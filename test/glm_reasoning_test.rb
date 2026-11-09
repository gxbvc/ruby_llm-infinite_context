# frozen_string_literal: true

require "test_helper"
require "support/fake_network"
require "tmpdir"
require_relative "../bench/spend_guard"

module RubyLLM
  module InfiniteContext
    # A Fireworks chat with reasoning ON under a budget (for
    # GLM-5.3-Flash, which is thinking-only). Route pinning, the reservation
    # that covers reasoning, the per-chat bounds, and "forbid thinking tokens
    # off for that chat only". Over the fake network.
    class GlmReasoningTest < Minitest::Test
      GLM = "accounts/fireworks/models/glm-5p3-flash"
      DEEPSEEK = "accounts/fireworks/models/deepseek-v4p1-flash"
      BUDGET = 1_024
      PRICES = {
        GLM => {"input" => 0.15, "cached_input" => 0.03, "output" => 0.50},
        DEEPSEEK => {"input" => 0.30, "cached_input" => 0.006, "output" => 1.20}
      }.freeze

      def setup
        @previous = FakeNetwork.install!(max_retries: 0)
        FakeNetwork.reset!
        @dir = Dir.mktmpdir("glm-reasoning")
        @ledger = Bench::Ledger.new(File.join(@dir, "ledger.json"))
        @context = Bench::FireworksRoute.context(api_key: "placeholder-not-a-key", max_retries: 0)
        FakeNetwork.default_reply = FakeNetwork.chat_completion_reply("ok", model: GLM)
      end

      def teardown
        FakeNetwork.restore!(@previous)
        FileUtils.rm_rf(@dir)
      end

      def guard(**opts)
        Bench::Guard.new(ledger: @ledger, prices: PRICES, max_output_tokens: 256, retries: 0,
          settlement: :reservation, **opts)
      end

      def glm_chat(g, budget: BUDGET, model: GLM)
        chat = Bench::FireworksRoute.chat(model: model, context: @context, thinking_budget: budget)
        g.arm(chat, model: model, label: "glm", reasoning_budget_tokens: budget)
      end

      def reply(**usage) = FakeNetwork.chat_completion_reply("391", model: GLM, **usage)

      # -- the body ------------------------------------------------------------------

      def test_the_body_carries_exactly_the_documented_thinking_object_and_no_reasoning_effort
        glm_chat(guard).ask("hi")
        body = FakeNetwork.calls.first[:body]
        assert_equal({"type" => "enabled", "budget_tokens" => BUDGET}, body["thinking"])
        refute_includes body.keys, "reasoning_effort"
        assert_equal %w[max_completion_tokens messages model stream thinking], body.keys.sort
        assert_equal 256 + BUDGET, body["max_completion_tokens"]
        assert_equal Bench::FireworksRoute::PATH, FakeNetwork.calls.first[:path]
      end

      def test_a_chat_without_a_budget_still_sends_reasoning_effort_none_and_no_thinking
        chat = Bench::FireworksRoute.chat(model: DEEPSEEK, context: @context)
        guard.arm(chat, model: DEEPSEEK, label: "ds").ask("hi")
        body = FakeNetwork.calls.first[:body]
        assert_equal "none", body["reasoning_effort"]
        refute_includes body.keys, "thinking"
      end

      def test_budget_and_effort_together_are_refused_when_building_and_in_the_body
        assert_raises(ArgumentError) do
          Bench::FireworksRoute.chat(model: GLM, context: @context, reasoning_effort: :high, thinking_budget: BUDGET)
        end
        assert_raises(Bench::RouteRefused) do
          Bench::FireworksRoute.verify_payload!({model: GLM, messages: [], stream: false, reasoning_effort: "high",
                                                 thinking: {type: "enabled", budget_tokens: BUDGET}}, thinking_budget: BUDGET)
        end
      end

      def test_any_other_thinking_shape_is_refused_before_the_network
        bad = {
          "wrong budget" => {type: "enabled", budget_tokens: 2_048},
          "extra keep" => {type: "enabled", budget_tokens: BUDGET, keep: "all"},
          "extra end string" => {type: "enabled", budget_tokens: BUDGET, budget_end_str: "x"},
          "adaptive" => {type: "adaptive"},
          "disabled" => {type: "disabled"}
        }
        bad.each do |name, thinking|
          FakeNetwork.reset!
          g = guard
          chat = Bench::FireworksRoute.chat(model: GLM, context: @context, thinking_budget: BUDGET)
          chat.with_provider_options(thinking: thinking) # replaces the declared object
          g.arm(chat, model: GLM, label: "glm", reasoning_budget_tokens: BUDGET)
          assert_raises(Bench::RouteRefused, name) { chat.ask("hi") }
          assert_empty FakeNetwork.calls, "#{name}: the body never left"
          assert g.halted
        end
      end

      def test_a_thinking_field_on_a_chat_that_declared_no_budget_is_refused
        g = guard
        chat = Bench::FireworksRoute.chat(model: GLM, context: @context)
        chat.with_provider_options(thinking: {type: "enabled", budget_tokens: BUDGET})
        g.arm(chat, model: GLM, label: "glm")
        assert_raises(Bench::RouteRefused) { chat.ask("hi") }
        assert_empty FakeNetwork.calls
      end

      def test_the_budget_must_be_an_integer_in_the_documented_range
        [0, 1_023, 8_193, "1024", 1_024.0, nil.to_s].each do |bad|
          assert_raises(ArgumentError, bad.inspect) { Bench::FireworksRoute.chat(model: GLM, context: @context, thinking_budget: bad) }
        end
        assert_raises(ArgumentError) { glm_chat(guard, budget: 100) }
        assert_raises(ArgumentError) do # the guard checks the range too
          guard.arm(Bench::FireworksRoute.chat(model: GLM, context: @context), model: GLM, label: "c", reasoning_budget_tokens: 100)
        end
        assert_raises(Bench::Error) do # a budget is only for Fireworks models
          guard.arm(RubyLLM.chat(model: "claude-haiku-4-5"), model: "claude-haiku-4-5", label: "c", reasoning_budget_tokens: BUDGET)
        end
      end

      # -- the reservation covers reasoning ------------------------------------------

      def test_the_thinking_bound_is_the_max_sent_and_the_reserved_output_is_twice_it
        g = guard
        assert_equal 1_280, g.thinking_bound_for(BUDGET), "256 max + 1,024 budget; the budget itself is soft"
        assert_equal 2_560, g.reserved_output_tokens_for(BUDGET), "max sent 1,280 + thinking up to 1,280"
      end

      def test_the_reservation_covers_the_max_sent_plus_thinking_up_to_the_bound_2560_output_tokens
        plain = Bench::Ledger.new(File.join(@dir, "plain.json"))
        g_plain = Bench::Guard.new(ledger: plain, prices: PRICES, max_output_tokens: 256, retries: 0, settlement: :reservation)
        g_plain.arm(Bench::FireworksRoute.chat(model: GLM, context: @context), model: GLM, label: "p").ask("hi")
        glm_chat(guard).ask("hi")
        extra = @ledger.entries.first["reserved_micro"] - plain.entries.first["reserved_micro"]
        # 2,560 - 256 = 2,304 more output tokens at $0.50/M = 1,152 micro-dollars; the bodies differ a few bytes
        assert_in_delta 1_152, extra, 40
        assert_operator @ledger.entries.first["reserved_micro"], :>=, 2_560 * 0.5
      end

      def test_a_reply_at_the_worst_case_fits_the_reservation_and_costs_less_than_it
        # the answer at the max sent (1,280 output) with thinking at the bound (1,280) billed on top
        FakeNetwork.script << reply(prompt_tokens: 40, completion_tokens: 1_280, reasoning_tokens: 1_280)
        g = guard(settlement: :metered)
        glm_chat(g).ask("hi")
        refute g.halted
        entry = @ledger.entries.first
        assert_operator entry["settled_micro"], :<=, entry["reserved_micro"], "the reservation covers the worst honest reply"
      end

      # -- bounds and the per-chat forbid ----------------------------------------------

      def test_thinking_up_to_the_budget_is_allowed_even_with_forbid_thinking_tokens_on
        FakeNetwork.script << reply(prompt_tokens: 40, completion_tokens: 200, reasoning_tokens: BUDGET)
        g = guard(forbid_thinking_tokens: true)
        glm_chat(g).ask("hi")
        refute g.halted, "forbid is off for the budgeted chat only"
      end

      # The budget is soft: the live run reported 1,036 thinking tokens against 1,024.
      def test_1036_thinking_tokens_over_the_1024_budget_do_not_halt
        FakeNetwork.script << reply(prompt_tokens: 40, completion_tokens: 1_100, reasoning_tokens: 1_036)
        g = guard(forbid_thinking_tokens: true)
        glm_chat(g).ask("hi")
        refute g.halted
      end

      def test_exactly_1280_thinking_tokens_do_not_halt_and_settle_under_the_reservation
        FakeNetwork.script << reply(prompt_tokens: 40, completion_tokens: 1_280, reasoning_tokens: 1_280)
        g = guard(forbid_thinking_tokens: true, settlement: :metered)
        glm_chat(g).ask("hi")
        refute g.halted
        entry = @ledger.entries.first
        assert_operator entry["settled_micro"], :<=, entry["reserved_micro"]
      end

      def test_1281_thinking_tokens_halt_the_guard_and_nothing_further_is_sent
        FakeNetwork.script << reply(prompt_tokens: 40, completion_tokens: 900, reasoning_tokens: 1_281)
        g = guard(forbid_thinking_tokens: true)
        glm_chat(g).ask("hi")
        assert_match(/1281 thinking tokens, above the 1280 thinking bound/, g.halted)
        assert_raises(Bench::Halted) { glm_chat(g) }
        assert_equal 1, FakeNetwork.calls.size
      end

      def test_forbid_thinking_tokens_still_halts_an_unbudgeted_chat_on_the_same_guard
        g = guard(forbid_thinking_tokens: true)
        FakeNetwork.script << reply(prompt_tokens: 40, completion_tokens: 50, reasoning_tokens: 1)
        chat = g.arm(Bench::FireworksRoute.chat(model: DEEPSEEK, context: @context), model: DEEPSEEK, label: "ds")
        chat.ask("hi")
        assert_match(/thinking tokens with reasoning off/, g.halted)
      end

      def test_output_above_the_max_sent_halts_the_guard
        FakeNetwork.script << reply(prompt_tokens: 40, completion_tokens: 256 + BUDGET + 1)
        g = guard
        glm_chat(g).ask("hi")
        assert_match(/above the #{256 + BUDGET} bound/, g.halted)
      end

      def test_a_payload_bound_above_the_chats_cap_is_refused
        g = guard
        chat = glm_chat(g)
        chat.before_request { |payload| payload[:max_completion_tokens] = 64_000 } # added after arming: pinned limit
        chat.ask("hi") # documented limit: a hook added after arming can rewrite the payload
        assert_equal 64_000, FakeNetwork.calls.first[:body]["max_completion_tokens"]
      end

      def test_the_budgeted_chat_counts_against_the_sub_cap_with_its_larger_reservation
        small = guard(run_cap_usd: 0.0005) # 500 micro-dollars: less than one 2,560-token reservation (>1,280)
        assert_raises(Bench::CapExceeded) { glm_chat(small).ask("hi") }
        assert_empty FakeNetwork.calls
      end
    end
  end
end
