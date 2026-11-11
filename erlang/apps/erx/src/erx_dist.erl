%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The distribution carrier between the domains of this machine, selected with
%% -proto_dist erx and -no_epmd (docs/design-runtime.md, "Connections in ERTS").
%%
%% A connection is a lane port (erx_lane_drv.c) that the system domain introduced, so
%% nothing here negotiates: the node's creation is its domain id, the peer's name, id and
%% flags are the introduction's, no cookie is asked, and no tick is written or awaited.
%% net_kernel drives the carrier through OTP's documented callbacks:
%%
%%   listen/2             the creation, from the boot page; no port mapper
%%   accept/1             starts erx_connections, the acceptor, which opens the system
%%                        connection from the boot page and hands it to net_kernel; in
%%                        the system domain, each domain's system side as the domain
%%                        service asks
%%   accept_connection/5  the connection's owner: setnode/3, then nodeup, then it waits
%%   setup/5              fails at once: only the system domain makes connections
%%   select/1             every node name at this machine's host
%%
%% The owner of the system connection halts the domain when the connection ends, since
%% the domain has no services without it and could tell no one. The agent and net_kernel
%% live as long as the runtime: in every domain, the end of either halts it, but for an
%% ordered stop of net_kernel, which ends the agent quietly (erx_connections).
-module(erx_dist).
-moduledoc false.

-export([listen/2, accept/1, accept_connection/5, setup/5, close/1, select/1,
         address/1, unavailable/2]).
-export([boot/0, names_dropped/0, export/3, exports/1, owner/1, aliases/0,
         exports_refused/0]).

-include_lib("kernel/include/net_address.hrl").
-include_lib("kernel/include/dist.hrl").

%% The frames' flag set (docs/design-domains.md, "The funnel"): no atom cache, no fragments.
-define(FLAGS, (?DFLAGS_MANDATORY bor ?DFLAG_PUBLISHED bor ?DFLAG_DIST_MONITOR bor
                ?DFLAG_DIST_MONITOR_NAME bor ?DFLAG_EXIT_PAYLOAD bor ?DFLAG_SEND_SENDER bor
                ?DFLAG_SPAWN bor ?DFLAG_ALIAS bor ?DFLAG_UNICODE_IO bor ?DFLAG_NATIVE_RECORDS)).

%% The lane driver's port_control command that runs its input task once (erx_lane_drv.c).
-define(CONTROL_KICK, 1).

%% The runtime's exit status when its system connection, its agent or net_kernel ends:
%% EX_UNAVAILABLE of sysexits(3).
-define(UNAVAILABLE_STATUS, 69).

%% The persistent term accept/1 writes once, at the start of the runtime's one agent.
-define(AGENT_STARTED, {?MODULE, agent_started}).

%% A connection as the acceptor hands it to net_kernel: its port and its peer.
-type connection() :: #{port := port(), node := node(), id := pos_integer(),
                        system := boolean()}.

%% The boot page's domain id and its system connection's peer, its id and node, with the
%% domain pid, the peer's process that stands for this domain; none in the system domain.
%% A BIF of ERTS (erx_lane_drv.c).
-spec boot() -> {pos_integer(), {pos_integer(), node(), pid()} | none}.
boot() ->
    erlang:nif_error(undefined).

%% The sends to another domain's registered names this runtime dropped, which never cross a
%% domain (edit 27 of docs/design-runtime.md). A BIF of ERTS (dist.c).
-spec names_dropped() -> non_neg_integer().
names_dropped() ->
    erlang:nif_error(undefined).

%% The export table (docs/design-domains.md, "Exports"), BIFs of ERTS (erx_exports.c).
-type right() :: send | link | exit | spawn | introduce.
-type own_name() :: pid() | {domain, pos_integer()}.

%% Sets what the domain Peer holds on Name, one of this domain's own names (a live local
%% pid, or the domain's name {domain, Id}), to exactly Rights; [] ends Peer's hold. A pid
%% holds send, link, exit and introduce, the domain's name spawn. The hold is on the
%% connection the two domains have and ends with it, so a domain exports again after a
%% reintroduction. {error, badarg} for any other name or a malformed argument,
%% {error, noconnection} for a grant to a peer with no connection with this domain,
%% {error, system_limit} when the table is full.
-spec export(own_name(), [right()], pos_integer()) ->
          ok | {error, badarg | noconnection | system_limit}.
