%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_procfs_core).
-moduledoc """
The pure decisions of `/proc` (docs/design-live.md, "The /proc tree"):
what a name names, what a directory lists and what a file holds, each a
function of the path and of the inspector's answers, which erx_procfs
asks for and hands in. Nothing here asks the inspector or keeps state, so
every decision is tested with made-up answers.

* **Nodes.** A directory is `{dir, Path}`, one per inspector path; its
  record is the file `{status, Path}`, and a listing the inspector could
  not give whole has a marker file, `{partial, Path}` (`.partial`) or
  `{unknown, Path}` (`.unknown`).
* **Names.** A path's segment becomes an entry name through name/1, the
  writer of the encoding erx_schema:resolve_text/1 reads: a literal as
  itself, an integer in decimal, a pid as `D.N.S`, a text with every byte
  outside `A-Z a-z 0-9 _+,:=@-` as `%XX`. child/2 reads a name by handing
  the parent's text and the name to resolve_text/1, so `/proc` has one
  reader of path text, and a name is accepted only in the spelling name/1
  writes. Names that start with `.` are the tree's markers, since no
  encoded name does.
* **Content.** status/2 writes one line per attribute the projection
  `proc` shows: its name, its value as erx_render:value/1 prints it (an
  `ok` value bare, any other status as `[partial]`, `[unknown]`,
  `[unsupported]`, `[timeout N]` or `[error]`) and its reporter, a stopgap
  one by its label, separated by tabs, each field through
  erx_text:escape_field/1. A record over 64 KiB is cut at a line's end
  and ends with a `[partial]` line.
""".

-export([root/0, name/1, child/2, walk/3, listing/3, lists_entries/1, status/2, marker/2, cut/1]).
-export_type([node_/0, entry/0]).

-type path() :: [erx_schema:segment()].
-type node_() :: {dir, path()} | {status, path()} | {partial, path()} | {unknown, path()}.
-type entry() :: {binary(), node_()}.

%% The longest entry name read: a text segment of 255 bytes, each encoded
%% as three.
-define(MAX_NAME, 765).
%% The most bytes of one status file (design-live.md, Snapshots).
-define(MAX_RECORD, 65536).
-define(CUT_LINE, <<"[partial]\n">>).

-doc "The root directory, the machine's path `[]`.".
-spec root() -> node_().
root() -> {dir, []}.

-doc """
The entry name of a path segment: the spelling erx_schema:resolve_text/1
reads back as that segment.
""".
-spec name(erx_schema:segment()) -> binary().
name(Segment) when is_atom(Segment) ->
    atom_to_binary(Segment);
name(Segment) when is_integer(Segment) ->
    integer_to_binary(Segment);
name(Segment) when is_pid(Segment) ->
    %% "<D.N.S>" without its brackets, so a shell needs no quoting.
    Text = list_to_binary(pid_to_list(Segment)),
    binary:part(Text, 1, byte_size(Text) - 2);
name(Segment) when is_binary(Segment) ->
    << <<(encoded(Byte))/binary>> || <<Byte>> <= Segment >>.

encoded(Byte) when Byte >= $A, Byte =< $Z; Byte >= $a, Byte =< $z; Byte >= $0, Byte =< $9 ->
    <<Byte>>;
encoded(Byte) ->
    case lists:member(Byte, "_+,:=@-") of
        true -> <<Byte>>;
        false -> list_to_binary(io_lib:format("%~2.16.0B", [Byte]))
    end.

-doc """
The path one level below Path that the entry name Name names, read by
erx_schema:resolve_text/1 from Path's text and Name; `error` for a name
that is empty, too long, holds `/` or is not a canonical spelling of a
declared path's segment. The name is untrusted: it is bounded before it
is read, and no atom is made.
""".
-spec child(path(), binary()) -> {ok, path()} | error.
child(Path, Name) when is_binary(Name), byte_size(Name) > 0, byte_size(Name) =< ?MAX_NAME ->
    case binary:match(Name, <<"/">>) of
        nomatch -> resolved(length(Path) + 1, erx_schema:resolve_text(text(Path, Name)));
        _ -> error
    end;
child(_Path, _Name) ->
    error.

text(Path, Name) ->
    iolist_to_binary(lists:join($/, [name(Segment) || Segment <- Path] ++ [Name])).

resolved(Depth, {ok, Child, _Declaration}) when length(Child) =:= Depth -> {ok, Child};
resolved(_Depth, _Answer) -> error.

-doc """
What the name Name in the directory Dir names. Lookup answers the
inspector for a path: `{exists, Path}` whether Path names something
(`{error, scope}` when it does not), `{listing, Path}` the record of the
listing at Path. A directory below exists unless the inspector answers
it `{error, scope}`, as it answers a path that names nothing. `status` is
always there, and a marker only where the listing is partial or unknown.
""".
-spec walk(path(), binary(), fun((term()) -> erx_inspector:answer())) ->
          {ok, node_()} | {error, enoent}.
walk(Dir, <<"status">>, _Lookup) ->
    {ok, {status, Dir}};
walk(Dir, <<".partial">>, Lookup) ->
    marker_node(partial, Dir, Lookup);
walk(Dir, <<".unknown">>, Lookup) ->
    marker_node(unknown, Dir, Lookup);
walk(Dir, Name, Lookup) ->
    case child(Dir, Name) of
        {ok, Child} -> exists(Child, Lookup);
        error -> {error, enoent}
    end.

