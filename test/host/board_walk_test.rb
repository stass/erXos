# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'set'
require_relative '../../tools/fuzz/bench_line'
require_relative '../../tools/lib/erx/board_files'
require_relative '../../tools/lib/erx/board_log'
require_relative '../../tools/lib/erx/board_walk'

# The board walk's decisions (docs/design-bench.md, "The walk", and its row of
# "Verification"): each entry runs in order and the walk ends on the found pair's banner;
# an entry skipped is not_run; a repeated name ends the walk; and over every sequence of
# up to eight events the walk ends within the queue's deadlines, exactly once.
class BoardWalkTest < Minitest::Test
  Fuzz = Erx::BenchLineFuzz
  Walk = Erx::BoardWalk
  FOUND = Erx::BoardFiles::Identity.new(**Fuzz::FOUND)
  BENCH = Erx::BoardFiles::Identity.new(**Fuzz::BENCH_BUILD)
  OTHER = { build: 'feedfacefeedface', index: 'ef' * 32 }.freeze
  DEADLINES = Walk::Deadlines.new(boot_seconds: 180, end_seconds: 600, return_seconds: 180)

  def plan(names = Fuzz::BOARD_NAMES, identities: [BENCH] * names.size, return_identity: FOUND, deadlines: DEADLINES,
           byte_limit: Erx::BenchRecord::LOG_BYTES)
    Walk::Plan.new(names: names, identities: identities, return_identity: return_identity, deadlines: deadlines,
                   byte_limit: byte_limit)
  end

  def line(text, at:, bytes: "#{text}\r\n".bytesize) = Walk::Line.new(kept: Erx::BoardLog.classify(text, 0), bytes: bytes, at: at)

  # The state after each of lines, one second apart from the reboot request at 0.
  def walked(lines, plan: self.plan)
    lines.each.with_index(1).reduce(Walk.start(plan, at: 0)) { |state, (text, at)| Walk.step(plan, state, line(text, at: at)) }
  end

  def test_three_entries_of_one_set_run_in_order_and_end_booted_on_the_found_pairs_banner
    state = walked(Fuzz.board_lines)
    assert_predicate state, :ended?
    assert_equal ['returned', %w[ended ended ended], 'booted'], [state.ending, state.outcomes, state.returned.status]
    assert_equal 'returned', Walk.walk(state, restored: true).ending
  end

  def test_a_paired_walk_of_two_sets_alternating_runs_each_entry_in_order
    names = Array.new(6) { |index| format('%032x', index + 1) }
    other = Erx::BoardFiles::Identity.new(**OTHER)
    lines = names.each_with_index.flat_map do |name, index|
      Fuzz.entry_lines(name).map { |text| text.start_with?('erx: boot image') ? Fuzz.banner(**(index.odd? ? OTHER : Fuzz::BENCH_BUILD)) : text }
    end
    paired = plan(names, identities: [BENCH, other] * 3)
    state = walked([*lines, Fuzz.banner(**Fuzz::FOUND)], plan: paired)
    assert_equal ['returned', ['ended'] * 6, 'booted'], [state.ending, state.outcomes, state.returned.status]
  end

  def test_an_entry_skipped_is_not_run_and_the_walk_goes_on
    first, _second, third = Fuzz::BOARD_NAMES
    state = walked([*Fuzz.entry_lines(first), *Fuzz.entry_lines(third), Fuzz.banner(**Fuzz::FOUND)])
    assert_equal ['returned', %w[ended not_run ended], 'booted'], [state.ending, state.outcomes, state.returned.status]
  end

  def test_an_entry_whose_next_began_first_ended_unseen
    first, second, third = Fuzz::BOARD_NAMES
    lines = [*Fuzz.entry_lines(first).reject { |text| text.end_with?(' done') }, *Fuzz.entry_lines(second), *Fuzz.entry_lines(third)]
    assert_equal %w[ended_unseen ended ended], walked(lines).outcomes
  end

  def test_a_line_naming_an_entry_that_has_ended_ends_the_walk_and_stops_none
    first, second, = Fuzz::BOARD_NAMES
    state = walked([*Fuzz.entry_lines(first), *Fuzz.entry_lines(first), *Fuzz.entry_lines(second)])
    assert_equal ['booted_again', %w[ended not_run not_run], 'not_seen'], [state.ending, state.outcomes, state.returned.status]
  end

  def test_a_name_of_no_entry_ends_the_walk_and_stops_the_running_entry
    state = walked(["erx: bench: boot #{Fuzz::BOARD_NAMES.first}", "erx: bench: boot #{'0' * 32}"])
    assert_equal ['booted_again', %w[stopped not_run not_run]], [state.ending, state.outcomes]
  end

  def test_a_broken_naming_line_names_nothing
    state = walked(["erx: bench: boot #{Fuzz::BOARD_NAMES.first}", 'erx: bench: boot 0123'])
    refute_predicate state, :ended?
  end

  def test_the_machine_ending_off_halts_the_walk
    state = walked(["erx: bench: boot #{Fuzz::BOARD_NAMES.first}", 'erx: end off'])
    assert_equal ['halted', %w[stopped not_run not_run]], [state.ending, state.outcomes]
    assert_match(/power needs cycling/, Walk.said(plan, state))
  end

  def test_the_end_deadline_runs_from_the_first_naming_line_however_often_the_board_names_its_entry
    name = Fuzz::BOARD_NAMES.first
    state = Walk.step(plan, Walk.start(plan, at: 0), line("erx: bench: boot #{name}", at: 10))
    state = (1..12).reduce(state) { |walking, minute| Walk.step(plan, walking, line("erx: bench: boot #{name}", at: 10 + (minute * 59))) }
    assert_equal ['end_deadline', %w[stopped not_run not_run]], [state.ending, state.outcomes]
    assert_equal 610, state.deadline
  end

  def test_the_return_is_the_found_pairs_only_when_its_banner_names_the_found_identity
    other = walked([*Fuzz.board_lines.take_while { |text| text != Fuzz.banner(**Fuzz::FOUND) }, Fuzz.banner(**OTHER)])
    assert_equal ['returned', 'unexpected', Erx::BoardFiles::Identity.new(**OTHER)],
                 [other.ending, other.returned.status, other.returned.identity]
    unknown = walked(Fuzz.board_lines, plan: plan(return_identity: nil))
    assert_equal 'unknown', unknown.returned.status
  end

  def test_no_banner_within_the_return_deadline_is_not_seen
    lines = Fuzz.board_lines.take_while { |text| text != Fuzz.banner(**Fuzz::FOUND) }
    state = walked(lines)
    state = Walk.step(plan, state, Walk::Quiet.new(at: lines.size + 180))
    assert_equal %w[returned not_seen], [state.ending, state.returned.status]
  end

  def test_the_boot_deadline_says_what_a_banner_read_meanwhile_shows
    silent = Walk.step(plan, Walk.start(plan, at: 0), Walk::Quiet.new(at: 180))
    assert_equal ['boot_deadline', %w[not_run not_run not_run]], [silent.ending, silent.outcomes]
    assert_match(/no line naming entry 1/, Walk.said(plan, silent))
    hung = Walk.step(plan, walked([Fuzz.banner(**Fuzz::BENCH_BUILD)]), Walk::Quiet.new(at: 180))
    assert_match(/below the bench root.*power needs cycling/, Walk.said(plan, hung))
    card = Walk.step(plan, walked([Fuzz.banner(**OTHER)]), Walk::Quiet.new(at: 180))
    assert_match(/another build, #{OTHER[:build]}.*until it is reset/, Walk.said(plan, card))
  end

  def test_a_boot_over_its_byte_limit_ends_the_walk
    small = plan(byte_limit: 100)
    state = Walk.step(small, walked(["erx: bench: boot #{Fuzz::BOARD_NAMES.first}"], plan: small), Walk::Bytes.new(bytes: 70, at: 2))
    assert_equal ['byte_limit', %w[stopped not_run not_run]], [state.ending, state.outcomes]
  end

  def test_the_bytes_after_an_entrys_end_line_count_toward_the_next_boot
    small = plan(byte_limit: 200)
    first, second, = Fuzz::BOARD_NAMES
    lines = ["erx: bench: boot #{first}", "erx: bench: boot #{first} done", 'erx: end reset', 'x' * 100, "erx: bench: boot #{second}"]
    state = walked(lines, plan: small)
    refute_predicate state, :ended?
    assert_equal 'byte_limit', Walk.step(small, state, Walk::Bytes.new(bytes: 50, at: 9)).ending
  end

  def test_the_console_closing_and_an_interruption_end_the_walk_saying_which
    running = walked(["erx: bench: boot #{Fuzz::BOARD_NAMES.first}"])
    %w[console_closed interrupted].each do |ending|
      state = Walk.step(plan, running, Walk::Stop.new(ending: ending, at: 5))
      assert_equal [ending, %w[stopped not_run not_run]], [state.ending, state.outcomes]
      assert_equal Erx::BoardFiles::STOPPED_BY.fetch(ending), Walk.said(plan, state)
    end
  end

  # Every sequence of up to eight events over a queue of two entries, with deadlines of 10,
  # 20 and 10 seconds and a limit of six bytes a boot: the walk's deadline never passes the
  # queue's bound (each entry's boot and end deadlines, and the return's), a final quiet
  # long after ends it, its outcomes are a walk's, and once ended no event changes it.
  SMALL = Walk::Deadlines.new(boot_seconds: 10, end_seconds: 20, return_seconds: 10)
  A, B = Fuzz::BOARD_NAMES
  TEXTS = ["erx: bench: boot #{A}", "erx: bench: boot #{A} done", "erx: bench: boot #{A} deadline", "erx: bench: boot #{B}",
           "erx: bench: boot #{B} done", "erx: bench: boot #{'0' * 32}", Fuzz.banner(**Fuzz::FOUND), Fuzz.banner(**OTHER),
           'erx: end off', 'erx: end reset'].freeze
  STEP_SECONDS = 19

  def events(now)
    [*TEXTS.map { |text| line(text, at: now, bytes: 1) }, Walk::Bytes.new(bytes: 5, at: now),
     Walk::Stop.new(ending: 'console_closed', at: now), Walk::Stop.new(ending: 'interrupted', at: now),
     Walk::Quiet.new(at: now + STEP_SECONDS)]
  end

  def test_every_sequence_of_eight_events_ends_within_the_queues_deadlines_exactly_once
    small = plan([A, B], identities: [BENCH, BENCH], deadlines: SMALL, byte_limit: 6)
    bound = (2 * (SMALL.boot_seconds + SMALL.end_seconds)) + SMALL.return_seconds
    seen = Set.new
    explore = lambda do |state, now, depth|
      assert_operator state.deadline, :<=, bound
      if state.ended?
        Walk.walk(state, restored: true)
        events(now).each { |event| assert_same state, Walk.step(small, state, event) }
        next
      end
      final = Walk.step(small, state, Walk::Quiet.new(at: 10**6))
      assert_predicate final, :ended?
      Walk.walk(final, restored: false)
      next if depth.zero? || !seen.add?([state, now, depth])

      events(now).each { |event| explore.call(Walk.step(small, state, event), event.at, depth - 1) }
    end
    explore.call(Walk.start(small, at: 0), 0, 8)
    assert_operator seen.size, :>, 500
  end
end
