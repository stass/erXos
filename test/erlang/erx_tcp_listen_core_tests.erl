%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Passive open, explored (docs/design-network-stack.md, "The listener: exploration, the
%% backlog and binds"): erx_tcp_listen_core with a model of the parties around it, each of
%% their effects a transition of its own, over three connections, two acceptors and an
%% accept credit of limit 2. Every reachable state is visited once, depth first, and checked
%% against the design's seven properties:
%%
%%   p1  every live connection holds a unit of the accept credit or is adopted;
%%   p2  the units on the counter are those their holders hold, plus one for each holder
%%       killed inside its window, never more than the limit, and back at zero once every
%%       connection has ended or been handed out, without a kill;
%%   p3  every call is answered exactly once, by the listener or by its end, and a
%%       quiescent state leaves none in flight but a call waiting on a live acceptor;
%%   p4  {ok, C} only after {bound, C}; bind only to an adopted connection, and once;
%%   p5  no call waits while a connection is queued and has not ended;
%%   p6  a waiting call is answered timeout at its deadline and not before, a handing call
%%       never;
%%   p7  calls and connections pair oldest first.
%%
%% A quiescent state is one in which no party owes a step: what is left is the
%% environment's choice (a kill, an acceptor's call or its end, the listener's close, the
%% grant's end, a pause, the clock). The model's own seeded faults, a connection that sends
%% its notice before its adoption and a pause that takes every exit, are options of
%% explore/1; the core's are seeded by test/host/erx_net_effect_test.rb.
-module(erx_tcp_listen_core_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LIMIT, 2).
-define(CONNS, 3).
%% Acceptor 1 calls with a timeout of one tick of the model clock, acceptor 2 with none.
-define(TIMEOUTS, {1, infinity}).
%% How many ends (a kill, an acceptor socket process ending, the interface, the grant or
%% the listener socket process ending) and pauses one run may hold.
-define(ENDS, 1).
-define(PAUSES, 1).

%% One connection: where it is in "An accepted connection's start" and its loop, its
%% mailbox, whether it holds the unit, its adoption (false, pending or true), whether it is
%% linked to the listener, and the socket process it was bound to.
-record(c, {st = none :: none | refused | wait | adopt | adopted | linked | queued | bound | ended,
            inbox = [] :: [term()],
            unit = false :: boolean(),
            adopted = false :: false | pending | true,
            linked_l = false :: boolean(),
            sp = none :: none | pid()}).

%% The whole system. m_queue and m_waiting are the model's own record of arrival order,
%% kept apart from the core's, for p7; bad collects the violations a transition's actions
%% made, which the state check reports with its own.
-record(m, {iface = {reserve, 1} :: {reserve | spawn | verdict, pos_integer()} | done | ended,
            conns :: tuple(),
            l = alive :: alive | ended,
            mbox = [] :: [term()],
            paused = false :: boolean(),
            core :: erx_tcp_listen_core:core(),
            l_links = [] :: [pid()],
            grant = alive :: alive | ended,
            resume_due = false :: boolean(),
            ls = open :: open | closing,
            in_flight = [] :: [pos_integer()],
            calls = {none, none} :: tuple(),
            sps = {alive, alive} :: tuple(),
            units = 0 :: integer(),
            stranded = 0 :: non_neg_integer(),
            now = 0 :: non_neg_integer(),
            m_queue = [] :: [pid()],
            m_waiting = [] :: [pos_integer()],
            bind_sent = [] :: [pid()],
            bound_sent = [] :: [pid()],
            bad = [] :: [atom()],
            ends_left :: non_neg_integer(),
            pauses_left :: non_neg_integer()}).

pid(N) -> list_to_pid("<0." ++ integer_to_list(N) ++ ".0>").
conn(I) -> pid(9000 + I).
sp(I) -> pid(9010 + I).
ls() -> pid(9020).
grant() -> pid(9021).
conn_index(Pid) -> lists:keyfind(Pid, 2, [{I, conn(I)} || I <- lists:seq(1, ?CONNS)]).
sp_index(Pid) -> element(1, lists:keyfind(Pid, 2, [{1, sp(1)}, {2, sp(2)}])).

%% --- The exploration ---------------------------------------------------------------

passive_open_is_explored_exhaustively_test_() ->
    {timeout, 600, fun() -> ?assertMatch({ok, _}, explore(#{})) end}.

%% A connection that sends its notice before its adoption: an accept takes it and its unit
%% comes back, so while its adoption is pending it holds neither a unit nor a socket (p1);
%% and where the adoption is refused first, the bind goes to a connection never adopted
%% (p4). Depth first, whichever the search meets first is reported.
notice_before_adoption_is_caught_test_() ->
    {timeout, 600,
     fun() ->
             {violation, Property, _} = explore(#{fault => notice_before_adoption}),
             ?assert(lists:member(Property, [p1, p4]))
     end}.

%% A pause that takes the exits of every link: a connection that sends its notice and ends
%% while the listener is paused has its exit taken first and is queued dead.
pause_that_takes_every_exit_is_caught_test_() ->
    {timeout, 600,
     fun() ->
             {violation, Property, _} = explore(#{fault => pause_takes_exits}),
             ?assert(lists:member(Property, [p2, p3]))
     end}.

-spec explore(map()) -> {ok, non_neg_integer()} | {violation, atom(), #m{}}.
explore(Opts) ->
    Seen = ets:new(seen, [set, private]),
    Init = #m{conns = list_to_tuple(lists:duplicate(?CONNS, #c{})),
              ends_left = maps:get(ends, Opts, ?ENDS), pauses_left = maps:get(pauses, Opts, ?PAUSES),
              core = erx_tcp_listen_core:new(ls(), grant())},
    true = ets:insert_new(Seen, {key(Init)}),
    try dfs([Init], Seen, Opts)
    after ets:delete(Seen)
    end.

dfs([], Seen, _Opts) ->
    {ok, ets:info(Seen, size)};
%% A state whose transition's actions broke a property carries it in bad, and is reported
%% with whatever the state itself breaks, the lowest-numbered property first.
dfs([M | Stack], Seen, Opts) ->
    Next = transitions(M, Opts),
    case check(M, Next) of
        [] -> dfs([S || {_, S} <- Next, ets:insert_new(Seen, {key(S)})] ++ Stack, Seen, Opts);
        Violations -> {violation, hd(Violations), M}
    end.

%% A visited state is kept as the digest of its canonical form: what can no longer matter
%% is cleared, so states that differ only there are one. An ended connection is only
%% ended; once the listener has ended, only the connections, the units and the grant still
%% act, since every call was answered at its end.
key(M) -> erlang:md5(term_to_binary(canonical(M), [deterministic])).

canonical(#m{conns = Conns} = M0) ->
    M = M0#m{conns = list_to_tuple([case C of #c{st = ended} -> #c{st = ended}; _ -> C end
                                    || C <- tuple_to_list(Conns)])},
    case M of
        #m{l = ended} -> M#m{core = ended, ls = closing, calls = ended, sps = ended, now = 0,
                             m_queue = [], m_waiting = [], bind_sent = [], bound_sent = []};
        _ -> M
    end.

%% --- Properties ----------------------------------------------------------------------

check(M, Next) ->
    Quiescent = not lists:any(fun({Kind, _}) -> Kind =:= owed end, Next),
    lists:usort(M#m.bad ++ [P || {P, false} <- [{p1, p1(M)}, {p2, p2(M, Quiescent)},
                                                 {p3, p3(M, Quiescent)}, {p5, p5(M)}]]).

p1(#m{conns = Conns} = M) ->
    lists:all(fun(I) ->
                      #c{st = St, unit = Unit, adopted = Adopted} = element(I, Conns),
                      not alive(St) orelse Unit orelse Adopted =:= true
                          orelse unit_with_listener(conn(I), M)
              end, lists:seq(1, ?CONNS)).

unit_with_listener(C, #m{l = alive, mbox = Mbox, core = Core}) ->
    lists:member({queued, C}, Mbox) orelse lists:member(C, queue(Core));
unit_with_listener(_C, _M) ->
    false.

p2(#m{units = Units}, _) when Units > ?LIMIT; Units < 0 ->
    false;
p2(#m{l = ended}, _) ->
    true;
p2(#m{iface = Iface, conns = Conns, mbox = Mbox, core = Core, units = Units,
      stranded = Stranded}, Quiescent) ->
    Held = length([x || {spawn, _} <- [Iface]])
        + length([x || #c{unit = true} <- tuple_to_list(Conns)])
        + length([x || {queued, _} <- Mbox]) + length(queue(Core)),
    Settled = lists:all(fun(#c{st = St}) -> lists:member(St, [none, refused, ended, bound]) end,
                        tuple_to_list(Conns)),
    Units =:= Held + Stranded
        andalso not (Quiescent andalso Stranded =:= 0 andalso Settled andalso Units =/= 0).

p3(#m{l = ended, in_flight = InFlight}, _) ->
    InFlight =:= [];
p3(_M, false) ->
    true;
p3(#m{in_flight = InFlight, core = Core, sps = Sps}, true) ->
    #{waiting := Waiting} = erx_tcp_listen_core:view(Core),
    lists:all(fun(N) ->
                      lists:keymember(N, 1, Waiting) andalso element(N, Sps) =:= alive
              end, InFlight).

p5(#m{core = Core, conns = Conns}) ->
    #{waiting := Waiting, queue := Queue} = erx_tcp_listen_core:view(Core),
    Waiting =:= []
        orelse not lists:any(fun(C) ->
                                     {I, _} = conn_index(C),
                                     alive((element(I, Conns))#c.st)
                             end, Queue).

queue(Core) -> maps:get(queue, erx_tcp_listen_core:view(Core)).

alive(St) -> lists:member(St, [wait, adopt, adopted, linked, queued, bound]).

%% --- Transitions -----------------------------------------------------------------------

%% Every transition enabled in M, each {owed | env, Next}: owed when a party must take it,
%% env when it is the environment's choice.
%% The listener's end is the last state explored: from then on only the model's own
%% connections act, every call has been answered and the core takes nothing more, so no
%% property can change.
transitions(#m{l = ended}, _Opts) ->
    [];
transitions(#m{ends_left = Ends, pauses_left = Pauses} = M, Opts) ->
    All = lists:append([iface(M), conns(M, Opts), listener(M, Opts), grant(M), acceptors(M),
                        clock(M)]),
    [T || {Kind, S} <- All,
          T <- case Kind of
                   ends when Ends > 0 -> [{env, S#m{ends_left = Ends - 1}}];
                   pause when Pauses > 0 -> [{env, S#m{pauses_left = Pauses - 1}}];
                   ends -> [];
                   pause -> [];
                   _ -> [{Kind, S}]
               end].

%% The interface handles its handshakes one at a time: it reserves a unit or finds the
%% credit full, spawns the connection, and sends it go or abandon; it may end between any
%% two of these, stranding a unit it reserved and did not hand on.
iface(#m{iface = {reserve, I}, units = Units} = M) when Units < ?LIMIT ->
    [{owed, M#m{iface = {spawn, I}, units = Units + 1}}, iface_end(M)];
iface(#m{iface = {reserve, I}} = M) ->
    [{owed, set_conn(I, #c{st = refused}, M#m{iface = next_handshake(I)})}, iface_end(M)];
%% The spawn and the verdict are one step: between them the interface shows nothing to
%% another party but its end, which is the one transition kept apart.
iface(#m{iface = {spawn, I}} = M) ->
    Spawned = set_conn(I, #c{st = wait, unit = true}, M#m{iface = {verdict, I}}),
    [{owed, deliver(conn(I), Verdict, Spawned#m{iface = next_handshake(I)})}
     || Verdict <- [go, abandon]]
        ++ [iface_end(M), iface_end(Spawned)];
iface(_M) ->
    [].

next_handshake(?CONNS) -> done;
next_handshake(I) -> {reserve, I + 1}.

iface_end(#m{iface = Iface, conns = Conns, stranded = Stranded} = M) ->
    Lost = length([x || {spawn, _} <- [Iface]]),
    Down = lists:foldl(fun(I, Acc) ->
                               case element(I, Conns) of
                                   #c{st = wait} -> deliver(conn(I), 'DOWN', Acc);
                                   _ -> Acc
                               end
                       end, M, lists:seq(1, ?CONNS)),
    {ends, Down#m{iface = ended, stranded = Stranded + Lost}}.

conns(M, Opts) ->
    lists:append([conn_steps(I, M, Opts) || I <- lists:seq(1, ?CONNS)]).

conn_steps(I, #m{conns = Conns} = M, Opts) ->
    C = element(I, Conns),
    Kill = [{ends, kill(I, M)} || alive(C#c.st)],
    Kill ++ adoption(I, C, M) ++ conn_step(I, C, M, Opts).

%% The grant answers an adoption ok or refuses it, past its limits or because it has ended.
adoption(I, #c{st = St, adopted = pending} = C, #m{grant = Grant} = M) when St =/= ended ->
    Refused = case C#c.unit of
                  true -> end_conn(I, M#m{units = M#m.units - 1});
                  false -> end_conn(I, M)
              end,
    Ok = set_conn(I, C#c{adopted = true, st = case St of adopt -> adopted; _ -> St end}, M),
    [{owed, Ok} || Grant =:= alive] ++ [{owed, Refused}];
adoption(_I, _C, _M) ->
    [].

%% Waiting for the verdict alone: go, abandon or the interface's 'DOWN', the first of them.
conn_step(I, #c{st = wait, inbox = Inbox} = C, M, Opts) ->
    case [X || X <- Inbox, lists:member(X, [go, abandon, 'DOWN'])] of
        [go | _] ->
            Rest = lists:delete('DOWN', lists:delete(go, Inbox)),
            case maps:get(fault, Opts, none) of
                notice_before_adoption ->
                    [{owed, set_conn(I, C#c{st = adopted, inbox = Rest, adopted = pending}, M)}];
                _ ->
                    %% The adoption and the link to the listener are one step with the
                    %% verdict: between them the connection shows nothing to another
                    %% party. A kill there strands the unit as one in wait does; the
                    %% grant's end there is reached as its end just before, which refuses
                    %% the adoption, or just after, which the connection meets in its loop.
                    Mid = set_conn(I, C#c{st = adopt, inbox = Rest, adopted = pending}, M),
                    [{owed, link_if_adopted(I, S, Opts)}
                     || {owed, S} <- adoption(I, element(I, Mid#m.conns), Mid)]
            end;
        [_AbandonOrDown | _] ->
            [{owed, end_conn(I, M#m{units = M#m.units - 1})}];
        [] ->
            []
    end;
%% Adopted: it links to the listener, answered noproc once the listener has ended...
conn_step(I, #c{st = adopted} = C, #m{l = alive} = M, _Opts) ->
    [{owed, set_conn(I, C#c{st = linked, linked_l = true}, M)}];
conn_step(I, #c{st = adopted, inbox = Inbox} = C, M, _Opts) ->
    [{owed, set_conn(I, C#c{st = linked, inbox = Inbox ++ [exit_l]}, M)}];
%% ...and sends its notice under the unit, which passes to the listener.
conn_step(I, #c{st = linked} = C, #m{l = alive, mbox = Mbox} = M, _Opts) ->
    [{owed, set_conn(I, C#c{st = queued, unit = false}, M#m{mbox = Mbox ++ [{queued, conn(I)}]})}];
conn_step(I, #c{st = linked} = C, M, _Opts) ->
    [{owed, set_conn(I, C#c{st = queued, unit = false}, M)}];
conn_step(I, #c{st = St, inbox = [Msg | Rest]} = C, M, _Opts) when St =:= queued; St =:= bound ->
    [{owed, loop(I, St, Msg, C#c{inbox = Rest}, M)}];
conn_step(_I, _C, _M, _Opts) ->
    [].

link_if_adopted(I, #m{conns = Conns} = M, Opts) ->
    case element(I, Conns) of
        #c{st = adopted} = C -> [{owed, Linked}] = conn_step(I, C, M, Opts), Linked;
        _ -> M
    end.

%% The connection's loop. Queued: bind links it to the socket process and answers bound,
%% unless the socket process has ended, when it closes and its exit answers the call; its
%% listener's exit aborts it. Bound: its listener's exit changes nothing, its socket
%% process's closes it. The grant's exit ends it either way.
loop(I, queued, {bind, Sp}, C, #m{sps = Sps, mbox = Mbox, l = L, bound_sent = BoundSent} = M) ->
    case element(sp_index(Sp), Sps) of
        dead ->
            end_conn(I, set_conn(I, C, M));
        alive ->
            Mbox1 = case L of alive -> Mbox ++ [{bound, conn(I)}]; ended -> Mbox end,
            set_conn(I, C#c{st = bound, sp = Sp},
                     M#m{mbox = Mbox1, bound_sent = lists:usort([conn(I) | BoundSent])})
    end;
loop(I, bound, exit_l, C, M) ->
    set_conn(I, C, M);
loop(I, _St, _Msg, C, M) ->
    %% exit_l while queued, exit_sp, exit_grant, or a second bind, which ends it.
    end_conn(I, set_conn(I, C, M)).

%% A connection killed: a unit it held is stranded; its exit reaches the listener through
%% their link.
kill(I, #m{conns = Conns, stranded = Stranded} = M) ->
    case element(I, Conns) of
        #c{unit = true} = C -> end_conn(I, set_conn(I, C#c{unit = false}, M#m{stranded = Stranded + 1}));
        _ -> end_conn(I, M)
    end.

end_conn(I, #m{conns = Conns, l = L, mbox = Mbox} = M) ->
    C = element(I, Conns),
    Mbox1 = case C#c.linked_l andalso L =:= alive of
                true -> Mbox ++ [{exit, conn(I)}];
                false -> Mbox
            end,
    set_conn(I, C#c{st = ended, unit = false, inbox = []}, M#m{mbox = Mbox1}).

set_conn(I, C, #m{conns = Conns} = M) -> M#m{conns = setelement(I, Conns, C)}.

deliver(Pid, Msg, #m{conns = Conns} = M) ->
    {I, _} = conn_index(Pid),
    case element(I, Conns) of
        #c{st = St, inbox = Inbox} = C when St =/= ended, St =/= none, St =/= refused ->
            set_conn(I, C#c{inbox = Inbox ++ [Msg]}, M);
        _ ->
            M
    end.

%% The listener takes its next message, or while paused the first its pause may take;
%% runs its deadlines when not paused; and may pause before any step.
listener(#m{l = ended}, _Opts) ->
    [];
listener(#m{mbox = Mbox, paused = Paused, core = Core, now = Now} = M, Opts) ->
    Take = case [X || X <- Mbox, takes(X, Paused, Opts)] of
               [Msg | _] -> [{owed, take(Msg, M#m{mbox = lists:delete(Msg, Mbox)})}];
               [] -> []
           end,
    Expire = [{owed, step(expired, M)}
              || not Paused, erx_tcp_listen_core:next_deadline(Core) =< Now],
    %% A pause shows only in what it holds back, so one is taken with a message waiting.
    Pause = [{pause, M#m{paused = true, resume_due = true}} || not Paused, Mbox =/= []],
    Take ++ Expire ++ Pause.

takes(_Msg, false, _Opts) -> true;
takes(resume, true, _Opts) -> true;
takes({exit, Pid}, true, Opts) ->
    Pid =:= grant() orelse maps:get(fault, Opts, none) =:= pause_takes_exits;
takes(_Msg, true, _Opts) -> false.

take(resume, M) ->
    M#m{paused = false};
take({call, N, Sp, Timeout}, #m{m_waiting = W} = M) ->
    step({accept, N, Sp, Timeout}, M#m{m_waiting = W ++ [N]});
take({queued, C}, #m{m_queue = Q} = M) ->
    step({queued, C}, M#m{m_queue = Q ++ [C]});
take({exit, Pid}, #m{m_queue = Q} = M) ->
    step({exit, Pid}, M#m{m_queue = lists:delete(Pid, Q)});
take(Msg, M) ->
    step(Msg, M).

step(Event, #m{core = Core0, now = Now} = M) ->
    {Core, Actions} = erx_tcp_listen_core:step(Event, Core0, #{now => Now}),
    lists:foldl(fun act/2, M#m{core = Core}, Actions).

act({link, Sp}, #m{sps = Sps, mbox = Mbox, l_links = Links} = M) ->
    case element(sp_index(Sp), Sps) of
        dead -> M#m{mbox = Mbox ++ [{exit, Sp}]};
        alive -> M#m{l_links = lists:usort([Sp | Links])}
    end;
act({unlink, Pid}, #m{l_links = Links, conns = Conns} = M) ->
    M1 = M#m{l_links = lists:delete(Pid, Links)},
    case conn_index(Pid) of
        {I, _} -> set_conn(I, (element(I, Conns))#c{linked_l = false}, M1);
        false -> M1
    end;
act({bind, C, Sp}, #m{conns = Conns, m_queue = Q, m_waiting = W, bind_sent = Sent} = M) ->
    {I, _} = conn_index(C),
    N = sp_index(Sp),
    Bad = [p4 || (element(I, Conns))#c.adopted =/= true orelse lists:member(C, Sent)]
        ++ [p7 || Q =:= [] orelse hd(Q) =/= C orelse W =:= [] orelse hd(W) =/= N],
    deliver(C, {bind, Sp}, M#m{m_queue = lists:delete(C, Q), m_waiting = lists:delete(N, W),
                               bind_sent = lists:usort([C | Sent]), bad = M#m.bad ++ Bad});
act({reply, N, Reply}, #m{in_flight = InFlight, m_waiting = W, calls = Calls, now = Now,
                          bound_sent = BoundSent} = M) ->
    Bad = [p3 || not lists:member(N, InFlight)]
        ++ case Reply of
               {error, timeout} ->
                   {called, At} = element(N, Calls),
                   [p6 || not lists:member(N, W) orelse element(N, ?TIMEOUTS) =:= infinity
                              orelse At + element(N, ?TIMEOUTS) > Now];
               {ok, C} ->
                   [p4 || not lists:member(C, BoundSent)];
               {error, econnaborted} ->
                   []
           end,
    M#m{in_flight = lists:delete(N, InFlight), m_waiting = lists:delete(N, W),
        bad = M#m.bad ++ Bad};
act(take_unit, #m{units = Units} = M) ->
    M#m{units = Units - 1};
act(stop, M) ->
    listener_end(M).

%% The listener's end: each connection linked to it gets its exit, its socket process
%% answers every call it still holds, and the acceptors' socket processes it linked stop.
listener_end(#m{conns = Conns, l_links = Links} = M0) ->
    M1 = lists:foldl(fun(I, Acc) ->
                             case element(I, Conns) of
                                 #c{linked_l = true, st = St} when St =/= ended ->
                                     deliver(conn(I), exit_l, Acc);
                                 _ ->
                                     Acc
                             end
                     end, M0#m{l = ended, mbox = [], paused = false, in_flight = [], l_links = []},
                     lists:seq(1, ?CONNS)),
    lists:foldl(fun(Sp, Acc) -> sp_end(sp_index(Sp), Acc) end, M1, Links).

%% The grant resumes a paused listener, and may end, which ends the listener and every
%% connection it adopted, and refuses every adoption still pending.
grant(#m{grant = ended}) ->
    [];
grant(#m{resume_due = Due, l = L, mbox = Mbox, conns = Conns} = M) ->
    Resume = [{owed, M#m{resume_due = false, mbox = Mbox ++ [resume]}} || Due, L =:= alive],
    Ended0 = M#m{grant = ended, resume_due = false,
                 mbox = case L of alive -> Mbox ++ [{exit, grant()}]; ended -> Mbox end},
    Ended = lists:foldl(fun(I, Acc) ->
                                case alive((element(I, Conns))#c.st) of
                                    true -> deliver(conn(I), exit_grant, Acc);
                                    false -> Acc
                                end
                        end, Ended0, lists:seq(1, ?CONNS)),
    Resume ++ [{ends, Ended}].

%% Each acceptor calls once, through the listener's socket process, and its socket process
%% may end at any point; the listener's socket process may close, which is its exit.
acceptors(#m{l = ended}) ->
    [];
acceptors(#m{l = L, ls = Ls, calls = Calls, sps = Sps, in_flight = InFlight, mbox = Mbox,
             now = Now} = M) ->
    Call = [{env, M#m{calls = setelement(N, Calls, {called, Now}),
                      in_flight = lists:usort([N | InFlight]),
                      mbox = Mbox ++ [{call, N, sp(N), element(N, ?TIMEOUTS)}]}}
            || N <- [1, 2], element(N, Calls) =:= none, L =:= alive, Ls =:= open],
    End = [{ends, sp_end(N, M)} || N <- [1, 2], element(N, Sps) =:= alive],
    Close = [{ends, M#m{ls = closing, mbox = Mbox ++ [{exit, ls()}]}} || L =:= alive, Ls =:= open],
    Call ++ End ++ Close.

sp_end(N, #m{sps = Sps, l = L, l_links = Links, mbox = Mbox, conns = Conns} = M) ->
    Sp = sp(N),
    Mbox1 = case L =:= alive andalso lists:member(Sp, Links) of
                true -> Mbox ++ [{exit, Sp}];
                false -> Mbox
            end,
    M1 = M#m{sps = setelement(N, Sps, dead), mbox = Mbox1, l_links = lists:delete(Sp, Links)},
    lists:foldl(fun(I, Acc) ->
                        case element(I, Conns) of
                            #c{sp = Sp, st = bound} -> deliver(conn(I), exit_sp, Acc);
                            _ -> Acc
                        end
                end, M1, lists:seq(1, ?CONNS)).

%% Time matters only to a waiting call: the clock moves while one has a deadline ahead.
clock(#m{l = alive, core = Core, now = Now} = M) ->
    case erx_tcp_listen_core:next_deadline(Core) of
        Deadline when is_integer(Deadline), Deadline > Now -> [{env, M#m{now = Now + 1}}];
        _ -> []
    end;
clock(_M) -> [].
