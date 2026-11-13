# frozen_string_literal: true

require "test_helper"

module RubyLLM
  module InfiniteContext
    # The search tool (0.3.0, off by default). All text here is synthetic.
    class SearchTest < Minitest::Test
      def tree_with(texts, key: "search-test")
        tree = Tree.for(key, compactor: "test-compactor")
        texts.each { |t| tree.append(:user, t) }
        tree
      end

      def search(tree, words, before = nil, turn: Turn.new, **options)
        Search.new(tree, turn, **options).search(words, before)
      end

      # The message ids a reply lists, in order.
      def ids(reply) = reply.scan(/(\d+) \(/).flatten.map(&:to_i)

      def sql_during
        statements = []
        callback = ->(*, payload) { statements << payload[:sql] }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
        statements
      end

      def row_counts
        conn = ActiveRecord::Base.connection
        Schema::TABLES.to_h { |t| [t, conn.select_value("SELECT COUNT(*) FROM #{t}")] }
      end

      # -- matching ------------------------------------------------------

      def test_finds_a_message_by_one_word_and_by_several_words
        tree = tree_with(["the invoice is late", "Stripe sent a retry", "invoice retry from Stripe", "lunch"])
        assert_equal [2, 0], ids(search(tree, "invoice")).first(2)
        reply = search(tree, "invoice retry Stripe")
        assert_match(/\AMessages with all words: 2 \(/, reply)
        assert_equal [2, 1, 0], ids(reply)
      end

      def test_matching_is_case_folded_and_nfkc_normalized
        tree = tree_with(["Meeting at the CAFÉ", "the ﬁle is ready", "ＳＴＲＩＰＥ payout", "Straße closed"])
        assert_equal [0], ids(search(tree, "café"))
        assert_equal [0], ids(search(tree, "cafe\u0301")) # decomposed accent
        assert_equal [1], ids(search(tree, "file"))       # the "ﬁ" ligature
        assert_equal [2], ids(search(tree, "stripe"))     # full-width letters
        assert_equal [3], ids(search(tree, "STRASSE"))    # ß folds to ss
      end

      def test_a_letters_only_word_of_five_or_more_matches_as_a_prefix
        tree = tree_with(["the deployment failed", "we redeployed", "deploy now"])
        assert_equal [2, 0], ids(search(tree, "deploy"))  # never inside "redeployed"
        assert_equal [], ids(search(tree, "ployment"))   # no match inside a word
      end

      def test_a_short_word_matches_a_whole_word_only
        tree = tree_with(["concatenate the party", "a cat and art", "dep list"])
        assert_equal [1], ids(search(tree, "cat"))
        assert_equal [1], ids(search(tree, "art"))
        assert_equal [2], ids(search(tree, "dep"))
        assert_equal [0], ids(search(tree, "conca"))  # 5 letters: a prefix of "concatenate"
        assert_equal [], ids(search(tree, "conc"))     # 4 letters: whole words only
      end

      def test_a_word_with_digits_never_matches_as_a_prefix
        tree = tree_with(["account 123456789 opened", "code 12345 sent", "ref inv4200", "ref inv42.",
          "amount 12345.678", "id:12345", "ticket #12345 open", "id::12345", "12345..678", "(#12345),",
          "x_12345", "tab\t12345\u3000end"])
        # never in 123456789, 12345.678, id:12345, id::12345, 12345..678 or x_12345
        assert_equal [11, 9, 6, 1], ids(search(tree, "12345"))
        assert_equal [3], ids(search(tree, "inv42"))
        assert_equal [0], ids(search(tree, "123456789"))
        assert_equal [], ids(search(tree, "1234"))
      end

      def test_a_word_with_a_symbol_matches_a_whole_token_only
        tree = tree_with(["open file.rb, then", "open myfile.rb", "open file.rbx", "mail ann@example.com today",
          "keep file.rb.old", "mail ann@example.com.au", "see (file.rb)", "x.file.rb", "keep file.rb..old",
          "x..file.rb"])
        assert_equal [6, 0], ids(search(tree, "file.rb"))
        assert_equal [3], ids(search(tree, "ann@example.com"))
        assert_equal [], ids(search(tree, "nn@example.com"))
        assert_equal [], ids(search(tree, "ann@example.co"))
      end

      def test_symbols_at_the_ends_of_a_word_are_trimmed_and_tiny_words_ignored
        tree = tree_with(["the invoice is late"])
        assert_equal [0], ids(search(tree, "invoice? a"))
        assert_equal "Give one to 8 words of 2 or more characters.", search(tree, "a ! -- ?")
      end

      # -- order, partials, paging -----------------------------------------

      def test_order_is_score_then_newest_and_partials_fill_to_ten
        texts = ["alpha beta gamma"] + Array.new(14) { |i| (i < 5) ? "alpha beta" : "alpha" } + ["alpha beta gamma"]
        tree = tree_with(texts) # 0 and 15 hold all three; 1..5 two words; 6..14 one
        reply = search(tree, "alpha beta gamma")
        assert_equal [15, 0, 5, 4, 3, 2, 1, 14, 13, 12], ids(reply)
        assert_includes reply, "5 (2 of 3 words, "
        assert_includes reply, "14 (1 of 3 words, "
        refute_includes reply, "More messages"
      end

      def test_before_pages_back_and_more_full_matches_are_named
        tree = tree_with(Array.new(25) { |i| "ticket note #{i}" })
        first = search(tree, "ticket")
        assert_equal (15..24).to_a.reverse, ids(first)
        assert_includes first, "More messages with all words are older: search again with before: 15."
        second = search(tree, "ticket", 15)
        assert_equal (5..14).to_a.reverse, ids(second)
        third = search(tree, "ticket", 5)
        assert_equal [4, 3, 2, 1, 0], ids(third)
        refute_includes third, "More messages"
      end

      def test_no_match_says_so
        tree = tree_with(["hello there"])
        assert_equal "No message contains these words. Try other words, or zoom into the view.", search(tree, "zebra")
      end

      def test_a_bad_before_is_refused_and_not_counted
        tree = tree_with(["hello there", "hello again"])
        turn = Turn.new
        lines = []
        ["abc", 0, -1, 3.5, "1.5", [1], " 1 ", "-1"].each do |bad|
          assert_equal "before must be a message id (a whole number above 0).",
            search(tree, "hello", bad, turn:, logger: ->(l) { lines << l })
        end
        assert_equal 0, turn.searches
        assert_equal 8, lines.grep(/\Asearch: status=bad_before ms=\d+\z/).size
        assert_equal [0], ids(search(tree, "hello", "1"))
        assert_equal [1, 0], ids(search(tree, "hello", 10**30)) # no limit, no range error
      end

      def test_text_tagged_binary_is_read_as_utf8
        assert_equal "café", Search.normalize("CAFÉ".b)
        assert_equal "caf\uFFFD", Search.normalize("caf\xFF".b)
        assert_equal "café", Search.normalize("CAFÉ".encode("ISO-8859-1"))
      end

      def test_only_eight_words_are_used
        tree = tree_with(["one two three four five six seven eight nine"])
        reply = search(tree, "one two three four five six seven eight nine")
        assert_match(/\AOnly the first 8 words were used\. Messages with all words: 0 \(/, reply)
      end

      # -- caps --------------------------------------------------------------

      def test_three_searches_per_turn_then_the_cap
        tree = tree_with(["hello there"])
        turn = Turn.new
        3.times { assert_equal [0], ids(search(tree, "hello", turn:)) }
        assert_equal 3, turn.searches
        assert_equal "Search cap reached for this turn (3 searches). Use zoom on the lines you have.",
          search(tree, "hello", turn:)
        assert_equal 0, turn.zooms # its own cap, not the zoom cap
        other = Turn.new
        lines = []
        assert_equal [0], ids(search(tree, "hello", turn: other, cap: 1))
        assert_includes search(tree, "hello", turn: other, cap: 1, logger: ->(l) { lines << l }), "Search cap reached"
        assert_match(/\Asearch: status=cap ms=\d+\z/, lines.first)
        assert_equal "Give one to 8 words of 2 or more characters.", search(tree, "a", turn: Turn.new,
          logger: ->(l) { lines << l })
        assert_match(/\Asearch: status=no_words ms=\d+\z/, lines.last)
      end

      def test_the_cap_holds_with_calls_at_the_same_time
        turn = Turn.new
        claims = Array.new(16) { Thread.new { turn.claim_search!(3) } }.map(&:value)
        assert_equal 3, claims.count(true)
        assert_equal 3, turn.searches
      end

      def test_the_scan_limit_says_what_was_searched
        tree = tree_with(Array.new(10) { |i| (i == 1) ? "needle here" : "hay #{i}" })
        reply = nil
        sql = sql_during { reply = search(tree, "needle", scan_limit: 4) }
        loads = sql.grep(/SELECT .*"text".* FROM "ric_entries"/i)
        assert_equal 1, loads.size # no batch is loaded past the limit
        assert_includes loads.first, "LIMIT"
        assert_equal "No message contains these words. Try other words, or zoom into the view. The search " \
          "stopped at its message limit: it searched messages 9 down to 6 only. Search again with before: 6 " \
          "for older ones.", reply
        assert_equal [1], ids(search(tree, "needle", 6))
      end

      def test_the_time_limit_says_what_was_searched
        tree = tree_with(Array.new(10) { |i| "hay #{i}" })
        now = 0.0
        clock = -> { now += 0.5 }
        reply = search(tree, "hay", clock:, time_limit: 2.0)
        assert_includes reply, "The search stopped at its time limit: it searched messages 9 down to 8 only. " \
          "Search again with before: 8 for older ones."
        assert_equal [9, 8], ids(reply)
      end

      def test_entries_load_in_batches_of_500_and_every_batch_is_searched
        tree = Tree.for("search-batches", compactor: "x")
        Entry.transaction do
          1_001.times { |i| tree.entries.create!(idx: i, kind: "user", text: (i == 3) ? "needle" : "hay", bytes: 3) }
        end
        reply = nil
        sql = sql_during { reply = search(tree, "needle") }
        assert_equal [3], ids(reply)
        loads = sql.grep(/FROM "ric_entries"/i)
        assert_equal 3, loads.size
        assert(loads.all? { |s| s.include?("LIMIT") })
      end

      # -- visibility, mask, storage ---------------------------------------

      def test_another_tree_never_matches
        mine = tree_with(["nothing here"], key: "search-mine")
        theirs = tree_with(["the needle is here"], key: "search-theirs")
        assert_equal "No message contains these words. Try other words, or zoom into the view.", search(mine, "needle")
        assert_equal [0], ids(search(theirs, "needle"))
      end

      def test_a_masked_value_is_not_found_by_its_full_text
        tree = tree_with(["card 4111222233334444 on file", "plain note about card"])
        # The mask contract: flagged spans become spaces.
        mask = ->(text) { text.gsub(/\d{12,19}/) { |m| " " * m.length } }
        assert_equal "No message contains these words. Try other words, or zoom into the view.",
          search(tree, "4111222233334444", mask:)
        assert_equal [], ids(search(tree, "41112222", mask:))
        both = search(tree, "4111222233334444 card", mask:)
        refute_includes both, "all words" # partial "1 of 2" for both messages: no difference shows
        assert_includes both, "1 (1 of 2 words, "
        assert_includes both, "0 (1 of 2 words, "
        assert_equal [1, 0], ids(search(tree, "card", mask:)) # the rest of the text still matches
        # Without the mask the value is found: the mask is what hides it.
        assert_equal [0], ids(search(tree, "4111222233334444"))
      end

      def test_a_raising_or_odd_mask_fails_closed_and_is_counted
        tree = tree_with(["needle one", "needle two", "needle three"])
        lines = []
        mask = ->(text) { text.include?("two") ? raise("boom") : text }
        assert_equal [2, 0], ids(search(tree, "needle", mask:, logger: ->(l) { lines << l }))
        assert_match(/ mask_errors=1 /, lines.last)
        assert_equal [], ids(search(tree, "needle", mask: ->(_t) {}))
        assert_raises(ArgumentError) { Search.new(tree, Turn.new, mask: "not callable") }
      end

      def test_search_writes_nothing_issues_no_like_and_reads_this_tree_only
        tree = tree_with(["the needle is here", "hay"])
        tree_with(["needle elsewhere"], key: "search-other")
        before = row_counts
        reply = nil
        sql = sql_during { reply = search(tree, "needle") }
        assert_equal [0], ids(reply)
        assert_equal before, row_counts
        refute(sql.any? { |s| s.match?(/\bLIKE\b|\bGLOB\b|\bMATCH\b|INSERT|UPDATE|DELETE/i) }, sql.join("\n"))
        assert(sql.grep(/ric_entries/).all? { |s| s.include?("tree_id") })
      end

      def test_encrypted_text_is_found_while_the_raw_column_stays_as_stored
        tree = tree_with(["Zephyrine sensor 4471 stuck", "other"], key: "search-encrypted")
        raw = ActiveRecord::Base.connection.select_value(
          "SELECT text FROM ric_entries WHERE tree_id = #{Integer(tree.id)} AND idx = 0"
        )
        if TEST_ENCRYPTED
          refute_includes raw, "Zephyrine"
          assert JSON.parse(raw).key?("p")
        else
          assert_equal "Zephyrine sensor 4471 stuck", raw
        end
        reply = nil
        sql = sql_during { reply = search(tree, "zephyrine 4471") }
        assert_equal [0], ids(reply)
        refute(sql.any? { |s| s.match?(/\bLIKE\b|INSERT|UPDATE|DELETE/i) })
        assert_equal raw, ActiveRecord::Base.connection.select_value(
          "SELECT text FROM ric_entries WHERE tree_id = #{Integer(tree.id)} AND idx = 0"
        )
      end

      # -- what the reply and the log hold ---------------------------------

      def test_the_reply_format_is_pinned
        tree = tree_with(["quartz meadow", "quartz", "x", "y", "quartz meadow", "z"])
        tree.entries.each { |e| e.update_columns(created_at: Time.utc(2026, 11, 10, 14, e.idx)) }
        reply = search(tree, "quartz meadow", view: [[2, 0], [0, 4], [0, 5]])
        assert_equal "Messages with all words: 4 (Tue 2026-11-10 14:04 UTC, in line 4+1), " \
          "0 (Tue 2026-11-10 14:00 UTC, in line 0+4). " \
          "Messages with some of the words: 1 (1 of 2 words, Tue 2026-11-10 14:01 UTC, in line 0+4). " \
          "Use zoom(id, 1) to read one.", reply
        # No covering line without a view, and the date is the date tool's.
        plain = search(tree, "quartz meadow")
        assert_includes plain, "4 (#{Zoom.new(tree, Turn.new).date(4)})"
        # Each item holds only: the id, "N of M words" for a partial, the
        # date, and the covering line. No kind, role, length or other score.
        item = /\d+ \((?:\d+ of \d+ words, )?\w{3} \d{4}-\d\d-\d\d \d\d:\d\d \w+(?:, in line \d+\+\d+)?\)/
        sentences = reply.gsub(item, "ITEM")
        assert_equal "Messages with all words: ITEM, ITEM. Messages with some of the words: ITEM. " \
          "Use zoom(id, 1) to read one.", sentences
        %w[user assistant tool kind role bytes score].each { |word| refute_includes reply, word }
      end

      def test_the_reply_and_the_log_hold_no_text_and_no_query_words
        tree = tree_with(["Fernhill orchard invoice Quillon", "Fernhill"])
        lines = []
        reply = search(tree, "fernhill quillon", logger: ->(l) { lines << l })
        assert_equal [0, 1], ids(reply)
        %w[fernhill quillon orchard invoice].each do |word|
          refute_includes reply.downcase, word
          refute_includes lines.join.downcase, word
        end
        assert_equal 1, lines.size
        assert_match(/\Asearch: status=ok words=2 scanned=2 hits=1 partial=1 mask_errors=0 stopped=no ms=\d+\z/,
          lines.first)
      end

      def test_a_logger_object_gets_info
        tree = tree_with(["hello"])
        logger = Object.new
        got = []
        logger.define_singleton_method(:info) { |m| got << m }
        search(tree, "hello", logger:)
        assert_match(/\A\[infinite_context\] search: status=ok words=1 /, got.first)
      end

      # -- the tools -------------------------------------------------------

      def test_for_turn_is_the_old_three_tools_by_default
        tree = tree_with(["hello"])
        tools = Tools.for_turn(tree, Turn.new)
        assert_equal [Tools::ZoomTool, Tools::ReadTool, Tools::DateTool], tools.map(&:class)
        assert_equal [Tools::ZoomTool, Tools::ReadTool, Tools::DateTool],
          Tools.for_turn(tree, Turn.new, search: false, search_mask: ->(t) { t }).map(&:class)
      end

      def test_for_turn_with_search_adds_the_tool
        tree = tree_with(["hello there"])
        tools = Tools.for_turn(tree, Turn.new, search: true, view: [[0, 0]])
        assert_equal %w[zoom read date search], tools.map { |t| t.class.tool_name }
        assert_equal "Messages with all words: 0 (#{tree.entry(0).created_at.strftime(DATE_FORMAT)}, in line 0+1). " \
          "Use zoom(id, 1) to read one.", tools.last.execute(words: "hello")
        assert_raises(ArgumentError) { Tools.for_turn(tree, Turn.new, search: true, search_cap: 0) }
      end
    end
  end
end
