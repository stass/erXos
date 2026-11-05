%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_stale_tree).
-moduledoc """
erx_fs_test_tree, with the callbacks named in its `{stale, Callbacks}`
argument answering as a module that keeps its tree as a value would: with a
next state appended to each answer, `ok` as `{ok, Fs}` and `{ok, ...}` as
`{ok, ..., Fs}`. None of those is a shape of the `erx_fs` behaviour, so
erx_fs must answer each request that reaches one `eio` and go on serving.
Every other callback, and every error, is erx_fs_test_tree's unchanged.
""".

-behaviour(erx_fs).

-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4,
         readlink/2, statfs/1, clunk/2, write/4, make/4, setattr/3, unlink/4,
         rename/5]).

-doc "erx_fs_test_tree's tree; `Args` may hold `{stale, Callbacks}` and `{observer, Pid}`.".
init(Args) ->
    {ok, Tree} = erx_fs_test_tree:init(Args),
    {ok, {proplists:get_value(stale, Args, []), Tree}}.

root(Fs) -> delegate(root, [], Fs).
walk(Dir, Name, Fs) -> delegate(walk, [Dir, Name], Fs).
getattr(Node, Fs) -> delegate(getattr, [Node], Fs).
open(Node, Flags, Fs) -> delegate(open, [Node, Flags], Fs).
read(Handle, Offset, Count, Fs) -> delegate(read, [Handle, Offset, Count], Fs).
readdir(Handle, Offset, Max, Fs) -> delegate(readdir, [Handle, Offset, Max], Fs).
readlink(Node, Fs) -> delegate(readlink, [Node], Fs).
statfs(Fs) -> delegate(statfs, [], Fs).
clunk(Handle, Fs) -> delegate(clunk, [Handle], Fs).
write(Handle, Offset, Data, Fs) -> delegate(write, [Handle, Offset, Data], Fs).
make(Dir, Name, What, Fs) -> delegate(make, [Dir, Name, What], Fs).
setattr(Target, Changes, Fs) -> delegate(setattr, [Target, Changes], Fs).
unlink(Dir, Name, Kind, Fs) -> delegate(unlink, [Dir, Name, Kind], Fs).
rename(Dir, Name, NewDir, NewName, Fs) -> delegate(rename, [Dir, Name, NewDir, NewName], Fs).

%% erx_fs_test_tree's answer, with the handle appended when Callback is stale.
delegate(Callback, Arguments, {Stale, Tree} = Fs) ->
    Answer = apply(erx_fs_test_tree, Callback, Arguments ++ [Tree]),
    case lists:member(Callback, Stale) of
        true -> with_state(Answer, Fs);
        false -> Answer
    end.

with_state(ok, Fs) -> {ok, Fs};
with_state({ok, _} = Answer, Fs) -> erlang:append_element(Answer, Fs);
with_state({ok, _, _} = Answer, Fs) -> erlang:append_element(Answer, Fs);
with_state({ok, _, _, _} = Answer, Fs) -> erlang:append_element(Answer, Fs);
with_state({error, _} = Error, _) -> Error.
