%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The kernel log from Erlang (docs/design-stopgap.md, "The console"): a labelled line into
%% it, a read from a cursor of the reader's own, and the log service's take of the lines
%% nobody has taken. Both return each record as the line the log core rendered, so every byte of a
%% record's text is already escaped, tab and newline included, and the line's own newline is
%% its only control byte.

-module(erx_log).

-export([debug/1, debug_text/1, read/1, take/0]).
-export_type([lines/0]).

-include("generated/erx_abi.hrl").

-nifs([debug_nif/1, read_nif/1, take_nif/0]).
-on_load(on_load/0).

-spec on_load() -> ok | {error, term()}.
on_load() ->
    erlang:load_nif(atom_to_list(?MODULE), #{}).

%% One debug-level record of at most a UTCB's bytes, opened with the caller's space.
-spec debug(iodata()) -> ok | {error, integer()}.
debug(Bytes) ->
    debug_nif(Bytes).

%% Bytes as debug-level records of at most a UTCB's bytes each, in order: one record for
%% a short text, and pieces of ERX_UTCB_BYTES_MAX for a longer one. The log escapes each
%% byte on its own, so a character split between two pieces shows as it would whole.
%% Stops at the first piece the log refuses.
-spec debug_text(iodata()) -> ok | {error, integer()}.
debug_text(Bytes) ->
    pieces(iolist_to_binary(Bytes)).

pieces(<<Piece:?ERX_UTCB_BYTES_MAX/binary, Rest/binary>>) when Rest =/= <<>> ->
    case debug_nif(Piece) of
        ok -> pieces(Rest);
        Error -> Error
    end;
pieces(Last) ->
    debug_nif(Last).

-type lines() :: {ok | corrupt, Next :: non_neg_integer(), Lost :: non_neg_integer(), [binary()]}
               | {error, integer()}.

%% The lines from Cursor on, oldest first; the cursor to pass next; and how many records the
%% ring overwrote before the read reached them. corrupt says a record failed the reader's
%% checks, so the lines stop short of the cursor. A read changes nothing another reader or
%% the console sees, and a read from 0 also returns what the early console wrote.
-spec read(non_neg_integer()) -> lines().
read(Cursor) ->
    read_nif(Cursor).

%% The log service's read, erx_syslog's alone (docs/design-log.md, invariant L4): the
%% lines nobody has taken, which it takes, so each kernel line reaches the log once across
%% the handoff from the early console. Next says where the take stopped and needs passing
%% nowhere.
-spec take() -> lines().
take() ->
    take_nif().

debug_nif(_Bytes) ->
    erlang:nif_error(undef).

read_nif(_Cursor) ->
    erlang:nif_error(undef).

take_nif() ->
    erlang:nif_error(undef).
