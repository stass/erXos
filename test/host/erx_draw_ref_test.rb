# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The draw reference erx_draw_ref (docs/design-display.md, "The pixel
# primitives"): its EUnit cases on stock's emulator (ERX_ERL and ERX_ERLC),
# and the same cases against a copy seeded with a change to one Porter-Duff
# operation, which they must catch.
class ErxDrawRefTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx_win].freeze
  REFERENCE = 'test/erlang/erx_draw_ref.erl'
  TESTS = [REFERENCE, 'test/erlang/erx_draw_ref_tests.erl'].freeze
  # The seeded fault: the source's part outside the destination (SoutD) is
  # weighted by the destination's alpha instead of its complement.
  SEED = ['{false, true} -> mul255(M, 255 - Da);', '{false, true} -> mul255(M, Da);'].freeze

  def test_eunit_cases_pass
    assert_match(/All \d+ tests passed/, eunit(File.binread(File.join(ROOT, REFERENCE))))
  end

  def test_a_seeded_change_to_one_operation_fails_the_cases
    source = File.binread(File.join(ROOT, REFERENCE))
    assert source.include?(SEED.first), 'the seed no longer applies to erx_draw_ref'
    assert_match(/Failed: [1-9]/, eunit(source.sub(SEED.first, SEED.last)))
  end

  private

  # The EUnit output of the cases over Reference, the module's source.
  def eunit(reference)
    Dir.mktmpdir('erx-draw-ref-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { REFERENCE => reference })
      output, = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                '-eval', 'eunit:test(erx_draw_ref_tests, [verbose]), halt(0)',
                                chdir: work, stdin_data: '')
      output
    end
  end
end
