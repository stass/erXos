# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_pair_tests.erl, the control tree's lines (erx_bt_pair): one
# bond record, the window's lines and the bounded reading of them, compiled from source
# on stock's emulator (ERX_ERL and ERX_ERLC). Then each seeded fault, applied to a copy
# of the module, must fail the case named for it (docs/design-bluetooth.md, "Host tests
# of the cores").
class ErxBtPairTest < Minitest::Test
  APPLICATIONS = %w[erx_bt_client].freeze
  TESTS = %w[test/erlang/erx_bt_pair_tests.erl test/erlang/erx_bt_pair_stub.erl].freeze
  HOST_BYTES = { 'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '300'
  MODULE = 'erlang/apps/erx_bt_client/src/erx_bt_pair.erl'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the bonded line composed by its own code, which drops the type',
             anchor: 'format({bonded, Bond}) -> <<"bonded ", (format_bond(Bond))/binary>>;',
             replacement: 'format({bonded, #{id := I, address := A, level := L}}) -> ' \
                          'iolist_to_binary(["bonded ", I, $\s, address_text(A), $\s, atom_to_binary(L)]);',
             catching_case: 'a_bond_record_round_trips_and_is_the_rest_of_a_bonded_line_test'),
    Seed.new(fault: 'the buffer bound checked only at a newline',
             anchor: "        [_] when byte_size(Held) > ?ERX_BT_PAIR_LINE_MAX -> overlong;\n" \
                     '        [_] -> read(Reader, ?ERX_BT_PAIR_LINE_MAX + 1 - byte_size(Held))',
             replacement: '        [_] -> read(Reader, ?ERX_BT_PAIR_LINE_MAX + 1)',
             catching_case: 'a_mebibyte_with_no_newline_costs_one_bounded_buffer_test'),
    Seed.new(fault: 'a read count of the remaining file size rather than the bound',
             anchor: '        [_] -> read(Reader, ?ERX_BT_PAIR_LINE_MAX + 1 - byte_size(Held))',
             replacement: '        [_] -> read(Reader, 1 bsl 20)',
             catching_case: 'a_mebibyte_with_no_newline_costs_one_bounded_buffer_test')
  ].freeze

  def test_pair_cases_pass_under_eunit
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
      assert_match(/#{Regexp.escape(seed.catching_case)}\.\.\.(?:(?!erx_bt_pair_tests: ).)*?\*failed\*/m,
                   output, seed.fault)
    end
  end

  private

  def run_cases(replaced)
    stand_ins = HOST_BYTES.transform_values { |path| File.binread(File.join(ErlangBuild::ROOT, path)) }
    Dir.mktmpdir('erx-bt-pair-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: stand_ins.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test([erx_bt_pair_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
