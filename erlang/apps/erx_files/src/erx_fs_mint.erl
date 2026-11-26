%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_mint).
-moduledoc """
The mint of one files service of a configured domain (docs/design-system.md, "Facets a
configured domain serves"): in the storage domain, of a tree of the data volume
(docs/design-stopgap.md, "littlefs in the storage domain"; erx_lfs, "Trees"), `data`, the
storage domain's `/data` for the system domain and root's session, or `packages`, the
installed app packages (docs/design-packaging.md, "Where a package lies"), or of the
`system` tree, the booted slot's system partition (docs/design-storage.md, "The `system`
tree"); in a USB domain, of its input tree (docs/design-usb.md, "HID reaches the
display"; erx_usb_places_sup). Each mint serves one tree, which an erx_fs callback module serves from the
arguments the mint's mount answers, so a mint hands out grants of its own tree alone.
It names itself the service's mint (erx_facet:provide/2) and acknowledges its start, both
before the domain's ready report; only then does it run the mount, in its own process,
before it takes a request: the supervisor that starts it waits for no mount, and a mint
request that comes first waits in the mint's queue.

For each mint request in the system domain's envelope (mint_request/3) it starts one
erx_fs grant of the service's tree, with the facet row's rights and rooted where its
tree says (erx_fs_grants), whose client is the
grantee's domain id, so the grant takes frames only in that domain's envelope and with
that domain's names (erx_fs_grant, S9). The grant exports itself to the grantee, with
`send` alone, before its start returns, so no answer names a grant the grantee cannot
reach; a refused export is the mint's answer, and no grant is left. A grant for another domain than the system
domain ends with this domain's connection to the grantee (erx_connections:connection/1):
a grantee's restart is a new domain id and a new connection, so a frame of the old
incarnation reaches no grant that would take it. A grant for the system domain lives as
long as this domain, whose link to the system domain is its own.

The grants run under erx_fs_grants, a supervisor of temporary children that the mint
starts linked to itself, so the end of a grant ends nothing else, while the mint's end,
and so the tree's, ends every grant. erx_fs_grants applies the facet row's limits, rights
and tree.
""".

-export([start_link/3, mint_request/3, grant/6]).
%% The mint's process.
-export([mint_init/2]).

-doc """
Starts the mint of the files service Service, whose tree the erx_fs callback module
Module serves from the arguments Mount answers, linked to the caller, the supervisor
of the tree. The mint runs Mount once, in its own process, after this returns.
""".
-spec start_link(atom(), module(), fun(() -> term())) -> {ok, pid()}.
start_link(Service, Module, Mount) when is_atom(Service), is_atom(Module), is_function(Mount, 0) ->
    proc_lib:start_link(?MODULE, mint_init, [self(), {Service, Module, Mount}]).

-doc false.
mint_init(Parent, {Service, Module, Mount}) ->
    ok = erx_facet:provide(Service, self()),
    proc_lib:init_ack(Parent, {ok, self()}),
    {ok, Grants} = erx_fs_grants:start_link(Module, Mount()),
    mint(erx_kernel_records:system_domain(), Service, Grants).

mint(System, Service, Grants) ->
    receive
        Message ->
            ok = mint_one(mint_request(System, Service, Message), System, Grants),
            mint(System, Service, Grants)
    end.

mint_one({grant, Tag, Grantee, Principal, Limits}, System, Grants) ->
    _ = erx_facet:minted(Tag, grant(Grants, System, Grantee, Principal, Limits, erx_dist)),
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
          {grant, pos_integer(), pos_integer(), binary(), map()} | unknown.
mint_request(System, Service, {erx_origin, System, {erx_facet_mint, Tag, Service, Grantee, Principal, Limits}})
  when is_integer(Tag), Tag > 0, is_integer(Grantee), Grantee > 0, is_binary(Principal), is_map(Limits) ->
    {grant, Tag, Grantee, Principal, Limits};
mint_request(_System, _Service, _Message) ->
    unknown.

-doc """
The answer to one granted request, in a domain whose system domain's id is System: a
grant under Grants for Grantee, whose principal is named Principal, with the options
Limits give it, rooted for that grantee where Limits state a tree, exported to Grantee
through Exports (erx_dist, or a host test's stand-in) before this returns; or the
refusal, which leaves no grant.
""".
-spec grant(pid(), pos_integer(), pos_integer(), binary(), map(), module()) ->
          {ok, pid(), binary()} | {error, term()}.
grant(Grants, System, Grantee, Principal, Limits, Exports) ->
    case connection_to(System, Grantee) of
        {ok, Connection} ->
            erx_fs_grants:grant(Grants, Limits, #{client => Grantee, principal => Principal,
                                                  ends_with => Connection, exports => Exports});
        {error, _} = Refused ->
            Refused
    end.

%% The system domain's grant lives as long as this domain, and so ends with no
%% connection; any other grantee's ends with this domain's connection to it, which must
%% be up.
connection_to(System, System) -> {ok, none};
connection_to(_System, Grantee) -> erx_connections:connection(Grantee).
