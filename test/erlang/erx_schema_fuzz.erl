%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Two readers of erx_schema under random input; the seed comes from make check-fuzz.
%%
%% Paths: random path texts through erx_schema:resolve_text/1, the reader of the
%% untrusted path text that /proc and the host hand the inspector. Whatever arrives, it
%% answers {ok, Path, Declaration} or {error, bad_path | unknown_path} and makes no atom.
%% Half the texts are paths of the declarations, written by encode/1, a writer that
%% shares no code with the module, and each must read back as its path; the other half
%% are those texts mutated and random bytes. Every text that resolves must be what
%% encode/1 writes for its path, so each path has exactly one spelling.
%%
%% Records: random terms through erx_schema:validate_record/1, the check every record
%% passes before it leaves the runtime (docs/design-live.md, "Names travel as data",
%% V10). A third are records built from the declarations, a third those records with a
%% pid, port, reference or fun planted at a random depth, and a third random terms that
%% sometimes hold one. named/1, a walker that shares no code with the module, is the
%% reference: a term holding a name is refused as {error, name}, any other term is never
%% refused for one, and no record accepted holds a name.

-module(erx_schema_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MIN_ACCEPTED, ?ROUNDS div 10).
-define(PLAIN, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+,:=@-").
-define(U32, 4294967295).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(text()) =:= accepted]),
    enough(Accepted, too_few_accepted),
    io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]),
    Names = [self(), make_ref(), fun erlang:self/0, fun() -> ok end, list_to_port("#Port<0.0>")],
    Verdicts = [record_round(record_term(Names)) || _ <- lists:seq(1, ?ROUNDS)],
    RecordsAccepted = length([ok || accepted <- Verdicts]),
    Named = length([ok || named <- Verdicts]),
    enough(RecordsAccepted, too_few_records_accepted),
    enough(Named, too_few_names_planted),
    io:format("fuzz: ~p records ok, ~p accepted, ~p refused as named~n", [?ROUNDS, RecordsAccepted, Named]).

enough(Count, _Why) when Count >= ?MIN_ACCEPTED -> ok;
enough(Count, Why) -> error({Why, Count}).

%%% Paths

%% The atom count is read around the call alone, since the round's own helpers load code.
round_of({Text, Expected}) ->
    Atoms = erlang:system_info(atom_count),
    Said = erx_schema:resolve_text(Text),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Text}),
    case {Said, Expected} of
        {{ok, Path, Declaration}, _} when Expected =:= none; Expected =:= Path ->
            {ok, Declaration} =:= erx_schema:resolve(Path) orelse error({term_disagrees, Text, Path}),
            canonical(Text) =:= encode(Path) orelse error({second_spelling, Text, Path}),
            accepted;
        {{error, Reason}, none} when Reason =:= bad_path; Reason =:= unknown_path ->
            refused;
        {Said, _} ->
            error({disagrees_with_reference, Text, Expected, Said})
    end.

canonical(<<"/", Rest/binary>>) -> Rest;
canonical(Text) -> Text.

%% {Text, Path} for a written path, {Text, none} for anything else.
text() ->
    {Path, Text} = written(),
    case rand:uniform(4) of
        1 -> {Text, Path};
        2 -> {<<"/", Text/binary>>, Path};
        3 -> {mutate(Text), none};
        4 -> {noise(), none}
    end.

written() ->
    #{pattern := Pattern} = pick(erx_schema:declarations()),
    Path = [segment(Element) || Element <- Pattern],
    {Path, encode(Path)}.

segment({variable, Type}) -> value(Type);
segment(Literal) -> Literal.

%% A value of a descriptor, at its bounds or within them. A record's attribute need
%% not hold a valid one: a value outside its type is kept as {error, invalid}.
value({type, Name}) ->
    {ok, Descriptor} = erx_schema:type(Name),
    value(Descriptor);
value({integer, Minimum, Maximum, Multiple}) ->
    Steps = (Maximum - Minimum) div Multiple,
    Minimum + Multiple * pick([0, Steps, rand:uniform(Steps + 1) - 1, Steps div 2]);
value({text, Maximum, Encoding}) ->
    Bytes = << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, rand:uniform(max(1, min(Maximum, 12)))) >>,
    case Encoding of
        utf8 -> << <<(Byte rem 128)>> || <<Byte>> <= Bytes >>;
        bytes -> Bytes
    end;
value({atoms, Atoms}) -> pick(Atoms);
value({flags, Names}) -> [Name || Name <- Names, rand:uniform(2) =:= 1];
value({list, Element, Maximum}) -> [value(Element) || _ <- lists:seq(1, rand:uniform(min(Maximum, 3) + 1) - 1)];
value({tuple, Elements}) -> list_to_tuple([value(Element) || Element <- Elements]);
value(boolean) -> pick([true, false]);
value(proc_id) -> {pid, part(), part(), part()}.

part() -> pick([0, ?U32, rand:uniform(?U32 + 1) - 1]).

%% The writer of /proc names, from docs/design-live.md, "The /proc tree".
encode(Path) ->
    iolist_to_binary(lists:join(<<"/">>, [encode_segment(Segment) || Segment <- Path])).

encode_segment(Segment) when is_atom(Segment) -> atom_to_binary(Segment);
encode_segment(Segment) when is_integer(Segment) -> integer_to_binary(Segment);
encode_segment({pid, D, N, S}) -> iolist_to_binary(io_lib:format("~b.~b.~b", [D, N, S]));
encode_segment(Segment) when is_binary(Segment) ->
    << <<(case lists:member(Byte, ?PLAIN) of
              true -> <<Byte>>;
              false -> list_to_binary(io_lib:format("%~2.16.0B", [Byte]))
          end)/binary>> || <<Byte>> <= Segment >>.

