# Changelog

All notable changes to this gem. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the gem follows
[Semantic Versioning](https://semver.org/).

## [0.2.3] - not yet released

### Fixed

- The view could be larger than its budget. In one app a view at `tokens: 20_000` (80,000
  bytes) was 101,096 bytes. Found by a GXB app's tree check. Four causes, all fixed:
  - A saved view was fitted only when new entries arrived. When the pump later built the
    nodes behind its lines, each line grew from the placeholder to its summary, and nothing
    merged them. Now the saved view is fitted again at every read. The fit only merges
    lines, so the saved view stays stable, and it is saved only when it changed.
  - The fold counted the text of each line, but not its `id+n|` label, its line break or
    the `<chat>` tags (about 2% over). Now the budget covers the whole rendered view.
  - While parents were not built, the fold stopped over budget with no limit. Now the
    lines shown merge the most due pairs anyway; a merged line shows the placeholder (the
    agent can zoom it) until the pump builds it. This merge is not saved, so the pump's
    order does not change.
  - A short entry with no node was counted as the 30-byte placeholder but shown word for
    word (up to 512 bytes). Now it counts at its own size.
- A last guard: if the view is still over budget, `Tree#view_lines` leaves out the oldest
  lines behind one short line ("(messages 0 to N are left out here to fit the view; zoom(id,
  1) still opens any of them)", with no `id+n|` label) and logs the counts (no text) to the
  `logger:` it is given (the Manager passes its own). What the agent receives, with the
  `<chat>` tags, is never over the budget.
- The compactor's context (`Tree#context_before`) could also pass its 24 KB budget while
  parents were pending. It now leaves out its oldest lines the same way (no forced merge,
  so the compactor never reads a placeholder for a stretch the pump has not built).
- Two readers of the same saved view could write it at the same time, and a reader with
  older node sizes could undo a newer reader's merges. A changed view is now written under
  the tree's row lock, fitted again from the row as it is then.
- The README and a code comment showed `view_lines(budget: 80_000)`; the budget is a
  positional argument: `view_lines(80_000)`.

### Added

- `Pump::Runner` hooks. `before_pass:` is called before each pass with the number of nodes
  it would start; if it returns false or raises `Pump::Hold`, the run ends before the pass
  sends anything (`held?` is true). An error in it ends the run too and is logged by class.
  `on_result:` is called once per node result with a `Pump::Result` (`level`, `index`,
  `ok`, `tries`; numbers only), also for a pass that ended with an error. A `StandardError`
  in it is logged by class and ignored; any other exception (`Interrupt`) is raised after
  every result was reported and after the pass's own error, if there is one. No result is lost.
- `RubyLLM::InfiniteContext.render_view(lines)`: the view as the agent receives it.
- `Tree#shown_view(budget, logger:)`: the lines shown with the parts behind them and the
  number of lines left out. `CacheMark.shown_blocks(shown, ...)` plans the cache blocks
  against those parts, and sends no mark when lines were left out.
- `MIN_VIEW_BUDGET` (256 bytes). A smaller view budget raises `ArgumentError`.

### Changed

- Views now merge a little earlier than before (labels and line breaks count), so a saved
  view can change shape at the first read after the upgrade. It only merges; no line splits.
- A view read loads the sizes of the nodes at the recent end of the view only, not of every
  node, so it does not grow slower with the log.

## [0.2.2] - not yet released

### Fixed

- `zoom(id, n)` with `n` of 2 or more recorded the wrong line as opened. It recorded the
  left child it showed (the line `id+n/2`), not the line it opened (`id+n`). So the repeat
  guard treated `zoom(id, 2)` and `zoom(id, 1)` as the same line: after `zoom(id, 2)`, the
  agent could not open message `id` (the even message of the pair) in that turn, and after
  `zoom(id, 1)` it could not open the pair. Zooms with `n` of 4 or more did not block each
  other, but the "already opened" message named the child, not the line. Now a zoom records the
  line it opened. A repeat of the same zoom is still refused, both children and both
  messages of a pair can be opened in the same turn, and the per-turn cap counts each opened
  line once. Found by a GXB app's tree check.
- The counters had the same error. For `n` of 2 or more, the zoom event (`level`, `i`) and
  the node's `dig_count` and `last_dug_at` were recorded on the left child, not on the line
  opened. Now they are recorded on the line opened: `zoom(id, n)` counts node
  `(log2(n), id / n)`. Zoom events written by 0.2.0 and 0.2.1 are one level too low for `n`
  of 2 or more: an event at `(level, i)` with `leaf_idx` nil was really an open of
  `(level + 1, i / 2)`. Message zooms (`zoom(id, 1)`, `leaf_idx` set) were recorded
  correctly. Because the pump stores short messages as level-0 nodes, the even message of
  each pair also got the dig counts of its pair. A node's `dig_count` can mix both kinds of
  open, so it cannot be corrected by itself; to correct old counters, rebuild `dig_count`
  and `last_dug_at` from the zoom events with the mapping above.

## [0.2.1] - not yet released

### Fixed

