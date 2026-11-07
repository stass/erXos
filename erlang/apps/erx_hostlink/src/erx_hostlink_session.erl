%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hostlink_session).
-moduledoc """
The host link's session protocol as one pure state machine
(docs/design-live.md, "The host link" and "Host link frames"; invariants V3
and V4).

`step/2` takes an event and the state and returns the next state and the
actions the caller performs, in order. The machine reads no clock, no
random source and no process: the link's bytes come in as `input` events,
the session identifier as an `entropy` event, a call's outcome as a
`call_done` event and a facet's exit as a `facet_down` event, and the
frames it sends go out as `send` actions of wire bytes.

The layers below it are erx_hostlink_frame, which turns the link's bytes
into frames, and erx_hostlink_stream, which owns everything about frames
within a session: which frames are taken, the order of `seq`, the
reassembly of control messages within the resident limit, the numbering
of the frames sent and the credit granted to the host. The machine holds
one deframer, one receiver, and per session one sender and one grant, and
decides what the stream's results mean:

* **Sessions.** A hello is a call to the root in one control frame of the
  all-zero session whose payload is `{hello, Nonce}`. It opens a session
  under the identifier the last `entropy` event supplied, after ending the
  preceding session and closing its facets, and is answered with
  `{hello, Nonce, SessionId, Build, Versions}` in one frame of the all-zero
  session numbered 0. A hello whose nonce is the current session's (a
  repeat, its reply lost or the frame sent again) is answered with the
  same reply and replaces nothing. Each session also gets a serial, which
  rises with every session the machine opens and so, unlike the
  identifier, which weak entropy may repeat, never names two sessions;
  executions and their outcomes are matched by it. A session ends instead
  of letting `seq` pass `last_seq` in either direction.
* **Credit.** Each `input` event's bytes are counted to the current
  session's grant before the frames they hold are taken, so a session
  counts the reads after the one that held its hello
  (erx_hostlink_stream, "Credit"). An `idle` event, which the caller sends
  when the link's input goes quiet, grants what is owed or repeats the
  last grant.
* **The call window (V4).** The window covers the identifiers `Low` to
  `Low + Window - 1`; each is unseen (absent from `calls`), executing or
  answered. The window moves up only to admit a call above it, and never
  past a call still executing: such a call is answered `{error, busy}`,
  neither executed nor seen. A call below the window is answered
  `{error, expired}`; a duplicate of an executing call is ignored, and a
  duplicate of an answered call gets its kept reply again, or
  `{error, reply_lost}` when it was not kept. The window is consulted when
  a call's message is whole, and when the stream refuses its first piece
  for want of room.
* **Kept replies and resident bytes.** Replies are kept while their encoded
  sizes total at most the kept limit. What the session holds (the message
  the stream is reassembling, at its `total`, each executing call at its
  decoded size and each kept reply) is derived from the state whenever it
  is needed, never kept as a running count, so no path can let it drift.
  A message that does not fit is refused by the stream at its first piece;
  a call that does not fit is answered `{error, busy}`.
* **The facet table (V3).** A call names its target by number: 0 is the
  root, any other number an entry of the session's table, and a number
  the table does not hold is answered `{error, noproc}`. A reply's pids
  that the call reports as facets it opened enter the table under fresh
  numbers, never reused within the session; the table holds at most the
  facet limit, and a reply that would pass it becomes
  `{error, system_limit}`. Every facet a call opened that does not end up
  in the table is closed, so a minted facet is in the table or closed, and
  the table dies with its session.
* **Replies.** A reply is rendered for the host before it is encoded: a
  facet as `{'$host_cap', N}`, and any other pid, reference, port or fun as
  its printed name, which carries none of a fun's captured values. A reply
  whose encoding fails `measure` or the message limit is replaced by
  `{error, system_limit}`.

Malformed input is never answered: it is discarded and counted under a
reason, which `info/1` reports with the deframer's and the receiver's
counts. Payloads are opaque here: `measure` gives a payload's decoded size
before any reservation, and `decode` is used for the hello alone; both
default to erx_hostlink_payload's.
""".

