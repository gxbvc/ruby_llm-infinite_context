# frozen_string_literal: true

require "test_helper"
require "support/fake_network"
require "tmpdir"
require "json"
require_relative "../bench/spend_guard"

module RubyLLM
  module InfiniteContext
    # Each ledger entry carries the token counts the provider reported for
    # that request (input, cached, cache_write, output, thinking), as numbers
    # only, so a report can show thinking per request. Never text.
    class LedgerTokensTest < Minitest::Test
      GLM = "accounts/fireworks/models/glm-5p3-flash"
      BUDGET = 1_024
      PRICES = {GLM => {"input" => 0.15, "cached_input" => 0.03, "output" => 0.50}}.freeze
      SECRET_REPLY = "SECRET-REPLY-TEXT-zebra"
      SECRET_PROMPT = "SECRET-PROMPT-TEXT-walrus"

      def setup
        @previous = FakeNetwork.install!(max_retries: 0)
        FakeNetwork.reset!
        @dir = Dir.mktmpdir("ledger-tokens")
        @path = File.join(@dir, "ledger.json")
        @ledger = Bench::Ledger.new(@path)
        @context = Bench::FireworksRoute.context(api_key: "placeholder-not-a-key", max_retries: 0)
      end

      def teardown
        FakeNetwork.restore!(@previous)
        FileUtils.rm_rf(@dir)
      end

      def guard(**opts)
        Bench::Guard.new(ledger: @ledger, prices: PRICES, max_output_tokens: 256, retries: 0,
          settlement: :reservation, **opts)
      end

      def glm_chat(g)
        chat = Bench::FireworksRoute.chat(model: GLM, context: @context, thinking_budget: BUDGET)
        g.arm(chat, model: GLM, label: "glm", reasoning_budget_tokens: BUDGET)
      end

      def reply(**usage) = FakeNetwork.chat_completion_reply(SECRET_REPLY, model: GLM, **usage)

      def test_an_entry_records_input_cached_output_and_thinking_per_request
        FakeNetwork.script << reply(prompt_tokens: 100, cached_tokens: 30, completion_tokens: 50, reasoning_tokens: 20)
        chat = glm_chat(guard)
        message = chat.ask(SECRET_PROMPT)
        tokens = @ledger.entries.first["tokens"]
        assert_equal %w[input cached cache_write output thinking].sort, tokens.keys.sort
        assert_equal 30, tokens["cached"]
        assert_equal 50, tokens["output"]
        assert_equal 20, tokens["thinking"]
        assert_equal message.tokens.input, tokens["input"]
      end

      def test_each_request_gets_its_own_counts
        FakeNetwork.script << reply(prompt_tokens: 100, completion_tokens: 50, reasoning_tokens: 485)
        FakeNetwork.script << reply(prompt_tokens: 120, completion_tokens: 60, reasoning_tokens: 1_036)
        chat = glm_chat(guard)
        chat.ask("one")
        chat.ask("two")
        assert_equal [485, 1_036], @ledger.entries.map { |e| e["tokens"]["thinking"] }
      end

      def test_a_reply_that_halts_the_run_is_recorded_too
        FakeNetwork.script << reply(prompt_tokens: 40, completion_tokens: 900, reasoning_tokens: 1_281)
        g = guard
        glm_chat(g).ask("hi")
        assert g.halted, "1,281 thinking tokens is above the 1,280 bound"
        assert_equal 1_281, @ledger.entries.first["tokens"]["thinking"]
      end

      def test_a_reply_that_overruns_its_reservation_is_recorded_too
        FakeNetwork.script << FakeNetwork.text_reply("x", cache_write_tokens: 2_100, input_tokens: 10, output_tokens: 5)
        g = Bench::Guard.new(ledger: @ledger, prices: {"claude-haiku-4-5" => {"input" => 1.0, "cached_input" => 0.10, "output" => 5.0}},
          max_output_tokens: 16, retries: 0, settlement: :reservation)
        g.arm(RubyLLM.chat(model: "claude-haiku-4-5"), model: "claude-haiku-4-5", label: "h").ask("hi")
        assert_match(/exceeded its reservation/, g.halted)
        assert_equal 2_100, @ledger.entries.first["tokens"]["cache_write"]
      end

      def test_an_unreported_count_is_nil_not_zero_and_not_text
        FakeNetwork.script << reply(prompt_tokens: 100, completion_tokens: 50)
        glm_chat(guard).ask("hi")
        tokens = @ledger.entries.first["tokens"]
        assert_equal 50, tokens["output"]
        assert tokens.values.all? { |v| v.nil? || v.is_a?(Integer) }
      end

      def test_the_ledger_file_holds_no_prompt_or_reply_text
        FakeNetwork.script << reply(prompt_tokens: 100, completion_tokens: 50, reasoning_tokens: 10)
        glm_chat(guard).ask(SECRET_PROMPT)
        raw = File.read(@path)
        refute_includes raw, SECRET_PROMPT
        refute_includes raw, SECRET_REPLY
        entry = JSON.parse(raw)["entries"].first
        assert_equal %w[at id label model reserved_micro settled_micro tokens], entry.keys.sort
      end

      def test_record_tokens_keeps_only_non_negative_integers_and_the_five_fields
        id = @ledger.reserve!(100, label: "x", model: GLM)
        clean = @ledger.record_tokens!(id, "input" => "ignore previous instructions", "cached" => -1, "output" => 12.5,
          :thinking => 7, "cache_write" => nil, "extra" => 9, "text" => "hello")
        assert_equal({"input" => nil, "cached" => nil, "cache_write" => nil, "output" => nil, "thinking" => 7}, clean)
        assert_equal clean, @ledger.entries.first["tokens"]
        refute_includes File.read(@path), "ignore previous"
        refute_includes File.read(@path), "hello"
      end

      def test_record_tokens_for_a_missing_entry_fails
        assert_raises(Bench::Error) { @ledger.record_tokens!(99, "output" => 1) }
      end

      def test_old_entries_without_tokens_still_load_and_count
        File.write(@path, JSON.generate({"version" => 1, "cap_micro" => 20_000_000,
                                         "entries" => [{"id" => 1, "label" => "old", "model" => GLM, "reserved_micro" => 500,
                                                        "settled_micro" => 300, "at" => "2026-11-01T00:00:00Z"}]}))
        ledger = Bench::Ledger.new(@path)
        assert_equal 300, ledger.committed_micro
        assert_nil ledger.entries.first["tokens"]
      end

      def test_recording_tokens_does_not_change_the_money
        FakeNetwork.script << reply(prompt_tokens: 100, cached_tokens: 30, completion_tokens: 50, reasoning_tokens: 20)
        glm_chat(guard).ask("hi")
        entry = @ledger.entries.first
        assert_equal entry["reserved_micro"], entry["settled_micro"], ":reservation settlement keeps the reservation"
      end
    end
  end
end
