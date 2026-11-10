%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tap).
-moduledoc """
The tap transport (docs/design-network-stack.md, "The tap transport"): Ethernet frames,
without their frame check sequence, exchanged with a host's tap device through the NIF
`erx_tap_nif`, one frame per `read` and per `writev`, the kernel's copy the only copy of a
frame's bytes. Built only outside erXos; on FreeBSD the device is `/dev/tapN`. It parses
nothing. A frame shorter than the Ethernet header is dropped as `malformed`, one longer than
the MTU and its 14-byte header as `too_long`, and one the tap discards as `refused`.

Each direction has exactly one wake. Receiving, either the device is armed for reading, and
its `{erx_tap, readable}` will come, or the transport has sent itself one `{erx_tap, more}`;
`init` sends the first. Transmitting, either the last frame was taken, or the device is armed
for writing and the driver's backlog waits for the `writable` event its `{erx_tap, writable}`
gives. The tap's own queue is the only queue ahead of the driver, and the driver's mailbox
holds at most one message of each kind, so a peer that floods is bounded.

An error of the device ends the medium: from `recv` at once, with `{stop, {tap, Reason}}`;
from `send`, which `transmit/2` cannot stop the driver from, through the one
`{erx_tap, failed, Reason}` the transport sends itself, after which every frame is dropped as
`refused` without a call. The driver ends, and its supervisor starts it again with a new
descriptor; the old one closes as the driver ends, since the NIF's handle is the driver's.

The configuration: `device`, the device's path; `lladdr`, which must be a unicast address
with the locally administered bit set; `mtu`, from 1,280 to 9,000 (1,500 when absent); and
`tx_limit`, the frames that may wait at the driver (256 when absent). The link is `up` from
`init` on.
""".

-behaviour(erx_net_driver).

-export([init/1, event/2, transmit/2]).

-define(ETHER_HDR_LEN, 14).
-define(MTU_DEFAULT, 1500).
-define(TX_LIMIT_DEFAULT, 256).

-record(tap, {handle :: erx_tap_nif:handle(),
              mtu :: 1280..9000,
              failed = false :: boolean()}).

-doc false.
init(#{device := Device, lladdr := Lladdr} = Config) ->
    Mtu = maps:get(mtu, Config, ?MTU_DEFAULT),
    Limit = maps:get(tx_limit, Config, ?TX_LIMIT_DEFAULT),
    maybe
        ok ?= check(lladdr, Lladdr, is_local_unicast(Lladdr)),
        ok ?= check(mtu, Mtu, is_integer(Mtu) andalso Mtu >= 1280 andalso Mtu =< 9000),
        ok ?= check(tx_limit, Limit, is_integer(Limit) andalso Limit > 0),
        {ok, Path} ?= path(Device),
        {ok, Handle} ?= open(Path, Mtu),
        self() ! {erx_tap, more},
        {ok, #{link => ethernet, lladdr => Lladdr, mtu => Mtu, state => up, tx_limit => Limit},
         #tap{handle = Handle, mtu = Mtu}}
    end.

check(_Key, _Value, true) -> ok;
check(Key, Value, false) -> {error, {Key, Value}}.

%% Unicast (the group bit clear) and locally administered (the next bit set).
is_local_unicast(<<_:6, 1:1, 0:1, _:40>>) -> true;
is_local_unicast(_) -> false.

%% The device's path as the bytes the host's file names are.
path(Device) when is_list(Device); is_binary(Device) ->
    case unicode:characters_to_binary(Device, unicode, file:native_name_encoding()) of
        Path when is_binary(Path), byte_size(Path) > 0 -> {ok, Path};
        _ -> {error, {device, Device}}
    end;
path(Device) ->
    {error, {device, Device}}.

open(Path, Mtu) ->
    try erx_tap_nif:open(Path, Mtu) of
        {ok, _} = Ok -> Ok;
        {error, Reason} -> {error, {device, Path, Reason}}
    catch
        error:badarg -> {error, {device, Path}}
    end.

-doc false.
event({erx_tap, Wake}, #tap{handle = Handle} = T) when Wake =:= more; Wake =:= readable ->
    case erx_tap_nif:recv(Handle) of
        {ok, Frames, Drops, End} ->
            ok = rearm(End),
            {dropped(Drops) ++ [{frames, Frames}], T};
        {error, Reason} ->
            {stop, {tap, Reason}}
    end;
event({erx_tap, writable}, T) ->
    {[writable], T};
event({erx_tap, failed, Reason}, _T) ->
    {stop, {tap, Reason}};
event(_Msg, T) ->
    {[], T}.

%% The read wake after a batch: an armed device sends its own; one left with frames waiting
%% gets the transport's `more`.
rearm(armed) -> ok;
rearm(more) -> self() ! {erx_tap, more}, ok.

%% One `dropped` event per frame dropped, as the driver counts them.
dropped(Drops) ->
    lists:append([lists:duplicate(N, {dropped, Reason})
                  || {Reason, N} <- lists:sort(maps:to_list(Drops))]).

-doc false.
transmit({_Zone, _Packet}, T) ->
    {{drop, malformed}, T};
transmit(_Frame, #tap{failed = true} = T) ->
    {{drop, refused}, T};
%% The NIF joins a frame of many pieces before it checks its size, so the size is checked
%% here first, as the pipe checks it.
transmit(Frame, #tap{mtu = Mtu} = T) when is_list(Frame) ->
    case iolist_size(Frame) =< Mtu + ?ETHER_HDR_LEN of
        true -> send(Frame, T);
        false -> {{drop, too_long}, T}
    end;
transmit(Frame, T) ->
    send(Frame, T).

send(Frame, #tap{handle = Handle} = T) ->
    case erx_tap_nif:send(Handle, Frame) of
        {ok, 1} -> {ok, T};
        full -> {full, T};
        {drop, _} = Drop -> {Drop, T};
        {error, Reason} ->
            self() ! {erx_tap, failed, Reason},
            {{drop, refused}, T#tap{failed = true}}
    end.
