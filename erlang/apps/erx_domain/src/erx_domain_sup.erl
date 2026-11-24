%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_sup).
-moduledoc """
The domain service's supervisor (docs/design-system.md, "System services").
It has seven children. The service is one, temporary and significant, so it
is never restarted: its end, however it comes, kill included, shuts the supervisor
down, which ends the permanent application and the system domain with it,
outside an ordered end, as any fault of the system domain does. The
service's records of every domain live in its own heap, and no successor
needs them, since no domain outlives the system domain. The coordinator
of the machine's end, erx_machine, is temporary and significant too, and
ends the supervisor the same way. The machine tree's grants, erx_machine_fs,
are a permanent child supervisor.

The device service's PCIe process, erx_devices_pci, is a permanent child
started before the service, so it is registered before any PCIe domain or
holder reports; a restarted one reads every setting and holder from the
domain library again (docs/design-pcie.md, "Failure handling and restart").

Beside them runs `/dev`'s control tree, erx_devfs, a permanent child that
mounts itself at `/dev` in the system domain's namespace; it keeps no
state, so a restarted one serves the same tree.

The login service, erx_login, is a permanent child started before the
service, so it has named itself the process behind `login` (erx_facet:serve/2)
before the service mints any front end's facet (docs/design-login.md, "The
service and its facet"). A restarted one starts with an empty table: the
facets minted in front of the old one ended with it, with an atom, and each
front end takes its facet's end as its own, so the manifest restarts its
domain, which the service grants a new facet (docs/design-login.md,
"Failure handling").

The restart intensity allows as many restarts within ?PERIOD_S seconds as the
supervisor has permanent children, so a crash of each in one period restarts
that child alone (docs/design-system.md, "System services"); a restart beyond
them is a service that cannot stay up, and ends the supervisor, and so the
system domain, as the service's end does.

The principal service's one passphrase check, erx_passphrase_check, is a
permanent child; a restarted one starts with no failures counted, as a reboot
does (docs/design-login.md, "The passphrase check").
""".
-behaviour(supervisor).

-export([start_link/0, init/1]).

-define(PERIOD_S, 5).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Service = #{id => erx_domain_srv, start => {erx_domain_srv, start_link, []},
                restart => temporary, significant => true, shutdown => 5000, type => worker,
                modules => [erx_domain_srv]},
    %% The coordinator of the machine's end, a process of the domain service whose end,
    %% like the service's, shuts the supervisor down; and the machine tree's grants,
    %% named the machine service's process before the service mints any session's grant
    %% (docs/design-system.md, "A session's request").
    Coordinator = #{id => erx_machine, start => {erx_machine, start_link, []},
                    restart => temporary, significant => true, shutdown => 5000, type => worker,
                    modules => [erx_machine]},
    Machine = #{id => erx_machine_fs, start => {erx_machine_fs, start_link, []},
                restart => permanent, shutdown => infinity, type => supervisor,
                modules => [erx_fs_grants]},
    Pci = #{id => erx_devices_pci, start => {erx_devices_pci, start_link, []},
            restart => permanent, shutdown => 5000, type => worker,
            modules => [erx_devices_pci]},
    Dev = #{id => erx_devfs, start => {erx_devfs, start_link, []},
            restart => permanent, shutdown => brutal_kill, type => worker,
            modules => [erx_devfs]},
    Login = #{id => erx_login, start => {erx_login, start_link, []},
              restart => permanent, shutdown => 5000, type => worker,
              modules => [erx_login]},
    Passphrase = #{id => erx_passphrase_check, start => {erx_passphrase_check, start_link, []},
                   restart => permanent, shutdown => 5000, type => worker,
                   modules => [erx_passphrase_check]},
    Children = [Coordinator, Machine, Pci, Login, Service, Dev, Passphrase],
    Permanent = length([Child || Child <- Children, maps:get(restart, Child, permanent) =:= permanent]),
    {ok, {#{strategy => one_for_one, auto_shutdown => any_significant,
            intensity => Permanent, period => ?PERIOD_S},
          Children}}.
