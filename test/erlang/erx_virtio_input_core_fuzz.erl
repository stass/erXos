%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random device writes through erx_virtio_input_core, the virtio-input driver's pure
%% core: event records through event/1, configuration space through config/3 and
%% absinfo/1, a device's axis reads through new/1, and streams of event records through
%% fold/2. Whatever arrives, no call raises, and each answer equals the reference's below,
%% which reads every field by its byte position with binary:decode_unsigned/2 and judges it
%% against the numbers of section 5.8 of the virtio 1.2 specification, evdev's codes and a
%% record's bounds ("Input events" of docs/design-display.md), written out here. Every
%% record the fold sends lies within erx_input:record()'s bounds, and its state never grows
%% past the size it had when new/1 made it, so it holds no event however long a stream
%% runs. Lengths, types, codes, values and sizes cluster at the values that matter, so
%% every path is common. The seed comes from make check-fuzz.

-module(erx_virtio_input_core_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(EVENT_SIZE, 8).
-define(CONFIG_SIZE, 136).
-define(DATA_MAX, 128).
-define(ABS_INFO, 16#12).
-define(QUERIES, [{?ABS_INFO, 0}, {?ABS_INFO, 1}]).
-define(INT32_MIN, -16#80000000).
-define(INT32_MAX, 16#7fffffff).
-define(AXIS_MAX, 65535).
-define(WHEEL_MIN, -128).
-define(WHEEL_MAX, 127).
%% The longest stream of event records one round folds.
-define(STREAM_MAX, 48).
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

%% One record, one configuration read, and one device with a stream of records folded;
%% 1 for each of the record and the device that was taken.
round_of() ->
    Record = record(),
    Event = agree(event, [Record], fun erx_virtio_input_core:event/1, ref_event(Record)),
    Query = pick(?QUERIES ++ [{1, 0}, {rand:uniform(256) - 1, rand:uniform(256) - 1}]),
    Block = block(Query, data(Query)),
    Config = agree(config, [Block], fun erx_virtio_input_core:config/1, ref_config(Block)),
    case Config of
        {ok, Data} -> agree(absinfo, [Data], fun erx_virtio_input_core:absinfo/1, ref_absinfo(Data));
        _ -> ok
    end,
    Reads = device(),
    {taken(Event), fold_stream(Reads)}.

taken({ok, _}) -> 1;
taken(_) -> 0.

%% new/1 on Reads, which must accept or refuse as the reference does; then, for a fold it
%% made, a stream of records ending in a SYN_REPORT, so what the fold kept is sent. Each
%% step's records must lie within a record's bounds and its state within the size new/1
%% gave it; at the end, every record sent and the counts must be the reference's, so a
%% fault that a step's bounds catch is not reported as a mere difference first.
fold_stream(Reads) ->
    Want = ref_new(Reads),
    case {said(new, [Reads], fun erx_virtio_input_core:new/1), Want} of
        {{ok, Fold}, {ok, Model}} ->
            Size = erts_debug:flat_size(Fold),
            Stream = [fold_event() || _ <- lists:seq(1, rand:uniform(?STREAM_MAX))] ++ [<<0:64>>],
            {Last, Sent} = lists:foldl(fun(Bytes, {F, Acc}) -> fold_one(Bytes, F, Size, Acc) end,
                                       {Fold, []}, Stream),
            {LastModel, Wanted} = lists:foldl(fun(Bytes, {M, Acc}) ->
                                                      {Records, Next} = ref_fold(Bytes, M),
                                                      {Next, lists:reverse(Records, Acc)}
                                              end, {Model, []}, Stream),
            Sent =:= Wanted
                orelse error({disagrees_with_reference, fold, lists:reverse(Sent), lists:reverse(Wanted), Stream}),
            agree(counts, [Last], fun erx_virtio_input_core:counts/1, maps:get(counts, LastModel)),
            1;
        {Said, Want} when Said =:= Want -> 0;
        {Said, Want} -> error({disagrees_with_reference, new, Said, Want, Reads})
    end.

%% One step of the fold, its records added to Sent, newest first.
fold_one(Bytes, Fold, Size, Sent) ->
    {Records, Next} = said(fold, [Bytes, Fold], fun erx_virtio_input_core:fold/2),
    [error({out_of_bounds, Record, Bytes}) || Record <- Records, not in_bounds(Record)],
    erts_debug:flat_size(Next) =< Size orelse error({state_grew, Size, Next, Bytes}),
    {Next, lists:reverse(Records, Sent)}.

%% The core's answer, which must be the reference's; a raise is a failure as well.
agree(Name, Args, Fun, Want) ->
    Said = said(Name, Args, Fun),
    case Said =:= Want of
        true -> Said;
        false -> error({disagrees_with_reference, Name, Said, Want, Args})
    end.

said(Name, Args, Fun) ->
    try apply(Fun, Args)
    catch Class:Reason -> error({crashed, Name, Class, Reason, Args})
    end.

%% erx_input:record()'s bounds.
in_bounds({pointer, rel, DX, DY}) -> int32(DX) andalso int32(DY);
in_bounds({pointer, abs, X, Y}) -> axis(X) andalso axis(Y);
in_bounds({key, Edge, Code}) -> lists:member(Edge, [down, up]) andalso Code >= 0 andalso Code =< 16#2ff;
in_bounds({wheel, Steps}) -> is_integer(Steps) andalso Steps >= ?WHEEL_MIN andalso Steps =< ?WHEEL_MAX;
in_bounds(release) -> true;
in_bounds(_) -> false.

int32(V) -> is_integer(V) andalso V >= ?INT32_MIN andalso V =< ?INT32_MAX.
axis(V) -> is_integer(V) andalso V >= 0 andalso V =< ?AXIS_MAX.

%% Generators.

record() ->
    Type = pick([0, 1, 1, 2, 2, 3, 3, 4, 16#11, rand:uniform(16#10000) - 1]),
    Code = pick([0, 1, 2, 3, 6, 8, 30, 16#ff, 16#100, 16#110, 16#14a, 16#2ff, 16#300, rand:uniform(16#10000) - 1]),
    Whole = <<Type:16/little, Code:16/little, (value()):32/little-signed, (rand:bytes(?EVENT_SIZE))/binary>>,
    binary:part(Whole, 0, pick([8, 8, 8, 8, 0, 1, 7, 9, 16, rand:uniform(17) - 1])).

value() -> pick([0, 1, 2, 3, -1, 127, -128, 1000, ?INT32_MIN, ?INT32_MAX, rand:uniform(1 bsl 32) - (1 bsl 31)]).

%% A record of a stream: mostly the events the fold uses, sometimes anything record/0 draws.
fold_event() ->
    {Type, Code, Value} = pick([{0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 3, 0},
                                {1, pick([30, 16#110, 16#2ff]), pick([0, 1, 1, 2])},
                                {2, pick([0, 1, 8]), value()}, {2, pick([0, 1, 8]), value()},
                                {3, pick([0, 1]), value()}, {3, pick([0, 1]), value()}]),
    pick([<<Type:16/little, Code:16/little, Value:32/little-signed>>, record()]).

%% A configuration read for Query: usually its own header and a size within the data area,
%% sometimes another query's header, a size past the data area or a read of another length.
block({Select, Subsel}, Data) ->
    {SaidSelect, SaidSubsel} = pick([{Select, Subsel}, {Select, Subsel}, {Select, Subsel}, {Select, Subsel},
                                     {Select, Subsel bxor 1}, {rand:uniform(256) - 1, Subsel}]),
    Size = pick([byte_size(Data), byte_size(Data), byte_size(Data), 0, 128, 129, 255, rand:uniform(256) - 1]),
    Whole = <<SaidSelect:8, SaidSubsel:8, Size:8, (rand:bytes(5))/binary, Data/binary,
              (rand:bytes(?DATA_MAX + 8 - byte_size(Data)))/binary>>,
    binary:part(Whole, 0, pick([136, 136, 136, 136, 136, 135, 137, 8, 0, rand:uniform(144) - 1])).

%% The data of an answer: an axis, often a wide or a narrow one, or random bytes.
data({?ABS_INFO, _}) ->
    Min = pick([0, -1, 5, ?INT32_MIN, rand:uniform(1 bsl 32) - (1 bsl 31)]),
    Max = pick([32767, 1, ?INT32_MAX, Min, Min - 1, rand:uniform(1 bsl 32) - (1 bsl 31)]),
    Whole = <<Min:32/little-signed, Max:32/little-signed, (rand:bytes(16))/binary>>,
    binary:part(Whole, 0, pick([20, 20, 20, 20, 20, 0, 0, 19, 24]));
data(_) -> rand:bytes(rand:uniform(?DATA_MAX + 1) - 1).

%% The reads of a device: usually both queries answered with a well-formed read, otherwise
%% one of them missing or drawn as block/2 draws a read. A well-formed read takes one of
%% the forms the facts record gives QEMU's (docs/research-virtio-input-qemu.md, facts 10
%% and 11): an area of zeros, header included, for a query the device has nothing for, or
%% an answer whose bytes past its size read as 0xff; or the query echoed and zeros after.
device() ->
    Clean = maps:from_list([{Query, clean_block(Query, data(Query))} || Query <- ?QUERIES]),
    Query = pick(?QUERIES),
    pick([Clean, Clean, Clean, Clean, maps:remove(Query, Clean), Clean#{Query := block(Query, data(Query))}]).

clean_block({Select, Subsel}, Data) ->
    Size = byte_size(Data),
    pick([<<0:(?CONFIG_SIZE * 8)>>,
          <<Select:8, Subsel:8, Size:8, 0:40, Data/binary, (binary:copy(<<16#ff>>, ?DATA_MAX - Size))/binary>>,
          <<Select:8, Subsel:8, Size:8, 0:40, Data/binary, 0:((?DATA_MAX - Size) * 8)>>]).

pick(List) -> lists:nth(rand:uniform(length(List)), List).

%% The reference.

ref_event(Bytes) when byte_size(Bytes) =/= ?EVENT_SIZE -> {error, {length, byte_size(Bytes)}};
ref_event(Bytes) -> judge(word(Bytes, 0, 2), word(Bytes, 2, 2), signed(word(Bytes, 4, 4))).

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

%% Only the size byte counts (virtio 1.2, section 5.8.5.1), whatever the header names.
ref_config(Bytes) when byte_size(Bytes) =/= ?CONFIG_SIZE -> {error, {length, byte_size(Bytes)}};
ref_config(Bytes) ->
    case binary:at(Bytes, 2) of
        Size when Size =< ?DATA_MAX -> {ok, binary:part(Bytes, 8, Size)};
        Size -> {error, {size, Size}}
    end.

ref_absinfo(Data) when byte_size(Data) =/= 20 -> {error, {absinfo, Data}};
ref_absinfo(Data) ->
    case {signed(word(Data, 0, 4)), signed(word(Data, 4, 4))} of
        {Min, Max} when Min < Max -> {ok, {Min, Max}};
        _ -> {error, {absinfo, Data}}
    end.

%% The fold's model: the device's ranges, whether it skips to the next report, the
%% update's relative and wheel sums and whether it moved, the position and the counts.
ref_new(Reads) ->
    case {ref_axis({?ABS_INFO, 0}, Reads), ref_axis({?ABS_INFO, 1}, Reads)} of
        {{ok, X}, {ok, Y}} ->
            Axes = case {X, Y} of {{_, _}, {_, _}} -> {X, Y}; _ -> none end,
            {ok, fresh(Axes, #{malformed => 0, unused => 0, skipped => 0})};
        {{error, _} = Error, _} -> Error;
        {_, Error} -> Error
    end.

fresh(Axes, Counts) ->
    #{axes => Axes, skipping => false, rel => {0, 0}, wheel => 0, moved => false, at => {none, none},
      counts => Counts}.

ref_axis(Query, Reads) ->
    case maps:find(Query, Reads) of
        error -> {error, {missing, Query}};
        {ok, Bytes} ->
            case ref_config(Bytes) of
                {ok, <<>>} -> {ok, none};
                {ok, Data} ->
                    case ref_absinfo(Data) of
                        {ok, Range} -> {ok, Range};
                        {error, Reason} -> {error, {Query, Reason}}
                    end;
                {error, Reason} -> {error, {Query, Reason}}
            end
    end.

ref_fold(Bytes, Model) -> model(ref_event(Bytes), Model).

model({error, _}, M) -> {[], bump(malformed, M)};
model(Event, #{skipping := true} = M) -> {[], (bump(skipped, M))#{skipping := Event =/= {ok, {syn, report}}}};
model({drop, _}, M) -> {[], bump(unused, M)};
model({ok, {syn, report}}, M) -> flush(M);
model({ok, {syn, dropped}}, #{axes := Axes, counts := Counts}) -> {[release], (fresh(Axes, Counts))#{skipping := true}};
model({ok, {key, _, repeat}}, M) -> {[], bump(unused, M)};
model({ok, {key, Code, Edge}}, M) ->
    {Sent, Next} = flush(M),
    {Sent ++ [{key, Edge, Code}], Next};
model({ok, {rel, wheel, V}}, #{wheel := W} = M) ->
    Steps = min(?WHEEL_MAX, max(?WHEEL_MIN, V)),
    case W + Steps of
        Sum when Sum >= ?WHEEL_MIN, Sum =< ?WHEEL_MAX -> {[], M#{wheel := Sum}};
        _ -> restarted(M, wheel, Steps)
    end;
model({ok, {rel, Axis, V}}, #{rel := {X, Y}} = M) ->
    {Sum, Fresh} = case Axis of x -> {{X + V, Y}, {V, 0}}; y -> {{X, Y + V}, {0, V}} end,
    case int32(element(1, Sum)) andalso int32(element(2, Sum)) of
        true -> {[], M#{rel := Sum}};
        false -> restarted(M, rel, Fresh)
    end;
model({ok, {abs, _, _}}, #{axes := none} = M) -> {[], bump(unused, M)};
model({ok, {abs, Axis, V}}, #{axes := {XRange, YRange}, at := {X, Y}} = M) ->
    At = case Axis of x -> {scaled(V, XRange), Y}; y -> {X, scaled(V, YRange)} end,
    {[], M#{at := At, moved := true}}.

%% A sum that would leave its range: everything kept is sent, and the sum starts again
%% at Value.
restarted(M, Sum, Value) ->
    {Sent, Next} = flush(M),
    {Sent, Next#{Sum := Value}}.

%% Each axis's value as a fraction of its range, clamped to it, in 65535ths rounded down.
scaled(V, {Min, _Max}) when V =< Min -> 0;
scaled(V, {_Min, Max}) when V >= Max -> ?AXIS_MAX;
scaled(V, {Min, Max}) -> ((V - Min) * ?AXIS_MAX) div (Max - Min).

flush(#{rel := Rel, at := At, moved := Moved, wheel := Wheel} = M) ->
    Move = [{pointer, rel, element(1, Rel), element(2, Rel)} || Rel =/= {0, 0}],
    Position = [{pointer, abs, element(1, At), element(2, At)}
                || Moved, element(1, At) =/= none, element(2, At) =/= none],
    Steps = [{wheel, Wheel} || Wheel =/= 0],
    {Move ++ Position ++ Steps, M#{rel := {0, 0}, wheel := 0, moved := false}}.

bump(Why, #{counts := Counts} = M) -> M#{counts := maps:update_with(Why, fun(N) -> N + 1 end, Counts)}.

word(Bytes, Offset, Size) -> binary:decode_unsigned(binary:part(Bytes, Offset, Size), little).

signed(Word) when Word >= 1 bsl 31 -> Word - (1 bsl 32);
signed(Word) -> Word.
