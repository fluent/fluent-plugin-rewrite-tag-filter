class Fluent::RewriteTagFilterOutput < Fluent::Output
  Fluent::Plugin.register_output('rewrite_tag_filter', self)

  config_param :rewriterule1, :string, :default => nil
  config_param :capitalize_regex_backreference, :bool, :default => false
  config_param :remove_tag_prefix, :string, :default => nil
  config_param :hostname_command, :string, :default => 'hostname'

  def configure(conf)
    super

    @rewriterules = []
    rewriterule_names = []
    @hostname = `#{@hostname_command}`.chomp

    conf.keys.select{|k| k =~ /^rewriterule(\d+)$/}.sort_by{|i| i.sub('rewriterule', '').to_i}.each do |key|
      rewritekey,regexp,rewritetag = parse_rewriterule(conf[key])
      if regexp.nil? || rewritetag.nil?
        raise Fluent::ConfigError, "missing values at #{key} " + conf[key]
      end
      @rewriterules.push([rewritekey, Regexp.new(trim_regex_quote(regexp)), get_match_operator(regexp), rewritetag])
      rewriterule_names.push(rewritekey + regexp)
      $log.info "adding rewrite_tag_filter rule: #{key} #{@rewriterules.last}"
    end

    unless @rewriterules.length > 0
      raise Fluent::ConfigError, "missing rewriterules #{@rewriterules.inspect}"
    end

    unless @rewriterules.length == rewriterule_names.uniq.length
      raise Fluent::ConfigError, "duplicated rewriterules found #{@rewriterules.inspect}"
    end

    unless conf['remove_tag_prefix'].nil?
      @remove_tag_prefix = Regexp.new("^#{Regexp.escape(remove_tag_prefix)}\.?")
    end
  end

  def emit(tag, es, chain)
    placeholder = get_placeholder(tag)
    es.each do |time,record|
      rewrite = false
      @rewriterules.each do |rewritekey, regexp, match_operator, rewritetag|
        rewritevalue = record[rewritekey].to_s
        next if rewritevalue.empty? && !match_operator.start_with?('!')
        matched = regexp && regexp.match(rewritevalue)
        exclude_mode = is_exclude_mode(match_operator)
        next unless (matched && !exclude_mode) || (!matched && exclude_mode)
        backreference_table = get_backreference_table($~.captures) unless exclude_mode
        rewrite = true
        rewritetag.gsub!(/(\${[a-z]+}|__[A-Z]+__)/, placeholder)
        rewritetag.gsub!(/\$\d+/, backreference_table) unless exclude_mode
        tag = rewritetag
        break
      end
      Fluent::Engine.emit(tag, time, record) if (rewrite)
    end

    chain.next
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
    if regexp.start_with?('!')
      regexp = regexp[1, regexp.length]
    end
    return regexp
  end

  def get_match_operator(regexp)
    return '!' if regexp.start_with?('!')
    return ''
  end

  def is_exclude_mode(regexp)
    return regexp.start_with?('!')
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
    return {
      '__HOSTNAME__' => @hostname,
      '${hostname}' => @hostname,
      '__TAG__' => tag,
      '${tag}' => tag,
    }
  end
end

