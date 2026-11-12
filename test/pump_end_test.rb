# frozen_string_literal: true

require "test_helper"
require "timeout"
require "tmpdir"

module RubyLLM
  module InfiniteContext
    # How a pump pass ends (0.2.1). Found in production by comms: the 0.2.0
    # Runner waited on a plain Queue#pop for one result per worker, and a
    # worker pushed only after a normal end or a StandardError inside the
    # executor block. Anything else (an exception that is not a
    # StandardError, an executor hook error, a killed or stuck thread) left
    # the main thread waiting forever. Every test has its own hard limit, so
    # a regression fails instead of hanging the suite.
    class PumpEndTest < Minitest::Test
      LIMIT = 30

      # NoMemoryError-like: an exception that is not a StandardError.
      class FatalTestError < Exception; end # standard:disable Lint/InheritException

      # Answers each node with a short line, except when `bad` (called with
      # level, i and the call count of that node) raises or blocks.
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
          ["line #{level}.#{i}", 1]
        end
      end

      def setup
        @log = Queue.new
        @logger = ->(message) { @log << message }
      end

      def logged = Array.new(@log.size) { @log.pop }

      # Four entries with nodes 0+1 and 1+1 built: the first pass runs two
      # workers at once, nodes [0, 2] ("2+1") and [1, 0] ("0+2"). Then
      # [0, 3], [1, 1] and [2, 0] follow, one pass each: 5 nodes to build.
      def tree(name)
        t = Tree.create!(key: "pump-end-#{name}-#{rand(1_000_000)}")
        4.times { |n| t.append(:user, "entry #{n} " + "w" * 600) }
        t.store_node!(0, 0, "line 0.0", tries: 1)
        t.store_node!(0, 1, "line 0.1", tries: 1)
        t
      end

      def runner(t, builder, **options)
        Pump::Runner.new(t, builder:, jobs: 4, logger: @logger, **options)
      end

      def within_limit(&) = Timeout.timeout(LIMIT, &)

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # -- normal paths ---------------------------------------------------------

      def test_a_clean_run_builds_every_node_and_logs_nothing
        t = tree("clean")
        built = within_limit { runner(t, Builder.new).run }
        assert_equal 5, built
        assert_equal 7, t.nodes.count
        assert_equal [], logged
      end

      def test_pass_timeout_nil_turns_the_limit_off
        t = tree("no-limit")
        assert_equal 5, within_limit { runner(t, Builder.new, pass_timeout: nil).run }
      end

      def test_pass_timeout_must_be_positive_or_nil
        t = tree("bad-limit")
        [0, -1, "60"].each do |bad|
          assert_raises(ArgumentError) { Pump::Runner.new(t, builder: Builder.new, pass_timeout: bad) }
        end
        assert_equal 15 * 60, Pump::Runner::PASS_TIMEOUT
      end

      def test_a_standard_error_is_logged_and_retried_as_before
        t = tree("flaky")
        builder = Builder.new { |l, i, count| raise Error, "flaky" if [l, i] == [0, 2] && count == 1 }
        assert_equal 5, within_limit { runner(t, builder).run }
        assert_equal ["node 2+1 failed: RubyLLM::InfiniteContext::Error: flaky"], logged
      end

      # -- fatal errors in a worker ---------------------------------------------

      def test_system_stack_error_in_a_worker_is_raised_after_the_pass
        t = tree("stack")
        builder = Builder.new { |l, i, _| raise SystemStackError, "deep" if [l, i] == [1, 0] }
        error = within_limit { assert_raises(SystemStackError) { runner(t, builder).run } }
        assert_equal "deep", error.message
        assert_equal 3, t.nodes.count, "the other workers of the pass finished first"
        assert t.nodes.exists?(level: 0, i: 2)
        refute t.nodes.exists?(level: 1, i: 0)
      end

      def test_an_exception_that_is_not_a_standard_error_is_raised_not_swallowed
        t = tree("fatal")
        builder = Builder.new { |l, i, _| raise FatalTestError, "no memory" if [l, i] == [0, 2] }
        within_limit { assert_raises(FatalTestError) { runner(t, builder).run } }
        assert_equal 1, builder.calls[[0, 2]], "a fatal error is not retried"
        assert_equal [], logged
      end

      def test_an_interrupt_in_a_worker_is_raised_in_the_calling_thread
        t = tree("interrupt")
        builder = Builder.new { |l, i, _| raise Interrupt if [l, i] == [1, 0] }
        within_limit { assert_raises(Interrupt) { runner(t, builder).run } }
      end

      # -- a killed worker ------------------------------------------------------

      def test_a_killed_worker_reports_a_failure_and_its_node_is_retried
        t = tree("killed")
        builder = Builder.new { |l, i, count| Thread.current.kill if [l, i] == [0, 2] && count == 1 }
        built = within_limit { runner(t, builder).run }
        assert_equal 5, built
        assert_equal 2, builder.calls[[0, 2]]
        assert_equal ["node 2+1 failed: its worker thread was stopped"], logged
      end

      def test_a_worker_that_ends_without_a_result_raises_worker_lost
        t = tree("lost")
        lossy = Class.new(Pump::Runner) do
          private def work(node, done, stop) = (node == [0, 2]) ? nil : super
        end
        started = now
        error = within_limit do
          assert_raises(PumpWorkerLost) { lossy.new(t, builder: Builder.new, jobs: 4, logger: @logger).run }
        end
        assert_match(/1 of 2 pump workers ended without a result/, error.message)
        assert_operator now - started, :<, 10, "found at the next liveness check, not at the pass timeout"
      end

      # -- the Rails executor's own hooks ---------------------------------------

      def with_wrap_thread(body)
        original = Pump.method(:wrap_thread)
        Pump.singleton_class.send(:remove_method, :wrap_thread)
        Pump.define_singleton_method(:wrap_thread, &body)
        yield
      ensure
        Pump.singleton_class.send(:remove_method, :wrap_thread)
        Pump.define_singleton_method(:wrap_thread, original)
      end

      def test_an_executor_hook_error_after_the_body_counts_as_a_failure_and_is_logged
        t = tree("hook-after")
        calls = 0
        lock = Mutex.new
        hook = proc do |&block|
          block.call
          raise ::ActiveRecord::ConnectionTimeoutError, "hook" if lock.synchronize { calls += 1 } == 1
        end
        built = with_wrap_thread(hook) { within_limit { runner(t, Builder.new).run } }
        assert_equal 4, built, "the node whose hook failed counts as failed"
        assert_equal 7, t.nodes.count, "it was stored before the hook failed, so it is not built again"
        assert_equal 1, logged.grep(/failed in the executor: ActiveRecord::ConnectionTimeoutError: hook/).size
      end

      def test_an_executor_hook_error_before_the_body_is_retried
        t = tree("hook-before")
        calls = 0
        lock = Mutex.new
        hook = proc do |&block|
          raise ::ActiveRecord::ConnectionTimeoutError, "hook" if lock.synchronize { calls += 1 } == 1

          block.call
        end
        built = with_wrap_thread(hook) { within_limit { runner(t, Builder.new).run } }
        assert_equal 5, built
        assert_equal 7, t.nodes.count
      end

      def test_a_worker_killed_in_an_executor_hook_after_the_body_is_not_counted_as_built
        t = tree("hook-kill")
        calls = 0
        lock = Mutex.new
        hook = proc do |&block|
          block.call
          Thread.current.kill if lock.synchronize { calls += 1 } == 1
        end
        built = with_wrap_thread(hook) { within_limit { runner(t, Builder.new).run } }
        assert_equal 4, built, "the killed worker's node counts as failed"
        assert_equal 7, t.nodes.count, "it was stored, so it is not built again"
        assert_equal 1, logged.grep(/failed: its worker thread was stopped/).size
      end

      def test_a_logger_that_raises_loses_no_result
        t = tree("bad-logger")
        builder = Builder.new { |l, i, count| raise Error, "flaky" if [l, i] == [0, 2] && count == 1 }
        logger = ->(_message) { raise IOError, "log disk full" }
        built = within_limit { Pump::Runner.new(t, builder:, jobs: 4, logger:).run }
        assert_equal 5, built
      end

      def test_a_fatal_executor_hook_error_is_raised
        t = tree("hook-fatal")
        hook = proc { |&_block| raise FatalTestError, "hook" }
        with_wrap_thread(hook) { within_limit { assert_raises(FatalTestError) { runner(t, Builder.new).run } } }
      end

      # -- a stuck worker -------------------------------------------------------

      def test_a_worker_that_never_returns_times_out_logs_where_it_is_and_is_stopped
        t = tree("stuck")
        stuck = Queue.new
        builder = Builder.new { |l, i, _| stuck.pop if [l, i] == [1, 0] } # waits forever
        started = now
        error = within_limit { assert_raises(PumpTimeout) { runner(t, builder, pass_timeout: 0.3).run } }
        assert_operator now - started, :<, 10
        assert_match(/took longer than 0.3 s; 1 of 2 workers were stopped/, error.message)
        assert_equal 0, stuck.num_waiting, "the stuck worker was stopped"
        lines = logged
        assert_includes lines, "pass timed out after 0.3 s: 1 of 2 nodes have no result"
        where = lines.grep(/\Anode 0\+2 stuck at: /).first
        refute_nil where
        assert_includes where, "#{__FILE__}:"
        assert_match(/:\d+:in /, where)
        assert_operator where.split(" | ").size, :<=, Pump::Runner::FRAMES
        refute_match(/stuck\.pop|Queue/, where.sub(/\Anode 0\+2 stuck at: /, "").gsub(/in [^|]*/, ""),
          "file:line:method only")
        assert_equal 3, t.nodes.count, "the other node of the pass was stored"
      end

      def test_a_fatal_error_reported_before_the_timeout_wins_over_the_timeout
        t = tree("fatal-and-stuck")
        stuck = Queue.new
        builder = Builder.new do |l, i, _|
          raise FatalTestError, "no memory" if [l, i] == [0, 2]
          stuck.pop if [l, i] == [1, 0]
        end
        within_limit { assert_raises(FatalTestError) { runner(t, builder, pass_timeout: 0.3).run } }
        assert_equal 0, stuck.num_waiting, "the stuck worker was stopped"
        assert_equal 1, logged.grep(/\Anode 0\+2 stuck at: /).size
      end

      # Node [1, 0]'s store runs `hold` (a block) first; node [0, 2] never
      # returns. The pass limit is 1 s and the stop wait `stop_wait`.
      def slow_store_run(name, stop_wait, hold)
        t = tree(name)
        t.define_singleton_method(:store_node!) do |level, i, text, tries:|
          hold.call if [level, i] == [1, 0]
          super(level, i, text, tries:)
        end
        stuck = Queue.new
        builder = Builder.new { |l, i, _| stuck.pop if [l, i] == [0, 2] }
        r = runner(t, builder, pass_timeout: 1.0)
        r.instance_variable_set(:@stop_wait, stop_wait)
        error = within_limit { assert_raises(PumpTimeout) { r.run } }
        [t, error]
      end

      def test_a_store_running_at_the_timeout_finishes_before_the_run_raises
        t, error = slow_store_run("store-finishes", 5, -> { sleep 1.5 }) # ends 0.5 s after the limit
        assert_match(/2 of 2 workers were stopped/, error.message)
        assert t.nodes.where(level: 1, i: 0).exists?, "the store ran to its end before PumpTimeout"
        lines = logged
        assert_empty lines.grep(/still storing|were left/), lines.inspect
      end

      def test_a_store_that_ignores_the_kill_is_logged_once_and_left
        entered = Queue.new
        release = Queue.new
        ended = Queue.new
        deaf = lambda do
          entered << true
          Thread.handle_interrupt(Object => :never) { release.pop } # ignores Thread#kill until released
        ensure
          ended << true
        end
        t, _error = slow_store_run("store-deaf", 0.2, deaf)
        assert entered.pop(timeout: 0), "the store had started"
        lines = logged
        assert_equal 1, lines.grep(/1 stuck worker threads did not stop and were left/).size, lines.inspect
        assert_equal 1, lines.grep(/1 stuck worker threads were still storing a node/).size, lines.inspect
        release << true
        assert ended.pop(timeout: 5), "the left worker ended once released"
        refute t.nodes.where(level: 1, i: 0).exists?, "the pending kill stopped it before the write"
      end

      def test_a_worker_whose_pass_was_given_up_stores_nothing
        t = tree("given-up")
        stop = Pump::Runner::Stop.new
        builder = Builder.new { stop.set! } # the caller gives up while the model call runs
        done = Queue.new
        runner(t, builder).send(:work, [0, 2], done, stop)
        assert_equal [[0, 2], false, nil], done.pop
        refute t.nodes.exists?(level: 0, i: 2)
        assert_equal [], logged
      end

      # The production hang (comms, Nov 12): workers stuck on a lock, no
      # network. One way to get there in a process that does not eager-load:
      # two workers autoload two files that refer to each other while they
      # load, and each waits for the other's require forever.
      # Each file waits at its top until `parties` files have started to
      # load (at most 5 s), so both workers hold their own file first.
      class Barrier
        def initialize(parties)
          @parties = parties
          @arrived = 0
          @lock = Mutex.new
          @cond = ConditionVariable.new
        end

        def arrive
          @lock.synchronize do
            @arrived += 1
            @cond.broadcast
            limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
            while @arrived < @parties
              left = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              break unless left.positive?

              @cond.wait(@lock, left)
            end
          end
        end
      end

      def autoload_pair(name, parties)
        dir = File.realpath(Dir.mktmpdir)
        a = "IcCycle#{name}A"
        b = "IcCycle#{name}B"
        barrier = "IcCycle#{name}Barrier"
        Object.const_set(barrier, Barrier.new(parties))
        File.write("#{dir}/a.rb", "#{barrier}.arrive\nmodule #{a}; OTHER = #{b}; end\n")
        File.write("#{dir}/b.rb", "#{barrier}.arrive\nmodule #{b}; OTHER = #{a}; end\n")
        Object.autoload(a.to_sym, "#{dir}/a.rb")
        Object.autoload(b.to_sym, "#{dir}/b.rb")
        [a, b, dir]
      end

      def autoloading_builder(a, b)
        Builder.new do |l, i, _|
          Object.const_get(a) if [l, i] == [0, 2]
          Object.const_get(b) if [l, i] == [1, 0]
        end
      end

      def test_workers_deadlocked_on_autoload_time_out_with_their_locations
        a, b, dir = autoload_pair("Hang", 2)
        t = tree("autoload-hang")
        error = within_limit { assert_raises(PumpTimeout) { runner(t, autoloading_builder(a, b), pass_timeout: 1.5).run } }
        assert_match(/2 of 2 workers were stopped/, error.message)
        lines = logged
        assert_equal 2, lines.grep(/stuck at: .*#{Regexp.escape(dir)}\/[ab]\.rb:\d+:in /).size, lines.inspect
      ensure
        FileUtils.rm_rf(dir) if dir
      end

      def test_loading_the_builders_classes_first_avoids_the_autoload_deadlock
        a, b, dir = autoload_pair("Loaded", 1)
        Object.const_get(a) # what the README asks: load first, in one thread
        t = tree("autoload-loaded")
        assert_equal 5, within_limit { runner(t, autoloading_builder(a, b), pass_timeout: 5).run }
      ensure
        FileUtils.rm_rf(dir) if dir
      end

      def test_preload_loads_ruby_llms_lazy_constants_once
        Pump.preload
        Pump.preload
        assert_nil ::RubyLLM.autoload?(:Chat)
        assert_nil ::RubyLLM::Providers.autoload?(:OpenAI)
      end
    end
  end
end
