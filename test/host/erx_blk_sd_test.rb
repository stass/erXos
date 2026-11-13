# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs the EUnit cases of the SD host controller's pure cores, erx_blk_sd_card and
# erx_blk_sd_host (test/erlang/erx_blk_sd_card_tests.erl against the reference card of
# erx_blk_sd_card_model.erl, and erx_blk_sd_host_tests.erl), compiled from source on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies); they are pure, so
# they need no hosted build; and erx_blk_write's issue and feed against the recording
# stand-in for the device NIF (test/erlang/stand_in/erx_device.erl, erx_blk_sd_issue_tests.erl), and the
# device process's start over it (erx_blk_sd_start_tests.erl). Then each seeded fault of the design's "Verification and
# testing" is compiled in place of its module, and the cases must fail on it, which shows
# they exercise what they guard.
class ErxBlkSdTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx erx_blk].freeze
  TESTS = %w[test/erlang/erx_blk_sd_card_model.erl test/erlang/erx_blk_sd_card_tests.erl test/erlang/erx_blk_write_sd_tests.erl
             test/erlang/erx_blk_sd_host_tests.erl test/erlang/stand_in/erx_device.erl
             test/erlang/erx_blk_sd_issue_tests.erl test/erlang/stand_in/erx_irq_line.erl
             test/erlang/erx_blk_sd_start_tests.erl].freeze
  CARD = 'erlang/apps/erx_blk/src/erx_blk_sd_card.erl'
  HOST = 'erlang/apps/erx_blk/src/erx_blk_sd_host.erl'
  WRITE = 'erlang/apps/erx_blk/src/erx_blk_write.erl'
  REGS = 'erlang/apps/erx_blk/src/erx_blk_sd_regs.erl'

  # Each fault: the module, the text replaced, its replacement, and the cases that catch it.
  Fault = Data.define(:name, :source, :from, :to, :cases)
  FAULTS = [
    Fault.new(name: 'CMD8 timeout refused', source: CARD,
              from: "    cmd8_answer(S, timeout);\n", to: "    refuse(S, timeout);\n",
              cases: 'erx_blk_sd_card_tests'),
    Fault.new(name: 'CMD8 timeout without line resets', source: CARD,
              from: 'Next, [{reset, cmd}, {reset, dat}], cmd(55, 0))', to: 'Next, [], cmd(55, 0))',
              cases: 'erx_blk_sd_card_tests'),
    Fault.new(name: 'any READ_BL_LEN admitted', source: CARD,
              from: 'when Len >= 9, Len =< 11 ->', to: 'when Len >= 0 ->', cases: 'erx_blk_sd_card_tests'),
    Fault.new(name: 'capacity bit and CSD structure not compared', source: CARD,
              from: 'admit(false, #{structure := 0, read_bl_len := Len, c_size',
              to: 'admit(_, #{structure := 0, read_bl_len := Len, c_size',
              cases: 'erx_blk_sd_card_tests'),
    Fault.new(name: 'R2 not shifted', source: CARD,
              from: '{ok, (Stored bsl 8) band ((1 bsl 128) - 1)};', to: '{ok, Stored};',
              cases: 'erx_blk_sd_card_tests'),
    Fault.new(name: 'cache left on', source: CARD,
              from: 'cache(S, {ok, #{cache := false}}) ->', to: 'cache(S, {ok, #{cache := _}}) ->',
              cases: 'erx_blk_sd_card_tests'),
    Fault.new(name: 'cache read-back skipped', source: CARD,
              from: 'issue(S1, disable_check, [], pe_read(S1))', to: 'identified(S1, flushed)',
              cases: 'erx_blk_sd_card_tests'),
    Fault.new(name: 'divider compares with <', source: HOST,
              from: 'Base =< Target * D]', to: 'Base < Target * D]', cases: 'erx_blk_sd_host_tests'),
    Fault.new(name: 'out of range ignored on every transfer', source: HOST,
              from: "auto_cmd12_errors(#transfer{}, AutoR1) ->\n    r1_errors(AutoR1).",
              to: "auto_cmd12_errors(#transfer{}, AutoR1) ->\n    without_out_of_range(r1_errors(AutoR1)).",
              cases: 'erx_blk_sd_host_tests'),
    Fault.new(name: '1.8 V check dropped', source: HOST,
              from: 'Control2 band ?SIGNALLING_1V8 =/= 0 ->', to: 'Control2 band ?SIGNALLING_1V8 =:= -1 ->',
              cases: 'erx_blk_sd_host_tests'),
    Fault.new(name: 'SD table admits CMD24', source: WRITE,
              from: "sd_table(_Command) -> refused.\n",
              to: "sd_table({cmd, 24}) -> {ok, r1, {write, ?SD_BLOCK}};\nsd_table(_Command) -> refused.\n",
              cases: 'erx_blk_write_sd_tests'),
    Fault.new(name: 'Auto CMD12 left off', source: WRITE,
              from: 'bor ?ERX_HW_SDHCI_CMDTM_TRNS_ACMD12_PUT(Multiple)',
              to: 'bor ?ERX_HW_SDHCI_CMDTM_TRNS_ACMD12_PUT(0)', cases: 'erx_blk_write_sd_tests'),
    Fault.new(name: 'register writes not spaced', source: REGS,
              from: 'max(0, Last + ?SPACING_US - Now).', to: '0 * (Last + Now).',
              cases: 'erx_blk_write_sd_tests'),
    Fault.new(name: "CMD49 argument unchecked", source: WRITE,
              from: "sd_argument({cmd, 49}, Arg, {write, <<Value, Rest/binary>>}) ->",
              to: "sd_argument({cmd, 4900}, Arg, {write, <<Value, Rest/binary>>}) ->", cases: "erx_blk_write_sd_tests"),
    Fault.new(name: "feed past the plan's blocks", source: WRITE,
              from: "when is_integer(Index), Index >= 0, Index < Count ->",
              to: "when is_integer(Index), Index >= 0, Index =< Count ->", cases: "erx_blk_sd_issue_tests"),
    Fault.new(name: "inhibit not awaited", source: WRITE,
              from: "erx_blk_sd_host:inhibited(erx_device:read(Dev, present), Dat) of",
              to: "erx_blk_sd_host:inhibited(erx_device:read(Dev, present), Dat) andalso false of",
              cases: "erx_blk_sd_issue_tests"),
    Fault.new(name: 'response error not acknowledged', source: HOST,
              from: "     {?ERX_HW_SDHCI_INTERRUPT_CARD_REMOVE_MASK, card_remove}\n     | error_bits()].",
              to: "     {?ERX_HW_SDHCI_INTERRUPT_CARD_REMOVE_MASK, card_remove}\n" \
                  "     | error_bits() -- [{?ERX_HW_SDHCI_INTERRUPT_RESP_ERR_MASK, response}]].",
              cases: 'erx_blk_sd_host_tests')
  ].freeze

  def test_sd_cores_pass_under_eunit
    Dir.mktmpdir('erx-blk-sd-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      %w[erx_blk_sd_card_tests erx_blk_sd_host_tests erx_blk_write_sd_tests erx_blk_sd_issue_tests
         erx_blk_sd_start_tests].each do |cases|
        output, status = eunit(work, cases)
        assert status.success?, output
        assert_match(/All \d+ tests passed|Test passed/, output)
      end
    end
  end

  def test_each_seeded_fault_is_caught
    FAULTS.each do |fault|
      text = File.read(File.join(ROOT, fault.source))
      assert_equal 1, text.scan(fault.from).size, "#{fault.name}: its text must occur once in #{fault.source}"
      Dir.mktmpdir('erx-blk-sd-fault') do |work|
        ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS,
                                  replaced: { fault.source => text.sub(fault.from, fault.to) })
        output, status = eunit(work, fault.cases)
        refute status.success?, "#{fault.name} passed #{fault.cases}:\n#{output}"
        assert_match(/Failed: [1-9]/, output, fault.name)
      end
    end
  end

  private

  def eunit(work, cases)
    Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                    '-eval', "halt(case eunit:test(#{cases}, []) of ok -> 0; _ -> 1 end)",
                    chdir: work, stdin_data: '')
  end
end
