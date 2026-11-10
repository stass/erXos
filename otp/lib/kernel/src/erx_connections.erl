%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The connection agent, erx_dist's acceptor (docs/design-runtime.md, "Connections in
%% ERTS"), registered in its domain under its module's name. In a domain, it opens the
%% domain's system connection from the boot page, on the lane driver, and hands it to
%% net_kernel as an accepted connection; erx_dist's owner then brings the system domain's
%% entry up. The system domain has no system connection, so its agent opens nothing at
%% start: it opens the system domain's side of each domain's system connection when the
%% domain service asks, closes it at the domain's end, and tells the service when a side
%% ends by itself. A domain's agent also maps each connection the system domain introduces
%% it to, on the connection_up its domain pid writes, finishes and ends it on
%% connection_down, and tells the domain pid when one ends by itself (records/3). Each
%% agent counts the messages it drops (dropped/0). The
%% agent and net_kernel live as long as the runtime: the agent halts it on net_kernel's
%% end other than an ordered stop, and erx_dist:accept/1 on the agent's.
-module(erx_connections).
-moduledoc false.

-export([start/2, open_side/2, close_side/2, dropped/0]).
%% A domain's agent past its system connection's hand-over, which start/2 runs and the
%% host test (test/erlang/erx_connections_tests.erl) runs with a stand-in opener.
-export([introduced/4]).

%% The lane driver's port_control command that finishes the port (erx_lane_drv.c).
-define(CONTROL_FINISH, 2).

%% What erx_domain_lib:create/1 returned for a domain's system connection, with the
%% domain's node: the slots of the two sides and of the domain's bell, the connection's
%% number, which labels the system domain's bell, and the two lanes' data areas.
-type side_values() :: #{node := node(), connection := pos_integer(), side := non_neg_integer(),
                         peer_side := non_neg_integer(), bell := non_neg_integer(),
                         reader := pos_integer(), system_lane := pos_integer(),
                         ctl_slots := non_neg_integer(), domain_pid_number := non_neg_integer(),
                         domain_pid_serial := non_neg_integer(), atom() => term()}.

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

%% How many messages this runtime's agent has dropped, each one it does not act on:
%% in a domain, a record that did not come from the system connection among them
%% (docs/design-domains.md, "Messages between the domain service and a runtime").
-spec dropped() -> non_neg_integer() | {error, noproc}.
dropped() ->
    call(dropped).

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

