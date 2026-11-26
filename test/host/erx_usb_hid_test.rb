# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_usb_hid_tests.erl, the HID function of docs/design-usb.md: the
# protocol choice of erx_hid_core:plan/2, and erx_usb_hid end to end from a model
# device's reports, through the domain's places and a real erx_fs grant of their input
# tree, to the records a reader decodes; on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies), against the sources as they are and against each seeded fault,
# where the named case must fail.
class ErxUsbHidTest < Minitest::Test
  APPLICATIONS = %w[erx_usb].freeze
  # The places' property test is compiled with the cases, whose fixture the cases
  # share; the stand-ins replace the erx modules the grant calls and
  # erx_usb_pipe, which carries the function's transfers to the model device.
  TESTS = %w[
    test/erlang/erx_usb_hid_tests.erl
    test/erlang/erx_usb_places_prop.erl
    test/erlang/stand_in/erx_dist.erl
    test/erlang/stand_in/erx_connections.erl
    test/erlang/stand_in/erx_usb_pipe.erl
  ].freeze
  DEADLINE_SECONDS = '300'
  # Every EUnit timeout scaled by 12: the default per-case timeout from 5 s to 60 s, above
  # the cases' own waits (WAIT_MS and the storm case's 30 s), and any explicit {timeout, N,
  # ...} to 12 N s, so a loaded host fails no case that would pass and a seeded fault's
  # case fails on its own error.
  EUNIT_OPTIONS = '[verbose, {scale_timeouts, 12}]'
  HID = 'erlang/apps/erx_usb/src/erx_usb_hid.erl'
  CORE = 'erlang/apps/erx_usb/src/erx_hid_core.erl'

  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'a transfer not posted again after its report',
             module_path: HID,
             anchor: "    write(Records, H),\n    post(Tag, H),\n",
             replacement: "    write(Records, H),\n    _ = Tag,\n",
             catching_case: 'typing_reaches_the_reader_test'),
    Seed.new(fault: 'a transfer posted again before the stream has taken its records',
             module_path: HID,
             anchor: "    write(Records, H),\n    post(Tag, H),\n",
             replacement: "    post(Tag, H),\n    write(Records, H),\n",
             catching_case: 'a_report_storm_waits_for_the_reader'),
    Seed.new(fault: 'a keyboard not sent SET_IDLE(0)',
             module_path: HID,
             anchor: 'set_idle(true, H) -> class_request(?ERX_HID_REQUEST_SET_IDLE, 0, H).',
             replacement: 'set_idle(true, _H) -> ok.',
             catching_case: 'a_keyboard_attaches_with_its_requests_test'),
    Seed.new(fault: 'a failed transfer posted again instead of ending the function',
             module_path: HID,
             anchor: "handle_info({usb, Pipe, _Tag, {error, Reason}}, H = #hid{interrupt = Pipe}) ->\n" \
                     "    {stop, {shutdown, {transfer, Reason}}, H};\n",
             replacement: "handle_info({usb, Pipe, Tag, {error, _}}, H = #hid{interrupt = Pipe}) ->\n" \
                          "    post(Tag, H),\n    {noreply, H};\n",
             catching_case: 'a_keyboard_removed_with_a_key_held_releases_it_test'),
    Seed.new(fault: 'a refused descriptor on a boot keyboard kept in the report protocol',
             module_path: CORE,
             anchor: '            {ok, planned(Layout, boot)};',
             replacement: '            {ok, planned(Layout, report)};',
             catching_case: 'a_refused_descriptor_types_in_the_boot_protocol_test'),
    Seed.new(fault: 'a report descriptor read that timed out taken as unusable',
             module_path: HID,
             anchor: "unplanned({report_descriptor, timeout}) ->\n    {shutdown, {report_descriptor, timeout}};",
             replacement: "unplanned({report_descriptor, timeout}) ->\n    unusable({report_descriptor, timeout});",
             catching_case: 'a_failed_report_descriptor_read_counts_and_a_refused_one_is_final_test')
  ].freeze

  def test_the_cases_pass
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.module_path))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.module_path => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  # The cases run with the logger off, so the crashes the seeds cause keep each case's
  # verdict on its line.
  def run_cases(replaced)
    Dir.mktmpdir('erx-usb-hid-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                      '-kernel', 'logger_level', 'none', '-pa', work,
                      '-eval', "halt(case eunit:test(erx_usb_hid_tests, #{EUNIT_OPTIONS}) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