mutate(Text) ->
    Position = rand:uniform(byte_size(Text) + 1) - 1,
    <<Head:Position/binary, Tail/binary>> = Text,
    case {rand:uniform(5), Tail} of
        {1, <<_, Rest/binary>>} -> <<Head/binary, Rest/binary>>;
        {2, <<_, Rest/binary>>} -> <<Head/binary, (piece())/binary, Rest/binary>>;
        {3, _} -> <<Head/binary, (piece())/binary, Tail/binary>>;
        {4, _} -> <<Head/binary, "/", Tail/binary>>;
        _ -> <<Text/binary, "/", (piece())/binary>>
    end.

noise() ->
    iolist_to_binary([piece() || _ <- lists:seq(1, rand:uniform(8) - 1)]).

piece() ->
    pick([<<"/">>, <<"%">>, <<"%2E">>, <<"%2e">>, <<"%41">>, <<"%FF">>, <<".">>, <<"-">>, <<"0">>,
          <<"00">>, <<"-0">>, <<"18446744073709551616">>, <<"4294967295">>, <<"4294967296">>,
          <<"domains">>, <<"modules">>, <<"processes">>, <<"budgets">>, <<"cpus">>, <<"budget">>,
          <<"63">>, <<"64">>, <<"0.1.0">>, <<"4.0.0">>, <<"<0.1.0>">>, <<"4.01.0">>,
          <<(rand:uniform(256) - 1)>>]).

%%% Records

record_round(Term) ->
    case {erx_schema:validate_record(Term), named(Term)} of
        {{error, name}, true} -> named;
        {_Said, true} -> error({name_not_refused, Term});
        {{error, name}, false} -> error({refused_as_named, Term});
        {{ok, Record}, false} -> named(Record) =:= false orelse error({name_accepted, Record}), accepted;
        {{error, _Reason}, false} -> refused
    end.

record_term(Names) ->
    case rand:uniform(3) of
        1 -> record();
        2 -> plant(record(), pick(Names));
        3 -> term(Names, 4)
    end.

%% A record of a random declaration, whose id is its path's last segment, with a
%% random half of its kind's attributes, each under one of its reporters.
record() ->
    #{kind := Kind, pattern := Pattern, children := Children} = pick(erx_schema:declarations()),
    Path = [segment(Element) || Element <- Pattern],
    {ok, Keys} = erx_schema:attributes(Kind),
    #{schema => erx_schema:schema(), path => Path, kind => Kind,
      id => case Path of [] -> 0; _ -> lists:last(Path) end,
      attrs => maps:from_list([{Key, attr(Kind, Key)} || Key <- Keys, rand:uniform(2) =:= 1]),
      children => children(Children)}.

attr(Kind, Key) ->
    {ok, #{type := Type, reporters := Reporters}} = erx_schema:attribute(Kind, Key),
    {pick(Reporters), pick([{ok, value(Type)}, {partial, value(Type)}, unknown, unsupported,
                            {timeout, rand:uniform(1000)}, {error, einval}])}.

children(Children) ->
    Segments = case Children of
                   {literals, []} -> [];
                   {literals, Literals} -> lists:usort([pick(Literals) || _ <- lists:seq(1, 3)]);
                   {variable, Type} -> lists:usort([value(Type) || _ <- lists:seq(1, 3)])
               end,
    pick([Segments, {partial, Segments}, unknown]).

%% Term with Name in place of a random part of it, at any depth: an element of a
%% list or tuple, a list's tail, a map's value or a key of its own.
plant(Term, Name) ->
    case {rand:uniform(5), Term} of
        {1, _} -> Name;
        {2, [_ | _]} -> Term ++ Name;
        {_, [_ | _]} -> replace_nth(Term, rand:uniform(length(Term)), Name);
        {_, _} when is_tuple(Term), tuple_size(Term) > 0 ->
            At = rand:uniform(tuple_size(Term)),
            setelement(At, Term, plant(element(At, Term), Name));
        {2, _} when is_map(Term) -> Term#{Name => 0};
        {_, _} when is_map(Term), map_size(Term) > 0 ->
            Key = pick(maps:keys(Term)),
            Term#{Key := plant(map_get(Key, Term), Name)};
        {_, _} -> Name
    end.

replace_nth([Head | Tail], 1, Name) -> [plant(Head, Name) | Tail];
replace_nth([Head | Tail], At, Name) -> [Head | replace_nth(Tail, At - 1, Name)].

%% A random term of at most Depth levels, one leaf in eight a name.
term(Names, 0) -> leaf(Names);
term(Names, Depth) ->
    case rand:uniform(5) of
        1 -> [term(Names, Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)];
        2 -> list_to_tuple([term(Names, Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)]);
        3 -> maps:from_list([{leaf(Names), term(Names, Depth - 1)} || _ <- lists:seq(1, rand:uniform(4) - 1)]);
        _ -> leaf(Names)
    end.

leaf(Names) ->
    case rand:uniform(8) of
        1 -> pick(Names);
        _ -> pick([schema, path, kind, id, attrs, children, entries, processes, ok, error, unknown,
                   0, 1, ?U32, -1, <<"a">>, <<>>, value(proc_id), {pid, 0, 0}])
    end.

%% A term holding a pid, port, reference or fun anywhere, written as a plain recursion
%% over the term: the terms here are a few levels deep.
named(Term) when is_pid(Term); is_port(Term); is_reference(Term); is_function(Term) -> true;
named([Head | Tail]) -> named(Head) orelse named(Tail);
named(Term) when is_tuple(Term) -> named(tuple_to_list(Term));
named(Term) when is_map(Term) -> named(maps:to_list(Term));
named(_Term) -> false.

pick(List) -> lists:nth(rand:uniform(length(List)), List).
