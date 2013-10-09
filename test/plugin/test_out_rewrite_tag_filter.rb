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

  CONFIG_USE_OF_FIRST_MATCH_TAG_REGEXP = %[
    use_of_first_match_tag_regexp [a-z_]+\.([a-z_]+)\.
    rewriterule1 type ^[a-z_]+$ api.${tag}.warrior
  ]

  def create_driver(conf=CONFIG,tag='test')
    Fluent::Test::OutputTestDriver.new(Fluent::RewriteTagFilterOutput, tag).configure(conf)
  end

  def test_configure
    assert_raise(Fluent::ConfigError) {
      d = create_driver('')
    }
    assert_raise(Fluent::ConfigError) {
      d = create_driver('rewriterule1 foo')
    }
    assert_raise(Fluent::ConfigError) {
      d = create_driver('rewriterule1 foo foo')
    }
    d = create_driver %[
      rewriterule1 domain ^www.google.com$ site.Google
      rewriterule2 domain ^news.google.com$ site.GoogleNews
    ]
    puts d.instance.inspect
    assert_equal 'domain ^www.google.com$ site.Google', d.instance.config['rewriterule1']
    assert_equal 'domain ^news.google.com$ site.GoogleNews', d.instance.config['rewriterule2']
  end

  def test_emit
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
    p emits[0]
    assert_equal 'site.Google', emits[0][0] # tag
    p emits[1]
    assert_equal 'site.GoogleNews', emits[1][0] # tag
    assert_equal 'news.google.com', emits[1][2]['domain']
    p emits[2]
    assert_equal 'agent.MacOSX', emits[2][0] #tag
    p emits[3]
    assert_equal 'agent.Googlebot-FooBar', emits[3][0] #tag
    p emits[4]
    assert_equal 'site.input.access.tagtest', emits[4][0] #tag
  end

  def test_emit2_indent_and_capitalize_option
    d1 = create_driver(CONFIG_INDENT_SPACE_AND_CAPITALIZE_OPTION, 'input.access')
    d1.run do
      d1.emit({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
      d1.emit({'domain' => 'news.google.com', 'path' => '/', 'agent' => 'Googlebot-Mobile', 'response_time' => 900000})
      d1.emit({'domain' => 'map.google.com', 'path' => '/', 'agent' => 'Macintosh; Intel Mac OS X 10_7_4', 'response_time' => 900000})
      d1.emit({'domain' => 'labs.google.com', 'path' => '/', 'agent' => 'Mozilla/5.0 Googlebot-FooBar/2.1', 'response_time' => 900000})
    end
    emits = d1.emits
    assert_equal 4, emits.length
    p emits[0]
    assert_equal 'site.Google', emits[0][0] # tag
    p emits[1]
    assert_equal 'site.GoogleNews', emits[1][0] # tag
    assert_equal 'news.google.com', emits[1][2]['domain']
    p emits[2]
    assert_equal 'agent.MacOSX', emits[2][0] #tag
    p emits[3]
    assert_equal 'agent.Googlebot-Foobar', emits[3][0] #tag
  end

  def test_emit3_remove_tag_prefix
    d1 = create_driver(CONFIG_REMOVE_TAG_PREFIX, 'input.access')
    d1.run do
      d1.emit({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
    end
    emits = d1.emits
    assert_equal 1, emits.length
    p emits[0]
    assert_equal 'access', emits[0][0] # tag
  end

  def test_emit4_remove_tag_prefix_with_dot
    d1 = create_driver(CONFIG_REMOVE_TAG_PREFIX_WITH_DOT, 'input.access')
    d1.run do
      d1.emit({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
    end
    emits = d1.emits
    assert_equal 1, emits.length
    p emits[0]
    assert_equal 'access', emits[0][0] # tag
  end

  def test_emit5_short_hostname
    d1 = create_driver(CONFIG_SHORT_HOSTNAME, 'input.access')
    d1.run do
      d1.emit({'domain' => 'www.google.com', 'path' => '/foo/bar?key=value', 'agent' => 'Googlebot', 'response_time' => 1000000})
    end
    emits = d1.emits
    assert_equal 1, emits.length
    p emits[0]
    assert_equal `hostname -s`.chomp, emits[0][0] # tag
  end

  def test_emit6_non_matching
    d1 = create_driver(CONFIG_NON_MATCHING, 'input.access')
    d1.run do
      d1.emit({'domain' => 'www.google.com'})
      d1.emit({'path' => '/'})
      d1.emit({'domain' => 'maps.google.com'})
    end
    emits = d1.emits
    assert_equal 3, emits.length
    p emits[0]
    assert_equal 'start_with_www', emits[0][0] # tag
    p emits[1]
    assert_equal 'not_start_with_www', emits[1][0] # tag
    p emits[2]
    assert_equal 'not_start_with_www', emits[2][0] # tag
  end

  def test_emit7_jump_index
    d1 = create_driver(CONFIG_JUMP_INDEX, 'input.access')
    d1.run do
      d1.emit({'domain' => 'www.google.com', 'path' => '/', 'agent' => 'Googlebot', 'response_time' => 1000000})
      d1.emit({'domain' => 'news.google.com', 'path' => '/', 'agent' => 'Googlebot', 'response_time' => 900000})
    end
    emits = d1.emits
    assert_equal 2, emits.length
    p emits[0]
    assert_equal 'site.Google', emits[0][0] # tag
    p emits[1]
    assert_equal 'site.GoogleNews', emits[1][0] # tag
  end

  def test_emit8_first_match_tag
    d1 = create_driver(CONFIG_USE_OF_FIRST_MATCH_TAG_REGEXP, 'hoge_application.production.api')
    d1.run do
      d1.emit({'user_id' => '1000', 'type' => 'warrior', 'name' => 'Richard Costner'})
    end
    emits = d1.emits
    p emits[0]
    assert_equal 1, emits.length
    assert_equal 'api.production.warrior', emits[0][0] # tag

    d2 = create_driver(CONFIG_USE_OF_FIRST_MATCH_TAG_REGEXP, 'hoge_application.development.api')
    d2.run do
      d2.emit({'user_id' => '1000', 'type' => 'warrior', 'name' => 'Mason Smith'})
    end
    emits = d2.emits
    p emits[0]
    assert_equal 1, emits.length
    assert_equal 'api.development.warrior', emits[0][0]

  end

end

