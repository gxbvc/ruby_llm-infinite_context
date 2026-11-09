# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"

module RubyLLM
  module InfiniteContext
    # The live smoke script is disabled by default: it must
    # refuse every live mode, and its free --plan mode must read no key,
    # open no socket and create no ledger. The script runs in a subprocess
    # with every key-like variable stripped and HOME pointed at an empty
    # temp dir, so a ledger or state file written anywhere would show up.
    class SmokeHoldTest < Minitest::Test
      SCRIPT = File.expand_path("../bench/smoke_test.rb", __dir__)
      REFUSAL = "REFUSED: the live smoke test is disabled by default (SMOKE_ENABLED is false)."

      def run_script(*args, extra_env: {})
        env = ENV.to_h.reject { |k, _| k =~ /KEY|TOKEN|SECRET|ANTHROPIC|OPENAI|FIREWORKS|XAI/i }
        Dir.mktmpdir("smoke-hold") do |home|
          env = env.merge("HOME" => home).merge(extra_env)
          stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, *args, unsetenv_others: true)
          [stdout, stderr, status, Dir.children(home)]
        end
      end

      def test_live_modes_and_abbreviations_are_refused_before_anything_loads
        [%w[--run], %w[--ru], %w[--r], %w[--yes], %w[--y], %w[--plan --run], %w[--run --plan]].each do |args|
          stdout, stderr, status, home_files = run_script(*args)
          refute status.success?, args.inspect
          assert_includes stderr, REFUSAL, args.inspect
          assert_includes stderr, "No key was read", args.inspect
          assert_empty stdout, args.inspect
          assert_empty home_files, "#{args.inspect}: nothing may be created"
        end
      end

      def test_live_mode_with_a_models_list_is_refused_too
        [%w[--run --models deepseek,glm], %w[--run --models haiku], %w[--run --models=glm]].each do |args|
          stdout, stderr, status, home_files = run_script(*args)
          refute status.success?, args.inspect
          assert_includes stderr, REFUSAL, args.inspect
          assert_empty stdout
          assert_empty home_files
        end
      end

      def test_malformed_models_arguments_are_refused
        [%w[--plan --models], ["--plan", "--models", "a b"], %w[--plan --models a --models b], %w[--plan --models=glm],
          ["--plan", "--models", "Deepseek"], ["--plan", "--models", "x;y"]].each do |args|
          _, stderr, status, home_files = run_script(*args)
          refute status.success?, args.inspect
          assert_includes stderr, REFUSAL, args.inspect
          assert_empty home_files
        end
      end

      def test_plan_with_an_unknown_model_aborts_without_a_plan
        stdout, stderr, status, home_files = run_script("--plan", "--models", "bogus")
        refute status.success?
        assert_match(/unknown model "bogus"/, stderr)
        assert_empty stdout
        assert_empty home_files
      end

      def test_a_fireworks_only_plan_runs_free_and_names_no_anthropic_file
        stdout, stderr, status, home_files = run_script("--plan", "--models", "deepseek,glm")
        assert status.success?, stderr
        assert_empty home_files, "nothing is created and no key file is read"
        refute_includes stdout, "anthropic.key"
        refute_includes stdout, "claude-haiku-4-5"
        assert_includes stdout, "infinite-context-bench/fireworks.key"
        assert_includes stdout, "ruby_llm-infinite_context/bench-ledger.json"
        assert_includes stdout, "sub-cap $0.90"
      end

      def test_no_arguments_prints_usage_and_does_nothing
        _, stderr, status, home_files = run_script
        refute status.success?
        assert_match(/usage: smoke_test.rb --plan/, stderr)
        assert_empty home_files
      end

      def test_a_live_run_is_refused_even_with_keys_in_the_environment
        stdout, stderr, status, home_files = run_script("--run",
          extra_env: {"ANTHROPIC_API_KEY" => "placeholder-not-a-key", "FIREWORKS_API_KEY" => "placeholder-not-a-key"})
        refute status.success?
        assert_includes stderr, REFUSAL
        assert_empty stdout
        assert_empty home_files
      end

      def test_the_script_is_locked_by_a_constant_a_person_must_edit
        source = File.read(SCRIPT)
        assert_match(/^\s*SMOKE_ENABLED = false$/, source)
        assert_match(/^\s*PAID_RUNS_ENABLED = false$/, File.read(File.expand_path("../bench/run_bench.rb", __dir__)))
      end

      def test_plan_prints_the_pinned_facts_and_creates_nothing
        stdout, stderr, status, home_files = run_script("--plan")
        assert status.success?, stderr
        assert_empty home_files, "--plan must not create the ledger or its directory"
        assert_includes stdout, ".local/state/ruby_llm-infinite_context/bench-ledger.json"
        refute_includes stdout, "smoke-ledger", "one shared ledger, no separate smoke ledger"
        assert_includes stdout, "ONE ledger for all bench runs, total $20.00"
        assert_includes stdout, "sub-cap $0.90, enforced by the guard"
        assert_includes stdout, "infinite-context-bench/anthropic.key"
        assert_includes stdout, "infinite-context-bench/fireworks.key"
        order = stdout[/order: .*/]
        assert_operator order.index("deepseek-v4p1-flash"), :<, order.index("claude-haiku-4-5")
        assert_operator order.index("claude-haiku-4-5"), :<, order.index("glm-5p3-flash")
        assert_includes order, "only after a single-request gate"
        assert_includes stdout, "max_retries 0"
        assert_includes stdout, "input margin 2000 tokens"
        assert_includes stdout, "settlement reservation"
        assert_includes stdout, "POST https://api.fireworks.ai/inference/v1/chat/completions"
        assert_includes stdout, "accounts/fireworks/models/glm-5p3-flash"
        assert_includes stdout, "accounts/fireworks/models/deepseek-v4p1-flash"
        assert_includes stdout, "claude-haiku-4-5"
        assert_equal 3, stdout.scan("source: https://").size, "every price names its source page"
        assert_includes stdout, "synthetic"
      end
    end
  end
end
