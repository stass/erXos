%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_mount).
-moduledoc """
`mount`: one line for each entry of the domain's namespace table
(docs/design-files.md, "Building, binding and mounting"), in the shape of
FreeBSD's: what provides it, `on`, the point it is mounted at, and in
parentheses its rights and the root within the provider. Each name goes
through the field escape, so a line holds no control character. The
table is erXos's, so a runtime without one, such as stock OTP on the
host, answers `enotsup`. Changing the table (`mount` with arguments,
`bind`, `unmount`) is erx_ns's and has no command yet.
""".

-behaviour(erx_cmd).
-erx_command(mount).
-erx_usage("mount").

-export([run/2]).

run([], Ctx) ->
    case erlang:function_exported(prim_file, erx_table, 0) of
        true ->
            lists:foreach(fun(Entry) -> erx_cmd:write(Ctx, line(Entry)) end,
                          prim_file:erx_table());
        false ->
            {error, enotsup}
    end;
run(_Args, _Ctx) ->
    {error, usage}.

line(#{point := Point, provider := Provider, root := Root, rights := Rights}) ->
    [escape(provider(Provider)), <<" on ">>, escape(path(Point)), <<" (">>,
     escape(rights(Rights)), <<", root ">>, escape(path(Root)), <<")\n">>].

escape(Text) -> erx_text:escape_field(Text).

rights(Rights) when is_atom(Rights) -> atom_to_binary(Rights);
rights(Rights) -> unicode:characters_to_binary(io_lib:format("~0tp", [Rights])).

path([]) -> <<"/">>;
path(Names) -> iolist_to_binary([[$/, Name] || Name <- Names]).

provider(release) -> <<"release">>;
provider({erofs, _Fs}) -> <<"erofs">>;
provider({grant, Pid, Tree}) -> iolist_to_binary([<<"grant ">>, pid_to_list(Pid), $\s, Tree]);
provider(ended) -> <<"ended">>.
