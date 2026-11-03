# fluent-plugin-rewrite-tag-filter

[![Testing on macOS](https://github.com/fluent/fluent-plugin-rewrite-tag-filter/actions/workflows/macos.yml/badge.svg)](https://github.com/fluent/fluent-plugin-rewrite-tag-filter/actions/workflows/macos.yml)
[![Testing on Ubuntu](https://github.com/fluent/fluent-plugin-rewrite-tag-filter/actions/workflows/linux.yml/badge.svg)](https://github.com/fluent/fluent-plugin-rewrite-tag-filter/actions/workflows/linux.yml)
[![Testing on Windows](https://github.com/fluent/fluent-plugin-rewrite-tag-filter/actions/workflows/windows.yml/badge.svg)](https://github.com/fluent/fluent-plugin-rewrite-tag-filter/actions/workflows/windows.yml)

## Overview

Rewrite Tag Filter for [Fluentd](http://fluentd.org). It is designed to rewrite tags like mod_rewrite.  
Re-emit the record with rewritten tag when a value matches/unmatches with a regular expression.  
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

For more details, see [Plugin Management](https://docs.fluentd.org/deployment/plugin-management)

## Configuration

* **rewriterule\<num\>** (string) (optional) \<attribute\> \<regex_pattern\> \<new_tag\>
  * Obsoleted: Use \<rule\> section
* **capitalize_regex_backreference** (bool) (optional): Convert the first character of every matched regex backreference to upper case and the rest to lower case, as Ruby's `String#capitalize` does. (ex: maps -> Maps, exampleMail -> Examplemail) for more details, see usage.
  * Default value: no
* **remove_tag_prefix** (string) (optional): Remove tag prefix for tag placeholder. (see the section of "Tag placeholder")
* **hostname_command** (string) (optional): Override hostname command for placeholder. (see the section of "Tag placeholder")
  * Default value: `hostname`
* **emit_mode** (enum) (required): Specify emit_mode to `batch` or `record`. `batch` will emit events per rewritten tag, and decrease IO. `record` will emit events per record.
  * Default value: `batch`
* **max_reemit_depth** (integer) (optional): How many times in a row an event can come back to this plugin. It is stopped as a loop when it comes back this many times. It can be 1 to 20. (see the section of "Events that keep coming back")
  * Default value: `10`

### \<rule\> section (optional) (multiple)

* **key** (string) (required): The field name to which the regular expression is applied.
  A value that is not a String is converted with Ruby's `to_s` before matching. For a Hash or an Array, the result can change with the Ruby version or the locale (for example, `{"a"=>1}` before Ruby 3.4 and `{"a" => 1}` since Ruby 3.4), so point `key` at the value inside it with a nested key instead (see "Nested attributes").
* **pattern** (regexp) (required): The regular expression.
  `/regexp/` is preferred because `/regexp/` style can support character classes such as `/[a-z]/`.
  The pattern without slashes will cause errors if you use patterns start with character classes.
* **tag** (string) (required): New tag
* **label** (string) (optional): New label. If specified, label can be changed per-rule.
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

# "capitalize_regex_backreference yes" converts the first character of every matched backreference to upper case and the rest to lower case. ex: maps -> Maps
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
  # Note: Specify catch-all rule in the last block not to lose unmatched records.
  # This rule only covers records that actually have a non-empty "domain" field.
  # See "Handling records that do not have the key" below for a rule that covers every record.
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

### Handling records that do not have the key

Each rule is evaluated against `record[key]`, and a record that matches none of the rules is not re-emitted, so it is silently dropped. A missing field is read as an empty string, and a normal rule (`invert false`) is skipped before its pattern is evaluated when the value is empty. Because of this, neither `pattern /.+/` nor `pattern /.*/` fires for a record that lacks the field, and a plain catch-all rule only covers records where the field exists and is not empty.

To catch every record regardless of whether the field exists, use an inverted rule whose pattern can never match anything, and place it as the last rule:

```
<rule>
  key     domain
  pattern /(?!)/
  invert  true
  tag     site.unmatched
</rule>
```

`(?!)` is an empty negative lookahead, so it never matches any input, and combined with `invert true` the rule always fires whether the field holds a value, is empty, or is absent from the record.

Note that this also means an inverted rule behaves differently from what you might expect for a missing field in general. For example, `pattern /^200$/` with `invert true` fires for a record that has no `status` field at all, because an empty string does not match that pattern.

If you want to keep unmatched records instead of discarding them, note that re-emitting them with the same tag into the same route is not possible. This is an output plugin, so the surrounding `<match>` has already routed the event here, and emitting it again with the same tag would make the same `<match>` catch it again forever. The plugin therefore skips an event whose tag is unchanged unless a `label` is given. To keep unmatched records, either rewrite them to a tag that the same `<match>` does not cover, or keep the tag and set `label` on the catch-all rule so that they are routed to another label:

```
<rule>
  key     domain
  pattern /(?!)/
  invert  true
  tag     ${tag}
  label   @UNMATCHED
</rule>
```

The `<label @UNMATCHED>` section must consume these records (for example, write them out). If it re-emits them with the tag unchanged and routes them back to `@UNMATCHED`, they loop for the same reason.

Alternatively, put `record_modifier` or `record_transformer` in front of this plugin so that the field always exists with a default value.

### Events that keep coming back

A re-emitted event can come back to this plugin, for example with `tag new.${tag}` in `<match **>`, or with `label @ROOT` in a top-level `<match>`. An event that comes back `max_reemit_depth` times in a row (10 by default) is stopped with `ReemitLoopError`, instead of being re-emitted until Fluentd stops with `SystemStackError`:

* With `<label @ERROR>`, the event is sent to `@ERROR`. If it comes back to this plugin from there, for example when this plugin is in `<label @ERROR>`, it is dropped, and the record is written to the error log.
* Without `<label @ERROR>`, the error goes back to the input, like other errors. It is raised once from the pass that started the loop, not at each level of the nested emits.

A chain that ends, for example `remove_tag_regexp` with `tag ${tag}`, which removes one part of the tag on each pass, may need a larger `max_reemit_depth`. It can be 20 at most, because each pass uses the stack of the thread: with `out_copy` in the path, the stack ran out after 84 passes on Windows with Ruby 3.1.

The depth is counted:

* for each `<match>` section (or `<store>` of `out_copy`), so a loop through two sections passes the events up to twice `max_reemit_depth`, and through three up to three times.
* only while the emits are nested in one fiber. A loop through a buffered output, or through `out_forward` and `in_forward`, starts again at 0 on each pass, and is not stopped.

An error that this plugin raises, such as for a label that is not defined, is not counted. Fluentd sends the events to `@ERROR`, as for other outputs that raise an error, so if `<label @ERROR>` sends them back to this plugin, for example with `relabel`, they loop until `SystemStackError`.

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

When a parent of the nested key cannot be read with the next key, such as `{"kubernetes": "text"}` or `{"kubernetes": ["x"]}` for the key above, the key is treated as missing (see "Handling records that do not have the key"), and a warning is logged once for each rule.

### Tag placeholder

It is supported these placeholder for new_tag (rewritten tag).

- `${tag}`
- `__TAG__`
- `${tag_parts[n]}`
- `__TAG_PARTS[n]__`
- `${hostname}`
- `__HOSTNAME__`

The placeholder of `${tag_parts[n]}` and `__TAG_PARTS[n]__` acts accessing the index which split the tag with "." (dot).  
For example with `td.apache.access` tag, it will get `td` by `${tag_parts[0]}` and `apache` by `${tag_parts[1]}`.

**Note** Currently, range expression ```${tag_parts[0..2]}``` is not supported.

#### Placeholder Options

* `remove_tag_prefix`  

This option adds removing tag prefix for `${tag}` or `__TAG__` in placeholder.

* `remove_tag_regexp`  

This option adds removing tag regexp for `${tag}` or `__TAG__` in placeholder.

* `hostname_command` 

By default, execute command as `hostname` to get full hostname.  
On your needs, it could override hostname command using `hostname_command` option.  
It comes short hostname with `hostname_command hostname -s` configuration specified.

The command runs when the plugin is configured, and only when a rule uses `${hostname}` or `__HOSTNAME__`.

To pick up a new hostname, reload the configuration, for example with `systemctl reload fluentd` or `SIGHUP` to the supervisor. See [Signals](https://docs.fluentd.org/deployment/signals) for details.

#### Placeholder Usage

It's a sample to rewrite a tag with placeholder.

```
# It will get "rewritten.access.ExampleMail"
<match apache.access>
  @type rewrite_tag_filter
  remove_tag_prefix apache
  <rule>
    key     domain
    pattern ^(mail)\.(example)\.com$
    tag     rewritten.${tag}.$2$1
  </rule>
</match>

# It will get "rewritten.access.ExampleMail"
<match apache.access>
  @type rewrite_tag_filter
  remove_tag_regexp /^apache\./
  <rule>
    key     domain
    pattern ^(mail)\.(example)\.com$
    tag     rewritten.${tag}.$2$1
  </rule>
</match>

# It will get "http.access.log"
<match input.{apache,nginx}.access.log>
  @type rewrite_tag_filter
  remove_tag_regexp /^input\.(apache|nginx)\./
  <rule>
    key     domain
    pattern ^.+$
    tag     http.${tag}
  </rule>
</match>

# It will get "rewritten.ExampleMail.app30-124.foo.com" when hostname is "app30-124.foo.com"
<match apache.access>
  @type rewrite_tag_filter
  <rule>
    key     domain
    pattern ^(mail)\.(example)\.com$
    tag     rewritten.$2$1.${hostname}
  </rule>
</match>

# It will get "rewritten.ExampleMail.app30-124" when hostname is "app30-124.foo.com"
<match apache.access>
  @type rewrite_tag_filter
  hostname_command hostname -s
  <rule>
    key     domain
    pattern ^(mail)\.(example)\.com$
    tag     rewritten.$2$1.${hostname}
  </rule>
</match>

# It will get "rewritten.game.pool"
<match app.game.pool.activity>
  @type rewrite_tag_filter
  <rule>
    key     domain
    pattern ^.+$
    tag     rewritten.${tag_parts[1]}.${tag_parts[2]}
  </rule>
</match>
```

### Altering Labels

In addition to changing tags, you can also change event's route by setting
 the label for the re-emitted event.

For example, given this configuration:

```
<match apache.access>
  @type rewrite_tag_filter
  <rule>
    key     domain
    pattern ^www\.example\.com$
    tag     web.${tag}
  </rule>
  <rule>
    key     domain
    pattern ^(.*)\.example\.com$
    tag     other.$1
    label   @other
  </rule>
</match>

<label @other>
  <match other.**>
    @type stdout
  </match>
</label>
```

message: `{"domain": "www.example.com"}` will get its tag changed to 
`web.apache.access`, while message 
`{"domain": "api.example.com"}` will get its tag changed to `other.api` and
 be sent to label `@other`, which must be defined with `<label>`.

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
https://developer.smartnews.com/blog/2013/09/02/an-effective-log-management-technique-which-uses-fluentd-and-s3/

- fluentd(td-agent) の導入 : Raccoon Tech Blog [株式会社ラクーン 技術戦略部ブログ]<br>
http://techblog.raccoon.ne.jp/archives/35031163.html

- fluent-plugin-rewrite-tag-filter v1.4.1 をリリースしました #fluentd<br>
http://y-ken.hatenablog.com/entry/fluent-plugin-rewrite-tag-filter-v1.4.1

## TODO

Pull requests are very welcome!!

## Copyright

Copyright :  Copyright (c) 2012- Kentaro Yoshida (@yoshi_ken)  
License   :  Apache License, Version 2.0

