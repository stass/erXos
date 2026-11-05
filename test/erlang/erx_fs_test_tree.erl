%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_test_tree).
-moduledoc """
A small `erx_fs` tree held in the grant's state, for erx_fs_tests.

It starts as

    /        directory, inode 1
    /a       directory, inode 2
    /a/b     directory, inode 3
    /a/f     file, inode 4
    /l       symbolic link to "a", inode 5
    /f       file, inode 6

and keeps directories, files and links, made, removed and renamed through
`make`, `unlink` and `rename`. It opens nothing. With `{observer, Pid}` in its
arguments, every callback first sends `{tree_call, Callback}` to `Pid`, so a
test can show a request never reached the tree. A walk of ".." crashes the
grant: erx_fs must answer ".." itself.
""".

-behaviour(erx_fs).

-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4,
         readlink/2, statfs/1, clunk/2, write/4, make/4, setattr/3, unlink/4,
         rename/5]).

-define(QTDIR, 16#80).
-define(QTSYMLINK, 16#02).
-define(QTFILE, 0).
-define(ROOT, 1).

-doc "The tree above; `Args` may hold `{observer, Pid}`.".
init(Args) ->
    Nodes = #{1 => directory(#{<<"a">> => 2, <<"l">> => 5, <<"f">> => 6}),
              2 => directory(#{<<"b">> => 3, <<"f">> => 4}),
              3 => directory(#{}),
              4 => #{kind => file, mode => 8#644},
              5 => #{kind => symlink, mode => 8#777, target => <<"a">>},
              6 => #{kind => file, mode => 8#644}},
    {ok, #{nodes => Nodes, next => 7,
           observer => proplists:get_value(observer, Args, none)}}.

directory(Entries) ->
    #{kind => directory, mode => 8#755, entries => Entries}.

-doc "The tree is named `test`.".
root(State) ->
    seen(root, State),
    {ok, <<"test">>, ?ROOT, qid(?ROOT, State)}.

-doc "One plain name in a directory.".
walk(_, <<"..">>, _) ->
    erlang:error(dotdot_reached_the_tree);
walk(Dir, Name, State) ->
    seen(walk, State),
    case node(Dir, State) of
        #{kind := directory, entries := #{Name := Ino}} -> {ok, Ino, qid(Ino, State)};
        #{kind := directory} -> {error, enoent};
        #{} -> {error, enotdir}
    end.

-doc "The 9P2000.L attributes of a node.".
getattr(Ino, State) ->
    seen(getattr, State),
    #{kind := Kind, mode := Mode} = node(Ino, State),
    Zero = maps:from_keys([uid, gid, rdev, size, blocks, atime_sec, atime_nsec,
                           mtime_sec, mtime_nsec, ctime_sec, ctime_nsec, btime_sec,
                           btime_nsec, gen, data_version], 0),
    {ok, Zero#{valid => 16#7ff, qid => qid(Ino, State), mode => type_bits(Kind) bor Mode,
               nlink => 1, blksize => 4096}}.

-doc "Nothing is opened.".
open(_, _, State) -> seen(open, State), {error, enotsup}.
-doc "Nothing is open.".
read(_, _, _, State) -> seen(read, State), {error, ebadf}.
-doc "Nothing is open.".
readdir(_, _, _, State) -> seen(readdir, State), {error, ebadf}.
-doc "Nothing is open.".
clunk(_, State) -> seen(clunk, State), {ok, State}.
-doc "Nothing is open; present so that the tree counts as one that writes.".
write(_, _, _, State) -> seen(write, State), {error, ebadf}.

-doc "A link's text.".
readlink(Ino, State) ->
    seen(readlink, State),
    case node(Ino, State) of
        #{kind := symlink, target := Target} -> {ok, Target};
        #{} -> {error, einval}
    end.

-doc "Fixed numbers.".
statfs(State) ->
    seen(statfs, State),
    {ok, #{type => 16#01021994, bsize => 4096, blocks => 16, bfree => 8, bavail => 8,
           files => 64, ffree => 58, fsid => 0, namelen => 255}}.

-doc "A directory, a link or another name for a node; nothing else.".
make(Dir, Name, What, State) ->
    seen(make, State),
    case node(Dir, State) of
        #{kind := directory, entries := #{Name := _}} -> {error, eexist};
        #{kind := directory} -> made(Dir, Name, What, State);
        #{} -> {error, enotdir}
    end.

made(Dir, Name, {link, Ino}, State) ->
    case node(Ino, State) of
        #{kind := directory} -> {error, eperm};
        #{} -> {ok, Ino, qid(Ino, State), enter(Dir, Name, Ino, State)}
    end;
made(Dir, Name, What, #{nodes := Nodes, next := Ino} = State) ->
    case new_node(What) of
        {ok, Node} ->
            State1 = State#{nodes := Nodes#{Ino => Node}, next := Ino + 1},
            {ok, Ino, qid(Ino, State1), enter(Dir, Name, Ino, State1)};
        {error, _} = Error ->
            Error
    end.

new_node({directory, Mode}) -> {ok, (directory(#{}))#{mode := Mode}};
new_node({symlink, Target}) -> {ok, #{kind => symlink, mode => 8#777, target => Target}};
new_node(_) -> {error, eperm}.

-doc "Changes the mode of a node when `valid` asks for it.".
setattr({node, Ino}, #{valid := Valid, mode := Mode}, #{nodes := Nodes} = State) ->
    seen(setattr, State),
    Node = node(Ino, State),
    case Valid band 1 of
        0 -> {ok, State};
        1 -> {ok, State#{nodes := Nodes#{Ino := Node#{mode := Mode band 8#7777}}}}
    end.

-doc "Removes a name, refusing a kind that does not match.".
unlink(Dir, Name, Kind, State) ->
    seen(unlink, State),
    case node(Dir, State) of
        #{kind := directory, entries := #{Name := Ino}} ->
            case {Kind, node(Ino, State)} of
                {directory, #{kind := Other}} when Other =/= directory -> {error, enotdir};
                {file, #{kind := directory}} -> {error, eisdir};
                {_, #{kind := directory, entries := Entries}} when map_size(Entries) > 0 ->
                    {error, enotempty};
                _ -> {ok, leave(Dir, Name, State)}
            end;
        #{kind := directory} -> {error, enoent};
        #{} -> {error, enotdir}
    end.

-doc "Moves a name, replacing what the new name named.".
rename(Dir, Name, NewDir, NewName, State) ->
    seen(rename, State),
    case node(Dir, State) of
        #{kind := directory, entries := #{Name := Ino}} ->
            {ok, enter(NewDir, NewName, Ino, leave(Dir, Name, State))};
        #{} ->
            {error, enoent}
    end.

enter(Dir, Name, Ino, #{nodes := Nodes} = State) ->
    #{Dir := #{entries := Entries} = Node} = Nodes,
    State#{nodes := Nodes#{Dir := Node#{entries := Entries#{Name => Ino}}}}.

leave(Dir, Name, #{nodes := Nodes} = State) ->
    #{Dir := #{entries := Entries} = Node} = Nodes,
    State#{nodes := Nodes#{Dir := Node#{entries := maps:remove(Name, Entries)}}}.

node(Ino, #{nodes := Nodes}) ->
    maps:get(Ino, Nodes).

qid(Ino, State) ->
    #{kind := Kind} = node(Ino, State),
    {qid_type(Kind), 0, Ino}.

qid_type(directory) -> ?QTDIR;
qid_type(symlink) -> ?QTSYMLINK;
qid_type(file) -> ?QTFILE.

type_bits(directory) -> 8#040000;
type_bits(symlink) -> 8#120000;
type_bits(file) -> 8#100000.

seen(Callback, #{observer := Observer}) when is_pid(Observer) ->
    Observer ! {tree_call, Callback},
    ok;
seen(_, _) ->
    ok.
