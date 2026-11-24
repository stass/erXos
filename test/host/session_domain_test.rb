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
  ROOT = File.expand_path('../..', __dir__)
  # The manifest the session_domain cell boots, QEMU virt's development one.
  DEVELOPMENT_SOURCE = Erx::Platform.development(ROOT).manifest_source(ROOT).freeze
  SHELL_POINTS = [{ name: 'release-shell', pattern: /x/n, seconds: 30 }].freeze

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

  # A boot's date reads the build date's hour, or the next one across a day's end, and no
  # other hour, 1970's included.
  def test_the_boot_date_is_the_boot_times_hour
    hours = Suite.date_boot_hours(Time.utc(2026, 11, 16, 23, 30, 5))
    assert_match hours, "2026111623\r\n"
    assert_match hours, "2026111700\n"
    refute_match hours, "2026111701\n"
    refute_match hours, "1970010100\n"
  end

  def test_a_point_list_that_does_not_end_at_the_shell_is_refused
    points = [{ name: 'image-identity', pattern: /y/n, seconds: 30 }]
    assert_raises(Erx::Error) { Suite.root_session_checkpoints(points, boot_time: Time.at(0), manifest_source: DEVELOPMENT_SOURCE) }
  end

  def pattern(points, name) = points.find { |point| point.fetch(:name) == name }.fetch(:pattern)

  def menu_entry(id) = "  1* root_1 (domain #{id})\r\n"

  # The boot starts each configured domain row of the cell's manifest and the login's
  # session, each taking the next id above the system domain's, so the relogin takes the
  # id after them, and the relogin after the kill the third after that; the rows are
  # counted here from the text, not through the harness's manifest reader.
  def assert_sessions_follow_the_boot(source)
    after_boot = Erx::MediumBoot::CONFIGURED_ID + source.scan(/^domain /).size + 1
    points = Suite.root_session_checkpoints(SHELL_POINTS, boot_time: Time.at(0), manifest_source: source)
    assert_match pattern(points, 'relogin-listed'), menu_entry(after_boot)
    refute_match pattern(points, 'relogin-listed'), menu_entry(after_boot - 1)
    assert_match pattern(points, 'killed-relogin-listed'), menu_entry(after_boot + 3)
    wall_set = points.find { |point| point.fetch(:name) == 'system-wall-set' }
    assert_equal "erx:i([processes, {pid, #{after_boot}, 0, 0}]).\r", wall_set.fetch(:type)
  end

  def test_the_relogin_takes_the_id_after_the_boots_starts
    assert_sessions_follow_the_boot(DEVELOPMENT_SOURCE)
  end

  # A start row starts a domain at boot, which the ids do not count.
  def test_a_manifest_with_a_start_row_is_refused
    source = "#{DEVELOPMENT_SOURCE}start extra\n  enable YES\n"
    assert_raises(Erx::Error) { Suite.root_session_checkpoints(SHELL_POINTS, boot_time: Time.at(0), manifest_source: source) }
  end

  # A domain row the manifest gains, a copy of the media row by another name, moves every
  # session id after the boot by one.
  def test_an_added_domain_row_moves_the_session_ids
    media = DEVELOPMENT_SOURCE[/^domain media\n(?:  .*\n)+/]
    refute_nil media, 'the development manifest has no media row to copy'
    row = media.sub('domain media', 'domain extra')
    assert_sessions_follow_the_boot(DEVELOPMENT_SOURCE + row)
  end
end
