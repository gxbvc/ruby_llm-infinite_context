# frozen_string_literal: true

require "test_helper"
require "support/fake_network"
require "tmpdir"
require_relative "../bench/spend_guard"

# A tool for the tool-call body test.
class FireworksRoutePingTool < RubyLLM::Tool
  description "ping"
  def execute = "pong"
end

module RubyLLM
  module InfiniteContext
    # The pinned Fireworks route: POST /inference/v1/chat/completions
    # only, a fixed model list, no storing or logging field. All over the
    # in-process fake network: no key, no socket, no provider.
    class FireworksRouteTest < Minitest::Test
      GLM = "accounts/fireworks/models/glm-5p3-flash"
      DEEPSEEK = "accounts/fireworks/models/deepseek-v4p1-flash"
      PRICES = {
        GLM => {"input" => 0.15, "output" => 0.50},
        DEEPSEEK => {"input" => 0.30, "output" => 1.20}
      }.freeze

      def setup
        @previous = FakeNetwork.install!(max_retries: 0)
        FakeNetwork.reset!
        @dir = Dir.mktmpdir("fw-route")
        @ledger = Bench::Ledger.new(File.join(@dir, "ledger.json"), cap_usd: 0.5)
        @context = Bench::FireworksRoute.context(api_key: "placeholder-not-a-key", max_retries: 0)
      end

      def teardown
        FakeNetwork.restore!(@previous)
        FileUtils.rm_rf(@dir)
      end

      def guard(**opts)
        Bench::Guard.new(ledger: @ledger, prices: PRICES, max_output_tokens: 256, retries: 0, **opts)
      end

      def armed(model: GLM, **opts)
        chat = Bench::FireworksRoute.chat(model: model, context: @context)
        guard(**opts).arm(chat, model: model, label: "fw")
      end

      def reply(text = "ok", model: GLM, **usage) = FakeNetwork.chat_completion_reply(text, model: model, **usage)

      # -- the exact route ---------------------------------------------------

      def test_a_fireworks_chat_posts_to_inference_v1_chat_completions_with_only_allowed_body_keys
        FakeNetwork.script << reply
        assert_equal "ok", armed.ask("hi").content
        call = FakeNetwork.calls.fetch(0)
        assert_equal 1, FakeNetwork.calls.size
        assert_equal "POST", call[:method]
        assert_equal "https://api.fireworks.ai/inference/v1/chat/completions", call[:url]
        assert_equal Bench::FireworksRoute::PATH, call[:path]
        assert_equal %w[model messages stream max_completion_tokens reasoning_effort].sort, call[:body].keys.sort
        assert_equal GLM, call[:body]["model"]
        assert_equal false, call[:body]["stream"]
        assert_equal 256, call[:body]["max_completion_tokens"]
        assert_equal "none", call[:body]["reasoning_effort"]
        (%w[store include metadata user safety_identifier input previous_response_id] & call[:body].keys).then do |bad|
          assert_empty bad
        end
      end

      def test_a_tool_call_body_stays_inside_the_allowlist
        FakeNetwork.script << reply
        armed(model: DEEPSEEK).with_tools(FireworksRoutePingTool.new).ask("hi")
        keys = FakeNetwork.calls.first[:body].keys
        assert_includes keys, "tools"
        assert_empty keys - Bench::FireworksRoute::ALLOWED_BODY_KEYS
        assert_equal Bench::FireworksRoute::PATH, FakeNetwork.calls.first[:path]
      end

      def test_the_default_openai_route_would_post_to_responses_with_store_so_it_is_refused_at_arm
        chat = @context.chat(model: GLM, provider: :openai, assume_model_exists: true) # no protocol:
        error = assert_raises(Bench::RouteRefused) { guard.arm(chat, model: GLM, label: "fw") }
        assert_match(/only :chat_completions/, error.message)
        assert_empty FakeNetwork.calls, "refused before any network call"
      end

      def test_a_model_off_the_fixed_list_is_refused_at_arm
        other = "accounts/fireworks/models/kimi-k3"
        chat = Bench::FireworksRoute.chat(model: other, context: @context)
        g = Bench::Guard.new(ledger: @ledger, prices: PRICES.merge(other => {"input" => 1, "output" => 1}))
        assert_raises(Bench::RouteRefused) { g.arm(chat, model: other, label: "fw") }
        assert_empty FakeNetwork.calls
      end

      def test_a_wrong_api_base_is_refused_at_arm
        context = RubyLLM.context do |c|
          c.openai_api_key = "placeholder-not-a-key"
          c.openai_api_base = "https://api.openai.com/v1"
        end
        chat = Bench::FireworksRoute.chat(model: GLM, context: context)
        assert_raises(Bench::RouteRefused) { guard.arm(chat, model: GLM, label: "fw") }
      end

      def test_a_storing_or_logging_field_added_to_the_body_is_refused_and_halts_before_the_network
        {store: true, metadata: {a: 1}, user: "u", safety_identifier: "x", include: ["reasoning.encrypted_content"]}.each do |key, value|
          FakeNetwork.reset!
          g = guard
          chat = Bench::FireworksRoute.chat(model: GLM, context: @context)
          chat.with_provider_options(key => value)
          g.arm(chat, model: GLM, label: "fw")
          assert_raises(Bench::RouteRefused, key.to_s) { chat.ask("hi") }
          assert_empty FakeNetwork.calls, "#{key}: the body never left"
          assert g.halted
          assert_equal 0, @ledger.committed_micro
        end
      end

      def test_streaming_is_refused
        g = guard
        chat = Bench::FireworksRoute.chat(model: GLM, context: @context)
        g.arm(chat, model: GLM, label: "fw")
        assert_raises(Bench::RouteRefused) { Bench::FireworksRoute.verify_payload!({model: GLM, messages: [], stream: true}) }
      end

      # -- pricing and settlement on Fireworks --------------------------------

      def test_a_fireworks_model_with_no_explicit_price_does_not_arm
        chat = Bench::FireworksRoute.chat(model: GLM, context: @context)
        g = Bench::Guard.new(ledger: @ledger, prices: {})
        assert_raises(Bench::UnknownPricing) { g.arm(chat, model: GLM, label: "fw") }
        assert_empty FakeNetwork.calls
      end

      def test_the_reply_is_costed_from_the_explicit_price_not_the_registry
        FakeNetwork.script << reply(prompt_tokens: 1_000, completion_tokens: 100)
        armed(settlement: :metered).ask("hi")
        # 1,000 in at $0.15/M + 100 out at $0.50/M = $0.0002 = 200 micro-dollars
        assert_in_delta 200, @ledger.committed_micro, 1
      end

      def test_reservation_settlement_on_fireworks_keeps_the_whole_reservation
        FakeNetwork.script << reply(prompt_tokens: 1_000, completion_tokens: 100)
        armed(settlement: :reservation).ask("hi")
        entry = @ledger.entries.first
        assert_equal entry["reserved_micro"], entry["settled_micro"]
        # body bytes + 2,000 margin at $0.15/M, plus 256 out at $0.50/M: well above the metered 200
        assert_operator entry["settled_micro"], :>, 400
      end

      # -- reasoning bound ----------------------------------------------------

      def test_reasoning_tokens_with_reasoning_off_halt_the_guard
        FakeNetwork.script << reply(prompt_tokens: 100, completion_tokens: 50, reasoning_tokens: 40)
        g = guard(forbid_thinking_tokens: true)
        chat = Bench::FireworksRoute.chat(model: GLM, context: @context)
        g.arm(chat, model: GLM, label: "fw")
        chat.ask("hi")
        assert_match(/thinking tokens with reasoning off/, g.halted)
        assert_raises(Bench::Halted) { chat.ask("again") }
        assert_equal 1, FakeNetwork.calls.size, "no second request after the halt"
      end

      def test_a_reply_above_the_output_bound_halts_the_guard
        FakeNetwork.script << reply(prompt_tokens: 100, completion_tokens: 900)
        g = guard
        chat = Bench::FireworksRoute.chat(model: GLM, context: @context)
        g.arm(chat, model: GLM, label: "fw")
        chat.ask("hi")
        assert_match(/above the 256 bound/, g.halted)
      end
    end
  end
end
