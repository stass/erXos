%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_links).
-moduledoc """
The domain service's pure core for the connection protocol
(docs/design-domains.md, "Connections", "The reserve", and "Introduction and
connection down"; specs/tla/Connection.tla). It decides which control
records go to which domain and when a connection's objects are deleted. It
makes no call: each function returns the actions to perform, in order, and
the domain service performs them.

Parties. A party is a domain, the system domain included, named by its id,
which no other domain takes within a boot, and known by its node name. The
domain service adds a party when it admits the domain, marks it ready when
its init reports ready, and removes it when its end arrives. Nothing is
sent to a party before it is ready.

Connections. A connection joins two parties, at most one per pair, and has a
side for each party: the service's view of that party's part. A side goes

    waiting -> up_sent -> mapped -> down_sent -> unmapped

waiting until connection_up has gone to the party, up_sent until the party
answers connection_mapped, mapped while it is up, down_sent once
connection_down has gone, unmapped when the party answers
connection_unmapped. The other ends of a side are lost (the party ended the
connection itself and said connection_lost), lost_down_sent (it did so with
connection_down outstanding, which it still answers), ended (the party's
domain ended) and untold (the connection closed before connection_up went
out, so the party never learns of it). A side has let go once its party will
never map the connection again (unmapped, lost, lost_down_sent, ended,
untold), and is done once it has also nothing outstanding (all of those but
lost_down_sent).

A connection's phase is up_pending until both sides are mapped, then up;
closing once a party ended it, its peer's domain ended, or policy closed it;
gone once both sides have let go and the disconnect action deleted its
objects. A gone connection's record stays only while a side still owes an
answer, so that answer is recognised; then it is forgotten.

Queues. Each party keeps, for each peer node name, the list of its sides
that are not done, oldest connection first. Only the head of a list ever
has a record sent: connection_up from waiting once the party is ready,
connection_down from mapped once the connection is closing. Every entry
behind the head is waiting, so at most one record per party and peer name is
outstanding, and a later domain of a name has its connection_up sent only
once the earlier connection's side is done, that is, once the party has
answered its connection_down or ended it itself. One function changes a
side's state and takes a done side off its list, so the lists hold exactly
the sides not done.

Answers come from domains and are untrusted. An answer is applied only when
it names a connection of the answering party in the state that expects it:
connection_mapped in up_sent; connection_unmapped in down_sent and
lost_down_sent; connection_lost in mapped and down_sent. Anything else is
dropped and counted against the party, or against unknown for a party the
core does not hold. No answer creates state, and an answer changes only the
answering party's own side. A runtime answers connection_mapped before its
port can report connection_lost, as in the model, so connection_lost while
connection_up is unanswered is dropped like any answer out of turn.

The quota. A connection counts against a party's connections from connect/4
until the party's side is done, closing included, as held/2 reports, so
the records that party can be owed never outnumber its connections: the
reserve of its lane from the system domain is sized for that.

Every other function is called by the domain service itself. ready/2 may
come after the party's end, since the init's report and the fault gate race,
and is then nothing; any other call in a state that does not allow it is a
bug of the caller and fails with a badmatch or function_clause.
""".

-export([new/0, add_party/3, ready/2, connect/4, answer/3, close/3, ended/3,
         phase/3, held/2, dropped/1]).
-export_type([state/0, party/0, phase/0, control_record/0, action/0, down_reason/0]).

-type party() :: pos_integer().
-type key() :: {party(), party()}.
-type phase() :: up_pending | up | closing | gone.
-type side_state() :: waiting | up_sent | mapped | down_sent
                    | lost_down_sent | lost | unmapped | ended | untold.
-type down_reason() :: noconnection | {domain_down, party(), term()}.
%% Up is what the party's connection_up carries besides the peer: its slots,
%% label and sizes, opaque here.
-type side() :: #{state := side_state(), peer := party(), peer_name := node(),
                  up := term()}.
%% Reason is what connection_down tells, fixed when the connection starts
%% closing, as in the model; before that it is noconnection and unread.
-type connection() :: #{handle := term(), phase := phase(),
                        reason := down_reason(),
                        sides := #{party() => side()}}.
-type party_record() :: #{name := node(), ready := boolean(),
                          queues := #{node() => [party()]},
                          dropped := non_neg_integer()}.
-opaque state() :: #{parties := #{party() => party_record()},
                     connections := #{key() => connection()},
                     dropped_unknown := non_neg_integer()}.

