%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_facets).
-moduledoc """
The facets the code of a domain acts with, by name, each the value its
holder hands the service behind it (docs/design-live.md, "Scopes";
docs/design-shell.md, "Interfaces"): the command shell's session facets,
which its commands get in their context, and the scope erx:i/0,1
inspects with. domain/0 reads which domain this is and what it was
handed; facets/2 is the pure decision.
""".

-export([domain/0, facets/2]).

-export_type([facets/0]).

-type facets() :: #{inspect := erx_inspector:scope(), atom() => term()}.

-doc """
The facets of the domain this runtime is: facets/2 for the domain its
boot page names (erx_dist:boot/0), with the facets it was handed
(erx:caps/0). The system domain is the one with the system domain's id
and no system connection; a runtime with only one of the two is another
domain, so a misread boot page never widens a domain to the system
domain's facets. A runtime that is not erXos's, as on a development
host, is one trusted runtime and gets the system domain's.
""".
-spec domain() -> facets().
domain() ->
    case erlang:system_info(os_type) of
        {unix, erxos} ->
            System = erx_kernel_records:system_domain(),
            case erx_dist:boot() of
                {System, none} -> facets(system, #{});
                {Id, _SystemConnection} -> facets({domain, Id}, erx:caps())
            end;
        _ ->
            facets(system, #{})
    end.

-doc """
A domain's facets from what it is and what it was handed. The system
domain is handed none. It holds the inspect facet of scope `all`, and
`net` with the value `local`: the network stack runs in the system
domain (docs/design-stopgap.md), so the facet is the domain's own,
reached through the stack's own modules. Every facet a command of the
command shell declares is in this map, so the system shell refuses
none. Any other domain holds the facets it was handed, each a pid, and
the inspect facet of the local scope `[Id]`, its own; a handed facet
named `inspect` never replaces it, so nothing the domain was handed
widens its scope.
""".
-spec facets(system | {domain, pos_integer()}, #{atom() => pid()}) -> facets().
facets(system, _Held) ->
    #{inspect => all, net => local};
facets({domain, Id}, Held) when is_map(Held) ->
    Held#{inspect => [Id]}.
