# frozen_string_literal: true

require "test_helper"

module RubyLLM
  module InfiniteContext
    class TreeTest < Minitest::Test
      def tree(key = "tree-test")
        Tree.for(key, compactor: "test-compactor")
      end

      def test_append_logs_the_entry_and_its_bytes
        t = tree
        entry = t.append(:user, "héllo")
        assert_equal 0, entry.idx
        assert_equal "user", entry.kind
        assert_equal 6, entry.bytes
        assert_equal 1, t.entry_count
      end

      def test_append_rejects_an_unknown_kind
        assert_raises(ArgumentError) { tree.append(:widget, "x") }
      end

      def test_view_is_saved_and_never_rebuilt_from_the_log
        t = tree
        12.times { |i| t.append(:user, "message #{i} #{"word " * 100}") }
        v = t.view(1_000)
        first_parts = v.parts
        assert_equal 12, v.message_count
        # Entries arrived later only move the view forward; the earlier
        # parts survive (append-only, never rebuilt).
        3.times { |i| t.append(:user, "more #{i} #{"word " * 100}") }
        v2 = t.view(1_000)
        assert_equal first_parts, v2.parts.first(first_parts.size)
        assert_equal 15, v2.message_count
      end

      def test_one_saved_view_per_budget
        t = tree
        8.times { |i| t.append(:user, "message #{i} #{"word " * 100}") }
        # The pump's cheap nodes: every message compressed (here, stored
        # verbatim) and the four pairs merged.
        8.times { |i| t.store_node!(0, i, "message #{i} #{"word " * 100}", tries: 0) }
        4.times { |i| t.store_node!(1, i, "pair #{i}", tries: 1) }
        coarse = t.view(500)
        fine = t.view(50_000)
        assert_equal 2, t.views.count
        refute_equal coarse.parts, fine.parts
        assert_operator coarse.parts.size, :<, fine.parts.size
      end

      def test_view_lines_show_short_entries_verbatim_and_placeholders_for_missing_nodes
        t = tree
        t.append(:user, "short one")
        t.append(:user, "long " * 300) # over NODE: needs a node
        lines = t.view_lines(100_000)
        assert_equal "0+1|short one", lines[0]
        assert_equal "1+1|#{PLACEHOLDER}", lines[1]
        # Once the node is built, its text shows.
        t.store_node!(0, 1, "the long message, summarized", tries: 1)
        assert_equal "1+1|the long message, summarized", t.view_lines(100_000)[1]
      end

      def test_context_before_covers_only_earlier_entries
        t = tree
        4.times { |i| t.append(:user, "m#{i}") }
        lines = t.context_before(3)
        assert_equal ["0+1|m0", "1+1|m1", "2+1|m2"], lines
        assert_empty t.context_before(0)
      end

      def test_paired_call_links_a_result_to_its_call
        t = tree
        t.append(:tool, "grep -r fernhill /logs")
        t.append(:echo, "logs/pump_ctl.c:3: # Fernhill valve")
        t.append(:user, "thanks")
        assert_equal "grep -r fernhill /logs", t.paired_call(1)&.text
        assert_nil t.paired_call(0)
        assert_nil t.paired_call(2)
      end

      def test_stats_counts_hot_nodes
        t = tree
        2.times { |i| t.append(:user, "m#{i}") }
        t.store_node!(0, 0, "x", tries: 0)
        t.record_zoom!(level: 0, i: 0, leaf_idx: 0, steps: 3, session: "s1")
        t.record_zoom!(level: 0, i: 0, leaf_idx: 0, steps: 1, session: "s2")
        hot = t.stats.hot_nodes(limit: 10)
        assert_equal 1, hot.size
        assert_equal 2, hot.first.dig_count
        assert_operator hot.first.last_dug_at, :>, 5.seconds.ago
        assert_equal 2, t.stats.zoom_events.count
      end
    end
  end
end
