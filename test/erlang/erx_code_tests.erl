%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_code, the code service, loading real modules into the emulator that
%% runs the tests: the missing-blob exchange end to end, a blob one bit off its hash, a
%% batch with one bad module, a module whose name differs from its bytes', a stored blob
%% whose bytes changed, reloads that purge old code, a rollback, and the requests the
%% service refuses. Each module is compiled here, returning its version from version/0,
%% so what runs is observed by calling it. erx_bytes is the host stand-in
%% (test/erlang/host_bytes).

-module(erx_code_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A, erx_code_tests_target_a).
-define(B, erx_code_tests_target_b).

service_test_() ->
    {foreach, fun start/0, fun stop/1,
     [fun the_exchange_sends_only_missing_blobs_and_loads_them/0,
      fun a_blob_one_bit_off_its_hash_never_loads/0,
      fun a_batch_with_one_bad_module_changes_no_module/0,
      fun a_module_whose_name_differs_from_its_bytes_never_loads/0,
      fun a_batch_the_code_server_refuses_purges_nothing/0,
      fun a_module_with_an_on_load_function_never_loads/0,
      fun a_stored_blob_whose_bytes_changed_never_loads/0,
      fun reloads_purge_old_code_and_a_rollback_loads_an_older_hash/0,
      fun refused_requests_change_nothing/0]}.

