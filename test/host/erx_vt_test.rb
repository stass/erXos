# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_vt_tests.erl, the EUnit cases of the terminal emulator's core
# (docs/design-display.md, "The terminal emulator"), against erx_vt and its generated width
# table compiled with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies). Each mutant is a copy of erx_vt with one rule broken, which must
# fail the case that guards it.
class ErxVtTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  SOURCE = File.join(ROOT, 'erlang/apps/erx_display/src/erx_vt.erl')
  WIDTH = Erx::Generated.path('erlang/apps/erx_display/src/erx_vt_width.erl', root: ROOT)
  CASES = File.join(ROOT, 'test/erlang/erx_vt_tests.erl')
  DEADLINE = '300'
  Mutant = Data.define(:text, :broken, :property)
  MUTANTS = {
    string_ignores_escape: Mutant.new(text: "parse(P, 16#1B) ->\n",
                                      broken: "parse(#parser{state = osc} = P, 16#1B) ->\n    {P, []};\nparse(P, 16#1B) ->\n",
                                      property: /an_unterminated_osc_does_not_stop_a_reset/),
    region_saves_rows: Mutant.new(text: 'Save =:= save andalso Top =:= 1 andalso', broken: 'Save =:= save andalso',
                                  property: /scroll_up_and_down/)
  }.freeze

  def test_the_cases_pass_under_eunit
    output, status = eunit(File.binread(SOURCE), strict: true)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_a_string_that_ignores_escape_fails_the_reset_case = assert_mutant_fails(:string_ignores_escape)

  def test_saving_a_lower_region_fails_the_scroll_case = assert_mutant_fails(:region_saves_rows)

  private

  def assert_mutant_fails(name)
    mutant = MUTANTS.fetch(name)
    source = File.binread(SOURCE)
    raise "erx_vt.erl no longer holds #{mutant.text.inspect}" unless source.include?(mutant.text)

    output, status = eunit(source.sub(mutant.text, mutant.broken), strict: false)
    refute status.success?, output
    assert_match mutant.property, output
  end

  # Compiles the module, the width table and the cases into a directory of their own and
  # runs the cases. An edited copy may leave a variable unused, which is not what it tests.
  def eunit(module_text, strict:)
    Dir.mktmpdir('erx-vt-test') do |work|
      copy = File.join(work, 'erx_vt.erl')
      File.binwrite(copy, module_text)
      flags = strict ? ['-Werror'] : []
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERLC'), *flags, '-o', work,
                                       WIDTH, copy, CASES, stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_vt_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                      chdir: work, stdin_data: '')
    end
  end
end
