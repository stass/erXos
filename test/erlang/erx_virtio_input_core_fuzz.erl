%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random device writes through erx_virtio_input_core, the virtio-input driver's pure
%% core: event records through event/1, the registers read for an axis through absinfo/1,
%% a device's axis reads through new/1, and streams of event records through
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
-define(ABSINFO_SIZE, 20).
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

%% One record, one axis read, and one device with a stream of records folded;
%% 1 for each of the record and the device that was taken.
round_of() ->
    Record = record(),
    Event = agree(event, [Record], fun erx_virtio_input_core:event/1, ref_event(Record)),
    Read = read(),
    agree(absinfo, [Read], fun erx_virtio_input_core:absinfo/1, ref_absinfo(Read)),
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

%% What the driver reads for one ABS_INFO query, as the device NIF reads SIZE, ABS_MIN and
%% ABS_MAX: usually a whole answer with bounds that cluster where the order and sign
%% matter, or zeros, which QEMU's device answers for an axis it lacks
%% (docs/research-virtio-input-qemu.md, fact 10); sometimes another size, and rarely what
%% no register holds.
read() ->
    Min = pick([0, -1, 5, ?INT32_MIN, rand:uniform(1 bsl 32) - (1 bsl 31)]),
    Max = pick([32767, 1, ?INT32_MAX, Min, Min - 1, rand:uniform(1 bsl 32) - (1 bsl 31)]),
    Words = {?ABSINFO_SIZE, Min band 16#ffffffff, Max band 16#ffffffff},
    pick([Words, Words, Words, Words, {0, 0, 0}, {0, 0, 0}, setelement(1, Words, rand:uniform(256) - 1),
          setelement(1, Words, pick([19, 21, 128, 255])), setelement(pick([1, 2, 3]), Words, pick([-1, 1 bsl 32, x])),
          {?ABSINFO_SIZE, Min}, <<?ABSINFO_SIZE, Min:32>>]).

%% The reads of a device: usually both queries answered with a well-formed read, otherwise
%% one of them missing or drawn as read/0 draws one.
device() ->
    Clean = maps:from_list([{Query, pick([{0, 0, 0}, clean_read()])} || Query <- ?QUERIES]),
    Query = pick(?QUERIES),
    pick([Clean, Clean, Clean, Clean, maps:remove(Query, Clean), Clean#{Query := read()}]).

clean_read() ->
    Min = pick([0, -100, rand:uniform(1 bsl 16) - 1]),
    {?ABSINFO_SIZE, Min band 16#ffffffff, (Min + rand:uniform(1 bsl 16)) band 16#ffffffff}.

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

%% SIZE 0 is no axis; any other SIZE must be one absinfo's (virtio 1.2, section 5.8.5.1),
%% and the bounds, signed, must be ordered. A read whose parts no register holds is refused.
ref_absinfo({Size, Min, Max} = Read) ->
    case lists:all(fun({Value, Bits}) -> is_integer(Value) andalso Value >= 0 andalso Value < 1 bsl Bits end,
                   [{Size, 8}, {Min, 32}, {Max, 32}]) of
        false -> {error, {read, Read}};
        true when Size =:= 0 -> {ok, none};
        true when Size =/= ?ABSINFO_SIZE -> {error, {size, Size}};
        true ->
            case {signed(Min), signed(Max)} of
                {Low, High} when Low < High -> {ok, {Low, High}};
                {Low, High} -> {error, {range, Low, High}}
            end
    end;
ref_absinfo(Read) -> {error, {read, Read}}.

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
        {ok, Read} ->
            case ref_absinfo(Read) of
                {ok, Axis} -> {ok, Axis};
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
