require "fluent/plugin/output"
require "fluent/config/regexp_type"

class Fluent::Plugin::RewriteTagFilterOutput < Fluent::Plugin::Output
  Fluent::Plugin.register_output('rewrite_tag_filter', self)

  helpers :event_emitter, :record_accessor

  desc "Convert the first character of every matched regex backreference to upper case and the rest to lower case, as Ruby's String#capitalize does."
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
    desc "The field name to which the regular expression is applied. A value that is not a String is converted with Ruby's to_s before matching."
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
  TAG_TOKEN_REGEXP = /(\$\d+)|(\${[a-z_]+(?:\[[0-9]+\])?}|__TAG_PARTS\[[0-9]+\]__|__[A-Z_]+?__)/

  def configure(conf)
    super

    @rewriterules = []
    rewriterule_names = []
    @rule_keys = {}
    @nested_keys = {}
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
      # A key starting with $. or $[ is nested, as Fluentd's Accessor.parse_parameter decides.
      @nested_keys[@rewriterules.last.first] = rule.key.start_with?('$.', '$[')
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

  def process(tag, es)
    placeholder = get_placeholder(tag)
    new_event_streams =  Hash.new {|hh, kk| hh[kk] = Hash.new {|h, k| h[k] = Fluent::MultiEventStream.new }}if @batch_mode

    es.each do |time, record|
      rewrited_tag, rewrited_label  = rewrite_tag(tag, record, placeholder)
      if (rewrited_tag.nil? || tag == rewrited_tag) && rewrited_label.nil?
        log.trace("rewrite_tag_filter: tag has not been rewritten", record)
        next
      end
      if new_event_streams.nil?
        get_router(rewrited_label).emit(rewrited_tag, time, record)
      else
        new_event_streams[rewrited_label][rewrited_tag].add(time, record)
      end
    end
    if !new_event_streams.nil?
      new_event_streams.each do |rewrited_label, label_event_streams |
        labeled_router = get_router(rewrited_label)
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

  # The tag is built from the captures as they are, as before. When an ASCII-8BIT capture cannot be joined with the rest
  # of the tag, such as for `tag ログ.$1`, the captures that are valid UTF-8 are read as UTF-8 and the tag is built again.
  def expand_tag(rewritetag, backreference_table, placeholder, tag)
    unknown = []
    begin
      expand_tag_once(rewritetag, backreference_table, placeholder, unknown)
    rescue Encoding::CompatibilityError
      raise unless backreference_table
      unknown.clear
      # Not Hash#transform_values, which needs Ruby 2.4: Fluentd up to 1.8 runs on Ruby 2.1.
      utf8_table = backreference_table.map { |key, value| [key, binary_as_utf8(value)] }.to_h
      expand_tag_once(rewritetag, utf8_table, placeholder, unknown)
    end
  ensure
    # Warned after the last pass, so it is warned once even when the tag is built again, and also when building the tag
    # fails, as before.
    unknown.each do |name|
      log.warn "rewrite_tag_filter: unknown placeholder found. :placeholder=>#{name} :tag=>#{tag} :rewritetag=>#{rewritetag}"
    end
  end

  def expand_tag_once(rewritetag, backreference_table, placeholder, unknown)
    # Backreferences and placeholders are expanded in one pass, so text taken
    # from a record can never turn into a placeholder.
    rewritetag.gsub(TAG_TOKEN_REGEXP) do
      if $1
        # An invert rule has no captures, so "$1" stays as it is written.
        backreference_table ? backreference_table[$1] : $1
      else
        unknown << $2 unless placeholder.include?($2)
        placeholder[$2]
      end
    end
  end

  def read_value(record_accessor, record)
    value = begin
      record_accessor.call(record)
    rescue TypeError => e
      # A nested key whose parent cannot be read with the next key, such as $.log.level for {"log": "text"} or
      # {"log": ["x"]}, is treated as a missing key. Other errors, such as a top-level key for a record that is not a
      # Hash, are raised as before. Accessor#keys is not used for this because Fluentd 1.0 has no reader for it.
      raise unless record.is_a?(Hash) && @nested_keys[record_accessor]
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

  # in_tail without `encoding` gives ASCII-8BIT strings.
  def binary_with_non_ascii?(value)
    value.is_a?(String) && value.encoding == Encoding::ASCII_8BIT && !value.ascii_only?
  end

  def binary_as_utf8(value)
    return value unless binary_with_non_ascii?(value)
    utf8 = value.dup.force_encoding(Encoding::UTF_8)
    utf8.valid_encoding? ? utf8 : value
  end

  # capitalize changes only the ASCII letters of an ASCII-8BIT capture, so "émile" stays "émile". Capitalize a capture
  # that is valid UTF-8 as UTF-8, and keep it in ASCII-8BIT, so the tag is built from the same encoding as before.
  def capitalize_capture(value)
    utf8 = binary_as_utf8(value)
    return value.capitalize if utf8.equal?(value)
    utf8.capitalize.force_encoding(Encoding::ASCII_8BIT)
  end

  def regexp_last_match(regexp, rewritevalue)
    # A pattern in UTF-8, such as one with non-ASCII characters or \p{Han}, cannot be matched against an ASCII-8BIT
    # string with non-ASCII bytes. Read the string as UTF-8, and the bytes that are not valid UTF-8 are replaced below.
    # A pattern in another encoding, such as one with only ASCII characters, matches the bytes as before.
    if regexp.encoding == Encoding::UTF_8 && binary_with_non_ascii?(rewritevalue)
      rewritevalue = rewritevalue.dup.force_encoding(Encoding::UTF_8)
    end
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
      hash_table["$#{index}"] = @capitalize_regex_backreference ? capitalize_capture(value) : value
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

