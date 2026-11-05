%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% prim_file's operations on a path below a file server's grant (design-files.md, Erlang
%% clients). prim_file's NIF answers such a path with its mount entry's grant, {Pid, Tree,
%% Rights}, and the names from that tree's root, the entry's root included, and prim_file calls the
%% operation here, in the calling process. Rights are the entry's, so a read-only bind
%% of a writable grant arrives read-only.
%%
%% This module is the dispatch's far end only: it answers every operation with
%% {error, enotsup}. TODO.md records the client that replaces it.

-module(erx_file_remote).

-export([open/3, read_file/2, read_link/3, list_dir/3, read_file_info/4,
         write_file_info/3, set_cwd/2, delete/2, rename/5, make_dir/2, del_dir/2,
         make_link/5, make_symlink/3]).

-type names() :: binary().
-type grant() :: {pid(), Tree :: binary(), Rights :: ro | rw | rx}.

-spec open(grant(), names(), list()) -> {error, enotsup}.
open(_Grant, _Names, _Modes) -> {error, enotsup}.

-spec read_file(grant(), names()) -> {error, enotsup}.
read_file(_Grant, _Names) -> {error, enotsup}.

-spec read_link(grant(), names(), boolean()) -> {error, enotsup}.
read_link(_Grant, _Names, _AcceptRawNames) -> {error, enotsup}.

-spec list_dir(grant(), names(), boolean()) -> {error, enotsup}.
list_dir(_Grant, _Names, _SkipInvalid) -> {error, enotsup}.

-spec read_file_info(grant(), names(), 0 | 1, atom()) -> {error, enotsup}.
read_file_info(_Grant, _Names, _FollowLinks, _TimeType) -> {error, enotsup}.

-spec write_file_info(grant(), names(), tuple()) -> {error, enotsup}.
write_file_info(_Grant, _Names, _Info) -> {error, enotsup}.

-spec set_cwd(grant(), names()) -> {error, enotsup}.
set_cwd(_Grant, _Names) -> {error, enotsup}.

-spec delete(grant(), names()) -> {error, enotsup}.
delete(_Grant, _Names) -> {error, enotsup}.

%% A two-path operation reaches here only when both its paths lie on one grant's
%% tree through one set of rights; it gets both names, and both paths as prim_file
%% was given them.
-spec rename(grant(), names(), names(), file:name_all(), file:name_all()) ->
          {error, enotsup}.
rename(_Grant, _Names, _OtherNames, _Source, _Destination) -> {error, enotsup}.

-spec make_dir(grant(), names()) -> {error, enotsup}.
make_dir(_Grant, _Names) -> {error, enotsup}.

-spec del_dir(grant(), names()) -> {error, enotsup}.
del_dir(_Grant, _Names) -> {error, enotsup}.

-spec make_link(grant(), names(), names(), file:name_all(), file:name_all()) ->
          {error, enotsup}.
make_link(_Grant, _Names, _OtherNames, _Existing, _New) -> {error, enotsup}.

-spec make_symlink(grant(), names(), file:name_all()) -> {error, enotsup}.
make_symlink(_Grant, _Names, _Existing) -> {error, enotsup}.
