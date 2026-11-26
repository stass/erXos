%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random sequences of messages through erx_fs_grant, the pure core of one erx_fs grant,
%% over erx_fs_test_tree: valid requests on a few fids and names of the tree, requests with
%% one field replaced, arbitrary terms, frames whose alias or owner belongs to another
%% domain, frames in another domain's envelope or bare, flushes, owners going down, and
%% the answers and ends of the keepers that hold waiting requests, with now and then an
%% answer or a DOWN of no request held. A sequence's grant serves the server's own domain
%% or another, ?CLIENT, whose frames arrive in its envelope, {erx_origin, ?CLIENT, Frame},
%% with names of its node, as edit 16 delivers them; erx_dist's stand-in reads a name's
%% domain as the BIF does.
%%
%% The grant's tree is this module: its callbacks pass every call on to erx_fs_test_tree,
%% but a third of its reads and writes answer {wait, Keeper, Request}, where Keeper is one
%% of the sequence's two keepers or, now and then, the grant itself or a process of another
%% node, which the core must answer eio. A shell here performs the core's effects as erx_fs
%% does, with references of its own in place of monitors, and holds each request handed to
%% a keeper until a later step answers it, validly or not, or ends its keeper.
%%
%% Whatever arrives, the core never raises, and:
%% * a reply goes only to an alias of the client's domain whose frame, in the client's
%%   envelope or bare for the server's own domain, awaits one, and
%%   decode_reply/2 accepts it for that frame's request (an error reply, for a frame the
%%   grammar refused); the core runs the same check before it replies, so what this adds
%%   is the alias, the count and the order: a flush answered ok comes after what it flushed,
%%   unless what it flushed is a flush, of which a flush is answered at once;
%% * a frame sent to an alias that still awaits its reply, and a second flush of an alias
%%   whose first flush still waits, are dropped: nothing answers them;
%% * a clunk or a remove answered other than ebadf is answered when no request of its fid
%%   is held at a keeper;
%% * a wait names one of the sequence's keepers, a process of this node that is not the
%%   grant; a flush the core admits for a request a keeper holds goes to that keeper, under
%%   the request's reference, a flush goes to a keeper only for a request it holds, and
%%   once for each;
%% * a keeper's answer to a request it holds answers the request once: with the answer
%%   when the grammar accepts it for the request, eio when not; a keeper's end answers each
%%   request it held eio once; an answer to no request held answers nothing and counts as
%%   refused, and a DOWN of no monitor answers nothing;
%% * the fids stay within the pool, the owners within the fids, the requests in flight
%%   within 64, the grant's owners are exactly the owners the shell holds a monitor for,
%%   and the requests it reports waiting are exactly those the shell holds at keepers;
%% * at the end of a sequence, with every owner down and every request at a keeper answered
%%   or its keeper ended, every frame that awaits a reply has had exactly one, and the
%%   grant holds nothing, no live alias included.
%% The seed comes from make check-fuzz. tools/fuzz/erx_fs_grant.rb also seeds six faults in
%% the core, each of which these checks must catch within the seed's sequences: a pool
%% admitting one fid more, a grant taking any domain's names for another domain's, a flush
%% kept from the keeper that holds its request, a grant that checks only requests' aliases,
%% a second flush answered ok at once, and a clunk that runs without flushing its fid's waits.

-module(erx_fs_grant_fuzz).
-export([run/1]).
%% The tree's callbacks, as erx_fs_test_tree exports them.
-export([root/1, walk/3, getattr/2, open/3, read/4, readdir/4, readlink/2, statfs/1, clunk/2,
         write/4, make/4, setattr/3, unlink/4, rename/5]).

-define(G, erx_9p_grammar).
-define(CORE, erx_fs_grant).
-define(TREE, erx_fs_test_tree).
-define(SEQUENCES, 30000).
-define(STEPS, 60).
-define(IN_FLIGHT_MAX, 64).
-define(FOREIGN, <<"other@far">>).
%% Another domain a grant may serve, and a third domain, as their names carry them.
-define(CLIENT, 5).
-define(THIRD, 9).
-define(DOMAIN_NODE, <<"d@erxos11">>).

