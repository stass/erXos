# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_line_tests.erl, the cases of the line tree (erx_line_fs) served by a
# real erx_fs grant over its keeper, erx_line, with a model driver, and test/erlang/
# erx_line_core_tests.erl, the exhaustive exploration of its core (docs/design-bluetooth.md,
# "The controller's line"), on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies), against the sources as they are and against each seeded fault, where the
# named case must fail.
class ErxLineTest < Minitest::Test
  APPLICATIONS = %w[erx_uart].freeze
  # The stand-ins replace the erx modules the grant calls.
  TESTS = %w[
    test/erlang/erx_line_tests.erl
    test/erlang/erx_line_core_tests.erl
    test/erlang/stand_in/erx_dist.erl
    test/erlang/stand_in/erx_connections.erl
  ].freeze
  DEADLINE_SECONDS = '120'
  LINE = 'erlang/apps/erx_uart/src/erx_line.erl'
  CORE = 'erlang/apps/erx_uart/src/erx_line_core.erl'

  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: "the keeper's wait clause removed, so no request it is handed is answered",
             module_path: CORE,
             anchor: "event({info, ?ERX_FS_WAIT(Wait, Request)}, C) ->\n    {take(Wait, Request, C), []};\n",
             replacement: '',
             catching_case: 'a_waiting_read_blocks_no_other_request_test'),
    Seed.new(fault: 'a keeper that never answers a flush',
             module_path: CORE,
             anchor: "event({info, Message}, #core{waits = Waits} = C) ->\n",
             replacement: "event({info, ?ERX_FS_FLUSH(_)}, C) ->\n    {C, []};\n" \
                          "event({info, Message}, #core{waits = Waits} = C) ->\n",
             catching_case: 'a_flush_answers_a_waiting_read_eintr_test'),
    Seed.new(fault: 'a reset that waits for the write the driver holds',
             module_path: CORE,
             anchor: "        [{Reset, Done} | _] -> begin_reset(Reset, Done, C);\n",
             replacement: "        [{Reset, Done} | _] when C#core.writing =:= none -> begin_reset(Reset, Done, C);\n" \
                          "        [_ | _] -> {C, []};\n",
             catching_case: 'a_reset_goes_ahead_of_waiting_writes_test'),
    Seed.new(fault: 'a reset that keeps the buffer',
             module_path: CORE,
             anchor: 'C#core{driver = Fresh, rx = <<>>, broken = false, reset = none}',
             replacement: 'C#core{driver = Fresh, broken = false, reset = none}',
             catching_case: 'a_reset_drops_what_the_old_driver_read_test'),
    Seed.new(fault: 'a keeper that outlives its grants, taking their end as any other message',
             module_path: LINE,
             anchor: "handle_info({'EXIT', Grants, Reason}, #line{grants = Grants} = L) ->\n" \
                     "    {stop, {grants_ended, erx_report:reason_name(Reason)}, L};\n",
             replacement: '',
             catching_case: 'the_keeper_and_its_grants_end_together_test'),
    Seed.new(fault: "a status that shows the keeper's buffer whole",
             module_path: LINE,
             anchor: '#{rx => erx_report:bytes(Rx),',
             replacement: '#{rx => Rx,',
             catching_case: 'the_status_shows_no_byte_of_the_line_test'),
    Seed.new(fault: 'a status that shows the requests waiting whole',
             module_path: LINE,
             anchor: '[{Wait, shown_request(Request), State}',
             replacement: '[{Wait, Request, State}',
             catching_case: 'the_status_shows_no_byte_of_the_line_test'),
    Seed.new(fault: 'a line that crashes when its driver does not start',
             module_path: CORE,
             anchor: "first({ok, Driver}, C) -> C#core{driver = Driver};\nfirst(_Refused, C) -> no_driver(C).\n",
             replacement: "first({ok, Driver}, C) -> C#core{driver = Driver}.\n",
             catching_case: 'a_driver_that_does_not_start_leaves_the_line_broken_test'),
    Seed.new(fault: "a driver's end taken as any other message, so the line waits on no driver",
             module_path: CORE,
             anchor: "event({info, {'EXIT', Driver, _}}, #core{driver = Driver} = C) when Driver =/= none ->\n    {no_driver(C), []};\n",
             replacement: '',
             catching_case: 'a_driver_s_end_leaves_the_line_broken_until_a_reset_test'),
    Seed.new(fault: "the grant's flow passed to the holding start, so RTS is asserted as the controller powers up",
             module_path: LINE,
             anchor: 'step({started, Flow, Start(self(), Flow)}, L);',
             replacement: 'step({started, Flow, Start(self(), grant)}, L);',
             catching_case: 'a_reset_power_cycles_between_two_fresh_starts_test'),
    Seed.new(fault: 'the second start made before the on time has passed',
             module_path: CORE,
             anchor: '[{timer, maps:get(Phase, Power), {Wait, Phase}}]',
             replacement: '[{timer, maps:get(Phase, Power#{on := 0}), {Wait, Phase}}]',
             catching_case: 'a_reset_power_cycles_between_two_fresh_starts_test'),
    Seed.new(fault: "the holding start dropped, so the old driver's settings meet the power-up",
             module_path: CORE,
             anchor: "stopped(C) ->\n    starting(none, C).\n",
             replacement: "stopped(C) ->\n    notify(off, C).\n",
             catching_case: 'a_reset_power_cycles_between_two_fresh_starts_test'),
    Seed.new(fault: 'a failure path that skips ending the holding driver, which runs on with flow none',
             module_path: CORE,
             anchor: "failed(#core{reset = #reset{holding = Holding} = R} = C) ->\n" \
                     "    {C#core{reset = R#reset{step = failing}}, [{kill, Holding}]}.\n",
             replacement: "failed(C) ->\n    {failed_end(C), []}.\n",
             catching_case: 'a_failed_notification_fails_the_reset_test_'),
    Seed.new(fault: 'a refused notification taken as performed, so the reset goes on to its next step',
             module_path: CORE,
             anchor: 'notified(Phase, {notified, ok}, ',
             replacement: 'notified(Phase, {notified, _}, ',
             catching_case: 'a_failed_notification_fails_the_reset_test_'),
    Seed.new(fault: "a holding driver's early end taken as any other message, so step 5 waits on a driver gone",
             module_path: CORE,
             anchor: "event({info, {'EXIT', Holding, _}}, #core{reset = #reset{holding = Holding} = R} = C) ->\n" \
                     "    released(C#core{reset = R#reset{holding = none}});\n",
             replacement: '',
             catching_case: 'a_holding_driver_that_ends_early_leaves_the_power_cycle_going_test'),
    Seed.new(fault: 'a keeper that serves no service, so no domain is granted its tree',
             module_path: LINE,
             anchor: "    ok = erx_facet:serve(line, Grants),\n",
             replacement: '',
             catching_case: 'the_line_serves_its_trees_grants_test'),
    Seed.new(fault: 'a failed reset answered while its holding driver still runs with flow none',
             module_path: CORE,
             anchor: "    {C#core{reset = R#reset{step = failing}}, [{kill, Holding}]}.\n",
             replacement: "    {failed_end(C), [{kill, Holding}]}.\n",
             catching_case: 'explore_with_a_power_line_test_'),
    Seed.new(fault: "a failing reset that never takes its holding driver's end, so it never answers",
             module_path: CORE,
             anchor: "released(#core{reset = #reset{step = failing}} = C) ->\n    {failed_end(C), []};\n",
             replacement: '',
             catching_case: 'explore_with_a_power_line_test_')
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
    Dir.mktmpdir('erx-line-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                      '-kernel', 'logger_level', 'none', '-pa', work,
                      '-eval', 'halt(case eunit:test([erx_line_tests, erx_line_core_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
