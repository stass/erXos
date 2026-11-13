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
""".

-nifs([map/4]).
-on_load(on_load/0).

-export([open/1, map/4]).

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
