%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random device writes through erx_virtio_input_core, the virtio-input driver's parse of
%% what the device wrote: event records through event/1, configuration space through
%% config/3, bits/1 and absinfo/1, and whole sets of configuration reads through
%% identify/1. Whatever arrives, no call raises, and each answer equals the reference's
%% below, which reads every field by its byte position with binary:decode_unsigned/2 and
%% judges it against the numbers of section 5.8 of the virtio 1.2 specification and
%% evdev's codes, written out here. Lengths, types, codes, values and sizes cluster at the
%% values that matter, so every path is common. The seed comes from make check-fuzz.

-module(erx_virtio_input_core_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(EVENT_SIZE, 8).
-define(CONFIG_SIZE, 136).
-define(DATA_MAX, 128).
-define(EV_BITS, 16#11).
-define(ABS_INFO, 16#12).
-define(QUERIES, [{?EV_BITS, 1}, {?EV_BITS, 2}, {?EV_BITS, 3}, {?ABS_INFO, 0}, {?ABS_INFO, 1}]).
%% The fewest rounds whose event, and whose device, must be taken, so an edit to the
%% generator cannot leave the accepting paths untried.
-define(MIN_ACCEPTED, ?ROUNDS div 20).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Counts = lists:foldl(fun(_, {Events, Devices}) ->
                                 {Event, Device} = round_of(),
                                 {Events + Event, Devices + Device}
                         end, {0, 0}, lists:seq(1, ?ROUNDS)),
    case Counts of
        {Events, Devices} when Events >= ?MIN_ACCEPTED, Devices >= ?MIN_ACCEPTED ->
            io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Events + Devices]);
        _ -> error({too_few_accepted, Counts})
    end.

%% One record, one configuration read and one device; 1 for each of the record and the
%% device that was taken.
round_of() ->
    Record = record(),
    Event = agree(event, [Record], fun erx_virtio_input_core:event/1, ref_event(Record)),
    {Select, Subsel} = Query = pick(?QUERIES ++ [{1, 0}, {rand:uniform(256) - 1, rand:uniform(256) - 1}]),
    Block = block(Query, data(Query)),
    Config = agree(config, [Select, Subsel, Block], fun erx_virtio_input_core:config/3,
                   ref_config(Select, Subsel, Block)),
    case Config of
        {ok, Data} ->
            agree(bits, [Data], fun erx_virtio_input_core:bits/1, ref_bits(Data)),
            agree(absinfo, [Data], fun erx_virtio_input_core:absinfo/1, ref_absinfo(Data));
        _ -> ok
    end,
    Reads = device(),
    Device = agree(identify, [Reads], fun erx_virtio_input_core:identify/1, ref_identify(Reads)),
    {taken(Event), taken(Device)}.

taken({ok, _}) -> 1;
taken(_) -> 0.

%% The core's answer, which must be the reference's; a raise is a failure as well.
agree(Name, Args, Fun, Want) ->
    Said = try apply(Fun, Args)
           catch Class:Reason -> error({crashed, Name, Class, Reason, Args})
           end,
    case Said =:= Want of
        true -> Said;
        false -> error({disagrees_with_reference, Name, Said, Want, Args})
    end.

%% Generators.

record() ->
    Type = pick([0, 1, 1, 2, 2, 3, 3, 4, 16#11, rand:uniform(16#10000) - 1]),
    Code = pick([0, 1, 2, 3, 6, 8, 30, 16#ff, 16#100, 16#110, 16#14a, 16#2ff, 16#300, rand:uniform(16#10000) - 1]),
    Value = pick([0, 1, 2, 3, -1, -16#80000000, 16#7fffffff, rand:uniform(1 bsl 32) - (1 bsl 31)]),
    Whole = <<Type:16/little, Code:16/little, Value:32/little-signed, (rand:bytes(?EVENT_SIZE))/binary>>,
    binary:part(Whole, 0, pick([8, 8, 8, 8, 0, 1, 7, 9, 16, rand:uniform(17) - 1])).

%% A configuration read for Query: usually its own header and a size within the data area,
%% sometimes another query's header, a size past the data area or a read of another length.
block({Select, Subsel}, Data) ->
    {SaidSelect, SaidSubsel} = pick([{Select, Subsel}, {Select, Subsel}, {Select, Subsel}, {Select, Subsel},
                                     {Select, Subsel bxor 1}, {rand:uniform(256) - 1, Subsel}]),
    Size = pick([byte_size(Data), byte_size(Data), byte_size(Data), 0, 128, 129, 255, rand:uniform(256) - 1]),
    Whole = <<SaidSelect:8, SaidSubsel:8, Size:8, (rand:bytes(5))/binary, Data/binary,
              (rand:bytes(?DATA_MAX + 8 - byte_size(Data)))/binary>>,
    binary:part(Whole, 0, pick([136, 136, 136, 136, 136, 135, 137, 8, 0, rand:uniform(144) - 1])).

%% The data of an answer: a bitmap of codes the classes use, an axis, or random bytes.
data({?EV_BITS, _}) ->
    pick([bitmap(lists:usort([pick([0, 1, 8, 30, 16#ff, 16#100, 16#110, 16#111, 16#14a, 16#2ff, rand:uniform(1024) - 1])
                              || _ <- lists:seq(1, rand:uniform(4) - 1)])),
          <<>>, rand:bytes(rand:uniform(?DATA_MAX))]);
data({?ABS_INFO, _}) ->
    Min = pick([0, -1, 5, rand:uniform(1 bsl 32) - (1 bsl 31)]),
    Max = pick([32767, Min, Min - 1, rand:uniform(1 bsl 32) - (1 bsl 31)]),
    Whole = <<Min:32/little-signed, Max:32/little-signed, (rand:bytes(16))/binary>>,
    binary:part(Whole, 0, pick([20, 20, 20, 0, 19, 24]));
data(_) -> rand:bytes(rand:uniform(?DATA_MAX + 1) - 1).

bitmap([]) -> <<>>;
bitmap(Codes) ->
    << <<(lists:sum([1 bsl (Code rem 8) || Code <- Codes, Code div 8 =:= Index])):8>>
       || Index <- lists:seq(0, lists:max(Codes) div 8) >>.

%% The reads of a device: usually every query answered with a well-formed read, otherwise
%% one of them missing or drawn as block/2 draws a read.
device() ->
    Clean = maps:from_list([{Query, clean_block(Query, data(Query))} || Query <- ?QUERIES]),
    Query = pick(?QUERIES),
    pick([Clean, Clean, Clean, maps:remove(Query, Clean), Clean#{Query := block(Query, data(Query))}]).

clean_block({Select, Subsel}, Data) ->
    <<Select:8, Subsel:8, (byte_size(Data)):8, 0:40, Data/binary, 0:((?DATA_MAX - byte_size(Data)) * 8)>>.

pick(List) -> lists:nth(rand:uniform(length(List)), List).

%% The reference.

ref_event(Bytes) when byte_size(Bytes) =/= ?EVENT_SIZE -> {error, {length, byte_size(Bytes)}};
ref_event(Bytes) ->
    Type = word(Bytes, 0, 2),
    Code = word(Bytes, 2, 2),
    Raw = word(Bytes, 4, 4),
    Value = case Raw >= 1 bsl 31 of true -> Raw - (1 bsl 32); false -> Raw end,
    judge(Type, Code, Value).

judge(0, 0, _) -> {ok, {syn, report}};
judge(0, 3, _) -> {ok, {syn, dropped}};
judge(0, Code, _) -> {drop, {syn, Code}};
judge(1, Code, Value) ->
    Direction = proplists:get_value(Value, [{0, up}, {1, down}, {2, repeat}]),
    case Code =< 16#2ff andalso Direction =/= undefined of
        true -> {ok, {key, Code, Direction}};
        false -> {drop, {key, Code, Value}}
    end;
judge(2, Code, Value) ->
    case proplists:get_value(Code, [{0, x}, {1, y}, {8, wheel}]) of
        undefined -> {drop, {rel, Code}};
        Axis -> {ok, {rel, Axis, Value}}
    end;
judge(3, Code, Value) ->
    case proplists:get_value(Code, [{0, x}, {1, y}]) of
        undefined -> {drop, {abs, Code}};
        Axis -> {ok, {abs, Axis, Value}}
    end;
judge(Type, _, _) -> {drop, {type, Type}}.

ref_config(_, _, Bytes) when byte_size(Bytes) =/= ?CONFIG_SIZE -> {error, {length, byte_size(Bytes)}};
ref_config(Select, Subsel, Bytes) ->
    case {binary:at(Bytes, 0), binary:at(Bytes, 1), binary:at(Bytes, 2)} of
        {Select, Subsel, Size} when Size =< ?DATA_MAX -> {ok, binary:part(Bytes, 8, Size)};
        {Select, Subsel, Size} -> {error, {size, Size}};
        {SaidSelect, SaidSubsel, _} -> {error, {query, {SaidSelect, SaidSubsel}}}
    end.

ref_bits(Data) ->
    [Code || Code <- lists:seq(0, byte_size(Data) * 8 - 1), (binary:at(Data, Code div 8) bsr (Code rem 8)) band 1 =:= 1].

ref_absinfo(Data) when byte_size(Data) < 20 -> {error, {absinfo, Data}};
ref_absinfo(Data) ->
    [Min, Max, Fuzz, Flat, Res] = [signed(word(Data, Offset, 4)) || Offset <- [0, 4, 8, 12, 16]],
    case Min < Max of
        true -> {ok, #{min => Min, max => Max, fuzz => Fuzz, flat => Flat, res => Res}};
        false -> {error, {absinfo, Data}}
    end.

ref_identify(Reads) ->
    case [answer(Query, Reads) || Query <- [{?EV_BITS, 1}, {?EV_BITS, 2}, {?EV_BITS, 3}]] of
        [{ok, Key}, {ok, Rel}, {ok, Abs}] ->
            [KeyCodes, RelCodes, AbsCodes] = [ref_bits(Data) || Data <- [Key, Rel, Abs]],
            Keys = [Code || Code <- KeyCodes, Code >= 1, Code =< 16#ff],
            %% Both axes are codes 0 and 1, for EV_ABS as for EV_REL; a tablet also has
            %% BTN_LEFT (16#110) or BTN_TOUCH (16#14a).
            Button = lists:member(16#110, KeyCodes) orelse lists:member(16#14a, KeyCodes),
            case {Button andalso ordsets:is_subset([0, 1], AbsCodes), ordsets:is_subset([0, 1], RelCodes), Keys} of
                {true, _, _} -> tablet(Reads);
                {false, true, _} -> {ok, mouse};
                {false, false, [_ | _]} -> {ok, keyboard};
                {false, false, []} -> {error, {class, KeyCodes, RelCodes, AbsCodes}}
            end;
        Answers -> hd([Error || {error, _} = Error <- Answers])
    end.

%% The X axis read and judged whole before the Y axis, so the first refusal is X's.
tablet(Reads) ->
    case {ref_axis({?ABS_INFO, 0}, Reads), ref_axis({?ABS_INFO, 1}, Reads)} of
        {{ok, X}, {ok, Y}} -> {ok, {tablet, X, Y}};
        {{error, _} = Error, _} -> Error;
        {_, Error} -> Error
    end.

ref_axis(Query, Reads) ->
    case answer(Query, Reads) of
        {ok, Data} ->
            case ref_absinfo(Data) of
                {ok, Axis} -> {ok, Axis};
                {error, Reason} -> {error, {Query, Reason}}
            end;
        Error -> Error
    end.

answer({Select, Subsel} = Query, Reads) ->
    case maps:find(Query, Reads) of
        error -> {error, {missing, Query}};
        {ok, Bytes} ->
            case ref_config(Select, Subsel, Bytes) of
                {ok, Data} -> {ok, Data};
                {error, Reason} -> {error, {Query, Reason}}
            end
    end.

word(Bytes, Offset, Size) -> binary:decode_unsigned(binary:part(Bytes, Offset, Size), little).

signed(Word) when Word >= 1 bsl 31 -> Word - (1 bsl 32);
signed(Word) -> Word.
