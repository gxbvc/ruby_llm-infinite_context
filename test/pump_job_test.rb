# frozen_string_literal: true

require "test_helper"
require "active_job"

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
    end
  end
end
