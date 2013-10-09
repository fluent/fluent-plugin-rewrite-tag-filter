class Fluent::RewriteTagFilterOutput < Fluent::Output
  Fluent::Plugin.register_output('rewrite_tag_filter', self)

  config_param :capitalize_regex_backreference, :bool, :default => false
  config_param :remove_tag_prefix, :string, :default => nil
  config_param :use_of_first_match_tag, :string, :default => nil
  config_param :hostname_command, :string, :default => 'hostname'

  MATCH_OPERATOR_EXCLUDE = '!'

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
      @rewriterules.push([rewritekey, /#{trim_regex_quote(regexp)}/, get_match_operator(regexp), rewritetag])
      rewriterule_names.push(rewritekey + regexp)
      $log.info "adding rewrite_tag_filter rule: #{key} #{@rewriterules.last}"
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

    unless @use_of_first_match_tag.nil?
      @use_of_first_match_tag = Regexp.new(@use_of_first_match_tag)
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
      next if rewritevalue.empty? && match_operator != MATCH_OPERATOR_EXCLUDE
      matched = regexp && regexp.match(rewritevalue)
      case match_operator
      when MATCH_OPERATOR_EXCLUDE
        next if matched
      else
        next if !matched
        backreference_table = get_backreference_table($~.captures)
        rewritetag = rewritetag.gsub(/\$\d+/, backreference_table)
      end
      rewritetag = rewritetag.gsub(/(\${[a-z]+}|__[A-Z]+__)/, placeholder)
      return rewritetag
    end
    return nil
  end

  def parse_rewriterule(rule)
    if rule.match(/^([^\s]+)\s+(.+?)\s+([^\s]+)$/)
      return $~.captures
    end
  end

  def trim_regex_quote(regexp)
    if regexp.start_with?('"') && regexp.end_with?('"')
      $log.info "rewrite_tag_filter: [DEPRECATED] Use ^....$ pattern for partial word match instead of double-quote-delimiter. #{regexp}"
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
    tag = tag.match(@use_of_first_match_tag)[1] if @use_of_first_match_tag
    return {
      '__HOSTNAME__' => @hostname,
      '${hostname}' => @hostname,
      '__TAG__' => tag,
      '${tag}' => tag,
    }
  end
end

