%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The connection agent, erx_dist's acceptor (docs/design-runtime.md, "Connections in
%% ERTS"). It opens the domain's system connection from the boot page, on the lane driver,
%% and hands it to net_kernel as an accepted connection; erx_dist's owner then brings the
%% system domain's entry up. In the system domain, which has no system connection, it
%% opens nothing.
-module(erx_connections).
-moduledoc false.

-export([start/2]).

%% The acceptor, linked to net_kernel as OTP's carriers start theirs.
-spec start(pid(), {pos_integer(), node(), pid()} | none) -> pid().
start(Kernel, System) ->
    spawn_opt(fun() -> init(Kernel, System) end, [link, {priority, max}]).

init(_Kernel, none) ->
    loop();
init(Kernel, {PeerId, PeerNode, _DomainPid}) ->
    %% Any peer handed this pid can reach it; what arrives from another domain comes as
    %% {erx_origin, D, Msg} (edit 16), and loop/0 acts on no message, so no peer steers it.
    try
        Port = open_port({spawn_driver, "erx_lane system"}, [binary]),
        hand_over(Kernel, #{port => Port, node => PeerNode, id => PeerId, system => true})
    catch
        Class:Reason -> erx_dist:system_lost({Class, Reason})
    end,
    loop().

%% net_kernel's accept protocol, as inet_tcp_dist's acceptor follows it: net_kernel names
%% the connection's owner, which then owns the port and is told so.
hand_over(Kernel, #{port := Port} = Connection) ->
    Kernel ! {accept, self(), Connection, erx, erx},
    receive
        {Kernel, controller, Owner} ->
            true = erlang:port_connect(Port, Owner),
            unlink(Port),
            Owner ! {self(), controller};
        {Kernel, unsupported_protocol} ->
            erx_dist:system_lost(unsupported_protocol)
    end.

%% Nothing else is acted on yet; what arrives is dropped, so its queue stays empty.
loop() ->
    receive _ -> loop() end.
