%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the drives' raw sectors (docs/design-drives.md, "Raw sectors"): the
%% barrier's state machine, erx_media_raw_barrier, over every sequence of events up to a
%% bound; a request's plan, erx_media_raw:plan/3; and the raw tree and its raw process
%% over a fake window holding a medium of two volumes, each sector of which holds its own
%% number, so a sector read names where it came from and the sectors around each volume
%% are its sentinels.
-module(erx_media_raw_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(NOFID, 16#ffffffff).
-define(SECTOR, 512).
-define(BOUND, 30000).
%% The medium: 512 sectors, volume 1 at 64 and volume 2 at 256, 128 sectors each.
-define(CAPACITY, 512).
%% The name each case runs under, to which the fake window tells its requests.
-define(LISTENER, erx_media_raw_tests_listener).

%% The barrier ---------------------------------------------------------------

%% Every sequence of up to Depth events the counts allow, from a new barrier, checked
%% after each step against the rule's properties; the model beside it is what the
%% sequence has done so far.
the_barrier_holds_its_rule_over_every_sequence_test() ->
    ?assert(explore(erx_media_raw_barrier:new(), model(), 7) > 10000).

model() -> #{writers => 0, sent => 0, wrote => false, held => [], flush => none, finishing => false, finished => false,
             failed => false}.

explore(_Barrier, _Model, 0) ->
    1;
explore(Barrier, Model, Depth) ->
    lists:sum([explore(B1, M1, Depth - 1) || Event <- events(Model),
                                             {B1, M1} <- [stepped(Event, Barrier, Model)]]) + 1.

%% The events the counts allow next, none once the process has failed. A flush answered
%% is the one on its way.
events(#{failed := true}) ->
    [];
events(#{writers := W, sent := S, flush := F, finished := Finished}) ->
    [arrive]
    ++ [leave || W > 0]
    ++ [{took, [{volume, 1}]}, {took, [medium]}]
    ++ [queued]
    ++ [wrote || S > 0, F =:= none]
    ++ [answered || S > 0, F =:= none orelse S > 1]
    ++ [{flushed, Answer} || F =/= none, Answer <- [ok, {error, eio}]]
    ++ [finish || not Finished].

stepped(Event, Barrier, Model) ->
    {Actions, Barrier1} = erx_media_raw_barrier:step(Event, Barrier),
    Model1 = after_event(Event, Model),
    {Barrier1, checked(Actions, Event, Model1, Barrier1)}.

after_event(arrive, #{writers := W} = M) -> M#{writers := W + 1};
after_event(leave, #{writers := W} = M) -> M#{writers := W - 1};
after_event({took, Covers}, #{held := H} = M) -> M#{held := lists:usort(H ++ Covers)};
after_event(queued, #{sent := S} = M) -> M#{sent := S + 1};
after_event(wrote, M) -> M#{wrote := true};
after_event(answered, #{sent := S} = M) -> M#{sent := S - 1};
after_event({flushed, _}, #{sent := S} = M) -> M#{sent := S - 1, flush := none};
after_event(finish, M) -> M#{finishing := true, finished := true}.

%% After its finish is answered, the barrier answers nothing more.

%% The rule's properties for the actions one event answered:
%% * a hand-back happens only with no writer, nothing sent, no flush on its way and no
%%   finish, gives back everything held, and only after a flush when a write was sent;
%% * the barrier flushes only when it wrote, the finish flushes once nothing is sent;
%% * a failed barrier flush fails the process; a finish's flush answers the finish;
%% * once nothing blocks the barrier, nothing stays held without a flush on its way.
checked(Actions, Event, Model, Barrier) ->
    Next = lists:foldl(fun(Action, M) -> acted(Action, Event, M) end, Model, Actions),
    #{writers := W, sent := S, held := H, flush := F, finishing := Finishing, finished := Finished,
      failed := Failed} = Next,
    ?assertEqual(H, erx_media_raw_barrier:holds(Barrier)),
    case {W, S, H, F, Finishing} of
        {0, 0, [_ | _], none, false} when not Finished -> erlang:error({held_with_barrier_open, Event, Next});
        {_, 0, _, none, true} when not Failed, Actions =/= [], element(1, hd(Actions)) =/= finished ->
            erlang:error({finish_not_flushed, Next});
        _ -> Next
    end.

acted({hand_back, Covers}, _Event, #{writers := 0, sent := 0, flush := none, finishing := false, wrote := false, held := Covers} = M) ->
    M#{held := []};
acted(flush, _Event, #{writers := 0, sent := 0, flush := none, finishing := false, wrote := true, held := [_ | _]} = M) ->
    M#{sent := 1, flush := barrier, wrote := false};
acted(flush, _Event, #{sent := 0, flush := none, finishing := true} = M) ->
    M#{sent := 1, flush := finish};
acted({fail, {flush, {error, eio}}}, {flushed, {error, eio}}, #{flush := none} = M) ->
    M#{failed := true, finished := true};
acted({finished, Answer}, {flushed, Answer}, #{finishing := true} = M) ->
    M#{finishing := false};
acted(Action, Event, M) ->
    erlang:error({unexpected_action, Action, Event, M}).

%% A refusal is a leave like any other: an open whose take failed leaves its volumes
%% held while a first writer still writes, and they return only once it has closed and
%% its write is answered, after a flush.
a_refused_open_hands_nothing_back_test() ->
    Steps = [arrive, {took, [{volume, 1}]}, queued, wrote, arrive, {took, [medium]}, leave],
    B = lists:foldl(fun(E, B0) -> {[], B1} = erx_media_raw_barrier:step(E, B0), B1 end,
                    erx_media_raw_barrier:new(), Steps),
    ?assertEqual([medium, {volume, 1}], erx_media_raw_barrier:holds(B)),
    {[], B2} = erx_media_raw_barrier:step(leave, B),
    {[flush], B3} = erx_media_raw_barrier:step(answered, B2),
    ?assertMatch({[{hand_back, [medium, {volume, 1}]}], _}, erx_media_raw_barrier:step({flushed, ok}, B3)).

%% Requests -------------------------------------------------------------------

plan_test_() ->
    V = #{first => 256, length => 128},
    Max = ?ERX_P9_IO_MAX,
    [?_assertEqual({ok, [{read, 256, 1}]}, erx_media_raw:plan({read, 0, 512}, V, 8)),
     ?_assertEqual({error, einval}, erx_media_raw:plan({read, 1, 512}, V, 8)),
     ?_assertEqual({error, einval}, erx_media_raw:plan({read, 0, 100}, V, 8)),
     ?_assertEqual({error, einval}, erx_media_raw:plan({read, 0, Max + 512}, V, 8)),
     ?_assertEqual({error, einval}, erx_media_raw:plan({write, 0, <<0:100/unit:8>>}, V, 8)),
     ?_assertEqual({error, einval}, erx_media_raw:plan({write, 513, <<0:512/unit:8>>}, V, 8)),
     %% A write that ends past the file, and one whose sum does.
     ?_assertEqual({error, einval}, erx_media_raw:plan({write, 127 * 512, <<0:1024/unit:8>>}, V, 8)),
     ?_assertEqual({error, einval}, erx_media_raw:plan({write, 16#ffffffffffffffff - 511, <<0:512/unit:8>>}, V, 8)),
     %% A 64 KiB read whose last 4 KiB lie past the end is cut to 60 KiB.
     ?_assertEqual(60 * 1024, read_bytes(erx_media_raw:plan({read, (128 - 120) * 512, 65536}, V, 8))),
     ?_assertEqual({ok, []}, erx_media_raw:plan({read, 128 * 512, 512}, V, 8)),
     ?_assertEqual({ok, []}, erx_media_raw:plan({read, 1 bsl 60, 512}, V, 8)),
     %% A 64 KiB write lands as pieces of the window's max_sectors, in order: 16 of 8
     %% sectors (virtio, SD), 2 of 64 (USB).
     ?_assertEqual([{write, 8 * I} || I <- lists:seq(0, 15)],
                   [{write, Lba} || {write, Lba, <<_:4096/binary>>} <- element(2, erx_media_raw:plan({write, 0, <<0:Max/unit:8>>}, #{first => 0, length => 512}, 8))]),
     ?_assertEqual([{write, 0}, {write, 64}],
                   [{write, Lba} || {write, Lba, <<_:32768/binary>>} <- element(2, erx_media_raw:plan({write, 0, <<0:Max/unit:8>>}, #{first => 0, length => 512}, 64))]),
     %% Placement keeps a volume's sectors inside it.
     ?_assertEqual({ok, [{write, 256 + 127, <<1:4096>>}]}, erx_media_raw:plan({write, 127 * 512, <<1:4096>>}, V, 8))].

read_bytes({ok, Pieces}) -> lists:sum([N * 512 || {read, _, N} <- Pieces]).

%% The raw tree over a fake window -------------------------------------------

medium() ->
    Sector0 = erx_media_volume_tests:mbr([{16#0c, 64, 128}, {16#0c, 256, 128}], []),
    iolist_to_binary([Sector0 | [<<Lba:32, 0:(508 * 8)>> || Lba <- lists:seq(1, ?CAPACITY - 1)]]).

%% A fake window: sectors of Medium, every request told to the test, and, while asked
%% to, a write held until released and a flush answered from a list.
window(Test, Medium) ->
    serve(Test, #{medium => Medium, hold => false, held => none, flushes => []}).

serve(Test, #{medium := Medium, held := Held, flushes := Flushes} = State) ->
    receive
        {'$gen_call', From, info} ->
            gen:reply(From, {ok, #{role => drive, sectors => ?CAPACITY, max_sectors => 8}}), serve(Test, State);
        {'$gen_call', From, {read, Lba, N}} ->
            tell({window, {read, Lba, N}}),
            gen:reply(From, {ok, binary:part(Medium, Lba * ?SECTOR, N * ?SECTOR)}), serve(Test, State);
        {'$gen_call', From, {write, Lba, Bytes}} when map_get(hold, State) ->
            tell({window, {held, Lba}}),
            serve(Test, State#{held := {From, Lba, Bytes}, hold := false});
        {'$gen_call', From, {write, Lba, Bytes}} ->
            tell({window, {write, Lba}}),
            gen:reply(From, ok), serve(Test, State#{medium := written(Medium, Lba, Bytes)});
        {'$gen_call', From, flush} ->
            {Answer, Rest} = case Flushes of [A | R] -> {A, R}; [] -> {ok, []} end,
            tell({window, flush}),
            gen:reply(From, Answer), serve(Test, State#{flushes := Rest});
        hold -> serve(Test, State#{hold := true});
        {flushes, Answers} -> serve(Test, State#{flushes := Answers});
        release when Held =/= none ->
            {From, Lba, Bytes} = Held,
            tell({window, {write, Lba}}),
            gen:reply(From, ok), serve(Test, State#{medium := written(Medium, Lba, Bytes), held := none})
    end.

tell(Message) ->
    case whereis(?LISTENER) of
        undefined -> ok;
        Listener -> Listener ! Message
    end.

written(Medium, Lba, Bytes) ->
    <<Before:(Lba * ?SECTOR)/binary, _:(byte_size(Bytes))/binary, After/binary>> = Medium,
    <<Before/binary, Bytes/binary, After/binary>>.

start() ->
    ok = erx_media_volume:new_mounts(),
    {ok, Sup} = supervisor:start_link({local, erx_media_sup}, erx_media_tree_tests, stand_in),
    Test = self(),
    Window = spawn_link(fun() -> window(Test, medium()) end),
    Facet = spawn_link(fun() -> erx_media_volume_tests:facet(Window) end),
    ok = erx_facets:install(#{{drive, 0} => {?ERX_SERVICE_DRIVE, Facet}}),
    [unlink(P) || P <- [Sup, Window, Facet]],
    #{window => Window, ended => [Sup, Facet, Window]}.

stop(#{ended := Pids}) ->
    [begin M = monitor(process, P), exit(P, kill), receive {'DOWN', M, _, _, _} -> ok end end || P <- Pids],
    flush_window(),
    ok.

flush_window() -> receive {window, _} -> flush_window() after 0 -> ok end.

grant(Module, Tree) ->
    {ok, Grant, _} = erx_fs:start_link(Module, Tree, rw),
    unlink(Grant),
    {ok, _} = call(Grant, {attach, 1, ?NOFID, <<"root">>, atom_to_binary(Tree), 0}),
    Grant.

call(Grant, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, self(), Request},
    receive {erx_9p, Alias, Reply} -> Reply after ?BOUND -> erlang:error({no_reply, Request}) end.

%% Sends Request and answers its alias, for a reply the test collects later.
send(Grant, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, self(), Request},
    Alias.

reply(Alias) ->
    receive {erx_9p, Alias, Reply} -> Reply after ?BOUND -> erlang:error(no_reply) end.

opened(Grant, Fid, Path, Flags) ->
    {ok, _} = call(Grant, {walk, 1, Fid, Path}),
    call(Grant, {lopen, Fid, Flags}).

names(Grant, Fid, Path) ->
    {ok, _} = call(Grant, {walk, 1, Fid, Path}),
    {ok, _, _} = call(Grant, {lopen, Fid, ?ERX_P9_O_DIRECTORY}),
    {ok, Entries} = call(Grant, {readdir, Fid, 0, 4096}),
    ok = call(Grant, {clunk, Fid}),
    [Name || {_Qid, _Offset, _Type, Name} <- Entries].

%% Volume N's process as drive 0 answers its medium: a pid, raw, or the table raw.
volume(N) ->
    case erx_media_drive:medium(0) of
        {ok, #{table := {_, Volumes, _}}} -> hd([P || {#{number := V}, P} <- Volumes, V =:= N]);
        {ok, #{table := Table}} -> Table
    end.

%% Once volume N is served by a live process: polled every 20 ms, at most 250 times.
returned(N) -> returned(N, 250).
returned(_N, 0) -> timeout;
returned(N, Rounds) ->
    case volume(N) of
        Pid when is_pid(Pid) -> ok;
        _ -> timer:sleep(20), returned(N, Rounds - 1)
    end.

raw_tree_test_() ->
    {foreach, fun start/0, fun stop/1,
     [fun(F) -> {Name, {timeout, 60, fun() -> register(?LISTENER, self()), Case(F) end}} end
      || {Name, Case} <- [{"listing and placement", fun listing_and_placement/1},
                          {"a reading open disturbs nothing", fun reading/1},
                          {"a writing open takes its volume until its close", fun writing/1},
                          {"a create of a raw file opens it", fun created/1},
                          {"a flush that cannot flush refuses the open", fun enotsup/1},
                          {"a refused open hands nothing back", fun refused_while_writing/1},
                          {"a grant's end is a close behind its held write", fun grant_end/1},
                          {"eject finishes the raw process", fun eject/1},
                          {"the raw process's end ends the medium", fun raw_killed/1},
                          {"a media grant reaches no sector", fun media_reaches_no_sector/1}]]}.

listing_and_placement(_F) ->
    Raw = grant(erx_media_raw_tree, media_raw),
    ?assertEqual([<<"disk0">>], names(Raw, 2, [])),
    ?assertEqual([<<"data">>, <<"s1.data">>, <<"s2.data">>], names(Raw, 2, [<<"disk0">>])),
    {ok, _, _} = opened(Raw, 2, [<<"disk0">>, <<"s2.data">>], 0),
    ?assertMatch({ok, <<256:32, _/binary>>}, call(Raw, {read, 2, 0, 512})),
    ?assertEqual({error, einval}, call(Raw, {read, 2, 1, 512})),
    %% A read cut at the end, and one past it.
    {ok, Cut} = call(Raw, {read, 2, 120 * 512, 8192}),
    ?assertEqual(8 * 512, byte_size(Cut)),
    ?assertEqual({ok, <<>>}, call(Raw, {read, 2, 128 * 512, 512})),
    ?assertMatch({ok, #{size := 65536}}, getattr(Raw, 2)),
    ok = call(Raw, {clunk, 2}).

getattr(Grant, Fid) ->
    case call(Grant, {getattr, Fid, 16#3fff}) of
        {ok, _Valid, _Qid, Attr} -> {ok, Attr};
        {ok, Attr} -> {ok, Attr};
        Other -> Other
    end.

reading(_F) ->
    Raw = grant(erx_media_raw_tree, media_raw),
    {ok, _, _} = opened(Raw, 2, [<<"disk0">>, <<"s1.data">>], 0),
    ?assertMatch({ok, <<64:32, _/binary>>}, call(Raw, {read, 2, 0, 512})),
    ?assert(is_pid(volume(1))),
    ?assertEqual({error, ebadf}, call(Raw, {write, 2, 0, <<0:4096>>})),
    ok = call(Raw, {clunk, 2}).

writing(_F) ->
    Raw = grant(erx_media_raw_tree, media_raw),
    Before = volume(1),
    {ok, _, _} = opened(Raw, 2, [<<"disk0">>, <<"s1.data">>], ?ERX_P9_O_RDWR),
    ?assertEqual(raw, volume(1)),
    ?assert(is_pid(volume(2))),
    ?assertMatch(flush, last_window()),
    %% A write past the volume's end is refused; one inside lands inside it.
    ?assertEqual({error, einval}, call(Raw, {write, 2, 128 * 512, <<9:4096>>})),
    ?assertMatch({ok, 512, _}, call(Raw, {write, 2, 127 * 512, <<9:4096>>})),
    ?assertEqual({write, 64 + 127}, last_window()),
    ok = call(Raw, {clunk, 2}),
    ok = returned(1),
    ?assertNotEqual(Before, volume(1)).

%% A create of an existing raw file opens it, as O_CREAT does on FreeBSD, so `dd of=` and
%% prim_file's writing opens reach the sectors; a new name is refused.
created(_F) ->
    Raw = grant(erx_media_raw_tree, media_raw),
    {ok, _} = call(Raw, {walk, 1, 2, [<<"disk0">>]}),
    ?assertEqual({error, eacces}, call(Raw, {lcreate, 2, <<"new">>, ?ERX_P9_O_RDWR, 8#644, 0})),
    ?assertMatch({ok, _, _}, call(Raw, {lcreate, 2, <<"s1.data">>, ?ERX_P9_O_RDWR bor ?ERX_P9_O_TRUNC, 8#644, 0})),
    ?assertEqual(raw, volume(1)),
    ok = call(Raw, {clunk, 2}),
    ok = returned(1).

enotsup(#{window := Window}) ->
    Raw = grant(erx_media_raw_tree, media_raw),
    Window ! {flushes, [{error, enotsup}]},
    {ok, _} = call(Raw, {walk, 1, 2, [<<"disk0">>, <<"s1.data">>]}),
    flush_window(),
    ?assertEqual({error, erofs}, call(Raw, {lopen, 2, ?ERX_P9_O_RDWR})),
    ok = returned(1),
    %% One flush, the open's, and no write: no write was sent, so the barrier sent none.
    ?assertEqual([flush], [W || W <- windows(), W =:= flush orelse element(1, W) =:= write]).

refused_while_writing(#{window := Window}) ->
    Raw = grant(erx_media_raw_tree, media_raw),
    {ok, _, _} = opened(Raw, 2, [<<"disk0">>, <<"s1.data">>], ?ERX_P9_O_RDWR),
    flush_window(),
    Window ! hold,
    Write = send(Raw, {write, 2, 0, <<7:4096>>}),
    ?assertEqual({held, 64}, next_window()),
    %% A writer of data whose finish of s2 fails is refused while the write is held.
    S2 = volume(2),
    exit(S2, kill),
    {ok, _} = call(Raw, {walk, 1, 3, [<<"disk0">>, <<"data">>]}),
    ?assertEqual({error, eio}, call(Raw, {lopen, 3, ?ERX_P9_O_RDWR})),
    timer:sleep(100),
    ?assertEqual(raw, volume(1)),
    Window ! release,
    ?assertMatch({ok, 512, _}, reply(Write)),
    ok = call(Raw, {clunk, 2}),
    ok = returned(1),
    %% The barrier flushed once the write was answered, before the medium mounted again.
    ?assert(lists:member(flush, windows())).

grant_end(#{window := Window}) ->
    Raw = grant(erx_media_raw_tree, media_raw),
    {ok, _, _} = opened(Raw, 2, [<<"disk0">>, <<"s1.data">>], ?ERX_P9_O_RDWR),
    flush_window(),
    Window ! hold,
    _Write = send(Raw, {write, 2, 0, <<7:4096>>}),
    ?assertEqual({held, 64}, next_window()),
    exit(Raw, kill),
    timer:sleep(100),
    ?assertEqual(raw, volume(1)),
    Window ! release,
    ?assertEqual({write, 64}, next_window()),
    ?assertEqual(flush, next_window()),
    ok = returned(1).

eject(#{window := Window}) ->
    Raw = grant(erx_media_raw_tree, media_raw),
    {ok, _, _} = opened(Raw, 2, [<<"disk0">>, <<"s1.data">>], ?ERX_P9_O_RDWR),
    flush_window(),
    Window ! hold,
    _First = send(Raw, {write, 2, 0, <<7:4096>>}),
    ?assertEqual({held, 64}, next_window()),
    Queued = send(Raw, {write, 2, 512, <<8:4096>>}),
    Eject = spawn_monitor(fun() -> exit({eject, erx_media_drive:eject(0)}) end),
    timer:sleep(100),
    Window ! release,
    ?assertEqual({error, eio}, reply(Queued)),
    {EjectPid, _} = Eject,
    receive {'DOWN', _, process, EjectPid, {eject, Answer}} -> ?assertEqual(ok, Answer) after ?BOUND -> erlang:error(no_eject) end,
    ?assertEqual([{write, 64}, flush], windows()),
    ?assertMatch({ok, #{table := ejected}}, erx_media_drive:medium(0)).

raw_killed(_F) ->
    Raw = grant(erx_media_raw_tree, media_raw),
    {ok, _, _} = opened(Raw, 2, [<<"disk0">>, <<"s1.data">>], ?ERX_P9_O_RDWR),
    [Drive] = [P || {{drive, 0}, P, _, _} <- supervisor:which_children(erx_media_sup)],
    #{medium := #{raw := {RawPid, _}}} = sys:get_state(Drive),
    exit(RawPid, kill),
    ?assertEqual(ok, failed_medium(250)),
    ?assertEqual([], names(Raw, 3, [<<"disk0">>])).

%% Once drive 0's medium shows the raw process's end: polled every 20 ms.
failed_medium(0) -> timeout;
failed_medium(Rounds) ->
    case erx_media_drive:medium(0) of
        {ok, #{table := {failed, {raw, killed}}}} -> ok;
        _ -> timer:sleep(20), failed_medium(Rounds - 1)
    end.

media_reaches_no_sector(_F) ->
    Media = grant(erx_media_tree, media),
    ?assertEqual([<<"raw">>, <<"disk0">>], names(Media, 2, [])),
    ?assertEqual([], names(Media, 2, [<<"raw">>])),
    %% Each walk stops at the drive's directory, or at raw.
    ?assertMatch({ok, [_]}, call(Media, {walk, 1, 2, [<<"disk0">>, <<"data">>]})),
    ?assertMatch({ok, [_]}, call(Media, {walk, 1, 3, [<<"raw">>, <<"disk0">>]})).

%% The window's requests the test has been told of so far, in order.
windows() -> receive {window, R} -> [R | windows()] after 200 -> [] end.

next_window() -> receive {window, R} -> R after ?BOUND -> none end.

last_window() -> lists:last([none | windows()]).
