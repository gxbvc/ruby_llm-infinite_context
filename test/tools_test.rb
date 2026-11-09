# frozen_string_literal: true

require "test_helper"

module RubyLLM
  module InfiniteContext
    # Regression: RubyLLM names a tool from its namespaced class, so the
    # model was shown "ruby_llm--infinite_context--tools--zoom" while every
    # prompt says "zoom". A real tool call for "zoom" came back as an
    # unavailable tool and no zoom ever ran. The old tests called #execute
    # directly and never went through the tool loop, so they could not see it.
    class ToolsTest < Minitest::Test
      def setup
        # Chat#render builds the exact request payload and sends nothing. A
        # chat needs a configured provider to exist at all: a placeholder key
        # and the loopback discard port, so nothing can leave the machine.
        @previous = {key: RubyLLM.config.anthropic_api_key, base: RubyLLM.config.anthropic_api_base}
        RubyLLM.configure do |c|
          c.anthropic_api_key = "placeholder-not-a-key"
          c.anthropic_api_base = "http://127.0.0.1:9"
        end
      end

      def teardown
        RubyLLM.configure do |c|
          c.anthropic_api_key = @previous[:key]
          c.anthropic_api_base = @previous[:base]
        end
      end

      def test_tool_classes_are_named_as_the_prompts_teach
        assert_equal "zoom", Tools::ZoomTool.tool_name
        assert_equal "read", Tools::ReadTool.tool_name
        assert_equal "date", Tools::DateTool.tool_name
      end

      def test_the_view_guide_names_the_same_tools
        %w[zoom read date].each { |name| assert_includes Prompts::VIEW_GUIDE, "#{name}(" }
      end

      def test_the_names_on_the_wire_are_the_names_the_model_is_taught
        tree = Tree.for("tools-wire", compactor: "x")
        tree.append(:user, "hello")
        chat = RubyLLM.chat(model: "claude-haiku-4-5").with_tools(*Tools.for_turn(tree, Turn.new))
        chat.add_message(role: :user, content: "q")
        names = chat.render[:tools].map { |tool| tool[:name] || tool["name"] }
        assert_equal %w[zoom read date], names
      end
    end
  end
end
