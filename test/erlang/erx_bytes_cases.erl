%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The Erlang side of the differential test of test/host/erx_net_bytes_test.rb: answers the
%% cases of test/fixtures/erx_bytes_cases.c's format with the models of the host stand-in,
%% test/erlang/host_bytes/erx_bytes.erl, one decimal answer a line. The pieces of a case
%% become an iolist, nested so that the models see deep lists as well as flat ones.

-module(erx_bytes_cases).
-export([answer/1]).

-spec answer(file:filename()) -> ok.
answer(Path) ->
    {ok, Text} = file:read_file(Path),
    Lines = [Line || Line <- binary:split(Text, <<"\n">>, [global]), Line =/= <<>>],
    lists:foreach(fun(Line) -> io:format("~B~n", [answer_line(binary:split(Line, <<" ">>, [global]))]) end,
                  Lines).

answer_line([<<"sum">>, Start | Pieces]) ->
    erx_bytes:inet_csum(binary_to_integer(Start, 16), nest(bytes_of(Pieces)));
answer_line([<<"update">>, Checksum, Before, After]) ->
    erx_bytes:inet_csum_update(binary_to_integer(Checksum, 16), bytes(Before), bytes(After));
answer_line([<<"sip">>, Key | Pieces]) ->
    erx_bytes:siphash24(bytes(Key), nest(bytes_of(Pieces))).

bytes_of(Pieces) -> [bytes(Piece) || Piece <- Pieces].

bytes(<<"-">>) -> <<>>;
bytes(Hex) -> binary:decode_hex(Hex).

%% The pieces as a nested iolist: [A, B, C, D] becomes [[A], [B, [C], [D]]].
nest([]) -> [];
nest([Piece]) -> [Piece];
nest([First, Second | Rest]) -> [[First], [Second | nest(Rest)]].
