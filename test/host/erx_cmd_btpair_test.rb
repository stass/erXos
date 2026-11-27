# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_cmd_btpair_tests.erl, the EUnit cases of the command shell's
# `btpair` (erx_cmd_btpair): its usage, its no_facet, and a window driven over a stub
# pair file for each status, against the erx, erx_shell and erx_bt_client applications
# compiled from source with warnings as errors on stock's emulator (ERX_ERL and
# ERX_ERLC). Then each seeded fault the design names (docs/design-bluetooth.md, "Host
# tests of the cores", `btpair` over a stub tree), applied to a copy of the module,
# must fail the case named for it.
class ErxCmdBtpairTest < Minitest::Test
  APPLICATIONS = %w[erx erx_shell erx_bt_client].freeze
  TESTS = %w[test/erlang/erx_cmd_btpair_tests.erl test/erlang/erx_bt_pair_stub.erl].freeze
  DEADLINE_SECONDS = '120'
  MODULE = 'erlang/apps/erx_shell/src/erx_cmd_btpair.erl'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the line printed as read, so a line holding an escape sequence reaches the terminal',
             anchor: 'ok = erx_cmd:write(Ctx, [shown(Term), $\n]),',
             replacement: 'ok = erx_cmd:write(Ctx, [Line, $\n]),',
             catching_case: 'an_invalid_line_prints_invalid_and_fails_test'),
    Seed.new(fault: 'the window read with file:read_line/1, so an unterminated stream is read whole',
             anchor: 'case erx_bt_pair:next(Reader) of',
             replacement: 'case case file:read_line(element(2, Reader)) of ' \
                          '{ok, L} -> {line, string:chomp(L), Reader}; Other -> Other end of',
             catching_case: 'an_overlong_line_prints_invalid_and_closes_at_once_test')
  ].freeze

  def test_btpair_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, MODULE))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ MODULE => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}\.\.\.(?:(?!erx_cmd_btpair_tests: ).)*?\*failed\*/m,
                   output, seed.fault)
    end
  end

  private

  def run_cases(replaced)
    Dir.mktmpdir('erx-cmd-btpair-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test([erx_cmd_btpair_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
