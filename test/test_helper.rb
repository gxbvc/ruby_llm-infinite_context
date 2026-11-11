# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ruby_llm/infinite_context"
require "ruby_llm/infinite_context/models"
require "ruby_llm/infinite_context/model"
require "minitest/autorun"

# Test-only Active Record Encryption keys (fixed, fake values; never used
# outside the tests). `rake test:encrypted` runs the whole suite again with
# RIC_TEST_ENCRYPT=1, which turns encryption on for the gem's text columns.
TEST_ENCRYPTION_KEYS = {
  primary_key: "ric-test-only-primary-key-not-a-secret",
  deterministic_key: "ric-test-only-deterministic-key-not-a-secret",
  key_derivation_salt: "ric-test-only-key-derivation-salt-not-a-secret"
}.freeze
ActiveRecord::Encryption.configure(**TEST_ENCRYPTION_KEYS)
TEST_ENCRYPTED = ENV["RIC_TEST_ENCRYPT"] == "1"
RubyLLM::InfiniteContext.encrypt_text = true if TEST_ENCRYPTED

# A file-backed SQLite database in tmp/: every thread and connection sees
# the same database, which the pump's worker threads need.
DB_PATH = File.expand_path("tmp/test.sqlite3", __dir__)
FileUtils.mkdir_p(File.dirname(DB_PATH))
File.unlink(DB_PATH) if File.exist?(DB_PATH)
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: DB_PATH, pool: 12)
ActiveRecord::Base.logger = nil
RubyLLM::InfiniteContext::Schema.create!

def reconnect_test_db
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: DB_PATH, pool: 12)
end

module Minitest
  class Test
    # Every test starts with empty tables.
    def before_setup
      %w[ric_zoom_events ric_views ric_nodes ric_entries ric_trees].each do |table|
        ActiveRecord::Base.connection.execute("DELETE FROM #{table}")
      end
      super
    end
  end
end
