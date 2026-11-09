# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # How the gem builds the chats it creates itself: the compactor's chats
    # (the pump, BatchImport) and a chat that `attach` builds from a model
    # name. The options are the ones RubyLLM.chat takes for picking the wire:
    #
    #   provider:             :openai
    #   protocol:             :chat_completions
    #   assume_model_exists:  true
    #   context:              a RubyLLM context (its own keys and base URL)
    #
    # RubyLLM 2.1.1 sends an OpenAI-provider chat to the Responses API
    # (POST {base}/responses) by default. Fireworks and most other
    # OpenAI-compatible services only offer chat completions, so pass
    # `protocol: :chat_completions` for them. See the README.
    module ChatOptions
      KEYS = %i[provider protocol assume_model_exists context].freeze

      module_function

      # Returns a frozen copy of `options` with symbol keys. Unknown keys raise
      # (a typo such as `protcol:` would silently pick the wrong API).
      def normalize(options)
        options = (options || {}).to_h.transform_keys(&:to_sym)
        unknown = options.keys - KEYS
        unless unknown.empty?
          raise ArgumentError, "unknown chat option(s) #{unknown.inspect}; known: #{KEYS.inspect}"
        end

        options.freeze
      end

      # RubyLLM.chat (or context.chat) with the options passed through.
      def build(model, options = nil)
        options = normalize(options).dup
        context = options.delete(:context)
        (context || RubyLLM).chat(model: model, **options)
      end
    end

    class << self
      # Default options for the compactor's chats when a Compactor,
      # BatchImport or the pump is built without its own `chat_options:`.
      # The pump's default builder and PumpJob (ActiveJob) have nowhere else
      # to read them from, so set this once at boot for those paths:
      #
      #   RubyLLM::InfiniteContext.compactor_chat_options =
      #     {provider: :openai, protocol: :chat_completions, assume_model_exists: true}
      def compactor_chat_options = @compactor_chat_options ||= {}.freeze

      def compactor_chat_options=(options)
        @compactor_chat_options = ChatOptions.normalize(options)
      end

      # Attaches a chat to a memory tree; see Manager.attach.
      def attach(...) = Manager.attach(...)
    end
  end
end
