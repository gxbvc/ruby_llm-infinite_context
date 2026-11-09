# frozen_string_literal: true

# Spend enforcement for paid benchmark rounds.
#
# What this enforces, and how:
#
# - A durable LEDGER (a JSON file, flock-guarded) is the one tally for the
#   total spend cap (default $20 combined across all models and runs).
#   Public and private model runs must point at the same ledger file.
# - Before EVERY provider request, a before_request hook on the chat
#   computes a WORST-CASE cost from the rendered payload and RESERVES it in
#   the ledger. If the reservation does not fit under the cap, the hook
#   raises and RubyLLM never sends the request. After the reply, the
#   reservation is settled to the metered cost.
# - The worst case is: payload bytes (a token is never more than one byte)
#   at the input price, plus the bounded max output at the output price,
#   plus a fixed hidden-input margin (default 2,000 tokens at the input
#   price) for tokens the provider adds that we cannot see (a tool-use
#   system prompt, a chat template), all times (transport retries + 1),
#   because RubyLLM retries POSTs below the chat hooks. The max output
#   bound is set by us and read back from the rendered payload; a payload
#   without it is refused.
# - The retry count comes from the chat's own provider connection (the
#   config object that connection was built with; a RubyLLM context can
#   differ from the global config), never from the global config alone. An
#   expected count passed to the guard must equal it, or arming fails.
# - Settlement prices input tokens the provider reports as cached at an
#   explicit cached_input price (when the price entry has one; else at the
#   input price). Reservations are never discounted. A reply that reports
#   more input tokens than the request could hold halts the guard, so a
#   cache discount cannot hide an inflated count.
# - Settlement has two modes. :metered settles down to the reply's
#   metered cost (when retries are 0). :reservation never settles below the
#   reservation: reserve = final spend. A metered cost is registry price x
#   reported usage, not the provider's bill, so the smoke round uses
#   :reservation.
# - Unknown or non-positive pricing, a reply without a metered cost, a
#   reply that costs more than its reservation, fallbacks, and too many
#   requests in one chat all fail closed and HALT the guard.
# - A reservation is never released: a request that failed after it was
#   reserved stays counted at its worst case, because we cannot know
#   whether the provider billed it.
#
# What this does NOT prove (stated so nobody reads it as more):
# - Provider billing is trusted to honor the max output bound (reasoning
#   tokens included) and to match registry prices; "a token is at most one
#   byte" is an assumption about tokenizers.
# - It covers chats armed through Guard#arm. Calls made any other way are
#   not counted. The bench builds every chat, the pump's included, through
#   one armed factory.
# - The reservation is sized from the payload as the guard's own hook sees
#   it. A before_request hook added to the chat AFTER arming can still
#   rewrite the payload (pinned by a test). The bench adds no other hooks.
# - Tests drive real RubyLLM chats over a fake network; nothing here has
#   been run against a live provider.

require "json"
require "fileutils"
require "time"
require_relative "fireworks_route"

