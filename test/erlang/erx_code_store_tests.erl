%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_code_store, the code store's pure core: the reader of requests and
%% manifests, the missing-blob exchange, uploads in pieces and their refusals, the store's
%% limit, load plans, and the 16-entry history. erx_bytes is the host stand-in
%% (test/erlang/host_bytes), whose sha256/1 is stock's crypto:hash/2.

-module(erx_code_store_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PIECE, 65536).

hash(Bytes) -> crypto:hash(sha256, Bytes).

%% N random bytes, distinct from every other call's only for N of eight or more.
bytes(N) -> crypto:strong_rand_bytes(N).

flip_bit(<<Byte, Rest/binary>>) -> <<(Byte bxor 1), Rest/binary>>.

%% The store after Bytes arrive in pieces of at most 64 KiB, with every answer checked.
stored(Store, Bytes) ->
    Hash = hash(Bytes),
    Size = byte_size(Bytes),
    lists:foldl(fun(Offset, Acc) ->
                        Piece = binary:part(Bytes, Offset, min(?PIECE, Size - Offset)),
                        Expected = case Offset + byte_size(Piece) of
                                       Size -> stored;
                                       Next -> {next, Next}
                                   end,
                        {ok, Expected, Next1} = erx_code_store:put_piece(Acc, Hash, Size, Offset, Piece),
                        Next1
                end, Store, lists:seq(0, Size - 1, ?PIECE)).

%% Uploads

a_blob_in_one_piece_is_stored_and_no_longer_missing_test() ->
    Bytes = bytes(100),
    Hash = hash(Bytes),
    Empty = erx_code_store:new(1 bsl 20),
    ?assertEqual([Hash], erx_code_store:missing(Empty, [Hash, Hash])),
    Store = stored(Empty, Bytes),
    ?assertEqual([], erx_code_store:missing(Store, [Hash])).

a_blob_in_pieces_is_stored_once_its_last_byte_arrives_test() ->
    Bytes = bytes(2 * ?PIECE + 7),
    Store = stored(erx_code_store:new(1 bsl 20), Bytes),
    ?assertEqual({ok, [{<<"m">>, hash(Bytes), Bytes}]}, erx_code_store:plan_load(Store, [{<<"m">>, hash(Bytes)}])).

a_blob_one_bit_off_its_hash_is_never_stored_test() ->
    Bytes = bytes(?PIECE + 1),
    Hash = hash(Bytes),
    Wrong = flip_bit(Bytes),
    Empty = erx_code_store:new(1 bsl 20),
    {ok, {next, ?PIECE}, Started} = erx_code_store:put_piece(Empty, Hash, byte_size(Wrong), 0,
                                                             binary:part(Wrong, 0, ?PIECE)),
    {error, hash_mismatch, After} = erx_code_store:put_piece(Started, Hash, byte_size(Wrong), ?PIECE,
                                                             binary:part(Wrong, ?PIECE, 1)),
    ?assertEqual([Hash], erx_code_store:missing(After, [Hash])),
    ?assertEqual({error, {missing, [Hash]}}, erx_code_store:plan_load(After, [{<<"m">>, Hash}])),
    %% The upload is gone with the bytes it promised: the whole limit is free again.
    ?assertEqual({error, {expected, 0}, After}, erx_code_store:put_piece(After, Hash, byte_size(Wrong), ?PIECE, <<0>>)),
    Full = bytes(1 bsl 20),
    ?assertMatch({ok, {next, _}, _}, erx_code_store:put_piece(After, hash(Full), 1 bsl 20, 0, bytes(?PIECE))).

