# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The suite pins RubyLLM 2.1.1: the bench spend guard reads RubyLLM 2.1
# transport settings and fails closed on 2.2. To test the library on another
# RubyLLM, set RUBY_LLM_VERSION (the bench tests then fail closed by design).
gem "ruby_llm", ENV.fetch("RUBY_LLM_VERSION", "2.1.1")

gem "irb"
gem "minitest", "~> 5.16"
gem "rake", "~> 13.0"
gem "standard", "~> 1.3"

group :test do
  gem "activejob", "~> 8.0"
  gem "activerecord", "~> 8.0"
  gem "sqlite3", ">= 2.0"
end
