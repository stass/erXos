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

* `tcp_connect` and `udp_open`: `{ok, Socket}` with `Socket` a pid of the grant's own
  node, so a network domain cannot name a process of a third domain, nor a registered
  name that `gen_server:call/3` would follow, as a program's socket; the answer is
  `{ok, Pid}`. A connection answers `{ok, {'$inet', erx_gen_tcp, Pid}}` until the socket
  process speaks the socket protocol, and that form is taken apart for its pid;
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
""".

-export([answer/3, change/3]).

-export_type([operation/0, origin/0, check/0]).

-doc "An operation of the grant whose reply this module checks.".
-type operation() :: tcp_connect | udp_open | resolver | watch_resolver.

-doc "How the grant's domain's messages arrive: bare (`local`) or in an envelope naming that domain.".
-type origin() :: local | term().

-doc """
The check that refused a term: `operation`, an operation with no declared reply type;
`shape`, a term of none of the reply's forms; `socket`, an open's socket that is not a
pid of the grant's node; `reason`, an error reason outside the operation's closed list;
`resolver`, a resolver answer the resolver check refuses; `origin`, a change message
without the grant's envelope or from another grant.
""".
-type check() :: operation | shape | socket | reason | resolver | origin.

%% The error reasons each operation may answer: the stack's refusals of that request
%% (the error table of docs/design-network-stack.md, "Errors"), and `badarg`, the grant's
%% refusal of a request it does not take.
-define(OPEN_REASONS, [eacces, emfile, enobufs, eaddrinuse, eaddrnotavail, einval, enotsup, badarg]).
-define(CONNECT_REASONS, [econnrefused, etimedout, enetunreach, ehostunreach, enoprotoopt, econnreset, closed, timeout
                          | ?OPEN_REASONS]).
-define(RESOLVER_REASONS, [eacces, badarg]).

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

%% The reply type of each operation: what its `ok` carries, and its error reasons.
reply_type(tcp_connect) -> {ok, {connection, ?CONNECT_REASONS}};
reply_type(udp_open) -> {ok, {socket, ?OPEN_REASONS}};
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

%% What an `ok` answer carries, checked: a connection comes in the socket term it answers
%% today, `{'$inet', erx_gen_tcp, Pid}`, and a datagram socket as its bare pid.
carried(connection, Grant, {'$inet', erx_gen_tcp, Pid}) -> socket(Grant, Pid);
carried(connection, _Grant, _Value) -> {refused, shape};
carried(socket, Grant, Pid) -> socket(Grant, Pid);
carried(resolver, _Grant, Answer) -> resolver(Answer).

%% An open's socket: a pid of the grant's node, so no other domain's process and no
%% registered name.
socket(Grant, Pid) when is_pid(Pid), node(Pid) =:= node(Grant) -> {ok, Pid};
socket(_Grant, _Socket) -> {refused, socket}.

resolver(Answer) ->
    case erx_inet:resolver_config(Answer) of
        {ok, Resolver} -> {ok, Resolver};
        {error, badarg} -> {refused, resolver}
    end.
