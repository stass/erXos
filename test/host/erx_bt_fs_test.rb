# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_fs_tests.erl, the control tree's `pair` and `ctl` files
# (erx_bt_fs_tree) served by a real erx_fs grant over the file service erx_bt_fs, with
# stand-in links and store or the real store (docs/design-bluetooth.md, "The pairing
# window", "Bonds and the store"), on stock's emulator (ERX_ERL and ERX_ERLC), against
# the sources as they are and against each seeded fault, where the named case must fail.
class ErxBtFsTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  # The stand-ins replace the erx modules the grant calls.
  TESTS = %w[
    test/erlang/erx_bt_fs_tests.erl
    test/erlang/stand_in/erx_dist.erl
    test/erlang/stand_in/erx_connections.erl
  ].freeze
  HOST_BYTES = { 'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '120'
  FS = 'erlang/apps/erx_bt/src/erx_bt_fs.erl'
  TREE = 'erlang/apps/erx_bt/src/erx_bt_fs_tree.erl'

  # A seed's file is the service's unless it names another.
  Seed = Data.define(:fault, :anchor, :replacement, :catching_case, :file) do
    def initialize(fault:, anchor:, replacement:, catching_case:, file: FS) = super
  end

  SEEDS = [
    Seed.new(fault: "the opening grant not monitored, so a window outlives its opener's end",
             anchor: '{reply, {ok, Id}, Opened#fs{opens = Opens#{monitor(process, Grant) => Id}}};',
             replacement: '{reply, {ok, Id}, Opened#fs{opens = Opens}};',
             catching_case: 'the_openers_end_closes_the_window_test'),
    Seed.new(fault: "the window's monitor of the link not taken, so a killed link is never counted",
             anchor: '{Answer, Fs#fs{links = Links#{Link => monitor(process, Link)}}};',
             replacement: '{Answer, Fs#fs{links = Links#{Link => make_ref()}}};',
             catching_case: 'a_killed_link_fails_the_pairing_disconnected_test'),
    Seed.new(fault: 'the waiting reads not offered the lines a step writes',
             anchor: '    {Answer, wake_up(pump(Done))}.',
             replacement: '    {Answer, wake_up(Done)}.',
             catching_case: 'a_pairing_reaches_the_opener_as_lines_test'),
    Seed.new(fault: 'the state shown whole, with its passkey line',
             anchor: 'window_facts(#fs{core = Core}) -> erx_bt_window:facts(Core);',
             replacement: 'window_facts(#fs{} = State) -> State;',
             catching_case: 'status_hides_the_lines_test'),
    Seed.new(fault: "the window started without the store's state, so it opens over a store that refuses changes",
             anchor: '    start_link(erx_bt_store:known()).',
             replacement: '    start_link(read).',
             catching_case: 'the_window_starts_with_the_store_and_ends_with_it_test'),
    Seed.new(fault: "a confirmed forget not told to the window, so it refuses until the store's next start",
             file: TREE,
             anchor: '        ok = gen_server:call(Fs, {store, read}),',
             replacement: '',
             catching_case: 'forget_all_ends_the_refusal_of_a_store_unknown_since_its_start_test'),
    Seed.new(fault: "ctl's address read least significant octet first, so it names another bond",
             file: TREE,
             anchor: '|| Pair <- Pairs >>}}};',
             replacement: '|| Pair <- lists:reverse(Pairs) >>}}};',
             catching_case: 'ctl_forgets_a_bond_and_refuses_the_rest_test'),
    Seed.new(fault: "ctl's address pairs taken by length alone, so a sign reads as a digit",
             file: TREE,
             anchor: 'lists:all(fun hex_pair/1, Pairs)',
             replacement: 'lists:all(fun(Pair) -> byte_size(Pair) =:= 2 end, Pairs)',
             catching_case: 'ctl_forgets_a_bond_and_refuses_the_rest_test')
  ].freeze

  def test_pair_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.file))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.file => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}\.\.\.(?:(?!erx_bt_fs_tests: ).)*?\*failed\*/m,
                   output, seed.fault)
    end
  end

  private

  def run_cases(replaced)
    stand_ins = HOST_BYTES.transform_values { |path| File.binread(File.join(ErlangBuild::ROOT, path)) }
    Dir.mktmpdir('erx-bt-fs-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: stand_ins.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-kernel', 'logger', '[{handler, default, undefined}]',
                      '-eval', 'halt(case eunit:test(erx_bt_fs_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
