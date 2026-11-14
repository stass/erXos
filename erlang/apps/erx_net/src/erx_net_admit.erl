%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_admit).
-moduledoc """
The network domain's one admission path (docs/design-network-stack.md, "The grant's
contract", "Sockets act for one domain", "Untrusted input"): every message from outside
the stack that a grant, a socket or the grant mint acts on is taken here first, as it
came, and answered as the request it may act on, or left out. The client domain is
untrusted. Only this module and erx_sock_admit, its twin on the client side, take a
message out of its `{erx_origin, D, Msg}` envelope, which a build check keeps so
(tools/lib/erx/net_checks.rb, `origin`).

**The grant.** request/2 takes a message the grant received, whose grantee is `Grantee`:
`local`, the grant's own domain, whose messages arrive bare, or a domain id `D`, whose
messages arrive as `{erx_origin, D, Msg}`. `Msg` must be a call, `{'$gen_call', {Pid,
Tag}, Request}`, whose reply goes to the grantee's domain: for `local`, `Pid` is a
process of this node; for `D`, the tag must be a reply alias, `[alias | Alias]`, and both
`Pid` and `Alias` must carry the creation `D`, the domain id they name (docs/
design-domains.md, D1), since gen:reply/2 sends to the alias, not to `Pid`, as
erx_facet requires of a facet's caller. Anything else, a message from another domain or
a call whose reply would go to a third domain, is `unknown`, for the grant to drop and
count, and no reply goes to anyone. `Request` must then be one of the grant's
operations, within its bounds:

* `{tcp_connect, inet, Ip, Port, Opts, Timeout}`: an IPv4 address tuple, a port from 1,
  a proper list of at most 64 options, and `infinity` or a timeout of at most the longest
  timer, 4294967295 ms;
* `{udp_open, inet, Local, Port, Opts}` and `{tcp_listen, inet, Local, Port, Opts}`: `any`
  or an IPv4 address, a port from 0, at most 64 options;
* `{icmp_open, inet}`, `interfaces`, `resolver` and `watch_resolver`.

The admitted request comes back with its caller, `{ok, Request, From}`, and the caller's
pid is the owner of what the request opens: no request names an owner of its own. A call
of another shape is `{refused, shape, From}`, answered `{error, badarg}`. The stack's own
calls of a grant, a connection's reservation and release of its buffers
(erx_net_grant:adopt/2, which adopts its caller, and reserve_buffer/4 and release_buffers/2,
whose token the grant checks) and
`counts` (erx_net_grant:counts/1), are admitted only bare and from a process of this node,
whatever the grantee.

**Sockets.** request/4 takes a message a socket received, for its socket process
`SockProc`, whose grantee's messages arrive by `Origin`, bare or enveloped as above; the
socket's kind, `tcp` for a connection, `tcp_listen` for a listener, `udp` for a datagram
socket, `icmp` for an echo socket, names the requests it takes. `Msg` must be
`{erx_net, SockProc, Body}` from that very socket process; anything else, an envelope of
another domain included, is `unknown`, for the socket to drop and count, and no reply goes
to a party that is not its socket process. `Body` must be `{credit, Bytes}` with `Bytes`
from 1 to 64 MiB, or
`{call, N, Request}` with `N` a request count and `Request` one of its kind's requests:

* `tcp`: `{send, Piece}` (a binary of at most 64 KiB), `{shutdown, How}`, `close`,
  `{setopts, [{nodelay, Boolean}]}`, `{getopts, [nodelay]}`, `sockname` or `peername`;
* `tcp_listen`: `{accept, SockProc, Timeout}`, with `SockProc` a pid of the grantee's
  domain (of this node when the grantee is `local`) and `Timeout` as for `tcp_connect`;
  `{setopts, [{nodelay, Boolean}]}`, `sockname` or `close`;
* `udp`: `{send_to, Ip, Port, Data}` with an IPv4 address tuple, a port and a binary of
  at most 65,527 bytes, the largest UDP payload; `{send, Data}` to the connected peer;
  `{connect, Ip, Port}` with a port from 1; `sockname` or `close`;
* `icmp`: `{echo_send, Ip, Seq, Ttl, Data}` with an IPv4 address tuple, a sequence
  number from 0 to 65535, a TTL from 1 to 255 or `default`, and a binary of at most
  65,507 bytes; or `close`.

A body of any other shape, or a request of another kind, is refused (`shape`).

**The mint.** mint/2 takes a message the network service's mint received: only
`{erx_facet_mint, Tag, net, Grantee, Principal, Limits}` in the system domain's envelope,
with a positive `Tag`, a domain id `Grantee`, a principal's name and a map of limits, is a
mint request; anything
else is `unknown` (docs/design-system.md, "Facets a configured domain serves"). A
request whose `Grantee` is the system domain's own id is refused, `{refused, eperm,
Tag}`, for the mint to answer and count: the system domain never holds the grant
(docs/design-network-stack.md, "The grant"). The mint's counts, `counts`, are asked
only bare and from a process of this node, as the grant's are.

The operation schema's generator will produce these checks from `abi/services/net.txt`;
until it exists they are written here with its signatures.
""".

