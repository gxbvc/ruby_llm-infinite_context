# frozen_string_literal: true

require "test_helper"

module RubyLLM
  module InfiniteContext
    class BatchImportTest < Minitest::Test
      # A stand-in for RubyLLM::Batch that records what was submitted.
      class FakeBatch
        attr_reader :chats, :id

        def self.submit(chats)
          batch = new
          batch.chats = chats
          batch
        end

        def initialize
          @id = "batch-#{Random.rand(1_000)}"
        end

        attr_writer :chats
      end

      class FakeChat
        attr_reader :prompts, :instructions

        def initialize
          @prompts = []
        end

        def with_instructions(text)
          @instructions = text
          self
        end

        def ask_later(text)
          @prompts << text
          self
        end
      end

      def test_submit_imports_the_log_and_batches_long_entries
        tree = Tree.for("batch-test", compactor: "test-model")
        messages = [
          {role: "user", content: "short"},
          {role: "user", content: "long " * 400},
          {role: "tool_call", content: "grep -r fernhill /logs"},
          {role: "tool", content: "result " * 400},
          {role: "assistant", content: "done"}
        ]
        chats = []
        importer = BatchImport.new(tree, chat_factory: -> {
          chats << FakeChat.new
          chats.last
        }, batch_class: FakeBatch)
        submission = importer.submit(messages)

        # The log holds all five, with kinds mapped from roles.
        assert_equal 5, tree.entry_count
        assert_equal "echo", tree.entry(3).kind
        assert_equal "assistant", tree.entry(4).kind

        # Two entries need a model call: the long user message and the long
        # tool result. The result's prompt carries its call as a pair.
        assert_equal 2, chats.size
        assert_equal submission.nodes, [[0, 1], [0, 3]]
        assert_includes chats[1].prompts.first, "grep -r fernhill /logs"
        assert_includes chats[0].instructions, "memory of an agent"
        assert_match(/\Abatch-\d+\z/, submission.id)
      end

      def test_submit_returns_nil_when_nothing_needs_a_model_call
        tree = Tree.for("batch-empty", compactor: "test-model")
        importer = BatchImport.new(tree, batch_class: FakeBatch)
        assert_nil importer.submit([{role: "user", content: "hi"}])
      end

      def test_collect_stores_finished_answers
        tree = Tree.for("batch-collect", compactor: "test-model")
        chats = []
        importer = BatchImport.new(tree, chat_factory: -> {
          chats << FakeChat.new
          chats.last
        }, batch_class: FakeBatch)
        submission = importer.submit([{role: "user", content: "long " * 400}])

        batch = Object.new
        batch.define_singleton_method(:complete?) { true }
        batch.define_singleton_method(:status) { :succeeded }
        message = Object.new
        message.define_singleton_method(:content) { "the summary" }
        batch.define_singleton_method(:messages) { [message] }

        assert_equal 1, importer.collect!(submission, batch)
        assert_equal "the summary", tree.node_text(0, 0)
      end

      def test_collect_refuses_an_incomplete_batch
        tree = Tree.for("batch-incomplete", compactor: "test-model")
        chats = []
        importer = BatchImport.new(tree, chat_factory: -> {
          chats << FakeChat.new
          chats.last
        }, batch_class: FakeBatch)
        submission = importer.submit([{role: "user", content: "long " * 400}])
        batch = Object.new
        batch.define_singleton_method(:complete?) { false }
        batch.define_singleton_method(:status) { :pending }
        assert_raises(Error) { importer.collect!(submission, batch) }
      end

      def with_batch_messages(submission, contents)
        batch = Object.new
        batch.define_singleton_method(:complete?) { true }
        batch.define_singleton_method(:status) { :succeeded }
        messages = contents.map do |c|
          m = Object.new
          content = c
          m.define_singleton_method(:content) { content }
          m
        end
        batch.define_singleton_method(:messages) { messages }
        batch
      end

      def test_collect_fails_the_whole_batch_when_a_result_is_missing_or_empty
        tree = Tree.for("batch-strict", compactor: "test-model")
        chats = []
        importer = BatchImport.new(tree, chat_factory: -> {
          chats << FakeChat.new
          chats.last
        }, batch_class: FakeBatch)
        submission = importer.submit([{role: "user", content: "long " * 400}, {role: "user", content: "longer " * 400}])
        assert_equal 2, chats.size

        # One empty result: nothing is stored, not even the good one.
        batch = with_batch_messages(submission, ["good summary", ""])
        error = assert_raises(Error) { importer.collect!(submission, batch) }
        assert_match(/nothing stored/, error.message)
        assert_equal 0, tree.nodes.count

        # A short result list fails the whole collect too.
        short = with_batch_messages(submission, ["only one"])
        assert_raises(Error) { importer.collect!(submission, short) }
        assert_equal 0, tree.nodes.count

        # A nil message counts as missing.
        nilmsg = Object.new
        nilmsg.define_singleton_method(:complete?) { true }
        nilmsg.define_singleton_method(:status) { :succeeded }
        nilmsg.define_singleton_method(:messages) { [nil, nil] }
        assert_raises(Error) { importer.collect!(submission, nilmsg) }
        assert_equal 0, tree.nodes.count

        # A complete batch stores both.
        good = with_batch_messages(submission, ["first summary", "second summary"])
        assert_equal 2, importer.collect!(submission, good)
        assert_equal "first summary", tree.node_text(0, 0)
        assert_equal "second summary", tree.node_text(0, 1)
      end
    end
  end
end
