%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_mount).
-moduledoc """
`mount`: one line for each entry of the domain's namespace table
(docs/design-files.md, "Building, binding and mounting"), in FreeBSD's
layout (sbin/mount/mount.c, prmount): `SOURCE on POINT (TYPE, OPTIONS)`.

* **Source.** What provides the entry: `release` or `erofs` for a local
  provider, `PID:/TREE` for a grant, the server's pid and the tree it
  roots in, as NFS writes `host:/export`, and `ended` for a grant whose
  server ended. A bind's root within the provider follows as a path:
  `release:/lib`, `PID:/data/a`.
* **Type.** The file system behind the entry, FreeBSD's `f_fstypename`:
  a local provider's own (`release`, `erofs`), and a grant's as its
  server answers statfs at the entry's root. 9P2000.L's statfs carries
  the type as a number, the `p9_magic_` limits of abi/protocols/9p.txt,
  which type_name/1 names; a number it does not know prints in hex, as
  the server sent it, and a server that does not answer, or an ended
  grant, prints `-`, as a command prints a value it does not have
  (docs/design-shell.md, SH3).
* **Options.** FreeBSD's words (MNTOPT_NAMES in sys/sys/mount.h), in
  their order: `local` for a provider the domain reads itself, and
  `read-only` for rights other than `rw`. FreeBSD has no word for a
  grant, a tree another process serves; `grant` stands where `local`
  would, since a grant is the one kind of entry that is not local.

Each name goes through the field escape, so a line holds no control
character, and the type is a name of type_name/1's or a number of at most
ten characters, never text a server chose. The table is erXos's, so a
runtime without one, such as stock OTP on the host, answers `enotsup`.
Changing the table (`mount` with arguments, `bind`, `unmount`) is
erx_ns's and has no command yet.
""".

-behaviour(erx_cmd).
-erx_command(mount).
-erx_usage("mount").

-export([run/2]).
-export([line/2, type_name/1]).

-include("generated/erx_abi.hrl").

%% The type of the file system behind an entry: a local provider's own, the number a
%% grant's server answered statfs with, or unknown when there is none.
-type fs_type() :: release | erofs | {magic, 0..16#ffffffff} | unknown.

run([], Ctx) ->
    case erlang:function_exported(prim_file, erx_table, 0) of
        true ->
            lists:foreach(fun(Entry) -> erx_cmd:write(Ctx, line(Entry, fs_type(Entry))) end,
                          prim_file:erx_table());
        false ->
            {error, enotsup}
    end;
run(_Args, _Ctx) ->
    {error, usage}.

%% The one effect: a grant's statfs, sent through erx_file_remote as every request on a
%% grant is, at the entry's root. The server's reply is untrusted; the grammar holds its
%% type to a u32, and anything else is unknown.
-spec fs_type(map()) -> fs_type().
fs_type(#{provider := release}) -> release;
fs_type(#{provider := {erofs, _}}) -> erofs;
fs_type(#{provider := {grant, Pid, Tree}, rights := Rights, root := Root}) ->
    case erx_file_remote:statfs({Pid, Tree, Rights}, {target, Root}) of
        {ok, #{type := Magic}} when is_integer(Magic), Magic >= 0, Magic =< 16#ffffffff ->
            {magic, Magic};
        _ -> unknown
    end;
fs_type(#{}) -> unknown.

-doc "The line `mount` prints for an entry, given the type of the file system behind it.".
-spec line(map(), fs_type()) -> iodata().
line(#{point := Point, provider := Provider, root := Root, rights := Rights}, Type) ->
    [escape(source(Provider, Root)), <<" on ">>, escape(path(Point)), <<" (">>,
     lists:join(<<", ">>, [type_name(Type) | locality(Provider) ++ rights_options(Rights)]),
     <<")\n">>].

-doc """
The name of a file system type: FreeBSD's where FreeBSD has the file system
(`tmpfs`, `procfs`, `devfs`), else the name its own project gives it.
""".
-spec type_name(fs_type()) -> binary().
type_name(release) -> <<"release">>;
type_name(erofs) -> <<"erofs">>;
type_name({magic, ?ERX_P9_MAGIC_LITTLEFS}) -> <<"littlefs">>;
type_name({magic, ?ERX_P9_MAGIC_TMPFS}) -> <<"tmpfs">>;
type_name({magic, ?ERX_P9_MAGIC_PROC}) -> <<"procfs">>;
type_name({magic, ?ERX_P9_MAGIC_DEVFS}) -> <<"devfs">>;
type_name({magic, ?ERX_P9_MAGIC_RAMFS}) -> <<"ramfs">>;
type_name({magic, Magic}) ->
    iolist_to_binary(["0x", string:lowercase(integer_to_list(Magic, 16))]);
type_name(unknown) -> <<"-">>.

%% FreeBSD's local for a provider the domain reads itself; a grant, like an NFS
%% mount, has no word, its PID:/TREE source shows another process serves it.
locality(release) -> [<<"local">>];
locality({erofs, _}) -> [<<"local">>];
locality({grant, _, _}) -> [];
locality(ended) -> [].

rights_options(rw) -> [];
rights_options(_) -> [<<"read-only">>].

escape(Text) -> erx_text:escape_field(Text).

source(release, Root) -> named_source(<<"release">>, Root);
source({erofs, _Fs}, Root) -> named_source(<<"erofs">>, Root);
source({grant, Pid, Tree}, Root) ->
    iolist_to_binary([pid_to_list(Pid), $:, path([Tree | Root])]);
source(ended, Root) -> named_source(<<"ended">>, Root).

named_source(Name, []) -> Name;
named_source(Name, Root) -> iolist_to_binary([Name, $:, path(Root)]).

path([]) -> <<"/">>;
path(Names) -> iolist_to_binary([[$/, Name] || Name <- Names]).
