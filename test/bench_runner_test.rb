# frozen_string_literal: true

require "test_helper"
require "support/fake_network"
require "tmpdir"
require_relative "../bench/run_bench"

module RubyLLM
  module InfiniteContext
    # The bench Runner end to end over the in-process fake network: real
    # RubyLLM chats, real hooks, a real ledger file. No key, no socket.
    class BenchRunnerTest < Minitest::Test
      MODEL = "claude-haiku-4-5"

      def setup
        @previous = FakeNetwork.install!(max_retries: 0)
        FakeNetwork.reset!
        @dir = Dir.mktmpdir("bench-runner")
        @corpus = build_corpus(File.join(@dir, "corpus"))
      end

      def teardown
        FakeNetwork.restore!(@previous)
        FileUtils.rm_rf(@dir)
        reconnect_test_db # the Runner may have left the shared test database
      end

      def build_corpus(dir)
        FileUtils.mkdir_p(dir)
        entries = [
          {"kind" => "user", "text" => "the RMA number is 3125 and the co-op approved the drip plan " + "detail " * 80},
          {"kind" => "assistant", "text" => "noted: RMA 3125, drip approved " + "reply " * 90},
          {"kind" => "tool", "text" => "grep -rn rma exports/coop.csv"},
          {"kind" => "echo", "text" => "exports/coop.csv:17: RMA 3125, drip, signed off " + "row " * 150},
          {"kind" => "user", "text" => "thanks " + "more " * 120},
          {"kind" => "assistant", "text" => "done " + "wrap " * 110}
        ]
        File.write(File.join(dir, "session-0000.jsonl"), entries.map { |e| JSON.generate(e) }.join("\n"))
        File.write(File.join(dir, "questions.jsonl"), [
          {"session" => 0, "question" => "What was the RMA number?", "gold" => "3125"},
          {"session" => 0, "question" => "Which plan did the co-op approve?", "gold" => "drip"}
        ].map { |q| JSON.generate(q) }.join("\n"))
        dir
      end

      def ledger(cap: 20.0) = Bench::Ledger.new(File.join(@dir, "ledger.json"), cap_usd: cap)

      def runner(cap: 20.0, baselines: %w[tree cutoff rolling], budgets: [600], **guard_opts)
        @guard = Bench::Guard.new(ledger: ledger(cap: cap), **guard_opts)
        Bench::Runner.new(corpus: @corpus, compactor: MODEL, reader: MODEL, budgets: budgets,
          out: File.join(@dir, "out"), guard: @guard, baselines: baselines, fresh: false)
      end

      # -- CLI ---------------------------------------------------------------

      def test_cli_yes_is_a_parsed_flag_the_refusal_layer_rejects
        options = Bench::CLI.parse(["--yes", "--compactor", "m", "--reader", "r"])
        assert options[:yes]
        assert_raises(Bench::PaidRunsDisabled) { Bench::CLI.refuse_paid!(options) }
      end

      def test_cli_defaults
        options = Bench::CLI.parse([])
        assert_equal Bench::CAP_LIMIT, options[:cap]
        assert_equal %w[tree cutoff rolling], options[:baselines]
        assert_equal Bench::Ledger.default_path, options[:ledger]
        assert_equal 1024, options[:max_output_tokens]
      end

      def preflight_options(*extra)
        Bench::CLI.parse(["--corpus", @corpus, "--compactor", MODEL, "--reader", MODEL,
          "--ledger", File.join(@dir, "ledger.json"), *extra])
      end

      def test_preflight_passes_on_a_good_setup_and_creates_no_ledger
        info = Bench::CLI.preflight!(preflight_options)
        assert_equal 1, info[:sessions]
        assert_equal 2, info[:questions]
        assert_nil info[:ledger]
        refute File.exist?(File.join(@dir, "ledger.json"))
      end

      def test_preflight_rejects_a_cap_over_the_default_total
        error = assert_raises(Bench::Error) { Bench::CLI.preflight!(preflight_options("--cap", "20.01")) }
        assert_match(/over the default \$20\.0 total cap/, error.message)
      end

      def test_preflight_rejects_unpriced_models_and_a_bad_output_bound
        assert_raises(Bench::Error) { Bench::CLI.preflight!(Bench::CLI.parse(["--corpus", @corpus, "--compactor", "x-unpriced", "--reader", MODEL])) }
        error = assert_raises(Bench::Error) { Bench::CLI.preflight!(preflight_options("--max-output-tokens", "0")) }
        assert_match(/positive integer/, error.message)
      end

      def test_preflight_rejects_a_missing_corpus_and_questions_for_missing_sessions
        assert_raises(Bench::Error) { Bench::CLI.preflight!(Bench::CLI.parse(["--corpus", "/nonexistent-#{rand(10_000)}", "--compactor", MODEL, "--reader", MODEL])) }
        File.write(File.join(@corpus, "questions.jsonl"), JSON.generate({session: 5, question: "q", gold: "g"}))
        error = assert_raises(Bench::Error) { Bench::CLI.preflight!(preflight_options) }
        assert_match(/do not exist/, error.message)
      end

      def test_preflight_reports_an_existing_ledgers_remaining_budget
        l = ledger
        l.reserve!(1_000_000, label: "earlier-run", model: "m")
        info = Bench::CLI.preflight!(preflight_options)
        assert_in_delta 19.0, info[:ledger][:remaining_usd], 0.001
      end

      # -- a full round over the fake network ---------------------------------

      def test_a_full_round_every_provider_request_has_exactly_one_ledger_entry
        r = runner
        results = r.run

        requests = FakeNetwork.requests.size
        entries = @guard.ledger.entries
        assert_operator requests, :>, 0
        assert_equal requests, entries.size, "no provider request without a reservation, none reserved twice"
        labels = entries.map { |e| e["label"] }.uniq
        assert_includes labels, "compactor-pump", "the pump's requests are counted"
        assert_includes labels, "reader-tree"
        assert_includes labels, "reader-cutoff"
        assert_includes labels, "reader-rolling"
        assert_includes labels, "compactor-rolling", "rolling merges are counted"
        assert entries.all? { |e| e["settled_micro"] }, "every reply was metered and settled"

        assert_operator results[:compactor_pump_usd], :>, 0
        assert_in_delta results[:round_spend_usd], Bench.micro_to_usd(@guard.ledger.committed_micro), 1e-9
        assert_equal 2, results[:budgets][600]["tree"][:n]
        assert File.exist?(File.join(@dir, "out", "results.json"))
        refute results.key?(:stopped)
      end

      def test_the_round_spend_is_on_one_shared_ledger_across_runs
        runner.run
        first = ledger.committed_micro

        FakeNetwork.reset!
        again = Bench::Runner.new(corpus: @corpus, compactor: MODEL, reader: MODEL, budgets: [600],
          out: File.join(@dir, "out2"), guard: Bench::Guard.new(ledger: ledger), baselines: %w[cutoff], fresh: false)
        again.run
        assert_operator ledger.committed_micro, :>, first, "the second run adds to the same tally"
      end

      def test_a_round_that_hits_the_cap_stops_before_the_next_request_and_keeps_partial_results
        # Each reply costs about 5,100 micro-dollars (1,000 output tokens), under its reservation.
        20.times { FakeNetwork.script << FakeNetwork.text_reply("ok", input_tokens: 100, output_tokens: 1000) }
        r = runner(cap: 0.012) # 12,000 micro-dollars: room for two such requests, not three
        assert_raises(Bench::Error) { r.run }

        assert_operator FakeNetwork.requests.size, :<=, 3
        assert_operator @guard.ledger.committed_micro, :<=, @guard.ledger.cap_micro
        assert_equal FakeNetwork.requests.size, @guard.ledger.entries.size
        written = JSON.parse(File.read(File.join(@dir, "out", "results.json")))
        assert written["stopped"], "a stopped round says why, with what it scored so far"
        assert written["round_spend_usd"]
      end

      def test_a_halted_guard_stops_the_whole_round_before_scoring_uses_a_half_built_tree
        reply = FakeNetwork.text_reply("no usage")
        reply.delete("usage")
        FakeNetwork.script << reply
        r = runner(baselines: %w[tree])
        assert_raises(Bench::Error) { r.run }
        written = JSON.parse(File.read(File.join(@dir, "out", "results.json")))
        assert_match(/Halted|no metered cost/, written["stopped"])
        assert_nil written["budgets"]["600"], "no reader scoring ran after the halt"
      end

      # -- per-question zoom isolation (real tools, real chat) -----------------

      def test_each_question_gets_a_fresh_turn_so_the_guard_and_counts_do_not_carry
        tree = Tree.for("bench-runner-zoom", compactor: MODEL)
        4.times { |i| tree.append(:user, "message #{i}") }
        questions = JSON.parse("[" + File.readlines(File.join(@corpus, "questions.jsonl")).join(",") + "]")

        2.times do # one scripted exchange per question: zoom, the SAME zoom again, then the answer
          FakeNetwork.script << FakeNetwork.tool_reply("zoom", {"id" => 0, "n" => 2}, id: "toolu_a")
          FakeNetwork.script << FakeNetwork.tool_reply("zoom", {"id" => 0, "n" => 2}, id: "toolu_b")
          FakeNetwork.script << FakeNetwork.text_reply("answer 3125 drip")
        end

        r = runner(baselines: %w[tree])
        score = r.score_tree([[tree, 0]], questions, 4_000)

        # Within one question the repeat is refused (one event); the second
        # question's fresh turn allows the same line again. A cumulative
        # count would have reported 3 for the pair.
        assert_equal 2, score[:zooms]
        assert_equal 2, tree.zoom_events.count
        assert_equal 2, tree.zoom_events.distinct.pluck(:session).size, "one turn id per question"
        assert_equal [1, 1], tree.zoom_events.order(:id).pluck(:steps)
        assert_equal 6, @guard.ledger.entries.size, "three provider requests per question, each reserved"
        assert_equal 2, score[:right] + score[:partial] + score[:wrong]
      end

      # -- rolling compaction is counted ---------------------------------------

      def test_rolling_merges_are_guarded_requests_in_the_same_ledger
        r = runner
        entries = File.readlines(File.join(@corpus, "session-0000.jsonl")).map { |l| JSON.parse(l) }
        lines = r.rolling_lines(entries, 500)
        assert_operator FakeNetwork.requests.size, :>, 0, "a tiny budget forces merges"
        assert_equal FakeNetwork.requests.size, @guard.ledger.entries.size
        assert @guard.ledger.entries.all? { |e| e["label"] == "compactor-rolling" }
        assert_operator lines.sum(&:bytesize), :<=, 500 + 200
      end

      def test_cutoff_makes_no_compactor_request
        r = runner(baselines: %w[cutoff])
        r.run
        labels = @guard.ledger.entries.map { |e| e["label"] }.uniq
        assert_equal ["reader-cutoff"], labels
      end
    end
  end
end
