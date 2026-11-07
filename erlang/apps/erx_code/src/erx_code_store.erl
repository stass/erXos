%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_code_store).

-moduledoc """
The code store's pure core (docs/design-live.md, "The code store"): the blobs the code
service holds in memory, each named by the SHA-256 of its bytes, the uploads that bring
them in pieces, and the history of the hashes loaded for each module. It reads no clock
and loads nothing: erx_code, its effect layer, passes the time in and carries out the
plan `plan_load/2` returns.

Everything a request carries is untrusted. `read_request/1` is the one reader of a
request term, so every operation below is handed values of the shapes it documents:

* `{missing, Hashes}` names at most 1,024 hashes; the answer is those the store lacks.
* `{put, Hash, Size, Offset, Piece}` sends bytes `Offset .. Offset + byte_size(Piece) - 1`
  of a blob of `Size` bytes. The pieces of one blob arrive in order from offset 0, each
  65,536 bytes but the last, which holds the rest; a piece at offset 0 starts the blob
  again. An upload therefore keeps at most `Size / 65,536 + 1` pieces. The blob is
  stored once its last byte arrives and its bytes hash to `Hash`; otherwise the upload is
  dropped and the answer is `hash_mismatch`, so a blob one bit off its hash is never
  stored.
* `{load, Manifest}` names 1 to 1,024 modules by `{Name, Hash}`, each name once.
  `plan_load/2` hashes each named blob again before it plans the load, so a store whose
  bytes changed can fail a load but never change what is loaded.
* `{history, DomainId, Module}` asks for the hashes loaded for a module.

A module name is 1 to 255 bytes of ASCII letters, digits, `_`, `.` and `@`, and stays a
binary here: only the effect layer, which loads the module, makes it an atom.

The store holds at most `limit` bytes: every stored blob and the full size of every upload
in progress count against it, so an upload can never outgrow the store. At most four
uploads are in progress; starting a fifth drops the oldest, whose sender learns it at its
next piece. When an upload does not fit, blobs are freed to make room: first those only
older history entries name, the one loaded longest ago first, then those no history
names, which may be a batch sent but not yet loaded. A module's current blob is never
freed, and a history entry outlives its blob, so a rollback to it needs the blob sent
again (docs/design-live.md, "History and rollback").
A piece refused before its upload starts changes nothing: the store drops an upload and
frees blobs only for an upload that starts, which a one-piece blob that then fails its hash
has done.
""".

-export([new/1, read_request/1, read_manifest/1, missing/2, put_piece/5, plan_load/2, commit/3, history/2,
         summary/1]).
-export_type([store/0, hash/0, name/0, manifest/0, request/0, plan/0, history/0, put_reply/0,
              put_error/0, manifest_error/0, time/0]).

%% The most bytes in one piece (docs/design-live.md, "Code from the host").
-define(PIECE_MAX, 65536).
%% The longest module name: an atom holds at most 255 characters.
-define(NAME_MAX, 255).
%% The most modules one manifest names, and the most hashes one missing request asks after.
-define(MANIFEST_MAX, 1024).
%% The hashes kept per module (docs/design-live.md, "History and rollback").
-define(HISTORY_MAX, 16).
%% The uploads in progress at once.
-define(UPLOADS_MAX, 4).

-doc "The SHA-256 of a blob's bytes, which names the blob.".
-type hash() :: <<_:256>>.
-doc "A module's name as it travels: a binary until the domain that loads it makes it an atom.".
-type name() :: binary().
-doc "Modules by name, each named once, in the order the request gave them.".
-type manifest() :: [{name(), hash()}, ...].
-doc "A time the effect layer supplies, in milliseconds of erlang:system_time/1.".
-type time() :: integer().
-doc "The hashes loaded for one module, newest first, at most 16.".
-type history() :: [{hash(), time()}].
-doc "What a load does: each module's name, hash and verified bytes.".
-type plan() :: [{name(), hash(), binary()}, ...].
-doc "A request, as `read_request/1` admits it.".
-type request() :: {missing, [hash()]}
                 | {put, hash(), pos_integer(), non_neg_integer(), binary()}
                 | {load, manifest()}
                 | {history, integer(), name()}.
-doc "A successful piece: more of the blob is expected from `Offset`, or the blob is stored.".
-type put_reply() :: {next, Offset :: pos_integer()} | stored.
-doc """
Why a piece was refused. `{expected, Offset}` names the offset the store waits for, 0 when
it holds no upload of that hash; the upload, if any, is kept. `size_mismatch` means the
piece's size differs from the size its upload began with. `bad_piece` is a piece other
than 65,536 bytes that is not the blob's last, or one that runs past the blob's end.
`too_large` is a blob larger than the whole store and `store_full` one that does not fit
beside the blobs the store must keep; each leaves the store as it was. `hash_mismatch` is
a complete blob whose bytes do not hash to its name; its upload is dropped.
""".
-type put_error() :: {expected, non_neg_integer()} | size_mismatch | bad_piece | too_large
                   | store_full | hash_mismatch.
