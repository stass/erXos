%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_listing).
-moduledoc """
The canonical, sorted description of a file tree that every F2FS test
compares (docs/design-f2fs.md, "Testing on the host"), built the same way
from every reader: the reference model, erXos's mounts and Linux's, each
through a reader/0 of four functions. file_reader/1 is the reader over OTP's
file module, which reaches a Linux mount in the distribution guest and a
directory on the host.

A listing holds one entry per name, the root's included, sorted by path, a
path being the list of names from the root. An entry has its kind, its
permission bits (mode, the low 12 bits of i_mode), its link count, its link
class, its size, and by kind its symlink target, its device number
{Major, Minor} or the SHA-256 of its bytes. The link class of a name that is
not a directory is the sorted list of the paths of every name the listing
found sharing its inode, so it is the same from every reader whatever inode
numbers each uses. At depth 2 an entry also has the owner and the times,
which the model does not predict, so only two readers of one image are
compared at that depth; a key a reader does not state is left out.

The walk visits names in path order, so what it reports does not depend on
the order a reader lists a directory in. An entry a reader answers with an
error is {error, Reason} in place of its attributes, and nothing beneath it
is listed. The walk's own errors are three: a directory reached a second
time by its inode is directory_reached_twice, so a listing of a damaged tree
ends and the later path in path order is the one that carries the error; a
name a directory lists more than once is duplicate_name; and a name no path
can hold (empty, ".", "..", or holding "/" or NUL) is bad_name, so no reader
is ever asked about a path that would step outside its tree. A reader that
holds a file's bytes hashes them with sha256_of/1 as it folds them in
chunks, so a sparse or damaged file of any size takes no more memory than
one chunk. record_reader/1 is the reader over the Linux oracle guest's
record of a mounted tree, which states each file's digest.
""".

-export([of_tree/1, of_tree/2, sha256_of/1, file_reader/1, record_reader/1, diff/2]).
-export_type([listing/0, entry/0, reader/0, stat/0, device/0]).

-include_lib("kernel/include/file.hrl").

-define(TYPE_MASK, 8#170000).
-define(PERMISSION_MASK, 8#7777).
-define(CHUNK_BYTES, 65536).

-doc "A path: the names from the root, [] being the root.".
-type path() :: [binary()].
-type kind() :: regular | directory | symlink | character | block | fifo | socket.
-doc """
A device number as major and minor, which each reader decodes once from its
own encoding (docs/design-f2fs.md, "Testing on the host").
""".
-type device() :: {Major :: non_neg_integer(), Minor :: non_neg_integer()}.
-doc """
What a reader states of a name: its kind, permission bits, link count, inode
(any term that is equal for names of one inode and differs otherwise), size,
for a device its number, and the owner and the times where it knows them.
""".
-type stat() :: #{kind := kind(), mode := 0..8#7777, links := non_neg_integer(),
                  inode := term(), size := non_neg_integer(),
                  device => device(), uid => non_neg_integer(),
                  gid => non_neg_integer(), atime => integer(),
                  mtime => integer(), ctime => integer()}.
-type answer(Value) :: {ok, Value} | {error, term()}.
-doc """
A reader of one tree: a directory's names, without "." and "..", a name's
stat, a regular file's SHA-256 (sha256_of/1 hashes a reader's bytes) and a
symlink's target.
""".
-type reader() :: #{list := fun((path()) -> answer([binary()])),
                    stat := fun((path()) -> answer(stat())),
                    sha256 := fun((path()) -> answer(binary())),
                    read_link := fun((path()) -> answer(binary()))}.
