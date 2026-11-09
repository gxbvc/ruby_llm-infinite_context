# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # The tables, created by the install generator's migration. `json`
    # columns (not jsonb) and row locks keep SQLite and Postgres both working.
    module Schema
      TABLES = %w[ric_trees ric_entries ric_nodes ric_views ric_zoom_events].freeze

      def self.migration(migrator)
        migrator.create_table :ric_trees do |t|
          t.string :key, null: false
          t.string :compactor_model
          t.json :options, null: false, default: {}
          t.timestamps
        end
        migrator.add_index :ric_trees, :key, unique: true

        # The append-only log. Never updated or deleted.
        migrator.create_table :ric_entries do |t|
          t.references :tree, null: false, index: false
          t.integer :idx, null: false
          t.string :kind, null: false
          t.text :text, null: false
          t.integer :bytes, null: false
          t.datetime :created_at, null: false
        end
        migrator.add_index :ric_entries, [:tree_id, :idx], unique: true

        # The summary tree. Node (level, i) covers entries
        # [i * 2^level, (i + 1) * 2^level). Built once, never recomputed.
        # dig_count and last_dug_at count how often the agent opened it.
        migrator.create_table :ric_nodes do |t|
          t.references :tree, null: false, index: false
          t.integer :level, null: false
          t.integer :i, null: false
          t.text :text, null: false
          t.integer :bytes, null: false
          t.integer :tries, null: false, default: 0
          t.integer :dig_count, null: false, default: 0
          t.datetime :last_dug_at
          t.datetime :created_at, null: false
        end
        migrator.add_index :ric_nodes, [:tree_id, :level, :i], unique: true

        # One saved view per budget.
        migrator.create_table :ric_views do |t|
          t.references :tree, null: false, index: false
          t.integer :budget, null: false
          t.json :parts, null: false, default: []
          t.integer :message_count, null: false, default: 0
          t.timestamps
        end
        migrator.add_index :ric_views, [:tree_id, :budget], unique: true

        # One row per zoom: the line opened, the leaf the dig reached (when
        # it went all the way down), the steps it cost, and the turn.
        migrator.create_table :ric_zoom_events do |t|
          t.references :tree, null: false, index: false
          t.string :session, null: false
          t.integer :level, null: false
          t.integer :i, null: false
          t.integer :leaf_idx
          t.integer :steps, null: false, default: 0
          t.datetime :created_at, null: false
        end
        migrator.add_index :ric_zoom_events, [:tree_id, :session]
        migrator.add_index :ric_zoom_events, [:tree_id, :level, :i]
      end

      # For tests and for apps that manage their own schema (no migration
      # file needed).
      def self.create!(connection = ::ActiveRecord::Base.connection)
        shim = Object.new
        shim.define_singleton_method(:create_table) { |*a, **o, &b| connection.create_table(*a, **o, &b) }
        shim.define_singleton_method(:add_index) { |*a, **o| connection.add_index(*a, **o) }
        migration(shim)
      end
    end
  end
end
