# frozen_string_literal: true

# LIVE SMOKE TEST. DISABLED BY DEFAULT: ONLY --plan RUNS.
#
# What it does when a person turns it on: send a few dozen REAL
# requests to three models, to see that the spend guard, the pinned
# Fireworks route and the pump work against live providers, at a total cost
# far below $1. It is a smoke test, not a benchmark: its scores mean nothing.
#
# Two switches keep it off. Only a person editing the code turns them on,
# and nothing else opens them:
#   1. SMOKE_ENABLED below (this file).
#   2. Bench::PAID_RUNS_ENABLED in run_bench.rb (the Runner refuses
#      without it).
# While they are false, `--plan` is the only mode that works. It prints the
# plan and the worst-case numbers, reads no key, opens no socket and
# creates no ledger.
#
#   bundle exec ruby bench/smoke_test.rb --plan        # free, no key, no network
#   bundle exec ruby bench/smoke_test.rb --run         # REFUSED while disabled
#
# Exact live command (after both switches are set to true):
#
#   bundle exec ruby bench/smoke_test.rb --run
#   bundle exec ruby bench/smoke_test.rb --run --models deepseek,glm   # Fireworks only
#
# --models takes short names (deepseek, haiku, glm) or full ids; the default
# is all three. The run order is always deepseek, haiku, glm, whatever the
# order given.
#
# Keys: read in-process from two files, never from the environment, and
# passed only to RubyLLM config (bench/key_file.rb checks each file on one
# open descriptor: regular file, owned by you, no group or other bits, at
# most 4,096 bytes, printable ASCII only, no whitespace except one trailing newline):
#
# (the bench's default key folder):
#
#   ~/.config/infinite-context-bench/anthropic.key   (only if haiku is selected)
#   ~/.config/infinite-context-bench/fireworks.key   (only if deepseek or glm is selected)
#
# Only the files the selected models need are opened. A bad or missing
# needed file refuses the run before the ledger, the corpus or any request.
#
# What is pinned:
#   corpus      synthetic, generated here by bench/generate_corpus.rb with
#               seed 2026 (1 session, 12 turns = 14 log entries, 12
#               questions). No real user data.
#   models      in this order: accounts/fireworks/models/deepseek-v4p1-flash
#               (reasoning_effort none is documented for it), then
#               claude-haiku-4-5 (Anthropic standard API-key path), then
#               accounts/fireworks/models/glm-5p3-flash, which runs ONLY
#               after one single-request gate. GLM-5.3 is thinking-only:
#               the live run got HTTP 400 "disabling thinking is not
#               supported" for reasoning_effort none. So GLM runs with
#               reasoning ON under a budget: the body carries the
#               documented thinking object {type: enabled, budget_tokens:
#               1024} (never together with reasoning_effort), the max
#               output sent is 256 + 1024, and the reservation covers that
#               max plus the budget again (see Guard#arm). The gate passes
#               only if Fireworks accepts the body and the reply reports
#               no more thinking tokens than the thinking bound (1,280, the
#               max sent; the budget is soft), is not cut off,
#               and has an answer. Any other model keeps reasoning off and
#               the guard halts everything on its first reasoning token.
#               Each model is both compactor and reader for its own pass.
#   NOTE        the GLM check and any halt stop the whole run: nothing
#               after a halt is sent.
#   sub-cap     the guard's run_cap_usd, $0.90 for this run (below).
#               It sits on top of the shared ledger; it is not a ledger.
#               The ledger is ONE file for all bench runs (default cap $20).
#   strategy    tree only, one budget (4,000 bytes).
#   prices      explicit for all three (below), each with its source page.
#   ledger      ~/.local/state/ruby_llm-infinite_context/bench-ledger.json,
#               the SAME file every bench run uses. Whoever creates it,
#               its total cap is the $20 default and it can only be lowered.
#               This run's spend lands in it, so a later round sees it and
#               is limited by it with no manual step.
#   guard       max_retries 0 (set on the Anthropic global config and on the
#               Fireworks context, and asserted equal at arm time),
#               input margin 2,000 tokens, settlement :reservation (reserve
#               = final spend), 256 max output tokens, reasoning off on
#               DeepSeek with a halt on any reported reasoning tokens; GLM
#               alone has reasoning on under its 1,024-token budget.
#   route       Fireworks: POST /inference/v1/chat/completions only, the
#               fixed model list, no storing or logging field
#               (bench/fireworks_route.rb).

