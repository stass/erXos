# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/native_crash'

# NativeCrash.judge against logs the crash suite wrote: each log agrees with its own
# case, and a log held to another case, or changed, is refused for the right reason.
class NativeCrashTest < Minitest::Test
  FIXTURES = File.expand_path('../fixtures/native_crash', __dir__)
  PLATFORM = Erx::Platform.development(File.expand_path('../..', __dir__))
  CASES = Erx::NativeCrash::CASES.to_h { |kase| [kase.name, kase] }.freeze

  def log(name) = File.binread(File.join(FIXTURES, "#{name}.log"))

  def refusal(serial, name)
    assert_raises(Erx::Error) { Erx::NativeCrash.judge(serial, CASES.fetch(name), ram_first: PLATFORM.ram_first) }.message
  end

  def test_each_log_agrees_with_its_own_case
    CASES.each do |name, kase|
      fault = Erx::NativeCrash.judge(log(name), kase, ram_first: PLATFORM.ram_first)
      assert_equal kase.kind, fault.fetch('kind'), name
    end
  end

  def test_a_read_held_to_the_write_case_disagrees_on_the_access
    assert_match(/disagree/, refusal(log('decommitted'), 'read_only_write'))
    assert_match(/access/, refusal(log('decommitted'), 'read_only_write'))
  end

  def test_a_write_held_to_the_read_case_disagrees_on_the_access
    assert_match(/access/, refusal(log('read_only_write'), 'decommitted'))
  end

  def test_a_trap_held_to_a_memory_case_disagrees_on_the_kind
    assert_match(/kind/, refusal(log('trap'), 'decommitted'))
  end

  def test_a_memory_fault_held_to_the_trap_case_disagrees_on_the_kind
    assert_match(/kind/, refusal(log('decommitted'), 'trap'))
  end

  def test_an_address_other_than_the_guests_disagrees
    changed = log('decommitted').sub(/address [0-9a-f]{16}/n, 'address 0000000000001000')
    assert_match(/address/, refusal(changed, 'decommitted'))
  end

  def test_a_log_without_the_guests_address_is_refused
    assert_match(/no address line/, refusal(log('decommitted').sub(/\Aerx: crash: address [^\n]*\n/n, ''), 'decommitted'))
  end

  def test_a_log_without_a_frame_is_refused
    address_only = log('decommitted').lines.first
    assert_match(/absent/, refusal(address_only, 'decommitted'))
  end

  def test_a_guest_that_reports_an_uncaught_touch_is_refused_with_its_line
    serial = "erx: crash: UNCAUGHT touch returned\r\n#{log('decommitted')}"
    assert_match(/erx: crash: UNCAUGHT/, refusal(serial, 'decommitted'))
  end
end
