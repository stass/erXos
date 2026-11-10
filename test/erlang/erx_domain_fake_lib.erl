%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A stand-in for erx_domain_lib and for the connection agent, erx_connections,
%% in erx_domain_tests: it logs every call to the queue start_log/0 starts,
%% which next_call/0 takes from in order, and a stop sends the service the end
%% the library's fault thread would. The agent refuses the side of a domain
%% named noside, as the lane driver refuses an open it cannot map. It also
%% stands in for the export table (erx_dist:export/3). A started domain's init
%% reports ready to its domain pid at once, in its envelope from the domain,
%% naming an agent of the domain's node, unless the domain is named silent,
%% whose init never reports, or overtaken, which ends at its start and whose
%% report its side hands the domain pid only at close_side, as the lane
%% driver's finish reads the lane to its end, or behind, which ends at its start
%% and whose report reaches the domain pid behind the service's domain_down, the
%% pid suspended from close_side until retire, which the service calls after it
%% sends domain_down, has sent the report. The service makes every call here in its own
%% process, so the process dictionary keeps each domain's pid and node.
-module(erx_domain_fake_lib).
-export([start_log/0, next_call/0]).
-export([register/0, configured/0, configured/3, create/1, start/1, stop/2, retire/1, crash/1,
         disconnect/1]).
-export([open_side/2, close_side/2, export/3]).
-export([agent/2]).

start_log() ->
    Pid = spawn(fun() -> queue([], []) end),
    register(erx_domain_fake_log, Pid),
    Pid.

next_call() ->
    erx_domain_fake_log ! {next, self()},
    receive {call, Call} -> Call after 5000 -> timeout end.

queue(Calls, Waiting) ->
    case {Calls, Waiting} of
        {[Call | Rest], [Pid | More]} -> Pid ! {call, Call}, queue(Rest, More);
        _ -> receive {lib, Call} -> queue(Calls ++ [Call], Waiting); {next, Pid} -> queue(Calls, Waiting ++ [Pid]) end
    end.

log(Call) -> erx_domain_fake_log ! {lib, Call}, ok.

register() -> ok.
configured() ->
    {ok, #{host => <<"erxos">>,
           domains => [#{row => 0, place => 1, name => <<"b">>, principal => 1, kind => service,
                         restarts => 1, restart_period_s => 60},
                       #{row => 1, place => 0, name => <<"a">>, principal => 1, kind => service,
                         restarts => 0, restart_period_s => 60}]}}.
configured(Id, Row, DomainPid) when is_pid(DomainPid) ->
    {ok, #{domains := Rows}} = configured(),
    [Name] = [Name || #{row := R, name := Name} <- Rows, R =:= Row],
    put({domain, Id}, {DomainPid, Name}),
    log({configured, Id, Row}), {ok, #{id => Id, connection => Id * 10, ctl_slots => 4}}.
create(#{memory := 1, domain_pid := DomainPid}) -> log({refused, DomainPid}), {error, enomem};
create(#{id := Id, name := Name, domain_pid := DomainPid} = Spec) ->
    put({domain, Id}, {DomainPid, Name}),
    log({create, Spec}), {ok, #{id => Id, connection => Id * 10, ctl_slots => 4}}.
start(Id) ->
    case get({domain, Id}) of
        {_, <<"silent">>} -> ok;
        {_, Ends} when Ends =:= <<"overtaken">>; Ends =:= <<"behind">> ->
            erx_domain_srv ! {domain_ended, Id, {halt, 0}, #{}};
        {DomainPid, Name} -> DomainPid ! {erx_origin, Id, {erx_ready, #{connections => agent(Name, Id)}}}
    end,
    log({start, Id}).
stop(Id, _Status) -> log({stop, Id}), erx_domain_srv ! {domain_ended, Id, {stopped, 0}, #{}}, ok.
retire(Id) ->
    case get({domain, Id}) of
        {DomainPid, <<"behind">> = Name} ->
            DomainPid ! report(Name, Id),
            true = erlang:resume_process(DomainPid);
        _ ->
            ok
    end,
    log({retire, Id}).
crash(Id) -> log({crash, Id}), {ok, <<"boom">>, <<"=erl_crash_dump">>, false}.
disconnect(Number) -> log({disconnect, Number}).

open_side(Id, #{node := Node, connection := Connection}) ->
    log({open_side, Id, Node, Connection}),
    case Node of
        'noside@erxos' -> {error, enomem};
        _ -> {ok, list_to_port("#Port<0.1>")}
    end.
close_side(Id, Reason) ->
    case get({domain, Id}) of
        {DomainPid, <<"overtaken">> = Name} ->
            DomainPid ! report(Name, Id);
        {DomainPid, <<"behind">>} ->
            true = erlang:suspend_process(DomainPid);
        _ ->
            ok
    end,
    log({close_side, Id, Reason}).
export(Pid, Rights, Peer) when is_pid(Pid) -> log({export, Peer, Rights}).

%% Init's ready report from domain Id, in its envelope.
report(Name, Id) -> {erx_origin, Id, {erx_ready, #{connections => agent(Name, Id)}}}.

%% A pid of domain Id's node, Name@erxos, as a frame from the domain carries one:
%% NEW_PID_EXT, its node a SMALL_ATOM_UTF8_EXT, its creation the domain's id.
agent(Name, Id) ->
    Node = <<Name/binary, "@erxos">>,
    binary_to_term(<<131, 88, 119, (byte_size(Node)), Node/binary, 1:32, 0:32, Id:32>>).
