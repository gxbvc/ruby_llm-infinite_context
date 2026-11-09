# frozen_string_literal: true

require "test_helper"

module RubyLLM
  module InfiniteContext
    class CompactorTest < Minitest::Test
      # A store over real tables, so the compactor sees what it will see in
      # production.
      def store(tree)
        tree
      end

      def build_tree
        tree = Tree.for("compactor-test", compactor: "test-compactor")
        8.times { |i| tree.append(:user, "message #{i}") }
        tree
      end

      def fake_chat(lines)
        # The factory hands out a fresh fake chat per call; replies come in
        # order. Like RubyLLM::Chat, `ask_later` stages a message WITHOUT a
        # request and `ask` is the request. Each chat records both lists, so
        # a test can count requests (the asks) and see what was only staged.
        replies = lines.dup
        chats = []
        factory = lambda do
          chat = Object.new
          staged = []
          asks = []
          chat.define_singleton_method(:with_instructions) { |_t| chat }
          chat.define_singleton_method(:ask_later) do |text|
            staged << text
            chat
          end
          chat.define_singleton_method(:ask) do |text|
            asks << text
            reply = Object.new
            reply.define_singleton_method(:content) { replies.shift || "no reply left" }
            reply
          end
          chat.define_singleton_method(:staged) { staged }
          chat.define_singleton_method(:asks) { asks }
          chats << chat
          chat
        end
        [factory, chats]
      end

      # Regression: the view context used to be sent with `ask`, which is a
      # second paid request that makes the model answer the context (and it
      # was an Array). It must be staged as a String with ask_later, so one
      # compress is exactly one request.
      def test_the_context_is_staged_not_asked_so_one_compress_is_one_request
        tree = build_tree
        tree.append(:user, "long " * 400)
        factory, chats = fake_chat(["a fitting line"])
        Compactor.new(store(tree), model: "m", chat_factory: factory).build(0, 8)
        chat = chats.first
        assert_equal 1, chat.asks.size, "exactly one paid request for one fitting compress"
        assert_equal 1, chat.staged.size
        assert_kind_of String, chat.staged.first
        assert chat.staged.first.start_with?("<chat>\n")
        assert_includes chat.staged.first, "0+1|message 0"
        refute_includes chat.asks.first, "<chat>"
      end

      # One provider request per try, never more: the context is staged once
      # and each over-long reply costs exactly one more `ask`.
      def test_provider_requests_equal_tries_for_a_node
        tree = build_tree
        tree.append(:user, "long " * 400)
        too_long = "y" * (NODE + 10)
        factory, chats = fake_chat([too_long, too_long, "fits"])
        _text, tries = Compactor.new(store(tree), model: "m", chat_factory: factory).build(0, 8)
        assert_equal 3, tries
        assert_equal 1, chats.size, "one chat per node"
        assert_equal tries, chats.first.asks.size, "one request per try"
        assert_equal 1, chats.first.staged.size, "the context is staged once, not re-sent"
      end

      def test_a_merge_is_one_request_per_try_too
        tree = build_tree
        tree.store_node!(0, 0, "a" * 600, tries: 1)
        tree.store_node!(0, 1, "b" * 600, tries: 1)
        factory, chats = fake_chat(["merged"])
        Compactor.new(store(tree), model: "m", chat_factory: factory).build(1, 0)
        assert_equal 1, chats.first.asks.size
      end

      def test_a_short_entry_is_its_own_node_with_no_model_call
        tree = build_tree
        factory, chats = fake_chat([])
        text, tries = Compactor.new(store(tree), model: "m", chat_factory: factory).build(0, 0)
        assert_equal "message 0", text
        assert_equal 0, tries
        assert_empty chats
      end

      def test_the_ruler_and_context_are_in_the_step
        step = Compactor.compress_prompt("user", "long " * 400)
        assert_includes step, "-" * NODE
        assert_includes step, "measuring stick"
        assert_includes step, "compress this user message"
      end

      def test_a_tool_result_carries_its_call_as_a_pair
        tree = build_tree
        tree.append(:tool, "grep -rn fernhill /var/log")
        tree.append(:echo, "result " * 400)
        step = Compactor.compress_prompt("echo", "result " * 400, call: "grep -rn fernhill /var/log")
        assert_includes step, "tool call that produced this result"
        assert_includes step, "grep -rn fernhill /var/log"
        no_pair = Compactor.compress_prompt("user", "result " * 400)
        refute_includes no_pair, "tool call"
      end

      def test_a_very_large_result_is_stubbed_to_head_and_tail
        huge = "x" * (CAP * 3)
        step = Compactor.compress_prompt("echo", huge)
        assert_includes step, "characters cut"
        assert_operator step.length, :<, huge.length
      end

      def test_merge_joins_short_children_with_no_model_call
        tree = build_tree
        tree.store_node!(0, 0, "a" * 100, tries: 0)
        tree.store_node!(0, 1, "b" * 100, tries: 0)
        text, tries = Compactor.new(store(tree), model: "m", chat_factory: -> { raise "no call" }).build(1, 0)
        assert_equal "#{"a" * 100}\n#{"b" * 100}", text
        assert_equal 0, tries
      end

      def test_merge_of_long_children_calls_the_model
        tree = build_tree
        tree.store_node!(0, 0, "a" * 600, tries: 1)
        tree.store_node!(0, 1, "b" * 600, tries: 1)
        factory, chats = fake_chat(["merged line"])
        text, = Compactor.new(store(tree), model: "m", chat_factory: factory).build(1, 0)
        assert_equal "merged line", text
        assert_equal 1, chats.size
      end

      def test_an_over_long_reply_is_cut_back_until_it_fits
        tree = build_tree
        tree.append(:user, "long " * 400)
        lines = ["y" * (NODE + 10), "z" * (NODE + 3), "fits " * 20]
        factory, = fake_chat(lines)
        text, tries = Compactor.new(store(tree), model: "m", chat_factory: factory).build(0, 8)
        assert_equal ("fits " * 20).strip, text
        assert_equal 3, tries
      end

      def test_a_fitting_first_reply_stops_the_loop
        tree = build_tree
        tree.append(:user, "long " * 400)
        lines = ["short one", "y" * (NODE + 10), "y" * (NODE + 10), "y" * (NODE + 10), "y" * (NODE + 10), "y" * (NODE + 10)]
        factory, = fake_chat(lines)
        text, tries = Compactor.new(store(tree), model: "m", chat_factory: factory).build(0, 8)
        assert_equal "short one", text
        assert_equal 1, tries
      end
    end
  end
end
