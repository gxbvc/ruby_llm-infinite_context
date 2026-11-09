# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ruby_llm/infinite_context"
require "ruby_llm/infinite_context/models"
require "ruby_llm/infinite_context/model"
require "minitest/autorun"

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