export(_Name, _Rights, _Peer) ->
    erlang:nif_error(undefined).

%% The peers holding Name, one of this domain's own names, and what each holds.
-spec exports(own_name()) -> [{pos_integer(), [right()]}].
exports(_Name) ->
    erlang:nif_error(undefined).

%% Edit 16: the domain id a pid, reference or port claims, its creation, which for a name
%% from another domain its sender wrote; a process compares it with the D of
%% {erx_origin, D, Msg}, which the connection sets, to tell whether a message came from
%% the domain a name it holds claims. A BIF of ERTS (erx_exports.c).
-spec owner(pid() | reference() | port()) -> non_neg_integer().
owner(_Name) ->
    erlang:nif_error(undefined).

%% Edit 17: how many aliases of this domain are active, each an entry of the alias
%% registry (erx_alias.c) from the moment its monitor is made until the alias ends.
-spec aliases() -> non_neg_integer().
aliases() ->
    erlang:nif_error(undefined).

%% How many times the export table, full or out of memory, refused the holder of a name
%% handed out to a peer
%% or of a peer's spawn: each such name behaves at the peer as a dead process. A BIF of
%% ERTS (erx_exports.c).
-spec exports_refused() -> non_neg_integer().
exports_refused() ->
    erlang:nif_error(undefined).

