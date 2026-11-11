%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_erxos).
-moduledoc """
erXos's runtime (docs/design-network-stack.md, "Two places, four seams"), built only into
erXos's images.

The stack runs in the system domain in Phase 1, the stopgap placement of the network
domain, and no socket of it is exported to another domain: every request comes from the
system domain's own processes, so `serve/1` has no envelope to take off and no lane to
limit, as for the portable runtime. The network domain's runtime replaces this once that
domain exists: it takes requests out of their envelope, `{erx_origin, D, Request}`, and
runs each grant under its ERTS's request limit and `erx_facet`.
""".

-behaviour(erx_net_runtime).

-export([serve/1, start_grant/2, children/0, mint_counts/0]).
-export([start_mint/0, mint_init/1]).

-doc "Nothing to do: every request comes from the system domain's own processes.".
-spec serve(pos_integer()) -> ok.
serve(MaxRequest) when is_integer(MaxRequest), MaxRequest > 0 ->
    ok.

-doc """
Starts the grant of `Grantee`, the system domain's own (`local`) or another domain's with
the port of the connection to it and the export table's module (erx_net_grant:start_link/2),
linked to the caller (erx_net_sup or its grant supervisor).
""".
-spec start_grant(local | {pos_integer(), port(), module()}, map()) ->
          {ok, pid()} | {error, term()}.
start_grant(Grantee, Limits) ->
    erx_net_grant:start_link(Grantee, Limits).

-doc """
The mints of the two services the stack provides, then the node's grant `local`, which the
system domain's own processes use while the stack runs there:

* `net`, the network service's mint (start_mint/0);
* `network_ctl`, the driver-control facet's mint (erx_driver_ctl), through which the
  system domain stops, starts or restarts the link of the network device it granted the
  domain. Its units map the manifest's unit `net` to that link: the link supervisor of
  `vtnet0`, the interface erx_virtio_net makes of the domain's first network device, a
  permanent child of `erx_net_interfaces` under its interface name. A stop leaves the
  link stopped; a start builds its driver, interface and DHCP client again; neither
  touches a grant. The driver, a temporary child of the link, is not the controlled
  object: a stop would remove it for good.
""".
-spec children() -> [{atom(), {module(), atom(), [term()]}}].
children() ->
    Units = #{net => {erx_net_interfaces, vtnet0}},
    [{net, {?MODULE, start_mint, []}},
     {network_ctl, {erx_driver_ctl, start_mint, [network_ctl, Units]}},
     {erx_net_grant, {?MODULE, start_grant, [local, #{}]}}].

-doc """
Starts the network service's mint (docs/design-system.md, "Facets a configured domain
serves"), registered as `erx_net_mint`: it names itself the mint of `net`
(erx_facet:provide/2) and then acts on what erx_net_admit:mint/2 takes from each message,
answering through erx_facet:minted/2:

* a request for a grantee: the grant erx_net:mint_grant/4 starts, ending with this
  domain's connection to the grantee (erx_connections:connection/1) and exported to it
  before the answer, or the refusal; a grantee this domain holds no connection to is
  answered that refusal, `{error, noconnection}`;
* a request naming the system domain as the grantee: `{error, eperm}`, counted, since the
  system domain never holds the grant (docs/design-network-stack.md, "The grant").

Every other message is dropped and counted; mint_counts/0 reads both counts. Until the
network domain exists the stack runs in the system domain, which no domain service asks
for a grant.
""".
-spec start_mint() -> {ok, pid()}.
start_mint() ->
    proc_lib:start_link(?MODULE, mint_init, [self()]).

-doc """
The requests the mint refused for naming the system domain as the grantee (`refused`),
and the messages it dropped (`unknown`).
""".
-spec mint_counts() -> #{refused := non_neg_integer(), unknown := non_neg_integer()}.
mint_counts() ->
    gen_server:call(erx_net_mint, counts, infinity).

-doc false.
mint_init(Parent) ->
    true = register(erx_net_mint, self()),
    ok = erx_facet:provide(net, self()),
    proc_lib:init_ack(Parent, {ok, self()}),
    mint(erx_kernel_records:system_domain(), #{refused => 0, unknown => 0}).

mint(System, Counts) ->
    receive
        Message ->
            case erx_net_admit:mint(System, Message) of
                {ok, Tag, Grantee, Limits} ->
                    _ = erx_facet:minted(Tag, mint_one(Grantee, Limits)),
                    mint(System, Counts);
                {refused, Reason, Tag} ->
                    _ = erx_facet:minted(Tag, {error, Reason}),
                    mint(System, count(refused, Counts));
                {counts, From} ->
                    gen_server:reply(From, Counts),
                    mint(System, Counts);
                unknown ->
                    mint(System, count(unknown, Counts))
            end
    end.

count(Key, Counts) ->
    maps:update_with(Key, fun(N) -> N + 1 end, Counts).

%% The answer to one admitted request: the grant over this domain's connection to the
%% grantee, or the refusal.
mint_one(Grantee, Limits) ->
    case erx_connections:connection(Grantee) of
        {ok, Connection} -> erx_net:mint_grant(Grantee, Connection, Limits, erx_dist);
        {error, _} = Error -> Error
    end.
