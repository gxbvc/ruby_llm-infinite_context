# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "concurrent"
require "timeout"
require "active_support/dependencies"

module RubyLLM
  module InfiniteContext
    class PumpTest < Minitest::Test
      def test_under_budget_every_message_is_ready_in_order
        nodes = Pump.ready_nodes(total: 4, first: 4, built: Set.new, busy: Set.new, slots: 10)
        assert_equal [[0, 0], [0, 1], [0, 2], [0, 3]], nodes
      end

      def test_slots_cut_the_list
        nodes = Pump.ready_nodes(total: 8, first: 8, built: Set.new, busy: Set.new, slots: 3)
        assert_equal [[0, 0], [0, 1], [0, 2]], nodes
      end

      def test_a_node_waits_for_its_children_and_its_context
        # first = 4: node (0,4) is ready (compressing one message needs no
        # later context), but the level-1 pairs over entries 4..7 are not:
        # their context (the view line over 4) is not summarized yet.
        nodes = Pump.ready_nodes(total: 8, first: 4,
          built: Set.new([[0, 0], [0, 1], [0, 2], [0, 3]]), busy: Set.new, slots: 10)
        assert_equal [[0, 4], [1, 0], [1, 1]], nodes
      end

      def test_built_and_busy_nodes_are_skipped
        nodes = Pump.ready_nodes(total: 4, first: 4,
          built: Set.new([[0, 0], [0, 1]]), busy: Set.new([[0, 2]]), slots: 10)
        assert_equal [[0, 3], [1, 0]], nodes
      end

      def test_a_level_zero_node_is_ready_only_when_its_entry_is_in_a_built_view_line
        # first = 2: entries 0 and 1 sit under built line 0+2, and entry 2's
        # compression needs no later context. Entry 3 waits for its line.
        nodes = Pump.ready_nodes(total: 4, first: 2, built: Set.new, busy: Set.new, slots: 10)
        assert_equal [[0, 0], [0, 1], [0, 2]], nodes
      end

      def test_runner_builds_nodes_through_the_builder
        tree = Tree.create!(key: "pump-test")
        8.times { |i| tree.append(:user, "message #{i} #{"word " * 100}") }
        # Prebuild every level-0 node, so only merges are left.
        builder = RecordingBuilder.new
        tree.nodes.create!(level: 0, i: 0, text: "a" * 300, bytes: 300, tries: 1, created_at: Time.current)
        runner = Pump::Runner.new(tree, builder:, jobs: 2)

        # Only nodes whose context is summarized get built; with all level-0
        # nodes missing, the runner builds level-0 nodes first.
        tree.nodes.delete_all
        built = runner.run
        assert_operator built, :>, 0
        assert_equal tree.nodes.count, built
        assert(tree.nodes.exists?(level: 1, i: 0))
        assert_equal [], builder.bad_calls
      end

      def test_runner_retries_a_failing_node_then_succeeds
        tree = Tree.create!(key: "pump-retry")
        tree.append(:user, "a" * 600)
        builder = FlakyBuilder.new(fail_first: 2)
        runner = Pump::Runner.new(tree, builder:, jobs: 1, retries: 3)
        assert_equal 1, runner.run
        assert tree.nodes.exists?(level: 0, i: 0)
      end

      # -- Rails app threading: executor and load interlock --------------------
      # Found by bin/install_check: in a Rails app with reloading on, the pump
      # deadlocked because its main thread waited on workers that needed to
      # autoload. Each worker now runs in the executor and the wait permits
      # concurrent loads.

      class RecordingExecutor
        attr_reader :wraps

        def initialize = @wraps = Concurrent::AtomicFixnum.new(0)

        def wrap
          @wraps.increment
          yield
        end
      end

      class RecordingInterlock
        attr_reader :permits

        def initialize = @permits = Concurrent::AtomicFixnum.new(0)

        def permit_concurrent_loads
          @permits.increment
          yield
        end
      end

      # Runs the block with Rails.application returning `app`, whether or not
      # Rails is loaded in this test process (the suite does not need Rails).
      def with_rails_application(app)
        if defined?(::Rails) && ::Rails.respond_to?(:application)
          ::Rails.stub(:application, app) { yield }
        else
          fake = Module.new { class << self; attr_accessor :application; end }
          fake.application = app
          created = !Object.const_defined?(:Rails)
          Object.const_set(:Rails, fake) if created
          begin
            yield
          ensure
            Object.send(:remove_const, :Rails) if created
          end
        end
      end

      def test_wrap_thread_is_plain_without_a_rails_app_and_uses_the_executor_with_one
        assert_equal 7, Pump.wrap_thread { 7 }
        executor = RecordingExecutor.new
        app = Struct.new(:executor).new(executor)
        with_rails_application(app) { assert_equal 8, Pump.wrap_thread { 8 } }
        assert_equal 1, executor.wraps.value
        with_rails_application(nil) { assert_equal 9, Pump.wrap_thread { 9 } } # no app: plain
        assert_equal 1, executor.wraps.value
      end

      def test_waiting_permits_concurrent_loads_through_the_interlock
        interlock = RecordingInterlock.new
        ::ActiveSupport::Dependencies.stub(:interlock, interlock) { assert_equal 9, Pump.waiting { 9 } }
        assert_equal 1, interlock.permits.value
      end

      def test_the_runner_wraps_every_worker_and_waits_with_the_interlock_released
        executor = RecordingExecutor.new
        interlock = RecordingInterlock.new
        app = Struct.new(:executor).new(executor)
        tree = Tree.create!(key: "pump-executor")
        3.times { |i| tree.append(:user, "entry #{i} " + "w" * 600) }
        built = nil
        with_rails_application(app) do
          ::ActiveSupport::Dependencies.stub(:interlock, interlock) do
            built = Pump::Runner.new(tree, builder: RecordingBuilder.new, jobs: 2).run
          end
        end
        assert_operator built, :>, 0
        assert_operator executor.wraps.value, :>=, built, "one executor wrap per node built"
        assert_operator interlock.permits.value, :>=, 1, "every pass waited with loads permitted"
      end

      # Regression, found by bin/install_check: with the Active Record query
      # cache on (as inside a Rails executor), the pump re-read stale node
      # sizes and built the same node forever.
      def test_the_pump_finishes_with_the_query_cache_on_and_leaves_a_fresh_cache
        tree = Tree.create!(key: "pump-query-cache")
        4.times { |i| tree.append(:user, "entry #{i} " + "w" * 600) }
        built = nil
        ActiveRecord::Base.cache do
          Timeout.timeout(30) { built = Pump::Runner.new(tree, builder: RecordingBuilder.new, jobs: 2).run }
          # The caller's next read, on the cached connection, sees what the workers stored.
          assert_equal built, tree.node_sizes.size
          assert_equal built, tree.nodes.count
        end
        assert_operator built, :>=, 4
      end

      # Builds a fixed text for every node; records bad calls.
      class RecordingBuilder
        attr_reader :bad_calls

        def initialize
          @calls = []
          @bad_calls = []
        end

        def build(level, i)
          @calls << [level, i]
          raise "children not built" if level.positive? && level.odd? && i == 10_000

          ["summary of #{TreeMath.label(level, i)}", 1]
        end
      end

      class FlakyBuilder
        def initialize(fail_first:)
          @fail_first = fail_first
          @calls = 0
        end

        def build(level, i)
          @calls += 1
          raise Error, "flaky" if @calls <= @fail_first

          ["recovered after #{@calls} calls", @calls]
        end
      end
    end
  end
end
