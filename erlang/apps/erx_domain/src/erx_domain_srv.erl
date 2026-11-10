%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_srv).
-moduledoc """
The domain service (docs/design-system.md, "Creating a domain", "Ending a
domain", "System services"): the domain library's one registrant, which
creates the manifest's configured domains in boot order at its first start
and every requested domain after, keeps a domain pid for each, and on each
{domain_ended, Id, End, Record} disconnects the domain's system connection,
ends its domain pid with {domain_down, Id, Info}, retires it and restarts a
configured domain within its restart intensity.

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
%% The keys of a request beyond its name: erx_domain_lib:spec()'s, less id and principal.
-define(REQUEST_KEYS, [runtime, release, release_files, memory, outer, grant, lane, args, env,
                       connections, flags, spaces, limits]).

start_link() ->
    start_link(#{}).

-doc "Opts may name lib, the domain library's module (erx_domain_lib), for a host test's stand-in.".
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

init(Opts) ->
    process_flag(trap_exit, true),
    Lib = library(maps:get(lib, Opts, erx_domain_lib)),
    {ok, #{lib => Lib, core => undefined, configured => #{}}, {continue, boot}}.

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
                    Make = fun(Id) ->
                                   Lib:create(Fields#{id => Id, name => Name, principal => ?SYSTEM_PRINCIPAL})
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
            Make = fun(Id) -> Lib:configured(Id, Row) end,
            case build(Ident, Principal, {configured, Row}, Make, State) of
                {{ok, _}, Next} ->
                    Next;
                {{error, Reason}, Next} ->
                    logger:error("erx_domain: configured domain ~ts did not start: ~0p", [Name, Reason]),
                    Next
            end
    end.

%% Admits Ident, has the library make it with Make(Id), makes its domain pid and
%% starts its first thread. A domain the library made whose start is refused is
%% stopped, and its end retires it as any end does.
build(Ident, Principal, Origin, Make, #{lib := Lib, core := Core} = State) ->
    case erx_domain_core:admit(Ident, Principal, Origin, Core) of
        {error, _} = Error ->
            {Error, State};
        {ok, #{id := Id, node := Node}, Admitted} ->
            case made(Make, Id) of
                {ok, #{connection := Connection}} ->
                    Ref = make_ref(),
                    Pid = erx_domain_pid:start_link(self(), Id, Ref),
                    Built = erx_domain_core:built(Id, Connection, Pid, Ref, Admitted),
                    case Lib:start(Id) of
                        ok ->
                            {{ok, {erx_domain, Id, Node, Pid}}, State#{core := erx_domain_core:running(Id, Built)}};
                        {error, Reason} ->
                            Next = State#{core := Built},
                            stop(Id, Next),
                            {{error, {start, Reason}}, Next}
                    end;
                {error, Reason} ->
                    {{error, refusal(Reason)}, State#{core := erx_domain_core:failed(Id, Admitted)}}
            end
    end.

made(Make, Id) ->
    try Make(Id)
    catch error:badarg -> {error, badarg}
    end.

refusal(enomem) -> no_memory;
refusal(Reason) -> Reason.

stop(Id, #{lib := Lib}) ->
    case Lib:stop(Id, 0) of
        ok -> ok;
        {error, Reason} -> logger:error("erx_domain: the library refused to stop domain ~b: ~0p", [Id, Reason])
    end.

ended(Id, End, #{lib := Lib, core := Core} = State) ->
    case erx_domain_core:ended(Id, End, slogan(Lib, Id, End), erlang:system_time(second), Core) of
        none ->
            State;
        {Info, #{pid := Pid, ref := Ref, connection := Connection, origin := Origin}, Ended} ->
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
