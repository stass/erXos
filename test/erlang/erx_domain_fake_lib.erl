%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A stand-in for erx_domain_lib in erx_domain_tests: it logs every call to
%% the queue start_log/0 starts, which next_call/0 takes from in order, and a
%% stop sends the service the end the library's fault thread would.
-module(erx_domain_fake_lib).
-export([start_log/0, next_call/0]).
-export([register/0, configured/0, configured/2, create/1, start/1, stop/2, retire/1, disconnect/1]).

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
configured(Id, Row) -> log({configured, Id, Row}), {ok, #{id => Id, connection => Id * 10}}.
create(#{memory := 1}) -> {error, enomem};
create(#{id := Id} = Spec) -> log({create, Spec}), {ok, #{id => Id, connection => Id * 10}}.
start(Id) -> log({start, Id}).
stop(Id, _Status) -> log({stop, Id}), erx_domain_srv ! {domain_ended, Id, {stopped, 0}, #{}}, ok.
retire(Id) -> log({retire, Id}).
disconnect(Number) -> log({disconnect, Number}).
