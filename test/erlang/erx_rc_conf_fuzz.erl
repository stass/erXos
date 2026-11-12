%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of rc.conf (docs/design-apps.md, "The start table"):
%% erx_start_table:parse_rc_conf/1, the reader of the untrusted file, with merge/3
%% and set/3 over what it reads. A round builds a file of lines this module writes
%% for a setting, in every quoting, those lines mutated, comments, blanks and random
%% bytes, and pads an eighth of the files past 64 KiB and a sixteenth to exactly
%% 64 KiB. Whatever arrives, the parser makes no atom and never raises; a file over
%% 64 KiB is refused; every written line reads back as its setting at its line; the
%% values read are within abi/manifest.txt's ceilings; the merge adds no row,
%% admits at most one enabled row per display and none on a
%% display its template is not granted; and set/3 writes what it was given, keeps
%% every other line and writes at most 64 KiB. The seed comes from make check-fuzz.

-module(erx_rc_conf_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(ROUNDS, 3000).
-define(MAX_RC_CONF, 65536).
-define(NAMES, [<<"clock">>, <<"a_b">>, <<"kiosk">>, <<"x-1">>]).
-define(DISPLAYS, [<<"display">>, <<"second">>]).
-define(FIELDS, [enable, display, restarts, period]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loaded before the first round counts atoms, since loading a module makes its atoms.
    [{module, _} = code:ensure_loaded(Module) || Module <- [erx_start_table, erx_ident, binary, lists, maps, re, unicode]],
    Read = lists:sum([round_of() || _ <- lists:seq(1, ?ROUNDS)]),
    case Read >= ?ROUNDS of
        true -> io:format("fuzz: ~p rounds ok, ~p settings read~n", [?ROUNDS, Read]);
        false -> error({too_few_settings_read, Read})
    end.

round_of() ->
    Lines = [line() || _ <- lists:seq(1, rand:uniform(40) - 1)],
    Text = padded(iolist_to_binary(lists:join(<<"\n">>, [Text || {_, Text} <- Lines]))),
    Atoms = erlang:system_info(atom_count),
    Said = erx_start_table:parse_rc_conf(Text),
    Settings = settings(),
    Name = pick(?NAMES),
    Set = erx_start_table:set(Text, Name, Settings),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Text}),
    case {Said, byte_size(Text) > ?MAX_RC_CONF} of
        {{error, too_large}, true} ->
            Set =:= {error, too_large} orelse error({accepted_over_bound, set, byte_size(Text)}),
            0;
        {_, true} ->
            error({accepted_over_bound, parse, byte_size(Text)});
        {{ok, Local}, false} ->
            [well_formed(Entry) || Entry <- Local],
            [read_back(Number, Expected, Local)
             || {Number, {{written, Expected}, _}} <- lists:zip(lists:seq(1, length(Lines)), Lines)],
            merged(Local),
            written(Text, Name, Settings, Set),
            length([set || {set, _, _, _, _} <- Local])
    end.

%% A line and what it says: a setting this module writes, or anything else.
line() ->
    case rand:uniform(8) of
        N when N =< 4 -> {Setting, Text} = setting_line(), {{written, Setting}, Text};
        5 -> {other, mutate(element(2, setting_line()))};
        6 -> {other, pick([<<>>, <<"# a comment">>, <<"  \t">>, <<"\t# indented">>, <<"hostname=\"box\"">>])};
        7 -> {other, noise()};
        8 -> {other, <<(pick(?NAMES))/binary, "_", (pick([<<"enable">>, <<"display">>, <<"restarts">>,
                                                          <<"period">>, <<"colour">>]))/binary,
                       "=", (noise())/binary>>}
    end.

setting_line() ->
    Name = pick(?NAMES),
    Field = pick(?FIELDS),
    Value = value(Field),
    Raw = raw(Value),
    Quoted = case rand:uniform(3) of
                 1 -> <<$", Raw/binary, $">>;
                 2 -> <<$', Raw/binary, $'>>;
                 3 when Raw =/= <<>> -> Raw;
                 3 -> <<"\"\"">>
             end,
    Lead = pick([<<>>, <<" ">>, <<"\t ">>]),
    Trail = pick([<<>>, <<"  ">>, <<" # set here">>, <<"\t#">>]),
    {{Name, Field, Value},
     <<Lead/binary, Name/binary, $_, (atom_to_binary(Field))/binary, $=, Quoted/binary, Trail/binary>>}.

value(enable) -> rand:uniform(2) =:= 1;
value(display) -> pick([none | ?DISPLAYS]);
value(restarts) -> pick([0, 1, 5, rand:uniform(?ERX_START_RESTARTS_MAX), ?ERX_START_RESTARTS_MAX]);
value(period) -> pick([1, 600, rand:uniform(?ERX_START_PERIOD_MAX_S), ?ERX_START_PERIOD_MAX_S]).

raw(true) -> pick([<<"YES">>, <<"yes">>, <<"True">>, <<"on">>, <<"1">>]);
raw(false) -> pick([<<"NO">>, <<"no">>, <<"FALSE">>, <<"Off">>, <<"0">>]);
raw(none) -> <<>>;
raw(Value) when is_integer(Value) -> integer_to_binary(Value);
raw(Value) -> Value.

settings() ->
    maps:from_list([{Field, value(Field)} || Field <- ?FIELDS, rand:uniform(2) =:= 1]).

%% An eighth of the files just over the bound, a sixteenth exactly at it.
padded(Text) ->
    case rand:uniform(16) of
        N when N =< 2 -> pad(Text, ?MAX_RC_CONF + rand:uniform(64));
        3 -> pad(Text, ?MAX_RC_CONF);
        _ -> Text
    end.