-include("generated/erx_abi.hrl").

-export([new/1, default_limits/0, step/2, info/1]).
-export_type([state/0, config/0, limits/0, event/0, action/0, session_id/0, serial/0]).

-define(NO_SESSION, <<0:128>>).
-define(PIECE_MAX, (?ERX_HOSTLINK_BODY_MAX - ?ERX_HOSTLINK_CONTROL_SIZE)).
%% The answer to a call naming a facet number the session's table does not
%% hold: one closed, one never opened, or one of an ended session. noproc is
%% what calling a process that is gone gives in Erlang.
-define(NO_TARGET, {error, noproc}).
%% What replaces a reply the host could not receive whole.
-define(UNSENDABLE, {error, system_limit}).

-type session_id() :: <<_:128>>.
-type serial() :: pos_integer().

-type limits() :: #{window := pos_integer(),
                    kept := non_neg_integer(),
                    facets := non_neg_integer(),
                    resident := pos_integer(),
                    message_max := 0..?ERX_HOSTLINK_MESSAGE_MAX,
                    last_seq := 0..16#FFFFFFFF,
                    max_facet_number := pos_integer()}.
-type config() :: #{build := binary(),
                    versions := term(),
                    measure => fun((binary()) -> {ok, non_neg_integer()} | {error, term()}),
                    decode => fun((binary()) -> {ok, term()} | {error, term()}),
                    limits => map()}.

%% The target of an executed call: the root, or the process of a facet.
-type target() :: root | pid().
-type event() :: {entropy, binary()}
               | {input, binary()}
               | idle
               | {call_done, serial(), pos_integer(), term(), [pid()]}
               | {facet_down, pid()}
               | {output, terminal | events | files, binary()}.
-type end_reason() :: replaced | exhausted.
-type action() :: {send, binary()}
                | {execute, serial(), pos_integer(), target(), binary()}
                | {cast, serial(), target(), binary()}
                | {deliver, terminal | files, binary()}
                | {monitor_facet, pid()}
                | {close_facet, pid()}
                | {session_opened, session_id(), serial()}
                | {session_ended, session_id(), end_reason()}
                | draw_entropy.

%% A call's entry in the window: executing at its decoded size, answered with
%% its kept reply, or answered with its reply not kept.
-type entry() :: {executing, non_neg_integer()} | {answered, binary()} | lost.

%% nonce and hello_reply answer a repeat of the hello that opened the session.
-record(session, {
    id :: session_id(),
    serial :: serial(),
    nonce :: binary(),
    hello_reply :: binary(),
    sender :: erx_hostlink_stream:sender(),
    grant :: erx_hostlink_stream:grant(),
    low = 1 :: pos_integer(),
    calls = #{} :: #{pos_integer() => entry()},
    facets = #{} :: #{pos_integer() => pid()},
    numbers = #{} :: #{pid() => pos_integer()},
    next_facet = 1 :: pos_integer()
}).

%% The receiver's session is always the session's identifier, or none with it.
-record(core, {
    config :: config(),
    limits :: limits(),
    deframer :: erx_hostlink_frame:deframer(),
    receiver :: erx_hostlink_stream:receiver(),
    fresh = none :: none | session_id(),
    serial = 0 :: non_neg_integer(),
    session = none :: none | #session{},
    counts = #{} :: #{atom() => pos_integer()}
}).

-opaque state() :: #core{}.

-doc "The design's limits: a 64-call window, 1 MiB of kept replies, 1,024
facets, 32 MiB resident, 16 MiB messages, and 32-bit `seq` and facet
numbers. A release build whose configuration lists no facet for the host
sets `message_max` to 8 KiB.".
-spec default_limits() -> limits().
default_limits() ->
    #{window => 64,
      kept => 1 bsl 20,
      facets => 1024,
      resident => 32 bsl 20,
      message_max => ?ERX_HOSTLINK_MESSAGE_MAX,
      last_seq => 16#FFFFFFFF,
      max_facet_number => 16#FFFFFFFF}.

