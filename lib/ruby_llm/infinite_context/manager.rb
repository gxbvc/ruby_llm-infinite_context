# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # Wires one chat to one tree: every turn appends the user's message and
    # the reply to the log, shows the saved view (plus the guide) as
    # instructions, hands the agent the zoom tools, and pumps the compactor
    # when the turn ends.
    #
    #   chat = RubyLLM.chat(model: "claude-sonnet-5-5")
    #   mem = RubyLLM::InfiniteContext.attach(chat, key: "conv-1",
    #                                         compactor: "claude-haiku-4-5",
    #                                         tokens: 20_000)
    #   mem.turn("...")
    #   mem.tree.view_lines(budget: 80_000)
    #   mem.tree.stats.hot_nodes(limit: 10)
    class Manager
      attr_reader :tree, :budget

      # Budget: `budget:` is bytes; `tokens:` converts with the rough 4
      # bytes-per-token estimator. Bytes win when both are given.
      def initialize(tree, budget: nil, tokens: nil, pump: :sync, logger: nil, compactor_options: nil, &chat_factory)
        @tree = tree
        @budget = InfiniteContext.resolve_budget(budget:, tokens:)
        @pump = pump
        @logger = logger
        @compactor_options = compactor_options && ChatOptions.normalize(compactor_options)
        @chat_factory = chat_factory
      end

      # Attaches a chat: `chat` is a factory (a Chat, a lambda returning
      # one, or nil for RubyLLM.chat(model:)). One Chat per turn; the tree
      # is the only memory between turns.
      #
      # chat_options: how a chat is built from a model NAME (provider:,
      # protocol:, assume_model_exists:, context:). compactor_options: the
      # same for the compactor's chats (default:
      # InfiniteContext.compactor_chat_options). RubyLLM 2.1.1 defaults the
      # OpenAI provider to the Responses API; for Fireworks and other
      # OpenAI-compatible services pass `protocol: :chat_completions` in
      # both. A :job pump (ActiveJob) cannot carry per-instance options, so
      # set InfiniteContext.compactor_chat_options at boot for it.
      def self.attach(chat, key:, budget: nil, tokens: nil, compactor: nil, pump: :sync,
        chat_options: nil, compactor_options: nil)
        tree = Tree.for(key, compactor: compactor)
        factory = case chat
        when Proc then chat
        when ->(c) { c.respond_to?(:ask) } then -> { chat }
        else -> { ChatOptions.build(chat, chat_options) }
        end
        new(tree, budget:, tokens:, pump:, compactor_options:, &factory)
      end

      # One turn: log the user's message, ask with the view as instructions,
      # log the reply, pump. A fresh Turn guards and caps the zooms.
      def turn(text)
        tree.append(:user, text)
        turn = Turn.new
        chat = @chat_factory.call
        chat.with_instructions("#{Prompts::VIEW_GUIDE}\n\n#{render_view}")
        chat.with_tools(*Tools.for_turn(tree, turn))
        reply = chat.ask(text)
        if reply.respond_to?(:content) && reply.content
          tree.append(:assistant, reply.content.to_s)
        end
        pump!
        reply
      end

      def render_view
        "<chat>\n#{tree.view_lines(budget).join("\n")}\n</chat>"
      end

      # :sync pumps now; :job uses PumpJob (ActiveJob) when defined, else a
      # thread; :none leaves the pump to the caller.
      def pump!
        case @pump
        when :none then nil
        when :job
          if defined?(PumpJob)
            PumpJob.perform_later(tree.id)
          else
            Thread.new do
              Pump.wrap_thread { Pump::Runner.new(tree, logger: @logger, chat_options: @compactor_options).run }
            end
          end
        else
          Pump::Runner.new(tree, logger: @logger, chat_options: @compactor_options).run
        end
      end
    end
  end
end