%% The shell's view of one sequence: the core, the domain the grant serves, the owners and
%% keepers its frames and tree name, the frames each of that domain's aliases awaits a
%% reply for (each numbered in the order sent) and the replies it has had, the monitor it
%% holds for each owner, each request held at a keeper by the reference of its wait, with
%% the keeper, the alias and the request, the references of the waits already settled, and
%% those of the waits a flush was sent for.
-record(shell, {core, client, owners, keepers, awaited = #{}, replies = #{}, sent = 0,
                monitors = #{}, held = #{}, settled = [], flushed = [], aliases = [], pool,
                tally = #{}}).

run([Seed]) ->
    rand:seed(exsss, {16#f5, 16#9a, list_to_integer(Seed)}),
    Tally = lists:foldl(fun(_, T) -> sequence(T) end, #{}, lists:seq(1, ?SEQUENCES)),
    io:format("fuzz: ~p sequences ok~n", [?SEQUENCES]),
    [io:format("~p ~p: ~p~n", [Op, Outcome, N]) || {Op, Outcome} := N <- maps:iterator(Tally, ordered)],
    ok.

sequence(Tally) ->
    {ok, #{tree := Tree} = Fs} = ?TREE:init([]),
    Client = pick([own, ?CLIENT]),
    Owners = owners(Client),
    Keepers = [spawn_link(fun idle/0) || _ <- [1, 2]],
    Pool = pick([1, 2, 3, 8, 4096]),
    {ok, Core} = ?CORE:new(#{module => ?MODULE, fs => {ok, {Fs, Keepers}}, rights => pick([ro, rw, rx]),
                             client => Client, pool => Pool}),
    Shell = #shell{core = Core, client = Client, owners = Owners, keepers = Keepers, pool = Pool,
                   tally = Tally},
    %% Most sequences open as a client does, so later requests find a session and a fid,
    %% and half of them open a file on fid 1, so reads and writes reach a keeper.
    Session = [{version, 8192, <<"9P2000.L">>}, {attach, 0, 16#ffffffff, <<"u">>, <<"test">>, 0}],
    Prologue = case rand:uniform(4) of
                   1 -> [];
                   2 -> Session;
                   _ -> Session ++ [{walk, 0, 1, [<<"f">>]}, {lopen, 1, pick([0, 1, 2])}]
               end,
    Opened = lists:foldl(fun(Request, S) -> checked(frame(delivered(request_frame(Request, S), S), S)) end,
                         Shell, Prologue),
    Steps = lists:foldl(fun(_, S) -> checked(step(S)) end, Opened,
                        lists:seq(1, rand:uniform(?STEPS))),
    Counted = finished(Steps),
    [begin unlink(Pid), exit(Pid, kill) end
     || Pid <- [Tree | Owners ++ Keepers], Pid =/= self(), node(Pid) =:= node()],
    Counted.

idle() ->
    receive stop -> ok end.

%% The owners a sequence's frames name: this test and two idle processes for the
%% server's own domain, and three pids of the client's node for another domain.
owners(own) -> [self() | [spawn_link(fun idle/0) || _ <- [1, 2]]];
owners(Client) -> [domain_pid(Client, N) || N <- [1, 2, 3]].

step(Shell) ->
    case rand:uniform(24) of
        N when N =< 13 -> frame(delivered(request_frame(request(Shell), Shell), Shell), Shell);
        14 -> frame(delivered(request_frame(mutated(request(Shell)), Shell), Shell), Shell);
        15 -> frame(odd_frame(Shell), Shell);
        16 -> owner_down(Shell);
        N when N =< 19 -> answer(Shell);
        20 -> keeper_down(Shell);
        21 -> stray_answer(Shell);
        22 -> stray_down(Shell);
        _ -> flush_held(Shell)
    end.

%% One message to the core, with what the shell expects back for it.
frame(Frame, #shell{core = Core} = Shell) ->
    {Effects, Core1} = ?CORE:handle_frame(Frame, Core),
    Expected = expected(Frame, Shell),
    forwarded(Frame, Expected, Effects, Shell),
    effects(Effects, expect(Expected, Effects, Shell#shell{core = Core1})).

%% What the shell expects of a frame: a reply to its alias, nothing for one the core may
%% not answer, or that the core drops it, unanswered, for an alias that awaits a reply
%% already, or as a second flush, the core admits, of an alias whose first flush still
%% waits.
expected(Message, #shell{client = Client} = Shell) ->
    Ours = fun(Alias) -> of_client(Alias, Client) end,
    case ?G:decode_request_frame(frame_of(Message, Client)) of
        {ok, Alias, Owner, Request} ->
            %% A flush whose owner is not the client's is refused before it is looked at.
            Ours(Alias) andalso
                case live(Alias, Shell) orelse Ours(Owner) andalso second_flush(Request, Shell) of
                    true -> {dropped, Alias};
                    false -> {Alias, {request, Request}}
                end;
        {error, Alias, _} ->
            Ours(Alias) andalso
                case live(Alias, Shell) of
                    true -> {dropped, Alias};
                    false -> {Alias, refused}
                end;
        error ->
            false
    end.

%% Whether Alias awaits the reply to a frame of its.
live(Alias, #shell{awaited = Awaited, replies = Replies}) ->
    length(maps:get(Alias, Awaited, [])) > length(maps:get(Alias, Replies, [])).

%% Whether a flush names a live alias that a live flush already names: that flush waits
%% for it, since a flush stays unanswered only while what it names does.
second_flush({flush, Old}, #shell{awaited = Awaited} = Shell) ->
    live(Old, Shell) andalso
        lists:any(fun({Alias, Frames}) ->
                          live(Alias, Shell) andalso element(2, lists:last(Frames)) =:= {request, {flush, Old}}
                  end, maps:to_list(Awaited));
second_flush(_, _) ->
    false.

expect({dropped, Alias}, Effects, Shell) ->
    [R || {reply, A, R} <- Effects, A =:= Alias] =:= []
        orelse error({check_failed, dropped_frame_answered, Alias, Effects}),
    counted(dropped, Shell);
expect(Expected, _, #shell{awaited = Awaited} = Shell) ->
    case Expected of
        {A, What} ->
            Sent = Shell#shell.sent,
            Shell#shell{awaited = Awaited#{A => maps:get(A, Awaited, []) ++ [{Sent, What}]},
                        sent = Sent + 1, aliases = [A | Shell#shell.aliases]};
        false ->
            Shell
    end.

%% A flush of the client's that the core holds rather than answers, for a request a keeper
%% holds, goes on to that keeper in the same step.
forwarded(_, {dropped, _}, _, _) ->
    true;
forwarded(Frame, _, Effects, #shell{client = Client, held = Held, flushed = Flushed}) ->
    case ?G:decode_request_frame(frame_of(Frame, Client)) of
        {ok, Alias, _, {flush, Old}} ->
            Flushes = [{flush, Keeper, Ref} || Ref := {Keeper, A, _} <- Held, A =:= Old,
                                               not lists:member(Ref, Flushed)],
            Answered = [Reply || {reply, A, Reply} <- Effects, A =:= Alias] =/= [],
            Forwarded = not of_client(Alias, Client) orelse Answered orelse Flushes -- Effects =:= [],
            Forwarded orelse error({check_failed, flush_kept_from_keeper, Old, Flushes, Effects});
        _ ->
            true
    end.

%% The core's effects, performed in order as erx_fs performs them.
effects([], Shell) ->
    Shell;
effects([{reply, Alias, Reply} | Rest], Shell) ->
    effects(Rest, replied(Alias, Reply, Shell));
effects([{monitor, Owner} | Rest], #shell{core = Core, monitors = Monitors} = Shell) ->
    is_map_key(Owner, Monitors) andalso error({monitored_twice, Owner}),
    Ref = make_ref(),
    effects(Rest, Shell#shell{core = ?CORE:monitored(Owner, Ref, Core),
                              monitors = Monitors#{Owner => Ref}});
effects([{demonitor, Ref} | Rest], #shell{monitors = Monitors} = Shell) ->
    case [Owner || Owner := R <- Monitors, R =:= Ref] of
        [Owner] -> effects(Rest, Shell#shell{monitors = maps:remove(Owner, Monitors)});
        [] -> error({demonitor_of_no_monitor, Ref})
    end;
%% A request goes only to one of the sequence's keepers, as the tree's request for its
%% client's read or write, and is held there under a reference of its own.
effects([{wait, Alias, Keeper, Request} | Rest], #shell{core = Core, held = Held} = Shell) ->
    lists:member(Keeper, Shell#shell.keepers) orelse error({check_failed, wait_at_no_keeper, Keeper}),
    {_, {request, Asked}} = lists:last(maps:get(Alias, Shell#shell.awaited)),
    element(1, Asked) =:= element(1, Request) orelse error({check_failed, wait_for_another_request, Asked, Request}),
    Ref = make_ref(),
    effects(Rest, counted({keeper, held}, Shell#shell{core = ?CORE:waiting(Alias, Ref, Core),
                                                      held = Held#{Ref => {Keeper, Alias, Asked}}}));
effects([{flush, Keeper, Ref} | Rest], #shell{held = Held, flushed = Flushed} = Shell) ->
    lists:member(Ref, Flushed) andalso error({check_failed, flushed_twice, Keeper, Ref}),
    case Held of
        #{Ref := {Keeper, _, _}} ->
            effects(Rest, counted({keeper, flushed}, Shell#shell{flushed = [Ref | Flushed]}));
        #{} ->
            error({check_failed, flush_of_no_held_request, Keeper, Ref})
    end;
effects([Effect | _], _) ->
    error({unexpected_effect, Effect}).

%% A client may send several frames with one alias, and their replies carry nothing else
%% that tells them apart, so the replies an alias has had must match its frames one to
%% one in some order, each valid for the frame it matches.
%% A flush answered ok comes after the replies of every frame it may have flushed: those
%% sent with its old tag before it (docs/design-files.md, flush), unless the last of them
%% is a flush, which a flush of answers at once.
replied(Alias, Reply, #shell{awaited = Awaited, replies = Replies} = Shell) ->
    Waiting = [What || {_, What} <- maps:get(Alias, Awaited, [])],
    Had = [Reply | maps:get(Alias, Replies, [])],
    matched(Had, Waiting) orelse error({check_failed, unexpected_reply, Alias, Reply, Waiting}),
    Flushes = [{Sent, Old} || {Sent, {request, {flush, Old}}} <- maps:get(Alias, Awaited, []), Reply =:= ok],
    Flushes =:= [] orelse lists:any(fun({Sent, Old}) -> flushed_after(Old, Sent, Shell) end, Flushes)
        orelse lists:any(fun({Sent, Old}) -> of_a_flush(Old, Sent, Shell) end, Flushes)
        orelse error({check_failed, flush_answered_first, Alias, Flushes}),
    [What | _] = [W || W <- Waiting, valid_reply(W, Reply)],
    settled_fid(lists:last(Waiting), Reply, Shell),
    Key = {case What of {request, R} -> element(1, R); refused -> refused end, outcome(Reply)},
    counted(Key, Shell#shell{replies = Replies#{Alias => Had}}).

%% A clunk or a remove that ended its fid is answered once no request of the fid is held;
%% one answered ebadf named no fid, or a closing one, and one answered einval or erofs
%% may have been refused before the core looked at the fid, for an owner of another
%% domain or a remove on a read-only grant, which a fid the core does not hold answers.
settled_fid({request, {Ends, Fid}}, Reply, #shell{held = Held})
  when (Ends =:= clunk orelse Ends =:= remove),
       not (Reply =:= {error, ebadf} orelse Reply =:= {error, einval} orelse Reply =:= {error, erofs}) ->
    Waiting = [Asked || _ := {_, _, Asked} <- Held, element(2, Asked) =:= Fid],
    Waiting =:= [] orelse error({check_failed, clunk_before_its_fids_requests, Fid, Reply, Waiting});
settled_fid(_, _, _) ->
    true.

of_a_flush(Old, Sent, #shell{awaited = Awaited}) ->
    case [What || {S, What} <- maps:get(Old, Awaited, []), S < Sent] of
        [_ | _] = Before ->
            case lists:last(Before) of
                {request, {flush, _}} -> true;
                _ -> false
            end;
        [] ->
            false
    end.

flushed_after(Old, Sent, #shell{awaited = Awaited, replies = Replies}) ->
    Before = [S || {S, _} <- maps:get(Old, Awaited, []), S < Sent],
    length(maps:get(Old, Replies, [])) >= length(Before).

%% Whether each reply has a frame of its own among Waiting that it is valid for.
matched([], _) ->
    true;
matched([Reply | Rest], Waiting) ->
    lists:any(fun(What) -> valid_reply(What, Reply) andalso matched(Rest, Waiting -- [What]) end,
              Waiting).

valid_reply({request, Request}, Reply) ->
    ?G:decode_reply(Request, Reply) =:= {ok, Reply};
valid_reply(refused, {error, _} = Reply) ->
    ?G:decode_reply({clunk, 0}, Reply) =:= {ok, Reply};
valid_reply(refused, _) ->
    false.

%% A keeper's answer to a request it holds: one its tree might give, eintr as for a
%% flushed request, or one that is none of the callback's shapes or breaks the grammar.
answer(#shell{held = Held} = Shell) when map_size(Held) =:= 0 ->
    frame(delivered(request_frame(request(Shell), Shell), Shell), Shell);
answer(#shell{core = Core, held = Held} = Shell) ->
    Ref = pick(lists:sort(maps:keys(Held))),
    #{Ref := {_, _, Request}} = Held,
    Result = result(Request),
    Reply = case ?G:decode_reply(Request, Result) of
                {ok, Result} -> Result;
                _ -> {error, eio}
            end,
    {Effects, Core1} = ?CORE:answered(Ref, Result, Core),
    settled(Ref, Reply, Effects, counted({keeper, answered}, Shell#shell{core = Core1})).

result({read, _, _, Count}) ->
    pick([{ok, binary:copy(<<"k">>, min(Count, pick([0, 3, 200])))}, {error, eintr}, {error, eagain},
          {ok, 3, 0}, {ok, binary:copy(<<"k">>, min(Count, 300) + 1)}, random_field()]);
result({write, _, Offset, Data}) ->
    pick([{ok, byte_size(Data), Offset}, {error, eintr}, {error, enospc},
          {ok, byte_size(Data) + 1, Offset}, {ok, <<>>}, random_field()]).

%% A keeper's end: the DOWN of the grant's monitor of it for each request it holds.
keeper_down(#shell{keepers = Keepers} = Shell) ->
    Keeper = pick(Keepers),
    Refs = lists:sort([Ref || Ref := {K, _, _} <- Shell#shell.held, K =:= Keeper]),
    lists:foldl(fun(Ref, #shell{core = Core} = S) ->
                        {Effects, Core1} = ?CORE:down(Ref, Keeper, Core),
                        settled(Ref, {error, eio}, Effects, counted({keeper, down}, S#shell{core = Core1}))
                end, Shell, Refs).

%% The effects that settle a request held at a keeper answer its alias exactly once, with
%% Reply, then the flushes that waited on it.
settled(Ref, Reply, Effects, #shell{held = Held, settled = Settled} = Shell) ->
    {{_, Alias, _}, Rest} = maps:take(Ref, Held),
    [R || {reply, A, R} <- Effects, A =:= Alias] =:= [Reply]
        orelse error({check_failed, keeper_answer_not_passed_on, Alias, Reply, Effects}),
    effects(Effects, Shell#shell{held = Rest, settled = [Ref | Settled]}).

%% A flush of a request a keeper holds, which the core sends on to the keeper.
flush_held(#shell{held = Held} = Shell) when map_size(Held) =:= 0 ->
    frame(delivered(request_frame(request(Shell), Shell), Shell), Shell);
flush_held(#shell{held = Held} = Shell) ->
    Old = pick(lists:sort([Alias || _ := {_, Alias, _} <- Held])),
    frame(delivered(request_frame({flush, Old}, Shell), Shell), Shell).

%% An owner's DOWN, with its monitor's reference or, now and then, another one, which
%% changes nothing. Its fids end, and the last one's demonitor removes the shell's monitor.
owner_down(#shell{core = Core, owners = Owners, monitors = Monitors} = Shell) ->
    Owner = pick(Owners),
    Ref = case rand:uniform(4) of
              1 -> make_ref();
              _ -> maps:get(Owner, Monitors, make_ref())
          end,
    {Effects, Core1} = ?CORE:down(Ref, Owner, Core),
    #shell{monitors = After} = Shell1 = effects(Effects, Shell#shell{core = Core1}),
    Gone = maps:get(Owner, Monitors, none) =/= Ref orelse not is_map_key(Owner, After),
    Gone orelse error({check_failed, monitor_kept_after_down, Owner}),
    Shell1.

%% A keeper's answer to no request held: a new reference, or one whose request was settled
%% already. It answers nothing and counts as refused.
stray_answer(#shell{core = Core} = Shell) ->
    Ref = pick([make_ref() | Shell#shell.settled]),
    #{refused := Refused} = ?CORE:info(Core),
    {Effects, Core1} = ?CORE:answered(Ref, pick([{ok, <<"k">>}, {error, eintr}, random_field()]), Core),
    #{refused := Counted} = ?CORE:info(Core1),
    {Effects, Counted} =:= {[], Refused + 1} orelse error({check_failed, stray_answer_taken, Ref, Effects}),
    counted({keeper, stray_answer}, Shell#shell{core = Core1}).

%% A DOWN of no monitor the grant holds, for a keeper's settled request or none, changes
%% nothing.
stray_down(#shell{core = Core} = Shell) ->
    Ref = pick([make_ref() | Shell#shell.settled]),
    Pid = pick(Shell#shell.keepers ++ Shell#shell.owners),
    {Effects, Core1} = ?CORE:down(Ref, Pid, Core),
    Effects =:= [] orelse error({check_failed, stray_down_taken, Ref, Effects}),
    Shell#shell{core = Core1}.

checked(#shell{core = Core, monitors = Monitors, held = Held, pool = Pool} = Shell) ->
    #{fids := Fids, owners := Owners, waiting := Waiting, in_flight := InFlight} = ?CORE:info(Core),
    Bounds = [{fids_within_pool, Fids =< Pool}, {owners_within_fids, Owners =< Fids},
              {in_flight_within_bound, InFlight =< ?IN_FLIGHT_MAX},
              {owners_are_monitored, Owners =:= map_size(Monitors)},
              {waiting_are_held, Waiting =:= map_size(Held)},
              {waiting_within_in_flight, Waiting =< InFlight}],
    case [Name || {Name, false} <- Bounds] of
        [] -> Shell;
        Broken -> error({check_failed, Broken})
    end.

%% Every owner goes down, then every request at a keeper is answered or its keeper ends.
finished(Shell) ->
    Down = lists:foldl(fun(Owner, #shell{core = Core, monitors = Monitors} = S) ->
                               case Monitors of
                                   #{Owner := Ref} ->
                                       {Effects, Core1} = ?CORE:down(Ref, Owner, Core),
                                       effects(Effects, S#shell{core = Core1});
                                   #{} -> S
                               end
                       end, Shell, Shell#shell.owners),
    #shell{core = Core, awaited = Awaited, replies = Replies} = Done = settle_all(Down),
    Info = ?CORE:info(Core),
    Empty = maps:with([fids, owners, waiting, in_flight, aliases], Info) =:=
        #{fids => 0, owners => 0, waiting => 0, in_flight => 0, aliases => 0},
    Empty orelse error({check_failed, held_at_the_end, Info}),
    Unanswered = [{Alias, Waiting} || Alias := Waiting <- Awaited,
                                      length(Waiting) =/= length(maps:get(Alias, Replies, []))],
    Unanswered =:= [] orelse error({check_failed, unanswered, Unanswered}),
    Done#shell.tally.

settle_all(#shell{held = Held} = Shell) when map_size(Held) =:= 0 ->
    Shell;
settle_all(Shell) ->
    settle_all(case rand:uniform(2) of
                   1 -> answer(Shell);
                   2 -> keeper_down(Shell)
               end).

counted(Key, #shell{tally = Tally} = Shell) ->
    Shell#shell{tally = Tally#{Key => maps:get(Key, Tally, 0) + 1}}.

%% The tree's callbacks: erx_fs_test_tree's, on the tree's own handle, but for a third of
%% the reads and writes, which wait at a keeper: mostly one of the sequence's two, now and
%% then the grant itself, which runs the callback, or a process of another node.
root({Fs, _}) -> ?TREE:root(Fs).
walk(Dir, Name, {Fs, _}) -> ?TREE:walk(Dir, Name, Fs).
getattr(Node, {Fs, _}) -> ?TREE:getattr(Node, Fs).
open(Node, Flags, {Fs, _}) -> ?TREE:open(Node, Flags, Fs).
readdir(Handle, Offset, Max, {Fs, _}) -> ?TREE:readdir(Handle, Offset, Max, Fs).
readlink(Node, {Fs, _}) -> ?TREE:readlink(Node, Fs).
statfs({Fs, _}) -> ?TREE:statfs(Fs).
clunk(Handle, {Fs, _}) -> ?TREE:clunk(Handle, Fs).
make(Dir, Name, What, {Fs, _}) -> ?TREE:make(Dir, Name, What, Fs).
setattr(Target, Attr, {Fs, _}) -> ?TREE:setattr(Target, Attr, Fs).
unlink(Dir, Name, Kind, {Fs, _}) -> ?TREE:unlink(Dir, Name, Kind, Fs).
rename(Dir, Name, NewDir, NewName, {Fs, _}) -> ?TREE:rename(Dir, Name, NewDir, NewName, Fs).

read(Handle, Offset, Count, Tree) ->
    may_wait({read, Handle, Offset, Count}, Tree, fun(Fs) -> ?TREE:read(Handle, Offset, Count, Fs) end).

write(Handle, Offset, Data, Tree) ->
    may_wait({write, Handle, Offset, Data}, Tree, fun(Fs) -> ?TREE:write(Handle, Offset, Data, Fs) end).

may_wait(Request, {Fs, Keepers}, Call) ->
    case rand:uniform(3) of
        1 -> {wait, pick(Keepers ++ Keepers ++ [self(), foreign_pid()]), Request};
        _ -> Call(Fs)
    end.

outcome({error, Posix}) -> Posix;
outcome(_) -> ok.

%% A request of the grammar's table on the fids and names a sequence keeps reusing.
request(Shell) ->
    Fid = fid(),
    %% Walks, opens, reads and writes are drawn more often, so sequences reach open files.
    case pick([1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 7, 7, 7, 8, 8, 8, 9, 9, 9, 15, 15, 21, 21 |
               lists:seq(10, 26)]) of
        1 -> {version, pick([4096, 8192, 65560, 4095, 65561]), pick([<<"9P2000.L">>, <<"9P2000">>])};
        2 -> {attach, Fid, 16#ffffffff, <<"u">>, pick([<<"test">>, <<"test">>, <<"tmp">>, <<>>]), 0};
        3 -> {walk, Fid, fid(), [name() || _ <- lists:seq(1, rand:uniform(4) - 1)]};
        4 -> {walk, Fid, fid(), pick([[], [<<"a">>], [<<"f">>], [<<"l">>], [<<"a">>, <<"b">>], [<<"a">>, <<"f">>],
                                     [<<"a">>, <<"..">>, <<"f">>], [<<"n">>], [<<"m">>]])};
        5 -> {lopen, Fid, flags()};
        6 -> {lcreate, Fid, name(), flags(), 8#644, 0};
        7 -> {read, Fid, offset(), count()};
        8 -> {write, Fid, offset(), pick([<<>>, <<"abc">>, binary:copy(<<"x">>, 5000)])};
        9 -> {readdir, Fid, offset(), count()};
        10 -> {getattr, Fid, pick([0, 16#3fff, 16#ffffffffffffffff])};
        11 -> {setattr, Fid, #{valid => pick([0, 1, 8, 9, 16#1ff]), mode => pick([8#644, 8#40755]),
                               uid => 0, gid => 0, size => pick([0, 3, 4097, 16#7fffffffffffffff]), atime_sec => 0,
                               atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0}};
        12 -> {mkdir, Fid, name(), 8#755, 0};
        13 -> {symlink, Fid, name(), pick([<<"a">>, <<"/">>, <<"..">>]), 0};
        14 -> {link, Fid, fid(), name()};
        15 -> {readlink, Fid};
        16 -> {unlinkat, Fid, name(), pick([0, 16#200])};
        17 -> {renameat, Fid, name(), fid(), name()};
        18 -> {statfs, Fid};
        19 -> {fsync, Fid, pick([0, 1])};
        20 -> {flush, pick([make_ref() | Shell#shell.aliases])};
        21 -> {clunk, Fid};
        22 -> {remove, Fid};
        23 -> {mknod, Fid, name(), 8#644, 0, 0, 0};
        24 -> {xattrwalk, Fid, fid(), pick([<<>>, <<"user.a">>])};
        25 -> {xattrcreate, Fid, <<"user.a">>, 0, 0};
        26 -> pick([{lock, Fid, 1, 0, 0, 0, 1, <<"h">>}, {getlock, Fid, 0, 0, 0, 1, <<"h">>}])
    end.

%% A frame with its own owner and alias, of the client's domain, around Request, now and
%% then the same alias as a frame before it, which the core answers once more.
request_frame(Request, Shell) ->
    Alias = case rand:uniform(8) of
                1 when Shell#shell.aliases =/= [] -> pick(Shell#shell.aliases);
                _ -> alias(Shell#shell.client)
            end,
    {erx_9p, Alias, pick(Shell#shell.owners), Request}.

mutated({flush, _} = Request) ->
    setelement(2, Request, random_field());
mutated(Request) ->
    setelement(1 + rand:uniform(tuple_size(Request) - 1), Request, random_field()).

%% A message the client's domain never sends: a frame whose alias or owner is of another
%% domain, an alias that is no reference, an owner that is no pid, the wrong arity, any
%% term, a client's frame in another domain's envelope, or bare from another domain.
odd_frame(#shell{client = Client} = Shell) ->
    {erx_9p, Alias, Owner, Request} = Frame = request_frame(request(Shell), Shell),
    case rand:uniform(8) of
        1 -> delivered({erx_9p, other_alias(Client), Owner, Request}, Shell);
        2 -> delivered({erx_9p, Alias, other_owner(Client), Request}, Shell);
        3 -> delivered({erx_9p, pick([self(), 1, <<>>]), Owner, Request}, Shell);
        4 -> delivered({erx_9p, Alias, pick([Alias, node(), 0]), Request}, Shell);
        5 -> delivered({erx_9p, Alias, Owner}, Shell);
        6 -> pick([random_field(), {erx_9p}, {Alias, Request}, Request]);
        7 -> {erx_origin, pick([0, 1, 7, ?THIRD]), Frame};
        8 when Client =:= own -> {erx_origin, ?CLIENT, Frame};
        8 -> Frame
    end.

%% Message as the grant receives Frame from the client's domain: bare from the server's
%% own, in the envelope of edit 16 from another.
delivered(Frame, #shell{client = own}) -> Frame;
delivered(Frame, #shell{client = Client}) -> {erx_origin, Client, Frame}.

%% The frame inside a message the client's domain sent, or none for any other message.
frame_of({erx_origin, Client, Frame}, Client) when is_integer(Client) -> Frame;
frame_of({erx_origin, _, _}, _) -> none;
frame_of(Frame, own) -> Frame;
frame_of(_, _) -> none.

%% Whether a frame's alias is of the client's domain: of this node for the server's own,
%% of the client's id, as erx_dist reads it, for another.
of_client(Alias, own) -> node(Alias) =:= node();
of_client(Alias, Client) -> erx_dist:owner(Alias) =:= Client.

%% A fresh alias of the client's domain.
alias(own) -> make_ref();
alias(Client) -> domain_ref(Client).

%% An alias and an owner that are not the client domain's.
other_alias(own) -> pick([foreign_ref(), domain_ref(?THIRD)]);
other_alias(_) -> pick([foreign_ref(), domain_ref(?THIRD), make_ref()]).

other_owner(own) -> pick([foreign_pid(), domain_pid(?THIRD, 1)]);
other_owner(_) -> pick([foreign_pid(), domain_pid(?THIRD, 1), self()]).


fid() ->
    pick([0, 0, 0, 1, 1, 1, 2, 2, 3, 16#fffffffe, 16#ffffffff]).

name() ->
    pick([<<"a">>, <<"b">>, <<"f">>, <<"l">>, <<"..">>, <<"n">>, <<"m">>, <<".">>, <<>>, <<"a/b">>]).

flags() ->
    pick([0, 1, 2, 8#100, 8#101, 8#302, 8#1001, 8#2001, 8#200000, 3]).

offset() ->
    pick([0, 0, 1, 3, 4096, 16#7fffffffffffffff, 16#ffffffffffffffff]).

count() ->
    pick([0, 1, 24, 64, 300, 4096, 65536, 16#ffffffff]).

random_field() ->
    case rand:uniform(7) of
        1 -> pick([0, 1, -1, 16#ffffffff, 16#100000000, 16#ffffffffffffffff, 1 bsl 64]);
        2 -> name();
        3 -> binary:copy(<<"n">>, pick([255, 256, 65537]));
        4 -> [name() || _ <- lists:seq(1, pick([0, 1, 16, 17]))];
        5 -> make_ref();
        6 -> pick([ok, error, enoent, 1.5, [], {}, #{}, self()]);
        7 -> {pick([read, walk, ok]), random_term()}
    end.

random_term() ->
    pick([{0, 0, 0}, [1], #{valid => 1}, <<0>>, foreign_pid()]).

%% A pid and a reference of another node, built from their external formats
%% (NEW_PID_EXT and NEWER_REFERENCE_EXT) with a node name of SMALL_ATOM_UTF8_EXT.
foreign_pid() ->
    binary_to_term(<<131, 88, 119, (byte_size(?FOREIGN)), ?FOREIGN/binary, 1:32, 0:32, 1:32>>).

foreign_ref() ->
    binary_to_term(<<131, 90, 3:16, 119, (byte_size(?FOREIGN)), ?FOREIGN/binary, 1:32,
                     (rand:uniform(1000)):32, 0:32, 0:32>>).

%% A pid and a reference of domain D's node, whose creation is the domain id; each
%% reference is new.
domain_pid(D, N) ->
    binary_to_term(<<131, 88, 119, (byte_size(?DOMAIN_NODE)), ?DOMAIN_NODE/binary, N:32, 0:32, D:32>>).

domain_ref(D) ->
    Id = erlang:unique_integer([positive]) band 16#ffffffff,
    binary_to_term(<<131, 90, 3:16, 119, (byte_size(?DOMAIN_NODE)), ?DOMAIN_NODE/binary, D:32,
                     1:32, Id:32, 0:32>>).

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