%% A control record as a party reads it: the peer's id first.
-type control_record() :: {connection_up, party(), node(), term()}
                | {connection_down, party(), down_reason()}.
%% Send a record through a party's domain pid, or delete the objects of the
%% connection whose handle connect/4 was given.
-type action() :: {send, party(), control_record()} | {disconnect, term()}.

%% Actions in reverse order, and the state they lead to.
-type acc() :: {[action()], state()}.

-doc "The state with no parties and no connections.".
-spec new() -> state().
new() ->
    #{parties => #{}, connections => #{}, dropped_unknown => 0}.

-doc "Adds party Id, known by node name Name and not yet ready.".
-spec add_party(party(), node(), state()) -> state().
add_party(Id, Name, #{parties := Parties} = State)
  when not is_map_key(Id, Parties) ->
    Party = #{name => Name, ready => false, queues => #{}, dropped => 0},
    State#{parties := Parties#{Id => Party}}.

-doc """
Party Id's init reported ready: the records waiting for it may go. Ready
again, or for a party that has ended, is nothing.
""".
-spec ready(party(), state()) -> {[action()], state()}.
ready(Id, #{parties := Parties} = State) ->
    case Parties of
        #{Id := #{ready := false, queues := Queues} = Party} ->
            Next = State#{parties := Parties#{Id := Party#{ready := true}}},
            finish(lists:foldl(fun(Name, Acc) -> advance(Id, Name, Acc) end,
                               {[], Next}, lists:sort(maps:keys(Queues))));
        #{} ->
            {[], State}
    end.

-doc """
Records the connection the domain library built between parties A and B,
whose objects Handle names, and queues connection_up for each, carrying
UpA to A and UpB to B. Both parties are held, distinct and not yet joined.
""".
-spec connect(term(), {party(), term()}, {party(), term()}, state()) ->
          {[action()], state()}.
connect(Handle, {A, UpA}, {B, UpB},
        #{parties := Parties, connections := Connections} = State)
  when A =/= B ->
    Key = key(A, B),
    false = is_map_key(Key, Connections),
    #{A := #{name := NameA}, B := #{name := NameB}} = Parties,
    Sides = #{A => new_side(B, NameB, UpA), B => new_side(A, NameA, UpB)},
    Connection = #{handle => Handle, phase => up_pending, reason => noconnection,
                   sides => Sides},
    Queued = enqueue(B, A, NameA, enqueue(A, B, NameB, Parties)),
    Next = State#{parties := Queued, connections := Connections#{Key => Connection}},
    finish(settle(Key, {[], Next})).

-doc """
Party P's answer, as its domain pid delivered it: {connection_mapped, Peer},
{connection_unmapped, Peer} or {connection_lost, Peer, Reason}. Applied only
in the state that expects it; anything else is dropped and counted.
""".
-spec answer(party(), term(), state()) -> {[action()], state()}.
answer(P, Answer, #{parties := Parties, dropped_unknown := Unknown} = State) ->
    case is_map_key(P, Parties) of
        false ->
            {[], State#{dropped_unknown := Unknown + 1}};
        true ->
            case answer_kind(Answer) of
                {Kind, Peer} -> apply_answer(P, Peer, Kind, State);
                malformed -> {[], count_dropped(P, State)}
            end
    end.

-doc """
Policy closes the connection between A and B: each party that knows of it
is told connection_down with noconnection. A connection already closing or
gone, or none, is left as it is.
""".
-spec close(party(), party(), state()) -> {[action()], state()}.
close(A, B, #{connections := Connections} = State) ->
    Key = key(A, B),
    case Connections of
        #{Key := #{phase := Phase}} when Phase =:= up_pending; Phase =:= up ->
            finish(settle(Key, {[], start_closing(Key, noconnection, State)}));
        #{} ->
            {[], State}
    end.

-doc """
Party D's domain ended, with Info for {domain_down, D, Info}: D is removed,
its sides end, and every peer that knows of a connection with D is told
connection_down with that reason.
""".
-spec ended(party(), term(), state()) -> {[action()], state()}.
ended(D, Info, #{parties := Parties, connections := Connections} = State) ->
    #{D := _} = Parties,
    Removed = State#{parties := maps:remove(D, Parties)},
    Keys = lists:sort([Key || {X, Y} = Key <- maps:keys(Connections),
                              X =:= D orelse Y =:= D]),
    finish(lists:foldl(fun(Key, {Actions, Acc}) ->
                               settle(Key, {Actions, end_side(Key, D, Info, Acc)})
                       end, {[], Removed}, Keys)).

-doc "The phase of the connection between A and B, or none.".
-spec phase(party(), party(), state()) -> phase() | none.
phase(A, B, #{connections := Connections}) ->
    Key = key(A, B),
    case Connections of
        #{Key := #{phase := Phase}} -> Phase;
        #{} -> none
    end.

-doc """
The connections counted against party P's connections: those whose side for
P is not done. 0 for a party not held.
""".
-spec held(party(), state()) -> non_neg_integer().
held(P, #{parties := Parties}) ->
    case Parties of
        #{P := #{queues := Queues}} -> lists:sum([length(Q) || Q <- maps:values(Queues)]);
        #{} -> 0
    end.

-doc "Answers dropped, by party held, and under unknown for any other sender.".
-spec dropped(state()) -> #{party() | unknown => non_neg_integer()}.
dropped(#{parties := Parties, dropped_unknown := Unknown}) ->
    maps:put(unknown, Unknown, maps:map(fun(_, #{dropped := N}) -> N end, Parties)).

%% Answers.

answer_kind({connection_mapped, Peer}) -> {mapped, Peer};
answer_kind({connection_unmapped, Peer}) -> {unmapped, Peer};
answer_kind({connection_lost, Peer, _Reason}) -> {lost, Peer};
answer_kind(_) -> malformed.

%% The state a side moves to on an answer, or unexpected.
answered(up_sent, mapped) -> {ok, mapped};
answered(mapped, lost) -> {ok, lost};
answered(down_sent, unmapped) -> {ok, unmapped};
answered(down_sent, lost) -> {ok, lost_down_sent};
answered(lost_down_sent, unmapped) -> {ok, unmapped};
answered(_, _) -> unexpected.

%% Peer is untrusted: it is only compared, and a key no connection has
%% finds nothing.
apply_answer(P, Peer, Kind, #{connections := Connections} = State) ->
    Key = key(P, Peer),
    case Connections of
        #{Key := #{sides := #{P := #{state := Side}}}} ->
            case answered(Side, Kind) of
                {ok, New} ->
                    Next = after_answer(Key, New, set_side(Key, P, New, State)),
                    finish(settle(Key, {[], Next}));
                unexpected ->
                    {[], count_dropped(P, State)}
            end;
        #{} ->
            {[], count_dropped(P, State)}
    end.

%% A connection is up once both sides are mapped; a party that ended a live
%% connection itself closes it, and its peer is told noconnection. (Ending
%% one with connection_down outstanding, lost_down_sent, finds it closing.)
after_answer(Key, New, State) ->
    #{phase := Phase, sides := Sides} = connection(Key, State),
    case {Phase, New} of
        {up_pending, mapped} ->
            case lists:all(fun(#{state := S}) -> S =:= mapped end, maps:values(Sides)) of
                true -> update_connection(Key, fun(C) -> C#{phase := up} end, State);
                false -> State
            end;
        {Live, lost} when Live =:= up_pending; Live =:= up ->
            start_closing(Key, noconnection, State);
        {_, _} ->
            State
    end.

count_dropped(P, #{parties := Parties} = State) ->
    #{P := #{dropped := N} = Party} = Parties,
    State#{parties := Parties#{P := Party#{dropped := N + 1}}}.

%% Closing and ending.

%% Mark the connection closing with Reason for the sides still to be told.
%% A side still waiting never learns of the connection: it becomes untold,
%% so no side is ever waiting in a closing connection.
start_closing(Key, Reason, State) ->
    #{sides := Sides} = connection(Key, State),
    Closing = update_connection(
                Key, fun(C) -> C#{phase := closing, reason := Reason} end, State),
    lists:foldl(fun({P, #{state := waiting}}, Acc) -> set_side(Key, P, untold, Acc);
                   ({_, _}, Acc) -> Acc
                end, Closing, lists:sort(maps:to_list(Sides))).

%% D's side ends; a live connection closes and its peer is told
%% {domain_down, D, Info}.
end_side(Key, D, Info, State) ->
    #{phase := Phase} = connection(Key, State),
    Ended = set_side(Key, D, ended, State),
    case Phase of
        up_pending -> start_closing(Key, {domain_down, D, Info}, Ended);
        up -> start_closing(Key, {domain_down, D, Info}, Ended);
        _ -> Ended
    end.

%% After any change to a connection: delete its objects once both sides
%% have let go, forget it once both are done, then send what its parties'
%% queues allow.
settle(Key, {Actions, State}) ->
    %% Read before retire/2, which may forget the connection.
    #{sides := Sides} = connection(Key, State),
    Retired = retire(Key, {Actions, State}),
    lists:foldl(fun({P, #{peer_name := Name}}, Acc) -> advance(P, Name, Acc) end,
                Retired, lists:sort(maps:to_list(Sides))).

retire(Key, {Actions, #{connections := Connections} = State}) ->
    #{Key := #{handle := Handle, phase := Phase, sides := Sides} = Connection} = Connections,
    States = [S || #{state := S} <- maps:values(Sides)],
    LetGo = lists:all(fun let_go/1, States),
    Done = lists:all(fun done/1, States),
    case Phase of
        closing when LetGo, Done ->
            {[{disconnect, Handle} | Actions],
             State#{connections := maps:remove(Key, Connections)}};
        closing when LetGo ->
            {[{disconnect, Handle} | Actions],
             State#{connections := Connections#{Key := Connection#{phase := gone}}}};
        gone when Done ->
            {Actions, State#{connections := maps:remove(Key, Connections)}};
        _ ->
            {Actions, State}
    end.

let_go(S) -> done(S) orelse S =:= lost_down_sent.

done(S) -> lists:member(S, [unmapped, lost, ended, untold]).

%% Queues.

%% Send the head of P's queue for peer name Name its next record, if it has
%% one due: connection_up once P is ready, connection_down once the
%% connection closes. A party removed or a queue empty sends nothing.
advance(P, Name, {Actions, #{parties := Parties} = State} = Acc) ->
    case Parties of
        #{P := #{ready := Ready, queues := #{Name := [Peer | _]}}} ->
            Key = key(P, Peer),
            #{phase := Phase, reason := Reason, sides := #{P := Side}} = connection(Key, State),
            #{state := SideState, up := Up} = Side,
            case next_record(SideState, Phase, Ready) of
                up ->
                    Record = {connection_up, Peer, Name, Up},
                    {[{send, P, Record} | Actions], set_side(Key, P, up_sent, State)};
                down ->
                    Record = {connection_down, Peer, Reason},
                    {[{send, P, Record} | Actions], set_side(Key, P, down_sent, State)};
                none ->
                    Acc
            end;
        #{} ->
            Acc
    end.

%% The record due to the head of a queue. Only waiting and mapped have one:
%% every other state waits on the party or has nothing more to say. A
%% waiting side is never in a closing connection (start_closing/3).
next_record(waiting, _Phase, true) -> up;
next_record(mapped, closing, _Ready) -> down;
next_record(_SideState, _Phase, _Ready) -> none.

enqueue(P, Peer, PeerName, Parties) ->
    #{P := #{queues := Queues} = Party} = Parties,
    Queue = maps:get(PeerName, Queues, []),
    Parties#{P := Party#{queues := Queues#{PeerName => Queue ++ [Peer]}}}.

%% The one place a side changes state. A side that is done leaves its
%% party's queue, unless the party is gone already.
set_side(Key, P, New, State) ->
    Updated = update_connection(
                Key, fun(#{sides := #{P := Side} = Sides} = C) ->
                             C#{sides := Sides#{P := Side#{state := New}}}
                     end, State),
    case done(New) of
        true -> dequeue(Key, P, Updated);
        false -> Updated
    end.

dequeue(Key, P, #{parties := Parties} = State) ->
    #{sides := #{P := #{peer := Peer, peer_name := Name}}} = connection(Key, State),
    case Parties of
        #{P := #{queues := #{Name := Queue} = Queues} = Party} ->
            Rest = lists:delete(Peer, Queue),
            Kept = case Rest of
                       [] -> maps:remove(Name, Queues);
                       _ -> Queues#{Name := Rest}
                   end,
            State#{parties := Parties#{P := Party#{queues := Kept}}};
        #{} ->
            State
    end.

%% Helpers.

key(A, B) when A < B -> {A, B};
key(A, B) -> {B, A}.

new_side(Peer, PeerName, Up) ->
    #{state => waiting, peer => Peer, peer_name => PeerName, up => Up}.

connection(Key, #{connections := Connections}) ->
    #{Key := Connection} = Connections,
    Connection.

update_connection(Key, Fun, #{connections := Connections} = State) ->
    #{Key := Connection} = Connections,
    State#{connections := Connections#{Key := Fun(Connection)}}.

-spec finish(acc()) -> {[action()], state()}.
finish({Actions, State}) -> {lists:reverse(Actions), State}.
