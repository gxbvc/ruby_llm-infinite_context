# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # search(words, before): finds the messages of THIS tree that contain the
    # words and returns their ids, dates and covering view lines. Never text:
    # the agent opens a hit with zoom(id, 1) or read(id, page), as before, so
    # search adds no new way to read the log. It only says where to look.
    #
    # The scan runs in Ruby over this tree's own entries (the rows zoom and
    # read can open), newest first, in batches of SEARCH_BATCH. It never
    # matches in SQL (no LIKE, no index): entry text can be encrypted at rest,
    # and an index would store plain text. It writes nothing, calls no model,
    # and keeps nothing between calls.
    #
    # Matching: text and words are NFKC-normalized and case-folded. A word
    # matches on word boundaries. A word of 5 or more letters (letters only)
    # also matches as a prefix ("deploy" matches "deployment"); a word with a
    # digit or a symbol matches a whole token only ("12345" never matches
    # inside "123456789").
    #
    # `mask` (the host's search_mask:) gets each entry's text and returns it
    # with flagged spans replaced. It runs BEFORE matching, so a value the
    # host's screen would refuse can never match. It must replace each
    # flagged span with spaces (or remove it): a replacement word such as
    # "[masked]" would itself be searchable and tell the agent where masked
    # values are. If it raises or returns something other than a String, that
    # entry does not match (fail closed) and the count is logged. It runs in
    # the calling thread; the time limit is checked after each message, so a
    # slow mask makes a search slow, and a mask that never returns blocks it.
    #
    # Every call logs one line of counts and a status (ok, cap, no_words,
    # bad_before), never words or text.
    #
    # The reply holds only what the agent can already see with its other
    # tools: message ids, the date the date tool gives, the label of the view
    # line that covers each message, and "all words" or "N of M words". No
    # kind or role, no other score, no length, no text, no query words.
    class Search
      # A "word character" for boundaries: letters, combining marks, numbers
      # and connector punctuation (underscore).
      WORD_CHAR = "[\\p{L}\\p{M}\\p{N}\\p{Pc}]"
      # A symbol: anything that is not a letter, a mark, a number or a space
      # ("." in "file.rb.old", "@" in an address, "#", "_"). The same set
      # EDGE trims from the ends of a query word.
      SYMBOL = "[^[:space:]\\p{L}\\p{M}\\p{N}]"
      # Largest `before:` used (bigger ids mean "no limit"); fits a 32-bit
      # integer column.
      MAX_BEFORE = 2**31 - 1
      # Longest query read; the rest is ignored (8 words never need more).
      MAX_QUERY = 1_000
      EDGE = /\A[^\p{L}\p{M}\p{N}]+|[^\p{L}\p{M}\p{N}]+\z/
      LETTERS = /\A[\p{L}\p{M}]+\z/
      HAS_ALNUM = /[\p{L}\p{N}]/

      def initialize(tree, turn, cap: SEARCH_CAP_PER_TURN, mask: nil, view: nil, logger: nil,
        scan_limit: SEARCH_SCAN_LIMIT, time_limit: SEARCH_TIME_LIMIT, clock: nil)
        @tree = tree
        @turn = turn
        @cap = Search.check_cap!(cap)
        @mask = Search.check_mask!(mask)
        @view = view&.map { |l, i| [Integer(l), Integer(i)] }
        @logger = logger
        @scan_limit = positive!(scan_limit, "search_scan_limit")
        @time_limit = positive!(time_limit, "search_time_limit")
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      end

      def self.check_mask!(mask)
        raise ArgumentError, "search_mask must respond to #call" unless mask.nil? || mask.respond_to?(:call)

        mask
      end

      def self.check_cap!(cap)
        raise ArgumentError, "search_cap must be a positive Integer" unless cap.is_a?(Integer) && cap.positive?

        cap
      end

      # The normalized form both the words and the text are compared in.
      def self.normalize(text)
        text = text.to_s
        if text.encoding == Encoding::BINARY
          text = text.dup.force_encoding(Encoding::UTF_8)
        elsif text.encoding != Encoding::UTF_8
          text = text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        end
        text.scrub.unicode_normalize(:nfkc).downcase(:fold).unicode_normalize(:nfkc)
      end

      # The query's distinct words (at most SEARCH_MAX_WORDS), normalized,
      # with symbols at their ends trimmed. Words shorter than 2 characters,
      # or with no letter or digit, are left out.
      def self.words(query)
        normalize(query.to_s[0, MAX_QUERY]).split(/[[:space:]]+/).map { |w| w.gsub(EDGE, "") }
          .select { |w| w.length >= 2 && w.match?(HAS_ALNUM) }.uniq
      end

      # The Regexp for one normalized word.
      # - Letters only, 5 or more: word boundary on the left, prefix allowed.
      # - Letters only, shorter: word boundaries on both sides.
      # - Any digit or symbol: a whole token. The word must be the whole
      #   space-separated token, apart from symbols at its ends (the same
      #   symbols a query word loses), so "12345" matches in "#12345," but
      #   not in "123456789", "12345.678", "12345..678" or "id::12345", and
      #   "file.rb" not in "file.rb.old".
      def self.pattern(word)
        escaped = Regexp.escape(word)
        unless word.match?(LETTERS)
          return Regexp.new("(?<![^[:space:]])#{SYMBOL}*#{escaped}#{SYMBOL}*(?![^[:space:]])")
        end

        tail = (word.length >= 5) ? "" : "(?!#{WORD_CHAR})"
        Regexp.new("(?<!#{WORD_CHAR})#{escaped}#{tail}")
      end

      # A message id for `before:`: a positive Integer, or a String of
      # digits. nil when it is not one.
      def self.before_id(value)
        id = case value
        when Integer then value
        when /\A\d+\z/ then Integer(value, 10)
        end
        id&.positive? ? [id, MAX_BEFORE].min : nil
      end

      def search(words, before = nil)
        started = @clock.call
        unless before.nil?
          before = Search.before_id(before)
          return refuse("bad_before", started, "before must be a message id (a whole number above 0).") unless before
        end
        list = Search.words(words)
        if list.empty?
          return refuse("no_words", started, "Give one to #{SEARCH_MAX_WORDS} words of 2 or more characters.")
        end
        unless @turn.claim_search!(@cap)
          return refuse("cap", started, "Search cap reached for this turn (#{@cap} searches). " \
            "Use zoom on the lines you have.")
        end

        trimmed = list.size > SEARCH_MAX_WORDS
        list = list.first(SEARCH_MAX_WORDS)
        scan(list.map { |w| Search.pattern(w) }, before, trimmed, started)
      end

      private

      Hit = Struct.new(:idx, :at, :score)

      def refuse(status, started, message)
        log("search: status=#{status} ms=#{((@clock.call - started) * 1000).round}")
        message
      end

      def scan(patterns, before, trimmed, started)
        full = []
        partial = []
        more_full = false
        scanned = 0
        mask_errors = 0
        top = nil
        low = nil
        stop = nil
        scope = @tree.entries
        cursor = before

        loop do
          older = cursor ? scope.where(idx: ...cursor) : scope
          # Stop before loading a batch past a limit; say so only when
          # older messages are left (a count-free existence check).
          if scanned >= @scan_limit || @clock.call - started >= @time_limit
            stop = (scanned >= @scan_limit) ? :scan : :time if older.exists?
            break
          end

          size = [SEARCH_BATCH, @scan_limit - scanned].min
          batch = older.order(idx: :desc).limit(size).select(:id, :idx, :created_at, :text).to_a
          break if batch.empty?

          batch.each do |entry|
            # Checked again after each message, because the mask can be slow.
            if @clock.call - started >= @time_limit
              stop = :time
              break
            end

            scanned += 1
            top ||= entry.idx
            low = cursor = entry.idx
            text = masked(entry.text)
            if text.nil?
              mask_errors += 1
              next
            end

            normalized = Search.normalize(text)
            score = patterns.count { |p| p.match?(normalized) }
            next if score.zero?

            hit = Hit.new(entry.idx, entry.created_at, score)
            if score == patterns.size
              (full.size < SEARCH_RESULTS) ? full << hit : more_full = true
            else
              keep_best(partial, hit)
            end
          end
          break if stop || batch.size < size

          cursor = batch.last.idx
        end

        ms = ((@clock.call - started) * 1000).round
        log("search: status=ok words=#{patterns.size} scanned=#{scanned} hits=#{full.size}#{"+" if more_full} " \
          "partial=#{partial.size} mask_errors=#{mask_errors} stopped=#{stop || "no"} ms=#{ms}")
        reply(full, partial.first(SEARCH_RESULTS - full.size), patterns.size, more_full, stop, top, low, trimmed)
      end

      # Partial hits, best first (score, then newest); at most SEARCH_RESULTS.
      # Hits arrive newest first, so a stable insert after equal scores keeps
      # the newest first within a score.
      def keep_best(list, hit)
        at = list.index { |h| h.score < hit.score } || list.size
        return if at >= SEARCH_RESULTS

        list.insert(at, hit)
        list.pop if list.size > SEARCH_RESULTS
      end

      def masked(text)
        return text.to_s unless @mask

        out = @mask.call(text.to_s)
        out.is_a?(String) ? out : nil
      rescue
        nil
      end

      def reply(full, partial, nwords, more_full, stop, top, low, trimmed)
        parts = []
        parts << "Only the first #{SEARCH_MAX_WORDS} words were used." if trimmed
        if full.empty? && partial.empty?
          parts << "No message contains these words. Try other words, or zoom into the view."
        else
          parts << "Messages with all words: #{full.map { |h| item(h, nil) }.join(", ")}." unless full.empty?
          unless partial.empty?
            parts << "Messages with some of the words: #{partial.map { |h| item(h, "#{h.score} of #{nwords} words") }.join(", ")}."
          end
          parts << "More messages with all words are older: search again with before: #{full.last.idx}." if more_full
          parts << "Use zoom(id, 1) to read one."
        end
        if stop && top.nil?
          parts << "The search stopped at its time limit before it searched any message."
        elsif stop
          parts << "The search stopped at its #{(stop == :scan) ? "message" : "time"} limit: it searched messages " \
            "#{top} down to #{low} only. Search again with before: #{low} for older ones."
        end
        parts.join(" ")
      end

      # "812 (Tue 2026-11-10 14:02 UTC, in line 768+64)": the id, the date as
      # the date tool gives it, and the covering view line when there is one.
      def item(hit, note)
        fields = [note, hit.at.strftime(DATE_FORMAT), covering(hit.idx)].compact
        "#{hit.idx} (#{fields.join(", ")})"
      end

      def covering(idx)
        part = @view&.find { |l, i| TreeMath.first(l, i) <= idx && idx < TreeMath.last(l, i) }
        part && "in line #{TreeMath.label(*part)}"
      end

      def log(message)
        return unless @logger

        @logger.respond_to?(:call) ? @logger.call(message) : @logger.info("[infinite_context] #{message}")
      rescue
        nil
      end

      def positive!(value, name)
        raise ArgumentError, "#{name} must be positive" unless value.is_a?(Numeric) && value.positive?

        value
      end
    end
  end
end
