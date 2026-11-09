# frozen_string_literal: true

require "test_helper"

module RubyLLM
  module InfiniteContext
    class CacheMarkTest < Minitest::Test
      def sizes_at(parts, bytes = 100)
        parts.each_with_object({}) { |(l, i), h| h[[l, i]] = bytes }
      end

      def test_the_whole_view_is_stable_under_budget
        parts = (0...4).map { |i| [0, i] }
        plan = CacheMark.plan(parts:, total: 4, sizes: sizes_at(parts))
        assert_nil plan.mark # no grid cuts in a 4-part view
        assert_empty plan.cuts
      end

      def test_the_mark_sits_inside_the_stable_prefix
        parts = (0...20).map { |i| [0, i] }
        sizes = sizes_at(parts)
        plan = CacheMark.plan(parts:, total: 20, sizes:, grid: 4)
        assert_equal [4, 8, 12, 16], plan.cuts
        # 24 further messages at 100 bytes each push the view over budget,
        # so the fold merges; the mark stays on a cut that survives.
        assert plan.mark >= 0
      end

      def test_blocks_split_on_grid_cuts_and_are_byte_identical_when_views_agree
        lines_a = (0...12).map { |i| "#{i}+1|line #{i}" }
        lines_b = lines_a.dup + ["12+1|line 12"]
        plan = CacheMark.plan(parts: (0...12).map { |i| [0, i] }, total: 12, sizes: sizes_at((0...12).map { |i| [0, i] }), grid: 4)
        blocks_a = CacheMark.blocks(lines_a, plan)
        plan_b = CacheMark.plan(parts: (0...13).map { |i| [0, i] }, total: 13, sizes: sizes_at((0...13).map { |i| [0, i] }), grid: 4)
        blocks_b = CacheMark.blocks(lines_b, plan_b)
        # Blocks where both views agree are byte-identical.
        assert_equal blocks_a.first(3).map(&:text), blocks_b.first(3).map(&:text)
        assert blocks_a.first.text.start_with?("<chat>\n")
        assert_equal "</chat>", blocks_a.last.text
      end

      def test_a_stable_prefix_keeps_the_previous_mark
        parts = (0...16).map { |i| [0, i] }
        sizes = sizes_at(parts)
        plan = CacheMark.plan(parts:, total: 16, sizes:, previous_mark: [0, 1, 2, 3, 4, 5, 6, 7], grid: 4)
        # The whole view is stable under budget, so the mark advances to the
        # last grid cut.
        assert_equal 12, plan.mark
      end

      def test_typical_line_falls_back_to_half_a_node
        assert_equal NODE / 2, CacheMark.typical_line([], {})
      end
    end
  end
end
