# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_session_relay_core_tests.erl, the cases and the
# exhaustive exploration of the terminal relay's core erx_session_relay_core
# (docs/design-shell.md, "The terminal relay's protocol"), compiled with
# warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies). Each seeded fault is a copy of the core, or of the link
# erx_tty_link it holds, with one rule broken, which must fail the case
# that guards it.
class ErxSessionRelayCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCE = 'erlang/apps/erx_session/src/erx_session_relay_core.erl'
  CASES = %w[test/erlang/erx_session_relay_core_tests.erl].freeze
  DEADLINE = '600'
  LINK = 'erlang/apps/erx_session/src/erx_tty_link.erl'
  TTY = 'erlang/apps/erx/src/erx_tty.erl'
  # A broken rule: the text that keeps it in source, what replaces it, and the case that
  # must then fail.
  Fault = Data.define(:text, :broken, :case_name, :source) do
    def initialize(text:, broken:, case_name:, source: SOURCE) = super
  end
  READ_GATE = 'case may_read(Made, Core) andalso N =:= Signal of'
  FAULTS = {
    # Every wait armed whatever its holder: B is reported before its foreground.
    any_holder: Fault.new(text: 'holds(#open{}, #core{}) -> false.', broken: 'holds(#open{}, #core{}) -> true.',
                          case_name: /background_test/),
    # A console open never parked takes A's line.
    console_never_parked: Fault.new(text: 'holds(#open{holder = console}, #core{holder = console}) -> true;',
                                    broken: 'holds(#open{holder = console}, #core{}) -> true;',
                                    case_name: /the_console_during_a_job_test/),
    max_ignored: Fault.new(text: 'erx_tty:read(Key, Max, Tty)', broken: 'erx_tty:read(Key, ?MAX_BYTES, Tty)',
                           case_name: /input_on_demand_test/),
    console_event_untagged: Fault.new(text: '[{send, Console, {erx_tty_event, Group, Event}}]',
                                      broken: '[{send, Console, {erx_tty_event, none, Event}}]',
                                      case_name: /ctrl_c_at_the_prompt_test/),
    left_is_new: Fault.new(text: '{{ok, Left, sent(Group, Core2)}',
                           broken: '{{ok, erx_tty:termios(Core2#core.tty), sent(Group, Core2)}',
                           case_name: /the_swap_by_libedits_rule_test/),
    no_adopt: Fault.new(text: 'Adopted = erx_tty_modes:adopt(Cooked, erx_tty:termios(Tty)),',
                        broken: 'Adopted = erx_tty_modes:adopt(Cooked, Cooked#{ispeed := maps:get(ispeed, erx_tty:termios(Tty))}),',
                        case_name: /the_swap_by_libedits_rule_test/),
    background_set: Fault.new(text: 'false -> {{background, false}, [], Core}', broken: 'false -> tcsetattr(Termios, Core)',
                              case_name: /tcsetattr_in_the_background_test/),
    sigttou_refused: Fault.new(text: "sigttou_ignored}}, _Made, Core) ->\n    tcsetattr(Termios, Core);",
                               broken: "sigttou_ignored}}, _Made, Core) ->\n    {{background, false}, [], Core#core{cooked = Termios}};",
                               case_name: /tcsetattr_in_the_background_test/),
    watch_count_ignored: Fault.new(text: 'tty_wait(Key, {read, Count}, Tty) -> erx_tty:read_wait(Key, Count, Tty);',
                                   broken: 'tty_wait(Key, {read, _}, Tty) -> erx_tty:read_wait(Key, ?MAX_BYTES, Tty);',
                                   case_name: /a_short_raw_read_test/),
    maker_kept: Fault.new(text: 'Maker =:= Process]),', broken: 'Maker =:= no_one]),', case_name: /opens_test/),
    sigtstp_as_interrupt: Fault.new(text: 'event_name({signal, sigtstp}) -> suspend;',
                                    broken: 'event_name({signal, sigtstp}) -> interrupt;',
                                    case_name: /events_test/, source: TTY),
    suspension_only_parks: Fault.new(text: READ_GATE, broken: 'case holds(Made, Core) andalso N =:= Signal of',
                                     case_name: /a_signal_suspends_the_jobs_reads_test/),
    number_ignored: Fault.new(text: READ_GATE, broken: 'case may_read(Made, Core) andalso is_integer(N + Signal) of',
                              case_name: /a_signal_suspends_the_jobs_reads_test/),
    # The read gate alone, without parking, still reports a lagging job.
    signal_parks_nothing: Fault.new(text: '{Parked, Core2} = park(Core1),', broken: '{Parked, Core2} = {[], Core1},',
                                    case_name: /a_report_after_a_signal_in_one_input_test/),
    report_after_park: Fault.new(text: '#{Key := #wait{armed = true, caller = Caller, spec = Spec}} ->',
                                 broken: '#{Key := #wait{caller = Caller, spec = Spec}} ->',
                                 case_name: /a_report_after_a_signal_in_one_input_test/),
    one_flag: Fault.new(text: 'Core#core{groups = Groups#{Group := {Sent, Seen}}}.',
                        broken: 'Core#core{groups = Groups#{Group := {Sent, max(Seen, Sent)}}}.',
                        case_name: /signal_numbers_test/),
    console_uncounted: Fault.new(text: 'counted_for(_Signal, #core{holder = console, console_group = Group}) -> Group.',
                                 broken: 'counted_for(_Signal, #core{holder = console}) -> none.',
                                 case_name: /signals_the_console_takes_test/),
    console_loss_dropped: Fault.new(text: 'flushed_loss(#core{holder = console} = Core) -> ' \
                                          'notify(erx_tty:event_name(flushed_loss), Core);',
                                    broken: 'flushed_loss(#core{holder = console}) -> [];',
                                    case_name: /a_flushed_loss_reaches_only_the_console_test/),
    job_told_of_the_loss: Fault.new(text: 'flushed_loss(#core{holder = {job, _, _, _}}) -> [].',
                                    broken: 'flushed_loss(#core{holder = {job, _, _, _}} = Core) -> notify(lost, Core).',
                                    case_name: /a_flushed_loss_reaches_only_the_console_test/),
    console_quit_counted: Fault.new(text: "counted_for(sigquit, #core{holder = console}) -> none;\n", broken: '',
                                    case_name: /signals_the_console_takes_test/),
    seen_unchecked: Fault.new(text: 'case Seen =< sent(Group, Core) andalso', broken: 'case Seen >= 0 andalso',
                              case_name: /refusals_test/),
    current_any_job: Fault.new(text: "plan({_Tag, current}, _Caller, _Group, _Core) ->\n    refused;",
                               broken: "plan({Tag, current}, Caller, Group, #core{cooked = Cooked}) ->\n    " \
                                       '{ok, {job, Tag, Caller, Group}, keep, Cooked};',
                               case_name: /refusals_test/),
    sent_is_seen: Fault.new(text: '{{ok, Left, sent(Group, Core2)}', broken: '{{ok, Left, Seen}',
                            case_name: /sent_in_the_answer_test/),
    hangup_ignored: Fault.new(text: '{Actions, Tty1} = erx_tty:hangup(Tty),', broken: '{Actions, Tty1} = {[], Tty},',
                              case_name: /the_end_of_file_test/),
    one_count: Fault.new(text: '#{Group := {Sent, Seen}} -> Core#core{groups = Groups#{Group := {Sent + 1, Seen}}};',
                         broken: '#{Group := _} -> Core#core{groups = maps:map(fun(_, {Sent, Seen}) -> ' \
                                 '{Sent + 1, Seen} end, Groups)};',
                         case_name: /two_shells_test/),
    group_end_ignored: Fault.new(text: '{job, _, _, Group} -> to_console(Forgotten);',
                                 broken: '{job, _, _, Group} -> {[], Forgotten};',
                                 case_name: /a_shell_that_ends_while_its_job_holds_test/),
    mode_ignored: Fault.new(text: "on_open(_Caller, {tty_read, _, _, _}, #open{mode = write}, Core) ->\n    " \
                                  "{{error, ebadf}, [], Core};\n",
                            broken: '', case_name: /the_mode_test/),
    out_without_room: Fault.new(text: 'andalso Free >= erx_tty:widest_rendering() of', broken: 'andalso Free >= 0 of',
                                case_name: /output_takes_the_links_room_test/),
    # A step sends what is held once, at its end: a send inside it, at
    # each echo or when output starts, puts bytes the step's flush drops
    # in front of the master.
    echo_sent_at_once: Fault.new(text: "{Actions, Link1} = erx_tty_link:write(none, Bytes, Link),\n",
                                 broken: "{Actions0, Link0} = erx_tty_link:write(none, Bytes, Link),\n" \
                                         "    {Sent0, Link1} = erx_tty_link:send(Link0),\n" \
                                         "    Actions = Actions0 ++ Sent0,\n",
                                 case_name: /a_signal_drops_held_output_before_any_send_test/),
    start_sends: Fault.new(text: '{[], Core#core{link = erx_tty_link:start(Link)}};',
                           broken: '{Sent, Link1} = erx_tty_link:send(erx_tty_link:start(Link)), ' \
                                   '{Sent, Core#core{link = Link1}};',
                           case_name: /a_signal_drops_held_output_before_any_send_test/),
    never_sent: Fault.new(text: '{Sent, Link} = erx_tty_link:send(Core4#core.link),',
                          broken: '{Sent, Link} = {[], Core4#core.link},',
                          case_name: /a_signal_drops_held_output_before_any_send_test/),
    # Every step ends with its waits armed exactly when their opens may read.
    never_reconciled: Fault.new(text: '{Reconciled, Core1} = reconcile(Core0),',
                                broken: '{Reconciled, Core1} = {[], Core0},',
                                case_name: /input_on_demand_test/),
    # An out wait reported at one free byte lets a newline under ONLCR find no room.
    out_at_one_byte: Fault.new(text: 'andalso Free >= erx_tty:widest_rendering() of', broken: 'andalso Free > 0 of',
                               case_name: /an_out_wait_waits_for_room_for_any_byte_test/),
    # With no master, held output flows all the same: it is sent, and a drain waits for it.
    no_master_flows: Fault.new(text: '-> Master =:= present andalso not Stopped.', broken: '-> not Stopped.',
                               case_name: /no_master_test/, source: LINK),
    # With no master, a message as from one types input and sets the size.
    no_master_heard: Fault.new(text: "master(_Message, L = #link{master = none}) ->\n    {[], L};\n",
                               broken: '', case_name: /no_master_test/, source: LINK),
    flush_keeps_writes: Fault.new(text: '{Linked ++ drop_writes(Core1), Core1#core{writes = queue:new()}}.',
                                  broken: '{Linked, Core1}.', case_name: /a_flush_drops_what_is_held_test/),
    stop_ignored: Fault.new(text: '{[], Core#core{link = erx_tty_link:stop(Link)}};', broken: '{[], Core#core{link = Link}};',
                            case_name: /stopped_output_holds_echo_test/),
    foreground_tostop: Fault.new(text: "    case settable(Termios, Tty) of\n        {ok, _, _} ->",
                                 broken: "    case erx_tty:set(Termios, Tty) of\n        {ok, _, _} ->",
                                 case_name: /tcsetattr_in_the_background_test/),
    drain_ignores_held: Fault.new(text: 'Empty = queue:is_empty(Writes) andalso erx_tty_link:held(Link) =:= 0,',
                                  broken: 'Empty = queue:is_empty(Writes),', case_name: /a_drain_waits_for_the_master_test/)
  }.freeze

  def test_the_cases_and_the_exploration_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_key do |name|
    define_method(:"test_fault_#{name}_fails") { assert_fault_fails(name) }
  end

  private

  def assert_fault_fails(name)
    fault = FAULTS.fetch(name)
    source = File.binread(File.join(ROOT, fault.source))
    raise "#{fault.source} no longer holds #{fault.text.inspect}" unless source.include?(fault.text)

    output, status = eunit(fault.source => source.sub(fault.text) { fault.broken })
    refute status.success?, output
    assert_match(/#{fault.case_name.source}\S*\.\.\.\*failed\*/, output)
  end

  def eunit(replaced)
    Dir.mktmpdir('erx-session-relay-core-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_session], tests: CASES,
                                replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_session_relay_core_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                      chdir: work, stdin_data: '')
    end
  end
end
