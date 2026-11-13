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
      # after it was last saved, then fitted again against the current line
      # sizes (lines grow when the pump builds the nodes behind them). Never
      # rebuilt from the log: the fit only merges, so the saved lines stay
      # stable. Saved only when it changed, under the tree's row lock, from
      # the row as it is then (a reader with older sizes cannot undo a
      # newer reader's merges).
      def view(budget = DEFAULT_VIEW_BUDGET) = view_and_sizes(budget).first

      # The lines the agent is shown, as a Shown: `lines` (the stub line
      # first when lines were left out), `parts` (the parts of the other
      # lines, in order; use these, not the saved view's, for CacheMark) and
      # `left_out` (how many lines were left out).
      Shown = Data.define(:lines, :parts, :left_out)

      # The lines inside <chat> tags (InfiniteContext.render_view) never
      # pass `budget` bytes (at least MIN_VIEW_BUDGET):
      # - While parents are pending, the saved view can stay over budget.
      #   The lines shown then merge the most due pairs anyway, and a merged
      #   line shows the placeholder until its node is built. This is not
      #   saved.
      # - If that is not enough, the oldest lines are left out behind one
      #   short line, and `logger` gets the counts (no text).
      def shown_view(budget = DEFAULT_VIEW_BUDGET, logger: nil)
        InfiniteContext.check_view_budget!(budget)
        record, sizes = view_and_sizes(budget)
        total = record.message_count
        parts = Fold.new(parts: record.parts, budget: budget, &sizes).fit(total, force: true).parts
        within_budget(parts, total, budget, logger, hint: true)
      end

      # The view's rendered lines, oldest first: "id+n|text". A short entry
      # is its own line, word for word; a long one shows its compressed node
      # or the placeholder until the pump builds it. Within `budget` bytes
      # inside <chat> tags: see shown_view.
      def view_lines(budget = DEFAULT_VIEW_BUDGET, logger: nil) = shown_view(budget, logger:).lines

      # The summary lines covering entries [0, idx): the context the
      # compactor reads before it builds a node. The lines of the saved view
      # (no forced merge: the compactor never reads a placeholder for a
      # stretch the pump has not built), within `budget` bytes: if they
      # pass it while parents are pending, the oldest are left out.
      def context_before(idx, budget: COMPACT_VIEW_BUDGET)
        InfiniteContext.check_view_budget!(budget)
        parts = view(budget).parts.select { |l, i| TreeMath.last(l, i) <= idx }
        within_budget(parts, parts.empty? ? 0 : TreeMath.last(*parts.last), budget, nil, hint: false).lines
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

      # [saved view record, sizes] for `budget` (see #view). `sizes` is the
      # size snapshot the fit used, for the caller's own fold.
      def view_and_sizes(budget)
        record = views.find_by(budget: budget)
        if record
          total = entry_count
          sizes = line_sizes(record.parts, record.message_count, total)
          parts = refit(record, budget, total, sizes)
          return [record, sizes] if total == record.message_count && parts == record.parts
        end
        with_view_lock do
          record = views.find_by(budget: budget) || views.create!(budget:, parts: [], message_count: 0)
          total = entry_count
          sizes = line_sizes(record.parts, record.message_count, total)
          parts = refit(record, budget, total, sizes)
          record.update!(parts:, message_count: total) if total != record.message_count || parts != record.parts
          [record, sizes]
        end
      end

      # The saved parts, folded forward to `total` entries and fitted again.
      def refit(record, budget, total, sizes)
        fold = Fold.new(parts: record.parts, budget: budget, &sizes)
        record.message_count.upto(total - 1) do |i|
          fold.append(i)
          fold.fit(i + 1)
        end
        fold.fit(total).parts
      end

      # The size of the text each view line shows (see line_text), or nil
      # when the part is not built. A short entry is its own line, built or
      # not.
      #
      # Reads only the nodes a fit of `parts` (covering `upto` entries, then
      # entries up to `total`) can show or merge into: a merge at level l
      # only joins parts of level l or lower, so at level l only nodes from
      # the first part of level l or lower onward matter. In a sawtooth view
      # that is the recent end, so the cost does not grow with the log.
      def line_sizes(parts, upto, total)
        top = 0
        top += 1 while (2 << top) <= total
        starts = (0..top).map do |l|
          part = parts.find { |pl, _| pl <= l }
          (part ? TreeMath.first(*part) : upto) >> l
        end
        scope = starts.each_with_index.map { |from, l| nodes.where(level: l, i: from..) }.reduce { |a, b| a.or(b) }
        sizes = scope.pluck(:level, :i, :bytes).to_h { |l, i, b| [[l, i], b] }
        short = entries.where(idx: starts[0].., bytes: ..NODE).pluck(:idx, :bytes).to_h
        ->(l, i) { (l.zero? && short[i]) || sizes[[l, i]] }
      end

      def line_for(l, i) = "#{TreeMath.label(l, i)}|#{TreeMath.flat(line_text(l, i))}"

      # The last guard: renders `parts` (covering entries [0, total)) and, if
      # the lines pass the budget inside <chat> tags, leaves out the oldest
      # behind one short line. Returns a Shown.
      def within_budget(parts, total, budget, logger, hint:)
        lines = parts.map { |l, i| line_for(l, i) }
        rendered = InfiniteContext.render_view(lines).bytesize
        return Shown.new(lines:, parts:, left_out: 0) if rendered <= budget

        # Rendered size of [stub, *lines[k..]]: "<chat>\n" + lines joined
        # with "\n" + "\n</chat>" is 14 bytes plus each line plus one.
        rest = lines.sum(&:bytesize) + lines.size
        shown = nil
        lines.each_index do |k|
          rest -= lines[k].bytesize + 1
          upto = (k + 1 < parts.size) ? TreeMath.first(*parts[k + 1]) : total
          stub = omitted_line(upto, hint)
          next unless 14 + stub.bytesize + 1 + rest <= budget

          shown = Shown.new(lines: [stub, *lines[(k + 1)..]], parts: parts[(k + 1)..], left_out: k + 1)
          break
        end
        # MIN_VIEW_BUDGET always holds the stub alone, so `shown` is set.
        log_view(logger, "view over budget by #{rendered - budget} bytes: left out the " \
          "#{shown.left_out} oldest of #{lines.size} lines")
        shown
      end

      # The line that stands for the lines left out. It has no "id+n|"
      # label, so it cannot be taken for a summary or zoomed as one.
      def omitted_line(upto, hint)
        "(messages 0 to #{upto - 1} are left out here to fit the view#{"; zoom(id, 1) still opens any of them" if hint})"
      end

      def log_view(logger, message)
        return unless logger

        logger.respond_to?(:call) ? logger.call(message) : logger.warn("[infinite_context] #{message}")
      rescue
        nil
      end

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
