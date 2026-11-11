%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gen_icmp).
-moduledoc """
The ICMP echo socket's client (docs/design-network-stack.md, "Scope", the raw ICMP
socket for `ping`): what ping(8) asks of its raw socket, through the domain's grant.
open/0 asks the grant for an echo socket (`icmp_open`) through erx_inet:call/1, owned by
the caller; send/4, recv/2 and close/1 call that socket. Every reply passes
erx_sock_admit:result/2 before the caller sees it, so nothing the network domain chose
reaches program code. A socket that has ended, however it ended, answers as a closed
socket does, `{error, closed}`, and closing it again is `ok`.
""".

-export([open/0, send/4, recv/2, close/1]).

-export_type([socket/0, reply/0]).

-type socket() :: pid().
-type reply() :: {inet:ip4_address(), Ttl :: 0..255, Seq :: 0..16#ffff, Data :: binary()}.

-doc "Opens an echo socket for the calling process, which it ends with.".
-spec open() -> {ok, socket()} | {error, term()}.
open() ->
    erx_inet:call({icmp_open, inet}).

-doc """
Sends an echo request with sequence number `Seq` and `Data` to `Ip`, with the TTL `ttl`
(the path's when absent).
""".
-spec send(socket(), inet:ip4_address(), 0..16#ffff, #{data := iodata(), ttl => 1..255}) ->
          ok | {error, term()}.
send(Sock, {_, _, _, _} = Ip, Seq, #{data := Data} = Opts) when is_integer(Seq), Seq >= 0, Seq =< 16#ffff ->
    call(Sock, echo_send, {send, addr(Ip), Seq, (maps:with([ttl], Opts))#{data => iolist_to_binary(Data)}}).

-doc """
Takes the next echo reply that carries the socket's identifier, waiting at most `Timeout`
milliseconds: its sender, TTL, sequence number and data.
""".
-spec recv(socket(), timeout()) -> {ok, reply()} | {error, term()}.
recv(Sock, Timeout) when Timeout =:= infinity; is_integer(Timeout), Timeout >= 0 ->
    call(Sock, echo_recv, {recv, Timeout}).

-doc "Closes the socket, giving up its identifier.".
-spec close(socket()) -> ok.
close(Sock) ->
    case call(Sock, echo_close, close) of
        ok -> ok;
        {error, _} -> ok
    end.

%% One call of the socket, its reply admitted. Only the call is guarded, so a socket that
%% ends answers as a closed socket and no crash of the check is mistaken for one.
call(Sock, Kind, Request) when is_pid(Sock) ->
    try gen_server:call(Sock, Request, infinity) of
        Reply ->
            case erx_sock_admit:result(Kind, Reply) of
                {ok, Checked} -> Checked;
                {refused, _} -> {error, badarg}
            end
    catch
        exit:_ -> {error, closed}
    end.

addr({A, B, C, D}) -> <<A, B, C, D>>.
