%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_grant).
-moduledoc """
A client domain's grant (docs/design-network-stack.md, "The grant's contract", "The
grant"), as far as an active open, a datagram socket, an echo socket, the interfaces and
name resolution need it. Each grant serves one grantee: `local`, the stack's own domain,
whose grant is registered as `erx_net_grant`, or a domain id, whose grant the network
service's mint starts (erx_net:mint_grant/4).

**Its start and its end.** A grant of a domain id exports itself to its grantee, with send
alone, before its start returns, so no one is handed a grant its grantee cannot reach; a
refused export is its start's refusal. Before the export it monitors the port of this
domain's connection to the grantee, which it is started with, and it ends with
`{shutdown, connection_ended}` when that port ends: the connection is gone, so the grantee
can no longer call, and the grant's export goes with it (docs/design-domains.md, D13). A
grant is never restarted: the domain service grants a domain again only when either
domain restarts.

**Admission.** The grant acts on no message erx_net_admit:request/2 has not admitted:
gen_server takes a bare call apart before handle_call/3 sees it, so the grant puts it back
together and admits it as it came, and every other message it does not make for itself,
an enveloped call among them, is admitted in handle_info/2. A message erx_net_admit
leaves out (another domain's, or a call whose reply would go outside the grantee's
domain) is dropped and counted; a call of the grantee's that is no operation's is
answered `{error, badarg}` and counted. The owner of every socket the grant starts is the
admitted call's caller.

**Connect.** `{tcp_connect, inet, Ip, Port, Opts, Timeout}` starts the connection linked
to the grant, with a generator split from its own, owned by the caller, its socket
process, whose messages arrive as the grantee's do; and the grant traps exits, so a
connection's end never ends the grant. The connection answers the connect caller; when it
exits, however it ends, the grant answers that caller `{error, closed}` too, so a
connection that dies before answering leaves no caller waiting. A caller already answered
never sees the second answer: a call's reply alias is gone once its first reply arrived.
A connection's demultiplexing entries are deleted by erx_net_tables, which watches it in
the grant's place. Every entry names its socket's grant, and erx_net_tables, which watches
the grant from its start, deletes every entry naming it when the grant ends.

**Open.** `{udp_open, inet, Local, Port, []}` starts a datagram socket (erx_udp_sock)
for the caller, its socket process, which the socket monitors and speaks the socket
protocol to, its messages arriving by the grantee's origin; `Local` is `any` or an IPv4
address and `Port` 0 for an ephemeral port; the socket binds it explicitly within the
grant's `ports` (erx_net_bind:bind/2). Options are the socket process's own, so a
non-empty list is refused with `einval`. `{icmp_open, inet}` starts an echo socket
(erx_icmp_sock) for the caller likewise.

**Interfaces.** `interfaces` answers `{ok, Interfaces}`, each interface's name, link-layer
address, MTU, link state, configuration and addresses as erx_net:interfaces/0 gives them,
which any holder of the grant may read, as FreeBSD's ifconfig shows them to any user.

**Resolver.** `resolver` answers `{ok, #{nameservers := [{Ip, 53}], search :=
[binary()]}}`, the name servers and search list of the interfaces' rows
(erx_net:interfaces/0), and changes nothing. `watch_resolver` answers the same and
makes the caller the grant's one subscriber: whenever the answer changes, the
subscriber gets `{erx_net_resolver, Grant, Answer}`, so its domain's inet_db follows the
lease as resolv.conf follows dhclient-script. A domain loads its resolver from one
process, erx_inet, the one caller of `watch_resolver`; a later watcher replaces the
earlier one, so the grant holds one subscriber whatever its client does, and a reader
never displaces it. The grant asks the interfaces only for a request and, while it has
a subscriber, after each notice of erx_net_tables, so a grant nobody asks never calls an
interface.

**Buffers.** Every byte of a connection's send and receive buffers is reserved at the
grant, within its `buffers` limit (erx_net_grant_core). A connect reserves the initial
buffers, FreeBSD's `tcp_sendspace` and `tcp_recvspace`, before the connection starts, and
is answered `{error, enobufs}` when they do not fit; the connection starts with those
sizes. The grant makes a token for each connection and hands it over in the start; every
later call for the connection's buffers names it, and any call without the right token is
answered `{error, badarg}`, so no process charges or frees another's buffers by naming its
pid in a call. Before a connection grows a buffer, by rounding it to whole segments or by
autosizing, it asks `reserve_buffer/4`; a refusal leaves its buffer as it was. A connection
gives both buffers back with `release_buffers/2` once it needs them no more, in TIME-WAIT
with its socket process gone, and its exit, by whatever means, releases what it still
holds; an `'EXIT'` message naming a connection still alive is not its exit, and is ignored.

**Adoption.** A connection an interface spawned from a listener's handshake (erx_tcp_conn,
"An accepted connection's start") links to the grant and asks `adopt/2` to count it as
one of the grant's sockets, with the two buffer sizes its listener's entry gives; the grant
reserves them under a new token, as a connect does, and answers `{ok, Token}`, or
`{error, enobufs}` when they do not fit. The socket adopted is the caller, so nothing is
reserved on the word of a pid in a message, and its exit releases what it holds as any
connection's does.

The grant's other limits and its account are not built: the grant admits every
well-formed request whose buffers fit.
""".

