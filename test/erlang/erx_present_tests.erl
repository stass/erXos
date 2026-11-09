%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_present against the checked-in inspection schema: every presentation
%% round-trips through its text and its link, the texts and paths are those of
%% docs/design-display.md's table, links agree with reference_uri/2, which
%% shares no code with the module, and malformed texts are refused.
-module(erx_present_tests).
-include_lib("eunit/include/eunit.hrl").

%% Every presentation the schema marks, over values at its segments' bounds.
every_presentation_round_trips_test() ->
    [round_trip(Type, Value) || {Type, Pattern} <- erx_present:marks(), Value <- values(Pattern)].

round_trip(Type, Value) ->
    Text = erx_present:text(Type, Value),
    ?assertEqual({ok, Value}, erx_present:parse(Type, Text)),
    Uri = erx_present:uri(Type, Value),
    ?assertEqual(reference_uri(Type, Text), Uri),
    ?assertEqual({ok, Type, Value}, erx_present:parse_uri(Uri)),
    ?assertEqual({ok, Type}, erx_present:type(atom_to_binary(Type))),
    {ok, Path, _Declaration} = erx_schema:resolve_text(path_text(erx_present:path(Type, Value))),
    ?assertEqual(Path, erx_present:path(Type, Value)).

the_design_table_test() ->
    [_, N, S] = string:split(string:trim(pid_to_list(self()), both, "<>"), ".", all),
    ?assertEqual(iolist_to_binary(["0.", N, ".", S]), erx_present:text(pid, self())),
    ?assertEqual(<<"3">>, erx_present:text(domain, 3)),
    ?assertEqual(<<"3/lists">>, erx_present:text(module, {3, <<"lists">>})),
    ?assertEqual(<<"7">>, erx_present:text(budget, 7)),
    ?assertEqual(<<"2">>, erx_present:text(group, 2)),
    ?assertEqual([domains, 3, modules, <<"lists">>], erx_present:path(module, {3, <<"lists">>})),
    ?assertEqual([processes, self()], erx_present:path(pid, self())),
    ?assertEqual(<<"erx:module/3/lists">>, erx_present:uri(module, {3, <<"lists">>})).

%% A text segment's /proc escapes are escaped again in the link, which keeps
%% "." and "/", so the link decodes once to the canonical text.
a_link_escapes_the_texts_escapes_test() ->
    ?assertEqual(<<"3/a%2Eb%2Fc">>, erx_present:text(module, {3, <<"a.b/c">>})),
    ?assertEqual(<<"erx:module/3/a%252Eb%252Fc">>, erx_present:uri(module, {3, <<"a.b/c">>})),
    %% No text segment becomes a dot segment, which a browser's URL parser resolves.
    ?assertEqual(<<"erx:module/3/%252E%252E">>, erx_present:uri(module, {3, <<"..">>})).

malformed_texts_are_refused_test() ->
    [?assertEqual(error, erx_present:parse(Type, Text))
     || {Type, Text} <- [{domain, <<"03">>}, {domain, <<"/3">>}, {domain, <<"3/">>}, {domain, <<>>},
                         {domain, <<"4294967296">>}, {budget, <<"0">>}, {module, <<"3">>},
                         {module, <<"3/lists/x">>}, {module, <<"3//lists">>}, {module, <<"3/a.b">>},
                         {module, <<"3/a%2eb">>}, {module, <<"3/a%41">>}, {pid, <<"0.1">>},
                         {nothing, <<"3">>}, {<<"domain">>, <<"3">>}, {domain, "3"},
                         {domain, binary:copy(<<"1">>, 4097)}]],
    [?assertEqual(error, erx_present:parse_uri(Link))
     || Link <- [<<"erx:module/3/a%2Eb">>, <<"erx:module/3/a%252eb">>, <<"erx:module/3/a%2Fb">>,
                 <<"erx:Domain/3">>, <<"erx:accept/domain">>, <<"erx:domain">>, <<"erx:domain/">>,
                 <<"erx:domain/3 ">>, <<"https:domain/3">>, <<"erx:nothing/3">>, "erx:domain/3",
                 <<"erx:module/3/", (binary:copy(<<"a">>, 3 * 4096))/binary>>]].

values_outside_the_type_raise_test() ->
    [?assertError(badarg, erx_present:text(Type, Value))
     || {Type, Value} <- [{domain, -1}, {budget, 0}, {module, 3}, {module, {3, <<>>}},
                          {module, {3, <<255>>}}, {pid, 3}, {nothing, 3}]],
    ?assertError(badarg, erx_present:path(domain, <<"3">>)),
    ?assertError(badarg, erx_present:uri(module, {3})).

reading_input_makes_no_atom_test() ->
    Before = erlang:system_info(atom_count),
    error = erx_present:type(<<"erx_present_tests_no_such_presentation">>),
    error = erx_present:parse_uri(<<"erx:erx_present_tests_no_such_presentation/3">>),
    ?assertEqual(Before, erlang:system_info(atom_count)).

%% Values at the bounds of each variable segment's type, and every
%% combination of them for a presentation of several segments.
values(Pattern) ->
    Choices = [samples(descriptor(Type)) || {variable, Type} <- Pattern],
    [value(Combination) || Combination <- combinations(Choices)].

value([Segment]) -> Segment;
value(Segments) -> list_to_tuple(Segments).

combinations([]) -> [[]];
combinations([Choice | Rest]) -> [[Item | Tail] || Item <- Choice, Tail <- combinations(Rest)].

descriptor({type, Name}) ->
    {ok, Descriptor} = erx_schema:type(Name),
    Descriptor;
descriptor(Descriptor) ->
    Descriptor.

samples({integer, Minimum, Maximum, _Multiple}) -> [Minimum, Maximum];
samples({text, Maximum, Encoding}) ->
    Longest = case Encoding of
                  utf8 -> binary:copy(<<16#C3, 16#A9>>, Maximum div 2);
                  bytes -> binary:copy(<<255>>, Maximum)
              end,
    [<<"lists">>, <<"a.b/c d%">>, Longest];
samples(pid) -> [self()].

path_text(Path) ->
    iolist_to_binary(lists:join($/, [erx_schema:segment_text(Segment) || Segment <- Path])).

%% The link as docs/design-display.md writes it: "erx:", the name, "/", and
%% the text with every byte outside the link's set as % and two upper-case
%% hexadecimal digits.
reference_uri(Type, Text) ->
    Kept = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+,:=@-./",
    Escaped = [case lists:member(Byte, Kept) of
                   true -> Byte;
                   false -> io_lib:format("%~2.16.0B", [Byte])
               end || <<Byte>> <= Text],
    iolist_to_binary(["erx:", atom_to_list(Type), "/", Escaped]).
