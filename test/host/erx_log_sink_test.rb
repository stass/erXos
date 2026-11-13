# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The log sink on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies):
# test/erlang/erx_log_sink_tests.erl, the EUnit cases of erx_log_h's records and of the
# lines erx_console_log renders for them, and logger_simple_h's early log (edit 43 of
# docs/design-runtime.md), compiled from the tree (outside the applications, it is a
# test module of its own run) and loaded in place of stock's, which
# must show an event with a tab, an escape sequence and a newline as one line of tokens.
class ErxLogSinkTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application the sink lives in, compiled whole (ErlangBuild).
  APPLICATIONS = %w[erx].freeze
  SINK_TESTS = %w[test/erlang/erx_log_sink_tests.erl].freeze
  # The tree's logger_simple_h, which stands on erx_text from the application.
  SIMPLE_HANDLER = %w[otp/lib/kernel/src/logger_simple_h.erl].freeze
  # Replaces stock's logger_simple_h with the tree's, makes it the only handler, logs one
  # event and waits for the handler's process to print it.
  SIMPLE_EVAL = <<~ERLANG
    code:unstick_mod(logger_simple_h),
    {module, logger_simple_h} = code:load_abs("logger_simple_h"),
    ok = logger:remove_handler(default),
    ok = logger:add_handler(simple, logger_simple_h, maps:new()),
    logger:error("tab\\there esc\\e[31mred nl~s", ["\\nend"]),
    timer:sleep(500),
    halt(0).
  ERLANG

  def test_sink_cases_pass_under_eunit
    Dir.mktmpdir('erx-log-sink-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: SINK_TESTS)
      output = run_erl(work, 'halt(case eunit:test(erx_log_sink_tests, [verbose]) of ok -> 0; _ -> 1 end).')
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_the_early_log_shows_an_event_on_one_escaped_line
    Dir.mktmpdir('erx-log-simple-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: SIMPLE_HANDLER)
      output = run_erl(work, SIMPLE_EVAL)
      assert_match(/ error: tab<U\+0009>here esc<U\+001B>\[31mred nl, end\r\n/, output)
      refute_includes output, "\e"
    end
  end

  private

  def run_erl(work, eval)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                     '-eval', eval, chdir: work, stdin_data: '')
    assert status.success?, output
    output
  end
end
