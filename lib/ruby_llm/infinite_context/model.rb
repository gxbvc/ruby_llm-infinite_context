# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # Rails-model sugar, next to `acts_as_chat` (ruby_llm-rails):
    #
    #   class Conversation < ApplicationRecord
    #     acts_as_chat
    #     include RubyLLM::InfiniteContext::Model
    #     has_infinite_context compactor: "claude-haiku-4-5"
    #   end
    #
    #   memory = conversation.with_infinite_context(tokens: 20_000)
    #   memory.turn("...")
    #
    # The tree key is "<Model>:<id>", so each record owns one memory tree.
    #
    # The record names the model: each turn builds a FRESH RubyLLM chat from
    # the record's model_id, provider, protocol, assume_model_exists and
    # context (the attributes acts_as_chat gives it), because the tree, not
    # the record's message history, is the memory between turns. Set
    # `conversation.protocol = :chat_completions` (and `provider`, `context`)
    # for an OpenAI-compatible service like Fireworks. The compactor takes
    # `compactor_options:` (see ChatOptions).
    module Model
      def self.included(base)
        base.extend ClassMethods
      end

      # The RubyLLM.chat options a record's acts_as_chat attributes imply.
      def self.chat_options_for(record)
        {
          provider: record.provider&.to_sym,
          protocol: record.protocol,
          assume_model_exists: record.assume_model_exists,
          context: record.context
        }.compact
      end

      module ClassMethods
        def has_infinite_context(compactor: nil, compactor_options: nil)
          @infinite_context_options = {compactor: compactor, compactor_options: compactor_options}
        end

        def infinite_context_options
          @infinite_context_options if instance_variable_defined?(:@infinite_context_options)
        end
      end

      def with_infinite_context(budget: nil, tokens: nil)
        options = self.class.infinite_context_options
        raise Error, "call has_infinite_context first" unless options

        unless respond_to?(:to_llm) && respond_to?(:model_id)
          raise Error, "with_infinite_context needs acts_as_chat (no #to_llm or #model_id)"
        end
        raise Error, "the record has no model_id yet" if model_id.to_s.empty?

        record = self
        factory = -> { ChatOptions.build(record.model_id, Model.chat_options_for(record), role: "record") }
        Manager.attach(factory, key: "#{self.class.name}:#{id}", budget:, tokens:,
          compactor: options[:compactor], compactor_options: options[:compactor_options])
      end
    end
  end
end
