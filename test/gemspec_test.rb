# frozen_string_literal: true

require "test_helper"
require "rubygems"

module RubyLLM
  module InfiniteContext
    # What the published gem would be: name, autoload path, version, and the
    # file list (an allowlist: no bench, tests, keys, ledgers or results).
    class GemspecTest < Minitest::Test
      ROOT = File.expand_path("..", __dir__)
      SPEC = Gem::Specification.load(File.join(ROOT, "ruby_llm-infinite_context.gemspec"))

      def test_the_gem_is_named_with_an_underscore_and_bundler_can_autoload_it
        assert_equal "ruby_llm-infinite_context", SPEC.name
        # Bundler.require maps "a-b_c" to require "a/b_c".
        assert File.file?(File.join(ROOT, "lib", "#{SPEC.name.tr("-", "/")}.rb"))
        assert_equal "https://github.com/gxbvc/ruby_llm-infinite_context", SPEC.homepage
      end

      def test_version_license_and_ruby_requirement
        assert_equal "0.2.2", SPEC.version.to_s
        assert_equal RubyLLM::InfiniteContext::VERSION, SPEC.version.to_s
        assert_equal ["MIT"], SPEC.licenses
        assert_operator SPEC.required_ruby_version.to_s, :==, ">= 3.2.0"
        assert_equal %w[activerecord ruby_llm], SPEC.runtime_dependencies.map(&:name).sort
        assert_match(/## \[0\.2\.0\]/, File.read(File.join(ROOT, "CHANGELOG.md")))
        assert_match(/MIT License/, File.read(File.join(ROOT, "LICENSE.txt")))
      end

      def test_the_file_list_is_an_allowlist_that_never_ships_bench_tests_keys_or_state
        files = SPEC.files
        %w[LICENSE.txt README.md CHANGELOG.md THIRD_PARTY_NOTICES.md lib/ruby_llm/infinite_context.rb
          lib/ruby_llm/infinite_context/chat_options.rb
          lib/ruby_llm/infinite_context/encryption.rb
          lib/generators/ruby_llm/infinite_context/install/install_generator.rb
          lib/generators/ruby_llm/infinite_context/install/templates/migration.rb.tt].each do |f|
          assert_includes files, f
        end
        assert files.all? { |f| f.start_with?("lib/") || %w[LICENSE.txt README.md CHANGELOG.md THIRD_PARTY_NOTICES.md].include?(f) }, files.inspect
        refute(files.any? { |f| f =~ %r{\A(bench|test|docs|bin|\.github)/} })
        refute(files.any? { |f| f =~ /\.(key|sqlite3|lock|gem)\z|ledger|results|corpus/ })
      end
    end
  end
end
