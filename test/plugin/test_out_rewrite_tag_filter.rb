require 'helper'
require 'tmpdir'
require 'shellwords'

class RewriteTagFilterOutputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
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

    # An event whose tag is not changed would come back to the same <match>, so it is not re-emitted, and the later
    # rules are not tried. With a label, it goes to the label (see "relabel").
    data(EMIT_MODES)
    test "an event whose tag is not changed is not re-emitted without a label" do |mode|
      conf = rule_conf(pattern: "/^(.+)$/", tag: "${tag}", head: "emit_mode #{mode}\n@log_level trace") +
             rule_conf(pattern: "/^(a|b)$/", tag: "other")
      d = create_driver(conf)
      d.run(default_tag: "input") do
        d.feed({ "message" => "a" })
        d.feed({ "message" => "b" })
      end
      assert_equal([], d.events)
      assert_equal(2, d.logs.grep(/tag has not been rewritten/).size)
    end

    data(EMIT_MODES)
    test "an event whose tag is not changed after remove_tag_prefix is not re-emitted" do |mode|
      conf = rule_conf(pattern: "/^(.+)$/", tag: "${tag}", head: "emit_mode #{mode}\nremove_tag_prefix other")
      d = create_driver(conf)
      d.run(default_tag: "input") { d.feed({ "message" => "a" }) }
      assert_equal([], d.events)
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
      # Router only called for default label
      mock.proxy(d.instance.router).emit(anything, anything, anything).times(2)
      mock.proxy(d.instance).get_router("odd_label").times(2)
      mock.proxy(d.instance).get_router("even_label").times(2)
      mock.proxy(d.instance).get_router(nil).times(2)
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

    test "relabel in batch mode" do
      conf = %[
          emit_mode batch
          <rule>
            key key
            pattern /^(odd|one)$/
            tag $1
            label odd_label
          </rule>
          <rule>
            key key
            pattern /^(even)$/
            tag shared
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
      # The router of each label is looked up once, and the events are emitted per label and tag.
      mock.proxy(d.instance).get_router("odd_label").times(1) do |router|
        mock.proxy(router).emit_stream("odd", anything).times(1)
        mock.proxy(router).emit_stream("one", anything).times(1)
        router
      end
      mock.proxy(d.instance).get_router("even_label").times(1) do |router|
        mock.proxy(router).emit_stream("shared", anything).times(1)
        router
      end
      mock.proxy(d.instance).get_router(nil).times(1)
      mock.proxy(d.instance.router).emit_stream("zero", anything).times(1)
      mock.proxy(d.instance.router).emit_stream("shared", anything).times(1)
      mock.proxy(d.instance.router).emit(anything, anything, anything).times(0)
      d.run(default_tag: "input") do
        d.feed([[time, { "key" => "odd", "message" => "message-1" }],
                [time, { "key" => "even", "message" => "message-2" }],
                [time, { "key" => "zero", "message" => "message-3" }],
                [time, { "key" => "one", "message" => "message-4" }],
                [time, { "key" => "shared", "message" => "message-5" }],
                [time, { "key" => "odd", "message" => "message-6" }]])
      end
      expected_events = [
        ["odd", time, { "key" => "odd", "message" => "message-1" }],
        ["odd", time, { "key" => "odd", "message" => "message-6" }],
        ["one", time, { "key" => "one", "message" => "message-4" }],
        ["shared", time, { "key" => "even", "message" => "message-2" }],
        ["zero", time, { "key" => "zero", "message" => "message-3" }],
        ["shared", time, { "key" => "shared", "message" => "message-5" }],
      ]
      assert_equal(expected_events, d.events)
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

    # Accessor#keys was added in Fluentd 1.1.0, so Fluentd 1.0 has no reader for it.
    test "is treated as a missing key when the accessor has no keys reader" do
      d = create_driver(rule_conf(key: "$.log.level", pattern: "/^x$/", tag: "not_x", invert: true))
      d.instance.instance_variable_get(:@rewriterules).each do |accessor, *|
        accessor.singleton_class.send(:undef_method, :keys) if accessor.respond_to?(:keys)
      end
      d.run(default_tag: "input") { 2.times { d.feed({ "log" => "plain" }) } }
      assert_equal(["not_x", "not_x"], d.events.map(&:first))
      assert_equal(1, d.logs.grep(/a parent in the nested key cannot be read/).size)
    end

    test "a record that is not a Hash still raises the error as before" do
      d = create_driver(rule_conf(key: "message", pattern: "/(?!)/", tag: "other", invert: true))
      es = Fluent::MultiEventStream.new
      es.add(event_time, ["a", "b"])
      assert_raise(TypeError) { d.run(default_tag: "input") { d.feed("input", es) } }
    end
  end

  # in_tail without `encoding` gives ASCII-8BIT strings.
  sub_test_case "ASCII-8BIT value" do
    def run_rules(rules, records, head: "", tag: "input")
      d = create_driver("#{head}\n#{rules}")
      d.run(default_tag: tag) { records.each { |r| d.feed(r) } }
      d
    end

    data(
      "normal rule" => [false, ["jp.hit"]],
      "invert rule" => [true,  ["jp.hit", "jp.hit"]],
    )
    test "against a pattern with non-ASCII characters" do |(invert, expected)|
      records = [{ "message" => "ok" }, { "message" => "エラー発生".b }, { "message" => "その他のエラー".b }]
      d = run_rules(rule_conf(pattern: "/^エラー/", tag: "jp.hit", invert: invert), records)
      assert_equal(expected, d.events.map(&:first))
      assert_equal([], d.error_events)
    end

    test "against an ASCII-only pattern in UTF-8" do
      d = run_rules(rule_conf(pattern: "/^\\p{Han}/", tag: "han"), [{ "message" => "漢字".b }])
      assert_equal(["han"], d.events.map(&:first))
    end

    test "capture put into a tag with non-ASCII characters" do
      d = run_rules(rule_conf(pattern: "/^(\\S+)/", tag: "ログ.$1"), [{ "message" => "abc" }, { "message" => "あいう".b }])
      assert_equal(["ログ.abc", "ログ.あいう"], d.events.map(&:first))
      assert_equal([Encoding::UTF_8, Encoding::UTF_8], d.events.map { |t, _, _| t.encoding })
    end

    test "capture put into a tag with non-ASCII characters, with an unused capture that is not valid UTF-8" do
      d = run_rules(rule_conf(pattern: "/^(\\S+) (\\S+)/", tag: "ログ.$1"), [{ "message" => "あ caf\xE9".b }])
      assert_equal(["ログ.あ"], d.events.map(&:first))
      assert_equal([], d.error_events)
    end

    test "unknown placeholder is warned once when the tag is built again" do
      d = run_rules(rule_conf(pattern: "/^(\\S+)/", tag: "ログ.$1.${unknown}"), [{ "message" => "あ".b }])
      assert_equal(["ログ.あ."], d.events.map(&:first))
      assert_equal(1, d.logs.grep(/unknown placeholder found/).size)
    end

    data("batch" => "batch", "record" => "record")
    test "unknown placeholder is warned once when the tag cannot be built again" do |mode|
      # ${unknown} comes before $1, so it is reached before "caf\xE9", which is not valid UTF-8, fails to join "ログ".
      d = create_driver(rule_conf(pattern: "/^(.+)$/", tag: "ログ.${unknown}.$1", head: "emit_mode #{mode}"))
      assert_raise(Encoding::CompatibilityError) do
        d.run(default_tag: "input") { d.feed({ "message" => "caf\xE9".b }) }
      end
      assert_equal(1, d.logs.grep(/unknown placeholder found/).size)
      assert_equal([], d.events)
    end

    # The tags below are built from the bytes, as before.
    test "ASCII-only pattern matches the bytes" do
      # "あいう" is 9 bytes in UTF-8, and .{3} matches the first 3 bytes, which are "あ".
      d = run_rules(rule_conf(pattern: "/^(.{3})/", tag: "t.$1"), [{ "message" => "あいう".b }])
      assert_equal(["t.あ".b], d.events.map { |t, _, _| t.b })
    end

    test "captures cut in the middle of a character" do
      d = run_rules(rule_conf(pattern: "/^(.{3})(.)(.*)$/", tag: "out.$1$2$3"), [{ "message" => "あいう".b }])
      assert_equal(["out.あいう".b], d.events.map { |t, _, _| t.b })
      assert_equal([], d.error_events)
    end

    test "capture joined with an ASCII-8BIT tag" do
      d = run_rules(rule_conf(pattern: "/^(.+)$/", tag: "${tag}.$1"), [{ "message" => "あ".b }], tag: "元".b)
      assert_equal(["元.あ".b], d.events.map { |t, _, _| t.b })
      assert_equal([], d.error_events)
    end

    test "value that is not valid UTF-8 is captured as it is" do
      d = run_rules(rule_conf(pattern: "/^(\\S+)/", tag: "t.$1"), [{ "message" => "caf\xE9 au lait".b }])
      assert_equal(["t.caf\xE9".b], d.events.map(&:first))
      assert_equal([], d.error_events)
    end

    test "pattern in ASCII-8BIT matches the bytes" do
      plugin = create_driver(rule_conf(pattern: "/x/", tag: "t")).instance
      assert_not_nil(plugin.send(:regexp_last_match, Regexp.compile("\\xFF".b), "\xFFa".b))
    end

    # A pattern in UTF-8 reads the value as UTF-8.
    data(
      "not inverted" => [false, []],
      "inverted"     => [true,  ["jp.other"]],
    )
    test "value that is not valid UTF-8 against a pattern with non-ASCII characters" do |(invert, expected)|
      d = run_rules(rule_conf(pattern: "/^エラー/", tag: "jp.other", invert: invert), [{ "message" => "caf\xE9 au lait".b }])
      assert_equal(expected, d.events.map(&:first))
      assert_equal([], d.error_events)
    end

    test "bytes that are not valid UTF-8 are replaced with ? in the captures too" do
      d = run_rules(rule_conf(pattern: "/^(\\S+) エラー/", tag: "t.$1"), [{ "message" => "caf\xE9 エラー".b }])
      assert_equal(["t.caf?"], d.events.map(&:first))
    end

    # This changes the tags from before for a capture that is valid UTF-8 and has non-ASCII letters.
    data(
      "first letter, batch"      => ["batch", "émile", "t.Émile"],
      "first letter, record"     => ["record", "émile", "t.Émile"],
      "other letters, batch"     => ["batch", "aÉ", "t.Aé"],
      "other letters, record"    => ["record", "aÉ", "t.Aé"],
    )
    test "capture is capitalized like a UTF-8 one" do |(mode, value, expected)|
      d = run_rules(rule_conf(pattern: "/^(\\S+)/", tag: "t.$1"), [{ "message" => value.b }, { "message" => value }],
                    head: "capitalize_regex_backreference yes\nemit_mode #{mode}")
      assert_equal([expected.b, expected.b], d.events.map { |t, _, _| t.b })
      assert_equal([], d.error_events)
    end

    data(EMIT_MODES)
    test "capture that is not valid UTF-8 has only its ASCII letters capitalized, as before" do |mode|
      d = run_rules(rule_conf(pattern: "/^(\\S+)/", tag: "t.$1"), [{ "message" => "caf\xC9 AU".b }, { "message" => "\xE9COLE".b }],
                    head: "capitalize_regex_backreference yes\nemit_mode #{mode}")
      assert_equal(["t.Caf\xC9".b, "t.\xE9cole".b], d.events.map { |t, _, _| t.b })
      assert_equal([], d.error_events)
    end

    test "the record itself keeps its encoding" do
      d = run_rules(rule_conf(pattern: "/^(あ)/", tag: "jp.$1"), [{ "message" => "あいう".b }])
      assert_equal(Encoding::ASCII_8BIT, d.events.first[2]["message"].encoding)
    end
  end
end