- `Pump::Runner` could wait forever. The main thread waited for one result from every worker
  thread, and a worker sent its result only after a normal end or a `StandardError` inside
  the Rails executor. A worker that ended any other way (an exception that is not a
  `StandardError`, an error in the executor's own hooks, a killed thread) or that never ended
  (stuck on a lock) left the pump waiting with no error. Found in production in one of GXB's
  apps, where five workers sat on a lock with no network traffic. Now:
  - Every worker sends exactly one result, whatever ends it. A `StandardError` in the
    executor's hooks and a killed worker are logged, and the node is tried again.
  - An exception that is not a `StandardError` (`NoMemoryError`, `SystemStackError`,
    `Interrupt`) is raised in the calling thread after the pass, like `ProtocolError`.
  - Each pass has a limit, `pass_timeout:` (15 minutes by default, `nil` for none). Past it,
    the log gets each stuck worker's location (file, line and method only), the stuck
    threads are stopped, and the run raises `RubyLLM::InfiniteContext::PumpTimeout` (or a
    fatal error that a worker reported before the limit). From that point no worker starts
    to store a node, and a store already running gets 5 seconds to finish before the kill.
    A thread that ignores the kill is left behind and logged. A model call that was already
    sent cannot be taken back.
  - A node counts as built only when the Rails executor has finished too. A logger that
    raises no longer stops a worker from reporting.
  - If every worker has ended and a result is still missing, the run raises
    `RubyLLM::InfiniteContext::PumpWorkerLost` at once.
  - If the calling thread leaves a pass early (an `Interrupt` there, for example), the
    workers of that pass are stopped.
- The pump loads RubyLLM's lazy constants once, before its first worker starts, so the
  workers do not autoload them at the same time. The README ("Threads") shows how to do the
  same for your own builder in a rake task or another process that does not eager-load.
- `PumpJob` has no retry: a stopped pump fails the job once.

## [0.2.0] - not yet released

### Added

- `RubyLLM::InfiniteContext.encrypt_text = true`: Active Record Encryption (non-deterministic)
  on `ric_entries.text` and `ric_nodes.text`. It works if the models load before or after the
  setting, declares `encrypts` once, and cannot be turned off again in the same process. The
  gem never searches these columns in SQL, so every feature works with it on. The README shows
  the setup, the rules, and how to declare it yourself with `to_prepare`.
- `RubyLLM::InfiniteContext.required_protocol = :chat_completions`: every chat the gem builds
  or uses (the compactor, the pump and `PumpJob`, each turn of `attach` and the
  `Model` concern, and chats passed in by the caller) must use that protocol. Any other
  protocol, none, a chat whose protocol cannot be read, or a fallback to another provider
  raises `RubyLLM::InfiniteContext::ProtocolError` before a request is sent. `BatchImport`
  (`submit` and `collect!`) always raises `ProtocolError` under this rule, before it logs or
  submits anything: provider batch jobs are not chat completions calls. Load old threads with
  `tree.append` and `Pump::Runner` instead.
- `rake test:encrypted` runs the library tests again with encryption on; `rake` runs both.

### Changed

- `Manager#turn` builds the chat before it logs the user's message, so a chat that fails to
  build leaves no half turn in the log.
- The pump stops and raises on a `ProtocolError` instead of logging it and retrying.

## [0.1.0] - 2026-11-09

First version. The gem is not on rubygems.org yet.

### Added

- The log, the summary tree and the saved views: `ric_entries`, `ric_nodes`, `ric_views`,
  `ric_zoom_events` and `ric_trees` (json columns and row locks, so SQLite and Postgres both
  work). Install with `rails g ruby_llm:infinite_context:install`.
- The compactor, with up to 5 tries to fit a node under 512 bytes, and the pump that builds
  the tree in parallel (`Pump::Runner`, `PumpJob` for ActiveJob).
- Saved views that fit a byte budget the caller picks, with the sawtooth merge. Budgets are
  bytes everywhere; `tokens:` and `20_000.tokens` (after
  `using RubyLLM::InfiniteContext::Tokens`) convert once at the API edge at 4 bytes per token.
- The `zoom`, `read` and `date` tools, with a repeat-zoom guard and a per-turn cap.
- Counters: `dig_count`, `last_dug_at` and the zoom-event table. No rewrites yet.
- Tool call and result are summarized as a pair.
- Prompt-cache marks for providers with explicit breakpoints (Anthropic).
- `RubyLLM::InfiniteContext.attach` (also `Manager.attach`) and the `Model` concern with
  `has_infinite_context`.
- `provider:`, `protocol:`, `assume_model_exists:` and `context:` pass-through for the chats the
  gem builds (`chat_options:`, `compactor_options:`, `compactor_chat_options`). RubyLLM 2.1.1
  sends an OpenAI-provider chat to the Responses API by default; Fireworks and other
  OpenAI-compatible services need `protocol: :chat_completions`. See the README.
- `BatchImport` for compressing an existing long thread at batch prices with `RubyLLM::Batch`.
- A public, synthetic benchmark in `bench/` (not part of the gem package), and a spend guard
  for paid benchmark rounds. Paid runs are disabled in this release; the guard has only been
  tested over a fake network.

### Differences to know about

- `has_infinite_context` is a plain concern: the model needs `acts_as_chat` as well. The record
  names the model, and each turn builds a fresh chat from it. The record's own message history
  is not sent; the tree is the memory.
- The `20_000.tokens` literal needs `using RubyLLM::InfiniteContext::Tokens`. The `tokens:`
  keyword does not.
- The agent tools are `zoom`, `read` and `date`.
- The action on repeated digs ships as `:none` only. The counters are there so a later release
  can decide from data.

### Known limits

- Token budgets use a rough 4 bytes per token. For exact budgets, pass bytes.
- Nothing in this release has been run against a live model provider by its authors' test
  suite; the suite uses a fake network.
