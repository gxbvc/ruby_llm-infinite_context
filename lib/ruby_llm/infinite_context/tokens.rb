# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # Budgets are UTF-8 bytes everywhere inside the gem. Callers think in
    # tokens, so two doors:
    #
    # - `20_000.tokens` via the refinement (`using RubyLLM::InfiniteContext::Tokens`),
    # - a `tokens:` keyword on attach, with_infinite_context and has_infinite_context.
    #
    # The estimator is a rough 4 bytes per token, right for English prose;
    # log text with code or non-ASCII runs heavier. Callers who need exact
    # token counts should pass `budget:` in bytes instead.
    BYTES_PER_TOKEN = 4

    def self.token_bytes(tokens)
      tokens * BYTES_PER_TOKEN
    end

    module Tokens
      refine Integer do
        def tokens = RubyLLM::InfiniteContext.token_bytes(self)
      end
    end

    # Resolves the budget from (bytes, tokens) arguments; bytes win when
    # both are given.
    def self.resolve_budget(budget: nil, tokens: nil)
      if budget
        budget
      elsif tokens
        token_bytes(tokens)
      else
        DEFAULT_VIEW_BUDGET
      end
    end
  end
end
