# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_input_tests.erl, the input router's state machine runs
# (docs/design-display.md, "Verification and testing", the input router), against the
# erx_display application compiled from source with warnings as errors on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies). Each property's case is
# then run alone against a copy of erx_input with one rule broken, which must fail it
# under the property's name.
class ErxInputTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCE = 'erlang/apps/erx_display/src/erx_input.erl'
  TEST = 'erx_input_tests'
  DEADLINE = '600'
  # A broken rule: its text, what replaces it, and the property that must fail, by the
  # name the cases raise.
  # A broken rule: its text, what replaces it, the case it must fail, in EUnit's terms,
  # and the name of the property the case raises.
  Mutant = Data.define(:text, :broken, :test, :property)
  POINTER_RUN = "{generator, #{TEST}, pointer_exhaustive_test_}".freeze
  KEYS_RUN = "{generator, #{TEST}, keys_exhaustive_test_}".freeze
  MUTANTS = {
    hidden_window_hears_moves: Mutant.new(
      text: '{{ok, #{state := shown}}, _, {pointer, _, _, Buttons}} ->',
      broken: '{{ok, #{state := _}}, _, {pointer, _, _, Buttons}} ->',
      test: POINTER_RUN, property: /pointer_while_hidden/
    ),
    hidden_window_told_every_button: Mutant.new(
      text: '{out({to, Window, Event#{event := {pointer, X, Y, Kept}}}, Step), {window, Window, Kept}};',
      broken: '{out({to, Window, Event}, Step), {window, Window, Kept}};',
      test: "{#{TEST}, hidden_window_hears_only_its_own_buttons_test}",
      property: /hidden_window_hears_only_its_own_buttons_test\.\.\..*failed/
    ),
    end_forgets_keys: Mutant.new(text: 'end, {Step, S}, lists:sort(maps:keys(Keys))),',
                                 broken: 'end, {Step, S}, []),',
                                 test: KEYS_RUN, property: /key_order/),
    up_asks_the_policy: Mutant.new(
      text: '    {out({to, Window, Event}, Step), S#input{repeats = maps:remove(Window, S#input.repeats)}}.',
      broken: "    {Route, Asked} = ask(Event, Step),\n" \
              '    {answer(Route, Asked), S#input{repeats = maps:remove(Window, S#input.repeats)}}.',
      test: KEYS_RUN, property: /key_order/
    ),
    clamp_to_the_edge: Mutant.new(
      text: 'place({X0, Y0, X1, Y1}, {X, Y}) -> {clamp(X, X0, X1 - 1), clamp(Y, Y0, Y1 - 1)}.',
      broken: 'place({X0, Y0, X1, Y1}, {X, Y}) -> {clamp(X, X0, X1), clamp(Y, Y0, Y1 - 1)}.',
      test: "{#{TEST}, pointer_inside_the_screen_test}", property: /pointer_outside_screen/
    )
  }.freeze

  def test_router_cases_pass_under_eunit
    output, status = eunit(nil, TEST)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_a_hidden_window_hearing_moves_fails_the_pointer_run = assert_mutant_fails(:hidden_window_hears_moves)

  def test_a_hidden_window_told_every_button_fails_its_case = assert_mutant_fails(:hidden_window_told_every_button)

  def test_an_end_that_forgets_keys_fails_the_keys_run = assert_mutant_fails(:end_forgets_keys)

  def test_an_up_the_policy_routes_fails_the_keys_run = assert_mutant_fails(:up_asks_the_policy)

  def test_a_clamp_to_the_edge_fails_the_screen_property = assert_mutant_fails(:clamp_to_the_edge)

  private

  def assert_mutant_fails(name)
    mutant = MUTANTS.fetch(name)
    output, status = eunit(mutant, mutant.test)
    refute status.success?, output
    assert_match mutant.property, output
  end

  # Compiles the application, with erx_input edited when there is a mutant, and the cases
  # into a directory of their own, and runs the cases Tests names, in EUnit's terms.
  def eunit(mutant, tests)
    Dir.mktmpdir('erx-input-test') do |work|
      replaced = mutant ? { SOURCE => edited(mutant) } : {}
      ErlangBuild.compile(work, applications: %w[erx_display], tests: ["test/erlang/#{TEST}.erl"],
                                replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "halt(case eunit:test(#{tests}, [verbose]) of ok -> 0; _ -> 1 end).",
                      chdir: work, stdin_data: '')
    end
  end

  def edited(mutant)
    path = File.join(ROOT, SOURCE)
    source = File.binread(path)
    raise "#{path} no longer holds #{mutant.text.inspect}" unless source.include?(mutant.text)

    source.sub(mutant.text, mutant.broken)
  end
end
