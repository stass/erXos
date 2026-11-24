# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_gatt_client_tests.erl, the cases of the `ble` facet's client side
# (erx_gatt, erx_gatt_service and erx_gatt_serial) against the real registry, compiled
# from source on stock's emulator (ERX_ERL and ERX_ERLC), with erx_dist replaced by its
# host stand-in. Then each seeded fault, applied to a copy of its module, must fail the
# case named for it.
class ErxBtGattClientTest < Minitest::Test
  APPLICATIONS = %w[erx_bt erx_bt_client].freeze
  TESTS = %w[test/erlang/erx_bt_gatt_client_tests.erl].freeze
  STAND_INS = { 'erlang/apps/erx/src/erx_dist.erl' => 'test/erlang/host_dist/erx_dist.erl',
                'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '300'
  CLIENT = 'erlang/apps/erx_bt_client/src/erx_gatt.erl'
  SERIAL = 'erlang/apps/erx_bt_client/src/erx_gatt_serial.erl'

  Seed = Data.define(:fault, :path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: "an event taken from any domain's envelope, not only the facet owner's",
             path: CLIENT, anchor: 'event(Origin, {erx_origin, Origin, Event}) ->',
             replacement: 'event(_Origin, {erx_origin, _, Event}) ->',
             catching_case: 'an event from another domain reaches no owner'),
    Seed.new(fault: 'send cutting at Mtu rather than Mtu - 3',
             path: SERIAL, anchor: 'Room = maps:get(Conn, Mtus, ?ERX_ATT_MTU_DEFAULT) - 3,',
             replacement: 'Room = maps:get(Conn, Mtus, ?ERX_ATT_MTU_DEFAULT),',
             catching_case: 'send cuts at Mtu - 3'),
    Seed.new(fault: "a write handed to an owner however far behind it is",
             path: SERIAL, anchor: 'when Queued < ?ERX_BT_WRITE_QUEUE ->',
             replacement: 'when Queued >= 0 ->',
             catching_case: 'a write to an owner that is behind is refused'),
    Seed.new(fault: 'attach passing on the first attached refusal',
             path: CLIENT, anchor: '        {error, attached} = Refusal ->',
             replacement: '        {error, attached_never} = Refusal ->',
             catching_case: 'attach_asks_again_until_the_previous_handler_has_gone'),
    Seed.new(fault: 'the serial handler started for nus whatever service it is given',
             path: SERIAL, anchor: 'erx_gatt_service:start_link({local, ?MODULE}, Service, ?MODULE, {Service, Owner}).',
             replacement: 'erx_gatt_service:start_link({local, ?MODULE}, nus, ?MODULE, {Service, Owner}).',
             catching_case: 'a serial handler of console answers console alone'),
    Seed.new(fault: 'the serial handler notifying nus whatever service it handles',
             path: SERIAL, anchor: 'case erx_gatt:notify(Conn, Service, tx, Piece) of',
             replacement: 'case erx_gatt:notify(Conn, nus, tx, Piece) of',
             catching_case: 'a serial handler of console answers console alone'),
    Seed.new(fault: "a connected event read with an identity on a link that is not bonded",
             path: CLIENT, anchor: 'bonded := true, level := Level, identity := Identity} = Info})',
             replacement: 'bonded := _, level := Level, identity := Identity} = Info})',
             catching_case: 'event_from_the_facet_owner_alone')
  ].freeze

  def test_client_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.path))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.path => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}(?:(?!erx_bt_gatt_client_tests: ).)*?\*failed\*/m,
                   output, seed.fault)
    end
  end

  private

  def run_cases(replaced)
    stand_ins = STAND_INS.transform_values { |path| File.binread(File.join(ErlangBuild::ROOT, path)) }
    Dir.mktmpdir('erx-bt-gatt-client-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: stand_ins.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-kernel', 'logger', '[{handler, default, undefined}]',
                      '-eval', 'halt(case eunit:test([erx_bt_gatt_client_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
