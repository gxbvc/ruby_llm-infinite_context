# frozen_string_literal: true

require "test_helper"

module RubyLLM
  module InfiniteContext
    class ManagerTest < Minitest::Test
      # A stand-in for RubyLLM::Chat that records instructions, tools and
      # asks, and answers with a fixed reply.
      class FakeChat
        attr_reader :instructions, :tools, :prompts

        def initialize(reply = "here is what I found")
          @reply = reply
          @instructions = []
          @tools = []
          @prompts = []
        end

        def with_instructions(text)
          @instructions << text
          self
        end

        def with_tools(*tools)
          @tools.concat(tools)
          self
        end

        def ask(text)
          @prompts << text
          message = Object.new
          reply_block = @reply
          message.define_singleton_method(:content) { reply_block }
          message
        end
      end

      def test_turn_logs_user_and_reply_and_shows_the_view
        tree = Tree.for("manager-test", compactor: "test-model")
        chat = FakeChat.new
        manager = Manager.new(tree, pump: :none) { chat }
        manager.turn("what did we decide about fernhill?")

        assert_equal 2, tree.entry_count
        assert_equal "user", tree.entry(0).kind
        assert_equal "assistant", tree.entry(1).kind
        assert_equal 1, chat.instructions.size
        assert_includes chat.instructions.first, "<chat>"
        assert_includes chat.instructions.first, "0+1|what did we decide about fernhill?"
        assert_equal ["what did we decide about fernhill?"], chat.prompts
        assert_equal 3, chat.tools.size # zoom, read, date
      end

      def test_zoom_tools_drive_the_real_tree
        tree = Tree.for("manager-tools", compactor: "test-model")
        4.times { |i| tree.append(:user, "message #{i}") }
        # The pump stores short messages verbatim as level-0 nodes.
        4.times { |i| tree.store_node!(0, i, "message #{i}", tries: 0) }
        tree.store_node!(1, 0, "pair one", tries: 0)
        chat = FakeChat.new
        manager = Manager.new(tree, pump: :none) { chat }
        manager.turn("remind me")

        zoom_tool = chat.tools.first
        out = zoom_tool.execute(id: 0, n: 4)
        assert_equal "0+2|pair one\n2+2|#{PLACEHOLDER}", out
        # The guard works through the tool too.
        assert_includes zoom_tool.execute(id: 0, n: 4), "already opened"
      end

      def test_attach_builds_or_finds_the_tree
        manager = Manager.attach("claude-sonnet-5-5", key: "conv-77", compactor: "claude-haiku-4-5", pump: :none)
        assert_equal "conv-77", manager.tree.key
        assert_equal "claude-haiku-4-5", manager.tree.compactor_model
        again = Manager.attach("claude-sonnet-5-5", key: "conv-77", compactor: "claude-haiku-4-5", pump: :none)
        assert_equal manager.tree.id, again.tree.id
      end

      def test_tokens_converts_to_bytes_at_the_default_estimator
        manager = Manager.attach("m", key: "conv-tokens", tokens: 20_000, pump: :none)
        assert_equal 80_000, manager.budget # 4 bytes per token
        by_bytes = Manager.attach("m", key: "conv-bytes", budget: 80_000, pump: :none)
        assert_equal manager.budget, by_bytes.budget
        # Bytes win when both are given.
        both = Manager.attach("m", key: "conv-both", budget: 1_000, tokens: 20_000, pump: :none)
        assert_equal 1_000, both.budget
        assert_equal RubyLLM::InfiniteContext::DEFAULT_VIEW_BUDGET, Manager.attach("m", key: "conv-none", pump: :none).budget
      end

      def test_pump_sync_runs_the_builder
        tree = Tree.for("manager-pump", compactor: "test-model")
        tree.append(:user, "long " * 400)
        builder = Object.new
        builder.define_singleton_method(:build) { |level, i| ["node #{i}", 1] }
        Manager.new(tree, pump: :none) { FakeChat.new }
        tree.append(:user, "x")
        # (0,0) and (0,1) need model calls; (1,0) is a free merge under NODE.
        count = Pump::Runner.new(tree, builder:, jobs: 1).run
        assert_equal 3, count
        assert tree.nodes.exists?(level: 0, i: 0)
        assert tree.nodes.exists?(level: 1, i: 0)
      end
    end
  end
end
