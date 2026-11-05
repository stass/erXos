%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_test_tree).
-moduledoc """
A small `erx_fs` tree, for erx_fs_tests.

It starts as

    /        directory, inode 1
    /a       directory, inode 2
    /a/b     directory, inode 3
    /a/f     file, inode 4
    /l       symbolic link to "a", inode 5
    /f       file, inode 6

and keeps directories, files and links, made, removed and renamed through
`make`, `unlink` and `rename`, and opens, reads and writes files and lists
directories. As an `erx_fs` tree with open files must, it keeps its nodes
where the grant and every file owner reach them: in a process of its own,
linked to the one that ran `init/1`, which applies each callback whole, so
every callback is atomic. Its handle, `Fs`, holds that process and the
observer.

A node lives while a name or an open holds it; an open of a node with no
name left is `enoent`. A handle is `{Ino, Access, Append}`: a read through
one opened only for writing, a write through one opened only for reading
and a size change through one not opened for writing are refused, and a
write through an append handle lands at the file's end and answers there.
Flags are Linux's, as 9P2000.L carries them. The tree has no `fsync`.

With `{observer, Pid}` in its arguments, every callback first sends
`{tree_call, Callback}` to `Pid`, so a test can show a request never reached
the tree. A walk of ".." crashes the grant: erx_fs must answer ".." itself.

With `{cap, Bytes}`, a write that would leave a file larger than `Bytes`
answers `enospc` and writes nothing, as a full tree answers.
""".

-behaviour(erx_fs).

-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4,
         readlink/2, statfs/1, clunk/2, write/4, make/4, setattr/3, unlink/4,
         rename/5]).

