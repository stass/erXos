# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_tty_modes_tests.erl, the cases of erx_tty_modes, the
# cooked termios and the console's editing setting (docs/design-shell.md, "The
# foreground rule"), on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies). Each seeded fault is a copy of erx_tty_modes with one rule
# broken, which must fail the case that guards it.
class ErxTtyModesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCE = 'erlang/apps/erx/src/erx_tty_modes.erl'
  CASES = %w[test/erlang/erx_tty_modes_tests.erl].freeze
  DEADLINE = '120'
  Fault = Data.define(:text, :broken, :case_name)
  FAULTS = {
    no_masks: Fault.new(text: 'true -> masked(?COOKED_MASKS, Left);', broken: 'true -> Left;',
                        case_name: /a_cooked_holder_gives_its_characters_but_not_its_echo/),
    icanon_ignored: Fault.new(text: 'case lists:member(icanon, Local) of', broken: 'case true of',
                              case_name: /a_raw_holder_leaves_nothing_but_its_speed/),
    cooked_vmin_kept: Fault.new(text: 'cc := Chars#{vmin := 1, vtime := 0}}.', broken: 'cc := Chars}.',
                                case_name: /the_editing_setting_reads_each_key_with_signals/),
    icrnl_cleared: Fault.new(text: 'iflag => {[icrnl], []},', broken: 'iflag => {[], [icrnl]},',
                             case_name: /the_editing_setting_reads_each_key_with_signals/),
    # One flag of libedit's cooked row left out of the masks.
    noflsh_kept: Fault.new(text: '[echonl, noflsh]}}).', broken: '[echonl]}}).',
                           case_name: /adopt_follows_libedits_row_for_every_flag/)
  }.freeze

  def test_the_cases_pass
    output, status = eunit(File.binread(File.join(ROOT, SOURCE)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_an_adopt_without_its_masks_fails = assert_fault_fails(:no_masks)

  def test_an_adopt_that_ignores_icanon_fails = assert_fault_fails(:icanon_ignored)

  def test_an_editing_setting_with_the_cooked_vmin_fails = assert_fault_fails(:cooked_vmin_kept)

  def test_an_editing_setting_without_icrnl_fails = assert_fault_fails(:icrnl_cleared)

  def test_a_mask_without_noflsh_fails = assert_fault_fails(:noflsh_kept)

  private

  def assert_fault_fails(name)
    fault = FAULTS.fetch(name)
    source = File.binread(File.join(ROOT, SOURCE))
    raise "erx_tty_modes.erl no longer holds #{fault.text.inspect}" unless source.include?(fault.text)

    output, status = eunit(source.sub(fault.text) { fault.broken })
    refute status.success?, output
    assert_match(/#{fault.case_name.source}\S*\.\.\.\*failed\*/, output)
  end

  def eunit(module_text)
    Dir.mktmpdir('erx-tty-modes-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_session], tests: CASES,
                                replaced: { SOURCE => module_text })
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_tty_modes_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                      chdir: work, stdin_data: '')
    end
  end
end
