# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'

# Erx::SanitizerEnvironment (tools/lib/erx/sanitizer_environment.rb): every
# sanitizer's options name the llvm-symbolizer beside the compiler, a missing
# one is a diagnostic, and a sanitizer report under the environment finishes
# symbolized instead of waiting on atos attaching to the failing process.
class SanitizerEnvironmentTest < Minitest::Test
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  # Seconds a failing sanitized program may take to report. A report that
  # waits on a hung symbolizer runs into it.
  REPORT_DEADLINE = '60'
  OVERFLOW = <<~C
    #include <stdlib.h>
    int overflowing_store(char *bytes) { bytes[16] = 1; return bytes[0]; }
    int main(void) { char *bytes = malloc(16); return overflowing_store(bytes); }
  C
  RACE = <<~C
    #include <pthread.h>
    static int shared;
    static void *racing_store(void *unused) { (void)unused; shared++; return NULL; }
    int main(void) {
        pthread_t thread;
        pthread_create(&thread, NULL, racing_store, NULL);
        shared++;
        pthread_join(thread, NULL);
        return shared;
    }
  C

  def setup
    @directory = Dir.mktmpdir('erx-sanitizer-environment-')
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory
  end

  # A compiler directory holding clang, reached through a link from
  # elsewhere as Homebrew's opt/llvm/bin is, and optionally llvm-symbolizer.
  def fake_llvm(name, symbolizer: true)
    bin = File.join(@directory, name, 'bin')
    FileUtils.mkdir_p(bin)
    tools = symbolizer ? %w[clang llvm-symbolizer] : %w[clang]
    tools.each do |tool|
      File.write(File.join(bin, tool), "#!/bin/sh\n")
      File.chmod(0o755, File.join(bin, tool))
    end
    link = File.join(@directory, "#{name}-link")
    File.symlink(File.join(bin, 'clang'), link)
    link
  end

  # The options of one variable, in order, as name => value.
  def options(environment, variable) = environment.fetch(variable).split(':').to_h { |option| option.split('=', 2) }

  def test_every_sanitizer_takes_the_policy_and_the_symbolizer_beside_the_compiler
    symbolizer = File.join(File.realpath(@directory), 'llvm', 'bin', 'llvm-symbolizer')
    environment = Erx::SanitizerEnvironment.call(compiler: fake_llvm('llvm'))
    assert_equal %w[ASAN_OPTIONS TSAN_OPTIONS UBSAN_OPTIONS], environment.keys.sort
    { 'ASAN_OPTIONS' => :asan, 'UBSAN_OPTIONS' => :ubsan, 'TSAN_OPTIONS' => :tsan }.each do |variable, sanitizer|
      policy = Erx::SanitizerEnvironment::POLICY.fetch(sanitizer)
      assert_equal [*policy, "external_symbolizer_path=#{symbolizer}"], environment.fetch(variable).split(':')
    end
  end

  def test_a_change_replaces_the_policy_option_of_its_name_and_keeps_the_rest
    environment = Erx::SanitizerEnvironment.call(tsan: %w[exitcode=7 report_signal_unsafe=0], compiler: fake_llvm('llvm'))
    tsan = options(environment, 'TSAN_OPTIONS')
    assert_equal %w[halt_on_error abort_on_error exitcode report_signal_unsafe external_symbolizer_path], tsan.keys
    assert_equal %w[1 1 7 0], tsan.values.first(4)
    assert_equal '1', options(environment, 'ASAN_OPTIONS').fetch('detect_stack_use_after_return'), 'other sanitizers keep the policy'
  end

  def test_an_option_the_parser_would_split_is_refused
    compiler = fake_llvm('llvm')
    ['halt_on_error=1:exitcode=0', 'log_path=a,b', 'halt_on_error', 'verbosity=1 2'].each do |option|
      assert_raises(Erx::Error, option) { Erx::SanitizerEnvironment.call(asan: [option], compiler: compiler) }
    end
  end

  def test_a_compiler_named_without_a_directory_is_found_on_the_path
    bin = File.dirname(File.realpath(fake_llvm('llvm')))
    path = ENV.fetch('PATH', '')
    ENV['PATH'] = [bin, path].join(File::PATH_SEPARATOR)
    assert_equal File.join(bin, 'llvm-symbolizer'), Erx::SanitizerEnvironment.symbolizer_path('clang')
  ensure
    ENV['PATH'] = path
  end

  def test_a_missing_symbolizer_is_a_diagnostic
    error = assert_raises(Erx::Error) { Erx::SanitizerEnvironment.call(compiler: fake_llvm('bare', symbolizer: false)) }
    assert_match(/llvm-symbolizer is not installed beside the compiler/, error.message)
  end

  def test_a_missing_compiler_is_a_diagnostic
    error = assert_raises(Erx::Error) do
      Erx::SanitizerEnvironment.call(compiler: File.join(@directory, 'absent', 'clang'))
    end
    assert_match(/does not exist/, error.message)
  end

  def test_a_compiler_missing_from_the_path_is_a_diagnostic
    error = assert_raises(Erx::Error) { Erx::SanitizerEnvironment.symbolizer_path('erx-no-such-compiler') }
    assert_match(/cannot find the compiler erx-no-such-compiler on PATH/, error.message)
  end

  def test_a_path_the_option_parser_would_split_is_refused
    ['two words', 'with,comma', 'with:colon'].each do |name|
      error = assert_raises(Erx::Error, name) { Erx::SanitizerEnvironment.call(compiler: fake_llvm(name)) }
      assert_match(/cannot be named in a sanitizer option string/, error.message)
    end
  end

  # Builds source under sanitizer and runs it under the environment and a
  # deadline, returning its output and exit status.
  def run_failing(source, sanitizer:, options:)
    program = File.join(@directory, sanitizer)
    File.write("#{program}.c", source)
    output, status = Open3.capture2e(COMPILER, '-std=c17', '-g', '-O0', '-pthread', "-fsanitize=#{sanitizer}",
                                     "#{program}.c", '-o', program, stdin_data: '')
    assert status.success?, output
    Open3.capture2e(Erx::SanitizerEnvironment.call(**options, compiler: COMPILER),
                    'gtimeout', '-k', '5', REPORT_DEADLINE, program, stdin_data: '')
  end

  # The program failed by itself (an exit status or the runtime's abort),
  # not by gtimeout's deadline (status 124, or SIGKILL after it).
  def assert_reported(output, status)
    refute status.success?, output
    refute_equal 124, status.exitstatus, "the report did not finish within #{REPORT_DEADLINE} s"
    refute_equal Signal.list.fetch('KILL'), status.termsig, "the report did not finish within #{REPORT_DEADLINE} s"
  end

  def test_an_address_report_finishes_symbolized
    output, status = run_failing(OVERFLOW, sanitizer: 'address', options: {})
    assert_reported(output, status)
    assert_includes output, 'heap-buffer-overflow'
    assert_match(/in overflowing_store .*address\.c:2/, output)
  end

  def test_a_thread_report_finishes_symbolized
    output, status = run_failing(RACE, sanitizer: 'thread', options: {})
    assert_reported(output, status)
    assert_includes output, 'ThreadSanitizer: data race'
    assert_match(/racing_store .*thread\.c:3/, output)
  end
end
