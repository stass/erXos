%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The kernel log from Erlang (docs/design-stopgap.md, "The console"): a labelled line into
%% it, and the console's read of the lines nobody has taken. A read returns each record as
%% the line the log core rendered, so every byte of a record's text is already escaped, tab
%% and newline included, and the line's own newline is its only control byte.

-module(erx_log).

-export([debug/1, read/1]).

-nifs([debug_nif/1, read_nif/1]).
-on_load(on_load/0).

-spec on_load() -> ok | {error, term()}.
on_load() ->
    erlang:load_nif(atom_to_list(?MODULE), #{}).

%% One debug-level record of at most a UTCB's bytes, opened with the caller's space.
-spec debug(iodata()) -> ok | {error, integer()}.
debug(Bytes) ->
    debug_nif(Bytes).

%% The lines after Cursor, oldest first; the cursor to pass next; and how many records were
%% overwritten before anyone read them. corrupt says a record failed the reader's checks,
%% so the lines stop short of the cursor. The log has one reader, erx_console: a read takes
%% what it returns for every reader.
-spec read(non_neg_integer()) ->
          {ok | corrupt, Next :: non_neg_integer(), Lost :: non_neg_integer(), [binary()]}
          | {error, integer()}.
read(Cursor) ->
    read_nif(Cursor).

debug_nif(_Bytes) ->
    erlang:nif_error(undef).

read_nif(_Cursor) ->
    erlang:nif_error(undef).
