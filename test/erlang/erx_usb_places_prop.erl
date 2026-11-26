%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The USB domain's places (docs/design-usb.md, "HID reaches the display", and the places
%% row of "Host tests of the cores"): erx_usb_places_sup with its eight streams, read
%% through a real erx_fs grant of its input tree, against a model. Functions are model
%% processes the test drives: each takes a number, writes records, and ends by detach, by
%% crash, by a halted pipe or by its restart. The property: every number goes to the
%% lowest free one, every read answers exactly the model's next bytes, so each number's
%% file carries one occupant's records and then `release` before the next occupant's, and
%% a write waits exactly while it does not fit in one read's worth. Each wait the cases
%% assert on has a deadline of 1 s.
-module(erx_usb_places_prop).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([export/3, mint_grants/1]).

-define(NOFID, 16#ffffffff).
-define(O_RDONLY, 0).
-define(O_WRONLY, 1).
%% The fid of number N's open file is ?FID0 + N; fid 1 is the root, fid 2 the root opened.
-define(FID0, 10).
-define(STEPS, 400).
-define(RECORD, (erx_input_codec:size())).

%% Fixtures --------------------------------------------------------------

%% The domain's places and an own grant of their input tree, with every number's file
%% open for reading.
places() ->
    {ok, Places} = erx_usb_places_sup:start_link(),
    unlink(Places),
    Streams = streams(Places),
    {ok, {Grant, _Tree, _Rights}} = erx_fs_grants:own(mint_grants(Places)),
    {ok, _} = call(Grant, {attach, 1, ?NOFID, <<"user">>, ?ERX_INPUT_TREE_BYTES, 0}),
    {ok, _} = call(Grant, {walk, 1, 2, []}),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDONLY}),
    [begin
         {ok, _} = call(Grant, {walk, 1, ?FID0 + N, [name(N)]}),
         {ok, _, _} = call(Grant, {lopen, ?FID0 + N, ?O_RDONLY})
     end || N <- numbers()],
    #{places => Places, grant => Grant, streams => Streams}.

%% The supervisor of the input tree's grants, which the places' mint starts linked to
%% itself once it has mounted the tree, in its own process after its start; the HID
%% function's cases take it too (erx_usb_hid_tests).
mint_grants(Places) -> mint_grants(Places, 1000).

mint_grants(Places, Wait) ->
    [Mint] = [Pid || {mint, Pid, _, _} <- supervisor:which_children(Places)],
    {links, Links} = process_info(Mint, links),
    case Links -- [Places] of
        [Grants] -> Grants;
        [] when Wait > 0 -> timer:sleep(10), mint_grants(Places, Wait - 10)
    end.

%% The streams of the places' input numbers, number 0 first, the tree's arguments.
streams(Places) ->
    list_to_tuple(erx_usb_places_sup:streams(Places)).

