require 'helper'

class RewriteTagFilterOutputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
  end

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

    test "split by tag" do
      config = %[
        <rule>
          key user_name
          pattern ^Lynn Minmay$
          tag vip.${tag_parts[1]}.remember_love
        </rule>
        <rule>
          key user_name
          pattern ^Harlock$
          tag ${tag_parts[2]}.${tag_parts[0]}.${tag_parts[1]}
        </rule>
        <rule>
          key  world
          pattern ^(alice|chaos)$
          tag application.${tag_parts[0]}.$1_server
        </rule>
        <rule>
          key world
          pattern ^[a-z]+$
          tag application.${tag_parts[1]}.future_server
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
      assert_equal('rewrite_tag_filter: tag has not been rewritten email={"localpart"=>"doe", "domain"=>"example.jp"}',
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
end
