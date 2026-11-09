# frozen_string_literal: true

require_relative "lib/ruby_llm/infinite_context/version"

Gem::Specification.new do |spec|
  spec.name = "ruby_llm-infinite_context"
  spec.version = RubyLLM::InfiniteContext::VERSION
  spec.authors = ["Christian Genco"]
  spec.email = ["christian@gxb.vc"]

  spec.summary = "Endless memory for RubyLLM 2.x chats: a summary tree, saved views that fit any budget, and zoom tools."
  spec.description = "A RubyLLM 2.x plugin. Every message is logged, a cheap model compresses the log into a " \
                     "binary tree of one-line summaries, and the chat sees a saved view of the tree that fits a " \
                     "budget the caller picks. The agent gets tools to zoom into any line, down to the original " \
                     "message. Based on Victor Taelin's OptChat/UniiChat design and on pi-optchat."
  spec.homepage = "https://github.com/gxbvc/ruby_llm-infinite_context"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # An allowlist, not "everything in git": the gem ships the library, the
  # generator templates and the docs, and never the bench, tests, results,
  # key files, ledgers or local state.
  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*", "README.md", "LICENSE.txt", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md"]
      .select { |f| File.file?(f) }
      .sort
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.1", "< 9"
  spec.add_dependency "ruby_llm", "~> 2.0"
end
