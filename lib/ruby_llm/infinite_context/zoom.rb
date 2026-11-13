# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # Per-turn state for the zoom tools: the lines opened so far, the zoom
    # count, the search count, and the turn's id (the `session` of a zoom
    # event).
    class Turn
      attr_reader :id, :opened

      def initialize(id = nil, cap: ZOOM_CAP_PER_TURN)
        @id = id || SecureRandom.uuid
        @cap = cap
        @opened = {}
        @zooms = 0
        @searches = 0
        @search_lock = Mutex.new
      end

      # True when the agent opened this label earlier in the turn.
      def repeat?(label) = @opened.key?(label)

      def open!(label, text)
        @opened[label] = text
        @zooms += 1
      end

      def cap_reached? = @zooms >= @cap
      def remaining = @cap - @zooms

      attr_reader :zooms

      # Searches run this turn (memory only, no write).
      attr_reader :searches

      # Takes one search of the turn's `cap` (Search's own cap, separate from
      # the zoom cap). False when none is left. One step under a lock, so
      # tool calls at the same time cannot pass the cap.
      def claim_search!(cap)
        @search_lock.synchronize do
          return false if @searches >= cap

          @searches += 1
          true
        end
      end
    end

    # The agent's memory tools: zoom, read (paging through a long message)
    # and date. `#zoom` refuses repeats ("you already opened this line") and
    # enforces the per-turn cap, and records counters and zoom events.
    class Zoom
      include TreeMath

      def initialize(tree, turn)
        @tree = tree
        @turn = turn
      end

      def zoom(id, n)
        id = Integer(id)
        n = Integer(n)
        total = @tree.entry_count
        return "No line #{id}+#{n}." unless valid?(id, n, total)

        return leaf(id) if n == 1

        # The line opened is node (level + 1, id / n), labelled "id+n" as in
        # the view. The repeat check, the cap and the counters all use it;
        # the two children it shows are separate lines the agent may open next.
        opened_level = level_of(n) + 1
        opened_i = id / n
        label = TreeMath.label(opened_level, opened_i)
        return already_opened(label) if @turn.repeat?(label)
        return cap_message if @turn.cap_reached?

        @turn.open!(label, true)
        level = level_of(n)
        left = left_of(id, n)
        text = [left, left + 1].map do |i|
          child = @tree.node_text(level, i)
          child ? "#{TreeMath.label(level, i)}|#{TreeMath.flat(child)}" : "#{TreeMath.label(level, i)}|#{PLACEHOLDER}"
        end.join("\n")
        @tree.record_zoom!(level: opened_level, i: opened_i, leaf_idx: nil, steps: @turn.zooms, session: @turn.id)
        text
      rescue ArgumentError, TypeError
        "No line #{id}+#{n}."
      end

      # A page of one message, for messages longer than one page.
      def read(id, page = 1)
        id = Integer(id)
        page = Integer(page)
        entry = @tree.entry(id)
        return "No message #{id}." unless entry && page.positive?

        text = entry.text.to_s
        pages = (TreeMath.bytes(text).to_f / PAGE).ceil
        return "Message #{id} has 1 page; it is shown in full by zoom(#{id}, 1)." if pages <= 1 || page > pages

        slice = text.byteslice((page - 1) * PAGE, PAGE).to_s
        suffix = (page < pages) ? "\n[page #{page} of #{pages}; read(#{id}, #{page + 1}) for more]" : "\n[end of message #{id}]"
        "#{slice}#{suffix}"
      rescue ArgumentError, TypeError
        "No message #{id}."
      end

      def date(id)
        entry = @tree.entry(Integer(id))
        return "No message #{id}." unless entry

        entry.created_at.strftime(DATE_FORMAT)
      rescue ArgumentError, TypeError
        "No message #{id}."
      end

      private

      # One message in full (paged when long). Reaching the leaf is what the
      # counters count: the leaf reached and the steps the dig cost.
      def leaf(id)
        label = TreeMath.label(0, id)
        return already_opened(label) if @turn.repeat?(label)
        return cap_message if @turn.cap_reached?

        entry = @tree.entry(id)
        return "No line #{id}+1." unless entry

        @turn.open!(label, true)
        @tree.record_zoom!(level: 0, i: id, leaf_idx: id, steps: @turn.zooms, session: @turn.id)
        text = entry.text.to_s
        if TreeMath.bytes(text) > PAGE
          pages = (TreeMath.bytes(text).to_f / PAGE).ceil
          "#{text.byteslice(0, PAGE)}\n[page 1 of #{pages}; read(#{id}, 2) for more]"
        else
          text
        end
      end

      def already_opened(label)
        "You already opened line #{label} this turn; its text is above. Use what you have."
      end

      def cap_message
        "Zoom cap reached for this turn (#{@turn.opened.size} lines opened). " \
          "Work with the lines you have and say what you still need in your reply."
      end

      def valid?(id, n, total)
        n.positive? && (n & (n - 1)).zero? && (id % n).zero? && id >= 0 && id + n <= total
      end

      def level_of(n) = n.bit_length - 2

      def left_of(id, n) = 2 * id / n
    end
  end
end
