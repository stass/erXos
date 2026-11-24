%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_manifest).
-moduledoc """
What the system manifest says about packages (docs/design-packaging.md,
"The `apps` row", "Admission", "Where a package lies" and "The SDK"), read
through `erx_manifest`, the reader generated from `abi/manifest.txt`, which
checks every count, span, index and string before a field is read:

* `apps`: the `apps` row as admission reads it (`erx_app_admit:apps()`),
  or `none` when the manifest has no row and the machine takes no
  packages. Beside the row's budget and max, it holds the rows of the app
  template the row names: the facet row granted to it for the service
  named `packages_service`, the one granted to it for the service named
  `system_service`, or `none` in a manifest that holds no such service,
  for each service of the row but ble, its name,
  whether its interface is `windows`, and the facet row granted to the
  template for it, and, as `ble`, the template's ble row with the GATT
  services its `services` parameter offers, the apps row's `gatt`, or
  `none` when the row offers no ble, each an index the build packed in
  the row and the boot view checked (docs/design-packaging.md, "The
  template's rows by index");
* `reserved`: the names no app may take, those of the manifest's
  principal, domain, service and facet rows, sorted;
* `packages`: the image's packages, each its app's name, the SHA-256 of
  its header, by which the machine trusts it, and whether its start row
  is enabled, in the order the manifest packs them, which the build sorts
  by name;
* `signers`: each `signer` row's name and Ed25519 public key, in packed
  order;
* `development`: the public half of the builder's development package
  key, which the generated reader accepts in a development manifest
  alone, or `none`.

The reader reads the bytes alone, so the packer runs it, and admission
over its answer, on the host. It takes no policy decision; the package
process builds its recovery's config from this answer.
""".

-export([system_config/1, admission/1]).
-export_type([config/0, package/0, error/0]).

-include("generated/erx_abi.hrl").

-doc "A package of the image.".
-type package() :: #{name := binary(),
                     sha256 := <<_:256>>,
                     enabled := boolean()}.

-doc "What the manifest says about packages.".
-type config() :: #{apps := none | erx_app_admit:apps(),
                    reserved := [binary()],
                    packages := [package()],
                    signers := [{binary(), <<_:256>>}],
                    development := none | <<_:256>>}.

-doc "Why a manifest is refused: the generated reader's error.".
-type error() :: erx_manifest:error().

-doc "Read `Manifest`, the bytes of a system manifest, or refuse it.".
-spec system_config(binary()) -> {ok, config()} | {error, error()}.
system_config(Manifest) ->
    try
        {ok, config(Manifest)}
    catch
        throw:{?MODULE, Error} -> {error, Error}
    end.

-doc "What admission reads of a manifest (`erx_app_admit:admit/4`).".
-spec admission(config()) -> erx_app_admit:manifest().
admission(#{apps := Apps, reserved := Reserved, packages := Packages}) ->
    #{apps => Apps, reserved => Reserved,
      packages => [Name || #{name := Name} <- Packages]}.

config(Manifest) ->
    View = checked(erx_manifest:open(Manifest)),
    #{apps => apps(View, rows(View, apps)),
      reserved => lists:usort(lists:append([names(View, rows(View, Table))
                                            || Table <- [principals, domains, services, facets]])),
      packages => [package(View, Row) || Row <- rows(View, packages)],
      signers => [{name(View, Row), Key} || #{key := Key} = Row <- rows(View, signers)],
      development => development(rows(View, development_key))}.

%% The reader bounds the apps table to one row, whose services partition
%% app_services, so the services a need may name are that table's rows less the
%% ble service's: an app takes that grant only through its declaration's gatt,
%% never as a need (docs/design-packaging.md, "Admission", step 6), so a need of
%% ble finds no service here and admission refuses it. The ble service's facet
%% row is the template's ble row, which the build derives with the apps row's
%% gatt as its services parameter: its index and that set are the apps row's ble.
apps(_View, []) ->
    none;
apps(View, [#{memory := Memory, max := Max, packages_facet := Packages, system_facet := System}]) ->
    Services = list_to_tuple(rows(View, services)),
    {Needs, Ble} = lists:partition(fun({Service, _Facet}) -> need(Service) end,
                                   [{element(Index + 1, Services), Facet}
                                    || #{service := Index, facet := Facet} <- rows(View, app_services)]),
    #{memory => Memory,
      max => Max,
      packages_row => Packages,
      system_row => System,
      services => [service(View, Service, Facet) || {Service, Facet} <- Needs],
      ble => ble(View, Ble)}.

need(#{interface := Interface}) -> Interface =/= ?ERX_SERVICE_BLE.

%% The apps row names at most one ble service: the build's ble_grant names the
%% one service of the ble interface ble, and the template takes one facet of a
%% service name.
ble(_View, []) ->
    none;
ble(View, [{_Service, Facet}]) ->
    #{row => Facet, gatt => gatt(View, Facet)}.

%% The values of the facet row's services parameter: of the parameter rows its
%% parameters span names, which the reader gives, those under the ble
%% interface's key for it, each an identifier's string.
gatt(View, Facet) ->
    [checked(erx_manifest:string(View, Bytes))
     || #{key := ?ERX_SERVICE_BLE_SERVICES_KEY, bytes := Bytes}
            <- checked(erx_manifest:span(View, facets, Facet, parameters))].

service(View, #{interface := Interface} = Row, Facet) ->
    #{name => name(View, Row),
      windows => Interface =:= ?ERX_SERVICE_WINDOWS,
      row => Facet}.

package(View, #{flags := Flags, sha256 := Sha256} = Row) ->
    #{name => name(View, Row), sha256 => Sha256, enabled => Flags band ?ERX_MF_PACKAGE_ENABLED =/= 0}.

%% The reader bounds the development key's table to one row.
development([]) ->
    none;
development([#{key := Key}]) ->
    Key.

names(View, Rows) ->
    [name(View, Row) || Row <- Rows].

%% A row's name, a reference into the string table.
name(View, #{name := Reference}) ->
    checked(erx_manifest:string(View, Reference)).

rows(View, Table) ->
    lists:reverse(checked(erx_manifest:fold(View, Table, fun(Row, Acc) -> [Row | Acc] end, []))).

checked({ok, Value}) -> Value;
checked({error, Error}) -> throw({?MODULE, Error}).
