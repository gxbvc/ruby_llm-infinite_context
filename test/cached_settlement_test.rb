# frozen_string_literal: true

require "test_helper"
require "support/fake_network"
require "tmpdir"
require_relative "../bench/spend_guard"

module RubyLLM
  module InfiniteContext
    # Settlement prices input tokens the provider reports as cached at an
    # explicit cached_input price. Reservations never get the discount, and a
    # cache discount cannot hide an inflated input count. Over the fake
    # network; the request body and headers are not touched by any of this.
    class CachedSettlementTest < Minitest::Test
      GLM = "accounts/fireworks/models/glm-5p3-flash"
      HAIKU = "claude-haiku-4-5"

      def setup
        @previous = FakeNetwork.install!(max_retries: 0)
        FakeNetwork.reset!
        @dir = Dir.mktmpdir("cached")
        @context = Bench::FireworksRoute.context(api_key: "placeholder-not-a-key", max_retries: 0)
        FakeNetwork.default_reply = FakeNetwork.chat_completion_reply("ok", model: GLM)
      end

      def teardown
        FakeNetwork.restore!(@previous)
        FileUtils.rm_rf(@dir)
      end

      def ledger(name = "l.json") = Bench::Ledger.new(File.join(@dir, name))

      def prices(cached: 0.03)
        glm = {"input" => 0.15, "output" => 0.50}
        glm["cached_input"] = cached unless cached.nil?
        {GLM => glm, HAIKU => {"input" => 1.0, "cached_input" => 0.10, "output" => 5.0}}
      end

      def guard(ledger, cached: 0.03, max_output_tokens: 256, **opts)
        Bench::Guard.new(ledger: ledger, prices: prices(cached: cached), max_output_tokens: max_output_tokens,
          retries: 0, **opts)
      end

      def glm_chat(guard)
        guard.arm(Bench::FireworksRoute.chat(model: GLM, context: @context), model: GLM, label: "c")
      end

      def glm_reply(**usage) = FakeNetwork.chat_completion_reply("ok", model: GLM, **usage)

      # -- prices ----------------------------------------------------------------

      def test_cached_input_is_optional_and_defaults_to_the_input_price
        rates = Bench::Pricing.resolve(GLM, overrides: prices(cached: nil))
        assert_equal rates.input, rates.cached_input, "no cached price given: no discount is assumed"
        with = Bench::Pricing.resolve(GLM, overrides: prices)
        assert_equal Rational(3, 100), with.cached_input
        assert_equal Rational(15, 100), with.input
      end

      def test_a_bad_cached_price_fails_closed
        [0, -0.01, "0.03", 0.16, Float::NAN].each do |bad|
          assert_raises(Bench::UnknownPricing, bad.inspect) do
            Bench::Pricing.resolve(GLM, overrides: {GLM => {"input" => 0.15, "output" => 0.5, "cached_input" => bad}})
          end
        end
        equal = Bench::Pricing.resolve(GLM, overrides: {GLM => {"input" => 0.15, "output" => 0.5, "cached_input" => 0.15}})
        assert_equal equal.input, equal.cached_input, "a cached price equal to the input price is allowed"
      end

      # -- settlement ----------------------------------------------------------------

      def test_cached_tokens_settle_at_the_cached_price_on_chat_completions
        FakeNetwork.script << glm_reply(prompt_tokens: 1_000, completion_tokens: 100, cached_tokens: 800)
        l = ledger
        glm_chat(guard(l, settlement: :metered)).ask("hi")
        # 200 fresh at $0.15/M = 30, 800 cached at $0.03/M = 24, 100 out at $0.50/M = 50 micro-dollars
        assert_in_delta 104, l.committed_micro, 1
      end

      def test_without_a_cached_price_the_same_reply_costs_the_full_input_price
        FakeNetwork.script << glm_reply(prompt_tokens: 1_000, completion_tokens: 100, cached_tokens: 800)
        l = ledger
        glm_chat(guard(l, cached: nil, settlement: :metered)).ask("hi")
        # 1,000 at $0.15/M = 150 + 50
        assert_in_delta 200, l.committed_micro, 1
      end

      def test_cached_tokens_settle_at_the_cached_price_on_anthropic_too
        FakeNetwork.script << FakeNetwork.text_reply("fine", input_tokens: 20, output_tokens: 10, cache_read_tokens: 300)
        l = ledger
        guard(l, settlement: :metered).arm(RubyLLM.chat(model: HAIKU), model: HAIKU, label: "c").ask("hi")
        # 20 fresh at $1/M = 20, 300 cached at $0.10/M = 30, 10 out at $5/M = 50
        assert_in_delta 100, l.committed_micro, 1
      end

      # -- cache writes: charged at 2x the input price ------------------

      def haiku_chat(guard) = guard.arm(RubyLLM.chat(model: HAIKU), model: HAIKU, label: "c")

      def test_cache_write_tokens_settle_at_twice_the_input_price
        assert_equal 2, Bench::Guard::CACHE_WRITE_MULTIPLIER
        FakeNetwork.script << FakeNetwork.text_reply("fine", input_tokens: 20, output_tokens: 10, cache_write_tokens: 300)
        l = ledger
        haiku_chat(guard(l, settlement: :metered)).ask("hi")
        # 20 fresh at $1/M = 20, 300 written at 2 x $1/M = 600, 10 out at $5/M = 50 micro-dollars
        assert_in_delta 670, l.committed_micro, 1
      end

      def test_reads_writes_and_fresh_tokens_in_one_reply_each_get_their_own_rate
        FakeNetwork.script << FakeNetwork.text_reply("fine", input_tokens: 20, output_tokens: 10,
          cache_read_tokens: 300, cache_write_tokens: 100)
        l = ledger
        haiku_chat(guard(l, settlement: :metered)).ask("hi")
        # 20 + (100 x 2) + (300 x 0.10) + (10 x 5) = 20 + 200 + 30 + 50
        assert_in_delta 300, l.committed_micro, 1
      end

      def test_cache_writes_that_push_the_cost_over_the_reservation_are_recorded_in_full_and_halt
        # Input count within what the request could hold (bytes + 2,000 margin), but written at 2x:
        # the cost passes the uncached reservation, so the overrun halt fires.
        FakeNetwork.script << FakeNetwork.text_reply("fine", input_tokens: 10, output_tokens: 1, cache_write_tokens: 2_100)
        l = ledger
        g = guard(l, settlement: :metered, max_output_tokens: 16)
        haiku_chat(g).ask("hi")
        entry = l.entries.first
        assert_operator entry["settled_micro"], :>, entry["reserved_micro"], "cost above the reservation"
        assert_match(/exceeded its reservation/, g.halted)
        assert_in_delta 10 + 4_200 + 5, entry["settled_micro"], 2, "recorded in full at 2x"
      end

      def test_the_reservation_covers_ordinary_cache_writes
        FakeNetwork.script << FakeNetwork.text_reply("fine", input_tokens: 10, output_tokens: 5, cache_write_tokens: 150)
        l = ledger
        g = guard(l, settlement: :metered)
        haiku_chat(g).ask("hi")
        refute g.halted
        entry = l.entries.first
        assert_operator entry["settled_micro"], :<, entry["reserved_micro"]
      end

      # -- reservations are never discounted ------------------------------------------

      def test_the_reservation_is_identical_with_and_without_a_cached_price
        a = ledger("a.json")
        b = ledger("b.json")
        glm_chat(guard(a, cached: 0.03)).ask("hi")
        glm_chat(guard(b, cached: nil)).ask("hi")
        assert_equal b.entries.first["reserved_micro"], a.entries.first["reserved_micro"]
      end

      def test_reservation_settlement_still_keeps_the_whole_reservation_when_replies_are_cached
        FakeNetwork.script << glm_reply(prompt_tokens: 1_000, completion_tokens: 100, cached_tokens: 1_000)
        l = ledger
        glm_chat(guard(l, settlement: :reservation)).ask("hi")
        entry = l.entries.first
        assert_equal entry["reserved_micro"], entry["settled_micro"]
      end

      # -- a discount cannot hide an inflated count -------------------------------------

      def test_a_reply_reporting_more_input_tokens_than_the_request_could_hold_halts
        # 9,000,000 prompt tokens, almost all "cached": the discounted cost is small, the count is not.
        FakeNetwork.script << glm_reply(prompt_tokens: 9_000_000, completion_tokens: 10, cached_tokens: 8_999_000)
        l = ledger
        g = guard(l, settlement: :metered)
        glm_chat(g).ask("hi")
        assert_match(/more than the request could hold/, g.halted)
        assert_raises(Bench::Halted) { glm_chat(g) }
        assert_equal 1, FakeNetwork.calls.size
      end

      def test_an_honest_cached_reply_within_the_request_size_does_not_halt
        FakeNetwork.script << glm_reply(prompt_tokens: 600, completion_tokens: 10, cached_tokens: 500)
        g = guard(ledger, settlement: :metered)
        glm_chat(g).ask("hi")
        refute g.halted
      end

      def test_the_overrun_path_is_still_reachable_with_counts_inside_the_bounds
        # Reasoning tokens are billed as output and are not part of completion_tokens here.
        FakeNetwork.script << glm_reply(prompt_tokens: 50, completion_tokens: 10, reasoning_tokens: 5_000_000)
        l = ledger
        g = guard(l, settlement: :metered)
        glm_chat(g).ask("hi")
        assert_match(/exceeded its reservation/, g.halted)
        assert_operator l.committed_micro, :>, 2_000_000, "recorded in full"
      end

      # -- no new request field or header ----------------------------------------------

      def test_the_request_is_the_same_with_a_cached_price_or_without
        FakeNetwork.script << glm_reply
        glm_chat(guard(ledger("x.json"), cached: 0.03)).ask("hi")
        with = FakeNetwork.calls.last
        FakeNetwork.reset!
        FakeNetwork.script << glm_reply
        glm_chat(guard(ledger("y.json"), cached: nil)).ask("hi")
        without = FakeNetwork.calls.last
        assert_equal without[:body], with[:body]
        assert_equal without[:headers].keys.sort, with[:headers].keys.sort
        assert_equal Bench::FireworksRoute::PATH, with[:path]
      end
    end
  end
end
