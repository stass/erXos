# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_usb_bus_tests.erl, the bus process row of docs/design-usb.md's
# host tests: the domain's top supervisor, erx_usb, with its places and a bus group,
# the bus process over erx_usb_bus_core and the hub function over erx_usb_hub_core,
# against erx_usb_fake_xhci, a controller speaking the design's controller-to-bus
# protocol, on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies),
# against the sources as they are and against each seeded fault, where the named case
# must fail.
class ErxUsbBusTest < Minitest::Test
  # erx_blk holds the mass-storage function's write path and block transport.
  APPLICATIONS = %w[erx erx_usb erx_blk].freeze
  # The places' grants need the stand-ins of the erx modules a grant calls; the HID function is a stand-in the
  # cases end at will.
  TESTS = %w[
    test/erlang/stand_in/erx_dist.erl
    test/erlang/stand_in/erx_connections.erl
    test/erlang/stand_in/erx_usb_hid.erl
    test/erlang/erx_usb_desc_tests.erl
    test/erlang/erx_usb_fake_stick.erl
    test/erlang/erx_usb_fake_xhci.erl
    test/erlang/erx_usb_bus_tests.erl
    test/erlang/erx_pcie_log_capture.erl
  ].freeze
  DEADLINE_SECONDS = '300'
  # The domain's drive records, as the domain library writes them: drives 0 and 1 on
  # the USB controllers (docs/design-fiasco.md, "Drive records").
  DRIVE_RECORDS = %w[-erx_record drive usb 0 -erx_record drive usb 1].freeze
  # Every EUnit timeout scaled by 12: the default per-case timeout from 5 s to 60 s, above
  # the cases' own waits (WAIT_MS), and any explicit {timeout, N, ...} to 12 N s.
  EUNIT_OPTIONS = '[verbose, {scale_timeouts, 12}]'
  BUS = 'erlang/apps/erx_usb/src/erx_usb_bus.erl'
  CORE = 'erlang/apps/erx_usb/src/erx_usb_bus_core.erl'
  SUP = 'erlang/apps/erx_usb/src/erx_usb.erl'
  BOT = 'erlang/apps/erx_usb/src/erx_usb_bot.erl'
  PIPE = 'erlang/apps/erx_usb/src/erx_usb_pipe.erl'
  BLK_USB = 'erlang/apps/erx_blk/src/erx_blk_usb.erl'

  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'a function whose start fails sends no end',
             module_path: BUS,
             anchor: '            {Bus, [{function_ended, Ref, Interface, Run, start_failure(Failed)} | Ended]}',
             replacement: '            {Bus, Ended}',
             catching_case: 'a_function_whose_start_fails_ends_test'),
    Seed.new(fault: "a detach that leaves the device's functions running",
             module_path: BUS,
             anchor: '    request({detach, Ref}, {stop_instances(Ref, Bus), Ended});',
             replacement: '    request({detach, Ref}, {Bus, Ended});',
             catching_case: 'a_hub_removed_detaches_below_it_first_test'),
    Seed.new(fault: "a hub's report passed on with the running instance's number, whoever sent it",
             module_path: BUS,
             anchor: "        \#{} -> {noreply, Bus}\n    end;\nhandle_info({'DOWN'",
             replacement: "        \#{} -> case [R || _ := {H, _, R, _} <- Instances, H =:= Hub] of\n" \
                          "                   [Run] -> {noreply, handle({changed, Hub, Set, Run, Pid}, Bus)};\n" \
                          "                   _ -> {noreply, Bus}\n" \
                          "               end\n    end;\nhandle_info({'DOWN'",
             catching_case: 'a_report_from_an_ended_hub_instance_is_dropped_test'),
    Seed.new(fault: "a hub port's connection change cleared by the wrong feature",
             module_path: CORE,
             anchor: 'port_change_feature(connection) -> ?ERX_USB_PORT_FEATURE_C_CONNECTION;',
             replacement: 'port_change_feature(connection) -> ?ERX_USB_PORT_FEATURE_C_ENABLE;',
             catching_case: 'a_hub_with_a_child_enumerates_it_test'),
    Seed.new(fault: 'a connection change with the port still connected not detaching the occupant',
             module_path: CORE,
             anchor: 'true -> {settling, Now + ?ERX_USB_POWER_UP_DELAY_MS};',
             replacement: 'true when Port =/= empty -> Port; true -> {settling, Now + ?ERX_USB_POWER_UP_DELAY_MS};',
             catching_case: 'a_device_replaced_unseen_gets_a_new_reference_test'),
    Seed.new(fault: "an instance's exit reason dropped, every end passed as a crash",
             module_path: BUS,
             anchor: '{noreply, handle({function_ended, Ref, Interface, Run, Reason},',
             replacement: '{noreply, handle({function_ended, Ref, Interface, Run, crashed},',
             catching_case: 'an_unusable_interface_leaves_the_others_running_test'),
    Seed.new(fault: 'a function told to go before the bus monitors it, its reason lost as noproc',
             module_path: BUS,
             anchor: "            Instance = {Ref, Interface, Run, monitor(process, Pid)},\n            ok = go(Pid),\n",
             replacement: "            ok = go(Pid),\n            timer:sleep(50),\n            Instance = {Ref, Interface, Run, monitor(process, Pid)},\n",
             catching_case: 'an_unusable_interface_leaves_the_others_running_test'),
    Seed.new(fault: "a failed start's reason dropped, every failed start counted",
             module_path: BUS,
             anchor: 'start_failure({error, Reason}) -> Reason;',
             replacement: 'start_failure({error, _Reason}) -> crashed;',
             catching_case: 'an_unusable_start_is_final_test'),
    Seed.new(fault: 'a bus group that gave up started again',
             module_path: SUP,
             anchor: 'restart => transient',
             replacement: 'restart => permanent',
             catching_case: 'a_controller_failing_at_every_reset_is_given_up_test'),
    Seed.new(fault: "a BOT function's pipe reset answered without resetting the pipe",
             module_path: BOT,
             anchor: '    {[{reset_pipe, erx_usb_pipe:reset_pipe(In)}], B};',
             replacement: '    {[{reset_pipe, ok}], B};',
             catching_case: 'a_stalled_data_phase_is_cleared_and_explained_test'),
    Seed.new(fault: 'a bulk-out completion counting none of the bytes written',
             module_path: PIPE,
             anchor: '{usb, Pipe, Tag, {ok, byte_size(Data)}}',
             replacement: '{usb, Pipe, Tag, {ok, 0}}',
             catching_case: 'a_stick_serves_its_medium_test'),
    Seed.new(fault: "a medium's transport linked to its function, so the transport's crash ends the function",
             module_path: BLK_USB,
             anchor: '    gen_server:start_monitor(?MODULE, Medium, []).',
             replacement: "    {ok, Pid} = gen_server:start_link(?MODULE, Medium, []),\n    {ok, {Pid, monitor(process, Pid)}}.",
             catching_case: 'a_transport_crash_ends_only_its_medium_test'),
    Seed.new(fault: "the function's end_medium clause dropped, so a grant asked again ends no medium",
             module_path: BOT,
             anchor: 'handle_info({erx_blk_drive, end_medium, {Lun, Ref}}, B = #bot{units = Units}) ->',
             replacement: 'handle_info({erx_blk_drive, end_medium_dropped, {Lun, Ref}}, B = #bot{units = Units}) ->',
             catching_case: 'a_grant_asked_again_ends_its_medium_through_the_function_test')
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
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*(failed|timed out)\*/, output, seed.fault)
    end
  end

  private

  # The cases run with the logger off, so the crashes the cases cause keep each case's
  # verdict on its line, and with EUnit's per-case timeout scaled from 5 s to 60 s, above
  # the cases' own waits (WAIT_MS), so a loaded host fails no case that would pass.
  def run_cases(replaced)
    Dir.mktmpdir('erx-usb-bus-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                      '-kernel', 'logger_level', 'none', '-pa', work, *DRIVE_RECORDS,
                      '-eval', "halt(case eunit:test(erx_usb_bus_tests, #{EUNIT_OPTIONS}) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
