# frozen_string_literal: true

require "test_helper"
require "support/fake_network"

module RubyLLM
  module InfiniteContext
    # protocol:/provider: passthrough for the chats the gem builds itself.
    # RubyLLM 2.1.1 defaults the OpenAI provider to the Responses API
    # (POST {base}/responses); Fireworks and other OpenAI-compatible
    # services need `protocol: :chat_completions`. Real RubyLLM chats over
    # the in-process fake network; no key, no socket.
    class ChatOptionsTest < Minitest::Test
      MODEL = "accounts/fireworks/models/glm-5p3-flash"
      BASE = "http://127.0.0.1:9/v1" # the fake network; a stand-in for any OpenAI-compatible base

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
      end

      def teardown
        InfiniteContext.compactor_chat_options = @saved_global
        FakeNetwork.restore!(@previous)
      end

      def long_tree(key)
        tree = Tree.for(key, compactor: MODEL)
        tree.append(:user, "entry " + "long " * 300) # over NODE: needs a model call
        tree
      end

      def paths = FakeNetwork.calls.map { |c| URI(c[:url]).path }

      # -- options ---------------------------------------------------------------

      def test_unknown_options_are_refused_so_a_typo_cannot_pick_the_wrong_api
        error = assert_raises(ArgumentError) { ChatOptions.normalize(protcol: :chat_completions) }
        assert_match(/unknown chat option/, error.message)
        assert_raises(ArgumentError) { Compactor.new(Object.new, model: MODEL, chat_options: {protocl: 1}) }
        assert_raises(ArgumentError) { InfiniteContext.compactor_chat_options = {nope: 1} }
        assert_equal({protocol: :chat_completions}, ChatOptions.normalize("protocol" => :chat_completions))
        assert_equal({}, ChatOptions.normalize(nil))
      end

      # -- the default, pinned so the README claim stays true -------------------

      def test_without_protocol_the_openai_provider_posts_to_responses
        tree = long_tree("co-default")
        # The fake reply is chat-completions shaped, so the Responses parser
        # finds no text; only the request that was sent matters here.
        assert_raises(InfiniteContext::Error) { Compactor.new(tree, model: MODEL, chat_options: @wired).build(0, 0) }
        assert_equal ["/v1/responses"], paths.uniq
        assert_includes FakeNetwork.calls.first[:body].keys, "input"
        refute_includes FakeNetwork.calls.first[:body].keys, "messages"
      end

      # -- the compactor -----------------------------------------------------------

      def test_compactor_chat_options_pass_protocol_through_to_chat_completions
        tree = long_tree("co-compactor")
        text, tries = Compactor.new(tree, model: MODEL, chat_options: @completions).build(0, 0)
        assert_equal "a short summary line", text
        assert_equal 1, tries
        assert_equal ["/v1/chat/completions"], paths.uniq
        body = FakeNetwork.calls.first[:body]
        assert_equal MODEL, body["model"]
        assert_includes body.keys, "messages"
        refute_includes body.keys, "input"
        refute_includes body.keys, "store"
      end

      def test_an_explicit_chat_factory_still_wins
        tree = long_tree("co-factory")
        built = 0
        factory = lambda do
          built += 1
          ChatOptions.build(MODEL, @completions)
        end
        Compactor.new(tree, model: MODEL, chat_factory: factory, chat_options: @wired).build(0, 0)
        assert_equal 1, built
        assert_equal ["/v1/chat/completions"], paths.uniq
      end

      def test_the_global_compactor_chat_options_reach_the_pump_default_builder
        InfiniteContext.compactor_chat_options = @completions
        tree = long_tree("co-pump-global")
        Pump::Runner.new(tree, jobs: 1).run
        refute_empty FakeNetwork.calls
        assert_equal ["/v1/chat/completions"], paths.uniq
      end

      def test_pump_runner_chat_options_beat_the_global_default
        InfiniteContext.compactor_chat_options = @wired # would be /responses
        tree = long_tree("co-pump-local")
        Pump::Runner.new(tree, jobs: 1, chat_options: @completions).run
        assert_equal ["/v1/chat/completions"], paths.uniq
      end

      def test_batch_import_builds_its_chats_with_the_options
        tree = long_tree("co-batch")
        import = BatchImport.new(tree, model: MODEL, chat_options: @completions)
        chat = import.send(:new_chat)
        assert_equal :chat_completions, chat.instance_variable_get(:@protocol)
        assert_equal BASE, chat.provider.api_base
        assert_empty FakeNetwork.calls, "building the chat sends nothing"
      end

      # -- attach ---------------------------------------------------------------------

      def test_attach_passes_chat_options_and_compactor_options_for_every_request
        mem = InfiniteContext.attach("accounts/fireworks/models/deepseek-v4p1-flash", key: "co-attach",
          compactor: MODEL, chat_options: @completions, compactor_options: @completions)
        mem.turn("start " + "long " * 300)
        assert_operator FakeNetwork.calls.size, :>=, 2, "the chat turn and at least one compactor call"
        assert_equal ["/v1/chat/completions"], paths.uniq
        models = FakeNetwork.calls.map { |c| c[:body]["model"] }
        assert_includes models, "accounts/fireworks/models/deepseek-v4p1-flash"
        assert_includes models, MODEL
        assert(FakeNetwork.calls.all? { |c| c[:body].key?("messages") })
      end

      def test_attach_without_options_keeps_the_ruby_llm_default_wire
        mem = InfiniteContext.attach(RubyLLM.chat(model: "claude-haiku-4-5"), key: "co-attach-default", pump: :none)
        assert_kind_of Manager, mem
        FakeNetwork.reset!
        FakeNetwork.default_reply = FakeNetwork.text_reply("hello")
        mem.turn("hi")
        assert_equal ["/v1/messages"], paths.uniq.map { |p| p.sub(%r{\A/v1}, "/v1") }.uniq
      end

      def test_module_level_attach_is_the_manager_attach
        assert_respond_to InfiniteContext, :attach
        mem = InfiniteContext.attach(RubyLLM.chat(model: "claude-haiku-4-5"), key: "co-attach-mod", pump: :none)
        assert_equal "co-attach-mod", mem.tree.key
      end
    end
  end
end
