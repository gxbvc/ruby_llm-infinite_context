# frozen_string_literal: true

# Active Record models for the memory tables. Required lazily, so the core
# (fold, zoom, compactor) works without Rails.
require "active_record"

module RubyLLM
  module InfiniteContext
    class Tree < ::ActiveRecord::Base
      self.table_name = "ric_trees"

      has_many :entries, class_name: "RubyLLM::InfiniteContext::Entry", dependent: :delete_all
      has_many :nodes, class_name: "RubyLLM::InfiniteContext::Node", dependent: :delete_all
      has_many :views, class_name: "RubyLLM::InfiniteContext::View", dependent: :delete_all
      has_many :zoom_events, class_name: "RubyLLM::InfiniteContext::ZoomEvent", dependent: :delete_all

      validates :key, presence: true, uniqueness: true

      # Finds the tree for `key`, creating it. `compactor:` names the model
      # the compactor calls.
      def self.for(key, compactor: nil)
        tree = find_or_create_by!(key: key.to_s) { |t| t.compactor_model = compactor }
        tree.update!(compactor_model: compactor) if compactor && tree.compactor_model != compactor
        tree
      end

      # Serializes view and pump work on this tree with a row lock (works on
      # SQLite and Postgres).
      def with_view_lock
        transaction do
          self.class.lock.find(id)
          yield
        end
      end

      # -- the log ---------------------------------------------------------

      # Appends one entry. Kind is one of KINDS; bytes is the UTF-8 size.
      def append(kind, text)
        kind = kind.to_s
        raise ArgumentError, "unknown kind #{kind}" unless KINDS.include?(kind)

        entries.create!(idx: entry_count, kind:, text: text.to_s, bytes: TreeMath.bytes(text))
      end

      def entry_count = entries.count

      def entry(idx) = entries.find_by(idx: idx)

      # The tool call paired with the result at idx, or nil.
      def paired_call(idx) = entry(idx)&.paired_call

      # -- the summary tree ------------------------------------------------

      def node_text(level, i) = nodes.find_by(level:, i:)&.text

      # The texts of every built node, as { [level, i] => bytes }.
      def node_sizes = nodes.pluck(:level, :i, :bytes).to_h { |l, i, b| [[l, i], b] }

      def store_node!(level, i, text, tries: 0)
        node = nodes.find_or_initialize_by(level:, i:)
        node.assign_attributes(text:, bytes: TreeMath.bytes(text), tries:)
        node.save!
        node
      end

      # -- saved views, one per budget -------------------------------------

      # The saved view for `budget`, folded forward over entries that arrived
      # after it was last saved. Never rebuilt from the log.
      def view(budget = DEFAULT_VIEW_BUDGET)
        record = views.find_by(budget: budget) || views.create!(budget:, parts: [], message_count: 0)
        if record.message_count < entry_count
          sizes = node_sizes
          fold = Fold.new(parts: record.parts, budget: budget) { |l, i| sizes[[l, i]] }
          record.message_count.upto(entry_count - 1) do |i|
            fold.append(i)
            fold.fit(i + 1)
          end
          record.update!(parts: fold.parts, message_count: entry_count)
        end
        record
      end

      # The view's rendered lines, oldest first: "id+n|text". A short entry
      # is its own line, word for word; a long one shows its compressed node
      # or the placeholder until the pump builds it.
      def view_lines(budget = DEFAULT_VIEW_BUDGET)
        record = view(budget)
        record.parts.map do |l, i|
          text = line_text(l, i)
          "#{TreeMath.label(l, i)}|#{TreeMath.flat(text)}"
        end
      end

      # The summary lines covering entries [0, idx): the context the
      # compactor reads before it builds a node.
      def context_before(idx, budget: COMPACT_VIEW_BUDGET)
        record = view(budget)
        record.parts.filter_map do |l, i|
          next if TreeMath.last(l, i) > idx

          "#{TreeMath.label(l, i)}|#{TreeMath.flat(line_text(l, i))}"
        end
      end

      # -- counters and zoom events ----------------------------------------

      def record_zoom!(level:, i:, leaf_idx:, steps:, session:)
        zoom_events.create!(level:, i:, leaf_idx:, steps:, session:)
        node = nodes.find_by(level:, i:)
        return unless node

        node.update!(dig_count: node.dig_count + 1, last_dug_at: Time.current)
      end

      def stats
        Stats.new(self)
      end

      # Small read-only summaries for dashboards and the bench.
      class Stats
        def initialize(tree) = @tree = tree

        # The most opened nodes.
        def hot_nodes(limit: 10)
          @tree.nodes.order(dig_count: :desc, last_dug_at: :desc).where(dig_count: 1..).limit(limit)
        end

        def zoom_events = @tree.zoom_events

        def node_count = @tree.nodes.count

        def entry_count = @tree.entry_count
      end

      private

      # The text a view line shows for part (l, i).
      def line_text(l, i)
        if l.zero?
          entry = entry(i)
          return TreeMath.flat(entry.text) if entry && entry.bytes <= NODE
        end

        node_text(l, i) || PLACEHOLDER
      end
    end

    class Entry < ::ActiveRecord::Base
      self.table_name = "ric_entries"

      belongs_to :tree, class_name: "RubyLLM::InfiniteContext::Tree"

      # The tool call that produced this result, when kind is "echo" and the
      # call is the entry right before. Returns nil for other kinds.
      def paired_call
        return nil unless kind == "echo"

        call = Tree.find(tree_id).entry(idx - 1)
        call if call && call.kind == "tool"
      end
    end

    class Node < ::ActiveRecord::Base
      self.table_name = "ric_nodes"

      belongs_to :tree, class_name: "RubyLLM::InfiniteContext::Tree"
    end

    class View < ::ActiveRecord::Base
      self.table_name = "ric_views"

      belongs_to :tree, class_name: "RubyLLM::InfiniteContext::Tree"
    end

    class ZoomEvent < ::ActiveRecord::Base
      self.table_name = "ric_zoom_events"

      belongs_to :tree, class_name: "RubyLLM::InfiniteContext::Tree"
    end

    # encrypt_text may have been set before this file loaded.
    Encryption.apply!
  end
end
