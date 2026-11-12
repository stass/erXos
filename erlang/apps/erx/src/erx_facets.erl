%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_facets).
-moduledoc """
What the code of a domain acts with (docs/design-live.md, "The inspect
service"; docs/design-shell.md, "Interfaces"): domain/0 is the facets the
domain was handed, by name, which the command shell gives its commands in
their context, and system/0 whether this runtime is the system domain's,
the one runtime whose inspector queries run in a local query worker
rather than through an inspect facet. No scope is decided here: an
inspect facet's scope is the one the system domain fixed when it minted
the facet.
""".

-export([domain/0, system/0]).

-export_type([facets/0]).

-type facets() :: #{atom() => pid()}.

-doc """
The facets this domain was handed (erx:caps/0). The system domain is
handed none.
""".
-spec domain() -> facets().
domain() ->
    erx:caps().

-doc """
Whether this runtime is the system domain's: on erXos, the one whose boot
page (erx_dist:boot/0) names the system domain's id and no system
connection, so a runtime with only one of the two, a misread boot page,
is another domain and never reaches the inspector without a facet. A
runtime that is not erXos's, as on a development host, is one trusted
runtime standing for the system domain.
""".
-spec system() -> boolean().
system() ->
    case erlang:system_info(os_type) of
        {unix, erxos} -> erx_dist:boot() =:= {erx_kernel_records:system_domain(), none};
        _ -> true
    end.
