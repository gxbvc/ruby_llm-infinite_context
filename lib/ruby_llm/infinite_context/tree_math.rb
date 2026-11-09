# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # Shared node math and byte helpers.
    #
    # Node (level, i) covers entries [first, last) of the append-only log,
    # where first = i << level and last = (i + 1) << level. Its label,
    # "id+n", names the stretch in the view and in the zoom tools.
    module TreeMath
      module_function

      def first(level, i) = i << level

      def last(level, i) = (i + 1) << level

      def label(level, i) = "#{first(level, i)}+#{1 << level}"

      def bytes(text) = text.to_s.bytesize

      # First `limit` bytes of text, never splitting a UTF-8 character.
      def cut(text, limit)
        text.byteslice(0, limit).scrub("").delete_suffix("\uFFFD")
      end

      # One line: whitespace runs around a newline become one space.
      def flat(text) = text.to_s.gsub(/\s*\n\s*/, " ")

      # Head and tail of an over-long text, with a note of what was cut.
      def cap(text, limit = CAP)
        return text if text.length <= limit

        half = limit / 2
        cut_chars = text.length - 2 * half
        "#{text[0, half]}\n[... #{cut_chars} characters cut ...]\n#{text[-half..]}"
      end
    end
  end
end
