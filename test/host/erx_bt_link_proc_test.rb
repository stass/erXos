# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_link_proc_tests.erl, the cases of the link process, erx_bt_link,
# over stand-in owners: a Just Works pairing to the store's ok, a reconnection with a kept
# bond, a crash mid-pairing that shows no secret, the handler's deadline on the wake-up
# timer and a disconnection mid-pairing reaching the window, compiled from source on
# stock's emulator (ERX_ERL and ERX_ERLC). Then each seeded fault, applied to a copy of
# the module, must fail the case named for it.
class ErxBtLinkProcTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  TESTS = %w[test/erlang/erx_bt_link_proc_tests.erl].freeze
  HOST_BYTES = { 'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '300'
  LINK = 'erlang/apps/erx_bt/src/erx_bt_link.erl'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'format_status/1 showing the state, the core with its keys',
             anchor: 'link_facts(#link{name = Name, conn = Conn, core = Core}) -> #{name => Name, conn => Conn, core => facts(Core)};',
             replacement: 'link_facts(#link{name = Name, conn = Conn, core = Core}) -> {Name, Conn, Core};',
             catching_case: 'crash_mid_pairing_leaks_nothing_test'),
    Seed.new(fault: "a raise in the core left uncaught, so its stack trace carries the core",
             anchor: "        Class:_Raised ->\n            {stop, {step_raised, Class, erx_bt_link_core:facts(Core)}, Link}",
             replacement: "        Class:Raised:Stack ->\n            erlang:raise(Class, Raised, Stack)",
             catching_case: 'crash_mid_pairing_leaks_nothing_test'),
    Seed.new(fault: "the store's resolve called from init/1, so start_child waits on the link's calls",
             anchor: '    {ok, #link{name = Name, conn = Conn, hci = Hci}, {continue, {start, Info}}}.',
             replacement: "    {noreply, Started} = handle_continue({start, Info}, #link{name = Name, conn = Conn, hci = Hci}),\n" \
                          '    {ok, Started}.',
             catching_case: 'start_waits_for_neither_call_test'),
    Seed.new(fault: "an owner's message sent from another name than the link's pid, which no owner can monitor",
             anchor: '    {owner(Role), node()} ! {?MODULE, self(), Message},',
             replacement: '    {owner(Role), node()} ! {?MODULE, make_ref(), Message},',
             catching_case: 'killed_link_is_seen_through_down_test'),
    Seed.new(fault: "a call of the start that fails left to crash the link with the call's terms",
             anchor: '    catch exit:_Reason -> throw({start, Owner})',
             replacement: '    catch exit:Reason -> exit(Reason)',
             catching_case: 'failed_join_ends_the_link_test'),
    Seed.new(fault: "a message shown whole, the window's verdict with its fresh private key and passkey",
             anchor: 'message => fun input_kind/1}',
             replacement: 'message => keep}',
             catching_case: 'format_status_hides_the_verdict_test')
  ].freeze

  def test_link_process_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, LINK))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ LINK => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      # A report the logger prints when a report callback raises may come between the
      # case's name and its verdict, so the verdict is the next one after the name.
      assert_match(/#{Regexp.escape(seed.catching_case)}\.\.\.(?:(?!erx_bt_link_proc_tests: ).)*?\*failed\*/m,
                   output, seed.fault)
    end
  end

  private

  # The modules, erx_bytes's stand-in and the replaced ones in place of the applications'
  # own, then the cases. The default logger handler is off, so a crash report the cases
  # provoke does not split a case's line of EUnit's output; the cases log to their own.
  def run_cases(replaced)
    stand_ins = HOST_BYTES.transform_values { |path| File.binread(File.join(ErlangBuild::ROOT, path)) }
    Dir.mktmpdir('erx-bt-link-proc-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: stand_ins.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-kernel', 'logger', '[{handler, default, undefined}]',
                      '-eval', 'halt(case eunit:test([erx_bt_link_proc_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
