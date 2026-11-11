%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_sock_admit).
-moduledoc """
The check of every message the client side takes from the network domain
(docs/design-network-stack.md, "Untrusted input", "Answers from the grant"), as far as
the grant's answers and its resolver change messages need it. Once the grant is in
another domain, everything it sends is untrusted: each check takes the term as it came
and answers what the caller may use, rebuilt from the parts it checked, or the name of
the check that refused it, never the term. The operation schema's generator will
produce this module from the reply types `abi/services/net.txt` declares; until it
exists it is hand-written with the generated module's signatures (Decisions, 10).

**Answers.** answer/3 checks the grant's reply to one call, which `gen` has already
taken out of its envelope, against the reply type of the call's operation:

* `tcp_connect`, `udp_open` and `icmp_open`: `{ok, Socket}` with `Socket` a pid of the
  grant's own node, so a network domain cannot name a process of a third domain, nor a
  registered name that `gen_server:call/3` would follow, as a program's socket; the
  answer is `{ok, Pid}`;
* `interfaces`: `{ok, Interfaces}`, a proper list of at most 64 interfaces, each a map of
  `name`, 1 to 15 bytes, FreeBSD's `IFNAMSIZ`, of letters, digits, `.`, `-` and `_`;
  `lladdr`, six bytes; `mtu`, 1 to 65535; `link`, `up` or `down`; `config`, `static` or
  `dhcp`; and `addrs`, at most 64 addresses, each `#{addr, plen}` with an IPv4 or IPv6
  address tuple and a prefix length within it, and an IPv4 `broadcast` beside an IPv4
  address. Each interface comes back rebuilt from those keys alone;
* `resolver` and `watch_resolver`: `{ok, Map}` that erx_inet:resolver_config/1 takes,
  its search domains as strings;
* any of them: `{error, Reason}` with `Reason` from the operation's closed list.

An operation this module declares no reply type for is refused whatever it answers, so
a new operation of the grant reaches program code only with its check.

**Change messages.** change/3 checks a message the resolver loader takes against the
origin its grant was found with: `local`, the caller's own domain, whose messages
arrive bare, or the domain id `D` of the grant's domain, whose messages arrive as
`{erx_origin, D, Msg}`. `Msg` must be `{erx_net_resolver, Grant, Answer}` from that
very grant, and `Answer` passes the `resolver` reply type. A bare message from a grant
in another domain, an envelope of another domain, or a change from another grant is
refused.

**Pushes.** push/3 takes a message the socket process received, for its socket `Socket`
whose grant's domain arrives by `Origin`. A message bare from a `local` socket, or
`{erx_origin, D, Msg}` with `D` the origin, and `Msg` `{erx_net, Socket, Body}` from that
very socket, is the socket's; anything else is `unknown`, for the caller to drop and
count. Of the socket's, `Body` must be one of the socket protocol's pushes:

* `{reply, N, Result}`, `N` a request count, `Result` checked by result/2 once the
  socket process knows which request `N` was;
* `{data, Pieces}`, a proper list of 1 to 64 binaries of 1 to 65,536 bytes in all,
  counted without walking past the 64th element, so a long list costs no more;
* `eof`, and `{error, Reason}` with `Reason` one of the end reasons.

A push of any other shape is refused (`push`), and the socket process aborts the socket.

**Replies.** result/2 checks a reply to a request of the socket protocol against its
reply type: `ok` or an error from a closed list for `send`, `shutdown` and `setopts`;
`{ok, [{nodelay, Boolean}]}` for `getopts`; `{ok, {Ip, Port}}` for `sockname` and
`peername`. It checks an echo socket's replies too: `ok` or an error for `echo_send`
and `echo_close`, and for `echo_recv` `{ok, {Ip, Ttl, Seq, Data}}` with an IPv4 address,
a TTL from 0 to 255, a sequence number from 0 to 65535 and a binary of at most 65535
bytes, or `{error, timeout}`.
""".

-export([answer/3, change/3, push/3, result/2]).

-export_type([operation/0, origin/0, check/0, push/0, end_reason/0]).

-doc "An operation of the grant whose reply this module checks.".
-type operation() :: tcp_connect | udp_open | icmp_open | interfaces | resolver | watch_resolver.

-doc "How the grant's domain's messages arrive: bare (`local`) or in an envelope naming that domain.".
-type origin() :: local | term().

