%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_core_model_tests).
-moduledoc """
The grant's core, `erx_fs_grant`, with a model keeper, explored over every
order, up to eight events long, of a set of events (docs/design-files.md,
"Verification and testing", "Waiting requests"): two reads that wait, one on each of two fids whose
handles are equal, a write answered at once on the second fid, the keeper
beginning the first read, a flush of the first read, a clunk of the first
fid, a flush of that clunk, a walk that reuses the clunked fid's number, the
keeper's answer to each read, its turn at each flush it was sent, and its
end. After each order the keeper takes every flush and answers what it still
holds, and the properties are checked.

This module is also the tree: one stream file, `s`, whose every open answers
the same handle, whose reads wait at the keeper and whose writes are answered
at once; its `clunk` counts its calls in the process dictionary.
""".

-include_lib("eunit/include/eunit.hrl").

-export([root/1, walk/3, getattr/2, open/3, read/4, write/4, readdir/4, statfs/1, clunk/2]).

-define(NOFID, 16#ffffffff).
-define(O_RDWR, 2).
-define(DEPTH, 8).
-define(EVENTS, [read2, read3, write3, begin2, flush2, clunk2, flush_clunk, walk,
                 {answer, read2}, {answer, read3}, deliver, keeper_down]).

every_order_of_the_events_keeps_the_waiting_rules_test_() ->
    {timeout, 300, fun() -> explore(?DEPTH, start(), []) end}.

%% The tree --------------------------------------------------------------

root(_) -> {ok, <<"test">>, root, {16#80, 0, 1}}.
walk(root, <<"s">>, _) -> {ok, s, {0, 0, 2}};
walk(_, _, _) -> {error, enoent}.
getattr(_, _) -> {ok, #{mode => 8#100666, size => 0}}.
open(s, _, _) -> {ok, stream}.
read(stream, _, Count, Keeper) -> {wait, Keeper, {read, Count}}.
write(stream, Offset, Data, _) -> {ok, byte_size(Data), Offset}.
readdir(_, _, _, _) -> {ok, []}.
statfs(_) -> {error, enotsup}.
clunk(stream, _) ->
    put(clunks, get(clunks) + 1),
    ok.

%% The world -------------------------------------------------------------

%% A grant with fids 2 and 3 opened on the stream, and an empty record of what
%% happened: the alias of each event's frame, every reply in order, the requests
%% the keeper holds (each by its keeper alias, waiting or begun), the flushes
%% sent to it not yet taken and every flush sent to it, the events used, and the reads begun.
start() ->
    put(clunks, 0),
    Keeper = spawn(fun() -> ok end),
    {ok, Core} = erx_fs_grant:new(#{module => ?MODULE, fs => {ok, Keeper}, rights => rw, client => own}),
    World = #{core => Core, keeper => Keeper, sent => #{}, replies => [], held => #{},
              inbox => [], flushed => [], used => [], begun => [], clunks => 0},
    lists:foldl(fun(Request, W) -> frame(none, Request, W) end, World,
                [{attach, 1, ?NOFID, <<"u">>, <<"test">>, 0},
                 {walk, 1, 2, [<<"s">>]}, {walk, 1, 3, [<<"s">>]},
                 {lopen, 2, ?O_RDWR}, {lopen, 3, ?O_RDWR}]).

explore(0, World, Trace) ->
    check(settle(World), Trace);
explore(Depth, World, Trace) ->
    check(settle(World), Trace),
    [explore(Depth - 1, event(Event, World), [Event | Trace])
     || Event <- ?EVENTS, enabled(Event, World)],
    ok.

enabled(deliver, #{inbox := Inbox}) -> Inbox =/= [];
enabled(Event, #{used := Used} = World) -> not lists:member(Event, Used) andalso ready(Event, World).

ready(begin2, World) -> held_state(read2, World) =:= waiting;
ready({answer, Name}, World) -> held_state(Name, World) =/= none;
ready(flush2, #{sent := Sent}) -> is_map_key(read2, Sent);
ready(flush_clunk, #{sent := Sent}) -> is_map_key(clunk2, Sent);
ready(_, _) -> true.

%% Whether the keeper holds the read Name, and if it does whether it began it.
held_state(Name, #{held := Held}) ->
    case [State || _ := {N, State} <- Held, N =:= Name] of
        [State] -> State;
        [] -> none
    end.

event(Event, #{used := Used} = World) ->
    happen(Event, World#{used := [Event | Used]}).

happen(read2, World) -> frame(read2, {read, 2, 0, 8}, World);
happen(read3, World) -> frame(read3, {read, 3, 0, 8}, World);
happen(write3, World) ->
    %% The other fid's requests run while a clunk waits: answered in their step.
    #{replies := Replies} = World1 = frame(write3, {write, 3, 0, <<"w">>}, World),
    ?assertEqual({ok, 1, 0}, reply_to(write3, World1)),
    ?assertEqual(length(maps:get(replies, World)) + 1, length(Replies)),
    World1;
happen(begin2, #{held := Held, begun := Begun} = World) ->
    [Ref] = [R || R := {read2, waiting} <- Held],
    World#{held := Held#{Ref := {read2, begun}}, begun := [read2 | Begun]};
happen(flush2, #{sent := #{read2 := Read}} = World) -> frame(flush2, {flush, Read}, World);
happen(clunk2, #{held := Held} = World) ->
    %% A clunk sends its keeper a flush of each request of its fid it holds.
    #{flushed := Flushed} = World1 = frame(clunk2, {clunk, 2}, World),
    ?assertEqual([], [Ref || Ref := {read2, _} <- Held, not lists:member(Ref, Flushed)]),
    World1;
happen(flush_clunk, #{sent := #{clunk2 := Clunk}} = World) -> frame(flush_clunk, {flush, Clunk}, World);
happen(walk, World) ->
    %% A walk to the clunked fid's number fails while the number is alive and
    %% succeeds once the clunk is answered.
    Expected = case reply_to(clunk2, World) of
                   none -> {error, einval};
                   _ -> {ok, []}
               end,
    World1 = frame(walk, {walk, 1, 2, []}, World),
    ?assertEqual(Expected, reply_to(walk, World1)),
    World1;
happen({answer, Name}, #{held := Held} = World) ->
    [Ref] = [R || R := {N, _} <- Held, N =:= Name],
    keeper_answers(Ref, {ok, <<"k">>}, World);
happen(deliver, #{inbox := [Ref | Rest], held := Held} = World) ->
    %% The keeper answers a waiting request eintr at its flush; a begun one is
    %% answered when its effect ends, and one already answered needs nothing.
    case Held of
        #{Ref := {_, waiting}} -> keeper_answers(Ref, {error, eintr}, World#{inbox := Rest});
        #{} -> World#{inbox := Rest}
    end;
happen(keeper_down, #{held := Held, keeper := Keeper} = World) ->
    lists:foldl(fun(Ref, W) -> perform(erx_fs_grant:down(Ref, Keeper, core(W)), none, W) end,
                World#{held := #{}, inbox := []}, lists:sort(maps:keys(Held))).

keeper_answers(Ref, Result, #{held := Held, inbox := Inbox} = World) ->
    W = World#{held := maps:remove(Ref, Held), inbox := Inbox -- [Ref]},
    perform(erx_fs_grant:answered(Ref, Result, core(W)), none, W).

%% Every flush the keeper was sent is taken, then every request it still holds
%% is answered.
settle(#{inbox := [_ | _]} = World) ->
    settle(happen(deliver, World));
settle(#{held := Held} = World) when map_size(Held) > 0 ->
    settle(keeper_answers(lists:min(maps:keys(Held)), {ok, <<"k">>}, World));
settle(World) ->
    World.

%% The shell -------------------------------------------------------------

frame(Name, Request, #{sent := Sent} = World) ->
    Alias = make_ref(),
    Named = case Name of
                none -> World;
                _ -> World#{sent := Sent#{Name => Alias}}
            end,
    perform(erx_fs_grant:handle_frame({erx_9p, Alias, self(), Request}, core(Named)), Name, Named).

%% The core's effects, performed as erx_fs performs them; a flush reaches the
%% keeper only for a request it holds. A step that ran the tree's clunk ran it
%% after the first fid's read was answered.
perform({Effects, Core}, _, World) ->
    Done = lists:foldl(fun effect/2, World#{core := Core}, Effects),
    Clunks = get(clunks),
    case Clunks > maps:get(clunks, World) of
        true -> ?assertNotEqual(none, read_settled(Done));
        false -> ok
    end,
    Done#{clunks := Clunks}.

effect({reply, Alias, Reply}, #{replies := Replies} = World) ->
    World#{replies := Replies ++ [{Alias, Reply}]};
effect({monitor, Pid}, World) ->
    World#{core := erx_fs_grant:monitored(Pid, make_ref(), core(World))};
effect({demonitor, _}, World) ->
    World;
effect({wait, Alias, _, {read, _}}, #{held := Held, sent := Sent} = World) ->
    [Name] = [N || N := A <- Sent, A =:= Alias],
    Ref = make_ref(),
    World#{core := erx_fs_grant:waiting(Alias, Ref, core(World)), held := Held#{Ref => {Name, waiting}}};
effect({flush, _, Ref}, #{held := Held, inbox := Inbox, flushed := Flushed} = World) ->
    ?assert(is_map_key(Ref, Held)),
    World#{inbox := Inbox ++ [Ref], flushed := [Ref | Flushed]}.

%% The world's core, about to be called: the tree's count of clunks is set to the
%% world's, since the exploration returns to earlier worlds.
core(#{core := Core, clunks := Clunks}) ->
    put(clunks, Clunks),
    Core.

%% The properties ----------------------------------------------------------

check(#{sent := Sent, replies := Replies, begun := Begun} = World, Trace) ->
    try
        %% Every request is answered exactly once.
        [?assertEqual({Name, 1}, {Name, length([R || {A, R} <- Replies, A =:= Alias])})
         || Name := Alias <- Sent],
        %% A flush is answered after its request, the clunk's after the clunk.
        [?assert(position(Of, World) < position(Flush, World))
         || {Flush, Of} <- [{flush2, read2}, {flush_clunk, clunk2}], is_map_key(Flush, Sent)],
        %% A clunk is answered after its fid's read sent before it.
        [?assert(position(read2, World) < position(clunk2, World))
         || sent_before(read2, clunk2, World)],
        %% Each fid's clunk runs once: the first fid's, if it was clunked.
        ?assertEqual(length([clunk2 || is_map_key(clunk2, Sent)]), maps:get(clunks, World)),
        %% A clunk of one fid answers no request of the other, and a begun
        %% request is answered only with the keeper's answer or eio.
        [?assert(lists:member(reply_to(Name, World), [{ok, <<"k">>}, {error, eio}]))
         || Name <- [read3 | Begun], is_map_key(Name, Sent)]
    catch
        error:Failure -> erlang:error({Failure, lists:reverse(Trace)})
    end.

reply_to(Name, #{sent := Sent, replies := Replies}) ->
    case [R || {A, R} <- Replies, A =:= maps:get(Name, Sent, none)] of
        [Reply | _] -> Reply;
        [] -> none
    end.

%% The first fid's read's reply, none while it waits; read_settled is answered
%% for a read never sent too.
read_settled(#{sent := Sent} = World) when is_map_key(read2, Sent) -> reply_to(read2, World);
read_settled(_) -> settled.

position(Name, #{sent := Sent, replies := Replies}) ->
    #{Name := Alias} = Sent,
    length(lists:takewhile(fun({A, _}) -> A =/= Alias end, Replies)).

sent_before(First, Second, #{used := Used}) ->
    lists:member(First, Used) andalso lists:member(Second, Used)
        andalso length(lists:takewhile(fun(E) -> E =/= First end, Used))
                > length(lists:takewhile(fun(E) -> E =/= Second end, Used)).
