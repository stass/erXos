%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% The EUnit cases of erx_ui_wire, ui.txt's binary form, generated from
%% abi/formats/ui.txt; corpus/3, which writes the parity corpus that
%% test/host/erx_ui_wire_test.rb feeds to the generated Erlang, C and
%% TypeScript readers; and read_each/2 and read_corpus/2, the Erlang side of
%% that test's other comparisons.
-module(erx_ui_wire_tests).
-include_lib("eunit/include/eunit.hrl").
-export([corpus/3, read_each/2, read_corpus/2, present/2]).

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

%% A server record reads back as what the binary form carries of it.
server_records_read_back_test() ->
    Records = fixed() ++
        [{insert, 3, 0, 2, input, #{key => k, text => <<"caf", 16#e9/utf8>>, secret => true, on_submit => {app, term}}},
         {insert, 4, 3, 0, label, #{present => {group, 7}, text => {kernel, {timeout, 30}}}},
         {insert, 5, 3, 1, label, #{text => {{stopgap, liberx_pool}, {error, gone}}, present => {service, unknown}}},
         {set, 4, #{text => {runtime, {partial, <<"p">>}}, visible => false}, [width, key, text]}],
    Stream = iolist_to_binary([encode(Record) || Record <- Records]),
    ?assertEqual([meaning(Record) || Record <- Records], read_all_server(Stream)).

every_strict_prefix_of_a_server_record_is_more_test() ->
    Bytes = encode({insert, 9, 1, 0, label, #{text => <<"hello">>}}),
    [?assertEqual(more, erx_ui_wire:read_server(binary:part(Bytes, 0, N))) || N <- lists:seq(0, byte_size(Bytes) - 1)].

%% test/host/erx_ui_wire_test.rb checks every reason against the C and
%% TypeScript readers; these are the ones only the Erlang reader's clauses
%% decide apart from the cursor's reads.
server_refusals_test_() ->
    Read = fun(Body) -> erx_ui_wire:read_server(frame(Body)) end,
    [?_assertEqual({error, bad_length}, erx_ui_wire:read_server(<<0:32, 5>>)),
     ?_assertEqual({error, bad_length}, erx_ui_wire:read_server(<<65025:32/little, 1>>)),
     ?_assertEqual({error, unknown_tag}, Read(<<6, 1:32/little, 24, 0>>)),
     ?_assertEqual({error, unknown_tag}, Read(<<10, 0:64>>)),
     ?_assertEqual({error, bytes_left_over}, Read(<<5, 0>>)),
     ?_assertEqual({error, bad_node}, Read(<<2, 0:32>>)),
     ?_assertEqual({error, unknown_property}, Read(<<3, 1:32/little, 0, 1, 1>>)),
     ?_assertEqual({error, property_twice}, Read(<<3, 1:32/little, 0, 2, 2, 2>>)),
     ?_assertEqual({error, short_record}, Read(<<8, 3>>)),
     ?_assertEqual({error, bad_rune}, Read(<<8, 2, 1, 0:16, 16#110000:32/little>>))].

read_all_server(<<>>) -> [];
read_all_server(Bytes) ->
    {ok, Record, Rest} = erx_ui_wire:read_server(Bytes),
    [Record | read_all_server(Rest)].

%% What a reader makes of Record's bytes: no key; an event property as true;
%% a presentation as its type's name and canonical text; an error without its
%% reason; a set's removals in number order, each once.
meaning({insert, Node, Parent, Index, Kind, Props}) -> {insert, Node, Parent, Index, Kind, meaning(Props)};
meaning({set, Node, Changed, Removed}) ->
    Numbered = lists:usort([{number(Name), Name} || Name <- Removed, Name =/= key]),
    {set, Node, meaning(Changed), [Name || {_Number, Name} <- Numbered]};
meaning(Props) when is_map(Props) ->
    #{Name => carried_meaning(Name, Value) || Name := Value <- Props, Name =/= key};
meaning(Record) -> Record.

carried_meaning(Name, {Reporter, Carried}) when Reporter =:= kernel; Reporter =:= service; Reporter =:= runtime;
                                               element(1, Reporter) =:= stopgap ->
    case Carried of
        {ok, Value} -> {Reporter, {ok, value_meaning(Name, Value)}};
        {partial, Value} -> {Reporter, {partial, value_meaning(Name, Value)}};
        {error, _Reason} -> {Reporter, error};
        _ -> {Reporter, Carried}
    end;
carried_meaning(Name, Value) -> value_meaning(Name, Value).

value_meaning(Name, Value) ->
    case erx_ui_schema:property(Name) of
        #{type := event} -> true;
        #{type := presentation} -> {Type, Of} = Value, {atom_to_binary(Type), present(Type, Of)};
        _ -> Value
    end.

number(Name) -> maps:get(number, erx_ui_schema:property(Name)).

read_all(<<>>) -> [];
read_all(Bytes) ->
    {ok, Record, Rest} = erx_ui_wire:read(Bytes),
    [Record | read_all(Rest)].

frame(Body) -> <<(byte_size(Body)):32/little, Body/binary>>.

%% --- The parity corpus ------------------------------------------------------

-doc """
Writes random server records to StreamPath in the binary form, reads the
stream back with erx_ui_wire:read_server/1, which must read what each
record means, and writes to ReadPath one line per record naming what it
read: kinds, properties and enum members by name, texts in hex. The Ruby
test maps the names to numbers through the ABI model and compares the lines
with the C and TypeScript readers'.
""".
corpus(StreamPath, ReadPath, Seed) ->
    rand:seed(exsss, {Seed, 3, 5}),
    Records = [record() || _ <- lists:seq(1, 600)] ++ fixed(),
    Stream = iolist_to_binary([encode(Record) || Record <- Records]),
    Read = read_all_server(Stream),
    Read =:= [meaning(Record) || Record <- Records] orelse error(read_is_not_the_meaning),
    ok = file:write_file(StreamPath, Stream),
    ok = file:write_file(ReadPath, [[line(Record), $\n] || Record <- Read]).

-doc """
Reads the server records of StreamPath one by one as the C harness's "each"
mode does and writes a line for each to OutPath: what it read, "refused:
REASON" with the reason in the C reader's words, then on with the record
after the bytes its length word counts, stopping at a bad length or at
"more".
""".
read_each(StreamPath, OutPath) ->
    {ok, Stream} = file:read_file(StreamPath),
    ok = file:write_file(OutPath, [[Line, $\n] || Line <- each(Stream)]).

each(<<>>) -> [];
each(Bytes) ->
    case erx_ui_wire:read_server(Bytes) of
        {ok, Record, Rest} -> [line(Record) | each(Rest)];
        more -> ["more"];
        {error, bad_length} -> ["refused: bad length"];
        {error, Reason} ->
            <<Length:32/little, _:Length/binary, Rest/binary>> = Bytes,
            ["refused: " ++ string:replace(atom_to_list(Reason), "_", " ", all) | each(Rest)]
    end.

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
%% A value of a presentation the inspection schema marks, within its id's type.
value(presentation) -> {pick([group, budget, domain]), rand:uniform(16#ffffffff)}.

text(Max) ->
    Characters = [pick([$a, $\n, 0, 16#e9, 16#20ac, 16#1f600]) || _ <- lists:seq(1, rand:uniform(12))],
    Text = unicode:characters_to_binary(Characters),
    pick([<<>>, Text, binary:copy(<<"x">>, Max)]).

pick(List) -> lists:nth(rand:uniform(length(List)), List).

%% One record as read, in the line format the C harness prints, with names
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
carried(error, R, S, _Type) -> lists:concat(["5,", R, ",", S, ",0:-"]).

value_text({integer, _, _}, V) -> integer_to_list(V);
value_text(boolean, V) -> atom_to_list(V);
value_text({enum, _}, V) -> atom_to_list(V);
value_text({image, _}, V) -> atom_to_list(V);
value_text({text, _}, V) -> hex(V);
value_text({bytes, _}, V) -> hex(V);
value_text({list, _, _}, V) -> "[" ++ lists:join(",", [hex(T) || T <- V]) ++ "]";
value_text(event, _V) -> "-";
value_text(presentation, {Name, Text}) -> hex(Name) ++ ":" ++ hex(Text).

-doc """
Reads the stream of event and pixels records that the C harness's writer
wrote to StreamPath and writes, to OutPath, one line per record naming what
erx_ui_wire:read/1 read: the event by name, the detail as none, true, false,
an integer or a text in hex, and the pixels in hex. The Ruby test maps the
names to numbers and compares the lines with what the writer says it wrote.
""".
read_corpus(StreamPath, OutPath) ->
    {ok, Stream} = file:read_file(StreamPath),
    ok = file:write_file(OutPath, [[read_line(Record), $\n] || Record <- read_all(Stream)]).

read_line({event, Node, Event, Detail}) ->
    join(["event", integer_to_list(Node), atom_to_list(Event), detail_text(Detail)]);
read_line({pixels, X, Y, Width, Height, Pixels}) ->
    join(["pixels" | [integer_to_list(N) || N <- [X, Y, Width, Height]]] ++ [hex(Pixels)]).

detail_text(Detail) when is_atom(Detail) -> atom_to_list(Detail);
detail_text(Detail) when is_integer(Detail) -> integer_to_list(Detail);
detail_text(Detail) when is_binary(Detail) -> hex(Detail).

hex(Binary) -> "x" ++ binary_to_list(binary:encode_hex(Binary, lowercase)).

join(Tokens) -> lists:join(" ", Tokens).
