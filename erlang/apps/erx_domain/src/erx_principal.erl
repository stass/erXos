%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_principal).
-moduledoc """
The principal service's app half (docs/design-packaging.md, "An app's
principal"): the boot's registry of app principals. `register_app/1`,
which only the package process calls, writes an app's record from the
package it has just committed; `app_registry/0` answers what admission
compares a package with.

The registry is a value the domain service keeps, since it starts every
session and names each from its principal: the functions below it are pure
and the two calls are the edge. Its bounds are the domain library's: an
app principal is the library's app entry, one of the `max` the apps row
holds, numbered for the whole boot (`erx_dom_apps_place`), so a record is
keyed by its name and holds its entry. An entry is never freed within a
boot: there is no unregister, and a name keeps its entry and signer until
the machine reboots, so the names and entries the registry holds stay
within `max` (PK9). A record holds six things and nothing else: the
app's entry; its signer; its declared memory, which each of its sessions'
own budgets holds; the indices of the app template's facet rows its
admission kept, which each of its sessions is granted whole; the `ble` row
with the GATT services its admission gave it, to which each session's grant
of that row is narrowed (PK13), or `none`
(erx_domain_core:app_session/4); and the app's record (erx:app_record/0)
each of its sessions is sent once its namespace is in place, the place of
its package's file, its header's layout and what it starts
(docs/design-packaging.md, "An app's session"), taken
from the same committed package, so the record and the rows cannot come
from two packages. An app principal has no credentials, so no login
starts a session of one (AP2).
""".

-export([register_app/1, app_registry/0]).
-export([new/1, register/2, registry/1, app/2, fetch_name/2]).
-export_type([apps/0, app/0, reason/0]).

-doc "An app principal's record.".
-type app() :: #{entry := non_neg_integer(),
                 signer := erx_pkg_header:authenticator(),
                 memory := pos_integer(),
                 rows := [non_neg_integer()],
                 ble := none | erx_app_admit:ble(),
                 app := erx:app_record()}.

-doc """
The boot's app principals: `max`, the apps row's, and each registered
name's record.
""".
-opaque apps() :: #{max := non_neg_integer(),
                    names := #{binary() => app()}}.

-doc """
Why a registration is refused: `erx_app_admit:entry/4`'s refusal, every
entry held (none without an apps row, whose `max` is 0) or the name
registered under another signer. Admission refuses by the same rule
before the package is committed, so the package process meets neither.
""".
-type reason() :: apps_full | {signer_changed, binary()}.

-doc """
Register the app of `Package`, the package just committed, in one step:
the signer, the declared memory and the kept rows of its admission, the
entry `erx_app_admit:entry/4` gives the name, and of its place and
checked header the app's record.
""".
-spec register_app(erx_pkg_plan:published()) -> ok | {error, reason()}.
register_app(Package) ->
    gen_server:call(erx_domain_srv, {register_app, Package}, infinity).

-doc "The registry admission reads: each registered name's entry and signer.".
-spec app_registry() -> erx_app_admit:registry().
app_registry() ->
    gen_server:call(erx_domain_srv, app_registry, infinity).

-doc "An empty registry of `Max` entries, the apps row's `max`, 0 without the row.".
-spec new(non_neg_integer()) -> apps().
new(Max) when is_integer(Max), Max >= 0 ->
    #{max => Max, names => #{}}.

-doc """
`Apps` with the record of `Package`'s app: the signer, memory, rows and ble of
its admission and the app's record of its place and header, with whether
its program has a window, which it has when the admission kept a
`windows` service (docs/design-packaging.md, "Starting an app"), written in
the entry `erx_app_admit:entry/4` gives the name, the one admission
found: a name not yet registered takes the lowest entry no name holds,
and a registered one writes its record again in its own entry, with its
own signer only.
""".
-spec register(erx_pkg_plan:published(), apps()) -> {ok, apps()} | {error, reason()}.
register(#{name := Name, place := Place, checked := #{header := #{layout := Layout, start := Start}},
           admitted := #{signer := Signer, memory := Memory, rows := Rows, ble := Ble, display := Display}},
         #{max := Max, names := Names} = Apps) ->
    case erx_app_admit:entry(Name, Signer, Max, registry(Apps)) of
        {ok, Entry} ->
            App = #{place => place(Place, Name), layout => Layout, start => Start,
                    window => Display =/= none},
            Record = #{entry => Entry, signer => Signer, memory => Memory, rows => Rows, ble => Ble,
                       app => App},
            {ok, Apps#{names := Names#{Name => Record}}};
        {error, _} = Refused ->
            Refused
    end.

%% Where a package's file lies (docs/design-packaging.md, "Where a package lies"), as
%% the facet of the app template that reaches it and the names below that facet's
%% tree: an installed one at the root of the `packages` grant, rooted at installed/,
%% and one of the image at the root of the `system` grant, rooted at the system
%% partition's apps/ (erx_storage_system). erx_ns's process walks them on that facet's
%% grant for the session's mount of /app.
place(system, Name) -> {system, [<<Name/binary, ".app">>]};
place(installed, Name) -> {packages, [<<Name/binary, ".app">>]}.

-doc "What admission compares a package with: each name's entry and signer.".
-spec registry(apps()) -> erx_app_admit:registry().
registry(#{names := Names}) ->
    #{Name => maps:with([entry, signer], Record) || Name := Record <- Names}.

-doc """
`Name`'s record, or `error` for a name not registered in this boot: what
the start of an app's session reads.
""".
-spec app(binary(), apps()) -> {ok, app()} | error.
app(Name, #{names := Names}) ->
    maps:find(Name, Names).

-doc """
The name of the app registered in entry `Entry`; it raises for an entry no
name holds, which no domain lives under, since only a registered app's
session runs under an app entry.
""".
-spec fetch_name(non_neg_integer(), apps()) -> binary().
fetch_name(Entry, #{names := Names}) ->
    [Name] = [Name || Name := #{entry := E} <- Names, E =:= Entry],
    Name.