start() ->
    _ = [unload(Module) || Module <- [?A, ?B]],
    {ok, Pid} = erx_code:start_link(#{limit => 1 bsl 20}),
    unlink(Pid),
    Pid.

stop(Pid) ->
    gen_server:stop(Pid),
    _ = [unload(Module) || Module <- [?A, ?B]],
    ok.

unload(Module) ->
    _ = code:purge(Module),
    _ = code:delete(Module),
    _ = code:purge(Module),
    ok.

%% A module whose version/0 returns Version and whose wait/0 waits for a message, so a
%% process can stay in one version's code.
beam(Module, Version) ->
    beam(Module, Version, []).

beam(Module, Version, Attributes) ->
    Forms = [{attribute, 1, module, Module},
             {attribute, 2, export, [{version, 0}, {wait, 0}]}]
        ++ Attributes
        ++ [{function, 3, version, 0, [{clause, 3, [], [], [{integer, 3, Version}]}]},
            {function, 4, wait, 0, [{clause, 4, [], [], [{'receive', 4, [{clause, 4, [{atom, 4, stop}], [], [{atom, 4, ok}]}]}]}]}],
    {ok, Module, Bytes} = compile:forms(Forms, [binary]),
    Bytes.

%% A process waiting in the code of Module's version current now.
waiting(Module) ->
    spawn(Module, wait, []).

hash(Bytes) -> crypto:hash(sha256, Bytes).

name(Module) -> atom_to_binary(Module).

%% Sends a blob in pieces of 64 KiB, as the host does.
send(Bytes) ->
    send(hash(Bytes), Bytes, 0).

send(Hash, Bytes, Offset) ->
    Piece = binary:part(Bytes, Offset, min(65536, byte_size(Bytes) - Offset)),
    case erx_code:put_piece(Hash, byte_size(Bytes), Offset, Piece) of
        {ok, {next, Next}} -> send(Hash, Bytes, Next);
        Reply -> Reply
    end.

version(Module) ->
    Module:version().

the_exchange_sends_only_missing_blobs_and_loads_them() ->
    One = beam(?A, 1),
    Two = beam(?B, 2),
    {ok, stored} = send(One),
    ?assertEqual({ok, [hash(Two)]}, erx_code:missing([hash(One), hash(Two)])),
    ?assertEqual({ok, stored}, send(Two)),
    ?assertEqual({ok, []}, erx_code:missing([hash(One), hash(Two)])),
    ?assertEqual(ok, erx_code:load([{name(?A), hash(One)}, {name(?B), hash(Two)}])),
    ?assertEqual({1, 2}, {version(?A), version(?B)}),
    ?assertMatch({ok, [{<<_:256>>, _}]}, erx_code:history(4, ?A)),
    {ok, [{Hash, _Time}]} = erx_code:history(4, name(?A)),
    ?assertEqual(hash(One), Hash),
    ?assertEqual(binary_to_list(binary:encode_hex(hash(One), lowercase)) ++ ".beam", code:which(?A)).

a_blob_one_bit_off_its_hash_never_loads() ->
    One = beam(?A, 1),
    <<First, Rest/binary>> = beam(?A, 2),
    Wrong = <<(First bxor 16#80), Rest/binary>>,
    Named = hash(<<First, Rest/binary>>),
    ok = load_one(?A, One),
    ?assertEqual({error, hash_mismatch}, send(Named, Wrong, 0)),
    ?assertEqual({error, {missing, [Named]}}, erx_code:load([{name(?A), Named}])),
    ?assertEqual(1, version(?A)),
    ?assertEqual(1, length(element(2, erx_code:history(4, ?A)))).

a_batch_with_one_bad_module_changes_no_module() ->
    ok = load_one(?A, beam(?A, 0)),
    Waiting = waiting(?A),
    ok = load_one(?A, beam(?A, 1)),
    ok = load_one(?B, beam(?B, 1)),
    Good = beam(?A, 2),
    Bad = <<"FOR1 not a module">>,
    {ok, stored} = send(Good),
    {ok, stored} = send(Bad),
    ?assertEqual({error, {not_loaded, [{name(?B), badfile}]}},
                 erx_code:load([{name(?A), hash(Good)}, {name(?B), hash(Bad)}])),
    ?assertEqual({1, 1}, {version(?A), version(?B)}),
    ?assert(erlang:check_old_code(?A)),
    ?assert(is_process_alive(Waiting)),
    ?assertEqual(2, length(element(2, erx_code:history(4, ?A)))).

%% The code server refuses a preloaded module, which is sticky, only once the batch is
%% prepared; the old code of the batch's other module, and the process in it, stay.
a_batch_the_code_server_refuses_purges_nothing() ->
    ok = load_one(?A, beam(?A, 0)),
    Waiting = waiting(?A),
    ok = load_one(?A, beam(?A, 1)),
    Two = beam(?A, 2),
    Sticky = beam(erl_prim_loader, 1),
    {ok, stored} = send(Two),
    {ok, stored} = send(Sticky),
    ?assertEqual({error, {not_loaded, [{<<"erl_prim_loader">>, sticky_directory}]}},
                 erx_code:load([{name(?A), hash(Two)}, {<<"erl_prim_loader">>, hash(Sticky)}])),
    ?assertEqual(1, version(?A)),
    ?assert(erlang:check_old_code(?A)),
    ?assert(is_process_alive(Waiting)).

a_module_with_an_on_load_function_never_loads() ->
    OnLoad = beam(?A, 1, [{attribute, 2, on_load, {version, 0}}]),
    {ok, stored} = send(OnLoad),
    ?assertEqual({error, {not_loaded, [{name(?A), on_load_not_allowed}]}}, erx_code:load([{name(?A), hash(OnLoad)}])),
    ?assertEqual(false, code:is_loaded(?A)).

a_module_whose_name_differs_from_its_bytes_never_loads() ->
    Bytes = beam(?A, 1),
    {ok, stored} = send(Bytes),
    ?assertEqual({error, {not_loaded, [{name(?B), badfile}]}}, erx_code:load([{name(?B), hash(Bytes)}])),
    ?assertEqual(false, code:is_loaded(?B)),
    ?assertEqual({ok, []}, erx_code:history(4, ?B)).

a_stored_blob_whose_bytes_changed_never_loads() ->
    ok = load_one(?A, beam(?A, 1)),
    Two = beam(?A, 2),
    {ok, stored} = send(Two),
    %% The store's memory changed after the blob was checked in.
    sys:replace_state(erx_code, fun(#{blobs := Blobs} = Store) ->
                                        <<First, Rest/binary>> = map_get(hash(Two), Blobs),
                                        Store#{blobs := Blobs#{hash(Two) := <<(First bxor 1), Rest/binary>>}}
                                end),
    ?assertEqual({error, {hash_mismatch, name(?A)}}, erx_code:load([{name(?A), hash(Two)}])),
    ?assertEqual(1, version(?A)).

reloads_purge_old_code_and_a_rollback_loads_an_older_hash() ->
    Versions = [beam(?A, Version) || Version <- lists:seq(1, 5)],
    [?assertEqual(ok, load_one(?A, Bytes)) || Bytes <- Versions],
    ?assertEqual(5, version(?A)),
    {ok, History} = erx_code:history(4, ?A),
    ?assertEqual(lists:reverse([hash(Bytes) || Bytes <- Versions]), [Hash || {Hash, _Time} <- History]),
    ?assertEqual({ok, []}, erx_code:missing([hash(hd(Versions))])),
    ?assertEqual(ok, erx_code:load([{name(?A), hash(hd(Versions))}])),
    ?assertEqual(1, version(?A)).

refused_requests_change_nothing() ->
    ok = load_one(?A, beam(?A, 1)),
    ?assertEqual({error, bad_request}, erx_code:call({load})),
    ?assertEqual({error, bad_request}, erx_code:call(make_ref())),
    ?assertEqual({error, {bad_manifest, {bad_entry, 1}}}, erx_code:load([{<<"no such/module">>, hash(<<>>)}])),
    ?assertEqual({error, scope}, erx_code:history(5, ?A)),
    ?assertEqual(1, version(?A)).

load_one(Module, Bytes) ->
    {ok, stored} = send(Bytes),
    erx_code:load([{name(Module), hash(Bytes)}]).
