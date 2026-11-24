%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_sup).
-moduledoc """
The stack below `erx_bt_top` (docs/design-bluetooth.md, "Concurrency"): `rest_for_one`, the store
first, then the registry, then the file service `erx_bt_fs` with the pairing window, then
the controller group. The store and the registry are temporary, `significant` children
and the supervisor's `auto_shutdown` is `any_significant`, so the end of either ends
`erx_bt_sup` and so the domain, and every facet with the mint: no handler stays attached
to a registry that has forgotten it, and none needs telling. A window's restart ends
every link it would have to answer, so it restarts the group after it; a group's
restart, the one a radio peer's traffic can cause beyond its own link, leaves the store,
its address, the handlers' attachments and the pairing wait alone.

The registry is given GAP's values, the name and the appearance, read here once from
`erx_bt`'s application keys; it lays them into the table's Device Name and Appearance and
answers them to the controller group for its advertising, so the advertised name and GAP's
Device Name have one source.
""".
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-export([gap/3]).

-include("generated/erx_abi.hrl").

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => rest_for_one, auto_shutdown => any_significant},
          [#{id => erx_bt_store, start => {erx_bt_store, start_link, []}, restart => temporary, significant => true},
           #{id => erx_gatt_srv, start => {erx_gatt_srv, start_link, [gap(), served()]}, restart => temporary,
             significant => true},
           #{id => erx_bt_fs, start => {erx_bt_fs, start_link, []}},
           #{id => erx_bt_host_sup, start => {erx_bt_host_sup, start_link, []}, type => supervisor}]}}.

%% The services the registry serves: every service abi/gatt declares, until the manifest's
%% `ble` rows reach the domain (TODO.md, Bluetooth).
served() ->
    [erx_gatt_decl:service(Name) || Name <- erx_gatt_decl:names()].

gap() ->
    gap(application:get_env(erx_bt, name), application:get_env(erx_bt, appearance), node()).

-doc """
GAP's values (docs/design-bluetooth.md, "The Bluetooth domain" and "The attribute
table") from the `name` and `appearance` application keys, as `application:get_env/2`
answers them, and the node name: the name, by default the machine's bare host name,
the host part of the node name up to its first dot, and the appearance, by default 0. A name that is not
UTF-8 text or is longer than GAP's Device Name allows fails with `{bad_name, Name}`,
and an appearance that is not 16 bits with `{bad_appearance, Appearance}`, so the
stack stops at its start.
""".
-spec gap(undefined | {ok, term()}, undefined | {ok, term()}, node()) -> erx_gatt_db:gap().
gap(NameKey, AppearanceKey, Node) ->
    #{name => name(NameKey, Node), appearance => appearance(AppearanceKey)}.

name(undefined, Node) ->
    Host = lists:last(binary:split(atom_to_binary(Node), <<"@">>)),
    [Bare | _Domain] = binary:split(Host, <<".">>),
    name({ok, Bare}, Node);
name({ok, Name}, _Node) when is_list(Name); is_binary(Name) ->
    case unicode:characters_to_binary(Name) of
        Binary when is_binary(Binary), byte_size(Binary) =< ?ERX_GAP_DEVICE_NAME_MAX -> Binary;
        _Refused -> error({bad_name, Name})
    end;
name({ok, Name}, _Node) ->
    error({bad_name, Name}).

appearance(undefined) -> 0;
appearance({ok, Appearance}) when is_integer(Appearance), Appearance >= 0, Appearance =< 16#FFFF -> Appearance;
appearance({ok, Appearance}) -> error({bad_appearance, Appearance}).
