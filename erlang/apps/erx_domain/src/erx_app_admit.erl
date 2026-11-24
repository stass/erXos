%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_app_admit).
-moduledoc """
Admission of an app package (docs/design-packaging.md, "Admission"):
whether a package whose header the file check accepted and authenticated
may become an app of this machine, and with what. `admit/4` is a pure
function of that header with the signer the file check named, the facts of
the manifest it reads, the boot's registry of app principals and the GATT
services the admitted packages hold, and the first of its eight checks that
fails is the answer, each check a function of the same name:

1. `check_apps`: the manifest has an `apps` row;
2. `check_built_for_image`: the header's ABI version and architecture are
   the image's, which are `ERX_ABI_VERSION` and `ERX_ARCH_MACHINE_ARCH`,
   the name of the `abi/arch/` file the build was generated from;
3. `check_name`: the name is an app name, property 5's reservation rule
   (docs/design-system.md, "Identifiers") applied to it;
4. `check_entry`: a name the registry holds keeps its entry, for its own
   signer only, and a new name takes the lowest entry the registry does
   not hold;
5. `check_memory`: the declared memory is a whole number of pages, at
   least `ERX_APP_MEMORY_MIN` and at most the `apps` row's budget, so the
   domain library's plan of the app's session, which refuses memory that
   is not page-aligned, never meets one admission let in;
6. `check_needs`: each need is a service of the `apps` row other than
   ble, which only the declaration's gatt takes;
7. `check_gatt_offered`: each GATT service the declaration names, taken
   as a set, is one the template's ble row offers;
8. `check_gatt_free`: no such service is held by the admitted package of
   another app; the app's own name is left out, so an update keeps the
   services its package held.

Nothing else is judged: a declaration can only name what the row offers,
so the build's proof over the row is the proof over the app. Step 8 is
the one judgment that depends on other apps, and its input is the package
process's own record of what it admitted (PK13), not the registry, whose
entries outlive a removal. Admission
reserves nothing and writes nothing; the package process registers the
principal when the package is committed.
""".

-export([admit/4, entry/4]).
-export_type([manifest/0, apps/0, service/0, ble/0,
              registry/0, held/0, admitted/0, reason/0]).

-include("generated/erx_abi.hrl").

-doc """
A service of the `apps` row: its name, whether it is a `windows` service,
and the index of the app template's facet row that grants it.
""".
-type service() :: #{name := binary(),
                     windows := boolean(),
                     row := non_neg_integer()}.

-doc """
The app template's `ble` row and a set of GATT services, sorted: in the
`apps` row, the services the row offers, the row's `services` parameter; in
an admitted package, the services its declaration names, to which its
sessions' grant of the row is narrowed (erx_domain_core:app_session/4).
""".
-type ble() :: #{row := non_neg_integer(), gatt := [binary()]}.

-doc """
The `apps` row: the budget all apps share, how many apps a boot holds, the
index of the app template's `packages` row and of its `system` row, the
services an app may need, and the template's `ble` row, `none` when the row
offers no ble.
""".
-type apps() :: #{memory := pos_integer(),
                  max := pos_integer(),
                  packages_row := non_neg_integer(),
                  system_row := non_neg_integer(),
                  services := [service()],
                  ble := none | ble()}.

-doc """
What admission reads of the manifest: its `apps` row, or `none` when it has
none; the names no app may take, those of its principals, configured
domains, services and facet rows; and the names of the image's packages.
""".
-type manifest() :: #{apps := none | apps(),
                      reserved := [binary()],
                      packages := [binary()]}.

-doc "The boot's app principals: each name's entry and signer.".
-type registry() :: #{binary() => #{entry := non_neg_integer(),
                                    signer := erx_pkg_header:authenticator()}}.

-doc """
The GATT services each admitted package holds, by its app's name: the
package process's record of the admissions it has committed, without a
package it removed, refused or replaced.
""".
-type held() :: #{binary() => [binary()]}.

-doc """
What an admitted package holds: the indices of the app template's facet
rows its session keeps whole, the `packages` row, the `system` row where the
manifest has one, and one row for each need, ascending; the `ble` row with
the GATT services its declaration names, `none` when it names none; its
start row's display, its one `windows` need if it has
exactly one and `none` otherwise; its declared memory, which its sessions'
own budgets hold; and the signer the file check named, which registration
records in the registry for `check_entry` to compare. It holds no entry:
registration takes the one `entry/4` gives the name then, the one
`check_entry` found, since only the package process registers and it
admits and registers one package at a time.
""".
-type admitted() :: #{rows := [non_neg_integer()],
                      ble := none | ble(),
                      display := none | binary(),
                      memory := pos_integer(),
                      signer := erx_pkg_header:authenticator()}.

-doc "Why a package is refused, each tag refused by one check of the eight.".
-type reason() :: no_apps
                | {abi, Have :: non_neg_integer(), Want :: non_neg_integer()}
                | {arch, Have :: binary(), Want :: binary()}
                | {bad_name, binary()}
                | {name_taken, binary()}
                | {signer_changed, binary()}
                | apps_full
                | {memory, non_neg_integer()}
                | {not_offered, binary()}
                | {gatt_not_offered, binary()}
                | {gatt_taken, binary(), Other :: binary()}.

-doc """
Admit `Checked`, the file check's answer, against `Manifest`, `Registry`
and `Held`, or refuse it with the first check that fails. Of `Checked` it
reads the decoded header and the signer.
""".
-spec admit(erx_pkg_header:checked(), manifest(), registry(), held()) ->
    {ok, admitted()} | {error, reason()}.
admit(Checked, Manifest, Registry, Held) ->
    try
        {ok, admitted(Checked, Manifest, Registry, Held)}
    catch
        throw:{?MODULE, Reason} -> {error, Reason}
    end.

