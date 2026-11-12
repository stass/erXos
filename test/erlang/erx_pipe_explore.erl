%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pipe_explore).
-moduledoc """
The exhaustive exploration of the pipe server's decisions, erx_pipe:step/2
(docs/design-pipes.md, "The pipe core" and "Verification and testing").
It drives one session's records, with the design's limits scaled down,
through every order of the first tier's events by three holders, two
programs and a session process, up to a depth or to completion:

* `{pipe, H, []}` by each holder;
* for every end ever made: `{inherit, H, Pipe, End, Child}` by its holder
  for each child and by every other holder (forged), and `{closed, ...}`
  and `{install_failed, ...}` by every holder, so by its own, by the
  others (forged) and again once the end is gone (repeated);
* for every read end ever made and every write end of its pipe:
  `{drained, ...}` by every holder, due or not;
* `{gone, H}` for each holder.

Notices naming numbers that were never made are EUnit cases
(erx_pipe_tests), since every number is only looked up.

Beside the records the exploration keeps a model of the world the
actions build: the objects the server holds, and for every end it handed
out, its holder and the copies, rights included, and the peers that
holder was told of, built only from the replies and reports the step
returned, as the handlers and liberx would. After every event it checks
the properties of `properties/0`; the first one to fail ends the run with
its name, what it found and the shortest trace that reaches it.

The exploration is breadth-first, and a state (records and model) seen
before is not explored again, until no new state appears or the depth
limit is reached. `hits` counts the cases each run must reach, so that a
property is not vacuous.
""".

-export([explore/1, properties/0]).

-include("generated/erx_abi.hrl").

-define(R, ?ERX_HR_READ).
-define(W, ?ERX_HR_WRITE).
-define(T, ?ERX_HR_TRIGGER).

-define(LIMITS, #{quota => 2, number_max => 4, readers_max => 2}).

-doc "The properties checked after every event.".
-spec properties() -> [atom()].
properties() ->
    [known_actions,               % every action is one of the moduledoc's
     makes_first,                 % every make comes before every other action
     made_once,                   % no object is made twice, numbers never reused
     closes_only_live,            % the server closes only what it holds
     names_only_live,             % a reply or report names only objects the server holds
     doorbell_in_holders_group,   % an end's doorbell is bound to its holder's group
     wends_before_install,        % a write end's number is in wends before it is named
     reports_reach_holders,       % a report goes only to the holder of the end it names
     told_once,                   % a peer is told of a join or a gone once
     forged_changes_nothing,      % a notice not from the end's holder, or not due, changes
                                  % nothing, the counters of numbers included
     refused_only_at_limits,      % enfile and emfile only at a limit, every number within it
     lock_freed_by_its_reader,    % a read end that goes frees the lock once, by its own index
     one_holder,                 % PI1: the records' ends are the ends handed out, each to its holder
     holders_hold_what_they_need, % every holder holds exactly its end's copies, with their rights
     server_holds_exactly,        % the server holds exactly the objects its records name
     readers_know_writers,        % PI2: a read end knows every writer, open or gone, it must drain
     writers_know_readers,        % PI3: a write end knows exactly the read ends that remain
     lanes_counted,               % the quota counts every lane, and no more lanes than it
     wends_stored].               % the lock page's wends is every pipe's highest write end

-doc """
Explores to `depth` events, or until no new state appears (`infinity`
or a depth past it), with the scaled limits of `limits`, all three of
erx_pipe:new/1's options. Returns the depth reached, whether the
exploration completed, the states and transitions explored and the hits,
or the first violation with its trace.
""".
-spec explore(#{depth := pos_integer() | infinity,
                limits => #{quota := pos_integer(), number_max := pos_integer(),
                            readers_max := pos_integer()}}) ->
          {ok, map()} | {violation, atom(), term(), [term()]}.
