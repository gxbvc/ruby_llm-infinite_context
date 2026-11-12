# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # The compactor's scheduler. Builds every node that is not built, has its
    # sources, and has its whole context summarized (every view line before
    # the node's end is built). Up to JOBS at once; a failed node is retried
    # up to `retries` times. A ProtocolError (see required_protocol) is a
    # setup error: the run stops and raises it. So does any exception that is
    # not a StandardError in a worker (NoMemoryError, SystemStackError,
    # Interrupt...). A pass that takes longer than `pass_timeout` stops and
    # raises PumpTimeout.
    module Pump
      PRELOAD_LOCK = Mutex.new

      # The nodes to start now, in order: levels from 0 up, and in each
      # level from the left. `built` and `busy` are sets of [level, i].
      def self.ready_nodes(total:, first:, built:, busy:, slots:)
        out = []
        l = 0
        while (1 << l) <= total
          i = 0
          while ((i + 1) << l) <= total
            return out if out.size >= slots

            node = [l, i]
            finish = l.zero? ? i : (i + 1) << l
            if !built.include?(node) && !busy.include?(node) && finish <= first &&
                (l.zero? || (built.include?([l - 1, 2 * i]) && built.include?([l - 1, 2 * i + 1])))
              out << node
            end
            i += 1
          end
          l += 1
        end
        out
      end

      # Runs a worker thread's body inside the Rails executor when a Rails
      # app is running, else plain.
      def self.wrap_thread(&block)
        executor = (defined?(::Rails) && ::Rails.respond_to?(:application)) ? ::Rails.application&.executor : nil
        executor ? executor.wrap(&block) : block.call
      end

      # Runs a blocking wait for worker threads so that they may autoload
      # constants meanwhile (the Rails load interlock, active when reloading
      # is on). Plain when ActiveSupport::Dependencies has no interlock.
      def self.waiting(&block)
        if defined?(::ActiveSupport::Dependencies) && ::ActiveSupport::Dependencies.respond_to?(:interlock)
          ::ActiveSupport::Dependencies.interlock.permit_concurrent_loads(&block)
        else
          block.call
        end
      end

      # Loads RubyLLM's lazy (Zeitwerk) constants once per process, in the
      # calling thread, before the first worker starts. In a process that
      # does not eager-load (a rake task, development), the workers would
      # otherwise autoload them at the same time, and two files that refer
      # to each other while they load can then wait on each other forever
      # (Ruby's require lock). The app's own classes (a custom builder, its
      # chat options) are the app's job: see the README, "Threads".
      # A file that fails to load here is left to load lazily, as before.
      def self.preload
        return if @preloaded

        PRELOAD_LOCK.synchronize do
          return if @preloaded

          begin
            if defined?(::Zeitwerk::Loader) && ::Zeitwerk::Loader.respond_to?(:eager_load_namespace)
              ::Zeitwerk::Loader.eager_load_namespace(::RubyLLM)
            end
          rescue ScriptError, StandardError
            nil
          end
          @preloaded = true
        end
      end

      # Runs passes over the tree until no more nodes can start. Each pass
      # starts up to `jobs` builder threads and waits for them. `builder`
      # must answer build(level, i) and return [text, tries].
      #
      # How a pass ends (0.2.1, after a production hang in an app):
      # - Every worker reports exactly one result, whatever ends it: a normal
      #   end, a StandardError in the builder or in the Rails executor's own
      #   hooks (logged, the node counts as failed and is retried), any other
      #   exception (raised in the calling thread after the pass), or a
      #   killed thread (logged, failed). A node counts as built only when
      #   the executor has finished too. A logger that raises is ignored.
      # - The wait for one pass has a limit, `pass_timeout` seconds (default
      #   PASS_TIMEOUT; nil turns it off). Past it, the location of every
      #   stuck worker is logged (file:line:in method, a few frames, no
      #   values), the stuck workers are stopped, and the run raises
      #   PumpTimeout (or a fatal error a worker reported before the
      #   limit). Before the kill, a store already running gets STOP_WAIT
      #   seconds to finish, and no worker starts a new one. A worker that
      #   ignores Thread#kill is left and logged; the builder's own work (a
      #   model call already sent) cannot be taken back.
      # - If every worker has ended and a result is still missing, the run
      #   raises PumpWorkerLost at once.
      # - If the calling thread leaves a pass early (an Interrupt there), the
      #   pass's workers are stopped the same way.
      class Runner
        include TreeMath

        # Seconds one pass may take. A node is normally a few model calls of a
        # few seconds each; a pass this long means something is stuck.
        PASS_TIMEOUT = 15 * 60
        # Seconds between checks that the workers are still alive.
        POLL = 1.0
        # Seconds to wait for each stopped worker to end before it is left.
        STOP_WAIT = 5
        # Frames logged for each stuck worker.
        FRAMES = 6

        # chat_options: for the default Compactor (ignored when `builder:` is given).
        # pass_timeout: seconds one pass may take (nil: no limit).
        def initialize(tree, builder: nil, jobs: JOBS, retries: 3, logger: nil, chat_options: nil,
          pass_timeout: PASS_TIMEOUT)
          valid = pass_timeout.nil? || (pass_timeout.is_a?(Numeric) && pass_timeout.positive?)
          unless valid
            raise ArgumentError, "pass_timeout must be a positive number of seconds or nil"
          end

          @tree = tree
          @builder = builder ||
            Compactor.new(tree, model: tree.compactor_model, chat_options: chat_options)
          @jobs = jobs
          @retries = retries
          @logger = logger
          @pass_timeout = pass_timeout
          @stop_wait = STOP_WAIT
        end

        # Returns the number of nodes built.
        #
        # The workers write on their own connections, so this thread must
        # read the database fresh: inside a Rails executor (rails runner, a
        # request, a job) the Active Record query cache is on, and a cached
        # read of the node sizes never shows a node a worker just stored, so
        # the same node was built forever (found by bin/install_check). The
        # cache is bypassed for the run and cleared at the end, so the
        # caller's next read (the view) is fresh too.
        def run
          built = 0
          attempts = Hash.new(0)
          ::ActiveRecord::Base.uncached do
            loop do
              nodes = startable(Set.new)
              nodes.reject! { |n| attempts[n] >= @retries }
              break if nodes.empty?

              Pump.preload
              run_pass(nodes).each do |node, ok|
                if ok
                  built += 1
                else
                  attempts[node] += 1
                end
              end
            end
          end
          built
        ensure
          if ::ActiveRecord::Base.respond_to?(:clear_query_caches_for_current_thread)
            ::ActiveRecord::Base.clear_query_caches_for_current_thread
          end
        end

        private

        def startable(busy)
          @tree.with_view_lock do
            sizes = @tree.node_sizes
            built = sizes.keys.to_set
            total = @tree.entry_count
            view = @tree.view(COMPACT_VIEW_BUDGET)
            first = Fold.new(parts: view.parts) { |l, i| sizes[[l, i]] }.first_unbuilt(total)
            Pump.ready_nodes(total:, first:, built:, busy:, slots: @jobs)
          end
        end

        def run_pass(nodes)
          done = Queue.new
          stop = Stop.new
          threads = nodes.map { |node| Thread.new { work(node, done, stop) } }
          results = nil
          begin
            # While this thread waits, the workers may autoload constants. With
            # reloading on (Rails development) that needs the load interlock, so
            # the wait must permit concurrent loads or the pass deadlocks.
            results = Pump.waiting do
              out = collect(nodes, done, threads, stop)
              threads.each { |thread| thread.join(@stop_wait) }
              out
            end
          ensure
            # This thread left the wait early (a timeout, a lost worker, an
            # Interrupt here): no worker of this pass keeps running or writes.
            stop_workers(threads, stop) unless results || stop.set?
          end
          fatal = results.map(&:last).compact.first
          raise fatal if fatal

          results.map { |node, ok, _| [node, ok] }
        end

        # Set when the calling thread gives up on a pass. After that no worker
        # of the pass starts to store its node, and the calling thread waits
        # a little for the stores already running (see stop_workers).
        class Stop
          def initialize
            @lock = Mutex.new
            @cond = ConditionVariable.new
            @set = false
            @storing = 0
          end

          # Runs the block (the store) unless the pass was given up. A kill
          # is held off while the count changes, so the count stays right;
          # the store itself can still be killed.
          def store
            Thread.handle_interrupt(Object => :never) do
              @lock.synchronize do
                raise Stopped if @set

                @storing += 1
              end
              begin
                Thread.handle_interrupt(Object => :immediate) { yield }
              ensure
                @lock.synchronize do
                  @storing -= 1
                  @cond.broadcast
                end
              end
            end
          end

          # Gives up the pass, then waits up to `wait` seconds for the stores
          # already running. Returns how many are still running.
          def set!(wait = 0)
            @lock.synchronize do
              @set = true
              limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
              while @storing.positive?
                left = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)
                break unless left.positive?

                @cond.wait(@lock, left)
              end
              @storing
            end
          end

          def set? = @lock.synchronize { @set }

          def storing = @lock.synchronize { @storing }
        end

        # One node. Pushes exactly one [node, ok, fatal] to `done`, whatever
        # ends the thread. The node counts as built only when the executor
        # has finished too.
        def work(node, done, stop)
          result = nil
          inner = nil
          begin
            # In a Rails app each worker thread runs inside the executor (it
            # returns the thread's database connection when it ends).
            Pump.wrap_thread do
              text, tries = @builder.build(*node)
              stop.store { @tree.store_node!(*node, text, tries:) }
              inner = [node, true, nil]
            rescue ProtocolError => e
              # A setup error, not a flaky call: no retry, raised after the pass.
              inner = [node, false, e]
            rescue Stopped
              inner = [node, false, nil]
            rescue => e
              inner = [node, false, nil]
              log("node #{TreeMath.label(*node)} failed: #{e.class}: #{e.message}")
            end
            result = inner
          rescue ProtocolError => e
            result = [node, false, e]
          rescue => e
            # An error in the executor's own hooks. The node may be stored;
            # it counts as failed here (a stored node is not built again).
            result = [node, false, nil]
            log("node #{TreeMath.label(*node)} failed in the executor: #{e.class}: #{e.message}")
          rescue Exception => e # standard:disable Lint/RescueException
            # NoMemoryError, SystemStackError, Interrupt...: raised after the pass.
            result = [node, false, e]
          ensure
            killed = result.nil?
            done << (result || [node, false, nil])
            log("node #{TreeMath.label(*node)} failed: its worker thread was stopped") if killed && !stop.set?
          end
        end

        # Raised inside a worker whose pass was given up: it stores nothing.
        class Stopped < StandardError; end

        # One result per node, in the order they come. Raises PumpTimeout past
        # the pass timeout (or a worker's fatal error that came before it) and
        # PumpWorkerLost when every worker has ended and a result is still
        # missing.
        def collect(nodes, done, threads, stop)
          deadline = @pass_timeout && now + @pass_timeout
          results = []
          while results.size < nodes.size
            wait = deadline ? (deadline - now).clamp(0, POLL) : POLL
            result = done.pop(timeout: wait)
            if result
              results << result
              next
            end
            if deadline && now >= deadline
              timed_out!(nodes, threads, results, done, stop)
              next
            end
            if threads.none?(&:alive?) && done.empty?
              raise PumpWorkerLost, "#{nodes.size - results.size} of #{nodes.size} pump workers ended " \
                "without a result"
            end
          end
          results
        end

        # Takes the results already sent, logs where each stuck worker is and
        # stops them. Then raises a fatal error a worker reported, else
        # PumpTimeout. Returns (no timeout) when every result was in after all.
        def timed_out!(nodes, threads, results, done, stop)
          drain(done, results)
          reported = results.map(&:first)
          stuck = nodes.each_index.reject { |k| reported.include?(nodes[k]) }
          return if stuck.empty?

          log("pass timed out after #{@pass_timeout} s: #{stuck.size} of #{nodes.size} nodes have no result")
          stuck.each do |k|
            log("node #{TreeMath.label(*nodes[k])} stuck at: #{where(threads[k])}")
          end
          left, storing = stop_workers(stuck.map { |k| threads[k] }, stop)
          if left.positive?
            log("#{left} stuck worker threads did not stop and were left; they start no store")
          end
          if storing.positive?
            log("#{storing} stuck worker threads were still storing a node when the pass was given up")
          end
          drain(done, results) # the stopped workers' results, a fatal error among them
          fatal = results.map(&:last).compact.first
          raise fatal if fatal

          raise PumpTimeout, "a pump pass took longer than #{@pass_timeout} s; " \
            "#{stuck.size} of #{nodes.size} workers were stopped (locations in the log)"
        end

        # file:line:in method for the first FRAMES frames. No values.
        def where(thread)
          frames = thread.backtrace_locations(0, FRAMES)
          return thread.alive? ? "(no frames)" : "(ended)" unless frames

          frames.map { |f| "#{f.path}:#{f.lineno}:in #{f.label}" }.join(" | ")
        end

        def drain(done, results)
          while (result = done.pop(timeout: 0))
            results << result
          end
        end

        # Gives up the pass (no worker starts a store after this), waits up
        # to STOP_WAIT for the stores already running, then kills the threads
        # still alive and waits up to STOP_WAIT for each (Thread#kill runs
        # their ensure blocks: the executor returns the connection and an
        # open transaction rolls back). Returns [threads still alive, stores
        # still running]. Both are 0 unless a thread ignores Thread#kill.
        def stop_workers(threads, stop)
          stop.set!(@stop_wait)
          live = threads.select(&:alive?)
          live.each(&:kill)
          live.each { |thread| thread.join(@stop_wait) }
          [live.count(&:alive?), stop.storing]
        end

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # A logger that raises must not stop the pump or lose a result.
        def log(message)
          return unless @logger

          (@logger.respond_to?(:call) ? @logger.call(message) : @logger.error("[infinite_context] #{message}"))
        rescue
          nil
        end
      end
    end
  end
end
