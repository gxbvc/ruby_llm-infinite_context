# frozen_string_literal: true

if defined?(ActiveJob::Base)
  module RubyLLM
    module InfiniteContext
      # The pump as an ActiveJob: app enqueue it with `set(wait:)` and it
      # works with any queue backend.
      #
      # No retry_on: an error the Runner raises (PumpTimeout, PumpWorkerLost,
      # ProtocolError, or a worker's NoMemoryError and the like) fails the
      # job once and goes to the queue backend. Do not add an automatic retry
      # for PumpTimeout: a stuck pass usually sticks again.
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
