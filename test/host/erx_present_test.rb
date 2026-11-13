# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_present_tests.erl on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies) against erx_present and erx_schema generated from
# abi/inspection.txt, then against an erx_present whose link encoding writes "." as
# %2E, which must fail: a round trip alone would pass it, since the module's reader
# and writer share the set of kept bytes.
class ErxPresentTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application holding the generated modules the cases run against (compiled whole,
  # ErlangBuild), and the suite.
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/erx_present_tests.erl].freeze
  # The generated erx_present, in build/gen, which the cases read.
  Erx::Generated.ensure(root: ROOT)
  PRESENT_PATH = File.join(Erx::Generated::OUTPUT, Erx::ABI::PresentEmitter::ERLANG_PATH)
  PRESENT = File.join(ROOT, PRESENT_PATH)
  KEPT = 'uri_plain(Byte) -> lists:member(Byte, "_+,:=@-./").'
  KEPT_WITHOUT_DOT = 'uri_plain(Byte) -> lists:member(Byte, "_+,:=@-/").'

  def test_the_generated_module_passes_under_eunit
    output, status = eunit(File.binread(PRESENT))
    assert status.success?, output
  end

  def test_a_link_encoding_that_escapes_dots_fails
    source = File.binread(PRESENT)
    assert_includes source, KEPT
    output, status = eunit(source.sub(KEPT, KEPT_WITHOUT_DOT))
    refute status.success?, output
    assert_match(/\{expression,"Uri"\}/, output)
  end

  private

  def eunit(present)
    Dir.mktmpdir('erx-present-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { PRESENT_PATH => present })
      Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_present_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
