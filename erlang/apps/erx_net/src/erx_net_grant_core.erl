%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_grant_core).
-moduledoc """
The grant's decisions over its sockets and their buffers (docs/design-network-stack.md,
"Sockets act for one domain", the `sockets` and `buffers` limits of "The grant"). The
grant's sockets are those open here, so their count is the size of one map, and nothing
else keeps it: an open past the `sockets` limit, 1,024 by default, is refused with
`emfile`, as FreeBSD's `falloc` refuses past a process's descriptor limit, and every byte
of send and receive buffer a socket holds is reserved here first, and refused with
`enobufs` past the `buffers` limit, as FreeBSD's `chgsbsize` refuses past a user's
`RLIMIT_SBSIZE` (kern_resource.c). The count comes first, as a FreeBSD socket's descriptor
is allocated before its buffers are reserved.

A socket opens with both of its buffers reserved, none for a socket that holds no buffer
(a listener, a datagram or an echo socket), under a token only the grant and the socket
know, and each later reservation names that token and replaces what that socket held of
the buffer it names, so growing charges only the difference and shrinking always fits. A
socket the grant did not open, or a call with another token, reserves nothing. A
connection gives both of its buffers back in TIME-WAIT once its socket process is gone,
and then is none of the grant's sockets (the design's "TIME-WAIT"): the grant forgets it,
as it forgets a socket that exits, releasing whatever it still holds.

An explicit bind of the grant, a listener's or a bound datagram socket's, may claim only the
ports `bind_ports/3` gives it from the grant's `ports`, `listen` and `addresses` limits; the
bind checks the port against them (erx_net_bind:avail/2), so there is one check of a port.
The grant's other limits and its account are not built.
""".

-export([new/1, room/1, admits/2, open/4, reserve/5, release/3, exited/2, bind_ports/3]).
-export_type([sockets/0, sizes/0]).

%% The design's default `buffers` limit, 16 MiB across the grant's sockets.
-define(DEFAULT_BUFFERS, 16777216).
%% The design's default `sockets` limit.
-define(DEFAULT_SOCKETS, 1024).
%% The `ports` limit's default: FreeBSD reserves the ports below 1024 to privilege
%% (`ipport_reservedhigh`, in_pcb.c:132).
-define(DEFAULT_PORTS, [{1024, 65535}]).

