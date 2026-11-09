# frozen_string_literal: true

# Dry run of the benchmark machinery with NO API calls and no cost: a small
# generated corpus goes through trees, the pump (with a fake builder that
# needs no model), the layer-1 metrics (fit rate, ruler copy rate, retention
# by level), the cut-off baseline lines and the gold-string judge.
#
#   ruby bench/dry_run.rb
#
# What a pass means: the corpus generates, the pump builds every node, the
# fake summaries fit under NODE, the ruler never leaks, gold facts stay
# findable at level 0, and the scoring helpers behave. What it cannot
# measure: real compactor or reader quality. That needs a paid
# round (bench/run_bench.rb; paid runs are disabled by default).

require "json"
require "fileutils"

BENCH_ROOT = File.expand_path(__dir__)
$LOAD_PATH.unshift File.expand_path("../lib", BENCH_ROOT)

require "ruby_llm/infinite_context"
require "ruby_llm/infinite_context/models"
# Only the pure scoring helpers: no Runner, no guard, no chat, no network.
require_relative "scoring"

module Bench
  class DryRun
    include RubyLLM::InfiniteContext::TreeMath
    include Bench::Scoring

    # A stand-in compactor: no model, deterministic, always fits. It keeps
    # the source text up to NODE bytes, so gold facts survive at level 0
    # and fade as merges truncate — the retention curve then has a real
    # shape even in the dry run.
    class FakeBuilder
      include RubyLLM::InfiniteContext::TreeMath

      def initialize(tree)
        @tree = tree
      end

      def build(level, i)
        source =
          if level.zero?
            @tree.entry(i).text
          else
            "#{@tree.node_text(level - 1, 2 * i)} #{@tree.node_text(level - 1, 2 * i + 1)}"
          end
        tm = RubyLLM::InfiniteContext::TreeMath
        [tm.cut("fake: #{tm.flat(source)}", RubyLLM::InfiniteContext::NODE), 1]
      end
    end

    def run
      # A throwaway database for the dry trees.
      db = File.expand_path("results-dry/bench.sqlite3", BENCH_ROOT)
      FileUtils.mkdir_p(File.dirname(db))
      File.unlink(db) if File.exist?(db)
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db)
      RubyLLM::InfiniteContext::Schema.create!

      corpus = File.expand_path("corpus-dry", BENCH_ROOT)
      FileUtils.rm_rf(corpus)
      system("ruby", File.join(BENCH_ROOT, "generate_corpus.rb"),
        "--sessions", "4", "--turns", "20", "--out", corpus, "--seed", "7") or raise "corpus generator failed"
      questions = File.readlines(File.join(corpus, "questions.jsonl")).map { |l| JSON.parse(l) }

      trees = Dir.glob(File.join(corpus, "session-*.jsonl")).sort.each_with_index.map do |file, i|
        tree = RubyLLM::InfiniteContext::Tree.for("dry-#{i}", compactor: "fake")
        File.readlines(file).each { |l|
          e = JSON.parse(l)
          tree.append(e["kind"], e["text"])
        }
        [tree, i]
      end

      trees.each do |tree, _|
        count = RubyLLM::InfiniteContext::Pump::Runner.new(tree, builder: FakeBuilder.new(tree), jobs: 4, logger: method(:log)).run
        raise "pump built #{count} nodes for #{tree.key}; expected #{expected_nodes(tree)}" unless count == expected_nodes(tree)

        tree.nodes.find_each do |node|
          raise "node over NODE: #{node.text[0, 40]}" if node.bytes > RubyLLM::InfiniteContext::NODE
          raise "ruler leaked into a node" if node.text.include?("-" * 20)
        end
        raise "no view lines" if tree.view_lines(80_000).empty?
      end

      layer1 = layer1(trees, questions)
      raise "fit rate #{layer1[:fit_rate]} != 1.0" unless (layer1[:fit_rate] - 1.0).abs < 1e-9
      raise "ruler copy rate #{layer1[:ruler_copy_rate]} != 0.0" unless layer1[:ruler_copy_rate].abs < 1e-9
      level0 = layer1[:retention_by_level][0]
      raise "level-0 retention #{level0} too low" unless level0 && level0 > 0.5

      # Cut-off baseline lines fit the budget and run oldest first.
      session0 = File.readlines(File.join(corpus, "session-0000.jsonl")).map { |l| JSON.parse(l) }
      lines = cutoff_lines(session0, 4_000)
      raise "cutoff over budget" if lines.sum(&:bytesize) > 4_000
      raise "cutoff not oldest first" unless lines.first.start_with?("0+1|")
      raise "cutoff dropped everything" unless lines.any?

      # The judge scores gold strings.
      raise "judge right" unless verdict_key("the RMA number was 3125 filed", "3125") == :right
      raise "judge wrong" unless verdict_key("logs/pump_ctl.c was grepped", "3125") == :wrong

      puts "DRY RUN OK"
      puts "  sessions: #{trees.size}, questions: #{questions.size}"
      puts "  layer1: fit_rate=#{layer1[:fit_rate]} ruler_copy_rate=#{layer1[:ruler_copy_rate]}"
      puts "  retention_by_level=#{layer1[:retention_by_level].inspect}"
      true
    end

    def log(message)
      warn "[dry] #{message}"
    end

    # A complete tree over T entries: every node whose stretch is a whole
    # power-of-two block, at every level.
    def expected_nodes(tree)
      total = tree.entry_count
      nodes = 0
      l = 0
      while (1 << l) <= total
        nodes += total >> l
        l += 1
      end
      nodes
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  Bench::DryRun.new.run
end
