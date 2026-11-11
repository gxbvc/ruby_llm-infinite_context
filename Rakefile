# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create

# The library's tests, without the ones for the bench (bench/ is not part of
# the gem, and its runners read their own output files with plain SQL).
LIBRARY_TESTS = Dir["test/**/*_test.rb"].reject do |file|
  File.read(file).match?(%r{bench/|Bench::})
end.sort

desc "Run the library tests again with Active Record Encryption on the text columns"
Minitest::TestTask.create("test:encrypted") do |t|
  t.test_globs = LIBRARY_TESTS
  t.test_prelude = %(ENV["RIC_TEST_ENCRYPT"] = "1")
end

require "standard/rake"

task default: %i[test test:encrypted standard]
