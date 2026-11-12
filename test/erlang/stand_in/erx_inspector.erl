%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erXos's erx_inspector as the host tests of the shell's commands see it: a
%% domain that holds no inspect facet, so every query is answered `no_facet`,
%% as erx_inspector:route/3 answers one outside the system domain, unless a
%% test has set the persistent term `erx_inspector` to a fun from a path to
%% the answer its facet would give.

-module(erx_inspector).

-export([inspect/1, inspect/2, entries/1, overview/0, proc_id/1]).

inspect(Path) -> inspect(Path, #{}).

inspect(Path, _Options) -> (persistent_term:get(erx_inspector, fun(_) -> {error, no_facet} end))(Path).

entries(_Path) -> {error, no_facet}.

overview() -> [{[], inspect([])}, {[processes], entries([processes])}].

proc_id(Pid) ->
    [_Node, Number, Serial] = string:lexemes(pid_to_list(Pid), "<.>"),
    {pid, 4, list_to_integer(Number), list_to_integer(Serial)}.
