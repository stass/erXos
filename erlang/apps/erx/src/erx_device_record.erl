%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The device records a domain's ERTS finds among its boot arguments (docs/design-stopgap.md,
%% "Device records"), one per device the domain drives, in one of two forms, each with its
%% own word so neither is told from the other by counting:
%%
%% - `-erx given ROLE PERIPHERAL WINDOW_H OFFSET SIZE LINE_H MARK MEM_H MEM_SIZE CLOCK COHERENT MAC`,
%%   a given device: the handles of the window, line and memory objects the domain library
%%   installed when it created the domain, or the root made for itself at boot for a device
%%   the system domain holds, the transport's offset and size in the window object, the
%%   memory's bytes, 0 for a device that does no DMA, and the firmware tree's coherence mark
%%   and hardware address;
%% - `-erx device ROLE PERIPHERAL BASE SIZE LINE MARK CLOCK`, the system domain's physical record
%%   of its host link's UART, which does no DMA, built by liberx/backend/core/boot_manifest.c
%%   from the system manifest.
%%
%% In both forms CLOCK is the device's clock in hertz from its manifest row, 0 for a device
%% whose driver reads none, so a driver reads its clock the same way whichever form it gets.
%% MARK is `shared` when another device of the unit names the line and `direct` otherwise,
%% as the record's writer found it (docs/design-shared-devices.md, "Lines inside a domain"),
%% and a shared line reaches erx_device:open/1 as `{shared, Line}`; any other word refuses
%% the record, so no line is read as one mark or the other by default.
%%
%% A driver asks for the records of its role and its peripheral and opens each with
%% erx_device:open/1. No record is a normal state, a machine without a disk, and is
%% `{ok, []}`: the driver then has nothing to drive. Whether a disk is behind a transport is
%% the driver's first reads of it to say, not the record's.

-module(erx_device_record).

-export([find/2, find/3]).
-export_type([spec/0]).

%% What erx_device:open/1 takes: a given device's objects, or a physical device's window and
%% line, each with its clock for its driver.
-type spec() :: #{peripheral := atom(),
                  window := {object, non_neg_integer(), non_neg_integer(), non_neg_integer()},
                  lines := [{object, non_neg_integer()} | {shared, {object, non_neg_integer()}}],
                  memory => {object, non_neg_integer(), pos_integer()}, clock := non_neg_integer(),
                  coherent := boolean(), mac => 1..16#ffffffffffff}
              | #{peripheral := atom(), window := {physical, non_neg_integer(), non_neg_integer()},
                  lines := [non_neg_integer() | {shared, non_neg_integer()}], clock := non_neg_integer()}.

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

%% COHERENT is the firmware tree's coherence mark, 0 or 1, and MAC its hardware address,
%% 48 bits, 0 for none (docs/design-device-tree.md, "Facts into records").
spec(Peripheral, {"given", [Window, Offset, Size, Line, Mark, Memory, MemorySize, Clock, Coherent, Mac | _]}) ->
    case {numbers([Window, Offset, Size, Line, Memory, MemorySize]), number(Clock, 32), mark(Mark),
          coherent(Coherent), number(Mac, 48)} of
        {{ok, [W, O, S, L, M, MS]}, {ok, C}, {ok, Sharing}, {ok, Co}, {ok, A}} ->
            Spec = #{peripheral => Peripheral, window => {object, W, O, S},
                     lines => [marked(Sharing, {object, L})], clock => C, coherent => Co},
            {ok, with_mac(with_memory(Spec, M, MS), A)};
        {{ok, _}, {ok, _}, error, _, _} ->
            bad("a given device record's line mark is neither direct nor shared");
        {{ok, _}, {ok, _}, {ok, _}, error, _} ->
            bad("a given device record's coherence is neither 0 nor 1");
        _ ->
            bad("a given device record's handle, offset, size, clock or address is not a decimal number "
                "of its field's width")
    end;
spec(_Peripheral, {"given", _}) ->
    bad("a given device record has fewer than nine numbers and a line mark");
spec(Peripheral, {"device", [Base, Size, Line, Mark, Clock | _]}) ->
    case {number(Base, 64), number(Size, 64), number(Line, 32), number(Clock, 32), mark(Mark)} of
        {{ok, B}, {ok, S}, {ok, L}, {ok, C}, {ok, Sharing}} ->
            {ok, #{peripheral => Peripheral, window => {physical, B, S}, lines => [marked(Sharing, L)],
                   clock => C}};
        {{ok, _}, {ok, _}, {ok, _}, {ok, _}, error} ->
            bad("a device record's line mark is neither direct nor shared");
        _ ->
            bad("a device record's base, size, line or clock is not a decimal number of its field's width")
    end;
spec(_Peripheral, {"device", _}) ->
    bad("a device record has fewer than four numbers and a line mark").

coherent("0") -> {ok, false};
coherent("1") -> {ok, true};
coherent(_) -> error.

with_mac(Spec, 0) -> Spec;
with_mac(Spec, Address) -> Spec#{mac => Address}.

%% The line's mark word, and the line as erx_device:open/1 takes it.
mark("direct") -> {ok, direct};
mark("shared") -> {ok, shared};
mark(_Word) -> error.

marked(direct, Line) -> Line;
marked(shared, Line) -> {shared, Line}.

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