stop(#{places := Places}) ->
    exit(Places, shutdown).

call(Grant, Request) ->
    Alias = send(Grant, Request),
    case reply_within(Alias, 1000) of
        none -> erlang:error({no_reply, Request});
        Reply -> Reply
    end.

send(Grant, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, self(), Request},
    Alias.

reply_within(Alias, Timeout) ->
    receive {erx_9p, Alias, Reply} -> Reply after Timeout -> none end.

numbers() -> lists:seq(0, ?ERX_USB_INPUT_MAX - 1).

name(N) -> <<"hid", (integer_to_binary(N))/binary>>.

%% A model function: a process that takes a number, writes and ends when the test says,
%% and tells the test what each step answered.
function(Places) ->
    Test = self(),
    Pid = spawn(fun() -> function_loop(Test, Places) end),
    _ = erlang:monitor(process, Pid),
    Pid.

function_loop(Test, Places) ->
    receive
        occupy -> Test ! {occupied, self(), erx_usb_places_sup:occupy_input(Places, self())};
        {write, Stream, Records} -> Test ! {wrote, self(), erx_usb_input_stream:write(Stream, Records)};
        {exit, Reason} -> exit(Reason)
    end,
    function_loop(Test, Places).

answer(Tag, Pid) ->
    receive {Tag, Pid, Answer} -> Answer after 1000 -> erlang:error({no_answer, Tag, Pid}) end.

ended(Pid) ->
    receive {'DOWN', _, process, Pid, _} -> ok after 1000 -> erlang:error({not_ended, Pid}) end.

%% The tree -----------------------------------------------------------------

%% The tree lists hid0 to hid7 and nothing else, walks no other name, and is read-only
%% by construction: its grant, rw as an own grant is, refuses every writing operation.
the_tree_holds_the_eight_numbers_test() ->
    #{grant := Grant} = P = places(),
    {ok, Entries} = call(Grant, {readdir, 2, 0, 4096}),
    ?assertEqual([name(N) || N <- numbers()], [Name || {_, _, _, Name} <- Entries]),
    {ok, _} = call(Grant, {walk, 1, 3, [<<"hid0">>]}),
    ?assertEqual({error, erofs}, call(Grant, {lopen, 3, ?O_WRONLY})),
    ?assertEqual({error, enoent}, call(Grant, {walk, 1, 4, [<<"hid8">>]})),
    ?assertEqual({error, enoent}, call(Grant, {walk, 1, 4, [<<"hidx">>]})),
    ?assertEqual({error, erofs}, call(Grant, {lcreate, 1, <<"hid9">>, 0, 8#644, 0})),
    stop(P).

%% A grant minted with the limits the domain service mints an input service's with
%% (erx_domain_mints's grant_limits/2: its facet row's limits with rights ro, and session
%% for the marked grant) is accepted: session returns no einval, the tree attaches under
%% ?ERX_INPUT_TREE_BYTES, a read opens, and a write open is refused. The refusal does not
%% test `rights => ro`: the input tree exports no write callback, so erx_fs_grant makes
%% every grant of it read-only. The grant is bound as the domain's own, so the test's bare
%% requests reach it; the limits apply to every grant alike.
a_grant_with_the_mint_limits_is_accepted_and_serves_the_tree_test() ->
    {ok, Places} = erx_usb_places_sup:start_link(),
    unlink(Places),
    {ok, Grants} = erx_fs_grants:start_link(erx_usb_input_tree),
    {ok, Grant, _Tree} = erx_fs_grants:grant(Grants, streams(Places), #{rights => ro, session => true},
                                             #{client => own, ends_with => none, exports => ?MODULE}),
    {ok, _} = call(Grant, {attach, 1, ?NOFID, <<"user">>, ?ERX_INPUT_TREE_BYTES, 0}),
    {ok, _} = call(Grant, {walk, 1, 3, [name(0)]}),
    ?assertEqual({error, erofs}, call(Grant, {lopen, 3, ?O_WRONLY})),
    {ok, _, _} = call(Grant, {lopen, 3, ?O_RDONLY}),
    stop(#{places => Places}).

%% The grant's exports module: every export is allowed.
export(_Pid, _Rights, _Peer) ->
    ok.

%% A read takes whole records only: one too small for a record is refused at once, and
%% one whose count ends inside a record takes the records before it.
reads_take_whole_records_test() ->
    #{grant := Grant, places := Places, streams := Streams} = P = places(),
    ?assertEqual({error, einval}, call(Grant, {read, ?FID0, 0, 1})),
    ?assertEqual({error, einval}, call(Grant, {read, ?FID0, 0, ?RECORD - 1})),
    F = function(Places),
    F ! occupy,
    ?assertMatch({ok, 0, _}, answer(occupied, F)),
    F ! {write, element(1, Streams), [{key, down, 1}, {key, up, 1}]},
    ?assertEqual(ok, answer(wrote, F)),
    ?assertEqual({ok, erx_input_codec:encode({key, down, 1})}, call(Grant, {read, ?FID0, 0, 2 * ?RECORD - 1})),
    ?assertEqual({ok, erx_input_codec:encode({key, up, 1})}, call(Grant, {read, ?FID0, 0, 4096})),
    stop(P).

%% A flush of a waiting read answers it eintr and takes nothing; the next read gets the
%% records.
a_flush_answers_a_waiting_read_eintr_test() ->
    #{grant := Grant, places := Places, streams := Streams} = P = places(),
    Read = send(Grant, {read, ?FID0, 0, 4096}),
    Flush = send(Grant, {flush, Read}),
    ?assertEqual({error, eintr}, reply_within(Read, 1000)),
    ?assertEqual(ok, reply_within(Flush, 1000)),
    F = function(Places),
    F ! occupy,
    ?assertMatch({ok, 0, _}, answer(occupied, F)),
    F ! {write, element(1, Streams), [{wheel, 1}]},
    ?assertEqual(ok, answer(wrote, F)),
    ?assertEqual({ok, erx_input_codec:encode({wheel, 1})}, call(Grant, {read, ?FID0, 0, 4096})),
    stop(P).

%% Only the occupant writes: another process's write is refused and adds nothing.
only_the_occupant_writes_test() ->
    #{grant := Grant, places := Places, streams := Streams} = P = places(),
    F = function(Places),
    F ! occupy,
    ?assertMatch({ok, 0, _}, answer(occupied, F)),
    ?assertEqual({error, not_occupant}, erx_usb_input_stream:write(element(1, Streams), [{key, down, 2}])),
    ?assertEqual({error, not_occupant}, erx_usb_input_stream:write(element(2, Streams), [{key, down, 2}])),
    Read = send(Grant, {read, ?FID0, 0, 4096}),
    ?assertEqual(none, reply_within(Read, 50)),
    stop(P).

%% A read of an empty file waits; the occupant's first records answer it, and its end
%% puts release after them.
a_waiting_read_takes_the_occupants_records_then_release_test() ->
    #{grant := Grant, places := Places, streams := Streams} = P = places(),
    Read = send(Grant, {read, ?FID0, 0, 4096}),
    ?assertEqual(none, reply_within(Read, 0)),
    F = function(Places),
    F ! occupy,
    ?assertMatch({ok, 0, _}, answer(occupied, F)),
    F ! {write, element(1, Streams), [{key, down, 30}]},
    ?assertEqual(ok, answer(wrote, F)),
    ?assertEqual({ok, erx_input_codec:encode({key, down, 30})}, reply_within(Read, 1000)),
    exit(F, kill),
    ended(F),
    ?assertEqual({ok, erx_input_codec:encode(release)}, call(Grant, {read, ?FID0, 0, 4096})),
    stop(P).

%% A function started again before its number's stream has taken its predecessor's end
%% still gets that number, and the file carries release before the new records: the
%% stream, held while the predecessor dies, finds the new start ahead of the 'DOWN'.
a_start_ahead_of_the_end_still_finds_release_test() ->
    #{grant := Grant, places := Places, streams := Streams} = P = places(),
    Stream = element(1, Streams),
    Old = function(Places),
    Old ! occupy,
    ?assertMatch({ok, 0, _}, answer(occupied, Old)),
    New = function(Places),
    ok = sys:suspend(Stream),
    New ! occupy,
    wait_for_call(Stream),
    exit(Old, kill),
    ended(Old),
    ok = sys:resume(Stream),
    ?assertMatch({ok, 0, _}, answer(occupied, New)),
    New ! {write, Stream, [{key, down, 1}]},
    ?assertEqual(ok, answer(wrote, New)),
    Expected = <<(erx_input_codec:encode(release))/binary, (erx_input_codec:encode({key, down, 1}))/binary>>,
    ?assertEqual({ok, Expected}, call(Grant, {read, ?FID0, 0, 4096})),
    stop(P).

%% Waits until a call is queued at the suspended Stream.
wait_for_call(Stream) ->
    case erlang:process_info(Stream, message_queue_len) of
        {message_queue_len, 0} -> timer:sleep(1), wait_for_call(Stream);
        {message_queue_len, _} -> ok
    end.

%% The property ---------------------------------------------------------------

places_hold_under_random_sequences_test_() ->
    {timeout, 120, fun() -> [run(Seed) || Seed <- [{1, 2, 3}, {7, 11, 13}, {17, 19, 23}]] end}.

%% The model: functions, each with its number (or none) and the write it waits on (or
%% none); numbers, each with its occupant, the bytes written and not yet read, and the
%% read outstanding at the grant (or none).
-record(model, {functions = #{} :: #{pid() => #{number := non_neg_integer(), waiting := none | binary()}},
                numbers :: #{non_neg_integer() => #{occupant := none | pid(), bytes := binary(),
                                                    read := none | {reference(), pos_integer()}}}}).

run(Seed) ->
    rand:seed(exsss, Seed),
    P = places(),
    Model0 = #model{numbers = maps:from_list([{N, #{occupant => none, bytes => <<>>, read => none}}
                                              || N <- numbers()])},
    Model = lists:foldl(fun(_, M) -> step(P, M) end, Model0, lists:seq(1, ?STEPS)),
    drain(P, Model),
    stop(P).

step(P, #model{functions = Functions} = M) ->
    Live = maps:keys(Functions),
    case {rand:uniform(10), Live} of
        {Roll, _} when Roll =< 2 -> start(P, M);
        {Roll, [_ | _]} when Roll =< 5 -> write(P, pick(Live), M);
        {Roll, [_ | _]} when Roll =< 6 -> finish(P, pick(Live), M);
        {Roll, [_ | _]} when Roll =< 7 -> restart(P, pick(Live), M);
        _ -> read(P, rand:uniform(?ERX_USB_INPUT_MAX) - 1, M)
    end.

pick(List) -> lists:nth(rand:uniform(length(List)), List).

%% A function starts and takes the lowest number with no occupant and room in its buffer.
start(#{places := Places}, #model{functions = Functions, numbers = Numbers} = M) ->
    F = function(Places),
    F ! occupy,
    Free = [N || N <- numbers(), free(maps:get(N, Numbers))],
    case {answer(occupied, F), Free} of
        {{ok, N, _}, [N | _]} ->
            #{N := Number} = Numbers,
            M#model{functions = Functions#{F => #{number => N, waiting => none}},
                    numbers = Numbers#{N := Number#{occupant := F}}};
        {{error, no_input_number}, []} ->
            F ! {exit, normal},
            ended(F),
            M;
        {Answer, _} ->
            erlang:error({occupied, Answer, expected, Free})
    end.

free(#{occupant := none, bytes := Bytes}) -> byte_size(Bytes) < ?ERX_P9_IO_MAX;
free(#{}) -> false.

%% An occupant writes a batch of records, some large enough to fill the buffer; one that
%% does not fit waits until reads make room.
write(#{streams := Streams} = P, F, #model{functions = Functions} = M) ->
    case Functions of
        #{F := #{waiting := none, number := N}} ->
            Records = records(case rand:uniform(4) of 1 -> 3000; _ -> 20 end),
            F ! {write, element(N + 1, Streams), Records},
            Bytes = << <<(erx_input_codec:encode(R))/binary>> || R <- Records >>,
            settle(P, N, M#model{functions = Functions#{F := #{number => N, waiting => Bytes}}});
        #{} ->
            M
    end.

records(Max) ->
    [case rand:uniform(3) of
         1 -> {key, down, rand:uniform(768) - 1};
         2 -> {key, up, rand:uniform(768) - 1};
         3 -> {pointer, rel, rand:uniform(201) - 101, rand:uniform(201) - 101}
     end || _ <- lists:seq(1, rand:uniform(Max))].

%% A function ends by detach, by crash or by a halted pipe; one waiting in its write can
%% only be ended from outside.
finish(P, F, #model{functions = Functions} = M) ->
    Reason = pick([normal, shutdown, killed, {transfer, halted}]),
    case Functions of
        #{F := #{waiting := none}} -> F ! {exit, Reason};
        #{F := #{}} -> exit(F, case Reason of normal -> kill; _ -> Reason end)
    end,
    ended(F),
    gone(P, F, M).

%% A function crashes and is started again at once, before its stream may have seen the
%% end: its number is free for the new start, which still finds release ahead of it.
restart(P, F, M) ->
    exit(F, kill),
    ended(F),
    start(P, gone(P, F, M)).

%% The model of an occupant's end: its waiting write is dropped, release follows what it
%% wrote, and the number is free.
gone(P, F, #model{functions = Functions, numbers = Numbers} = M) ->
    {#{number := N}, Rest} = maps:take(F, Functions),
    #{N := #{bytes := Bytes} = Number} = Numbers,
    Release = erx_input_codec:encode(release),
    settle(P, N, M#model{functions = Rest,
                         numbers = Numbers#{N := Number#{occupant := none,
                                                         bytes := <<Bytes/binary, Release/binary>>}}}).

%% The reader reads number N: with bytes buffered the read takes at most Count of them at
%% once; with none it stays outstanding, at most one a number, as the display's reader is.
read(#{grant := Grant} = P, N, #model{numbers = Numbers} = M) ->
    case maps:get(N, Numbers) of
        #{read := none} = Number ->
            Count = pick([?RECORD, 2 * ?RECORD - 1, 100, 4096, ?ERX_P9_IO_MAX]),
            Alias = send(Grant, {read, ?FID0 + N, 0, Count}),
            settle(P, N, M#model{numbers = Numbers#{N := Number#{read := {Alias, Count}}}});
        #{} ->
            M
    end.

%% What number N does next, as the stream does it, until nothing can move: the
%% outstanding read takes buffered bytes, and the occupant's waiting write is taken once
%% it fits. At rest, a read outstanding has no answer yet, a write waiting has none
%% either, and the buffer is within one read's worth and the one release past it.
settle(P, N, #model{numbers = Numbers} = M) ->
    case maps:get(N, Numbers) of
        #{read := {Alias, Count}, bytes := Bytes} = Number when Bytes =/= <<>> ->
            Size = min(Count - Count rem ?RECORD, byte_size(Bytes)),
            <<Taken:Size/binary, Rest/binary>> = Bytes,
            ?assertEqual({ok, Taken}, reply_within(Alias, 1000)),
            settle(P, N, M#model{numbers = Numbers#{N := Number#{read := none, bytes := Rest}}});
        #{} ->
            take(P, N, M)
    end.

take(P, N, #model{functions = Functions, numbers = Numbers} = M) ->
    #{N := #{occupant := Occupant, bytes := Bytes} = Number} = Numbers,
    case Functions of
        #{Occupant := #{waiting := Waiting} = Function} when is_binary(Waiting),
                                                              byte_size(Bytes) + byte_size(Waiting) =< ?ERX_P9_IO_MAX ->
            ?assertEqual(ok, answer(wrote, Occupant)),
            settle(P, N, M#model{functions = Functions#{Occupant := Function#{waiting := none}},
                                 numbers = Numbers#{N := Number#{bytes := <<Bytes/binary, Waiting/binary>>}}});
        #{} ->
            at_rest(N, M)
    end.

at_rest(N, #model{functions = Functions, numbers = Numbers} = M) ->
    #{N := #{occupant := Occupant, bytes := Bytes, read := Read}} = Numbers,
    case Read of
        {Alias, _} -> ?assertEqual(none, reply_within(Alias, 0));
        none -> ok
    end,
    case Functions of
        #{Occupant := #{waiting := Waiting}} when is_binary(Waiting) ->
            receive {wrote, Occupant, Early} -> erlang:error({taken_past_the_bound, N, Early})
            after 20 -> ok
            end;
        #{} ->
            ok
    end,
    ?assert(byte_size(Bytes) =< ?ERX_P9_IO_MAX + ?RECORD),
    M.

%% Every function ends and every number's file is read to its end: what is left is the
%% model's bytes, release last wherever an occupant was.
drain(P, #model{functions = Functions} = M0) ->
    M = lists:foldl(fun(F, Acc) -> exit(F, kill), ended(F), gone(P, F, Acc) end, M0, maps:keys(Functions)),
    lists:foreach(fun(N) -> drain_number(P, N, M) end, numbers()).

drain_number(P, N, #model{numbers = Numbers} = M) ->
    case maps:get(N, Numbers) of
        #{bytes := <<>>} -> ok;
        #{read := none} -> drain_number(P, N, read(P, N, M));
        #{} -> drain_number(P, N, settle(P, N, M))
    end.
