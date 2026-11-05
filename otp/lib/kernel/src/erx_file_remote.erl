%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% prim_file's operations on a path below a file server's grant (design-files.md, Erlang
%% clients). prim_file's NIF answers such a path with the grant's pid and the names below
%% the grant's root, and prim_file calls the operation here, in the calling process.
%%
%% This module is the dispatch's far end only: it answers every operation with
%% {error, enotsup}. TODO.md records the client that replaces it.

-module(erx_file_remote).

-export([open/3, read_file/2, read_link/3, list_dir/3, read_file_info/4,
         write_file_info/3, set_cwd/2, delete/2, rename/4, make_dir/2, del_dir/2,
         make_link/4, make_symlink/3]).

-type names() :: binary().

-spec open(pid(), names(), list()) -> {error, enotsup}.
open(_Pid, _Names, _Modes) -> {error, enotsup}.

-spec read_file(pid(), names()) -> {error, enotsup}.
read_file(_Pid, _Names) -> {error, enotsup}.

-spec read_link(pid(), names(), boolean()) -> {error, enotsup}.
read_link(_Pid, _Names, _AcceptRawNames) -> {error, enotsup}.

-spec list_dir(pid(), names(), boolean()) -> {error, enotsup}.
list_dir(_Pid, _Names, _SkipInvalid) -> {error, enotsup}.

-spec read_file_info(pid(), names(), 0 | 1, atom()) -> {error, enotsup}.
read_file_info(_Pid, _Names, _FollowLinks, _TimeType) -> {error, enotsup}.

-spec write_file_info(pid(), names(), tuple()) -> {error, enotsup}.
write_file_info(_Pid, _Names, _Info) -> {error, enotsup}.

-spec set_cwd(pid(), names()) -> {error, enotsup}.
set_cwd(_Pid, _Names) -> {error, enotsup}.

-spec delete(pid(), names()) -> {error, enotsup}.
delete(_Pid, _Names) -> {error, enotsup}.

%% A two-path operation's names are those of its first path on a grant; it gets both
%% paths as prim_file was given them.
-spec rename(pid(), names(), file:name_all(), file:name_all()) -> {error, enotsup}.
rename(_Pid, _Names, _Source, _Destination) -> {error, enotsup}.

-spec make_dir(pid(), names()) -> {error, enotsup}.
make_dir(_Pid, _Names) -> {error, enotsup}.

-spec del_dir(pid(), names()) -> {error, enotsup}.
del_dir(_Pid, _Names) -> {error, enotsup}.

-spec make_link(pid(), names(), file:name_all(), file:name_all()) -> {error, enotsup}.
make_link(_Pid, _Names, _Existing, _New) -> {error, enotsup}.

-spec make_symlink(pid(), names(), file:name_all()) -> {error, enotsup}.
make_symlink(_Pid, _Names, _Existing) -> {error, enotsup}.
