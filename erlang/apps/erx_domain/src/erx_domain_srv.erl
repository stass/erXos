%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_srv).
-moduledoc """
The domain service (docs/design-system.md, "Creating a domain", "Ending a
domain", "System services"): the domain library's one registrant, which
creates the manifest's configured domains in boot order at its first start
and every requested domain after, keeps a domain pid for each, has the
system domain's connection agent (erx_connections) open the system side of
each domain's system connection before its first thread runs, and on each
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
%% The keys of a request beyond its name: erx_domain_lib:spec()'s, less id, principal and
%% domain_pid, which the service sets.
-define(REQUEST_KEYS, [runtime, release, release_files, memory, outer, grant, lane, args, env,
                       connections, flags, spaces, limits]).

start_link() ->
    start_link(#{}).

-doc """
Opts may name lib, the domain library's module (erx_domain_lib), and agent, the
connection agent's (erx_connections), for a host test's stand-ins.
""".
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

init(Opts) ->
    process_flag(trap_exit, true),
    Lib = library(maps:get(lib, Opts, erx_domain_lib)),
    Agent = maps:get(agent, Opts, erx_connections),
    %% Whether the runtime is a node, as kernel's start left it, since net_kernel starts
    %% before any application; its end later leaves the sides it served open (close_side/4).
    {ok, #{lib => Lib, agent => Agent, node => erlang:is_alive(), core => undefined, configured => #{}},
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

handle_call({create, Spec}, _From, State) ->
    {Reply, Next} = create(Spec, State),
    {reply, Reply, Next};
handle_call(_Request, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({domain_ended, Id, End, _Record}, State) ->
    {noreply, ended(Id, End, State)};
handle_info({stop_request, Ref, Id}, #{core := Core} = State) ->
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{ref := Ref, state := Life}} when Life =:= built; Life =:= running -> stop(Id, State);
        _ -> ok
    end,
    {noreply, State};
handle_info({'EXIT', Pid, _Reason}, #{core := Core} = State) when Core =/= undefined ->
    %% A domain pid that died first, by a kill or a fault of its own, stops its domain.
    case erx_domain_core:find_pid(Pid, Core) of
        {ok, #{id := Id, state := Life}} when Life =:= built; Life =:= running -> stop(Id, State);
        _ -> ok
    end,
    {noreply, State};
handle_info(_Message, State) ->
    {noreply, State}.

%% A request: its name and fields checked, then built as a configured row is.
create(_Spec, #{lib := none} = State) ->
    {{error, enotsup}, State};
create(#{name := Name} = Spec, State) ->
    Fields = maps:remove(name, Spec),
    case [Key || Key <- maps:keys(Fields), not lists:member(Key, ?REQUEST_KEYS)] of
        [Key | _] ->
            {{error, {bad_spec, Key}}, State};
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
                    build(Ident, ?SYSTEM_PRINCIPAL, request, Make, State)
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
            case build(Ident, Principal, {configured, Row}, Make, State) of
                {{ok, _}, Next} ->
                    Next;
                {{error, Reason}, Next} ->
                    logger:error("erx_domain: configured domain ~ts did not start: ~0p", [Name, Reason]),
                    Next
            end
    end.

%% Admits Ident, makes its domain pid, which its boot page names, has the library
%% make it with Make(Id, Pid) and starts its first thread once the system side of its
%% system connection is open. A refused plan ends the pid, unlinked first, so no
%% domain is stopped for it; a domain the library made whose side or start is refused
%% is stopped, and its end retires it as any end does.
build(Ident, Principal, Origin, Make, #{core := Core} = State) ->
    case erx_domain_core:admit(Ident, Principal, Origin, Core) of
        {error, _} = Error ->
            {Error, State};
        {ok, #{id := Id, node := Node}, Admitted} ->
            Ref = make_ref(),
            Pid = erx_domain_pid:start_link(self(), Id, Ref),
            case made(Make, Id, Pid) of
                {ok, #{connection := Connection} = Created} ->
                    Built = erx_domain_core:built(Id, Connection, Pid, Ref, Admitted),
                    Next = State#{core := Built},
                    case started(Id, Created#{node => Node}, Next) of
                        ok ->
                            {{ok, {erx_domain, Id, Node, Pid}}, State#{core := erx_domain_core:running(Id, Built)}};
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
%% node, then its first thread; a domain with no system connection has no side.
started(Id, Values, #{lib := Lib, agent := Agent}) ->
    case open_side(Agent, Id, Values) of
        ok ->
            case Lib:start(Id) of
                ok -> ok;
                {error, Reason} -> {error, {start, Reason}}
            end;
        {error, Reason} ->
            {error, {system_side, Reason}}
    end.

open_side(_Agent, _Id, #{connection := 0}) ->
    ok;
open_side(Agent, Id, Values) ->
    case Agent:open_side(Id, Values) of
        {ok, _Port} -> ok;
        {error, _} = Refused -> Refused
    end.

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
        {Info, #{pid := Pid, ref := Ref, connection := Connection, origin := Origin}, Ended} ->
            close_side(Id, Connection, {domain_down, Id, Info}, State),
            disconnect(Lib, Connection),
            Pid ! {Ref, domain_down, Info},
            Retired = case Lib:retire(Id) of
                          ok -> erx_domain_core:retired(Id, Ended);
                          {error, _} -> Ended
                      end,
            restart(Origin, State#{core := Retired})
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
%% service's start, where no agent runs, opened none. In a node, the agent's end leaves its
%% ports to their owners, so the service ends, and the system domain with it, rather than
%% destroy objects a live port may map.
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
