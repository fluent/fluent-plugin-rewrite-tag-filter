require "fluent/plugin/output"
require "fluent/config/regexp_type"

class Fluent::Plugin::RewriteTagFilterOutput < Fluent::Plugin::Output
  Fluent::Plugin.register_output('rewrite_tag_filter', self)

  helpers :event_emitter, :record_accessor

  desc 'Capitalize letter for every matched regex backreference.'
  config_param :capitalize_regex_backreference, :bool, :default => false
  desc 'Remove tag prefix for tag placeholder.'
  config_param :remove_tag_prefix, :string, :default => nil
  desc "Remove tag regexp for tag placeholder."
  config_param :remove_tag_regexp, :regexp, default: nil
  desc 'Override hostname command for placeholder.'
  config_param :hostname_command, :string, :default => 'hostname'
  desc "The emit mode. If `batch`, this plugin will emit events per rewritten tag."
  config_param :emit_mode, :enum, list: [:record, :batch], default: :batch

  config_section :rule, param_name: :rules, multi: true do
    desc "The field name to which the regular expression is applied"
    config_param :key, :string
    desc "The regular expression"
    config_param :pattern, :regexp
    desc "New tag"
    config_param :tag, :string
    desc "New label. If specified, label can be changed per-rule."
    config_param :label, :string, default: nil
    desc "If true, rewrite tag when unmatch pattern"
    config_param :invert, :bool, default: false
  end

  MATCH_OPERATOR_EXCLUDE = '!'

  def configure(conf)
    super

    @rewriterules = []
    rewriterule_names = []
    @rule_keys = {}
    @unreadable_key_warned = {}
    @hostname = `#{@hostname_command}`.chomp

    @rules.each do |rule|
      unless rule.tag.match(/\$\{tag_parts\[\d\.\.\.?\d\]\}/).nil? or rule.tag.match(/__TAG_PARTS\[\d\.\.\.?\d\]__/).nil?
        raise Fluent::ConfigError, "${tag_parts[n]} and __TAG_PARTS[n]__ placeholder does not support range specify at #{rule}"
      end

      invert = rule.invert ? MATCH_OPERATOR_EXCLUDE : ""
      @rewriterules.push([record_accessor_create(rule.key), rule.pattern, invert, rule.tag, rule.label])
      @rule_keys[@rewriterules.last.first] = rule.key
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

    if @remove_tag_prefix && @remove_tag_regexp
      raise Fluent::ConfigError, "remove_tag_prefix and remove_tag_regexp are exclusive"
    end

    unless @remove_tag_prefix.nil?
      @remove_tag_regexp = /^#{Regexp.escape(@remove_tag_prefix)}\.?/
    end

    @batch_mode = @emit_mode == :batch
  end

  def multi_workers_ready?
    true
  end

  def get_router(tgt_label)
    label_router = if tgt_label.nil? || tgt_label.empty?
        router
    else
        event_emitter_router(tgt_label)
    end
    #log.trace "Got router for #{tgt_label}: #{!label_router.nil?}"
    return label_router
  end

  # A label that is not defined raises ArgumentError when its router is looked up. With <label @ERROR>, send only the
  # records for that label to @ERROR, so the other records are re-emitted and not sent to @ERROR twice. Without it,
  # raise the error as before, so that the input sees it.
  def get_router_or_emit_errors(label)
    get_router(label)
  rescue ArgumentError => e
    raise unless error_label_defined?
    yield e
    nil
  end

  def error_label_defined?
    root_agent = Fluent::Engine.root_agent
    return false if root_agent.nil?
    root_agent.find_label(Fluent::RootAgent::ERROR_LABEL)
    true
  rescue ArgumentError
    false
  end

  def process(tag, es)
    placeholder = get_placeholder(tag)
    new_event_streams =  Hash.new {|hh, kk| hh[kk] = Hash.new {|h, k| h[k] = Fluent::MultiEventStream.new }}if @batch_mode

    es.each do |time, record|
      rewrited_tag, rewrited_label  = rewrite_tag(tag, record, placeholder)
      if (rewrited_tag.nil? || tag == rewrited_tag) && rewrited_label.nil?
        log.trace("rewrite_tag_filter: tag has not been rewritten", record)
        next
      end
      rewrited_tag = tag if rewrited_tag.nil?
      if new_event_streams.nil?
        labeled_router = get_router_or_emit_errors(rewrited_label) { |e| router.emit_error_event(tag, time, record, e) }
        labeled_router.emit(rewrited_tag, time, record) if labeled_router
      else
        new_event_streams[rewrited_label][rewrited_tag].add(time, record)
      end
    end
    if !new_event_streams.nil?
      new_event_streams.each do |rewrited_label, label_event_streams |
        labeled_router = get_router_or_emit_errors(rewrited_label) do |e|
          label_event_streams.each_value { |new_es| new_es.each { |time, record| router.emit_error_event(tag, time, record, e) } }
        end
        next unless labeled_router
        label_event_streams.each do |rewrited_tag, new_es|
            labeled_router.emit_stream(rewrited_tag, new_es)
        end
      end
    end
  end

  def rewrite_tag(tag, record, placeholder)
    @rewriterules.each do |record_accessor, regexp, match_operator, rewritetag, rewritelabel|
      rewritevalue = read_value(record_accessor, record)
      next if rewritevalue.empty? && match_operator != MATCH_OPERATOR_EXCLUDE
      last_match = regexp_last_match(regexp, rewritevalue)
      backreference_table = nil
      case match_operator
      when MATCH_OPERATOR_EXCLUDE
        next if last_match
      else
        next if !last_match
        backreference_table = get_backreference_table(last_match.captures)
      end
      return expand_tag(rewritetag, backreference_table, placeholder, tag), rewritelabel
    end
    return nil, nil
  end

  def expand_tag(rewritetag, backreference_table, placeholder, tag)
    # Backreferences and placeholders are expanded in one pass, so text taken
    # from a record can never turn into a placeholder.
    rewritetag.gsub(/(\$\d+)|(\${[a-z_]+(?:\[[0-9]+\])?}|__TAG_PARTS\[[0-9]+\]__|__[A-Z_]+?__)/) do
      if $1
        # An invert rule has no captures, so "$1" stays as it is written.
        backreference_table ? backreference_table[$1] : $1
      else
        log.warn "rewrite_tag_filter: unknown placeholder found. :placeholder=>#{$2} :tag=>#{tag} :rewritetag=>#{rewritetag}" unless placeholder.include?($2)
        placeholder[$2]
      end
    end
  end

  def read_value(record_accessor, record)
    value = begin
      record_accessor.call(record)
    rescue TypeError => e
      # A nested key whose parent cannot be read with the next key, such as $.log.level for {"log": "text"} or
      # {"log": ["x"]}, is treated as a missing key. Accessor#keys is an Array only for a nested key. Other errors, such
      # as a top-level key for a record that is not a Hash, are raised as before.
      raise unless record.is_a?(Hash) && record_accessor.keys.is_a?(Array)
      warn_unreadable_key(record_accessor, e)
      nil
    end
    value.to_s
  end

  # Logged once for each rule, so that the log is not flooded. Two threads may both log it, which is harmless.
  def warn_unreadable_key(record_accessor, error)
    return if @unreadable_key_warned[record_accessor]
    @unreadable_key_warned[record_accessor] = true
    log.warn "rewrite_tag_filter: a parent in the nested key cannot be read with the next key, so the key is treated as missing. This is logged once for each rule", key: @rule_keys[record_accessor], error: error.message
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
    tag = tag.sub(@remove_tag_regexp, '') if @remove_tag_regexp

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

