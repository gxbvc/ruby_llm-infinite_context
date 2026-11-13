# frozen_string_literal: true

require "test_helper"
require "timeout"

module RubyLLM
  module InfiniteContext
    # Pump::Runner hooks (0.2.3): before_pass can hold a run before a pass
    # sends anything; on_result gets one numbers-only Result per node
    # result. An error in a hook loses no result and hangs no pass.
    class PumpHooksTest < Minitest::Test
      LIMIT = 30

      class FatalTestError < Exception; end # standard:disable Lint/InheritException

      class Builder
        attr_reader :calls

        def initialize(&bad)
          @bad = bad
          @calls = Hash.new(0)
          @lock = Mutex.new
        end

        def build(level, i)
          count = @lock.synchronize { @calls[[level, i]] += 1 }
          @bad&.call(level, i, count)
          ["line #{level}.#{i}", 2]
        end
      end

      def setup
        @log = Queue.new
        @logger = ->(message) { @log << message }
        @results = Queue.new
        @on_result = ->(r) { @results << r }
      end

      def logged = Array.new(@log.size) { @log.pop }

      def results = Array.new(@results.size) { @results.pop }

      # Four entries with nodes 0+1 and 1+1 built. Passes: [0, 2] and [1, 0]
      # together, then [0, 3], [1, 1], [2, 0] one each: 5 nodes.
      def tree(name)
        t = Tree.create!(key: "pump-hooks-#{name}-#{rand(1_000_000)}")
        4.times { |n| t.append(:user, "entry #{n} " + "w" * 600) }
        t.store_node!(0, 0, "line 0.0", tries: 1)
        t.store_node!(0, 1, "line 0.1", tries: 1)
        t
      end

      def runner(t, builder, **options)
        Pump::Runner.new(t, builder:, jobs: 4, logger: @logger, **options)
      end

      def within_limit(&) = Timeout.timeout(LIMIT, &)

      def summary(list) = list.map { |r| [r.level, r.index, r.ok, r.tries] }.sort_by { |l, i, ok, _| [l, i, ok ? 1 : 0] }

      # -- on_result ------------------------------------------------------------

      def test_on_result_gets_one_numbers_only_result_per_node
        t = tree("results")
        assert_equal 5, within_limit { runner(t, Builder.new, on_result: @on_result).run }
        got = results
        assert_equal [[0, 2, true, 2], [0, 3, true, 2], [1, 0, true, 2], [1, 1, true, 2], [2, 0, true, 2]], summary(got)
        got.each do |r|
          assert_kind_of Pump::Result, r
          assert r.ok?
          assert_equal %i[level index ok tries], r.to_h.keys
          assert(r.to_h.values.all? { |v| v.is_a?(Integer) || v == true || v == false || v.nil? }, "numbers only")
        end
        assert_equal [], logged
      end

      def test_a_failed_node_reports_failed_then_built
        t = tree("failed")
        builder = Builder.new { |l, i, count| raise Error, "flaky" if [l, i] == [0, 2] && count == 1 }
        assert_equal 5, within_limit { runner(t, builder, on_result: @on_result).run }
        got = summary(results)
        assert_equal [[0, 2, false, nil], [0, 2, true, 2]], got.select { |l, i, *| [l, i] == [0, 2] }
        assert_equal 6, got.size
      end

      def test_an_on_result_hook_that_raises_loses_no_result
        t = tree("bad-on-result")
        calls = 0
        hook = lambda do |_r|
          calls += 1
          raise IOError, "private text that must not be logged"
        end
        built = within_limit { runner(t, Builder.new, on_result: hook).run }
        assert_equal 5, built
        assert_equal 5, calls, "every result still reached the hook"
        assert_equal 7, t.nodes.count
        lines = logged
        assert_equal ["on_result raised IOError; ignored"] * 5, lines
        refute_match(/private text/, lines.join)
      end

      def test_on_result_runs_for_the_results_of_a_pass_that_raises
        t = tree("fatal")
        builder = Builder.new { |l, i, _| raise FatalTestError, "deep" if [l, i] == [1, 0] }
        within_limit { assert_raises(FatalTestError) { runner(t, builder, on_result: @on_result).run } }
        assert_equal [[0, 2, true, 2], [1, 0, false, nil]], summary(results)
      end

      def test_on_result_runs_for_the_results_of_a_pass_that_timed_out
        t = tree("timeout")
        stuck = Queue.new
        builder = Builder.new { |l, i, _| stuck.pop if [l, i] == [1, 0] }
        within_limit do
          assert_raises(PumpTimeout) { runner(t, builder, on_result: @on_result, pass_timeout: 0.3).run }
        end
        assert_equal [[0, 2, true, 2], [1, 0, false, nil]], summary(results)
      end

      def test_an_on_result_hook_that_raises_does_not_hide_a_fatal_error
        t = tree("fatal-bad-hook")
        builder = Builder.new { |l, i, _| raise FatalTestError, "deep" if [l, i] == [1, 0] }
        hook = ->(_r) { raise ArgumentError, "hook" }
        within_limit { assert_raises(FatalTestError) { runner(t, builder, on_result: hook).run } }
        assert_equal ["on_result raised ArgumentError; ignored"] * 2, logged
      end

      def test_an_interrupt_in_on_result_does_not_hide_the_pass_error_or_skip_results
        t = tree("fatal-interrupt-hook")
        builder = Builder.new { |l, i, _| raise FatalTestError, "deep" if [l, i] == [1, 0] }
        calls = 0
        hook = lambda do |_r|
          calls += 1
          raise Interrupt
        end
        within_limit { assert_raises(FatalTestError) { runner(t, builder, on_result: hook).run } }
        assert_equal 2, calls, "every result reached the hook"
        assert_equal ["on_result raised Interrupt"] * 2, logged
      end

      def test_an_interrupt_in_on_result_is_raised_after_every_result_of_the_pass
        t = tree("interrupt-hook")
        calls = 0
        hook = lambda do |_r|
          calls += 1
          raise Interrupt if calls == 1
        end
        within_limit { assert_raises(Interrupt) { runner(t, Builder.new, on_result: hook).run } }
        assert_equal 2, calls, "the second result of the pass still reached the hook"
        assert_equal 4, t.nodes.count, "both nodes of the pass were stored"
      end

      # -- before_pass ----------------------------------------------------------

      def test_before_pass_gets_the_size_of_each_pass
        t = tree("sizes")
        sizes = []
        r = runner(t, Builder.new, before_pass: ->(n) { sizes << n })
        assert_equal 5, within_limit { r.run }
        assert_equal [2, 1, 1, 1], sizes
        refute r.held?
      end

      def test_before_pass_returning_false_stops_before_anything_is_sent
        t = tree("false")
        builder = Builder.new
        r = runner(t, builder, before_pass: ->(_n) { false }, on_result: @on_result)
        assert_equal 0, within_limit { r.run }
        assert r.held?
        assert_empty builder.calls, "no node was built: nothing was sent"
        assert_equal 2, t.nodes.count
        assert_empty results
        assert_equal [], logged
      end

      def test_before_pass_returning_nil_lets_the_pass_run
        t = tree("nil")
        assert_equal 5, within_limit { runner(t, Builder.new, before_pass: ->(_n) {}).run }
      end

      def test_hold_on_a_later_pass_keeps_the_earlier_results
        t = tree("hold")
        builder = Builder.new
        passes = 0
        hook = lambda do |_n|
          passes += 1
          raise Pump::Hold if passes == 2
        end
        r = runner(t, builder, before_pass: hook, on_result: @on_result)
        assert_equal 2, within_limit { r.run }
        assert r.held?
        assert_equal [[0, 2], [1, 0]], builder.calls.keys.sort
        assert_equal 4, t.nodes.count
        assert_equal 2, results.size
        assert_equal [], logged, "a Hold is not an error"
        # The next run starts fresh.
        r2 = runner(t, builder)
        assert_equal 3, within_limit { r2.run }
        refute r2.held?
      end

      def test_a_before_pass_hook_that_raises_stops_the_run_and_logs_the_class
        t = tree("raises")
        builder = Builder.new
        r = runner(t, builder, before_pass: ->(_n) { raise KeyError, "private text" })
        assert_equal 0, within_limit { r.run }
        assert r.held?
        assert_empty builder.calls
        assert_equal ["before_pass raised KeyError; the run stops before the pass"], logged
      end

      def test_held_resets_on_the_next_run
        t = tree("reset")
        allow = false
        r = runner(t, Builder.new, before_pass: ->(_n) { allow })
        assert_equal 0, within_limit { r.run }
        assert r.held?
        allow = true
        assert_equal 5, within_limit { r.run }
        refute r.held?
      end

      def test_hooks_must_be_callable
        t = tree("callable")
        assert_raises(ArgumentError) { Pump::Runner.new(t, builder: Builder.new, before_pass: 1) }
        assert_raises(ArgumentError) { Pump::Runner.new(t, builder: Builder.new, on_result: "x") }
      end
    end
  end
end
