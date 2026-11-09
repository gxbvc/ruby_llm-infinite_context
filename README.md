# ruby_llm-infinite_context

Endless memory for [RubyLLM](https://github.com/crmne/ruby_llm) 2.x chats and agents.

Every message is logged. A cheap model compresses the log into a binary tree of one-line
summaries. The chat sees a saved "view" of the tree that fits a budget you pick (for example
20,000 tokens): recent messages one per line, older ones in progressively coarser lines. The
agent gets tools to zoom into any line, down to the original message.

## Status

0.1.0 is the first version and has not been released yet. It has been tested end to end on three
real models: DeepSeek V4.1 Flash (11 of 12 questions right, 33 zooms), Claude Haiku 4.5
(10 of 12 right, 31 zooms) and GLM-5.3 Flash (10 of 12 right, 26 zooms), each as both
compactor and reader, on a small synthetic log (14 entries, 12 questions). That is a smoke
test that the whole path works, not a benchmark.
Benchmark results (quality and cost across models and view budgets) come later; the benchmark
itself is in `bench/`.

## Credits

This gem is based on **OptChat / UniiChat**, Victor Taelin's design for one endless chat whose
log is summarized into a binary tree:

- OptChat/UniiChat gist: https://gist.github.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449
- [pi-optchat](https://github.com/jonaslsaa/pi-optchat) (Jonas, MIT), a Pi extension that
  implements the gist, and its npm package
  [pi-optchat](https://www.npmjs.com/package/pi-optchat).

The design ideas come from the gist and pi-optchat; the prompts in this gem are our own words.
See `THIRD_PARTY_NOTICES.md`.

## Install

```ruby
gem "ruby_llm-infinite_context"
```

Then create the tables:

```
rails g ruby_llm:infinite_context:install
rails db:migrate
```

## Use

### With a chat

```ruby
chat = RubyLLM.chat(model: "claude-sonnet-5-5")
memory = RubyLLM::InfiniteContext.attach(chat, key: "conv-1",
                                         compactor: "claude-haiku-4-5",
                                         tokens: 20_000)
memory.turn("...")
memory.tree.view_lines(budget: 80_000)   # the saved view, "id+n|text" lines
memory.tree.stats.hot_nodes(limit: 10)   # the most opened lines
```

One `Chat` per turn; the tree is the only memory between turns. Each turn logs the user's
message and the reply, shows the view as instructions, hands the agent `zoom`, `read` and
`date` tools, and then pumps the compactor for nodes that are not built yet.

### Fireworks and other OpenAI-compatible services

**RubyLLM 2.1.1 sends an OpenAI-provider chat to the Responses API by default**
(`POST {base}/responses`, with `store: false`). Many OpenAI-compatible services only offer
chat completions (`POST {base}/chat/completions`). Fireworks offers both, but its Responses
API has storing features, so use chat completions there. For any of these, build the chat
with `protocol: :chat_completions`, for both your chat and the compactor:

```ruby
fireworks = RubyLLM.context do |config|
  config.openai_api_key = Rails.application.credentials.fireworks_api_key
  config.openai_api_base = "https://api.fireworks.ai/inference/v1"
end

wire = { provider: :openai, protocol: :chat_completions,
         assume_model_exists: true, context: fireworks }

memory = RubyLLM::InfiniteContext.attach(
  "accounts/fireworks/models/deepseek-v4p1-flash",    # a model NAME: the gem builds the chat
  key: "conv-1",
  compactor: "accounts/fireworks/models/glm-5p3-flash",
  chat_options: wire,        # how the gem builds your chat from the name
  compactor_options: wire    # how it builds the compactor's chats
)
```

The options are the ones `RubyLLM.chat` takes to pick the wire: `provider:`, `protocol:`,
`assume_model_exists:` and `context:`. An unknown key raises, so a typo such as `protcol:`
cannot quietly pick the wrong API. The same `chat_options:` is accepted by
`Compactor.new`, `BatchImport.new` and `Pump::Runner.new`. If you pass a ready `Chat` (or a
lambda that returns one), you build it yourself:
`RubyLLM.chat(model: ..., provider: :openai, protocol: :chat_completions, ...)`; only the
compactor then needs `compactor_options:`.

The pump that runs inside an ActiveJob (`pump: :job`, `PumpJob`) cannot carry per-call
options, so set the compactor's default once at boot:

```ruby
RubyLLM::InfiniteContext.compactor_chat_options = wire
```

For a Rails model, see below: set `protocol`, `provider` and `context` on the record, and
pass `compactor_options:` to `has_infinite_context`.

### Tokens or bytes

Every budget inside the gem is UTF-8 bytes. You can ask in tokens: pass `tokens:`
(`tokens: 20_000`), or write `budget: 20_000.tokens` after
`using RubyLLM::InfiniteContext::Tokens`. Both convert once at the API edge with a rough
estimator of 4 bytes per token, which is right for English prose; text with code or
non-ASCII runs heavier. For exact budgets, pass `budget:` in bytes.

### With a Rails model

```ruby
class Conversation < ApplicationRecord
  acts_as_chat
  include RubyLLM::InfiniteContext::Model
  has_infinite_context compactor: "claude-haiku-4-5"
end

memory = conversation.with_infinite_context(tokens: 20_000)
memory.turn("...")
```

The record names the model. Each turn builds a fresh RubyLLM chat from the record's
`model_id`, `provider`, `protocol`, `assume_model_exists` and `context` (the attributes
`acts_as_chat` gives it). The record's own message history is not sent: the tree is the
memory between turns, so the turn does not grow with the thread. For Fireworks, set
`conversation.protocol = :chat_completions` (the attributes `protocol`, `assume_model_exists`
and `context` are not saved; set them after loading the record) and use
`has_infinite_context compactor: "...", compactor_options: wire`.

### Bulk import of an existing thread

```ruby
importer = RubyLLM::InfiniteContext::BatchImport.new(tree)
submission = importer.submit(messages.map { |m| { role: m.role, content: m.content } })
# persist submission.id; later:
batch = RubyLLM::Batch.find(submission.id, provider: submission.provider)
importer.collect!(submission, batch) if batch.refresh.complete?
```

Compresses an existing long thread at batch prices with `RubyLLM::Batch` (`ask_later`).
Call `submit` again after `collect!` when the thread is longer than one batch covers:
later levels become ready as their children finish.

## How it works

- **Log** (`ric_entries`): append-only, never updated or deleted.
- **Tree** (`ric_nodes`): node `(level, i)` covers entries `[i·2^level, (i+1)·2^level)`.
  A source that fits in 512 bytes is its own node with no model call; otherwise the compactor
  model compresses or merges it, with the view as context, up to 5 tries to fit under 512
  bytes (the shortest try wins). Built once, never recomputed.
- **Views** (`ric_views`): one saved view per budget. The view only appends at the end and
  merges the most due adjacent pair whose parent is built; it never splits, so older stretches
  sit in coarser and coarser lines (the sawtooth). A saved view is never rebuilt from the log.
  The compactor works against its own 24 KB view, separate from whatever the consumer sees.
- **Zoom** (`ric_zoom_events`): `zoom(id, n)` opens a line into the two lines it was built
  from; `zoom(id, 1)` shows the message, paged when long (`read(id, page)`). Opening a line
  the agent already opened this turn returns "you already opened this line; its text is
  above" instead of the text again, and a per-turn cap (12 by default) bounds runaway zooming.
- **Counters, not rewrites**: nodes count `dig_count` and `last_dug_at`; zoom events record
  the leaf a dig reached, the steps it cost, and the turn. No parent rewrite, no fold boost:
  the shipped action on repeated digs is `:none` (do nothing) until data supports one.
- **Tool pairs**: a tool result is summarized with its call as context, so the pair survives
  as one fact.
- **Prompt caching** (`CacheMark`): for providers that accept explicit cache breakpoints
  (Anthropic), the view is sent as fixed blocks of 8 parts with one mark on the part the next
  messages will not change. Other providers rely on implicit prefix caching.

## SQLite and Postgres

The tables use `json` columns and row locks, not `jsonb` or advisory locks, so both work.

## Benchmarks

`bench/` holds a public, synthetic benchmark: a generator that writes agent sessions with
known gold facts, and a runner that scores compactor quality (fit rate, ruler-copy rate,
retention up the tree) and end-to-end accuracy at several view budgets against cut-off and
rolling-compaction baselines, with cost in USD. `bench/dry_run.rb` exercises the whole
machinery with no API calls. No client data is used anywhere in the corpus. See
`bench/README.md` to reproduce.

## Development

```
bin/setup
rake test
rake standard
```

## License

MIT. See `THIRD_PARTY_NOTICES.md` for third-party credits.
