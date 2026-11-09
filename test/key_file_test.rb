# frozen_string_literal: true

require "test_helper"
require "support/fake_network"
require "tmpdir"
require "stringio"
require "logger"
require_relative "../bench/smoke_test"

module RubyLLM
  module InfiniteContext
    # Strict key-file handling for the smoke script.
    # Every file here is a TEMP file made by the test. The real key files
    # (~/.config/infinite-context-bench/*.key) are never created or read.
    class KeyFileTest < Minitest::Test
      # Distinctive, obviously fake key text, so any leak is easy to spot.
      FAKE_A = "sk-ant-FAKE-key-text-for-tests-ANT-0123456789"
      FAKE_F = "fw_FAKE-key-text-for-tests-FIRE-9876543210"

      def setup
        @dir = Dir.mktmpdir("key-file-test")
        @previous = FakeNetwork.install!(max_retries: 0)
        FakeNetwork.reset!
      end

      def teardown
        FakeNetwork.restore!(@previous)
        FileUtils.rm_rf(@dir)
      end

      def key_file(name, content, mode: 0o600)
        path = File.join(@dir, name)
        File.binwrite(path, content)
        File.chmod(mode, path)
        path
      end

      def both(anthropic: FAKE_A, fireworks: FAKE_F, mode: 0o600)
        key_file("anthropic.key", anthropic, mode: mode)
        key_file("fireworks.key", fireworks, mode: mode)
      end

      def refused(path)
        assert_raises(Bench::KeyFileRefused) { Bench::KeyFile.read(path, label: "t") }
      end

      # -- the rules -----------------------------------------------------------

      def test_a_good_file_is_read_exactly
        assert_equal FAKE_A, Bench::KeyFile.read(key_file("a.key", FAKE_A))
        assert_equal FAKE_A, Bench::KeyFile.read(key_file("b.key", FAKE_A, mode: 0o400))
      end

      def test_group_or_other_bits_are_refused_before_the_content_is_read
        [0o644, 0o640, 0o604, 0o660, 0o666, 0o601].each do |mode|
          error = refused(key_file("m#{mode.to_s(8)}.key", FAKE_A, mode: mode))
          assert_match(/group or other permission bits/, error.message)
          refute_includes error.message, FAKE_A
        end
      end

      def test_a_symlink_a_directory_and_a_missing_file_are_refused
        real = key_file("real.key", FAKE_A)
        link = File.join(@dir, "link.key")
        File.symlink(real, link)
        assert_match(/symlink/, refused(link).message)
        refused(@dir)
        refused(File.join(@dir, "nope.key"))
      end

      def test_empty_and_oversized_files_are_refused
        assert_match(/empty/, refused(key_file("e.key", "")).message)
        refute_nil Bench::KeyFile.read(key_file("ok.key", "k" * 4_096))
        assert_match(/larger than 4096/, refused(key_file("big.key", "k" * 4_097)).message)
      end

      def test_whitespace_control_and_non_ascii_characters_are_refused_and_never_echoed
        bad = {"space" => "#{FAKE_A} x", "tab" => "#{FAKE_A}\tx", "cr" => "#{FAKE_A}\r",
               "nul" => "#{FAKE_A}\0", "esc" => "\e#{FAKE_A}", "utf8" => "#{FAKE_A}é", "del" => "#{FAKE_A}\x7F",
               "bom" => "\xEF\xBB\xBF#{FAKE_A}", "inner newline" => "#{FAKE_A}\nSECOND-LINE-SECRET"}
        bad.each do |name, content|
          error = refused(key_file("c-#{name.tr(" ", "_")}.key", content))
          assert_match(/not printable ASCII/, error.message, name)
          refute_includes error.message, FAKE_A, name
          refute_includes error.message, "SECOND-LINE-SECRET", name
        end
      end

      # -- exactly one trailing newline is allowed ------------------------------

      def test_exactly_one_trailing_newline_is_accepted_stripped_and_the_file_is_not_touched
        path = key_file("nl.key", "#{FAKE_F}\n")
        before = File.binread(path)
        mtime = File.mtime(path)
        value = Bench::KeyFile.read(path)
        assert_equal FAKE_F, value, "returned without the newline"
        refute_includes value, "\n"
        assert_equal before, File.binread(path), "the key file is never modified"
        assert_equal mtime, File.mtime(path)
      end

      def test_anything_beyond_one_trailing_newline_is_refused_and_never_echoed
        bad = {"two newlines" => "#{FAKE_F}\n\n", "crlf" => "#{FAKE_F}\r\n", "leading newline" => "\n#{FAKE_F}",
               "space before newline" => "#{FAKE_F} \n", "tab before newline" => "#{FAKE_F}\t\n",
               "cr only" => "#{FAKE_F}\r", "newline then space" => "#{FAKE_F}\n ",
               "newline in the middle" => "#{FAKE_F}\nSECOND-LINE-SECRET\n", "only a newline" => "\n",
               "only two newlines" => "\n\n", "space" => " #{FAKE_F}"}
        bad.each do |name, content|
          error = refused(key_file("nlbad-#{name.tr(" ", "_")}.key", content))
          assert_match(/not printable ASCII|is empty/, error.message, name)
          refute_includes error.message, FAKE_F, name
          refute_includes error.message, "SECOND-LINE-SECRET", name
        end
      end

      def test_the_size_limit_counts_the_file_as_written_newline_included
        assert_equal "k" * 4_095, Bench::KeyFile.read(key_file("fit.key", "#{"k" * 4_095}\n"))
        assert_match(/larger than 4096/, refused(key_file("over.key", "#{"k" * 4_096}\n")).message)
      end

      def test_the_real_shapes_26_and_106_bytes_with_one_newline_are_accepted
        fw = "f" * 25 # a 26-byte file: the key plus one newline
        an = "a" * 105 # a 106-byte file
        assert_equal fw, Bench::KeyFile.read(key_file("real-fw-shape.key", "#{fw}\n"))
        assert_equal an, Bench::KeyFile.read(key_file("real-an-shape.key", "#{an}\n"))
        assert_equal 26, File.size(File.join(@dir, "real-fw-shape.key"))
        assert_equal 106, File.size(File.join(@dir, "real-an-shape.key"))
      end

      def test_a_newline_ended_file_reaches_ruby_llm_config_without_the_newline
        key_file("anthropic.key", "#{FAKE_A}\n")
        key_file("fireworks.key", "#{FAKE_F}\n")
        context = Bench::Smoke.apply_keys(Bench::Smoke.load_keys(dir: @dir))
        assert_equal FAKE_A, RubyLLM.config.anthropic_api_key
        assert_equal FAKE_F, context.config.openai_api_key
      end

      def test_a_file_owned_by_someone_else_is_refused
        path = key_file("a.key", FAKE_A)
        error = assert_raises(Bench::KeyFileRefused) { Bench::KeyFile.read(path, uid: Process.euid + 1) }
        assert_match(/not owned by the current user/, error.message)
        refute_includes error.message, FAKE_A
      end

      # -- the smoke script: refused before any request, no env, no leaks ------

      def test_a_0644_key_file_refuses_the_run_before_the_ledger_or_any_request
        both
        File.chmod(0o644, File.join(@dir, "fireworks.key"))
        ledger_path = File.join(@dir, "ledger", "bench-ledger.json")
        error = assert_raises(Bench::KeyFileRefused) do
          Bench::Smoke.run!(key_dir: @dir, ledger_path: ledger_path)
        end
        assert_match(/fireworks file .*fireworks\.key has group or other permission bits/, error.message)
        refute File.exist?(ledger_path), "no ledger was created"
        refute File.exist?(File.dirname(ledger_path)), "no ledger directory was created"
        assert_empty FakeNetwork.calls, "no provider request"
        refute_includes error.message, FAKE_F
        refute_includes error.message, FAKE_A
      end

      def test_either_file_missing_refuses_the_run_before_any_request
        key_file("anthropic.key", FAKE_A)
        assert_raises(Bench::KeyFileRefused) do
          Bench::Smoke.run!(key_dir: @dir, ledger_path: File.join(@dir, "ledger.json"))
        end
        refute File.exist?(File.join(@dir, "ledger.json"))
        assert_empty FakeNetwork.calls
      end

      # Records every path Bench::KeyFile.read is asked to open.
      def spy_key_reads
        reads = []
        original = Bench::KeyFile.method(:read)
        Bench::KeyFile.define_singleton_method(:read) do |path, **kw|
          reads << path
          original.call(path, **kw)
        end
        yield reads
      ensure
        Bench::KeyFile.define_singleton_method(:read, original)
      end

      # -- --models: only the key files the selected models need ----------------

      def test_models_default_to_all_three_and_the_run_order_is_kept
        assert_equal Bench::Smoke::MODELS, Bench::Smoke.select_models(nil)
        assert_equal %w[deepseek haiku glm], Bench::Smoke.select_models(nil).map { |m| m[:short] }
        assert_equal %w[deepseek glm], Bench::Smoke.select_models("glm,deepseek").map { |m| m[:short] }
        assert_equal %w[deepseek haiku glm], Bench::Smoke.select_models("glm,haiku,deepseek").map { |m| m[:short] }
        full = Bench::Smoke.select_models("accounts/fireworks/models/glm-5p3-flash,claude-haiku-4-5")
        assert_equal %w[haiku glm], full.map { |m| m[:short] }
      end

      def test_a_bad_models_list_is_refused
        ["bogus", "deepseek,deepseek", "deepseek,", "", "deepseek,gpt-5"].each do |list|
          assert_raises(Bench::Error, list.inspect) { Bench::Smoke.select_models(list) }
        end
      end

      def test_a_fireworks_only_selection_never_opens_the_anthropic_key_file
        key_file("fireworks.key", FAKE_F)
        key_file("anthropic.key", FAKE_A, mode: 0o644) # opening it would refuse: it must not be opened
        models = Bench::Smoke.select_models("deepseek,glm")
        assert_equal [:fireworks], Bench::Smoke.key_names(models)
        spy_key_reads do |reads|
          keys = Bench::Smoke.load_keys(dir: @dir, models: models)
          assert_equal({fireworks: FAKE_F}, keys)
          assert_equal [File.join(@dir, "fireworks.key")], reads
        end
      end

      def test_a_fireworks_only_run_without_any_anthropic_file_gets_past_key_loading
        key_file("fireworks.key", FAKE_F)
        models = Bench::Smoke.select_models("deepseek,glm")
        context = Bench::Smoke.apply_keys(Bench::Smoke.load_keys(dir: @dir, models: models))
        assert_equal FAKE_F, context.config.openai_api_key
      end

      def test_a_haiku_selection_without_anthropic_key_refuses_before_any_request
        key_file("fireworks.key", FAKE_F)
        ledger_path = File.join(@dir, "ledger", "bench-ledger.json")
        spy_key_reads do |reads|
          error = assert_raises(Bench::KeyFileRefused) do
            Bench::Smoke.run!(key_dir: @dir, ledger_path: ledger_path, models: Bench::Smoke.select_models("haiku"))
          end
          assert_match(/anthropic file .*anthropic\.key cannot be opened/, error.message)
          assert_equal [File.join(@dir, "anthropic.key")], reads, "the Fireworks file is not opened for a Haiku-only run"
        end
        refute File.exist?(File.dirname(ledger_path)), "no ledger or directory"
        assert_empty FakeNetwork.calls
      end

      def test_a_mixed_selection_missing_the_anthropic_file_refuses_before_any_request
        key_file("fireworks.key", FAKE_F)
        ledger_path = File.join(@dir, "ledger.json")
        assert_raises(Bench::KeyFileRefused) do
          Bench::Smoke.run!(key_dir: @dir, ledger_path: ledger_path, models: Bench::Smoke.select_models("deepseek,haiku"))
        end
        refute File.exist?(ledger_path)
        assert_empty FakeNetwork.calls
      end

      def test_a_fireworks_only_plan_names_no_anthropic_file_or_model
        text = Bench::Smoke.plan(models: Bench::Smoke.select_models("deepseek,glm"))
        refute_includes text, "anthropic.key"
        refute_includes text, "claude-haiku"
        assert_includes text, "infinite-context-bench/fireworks.key"
        assert_includes text, "GLM gate"
        assert_includes text, "deepseek-v4p1-flash -> accounts/fireworks/models/glm-5p3-flash"
        only_deepseek = Bench::Smoke.plan(models: Bench::Smoke.select_models("deepseek"))
        refute_includes only_deepseek, "GLM gate"
        refute_includes only_deepseek, "glm-5p3-flash"
      end

      def test_the_keys_go_only_to_ruby_llm_config
        both
        keys = Bench::Smoke.load_keys(dir: @dir)
        assert_equal({anthropic: FAKE_A, fireworks: FAKE_F}, keys)
        context = Bench::Smoke.apply_keys(keys)
        assert_equal FAKE_A, RubyLLM.config.anthropic_api_key
        assert_equal 0, RubyLLM.config.max_retries
        assert_equal FAKE_F, context.config.openai_api_key
        assert_equal Bench::FireworksRoute::API_BASE, context.config.openai_api_base
        assert_equal 0, context.config.max_retries
        refute_equal FAKE_F, RubyLLM.config.openai_api_key, "the Fireworks key is not on the global config"
      end

      def test_the_script_never_reads_the_environment_for_a_key
        source = File.read(File.expand_path("../bench/smoke_test.rb", __dir__))
        refute_match(/\bENV\b/, source.lines.reject { |l| l.start_with?("#") }.join)
        refute_match(/ANTHROPIC_API_KEY|FIREWORKS_API_KEY/, source)
        assert_equal File.join(Dir.home, ".config", "infinite-context-bench"), Bench::Smoke::KEY_DIR
        assert_equal({anthropic: "anthropic.key", fireworks: "fireworks.key"}, Bench::Smoke::KEY_FILES)
      end

      def test_a_key_in_the_environment_is_ignored
        keys_env = {"ANTHROPIC_API_KEY" => "ENV-KEY-SHOULD-NOT-BE-USED", "FIREWORKS_API_KEY" => "ENV-KEY-SHOULD-NOT-BE-USED"}
        old = keys_env.keys.to_h { |k| [k, ENV[k]] }
        keys_env.each { |k, v| ENV[k] = v }
        both
        keys = Bench::Smoke.load_keys(dir: @dir)
        assert_equal FAKE_A, keys[:anthropic]
        assert_equal FAKE_F, keys[:fireworks]
      ensure
        old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      end

      def test_the_key_text_never_appears_in_a_log_an_error_or_the_ledger
        both
        keys = Bench::Smoke.load_keys(dir: @dir)
        io = StringIO.new
        old_logger = RubyLLM.instance_variable_get(:@logger)
        RubyLLM.instance_variable_set(:@logger, Logger.new(io, level: Logger::DEBUG)) # debug logs bodies too
        Bench::Smoke.apply_keys(keys)
        ledger = Bench::Ledger.new(File.join(@dir, "ledger.json"))
        guard = Bench::Guard.new(ledger: ledger, prices: Bench::Smoke.prices, max_output_tokens: 64, retries: 0,
          settlement: :reservation)
        model = "claude-haiku-4-5"
        chat = guard.arm(RubyLLM.chat(model: model), model: model, label: "key-leak-test")
        chat.ask("hi")
        FakeNetwork.script << Faraday::ConnectionFailed.new("down")
        error = assert_raises(StandardError) { guard.arm(RubyLLM.chat(model: model), model: model, label: "again").ask("again") }

        outputs = {"log" => io.string, "error" => "#{error.class}: #{error.message}", "ledger" => File.read(ledger.path),
                   "guard halted" => guard.halted.to_s, "plan" => Bench::Smoke.plan}
        outputs.each do |name, text|
          refute_includes text, FAKE_A, "#{name} must not contain the Anthropic key text"
          refute_includes text, FAKE_F, "#{name} must not contain the Fireworks key text"
        end
        assert_equal 2, FakeNetwork.calls.size
        assert_operator io.string.bytesize, :>, 0, "the debug logger did capture request logging"
        # Honest limit: the fake network saw the Authorization header, as a real provider would.
        assert(FakeNetwork.calls.first[:headers].values.any? { |v| v.to_s.include?(FAKE_A) },
          "the key is sent only in the request header")
      ensure
        RubyLLM.instance_variable_set(:@logger, old_logger)
      end

      def test_a_refusal_message_for_the_whole_run_path_holds_no_content_either
        both(fireworks: "#{FAKE_F}\n\n")
        error = assert_raises(Bench::KeyFileRefused) { Bench::Smoke.load_keys(dir: @dir) }
        refute_includes error.message, FAKE_F
        refute_includes error.full_message, FAKE_F
      end
    end
  end
end
