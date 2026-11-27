%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The crash states of a recorded block trace (docs/design-crash-states.md, "The
%% construction" and "The generator", "States"). A pure module: it reads the trace
%% erx_ram_window records and the base image the run started from, and answers each
%% epoch's crash states, each a choice of one value per sector the epoch wrote.
%%
%% * **Epochs.** A flush answered `ok` ends an epoch and makes every write sent
%%   before it durable; a failed flush ends nothing. The last epoch runs to the end
%%   of the trace. A write is a value of its sectors whatever its answer.
%% * **Values.** For each sector the epoch writes, its values are the durable bytes
%%   first, then each distinct byte string the epoch wrote to it, in the order first
%%   written, each with the trace position where it was first written. A choice
%%   maps a sector to an index into its values, from 1; a sector it leaves out holds
%%   its durable bytes (index 0). Distinct choices are distinct images, so an epoch has M, the product of the
%%   value counts, states.
%% * **A state's earliest moment** is the latest first-written position among its
%%   chosen values, or the epoch's start when it chooses only durable bytes.
%% * **The bound.** An epoch of at most Bound states is enumerated whole,
%%   `exhaustive`. A larger one gives the in-order cuts, then every state with one
%%   sector left durable and the rest at their last value, whatever the bound; then
%%   states drawn without repeats from a seed derived from the run's seed and the
%%   epoch's index, until it holds Bound; it is `{sampled, N, M, Seed, Version}`.
%%   The order of the families and of the draw is this module's, so its version,
%%   the module's MD5, and the seed name the sample.
%%
%% Only the `atomic` device mode is built here; `torn` is refused.

-module(erx_crash_states).

-export([epochs/2, states/2, image/4, read_fun/3, version/0]).
-export_type([epoch/0, choice/0, state/0, coverage/0]).

-define(SECTOR, 512).

-type sector() :: non_neg_integer().
-type overlay() :: #{sector() => binary()}.
-type choice() :: #{sector() => non_neg_integer()}.
%% An epoch: its index from 1; its start, the trace position after which it begins
%% (0 for the first); its end, the position of the flush that closes it, or one
%% past the trace for the open last epoch; the sectors durable before it that differ
%% from the base; and each written sector's values with their first positions.
-type epoch() :: #{index := pos_integer(), start := non_neg_integer(), 'end' := pos_integer(),
                   durable := overlay(), values := #{sector() => [{binary(), non_neg_integer()}]},
                   writes := [{pos_integer(), sector(), binary()}]}.
-type state() :: #{choice := choice(), t := non_neg_integer()}.
-type coverage() :: exhaustive | {sampled, pos_integer(), pos_integer(), integer(), binary()}.

%% The generator's version: this module's MD5, in hex.
-spec version() -> binary().
version() -> binary:encode_hex(?MODULE:module_info(md5), lowercase).

