# Changelog

All notable changes to this gem. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the gem follows
[Semantic Versioning](https://semver.org/).

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
