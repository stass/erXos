# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_vt_tests.erl, the EUnit cases of the terminal emulator's core
# (docs/design-display.md, "The terminal emulator"), against erx_vt and its generated width
# table compiled with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies). Each mutant is a copy of erx_vt with one rule broken, which must
# fail the case that guards it.
class ErxVtTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  SOURCE = 'erlang/apps/erx_win/src/erx_vt.erl'
  CASES = %w[test/erlang/erx_vt_tests.erl].freeze
  DEADLINE = '300'
  Mutant = Data.define(:text, :broken, :property)
  MUTANTS = {
    string_ignores_escape: Mutant.new(text: "parse(P, 16#1B) ->\n",
                                      broken: "parse(#parser{state = osc} = P, 16#1B) ->\n    {P, []};\nparse(P, 16#1B) ->\n",
                                      property: /an_unterminated_osc_does_not_stop_a_reset/),
    region_saves_rows: Mutant.new(text: 'Save =:= save andalso Top =:= 1 andalso', broken: 'Save =:= save andalso',
                                  property: /scroll_up_and_down/),
    overflow_keeps_link: Mutant.new(text: 'osc(link_overflow, VT) -> count(link, VT#vt{link = none});',
                                    broken: 'osc(link_overflow, VT) -> count(link, VT);',
                                    property: /an_overflowed_link_still_ends_the_open_one/)
  }.freeze

  def test_the_cases_pass_under_eunit
    output, status = eunit(File.binread(File.join(ROOT, SOURCE)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_a_string_that_ignores_escape_fails_the_reset_case = assert_mutant_fails(:string_ignores_escape)

  def test_saving_a_lower_region_fails_the_scroll_case = assert_mutant_fails(:region_saves_rows)

  def test_an_overflowed_link_that_stays_open_fails_its_case = assert_mutant_fails(:overflow_keeps_link)

  private

  def assert_mutant_fails(name)
    mutant = MUTANTS.fetch(name)
    source = File.binread(File.join(ROOT, SOURCE))
    raise "erx_vt.erl no longer holds #{mutant.text.inspect}" unless source.include?(mutant.text)

    output, status = eunit(source.sub(mutant.text, mutant.broken))
    refute status.success?, output
    assert_match mutant.property, output
  end

  # Compiles erx_win and erx with erx_vt as module_text, and the cases, into a
  # directory of their own and runs the cases.
  def eunit(module_text)
    Dir.mktmpdir('erx-vt-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_win], tests: CASES, replaced: { SOURCE => module_text })

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_vt_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                      chdir: work, stdin_data: '')
    end
  end
end
