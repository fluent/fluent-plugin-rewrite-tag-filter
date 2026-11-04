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

# An output that raises, as an output that fails. An error that is not a StandardError is not caught by Fluentd.
class RewriteTagFilterTestRaiseOutput < Fluent::Plugin::Output
  Fluent::Plugin.register_output("rewrite_tag_filter_test_raise", self)
  config_param :standard_error, :bool, default: true

  class Error < Exception; end

  def process(tag, es)
    raise(@standard_error ? RuntimeError : Error, "failed")
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
      assert_reemit_state_is_clean
    end

    data(LOOPS)
    test "without <label @ERROR>, the error of a loop goes back to the input" do |(mode, label)|
      error = assert_raise(Fluent::Plugin::RewriteTagFilterOutput::ReemitLoopError) do
        run_fluentd(loop_conf(mode, label, error_label: false), "input")
      end
      assert_match(/events came back to this plugin 10 times in a row/, error.message)
      # The error is raised once from the outermost pass, so Fluentd logs it once, not at each level of the nested emits.
      assert_equal(1, $log.out.logs.grep(/emit transaction failed/).size, $log.out.logs.grep(/emit transaction failed/).inspect)
      assert_reemit_state_is_clean
    end

    # The tag loses one part on each pass. "m" reaches <match m> after 12 passes. "k" is not re-emitted at its pass, the
    # 11th, so the chain ends there with the default limit too, as on master.
    data(
      "default limit"          => ["", "a.b.c.d.e.f.g.h.i.j.k.l.m", [["error", "k.l.m", { "message" => "a" }]]],
      "limit of 20"            => ["max_reemit_depth 20", "a.b.c.d.e.f.g.h.i.j.k.l.m", [["out", "m", { "message" => "a" }]]],
      "ends at the last pass"  => ["", "a.b.c.d.e.f.g.h.i.j.k", []],
    )
    test "a chain that ends is stopped only when it is longer than max_reemit_depth" do |(param, tag, expected)|
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
      ] + ERROR_LABEL_CONF, tag)
      assert_equal(expected, events)
      assert_equal(expected.none? { |name, _tag, _record| name == "error" }, $log.out.logs.grep(/ReemitLoopError/).empty?, $log.out.logs.inspect)
      assert_reemit_state_is_clean
    end

    # A ring of <match> sections, each with out_copy, after 10 filters: s1 re-emits to s2, and the last one to s1. Each
    # pass adds a part to the tag. depths: the max_reemit_depth of each section, the last one for the rest.
    def ring_conf(depths, sections: depths.size, error_label: ERROR_LABEL_CONF)
      filters = (1..10).map { "<filter **>\n@type record_transformer\n</filter>\n" }.join
      ring = (1..sections).map do |i|
        %[
          <match s#{i}.**>
            @type copy
            <store>
              @type rewrite_tag_filter
              max_reemit_depth #{depths[i - 1] || depths.last}
              <rule>
                key message
                pattern /.+/
                tag s#{i % sections + 1}.${tag}
              </rule>
            </store>
          </match>
        ]
      end
      filters + ring.join + error_label
    end

    # Runs in a thread, which has a smaller stack than the main thread, as an input does, or in a fiber in it, which has
    # a smaller one still. Returns the events and the state left in the thread or the fiber.
    def run_nested(where, &block)
      run_in_thread(30) do
        if where == :fiber
          Fiber.new { [block.call, reemit_state] }.resume
        else
          [block.call, reemit_state]
        end
      end
    end

    # max_reemit_depth is counted for each section, so a ring of 12 sections with the largest one would nest 240 passes.
    # The passes of all the sections in a row are stopped at 20 too. With 10 filters and out_copy, the stack of a thread
    # ran out after 84 passes on Windows with Ruby 3.1, and the stack of a fiber after 67 on Linux with Ruby 3.2.
    data(
      "3 sections, limit of 20, thread"  => [3, 20, :thread],
      "12 sections, limit of 20, thread" => [12, 20, :thread],
      "4 sections, limit of 20, fiber"   => [4, 20, :fiber],
      "8 sections, default limit, fiber" => [8, 10, :fiber],
      "12 sections, limit of 20, fiber"  => [12, 20, :fiber],
    )
    test "the passes of all the sections are stopped at 20 in a row, within the stack" do |(sections, depth, where)|
      events, state = run_nested(where) { run_fluentd(ring_conf([depth], sections: sections), "s1") }
      assert_equal(1, events.size)
      assert_equal("error", events.first[0])
      # "s1" and 20 parts added by the passes.
      assert_equal(21, events.first[1].split(".").size)
      assert_equal(1, $log.out.logs.grep(/were re-emitted by rewrite_tag_filter 20 times in a row in the nested emits, counting the passes of all the <match> sections/).size, $log.out.logs.inspect)
      assert_reemit_state_is_clean(state)
    end

    # The first limit reached stops the loop: the depth of a section, or 20 passes of all the sections.
    data(
      "s1 with 3 and s2 with 20" => [[3, 20], 7, /came back to this plugin 3 times in a row/],
      "s1 with 20 and s2 with 3" => [[20, 3], 8, /came back to this plugin 3 times in a row/],
      "both with 20"             => [[20, 20], 21, /were re-emitted by rewrite_tag_filter 20 times in a row/],
      # s1 reaches its depth of 10 at the 21st pass, where the passes in a row reach 20 too.
      "both with 10"             => [[10, 10], 21, /came back to this plugin 10 times in a row/],
      "s1 with 9 and s2 with 10" => [[9, 10], 19, /came back to this plugin 9 times in a row/],
    )
    test "sections with different max_reemit_depth are stopped at the first limit" do |(depths, parts, message)|
      events, state = run_nested(:thread) { run_fluentd(ring_conf(depths), "s1") }
      assert_equal([["error", parts]], events.map { |name, tag, _record| [name, tag.split(".").size] })
      assert_equal(1, $log.out.logs.grep(message).size, $log.out.logs.inspect)
      assert_reemit_state_is_clean(state)
    end

    # The events that @ERROR sends back to the ring come to the section that was stopped, so they are dropped.
    data(
      "stopped at 20 passes, thread"      => [[20], 12, :thread],
      "stopped at 20 passes, fiber"       => [[20], 12, :fiber],
      "stopped at a section limit, fiber" => [[3, 20], 2, :fiber],
    )
    test "events sent back from @ERROR to a ring are dropped" do |(depths, sections, where)|
      events, state = run_nested(where) do
        run_fluentd(ring_conf(depths, sections: sections, error_label: ERROR_LABEL_RELABEL_CONF), "s1")
      end
      assert_equal(["error"], events.map(&:first))
      assert_equal(1, $log.out.logs.grep(/an event sent to @ERROR came back to this plugin/).size, $log.out.logs.inspect)
      assert_reemit_state_is_clean(state)
    end

    # The events of a ring stopped at 20 passes in a row are sent to @ERROR once each section of the ring is back at
    # its outermost pass, so that a rewrite_tag_filter in <label @ERROR> can still re-emit them.
    data(
      "3 sections, default limit, thread"  => [[10], 3, :thread],
      "12 sections, limit of 20, thread"   => [[20], 12, :thread],
      "12 sections, limit of 20, fiber"    => [[20], 12, :fiber],
      "s1 with 3 and s2 with 20, fiber"    => [[3, 20], 2, :fiber],
    )
    test "a rewrite_tag_filter in <label @ERROR> routes the events of a stopped ring" do |(depths, sections, where)|
      error_label = %[
        <label @ERROR>
          <match routed.**>
            @type rewrite_tag_filter_test_collect
            name routed
          </match>
          <match **>
            @type rewrite_tag_filter
            <rule>
              key message
              pattern /.+/
              tag routed.${tag}
            </rule>
          </match>
        </label>
      ]
      events, state = run_nested(where) { run_fluentd(ring_conf(depths, sections: sections, error_label: error_label), "s1") }
      assert_equal(["routed"], events.map(&:first))
      assert_equal([], $log.out.logs.grep(/came back to this plugin, so it is dropped/))
      assert_reemit_state_is_clean(state)
    end

    # A <store> next to each pass of the loop leads the record out of it. Only its pass at the 21st level, which cannot
    # re-emit, is stopped, and its record is the one of the stopped loop, sent to @ERROR once. Its other passes go out.
    data(
      "1 section, limit of 20"   => [1, 20],
      "2 sections, limit of 20"  => [2, 20],
      "2 sections, default limit" => [2, 10],
    )
    test "a <store> that leads out of a loop stopped at 20 passes in a row goes on" do |(sections, depth)|
      conf = (1..sections).map { |i| %[
        <match s#{i}.**>
          @type copy
          <store>
            @type rewrite_tag_filter
            max_reemit_depth #{depth}
            #{rule_conf(pattern: "/.+/", tag: "s#{i % sections + 1}.${tag}")}
          </store>
          <store>
            @type rewrite_tag_filter
            #{rule_conf(pattern: "/.+/", tag: "out.${tag}")}
          </store>
        </match>
      ] }.join + %[
        <match out.**>
          @type rewrite_tag_filter_test_collect
          name out
        </match>
      ] + ERROR_LABEL_CONF
      events, state = run_nested(:fiber) { run_fluentd(conf, "s1") }
      assert_equal({ "out" => 20, "error" => 1 }, events.group_by(&:first).map { |name, list| [name, list.size] }.to_h)
      assert_equal((2..21).to_a, events.select { |name, _tag, _record| name == "out" }.map { |_name, tag, _record| tag.split(".").size }.sort)
      assert_reemit_state_is_clean(state)
    end

    # The events are sent to @ERROR from the nested emits, where the passes can nest 10 more, so that a
    # rewrite_tag_filter in <label @ERROR> routes them, after a chain of 21 sections, or after a long chain into a ring.
    data(
      "a chain of 21 sections"              => ["chain", "c1"],
      "a ring after a chain of 19 sections" => ["ring", "c1"],
    )
    test "a rewrite_tag_filter in <label @ERROR> routes the events of a long chain stopped at 20 passes" do |(kind, tag)|
      chain = (1..19).map { |i| %[
        <match c#{i}>
          @type rewrite_tag_filter
          #{rule_conf(pattern: "/.+/", tag: i < 19 ? "c#{i + 1}" : (kind == "chain" ? "c20" : "r1"))}
        </match>
      ] }.join
      rest = if kind == "chain"
        %[
          <match c20>
            @type rewrite_tag_filter
            #{rule_conf(pattern: "/.+/", tag: "c21")}
          </match>
          <match c21>
            @type rewrite_tag_filter
            #{rule_conf(pattern: "/.+/", tag: "done")}
          </match>
        ]
      else
        %[
          <match r1.** r1>
            @type rewrite_tag_filter
            #{rule_conf(pattern: "/.+/", tag: "r2.${tag}")}
          </match>
          <match r2.**>
            @type rewrite_tag_filter
            #{rule_conf(pattern: "/.+/", tag: "r1.${tag}")}
          </match>
        ]
      end
      error_label = %[
        <label @ERROR>
          <match routed.**>
            @type rewrite_tag_filter_test_collect
            name routed
          </match>
          <match **>
            @type rewrite_tag_filter
            #{rule_conf(pattern: "/.+/", tag: "routed.${tag}")}
          </match>
        </label>
      ]
      events, state = run_nested(:fiber) { run_fluentd(chain + rest + error_label, tag) }
      assert_equal(["routed"], events.map(&:first))
      assert_equal([], $log.out.logs.grep(/came back to this plugin, so it is dropped/))
      assert_reemit_state_is_clean(state)
    end

    # The deepest nesting: a loop in <label @ERROR> itself, after 10 filters, with out_copy, while the events of a ring
    # stopped at 20 passes in a row are sent there. It is stopped at 30 passes in a row, and its events come back to
    # @ERROR, so they are dropped.
    data("thread" => :thread, "fiber" => :fiber)
    test "a loop in <label @ERROR> is stopped at 30 passes in a row, within the stack" do |where|
      filters = (1..10).map { "<filter **>\n@type record_transformer\n</filter>\n" }.join
      error_label = %[
        <label @ERROR>
          #{filters}
          <match s*.** e.**>
            @type copy
            <store>
              @type rewrite_tag_filter
              max_reemit_depth 20
              #{rule_conf(pattern: "/.+/", tag: "e.${tag}")}
            </store>
          </match>
        </label>
      ]
      events, state = run_nested(where) { run_fluentd(ring_conf([20], sections: 12, error_label: error_label), "s1") }
      assert_equal([], events)
      assert_equal(1, $log.out.logs.grep(/were re-emitted by rewrite_tag_filter 30 times in a row/).size, $log.out.logs.inspect)
      assert_equal(1, $log.out.logs.grep(/came back to this plugin, so it is dropped/).size, $log.out.logs.inspect)
      assert_reemit_state_is_clean(state)
    end

    # The events of a chain of 21 sections are sent to @ERROR at 20 passes in a row, into a chain of 11 sections there,
    # which is stopped at 30. Its events come back to the section that was stopped, so they are dropped, instead of being
    # sent to @ERROR again and again.
    data("thread" => :thread, "fiber" => :fiber)
    test "events stopped while they are sent to @ERROR are dropped when they come back" do |where|
      chain = ->(prefix, count, last) do
        (1..count).map { |i| %[
          <match #{prefix}#{i}>
            @type rewrite_tag_filter
            #{rule_conf(pattern: "/.+/", tag: i < count ? "#{prefix}#{i + 1}" : last)}
          </match>
        ] }.join
      end
      conf = chain.call("c", 21, "done") + %[
        <label @ERROR>
          <match c21>
            @type rewrite_tag_filter
            #{rule_conf(pattern: "/.+/", tag: "e1")}
          </match>
          #{chain.call("e", 11, "edone")}
          <match edone>
            @type rewrite_tag_filter_test_collect
            name error
          </match>
        </label>
      ]
      events, state = run_nested(where) { run_fluentd(conf, "c1") }
      assert_equal([], events)
      assert_equal(1, $log.out.logs.grep(/came back to this plugin, so it is dropped/).size, $log.out.logs.inspect)
      assert_reemit_state_is_clean(state)
    end

    # Without <label @ERROR>, the other events of the emit go on, and the error is raised when the outermost pass returns.
    data(
      "loop first, batch"  => [%w[a b], "batch"],
      "loop first, record" => [%w[a b], "record"],
      "exit first, record" => [%w[b a], "record"],
    )
    test "without <label @ERROR>, the other events go on until the error is raised" do |(messages, mode)|
      conf = %[
        <match input>
          @type rewrite_tag_filter
          emit_mode #{mode}
          #{rule_conf(pattern: "/^a$/", tag: "s1")}
          #{rule_conf(pattern: "/^b$/", tag: "done")}
        </match>
        <match done>
          @type rewrite_tag_filter_test_collect
          name done
        </match>
      ] + ring_conf([20], sections: 12, error_label: "")
      result, state = run_nested(:fiber) do
        begin
          run_fluentd(conf, "input", messages.map { |message| { "message" => message } })
        rescue Fluent::Plugin::RewriteTagFilterOutput::ReemitLoopError => e
          [e, RewriteTagFilterTestCollectOutput.events.dup]
        end
      end
      assert_kind_of(Fluent::Plugin::RewriteTagFilterOutput::ReemitLoopError, result[0])
      assert_equal([["done", "done", { "message" => "b" }]], result[1])
      assert_reemit_state_is_clean(state)
    end

    # Without <label @ERROR>, another <store> of the out_copy raises an error after the loop is stopped. That error goes
    # back to the input, and the error of the loop is kept in the log.
    test "without <label @ERROR>, the error of a loop is logged when another error goes back to the input" do
      conf = %[
        <match input>
          @type rewrite_tag_filter
          #{rule_conf(pattern: "/.+/", tag: "s1")}
        </match>
        <match s1.** s1>
          @type copy
          <store>
            @type rewrite_tag_filter
            #{rule_conf(pattern: "/.+/", tag: "s1.${tag}")}
          </store>
          <store>
            @type rewrite_tag_filter_test_raise
          </store>
        </match>
      ]
      error, state = run_nested(:thread) do
        begin
          run_fluentd(conf, "input")
          nil
        rescue => e
          e
        end
      end
      assert_kind_of(StandardError, error)
      assert_not_kind_of(Fluent::Plugin::RewriteTagFilterOutput::ReemitLoopError, error)
      assert_equal(1, $log.out.logs.grep(/a loop was stopped in this emit, but another error goes back to the input/).size, $log.out.logs.inspect)
      assert_reemit_state_is_clean(state)
    end

    # Without <label @ERROR>, the error is kept until the outermost pass returns, here of the section before the ring,
    # so that Fluentd logs it once.
    data("thread" => :thread, "fiber" => :fiber)
    test "without <label @ERROR>, the error of a ring is raised once by the outermost pass" do |where|
      conf = %[
        <match input>
          @type rewrite_tag_filter
          #{rule_conf(pattern: "/.+/", tag: "s1")}
        </match>
      ] + ring_conf([20], sections: 12, error_label: "")
      error, state = run_nested(where) do
        begin
          run_fluentd(conf, "input")
          nil
        rescue Fluent::Plugin::RewriteTagFilterOutput::ReemitLoopError => e
          e
        end
      end
      assert_not_nil(error)
      assert_match(/were re-emitted by rewrite_tag_filter 20 times in a row/, error.message)
      assert_equal(1, $log.out.logs.grep(/emit transaction failed/).size, $log.out.logs.grep(/emit transaction failed/).inspect)
      assert_reemit_state_is_clean(state)
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

    def reemit_state(thread = Thread.current)
      state = thread[Fluent::Plugin::RewriteTagFilterOutput::REEMIT_STATE_KEY]
      [state.depths, state.nesting, state.sending_errors, state.error, state.scopes.map { |scope| scope.to_a.map { |value| value.is_a?(Hash) ? value.to_a : value } }]
    end

    # Nothing about an instance is left for the next emit.
    def assert_reemit_state_is_clean(state = reemit_state)
      assert_equal([{}, 0, 0, nil, [[nil, nil, nil, [], [], [], []]]], state)
    end

    def copy_loop_conf(stores, error_label)
      %[
        <match **>
          @type copy
          #{%w[a b c].first(stores).map { |prefix| %[
            <store>
              @type rewrite_tag_filter
              <rule>
                key message
                pattern /.+/
                tag #{prefix}.${tag}
              </rule>
            </store>
          ] }.join}
        </match>
      ] + error_label
    end

    # @ERROR sends the events back to the loop.
    ERROR_LABEL_RELABEL_CONF = %[
      <label @ERROR>
        <match **>
          @type copy
          <store>
            @type rewrite_tag_filter_test_collect
            name error
          </store>
          <store>
            @type relabel
            @label @ROOT
          </store>
        </match>
      </label>
    ]

    def run_in_thread(seconds = 5)
      thread = Thread.new { yield }
      unless thread.join(seconds)
        thread.kill
        flunk("the loop did not end in #{seconds} seconds")
      end
      thread.value
    end

    # Each pass re-emits to every <store>, so if the loop were stopped only at max_reemit_depth, the passes would grow as
    # a tree until each path reaches it: with two stores, one event sent 705,432 events to @ERROR in 22 seconds, and
    # with three, it did not end in 60 seconds.
    data(
      "two stores"                     => [2, :collect],
      "three stores"                   => [3, :collect],
      "two stores, sent back to loop"   => [2, :relabel],
      "three stores, sent back to loop" => [3, :relabel],
    )
    test "a loop through out_copy is stopped once for the whole emit" do |(stores, error)|
      conf = copy_loop_conf(stores, error == :relabel ? ERROR_LABEL_RELABEL_CONF : ERROR_LABEL_CONF)
      events, state = run_in_thread { [run_fluentd(conf, "input"), reemit_state] }
      assert_operator(events.size, :<=, 100)
      assert_equal(["error"], events.map(&:first).uniq)
      # The first path is stopped at max_reemit_depth, as without out_copy.
      assert_equal("#{(["a"] * 10).join(".")}.input", events.first[1])
      assert_reemit_state_is_clean(state)
    end

    # Two rewrite_tag_filter sections upstream of the loop: the stop ends when the tree has ended, so the other record
    # still goes out as before.
    data(EMIT_MODES)
    test "the other events of an upstream rewrite_tag_filter go out as before after a loop through out_copy" do |mode|
      conf = %[
        <match input>
          @type rewrite_tag_filter
          #{rule_conf(pattern: "/.+/", tag: "split")}
        </match>
        <match split>
          @type rewrite_tag_filter
          emit_mode #{mode}
          <rule>
            key k
            pattern /^loop$/
            tag loop
          </rule>
          <rule>
            key k
            pattern /^ok$/
            tag done
          </rule>
        </match>
        <match done>
          @type rewrite_tag_filter_test_collect
          name done
        </match>
      ] + copy_loop_conf(2, ERROR_LABEL_CONF)
      events = run_fluentd(conf, "input", [{ "message" => "a", "k" => "loop" }, { "message" => "b", "k" => "ok" }])
      assert_equal([["done", "done", { "message" => "b", "k" => "ok" }]], events.select { |e| e[0] == "done" })
      assert_operator(events.count { |e| e[0] == "error" }, :<=, 30)
      assert_reemit_state_is_clean
    end

    # Both <store> re-emit to the same section, which is in the loop. One event sent 1,025 events to @ERROR, and about a
    # million with max_reemit_depth 20.
    test "a loop through out_copy whose <store> re-emit to the same section is stopped once" do
      conf = %[
        <match x>
          @type rewrite_tag_filter
          #{rule_conf(pattern: "/.+/", tag: "copy")}
        </match>
        <match copy>
          @type copy
          #{%w[a b].map { %[
            <store>
              @type rewrite_tag_filter
              #{rule_conf(pattern: "/.+/", tag: "x")}
            </store>
          ] }.join}
        </match>
      ] + ERROR_LABEL_CONF
      events, state = run_in_thread { [run_fluentd(conf, "x"), reemit_state] }
      assert_operator(events.size, :<=, 30)
      assert_equal(["error"], events.map(&:first).uniq)
      assert_reemit_state_is_clean(state)
    end

    # The events that another output sends to @ERROR while the loop is stopped are not a part of the loop.
    test "a rewrite_tag_filter in <label @ERROR> routes the events that another output sends there during a loop" do
      conf = %[
        <match **>
          @type copy
          #{%w[a b].map { |prefix| %[
            <store>
              @type rewrite_tag_filter
              #{rule_conf(pattern: "/.+/", tag: "#{prefix}.${tag}")}
            </store>
          ] }.join}
          <store>
            @type rewrite_tag_filter_test_raise
          </store>
        </match>
        <label @ERROR>
          <match routed.**>
            @type rewrite_tag_filter_test_collect
            name routed
          </match>
          <match **>
            @type rewrite_tag_filter
            #{rule_conf(pattern: "/.+/", tag: "routed.${tag}")}
          </match>
        </label>
      ]
      events, state = run_in_thread { [run_fluentd(conf, "input"), reemit_state] }
      assert_equal([], $log.out.logs.grep(/came back to this plugin, so it is dropped/))
      assert_equal(["routed"], events.map(&:first).uniq)
      assert_reemit_state_is_clean(state)
    end

    # A chain that removes one part of the tag on each pass, and is not a part of the loop.
    CHAIN_CONF = %[
      <match done>
        @type rewrite_tag_filter_test_collect
        name chain
      </match>
      <match **>
        @type rewrite_tag_filter
        remove_tag_regexp /^[^.]+\\./
        <rule>
          key message
          pattern /.+/
          tag ${tag}
        </rule>
      </match>
    ]

    test "a chain from another <store> of the out_copy of a loop goes on as before" do
      events = run_fluentd(%[
        <match input>
          @type rewrite_tag_filter
          #{rule_conf(pattern: "/.+/", tag: "x.y.done")}
        </match>
        <match x.y.done>
          @type copy
          <store>
            @type relabel
            @label @LOOP
          </store>
          <store>
            @type relabel
            @label @CHAIN
          </store>
        </match>
        <label @LOOP>
          <match **>
            @type rewrite_tag_filter
            #{rule_conf(pattern: "/.+/", tag: "${tag}", label: "@LOOP")}
          </match>
        </label>
        <label @CHAIN>
          #{CHAIN_CONF}
        </label>
      ] + ERROR_LABEL_CONF, "input")
      assert_equal([["error", "x.y.done", { "message" => "a" }], ["chain", "done", { "message" => "a" }]], events)
      assert_reemit_state_is_clean
    end

    # A filter counts the passes, and the record "side" leaves the loop at the third pass, into a chain.
    data(EMIT_MODES)
    test "a chain that a record starts when it leaves a loop goes on as before" do |mode|
      events = run_fluentd(%[
        <filter loop>
          @type record_transformer
          enable_ruby
          <record>
            n ${record["n"].to_i + 1}
            exit ${record["kind"] == "side" && record["n"].to_i + 1 >= 3 ? "yes" : "no"}
          </record>
        </filter>
        <match loop>
          @type rewrite_tag_filter
          emit_mode #{mode}
          #{rule_conf(key: "exit", pattern: "/^yes$/", tag: "x.y.done")}
          #{rule_conf(pattern: "/.+/", tag: "loop", label: "@ROOT")}
        </match>
      ] + CHAIN_CONF + ERROR_LABEL_CONF, "loop", [{ "message" => "a", "kind" => "loop" }, { "message" => "b", "kind" => "side" }])
      assert_equal([["chain", "done"], ["error", "loop"]], events.map { |name, tag, _record| [name, tag] }.sort)
      assert_equal("b", events.find { |name, _tag, _record| name == "chain" }[2]["message"])
      assert_reemit_state_is_clean
    end

    # A record that leaves a loop, and loops in another section, has its own loop, as before.
    data(EMIT_MODES)
    test "a loop after a stopped loop without out_copy has its own depth" do |mode|
      events = run_fluentd(%[
        <match a>
          @type rewrite_tag_filter
          #{rule_conf(pattern: "/.+/", tag: "b")}
        </match>
        <match b>
          @type rewrite_tag_filter
          emit_mode #{mode}
          #{rule_conf(key: "k", pattern: "/^loop$/", tag: "a")}
          #{rule_conf(key: "k", pattern: "/^q$/", tag: "q")}
        </match>
        <match q q.**>
          @type rewrite_tag_filter
          #{rule_conf(pattern: "/.+/", tag: "q.${tag}")}
        </match>
      ] + ERROR_LABEL_CONF, "a", [{ "message" => "a", "k" => "loop" }, { "message" => "b", "k" => "q" }])
      assert_equal([["error", "a", { "message" => "a", "k" => "loop" }],
                    ["error", (["q"] * 11).join("."), { "message" => "b", "k" => "q" }]], events)
      assert_reemit_state_is_clean
    end

    test "an error from <label @ERROR> leaves nothing for the next emit" do
      conf = %[
        <match ok>
          @type rewrite_tag_filter_test_collect
          name ok
        </match>
      ] + copy_loop_conf(2, %[
        <label @ERROR>
          <match **>
            @type rewrite_tag_filter_test_raise
            standard_error false
          </match>
        </label>
      ])
      assert_raise(RewriteTagFilterTestRaiseOutput::Error) do
        run_fluentd(conf, "input")
      end
      assert_reemit_state_is_clean
      Fluent::Engine.root_agent.event_router.emit("ok", event_time, { "message" => "a" })
      assert_equal([["ok", "ok", { "message" => "a" }]], RewriteTagFilterTestCollectOutput.events)
    end

    test "without <label @ERROR>, a loop through out_copy raises the error once" do
      error = assert_raise(Fluent::Plugin::RewriteTagFilterOutput::ReemitLoopError) do
        run_fluentd(copy_loop_conf(2, ""), "input")
      end
      assert_match(/events came back to this plugin 10 times in a row/, error.message)
      assert_reemit_state_is_clean
    end

    test "in record mode, each record of a stream loops max_reemit_depth times, as before" do
      events = run_fluentd(%[
        <match **>
          @type rewrite_tag_filter
          emit_mode record
          <rule>
            key message
            pattern /.+/
            tag new.${tag}
          </rule>
        </match>
      ] + ERROR_LABEL_CONF, "input", [{ "message" => "a" }, { "message" => "b" }])
      tag = "#{(["new"] * 10).join(".")}.input"
      assert_equal([["error", tag, { "message" => "a" }], ["error", tag, { "message" => "b" }]], events)
    end

    test "a rewrite_tag_filter in <label @ERROR> routes the events of a stopped loop" do
      events = run_fluentd(loop_conf("batch", "@ROOT", error_label: false) + %[
        <label @ERROR>
          <match routed.**>
            @type rewrite_tag_filter_test_collect
            name routed
          </match>
          <match **>
            @type rewrite_tag_filter
            <rule>
              key message
              pattern /.+/
              tag routed.${tag}
            </rule>
          </match>
        </label>
      ], "input", [{ "message" => "a" }, { "message" => "b" }])
      assert_equal([["routed", "routed.input", { "message" => "a" }], ["routed", "routed.input", { "message" => "b" }]], events)
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
