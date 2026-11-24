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
  # The echo app of examples/echo, built here as its package's module over the client.
  ECHO = 'examples/echo/lib/erx_echo/src/erx_echo.erl'
  TESTS = ['test/erlang/erx_bt_gatt_client_tests.erl', ECHO].freeze
  STAND_INS = { 'erlang/apps/erx/src/erx_dist.erl' => 'test/erlang/host_dist/erx_dist.erl',
                'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '300'
  CLIENT = 'erlang/apps/erx_bt_client/src/erx_gatt.erl'
  SERIAL = 'erlang/apps/erx_bt_client/src/erx_gatt_serial.erl'
  SERVICE = 'erlang/apps/erx_bt_client/src/erx_gatt_service.erl'

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
    Seed.new(fault: 'the serial handler started for a service without the serial shape',
             path: SERIAL, anchor: '    case serial_shape(Table) of',
             replacement: '    case true of',
             catching_case: 'a service without the serial shape gets no serial handler'),
    Seed.new(fault: "a connected event read with an identity on a link that is not bonded",
             path: CLIENT, anchor: 'bonded := true, level := Level, identity := Identity} = Info})',
             replacement: 'bonded := _, level := Level, identity := Identity} = Info})',
             catching_case: 'event_from_the_facet_owner_alone'),
    Seed.new(fault: 'the echo sending every write to the first link to have written',
             path: ECHO, anchor: "{serial, Conn, Bytes} ->\n",
             replacement: "{serial, Written, Bytes} ->\n" \
                          "            Conn = case get(first) of undefined -> put(first, Written), Written; " \
                          "First -> First end,\n",
             catching_case: 'the echo app answers each link on its own link'),
    Seed.new(fault: 'a handler attaching without waiting for its domain to hold ble',
             path: SERVICE, anchor: "    _ = erx_facets:await(ble, none, ?ERX_BT_ATTACH_WAIT_MS),\n",
             replacement: '',
             catching_case: 'a handler started before its domain holds ble attaches once it does'),
    Seed.new(fault: "a handler's reports showing its last message and state",
             path: SERVICE, anchor: 'handle_info/2, format_status/1]).',
             replacement: 'handle_info/2]).',
             catching_case: 'no report of a handler that held a write shows its bytes'),
    Seed.new(fault: "a callback's raise stopping the handler with its reason and stack trace",
             path: SERVICE,
             anchor: '        Class:Reason -> {stop, {Class, erx_report:reason_name(Reason)}, Handler}',
             replacement: 'Class:Reason:Stack -> erlang:raise(Class, Reason, Stack)',
             catching_case: 'no report of a handler that held a write shows its bytes')
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
      assert_match(/#{Regexp.escape(seed.catching_case)}(?:(?!erx_bt_gatt_client_tests: ).)*?\*(?:failed|timed out)\*/m,
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
