%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ble_facet).
-moduledoc """
The `ble` facet (docs/design-bluetooth.md, "The `ble` facet"; abi/services/ble.txt): what
an app in another domain asks of the registry, `erx_gatt_srv`, for the GATT services its
grant names.

The mint (start_link/0) is a process of its own below `erx_bt_top`, started by the boot
script, since it names itself the service's mint with erx_facet:provide/2, which init's
ready report ends, while the registry starts only from the row's `-eval`, after the
report. For each configured grant the domain service sends, in the system domain's
envelope, it starts a facet bound to the grantee, which ends with the mint and with this
domain's connection to the grantee. It refuses a grant to the system domain, which the
manifest check refuses too (B8), so a row that check missed still grants nothing.

The facet is the one check of a grant: init/1 keeps the services its grant's `services`
parameter names, as the atoms of abi/gatt's declarations, so no request makes an atom,
and whether its `identity` parameter asks for a bonded link's identity, which an attach
it forwards carries, so the registry gives the identity to this grant's handler alone;
admit/3 refuses a request of no operation's shape with `badarg` and one naming any other
service with `not_granted`, before the registry sees it. It finds the registry by its
registered name at each request, refusing `unavailable` while none is registered, so a
registry restart ends no facet and no facet holds a registry of an earlier start. It
forwards `{facet, Caller, Request}`, Caller the grantee's process that made the call, so
the forwarded call's `From` names the facet, and Caller becomes the handler, hears the
events and alone answers the writes handed to it.

The operations, each a gen_server call of the grantee's:

* `{attach, Service}`;
* `{set, Service, Char, Value}`, Value a binary;
* `{notify | indicate, Conn, Service, Char, Value}`, Conn a reference;
* `{reply, Req, Answer}`, Req a reference and Answer `ok`, `{error, value_not_allowed}`
  or `{error, Code}` with Code an ATT Application Error, `0x80` to `0x9F`.

The facet has no operation/1: its manifest row says `operations none`, as a configured
domain's service does on Fiasco (docs/design-time.md, "On Fiasco"), and admit/3 decides
what passes.
""".

-behaviour(erx_facet).

-include("generated/erx_abi.hrl").

-export([start_link/0]).
-export([mint_init/1]).
-export([init/1, admit/3]).

-doc """
Starts the mint of `ble`, linked to the caller, `erx_bt_top`, and names it the service's
mint with erx_facet:provide/2 before it returns, so before init's ready report.
""".
-spec start_link() -> {ok, pid()}.
start_link() ->
    proc_lib:start_link(?MODULE, mint_init, [self()]).

-doc false.
mint_init(Parent) ->
    ok = erx_facet:provide(ble, self()),
    proc_lib:init_ack(Parent, {ok, self()}),
    mint(erx_kernel_records:system_domain()).

mint(System) ->
    receive
        {erx_origin, System, {erx_facet_mint, Tag, ble, Grantee, Principal, Limits}}
          when is_integer(Tag), Tag > 0, is_integer(Grantee), Grantee > 0, is_binary(Principal), is_map(Limits) ->
            _ = erx_facet:minted(Tag, grant(System, Grantee, Limits)),
            mint(System);
        _Other ->
            mint(System)
    end.

%% The facet for Grantee, over this domain's connection to it, or the refusal.
grant(System, System, _Limits) ->
    {error, eperm};
grant(_System, Grantee, Limits) ->
    case erx_connections:connection(Grantee) of
        {ok, Connection} ->
            erx_facet:start(?MODULE, Limits#{grantee => Grantee, ends_with => [Connection, self()]}, #{});
        {error, _} = Error ->
            Error
    end.

-doc false.
init(#{services := Names} = Limits) when is_list(Names) ->
    {ok, #{services => [Service || Service <- erx_gatt_decl:names(), lists:member(atom_to_binary(Service), Names)],
           identity => maps:get(identity, Limits, false) =:= true}}.

-doc false.
admit(Request, Caller, #{services := Services} = Grant) ->
    case named(Request) of
        error -> {refuse, badarg, Grant};
        reply -> forward(true, Request, Caller, Grant);
        {service, Service} -> forward(lists:member(Service, Services), Request, Caller, Grant)
    end.

forward(false, _Request, _Caller, Grant) ->
    {refuse, not_granted, Grant};
forward(true, Request, Caller, Grant) ->
    case whereis(erx_gatt_srv) of
        undefined -> {refuse, unavailable, Grant};
        Registry -> {forward, Registry, {facet, Caller, as_granted(Request, Grant)}, Grant}
    end.

%% The request as the registry takes it: an attach with whether the grant asks for a
%% bonded link's identity; every other as made.
as_granted({attach, Service}, #{identity := Identity}) -> {attach, Service, Identity};
as_granted(Request, _Grant) -> Request.

%% The service a request of an operation's shape names; reply for a reply, which names
%% the write it answers instead; error for any other term.
named({attach, Service}) when is_atom(Service) ->
    {service, Service};
named({set, Service, Char, Value}) when is_atom(Service), is_atom(Char), is_binary(Value) ->
    {service, Service};
named({Kind, Conn, Service, Char, Value})
  when (Kind =:= notify orelse Kind =:= indicate), is_reference(Conn), is_atom(Service), is_atom(Char),
       is_binary(Value) ->
    {service, Service};
named({reply, Req, Answer}) when is_reference(Req) ->
    case answer(Answer) of
        true -> reply;
        false -> error
    end;
named(_Request) ->
    error.

answer(ok) -> true;
answer({error, value_not_allowed}) -> true;
answer({error, Code})
  when is_integer(Code), Code >= ?ERX_ATT_APPLICATION_ERROR_MIN, Code =< ?ERX_ATT_APPLICATION_ERROR_MAX ->
    true;
answer(_Answer) -> false.
