# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # Bulk import: compress an existing long thread with RubyLLM::Batch.
    # Appends the thread to the log, then submits one batched request per
    # node that needs a model call (long entries and merges).
    #
    #   messages = existing_thread.map { |m| { role: m.role, content: m.content } }
    #   submission = RubyLLM::InfiniteContext::BatchImport.new(tree).submit(messages)
    #   submission.id    # persist this
    #   ...
    #   batch = RubyLLM::Batch.find(submission.id, provider: submission.provider)
    #   importer.collect!(submission, batch) if batch.refresh.complete?
    class BatchImport
      include TreeMath

      # nodes: the [level, i] pairs in the batch; id: the provider batch id;
      # provider: the provider name, for RubyLLM::Batch.find.
      Submission = Data.define(:nodes, :id, :provider)

      # chat_options: see Compactor (provider:, protocol:, ...).
      def initialize(tree, model: nil, chat_factory: nil, batch_class: nil, chat_options: nil)
        @tree = tree
        @model = model || tree.compactor_model
        @chat_options = chat_options && ChatOptions.normalize(chat_options)
        @chat_factory = chat_factory
        @batch_class = batch_class || (RubyLLM::Batch if defined?(RubyLLM::Batch))
      end

      # Appends `messages` (role/content pairs) to the log and submits the
      # ready nodes as one batch. Returns nil when nothing needs a model
      # call. When RubyLLM::Batch is unavailable, use Pump::Runner instead.
      #
      # With InfiniteContext.required_protocol set, raises ProtocolError
      # before it logs or sends anything: a provider batch job is not a chat
      # completions call.
      def submit(messages)
        refuse_batch_under_required_protocol!
        import_messages(messages)
        chats = []
        nodes = []
        batchable_nodes.each do |level, i|
          prompt = prompt_for(level, i)
          next unless prompt

          chat = new_chat
          chat.ask_later(prompt)
          chats << chat
          nodes << [level, i]
        end
        return nil if chats.empty?

        raise Error, "RubyLLM::Batch is not available" unless @batch_class

        batch = @batch_class.submit(chats)
        Submission.new(nodes:, id: batch.id, provider: provider_name(batch))
      end

      # Stores the batch's answers on their nodes. Validates the whole batch
      # FIRST: a missing, empty or short result fails the whole collect and
      # stores nothing, so a partial batch never half-populates the tree.
      def collect!(submission, batch)
        refuse_batch_under_required_protocol!
        raise Error, "batch is not complete (#{batch.status})" unless batch.complete?

        messages = batch.messages
        problems = []
        if messages.size != submission.nodes.size
          problems << "expected #{submission.nodes.size} results, got #{messages.size}"
        end
        messages.zip(submission.nodes).each_with_index do |(message, node), i|
          text = message&.content.to_s.strip
          problems << "result #{i} for node #{TreeMath.label(*node)} is missing or empty" if text.empty?
        end
        return 0 if submission.nodes.empty?
        raise Error, "batch results incomplete, nothing stored: #{problems.join("; ")}" unless problems.empty?

        stored = 0
        messages.zip(submission.nodes).each do |message, node|
          @tree.store_node!(node[0], node[1], message.content.to_s.strip, tries: 1)
          stored += 1
        end
        stored
      end

      private

      def refuse_batch_under_required_protocol!
        required = InfiniteContext.required_protocol
        return if required.nil?

        raise ProtocolError, "BatchImport uses provider batch jobs (RubyLLM::Batch), which are not " \
          "#{required.inspect} calls, and RubyLLM::InfiniteContext.required_protocol is #{required.inspect}. " \
          "Load the thread with tree.append for each message, then Pump::Runner.new(tree).run."
      end

      def import_messages(messages)
        messages.each do |m|
          role = (m[:role] || m["role"] || :user).to_s
          kind = if role == "assistant"
            :assistant
          else
            (if role == "tool"
               :echo
             else
               ((role == "tool_call") ? :tool : role)
             end)
          end
          kind = :user unless KINDS.include?(kind.to_s)
          @tree.append(kind, (m[:content] || m["content"]).to_s)
        end
      end

      def total = @tree.entry_count

      # The nodes that can be batched now: long level-0 entries, then merges
      # whose children are built. Unlike the pump's rule, a level-0 node does
      # not wait for the lines before it: in a batch its context is
      # best-effort. Call `submit` again after `collect!` for the next wave.
      def batchable_nodes
        total = @tree.entry_count
        sizes = @tree.node_sizes
        out = []
        total.times do |i|
          out << [0, i] if !sizes.key?([0, i]) && TreeMath.bytes(@tree.entry(i).text) > NODE
        end
        l = 1
        while (1 << l) <= total
          (0...(total >> l)).each do |i|
            next if sizes.key?([l, i])
            next unless sizes.key?([l - 1, 2 * i]) && sizes.key?([l - 1, 2 * i + 1])

            joined = "#{@tree.node_text(l - 1, 2 * i)}\n#{@tree.node_text(l - 1, 2 * i + 1)}"
            out << [l, i] if TreeMath.bytes(joined) > NODE
          end
          l += 1
        end
        out
      end

      # The batched prompt for one node, or nil when no model call is needed
      # (a short entry is its own node; a joined pair under NODE is a node).
      def prompt_for(level, i)
        if level.zero?
          entry = @tree.entry(i)
          return nil if TreeMath.bytes(entry.text) <= NODE

          Compactor.compress_prompt(entry.kind, entry.text, call: @tree.paired_call(i)&.text)
        else
          a = @tree.node_text(level - 1, 2 * i)
          b = @tree.node_text(level - 1, 2 * i + 1)
          return nil unless a && b

          joined = "#{a}\n#{b}"
          return nil if TreeMath.bytes(joined) <= NODE

          Compactor.merge_prompt(a, b)
        end
      end

      def new_chat
        chat = if @chat_factory
          @chat_factory.call
        else
          ChatOptions.build(@model, @chat_options || InfiniteContext.compactor_chat_options, role: "batch import")
        end
        ChatOptions.check!(chat, "batch import").with_instructions(Prompts::COMPACT_SYSTEM)
      end

      def provider_name(batch)
        batch.provider&.respond_to?(:slug) ? batch.provider.slug : nil
      rescue
        nil
      end
    end
  end
end
