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
    #
    # A host app can REQUIRE one protocol for every chat the gem builds or
    # uses (see InfiniteContext.required_protocol=). Then a chat with any
    # other protocol, or none, raises ProtocolError before a request.
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
      # With a required protocol, the options are checked BEFORE the chat is
      # built and the built chat is checked after.
      def build(model, options = nil, role: "chat")
        options = normalize(options).dup
        check_option!(options[:protocol], role)
        context = options.delete(:context)
        check!((context || RubyLLM).chat(model: model, **options), role)
      end

      # Raises ProtocolError when a protocol is required and `protocol` is
      # not it. Does nothing when no protocol is required.
      def check_option!(protocol, role)
        required = InfiniteContext.required_protocol
        return if required.nil? || protocol.to_s == required.to_s

        raise ProtocolError, "the #{role} options name protocol #{protocol.inspect}, but " \
          "RubyLLM::InfiniteContext.required_protocol is #{required.inspect}; pass protocol: #{required.inspect}"
      end

      # Checks a chat the gem is about to use. Returns the chat. When a
      # protocol is required, the chat must use it (none is a failure), and
      # every fallback model must stay on the chat's provider (RubyLLM drops
      # the protocol when a fallback moves to another provider). A chat whose
      # protocol cannot be read fails too.
      #
      # An acts_as_chat record sends through its memoized `to_llm` chat, not
      # through its `protocol` attribute, so for a record the `to_llm` chat
      # is the one checked.
      def check!(chat, role)
        required = InfiniteContext.required_protocol
        return chat if required.nil?

        sender = chat.respond_to?(:to_llm) ? chat.to_llm : chat
        actual = protocol_of(sender, role)
        unless actual.to_s == required.to_s
          raise ProtocolError, "the #{role} chat uses protocol #{actual.inspect}, but " \
            "RubyLLM::InfiniteContext.required_protocol is #{required.inspect}; build it with protocol: #{required.inspect}"
        end
        check_fallbacks!(sender, role)
        chat
      end

      def protocol_of(chat, role)
        if defined?(RubyLLM::Chat) && chat.is_a?(RubyLLM::Chat)
          chat.respond_to?(:protocol) ? chat.protocol : chat.instance_variable_get(:@protocol)
        elsif chat.respond_to?(:protocol)
          chat.protocol
        else
          raise ProtocolError, "cannot read the protocol of the #{role} chat (#{chat.class}), " \
            "and RubyLLM::InfiniteContext.required_protocol is set"
        end
      end

      def check_fallbacks!(chat, role)
        fallbacks = chat.respond_to?(:fallbacks) ? Array(chat.fallbacks) : []
        return if fallbacks.empty?

        slug = (chat.respond_to?(:provider) && chat.provider.respond_to?(:slug)) ? chat.provider.slug.to_s : nil
        fallbacks.each do |fallback|
          provider = fallback.respond_to?(:provider) ? fallback.provider&.to_s : nil
          next if slug && provider == slug

          raise ProtocolError, "the #{role} chat has a fallback (#{fallback.respond_to?(:id) ? fallback.id : fallback}) " \
            "that does not name the chat's provider #{slug.inspect}; with required_protocol set, every fallback " \
            "must be a RubyLLM::Model on the same provider"
        end
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

      # The protocol every chat the gem builds or uses must have, or nil (the
      # default: no rule). Set it once at boot:
      #
      #   RubyLLM::InfiniteContext.required_protocol = :chat_completions
      #
      # Then the compactor (pump, PumpJob), BatchImport and every turn of a
      # Manager (attach, the Model concern) raise ProtocolError when their
      # chat has another protocol or none, before any request is sent.
      attr_reader :required_protocol

      def required_protocol=(protocol)
        @required_protocol = protocol&.to_sym
      end

      # Attaches a chat to a memory tree; see Manager.attach.
      def attach(...) = Manager.attach(...)
    end
  end
end
