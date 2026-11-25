# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/generated'
require_relative '../fixtures/erlang_build'

# The erx_fs grant, the domain's file version counter and storage's data mint:
# test/erlang/erx_fs_tests.erl, erx_fs_version_tests.erl and erx_fs_mint_tests.erl run on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies) against the sources
# as they are, and against each seeded fault of docs/design-files.md#verification-and-testing
# and of the mint, where the named test must fail. A fault in the protocol table reaches
# the grant through the grammar generated from it.
class ErxFsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  GRAMMAR = 'build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl'
  # The applications are compiled whole with those they declare (ErlangBuild), erx among
  # them; the stand-ins below replace the erx modules the grant and the mint call. The grammar is generated into
  # the preloaded sources of OTP, outside the applications, so it is compiled with the cases.
  APPLICATIONS = %w[erx_files erx_storage].freeze
  TESTS = [GRAMMAR] + %w[
    test/erlang/erx_fs_test_tree.erl
    test/erlang/erx_fs_stale_tree.erl
    test/erlang/erx_fs_stream_tree.erl
    test/erlang/erx_fs_tests.erl
    test/erlang/erx_fs_core_model_tests.erl
    test/erlang/erx_fs_version_tests.erl
    test/erlang/erx_fs_waits_tests.erl
    test/erlang/erx_fs_mint_tests.erl
    test/erlang/stand_in/erx_dist.erl
    test/erlang/stand_in/erx_connections.erl
  ].freeze
  GRANT = 'erlang/apps/erx_files/src/erx_fs_grant.erl'
  SERVER = 'erlang/apps/erx_files/src/erx_fs.erl'
  MINT = 'erlang/apps/erx_files/src/erx_fs_mint.erl'
  VERSION = 'erlang/apps/erx_files/src/erx_fs_version.erl'
  WAITS = 'erlang/apps/erx/src/erx_fs_waits.erl'
  STREAM = 'test/erlang/erx_fs_stream_tree.erl'
  TABLE = 'abi/protocols/9p.txt'

  Fault = Data.define(:name, :file, :from, :to, :caught_by)

  # Each fault replaces one passage of one source; the test named in caught_by must fail.
  FAULTS = [
    Fault.new(name: "an lopen with O_DIRECTORY that opens a file", file: GRANT,
              from: 'when Flags band ?ERX_P9_O_DIRECTORY =/= 0, Type band ?ERX_P9_QTDIR =:= 0 ->',
              to: 'when Flags band ?ERX_P9_O_DIRECTORY =:= -1, Type band ?ERX_P9_QTDIR =:= 0 ->',
              caught_by: 'lopen_with_directory_opens_only_a_directory_test'),
    Fault.new(name: "a mkdir's Owner is replaced by the grant", file: GRANT,
              from: 'make(Dfid, Name, {directory, Mode band 8#7777, Owner}, Grant);',
              to: 'make(Dfid, Name, {directory, Mode band 8#7777, self()}, Grant);',
              caught_by: 'mkdir_carries_the_requests_owner_test'),
    Fault.new(name: 'a walk of .. at the root asks the tree', file: GRANT,
              from: "walk_step(<<\"..\">>, [_] = Root, Grant) ->\n    {ok, Root, Grant};",
              to: "walk_step(<<\"..\">>, [{Dir, _, _}] = Root, #grant{module = M, fs = T} = Grant) ->\n" \
                  "    {ok, _, Qid} = M:walk(Dir, <<\"..\">>, T),\n    {ok, [{Dir, Qid, root} | Root], Grant};",
              caught_by: 'dotdot_stays_at_the_root_test'),
    Fault.new(name: "a walk from NOFID starts at the tree's top, not the grant's root", file: GRANT,
              from: "walk_start(?ERX_P9_NOFID, #grant{root = Root}) ->\n    {ok, [Root]};",
              to: "walk_start(?ERX_P9_NOFID, #grant{root = _}) ->\n    {ok, [{1, {16#80, 0, 1}, root}]};",
              caught_by: 'nofid_walk_stays_within_the_grants_root_test'),
    Fault.new(name: 'a walk from NOFID looks for a fid and finds none', file: GRANT,
              from: "walk_start(?ERX_P9_NOFID, #grant{root = Root}) ->\n    {ok, [Root]};",
              to: "walk_start(?ERX_P9_NOFID, #grant{root = _}) ->\n    {error, ebadf};",
              caught_by: 'nofid_walk_starts_at_the_grants_root_test'),
    Fault.new(name: 'a start that skips its check of root', file: GRANT,
              from: "    case erx_9p_grammar:is_name(Tree) andalso erx_9p_grammar:is_qid(Qid)\n" \
                    "        andalso Type band ?ERX_P9_QTDIR =/= 0 of",
              to: '    case is_binary(Tree) orelse Qid =:= Type of',
              caught_by: 'a_root_that_is_no_directory_fails_the_start_test'),
    Fault.new(name: 'an attach that answers the qid the start admitted', file: GRANT,
              from: "                {ok, Tree, _, {Type, _, Path} = Qid} ->\n",
              to: "                {ok, Tree, _, {Type, _, Path}} ->\n                    Qid = {Type, 0, Path},\n",
              caught_by: 'attach_carries_the_roots_version_and_nothing_else_test'),
    Fault.new(name: 'a walk continues past a link', file: GRANT,
              from: 'when Type band ?ERX_P9_QTDIR =:= 0 ->', to: 'when Type band ?ERX_P9_QTDIR =:= -1 ->',
              caught_by: 'walk_through_a_link_stops_at_it_test'),
    Fault.new(name: "a reply goes to another domain's alias", file: GRANT,
              from: 'case {of_client(Alias, Client), of_client(Owner, Client)} of',
              to: 'case {is_reference(Alias), of_client(Owner, Client)} of',
              caught_by: 'replies_go_only_to_the_client_domain_test'),
    Fault.new(name: 'an owner of another domain is admitted', file: GRANT,
              from: "{true, false} ->\n                    {refuse, Alias, einval, none};\n                {true, true} ->",
              to: '{true, _} ->', caught_by: 'owner_outside_the_domain_is_refused_test'),
    Fault.new(name: "a frame in a third domain's envelope is taken", file: GRANT,
              from: "decode({erx_origin, _, _}, _) ->\n    drop;",
              to: "decode({erx_origin, _, Frame}, Grant) ->\n    decode_frame(Frame, Grant);",
              caught_by: 'frames_come_only_from_the_client_domain_test'),
    Fault.new(name: "a grant for another domain takes its own domain's bare frames", file: GRANT,
              from: "decode(_, _) ->\n    drop.", to: "decode(Frame, Grant) ->\n    decode_frame(Frame, Grant).",
              caught_by: 'frames_come_only_from_the_client_domain_test'),
    Fault.new(name: 'a fid in use is made again', file: GRANT,
              from: 'is_map_key(Fid, Fids) orelse is_map_key(Fid, Closing) -> {error, einval};',
              to: 'is_map_key(Fid, Closing) -> {error, einval};',
              caught_by: 'fid_in_use_is_refused_test'),
    Fault.new(name: 'the pool admits one fid more', file: GRANT,
              from: 'map_size(Fids) + map_size(Closing) >= Pool -> {error, emfile};', to: 'map_size(Fids) + map_size(Closing) > Pool -> {error, emfile};',
              caught_by: 'fid_flood_stops_at_the_pool_test'),
    Fault.new(name: "an owner's monitor stays after its last fid", file: GRANT,
              from: 'effects = [{demonitor, Ref} | Effects]}};',
              to: 'effects = element(2, {Ref, Effects})}};',
              caught_by: 'monitor_is_removed_at_the_last_fid_test'),
    Fault.new(name: 'an ended owner stays known, so its later fids go unmonitored', file: GRANT,
              from: 'Forgotten = drain(Grant#grant{owners = Rest, effects = [{demonitor, Ref} | Effects]}),',
              to: 'Forgotten = drain(Grant#grant{owners = Rest#{Owner => #owner{monitor = Ref, fids = #{}}},' \
                  ' effects = [{demonitor, Ref} | Effects]}),',
              caught_by: 'ended_owner_leaves_no_fid_test'),
    Fault.new(name: 'a walk that stops keeps its new fid', file: GRANT,
              from: "walked(_, _, _, {stopped, Qids, _, Grant}) ->\n    {{ok, lists:reverse(Qids)}, Grant};",
              to: "walked(Owner, _, NewFid, {stopped, Qids, _, Grant}) ->\n" \
                  "    {{ok, lists:reverse(Qids)}, add_fid(NewFid, Owner, [{1, {16#80, 0, 1}, root}], Grant)};",
              caught_by: 'fid_table_model_test_'),
    Fault.new(name: "a grant's report that shows the message that was being handled", file: SERVER,
              from: '    erx_report:status(Status, #{}).',
              to: '    erx_report:status(Status, #{message => keep}).',
              caught_by: 'a_grants_report_shows_no_term_test'),
    Fault.new(name: 'a grant is never exported', file: SERVER,
              from: '    case export(Client, maps:get(exports, Options, erx_dist)) of',
              to: '    case export(own, maps:get(exports, Options, erx_dist)) of',
              caught_by: 'the_export_comes_before_the_start_returns_test'),
    Fault.new(name: 'a refused export leaves the grant serving', file: SERVER,
              from: "        {error, _} = Refused ->\n            proc_lib:init_ack(Parent, Refused)\n",
              to: "        {error, _} = Refused ->\n" \
                  "            proc_lib:init_ack(Parent, element(1, {{ok, self()}, Refused})),\n" \
                  "            loop(Grant, ConnectionMonitor)\n",
              caught_by: 'a_refused_export_leaves_no_grant_test'),
    Fault.new(name: 'a grant outlives its connection', file: SERVER,
              from: '?MODULE:drain(perform(erx_fs_grant:client_ended(Grant)));',
              to: '?MODULE:loop(Grant, ConnectionMonitor);',
              caught_by: 'the_grant_ends_with_its_connection_test'),
    Fault.new(name: 'a grant that ends at once when its client ends', file: SERVER,
              from: '?MODULE:drain(perform(erx_fs_grant:client_ended(Grant)));',
              to: 'exit({shutdown, connection_ended});',
              caught_by: 'a_grant_whose_client_ended_drains_test'),
    Fault.new(name: 'a grant for its own domain ignores ends_with', file: SERVER,
              from: 'connection_monitor(_Client, #{ends_with := Process}) when is_pid(Process) ->',
              to: 'connection_monitor(Client, #{ends_with := Process}) when is_pid(Process), Client =/= own ->',
              caught_by: 'own_grant_ends_with_what_it_names_test'),
    Fault.new(name: "the mint takes a request outside the system domain's envelope", file: MINT,
              from: 'mint_request(System, Service, {erx_origin, System,',
              to: 'mint_request(_System, Service, {erx_origin, _Origin,',
              caught_by: 'only_the_system_domains_mint_request_is_granted_test'),
    Fault.new(name: 'a minted grant serves another domain than its grantee', file: MINT,
              from: '#{client => Grantee, principal => Principal,',
              to: '#{client => Grantee + 1, principal => Principal,',
              caught_by: 'an_enveloped_exchange_is_served_test'),
    Fault.new(name: "the mint ties no grantee's grant to its connection", file: MINT,
              from: 'connection_to(_System, Grantee) -> erx_connections:connection(Grantee).',
              to: 'connection_to(_System, _Grantee) -> {ok, none}.',
              caught_by: 'the_grant_ends_with_its_connection_test'),
    Fault.new(name: 'the in-flight bound admits one more', file: GRANT,
              from: "  when InFlight >= Max ->\n    finish(Alias, Request, {error, emfile}, Grant);",
              to: "  when InFlight > Max ->\n    finish(Alias, Request, {error, emfile}, Grant);",
              caught_by: 'a_window_of_waiting_reads_is_still_flushed_and_clunked_test'),
    Fault.new(name: 'an rx grant writes', file: GRANT,
              from: 'case Rights =:= rw orelse', to: 'case Rights =/= ro orelse',
              caught_by: 'read_only_grants_refuse_every_writing_operation_test_'),
    Fault.new(name: 'lcreate loses its writing mark', file: GRAMMAR,
              from: "writes({lcreate, _, _, _, _, _}) ->\n    true;",
              to: "writes({lcreate, _, _, _, _, _}) ->\n    false;",
              caught_by: 'lcreate_is_refused_whatever_its_flags_test'),
    Fault.new(name: 'a refused remove keeps its fid', file: GRANT,
              from: "        {refuse, Alias, Posix, {Ends, Fid} = Request} when Ends =:= clunk; Ends =:= remove ->\n" \
                    "            end_fid(Alias, Fid, Request, {error, Posix}, Grant);\n",
              to: '',
              caught_by: 'refused_remove_still_clunks_its_fid_test'),
    Fault.new(name: 'the version counter wraps', file: VERSION,
              from: "draw(_, ?LAST) ->\n    {error, eio};",
              to: "draw(Counter, ?LAST) ->\n    {ok, atomics:add_get(Counter, 1, 1)};",
            caught_by: 'the_last_value_is_drawn_once_then_refused_test'),
    Fault.new(name: 'lcreate answers eexist without O_EXCL', file: GRANT,
              from: 'What = {file, Mode band 8#7777, Flags},',
              to: 'What = {file, Mode band 8#7777, Flags bor 8#200},',
              caught_by: 'two_openers_of_one_new_name_both_succeed_test'),
    Fault.new(name: 'lcreate drops O_EXCL', file: GRANT,
              from: 'What = {file, Mode band 8#7777, Flags},',
              to: 'What = {file, Mode band 8#7777, Flags band bnot 8#200},',
              caught_by: 'lcreate_with_exclusive_answers_eexist_test'),
    Fault.new(name: 'a write answers the offset it was sent at', file: GRANT,
              from: 'may_wait(write, Module:write(Handle, Offset, Data, Fs));',
              to: 'may_wait(write, case Module:write(Handle, Offset, Data, Fs) of {ok, C, _} -> {ok, C, Offset}; O -> O end);',
              caught_by: 'append_answers_order_two_appenders_test'),
    Fault.new(name: 'a write answers its count and offset swapped', file: GRANT,
              from: 'shaped(write, {ok, Count, At}) -> {ok, Count, At};',
              to: 'shaped(write, {ok, Count, At}) -> {ok, At, Count};',
              caught_by: 'write_answers_where_it_wrote_test'),
    Fault.new(name: "a size change through an open goes by the node's permission", file: GRANT,
              from: '#{Fid := #fid{open = {open, _, _}}} -> on_open(Fid, Grant, fun(Handle) -> {setattr,',
              to: '#{Fid := #fid{open = {open, Node, _}}} when Node =:= none -> on_open(Fid, Grant, fun(Handle) -> {setattr,',
              caught_by: 'truncate_through_a_read_only_open_is_refused_test'),
    Fault.new(name: "an ended fid keeps its file open", file: GRANT,
              from: 'Closed = closed(Open, Grant1),',
              to: 'Closed = element(1, {ok, fun closed/2, Open}),',
              caught_by: 'owner_end_clunks_its_open_fids_test'),
    Fault.new(name: 'a listing is not fitted to its count', file: GRANT,
              from: '{ok, Entries} -> fit_listing(Entries, Count);',
              to: '{ok, Entries} -> element(2, {fun fit_listing/2, {ok, Entries}});',
              caught_by: 'readdir_over_an_open_directory_test'),
    Fault.new(name: 'a walk starts from an opened fid', file: GRANT,
              from: "        \#{Fid := #fid{open = {open, _, _}}} -> {error, einval};\n" \
                    '        #{Fid := #fid{path = Path}} -> {ok, Path};',
              to: "        \#{Fid := #fid{open = {open, _, _}}} when Fid < 0 -> {error, einval};\n" \
                  '        #{Fid := #fid{path = Path}} -> {ok, Path};',
              caught_by: 'readdir_over_an_open_directory_test'),
    Fault.new(name: 'remove takes whatever its name names now', file: GRANT,
              from: 'change(unlink, [Dir, Name, {node, Node}], Grant)',
              to: 'change(unlink, [Dir, Name, element(1, {any, Node})], Grant)',
              caught_by: 'remove_after_a_rename_leaves_the_new_name_test'),
    Fault.new(name: 'an alias in flight takes a second request', file: GRANT,
              from: "        {_, Alias, _, _} when is_map_key(Alias, Live) ->\n            dropped(Grant);\n",
              to: '',
              caught_by: 'an_alias_in_flight_takes_no_second_request_test'),
    Fault.new(name: "a grant that checks only requests' aliases", file: GRANT,
              from: '{_, Alias, _, _} when is_map_key(Alias, Live) ->',
              to: '{_, Alias, _, _} when is_map_key(Alias, Live), element(1, element(2, map_get(Alias, Live))) =:= held ->',
              caught_by: 'a_window_of_waiting_reads_is_still_flushed_and_clunked_test'),
    Fault.new(name: 'flushes counted in the window', file: GRANT,
              from: "window(_) -> 0.\n", to: "window({flush, _}) -> 1;\nwindow(_) -> 0.\n",
              caught_by: 'a_window_of_waiting_reads_is_still_flushed_and_clunked_test'),
    Fault.new(name: 'a flush of a flush waits behind it', file: GRANT,
              from: "        \#{Old := \#live{what = {flush, _}}} -> finish(Alias, Request, ok, Grant);\n", to: '',
              caught_by: 'a_flush_of_a_flush_is_answered_at_once_test'),
    Fault.new(name: 'a remove that never unlinks', file: GRANT,
              from: '#{Fid := #fid{path = Path}} -> end_fid(Alias, Fid, Request, unlinked(Path, Grant), Grant);',
              to: '#{Fid := #fid{path = Path}} -> end_fid(Alias, Fid, Request, element(1, {closed, Path}), Grant);',
              caught_by: 'a_remove_unlinks_when_it_is_admitted_test'),
    Fault.new(name: 'a second flush answered ok at once', file: GRANT,
              from: '#{Old := #live{}} -> dropped(Grant);', to: '#{Old := #live{}} -> finish(Alias, Request, ok, Grant);',
              caught_by: 'a_window_of_waiting_reads_is_still_flushed_and_clunked_test'),
    Fault.new(name: 'a grant that counts clunks in the window', file: GRANT,
              from: "admit(Alias, _, {clunk, Fid} = Request, Grant) ->\n",
              to: "admit(Alias, _, {clunk, _} = Request, \#grant{in_flight = InFlight, in_flight_max = Max} = Grant)\n" \
                  "  when InFlight >= Max ->\n" \
                  "    finish(Alias, Request, {error, emfile}, Grant);\n" \
                  "admit(Alias, _, {clunk, Fid} = Request, Grant) ->\n",
              caught_by: 'a_window_of_waiting_reads_is_still_flushed_and_clunked_test'),
    Fault.new(name: 'a grant that runs the clunk while the read still waits', file: GRANT,
              from: "                [] ->\n                    run_clunk(Fid, Ending, Grant1);",
              to: "                _ ->\n                    run_clunk(Fid, Ending, Grant1);",
              caught_by: 'a_clunk_of_a_waiting_read_is_answered_after_its_eintr_test'),
    Fault.new(name: 'a grant that answers a flush of a waiting clunk at once', file: GRANT,
              from: 'flush_waits(Alias, Old, Entry, #grant{aliases = Live} = Grant) ->',
              to: "flush_waits(Alias, Old, \#live{what = ending}, Grant) ->\n    finish(Alias, {flush, Old}, ok, Grant);\n" \
                  'flush_waits(Alias, Old, Entry, #grant{aliases = Live} = Grant) ->',
              caught_by: 'every_order_of_the_events_keeps_the_waiting_rules_test_'),
    Fault.new(name: "a grant that frees a fid's number when it takes the clunk", file: GRANT,
              from: 'is_map_key(Fid, Fids) orelse is_map_key(Fid, Closing) -> {error, einval};',
              to: 'is_map_key(Fid, Fids) -> {error, einval};',
              caught_by: 'every_order_of_the_events_keeps_the_waiting_rules_test_'),
    Fault.new(name: "a grant that answers a flush before the keeper's answer", file: GRANT,
              from: '#{Old := #live{flush = none} = Entry} -> flush_waits(Alias, Old, Entry, Grant);',
              to: '#{Old := #live{flush = none, what = #held{}}} -> ' \
                  'then(drain(flush_at_keeper(Old, Grant)), fun(G) -> finish(Alias, Request, ok, G) end);' \
                  "\n        \#{Old := \#live{flush = none} = Entry} -> flush_waits(Alias, Old, Entry, Grant);",
              caught_by: 'every_order_of_the_events_keeps_the_waiting_rules_test_'),
    Fault.new(name: "a clunk that runs without flushing its fid's waits", file: GRANT,
              from: "drain(lists:foldl(fun flush_at_keeper/2,\n",
              to: "drain(lists:foldl(fun(_, G) -> G end,\n",
              caught_by: 'every_order_of_the_events_keeps_the_waiting_rules_test_'),
    Fault.new(name: 'a grant that keys waits by handle', file: GRANT,
              from: '<- Live, Of =:= Fid],', to: '<- Live, is_integer(Of)],',
              caught_by: 'every_order_of_the_events_keeps_the_waiting_rules_test_'),
    Fault.new(name: 'a grant that takes no other frame while a clunk waits', file: GRANT,
              from: "        {admit, Alias, Owner, Request} ->\n            admit(Alias, Owner, Request, Grant)\n",
              to: "        {admit, Alias, _, Request} when map_size(Grant\#grant.closing) > 0 ->\n" \
                  "            finish(Alias, Request, {error, eagain}, Grant);\n" \
                  "        {admit, Alias, Owner, Request} ->\n            admit(Alias, Owner, Request, Grant)\n",
              caught_by: 'every_order_of_the_events_keeps_the_waiting_rules_test_'),
    Fault.new(name: 'a stream tree whose read waits inside its callback', file: STREAM,
              from: "read({stream, _}, _Offset, Count, Keeper) ->\n    {wait, Keeper, {read, Count}};",
              to: "read({stream, _}, _Offset, _Count, _Keeper) ->\n    receive after 3000 -> {error, eintr} end;",
              caught_by: 'a_write_is_answered_while_a_read_waits_test'),
    Fault.new(name: "a keeper's end that answers nothing", file: GRANT,
              from: "{\#{Ref := \#live{what = {keeper, ClientAlias}}}, _} ->\n            settle_held(Ref, ClientAlias, {error, eio}, Grant);",
              to: "{\#{Ref := \#live{what = {keeper, _}}}, _} ->\n            {[], Grant};",
              caught_by: 'a_keepers_end_answers_its_reads_eio_test'),
    Fault.new(name: 'a flush of a waiting request that stays in the grant', file: GRANT,
              from: 'effects = [{flush, Keeper, KeeperAlias} | Effects]};',
              to: 'effects = element(1, {Effects, Keeper, KeeperAlias})};',
              caught_by: 'a_flush_of_a_waiting_read_reaches_its_keeper_test'),
    Fault.new(name: 'a keeper that is the grant itself', file: GRANT,
              from: 'when is_pid(Keeper), node(Keeper) =:= node(), Keeper =/= Self ->',
              to: 'when is_pid(Keeper), node(Keeper) =:= node(), Self =/= none ->',
              caught_by: 'a_keeper_that_is_the_grant_is_eio_test'),
    Fault.new(name: "a directory's make answering a next state is taken for a file's", file: GRANT,
              from: 'changed(make, Other) -> failed(Other);',
              to: "changed(make, {ok, Node, Qid, _}) -> {ok, Node, Qid};\nchanged(make, Other) -> failed(Other);",
              caught_by: 'answers_with_a_state_are_eio_in_the_grant_test'),
    Fault.new(name: 'a malformed answer crashes the grant', file: GRANT,
              from: 'failed(_) -> {error, eio}.',
              to: 'failed(Other) when element(1, Other) =:= error -> {error, eio}.',
              caught_by: 'answers_with_a_state_are_eio_in_the_grant_test'),
    Fault.new(name: 'a reply the grammar rejects keeps the grant its operation built', file: GRANT,
              from: 'false -> {{error, eio}, kept_when_rejected(Request, Built, Before)}',
              to: 'false -> {{error, eio}, element(1, {Built, kept_when_rejected(Request, Built, Before)})}',
              caught_by: 'malformed_qids_change_nothing_test'),
    Fault.new(name: "a rejected lcreate leaves the tree's handle open", file: GRANT,
              from: "                            _ = Module:clunk(Handle, Fs),\n" \
                    '                            {{error, eio}, Grant}',
              to: '                            {{error, eio}, element(2, {Handle, Grant})}',
              caught_by: 'malformed_qids_leave_the_grant_serving_test'),
    Fault.new(name: 'a listing with an improper tail crashes the grant', file: GRANT,
              from: '    case entries(Entries) of',
              to: '    case is_list(Entries) andalso lists:all(fun(Entry) -> entries([Entry]) end, Entries) of',
              caught_by: 'improper_listing_is_eio_test'),
    Fault.new(name: "a rename's new directory may be a file", file: TABLE,
              from: "    request new_dir_fid fid directory\n", to: "    request new_dir_fid fid node\n",
              caught_by: 'directory_operations_on_a_file_or_a_link_reach_no_tree_test'),
    Fault.new(name: "a link's checked fid is its source, not its directory", file: TABLE,
              from: "  operation link 70\n    request dfid fid directory\n    request fid fid node\n",
              to: "  operation link 70\n    request dfid fid node\n    request fid fid directory\n",
              caught_by: 'directory_operations_on_a_file_or_a_link_reach_no_tree_test'),
    Fault.new(name: 'a file opened is listed by the tree', file: TABLE,
              from: "  operation readdir 40\n    request fid fid directory\n",
              to: "  operation readdir 40\n    request fid fid node\n",
              caught_by: 'directory_operations_on_a_file_or_a_link_reach_no_tree_test'),
    Fault.new(name: 'an answer/3 that leaves its entry', file: WAITS,
              from: "erlang:send(Alias, ?ERX_FS_ANSWER(Alias, Result)),\n            forget(Wait, Waits);",
              to: "erlang:send(Alias, ?ERX_FS_ANSWER(Alias, Result)),\n            Waits;",
              caught_by: 'a_keeper_that_answers_a_thousand_reads_holds_nothing_test'),
    Fault.new(name: 'a set that does not monitor the grant', file: WAITS,
              from: '#{} -> {erlang:monitor(process, Grant), #{}}',
              to: '#{} -> {make_ref(), #{}}',
              caught_by: 'a_grants_end_drops_its_requests_test')
  ].freeze

  def test_the_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, fault.file))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit(replacements(fault.file, original.sub(fault.from) { fault.to }))
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      # EUnit's verbose line for one test: its name, then its verdict on the same line.
      assert_match(/#{Regexp.escape(fault.caught_by)}[^\n]*\*(?:failed|timed out)\*/, output, fault.name)
    end
  end

  private

  # The sources a fault replaces: the file itself, or for the protocol table the grammar
  # generated from it in a scratch copy of abi/.
  def replacements(file, text)
    return { file => text } unless file == TABLE

    Dir.mktmpdir('erx-fs-table-') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      File.write(File.join(root, TABLE), text)
      schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
      # The generator names the grammar by its path beneath build/gen.
      { GRAMMAR => Erx::ABI::ProtocolEmitter.outputs(schema).fetch(GRAMMAR.delete_prefix("#{Erx::Generated::OUTPUT}/")) }
    end
  end

  # Compiles the applications and the cases, with any source replaced by the given text, and runs the suites.
  def eunit(replaced)
    Dir.mktmpdir('erx-fs-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      # A grant a seeded fault crashes would print a crash report into the middle of
      # EUnit's line for its test; the logger stays quiet so each verdict keeps its line.
      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'logger:set_primary_config(level, none), ' \
                      'halt(case eunit:test([erx_fs_tests, erx_fs_core_model_tests, erx_fs_version_tests, erx_fs_waits_tests, erx_fs_mint_tests], [verbose]) ' \
                      'of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
