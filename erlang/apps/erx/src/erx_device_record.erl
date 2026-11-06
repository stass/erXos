%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The device records the root hands the system domain's ERTS (docs/design-stopgap.md,
%% "Device records"): for each device of a unit the system domain holds that its ERTS
%% drives, `-erx device ROLE PERIPHERAL BASE SIZE LINE DMA_MEMORY`, built by
%% liberx/backend/core/boot_manifest.c from the system manifest. A driver asks for the
%% records of its role and its peripheral and opens each with erx_device:open/1. No
%% record is a normal state, a machine without a disk, and is `{ok, []}`: the driver
%% then has nothing to drive. Whether a disk is behind a transport is the driver's first
%% reads of it to say, not the record's.

-module(erx_device_record).

-export([find/2, find/3]).
-export_type([spec/0]).

%% What erx_device:open/1 takes, with the boot's DMA memory beside the window and line.
-type spec() :: #{peripheral := atom(), window := {physical, non_neg_integer(), non_neg_integer()},
                  lines := [non_neg_integer()], dma_memory := non_neg_integer()}.

%% The records of Role and Peripheral among init's `-erx` arguments.
-spec find(atom(), atom()) -> {ok, [spec()]} | {error, {bad_device_record, string()}}.
find(Role, Peripheral) ->
    Arguments = case init:get_argument(erx) of
                    {ok, Found} -> Found;
                    error -> []
                end,
    find(Role, Peripheral, Arguments).

%% Pure, for its tests and fuzz target. A record of another role or peripheral is left
%% alone. A plain word of the kernel command line joins the flag before it, so a record
%% may run on past its four numbers; the words after them are not the record's. A record
%% of Role and Peripheral whose numbers do not parse refuses them all, since a malformed
%% record says the root and this reader disagree.
-spec find(atom(), atom(), [[string()]]) ->
    {ok, [spec()]} | {error, {bad_device_record, string()}}.
find(Role, Peripheral, Arguments) ->
    RoleWord = atom_to_list(Role),
    PeripheralWord = atom_to_list(Peripheral),
    Records = [Words || ["device", R, P | Words] <- Arguments, R =:= RoleWord, P =:= PeripheralWord],
    specs(Peripheral, Records, []).

specs(_Peripheral, [], Specs) ->
    {ok, lists:reverse(Specs)};
specs(Peripheral, [[Base, Size, Line, Dma | _] | Rest], Specs) ->
    case {number(Base, 64), number(Size, 64), number(Line, 32), number(Dma, 64)} of
        {{ok, B}, {ok, S}, {ok, L}, {ok, D}} ->
            Spec = #{peripheral => Peripheral, window => {physical, B, S}, lines => [L], dma_memory => D},
            specs(Peripheral, Rest, [Spec | Specs]);
        _ ->
            {error, {bad_device_record, "a device record's base, size, line or DMA memory is not a "
                                        "decimal number of its field's width"}}
    end;
specs(_Peripheral, [_ | _], _Specs) ->
    {error, {bad_device_record, "a device record has fewer than four numbers"}}.

%% Digits only, at most as many as the field's largest value has, so no word builds a large
%% integer before the range check.
number(Word, Bits) ->
    Max = (1 bsl Bits) - 1,
    case Word =/= [] andalso length(Word) =< length(integer_to_list(Max))
        andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Word) of
        true ->
            case list_to_integer(Word) of
                Value when Value =< Max -> {ok, Value};
                _ -> error
            end;
        false ->
            error
    end.
