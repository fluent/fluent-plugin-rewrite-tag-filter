require 'helper'

class RewriteTagFilterOutputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
  end
  
  CONFIG = %[
    rewriterule1 domain ^www\.google\.com$ site.Google
    rewriterule2 domain ^news\.google\.com$ site.GoogleNews
  ]

  def create_driver(conf=CONFIG,tag='test')
    Fluent::Test::OutputTestDriver.new(Fluent::RewriteTagFilterOutput, tag).configure(conf)
  end

  def test_configure
    assert_raise(Fluent::ConfigError) {
      d = create_driver('')
    }
    d = create_driver %[
      rewriterule1 domain ^www.google.com$ site.Google
      rewriterule2 domain ^news.google.com$ site.GoogleNews
    ]
    d.instance.inspect
    assert_equal 'domain ^www.google.com$ site.Google', d.instance.rewriterule1
    assert_equal 'domain ^news.google.com$ site.GoogleNews', d.instance.rewriterule2
  end

  def test_emit
    d1 = create_driver(CONFIG, 'input.access')
    time = Time.parse("2012-01-02 13:14:15").to_i
    d1.run do
      d1.emit({'domain' => 'www.google.com', 'agent' => 'Googlebot', 'response_time' => 1000000})
      d1.emit({'domain' => 'news.google.com', 'agent' => 'Googlebot-Mobile', 'response_time' => 900000})
    end
    emits = d1.emits
    assert_equal 2, emits.length
    assert_equal 'site.Google', emits[0][0] # tag
    assert_equal 'site.GoogleNews', emits[1][0] # tag
    assert_equal 'news.google.com', emits[1][2]['domain']
  end
end

