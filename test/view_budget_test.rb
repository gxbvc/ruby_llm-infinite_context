# frozen_string_literal: true

require "test_helper"

module RubyLLM
  module InfiniteContext
    # The rendered view ("<chat>" + lines + "</chat>") never passes its
    # budget. 0.2.0 to 0.2.2 could send a view far over it (found by a GXB
    # app's tree check): a saved view was fitted only when entries arrived
    # (cause 1), the fold counted node text but not "id+n|" and the line
    # break (cause 2), it stopped over budget while parents were pending
    # (cause 3), and it counted an unbuilt short entry as the placeholder
    # (cause 4). Synthetic text only.
    class ViewBudgetTest < Minitest::Test
      LONG = NODE + 100 # an entry over NODE: its line is its node or the placeholder

      def tree(key = "view-budget")
        Tree.for(key, compactor: "test-compactor")
      end

      # What the agent receives (Manager#render_view), written out here so
      # the test does not depend on the code under test.
      def rendered(lines) = "<chat>\n#{lines.join("\n")}\n</chat>".bytesize

      # The fold itself fits the view: the last guard (which leaves out old
      # lines and logs) is not needed.
      def fitted_lines(t, budget)
        logged = []
        lines = t.view_lines(budget, logger: ->(m) { logged << m })
        assert_empty logged, "the last guard left lines out"
        lines
      end

      def assert_within(budget, lines, note = nil)
        assert_operator rendered(lines), :<=, budget, note
      end

      # Every old part sits inside one new part: the view only merged.
      def assert_only_merged(old_parts, new_parts)
        old_parts.each do |l, i|
          inside = new_parts.any? do |nl, ni|
            nl >= l && TreeMath.first(nl, ni) <= TreeMath.first(l, i) && TreeMath.last(l, i) <= TreeMath.last(nl, ni)
          end
          assert inside, "part #{[l, i].inspect} was split: #{old_parts.inspect} -> #{new_parts.inspect}"
        end
      end

      def build_all!(t, total, size: 500)
        l = 0
        while (1 << l) <= total
          (total >> l).times { |i| t.store_node!(l, i, ("n#{l}.#{i} " + "z" * size)[0, size]) }
          l += 1
        end
      end

      # Cause 1: a view saved while nodes were not built, read again after
      # the pump built them, with no new entry.
      def test_a_saved_view_is_fitted_again_when_nodes_are_built_later
        t = tree
        40.times { |i| t.append(:user, "entry #{i} " + "w" * LONG) }
        budget = 3_000
        saved = t.view(budget).parts.map(&:dup)
        assert_equal 40, saved.size # placeholders: every message its own line
        assert_within budget, fitted_lines(t, budget)

        build_all!(t, 40)
        lines = fitted_lines(t, budget)
        assert_within budget, lines
        refute lines.any? { |line| line.include?(PLACEHOLDER) }, "every line has a built node"
        after = t.view(budget).parts
        assert_operator after.size, :<, 40
        assert_only_merged saved, after
        assert_equal 40, t.view(budget).message_count
      end

      def test_a_saved_view_that_did_not_change_is_not_written_again
        t = tree
        4.times { |i| t.append(:user, "m#{i}") }
        record = t.view(10_000)
        stamp = record.updated_at
        sleep 0.01
        assert_equal stamp, t.view(10_000).updated_at
      end

      # Cause 2: labels and line breaks count.
      def test_labels_and_line_breaks_count_against_the_budget
        t = tree
        20.times { |i| t.append(:user, "m%02d " % i + "s" * 96) } # 100 bytes, short: shown word for word
        build_all!(t, 20, size: 100)
        texts = 20 * 100
        budget = texts + 100 # the old fold counted 2,000 and merged nothing
        lines = fitted_lines(t, budget)
        assert_within budget, lines
        assert_operator lines.size, :<, 20
      end

      # Cause 3: parents pending; the view shown still fits, the saved view
      # holds only merges into built parents, and the pump still builds
      # everything afterwards.
      def test_with_parents_pending_the_rendered_view_still_fits
        t = tree
        16.times { |i| t.append(:user, "entry #{i} " + "w" * LONG) }
        16.times { |i| t.store_node!(0, i, "leaf #{i} " + "q" * 400) }
        budget = 2_000
        lines = fitted_lines(t, budget)
        assert_within budget, lines
        assert lines.any? { |line| line.end_with?("|#{PLACEHOLDER}") }, "a pending parent shows the placeholder"
        sizes = t.node_sizes
        t.view(budget).parts.each do |l, i|
          assert sizes.key?([l, i]), "the saved view holds an unbuilt merge #{[l, i].inspect}" if l.positive?
        end
      end

      # The shape seen in production: 1,118 entries, no saved view (a fresh
      # fold), 236 parents pending, 80,000 bytes (20,000 tokens). The saved
      # view stops over budget at the blocked pairs (cause 3), and labels add
      # about 2% (cause 2). The view the agent gets fits, and the fold
      # itself does it: the last guard leaves nothing out.
      def test_the_production_shape_renders_within_budget
        rng = Random.new(1118)
        t = tree("production-shape")
        total = 1_118
        total.times do |i|
          short = rng.rand < 0.6
          t.append(:user, "e#{i} " + "s" * (short ? rng.rand(100..500) : rng.rand(600..3_000)))
          t.store_node!(0, i, "leaf #{i} " + "q" * rng.rand(250..490)) unless short && rng.rand < 0.5
        end
        pending = Set.new
        while pending.size < 236
          l = rng.rand(1..4)
          node = [l, rng.rand(total >> l)]
          while (1 << node[0]) <= total && !pending.include?(node) # an unbuilt node's parents are unbuilt too
            pending << node
            node = [node[0] + 1, node[1] / 2]
            break if TreeMath.last(*node) > total
          end
        end
        l = 1
        while (1 << l) <= total
          (total >> l).times { |i| t.store_node!(l, i, "node #{l}.#{i} " + "p" * rng.rand(250..490)) unless pending.include?([l, i]) }
          l += 1
        end
        budget = InfiniteContext.token_bytes(20_000)
        assert_equal 0, t.views.count, "a fresh fold"

        saved = t.view(budget).parts
        saved_lines = saved.map { |l, i| "#{TreeMath.label(l, i)}|#{TreeMath.flat(t.send(:line_text, l, i))}" }
        blocked = saved.each_cons(2).count do |a, b|
          a[0] == b[0] && a[1].even? && b[1] == a[1] + 1 && pending.include?([a[0] + 1, a[1] / 2])
        end
        assert_operator blocked, :>, 0, "pairs wait on pending parents"
        assert_operator rendered(saved_lines), :>, budget, "the saved view alone is over budget (cause 3)"
        labels = saved.sum { |l, i| TreeMath.label(l, i).bytesize + 2 }
        assert_operator labels, :>, budget / 100, "labels and line breaks are about 2% (cause 2)"

        lines = fitted_lines(t, budget)
        assert_within budget, lines
        refute lines.first.include?("older lines left out")
        assert(lines.any? { |line| line.end_with?("|#{PLACEHOLDER}") }, "a forced merge shows the placeholder")
        manager = Manager.new(t, budget:, pump: :none) { nil }
        assert_operator manager.render_view.bytesize, :<=, budget
      end

      def test_a_view_shown_at_the_compactor_budget_does_not_stop_the_pump
        t = tree
        96.times { |i| t.append(:user, "entry #{i} " + "w" * LONG) }
        manager = Manager.new(t, budget: COMPACT_VIEW_BUDGET, pump: :none) { nil }
        96.times { |i| t.store_node!(0, i, "leaf #{i} " + "q" * 400) }
        assert_operator manager.render_view.bytesize, :<=, COMPACT_VIEW_BUDGET
        builder = Object.new
        builder.define_singleton_method(:build) { |l, i| ["node #{l}.#{i} " + "p" * 300, 1] }
        # One job: concurrent SQLite writes in the encrypted test run hit
        # BusyException (also in 0.2.2); this test is about the order.
        Pump::Runner.new(t, builder:, jobs: 1).run
        assert t.nodes.exists?(level: 6, i: 0), "the pump built up to the top"
        assert_operator manager.render_view.bytesize, :<=, COMPACT_VIEW_BUDGET
      end

      # Cause 4: an unbuilt short entry is shown word for word, so it counts
      # at its own size.
      def test_an_unbuilt_short_entry_counts_at_its_own_size
        t = tree
        10.times { |i| t.append(:user, "e#{i} " + "k" * 497) } # 500 bytes, no node
        5.times { |i| t.store_node!(1, i, "pair #{i}") }
        budget = 3_000 # 10 placeholders would fit; 10 lines of 500 bytes do not
        assert_operator t.view(budget).parts.size, :<, 10
        assert_within budget, fitted_lines(t, budget)
        sizes = t.send(:line_sizes, [], 0, 10)
        assert_equal 500, sizes.call(0, 3)
        assert_nil sizes.call(1, 7)
      end

      # The last guard: no merge is left and the view is still over budget.
      def test_the_oldest_lines_are_left_out_behind_one_line_and_the_count_is_logged
        t = tree
        7.times { |i| t.append(:user, "secret entry #{i} " + "w" * LONG) }
        t.store_node!(2, 0, "old " + "a" * 296)
        t.store_node!(1, 2, "mid " + "b" * 296)
        t.store_node!(0, 6, "new " + "c" * 296)
        t.views.create!(budget: 760, parts: [[2, 0], [1, 2], [0, 6]], message_count: 7)
        logged = []
        shown = t.shown_view(760, logger: ->(m) { logged << m })
        lines = shown.lines
        assert_within 760, lines
        assert_equal "(messages 0 to 3 are left out here to fit the view; zoom(id, 1) still opens any of them)", lines.first
        refute_match(/\A\d+\+\d+\|/, lines.first, "the stub has no id+n label")
        assert_equal ["4+2|mid " + "b" * 296, "6+1|new " + "c" * 296], lines.drop(1)
        assert_equal [[1, 2], [0, 6]], shown.parts
        assert_equal 1, shown.left_out
        assert_equal 1, logged.size
        assert_match(/\Aview over budget by 169 bytes: left out the 1 oldest of 3 lines\z/, logged.first)
        refute_match(/secret|aaa|bbb|ccc/, logged.join)
      end

      def test_when_no_line_fits_only_the_short_line_is_left
        t = tree
        t.append(:user, "w" * LONG)
        t.store_node!(0, 0, "x" * 400)
        logged = []
        logger = Object.new
        logger.define_singleton_method(:warn) { |m| logged << m }
        lines = t.view_lines(MIN_VIEW_BUDGET, logger:)
        assert_equal ["(messages 0 to 0 are left out here to fit the view; zoom(id, 1) still opens any of them)"], lines
        assert_within MIN_VIEW_BUDGET, lines
        assert_match(/left out the 1 oldest of 1 lines/, logged.first)
      end

      def test_a_raising_logger_does_not_stop_the_view
        t = tree
        t.append(:user, "w" * LONG)
        t.store_node!(0, 0, "x" * 400)
        lines = t.view_lines(MIN_VIEW_BUDGET, logger: ->(_) { raise "boom" })
        assert_within MIN_VIEW_BUDGET, lines
      end

      def test_a_budget_under_the_minimum_is_refused
        t = tree
        t.append(:user, "hi")
        [0, 14, 15, MIN_VIEW_BUDGET - 1, 300.5, nil].each do |bad|
          assert_raises(ArgumentError) { t.view_lines(bad) }
        end
        assert_raises(ArgumentError) { Manager.new(t, budget: 100, pump: :none) { nil } }
        assert_raises(ArgumentError) { Manager.new(t, tokens: 10, pump: :none) { nil } }
        assert_raises(ArgumentError) { t.context_before(1, budget: 20) }
        assert_equal ["0+1|hi"], t.view_lines(MIN_VIEW_BUDGET)
      end

      def test_an_empty_log_renders_the_tags_only
        assert_equal [], tree.view_lines(MIN_VIEW_BUDGET)
        assert_equal 15, rendered([])
      end

      # The compactor's context comes from the saved view (no forced merge)
      # and is bounded too: with parents pending, the oldest lines go.
      def test_the_compactor_context_stays_within_its_budget_while_parents_are_pending
        t = tree
        80.times { |i| t.append(:user, "entry #{i} " + "w" * LONG) }
        80.times { |i| t.store_node!(0, i, "leaf #{i} " + "q" * 450) }
        lines = t.context_before(80)
        assert_within COMPACT_VIEW_BUDGET, lines
        assert lines.first.start_with?("(messages 0 to "), "older lines were left out"
        refute_includes lines.first, "zoom", "the compactor has no zoom tool"
        refute lines.any? { |line| line.include?(PLACEHOLDER) }, "no forced merge in the compactor's context"
        assert_equal "79+1|leaf 79 " + "q" * 450, lines.last
      end

      # The fit reads only the nodes at the recent end of a sawtooth view.
      def test_line_sizes_reads_only_the_recent_end
        t = tree
        64.times { |i| t.append(:user, "entry #{i} " + "w" * LONG) }
        build_all!(t, 64, size: 100)
        sizes = t.send(:line_sizes, [[5, 0], [4, 2], [2, 12], [0, 52], [0, 53]], 54, 64)
        assert_nil sizes.call(0, 3), "an old leaf inside a coarse line is not read"
        assert_nil sizes.call(4, 0)
        assert_equal 100, sizes.call(5, 0)
        assert_equal 100, sizes.call(4, 2)
        assert_equal 100, sizes.call(0, 60), "an entry still to append"
        assert_equal 100, sizes.call(1, 26), "a parent the fit may merge into"
      end

      def test_cache_mark_blocks_for_a_shown_view
        t = tree
        40.times { |i| t.append(:user, "m%02d " % i + "s" * 60) }
        shown = t.shown_view(100_000)
        blocks = CacheMark.shown_blocks(shown, total: 40, sizes: t.node_sizes, budget: 100_000)
        assert_equal InfiniteContext.render_view(shown.lines), blocks.map(&:text).join
        assert blocks.any?(&:mark), "under budget the view gets a cache mark"

        u = tree("cache-mark-left-out")
        7.times { |i| u.append(:user, "entry #{i} " + "w" * LONG) }
        u.store_node!(2, 0, "a" * 300)
        u.store_node!(1, 2, "b" * 300)
        u.store_node!(0, 6, "c" * 300)
        u.views.create!(budget: 760, parts: [[2, 0], [1, 2], [0, 6]], message_count: 7)
        small = u.shown_view(760)
        assert_equal 1, small.left_out
        blocks = CacheMark.shown_blocks(small, total: 7, sizes: u.node_sizes, budget: 760)
        assert_equal InfiniteContext.render_view(small.lines), blocks.map(&:text).join
        assert blocks.none?(&:mark), "no cache mark when lines were left out"
        assert blocks.first.text.start_with?("<chat>\n(messages 0 to ")
      end

      def test_manager_turn_sends_a_view_within_budget
        t = tree
        30.times { |i| t.append(:user, "entry #{i} " + "w" * LONG) }
        30.times { |i| t.store_node!(0, i, "leaf #{i} " + "q" * 450) }
        chat = Struct.new(:instructions) do
          def with_instructions(text) = tap { instructions << text }
          def with_tools(*) = self
          def ask(_) = Struct.new(:content).new("ok")
        end.new([])
        Manager.new(t, budget: 4_000, pump: :none) { chat }.turn("hello")
        view = chat.instructions.first[/<chat>\n.*\z/m]
        assert view.start_with?("<chat>\n")
        assert view.end_with?("\n</chat>")
        assert_operator view.bytesize, :<=, 4_000
      end

      # Random trees: built and unbuilt nodes, short and long entries,
      # saved and fresh views. The rendered view always fits, and a saved
      # view read again only merges.
      def test_random_trees_always_render_within_budget
        60.times do |seed|
          rng = Random.new(seed)
          t = tree("random-#{seed}")
          total = rng.rand(1..90)
          budget = rng.rand(MIN_VIEW_BUDGET..8_000)
          add_entries(t, rng, 0, total)
          add_nodes(t, rng, total, rng.rand)
          note = "seed #{seed}, total #{total}, budget #{budget}"

          if rng.rand < 0.6 # a view saved before more nodes and entries arrive
            saved = t.view(budget).parts.map(&:dup)
            assert_within budget, t.view_lines(budget), note
            more = rng.rand(0..30)
            add_entries(t, rng, total, more)
            total += more
            add_nodes(t, rng, total, rng.rand)
            # The fit reads only the recent nodes; a fit with every size
            # gives the same view.
            full = full_sizes(t)
            expected = Fold.new(parts: saved, budget:) { |l, i| full[[l, i]] }
            (total - more).upto(total - 1) { |i| expected.append(i).fit(i + 1) }
            assert_equal expected.fit(total).parts, t.view(budget).parts, note
            assert_only_merged saved, t.view(budget).parts
          end

          shown = t.shown_view(budget)
          lines = shown.lines
          assert_within budget, lines, note
          assert_equal lines.size - (shown.left_out.positive? ? 1 : 0), shown.parts.size, note
          shown.parts.zip(lines.last(shown.parts.size)).each do |(l, i), line|
            assert line.start_with?("#{TreeMath.label(l, i)}|"), note
          end
          assert_operator rendered(t.context_before(total)), :<=, COMPACT_VIEW_BUDGET, note
          parts = t.view(budget).parts
          assert_equal total, parts.sum { |l, _| 1 << l }, note
          t.destroy
        end
      end

      private

      def full_sizes(t)
        sizes = t.node_sizes
        t.entries.where(bytes: ..NODE).pluck(:idx, :bytes).each { |i, b| sizes[[0, i]] = b }
        sizes
      end

      def add_entries(t, rng, from, count)
        count.times do |k|
          size = (rng.rand < 0.5) ? rng.rand(1..NODE) : rng.rand(NODE + 1..2_000)
          text = (rng.rand < 0.2) ? "é" * (size / 2) : "t" * size
          text = "x" if text.empty?
          t.append(:user, "#{from + k} #{text}")
        end
      end

      def add_nodes(t, rng, total, share)
        l = 0
        while (1 << l) <= total
          (total >> l).times do |i|
            next if t.nodes.exists?(level: l, i: i)
            next unless rng.rand < share

            t.store_node!(l, i, "n" * rng.rand(1..NODE))
          end
          l += 1
        end
      end
    end
  end
end
