# frozen_string_literal: true

require "test_helper"
require "support/fake_network"
require "tmpdir"
require_relative "../bench/smoke_test"

module RubyLLM
  module InfiniteContext
    # The GLM-5.3-Flash gate in the smoke script. GLM-5.3 is thinking-only
    # (the live run got a 400 for reasoning_effort none), so GLM runs with
    # reasoning ON under a budget, and only after one single request passes
    # this gate. Over the fake network.
    class SmokeGateTest < Minitest::Test
      GLM = Bench::Smoke::GLM
      DEEPSEEK = "accounts/fireworks/models/deepseek-v4p1-flash"
      BUDGET = Bench::Smoke::GLM_REASONING_BUDGET

      def setup
        @previous = FakeNetwork.install!(max_retries: 0)
        FakeNetwork.reset!
        @dir = Dir.mktmpdir("smoke-gate")
        @ledger = Bench::Ledger.new(File.join(@dir, "bench-ledger.json"))
        @context = Bench::FireworksRoute.context(api_key: "placeholder-not-a-key", max_retries: 0)
        @guard = Bench::Guard.new(ledger: @ledger, prices: Bench::Smoke.prices, retries: 0,
          max_output_tokens: Bench::Smoke::MAX_OUTPUT_TOKENS, settlement: :reservation,
          forbid_thinking_tokens: true, run_cap_usd: Bench::Smoke::CAP_USD)
      end

      def teardown
        FakeNetwork.restore!(@previous)
        FileUtils.rm_rf(@dir)
      end

      def reply(text = "401", **usage) = FakeNetwork.chat_completion_reply(text, model: GLM, **usage)

      def test_the_run_order_is_deepseek_then_haiku_then_gated_glm_with_a_reasoning_budget
        models = Bench::Smoke::MODELS.map { |m| m[:model] }
        assert_equal [DEEPSEEK, "claude-haiku-4-5", GLM], models
        assert_equal [GLM], Bench::Smoke::MODELS.select { |m| m[:gate] }.map { |m| m[:model] }
        assert_equal :single_request_reasoning_budget, Bench::Smoke::MODELS.last[:gate]
        assert_equal({GLM => 1_024}, Bench::Smoke.reasoning_budgets)
        assert_equal({}, Bench::Smoke.reasoning_budgets(Bench::Smoke.select_models("deepseek,haiku")))
      end

      def test_the_gate_sends_thinking_enabled_with_the_budget_and_no_reasoning_effort_to_the_pinned_route
        FakeNetwork.script << reply(prompt_tokens: 30, completion_tokens: 40, reasoning_tokens: 35)
        observation = Bench::Smoke.glm_gate!(@guard, @context)
        assert_equal 1, FakeNetwork.calls.size, "a single request"
        call = FakeNetwork.calls.first
        assert_equal Bench::FireworksRoute::PATH, call[:path]
        assert_equal({"type" => "enabled", "budget_tokens" => BUDGET}, call[:body]["thinking"])
        refute_includes call[:body].keys, "reasoning_effort", "the docs make thinking + reasoning_effort a validation error"
        assert_equal 256 + BUDGET, call[:body]["max_completion_tokens"], "max sent covers the answer even if reasoning counts toward it"
        assert_empty call[:body].keys - Bench::FireworksRoute::ALLOWED_BODY_KEYS
        assert_equal 35, observation[:thinking_tokens]
        assert observation[:thinking_inside_output]
        refute @guard.halted
      end

      # -- the harder gate prompt ---------------------------------------------------------

      def test_the_prompt_is_a_multi_step_counting_problem_with_one_checkable_answer
        # 1..1000 divisible by 3 or by 5 but not by both: computed here, independently of the constant.
        truth = (1..1000).count { |n| (n % 3).zero? ^ (n % 5).zero? }
        assert_equal 401, truth
        assert_equal truth.to_s, Bench::Smoke::CHECK_ANSWER
        prompt = Bench::Smoke::CHECK_PROMPT
        assert_includes prompt, "1 to 1000"
        assert_includes prompt, "divisible by 3 or by 5, but not by both"
        assert_includes prompt, "step by step"
        assert_includes prompt, "reply with only the number"
        refute_includes prompt, Bench::Smoke::CHECK_ANSWER, "the answer is not in the prompt"
      end

      def test_the_gate_sends_that_prompt_and_prints_thinking_against_the_budget
        FakeNetwork.script << reply(prompt_tokens: 60, completion_tokens: 900, reasoning_tokens: 850)
        out, = capture_io { @observation = Bench::Smoke.glm_gate!(@guard, @context) }
        user = FakeNetwork.calls.first[:body]["messages"].last
        assert_equal Bench::Smoke::CHECK_PROMPT, user["content"]
        assert_match(/thinking 850 of 1024 budget tokens \(83%; bound 1280\)/, out)
        assert_match(/expected 401/, out)
        assert_equal 850, @observation[:thinking_tokens]
        assert_equal BUDGET, @observation[:budget]
        assert @observation[:answer_matches]
      end

      def test_a_wrong_answer_does_not_fail_the_gate_it_tests_the_budget_not_skill
        FakeNetwork.script << reply("399", prompt_tokens: 60, completion_tokens: 700, reasoning_tokens: 650)
        observation = nil
        capture_io { observation = Bench::Smoke.glm_gate!(@guard, @context) }
        refute observation[:answer_matches]
      end

      def test_a_refused_gate_still_prints_what_it_saw
        body = reply("", prompt_tokens: 60, completion_tokens: 256 + BUDGET, reasoning_tokens: BUDGET)
        body["choices"][0]["finish_reason"] = "length"
        FakeNetwork.script << body
        out, = capture_io { assert_raises(Bench::Error, Bench::Halted) { Bench::Smoke.glm_gate!(@guard, @context) } }
        assert_match(/thinking 1024 of 1024 budget tokens \(100%; bound 1280\)/, out)
      end

      def test_the_gate_passes_with_zero_reported_reasoning_too
        FakeNetwork.script << reply(prompt_tokens: 20, completion_tokens: 3)
        assert_equal 0, Bench::Smoke.glm_gate!(@guard, @context)[:thinking_tokens]
      end

      def test_the_named_constants_equal_what_the_guard_computes
        assert_equal 1_280, Bench::Smoke::GLM_THINKING_BOUND
        assert_equal 2_560, Bench::Smoke::GLM_RESERVED_OUTPUT_TOKENS
        assert_equal Bench::Smoke::GLM_THINKING_BOUND, @guard.thinking_bound_for(BUDGET)
        assert_equal Bench::Smoke::GLM_RESERVED_OUTPUT_TOKENS, @guard.reserved_output_tokens_for(BUDGET)
        assert_equal Bench::Smoke::MAX_OUTPUT_TOKENS + BUDGET, Bench::Smoke::GLM_THINKING_BOUND
      end

      def test_the_gate_passes_at_1036_thinking_tokens_a_soft_budget_overshoot
        FakeNetwork.script << reply(prompt_tokens: 60, completion_tokens: 1_100, reasoning_tokens: 1_036)
        out, = capture_io { @observation = Bench::Smoke.glm_gate!(@guard, @context) }
        assert_equal 1_036, @observation[:thinking_tokens]
        assert_match(/thinking 1036 of 1024 budget tokens \(101%; bound 1280\)/, out)
        refute @guard.halted
      end

      def test_the_gate_passes_at_exactly_the_bound_and_refuses_one_above
        FakeNetwork.script << reply(prompt_tokens: 60, completion_tokens: 1_280, reasoning_tokens: 1_280)
        capture_io { assert_equal 1_280, Bench::Smoke.glm_gate!(@guard, @context)[:thinking_tokens] }
        FakeNetwork.reset!
        FakeNetwork.script << reply(prompt_tokens: 60, completion_tokens: 900, reasoning_tokens: 1_281)
        capture_io { assert_raises(Bench::Halted) { Bench::Smoke.glm_gate!(@guard, @context) } }
      end

      def test_more_thinking_tokens_than_the_bound_halts_the_whole_guard
        FakeNetwork.script << reply(prompt_tokens: 20, completion_tokens: 900, reasoning_tokens: Bench::Smoke::GLM_THINKING_BOUND + 1)
        capture_io { assert_raises(Bench::Halted) { Bench::Smoke.glm_gate!(@guard, @context) } }
        assert_match(/above the 1280 thinking bound/, @guard.halted)
        other = Bench::FireworksRoute.chat(model: DEEPSEEK, context: @context)
        assert_raises(Bench::Halted) { @guard.arm(other, model: DEEPSEEK, label: "after") }
        assert_equal 1, FakeNetwork.calls.size
      end

      def test_the_gate_refuses_an_answer_cut_off_by_max_tokens
        body = reply("", prompt_tokens: 20, completion_tokens: 256 + BUDGET, reasoning_tokens: BUDGET)
        body["choices"][0]["finish_reason"] = "length"
        FakeNetwork.script << body
        error = assert_raises(Bench::Error, Bench::Halted) { Bench::Smoke.glm_gate!(@guard, @context) }
        assert_match(/cut off by max tokens/, error.message)
      end

      def test_the_gate_refuses_an_empty_answer_and_a_reply_with_no_usage
        FakeNetwork.script << reply("", prompt_tokens: 20, completion_tokens: 3)
        assert_match(/empty answer/, assert_raises(Bench::Error) { Bench::Smoke.glm_gate!(@guard, @context) }.message)
        FakeNetwork.reset!
        body = reply
        body.delete("usage")
        FakeNetwork.script << body
        assert_raises(Bench::Error, Bench::Halted) { Bench::Smoke.glm_gate!(@guard, @context) }
      end

      def test_a_400_from_the_provider_stops_the_gate_and_the_pass
        FakeNetwork.script << Faraday::BadRequestError.new("disabling thinking is not supported")
        assert_raises(Faraday::BadRequestError) { Bench::Smoke.glm_gate!(@guard, @context) }
        assert_equal 1, FakeNetwork.calls.size
      end

      def test_the_gate_request_counts_against_the_run_sub_cap_and_the_shared_ledger
        FakeNetwork.script << reply(prompt_tokens: 20, completion_tokens: 3)
        Bench::Smoke.glm_gate!(@guard, @context)
        assert_operator @guard.run_micro, :>, 0
        assert_equal @guard.run_micro, @ledger.committed_micro
        assert_equal Bench.usd_to_micro_down(0.90), @guard.run_cap_micro
      end
    end
  end
end
