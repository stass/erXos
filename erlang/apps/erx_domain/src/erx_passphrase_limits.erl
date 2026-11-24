%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_passphrase_limits).
-moduledoc """
The passphrase check's failure counts (docs/design-login.md, "The passphrase
check"), the vault's for the network class: a check is `limited` when its name
has had 5 failures, or its terminal 5, less than 60 s after that counter's last
failure. A pure value: admit/4 decides and failed/4 records, each given the
time in milliseconds.

A counter is its count and its last failure. One whose last failure is 60 s old
starts again at one, and every counter that old is dropped at each failure, so
no more counters live than failures fit in a minute.
""".

-export([new/0, admit/4, failed/4, size/1]).
-export_type([counts/0]).

-define(FAILURES, 5).
-define(WINDOW_MS, 60000).

-doc "The counters, by name and by terminal.".
-opaque counts() :: #{{name, binary()} | {terminal, term()} => {pos_integer(), integer()}}.

-doc "No failures.".
-spec new() -> counts().
new() -> #{}.

-doc "`ok`, or `limited` when the name's or the terminal's counter is full at `Now`.".
-spec admit(binary(), term(), integer(), counts()) -> ok | limited.
admit(Name, Terminal, Now, Counts) ->
    case full({name, Name}, Now, Counts) orelse full({terminal, Terminal}, Now, Counts) of
        true -> limited;
        false -> ok
    end.

-doc "`Counts` with one failure of `Name` from `Terminal` at `Now`.".
-spec failed(binary(), term(), integer(), counts()) -> counts().
failed(Name, Terminal, Now, Counts) ->
    Live = maps:filter(fun(_Key, {_Count, Last}) -> live(Last, Now) end, Counts),
    bump({terminal, Terminal}, Now, bump({name, Name}, Now, Live)).

-doc "How many counters live, for the checker's status.".
-spec size(counts()) -> non_neg_integer().
size(Counts) -> map_size(Counts).

full(Key, Now, Counts) ->
    case maps:find(Key, Counts) of
        {ok, {Count, Last}} -> Count >= ?FAILURES andalso live(Last, Now);
        error -> false
    end.

bump(Key, Now, Counts) ->
    Count = case maps:find(Key, Counts) of
                {ok, {Before, Last}} -> case live(Last, Now) of true -> Before + 1; false -> 1 end;
                error -> 1
            end,
    Counts#{Key => {Count, Now}}.

live(Last, Now) -> Now - Last < ?WINDOW_MS.