a_piece_out_of_order_names_the_offset_the_store_waits_for_test() ->
    Bytes = bytes(3 * ?PIECE),
    Hash = hash(Bytes),
    Size = byte_size(Bytes),
    Piece = fun(Index) -> binary:part(Bytes, Index * ?PIECE, ?PIECE) end,
    Empty = erx_code_store:new(1 bsl 20),
    ?assertEqual({error, {expected, 0}, Empty}, erx_code_store:put_piece(Empty, Hash, Size, ?PIECE, Piece(1))),
    {ok, {next, ?PIECE}, One} = erx_code_store:put_piece(Empty, Hash, Size, 0, Piece(0)),
    ?assertEqual({error, {expected, ?PIECE}, One}, erx_code_store:put_piece(One, Hash, Size, 2 * ?PIECE, Piece(2))),
    ?assertEqual({error, size_mismatch, One}, erx_code_store:put_piece(One, Hash, Size + 1, ?PIECE, Piece(1))),
    {ok, {next, _}, Two} = erx_code_store:put_piece(One, Hash, Size, ?PIECE, Piece(1)),
    ?assertMatch({ok, stored, _}, erx_code_store:put_piece(Two, Hash, Size, 2 * ?PIECE, Piece(2))).

a_piece_at_offset_zero_starts_the_blob_again_test() ->
    Bytes = bytes(2 * ?PIECE),
    Hash = hash(Bytes),
    Empty = erx_code_store:new(1 bsl 20),
    {ok, {next, _}, Partial} = erx_code_store:put_piece(Empty, Hash, 2 * ?PIECE, 0, bytes(?PIECE)),
    ?assertEqual(stored(Empty, Bytes), stored(Partial, Bytes)).

a_piece_past_the_blobs_end_or_short_of_a_whole_piece_is_refused_test() ->
    Empty = erx_code_store:new(1 bsl 20),
    Hash = hash(<<"x">>),
    ?assertEqual({error, bad_piece, Empty}, erx_code_store:put_piece(Empty, Hash, 1, 0, <<"xy">>)),
    ?assertEqual({error, bad_piece, Empty}, erx_code_store:put_piece(Empty, Hash, ?PIECE + 1, 0, <<"x">>)),
    ?assertEqual({error, bad_piece, Empty}, erx_code_store:put_piece(Empty, Hash, ?PIECE, ?PIECE, <<"x">>)),
    {ok, {next, ?PIECE}, Started} = erx_code_store:put_piece(Empty, Hash, ?PIECE + 2, 0, bytes(?PIECE)),
    ?assertEqual({error, bad_piece, Started}, erx_code_store:put_piece(Started, Hash, ?PIECE + 2, ?PIECE, <<"x">>)).

a_stored_blob_answers_stored_at_once_test() ->
    Bytes = bytes(10),
    Store = stored(erx_code_store:new(1 bsl 20), Bytes),
    ?assertEqual({ok, stored, Store}, erx_code_store:put_piece(Store, hash(Bytes), 10, 5, <<"z">>)).

a_fifth_upload_drops_the_oldest_test() ->
    Blobs = [bytes(2 * ?PIECE) || _ <- lists:seq(1, 5)],
    Started = lists:foldl(fun(Bytes, Acc) ->
                                  {ok, {next, _}, Next} = erx_code_store:put_piece(Acc, hash(Bytes), 2 * ?PIECE, 0,
                                                                                   binary:part(Bytes, 0, ?PIECE)),
                                  Next
                          end, erx_code_store:new(1 bsl 20), Blobs),
    [First, Second | _] = Blobs,
    ?assertMatch({error, {expected, 0}, _},
                 erx_code_store:put_piece(Started, hash(First), 2 * ?PIECE, ?PIECE, binary:part(First, ?PIECE, ?PIECE))),
    ?assertMatch({ok, stored, _},
                 erx_code_store:put_piece(Started, hash(Second), 2 * ?PIECE, ?PIECE, binary:part(Second, ?PIECE, ?PIECE))).

%% The limit

a_blob_larger_than_the_store_is_refused_test() ->
    Empty = erx_code_store:new(100),
    ?assertEqual({error, too_large, Empty}, erx_code_store:put_piece(Empty, hash(<<"a">>), 101, 0, bytes(101))).

