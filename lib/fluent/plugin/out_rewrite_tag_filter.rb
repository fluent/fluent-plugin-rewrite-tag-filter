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
  desc "How many times in a row an event can come back to this plugin. When it has come back this many times, it is stopped as a loop instead of being re-emitted again. 1 to 20."
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
  # Each pass uses the stack of the thread, or of the fiber, which is smaller. With 10 filters and out_copy in the path,
  # the stack of a thread ran out after 84 passes on Windows with Ruby 3.1, and after 157 or more on macOS and Linux,
  # and the stack of a fiber after 67 passes on Linux with Ruby 3.2. max_reemit_depth is counted for each <match>
  # section, so a loop through several sections would pass the events that many times more. So the passes of all the
  # sections nested in the current fiber are stopped at 20 in a row too, the largest max_reemit_depth.
  MAX_REEMIT_DEPTH_LIMIT = 20
  # The events of a stopped loop are sent to @ERROR from the nested emits, where a rewrite_tag_filter in <label @ERROR>
  # may re-emit them. While they are sent, the passes may nest 10 more, so 31 at most.
  ERROR_REEMIT_DEPTH_MARGIN = 10
  # The passes of this plugin nested in the current fiber, for all the instances under one key: a Symbol made per
  # instance would stay in memory after a reload. Nothing about an instance is kept after its outermost pass.
  REEMIT_STATE_KEY = :rewrite_tag_filter_reemit

  # depths: the depth of each instance. nesting: the passes of all the instances nested in the fiber. sending_errors: the
  # nested sends of the events of stopped loops to @ERROR. error: the error of a loop without <label @ERROR>, kept until
  # the outermost pass returns. scopes: see ReemitScope.
  class ReemitState
    attr_reader :depths, :scopes
    attr_accessor :nesting, :sending_errors, :error

    def initialize
      @depths = {}
      @nesting = 0
      @sending_errors = 0
      @error = nil
      @scopes = [ReemitScope.new(nil, nil, nil, [], [], {}.compare_by_identity, [].freeze)]
    end
  end

  # With out_copy in a loop, each pass re-emits to each <store>, and the passes would grow as a tree until each path
  # reaches the depth. So once a loop is stopped, every pass of the loop that starts is stopped too, and does not
  # re-emit: a pass of a section that was in the nested emits when the loop was stopped, or when a pass of the loop was
  # stopped again. A pass of another section goes on as usual, such as a chain out of the loop, or a rewrite_tag_filter
  # in <label @ERROR>.
  # When a pass returns from an emit, and each section stopped in this loop is back at its outermost pass, or out of
  # the nested emits, the loop is over: its events are sent to @ERROR, in a new scope where an event that comes back
  # to a section stopped in the loop is dropped, and the next emits of this pass have a new scope, so that they have
  # their own loop. After this pass, the loop is stopped again until the outermost pass returns, so that another
  # <store> of an out_copy does not start it again.
  # stopped: the error of the stopped loop, if any. other_error: the error of the passes stopped with it. to_error:
  # whether the events go to @ERROR. loop_instances, stopped_instances: the sections of the loop, and those stopped.
  # pending: the events to send to @ERROR, once for each record, which out_copy shares between the <store>.
  # came_back: the sections stopped before the events were sent to @ERROR.
  ReemitScope = Struct.new(:stopped, :other_error, :to_error, :loop_instances, :stopped_instances, :pending, :came_back)

  class ReemitLoopError < StandardError; end

  def configure(conf)
    super

    unless (1..MAX_REEMIT_DEPTH_LIMIT).cover?(@max_reemit_depth)
      raise Fluent::ConfigError, "max_reemit_depth must be between 1 and #{MAX_REEMIT_DEPTH_LIMIT}"
    end

    @rewriterules = []
    rewriterule_names = []
    @rule_keys = {}
    @unreadable_key_warned = {}
    # The command does not run when no rule uses the hostname, so a missing command does not stop the startup.
    uses_hostname = @rules.any? { |rule| rule.tag.include?('${hostname}') || rule.tag.include?('__HOSTNAME__') }
    @hostname = uses_hostname ? `#{@hostname_command}`.chomp : ''

    @rules.each do |rule|
      unless rule.tag.match(/\$\{tag_parts\[\d\.\.\.?\d\]\}/).nil? or rule.tag.match(/__TAG_PARTS\[\d\.\.\.?\d\]__/).nil?
        raise Fluent::ConfigError, "${tag_parts[n]} and __TAG_PARTS[n]__ placeholder does not support range specify at #{rule}"
      end

      invert = rule.invert ? MATCH_OPERATOR_EXCLUDE : ""
      @rewriterules.push([record_accessor_create(rule.key), rule.pattern, invert, rule.tag, rule.label])
      @rule_keys[@rewriterules.last.first] = rule.key
      rewriterule_names.push([rule.key, invert, rule.pattern.to_s])
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

    @label_routers = {}
    @label_lookup_errors = {}
    resolve_label_routers
  end

  def multi_workers_ready?
    true
  end

  def start
    super
    # A label that was not found in configure is looked up again, in case it was added after this plugin.
    @label_lookup_errors = {}
    resolve_label_routers
  end

  # The outputs of this configuration have flushed at shutdown. The events for the labels that still come, from a thread
  # that outlives its plugin, go to the configuration that Fluentd runs, as before this plugin looked up the labels once.
  def after_shutdown
    @label_routers = {}
    @label_lookup_errors = {}
    super
  end

  # Looked up once, as @label is, so during a reload the events go to the labels of this configuration, whose outputs
  # flush at shutdown, not to the new one, which may not be configured or started yet. The error of a label that is not
  # defined is kept. @ERROR is set up after the other <label> sections, so it may be found only in start.
  def resolve_label_routers
    @rules.each do |rule|
      label = rule.label
      next if label.nil? || label.empty? || @label_routers.key?(label) || @label_lookup_errors.key?(label)
      begin
        @label_routers[label] = get_router(label)
      rescue ArgumentError => e
        next if label == Fluent::RootAgent::ERROR_LABEL && !started?
        @label_lookup_errors[label] = e
      end
    end
  end

  # The router of the label of a rule, found in configure or start. For a label that is not defined, the kept error is
  # raised again as a new error, with the frames of the lookup in Fluentd and then the backtrace of this call, so that
  # its location and the logs are as when the label is looked up here.
  def resolved_router(label)
    return router if label.nil? || label.empty?
    labeled_router = @label_routers[label]
    return labeled_router if labeled_router
    if (kept = @label_lookup_errors[label])
      lookup_frames = kept.backtrace.take_while { |line| !line.include?(__FILE__) }
      raise kept.class, kept.message, lookup_frames + caller
    end
    # @ERROR in a <label> before start, and any label after shutdown.
    get_router(label)
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

  # The root agent of the configuration that this plugin belongs to, to see whether it has <label @ERROR>.
  # Fluent::Engine.root_agent is the newest one: a reload replaces it before the old plugins stop. The handler of the
  # router is the root agent, or the label that this plugin is in, and the label knows its root agent. The router of
  # the test driver has no handler.
  def own_root_agent
    handler = router.respond_to?(:emit_error_handler) ? router.emit_error_handler : nil
    handler = handler.root_agent if handler.is_a?(Fluent::Label)
    handler.is_a?(Fluent::RootAgent) ? handler : Fluent::Engine.root_agent
  end

  def process(tag, es)
    state = (Thread.current[REEMIT_STATE_KEY] ||= ReemitState.new)
    scopes = state.scopes
    own_scope = scopes.size
    scope = scopes.last
    depths = state.depths
    depth = depths[object_id] || 0
    depths[object_id] = depth + 1
    nesting = state.nesting
    state.nesting = nesting + 1
    loop_error = nil
    raised = false
    begin
      # Decided when the pass starts, as a loop stopped in its nested emits does not stop a pass that has started.
      stop = if scope.came_back.include?(object_id)
        :came_back
      elsif depth >= @max_reemit_depth
        :depth
      elsif nesting >= MAX_REEMIT_DEPTH_LIMIT + (state.sending_errors.zero? ? 0 : ERROR_REEMIT_DEPTH_MARGIN)
        :nesting
      elsif !scope.stopped.nil? && scope.loop_instances.include?(object_id)
        :loop
      end
      stopped_es = rewrite_and_emit(tag, es, state, own_scope, stop)
      stop_reemit(tag, stopped_es, state, scope, stop, depth, nesting) unless stopped_es.nil?
    rescue Exception
      raised = true
      raise
    ensure
      if depth.zero?
        depths.delete(object_id)
      else
        depths[object_id] = depth
      end
      # After an error too, so that the next emit starts without the stop.
      begin
        while scopes.size > own_scope
          begin
            end_stopped_loop(state, scopes.last) if scopes.last.stopped
          ensure
            scopes.pop
          end
        end
      ensure
        begin
          end_stopped_loop(state, scope) if scope.stopped && depths.empty?
        ensure
          state.nesting = nesting
          # Raised once, by the outermost pass, so that it is not logged at each level of the nested emits.
          if nesting.zero?
            loop_error = state.error
            state.error = nil
            # Another error goes back to the input instead, so keep the error of the loop in the log.
            if raised && loop_error
              log.error "rewrite_tag_filter: a loop was stopped in this emit, but another error goes back to the input", error: loop_error.message
              loop_error = nil
            end
          end
        end
      end
    end
    raise loop_error if loop_error
  end

  # The events that a pass stopped would re-emit, with the tag that it got. A pass that re-emits nothing is not stopped,
  # such as the last pass of a chain that ends. stop: :came_back, :depth (max_reemit_depth of this section), :nesting
  # (the passes of all the sections), or :loop (a section of a stopped loop).
  def stop_reemit(tag, es, state, scope, stop, depth, nesting)
    if stop == :came_back
      # The events sent to @ERROR came back, for example when this plugin is in <label @ERROR>. Sending them to @ERROR
      # again would loop forever, so drop them, and keep the records in the log.
      es.each do |time, record|
        log.error "rewrite_tag_filter: an event sent to @ERROR came back to this plugin, so it is dropped. Check the tag and the label of the rules", tag: tag, time: time, record: record
      end
      return
    end
    if stop != :loop
      error = if stop == :depth
        ReemitLoopError.new("events came back to this plugin #{depth} times in a row. Check the tag and the label of the rules, or max_reemit_depth")
      else
        ReemitLoopError.new("events were re-emitted by rewrite_tag_filter #{nesting} times in a row in the nested emits, counting the passes of all the <match> sections, which is the most. Check the tag and the label of the rules, or make the chain shorter")
      end
      unless scope.stopped
        scope.stopped = error
        root_agent = own_root_agent
        scope.to_error = !root_agent.nil? && !root_agent.error_collector.nil?
      end
      # Without <label @ERROR>, the error is raised like other errors, so that the input sees it.
      state.error ||= error unless scope.to_error
    else
      error = (scope.other_error ||= ReemitLoopError.new("events came back to this plugin in a loop that was stopped in the same emit. Check the tag and the label of the rules, or max_reemit_depth"))
    end
    # A section stopped at 20 passes in a row that has not come back, such as a <store> of an out_copy that leads out of
    # the loop, or the last section of a long chain, is not in the loop: its other passes go on.
    in_loop = stop != :nesting || !depth.zero?
    # While events are sent to @ERROR, it is stopped too, so that its events are dropped if they come back to it from
    # @ERROR, instead of being sent to @ERROR again and again.
    if in_loop || !state.sending_errors.zero?
      scope.stopped_instances << object_id unless scope.stopped_instances.include?(object_id)
    end
    if in_loop
      # The sections in the nested emits led the events back to the loop.
      loop_instances = scope.loop_instances
      state.depths.each_key { |instance| loop_instances << instance unless loop_instances.include?(instance) }
    end
    if scope.to_error
      pending = scope.pending
      es.each { |time, record| pending[record] ||= [router, tag, time, error] }
    end
  end

  # Sends the events of the stopped loop to @ERROR. Unless keep_stopped, the next events are re-emitted as usual.
  def end_stopped_loop(state, scope, keep_stopped: false)
    pending = scope.pending
    came_back = scope.came_back | scope.stopped_instances
    unless keep_stopped
      scope.stopped = scope.other_error = scope.to_error = nil
      scope.loop_instances = []
      scope.stopped_instances = []
    end
    scope.pending = {}.compare_by_identity
    return if pending.empty?
    error_scope = ReemitScope.new(nil, nil, nil, [], [], {}.compare_by_identity, came_back)
    state.scopes.push(error_scope)
    state.sending_errors += 1
    begin
      pending.each { |record, (event_router, tag, time, error)| event_router.emit_error_event(tag, time, record, error) }
      end_stopped_loop(state, error_scope) if error_scope.stopped
    ensure
      state.sending_errors -= 1
      state.scopes.pop
    end
  end

  # Called after this pass re-emits while a loop is stopped.
  def after_reemit(state, own_scope)
    scopes = state.scopes
    scope = scopes.last
    depths = state.depths
    return unless scope.stopped_instances.all? { |instance| (depths[instance] || 0) <= 1 }
    if scopes.size > own_scope
      end_stopped_loop(state, scope)
    else
      end_stopped_loop(state, scope, keep_stopped: true)
      scopes.push(ReemitScope.new(nil, nil, nil, [], [], {}.compare_by_identity, scope.came_back))
    end
  end

  # Returns the events that the pass would re-emit when it is stopped.
  def rewrite_and_emit(tag, es, state, own_scope, stop)
    placeholder = get_placeholder(tag)
    new_event_streams =  Hash.new {|hh, kk| hh[kk] = Hash.new {|h, k| h[k] = Fluent::MultiEventStream.new }}if @batch_mode
    stopped_es = nil

    es.each do |time, record|
      rewrited_tag, rewrited_label  = rewrite_tag(tag, record, placeholder)
      if (rewrited_tag.nil? || tag == rewrited_tag) && rewrited_label.nil?
        log.trace("rewrite_tag_filter: tag has not been rewritten", record)
        next
      end
      if !stop.nil?
        (stopped_es ||= Fluent::MultiEventStream.new).add(time, record)
      elsif new_event_streams.nil?
        resolved_router(rewrited_label).emit(rewrited_tag, time, record)
        after_reemit(state, own_scope) if state.scopes.last.stopped
      else
        new_event_streams[rewrited_label][rewrited_tag].add(time, record)
      end
    end
    if !new_event_streams.nil?
      new_event_streams.each do |rewrited_label, label_event_streams |
        labeled_router = resolved_router(rewrited_label)
        label_event_streams.each do |rewrited_tag, new_es|
            labeled_router.emit_stream(rewrited_tag, new_es)
            after_reemit(state, own_scope) if state.scopes.last.stopped
        end
      end
    end
    stopped_es
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
      # An optional group that did not participate in the match is nil.
      value = value.to_s
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

