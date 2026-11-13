%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pipe_nif).
-moduledoc """
The session's pipe NIF (otp/erts/emulator/nifs/erxos/erx_pipe_nif.c,
docs/design-pipes.md, "The session's pipe NIF"), static in the runtime.
erx_pipe_srv alone makes, binds and closes objects, opens ends and
applies reports to them, and makes hand-offs; a session process reads,
writes and closes the ends it owns, through erx_pipe_srv:read/3, write/3
and close/1.

A program's handler makes the program's holder entry, gives back
hand-offs it does not pass to its port driver, and drops its hold after
a start that failed (docs/design-pipes.md, "Hand-offs"). The program
driver takes hand-offs and lets the port's hold go through the NIF's C
entries (erx_pipe.h); once neither hold of an entry remains, the NIF
tells the pipe server the program is gone.
""".

-nifs([make_lock/1, pipes_made/0, make_lane/1, make_bell/3, store_wends/2,
       free_lock/2, close/1, open_end/3, apply/2, read/2, write/2,
       hand_make/2, hand_drop/1, program_holder/1, holder_drop/1, holder_owner/1]).
-on_load(on_load/0).

-export([make_lock/1, pipes_made/0, make_lane/1, make_bell/3, store_wends/2,
         free_lock/2, close/1, open_end/3, apply/2, read/2, write/2,
         hand_make/2, hand_drop/1, program_holder/1, holder_drop/1, holder_owner/1]).

on_load() ->
    erlang:load_nif(atom_to_list(?MODULE), #{}).

-doc """
Pipe `Pipe`'s lock page: `{ok, Lock}`, `{error, einval}` for a number
not above every number a make_lock has taken while the runtime runs, or
`{error, enomem}`.
""".
make_lock(_Pipe) -> erlang:nif_error(undef).

-doc "The highest pipe number a make_lock has taken, 0 for none.".
pipes_made() -> erlang:nif_error(undef).

-doc "A lane of a data area of Size bytes: `{ok, Ring, RPage}` or `{error, enomem}`.".
make_lane(_Size) -> erlang:nif_error(undef).

-doc """
End `End`'s doorbell: for a process `Pid`, one whose ring sends it
`{erx_pipe_ready, Pipe, End}`; for `{program, _}`, one made unbound, for
the program's port driver to bind.
""".
make_bell(_Holder, _Pipe, _End) -> erlang:nif_error(undef).

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

-doc """
One hand-off for each `{Copies, Bell}` of `Hands`, in order, for the
owner of `{program, Program}`'s holder entry: `Copies` a list of
`{Object, Rights}`, `Bell` `none` or the end's own unbound doorbell and
its label, `{Bell, Label}`. `{ok, Numbers}`, all or none; `none`, making
nothing, when the program has no entry its owner holds; or `{error,
enomem}`.
""".
hand_make(_Program, _Hands) -> erlang:nif_error(undef).

-doc "Lets go the caller's held hand-off `Number`; nothing for any other.".
hand_drop(_Number) -> erlang:nif_error(undef).

-doc """
The holder entry of `{program, Program}`, owned by the caller, which then
speaks for the program: `ok`, or `{error, eexist}` when it has one.
""".
program_holder(_Program) -> erlang:nif_error(undef).

-doc "Lets the caller's hold on the program's entry go, with its hand-offs.".
holder_drop(_Program) -> erlang:nif_error(undef).

-doc "The process that speaks for `{program, Program}`: `{ok, Pid}` or `none`.".
holder_owner(_Program) -> erlang:nif_error(undef).
