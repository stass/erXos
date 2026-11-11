%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gen_icmp).
-moduledoc """
The ICMP echo socket's backend (docs/design-network-stack.md, "Scope", the raw ICMP
socket for `ping`): what ping(8) asks of its raw socket, through the domain's grant. A
socket is its socket process, erx_gen_udp's of kind `icmp`, in the caller's domain, so the
echo socket speaks the socket protocol as a datagram socket does: open/0 starts the
socket process, owned by the caller, which asks the grant for an echo socket
(`icmp_open`); send/4, recv/2 and close/1 are local calls of it. Every reply and echo
reply passes erx_sock_admit before the socket process acts on it, so nothing the network
domain chose reaches program code unchecked. A socket that has ended, however it ended,
answers as a closed socket does, `{error, closed}`, and closing it again is `ok`.
""".

-export([open/0, send/4, recv/2, close/1]).

-export_type([socket/0, reply/0]).

-type socket() :: pid().
-type reply() :: {inet:ip4_address(), Ttl :: 0..255, Seq :: 0..16#ffff, Data :: binary()}.

-doc "Opens an echo socket for the calling process, which it ends with.".
-spec open() -> {ok, socket()} | {error, term()}.
open() ->
    erx_gen_udp:start(icmp, {{icmp_open, inet}, #{mode => binary, active => false}}).

-doc """
Sends an echo request with sequence number `Seq` and `Data` to `Ip`, with the TTL `ttl`
(the path's when absent).
""".
-spec send(socket(), inet:ip4_address(), 0..16#ffff, #{data := iodata(), ttl => 1..255}) ->
          ok | {error, term()}.
send(Sock, {_, _, _, _} = Ip, Seq, #{data := Data} = Opts) when is_integer(Seq), Seq >= 0, Seq =< 16#ffff ->
    erx_gen_udp:call(Sock, {echo_send, Ip, Seq, maps:get(ttl, Opts, default), iolist_to_binary(Data)}).

-doc """
Takes the next echo reply that carries the socket's identifier, waiting at most `Timeout`
milliseconds: its sender, TTL, sequence number and data.
""".
-spec recv(socket(), timeout()) -> {ok, reply()} | {error, term()}.
recv(Sock, Timeout) when Timeout =:= infinity; is_integer(Timeout), Timeout >= 0 ->
    erx_gen_udp:call(Sock, {recv, Timeout}).

-doc "Closes the socket, giving up its identifier.".
-spec close(socket()) -> ok.
close(Sock) ->
    case erx_gen_udp:call(Sock, close) of
        ok -> ok;
        {error, _} -> ok
    end.
