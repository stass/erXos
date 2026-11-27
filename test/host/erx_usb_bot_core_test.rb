# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_usb_bot_core_tests.erl, the Bulk-Only engine explored to a fixed
# point, BOT 1.0's thirteen cases, traces and the decoders, against the module compiled
# from source on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies).
# Then each seeded fault the design names (docs/design-usb.md, "Host tests of the
# cores"), applied to a copy of the module, must fail the exploration: the CSW's tag check
# removed, so a wrapper of another command is taken; the residue rule removed, so a
# device that cannot count its bytes is trusted; the medium reference check removed, so
# a request of an ended medium is sent to the next; the engine idle after a failed status
# with the sense queued behind it, so a queued write runs before a UNIT ATTENTION is
# seen; a failed sense answered by asking for sense again; a flush of a medium that
# cannot flush answered `ok`; eight of the recovery ladder (docs/design-usb.md,
# "Recovery"): the class reset sent while the transfer it gave up on is still posted,
# a rung waiting with no deadline of its own, a failed rung that ends the function
# without asking for the port, a retry counter that never stops, a retry sent for a
# medium the function has ended, a retried write of the next block, the function's end
# of a medium ignored, and a cancel that resets the other pipe. Three more seed the
# quirks (docs/design-usb.md, "Device quirks"), each failing the case it names: any
# signature taken from a device with wrong_csw_signature, every device's capacity read
# as a count, and every device's residue taken from its data phase, which the
# exploration's devices with no quirk catch.
class ErxUsbBotCoreTest < Minitest::Test
  APPLICATIONS = %w[erx_usb].freeze
  CORE = 'erlang/apps/erx_usb/src/erx_usb_bot_core.erl'
  TESTS = %w[test/erlang/erx_usb_bot_core_tests.erl].freeze
  EXPLORATION = 'the_engine_explored_keeps_its_invariants_test_'
  DEADLINE_SECONDS = '600'

  # A fault planted by replacing anchor, and the case that must fail on it.
  Seed = Data.define(:fault, :anchor, :replacement, :test) do
    def initialize(fault:, anchor:, replacement:, test: EXPLORATION) = super
  end

  SEEDS = [
    Seed.new(fault: "the CSW's tag check removed",
             anchor: 'Tag:32/little, Residue:32/little, Status>>, Tag, Length) ->',
             replacement: '_CswTag:32/little, Residue:32/little, Status>>, _Tag, Length) ->'),
    Seed.new(fault: 'the residue rule removed',
             anchor: "        Residue > Length -> not_meaningful;\n",
             replacement: ''),
    Seed.new(fault: 'the medium reference check removed',
             anchor: 'case {ref(Current) =:= Medium, Current, Request} of',
             replacement: 'case {true, Current, Request} of'),
    Seed.new(fault: 'the engine idle after a failed status, its sense queued behind',
             anchor: "failed(Now, State = \#{op := Op = \#{stage := command, command := Command}}) ->\n    " \
                     "send(Op\#{stage := sense}, {request_sense, lun(Command)}, Now, State);",
             replacement: "failed(Now, State = \#{op := \#{stage := command, " \
                          "entry := Entry = \#{request := Request}}, queue := Queue}) ->\n    " \
                          'Sense = Entry#{id := sense, request := {request_sense, lun(Request)}}, ' \
                          'finish({error, {device, failed}}, keep, Now, State#{queue := queue:in(Sense, Queue)});'),
    Seed.new(fault: 'a failed sense answered by asking for sense again',
             anchor: "failed(Now, State = \#{op := \#{stage := sense}}) ->\n    sense_failed(Now, State).",
             replacement: "failed(Now, State = \#{op := Op = \#{stage := sense, command := Command}}) ->\n    " \
                          'send(Op, Command, Now, State).'),
    Seed.new(fault: 'a flush of a medium that cannot flush answered ok',
             anchor: '-> {error, no_flush};',
             replacement: '-> ok;'),
    Seed.new(fault: 'a class reset sent before the cancel',
             anchor: 'Pipe -> wait(cancel, {reset_pipe, Pipe}, Now, Marked)',
             replacement: '_Pipe -> reset(Now, Marked)'),
    Seed.new(fault: 'a rung with no deadline',
             anchor: "reset(Now, State) ->\n    wait(reset_1, class_reset, Now, State).",
             replacement: "reset(_Now, State) ->\n    {State\#{phase := reset_1}, [class_reset]}."),
    Seed.new(fault: 'a failed recovery that stops instead of escalating',
             anchor: '    stop({reset_port, Rung, Reason}, State).',
             replacement: '    stop({reset, Reason}, State).'),
    Seed.new(fault: 'a retry counter that never stops',
             anchor: 'Retries < ?ERX_USB_BOT_RETRIES} of',
             replacement: 'Retries >= 0} of'),
    Seed.new(fault: 'a retry sent for a medium that has ended',
             anchor: 'case {refusal(Entry, State), Retries',
             replacement: 'case {none, Retries'),
    Seed.new(fault: 'a retried write of the next block',
             anchor: 'retries := Retries + 1}, command(Request), Now, State);',
             replacement: 'retries := Retries + 1}, ' \
                          'case command(Request) of {write, L, S, D} -> {write, L, S + 1, D}; C -> C end, ' \
                          'Now, State);'),
    Seed.new(fault: "the function's end of a medium ignored",
             anchor: "on({end_medium, Lun, Ref}, _Now, State) ->\n    end_medium(Lun, Ref, State);",
             replacement: "on({end_medium, _Lun, _Ref}, _Now, State) ->\n    {State, []};"),
    Seed.new(fault: 'a cancel on the other pipe',
             anchor: 'posted(Phase) when Phase =:= command; Phase =:= data_out -> out;',
             replacement: 'posted(Phase) when Phase =:= command; Phase =:= data_out -> in;'),
    Seed.new(fault: 'any signature taken from a device with wrong_csw_signature',
             anchor: 'pick(Has(wrong_csw_signature) andalso Known,',
             replacement: 'pick(Has(wrong_csw_signature),',
             test: 'a_wrong_csw_signature_device_has_only_freebsds_two_taken_test'),
    Seed.new(fault: "every device's capacity read as a count",
             anchor: 'counted(erx_usb_quirks:has(capacity_is_count, Quirks), Capacity)',
             replacement: 'counted(true, Capacity)',
             test: 'a_capacity_is_count_device_has_its_last_block_read_as_a_count_test'),
    Seed.new(fault: "every device's residue taken from its data phase",
             anchor: 'pick(Has(ignore_residue), max(0, Length - Moved), Residue)',
             replacement: 'pick(true, max(0, Length - Moved), Residue)')
  ].freeze

  def test_bot_core_cases_pass_under_eunit
    output, status = run_cases
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, CORE))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases(replaced: { CORE => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.test)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  def run_cases(replaced: {})
    Dir.mktmpdir('erx-usb-bot-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_usb_bot_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
