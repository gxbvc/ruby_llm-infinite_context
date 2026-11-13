# frozen_string_literal: true

require "test_helper"

using RubyLLM::InfiniteContext::Tokens

module RubyLLM
  module InfiniteContext
    class TokensTest < Minitest::Test
      def test_integer_refinement_converts_tokens_to_bytes
        assert_equal 80_000, 20_000.tokens
        assert_equal 16_000, 4_000.tokens
      end

      def test_resolve_budget_bytes_win_tokens_convert_none_defaults
        assert_equal 80_000, InfiniteContext.resolve_budget(tokens: 20_000)
        assert_equal 1_000, InfiniteContext.resolve_budget(budget: 1_000, tokens: 20_000)
        assert_equal DEFAULT_VIEW_BUDGET, InfiniteContext.resolve_budget
      end
    end

    # A stand-in for a record with `acts_as_chat` (ruby_llm 2.1.1): it has
    # #to_llm and the model_id / provider / protocol / assume_model_exists /
    # context readers, and NO #chat method. The real record is exercised in
    # a fresh Rails app by the release install test.
    class FakeConversation
      include Model

      attr_reader :id
      attr_accessor :model_id, :provider, :protocol, :assume_model_exists, :context

      def initialize(model_id = "claude-haiku-4-5", id = 1)
        @model_id = model_id
        @id = id
      end

      def to_llm = raise("the record's own chat must not be used: it would carry its whole history")
    end

    class ModelTest < Minitest::Test
      def before_setup
        # has_infinite_context sets class-level state; clear it per test.
        FakeConversation.instance_variable_set(:@infinite_context_options, nil)
        super
      end

      def test_with_infinite_context_uses_the_record_key_and_options
        FakeConversation.has_infinite_context(compactor: "claude-haiku-4-5")

        manager = FakeConversation.new("claude-sonnet-5-5", 7).with_infinite_context(tokens: 5_000)
        assert_equal "RubyLLM::InfiniteContext::FakeConversation:7", manager.tree.key
        assert_equal 20_000, manager.budget
        assert_equal "claude-haiku-4-5", manager.tree.compactor_model
      end

      def test_search_options_pass_through_and_can_be_overridden_per_memory
        FakeConversation.has_infinite_context(compactor: "claude-haiku-4-5")
        refute FakeConversation.new("m", 21).with_infinite_context(tokens: 1_000).search?

        mask = ->(t) { t }
        FakeConversation.has_infinite_context(compactor: "claude-haiku-4-5", search: true, search_mask: mask,
          search_cap: 2)
        memory = FakeConversation.new("m", 22).with_infinite_context(tokens: 1_000)
        assert memory.search?
        assert_same mask, memory.search_mask
        assert_equal 2, memory.search_cap
        refute FakeConversation.new("m", 23).with_infinite_context(tokens: 1_000, search: false).search?
        assert_equal 1, FakeConversation.new("m", 24).with_infinite_context(tokens: 1_000, search_cap: 1).search_cap
        assert_raises(ArgumentError) { FakeConversation.new("m", 25).with_infinite_context(tokens: 1_000, serch: true) }
        assert_raises(ArgumentError) { FakeConversation.has_infinite_context(search: true, search_mask: :nope) }
      end

      def test_with_infinite_context_needs_has_infinite_context_first
        assert_raises(Error) { FakeConversation.new("claude-haiku-4-5", 9).with_infinite_context(tokens: 1_000) }
      end

      def test_with_infinite_context_needs_a_record_with_acts_as_chat_methods
        klass = Class.new do
          include Model

          has_infinite_context
          def id = 1
        end
        error = assert_raises(Error) { klass.new.with_infinite_context(tokens: 1_000) }
        assert_match(/needs acts_as_chat/, error.message)
      end

      def test_with_infinite_context_needs_a_model_id
        FakeConversation.has_infinite_context
        assert_raises(Error) { FakeConversation.new(nil, 3).with_infinite_context(tokens: 1_000) }
      end

      def test_chat_options_come_from_the_records_acts_as_chat_attributes
        record = FakeConversation.new("m")
        assert_equal({}, Model.chat_options_for(record))
        record.provider = "openai"
        record.protocol = :chat_completions
        record.assume_model_exists = true
        assert_equal({provider: :openai, protocol: :chat_completions, assume_model_exists: true},
          Model.chat_options_for(record))
      end

      def test_each_turn_builds_a_fresh_chat_from_the_record_over_chat_completions
        require "support/fake_network"
        previous = FakeNetwork.install!(max_retries: 0)
        FakeNetwork.reset!
        model = "accounts/fireworks/models/glm-5p3-flash"
        FakeNetwork.default_reply = FakeNetwork.chat_completion_reply("hello there", model: model)
        context = RubyLLM.context do |c|
          c.openai_api_key = "placeholder-not-a-key"
          c.openai_api_base = "http://127.0.0.1:9/v1"
          c.max_retries = 0
        end
        FakeConversation.has_infinite_context(compactor: model, compactor_options: {provider: :openai,
                                                                                    protocol: :chat_completions, assume_model_exists: true, context: context})
        record = FakeConversation.new(model, 11)
        record.provider = "openai"
        record.protocol = :chat_completions
        record.assume_model_exists = true
        record.context = context

        memory = record.with_infinite_context(tokens: 5_000)
        memory.turn("first")
        memory.turn("second")
        paths = FakeNetwork.calls.map { |c| URI(c[:url]).path }
        assert_equal ["/v1/chat/completions"], paths.uniq
        assert_equal 2, FakeNetwork.calls.size, "two turns, two fresh chats, no history carried in the record"
        second = FakeNetwork.calls.last[:body]["messages"].map { |m| m["role"] }
        assert_equal 1, second.count("user"), "the second request holds only the second user message plus the view"
      ensure
        FakeNetwork.restore!(previous) if previous
      end
    end
  end
end
