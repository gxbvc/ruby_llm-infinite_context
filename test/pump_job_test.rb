# frozen_string_literal: true

require "test_helper"
require "active_job"
require "minitest/mock"

# Define PumpJob now: at gem load time ActiveJob was not loaded, so the
# class was skipped.
load File.expand_path("../lib/ruby_llm/infinite_context/pump_job.rb", __dir__)

module RubyLLM
  module InfiniteContext
    class PumpJobTest < Minitest::Test
      def test_manager_pump_job_hands_the_tree_id_to_the_queue
        tree = Tree.create!(key: "pump-job-test")
        enqueued = []
        PumpJob.singleton_class.send(:define_method, :perform_later) { |*args| enqueued << args }

        Manager.new(tree, pump: :job).pump!

        assert_equal [[tree.id]], enqueued
      ensure
        PumpJob.singleton_class.send(:remove_method, :perform_later)
      end

      def test_pump_job_perform_runs_the_runner
        tree = Tree.create!(key: "pump-job-perform")
        tree.append(:user, "long " * 400)
        builder = Object.new
        builder.define_singleton_method(:build) { |level, i| ["node #{i}", 1] }
        # The job builds its own Runner; run it against a stub builder by
        # calling the pieces the job calls.
        count = Pump::Runner.new(tree, builder:, jobs: 1).run
        assert_equal 1, count
        assert tree.nodes.exists?(level: 0, i: 0)
      end

      # A stopped pump fails the job once: the error reaches the queue
      # backend, and the job has no retry of its own.
      def test_pump_job_raises_the_runners_error_and_does_not_retry
        tree = Tree.create!(key: "pump-job-timeout")
        stopped = Object.new
        stopped.define_singleton_method(:run) { raise PumpTimeout, "stuck" }
        logger = Object.new
        logger.define_singleton_method(:error) { |*| nil }
        rails = Module.new { class << self; attr_accessor :logger; end }
        rails.logger = logger
        created = !Object.const_defined?(:Rails)
        Object.const_set(:Rails, rails) if created
        Pump::Runner.stub(:new, stopped) do
          assert_raises(PumpTimeout) { PumpJob.new.perform(tree.id) }
        end
        assert_empty PumpJob.rescue_handlers
      ensure
        Object.send(:remove_const, :Rails) if created
      end
    end
  end
end
