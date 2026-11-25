# TODO: Apps and the start service

Open work on applications and packages, the demo apps. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Major initiatives

* [Medium] apps, an app's own tree ([design-app-trees.md](design-app-trees.md)): build `/svc/NAME`:
  `erx_svc` (the SDK's tree server and mint, started before a session's ready report when its template or
  package declares `serves svc`), `erx_svc_status` (format and parser, with its fuzz target) and
  `erx_svc_client` (reads and commands at `svc_wait_max`, with the chokepoint source check); the `serves` field
  in `abi/manifest.txt`'s session template and `abi/formats/package.txt`'s declaration, and admission
  carrying the declaration's `serves` in `erx_app_admit`'s `Admitted` to the registry entry, for the
  session's plan ([design-packaging.md](design-packaging.md#admission)); the manifest
  check refusing a facet row of `svc`; the limits `svc_wait_max`, `svc_status_max` and `svc_ctl_max` in
  `abi/services/files.txt`; the domain service's session providers (a keeper's `Start` with `row`, the plan's `serves=svc`) and derived `svc` grants, with their connections counted by the manifest check
  ([design-system.md](design-system.md#facets-a-configured-domain-serves)); the namespace's
  `{facets, svc}` provider, under which the resolver follows no link (`eacces`) and a program's listing
  leaves out every facet of the `windows` interface, as `erx_facets:program_table/1` does for its paths
  ([design-files.md](design-files.md#narrowing-for-a-program)), the `/svc` point in
  `erx_ns`'s table and an empty `/svc` in the release slice; `service NAME status` showing the app's words;
  ntpd serving `/svc/ntpd/status` and `ntpctl -s` reading it; and deleting the `ntp` kind, its path and the
  types `ntp_servers`, `ntp_last` and `net_addresses` from `abi/inspection.txt` (ntpd's denied-address bound
  becomes `erx_ntp_core`'s own), `erx_ntp_records`, the inspector's `[ntp]` clause, with the schema
  generator's check that a `runtime`-reported kind sits only under a domain or process id. The tests are the
  design's Verification list, each with its seeded fault. `service NAME CMD` lands with the first app whose
  tree has a `ctl`, since ntpd's has none; the administrator's documentation says that `cat` of an app's file
  shows its bytes unescaped.
* [Low] apps, `service` ([design-apps.md](design-apps.md#interfaces)): rc.subr's `enabled`, `rcvar`, `describe`, `delete` and `poll`, and the `fast`, `force` and `quiet` forms of every verb, are refused with the usage line, so a script testing `service NAME enabled` reads every row as disabled; offer them from `/etc/start.conf` as FreeBSD does (`libexec/rc/rc.subr:1094-1126`, 1176, 1188-1191).
* [High] apps, [design-packaging.md](design-packaging.md): the design is reviewed and Track A's part 2,
  packages added to an image, is built; part 3, installing at run time, is not
  ([plan.md](plan.md#track-a-apps)). In the design an app names its needs, memory and code, and one `apps` row bounds
  every app; each app is a plain file, `/apps/NAME.app`, the image's read-only; installing is `cp
  NAME.app /apps/`, whose close checks, admits and publishes the package by one rename, a copy over an
  installed app updates it the same way, the old one running until the new one passes and then stopped until
  its own `service NAME start` or `restart` or the next boot, since no publication applies `rc.conf`, `rm` removes it,
  keeping its data, which is named by app and signer, and `mount /apps/NAME.app DIR` shows its image
  read-only; each app is a principal of its own, its budget a wall carved from the `apps` budget at each
  session's start and destroyed at that session's retire, as design-kernel.md and design-system.md record.
* [High] apps, the manifest check's property 19
  ([design-packaging.md](design-packaging.md#the-builds-check)), `tools/lib/erx/manifest.rb`: the
  manifest check reads the `apps`, `package` and `signer` rows, derives the app template
  (`DomainStartup::APP_TEMPLATE`, of the `limits session` record), the `packages` rows and the template's row
  of each service of the row, packs the template and its rows as indices that the boot view checks, and
  checks clauses 1, 3, 6 and 7's `tree apps`. QEMU virt's development manifest carries an `apps` row and the
  site and narrow manifests leave it out. What remains, each with its seeded violation: the `apps` rows of
  the `apps` service, and clause 7's refusal of a source facet naming it, which wait for that service;
  clause 4, which needs `app_memory_default` for property 12's planner; the rest of clause 5: the enabled
  packages' session outer budgets in the `apps` budget sum, an enabled row meeting property 17's display
  and planning clauses, and admission on the host (`erx_app_admit:admit/4` on the packed manifest);
  clause 1's inspect scope; clause 2's counts in the principal table, the session-name atoms and each
  server's connections, which the Phase 1 manifest check sums for no principal (QEMU virt's manifest reckons the
  storage, network and display domains' connection quotas and `max_connections` by hand, in its comments,
  and `Manifest::Edit.without_apps` repeats that reckoning; the check should sum each grant's instances
  over distinct grantee and server pairs against each server's quota and `max_connections`; the Raspberry
  Pi 4's part reckons them by hand too, and its storage and network domains keep the common rows' four
  connections for QEMU virt's four apps where the Pi's row has one).
* [Medium] apps, a files service on the `apps` row (`tools/lib/erx/manifest.rb`, `check_apps`): refused as
  unsupported until the storage service's `tree` parameter roots a grant at the app's own directory
  (`tree apps`, [design-packaging.md](design-packaging.md#where-an-apps-files-lie)); then `data`
  joins the development manifests' `services`.
* [Medium] apps, what the boot view guards of an app's authority (`liberx/system/dom_boot_view.c`,
  `boot_app_grants`): it requires the template's facet rows to be exactly the rows the `apps` row names,
  each once, but not what the `apps` row itself grants: a manifest the check did not pack could name
  `start`, `apps` or `etc` among `app_services` (refused by `app_services_refused` in
  `tools/lib/erx/manifest.rb`), an inspect or files service, parameters on the derived rows (`tree`, an
  inspect scope, `rights rw` on packages) or inflated quantities, and every app's session would hold them.
  Decide whether app authority is the build check's alone (property 19; design-system.md trusts the image
  once the boot validator checked it), and then say so in design-packaging.md, or the view's too; then
  the by-construction answer is that the manifest packs no template facet rows and the view derives them
  from the `apps` row (packages `ro`, each service with its derived quantities), which needs the
  parameter and quantity derivation the packer does today, and a generated name for the files `rights`
  parameter (the header names only its members, `ERX_FILES_RIGHTS_RO`).
* [Medium] apps, the app template is identified five ways: the packed `apps[].app_template`, which only
  `boot_apps` reads and requires to equal its own rule (the last template, naming no principal),
  `app_template?` and `sessions.size - 1` in `tools/lib/erx/manifest.rb`, and erx_starter's
  `=/= ?ERX_MF_NONE`. Either drop the field and keep the rule, or make the index the one source.
* [Medium] apps, whether an interface may go to apps rests on its `quantity` lines
  (`abi/services/net.txt`, `derived_quantities` in `tools/lib/erx/manifest.rb`): netadmin is kept off the
  `apps` row only because it declares no quantity, so adding them would let apps administer the network.
  Make grantability an explicit fact (a mark on the interface the check reads, or a refusal by interface
  beside inspect and files) and require quantities only of grantable interfaces.
* [Low] apps, the derivation's readability (`tools/lib/erx/manifest.rb`): `app_template` rebuilds the
  session row and SPACES check `normalize_sessions` writes (one `session_row` for both); `named_artifact`
  duplicates `artifact`'s kind check; `derived_facets` maps positional triples where a small `Data` value
  would read better; `apps_rows` searches the sorted facets for rows `normalize_facets` just placed; the
  `tree apps` refusal in `check_apps` runs with no apps row and is redundant while files declares no
  `tree`; dom_planner_test's apps case hand-codes header offsets the codec can give.
* [High] apps, the package process at boot
  ([design-packaging.md](design-packaging.md#boot-and-recovery)), `erlang/apps/erx_starter/src/erx_pkg*.erl`:
  the file check, the recovery's plan (one action per message), erx_pkg_io with its path table, one route for
  every medium answer and its bound on a read, `erx_pkg_medium` over the `packages` grant at `/packages` and
  the `system` grant's `NAME.app`, the system partition's `apps/NAME.app`
  ([docs/todo-system-partition.md](todo-system-partition.md)), and erx_pkg under erx_pkg_sup are built; the start service's supervisor starts
  erx_pkg_io (never restarted, its end resets the machine) and, given a config, erx_pkg_sup. `erx_pkg:system_config/0` builds
  the config from the manifest and the library's app entries. QEMU virt's development manifest has the
  `apps` row and the check derives the app template, so every development boot runs the package process,
  and the kiosk QEMU suite boots a production image whose system partition carries `apps/dashboard.app`,
  which the process checks, admits and starts; its altered cell's package, root hash flipped, is refused at its mount. The publication (`erx_starter:packages/2`: the set's rows after the manifest's, kept by keepers of
  `{app, Name}`, a dropped app's keepers stopped before the answer, the set kept across a restart of the table) and the
  listing's wait for the system domain's namespace are built, and the apps suite's unlisted boot checks
  `{packages,4,#{packages => #{},scan => {ok,0}}}`. What remains: a listing that still fails after the wait
  leaves the scan `unknown`, and nothing lists the installed packages again before the next lifetime (the later
  set design-packaging.md names, with no record, which `rc.conf` does not enable until the next boot); the
  `installed` state and the boot mark of a later set, which wait for the table's records (the `/etc/start/ctl`
  item below), so until then every make of the table applies `rc.conf` to the set's rows too; the
  `apps` tree serving `system/NAME.app` and `NAME.app` through erx_pkg_io; `/proc/packages` (`[packages]`
  and `[packages, Name]` in `abi/inspection.txt`) from `erx_pkg:packages/0`, the `room` attribute
  included; the system_domain QEMU cell; the log lines for a refused package and an entry of no recognized
  form; the lifetime taken from the caller rather than the request; and whether image header reads wait for
  the `packages` grant. `erx_pkg_medium` reads the whole
  directory with `file:list_dir_all/1` and keeps the first `pkg_scan_max` names, so the listing is not one
  bounded read at a time (Phase 1: the storage domain is trusted).
* [Medium] apps, the package set's publication (`erlang/apps/erx_starter/src/erx_starter.erl`,
  `publish/2`): the decision which keepers a set drops is made in the effect layer, not in
  `erx_start_table` beside `reconcile/3`. Until the boot's set arrives, rc.conf's lines for apps are
  logged as `{undeclared, App}` and shown as skipped.
* [Medium] apps, chokepoints (`tools/lib/erx/chokepoint_rules/apps.rb`): `starter-reach` covers the start
  table and its keepers, not packaging's `erx_pkg*`, and design-packaging.md's own checks are not built:
  that `erx_pkg` and `erx_pkg_io` call no `erx_domain:stop/2`, and that only `erx_pkg` calls
  `erx_principal:register_app/1` and `erx_starter:packages/2` (docs/design-packaging.md, "Verification and testing"). Add a `pkg-reach` rule
  allowing `erx_domain:system_namespace/0` and `erx_domain_lib:apps/0`, and a publishers rule.
* [High] apps, the start of an app's session (`erx_domain:start_app/2`, `erx_domain_srv`): its host test
  `erx_domain_mints_srv_tests:app_session/0` is written and not run: in its fixture the start is answered
  before the kept row is installed, because configured domain `a` ends after its introduction to the
  session, for a reason not yet found. Also open: the pixel area of an app session's pairs is still the
  app template's (`erx_domain_mints:pair_area/3` by template), to be decided from the session's rows.
* [High] apps, an app's session ([design-packaging.md](design-packaging.md#an-apps-session)): `erx_app`,
  the `app` script, the boot view's app entries (the check derives the app template from the `apps` row, so
  QEMU virt's development image boots with four app entries, `erx_domain_lib:apps/0`'s max 4 at the
  system's Erlang shell under HVF), the session's plan (`erx_domain_core:app_session/4`, with its host test
  and seeded faults), the library's entry (`erx_domain_lib:app_session/6` over `erx_dom_lib_app_session`)
  and the domain service's start (`erx_domain:start_app/2`, which sends the app's record as
  `{Ref, app, App}` once the session's namespace is in place), and the start service's package rows
  (`erx_starter:packages/2`) with their keepers, the only starters of an app's sessions (PK7), exist. What
  remains: the app principal's CPU group under an apps group, which Fiasco's flat groups leave out; a `tree
  apps` grant's root `apps/NAME/SIGNER/`, whose signer is the registry record's and outside the plan, so
  the plan's PK10 comparison does not cover it; the rest of the file-backed EROFS mount of
  [todo-system-partition.md](todo-system-partition.md), whose `{erofs, app}` source `erx_app`
  mounts `/app` with. A native app's start is built in `erx_app` (`/app/` and the header's `program`, a
  `relative_path` the reader checks, through `erx_prog_handler:start/1` with the record's `window` on the
  session's default display, the program's end ending the session); see the next item for what it waits on.
* [Medium] apps, `erx_app`, a native app's standard streams: design-packaging.md ("Starting an app") starts a
  program without a window with standard input null and its output to the session's log, but
  `erx_prog_handler:start/1` offers only pipe ends and a window's buffer as descriptors, so `erx_app` starts
  every program with descriptors 0 to 2 closed. Needs a null descriptor and one for the session's log in the
  handler's spec.
* [Medium] apps, the start of an app's session (`erx_domain:start_app/2`, `erx_domain_srv`):
  an image package's place on the `system` grant is written in `erx_principal:place/2` and again in
  `erx_pkg_medium` (`place/2`, `on_system/1`, the grant tuple itself is `erx_facets:file_grant/2`'s alone); the
  `app-starters` chokepoint repeats `start-callers`' call forms; `start_app/2` lets a console
  facet through to the planner; a record can be sent when the `packages` grant failed (fails safe at the mount);
  a keeper's stop waits without bound for its session's end.
* [Low] apps, `erx_starter_keeper`: a session that ends before its keeper takes it ends the keeper with
  `noproc`, the exit its trapped link brings, so the supervisor reports a crash naming no session where
  `{shutdown, {ended, Id}}` is meant; `hold/2` can map it, with an `erx_starter_tests` case for the path.
* [Medium] apps, the domain library (`liberx/system/dom_core.c`, `dom_plan_in`): a request's plan
  (`erx_dom_plan_request`, `erx_domain_lib:create/1`) under an app entry's principal is not refused, so
  a domain that is not the app template can take the entry's one domain slot, against "neither entry
  can pair an app principal with another template" ([design-packaging.md](design-packaging.md#an-apps-session)).
  Nothing calls `create/1` with one today. Fix by construction in `dom_plan_in`: an app principal
  exactly when the origin is a session of the app template, with a dom_core test that plans a
  request under an app principal and expects `ERX_EINVAL`.
* [High] apps, an app principal's wall on both kernels (`liberx/system/dom_boot.c`, `erx_domain_core.erl`):
  the domain library carves each app principal's budget at boot as an elastic budget with no guarantee, which
  Fiasco makes a wall of nothing. Carve none at boot; the domain service carves the principal's wall from
  `apps` at each session's start, at the declared memory plus the session's outer budget, and destroys it
  once that session has retired, with the tests of
  [design-packaging.md](design-packaging.md#verification-and-testing) of the principal's wall. The
  same file creates the `apps` budget and every manifest principal's budget with kind `ERX_BUDGET_ELASTIC` and
  the guarantee equal to the cap, where the design makes each a wall, `ERX_BUDGET_WALL`.

## Stopgap replacements

* [High] [design-apps.md](design-apps.md): the code the design asks for, in the order
  [Track A](plan.md#track-a-apps) builds it. Built: the `start` rows and property 17's structural clauses and
  its planning clause (root's console session and each enabled row's session planned by the domain library beside
  the configured domains);
  `erx_start_table` (`merge/3`, `rc.conf`'s and `ctl`'s parsers with their fuzz targets, `set/3`, the command check
  `apply_ctl/4`); `erx_starter` with its table, a supervisor and keeper per enabled row, and `rc.conf` read and
  written at `/data/etc/rc.conf`; the start service's tree, `start` (`erx_starter_fs`), holding `ctl` alone,
  which a session mounts at `/etc/start`;
  `erx_domain:start_session/2` with `display` and `default_display`, and the session mark; a row that names a
  written under `/data`; the `apps` tree (`erx_starter_fs`), which a session mounts at `/apps`;
  `erx_domain:start_session/2` with `display` and `default_display`, and the session mark; the session's default
  display, the display its start names or the one its template is granted, set as its `display` variable when
  the session is planned; a row that names a
  display started once that display's server has settled (`erx_domain:server_settled/1`).
  Not built: the reset count cleared by the first kept session; and start flags (design-apps.md,
  "Start flags"): `limit start_flags_max u32 1024` in `abi/manifest.txt` and a string field for the default in
  `erx_mf_start`, under a name other than `flags`, which the layout gives its `mf_start_flags` bits, with the
  packer and the manifest reader holding it to the bound; `NAME_flags` in `rc.conf`'s parser; `flags` in
  `erx_domain:start_session/2`'s `Start` and `ERX_START_FLAGS` in the session's environment; and the boot view's
  refusal of a session template whose environment sets the key, with the variable at its longest in its strings
  reserve (`boot_strings_fit` in `liberx/system/dom_boot_view.c`).
* [Medium] apps, `/etc/start.conf` and the commands of `/etc/start/ctl`
  ([design-apps.md](design-apps.md#the-start-table)). The built settings file is `/data/etc/rc.conf`
  (`erlang/apps/erx_shell/src/erx_cmd_service.erl`, `erlang/apps/erx_starter/src/erx_starter_rc.erl`), and the
  built `service NAME enable` also starts the row, which the design and FreeBSD do not. The settings move to
  `/etc/start.conf`, an ordinary file in rc.conf(5)'s assignment syntax with the fields `enable`, `display`,
  `restarts`, `restart_period_s` and `flags`, on the data partition's `etc` tree: a service directory with a
  facet `etc`, read-write to the system domain and to the templates that hold `start` (rows the build derives,
  and an entry of the facet table), mounted at `/etc`. The `etc` grant waits for grants rooted at a service
  directory; until then the file is
  `/data/etc/start.conf`, through the `data` grants of the system domain and root's session. Code to change:
  * the reader and judgement: `erx_start_conf:read/1`, the literal `sh` subset of "The file's syntax", with a
    host test against the host's `sh` and a fuzz target, replacing `parse_rc_conf/1` and `erx_rc_conf_fuzz`; a
    variable's row found from the field name that ends it, not a split at the last `_`;
    `erx_start_settings:judge/2` returning each read's problems with their lines, shown at `/proc/apps` as
    `problems`, with `start_conf`, which tells `failed` with its reason and `too_long`, in place of `rc_conf`,
    which tells only `read` and `unread` (`abi/inspection.txt`); `service -c [FILE]`, which checks row names only where `/proc/apps` lists the rows and says so elsewhere;
    `judge/2` takes row names (or `any`) and no grants: a display line is judged for its form alone, and the
    admission refuses a display the principal may not draw on;
  * names: a row's variable name is its principal's name with each `-` replaced by `_`; the manifest check
    (property 17) refuses a `start` row whose principal's name begins with a digit or whose variable name is
    another row's, and admission (`erx_app_admit:admit/4`, rule 3) an app name that does either against the
    manifest's `start` rows, the image's packages and the registry, with `{variable_taken, N, Other}`;
    problems at `/proc/apps` and `service -c` show the row's own name beside its variable;
  * commands: `ctl` gains `restart`, `onestart`, `onestop` and `onerestart`, and its `enable NAME
    [display=D] [restarts=N] [restart_period_s=S]` and `disable NAME` edit the file and start nothing; `erx_starter` reads the file before every
    command, and `erx_start_table:command/3` judges every command after the read (design-apps.md, "How a command
    is judged"), returning the answer, the action and the row's new record, replacing `apply_ctl/4`, with the
    errnos `enoent`, `enotsup`, `ealready` and `esrch`; `enable` and `disable` are carried out by the start
    service one at a time from a fresh read, with `erx_start_settings:set/3` and `erx_starter_rc`'s write
    (temporary file, sync, rename, sync again), without the `superseded` rule, and answer `eio` when the read
    fails; `erx_cmd_service` writes them to `ctl`, drops its decisions from `/proc/apps` (`plan/3` and `act/4`,
    `erlang/apps/erx_shell/src/erx_cmd_service.erl:236-290`) and answers from the write's errno, and its
    `service -e` judges `/etc/start.conf` itself with the rows' `declared_enable`;
  * applying: a command applies the file to its own row alone and the whole file applies only at boot, so
    `erx_start_table:reconcile/3`, the stopped marks, the recorded text, the restart of a running row whose
    settings changed, the comparison `erx_starter:kept/1` serves go;
    the records process holds each row's applied record and the boot mark; the display rule judges a row
    against the rows kept, so `merge/3` becomes `merge/4`; a failed read at boot starts the rows at their published
    defaults and leaves the boot mark unset until a later read applies the file, while at a command `start`, `restart`, `onestart` and `onerestart` answer `eio` and `stop` and
    `onestop` are judged on the row as last applied; the boot applies the file to the rows of the boot's
    package set when it arrives, and a later publication records the rows it adds `installed` and starts
    nothing; a restarted table reads the file only to finish a boot the mark says is not done; the keeper waits
    on `erx_domain:server_settled/1` before each start of its session; and a row runs while its kept or its
    `onestart` session stands (the A5c residual);
  * flags and limits: the start flags' byte rule excludes `"`, `\`, `$` and `` ` ``; packages declare default
    `flags` in `app.txt` and `abi/formats/package.txt`, and `erx_app` passes a native app's program the one
    environment entry `ERX_START_FLAGS` (design-packaging.md, "Starting an app"); `start_rc_conf_max` becomes `start_conf_max` in
    `abi/manifest.txt`;
  * mounts and checks: the session's and the system domain's mounts of `etc` at `/etc`; the paths
    `/data/etc/rc.conf` names in `erx_starter_rc:directory/0`, `erx_cmd_service` and the `apps` QEMU suite; the
    chokepoint that only `erx_starter_rc` writes on `etc`, and its refusal with `efbig` of an edit whose text
    would pass `start_conf_max`; property 17's clause that every writable grant of `etc` belongs to the system
    domain or to a template holding `start` ([design-system.md](design-system.md#the-manifest)); and a
    program's handler joining the session's export and its grant at `/etc` and `/dev`
    ([design-files.md](design-files.md#narrowing-for-a-program)), so a native editor reaches
    `/etc/start.conf`, and a program with a window keeps a grant the session mounts at `/dev`, which its own
    `/dev` replaces until then ([design-files.md](design-files.md#a-programs-window)); the join keeps that
    grant at its own rights, so it also decides whether a windowed start still refuses a read-only entry at
    exactly `/dev` (`erx_prog_handler_core:writes_dev/2`). This removes the A5c residuals of an `enable`
    interrupted during its write and of the stopped mark.
* [Medium] apps, `erx_starter:with_default_display/3`
  ([design-apps.md](design-apps.md#starting-a-session)): no test covers the default display the start
  service gives a row or command that names none. Add an `erx_starter_tests` case over a stub domain service
  asserting the `Start` it receives: `#{default_display => D}` for a template granted exactly one display, `#{}`
  for none or two, and the same for `start` of a row that is not enabled.
* [Low] The start table's first `rc.conf` read waits for the system domain's namespace to be in place
  (`erx_domain:system_namespace/0`), but a storage domain that ends once during boot, or misses the mint
  deadline, settles that wait as failed: the read answers an error and the manifest's enabled rows start before
  `rc.conf` is known, so a row `rc.conf` disables runs until the read succeeds. Waiting through a storage
  restart within its intensity would close it (`erlang/apps/erx_starter/src/erx_starter.erl`).
* [Low] The grants of the start service's tree, `start` (`erx_starter_fs`), end with a crash of `erx_starter_sup`
  itself, or of the tree's grants supervisor, and nothing grants a session no keeper kept (root's console session
  among them) a new one, as for every service the system domain serves.
* [Medium] The keepers' branch is a permanent child of the start service's top supervisor (`erx_starter_sup`), so
  an end of its records process (`erx_starter_records`) or of its own intensity restarts it with no records, and the
  restarted table applies `rc.conf` to every row again, starting rows no command started. The design makes the
  branch a temporary significant child of a top supervisor with `auto_shutdown => any_significant`, so that end
  ends the application and resets the machine ([design-apps.md](design-apps.md#concurrency), "Losing that
  store resets the machine"); with it the race between the branch ending its rows and the table's calls goes too.
* [Low] `start` tree review residuals (`erx_starter_fs`): each refused `ctl` write logs a line with no rate bound,
  so a session writing refused lines in a loop fills the system log; and `erx_start_table:ctl_errno/1` has a clause per refusal and no catch-all, but nothing checks it against
  `ctl_error()` (no dialyzer runs), so a new refusal without a clause ends the session's grant on its first
  write: returning the errno with the refusal from `apply_ctl/4` makes it hold by construction.
* [Medium] start service, `erlang/apps/erx_starter/src/erx_starter_fs.erl` (`start_link/1`, `call/2`): the
  tree takes a `command` fun from outside, which only its tests pass, and calls it, where
  [design-apps.md](design-apps.md#invariants) has erx_starter call nothing given to it from outside;
  the `starter-reach` chokepoint matches a variable or macro module and `apply` but not a fun value, so a
  later caller of `start_link/1` would pass the check. Drop `start_link/1` and stand in for
  `erx_starter:command/1` with a stub module in the tests, as `erx_pkg_medium` does for `erx_pkg_io`.
* [Medium] `erx_starter:manifest_table/1`, which reads the start rows, the principals and each session template's
  grants from the system manifest, has no host test over a packed manifest with a `start` row; only the `apps`
  QEMU suite (`tools/lib/erx/apps.rb`) reads one. Its grants are every service a template is granted, not only
  `windows` services, as the domain service's own check is.
* [Low] `erx_starter` review residuals (A5): no deadline on the `rc.conf` process's file operations
    (`erx_starter_rc`), so a hung storage operation queues every later command and holds a restart of the keepers'
    branch and the application's stop, which wait for the operation in progress (a deadline needs a way to cancel a rename already sent,
    such as 9P's `Tflush`); a refused start and a row going down log no line naming the row; the keepers' branch has OTP's default intensity and
    `held/0` reads `restarting` as down; the one-off keeper is a temporary child of the keepers' branch, which
    design-apps.md calls "under no supervisor"; the rescue configuration starting no row is not checked (it is not
    built).
* [Medium] Start table (`erx_starter`, `docs/plan.md` M12): the table owes the reset count, cleared by the first
  kept session, and the rescue configuration starting no row, with their tests, once M12 builds the reset count and the
  rescue configuration; Track A's exit criteria no longer carry them.
* [Medium] The start table's display key (`tools/lib/erx/chokepoint_rules/apps.rb`, start-display): the check that only
  `erx_starter` passes `display` or `default_display` to `erx_domain:start_session/2` reads the atoms in the
  calling module only, so a start map built in a helper module that never starts a session passes unseen (the
  keeper already passes a map built elsewhere). Make it hold by construction: a separate entry for a start at a
  display (`start_session/3`, or `start_display_session`) that only the keeper calls, and `start_session/2`
  refusing both keys; start-display then becomes a call-site rule like start-callers.
* [Low] `erx_starter` review residuals (A5b): the rename over rc.conf is not followed by a sync of its directory;
    the process tests make their rc.conf directories in the current directory.
* [Low] `/proc/apps` and `service` (A7) leave out what the start service's read API does not expose: a row's
  `domain` and its `ends` within the period are `unsupported`, a down row's `reason` (its session's last end) is
  `unknown`, a session `onestart` started (an `{once, Name}` keeper) shows nowhere, so `onestatus` of a row that
  is not enabled cannot say whether one runs, and `service NAME status` of a configured domain says only that it
  is configured, not its state. `erx_starter_sup:held/0` returning each keeper's session domain, its row
  supervisor's recent ends and the once keepers would fill all but the last; a configured domain's state needs the
  domain service's attributes at `[domains, Id]`. `rows/0`'s skipped rc.conf lines are not shown either. A row is
  `running` while its supervisor lives, a keeper still starting its session included, against "nothing is shown
  as running that the domain service does not list"; a failed read of the manifest shows an empty, known table and
  boot order; and no test reads `manifest_table/1`'s boot order from a packed manifest, which the QEMU
  `service -e` checkpoint checks only by its exit status.
* [Low] `erx_starter_rc:read/1` treats `enoent` as a machine with no `rc.conf`. If a storage domain that is down
  answers `enoent` under `/data` rather than another error, the boot's read finds no settings and starts each row
  at its manifest `enable` rather than at its published default, as a failed read would, and `/proc/apps` shows
  `rc_conf` as `read` rather than `failed`; and the shell's `enable` or `disable`,
  reading the same answer, would write a file of its one line over the real one if its write then succeeded,
  losing the other settings. An absent `data` grant answers `eio` (`erx_path`); check what a live but failing
  storage domain answers.

## Bugs by subsystem

* [Medium] dashboard, its slow work can start before its first frame is drawn
  (`examples/dashboard/lib/erx_dashboard/src/erx_dashboard.erl`, `erx_ui_lvgl_core`): the dashboard
  starts the quotes, the ground picture and the dial once `erx_ui:tree/2` answers, but an idle
  renderer core answers once its operations are written, before it draws, so a slow renderer can
  receive both trees before its first frame, and `erx_dashboard: shown` is logged before the frame
  is on screen. erx_ui tells an opener nothing when its window presents. The fix is a design
  question for docs/design-display.md "The widget server": a `{ui_shown, Window}` message to the
  opener on the first present, or a first `tree/2` answer that waits for it. Measure the Pi's time
  from `shown` to the first frame first; fix only if the gap is visible.
* [Medium] apps, a refused `/app` mount (`erlang/apps/erx_app/src/erx_app.erl`, `start_app/2`): in the kiosk
  suite's altered cell, whose image the verity read refuses, `erx_app` fails with `{mount, Reason}` and is
  started again about every 0.2 s for as long as the guest runs, logging each attempt. The design ends the
  session at its start with the reader's reason ([design-packaging.md](design-packaging.md), the failure
  table's "the image does not mount" row) and lets the start row's keeper restart it only within the row's
  intensity, 5 ends in 600 s by default, after which the row is `down`
  ([design-apps.md](design-apps.md)); the restarts break that bound, so either they bypass the row's
  supervisor or its intensity is not applied to this row.
* [Medium] apps, the manifest and package readers ([design-abi.md](design-abi.md#layouts-in-erlang)):
  the generated structural readers decode an enum or flags field to its integer, so their callers compare
  against `erx_abi.hrl` macros (`erlang/apps/erx/src/erx_pkg_header.erl:237`, `start/2` on
  `?ERX_PKG_ERLANG`) while `erx_abi_layout` gives the same fields as atoms and ordsets: two forms of one
  record. Fix: the structural readers decode a fixed record through `erx_abi_layout` and their callers
  match names.
* [Low] apps, `erx_pkg_header` ([design-packaging.md](design-packaging.md#the-declaration)): the
  generated reader checks the declaration's strings by the ABI's string classes, which are wider than the
  declaration's grammar: a need named twice, more than `pkg_args_max` arguments, an application name with
  `-` or a leading digit, and a program path that is not plain names under `bin/` (`/system/bin/sh`,
  `../x`) all decode. The packer refuses them on the host; the machine does not. Leaving them open is safe
  because the header is signed or hash-pinned and the program runs with the app's own grants alone. Fix:
  the ABI's reader language gains a count bound on an `args` string and string classes for an OTP
  application name and a relative path of plain names, with a seeded case each.
* [Medium] apps, the SDK (`tools/lib/erx/sdk.rb`, `tools/erx sdk export`): the export writes `SDK.txt` and
  `erlang/` (the public applications and `public.txt`), `host/erlang/ebin`, and the native half
  (`tools/lib/erx/sdk_sysroot.rb`): `sysroot/aarch64` and `share/erxos/sdk.mk`. The native half links a
  fixed-address executable at `task.ld`'s base, as the boot image's programs are, where the design's table
  names a position-independent one: 0.1 starts a package's program from its fixed link, and the move to a
  position-independent link and the loader is 0.2's.
  Not yet written: `host/bin` (`erx-app` with the Ruby it loads, `fsimg`, the host build of `erx_elf_plan` the packer plans a
  program with, which it builds from the tree into `build/app-pack-tools`, a host `erx-lvgl` and
  its descriptor-3 launcher), `erx_ui_host`, `erx-app test`, and `SDK.txt`'s minimum LLVM and `fsimg` version,
  which no source in the tree records yet (docs/design-packaging.md, "The SDK"). `erx_ui_host` takes option A
  of the advisors' review: while it runs it is the node's default display, `erx_ui:open/1` takes a window
  (size, channel, `open`, `present`) from the registered host and starts the server through start/1's path,
  `present` copies the frame before `shown`, and `renderer => erlang` answers `enotsup` until `erx_ui_erlang`
  exists; design-display.md ("The widget server", "Choosing a display") and design-packaging.md (two opens on
  one host) gain those sentences first. The design's public table names `erx_draw`, which the tree does not
  have; `sdk/public.txt` lists `erx_win` alone. Fix: build each with the next SDK packages, ahead of
  `examples/dashboard`. `host/bin/erx-app` waits on a choice: the packer's Ruby is not self-contained, since
  `Erx::AppPackage.codec` plans the whole ABI with `ABI::Generator.plan` from `abi/` at run time (about seventy
  generator files), `Erx::LineEscape` regenerates its tables through `Erx::Generated.ensure`, and `Erx::Fsimg`
  finds fsimg by the tree's build record against `deps.lock`. Recommended fix: the packer reads the generated
  host binding (`build/gen/tools/generated/abi.rb`, `tools/lib/erx/generated_abi.rb`) and the generated
  terminal tables, which the export copies, `Erx::ErofsImage` takes the fsimg path it runs, and the export
  copies `erx-app`, its handful of library files, those generated files and fsimg into `host/`; until then
  `tools/erx-app`, which finds its SDK at `../..`, runs from no SDK.
* [Medium] apps, the SDK's and the image's notices (`Erx::SdkSysroot::NOTICES`, `ProductionImage#archives`):
  both take L4Re's user libraries' notices from `Fiasco#user_library_notices`, but each states the other
  libraries' notices (musl, compiler-rt, the boot cores) itself, so that mapping exists twice; and the SDK
  copies Fiasco's archives as built, with the builder's uid and gid in their members. Fix: one attribution
  table, derived from each archive's objects, that both read and the SDK copies `lib/` from; a deterministic
  re-archive.
* [Low] apps, `tools/erx sdk export` (`tools/erx`, `Erx::SdkSysroot`): the export takes `ERX_CLANG` and
  `ERX_LLD` from the environment as given, not through `host_environment`, so it skips the minimum-LLVM
  check and the resolved `llvm-ar` beside clang that `pack` gets, and a missing linker is found only after
  the Erlang half. Fix: resolve the toolchain with `host_environment` and check it at `Sdk.new`.
* [Low] examples, the Doom fork (`examples/doom/doom`) builds with its own `run.rb` over erXos's internal
  build library and keeps `app.txt` in `app/`, where docs/design-packaging.md ("Examples") has a `Makefile`
  over the SDK's `sdk.mk` and `app.txt` at the fork's root, so `tools/erx app run examples/doom/doom` finds
  no app. Waits on the SDK (`sdk.mk`) and `tools/erx app run`; then the fork moves to the design in commits
  of its own and the gitlink is re-pinned.
* [Medium] apps, `erx-app pack` (`tools/lib/erx/app_pack.rb`): the packer
  compiles `lib/APP/src`, signs with the host's development package key by default and runs the file check, but
  does not yet run `DIR/Makefile`, with the exported SDK's `sdk.mk`, or write the build record beside
  `NAME.app` (docs/design-packaging.md, "Building and packing"). Safe meanwhile: a missing program is refused, and a prebuilt `bin/`, or the `ebin/` of an
  application without `src/`, enters the package as given, with whatever host paths a beam's compile
  information holds. Also open: the packer runs the first `erlc` on PATH without checking that it is the
  OTP release `SDK.txt` names, so a beam another release compiled fails only when the app starts; erlc's
  environment is cleared by `Oracle::CLEAN_ERLANG_ENV`'s deny-list, which misses `ERLC_EMULATOR` and
  `ERLC_USE_SERVER` (an allow-list spawn in `Erx::Runner` is the fix by construction); and a compile error
  shows only as the runner's log path. Fix: add each with the SDK package.
* [High] apps, `tools/erx pack --app` ([design-packaging.md](design-packaging.md#adding-an-app-to-an-image)):
  the command packs an app directory with the in-tree packer (`AppPack.pack` with an SDK exported into
  `build/app-sdk`), not the exported SDK's `host/bin/erx-app`, which does not exist yet (the SDK entry above);
  no build hands the public half of the builder's `Erx::PackageKey` to the manifest check as
  `Manifest::Context`'s `development_key`, so no image trusts its builder's key yet, where every development
  build, not only those `pack --app` builds, should, but for the published media, the Raspberry Pi 4's card and QEMU's medium, which trust its kiosk by hash and no key and whose build refuses a manifest that trusts one (`ProductionImage.check_published_trust`; design-packaging.md, "The shipped manifests"); the packer does not yet run the machine's manifest
  reader (`erx_pkg_manifest:system_config/1`) on the host over the packed manifest, beside
  `AppPack.describe`; and `tools/erx app run DIR`.
  Fix: each with its own package.
* [Medium] apps, package notices (`tools/lib/erx/production_image.rb`, `package_external`): a package is registered with no notice document, so an image carrying a third-party MIT or BSD package names its license in NOTICES but holds neither the license text nor its copyright line, which both licenses ask of a binary distribution. Fix: a declaration field naming the notice file in the package image, which the build cites.
* [Low] apps, packer's hash tree (`tools/lib/erx/app_package.rb`, `verity_tree`): the tree's level
  arithmetic is written twice, in the packer's Ruby and in `erx_verity_tree`; the packed-app EUnit cases
  check they agree. Fix: take the level lengths from one source when the packer runs the file check on
  the host OTP.
* [Medium] starter, `erx_starter_row:init/1` and `erx_starter_keeper`: a start-table row's
  supervisor counts its `restarts` within `restart_period_s` as OTP does, and a session boot
  that hangs ends its keeper (`{refused, timeout}`) only after the machine's boot timeout, so
  on a machine whose boot timeout is 120 s or more (the website's is 600 s) a start row of 5
  in 600 s restarts a hung session without end. Configured rows and the console's login
  count restarts after a timeout in a row until a boot reports ready
  (`erx_domain_core:intensity/4`); a start row's keeper would count the same way.
* [Low] examples, Doom on QEMU by hand (`/bin/doom`, `examples/doom/doom`; [design-packaging.md](design-packaging.md#examples)):
  no gate builds Doom, and 0.1 is published without its by-hand check: on QEMU `virt`, with a medium packed by
  `tools/erx pack --published`, `doom` typed in `rc` shows Doom's title, and a key from the virtio keyboard
  moves its menu. Run it on the next published build.
* [Low] examples, `tools/lib/erx/doom_program.rb` (`DOOM_SOURCES`): the
  Doom build lists the fork's files to compile as a copy of the fork
  `Makefile`'s `SRC_DOOM` less the X11 platform part, and its platform layer
  as `GLUE_SOURCES`, so the fork's `Makefile` and this list must change
  together. Put the list in a file of the fork, a commit on its `erxos`
  branch, that both its `Makefile` and `DoomProgram` read from the snapshot.


## Security residuals

* [Medium] apps, an app's directory ([design-packaging.md](design-packaging.md#invariants), PK4): until
  the storage service roots an app's `data` grant at `apps/NAME/SIGNER/` (`tree apps`), apps hold no `data`
  grant (the files-service item under Major initiatives) and the directory half of PK4's QEMU test waits; and
  `service NAME purge` answers `enotsup` until the storage service offers `remove_app`.

* [High] apps, the file check under `{signers, Keys}`, `erlang/apps/erx/src/erx_pkg_header.erl`
  (`check_file/2`; [design-packaging.md](design-packaging.md#the-package)): no signature is checked,
  since no Ed25519 verifier runs on the machine; the check only requires the header's key to be a trusted
  one, and a key is a public value, so anyone who can write the data partition can make a package accepted
  by copying a trusted key into its header. Such a package shows signer `unchecked`. Development builds run
  trusted code only; a release build must refuse every installed package until the verifier runs, and this
  blocks release.
* [Medium] apps, the reset count ([design-apps.md](design-apps.md#keeping-a-session)): the first session a
  start row keeps clears the count when it reports ready, which can come before its applications have done any
  work, so a system fault that follows every boot by a little never reaches the rescue configuration. Move the
  clearing to a point after the app has started, or after it has run a while, and test resets on both sides of it.
* [Medium] packages on Fiasco ([design-packaging.md](design-packaging.md#where-a-package-lies)),
  `erlang/apps/erx_storage/src/erx_lfs.erl`: a `packages` grant reaches the volume's `packages/` directory alone,
  but a `data` grant covers the whole volume, so root's sessions, which hold it in a development build, can add, rewrite or remove an
  installed package at `/data/packages`, past the package process. A changed package fails its header check or,
  from M11, `erx_verity`'s; a removed one is withheld. Closed in a release, whose manifest property 19 grants
  no session `data`, with the test that a user's session finds no `packages/` in its home. The tree has
  two more gaps: the owner trusts any path a grant hands it, so
  the rooting rests on `erx_fs_grant` building nodes only from the callbacks' answers (`erx_lfs` should check
  each path against its grant's root, as `tree apps` will need); and a file at `/packages`, or a directory a
  full volume cannot make, leaves the tree failing its requests without a diagnostic at attach.

## Planned features

* [Medium] Doom on the Pi 4 is very slow (`examples/doom/doom`, erXos's fork; the firmware framebuffer driver,
  `erlang/apps/erx_fb/src/erx_firmware_fb_core.erl`): its demo loop runs, over the 1920x1080 `a8r8g8b8` screen, at
  a frame rate far below QEMU's. Unmeasured is where the time goes: the port's scaled frames written through
  `/dev/draw` in 64 KiB bands, the display's composition, or the driver's copy of each changed rectangle into the
  framebuffer. Measure frames a second on the board first ([docs/todo-performance.md](todo-performance.md)).
* [Medium] apps, who may read the start table's row names in a release build ([design-apps.md](design-apps.md),
  [design-find-act.md](design-find-act.md#decisions), decision 3): `[apps]` is visible only at scope `all`, so a
  release build's palette lists no apps and `service -e` cannot read `declared_enable`; design-apps decides which
  sessions see the row names, and the palette follows it.
* [Low] `examples/dashboard`: the app draws its dial and ground for the dark palette (`?PALETTE` in
  `erx_dashboard.erl`) whatever its display chooses, since `erx_ui` does not tell an app its window's palette
  or size (`erx_win:info/1` has both); on a light display its text is dark on the dark ground. The ground is
  drawn at the Pi 4's 1920x1080 and centred, so a larger screen shows the window colour round it. The graph's
  dotted mark leaves every third point out, which at 180 live samples on 520 px is nearly solid; LVGL's
  line dash on the mark's draw task would be uniform. erx-lvgl's area fill draws nothing for a graph with
  more samples than pixels (LVGL's crowded mode).
* [Medium] `examples/dashboard`, the kiosk of plan part 4a: the app and its host test
  (`test/host/erx_dashboard_test.rb`, the frame against `test/display/reference/dashboard`) exist; its
  first QEMU boot comes with part 4b's package. design-packaging.md's verification row for
  `examples/dashboard` describes a Pause click and a status line, which this dashboard of a clock, a date
  and a quotes panel does not have, and its host test goes through `erx_ui_host` and the SDK's boundary
  check, which this host test does not. G6 (design-display.md) holds when no device request comes between
  two changes of the tree. The kiosk cell (`tools/lib/erx/kiosk.rb`) boots it as an image package and
  checks its frame; no QEMU test checks G6 yet: the cell's next step counts the driver's
  requests between two of the dashboard's clock ticks, where a seeded timer that repaints with no change
  fails the count.

* [Medium] the kiosk cell (`tools/lib/erx/kiosk.rb`), left from its review: its boot repeats
  MediumBoot::Run's (fresh medium, slot parse, firmware tree, the boot value spliced after the image's
  identity) instead of sharing one MediumBoot function;
  `packages: refused` is logged for admission refusals only, not for a header the file check refuses;
  AppPack builds an app's beams into the app directory's own `ebin/`, which each run of the cell or of
  `tools/erx pack --app` leaves in the source tree (`examples/.gitignore` ignores it), where the
  build tree is their place. `ls /apps` and a dropped `--enable` are not yet cases of its boot.

* [High] `examples/dashboard` live quotes, `httpc`'s bounds: no `httpc_bound` edit (the item under "HTTPS clients"
  above), which a real fetch of the live quotes on the target waits for, and no run on the target that fetches
  through the image's trust store ([design-crypto.md](design-crypto.md#https-clients)).

* [Medium] `examples/dashboard`: the live dashboard's reference frame, `dashboard-live` under
  `test/display/reference/`, is not recorded: `erx_ui_host` with the Erlang renderer draws the dashboard's tree
  for a fixed time and a fixed live board, one quote in each state of the status line, `clock not set` among
  them, and the host test compares it with the picture; seeded fault: a stale value shown without `stale`
  changes the frame.

* [Medium] `erx_quotes_core` (`trying`): a round in flight has no deadline, so a request httpc never
  answers (a handler killed without replying) keeps its quote from fetching until the source restarts.
  Fix by construction: a deadline in `trying` that `tick/3` ends as `timeout`, and requests keyed by quote.
  A history request has the same gap the other way: `history_at` moves on when it is asked, so a
  history httpc never answers leaves its entry in `erx_quotes`'s `requests` for good, one more each
  hour, past the six-request bound of the dashboard's [README](../examples/dashboard/README.md#how-the-quotes-behave); keying requests by `{Kind, Quote}`
  makes a new request replace the old one and drop its answer.

* [Medium] `erx_quotes`, `erx_quotes_view`: both take apart `erx_quotes_core:state()` (the table's source
  rows); the `fetch` action should carry the source row and the view take the table, so the core alone
  owns its representation.

* [Medium] `examples/dashboard` (`erx_dashboard.app.src`): the live quotes need `ssl` and `inets`, which
  `erx_quotes` starts at run time but no `.app` file declares; settle whether the `.app` names them.

* [Medium] `kiosk/hvf-1cpu-quotes` (`tools/lib/erx/quotes_fixture.rb`, `tools/lib/erx/kiosk.rb`): the
  fixture answers only Kraken's Ticker requests, not the OHLC history request the dashboard's [README](../examples/dashboard/README.md#the-qemu-cell) ("The
  QEMU cell") names, so each quote's history fails with a 404 and the cell does not check the
  `quotes: QUOTE history N entries` lines the cell passes on.

* [Low] `examples/dashboard` (`erx_quotes_table`): Kraken's address, 104.16.14.28 (one of
  `api.kraken.com`'s Cloudflare addresses), is hardcoded and may change; a change shows
  `cannot connect` or `certificate rejected` until the row's `address` is updated.

* [Medium] `erx_quotes` tests: the effect process's own paths (an unknown request dropped, a redirect
  followed within the round, a request httpc refuses at once, the tick) have no test; the HTTPS test
  covers a value, a refused certificate and a body too big.

* [Low] `examples/dashboard`: the clock shows the wall clock even while `/proc/time`'s `state` is `unset`
  ([design-time.md](design-time.md)), so an unset clock shows a 1970 date as if it were the time; it
  should show the clock as not set.

* [Low] apps, [design-packaging.md](design-packaging.md#the-apps-row): a setting for the apps group's
  CPU share of `users`. The apps group takes what the principals' shares leave, each app an equal part, with
  no field of the `apps` row to set it; a builder who wants apps held to a smaller share has no lever.
* [Low] apps, [design-packaging.md](design-packaging.md#the-apps-row): a board's own figure for a
  parameter of the services its apps are granted. The derived rows take each service's ABI defaults, so
  every board's apps get `windows_pixels_default`, 8 MiB, one 1920 by 1080 `x8r8g8b8` buffer. A board with a
  screen above 1080p (3840 by 2160 needs about 32 MiB a buffer, and an app there is refused `enomem` when it
  opens its window) or a small panel (800 by 480 needs 1.5 MiB, so 8 MiB reserves far more than it uses)
  needs its own. Add it in the general form, `parameter SERVICE NAME VALUE` lines in the `apps` row, checked
  against the service's schema as a facet row's parameters are, not a column for one service, and update the
  row of [Alternatives considered](design-packaging.md#alternatives-considered) that sends such values
  to the service's defaults. Needed only once such a board gets an `apps` row.
* [Medium] debugging, 0.2's native debugger, core dumps and remote Erlang debugger ([design-display.md](design-display.md#risks-and-decisions)'s
  LVGL-in-app, [design-programs.md](design-programs.md#signal-numbers)): no document designs a debugger for a native
  program (a GDB remote stub, so `gdb` attaches to a domain or sub-space over a connection), the core dumps a
  debugger would read, or a debugger for Erlang processes in another node or domain (remote `dbg`, `observer`
  or `debugger` over distribution). Design the three together, with LVGL-in-app, since an app that links its own LVGL
  is the first native program a developer debugs. The designs disagree today: design-programs.md says erXos
  writes no core file, so the signal table has no core column and `WCOREDUMP` is never set; decide whether a
  core dump is a file a program's death leaves, an inspector read of a stopped domain, or neither, and edit that
  statement with the design. QEMU's GDB stub (`-s`) debugs the kernel only; the harness passes no such flag.
  The kernel's side is designed ([design-debugger.md](design-debugger.md)), and its host tool is what this
  design should build on rather than beside: a target there is a memory, a list of CPUs with their registers and
  a build identifier, read through one interface, with an ELF core reader, a GDB remote protocol client and
  views in the inspection schema, so a program's core file and a stub in a domain are two more targets of
  `tools/erx debug`, not a second debugger.
