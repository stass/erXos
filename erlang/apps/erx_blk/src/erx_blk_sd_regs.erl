%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_blk_sd_regs).
-moduledoc """
The SD host controller's register writes, spaced (docs/design-storage.md,
"The SD host controller", Registers): two writes that reach the BCM2711's
controller within two card clock periods of each other can lose the first,
so every write other than to `data` goes through spaced/2, which makes it
at least 6 us after the one before it. 6 us is two periods of the 400 kHz
identification clock and a microsecond, U-Boot's rule, at every clock.

A handle holds the device and the time of the last spaced write; the
device process and erx_blk_write pass it along, so the command register's
write, which erx_blk_write alone makes, is spaced like every other. The
wait spins on Erlang's monotonic clock: it is at most 6 us, shorter than
any timer.
""".

-export([new/1, device/1, spaced/2, write/3, write_field/4, remaining_us/2]).

-export_type([regs/0]).

-define(SPACING_US, 6).

-record(regs, {dev :: erx_device:device(), last :: undefined | integer()}).
-opaque regs() :: #regs{}.

-doc "A handle for the opened device Dev, with no write made yet.".
-spec new(erx_device:device()) -> regs().
new(Dev) ->
    #regs{dev = Dev}.

-doc "The device the handle writes.".
-spec device(regs()) -> erx_device:device().
device(#regs{dev = Dev}) ->
    Dev.

-doc """
Makes the one register write Write makes, once 6 us have passed since the
last write made through the handle, and returns the handle with this
write's time. Write's own error, a badarg of erx_device, is raised.
""".
-spec spaced(regs(), fun(() -> ok)) -> regs().
spaced(#regs{last = Last} = Regs, Write) ->
    ok = wait(Last),
    ok = Write(),
    Regs#regs{last = now_us()}.

-doc "erx_device:write/3, spaced.".
-spec write(regs(), erx_device:register_name(), non_neg_integer()) -> regs().
write(#regs{dev = Dev} = Regs, Register, Value) ->
    spaced(Regs, fun() -> erx_device:write(Dev, Register, Value) end).

-doc "erx_device:write_field/4, one write of the register, spaced.".
-spec write_field(regs(), erx_device:register_name(), atom(), non_neg_integer()) -> regs().
write_field(#regs{dev = Dev} = Regs, Register, Field, Value) ->
    spaced(Regs, fun() -> erx_device:write_field(Dev, Register, Field, Value) end).

-doc """
How many microseconds must still pass, at monotonic time Now, before a
write may follow the one made at Last: none before the first write. Pure.
""".
-spec remaining_us(undefined | integer(), integer()) -> non_neg_integer().
remaining_us(undefined, _Now) ->
    0;
remaining_us(Last, Now) ->
    max(0, Last + ?SPACING_US - Now).

wait(Last) ->
    case remaining_us(Last, now_us()) of
        0 -> ok;
        _ -> wait(Last)
    end.

now_us() ->
    erlang:monotonic_time(microsecond).
