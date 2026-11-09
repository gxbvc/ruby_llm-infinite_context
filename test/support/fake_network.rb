# frozen_string_literal: true

require "json"
require "faraday"
require "ruby_llm"

# A fake provider network for tests. Real RubyLLM::Chat objects run through
# the real payload rendering, the real before_request hooks and the real
# Faraday retry middleware; only the final HTTP hop is replaced by this
# in-process adapter, which counts requests and never opens a socket.
#
# Belt and braces: the API key is a placeholder and the API base points at
# the loopback discard port, so even a wiring mistake could not reach a
# provider or spend anything.
module FakeNetwork
  class Adapter < Faraday::Adapter
    def call(env)
      super
      FakeNetwork.requests << JSON.parse(env.body)
      FakeNetwork.calls << {method: env.method.to_s.upcase, url: env.url.to_s, path: env.url.path,
                            body: FakeNetwork.requests.last, headers: env.request_headers.to_h}
      step = FakeNetwork.script.shift
      step = FakeNetwork.default_reply if step.nil?
      raise step if step.is_a?(Class) && step <= Exception
      raise step if step.is_a?(Exception)

      save_response(env, 200, JSON.generate(step), {"content-type" => "application/json"})
      @app.call(env)
    end
  end
  Faraday::Adapter.register_middleware(fake_network: Adapter)

  class << self
    # Every request body that reached the "provider" (a started call).
    def requests = (@requests ||= [])

    # The same started requests with their HTTP method, URL and headers.
    def calls = (@calls ||= [])

    # Scripted replies (hashes) or exceptions to raise, consumed in order.
    def script = (@script ||= [])

    # The reply when the script is empty (Anthropic-shaped unless a test
    # sets another one; reset! puts it back).
    def default_reply = @default_reply || text_reply("ok")

    attr_writer :default_reply

    def reset!
      @requests = []
      @calls = []
      @script = []
      @default_reply = nil
    end

    # An Anthropic-shaped text reply with token usage (priced by the real
    # registry: Haiku 4.5 is $1 in / $5 out per million tokens).
    def text_reply(text, input_tokens: 100, output_tokens: 20, cache_read_tokens: nil, cache_write_tokens: nil)
      usage = {"input_tokens" => input_tokens, "output_tokens" => output_tokens}
      usage["cache_read_input_tokens"] = cache_read_tokens if cache_read_tokens
      usage["cache_creation_input_tokens"] = cache_write_tokens if cache_write_tokens
      {"id" => "msg_fake", "type" => "message", "role" => "assistant", "model" => "claude-haiku-4-5",
       "content" => [{"type" => "text", "text" => text}], "stop_reason" => "end_turn",
       "stop_sequence" => nil, "usage" => usage}
    end

    # An OpenAI-compatible chat-completions reply (what Fireworks returns
    # on POST /inference/v1/chat/completions), with optional reasoning tokens.
    def chat_completion_reply(text, model:, prompt_tokens: 100, completion_tokens: 20, reasoning_tokens: nil,
      cached_tokens: nil)
      usage = {"prompt_tokens" => prompt_tokens, "completion_tokens" => completion_tokens,
               "total_tokens" => prompt_tokens + completion_tokens}
      usage["prompt_tokens_details"] = {"cached_tokens" => cached_tokens} if cached_tokens
      usage["completion_tokens_details"] = {"reasoning_tokens" => reasoning_tokens} if reasoning_tokens
      {"id" => "chatcmpl-fake", "object" => "chat.completion", "model" => model,
       "choices" => [{"index" => 0, "message" => {"role" => "assistant", "content" => text},
                      "finish_reason" => "stop"}],
       "usage" => usage}
    end

    def tool_reply(name, input, id: "toolu_fake", input_tokens: 100, output_tokens: 20)
      {"id" => "msg_fake", "type" => "message", "role" => "assistant", "model" => "claude-haiku-4-5",
       "content" => [{"type" => "tool_use", "id" => id, "name" => name, "input" => input}],
       "stop_reason" => "tool_use", "stop_sequence" => nil,
       "usage" => {"input_tokens" => input_tokens, "output_tokens" => output_tokens}}
    end

    # Points RubyLLM at the fake network. Returns the previous settings so a
    # test can restore them.
    def install!(max_retries: 0)
      config = RubyLLM.config
      previous = {adapter: config.faraday_adapter, key: config.anthropic_api_key,
                  base: config.anthropic_api_base, retries: config.max_retries,
                  interval: config.retry_interval}
      RubyLLM.configure do |c|
        c.faraday_adapter = :fake_network
        c.anthropic_api_key = "placeholder-not-a-key"
        c.anthropic_api_base = "http://127.0.0.1:9"
        c.max_retries = max_retries
        c.retry_interval = 0.0
      end
      previous
    end

    def restore!(previous)
      RubyLLM.configure do |c|
        c.faraday_adapter = previous[:adapter]
        c.anthropic_api_key = previous[:key]
        c.anthropic_api_base = previous[:base]
        c.max_retries = previous[:retries]
        c.retry_interval = previous[:interval]
      end
    end
  end
end
