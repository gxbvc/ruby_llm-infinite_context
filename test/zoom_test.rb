# frozen_string_literal: true

require "test_helper"

module RubyLLM
  module InfiniteContext
    class ZoomTest < Minitest::Test
      def setup
        @tree = Tree.for("zoom-test", compactor: "test-compactor")
        8.times { |i| @tree.append(:user, "message #{i}") }
        # Build a small tree: node 1+0 over messages 0..1, 1+1 over 2..3.
        @tree.store_node!(1, 0, "pair one", tries: 0)
        @tree.store_node!(1, 1, "pair two", tries: 0)
        @tree.store_node!(2, 0, "four messages", tries: 0)
        @turn = Turn.new("turn-1")
        @zoom = Zoom.new(@tree, @turn)
      end

      def test_zoom_opens_a_line_into_its_two_children
        out = @zoom.zoom(0, 4)
        assert_equal "0+2|pair one\n2+2|pair two", out
      end

      def test_zoom_of_an_unbuilt_line_shows_the_placeholder
        out = @zoom.zoom(4, 4)
        assert_equal "4+2|#{PLACEHOLDER}\n6+2|#{PLACEHOLDER}", out
      end

      def test_zoom_to_a_leaf_shows_the_message_verbatim
        assert_equal "message 5", @zoom.zoom(5, 1)
      end

      def test_a_repeat_zoom_this_turn_is_refused_with_a_hint
        @zoom.zoom(0, 4)
        out = @zoom.zoom(0, 4)
        assert_includes out, "already opened"
        refute_includes out, "pair one"
      end

      def test_a_repeat_leaf_is_refused_but_the_first_still_counts
        @zoom.zoom(5, 1)
        assert_includes @zoom.zoom(5, 1), "already opened"
      end

      def test_per_turn_zoom_cap
        turn = Turn.new("turn-2", cap: 2)
        zoom = Zoom.new(@tree, turn)
        assert_equal "message 0", zoom.zoom(0, 1)
        assert_equal "message 1", zoom.zoom(1, 1)
        assert_includes zoom.zoom(2, 1), "cap reached"
        assert_includes zoom.zoom(0, 4), "cap reached"
      end

      def test_invalid_lines_are_refused
        assert_match(/No line/, @zoom.zoom(3, 2)) # 3 not divisible by 2
        assert_match(/No line/, @zoom.zoom(0, 3)) # not a power of 2
        assert_match(/No line/, @zoom.zoom(0, 0))
        assert_match(/No line/, @zoom.zoom(7, 4)) # past the end
        assert_match(/No line/, @zoom.zoom(-2, 2))
        assert_match(/No line/, @zoom.zoom("x", 2))
      end

      def test_a_long_leaf_is_paged_and_read_fetches_more
        text = "page " + "content " * 1_000 # well over PAGE bytes
        @tree.append(:note, text)
        first = @zoom.zoom(8, 1)
        assert_includes first, "page 1 of"
        assert_includes first, "read(8, 2)"
        second = @zoom.read(8, 2)
        assert_includes second, "page 2 of"
        assert_includes @zoom.read(8, 99), "page"
        refute_includes second, "[page 1"
      end

      def test_read_on_a_short_message_says_so
        assert_match(/1 page/, @zoom.read(0, 2))
      end

      def test_date_gives_the_time_of_a_message
        assert_match(/\d{4}-\d{2}-\d{2}/, @zoom.date(0))
        assert_match(/No message/, @zoom.date(99))
      end

      def test_counters_record_the_leaf_reached_and_the_steps
        @zoom.zoom(0, 4) # step 1
        @zoom.zoom(0, 2) # step 2
        @zoom.zoom(1, 1) # step 3: leaf
        events = @tree.zoom_events.order(:id)
        assert_equal 3, events.count
        leaf = events.last
        assert_equal 0, leaf.level
        assert_equal 1, leaf.i
        assert_equal 1, leaf.leaf_idx
        assert_equal 3, leaf.steps
        assert_equal "turn-1", leaf.session
        # Each event names the line opened: 0+4 is node (2, 0), 0+2 is
        # node (1, 0), 1+1 is message 1.
        assert_equal [[2, 0, nil], [1, 0, nil], [0, 1, 1]], events.pluck(:level, :i, :leaf_idx)
        # dig_count lands on the opened nodes; this setup has no level-0
        # node rows, so the leaf shows in its event only.
        assert_equal 1, @tree.nodes.find_by(level: 2, i: 0).dig_count
        assert_equal 1, @tree.nodes.find_by(level: 1, i: 0).dig_count
        assert_equal 0, @tree.nodes.find_by(level: 1, i: 1).dig_count
        assert_equal 0, @tree.nodes.where(level: 0).sum(:dig_count)
      end

      # -- walking down: a zoom marks the line it opened, not a child -------

      # The pump stores short messages verbatim as level-0 nodes.
      def store_leaves = 8.times { |i| @tree.store_node!(0, i, "message #{i}", tries: 0) }

      def test_a_pair_then_its_left_leaf_in_one_turn
        store_leaves
        assert_equal "0+1|message 0\n1+1|message 1", @zoom.zoom(0, 2)
        assert_equal "message 0", @zoom.zoom(0, 1)
        assert_equal "message 1", @zoom.zoom(1, 1)
      end

      def test_a_leaf_then_its_pair_in_one_turn
        store_leaves
        assert_equal "message 2", @zoom.zoom(2, 1)
        assert_equal "2+1|message 2\n3+1|message 3", @zoom.zoom(2, 2)
        assert_equal "message 3", @zoom.zoom(3, 1)
      end

      def test_a_line_then_its_left_and_right_child_in_one_turn
        store_leaves
        @zoom.zoom(0, 4)
        assert_equal "0+1|message 0\n1+1|message 1", @zoom.zoom(0, 2)
        assert_equal "2+1|message 2\n3+1|message 3", @zoom.zoom(2, 2)
      end

      def test_a_full_walk_down_from_8_to_every_leaf_in_one_turn
        @tree.store_node!(1, 2, "pair three", tries: 0)
        @tree.store_node!(1, 3, "pair four", tries: 0)
        @tree.store_node!(2, 1, "four more", tries: 0)
        @tree.store_node!(3, 0, "all eight", tries: 0)
        store_leaves
        turn = Turn.new("walk", cap: 15)
        zoom = Zoom.new(@tree, turn)

        assert_equal "0+4|four messages\n4+4|four more", zoom.zoom(0, 8)
        assert_equal "0+2|pair one\n2+2|pair two", zoom.zoom(0, 4)
        assert_equal "4+2|pair three\n6+2|pair four", zoom.zoom(4, 4)
        [0, 2, 4, 6].each do |id|
          assert_equal "#{id}+1|message #{id}\n#{id + 1}+1|message #{id + 1}", zoom.zoom(id, 2)
        end
        8.times { |id| assert_equal "message #{id}", zoom.zoom(id, 1) }

        assert_equal 15, turn.zooms
        expected = %w[0+8 0+4 4+4 0+2 2+2 4+2 6+2] + (0..7).map { |id| "#{id}+1" }
        assert_equal expected, turn.opened.keys

        # Every line was opened exactly once: the counters agree.
        assert_equal 15, @tree.zoom_events.count
        assert_equal [1], @tree.nodes.distinct.pluck(:dig_count)
        assert_equal 15, @tree.nodes.count
        refute @tree.nodes.where(last_dug_at: nil).exists?
        coords = [[3, 0], [2, 0], [2, 1], [1, 0], [1, 1], [1, 2], [1, 3]] + (0..7).map { |id| [0, id] }
        assert_equal coords, @tree.zoom_events.order(:id).pluck(:level, :i)
      end

      def test_the_last_lines_of_the_log_record_their_own_coordinates
        # Messages 0..7 are the whole log: 6+2 and 4+4 end at its last entry.
        turn = Turn.new("end", cap: 5)
        zoom = Zoom.new(@tree, turn)
        zoom.zoom(4, 4)
        zoom.zoom(6, 2)
        zoom.zoom(7, 1)
        zoom.zoom(6, 1)
        assert_equal [[2, 1, nil], [1, 3, nil], [0, 7, 7], [0, 6, 6]],
          @tree.zoom_events.order(:id).pluck(:level, :i, :leaf_idx)
        assert_match(/No line/, zoom.zoom(8, 1))
        assert_match(/No line/, zoom.zoom(0, 16))
      end

      def test_each_repeat_is_refused_with_the_label_of_the_line_opened
        turn = Turn.new("repeat", cap: 20)
        zoom = Zoom.new(@tree, turn)
        lines = [[0, 8], [0, 4], [4, 4], [0, 2], [2, 2], [0, 1], [1, 1]]
        lines.each { |id, n| refute_includes zoom.zoom(id, n), "already opened" }
        lines.each do |id, n|
          assert_equal "You already opened line #{id}+#{n} this turn; its text is above. Use what you have.",
            zoom.zoom(id, n)
        end
        assert_equal lines.size, turn.zooms
        assert_equal lines.size, @tree.zoom_events.count, "a refused repeat records no event"
      end

      def test_the_cap_counts_each_opened_line_once
        store_leaves
        turn = Turn.new("cap", cap: 3)
        zoom = Zoom.new(@tree, turn)
        zoom.zoom(0, 4)
        assert_includes zoom.zoom(0, 4), "already opened"
        assert_equal "0+1|message 0\n1+1|message 1", zoom.zoom(0, 2)
        assert_includes zoom.zoom(0, 2), "already opened"
        assert_equal "message 0", zoom.zoom(0, 1)
        assert_equal 3, turn.zooms
        assert_equal "Zoom cap reached for this turn (3 lines opened). " \
          "Work with the lines you have and say what you still need in your reply.", zoom.zoom(1, 1)
        assert_includes zoom.zoom(2, 2), "cap reached"
        # A repeat still gets the repeat answer after the cap.
        assert_includes zoom.zoom(0, 1), "already opened"
        assert_equal 3, @tree.zoom_events.count
      end

      def test_read_is_not_affected_by_zooms_and_does_not_count
        text = "page " + "content " * 1_000
        @tree.append(:note, text) # message 8
        @tree.append(:user, "message 9")
        turn = Turn.new("read", cap: 2)
        zoom = Zoom.new(@tree, turn)
        assert_includes zoom.zoom(8, 2), "8+1|"
        assert_includes zoom.zoom(8, 1), "page 1 of"
        assert_includes zoom.read(8, 2), "page 2 of"
        assert_includes zoom.read(8, 2), "page 2 of" # read has no repeat guard
        assert_match(/1 page/, zoom.read(9, 2))
        assert_equal 2, turn.zooms
        assert_equal 2, @tree.zoom_events.count
      end
    end
  end
end