-export([request/2, request/4, mint/2, domain/1]).

-export_type([origin/0, kind/0, request/0, grant_request/0]).

-define(PIECE, 65536).
%% The largest UDP payload (an IPv6 jumbogram aside) and the largest ICMP echo data of
%% an IPv4 datagram: 65535 less the IPv6 or IPv4 header and the UDP or echo header.
-define(MAX_UDP, 65527).
-define(MAX_ECHO, 65507).
-define(MAX_OPTS, 64).
%% The longest timer erlang:start_timer/3 takes, in milliseconds.
-define(MAX_TIMEOUT, 4294967295).
%% A call the stack makes of its own grant: an accepted connection's adoption, a connection's
%% buffers, or the grant's counts.
-define(IS_OWN(R), (R =:= counts orelse (is_tuple(R) andalso tuple_size(R) >= 1 andalso
                                          (element(1, R) =:= adopt orelse element(1, R) =:= reserve_buffer
                                           orelse element(1, R) =:= release_buffers)))).
-define(IS_BYTE(X), (is_integer(X) andalso X >= 0 andalso X =< 255)).
-define(IS_IP4(T), (tuple_size(T) =:= 4 andalso ?IS_BYTE(element(1, T)) andalso ?IS_BYTE(element(2, T))
                    andalso ?IS_BYTE(element(3, T)) andalso ?IS_BYTE(element(4, T)))).
%% stock's TCP_MAX_PACKET_SIZE: the most credit a socket process grants at once.
-define(MAX_CREDIT, 67108864).

-doc "How the grantee's messages arrive: bare (`local`) or in an envelope naming its domain.".
-type origin() :: local | pos_integer().

