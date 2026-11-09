# frozen_string_literal: true

require "test_helper"
require "support/fake_network"
require "tmpdir"
require "faraday"
require_relative "../bench/spend_guard"

# Records every fsync (file and directory) while a test turns logging on.
module FsyncLog
  def fsync
    (Thread.current[:fsync_log] ||= []) << path if Thread.current[:fsync_log]
    super
  end
end
File.prepend(FsyncLog)

# A tool for the tool-loop tests.
class SpendGuardPingTool < RubyLLM::Tool
  description "ping"
  def execute = "pong"
end

module RubyLLM
  module InfiniteContext
    # Ledger, pricing and guard behavior. Chats are REAL RubyLLM::Chat
    # objects: payload rendering, before_request hooks, the tool loop and the
    # Faraday retry middleware are all real; only the final HTTP hop is the
    # in-process fake network (test/support/fake_network.rb), which counts
    # started requests and never opens a socket. No API key, no outbound call.
    class SpendGuardTest < Minitest::Test
      MODEL = "claude-haiku-4-5"

      def setup
        @previous = FakeNetwork.install!(max_retries: 0)
        FakeNetwork.reset!
        @dir = Dir.mktmpdir("spend-guard")
        @path = File.join(@dir, "ledger.json")
      end

      def teardown
        FakeNetwork.restore!(@previous)
        FileUtils.rm_rf(@dir)
      end

      def ledger(cap: 20.0, path: @path) = Bench::Ledger.new(path, cap_usd: cap)

      def guard(ledger = self.ledger, **opts) = Bench::Guard.new(ledger: ledger, **opts)

      def armed(guard, model: MODEL, label: "t")
        guard.arm(RubyLLM.chat(model: model), model: model, label: label)
      end

      def micro(usd) = Bench.usd_to_micro_up(usd)

      # -- ledger ------------------------------------------------------------

      def test_reservations_fill_the_cap_exactly_and_the_next_micro_dollar_is_refused
        l = ledger(cap: 0.001) # 1000 micro-dollars
        l.reserve!(600, label: "a", model: "m")
        l.reserve!(400, label: "b", model: "m")
        assert_equal 1000, l.committed_micro
        assert_raises(Bench::CapExceeded) { l.reserve!(1, label: "c", model: "m") }
        assert_equal 1000, l.committed_micro
        assert_equal 2, l.entries.size, "a refused reservation writes nothing"
      end

      def test_settling_lowers_the_commitment_and_an_overrun_is_recorded_in_full_and_raises
        l = ledger
        id = l.reserve!(500, label: "a", model: "m")
        l.settle!(id, 100)
        assert_equal 100, l.committed_micro
        id2 = l.reserve!(300, label: "b", model: "m")
        assert_raises(Bench::Overrun) { l.settle!(id2, 400) }
        assert_equal 500, l.committed_micro, "the overrun is counted at its full metered cost"
      end

      def test_the_ledger_survives_a_restart_and_an_unsettled_reservation_stays_counted
        first = ledger
        first.reserve!(700_000, label: "crashed-before-settle", model: "m")
        # The process dies here. A new process opens the same file.
        second = ledger
        assert_equal 700_000, second.committed_micro
        assert_equal 1, second.entries.size
        assert_equal 20_000_000 - 700_000, second.remaining_micro
      end

      def test_whoever_creates_the_ledger_its_recorded_total_is_20_and_a_lower_cap_is_per_instance
        l = ledger(cap: 0.9) # the first opener asks for a low cap
        assert_equal micro(0.9), l.cap_micro
        assert_equal micro(20.0), JSON.parse(File.read(@path))["cap_micro"], "the file records the $20 total"
        assert_equal micro(20.0), ledger(cap: 20.0).cap_micro, "a later opener still gets the $20 total"
      end

      def test_a_raised_cap_is_refused_and_a_lowered_cap_is_honored
        ledger(cap: 5.0)
        # A person lowers the recorded total by editing the file; it can then not be raised by a caller.
        data = JSON.parse(File.read(@path))
        data["cap_micro"] = micro(5.0)
        File.write(@path, JSON.generate(data))
        error = assert_raises(Bench::Error) { ledger(cap: 20.0) }
        assert_match(/over this ledger's recorded cap/, error.message)
        assert_equal micro(3.0), ledger(cap: 3.0).cap_micro
        assert_raises(Bench::Error) { ledger(cap: 20.01, path: File.join(@dir, "other.json")) }
        assert_raises(Bench::Error) { ledger(cap: 0, path: File.join(@dir, "zero.json")) }
      end

      def test_a_malformed_ledger_fails_closed_instead_of_resetting_the_spend
        ledger
        File.write(@path, "{ not json")
        assert_raises(Bench::Error) { ledger }
        File.write(@path, JSON.generate({"entries" => "nope"}))
        assert_raises(Bench::Error) { ledger }
        File.write(@path, JSON.generate({"cap_micro" => "x", "entries" => []}))
        assert_raises(Bench::Error) { ledger }
      end

      def test_a_leftover_temp_file_from_a_crash_is_ignored
        l = ledger
        l.reserve!(250, label: "a", model: "m")
        File.write("#{@path}.tmp.99999", "{ torn write")
        assert_equal 250, ledger.committed_micro
      end

      def test_concurrent_reservations_from_many_threads_and_instances_never_exceed_the_cap
        instances = Array.new(4) { ledger(cap: 0.001) } # 1000 micro-dollars, four separate objects
        outcomes = Queue.new
        threads = Array.new(40) do |i|
          Thread.new do
            instances[i % 4].reserve!(100, label: "t#{i}", model: "m")
            outcomes << :ok
          rescue Bench::CapExceeded
            outcomes << :refused
          end
        end
        threads.each(&:join)
        results = Array.new(40) { outcomes.pop }
        assert_equal 10, results.count(:ok)
        assert_equal 30, results.count(:refused)
        assert_equal 1000, ledger(cap: 0.001).committed_micro
      end

      def test_the_write_is_fsynced_atomic_and_private
        Thread.current[:fsync_log] = []
        l = ledger
        l.reserve!(10, label: "a", model: "m")
        log = Thread.current[:fsync_log]
        assert(log.any? { |p| p.start_with?("#{@path}.tmp.") }, "the temp file is fsynced before the rename")
        assert_includes log, @dir, "the directory is fsynced after the rename"
        assert_equal "600", format("%o", File.stat(@path).mode & 0o777)
        assert_empty Dir.children(@dir).grep(/\.tmp\./), "no temp file is left behind"
      ensure
        Thread.current[:fsync_log] = nil
      end

      # -- pricing: fail closed ----------------------------------------------

      def test_pricing_comes_from_the_registry_for_a_known_model
        rates = Bench::Pricing.resolve(MODEL)
        assert_equal 1, rates.input
        assert_equal 5, rates.output
      end

      def test_an_unknown_model_fails_closed
        assert_raises(Bench::UnknownPricing) { Bench::Pricing.resolve("no-such-model-xyz") }
      end

      def test_a_fireworks_model_needs_an_explicit_price_entry_even_if_a_registry_knew_it
        fw = "accounts/fireworks/models/glm-5p3-flash"
        error = assert_raises(Bench::UnknownPricing) { Bench::Pricing.resolve(fw) }
        assert_match(/no explicit price entry/, error.message)
        rates = Bench::Pricing.resolve(fw, overrides: {fw => {"input" => 0.15, "output" => 0.5}})
        assert_equal Rational(15, 100), rates.input
        # A registry that claims a price for a Fireworks id is still not trusted.
        fake_registry = Object.new
        fake_registry.define_singleton_method(:find) { |_id| raise "the registry must not be consulted for Fireworks" }
        assert_raises(Bench::UnknownPricing) { Bench::Pricing.resolve(fw, registry: fake_registry) }
      end

      def test_missing_zero_or_negative_prices_fail_closed
        [[nil, 5], [1, nil], [0, 5], [1, 0], [-1, 5], ["1", 5]].each do |input, output|
          assert_raises(Bench::UnknownPricing, [input, output].inspect) do
            Bench::Pricing.resolve("x", overrides: {"x" => {"input" => input, "output" => output}})
          end
        end
      end

      def test_arming_fails_closed_on_unknown_pricing_before_any_request
        assert_raises(Bench::UnknownPricing) do
          g = guard
          chat = RubyLLM.chat(model: MODEL)
          g.arm(chat, model: "no-such-model-xyz", label: "t")
        end
        assert_empty FakeNetwork.requests
      end

      # -- output bound ------------------------------------------------------

      def test_output_bound_is_read_from_the_rendered_payload_wherever_it_is
        assert_nil Bench::Guard.output_bound({"messages" => []})
        assert_equal 300, Bench::Guard.output_bound({max_tokens: 300})
        assert_equal 500, Bench::Guard.output_bound({"generationConfig" => {"maxOutputTokens" => 500}})
        assert_equal 900, Bench::Guard.output_bound({a: [{max_completion_tokens: 900}, {max_tokens: 10}]})
      end

      def test_every_armed_chat_carries_the_explicit_output_bound_on_the_wire
        chat = armed(guard(max_output_tokens: 256))
        chat.ask("hi")
        assert_equal 256, FakeNetwork.requests.first["max_tokens"]
        refute_equal 64_000, FakeNetwork.requests.first["max_tokens"], "never the model default"
      end

      def test_a_payload_without_the_bound_is_refused_before_any_request
        g = guard
        chat = RubyLLM.chat(model: MODEL)
        chat.before_request { |payload| payload.delete(:max_tokens) } # runs before the guard's hook
        g.arm(chat, model: MODEL, label: "t")
        assert_raises(Bench::UnboundedOutput) { chat.ask("hi") }
        assert_empty FakeNetwork.requests
        assert g.halted
      end

      # DOCUMENTED LIMIT, pinned by a test so nobody assumes more: the guard
      # sizes its reservation from the payload as its own hook sees it. A
      # before_request hook added to the chat AFTER arming can still rewrite
      # the payload. The bench arms chats last and adds no other hooks.
      def test_documented_limit_a_hook_added_after_arming_can_rewrite_the_payload
        g = guard(max_output_tokens: 256)
        chat = RubyLLM.chat(model: MODEL)
        g.arm(chat, model: MODEL, label: "t")
        chat.before_request { |payload| payload[:max_tokens] = 64_000 }
        chat.ask("hi")
        assert_equal 64_000, FakeNetwork.requests.first["max_tokens"]
      end

      def test_fallbacks_are_refused_at_arm_time_and_if_added_later
        g = guard
        chat = RubyLLM.chat(model: MODEL).with_fallbacks(MODEL)
        assert_raises(Bench::Error) { g.arm(chat, model: MODEL, label: "t") }

        chat2 = armed(g)
        chat2.with_fallbacks(MODEL)
        assert_raises(Bench::Error) { chat2.ask("hi") }
        assert_empty FakeNetwork.requests
      end

      # -- reservation before every request ----------------------------------

      def test_no_provider_request_starts_when_the_worst_case_does_not_fit
        l = ledger(cap: 0.0001) # 100 micro-dollars: the 1024-token output bound alone is ~5,120
        g = guard(l)
        chat = armed(g)
        assert_raises(Bench::CapExceeded) { chat.ask("hi") }
        assert_empty FakeNetwork.requests, "the provider must never see a request that does not fit"
        assert_equal 0, l.committed_micro
        assert g.halted
      end

      def test_a_request_that_fits_settles_to_the_metered_cost
        l = ledger
        FakeNetwork.script << FakeNetwork.text_reply("fine", input_tokens: 120, output_tokens: 20)
        reply = armed(guard(l)).ask("hi")
        assert_equal "fine", reply.content
        assert_equal 1, FakeNetwork.requests.size
        # 120 in at $1/M + 20 out at $5/M = $0.00022
        assert_in_delta 220, l.committed_micro, 2
        entry = l.entries.first
        assert entry["settled_micro"]
        assert_operator entry["reserved_micro"], :>, entry["settled_micro"]
      end

      def test_the_reservation_is_the_worst_case_for_the_rendered_payload
        l = ledger
        armed(guard(l, max_output_tokens: 1024)).ask("hi")
        body_bytes = JSON.generate(FakeNetwork.requests.first).bytesize
        reserved = l.entries.first["reserved_micro"]
        # bytes at $1/M plus the 2,000-token hidden-input margin at $1/M plus
        # 1024 output tokens at $5/M, in micro-dollars, with retries 0.
        assert_operator reserved, :>=, body_bytes - 40 + 2_000 + 5_120
        assert_operator reserved, :<=, body_bytes + 2_000 + 5_120 + 400
      end

      # -- hidden input margin ------------------------------------------------

      def test_the_default_hidden_input_margin_is_2000_tokens_at_the_input_price
        assert_equal 2_000, Bench::Guard::DEFAULT_INPUT_MARGIN_TOKENS
        none = ledger(path: File.join(@dir, "m0.json"))
        armed(guard(none, input_margin_tokens: 0)).ask("hi")
        default = ledger(path: File.join(@dir, "m2k.json"))
        armed(guard(default)).ask("hi")
        # 2,000 tokens at $1/M = 2,000 micro-dollars, per attempt.
        assert_in_delta 2_000, default.entries.first["reserved_micro"] - none.entries.first["reserved_micro"], 2
      end

      def test_the_margin_is_charged_once_per_attempt_so_retries_multiply_it_too
        RubyLLM.config.max_retries = 2
        a = ledger(path: File.join(@dir, "a.json"))
        armed(guard(a, input_margin_tokens: 0)).ask("hi")
        b = ledger(path: File.join(@dir, "b.json"))
        armed(guard(b, input_margin_tokens: 1_000)).ask("hi")
        assert_in_delta 3 * 1_000, b.entries.first["reserved_micro"] - a.entries.first["reserved_micro"], 4
      end

      def test_a_margin_that_does_not_fit_is_refused_before_any_request
        l = ledger(cap: 0.0075) # 7,500: fits 1024 out ($5,120) + a tiny body, not + 2,000 margin
        g = guard(l, input_margin_tokens: 5_000)
        assert_raises(Bench::CapExceeded) { armed(g).ask("hi") }
        assert_empty FakeNetwork.requests
      end

      def test_a_bad_margin_or_settlement_is_refused
        assert_raises(Bench::Error) { guard(input_margin_tokens: -1) }
        assert_raises(Bench::Error) { guard(input_margin_tokens: 1.5) }
        assert_raises(Bench::Error) { guard(settlement: :whatever) }
      end

      # -- retries come from the chat's own provider connection ---------------

      def context_chat(max_retries)
        context = RubyLLM.context { |c| c.max_retries = max_retries }
        context.chat(model: MODEL)
      end

      def test_retries_are_read_from_the_chats_own_context_not_the_global_config
        assert_equal 0, RubyLLM.config.max_retries
        l = ledger
        g = guard(l)
        g.arm(chat = context_chat(3), model: MODEL, label: "t")
        chat.ask("hi")
        single = ledger(path: File.join(@dir, "single.json"))
        armed(guard(single)).ask("hi")
        assert_in_delta 4 * single.entries.first["reserved_micro"], l.entries.first["reserved_micro"], 8,
          "3 retries on the context: four attempts are reserved even though the global config says 0"
      end

      def test_an_expected_retry_count_that_differs_from_the_chats_connection_fails_closed_at_arm
        g = guard(retries: 0)
        error = assert_raises(Bench::Error) { g.arm(context_chat(2), model: MODEL, label: "t") }
        assert_match(/expects max_retries 0/, error.message)
        assert_empty FakeNetwork.requests
        guard(retries: 2).arm(context_chat(2), model: MODEL, label: "t") # equal: arms
        guard(retries: 0).arm(RubyLLM.chat(model: MODEL), model: MODEL, label: "t") # global 0: arms
      end

      def test_the_larger_of_the_config_value_and_the_connections_frozen_value_is_used
        context = RubyLLM.context { |c| c.max_retries = 2 }
        chat = context.chat(model: MODEL)
        context.config.max_retries = 0 # the connection was built with 2 and keeps it
        g = guard
        assert_equal 2, g.transport_retries(chat)
        context.config.max_retries = 5 # a later raise is seen too
        assert_equal 5, g.transport_retries(chat)
      end

      def test_a_retry_count_changed_after_arming_halts_before_the_request
        context = RubyLLM.context { |c| c.max_retries = 0 }
        chat = context.chat(model: MODEL)
        g = guard
        g.arm(chat, model: MODEL, label: "t")
        context.config.max_retries = 3
        assert_raises(Bench::Halted) { chat.ask("hi") }
        assert_empty FakeNetwork.requests
        assert_match(/max_retries changed from 0 to 3/, g.halted)
      end

      # -- settlement modes ---------------------------------------------------

      def test_reservation_settlement_never_settles_below_the_reservation
        l = ledger
        FakeNetwork.script << FakeNetwork.text_reply("fine", input_tokens: 120, output_tokens: 20)
        armed(guard(l, settlement: :reservation)).ask("hi")
        entry = l.entries.first
        assert_equal entry["reserved_micro"], entry["settled_micro"], "reserve = final spend"
        assert_operator entry["settled_micro"], :>, 1_000, "not the ~220 micro-dollars the reply metered"
        assert_equal entry["reserved_micro"], l.committed_micro
      end

      def test_metered_settlement_still_settles_down_when_retries_are_zero
        l = ledger
        FakeNetwork.script << FakeNetwork.text_reply("fine", input_tokens: 120, output_tokens: 20)
        armed(guard(l, settlement: :metered)).ask("hi")
        assert_in_delta 220, l.committed_micro, 2
      end

      def test_reservation_settlement_still_records_an_overrun_in_full
        l = ledger(cap: 20.0)
        g = guard(l, settlement: :reservation, max_output_tokens: 16, input_margin_tokens: 0)
        # Reported usage far above what the reservation covers.
        FakeNetwork.script << FakeNetwork.text_reply("x", input_tokens: 5_000_000, output_tokens: 10)
        armed(g).ask("hi")
        assert g.halted
        assert_operator l.committed_micro, :>=, 5_000_000
      end

      def test_transport_retries_multiply_the_reservation
        l0 = ledger(path: File.join(@dir, "r0.json"))
        armed(guard(l0)).ask("hi")
        single = l0.entries.first["reserved_micro"]

        RubyLLM.config.max_retries = 2
        l2 = ledger(path: File.join(@dir, "r2.json"))
        armed(guard(l2)).ask("hi")
        tripled = l2.entries.first["reserved_micro"]
        assert_in_delta single * 3, tripled, 4
      end

      def test_with_retries_a_failed_attempt_is_not_forgotten_so_the_reservation_is_kept_whole
        RubyLLM.config.max_retries = 2
        l = ledger
        FakeNetwork.script << Faraday::ConnectionFailed.new("boom") << FakeNetwork.text_reply("after retry")
        armed(guard(l)).ask("hi")
        assert_equal 2, FakeNetwork.requests.size, "one ask, two provider attempts under one hook"
        assert_equal 1, l.entries.size, "one reservation covered both attempts"
        entry = l.entries.first
        assert_equal entry["reserved_micro"], entry["settled_micro"],
          "retries > 0: never settle down below the worst case, a failed attempt may have been billed"
      end

      def test_retries_unknown_fails_closed
        RubyLLM.config.max_retries = nil
        assert_raises(Bench::Error) { armed(guard).ask("hi") }
        assert_empty FakeNetwork.requests
      end

      # -- tool loop: several requests inside one ask -------------------------

      def test_each_request_of_a_tool_loop_is_reserved_and_settled_separately
        l = ledger
        2.times { FakeNetwork.script << FakeNetwork.tool_reply("spend_guard_ping", {}) }
        FakeNetwork.script << FakeNetwork.text_reply("done")
        chat = armed(guard(l)).with_tools(SpendGuardPingTool.new)
        assert_equal "done", chat.ask("go").content
        assert_equal 3, FakeNetwork.requests.size
        assert_equal 3, l.entries.size, "one reservation per provider request, not per ask"
        assert l.entries.all? { |e| e["settled_micro"] }
      end

      def test_the_per_chat_request_bound_stops_a_runaway_tool_loop_before_the_next_request
        l = ledger
        10.times { FakeNetwork.script << FakeNetwork.tool_reply("spend_guard_ping", {}) }
        g = guard(l, max_requests_per_chat: 3)
        chat = armed(g).with_tools(SpendGuardPingTool.new)
        assert_raises(Bench::Halted) { chat.ask("go") }
        assert_equal 3, FakeNetwork.requests.size, "the 4th request never started"
        assert_equal 3, l.entries.size
      end

      def test_the_cap_reached_in_the_middle_of_a_tool_loop_stops_before_the_next_request
        # Measure the three requests' reservations and costs on a big ledger.
        3.times { FakeNetwork.script << FakeNetwork.tool_reply("spend_guard_ping", {}) }
        FakeNetwork.script << FakeNetwork.text_reply("done")
        measuring = ledger(path: File.join(@dir, "measure.json"))
        armed(guard(measuring)).with_tools(SpendGuardPingTool.new).ask("go")
        entries = measuring.entries
        settled_two = entries.first(2).sum { |e| e["settled_micro"] }
        third_reserve = entries[2]["reserved_micro"]

        # A cap that fits requests 1 and 2 (settled) but not request 3's worst case.
        FakeNetwork.reset!
        3.times { FakeNetwork.script << FakeNetwork.tool_reply("spend_guard_ping", {}) }
        FakeNetwork.script << FakeNetwork.text_reply("done")
        tight = ledger(cap: Rational(settled_two + third_reserve - 1, Bench::MICRO))
        chat = armed(guard(tight)).with_tools(SpendGuardPingTool.new)
        assert_raises(Bench::CapExceeded) { chat.ask("go") }
        assert_equal 2, FakeNetwork.requests.size, "request 3 never started"
        assert_operator tight.committed_micro, :<=, tight.cap_micro
      end

      # -- metering anomalies: fail closed ------------------------------------

      def test_a_reply_without_a_metered_cost_halts_and_keeps_the_reservation
        l = ledger
        reply = FakeNetwork.text_reply("no usage")
        reply.delete("usage")
        FakeNetwork.script << reply
        g = guard(l)
        armed(g).ask("hi")
        assert_match(/no metered cost/, g.halted)
        entry = l.entries.first
        assert_nil entry["settled_micro"], "unmetered: the reservation stays counted"
        assert_equal entry["reserved_micro"], l.committed_micro
        # And nothing further runs.
        before = FakeNetwork.requests.size
        assert_raises(Bench::Halted) { armed(g).ask("again") }
        assert_equal before, FakeNetwork.requests.size
      end

      def test_a_reply_costing_more_than_its_reservation_is_recorded_halts_and_blocks_the_next_request
        l = ledger
        FakeNetwork.script << FakeNetwork.text_reply("expensive", input_tokens: 10_000_000, output_tokens: 20) # $10
        g = guard(l)
        armed(g).ask("hi")
        # Two things are wrong with this reply: its input count exceeds what the request
        # could hold, and its cost exceeds the reservation. The first check to fire names the halt.
        assert_match(/exceeded its reservation|more than the request could hold/, g.halted)
        assert_in_delta micro(10.0), l.committed_micro, 200, "counted at its full metered cost ($10 + output tokens)"
        before = FakeNetwork.requests.size
        assert_raises(Bench::Halted) { armed(g).ask("again") }
        assert_equal before, FakeNetwork.requests.size
      end

      def test_a_reply_with_more_output_tokens_than_the_bound_halts_even_if_its_cost_fits
        l = ledger
        g = guard(l, max_output_tokens: 16)
        FakeNetwork.script << FakeNetwork.text_reply("long", input_tokens: 10, output_tokens: 400) # $0.002 fits the margin
        armed(g).ask("hi")
        assert_match(/above the 16 bound/, g.halted)
        assert_raises(Bench::Halted) { armed(g).ask("again") }
      end

      def test_a_nan_infinite_or_negative_cost_halts_and_keeps_the_reservation
        [Float::NAN, Float::INFINITY, -1.0].each do |bad|
          l = ledger(path: File.join(@dir, "bad-#{bad}.json"))
          g = guard(l)
          chat = armed(g)
          FakeNetwork.script << Faraday::ConnectionFailed.new("down") # leaves the reservation open
          assert_raises(StandardError) { chat.ask("hi") }
          reply = Object.new
          reply.define_singleton_method(:role) { :assistant }
          reply.define_singleton_method(:cost) { Struct.new(:total).new(bad) }
          chat.send(:run_callbacks, :after_message, reply)
          assert_match(/not a finite non-negative number/, g.halted.to_s, bad.inspect)
          assert_nil l.entries.first["settled_micro"], "the reservation stays counted for #{bad.inspect}"
        end
      end

      def test_a_failed_request_keeps_its_worst_case_reservation_and_a_restart_still_sees_it
        l = ledger
        FakeNetwork.script << Faraday::ConnectionFailed.new("network down")
        chat = armed(guard(l))
        assert_raises(StandardError) { chat.ask("hi") }
        reserved = l.entries.first["reserved_micro"]
        assert_nil l.entries.first["settled_micro"]
        assert_equal reserved, l.committed_micro, "we cannot know it was not billed"

        # Restart: new ledger and guard objects over the same file.
        restarted = ledger
        assert_equal reserved, restarted.committed_micro
      end

      def test_after_a_restart_a_request_that_no_longer_fits_never_reaches_the_provider
        # Cap fits one worst-case request but not two.
        probe = ledger(path: File.join(@dir, "probe.json"))
        armed(guard(probe)).ask("hi")
        one = probe.entries.first["reserved_micro"]
        FakeNetwork.reset!

        cap = Rational(one + one / 2, Bench::MICRO)
        FakeNetwork.script << Faraday::ConnectionFailed.new("network down")
        first_run = ledger(cap: cap)
        assert_raises(StandardError) { armed(guard(first_run)).ask("hi") }
        started = FakeNetwork.requests.size

        # "Restart": brand-new objects.
        second_run = ledger(cap: cap)
        g = guard(second_run)
        assert_raises(Bench::CapExceeded) { armed(g).ask("hi") }
        assert_equal started, FakeNetwork.requests.size, "no new provider request after the restart"
      end

      # -- one ledger across models and runs ----------------------------------

      def test_two_models_and_two_guards_share_one_combined_cap
        # Measure one worst-case request on each model.
        probe_a = ledger(path: File.join(@dir, "pa.json"))
        armed(guard(probe_a), model: MODEL, label: "public").ask("hi")
        probe_b = ledger(path: File.join(@dir, "pb.json"))
        armed(guard(probe_b), model: "claude-sonnet-4-5", label: "private").ask("hi")
        reserve_a = probe_a.entries.first["reserved_micro"]
        reserve_b = probe_b.entries.first["reserved_micro"]
        FakeNetwork.reset!

        # A shared cap that fits A's reservation plus B's only if both are settled low.
        cap = Rational(reserve_a + reserve_b - 1, Bench::MICRO)
        FakeNetwork.script << Faraday::ConnectionFailed.new("down") # A fails: its reservation stays
        a = guard(ledger(cap: cap))
        assert_raises(StandardError) { armed(a, model: MODEL, label: "public").ask("hi") }

        b = guard(ledger(cap: cap)) # a different guard, a different model, the same file
        assert_raises(Bench::CapExceeded) { armed(b, model: "claude-sonnet-4-5", label: "private").ask("hi") }
        assert_equal 1, FakeNetwork.requests.size, "only A's request ever started"
        labels = ledger(cap: cap).entries.map { |e| e["label"] }
        assert_equal ["public"], labels
      end

      # -- one ledger, a per-run sub-cap ----------------------------------------

      def one_request_reserve
        probe = ledger(path: File.join(@dir, "probe-one.json"))
        armed(guard(probe, settlement: :reservation)).ask("hi")
        probe.entries.first["reserved_micro"].tap { FakeNetwork.reset! }
      end

      def test_a_run_sub_cap_limits_that_guard_and_its_spend_limits_a_later_run_with_no_manual_step
        one = one_request_reserve
        # The file is created by the smoke-style run: total cap $20, sub-cap about 2.5 requests.
        smoke = guard(ledger, settlement: :reservation, run_cap_usd: Rational(one * 5 / 2, Bench::MICRO))
        2.times { armed(smoke, label: "smoke").ask("hi") }
        assert_equal 2 * one, smoke.run_micro
        assert_raises(Bench::CapExceeded) { armed(smoke, label: "smoke").ask("hi") }
        assert_match(/run's sub-cap/, smoke.halted)
        assert_equal 2, FakeNetwork.requests.size, "the third request never started"
        assert_equal micro(20.0), JSON.parse(File.read(@path))["cap_micro"]

        # A later round run, same file, no sub-cap: it SEES the smoke spend ...
        round = ledger
        assert_equal 2 * one, round.committed_micro
        # ... and is not held to the smoke run's sub-cap.
        later = guard(round, settlement: :reservation)
        armed(later, label: "round").ask("hi")
        assert_equal 3 * one, round.committed_micro

        # A later run whose own total cap sits just under 4 requests is limited by the earlier spend.
        tight = ledger(cap: Rational(4 * one - 1, Bench::MICRO))
        assert_raises(Bench::CapExceeded) { armed(guard(tight, settlement: :reservation), label: "round").ask("hi") }
        assert_equal 3, FakeNetwork.requests.size
      end

      def test_the_run_sub_cap_follows_settlement
        FakeNetwork.script << FakeNetwork.text_reply("fine", input_tokens: 120, output_tokens: 20)
        g = guard(ledger, settlement: :metered, run_cap_usd: 0.9)
        armed(g).ask("hi")
        assert_in_delta 220, g.run_micro, 2, "the run total follows the settled amount, like the ledger"
        assert_equal g.run_micro, ledger.committed_micro
      end

      def test_a_bad_run_sub_cap_is_refused
        [0, -1, 20.01, "1"].each { |bad| assert_raises(Bench::Error, bad.inspect) { guard(run_cap_usd: bad) } }
      end

      # -- pump: compactor requests are counted -------------------------------

      def pump_tree(entries: 4)
        tree = Tree.for("spend-guard-pump-#{rand(1_000_000)}", compactor: MODEL)
        entries.times { |i| tree.append(:user, "entry #{i} " + "long " * 300) } # each over NODE: needs a model call
        tree
      end

      def test_pump_compactor_requests_are_all_reserved_in_the_ledger
        l = ledger
        g = guard(l)
        tree = pump_tree
        builder = Compactor.new(tree, model: MODEL,
          chat_factory: -> { armed(g, label: "compactor-pump") })
        built = Pump::Runner.new(tree, builder: builder, jobs: 4).run

        assert_operator built, :>, 0
        assert_operator FakeNetwork.requests.size, :>=, 4, "every long entry needed a model call"
        assert_equal FakeNetwork.requests.size, l.entries.size,
          "every provider request the pump made has exactly one ledger entry"
        assert l.entries.all? { |e| e["label"] == "compactor-pump" }
        assert l.entries.all? { |e| e["settled_micro"] }
        refute g.halted
      end

      def test_the_pump_stops_at_the_cap_and_starts_no_request_it_cannot_afford
        l = ledger(cap: 0.0001) # nothing fits
        g = guard(l)
        tree = pump_tree
        builder = Compactor.new(tree, model: MODEL, chat_factory: -> { armed(g, label: "compactor-pump") })
        built = Pump::Runner.new(tree, builder: builder, jobs: 4, retries: 1).run
        assert_equal 0, built
        assert_empty FakeNetwork.requests
        assert g.halted
        assert_raises(Bench::Halted, "the caller sees the halt even though the pump swallows node errors") { g.check! }
      end

      def test_parallel_pump_threads_never_overshoot_a_tight_cap
        probe = ledger(path: File.join(@dir, "pp.json"))
        armed(guard(probe)).ask("hi " * 200)
        one = probe.entries.first["reserved_micro"]
        FakeNetwork.reset!

        # Room for about two worst-case reservations at once; eight threads.
        l = ledger(cap: Rational(one * 2 + 10, Bench::MICRO))
        g = guard(l)
        tree = pump_tree(entries: 8)
        builder = Compactor.new(tree, model: MODEL, chat_factory: -> { armed(g, label: "compactor-pump") })
        Pump::Runner.new(tree, builder: builder, jobs: 8, retries: 1).run
        assert_operator l.committed_micro, :<=, l.cap_micro, "parallel reservations never exceed the cap"
        assert_equal FakeNetwork.requests.size, l.entries.size
      end
    end
  end
end
