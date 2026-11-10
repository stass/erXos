%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_pid).
-moduledoc """
A domain pid (docs/design-domains.md, "Domains"): an ordinary process of the
system domain that stands for one domain. It traps exits. An exit signal
with any reason but normal, from anyone but the domain service, asks the
service to stop the domain; normal is ignored, as a process that does not
trap exits ignores it. The pid ends with {domain_down, Id, Info} when the
service tells it the domain ended, so its links and monitors see the
domain's end; a kill ends it at once, and the service, which links to it,
then stops the domain. The service's own end ends the pid with the
service's reason, once the service is dead, since a trapped exit can be
forged as a plain message: that end ends the system domain and every domain with it
(erx_domain_sup), so there is no domain left to stop.

Ref is the secret the service made with the pid: only messages tagged with
it come from the service, and the pid drops every other message.
""".

-export([start_link/3]).

-spec start_link(pid(), pos_integer(), reference()) -> pid().
start_link(Service, Id, Ref) ->
    %% Not proc_lib: a domain pid ends with {domain_down, Id, Info} at every
    %% end of its domain, which is no crash to report.
    spawn_link(fun() -> init(Service, Id, Ref) end).

init(Service, Id, Ref) ->
    process_flag(trap_exit, true),
    loop(Service, Id, Ref).

loop(Service, Id, Ref) ->
    receive
        {Ref, domain_down, Info} ->
            exit({domain_down, Id, Info});
        {'EXIT', Service, Reason} ->
            %% A trapped exit is a message, which any process here can forge;
            %% only a service that has ended sent a real one.
            case is_process_alive(Service) of
                false -> exit(Reason);
                true -> loop(Service, Id, Ref)
            end;
        {'EXIT', _From, normal} ->
            loop(Service, Id, Ref);
        {'EXIT', _From, _Reason} ->
            Service ! {stop_request, Ref, Id},
            loop(Service, Id, Ref);
        _Other ->
            loop(Service, Id, Ref)
    end.