pad(Text, Size) ->
    <<Text/binary, "\n#", (binary:copy(<<"x">>, Size - byte_size(Text) - 2))/binary>>.

well_formed({set, Number, Name, Field, Value}) when is_integer(Number), Number >= 1 ->
    valid_name(Name) andalso lists:member(Field, ?FIELDS) andalso valid_value(Field, Value)
        orelse error({ill_formed, {set, Number, Name, Field, Value}});
well_formed({skipped, Number, Reason}) when is_integer(Number), Number >= 1 ->
    reason(Reason) orelse error({open_reason, Reason});
well_formed(Entry) ->
    error({ill_formed, Entry}).

read_back(Number, {Name, Field, Value}, Local) ->
    [Entry || Entry <- Local, element(2, Entry) =:= Number] =:= [{set, Number, Name, Field, Value}]
        orelse error({written_line_misread, Number, Name, Field, Value, Local}).

merged(Local) ->
    Rows = [#{principal => Name, enable => rand:uniform(2) =:= 1, display => pick([none | ?DISPLAYS]),
              restarts => 5, period => 600} || Name <- ?NAMES],
    Grants = maps:from_list([{Name, [D || D <- ?DISPLAYS, rand:uniform(2) =:= 1]} || Name <- ?NAMES]),
    {Merged, _Skipped} = erx_start_table:merge(Rows, Local, Grants),
    [P || #{principal := P} <- Merged] =:= ?NAMES orelse error({row_added, Merged}),
    Shown = [D || #{status := enabled, display := D} <- Merged, D =/= none],
    length(Shown) =:= length(lists:usort(Shown)) orelse error({display_twice, Merged}),
    [error({no_grant_admitted, P, D}) || #{status := enabled, principal := P, display := D} <- Merged,
                                         D =/= none, not lists:member(D, maps:get(P, Grants))],
    [last_setting(Row, Local) || Row <- Merged].

%% A merged row holds the last setting of each field the file made for it.
last_setting(#{principal := Name} = Row, Local) ->
    [maps:get(Field, Row) =:= Value orelse error({not_the_last_setting, Name, Field, Row})
     || Field <- ?FIELDS,
        {set, _, _, _, Value} <- lists:sublist(lists:reverse([E || {set, _, N, F, _} = E <- Local,
                                                                  N =:= Name, F =:= Field]), 1)].

written(Text, Name, Settings, {ok, Out}) ->
    byte_size(Out) =< ?MAX_RC_CONF orelse error({accepted_over_bound, written, byte_size(Out)}),
    {ok, Local} = erx_start_table:parse_rc_conf(Out),
    [error({set_misread, Name, Field, Value, Local})
     || {Field, Value} <- maps:to_list(Settings),
        lists:last([missing | [V || {set, _, N, F, V} <- Local, N =:= Name, F =:= Field]]) =/= Value],
    Variables = [<<Name/binary, $_, (atom_to_binary(Field))/binary>> || Field <- maps:keys(Settings)],
    Kept = fun(Bin) -> [L || L <- binary:split(Bin, <<"\n">>, [global]), L =/= <<>>,
                             not lists:any(fun(V) -> assigns(L, V) end, Variables)] end,
    Kept(Text) =:= Kept(Out) orelse error({set_lost_line, Text, Out});
written(Text, _Name, _Settings, {error, too_large}) ->
    byte_size(Text) + 200 > ?MAX_RC_CONF orelse error({set_refused_in_bound, byte_size(Text)}).

assigns(Line, Variable) ->
    Size = byte_size(Variable),
    case skip_blanks(Line) of
        <<Variable:Size/binary, $=, _/binary>> -> true;
        _ -> false
    end.

%% The closed set of reasons a line is skipped for; the one name has passed the
%% identifier check, so nothing of the line reaches a reason unchecked.
reason(Reason) when Reason =:= not_an_assignment; Reason =:= bad_quoting;
                    Reason =:= trailing_text; Reason =:= bad_variable -> true;
reason({bad_value, Field}) -> lists:member(Field, ?FIELDS);
reason({undeclared, Name}) -> valid_name(Name);
reason(_) -> false.

%% An independent oracle of the identifier rule, apart from erx_ident's code.
valid_name(Name) ->
    re:run(Name, "\\A[a-z0-9][a-z0-9_-]{0,62}\\z") =/= nomatch.

valid_value(enable, Value) -> is_boolean(Value);
valid_value(display, Value) -> Value =:= none orelse valid_name(Value);
valid_value(restarts, Value) -> is_integer(Value) andalso Value >= 0 andalso Value =< ?ERX_START_RESTARTS_MAX;
valid_value(period, Value) -> is_integer(Value) andalso Value >= 1 andalso Value =< ?ERX_START_PERIOD_MAX_S.

mutate(<<>>) ->
    noise();
mutate(Text) ->
    At = rand:uniform(byte_size(Text)) - 1,
    <<Before:At/binary, Byte, After/binary>> = Text,
    case rand:uniform(4) of
        1 -> <<Before/binary, After/binary>>;
        2 -> <<Before/binary, (byte())/binary, Byte, After/binary>>;
        3 -> <<Before/binary, (byte())/binary, After/binary>>;
        4 -> <<Before/binary, (pick([$", $', $\\, $$, $`, $#, $_, $=, $\s]))/integer, After/binary>>
    end.

noise() ->
    iolist_to_binary([byte() || _ <- lists:seq(1, rand:uniform(40) - 1)]).

%% Any byte but the newline, so a line stays one line.
byte() ->
    case rand:uniform(256) - 1 of
        $\n -> <<"\r">>;
        Byte -> <<Byte>>
    end.

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).

skip_blanks(<<Blank, Rest/binary>>) when Blank =:= $\s; Blank =:= $\t -> skip_blanks(Rest);
skip_blanks(Rest) -> Rest.