exists(Path, Lookup) ->
    case Lookup({exists, Path}) of
        {error, scope} -> {error, enoent};
        _Answer -> {ok, {dir, Path}}
    end.

marker_node(Marker, Dir, Lookup) ->
    case lists_entries(Dir) of
        true -> marker_present(Marker, Dir, children(Lookup({listing, Dir})));
        false -> {error, enoent}
    end.

marker_present(Marker, Dir, {Marker, _}) -> {ok, {Marker, Dir}};
marker_present(_Marker, _Dir, _Children) -> {error, enoent}.

-doc """
The entries of the directory at Path, in order: `status`, then the paths
below it. A path whose children the schema names lists those that Scope
reaches (erx_inspector:declared_reachable/3); a listing lists the ids of the
inspector's answer for it, ListingAnswer, then `.partial` when the
inspector gave only part of them, or holds only `.unknown` when it gave
none.
""".
-spec listing(path(), erx_inspector:answer() | none, erx_inspector:scope()) -> [entry()].
listing(Path, ListingAnswer, Scope) ->
    [{<<"status">>, {status, Path}} | below(Path, ListingAnswer, Scope)].

below(Path, ListingAnswer, Scope) ->
    case lists_entries(Path) of
        true ->
            listed(Path, children(ListingAnswer));
        false ->
            {literals, Literals} = declaration_children(Path),
            [{name(Literal), {dir, Path ++ [Literal]}}
             || Literal <- Literals, reachable(Path ++ [Literal], Scope)]
    end.

listed(Path, {ok, Ids}) -> ids(Path, Ids);
listed(Path, {partial, Ids}) -> ids(Path, Ids) ++ [{<<".partial">>, {partial, Path}}];
listed(Path, {unknown, _}) -> [{<<".unknown">>, {unknown, Path}}].

ids(Path, Ids) -> [{name(Id), {dir, Path ++ [Id]}} || Id <- Ids].

reachable(Path, Scope) ->
    erx_inspector:declared_reachable(Path, erx_schema:resolve(Path), Scope) =/= error.

-doc """
Whether the directory at Path lists the inspector's entries: a path whose
children the schema leaves to the inspector, or one it declares with
entries, such as a domain's pids; every other directory lists the
literals the schema names below it.
""".
-spec lists_entries(path()) -> boolean().
lists_entries(Path) ->
    case erx_schema:resolve(Path) of
        {ok, #{children := {variable, _Type}}} -> true;
        {ok, #{entries := {_Descriptor, _Bound}}} -> true;
        _ -> false
    end.

declaration_children(Path) ->
    case erx_schema:resolve(Path) of
        {ok, #{children := Children}} -> Children;
        {error, unknown_path} -> {literals, []}
    end.

%% A listing's entries as the inspector answered them: all, part, or none
%% with the status that says why, which `.unknown` shows.
children({ok, #{children := Ids}}) when is_list(Ids) -> {ok, Ids};
children({ok, #{children := {partial, Ids}}}) -> {partial, Ids};
children({ok, #{children := unknown}}) -> {unknown, <<"[unknown]">>};
children({error, unsupported}) -> {unknown, <<"[unsupported]">>};
children(_Answer) -> {unknown, <<"[unknown]">>}.

-doc """
The text of a `status` file: the record's attributes that the `proc`
projection shows in Build, one per line, or one line with the status of
an answer that holds no record, cut to 64 KiB.
""".
-spec status(erx_inspector:answer(), release | development) -> binary().
status({ok, #{kind := Kind, attrs := Attrs}}, Build) ->
    {ok, Fields} = erx_schema:fields(Kind, proc, Build),
    cut([line(Key, Attr) || Key <- Fields, {ok, Attr} <- [maps:find(Key, Attrs)]]);
status({error, unsupported}, _Build) ->
    <<"[unsupported]\n">>;
status({error, _Reason}, _Build) ->
    <<"[error]\n">>.

line(Key, {Reporter, _Value} = Attr) ->
    {ok, Label} = erx_schema:reporter_label(Reporter),
    Fields = [atom_to_binary(Key), erx_render:value(Attr), Label],
    [lists:join($\t, [erx_text:escape_field(Field) || Field <- Fields]), $\n].

-doc """
Lines as one file of at most 64 KiB: whole lines while they fit, then a
`[partial]` line in place of the rest.
""".
-spec cut([iodata()]) -> binary().
cut(Lines) ->
    cut(Lines, 0, []).

cut([], _Size, Kept) ->
    iolist_to_binary(lists:reverse(Kept));
cut([Line | Rest], Size, Kept) ->
    Bytes = iolist_to_binary(Line),
    Room = case Rest of
               [] -> ?MAX_RECORD;
               _ -> ?MAX_RECORD - byte_size(?CUT_LINE)
           end,
    case Size + byte_size(Bytes) =< Room of
        true -> cut(Rest, Size + byte_size(Bytes), [Bytes | Kept]);
        false -> iolist_to_binary(lists:reverse([?CUT_LINE | Kept]))
    end.

-doc """
The text of a marker file, from the inspector's answer for its listing:
`.partial` says how many entries were left out, which the inspector does
not count, so `[unknown]`; `.unknown` gives the status that kept the
listing back.
""".
-spec marker(partial | unknown, erx_inspector:answer()) -> binary().
marker(partial, _ListingAnswer) ->
    <<"left_out\t[unknown]\n">>;
marker(unknown, ListingAnswer) ->
    case children(ListingAnswer) of
        {unknown, Status} -> <<Status/binary, "\n">>;
        _ -> <<"[unknown]\n">>
    end.
