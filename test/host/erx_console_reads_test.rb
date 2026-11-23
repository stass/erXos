# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/line_editor'

# Runs test/erlang/erx_console_reads_tests.erl, the console of a session domain's line
# reading its terminal relay on demand (docs/design-shell.md, "The console reads on
# demand"), on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies) with
# the tree's group.erl and its edlin loaded in place of stock's. `user` is erx_test_user, so no group
# runs stock's code when the tree's is loaded. The seeded faults: stock's group, which
# never asks its driver for input in a shell's group (edit 72 of design-runtime.md),
# a relay core that tells the console nothing at a hangup, and a console that takes a
# read's end of file as the hangup.
class ErxConsoleReadsTest < Minitest::Test
  CASES = %w[test/erlang/erx_test_user.erl test/erlang/erx_console_reads_tests.erl].freeze
  CORE = 'erlang/apps/erx_session/src/erx_session_relay_core.erl'
  NOTICE = '{[{send, Console, erx_console_eof} | Ready]'
  CONSOLE = 'erlang/apps/erx/src/erx_console.erl'
  SWALLOWED = 'eof -> {noreply, watch(drop_held(Group, State))}'
  DEADLINE = '120'
  LOAD_GROUP = LineEditor::LOAD

  def test_the_cases_pass
    output, status = eunit(LOAD_GROUP)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_a_group_without_edit_72_fails
    output, status = eunit('')
    refute status.success?, output
    assert_match(/a_typed_line_reaches_the_shell_test\S*\.\.\.\*failed\*/, output)
  end

  def test_a_relay_that_sends_no_hangup_notice_fails
    source = File.binread(File.join(ErlangBuild::ROOT, CORE))
    flunk "#{CORE} no longer holds #{NOTICE.inspect}" unless source.include?(NOTICE)
    output, status = eunit(LOAD_GROUP, replaced: { CORE => source.sub(NOTICE, '{Ready') })
    refute status.success?, output
    assert_match(/a_hangup_with_no_read_outstanding_ends_the_console_test\S*\.\.\.\*failed\*/, output)
  end

  def test_a_console_that_hangs_up_at_a_reads_eof_fails
    source = File.binread(File.join(ErlangBuild::ROOT, CONSOLE))
    flunk "#{CONSOLE} no longer holds #{SWALLOWED.inspect}" unless source.include?(SWALLOWED)
    output, status = eunit(LOAD_GROUP, replaced: { CONSOLE => source.sub(SWALLOWED, 'eof -> hang_up(State)') })
    refute status.success?, output
    assert_match(/an_end_of_file_on_a_read_ends_no_shell_test\S*\.\.\.\*failed\*/, output)
  end

  private

  def eunit(load, replaced: {})
    Dir.mktmpdir('erx-console-reads-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_session], tests: CASES + LineEditor::SOURCES,
                                replaced: replaced)
      # Stock group and line editor, in the seeded run, wherever they would load from.
      LineEditor::MODULES.each { |m| File.delete(File.join(work, "#{m}.beam")) } if load.empty?
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-user', 'erx_test_user',
                      '-pa', work, '-eval',
                      "logger:set_primary_config(level, none), #{load}" \
                      'halt(case eunit:test(erx_console_reads_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                      chdir: work, stdin_data: '')
    end
  end
end
