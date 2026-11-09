# frozen_string_literal: true

# Generates a public, synthetic benchmark corpus: agent sessions whose log
# holds known facts (names, numbers, paths, decisions), plus questions with
# gold answers. Everything is made up here; no client or private data goes
# into this corpus, so anyone can rerun the benchmark.
#
#   ruby bench/generate_corpus.rb --sessions 20 --turns 40 --out bench/corpus
#
# Output: one JSONL file per session (a list of {kind, text} log entries)
# and a questions.jsonl with {session, question, gold}.

require "json"
require "optparse"

module Bench
  module Corpus
    PEOPLE = %w[Mara Ozlem Pete Ingrid Callum Rosa Deng Yuki Omar Priya Nadia Theo Vera Salim June].freeze
    PLACES = %w[Fernhill Oakvale Brassfield Loomis Quillon Harborline Dunmore Kestrel].freeze
    THINGS = %w[greenhouse sensors pump controller firmware lane CSV export backup bucket nightly report invoice portal login].freeze
    TOOLS = %w[deploy logtail rotate-keys snapshot prune].freeze
    PATHS = %w[logs/pump_ctl.c config/valve.yaml exports/coop.csv backups/nightly].freeze

    module_function

    def rnd(seed)
      Random.new(seed)
    end

    # One synthetic session: a list of {kind:, text:} log entries.
    def session(seed, turns:)
      rand = rnd(seed)
      person = PEOPLE[rand.rand(PEOPLE.size)]
      place = PLACES[rand.rand(PLACES.size)]
      entries = []
      facts = []

      turns.times do |t|
        case rand.rand(6)
        when 0, 1
          number = rand.rand(100..9_999)
          facts << {question: "How often did #{person} want the #{place} thing checked, in minutes?", gold: number.to_s}
          entries << {kind: "user", text: "Please check the #{place} sensors every #{number} minutes, and keep the old export until we sign off. #{"Detail " * rand.rand(3)}"}
        when 2
          rma = rand.rand(1000..9999)
          entries << {kind: "assistant", text: "I flashed #{rand.rand(3..14)} of 14 boards; #{rand.rand(0..3)} bricked, RMA ##{rma} filed. #{"Progress " * rand.rand(3)}"}
          facts << {question: "What was the RMA number filed for the bricked boards around turn #{t}?", gold: rma.to_s}
        when 3
          path = PATHS.sample(random: rand)
          entries << {kind: "tool", text: "grep -rn #{place.downcase} #{path}"}
          entries << {kind: "echo", text: "#{path}:#{rand.rand(1..99)}: # #{place} valve loop, #{rand.rand(2..9)} retry paths. #{"Output " * rand.rand(20)}"}
          facts << {question: "Which file did the grep over #{path} relate to the #{place} valves?", gold: path}
        when 4
          entries << {kind: "user", text: "Use #{TOOLS.sample(random: rand)} on the #{place} box, but not before the backup finishes. #{"Instruction " * rand.rand(3)}"}
          facts << {question: "What constraint did the user put on the #{place} task around turn #{t}?", gold: "backup"}
        when 5
          entries << {kind: "note", text: "earlier: the #{place} co-op approved the drip plan; misting stays off until the loan closes."}
          facts << {question: "Which watering plan did the #{place} co-op approve?", gold: "drip"}
        end
      end

      [entries, facts]
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {sessions: 20, turns: 40, out: "bench/corpus", seed: 2026}
  OptionParser.new do |o|
    o.on("--sessions N", Integer) { |v| options[:sessions] = v }
    o.on("--turns N", Integer) { |v| options[:turns] = v }
    o.on("--out DIR") { |v| options[:out] = v }
    o.on("--seed N", Integer) { |v| options[:seed] = v }
  end.parse!

  require "fileutils"
  FileUtils.mkdir_p(options[:out])
  questions = []

  options[:sessions].times do |s|
    entries, facts = Bench::Corpus.session(options[:seed] + s, turns: options[:turns])
    File.write(File.join(options[:out], "session-#{format("%04d", s)}.jsonl"),
      entries.map { |e| JSON.generate(e) }.join("\n"))
    facts.each do |fact|
      questions << {session: s, question: fact[:question], gold: fact[:gold]}
    end
  end

  File.write(File.join(options[:out], "questions.jsonl"),
    questions.map { |q| JSON.generate(q) }.join("\n"))
  puts "#{options[:sessions]} sessions, #{questions.size} questions in #{options[:out]}"
end