%% The header's reader cannot refuse a repeated name, so a crafted header may
%% name a GATT service twice; its gatt is taken as a set.
admitted(#{header := #{name := Name, memory := Memory, needs := Needs, gatt := Declared} = Header,
           signer := Signer},
         #{apps := AppsRow} = Manifest, Registry, Held) ->
    #{memory := Budget, max := Max, packages_row := PackagesRow, system_row := SystemRow,
      services := Offered, ble := Ble} = check_apps(AppsRow),
    Gatt = lists:usort(Declared),
    check_built_for_image(Header),
    check_name(Name, Signer, Manifest),
    check_entry(Name, Signer, Max, Registry),
    check_memory(Memory, Budget),
    Kept = check_needs(Needs, Offered),
    check_gatt_offered(Gatt, Ble),
    check_gatt_free(Gatt, maps:remove(Name, Held)),
    #{rows => lists:sort([PackagesRow, SystemRow | [Row || #{row := Row} <- Kept]]),
      ble => admitted_ble(Gatt, Ble),
      display => display([Service || #{name := Service,
                                       windows := true} <- Kept]),
      memory => Memory,
      signer => Signer}.

check_apps(none) -> refuse(no_apps);
check_apps(#{} = Apps) -> Apps.

check_built_for_image(#{abi_version := Abi, arch := Arch}) ->
    require(Abi =:= ?ERX_ABI_VERSION, {abi, Abi, ?ERX_ABI_VERSION}),
    require(Arch =:= ?ERX_ARCH_MACHINE_ARCH_BYTES,
            {arch, Arch, ?ERX_ARCH_MACHINE_ARCH_BYTES}).

%% An app name is an identifier that stays one with `_` and the digits of
%% the names quota every principal has appended, so every session name it
%% takes is one; is none that session naming keeps (property 5): not root,
%% whose session names are the system principal's, and not of a session
%% name's form, so it is no principal's session name; and is no name of the
%% manifest, nor, for an installed package, of a package of the image.
check_name(Name, Signer, #{reserved := Reserved, packages := ImagePackages}) ->
    Suffix = integer_to_binary(erx_domain_core:names_quota()),
    require(is_identifier(<<Name/binary, $_, Suffix/binary>>)
            andalso not erx_domain_core:session_reserved(Name),
            {bad_name, Name}),
    Taken = case Signer of
                image -> Reserved;
                _ -> Reserved ++ ImagePackages
            end,
    require(not lists:member(Name, Taken), {name_taken, Name}).

is_identifier(Bin) ->
    case erx_ident:new(Bin) of
        {error, bad_identifier} -> false;
        _ -> true
    end.

check_entry(Name, Signer, Max, Registry) ->
    case entry(Name, Signer, Max, Registry) of
        {ok, _Entry} -> ok;
        {error, Reason} -> refuse(Reason)
    end.

-doc """
The entry of `Max` that `Name`, signed by `Signer`, takes in `Registry`: a
name the registry holds keeps its entry, for its own signer only, and a new
name takes the lowest entry no name holds. Admission refuses by it, and
registration (`erx_principal:register/2`) takes the entry it gives.
""".
-spec entry(binary(), erx_pkg_header:authenticator(), non_neg_integer(), registry()) ->
    {ok, non_neg_integer()} | {error, {signer_changed, binary()} | apps_full}.
entry(Name, Signer, Max, Registry) ->
    case Registry of
        #{Name := #{entry := Entry, signer := Signer}} ->
            {ok, Entry};
        #{Name := _} ->
            {error, {signer_changed, Name}};
        #{} ->
            Held = [Entry || #{entry := Entry} <- maps:values(Registry)],
            case lists:seq(0, Max - 1) -- Held of
                [Free | _] -> {ok, Free};
                [] -> {error, apps_full}
            end
    end.

check_memory(Memory, Budget) ->
    require(Memory rem ?ERX_PAGE_SIZE =:= 0 andalso
                Memory >= ?ERX_APP_MEMORY_MIN andalso Memory =< Budget,
            {memory, Memory}).

%% The service of each need, once each; a need the row lacks is refused.
check_needs(Needs, Offered) ->
    lists:usort([offered(Need, Offered) || Need <- Needs]).

offered(Need, Offered) ->
    case [Service || #{name := Name} = Service <- Offered, Name =:= Need] of
        [Service] -> Service;
        [] -> refuse({not_offered, Need})
    end.

%% Each GATT service is one the template's ble row offers; a row without ble
%% offers none.
check_gatt_offered(Gatt, Ble) ->
    Offered = case Ble of
                  none -> [];
                  #{gatt := Services} -> Services
              end,
    case Gatt -- Offered of
        [] -> ok;
        [Service | _] -> refuse({gatt_not_offered, Service})
    end.

%% No GATT service is held by another app's admitted package, the first
%% service of Gatt another app holds naming that app.
check_gatt_free(Gatt, Others) ->
    Holders = #{Service => Other || Other := Services <- Others, Service <- Services},
    case [Service || Service <- Gatt, is_map_key(Service, Holders)] of
        [] -> ok;
        [Service | _] -> refuse({gatt_taken, Service, map_get(Service, Holders)})
    end.

%% The ble row with the services admitted, for a declaration that names any,
%% which check_gatt_offered found the row to offer.
admitted_ble([], _Ble) -> none;
admitted_ble(Gatt, #{row := Row}) -> #{row => Row, gatt => Gatt}.

display([Display]) -> Display;
display(_) -> none.

require(true, _Reason) -> ok;
require(false, Reason) -> refuse(Reason).

-spec refuse(reason()) -> no_return().
refuse(Reason) ->
    throw({?MODULE, Reason}).
