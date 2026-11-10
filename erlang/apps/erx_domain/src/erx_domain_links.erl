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
domain service adds a party when the library has built the domain, marks it ready when
its init reports ready, and removes it when its end arrives. Nothing is
sent to a party before it is ready.

Connections. A connection joins two parties, at most one per pair, and has a
side for each party: the service's view of that party's part. A side goes

    waiting -> up_sent -> mapped -> down_sent -> unmapped

waiting until connection_up has gone to the party, up_sent until the party
answers connection_mapped (or connection_lost, below), mapped while it is
up, down_sent once connection_down has gone, unmapped when the party
answers connection_unmapped. The other ends of a side are lost (the party ended the
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
connection_mapped or connection_lost in up_sent; connection_unmapped in
down_sent and lost_down_sent; connection_lost in mapped and down_sent.
Anything else is dropped and counted against the party, or against unknown
for a party the core does not hold. No answer creates state, and an answer
changes only the answering party's own side. A runtime answers
connection_mapped once its entry for the peer is up, and a connection_up
it cannot map, or whose port ends before the entry is up, it answers with
connection_lost alone, which settles the record as connection_mapped would
and closes the connection, as connection_lost from mapped does.

The quota. A connection counts against a party's connections from connect/4
until the party's side is done, closing included, as held/2 reports, and
room/2 says whether a party can take one more. So the records that party
can be owed never outnumber its connections, which is the number of slots
of its control table (docs/design-domains.md, "The control table").

Slots. The core owns each party's control table. A record goes with the
lowest slot of the party's table that no outstanding record holds, and its
side holds that slot while the record is unanswered, that is, while the side
is up_sent, down_sent or lost_down_sent; the one function that changes a
side's state frees the slot as the side leaves those states. So a slot is
written again only once the answer its record waits for has arrived:
connection_mapped or connection_lost to a connection_up,
connection_unmapped to a connection_down, or the party's end. A connection_lost while a
connection_down waits frees nothing, since the party may not have taken the
record yet. A table never runs out: a party's outstanding records are at
most its sides not done, which room/2 keeps within its slots.

Every other function is called by the domain service itself. ready/2 may
come after the party's end, since the init's report and the fault gate race,
and is then nothing; any other call in a state that does not allow it is a
bug of the caller and fails with a badmatch or function_clause.
""".

-export([new/0, add_party/4, ready/2, connect/4, answer/3, close/3, ended/3,
         phase/3, held/2, room/2, dropped/1]).
-export_type([state/0, party/0, slot/0, phase/0, control_record/0, action/0, down_reason/0]).

-type party() :: pos_integer().
%% A slot of a party's control table, from 0.
-type slot() :: non_neg_integer().
-type key() :: {party(), party()}.
-type phase() :: up_pending | up | closing | gone.
-type side_state() :: waiting | up_sent | mapped | down_sent
                    | lost_down_sent | lost | unmapped | ended | untold.
-type down_reason() :: noconnection | {domain_down, party(), term()}.
%% Up is what the party's connection_up carries besides the peer: its slots,
%% label and sizes, opaque here. Slot is the control slot its outstanding
%% record holds, none while it has none.
-type side() :: #{state := side_state(), peer := party(), peer_name := node(),
                  up := term(), slot := slot() | none}.
%% Reason is what connection_down tells, fixed when the connection starts
%% closing, as in the model; before that it is noconnection and unread.
-type connection() :: #{handle := term(), phase := phase(),
                        reason := down_reason(),
                        sides := #{party() => side()}}.
%% Slots is the size of the party's control table, held the slots its
%% outstanding records hold, each with the peer the record is about.
-type party_record() :: #{name := node(), ready := boolean(),
                          queues := #{node() => [party()]},
                          slots := non_neg_integer(), held := #{slot() => party()},
                          dropped := non_neg_integer()}.
-opaque state() :: #{parties := #{party() => party_record()},
                     connections := #{key() => connection()},
                     dropped_unknown := non_neg_integer()}.

%% A control record as a party reads it: the peer's id first.
-type control_record() :: {connection_up, party(), node(), term()}
                | {connection_down, party(), down_reason()}.
%% Write a record into a slot of a party's control table, through its domain
%% pid, or delete the objects of the connection whose handle connect/4 was given.
-type action() :: {send, party(), slot(), control_record()} | {disconnect, term()}.

%% Actions in reverse order, and the state they lead to.
-type acc() :: {[action()], state()}.

-doc "The state with no parties and no connections.".
-spec new() -> state().
new() ->
    #{parties => #{}, connections => #{}, dropped_unknown => 0}.

-doc """
Adds party Id, known by node name Name, whose control table has Slots slots,
its connections, and not yet ready.
""".
-spec add_party(party(), node(), non_neg_integer(), state()) -> state().
add_party(Id, Name, Slots, #{parties := Parties} = State)
  when not is_map_key(Id, Parties), is_integer(Slots), Slots >= 0 ->
    Party = #{name => Name, ready => false, queues => #{}, slots => Slots, held => #{},
              dropped => 0},
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
UpA to A and UpB to B. Both parties are held, distinct, not yet joined and
each with room for one more connection (room/2), the precondition the
service checks before it asks the library to build the connection.
""".
-spec connect(term(), {party(), term()}, {party(), term()}, state()) ->
          {[action()], state()}.
connect(Handle, {A, UpA}, {B, UpB},
        #{parties := Parties, connections := Connections} = State)
  when A =/= B ->
    Key = key(A, B),
    false = is_map_key(Key, Connections),
    {true, true} = {room(A, State), room(B, State)},
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

-doc """
Whether party P can take one more connection: it is held and fewer of its
connections count against it than it has slots.
""".
-spec room(party(), state()) -> boolean().
room(P, #{parties := Parties} = State) ->
    case Parties of
        #{P := #{slots := Slots}} -> held(P, State) < Slots;
        #{} -> false
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
answered(up_sent, lost) -> {ok, lost};
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
advance(P, Name, {_Actions, #{parties := Parties} = State} = Acc) ->
    case Parties of
        #{P := #{ready := Ready, queues := #{Name := [Peer | _]}}} ->
            Key = key(P, Peer),
            #{phase := Phase, reason := Reason, sides := #{P := Side}} = connection(Key, State),
            #{state := SideState, up := Up} = Side,
            case next_record(SideState, Phase, Ready) of
                up ->
                    send(Key, P, up_sent, {connection_up, Peer, Name, Up}, Acc);
                down ->
                    send(Key, P, down_sent, {connection_down, Peer, Reason}, Acc);
                none ->
                    Acc
            end;
        #{} ->
            Acc
    end.

%% P's side of Key goes to New, an outstanding state, with Record in the
%% lowest slot of P's table that no outstanding record holds. room/2 keeps the
%% outstanding records within the table, so a free slot always exists.
send(Key, P, New, Record, {Actions, #{parties := Parties} = State}) ->
    #{P := #{slots := Slots, held := Held} = Party} = Parties,
    [Slot | _] = [S || S <- lists:seq(0, Slots - 1), not is_map_key(S, Held)],
    #{sides := #{P := #{peer := Peer}}} = connection(Key, State),
    Taken = State#{parties := Parties#{P := Party#{held := Held#{Slot => Peer}}}},
    Slotted = update_side(Key, P, fun(Side) -> Side#{slot := Slot} end, Taken),
    {[{send, P, Slot, Record} | Actions], set_side(Key, P, New, Slotted)}.

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

%% The one place a side changes state. A side that leaves the states with a
%% record outstanding frees its slot, and a side that is done leaves its
%% party's queue, unless the party is gone already.
set_side(Key, P, New, State) ->
    Updated = update_side(Key, P, fun(Side) -> Side#{state := New} end, State),
    Freed = case outstanding(New) of
                true -> Updated;
                false -> free_slot(Key, P, Updated)
            end,
    case done(New) of
        true -> dequeue(Key, P, Freed);
        false -> Freed
    end.

%% The states in which the party owes an answer to the record its slot holds.
outstanding(S) -> lists:member(S, [up_sent, down_sent, lost_down_sent]).

free_slot(Key, P, #{parties := Parties} = State) ->
    case connection(Key, State) of
        #{sides := #{P := #{slot := none}}} ->
            State;
        #{sides := #{P := #{slot := Slot}}} ->
            Unslotted = update_side(Key, P, fun(Side) -> Side#{slot := none} end, State),
            case Parties of
                #{P := #{held := Held} = Party} ->
                    Unslotted#{parties := Parties#{P := Party#{held := maps:remove(Slot, Held)}}};
                #{} ->
                    Unslotted
            end
    end.

update_side(Key, P, Fun, State) ->
    update_connection(Key, fun(#{sides := #{P := Side} = Sides} = C) ->
                                   C#{sides := Sides#{P := Fun(Side)}}
                           end, State).

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
    #{state => waiting, peer => Peer, peer_name => PeerName, up => Up, slot => none}.

connection(Key, #{connections := Connections}) ->
    #{Key := Connection} = Connections,
    Connection.

update_connection(Key, Fun, #{connections := Connections} = State) ->
    #{Key := Connection} = Connections,
    State#{connections := Connections#{Key := Fun(Connection)}}.

-spec finish(acc()) -> {[action()], state()}.
finish({Actions, State}) -> {lists:reverse(Actions), State}.
