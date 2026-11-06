%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random completions through erx_blk_request:decode/2, the block driver's parse of what a
%% device wrote, and random requests through its checks. Whatever arrives, decode/2
%% returns ok, {ok, Data} or {error, Reason} with Reason one of the fixed shapes, and agrees
%% with reference/2, which judges the bytes by their size and last byte alone; range/3 and
%% erx_blk_write:write_segments/3 agree with a reference of plain comparisons. Sizes cluster at
%% the boundaries (empty, one short, exact, one long), so every path is common. The seed
%% comes from make check-fuzz.

-module(erx_blk_request_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(SECTOR, 512).
%% The fewest rounds that must decode a good completion, so an edit to the generator
%% cannot leave the accepting path untried.
-define(MIN_ACCEPTED, ?ROUNDS div 20).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of() =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of() ->
    check_range(),
    Request = case rand:uniform(2) of
                  1 -> {read, rand:uniform(erx_blk_request:max_sectors())};
                  2 -> write
              end,
    Bytes = bytes(expected_size(Request)),
    Said = erx_blk_request:decode(Request, Bytes),
    shape(Said),
    case Said =:= reference(Request, Bytes) of
        true when Said =:= ok -> accepted;
        true when element(1, Said) =:= ok -> accepted;
        true -> refused;
        false -> error({disagrees_with_reference, Request, Bytes, Said})
    end.

expected_size({read, Count}) -> Count * ?SECTOR + 1;
expected_size(write) -> 1.

%% A size near the expected one, or anywhere up to a buffer; the last byte a status the
%% specification names or any other.
bytes(Expected) ->
    Size = case rand:uniform(6) of
               1 -> 0;
               2 -> max(0, Expected - 1);
               3 -> Expected + 1;
               4 -> rand:uniform(erx_blk_request:buffer_size() + 1) - 1;
               _ -> Expected
           end,
    Status = case rand:uniform(4) of
                 1 -> rand:uniform(256) - 1;
                 2 -> rand:uniform(3) - 1;
                 _ -> 0
             end,
    case Size of
        0 -> <<>>;
        _ -> <<(rand:bytes(Size - 1))/binary, Status>>
    end.

shape(ok) -> ok;
shape({ok, Data}) when is_binary(Data) -> ok;
shape({error, ioerr}) -> ok;
shape({error, unsupp}) -> ok;
shape({error, {status, N}}) when is_integer(N), N >= 3, N =< 255 -> ok;
shape({error, {length, N}}) when is_integer(N), N >= 0 -> ok.

reference(Request, Bytes) ->
    Size = byte_size(Bytes),
    case Size =:= expected_size(Request) of
        false ->
            {error, {length, Size}};
        true ->
            case binary:last(Bytes) of
                0 when Request =:= write -> ok;
                0 -> {ok, binary:part(Bytes, 0, Size - 1)};
                1 -> {error, ioerr};
                2 -> {error, unsupp};
                N -> {error, {status, N}}
            end
    end.

%% A request's checks against plain comparisons, for reads and the one write path alike.
check_range() ->
    Capacity = rand:uniform(64) - 1,
    Sector = rand:uniform(Capacity + 4) - 3,
    Count = rand:uniform(erx_blk_request:max_sectors() + 2) - 2,
    Max = erx_blk_request:max_sectors(),
    Expected = if
                   Count < 1; Count > Max -> {error, bad_count};
                   Sector < 0; Sector + Count > Capacity -> {error, out_of_range};
                   true -> ok
               end,
    case erx_blk_request:range(Sector, Count, Capacity) of
        Expected -> ok;
        Other -> error({range_disagrees, Sector, Count, Capacity, Other})
    end,
    Data = binary:copy(<<0>>, max(0, Count) * ?SECTOR),
    case {erx_blk_write:write_segments(Sector, Data, Capacity), Expected} of
        {{ok, _}, ok} -> ok;
        {Same, Same} -> ok;
        {{error, bad_count}, {error, bad_count}} -> ok;
        Mismatch -> error({write_segments_disagree, Sector, Count, Capacity, Mismatch})
    end.