%% The two uploads have fixed, distinct names: an upload of a name already in progress
%% restarts it rather than competing with it for room.
an_upload_promises_its_whole_size_against_the_limit_test() ->
    Empty = erx_code_store:new(2 * ?PIECE),
    {ok, {next, ?PIECE}, Started} = erx_code_store:put_piece(Empty, hash(<<"first">>), ?PIECE + 1, 0, bytes(?PIECE)),
    ?assertEqual({error, store_full, Started},
                 erx_code_store:put_piece(Started, hash(<<"second">>), ?PIECE, 0, bytes(?PIECE))),
    ?assertMatch({ok, stored, _}, erx_code_store:put_piece(Started, hash(<<"b">>), 1, 0, <<"b">>)).

%% Loaded once, so its history names it.
loaded(Store, Name, Bytes, Time) ->
    erx_code_store:commit(stored(Store, Bytes), [{Name, hash(Bytes), Bytes}], Time).

a_full_store_frees_old_versions_then_unnamed_blobs_never_current_ones_test() ->
    [Old, Current, Unnamed, Other] = [bytes(25) || _ <- lists:seq(1, 4)],
    Store = stored(loaded(loaded(loaded(erx_code_store:new(100), <<"m">>, Old, 1), <<"m">>, Current, 2),
                          <<"n">>, Other, 3), Unnamed),
    Hashes = [hash(Bytes) || Bytes <- [Old, Current, Unnamed, Other]],
    {ok, stored, FreedOld} = erx_code_store:put_piece(Store, hash(<<"a">>), 1, 0, <<"a">>),
    ?assertEqual([hash(Old)], erx_code_store:missing(FreedOld, Hashes)),
    ?assertEqual([hash(Current), hash(Old)], [Hash || {Hash, _} <- erx_code_store:history(FreedOld, <<"m">>)]),
    Big = bytes(26),
    {ok, stored, FreedUnnamed} = erx_code_store:put_piece(FreedOld, hash(Big), 26, 0, Big),
    ?assertEqual([hash(Old), hash(Unnamed)], erx_code_store:missing(FreedUnnamed, Hashes)),
    ?assertEqual({error, store_full, FreedUnnamed},
                 erx_code_store:put_piece(FreedUnnamed, hash(<<"c">>), 51, 0, bytes(51))).

a_refused_upload_drops_no_upload_and_frees_no_blob_test() ->
    Started = started(erx_code_store:new(?PIECE + 10), <<"u">>, ?PIECE + 1),
    ?assertEqual({error, too_large, Started}, erx_code_store:put_piece(Started, hash(<<"u">>), ?PIECE + 11, 0, bytes(?PIECE))),
    Store = stored(loaded(erx_code_store:new(100), <<"m">>, bytes(50), 1), bytes(40)),
    ?assertEqual({error, store_full, Store}, erx_code_store:put_piece(Store, hash(<<"v">>), 51, 0, bytes(51))),
    Busy = lists:foldl(fun(Index, Acc) -> started(Acc, <<Index>>, ?PIECE + 1) end,
                       erx_code_store:new(4 * (?PIECE + 1) + 10), lists:seq(1, 4)),
    ?assertEqual({error, store_full, Busy}, erx_code_store:put_piece(Busy, hash(<<"w">>), ?PIECE + 12, 0, bytes(?PIECE))).

%% The store with an upload of Size bytes under the hash of Seed begun.
started(Store, Seed, Size) ->
    {ok, {next, ?PIECE}, Started} = erx_code_store:put_piece(Store, hash(Seed), Size, 0, bytes(?PIECE)),
    Started.

