# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # The compactor's scheduler. Builds every node that is not built, has its
    # sources, and has its whole context summarized (every view line before
    # the node's end is built). Up to JOBS at once; a failed node is retried
    # up to `retries` times.
    module Pump
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

      # Runs passes over the tree until no more nodes can start. Each pass
      # starts up to `jobs` builder threads and waits for them. `builder`
      # must answer build(level, i) and return [text, tries].
      class Runner
        include TreeMath

        # chat_options: for the default Compactor (ignored when `builder:` is given).
        def initialize(tree, builder: nil, jobs: JOBS, retries: 3, logger: nil, chat_options: nil)
          @tree = tree
          @builder = builder ||
            Compactor.new(tree, model: tree.compactor_model, chat_options: chat_options)
          @jobs = jobs
          @retries = retries
          @logger = logger
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
          threads = nodes.map do |node|
            Thread.new do
              ok = false
              # In a Rails app each worker thread runs inside the executor (it
              # returns the thread's database connection when it ends).
              Pump.wrap_thread do
                text, tries = @builder.build(*node)
                @tree.store_node!(*node, text, tries:)
                ok = true
              rescue => e
                log("node #{TreeMath.label(*node)} failed: #{e.class}: #{e.message}")
              end
              done << [node, ok]
            end
          end
          # While this thread waits, the workers may autoload constants. With
          # reloading on (Rails development) that needs the load interlock, so
          # the wait must permit concurrent loads or the pass deadlocks.
          Pump.waiting do
            results = nodes.map { done.pop }
            threads.each(&:join)
            results
          end
        end

        def log(message)
          return unless @logger

          (@logger.respond_to?(:call) ? @logger.call(message) : @logger.error("[infinite_context] #{message}"))
        end
      end
    end
  end
end