%% Any process handed this pid can reach it, and what arrives from another domain comes as
%% {erx_origin, D, Msg} (edit 16): the one such message either loop acts on is a domain's
%% record from the system domain, so no peer steers it. Both loops act on net_kernel's end, which the
%% agent's link brings as 'EXIT' (kernel_ended/1), answer dropped/0 with the count of
%% what they dropped, and answer any other call badarg.
serve(Kernel, none) ->
    sides(Kernel, #{}, 0);
serve(Kernel, {PeerId, PeerNode, DomainPid}) ->
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
    introduced(Kernel, PeerId, DomainPid, fun lane_open/1).

%% A domain's agent serving the records of the system domain SystemId's domain pid
%% DomainPid (records/3), with net_kernel Kernel taking each introduced connection's
%% port, which Open opens from its open command.
-spec introduced(pid(), pos_integer(), pid(), fun((string()) -> port())) -> no_return().
introduced(Kernel, SystemId, DomainPid, Open) ->
    records(#{kernel => Kernel, system => SystemId, domain_pid => DomainPid, open => Open}, #{}, 0).

%% An introduced connection's port, on the lane driver.
lane_open(Command) ->
    open_port({spawn_driver, Command}, [binary]).

%% The system domain's agent: the domain service's two calls, with each open side by domain
%% id as {Port, Monitor, Service}: its port, the monitor on it and the process that opened
%% it, the domain service.
%% A side's port ends with its owner (erx_dist), each linked to the other, so its monitor
%% fires on every end of either: the agent then tells the service, which stops the domain
%% (docs/design-system.md, "A lost system connection ends the domain"). A side the
%% service closes is no longer monitored, so its ordered end tells no one. erx_dist's
%% word that a side's entry is up, which only an introduced connection's agent awaits, is
%% ignored, and anything else dropped and counted in Dropped.
sides(Kernel, Sides, Dropped) ->
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
            sides(Kernel, Next, Dropped);
        {'$gen_call', From, {close_side, Id, Reason}} ->
            case maps:take(Id, Sides) of
                {{Port, Monitor, _Service}, Rest} ->
                    erlang:demonitor(Monitor, [flush]),
                    finish(Port, Reason),
                    gen:reply(From, ok),
                    sides(Kernel, Rest, Dropped);
                error ->
                    gen:reply(From, ok),
                    sides(Kernel, Sides, Dropped)
            end;
        {'$gen_call', From, dropped} ->
            gen:reply(From, Dropped),
            sides(Kernel, Sides, Dropped);
        {'$gen_call', From, _Request} ->
            gen:reply(From, {error, badarg}),
            sides(Kernel, Sides, Dropped);
        {{side_ended, Id}, Monitor, port, Port, _Reason} ->
            case maps:take(Id, Sides) of
                {{Port, Monitor, Service}, Rest} ->
                    Service ! {system_side_ended, Id},
                    sides(Kernel, Rest, Dropped);
                _ ->
                    sides(Kernel, Sides, Dropped)
            end;
        {erx_connection_inserted, _Id, _Port} ->
            sides(Kernel, Sides, Dropped);
        {'EXIT', Kernel, Reason} ->
            kernel_ended(Reason);
        _ ->
            sides(Kernel, Sides, Dropped + 1)
    end.

%% The port's open command, "erx_lane table" and its words, names the system domain's own
%% side first, the one it writes and whose control table it ends in, then the domain's, the
%% domain's bell, the label, the data areas of the lanes it writes and reads, the peer, the
%% domain, by id, the number and serial of the domain pid, the one process whose control
%% records the port writes, the table's slots, and the domain's node (erx_lane_drv.c,
%% lane_open_parse).
%% The library names the sides and the bell from the domain's view: side and bell are the
%% domain's, peer_side the system domain's; reader is the lane the system domain writes,
%% system_lane the one it reads. A port that net_kernel did not take is ended before the
%% answer, so no refused open leaves a port mapping the connection's objects.
open(Kernel, Id, #{node := Node, connection := Label, side := DomainSide, peer_side := OwnSide,
                   bell := Bell, reader := Reader, system_lane := SystemLane, ctl_slots := CtlSlots,
                   domain_pid_number := PidNumber, domain_pid_serial := PidSerial})
  when is_atom(Node), is_integer(Label), is_integer(DomainSide), is_integer(OwnSide),
       is_integer(Bell), is_integer(Reader), is_integer(SystemLane), is_integer(CtlSlots),
       is_integer(PidNumber), is_integer(PidSerial) ->
    Words = [integer_to_list(Word) || Word <- [OwnSide, DomainSide, Bell, Label, Reader, SystemLane, Id,
                                               PidNumber, PidSerial, CtlSlots]],
    Command = lists:join($\s, ["erx_lane", "table" | Words] ++ [atom_to_list(Node)]),
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
        ended ->
            ok;
        Live when Live =:= finished; Live =:= refused ->
            erlang:demonitor(Ref, [flush]),
            close(Port, Reason)
    end.

%% How the finish went: finished, once the port took every record before its position;
%% ended, once the port ended during it; refused, for a port gone before it was asked or
%% finished already, which close/2 ends if it lives and finds gone otherwise, so the agent
%% never waits on a port that will not end.
finished(Port, Ref) ->
    try erlang:port_control(Port, ?CONTROL_FINISH, []) of
        _ ->
            receive
                {Port, erx_lane_finished} -> finished;
                {'DOWN', Ref, port, Port, _} -> ended
            end
    catch
        error:badarg -> refused
    end.

%% The port's end, awaited: once this returns no driver callback runs on the port. The
%% driver's stop, which unmaps the sides, may still be running on another scheduler when
%% the monitor fires, so every answer sent after it, close_side's and records/3's
%% connection_unmapped and connection_lost, may precede the unmap (TODO.md).
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

%% A domain's agent, once its system connection is up: the connection-control records the
%% system domain's domain pid writes into the control table, which it acts on only as they
%% arrive in the envelope of the system connection, {erx_origin, SystemId, Record}, so a
%% peer handed the agent's pid can reach it but not steer it; erx_dist's word that an
%% introduced connection's entry is up; each introduced port's end; and net_kernel's end.
%% What else arrives is dropped and counted in Dropped, so its queue stays empty
%% (docs/design-domains.md, "Messages between the domain service and a runtime"). Held is
%% each introduced connection by the peer's domain id, as {Phase, Port, Monitor}: mapping
%% from the port's open until erx_dist's owner says the peer's entry is up, then up;
%% Monitor watches the port, so a port that ends by itself is answered. The system domain
%% sends one record about a peer at a time, each once the last is answered, so a
%% connection_up names a peer the agent holds no port for; one that does not is dropped.
%% Env is what the agent works with, as introduced/4 gives it.
records(#{kernel := Kernel, system := SystemId} = Env, Held, Dropped) ->
    receive
        {erx_origin, SystemId, {erx_connection_up, Peer, PeerNode, Side, PeerSide, PeerBell, Label, OutSize, InSize}}
          when is_integer(Peer), is_atom(PeerNode), not is_map_key(Peer, Held) ->
            Values = [Side, PeerSide, PeerBell, Label, OutSize, InSize],
            records(Env, connection_up(Env, Peer, PeerNode, Values, Held), Dropped);
        {erx_origin, SystemId, {erx_connection_down, Peer, Reason}} when is_integer(Peer) ->
            records(Env, connection_down(Env, Peer, Reason, Held), Dropped);
        {erx_connection_inserted, Peer, Port} ->
            records(Env, inserted(Env, Peer, Port, Held), Dropped);
        {{connection_ended, Peer}, Monitor, port, Port, Reason} ->
            records(Env, ended_itself(Env, Peer, Monitor, Port, Reason, Held), Dropped);
        {'$gen_call', From, dropped} ->
            gen:reply(From, Dropped),
            records(Env, Held, Dropped);
        {'$gen_call', From, _Request} ->
            gen:reply(From, {error, badarg}),
            records(Env, Held, Dropped);
        {'EXIT', Kernel, Reason} ->
            kernel_ended(Reason);
        _ ->
            records(Env, Held, Dropped + 1)
    end.

%% connection_up: the port opens, on the lane driver (lane_open/1), with the record's
%% words, "erx_lane Side PeerSide PeerBell Label OutSize InSize Peer PeerNode"
%% (erx_lane_drv.c, lane_open_parse),
%% whose open maps both sides and registers the label as the connection's sink, and goes to
%% net_kernel; erx_dist's owner then brings the peer's entry up with the system domain's id
%% and flags, as for the system connection, but with system := false, so the connection's
%% end ends only it, and says so (inserted/4). The agent answers connection_mapped only
%% then, so the system domain hears ok for an introduction once both entries are up
%% (docs/design-runtime.md, "Connections in ERTS"). An open the driver refuses, or a port
%% net_kernel does not take, is answered connection_lost with {map, refused} alone, the
%% port gone by then.
connection_up(#{kernel := Kernel, domain_pid := DomainPid, open := Open}, Peer, PeerNode, Values, Held) ->
    case open_introduced(Open, Peer, PeerNode, Values) of
        {ok, Port} ->
            Monitor = erlang:monitor(port, Port, [{tag, {connection_ended, Peer}}]),
            case accepted(Kernel, Port, #{port => Port, node => PeerNode, id => Peer, system => false}) of
                {ok, Port} ->
                    Held#{Peer => {mapping, Port, Monitor}};
                {error, _Refusal} ->
                    erlang:demonitor(Monitor, [flush]),
                    DomainPid ! {erx_connection_lost, Peer, {map, refused}},
                    Held
            end;
        {error, _Refusal} ->
            DomainPid ! {erx_connection_lost, Peer, {map, refused}},
            Held
    end.

open_introduced(Open, Peer, PeerNode, Values) ->
    case lists:all(fun is_integer/1, Values) of
        true ->
            Words = [integer_to_list(Word) || Word <- Values ++ [Peer]],
            Command = lists:flatten(lists:join($\s, ["erx_lane" | Words] ++ [atom_to_list(PeerNode)])),
            try {ok, Open(Command)}
            catch error:Reason -> {error, Reason}
            end;
        false ->
            {error, badarg}
    end.

%% erx_dist's owner of an introduced port has its peer's entry up: the agent answers
%% connection_mapped. A port the agent holds no mapping connection for, one that ended
%% first and was answered connection_lost, is nothing.
inserted(#{domain_pid := DomainPid}, Peer, Port, Held) ->
    case Held of
        #{Peer := {mapping, Port, Monitor}} ->
            DomainPid ! {erx_connection_mapped, Peer},
            Held#{Peer := {up, Port, Monitor}};
        #{} ->
            Held
    end.

%% An introduced port ended by itself: a malformed frame or position, a signal past
%% peer_held, erlang:disconnect_node/1, or its owner's end. ERTS has taken down the entry,
%% if the port controlled one yet, and the driver's stop unmaps both sides (close/2 says
%% when), so the agent tells the domain pid connection_lost with what ended it
%% (lost_reason/1), in {map, Lost} while the entry was not yet up.
%% A port the agent ended itself is no longer monitored, so it is never answered here.
ended_itself(#{domain_pid := DomainPid}, Peer, Monitor, Port, Reason, Held) ->
    case Held of
        #{Peer := {Phase, Port, Monitor}} ->
            Lost = case Phase of
                       mapping -> {map, lost_reason(Reason)};
                       up -> lost_reason(Reason)
                   end,
            DomainPid ! {erx_connection_lost, Peer, Lost},
            maps:remove(Peer, Held);
        #{} ->
            Held
    end.

%% What a port's end tells the domain pid, one of the reasons of design-domains' table of
%% messages, all atoms the system domain's code holds, so its safe decoder takes the
%% answer (edit 9 of docs/design-runtime.md), which a raw exit reason could fail: the lane
%% driver's end for a peer's malformed frame, position or record, or for a peer that does
%% not read its answers; its allocation failure; net_kernel's exit of the port, its
%% distribution controller, for erlang:disconnect_node/1; and noconnection for any other end.
lost_reason(erx_lane_malformed) -> malformed;
lost_reason(erx_lane_answers_unread) -> malformed;
lost_reason(erx_lane_no_memory) -> no_memory;
lost_reason(disconnect) -> disconnect;
lost_reason(_Reason) -> noconnection.

%% connection_down: the port finishes, so every whole frame the peer published before the
%% position it reads then is delivered, and then ends with the record's reason, which takes
%% the peer's entry down and fires its links and monitors with it (edit 56); the driver's
%% stop unmaps both sides; then the agent answers connection_unmapped. About a peer it holds
%% no port for, one it never mapped or already lost, it answers at once, having nothing
%% mapped. A port that ended by itself as the record came is gone already: its end is not
%% answered connection_lost, since connection_unmapped answers the record.
connection_down(#{domain_pid := DomainPid}, Peer, Reason, Held) ->
    case maps:take(Peer, Held) of
        {{_Phase, Port, Monitor}, Rest} ->
            erlang:demonitor(Monitor, [flush]),
            finish(Port, down_reason(Reason)),
            DomainPid ! {erx_connection_unmapped, Peer},
            Rest;
        error ->
            DomainPid ! {erx_connection_unmapped, Peer},
            Held
    end.

%% A port ended with normal would not end, so normal ends it as noconnection.
down_reason(normal) -> noconnection;
down_reason(Reason) -> Reason.

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
