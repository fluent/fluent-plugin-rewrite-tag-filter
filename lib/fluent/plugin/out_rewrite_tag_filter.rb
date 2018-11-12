require "fluent/plugin/output"
require "fluent/config/regexp_type"

class Fluent::Plugin::RewriteTagFilterOutput < Fluent::Plugin::Output
  Fluent::Plugin.register_output('rewrite_tag_filter', self)

  helpers :event_emitter, :record_accessor

  desc 'Capitalize letter for every matched regex backreference.'
  config_param :capitalize_regex_backreference, :bool, :default => false
  desc 'Remove tag prefix for tag placeholder.'
  config_param :remove_tag_prefix, :string, :default => nil
  desc 'Override hostname command for placeholder.'
  config_param :hostname_command, :string, :default => 'hostname'

  config_section :rule, param_name: :rules, multi: true do
    desc "The field name to which the regular expression is applied"
    config_param :key, :string
    desc "The regular expression"
    config_param :pattern, :regexp
    desc "New tag"
    config_param :tag, :string
    desc "If true, rewrite tag when unmatch pattern"
    config_param :invert, :bool, default: false
  end

  MATCH_OPERATOR_EXCLUDE = '!'

  def configure(conf)
    super

    @rewriterules = []
    rewriterule_names = []
    @hostname = `#{@hostname_command}`.chomp

    @rules.each do |rule|
      unless rule.tag.match(/\$\{tag_parts\[\d\.\.\.?\d\]\}/).nil? or rule.tag.match(/__TAG_PARTS\[\d\.\.\.?\d\]__/).nil?
        raise Fluent::ConfigError, "${tag_parts[n]} and __TAG_PARTS[n]__ placeholder does not support range specify at #{rule}"
      end

      invert = rule.invert ? MATCH_OPERATOR_EXCLUDE : ""
      @rewriterules.push([record_accessor_create(rule.key), rule.pattern, invert, rule.tag])
      rewriterule_names.push(rule.key + invert + rule.pattern.to_s)
      log.info "adding rewrite_tag_filter rule: #{rule.key} #{@rewriterules.last}"
    end

    if conf.keys.any? {|k| k.start_with?("rewriterule") }
      raise Fluent::ConfigError, "\"rewriterule<num>\" support has been dropped. Use <rule> section instead."
    end

    unless @rewriterules.length > 0
      raise Fluent::ConfigError, "missing rewriterules"
    end

    unless @rewriterules.length == rewriterule_names.uniq.length
      raise Fluent::ConfigError, "duplicated rewriterules found #{@rewriterules.inspect}"
    end

    unless @remove_tag_prefix.nil?
      @remove_tag_prefix = /^#{Regexp.escape(@remove_tag_prefix)}\.?/
    end
  end

  def multi_workers_ready?
    true
  end

  def process(tag, es)
    placeholder = get_placeholder(tag)
    es.each do |time, record|
      rewrited_tag = rewrite_tag(tag, record, placeholder)
      if rewrited_tag.nil? || tag == rewrited_tag
        log.trace("rewrite_tag_filter: tag has not been rewritten", record)
        next
      end
      router.emit(rewrited_tag, time, record)
    end
  end

  def rewrite_tag(tag, record, placeholder)
    @rewriterules.each do |record_accessor, regexp, match_operator, rewritetag|
      rewritevalue = record_accessor.call(record).to_s
      next if rewritevalue.empty? && match_operator != MATCH_OPERATOR_EXCLUDE
      last_match = regexp_last_match(regexp, rewritevalue)
      case match_operator
      when MATCH_OPERATOR_EXCLUDE
        next if last_match
      else
        next if !last_match
        backreference_table = get_backreference_table(last_match.captures)
        rewritetag = rewritetag.gsub(/\$\d+/, backreference_table)
      end
      rewritetag = rewritetag.gsub(/(\${[a-z_]+(\[[0-9]+\])?}|__[A-Z_]+__)/) do
        log.warn "rewrite_tag_filter: unknown placeholder found. :placeholder=>#{$1} :tag=>#{tag} :rewritetag=>#{rewritetag}" unless placeholder.include?($1)
        placeholder[$1]
      end
      return rewritetag
    end
    return nil
  end

  def regexp_last_match(regexp, rewritevalue)
    if rewritevalue.valid_encoding?
      regexp.match(rewritevalue)
    else
      regexp.match(rewritevalue.scrub('?'))
    end
  end

  def get_backreference_table(elements)
    hash_table = Hash.new
    elements.each.with_index(1) do |value, index|
      hash_table["$#{index}"] = @capitalize_regex_backreference ? value.capitalize : value
    end
    return hash_table
  end

  def get_placeholder(tag)
    tag = tag.sub(@remove_tag_prefix, '') if @remove_tag_prefix

    result = {
      '__HOSTNAME__' => @hostname,
      '${hostname}' => @hostname,
      '__TAG__' => tag,
      '${tag}' => tag,
    }

    tag.split('.').each_with_index do |t, idx|
      result.store("${tag_parts[#{idx}]}", t)
      result.store("__TAG_PARTS[#{idx}]__", t)
    end

    return result
  end
end

