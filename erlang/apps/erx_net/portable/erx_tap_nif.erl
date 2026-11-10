%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tap_nif).

-moduledoc """
The loader of the tap transport's NIF (docs/design-network-stack.md, "The tap transport"),
built only outside erXos: erx_net's `c_src/erx_tap_nif.c`, from `priv/erx_tap_nif.so`, which
`make -C c_src tap` builds. Without its library the module does not load, and every call
fails with `undef`.

A handle comes from `open/2`, which opens the device by name, or from `adopt/2`, which takes
a copy of a descriptor the node already holds, such as a tap's that a privileged opener
handed over. The handle belongs to the calling process: every call from another process
is `badarg`, and the descriptor is closed once the owner has ended. Each call is bounded and
runs on a normal scheduler; the descriptor is non-blocking, and an empty or full device is
armed with `enif_select`, whose message to the owner, `{erx_tap, readable}` or
`{erx_tap, writable}`, says it is ready again.
""".

-export([adopt/2, open/2, recv/1, send/2]).

-export_type([handle/0]).

-nifs([adopt/2, open/2, recv/1, send/2]).
-on_load(on_load/0).

-doc "An open tap device, usable only by the process that opened it.".
-opaque handle() :: reference().

%% Loads priv/erx_tap_nif.so of erx_net, as erx_bytes loads its library.
-spec on_load() -> ok | {error, term()}.
on_load() ->
    case code:priv_dir(erx_net) of
        {error, Reason} -> {error, {priv_dir, erx_net, Reason}};
        Priv -> erlang:load_nif(filename:join(Priv, "erx_tap_nif"), 0)
    end.

-doc """
Opens the device at `Path` for reading and writing, non-blocking and close-on-exec, for
frames of at most `Mtu` bytes past the 14-byte Ethernet header. `{error, {open, Errno}}`
when the system refuses; `badarg` for a path that is empty, holds a NUL or is too long, or an
MTU outside 68 to 9,000.
""".
-spec open(Path :: binary(), Mtu :: 68..9000) ->
    {ok, handle()} | {error, {open, atom() | integer()}}.
open(_Path, _Mtu) ->
    erlang:nif_error(undef).

-doc """
A handle on a close-on-exec copy of the open descriptor `Fd`, made non-blocking, for frames of
at most `Mtu` bytes past the 14-byte Ethernet header. `Fd` stays the caller's, and closing it
with `close(2)` leaves the copy open. The copy shares `Fd`'s open file and so its flags: `Fd`
turns non-blocking too, and the caller keeps it so while the handle lives, since a read or
write of a blocking copy would stall the scheduler; OTP's `socket:close/1`, for one, makes a
socket blocking before it closes it. `{error, {adopt, Errno}}` when the system refuses,
`ebadf` for a descriptor that is not open; `badarg` for an `Fd` that is not a non-negative
integer that fits a C `int`, or an MTU outside 68 to 9,000.
""".
-spec adopt(Fd :: non_neg_integer(), Mtu :: 68..9000) ->
    {ok, handle()} | {error, {adopt, atom() | integer()}}.
adopt(_Fd, _Mtu) ->
    erlang:nif_error(undef).

-doc """
The frames waiting on the device: each `read` one frame, into a binary of its own, at most 64
reads or 64 KiB in all, each as `{sum, Sum, Frame}` with its network sum, the sum
(`erx_net_sum`) of its bytes after the Ethernet header. `Drops` counts by reason the frames
dropped: `malformed`, shorter than the Ethernet header, and `too_long`, longer than the MTU
and the header. `armed` when the device had no frame left, which arms it for reading; `more`
when a bound was reached and frames may wait. `{error, Reason}` ends the medium: `eof`, `arm`,
or `{read, Errno}`.
""".
-spec recv(handle()) ->
    {ok, [{sum, erx_net_sum:sum(), binary()}], #{malformed | too_long => pos_integer()}, more | armed}
    | {error, term()}.
recv(_Handle) ->
    erlang:nif_error(undef).

-doc """
Writes one frame, iodata, in one `writev` of its binaries, none of them joined unless it holds
more than 64 or byte integers. `{ok, 1}` when the device took it; `full` when it would block,
which arms the device for writing; `{drop, Reason}` for a frame shorter than the Ethernet
header (`malformed`), longer than the MTU and the header (`too_long`), or that the tap
discarded as a wire loses one (`refused`). `{error, Reason}` ends the medium: `partial` for a
write that took part of the frame, `arm`, or `{write, Errno}`.

A delayed frame, `{csum, Start, Field, Frame}` (`erx_net_frame:delayed()`), is written with
its checksum finished: the NIF sums the frame's bytes from `Start` to its end, the field at
`Start + Field` included, and writes the complement in place of the field's two bytes, an
iovec of its own, so no binary is changed or copied. `Start` and `Field` must be even and
the field must lie inside the frame, else `badarg`.

A run (`erx_net_frame:run()`) of at most 64 payload binaries is cut by `c_src/erx_tcp_cut.c`
as it is written, into the frames `erx_net_frame:cut/1` gives, each in one `writev` of its
headers, from a buffer of the NIF's own, and its payload slice, from the run's binaries where
they lie. `{ok, N}`, N > 0, for the first N frames taken: all of them, the first 64 of a run
of more, or those before the first the device did not take, which the next call answers for
itself. A run whose first frame is not taken is answered as a frame is, `{drop, too_long}`
when its first frame, its longest, is over the MTU. A run the cut refuses, a template
`erx_net_frame:template/2` does not make, a zero segment size, a field wider than the wire's,
more than 64 payload binaries, or more than 65,535 bytes with its IP and TCP headers, is
`badarg`: output makes none (`erx_tcp_sndbuf:range/4`).
""".
-spec send(handle(), iodata() | erx_net_frame:delayed() | erx_net_frame:run()) ->
    {ok, pos_integer()} | full | {drop, malformed | too_long | refused} | {error, term()}.
send(_Handle, _Frame) ->
    erlang:nif_error(undef).
