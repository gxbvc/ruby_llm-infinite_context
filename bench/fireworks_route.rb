# frozen_string_literal: true

# The one place that pins how a Fireworks request may leave this bench:
#
# - POST https://api.fireworks.ai/inference/v1/chat/completions only. RubyLLM
#   2.1.1 sends an OpenAI-provider chat to POST {openai_api_base}/responses
#   (with store:false) UNLESS the chat is built with protocol:
#   :chat_completions. This module builds the chat that way and refuses any
#   chat that is not.
# - Model ids only from a fixed list of open serverless models.
# - No storing or logging field in the body: the rendered body may carry
#   only the keys in ALLOWED_BODY_KEYS. "store", "include", "metadata",
#   "user", "safety_identifier", "prompt_cache_key", "input" and anything
#   else are refused.
#
# Everything here runs BEFORE any network call: verify_chat! at arm time and
# verify_payload! in the chat's before_request hook (Guard calls both for any
# Fireworks model id). No key is read here; the caller passes it.

require "json"
require "ruby_llm"

module Bench
  class Error < StandardError; end unless const_defined?(:Error, false)
  class RouteRefused < Error; end

  module FireworksRoute
    API_BASE = "https://api.fireworks.ai/inference/v1"
    PATH = "/inference/v1/chat/completions"

    # The fixed list of open serverless models this bench uses. Add an id
    # here only after you check it is a plain serverless model.
    ALLOWED_MODELS = %w[
      accounts/fireworks/models/glm-5p3-flash
      accounts/fireworks/models/deepseek-v4p1-flash
    ].freeze

    # What RubyLLM 2.1.1 puts in a chat-completions body for a plain chat
    # (with tools): model, messages, stream, the max-output field, and, with
    # tools, tools/tool_choice/parallel_tool_calls. reasoning_effort is the
    # thinking control. Nothing else is allowed.
    ALLOWED_BODY_KEYS = %w[
      model messages stream max_tokens max_completion_tokens temperature
      tools tool_choice parallel_tool_calls reasoning_effort thinking
    ].freeze

    # The Fireworks reasoning guide's Anthropic-compatible `thinking` object
    # takes budget_tokens "Must be >= 1024" (docs.fireworks.ai/guides/reasoning).
    # `thinking` is allowed in a body ONLY in the exact form
    # {type: "enabled", budget_tokens: N} with the N the caller declared, and
    # never together with reasoning_effort (the docs make that a validation
    # error). The other documented sub-fields (keep, budget_end_str) are refused.
    THINKING_BUDGET_RANGE = (1_024..8_192)

    module_function

    def fireworks_model?(model_id) = model_id.to_s.match?(/fireworks/i)

    # A RubyLLM context (its own config object) for Fireworks: the OpenAI-
    # compatible client pointed at the Fireworks base, and max_retries set
    # explicitly. The key is passed in by the caller, never read here.
    def context(api_key:, max_retries: 0)
      RubyLLM.context do |config|
        config.openai_api_key = api_key
        config.openai_api_base = API_BASE
        config.max_retries = max_retries
      end
    end

    # A chat on the chat-completions route. `context` is the one from
    # #context. By default reasoning is off (reasoning_effort "none"). With
    # thinking_budget: N (an Integer in THINKING_BUDGET_RANGE) reasoning is ON
    # with a budget: the body carries thinking {type: "enabled",
    # budget_tokens: N} and no reasoning_effort. RubyLLM's with_thinking does
    # not render a budget on chat completions, so the object goes in as a
    # provider option; the guard re-checks the rendered body.
    def chat(model:, context:, reasoning_effort: :default, thinking_budget: nil)
      effort = if reasoning_effort == :default
        thinking_budget ? nil : :none
      else
        reasoning_effort
      end
      raise ArgumentError, "thinking_budget and reasoning_effort cannot be combined" if thinking_budget && effort

      chat = context.chat(model: model, provider: :openai, protocol: :chat_completions,
        assume_model_exists: true)
      chat.with_thinking(effort: effort) if effort
      if thinking_budget
        check_budget!(thinking_budget)
        chat.with_provider_options(thinking: {type: "enabled", budget_tokens: thinking_budget})
      end
      chat
    end

    def check_budget!(budget)
      return budget if budget.is_a?(Integer) && THINKING_BUDGET_RANGE.cover?(budget)

      raise ArgumentError, "thinking budget must be an Integer in #{THINKING_BUDGET_RANGE}, got #{budget.inspect}"
    end

    def verify_chat!(chat, model)
      refuse!("model #{model.inspect} is not on the fixed serverless list #{ALLOWED_MODELS.inspect}") unless ALLOWED_MODELS.include?(model.to_s)
      provider = chat.provider
      refuse!("provider is #{provider.slug.inspect}, not the OpenAI-compatible client pointed at Fireworks") unless provider.slug.to_s == "openai"
      refuse!("api base is #{provider.api_base.inspect}, not #{API_BASE}") unless provider.api_base == API_BASE
      protocol = chat.instance_variable_get(:@protocol)
      unless protocol.to_s == "chat_completions"
        refuse!("protocol is #{protocol.inspect}; only :chat_completions (POST #{PATH}) is allowed, " \
                "the default is /responses")
      end
      true
    end

    # Called on the final rendered body (provider options included).
    # thinking_budget: the budget this chat declared, or nil for a chat with
    # no thinking object (then any `thinking` field is refused).
    def verify_payload!(payload, thinking_budget: nil)
      body = payload.to_h.transform_keys(&:to_s)
      extra = body.keys - ALLOWED_BODY_KEYS
      refuse!("body carries field(s) outside the allowlist: #{extra.inspect}") unless extra.empty?
      verify_thinking!(body, thinking_budget)
      refuse!("body has no messages array (not a chat-completions body)") unless body["messages"].is_a?(Array)
      refuse!("model #{body["model"].inspect} is not on the fixed serverless list") unless ALLOWED_MODELS.include?(body["model"].to_s)
      refuse!("streaming is not allowed here") unless body["stream"] == false
      true
    end

    def verify_thinking!(body, budget)
      if budget.nil?
        refuse!("body carries a thinking object but the chat declared no thinking budget") if body.key?("thinking")
        return
      end
      check_budget!(budget)
      refuse!("body has reasoning_effort together with thinking") if body.key?("reasoning_effort")
      thinking = body["thinking"]
      thinking = JSON.parse(JSON.generate(thinking)) if thinking.is_a?(Hash)
      expected = {"type" => "enabled", "budget_tokens" => budget}
      refuse!("thinking must be exactly #{expected.inspect}, got #{thinking.inspect}") unless thinking == expected
    end

    def refuse!(message)
      raise RouteRefused, "Fireworks route refused: #{message}"
    end
  end
end
