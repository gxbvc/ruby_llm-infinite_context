# frozen_string_literal: true

# ruby_llm-infinite_context: endless memory for RubyLLM 2.x chats and
# agents. Every message is logged, a cheap model compresses the log into a
# binary tree of one-line summaries, and the chat sees a saved view of the
# tree that fits a byte budget the caller picks. The agent gets tools to
# zoom into any line, down to the original message.
#
# Based on Victor Taelin's OptChat/UniiChat design
# (https://gist.github.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449)
# and on pi-optchat (https://github.com/jonaslsaa/pi-optchat). See README.md.

require_relative "infinite_context/version"

require "ruby_llm" # the full library: RubyLLM.chat and friends

module RubyLLM
  module InfiniteContext
    class Error < StandardError; end

    # A chat does not use RubyLLM::InfiniteContext.required_protocol.
    class ProtocolError < Error; end

    # A pump pass took longer than Pump::Runner's pass_timeout. The stuck
    # workers were stopped and their locations logged.
    class PumpTimeout < Error; end

    # Every pump worker of a pass ended, and a result is still missing.
    class PumpWorkerLost < Error; end

    NODE = 512              # target size of one summary line
    DEFAULT_VIEW_BUDGET = 128_000 # default consumer view budget, bytes
    COMPACT_VIEW_BUDGET = 24_000  # the compactor's own view, 16-32 KB
    MIN_VIEW_BUDGET = 256   # smallest view budget: the <chat> tags and the line that says lines were left out
    JOBS = 8                # compactor calls at once
    MARGIN = 64             # bytes a non-Claude compactor is asked to stay under NODE
    TRIES = 5               # attempts per node to get under NODE
    CAP = 30_000            # max characters of one stubbed tool result (head and tail)
    PAGE = 4_000            # bytes per page when reading a long message
    PLACEHOLDER = "(not summarized yet: zoom it)"
    ZOOM_CAP_PER_TURN = 12  # max lines the agent may open in one turn
    KINDS = %w[user assistant tool echo note].freeze
  end
end

require_relative "infinite_context/tree_math"
require_relative "infinite_context/schema"
require_relative "infinite_context/tokens"
require_relative "infinite_context/fold"
require_relative "infinite_context/prompts"
require_relative "infinite_context/chat_options"
require_relative "infinite_context/encryption"
require_relative "infinite_context/compactor"
require_relative "infinite_context/pump"
require_relative "infinite_context/cache_mark"
require_relative "infinite_context/zoom"
require_relative "infinite_context/tools"
require_relative "infinite_context/batch_import"
require_relative "infinite_context/manager"

begin
  require "rails"
  require_relative "infinite_context/models"
  require_relative "infinite_context/pump_job"
  require_relative "infinite_context/model"
  require_relative "infinite_context/engine"
rescue LoadError
  # Not a Rails app: the Active Record models load lazily on first use.
end
