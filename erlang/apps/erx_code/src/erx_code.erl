%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_code).
-behaviour(gen_server).

-moduledoc """
The code service of the system domain (docs/design-live.md, "Code from the host" and "The
code store"): it keeps the in-memory code store, erx_code_store, and loads modules into the
system domain's runtime by hash.

Every operation is one request term, read by `erx_code_store:read_request/1`, so the host
link's install facet hands `call/1` the term it decoded and nothing else; the other exports
build the same terms for callers in the system domain. A host loads a set of modules in
three steps, sending only what the store lacks: `missing/1` with the modules' hashes,
`put_piece/4` for each piece of each missing blob, then `load/1` with the manifest.

A load is planned whole before it changes anything. The plan names every module's verified
bytes (`erx_code_store:plan_load/2`); `code:prepare_loading/1` then checks every module of
it, its name against its bytes included, and `code:finish_loading/1`, the two halves of
`code:atomic_load/1`, makes the batch current or refuses it whole. Its last check is that
no module still has old code; only when every refusal is that one does the service purge
the old code of those modules, as stock's loads purge it, and finish the batch again, so a
load refused for any other reason, a sticky or pending module, purges nothing. Either every
module of the manifest is current when `load/1` returns `ok` or none changed. Purging ends
any process still running a module's old code, as `code:load_binary/3` does. Names become
atoms only here, after the manifest has been read, at most 1,024 of 255 bytes each per
load; a load the loader refuses still leaves its names' atoms behind (TODO.md).
""".

-export([start_link/0, start_link/1, call/1, missing/1, put_piece/4, load/1, history/2]).
-export([init/1, handle_call/3, handle_cast/2, format_status/1]).
-export_type([reply/0]).

%% The system domain's id (docs/design-domains.md: no node has a creation below 4).
-define(SYSTEM_DOMAIN, 4).
%% The store's limit: the overlay limit's default (docs/design-live.md, "Overlays").
-define(STORE_LIMIT, 16 * 1024 * 1024).
%% A load prepares, purges and loads up to 1,024 modules.
-define(CALL_TIMEOUT, 60000).

-doc """
The answer to a request. A load that `code:prepare_loading/1` or `code:finish_loading/1`
refuses answers `{error, {not_loaded, [{Name, What}]}}`, with `What` as `code:atomic_load/1`
gives it.
""".
-type reply() :: ok
               | {ok, [erx_code_store:hash()]}
               | {ok, erx_code_store:put_reply()}
               | {ok, erx_code_store:history()}
               | {error, bad_request | {bad_manifest, erx_code_store:manifest_error()}
                       | erx_code_store:put_error()
                       | {missing, [erx_code_store:hash()]}
                       | {hash_mismatch, erx_code_store:name()}
                       | {not_loaded, [{erx_code_store:name(), atom()}]}
                       | scope}.

-doc "Starts the code service, registered as `erx_code`, with a store of 16 MiB.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-doc "As `start_link/0`, with the store's byte limit `limit` from `Options`.".
-spec start_link(#{limit => pos_integer()}) -> gen_server:start_ret().
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, maps:get(limit, Options, ?STORE_LIMIT), []).

-doc """
Serves one request term from outside the code service, as `erx_code_store:read_request/1`
lists them. A term of any other shape answers `{error, bad_request}` and changes nothing.
""".
-spec call(term()) -> reply().
call(Request) ->
    gen_server:call(?MODULE, {request, Request}, ?CALL_TIMEOUT).

-doc "The hashes of `Hashes` whose blobs the store lacks.".
-spec missing([erx_code_store:hash()]) -> reply().
missing(Hashes) ->
    call({missing, Hashes}).

-doc "One piece of the blob `Hash` of `Size` bytes, at `Offset` (`erx_code_store:put_piece/5`).".
-spec put_piece(erx_code_store:hash(), pos_integer(), non_neg_integer(), binary()) -> reply().
put_piece(Hash, Size, Offset, Piece) ->
    call({put, Hash, Size, Offset, Piece}).

-doc "Loads the modules of `Manifest`, `[{Name, Hash}]`, into the system domain as one batch.".
-spec load(term()) -> reply().
load(Manifest) ->
    call({load, Manifest}).

