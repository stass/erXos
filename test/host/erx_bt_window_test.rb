# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_window_tests.erl, the pairing window's core (erx_bt_window):
# its exploration and its cases, compiled from source on stock's emulator (ERX_ERL and
# ERX_ERLC). Then each seeded fault, applied to a copy of the core, must fail the case
# named for it (docs/design-bluetooth.md, "Host tests of the cores").
class ErxBtWindowTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  TESTS = %w[test/erlang/erx_bt_window_tests.erl].freeze
  HOST_BYTES = { 'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '300'
  CORE = 'erlang/apps/erx_bt/src/erx_bt_window.erl'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the wait reset when a window opens',
             anchor: '    Opened = Core#core{window = {admitting, Id, Mode, Deadline, false}},',
             replacement: '    Opened = Core#core{window = {admitting, Id, Mode, Deadline, false}, last_failure = none},',
             catching_case: 'back_to_back_windows_do_not_shorten_the_wait_test'),
    Seed.new(fault: 'a disconnection mid-pairing not counted',
             anchor: '    failure(Address, disconnected, Now, Core);',
             replacement: '    {Actions, Failed} = failure(Address, disconnected, Now, Core), ' \
                          '{Actions, Failed#core{last_failure = Core#core.last_failure}};',
             catching_case: 'a_disconnection_mid_pairing_fails_and_counts_test'),
    Seed.new(fault: "the link's monitor kept past its keeping, so its end fails a kept bond",
             anchor: '    {[{demonitor, Link}], Core#core{pairing = {Link, Tag, Address, keeping}}};',
             replacement: '    {[], Core};',
             catching_case: 'keeping_then_down_leaves_the_store_to_decide_test'),
    Seed.new(fault: "a link's failure taken without its tag, so a stale one ends the pairing",
             anchor: 'input({link, Link, {outcome, Tag, {failed, Reason}}}, Now,',
             replacement: 'input({link, Link, {outcome, _Stale, {failed, Reason}}}, Now,',
             catching_case: 'stale_tags_change_nothing_test'),
    Seed.new(fault: 'a closed window leaving its running pairing unwithdrawn',
             anchor: '    {[{send, Link, {withdraw, Tag}}], Core#core{window = none}};',
             replacement: '    {[], Core#core{window = none}};',
             catching_case: 'closing_withdraws_a_running_pairing_test'),
    Seed.new(fault: "an open allowed while a closed window's pairing has no outcome",
             anchor: 'input({open, Id}, _Now, #core{window = none, pairing = none, lines = Lines} = Core) ->',
             replacement: 'input({open, Id}, _Now, #core{window = none, lines = Lines} = Core) ->',
             catching_case: 'keeping_then_down_leaves_the_store_to_decide_test'),
    Seed.new(fault: 'the wait never decayed',
             anchor: '    Halvings = (Now - At) div (?ERX_BT_PAIR_WAIT_DECAY_S * 1000),',
             replacement: '    Halvings = 0 * (Now - At),',
             catching_case: 'wait_halves_for_each_decay_without_a_failure_test'),
    Seed.new(fault: 'the maximum applied before the decay, so 600 s of quiet after a 64 s wait shortens the next',
             anchor: '    max(?ERX_BT_PAIR_WAIT_MIN_S * 1000, min(?ERX_BT_PAIR_WAIT_MAX_S * 1000, (2 * Wait) bsr Halvings)).',
             replacement: '    max(?ERX_BT_PAIR_WAIT_MIN_S * 1000, min(?ERX_BT_PAIR_WAIT_MAX_S * 1000, 2 * Wait) bsr Halvings).',
             catching_case: 'wait_halves_for_each_decay_without_a_failure_test'),
    Seed.new(fault: "a confirmed forget leaving the store's refusal since its start",
             anchor: '    {[], Core#core{refusing = false}};',
             replacement: '    {[], Core};',
             catching_case: 'a_confirmed_forget_ends_the_refusal_test'),
    Seed.new(fault: "a failure's line composed before the window is checked, so a pairing withdrawn at a close raises",
             anchor: '     ended({failed, Octets, Reason}, wait_from(Now, Core))}.',
             replacement: '     begin _ = text({failed, Octets, Reason}), ended({failed, Octets, Reason}, wait_from(Now, Core)) end}.',
             catching_case: 'an_interrupted_pairing_writes_no_line_test')
  ].freeze

  def test_window_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, CORE))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ CORE => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}\.\.\.(?:(?!erx_bt_window_tests: ).)*?\*failed\*/m,
                   output, seed.fault)
    end
  end

  private

  def run_cases(replaced)
    stand_ins = HOST_BYTES.transform_values { |path| File.binread(File.join(ErlangBuild::ROOT, path)) }
    Dir.mktmpdir('erx-bt-window-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: stand_ins.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test([erx_bt_window_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
