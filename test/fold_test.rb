# frozen_string_literal: true

require "test_helper"

module RubyLLM
  module InfiniteContext
    class FoldTest < Minitest::Test
      # Every node is 10 bytes; `unbuilt` lists nodes that are not built.
      def sizer(unbuilt: [])
        ->(l, i) { unbuilt.include?([l, i]) ? nil : 10 }
      end

      def fold(total, budget:, unbuilt: [])
        s = sizer(unbuilt:)
        Fold.from_scratch(total, budget:) { |l, i| s.call(l, i) }
      end

      def assert_tiles(parts, total)
        pos = 0
        parts.each do |l, i|
          assert_equal pos, TreeMath.first(l, i), "parts #{parts.inspect} leave a gap or overlap at #{pos}"
          pos = TreeMath.last(l, i)
        end
        assert_equal total, pos
      end

      def test_under_budget_every_message_is_its_own_line
        assert_equal (0...6).map { |i| [0, i] }, fold(6, budget: 1_000).parts
      end

      def test_over_budget_merges_the_most_due_pair_by_age
        # T=4: [0,0] [0,1] [0,2] [0,3] is 40 > 35. Pair (0,1) is due 4/4 = 1,
        # pair (2,3) is due 2/4: the older pair merges.
        assert_equal [[1, 0], [0, 2], [0, 3]], fold(4, budget: 35).parts
        # T=5: only (2,3) can merge; (3,4) is not an aligned pair.
        assert_equal [[1, 0], [1, 1], [0, 4]], fold(5, budget: 35).parts
        # T=6: [1,0][1,1] is due 6/8 and (4,5) is due 2/4: the old pair merges.
        assert_equal [[2, 0], [0, 4], [0, 5]], fold(6, budget: 35).parts
        # T=7: (4,5) is the only aligned pair.
        assert_equal [[2, 0], [1, 2], [0, 6]], fold(7, budget: 35).parts
      end

      def test_a_pair_whose_parent_is_not_built_is_passed_over
        assert_equal [[0, 0], [0, 1], [1, 1]], fold(4, budget: 35, unbuilt: [[1, 0]]).parts
      end

      def test_with_no_parent_built_the_view_stays_over_budget
        parts = fold(4, budget: 35, unbuilt: [[1, 0], [1, 1]]).parts
        assert_equal (0...4).map { |i| [0, i] }, parts
      end

      def test_an_unbuilt_part_counts_its_placeholder
        f = Fold.new(parts: [[0, 0], [0, 1]]) { |l, i| i.zero? ? 10 : nil }
        assert_equal 10 + PLACEHOLDER.bytesize, f.size
      end

      def test_the_view_only_appends_and_coarsens
        s = sizer
        f = Fold.new(budget: 120) { |l, i| s.call(l, i) }
        previous = []
        200.times do |i|
          f.append(i).fit(i + 1)
          assert_tiles f.parts, i + 1
          assert_operator f.size, :<=, 120
          previous.each do |l, j|
            assert(f.parts.any? { |pl, pi| pl >= l && TreeMath.first(pl, pi) <= TreeMath.first(l, j) && TreeMath.last(l, j) <= TreeMath.last(pl, pi) },
              "part #{[l, j].inspect} was split at T=#{i + 1}")
          end
          previous = f.parts.map(&:dup)
        end
        # Detail fades with age: the oldest line covers the most messages.
        assert_operator f.parts.first[0], :>, f.parts.last[0]
      end

      def test_folding_incrementally_gives_the_same_view_as_folding_from_scratch
        s = sizer
        live = Fold.new(budget: 200) { |l, i| s.call(l, i) }
        100.times { |i| live.append(i).fit(i + 1) }
        assert_equal fold(100, budget: 200).parts, live.parts
      end

      def test_first_unbuilt_finds_the_first_message_whose_view_line_is_not_built
        f = Fold.new(parts: [[1, 0], [0, 2], [0, 3]]) { |l, i| ([l, i] == [0, 3]) ? nil : 10 }
        assert_equal 3, f.first_unbuilt(4)
        g = Fold.new(parts: [[1, 0]]) { 10 }
        assert_equal 2, g.first_unbuilt(2)
      end
    end
  end
end
