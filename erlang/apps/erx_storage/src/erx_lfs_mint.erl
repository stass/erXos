%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_lfs_mint).
-moduledoc """
The mint of a littlefs volume's files service (docs/design-stopgap.md, "littlefs in
the storage domain"): `data`, the storage domain's `/data` for the system domain and
root's session. It is a child of erx_lfs_sup, started after the volume's owner, so it
serves the volume already mounted, and it names itself the service's mint
(erx_facet:provide/2) before the domain's ready report.

For each mint request in the system domain's envelope (mint_request/3) it starts one
erx_fs grant of the volume's tree, read-write, whose client is the grantee's domain id,
so the grant takes frames only in that domain's envelope and with that domain's names
(erx_fs_grant, S9). The grant exports itself to the grantee, with `send` alone, before
its start returns, so no answer names a grant the grantee cannot reach; a refused export
is the mint's answer, and no grant is left. A grant for another domain than the system
domain ends with this domain's connection to the grantee (erx_connections:connection/1):
a grantee's restart is a new domain id and a new connection, so a frame of the old
incarnation reaches no grant that would take it. A grant for the system domain lives as
long as this domain, whose link to the system domain is its own.

The grants run under a supervisor of temporary children that the mint starts linked to
itself, so the end of a grant, by its connection or by its heap bound, ends nothing
else, while the mint's end, and so the volume's, ends every grant.

Of the facet row's limits the grant applies three (erx_fs:start_link/4):

* `in_flight`, the most requests it holds at once, at most erx_fs_grant's 64;
* `max_request`, the largest message size it agrees to at version (advertised, not
  checked against each frame), at most 9P's 65,560;
  a row below 9P's least, 4,096, is refused with `{error, einval}`;
* `max_heap_size`, its process's heap bound in words, shared binaries included.

`reductions` and `period_ns` bind no erx_fs grant, as they bind no facet yet
(erx_facet).
""".

-behaviour(supervisor).

-export([start_link/2, mint_request/3, grant_options/1, start_grants/2, grant/5]).
%% The mint's process, and the grants supervisor's callback and child start.
-export([mint_init/2, init/1, start_grant/3]).

-define(IN_FLIGHT_MAX, 64).
-define(MSIZE_MIN, 4096).
-define(MSIZE_MAX, 65560).

-doc """
Starts the mint of the files service Service for the volume whose owner is registered
as Name, linked to the caller, erx_lfs_sup. A machine without the volume starts no mint.
""".
-spec start_link(atom(), atom()) -> {ok, pid()} | ignore.
start_link(Service, Name) when is_atom(Service), is_atom(Name) ->
    case whereis(Name) of
        undefined -> ignore;
        _Owner -> proc_lib:start_link(?MODULE, mint_init, [self(), {Service, Name}])
    end.

-doc false.
mint_init(Parent, {Service, Name}) ->
    {ok, Grants} = start_grants(erx_lfs, Name),
    ok = erx_facet:provide(Service, self()),
    proc_lib:init_ack(Parent, {ok, self()}),
    mint(erx_kernel_records:system_domain(), Service, Grants).

mint(System, Service, Grants) ->
    receive
        Message ->
            ok = mint_one(mint_request(System, Service, Message), System, Grants),
            mint(System, Service, Grants)
    end.

mint_one({grant, Tag, Grantee, Limits}, System, Grants) ->
    _ = erx_facet:minted(Tag, grant(Grants, System, Grantee, Limits, erx_dist)),
    ok;
mint_one(unknown, _System, _Grants) ->
    ok.

-doc """
What the mint of the service Service, in a domain whose system domain's id is System,
does with Message: a mint request in the system domain's envelope, for this service,
with a positive tag, a domain id as its grantee and a map of limits, is granted;
anything else is unknown and dropped.
""".
-spec mint_request(pos_integer(), atom(), term()) ->
          {grant, pos_integer(), pos_integer(), map()} | unknown.
mint_request(System, Service, {erx_origin, System, {erx_facet_mint, Tag, Service, Grantee, Limits}})
  when is_integer(Tag), Tag > 0, is_integer(Grantee), Grantee > 0, is_map(Limits) ->
    {grant, Tag, Grantee, Limits};
mint_request(_System, _Service, _Message) ->
    unknown.

-doc """
The erx_fs options a facet row's Limits give a grant, or `{error, einval}` for a row
whose `max_request` is below 9P's least message size, whose `in_flight` is not
positive, or whose `max_heap_size` is below the emulator's least heap. A limit the row leaves out keeps erx_fs's bound.
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

-doc """
Starts the supervisor of the grants of the tree Module serves from Args, linked to the
caller: the mint, for erx_lfs on the volume's owner, or a host test, for a test tree.
""".
-spec start_grants(module(), term()) -> {ok, pid()}.
start_grants(Module, Args) ->
    supervisor:start_link(?MODULE, {grants, Module, Args}).

-doc """
The answer to one granted request, in a domain whose system domain's id is System: a
grant under Grants for Grantee with the options Limits give it, exported to Grantee
through Exports (erx_dist, or a host test's stand-in) before this returns; or the
refusal, which leaves no grant.
""".
-spec grant(pid(), pos_integer(), pos_integer(), map(), module()) -> {ok, pid()} | {error, term()}.
grant(Grants, System, Grantee, Limits, Exports) ->
    case {grant_options(Limits), connection_to(System, Grantee)} of
        {{ok, Options}, {ok, Connection}} ->
            supervisor:start_child(Grants, [Options#{client => Grantee, ends_with => Connection,
                                                     exports => Exports}]);
        {{error, _} = Refused, _} ->
            Refused;
        {_, {error, _} = Refused} ->
            Refused
    end.

%% The system domain's grant lives as long as this domain, and so ends with no
%% connection; any other grantee's ends with this domain's connection to it, which must
%% be up.
connection_to(System, System) -> {ok, none};
connection_to(_System, Grantee) -> erx_connections:connection(Grantee).

-doc false.
init({grants, Module, Args}) ->
    Grant = #{id => grant, start => {?MODULE, start_grant, [Module, Args]},
              restart => temporary, shutdown => brutal_kill, type => worker,
              modules => [erx_fs]},
    {ok, {#{strategy => simple_one_for_one, intensity => 0, period => 1}, [Grant]}}.

-doc false.
-spec start_grant(module(), term(), map()) -> {ok, pid()} | {error, term()}.
start_grant(Module, Args, Options) ->
    erx_fs:start_link(Module, Args, rw, Options).
