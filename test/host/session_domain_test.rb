# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/session_domain'

# The session_domain suite's check of the burst it writes while the menu toggles
# (tools/lib/erx/session_domain.rb). Nothing boots here.
class SessionDomainTest < Minitest::Test
  Suite = Erx::SessionDomain
  MENU = "\e\\\e[0m\r\nerx_console: Ctrl-G menu\r\n  s  system shell\r\nEsc returns. \e\\\e[0m\r\n"

  def lines(range) = range.map { |number| Suite.burst_line(number) }.join

  # The console ends the burst line the menu interrupts, and the line goes on after it.
  def test_a_burst_cut_by_the_menu_is_whole_once_the_menu_is_out
    cut = Suite.burst_line(2)
    text = "1> ok\r\n#{lines(1..1)}#{cut[0, 9]}#{MENU}#{cut[9..]}#{lines(3..Suite::BURST_LINES)}ok\r\n"
    assert Suite.burst_whole!(text)
  end

  def test_a_lost_or_reordered_line_fails
    lost = "#{lines(1..10)}#{MENU}#{lines(12..Suite::BURST_LINES)}"
    assert_raises(Erx::Error) { Suite.burst_whole!(lost) }
    swapped = "#{lines(1..10)}#{MENU}#{lines(12..12)}#{lines(11..11)}#{lines(13..Suite::BURST_LINES)}"
    assert_raises(Erx::Error) { Suite.burst_whole!(swapped) }
  end

  # A menu that opened only after the burst ended toggled nothing mid-burst.
  def test_a_menu_after_the_burst_fails
    error = assert_raises(Erx::Error) { Suite.burst_whole!("#{lines(1..Suite::BURST_LINES)}#{MENU}") }
    assert_match(/did not open while/, error.message)
  end

  def test_a_point_list_that_does_not_end_at_the_shell_is_refused
    assert_raises(Erx::Error) { Suite.root_session_checkpoints([{ name: 'image-identity', pattern: /y/n, seconds: 30 }]) }
  end
end
