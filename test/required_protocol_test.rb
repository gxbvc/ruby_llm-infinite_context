# frozen_string_literal: true

require "test_helper"
require "support/fake_network"

module RubyLLM
  module InfiniteContext
    # RubyLLM::InfiniteContext.required_protocol: with it set, every chat the
    # gem builds or uses must have that protocol, or ProtocolError is raised
    # BEFORE any request. Real RubyLLM chats over the in-process fake
    # network; no key, no socket.
    class RequiredProtocolTest < Minitest::Test
      MODEL = "accounts/fireworks/models/glm-5p3-flash"
      BASE = "http://127.0.0.1:9/v1"

      # A chat stand-in that reports a protocol and answers in one line.
      class ProtocolChat
        attr_reader :protocol, :asks

        def initialize(protocol)
          @protocol = protocol
          @asks = []
        end

        def with_instructions(_text) = self
        def with_tools(*) = self
        def ask_later(_text) = self

        def ask(text)
          @asks << text
          Struct.new(:content).new("one line")
        end
      end

      class FakeBatch
        class << self
          attr_accessor :submitted
        end

        def self.submit(chats)
          self.submitted = chats
          Struct.new(:id, :provider).new("batch-1", nil)
        end
      end

      def setup
        @previous = FakeNetwork.install!(max_retries: 0)
        FakeNetwork.reset!
        FakeNetwork.default_reply = FakeNetwork.chat_completion_reply("a short summary line", model: MODEL)
        @context = RubyLLM.context do |c|
          c.openai_api_key = "placeholder-not-a-key"
          c.openai_api_base = BASE
          c.max_retries = 0
        end
        @wired = {provider: :openai, assume_model_exists: true, context: @context}
        @completions = @wired.merge(protocol: :chat_completions)
        @saved_global = InfiniteContext.compactor_chat_options
        @saved_required = InfiniteContext.required_protocol
        InfiniteContext.required_protocol = :chat_completions
        FakeBatch.submitted = nil
      end

      def teardown
        InfiniteContext.required_protocol = @saved_required
        InfiniteContext.compactor_chat_options = @saved_global
        FakeNetwork.restore!(@previous)
      end

      def long_tree(key)
        tree = Tree.for(key, compactor: MODEL)
        tree.append(:user, "entry " + "long " * 300) # over NODE: needs a model call
        tree
      end

      def paths = FakeNetwork.calls.map { |c| URI(c[:url]).path }

      def assert_refused(&block)
        error = assert_raises(ProtocolError, &block)
        assert_kind_of Error, error
        assert_empty FakeNetwork.calls, "nothing was sent"
        error
      end

      # -- the setting ------------------------------------------------------------

      def test_the_setting_is_a_symbol_or_nil
        InfiniteContext.required_protocol = "chat_completions"
        assert_equal :chat_completions, InfiniteContext.required_protocol
        InfiniteContext.required_protocol = nil
        assert_nil InfiniteContext.required_protocol
      end

      def test_without_the_setting_nothing_is_checked
        InfiniteContext.required_protocol = nil
        assert_same :x, ChatOptions.check!(:x, "chat")
        chat = ChatOptions.build(MODEL, @wired)
        assert_nil chat.instance_variable_get(:@protocol)
      end

      # -- ChatOptions.build ----------------------------------------------------------

      def test_build_needs_the_protocol_in_the_options
        assert_equal :chat_completions, ChatOptions.build(MODEL, @completions).instance_variable_get(:@protocol)
        assert ChatOptions.build(MODEL, @wired.merge(protocol: "chat_completions"))
        error = assert_refused { ChatOptions.build(MODEL, @wired) }
        assert_match(/protocol nil/, error.message)
        assert_match(/required_protocol is :chat_completions/, error.message)
        assert_refused { ChatOptions.build(MODEL, @wired.merge(protocol: :responses)) }
      end

      # -- the compactor -----------------------------------------------------------------

      def test_compactor_default_options_without_protocol_are_refused
        InfiniteContext.compactor_chat_options = @wired
        error = assert_refused { Compactor.new(long_tree("rp-default"), model: MODEL).build(0, 0) }
        assert_match(/compactor/, error.message)
      end

      def test_compactor_default_options_with_protocol_work
        InfiniteContext.compactor_chat_options = @completions
        text, = Compactor.new(long_tree("rp-default-ok"), model: MODEL).build(0, 0)
        assert_equal "a short summary line", text
        assert_equal ["/v1/chat/completions"], paths.uniq
      end

      def test_compactor_own_options_are_checked
        assert_refused do
          Compactor.new(long_tree("rp-own"), model: MODEL, chat_options: @wired.merge(protocol: :responses)).build(0, 0)
        end
        Compactor.new(long_tree("rp-own-ok"), model: MODEL, chat_options: @completions).build(0, 0)
        assert_equal ["/v1/chat/completions"], paths.uniq
      end

      def test_compactor_chat_factory_chats_are_checked
        tree = long_tree("rp-factory")
        no_protocol = -> { @context.chat(model: MODEL, provider: :openai, assume_model_exists: true) }
        assert_refused { Compactor.new(tree, model: MODEL, chat_factory: no_protocol).build(0, 0) }

        unreadable = Object.new
        error = assert_refused { Compactor.new(tree, model: MODEL, chat_factory: -> { unreadable }).build(0, 0) }
        assert_match(/cannot read the protocol/, error.message)

        assert_refused { Compactor.new(tree, model: MODEL, chat_factory: -> { ProtocolChat.new(:responses) }).build(0, 0) }
        good = ProtocolChat.new(:chat_completions)
        assert_equal ["one line", 1], Compactor.new(tree, model: MODEL, chat_factory: -> { good }).build(0, 0)
      end

      def test_compactor_fallbacks_must_stay_on_the_provider
        tree = long_tree("rp-fallback")
        other = -> { ChatOptions.build(MODEL, @completions).with_fallbacks("accounts/fireworks/models/kimi-k3") }
        error = assert_refused { Compactor.new(tree, model: MODEL, chat_factory: other).build(0, 0) }
        assert_match(/fallback/, error.message)

        same = lambda do
          chat = ChatOptions.build(MODEL, @completions)
          chat.with_fallbacks(RubyLLM::Model.default("accounts/fireworks/models/kimi-k3", chat.provider.slug))
        end
        text, = Compactor.new(tree, model: MODEL, chat_factory: same).build(0, 0)
        assert_equal "a short summary line", text
      end

      # -- the pump (and PumpJob, which uses the global options) -------------------------

      def test_pump_raises_on_a_protocol_error_and_sends_nothing
        InfiniteContext.compactor_chat_options = @wired
        tree = long_tree("rp-pump")
        logged = []
        assert_refused { Pump::Runner.new(tree, jobs: 2, logger: ->(m) { logged << m }).run }
        assert_equal 0, tree.nodes.count
        assert_empty logged, "a setup error is raised, not logged and retried"
      end

      def test_pump_works_with_the_protocol
        InfiniteContext.compactor_chat_options = @completions
        tree = long_tree("rp-pump-ok")
        assert_equal 1, Pump::Runner.new(tree, jobs: 1).run
        assert_equal ["/v1/chat/completions"], paths.uniq
      end

      # -- batch import -------------------------------------------------------------------

      # A provider batch job is not a chat completions call: with the rule
      # set, BatchImport refuses even with chat_completions options, before
      # it logs or submits anything.
      def test_batch_import_submit_is_refused_under_the_rule
        InfiniteContext.compactor_chat_options = @completions
        tree = Tree.for("rp-batch", compactor: MODEL)
        [
          BatchImport.new(tree, model: MODEL, chat_options: @completions, batch_class: FakeBatch),
          BatchImport.new(tree, batch_class: FakeBatch),
          BatchImport.new(tree, chat_factory: -> { ProtocolChat.new(:chat_completions) }, batch_class: FakeBatch)
        ].each do |import|
          error = assert_refused { import.submit([{role: "user", content: "long " * 300}]) }
          assert_match(/provider batch jobs/, error.message)
          assert_match(/tree\.append/, error.message)
          assert_match(/Pump::Runner/, error.message)
        end
        assert_nil FakeBatch.submitted
        assert_equal 0, tree.entry_count, "nothing was logged"
      end

      def test_batch_import_collect_is_refused_under_the_rule
        tree = Tree.for("rp-batch-collect", compactor: MODEL)
        submission = BatchImport::Submission.new(nodes: [[0, 0]], id: "batch-1", provider: "openai")
        batch = Object.new
        def batch.complete? = raise("collect! must refuse before it reads the batch")
        assert_refused { BatchImport.new(tree, batch_class: FakeBatch).collect!(submission, batch) }
        assert_equal 0, tree.nodes.count
      end

      def test_without_the_rule_batch_import_still_submits
        InfiniteContext.required_protocol = nil
        tree = Tree.for("rp-batch-off", compactor: MODEL)
        submission = BatchImport.new(tree, chat_options: @completions, batch_class: FakeBatch)
          .submit([{role: "user", content: "long " * 300}])
        assert_equal "batch-1", submission.id
        assert_equal 1, FakeBatch.submitted.size
      end

      # The route the error message names: append, then the pump, all on
      # chat completions.
      def test_append_and_the_pump_load_an_old_thread_under_the_rule
        InfiniteContext.compactor_chat_options = @completions
        tree = Tree.for("rp-old-thread", compactor: MODEL)
        [[:user, "long " * 300], [:assistant, "short reply"], [:user, "more " * 300]].each do |kind, text|
          tree.append(kind, text)
        end
        assert_operator Pump::Runner.new(tree, jobs: 2).run, :>=, 3
        refute_empty FakeNetwork.calls
        assert_equal ["/v1/chat/completions"], paths.uniq
      end

      # -- attach and the Model concern ------------------------------------------------------

      def test_attach_by_model_name_checks_chat_options
        mem = InfiniteContext.attach(MODEL, key: "rp-attach", chat_options: @wired, pump: :none)
        error = assert_refused { mem.turn("hi") }
        assert_match(/chat options/, error.message)
        assert_equal 0, mem.tree.entry_count, "nothing was logged"

        ok = InfiniteContext.attach(MODEL, key: "rp-attach-ok", chat_options: @completions, pump: :none)
        ok.turn("hi")
        assert_equal ["/v1/chat/completions"], paths.uniq
      end

      def test_attach_with_a_chat_object_or_factory_is_checked
        assert_refused { InfiniteContext.attach(RubyLLM.chat(model: "claude-haiku-4-5"), key: "rp-obj", pump: :none).turn("hi") }
        assert_refused { InfiniteContext.attach(-> { ProtocolChat.new(:responses) }, key: "rp-proc", pump: :none).turn("hi") }
        chat = ProtocolChat.new(:chat_completions)
        InfiniteContext.attach(-> { chat }, key: "rp-proc-ok", pump: :none).turn("hi")
        assert_equal ["hi"], chat.asks
      end

      # An acts_as_chat record passed to attach sends through its memoized
      # to_llm chat, so that chat is checked, not the record's attribute.
      class SendingRecord
        attr_accessor :protocol

        def initialize(protocol, sender)
          @protocol = protocol
          @sender = sender
        end

        def to_llm = @sender
        def with_instructions(_text) = self
        def with_tools(*) = self
        def ask(text) = @sender.ask(text)
      end

      def test_a_record_is_checked_through_its_to_llm_chat
        stale = SendingRecord.new(:chat_completions, ProtocolChat.new(:responses))
        error = assert_refused { InfiniteContext.attach(stale, key: "rp-record-stale", pump: :none).turn("hi") }
        assert_match(/:responses/, error.message)

        real = SendingRecord.new(:chat_completions, @context.chat(model: MODEL, provider: :openai, assume_model_exists: true))
        assert_refused { InfiniteContext.attach(real, key: "rp-record-real", pump: :none).turn("hi") }

        good = ProtocolChat.new(:chat_completions)
        InfiniteContext.attach(SendingRecord.new(nil, good), key: "rp-record-ok", pump: :none).turn("hi")
        assert_equal ["hi"], good.asks
      end

      def test_attach_turn_pumps_the_compactor_under_the_rule
        InfiniteContext.compactor_chat_options = @wired
        mem = InfiniteContext.attach(MODEL, key: "rp-attach-pump", compactor: MODEL, chat_options: @completions)
        assert_raises(ProtocolError) { mem.turn("start " + "long " * 300) }
        assert_equal ["/v1/chat/completions"], paths.uniq, "the turn itself went out; the compactor sent nothing"
        assert_equal 1, FakeNetwork.calls.size
      end

      # A stand-in for an acts_as_chat record (see model_test.rb).
      class ProtocolRecord
        include Model

        attr_reader :id
        attr_accessor :model_id, :provider, :protocol, :assume_model_exists, :context

        def initialize(model_id, id)
          @model_id = model_id
          @id = id
        end

        def to_llm = raise("not used")
      end

      def test_the_model_concern_uses_the_record_protocol
        ProtocolRecord.has_infinite_context(compactor: MODEL, compactor_options: @completions)
        record = ProtocolRecord.new(MODEL, 41)
        record.provider = "openai"
        record.assume_model_exists = true
        record.context = @context
        error = assert_refused { record.with_infinite_context(tokens: 1_000).turn("hi") }
        assert_match(/record/, error.message)

        record.protocol = "chat_completions" # acts_as_chat stores a string
        record.with_infinite_context(tokens: 1_000).turn("hi")
        assert_equal ["/v1/chat/completions"], paths.uniq
      end
    end
  end
end
