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
it still holds and forgets it. The grant's other limits and its account are not built.
""".

-export([new/1, room/1, open/4, reserve/5, release/3, exited/2]).
-export_type([buffers/0, sizes/0]).

%% The design's default `buffers` limit, 16 MiB across the grant's sockets.
-define(DEFAULT_BUFFERS, 16777216).

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

%% A socket's new sizes, which change the total by Delta, within the limit.
charge(Socket, Token, Sizes, Delta, #buffers{limit = Limit, total = Total, held = Held} = B) ->
    case Total + Delta =< Limit of
        true -> {ok, B#buffers{total = Total + Delta, held = Held#{Socket => {Token, Sizes}}}};
        false -> {error, enobufs}
    end.
