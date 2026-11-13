%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_grants).
-moduledoc """
The grants of one file tree that a files service hands to other domains: a
supervisor of temporary erx_fs grants of the tree a callback module serves, each
read-write and bound to one client domain (erx_fs:start_link/4). A files service
of a configured domain asks it through its mint (erx_lfs_mint); one the system
domain serves names it with erx_facet:serve/2, and the domain service asks it for
each grantee's grant in the grantee's ready answer (docs/design-system.md,
"Facets of the system domain's services").

The grants are temporary children, so the end of a grant, by its client's end or
by its heap bound, ends nothing else, while the supervisor's end ends every grant.

Of a facet row's limits a grant applies three (grant_options/1):

* `in_flight`, the most requests it holds at once, at most erx_fs_grant's 64;
* `max_request`, the largest message size it agrees to at version (advertised,
  not checked against each frame), at most 9P's 65,560; a row below 9P's least,
  4,096, is refused with `{error, einval}`;
* `max_heap_size`, its process's heap bound in words, shared binaries included.

`reductions` and `period_ns` bind no erx_fs grant, as they bind no facet yet
(erx_facet).
""".

-behaviour(supervisor).

-export([start_link/1, start_link/2, grant/3, grant/4, grant_options/1]).
%% The supervisor's callback and its child's start.
-export([init/1, start_grant/3]).

-define(IN_FLIGHT_MAX, 64).
-define(MSIZE_MIN, 4096).
-define(MSIZE_MAX, 65560).

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
                                    exports := module()}) -> {ok, pid()} | {error, term()}.
grant(Grants, Args, Limits, #{client := _, ends_with := _, exports := _} = Binding) ->
    case grant_options(Limits) of
        {ok, Options} -> supervisor:start_child(Grants, [Args, maps:merge(Options, Binding)]);
        {error, _} = Refused -> Refused
    end.

-doc """
One grant under Grants with the options a facet row's Limits give it, bound by
Binding: `client`, the grantee's domain id, `ends_with`, what the grant ends with
(erx_fs:start_link/4), and `exports`, the export table it exports itself to its
client through before this returns. A refused export, or Limits a row would
refuse, is the answer and leaves no grant.
""".
-spec grant(pid(), map(), #{client := pos_integer(), ends_with := port() | pid() | none,
                            exports := module()}) -> {ok, pid()} | {error, term()}.
grant(Grants, Limits, #{client := Client, ends_with := _, exports := _} = Binding)
  when is_integer(Client), Client > 0 ->
    case grant_options(Limits) of
        {ok, Options} -> supervisor:start_child(Grants, [maps:merge(Options, Binding)]);
        {error, _} = Refused -> Refused
    end.

-doc """
The erx_fs options a facet row's Limits give a grant, or `{error, einval}` for a
row whose `max_request` is below 9P's least message size, whose `in_flight` is not
positive, or whose `max_heap_size` is below the emulator's least heap. A limit the
row leaves out keeps erx_fs's bound.
""".
-spec grant_options(map()) -> {ok, map()} | {error, einval}.
grant_options(Limits) ->
    InFlight = maps:get(in_flight, Limits, ?IN_FLIGHT_MAX),
    Msize = maps:get(max_request, Limits, ?MSIZE_MAX),
    Heap = maps:get(max_heap_size, Limits, none),
    {min_heap_size, LeastHeap} = erlang:system_info(min_heap_size),
    case is_integer(InFlight) andalso InFlight > 0 andalso is_integer(Msize) andalso Msize >= ?MSIZE_MIN
        andalso (Heap =:= none orelse is_integer(Heap) andalso Heap >= LeastHeap) of
        true ->
            Options = #{in_flight => min(InFlight, ?IN_FLIGHT_MAX), msize => min(Msize, ?MSIZE_MAX)},
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
-spec start_grant(module(), term(), map()) -> {ok, pid()} | {error, term()}.
start_grant(Module, Args, Options) ->
    erx_fs:start_link(Module, Args, rw, Options).
