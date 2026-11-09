# frozen_string_literal: true

require "test_helper"
require "support/fake_network"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../bench/run_bench"

module RubyLLM
  module InfiniteContext
    # Negative tests for the default that keeps paid runs off. Two kinds:
    #
    # - the real script in a subprocess with key-like environment variables
    #   stripped: --yes must be refused with a fixed error before anything
    #   is built;
    # - the Runner API called DIRECTLY (not through the CLI): with no
    #   in-process fake network installed it must raise before any chat,
    #   database, directory or corpus read, with RubyLLM.chat stubbed to
    #   fail the test if it is ever reached.
    class BenchHoldTest < Minitest::Test
      SCRIPT = File.expand_path("../bench/run_bench.rb", __dir__)
      REFUSAL = "REFUSED: paid benchmark runs are disabled by default (PAID_RUNS_ENABLED is false)."
      MODEL = "claude-haiku-4-5"

      def run_script(*args, out_dir: nil)
        env = ENV.to_h.reject { |k, _| k =~ /KEY|TOKEN|SECRET|ANTHROPIC|OPENAI|FIREWORKS|XAI/i }
        Dir.mktmpdir("bench-hold") do |dir|
          out = out_dir || File.join(dir, "results")
          # unsetenv_others: only the filtered env reaches the child, so no
          # key-like variable can leak in from the parent.
          stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, *args, "--out", out,
            unsetenv_others: true)
          [stdout, stderr, status, File.exist?(out), Dir.children(dir)]
        end
      end

      def corpus_in(dir)
        File.write(File.join(dir, "session-0000.jsonl"), JSON.generate({kind: "user", text: "hi " * 300}))
        File.write(File.join(dir, "questions.jsonl"), JSON.generate({session: 0, question: "q", gold: "g"}))
        dir
      end

      # -- the CLI ---------------------------------------------------------

      def test_yes_is_refused_with_the_fixed_error
        stdout, stderr, status, out_created, = run_script("--yes", "--compactor", "m", "--reader", "r")
        refute status.success?
        assert_includes stderr, REFUSAL
        assert_includes stderr, "No model was initialized and no call was made."
        refute_includes stdout, "Preflight OK"
        refute out_created, "the refusal must come before any Runner.new creates the output dir"
      end

      def test_yes_is_refused_even_with_a_bad_corpus_and_no_models
        # Refusal precedes preflight: the error is the safety one, not a
        # preflight complaint about the missing corpus or models.
        _, stderr, status, = run_script("--yes", "--corpus", "/nonexistent/corpus")
        refute status.success?
        assert_includes stderr, REFUSAL
        refute_includes stderr, "preflight failed"
      end

      def test_option_abbreviations_of_yes_are_refused_too
        %w[--y --ye --yes].each do |flag|
          _, stderr, status, = run_script(flag, "--compactor", "m", "--reader", "r")
          refute status.success?, "#{flag} must not get past the disabled default"
          assert_includes stderr, REFUSAL, flag
        end
      end

      def test_yes_with_preflight_is_still_refused
        _, stderr, status, = run_script("--preflight", "--yes", "--compactor", "m", "--reader", "r")
        refute status.success?
        assert_includes stderr, REFUSAL
      end

      def test_without_yes_a_run_has_no_path_even_after_preflight
        Dir.mktmpdir("bench-hold-corpus") do |dir|
          corpus = corpus_in(dir)
          ledger = File.join(dir, "ledger.json")
          stdout, stderr, status, = run_script("--corpus", corpus, "--compactor", MODEL, "--reader", MODEL, "--ledger", ledger)
          refute status.success?
          assert_includes stdout, "preflight only; no model call was made"
          assert_includes stderr, REFUSAL
          refute File.exist?(ledger), "preflight must not create the ledger"
        end
      end

      def test_preflight_alone_works_makes_no_call_and_creates_no_ledger
        Dir.mktmpdir("bench-hold-corpus") do |dir|
          corpus = corpus_in(dir)
          ledger = File.join(dir, "ledger.json")
          stdout, _, status, = run_script("--preflight", "--corpus", corpus, "--compactor", MODEL, "--reader", MODEL, "--ledger", ledger)
          assert status.success?
          assert_includes stdout, "Preflight OK"
          refute File.exist?(ledger)
        end
      end

      def test_preflight_fails_closed_on_a_fireworks_model_without_an_explicit_price
        Dir.mktmpdir("bench-hold-corpus") do |dir|
          corpus = corpus_in(dir)
          fw = "accounts/fireworks/models/glm-5p3-flash"
          _, stderr, status, = run_script("--preflight", "--corpus", corpus, "--compactor", fw, "--reader", MODEL,
            "--ledger", File.join(dir, "l.json"))
          refute status.success?
          assert_includes stderr, "no explicit price entry"

          prices = File.join(dir, "prices.json")
          File.write(prices, JSON.generate({fw => {"input" => 0.15, "output" => 0.5}}))
          stdout, _, status, = run_script("--preflight", "--corpus", corpus, "--compactor", fw, "--reader", MODEL,
            "--ledger", File.join(dir, "l.json"), "--prices", prices)
          assert status.success?, "an explicit price entry lets preflight pass"
          assert_includes stdout, "Preflight OK"
        end
      end

      def test_preflight_fails_closed_on_an_unknown_model
        Dir.mktmpdir("bench-hold-corpus") do |dir|
          _, stderr, status, = run_script("--preflight", "--corpus", corpus_in(dir), "--compactor", "no-such-model-xyz",
            "--reader", MODEL, "--ledger", File.join(dir, "l.json"))
          refute status.success?
          assert_includes stderr, "no pricing for no-such-model-xyz"
        end
      end

      def test_the_constant_is_off_and_the_cli_layer_refuses_a_parsed_yes
        refute Bench::PAID_RUNS_ENABLED
        options = Bench::CLI.parse(["--yes", "--compactor", "m", "--reader", "r"])
        error = assert_raises(Bench::PaidRunsDisabled) { Bench::CLI.refuse_paid!(options) }
        assert_equal Bench::PAID_REFUSAL, error.message
      end

      # -- the Runner API called directly ------------------------------------

      # RubyLLM.chat fails the test if anything reaches it.
      def with_chat_trap
        calls = []
        trap = ->(*args, **kwargs) {
          calls << [args, kwargs]
          raise "RubyLLM.chat must never be called while paid runs are disabled"
        }
        RubyLLM.stub(:chat, trap) { yield calls }
      end

      def build_runner(dir, baselines: %w[tree cutoff rolling])
        ledger = Bench::Ledger.new(File.join(dir, "ledger.json"))
        guard = Bench::Guard.new(ledger: ledger)
        Bench::Runner.new(corpus: corpus_in(File.join(dir, "corpus").tap { |c| FileUtils.mkdir_p(c) }),
          compactor: MODEL, reader: MODEL, budgets: [4_000], out: File.join(dir, "out"),
          guard: guard, baselines: baselines, fresh: false)
      end

      def test_runner_new_refuses_without_the_fake_transport_and_touches_nothing
        refute Bench.offline_transport?
        with_chat_trap do |calls|
          Dir.mktmpdir("bench-hold-new") do |dir|
            out = File.join(dir, "never-created")
            guard = Bench::Guard.new(ledger: Bench::Ledger.new(File.join(dir, "ledger.json")))
            assert_raises(Bench::PaidRunsDisabled) do
              Bench::Runner.new(corpus: dir, compactor: MODEL, reader: MODEL, budgets: [4_000],
                out: out, guard: guard)
            end
            refute File.exist?(out), "Runner.new must raise before mkdir or database setup"
            assert_empty calls
          end
        end
      end

      def test_direct_run_with_the_tree_baseline_raises_before_any_chat_corpus_or_db_work
        with_chat_trap do |calls|
          Dir.mktmpdir("bench-hold-run") do |dir|
            # Built while the in-process fake transport is installed (the
            # only way a Runner can exist), then the real transport comes
            # back: run must refuse on its own first line.
            previous = FakeNetwork.install!
            runner = begin
              build_runner(dir, baselines: %w[tree])
            ensure
              FakeNetwork.restore!(previous)
            end
            refute Bench.offline_transport?
            trees_before = Tree.count

            assert_raises(Bench::PaidRunsDisabled) { runner.run }

            assert_empty calls, "no RubyLLM.chat call may happen"
            assert_equal trees_before, Tree.count, "no tree row: nothing past the gate ran"
            refute File.exist?(File.join(dir, "out", "results.json"))
          end
        end
      end

      def test_direct_run_refuses_before_reading_the_corpus
        with_chat_trap do |calls|
          runner = Bench::Runner.allocate # a bypass attempt: no initialize, no guard
          assert_raises(Bench::PaidRunsDisabled) { runner.run }
          assert_empty calls
        end
      end

      def test_the_pump_path_cannot_build_a_default_chat_and_halts_the_guard
        with_chat_trap do |calls|
          Dir.mktmpdir("bench-hold-pump") do |dir|
            previous = FakeNetwork.install!
            runner = begin
              build_runner(dir, baselines: %w[tree])
            ensure
              FakeNetwork.restore!(previous)
            end
            # The pump swallows per-node errors, so the refusal must surface
            # through the halted guard, not as a silently empty tree.
            file = File.join(dir, "corpus", "session-0000.jsonl")
            assert_raises(Bench::Halted) { runner.build_tree(file, 0) }
            assert_empty calls, "the pump must not reach a default RubyLLM.chat"
          end
        end
      end

      def test_new_chat_refuses_without_the_fake_transport
        with_chat_trap do |calls|
          Dir.mktmpdir("bench-hold-chat") do |dir|
            previous = FakeNetwork.install!
            runner = begin
              build_runner(dir)
            ensure
              FakeNetwork.restore!(previous)
            end
            assert_raises(Bench::PaidRunsDisabled) { runner.new_chat(model: MODEL, label: "x") }
            assert_empty calls
          end
        end
      end

      def test_a_lookalike_adapter_name_does_not_count_as_offline
        # Only the registered FakeNetwork::Adapter class counts, not a name.
        previous = FakeNetwork.install!
        begin
          assert Bench.offline_transport?
          Faraday::Adapter.register_middleware(fake_network: Faraday::Adapter::NetHttp)
          refute Bench.offline_transport?, "a different class under the same name is not the fake network"
        ensure
          Faraday::Adapter.register_middleware(fake_network: FakeNetwork::Adapter)
          FakeNetwork.restore!(previous)
        end
      end
    end
  end
end
