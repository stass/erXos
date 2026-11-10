%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tap).
-moduledoc """
The tap transport (docs/design-network-stack.md, "The tap transport"): Ethernet frames,
without their frame check sequence, exchanged with a host's tap device through the NIF
`erx_tap_nif`, one frame per `read` and per `writev`, the kernel's copy the only copy of a
frame's bytes. Built only outside erXos; on FreeBSD the device is `/dev/tapN`. It parses
nothing. Each received frame comes as `{sum, Sum, Frame}`, with the network sum the NIF took
right after the `read` (docs/design-network-stack.md, "Checksums in the copy"). The tap
finishes checksums in its copy (`finish` `copy`): a delayed frame, `{csum, Start, Field,
Frame}`, has its checksum finished by the NIF as it hands the frame to `writev`. A run
(`erx_net_frame:run()`) is cut by the NIF as it writes it (`c_src/erx_tcp_cut.c`), one
`writev` a frame: the headers from the NIF's own buffer, the payload from the run's binaries
where they lie, the bytes `erx_net_frame:cut/1` gives. A run whose payload is more binaries
than the NIF takes, which it answers `pieces`, goes frame by frame as `cut/1` cuts it. When a frame
after the first N is not taken, or the NIF's bound of frames a call is reached, the answer is
`{ok, N}`, and the driver hands the rest again, which the tap then answers itself (`full`,
armed, or a drop). A run whose first frame is over the MTU is dropped as `too_long`. A frame
shorter than the Ethernet header is dropped as `malformed`, one longer than the MTU and its
14-byte header as `too_long`, and one the tap discards as `refused`.

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

The configuration names the device by exactly one of `device`, its path, which `init` opens,
and `fd`, a descriptor the node holds open on it, such as one a privileged opener handed over,
of which `init` adopts a copy, so the node keeps its own and each start of the driver adopts
again; the node leaves it non-blocking, as `erx_tap_nif:adopt/2` says. The rest: `lladdr`,
which must be a unicast address with the locally administered bit set; `mtu`, from 1,280 to
9,000 (1,500 when absent); and `tx_limit`, the frames that may wait at the driver (256 when
absent). The link is `up` from `init` on.
""".

-behaviour(erx_net_driver).

-export([init/1, event/2, transmit/2]).

-include("erx_net_frame.hrl").

-define(ETHER_HDR_LEN, 14).
-define(MTU_DEFAULT, 1500).
-define(TX_LIMIT_DEFAULT, 256).

-record(tap, {handle :: erx_tap_nif:handle(),
              mtu :: 1280..9000,
              failed = false :: boolean()}).

-doc false.
init(#{lladdr := Lladdr} = Config) ->
    Mtu = maps:get(mtu, Config, ?MTU_DEFAULT),
    Limit = maps:get(tx_limit, Config, ?TX_LIMIT_DEFAULT),
    maybe
        ok ?= check(lladdr, Lladdr, is_local_unicast(Lladdr)),
        ok ?= check(mtu, Mtu, is_integer(Mtu) andalso Mtu >= 1280 andalso Mtu =< 9000),
        ok ?= check(tx_limit, Limit, is_integer(Limit) andalso Limit > 0),
        {ok, Handle} ?= medium(maps:with([device, fd], Config), Mtu),
        self() ! {erx_tap, more},
        {ok, #{link => ethernet, lladdr => Lladdr, mtu => Mtu, state => up, tx_limit => Limit,
               finish => copy},
         #tap{handle = Handle, mtu = Mtu}}
    end.

check(_Key, _Value, true) -> ok;
check(Key, Value, false) -> {error, {Key, Value}}.

%% Unicast (the group bit clear) and locally administered (the next bit set).
is_local_unicast(<<_:6, 1:1, 0:1, _:40>>) -> true;
is_local_unicast(_) -> false.

%% The handle on the medium the configuration names: exactly one of a path or a descriptor.
medium(#{device := Device} = Medium, Mtu) when map_size(Medium) =:= 1 ->
    maybe
        {ok, Path} ?= path(Device),
        open(Path, Mtu)
    end;
medium(#{fd := Fd} = Medium, Mtu) when map_size(Medium) =:= 1 ->
    adopt(Fd, Mtu);
medium(Medium, _Mtu) ->
    {error, {medium, Medium}}.

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

adopt(Fd, Mtu) ->
    try erx_tap_nif:adopt(Fd, Mtu) of
        {ok, _} = Ok -> Ok;
        {error, Reason} -> {error, {fd, Fd, Reason}}
    catch
        error:badarg -> {error, {fd, Fd}}
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
%% A run whose payload is more binaries than the NIF's cut takes is cut here; its first
%% frame, the longest, is checked as the NIF checks it.
transmit(#run{} = Run, T0) ->
    case send(Run, T0) of
        {pieces, T} ->
            [First | _] = Frames = erx_net_frame:cut(Run),
            case iolist_size(First) =< T#tap.mtu + ?ETHER_HDR_LEN of
                true -> send_run(Frames, 0, T);
                false -> {{drop, too_long}, T}
            end;
        Answer ->
            Answer
    end;
%% The NIF joins a frame of many pieces before it checks its size, so the size is checked
%% here first, as the pipe checks it.
transmit({csum, _Start, _Field, Bytes} = Frame, #tap{mtu = Mtu} = T) ->
    Size = iolist_size(Bytes),
    case {Size =< Mtu + ?ETHER_HDR_LEN, erx_net_frame:finishable(Frame, Size)} of
        {false, _} -> {{drop, too_long}, T};
        {true, false} -> {{drop, malformed}, T};
        {true, true} -> send(Frame, T)
    end;
transmit(Frame, #tap{mtu = Mtu} = T) when is_list(Frame) ->
    case iolist_size(Frame) =< Mtu + ?ETHER_HDR_LEN of
        true -> send(Frame, T);
        false -> {{drop, too_long}, T}
    end;
transmit(Frame, T) ->
    send(Frame, T).

%% A run's frames, each no longer than its first, which was checked; Taken of them went.
send_run([], _Taken, T) ->
    {ok, T};
send_run([Frame | Frames], Taken, T0) ->
    case {send(Frame, T0), Taken} of
        {{ok, T}, _} -> send_run(Frames, Taken + 1, T);
        {{_FullOrDrop, _} = Answer, 0} -> Answer;
        {{_FullOrDrop, T}, _} -> {{ok, Taken}, T}
    end.

send(Frame, #tap{handle = Handle} = T) ->
    case erx_tap_nif:send(Handle, Frame) of
        {ok, N} -> {taken(Frame, N), T};
        full -> {full, T};
        pieces -> {pieces, T};
        {drop, _} = Drop -> {Drop, T};
        {error, Reason} ->
            self() ! {erx_tap, failed, Reason},
            {{drop, refused}, T#tap{failed = true}}
    end.

%% A frame goes whole; of a run, the NIF answers how many of its frames went.
taken(#run{} = Run, N) ->
    case N < erx_net_frame:frames(Run) of
        true -> {ok, N};
        false -> ok
    end;
taken(_Frame, 1) ->
    ok.
