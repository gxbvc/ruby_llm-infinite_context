# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"

module RubyLLM
  module InfiniteContext
    # Active Record Encryption on the text columns (encrypt_text). This file
    # runs twice: in `rake test` (encryption off: the raw columns hold the
    # plain text, nothing changes) and in `rake test:encrypted` (on: the raw
    # columns hold ciphertext and the models read the plain text back).
    class EncryptionTest < Minitest::Test
      SECRET = "Zephyrine-greenhouse-sensor-4471"
      LONG = "#{SECRET} reports the north vent stuck open. " * 100 # over NODE and over PAGE

      def raw(table, id)
        conn = ActiveRecord::Base.connection
        conn.select_value("SELECT text FROM #{table} WHERE id = #{Integer(id)}")
      end

      def assert_ciphertext(raw_value, plain)
        refute_equal plain, raw_value
        refute_includes raw_value, SECRET
        refute_includes raw_value, "north vent"
        message = JSON.parse(raw_value)
        assert message.key?("p"), "an Active Record Encryption message has a payload"
        assert message.key?("h"), "an Active Record Encryption message has headers"
      end

      # A compactor chat that answers with a line naming the secret, so the
      # node text is sensitive too.
      def compactor_factory
        lambda do
          chat = Object.new
          chat.define_singleton_method(:with_instructions) { |_t| chat }
          chat.define_singleton_method(:ask_later) { |_t| chat }
          chat.define_singleton_method(:ask) do |_t|
            reply = Object.new
            reply.define_singleton_method(:content) { "#{SECRET}: north vent stuck open" }
            reply
          end
          chat
        end
      end

      def build_tree
        tree = Tree.for("encryption-test", compactor: "test-compactor")
        tree.append(:user, LONG)
        tree.append(:assistant, "short reply about #{SECRET}")
        compactor = Compactor.new(tree, model: "test-compactor", chat_factory: compactor_factory)
        Pump::Runner.new(tree, builder: compactor, jobs: 1).run
        tree
      end

      def test_the_flag_matches_the_run
        assert_equal TEST_ENCRYPTED, InfiniteContext.encrypt_text?
        assert_equal TEST_ENCRYPTED, Encryption.applied?
        assert_equal TEST_ENCRYPTED, Entry.encrypted_attributes.to_a.include?(:text)
        assert_equal TEST_ENCRYPTED, Node.encrypted_attributes.to_a.include?(:text)
      end

      def test_raw_columns_and_model_reads
        tree = build_tree
        long = tree.entry(0)
        short = tree.entry(1)
        node = tree.nodes.find_by(level: 0, i: 0)
        refute_nil node, "the pump built the node for the long entry"

        # The models always read the plain text.
        assert_equal LONG, long.reload.text
        assert_equal "short reply about #{SECRET}", short.reload.text
        assert_equal "#{SECRET}: north vent stuck open", node.reload.text
        assert_equal TreeMath.bytes(LONG), long.bytes

        if TEST_ENCRYPTED
          assert_ciphertext raw("ric_entries", long.id), LONG
          assert_ciphertext raw("ric_entries", short.id), short.text
          assert_ciphertext raw("ric_nodes", node.id), node.text
          # Ciphertext is longer than short plain text (base64 plus headers).
          assert_operator raw("ric_entries", short.id).bytesize, :>, short.text.bytesize
        else
          assert_equal LONG, raw("ric_entries", long.id)
          assert_equal short.text, raw("ric_entries", short.id)
          assert_equal node.text, raw("ric_nodes", node.id)
        end
      end

      def test_view_zoom_read_and_date_work
        tree = build_tree
        lines = tree.view_lines(10_000)
        assert_equal 2, lines.size
        assert_equal "0+1|#{SECRET}: north vent stuck open", lines[0]
        assert_equal "1+1|short reply about #{SECRET}", lines[1]
        refute_includes tree.views.pluck(:parts).to_s, SECRET

        zoom = Zoom.new(tree, Turn.new)
        page1 = zoom.zoom(0, 1)
        assert page1.start_with?(LONG.byteslice(0, PAGE))
        assert_includes page1, "read(0, 2)"
        assert zoom.read(0, 2).start_with?(LONG.byteslice(PAGE, PAGE))
        assert_equal "0+1|#{SECRET}: north vent stuck open", Zoom.new(tree, Turn.new).zoom(0, 2).lines.first.chomp
        assert_match(/\A\w{3} \d{4}-\d{2}-\d{2} /, zoom.date(1))
      end

      def test_compactor_reads_the_plain_text
        tree = Tree.for("encryption-compactor", compactor: "test-compactor")
        tree.append(:user, LONG)
        seen = []
        factory = lambda do
          chat = Object.new
          chat.define_singleton_method(:with_instructions) { |_t| chat }
          chat.define_singleton_method(:ask_later) { |_t| chat }
          chat.define_singleton_method(:ask) do |text|
            seen << text
            reply = Object.new
            reply.define_singleton_method(:content) { "one line" }
            reply
          end
          chat
        end
        text, tries = Compactor.new(tree, model: "test-compactor", chat_factory: factory).build(0, 0)
        assert_equal ["one line", 1], [text, tries]
        assert_includes seen.first, SECRET
      end

      # -- load order and the off switch, in a fresh process ---------------------

      def run_ruby(script)
        lib = File.expand_path("../lib", __dir__)
        out, status = Open3.capture2e(RbConfig.ruby, "-I", lib, "-e", script)
        [out, status]
      end

      def test_flag_set_before_the_models_load
        script = <<~RUBY
          require "ruby_llm/infinite_context"
          RubyLLM::InfiniteContext.encrypt_text = true
          require "ruby_llm/infinite_context/models"
          m = RubyLLM::InfiniteContext
          puts [m::Entry, m::Node].map { |k| k.encrypted_attributes.to_a.inspect }.join(" ")
          puts Array(m::View.encrypted_attributes).inspect
        RUBY
        out, status = run_ruby(script)
        assert status.success?, out
        assert_equal "[:text] [:text]\n[]\n", out
      end

      def test_flag_set_after_the_models_load_and_cannot_turn_off
        script = <<~RUBY
          require "ruby_llm/infinite_context"
          require "ruby_llm/infinite_context/models"
          m = RubyLLM::InfiniteContext
          m.encrypt_text = false
          puts m::Entry.encrypted_attributes.to_a.inspect
          m.encrypt_text = true
          m.encrypt_text = true # a second call declares nothing twice
          puts [m::Entry, m::Node].map { |k| k.encrypted_attributes.to_a.inspect }.join(" ")
          begin
            m.encrypt_text = false
            puts "no error"
          rescue m::Error => e
            puts e.message
          end
        RUBY
        out, status = run_ruby(script)
        assert status.success?, out
        assert_equal "[]\n[:text] [:text]\nencrypt_text cannot be turned off once it is on (restart the process)\n", out
      end

      def test_flag_cannot_turn_off_before_the_models_load_either
        script = <<~RUBY
          require "ruby_llm/infinite_context"
          m = RubyLLM::InfiniteContext
          m.encrypt_text = true
          begin
            m.encrypt_text = false
            puts "no error"
          rescue m::Error => e
            puts e.message
          end
          require "ruby_llm/infinite_context/models"
          puts m.encrypt_text?
          puts m::Entry.encrypted_attributes.to_a.inspect
        RUBY
        out, status = run_ruby(script)
        assert status.success?, out
        assert_equal "encrypt_text cannot be turned off once it is on (restart the process)\ntrue\n[:text]\n", out
      end

      def test_without_keys_the_first_write_fails_closed
        script = <<~RUBY
          require "ruby_llm/infinite_context"
          require "ruby_llm/infinite_context/models"
          RubyLLM::InfiniteContext.encrypt_text = true
          ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
          RubyLLM::InfiniteContext::Schema.create!
          tree = RubyLLM::InfiniteContext::Tree.for("no-keys")
          begin
            tree.append(:user, "hello")
            puts "written"
          rescue ActiveRecord::Encryption::Errors::Configuration => e
            puts "refused"
          end
          puts ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM ric_entries")
        RUBY
        out, status = run_ruby(script)
        assert status.success?, out
        assert_equal "refused\n0\n", out
      end
    end
  end
end
