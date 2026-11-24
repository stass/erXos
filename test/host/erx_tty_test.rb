# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_tty_tests.erl, the EUnit cases and the exhaustive
# exploration of the line discipline erx_tty (docs/design-live.md, "The tty"),
# compiled with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies). Each seeded fault is a copy of erx_tty with one
# rule broken, which must fail the property that guards it.
class ErxTtyTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCE = 'erlang/apps/erx/src/erx_tty.erl'
  CASES = %w[test/erlang/erx_tty_tests.erl].freeze
  DEADLINE = '600'
  Fault = Data.define(:text, :broken, :property)
  FAULTS = {
    vmin_ignored: Fault.new(text: '{Min, _} -> min(Min, Count)', broken: '{_, _} -> 1', property: /early_wakeup/),
    count_ignored: Fault.new(text: '{Min, _} -> min(Min, Count)', broken: '{Min, _} -> Min',
                             property: /a_short_raw_read_goes_on_at_its_count/),
    # Input that goes on past a signal key reports a reader the bytes after it.
    signal_not_stopping: Fault.new(text: '{[{signal, _} | _] = Actions, Tty} -> {Actions, Rest, Tty};',
                                   broken: '', property: /a_signal_key_stops_input_and_returns_the_rest/),
    eof_as_empty: Fault.new(text: '0 -> eof;', broken: '0 -> {ok, Got};', property: /read_differs/),
    echo_without_echo: Fault.new(text: 'case on(echo, Tty) orelse (Char =:= $\n andalso on(echonl, Tty)) of',
                                 broken: 'case true of', property: /echo_without_echo/),
    onlcr_without_opost: Fault.new(text: 'case on(opost, Tty) of', broken: 'case true of',
                                   property: /opost_clear_changes_bytes/),
    vstatus_without_iexten: Fault.new(text: 'case on(icanon, Tty) andalso on(iexten, Tty) andalso',
                                      broken: 'case on(icanon, Tty) andalso', property: /vstatus/),
    vstatus_echoed: Fault.new(text: "{[info | Started], Tty1};",
                              broken: "echo(Char, [info | Started], Tty1);",
                              property: /vstatus_echoed/),
    # POSIX's reading, a restart at each byte, in place of FreeBSD's one deadline.
    interbyte_restarted: Fault.new(text: "Held, element(3, Waiter) =:= none ->\n" \
                                         "            start_timer(Open, element(2, Waiter), Tty);",
                                   broken: "Held ->\n            {Cancelled, Tty1} = unwait(Open, Tty),\n" \
                                           "            {Started, Tty2} = start_timer(Open, element(2, Waiter), Tty1),\n" \
                                           "            {Cancelled ++ Started, Tty2};",
                                   property: /interbyte_deadline/),
    # An echo that would end exactly where the room ends is dropped.
    echo_short_of_its_bound: Fault.new(text: 'Tty) when byte_size(Bytes) =< Room ->',
                                       broken: 'Tty) when byte_size(Bytes) < Room ->',
                                       property: /echo_at_its_bound/),
    # Each call starts with a fresh bound of its own, whatever room the
    # owner has, so a chunk that a signal key cuts into calls echoes more.
    # Output stopped is the owner's: input/3 takes it from the room it is given.
    stopped_not_taken: Fault.new(text: 'out_stopped = Stopped}),', broken: 'out_stopped = false}),',
                                 property: /signal_left_output_stopped/),
    echo_bound_per_call: Fault.new(text: 'keys(Bytes, [], Tty0#tty{echo_room = Free,',
                                   broken: 'keys(Bytes, [], Tty0#tty{echo_room = 4096,',
                                   property: /echo_across_calls_takes_one_room/),
    # A dropped piece of echo drops every later one in the call too.
    echo_dropped_after_a_drop: Fault.new(text: "put_echo(_, Actions, Tty) ->\n    {false, Actions, Tty}.",
                                         broken: "put_echo(_, Actions, Tty) ->\n    {false, Actions, Tty#tty{echo_room = 0}}.",
                                         property: /a_piece_that_does_not_fit_is_dropped_alone/),
    # A flush that leaves the room as it was, so a signal key at room 0
    # echoes nothing though the owner has dropped all it held.
    flush_keeps_the_room: Fault.new(text: 'echo_room = ?MASTER_ROOM - Tty#tty.echo_kept}}',
                                    broken: 'echo_room = Tty#tty.echo_room}}',
                                    property: /a_flush_gives_the_room_back/),
    # A flush that gives back output the master has not taken.
    flush_drops_the_kept: Fault.new(text: 'echo_room = ?MASTER_ROOM - Tty#tty.echo_kept}}', broken: 'echo_room = ?MASTER_ROOM}}',
                                    property: /a_flush_gives_the_room_back/),
    # A cooked line walked with ECHO clear, every piece empty.
    reprint_walks_quietly: Fault.new(text: 'Line = case Fit andalso on(echo, Tty) of',
                                     broken: 'Line = case Fit of',
                                     property: /a_reprint_ends_at_its_first_dropped_piece/),
    # FreeBSD's walk: every piece of the retyped line is tried.
    reprint_walks_on: Fault.new(text: '{false, _, _} = Cut -> Cut',
                                broken: '{false, Echoed, Tty2} -> retype(Rest, Echoed, Tty2)',
                                property: /a_reprint_ends_at_its_first_dropped_piece/),
    # Lost input (docs/design-live.md, "Lost input"), the seeded faults of
    # its verification table.
    losses_not_shifted: Fault.new(text: "#units{bytes = Back, losses = [L - Size || L <- Kept]}}.",
                                  broken: "#units{bytes = Back, losses = Kept}}.",
                                  property: /a_raw_loss_is_one_unit_at_its_place/),
    readiness_counts_bytes: Fault.new(text: 'false -> count(Ready) >= wanted(Kind, Tty)',
                                      broken: 'false -> byte_size(Ready#units.bytes) >= wanted(Kind, Tty)',
                                      property: /a_loss_alone_is_ready_as_a_byte_is/),
    drop_not_marked: Fault.new(text: 'Counted = add_loss(Tty#tty{dropped = Dropped + 1}),',
                               broken: 'Counted = Tty#tty{dropped = Dropped + 1},',
                               property: /a_byte_dropped_for_room_is_a_loss/),
    erase_removes_the_loss: Fault.new(text: 'losses = lists:usort([min(L, Keep) || L <- Losses])}.',
                                      broken: 'losses = [L || L <- Losses, L < Keep]}.',
                                      property: /a_cooked_line_keeps_its_loss/),
    # An erase or kill that finds no byte drops the line's loss.
    bare_edit_drops_the_loss: Fault.new(text: "rub(Actions, #tty{line = #units{bytes = <<>>}} = Tty) ->\n" \
                                              '    {empty, Actions, Tty};',
                                        broken: "rub(Actions, #tty{line = #units{bytes = <<>>}} = Tty) ->\n" \
                                                '    {empty, Actions, Tty#tty{line = #units{}}};',
                                        property: /an_edit_that_removes_no_byte_keeps_the_loss/),
    # A word erase that finds no byte drops the line's loss.
    bare_word_erase_drops_the_loss: Fault.new(text: "none ->\n" \
                                                    "            %% No byte to remove: the line, and any loss it holds, stays.\n" \
                                                    '            {Actions, Tty};',
                                              broken: "none ->\n            {Actions, Tty#tty{line = #units{}}};",
                                              property: /an_edit_that_removes_no_byte_keeps_the_loss/),
    # A flush that keeps the losses: the exploration's reads meet them.
    flush_keeps_losses: Fault.new(text: "{Reported, Tty#tty{ready = #units{}, line = #units{}, reprintpos = 0,",
                                  broken: "{Reported, Tty#tty{ready = #units{losses = Dropped}, line = #units{}, reprintpos = 0,",
                                  property: /waiting_differs|read_differs|a_flush_reports_the_loss_it_drops/),
    flushed_loss_unreported: Fault.new(text: '_ -> [flushed_loss, flush_output | Actions]',
                                       broken: '_ -> [flush_output | Actions]',
                                       property: /a_flush_reports_the_loss_it_drops/)
  }.freeze

  def test_the_cases_and_the_exploration_pass
    output, status = eunit(File.binread(File.join(ROOT, SOURCE)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_ignoring_vmin_readies_a_read_early = assert_fault_fails(:vmin_ignored)

  def test_echo_with_echo_clear_fails = assert_fault_fails(:echo_without_echo)

  def test_a_read_that_ignores_its_count_fails = assert_fault_fails(:count_ignored)

  def test_input_past_a_signal_key_fails = assert_fault_fails(:signal_not_stopping)

  def test_an_end_of_file_read_as_empty_fails = assert_fault_fails(:eof_as_empty)

  def test_onlcr_with_opost_clear_fails = assert_fault_fails(:onlcr_without_opost)

  def test_output_stopped_not_taken_from_the_room_fails = assert_fault_fails(:stopped_not_taken)

  def test_vstatus_without_iexten_fails = assert_fault_fails(:vstatus_without_iexten)

  def test_an_echoed_vstatus_fails = assert_fault_fails(:vstatus_echoed)

  def test_an_echo_short_of_its_bound_fails = assert_fault_fails(:echo_short_of_its_bound)

  def test_an_echo_bound_per_call_fails = assert_fault_fails(:echo_bound_per_call)

  def test_a_flush_that_keeps_the_room_fails = assert_fault_fails(:flush_keeps_the_room)

  def test_a_flush_that_drops_the_kept_fails = assert_fault_fails(:flush_drops_the_kept)

  def test_a_quiet_reprint_that_walks_the_line_fails = assert_fault_fails(:reprint_walks_quietly)

  def test_a_reprint_that_walks_past_a_drop_fails = assert_fault_fails(:reprint_walks_on)

  def test_echo_dropped_after_a_drop_fails = assert_fault_fails(:echo_dropped_after_a_drop)

  def test_a_restarted_interbyte_timer_fails = assert_fault_fails(:interbyte_restarted)

  def test_a_read_that_does_not_shift_the_losses_fails = assert_fault_fails(:losses_not_shifted)

  def test_readiness_counting_bytes_only_fails = assert_fault_fails(:readiness_counts_bytes)

  def test_a_drop_not_marked_fails = assert_fault_fails(:drop_not_marked)

  def test_an_erase_that_removes_the_loss_fails = assert_fault_fails(:erase_removes_the_loss)

  def test_an_edit_that_removes_no_byte_dropping_the_loss_fails = assert_fault_fails(:bare_edit_drops_the_loss)

  def test_a_word_erase_that_removes_no_byte_dropping_the_loss_fails =
    assert_fault_fails(:bare_word_erase_drops_the_loss)

  def test_a_flush_that_keeps_the_losses_fails = assert_fault_fails(:flush_keeps_losses)

  def test_a_flush_that_drops_a_loss_unreported_fails = assert_fault_fails(:flushed_loss_unreported)

  private

  def assert_fault_fails(name)
    fault = FAULTS.fetch(name)
    source = File.binread(File.join(ROOT, SOURCE))
    raise "erx_tty.erl no longer holds #{fault.text.inspect}" unless source.include?(fault.text)

    output, status = eunit(source.sub(fault.text, fault.broken))
    refute status.success?, output
    # A case fails as "name_test...*failed*"; an exploration property is
    # the second element of the error term, followed by a comma.
    assert_match(/#{fault.property.source}\S*(\.\.\.\*failed\*|,)/, output)
  end

  # Compiles erx and erx_session with erx_tty as module_text, and the cases,
  # into a directory of their own and runs the cases.
  def eunit(module_text)
    Dir.mktmpdir('erx-tty-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_session], tests: CASES,
                                replaced: { SOURCE => module_text })

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_tty_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                      chdir: work, stdin_data: '')
    end
  end
end
