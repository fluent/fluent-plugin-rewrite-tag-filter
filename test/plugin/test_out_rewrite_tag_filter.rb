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

  def create_driver(conf = CONFIG)
    Fluent::Test::Driver::Output.new(Fluent::Plugin::RewriteTagFilterOutput).configure(conf)
  end

  sub_test_case "configure" do
    data("empty" => "",
         "missing regexp" => "rewriterule1 foo",
         "not regexp 1" => "rewriterule1 hoge hoge.${tag_parts[0..2]}.__TAG_PARTS[0..2]__",
         "not regexp 2" => "rewriterule1 fuga fuga.${tag_parts[1...2]}.__TAG_PARTS[1...2]__")
    test "invalid" do |conf|
      assert_raise(Fluent::ConfigError) do
        create_driver(conf)
      end
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
    def test_emit
      d1 = create_driver(CONFIG)
      d1.run(default_tag: "input.access") do
        d1.feed({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
        d1.feed({'domain' => 'news.google.com', 'path' => '/', 'agent' => 'Googlebot-Mobile', 'response_time' => 900000})
        d1.feed({'domain' => 'map.google.com', 'path' => '/', 'agent' => 'Macintosh; Intel Mac OS X 10_7_4', 'response_time' => 900000})
        d1.feed({'domain' => 'labs.google.com', 'path' => '/', 'agent' => 'Mozilla/5.0 Googlebot-FooBar/2.1', 'response_time' => 900000})
        d1.feed({'domain' => 'tagtest.google.com', 'path' => '/', 'agent' => 'Googlebot', 'response_time' => 900000})
        d1.feed({'domain' => 'noop.example.com'}) # to be ignored
      end
      events = d1.events
      assert_equal 5, events.length
      assert_equal 'site.Google', events[0][0] # tag
      assert_equal 'site.GoogleNews', events[1][0] # tag
      assert_equal 'news.google.com', events[1][2]['domain']
      assert_equal 'agent.MacOSX', events[2][0] #tag
      assert_equal 'agent.Googlebot-FooBar', events[3][0] #tag
      assert_equal 'site.input.access.tagtest', events[4][0] #tag
    end

    def test_emit2_indent_and_capitalize_option
      d1 = create_driver(CONFIG_INDENT_SPACE_AND_CAPITALIZE_OPTION)
      d1.run(default_tag: "input.access") do
        d1.feed({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
        d1.feed({'domain' => 'news.google.com', 'path' => '/', 'agent' => 'Googlebot-Mobile', 'response_time' => 900000})
        d1.feed({'domain' => 'map.google.com', 'path' => '/', 'agent' => 'Macintosh; Intel Mac OS X 10_7_4', 'response_time' => 900000})
        d1.feed({'domain' => 'labs.google.com', 'path' => '/', 'agent' => 'Mozilla/5.0 Googlebot-FooBar/2.1', 'response_time' => 900000})
      end
      events = d1.events
      assert_equal 4, events.length
      assert_equal 'site.Google', events[0][0] # tag
      assert_equal 'site.GoogleNews', events[1][0] # tag
      assert_equal 'news.google.com', events[1][2]['domain']
      assert_equal 'agent.MacOSX', events[2][0] #tag
      assert_equal 'agent.Googlebot-Foobar', events[3][0] #tag
    end

    def test_emit3_remove_tag_prefix
      d1 = create_driver(CONFIG_REMOVE_TAG_PREFIX)
      d1.run(default_tag: "input.access") do
        d1.feed({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
      end
      events = d1.events
      assert_equal 1, events.length
      assert_equal 'access', events[0][0] # tag
    end

    def test_emit4_remove_tag_prefix_with_dot
      d1 = create_driver(CONFIG_REMOVE_TAG_PREFIX_WITH_DOT)
      d1.run(default_tag: "input.access") do
        d1.feed({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
      end
      events = d1.events
      assert_equal 1, events.length
      assert_equal 'access', events[0][0] # tag
    end

    def test_emit5_short_hostname
      d1 = create_driver(CONFIG_SHORT_HOSTNAME)
      d1.run(default_tag: "input.access") do
        d1.feed({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
      end
      events = d1.events
      assert_equal 1, events.length
      assert_equal `hostname -s`.chomp, events[0][0] # tag
    end

    def test_emit6_non_matching
      d1 = create_driver(CONFIG_NON_MATCHING)
      d1.run(default_tag: "input.access") do
        d1.feed({'domain' => 'www.google.com'})
        d1.feed({'path' => '/'})
        d1.feed({'domain' => 'maps.google.com'})
      end
      events = d1.events
      assert_equal 3, events.length
      assert_equal 'start_with_www', events[0][0] # tag
      assert_equal 'not_start_with_www', events[1][0] # tag
      assert_equal 'not_start_with_www', events[2][0] # tag
    end

    def test_emit7_jump_index
      d1 = create_driver(CONFIG_JUMP_INDEX)
      d1.run(default_tag: "input.access") do
        d1.feed({'domain' => 'www.google.com', 'path' => '/', 'agent' => 'Googlebot', 'response_time' => 1000000})
        d1.feed({'domain' => 'news.google.com', 'path' => '/', 'agent' => 'Googlebot', 'response_time' => 900000})
      end
      events = d1.events
      assert_equal 2, events.length
      assert_equal 'site.Google', events[0][0] # tag
      assert_equal 'site.GoogleNews', events[1][0] # tag
    end

    def test_emit8_split_by_tag
      d1 = create_driver(CONFIG_SPLIT_BY_TAG)
      d1.run(default_tag: "game.production.api") do
        d1.feed({'user_id' => '10000', 'world' => 'chaos', 'user_name' => 'gamagoori'})
        d1.feed({'user_id' => '10001', 'world' => 'chaos', 'user_name' => 'sanageyama'})
        d1.feed({'user_id' => '10002', 'world' => 'nehan', 'user_name' => 'inumuta'})
        d1.feed({'user_id' => '77777', 'world' => 'space', 'user_name' => 'Lynn Minmay'})
        d1.feed({'user_id' => '99999', 'world' => 'space', 'user_name' => 'Harlock'})
      end
      events = d1.events
      assert_equal 5, events.length
      assert_equal 'application.game.chaos_server', events[0][0]
      assert_equal 'application.game.chaos_server', events[1][0]
      assert_equal 'application.production.future_server', events[2][0]
      assert_equal 'vip.production.remember_love', events[3][0]
      assert_equal 'api.game.production', events[4][0]
    end

    def test_emit9_invalid_byte
      invalid_utf8 = "\xff".force_encoding('UTF-8')
      d1 = create_driver(CONFIG_INVALID_BYTE)
      d1.run(default_tag: "input.activity") do
        d1.feed({'client_name' => invalid_utf8})
      end
      events = d1.events
      assert_equal 1, events.length
      assert_equal "app.?", events[0][0]
      assert_equal invalid_utf8, events[0][2]['client_name']

      invalid_ascii = "\xff".force_encoding('US-ASCII')
      d1 = create_driver(CONFIG_INVALID_BYTE)
      d1.run(default_tag: "input.activity") do
        d1.feed({'client_name' => invalid_ascii})
      end
      events = d1.events
      assert_equal 1, events.length
      assert_equal "app.?", events[0][0]
      assert_equal invalid_ascii, events[0][2]['client_name']
    end

    def test_nested_key_support_with_dot_notation
      conf = %[
        rewriterule1 $.email.domain ^(example)\.(com)$ $2.$1
      ]
      d = create_driver(conf)
      d.run(default_tag: "input") do
        d.feed({ "email" => { "localpart" => "john", "domain" => "example.com" }})
        d.feed({ "email" => { "localpart" => "doe", "domain" => "example.jp" }})
      end
      events = d.events
      assert_equal "com.example", events[0][0]
    end

    def test_nested_key_support_with_bracket_notation
      conf = %[
        rewriterule1 $['email']['domain'] ^(example)\.(com)$ $2.$1
      ]
      d = create_driver(conf)
      d.run(default_tag: "input") do
        d.feed({ "email" => { "localpart" => "john", "domain" => "example.com" }})
        d.feed({ "email" => { "localpart" => "doe", "domain" => "example.jp" }})
      end
      events = d.events
      assert_equal "com.example", events[0][0]
    end
  end
end