-doc """
The check that refused a term: `operation`, an operation with no declared reply type;
`shape`, a term of none of the reply's forms; `socket`, an open's socket that is not a
pid of the grant's node; `interface`, an interface the interfaces check refuses; `reason`, an error reason outside the operation's closed list;
`resolver`, a resolver answer the resolver check refuses; `origin`, a change message
without the grant's envelope or from another grant; `push`, a socket's push of none of
the protocol's shapes. The socket process adds its own checks of a push: `reply`, a
reply to no request in flight; `credit`, data past the credit outstanding; `order`, data
or `eof` after `eof`.
""".
-type check() :: operation | shape | socket | interface | reason | resolver | origin | push | reply | credit | order.

-doc "A socket's push, as push/3 admits it.".
-type push() :: {reply, non_neg_integer(), term()} | {data, [binary(), ...]} | eof
              | {error, end_reason()}.

-doc "Why a socket ended: its last push.".
-type end_reason() :: closed | econnreset | econnaborted | econnrefused | etimedout
                    | ehostunreach | enetunreach | enoprotoopt | epipe | timeout.

%% The error reasons each operation may answer: the stack's refusals of that request
%% (the error table of docs/design-network-stack.md, "Errors"), and `badarg`, the grant's
%% refusal of a request it does not take.
-define(OPEN_REASONS, [eacces, emfile, enobufs, eaddrinuse, eaddrnotavail, einval, enotsup, badarg]).
-define(CONNECT_REASONS, [econnrefused, etimedout, enetunreach, ehostunreach, enoprotoopt, econnreset, closed, timeout
                          | ?OPEN_REASONS]).
-define(RESOLVER_REASONS, [eacces, badarg]).
-define(INTERFACES_REASONS, [enotconn, eacces, badarg]).
%% An echo socket's refusals of a send (erx_icmp_sock, erx_net_frame:path/3).
-define(ECHO_REASONS, [emsgsize, enobufs, enetunreach, ehostunreach, eaddrnotavail, einval, closed, badarg]).
-define(MAX_INTERFACES, 64).
-define(MAX_ADDRS, 64).
-define(IFNAMSIZ, 15).
-define(MAX_ECHO_DATA, 65535).
%% The ends of a connection: `closed` without an error, or the error that ended it, an
%% ICMP soft error among them (`enoprotoopt` for a parameter problem: erx_tcp_icmp,
%% erx_icmp4, erx_icmp6).
-define(END_REASONS, [closed, econnreset, econnaborted, econnrefused, etimedout, ehostunreach, enetunreach, enoprotoopt,
                      epipe, timeout]).
%% The errors a socket answers its requests with: its refusals (erx_tcp_user) and the
%% socket protocol's `badarg`.
-define(SOCKET_REASONS, [einval, enotconn, epipe, ebusy, ealready, eisconn, badarg | ?END_REASONS]).
-define(PIECE, 65536).
-define(MAX_PIECES, 64).
-define(IS_BYTE(X), (is_integer(X) andalso X >= 0 andalso X =< 255)).

-doc """
Checks the grant's answer `Answer` to a call of `Operation`, the grant being `Grant`;
answers the reply rebuilt from its checked parts, or the check that refused it.
""".
-spec answer(atom(), pid(), term()) -> {ok, term()} | {refused, check()}.
answer(Operation, Grant, Answer) when is_atom(Operation), is_pid(Grant) ->
    case reply_type(Operation) of
        {ok, Type} -> admit(Type, Grant, Answer);
        none -> {refused, operation}
    end.

-doc """
Checks `Message`, taken by the resolver loader, as a change message of `Grant`, whose
domain's messages arrive by `Origin`; answers the checked resolver, or the check that
refused it.
""".
-spec change(origin(), pid(), term()) -> {ok, erx_inet:resolver()} | {refused, check()}.
change(local, Grant, {erx_net_resolver, Grant, Answer}) ->
    resolver(Answer);
change(Origin, Grant, {erx_origin, D, {erx_net_resolver, Grant, Answer}}) when Origin =/= local, D =:= Origin ->
    resolver(Answer);
change(_Origin, _Grant, _Message) ->
    {refused, origin}.

