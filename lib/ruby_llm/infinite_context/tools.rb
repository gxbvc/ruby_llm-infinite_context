# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # The agent's tools, as RubyLLM::Tool classes. Instances carry the tree
    # and the turn, so one Turn guards and caps the zooms of one reply.
    require "ruby_llm/tool"

    module Tools
      # zoom(id, n): open the line covering messages id..id+n-1 into the two
      # lines it was built from; zoom(id, 1) shows message id itself.
      class ZoomTool < ::RubyLLM::Tool
        # RubyLLM derives a name from the namespaced class
        # (ruby_llm--infinite_context--tools--zoom), but the prompts and the
        # view guide say "zoom". The model must see the name we teach it.
        def self.tool_name = "zoom"

        description "Open a line of the conversation view. zoom(id, n) returns the two " \
                    "half-size lines the line covering messages id..id+n-1 was built from. " \
                    "zoom(id, 1) shows message id in full. Zoom before you guess: when a " \
                    "summary only mentions something you need, open the line that mentions it."
        parameter :id, type: "integer", description: "Start message index of the line"
        parameter :n, type: "integer", description: "Number of messages the line covers (a power of 2); 1 for a single message"

        def initialize(handler)
          @handler = handler
        end

        def execute(id:, n:) = @handler.zoom(id, n)
      end

      # read(id, page): the next page of a long message.
      class ReadTool < ::RubyLLM::Tool
        def self.tool_name = "read"

        description "Read a further page of a long message. zoom(id, 1) shows its first page."
        parameter :id, type: "integer", description: "Message index"
        parameter :page, type: "integer", description: "Page number, starting at 2"

        def initialize(handler)
          @handler = handler
        end

        def execute(id:, page: 2) = @handler.read(id, page)
      end

      # date(id): when a message was written.
      class DateTool < ::RubyLLM::Tool
        def self.tool_name = "date"

        description "Date and time a message was written."
        parameter :id, type: "integer", description: "Message index"

        def initialize(handler)
          @handler = handler
        end

        def execute(id:) = @handler.date(id)
      end

      # The tool set for one turn: fresh instances per turn, because the
      # guard and the cap are per turn.
      def self.for_turn(zoom_handler, turn)
        [ZoomTool.new(Zoom.new(zoom_handler, turn)),
          ReadTool.new(Zoom.new(zoom_handler, turn)),
          DateTool.new(Zoom.new(zoom_handler, turn))]
      end
    end
  end
end
