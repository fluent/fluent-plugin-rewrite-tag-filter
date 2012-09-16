class Fluent::RewriteTagFilterOutput < Fluent::Output
  Fluent::Plugin.register_output('rewrite_tag_filter', self)

  PATTERN_MAX_NUM = 200

  config_param :rewriterule1, :string # string: NAME REGEXP
  (2..PATTERN_MAX_NUM).each do |i|
    config_param ('rewriterule' + i.to_s).to_sym, :string, :default => nil # NAME REGEXP
  end
  config_param :capitalize_regex_backreference, :bool, :default => false

  def configure(conf)
    super

    @rewriterules = []
    rewriterule_names = []

    invalids = conf.keys.select{|k| k =~ /^rewriterule(\d+)$/}.select{|arg| arg =~ /^rewriterule(\d+)/ and not (1..PATTERN_MAX_NUM).include?($1.to_i)}
    if invalids.size > 0
      $log.warn "invalid number rewriterules (valid rewriterule number:1-{PATTERN_MAX_NUM}): #{invalids.join(",")}"
    end
    (1..PATTERN_MAX_NUM).each do |i|
      next unless conf["rewriterule#{i}"]
      rewritekey,regexp,rewritetag = conf["rewriterule#{i}"].match(/([^ ]+)\s(.+)\s([^ ]+)/).captures
      unless regexp != nil && rewritetag != nil
        raise Fluent::ConfigError, "missing values at rewriterule#{i} " + conf["rewriterule#{i}"].inspect
      end 
      @rewriterules.push([i, rewritekey, Regexp.new(regexp), rewritetag])
      rewriterule_names.push(rewritekey + regexp)
      $log.info "adding rewrite_tag_filter rule: #{@rewriterules.last}"
    end
    rewriterule_index_list = conf.keys.select{|s| s =~ /^rewriterule\d$/}.map{|v| (/^rewriterule(\d)$/.match(v))[1].to_i}
    unless rewriterule_index_list.reduce(true){|v,i| v and @rewriterules[i - 1]}
      raise Fluent::ConfigError, "jump of rewriterule index found #{@rewriterules.inspect}"
    end
    unless @rewriterules.length == rewriterule_names.uniq.length
      raise Fluent::ConfigError, "duplicated rewriterules found #{@rewriterules.inspect}"
    end
  end

  def emit(tag, es, chain)
    es.each do |time,record|
      rewrite = false
      @rewriterules.each do |index, rewritekey, regexp, rewritetag|
        rewritevalue = record[rewritekey]
        next if rewritevalue.nil?
        next unless (regexp && regexp.match(rewritevalue))
        rewrite = true
        tag = if rewritetag.include?('$')
                rewritetag.gsub(/\$\d+/, map_regex_table($~.captures))
              else
                rewritetag
              end
        break
      end
      Fluent::Engine.emit(tag, time, record) if (rewrite)
    end

    chain.next
  end

  def map_regex_table(elements)
    hash_table = Hash.new
    index = 1
    elements.each do |value|
      hash_table["$#{index}"] = @capitalize_regex_backreference ? value.capitalize : value
      index += 1
    end
    return hash_table
  end
end

