%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pipe_nif).
-moduledoc """
The session's pipe NIF (otp/erts/emulator/nifs/erxos/erx_pipe_nif.c,
docs/design-pipes.md, "The session's pipe NIF"), static in the runtime.
erx_pipe_srv alone makes, binds and closes objects and opens ends and
applies reports to them; a session process reads, writes and closes the
ends it owns, through erx_pipe_srv:read/3, write/3 and close/1.
""".

-nifs([make_lock/0, make_lane/1, make_bell/3, store_wends/2, free_lock/2,
       close/1, open_end/3, apply/2, read/2, write/2]).
-on_load(on_load/0).

-export([make_lock/0, make_lane/1, make_bell/3, store_wends/2, free_lock/2,
         close/1, open_end/3, apply/2, read/2, write/2]).

on_load() ->
    erlang:load_nif(atom_to_list(?MODULE), #{}).

-doc "A lock page: `{ok, Lock}` or `{error, enomem}`.".
make_lock() -> erlang:nif_error(undef).

-doc "A lane of a data area of Size bytes: `{ok, Ring, RPage}` or `{error, enomem}`.".
make_lane(_Size) -> erlang:nif_error(undef).

-doc "A doorbell whose ring sends Pid `{erx_pipe_ready, Pipe, End}`.".
make_bell(_Pid, _Pipe, _End) -> erlang:nif_error(undef).

-doc "Stores a pipe's highest write end number, release order.".
store_wends(_Lock, _Wends) -> erlang:nif_error(undef).

-doc "Frees the reader lock if read end Rix holds it.".
free_lock(_Lock, _Rix) -> erlang:nif_error(undef).

-doc "Drops the server's hold on an object, or closes an end its caller owns.".
close(_ObjectOrEnd) -> erlang:nif_error(undef).

-doc "An end owned by Owner from a descriptor naming objects: `{ok, End}`.".
open_end(_Owner, _Server, _Descriptor) -> erlang:nif_error(undef).

-doc "Applies the server's report to an end: `ok` or `{error, enomem}`.".
apply(_End, _Report) -> erlang:nif_error(undef).

-doc "At most Max bytes, `eof`, `would_block` or `{error, eio}`.".
read(_End, _Max) -> erlang:nif_error(undef).

-doc "The bytes written, `would_block`, or `{error, epipe | eio}`.".
write(_End, _Bin) -> erlang:nif_error(undef).