-doc """
The hashes loaded into domain `DomainId` for `Module`, newest first, at most 16, each with
the time of its load in milliseconds of `erlang:system_time/1`. The service loads only into
the system domain, so any other domain answers `{error, scope}`.
""".
-spec history(integer(), module() | binary()) -> reply().
history(DomainId, Module) when is_atom(Module) ->
    history(DomainId, atom_to_binary(Module));
history(DomainId, Module) ->
    call({history, DomainId, Module}).

-doc false.
-spec init(pos_integer()) -> {ok, erx_code_store:store()}.
init(Limit) ->
    {ok, erx_code_store:new(Limit)}.

-doc false.
-spec handle_call({request, term()}, gen_server:from(), erx_code_store:store()) ->
          {reply, reply(), erx_code_store:store()}.
handle_call({request, Term}, _From, Store) ->
    {Reply, Next} = case erx_code_store:read_request(Term) of
                        {ok, Request} -> serve(Request, Store);
                        {error, _} = Refused -> {Refused, Store}
                    end,
    {reply, Reply, Next}.

-doc """
The state as a crash report or `sys:get_status/1` shows it: the store's size and its
blobs' hashes, never its bytes, and of the request being served only its kind, so no
report carries bytes from outside.
""".
-spec format_status(gen_server:format_status()) -> gen_server:format_status().
format_status(Status) ->
    maps:map(fun(state, Store) -> erx_code_store:summary(Store);
                (message, {request, Request}) when is_tuple(Request), tuple_size(Request) > 0 ->
                     {request, element(1, Request)};
                (message, _Message) -> request;
                (log, _Log) -> [];
                (_Key, Value) -> Value
             end, Status).

-doc false.
-spec handle_cast(term(), erx_code_store:store()) -> {noreply, erx_code_store:store()}.
handle_cast(_Message, Store) ->
    {noreply, Store}.

serve({missing, Hashes}, Store) ->
    {{ok, erx_code_store:missing(Store, Hashes)}, Store};
serve({put, Hash, Size, Offset, Piece}, Store) ->
    case erx_code_store:put_piece(Store, Hash, Size, Offset, Piece) of
        {ok, Reply, Next} -> {{ok, Reply}, Next};
        {error, Why, Next} -> {{error, Why}, Next}
    end;
serve({load, Manifest}, Store) ->
    case erx_code_store:plan_load(Store, Manifest) of
        {ok, Plan} ->
            case activate(Plan) of
                ok -> {ok, erx_code_store:commit(Store, Plan, erlang:system_time(millisecond))};
                {error, _} = Failed -> {Failed, Store}
            end;
        {error, _} = Refused ->
            {Refused, Store}
    end;
serve({history, ?SYSTEM_DOMAIN, Name}, Store) ->
    {{ok, erx_code_store:history(Store, Name)}, Store};
serve({history, _DomainId, _Name}, Store) ->
    {{error, scope}, Store}.

%% Makes the plan's modules current as one batch, or none of them. A module's file name,
%% which code:which/1 reports, is its blob's hash in hexadecimal.
activate(Plan) ->
    Modules = [{binary_to_atom(Name), hex(Hash) ++ ".beam", Bytes} || {Name, Hash, Bytes} <- Plan],
    case code:prepare_loading(Modules) of
        {ok, Prepared} -> finish(Prepared, purge_once);
        {error, Failed} -> not_loaded(Failed)
    end.

%% A batch refused only because some of its modules still have old code is finished again
%% once that old code is purged; a batch refused for anything else purges nothing.
finish(Prepared, Purge) ->
    case {code:finish_loading(Prepared), Purge} of
        {ok, _} ->
            ok;
        {{error, Failed}, purge_once} ->
            case lists:all(fun({_Module, What}) -> What =:= not_purged end, Failed) of
                true ->
                    lists:foreach(fun({Module, not_purged}) -> code:purge(Module) end, Failed),
                    finish(Prepared, purged);
                false ->
                    not_loaded(Failed)
            end;
        {{error, Failed}, purged} ->
            not_loaded(Failed)
    end.

not_loaded(Failed) ->
    {error, {not_loaded, [{atom_to_binary(Module), What} || {Module, What} <- Failed]}}.

hex(Hash) ->
    binary_to_list(binary:encode_hex(Hash, lowercase)).
