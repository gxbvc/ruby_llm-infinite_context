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
        # dig_count lands on the opened nodes; a message has no node row
        # unless it needed one, so the leaf shows in its event only.
        assert_equal 1, @tree.nodes.find_by(level: 1, i: 0).dig_count
        assert_equal 0, @tree.nodes.where(level: 0).sum(:dig_count)
      end
    end
  end
end
