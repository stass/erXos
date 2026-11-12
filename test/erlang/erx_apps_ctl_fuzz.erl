%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the apps tree's ctl file (docs/design-apps.md, "Interfaces"):
%% erx_start_table:parse_ctl/1, the reader of one untrusted write. A round takes a
%% command this module writes, with its settings in any order and any blanks
%% between its words, and uses it as it is, padded with blanks to exactly 4,096
%% bytes or past them, mutated, or replaced by random bytes. Whatever arrives,
%% parse_ctl/1 makes no atom and never raises; a written command reads back as
%% itself; a write over 4,096 bytes is refused; and every accepted command is a
%% verb, a manifest identifier and only the settings its verb takes, which reads
%% back as itself once written again. The seed comes from make check-fuzz.

-module(erx_apps_ctl_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MIN_ACCEPTED, ?ROUNDS div 5).
-define(MAX_CTL, 4096).
-define(MAX_U32, 16#FFFFFFFF).
%% Each verb and the settings it takes.
-define(VERBS, [{enable, [display, restarts, period]}, {disable, []}, {start, [display]}, {stop, []}]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loaded before the first round counts atoms, since loading a module makes its atoms.
    [{module, _} = code:ensure_loaded(Module) || Module <- [erx_start_table, erx_ident, binary, lists, maps, re, unicode]],
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(case_of()) =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of({Write, Expected}) ->
    Atoms = erlang:system_info(atom_count),
    Said = erx_start_table:parse_ctl(Write),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Write}),
    byte_size(Write) =< ?MAX_CTL orelse Said =:= {error, too_long}
        orelse error({accepted_over_bound, byte_size(Write), Said}),
    case {Said, Expected} of
        {{ok, Command}, _} when Expected =:= none; Expected =:= Command ->
            well_formed(Command),
            through_rc_conf(Command),
            erx_start_table:parse_ctl(written(Command)) =:= Said orelse error({second_reading, Write, Said}),
            accepted;
        {{error, Reason}, none} when is_atom(Reason) ->
            refused;
        {{error, too_long}, too_long} ->
            refused;
        _ ->
            error({disagrees_with_writer, Write, Expected, Said})
    end.

%% {Write, Command} for a written command, {Write, too_long} for one padded past
%% the bound, {Write, none} for anything else.
case_of() ->
    Command = command(),
    Write = spaced(Command),
    case rand:uniform(8) of
        N when N =< 3 -> {Write, Command};
        4 -> {pad(Write, ?MAX_CTL), Command};
        5 -> {pad(Write, ?MAX_CTL + rand:uniform(64)), too_long};
        6 -> {mutate(Write), none};
        7 -> {noise(), none};
        8 -> {<<(atom_to_binary(element(1, Command)))/binary, " ", (bad_name())/binary>>, none}
    end.

command() ->
    {Verb, Allowed} = pick(?VERBS),
    {Verb, name(), maps:from_list([{Field, value(Field)} || Field <- Allowed, rand:uniform(2) =:= 1])}.

name() ->
    First = pick("abcdefghijklmnopqrstuvwxyz0123456789"),
    Rest = [pick("abcdefghijklmnopqrstuvwxyz0123456789_-") || _ <- lists:seq(1, rand:uniform(63) - 1)],
    list_to_binary([First | Rest]).

%% A name one byte too long, or with a byte the manifest's identifier refuses.
bad_name() ->
    case rand:uniform(3) of
        1 -> binary:copy(<<"a">>, 64);
        2 -> <<"_", (name())/binary>>;
        3 -> <<(name())/binary, (pick([<<"A">>, <<".">>, <<"/">>, <<"=">>, <<"\"">>]))/binary>>
    end.

value(display) -> pick([none, <<"display">>, name()]);
value(restarts) -> pick([0, 5, rand:uniform(1000), ?MAX_U32]);
value(period) -> pick([1, 600, rand:uniform(100000), ?MAX_U32]).

%% The command with its settings in random order and random blanks.
spaced({Verb, Name, Settings}) ->
    Words = [atom_to_binary(Verb), Name | [setting(F, V) || {F, V} <- shuffle(maps:to_list(Settings))]],
    Blank = fun() -> pick([<<" ">>, <<"\t">>, <<"  ">>, <<" \t ">>]) end,
    Lead = pick([<<>>, Blank()]),
    Trail = pick([<<>>, Blank(), <<"\n">>]),
    iolist_to_binary([Lead, lists:join(Blank(), Words), Trail]).

written({Verb, Name, Settings}) ->
    iolist_to_binary(lists:join(<<" ">>, [atom_to_binary(Verb), Name |
                                          [setting(F, V) || {F, V} <- maps:to_list(Settings)]])).

setting(Field, Value) -> <<(atom_to_binary(Field))/binary, $=, (raw(Value))/binary>>.

raw(none) -> <<>>;
raw(Value) when is_integer(Value) -> integer_to_binary(Value);
raw(Value) -> Value.

%% Blanks before the first word, so the command and its one newline are unchanged.
pad(Write, Size) ->
    <<(binary:copy(<<" ">>, Size - byte_size(Write)))/binary, Write/binary>>.

%% What a command sets is what set/3 writes and parse_rc_conf/1 reads back.
through_rc_conf({_Verb, Name, Settings} = Command) ->
    {ok, Text} = erx_start_table:set(<<>>, Name, Settings),
    {ok, Local} = erx_start_table:parse_rc_conf(Text),
    lists:sort([{Field, Value} || {set, _, N, Field, Value} <- Local, N =:= Name]) =:=
        lists:sort(maps:to_list(Settings)) andalso length(Local) =:= map_size(Settings)
        orelse error({not_through_rc_conf, Command, Text}).

well_formed({Verb, Name, Settings} = Command) ->
    {Verb, Allowed} = lists:keyfind(Verb, 1, ?VERBS),
    valid_name(Name) andalso is_map(Settings)
        andalso lists:all(fun({F, V}) -> lists:member(F, Allowed) andalso valid_value(F, V) end,
                          maps:to_list(Settings))
        orelse error({ill_formed, Command}).

%% An independent oracle of the identifier rule, apart from erx_ident's code.
valid_name(Name) ->
    is_binary(Name) andalso re:run(Name, "\\A[a-z0-9][a-z0-9_-]{0,62}\\z") =/= nomatch.

valid_value(display, Value) -> Value =:= none orelse valid_name(Value);
valid_value(restarts, Value) -> is_integer(Value) andalso Value >= 0 andalso Value =< ?MAX_U32;
valid_value(period, Value) -> is_integer(Value) andalso Value >= 1 andalso Value =< ?MAX_U32.

mutate(Write) when byte_size(Write) =:= 0 ->
    noise();
mutate(Write) ->
    At = rand:uniform(byte_size(Write)) - 1,
    <<Before:At/binary, Byte, After/binary>> = Write,
    case rand:uniform(4) of
        1 -> <<Before/binary, After/binary>>;
        2 -> <<Before/binary, (rand:uniform(256) - 1), Byte, After/binary>>;
        3 -> <<Before/binary, (rand:uniform(256) - 1), After/binary>>;
        4 -> <<Before/binary, (pick("= \t\n_-0Ae")), After/binary>>
    end.

noise() ->
    << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, rand:uniform(64) - 1) >>.

shuffle(List) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), X} || X <- List])].

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
