require 'helper'
require 'tmpdir'
require 'shellwords'

# An output that keeps the events it gets, to see where Fluentd routes the events.
class RewriteTagFilterTestCollectOutput < Fluent::Plugin::Output
  Fluent::Plugin.register_output("rewrite_tag_filter_test_collect", self)
  config_param :name, :string, default: "out"

  def self.events
    @events ||= []
  end

  def process(tag, es)
    es.each { |_time, record| self.class.events << [@name, tag, record] }
  end
end

# An output that emits an event through a router when it is configured, as an input of the old configuration can do
# while Fluentd configures the new one in a reload.
class RewriteTagFilterTestEmitInConfigureOutput < Fluent::Plugin::Output
  Fluent::Plugin.register_output("rewrite_tag_filter_test_emit_in_configure", self)

  class << self
    attr_accessor :router_to_emit
  end

  def configure(conf)
    super
    self.class.router_to_emit&.emit("input", Fluent::EventTime.now, { "message" => "while configuring" })
  end

  def process(_tag, _es)
  end
end

class RewriteTagFilterOutputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    RewriteTagFilterTestEmitInConfigureOutput.router_to_emit = nil
  end

  def rule_conf(tag:, key: "message", pattern: "/^(a)(b)$/", label: nil, invert: false, head: "")
    conf = +"#{head}\n<rule>\n key #{key}\n pattern #{pattern}\n tag #{tag}\n"
    conf << " label #{label}\n" unless label.nil?
    conf << " invert true\n" if invert
    conf << "</rule>\n"
  end

  EMIT_MODES = { "batch" => "batch", "record" => "record" }.freeze

  def create_driver(conf)
    Fluent::Test::Driver::Output.new(Fluent::Plugin::RewriteTagFilterOutput).configure(conf)
  end

  sub_test_case "hostname_command" do
    def hostname_conf(tag, command)
      "hostname_command #{command}\n<rule>\n key message\n pattern /^(a)$/\n tag #{tag}\n</rule>\n"
    end

    # A command that works the same on sh and cmd.exe. A value that starts with a quote is read as a quoted string
    # in the configuration, so the path of ruby is escaped for sh instead of quoted.
    def ruby_command(code)
      %Q[#{Shellwords.escape(RbConfig.ruby)} -e "#{code}"]
    end

    # Prints the bytes given in hex, so the command line has only ASCII characters.
    def print_bytes_command(hex)
      ruby_command("STDOUT.binmode; STDOUT.write ['#{hex}'].pack('H*')")
    end

    def with_default_external(encoding)
      verbose, $VERBOSE = $VERBOSE, nil
      original = Encoding.default_external
      Encoding.default_external = encoding
      yield
    ensure
      Encoding.default_external = original
      $VERBOSE = verbose
    end

    test "runs only when a rule uses the hostname" do
      Dir.mktmpdir do |dir|
        marker = File.join(dir, "ran")
        command = ruby_command("File.write('#{marker}', 'x')")
        create_driver(hostname_conf("t.$1", command))
        assert_false(File.exist?(marker))
        create_driver(hostname_conf("t.${hostname}", command))
        assert_true(File.exist?(marker))
      end
    end

    test "a missing command does not stop the startup when no rule uses the hostname (#100)" do
      assert_nothing_raised { create_driver(hostname_conf("t.$1", "no_such_command_for_test")) }
    end

    data(
      "${hostname}"  => "t.${hostname}",
      "__HOSTNAME__" => "t.__HOSTNAME__",
    )
    test "runs when a rule uses the hostname" do |tag|
      d = create_driver(hostname_conf(tag, ruby_command("puts 'h1'")))
      assert_equal("h1", d.instance.instance_variable_get(:@hostname))
    end

    test "a missing command stops the startup when a rule uses the hostname, as before" do
      assert_raise(Errno::ENOENT) { create_driver(hostname_conf("t.${hostname}", "no_such_command_for_test")) }
    end

    data(
      "invalid UTF-8"              => ["ff",                 Encoding::UTF_8],
      "UTF-8 with LC_ALL=C"        => ["e3839be382b9e38388", Encoding::US_ASCII],
    )
    test "output that is not valid in the default external encoding does not stop the startup" do |(hex, encoding)|
      with_default_external(encoding) do
        d = create_driver(hostname_conf("t.${hostname}", print_bytes_command(hex)))
        assert_equal([hex].pack('H*'), d.instance.instance_variable_get(:@hostname).b)
      end
    end
  end

  sub_test_case "configure" do
    data("empty" => "",
         "line style" => "rewriterule1 foo ^foo$ new_tag")
    test "invalid" do |conf|
      assert_raise(Fluent::ConfigError) do
        create_driver(conf)
      end
    end

    test "pattern with character classes" do
      conf = %[
        <rule>
          key $['email']['domain']
          pattern /[sv]d[a-z]+\\d*$/
          tag $2.$1
        </rule>
      ]
      d = create_driver(conf)
      assert_equal(/[sv]d[a-z]+\d*$/, d.instance.rules.first.pattern)
    end

    test "pattern w/o slashes" do
      conf = %[
        <rule>
          key $['email']['domain']
          pattern .+
          tag $2.$1
        </rule>
      ]
      d = create_driver(conf)
      assert_equal(/.+/, d.instance.rules.first.pattern)
    end

    test "remove_tag_prefix and remove_tag_regexp are exclusive" do
      conf = %[
        remove_tag_prefix prefix
        remove_tag_regexp /^prefix\./
        <rule>
          key message
          pattern .+
          tag ${tag}
        </rule>
      ]
      assert_raise(Fluent::ConfigError) do
        create_driver(conf)
      end
    end

    sub_test_case "duplicated rules" do
      def rules_conf(*rules)
        rules.each_with_index.map { |(key, pattern, invert), i|
          "<rule>\n key #{key}\n pattern #{pattern}\n tag t#{i}\n#{invert ? " invert true\n" : ""}</rule>\n"
        }.join
      end

      data(
        "same key and pattern"      => [["message", "/x/"], ["message", "/x/"]],
        "pattern with and w/o slashes" => [["message", "x"], ["message", "/x/"]],
        "same, both inverted"       => [["message", "/x/", true], ["message", "/x/", true]],
        "inline option group"       => [["message", "/x/i"], ["message", "/(?i:x)/"]],
        "non-capturing group"       => [["message", "/x/"], ["message", "/(?:x)/"]],
        "escaped slashes"           => [["message", "^/api/"], ["message", "/^\\/api\\//"]],
      )
      test "are rejected" do |rules|
        e = assert_raise(Fluent::ConfigError) do
          create_driver(rules_conf(*rules))
        end
        assert_match(/duplicated rewriterules/, e.message)
      end

      data(
        "key ending with ! and inverted key" => [["a!", "/x/"], ["a", "/x/", true]],
        "invert differs"                     => [["message", "/x/"], ["message", "/x/", true]],
        "pattern options differ"             => [["message", "/x/"], ["message", "/x/i"]],
        "key differs"                        => [["message", "/x/"], ["other", "/x/"]],
      )
      test "different rules are accepted" do |rules|
        assert_nothing_raised do
          create_driver(rules_conf(*rules))
        end
      end
    end
  end

  sub_test_case "section style" do
    test "simple" do
      config = %[
        <rule>
          key domain
          pattern ^www\.google\.com$
          tag site.Google
        </rule>
        <rule>
          key domain
          pattern ^news\.google\.com$
          tag site.GoogleNews
        </rule>
        <rule>
          key agent
          pattern .* Mac OS X .*
          tag agent.MacOSX
        </rule>
        <rule>
          key agent
          pattern (Googlebot|CustomBot)-([a-zA-Z]+)
          tag agent.$1-$2
        </rule>
        <rule>
          key domain
          pattern ^(tagtest)\.google\.com$
          tag site.${tag}.$1
        </rule>
      ]
      d = create_driver(config)
      d.run(default_tag: "input.access") do
        d.feed({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
        d.feed({'domain' => 'news.google.com', 'path' => '/', 'agent' => 'Googlebot-Mobile', 'response_time' => 900000})
        d.feed({'domain' => 'map.google.com', 'path' => '/', 'agent' => 'Macintosh; Intel Mac OS X 10_7_4', 'response_time' => 900000})
        d.feed({'domain' => 'labs.google.com', 'path' => '/', 'agent' => 'Mozilla/5.0 Googlebot-FooBar/2.1', 'response_time' => 900000})
        d.feed({'domain' => 'tagtest.google.com', 'path' => '/', 'agent' => 'Googlebot', 'response_time' => 900000})
        d.feed({'domain' => 'noop.example.com'}) # to be ignored
      end
      events = d.events
      assert_equal 5, events.length
      assert_equal 'site.Google', events[0][0] # tag
      assert_equal 'site.GoogleNews', events[1][0] # tag
      assert_equal 'news.google.com', events[1][2]['domain']
      assert_equal 'agent.MacOSX', events[2][0] #tag
      assert_equal 'agent.Googlebot-FooBar', events[3][0] #tag
      assert_equal 'site.input.access.tagtest', events[4][0] #tag
    end

    test "remove_tag_prefix" do
      config = %[
        remove_tag_prefix input
        <rule>
          key domain
          pattern ^www\.google\.com$
          tag ${tag}
        </rule>
      ]
      d = create_driver(config)
      d.run(default_tag: "input.access") do
        d.feed({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
      end
      events = d.events
      assert_equal 1, events.length
      assert_equal 'access', events[0][0] # tag
    end

    test "remove_tag_prefix with dot" do
      config = %[
        remove_tag_prefix input.
        <rule>
          key domain
          pattern ^www\.google\.com$
          tag ${tag}
        </rule>
      ]
      d = create_driver(config)
      d.run(default_tag: "input.access") do
        d.feed({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
      end
      events = d.events
      assert_equal 1, events.length
      assert_equal 'access', events[0][0] # tag
    end

    sub_test_case "remove_tag_regexp" do
      test "plain" do
        config = %[
          remove_tag_regexp /^input\.(apache|nginx)\./
          <rule>
            key domain
            pattern ^www\.google\.com$
            tag rewritten.${tag}
          </rule>
        ]
        d = create_driver(config)
        d.run do
          d.feed('input.apache.access', event_time, {'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
          d.feed('input.nginx.access', event_time, {'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
          d.feed('input.tomcat.access', event_time, {'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
        end
        events = d.events
        assert_equal 3, events.length
        assert_equal 'rewritten.access', events[0][0]
        assert_equal 'rewritten.access', events[1][0]
        assert_equal 'rewritten.input.tomcat.access', events[2][0]
      end
    end

    test "short hostname" do
      config = %[
        remove_tag_prefix input
        hostname_command hostname -s
        <rule>
          key domain
          pattern ^www\.google\.com$
          tag ${hostname}
        </rule>
      ]
      d = create_driver(config)
      d.run(default_tag: "input.access") do
        d.feed({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
      end
      events = d.events
      assert_equal 1, events.length
      assert_equal `hostname -s`.chomp, events[0][0] # tag
    end

    test "non matching" do
      config = %[
        <rule>
          key domain
          pattern ^www\..+$
          tag not_start_with_www
          invert true
        </rule>
        <rule>
          key domain
          pattern ^www\..+$
          tag start_with_www
        </rule>
      ]
      d = create_driver(config)
      d.run(default_tag: "input.access") do
        d.feed({'domain' => 'www.google.com'})
        d.feed({'path' => '/'})
        d.feed({'domain' => 'maps.google.com'})
      end
      events = d.events
      assert_equal 3, events.length
      assert_equal 'start_with_www', events[0][0] # tag
      assert_equal 'not_start_with_www', events[1][0] # tag
      assert_equal 'not_start_with_www', events[2][0] # tag
    end

    data("dollar style" => "${tag_parts[%d]}",
         "underscore style" => "__TAG_PARTS[%d]__")
    test "split by tag" do |style|
      config = %[
        <rule>
          key user_name
          pattern ^Lynn Minmay$
          tag vip.#{style % 1}.remember_love
        </rule>
        <rule>
          key user_name
          pattern ^Harlock$
          tag #{style % 2}.#{style % 0}.#{style % 1}
        </rule>
        <rule>
          key  world
          pattern ^(alice|chaos)$
          tag application.#{style % 0}.$1_server
        </rule>
        <rule>
          key world
          pattern ^[a-z]+$
          tag application.#{style % 1}.future_server
        </rule>
      ]
      d = create_driver(config)
      d.run(default_tag: "game.production.api") do
        d.feed({'user_id' => '10000', 'world' => 'chaos', 'user_name' => 'gamagoori'})
        d.feed({'user_id' => '10001', 'world' => 'chaos', 'user_name' => 'sanageyama'})
        d.feed({'user_id' => '10002', 'world' => 'nehan', 'user_name' => 'inumuta'})
        d.feed({'user_id' => '77777', 'world' => 'space', 'user_name' => 'Lynn Minmay'})
        d.feed({'user_id' => '99999', 'world' => 'space', 'user_name' => 'Harlock'})
      end
      events = d.events
      assert_equal 5, events.length
      assert_equal 'application.game.chaos_server', events[0][0]
      assert_equal 'application.game.chaos_server', events[1][0]
      assert_equal 'application.production.future_server', events[2][0]
      assert_equal 'vip.production.remember_love', events[3][0]
      assert_equal 'api.game.production', events[4][0]
    end

    test "underscore style placeholder for tag and hostname" do
      config = %[
        <rule>
          key domain
          pattern ^(www)$
          tag site.__TAG__.$1
        </rule>
        <rule>
          key domain
          pattern ^news$
          tag site.__HOSTNAME__
        </rule>
      ]
      d = create_driver(config)
      d.run(default_tag: "input.access") do
        d.feed({'domain' => 'www'})
        d.feed({'domain' => 'news'})
      end
      events = d.events
      assert_equal 2, events.length
      assert_equal 'site.input.access.www', events[0][0]
      assert_equal "site.#{`hostname`.chomp}", events[1][0]
    end

    test "adjacent placeholders are expanded one by one" do
      config = %[
        <rule>
          key world
          pattern ^chaos$
          tag __TAG_PARTS[0]____TAG_PARTS[1]__
        </rule>
      ]
      d = create_driver(config)
      d.run(default_tag: "game.production.api") do
        d.feed({'world' => 'chaos'})
      end
      events = d.events
      assert_equal 1, events.length
      assert_equal 'gameproduction', events[0][0]
    end

    sub_test_case "expansion runs only once" do
      test "record value is not read as a placeholder" do
        config = %[
          <rule>
            key domain
            pattern ^(.+)$
            tag site.$1
          </rule>
        ]
        d = create_driver(config)
        d.run(default_tag: "input.access") do
          d.feed({'domain' => '${hostname}'})
          d.feed({'domain' => '__TAG__'})
          d.feed({'domain' => 'a${unknown}b'})
        end
        events = d.events
        assert_equal 3, events.length
        assert_equal 'site.${hostname}', events[0][0]
        assert_equal 'site.__TAG__', events[1][0]
        assert_equal 'site.a${unknown}b', events[2][0]
      end

      test "incoming tag is not read as a backreference" do
        config = %[
          <rule>
            key domain
            pattern ^(www)\.google\.com$
            tag ${tag}.$1
          </rule>
        ]
        d = create_driver(config)
        d.run(default_tag: "incoming.$1") do
          d.feed({'domain' => 'www.google.com'})
        end
        events = d.events
        assert_equal 1, events.length
        assert_equal 'incoming.$1.www', events[0][0]
      end

      test "invert rule keeps a backreference as it is written" do
        config = %[
          <rule>
            key domain
            pattern ^www\..+$
            tag other.$1
            invert true
          </rule>
        ]
        d = create_driver(config)
        d.run(default_tag: "input.access") do
          d.feed({'domain' => 'maps.google.com'})
        end
        events = d.events
        assert_equal 1, events.length
        assert_equal 'other.$1', events[0][0]
      end
    end

    test "invalid_byte (UTF-8)" do
      config = %[
        <rule>
          key client_name
          pattern (.+)
          tag app.$1
        </rule>
      ]
      invalid_utf8 = "\xff".force_encoding('UTF-8')
      d = create_driver(config)
      d.run(default_tag: "input.activity") do
        d.feed({'client_name' => invalid_utf8})
      end
      events = d.events
      assert_equal 1, events.length
      assert_equal "app.?", events[0][0]
      assert_equal invalid_utf8, events[0][2]['client_name']
    end

    test "invalid byte (US-ASCII)" do
      config = %[
        <rule>
          key client_name
          pattern (.+)
          tag app.$1
        </rule>
      ]
      invalid_ascii = "\xff".force_encoding('US-ASCII')
      d = create_driver(config)
      d.run(default_tag: "input.activity") do
        d.feed({'client_name' => invalid_ascii})
      end
      events = d.events
      assert_equal 1, events.length
      assert_equal "app.?", events[0][0]
      assert_equal invalid_ascii, events[0][2]['client_name']
    end

    test "capitalize_regex_backreference with an unmatched optional group" do
      conf = %[
        capitalize_regex_backreference yes
        <rule>
          key domain
          pattern ^(www\\.)?([a-z]+)\\.com$
          tag site.$1$2
        </rule>
      ]
      d = create_driver(conf)
      d.run(default_tag: "input") do
        d.feed({ "domain" => "www.example.com" })
        d.feed({ "domain" => "example.com" })
      end
      events = d.events
      assert_equal ["site.Www.Example", "site.Example"], events.map { |e| e[0] }
    end

    test "nested key support with dot notation" do
      conf = %[
        <rule>
          key $.email.domain
          pattern ^(example)\.(com)$
          tag $2.$1
        </rule>
      ]
      d = create_driver(conf)
      d.run(default_tag: "input") do
        d.feed({ "email" => { "localpart" => "john", "domain" => "example.com" }})
        d.feed({ "email" => { "localpart" => "doe", "domain" => "example.jp" }})
      end
      events = d.events
      assert_equal "com.example", events[0][0]
    end

    test "nested key support with bracket notation" do
      conf = %[
        <rule>
          key $['email']['domain']
          pattern ^(example)\.(com)$
          tag $2.$1
        </rule>
      ]
      d = create_driver(conf)
      d.run(default_tag: "input") do
        d.feed({ "email" => { "localpart" => "john", "domain" => "example.com" }})
        d.feed({ "email" => { "localpart" => "doe", "domain" => "example.jp" }})
      end
      events = d.events
      assert_equal "com.example", events[0][0]
    end

    test "tag has not been rewritten and log_level trace" do
      conf = %[
        @log_level trace
        <rule>
          key $['email']['domain']
          pattern ^(example)\.(com)$
          tag $2.$1
        </rule>
      ]
      d = create_driver(conf)
      d.run(default_tag: "input") do
        d.feed({ "email" => { "localpart" => "john", "domain" => "example.com" }})
        d.feed({ "email" => { "localpart" => "doe", "domain" => "example.jp" }})
      end
      events = d.events
      assert_equal(1, events.size)
      log = d.logs.grep(/\[trace\]/).first
      email = {"localpart" => "doe", "domain" => "example.jp"}
      assert_equal("rewrite_tag_filter: tag has not been rewritten email=#{email}",
                   log.slice(/\[trace\]: (.+)$/, 1))
      assert_equal "com.example", events[0][0]
    end

    test "get_router" do
      conf = %[
        <rule>
          key key
          pattern /^(odd|even)$/
          tag $1
          label new_label
        </rule>
        <rule>
          key key
          pattern /^(.*)$/
          tag $1
        </rule>
      ]
      time = event_time
      d = create_driver(conf)
      assert_equal(d.instance.router, d.instance.get_router(nil))
      assert_equal(d.instance.router, d.instance.get_router(""))
      new_label_router = d.instance.get_router("new_label")
      refute_equal(d.instance.router, new_label_router)
    end

    test "relabel" do
      conf = %[
          emit_mode record
          <rule>
            key key
            pattern /^(odd)$/
            tag $1
            label odd_label
          </rule>
          <rule>
            key key
            pattern /^(even)$/
            tag ${tag}
            label even_label
          </rule>
          <rule>
            key key
            pattern /^(.*)$/
            tag $1
          </rule>
        ]
      time = event_time
      d = create_driver(conf)
      # Router only called for default label. The routers of the labels are found in configure, not for each record.
      mock.proxy(d.instance.router).emit(anything, anything, anything).times(2)
      dont_allow(d.instance).get_router.with_any_args
      mock.proxy(d.instance.router).emit_stream(anything, anything).times(0)
      d.run(default_tag: "input") do
        d.feed([[time, { "key" => "odd", "message" => "message-1" }],
                [time, { "key" => "even", "message" => "message-2" }],
                [time, { "key" => "zero", "message" => "message-3" }],
                [time, { "key" => "odd", "message" => "message-4" }],
                [time, { "key" => "even", "message" => "message-5" }],
                [time, { "key" => "zero", "message" => "message-6" }]])
      end
      events = d.events
      expected_events = [
        ["odd", time, { "key" => "odd", "message" => "message-1" }],
        ["input", time, { "key" => "even", "message" => "message-2" }],
        ["zero", time, { "key" => "zero", "message" => "message-3" }],
        ["odd", time, { "key" => "odd", "message" => "message-4" }],
        ["input", time, { "key" => "even", "message" => "message-5" }],
        ["zero", time, { "key" => "zero", "message" => "message-6" }],
      ]
      assert_equal(events, expected_events)
    end

    sub_test_case "emit_mode" do
      test "record" do
        conf = %[
          emit_mode record
          <rule>
            key key
            pattern /^(odd|even)$/
            tag $1
          </rule>
        ]
        time = event_time
        d = create_driver(conf)
        mock.proxy(d.instance.router).emit(anything, anything, anything).times(6)
        mock.proxy(d.instance.router).emit_stream(anything, anything).times(0)
        d.run(default_tag: "input") do
          d.feed([[time, { "key" => "odd", "message" => "message-1" }],
                  [time, { "key" => "even", "message" => "message-2" }],
                  [time, { "key" => "odd", "message" => "message-3" }],
                  [time, { "key" => "even", "message" => "message-4" }],
                  [time, { "key" => "odd", "message" => "message-5" }],
                  [time, { "key" => "even", "message" => "message-6" }]])
        end
        events = d.events
        expected_events = [
          ["odd", time, { "key" => "odd", "message" => "message-1" }],
          ["even", time, { "key" => "even", "message" => "message-2" }],
          ["odd", time, { "key" => "odd", "message" => "message-3" }],
          ["even", time, { "key" => "even", "message" => "message-4" }],
          ["odd", time, { "key" => "odd", "message" => "message-5" }],
          ["even", time, { "key" => "even", "message" => "message-6" }],
        ]
        assert_equal(events, expected_events)
      end

      test "batch" do
        conf = %[
          emit_mode batch
          <rule>
            key key
            pattern /^(odd|even)$/
            tag $1
          </rule>
        ]
        time = event_time
        d = create_driver(conf)
        mock.proxy(d.instance.router).emit(anything, anything, anything).times(0)
        mock.proxy(d.instance.router).emit_stream(anything, anything).times(2)
        d.run(default_tag: "input") do
          d.feed([[time, { "key" => "odd", "message" => "message-1" }],
                  [time, { "key" => "even", "message" => "message-2" }],
                  [time, { "key" => "odd", "message" => "message-3" }],
                  [time, { "key" => "even", "message" => "message-4" }],
                  [time, { "key" => "odd", "message" => "message-5" }],
                  [time, { "key" => "even", "message" => "message-6" }]])
        end
        events = d.events
        expected_records = [
          ["odd", time, { "key" => "odd", "message" => "message-1" }],
          ["odd", time, { "key" => "odd", "message" => "message-3" }],
          ["odd", time, { "key" => "odd", "message" => "message-5" }],
          ["even", time, { "key" => "even", "message" => "message-2" }],
          ["even", time, { "key" => "even", "message" => "message-4" }],
          ["even", time, { "key" => "even", "message" => "message-6" }],
        ]
        assert_equal(events, expected_records)
      end
    end
  end

  sub_test_case "a nested key that the rules cannot read" do
    UNREADABLE = {
      "string parent"                   => ["$.log.level",       { "log" => "plain" }],
      "string parent, bracket notation" => ["$['log']['level']", { "log" => "plain" }],
      "integer parent"                  => ["$.log.level",       { "log" => 1 }],
      "true parent"                     => ["$.log.level",       { "log" => true }],
      "array parent"                    => ["$.log.level",       { "log" => ["x"] }],
      "string grandparent"              => ["$.log.level.name",  { "log" => { "level" => "x" } }],
      "array index on string"           => ["$.log[0]",          { "log" => "plain" }],
    }.freeze

    data(UNREADABLE)
    test "is treated as a missing key" do |(key, record)|
      rules = rule_conf(key: key, pattern: "/^(.+)$/", tag: "level.$1") + rule_conf(pattern: "/(?!)/", tag: "other", invert: true)
      d = create_driver(rules)
      d.run(default_tag: "input") { d.feed(record) }
      assert_equal(["other"], d.events.map(&:first))
    end

    data(UNREADABLE)
    test "is treated as a missing key by an invert rule on it" do |(key, record)|
      d = create_driver(rule_conf(key: key, pattern: "/^x$/", tag: "not_x", invert: true))
      d.run(default_tag: "input") { d.feed(record) }
      assert_equal(["not_x"], d.events.map(&:first))
    end

    data(EMIT_MODES)
    test "does not stop the readable records in the same stream" do |mode|
      rules = rule_conf(key: "$.log.level", pattern: "/^(.+)$/", tag: "level.$1", head: "emit_mode #{mode}")
      d = create_driver(rules)
      d.run(default_tag: "input") do
        d.feed([[event_time, { "log" => "plain" }], [event_time, { "log" => { "level" => "info" } }]])
      end
      assert_equal([["level.info", { "log" => { "level" => "info" } }]], d.events.map { |t, _, r| [t, r] })
    end

    test "is warned once for each rule" do
      rules = rule_conf(key: "$.log.level", pattern: "/^x$/", tag: "x") + rule_conf(key: "$.log.name", pattern: "/^y$/", tag: "y")
      d = create_driver(rules)
      d.run(default_tag: "input") { 3.times { d.feed({ "log" => "plain" }) } }
      warnings = d.logs.grep(/a parent in the nested key cannot be read/)
      assert_equal(2, warnings.size, warnings.inspect)
      assert_match(/key="\$\.log\.level"/, warnings[0])
      assert_match(/key="\$\.log\.name"/, warnings[1])
    end

    test "a record that is not a Hash still raises the error as before" do
      d = create_driver(rule_conf(key: "message", pattern: "/(?!)/", tag: "other", invert: true))
      es = Fluent::MultiEventStream.new
      es.add(event_time, ["a", "b"])
      assert_raise(TypeError) { d.run(default_tag: "input") { d.feed("input", es) } }
    end
  end

  sub_test_case "max_reemit_depth" do
    data("0" => "0", "negative" => "-1", "over the limit" => "21")
    test "must be between 1 and 20" do |value|
      error = assert_raise(Fluent::ConfigError) { create_driver("max_reemit_depth #{value}\n" + rule_conf(tag: "new")) }
      assert_equal("max_reemit_depth must be between 1 and 20", error.message)
    end

    data("1" => "1", "20" => "20")
    test "accepts the limits" do |value|
      assert_nothing_raised { create_driver("max_reemit_depth #{value}\n" + rule_conf(tag: "new")) }
    end
  end

  # These tests let Fluentd route the events with the configuration, as it does when it runs.
  sub_test_case "re-emitted event that comes back to this plugin" do
    teardown do
      Fluent::Engine.init(Fluent::SystemConfig.new)
    end

    ERROR_LABEL_CONF = %[
      <label @ERROR>
        <match **>
          @type rewrite_tag_filter_test_collect
          name error
        </match>
      </label>
    ]

    def run_fluentd(conf, tag, records = [{ "message" => "a" }])
      RewriteTagFilterTestCollectOutput.events.clear
      Fluent::Engine.run_configure(Fluent::Config.parse(conf, "(test)", "(test_dir)", syntax: :v1))
      es = Fluent::MultiEventStream.new
      records.each { |record| es.add(event_time, record) }
      Fluent::Engine.root_agent.event_router.emit_stream(tag, es)
      RewriteTagFilterTestCollectOutput.events
    end

    def loop_conf(mode, label, error_label: true)
      %[
        <match **>
          @type rewrite_tag_filter
          emit_mode #{mode}
          <rule>
            key message
            pattern /.+/
            tag ${tag}
            label #{label}
          </rule>
        </match>
      ] + (error_label ? ERROR_LABEL_CONF : "")
    end

    LOOPS = {
      "label @ROOT, batch"  => ["batch", "@ROOT"],
      "label @ROOT, record" => ["record", "@ROOT"],
      'label "", batch'     => ["batch", '""'],
      'label "", record'    => ["record", '""'],
    }.freeze

    data(LOOPS)
    test "a loop is stopped and the events go to @ERROR" do |(mode, label)|
      events = run_fluentd(loop_conf(mode, label), "input", [{ "message" => "a" }, { "message" => "b" }])
      assert_equal([["error", "input", { "message" => "a" }], ["error", "input", { "message" => "b" }]], events)
      assert_true(Thread.current[Fluent::Plugin::RewriteTagFilterOutput::REEMIT_DEPTH_KEY].empty?)
    end

    data(LOOPS)
    test "without <label @ERROR>, the error of a loop goes back to the input" do |(mode, label)|
      error = assert_raise(Fluent::Plugin::RewriteTagFilterOutput::ReemitLoopError) do
        run_fluentd(loop_conf(mode, label, error_label: false), "input")
      end
      assert_match(/events came back to this plugin 10 times in a row/, error.message)
      # The error is raised once from the outermost pass, so Fluentd logs it once, not at each level of the nested emits.
      assert_equal(1, $log.out.logs.grep(/emit transaction failed/).size, $log.out.logs.grep(/emit transaction failed/).inspect)
      assert_true(Thread.current[Fluent::Plugin::RewriteTagFilterOutput::REEMIT_DEPTH_KEY].empty?)
    end

    # The tag loses one part on each pass, and reaches <match m> after 12 passes.
    data(
      "default limit" => ["", [["error", "k.l.m", { "message" => "a" }]]],
      "limit of 20"   => ["max_reemit_depth 20", [["out", "m", { "message" => "a" }]]],
    )
    test "a chain that ends is stopped only when it is longer than max_reemit_depth" do |(param, expected)|
      events = run_fluentd(%[
        <match m>
          @type rewrite_tag_filter_test_collect
        </match>
        <match **>
          @type rewrite_tag_filter
          #{param}
          remove_tag_regexp /^[^.]+\\./
          <rule>
            key message
            pattern /.+/
            tag ${tag}
          </rule>
        </match>
      ] + ERROR_LABEL_CONF, "a.b.c.d.e.f.g.h.i.j.k.l.m")
      assert_equal(expected, events)
    end

    # A loop through three <match> sections, all with out_copy, after 10 filters, with the largest max_reemit_depth. The
    # events are passed 60 times in a row. Run in a thread, which has a smaller stack than the main thread, as an input
    # does. The stack of a thread ran out after 84 passes with out_copy on Windows with Ruby 3.1.
    test "the largest max_reemit_depth does not run out of the stack" do
      filters = (1..10).map { "<filter **>\n@type record_transformer\n</filter>\n" }.join
      rtf = ->(pattern, prefix) do
        %[
          <match #{pattern}>
            @type copy
            <store>
              @type rewrite_tag_filter
              max_reemit_depth 20
              <rule>
                key message
                pattern /.+/
                tag #{prefix}.${tag}
              </rule>
            </store>
          </match>
        ]
      end
      loop_conf = rtf.call("a.**", "b") + rtf.call("b.**", "c") + rtf.call("c.**", "a")
      events = Thread.new { run_fluentd(filters + loop_conf + ERROR_LABEL_CONF, "a") }.value
      assert_equal(1, events.size)
      assert_equal("error", events.first[0])
      # "a" and 60 parts added by the passes.
      assert_equal(61, events.first[1].split(".").size)
    end

    data(EMIT_MODES)
    test 'label "" sends the events to the label of the <match>' do |mode|
      events = run_fluentd(%[
        <match input>
          @type rewrite_tag_filter
          @label @OTHER
          emit_mode #{mode}
          <rule>
            key message
            pattern /.+/
            tag ${tag}
            label ""
          </rule>
        </match>
        <label @OTHER>
          <match **>
            @type rewrite_tag_filter_test_collect
            name other
          </match>
        </label>
      ], "input")
      assert_equal([["other", "input", { "message" => "a" }]], events)
    end

    test "events sent to @ERROR that come back are dropped, and the records are logged" do
      events = run_fluentd(%[
        <match input>
          @type rewrite_tag_filter
          <rule>
            key message
            pattern /.+/
            tag new.${tag}
            label @ERROR
          </rule>
        </match>
        <label @ERROR>
          <match **>
            @type rewrite_tag_filter
            <rule>
              key message
              pattern /.+/
              tag new.${tag}
            </rule>
          </match>
        </label>
      ], "input")
      assert_equal([], events)
      logs = $log.out.logs.grep(/an event sent to @ERROR came back to this plugin/)
      assert_equal(1, logs.size, $log.out.logs.inspect)
      assert_match(/record=\{"message"\s*=>\s*"a"\}/, logs.first)
    end
  end

  # These tests let Fluentd route the events with the configuration, as it does when it runs.
  sub_test_case "the router of a label" do
    teardown do
      Fluent::Engine.init(Fluent::SystemConfig.new)
    end

    EMIT_IN_CONFIGURE_CONF = "<match never>\n@type rewrite_tag_filter_test_emit_in_configure\n</match>"

    def configure_fluentd(conf)
      Fluent::Engine.run_configure(Fluent::Config.parse(conf, "(test)", "(test_dir)", syntax: :v1))
    end

    # Engine#reload_config replaces Fluent::Engine.root_agent and configures the new configuration before it stops the
    # old one. It starts the new one after the old one is shut down. Engine#init makes a new root agent in the same way.
    # rewrite_tag_filter_test_emit_in_configure in the new configuration emits through the old one. The old root agent is
    # returned.
    def reload(old_conf, new_conf)
      configure_fluentd(old_conf)
      old_root_agent = Fluent::Engine.root_agent
      RewriteTagFilterTestEmitInConfigureOutput.router_to_emit = old_root_agent.event_router
      RewriteTagFilterTestCollectOutput.events.clear
      Fluent::Engine.init(Fluent::SystemConfig.new)
      configure_fluentd(new_conf)
      old_root_agent
    end

    # The labels that the plugin looks up from now on.
    def count_lookups(plugin)
      lookups = []
      plugin.define_singleton_method(:get_router) do |label|
        lookups << label
        super(label)
      end
      lookups
    end

    def emit_one(router)
      RewriteTagFilterTestCollectOutput.events.clear
      router.emit("input", event_time, { "message" => "a" })
      RewriteTagFilterTestCollectOutput.events.dup
    end

    # head is put in <label @OUT> before its <match>. Without @OUT, the label of the rule is not defined.
    def label_conf(name, mode: "batch", head: "", out: true)
      conf = %[
        <match input>
          @type rewrite_tag_filter
          #{rule_conf(pattern: "/.+/", tag: "new.${tag}", label: "@OUT", head: "emit_mode #{mode}")}
        </match>
      ]
      return conf + ERROR_LABEL_CONF unless out
      conf + %[
        <label @OUT>
          #{head}
          <match **>
            @type rewrite_tag_filter_test_collect
            name #{name}
          </match>
        </label>
      ]
    end

    data(EMIT_MODES)
    test "is looked up in configure, not for each event stream" do |mode|
      configure_fluentd(label_conf("out", mode: mode))
      root_agent = Fluent::Engine.root_agent
      lookups = count_lookups(root_agent.outputs.first)
      assert_equal([["out", "new.input", { "message" => "a" }]], emit_one(root_agent.event_router))
      assert_equal([], lookups)
    end

    test "during a reload, the events go to the label of the configuration of this plugin" do
      old_root_agent = reload(label_conf("old"), label_conf("new"))
      assert_equal([["old", "new.input", { "message" => "a" }]], emit_one(old_root_agent.event_router))
      assert_equal([["new", "new.input", { "message" => "a" }]], emit_one(Fluent::Engine.root_agent.event_router))
    end

    # Fluentd adds the <label> sections of the new configuration before it configures them, and the router of a label
    # keeps the collector that it finds for a tag. An event sent to the new label before its <match> is added would be
    # dropped, and so would the events with the same tag that the new configuration sends to the label later.
    data(EMIT_MODES)
    test "during a reload, the events sent while the new configuration is configured do not break its routing" do |mode|
      reload(label_conf("old", mode: mode), label_conf("new", mode: mode, head: EMIT_IN_CONFIGURE_CONF))
      assert_equal([["old", "new.input", { "message" => "while configuring" }]], RewriteTagFilterTestCollectOutput.events)
      assert_equal([["new", "new.input", { "message" => "a" }]], emit_one(Fluent::Engine.root_agent.event_router))
    end

    test "during a reload, a label that is not defined in the configuration of this plugin is not looked up in the new one" do
      reload(label_conf("old", out: false), label_conf("new", head: EMIT_IN_CONFIGURE_CONF))
      # The error goes to @ERROR of the old configuration, as the lookup error does.
      assert_equal([["error", "input", { "message" => "while configuring" }]], RewriteTagFilterTestCollectOutput.events)
      assert_equal([["new", "new.input", { "message" => "a" }]], emit_one(Fluent::Engine.root_agent.event_router))
    end

    data(EMIT_MODES)
    test "each rule sends to the router of its own label" do |mode|
      configure_fluentd(%[
        <match input>
          @type rewrite_tag_filter
          emit_mode #{mode}
          #{rule_conf(pattern: "/^a$/", tag: "new.${tag}", label: "@A")}
          #{rule_conf(pattern: "/^b$/", tag: "new.${tag}", label: "@B")}
          #{rule_conf(pattern: "/^c$/", tag: "c.${tag}")}
        </match>
        <match c.**>
          @type rewrite_tag_filter_test_collect
          name root
        </match>
      ] + %w[A B].map { |name| %[
        <label @#{name}>
          <match **>
            @type rewrite_tag_filter_test_collect
            name #{name}
          </match>
        </label>
      ] }.join)
      RewriteTagFilterTestCollectOutput.events.clear
      Fluent::Engine.root_agent.event_router.emit_array("input", %w[a b c b a].map { |m| [event_time, { "message" => m }] })
      events = RewriteTagFilterTestCollectOutput.events
      assert_equal([["A", "new.input"]] * 2, events.select { |e| e[0] == "A" }.map { |e| e[0, 2] })
      assert_equal([["B", "new.input"]] * 2, events.select { |e| e[0] == "B" }.map { |e| e[0, 2] })
      assert_equal([["root", "c.input", { "message" => "c" }]], events.select { |e| e[0] == "root" })
    end

    data(EMIT_MODES)
    test "a label that is not defined raises the error with the backtrace of the emit" do |mode|
      conf = %[
        <match input>
          @type rewrite_tag_filter
          #{rule_conf(pattern: "/.+/", tag: "new.${tag}", label: "@UNDEFINED", head: "emit_mode #{mode}")}
        </match>
      ]
      configure_fluentd(conf)
      lookups = count_lookups(Fluent::Engine.root_agent.outputs.first)
      errors = 2.times.map do
        assert_raise(ArgumentError) { emit_one(Fluent::Engine.root_agent.event_router) }
      end
      assert_equal(["@UNDEFINED label not found"] * 2, errors.map(&:message))
      assert_false(errors[0].equal?(errors[1]))
      # The location is the lookup in Fluentd, as when the label is looked up for the event, and then comes the emit.
      assert_match(/root_agent\.rb:\d+:in .*find_label/, errors[0].backtrace.first)
      assert_true(errors[0].backtrace.any? { |line| line.include?("rewrite_and_emit") }, errors[0].backtrace.inspect)
      assert_true(errors[0].backtrace.none? { |line| line.include?("resolve_label_routers") }, errors[0].backtrace.inspect)
      assert_equal([], lookups)
    end

    test "a label that is not found in configure is looked up again when the plugin starts" do
      configure_fluentd(label_conf("late", out: false))
      root_agent = Fluent::Engine.root_agent
      root_agent.add_label("@OUT").configure(Fluent::Config.parse(%[
        <match **>
          @type rewrite_tag_filter_test_collect
          name late
        </match>
      ], "(test)", "(test_dir)", syntax: :v1))
      root_agent.start
      begin
        assert_equal([["late", "new.input", { "message" => "a" }]], emit_one(root_agent.event_router))
      ensure
        root_agent.shutdown
      end
    end

    # The outputs of the old configuration do not flush after they are shut down. With supervisor: true, reload_config
    # configures the new configuration and shuts the old one down, but does not start the new one.
    test "after the configuration of this plugin is shut down, the events go to the configuration that Fluentd runs" do
      configure_fluentd(label_conf("old"))
      old_root_agent = Fluent::Engine.root_agent
      old_root_agent.start
      Fluent::Engine.reload_config(Fluent::Config.parse(label_conf("new"), "(test)", "(test_dir)", syntax: :v1), supervisor: true)
      assert_equal([["new", "new.input", { "message" => "a" }]], emit_one(old_root_agent.event_router))
    end

    # @ERROR is set up after the other <label> sections are configured.
    test "label @ERROR in a <label> is looked up when the plugin starts" do
      configure_fluentd(%[
        <label @APP>
          <match input>
            @type rewrite_tag_filter
            #{rule_conf(pattern: "/.+/", tag: "new.${tag}", label: "@ERROR")}
          </match>
        </label>
      ] + ERROR_LABEL_CONF)
      root_agent = Fluent::Engine.root_agent
      app = root_agent.find_label("@APP")
      lookups = count_lookups(app.outputs.first)
      expected = [["error", "new.input", { "message" => "a" }]]
      # Before the plugin starts, the label is looked up when its events come.
      assert_equal(expected, emit_one(app.event_router))
      assert_equal(["@ERROR"], lookups)
      root_agent.start
      begin
        lookups.clear
        assert_equal(expected, emit_one(app.event_router))
        assert_equal([], lookups)
      ensure
        root_agent.shutdown
      end
    end
  end
end
