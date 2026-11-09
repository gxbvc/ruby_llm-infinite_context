# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # The view (the sawtooth): a list of parts [level, i] that tiles the log
    # [0, T), oldest first. It only appends at the end and merges the most
    # due adjacent pair whose parent is built; it never splits. Older
    # stretches therefore sit in coarser and coarser lines, which gives the
    # view its sawtooth shape.
    #
    # `size_of.call(level, i)` returns the bytes of a built node's text, or
    # nil when the node is not built. An unbuilt part counts its placeholder.
    #
    # `recall` (optional) slows the aging of stretches that were zoomed into,
    # by dividing the pair's due score. Ships unused: no Recall policy yet.
    class Fold
      include TreeMath

      attr_reader :parts

      def initialize(parts: [], budget: DEFAULT_VIEW_BUDGET, recall: nil, &size_of)
        @parts = parts.map { |l, i| [l, i] }
        @budget = budget
        @recall = recall unless recall && recall.empty?
        @size_of = size_of
      end

      # At load: fold again from message 0 (append + fit for every message).
      def self.from_scratch(total, budget: DEFAULT_VIEW_BUDGET, recall: nil, &size_of)
        fold = new(budget:, recall:, &size_of)
        total.times do |i|
          fold.append(i)
          fold.fit(i + 1)
        end
        fold
      end

      def append(i)
        @parts << [0, i]
        self
      end

      def size = @parts.sum { |l, i| bytes(l, i) }

      def fit(total)
        size = self.size
        while size > @budget
          best = nil
          best_due = nil
          @parts.each_cons(2).with_index do |(a, b), k|
            next unless a[0] == b[0] && a[1].even? && b[1] == a[1] + 1 && built?(a[0] + 1, a[1] / 2)

            due = Rational(total - TreeMath.first(*a), 1 << (a[0] + 2)) # age rule
            due /= @recall.slowdown(TreeMath.first(*a), TreeMath.last(*b), total) if @recall
            if best.nil? || due > best_due
              best = k
              best_due = due
            end
          end
          break unless best # wait until a parent is built

          a, b = @parts[best], @parts[best + 1]
          parent = [a[0] + 1, a[1] / 2]
          size += bytes(*parent) - bytes(*a) - bytes(*b)
          @parts[best, 2] = [parent]
        end
        self
      end

      # First message whose view line is unbuilt.
      def first_unbuilt(total)
        part = @parts.find { |l, i| !built?(l, i) }
        part ? TreeMath.first(*part) : total
      end

      private

      def built?(l, i) = !@size_of.call(l, i).nil?

      def bytes(l, i) = @size_of.call(l, i) || PLACEHOLDER.bytesize
    end
  end
end
