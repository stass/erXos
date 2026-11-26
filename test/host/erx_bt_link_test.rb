# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_link_tests.erl, the cases of the link's core, erx_bt_link_core:
# its channels, its one key and the controller's encryption, its deadlines and queue, a
# pairing through it and its exploration, compiled from source on stock's emulator
# (ERX_ERL and ERX_ERLC). Then each seeded fault of docs/design-bluetooth.md, "Host tests
# of the cores", applied to a copy of the module, must fail the case named for it.
class ErxBtLinkTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  TESTS = %w[test/erlang/erx_bt_link_tests.erl].freeze
  HOST_BYTES = { 'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '300'
  CORE = 'erlang/apps/erx_bt/src/erx_bt_link_core.erl'
  EXPLORED = 'erx_bt_link_tests: explore...'

  SMP_CORE = 'erlang/apps/erx_bt/src/erx_smp_core.erl'

  # A seeded fault in the link's core, or in the module `path` names.
  Seed = Data.define(:fault, :anchor, :replacement, :catching_case, :path) do
    def initialize(path: CORE, **fields) = super
  end

  SEEDS = [
    Seed.new(fault: 'a frame on an unknown channel dropped without being counted',
             anchor: '    {[], Core#core{dropped = Dropped + 1}}.',
             replacement: '    {[], Core}.',
             catching_case: 'unknown_channel_counted_test'),
    Seed.new(fault: "a link with a key pairing again, so its pairing would give it a second key",
             anchor: 'input({window, {admission, Tag, {open, _Mode, _Fresh}}}, Now, #core{key = {_, _}} = Core) ->',
             replacement: 'input({window, {admission, Tag, {open, _Mode, _Fresh}}}, Now, #core{key = never} = Core) ->',
             catching_case: 'bonded_link_never_pairs_test'),
    Seed.new(fault: 'the gate shown a keyed link as encrypted before the controller reports it',
             anchor: 'security => #{key => gate_key(Key), encrypted => Encrypted, bonded => bonded(Core)}}.',
             replacement: 'security => #{key => gate_key(Key), encrypted => Key =/= none, bonded => bonded(Core)}}.',
             catching_case: 'write_waits_for_encryption_test'),
    Seed.new(fault: 'the gate shown a pairing link as bonded before the store has kept its bond',
             anchor: 'security => #{key => gate_key(Key), encrypted => Encrypted, bonded => bonded(Core)}}.',
             replacement: 'security => #{key => gate_key(Key), encrypted => Encrypted, bonded => true}}.',
             catching_case: 'bonded_write_waits_for_the_kept_bond_test'),
    Seed.new(fault: 'an Encryption Change accepted after a Negative Reply',
             anchor: "?ERX_HCI_ENCRYPTION_ON_LE}, Now,\n    #core{ltk_answer = replied} = Core) ->",
             replacement: "?ERX_HCI_ENCRYPTION_ON_LE}, Now,\n    #core{} = Core) ->",
             catching_case: 'negative_reply_then_change_ends_link_test'),
    Seed.new(fault: 'encryption accepted only for kept bonds',
             anchor: 'hci({le_long_term_key_request, _Handle, <<0:64>>, 0}, _Now, #core{key = {Ltk, _}} = Core) ->',
             replacement: 'hci({le_long_term_key_request, _Handle, <<0:64>>, 0}, _Now, ' \
                          '#core{key = {Ltk, _}, bond = {candidate, _, _}} = Core) ->',
             catching_case: 'first_pairing_reaches_level_before_store_test'),
    Seed.new(fault: 'the notification queue unbounded',
             anchor: 'full(Queue) -> queue:len(Queue) >= ?ERX_BT_NOTIFY_QUEUE.',
             replacement: 'full(_Queue) -> false.',
             catching_case: 'notification_queue_bound_test'),
    Seed.new(fault: "the hand-over past the link's share of the controller's buffers",
             anchor: 'when Outstanding >= Share ->',
             replacement: 'when Outstanding >= Share + 1 ->',
             catching_case: EXPLORED),
    Seed.new(fault: "the handler's deadline a millisecond late",
             anchor: 'Core#core{write = {Ref, Now + ?ERX_BT_HANDLER_TIMEOUT_MS}}',
             replacement: 'Core#core{write = {Ref, Now + ?ERX_BT_HANDLER_TIMEOUT_MS + 1}}',
             catching_case: 'handler_deadline_test'),
    Seed.new(fault: "ATT's responses queued without bound for a phone that does not wait",
             anchor: 'case queue:len(Queue) >= ?ERX_BT_NOTIFY_QUEUE + 2 of',
             replacement: 'case false of',
             catching_case: 'att_request_flood_ends_link_test'),
    Seed.new(fault: "signaling's answers queued whatever the queue holds",
             anchor: '{reply, Reply} -> queue(?ERX_L2CAP_CID_LE_SIGNALING, Reply, droppable, Core);',
             replacement: '{reply, Reply} -> queue(?ERX_L2CAP_CID_LE_SIGNALING, Reply, always, Core);',
             catching_case: 'signaling_answers_dropped_at_full_queue_test'),
    Seed.new(fault: "the refusal after the bond told to the window as the pairing's outcome",
             anchor: '     Core#core{awaiting = none, bond = {keeping, none}}};',
             replacement: '     Core#core{bond = {keeping, none}}};',
             catching_case: 'done_refusal_not_an_outcome_test'),
    Seed.new(fault: 'a Reply the controller failed still taken as a Reply',
             anchor: 'hci({ltk_reply_complete, {failed, _Status}}, _Now, #core{ltk_answer = replied} = Core) ->',
             replacement: 'hci({ltk_reply_complete, {failed, _Status}}, _Now, #core{ltk_answer = never} = Core) ->',
             catching_case: 'failed_reply_counts_as_none_test'),
    Seed.new(fault: "a controller message's step without its `taken`, so the backlog grows without bound",
             anchor: '    {[{hci, taken} | Actions], Next};',
             replacement: '    {Actions, Next};',
             catching_case: 'roles_test'),
    Seed.new(fault: "the bond's subscriptions taken at new/1, so a resolved link's configuration reads as the bond's",
             anchor: 'bearer = erx_gatt_server:new(),',
             replacement: 'bearer = element(2, erx_gatt_server:restore(case Resolved of none -> #{}; ' \
                          '#{subscriptions := S} -> S end, Table, erx_gatt_server:new())),',
             catching_case: 'resolved_bond_is_taken_on_at_encryption_test'),
    Seed.new(fault: "`keep` sent without `keeping`, so the window would count a kept bond's link end as failed",
             anchor: '    {[{store, {keep, Tag, Bond, erx_gatt_server:subscriptions(Bearer)}}, {window, {keeping, Tag}}],',
             replacement: '    {[{store, {keep, Tag, Bond, erx_gatt_server:subscriptions(Bearer)}}],',
             catching_case: 'first_pairing_reaches_level_before_store_test'),
    Seed.new(fault: 'the configuration write answered before the store keeps it',
             anchor: "configuration(Ref, Key, Kind, _Now, #core{bond = {kept, _Id, none}} = Core) ->\n" \
                     '    keep_configuration(Ref, Key, Kind, Core);',
             replacement: "configuration(Ref, _Key, _Kind, Now, #core{bond = {kept, _Id, none}} = Core) ->\n" \
                          '    att(erx_gatt_server:reply(Ref, ok, server(Core), Core#core.bearer), Now, Core);',
             catching_case: 'bonded_configuration_write_waits_for_the_store_test'),
    Seed.new(fault: 'the Security Request sent once the phone has begun encryption',
             anchor: 'pairing_wait_answered(0, _Now, Rest, #core{ltk_answer = none, smp_deadline = none,',
             replacement: 'pairing_wait_answered(0, _Now, Rest, #core{smp_deadline = none,',
             catching_case: 'security_request_once_never_during_encryption_test'),
    Seed.new(fault: 'the Security Request sent while the phone pairs',
             anchor: 'pairing_wait_answered(0, _Now, Rest, #core{ltk_answer = none, smp_deadline = none,',
             replacement: 'pairing_wait_answered(0, _Now, Rest, #core{ltk_answer = none,',
             catching_case: 'security_request_once_never_during_encryption_test'),
    Seed.new(fault: 'the Security Request asked again after it was sent',
             anchor: "          Core#core{bond = {candidate, Rest, done}});\n",
             replacement: "          Core#core{bond = {candidate, Rest, {look, _Now}}});\n",
             catching_case: 'security_request_once_never_during_encryption_test'),
    Seed.new(fault: "Service Changed indicated whatever the bond's table hash",
             anchor: '{Changed, Next} = case Hash =:= erx_gatt_db:hash(Table) of',
             replacement: '{Changed, Next} = case Hash =:= unserved of',
             catching_case: 'service_changed_at_reconnection_test'),
    Seed.new(fault: "a configuration write held while the store keeps the pairing's bond answered at once",
             anchor: "#core{bond = {keeping, none}} = Core) ->\n" \
                     '    {[], Core#core{bond = {keeping, {Ref, Key, Kind}}}};',
             replacement: "#core{bond = {keeping, none}} = Core) ->\n" \
                          '    att(erx_gatt_server:reply(Ref, ok, server(Core), Core#core.bearer), _Now, Core);',
             catching_case: 'configuration_write_while_keeping_waits_for_the_keep_test'),
    Seed.new(fault: 'the pairing not awaited from its `admit`, so a failure before the verdict is never told',
             anchor: '    {[{window, {admit, Tag, Central}}], Core#core{awaiting = Tag}};',
             replacement: '    {[{window, {admit, Tag, Central}}], Core};',
             catching_case: 'failure_before_the_verdict_reaches_the_window_test'),
    Seed.new(fault: "a `withdraw` taken in the Security Manager's `done`, withdrawn while the store keeps the bond",
             path: SMP_CORE,
             anchor: 'phase(_Input, done, _State) -> {[], done};',
             replacement: "phase({withdraw, _}, done, _State) -> fail(?ERX_SMP_REASON_UNSPECIFIED_REASON, withdrawn);\n" \
                          'phase(_Input, done, _State) -> {[], done};',
             catching_case: 'first_pairing_reaches_level_before_store_test'),
    Seed.new(fault: "the security told from the link before its encryption proved the bond, so a reconnection " \
                    'reports no bond',
             anchor: '               false -> security(Proven)',
             replacement: '               false -> security(Core#core{encrypted = true})',
             catching_case: 'bonded_link_reports_the_bonds_id_test'),
    Seed.new(fault: 'a bond id reported for a link that is not bonded',
             anchor: 'bond_id(_Bond) -> none.',
             replacement: 'bond_id(_Bond) -> <<"00000000000000000000000000000001">>.',
             catching_case: 'first_pairing_reaches_level_before_store_test')
  ].freeze

  def test_link_core_cases_pass_under_eunit
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
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  # The modules, erx_bytes's stand-in and the replaced ones in place of the applications'
  # own, then the cases.
  def run_cases(replaced)
    stand_ins = HOST_BYTES.transform_values { |path| File.binread(File.join(ErlangBuild::ROOT, path)) }
    Dir.mktmpdir('erx-bt-link-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: stand_ins.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test([erx_bt_link_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
