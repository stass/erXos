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

The grants run under erx_fs_grants, a supervisor of temporary children that the mint
starts linked to itself, so the end of a grant ends nothing else, while the mint's end,
and so the volume's, ends every grant. erx_fs_grants applies the facet row's limits.
""".

-export([start_link/2, mint_request/3, grant/5]).
%% The mint's process.
-export([mint_init/2]).

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
    {ok, Grants} = erx_fs_grants:start_link(erx_lfs, Name),
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
with a positive tag, a domain id as its grantee, its principal's name and a map of
limits, is granted;
anything else is unknown and dropped.
""".
-spec mint_request(pos_integer(), atom(), term()) ->
          {grant, pos_integer(), pos_integer(), map()} | unknown.
mint_request(System, Service, {erx_origin, System, {erx_facet_mint, Tag, Service, Grantee, Principal, Limits}})
  when is_integer(Tag), Tag > 0, is_integer(Grantee), Grantee > 0, is_binary(Principal), is_map(Limits) ->
    {grant, Tag, Grantee, Limits};
mint_request(_System, _Service, _Message) ->
    unknown.

-doc """
The answer to one granted request, in a domain whose system domain's id is System: a
grant under Grants for Grantee with the options Limits give it, exported to Grantee
through Exports (erx_dist, or a host test's stand-in) before this returns; or the
refusal, which leaves no grant.
""".
-spec grant(pid(), pos_integer(), pos_integer(), map(), module()) -> {ok, pid()} | {error, term()}.
grant(Grants, System, Grantee, Limits, Exports) ->
    case connection_to(System, Grantee) of
        {ok, Connection} ->
            erx_fs_grants:grant(Grants, Limits, #{client => Grantee, ends_with => Connection, exports => Exports});
        {error, _} = Refused ->
            Refused
    end.

%% The system domain's grant lives as long as this domain, and so ends with no
%% connection; any other grantee's ends with this domain's connection to it, which must
%% be up.
connection_to(System, System) -> {ok, none};
connection_to(_System, Grantee) -> erx_connections:connection(Grantee).