explore(#{depth := Depth} = Opts) ->
    Limits = maps:get(limits, Opts, ?LIMITS),
    World = #{s => erx_pipe:new(Limits), model => model0(), holders => holders(),
              limits => Limits},
    try
        bfs([{World, []}], #{key(World) => true}, 0, Depth, #{}, 0)
    catch
        throw:{violation, Name, Found, Trace} -> {violation, Name, Found, Trace}
    end.

holders() ->
    [{program, 1}, {program, 2}, {process, self()}].

model0() ->
    #{live => #{}, made => #{}, bells => #{}, wends => #{}, ends => #{},
      issued => #{}, lanes => #{}}.

%% A state's identity for merging. `made` is left out: the objects ever
%% made follow from the pipes' counters in the records, the ends issued
%% and the lanes ever made, which the key keeps.
key(#{s := S, model := Model}) ->
    {S, maps:without([made], Model)}.

bfs([], Seen, Depth, _Max, Hits, Transitions) ->
    {ok, #{depth => Depth, states => map_size(Seen), transitions => Transitions,
           hits => Hits, complete => true}};
bfs(_Frontier, Seen, Depth, Max, Hits, Transitions) when Depth >= Max ->
    {ok, #{depth => Depth, states => map_size(Seen), transitions => Transitions,
           hits => Hits, complete => false}};
bfs(Frontier, Seen0, Depth, Max, Hits0, Transitions0) ->
    {Next, Seen, Hits, Transitions} =
        lists:foldl(
          fun({World, Trace}, Acc0) ->
                  lists:foldl(
                    fun(Event, {AccNext, AccSeen, AccHits, AccT}) ->
                            Trace1 = [Event | Trace],
                            {World1, Hit} = event(World, Event, Trace1),
                            Hits1 = lists:foldl(fun(H, M) -> M#{H => maps:get(H, M, 0) + 1} end,
                                                AccHits, Hit),
                            Key = key(World1),
                            case is_map_key(Key, AccSeen) of
                                true -> {AccNext, AccSeen, Hits1, AccT + 1};
                                false -> {[{World1, Trace1} | AccNext], AccSeen#{Key => true},
                                          Hits1, AccT + 1}
                            end
                    end, Acc0, alphabet(World))
          end, {[], Seen0, Hits0, Transitions0}, Frontier),
    bfs(lists:reverse(Next), Seen, Depth + 1, Max, Hits, Transitions).

%% ---------------------------------------------------------------------
%% The alphabet

