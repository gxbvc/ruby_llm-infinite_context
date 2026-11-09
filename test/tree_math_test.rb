# frozen_string_literal: true

require "test_helper"

module RubyLLM
  module InfiniteContext
    class TreeMathTest < Minitest::Test
      def test_first_last_label
        assert_equal 8, TreeMath.first(3, 1)
        assert_equal 16, TreeMath.last(3, 1)
        assert_equal "8+8", TreeMath.label(3, 1)
      end

      def test_cut_never_splits_a_utf8_character
        text = "a" * 10 + "é" # é is 2 bytes, so the text is 12 bytes
        assert_equal 12, TreeMath.bytes(text)
        assert_equal "a" * 10, TreeMath.cut(text, 11) # é does not fit
        assert_equal text, TreeMath.cut(text, 12)
        assert_equal text, TreeMath.cut(text, 100)
      end

      def test_flat_makes_one_line
        assert_equal "a b c", TreeMath.flat("a\n b\nc")
      end

      def test_cap_keeps_head_and_tail
        text = "x" * 100
        capped = TreeMath.cap(text, 10)
        assert_includes capped, "characters cut"
        assert_equal "xxxxx\n[... 90 characters cut ...]\nxxxxx", capped
        assert_equal text, TreeMath.cap(text, 1000)
      end
    end
  end
end
