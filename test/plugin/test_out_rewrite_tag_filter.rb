require 'helper'

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

  sub_test_case "a record that the rules cannot read as expected" do
    def run_rules(rules, records, head: "")
      d = create_driver("#{head}\n#{rules}")
      d.run(default_tag: "input") { records.each { |r| d.feed(r) } }
      d
    end

    data(
      "string parent"        => ["$.log.level",       { "log" => "plain" }],
      "string parent, bracket notation" => ["$['log']['level']", { "log" => "plain" }],
      "integer parent"       => ["$.log.level",       { "log" => 1 }],
      "true parent"          => ["$.log.level",       { "log" => true }],
      "array parent"         => ["$.log.level",       { "log" => ["x"] }],
      "string grandparent"   => ["$.log.level.name",  { "log" => { "level" => "x" } }],
      "array index on string" => ["$.log[0]",         { "log" => "plain" }],
    )
    test "nested key whose parent is not a Hash or an Array is treated as a missing key" do |(key, record)|
      rules = rule_conf(key: key, pattern: "/^(.+)$/", tag: "level.$1") + rule_conf(pattern: "/(?!)/", tag: "other", invert: true)
      d = run_rules(rules, [record, record])
      assert_equal(["other", "other"], d.events.map(&:first))
      assert_equal([], d.error_events)
    end

    data(
      "normal rule" => [false, ["jp.hit"]],
      "invert rule" => [true,  ["jp.hit", "jp.hit"]],
    )
    test "ASCII-8BIT value against a pattern with non-ASCII characters" do |(invert, expected)|
      # in_tail without `encoding` gives ASCII-8BIT strings.
      records = [{ "message" => "ok" }, { "message" => "エラー発生".b }, { "message" => "その他のエラー".b }]
      d = run_rules(rule_conf(pattern: "/^エラー/", tag: "jp.hit", invert: invert), records)
      assert_equal(expected, d.events.map(&:first))
    end

    test "ASCII-8BIT capture put into a tag with non-ASCII characters" do
      d = run_rules(rule_conf(pattern: "/^(\\S+)/", tag: "ログ.$1"), [{ "message" => "abc" }, { "message" => "あいう".b }])
      assert_equal(["ログ.abc", "ログ.あいう"], d.events.map(&:first))
      assert_equal([Encoding::UTF_8, Encoding::UTF_8], d.events.map { |t, _, _| t.encoding })
    end

    test "ASCII-only pattern matches the bytes of an ASCII-8BIT value as before" do
      # "あいう" is 9 bytes in UTF-8, and .{3} matches the first 3 bytes, which are "あ".
      d = run_rules(rule_conf(pattern: "/^(.{3})/", tag: "t.$1"), [{ "message" => "あいう".b }])
      assert_equal(["t.あ"], d.events.map(&:first))
    end

    test "ASCII-8BIT value that is not valid UTF-8 is captured as it is" do
      latin1 = "caf\xE9 au lait".b
      d = run_rules(rule_conf(pattern: "/^(\\S+)/", tag: "t.$1"), [{ "message" => latin1 }])
      assert_equal(["t.caf\xE9".b], d.events.map(&:first))
      assert_equal([], d.error_events)
    end

    data(
      "not inverted" => [false, []],
      "inverted"     => [true,  ["jp.other"]],
    )
    test "ASCII-8BIT value that is not valid UTF-8 against a pattern with non-ASCII characters" do |(invert, expected)|
      d = run_rules(rule_conf(pattern: "/^エラー/", tag: "jp.other", invert: invert), [{ "message" => "caf\xE9 au lait".b }])
      assert_equal(expected, d.events.map(&:first))
      assert_equal([], d.error_events)
    end

    test "the record itself keeps its encoding" do
      value = "あいう".b
      d = run_rules(rule_conf(pattern: "/^(あ)/", tag: "jp.$1"), [{ "message" => value }])
      assert_equal(Encoding::ASCII_8BIT, d.events.first[2]["message"].encoding)
    end

    data(EMIT_MODES)
    test "a record that raises an error goes to @ERROR and the others are re-emitted" do |mode|
      # A pattern with non-ASCII characters cannot be matched against a Shift_JIS string.
      bad = { "message" => "エラー".encode("Shift_JIS") }
      d = run_rules(rule_conf(pattern: "/^(エ|o)/", tag: "hit.${tag}"), [{ "message" => "ok" }, bad, { "message" => "ok" }],
                    head: "emit_mode #{mode}")
      assert_equal(["hit.input", "hit.input"], d.events.map(&:first))
      assert_equal(1, d.error_events.size)
      _tag, _time, record, error = d.error_events.first
      assert_kind_of(Encoding::CompatibilityError, error)
      assert_equal(bad, record)
    end
    data(EMIT_MODES)
    test "records for an undefined label go to @ERROR and the others are re-emitted" do |mode|
      d = create_driver(%[
        emit_mode #{mode}
        <rule>
          key message
          pattern /^x$/
          tag new.${tag}
          label @UNDEFINED
        </rule>
        <rule>
          key message
          pattern /^y$/
          tag ok.${tag}
        </rule>
      ])
      # The test driver routes any label, so make the label undefined like the real router does.
      d.instance.define_singleton_method(:get_router) do |label|
        raise ArgumentError, "#{label} label not found" if label == "@UNDEFINED"
        super(label)
      end
      d.run(default_tag: "input") do
        d.feed([[event_time, { "message" => "y" }], [event_time, { "message" => "x" }], [event_time, { "message" => "y" }]])
      end
      assert_equal(["ok.input", "ok.input"], d.events.map(&:first))
      assert_equal([{ "message" => "x" }], d.error_events.map { |_tag, _time, record, _error| record })
    end
  end

  sub_test_case "re-emitted event that comes back to this plugin" do
    test "label \"\" with the unchanged tag is skipped like no label" do
      # remove_tag_prefix lets the startup check pass, and this tag does not have the prefix.
      d = create_driver(%[
        remove_tag_prefix other
        <rule>
          key message
          pattern /.+/
          tag ${tag}
          label ""
        </rule>
      ])
      d.run(default_tag: "input") { d.feed({ "message" => "x" }) }
      assert_equal([], d.events)
    end

    # A router that sends every event back to the plugin, like a <match> that covers the new tag.
    # The block, if given, receives the re-emitted events instead.
    def route_back_to(plugin, &deliver)
      deliver ||= ->(tag, es) { plugin.process(tag, es) }
      router = Object.new
      router.define_singleton_method(:emit) { |tag, time, record| deliver.call(tag, Fluent::OneEventStream.new(time, record)) }
      router.define_singleton_method(:emit_stream) { |tag, es| deliver.call(tag, es) }
      plugin.define_singleton_method(:get_router) { |_label| router }
    end

    data(EMIT_MODES)
    test "a loop is stopped and the events go to @ERROR" do |mode|
      d = create_driver(%[
        emit_mode #{mode}
        <rule>
          key message
          pattern /.+/
          tag new.${tag}
        </rule>
      ])
      route_back_to(d.instance)
      es = Fluent::MultiEventStream.new
      es.add(event_time, { "message" => "a" })
      es.add(event_time, { "message" => "b" })
      d.instance.process("input", es)

      assert_equal(2, d.error_events.size)
      tag, _time, record, error = d.error_events.first
      assert_equal("new." * Fluent::Plugin::RewriteTagFilterOutput::MAX_REEMIT_DEPTH + "input", tag)
      assert_equal({ "message" => "a" }, record)
      assert_kind_of(Fluent::Plugin::RewriteTagFilterOutput::ReemitLoopError, error)
    end

    test "error events that come back from @ERROR are dropped" do
      d = create_driver(%[
        <rule>
          key message
          pattern /.+/
          tag new.${tag}
        </rule>
      ])
      plugin = d.instance
      route_back_to(plugin)
      # Like this plugin in <label @ERROR>: the error events come back to it too.
      error_router = Object.new
      error_router.define_singleton_method(:emit_error_event) { |tag, time, record, _e| plugin.process(tag, Fluent::OneEventStream.new(time, record)) }
      plugin.define_singleton_method(:router) { error_router }
      plugin.process("input", Fluent::OneEventStream.new(event_time, { "message" => "a" }))
      assert_true(d.logs.any? { |l| l.include?("events sent to @ERROR came back to this plugin, so they are dropped") }, d.logs.inspect)
    end

    test "events that come back fewer times than the limit are re-emitted" do
      d = create_driver(%[
        <rule>
          key message
          pattern /.+/
          tag new.${tag}
        </rule>
      ])
      plugin = d.instance
      delivered = []
      # Come back twice, then go to another <match>.
      route_back_to(plugin) do |tag, es|
        tag.count(".") < 2 ? plugin.process(tag, es) : es.each { |_t, r| delivered << [tag, r] }
      end
      plugin.process("input", Fluent::OneEventStream.new(event_time, { "message" => "a" }))
      assert_equal([["new.new.input", { "message" => "a" }]], delivered)
      assert_equal([], d.error_events)
      # The depth of the instance is removed, so it does not stay after a reload.
      depths = Thread.current[Fluent::Plugin::RewriteTagFilterOutput::REEMIT_DEPTH_KEY]
      assert_false(depths.key?(plugin.object_id))
    end
  end
end
