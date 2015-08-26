class Fluent::RewriteTagFilterOutput < Fluent::Output
  Fluent::Plugin.register_output('rewrite_tag_filter', self)

  config_param :capitalize_regex_backreference, :bool, :default => false
  config_param :remove_tag_prefix, :string, :default => nil
  config_param :hostname_command, :string, :default => 'hostname'

  MATCH_OPERATOR_EXCLUDE = '!'

  # Define `log` method for v0.10.42 or earlier
  unless method_defined?(:log)
    define_method("log") { $log }
  end

  def initialize
    super
    require 'string/scrub' if RUBY_VERSION.to_f < 2.1
  end

  def configure(conf)
    super

    @rewriterules = []
    rewriterule_names = []
    @hostname = `#{@hostname_command}`.chomp

    conf.keys.select{|k| k =~ /^rewriterule(\d+)$/}.sort_by{|i| i.sub('rewriterule', '').to_i}.each do |key|
      rewritekey,regexp,rewritetag = parse_rewriterule(conf[key])
      if regexp.nil? || rewritetag.nil?
        raise Fluent::ConfigError, "failed to parse rewriterules at #{key} #{conf[key]}"
      end

      unless rewritetag.match(/\$\{tag_parts\[\d\.\.\.?\d\]\}/).nil? or rewritetag.match(/__TAG_PARTS\[\d\.\.\.?\d\]__/).nil?
        raise Fluent::ConfigError, "${tag_parts[n]} and __TAG_PARTS[n]__ placeholder does not support range specify at #{key} #{conf[key]}"
      end

      @rewriterules.push([rewritekey, /#{trim_regex_quote(regexp)}/, get_match_operator(regexp), rewritetag])
      rewriterule_names.push(rewritekey + regexp)
      log.info "adding rewrite_tag_filter rule: #{key} #{@rewriterules.last}"
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

  def emit(tag, es, chain)
    es.each do |time,record|
      rewrited_tag = rewrite_tag(tag, record)
      next if rewrited_tag.nil? || tag == rewrited_tag
      Fluent::Engine.emit(rewrited_tag, time, record)
    end

    chain.next
  end

  def rewrite_tag(tag, record)
    placeholder = get_placeholder(tag)
    @rewriterules.each do |rewritekey, regexp, match_operator, rewritetag|
      rewritevalue = record[rewritekey].to_s
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
    begin
      return if regexp.nil?
      regexp.match(rewritevalue)
      return $~
    rescue ArgumentError => e
      raise e unless e.message.index('invalid byte sequence in') == 0
      regexp.match(rewritevalue.scrub('?'))
      return $~
    end
  end

  def parse_rewriterule(rule)
    if rule.match(/^([^\s]+)\s+(.+?)\s+([^\s]+)$/)
      return $~.captures
    end
  end

  def trim_regex_quote(regexp)
    if regexp.start_with?('"') && regexp.end_with?('"')
      log.info "rewrite_tag_filter: [DEPRECATED] Use ^....$ pattern for partial word match instead of double-quote-delimiter. #{regexp}"
      regexp = regexp[1..-2]
    end
    if regexp.start_with?(MATCH_OPERATOR_EXCLUDE)
      regexp = regexp[1, regexp.length]
    end
    return regexp
  end

  def get_match_operator(regexp)
    return MATCH_OPERATOR_EXCLUDE if regexp.start_with?(MATCH_OPERATOR_EXCLUDE)
    return ''
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