reloading_modules_near_the_limit_never_fills_the_store_test() ->
    Limit = 1 bsl 20,
    Modules = [<<"a">>, <<"b">>, <<"c">>],
    Reload = fun(Round, Acc) ->
                     Blobs = [{Name, bytes(Limit div 8)} || Name <- Modules],
                     Sent = lists:foldl(fun({_Name, Bytes}, In) -> stored(In, Bytes) end, Acc, Blobs),
                     {ok, Plan} = erx_code_store:plan_load(Sent, [{Name, hash(Bytes)} || {Name, Bytes} <- Blobs]),
                     erx_code_store:commit(Sent, Plan, Round)
             end,
    Store = lists:foldl(Reload, erx_code_store:new(Limit), lists:seq(1, 20)),
    ?assertEqual(16, length(erx_code_store:history(Store, <<"a">>))).

%% Random puts and loads on a small store, checking after every step what the store must
%% keep true: the bytes it counts are its blobs' and its uploads' sizes, within its limit;
%% at most four uploads; every blob hashes to its name; every module's current blob held.
random_puts_and_loads_keep_the_stores_accounting_test() ->
    rand:seed(exsss, {20, 26, 11}),
    Blobs = [rand:bytes(Size) || Size <- [1, 100, ?PIECE, ?PIECE + 1, 3 * ?PIECE, 4 * ?PIECE]],
    lists:foldl(fun(_Step, Store) -> check(step(Store, Blobs)) end, erx_code_store:new(6 * ?PIECE),
                lists:seq(1, 5000)).

step(Store, Blobs) ->
    Bytes = lists:nth(rand:uniform(length(Blobs)), Blobs),
    Size = byte_size(Bytes),
    case rand:uniform(4) of
        4 ->
            case erx_code_store:plan_load(Store, [{<<"m">>, hash(Bytes)}]) of
                {ok, Plan} -> erx_code_store:commit(Store, Plan, rand:uniform(1000));
                {error, {missing, _}} -> Store
            end;
        _ ->
            Offset = ?PIECE * (rand:uniform(Size div ?PIECE + 1) - 1),
            Piece = binary:part(Bytes, Offset, min(?PIECE, Size - Offset)),
            element(3, erx_code_store:put_piece(Store, hash(Bytes), Size, Offset, Piece))
    end.

