# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"
require "rails/generators/active_record"

module RubyLLM
  module InfiniteContext
    module Generators
      # `rails g ruby_llm:infinite_context:install` copies the migration
      # that creates the ric_ tables.
      class InstallGenerator < ::Rails::Generators::Base
        include ::Rails::Generators::Migration

        # Set by hand: Rails would derive "ruby_l_l_m:..." from the class
        # name (RubyLLM), and `rails g ruby_llm:infinite_context:install`
        # would not be found.
        namespace "ruby_llm:infinite_context:install"

        source_root File.expand_path("templates", __dir__)
        desc "Creates the ric_ tables for ruby_llm-infinite_context"

        # Rails::Generators::Migration leaves this to the including class.
        def self.next_migration_number(dir)
          ::ActiveRecord::Generators::Base.next_migration_number(dir)
        end

        def copy_migration
          migration_template "migration.rb.tt", "db/migrate/create_ruby_llm_infinite_context_tables.rb"
        end
      end
    end
  end
end
