# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_hci_tests.erl, the cases of H4 framing (erx_h4), the HCI codec
# (erx_hci), the controller process's core (erx_bt_hci_core) and, from
# test/erlang/erx_bt_patch_tests.erl, the patch reader (erx_bt_patch), compiled from source on
# stock's emulator (ERX_ERL and ERX_ERLC). Then each seeded fault of
# docs/design-bluetooth.md, "Host tests of the cores", applied to a copy of its module,
# must fail the case named for it.
#
# Two of the design's seeds cannot be written against this core, which makes their
# faults unrepresentable: the ACL bound taken from LE Read Buffer Size (erx_h4:split/1
# takes no bound; the bound is the constant bt_acl_rx_max), and credits not returned at
# disconnection (the free credits are the buffer count less the live handles' packets in
# flight, so removing a handle returns its packets). In the second's place the handle is
# kept live after its Disconnection Complete. Nor can a second deadline armed or a
# deadline cancelled that was never armed: each deadline is a field of the state it
# guards, the slot or a taken disconnect, so leaving the state drops it and there is no
# second one to arm.
class ErxBtHciTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  TESTS = %w[test/erlang/erx_bt_hci_tests.erl test/erlang/erx_bt_patch_tests.erl].freeze
  DEADLINE_SECONDS = '300'
  H4 = 'erlang/apps/erx_bt/src/erx_h4.erl'
  CORE = 'erlang/apps/erx_bt/src/erx_bt_hci_core.erl'
  PATCH = 'erlang/apps/erx_bt/src/erx_bt_patch.erl'
  HCI = 'erlang/apps/erx_bt/src/erx_hci.erl'

  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'new advertising data kept behind data not yet written, so the earlier is written',
             module_path: CORE,
             anchor: '    {[], Core#core{advertising_data = Data}};',
             replacement: '    {[], Core#core{advertising_data = case Core#core.advertising_data of none -> Data; Kept -> Kept end}};',
             catching_case: 'explored_advertising_data_test'),
    Seed.new(fault: 'the record length not checked against the bytes left',
             module_path: PATCH,
             anchor: "parse(_Bytes, Offset, _Records) ->\n    throw({truncated, Offset}).",
             replacement: "parse(<<Opcode:16/little, _Length, Payload/binary>>, _Offset, Records) ->\n    lists:reverse([{Opcode, Payload} | Records]);\n" \
                          "parse(_Bytes, Offset, _Records) ->\n    throw({truncated, Offset}).",
             catching_case: 'truncated_last_record_is_refused_whole_test'),
    Seed.new(fault: 'the indicator check removed, so an unknown byte is skipped',
             module_path: H4,
             anchor: "split(<<Indicator, _/binary>>, _Packets) ->\n    {error, {bad_indicator, Indicator}};",
             replacement: "split(<<_, Rest/binary>>, Packets) ->\n    split(Rest, Packets);",
             catching_case: 'unknown_indicator_is_an_error_test'),
    Seed.new(fault: 'the ACL length read as one byte',
             module_path: H4,
             anchor: 'Word:16/little, Length:16/little, Data:Length/binary',
             replacement: 'Word:16/little, _:8, Length:8, Data:Length/binary',
             catching_case: 'a_stream_cut_anywhere_splits_the_same_test'),
    Seed.new(fault: 'the ACL bound one octet too long',
             module_path: H4,
             anchor: 'when Length > ?ERX_BT_ACL_RX_MAX ->',
             replacement: 'when Length > ?ERX_BT_ACL_RX_MAX + 1 ->',
             catching_case: 'acl_of_252_octets_is_an_error_test'),
    Seed.new(fault: 'the command slot not cleared by Command Status',
             module_path: CORE,
             anchor: 'answered(Label, Command, Answer, Core#core{slot = idle});',
             replacement: 'answered(Label, Command, Answer, case Answer of {status, _} -> Core; _ -> ' \
                          'Core#core{slot = idle} end);',
             catching_case: 'a_disconnect_answered_by_status_frees_the_slot_test'),
    Seed.new(fault: 'a handle kept live after its Disconnection Complete',
             module_path: CORE,
             anchor: 'Core#core{links = maps:remove(Handle, Links),',
             replacement: 'Core#core{links = Links,',
             catching_case: 'disconnection_returns_a_handles_packets_test'),
    Seed.new(fault: "a completion's count taken without the in-flight bound",
             module_path: CORE,
             anchor: '#{Handle := #live{in_flight = InFlight} = Live} when Count =< InFlight - Queued ->',
             replacement: '#{Handle := #live{in_flight = InFlight} = Live} ->',
             catching_case: 'a_forged_completion_stops_test'),
    Seed.new(fault: 'advertising not enabled again after a disconnection',
             module_path: CORE,
             anchor: 'Core#core{links = maps:remove(Handle, Links),',
             replacement: 'Core#core{advertising = true, links = maps:remove(Handle, Links),',
             catching_case: 'advertising_resumes_after_a_disconnection_test'),
    Seed.new(fault: "a completion's bound counting packets still on the writer's list",
             module_path: CORE,
             anchor: 'when Count =< InFlight - Queued ->',
             replacement: 'when Count =< InFlight ->',
             catching_case: 'a_completion_of_a_queued_packet_stops_test'),
    Seed.new(fault: 'the deadline armed only once the controller allows the command',
             module_path: CORE,
             anchor: "        _ -> {[], Core#core{slot = {due, Now + ?ERX_BT_COMMAND_TIMEOUT_MS}}}\n",
             replacement: "        _ when Core#core.allowed =:= 0 -> {[], Core};\n" \
                          "        _ -> {[], Core#core{slot = {due, Now + ?ERX_BT_COMMAND_TIMEOUT_MS}}}\n",
             catching_case: 'a_command_the_controller_never_allows_stops_on_its_deadline_test'),
    Seed.new(fault: 'the connection limit kept above the buffer count',
             module_path: CORE,
             anchor: 'limit = min(Limit, Credits)}',
             replacement: 'limit = Limit}',
             catching_case: 'fewer_buffers_than_connections_lower_the_limit_test'),
    Seed.new(fault: "LE's 27-octet minimum applied to Read Buffer Size",
             module_path: CORE,
             anchor: 'bringup(shared_buffers, {Length, Packets}, Core) when Length > 0, Packets > 0 ->',
             replacement: 'bringup(shared_buffers, {Length, Packets}, Core) when Length >= 27, Packets > 0 ->',
             catching_case: 'shared_buffers_take_any_length_from_one_test'),
    Seed.new(fault: "a handle's disconnect kept after its Disconnection Complete, so it reaches the next peer",
             module_path: CORE,
             anchor: 'disconnects = lists:keydelete(Handle, 1, Core#core.disconnects),',
             replacement: 'disconnects = Core#core.disconnects,',
             catching_case: 'explored_core_keeps_its_invariants_test_'),
    Seed.new(fault: "a connection before the advertising enable's answer leaving advertising on",
             module_path: CORE,
             anchor: 'overtaken({sent, advertise, Command, Opcode, Deadline}) -> {sent, advertise_overtaken, Command, Opcode, Deadline};',
             replacement: 'overtaken({sent, advertise, Command, Opcode, Deadline}) -> {sent, advertise, Command, Opcode, Deadline};',
             catching_case: 'explored_core_keeps_its_invariants_test_'),
    Seed.new(fault: 'a connection accepted on a handle whose disconnect is handed over and unanswered',
             module_path: CORE,
             anchor: "connected(Handle, _Peer, #core{slot = {sent, {disconnect, Handle}, _, _, _}}) ->\n" \
                     "    stop({connection_while_disconnecting, Handle});\n",
             replacement: '',
             catching_case: 'a_connection_on_a_handle_being_disconnected_stops_test'),
    Seed.new(fault: 'any failed disconnect taken as the handle gone',
             module_path: CORE,
             anchor: '        Failed -> stop({disconnect_failed, Handle, Failed})',
             replacement: '        _Failed -> {[], Core}',
             catching_case: 'a_disconnect_is_asked_once_and_a_failure_other_than_gone_or_ending_stops_test'),
    Seed.new(fault: "a taken disconnect's deadline never armed, so no wake-up comes for it",
             module_path: CORE,
             anchor: '        [{{disconnect, Handle}, Deadline} || {Handle, {taken, Deadline}} <- Disconnects].',
             replacement: '        lists:sublist(Disconnects, 0).',
             catching_case: 'a_disconnect_not_completed_by_its_deadline_stops_test'),
    Seed.new(fault: 'a disconnect answered Command Disallowed asked again at once',
             module_path: CORE,
             anchor: '        {failed, ?ERX_HCI_STATUS_COMMAND_DISALLOWED} -> {[], Core};',
             replacement: '        {failed, ?ERX_HCI_STATUS_COMMAND_DISALLOWED} -> ' \
                          '{[], disconnect(Handle, 16#13, Core#core{disconnects = ' \
                          'lists:keydelete(Handle, 1, Core#core.disconnects)})};',
             catching_case: 'explored_core_keeps_its_invariants_test_'),
    Seed.new(fault: "a taken disconnect kept past its handle's Disconnection Complete, so its deadline stops a later run",
             module_path: CORE,
             anchor: '                       disconnects = lists:keydelete(Handle, 1, Core#core.disconnects),',
             replacement: '                       disconnects = [Mark || {Owner, Value} = Mark <- Core#core.disconnects, ' \
                          'Owner =/= Handle orelse element(1, Value) =:= taken],',
             catching_case: 'a_disconnect_not_completed_by_its_deadline_stops_test'),
    Seed.new(fault: "the line's reset under no deadline",
             module_path: CORE,
             anchor: 'slot_deadline({line_reset, Deadline}) -> [Deadline];',
             replacement: 'slot_deadline({line_reset, _Deadline}) -> [];',
             catching_case: 'a_line_reset_that_never_ends_stops_test'),
    Seed.new(fault: 'the due deadline restarted on every input, so repeated traffic holds a command off',
             module_path: CORE,
             anchor: "        true -> {[], Core#core{slot = idle}};\n        false -> {[], Core}\n",
             replacement: "        true -> {[], Core#core{slot = idle}};\n" \
                          "        false -> {[], Core#core{slot = {due, Now + ?ERX_BT_COMMAND_TIMEOUT_MS}}}\n",
             catching_case: 'explored_core_keeps_its_invariants_test_'),
    Seed.new(fault: 'a due slot emptied while the line takes no command, so connections that come and go ' \
                    'hold a command off',
             module_path: CORE,
             anchor: '    case due(Now, Core) =:= none andalso line_takes_command(Core) of',
             replacement: '    case due(Now, Core) =:= none of',
             catching_case: 'a_command_due_again_keeps_its_deadline_test'),
    Seed.new(fault: 'completions not passed to their links, so a link never counts its share back',
             module_path: CORE,
             anchor: 'completed(Handle, Count, Core) -> to_link(Handle, {completed, Count}, Core).',
             replacement: 'completed(_Handle, _Count, Core) -> {[], Core}.',
             catching_case: 'explored_core_keeps_its_invariants_test_'),
    Seed.new(fault: 'a deadline passed only after its instant',
             module_path: CORE,
             anchor: '<- deadlines(Core), Deadline =< Now] of',
             replacement: '<- deadlines(Core), Deadline < Now] of',
             catching_case: 'explored_core_keeps_its_invariants_test_'),
    Seed.new(fault: 'a deadline passed a millisecond early',
             module_path: CORE,
             anchor: '<- deadlines(Core), Deadline =< Now] of',
             replacement: '<- deadlines(Core), Deadline =< Now + 1] of',
             catching_case: 'explored_core_keeps_its_invariants_test_'),
    Seed.new(fault: "a request's link identity ignored, so a gone link's packet reaches its handle's next peer",
             module_path: CORE,
             anchor: "current({Handle, Serial}, #core{links = Links}) ->\n    case Links of\n" \
                     "        \#{Handle := #live{serial = Serial} = Live} -> {current, Live};",
             replacement: "current({Handle, _Serial}, #core{links = Links}) ->\n    case Links of\n" \
                          "        \#{Handle := #live{} = Live} -> {current, Live};",
             catching_case: 'explored_core_keeps_its_invariants_test_'),
    Seed.new(fault: "a Long Term Key reply kept past its handle's Disconnection Complete",
             module_path: CORE,
             anchor: 'replies = lists:keydelete(Handle, 1, Core#core.replies)}};',
             replacement: 'replies = Core#core.replies}};',
             catching_case: 'a_reply_never_reaches_a_reused_handle_test'),
    Seed.new(fault: "a Long Term Key reply's answer naming another handle passed to the link",
             module_path: CORE,
             anchor: '        {ok, Handle} -> to_link(Handle, {ltk_reply_complete, ok}, Core);',
             replacement: '        {ok, _} -> to_link(Handle, {ltk_reply_complete, ok}, Core);',
             catching_case: 'a_long_term_key_reply_reaches_the_controller_and_its_answer_the_link_test'),
    Seed.new(fault: "a link's backlog bound compared one too late, so 33 messages are sent",
             module_path: CORE,
             anchor: '#{Handle := #live{backlog = ?ERX_BT_LINK_BACKLOG} = Live} ->',
             replacement: '#{Handle := #live{backlog = ?ERX_BT_LINK_BACKLOG + 1} = Live} ->',
             catching_case: 'a_link_that_acknowledges_nothing_is_sent_32_messages_test'),
    Seed.new(fault: "completions sent past the backlog's funnel, so they are not counted",
             module_path: CORE,
             anchor: 'completed(Handle, Count, Core) -> to_link(Handle, {completed, Count}, Core).',
             replacement: 'completed(Handle, Count, #core{links = Links} = Core) -> ' \
                          '{[{to_link, {Handle, (map_get(Handle, Links))#live.serial}, {completed, Count}}], Core}.',
             catching_case: 'a_link_that_acknowledges_nothing_is_sent_32_messages_test'),
    Seed.new(fault: "a link's taken read by its handle without its name, so a gone link's lowers the next link's backlog",
             module_path: CORE,
             anchor: "untimed({request, Link, Request}, Core) ->\n",
             replacement: "untimed({request, {Handle, _}, taken}, #core{links = Links} = Core)\n" \
                          "  when is_map_key(Handle, Links), is_integer((map_get(Handle, Links))#live.backlog),\n" \
                          "       (map_get(Handle, Links))#live.backlog > 0 ->\n" \
                          "    Live = map_get(Handle, Links),\n" \
                          "    {[], Core#core{links = Links\#{Handle := Live#live{backlog = Live#live.backlog - 1}}}};\n" \
                          "untimed({request, Link, Request}, Core) ->\n",
             catching_case: 'a_gone_links_acknowledgement_changes_nothing_test'),
    Seed.new(fault: "LE Connection Complete's Peer_Address_Type passed through as its octet",
             module_path: HCI,
             anchor: '{le_connection_complete, handle(Handle), {peer_type(PeerType), reverse(Peer)}};',
             replacement: '{le_connection_complete, handle(Handle), {PeerType, reverse(Peer)}};',
             catching_case: 'le_connection_complete_reads_its_status_first_test'),
    Seed.new(fault: "a failed LE Connection Complete's handle and address type checked before its Status",
             module_path: HCI,
             anchor: "<<Status, _/binary>>) when Status =/= ?ERX_HCI_STATUS_SUCCESS ->\n" \
                     "    {le_connection_complete, {failed, Status}};",
             replacement: "<<Status, Handle:16/little, _Role, PeerType, _/binary>>) when Status =/= ?ERX_HCI_STATUS_SUCCESS ->\n" \
                          "    _ = {handle(Handle), peer_type(PeerType)},\n" \
                          "    {le_connection_complete, {failed, Status}};",
             catching_case: 'le_connection_complete_reads_its_status_first_test')
  ].freeze

  def test_bluetooth_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.module_path))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.module_path => source.sub(seed.anchor) { seed.replacement } },
                                 only: seed.catching_case)
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  # The modules, with replaced ones in place of the application's own, then the cases:
  # all of them, or with only: the one case named, which a seeded fault must fail (the
  # explored case alone takes minutes, so the other seeds' runs skip it).
  def run_cases(replaced, only: nil)
    Dir.mktmpdir('erx-bt-hci-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', "halt(case eunit:test(#{eunit_spec(only)}, [verbose]) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end

  # What eunit runs: both test modules, or the one case, from the module that defines it.
  def eunit_spec(only)
    return '[erx_bt_hci_tests, erx_bt_patch_tests]' if only.nil?

    source = TESTS.find { |path| File.read(File.join(ErlangBuild::ROOT, path)).match?(/^#{Regexp.escape(only)}\(/) }
    raise ArgumentError, "no test module defines #{only}" if source.nil?

    owner = File.basename(source, '.erl')
    # eunit runs {Module, Name} as a plain test, which would take a generator's
    # returned tests for the result, so a generator (a name ending in _) is named as one.
    only.end_with?('_') ? "{generator, fun #{owner}:#{only}/0}" : "{#{owner}, #{only}}"
  end
end