-doc "A machine with no session, under the design's limits overridden by
the configuration's. Its caller sends an `entropy` event next, which the
first hello needs. A build and versions whose hello reply would not fit
one frame are refused.".
-spec new(config()) -> state().
new(#{build := Build, versions := Versions} = Config0) ->
    Overrides = maps:get(limits, Config0, #{}),
    Defaults = default_limits(),
    _ = [error({unknown_limit, Key}) || Key <- maps:keys(Overrides), not is_map_key(Key, Defaults)],
    Limits = maps:merge(Defaults, Overrides),
    byte_size(term_to_binary({hello, ?NO_SESSION, ?NO_SESSION, Build, Versions})) =< ?PIECE_MAX
        orelse error({config, hello_reply}),
    Config = maps:merge(#{measure => fun erx_hostlink_payload:measure/1,
                          decode => fun erx_hostlink_payload:decode/1}, Config0),
    #core{config = Config, limits = Limits,
          deframer = erx_hostlink_frame:deframer(target),
          receiver = erx_hostlink_stream:receiver(maps:get(message_max, Limits))}.

-doc "A snapshot for the inspector and the tests: the session (or `none`),
its window by entry state and reply size (never the reply bytes), its facet
table and resident bytes, and the discard counts of the deframer, the
receiver and the session.".
-spec info(state()) -> map().
info(#core{session = none} = Core) ->
    #{session => none, counts => counts(Core)};
info(#core{session = S} = Core) ->
    #{session => S#session.id,
      serial => S#session.serial,
      low => S#session.low,
      calls => maps:map(fun(_, {answered, Reply}) -> {answered, byte_size(Reply)};
                           (_, Entry) -> Entry
                        end, S#session.calls),
      facets => S#session.facets,
      kept => kept_bytes(S),
      resident => committed(S) + erx_hostlink_stream:held(Core#core.receiver),
      counts => counts(Core)}.

-doc "The next state and the actions for one event.".
-spec step(event(), state()) -> {state(), [action()]}.
step({entropy, ?NO_SESSION}, Core) ->
    {count(zero_entropy, Core), [draw_entropy]};
step({entropy, <<_:128>> = Id}, Core) ->
    {Core#core{fresh = Id}, []};
step({input, Bytes}, Core) when is_binary(Bytes) ->
    input(Bytes, Core);
step(idle, Core) ->
    idle(Core);
step({call_done, Serial, Id, Term, Opened}, Core) when is_list(Opened) ->
    case Core#core.session of
        #session{serial = Serial, calls = #{Id := {executing, _}}} ->
            finish(Id, Term, Opened, Core);
        _ ->
            %% A call of an ended session: what it opened has no table to
            %% enter.
            {Core, close_all(Opened)}
    end;
step({facet_down, Pid}, #core{session = #session{numbers = Numbers} = S} = Core) ->
    case Numbers of
        #{Pid := N} ->
            {set_session(S#session{facets = maps:remove(N, S#session.facets),
                                   numbers = maps:remove(Pid, Numbers)}, Core), []};
        #{} ->
            {Core, []}
    end;
step({facet_down, _Pid}, Core) ->
    {Core, []};
step({output, Stream, Body}, Core)
  when (Stream =:= terminal orelse Stream =:= events orelse Stream =:= files),
       is_binary(Body) ->
    output(Stream, Body, Core).

%%% Bytes in

%% One read of the link: its bytes are counted to the current session's
%% grant first, then its frames are taken in order.
input(Bytes, Core) ->
    {Core1, Granted} = consumed(byte_size(Bytes), Core),
    {Results, Deframer} = erx_hostlink_frame:feed(Bytes, Core1#core.deframer),
    {Core2, Actions} = lists:foldl(fun(Result, {CoreAcc, Acc}) ->
                                           {CoreNext, New} = deframed(Result, CoreAcc),
                                           {CoreNext, [New | Acc]}
                                   end, {Core1#core{deframer = Deframer}, []}, Results),
    {Core2, Granted ++ lists:append(lists:reverse(Actions))}.

%% A frame the deframer passed is taken by the receiver; one it discarded it
%% has counted.
deframed({ok, Frame}, #core{receiver = Receiver} = Core) ->
    {Result, Receiver1} = erx_hostlink_stream:accept(Frame, room_besides_reassembly(Core), Receiver),
    {Core1, Actions} = taken(Result, Core#core{receiver = Receiver1}),
    case last_frame(Result, Frame, Core1) of
        true ->
            %% No frame can follow this one: the session ends rather than wrap.
            {Core2, Ended} = end_session(exhausted, Core1),
            {Core2, Actions ++ Ended};
        false ->
            {Core1, Actions}
    end;
deframed({error, _Reason}, Core) ->
    {Core, []}.

%% Whether Frame moved the current session's sequence to its last seq: every
%% frame of the session does but a hello, one of another session and a repeat
%% below the sequence, whatever else the receiver made of it.
last_frame({hello, _}, _Frame, _Core) -> false;
last_frame({error, session}, _Frame, _Core) -> false;
last_frame({error, seq}, _Frame, _Core) -> false;
last_frame(_Result, #{session := Sid, seq := Seq},
           #core{session = #session{id = Sid}, limits = #{last_seq := LastSeq}}) -> Seq >= LastSeq;
last_frame(_Result, _Frame, _Core) -> false.

%% What one of the receiver's results asks of the session.
taken({frame, #{stream := Stream, body := Body}}, Core) when Stream =:= terminal; Stream =:= files ->
    {Core, [{deliver, Stream, Body}]};
taken({message, #{kind := reply}}, Core) ->
    {count(reply_from_host, Core), []};
taken({message, #{kind := Kind, id := Id, target := Target, payload := Payload}}, Core) ->
    complete(Kind, Id, Target, Payload, Core);
taken({hello, Message}, Core) ->
    hello(Message, Core);
taken({refused, #{kind := call, id := Id}}, Core) ->
    refused(Id, Core);
taken({refused, #{kind := cast}}, Core) ->
    {count(busy_cast, Core), []};
taken({refused, #{kind := reply}}, Core) ->
    {count(reply_from_host, Core), []};
taken(Result, Core) when Result =:= pending; Result =:= skipped ->
    {Core, []};
taken({error, _Reason}, Core) ->
    {Core, []};
taken({frame, #{}}, Core) ->
    %% A stream the target does not receive, which its deframer refuses.
    {count(stream_not_received, Core), []}.

%% A whole message: its payload is measured, then admitted.
complete(Kind, Id, Target, Payload, #core{config = #{measure := Measure}} = Core) ->
    case Measure(Payload) of
        {ok, Size} when is_integer(Size), Size >= 0 ->
            admit(Kind, Id, Size, target(Target, session(Core)), Payload, Core);
        _ ->
            {count(bad_payload, Core), []}
    end.

%% A call is entered in the window and executed, or answered at once when
%% its target names nothing; a cast is handed on.
admit(cast, _Id, Size, Target, Payload, Core) ->
    case {Size =< room(Core), Target} of
        {false, _} -> {count(busy_cast, Core), []};
        {true, error} -> {count(cast_without_target, Core), []};
        {true, {ok, To}} -> {Core, [{cast, serial(Core), To, Payload}]}
    end;
admit(call, Id, Size, Target, Payload, #core{limits = Limits} = Core) ->
    Room = room(Core),
    case disposition(Id, session(Core), Limits) of
        execute when Size =< Room ->
            Core1 = set_session(enter(Id, Size, session(Core), Limits), Core),
            case Target of
                {ok, To} -> {Core1, [{execute, serial(Core1), Id, To, Payload}]};
                error -> finish(Id, ?NO_TARGET, [], Core1)
            end;
        execute ->
            answer(Id, term_to_binary({error, busy}), Core);
        ignore ->
            {Core, []};
        {answer, Reply} ->
            answer(Id, Reply, Core)
    end.

%% A call whose first piece the stream refused for want of room: answered
%% busy if the window would run it, as the window says otherwise.
refused(Id, #core{limits = Limits} = Core) ->
    case disposition(Id, session(Core), Limits) of
        execute -> answer(Id, term_to_binary({error, busy}), Core);
        ignore -> {Core, []};
        {answer, Reply} -> answer(Id, Reply, Core)
    end.

target(0, _S) -> {ok, root};
target(N, #session{facets = Facets}) when is_map_key(N, Facets) -> {ok, map_get(N, Facets)};
target(_N, _S) -> error.

%%% The call window

%% What a call's identifier asks of the window: execute it (it is unseen, in
%% the window or above it with no executing call below its new bottom),
%% ignore it (it is executing), or answer it at once.
-spec disposition(pos_integer(), #session{}, limits()) ->
          execute | ignore | {answer, binary()}.
disposition(Id, #session{low = Low}, _Limits) when Id < Low ->
    {answer, term_to_binary({error, expired})};
disposition(Id, #session{low = Low, calls = Calls}, #{window := Window}) ->
    case Calls of
        #{Id := {executing, _}} ->
            ignore;
        #{Id := {answered, Reply}} ->
            {answer, Reply};
        #{Id := lost} ->
            {answer, term_to_binary({error, reply_lost})};
        #{} when Id < Low + Window ->
            execute;
        #{} ->
            NewLow = Id - Window + 1,
            case [C || C := {executing, _} <- Calls, C < NewLow] of
                [] -> execute;
                [_ | _] -> {answer, term_to_binary({error, busy})}
            end
    end.

%% Enters call Id as executing at its decoded size, moving the window up to
%% it first if it is above; disposition/3 has checked that nothing executing
%% falls out.
enter(Id, Size, #session{low = Low, calls = Calls} = S, #{window := Window}) ->
    NewLow = max(Low, Id - Window + 1),
    Inside = maps:filter(fun(C, _) -> C >= NewLow end, Calls),
    S#session{low = NewLow, calls = Inside#{Id => {executing, Size}}}.

%% A call's outcome: its reply rendered against the facet table and
%% encoded, kept if it fits once the call's own reservation is released, and
%% sent.
finish(Id, Term, Opened, #core{limits = Limits} = Core) ->
    {Reply, S, FacetActions} = reply(Term, Opened, session(Core), Core),
    Released = S#session{calls = maps:remove(Id, S#session.calls)},
    Fits = kept_bytes(Released) + byte_size(Reply) =< maps:get(kept, Limits)
        andalso committed(Released) + erx_hostlink_stream:held(Core#core.receiver)
                + byte_size(Reply) =< maps:get(resident, Limits),
    Entry = case Fits of
                true -> {answered, Reply};
                false -> lost
            end,
    Answered = Released#session{calls = (Released#session.calls)#{Id => Entry}},
    {Core1, Sent} = answer(Id, Reply, set_session(Answered, Core)),
    {Core1, FacetActions ++ Sent}.

%% The encoded reply for Term, with the session and facet actions it takes:
%% the facets it hands out enter the table only if the reply can be sent
%% whole, and every other facet the call opened is closed.
reply(Term, Opened, #session{numbers = Numbers} = S, #core{limits = Limits} = Core) ->
    Minted = [P || P <- lists:usort(Opened), is_pid(P), not is_map_key(P, Numbers)],
    Shown = lists:usort(pids(Term, [])),
    New = [P || P <- Minted, lists:member(P, Shown)],
    #{facets := MaxFacets, max_facet_number := MaxNumber} = Limits,
    TableFits = map_size(Numbers) + length(New) =< MaxFacets
        andalso S#session.next_facet + length(New) - 1 =< MaxNumber,
    WithNew = lists:foldl(fun add_facet/2, S, New),
    Sendable = maybe
                   true ?= TableFits,
                   {ok, Rendered} ?= render(Term, WithNew#session.numbers),
                   {ok, _} ?= sendable(Rendered, Core)
               else
                   _ -> unsendable
               end,
    case Sendable of
        {ok, Reply} ->
            {Reply, WithNew, [{monitor_facet, P} || P <- New] ++ close_all(Minted -- New)};
        unsendable ->
            %% The table stays as it was: no new facet was handed out.
            {term_to_binary(?UNSENDABLE), S, close_all(Minted)}
    end.

%% Term as the host sees it (rename/2), or `error` when two of a map's keys
%% would render alike.
render(Term, Numbers) ->
    try {ok, rename(Term, Numbers)}
    catch throw:map_keys_collide -> error
    end.

%% The encoding of a rendered reply, if the host can receive it: within the
%% message limit and passing `measure`. Anything but `{ok, _}` from
%% `measure` counts as a refusal.
sendable(Rendered, #core{config = #{measure := Measure}, limits = #{message_max := Max}}) ->
    Reply = term_to_binary(Rendered),
    case byte_size(Reply) =< Max andalso Measure(Reply) of
        {ok, _} -> {ok, Reply};
        _ -> error
    end.

add_facet(Pid, #session{next_facet = N} = S) ->
    S#session{facets = (S#session.facets)#{N => Pid},
              numbers = (S#session.numbers)#{Pid => N},
              next_facet = N + 1}.

pids(Pid, Acc) when is_pid(Pid) -> [Pid | Acc];
pids([H | T], Acc) -> pids(T, pids(H, Acc));
pids(Tuple, Acc) when is_tuple(Tuple) -> pids(tuple_to_list(Tuple), Acc);
pids(Map, Acc) when is_map(Map) -> pids(maps:to_list(Map), Acc);
pids(_, Acc) -> Acc.

%% Term as the host sees it: a facet of the table by its number, and every
%% other pid, reference, port and fun by its printed name, which the host
%% cannot address. A fun's name carries none of its captured values.
rename(Pid, Numbers) when is_pid(Pid) ->
    case Numbers of
        #{Pid := N} -> {'$host_cap', N};
        #{} -> {'$pid', list_to_binary(pid_to_list(Pid))}
    end;
rename(Ref, _Numbers) when is_reference(Ref) ->
    {'$ref', list_to_binary(ref_to_list(Ref))};
rename(Port, _Numbers) when is_port(Port) ->
    {'$port', list_to_binary(port_to_list(Port))};
rename(Fun, _Numbers) when is_function(Fun) ->
    {'$fun', iolist_to_binary(fun_name(Fun))};
rename([H | T], Numbers) ->
    [rename(H, Numbers) | rename(T, Numbers)];
rename(Tuple, Numbers) when is_tuple(Tuple) ->
    list_to_tuple(rename(tuple_to_list(Tuple), Numbers));
rename(Map, Numbers) when is_map(Map) ->
    Renamed = maps:from_list(rename(maps:to_list(Map), Numbers)),
    %% Keys that print alike would merge and drop a value: such a reply
    %% cannot be shown faithfully (render/2 refuses it).
    case map_size(Renamed) =:= map_size(Map) of
        true -> Renamed;
        false -> throw(map_keys_collide)
    end;
rename(Other, _Numbers) ->
    Other.

fun_name(Fun) ->
    {module, Module} = erlang:fun_info(Fun, module),
    {name, Name} = erlang:fun_info(Fun, name),
    {arity, Arity} = erlang:fun_info(Fun, arity),
    io_lib:format("~p:~p/~b", [Module, Name, Arity]).

close_all(Pids) -> [{close_facet, P} || P <- Pids, is_pid(P)].

%%% Hello

%% A hello: a call to the root whose payload is `{hello, Nonce}`. A repeat
%% of the current session's nonce gets that session's reply again; any
%% other nonce opens a session under a fresh identifier that differs from
%% the current session's.
hello(#{kind := call, id := HelloId, target := 0, payload := Payload}, Core) ->
    case nonce(Payload, Core) of
        {ok, Nonce} -> hello_nonce(HelloId, Nonce, Core);
        error -> {count(bad_hello, Core), []}
    end;
hello(#{}, Core) ->
    {count(bad_hello, Core), []}.

nonce(Payload, #core{config = #{measure := Measure, decode := Decode}}) ->
    maybe
        {ok, _Size} ?= Measure(Payload),
        {ok, {hello, <<_:16/binary>> = Nonce}} ?= Decode(Payload),
        {ok, Nonce}
    else
        _ -> error
    end.

hello_nonce(_HelloId, Nonce, #core{session = #session{nonce = Nonce, hello_reply = Reply}} = Core) ->
    {count(repeated_hello, Core), [{send, Reply}]};
hello_nonce(_HelloId, _Nonce, #core{fresh = none} = Core) ->
    {count(hello_without_entropy, Core), [draw_entropy]};
hello_nonce(_HelloId, _Nonce, #core{fresh = Fresh, session = #session{id = Fresh}} = Core) ->
    {count(repeated_entropy, Core#core{fresh = none}), [draw_entropy]};
hello_nonce(HelloId, Nonce, #core{fresh = Fresh} = Core) ->
    open(HelloId, Nonce, Fresh, Core).

%% Ends the current session, opens session Sid and answers the hello in one
%% frame of the all-zero session, numbered 0; new/1 has checked that the
%% reply fits one frame.
open(HelloId, Nonce, Sid, Core) ->
    {Core1, Ended} = end_session(replaced, Core),
    #core{config = #{build := Build, versions := Versions}, limits = #{last_seq := LastSeq},
          serial = Serial0, receiver = Receiver} = Core1,
    Serial = Serial0 + 1,
    Payload = term_to_binary({hello, Nonce, Sid, Build, Versions}),
    {ok, [Reply], _} = erx_hostlink_stream:message(reply, HelloId, 0, Payload,
                                                   erx_hostlink_stream:sender(?NO_SESSION)),
    S = #session{id = Sid, serial = Serial, nonce = Nonce, hello_reply = Reply,
                 sender = erx_hostlink_stream:sender(Sid, LastSeq),
                 grant = erx_hostlink_stream:grant()},
    Core2 = Core1#core{fresh = none, serial = Serial, session = S,
                       receiver = erx_hostlink_stream:set_session(Sid, Receiver)},
    {Core2, Ended ++ [{session_opened, Sid, Serial}, {send, Reply}, draw_entropy]}.

%% Closes the session's facets and ends it.
end_session(_Reason, #core{session = none} = Core) ->
    {Core, []};
end_session(Reason, #core{session = S, receiver = Receiver} = Core) ->
    Facets = [Pid || _ := Pid <- maps:iterator(S#session.facets, ordered)],
    {Core#core{session = none, receiver = erx_hostlink_stream:set_session(none, Receiver)},
     close_all(Facets) ++ [{session_ended, S#session.id, Reason}]}.

%%% Frames out and credit

%% Sends a reply, an encoded term, to call Id.
answer(Id, Reply, #core{session = S} = Core) ->
    case erx_hostlink_stream:message(reply, Id, 0, Reply, S#session.sender) of
        {ok, Wire, Sender} -> {set_session(S#session{sender = Sender}, Core), sends(Wire)};
        {error, exhausted} -> end_session(exhausted, Core)
    end.

output(_Stream, _Body, #core{session = none} = Core) ->
    {count(output_without_session, Core), []};
output(files, Body, Core) when byte_size(Body) > ?ERX_HOSTLINK_BODY_MAX ->
    %% A files body is one whole 9P2000.L message and is never split.
    {count(oversize_files_output, Core), []};
output(Stream, Body, Core) ->
    frames(Stream, 0, chunks(Body, ?ERX_HOSTLINK_BODY_MAX), Core).

%% A read of Bytes counted to the current session's grant, and the credit
%% frame it sends, if any.
consumed(_Bytes, #core{session = none} = Core) ->
    {Core, []};
consumed(Bytes, #core{session = S} = Core) ->
    granted(erx_hostlink_stream:consumed(Bytes, S#session.grant), Core).

idle(#core{session = none} = Core) ->
    {Core, []};
idle(#core{session = S} = Core) ->
    granted(erx_hostlink_stream:flush(S#session.grant), Core).

granted({none, Grant}, #core{session = S} = Core) ->
    {set_session(S#session{grant = Grant}, Core), []};
granted({{grant, Total}, Grant}, #core{session = S} = Core) ->
    frames(credit, Total, [<<>>], set_session(S#session{grant = Grant}, Core)).

%% Sends one frame of Stream per body, all of them or, when the sender
%% would pass its last seq, none, and ends the session instead.
frames(Stream, Target, Bodies, #core{session = S} = Core) ->
    Made = lists:foldl(fun(Body, {ok, Acc, Sender}) ->
                               case erx_hostlink_stream:frame(Stream, Target, Body, Sender) of
                                   {ok, Wire, Next} -> {ok, [Wire | Acc], Next};
                                   {error, exhausted} -> {error, exhausted}
                               end;
                          (_Body, {error, exhausted}) ->
                               {error, exhausted}
                       end, {ok, [], S#session.sender}, Bodies),
    case Made of
        {ok, Wire, Sender} -> {set_session(S#session{sender = Sender}, Core), sends(lists:reverse(Wire))};
        {error, exhausted} -> end_session(exhausted, Core)
    end.

sends(Wire) -> [{send, Bytes} || Bytes <- Wire].

%% Bin in pieces of at most Max bytes; an empty binary is one empty piece.
chunks(Bin, Max) when byte_size(Bin) =< Max -> [Bin];
chunks(Bin, Max) ->
    <<Piece:Max/binary, Rest/binary>> = Bin,
    [Piece | chunks(Rest, Max)].

%%% Derived accounting

%% Bytes the session holds outside the receiver: each executing call at its
%% decoded size and each kept reply.
committed(#session{calls = Calls} = S) ->
    lists:sum([Size || _ := {executing, Size} <- Calls]) + kept_bytes(S).

kept_bytes(#session{calls = Calls}) ->
    lists:sum([byte_size(Reply) || _ := {answered, Reply} <- Calls]).

%% What the resident limit leaves for the message the receiver reassembles,
%% whose own reservation a first piece replaces (erx_hostlink_stream:accept/3).
room_besides_reassembly(#core{session = none, limits = #{resident := Limit}}) -> Limit;
room_besides_reassembly(#core{session = S, limits = #{resident := Limit}}) ->
    max(0, Limit - committed(S)).

%% What is left of the resident limit.
room(#core{receiver = Receiver} = Core) ->
    room_besides_reassembly(Core) - erx_hostlink_stream:held(Receiver).

%%% State plumbing

session(#core{session = S}) -> S.

serial(#core{session = #session{serial = Serial}}) -> Serial.

set_session(S, Core) -> Core#core{session = S}.

counts(#core{deframer = Deframer, receiver = Receiver, counts = Counts}) ->
    maps:merge(maps:merge(erx_hostlink_frame:counts(Deframer), erx_hostlink_stream:counts(Receiver)),
               Counts).

count(Reason, #core{counts = Counts} = Core) ->
    Core#core{counts = maps:update_with(Reason, fun(N) -> N + 1 end, 1, Counts)}.
