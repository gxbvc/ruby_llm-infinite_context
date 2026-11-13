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
    # both are given. A budget under MIN_VIEW_BUDGET bytes raises
    # ArgumentError.
    def self.resolve_budget(budget: nil, tokens: nil)
      resolved = if budget
        budget
      elsif tokens
        token_bytes(tokens)
      else
        DEFAULT_VIEW_BUDGET
      end
      check_view_budget!(resolved)
    end

    # Returns the budget, or raises ArgumentError when it is not an Integer
    # of at least MIN_VIEW_BUDGET bytes (smaller views cannot be kept within
    # their budget).
    def self.check_view_budget!(budget)
      unless budget.is_a?(Integer) && budget >= MIN_VIEW_BUDGET
        raise ArgumentError, "a view budget must be an Integer of at least #{MIN_VIEW_BUDGET} bytes"
      end

      budget
    end
  end
end
