# frozen_string_literal: true

if defined?(ActiveJob::Base)
  module RubyLLM
    module InfiniteContext
      # The pump as an ActiveJob: app enqueue it with `set(wait:)` and it
      # works with any queue backend.
      class PumpJob < ActiveJob::Base
        queue_as :default

        def perform(tree_id)
          tree = Tree.find(tree_id)
          Pump::Runner.new(tree, logger: Rails.logger).run
        end
      end
    end
  end
end
