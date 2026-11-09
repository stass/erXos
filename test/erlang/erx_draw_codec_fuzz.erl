%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% The fuzz target of erx_draw_codec:decode/2 and of erx_draw_image:decode/3,
%% which it calls for a `Y` (docs/design-display.md, "Draw messages"). Each
%% round decodes, message by message, a case of erx_draw_codec_tests's
%% corpus (random messages of every letter and compressed payloads, a third
%% of them broken) or random bytes, with the depths the case's first 8
%% bytes give. Every decode must return a message of a declared name that
%% consumed at least its letter, whose pixels fill its rectangle exactly
%% and which re-encodes to a message that decodes to itself; or einval or
%% enoent at an offset within the bytes; and never raise.
-module(erx_draw_codec_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).

run([Seed]) ->
    rand:seed(exsss, {list_to_integer(Seed), 23, 29}),
    try
        lists:foreach(fun(_) -> round() end, lists:seq(1, ?ROUNDS)),
        io:format("fuzz: ~b rounds ok~n", [?ROUNDS])
    catch
        Class:Reason:Stack ->
            io:format("fuzz failed: ~p:~P~n~P~n", [Class, Reason, 40, Stack, 20]),
            halt(1)
    end.

round() ->
    Case = case rand:uniform(4) of
               1 -> rand:bytes(8 + rand:uniform(64));
               _ -> erx_draw_codec_tests:corpus_case()
           end,
    <<Depths:8/binary, Messages/binary>> = Case,
    walk(Messages, erx_draw_codec_tests:depth_fun(Depths)).

walk(<<>>, _) -> ok;
walk(Bytes, Depth) ->
    case erx_draw_codec:decode(Bytes, Depth) of
        {ok, Message, Rest} when byte_size(Rest) < byte_size(Bytes) ->
            check(Message, Depth),
            walk(Rest, Depth);
        {error, Errno, Offset} when (Errno =:= einval orelse Errno =:= enoent), Offset =< byte_size(Bytes) ->
            ok
    end.

check(Message, Depth) ->
    Name = case Message of _ when is_atom(Message) -> Message; _ -> element(1, Message) end,
    {Name, _} = erx_draw_codec:layout(erx_draw_codec:letter(Name)),
    case Message of
        {Load, Id, {_, Y0, _, Y1} = R, Pixels} when Load =:= load; Load =:= cload ->
            Size = erx_draw_image:bytes_per_line(R, Depth(Id)) * (Y1 - Y0),
            Size = byte_size(Pixels);
        _ -> ok
    end,
    {ok, Message, <<>>} = erx_draw_codec:decode(erx_draw_codec:encode(Message), Depth).
