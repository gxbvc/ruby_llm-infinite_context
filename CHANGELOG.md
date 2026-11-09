# Changelog

All notable changes to this gem. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the gem follows
[Semantic Versioning](https://semver.org/).

## [0.1.0] - not yet released

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
