%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_schema as generated from test/fixtures/inspection_forms, a schema
%% that uses every value form, a stopgap reporter, every visibility, build and
%% projection, and every kind of path segment and mark. test/host/erx_schema_test.rb
%% generates the module and runs these on stock's emulator.

-module(erx_schema_forms_tests).
-include_lib("eunit/include/eunit.hrl").

type_of(Key) ->
    {ok, #{type := Type}} = erx_schema:attribute(thing, Key),
    Type.

accepts(Key, Values) -> [?assert(erx_schema:valid(type_of(Key), Value)) || Value <- Values].
refuses(Key, Values) -> [?assertNot(erx_schema:valid(type_of(Key), Value)) || Value <- Values].

integer_test() ->
    accepts(count, [-5, 0, 40]),
    refuses(count, [-6, 41, 1.0, <<"1">>, one]).

aligned_root_scalar_test() ->
    accepts(page, [0, 4096, 1048576]),
    refuses(page, [4095, -4096, 1048576 + 4096]).

utf8_text_test() ->
    accepts(name, [<<>>, <<"h", 16#c3, 16#a9, "llo">>, <<"12345678">>]),
    refuses(name, [<<"123456789">>, <<16#c0, 16#80>>, <<16#ed, 16#a0, 16#80>>, <<255>>,
                   <<16#f4, 16#90, 16#80, 16#80>>, "abc", abc]).

byte_text_test() ->
    accepts(secret, [<<255, 0>>, <<"abcd">>]),
    refuses(secret, [<<"abcde">>, "ab"]).

%% A descriptor erx_schema did not make is no type, and never a crash.
foreign_descriptor_test() ->
    Foreign = [{{list, {type, index}, infinity}, [1]}, {{atoms, x}, a}, {{flags, x}, [a]},
               {{tuple, x}, {1}}, {{integer, 0, 9, 0}, 1}, {{text, many, bytes}, <<>>},
               {{type, missing}, 1}, {nothing, 1}],
    [?assertNot(erx_schema:valid(Descriptor, Value)) || {Descriptor, Value} <- Foreign].

atoms_test() ->
    accepts(shade, [light, dark]),
    refuses(shade, [red, <<"light">>, "light"]),
    accepts(object, [budget, space]),
    refuses(object, [thread]),
    accepts(status, [ok, inval]),
    refuses(status, [nomem, 0]),
    accepts(colour, [red, blue]),
    refuses(colour, [1, green]).

flags_test() ->
    accepts(rights, [[], [read], [write, read]]),
    refuses(rights, [[read, read], [exec], read, [read | write]]),
    accepts(mode, [[fast, safe]]),
    refuses(mode, [[fast, slow]]).

list_and_tuple_test() ->
    accepts(pairs, [[], [{1, <<"a">>}], [{0, <<>>}, {9, <<"abcd">>}]]),
    refuses(pairs, [[{1, <<"a">>}, {1, <<"a">>}, {1, <<"a">>}], [{1, <<"a">>} | tail],
                    [{1, <<"a">>, x}], [{10, <<>>}], [{1, <<"abcde">>}], {1, <<"a">>}]),
    accepts(labels, [[<<"a">>, <<"b">>, <<"c">>]]),
    refuses(labels, [[<<"a">>, <<"b">>, <<"c">>, <<"d">>], [<<16#c0>>]]).

boolean_and_proc_id_test() ->
    accepts(flag, [true, false]),
    refuses(flag, [yes, 1]),
    accepts(owner, [{pid, 0, 1, 0}, {pid, 16#ffffffff, 16#ffffffff, 16#ffffffff}]),
    refuses(owner, [self(), 1, "<0.1.0>", {pid, -1, 1, 0}, {pid, 0, 1 bsl 32, 0}, {pid, a, 1, 0},
                    {pid, 0, 1}, {port, 0, 1, 0}]).

%% Every status keeps its value and its reporter; a value outside its type becomes
%% {error, invalid}, still the reporter's.
statuses_test() ->
    Kept = [{ok, 3}, {partial, 3}, unknown, unsupported, {timeout, 500}, {error, enomem}],
    [?assertEqual({ok, {kernel, Value}}, erx_schema:validate_attr(thing, count, kernel, Value))
     || Value <- Kept],
    Invalid = [{ok, 99}, {partial, 99}, {timeout, 0}, {timeout, 1.5}, {timeout, 1 bsl 32},
               {error, [1, 2, 3]}, {error, <<"reason">>}, weird, {ok, 1, 2}],
    [?assertEqual({ok, {kernel, {error, invalid}}}, erx_schema:validate_attr(thing, count, kernel, Value))
     || Value <- Invalid].

%% Each reporter only on the attributes that list it; a stopgap by its name only.
reporters_test() ->
    Allowed = [{count, kernel}, {count, {stopgap, gap}}, {secret, service}, {name, runtime}],
    [?assertMatch({ok, _}, erx_schema:validate_attr(thing, Key, Reporter, unknown))
     || {Key, Reporter} <- Allowed],
    Refused = [{count, service}, {count, runtime}, {secret, kernel}, {name, {stopgap, gap}},
               {count, {stopgap, other}}, {count, gap}, {count, {stopgap, <<"gap">>}}],
    [?assertEqual({error, reporter}, erx_schema:validate_attr(thing, Key, Reporter, unknown))
     || {Key, Reporter} <- Refused],
    ?assertEqual({error, unknown_attribute}, erx_schema:validate_attr(thing, missing, kernel, unknown)),
    ?assertEqual({error, unknown_attribute}, erx_schema:validate_attr(listing, count, kernel, unknown)),
    ?assertEqual({error, reporter}, erx_schema:validate_attr(thing, count, {kernel, {ok, 1}}, unknown)).

labels_test() ->
    ?assertEqual({ok, <<"gap label">>}, erx_schema:reporter_label({stopgap, gap})),
    ?assertEqual({ok, <<"kernel">>}, erx_schema:reporter_label(kernel)),
    ?assertEqual(error, erx_schema:reporter_label({stopgap, other})),
    ?assertEqual({ok, #{category => kernel, label => <<"gap label">>, scope => <<"what the gap sees">>}},
                 erx_schema:stopgap(gap)),
    ?assertEqual([gap], erx_schema:stopgaps()),
    ?assertEqual({ok, <<"pages">>}, erx_schema:unit_label(pages)),
    {ok, #{unit := Unit}} = erx_schema:attribute(thing, count),
    ?assertEqual(<<"pages">>, Unit).

fields_test() ->
    {ok, Release} = erx_schema:fields(thing, shell, release),
    ?assertEqual([count, pairs, flag, owner, rights, object, status, page, colour, mode], Release),
    {ok, Development} = erx_schema:fields(thing, shell, development),
    ?assertEqual(Release ++ [labels], Development),
    ?assertEqual({ok, [name]}, erx_schema:fields(thing, proc, release)),
    ?assertEqual({ok, []}, erx_schema:fields(listing, shell, release)),
    ?assertEqual(error, erx_schema:fields(nothing, shell, release)),
    ?assertEqual(error, erx_schema:fields(thing, shell, beta)).

%% A matcher that shares no code with erx_schema's: the number of declarations a
%% path term matches.
matching(Path) ->
    length([D || #{pattern := Pattern} = D <- erx_schema:declarations(), match(Pattern, Path)]).

match([], []) -> true;
match([{variable, Type} | Pattern], [Segment | Path]) ->
    Segment =/= <<>> andalso erx_schema:valid(Type, Segment) andalso match(Pattern, Path);
match([Literal | Pattern], [Segment | Path]) when is_atom(Literal) -> Literal =:= Segment andalso match(Pattern, Path);
match(_, _) -> false.

resolve_term_test() ->
    Paths = [{[], listing}, {[things], listing}, {[things, 3], thing}, {[things, 3, secret], listing},
             {[named], listing}, {[named, <<"a.b">>], thing}, {[owners, {pid, 0, 1, 0}], thing}, {[log], listing}],
    [begin
         ?assertEqual(1, matching(Path)),
         ?assertMatch({ok, #{kind := Kind}}, erx_schema:resolve(Path))
     end || {Path, Kind} <- Paths],
    Unknown = [[things, 10], [things, -1], [named, a], [named, <<>>], [named, <<"123456789">>], [owners, 1],
               [owners, self()], [things, 3, other], [other], [things | 3], not_a_path],
    [?assertEqual({error, unknown_path}, erx_schema:resolve(Path)) || Path <- Unknown],
    [?assertEqual(0, matching(Path)) || Path <- Unknown, is_list(Path), Path =/= [things | 3]].

path_marks_test() ->
    {ok, Secret} = erx_schema:resolve([things, 3, secret]),
    ?assertEqual([all, system_shell], maps:get(visible, Secret)),
    {ok, Log} = erx_schema:resolve([log]),
    ?assertMatch(#{entries := {{type, label}, 100}, append_only := true, visible := []}, Log),
    {ok, Root} = erx_schema:resolve([]),
    ?assertEqual({literals, [things, named, owners, log]}, maps:get(children, Root)),
    {ok, Things} = erx_schema:resolve([things]),
    ?assertEqual({variable, {type, index}}, maps:get(children, Things)).

resolve_text_test() ->
    Texts = [{<<>>, []}, {<<"/">>, []}, {<<"things">>, [things]}, {<<"/things/3">>, [things, 3]},
             {<<"things/3/secret">>, [things, 3, secret]}, {<<"named/a%2Eb">>, [named, <<"a.b">>]},
             {<<"named/%25%2F%C3%A9">>, [named, <<"%/", 16#c3, 16#a9>>]},
             {<<"named/A_+,:=@-">>, [named, <<"A_+,:=@-">>]},
             {<<"owners/0.1.0">>, [owners, {pid, 0, 1, 0}]},
             {<<"owners/9.1.0">>, [owners, {pid, 9, 1, 0}]}],
    [begin
         {ok, Path, Declaration} = erx_schema:resolve_text(Text),
         ?assertEqual(Expected, Path),
         ?assertEqual({ok, Declaration}, erx_schema:resolve(Path))
     end || {Text, Expected} <- Texts].

%% Only the canonical spelling of a path is read; the rest are refused without an
%% atom made.
resolve_text_refusals_test() ->
    Atoms = erlang:system_info(atom_count),
    Unknown = [<<"things/03">>, <<"things/-0">>, <<"things/+3">>, <<"things/10">>, <<"things/x">>,
               <<"named/a.b">>, <<"named/%41">>, <<"named/%2e">>, <<"named/%2">>, <<"named/%G0">>,
               <<"named/%C0%80">>, <<"named/123456789">>, <<"owners/0.1">>, <<"owners/0.1.2.3">>,
               <<"owners/<0.1.0>">>, <<"owners/00.1.0">>, <<"owners/0.4294967296.0">>,
               <<"never_seen_before_segment">>, <<"things/3/never_seen_either">>],
    [?assertEqual({error, unknown_path}, erx_schema:resolve_text(Text)) || Text <- Unknown],
    Seventeen = <<(binary:copy(<<"a/">>, 16))/binary, "a">>,
    Bad = [<<"//">>, <<"things//3">>, <<"things/3/">>, <<"//things">>, Seventeen,
           binary:copy(<<"a">>, 12305), "things", things],
    [?assertEqual({error, bad_path}, erx_schema:resolve_text(Text)) || Text <- Bad],
    ?assertEqual(Atoms, erlang:system_info(atom_count)).

record(Overrides) ->
    maps:merge(#{schema => 7, path => [things, 3], kind => thing, id => 3,
                 attrs => #{count => {kernel, {ok, 99}}, name => {runtime, {partial, <<"n">>}}},
                 children => [secret]}, Overrides).

validate_record_test() ->
    {ok, Checked} = erx_schema:validate_record(record(#{})),
    ?assertEqual(#{count => {kernel, {error, invalid}}, name => {runtime, {partial, <<"n">>}}},
                 maps:get(attrs, Checked)),
    ?assertMatch({ok, _}, erx_schema:validate_record(record(#{children => {partial, []}}))),
    ?assertMatch({ok, _}, erx_schema:validate_record(record(#{children => unknown}))),
    ?assertEqual({error, schema}, erx_schema:validate_record(record(#{schema => 1}))),
    ?assertEqual({error, kind}, erx_schema:validate_record(record(#{kind => listing}))),
    ?assertEqual({error, unknown_path}, erx_schema:validate_record(record(#{path => [things, 10]}))),
    ?assertEqual({error, children}, erx_schema:validate_record(record(#{children => [other]}))),
    ?assertEqual({error, children}, erx_schema:validate_record(record(#{children => [secret | x]}))),
    ?assertEqual({error, children}, erx_schema:validate_record(record(#{children => [secret, secret]}))),
    ?assertEqual({error, malformed}, erx_schema:validate_record(record(#{attrs => #{count => kernel}}))),
    ?assertEqual({error, reporter},
                 erx_schema:validate_record(record(#{attrs => #{secret => {kernel, unknown}}}))),
    ?assertEqual({error, unknown_attribute},
                 erx_schema:validate_record(record(#{attrs => #{missing => {kernel, unknown}}}))),
    ?assertEqual({error, malformed}, erx_schema:validate_record(record(#{extra => 1}))),
    ?assertEqual({error, malformed}, erx_schema:validate_record([])),
    {ok, Listing} = erx_schema:validate_record(#{schema => 7, path => [things], kind => listing, id => none,
                                                 attrs => #{}, children => [0, 9]}),
    ?assertEqual([0, 9], maps:get(children, Listing)),
    ?assertEqual({error, children},
                 erx_schema:validate_record(#{schema => 7, path => [things], kind => listing, id => none,
                                              attrs => #{}, children => lists:seq(0, 9) ++ [10]})).
