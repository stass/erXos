%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% The EUnit cases of erx_ui_wire, ui.txt's binary form, generated from
%% abi/formats/ui.txt, and corpus/3, which writes the parity corpus that
%% test/host/erx_ui_wire_test.rb feeds to the generated C reader.
-module(erx_ui_wire_tests).
-include_lib("eunit/include/eunit.hrl").
-export([corpus/3, present/2]).

%% The canonical text a test stands in for erx_present:text/2.
present(_Type, Value) -> iolist_to_binary(io_lib:format("~0p", [Value])).

encode(Record) -> erx_ui_wire:encode(Record, fun present/2).

event_and_pixels_round_trip_test() ->
    Records = [{event, 1, on_click, none}, {event, 7, on_change, true}, {event, 7, on_change, false},
               {event, 16#ffffffff, on_change, -16#80000000}, {event, 2, on_submit, <<"caf", 16#e9/utf8>>},
               {event, 3, on_select, <<>>}, {pixels, 0, 1, 2, 3, <<1, 2, 3, 4, 5, 6>>},
               {pixels, 65535, 65535, 0, 0, <<>>}],
    Stream = iolist_to_binary([encode(Record) || Record <- Records]),
    ?assertEqual(Records, read_all(Stream)).

every_strict_prefix_is_more_test() ->
    Bytes = encode({event, 9, on_submit, <<"hello">>}),
    [?assertEqual(more, erx_ui_wire:read(binary:part(Bytes, 0, N))) || N <- lists:seq(0, byte_size(Bytes) - 1)].

refusals_test_() ->
    Event = fun(Number, Detail) -> frame(<<6, 5:32/little, Number, Detail/binary>>) end,
    [?_assertEqual({error, bad_length}, erx_ui_wire:read(<<0:32, 6>>)),
     ?_assertEqual({error, bad_length}, erx_ui_wire:read(<<65537:32/little>>)),
     ?_assertEqual({error, bad_length}, erx_ui_wire:read(<<65025:32/little, 6>>)),
     %% A server's record arriving at the server is refused by tag.
     ?_assertEqual({error, bad_tag}, erx_ui_wire:read(encode(commit))),
     ?_assertEqual({error, bad_tag}, erx_ui_wire:read(encode(repaint))),
     ?_assertEqual({error, bad_tag}, erx_ui_wire:read(frame(<<11>>))),
     ?_assertEqual({error, bad_node}, erx_ui_wire:read(frame(<<6, 0:32, 24, 0>>))),
     %% 11 is text, a property but no event; 1 is the key, never written.
     ?_assertEqual({error, bad_event}, erx_ui_wire:read(Event(11, <<0>>))),
     ?_assertEqual({error, bad_event}, erx_ui_wire:read(Event(1, <<0>>))),
     ?_assertEqual({error, bad_detail}, erx_ui_wire:read(Event(24, <<1, 2>>))),
     ?_assertEqual({error, bad_detail}, erx_ui_wire:read(Event(24, <<0, 0>>))),
     ?_assertEqual({error, bad_detail}, erx_ui_wire:read(Event(24, <<3, 1:32/little, 16#ff>>))),
     ?_assertEqual({error, bad_detail}, erx_ui_wire:read(Event(24, <<4>>))),
     ?_assertEqual({error, bad_body}, erx_ui_wire:read(frame(<<10, 1, 2, 3>>))),
     ?_assertEqual({error, bad_body}, erx_ui_wire:read(frame(<<6, 1:32>>)))].

encoder_refuses_what_does_not_fit_test_() ->
    [?_assertError({bad_value, width}, encode({set, 1, #{width => 16385}, []})),
     ?_assertError({bad_value, text}, encode({set, 1, #{text => {{stopgap, nobody}, unknown}}, []})),
     ?_assertError({bad_kind, nothing}, encode({insert, 1, 0, 0, nothing, #{}})),
     ?_assertError({bad_record, _}, encode({move, 1, 65536})),
     ?_assertError({bad_value, 16#d800}, encode({input, {key, down, 1, 16#d800}})),
     ?_assertError({too_long, _}, encode({pixels, 0, 0, 1, 1, binary:copy(<<0>>, 65536)}))].

%% The key is never written, and a set's removals are in number order.
key_is_never_written_test() ->
    ?assertEqual(encode({insert, 4, 0, 0, label, #{}}), encode({insert, 4, 0, 0, label, #{key => k}})),
    ?assertEqual(<<9:32/little, 3, 4:32/little, 0, 2, 2, 11>>, encode({set, 4, #{}, [text, key, width]})).

read_all(<<>>) -> [];
read_all(Bytes) ->
    {ok, Record, Rest} = erx_ui_wire:read(Bytes),
    [Record | read_all(Rest)].

frame(Body) -> <<(byte_size(Body)):32/little, Body/binary>>.

%% --- The parity corpus ------------------------------------------------------

-doc """
Writes Count random server records to StreamPath in the binary form and, to
ExpectedPath, one line per record naming what it means: kinds, properties
and enum members by name, texts in hex. The Ruby test maps the names to
numbers through the ABI model and compares the lines with the C reader's.
""".
corpus(StreamPath, ExpectedPath, Seed) ->
    rand:seed(exsss, {Seed, 3, 5}),
    Records = [record() || _ <- lists:seq(1, 600)] ++ fixed(),
    ok = file:write_file(StreamPath, [encode(Record) || Record <- Records]),
    ok = file:write_file(ExpectedPath, [[line(Record), $\n] || Record <- Records]).

fixed() ->
    [commit, repaint, {screen, 0, 0, 0}, {screen, 65535, 65535, 16#ffffffff},
     {input, {pointer, 65535, 0, 255}}, {input, {key, up, 0, none}}, {input, {key, down, 65535, 16#10ffff}},
     {input, {wheel, -128}}, {input, {wheel, 127}}, {remove, 16#ffffffff}, {move, 1, 65535},
     {set, 1, #{}, []}].

record() ->
    Kinds = erx_ui_schema:kinds(),
    Kind = pick(Kinds),
    #{takes := Takes} = erx_ui_schema:kind(Kind),
    Node = rand:uniform(16#ffffffff),
    case rand:uniform(6) of
        1 -> {remove, Node};
        2 -> {move, Node, rand:uniform(65536) - 1};
        N when N =< 4 -> {insert, Node, rand:uniform(16#100000000) - 1, rand:uniform(65536) - 1, Kind, props(Takes)};
        _ ->
            Changed = props(Takes),
            Removed = [Name || Name <- Takes, Name =/= key, not is_map_key(Name, Changed), rand:uniform(3) =:= 1],
            {set, Node, Changed, Removed}
    end.

props(Takes) ->
    maps:from_list([{Name, prop_value(Name)} || Name <- Takes, Name =/= key, rand:uniform(2) =:= 1]).

prop_value(Name) ->
    #{type := Type, status := Status} = erx_ui_schema:property(Name),
    case Status andalso rand:uniform(2) =:= 1 of
        false -> value(Type);
        true ->
            Reporter = pick([kernel, service, runtime, {stopgap, liberx_pool}, {stopgap, liberx_trace}]),
            {Reporter, pick([{ok, value(Type)}, {partial, value(Type)}, unknown, unsupported,
                             {timeout, rand:uniform(16#ffffffff)}, {error, reason}])}
    end.

value({integer, Min, Max}) -> pick([Min, Max, Min + rand:uniform(Max - Min + 1) - 1]);
value({text, Max}) -> text(Max);
value({bytes, Max}) -> pick([<<>>, rand:bytes(rand:uniform(64)), rand:bytes(Max)]);
value({list, {text, TextMax}, Max}) -> [text(TextMax) || _ <- lists:seq(1, pick([0, 1, rand:uniform(8), Max]))];
value({enum, Atoms}) -> pick(Atoms);
value({image, Atoms}) -> pick(Atoms);
value(boolean) -> pick([true, false]);
value(event) -> true;
value(presentation) -> {pick([pid, port, binary]), rand:uniform(1000)}.

text(Max) ->
    Characters = [pick([$a, $\n, 0, 16#e9, 16#20ac, 16#1f600]) || _ <- lists:seq(1, rand:uniform(12))],
    Text = unicode:characters_to_binary(Characters),
    pick([<<>>, Text, binary:copy(<<"x">>, Max)]).

pick(List) -> lists:nth(rand:uniform(length(List)), List).

%% One record's meaning, in the line format the C harness prints, with names
%% where it prints numbers.
line({insert, Node, Parent, Index, Kind, Props}) ->
    join(["insert", integer_to_list(Node), integer_to_list(Parent), integer_to_list(Index), atom_to_list(Kind)
          | prop_tokens(Props)]);
line({set, Node, Changed, Removed}) ->
    join(["set", integer_to_list(Node) | prop_tokens(Changed)] ++ ["/" | [atom_to_list(Name) || Name <- Removed]]);
line({remove, Node}) -> join(["remove", integer_to_list(Node)]);
line({move, Node, Index}) -> join(["move", integer_to_list(Node), integer_to_list(Index)]);
line(commit) -> "commit";
line(repaint) -> "repaint";
line({screen, W, H, Chan}) -> join(["screen" | [integer_to_list(N) || N <- [W, H, Chan]]]);
line({input, {pointer, X, Y, Buttons}}) -> join(["pointer" | [integer_to_list(N) || N <- [X, Y, Buttons]]]);
line({input, {key, Direction, Code, Rune}}) ->
    join(["key", atom_to_list(Direction), integer_to_list(Code), case Rune of none -> "none"; _ -> integer_to_list(Rune) end]);
line({input, {wheel, Steps}}) -> join(["wheel", integer_to_list(Steps)]).

prop_tokens(Props) ->
    [atom_to_list(Name) ++ "=" ++ prop_text(Name, Value) || Name := Value <- Props, Name =/= key].

%% A status property: STATUS,REPORTER,STOPGAP,MS: and the value or "-".
prop_text(Name, Value) ->
    #{type := Type, status := Status} = erx_ui_schema:property(Name),
    case {Status, Value} of
        {true, {Reporter, Carried}} when Reporter =:= kernel; Reporter =:= service; Reporter =:= runtime;
                                        element(1, Reporter) =:= stopgap ->
            {Code, Stopgap} = reporter(Reporter),
            carried(Carried, Code, Stopgap, Type);
        {true, _} -> "0,0,,0:" ++ value_text(Type, Value);
        {false, _} -> value_text(Type, Value)
    end.

reporter(kernel) -> {"1", ""};
reporter(service) -> {"2", ""};
reporter(runtime) -> {"3", ""};
reporter({stopgap, Name}) -> {"4", atom_to_list(Name)}.

carried({ok, V}, R, S, Type) -> lists:concat(["0,", R, ",", S, ",0:", value_text(Type, V)]);
carried({partial, V}, R, S, Type) -> lists:concat(["1,", R, ",", S, ",0:", value_text(Type, V)]);
carried(unknown, R, S, _Type) -> lists:concat(["2,", R, ",", S, ",0:-"]);
carried(unsupported, R, S, _Type) -> lists:concat(["3,", R, ",", S, ",0:-"]);
carried({timeout, Ms}, R, S, _Type) -> lists:concat(["4,", R, ",", S, ",", Ms, ":-"]);
carried({error, _}, R, S, _Type) -> lists:concat(["5,", R, ",", S, ",0:-"]).

value_text({integer, _, _}, V) -> integer_to_list(V);
value_text(boolean, V) -> atom_to_list(V);
value_text({enum, _}, V) -> atom_to_list(V);
value_text({image, _}, V) -> atom_to_list(V);
value_text({text, _}, V) -> hex(V);
value_text({bytes, _}, V) -> hex(V);
value_text({list, _, _}, V) -> "[" ++ lists:join(",", [hex(T) || T <- V]) ++ "]";
value_text(event, _V) -> "-";
value_text(presentation, {Type, V}) -> hex(atom_to_binary(Type)) ++ ":" ++ hex(present(Type, V)).

hex(Binary) -> "x" ++ binary_to_list(binary:encode_hex(Binary, lowercase)).

join(Tokens) -> lists:join(" ", Tokens).
