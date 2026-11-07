%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_mount).
-moduledoc """
`mount`: one record for each entry of the domain's namespace table
(docs/design-files.md, "Building, binding and mounting"): the point it
is mounted at, what provides it, the root within the provider and its
rights. The table is erXos's, so a runtime without one, such as stock
OTP on the host, answers `enotsup`. Changing the table (`mount` with
arguments, `bind`, `unmount`) is erx_ns's and has no command yet.
""".

-behaviour(erx_cmd).
-erx_command(mount).
-erx_usage("mount").
-erx_fields([point, provider, root, rights]).

-export([run/2]).

run([], Ctx) ->
    case erlang:function_exported(prim_file, erx_table, 0) of
        true ->
            lists:foreach(fun(Entry) -> erx_cmd:emit(Ctx, record(Entry)) end,
                          prim_file:erx_table());
        false ->
            {error, enotsup}
    end;
run(_Args, _Ctx) ->
    {error, usage}.

record(#{point := Point, provider := Provider, root := Root, rights := Rights}) ->
    #{point => ok(path(Point)), provider => ok(provider(Provider)),
      root => ok(path(Root)), rights => ok(Rights)}.

ok(Value) -> {runtime, {ok, Value}}.

path([]) -> <<"/">>;
path(Names) -> iolist_to_binary([[$/, Name] || Name <- Names]).

provider(release) -> <<"release">>;
provider({erofs, _Fs}) -> <<"erofs">>;
provider({grant, Pid, Tree}) -> iolist_to_binary([<<"grant ">>, pid_to_list(Pid), $\s, Tree]);
provider(ended) -> <<"ended">>.
