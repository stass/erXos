%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_version).
-moduledoc """
The domain's file version counter (docs/design-files.md#identity-and-version).

Every file server of the domain draws a file's version, and `/tmp` its inode
numbers, from one unsigned 64-bit `atomics` cell that the runtime makes once,
before any file server starts, and publishes through `persistent_term`, so it
lives as long as the runtime and no server's restart resets it. Draws start at
1 and never repeat: at 2^64 - 1 the counter refuses with `eio` rather than
wrap, which `atomics:add_get/3` would do.
""".

-export([init/0, draw/0, new/0, draw/1]).

-define(KEY, {?MODULE, counter}).
-define(LAST, 16#ffffffffffffffff).

-doc """
Makes the domain's counter and publishes it, once: a counter already made is
kept, so a later call cannot reset it. It runs once, from the kernel
application's startup before any file server: two first calls at once could each
publish a counter of their own.
""".
-spec init() -> ok.
init() ->
    case persistent_term:get(?KEY, undefined) of
        undefined -> persistent_term:put(?KEY, new());
        _ -> ok
    end.

-doc "The next value of the domain's counter; `init/0` must have run.".
-spec draw() -> {ok, 1..?LAST} | {error, eio}.
draw() ->
    draw(persistent_term:get(?KEY)).

-doc "A counter of its own, not published, whose first draw is 1.".
-spec new() -> atomics:atomics_ref().
new() ->
    atomics:new(1, [{signed, false}]).

-doc "The next value of `Counter`, or `{error, eio}` once it has drawn 2^64 - 1.".
-spec draw(atomics:atomics_ref()) -> {ok, 1..?LAST} | {error, eio}.
draw(Counter) ->
    draw(Counter, atomics:get(Counter, 1)).

draw(_, ?LAST) ->
    {error, eio};
draw(Counter, Seen) ->
    case atomics:compare_exchange(Counter, 1, Seen, Seen + 1) of
        ok -> {ok, Seen + 1};
        Current -> draw(Counter, Current)
    end.
