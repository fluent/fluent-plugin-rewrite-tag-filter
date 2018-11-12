# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)

Gem::Specification.new do |s|
  s.name        = "fluent-plugin-rewrite-tag-filter"
  s.version     = "2.1.1"
  s.license     = "Apache-2.0"
  s.authors     = ["Kentaro Yoshida"]
  s.email       = ["y.ken.studio@gmail.com"]
  s.homepage    = "https://github.com/fluent/fluent-plugin-rewrite-tag-filter"
  s.summary     = %q{Fluentd Output filter plugin. It has designed to rewrite tag like mod_rewrite. Re-emmit a record with rewrited tag when a value matches/unmatches with the regular expression. Also you can change a tag from apache log by domain, status-code(ex. 500 error), user-agent, request-uri, regex-backreference and so on with regular expression.}

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  s.add_development_dependency "test-unit", ">= 3.1.0"
  s.add_development_dependency "rake"
  s.add_runtime_dependency "fluentd", [">= 0.14.2", "< 2"]
  s.add_runtime_dependency "fluent-config-regexp-type"
end
