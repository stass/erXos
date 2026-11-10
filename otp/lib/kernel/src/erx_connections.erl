%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The connection agent, erx_dist's acceptor (docs/design-runtime.md, "Connections in
%% ERTS"), registered in its domain under its module's name. In a domain, it opens the
%% domain's system connection from the boot page, on the lane driver, and hands it to
%% net_kernel as an accepted connection; erx_dist's owner then brings the system domain's
%% entry up. The system domain has no system connection, so its agent opens nothing at
%% start: it opens the system domain's side of each domain's system connection when the
%% domain service asks, closes it at the domain's end, and tells the service when a side
%% ends by itself. The agent and net_kernel live as long as the runtime: the agent halts
%% it on net_kernel's end other than an ordered stop, and erx_dist:accept/1 on the agent's.
-module(erx_connections).
-moduledoc false.

-export([start/2, open_side/2, close_side/2]).

%% The lane driver's port_control command that finishes the port (erx_lane_drv.c).
-define(CONTROL_FINISH, 2).

%% What erx_domain_lib:create/1 returned for a domain's system connection, with the
%% domain's node: the slots of the two sides and of the domain's bell, the connection's
%% number, which labels the system domain's bell, and the two lanes' data areas.
-type side_values() :: #{node := node(), connection := pos_integer(), side := non_neg_integer(),
                         peer_side := non_neg_integer(), bell := non_neg_integer(),
                         reader := pos_integer(), system_lane := pos_integer(),
                         atom() => term()}.

%% The acceptor, linked to net_kernel as OTP's carriers start theirs.
-spec start(pid(), {pos_integer(), node(), pid()} | none) -> pid().
start(Kernel, System) ->
    spawn_opt(fun() -> init(Kernel, System) end, [link, {priority, max}]).

%% In the system domain: opens the system side of domain Id's system connection and hands
%% it to net_kernel as an accepted connection to the domain's node, before the domain's
%% first thread runs. The caller is sent {system_side_ended, Id} if the side ends before
%% close_side/2 closes it. {error, noproc} where no agent runs, the runtime being no node;
%% the lane driver's or net_kernel's refusal otherwise, and badarg for a domain whose side
%% is open already.
-spec open_side(pos_integer(), side_values()) -> {ok, port()} | {error, term()}.
open_side(Id, Values) ->
    call({open_side, Id, Values}).

%% In the system domain: finishes the system side of domain Id's system connection, so
%% every whole frame the domain published is delivered, then ends it with Reason, which takes
%% the domain's entry down, and answers once the port has ended, so the connection's objects
%% may be destroyed then. ok for a domain whose side is not open. Reason is not normal,
%% which would end nothing.
-spec close_side(pos_integer(), term()) -> ok | {error, noproc}.
close_side(Id, Reason) when Reason =/= normal ->
    call({close_side, Id, Reason}).

call(Request) ->
    try gen:call(?MODULE, '$gen_call', Request, infinity) of
        {ok, Reply} -> Reply
    catch
        exit:noproc -> {error, noproc}
    end.

init(Kernel, System) ->
    process_flag(trap_exit, true),
    true = register(?MODULE, self()),
    serve(Kernel, System).

