%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_srv).
-moduledoc """
The domain service (docs/design-system.md, "Creating a domain", "Ending a
domain", "System services"): the domain library's one registrant, which
creates the manifest's configured domains in boot order at its first start
and every requested domain after, keeps a domain pid for each, has the
system domain's connection agent (erx_connections) open the system side of
each domain's system connection before its first thread runs, answers a
create once the domain's init reports ready through its domain pid, stops a
domain that does not report within its boot timeout or whose side the agent
reports ended, and on each
{domain_ended, Id, End, Record} has the agent close that side, disconnects
the connection, ends its domain pid with {domain_down, Id, Info}, retires it
and restarts a configured domain within its restart intensity.

Its state, erx_domain_core's, lives in its own heap and nowhere else. The
service is never restarted: its end, however it comes, ends the system
domain (erx_domain_sup), and no domain outlives that, so no successor needs
its records. Where the system domain has no domain library (a hosted
runtime, whose erx_domain_lib does not load, or a root that built none),
the service runs with none and every create is {error, enotsup}.

Callers are the system domain's own processes; requests from other domains
reach it only through facets, which arrive with the connections.
""".
-behaviour(gen_server).

-export([start_link/0, start_link/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

%% Every domain is the system principal's, number 1, the one principal the library's
%% view has (include/erx/dom.h, erx_dom_principal_t).
-define(SYSTEM_PRINCIPAL, 1).
%% The keys of a request beyond its name and boot_timeout: erx_domain_lib:spec()'s, less
%% id, principal and domain_pid, which the service sets.
-define(REQUEST_KEYS, [runtime, release, release_files, memory, outer, grant, lane, args, env,
                       connections, flags, spaces, limits]).
%% How long a domain's init has to report ready, in milliseconds, unless its request
%% sets boot_timeout (docs/design-domains.md, "Erlang interface"); a configured domain
%% always has this long.
-define(BOOT_TIMEOUT, 10000).
%% The longest boot_timeout erlang:start_timer/3 takes.
-define(BOOT_TIMEOUT_MAX, 16#ffffffff).
%% A domain that has not ended, whose domain pid stands for it (erx_domain_core:ended/5).
-define(IS_LIVE(Life), (Life =:= built orelse Life =:= running orelse Life =:= ready orelse Life =:= stopping)).

start_link() ->
    start_link(#{}).

-doc """
Opts may name lib, the domain library's module (erx_domain_lib), agent, the
connection agent's (erx_connections), and exports, the export table's
(erx_dist), for a host test's stand-ins.
""".
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

init(Opts) ->
    process_flag(trap_exit, true),
    Lib = library(maps:get(lib, Opts, erx_domain_lib)),
    Agent = maps:get(agent, Opts, erx_connections),
    Exports = maps:get(exports, Opts, erx_dist),
    %% Whether the runtime is a node, as kernel's start left it, since net_kernel starts
    %% before any application and lives as long as the runtime (close_side/4). Waiting
    %% holds, by domain id, each create whose domain has not reported ready yet: its
    %% caller, the domain, its domain pid's secret, that pid until it ends and gone after,
    %% and, once the domain has ended, the life it ended in and its Info (ended/3).
    {ok, #{lib => Lib, agent => Agent, exports => Exports, node => erlang:is_alive(), core => undefined,
           configured => #{}, waiting => #{}},
     {continue, boot}}.

%% The library, registered with this process as the one that hears of every end, or none.
library(Lib) ->
    try Lib:register() of
        ok -> Lib;
        {error, Reason} -> error({domain_library, Reason})
    catch
        error:undef -> none
    end.

handle_continue(boot, #{lib := Lib} = State) ->
    case configured(Lib) of
        {ok, #{host := Host, domains := Rows}} ->
            Ordered = lists:sort(fun(#{place := A}, #{place := B}) -> A =< B end, Rows),
            Configured = maps:from_list([{Row, Entry} || #{row := Row} = Entry <- Ordered]),
            Booted = State#{core := erx_domain_core:new(Host), configured := Configured},
            {noreply, lists:foldl(fun start_configured/2, Booted, Ordered)};
        {error, _} ->
            {noreply, State#{core := erx_domain_core:new(<<>>)}}
    end.

configured(none) -> {error, enotsup};
configured(Lib) -> Lib:configured().

handle_call({create, Spec}, From, State) ->
    case create(Spec, State) of
        {{waiting, {erx_domain, Id, _, Pid} = Domain}, #{core := Core, waiting := Waiting} = Next} ->
            %% Answered by ready/3, or by settle/2 once the domain and its pid are gone.
            {ok, #{ref := Ref}} = erx_domain_core:fetch(Id, Core),
            Waiter = #{from => From, domain => Domain, ref => Ref, pid => Pid, ended => none},
            {noreply, Next#{waiting := Waiting#{Id => Waiter}}};
        {{ready, Domain}, Next} ->
            {reply, {ok, Domain}, Next};
        {{error, _} = Error, Next} ->
            {reply, Error, Next}
    end;
handle_call({info, Id}, From, #{core := Core} = State) ->
    %% The domain pid answers the caller itself, so a flood in its mailbox delays only
    %% this caller, never the service.
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{pid := Pid, ref := Ref, state := Life}} when ?IS_LIVE(Life) ->
            Pid ! {Ref, info, From},
            {noreply, State};
        _ ->
            {reply, {error, badarg}, State}
    end;
handle_call({test_record, Id, Peer}, _From, #{core := Core} = State) when is_integer(Peer), Peer > 0 ->
    %% A test's hook: the domain pid of ready domain Id writes a connection_down about
    %% connection Peer, which the domain holds none of, so its agent answers it unmapped.
    %% Peer is an id never spent, so the record can name no connection a domain holds.
    case erx_domain_core:unspent(Peer, Core) of
        true ->
            {Reply, Next} = record(Id, Peer, {erx_connection_down, Peer, noconnection}, State),
            {reply, Reply, Next};
        false ->
            {reply, {error, badarg}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({domain_ended, Id, End, _Record}, State) ->
    {noreply, ended(Id, End, State)};
handle_info({domain_ready, Ref, Id, _Agents}, State) ->
    {noreply, ready(Id, Ref, State)};
handle_info({domain_answer, Ref, Id, Answer}, State) ->
    {noreply, answer(Id, Ref, Answer, State)};
handle_info({timeout, _Timer, {boot_timeout, Id}}, #{core := Core} = State) ->
    %% Ids are never reused, so the timer of a domain that reported ready or ended finds
    %% it ready or gone. A domain stopping for its timeout takes no late report
    %% (ready/3), and its create is answered timeout once the stop's end arrives.
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{state := running}} ->
            logger:notice("erx_domain: domain ~b did not report ready in time; stopping it", [Id]),
            stop(Id, State),
            {noreply, State#{core := erx_domain_core:stopping(Id, Core)}};
        _ ->
            {noreply, State}
    end;
handle_info({stop_request, Ref, Id}, #{core := Core} = State) ->
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{ref := Ref, state := Life}} when ?IS_LIVE(Life) -> stop(Id, State);
        _ -> ok
    end,
    {noreply, State};
handle_info({system_side_ended, Id}, #{core := Core} = State) ->
    %% The agent's report that a side it opened for this service ended before the service
    %% closed it: this runtime ended the connection, for a malformed frame, a peer bound
    %% passed or its owner's end, so the domain goes (docs/design-system.md, "A lost
    %% system connection ends the domain"). Ids are never reused, so a late report for an
    %% ended domain finds it ended or retired.
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{state := Life}} when ?IS_LIVE(Life) ->
            logger:notice("erx_domain: domain ~b's system side ended; stopping the domain", [Id]),
            stop(Id, State);
        _ ->
            ok
    end,
    {noreply, State};
handle_info({'EXIT', Pid, _Reason}, #{core := Core} = State) when Core =/= undefined ->
    %% A domain pid that died first, by a kill or a fault of its own, stops its domain.
    case erx_domain_core:find_pid(Pid, Core) of
        {ok, #{id := Id, state := Life}} when ?IS_LIVE(Life) -> stop(Id, State);
        _ -> ok
    end,
    {noreply, pid_ended(Pid, State)};
handle_info(_Message, State) ->
    {noreply, State}.

%% A request: its name and fields checked, then built as a configured row is.
create(_Spec, #{lib := none} = State) ->
    {{error, enotsup}, State};
create(#{name := Name} = Spec, State) ->
    Timeout = maps:get(boot_timeout, Spec, ?BOOT_TIMEOUT),
    Fields = maps:without([name, boot_timeout], Spec),
    case [Key || Key <- maps:keys(Fields), not lists:member(Key, ?REQUEST_KEYS)] of
        [Key | _] ->
            {{error, {bad_spec, Key}}, State};
        [] when not (Timeout =:= infinity orelse
                     (is_integer(Timeout) andalso Timeout >= 0 andalso Timeout =< ?BOOT_TIMEOUT_MAX)) ->
            {{error, {bad_spec, boot_timeout}}, State};
        [] ->
            case erx_ident:new(Name) of
                {error, bad_identifier} = Error ->
                    {Error, State};
                Ident ->
                    #{lib := Lib} = State,
                    Make = fun(Id, Pid) ->
                                   Lib:create(Fields#{id => Id, name => Name, principal => ?SYSTEM_PRINCIPAL,
                                                      domain_pid => Pid})
                           end,
                    build(Ident, ?SYSTEM_PRINCIPAL, request, Make, Timeout, State)
            end
    end;
create(_Spec, State) ->
    {{error, {bad_spec, name}}, State}.

start_configured(#{row := Row, name := Name, principal := Principal}, #{lib := Lib} = State) ->
    case erx_ident:new(Name) of
        {error, bad_identifier} ->
            logger:error("erx_domain: configured row ~b has no identifier for a name", [Row]),
            State;
        Ident ->
            Make = fun(Id, Pid) -> Lib:configured(Id, Row, Pid) end,
            case build(Ident, Principal, {configured, Row}, Make, ?BOOT_TIMEOUT, State) of
                {{error, Reason}, Next} ->
                    logger:error("erx_domain: configured domain ~ts did not start: ~0p", [Name, Reason]),
                    Next;
                {_Started, Next} ->
                    Next
            end
    end.

%% Admits Ident, makes its domain pid, which its boot page names, has the library
%% make it with Make(Id, Pid) and starts its first thread once the system side of its
%% system connection is open and the pid is exported to the domain. A refused plan ends
%% the pid, unlinked first, so no domain is stopped for it; a domain the library made
%% whose side, export or start is refused is stopped, and its end retires it as any end
%% does. A started domain is waiting for its init's ready report, which Timeout bounds,
%% unless it has no system connection, the one path a report could take: then it is
%% ready at its start.
build(Ident, Principal, Origin, Make, Timeout, #{core := Core} = State) ->
    case erx_domain_core:admit(Ident, Principal, Origin, Core) of
        {error, _} = Error ->
            {Error, State};
        {ok, #{id := Id, node := Node}, Admitted} ->
            Ref = make_ref(),
            Pid = erx_domain_pid:start_link(self(), Id, Node, Ref),
            case made(Make, Id, Pid) of
                {ok, #{connection := Connection, ctl_slots := CtlSlots} = Created} ->
                    Built = erx_domain_core:built(Id, Connection, CtlSlots, Pid, Ref, Admitted),
                    Next = State#{core := Built},
                    Domain = {erx_domain, Id, Node, Pid},
                    case started(Id, Pid, Ref, Created#{node => Node}, Next) of
                        ok when Connection =:= 0 ->
                            Ready = erx_domain_core:ready(Id, erx_domain_core:running(Id, Built)),
                            {{ready, Domain}, State#{core := Ready}};
                        ok ->
                            boot_timer(Id, Timeout),
                            {{waiting, Domain}, State#{core := erx_domain_core:running(Id, Built)}};
                        {error, _} = Refused ->
                            stop(Id, Next),
                            {Refused, Next}
                    end;
                {error, Reason} ->
                    unlink(Pid),
                    exit(Pid, kill),
                    {{error, refusal(Reason)}, State#{core := erx_domain_core:failed(Id, Admitted)}}
            end
    end.

%% Any other exception ends the domain pid before it reaches the service, so no pid
%% outlives a plan that was never made.
made(Make, Id, Pid) ->
    try Make(Id, Pid)
    catch
        error:badarg -> {error, badarg};
        Class:Reason:Stack ->
            unlink(Pid),
            exit(Pid, kill),
            erlang:raise(Class, Reason, Stack)
    end.

refusal(enomem) -> no_memory;
refusal(Reason) -> Reason.

%% A made domain's system side, opened with the library's values of it and the domain's
%% node, its port handed to the domain pid, which writes the domain's control records
%% through it, then the domain pid's export to it, then its first thread; a domain with no
%% system connection has no side. The domain gets send on its pid, its one way to report
%% ready and answer; its creator, a process of the system domain, which holds every
%% right on the system domain's own pids, needs no export.
started(Id, Pid, Ref, Values, #{lib := Lib, agent := Agent, exports := Exports}) ->
    first_refusal([{system_side, fun() -> open_side(Agent, Id, Pid, Ref, Values) end},
                   {export, fun() -> export(Exports, Pid, Id, Values) end},
                   {start, fun() -> Lib:start(Id) end}]).

%% Runs each step in turn: ok, or {error, {Step, Reason}} for the first that refuses.
first_refusal([]) ->
    ok;
first_refusal([{Step, Run} | Rest]) ->
    case Run() of
        ok -> first_refusal(Rest);
        {error, Reason} -> {error, {Step, Reason}}
    end.

%% A domain with no system connection has no way to message its pid, so needs no export.
export(_Exports, _Pid, _Id, #{connection := 0}) -> ok;
export(Exports, Pid, Id, _Values) -> Exports:export(Pid, [send], Id).

boot_timer(_Id, infinity) -> ok;
boot_timer(Id, Timeout) -> _ = erlang:start_timer(Timeout, self(), {boot_timeout, Id}), ok.

%% Domain Id's ready report, which its domain pid passed on with Ref: the domain is ready
%% and its create, if any, answered. A domain that ended while running, its end having
%% overtaken a report its pid passed on before the pid's own end, reported too, and its
%% create answers ok. A report for a domain that is ready already, or that ended stopping
%% for its boot timeout, changes nothing.
ready(Id, Ref, #{core := Core, waiting := Waiting} = State) ->
    case {erx_domain_core:fetch(Id, Core), Waiting} of
        {{ok, #{ref := Ref, state := running}}, _} ->
            answer_ready(Id, State#{core := erx_domain_core:ready(Id, Core)});
        {_, #{Id := #{ref := Ref, ended := {running, _Info}}}} ->
            answer_ready(Id, State);
        _ ->
            State
    end.

answer_ready(Id, #{waiting := Waiting} = State) ->
    case maps:take(Id, Waiting) of
        {#{from := From, domain := Domain}, Rest} ->
            gen_server:reply(From, {ok, Domain}),
            State#{waiting := Rest};
        error ->
            State
    end.

%% A create whose domain ended before its report reached the service waits for the
%% domain pid's end as well: the service tells the pid of the end only once the domain's
%% system side is closed, and the pid passes on every report the side delivered before it
%% ends (erx_domain_pid's finish), so no report is still to come once both have ended.
waiter_ended(Id, Life, Info, #{waiting := Waiting} = State) ->
    case Waiting of
        #{Id := Waiter} -> settle(Id, State#{waiting := Waiting#{Id := Waiter#{ended := {Life, Info}}}});
        #{} -> State
    end.

pid_ended(Pid, #{waiting := Waiting} = State) ->
    case [{Id, Waiter} || Id := #{pid := P} = Waiter <- Waiting, P =:= Pid] of
        [{Id, Waiter}] -> settle(Id, State#{waiting := Waiting#{Id := Waiter#{pid := gone}}});
        [] -> State
    end.

%% Answers the create of domain Id, which ended in life Life before it reported ready,
%% once nothing of the domain remains (A4) and its domain pid has ended.
settle(Id, #{waiting := Waiting} = State) ->
    case Waiting of
        #{Id := #{from := From, pid := gone, ended := {Life, Info}}} ->
            gen_server:reply(From, {error, unreported(Life, Info)}),
            State#{waiting := maps:remove(Id, Waiting)};
        #{} ->
            State
    end.

%% Stopping for its boot timeout, the domain timed out; otherwise it ended by itself.
unreported(stopping, _Info) -> timeout;
unreported(_Life, Info) -> {boot, Info}.

open_side(_Agent, _Id, _Pid, _Ref, #{connection := 0}) ->
    ok;
open_side(Agent, Id, Pid, Ref, Values) ->
    case Agent:open_side(Id, Values) of
        {ok, Port} ->
            Pid ! {Ref, port, Port},
            ok;
        {error, _} = Refused ->
            Refused
    end.

%% A connection-control record about connection Peer, which domain Id's domain pid writes
%% at once into the slot the core gives it (docs/design-domains.md, "The control table").
record(Id, Peer, Record, #{core := Core} = State) ->
    case erx_domain_core:record_slot(Id, Peer, expects(Record), Core) of
        {ok, Slot, Next} ->
            {ok, #{pid := Pid, ref := Ref}} = erx_domain_core:fetch(Id, Next),
            Pid ! {Ref, record, Slot, Record},
            {{ok, Slot}, State#{core := Next}};
        {error, _} = Refused ->
            {Refused, State}
    end.

%% The answer a record waits for, which alone frees its slot.
expects({erx_connection_up, _Peer, _Values}) -> mapped;
expects({erx_connection_down, _Peer, _Reason}) -> unmapped.

%% An answer domain Id's pid passed on with Ref, which frees the connection's slot when it
%% is the answer the slot's record waits for; any other changes nothing.
answer(Id, Ref, Answer, #{core := Core} = State) ->
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{ref := Ref}} ->
            case erx_domain_core:answered(Id, answer_peer(Answer), answer_kind(Answer), Core) of
                {ok, Next} -> State#{core := Next};
                none -> State
            end;
        _ ->
            State
    end.

%% The pid passes on only answers (erx_domain_pid:is_answer/1); any other shape, which
%% would come from a domain, answers no record.
answer_kind({erx_connection_mapped, _Peer}) -> mapped;
answer_kind({erx_connection_unmapped, _Peer}) -> unmapped;
answer_kind({erx_connection_lost, _Peer, _Reason}) -> lost;
answer_kind(_Answer) -> other.

answer_peer(Answer) when tuple_size(Answer) >= 2 -> element(2, Answer);
answer_peer(_Answer) -> none.

stop(Id, #{lib := Lib}) ->
    case Lib:stop(Id, 0) of
        ok -> ok;
        {error, Reason} -> logger:error("erx_domain: the library refused to stop domain ~b: ~0p", [Id, Reason])
    end.

%% A domain's end: its system side's port ends before its connection's objects are
%% destroyed and before its domain pid ends, so no driver callback touches them once they
%% are gone (the unmap itself may still trail the port's end: TODO.md).
ended(Id, End, #{lib := Lib, core := Core} = State) ->
    case erx_domain_core:ended(Id, End, slogan(Lib, Id, End), erlang:system_time(second), Core) of
        none ->
            State;
        {Info, #{pid := Pid, ref := Ref, connection := Connection, origin := Origin, state := Life}, Ended} ->
            close_side(Id, Connection, {domain_down, Id, Info}, State),
            disconnect(Lib, Connection),
            Pid ! {Ref, domain_down, Info},
            Retired = case Lib:retire(Id) of
                          ok -> erx_domain_core:retired(Id, Ended);
                          {error, _} -> Ended
                      end,
            restart(Origin, waiter_ended(Id, Life, Info, State#{core := Retired}))
    end.

%% A crash's slogan, from its crash area, which goes at the retire after it.
slogan(Lib, Id, {crash, _}) ->
    case Lib:crash(Id) of
        {ok, Slogan, _Dump, _Truncated} -> Slogan;
        {error, Reason} -> {unreadable, Reason}
    end;
slogan(_Lib, _Id, _End) ->
    none.

%% A domain with no system connection has no side, and a runtime that was no node at the
%% service's start, where no agent runs, opened none. In a node, the agent ends only as the
%% runtime ends: it halts it, or follows net_kernel's shutdown in an ordered end or once
%% kernel_sup gives up (erx_connections:kernel_ended/1), so noproc there finds that end
%% under way; the service ends rather than destroy objects a live port may map.
close_side(_Id, 0, _Reason, _State) ->
    ok;
close_side(Id, _Connection, Reason, #{agent := Agent, node := Node}) ->
    case {Agent:close_side(Id, Reason), Node} of
        {ok, _} -> ok;
        {{error, noproc}, false} -> ok;
        {{error, noproc}, true} -> error({connection_agent, noproc})
    end.

disconnect(_Lib, 0) -> ok;
disconnect(Lib, Connection) -> Lib:disconnect(Connection).

restart(request, State) ->
    State;
restart({configured, Row}, #{core := Core, configured := Configured} = State) ->
    #{Row := #{restarts := Restarts, restart_period_s := Period} = Entry} = Configured,
    case erx_domain_core:restart(Row, Restarts, Period, erlang:monotonic_time(second), Core) of
        {yes, Next} -> start_configured(Entry, State#{core := Next});
        {no, Next} -> State#{core := Next}
    end.