-define(QTDIR, 16#80).
-define(QTSYMLINK, 16#02).
-define(QTFILE, 0).
-define(ROOT, 1).
-define(O_ACCMODE, 3).
-define(O_EXCL, 8#200).
-define(O_TRUNC, 8#1000).
-define(O_APPEND, 8#2000).
-define(ATTR_MODE, 1).
-define(ATTR_SIZE, 8).
-define(DT_DIR, 4).
-define(DT_REG, 8).
-define(DT_LNK, 10).

-doc """
The tree above, in a process linked to the caller; `Args` may hold
`{observer, Pid}` and `{cap, Bytes}`.
""".
init(Args) ->
    Nodes = #{1 => directory(#{<<"a">> => 2, <<"l">> => 5, <<"f">> => 6}),
              2 => directory(#{<<"b">> => 3, <<"f">> => 4}),
              3 => directory(#{}),
              4 => file(8#644),
              5 => #{kind => symlink, mode => 8#777, target => <<"a">>, links => 1, opens => 0},
              6 => file(8#644)},
    Cap = proplists:get_value(cap, Args, infinity),
    Tree = spawn_link(fun() -> serve(#{nodes => Nodes, next => 7, cap => Cap}) end),
    {ok, #{tree => Tree, observer => proplists:get_value(observer, Args, none)}}.

directory(Entries) ->
    #{kind => directory, mode => 8#755, entries => Entries, links => 1, opens => 0}.

file(Mode) ->
    #{kind => file, mode => Mode, data => <<>>, links => 1, opens => 0}.

%% The tree's process: each request is a function of the tree, applied whole.
serve(Tree) ->
    receive
        {Caller, Ref, Step} ->
            {Reply, Tree1} = Step(Tree),
            Caller ! {Ref, Reply},
            serve(Tree1)
    end.

%% Applies Step to the tree and returns its reply. A Step's {Reply, Tree1}
%% replaces the tree; one that answers an error keeps it.
apply_step(#{tree := Tree}, Step) ->
    Ref = monitor(process, Tree),
    Tree ! {self(), Ref, Step},
    receive
        {Ref, Reply} -> demonitor(Ref, [flush]), Reply;
        {'DOWN', Ref, process, Tree, Why} -> exit({tree_ended, Why})
    end.

-doc "The tree is named `test`.".
root(Fs) ->
    seen(root, Fs),
    apply_step(Fs, fun(T) -> {{ok, <<"test">>, ?ROOT, qid(?ROOT, T)}, T} end).

-doc "One plain name in a directory.".
walk(_, <<"..">>, _) ->
    erlang:error(dotdot_reached_the_tree);
walk(Dir, Name, Fs) ->
    seen(walk, Fs),
    read_only(Fs, fun(T) ->
                             case node(Dir, T) of
                                 #{kind := directory, entries := #{Name := Ino}} -> {ok, Ino, qid(Ino, T)};
                                 #{kind := directory} -> {error, enoent};
                                 #{} -> {error, enotdir};
                                 gone -> {error, enoent}
                             end
                     end).

-doc "The 9P2000.L attributes of a node.".
getattr(Ino, Fs) ->
    seen(getattr, Fs),
    read_only(Fs, fun(T) ->
                             case node(Ino, T) of
                                 gone -> {error, enoent};
                                 #{kind := Kind, mode := Mode, links := Links} = Node ->
                                     Zero = maps:from_keys(
                                              [uid, gid, rdev, blocks, atime_sec, atime_nsec,
                                               mtime_sec, mtime_nsec, ctime_sec, ctime_nsec,
                                               btime_sec, btime_nsec, gen, data_version], 0),
                                     {ok, Zero#{valid => 16#7ff, qid => qid(Ino, T),
                                                mode => type_bits(Kind) bor Mode, nlink => Links,
                                                size => byte_size(maps:get(data, Node, <<>>)),
                                                blksize => 4096}}
                             end
                     end).

-doc "Opens a node that still has a name: a file, or a directory for reading.".
open(Ino, Flags, Fs) ->
    seen(open, Fs),
    change(Fs, fun(T) ->
                          case node(Ino, T) of
                              gone -> {error, enoent};
                              #{links := 0} -> {error, enoent};
                              Node -> opened(Ino, Node, Flags, T)
                          end
                  end).

opened(_, #{kind := symlink}, _, _) ->
    {error, eloop};
opened(Ino, #{kind := directory} = Node, Flags, T) when Flags band (?O_ACCMODE bor ?O_TRUNC) =:= 0 ->
    {ok, handle(Ino, Flags), put_node(Ino, Node#{opens := maps:get(opens, Node) + 1}, T)};
opened(_, #{kind := directory}, _, _) ->
    {error, eisdir};
opened(Ino, #{kind := file, data := Data, opens := Opens} = Node, Flags, T) ->
    Kept = case Flags band ?O_TRUNC of
               0 -> Data;
               _ -> <<>>
           end,
    {ok, handle(Ino, Flags), put_node(Ino, Node#{data := Kept, opens := Opens + 1}, T)}.

handle(Ino, Flags) ->
    Access = case Flags band ?O_ACCMODE of
                 0 -> read;
                 1 -> write;
                 _ -> read_write
             end,
    {Ino, Access, Flags band ?O_APPEND =/= 0}.

-doc "Bytes of a file, through a handle opened for reading.".
read({_, write, _}, _, _, Fs) ->
    seen(read, Fs),
    {error, ebadf};
read({Ino, _, _}, Offset, Count, Fs) ->
    seen(read, Fs),
    read_only(Fs, fun(T) ->
                             case node(Ino, T) of
                                 #{kind := file, data := Data} when Offset >= byte_size(Data) ->
                                     {ok, <<>>};
                                 #{kind := file, data := Data} ->
                                     {ok, binary:part(Data, Offset, min(Count, byte_size(Data) - Offset))};
                                 #{} ->
                                     {error, eisdir}
                             end
                     end).

-doc """
Writes through a handle opened for writing: at `Offset`, filling a gap with
zeros, or at the end through an append handle; answers where it wrote.
""".
write({_, read, _}, _, _, Fs) ->
    seen(write, Fs),
    {error, ebadf};
write({Ino, _, Append}, Offset, Bytes, Fs) ->
    seen(write, Fs),
    apply_step(Fs, fun(T) ->
                               #{data := Data} = Node = node(Ino, T),
                               #{cap := Cap} = T,
                               At = case Append of
                                        true -> byte_size(Data);
                                        false -> Offset
                                    end,
                               Data1 = spliced(Data, At, Bytes),
                               case byte_size(Data1) > Cap of
                                   true -> {{error, enospc}, T};
                                   false -> {{ok, byte_size(Bytes), At}, put_node(Ino, Node#{data := Data1}, T)}
                               end
                       end).

spliced(Data, At, Bytes) when At >= byte_size(Data) ->
    <<Data/binary, 0:((At - byte_size(Data)) * 8), Bytes/binary>>;
spliced(Data, At, Bytes) ->
    End = At + byte_size(Bytes),
    Tail = case End < byte_size(Data) of
               true -> binary:part(Data, End, byte_size(Data) - End);
               false -> <<>>
           end,
    <<(binary:part(Data, 0, At))/binary, Bytes/binary, Tail/binary>>.

-doc """
The entries of an open directory in name order, entry I at offset I, from
just past `Offset`.
""".
readdir({Ino, _, _}, Offset, Max, Fs) ->
    seen(readdir, Fs),
    read_only(Fs, fun(T) ->
                             case node(Ino, T) of
                                 #{kind := directory, entries := Entries} ->
                                     Sorted = lists:sort(maps:to_list(Entries)),
                                     Listed = lists:zip(lists:seq(1, length(Sorted)), Sorted),
                                     After = lists:nthtail(min(Offset, length(Listed)), Listed),
                                     {ok, [{qid(Child, T), Index, dirent_type(Child, T), Name}
                                           || {Index, {Name, Child}} <- lists:sublist(After, Max)]};
                                 #{} ->
                                     {error, enotdir}
                             end
                     end).

-doc "Drops an open; a node with no name and no open is gone.".
clunk({Ino, _, _}, Fs) ->
    seen(clunk, Fs),
    apply_step(Fs, fun(T) ->
                              #{opens := Opens} = Node = node(Ino, T),
                              {ok, kept(Ino, Node#{opens := Opens - 1}, T)}
                      end).

-doc "A link's text.".
readlink(Ino, Fs) ->
    seen(readlink, Fs),
    read_only(Fs, fun(T) ->
                             case node(Ino, T) of
                                 #{kind := symlink, target := Target} -> {ok, Target};
                                 _ -> {error, einval}
                             end
                     end).

-doc "Fixed numbers.".
statfs(Fs) ->
    seen(statfs, Fs),
    {ok, #{type => 16#01021994, bsize => 4096, blocks => 16, bfree => 8, bavail => 8,
           files => 64, ffree => 58, fsid => 0, namelen => 255}}.

-doc """
A directory, a link, another name for a node, or a file: created and opened,
or without `O_EXCL` the regular file the name already names, opened.
""".
make(Dir, Name, What, Fs) ->
    seen(make, Fs),
    apply_step(Fs, fun(T) ->
                              case node(Dir, T) of
                                  #{kind := directory, entries := #{Name := Ino}} -> answer(existing(Ino, What, T), T);
                                  #{kind := directory, links := 0} -> {{error, enoent}, T};
                                  #{kind := directory} -> answer(made(Dir, Name, What, T), T);
                                  #{} -> {{error, enotdir}, T};
                                  gone -> {{error, enoent}, T}
                              end
                      end).

existing(Ino, {file, _, Flags}, T) when Flags band ?O_EXCL =:= 0 ->
    case node(Ino, T) of
        #{kind := file} = Node ->
            {ok, Handle, T1} = opened(Ino, Node, Flags, T),
            {ok, Ino, qid(Ino, T1), Handle, T1};
        #{kind := directory} -> {error, eisdir};
        #{kind := symlink} -> {error, eloop}
    end;
existing(_, _, _) ->
    {error, eexist}.

made(Dir, Name, {link, Ino}, T) ->
    case node(Ino, T) of
        #{kind := directory} -> {error, eperm};
        #{links := Links} = Node ->
            T1 = put_node(Ino, Node#{links := Links + 1}, T),
            {ok, Ino, qid(Ino, T1), enter(Dir, Name, Ino, T1)}
    end;
made(Dir, Name, {file, Mode, Flags}, #{next := Ino} = T) ->
    T1 = put_node(Ino, (file(Mode))#{opens := 1}, T#{next := Ino + 1}),
    {ok, Ino, qid(Ino, T1), handle(Ino, Flags), enter(Dir, Name, Ino, T1)};
made(Dir, Name, What, #{next := Ino} = T) ->
    case new_node(What) of
        {ok, Node} ->
            T1 = put_node(Ino, Node, T#{next := Ino + 1}),
            {ok, Ino, qid(Ino, T1), enter(Dir, Name, Ino, T1)};
        {error, _} = Error ->
            Error
    end.

new_node({directory, Mode}) -> {ok, (directory(#{}))#{mode := Mode}};
new_node({symlink, Target}) -> {ok, #{kind => symlink, mode => 8#777, target => Target,
                                      links => 1, opens => 0}};
new_node(_) -> {error, eperm}.

-doc """
Changes a node's mode and a file's size when `valid` asks for them. A size
change through a handle needs one opened for writing (`einval`).
""".
setattr({open, {_, read, _}}, #{valid := Valid}, Fs) when Valid band ?ATTR_SIZE =/= 0 ->
    seen(setattr, Fs),
    {error, einval};
setattr({open, {Ino, _, _}}, Attr, Fs) ->
    setattr({node, Ino}, Attr, Fs);
setattr({node, Ino}, #{valid := Valid, mode := Mode, size := Size}, Fs) ->
    seen(setattr, Fs),
    change(Fs, fun(T) ->
                          case node(Ino, T) of
                              gone -> {error, enoent};
                              Node ->
                                  Node1 = case Valid band ?ATTR_MODE of
                                              0 -> Node;
                                              _ -> Node#{mode := Mode band 8#7777}
                                          end,
                                  {ok, put_node(Ino, sized(Valid band ?ATTR_SIZE, Size, Node1), T)}
                          end
                  end).

sized(0, _, Node) -> Node;
sized(_, Size, #{data := Data} = Node) when Size =< byte_size(Data) ->
    Node#{data := binary:part(Data, 0, Size)};
sized(_, Size, #{data := Data} = Node) ->
    Node#{data := <<Data/binary, 0:((Size - byte_size(Data)) * 8)>>}.

-doc """
Removes a name, refusing a kind that does not match: `file` and `directory`
from `unlinkat`, and `{node, Ino}` from `remove`, which removes the name only
while it still names that node.
""".
unlink(Dir, Name, Kind, Fs) ->
    seen(unlink, Fs),
    change(Fs, fun(T) ->
                          case node(Dir, T) of
                              #{kind := directory, entries := #{Name := Ino}} -> unlinked(Dir, Name, Ino, Kind, T);
                              #{kind := directory} -> {error, enoent};
                              #{} -> {error, enotdir};
                              gone -> {error, enoent}
                          end
                  end).

unlinked(_, _, Ino, {node, Other}, _) when Other =/= Ino ->
    {error, enoent};
unlinked(Dir, Name, Ino, Kind, T) ->
    case {Kind, node(Ino, T)} of
        {directory, #{kind := Other}} when Other =/= directory -> {error, enotdir};
        {file, #{kind := directory}} -> {error, eisdir};
        {_, #{kind := directory, entries := Entries}} when map_size(Entries) > 0 -> {error, enotempty};
        {_, #{links := Links} = Node} -> {ok, kept(Ino, Node#{links := Links - 1}, leave(Dir, Name, T))}
    end.

-doc "Moves a name, replacing what the new name named.".
rename(Dir, Name, NewDir, NewName, Fs) ->
    seen(rename, Fs),
    change(Fs, fun(T) ->
                          case {node(Dir, T), node(NewDir, T)} of
                              {_, #{kind := NewKind}} when NewKind =/= directory ->
                                  {error, enotdir};
                              {#{kind := directory, entries := #{Name := Ino}}, _} ->
                                  T1 = leave(Dir, Name, T),
                                  T2 = case node(NewDir, T1) of
                                           #{entries := #{NewName := Replaced}} ->
                                               #{links := Links} = Old = node(Replaced, T1),
                                               kept(Replaced, Old#{links := Links - 1}, leave(NewDir, NewName, T1));
                                           #{} ->
                                               T1
                                       end,
                                  {ok, enter(NewDir, NewName, Ino, T2)};
                              _ ->
                                  {error, enoent}
                          end
                  end).

%% A step whose reply is the callback's answer and which changes nothing.
read_only(Fs, Read) ->
    apply_step(Fs, fun(T) -> {Read(T), T} end).

%% A step answering {ok, T1}, {ok, Handle, T1} or {error, Posix}; the callback
%% answers ok, {ok, Handle} or the error, and the tree keeps T1.
change(Fs, Step) ->
    apply_step(Fs, fun(T) -> answer(Step(T), T) end).

%% A tree step's answer, split into the reply and the next tree; {ok, T1} is
%% the reply ok with the tree T1.
answer({ok, T1}, _) -> {ok, T1};
answer({ok, Handle, T1}, _) -> {{ok, Handle}, T1};
answer({ok, Ino, Qid, T1}, _) -> {{ok, Ino, Qid}, T1};
answer({ok, Ino, Qid, Handle, T1}, _) -> {{ok, Ino, Qid, Handle}, T1};
answer({error, _} = Error, T) -> {Error, T}.

enter(Dir, Name, Ino, T) ->
    #{entries := Entries} = Node = node(Dir, T),
    put_node(Dir, Node#{entries := Entries#{Name => Ino}}, T).

leave(Dir, Name, T) ->
    #{entries := Entries} = Node = node(Dir, T),
    put_node(Dir, Node#{entries := maps:remove(Name, Entries)}, T).

%% A node with no name and no open is gone.
kept(Ino, #{links := 0, opens := 0}, #{nodes := Nodes} = T) ->
    T#{nodes := maps:remove(Ino, Nodes)};
kept(Ino, Node, T) ->
    put_node(Ino, Node, T).

put_node(Ino, Node, #{nodes := Nodes} = T) ->
    T#{nodes := Nodes#{Ino => Node}}.

node(Ino, #{nodes := Nodes}) ->
    maps:get(Ino, Nodes, gone).

qid(Ino, T) ->
    #{kind := Kind} = node(Ino, T),
    {qid_type(Kind), 0, Ino}.

qid_type(directory) -> ?QTDIR;
qid_type(symlink) -> ?QTSYMLINK;
qid_type(file) -> ?QTFILE.

type_bits(directory) -> 8#040000;
type_bits(symlink) -> 8#120000;
type_bits(file) -> 8#100000.

dirent_type(Ino, T) ->
    case node(Ino, T) of
        #{kind := directory} -> ?DT_DIR;
        #{kind := symlink} -> ?DT_LNK;
        #{kind := file} -> ?DT_REG
    end.

seen(Callback, #{observer := Observer}) when is_pid(Observer) ->
    Observer ! {tree_call, Callback},
    ok;
seen(_, _) ->
    ok.
