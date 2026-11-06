%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The guest side of the block device suite (tools/lib/erx/block_device.rb, whose header
%% defines the lines printed here). It is test code: the suite's harness compiles it, adds
%% it to a test image's system release under /test/blk and starts it with the kernel
%% command line's `-run erx_blk_check main`, after the release, erx_blk included, has
%% started. No production image holds it.
%%
%% It drives the driver only through erx_blk's public calls: it reports the transport
%% version and the capacity, reads each sector of the harness's disk and compares it with
%% the host's pattern, asks for the sector past the end, writes the guest's pattern to two
%% sectors, and ends with "blk: done", on which the harness ends the guest and reads the
%% disk back. A step that does not go as expected prints its "failed" line and the run goes
%% on, so the harness names the first step that went wrong.
%%
%% Each line goes to the console in one erlang:display_string/2 call, which reaches the
%% console's sink, its driver, whole (docs/design-runtime.md, "The console and standard
%% I/O"), so a kernel log line the console writes lands between two lines, never inside one.

-module(erx_blk_check).

-export([main/0]).

%% The disk the harness attaches and the sectors it expects written (BlockDevice::SECTORS
%% and WRITE_SECTORS), and the patterns of tools/lib/erx/block_image.rb: each 512-byte
%% sector is 32 records of an 8-byte tag and the sector's index as a little-endian 64-bit
%% integer.
-define(SECTORS, 16).
-define(WRITE_SECTORS, [3, 7]).
-define(SECTOR_BYTES, 512).
-define(RECORD_BYTES, 16).
-define(HOST_TAG, <<"ERXHOST!">>).
-define(GUEST_TAG, <<"ERXGUEST">>).

-spec main() -> ok.
main() ->
    case call(fun erx_blk:info/0) of
        {ok, #{version := Version, capacity := Capacity}} ->
            line("transport version ~b", [Version]),
            line("capacity ~b sectors", [Capacity]),
            lists:foreach(fun read/1, lists:seq(0, ?SECTORS - 1)),
            refused(?SECTORS),
            lists:foreach(fun write/1, ?WRITE_SECTORS);
        _NoDriver ->
            line("no driver", [])
    end,
    line("done", []).

read(Sector) ->
    case call(fun() -> erx_blk:read(Sector, 1) end) =:= {ok, pattern(Sector, ?HOST_TAG)} of
        true -> line("read sector ~b ok", [Sector]);
        false -> line("read sector ~b failed", [Sector])
    end.

refused(Sector) ->
    case call(fun() -> erx_blk:read(Sector, 1) end) of
        {error, out_of_range} -> line("read sector ~b refused", [Sector]);
        _Other -> line("read sector ~b failed", [Sector])
    end.

write(Sector) ->
    case call(fun() -> erx_blk:write(Sector, pattern(Sector, ?GUEST_TAG)) end) of
        ok -> line("wrote sector ~b", [Sector]);
        _Other -> line("wrote sector ~b failed", [Sector])
    end.

pattern(Sector, Tag) ->
    binary:copy(<<Tag/binary, Sector:64/little>>, ?SECTOR_BYTES div ?RECORD_BYTES).

%% A driver call, with the exit of a call that timed out or found the driver gone taken as
%% that step's failure, so one bad step does not end the run before "blk: done".
call(Fun) ->
    try Fun() catch exit:Reason -> {exit, Reason} end.

line(Format, Arguments) ->
    true = erlang:display_string(stdout, iolist_to_binary(["blk: ", io_lib:format(Format, Arguments), $\n])),
    ok.