-doc "Why a manifest was refused; an index counts entries from 1.".
-type manifest_error() :: not_a_list | empty | too_many | {bad_entry, pos_integer()}
                        | {duplicate_name, pos_integer()}.

-record(upload, {hash :: hash(), size :: pos_integer(), received = 0 :: non_neg_integer(),
                 pieces = [] :: [binary()]}).

-doc """
A store: its byte limit, the bytes it holds or has promised to uploads, its blobs, its
uploads oldest first, and each module's history.
""".
-opaque store() :: #{limit := pos_integer(),
                     used := non_neg_integer(),
                     blobs := #{hash() => binary()},
                     uploads := [#upload{}],
                     history := #{name() => history()}}.

-doc "An empty store that holds at most `Limit` bytes.".
-spec new(Limit :: pos_integer()) -> store().
new(Limit) when is_integer(Limit), Limit > 0 ->
    #{limit => Limit, used => 0, blobs => #{}, uploads => [], history => #{}}.

-doc """
The request a term from outside the code service names, or `{error, bad_request}` for a
term of any other shape, and `{error, {bad_manifest, Why}}` for a load whose manifest
`read_manifest/1` refuses. It creates no atom and walks no list past its bound.
""".
-spec read_request(term()) ->
          {ok, request()} | {error, bad_request | {bad_manifest, manifest_error()}}.
read_request({missing, Hashes}) ->
    case bounded_list(Hashes, ?MANIFEST_MAX) of
        {ok, List} ->
            case lists:all(fun is_hash/1, List) of
                true -> {ok, {missing, List}};
                false -> {error, bad_request}
            end;
        {error, _} ->
            {error, bad_request}
    end;
read_request({put, Hash, Size, Offset, Piece} = Request)
  when is_integer(Size), Size > 0, is_integer(Offset), Offset >= 0, is_binary(Piece),
       byte_size(Piece) > 0, byte_size(Piece) =< ?PIECE_MAX ->
    case is_hash(Hash) of
        true -> {ok, Request};
        false -> {error, bad_request}
    end;
read_request({load, Manifest}) ->
    case read_manifest(Manifest) of
        {ok, Modules} -> {ok, {load, Modules}};
        {error, Why} -> {error, {bad_manifest, Why}}
    end;
read_request({history, DomainId, Module}) when is_integer(DomainId) ->
    case is_name(Module) of
        true -> {ok, {history, DomainId, Module}};
        false -> {error, bad_request}
    end;
read_request(_Term) ->
    {error, bad_request}.

-doc """
A manifest from outside the code service: a proper list of 1 to 1,024 `{Name, Hash}`
pairs, each name a module name and named once, each hash 32 bytes.
""".
-spec read_manifest(term()) -> {ok, manifest()} | {error, manifest_error()}.
read_manifest(Term) ->
    case bounded_list(Term, ?MANIFEST_MAX) of
        {ok, []} -> {error, empty};
        {ok, Entries} -> read_entries(Entries, 1, #{}, []);
        {error, Why} -> {error, Why}
    end.

read_entries([], _Index, _Seen, Modules) ->
    {ok, lists:reverse(Modules)};
read_entries([{Name, Hash} | Rest], Index, Seen, Modules) ->
    case is_name(Name) andalso is_hash(Hash) of
        false -> {error, {bad_entry, Index}};
        true when is_map_key(Name, Seen) -> {error, {duplicate_name, Index}};
        true -> read_entries(Rest, Index + 1, Seen#{Name => true}, [{Name, Hash} | Modules])
    end;
read_entries([_ | _], Index, _Seen, _Modules) ->
    {error, {bad_entry, Index}}.

%% A proper list of at most Max elements, walked no further than Max + 1 cells.
bounded_list(Term, Max) ->
    bounded_list(Term, Max, []).

bounded_list([], _Left, Elements) -> {ok, lists:reverse(Elements)};
bounded_list([_ | _], 0, _Elements) -> {error, too_many};
bounded_list([Element | Rest], Left, Elements) -> bounded_list(Rest, Left - 1, [Element | Elements]);
bounded_list(_Tail, _Left, _Elements) -> {error, not_a_list}.

is_hash(Hash) -> is_binary(Hash) andalso byte_size(Hash) =:= 32.

is_name(Name) when is_binary(Name), byte_size(Name) > 0, byte_size(Name) =< ?NAME_MAX ->
    lists:all(fun is_name_byte/1, binary_to_list(Name));
is_name(_Name) ->
    false.

is_name_byte(Byte) ->
    (Byte >= $a andalso Byte =< $z) orelse (Byte >= $A andalso Byte =< $Z)
        orelse (Byte >= $0 andalso Byte =< $9) orelse Byte =:= $_ orelse Byte =:= $.
        orelse Byte =:= $@.

-doc "The hashes of `Hashes` the store holds no blob for, each once, in their first order.".
-spec missing(store(), [hash()]) -> [hash()].
missing(#{blobs := Blobs}, Hashes) ->
    {Missing, _Seen} =
        lists:foldl(fun(Hash, {Acc, Seen}) when is_map_key(Hash, Blobs); is_map_key(Hash, Seen) ->
                            {Acc, Seen};
                       (Hash, {Acc, Seen}) ->
                            {[Hash | Acc], Seen#{Hash => true}}
                    end, {[], #{}}, Hashes),
    lists:reverse(Missing).

-doc """
The store after one piece of the blob named `Hash`, of `Size` bytes, at `Offset`. A blob the
store already holds answers `stored` at once, whatever the piece.
""".
-spec put_piece(store(), hash(), pos_integer(), non_neg_integer(), binary()) ->
          {ok, put_reply(), store()} | {error, put_error(), store()}.
put_piece(#{blobs := Blobs} = Store, Hash, _Size, _Offset, _Piece) when is_map_key(Hash, Blobs) ->
    {ok, stored, Store};
put_piece(Store, _Hash, Size, Offset, Piece)
  when Piece =:= <<>>; byte_size(Piece) =/= min(?PIECE_MAX, Size - Offset) ->
    {error, bad_piece, Store};
put_piece(Store, Hash, Size, 0, Piece) ->
    case start_upload(Store, Hash, Size) of
        {ok, Upload, Started} -> append(Started, Upload, Piece);
        {error, Why} -> {error, Why, Store}
    end;
put_piece(#{uploads := Uploads} = Store, Hash, Size, Offset, Piece) ->
    case lists:keyfind(Hash, #upload.hash, Uploads) of
        false -> {error, {expected, 0}, Store};
        #upload{size = Started} when Started =/= Size -> {error, size_mismatch, Store};
        #upload{received = Received} when Received =/= Offset -> {error, {expected, Received}, Store};
        #upload{} = Upload -> append(Store, Upload, Piece)
    end.

%% The store with a new upload of Size bytes in place of any upload of Hash, and with room
%% made for it: the oldest upload dropped when four are in progress, and blobs freed when
%% Size does not fit. Nothing of that is kept unless the upload starts.
start_upload(#{limit := Limit}, _Hash, Size) when Size > Limit ->
    {error, too_large};
start_upload(Store, Hash, Size) ->
    Room = free_bytes(drop_oldest_upload_if_full(drop_upload(Store, Hash)), Size),
    #{limit := Limit, used := Used, uploads := Uploads} = Room,
    case Used + Size =< Limit of
        true ->
            Upload = #upload{hash = Hash, size = Size},
            {ok, Upload, Room#{used := Used + Size, uploads := Uploads ++ [Upload]}};
        false ->
            {error, store_full}
    end.

drop_oldest_upload_if_full(#{uploads := [#upload{hash = Oldest} | _] = Uploads} = Store)
  when length(Uploads) >= ?UPLOADS_MAX ->
    drop_upload(Store, Oldest);
drop_oldest_upload_if_full(Store) ->
    Store.

%% The store without its upload of Hash, if it has one, and that upload's promised bytes.
drop_upload(#{used := Used, uploads := Uploads} = Store, Hash) ->
    case lists:keytake(Hash, #upload.hash, Uploads) of
        {value, #upload{size = Size}, Rest} -> Store#{used := Used - Size, uploads := Rest};
        false -> Store
    end.

%% The piece is in place, so the blob's end is never passed: bad_piece refuses a piece
%% that would run past it.
append(Store, #upload{hash = Hash, size = Size, received = Received, pieces = Pieces} = Upload, Piece) ->
    case Received + byte_size(Piece) of
        Size -> finish(Store, Hash, iolist_to_binary(lists:reverse([Piece | Pieces])));
        Next -> {ok, {next, Next}, replace_upload(Store, Upload#upload{received = Next,
                                                                       pieces = [Piece | Pieces]})}
    end.

replace_upload(#{uploads := Uploads} = Store, #upload{hash = Hash} = Upload) ->
    Store#{uploads := lists:keyreplace(Hash, #upload.hash, Uploads, Upload)}.

%% The upload's bytes are complete. If they hash to its name they become the blob, whose
%% bytes the upload already counted in `used`; otherwise the upload is dropped.
finish(#{uploads := Uploads, blobs := Blobs} = Store, Hash, Bytes) ->
    case erx_bytes:sha256(Bytes) =:= Hash of
        true ->
            {ok, stored, Store#{uploads := lists:keydelete(Hash, #upload.hash, Uploads),
                                blobs := Blobs#{Hash => Bytes}}};
        false ->
            {error, hash_mismatch, drop_upload(Store, Hash)}
    end.

%% The store after freeing blobs, in the order freeable/1 gives, until Size more bytes fit
%% or nothing more may be freed.
free_bytes(Store, Size) ->
    free_bytes(Store, Size, freeable(Store)).

free_bytes(#{limit := Limit, used := Used} = Store, Size, _Freeable) when Used + Size =< Limit ->
    Store;
free_bytes(Store, _Size, []) ->
    Store;
free_bytes(#{used := Used, blobs := Blobs} = Store, Size, [Hash | Rest]) ->
    Freed = Store#{used := Used - byte_size(map_get(Hash, Blobs)), blobs := maps:remove(Hash, Blobs)},
    free_bytes(Freed, Size, Rest).

%% The blobs that may be freed, first to free first: every blob but a module's current
%% one, those older history entries name by the time of their newest load, oldest first,
%% then those no history names.
freeable(#{blobs := Blobs, history := History}) ->
    Current = maps:from_keys([Hash || [{Hash, _Time} | _] <- maps:values(History)], true),
    Loaded = lists:foldl(fun({Hash, Time}, Acc) -> Acc#{Hash => max(Time, maps:get(Hash, Acc, Time))} end,
                         #{}, lists:append(maps:values(History))),
    Ranked = [{freeing_rank(Hash, Loaded), Hash} || Hash <- maps:keys(Blobs), not is_map_key(Hash, Current)],
    [Hash || {_Rank, Hash} <- lists:sort(Ranked)].

freeing_rank(Hash, Loaded) ->
    case Loaded of
        #{Hash := Time} -> {0, Time};
        #{} -> {1, 0}
    end.

-doc """
The load of `Manifest`: each module with the bytes of its blob, hashed again here. Fails
with `{missing, Hashes}`, naming each hash the store lacks once, or with
`{hash_mismatch, Name}` for the first module whose stored bytes no longer hash to its name.
""".
-spec plan_load(store(), manifest()) ->
          {ok, plan()} | {error, {missing, [hash(), ...]} | {hash_mismatch, name()}}.
plan_load(#{blobs := Blobs} = Store, Manifest) ->
    case missing(Store, [Hash || {_Name, Hash} <- Manifest]) of
        [] -> verify([{Name, Hash, map_get(Hash, Blobs)} || {Name, Hash} <- Manifest]);
        Missing -> {error, {missing, Missing}}
    end.

verify(Plan) ->
    case [Name || {Name, Hash, Bytes} <- Plan, erx_bytes:sha256(Bytes) =/= Hash] of
        [] -> {ok, Plan};
        [Name | _] -> {error, {hash_mismatch, Name}}
    end.

-doc """
The store after `Plan` loaded at `Now`: each module's history gains the plan's hash at its
head and keeps its 16 newest entries.
""".
-spec commit(store(), plan(), time()) -> store().
commit(#{history := History} = Store, Plan, Now) ->
    Store#{history := lists:foldl(fun({Name, Hash, _Bytes}, Acc) ->
                                          Entries = maps:get(Name, Acc, []),
                                          Acc#{Name => lists:sublist([{Hash, Now} | Entries], ?HISTORY_MAX)}
                                  end, History, Plan)}.

-doc "The hashes loaded for the module `Name`, newest first; empty for one never loaded.".
-spec history(store(), name()) -> history().
history(#{history := History}, Name) ->
    maps:get(Name, History, []).

-doc """
What a report may show of the store: its limit and the bytes it holds or has promised, its
blobs' hashes, each upload's hash, size and bytes received, and how many modules have a
history. It holds no blob's bytes.
""".
-spec summary(store()) -> map().
summary(#{limit := Limit, used := Used, blobs := Blobs, uploads := Uploads, history := History}) ->
    #{limit => Limit, used => Used, blobs => maps:keys(Blobs),
      uploads => [{Hash, Size, Received} || #upload{hash = Hash, size = Size, received = Received} <- Uploads],
      modules => map_size(History)}.
