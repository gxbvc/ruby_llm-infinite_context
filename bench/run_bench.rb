# frozen_string_literal: true

# Runs the quality and cost benchmark over a generated corpus.
#
# PAID RUNS ARE DISABLED BY DEFAULT. `--yes` is refused, and the real
# provider path is shut, until a person sets PAID_RUNS_ENABLED to true
# below. Only `--preflight` (no model call) works from the command line.
# The meter is tested over a fake in-process network; its stated limits
# are in spend_guard.rb.
#
# Layer 1 scores the compactor alone: share of nodes within NODE bytes
# after the allowed tries, the ruler-copy rate (the ruler leaking into a
# summary), and gold-fact retention at each level of the tree.
# Layer 2 scores end to end at each view budget, for three context
# strategies:
#
# - tree: the saved view of the summary tree, with zoom/read/date tools
#   (this gem).
# - cutoff: the last `budget` bytes of the raw log, whole entries (the
#   baseline every long chat falls back to).
# - rolling: a verbatim tail of half the budget, and the older entries
#   merged pair by pair with the compactor until the head fits the other
#   half (rolling compaction).
#
# Replies score right, partial or wrong by gold string; zooms per question
# and USD per strategy come from the ledger.
#
# Every chat, the pump's compactor chats and the rolling merges included,
# is built through one armed factory (Runner#new_chat), so each rendered
# provider request reserves its worst case in the shared ledger first.
#
#   ruby bench/generate_corpus.rb
#   ruby bench/run_bench.rb --corpus bench/corpus \
#     --compactor claude-haiku-4-5 --reader claude-haiku-4-5 --preflight

# DEFAULT: paid benchmark runs are DISABLED.
# `--yes` is refused here, at the very top of the script, before any
# library is loaded, any option is parsed, any Runner is built or any model
# is initialized. The match is any argument starting `--y`, so an
# OptionParser abbreviation of --yes (`--ye`, `--y`) is refused too.
# Nothing re-enables this except a person editing this file.
module Bench
  PAID_RUNS_ENABLED = false
  PAID_REFUSAL = "REFUSED: paid benchmark runs are disabled by default (PAID_RUNS_ENABLED is false). --yes is not " \
                 "accepted. No model was initialized and no call was made."
end

if __FILE__ == $PROGRAM_NAME && ARGV.any? { |arg| arg.start_with?("--y") }
  abort Bench::PAID_REFUSAL
end

require "json"
require "optparse"
require "fileutils"

BENCH_ROOT = File.expand_path(__dir__)
$LOAD_PATH.unshift File.expand_path("../lib", BENCH_ROOT)

require "ruby_llm/infinite_context"
require "ruby_llm/infinite_context/models"
require_relative "spend_guard"
require_relative "scoring"

