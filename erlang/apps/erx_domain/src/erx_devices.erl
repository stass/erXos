%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_devices).
-moduledoc """
The device catalogue as the system domain presents it (docs/design-system.md,
"Devices"): what `/dev` and the inspector read. It bears no authority. The
domain library's boot view (liberx/system/dom_boot_view.c) builds the
catalogue from the system manifest's placed devices, validates their
placement and gives each device as part of its holder's creation, so this
module validates nothing the view has not, keeps no state and gives nothing:
it hands on the view's catalogue, in the manifest's device order, unchanged.
""".

-export([catalogue/0, catalogue/1]).

-doc """
The catalogue, from the domain library, or the library's error where the
system domain has none.
""".
-spec catalogue() -> {ok, [erx_domain_lib:device()]} | erx_domain_lib:error().
catalogue() ->
    catalogue(fun erx_domain_lib:devices/0).

-doc """
The catalogue Devices() answers, unchanged: Devices is erx_domain_lib:devices/0,
or a stand-in for tests.
""".
-spec catalogue(fun(() -> {ok, [erx_domain_lib:device()]} | erx_domain_lib:error())) ->
    {ok, [erx_domain_lib:device()]} | erx_domain_lib:error().
catalogue(Devices) when is_function(Devices, 0) ->
    Devices().
