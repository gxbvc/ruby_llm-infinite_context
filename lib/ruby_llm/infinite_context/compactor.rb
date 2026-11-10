# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # Builds one node. A source that fits in NODE bytes is the node, with no
    # model call. Otherwise one fresh call on the compactor model, with
    # COMPACT_SYSTEM as instructions and the step text: the size ruler, then
    # the compress or merge step. Over-long replies get the cut-at-limit
    # feedback in the same conversation, up to TRIES; the shortest try wins.
    #
    # The compactor works over a `store` that answers:
    #   entry(idx)     -> object with kind, text (the log entry)
    #   node_text(level, i) -> built node text, or nil
    #   context_before(idx, budget:) -> the view lines covering [0, idx)
    #
    # A tool result (`echo`) is summarized as a pair with the tool call that
    # produced it: the call's text rides along as context. The pair idea is
    # an open question for the benchmark: the alternative, summarizing
    # call and result as one node, is not shipped.
    class Compactor
      include TreeMath

      # The step text for compressing one message. A tool result carries its
      # call as context (the pair). A very large result is stubbed: the
      # model sees head and tail, not the whole output.
      def self.compress_prompt(kind, text, call: nil)
        pieces = []
        if kind == "echo" && call
          pieces << "The tool call that produced this result (context only; the line is about the result):\n#{TreeMath.flat(call)}"
        end
        shown = (TreeMath.bytes(text) > CAP) ? TreeMath.cap(text, CAP) : text
        pieces << ruler
        pieces << "Step: compress this #{kind} message into one line, in at most #{NODE} bytes:\n#{TreeMath.flat(shown)}"
        pieces.join("\n\n")
      end

      # The step text for merging two built lines.
      def self.merge_prompt(a, b)
        "#{ruler}\n\nStep: merge these two lines into one, in at most #{NODE} bytes:\n#{TreeMath.flat(a)}\n#{TreeMath.flat(b)}"
      end

      def self.ruler
        "For scale only: the next ruler is a line of exactly #{NODE} dashes. " \
          "It is a measuring stick, not content. Never copy it or its dashes into a line.\n#{Prompts::RULER}"
      end

      # chat_options: how the compactor's chats are built (provider:,
      # protocol:, assume_model_exists:, context:; see ChatOptions). Defaults
      # to InfiniteContext.compactor_chat_options, read at each call. For
      # Fireworks and other OpenAI-compatible services pass
      # `protocol: :chat_completions`: RubyLLM 2.1.1 defaults to the
      # Responses API for the OpenAI provider.
      def initialize(store, model:, chat_factory: nil, chat_options: nil)
        @store = store
        @model = model
        @chat_options = chat_options && ChatOptions.normalize(chat_options)
        @chat_factory = chat_factory ||
          -> { ChatOptions.build(@model, @chat_options || InfiniteContext.compactor_chat_options) }
      end

      # Returns [text, tries].
      def build(level, i)
        level.zero? ? compress(i) : merge(level, i)
      end

      def compress(i)
        entry = @store.entry(i)
        text = entry.text.to_s
        return [flat(text), 0] if TreeMath.bytes(text) <= NODE

        ask(@store.context_before(i, budget: COMPACT_VIEW_BUDGET),
          self.class.compress_prompt(entry.kind, text, call: @store.paired_call(i)&.text))
      end

      def merge(level, i)
        a = @store.node_text(level - 1, 2 * i) or raise Error, "child #{TreeMath.label(level - 1, 2 * i)} not built"
        b = @store.node_text(level - 1, 2 * i + 1) or raise Error, "child #{TreeMath.label(level - 1, 2 * i + 1)} not built"
        joined = "#{a}\n#{b}"
        return [joined, 0] if TreeMath.bytes(joined) <= NODE

        ask(@store.context_before(TreeMath.last(level, i), budget: COMPACT_VIEW_BUDGET),
          self.class.merge_prompt(a, b))
      end

      private

      def render_context(lines)
        "<chat>\n#{Array(lines).join("\n")}\n</chat>"
      end

      def ask(context, step)
        chat = @chat_factory.call
        chat = chat.with_instructions(Prompts::COMPACT_SYSTEM) if chat.respond_to?(:with_instructions)
        # The view lines so far are staged WITHOUT a request (ask_later): they
        # ride along with the step in the one request that `ask` makes. A
        # plain `ask` here would be a second, wasted, paid request.
        chat.ask_later(render_context(context)) if context && !context.empty?
        reply = chat.ask(step)
        tries = []
        loop do
          line = reply.content.to_s.strip
          raise Error, "compactor returned an empty line" if line.empty?

          tries << line
          break if TreeMath.bytes(line) <= NODE || tries.size >= TRIES

          reply = chat.ask("That line is #{TreeMath.bytes(line)} bytes; the limit is #{NODE}. " \
                           "It must end where it is cut here:\n#{TreeMath.cut(line, NODE)}| <- LIMIT")
        end
        [tries.min_by { |t| TreeMath.bytes(t) }, tries.size]
      end
    end
  end
end