module Bench
  class Error < StandardError; end
  class CapExceeded < Error; end
  class UnknownPricing < Error; end
  class Unmetered < Error; end
  class Overrun < Error; end
  class UnboundedOutput < Error; end
  class Halted < Error; end

  # The default total spend cap: $20 TOTAL across all models, both layers
  # and every run that shares the ledger. A larger cap needs a code change
  # and a new ledger started by a person.
  CAP_LIMIT = 20.0

  MICRO = 1_000_000

  # Exact decimal value of a dollar amount: 0.001 is 1/1000, not the binary
  # float's long fraction, which sits a hair above it. Raises on NaN or
  # Infinity (ArgumentError), which callers treat as a failure.
  def self.exact(usd)
    usd.is_a?(Float) ? Rational(usd.to_s) : usd.to_r
  end

  # Costs round UP (never undercount); the cap rounds DOWN (never overstate).
  def self.usd_to_micro_up(usd) = (exact(usd) * MICRO).ceil

  def self.usd_to_micro_down(usd) = (exact(usd) * MICRO).floor

  def self.micro_to_usd(micro) = micro / MICRO.to_f

  # The durable round ledger. Amounts are integer micro-dollars rounded UP.
  class Ledger
    attr_reader :path, :cap_micro

    def self.default_path
      File.join(Dir.home, ".local", "state", "ruby_llm-infinite_context", "bench-ledger.json")
    end

    # Opens (creating) the ledger. ONE file holds all bench runs: whoever
    # creates it, the recorded total cap is the default CAP_LIMIT ($20), and
    # it only changes if a person edits the file down. A requested cap above
    # the recorded one is refused; a lower one limits this instance only (it
    # is never written back). Per-run limits (the smoke run's $0.90) belong
    # to the Guard (run_cap_usd), not to the ledger, so every run's spend is
    # visible to every later run with no manual step.
    def initialize(path, cap_usd: CAP_LIMIT)
      raise Error, "cap #{cap_usd} is over the default $#{CAP_LIMIT} total cap" if cap_usd > CAP_LIMIT
      raise Error, "cap must be positive" unless cap_usd.positive?

      @path = path
      @mutex = Mutex.new
      FileUtils.mkdir_p(File.dirname(path))
      requested = Bench.usd_to_micro_down(cap_usd)
      with_lock(write: true) do |data|
        data["cap_micro"] ||= Bench.usd_to_micro_down(CAP_LIMIT)
        if requested > data["cap_micro"]
          raise Error, "requested cap $#{cap_usd} is over this ledger's recorded cap " \
                       "$#{Bench.micro_to_usd(data["cap_micro"])}; a new ledger needs a person"
        end
        @cap_micro = [data["cap_micro"], requested].min
      end
    end

    def committed_micro = with_lock { |data| committed_of(data) }

    def remaining_micro = cap_micro - committed_micro

    def entries = with_lock { |data| data["entries"].map(&:dup) }

    # Reserves `micro` or raises CapExceeded; nothing is written then.
    def reserve!(micro, label:, model:)
      with_lock(write: true) do |data|
        committed = committed_of(data)
        if committed + micro > cap_micro
          raise CapExceeded, "reserve of $#{Bench.micro_to_usd(micro)} does not fit: " \
                             "committed $#{Bench.micro_to_usd(committed)} of $#{Bench.micro_to_usd(cap_micro)}"
        end
        id = (data["entries"].map { |e| e["id"] }.max || 0) + 1
        data["entries"] << {"id" => id, "label" => label, "model" => model,
                             "reserved_micro" => micro, "settled_micro" => nil, "at" => Time.now.utc.iso8601}
        id
      end
    end

    # The per-request token counts the provider reported, stored on the
    # entry as NUMBERS ONLY (TOKEN_FIELDS, each a non-negative Integer or
    # nil when the provider did not report it), so a report can show thinking
    # per request. Never text: any other value is dropped to nil, and no other
    # key is ever written. Called for every reply, before the guard's halt
    # checks, so a reply that halts the run is on the record too.
    TOKEN_FIELDS = %w[input cached cache_write output thinking].freeze

    def record_tokens!(id, counts)
      clean = TOKEN_FIELDS.to_h do |field|
        value = counts[field] || counts[field.to_sym]
        [field, (value.is_a?(Integer) && !value.negative?) ? value : nil]
      end
      with_lock(write: true) do |data|
        entry = data["entries"].find { |e| e["id"] == id } or raise Error, "no ledger entry #{id}"
        entry["tokens"] = clean
      end
      clean
    end

    # Replaces the reservation with the metered amount. A reply costing more
    # than its reservation is recorded in full and raises Overrun.
    def settle!(id, micro)
      overrun = nil
      with_lock(write: true) do |data|
        entry = data["entries"].find { |e| e["id"] == id } or raise Error, "no ledger entry #{id}"
        overrun = micro > entry["reserved_micro"]
        entry["settled_micro"] = micro
      end
      raise Overrun, "reply cost $#{Bench.micro_to_usd(micro)} exceeded its reservation (entry #{id})" if overrun

      micro
    end

    private

    def committed_of(data)
      data["entries"].sum { |e| e["settled_micro"] || e["reserved_micro"] }
    end

    # Read-modify-write under an exclusive lock: an in-process mutex plus a
    # flock on a sidecar file, so threads and processes both serialize.
    def with_lock(write: false)
      @mutex.synchronize do
        File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          data = read
          result = yield data
          write(data) if write # an exception above skips the write
          result
        end
      end
    end

    # An unreadable or malformed ledger is never treated as empty: that
    # would silently reset the round's spend. Fail closed instead.
    def read
      return {"version" => 1, "entries" => []} unless File.exist?(@path)

      data = JSON.parse(File.read(@path))
      well_formed = data.is_a?(Hash) && data["entries"].is_a?(Array) &&
        (data["cap_micro"].nil? || data["cap_micro"].is_a?(Integer))
      raise Error, "ledger #{@path} is malformed; failing closed (a person must inspect it)" unless well_formed

      data
    rescue JSON::ParserError => e
      raise Error, "ledger #{@path} is unreadable (#{e.class}); failing closed (a person must inspect it)"
    end

    # Durable write: temp file, fsync, atomic rename, fsync the directory.
    # A crash leaves either the old ledger or the new one, never a torn
    # file; a leftover temp file is ignored.
    def write(data)
      tmp = "#{@path}.tmp.#{Process.pid}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(JSON.pretty_generate(data))
        f.flush
        f.fsync
      end
      File.rename(tmp, @path)
      File.open(File.dirname(@path)) { |dir| dir.fsync }
    end
  end

  # Fail-closed prices in USD per million tokens, as exact Rationals.
  module Pricing
    # cached_input: the price of input tokens the provider reports as cached
    # (a cache read). Only SETTLEMENT uses it; reservations always use the
    # uncached input price. Without an explicit one it equals input (no
    # discount is ever assumed).
    Rates = Data.define(:input, :output, :cached_input)

    module_function

    # overrides: { "model-id" => { "input" => 1.0, "output" => 5.0,
    # "cached_input" => 0.1 } } for models the RubyLLM registry does not
    # price (for example Fireworks). cached_input is optional.
    def resolve(model_id, overrides: {}, registry: nil)
      if (given = overrides[model_id] || overrides[model_id.to_s])
        return build(model_id, given["input"] || given[:input], given["output"] || given[:output],
          given["cached_input"] || given[:cached_input])
      end

      # Fireworks serverless prices are not ours to guess from a registry:
      # a Fireworks model needs an explicit price entry, always.
      if model_id.to_s.match?(/fireworks/i)
        raise UnknownPricing, "#{model_id} is a Fireworks model with no explicit price entry; " \
                              "failing closed (pass prices for it)"
      end

      registry ||= RubyLLM.models
      info = begin
        registry.find(model_id)
      rescue => e
        raise UnknownPricing, "no pricing for #{model_id} (#{e.class}); pass explicit prices"
      end
      text = info.pricing&.text_tokens
      build(model_id, text&.input, text&.output)
    end

    def build(model_id, input, output, cached_input = nil)
      [input, output].each do |price|
        unless price.is_a?(Numeric) && price.positive?
          raise UnknownPricing, "missing or non-positive price for #{model_id} " \
                                "(input #{input.inspect}, output #{output.inspect}); failing closed"
        end
      end
      unless cached_input.nil?
        unless cached_input.is_a?(Numeric) && cached_input.positive? && exact(cached_input) <= exact(input)
          raise UnknownPricing, "cached_input price for #{model_id} must be positive and at most the input price " \
                                "(cached_input #{cached_input.inspect}, input #{input.inspect}); failing closed"
        end
      end
      Rates.new(input: exact(input), output: exact(output), cached_input: exact(cached_input || input))
    end

    # Exact decimal: 0.15 is 3/20, not the binary float's long fraction.
    def exact(price) = Bench.exact(price)
  end

  # Arms chats so that no provider request starts without a reservation.
  class Guard
    OUTPUT_KEYS = %w[max_tokens max_completion_tokens max_output_tokens maxOutputTokens num_predict].freeze

    DEFAULT_INPUT_MARGIN_TOKENS = 2_000
    CACHE_WRITE_MULTIPLIER = 2 # Anthropic's highest cache-write rate (1h writes), applied to the input price
    SETTLEMENTS = %i[metered reservation].freeze

    attr_reader :ledger, :halted, :input_margin_tokens, :settlement, :forbid_thinking_tokens, :run_cap_micro

    # Micro-dollars this guard has reserved or settled in the shared ledger.
    def run_micro = @run_mutex.synchronize { @run_micro }

    # retries: the transport retry count the caller expects (for example 0).
    # nil means "use whatever the chat's provider connection has". A value
    # that differs from the connection's own makes arm fail closed.
    def initialize(ledger:, prices: {}, max_output_tokens: 1024, max_requests_per_chat: 14,
      retries: nil, registry: nil, input_margin_tokens: DEFAULT_INPUT_MARGIN_TOKENS,
      settlement: :metered, forbid_thinking_tokens: false, run_cap_usd: nil, request_scanner: nil)
      @ledger = ledger
      # Optional send-time scan: a callable given the exact JSON request body
      # (a String) before every request, before any reservation. It returns
      # nil when the body is clean, or a short FIXED reason String (never
      # request text) to halt the whole guard. An exception from it, or any
      # other return value, also halts (fail closed). See #scan_request!.
      unless request_scanner.nil? || request_scanner.respond_to?(:call)
        raise Error, "request_scanner must respond to call"
      end
      @request_scanner = request_scanner
      # A per-run sub-cap enforced here, on top of the shared ledger's total:
      # this guard's own reservations and settlements may not pass it. The
      # spend still lands in the one shared ledger, so a later run sees it.
      @run_mutex = Mutex.new
      @run_micro = 0
      @run_cap_micro = nil
      unless run_cap_usd.nil?
        unless run_cap_usd.is_a?(Numeric) && run_cap_usd.positive? && run_cap_usd <= CAP_LIMIT
          raise Error, "run_cap_usd must be positive and at most $#{CAP_LIMIT}"
        end
        @run_cap_micro = Bench.usd_to_micro_down(run_cap_usd)
      end
      # When true, a reply that reports any thinking/reasoning tokens halts
      # the guard (used with reasoning switched off, so a provider that does
      # not honor that is caught on its first reply).
      @forbid_thinking_tokens = forbid_thinking_tokens
      @input_margin_tokens = input_margin_tokens
      @settlement = settlement.to_sym
      unless SETTLEMENTS.include?(@settlement)
        raise Error, "settlement must be one of #{SETTLEMENTS.inspect}"
      end
      unless input_margin_tokens.is_a?(Integer) && !input_margin_tokens.negative?
        raise Error, "input_margin_tokens must be a non-negative integer"
      end
      @prices = prices
      @max_output_tokens = max_output_tokens
      @max_requests_per_chat = max_requests_per_chat
      @retries = retries
      @registry = registry
      @halted = nil
      raise Error, "max_output_tokens must be a positive integer" unless max_output_tokens.is_a?(Integer) && max_output_tokens.positive?
    end

    # Raises if the guard halted (an anomaly) or the ledger has no room.
    def check!
      raise Halted, "spend guard halted: #{@halted}" if @halted
    end

    def halt!(reason)
      @halted ||= reason
    end

    # The retry count the chat's transport will actually use: the larger of
    # its provider's config value and the value frozen into the provider's
    # Faraday connection settings. Both come from the chat's provider, so a
    # RubyLLM context with its own config is read correctly. Anything
    # unreadable fails closed.
    def transport_retries(chat)
      provider = chat.provider
      from_config = provider.config.max_retries
      settings = provider.connection.instance_variable_get(:@settings)
      from_connection = settings.respond_to?(:max_retries) ? settings.max_retries : nil
      values = [from_config, from_connection]
      unless values.all? { |v| v.is_a?(Integer) && v >= 0 }
        raise Error, "transport max_retries is unknown (config #{from_config.inspect}, " \
                     "connection #{from_connection.inspect}); failing closed"
      end

      values.max
    rescue NoMethodError => e
      raise Error, "cannot read the chat provider's transport retries (#{e.class}); failing closed"
    end

    # The largest max-output value the payload carries, searched through
    # nested hashes, or nil when none is present.
    def self.output_bound(payload)
      found = []
      walk = lambda do |node|
        case node
        when Hash
          node.each do |key, value|
            found << value if OUTPUT_KEYS.include?(key.to_s) && value.is_a?(Integer)
            walk.call(value)
          end
        when Array then node.each { |v| walk.call(v) }
        end
      end
      walk.call(payload)
      found.max
    end

    # The worst-case reservation, in micro-dollars, for one rendered request.
    # output_tokens: the worst-case output to reserve (the output bound; for
    # a chat with a reasoning budget, see #arm).
    def reserve_micro(payload, rates, retries, output_tokens: @max_output_tokens)
      input_tokens = JSON.generate(payload).bytesize # a token is at most a byte
      input_tokens += @input_margin_tokens # provider-added tokens we cannot see
      per_attempt = (input_tokens * rates.input + output_tokens * rates.output) / MICRO
      (per_attempt * (retries + 1) * MICRO).ceil + 1
    end

    # The enforced bound on reported thinking tokens for a chat with a
    # reasoning budget: the max output sent (max_output_tokens + budget). The
    # budget itself is a soft cap, so it is NOT the bound. One definition, used
    # by #arm and by the smoke plan and tests (1,280 for 256 + 1,024).
    def thinking_bound_for(budget) = @max_output_tokens + budget

    # The output tokens a budgeted chat reserves: the max sent plus thinking up
    # to the thinking bound (2,560 for 256 + 1,024).
    def reserved_output_tokens_for(budget) = (@max_output_tokens + budget) + thinking_bound_for(budget)

    # Arms `chat`: bounds its output, forbids fallbacks, and installs the
    # reserve-before-request and settle-after-reply hooks. Returns the chat.
    #
    # reasoning_budget_tokens: for a Fireworks chat built with a thinking
    # budget B (FireworksRoute.chat(thinking_budget: B)); nil otherwise.
    # Reasoning is then ON for this chat only, and:
    # - the body must carry exactly thinking {type: enabled, budget_tokens: B};
    # - max output sent = max_output_tokens + B, so the answer still fits if
    #   the provider counts reasoning inside max_tokens (the Fireworks
    #   Messages API docs say a thinking budget "counts towards your
    #   max_tokens limit"; the chat-completions docs do not say either way);
    # - B is sent as budget_tokens but is a SOFT cap: the live GLM run
    #   reported 1,036 thinking tokens against a 1,024 budget. So the
    #   enforced thinking bound is the max sent, not B;
    # - the reservation covers the max sent PLUS thinking up to that same
    #   bound (2 x max sent, 2,560 output tokens for 256 + 1,024), so it
    #   holds if the provider bills reasoning on top of max_tokens and the
    #   worst honest reply fits;
    # - a reply reporting more thinking tokens than the max sent, or more
    #   output tokens than the max sent, halts the guard; thinking tokens up
    #   to the max sent are allowed for this chat even when
    #   forbid_thinking_tokens is on for the guard (other chats keep it, and
    #   halt on any reasoning token).
    # An unbudgeted Fireworks chat keeps reasoning off and the old checks.
    def arm(chat, model:, label:, reasoning_budget_tokens: nil)
      check!
      budget = reasoning_budget_tokens
      unless budget.nil?
        unless FireworksRoute.fireworks_model?(model)
          raise Error, "a reasoning budget is only for Fireworks models (got #{model})"
        end
        FireworksRoute.check_budget!(budget)
      end
      chat_cap = budget ? @max_output_tokens + budget : @max_output_tokens
      thinking_bound = budget ? thinking_bound_for(budget) : 0
      reserve_output = budget ? reserved_output_tokens_for(budget) : @max_output_tokens
      rates = Pricing.resolve(model, overrides: @prices, registry: @registry)
      raise Error, "chat has fallbacks; a fallback model would bypass the reservation" unless chat.fallbacks.empty?

      armed_retries = transport_retries(chat)
      if @retries && @retries != armed_retries
        raise Error, "guard expects max_retries #{@retries} but the chat's provider connection has " \
                     "#{armed_retries}; failing closed"
      end

      # A Fireworks model must be on the one pinned route before
      # any request: chat-completions only, fixed model list, no storing
      # fields. Checked again on every rendered body below.
      fireworks = FireworksRoute.fireworks_model?(model)
      FireworksRoute.verify_chat!(chat, model) if fireworks

      chat.with_max_output_tokens(chat_cap)
      state = {requests: 0, open: nil, reserved: 0, retries: 0}

      chat.before_request do |payload|
        check!
        raise Error, "fallbacks were added to an armed chat" unless chat.fallbacks.empty?
        if state[:requests] >= @max_requests_per_chat
          halt!("chat made #{@max_requests_per_chat} requests (label #{label}); tool loop bound")
          check!
        end
        if fireworks
          begin
            FireworksRoute.verify_payload!(payload, thinking_budget: budget)
          rescue RouteRefused => e
            halt!(e.message)
            raise
          end
        end
        scan_request!(payload, label)
        bound = self.class.output_bound(payload)
        if bound.nil? || bound > chat_cap
          halt!("rendered payload carries no max-output bound within #{chat_cap} (found #{bound.inspect})")
          raise UnboundedOutput, @halted
        end

        attempts_retries = transport_retries(chat)
        if attempts_retries != armed_retries
          halt!("transport max_retries changed from #{armed_retries} to #{attempts_retries} after arming (label #{label})")
          check!
        end
        micro = reserve_micro(payload, rates, attempts_retries, output_tokens: reserve_output)
        state[:input_cap] = JSON.generate(payload).bytesize + @input_margin_tokens
        begin
          # An earlier unsettled reservation (a failed request) stays counted.
          state[:open] = reserve_in_run!(micro, label: label, model: model)
          state[:reserved] = micro
          state[:retries] = attempts_retries
          state[:requests] += 1
        rescue CapExceeded => e
          halt!(e.message)
          raise
        end
      end

      chat.after_message do |message|
        next unless message.respond_to?(:role) && message.role == :assistant && state[:open]

        id = state[:open]
        state[:open] = nil
        # A reply above the output bound, or one with reasoning tokens when
        # reasoning was switched off, means the provider did not honor the
        # bound we reserved against. Halt (the reservation stays counted).
        tokens = message.respond_to?(:tokens) ? message.tokens : nil
        if tokens
          ledger.record_tokens!(id, "input" => tokens.input, "cached" => tokens.cache_read, "cache_write" => tokens.cache_write,
            "output" => tokens.output, "thinking" => tokens.thinking)
        end
        if tokens&.output.is_a?(Integer) && tokens.output > chat_cap
          halt!("reply reported #{tokens.output} output tokens, above the #{chat_cap} bound (label #{label})")
        end
        if budget
          if tokens&.thinking.to_i > thinking_bound
            halt!("reply reported #{tokens.thinking} thinking tokens, above the #{thinking_bound} thinking bound " \
                  "(the max sent; budget #{budget} is soft) (label #{label})")
          end
        elsif @forbid_thinking_tokens && tokens&.thinking.to_i.positive?
          halt!("reply reported #{tokens.thinking} thinking tokens with reasoning off (label #{label})")
        end
        # A cached-token discount must not hide an inflated count: a reply
        # that reports more input tokens (fresh + cached + cache writes) than
        # the request could hold (its bytes plus the hidden-input margin)
        # halts the guard.
        if tokens && state[:input_cap]
          reported = tokens.input.to_i + tokens.cache_read.to_i + tokens.cache_write.to_i
          if reported > state[:input_cap]
            halt!("reply reported #{reported} input tokens, more than the request could hold (#{state[:input_cap]}) (label #{label})")
          end
        end
        total = metered_cost(message, tokens, model)
        unless total.is_a?(Numeric)
          halt!("reply had no metered cost (label #{label}); its reservation stays counted")
          next
        end
        # Settling down to the final reply's cost is only safe when the
        # transport cannot have retried: with retries > 0 a failed attempt
        # may have been billed and we cannot see it, so the whole worst-case
        # reservation stays counted (never less than the metered cost).
        actual = begin
          raise ArgumentError, "negative cost" if total.negative?

          Bench.usd_to_micro_up(total)
        rescue ArgumentError, FloatDomainError
          halt!("reply cost #{total.inspect} is not a finite non-negative number (label #{label}); its reservation stays counted")
          next
        end
        settled = if @settlement == :reservation || !state[:retries].to_i.zero?
          [actual, state[:reserved].to_i].max
        else
          actual
        end
        begin
          ledger.settle!(id, settled)
          adjust_run!(settled - state[:reserved].to_i)
        rescue Overrun => e
          adjust_run!(settled - state[:reserved].to_i) # recorded in full before it raised
          halt!(e.message)
        end
      end
      chat
    end

    private

    # Runs the request scanner (if any) on the exact body that will be sent.
    # A hit, a failure or an unexpected return halts the guard and raises
    # Halted before the request is reserved or sent. The halt reason is a
    # fixed text: it never contains the body, the match or the scanner's own
    # error message.
    def scan_request!(payload, label)
      return unless @request_scanner

      verdict = begin
        @request_scanner.call(JSON.generate(payload))
      rescue => e
        halt!("request scanner failed (#{e.class}); nothing was sent (label #{label})")
        check!
      end
      return if verdict.nil?

      reason = verdict.is_a?(String) ? verdict : "unexpected scanner result"
      halt!("request scanner refused the body: #{reason} (label #{label})")
      check!
    end

    # Reserves in the shared ledger, after checking this run's sub-cap. The
    # mutex makes the check and the reservation one step for this guard.
    def reserve_in_run!(micro, label:, model:)
      @run_mutex.synchronize do
        if @run_cap_micro && @run_micro + micro > @run_cap_micro
          raise CapExceeded, "reserve of $#{Bench.micro_to_usd(micro)} does not fit this run's sub-cap: " \
                             "run spend $#{Bench.micro_to_usd(@run_micro)} of $#{Bench.micro_to_usd(@run_cap_micro)}"
        end
        id = ledger.reserve!(micro, label: label, model: model)
        @run_micro += micro
        id
      end
    end

    def adjust_run!(delta) = @run_mutex.synchronize { @run_micro += delta }

    # The reply's cost in dollars. A model with an explicit price entry is
    # always costed from that entry and the reply's reported usage (the
    # registry is not trusted for it, and has no entry for Fireworks).
    # Input tokens the provider reports as cached (cache_read) are charged at
    # the entry's cached_input price (the full input price when the entry has
    # none); fresh input at the input price; cache-WRITE tokens at
    # CACHE_WRITE_MULTIPLIER (2x) the input price, Anthropic's highest write
    # rate (5-minute writes are 1.25x, 1-hour writes 2x), because the gem's
    # CacheMark can send Anthropic cache breakpoints, so writes are expected
    # and are charged, not refused; thinking tokens, if reported apart from
    # output, at the output price. The RESERVATION is never discounted: it
    # stays at the uncached worst case (input at the input price), so a reply
    # whose writes push the cost above it is recorded in full and halts the
    # guard (Overrun). Other models use RubyLLM's message cost.
    #
    # No new request field or header is involved: this reads the reply only.
    def metered_cost(message, tokens, model)
      if @prices[model] || @prices[model.to_s]
        return nil unless tokens && tokens.input.is_a?(Integer) && tokens.output.is_a?(Integer)

        rates = Pricing.resolve(model, overrides: @prices)
        fresh = tokens.input
        written = tokens.cache_write.to_i
        cached = tokens.cache_read.to_i
        output = tokens.output + tokens.thinking.to_i
        return (fresh * rates.input + written * CACHE_WRITE_MULTIPLIER * rates.input +
          cached * rates.cached_input + output * rates.output) / MICRO
      end
      message.cost&.total
    rescue
      nil
    end
  end
end
