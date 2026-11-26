%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_grants).
-moduledoc """
The grants of one file tree that a files service hands to other domains: a
supervisor of temporary erx_fs grants of the tree a callback module serves, each
with its facet row's rights and bound to one client domain (erx_fs:start_link/4).
A files service of a configured domain asks it through its mint (erx_fs_mint); one the system
domain serves names it with erx_facet:serve/2, and the domain service asks it for
each grantee's grant in the grantee's ready answer (docs/design-system.md,
"Facets of the system domain's services").

The grants are temporary children, so the end of a grant, by its client's end or
by its heap bound, ends nothing else, while the supervisor's end ends every grant.

Of a facet row's limits and parameters a grant applies five (grant_options/1):

* `rights`, the files interface's parameter (abi/services/files.txt), `ro`, `rw`
  or `rx`, and `rw` for a row that states none; an `ro` or `rx` grant refuses
  every writing operation before its callback (docs/design-files.md, F5), and the
  rights are fixed when the grant starts, so no request widens them;
* `tree`, the files interface's other parameter, a member of `files_tree`: the
  grant starts from the arguments its tree's module answers for that root
  for its grantee (erx_fs's subtree/3), and a module that roots none there refuses the grant
  with `{error, einval}`, so a grant is rooted where its row says or not started;
  a row that states none roots the grant at the tree's root;
* `in_flight`, the most requests it holds at once, at most erx_fs_grant's 64;
* `max_request`, the largest message size it agrees to at version (advertised,
  not checked against each frame), at most 9P's 65,560; a row below 9P's least,
  4,096, is refused with `{error, einval}`;
* `max_heap_size`, its process's heap bound in words, shared binaries included.

`reductions` and `period_ns` bind no erx_fs grant, as they bind no facet yet
(erx_facet).
""".

-behaviour(supervisor).

-export([start_link/1, start_link/2, grant/3, grant/4, own/1, own/2, grant_options/1, facet/3]).
%% The supervisor's callback and its child's start.
-export([init/1, start_grant/3]).

-include("generated/erx_abi.hrl").

-define(IN_FLIGHT_MAX, 64).
-define(MSIZE_MIN, 4096).
-define(MSIZE_MAX, 65560).
%% The limits an own grant (own/1,2) starts with, from which its facet's rights follow.
-define(OWN, #{rights => rw}).

%% The grantee a tree's subtree/3 roots a grant for: the domain the grant is for, and
%% the name of its principal where the grant's mint named one (erx_fs_mint).
-type grantee() :: #{client := erx_fs_grant:client(), principal => binary()}.
-export_type([grantee/0]).

-doc """
Starts the supervisor of the grants of the tree Module serves from Args, linked to
the caller.
""".
-spec start_link(module(), term()) -> {ok, pid()}.
start_link(Module, Args) when is_atom(Module) ->
    supervisor:start_link(?MODULE, {Module, Args}).

-doc """
Starts the supervisor of the grants of the tree Module serves, linked to the
caller, where each grant names the Args its tree starts from (grant/4): a
tree that serves each client its own part, as erx_winfs serves each client
its own directory.
""".
-spec start_link(module()) -> {ok, pid()}.
start_link(Module) when is_atom(Module) ->
    supervisor:start_link(?MODULE, Module).

-doc """
One grant under Grants, a supervisor start_link/1 started, of the tree Args
name, bound as grant/3 binds one, or with `client` `own` for a client of the
server's own domain.
""".
-spec grant(pid(), term(), map(), #{client := pos_integer() | own,
                                    ends_with := port() | pid() | none,
                                    exports := module()}) -> {ok, pid(), binary()} | {error, term()}.
grant(Grants, Args, Limits, #{client := _, ends_with := _, exports := _} = Binding) ->
    case grant_options(Limits) of
        {ok, Options} -> started(supervisor:start_child(Grants, [Args, maps:merge(Binding, Options)]));
        {error, _} = Refused -> Refused
    end.

-doc """
One grant under Grants with the options a facet row's Limits give it, bound by
Binding: `client`, the grantee's domain id, `ends_with`, what the grant ends with
(erx_fs:start_link/4), and `exports`, the export table it exports itself to its
client through before this returns. The answer is the grant's pid with the tree its
server names, `{ok, Pid, Tree}`, the reply a mint sends for it
(docs/design-system.md, "the mint's reply"). A refused export, or Limits a row
would refuse, is the answer and leaves no grant.
""".
-spec grant(pid(), map(), #{client := pos_integer(), ends_with := port() | pid() | none,
                            exports := module(), principal => binary()}) ->
          {ok, pid(), binary()} | {error, term()}.
