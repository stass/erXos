# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_console_shell_tests.erl, the EUnit cases of the console's choice of
# its first shell, of what follows that shell's end and of the group shell:whereis/0
# reports, against erx_console compiled from
# source on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies); the
# decisions are pure, so they need no hosted build.
class ErxConsoleShellTest < Minitest::Test
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/erx_console_shell_tests.erl].freeze

  def test_first_shell_cases_pass_under_eunit
    Dir.mktmpdir('erx-console-shell-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_console_shell_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  # Every shipped writer of `-erx_record console_driver` (each manifest's system_args and the
  # hosted entry) names a driver erx_console:console_driver/1 accepts, so its closed set is
  # the one list of the console's drivers and a board's boot cannot be the first to find a
  # name missing from it.
  def test_every_shipped_console_driver_word_names_a_driver
    words = shipped_driver_words
    assert_operator words.size, :>=, 3, words.inspect
    probe = 'io:format("~p~n", [[erx_console:console_driver([["console_driver", W]]) || W <- init:get_plain_arguments()]]), halt().'
    Dir.mktmpdir('erx-console-driver-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: [])
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', probe, '-extra', *words, chdir: work, stdin_data: '')
      assert status.success?, output
      assert_equal "[#{words.map { |word| "{ok,#{word}}" }.join(',')}]\n", output.lines.last, words.inspect
    end
  end

  private

  def shipped_driver_words
    root = ErlangBuild::ROOT
    manifests = Dir.glob(File.join(root, 'config/manifest/*.txt'))
                   .flat_map { |path| File.read(path).scan(/^  system_args ".*\bconsole_driver (\S+)/).flatten }
    hosted = File.read(File.join(root, 'liberx/backend/hosted/start.c')).scan(/"\\0console_driver\\0(\w+)"/).flatten
    manifests + hosted
  end
end
