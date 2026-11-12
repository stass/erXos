# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# The start table's pure core (docs/design-apps.md, "Verification and testing"):
# test/erlang/erx_start_table_tests.erl runs on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies) against erx_start_table as it is, and against each seeded
# fault below, where the named case must fail.
class ErxStartTableTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_starter/src/erx_start_table.erl'
  # erx_ident, the identifier rule the core reads names with, and the suite.
  SOURCES = %w[erlang/apps/erx_domain/src/erx_ident.erl test/erlang/erx_start_table_tests.erl].freeze

  Fault = Data.define(:name, :from, :to, :caught_by)

  # Each fault replaces one passage of erx_start_table; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'a merge that adds a row for an undeclared principal',
              from: 'false -> {Rows, [{skipped, Line, {undeclared, Name}} | Skipped]}',
              to: 'false -> {Rows ++ [maps:put(Field, Value, #{principal => Name, enable => true, ' \
                  'display => none, restarts => 5, period => 600, from_rc_conf => [Field || Line > 0]})], Skipped}',
              caught_by: 'a_bad_line_and_an_undeclared_name_are_skipped_test'),
    Fault.new(name: 'the display rule dropped',
              from: 'case {Granted, maps:find(Display, Held)} of',
              to: 'case {Granted, maps:find(Display, maps:remove(Display, Held))} of',
              caught_by: 'a_second_enabled_row_on_a_display_is_refused_with_the_first_name_test'),
    Fault.new(name: 'the grant check dropped',
              from: 'Granted = lists:member(Display, maps:get(Principal, Grants, [])),',
              to: 'Granted = is_map(Grants),',
              caught_by: 'a_display_the_template_is_not_granted_is_refused_test'),
    Fault.new(name: "a command check that drops the comparison of every row before and after",
              from: "<- lists:zip(Before, After), Other =/= Name],", to: "<- lists:zip(Before, Before), Other =/= Name],",
              caught_by: "an_enable_that_displaces_another_row_is_refused_with_its_name_test"),
    Fault.new(name: "a variable's name split at its first _",
              from: '{At, 1} = lists:last(Underscores),', to: '{At, 1} = hd(Underscores),',
              caught_by: 'a_name_splits_at_its_last_underscore_test'),
    Fault.new(name: 'a reconcile that compares names only, not settings',
              from: 'decide({running, _Kept}, false, {ok, _Changed}) -> restart;',
              to: 'decide({running, _Kept}, false, {ok, _Changed}) -> keep;',
              caught_by: 'reconcile_restarts_a_row_whose_settings_changed_test'),
    Fault.new(name: 'a reconcile that ignores the stopped marks',
              from: 'lists:member(Name, Stopped)', to: 'lists:member(Name, Stopped -- Stopped)',
              caught_by: 'reconcile_decides_every_case_of_a_row_test'),
    Fault.new(name: 'a reconcile that restarts a down row whose settings changed',
              from: 'decide({down, _Kept}, false, {ok, _Is}) -> keep.',
              to: 'decide({down, Kept}, false, {ok, Is}) when Is =:= Kept -> keep; ' \
                  'decide({down, _Kept}, false, {ok, _Is}) -> restart.',
              caught_by: 'reconcile_decides_every_case_of_a_row_test'),
    Fault.new(name: 'restarts read up to 2^32-1, past its ceiling',
              from: 'decimal(Raw, 0, ?ERX_START_RESTARTS_MAX)', to: 'decimal(Raw, 0, 16#FFFFFFFF)',
              caught_by: 'restarts_and_period_past_their_ceilings_are_refused_test'),
    Fault.new(name: 'a read that gives up after 30 failures',
              from: '{{unread, Count}, Log ++ Manifest ++ [{retry, Delay}]};',
              to: '{{unread, Count}, Log ++ Manifest ++ [{retry, Delay} || Count < 30]};',
              caught_by: 'a_failed_read_retries_with_a_growing_bounded_delay_and_never_gives_up_test')
  ].freeze

  def setup
    Erx::Generated.ensure(root: ROOT)
  end

  def test_the_cases_pass
    output, status = eunit(File.read(File.join(ROOT, CORE)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, CORE))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit(original.sub(fault.from) { fault.to })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      # EUnit's verbose report of one test: its name, then its verdict before the next
      # test's name.
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_start_table_tests: ).)*?\*failed\*/m,
                   output, fault.name)
    end
  end

  private

  # Compiles the core as core_text, and the suite, and runs the suite.
  def eunit(core_text)
    Dir.mktmpdir('erx-start-table-test') do |work|
      core = File.join(work, File.basename(CORE))
      File.write(core, core_text)
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', include, '-o', work, core,
                                       *SOURCES.map { |source| File.join(ROOT, source) }, stdin_data: '')
      assert status.success?, output
      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_start_table_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
