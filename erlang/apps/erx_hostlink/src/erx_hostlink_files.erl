%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hostlink_files).
-moduledoc """
The host link's 9P bridge process (docs/design-live.md, "Files between the
host and the machine"): the effects around `erx_hostlink_9p`'s pure core.

`erx_hostlink` starts one bridge for each host-link session and ends it with
the session, so the files stream's 9P session lives exactly as long as the
host-link session it rides in. The bridge owns every fid it holds on a grant
(docs/design-files.md, "Fid owners"), so its end, at a session's end or at
any failure, makes each grant clunk them: a replaced session leaves nothing
open on the machine. It ends too when `erx_hostlink` does.

It takes the files stream's bodies as `{files_in, Link, Bytes}`, draws a
fresh alias and a fid for each, and hands the core's host messages back as
`{files_out, Bridge, Bytes}`. A grant's reply arrives at the alias of its
request; anything else it receives is dropped. Each alias is made with
`erlang:alias([reply])`, so it ends with its one reply.

Which trees the host may reach is the host-link configuration's:
`files_trees` in `erx_hostlink`'s environment, a list of atoms, when it sets
one, and otherwise the build's (`default_trees/1`): `proc` and `data` in a
development build, none in a release build. The build's kind is the system
manifest's development flag, which the image build checks against the kind
it builds, so the bridge reads it there; a manifest it cannot read lists
none. Each tree is found among the system domain's namespace entries as the
grant mounted with that tree name and no root below it (`tree_grant/3`).
""".

-export([start/2, tree_grant/3, configured_trees/0, default_trees/1, manifest_flags/1]).
-export([init/2]).

-include("generated/erx_abi.hrl").

%% The bridge's heap: its tables are bounded by the pool, 256 fids, and 64
%% tags, and a message it holds by the stream's msize.
-define(MAX_HEAP_WORDS, 1048576).

-doc """
Starts a bridge for `Link`, the host link's process, and monitors it from the
caller. `Options` may set `trees`, the core's tree lookup, `draw_fid`, the
source of grant fids (`prim_file:erx_fid/0`, the runtime's one counter), and
`pool`, for the tests.
""".
-spec start(pid(), map()) -> {pid(), reference()}.
start(Link, Options) ->
    Heap = #{size => ?MAX_HEAP_WORDS, kill => true, include_shared_binaries => true},
    spawn_opt(?MODULE, init, [Link, Options], [monitor, {max_heap_size, Heap}]).

-doc false.
-spec init(pid(), map()) -> no_return().
init(Link, Options) ->
    _ = erlang:monitor(process, Link),
    Trees = case Options of
                #{trees := Given} ->
                    Given;
                #{} ->
                    Names = configured_trees(),
                    fun(Aname) -> tree_grant(Aname, Names, prim_file:erx_table()) end
            end,
    Draw = maps:get(draw_fid, Options, fun prim_file:erx_fid/0),
    Bridge = erx_hostlink_9p:new((maps:with([pool], Options))#{trees => Trees}),
    loop(Link, Draw, Bridge).

loop(Link, Draw, Bridge) ->
    receive
        {files_in, Link, Bytes} when is_binary(Bytes) ->
            Alias = erlang:alias([reply]),
            loop(Link, Draw, step({host, Bytes, Alias, Draw()}, Link, Bridge));
        {erx_9p, Alias, Reply} when is_reference(Alias) ->
            loop(Link, Draw, step({reply, Alias, Reply}, Link, Bridge));
        {'DOWN', _Ref, process, Link, _Reason} ->
            exit(normal);
        {'DOWN', _Ref, process, Grant, _Reason} ->
            loop(Link, Draw, step({grant_down, Grant}, Link, Bridge));
        _Other ->
            loop(Link, Draw, Bridge)
    end.

step(Event, Link, Bridge) ->
    {Bridge1, Effects} = erx_hostlink_9p:step(Event, Bridge),
    lists:foreach(fun(Effect) -> act(Effect, Link) end, Effects),
    Bridge1.

act({host, Bytes}, Link) ->
    Link ! {files_out, self(), Bytes};
act({grant, Grant, Alias, Request}, _Link) ->
    Grant ! {erx_9p, Alias, self(), Request};
act({monitor, Grant}, _Link) ->
    _ = erlang:monitor(process, Grant);
act({clunk, Grant, Fid}, _Link) ->
    %% Nobody awaits this answer: it reaches a bridge that no longer knows
    %% the alias, which counts it as stray.
    Grant ! {erx_9p, erlang:alias([reply]), self(), {clunk, Fid}};
act({unalias, Alias}, _Link) ->
    _ = erlang:unalias(Alias).

-doc """
The grant of tree `Aname` when it is one of `Names` and the namespace `Table`
mounts it whole, as `erx_ns` entries `{grant, Pid, Tree}` with root `[]`;
`error` otherwise. Pure, for the tests.
""".
-spec tree_grant(binary(), [binary()], erx_ns:table()) -> {ok, pid()} | error.
tree_grant(Aname, Names, Table) ->
    Mounted = [Pid || #{provider := {grant, Pid, Tree}, root := []} <- Table, Tree =:= Aname],
    case {lists:member(Aname, Names), Mounted} of
        {true, [Pid | _]} -> {ok, Pid};
        _ -> error
    end.

-doc """
The trees the host may reach, as the names attach's Aname takes: those the
host link's configuration lists, or the build's when it lists none.
""".
-spec configured_trees() -> [binary()].
configured_trees() ->
    case application:get_env(erx_hostlink, files_trees) of
        {ok, Names} when is_list(Names) ->
            [atom_to_binary(Name) || Name <- Names, is_atom(Name)];
        {ok, _} ->
            [];
        undefined ->
            default_trees(manifest_flags(file:read_file(manifest_path())))
    end.

-doc """
The trees a build serves when its configuration lists none, from its system
manifest's flags: `proc` and `data` in a development build, and none in a
release build or when the flags are `unknown` (docs/design-live.md, "Files
between the host and the machine"). Pure, for the tests.
""".
-spec default_trees(non_neg_integer() | unknown) -> [binary()].
default_trees(Flags) when is_integer(Flags), Flags band ?ERX_MANIFEST_DEVELOPMENT =/= 0 ->
    [<<"proc">>, <<"data">>];
default_trees(_Flags) ->
    [].

-doc "The flags of the system manifest `file:read_file/1` returned, or `unknown`. Pure, for the tests.".
-spec manifest_flags({ok, binary()} | {error, term()}) -> non_neg_integer() | unknown.
manifest_flags({ok, Manifest}) ->
    maybe
        {ok, View} ?= erx_manifest:open(Manifest),
        {ok, #{flags := Flags}} ?= erx_manifest:header(View),
        Flags
    else
        _ -> unknown
    end;
manifest_flags({error, _}) ->
    unknown.

%% The system manifest in the system domain's namespace, where the system
%% release's tree is the root.
manifest_path() ->
    <<"system/", Path/binary>> = ?ERX_SYSTEM_MANIFEST_PATH_BYTES,
    <<"/", Path/binary>>.
