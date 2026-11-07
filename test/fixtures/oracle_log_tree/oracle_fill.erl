%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
-module(oracle_fill).
-moduledoc false.
-export([fill/1]).

%% Above /tmp's 160 MiB cap on erXos, so the writes stop at the cap there.
-define(MOST, (192 bsl 20)).
-define(NODES, 4096).

%% Fills the tree of the directory Dir, as sendfile_SUITE's init_per_suite
%% does, and to its last charge: a refused write is retried at half its
%% size, down to one byte, and then empty files are made until a create is
%% refused, so not even a directory fits after it.
fill(Dir) ->
    {ok, File} = file:open(filename:join(Dir, "fill"), [write, raw, binary]),
    ok = fill(File, 1 bsl 20, ?MOST),
    _ = file:close(File),
    nodes(Dir, 0).

fill(_File, Size, Left) when Size =:= 0; Left =< 0 ->
    ok;
fill(File, Size, Left) ->
    case file:write(File, binary:copy(<<0>>, Size)) of
        ok -> fill(File, Size, Left - Size);
        {error, _} -> fill(File, Size div 2, Left)
    end.

%% Empty files until a create is refused; at most ?NODES of them, so a
%% tree without a cap ends too.
nodes(_Dir, ?NODES) ->
    ok;
nodes(Dir, N) ->
    case file:write_file(filename:join(Dir, "node." ++ integer_to_list(N)), <<>>) of
        ok -> nodes(Dir, N + 1);
        {error, _} -> ok
    end.