-record(sockets, {sockets_limit :: non_neg_integer(),  % the most sockets open at once
                  buffers_limit :: non_neg_integer(),  % the most bytes they hold together
                  %% The sum of every size in `open`.
                  total = 0 :: non_neg_integer(),
                  %% Each open socket's token and what it holds of each buffer.
                  open = #{} :: #{term() => {reference(), sizes()}}}).

-opaque sockets() :: #sockets{}.
-type sizes() :: #{snd := non_neg_integer(), rcv := non_neg_integer()}.

-doc """
No sockets, within the `sockets` and `buffers` limits of `Limits`, 1,024 sockets and 16 MiB
when it names none; a limit that is not a non-negative integer is refused with `badarg`.
""".
-spec new(map()) -> {ok, sockets()} | {error, badarg}.
new(Limits) when is_map(Limits) ->
    Sockets = maps:get(sockets, Limits, ?DEFAULT_SOCKETS),
    Buffers = maps:get(buffers, Limits, ?DEFAULT_BUFFERS),
    case is_integer(Sockets) andalso Sockets >= 0 andalso is_integer(Buffers) andalso Buffers >= 0 of
        true -> {ok, #sockets{sockets_limit = Sockets, buffers_limit = Buffers}};
        false -> {error, badarg}
    end.

-doc "The bytes still free under the `buffers` limit.".
-spec room(sockets()) -> non_neg_integer().
room(#sockets{buffers_limit = Limit, total = Total}) ->
    Limit - Total.

-doc """
Whether a new socket whose buffers are `Sizes` would be admitted: `ok`, or `{error,
emfile}` with the `sockets` limit reached, else `{error, enobufs}` when its buffers do not
fit. open/4 decides the same; this asks before the socket is started.
""".
-spec admits(sizes(), sockets()) -> ok | {error, emfile | enobufs}.
admits(#{snd := Snd, rcv := Rcv},
       #sockets{sockets_limit = SocketsLimit, buffers_limit = BuffersLimit, total = Total, open = Open}) ->
    if
        map_size(Open) >= SocketsLimit -> {error, emfile};
        Total + Snd + Rcv > BuffersLimit -> {error, enobufs};
        true -> ok
    end.

-doc """
Opens a new socket, one of the grant's sockets from now on, with its two buffers reserved
under `Token`, which every later call for the socket must name; refused as admits/2
refuses, or with `badarg` for a socket already open, and then nothing is recorded.
""".
-spec open(term(), reference(), sizes(), sockets()) ->
          {ok, sockets()} | {error, emfile | enobufs | badarg}.
open(Socket, Token, #{snd := Snd, rcv := Rcv} = Sizes, #sockets{open = Open} = S)
  when is_reference(Token), is_integer(Snd), Snd >= 0, is_integer(Rcv), Rcv >= 0 ->
    case {is_map_key(Socket, Open), admits(Sizes, S)} of
        {true, _} -> {error, badarg};
        {false, ok} -> charge(Socket, Token, Sizes, Snd + Rcv, S);
        {false, {error, _} = Refused} -> Refused
    end.

-doc """
Sets what an open socket holds of one buffer to `Bytes`: refused with `enobufs` when the
growth does not fit, and with `badarg` unless `Token` is the one the socket opened with.
""".
-spec reserve(term(), reference(), snd | rcv, non_neg_integer(), sockets()) ->
          {ok, sockets()} | {error, enobufs | badarg}.
reserve(Socket, Token, Kind, Bytes, #sockets{open = Open} = S)
  when (Kind =:= snd orelse Kind =:= rcv), is_integer(Bytes), Bytes >= 0 ->
    case Open of
        #{Socket := {Token, #{Kind := Old} = Sizes}} ->
            charge(Socket, Token, Sizes#{Kind := Bytes}, Bytes - Old, S);
        #{} ->
            {error, badarg}
    end.

-doc """
Gives back both buffers of an open socket that needs them no more, a connection in
TIME-WAIT whose socket process is gone, and its place among the grant's sockets: the grant
forgets it, as at its exit, so its token reserves nothing more. `badarg` unless `Token` is
the one it opened with.
""".
-spec release(term(), reference(), sockets()) -> {ok, sockets()} | {error, badarg}.
release(Socket, Token, #sockets{open = Open} = S) ->
    case Open of
        #{Socket := {Token, _}} -> {ok, exited(Socket, S)};
        #{} -> {error, badarg}
    end.

-doc """
Releases both buffers of a socket that ended, as its link reports it, and forgets it; one
not open changes nothing.
""".
-spec exited(term(), sockets()) -> sockets().
exited(Socket, #sockets{total = Total, open = Open0} = S) ->
    case maps:take(Socket, Open0) of
        {{_Token, #{snd := Snd, rcv := Rcv}}, Open} ->
            S#sockets{total = Total - Snd - Rcv, open = Open};
        error -> S
    end.

-doc """
The ports an explicit bind of the grant whose limits are `Limits` may claim on the local
address `Local`, as the inclusive ranges erx_net_bind:avail/2 checks the port against: for a
bound datagram socket (`udp`) the `ports` limit, 1024 to 65535 by default; for a listener
(`tcp_listen`) the same narrowed by `listen`, which is `true` (every port of `ports`, the
default), `false`, or ranges of its own. Answers `{error, eacces}` for a listener when
`listen` is `false`, and for either when `addresses`, `all` by default, lists the IPv4
addresses the grant may bind and `Local` is not one of them; `any` is then refused too,
rather than taken as the listed addresses as a FreeBSD jail takes it, since a wildcard bind
would reach addresses the grant was not given (docs/design-network-stack.md, "The grant").
A limit of another shape, or a range in it that is not one, allows nothing, so a malformed
policy fails closed.
""".
-spec bind_ports(tcp_listen | udp, inet:ip4_address() | any, map()) ->
          {ok, erx_net_bind:ports()} | {error, eacces}.
bind_ports(Kind, Local, Limits) when (Kind =:= tcp_listen orelse Kind =:= udp), is_map(Limits) ->
    Ports = ranges(maps:get(ports, Limits, ?DEFAULT_PORTS)),
    case {address(Local, maps:get(addresses, Limits, all)), listen(Kind, Limits)} of
        {false, _} -> {error, eacces};          % an address the grant was not given
        {true, none} -> {error, eacces};        % a listener the grant may not open
        {true, all} -> {ok, Ports};
        {true, Listen} -> {ok, intersect(Ports, Listen)}
    end.

%% The ports the `listen` limit lets a bind of Kind claim: all of `ports`, its own ranges, or
%% none, for `false` or a limit of another shape.
listen(udp, _Limits) -> all;
listen(tcp_listen, Limits) ->
    case maps:get(listen, Limits, true) of
        true -> all;
        Ranges when is_list(Ranges) -> ranges(Ranges);
        _ -> none
    end.

%% Whether the `addresses` limit lets the grant bind Local.
address(_Local, all) -> true;
address(any, Addresses) when is_list(Addresses) -> false;
address(Local, Addresses) when is_list(Addresses) -> lists:member(Local, proper(Addresses));
address(_Local, _) -> false.

%% The well-formed inclusive port ranges of a limit; anything else allows nothing.
ranges(Ranges) ->
    [{Lo, Hi} || {Lo, Hi} <- proper(Ranges), is_integer(Lo), is_integer(Hi), 1 =< Lo, Lo =< Hi, Hi =< 16#ffff].

%% A limit's list, or the empty list when it is not a proper list.
proper(List) when is_list(List), length(List) >= 0 -> List;
proper(_) -> [].

%% The ports both lists of ranges hold.
intersect(A, B) ->
    [{max(L1, L2), min(H1, H2)} || {L1, H1} <- A, {L2, H2} <- B, max(L1, L2) =< min(H1, H2)].

%% A socket's new sizes, which change the total by Delta, within the `buffers` limit.
charge(Socket, Token, Sizes, Delta, #sockets{buffers_limit = Limit, total = Total, open = Open} = S) ->
    case Total + Delta =< Limit of
        true -> {ok, S#sockets{total = Total + Delta, open = Open#{Socket => {Token, Sizes}}}};
        false -> {error, enobufs}
    end.