-doc "A request of the grant, as request/2 admits it.".
-type grant_request() :: {tcp_connect, inet, inet:ip4_address(), 1..16#ffff, list(), timeout()}
                       | {udp_open, inet, any | inet:ip4_address(), 0..16#ffff, list()}
                       | {tcp_listen, inet, any | inet:ip4_address(), 0..16#ffff, list()}
                       | {icmp_open, inet} | interfaces | resolver | watch_resolver
                       | {adopt, #{snd := pos_integer(), rcv := non_neg_integer()}}
                       | {reserve_buffer, reference(), snd | rcv, non_neg_integer()}
                       | {release_buffers, reference()} | counts.

-doc """
A socket's kind: a TCP connection, a TCP listener, a UDP datagram socket or an ICMP echo
socket.
""".
-type kind() :: tcp | tcp_listen | udp | icmp.

-doc "A socket protocol request, as request/4 admits it.".
-type request() :: {credit, pos_integer()}
                 | {call, non_neg_integer(),
                    {send, binary()} | {shutdown, read | write | read_write} | close
                    | {setopts, [{nodelay, boolean()}]} | {getopts, [nodelay]} | sockname | peername
                    | {send_to, inet:ip4_address(), inet:port_number(), binary()}
                    | {connect, inet:ip4_address(), 1..16#ffff}
                    | {echo_send, inet:ip4_address(), 0..16#ffff, 1..255 | default, binary()}
                    | {accept, pid(), timeout()}}.

-doc """
Takes `Message`, received by the grant of `Grantee`: the call it carries with its caller,
`unknown` when it is not a call of the grantee's, or a call refused for its shape.
""".
-spec request(term(), origin()) ->
          {ok, grant_request(), gen_server:from()} | {refused, shape, gen_server:from()} | unknown.
request({'$gen_call', {Pid, _} = From, Request}, _Grantee) when is_pid(Pid), node(Pid) =:= node(), ?IS_OWN(Request) ->
    case own(Request) of
        true -> {ok, Request, From};
        false -> {refused, shape, From}
    end;
request({'$gen_call', {Pid, _} = From, Request}, local) when is_pid(Pid), node(Pid) =:= node() ->
    grant(Request, From);
request({erx_origin, D, {'$gen_call', {Pid, [alias | Alias]} = From, Request}}, Grantee)
  when is_integer(Grantee), D =:= Grantee, is_pid(Pid), is_reference(Alias) ->
    case domain(Pid) =:= Grantee andalso domain(Alias) =:= Grantee of
        true -> grant(Request, From);
        false -> unknown
    end;
request(_Message, _Grantee) ->
    unknown.

grant(Request, From) ->
    case grant(Request) of
        true -> {ok, Request, From};
        false -> {refused, shape, From}
    end.

grant({tcp_connect, inet, Ip, Port, Opts, Timeout}) ->
    is_tuple(Ip) andalso ?IS_IP4(Ip) andalso is_integer(Port) andalso Port >= 1 andalso Port =< 16#ffff
        andalso options(Opts, 0) andalso timeout(Timeout);
grant({udp_open, inet, Local, Port, Opts}) ->
    local_bind(Local, Port, Opts);
grant({tcp_listen, inet, Local, Port, Opts}) ->
    local_bind(Local, Port, Opts);
grant({icmp_open, inet}) -> true;
grant(interfaces) -> true;
grant(resolver) -> true;
grant(watch_resolver) -> true;
grant(_) -> false.

%% An explicit bind's request: `any` or an IPv4 address, a port from 0, its options.
local_bind(Local, Port, Opts) ->
    (Local =:= any orelse (is_tuple(Local) andalso ?IS_IP4(Local))) andalso is_integer(Port)
        andalso Port >= 0 andalso Port =< 16#ffff andalso options(Opts, 0).

%% The stack's own calls of the grant.
own({adopt, #{snd := Snd, rcv := Rcv} = Sizes}) ->
    map_size(Sizes) =:= 2 andalso is_integer(Snd) andalso Snd > 0 andalso is_integer(Rcv) andalso Rcv >= 0;
own({reserve_buffer, Token, Kind, Bytes}) ->
    is_reference(Token) andalso (Kind =:= snd orelse Kind =:= rcv) andalso is_integer(Bytes) andalso Bytes >= 0;
own({release_buffers, Token}) ->
    is_reference(Token);
own(counts) ->
    true;
own(_) ->
    false.

%% A proper list of at most ?MAX_OPTS elements, counted without walking past the bound.
options([], _Count) -> true;
options([_ | Rest], Count) when Count < ?MAX_OPTS -> options(Rest, Count + 1);
options(_, _) -> false.

timeout(infinity) -> true;
timeout(T) -> is_integer(T) andalso T >= 0 andalso T =< ?MAX_TIMEOUT.

-doc """
The domain id a pid or a reference names: its node's creation, which on erXos is the id
of the domain the process runs in or that made the reference (docs/design-domains.md,
D1), as the external term format carries it (NEW_PID_EXT, NEWER_REFERENCE_EXT).
""".
-spec domain(pid() | reference()) -> non_neg_integer().
domain(Pid) when is_pid(Pid) ->
    case term_to_binary(Pid) of
        <<131, 88, 119, Len, _Node:Len/binary, _Id:32, _Serial:32, Creation:32>> -> Creation;
        <<131, 88, 118, Len:16, _Node:Len/binary, _Id:32, _Serial:32, Creation:32>> -> Creation
    end;
domain(Ref) when is_reference(Ref) ->
    case term_to_binary(Ref) of
        <<131, 90, _Words:16, 119, Len, _Node:Len/binary, Creation:32, _/binary>> -> Creation;
        <<131, 90, _Words:16, 118, Len:16, _Node:Len/binary, Creation:32, _/binary>> -> Creation
    end.

-doc """
Takes `Message`, received by the network service's mint in a domain whose system
domain's id is `System`: the mint request it carries, its refusal when it names the
system domain as the grantee, a call of the mint's counts, or `unknown`.
""".
-spec mint(pos_integer(), term()) ->
          {ok, pos_integer(), pos_integer(), map()} | {refused, eperm, pos_integer()}
          | {counts, gen_server:from()} | unknown.
mint(System, {erx_origin, D, {erx_facet_mint, Tag, net, Grantee, Principal, Limits}})
  when D =:= System, is_integer(Tag), Tag > 0, is_integer(Grantee), Grantee > 0, is_binary(Principal),
       is_map(Limits) ->
    case Grantee =:= System of
        true -> {refused, eperm, Tag};
        false -> {ok, Tag, Grantee, Limits}
    end;
mint(_System, {'$gen_call', {Pid, _} = From, counts}) when is_pid(Pid), node(Pid) =:= node() ->
    {counts, From};
mint(_System, _Message) ->
    unknown.

-doc """
Takes `Message`, received by a socket of kind `Kind` whose socket process is `SockProc`
(`none` once it has none) and whose grantee's messages arrive by `Origin`.
""".
-spec request(kind(), origin(), pid() | none, term()) -> {ok, request()} | unknown | {refused, shape}.
request(Kind, local, SockProc, {erx_net, SockProc, Body}) when is_pid(SockProc) ->
    body(Kind, local, Body);
request(Kind, Origin, SockProc, {erx_origin, D, {erx_net, SockProc, Body}})
  when Origin =/= local, D =:= Origin, is_pid(SockProc) ->
    body(Kind, Origin, Body);
request(_Kind, _Origin, _SockProc, _Message) ->
    unknown.

body(_Kind, _Origin, {credit, Bytes}) when is_integer(Bytes), Bytes > 0, Bytes =< ?MAX_CREDIT ->
    {ok, {credit, Bytes}};
body(Kind, Origin, {call, N, Request}) when is_integer(N), N >= 0 ->
    case call(Kind, Request) andalso of_grantee(Request, Origin) of
        true -> {ok, {call, N, Request}};
        false -> {refused, shape}
    end;
body(_Kind, _Origin, _) ->
    {refused, shape}.

%% The socket process an `accept` names is of the grantee's domain, as the one a grant's
%% `connect`, `listen` or `open` names is (docs/design-network-stack.md, "Sockets act for one
%% domain"); the listener links to it and binds a connection to it.
of_grantee({accept, SockProc, _}, local) -> node(SockProc) =:= node();
of_grantee({accept, SockProc, _}, Grantee) -> domain(SockProc) =:= Grantee;
of_grantee(_Request, _Origin) -> true.

call(tcp, {send, Piece}) -> is_binary(Piece) andalso byte_size(Piece) =< ?PIECE;
call(tcp, {shutdown, How}) -> How =:= read orelse How =:= write orelse How =:= read_write;
call(Kind, {setopts, []}) when Kind =:= tcp; Kind =:= tcp_listen -> true;
call(Kind, {setopts, [{nodelay, B}]}) when Kind =:= tcp; Kind =:= tcp_listen -> is_boolean(B);
call(tcp, {getopts, []}) -> true;
call(tcp, {getopts, [nodelay]}) -> true;
call(tcp, peername) -> true;
call(tcp_listen, {accept, SockProc, Timeout}) -> is_pid(SockProc) andalso timeout(Timeout);
call(udp, {send_to, Ip, Port, Data}) ->
    is_tuple(Ip) andalso ?IS_IP4(Ip) andalso is_integer(Port) andalso Port >= 0 andalso Port =< 16#ffff
        andalso is_binary(Data) andalso byte_size(Data) =< ?MAX_UDP;
call(udp, {send, Data}) -> is_binary(Data) andalso byte_size(Data) =< ?MAX_UDP;
call(udp, {connect, Ip, Port}) ->
    is_tuple(Ip) andalso ?IS_IP4(Ip) andalso is_integer(Port) andalso Port >= 1 andalso Port =< 16#ffff;
call(icmp, {echo_send, Ip, Seq, Ttl, Data}) ->
    is_tuple(Ip) andalso ?IS_IP4(Ip) andalso is_integer(Seq) andalso Seq >= 0 andalso Seq =< 16#ffff
        andalso (Ttl =:= default orelse (is_integer(Ttl) andalso Ttl >= 1 andalso Ttl =< 255))
        andalso is_binary(Data) andalso byte_size(Data) =< ?MAX_ECHO;
call(Kind, sockname) -> Kind =:= tcp orelse Kind =:= tcp_listen orelse Kind =:= udp;
call(_Kind, close) -> true;
call(_Kind, _) -> false.
