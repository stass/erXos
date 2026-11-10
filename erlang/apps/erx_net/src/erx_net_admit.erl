%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_admit).
-moduledoc """
The check of what a socket takes from its socket process (docs/design-network-stack.md,
"The socket process", "Untrusted input"), the network domain's side of the socket
protocol, as far as a TCP connection needs it. The client domain is untrusted: each
message is taken as it came and answered as the request the socket may act on, or left
out.

request/3 takes a message the socket received, for its socket process `SockProc`, whose
grantee's messages arrive by `Origin`: bare when the grantee is `local`, the socket's own
domain, or as `{erx_origin, D, Msg}` with `D` the grantee's domain id. `Msg` must be
`{erx_net, SockProc, Body}` from that very socket process; anything else, an envelope of
another domain included, is `unknown`, for the socket to drop and count, and no reply
goes to a party that is not its socket process. `Body` must be one of the protocol's
requests: `{credit, Bytes}` with `Bytes` from 1 to 64 MiB, or `{call, N, Request}` with
`N` a request count and `Request` one of `{send, Piece}` (a binary of at most 64 KiB),
`{shutdown, How}`, `close`, `{setopts, [{nodelay, Boolean}]}`, `{getopts, [nodelay]}`,
`sockname` or `peername`. A body of any other shape is refused (`shape`).

The operation schema's generator will produce this module's checks from
`abi/services/net.txt`; until it exists they are written here with its signatures.
""".

-export([request/3]).

-export_type([origin/0, request/0]).

-define(PIECE, 65536).
%% stock's TCP_MAX_PACKET_SIZE: the most credit a socket process grants at once.
-define(MAX_CREDIT, 67108864).

-doc "How the grantee's messages arrive: bare (`local`) or in an envelope naming its domain.".
-type origin() :: local | pos_integer().

-doc "A socket protocol request, as request/3 admits it.".
-type request() :: {credit, pos_integer()}
                 | {call, non_neg_integer(),
                    {send, binary()} | {shutdown, read | write | read_write} | close
                    | {setopts, [{nodelay, boolean()}]} | {getopts, [nodelay]} | sockname | peername}.

-doc """
Takes `Message`, received by a socket whose socket process is `SockProc` (`none` once it
has none) and whose grantee's messages arrive by `Origin`.
""".
-spec request(origin(), pid() | none, term()) -> {ok, request()} | unknown | {refused, shape}.
request(local, SockProc, {erx_net, SockProc, Body}) when is_pid(SockProc) ->
    body(Body);
request(Origin, SockProc, {erx_origin, D, {erx_net, SockProc, Body}})
  when Origin =/= local, D =:= Origin, is_pid(SockProc) ->
    body(Body);
request(_Origin, _SockProc, _Message) ->
    unknown.

body({credit, Bytes}) when is_integer(Bytes), Bytes > 0, Bytes =< ?MAX_CREDIT ->
    {ok, {credit, Bytes}};
body({call, N, Request}) when is_integer(N), N >= 0 ->
    case call(Request) of
        true -> {ok, {call, N, Request}};
        false -> {refused, shape}
    end;
body(_) ->
    {refused, shape}.

call({send, Piece}) -> is_binary(Piece) andalso byte_size(Piece) =< ?PIECE;
call({shutdown, How}) -> How =:= read orelse How =:= write orelse How =:= read_write;
call(close) -> true;
call({setopts, []}) -> true;
call({setopts, [{nodelay, B}]}) -> is_boolean(B);
call({getopts, []}) -> true;
call({getopts, [nodelay]}) -> true;
call(sockname) -> true;
call(peername) -> true;
call(_) -> false.
