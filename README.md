# fluent-plugin-rewrite-tag-filter [![Build Status](https://travis-ci.org/fluent/fluent-plugin-rewrite-tag-filter.png?branch=master)](https://travis-ci.org/fluent/fluent-plugin-rewrite-tag-filter)

## Overview

Rewrite Tag Filter for [Fluentd](http://fluentd.org). It is designed to rewrite tags like mod_rewrite.  
Re-emit the record with rewrited tag when a value matches/unmatches with a regular expression.  
Also you can change a tag from Apache log by domain, status code (ex. 500 error),  
user-agent, request-uri, regex-backreference and so on with regular expression.

This is an output plugin because fluentd's `filter` doesn't allow tag rewrite.

## Requirements

| fluent-plugin-rewrite-tag-filter | Fluentd    | Ruby   |
|----------------------------------|------------|--------|
| >= 2.0.0                         | >= v0.14.2 | >= 2.1 |
| < 2.0.0                          | >= v0.12.0 | >= 1.9 |

## Installation

Install with `gem` or `td-agent-gem` command as:

```
# for system installed fluentd
$ gem install fluent-plugin-rewrite-tag-filter

# for td-agent2 (with fluentd v0.12)
$ sudo td-agent-gem install fluent-plugin-rewrite-tag-filter -v 1.6.0

# for td-agent3 (with fluentd v0.14)
$ sudo td-agent-gem install fluent-plugin-rewrite-tag-filter
```

For more details, see [Plugin Management](https://docs.fluentd.org/v0.14/articles/plugin-management)

## Configuration

* **rewriterule\<num\>** (string) (optional) \<attribute\> \<regex_pattern\> \<new_tag\>
  * Obsoleted: Use <rule> section
* **capitalize_regex_backreference** (bool) (optional): Capitalize letter for every matched regex backreference. (ex: maps -> Maps) for more details, see usage.
  * Default value: no
* **remove_tag_prefix** (string) (optional): Remove tag prefix for tag placeholder. (see the section of "Tag placeholder")
* **hostname_command** (string) (optional): Override hostname command for placeholder. (see the section of "Tag placeholder")
  * Default value: `hostname`.

### \<rule\> section (optional) (multiple)

* **key** (string) (required): The field name to which the regular expression is applied
* **pattern** (regexp) (required): The regular expression.
  `/regexp/` is preferred because `/regexp/` style can support character classes such as `/[a-z]/`.
  The pattern without slashes will cause errors if you use patterns start with character classes.
* **tag** (string) (required): New tag
* **invert** (bool) (optional): If true, rewrite tag when unmatch pattern
  * Default value: `false`

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
# At 2nd <rule>, redirect to tag named "clear" which unmatched for status code 200.
# At 3rd <rule>, redirect to tag named "clear" which is not end with ".com"
# At 6th <rule>, "site.$2$1" to be "site.ExampleMail" by capitalize_regex_backreference option.
<match td.apache.access>
  @type rewrite_tag_filter
  capitalize_regex_backreference yes
  <rule>
    key     path
    pattern /\.(gif|jpe?g|png|pdf|zip)$/
    tag clear
  </rule>
  <rule>
    key     status
    pattern /^200$/
    tag     clear
    invert  true
  </rule>
  <rule>
    key     domain
    pattern /^.+\.com$/
    tag     clear
    invert  true
  </rule>
  <rule>
    key     domain
    pattern /^maps\.example\.com$/
    tag     site.ExampleMaps
  </rule>
  <rule>
    key     domain
    pattern /^news\.example\.com$/
    tag     site.ExampleNews
  </rule>
  <rule>
    key     domain
    pattern /^(mail)\.(example)\.com$/
    tag     site.$2$1
  </rule>
  <rule>
    key     domain
    pattern /.+/
    tag     site.unmatched
  </rule>
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

### Nested attributes

Dot notation:

```
<match kubernetes.**>
  @type rewrite_tag_filter
  <rule>
    key $.kubernetes.namespace_name
    pattern ^(.+)$
    tag $1.${tag}
  </rule>
</match>
```

Bracket notation:

```
<match kubernetes.**>
  @type rewrite_tag_filter
  <rule>
    key $['kubernetes']['namespace_name']
    pattern ^(.+)$
    tag $1.${tag}
  </rule>
</match>
```

These example configurations can process nested attributes like following:

```
{
  "kubernetes": {
    "namespace_name": "default"
  }
}
```

When original tag is `kubernetes.var.log`, this will be converted to `default.kubernetes.var.log`.

### Tag placeholder

It is supported these placeholder for new_tag (rewrited tag).

- `${tag}`
- `__TAG__`
- `${tag_parts[n]}`
- `__TAG_PARTS[n]__`
- `${hostname}`
- `__HOSTNAME__`

The placeholder of `${tag_parts[n]}` and `__TAG_PARTS[n]__` acts accessing the index which split the tag with "." (dot).  
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
  remove_tag_prefix apache
  <rule>
    key     domain
    pattern ^(mail)\.(example)\.com$
    tag     rewrited.${tag}.$2$1
  </rule>
</match>

# It will get "rewrited.ExampleMail.app30-124.foo.com" when hostname is "app30-124.foo.com"
<match apache.access>
  @type rewrite_tag_filter
  <rule>
    key     domain
    pattern ^(mail)\.(example)\.com$
    tag     rewrited.$2$1.${hostname}
  </rule>
</match>

# It will get "rewrited.ExampleMail.app30-124" when hostname is "app30-124.foo.com"
<match apache.access>
  @type rewrite_tag_filter
  hostname_command hostname -s
  <rule>
    key     domain
    pattern ^(mail)\.(example)\.com$
    tag     rewrited.$2$1.${hostname}
  </rule>
</match>

# It will get "rewrited.game.pool"
<match app.game.pool.activity>
  @type rewrite_tag_filter
  <rule>
    key     domain
    pattern ^.+$
    tag     rewrited.${tag_parts[1]}.${tag_parts[2]}
  </rule>
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