check(#{limit := Limit, used := Used, blobs := Blobs, uploads := Uploads, history := History} = Store) ->
    Promised = lists:sum([element(3, Upload) || Upload <- Uploads]),
    ?assertEqual(Used, lists:sum([byte_size(Bytes) || Bytes <- maps:values(Blobs)]) + Promised),
    ?assert(Used =< Limit),
    ?assert(length(Uploads) =< 4),
    [?assertEqual(Hash, hash(Bytes)) || Hash := Bytes <- Blobs],
    [?assert(is_map_key(Hash, Blobs)) || [{Hash, _} | _] <- maps:values(History)],
    Store.

%% Loads and history

a_load_names_each_missing_hash_once_test() ->
    Here = bytes(10),
    Gone = hash(<<"gone">>),
    Store = stored(erx_code_store:new(1 bsl 20), Here),
    ?assertEqual({error, {missing, [Gone]}},
                 erx_code_store:plan_load(Store, [{<<"a">>, Gone}, {<<"b">>, hash(Here)}, {<<"c">>, Gone}])).

a_stored_blob_whose_bytes_changed_never_loads_test() ->
    Bytes = bytes(64),
    Hash = hash(Bytes),
    %% A store whose memory changed after the blob was checked in: the plan hashes it again.
    #{blobs := Blobs} = Store = stored(erx_code_store:new(1 bsl 20), Bytes),
    Changed = Store#{blobs := Blobs#{Hash := flip_bit(Bytes)}},
    ?assertEqual({error, {hash_mismatch, <<"m">>}}, erx_code_store:plan_load(Changed, [{<<"m">>, Hash}])).

the_history_keeps_the_sixteen_newest_loads_newest_first_test() ->
    Hashes = [hash(<<Index>>) || Index <- lists:seq(1, 20)],
    Store = lists:foldl(fun({Time, Hash}, Acc) -> erx_code_store:commit(Acc, [{<<"m">>, Hash, <<>>}], Time) end,
                        erx_code_store:new(1 bsl 20), lists:enumerate(Hashes)),
    Expected = lists:sublist(lists:reverse(lists:enumerate(Hashes)), 16),
    ?assertEqual([{Hash, Time} || {Time, Hash} <- Expected], erx_code_store:history(Store, <<"m">>)),
    ?assertEqual([], erx_code_store:history(Store, <<"other">>)).

%% The readers

requests_of_every_shape_are_read_or_refused_test() ->
    Hash = hash(<<"h">>),
    Manifest = [{<<"erx_mod">>, Hash}],
    ?assertEqual({ok, {missing, [Hash]}}, erx_code_store:read_request({missing, [Hash]})),
    ?assertEqual({ok, {put, Hash, 2, 0, <<"ab">>}}, erx_code_store:read_request({put, Hash, 2, 0, <<"ab">>})),
    ?assertEqual({ok, {load, Manifest}}, erx_code_store:read_request({load, Manifest})),
    ?assertEqual({ok, {history, 4, <<"erx_mod">>}}, erx_code_store:read_request({history, 4, <<"erx_mod">>})),
    Refused = [{missing, [<<1:248>>]}, {missing, [Hash | Hash]}, {missing, lists:duplicate(1025, Hash)},
               {missing, Hash},
               {put, <<1:248>>, 1, 0, <<"a">>}, {put, Hash, 0, 0, <<"a">>}, {put, Hash, 1, -1, <<"a">>},
               {put, Hash, 1, 0, <<>>}, {put, Hash, ?PIECE + 1, 0, binary:copy(<<0>>, ?PIECE + 1)},
               {put, Hash, 1, 0, <<1:7>>}, {put, Hash, 1.0, 0, <<"a">>},
               {history, 4, erx_mod}, {history, <<"4">>, <<"erx_mod">>}, {history, 4, <<"a/b">>},
               {load}, load, [], <<"missing">>, {missing, [Hash], extra}],
    [?assertEqual({error, bad_request}, erx_code_store:read_request(Term)) || Term <- Refused],
    ?assertEqual({error, {bad_manifest, empty}}, erx_code_store:read_request({load, []})).

manifests_are_read_or_refused_with_their_reason_test() ->
    Hash = hash(<<"h">>),
    Names = [<<"erx_code">>, <<"Elixir.Foo">>, <<"a@b">>, <<"_9">>, binary:copy(<<"m">>, 255)],
    Good = [{Name, Hash} || Name <- Names],
    ?assertEqual({ok, Good}, erx_code_store:read_manifest(Good)),
    Many = [{<<"m", (integer_to_binary(Index))/binary>>, Hash} || Index <- lists:seq(1, 1025)],
    ?assertMatch({ok, [_ | _]}, erx_code_store:read_manifest(lists:sublist(Many, 1024))),
    Cases = [{not_a_list, #{}}, {not_a_list, [{<<"a">>, Hash} | {<<"b">>, Hash}]}, {empty, []},
             {too_many, Many},
             {{bad_entry, 1}, [{<<>>, Hash}]}, {{bad_entry, 1}, [{binary:copy(<<"m">>, 256), Hash}]},
             {{bad_entry, 2}, [{<<"a">>, Hash}, {<<"b/c">>, Hash}]}, {{bad_entry, 1}, [{<<"a b">>, Hash}]},
             {{bad_entry, 1}, [{<<"caf", 16#c3, 16#a9>>, Hash}]}, {{bad_entry, 1}, [{a, Hash}]},
             {{bad_entry, 1}, [{<<"a">>, <<Hash/binary, 0>>}]}, {{bad_entry, 1}, [{<<"a">>, Hash, extra}]},
             {{bad_entry, 1}, [<<"a">>]}, {{duplicate_name, 3}, [{<<"a">>, Hash}, {<<"b">>, Hash}, {<<"a">>, Hash}]}],
    [?assertEqual({Why, {error, Why}}, {Why, erx_code_store:read_manifest(Term)}) || {Why, Term} <- Cases].