module Bench
  class PaidRunsDisabled < Error; end

  # True only when RubyLLM's HTTP hop is the in-process fake network that
  # the test support registers: no socket is ever opened. The check is on
  # the registered adapter CLASS, not just its name, so a lookalike name
  # does not pass.
  def self.offline_transport?
    return false unless defined?(::FakeNetwork::Adapter)
    return false unless RubyLLM.config.faraday_adapter.to_s == "fake_network"

    Faraday::Adapter.lookup_middleware(:fake_network) == ::FakeNetwork::Adapter
  rescue
    false
  end

  # The fail-closed gate. Called first in Runner.new, first in Runner#run
  # and in new_chat: before any corpus read, database setup, directory
  # creation, guard use or provider object. It raises unless paid runs are
  # enabled (they are not by default) or the transport is the in-process
  # fake network.
  def self.assert_runs_allowed!
    return if PAID_RUNS_ENABLED || offline_transport?

    raise PaidRunsDisabled, PAID_REFUSAL
  end

  module CLI
    module_function

    def parse(argv)
      options = {corpus: "bench/corpus", budgets: [4_000, 20_000, 60_000],
                 out: "bench/results", baselines: Runner::STRATEGIES, cap: CAP_LIMIT,
                 ledger: Ledger.default_path, max_output_tokens: 1024,
                 input_margin_tokens: Guard::DEFAULT_INPUT_MARGIN_TOKENS, settlement: :metered}
      OptionParser.new do |o|
        o.on("--corpus DIR") { |v| options[:corpus] = v }
        o.on("--compactor MODEL") { |v| options[:compactor] = v }
        o.on("--reader MODEL") { |v| options[:reader] = v }
        o.on("--budgets a,b,c", Array) { |v| options[:budgets] = v.map(&:to_i) }
        o.on("--baselines a,b", Array) { |v| options[:baselines] = v }
        o.on("--out DIR") { |v| options[:out] = v }
        o.on("--cap USD", Float) { |v| options[:cap] = v }
        o.on("--ledger PATH") { |v| options[:ledger] = v }
        o.on("--prices FILE") { |v| options[:prices] = v }
        o.on("--run-cap USD", Float) { |v| options[:run_cap] = v }
        o.on("--max-output-tokens N", Integer) { |v| options[:max_output_tokens] = v }
        o.on("--input-margin-tokens N", Integer) { |v| options[:input_margin_tokens] = v }
        o.on("--settlement MODE", %w[metered reservation]) { |v| options[:settlement] = v.to_sym }
        o.on("--expect-retries N", Integer) { |v| options[:expect_retries] = v }
        o.on("--preflight") { |v| options[:preflight] = v }
        o.on("--yes") { |v| options[:yes] = v }
      end.parse(argv)
      options
    end

    # Second layer behind the top-of-file check: a parsed --yes is refused
    # before preflight, before Runner.new, before anything else.
    def refuse_paid!(options)
      raise PaidRunsDisabled, PAID_REFUSAL if options[:yes] || !PAID_RUNS_ENABLED
    end

    # Explicit per-model prices (USD per million tokens), from a JSON file:
    #   {"model-id": {"input": 1.0, "output": 5.0}}
    def load_prices(path)
      return {} unless path

      JSON.parse(File.read(path))
    rescue JSON::ParserError, SystemCallError => e
      raise Error, "cannot read prices file #{path}: #{e.class}"
    end

    def build_guard(options)
      ledger = Ledger.new(options[:ledger], cap_usd: options[:cap])
      Guard.new(ledger:, prices: load_prices(options[:prices]),
        max_output_tokens: options[:max_output_tokens],
        input_margin_tokens: options[:input_margin_tokens],
        settlement: options[:settlement], retries: options[:expect_retries],
        run_cap_usd: options[:run_cap])
    end

    # Corpus checks shared by preflight and Runner#run.
    def check_corpus!(corpus)
      problems = []
      sessions = Dir.glob(File.join(corpus, "session-*.jsonl")).sort
      problems << "no session files in #{corpus} (run generate_corpus.rb first)" if sessions.empty?
      questions_path = File.join(corpus, "questions.jsonl")
      questions = []
      if File.exist?(questions_path)
        questions = File.readlines(questions_path).map { |l| JSON.parse(l) }
        problems << "questions.jsonl is empty" if questions.empty?
        bad = questions.reject { |q| (0...sessions.size).cover?(q["session"]) }
        problems << "#{bad.size} questions name sessions that do not exist" if bad.any?
      else
        problems << "no questions.jsonl in #{corpus}"
      end
      raise Error, "preflight failed, nothing ran: #{problems.join("; ")}" unless problems.empty?

      {sessions: sessions.size, questions: questions.size}
    end

    # Everything that can be checked without a single API call. Strictly
    # conservative: any problem stops the round before it starts. It does
    # not create the ledger and it makes no network call (the pricing
    # registry is local data).
    def preflight!(options)
      problems = []
      problems << "--compactor MODEL is required" unless options[:compactor]
      problems << "--reader MODEL is required" unless options[:reader]
      if options[:cap] > CAP_LIMIT
        problems << "cap #{options[:cap]} is over the default $#{CAP_LIMIT} total cap; " \
                    "a larger cap needs a code change and a new ledger"
      end
      problems << "cap must be positive" unless options[:cap].positive?
      problems << "budgets must be positive" unless options[:budgets].all?(&:positive?)
      unless options[:max_output_tokens].is_a?(Integer) && options[:max_output_tokens].positive?
        problems << "--max-output-tokens must be a positive integer"
      end

      prices = begin
        load_prices(options[:prices])
      rescue Error => e
        problems << e.message
        {}
      end
      [options[:compactor], options[:reader]].compact.uniq.each do |model|
        Pricing.resolve(model, overrides: prices)
      rescue UnknownPricing => e
        problems << e.message
      end
      raise Error, "preflight failed, nothing ran: #{problems.join("; ")}" unless problems.empty?

      counts = check_corpus!(options[:corpus])
      counts.merge(ledger: ledger_state(options))
    end

    # Read-only look at an existing ledger; nil when it does not exist yet.
    def ledger_state(options)
      return nil unless File.exist?(options[:ledger])

      ledger = Ledger.new(options[:ledger], cap_usd: options[:cap])
      {committed_usd: Bench.micro_to_usd(ledger.committed_micro),
       remaining_usd: Bench.micro_to_usd(ledger.remaining_micro)}
    end
  end

  class Runner
    include Scoring

    STRATEGIES = %w[tree cutoff rolling].freeze

    attr_reader :guard

    # reasoning_budgets: {model id => thinking budget tokens} for Fireworks
    # models that run with reasoning ON (see Guard#arm); others run with
    # reasoning off.
    def initialize(corpus:, compactor:, reader:, budgets:, out:, guard:, baselines: STRATEGIES, fresh: true,
      fireworks_context: nil, reasoning_budgets: {})
      Bench.assert_runs_allowed! # before mkdir, database setup or anything else
      @fireworks_context = fireworks_context # from FireworksRoute.context; nil means no Fireworks
      @reasoning_budgets = reasoning_budgets
      @corpus = corpus
      @compactor = compactor
      @reader = reader
      @budgets = budgets
      @out = out
      @guard = guard
      @baselines = baselines & STRATEGIES
      FileUtils.mkdir_p(out)
      db = File.join(out, "bench.sqlite3")
      if fresh
        File.unlink(db) if File.exist?(db)
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db)
        RubyLLM::InfiniteContext::Schema.create!
      elsif !ActiveRecord::Base.connected?
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db)
        RubyLLM::InfiniteContext::Schema.create!
      end
    end

    def run
      Bench.assert_runs_allowed! # first line: before any corpus read, DB or provider object
      Bench::CLI.check_corpus!(@corpus)
      @guard.check!
      results = {compactor: @compactor, reader: @reader, baselines: @baselines,
                 cap_usd: Bench.micro_to_usd(@guard.ledger.cap_micro), budgets: {}, layer1: nil}
      started_micro = @guard.ledger.committed_micro
      begin
        run_rounds(results)
      rescue Bench::Error => e
        # A stop (cap, halt, unmetered reply) keeps what was scored so far.
        results[:stopped] = "#{e.class}: #{e.message}"
        raise
      ensure
        results[:round_spend_usd] = Bench.micro_to_usd(@guard.ledger.committed_micro - started_micro)
        results[:ledger_committed_usd] = Bench.micro_to_usd(@guard.ledger.committed_micro)
        File.write(File.join(@out, "results.json"), JSON.pretty_generate(results))
      end
      results
    end

    def run_rounds(results)
      sessions = Dir.glob(File.join(@corpus, "session-*.jsonl")).sort
      questions = File.readlines(File.join(@corpus, "questions.jsonl")).map { |l| JSON.parse(l) }
      entries = sessions.map { |file| File.readlines(file).map { |l| JSON.parse(l) } }

      trees = nil
      if @baselines.include?("tree")
        before = @guard.ledger.committed_micro
        puts "Pumping #{@compactor} over #{sessions.size} sessions..."
        trees = sessions.each_with_index.map do |file, i|
          [build_tree(file, i), i]
        end
        results[:compactor_pump_usd] = Bench.micro_to_usd(@guard.ledger.committed_micro - before)
        results[:layer1] = layer1(trees, questions)
      end

      @budgets.each do |budget|
        puts "Reading at budget #{budget}..."
        per_strategy = {}
        results[:budgets][budget] = per_strategy
        if trees
          per_strategy["tree"] = metered { score_tree(trees, questions, budget) }
          puts "  tree:    #{summary(per_strategy["tree"])}"
        end
        if @baselines.include?("cutoff")
          per_strategy["cutoff"] = metered { score_plain(entries, questions, budget, "reader-cutoff") { |es, b| cutoff_lines(es, b) } }
          puts "  cutoff:  #{summary(per_strategy["cutoff"])}"
        end
        if @baselines.include?("rolling")
          per_strategy["rolling"] = metered { score_plain(entries, questions, budget, "reader-rolling") { |es, b| rolling_lines(es, b) } }
          puts "  rolling: #{summary(per_strategy["rolling"])}"
        end
      end
    end

    # Builds and pumps one session's tree. The pump's compactor chats come
    # from the SAME armed factory as every other chat, so its requests
    # reserve against the ledger too. Pump::Runner swallows a node's error
    # and retries, so a halt is re-raised here, after the pump, before any
    # scoring uses a half-built tree.
    def build_tree(file, index)
      tree = RubyLLM::InfiniteContext::Tree.for("bench-#{index}", compactor: @compactor)
      File.readlines(file).each do |line|
        entry = JSON.parse(line)
        tree.append(entry["kind"], entry["text"])
      end
      builder = RubyLLM::InfiniteContext::Compactor.new(tree, model: @compactor,
        chat_factory: -> { new_chat(model: @compactor, label: "compactor-pump") })
      RubyLLM::InfiniteContext::Pump::Runner.new(tree, builder:, logger: method(:log)).run
      @guard.check!
      puts "  session #{index}: #{tree.nodes.count} nodes"
      tree
    end

    # -- chats: the one armed factory -------------------------------------

    # Every chat the bench makes comes from here, armed with the guard: an
    # output bound, no fallbacks, a worst-case reservation before every
    # rendered request and a settle after every reply.
    def new_chat(model:, label:, instructions: nil, tools: nil)
      # The real provider path stays shut while paid runs are disabled. Only the
      # in-process fake network (tests) is allowed through. Pump::Runner
      # swallows a node's error and retries, so a refusal here also halts
      # the guard: the check after the pump then raises instead of leaving
      # a silently empty tree.
      begin
        Bench.assert_runs_allowed!
      rescue PaidRunsDisabled => e
        @guard&.halt!(e.message)
        raise
      end

      budget = nil
      chat = if FireworksRoute.fireworks_model?(model)
        raise Error, "#{model} is a Fireworks model but no fireworks_context was given" unless @fireworks_context

        budget = @reasoning_budgets[model]
        FireworksRoute.chat(model: model, context: @fireworks_context, thinking_budget: budget)
      else
        RubyLLM.chat(model: model)
      end
      @guard.arm(chat, model: model, label: label, reasoning_budget_tokens: budget)
      chat.with_instructions(instructions) if instructions
      chat.with_tools(*tools) if tools
      chat
    end

    # Runs the block and returns its score with usd taken from the ledger
    # delta (settled replies plus any reservation still open).
    def metered
      before = @guard.ledger.committed_micro
      score = yield
      score[:usd] = Bench.micro_to_usd(@guard.ledger.committed_micro - before)
      @guard.check!
      score
    end

    # -- layer 2: end to end -----------------------------------------------

    # The tree strategy: the saved view at this budget, with zoom tools.
    # A fresh Turn per question: the repeat-zoom guard and the cap are per
    # question, and zoom counts never carry over.
    def score_tree(trees, questions, budget)
      score = empty_score
      trees.each do |tree, i|
        instructions = "#{RubyLLM::InfiniteContext::Prompts::VIEW_GUIDE}\n\n<chat>\n#{tree.view_lines(budget).join("\n")}\n</chat>"
        questions.select { |q| q["session"] == i }.each do |q|
          turn = RubyLLM::InfiniteContext::Turn.new
          tools = RubyLLM::InfiniteContext::Tools.for_turn(tree, turn)
          chat = new_chat(model: @reader, label: "reader-tree", instructions:, tools:)
          reply = chat.ask(q["question"])
          @guard.check!
          score[verdict_key(reply.content.to_s, q["gold"])] += 1
          score[:zooms] += tree.zoom_events.where(session: turn.id).count
          score[:n] += 1
        end
      end
      score
    end

    # The baselines: a plain context, no tools. The block builds the
    # context lines for one session at this budget.
    def score_plain(all_entries, questions, budget, label)
      score = empty_score
      all_entries.each_with_index do |entries, i|
        lines = yield(entries, budget)
        instructions = "#{RubyLLM::InfiniteContext::Prompts::VIEW_GUIDE}\n\n<chat>\n#{lines.join("\n")}\n</chat>"
        questions.select { |q| q["session"] == i }.each do |q|
          chat = new_chat(model: @reader, label:, instructions:)
          reply = chat.ask(q["question"])
          @guard.check!
          score[verdict_key(reply.content.to_s, q["gold"])] += 1
          score[:n] += 1
        end
      end
      score
    end

    # -- baseline context builders -----------------------------------------

    # Rolling compaction: a verbatim tail of half the budget; the older
    # entries merge pair by pair with the compactor (one model call per
    # merge, oldest pair first) until the head fits the other half. Each
    # merge is a guarded request like any other.
    def rolling_lines(entries, budget)
      lines = entries.each_with_index.map { |e, i| "#{i}+1|#{flat(e["text"])}" }
      tail = cutoff_lines(entries, budget / 2)
      head_count = lines.size - tail.size
      head = lines.first(head_count).map { |l| l.split("|", 2)[1] }
      head_budget = budget - tail.sum(&:bytesize)

      while head.sum(&:bytesize) > head_budget && head.size > 1
        a, b = head[0], head[1]
        chat = new_chat(model: @compactor, label: "compactor-rolling",
          instructions: RubyLLM::InfiniteContext::Prompts::COMPACT_SYSTEM)
        reply = chat.ask(RubyLLM::InfiniteContext::Compactor.merge_prompt(a, b))
        @guard.check!
        merged = reply.content.to_s.strip
        merged = "#{flat(a)} #{flat(b)}" if merged.empty? # never lose the entries
        head = [merged, *head[2..]]
      end
      head.each_with_index.map { |t, i| "#{i}+1|#{flat(t)}" } + tail
    end

    # -- helpers -----------------------------------------------------------

    def log(message)
      warn "[bench] #{message}"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = Bench::CLI.parse(ARGV)

  # Refusal comes first: before preflight, before Runner.new.
  begin
    Bench::CLI.refuse_paid!(options) if options[:yes]
  rescue Bench::PaidRunsDisabled => e
    abort e.message
  end

  begin
    preflight = Bench::CLI.preflight!(options)
  rescue Bench::Error => e
    abort e.message
  end
  ledger = preflight[:ledger]
  puts "Preflight OK: #{preflight[:sessions]} sessions, #{preflight[:questions]} questions, " \
       "#{ledger ? "ledger remaining $#{format("%.4f", ledger[:remaining_usd])}" : "no ledger yet"} " \
       "(preflight only; no model call was made)"
  exit 0 if options[:preflight]

  # While paid runs are disabled there is no path from here to a run.
  abort Bench::PAID_REFUSAL
end