-behaviour(gen_server).

-export([start_link/2, adopt/2, reserve_buffer/4, release_buffers/2, counts/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(MAX_REQUEST, 64).
%% tcp_sendspace and tcp_recvspace, FreeBSD's initial buffer sizes (tcp_usrreq.c).
-define(SNDBUF, 32768).
-define(RCVBUF, 65536).
-define(DNS_PORT, 53).
-define(MAXNS, 3).
-define(MAXDNSRCH, 6).

-doc """
Starts the grant of `local`, the node's own, registered as `erx_net_grant`, where
erx_net:local_grant/0 finds it, or of a domain, `{Grantee, Connection, Exports}`: the
domain id, the port of this domain's connection to it, and the export table's module
(erx_dist, or a host test's stand-in). A domain's grant is exported to it before this
returns; a refused export is answered `{error, Reason}` and leaves no grant.
""".
-spec start_link(local | {pos_integer(), port(), module()}, map()) -> {ok, pid()} | {error, term()}.
start_link(local, Limits) when is_map(Limits) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {local, Limits}, []);
start_link({Grantee, Connection, Exports} = Client, Limits)
  when is_integer(Grantee), Grantee > 0, is_port(Connection), is_atom(Exports), is_map(Limits) ->
    gen_server:start_link(?MODULE, {Client, Limits}, []).

-doc """
The messages the grant has left out (`unknown`) and the calls it refused (`refused`),
asked by a process of its own node.
""".
-spec counts(pid()) -> #{unknown := non_neg_integer(), refused := non_neg_integer()}.
counts(Grant) ->
    gen_server:call(Grant, counts, infinity).

-doc """
Adopts the calling connection, which has linked to the grant, as one of the grant's sockets:
reserves its send and receive buffers of `Sizes` and answers `{ok, Token}` with the token
its later buffer calls name, or `{error, enobufs}` past the grant's `buffers` limit;
a caller the grant already holds buffers for is answered `{error, badarg}`.
""".
-spec adopt(pid(), #{snd := pos_integer(), rcv := non_neg_integer()}) ->
          {ok, reference()} | {error, enobufs | badarg}.
adopt(Grant, Sizes) ->
    gen_server:call(Grant, {adopt, Sizes}, infinity).

-doc """
Asks the grant to let the calling connection, whose start carried `Token`, hold `Bytes` of
its send or receive buffer, before the connection grows it: `ok`, or `{error, enobufs}`
past the grant's `buffers` limit. Any other caller or token is answered `{error, badarg}`.
""".
-spec reserve_buffer(pid(), reference(), snd | rcv, non_neg_integer()) ->
          ok | {error, enobufs | badarg}.
reserve_buffer(Grant, Token, Kind, Bytes) ->
    gen_server:call(Grant, {reserve_buffer, Token, Kind, Bytes}, infinity).

-doc """
Gives back both buffers of the calling connection, whose start carried `Token`, which needs
them no more: `ok`, or `{error, badarg}` for any other caller or token.
""".
-spec release_buffers(pid(), reference()) -> ok | {error, badarg}.
release_buffers(Grant, Token) ->
    gen_server:call(Grant, {release_buffers, Token}, infinity).

-doc false.
init({local, Limits}) ->
    start(local, none, Limits);
init({{Grantee, Connection, Exports}, Limits}) ->
    %% The monitor comes first: a connection that ends at any time from here on, before the
    %% export or after it, ends the grant, and a port that has ended already is answered at
    %% once with a 'DOWN'. So the grant never outlives the connection whose port it was
    %% given, even when the export binds to a newer one.
    ConnectionMonitor = erlang:monitor(port, Connection),
    case Exports:export(self(), [send], Grantee) of
        ok -> start(Grantee, ConnectionMonitor, Limits);
        {error, _} = Refused -> Refused
    end.

start(Grantee, ConnectionMonitor, Limits) ->
    process_flag(trap_exit, true),
    ok = (erx_net_sup:runtime()):serve(?MAX_REQUEST),
    ok = erx_net_tables:watch_resolver(self()),
    ok = erx_net_tables:watch_grant(self()),
    {ok, #{grantee => Grantee, connection_monitor => ConnectionMonitor, limits => Limits,
           gen => erx_net_rand:new(erx_net_clock:entropy(16)), callers => #{},
           buffers => erx_net_grant_core:new(Limits), subscriber => none, resolver => none,
           unknown => 0, refused => 0}}.

%% gen_server took a bare call apart; it is put back together, so the grant admits every
%% call as it came.
-doc false.
handle_call(Request, From, S) ->
    admit({'$gen_call', From, Request}, S).

%% Acts on a message as erx_net_admit:request/2 admitted it. The reply goes out by
%% gen_server:reply/2 whichever callback took the message, since handle_info/2 has no
%% reply of its own.
admit(Message, #{grantee := Grantee} = S0) ->
    case erx_net_admit:request(Message, Grantee) of
        {ok, Request, From} ->
            case act(Request, From, S0) of
                {reply, Reply, S} ->
                    gen_server:reply(From, Reply),
                    {noreply, S};
                {noreply, _} = NoReply ->
                    NoReply
            end;
        {refused, shape, From} ->
            gen_server:reply(From, {error, badarg}),
            {noreply, count(refused, S0)};
        unknown ->
            {noreply, count(unknown, S0)}
    end.

count(Key, S) ->
    maps:update_with(Key, fun(N) -> N + 1 end, S).

%% An admitted request: answered, or answered later by what it started.
act({tcp_connect, inet, {A, B, C, D}, Port, Opts, Timeout}, {Owner, _} = From,
    #{grantee := Grantee, gen := Gen0, callers := Callers, buffers := Buffers0} = S) ->
    Initial = #{snd => ?SNDBUF, rcv => ?RCVBUF},
    case erx_net_grant_core:room(Buffers0) >= ?SNDBUF + ?RCVBUF of
        false ->
            {reply, {error, enobufs}, S};
        true ->
            {Child, Gen} = erx_net_rand:split(Gen0),
            Token = make_ref(),
            Start = #{owner => Owner, origin => Grantee, from => From,
                      remote => {<<A, B, C, D>>, Port}, opts => Opts, timeout => Timeout,
                      gen => Child, grant => self(), token => Token, buffers => Initial},
            case erx_tcp_conn:start_link(Start) of
                {ok, Conn} ->
                    %% Nothing else ran in the grant since its room was checked, and the
                    %% connection's first call waits until this one returns.
                    {ok, Buffers} = erx_net_grant_core:open(Conn, Token, Initial, Buffers0),
                    {noreply, S#{gen := Gen, callers := Callers#{Conn => From}, buffers := Buffers}};
                {error, Reason} ->
                    {reply, {error, Reason}, S#{gen := Gen}}
            end
    end;
act({adopt, Sizes}, {Conn, _}, #{buffers := Buffers0} = S) ->
    %% The grant links the socket it adopts, so its exit releases what it holds whatever
    %% the caller did; a socket already holding buffers is refused, not a crash.
    Token = make_ref(),
    try erx_net_grant_core:open(Conn, Token, Sizes, Buffers0) of
        {ok, Buffers} ->
            true = link(Conn),
            {reply, {ok, Token}, S#{buffers := Buffers}};
        {error, enobufs} = Refused ->
            {reply, Refused, S}
    catch
        error:badarg -> {reply, {error, badarg}, S}
    end;
act({reserve_buffer, Token, Kind, Bytes}, {Conn, _}, #{buffers := Buffers0} = S) ->
    case erx_net_grant_core:reserve(Conn, Token, Kind, Bytes, Buffers0) of
        {ok, Buffers} -> {reply, ok, S#{buffers := Buffers}};
        {error, _} = Error -> {reply, Error, S}
    end;
act({release_buffers, Token}, {Conn, _}, #{buffers := Buffers0} = S) ->
    case erx_net_grant_core:release(Conn, Token, Buffers0) of
        {ok, Buffers} -> {reply, ok, S#{buffers := Buffers}};
        {error, _} = Error -> {reply, Error, S}
    end;
act({udp_open, inet, Local, Port, []}, {Owner, _}, #{grantee := Grantee, limits := Limits} = S) ->
    {reply, erx_udp_sock:open(Port, #{ip => Local, owner => Owner, origin => Grantee,
                                      grant => self(), ports => ports(Limits)}), S};
act({udp_open, inet, _Local, _Port, _Opts}, _From, S) ->
    %% The socket process keeps every option gen_udp:open/2 takes; the socket takes none.
    {reply, {error, einval}, S};
act({icmp_open, inet}, {Owner, _}, #{grantee := Grantee} = S) ->
    {reply, erx_icmp_sock:open(#{owner => Owner, origin => Grantee, grant => self()}), S};
act(counts, _From, #{unknown := Unknown, refused := Refused} = S) ->
    {reply, #{unknown => Unknown, refused => Refused}, S};
act(interfaces, _From, S) ->
    {reply, interfaces(), S};
act(resolver, _From, S) ->
    {reply, {ok, resolver()}, S};
act(watch_resolver, {Pid, _}, #{subscriber := Old} = S) ->
    Resolver = resolver(),
    {reply, {ok, Resolver}, S#{subscriber := subscribe(Pid, Old), resolver := Resolver}}.

-doc false.
handle_cast(_Msg, S) ->
    {noreply, S}.

-doc false.
handle_info({erx_net_tables, resolver}, #{subscriber := none} = S) ->
    {noreply, S};
handle_info({erx_net_tables, resolver}, #{resolver := Old, subscriber := {Pid, _}} = S) ->
    case resolver() of
        Old ->
            {noreply, S};
        New ->
            Pid ! {erx_net_resolver, self(), New},
            {noreply, S#{resolver := New}}
    end;
handle_info({'DOWN', Ref, port, _, _}, #{connection_monitor := Ref} = S) ->
    {stop, {shutdown, connection_ended}, S};
handle_info({'DOWN', Ref, process, _, _}, #{subscriber := {_, Ref}} = S) ->
    {noreply, S#{subscriber := none}};
handle_info({'EXIT', Conn, _Reason}, #{callers := Callers0, buffers := Buffers} = S0) ->
    case is_process_alive(Conn) of
        true ->
            %% A linked process's exit signal arrives only once it is dead, so this is a
            %% message some process sent in its name: it frees nothing and answers no one.
            {noreply, S0};
        false ->
            S = S0#{buffers := erx_net_grant_core:exited(Conn, Buffers)},
            case maps:take(Conn, Callers0) of
                {From, Callers} ->
                    gen_server:reply(From, {error, closed}),
                    {noreply, S#{callers := Callers}};
                error ->
                    {noreply, S}
            end
    end;
handle_info(Message, S) ->
    admit(Message, S).

%% The local ports the grant may bind explicitly, as inclusive ranges: its `ports` limit,
%% 1024 to 65535 by default, as FreeBSD reserves the ports below 1024 to privilege
%% (`ipport_reservedhigh`, in_pcb.c).
ports(Limits) ->
    maps:get(ports, Limits, [{1024, 65535}]).

%% The interfaces as the `interfaces` operation shows them: what ifconfig prints, and not
%% the routes and resolver servers, which the resolver operation answers.
interfaces() ->
    case erx_net:interfaces() of
        {ok, Ifs} -> {ok, [(maps:with([lladdr, mtu, link, config, addrs], If))#{name => name(Name)}
                           || #{name := Name} = If <- Ifs]};
        {error, _} = Error -> Error
    end.

name(Name) when is_atom(Name) -> atom_to_binary(Name);
name(Name) when is_binary(Name) -> Name.

%% The resolver operation's answer: the interfaces' name servers and search lists, in the
%% order of the interfaces' names, repeats dropped, cut to resolv.conf's limits, three
%% servers and six domains, as FreeBSD's resolver reads at most MAXNS `nameserver` lines
%% and MAXDNSRCH `search` domains (resolv.h).
resolver() ->
    {ok, Ifs} = erx_net:interfaces(),
    Servers = lists:uniq(lists:append([Dns || #{dns := Dns} <- Ifs])),
    Search = lists:uniq(lists:append([Domains || #{search := Domains} <- Ifs])),
    #{nameservers => [{Ip, ?DNS_PORT} || Ip <- lists:sublist(Servers, ?MAXNS)],
      search => lists:sublist(Search, ?MAXDNSRCH)}.

%% The one subscriber: Pid, monitored, in place of the one before it.
subscribe(Pid, {Pid, _} = Same) ->
    Same;
subscribe(Pid, none) ->
    {Pid, erlang:monitor(process, Pid)};
subscribe(Pid, {_, Ref}) ->
    true = erlang:demonitor(Ref, [flush]),
    subscribe(Pid, none).