%% Any process handed this pid can reach it; what arrives from another domain comes as
%% {erx_origin, D, Msg} (edit 16), which neither loop acts on, so no peer steers it. Both
%% loops act on net_kernel's end, which the agent's link brings as 'EXIT' (kernel_ended/1).
serve(Kernel, none) ->
    sides(Kernel, #{});
serve(Kernel, {PeerId, PeerNode, _DomainPid}) ->
    try
        Port = open_port({spawn_driver, "erx_lane system"}, [binary]),
        case hand_over(Kernel, #{port => Port, node => PeerNode, id => PeerId, system => true}) of
            ok -> ok;
            {error, Refusal} -> erx_dist:unavailable(system_connection, Refusal)
        end
    catch
        %% net_kernel's shutdown during the hand-over (kernel_ended/1) ends the agent
        %% quietly, as it does after the hand-over.
        exit:shutdown -> exit(shutdown);
        Class:Reason -> erx_dist:unavailable(system_connection, {Class, Reason})
    end,
    drop(Kernel).

%% The system domain's agent: the domain service's two calls, with each open side by domain
%% id as {Port, Monitor, Service}: its port, the monitor on it and the process that opened
%% it, the domain service.
%% A side's port ends with its owner (erx_dist), each linked to the other, so its monitor
%% fires on every end of either: the agent then tells the service, which stops the domain
%% (docs/design-system.md, "A lost system connection ends the domain"). A side the
%% service closes is no longer monitored, so its ordered end tells no one.
sides(Kernel, Sides) ->
    receive
        {'$gen_call', {Service, _} = From, {open_side, Id, Values}} when not is_map_key(Id, Sides) ->
            Opened = open(Kernel, Id, Values),
            Next = case Opened of
                       {ok, Port} ->
                           Monitor = erlang:monitor(port, Port, [{tag, {side_ended, Id}}]),
                           Sides#{Id => {Port, Monitor, Service}};
                       {error, _} ->
                           Sides
                   end,
            gen:reply(From, Opened),
            sides(Kernel, Next);
        {'$gen_call', From, {close_side, Id, Reason}} ->
            case maps:take(Id, Sides) of
                {{Port, Monitor, _Service}, Rest} ->
                    erlang:demonitor(Monitor, [flush]),
                    finish(Port, Reason),
                    gen:reply(From, ok),
                    sides(Kernel, Rest);
                error ->
                    gen:reply(From, ok),
                    sides(Kernel, Sides)
            end;
        {'$gen_call', From, _Request} ->
            gen:reply(From, {error, badarg}),
            sides(Kernel, Sides);
        {{side_ended, Id}, Monitor, port, Port, _Reason} ->
            case maps:take(Id, Sides) of
                {{Port, Monitor, Service}, Rest} ->
                    Service ! {system_side_ended, Id},
                    sides(Kernel, Rest);
                _ ->
                    sides(Kernel, Sides)
            end;
        {'EXIT', Kernel, Reason} ->
            kernel_ended(Reason);
        _ ->
            sides(Kernel, Sides)
    end.

%% The port's open command names the system domain's own side first, the one it writes,
%% then the domain's, the domain's bell, the label, the data areas of the lanes it writes
%% and reads, and the peer, the domain, by id and node (erx_lane_drv.c, lane_open_parse).
%% The library names the sides and the bell from the domain's view: side and bell are the
%% domain's, peer_side the system domain's; reader is the lane the system domain writes,
%% system_lane the one it reads. A port that net_kernel did not take is ended before the
%% answer, so no refused open leaves a port mapping the connection's objects.
open(Kernel, Id, #{node := Node, connection := Label, side := DomainSide, peer_side := OwnSide,
                   bell := Bell, reader := Reader, system_lane := SystemLane})
  when is_atom(Node), is_integer(Label), is_integer(DomainSide), is_integer(OwnSide),
       is_integer(Bell), is_integer(Reader), is_integer(SystemLane) ->
    Words = [integer_to_list(Word) || Word <- [OwnSide, DomainSide, Bell, Label, Reader, SystemLane, Id]],
    Command = lists:join($\s, ["erx_lane" | Words] ++ [atom_to_list(Node)]),
    try open_port({spawn_driver, lists:flatten(Command)}, [binary]) of
        Port -> accepted(Kernel, Port, #{port => Port, node => Node, id => Id, system => false})
    catch
        error:Reason -> {error, Reason}
    end;
open(_Kernel, _Id, _Values) ->
    {error, badarg}.

%% The port is linked to the agent until hand_over gives it to its owner, so a refused one
%% is unlinked first, or its end would leave an 'EXIT' in the agent's queue.
accepted(Kernel, Port, Connection) ->
    try hand_over(Kernel, Connection) of
        ok ->
            {ok, Port};
        {error, _} = Refused ->
            refuse(Port),
            Refused
    catch
        error:Reason ->
            refuse(Port),
            {error, Reason}
    end.

refuse(Port) ->
    unlink(Port),
    close(Port, refused).

%% The finish (erx_lane_drv.c, port_control 2): the port takes every whole record the peer
%% published before the write position it reads once, through the funnel as always, and says
%% erx_lane_finished; then the port is ended with Reason, behind everything the peer
%% published. A port that ends by itself first, on a malformed record, has ended as such a
%% port always does, and one already gone has nothing to finish.
finish(Port, Reason) ->
    Ref = erlang:monitor(port, Port),
    case finished(Port, Ref) of
        true ->
            erlang:demonitor(Ref, [flush]),
            close(Port, Reason);
        false ->
            ok
    end.

%% Whether the port finished: false once it has ended, by itself or before it was asked.
finished(Port, Ref) ->
    try erlang:port_control(Port, ?CONTROL_FINISH, []) of
        _ ->
            receive
                {Port, erx_lane_finished} -> true;
                {'DOWN', Ref, port, Port, _} -> false
            end
    catch
        error:badarg -> receive {'DOWN', Ref, port, Port, _} -> false end
    end.

%% The port's end, awaited: once this returns no driver callback runs on the port. The
%% driver's stop, which unmaps the sides, may still be running on another scheduler when
%% the monitor fires (TODO.md).
close(Port, Reason) ->
    Ref = erlang:monitor(port, Port),
    exit(Port, Reason),
    receive {'DOWN', Ref, port, Port, _} -> ok end.

%% net_kernel's accept protocol, as inet_tcp_dist's acceptor follows it: net_kernel names
%% the connection's owner, which then owns the port and is told so. net_kernel's end
%% while the agent waits is acted on here, as in the agent's loops.
hand_over(Kernel, #{port := Port} = Connection) ->
    Kernel ! {accept, self(), Connection, erx, erx},
    receive
        {Kernel, controller, Owner} ->
            true = erlang:port_connect(Port, Owner),
            unlink(Port),
            Owner ! {self(), controller},
            ok;
        {Kernel, unsupported_protocol} ->
            {error, unsupported_protocol};
        {'EXIT', Kernel, Reason} ->
            kernel_ended(Reason)
    end.

%% A domain's agent acts on nothing but net_kernel's end; what else arrives is dropped, so
%% its queue stays empty.
drop(Kernel) ->
    receive
        {'EXIT', Kernel, Reason} -> kernel_ended(Reason);
        _ -> drop(Kernel)
    end.

%% net_kernel's end. net_kernel traps exits, so only its supervisor ends it with shutdown:
%% in the runtime's ordered end, or after a sibling's crash in net_sup or kernel_sup. Both
%% are one_for_all with intensity 0 (erl_distribution.erl, kernel.erl), so after a crash
%% kernel_sup gives up and the runtime ends too, and a restart of net_kernel halts at its
%% first erx_dist:accept/1. The agent follows a shutdown quietly, so an ordered end ends as
%% it was told; this rests on that supervision tree, and only a local terminate_child with
%% no restart would leave the runtime running without its agent. Any other end halts the
%% runtime.
kernel_ended(shutdown) -> exit(shutdown);
kernel_ended(Reason) -> erx_dist:unavailable(net_kernel, Reason).