%% The epochs of Trace over Base, the image the run started from.
-spec epochs(erx_ram_window:trace(), binary()) -> [epoch()].
epochs(Trace, Base) ->
    epochs(lists:enumerate(Trace), Base, open(1, 0, #{}, length(Trace) + 1), []).

epochs([], Base, Epoch, Acc) ->
    lists:reverse([closed(Epoch, Base) | Acc]);
epochs([{Pos, {flush, ok}} | Rest], Base, #{index := I, 'end' := TraceEnd} = Epoch, Acc) ->
    Closed = closed(Epoch#{'end' := Pos}, Base),
    epochs(Rest, Base, open(I + 1, Pos, durable_after(Closed), TraceEnd), [Closed | Acc]);
epochs([{Pos, {write, Lba, Bytes, _Answer}} | Rest], Base, #{writes := Writes} = Epoch, Acc) ->
    Placed = [{Pos, Lba + I, Sector} || {I, Sector} <- lists:enumerate(0, split(Bytes))],
    epochs(Rest, Base, Epoch#{writes := lists:reverse(Placed, Writes)}, Acc);
epochs([{_Pos, _FailedFlushOrMark} | Rest], Base, Epoch, Acc) ->
    epochs(Rest, Base, Epoch, Acc).

%% An epoch from Start, ending at TraceEnd, one past the trace, until a flush closes it.
open(Index, Start, Durable, TraceEnd) ->
    #{index => Index, start => Start, 'end' => TraceEnd, durable => Durable, writes => []}.

%% The epoch with its writes in order and each sector's values.
closed(#{start := Start, durable := Durable, writes := Reversed} = Epoch, Base) ->
    Writes = lists:reverse(Reversed),
    Values = lists:foldl(fun({Pos, Lba, Bytes}, Acc) ->
                                 Known = maps:get(Lba, Acc, [{durable_sector(Durable, Base, Lba), Start}]),
                                 case lists:keymember(Bytes, 1, Known) of
                                     true -> Acc#{Lba => Known};
                                     false -> Acc#{Lba => Known ++ [{Bytes, Pos}]}
                                 end
                         end, #{}, Writes),
    Epoch#{writes := Writes, values => Values}.

%% The durable sectors after Epoch: every write of it applied in order.
durable_after(#{durable := Durable, writes := Writes}) ->
    lists:foldl(fun({_Pos, Lba, Bytes}, Acc) -> Acc#{Lba => Bytes} end, Durable, Writes).

durable_sector(Durable, Base, Lba) ->
    case Durable of
        #{Lba := Bytes} -> Bytes;
        #{} -> binary:part(Base, Lba * ?SECTOR, ?SECTOR)
    end.

split(<<>>) -> [];
split(<<Sector:?SECTOR/binary, Rest/binary>>) -> [Sector | split(Rest)].

%% ---------------------------------------------------------------------------
%% The states of one epoch
%% ---------------------------------------------------------------------------

%% Epoch's states under Options: mode (atomic), bound and seed.
-spec states(epoch(), #{mode := atomic | torn, bound := pos_integer(), seed := integer()}) ->
          #{count := pos_integer(), coverage := coverage(), states := [state()]} | {error, {unsupported_mode, torn}}.
states(_Epoch, #{mode := torn}) ->
    {error, {unsupported_mode, torn}};
states(#{values := Values} = Epoch, #{mode := atomic, bound := Bound, seed := Seed}) ->
    Sizes = [{Lba, length(Vs)} || {Lba, Vs} <- lists:sort(maps:to_list(Values))],
    Count = lists:foldl(fun({_, N}, Acc) -> N * Acc end, 1, Sizes),
    {Coverage, Choices} = case Count =< Bound of
                              true -> {exhaustive, every_choice(Sizes)};
                              false -> sampled(Epoch, Sizes, Count, Bound, Seed)
                          end,
    #{count => Count, coverage => Coverage, states => [#{choice => C, t => moment(Epoch, C)} || C <- Choices]}.

every_choice(Sizes) ->
    lists:foldr(fun({Lba, N}, Partial) -> [chosen(P, Lba, I) || I <- lists:seq(0, N - 1), P <- Partial] end, [#{}], Sizes).

%% Families 1 and 2 whole, then the draw up to Bound.
sampled(#{index := Index} = Epoch, Sizes, Count, Bound, Seed) ->
    Families = unique(in_order_cuts(Epoch) ++ one_left_durable(Epoch)),
    Drawn = draw(Sizes, Bound - length(Families), sets:from_list(Families, [{version, 2}]),
                 rand:seed_s(exsss, {Seed, Index, 16#c4a5})),
    Choices = Families ++ Drawn,
    {{sampled, length(Choices), Count, Seed, version()}, Choices}.

%% The state after each prefix of the epoch's writes, as a device that writes in
%% order leaves it.
in_order_cuts(#{writes := Writes, values := Values}) ->
    {_, Cuts} = lists:foldl(fun({_Pos, Lba, Bytes}, {Choice, Acc}) ->
                                    Next = chosen(Choice, Lba, index_of(Bytes, maps:get(Lba, Values))),
                                    {Next, [Next | Acc]}
                            end, {#{}, [#{}]}, Writes),
    lists:reverse(Cuts).

%% The epoch's last state with one sector at a time left at its durable bytes.
one_left_durable(#{writes := Writes, values := Values}) ->
    Last = lists:foldl(fun({_Pos, Lba, Bytes}, Acc) -> chosen(Acc, Lba, index_of(Bytes, maps:get(Lba, Values))) end,
                       #{}, Writes),
    [maps:remove(Lba, Last) || Lba := _ <- maps:iterator(Last, ordered)].

%% Choice with Lba at value I; the durable value, 0, is left out.
chosen(Choice, Lba, 0) -> maps:remove(Lba, Choice);
chosen(Choice, Lba, I) -> Choice#{Lba => I}.

index_of(Bytes, Vs) -> index_of(Bytes, Vs, 0).
index_of(Bytes, [{Bytes, _} | _], I) -> I;
index_of(Bytes, [_ | Rest], I) -> index_of(Bytes, Rest, I + 1).

unique(Choices) -> unique(Choices, #{}).
unique([], _Seen) -> [];
unique([C | Rest], Seen) when is_map_key(C, Seen) -> unique(Rest, Seen);
unique([C | Rest], Seen) -> [C | unique(Rest, Seen#{C => true})].

draw(_Sizes, Wanted, _Seen, _Rand) when Wanted =< 0 -> [];
draw(Sizes, Wanted, Seen, Rand) ->
    {Choice, Rand1} = lists:foldl(fun({Lba, N}, {Acc, R}) ->
                                          {I, R1} = rand:uniform_s(N, R),
                                          {chosen(Acc, Lba, I - 1), R1}
                                  end, {#{}, Rand}, Sizes),
    case sets:is_element(Choice, Seen) of
        true -> draw(Sizes, Wanted, Seen, Rand1);
        false -> [Choice | draw(Sizes, Wanted - 1, sets:add_element(Choice, Seen), Rand1)]
    end.

%% The earliest trace position at which a crash could leave Choice.
moment(#{start := Start, values := Values}, Choice) ->
    lists:max([Start | [element(2, lists:nth(I + 1, maps:get(Lba, Values))) || Lba := I <- Choice]]).

%% ---------------------------------------------------------------------------
%% Images
%% ---------------------------------------------------------------------------

%% A function reading one sector of Epoch's state Choice over Base, as erx_fat:mount/2
%% takes it.
-spec read_fun(binary(), epoch(), choice()) -> fun((non_neg_integer()) -> {ok, binary()} | {error, erange}).
read_fun(Base, #{durable := Durable, values := Values}, Choice) ->
    Overlay = maps:merge(Durable, #{Lba => element(1, lists:nth(I + 1, maps:get(Lba, Values))) || Lba := I <- Choice}),
    Sectors = byte_size(Base) div ?SECTOR,
    fun(Lba) when is_integer(Lba), Lba >= 0, Lba < Sectors -> {ok, durable_sector(Overlay, Base, Lba)};
       (_Lba) -> {error, erange}
    end.

%% The whole image of state Choice of epoch Index of Trace over Base, rebuilt from
%% nothing else: Base with every write sent before the epoch began, then each chosen
%% sector's value.
-spec image(binary(), erx_ram_window:trace(), pos_integer(), choice()) -> binary().
image(Base, Trace, Index, Choice) ->
    [#{start := Start, values := Values}] = [E || #{index := I} = E <- epochs(Trace, Base), I =:= Index],
    Before = [{Lba + I, S} || {Pos, {write, Lba, Bytes, _}} <- lists:enumerate(Trace), Pos =< Start,
                              {I, S} <- lists:enumerate(0, split(Bytes))],
    Chosen = [{Lba, element(1, lists:nth(I + 1, maps:get(Lba, Values)))} || Lba := I <- Choice],
    lists:foldl(fun({Lba, Bytes}, Image) ->
                        At = Lba * ?SECTOR,
                        <<Head:At/binary, _:?SECTOR/binary, Tail/binary>> = Image,
                        <<Head/binary, Bytes/binary, Tail/binary>>
                end, Base, Before ++ Chosen).
