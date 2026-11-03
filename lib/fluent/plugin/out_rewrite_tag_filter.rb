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
  desc "How many times in a row an event can come back to this plugin before it is stopped as a loop."
  config_param :max_reemit_depth, :integer, default: 10

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
  # A re-emitted event that comes back to this plugin is processed again in the same thread, nested in the emit.
  # It is stopped at max_reemit_depth instead of growing until SystemStackError stops Fluentd.
  # One key for all the instances: a Symbol made per instance would stay in memory after a reload.
  REEMIT_DEPTH_KEY = :rewrite_tag_filter_reemit_depth

  class ReemitLoopError < StandardError; end

  def configure(conf)
    super

    raise Fluent::ConfigError, "max_reemit_depth must be 1 or more" if @max_reemit_depth < 1

    @rewriterules = []
    rewriterule_names = []
    @hostname = `#{@hostname_command}`.chomp

    @rules.each do |rule|
      unless rule.tag.match(/\$\{tag_parts\[\d\.\.\.?\d\]\}/).nil? or rule.tag.match(/__TAG_PARTS\[\d\.\.\.?\d\]__/).nil?
        raise Fluent::ConfigError, "${tag_parts[n]} and __TAG_PARTS[n]__ placeholder does not support range specify at #{rule}"
      end

      invert = rule.invert ? MATCH_OPERATOR_EXCLUDE : ""
      @rewriterules.push([record_accessor_create(rule.key), rule.pattern, invert, rule.tag, rule.label])
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
    # The depth of each instance, for the current fiber. An instance is removed when its depth goes back to 0.
    depths = (Thread.current[REEMIT_DEPTH_KEY] ||= {})
    depth = depths[object_id] || 0
    depths[object_id] = depth + 1
    begin
      if depth < @max_reemit_depth
        rewrite_and_emit(tag, es)
      elsif depth == @max_reemit_depth
        error = ReemitLoopError.new("events came back to this plugin #{depth} times in a row. Check the tag and the label of the rules, or max_reemit_depth")
        # Without <label @ERROR>, raise the error like other errors, so that the input sees it.
        raise error unless error_label_defined?
        # Send them to @ERROR here instead of raising the error, so the events that come back from @ERROR are still
        # counted at this depth.
        es.each { |time, record| router.emit_error_event(tag, time, record, error) }
      else
        # The error events came back too, for example when this plugin is in <label @ERROR>. Sending them to @ERROR
        # again would loop forever, so drop them, and keep the records in the log.
        es.each do |time, record|
          log.error "rewrite_tag_filter: an event sent to @ERROR came back to this plugin, so it is dropped. Check the tag and the label of the rules", tag: tag, time: time, record: record
        end
      end
    ensure
      if depth.zero?
        depths.delete(object_id)
      else
        depths[object_id] = depth
      end
    end
  end

  def rewrite_and_emit(tag, es)
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
    record_accessor.call(record).to_s
  rescue TypeError
    # A nested key whose parent cannot be read with the next key, such as $.log.level for {"log": "text"} or
    # {"log": ["x"]}, is treated as a missing key.
    ''
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