-spec listen(atom(), string()) -> {ok, {term(), #net_address{}, pos_integer()}}.
listen(_Name, Host) ->
    {Id, System} = boot(),
    {ok, {System, address(Id, Host), Id}}.

-spec address(string()) -> #net_address{}.
address(Host) ->
    {Id, _System} = boot(),
    address(Id, Host).

address(Id, Host) ->
    #net_address{address = Id, host = Host, protocol = erx, family = erx}.

%% net_kernel calls accept/1 at each of its starts, and again to restart an agent that
%% ended; only the first call of a runtime starts one. The agent lives as long as the runtime (docs/design-runtime.md, "Connections in ERTS"):
%% a domain's domain pid keeps its pid for the domain's life, and the system domain's
%% agent holds every open system side, so a second call halts the runtime instead. The
%% persistent term, written once per runtime, is what tells the calls apart, so neither a
%% restarted agent nor a restarted net_kernel ever starts a second agent.
accept(System) ->
    case persistent_term:get(?AGENT_STARTED, false) of
        false ->
            persistent_term:put(?AGENT_STARTED, true),
            erx_connections:start(self(), System);
        true ->
            unavailable(connection_agent, ended)
    end.

close(_System) ->
    ok.

-spec select(node()) -> boolean().
select(Node) ->
    case host(Node) of
        none -> false;
        Host -> Host =:= host(node())
    end.

%% A connection exists only by introduction, so an attempt to make one ends at once, and
%% ERTS answers what waited on it as for a node it cannot reach.
setup(_Node, _Type, _MyNode, _LongOrShortNames, _SetupTime) ->
    spawn_opt(fun() -> exit({shutdown, not_introduced}) end, [link]).

-spec accept_connection(pid(), connection(), node(), term(), term()) -> pid().
accept_connection(AcceptPid, Connection, MyNode, _Allowed, _SetupTime) ->
    Kernel = self(),
    spawn_opt(fun() -> owner(Kernel, AcceptPid, MyNode, Connection) end,
              [link, {priority, max}]).

%% The connection's owner: takes the port from the acceptor, has net_kernel mark the peer
%% pending, makes the port the controller of the peer's entry, runs the port's input task
%% once for the frames that came before, reports the node up as dist_util does, and tells
%% the acceptor of an introduced connection once net_kernel has inserted it. Every
%% way it ends, a refusal or a crash included, goes through ended/2, so the system
%% connection's owner halts the domain on each. It acts on {Kernel, disconnect}, which
%% names net_kernel by a pid any peer can write; a message from another domain arrives
%% as {erx_origin, D, Msg} (edit 16) and reaches only its catch-all.
owner(Kernel, AcceptPid, MyNode, Connection) ->
    process_flag(trap_exit, true),
    try
        owner_up(Kernel, AcceptPid, MyNode, Connection)
    catch
        exit:{shutdown, _} = Shutdown -> exit(Shutdown);
        Class:Reason -> ended(Connection, {Class, Reason})
    end.

owner_up(Kernel, AcceptPid, MyNode, #{port := Port, node := Peer, id := PeerId} = Connection) ->
    receive
        {AcceptPid, controller} -> link(Port);
        {'EXIT', _From, Reason} -> ended(Connection, Reason)
    end,
    Kernel ! {self(), {accept_pending, MyNode, Peer, normal}},
    receive
        {Kernel, {accept_pending, Pending}} when Pending =:= ok; Pending =:= ok_pending -> ok;
        {Kernel, {accept_pending, up_pending}} -> wait_pending(Kernel, Peer);
        {Kernel, {accept_pending, Refused}} -> ended(Connection, {accept_pending, Refused})
    end,
    DHandle = erlang:setnode(Peer, Port, {?FLAGS, PeerId}),
    _ = erlang:port_control(Port, ?CONTROL_KICK, []),
    Kernel ! {self(), {nodeup, Peer, address(PeerId, host(Peer)), normal, false}},
    receive
        {Kernel, inserted, _TickIntensity} ->
            inserted(AcceptPid, Connection),
            owner_loop(Kernel, DHandle, Connection);
        {Kernel, bad_request} -> ended(Connection, bad_request)
    end.

%% The peer's entry is up: the agent answers an introduced connection's connection_up
%% only now (erx_connections, records/3), so the system domain hears ok for an
%% introduction once both entries are up, and the system domain's agent answers the open
%% of a domain's system side only now (erx_connections:open_side/2), so the domain
%% service's export to the domain finds its entry. The system connection's agent, in a
%% domain, awaits nothing.
inserted(_AcceptPid, #{system := true}) ->
    ok;
inserted(AcceptPid, #{port := Port, id := PeerId}) ->
    AcceptPid ! {erx_connection_inserted, PeerId, Port},
    ok.

%% A domain whose name an ended domain had, while net_kernel still holds the ended one's
%% connection: its owner waits for that connection's end, as dist_util's wait_pending does,
%% net_kernel ending its controller if it still lives.
wait_pending(Kernel, Peer) ->
    Kernel ! {self(), {wait_pending, Peer}},
    receive {Kernel, pending} -> ok end.

%% What net_kernel asks of a connection's owner, as dist_util's con_loop answers it. Ticks
%% are ignored: a silent peer is only silent, and a peer's end arrives from the system
%% domain. net_kernel ends a connection by exiting its controller, which reaches the owner
%% as the port's 'EXIT'; disconnect is dist_util's older request, kept as it handles it.
owner_loop(Kernel, DHandle, Connection) ->
    receive
        {Kernel, Tick} when Tick =:= tick; Tick =:= aux_tick ->
            owner_loop(Kernel, DHandle, Connection);
        {Kernel, disconnect} ->
            ended(Connection, disconnect);
        {From, get_status} ->
            {ok, Read, Write, _Pending} = erlang:dist_get_stat(DHandle),
            From ! {self(), get_status, {ok, Read, Write}},
            owner_loop(Kernel, DHandle, Connection);
        {From, Ref, {Options, _}} when Options =:= setopts; Options =:= getopts ->
            From ! {Ref, {error, enotsup}},
            owner_loop(Kernel, DHandle, Connection);
        {'EXIT', _From, Reason} ->
            ended(Connection, Reason);
        _Other ->
            owner_loop(Kernel, DHandle, Connection)
    end.

%% The owner's end, which closes the port it is linked to and takes the entry down.
ended(#{system := true}, Reason) ->
    unavailable(system_connection, Reason);
ended(#{system := false}, Reason) ->
    exit({shutdown, Reason}).

%% The system connection, the agent or net_kernel ended, or the system connection never
%% opened: the runtime halts. The console line names which, with an atom reason, the
%% driver's or net_kernel's, and only the class of any other, so no term from elsewhere
%% reaches it.
-spec unavailable(system_connection | connection_agent | net_kernel, term()) -> no_return().
unavailable(What, Reason) ->
    erlang:display({erx_dist, What, reason_class(Reason)}),
    erlang:halt(?UNAVAILABLE_STATUS).

reason_class(Reason) when is_atom(Reason) -> Reason;
reason_class({Class, _}) when is_atom(Class) -> Class;
reason_class(_Reason) -> other.

host(Node) ->
    case string:split(atom_to_list(Node), "@") of
        [_Name, Host] -> Host;
        _ -> none
    end.
