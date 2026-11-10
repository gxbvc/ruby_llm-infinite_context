# frozen_string_literal: true

require "test_helper"
require "support/fake_network"
require "tmpdir"
require "json"
require_relative "../bench/spend_guard"

module RubyLLM
  module InfiniteContext
    # The optional request_scanner hook on Bench::Guard. The scanner gets the
    # exact JSON body before every request, before any reservation. nil lets
    # the request go; a String reason, any other value or an exception halts
    # the guard, and nothing is reserved or sent. All text here is synthetic,
    # over the in-process fake network: no key, no socket, no provider.
    class RequestScannerHookTest < Minitest::Test
      MODEL = "claude-haiku-4-5"
      PROMPT = "the blue kettle is on shelf seven"

      def setup
        @previous = FakeNetwork.install!(max_retries: 0)
        FakeNetwork.reset!
        @dir = Dir.mktmpdir("request-scanner")
        @ledger = Bench::Ledger.new(File.join(@dir, "ledger.json"))
      end

      def teardown
        FakeNetwork.restore!(@previous)
        FileUtils.rm_rf(@dir)
      end

      def armed(scanner)
        guard = Bench::Guard.new(ledger: @ledger, request_scanner: scanner)
        [guard, guard.arm(RubyLLM.chat(model: MODEL), model: MODEL, label: "t")]
      end

      def assert_nothing_reserved_or_sent
        assert_empty FakeNetwork.calls, "no request reached the network"
        assert_empty @ledger.entries, "no reservation was written"
        assert_equal 0, @ledger.committed_micro
      end

      def test_a_clean_body_passes_and_the_scanner_sees_the_exact_json_body
        seen = []
        _guard, chat = armed(->(body) {
          seen << body
          nil
        })

        assert_equal "ok", chat.ask(PROMPT).content
        assert_equal 1, seen.size
        assert_kind_of String, seen.first
        assert_includes seen.first, PROMPT
        assert_equal FakeNetwork.requests.first, JSON.parse(seen.first), "the scanned body is the body that was sent"
        assert_equal 1, FakeNetwork.calls.size
        assert_equal 1, @ledger.entries.size, "the request was reserved after the scan"
      end

      def test_a_returned_reason_halts_before_any_reservation_or_request
        guard, chat = armed(->(_body) { "synthetic marker found" })

        error = assert_raises(Bench::Halted) { chat.ask(PROMPT) }
        assert_includes error.message, "synthetic marker found"
        assert_includes guard.halted, "request scanner refused the body: synthetic marker found"
        refute_includes guard.halted, PROMPT, "the halt reason never carries request text"
        assert_nothing_reserved_or_sent
      end

      def test_the_halt_is_sticky_and_the_scanner_is_not_asked_again
        calls = 0
        guard, chat = armed(->(_body) {
          calls += 1
          "synthetic marker found"
        })
        assert_raises(Bench::Halted) { chat.ask(PROMPT) }

        assert_raises(Bench::Halted) { chat.ask("a different synthetic question") }
        assert_raises(Bench::Halted, "a halted guard arms no new chat") do
          guard.arm(RubyLLM.chat(model: MODEL), model: MODEL, label: "t2")
        end
        assert_equal 1, calls, "a halted guard refuses before it scans"
        assert_nothing_reserved_or_sent
      end

      def test_an_exception_halts_with_the_class_name_only
        guard, chat = armed(->(_body) { raise ArgumentError, "scanner detail that must not leak" })

        error = assert_raises(Bench::Halted) { chat.ask(PROMPT) }
        assert_includes guard.halted, "request scanner failed (ArgumentError)"
        refute_includes guard.halted, "scanner detail that must not leak"
        refute_includes error.message, "scanner detail that must not leak"
        refute_includes guard.halted, PROMPT
        assert_nothing_reserved_or_sent
      end

      def test_an_unexpected_return_value_halts
        guard, chat = armed(->(_body) { true })

        assert_raises(Bench::Halted) { chat.ask(PROMPT) }
        assert_includes guard.halted, "unexpected scanner result"
        assert_nothing_reserved_or_sent
      end

      def test_a_scanner_that_cannot_be_called_is_refused_at_construction
        error = assert_raises(Bench::Error) { Bench::Guard.new(ledger: @ledger, request_scanner: "not callable") }
        assert_match(/request_scanner must respond to call/, error.message)
      end
    end
  end
end