-doc """
Takes `Message`, received by the socket process of `Socket`, whose grant's domain's
messages arrive by `Origin`: the push it carries, `unknown` when it is not that socket's,
or the check that refused it.
""".
-spec push(origin(), pid(), term()) -> {ok, push()} | unknown | {refused, check()}.
push(local, Socket, {erx_net, Socket, Body}) ->
    body(Body);
push(Origin, Socket, {erx_origin, D, {erx_net, Socket, Body}}) when Origin =/= local, D =:= Origin ->
    body(Body);
push(_Origin, _Socket, _Message) ->
    unknown.

body({reply, N, Result}) when is_integer(N), N >= 0 -> {ok, {reply, N, Result}};
body({data, Pieces}) ->
    case pieces(Pieces, 0, 0) of
        ok -> {ok, {data, Pieces}};
        error -> {refused, push}
    end;
body(eof) -> {ok, eof};
body({error, Reason}) ->
    case lists:member(Reason, ?END_REASONS) of
        true -> {ok, {error, Reason}};
        false -> {refused, push}
    end;
body(_) -> {refused, push}.

%% A proper list of at most ?MAX_PIECES binaries, of 1 to ?PIECE bytes in all.
pieces([], Count, Bytes) when Count > 0, Bytes > 0 -> ok;
pieces([Piece | Rest], Count, Bytes) when is_binary(Piece), Count < ?MAX_PIECES,
                                          Bytes + byte_size(Piece) =< ?PIECE ->
    pieces(Rest, Count + 1, Bytes + byte_size(Piece));
pieces(_, _, _) -> error.

-doc """
Checks `Result`, a socket's reply to a request of kind `Kind` (`send`, `shutdown`,
`setopts`, `getopts`, `sockname` or `peername`), against its reply type.
""".
-spec result(atom(), term()) -> {ok, term()} | {refused, check()}.
result(Kind, ok) when Kind =:= send; Kind =:= shutdown; Kind =:= setopts ->
    {ok, ok};
result(getopts, {ok, []}) ->
    {ok, {ok, []}};
result(getopts, {ok, [{nodelay, B}]}) when is_boolean(B) ->
    {ok, {ok, [{nodelay, B}]}};
result(Kind, {ok, {{A, B, C, D}, Port}})
  when (Kind =:= sockname orelse Kind =:= peername), ?IS_BYTE(A), ?IS_BYTE(B), ?IS_BYTE(C), ?IS_BYTE(D),
       is_integer(Port), Port >= 0, Port =< 16#ffff ->
    {ok, {ok, {{A, B, C, D}, Port}}};
result(echo_recv, {ok, {{A, B, C, D}, Ttl, Seq, Data}})
  when ?IS_BYTE(A), ?IS_BYTE(B), ?IS_BYTE(C), ?IS_BYTE(D), ?IS_BYTE(Ttl), is_integer(Seq), Seq >= 0,
       Seq =< 16#ffff, is_binary(Data), byte_size(Data) =< ?MAX_ECHO_DATA ->
    {ok, {ok, {{A, B, C, D}, Ttl, Seq, Data}}};
result(echo_recv, {error, timeout}) ->
    {ok, {error, timeout}};
result(Kind, ok) when Kind =:= echo_send; Kind =:= echo_close ->
    {ok, ok};
result(Kind, {error, Reason}) when Kind =:= echo_send; Kind =:= echo_close ->
    case lists:member(Reason, ?ECHO_REASONS) of
        true -> {ok, {error, Reason}};
        false -> {refused, reason}
    end;
result(echo_recv, _Result) ->
    {refused, shape};
result(_Kind, {error, Reason}) ->
    case lists:member(Reason, ?SOCKET_REASONS) of
        true -> {ok, {error, Reason}};
        false -> {refused, reason}
    end;
result(_Kind, _Result) ->
    {refused, shape}.

%% The reply type of each operation: what its `ok` carries, and its error reasons.
reply_type(tcp_connect) -> {ok, {socket, ?CONNECT_REASONS}};
reply_type(udp_open) -> {ok, {socket, ?OPEN_REASONS}};
reply_type(icmp_open) -> {ok, {socket, ?OPEN_REASONS}};
reply_type(interfaces) -> {ok, {interfaces, ?INTERFACES_REASONS}};
reply_type(resolver) -> {ok, {resolver, ?RESOLVER_REASONS}};
reply_type(watch_resolver) -> {ok, {resolver, ?RESOLVER_REASONS}};
reply_type(_) -> none.