grant(Grants, Limits, #{client := Client, ends_with := _, exports := _} = Binding)
  when is_integer(Client), Client > 0 ->
    case grant_options(Limits) of
        {ok, Options} -> started(supervisor:start_child(Grants, [maps:merge(Binding, Options)]));
        {error, _} = Refused -> Refused
    end.

-doc """
One grant under Grants, a supervisor start_link/2 started, for the server's own
domain, with erx_fs's own bounds: the grant a system domain's files service
mounts in that domain's own namespace (erx_ns:mount_own/2), returned as the
handle its start answered, which carries the tree the grant's server names and
the rights it serves (docs/design-files.md, "The tree beneath an entry"). It is
exported to no one, ends with Grants and, a temporary child as every grant is,
is not restarted when it ends alone (TODO.md).

""".
-spec own(pid()) -> {ok, erx_fs:grant_handle()}.
own(Grants) ->
    owned(supervisor:start_child(Grants, [?OWN])).

-doc """
As own/1, for a supervisor start_link/1 started, whose grant's tree starts
from Args.
""".
-spec own(pid(), term()) -> {ok, erx_fs:grant_handle()}.
own(Grants, Args) ->
    owned(supervisor:start_child(Grants, [Args, ?OWN])).

owned({ok, _Pid, Handle}) -> {ok, Handle}.

%% A grant started for another domain is answered by its pid and the tree its handle
%% carries, which the domain that holds it installs with the facet
%% (docs/design-files.md, "The tree beneath an entry").
started({ok, Pid, Handle}) -> {ok, Pid, erx_fs:handle_tree(Handle)};
started({error, _} = Refused) -> Refused.

-doc """
The facet of the grant Pid on the tree Tree as the grantee's registry holds it
(erx_facets:files/3): the pid with the tree its server named and the rights of its
facet row's Limits, the rights the grant serves (grant_options/1), which no reply
of the server's sets (docs/design-files.md, "Rights beneath an entry").
""".
-spec facet(pid(), binary(), map()) -> erx_facets:facet().
facet(Pid, Tree, Limits) ->
    erx_facets:files(Pid, Tree, rights(Limits)).

%% The rights a facet row's Limits give its grant, rw where the row states none
%% (abi/services/files.txt).
rights(Limits) ->
    maps:get(rights, Limits, rw).

-doc """
The grant's rights and the erx_fs options a facet row's Limits give it, or
`{error, einval}` for a row whose `max_request` is below 9P's least message size,
whose `in_flight` is not positive, whose `max_heap_size` is below the emulator's
least heap, whose `rights` is not `ro`, `rw` or `rx`, or whose `tree` is no member of
`files_tree`. A limit the row leaves out keeps erx_fs's bound, rights it leaves out
are `rw`, and a tree it states is the options' `tree`.
""".
-spec grant_options(map()) -> {ok, map()} | {error, einval}.
grant_options(Limits) ->
    Rights = rights(Limits),
    Tree = maps:with([tree], Limits),
    InFlight = maps:get(in_flight, Limits, ?IN_FLIGHT_MAX),
    Msize = maps:get(max_request, Limits, ?MSIZE_MAX),
    Heap = maps:get(max_heap_size, Limits, none),
    {min_heap_size, LeastHeap} = erlang:system_info(min_heap_size),
    case lists:keymember(Rights, 1, ?ERX_FILES_RIGHTS_MEMBERS)
        andalso lists:all(fun(Member) -> lists:keymember(Member, 1, ?ERX_FILES_TREE_MEMBERS) end, maps:values(Tree))
        andalso is_integer(InFlight) andalso InFlight > 0
        andalso is_integer(Msize) andalso Msize >= ?MSIZE_MIN
        andalso (Heap =:= none orelse is_integer(Heap) andalso Heap >= LeastHeap) of
        true ->
            Options = Tree#{rights => Rights, in_flight => min(InFlight, ?IN_FLIGHT_MAX),
                            msize => min(Msize, ?MSIZE_MAX)},
            {ok, case Heap of
                     none -> Options;
                     _ -> Options#{max_heap_size => Heap}
                 end};
        false ->
            {error, einval}
    end.

-doc false.
init(Module) when is_atom(Module) ->
    {ok, {grants_spec(), [grant_spec({?MODULE, start_grant, [Module]})]}};
init({Module, Args}) ->
    {ok, {grants_spec(), [grant_spec({?MODULE, start_grant, [Module, Args]})]}}.

grants_spec() ->
    #{strategy => simple_one_for_one, intensity => 0, period => 1}.

grant_spec(Start) ->
    #{id => grant, start => Start, restart => temporary, shutdown => brutal_kill,
      type => worker, modules => [erx_fs]}.

-doc false.
-spec start_grant(module(), term(), map()) -> {ok, pid(), erx_fs:grant_handle()} | {error, term()}.
start_grant(Module, Args, Options) ->
    Grantee = maps:with([client, principal], Options),
    {Rights, Rest} = maps:take(rights, maps:remove(principal, Options)),
    case maps:take(tree, Rest) of
        error -> erx_fs:start_link(Module, Args, Rights, Rest);
        {Tree, FsOptions} -> start_rooted(Module, subtree(Module, Args, Tree, Grantee), Rights, FsOptions)
    end.

start_rooted(Module, {ok, Rooted}, Rights, FsOptions) -> erx_fs:start_link(Module, Rooted, Rights, FsOptions);
start_rooted(_Module, {error, einval} = Refused, _Rights, _FsOptions) -> Refused.

%% The arguments of a grant for Grantee rooted at Tree within the tree Args name, from
%% the tree's module, which roots none there unless it has subtree/3 and that answers it.
subtree(Module, Args, Tree, Grantee) ->
    _ = code:ensure_loaded(Module),
    case erlang:function_exported(Module, subtree, 3) of
        true -> Module:subtree(Args, Tree, Grantee);
        false -> {error, einval}
    end.
