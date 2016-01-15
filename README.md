# fluent-plugin-rewrite-tag-filter [![Build Status](https://travis-ci.org/fluent/fluent-plugin-rewrite-tag-filter.png?branch=master)](https://travis-ci.org/fluent/fluent-plugin-rewrite-tag-filter)

## Overview

Rewrite Tag Filter for [Fluentd](http://fluentd.org). It is designed to rewrite tags like mod_rewrite.  
Re-emit the record with rewrited tag when a value matches/unmatches with a regular expression.  
Also you can change a tag from Apache log by domain, status code (ex. 500 error),  
user-agent, request-uri, regex-backreference and so on with regular expression.

## Installation

Install with `gem`, `fluent-gem` or `td-agent-gem` command as:

```
# for system installed fluentd
$ gem install fluent-plugin-rewrite-tag-filter

# for td-agent
$ sudo /usr/lib64/fluent/ruby/bin/fluent-gem install fluent-plugin-rewrite-tag-filter

# for td-agent2
$ sudo td-agent-gem install fluent-plugin-rewrite-tag-filter
```

## Configuration

### Syntax

```
rewriterule<num> <attribute> <regex_pattern> <new_tag>

# Optional: Capitalize letter for every matched regex backreference. (ex: maps -> Maps)
# for more details, see usage.
capitalize_regex_backreference <yes/no> (default no)

# Optional: remove tag prefix for tag placeholder. (see the section of "Tag placeholder")
remove_tag_prefix <string>

# Optional: override hostname command for placeholder. (see the section of "Tag placeholder")
hostname_command <string>

# Optional: Set log level for this plugin. (ex: trace, debug, info, warn, error, fatal)
log_level        <string> (default info)
```

### Usage

It's a sample to exclude some static file log before split tag by domain.

```
<source>
  @type tail
  path /var/log/httpd/access_log
  format apache2
  time_format %d/%b/%Y:%H:%M:%S %z
  tag td.apache.access
  pos_file /var/log/td-agent/apache_access.pos
</source>

# "capitalize_regex_backreference yes" affects converting every matched first letter of backreference to upper case. ex: maps -> Maps
# At rewriterule2, redirect to tag named "clear" which unmatched for status code 200.
# At rewriterule3, redirect to tag named "clear" which is not end with ".com"
# At rewriterule6, "site.$2$1" to be "site.ExampleMail" by capitalize_regex_backreference option.
<match td.apache.access>
  @type rewrite_tag_filter
  capitalize_regex_backreference yes
  rewriterule1 path   \.(gif|jpe?g|png|pdf|zip)$  clear
  rewriterule2 status !^200$                      clear
  rewriterule3 domain !^.+\.com$                  clear
  rewriterule4 domain ^maps\.example\.com$        site.ExampleMaps
  rewriterule5 domain ^news\.example\.com$        site.ExampleNews
  rewriterule6 domain ^(mail)\.(example)\.com$    site.$2$1
  rewriterule7 domain .+                          site.unmatched
</match>

<match site.*>
  @type mongo
  host localhost
  database apache_access
  remove_tag_prefix site
  tag_mapped
  capped
  capped_size 100m
</match>

<match clear>
  @type null
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

It is supported these placeholder for new_tag (rewrited tag).

- `${tag}`
- `__TAG__`
- `{$tag_parts[n]}`
- `__TAG_PARTS[n]__`
- `${hostname}`
- `__HOSTNAME__`

The placeholder of `{$tag_parts[n]}` and `__TAG_PARTS[n]__` acts accessing the index which split the tag with "." (dot).  
For example with `td.apache.access` tag, it will get `td` by `${tag_parts[0]}` and `apache` by `${tag_parts[1]}`.

**Note** Currently, range expression ```${tag_parts[0..2]}``` is not supported.

#### Placeholder Option

* `remove_tag_prefix`  

This option adds removing tag prefix for `${tag}` or `__TAG__` in placeholder.

* `hostname_command` 

By default, execute command as `hostname` to get full hostname.  
On your needs, it could override hostname command using `hostname_command` option.  
It comes short hostname with `hostname_command hostname -s` configuration specified.

#### Placeholder Usage

It's a sample to rewrite a tag with placeholder.

```
# It will get "rewrited.access.ExampleMail"
<match apache.access>
  @type rewrite_tag_filter
  rewriterule1  domain  ^(mail)\.(example)\.com$  rewrited.${tag}.$2$1
  remove_tag_prefix apache
</match>

# It will get "rewrited.ExampleMail.app30-124.foo.com" when hostname is "app30-124.foo.com"
<match apache.access>
  @type rewrite_tag_filter
  rewriterule1  domain  ^(mail)\.(example)\.com$  rewrited.$2$1.${hostname}
</match>

# It will get "rewrited.ExampleMail.app30-124" when hostname is "app30-124.foo.com"
<match apache.access>
  @type rewrite_tag_filter
  rewriterule1  domain  ^(mail)\.(example)\.com$  rewrited.$2$1.${hostname}
  hostname_command hostname -s
</match>

# It will get "rewrited.game.pool"
<match app.game.pool.activity>
  @type rewrite_tag_filter
  rewriterule1  domain  ^.+$  rewrited.${tag_parts[1]}.${tag_parts[2]}
</match>
```

## Example

- Example1: how to analyze response_time, response_code and user_agent for each virtual domain websites.  
https://github.com/y-ken/fluent-plugin-rewrite-tag-filter/blob/master/example.conf

- Example2: how to exclude specified patterns before analyze response_time for each virtual domain websites.  
https://github.com/y-ken/fluent-plugin-rewrite-tag-filter/blob/master/example2.conf

## Related Articles

- 自在にタグを書き換える fluent-plugin-rewrite-tag-filter でログ解析が捗るお話 #fluentd<br>
http://d.hatena.ne.jp/yoshi-ken/20120701/1341137269

- Fluentd & TreasureDataで こっそり始めるログ集計 Fluentd Meetup #2 @mikeda<br>
http://www.slideshare.net/baguzy/fluentd-meetup-2-14073930

- 似てる #fluentd プラグインの比較<br>
http://matsumana.wordpress.com/2012/11/15/%E4%BC%BC%E3%81%A6%E3%82%8B-fluentd-%E3%83%97%E3%83%A9%E3%82%B0%E3%82%A4%E3%83%B3%E3%81%AE%E6%AF%94%E8%BC%83/

- Fluentdの集約サーバ用設定ファイル (fluent-plugin-rewrite-tag-filter版)<br>
https://gist.github.com/matsumana/4078096

- 稼働中のFluentdにflowcounter pluginを導入してみた<br>
http://dayafterneet.blogspot.jp/2012/12/fluentdflowcounter-plugin.html

- fluent-plugin-rewrite-tag-filter v1.2.0 をリリースしました。新機能であるremove_tag_prefix設定の使い方を解説します。 #fluentd<br>
http://y-ken.hatenablog.com/entry/fluent-plugin-rewrite-tag-filter-v1.2.0

- fluent-plugin-rewrite-tag-filter v1.2.1 をリリースしました。設定サンプルと共にプレースホルダ機能強化内容を紹介します。 #fluentd<br>
http://y-ken.hatenablog.com/entry/fluent-plugin-rewrite-tag-filter-v1.2.1

- 待望の正規表現の否定パターンに対応した fluent-plugin-rewrite-tag-filter v1.3.0 をリリースしました #fluentd<br>
http://y-ken.hatenablog.com/entry/fluent-plugin-rewrite-tag-filter-v1.3.0

- 不具合修正版 fluent-plugin-rewrite-tag-filter v1.3.1 をリリースしました #fluentd<br>
http://y-ken.hatenablog.com/entry/fluent-plugin-rewrite-tag-filter-v1.3.1

- PostgreSQLのログをfluentdで回収する設定 — still deeper<br>
http://chopl.in/blog/2013/06/07/postgresql_csv_log_with_fluentd.html

- S3とFluentdを用いた効率的なログ管理 | SmartNews開発者ブログ<br>
http://developer.smartnews.be/blog/2013/09/02/an-effective-log-management-technique-which-uses-fluentd-and-s3/

- fluentd(td-agent) の導入 : Raccoon Tech Blog [株式会社ラクーン 技術戦略部ブログ]<br>
http://techblog.raccoon.ne.jp/archives/35031163.html

- fluent-plugin-rewrite-tag-filter v1.4.1 をリリースしました #fluentd<br>
http://y-ken.hatenablog.com/entry/fluent-plugin-rewrite-tag-filter-v1.4.1

## TODO

Pull requests are very welcome!!

## Copyright

Copyright :  Copyright (c) 2012- Kentaro Yoshida (@yoshi_ken)  
License   :  Apache License, Version 2.0

