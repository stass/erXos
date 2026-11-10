%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tap_nif).

-moduledoc """
The loader of the tap transport's NIF (docs/design-network-stack.md, "The tap transport"),
built only outside erXos: erx_net's `c_src/erx_tap_nif.c`, from `priv/erx_tap_nif.so`, which
`make -C c_src tap` builds. Without its library the module does not load, and every call
fails with `undef`.

The handle `open/2` answers belongs to the calling process: every call from another process
is `badarg`, and the descriptor is closed once the owner has ended. Each call is bounded and
runs on a normal scheduler; the descriptor is non-blocking, and an empty or full device is
armed with `enif_select`, whose message to the owner, `{erx_tap, readable}` or
`{erx_tap, writable}`, says it is ready again.
""".

-export([open/2, recv/1, send/2]).

-export_type([handle/0]).

-nifs([open/2, recv/1, send/2]).
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
The frames waiting on the device: each `read` one frame, into a binary of its own, at most 64
reads or 64 KiB in all. `Drops` counts by reason the frames dropped: `malformed`, shorter than
the Ethernet header, and `too_long`, longer than the MTU and the header. `armed` when the
device had no frame left, which arms it for reading; `more` when a bound was reached and frames
may wait. `{error, Reason}` ends the medium: `eof`, `arm`, or `{read, Errno}`.
""".
-spec recv(handle()) ->
    {ok, [binary()], #{malformed | too_long => pos_integer()}, more | armed} | {error, term()}.
recv(_Handle) ->
    erlang:nif_error(undef).

-doc """
Writes one frame, iodata, in one `writev` of its binaries, none of them joined unless it holds
more than 64 or byte integers. `{ok, 1}` when the device took it; `full` when it would block,
which arms the device for writing; `{drop, Reason}` for a frame shorter than the Ethernet
header (`malformed`), longer than the MTU and the header (`too_long`), or that the tap
discarded as a wire loses one (`refused`). `{error, Reason}` ends the medium: `partial` for a
write that took part of the frame, `arm`, or `{write, Errno}`.
""".
-spec send(handle(), iodata()) ->
    {ok, 1} | full | {drop, malformed | too_long | refused} | {error, term()}.
send(_Handle, _Frame) ->
    erlang:nif_error(undef).
