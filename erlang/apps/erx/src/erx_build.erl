%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_build).
-moduledoc """
The boot image's build identifier, the pack header's `build_id`
(abi/erx_abi.txt, `erx_pack_header`), as the system domain's init
receives it: liberx's runtime entry adds `-erx build ID`, the identifier's
bytes read big-endian as one number in decimal, since init parses each
`-erx` value as a term and hexadecimal digits need not scan as one.

It is answered in lower-case hexadecimal, two digits per byte, as the
root's identity line, the host link's hello and `uname -b` show it. A
runtime whose init was given no `-erx build`, such as a hosted one or
another domain's, has `{error, {no_build, _}}`, which its callers report
as unknown.
""".

-include("generated/erx_abi.hrl").

-export([id/0, id/1]).

%% The build identifier's bits: the pack header's build_id, the bytes from its
%% offset to the next field's.
-define(BITS, (8 * (?ERX_PACK_HEADER_OFF_INDEX_HASH - ?ERX_PACK_HEADER_OFF_BUILD_ID))).

-doc "The build identifier among this runtime's init `-erx` arguments.".
-spec id() -> {ok, binary()} | {error, {atom(), string()}}.
id() ->
    case init:get_argument(erx) of
        {ok, Arguments} -> id(Arguments);
        error -> id([])
    end.

-doc "The build identifier among `-erx` arguments as init:get_argument(erx) returns them. Pure, for its tests.".
-spec id([[string()]]) -> {ok, binary()} | {error, {atom(), string()}}.
id(Arguments) ->
    case [Word || ["build", Word | _] <- Arguments] of
        [Word] ->
            case decimal(Word, ?BITS) of
                {ok, Id} -> {ok, iolist_to_binary(io_lib:format("~*.16.0b", [?BITS div 4, Id]))};
                error -> {error, {bad_build, "-erx build is not the build identifier in decimal"}}
            end;
        [] ->
            {error, {no_build, "the root gave no -erx build"}};
        [_, _ | _] ->
            {error, {bad_build, "more than one -erx build"}}
    end.

%% Digits only, at most as many as the field's largest value has, so no word
%% builds a large integer before the range check.
decimal(Word, Bits) ->
    Max = (1 bsl Bits) - 1,
    case Word =/= [] andalso length(Word) =< length(integer_to_list(Max))
        andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Word) of
        true ->
            case list_to_integer(Word) of
                Value when Value =< Max -> {ok, Value};
                _ -> error
            end;
        false ->
            error
    end.
