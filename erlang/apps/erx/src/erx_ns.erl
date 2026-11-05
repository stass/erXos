%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The runtime's namespace from Erlang (design-files.md, Building, binding and mounting).
%% A change takes effect for every process of the domain at once and for no other domain.
%% The table lives in prim_file's NIF, which resolves every path through it; this module
%% checks a change's arguments and hands it to prim_file. Each call answers ok or
%% {error, Reason}: einval for a malformed path or option or an unmount where no entry
%% is, enoent for a source that
%% reaches no mount, eexist for a point that already has an entry, ebusy for `/`, and
%% system_limit beyond the table's 64 entries.

-module(erx_ns).

-export([mount/3, unmount/1, bind/2, bind/3]).

-type option() :: {tree, binary()} | ro | rw | rx.
-type reason() :: einval | enametoolong | enoent | eexist | ebusy | system_limit.

%% Mounts the grant Pid at To, a local process. Options name the tree the grant roots in,
%% {tree, Name}, once, and at most one of ro, rw and rx, ro when none is given.
-spec mount(pid(), file:name_all(), [option()]) -> ok | {error, reason()}.
mount(Pid, To, Options) when is_pid(Pid), node(Pid) =:= node(), is_list(Options) ->
    case mount_options(Options, undefined, undefined) of
        {ok, Tree, Rights} -> change(fun() -> prim_file:erx_ns_mount(To, Pid, Tree, Rights) end);
        error -> {error, einval}
    end;
mount(_Pid, _To, _Options) ->
    {error, einval}.

%% Removes the entry at exactly To.
-spec unmount(file:name_all()) -> ok | {error, reason()}.
unmount(To) ->
    change(fun() -> prim_file:erx_ns_unmount(To) end).

%% Shows at To what From reaches, as From's provider or grant rooted there, read-only
%% with the option ro.
-spec bind(file:name_all(), file:name_all()) -> ok | {error, reason()}.
bind(From, To) ->
    bind(From, To, []).

-spec bind(file:name_all(), file:name_all(), [] | [ro]) -> ok | {error, reason()}.
bind(From, To, []) ->
    change(fun() -> prim_file:erx_ns_bind(From, To, false) end);
bind(From, To, [ro]) ->
    change(fun() -> prim_file:erx_ns_bind(From, To, true) end);
bind(_From, _To, _Options) ->
    {error, einval}.

mount_options([], Tree, Rights) when is_binary(Tree) ->
    {ok, Tree, case Rights of undefined -> ro; _ -> Rights end};
mount_options([{tree, Tree} | Rest], undefined, Rights) when is_binary(Tree) ->
    mount_options(Rest, Tree, Rights);
mount_options([Rights | Rest], Tree, undefined) when Rights =:= ro; Rights =:= rw; Rights =:= rx ->
    mount_options(Rest, Tree, Rights);
mount_options(_Options, _Tree, _Rights) ->
    error.

%% A name prim_file cannot encode is malformed.
change(Change) ->
    try
        Change()
    catch
        error:badarg -> {error, einval}
    end.
