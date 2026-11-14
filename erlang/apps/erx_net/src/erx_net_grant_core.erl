%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_grant_core).
-moduledoc """
The grant's decisions over its sockets' buffers (docs/design-network-stack.md, "Sockets act
for one domain", the `buffers` limit of "The grant"): every byte of send and receive buffer
a socket of the grant holds is reserved here first, and the grant refuses a reservation that
would take the total past its `buffers` limit, as FreeBSD's `chgsbsize` refuses past a
user's `RLIMIT_SBSIZE` (kern_resource.c).

A socket opens with both of its buffers reserved, under a token only the grant and the
socket know, and each later reservation names that token and replaces what that socket held
of the buffer it names, so growing charges only the difference and shrinking always fits. A
socket the grant did not open, or a call with another token, reserves nothing. A socket
gives both of its buffers back when it needs them no more, and its exit releases whatever
it still holds and forgets it.

An explicit bind of the grant, a listener's or a bound datagram socket's, may claim only the
ports `bind_ports/3` gives it from the grant's `ports`, `listen` and `addresses` limits; the
bind checks the port against them (erx_net_bind:avail/2), so there is one check of a port.
The grant's other limits and its account are not built.
""".

-export([new/1, room/1, open/4, reserve/5, release/3, exited/2, bind_ports/3]).
-export_type([buffers/0, sizes/0]).

%% The design's default `buffers` limit, 16 MiB across the grant's sockets.
-define(DEFAULT_BUFFERS, 16777216).
%% The `ports` limit's default: FreeBSD reserves the ports below 1024 to privilege
%% (`ipport_reservedhigh`, in_pcb.c:132).
-define(DEFAULT_PORTS, [{1024, 65535}]).

-record(buffers, {limit :: non_neg_integer(),
                  %% The sum of every size in `held`.
                  total = 0 :: non_neg_integer(),
                  %% Each open socket's token and what it holds of each buffer.
                  held = #{} :: #{term() => {reference(), sizes()}}}).

-opaque buffers() :: #buffers{}.
-type sizes() :: #{snd := non_neg_integer(), rcv := non_neg_integer()}.

-doc "No reservations, within the `buffers` limit of `Limits`, 16 MiB when it names none.".
-spec new(map()) -> buffers().
new(Limits) when is_map(Limits) ->
    case maps:get(buffers, Limits, ?DEFAULT_BUFFERS) of
        Limit when is_integer(Limit), Limit >= 0 -> #buffers{limit = Limit}
    end.

-doc "The bytes still free under the limit.".
-spec room(buffers()) -> non_neg_integer().
room(#buffers{limit = Limit, total = Total}) ->
    Limit - Total.

-doc """
Reserves a new socket's two buffers under `Token`, which every later call for the socket
must name, or refuses with `enobufs` when they do not fit; a socket already open is a
programming error.
""".
-spec open(term(), reference(), sizes(), buffers()) -> {ok, buffers()} | {error, enobufs}.
open(Socket, Token, #{snd := Snd, rcv := Rcv} = Sizes, #buffers{held = Held} = B)
  when is_reference(Token), is_integer(Snd), Snd >= 0, is_integer(Rcv), Rcv >= 0 ->
    case is_map_key(Socket, Held) of
        true -> error(badarg);
        false -> charge(Socket, Token, Sizes, Snd + Rcv, B)
    end.

-doc """
Sets what an open socket holds of one buffer to `Bytes`: refused with `enobufs` when the
growth does not fit, and with `badarg` unless `Token` is the one the socket opened with.
""".
-spec reserve(term(), reference(), snd | rcv, non_neg_integer(), buffers()) ->
          {ok, buffers()} | {error, enobufs | badarg}.
reserve(Socket, Token, Kind, Bytes, #buffers{held = Held} = B)
  when (Kind =:= snd orelse Kind =:= rcv), is_integer(Bytes), Bytes >= 0 ->
    case Held of
        #{Socket := {Token, #{Kind := Old} = Sizes}} ->
            charge(Socket, Token, Sizes#{Kind := Bytes}, Bytes - Old, B);
        #{} ->
            {error, badarg}
    end.

-doc """
Gives back both buffers of an open socket that needs them no more, which then holds none,
`badarg` unless `Token` is the one it opened with. The socket stays open, so a later
reservation is charged afresh.
""".
-spec release(term(), reference(), buffers()) -> {ok, buffers()} | {error, badarg}.
release(Socket, Token, #buffers{held = Held} = B) ->
    case Held of
        #{Socket := {Token, #{snd := Snd, rcv := Rcv}}} ->
            charge(Socket, Token, #{snd => 0, rcv => 0}, -Snd - Rcv, B);
        #{} ->
            {error, badarg}
    end.

-doc """
Releases both buffers of a socket that ended, as its link reports it, and forgets it; one
not open changes nothing.
""".
-spec exited(term(), buffers()) -> buffers().
exited(Socket, #buffers{total = Total, held = Held0} = B) ->
    case maps:take(Socket, Held0) of
        {{_Token, #{snd := Snd, rcv := Rcv}}, Held} ->
            B#buffers{total = Total - Snd - Rcv, held = Held};
        error -> B
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

%% A socket's new sizes, which change the total by Delta, within the limit.
charge(Socket, Token, Sizes, Delta, #buffers{limit = Limit, total = Total, held = Held} = B) ->
    case Total + Delta =< Limit of
        true -> {ok, B#buffers{total = Total + Delta, held = Held#{Socket => {Token, Sizes}}}};
        false -> {error, enobufs}
    end.
