%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_build).
-moduledoc """
What this runtime knows of the boot image's build: its identifier and the
facts of its build that `uname -v` shows.

The build identifier is the pack header's `build_id` (abi/erx_abi.txt,
`erx_pack_header`), as the system domain's init receives it: liberx's
runtime entry adds `-erx build ID`, the identifier's bytes read big-endian
as one number in decimal, since init parses each `-erx` value as a term
and hexadecimal digits need not scan as one. It is answered in lower-case
hexadecimal, two digits per byte, as the root's identity line, the host
link's hello and `uname -b` show it. A runtime whose init was given no
`-erx build`, such as a hosted one or another domain's, has
`{error, {no_build, _}}`, which its callers report as unknown.

The build facts are the file the image build writes into the system
release at abi/erx_abi.txt's `build_facts_path`
(tools/lib/erx/build_facts.rb): one `name value` line per fact, in a fixed
order, for the source revision, its commit's time in seconds since the
epoch (UTC), the configuration (the platform and the build kind, as
`qemu-virt/development`) and the packed kernel's name and revision. A value
is `unknown` where the build could not determine it. The file is a build
artifact, so it is parsed with every bound checked, and each value may hold
only the printable characters its field allows. A runtime whose release
has no such file, a hosted one or another domain's, has
`{error, {no_facts, _}}`, and one whose file does not parse
`{error, {bad_facts, _}}`; its callers report every fact as unknown.
""".

-include("generated/erx_abi.hrl").

-export([id/0, id/1]).
-export([facts/0, parse_facts/1]).

-export_type([facts/0]).

-doc "The facts of the build, each `unknown` where the build could not determine it.".
-type facts() :: #{revision := binary() | unknown,
                   date := non_neg_integer() | unknown,
                   configuration := binary() | unknown,
                   kernel := binary() | unknown}.

%% The build identifier's bits: the pack header's build_id, the bytes from its
%% offset to the next field's.
-define(BITS, (8 * (?ERX_PACK_HEADER_OFF_INDEX_HASH - ?ERX_PACK_HEADER_OFF_BUILD_ID))).

%% The facts in the file's order, and the most bytes the file may hold: more
%% than the four lines' names, spaces, longest values and newlines.
-define(FACTS, [revision, date, configuration, kernel]).
-define(FACTS_MAX, 512).

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

-doc "The build facts in this runtime's release.".
-spec facts() -> {ok, facts()} | {error, {atom(), string()}}.
facts() ->
    %% The path's system/ prefix names the system release, which the release
    %% file system serves at the runtime's root (docs/design-runtime.md).
    <<"system/", Path/binary>> = ?ERX_BUILD_FACTS_PATH_BYTES,
    case file:open(filename:join(code:root_dir(), Path), [read, raw, binary]) of
        {ok, Device} ->
            Read = read_bounded(Device, <<>>),
            _ = file:close(Device),
            case Read of
                {ok, Bytes} -> parse_facts(Bytes);
                {error, _} -> {error, {bad_facts, "the build facts cannot be read"}}
            end;
        {error, _} ->
            {error, {no_facts, "the release has no build facts"}}
    end.

%% The file's bytes up to one past the bound, so a longer file is refused,
%% not cut short, however few bytes each read returns.
read_bounded(_Device, Read) when byte_size(Read) > ?FACTS_MAX ->
    {ok, Read};
read_bounded(Device, Read) ->
    case file:read(Device, ?FACTS_MAX + 1 - byte_size(Read)) of
        {ok, Bytes} -> read_bounded(Device, <<Read/binary, Bytes/binary>>);
        eof -> {ok, Read};
        {error, _} = Error -> Error
    end.

-doc """
The build facts a file's bytes hold. Pure, for its tests. The file must be
exactly one `name value` line for each fact, in order, each ending in a
newline, with each value `unknown` or of its field's shape; anything else
is refused whole, so no fact is taken from a file that is wrong anywhere.
""".
-spec parse_facts(binary()) -> {ok, facts()} | {error, {bad_facts, string()}}.
parse_facts(Bytes) when byte_size(Bytes) > ?FACTS_MAX ->
    {error, {bad_facts, "the build facts are longer than any the build writes"}};
parse_facts(Bytes) ->
    case binary:split(Bytes, <<"\n">>, [global]) of
        Lines when length(Lines) =:= length(?FACTS) + 1 ->
            case lists:split(length(?FACTS), Lines) of
                {Facts, [<<>>]} -> lines(lists:zip(?FACTS, Facts), #{});
                {_, [_]} -> {error, {bad_facts, "the build facts do not end in a newline"}}
            end;
        _ ->
            {error, {bad_facts, "the build facts are not one line for each fact"}}
    end.

lines([], Facts) ->
    {ok, Facts};
lines([{Name, Line} | Rest], Facts) ->
    Prefix = <<(atom_to_binary(Name))/binary, " ">>,
    Size = byte_size(Prefix),
    case Line of
        <<Prefix:Size/binary, Value/binary>> ->
            case fact(Name, Value) of
                {ok, Fact} -> lines(Rest, Facts#{Name => Fact});
                error -> {error, {bad_facts, "the build fact " ++ atom_to_list(Name) ++ " is malformed"}}
            end;
        _ ->
            {error, {bad_facts, "the build facts do not give " ++ atom_to_list(Name) ++ " in its place"}}
    end.

%% A value of its field's shape, the same as tools/lib/erx/build_facts.rb's
%% SHAPES: printable ASCII with no space, of bounded length.
fact(_Name, <<"unknown">>) ->
    {ok, unknown};
fact(revision, Value) ->
    shaped(Value, 160, fun alnum/1, fun(C) -> alnum(C) orelse lists:member(C, "._+/-") end);
fact(date, Value) ->
    case shaped(Value, 12, fun digit/1, fun digit/1) of
        {ok, Digits} -> {ok, binary_to_integer(Digits)};
        error -> error
    end;
fact(configuration, Value) ->
    Name = fun(C) -> lower(C) orelse digit(C) orelse C =:= $- end,
    case binary:split(Value, <<"/">>) of
        [Platform, Kind] ->
            case {shaped(Platform, 64, fun(C) -> lower(C) orelse digit(C) end, Name),
                  shaped(Kind, 32, fun lower/1, Name)} of
                {{ok, _}, {ok, _}} -> {ok, Value};
                _ -> error
            end;
        [_] ->
            error
    end;
fact(kernel, Value) ->
    Lower = fun(C) -> lower(C) orelse digit(C) end,
    shaped(Value, 64, Lower, fun(C) -> Lower(C) orelse C =:= $. orelse C =:= $- end).

%% Value when it is one to Max bytes, its first byte passes First and every
%% other passes Rest.
shaped(<<C, Tail/binary>> = Value, Max, First, Rest) when byte_size(Value) =< Max ->
    case First(C) andalso lists:all(Rest, binary_to_list(Tail)) of
        true -> {ok, Value};
        false -> error
    end;
shaped(_Value, _Max, _First, _Rest) ->
    error.

alnum(C) -> upper(C) orelse lower(C) orelse digit(C).
upper(C) -> C >= $A andalso C =< $Z.
lower(C) -> C >= $a andalso C =< $z.
digit(C) -> C >= $0 andalso C =< $9.
