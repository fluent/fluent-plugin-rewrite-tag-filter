require 'helper'

class RewriteTagFilterOutputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
  end

  CONFIG = %[
    rewriterule1 domain ^www\.google\.com$ site.Google
    rewriterule2 domain ^news\.google\.com$ site.GoogleNews
    rewriterule3 agent .* Mac OS X .* agent.MacOSX
    rewriterule4 agent (Googlebot|CustomBot)-([a-zA-Z]+) agent.$1-$2
    rewriterule5 domain ^(tagtest)\.google\.com$ site.${tag}.$1
  ]

  # aggresive test
  # indentation, comment, capitalize_regex_backreference, regex with space aside.
  # [DEPLICATED] Use ^....$ pattern for partial word match instead of double-quote-delimiter.
  CONFIG_INDENT_SPACE_AND_CAPITALIZE_OPTION = %[
    capitalize_regex_backreference yes
    rewriterule1 domain ^www\.google\.com$                  site.Google # some comment
    rewriterule2 domain ^(news)\.(google)\.com$             site.$2$1
    rewriterule3 agent  ^.* Mac OS X .*$                    agent.MacOSX
    rewriterule4 agent  "(Googlebot|CustomBot)-([a-zA-Z]+)" agent.$1-$2
  ]

  # remove_tag_prefix test
  CONFIG_REMOVE_TAG_PREFIX = %[
    rewriterule1 domain ^www\.google\.com$ ${tag}
    remove_tag_prefix input
  ]

  # remove_tag_prefix test2
  CONFIG_REMOVE_TAG_PREFIX_WITH_DOT = %[
    rewriterule1 domain ^www\.google\.com$ ${tag}
    remove_tag_prefix input.
  ]

  # hostname placeholder test
  CONFIG_SHORT_HOSTNAME = %[
    rewriterule1 domain ^www\.google\.com$ ${hostname}
    remove_tag_prefix input
    hostname_command hostname -s
  ]

  # '!' character (exclamation mark) to specify a non-matching pattern
  CONFIG_NON_MATCHING = %[
    rewriterule1 domain !^www\..+$ not_start_with_www
    rewriterule2 domain ^www\..+$ start_with_www
  ]

  # jump of index
  CONFIG_JUMP_INDEX = %[
    rewriterule10 domain ^www\.google\.com$ site.Google
    rewriterule20 domain ^news\.google\.com$ site.GoogleNews
  ]

  # split by tag
  CONFIG_SPLIT_BY_TAG = %[
    rewriterule1 user_name ^Lynn Minmay$ vip.${tag_parts[1]}.remember_love
    rewriterule2 user_name ^Harlock$ ${tag_parts[2]}.${tag_parts[0]}.${tag_parts[1]}
    rewriterule3 world ^(alice|chaos)$ application.${tag_parts[0]}.$1_server
    rewriterule4 world ^[a-z]+$ application.${tag_parts[1]}.future_server
  ]

  # test for invalid byte sequence in UTF-8 error
  CONFIG_INVALID_BYTE = %[
    rewriterule1 client_name (.+) app.$1
  ]

  def create_driver(conf, tag = 'test')
    Fluent::Test::OutputTestDriver.new(Fluent::RewriteTagFilterOutput, tag).configure(conf)
  end

  sub_test_case "configure" do
    data("empty" => "",
         "missing regexp" => "rewriterule1 foo",
         "missing new tag" => "rewriterule1 foo foo",
         "not regext 1" => "rewriterule1 hoge hoge.${tag_parts[0..2]}.__TAG_PARTS[0..2]__",
         "not regext 2" => "rewriterule1 fuga fuga.${tag_parts[1...2]}.__TAG_PARTS[1...2]__")
    test "invalid" do |conf|
      assert_raise(Fluent::ConfigError) {
        create_driver(conf)
      }
    end

    test "valid" do
      d = create_driver %[
        rewriterule1 domain ^www.google.com$ site.Google
        rewriterule2 domain ^news.google.com$ site.GoogleNews
      ]
      assert_equal 'domain ^www.google.com$ site.Google', d.instance.config['rewriterule1']
      assert_equal 'domain ^news.google.com$ site.GoogleNews', d.instance.config['rewriterule2']
    end
  end

  sub_test_case "line style config" do
    test "emit simple" do
      d1 = create_driver(CONFIG, 'input.access')
      d1.run do
        d1.emit({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
        d1.emit({'domain' => 'news.google.com', 'path' => '/', 'agent' => 'Googlebot-Mobile', 'response_time' => 900000})
        d1.emit({'domain' => 'map.google.com', 'path' => '/', 'agent' => 'Macintosh; Intel Mac OS X 10_7_4', 'response_time' => 900000})
        d1.emit({'domain' => 'labs.google.com', 'path' => '/', 'agent' => 'Mozilla/5.0 Googlebot-FooBar/2.1', 'response_time' => 900000})
        d1.emit({'domain' => 'tagtest.google.com', 'path' => '/', 'agent' => 'Googlebot', 'response_time' => 900000})
        d1.emit({'domain' => 'noop.example.com'}) # to be ignored
      end
      emits = d1.emits
      assert_equal 5, emits.length
      assert_equal 'site.Google', emits[0][0] # tag
      assert_equal 'site.GoogleNews', emits[1][0] # tag
      assert_equal 'news.google.com', emits[1][2]['domain']
      assert_equal 'agent.MacOSX', emits[2][0] #tag
      assert_equal 'agent.Googlebot-FooBar', emits[3][0] #tag
      assert_equal 'site.input.access.tagtest', emits[4][0] #tag
    end

    test "indent and capitalize option" do
      d1 = create_driver(CONFIG_INDENT_SPACE_AND_CAPITALIZE_OPTION, 'input.access')
      d1.run do
        d1.emit({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
        d1.emit({'domain' => 'news.google.com', 'path' => '/', 'agent' => 'Googlebot-Mobile', 'response_time' => 900000})
        d1.emit({'domain' => 'map.google.com', 'path' => '/', 'agent' => 'Macintosh; Intel Mac OS X 10_7_4', 'response_time' => 900000})
        d1.emit({'domain' => 'labs.google.com', 'path' => '/', 'agent' => 'Mozilla/5.0 Googlebot-FooBar/2.1', 'response_time' => 900000})
      end
      emits = d1.emits
      assert_equal 4, emits.length
      assert_equal 'site.Google', emits[0][0] # tag
      assert_equal 'site.GoogleNews', emits[1][0] # tag
      assert_equal 'news.google.com', emits[1][2]['domain']
      assert_equal 'agent.MacOSX', emits[2][0] #tag
      assert_equal 'agent.Googlebot-Foobar', emits[3][0] #tag
    end

    test "remove_tag_prefix" do
      d1 = create_driver(CONFIG_REMOVE_TAG_PREFIX, 'input.access')
      d1.run do
        d1.emit({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
      end
      emits = d1.emits
      assert_equal 1, emits.length
      assert_equal 'access', emits[0][0] # tag
    end

    test "remove_tag_prefix with dot" do
      d1 = create_driver(CONFIG_REMOVE_TAG_PREFIX_WITH_DOT, 'input.access')
      d1.run do
        d1.emit({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
      end
      emits = d1.emits
      assert_equal 1, emits.length
      assert_equal 'access', emits[0][0] # tag
    end

    test "short_hostname" do
      d1 = create_driver(CONFIG_SHORT_HOSTNAME, 'input.access')
      d1.run do
        d1.emit({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
      end
      emits = d1.emits
      assert_equal 1, emits.length
      assert_equal `hostname -s`.chomp, emits[0][0] # tag
    end

    test "non_matching" do
      d1 = create_driver(CONFIG_NON_MATCHING, 'input.access')
      d1.run do
        d1.emit({'domain' => 'www.google.com'})
        d1.emit({'path' => '/'})
        d1.emit({'domain' => 'maps.google.com'})
      end
      emits = d1.emits
      assert_equal 3, emits.length
      assert_equal 'start_with_www', emits[0][0] # tag
      assert_equal 'not_start_with_www', emits[1][0] # tag
      assert_equal 'not_start_with_www', emits[2][0] # tag
    end

    test "jump_index" do
      d1 = create_driver(CONFIG_JUMP_INDEX, 'input.access')
      d1.run do
        d1.emit({'domain' => 'www.google.com', 'path' => '/', 'agent' => 'Googlebot', 'response_time' => 1000000})
        d1.emit({'domain' => 'news.google.com', 'path' => '/', 'agent' => 'Googlebot', 'response_time' => 900000})
      end
      emits = d1.emits
      assert_equal 2, emits.length
      assert_equal 'site.Google', emits[0][0] # tag
      assert_equal 'site.GoogleNews', emits[1][0] # tag
    end

    test "split_by_tag" do
      d1 = create_driver(CONFIG_SPLIT_BY_TAG, 'game.production.api')
      d1.run do
        d1.emit({'user_id' => '10000', 'world' => 'chaos', 'user_name' => 'gamagoori'})
        d1.emit({'user_id' => '10001', 'world' => 'chaos', 'user_name' => 'sanageyama'})
        d1.emit({'user_id' => '10002', 'world' => 'nehan', 'user_name' => 'inumuta'})
        d1.emit({'user_id' => '77777', 'world' => 'space', 'user_name' => 'Lynn Minmay'})
        d1.emit({'user_id' => '99999', 'world' => 'space', 'user_name' => 'Harlock'})
      end
      emits = d1.emits
      assert_equal 5, emits.length
      assert_equal 'application.game.chaos_server', emits[0][0]
      assert_equal 'application.game.chaos_server', emits[1][0]
      assert_equal 'application.production.future_server', emits[2][0]
      assert_equal 'vip.production.remember_love', emits[3][0]
      assert_equal 'api.game.production', emits[4][0]
    end

    test "invalid byte (UTF-8)" do
      invalid_utf8 = "\xff".force_encoding('UTF-8')
      d1 = create_driver(CONFIG_INVALID_BYTE, 'input.activity')
      d1.run do
        d1.emit({'client_name' => invalid_utf8})
      end
      emits = d1.emits
      assert_equal 1, emits.length
      assert_equal "app.?", emits[0][0]
      assert_equal invalid_utf8, emits[0][2]['client_name']
    end

    test "invalid byte (US-ASCII)" do
      invalid_ascii = "\xff".force_encoding('US-ASCII')
      d1 = create_driver(CONFIG_INVALID_BYTE, 'input.activity')
      d1.run do
        d1.emit({'client_name' => invalid_ascii})
      end
      emits = d1.emits
      assert_equal 1, emits.length
      assert_equal "app.?", emits[0][0]
      assert_equal invalid_ascii, emits[0][2]['client_name']
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
      d = create_driver(config, 'input.access')
      d.run do
        d.emit({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
        d.emit({'domain' => 'news.google.com', 'path' => '/', 'agent' => 'Googlebot-Mobile', 'response_time' => 900000})
        d.emit({'domain' => 'map.google.com', 'path' => '/', 'agent' => 'Macintosh; Intel Mac OS X 10_7_4', 'response_time' => 900000})
        d.emit({'domain' => 'labs.google.com', 'path' => '/', 'agent' => 'Mozilla/5.0 Googlebot-FooBar/2.1', 'response_time' => 900000})
        d.emit({'domain' => 'tagtest.google.com', 'path' => '/', 'agent' => 'Googlebot', 'response_time' => 900000})
        d.emit({'domain' => 'noop.example.com'}) # to be ignored
      end
      emits = d.emits
      assert_equal 5, emits.length
      assert_equal 'site.Google', emits[0][0] # tag
      assert_equal 'site.GoogleNews', emits[1][0] # tag
      assert_equal 'news.google.com', emits[1][2]['domain']
      assert_equal 'agent.MacOSX', emits[2][0] #tag
      assert_equal 'agent.Googlebot-FooBar', emits[3][0] #tag
      assert_equal 'site.input.access.tagtest', emits[4][0] #tag
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
      d = create_driver(config, 'input.access')
      d.run do
        d.emit({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
      end
      emits = d.emits
      assert_equal 1, emits.length
      assert_equal 'access', emits[0][0] # tag
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
      d = create_driver(config, 'input.access')
      d.run do
        d.emit({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
      end
      emits = d.emits
      assert_equal 1, emits.length
      assert_equal 'access', emits[0][0] # tag
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
      d = create_driver(config, 'input.access')
      d.run do
        d.emit({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
      end
      emits = d.emits
      assert_equal 1, emits.length
      assert_equal `hostname -s`.chomp, emits[0][0] # tag
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
      d = create_driver(config, 'input.access')
      d.run do
        d.emit({'domain' => 'www.google.com'})
        d.emit({'path' => '/'})
        d.emit({'domain' => 'maps.google.com'})
      end
      emits = d.emits
      assert_equal 3, emits.length
      assert_equal 'start_with_www', emits[0][0] # tag
      assert_equal 'not_start_with_www', emits[1][0] # tag
      assert_equal 'not_start_with_www', emits[2][0] # tag
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
      d = create_driver(config, 'game.production.api')
      d.run do
        d.emit({'user_id' => '10000', 'world' => 'chaos', 'user_name' => 'gamagoori'})
        d.emit({'user_id' => '10001', 'world' => 'chaos', 'user_name' => 'sanageyama'})
        d.emit({'user_id' => '10002', 'world' => 'nehan', 'user_name' => 'inumuta'})
        d.emit({'user_id' => '77777', 'world' => 'space', 'user_name' => 'Lynn Minmay'})
        d.emit({'user_id' => '99999', 'world' => 'space', 'user_name' => 'Harlock'})
      end
      emits = d.emits
      assert_equal 5, emits.length
      assert_equal 'application.game.chaos_server', emits[0][0]
      assert_equal 'application.game.chaos_server', emits[1][0]
      assert_equal 'application.production.future_server', emits[2][0]
      assert_equal 'vip.production.remember_love', emits[3][0]
      assert_equal 'api.game.production', emits[4][0]
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
      d = create_driver(config, 'input.activity')
      d.run do
        d.emit({'client_name' => invalid_utf8})
      end
      emits = d.emits
      assert_equal 1, emits.length
      assert_equal "app.?", emits[0][0]
      assert_equal invalid_utf8, emits[0][2]['client_name']
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
      d = create_driver(config, 'input.activity')
      d.run do
        d.emit({'client_name' => invalid_ascii})
      end
      emits = d.emits
      assert_equal 1, emits.length
      assert_equal "app.?", emits[0][0]
      assert_equal invalid_ascii, emits[0][2]['client_name']
    end
  end
end
