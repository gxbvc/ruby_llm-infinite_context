# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # The engine: it brings the migration generator into the app and loads
    # the Active Record models on the app's connection. It serves no
    # controllers and isolates nothing.
    class Engine < ::Rails::Engine
      engine_name "ruby_llm_infinite_context"
    end
  end
end
