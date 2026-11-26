%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_test_dir).
-moduledoc """
A scratch directory for an EUnit case. It is made in the working directory,
which each host test sets to a directory of its own run (Dir.mktmpdir) and
removes with the run, so two runs never share one; the integer separates the
cases of one run. It is made with `file:make_dir/1`, so a name already taken
fails the case instead of being shared.
""".

-export([new/0]).

-doc "Makes an empty directory and answers its absolute path.".
-spec new() -> file:filename().
new() ->
    Dir = filename:absname("scratch-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Dir),
    Dir.
