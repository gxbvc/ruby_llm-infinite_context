# Benchmark

A public, synthetic benchmark of memory quality and cost. The corpus is
generated (`generate_corpus.rb`): agent sessions with known gold facts
(names, numbers, paths, decisions) and questions with gold answers. No
real user data is used anywhere in it, so anyone can rerun the
benchmark.

## Generate the corpus (free, no API)

```
ruby bench/generate_corpus.rb --sessions 20 --turns 40 --out bench/corpus
```

## Dry run the machinery (free, no API)

```
ruby bench/dry_run.rb
```

A small generated corpus goes through trees, the pump (a fake builder, no
model) and the layer-1 metrics. A pass says the machinery works; it says
nothing about real model quality.

## Paid rounds are disabled by default

`PAID_RUNS_ENABLED` is false by default, so paid runs are off. `--yes` (and any `--y`
abbreviation) is refused at the very top of `run_bench.rb`, before any
library loads or any model is initialized, and the real provider path is
shut inside the `Runner` itself. Only a preflight works from the command
line, and it makes no model call and creates no ledger:

```
ruby bench/run_bench.rb --corpus bench/corpus \
  --compactor claude-haiku-4-5 --reader claude-haiku-4-5 --preflight
```

Preflight fails closed when a model has no known price. A Fireworks model
always needs an explicit price entry (`--prices FILE`, JSON of
`{"model-id": {"input": USD_PER_MILLION, "output": USD_PER_MILLION}}`).

## The spend meter

`spend_guard.rb` holds a durable round ledger and a per-request guard. It is
tested over a fake in-process network with real RubyLLM chats, and it is
not a substitute for provider spend limits. How it works:

- One ledger file (JSON, flock, fsync, atomic rename) holds the total
  spend, with a default cap of $20. Every run, on every provider, must
  share the same ledger path (`--ledger`; the default is
  `~/.local/state/ruby_llm-infinite_context/bench-ledger.json`). Whoever
  creates the file, its recorded total cap is $20; a person can edit it
  down, and no caller can raise it.
  A malformed ledger fails closed. A smaller `--cap` limits that one run
  only. A per-run limit is `--run-cap USD` (the guard's `run_cap_usd`): this
  run's own reservations may not pass it, while its spend still lands in the
  one shared file, so every later run sees it with no manual step.
- Before EVERY rendered provider request, a `before_request` hook reserves a
  worst case in the ledger: payload bytes at the input price (a token is
  assumed to be at most a byte), plus a fixed hidden-input margin (default
  2,000 tokens at the input price, `--input-margin-tokens`) for tokens the
  provider adds that we cannot see (a tool-use system prompt, a chat
  template), plus the explicit max output at the output price, all times
  `max_retries + 1` (RubyLLM retries POSTs below the hook). If it does not
  fit, the hook raises and no request is sent. Tool-loop turns and the
  pump's compactor requests each reserve separately.
- `max_retries` is read from the chat's own provider connection (a RubyLLM
  context can differ from the global config): the larger of that config
  value and the value frozen into the connection. `--expect-retries N` (or
  `retries:` on the guard) must equal it or arming fails; a change after
  arming halts before the request.
- After the reply the reservation settles. `--settlement metered` (the
  default) settles down to the metered cost when retries are 0.
  `--settlement reservation` never settles below the reservation (reserve =
  final spend); use it for any live round, because a metered cost is the
  price table times the reported usage, not the provider's bill. With
  retries enabled it is never settled down in either mode. A reservation is
  never released: a failed request stays counted. A model with an explicit
  price entry is always costed from that entry, never from the registry.
- Fail closed and halt on: unknown or non-positive price, a missing metered
  cost, a reply costing more than its reservation, a reply reporting more
  output tokens than the bound, a payload without the output bound,
  fallbacks, and too many requests in one chat.

### Fireworks route

`fireworks_route.rb` pins the one allowed Fireworks request: `POST
https://api.fireworks.ai/inference/v1/chat/completions`, a fixed list of
open serverless model ids, and a body with only the keys `model messages
stream max_tokens|max_completion_tokens temperature tools tool_choice
parallel_tool_calls reasoning_effort thinking`. RubyLLM 2.1.1 sends an OpenAI-provider
chat to `/responses` with `store: false` unless the chat is built with
`protocol: :chat_completions`, so the guard refuses any Fireworks chat that
is not, at arm time, and refuses any body with another field (`store`,
`include`, `metadata`, `user`, ...) in the before_request hook, before any
network call. Fireworks reasoning is switched off (`reasoning_effort:
"none"`) because the Fireworks docs do not say that `max_tokens` bounds
reasoning tokens; see the guard's `forbid_thinking_tokens` halt. GLM-5.3
is the one exception: it cannot run with thinking off, so it runs under an
explicit thinking budget (`thinking`, see below).

### Live smoke test (disabled by default)

`smoke_test.rb` sends a few dozen live requests on a generated synthetic
corpus, in this order: DeepSeek V4.1 Flash (`reasoning_effort none` is
documented), Claude Haiku 4.5, then GLM-5.3-Flash. GLM runs only after one
single-request gate: reasoning on under a 1,024-token thinking budget, and
the reply must report no more thinking tokens than the max output sent
(1,280). Any other model halts the run on its first reasoning token. It
uses the shared $20 ledger with a $0.90 run sub-cap, `max_retries 0`,
explicit prices and `:reservation` settlement. Keys are read in-process
from the bench's default key folder,
`~/.config/infinite-context-bench/` (`anthropic.key` and
`fireworks.key`; one open, fstat: regular file, owned by you, no group or
other bits, at most 4,096 bytes, printable ASCII, no whitespace except one trailing newline), never
from the environment, and passed only to RubyLLM config. It is locked twice
(`SMOKE_ENABLED` here, `PAID_RUNS_ENABLED` in `run_bench.rb`); only the free
`--plan` mode works:

```
bundle exec ruby bench/smoke_test.rb --plan
```

Limits, stated plainly: provider billing is trusted to honor the max output
bound (reasoning tokens included) and the listed prices; a `before_request`
hook added after arming could rewrite the payload; calls made outside the
armed chat factory are not counted.

## What is scored

Layer 1, compactor quality (no reader needed):

- `fit_rate`: share of nodes within 512 bytes after the allowed tries.
- `ruler_copy_rate`: how often the ruler (a line of 512 dashes) leaked into
  a summary. An earlier internal test with Haiku raised this question.
- `mean_tries`: average attempts per node.
- `retention_by_level`: share of the corpus gold facts still findable in
  the built nodes at each level of the tree. If retention collapses
  between level 0 and the top, the tree is losing the user's own words as
  it merges. A half-built tree under-reports: a level with no nodes yet
  scores 0 for that session's facts.

Layer 2, end to end, at each view budget (default 4k, 20k, 60k bytes), for
each context strategy:

- `tree`: this gem's saved view, with the zoom/read/date tools.
- `cutoff` (baseline): the last `budget` bytes of the raw log, whole
  entries. This is what a chat without memory does.
- `rolling` (baseline): a verbatim tail of half the budget; older entries
  merge pair by pair with the compactor until the head fits the other
  half.

Each strategy reports:

- right / partial / wrong, by gold string against the reader's reply.
- zooms per question (tree only, including repeat asks; the guard should
  hold these at one per line per turn).
- USD per question, from the provider's reported cost.

Pick strategies with `--baselines cutoff,rolling` or `--baselines tree`.
