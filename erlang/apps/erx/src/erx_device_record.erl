%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The device records a domain's ERTS finds among its boot arguments (docs/design-stopgap.md,
%% "Device records"), one per device the domain drives, in one of two forms, each with its
%% own word so neither is told from the other by counting:
%%
%% - `-erx given ROLE PERIPHERAL WINDOW_H OFFSET SIZE LINE_H MEM_H MEM_SIZE`, a holder
%%   domain's device: the handles of the window, line and memory objects the domain library
%%   installed when it created the domain, the transport's offset and size in the window
%%   object, and the memory's bytes, 0 for a device that does no DMA;
%% - `-erx device ROLE PERIPHERAL BASE SIZE LINE DMA_MEMORY`, the system domain's physical
%%   record, built by liberx/backend/core/boot_manifest.c from the system manifest.
%%
%% A driver asks for the records of its role and its peripheral and opens each with
%% erx_device:open/1. No record is a normal state, a machine without a disk, and is
%% `{ok, []}`: the driver then has nothing to drive. Whether a disk is behind a transport is
%% the driver's first reads of it to say, not the record's.

-module(erx_device_record).

-export([find/2, find/3]).
-export_type([spec/0]).

%% What erx_device:open/1 takes: a given device's objects, or a physical device's window and
%% line with the boot's DMA memory beside them.
-type spec() :: #{peripheral := atom(),
                  window := {object, non_neg_integer(), non_neg_integer(), non_neg_integer()},
                  lines := [{object, non_neg_integer()}],
                  memory => {object, non_neg_integer(), pos_integer()}}
              | #{peripheral := atom(), window := {physical, non_neg_integer(), non_neg_integer()},
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
%% may run on past its numbers; the words after them are not the record's. A record of
%% Role and Peripheral whose numbers do not parse refuses them all, since a malformed
%% record says the writer and this reader disagree.
-spec find(atom(), atom(), [[string()]]) ->
    {ok, [spec()]} | {error, {bad_device_record, string()}}.
find(Role, Peripheral, Arguments) ->
    RoleWord = atom_to_list(Role),
    PeripheralWord = atom_to_list(Peripheral),
    Records = [{Form, Words} || [Form, R, P | Words] <- Arguments, Form =:= "device" orelse Form =:= "given",
                                R =:= RoleWord, P =:= PeripheralWord],
    specs(Peripheral, Records, []).

specs(_Peripheral, [], Specs) ->
    {ok, lists:reverse(Specs)};
specs(Peripheral, [Record | Rest], Specs) ->
    case spec(Peripheral, Record) of
        {ok, Spec} -> specs(Peripheral, Rest, [Spec | Specs]);
        {error, _} = Error -> Error
    end.

spec(Peripheral, {"given", [Window, Offset, Size, Line, Memory, MemorySize | _]}) ->
    case numbers([Window, Offset, Size, Line, Memory, MemorySize]) of
        {ok, [W, O, S, L, M, MS]} ->
            Spec = #{peripheral => Peripheral, window => {object, W, O, S}, lines => [{object, L}]},
            {ok, with_memory(Spec, M, MS)};
        error ->
            bad("a given device record's handle, offset or size is not a decimal number of 64 bits")
    end;
spec(_Peripheral, {"given", _}) ->
    bad("a given device record has fewer than six numbers");
spec(Peripheral, {"device", [Base, Size, Line, Dma | _]}) ->
    case {number(Base, 64), number(Size, 64), number(Line, 32), number(Dma, 64)} of
        {{ok, B}, {ok, S}, {ok, L}, {ok, D}} ->
            {ok, #{peripheral => Peripheral, window => {physical, B, S}, lines => [L], dma_memory => D}};
        _ ->
            bad("a device record's base, size, line or DMA memory is not a decimal number of its field's width")
    end;
spec(_Peripheral, {"device", _}) ->
    bad("a device record has fewer than four numbers").

%% A device that does no DMA has no memory object, and its record says 0 bytes.
with_memory(Spec, _Memory, 0) -> Spec;
with_memory(Spec, Memory, Bytes) -> Spec#{memory => {object, Memory, Bytes}}.

bad(Text) ->
    {error, {bad_device_record, Text}}.

numbers(Words) ->
    Parsed = [number(Word, 64) || Word <- Words],
    case lists:all(fun(Result) -> Result =/= error end, Parsed) of
        true -> {ok, [Value || {ok, Value} <- Parsed]};
        false -> error
    end.

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
