# fluent-plugin-rewrite-tag-filter

## Overview

### RewriteTagFilterOutput

Fluentd Output filter plugin. It has designed to rewrite tag like mod_rewrite.  
Re-emmit a record with rewrited tag when a value matches with the regular expression.  
Also you can change a tag from apache log by domain, status-code(ex. 500 error),  
user-agent, request-uri, regex-backreference and so on with regular expression.

## Installation

```
# native gem
gem install fluent-plugin-rewrite-tag-filter

# td-agent gem
/usr/lib64/fluent/ruby/bin/fluent-gem install fluent-plugin-rewrite-tag-filter
```

## Configuration

### Syntax

```
rewruterule<num:1-200> <attribute> <regex_pattern> <new_tag>

# Optional: Capitalize every matched regex backreference. (ex: $1, $2)
capitalize_regex_backreference <yes/no> (default no)

# Optional: remove tag prefix for tag placeholder.
remove_tag_prefix <string>

# Optional: set placeholder for hostname.
hostname_command <string>
```

### Usage

It's a sample to exclude some static file log before split tag by domain.

```
<source>
  type tail
  path /var/log/httpd/access_log
  format apache2
  time_format %d/%b/%Y:%H:%M:%S %z
  tag td.apache.access
  pos_file /var/log/td-agent/apache_access.pos
</source>

# At rewriterule4, "site.$2$1" to be "site.ExampleMail" by capitalize_regex_backreference option.
<match td.apache.access>
  type rewrite_tag_filter
  capitalize_regex_backreference yes
  rewriterule1 path   \.(gif|jpe?g|png|pdf|zip)$  clear
  rewriterule2 domain ^maps\.example\.com$        site.ExampleMaps
  rewriterule3 domain ^news\.example\.com$        site.ExampleNews
  rewriterule4 domain ^(mail)\.(example)\.com$    site.$2$1
  rewriterule5 domain .+                          site.unmatched
</match>

<match site.*>
  type mongo
  host localhost
  database apache_access
  remove_tag_prefix site
  tag_mapped
  capped
  capped_size 100m
</match>

<match clear>
  type null
</match>
```

### Result

```
$ mongo
MongoDB shell version: 2.2.0
> use apache_access
switched to db apache_access
> show collections
ExampleMaps
ExampleNews
ExampleMail
unmatched
```

### Debug

On starting td-agent, Logging supported like below.

```
$ tailf /var/log/td-agent/td-agent.log
2012-09-16 18:10:51 +0900: adding match pattern="td.apache.access" type="rewrite_tag_filter"
2012-09-16 18:10:51 +0900: adding rewrite_tag_filter rule: [1, "path", /\.(gif|jpe?g|png|pdf|zip)$/, "clear"]
2012-09-16 18:10:51 +0900: adding rewrite_tag_filter rule: [2, "domain", /^maps\.example\.com$/, "site.ExampleMaps"]
2012-09-16 18:10:51 +0900: adding rewrite_tag_filter rule: [3, "domain", /^news\.example\.com$/, "site.ExampleNews"]
2012-09-16 18:10:51 +0900: adding rewrite_tag_filter rule: [4, "domain", /^(mail)\.(example)\.com$/, "site.$2$1"]
2012-09-16 18:10:51 +0900: adding rewrite_tag_filter rule: [5, "domain", /.+/, "site.unmatched"]
```

### Tag placeholder

Supporing these placeholder for new_tag(rewrited tag).  
It's available to use this placeholder with `remove_tag_prefix` option.  
This feature adds removing tag prefix for `${tag}` or `__TAG__` in placeholder.

- `${hostname}`
- `__HOSTNAME__`
- `${tag}`
- `__TAG__`

It's a sample to rewrite a tag with placeholder.

```
# It will get "rewrited.access.ExampleMail"
<match apache.access>
  type rewrite_tag_filter
  rewriterule1  domain  ^(mail)\.(example)\.com$  rewrited.${tag}.$2$1
  remove_tag_prefix apache
</match>

# It will get "rewrited.ExampleMail.app30-124.foo.com" when hostname is "app30-124.foo.com"
<match apache.access>
  type rewrite_tag_filter
  rewriterule1  domain  ^(mail)\.(example)\.com$  rewrited.$2$1.${hostname}
</match>

# It will get "rewrited.ExampleMail.app30-124" when hostname is "app30-124.foo.com"
<match apache.access>
  type rewrite_tag_filter
  rewriterule1  domain  ^(mail)\.(example)\.com$  rewrited.$2$1.${hostname}
  hostname_command hostname -s
</match>
```

## Example

- Example1: how to analyze response_time, response_code and user_agent for each virtual domain websites.  
https://github.com/y-ken/fluent-plugin-rewrite-tag-filter/blob/master/example.conf

- Example2: how to exclude specified patterns before analyze response_time for each virtual domain websites.  
https://github.com/y-ken/fluent-plugin-rewrite-tag-filter/blob/master/example2.conf

## Related Articles

- 自在にタグを書き換える fluent-plugin-rewrite-tag-filter でログ解析が捗るお話 #fluentd  
http://d.hatena.ne.jp/yoshi-ken/20120701/1341137269

- Fluentd & TreasureDataで こっそり始めるログ集計 Fluentd Meetup #2 @mikeda  
http://www.slideshare.net/baguzy/fluentd-meetup-2-14073930

- 似てる #fluentd プラグインの比較  
http://matsumana.wordpress.com/2012/11/15/%E4%BC%BC%E3%81%A6%E3%82%8B-fluentd-%E3%83%97%E3%83%A9%E3%82%B0%E3%82%A4%E3%83%B3%E3%81%AE%E6%AF%94%E8%BC%83/

- Fluentdの集約サーバ用設定ファイル (fluent-plugin-rewrite-tag-filter版)  
https://gist.github.com/matsumana/4078096

- 稼働中のFluentdにflowcounter pluginを導入してみた  
http://dayafterneet.blogspot.jp/2012/12/fluentdflowcounter-plugin.html

- fluent-plugin-rewrite-tag-filter v1.2.0 をリリースしました。新機能を紹介します。 #fluentd  
http://y-ken.hatenablog.com/entry/fluent-plugin-rewrite-tag-filter-v1.2.0

## TODO

Pull requests are very welcome!!

## Copyright

Copyright :  Copyright (c) 2012- Kentaro Yoshida (@yoshi_ken)  
License   :  Apache License, Version 2.0

