# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # How to send the view so that consecutive turns read it from the
    # provider's prompt cache. Only providers that accept explicit cache
    # breakpoints use this (Anthropic); others rely on implicit prefix
    # caching, and some (OpenAI) reject explicit breakpoints outright.
    #
    # A cache entry matches on the exact block layout, so:
    # - The view goes as blocks of GRID parts each (a fixed grid by part
    #   index). Where two views agree, their blocks are byte-identical.
    # - The mark goes on the last grid cut inside the part of the view that
    #   the next messages will not change. The fold is deterministic, so we
    #   run it HORIZON messages ahead (with lines of a typical size) and
    #   stop before the first part it would merge. Under budget that is the
    #   whole view.
    class CacheMark
      GRID = 8
      HORIZON = 8 # messages ahead: about two turns

      # cuts: part indexes where blocks end (the last block runs to the end);
      # mark: the cut whose block gets the cache mark, or nil.
      Plan = Data.define(:cuts, :mark)

      # parts: the view's parts; sizes: [level, i] => bytes of built nodes;
      # previous_mark: the parts prefix the previous turn marked.
      def self.plan(parts:, total:, sizes:, previous_mark: [], budget: DEFAULT_VIEW_BUDGET, horizon: HORIZON, grid: GRID, recall: nil)
        cuts = (grid...parts.size).step(grid).to_a
        stable = stable_prefix(parts, total, sizes, budget, horizon, recall)
        mark = cuts.select { |c| c <= stable }.max
        kept = previous_mark.size
        mark = kept if kept.positive? && cuts.include?(kept) && (mark.nil? || kept > mark) && parts.first(kept) == previous_mark
        Plan.new(cuts:, mark:)
      end

      # How many leading parts stay the same after `horizon` more messages.
      def self.stable_prefix(parts, total, sizes, budget, horizon, recall = nil)
        return 0 if parts.empty?

        typical = typical_line(parts, sizes)
        guess = lambda do |l, i|
          next sizes[[l, i]] if sizes.key?([l, i])
          next typical if l.zero? && i >= total # a message that does not exist yet

          a = sizes[[l - 1, 2 * i]]
          b = sizes[[l - 1, 2 * i + 1]]
          [a + b, NODE].min if a && b # a parent the pump will build soon
        end
        fold = Fold.new(parts:, budget:, recall:, &guess)
        horizon.times { |h| fold.append(total + h).fit(total + h + 1) }
        parts.zip(fold.parts).take_while { |a, b| a == b }.size
      end

      def self.typical_line(parts, sizes)
        recent = parts.last(50).filter_map { |l, i| sizes[[l, i]] if l.zero? }
        recent.empty? ? NODE / 2 : recent.sum / recent.size
      end

      Block = Data.define(:text, :mark)

      # The blocks for a Tree::Shown (Tree#shown_view): the plan uses the
      # parts of the lines shown, not the saved view's. When lines were left
      # out, the leading line changes as more go, so no block gets a mark
      # (all blocks are still sent, in order).
      def self.shown_blocks(shown, total:, sizes:, previous_mark: [], budget: DEFAULT_VIEW_BUDGET, **options)
        return blocks(shown.lines, Plan.new(cuts: [], mark: nil)) if shown.left_out.positive?

        blocks(shown.lines, plan(parts: shown.parts, total:, sizes:, previous_mark:, budget:, **options))
      end

      # The view as text blocks: "<chat>\n" opens the first block, every line
      # ends with "\n", and "</chat>" is a block of its own, so the text of a
      # block never depends on where the view ends.
      def self.blocks(lines, plan)
        bounds = [0, *plan.cuts, lines.size].uniq
        pieces = bounds.each_cons(2).map do |a, b|
          text = lines[a...b].map { |l| "#{l}\n" }.join
          Block.new(text: a.zero? ? "<chat>\n#{text}" : text, mark: b == plan.mark)
        end
        pieces = [Block.new(text: "<chat>\n", mark: false)] if pieces.empty?
        [*pieces, Block.new(text: "</chat>", mark: false)]
      end
    end
  end
end
