# ruby_llm-infinite_context

Endless memory for [RubyLLM](https://github.com/crmne/ruby_llm) 2.x chats and agents.

Every message is logged. A cheap model compresses the log into a binary tree of one-line
summaries. The chat sees a saved "view" of the tree that fits a budget you pick (for example
20,000 tokens): recent messages one per line, older ones in progressively coarser lines. The
agent gets tools to zoom into any line, down to the original message.

## Status

0.2.0 adds Active Record Encryption for the text columns and a way to require one wire
protocol for every chat the gem uses (see below and `CHANGELOG.md`). 0.2.1 fixes a pump
that could wait forever for a lost or stuck worker thread (see "Threads"). 0.2.2 fixes the zoom
repeat guard: after opening a pair of messages, the agent could not open the first message
of that pair in the same turn (and the reverse). Zoom counters now land on the line opened.
0.2.3 fixes a view that could be larger than its budget (26% over in one app; see "How it
works", Views) and adds two hooks to `Pump::Runner` (see "Threads"). 0.3.0 adds an opt-in
`search` tool that finds messages by their words and returns ids and dates, never text (see
"Search").
The gem has been tested
end to end on three
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
memory.tree.view_lines(80_000)   # the view, "id+n|text" lines, within 80,000 bytes
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

### Search (opt-in)

The agent can find a message by its words with a fourth tool, `search(words, before)`. It is
off by default. Turn it on per memory:

```ruby
memory = RubyLLM::InfiniteContext.attach(chat, key: "conv-1", tokens: 20_000,
                                         search: true,
                                         search_mask: ->(text) { MyScreen.mask(text) })

# or, for a Rails model
has_infinite_context compactor: "claude-haiku-4-5", search: true, search_mask: MyScreen.method(:mask)
conversation.with_infinite_context(tokens: 20_000, search: false)   # per-memory override
```

If you call `Tools.for_turn` yourself, pass `search: true` (and `search_mask:`, `search_cap:`,
and `view:` with the `[level, i]` parts of the view you showed, from `tree.shown_view(budget).parts`).
Without `search: true` the tool set is exactly `zoom`, `read` and `date`, as before.

What it returns: message ids, the date (as the `date` tool gives it) and the label of the view
line that covers each message, for example
`Messages with all words: 812 (Tue 2026-11-10 14:02 UTC, in line 768+64). Use zoom(id, 1) to read one.`
It never returns message text, the kind of a message, or its length. The agent then reads a
hit with `zoom(id, 1)`, so search adds no new way to read text.

How it matches:

- Text and words are compared NFKC-normalized and case-folded (`CAFÉ` matches `café`).
- A word matches whole words. A word of 5 or more letters, with letters only, also matches as a
  prefix (`deploy` matches `deployment`). A word with a digit or a symbol matches a whole token
  only: it must be the whole space-separated token, apart from symbols at the token's ends.
  So `12345` matches in `#12345,` but never in `123456789`, `12345.678`, `id:12345` or
  `id::12345`, and `file.rb` never matches in `file.rb.old`. Symbols at the ends of a query
  word are dropped. Words shorter than 2
  characters are ignored; at most 8 words are used.
- Order: messages with all the words first, then the best partial matches (marked `3 of 4
  words`), newest first within each, at most 10. `before:` (a message id above 0) pages back
  to older matches.

The mask hook: `search_mask:` is a callable that gets each message's text and returns it with
the spans your app must not reveal replaced **with spaces** (for example card numbers, keys,
health identifiers). It runs before matching, so a masked value can never match, and the agent
cannot learn that a message holds it by guessing the value. Use spaces (or remove the span),
not a word such as `[masked]`: a replacement word is searchable itself and would show the agent
which messages held a screened value. **If your app screens text before an agent may see it,
pass a mask that applies the same screen.** Without one nothing is masked. If the mask raises,
or returns something that is not a String, that message does not match (it fails closed) and
the count goes to the log. The mask runs in the calling thread; the time limit is checked after
each message, so keep the mask fast (a mask that never returns blocks the search).

```ruby
search_mask: ->(text) { text.gsub(/\b\d{12,19}\b/) { |m| " " * m.length } }
```

Limits and cost:

- At most 3 searches per turn (`search_cap:`), separate from the zoom cap.
- The scan runs in Ruby over this tree's own messages, newest first, in batches of 500, at most
  20,000 messages and 2 seconds per search. When a limit stops it, the reply says which ids it
  searched ("searched messages 20000 down to 4113 only") so the agent can go on with `before:`.
- It never searches in SQL (no `LIKE`, no full-text index), so encrypted text works and no plain
  text index is stored. It writes nothing, makes no model call and keeps nothing between calls.
- The logger gets one line per call with a status and counts only (`search: status=ok words=3
  scanned=1118 hits=2 partial=1 mask_errors=0 stopped=no ms=40`, or `search: status=cap ms=0`
  for a refused call): no query words, no text. Only a search that runs counts toward the cap;
  a call with no usable words or a bad `before:` does not.

Groups: like `zoom`, search reaches every message in the tree. In a tree shared by a group, a
member who joined late can find older talk. This is not new with search; if your app needs a
different rule, your app owns it (for example one tree per member, or no search for that
tree).

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

A provider batch job is not a chat completions call. When `required_protocol` is set (see
below), `submit` and `collect!` raise `ProtocolError`; load the thread with `tree.append` and
`Pump::Runner` instead.

### Encrypting the stored text

The text columns (`ric_entries.text`, the original messages, and `ric_nodes.text`, the summary
lines) can use Active Record Encryption. Set up the keys first (`bin/rails
db:encryption:init`, then put them in your credentials), then turn it on in an initializer:

```ruby
# config/initializers/infinite_context.rb
RubyLLM::InfiniteContext.encrypt_text = true
```

Rules:

- **Set it before the app writes a memory row.** It works if the gem's models load before or
  after the initializer. The models are plain classes that Zeitwerk does not reload, so the
  setting holds for the life of the process. You cannot turn it off again in the same process.
- **Without keys, the first write raises.** Nothing is stored as plain text by mistake.
- **The gem never searches these columns in SQL.** It reads rows by id and works on the text
  in Ruby, so non-deterministic encryption (the Rails default) is fine. Do not add your own
  `LIKE` or `where(text: ...)` queries on them.
- **Other columns are not encrypted.** They hold numbers, kinds and the tree key. `ric_views`
  holds only `[level, i]` pairs. Make the tree key an opaque id (a record id, not an email
  address or a phone number).
- **Column size:** ciphertext is larger than the plain text (base64 and a JSON header, after
  compression). The generator makes `text` columns, which have no practical limit on SQLite
  and Postgres. On MySQL, change them to `mediumtext` or larger.
- **Rows that exist already** stay plain text and cannot be read once encryption is on. Set
  `config.active_record.encryption.support_unencrypted_data = true`, run
  `RubyLLM::InfiniteContext::Entry.find_each(&:encrypt)` and the same for `Node`, then turn
  that setting off again.

If you prefer to declare it yourself, do it once per process, with a guard:

```ruby
# config/application.rb
config.to_prepare do
  [RubyLLM::InfiniteContext::Entry, RubyLLM::InfiniteContext::Node].each do |model|
    model.encrypts :text unless Array(model.encrypted_attributes).include?(:text)
  end
end
```

`to_prepare` runs again on every code reload in development, and the gem's models are not
reloaded. Without the guard, a second `encrypts :text` would wrap the column twice.

### Requiring one protocol

To make sure no chat the gem uses can reach another API, require the protocol at boot:

```ruby
RubyLLM::InfiniteContext.required_protocol = :chat_completions
```

Then every chat the gem builds or uses must have that protocol: the compactor (the pump and
`PumpJob`) and each turn of `attach` and the `Model` concern, including chats that you build
and pass in (for an `acts_as_chat` record, the chat its `to_llm` returns). A chat with another
protocol, or with none, raises `RubyLLM::InfiniteContext::ProtocolError` before any request
is sent and before the turn is logged. `BatchImport` always raises `ProtocolError` under
this rule, before it logs or submits anything, because provider batch jobs are not chat
completions calls. A chat with fallback models is accepted only when each fallback is a `RubyLLM::Model`
on the same provider, because RubyLLM drops the protocol when a fallback changes provider.

### A locked-down setup

For an app that must keep message text private (Fireworks serverless, chat completions only,
encrypted storage):

```ruby
# config/initializers/infinite_context.rb
fireworks = RubyLLM.context do |config|
  config.openai_api_key = Rails.application.credentials.fireworks_api_key
  config.openai_api_base = "https://api.fireworks.ai/inference/v1"
end
wire = { provider: :openai, protocol: :chat_completions,
         assume_model_exists: true, context: fireworks }

RubyLLM::InfiniteContext.required_protocol = :chat_completions
RubyLLM::InfiniteContext.compactor_chat_options = wire
RubyLLM::InfiniteContext.encrypt_text = true
```

Pass the same `wire` as `chat_options:` to `attach`, or set `protocol`, `provider` and
`context` on the `acts_as_chat` record.

Load old threads with `append` and the pump, not `BatchImport` (batch jobs are not chat
completions, so `BatchImport` refuses under this setup):

```ruby
tree = RubyLLM::InfiniteContext::Tree.for("thread-42", compactor: "accounts/fireworks/models/glm-5p3-flash")
old_messages.each { |m| tree.append(m.role == "assistant" ? :assistant : :user, m.content) }
RubyLLM::InfiniteContext::Pump::Runner.new(tree).run   # plain chat completions, normal prices
```

### Threads

The pump builds up to 8 nodes at once, each in its own thread. When a pass ends:

- A node that fails with a `StandardError` (in the compactor or in the Rails executor's own
  hooks) is logged and tried again, up to `retries` times.
- A `ProtocolError`, or any exception that is not a `StandardError` (`NoMemoryError`,
  `SystemStackError`, `Interrupt`), stops the run: `run` raises it after the pass.
- A pass that takes longer than `pass_timeout` seconds (15 minutes by default) stops: the
  log gets each stuck worker's location (file, line and method only), the stuck threads are
  stopped, and `run` raises `RubyLLM::InfiniteContext::PumpTimeout`. `pass_timeout: nil`
  turns the limit off. `PumpJob` does not retry; the error goes to your queue backend.

Two optional hooks, both called in the thread that called `run`:

```ruby
runner = RubyLLM::InfiniteContext::Pump::Runner.new(tree,
  before_pass: ->(count) { spend_ok?(count) },         # false or Pump::Hold: stop before the pass
  on_result: ->(r) { stats.add(r.level, r.index, r.ok, r.tries) })
runner.run
runner.held?   # true when before_pass stopped the run
```

- `before_pass` gets the number of nodes the next pass would start. If it returns `false` or
  raises `RubyLLM::InfiniteContext::Pump::Hold`, `run` returns at once, before the pass
  sends any model call. Any other error in it also stops the run (its class is logged).
- `on_result` gets one `Pump::Result` (`level`, `index`, `ok`, `tries`; numbers only, never
  text) for each node result, after each pass, also for a pass that ended with an error.
  `tries` is nil for a failed node. A `StandardError` in it is logged (its class only) and
  ignored; any other exception (`Interrupt`) is raised after all the pass's results.

In a process that does not eager-load your app (a rake task, where Rails sets
`rake_eager_load` to false, or development), the worker threads load your classes the first
time they use them, all at once. Two files that refer to each other while they load can then
wait on each other forever, and the pass times out. The gem loads RubyLLM before the first
worker starts. If you pass your own `builder:` or `chat_options:`, load their classes first:
call `Rails.application.eager_load!` at the start of the task, or set
`config.rake_eager_load = true`.

## How it works

- **Log** (`ric_entries`): append-only, never updated or deleted.
- **Tree** (`ric_nodes`): node `(level, i)` covers entries `[i·2^level, (i+1)·2^level)`.
  A source that fits in 512 bytes is its own node with no model call; otherwise the compactor
  model compresses or merges it, with the view as context, up to 5 tries to fit under 512
  bytes (the shortest try wins). Built once, never recomputed.
- **Views** (`ric_views`): one saved view per budget. The view only appends at the end and
  merges the most due adjacent pair whose parent is built; it never splits, so older stretches
  sit in coarser and coarser lines (the sawtooth). A saved view is never rebuilt from the log;
  at each read it is fitted again, because lines grow when the pump builds their nodes.
  The budget covers the whole text the agent receives: each line with its `id+n|` label and
  line break, and the `<chat>` tags. While parents are not built yet, the lines shown merge
  anyway (a merged line shows "not summarized yet" until the pump builds it), and if that is
  not enough the oldest lines are left out behind one short line, and the logger gets the
  count. `view_lines(budget)` never returns more than the budget (at least 256 bytes,
  `MIN_VIEW_BUDGET`). The compactor's own context is bounded the same way.
  The compactor works against its own 24 KB view, separate from whatever the consumer sees.
- **Zoom** (`ric_zoom_events`): `zoom(id, n)` opens a line into the two lines it was built
  from; `zoom(id, 1)` shows the message, paged when long (`read(id, page)`). Opening a line
  the agent already opened this turn returns "you already opened this line; its text is
  above" instead of the text again, and a per-turn cap (12 by default) bounds runaway zooming.
  Zoom reaches every message of the tree, and so does search (opt-in, see above): in a tree
  shared by a group, a member who joined late can open or find older talk. The app owns that
  rule.
- **Counters, not rewrites**: nodes count `dig_count` and `last_dug_at`; zoom events record
  the leaf a dig reached, the steps it cost, and the turn. No parent rewrite, no fold boost:
  the shipped action on repeated digs is `:none` (do nothing) until data supports one.
- **Tool pairs**: a tool result is summarized with its call as context, so the pair survives
  as one fact.
- **Prompt caching** (`CacheMark`): for providers that accept explicit cache breakpoints
  (Anthropic), the view is sent as fixed blocks of 8 parts with one mark on the part the next
  messages will not change. Other providers rely on implicit prefix caching. Build the blocks from
  `tree.shown_view(budget)` with `CacheMark.shown_blocks`: it plans against the lines shown.

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
rake            # the tests, the tests again with encryption on, then standard
rake test
rake test:encrypted
rake standard
```

## License

MIT. See `THIRD_PARTY_NOTICES.md` for third-party credits.
