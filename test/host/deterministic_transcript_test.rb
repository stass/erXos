# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/deterministic_transcript'

# The comparison of two deterministic-mode transcripts. The boots themselves are the QEMU
# gate's production_image suite, and the QEMU plan that runs them is qemu_test.rb's.
class DeterministicTranscriptTest < Minitest::Test
  BOOT = [
    "bootstrap: loading at 0x40200000\r\n",
    "\r\n",
    "             __  __\r\n",
    "ARM generic timer: 62500000 Hz (62.5 MHz) interval=62500 cnt=13542012 periodic mode\r\n",
    "erx: root task: watchdog off\r\n",
    "erx: erts: erl_start runs, 10 arguments\r\n",
    "rc: the command shell; erl starts the Erlang shell\r\n"
  ].join.b.freeze

  def compare_failure(first, second)
    assert_raises(Erx::Error) { Erx::DeterministicTranscript.compare(first, second) }.message
  end

  def test_the_same_transcript_compares_equal
    assert_equal 5, Erx::DeterministicTranscript.compare(BOOT, BOOT.dup)
  end

  def test_one_changed_byte_fails_with_its_line
    message = compare_failure(BOOT, BOOT.sub('runs, 10', 'runs, 11'))
    assert_includes message, 'line 4 of the compared span'
    assert_includes message, 'runs, 10 arguments'
    assert_includes message, 'runs, 11 arguments'
  end

  def test_a_changed_clock_reading_fails
    assert_includes compare_failure(BOOT, BOOT.sub('cnt=13542012', 'cnt=13542013')), 'line 2 of the compared span'
  end

  def test_a_missing_line_fails_where_the_spans_part
    assert_includes compare_failure(BOOT, BOOT.sub("erx: root task: watchdog off\r\n", '')), 'line 3 of the compared span'
  end

  def test_a_differing_line_is_quoted_escaped_and_cut
    message = compare_failure(BOOT, BOOT.sub('watchdog off', "watchdog \e[2J#{'x' * 300}"))
    refute_includes message, "\e"
    assert_includes message, '\e[2J'
    assert_operator message.bytesize, :<, 600
  end

  def test_what_precedes_the_banner_and_follows_the_shell_is_not_compared
    other = BOOT.sub('0x40200000', '0x40300000') + "% erl\r\nEshell V16.0 (type help(). for help)\r\n"
    assert_equal 5, Erx::DeterministicTranscript.compare(BOOT, other)
  end

  def test_a_transcript_without_its_banner_shell_or_clock_has_no_span
    [BOOT.sub('             __  __', 'x'), BOOT.sub('command shell;', 'command shell'), BOOT.sub('cnt=', 'count=')].each do |broken|
      assert_raises(Erx::Error) { Erx::DeterministicTranscript.compare(BOOT, broken) }
      assert_raises(Erx::Error) { Erx::DeterministicTranscript.compare(broken, BOOT) }
    end
  end
end