-type entry() :: {path(), #{atom() => term()} | {error, term()}}.
-type listing() :: [entry()].

-doc "The listing of Reader's tree at depth 1.".
-spec of_tree(reader()) -> listing().
of_tree(Reader) ->
    of_tree(Reader, 1).

-doc "The listing of Reader's tree at Depth: 2 adds the owner and the times.".
-spec of_tree(reader(), 1 | 2) -> listing().
of_tree(Reader, Depth) when Depth =:= 1; Depth =:= 2 ->
    Found = walk(Reader, [{[], visit}], #{}, []),
    Classes = link_classes(Found),
    [{Path, describe(Reader, Path, Answer, Classes, Depth)} || {Path, Answer} <- Found].

-doc """
The entries of two listings that differ, in path order, each side's
attributes or absent: what a failed comparison reports. A path either
listing has twice is reported, never hidden. Link classes are compared only
over the paths both listings state without an error, so an entry one reader
answers with an error changes no other entry.
""".
-spec diff(listing(), listing()) -> [{path(), term(), term()}].
diff(Left, Right) ->
    Stated = maps:intersect(stated(Left), stated(Right)),
    merge(comparable(Left, Stated), comparable(Right, Stated)).

-doc """
The SHA-256 of the bytes Fold gives, for a reader's sha256: Fold folds a
function over a file's bytes in chunks of its choosing, in order.
""".
-spec sha256_of(fun((fun((binary(), Acc) -> Acc), Acc) -> answer(Acc))) -> answer(binary()).
sha256_of(Fold) ->
    case Fold(fun(Chunk, State) -> crypto:hash_update(State, Chunk) end, crypto:hash_init(sha256)) of
        {ok, State} -> {ok, crypto:hash_final(State)};
        {error, _} = Error -> Error
    end.

%%% The walk

%% Every name under the paths to visit, in path order, each with its stat or
%% error. A path to visit is {Path, visit}, or {Path, {error, Reason}} when
%% the walk refused it already; Seen holds the inodes of the directories
%% already listed. Children go in front of the rest in byte order, so the
%% walk is a depth-first visit in path order.
walk(_Reader, [], _Seen, Found) ->
    lists:reverse(Found);
walk(Reader, [{Path, {error, _} = Error} | Rest], Seen, Found) ->
    walk(Reader, Rest, Seen, [{Path, Error} | Found]);
walk(Reader, [{Path, visit} | Rest], Seen, Found) ->
    #{stat := Stat, list := List} = Reader,
    case Stat(Path) of
        {error, _} = Error ->
            walk(Reader, Rest, Seen, [{Path, Error} | Found]);
        {ok, #{kind := directory, inode := Inode}} when is_map_key(Inode, Seen) ->
            walk(Reader, Rest, Seen, [{Path, {error, directory_reached_twice}} | Found]);
        {ok, #{kind := directory, inode := Inode} = Stated} ->
            case List(Path) of
                {ok, Names} ->
                    walk(Reader, children(Path, Names) ++ Rest, Seen#{Inode => true},
                         [{Path, {ok, Stated}} | Found]);
                {error, _} = Error ->
                    walk(Reader, Rest, Seen, [{Path, Error} | Found])
            end;
        {ok, Stated} ->
            walk(Reader, Rest, Seen, [{Path, {ok, Stated}} | Found])
    end.

%% A directory's names, once each in byte order, to visit or refused.
children(Path, Names) ->
    Counts = lists:foldl(fun(Name, Tally) -> maps:update_with(Name, fun(N) -> N + 1 end, 1, Tally) end,
                         #{}, Names),
    [{Path ++ [Name], child(Name, Count)} || {Name, Count} <- lists:sort(maps:to_list(Counts))].

child(Name, _Count) when Name =:= <<>>; Name =:= <<".">>; Name =:= <<"..">> ->
    {error, bad_name};
child(Name, Count) ->
    case binary:match(Name, [<<"/">>, <<0>>]) of
        {_, _} -> {error, bad_name};
        nomatch when Count > 1 -> {error, duplicate_name};
        nomatch -> visit
    end.

%% Each inode of a name that is not a directory, with the paths, in order,
%% of every name found sharing it.
link_classes(Found) ->
    Reversed = lists:foldl(fun({Path, {ok, #{kind := Kind, inode := Inode}}}, Classes)
                                 when Kind =/= directory ->
                                   maps:update_with(Inode, fun(Paths) -> [Path | Paths] end,
                                                    [Path], Classes);
                              (_Entry, Classes) ->
                                   Classes
                           end, #{}, Found),
    maps:map(fun(_Inode, Paths) -> lists:reverse(Paths) end, Reversed).

describe(_Reader, _Path, {error, _} = Error, _Classes, _Depth) ->
    Error;
describe(Reader, Path, {ok, Stat}, Classes, Depth) ->
    #{kind := Kind, mode := Mode, links := Links, inode := Inode, size := Size} = Stat,
    Common = #{kind => Kind, mode => Mode, links => Links, size => Size},
    WithClass = case Kind of
                    directory -> Common;
                    _ -> Common#{link_class => maps:get(Inode, Classes)}
                end,
    case content(Reader, Path, Stat) of
        {error, _} = Error -> Error;
        Content -> maps:merge(maps:merge(WithClass, Content), owner_and_times(Stat, Depth))
    end.

%% By kind: a regular file's SHA-256, a symlink's target, a device's number.
content(#{sha256 := Sha256}, Path, #{kind := regular}) ->
    case Sha256(Path) of
        {ok, Hash} -> #{sha256 => Hash};
        {error, _} = Error -> Error
    end;
content(#{read_link := ReadLink}, Path, #{kind := symlink}) ->
    case ReadLink(Path) of
        {ok, Target} -> #{target => Target};
        {error, _} = Error -> Error
    end;
content(_Reader, _Path, #{kind := Kind, device := Device})
  when Kind =:= character; Kind =:= block ->
    #{device => Device};
content(_Reader, _Path, _Stat) ->
    #{}.

owner_and_times(_Stat, 1) ->
    #{};
owner_and_times(Stat, 2) ->
    maps:with([uid, gid, atime, mtime, ctime], Stat).

%%% The comparison

%% The paths a listing states without an error.
stated(Listing) ->
    #{Path => true || {Path, Attributes} <- Listing, is_map(Attributes)}.

%% A listing in path order with each link class cut to the paths in Stated.
comparable(Listing, Stated) ->
    lists:keysort(1, [{Path, cut_class(Attributes, Stated)} || {Path, Attributes} <- Listing]).

cut_class(#{link_class := Class} = Attributes, Stated) ->
    Attributes#{link_class := [Path || Path <- Class, is_map_key(Path, Stated)]};
cut_class(Attributes, _Stated) ->
    Attributes.

%% A merge of two listings in path order: equal entries drop out, an entry
%% one side lacks is absent there, and a path repeated on one side meets
%% absent on the other.
merge([], []) ->
    [];
merge([{Path, Same} | Left], [{Path, Same} | Right]) ->
    merge(Left, Right);
merge([{Path, L} | Left], [{Path, R} | Right]) ->
    [{Path, L, R} | merge(Left, Right)];
merge([{Path, L} | Left], Right) when Right =:= []; Path < element(1, hd(Right)) ->
    [{Path, L, absent} | merge(Left, Right)];
merge(Left, [{Path, R} | Right]) ->
    [{Path, absent, R} | merge(Left, Right)].

%%% The reader over OTP's file module

-doc """
The reader of the tree under the directory Root through OTP's file module,
names as their bytes. A symlink is stated, never followed. The kind comes
from st_mode's file-type bits, which file:read_link_info/2 answers in its
mode on a UNIX host. A device's number is decoded from the file_info's
minor_device, which holds the low 32 bits of the host's st_rdev, by the
host's own dev_t encoding; on a host whose encoding this module does not
know, a device is an error, never a guess.

A name OTP answers as a string is encoded back to its bytes in the file name
encoding. On macOS, a name may come back in another Unicode normalization
than it was made with, so trees compared across hosts use ASCII names.
""".
-spec file_reader(file:name_all()) -> reader().
file_reader(Root) ->
    Absolute = fun(Path) -> filename:join([Root | Path]) end,
    OsType = os:type(),
    #{list => fun(Path) -> names(file:list_dir_all(Absolute(Path))) end,
      stat => fun(Path) ->
                      file_stat(OsType, file:read_link_info(Absolute(Path), [{time, posix}]))
              end,
      sha256 => fun(Path) -> sha256_of(fun(Fun, Acc) -> fold_file(Absolute(Path), Fun, Acc) end) end,
      read_link => fun(Path) -> target(file:read_link_all(Absolute(Path))) end}.

names({ok, Names}) -> {ok, [bytes(Name) || Name <- Names]};
names({error, _} = Error) -> Error.

target({ok, Target}) -> {ok, bytes(Target)};
target({error, _} = Error) -> Error.

%% OTP answers a name as a string when it decodes in the file name
%% encoding, else as its bytes; a listing holds bytes.
bytes(Name) when is_binary(Name) -> Name;
bytes(Name) -> unicode:characters_to_binary(Name, unicode, file:native_name_encoding()).

fold_file(Name, Fun, Acc) ->
    case file:open(Name, [read, raw, binary]) of
        {ok, File} ->
            try fold_chunks(File, Fun, Acc) after file:close(File) end;
        {error, _} = Error ->
            Error
    end.

fold_chunks(File, Fun, Acc) ->
    case file:read(File, ?CHUNK_BYTES) of
        {ok, Chunk} -> fold_chunks(File, Fun, Fun(Chunk, Acc));
        eof -> {ok, Acc};
        {error, _} = Error -> Error
    end.

file_stat(OsType, {ok, #file_info{mode = Mode} = Info}) ->
    case kind(Mode band ?TYPE_MASK) of
        {ok, Kind} -> stat_of(OsType, Kind, Info);
        error -> {error, {file_type, Mode}}
    end;
file_stat(_OsType, {error, _} = Error) ->
    Error.

stat_of(OsType, Kind, #file_info{mode = Mode, links = Links, inode = Inode, size = Size,
                                 major_device = FileSystem, minor_device = Rdev,
                                 uid = Uid, gid = Gid, atime = Atime, mtime = Mtime,
                                 ctime = Ctime}) ->
    Stat = #{kind => Kind, mode => Mode band ?PERMISSION_MASK, links => Links,
             inode => {FileSystem, Inode}, size => Size, uid => Uid, gid => Gid,
             atime => Atime, mtime => Mtime, ctime => Ctime},
    if
        Kind =:= character; Kind =:= block ->
            case device(OsType, Rdev) of
                {ok, Device} -> {ok, Stat#{device => Device}};
                {error, _} = Error -> Error
            end;
        true ->
            {ok, Stat}
    end.

%% POSIX's S_IFMT values; an unknown one is an error, never a guess.
kind(8#100000) -> {ok, regular};
kind(8#040000) -> {ok, directory};
kind(8#120000) -> {ok, symlink};
kind(8#020000) -> {ok, character};
kind(8#060000) -> {ok, block};
kind(8#010000) -> {ok, fifo};
kind(8#140000) -> {ok, socket};
kind(_Type) -> error.

%% The host's major() and minor() over the low 32 bits of st_rdev: macOS's
%% from its SDK's sys/types.h, Linux's from musl's sys/sysmacros.h (in the
%% tree at musl/include/sys/sysmacros.h), FreeBSD's from sys/sys/types.h
%% at release/14.3.0, l.331-340.
device({unix, darwin}, Rdev) ->
    {ok, {(Rdev bsr 24) band 16#ff, Rdev band 16#ffffff}};
device({unix, linux}, Rdev) ->
    {ok, {(Rdev bsr 8) band 16#fff, ((Rdev bsr 12) band 16#ffffff00) bor (Rdev band 16#ff)}};
device({unix, freebsd}, Rdev) ->
    {ok, {(Rdev bsr 8) band 16#ff, ((Rdev bsr 24) band 16#ff00) bor (Rdev band 16#ffff00ff)}};
device(OsType, _Rdev) ->
    {error, {device_encoding, OsType}}.

%%% The reader over the Linux oracle guest's record

-doc """
The reader of the tree the Linux oracle guest's record describes
(test/f2fs/oracle_guest.sh's `record`), or the rule the record breaks. The
record is untrusted bytes: per name seven NUL-terminated fields, its path as
find prints it ("." for the root, else "./" and the names joined by "/"),
find's type letter, the permission bits in octal, the link count, the inode,
the size and the content: "=" and a regular file's SHA-256 in hex or a
symlink's target, "!" where Linux would not let the guest read it, which the
reader answers as {error, unreadable}, or nothing for any other kind. A
device's number is not recorded, since erXos's core reader states none.
Refused: a record that is not whole entries (partial_entry), names a path
twice (duplicate_path) or a path of no known form (bad_path), names a path
whose parent it does not name as a directory (orphan), holds a field of no
known form (bad_type, bad_number, bad_content) or has no root (no_root).
""".
-spec record_reader(binary()) -> {ok, reader()} | {error, {record, atom()}}.
record_reader(Record) ->
    try
        Entries = record_entries(binary:split(Record, <<0>>, [global]), #{}),
        is_map_key([], Entries) orelse throw(no_root),
        Children = maps:fold(fun(Path, _Entry, Found) -> record_child(Path, Entries, Found) end,
                             #{}, Entries),
        Lookup = fun(Path, Answer) ->
                         case Entries of
                             #{Path := Entry} -> Answer(Entry);
                             #{} -> {error, enoent}
                         end
                 end,
        Content = fun(Kind) ->
                          fun(Path) ->
                                  Lookup(Path, fun({#{kind := Of}, Value}) when Of =:= Kind -> Value;
                                                  (_Entry) -> {error, einval}
                                               end)
                          end
                  end,
        {ok, #{list => fun(Path) -> Lookup(Path, fun(_) -> {ok, maps:get(Path, Children, [])} end) end,
               stat => fun(Path) -> Lookup(Path, fun({Stat, _Value}) -> {ok, Stat} end) end,
               sha256 => Content(regular),
               read_link => Content(symlink)}}
    catch
        throw:Rule -> {error, {record, Rule}}
    end.

%% Each path to its stat and its content's answer; the record's last field
%% ends with its NUL, so the split leaves one empty binary after it.
record_entries([<<>>], Entries) ->
    Entries;
record_entries([Path, Type, Mode, Links, Inode, Size, Content | Rest], Entries) ->
    Names = record_path(Path),
    is_map_key(Names, Entries) andalso throw(duplicate_path),
    Kind = record_kind(Type),
    Stat = #{kind => Kind, mode => record_number(Mode, 8) band ?PERMISSION_MASK,
             links => record_number(Links, 10), inode => record_number(Inode, 10),
             size => record_number(Size, 10)},
    record_entries(Rest, Entries#{Names => {Stat, record_content(Kind, Content)}});
record_entries(_Fields, _Entries) ->
    throw(partial_entry).

record_path(<<".">>) ->
    [];
record_path(<<"./", Path/binary>>) ->
    Names = binary:split(Path, <<"/">>, [global]),
    lists:any(fun(Name) -> lists:member(Name, [<<>>, <<".">>, <<"..">>]) end, Names)
        andalso throw(bad_path),
    Names;
record_path(_Path) ->
    throw(bad_path).

%% find's %y letters.
record_kind(<<"f">>) -> regular;
record_kind(<<"d">>) -> directory;
record_kind(<<"l">>) -> symlink;
record_kind(<<"c">>) -> character;
record_kind(<<"b">>) -> block;
record_kind(<<"p">>) -> fifo;
record_kind(<<"s">>) -> socket;
record_kind(_Type) -> throw(bad_type).

%% Digits of Base only, no sign, at most 20 of them.
record_number(Field, Base) when byte_size(Field) >= 1, byte_size(Field) =< 20 ->
    case lists:all(fun(Digit) -> Digit >= $0 andalso Digit < $0 + Base end, binary_to_list(Field)) of
        true -> binary_to_integer(Field, Base);
        false -> throw(bad_number)
    end;
record_number(_Field, _Base) ->
    throw(bad_number).

record_content(Kind, <<"!">>) when Kind =:= regular; Kind =:= symlink ->
    {error, unreadable};
record_content(regular, <<"=", Hex:64/binary>>) ->
    try {ok, binary:decode_hex(Hex)} catch error:badarg -> throw(bad_content) end;
record_content(symlink, <<"=", Target/binary>>) ->
    {ok, Target};
record_content(Kind, <<>>) when Kind =/= regular, Kind =/= symlink ->
    none;
record_content(_Kind, _Content) ->
    throw(bad_content).

%% Path among its parent's children; the parent must be a directory the
%% record names, so the walk from the root reaches every name it holds.
record_child([], _Entries, Found) ->
    Found;
record_child(Path, Entries, Found) ->
    {Parent, [Name]} = lists:split(length(Path) - 1, Path),
    case Entries of
        #{Parent := {#{kind := directory}, _}} ->
            maps:update_with(Parent, fun(Names) -> [Name | Names] end, [Name], Found);
        #{} ->
            throw(orphan)
    end.
