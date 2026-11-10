%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The connection agent, erx_dist's acceptor (docs/design-runtime.md, "Connections in
%% ERTS"), registered in its domain under its module's name. In a domain, it opens the
%% domain's system connection from the boot page, on the lane driver, and hands it to
%% net_kernel as an accepted connection; erx_dist's owner then brings the system domain's
%% entry up. The system domain has no system connection, so its agent opens nothing at
%% start: it opens the system domain's side of each domain's system connection when the
%% domain service asks, and closes it at the domain's end.
-module(erx_connections).
-moduledoc false.

-export([start/2, open_side/2, close_side/2]).

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
%% first thread runs. {error, noproc} where no agent runs, the runtime being no node; the
%% lane driver's or net_kernel's refusal otherwise, and badarg for a domain whose side is
%% open already.
-spec open_side(pos_integer(), side_values()) -> {ok, port()} | {error, term()}.
open_side(Id, Values) ->
    call({open_side, Id, Values}).

%% In the system domain: ends the system side of domain Id's system connection with
%% Reason, which takes the domain's entry down, and answers once the port has ended, so the
%% connection's objects may be destroyed then. ok for a domain whose side is not open.
%% Reason is not normal, which would end nothing.
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
    true = register(?MODULE, self()),
    serve(Kernel, System).

%% Any process handed this pid can reach it; what arrives from another domain comes as
%% {erx_origin, D, Msg} (edit 16), which neither loop acts on, so no peer steers it.
serve(Kernel, none) ->
    sides(Kernel, #{});
serve(Kernel, {PeerId, PeerNode, _DomainPid}) ->
    try
        Port = open_port({spawn_driver, "erx_lane system"}, [binary]),
        case hand_over(Kernel, #{port => Port, node => PeerNode, id => PeerId, system => true}) of
            ok -> ok;
            {error, Refusal} -> erx_dist:system_lost(Refusal)
        end
    catch
        Class:Reason -> erx_dist:system_lost({Class, Reason})
    end,
    drop().

%% The system domain's agent: the domain service's two calls, with the open sides by domain
%% id. A side whose port ended by itself stays here until its domain's end closes it.
sides(Kernel, Sides) ->
    receive
        {'$gen_call', From, {open_side, Id, Values}} when not is_map_key(Id, Sides) ->
            Opened = open(Kernel, Id, Values),
            gen:reply(From, Opened),
            case Opened of
                {ok, Port} -> sides(Kernel, Sides#{Id => Port});
                {error, _} -> sides(Kernel, Sides)
            end;
        {'$gen_call', From, {close_side, Id, Reason}} ->
            case maps:take(Id, Sides) of
                {Port, Rest} ->
                    close(Port, Reason),
                    gen:reply(From, ok),
                    sides(Kernel, Rest);
                error ->
                    gen:reply(From, ok),
                    sides(Kernel, Sides)
            end;
        {'$gen_call', From, _Request} ->
            gen:reply(From, {error, badarg}),
            sides(Kernel, Sides);
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
%% is unlinked first, or its end would end the agent.
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

%% The port's end, awaited: once this returns no driver callback runs on the port. The
%% driver's stop, which unmaps the sides, may still be running on another scheduler when
%% the monitor fires (TODO.md).
close(Port, Reason) ->
    Ref = erlang:monitor(port, Port),
    exit(Port, Reason),
    receive {'DOWN', Ref, port, Port, _} -> ok end.

%% net_kernel's accept protocol, as inet_tcp_dist's acceptor follows it: net_kernel names
%% the connection's owner, which then owns the port and is told so.
hand_over(Kernel, #{port := Port} = Connection) ->
    Kernel ! {accept, self(), Connection, erx, erx},
    receive
        {Kernel, controller, Owner} ->
            true = erlang:port_connect(Port, Owner),
            unlink(Port),
            Owner ! {self(), controller},
            ok;
        {Kernel, unsupported_protocol} ->
            {error, unsupported_protocol}
    end.

%% A domain's agent acts on nothing else; what arrives is dropped, so its queue stays empty.
drop() ->
    receive _ -> drop() end.
