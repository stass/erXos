%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A stand-in for erx_domain_lib and for the connection agent, erx_connections,
%% in erx_domain_tests: it logs every call to the queue start_log/0 starts,
%% which next_call/0 takes from in order, and a stop sends the service the end
%% the library's fault thread would. The agent refuses the side of a domain
%% named noside or nostop, as the lane driver refuses an open it cannot map;
%% noside's end comes only when the test sends it, and nostop's stop is
%% refused, so it never ends. It also
%% stands in for the export table (erx_dist:export/3). A started domain's init
%% reports ready to its domain pid at once, in its envelope from the domain,
%% naming an agent of the domain's node, unless the domain is named silent,
%% whose init never reports, or overtaken, which ends at its start and whose
%% report its side hands the domain pid only at close_side, as the lane
%% driver's finish reads the lane to its end, or behind, which ends at its start
%% and whose report reaches the domain pid behind the service's domain_down, the
%% pid suspended from close_side until retire, which the service calls after it
%% sends domain_down, has sent the report. Principal 1 has a session template, which
%% the boot never starts. A domain named lost has a side that has
%% ended by the time open_side answers, so its pid has no port to write a record
%% into. As the library does, retire refuses with ebusy while a connection of the
%% domain stands, connect refuses with einval a domain named ending, as the library
%% does a domain whose end the service has not heard of yet, and each domain reads
%% rings of a size of its own. The service makes every call here in its own process,
%% so the process dictionary keeps each domain's pid and node and each connection.
-module(erx_domain_fake_lib).
-export([start_log/0, next_call/0]).
-export([register/0, configured/0, configured/3, templates/0, create/1, start/1, stop/2, retire/1, crash/1,
         connect/4, disconnect/1]).
-export([open_side/2, close_side/2, export/3]).
-export([agent/2, reader/1]).

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
templates() -> {ok, [#{template => 0, principal => 1}]}.
configured(Id, Row, DomainPid) when is_pid(DomainPid) ->
    {ok, #{domains := Rows}} = configured(),
    [Name] = [Name || #{row := R, name := Name} <- Rows, R =:= Row],
    put({domain, Id}, {DomainPid, Name}),
    log({configured, Id, Row}), {ok, created(Id, 4)}.
create(#{memory := 1, domain_pid := DomainPid}) -> log({refused, DomainPid}), {error, enomem};
create(#{id := Id, name := Name, domain_pid := DomainPid} = Spec) ->
    put({domain, Id}, {DomainPid, Name}),
    log({create, Spec}), {ok, created(Id, maps:get(connections, Spec, 4))}.
start(Id) ->
    case get({domain, Id}) of
        {_, <<"silent">>} -> ok;
        {_, Ends} when Ends =:= <<"overtaken">>; Ends =:= <<"behind">> ->
            erx_domain_srv ! {domain_ended, Id, {halt, 0}, #{}};
        {DomainPid, Name} -> DomainPid ! {erx_origin, Id, {erx_ready, #{connections => agent(Name, Id)}}}
    end,
    log({start, Id}).
stop(Id, _Status) ->
    log({stop, Id}),
    End = {domain_ended, Id, {stopped, 0}, #{}},
    case get({domain, Id}) of
        {_, <<"noside">>} -> ok;
        {_, <<"nostop">>} -> {error, einval};
        _ -> erx_domain_srv ! End, ok
    end.
retire(Id) ->
    case [Number || {{connection, Number}, {A, B}} <- get(), A =:= Id orelse B =:= Id] of
        [] ->
            case get({domain, Id}) of
                {DomainPid, <<"behind">> = Name} ->
                    DomainPid ! report(Name, Id),
                    true = erlang:resume_process(DomainPid);
                _ ->
                    ok
            end,
            log({retire, Id});
        [_ | _] ->
            log({retire, Id, ebusy}),
            {error, ebusy}
    end.
crash(Id) -> log({crash, Id}), {ok, <<"boom">>, <<"=erl_crash_dump">>, false}.
disconnect(Number) -> erase({connection, Number}), log({disconnect, Number}).
%% Each party's values as the library's connect returns them, in its own table.
connect(A, B, AReads, BReads) ->
    log({connect, A, B, AReads, BReads}),
    case [Id || Id <- [A, B], element(2, get({domain, Id})) =:= <<"ending">>] of
        [] ->
            Number = A * 100 + B,
            put({connection, Number}, {A, B}),
            {ok, #{number => Number, a => #{side => 1, peer_side => 2, peer_bell => 3, label => 7},
                   b => #{side => 4, peer_side => 5, peer_bell => 6, label => 8}}};
        [_ | _] ->
            {error, einval}
    end.

%% A created domain whose control table has Slots slots, one per connection, and whose
%% rings it reads have reader(Id) bytes of data.
created(Id, Slots) -> #{id => Id, connection => Id * 10, ctl_slots => Slots, reader => reader(Id)}.

%% The data size of the rings domain Id reads, each domain's its own.
reader(Id) -> 1024 * Id.

open_side(Id, #{node := Node, connection := Connection}) ->
    log({open_side, Id, Node, Connection}),
    case Node of
        Refused when Refused =:= 'noside@erxos'; Refused =:= 'nostop@erxos' ->
            {error, enomem};
        'lost@erxos' ->
            Port = open_port({spawn_driver, "udp_inet"}, [binary]),
            true = port_close(Port),
            {ok, Port};
        _ ->
            {ok, open_port({spawn_driver, "udp_inet"}, [binary])}
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
