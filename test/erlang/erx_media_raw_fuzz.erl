%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of a raw file's request check, erx_media_raw:plan/3
%% (docs/design-drives.md, "Raw sectors" and "Fuzz targets"). A client's read or write
%% of a raw file, its offset and its count or bytes, is untrusted; the file's placement
%% comes from the table and the piece size from the window's info. A round draws a
%% placement (a volume at some first sector, or a medium of up to 2^40 sectors from 0),
%% a piece size of 1 to 128 sectors and a request: offsets and counts near the file's
%% end, at sector multiples and off them, up to past the file protocol's p9_io_max, and
%% offsets near 2^64. Whatever it is, plan/3 never raises and makes no atom, and it
%% answers exactly what an independent model of the rules answers: einval for an offset
%% or count that is not a multiple of 512, a count past p9_io_max or a write that ends
%% past the file; otherwise the sectors the request covers, a read cut at the file's
%% end. Every piece it answers carries 1 to Piece sectors, lies inside the placement,
%% follows the one before it, and a write's pieces carry the client's bytes in order.
%% The seed comes from make check-fuzz.

-module(erx_media_raw_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(ROUNDS, 20000).
-define(MIN_ACCEPTED, ?ROUNDS div 4).
-define(SECTOR, 512).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    Accepted = lists:sum([round_of() || _ <- lists:seq(1, ?ROUNDS)]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of() ->
    Volume = placement(),
    Piece = rand:uniform(128),
    Request = request(Volume),
    Atoms = erlang:system_info(atom_count),
    Answer = try
                 erx_media_raw:plan(Request, Volume, Piece)
             catch
                 Class:Reason:Stack -> error({raised, Class, Reason, Stack})
             end,
    Atoms =:= erlang:system_info(atom_count) orelse error({made_an_atom, Answer}),
    check(Answer, Request, Volume, Piece).

placement() ->
    case rand:uniform(3) of
        1 -> #{first => 0, length => rand:uniform(1 bsl 40)};
        _ -> #{first => rand:uniform(1 bsl 32), length => rand:uniform(4096) - 1}
    end.

request(#{length := Length}) ->
    Offset = offset(Length),
    case rand:uniform(2) of
        1 -> {read, Offset, count()};
        2 -> {write, Offset, bytes(count())}
    end.

%% An offset near the file's start, its end or 2^64, a sector multiple in most rounds.
offset(Length) ->
    Base = case rand:uniform(5) of
               1 -> 0;
               2 -> max(0, Length - rand:uniform(256)) * ?SECTOR;
               3 -> Length * ?SECTOR;
               4 -> (1 bsl 64) - rand:uniform(4) * ?SECTOR;
               5 -> rand:uniform(max(1, Length)) * ?SECTOR
           end,
    Base + skew().

%% A count up to past p9_io_max, a sector multiple in most rounds.
count() ->
    case rand:uniform(8) of
        1 -> ?ERX_P9_IO_MAX + ?SECTOR * (rand:uniform(4) - 1);
        _ -> ?SECTOR * (rand:uniform(?ERX_P9_IO_MAX div ?SECTOR + 1) - 1) + skew()
    end.

skew() ->
    case rand:uniform(8) of
        1 -> rand:uniform(?SECTOR - 1);
        _ -> 0
    end.

%% Bytes whose every sector is told apart from the others, so a piece carrying the
%% wrong sector shows.
bytes(Count) ->
    Whole = << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, min(Count, 64)) >>,
    binary:part(binary:copy(Whole, Count div max(1, byte_size(Whole)) + 1), 0, Count).

%% The model: what plan/3 must answer for Request on Volume.
model({Kind, Offset, CountOrBytes}, #{length := Length}) ->
    Count = case Kind of read -> CountOrBytes; write -> byte_size(CountOrBytes) end,
    First = Offset div ?SECTOR,
    if
        Offset rem ?SECTOR =/= 0; Count rem ?SECTOR =/= 0; Count > ?ERX_P9_IO_MAX -> einval;
        Kind =:= write, Offset + Count > Length * ?SECTOR -> einval;
        Kind =:= read -> {First, max(0, min(Count div ?SECTOR, Length - First))};
        Kind =:= write -> {First, Count div ?SECTOR}
    end.

check(Answer, Request, Volume, Piece) ->
    case {model(Request, Volume), Answer} of
        {einval, {error, einval}} -> 0;
        {{First, Sectors}, {ok, Pieces}} -> pieces(Pieces, Request, Volume, Piece, First, Sectors), 1;
        {Expected, _} -> error({wrong_answer, Request, Volume, Piece, Expected, Answer})
    end.

pieces(Pieces, {Kind, _Offset, CountOrBytes} = Request, #{first := Base, length := Length}, Piece, First, Sectors) ->
    Spans = [span(P) || P <- Pieces],
    [error({piece_too_large, Request, Piece, N}) || {_, N} <- Spans, N < 1 orelse N > Piece],
    [error({served_outside, Request, Lba, N}) || {Lba, N} <- Spans, Lba < Base orelse Lba + N > Base + Length],
    Covered = lists:sum([N || {_, N} <- Spans]),
    Covered =:= Sectors orelse error({wrong_answer, Request, Covered, Sectors}),
    Starts = [Lba || {Lba, _} <- Spans],
    {Expected, _End} = lists:mapfoldl(fun({_, N}, At) -> {At, At + N} end, Base + First, Spans),
    Starts =:= Expected orelse error({out_of_order, Request, Starts}),
    Kind =:= read orelse [error({wrong_kind, Request}) || P <- Pieces, element(1, P) =/= write],
    Kind =:= write orelse [error({wrong_kind, Request}) || P <- Pieces, element(1, P) =/= read],
    Kind =:= read orelse iolist_to_binary([B || {write, _, B} <- Pieces]) =:= CountOrBytes
        orelse error({wrong_bytes, Request}),
    ok.

span({read, Lba, N}) -> {Lba, N};
span({write, Lba, Bytes}) -> {Lba, byte_size(Bytes) div ?SECTOR}.
