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
fid for each, and hands the core's host messages back as
`{files_out, Bridge, Bytes}`. The core draws an alias for each message it
sends a grant from `erlang:alias([reply])`, so each alias ends with its one
reply, and a grant's reply arrives at the alias of its request or flush;
anything else the bridge receives is dropped.

Which trees the host may reach is the host-link configuration's:
`files_trees` in `erx_hostlink`'s environment, a list of atoms, when it sets
one, and otherwise the build's (`default_trees/1`): `proc` and `data` in a
development build, none in a release build. The build's kind is the system
manifest's development flag, which the image build checks against the kind
it builds, so the bridge reads it there; a manifest it cannot read lists
none. Each tree is found among the system domain's namespace entries as the
grant mounted with that tree name and no root below it (`tree_grant/3`).
""".

-export([start/2, tree_grant/3, configured_trees/0, default_trees/1, build_flags/0, manifest_flags/1]).
-export([init/2]).

-include("generated/erx_abi.hrl").

%% The bridge's heap: its tables are bounded by the pool, 256 fids, and 64
%% slots, and a message it holds by the stream's msize.
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
                    %% A refused configuration ends the bridge with the reason, which
                    %% names the bad entry, and the files stream has no bridge.
                    Names = case configured_trees() of
                                {ok, Configured} -> Configured;
                                {error, Reason} -> error(Reason)
                            end,
                    fun(Aname) -> tree_grant(Aname, Names, prim_file:erx_table()) end
            end,
    Draw = maps:get(draw_fid, Options, fun prim_file:erx_fid/0),
    Bridge = erx_hostlink_9p:new((maps:with([pool], Options))#{trees => Trees, alias => fun new_alias/0}),
    loop(Link, Draw, Bridge).

loop(Link, Draw, Bridge) ->
    receive
        {files_in, Link, Bytes} when is_binary(Bytes) ->
            loop(Link, Draw, step({host, Bytes, Draw()}, Link, Bridge));
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
    %% Nobody awaits this answer: it reaches a bridge that never knew
    %% the alias, which counts it as stray.
    Grant ! {erx_9p, new_alias(), self(), {clunk, Fid}};
act({unalias, Alias}, _Link) ->
    _ = erlang:unalias(Alias).

%% An alias that ends with the one reply it takes.
new_alias() ->
    erlang:alias([reply]).

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
host link's configuration lists, a list of atoms, or the build's when it
lists none. A configuration that is not a list of atoms is refused with
`{files_trees, Text}`, `Text` the first entry that is no atom, or the tail
or value that is no list, as written and line-escaped.
""".
-spec configured_trees() -> {ok, [binary()]} | {error, {files_trees, binary()}}.
configured_trees() ->
    case application:get_env(erx_hostlink, files_trees) of
        {ok, Names} ->
            tree_names(Names, []);
        undefined ->
            {ok, default_trees(build_flags())}
    end.

tree_names([], Acc) ->
    {ok, lists:reverse(Acc)};
tree_names([Name | Rest], Acc) when is_atom(Name) ->
    tree_names(Rest, [atom_to_binary(Name) | Acc]);
tree_names([Bad | _], _Acc) ->
    refused(Bad);
tree_names(Bad, _Acc) ->
    refused(Bad).

refused(Bad) ->
    {error, {files_trees, erx_text:escape_line(io_lib:format("~tP", [Bad, 12]))}}.

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

-doc """
The flags of this build's system manifest, or `unknown` when it cannot be
read. Its development flag is the build's kind, which the image build checks
against the kind it builds, so the host link's development-only facets read
it here.
""".
-spec build_flags() -> non_neg_integer() | unknown.
build_flags() ->
    manifest_flags(file:read_file(manifest_path())).

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