alphabet(#{model := #{issued := Issued, lanes := Lanes}, holders := Holders}) ->
    Ends = lists:sort(maps:to_list(Issued)),
    [{pipe, H, []} || H <- Holders]
        ++ [{gone, H} || H <- Holders]
        ++ lists:append(
             [[{inherit, H, P, E, C} || C <- Holders]
              ++ [{inherit, X, P, E, hd(Holders)} || X <- Holders, X =/= H]
              ++ [{closed, X, P, E} || X <- Holders]
              ++ [{install_failed, X, P, E} || X <- Holders]
              || {{P, E}, #{holder := H}} <- Ends])
        ++ [{drained, X, P, E, W}
            || {{P, E}, #{kind := read}} <- Ends,
               {LaneP, W} <- lists:sort(maps:keys(Lanes)), LaneP =:= P,
               X <- Holders].

%% ---------------------------------------------------------------------
%% One event

event(#{s := S, model := Model0, limits := Limits} = World, Event, Trace) ->
    {S1, Actions} = erx_pipe:step(S, Event),
    Ctx = #{trace => lists:reverse(Trace), event => Event},
    Legit = legit(Model0, Event),
    case Legit of
        false -> forged(S, S1, Event, Actions, Ctx);
        true -> ok
    end,
    require(lock_freed_by_its_reader,
            lists:sort([{L, R} || {free_lock, L, R} <- Actions])
            =:= locks_to_free(Model0, Event, Legit),
            Actions, Ctx),
    Refusal = refusal(erx_pipe:view(S), Model0, Event, Limits),
    require(refused_only_at_limits,
            [R || {reply, {error, R}} <- Actions, R =/= ebadf] =:= reasons(Refusal, Legit),
            {Refusal, Actions}, Ctx),
    Model1 = case Legit of
                 true -> before(Model0, Event);
                 false -> Model0
             end,
    {Model2, Hits} = actions(Model1, Event, Actions, Ctx),
    check(S1, Model2, Limits, Ctx),
    {World#{s := S1, model := Model2}, hits(Event, Legit, Actions, Refusal) ++ Hits}.

%% The reader lock frees a legitimately going read end's index, as its
%% descriptor named it, and nothing else.
locks_to_free(#{ends := Ends}, {closed, _, P, E}, true) ->
    [{{lock, P}, Rix} || #{kind := read, rix := Rix} <- [maps:get({P, E}, Ends)]];
locks_to_free(#{ends := Ends}, {gone, H}, true) ->
    lists:sort([{{lock, P}, Rix}
                || {{P, _}, #{kind := read, rix := Rix, holder := X}} <- maps:to_list(Ends),
                   X =:= H]);
locks_to_free(_, _, _) ->
    [].

%% Which limit, if any, a request meets, judged from the records before
%% it and the model's own knowledge of the requester's end: the quota of
%% lanes, the numbers or the read ends.
refusal(#{lanes := Lanes, next_pipe := NextPipe, pipes := Pipes}, Model, Event,
        #{quota := Quota, number_max := Max, readers_max := ReadersMax}) ->
    case Event of
        {pipe, _, _} when Lanes >= Quota -> {enfile, quota};
        {pipe, _, _} when NextPipe > Max -> {enfile, number};
        {inherit, _, P, E, _} ->
            case {find(Model, P, E), maps:get(P, Pipes, none)} of
                {#{kind := write}, _} when Lanes >= Quota -> {enfile, quota};
                {#{kind := write}, #{next_end := Next}} when Next > Max -> {enfile, number};
                {#{kind := read}, #{readers := Rs}} when map_size(Rs) >= ReadersMax -> emfile;
                {#{kind := read}, #{next_end := Next}} when Next > Max -> {enfile, number};
                _ -> none
            end;
        _ -> none
    end.

reasons(none, _) -> [];
reasons(_, false) -> [];
reasons({enfile, _}, true) -> [enfile];
reasons(emfile, true) -> [emfile].

%% Whether the event is one a real holder could send: a request, or a
%% notice about an end it holds, a drained one only for a writer it was
%% told is gone and has not drained.
legit(_, {pipe, _, _}) -> true;
legit(_, {gone, _}) -> true;
legit(Model, {drained, H, P, E, W}) ->
    case find(Model, P, E) of
        #{holder := H, kind := read, writers := #{W := gone}} -> true;
        _ -> false
    end;
legit(Model, Event) ->
    {H, P, E} = case Event of
                    {inherit, H0, P0, E0, _} -> {H0, P0, E0};
                    {closed, H0, P0, E0} -> {H0, P0, E0};
                    {install_failed, H0, P0, E0} -> {H0, P0, E0}
                end,
    case find(Model, P, E) of
        #{holder := H} -> true;
        _ -> false
    end.

forged(S, S1, Event, Actions, Ctx) ->
    Expected = case Event of
                   {inherit, _, _, _, _} -> [{reply, {error, ebadf}}];
                   _ -> []
               end,
    require(forged_changes_nothing, S =:= S1 andalso Actions =:= Expected,
            {Actions, erx_pipe:view(S1)}, Ctx).

%% What the holder did before its notice: liberx let the end go, or the
%% holder ended, or the read end let a drained lane go.
before(#{ends := Ends} = Model, {closed, _, P, E}) ->
    Model#{ends := maps:remove({P, E}, Ends)};
before(#{ends := Ends} = Model, {gone, H}) ->
    Model#{ends := maps:filter(fun(_, #{holder := X}) -> X =/= H end, Ends)};
before(#{ends := Ends} = Model, {drained, _, P, E, W}) ->
    #{writers := Writers, held := Held} = End = maps:get({P, E}, Ends),
    Lane = [{ring, P, W}, {rpage, P, W}],
    Model#{ends := Ends#{{P, E} := End#{writers := maps:remove(W, Writers),
                                        held := maps:without(Lane, Held)}}};
before(Model, _) ->
    Model.

hits({pipe, _, _}, _, [{reply, {error, enfile}}], Refusal) -> [{pipe, Refusal}];
hits({inherit, _, _, _, _}, true, [{reply, {error, _}}], Refusal) -> [{inherit, Refusal}];
hits({inherit, _, _, _, _}, false, _, _) -> [inherit_forged];
hits({drained, _, _, _, _}, true, Actions, _) ->
    [drained | [drained_last || lists:keymember(close, 1, Actions)]];
hits({gone, _}, _, [_ | _], _) -> [gone_with_ends];
hits(_, false, _, _) -> [notice_ignored];
hits(_, _, _, _) -> [].

%% ---------------------------------------------------------------------
%% The actions, in order, against the model

actions(Model0, Event, Actions, Ctx) ->
    {Model, _, Hits} =
        lists:foldl(fun(Action, {M, Phase, H}) ->
                            IsMake = element(1, Action) =:= make_lock
                                orelse element(1, Action) =:= make_lane
                                orelse element(1, Action) =:= make_bell,
                            require(makes_first, not (IsMake andalso Phase =:= rest),
                                    Action, Ctx),
                            NextPhase = case IsMake of true -> Phase; false -> rest end,
                            {M1, H1} = action(M, Event, Action, Ctx),
                            {M1, NextPhase, H1 ++ H}
                    end, {Model0, makes, []}, Actions),
    {Model, Hits}.

action(Model, _, {make_lock, Lock}, Ctx) ->
    {make(Model, [Lock], Ctx), []};
action(#{lanes := Lanes} = Model, _, {make_lane, {ring, P, W} = Ring, {rpage, P, W} = RPage,
                                       _Size}, Ctx) ->
    M = make(Model, [Ring, RPage], Ctx),
    {M#{lanes := Lanes#{{P, W} => true}}, []};
action(#{bells := Bells} = Model, _, {make_bell, {bell, P, E} = Bell, Holder, Label}, Ctx) ->
    Expected = case Holder of
                   {program, _} -> erx_pipe:label(P, E);
                   {process, _} -> registered
               end,
    require(doorbell_in_holders_group, Label =:= Expected, Label, Ctx),
    M = make(Model, [Bell], Ctx),
    {M#{bells := Bells#{Bell => Holder}}, []};
action(#{wends := Wends} = Model, _, {store_wends, {lock, P} = Lock, N}, Ctx) ->
    live(Model, [Lock], Ctx),
    require(wends_before_install, N =:= maps:get(P, Wends, 0) + 1, N, Ctx),
    {Model#{wends := Wends#{P => N}}, []};
action(Model, _, {free_lock, Lock, _Rix}, Ctx) ->
    live(Model, [Lock], Ctx),
    {Model, [lock_freed]};
action(#{live := Live} = Model, _, {close, Object}, Ctx) ->
    require(closes_only_live, is_map_key(Object, Live), Object, Ctx),
    Hit = case Object of {lock, _} -> [pipe_forgotten]; _ -> [] end,
    {Model#{live := maps:remove(Object, Live)}, Hit};
action(Model, _, {report, Holder, Report}, Ctx) ->
    live(Model, [O || {O, _} <- erx_pipe:copies(Report)], Ctx),
    report(Model, Holder, Report, Ctx);
action(Model, {pipe, Holder, _}, {reply, {ok, Read, Write}}, Ctx) ->
    {issue(issue(Model, Holder, Read, Ctx), Holder, Write, Ctx), [pipe_made]};
action(Model, {inherit, _, _, _, Child}, {reply, {ok, {pipe, Kind, _, _} = D}}, Ctx) ->
    {issue(Model, Child, D, Ctx), [{inherited, Kind}]};
action(Model, _, {reply, {error, _}}, _Ctx) ->
    {Model, []};
action(_Model, _, Action, Ctx) ->
    violation(known_actions, Action, Ctx).

make(#{live := Live, made := Made} = Model, Objects, Ctx) ->
    lists:foreach(fun(O) -> require(made_once, not is_map_key(O, Made), O, Ctx) end, Objects),
    New = maps:from_keys(Objects, true),
    Model#{live := maps:merge(Live, New), made := maps:merge(Made, New)}.

live(#{live := Live}, Objects, Ctx) ->
    lists:foreach(fun(O) -> require(names_only_live, is_map_key(O, Live), O, Ctx) end, Objects).

%% A descriptor handed out: a new end of its holder, with the copies the
%% handler installs and the peers it names.
issue(#{ends := Ends, issued := Issued, bells := Bells, wends := Wends} = Model,
      Holder, {pipe, Kind, {P, E}, Map} = D, Ctx) ->
    require(made_once, not is_map_key({P, E}, Issued), {P, E}, Ctx),
    require(doorbell_in_holders_group, maps:get({bell, P, E}, Bells, none) =:= Holder,
            {bell, P, E}, Ctx),
    Copies = erx_pipe:copies(D),
    live(Model, [O || {O, _} <- Copies], Ctx),
    End = case Kind of
              write ->
                  #{wend := W, readers := Rs} = Map,
                  require(wends_before_install, W =< maps:get(P, Wends, 0), W, Ctx),
                  #{kind => write, wend => W, readers => maps:from_list(Rs)};
              read ->
                  #{rix := Rix, writers := Ws, readers := Rs, wends := N} = Map,
                  require(wends_before_install,
                          N =:= maps:get(P, Wends, 0)
                          andalso lists:all(fun({W, _, _, _, _}) -> W =< N end, Ws),
                          N, Ctx),
                  #{kind => read, rix => Rix, readers => maps:from_list(Rs),
                    writers => maps:from_list([{W, writer_state(S)} || {W, _, _, _, S} <- Ws]),
                    wbells => maps:from_list([{W, B} || {W, _, _, _, {open, B}} <- Ws])}
          end,
    Model#{ends := Ends#{{P, E} => End#{holder => Holder, lost => false,
                                        held => maps:from_list(Copies)}},
           issued := Issued#{{P, E} => #{holder => Holder, kind => Kind}}}.

writer_state({open, _}) -> open;
writer_state(gone) -> gone.

report(Model, Holder, Report, Ctx) ->
    {P, E} = {element(2, Report), element(3, Report)},
    End = case find(Model, P, E) of
              #{holder := Holder} = Found -> Found;
              Found -> violation(reports_reach_holders, {Holder, Found}, Ctx)
          end,
    {End1, Hit} = apply_report(End, Report, Model, Ctx),
    {Model#{ends := (maps:get(ends, Model))#{{P, E} := End1}}, Hit}.

apply_report(#{kind := read, writers := Ws, wbells := Bells, held := Held} = End,
             {pipe_writer, P, _, W, _, _, _, Bell, open} = R, #{wends := Wends}, Ctx) ->
    require(told_once, not is_map_key(W, Ws), R, Ctx),
    require(wends_before_install, W =< maps:get(P, Wends, 0), R, Ctx),
    {End#{writers := Ws#{W => open}, wbells := Bells#{W => Bell},
          held := maps:merge(Held, maps:from_list(erx_pipe:copies(R)))}, [writer_joined]};
%% A read end told a writer is gone closes its copy of the writer's
%% doorbell and keeps the lane until it drains it.
apply_report(#{kind := read, writers := Ws, wbells := Bells, held := Held} = End,
             {pipe_writer_gone, _, _, W} = R, _, Ctx) ->
    require(told_once, maps:get(W, Ws, none) =:= open, R, Ctx),
    {End#{writers := Ws#{W := gone}, wbells := maps:remove(W, Bells),
          held := maps:remove(maps:get(W, Bells), Held)}, [writer_gone_told]};
apply_report(#{readers := Rs, held := Held} = End, {pipe_reader, _, _, Rix, Bell, open} = R,
             _, Ctx) ->
    require(told_once, not is_map_key(Rix, Rs), R, Ctx),
    {End#{readers := Rs#{Rix => Bell}, held := Held#{Bell => ?T}}, [reader_joined]};
apply_report(#{readers := Rs, held := Held} = End, {pipe_reader_gone, _, _, Rix} = R, _, Ctx) ->
    require(told_once, is_map_key(Rix, Rs), R, Ctx),
    {End#{readers := maps:remove(Rix, Rs), held := maps:remove(maps:get(Rix, Rs), Held)},
     [reader_gone_told]};
apply_report(End, {pipe_lost, _, _}, _, _) ->
    {End#{lost := true}, [lost_reported]};
apply_report(End, Report, _, Ctx) ->
    violation(reports_reach_holders, {wrong_kind, End, Report}, Ctx).

%% ---------------------------------------------------------------------
%% The properties of the records against the model

check(S, #{ends := Ends, live := Live, wends := Wends}, #{quota := Quota}, Ctx) ->
    #{lanes := Lanes, pipes := Pipes} = erx_pipe:view(S),
    Recorded = recorded_ends(Pipes),
    require(one_holder,
            maps:from_list([{PE, {H, K}} || {PE, H, K, _} <- Recorded])
            =:= maps:map(fun(_, #{holder := H, kind := K}) -> {H, K} end, Ends),
            Recorded, Ctx),
    lists:foreach(fun({{P, E}, _H, Kind, Number}) ->
                          Pipe = maps:get(P, Pipes),
                          End = maps:get({P, E}, Ends),
                          peers(End, P, Kind, Number, Pipe, Ctx),
                          held(End, needs(P, Kind, Number, Pipe), Ctx)
                  end, Recorded),
    require(server_holds_exactly, Live =:= maps:from_keys(derived(Pipes), true),
            {maps:keys(Live), derived(Pipes)}, Ctx),
    require(lanes_counted,
            Lanes =:= lists:sum([map_size(W) || #{writers := W} <- maps:values(Pipes)])
            andalso Lanes =< Quota,
            Lanes, Ctx),
    require(wends_stored, maps:map(fun(_, #{wends := N}) -> N end, Pipes)
            =:= maps:with(maps:keys(Pipes), Wends), Wends, Ctx).

recorded_ends(Pipes) ->
    lists:sort(
      [{{P, E}, H, write, W}
       || {P, #{writers := Ws}} <- maps:to_list(Pipes),
          {W, #{end_id := E, holder := H, state := open}} <- maps:to_list(Ws)]
      ++ [{{P, E}, H, read, Rix}
          || {P, #{readers := Rs}} <- maps:to_list(Pipes),
             {Rix, #{end_id := E, holder := H}} <- maps:to_list(Rs)]).

%% What an end's holder needs installed (docs/design-pipes.md, "Ends and
%% their holders"), with each copy's rights.
needs(P, write, W, #{readers := Rs}) ->
    maps:from_list([{{ring, P, W}, ?R bor ?W}, {{rpage, P, W}, ?R}
                    | [{{bell, P, E}, ?T} || #{end_id := E} <- maps:values(Rs)]]);
needs(P, read, Rix, #{writers := Ws, readers := Rs}) ->
    maps:from_list([{{lock, P}, ?R bor ?W}
                    | lists:append([[{{ring, P, W}, ?R}, {{rpage, P, W}, ?R bor ?W}
                                     | [{{bell, P, E}, ?T} || S =:= open]]
                                    || {W, #{end_id := E, state := S} = Wr} <- maps:to_list(Ws),
                                       drains(Wr, Rix)])]
                   ++ [{{bell, P, E}, ?T} || {R, #{end_id := E}} <- maps:to_list(Rs),
                                             R =/= Rix]).

drains(#{state := open}, _) -> true;
drains(#{state := {gone, Left}}, Rix) -> lists:member(Rix, Left).

held(#{lost := true}, _, _) -> ok;
held(#{held := Held}, Needs, Ctx) ->
    require(holders_hold_what_they_need, Held =:= Needs, {Held, Needs}, Ctx).

peers(#{kind := read, writers := Known, readers := KnownR}, _P, read, Rix,
      #{writers := Ws, readers := Rs}, Ctx) ->
    Expected = maps:from_list([{W, case S of open -> open; {gone, _} -> gone end}
                               || {W, #{state := S} = Wr} <- maps:to_list(Ws),
                                  drains(Wr, Rix)]),
    require(readers_know_writers, Known =:= Expected, {Known, Expected}, Ctx),
    require(readers_know_writers, lists:sort(maps:keys(KnownR))
            =:= lists:sort(maps:keys(Rs)) -- [Rix], KnownR, Ctx);
peers(#{kind := write, readers := KnownR}, _P, write, _W, #{readers := Rs}, Ctx) ->
    require(writers_know_readers, lists:sort(maps:keys(KnownR)) =:= lists:sort(maps:keys(Rs)),
            {KnownR, Rs}, Ctx).

%% The objects the records name: a lock page per pipe, a lane and a
%% doorbell per write end, open or gone, and a doorbell per read end. The
%% server keeps a gone write end's doorbell until it forgets the end,
%% since an install still in progress may name it.
derived(Pipes) ->
    lists:sort(
      lists:append(
        [[{lock, P}
          | lists:append([[{ring, P, W}, {rpage, P, W}, {bell, P, E}]
                          || {W, #{end_id := E}} <- maps:to_list(Ws)])
          ++ [{bell, P, E} || #{end_id := E} <- maps:values(Rs)]]
         || {P, #{writers := Ws, readers := Rs}} <- maps:to_list(Pipes)])).

%% ---------------------------------------------------------------------

find(#{ends := Ends}, P, E) ->
    maps:get({P, E}, Ends, none).

require(_, true, _, _) -> ok;
require(Name, false, Found, Ctx) -> violation(Name, Found, Ctx).

violation(Name, Found, #{trace := Trace}) ->
    throw({violation, Name, Found, Trace}).