module Bench
  SMOKE_ENABLED = false
  SMOKE_REFUSAL = "REFUSED: the live smoke test is disabled by default (SMOKE_ENABLED is false). Only --plan works. " \
                  "No key was read, no model was initialized and no call was made."

  # [mode, models_list_or_nil] for `--plan|--run [--models LIST]`, else nil.
  # Checked before any library loads.
  def self.smoke_args(argv)
    mode, *rest = argv
    return nil unless %w[--plan --run].include?(mode)
    return [mode, nil] if rest.empty?
    return [mode, rest[1]] if rest.size == 2 && rest[0] == "--models" && rest[1].match?(/\A[a-z0-9][a-z0-9,._\/-]*\z/)

    nil
  end
end

if __FILE__ == $PROGRAM_NAME
  args = Bench.smoke_args(ARGV)
  allowed = args && (args[0] == "--plan" || Bench::SMOKE_ENABLED)
  unless allowed
    abort(ARGV.empty? ? "usage: smoke_test.rb --plan | --run (--run is refused while disabled)" : Bench::SMOKE_REFUSAL)
  end
end

require "json"
require "fileutils"
require_relative "run_bench"
require_relative "key_file"
require_relative "generate_corpus"

module Bench
  module Smoke
    MAX_OUTPUT_TOKENS = 256
    INPUT_MARGIN_TOKENS = 2_000
    CAP_USD = 0.90
    SEED = 2026
    TURNS = 12
    BUDGET = 4_000
    OUT = File.expand_path("results-smoke", __dir__)

    # USD per million tokens, from the vendors' public price pages as read on
    # 2026-11-09. Prices change: re-read the page before a live run.
    KEY_DIR = File.join(Dir.home, ".config", "infinite-context-bench")
    KEY_FILES = {anthropic: "anthropic.key", fireworks: "fireworks.key"}.freeze

    # The ORDER is the run order. GLM runs last and only after the gate.
    GLM = "accounts/fireworks/models/glm-5p3-flash"
    # A multi-step counting problem that needs long reasoning, so one request
    # tests whether the thinking budget holds (a model that ignores the
    # budget would think past it or past the max sent). One checkable answer:
    # the multiples of 3 only (267) plus the multiples of 5 only (134) = 401.
    # The answer is printed and compared for the person reading the gate, but
    # a wrong answer does not fail the gate: it tests the budget, not skill.
    CHECK_PROMPT = "How many integers from 1 to 1000 inclusive are divisible by 3 or by 5, but not by both? " \
                   "Work it out step by step, then reply with only the number."
    CHECK_ANSWER = "401"
    GLM_REASONING_BUDGET = 1_024 # the documented minimum for thinking.budget_tokens
    # The budget is a SOFT cap (the live run reported 1,036 thinking tokens
    # against 1,024), so the enforced thinking bound is the max output sent:
    # 256 + 1,024 = 1,280. A reply above it halts the guard; the reservation
    # covers the max sent plus thinking up to the bound: 2,560 output tokens.
    # Guard#thinking_bound_for and #reserved_output_tokens_for compute the same
    # numbers; a test pins them equal.
    GLM_THINKING_BOUND = MAX_OUTPUT_TOKENS + GLM_REASONING_BUDGET
    GLM_RESERVED_OUTPUT_TOKENS = (MAX_OUTPUT_TOKENS + GLM_REASONING_BUDGET) + GLM_THINKING_BOUND

    MODELS = [
      {short: "deepseek", model: "accounts/fireworks/models/deepseek-v4p1-flash", input: 0.30, cached: 0.006, output: 1.20,
       source: "https://fireworks.ai/pricing, Highlighted Serverless rates, Standard tier " \
               "(DeepSeek V4.1 Flash: $0.30 input, $0.006 cached input, $1.20 output). " \
               "The model page at fireworks.ai/models/fireworks/deepseek-v4p1-flash returned 404 on " \
               "2026-11-09; the id is the one in the Fireworks serverless model list"},
      {short: "haiku", model: "claude-haiku-4-5", input: 1.00, cached: 0.10, output: 5.00,
       source: "https://platform.claude.com/docs/en/about-claude/pricing " \
               "(Claude Haiku 4.5: $1 / MTok base input, $0.10 / MTok cache read, $5 / MTok output)"},
      {short: "glm", model: GLM, input: 0.15, cached: 0.03, output: 0.50, gate: :single_request_reasoning_budget,
       reasoning_budget: GLM_REASONING_BUDGET,
       source: "https://fireworks.ai/pricing, Highlighted Serverless rates, Standard tier " \
               "(GLM 5.3 Flash: $0.15 input, $0.03 cached input, $0.50 output); same on " \
               "https://fireworks.ai/models/fireworks/glm-5p3-flash"}
    ].freeze

    module_function

    # The ONE ledger file for all bench runs (default cap $20), shared with run_bench.
    def ledger_path = Ledger.default_path

    # The models a --models list selects, in run order (never the order
    # given). nil selects all. Names are short names or full ids; an unknown
    # name, a duplicate or an empty list raises.
    def select_models(list)
      return MODELS if list.nil?

      names = list.is_a?(Array) ? list : list.to_s.split(",", -1)
      raise Error, "--models list is empty" if names.empty? || names.any?(&:empty?)

      picked = names.map do |name|
        MODELS.find { |m| m[:short] == name || m[:model] == name } or
          raise Error, "unknown model #{name.inspect}; known: #{MODELS.map { |m| m[:short] }.join(", ")}"
      end
      raise Error, "--models lists a model twice" if picked.uniq.size != picked.size

      MODELS.select { |m| picked.include?(m) }
    end

    # Which key files these models need: :anthropic for a non-Fireworks
    # model, :fireworks for a Fireworks one.
    def key_names(models)
      models.map { |m| FireworksRoute.fireworks_model?(m[:model]) ? :fireworks : :anthropic }.uniq
    end

    # Reads ONLY the key files the selected models need (bench/key_file.rb).
    # A file for an unselected model is not opened. Never the environment.
    def load_keys(dir: KEY_DIR, models: MODELS)
      key_names(models).to_h { |name| [name, KeyFile.read(File.join(dir, KEY_FILES.fetch(name)), label: name.to_s)] }
    end

    # Puts the keys where they are used and nowhere else: the Anthropic key on
    # the global RubyLLM config and the Fireworks key on its own context.
    # max_retries 0 on both, set explicitly and asserted equal by the guard
    # at arm time. Returns the Fireworks context (nil when no Fireworks
    # model is selected).
    def apply_keys(keys)
      RubyLLM.configure do |c|
        c.anthropic_api_key = keys[:anthropic] if keys.key?(:anthropic)
        c.max_retries = 0
      end
      FireworksRoute.context(api_key: keys.fetch(:fireworks), max_retries: 0) if keys.key?(:fireworks)
    end

    # {model id => thinking budget} for the selected models that run with
    # reasoning ON (GLM only). Others run with reasoning off.
    def reasoning_budgets(models = MODELS)
      models.select { |m| m[:reasoning_budget] }.to_h { |m| [m[:model], m[:reasoning_budget]] }
    end

    # One request, no tools, with reasoning ON under a budget (the body
    # carries thinking {type: enabled, budget_tokens: B}; GLM-5.3 is
    # thinking-only and refuses reasoning_effort none, see MODELS). Passes
    # only if Fireworks accepts the body (a 4xx raises before this returns),
    # the reply reports usage, reports no more thinking tokens than the
    # thinking bound (GLM_THINKING_BOUND, the max sent; the budget is soft;
    # the guard halts the whole run otherwise), no more output tokens than
    # the max sent, was not cut off by the max, and has a non-empty answer. Returns what it observed, and prints it (before the
    # checks, so a refusal shows it too): thinking tokens against the budget,
    # so a person sees how GLM reports reasoning before the GLM pass runs.
    def glm_gate!(guard, fireworks_context, budget: GLM_REASONING_BUDGET)
      chat = FireworksRoute.chat(model: GLM, context: fireworks_context, thinking_budget: budget)
      guard.arm(chat, model: GLM, label: "smoke-glm-gate", reasoning_budget_tokens: budget)
      reply = chat.ask(CHECK_PROMPT)
      guard.check!
      tokens = reply.tokens
      unless tokens&.output.is_a?(Integer)
        raise Error, "GLM gate: the reply reported no usage; the GLM pass is not run"
      end
      answer = reply.content.to_s.strip
      puts "GLM gate: thinking #{tokens.thinking.to_i} of #{budget} budget tokens (#{(100.0 * tokens.thinking.to_i / budget).round}%; bound #{guard.thinking_bound_for(budget)}), " \
           "output #{tokens.output}, finish #{reply.finish_reason.inspect}, answer #{answer[0, 20].inspect} (expected #{CHECK_ANSWER})"
      if tokens.thinking.to_i > guard.thinking_bound_for(budget)
        raise Error, "GLM gate: #{tokens.thinking} thinking tokens, above the #{guard.thinking_bound_for(budget)} thinking bound " \
                     "(budget #{budget} is soft); the GLM pass is not run"
      end
      if reply.finish_reason.to_s == "max_tokens"
        raise Error, "GLM gate: the answer was cut off by max tokens (reasoning may count toward it); the GLM pass is not run"
      end
      raise Error, "GLM gate: empty answer; the GLM pass is not run" if answer.empty?

      {thinking_tokens: tokens.thinking.to_i, budget: budget, output_tokens: tokens.output,
       input_tokens: tokens.input, finish_reason: reply.finish_reason.to_s,
       thinking_inside_output: tokens.thinking.to_i <= tokens.output,
       answer_matches: answer.match?(/\b#{CHECK_ANSWER}\b/o)}
    end

    def prices = MODELS.to_h { |m| [m[:model], {"input" => m[:input], "cached_input" => m[:cached], "output" => m[:output]}] }

    def corpus
      entries, facts = Bench::Corpus.session(SEED, turns: TURNS)
      {entries: entries, questions: facts.map { |f| {"session" => 0, "question" => f[:question], "gold" => f[:gold]} }}
    end

    # Writes the generated corpus where Runner reads it.
    def write_corpus(dir)
      data = corpus
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "session-0000.jsonl"), data[:entries].map { |e| JSON.generate(e) }.join("\n"))
      File.write(File.join(dir, "questions.jsonl"), data[:questions].map { |q| JSON.generate(q) }.join("\n"))
      data
    end

    # Rough worst-case reservation (USD) for ONE request of a model, from
    # the guard's own formula. Real requests are measured by the ledger.
    def request_worst_case_usd(model, payload_bytes)
      guard = Guard.new(ledger: nil, prices: prices, max_output_tokens: MAX_OUTPUT_TOKENS,
        input_margin_tokens: INPUT_MARGIN_TOKENS, retries: 0, settlement: :reservation)
      rates = Pricing.resolve(model, overrides: prices)
      # A reasoning-budget chat reserves max + budget + budget (Guard#arm).
      budget = reasoning_budgets[model]
      output = budget ? guard.reserved_output_tokens_for(budget) : MAX_OUTPUT_TOKENS
      micro = guard.reserve_micro({"messages" => ["x" * payload_bytes]}, rates, 0, output_tokens: output)
      Bench.micro_to_usd(micro)
    end

    def plan(models: MODELS)
      data = corpus
      entries = data[:entries].size
      questions = data[:questions].size
      merges = entries - 1
      lines = []
      lines << "SMOKE PLAN (draft, not run; nothing below was sent anywhere)"
      lines << "corpus: synthetic, seed #{SEED}, 1 session, #{TURNS} turns = #{entries} log entries, #{questions} questions"
      lines << "ledger: #{ledger_path}"
      lines << "caps: ONE ledger for all bench runs, total $#{format("%.2f", CAP_LIMIT)} (can only be lowered); " \
               "this run's sub-cap $#{format("%.2f", CAP_USD)}, enforced by the guard; this run's spend is in the shared ledger for any later round"
      lines << "keys: only the files the selected models need: " \
               "#{key_names(models).map { |n| File.join(KEY_DIR, KEY_FILES[n]) }.join(" and ")} " \
               "(0600, owned by you, printable ASCII, no whitespace except one trailing newline); never the environment; not read in --plan"
      lines << "order: " + models.map { |m| m[:model] }.join(" -> ") +
        ((models.any? { |m| m[:gate] }) ? "; GLM-5.3-Flash only after a single-request gate (reasoning ON under a #{GLM_REASONING_BUDGET}-token budget; the gate needs a 200, thinking tokens within the #{GLM_THINKING_BOUND}-token bound, no cut-off, a non-empty answer)" : "")
      lines << "guard: max_retries 0 | input margin #{INPUT_MARGIN_TOKENS} tokens | settlement reservation | " \
               "max output #{MAX_OUTPUT_TOKENS} tokens | reasoning off with a halt on any reasoning tokens" \
               "#{if models.any? { |m| m[:reasoning_budget] }
                    " (GLM only: reasoning on, thinking {type: enabled, budget_tokens: #{GLM_REASONING_BUDGET}}, " \
               "max sent #{MAX_OUTPUT_TOKENS + GLM_REASONING_BUDGET}, thinking bound #{GLM_THINKING_BOUND} (the budget is soft), " \
               "reserved output #{GLM_RESERVED_OUTPUT_TOKENS} tokens)"
                  end}"
      lines << "route: Fireworks POST #{FireworksRoute::API_BASE}/chat/completions only; models #{FireworksRoute::ALLOWED_MODELS.size} on the fixed list"
      lines << "per model pass: about #{merges} compactor requests (each may retry up to #{RubyLLM::InfiniteContext::TRIES} " \
               "times if a summary is too long) + #{questions} reader questions (tool loops add requests)"
      total_expected = 0.0
      total_worst = 0.0
      models.each do |m|
        compactor = request_worst_case_usd(m[:model], 3_000)
        reader = request_worst_case_usd(m[:model], 6_000)
        expected = merges * compactor + questions * 2 * reader
        worst = merges * RubyLLM::InfiniteContext::TRIES * compactor + questions * 14 * reader
        total_expected += expected
        total_worst += worst
        lines << "  #{m[:model]}"
        lines << "    price: $#{m[:input]} in / $#{m[:cached]} cached in / $#{m[:output]} out per million tokens"
        lines << "    source: #{m[:source]}"
        lines << "    reserve per request: compactor ~$#{format("%.4f", compactor)}, reader ~$#{format("%.4f", reader)}"
        lines << "    expected pass total ~$#{format("%.3f", expected)}; extreme bound (every retry and 14 requests per question) ~$#{format("%.2f", worst)}"
      end
      if models.any? { |m| m[:gate] }
        gate = request_worst_case_usd(GLM, 600)
        total_expected += gate
        lines << "GLM gate: one request, reserve ~$#{format("%.4f", gate)}"
      end
      lines << "expected total ~$#{format("%.2f", total_expected)}; the sub-cap $#{format("%.2f", CAP_USD)} stops the run in the guard long before the extreme bound"
      lines.join("\n")
    end

    # The live run. Unreachable while the locks are shut: the top of this
    # file aborts, and Runner.new raises PaidRunsDisabled.
    def run!(key_dir: KEY_DIR, ledger_path: self.ledger_path, models: MODELS)
      # First, before the ledger, the corpus or any provider object: a key
      # file that fails its checks refuses the run. Only the files the
      # selected models need are opened.
      keys = load_keys(dir: key_dir, models: models)
      fireworks_context = apply_keys(keys)

      corpus_dir = File.join(OUT, "corpus")
      write_corpus(corpus_dir)
      ledger = Ledger.new(ledger_path) # the shared file; total $20 whoever created it
      guard = Guard.new(ledger: ledger, prices: prices, max_output_tokens: MAX_OUTPUT_TOKENS,
        input_margin_tokens: INPUT_MARGIN_TOKENS, retries: 0, settlement: :reservation,
        forbid_thinking_tokens: true, run_cap_usd: CAP_USD)

      models.each do |m|
        if m[:gate] == :single_request_reasoning_budget
          puts "== gate: #{m[:model]} (one request, reasoning on under a #{m[:reasoning_budget]}-token budget)"
          glm_gate!(guard, fireworks_context)
        end
        puts "== #{m[:model]}"
        runner = Runner.new(corpus: corpus_dir, compactor: m[:model], reader: m[:model], budgets: [BUDGET],
          out: File.join(OUT, m[:model].tr("/", "_")), guard: guard, baselines: %w[tree],
          fireworks_context: fireworks_context, reasoning_budgets: reasoning_budgets(models))
        runner.run
      end
      puts "this run: $#{format("%.4f", Bench.micro_to_usd(guard.run_micro))} of its $#{format("%.2f", CAP_USD)} sub-cap; " \
           "ledger total: $#{format("%.4f", Bench.micro_to_usd(ledger.committed_micro))} of $#{format("%.2f", CAP_LIMIT)}"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  mode, list = Bench.smoke_args(ARGV)
  begin
    models = Bench::Smoke.select_models(list)
  rescue Bench::Error => e
    abort e.message
  end
  if mode == "--plan"
    puts Bench::Smoke.plan(models: models)
  else
    Bench::Smoke.run!(models: models)
  end
end
