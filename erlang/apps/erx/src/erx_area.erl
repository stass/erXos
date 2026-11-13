%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_area).
-moduledoc """
A connection's pixel area (docs/design-display.md, "The pixel area"), static
in the runtime through the NIF otp/erts/emulator/nifs/erxos/erx_area_nif.c.
The connection agent maps a connection's area when it maps the connection's
sides and holds the mapping until the connection ends; `open/1` hands it to
the processes that draw into it or read it, and `erx_memdraw:wrap/4` makes
images over it. The area stays mapped while any term or image refers to it,
and the agent answers that the connection is unmapped only after the last
one is gone.

A range of a writable area is lent to one program with `lend/4`, which only
`erx_pixels`, the one lender, calls: the lease keeps the area mapped until
the program driver returns it, after the program's sub-space has ended.
""".

-nifs([map/4, lend/4, unlend/1]).
-on_load(on_load/0).

-export([open/1, map/4, lend/4, unlend/1]).

-type area() :: reference().
-export_type([area/0]).

on_load() ->
    erlang:load_nif(atom_to_list(?MODULE), 0).

-doc """
The pixel area of this domain's connection to domain Peer, `{ok, Area,
Bytes}`, writable for the client of a display and read-only for the display,
or `{error, none}` for a connection without one or no connection, and in
the system domain, whose agent serves no introductions; `{error, noproc}`
where no agent runs.
""".
-spec open(pos_integer()) -> {ok, area(), pos_integer()} | {error, none | noproc}.
open(Peer) ->
    case erx_connections:area(Peer) of
        {error, badarg} -> {error, none};
        Answer -> Answer
    end.

-doc """
For the connection agent alone: maps the Bytes of the memory object in Slot,
read-write for `write` and read-only for `read`. The caller is sent
`{erx_area_unmapped, Tag}` once the area is unmapped, after the last
reference to it is gone. `{error, einval}` for a length that is not whole
pages or an object the kernel refuses to map so.
""".
-spec map(non_neg_integer(), pos_integer(), write | read, reference()) ->
          {ok, area()} | {error, einval | enomem}.
map(_Slot, _Bytes, _Mode, _Tag) -> erlang:nif_error(undef).

-doc """
For `erx_pixels` alone: a held lease of the Pages pages of Area from Offset,
for Holder, the range's owner, whose own program port alone can take it
(docs/design-display.md, "The pixel area", The lease). Answers the lease's
number, from 1 and never given again. The caller is sent
`{erx_area_returned, Lease}` once the lease is returned: given back with
`unlend/1` or ended by Holder's exit while held, or returned by the program
driver once taken.

`{error, einval}` for an Offset off a page boundary, Pages of 0 or more than
the buffer place holds, a range past the area's end, and a read-only area;
`{error, noproc}`, making no lease, for a Holder that has exited. Offset and
Pages outside 0..2^64-1, a Holder that is no local pid, or an Area that is
no area, are `badarg`.
""".
-spec lend(area(), non_neg_integer(), non_neg_integer(), pid()) ->
          {ok, pos_integer()} | {error, einval | noproc | enomem}.
lend(_Area, _Offset, _Pages, _Holder) -> erlang:nif_error(undef).

-doc """
For `erx_pixels` alone: returns the lease numbered Lease if it is held, and
does nothing to one taken, returned or never made, so a handler gives back
after any failed start without knowing how far the start went. `badarg` for
a term that is no integer from 1 to 2^64 - 1.
""".
-spec unlend(pos_integer()) -> ok.
unlend(_Lease) -> erlang:nif_error(undef).
