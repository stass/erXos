%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_grant).
-moduledoc """
A client domain's grant (docs/design-network-stack.md, "The grant's contract", "The
grant"), as far as an active and a passive open, a datagram socket, an echo socket, the interfaces and
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
ports erx_net_grant_core:bind_ports/3 allows (erx_net_bind:bind/2), and an address the
grant's `addresses` does not list is refused with `eacces`. Options are the socket
process's own, so a non-empty list is refused with `einval`. `{icmp_open, inet}` starts an
echo socket (erx_icmp_sock) for the caller likewise.

**Listen.** `{tcp_listen, inet, Local, Port, Opts}` starts a listener (erx_tcp_listen),
linked to the grant, for the caller, its socket process: `Local` is `any` or an IPv4
address, `Port` 0 for an ephemeral port, and the listener binds them explicitly within the
ports erx_net_grant_core:bind_ports/3 allows a listener, the grant's `ports` narrowed by
`listen`; a grant whose `listen` is `false`, or whose `addresses` does not list `Local`, is
answered `{error, eacces}`. `Opts` are the listener's own options, which
erx_tcp_listen_core:options/1 takes (`backlog`, `reuseaddr`, `reuseport`, `nodelay`); any
other is refused with `einval`. The listener's answer, `{ok, Listener}` or the bind's
refusal, is the grant's. The grant reserves no buffer for a listener, which holds none.

**Sockets.** Every socket the grant starts or adopts, a connection, a listener, a datagram
or an echo socket, is one of its sockets from its start until its exit, or for a
connection until it gives its buffers back in TIME-WAIT (erx_net_grant_core). Every one
becomes the grant's by one path, which admits it, starts it, records it and links it to
the grant, so each is counted and its exit frees its place, whatever its kind. With the
`sockets` limit reached, `connect`, `listen`, `udp_open` and `icmp_open` are answered
`{error, emfile}` before anything is started, and an adoption is refused alike, so the
interface resets that connection and `accept` never answers `emfile` (the design's
Decision 20). A `sockets` or `buffers` limit that is not a non-negative integer refuses
the grant's start with `{error, badarg}`.

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
with its socket process gone, and leaves the grant's sockets with them; its exit, by
whatever means, releases what it still holds. An `'EXIT'` message naming a process still
alive is not an exit and is ignored, and one naming no process of this node is admitted
as any other message.

**Adoption.** A connection an interface spawned from a listener's handshake (erx_tcp_conn,
"An accepted connection's start") links to the grant and asks `adopt/2` to count it as
one of the grant's sockets, with the two buffer sizes its listener's entry gives; the
grant reserves them under a new token, as a connect does, and answers `{ok, Token}`,
`{error, emfile}` at its `sockets` limit, or `{error, enobufs}` when they do not fit. The
socket adopted is the caller, so nothing is reserved on the word of a pid in a message,
and its exit releases what it holds as any connection's does.

The grant's other limits and its account are not built: the grant admits every
well-formed request within its sockets and buffers.
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
returns; a refused export is answered `{error, Reason}` and leaves no grant, as is a
malformed `sockets` or `buffers` limit, with `{error, badarg}`, before any export.
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
its later buffer calls name, or `{error, emfile}` past the grant's `sockets` limit and
`{error, enobufs}` past its `buffers` limit; a caller already one of the grant's sockets
is refused too, with `{error, badarg}` when the limits admit one more.
""".
-spec adopt(pid(), #{snd := pos_integer(), rcv := non_neg_integer()}) ->
          {ok, reference()} | {error, emfile | enobufs | badarg}.
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
Gives back both buffers of the calling connection, whose start carried `Token`, once it
needs them no more, in TIME-WAIT with its socket process gone, and with them its place
among the grant's sockets, so its token reserves nothing more: `ok`, or `{error, badarg}`
for any other caller or token.
""".
-spec release_buffers(pid(), reference()) -> ok | {error, badarg}.
release_buffers(Grant, Token) ->
    gen_server:call(Grant, {release_buffers, Token}, infinity).

-doc false.
%% A malformed `sockets` or `buffers` limit refuses the grant before it is exported.
init({Client, Limits}) ->
    maybe
        {ok, Sockets} ?= erx_net_grant_core:new(Limits),
        {ok, Grantee, ConnectionMonitor} ?= export(Client),
        process_flag(trap_exit, true),
        ok = (erx_net_sup:runtime()):serve(?MAX_REQUEST),
        ok = erx_net_tables:watch_resolver(self()),
        ok = erx_net_tables:watch_grant(self()),
        {ok, #{grantee => Grantee, connection_monitor => ConnectionMonitor, limits => Limits,
               gen => erx_net_rand:new(erx_net_clock:entropy(16)), callers => #{},
               sockets => Sockets, subscriber => none, resolver => none,
               unknown => 0, refused => 0}}
    end.

%% The grantee, exported to when it is a domain, and the monitor of the connection to it.
export(local) ->
    {ok, local, none};
export({Grantee, Connection, Exports}) ->
    %% The monitor comes first: a connection that ends at any time from here on, before the
    %% export or after it, ends the grant, and a port that has ended already is answered at
    %% once with a 'DOWN'. So the grant never outlives the connection whose port it was
    %% given, even when the export binds to a newer one.
    ConnectionMonitor = erlang:monitor(port, Connection),
    case Exports:export(self(), [send], Grantee) of
        ok -> {ok, Grantee, ConnectionMonitor};
        {error, _} = Refused -> Refused
    end.

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
    #{grantee := Grantee, gen := Gen0, callers := Callers} = S0) ->
    {Child, Gen} = erx_net_rand:split(Gen0),
    S = S0#{gen := Gen},
    Initial = #{snd => ?SNDBUF, rcv => ?RCVBUF},
    Start = fun(Token) ->
                    erx_tcp_conn:start_link(#{owner => Owner, origin => Grantee, from => From,
                                              remote => {<<A, B, C, D>>, Port}, opts => Opts,
                                              timeout => Timeout, gen => Child, grant => self(),
                                              token => Token, buffers => Initial})
            end,
    %% The connection answers the caller, or its exit does.
    case open_socket(Initial, Start, S) of
        {ok, Conn, _Token, Opened} -> {noreply, Opened#{callers := Callers#{Conn => From}}};
        {error, _} = Error -> {reply, Error, S}
    end;
act({adopt, Sizes}, {Conn, _}, S) ->
    %% The socket adopted is the caller, already running; a second adoption is refused.
    case open_socket(Sizes, fun(_Token) -> {ok, Conn} end, S) of
        {ok, Conn, Token, Opened} -> {reply, {ok, Token}, Opened};
        {error, _} = Error -> {reply, Error, S}
    end;
act({reserve_buffer, Token, Kind, Bytes}, {Conn, _}, #{sockets := Sockets0} = S) ->
    case erx_net_grant_core:reserve(Conn, Token, Kind, Bytes, Sockets0) of
        {ok, Sockets} -> {reply, ok, S#{sockets := Sockets}};
        {error, _} = Error -> {reply, Error, S}
    end;
act({release_buffers, Token}, {Conn, _}, #{sockets := Sockets0} = S) ->
    case erx_net_grant_core:release(Conn, Token, Sockets0) of
        {ok, Sockets} -> {reply, ok, S#{sockets := Sockets}};
        {error, _} = Error -> {reply, Error, S}
    end;
act({udp_open, inet, Local, Port, []}, {Owner, _}, #{grantee := Grantee, limits := Limits} = S) ->
    Start = fun() ->
                    maybe
                        {ok, Ports} ?= erx_net_grant_core:bind_ports(udp, Local, Limits),
                        erx_udp_sock:open(Port, #{ip => Local, owner => Owner, origin => Grantee,
                                                  grant => self(), ports => Ports})
                    end
            end,
    open_unbuffered(Start, S);
act({udp_open, inet, _Local, _Port, _Opts}, _From, S) ->
    %% The socket process keeps every option gen_udp:open/2 takes; the socket takes none.
    {reply, {error, einval}, S};
act({tcp_listen, inet, Local, Port, Opts}, {Owner, _}, #{grantee := Grantee, limits := Limits} = S) ->
    Start = fun() ->
                    maybe
                        {ok, Allowed} ?= erx_net_grant_core:bind_ports(tcp_listen, Local, Limits),
                        {ok, Options} ?= erx_tcp_listen_core:options(Opts),
                        erx_tcp_listen:start_link(#{socket => Owner, origin => Grantee,
                                                    local => Local, port => Port,
                                                    allowed => Allowed, options => Options})
                    end
            end,
    open_unbuffered(Start, S);
act({icmp_open, inet}, {Owner, _}, #{grantee := Grantee} = S) ->
    Start = fun() -> erx_icmp_sock:open(#{owner => Owner, origin => Grantee, grant => self()}) end,
    open_unbuffered(Start, S);
act(counts, _From, #{unknown := Unknown, refused := Refused} = S) ->
    {reply, #{unknown => Unknown, refused => Refused}, S};
act(interfaces, _From, S) ->
    {reply, interfaces(), S};
act(resolver, _From, S) ->
    {reply, {ok, resolver()}, S};
act(watch_resolver, {Pid, _}, #{subscriber := Old} = S) ->
    Resolver = resolver(),
    {reply, {ok, Resolver}, S#{subscriber := subscribe(Pid, Old), resolver := Resolver}}.

%% The one way a socket becomes one of the grant's, so every socket is counted and freed
%% alike: admitted with buffers of Sizes, started by Start with the token the grant makes
%% for it (an adopted connection is running already), recorded under that token, and
%% linked, so its exit frees its place and its buffers. The grant's emfile or enobufs, or
%% Start's refusal, leaves nothing started or recorded.
open_socket(Sizes, Start, #{sockets := Sockets0} = S) ->
    Token = make_ref(),
    maybe
        ok ?= erx_net_grant_core:admits(Sizes, Sockets0),
        {ok, Socket} ?= Start(Token),
        %% Nothing else ran in the grant since it admitted the socket, and a socket just
        %% started is open nowhere, so only a second adoption is refused here.
        {ok, Sockets} ?= erx_net_grant_core:open(Socket, Token, Sizes, Sockets0),
        true = link(Socket),
        {ok, Socket, Token, S#{sockets := Sockets}}
    end.

%% A socket that holds no buffer, a listener, a datagram or an echo socket, opened by Start;
%% the socket, or the refusal, is the reply.
open_unbuffered(Start, S) ->
    case open_socket(#{snd => 0, rcv => 0}, fun(_Token) -> Start() end, S) of
        {ok, Socket, _Token, Opened} -> {reply, {ok, Socket}, Opened};
        {error, _} = Error -> {reply, Error, S}
    end.

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
handle_info({'EXIT', Conn, _Reason}, #{callers := Callers0, sockets := Sockets} = S0)
  when is_pid(Conn), node(Conn) =:= node() ->
    %% Every socket of the grant is a process of this node; an 'EXIT' naming anything else
    %% is no exit signal, and is admitted as any other message.
    case is_process_alive(Conn) of
        true ->
            %% A linked process's exit signal arrives only once it is dead, so this is a
            %% message some process sent in its name: it frees nothing and answers no one.
            {noreply, S0};
        false ->
            S = S0#{sockets := erx_net_grant_core:exited(Conn, Sockets)},
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
