# frozen_string_literal: true

require "ruby_llm/infinite_context"

module Bench
  # Pure scoring helpers: no chat, no network, no ledger, no Runner. The
  # dry run (bench/dry_run.rb) includes this module directly, so it can
  # exercise the metrics with no provider object anywhere in the process.
  module Scoring
    include RubyLLM::InfiniteContext::TreeMath

    NODE_LIMIT = RubyLLM::InfiniteContext::NODE
    RULER = RubyLLM::InfiniteContext::Prompts::RULER

    # Layer 1: share of nodes within NODE bytes, ruler-copy rate, mean
    # tries, and gold-fact retention by tree level.
    def layer1(trees, questions)
      nodes = 0
      over = 0
      ruler_copies = 0
      tries_sum = 0
      retention = retention_by_level(trees, questions)
      trees.each do |tree, _|
        tree.nodes.find_each do |node|
          nodes += 1
          over += 1 if node.bytes > NODE_LIMIT
          ruler_copies += 1 if node.text.include?(RULER.first(20))
          tries_sum += node.tries
        end
      end
      {
        nodes:, over_limit: over, fit_rate: nodes.zero? ? 0.0 : (nodes - over) / nodes.to_f,
        ruler_copy_rate: nodes.zero? ? 0.0 : ruler_copies / nodes.to_f,
        mean_tries: nodes.zero? ? 0.0 : tries_sum / nodes.to_f,
        # Share of gold facts still findable in the nodes at each level:
        # if retention collapses between level 0 and the top, the tree is
        # losing the user's own words as it merges.
        retention_by_level: retention
      }
    end

    # Gold-fact retention per tree level: the share of the corpus questions'
    # gold strings that appear in any built node of that level. A level with
    # no nodes yet scores 0 for that session's facts, so a half-built tree
    # under-reports rather than over-reports.
    def retention_by_level(trees, questions)
      hits = Hash.new { |h, k| h[k] = [0, 0] }
      trees.each do |tree, i|
        qs = questions.select { |q| q["session"] == i }
        next if qs.empty?

        levels = tree.nodes.distinct.pluck(:level)
        levels.each do |level|
          texts = tree.nodes.where(level: level).pluck(:text).join("\n").downcase
          qs.each do |q|
            hits[level][1] += 1
            hits[level][0] += 1 if texts.include?(q["gold"].to_s.downcase)
          end
        end
      end
      hits.sort.to_h.transform_values { |hit, total| (hit / total.to_f).round(4) }
    end

    # Cut-off: whole recent entries, oldest first, up to the budget.
    def cutoff_lines(entries, budget)
      lines = entries.each_with_index.map { |e, i| "#{i}+1|#{flat(e["text"])}" }
      out = []
      total = 0
      lines.reverse_each do |line|
        break if total + line.bytesize > budget

        out.unshift(line)
        total += line.bytesize
      end
      out
    end

    # Gold-string scoring: right when the gold appears in the reply,
    # partial when a word of the gold appears, wrong otherwise.
    def verdict_key(reply, gold)
      reply = reply.downcase
      gold = gold.downcase
      return :right if reply.include?(gold)

      words = gold.scan(/[\w.\/#-]+/).reject { |w| w.length < 4 }
      return :partial if words.any? { |w| reply.include?(w) }

      :wrong
    end

    def empty_score = {right: 0, partial: 0, wrong: 0, zooms: 0, usd: 0.0, n: 0}

    def summary(score)
      "right #{score[:right]} partial #{score[:partial]} wrong #{score[:wrong]} " \
        "zooms #{score[:zooms]} usd #{format("%.4f", score[:usd])}"
    end
  end
end
