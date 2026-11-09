%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random texts and links through erx_present:parse/2 and erx_present:parse_uri/1,
%% the readers of the untrusted text a terminal's link, a browser's address and a
%% command's argument hand the system. Whatever arrives, each answers a value or error
%% and makes no atom. Half the inputs are values' texts and links, written by text/1 and
%% uri/2 here, writers that share no code with the module, and each must read back as
%% its value; the other half are those inputs mutated and random bytes. Every input that
%% is read must be what the writers here write for its value, so each value has exactly
%% one spelling. The seed comes from make check-fuzz.

-module(erx_present_fuzz).
-export([run/1]).

-define(ROUNDS, 100000).
-define(MIN_ACCEPTED, ?ROUNDS div 10).
-define(PLAIN, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+,:=@-").

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Pids = [self() | [spawn(fun() -> receive stop -> ok end end) || _ <- lists:seq(1, 3)]],
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(input(Pids)) =:= accepted]),
    [Pid ! stop || Pid <- tl(Pids)],
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

%% The atom count is read around the call alone, since the round's own helpers load code.
round_of({Reader, Input, Expected}) ->
    Atoms = erlang:system_info(atom_count),
    Said = read(Reader, Input),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Input}),
    case {Said, Expected} of
        {{ok, Type, Value}, _} when Expected =:= none; Expected =:= {Type, Value} ->
            written(Reader, Type, Value) =:= Input orelse error({second_spelling, Input, Value}),
            accepted;
        {error, none} ->
            refused;
        {Said, _} ->
            error({disagrees_with_reference, Input, Expected, Said})
    end.

read({text, Type}, Text) ->
    case erx_present:parse(Type, Text) of
        {ok, Value} -> {ok, Type, Value};
        error -> error
    end;
read(link, Link) ->
    erx_present:parse_uri(Link).

written({text, Type}, Type, Value) -> text(Value);
written(link, Type, Value) -> uri(Type, text(Value)).

%% {Reader, Input, {Type, Value}} for a written value, {Reader, Input, none} for
%% anything else.
input(Pids) ->
    {Type, Pattern} = pick(erx_present:marks()),
    Segments = [segment(descriptor(Variable), Pids) || {variable, Variable} <- Pattern],
    Value = case Segments of [One] -> One; _ -> list_to_tuple(Segments) end,
    Text = text(Value),
    {Reader, Written} = case rand:uniform(2) of
                            1 -> {{text, Type}, Text};
                            2 -> {link, uri(Type, Text)}
                        end,
    case rand:uniform(4) of
        1 -> {Reader, Written, {Type, Value}};
        2 -> {Reader, mutate(Written), none};
        3 -> {Reader, mutate(mutate(Written)), none};
        4 -> {Reader, noise(), none}
    end.

descriptor({type, Name}) ->
    {ok, Descriptor} = erx_schema:type(Name),
    Descriptor;
descriptor(Descriptor) ->
    Descriptor.

segment({integer, Minimum, Maximum, _Multiple}, _Pids) ->
    pick([Minimum, Maximum, Minimum + rand:uniform(Maximum - Minimum + 1) - 1, Minimum + 1]);
segment({text, Maximum, Encoding}, _Pids) ->
    Length = pick([1, 2, rand:uniform(Maximum), Maximum]),
    case Encoding of
        bytes -> << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, Length) >>;
        utf8 -> utf8(Length)
    end;
segment(pid, Pids) ->
    pick(Pids).

%% Valid UTF-8 of at most Length bytes and at least one character.
utf8(Length) ->
    Characters = [pick([rand:uniform(127), 16#e9, 16#2f, 16#2e, 16#25, 16#20ac, 16#1f600])
                  || _ <- lists:seq(1, max(1, Length div 4))],
    unicode:characters_to_binary(Characters).

%% The canonical text of a value: its segments joined by "/", a pid as D.N.S, an
%% integer in decimal and a text with every byte outside PLAIN as %XX.
text(Value) when is_tuple(Value) -> iolist_to_binary(lists:join("/", [text(Item) || Item <- tuple_to_list(Value)]));
text(Value) when is_integer(Value) -> integer_to_binary(Value);
text(Value) when is_pid(Value) -> list_to_binary(string:trim(pid_to_list(Value), both, "<>"));
text(Value) when is_binary(Value) -> iolist_to_binary([escape(Byte, ?PLAIN) || <<Byte>> <= Value]).

uri(Type, Text) ->
    iolist_to_binary(["erx:", atom_to_list(Type), "/", [escape(Byte, ?PLAIN ++ "./") || <<Byte>> <= Text]]).

escape(Byte, Kept) ->
    case lists:member(Byte, Kept) of
        true -> Byte;
        false -> io_lib:format("%~2.16.0B", [Byte])
    end.

%% A second spelling is the likeliest mistake, so a byte is often written as an escape,
%% an escape in lower case, or a separator doubled.
mutate(<<>>) ->
    noise();
mutate(Input) ->
    At = rand:uniform(byte_size(Input)) - 1,
    <<Before:At/binary, Byte, After/binary>> = Input,
    Middle = case rand:uniform(6) of
                 1 -> <<>>;
                 2 -> <<(rand:uniform(256) - 1)>>;
                 3 -> <<Byte, (pick(<<"/.%0aAz-">>))>>;
                 4 -> list_to_binary(io_lib:format("%~2.16.0B", [Byte]));
                 5 -> <<(lower(Byte))>>;
                 6 -> <<Byte, Byte>>
             end,
    <<Before/binary, Middle/binary, After/binary>>.

lower(Byte) when Byte >= $A, Byte =< $Z -> Byte + 32;
lower(Byte) -> Byte.

noise() ->
    << <<(pick(<<"erx:/%0123456789ABCabcdefgmoduleidpb.">>))>> || _ <- lists:seq(1, rand:uniform(24)) >>.

pick(Binary) when is_binary(Binary) -> binary:at(Binary, rand:uniform(byte_size(Binary)) - 1);
pick(List) -> lists:nth(rand:uniform(length(List)), List).
