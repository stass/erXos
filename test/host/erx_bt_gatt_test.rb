# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_gatt_tests.erl, the cases of the GATT server's cores: L2CAP's
# frames (erx_l2cap), the gate (erx_gatt_gate), the attribute table (erx_gatt_db) and the
# ATT server (erx_att, erx_gatt_server), compiled from source on stock's emulator (ERX_ERL
# and ERX_ERLC) with erx_bytes's stand-in. Then each seeded fault of
# docs/design-bluetooth.md, "Host tests of the cores", and of the bounds the link's frames
# and bearer keep, applied to a copy of its module, must fail the case named for it.
class ErxBtGattTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  TESTS = %w[test/erlang/erx_bt_gatt_tests.erl].freeze
  HOST_BYTES = { 'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '300'
  L2CAP = 'erlang/apps/erx_bt/src/erx_l2cap.erl'
  GATE = 'erlang/apps/erx_bt/src/erx_gatt_gate.erl'
  DB = 'erlang/apps/erx_bt/src/erx_gatt_db.erl'
  SERVER = 'erlang/apps/erx_bt/src/erx_gatt_server.erl'

  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: "a write command past bt_write_queue discarded and the link kept",
             module_path: SERVER,
             anchor: "false when Commands >= ?ERX_BT_WRITE_QUEUE -> {[{close, write_queue_full}], Bearer};",
             replacement: "false when Commands >= ?ERX_BT_WRITE_QUEUE -> {[], Bearer};",
             catching_case: "commands_wait_behind_the_handler_and_overflow_ends_the_link_test"),
    Seed.new(fault: 'the bond check dropped from the gate, so a pairing link passes bonded',
             module_path: GATE,
             anchor: 'check(bonded, _Security) -> {error, insufficient_authentication}.',
             replacement: 'check(bonded, _Security) -> ok.',
             catching_case: 'gate_bonded_requires_the_kept_bond_test'),
    Seed.new(fault: 'a value no handler has set read without the gate, as a handlerless service is',
             module_path: SERVER,
             anchor: 'readable(#{read := Level}, #{security := Security}, _Bearer) -> erx_gatt_gate:check(Level, Security).',
             replacement: 'readable(#{read := Level, source := {value, Key, _}}, #{security := Security, values := Values}, ' \
                          '_Bearer) when is_map_key(Key, Values) -> erx_gatt_gate:check(Level, Security); ' \
                          'readable(#{read := _}, _Server, _Bearer) -> ok.',
             catching_case: 'bondcheck_reads_only_through_the_gate_test'),
    Seed.new(fault: 'services laid out in manifest order',
             module_path: DB,
             anchor: 'Sorted = lists:sort(fun(#{name := A}, #{name := B}) -> A =< B end, Services),',
             replacement: 'Sorted = Services,',
             catching_case: 'table_ignores_manifest_order_test'),
    Seed.new(fault: 'the handle bound removed, so a table past 0xFFFF builds',
             module_path: DB,
             anchor: 'tuple_size(Tuple) =< 16#FFFF orelse error({handles_past_0xffff, tuple_size(Tuple)}),',
             replacement: 'true,',
             catching_case: 'table_past_0xffff_handles_is_refused_test'),
    Seed.new(fault: "the descriptor's write level taken from read",
             module_path: DB,
             anchor: 'source => {configuration, Key}, read => open, write => Subscribe,',
             replacement: 'source => {configuration, Key}, read => open, write => open,',
             catching_case: 'configuration_write_is_gated_at_notify_level_test'),
    Seed.new(fault: "the descriptor's write level taken from the declaration alone",
             module_path: SERVER,
             anchor: 'write_level({configuration, _Key}, open, #{key := Key}) when Key =/= none -> encrypted;',
             replacement: 'write_level({configuration, _Key}, never, #{key := Key}) when Key =/= none -> encrypted;',
             catching_case: 'keyed_configuration_write_waits_for_encryption_test'),
    Seed.new(fault: 'Insufficient Encryption answered on a link with no key',
             module_path: GATE,
             anchor: 'check(_Level, #{key := none}) -> {error, insufficient_authentication};',
             replacement: 'check(_Level, #{key := none}) -> {error, insufficient_encryption};',
             catching_case: 'gate_follows_gap_table_10_2_test'),
    Seed.new(fault: 'the gate skipped for Read Blob',
             module_path: SERVER,
             anchor: 'Value = read(?ERX_ATT_OPCODE_READ_BLOB_REQ, Handle, Server, Bearer),',
             replacement: '{ok, Attribute} = erx_gatt_db:lookup(Handle, maps:get(table, Server)), ' \
                          'Value = value(Attribute, Server, Bearer),',
             catching_case: 'read_blob_asks_the_gate_test'),
    Seed.new(fault: 'a second request queued behind the first',
             module_path: SERVER,
             anchor: 'true when Requests =/= []; Awaited =/= command -> {[{close, request_outstanding}], Bearer};',
             replacement: 'true when false -> {[], Bearer};',
             catching_case: 'second_request_before_the_response_ends_the_link_test'),
    Seed.new(fault: 'a configuration changed before its answer, so a bonded write took effect before the store kept it',
             module_path: SERVER,
             anchor: 'awaiting = {Ref, Answered, {Key, Kind}}}}',
             replacement: 'awaiting = {Ref, Answered, {Key, Kind}}, subscriptions = Subscriptions#{Key => Kind}}}',
             catching_case: 'configuration_changes_only_at_its_answer_test'),
    Seed.new(fault: 'an answer taken whatever write it names',
             module_path: SERVER,
             anchor: 'reply(Ref, Answer, Server, #bearer{awaiting = {Ref, Answered, Change}} = Bearer) ->',
             replacement: 'reply(_, Answer, Server, #bearer{awaiting = {_, Answered, Change}} = Bearer) ->',
             catching_case: 'late_answer_is_not_taken_for_the_next_write_test'),
    Seed.new(fault: 'a second indication sent while one is in flight',
             module_path: SERVER,
             anchor: 'ok when Bearer#bearer.indication =/= none -> {error, busy};',
             replacement: 'ok when false -> {error, busy};',
             catching_case: 'one_indication_in_flight_test'),
    Seed.new(fault: 'a continuation without a start taken as a frame',
             module_path: L2CAP,
             anchor: 'reassemble(?ERX_HCI_ACL_BOUNDARY_CONTINUING, _Data, none) -> {error, continuation_without_start};',
             replacement: 'reassemble(?ERX_HCI_ACL_BOUNDARY_CONTINUING, Data, none) -> frame(Data);',
             catching_case: 'continuation_without_start_ends_the_link_test'),
    Seed.new(fault: "a frame's bound one octet too long",
             module_path: L2CAP,
             anchor: 'Bound when Length > Bound ->',
             replacement: 'Bound when Length > Bound + 1 ->',
             catching_case: 'frame_past_its_channel_bound_is_refused_test'),
    Seed.new(fault: 'the gate skipped for Write Command',
             module_path: SERVER,
             anchor: "case erx_gatt_gate:check(Level, Security) of\n                " \
                     'ok -> give(Key, Value, command, Bearer);',
             replacement: "case erx_gatt_gate:check(open, Security) of\n                " \
                          'ok -> give(Key, Value, command, Bearer);',
             catching_case: 'gate_guards_commands_prepares_and_value_search_test'),
    Seed.new(fault: 'the gate skipped for Write Request and Prepare Write',
             module_path: SERVER,
             anchor: "case erx_gatt_gate:check(write_level(Source, Level, Security), Security) of\n                ok -> Attribute;",
             replacement: "case erx_gatt_gate:check(open, Security) of\n                ok -> Attribute;",
             catching_case: 'gate_guards_commands_prepares_and_value_search_test'),
    Seed.new(fault: 'Find By Type Value comparing values the gate hides',
             module_path: SERVER,
             anchor: 'same_type(T, Type) andalso readable(A, Server, Bearer) =:= ok',
             replacement: 'same_type(T, Type)',
             catching_case: 'gate_guards_commands_prepares_and_value_search_test')
  ].freeze

  def test_gatt_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.module_path))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.module_path => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  # The modules, erx_bytes's stand-in and the replaced ones in place of the applications'
  # own, then the cases.
  def run_cases(replaced)
    stand_ins = HOST_BYTES.transform_values { |path| File.binread(File.join(ErlangBuild::ROOT, path)) }
    Dir.mktmpdir('erx-bt-gatt-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: stand_ins.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                      '-kernel', 'logger_level', 'none', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_bt_gatt_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