admit({Carried, _}, Grant, {ok, Value}) ->
    case carried(Carried, Grant, Value) of
        {ok, Checked} -> {ok, {ok, Checked}};
        {refused, _} = Refused -> Refused
    end;
admit({_, Reasons}, _Grant, {error, Reason}) ->
    case lists:member(Reason, Reasons) of
        true -> {ok, {error, Reason}};
        false -> {refused, reason}
    end;
admit(_Type, _Grant, _Answer) ->
    {refused, shape}.

%% What an `ok` answer carries, checked: a connection's or a datagram socket's pid.
carried(socket, Grant, Pid) -> socket(Grant, Pid);
carried(resolver, _Grant, Answer) -> resolver(Answer);
carried(interfaces, _Grant, Interfaces) -> interfaces(Interfaces, 0, []).

%% A proper list of at most ?MAX_INTERFACES interfaces, each rebuilt from its checked keys.
interfaces([], _Count, Acc) ->
    {ok, lists:reverse(Acc)};
interfaces([If | Rest], Count, Acc) when Count < ?MAX_INTERFACES ->
    case interface(If) of
        {ok, Checked} -> interfaces(Rest, Count + 1, [Checked | Acc]);
        error -> {refused, interface}
    end;
interfaces(_, _, _) ->
    {refused, interface}.

interface(#{name := Name, lladdr := <<_:48>> = Lladdr, mtu := Mtu, link := Link, config := Config,
            addrs := Addrs})
  when is_binary(Name), byte_size(Name) >= 1, byte_size(Name) =< ?IFNAMSIZ, is_integer(Mtu), Mtu >= 1,
       Mtu =< 16#ffff, (Link =:= up orelse Link =:= down), (Config =:= static orelse Config =:= dhcp) ->
    maybe
        true ?= ifname(Name),
        {ok, Checked} ?= addrs(Addrs, 0, []),
        {ok, #{name => Name, lladdr => Lladdr, mtu => Mtu, link => Link, config => Config, addrs => Checked}}
    else
        _ -> error
    end;
interface(_) ->
    error.

ifname(Name) ->
    lists:all(fun(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse (C >= $0 andalso C =< $9)
                            orelse C =:= $. orelse C =:= $- orelse C =:= $_ end,
              binary_to_list(Name)).

addrs([], _Count, Acc) ->
    {ok, lists:reverse(Acc)};
addrs([Addr | Rest], Count, Acc) when Count < ?MAX_ADDRS ->
    case addr(Addr) of
        {ok, Checked} -> addrs(Rest, Count + 1, [Checked | Acc]);
        error -> error
    end;
addrs(_, _, _) ->
    error.

addr(#{addr := {A, B, C, D} = Ip, plen := Plen} = Addr)
  when ?IS_BYTE(A), ?IS_BYTE(B), ?IS_BYTE(C), ?IS_BYTE(D), is_integer(Plen), Plen >= 0, Plen =< 32 ->
    case Addr of
        #{broadcast := {E, F, G, H} = Broadcast} when ?IS_BYTE(E), ?IS_BYTE(F), ?IS_BYTE(G), ?IS_BYTE(H) ->
            {ok, #{addr => Ip, plen => Plen, broadcast => Broadcast}};
        #{broadcast := _} ->
            error;
        #{} ->
            {ok, #{addr => Ip, plen => Plen}}
    end;
addr(#{addr := Ip, plen := Plen})
  when tuple_size(Ip) =:= 8, is_integer(Plen), Plen >= 0, Plen =< 128 ->
    case lists:all(fun(W) -> is_integer(W) andalso W >= 0 andalso W =< 16#ffff end, tuple_to_list(Ip)) of
        true -> {ok, #{addr => Ip, plen => Plen}};
        false -> error
    end;
addr(_) ->
    error.

%% An open's socket: a pid of the grant's node, so no other domain's process and no
%% registered name.
socket(Grant, Pid) when is_pid(Pid), node(Pid) =:= node(Grant) -> {ok, Pid};
socket(_Grant, _Socket) -> {refused, socket}.

resolver(Answer) ->
    case erx_inet:resolver_config(Answer) of
        {ok, Resolver} -> {ok, Resolver};
        {error, badarg} -> {refused, resolver}
    end.
