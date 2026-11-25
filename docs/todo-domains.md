# TODO: Domains and the system manifest

Open work on the domain service, domains, the code service, facets, the system manifest and its checks, the funnel. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Stopgap replacements

* [Medium] `tools/lib/erx/manifest.rb`, `GRANT_CHECKERS`: each facet goes to the checker its service names
  (`grant_checker`), but the helper reaches its method only by the name string each checker repeats
  (`check_line_grants`, `normalize_displays`), so a helper listed with its keys and no method admits its facets
  unchecked; map each helper to its keys and its method and call them from one loop. With it: `check_start_display`
  still takes a display as a `windows` service while property 18 takes one as a `windows_grant` service
  (design-system.md says the former), and `check_apps` grants an app row a service whose checker is not run on app
  grants, which only line.txt declaring every parameter `one` keeps off the line.
* [Medium] `tools/lib/erx/manifest.rb`, `check_framebuffer_windows`: a framebuffer window is checked against the
  platform record's register windows and RAM, not against the board tree's every `reg` and `ranges` (the GIC, the
  local peripherals, PCIe windows), which the record does not list; checking it against the board's own tree
  (`board_tree.rb`) would make the window's isolation hold by construction.
* [Medium] `tools/lib/erx/manifest.rb`, `Check#check_mode`'s partial path lists the record kinds it
  refuses, so a record kind the grammar gains is admitted in a partial boot until someone adds it to the
  list. Make the partial mode an allowlist of the kinds it takes, every other kind refused, keeping each
  refused kind's reason in one table.
* [Medium] `tools/lib/erx/manifest_edit.rb`, `removed`: a removal is refused when a record left in names a
  taken one by an `@kind.name` token, but not when it names one by name alone: a `display NAME` record names
  its service, and a `start NAME` row a principal that must keep a session template, so `without` of a
  service or `without_sessions` under a start row returns text the admission check refuses rather than an
  edit refused. `without_domain` handles display records through its own list. Give `Record` one "the
  records this record names" function covering the name-keyed links the checker knows
  (`tools/lib/erx/manifest.rb`, `service_name`, the start rows' principal), have `removed` and
  `with_unused_definitions` derive from it, and delete `without_domain`'s display list.
* [Medium] `tools/lib/erx/manifest_frontend.rb`, `Record#decimal`, `string` and `reference`: a field's value
  is decoded in three places with different rules: these, the manifest checker's `number`, `text` and
  `reference` (`manifest.rb`, which take `0x` numbers and `hex:` bytes), and `FacetNames.field`. A harness
  edit or reader refuses a manifest the packer accepts (`cpuset 0x3`). Move the checker's decoders onto
  `Record` and have the checker, `Manifest::Edit` and `FacetNames` call them. `Edit.repoint` also writes
  its `to` unchecked, and the printer writes an unquoted token verbatim, so a value with a space or newline
  would not read back as one word; refuse such a token where the printer writes it.
* [Medium] A keeper's restart of a crashed session can be refused once with `{refused,no_memory}` before the
  next retry succeeds, seen with a principal whose memory is exactly one session wall plus one outer budget:
  the ended domain's budget is apparently not back when the keeper retries (`erlang/apps/erx_starter`, the domain
  service's budget release). Unverified whether the keeper should wait for the ended domain's exit record, or the
  principal needs headroom; reproduce with a session that crashes at start.
* [Medium] Manifest property 4 (`tools/lib/erx/manifest.rb`, `normalize_principals`) requires the principals' CPU
  grants together to fit within the `users` share, and every board manifest gives the system principal all of
  `users`, so docs/design-apps.md's own example app principal (`principal clock`, `grant @share.users`) fails the
  manifest check. The rule for dividing `users` among principals is undecided; the `apps` QEMU suite splits it in
  its own test manifest (`Erx::Apps::SPLIT`: root takes three quarters, the app the last quarter). Once decided,
  record it in docs/design-apps.md or docs/design-system.md, fix the example and put the split in the board
  manifests.
* [Medium] `erx_connections` (`let_go/5`): a connection with an area is answered unmapped or lost only once
  every process that held the area or an image over it has collected; an idle holder that dropped it but never
  collects holds the connection, its objects and the display's budget for it. The design names only
  `erx_winfs` and `erx_screen`. A fix by construction: at let-go, the NIF replaces the area's range in place with
  private zero memory owned by the resource and the agent answers at once.
* [Medium] `erx_connections`: only the agent opens an `erx_lane` port over a connection's side, but no build check
  enforces it as `area-mappers` (tools/lib/erx/area_mappers.rb) does for `erx_area:map/4`; a side another process
  maps is not counted by the agent, which then answers unmapped while that mapping lives.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_mints.erl` (`grant_limits/2`, `installed_facet/3`):
  a grant is told a files or an input grant by its service name alone (`files`, `inputs`), though names are
  unique only per server, so a files grant of one server named like another server's input service is minted and
  held read-only; the interface would better come from one `{Server, Name} => Interface` map, which
  `erx_domain_srv` builds for the ready answer, and read-only from a declaration of `abi/services/input.txt`
  rather than from the Erlang that names `?ERX_SERVICE_INPUT`.
* [Medium] `tools/lib/erx/manifest.rb`, [The host tool's front end](design-web.md#the-host-tools-front-end):
  the design says a release manifest that offers the host the `web` facet fails the manifest check. At run time
  the host link offers it only where the manifest's development flag is set and the system domain holds a facet of
  the `web` interface (`erx_hostlink_web:open/1`), but Phase 1's check refuses every release manifest, so the
  build-time rule has no site yet; with the release check (M11), refuse a release manifest that grants a facet of
  the `web` interface, with a seeded violation.
* [Medium] manifest, `tools/lib/erx/manifest.rb` (`device_clock`), `liberx/backend/core/boot_manifest.c`,
  `liberx/system/dom_boot_view.c`: "only a PL011 row carries a clock" is a rule on one compatible string, checked
  only by the Ruby manifest check; the C readers pass any 32-bit clock through, so a PL011 row with clock 0 is
  refused only when `erx_pl011` starts, and a clock below what `erx_pl011:baud_divisors/1` accepts (about
  1.83 MHz for 115200 baud) passes the build. Make "its driver reads a clock" a property of the device kind
  (`include/erx/device_kinds.h`'s table), read by the Ruby check, the C readers and `device_path_problems`,
  and check the divisor bound at build time.
* [Low] erx_device_record's fuzz target (`tools/fuzz/erx_device_record.rb`): under seed 20261114 its
  seeded copy "taking a space in a path" passes, so the target rarely builds an accepted path with a
  space inside it, and the run fails without a finding.
* [Medium] system manifest, the bridge's second line (`tools/lib/erx/manifest.rb`, `device_window`;
  `config/platforms/raspi4b.json`, unit `pcie`): a device-tree row carries only its node's first interrupt, so the
  BCM2711 bridge's unit holds SPI 147 and its MSI line, SPI 148, is in no unit and not in the unit rule's line
  relation, though [design-pcie.md](design-pcie.md) and [design-platforms.md](design-platforms.md#pcie-bridges)
  make both lines the bridge's. A row of another domain naming SPI 148 would pass the unit rule, and the boot
  view's refusal of a place routed to one of the bridge's own lines cannot see it. Let a row carry each of its
  node's lines, or derive the unit's lines from the node.
* [Low] system manifest, `tools/lib/erx/manifest.rb` (`check_system_window`, `unit_holder`): the holder of a
  window's device is found by the device's path, which a `pci` row does not have, so a system window on a
  block-role PCIe function would be checked against the wrong unit. No platform record has one; key the lookup by
  device index (a unit's span) when one appears.
* [Medium] Services dispatched by name, checked by interface (`erlang/apps/erx_domain/src/erx_domain_srv.erl`,
  `tools/lib/erx/manifest.rb`, [design-abi.md](design-abi.md#services-facets-and-their-parameter-schemas)): the
  domain service picks a system-domain facet's callback and the process behind it by the service's name
  (`system_facet/4`, `served/2`), while the manifest check matches the `log`, `clock` and `inspect` services by
  interface, so a service named `log` of another interface, or a service of interface `log` under another name, is
  admitted and its grantees get a surface the check never judged. `check_pcie_parties` closes this for `pci_bus`,
  `pci` and `pcie` alone, as `check_code_objects_service` does for `code_objects`; bind every system-domain service's
  name to its interface in one rule and delete the per-interface copies.

## Bugs by subsystem

* [Medium] manifest check, `tools/lib/erx/manifest.rb` against `liberx/system/dom_boot_view.c` `boot_devices` (the unit test after its device loop): the domain library's boot view refuses devices of two units that share a register page (by 4 KiB page) or an interrupt line, but the Ruby manifest check admits them, so a manifest the build check proves is refused at boot; `manifest_check_test.rb`'s USB and block fixtures passed the check with the stick on display's line 60 and the block rows on the line unit's page, until the drive-record test ran the view over them, and `/third@0` (`test_a_block_drive_s_holder_holding_anything_else_is_refused`'s platform) still shares `spare_block_row`'s page and line in another unit. Two implementations of one rule; fix by construction as for `dom_grant_fits` above.
* [Medium] manifest check, `tools/lib/erx/manifest.rb` against `liberx/system/dom_core.c` `dom_grant_fits` (:222, used at :494): the domain library holds a session's CPU grant within its principal's, but the Ruby manifest check does not, so a manifest whose session share exceeds the users share passes the build and is refused at boot (only the C planner in `dom_planner_test.rb` caught it when the users share dropped to 0.9). Two implementations of one rule; fix by construction: one source the C planner and the Ruby check both take, or the check runs the planner.
* [Low] manifest check, `tools/lib/erx/manifest.rb` `GRANT_CHECKERS` and `check_network_grants`: the checker inventory lists key names alone, so a declaration naming `net_grant` with a key it lists but of another kind or cardinality (an identifier set `buffers`, say) counts as consumed though no clause reads it; and `check_net_ports` takes the facets of the net interface, not those of the services naming `net_grant`, against design-abi.md ("Services, facets and their parameter schemas": each facet goes to the checker its service names, never to one that picks facets by interface). Key the inventory by key, kind and cardinality, and hand `check_net_ports` the facets its checker name selects.
* [Low] system identifiers, `tools/lib/erx/manifest_frontend.rb` `IDENTIFIER` and
  `erlang/apps/erx_domain/src/erx_ident.erl` (docs/design-system.md, "Identifiers"): the
  manifest reader and the system domain each write out the rule `[a-z0-9][a-z0-9_-]`, 1 to 63
  bytes, so a change to one admits names the other refuses, a principal the manifest admits
  that no login can name among them. Generate both from abi/manifest.txt's `identifier_max`
  and one rule line beside it.
* [Low] manifest check, `tools/lib/erx/manifest.rb` `parameter_value`: an `identifier` parameter is checked only for its byte bound, not the manifest reader's identifier class (`abi/manifest.txt`, 1 to 63 bytes of `[a-z0-9][a-z0-9_-]*`), so a name like `"Nus"` passes the parameter check and is refused only when `admit` reopens the bytes, with the codec's generic error rather than a `facet.parameter` diagnostic. Apply the identifier class in `parameter_value`, and cap an identifier parameter's bound at 63 in the ABI reader.
* [Low] handles, `erx_group_configure(ERX_CAP_NULL)` (`liberx/backend/fiasco/group.c` and the hosted
  `group.c`): both backends refuse NULL with `ERX_EINVAL` before the lookup, while the call table's configure
  row does not take NULL and [Handles](design-fiasco.md#handles) sends a value a call does not take to the
  lookup, which answers `ERX_ESTALE`. Drop the pre-check on both backends and expect `ERX_ESTALE`, so the rule
  holds without an exception.
* [Low] the system domain's id in Erlang tests: thirteen modules under `test/erlang` (`erx_ble_facet_tests` among
  them) write `-define(SYSTEM, 4)`, and `erx_inspect_facet_tests` and `erx_inspect_worker_tests` write `{pid, 4, ...}`,
  copies of the ABI row `system_domain_id` the code they test compares with. Include `generated/erx_abi.hrl`, as
  `erx_domain_tests` does, and use `?ERX_SYSTEM_DOMAIN_ID`.

* [Medium] facet parameters, the `member` kind (`liberx/system/dom_boot_view.c` `boot_parameter`,
  `otp/erts/emulator/nifs/erxos/erx_domain_terms.c` `parameter_term`): no test drives a packed member row through the
  C view and the NIF. Extend `test/host/facet_parameters_test.rb` and `test/erlang/erx_facet_parameters_tests.erl`
  with a files facet stating `rights ro` (its limits carry `rights := ro`) and forged rows refused (scalar 0 and 4,
  kind u64 under key 1), with seeds for an off-by-one bound and a dropped `- minimum`, and give
  `tools/fuzz/manifest_seeds.rb` a files facet with `rights` so the fuzz target reaches the member case.
* [Low] `erlang/apps/erx/src/erx_ns.erl` `place/1`: a facet's mount is `rw` whatever its grant's rights, so an
  `ro` grant shows as writable until the server refuses with `erofs`, and an `rx` facet cannot run code (F6
  needs an `rx` mount); the mount should take the facet's rights.
* [Medium] manifest fuzz harness (`tools/fuzz/manifest_fuzz.c`, `tools/fuzz/manifest_verdicts.c`): `view_build`
  runs `view_check` only when the domain library admits the manifest, and a refusal is silent, so the library
  refusing a valid seed (the development manifest) leaves the target and `test/host/manifest_fuzz_test.rb` passing
  with nothing checked. Print whether the library viewed each accepted manifest (`ok viewed`, `ok refused REASON`;
  `erx_manifest.rb` compares only the first word) and require `viewed` for the valid seeds.
* [Medium] domains, mints (`erx_net_erxos` mint, `erx_driver_ctl` mint, `erx_fs_mint`; design-system,
  "Facets a configured domain serves"): a mint answers its request only after the grant or
  facet is started and exported, and the domain service drops a reply that comes after the
  request's deadline or after it cancelled the request (`erx_domain_mints`). The grant or
  facet minted for a dropped reply stays alive and exported to its grantee until the
  connection between the two domains ends (the network grant, and a `data` or `system` grant of
  the storage domain to any domain but the system domain) or the serving domain ends (the
  storage domain's `storage_ctl` facet, which ends only with its mint, and its `data`
  and `system` grants to the system domain), since no message withdraws a mint's answer.
  The `system` mint answers no grant until its mount of the tree ends, so a slow
  `system` window can make its first grants miss the 10 s deadline
  ([todo-performance.md](todo-performance.md), the `system` mount's boot cost).
  Give the domain service a withdrawal it sends the mint for every request it stops
  waiting on, or have each grant end unless the grantee claims it within the deadline.
* [Medium] domains, a facet of no manifest service (`tools/lib/erx/facet_names.rb`, `UNDECLARED`;
  [design-abi.md](design-abi.md#services-facets-and-their-parameter-schemas)): a session's `console`
  facet, which `erx_console` hands in its create spec and `erx_session_tty` reads with `erx:cap(console)`
  ([design-live.md](design-live.md#the-console)), is of the interface `abi/services/console.txt`
  declares, but no system manifest service instantiates it, so the funnel takes it through a literal
  `console` clause of its own (`erx_domain_srv:facet/3`). Instantiate it once the attenuating hand-on of
  the facets item below lands, through which the console facet is then handed on like any recorded facet;
  that deletes the literal clause, and `console` leaves `UNDECLARED` with `EXEMPTIONS_MAX` lowered to 0.
* [Low] domains, the facet table's manifest reader (`tools/lib/erx/facet_names.rb`, `records_of`): the
  facet-names check, and the funnel's table generated from it (`erx_facet_names.hrl`), read the manifest
  with a small parser of their own rather than `Erx::ABI::Syntax.parse`. Read it with the manifest's own
  syntax so the table and the image's manifest cannot disagree on a service's name.
* [Medium] domains, the inspect facet's scope wiring (`erlang/apps/erx_domain/src/erx_domain_srv.erl`,
  `system_facet/4`; `erlang/apps/erx/src/erx_build.erl`, `shell_principals/1`): no test checks the scope a
  session's minted inspect facet holds, so a `system_facet/4` that mints `all` for every grantee passes, and
  `shell_principals/1` is tested on no manifest that names a system-shell principal. The service tests' export
  stand-in has no `owner/1`, so a request cannot go through a facet the service minted. Give it one, mint with
  `inspect_policy => #{roots => [1], development => false}` for principal 1, expect `{error, scope}` for
  `[kernel, log]`, and seed `inspect_scope/3` replaced by `all`; test `shell_principals/1` on a packed manifest.
* [Low] facets, a request past `max_request` (`erlang/apps/erx/src/erx_inspector.erl`, `route/4`): the facet
  drops it unanswered, so the inspector waits `inspect_query_max` and a margin before `{error, failed}`. It can
  refuse such a request at once from the grant's `max_request` (`erx_facet:info/1`).
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_srv.erl` (`slogan/3`): a
  crash's slogan reaches only the death record and its dump text is read and dropped, since
  no inspector exists to show either; design-runtime.md, "Crash handling", has the inspector
  show both through its escaping.
* [Low] domain service, `erx_domain_srv:restart/6` and `liberx/system/dom_boot_view.c`: a
  configured domain the manifest marks `required` (`mf_domain_flags`, `abi/manifest.txt`) is
  left down beyond its restart intensity like any other, where design-system.md "Boot failure"
  ends the machine. The boot view's configured row carries no flags, so `erx_domain_lib`'s
  `configured()` cannot say `required`, and the service's `{no, Next}` answer logs "left down"
  for every domain. No manifest marks a domain `required` yet, and leaving it down fails safe.
  Carry the flag into the row and end the machine on it, with the end's reason in the log and a
  host test of the decision.
* [Low] domain service, `erx_domain_srv:session_start/3`: a start's `display` may name any
  service its template is granted, not only a display, since no `windows` service exists to
  check it against; the mint then carries `session` to a server that ignores it. Check the
  name against the manifest's displays once `abi/services/windows.txt` exists. Two starts
  naming one display both get the mark: only `erx_starter`'s keepers pass `display`, and
  design-display.md wants one display's session, so whether the domain service refuses a
  second is a design question for Track D.
* [Low] manifest packer, `tools/lib/erx/manifest.rb`: a principal's name is checked to fit
  `<name>_<names>` in 63 bytes, but a session name may take a number past `names` when
  another principal holds a lower one, so a long name's later start is refused with
  `bad_identifier` rather than the library's quota. Bound the name by the domain service's
  names quota.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_srv.erl` (`create/2`):
  `erx_domain:create/1` takes the domain library's own request fields (the boot image's
  runtime and release indexes, the budgets, the grant), where design-domains.md "Erlang
  interface" has a spec of a release name and a resource policy compute them. Replace the
  fields once release lookup by name and the resource policy exist. The runtime index goes
  with them: the domain service maps the spec's `flavour` (default `jit`) to `runtimes/jit` or
  `runtimes/emu` and, under `erx.det=1`, forces `runtimes/emu` for every domain, configured rows
  included, whatever it names (design-runtime.md, "BeamAsm"), once the boot's mode reaches the
  system domain. Until then a create names the BeamAsm image by its index and gets it in any boot mode.
  The release name replaces Fiasco's `boot` field too: once the library takes the
  release by name it binds `-boot` itself, and the two bindings in the manifest's packer
  (`Erx::Manifest#boot_args`) and the service (`boot_args/2`) go, with the gap
  design-domains.md records for system-domain code that calls `erx_domain_lib:create/1`
  directly and names its own `-boot`.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_pid.erl`: a domain can
  fill its domain pid's mailbox as fast as its lane delivers, and the pid passes each
  answer-shaped message after the ready report on to the domain service, which every domain
  shares, and which drops and counts each one no connection expects (design-system.md "What
  a domain sends the domain service"). A count is one integer per domain, but the time
  each message costs the pid and the service is not bounded. Bound what a domain can make
  the pid and the service spend.
* [Medium] facets, `erlang/apps/erx/src/erx_facet.erl` and `erx_domain_srv.erl`
  (`grant_facets/3`, `facets/2`): the facet behaviour checks the origin, the reply target, the
  encoded size against `max_request` and the limit in flight, and nothing else of
  design-domains.md "Facets". Residuals of fairness and memory rather than
  authority: no admission by the grantee's measured share of reductions, no queue quota and
  no heap limit, so a grantee can fill its facet's mailbox and the facet's heap as fast as its
  lane delivers; `max_request` is checked by the facet once the message is decoded and
  queued, not by the funnel before, and likewise a query worker (`erx_inspect_worker.erl`)
  drops an agent's answer past `inspect_message_heap_min` words by its decoded size once it
  is queued, not the funnel before it; and admission is hand-written, not the generated path
  from the service's operation schema. The funnel (`facets/2`) hands on only `console`,
  a literal clause of `facet/3` beside its TODO.md item, and refuses every other
  name with `{bad_spec, facets}`, a name of the table included (`attenuated/2`), since
  handing on the starter's own recorded facet would pass it on unattenuated. Phase 1
  residual: `console` takes any local process the system domain
  hands, which only trusted system-domain code can do; it goes with the console item above,
  which declares it. Build the
  attenuating hand-on of design-domains.md "Handing a facet on", which mints a facet in
  front of the starter's within its grant record, and let `attenuated/2` hand recorded
  names on through it. Attenuation alone does not keep design-system.md's "The manifest"
  property 8 (only the system domain holds a facet of driver control): design the rule
  that ties a hand-on to the manifest's facet rows for the new domain first, in
  design-domains.md "Handing a facet on". The facets `grant_facets/3` starts in front of a spec's grants and of
  the system domain's served ones need grant records of their own for a starter other than
  the system domain to hand one on. Until then the funnel's table lookup (`declared/2`)
  decides nothing a test can see, since `attenuated/2` refuses every name of the table too.
  Missing besides: `erx_domain:grant/4`. Init waits at most 5 s for the answer and then
  runs with none.
* [Medium] domains, `liberx/system/dom_life.c` (`life_connections`) and design-domains'
  limits table: the table says a domain's `connections` counts the system connection,
  and `life_connections` leaves it out of the quota, which the development manifest's
  counts follow (storage 2, root's session 3). Make the two agree, and check whether
  `ctl_slots = connections` (`dom_apply.c`) then needs a slot for the system connection;
  write the derivation of the machine's `max_connections 8` beside it in the manifest.
* [Medium] facets, `erlang/apps/erx/src/erx_facet.erl` (`provide/2`) and `erx_domain_srv`: that a
  mint's end ends its domain, so its restart provides again and the grants are made anew, is each
  server's duty (a permanent application whose process the mint is), and nothing enforces it: a
  mint under a supervisor is restarted, `provide/2` refuses it, and its service grants nothing
  until the domain restarts; `init:restart/0` erases the provides and the domain pid takes no
  second report. Make it hold by construction: the domain service monitors each accepted mint and
  stops the incarnation at its end (or init halts the node at a reported mint's end).
* [Low] facets, `test/erlang/erx_domain_mints_fuzz.erl`: the mint fuzz target sends no
  session events (`session_ready`, `session_ended`); the exhaustive explorer covers them, and
  their fields are the domain service's own, but the fuzz oracle should hold session grants too.
* [Medium] facets, `erx_facet_mint` and configured servers' mints
  (`test/erlang/apps/erx_echo_test`): `erx_facet`'s `ends_with` takes the port of this domain's
  connection to the grantee (`erx_connections:connection/1`), but no configured server's mint
  passes it yet, so a facet minted for an incarnation that ended lives on until its server ends,
  one per grantee restart, and one per session for each grant to a session template, so per
  login. It admits only that grantee's id, which no later domain takes, so it grants nothing; it
  is a leak against design-system.md's "ends with its grantee". Have the echo test mint and the
  Bluetooth mint add the grantee's connection to `ends_with` (refusing the mint when there is
  none, as `erx_net_erxos` does), and have the re-grant boot check the old facet ends.
* [Low] facets and files, `erlang/apps/erx/src/erx_facet.erl` (`is_end/1`, `monitor_end/1`,
  `ended/1`) and `erlang/apps/erx_files/src/erx_fs.erl` (`connection_monitor/2`): two owners of
  "what a grant ends with", a process or a connection's port, with different types, a different
  rule for one already ended (`erx_facet` refuses with `noproc`, `erx_fs` exports and ends at the
  immediate `DOWN`) and different exit reasons. Give one module the type and the monitor, and
  have both use it.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_core.erl`: the names
  quota is fixed at 64 per principal, not the manifest principal's own field, which the
  library's view does not expose yet. Expose it in `configured/0` (or a principal entry) and
  use it.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_srv.erl`
  (`start_configured/2`, `restart/6`): a configured domain that fails to start, or ends
  beyond its restart intensity, is only logged, also when the manifest marks it `required`,
  which `configured/0` does not report yet; design-system.md has a required domain end the
  machine as a fault would. Report the mark and end the machine on it.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_srv.erl`: the service
  trusts every system-domain process. It acts on any `{domain_ended, Id, End, Record}` and
  on a plain `{'EXIT', DomainPid, _}` message, so a forged one retires or stops a domain,
  and a malformed forged report (an end kind `erx_domain_core:info/1` has no clause for, an
  id that is not an integer) crashes the service, which ends the machine. Other domains cannot send either: their messages
  arrive in the `erx_origin` envelope. Tag the library's reports with a secret the NIF
  hands the registrant.
* [Medium] domain service, `test/erlang/erx_domain_tests.erl`: nothing tests the `ebusy`
  and `erights` answers, which the stand-in library never gives. Add a stand-in that
  refuses.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_core.erl`, `erx_ident.erl`: pooled names are
  `<principal>_<n>` ([Identifiers](design-system.md#identifiers)), so stock net_kernel accepts them, but
  an identifier still may hold `.`, which net_kernel refuses in a node name. Build the name pool, and make a
  domain's node name refuse a `.` before the domain boots with an `-sname` its own distribution refuses.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_core.erl`: the name pool
  (`<principal>_<n>`, [Identifiers](design-system.md#identifiers)) is not built. Build it.
* [Low] domain service, `erlang/apps/erx_domain/src/erx_domain_core.erl` (`admit/4`): where
  the root built no library the service still admits a name under an empty host and makes an
  atom such as `'web@'` before the create is refused; and `restart_period_s 0` reads as no
  limit. Refuse before admission when there is no library, and decide the meaning of period 0.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_ident.erl`: identifiers are an
  opaque type checked at `erx_ident:new/1`, and Dialyzer is the only check that no other
  module builds one. design-system.md "Identifiers" has a build check over the system
  domain's syntax trees fail on a record expression that builds a named record outside its
  owning module; add it (as `tools/lib/erx/ns_writers.rb` checks its Erlang rules).
* [Low] the machine grant's principal, `erlang/apps/erx_domain/src/erx_domain_srv.erl`
  (`system_facet/4` for `machine`, through `user_name/2`): the configured domains `storage` and `display` run under the
  system principal, as root's sessions do, so a `machine` row granted to one of them would
  log its end as `by root`. Only root's template holds the row, so no such grant exists; a
  row that names one needs a principal of its own for the domain first.
* [Low] manifest check, `tools/host/dom_plan.c`: a refusal of property 12 names the
  status alone (`inval` covers a grant past `system`, the reserve, files and limits),
  so the operator cannot tell which sum failed; and the fuzz target's
  "a second plan of one id is refused" holds by the full table (`max_domains` 2 in
  `tools/fuzz/dom_core_fuzz.c`), not by the duplicate-id check. Have the planner print
  the refusing check, and give the fuzz view a third record.
* [Medium] manifest check, `tools/lib/erx/manifest.rb` (`Check#check_facets_supported`):
  a facet that names operations of a service a configured domain serves, or of a tree,
  is refused (`unsupported`), as the boot view refuses it, since only the system
  domain's `erx_facet` checks a grant's operations (design-time.md, "On Fiasco"); a mint
  in a configured domain and an `erx_fs` grant check none, so such a row would grant
  every operation. The server's release is not checked to supply the service's
  interface.
* [Medium] facets, `erlang/apps/erx/src/erx_facet.erl` (`operation/1`): of the system-served services
  only the `clock`, `install` (the `code` interface), `pci` and `pci_bus` facets' callbacks export `operation/1`, so a row naming operations of
  another (`inspect`, `log`, `code_objects`, or one served through `erx_domain_facet`) compiles and
  boots, and only its mint refuses it (`unchecked_operations`, logged, no facet), until the generated admission path checks every
  service's operations.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_srv.erl` (`served/2`): a
  configured domain's facet of a service the system domain serves ends with the process
  behind it, and when that service restarts and names a new process (`erx_facet:serve/2`)
  nothing grants the domain a new facet, so the domain finds the facet dead until it
  restarts itself. Re-grant through the installation path (`{erx_facets_install, ...}` and its
  acknowledgement) when a served name gets a new process, with a host test.
* [Low] manifest check, `tools/lib/erx/manifest.rb`: a facet row's `max_request` and
  `in_flight` may be 0, which makes a facet that refuses everything (the domain service leaves
  a system-served one out), and `max_request` is not held to the grantee's `max_frame`
  (design-domains.md, "Facets"). Refuse both at the check, with tests.
* [Low] manifest check, `tools/lib/erx/manifest.rb`: `system_reservation` is 0, so the
  system domain's reservation for `max_domains` admitted domains (property 4) is not
  counted against `root_memory`; design-abi.md has the production admission planner
  derive it, and nothing on Fiasco enforces it. The system domain's `max_frame` of 512 KiB,
  `inspect`'s frame floor, makes each connection's term of it (a record buffer and a funnel scratch
  kept at its high-water mark, about twice the frame) four times what 128 KiB made it, and a
  `max_request` up to 512 KiB is not held to its server's `max_frame`; an `inspect` holder adds
  `in_flight` times `inspect_worker_heap`, 32 MiB per holder at `in_flight` 2 (design-live.md, "The query worker");
  nothing reserves it, and the enforced bounds are the worker's `max_heap_size`, `in_flight` 2 and
  `inspect_query_max`.
* [Medium] manifest check, `tools/lib/erx/manifest.rb` (`Check#normalize_domains`): a
  configured domain's limits record (memory, outer, lane, connections, crash, flags,
  peer-held bounds) is not held to its principal's `ceiling_limits`, which design-abi.md
  ("Domain identity and placement") asks; only the runtime limits are, by the planner.
  Data windows may be held by any configured domain, since nothing identifies a
  storage domain (property 8), and `drive` windows only by the media domain
  ([design-drives.md](design-drives.md#manifest-rows)); the slot writer's windows are the system domain's.
* [Medium] manifest check, `liberx/system/dom_boot_view.c`, `tools/host/dom_plan.c`: the
  host planner builds the boot view from the packed manifest with the root's own builder,
  but three things still rest on two sides. (1) The boot order and the introductions come
  from Ruby's rows as plan lines, not from the packed `boot_order` and `introductions`
  tables, and a domain's id (`ERX_SYSTEM_DOMAIN_ID + 1 +` its place) and each party's lane
  side are the planner's rule alone; put the walk of both tables in one pure function the
  boot sequencer will call too. (2) Each file's `offset` and `size` are 0 on the host while
  the root reads the entry's span, so a release slice's `STEP_MAP` size differs between
  the plan checked and the plan applied; pass the spans once the pack is laid out. (3)
  Whether an entry starts with an image manifest is `row['image']` in `plan_file` and
  `row.key?('plan')` in `PackWire#write_image`; one helper should give an entry's head
  for both.
* [Medium] manifest check, `tools/lib/erx/manifest.rb` (`Check#check_plans`),
  `tools/lib/erx/pack.rb`: a manifest with no configured domains is planned, and the
  domain library's boot view built, only when the caller passes a planner, so a pack
  built without one admits a principal `erx_dom_principal_check` refuses, or two units
  sharing a register page, which the root then refuses at boot. Every pack in the tree
  passes one; make the planner a required argument of `Pack.new` and `Manifest.admit`,
  pass `accepting_planner` in the tests, and delete the nil branch.
* [Low] manifest check, `tools/lib/erx/manifest.rb` (`Manifest.release_names`): the image
  builds the releases its rows name before the manifest is checked, so a release named
  like another artifact fails as an artifact clash, not a manifest diagnostic.

* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_core.erl`: the names quota is the constant `NAMES_QUOTA`, 64, for every principal; the manifest's per-principal `names` is read by no one. Take each principal's from its row, as the domain quota is.
* [Medium] manifest check, display grants (`check_display_grants`, `tools/lib/erx/manifest.rb`;
  `config/manifest/qemu-virt-development.txt`, `limits display`): a session template's grant is priced once
  for each slot of its principal's domains quota, though the system principal's configured domains hold five
  of its six slots and the display domain's six connections bound the live grants, so the display's outer
  budget, the system principal's memory and `root_memory` carry about 32 MiB for grants that cannot exist at
  once, 8 MiB and 4 KiB more for each configured domain the system principal gains. Count a template's
  sessions as the quota less the principal's configured domains, or cap the grants by the display's
  connections.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_srv.erl`: a domain whose pid died and whose stop the library refused never ends, so `ending/2` counts it for good and every later create and session start of its principal waits the full `release_wait` (10 s); record the refused stop and leave such a domain out of the hold.
* [Low] domain service, `erlang/apps/erx_domain/src/erx_domain_srv.erl`: a held start runs even if its caller died while it was held, and a start invalid on its face (a bad name, no template) waits out the hold before its refusal; monitor the caller while held and check the request before holding it.
* [Low] Domain service, `erx_domain_srv.erl` `retire/2` and `act/2`: a refusal of
  `Lib:retire/1` (a system connection whose disconnect was refused, or counts that do not
  hold the domain, each a bug) is only logged, leaving the record in the library, and a
  refusal of `Lib:disconnect/1` is only logged, leaving the connection's objects and any
  remains; nothing tries again. Decide whether either ends the service, as `close_side/4`
  does on `noproc`.
* [Low] Domain service, `erx_domain_core.erl`, `erx_ident`, the manifest check: nothing reserves
  the name `system`, so a request or a configured row named `system` is admitted, spends an
  id and is refused only when the boot page is built (its node would be its own peer,
  `ERX_BOOT_INFO_PEER`), as `einval`. Reserve the name where names are bound, so the answer
  is `name_taken`, and refuse it in the manifest check.
* [Medium] Funnel control grammar, `liberx/erx_funnel.c` `spawn_errors`: the three
  errors a SPAWN_REPLY may name (badopt, noconnection, system_limit) are kept by hand
  in step with the writers in `otp/erts/emulator/beam/dist.c`, and the funnel tests and
  fuzz target repeat the names. One source (an `abi/erx_abi.txt` row generating the
  funnel table and the ERTS side) would make a new spawn error impossible to forget.
* [Medium] Funnel authority, design-domains.md "The funnel" step 5: a
  `LINK` without `link` to a live process that holds no link with the
  sender is answered `noproc` by the target process when it handles the
  signal, while one to a process that does not exist is answered at once
  by the distribution input, so the answer's delay can tell a sender which
  guessed pids are alive. The step's timing argument covers only the case
  where a link exists. Such a `LINK` is also never held to the queue
  quota, so a sender can queue them on any live process it can guess. One
  change closes both: the drain answers `noproc` at once unless the target
  holds a link with the sender (a bit of `erx_funnel_hold_t` from the same
  lookup), and only then queues the conditional `LINK` for the target to
  re-judge. The ERTS side has no edit yet either: stock
  `ERTS_SIG_Q_OP_LINK` always inserts, so design-runtime.md's list of edits
  needs a LINK signal that creates nothing unless a link (in any state)
  exists and otherwise sends the `noproc` exit, which the lane driver
  (RT6a) uses for `ERX_FUNNEL_DELIVER_IF_LINKED`.
* [Medium] system, the principal service (`erlang/apps/erx_domain/src/erx_principal.erl`): only its app half,
  the registry of app principals, is built. The rest of its role in design-system.md's service table is not:
  principals, credentials, sessions and quotas, and each session's credentials facet with `login_keys`,
  `add_login_key` and `del_login_key`. Nor is the `erx_principal:number()` type that design-system.md's
  domain service record names: a principal is a `pos_integer()` in `erx_domain_core`'s types, and
  the domain service starts sessions from the system manifest's principals itself. They come with M10 and SSH's fourth stage
  ([design-ssh.md](design-ssh.md#stages)); then `erx_domain_core` takes the type from `erx_principal`.
* [Low] system, principals: a principal can be created but never resized
  or removed. Add both to the principal service, with what happens to its
  sessions, domains, overlays and vault files
  ([design-domains.md](design-domains.md#principals-sessions-and-quotas)).
* [Low] domains, naming: a name binds to the principal whose domain first
  takes it, so a principal can take a name before the principal or the
  configured domain meant to hold it. The design recommends first-use
  binding with the configured domains' names held from boot; the
  alternative is names the administrator assigns to each principal in the
  system manifest, which closes squatting at the cost of a configuration
  step per name. The user decides
  ([design-domains.md](design-domains.md#risks-and-open-questions),
  [design-system.md](design-system.md#identifiers)).
* [Low] domains, retirement: a survivor that never answers
  `connection_down` keeps a dead domain's outer budget and its record in
  the domain library until it unmaps or ends, bounded by the survivor's
  `connections` quota. Leave headroom in `max_domains` for such records,
  and state how much
  ([design-system.md](design-system.md#risks-and-open-questions)).
* [Medium] domains, edit 66 (`beam/bif.c` `link_opt` and `monitor`,
  docs/design-runtime.md): the asker answers a link or monitor of a pid of another run of a
  peer's node only while its entry for the name is connected. One made while the entry is
  pending, in the short window of an introduction or of a stock auto-connect that an
  introduction takes over, is queued as stock queues it and sent once the peer is
  connected; the peer's `noproc` answer names that pid, the asker's sender rule refuses
  it, and the connection ends. The pid need not be real: any domain that can send the
  asker a term can forge one with the peer's name and another creation, so a service
  that monitors pids its clients hand it can be made to lose its connection to a third
  domain, in that window. A pending entry does not know the peer's id; the complete fix
  answers the frame where it is written to the lane port, whose id is known, which would
  also hold edit 66 for every operation by construction. Related: a pid with a creation
  newer than a connected entry's, a later domain while the asker has not yet taken the
  ended one's `connection_down`, gets `noproc` where stock would give `noconnection`.
* [High] domains, the funnel's sender rule (`liberx/erx_funnel.c` `sender_rule`,
  docs/design-domains.md "The funnel", step 4): a link or monitor of a pid of an ended
  domain, sent once a later domain of its name is connected, ends the connection. The later
  domain's funnel finds the target dead and has ERTS answer noproc, and ERTS's answer
  (`PAYLOAD_EXIT`, or `PAYLOAD_MONITOR_P_EXIT` from `erts_dsig_send_m_exit`) names the dead
  pid as its sender, as stock ERTS does; that pid carries the ended domain's id, so the
  asker's sender rule finds a sending pid of another creation and refuses the frame as
  malformed. A client that keeps a monitor on a service domain's process and monitors it
  again after the service's domain was replaced is enough. Seen in the system_domain
  suite's later-domain step with a monitor in place of its message. Two fixes: the asking
  runtime answers a link or monitor of a pid whose creation is not its connected entry's
  itself, with noproc and no frame, as stock ERTS does for its own node's earlier runs
  (recommended: no rule changes, and nothing a stock test sees); or the sender rule admits,
  in those two answers alone, a pid of the lane's node name with an earlier id, which lets a
  later domain report deaths of its name's ended domains. The user decides.
* [Low] system manifest, the USB domain's rows copied in two board parts (`config/manifest/qemu-virt-development.txt`,
  `config/manifest/raspi4b-development.txt`): QEMU virt and the Raspberry Pi 4 carry the same USB domain rows, which
  cannot be in `config/manifest/development.txt` because a board need not have a USB domain (the Raspberry Pi 5's
  USB hosts are in RP1's unit, [design-platforms.md](design-platforms.md)). Give the manifest source a part
  that only boards with a USB domain of their own take (`Platform#manifest_source`), so the rows have one copy.
* [Medium] the `record_volume` role's name is spelled by hand in `erx_device_record:image_record/1`
  (`"record_volume"`) and in `ERX_BOOT_SYSTEM_IMAGE_WORDS_MAX` (`sizeof("record_volume")`, as the pair
  words' bound spells its names), while the writer takes it from the generated
  `erx_mf_window_role_name`; only `boot_info_driver.c`'s longest-record check keeps them in step. Take the
  Erlang word from `?ERX_MF_WINDOW_ROLE_MEMBERS`, as `erx_blk_table:role/1` does, and have the ABI
  generator emit each enum member's name as a string macro the bounds can size.

## Security residuals

* [Low] manifest check, who may hold a raw input, gpu or network device (`tools/lib/erx/manifest.rb`,
  [design-system.md](design-system.md) property 8): `check_input_grants` holds the input facet to a display
  domain, since its holder reads every key pressed, but no rule limits which domain holds a device of role
  `input`, `gpu` or `network`, which is more than that facet. The `device_give` QEMU suite places QEMU virt's display
  unit on a configured ERTS domain and relies on that. Only trusted code runs in a development build; a holder rule
  for these roles would need device_give to place another unit.
* [Low] funnel, a 'DOWN' is matched by reference alone (`liberx/erx_funnel.c`, the target rule for
  `ERX_FUNNEL_PAYLOAD_MONITOR_P_EXIT`; ERTS's `erl_proc_sig_queue.c`): the funnel checks that a monitor
  exit's `from` is the sending domain's and that its reference is the receiver's node's, but not that the
  monitor was set up towards that domain, so a domain that learned or guessed a monitor's reference
  (ERTS's references are counter-based) could end another domain's monitor with a 'DOWN' of its own pid, which the receiver drops (`erx_session_relay` matches pid
  and reference) while ERTS has removed the monitor; the relay's watch of a master in another domain would
  then hang nothing up. Phase 2's kernel checks the monitor's connection.
* [Medium] manifest check, property 8's pin controller clause (`check_pin_controller`,
  `tools/lib/erx/manifest.rb`; docs/design-system.md property 8, docs/design-header-io.md "The
  pin controller and the console"): the check counts units only and passes a domain that holds
  only such units, so a domain that serves services, windows or sessions holds the GPIO page,
  and with it the console's pins, as long as it holds no other unit. The clause allows no
  holder but the system domain and reads the chip's pin table
  ([design-pinctrl.md](design-pinctrl.md#decisions), 2); bring the check to it. The Pi 4's
  development manifest gives `gpio` to the system domain.
* [Medium] design, decisions made on the user's behalf and awaiting confirmation: the list that follows the
  risks table of [design.md](design.md#risks-and-open-questions) (translating from Fiasco, login
  credentials, the device secret through the root task, the vault's partition in the extended partition,
  secure boot as an option, late errors on the Raspberry Pi 4, and every other entry of that list), the
  three that [design-kernel.md](design-kernel.md)'s open questions repeat (`CAPS` with one holder,
  the device-secret page, late asynchronous errors), and the two that
  [design-system.md](design-system.md) still calls provisional (the first-enrolment rule at the
  console's UART, and the rejection of a sealing call in the kernel). Put each to the user; a decision the user changes
  changes the document it names.
* [Low] manifest check, `signer` rows: a signer key of small order, or one that does not
  decode, would accept a seal anyone can make, as design-ssh.md's acceptance rules note for
  login keys. Have property 19's signer clause refuse such a key, with the eight small-order
  encodings as `add_login_key` refuses them, and a test; the rows land with the manifest's
  `apps` and `signer` rows ([design-packaging.md](design-packaging.md#the-package)).

* [Medium] `include/erx/dom.h`, `ERX_DOM_DEVICES_MAX` (8), `dom_boot_view.c`, `dom_core.c`: the per-domain device
  limit counts devices of no kind, which get no give, record or memory, so a unit that lists every transport on a
  QEMU virt page already holds 8 and the display domain can hold nothing more. Count driven devices only, since the
  limit bounds gives and records.
* [Medium] Domain service, a display domain's end keeps its outer budget: root's session holds a
  connection to the display domain on every development board (display_root), so its end keeps
  the domain's whole outer budget as remains (`erx_dom_retire_record`, `liberx/system/dom_life.c`),
  89 MiB on QEMU virt (`limits display`'s `outer 93368320`) and 49 MiB on the Raspberry Pi 4, until
  root's session answers, and the system principal's 1 MiB for an ended domain's outer budget does
  not hold the restart: the display stays down until reboot. The usb suite shows it: the display's
  fault under call tracing (the USB typed-stage item) is followed 1 ms later by `configured domain
  display did not start: no_memory`. Keep only what the survivor maps (the lanes) as remains, or
  size the reserve from the largest outer budget a session connects to.
* [Low] Domain service, a refused restart is not retried (`erx_domain_srv.erl`
  `start_configured/2`): a configured domain's restart that the library refuses, such as
  `no_memory` while more than one ended domain's outer budget still waits for its peer's
  disconnect (the system principal reserves one, `config/manifest/qemu-virt-development.txt`),
  is only logged, so the storage domain stays down and `/data` answers `eio` until the
  next boot. Retry it once the remains are disconnected, within its restart intensity.
* [Medium] Forged pids and `erx:owner/1` (erx.erl `owner/1`, erx_dist, the funnel): a pid's creation is a field its maker writes, while ERTS sends to a remote pid over the connection its node names, so a pid with domain A's creation and domain X's node passes an `erx:owner(Pid) =:= A` check and a send to it goes to X's connection, handing every local pid in the frame out to X (external.c's encoder) before X's funnel drops the frame as one to a dead name. erx_facet's caller check and the `erx:owner/1` doc's "a reply sent to a forged name goes to no third domain" rely on the creation alone. erx_domain_mints checks node and creation both. The fix by construction: the funnel refuses, at decode, a pid, reference or port whose node is a domain of this machine and whose creation is not that domain's, so `erx:owner/1` is authoritative for every caller; then the node check in erx_domain_mints can go.
* [Medium] code service, atoms from loads (`erlang/apps/erx_code/src/erx_code.erl`):
  `activate/1` makes each manifest name an atom before ERTS's loader checks it
  against the module's bytes, so a load the loader refuses still leaves up to
  `code_modules_max` atoms of at most 255 bytes, with no bound across loads; a holder of the
  install facet can exhaust the system domain's atom table, sized by the
  manifest's `atoms` (65,536 in the development manifest), and reset the
  machine. A successful load also makes every atom of each module's atom table.
  The fix reads the module name from the blob's atom chunk with a bounded pure
  parser, with a fuzz target, and compares it as a binary before any atom is
  made; the install facet's holders can already run code in the system domain.

* [Medium] system domain, the reset count
  ([design-system.md](design-system.md)): any successful login clears the
  count, including a web login, so a machine with a boot fault that lets
  the network come up can be kept out of rescue. Clear it only on a login at
  a secure line, or only after a login has lasted a while. Related: in a
  default release build no principal may open the system shell, so the
  rescue texts' "the operator can inspect the crash record"
  (design-system.md, design-platforms.md) holds only when the manifest names
  a system-shell principal; state that there.

* [Medium] domains, the funnel (`liberx/erx_funnel.c`, `otp/erts/emulator/sys/erxos/erx_lane_drv.c`): until RT8
  adds the queue quota (design-runtime.md edit 15), the funnel delivers every authorised frame whatever the target
  process already holds queued, so a peer can grow any process's queue it can name without bound, and two domains
  that send toward each other in a cycle grow each other's queues with nothing to stop them. RT8's quota leaves the
  next frame in the lane at a process at its quota; until it lands nothing bounds the queue. The lane driver's finish
  pauses there too, as at any time (design-runtime.md, "Connections in ERTS"); until the quota lands that clause
  of the finish has nothing to act on.
* [Low] domains, control records (`erlang/apps/erx_domain/src/erx_domain_links.erl`, the system
  domain's control writer): a domain that answers a record before reading it, such as
  `connection_unmapped` before its `connection_down`, lets the domain service send its next
  record while the earlier one is still in the domain's lane from the system domain, so that
  lane can hold more control records than its reserve, up to two per connection the domain
  holds. Only the liar's own lane is affected; the writer must then neither block the system
  domain nor drop a record, and its design has to show how.
* [Medium] Namespace, a facet's mount (`erx_facets:table/1`, design-files.md, "A facet's
  mount"): every lookup under a facet's mount, `/data` among them, goes to whatever pid the
  domain's registry holds for the facet, which a server domain minted, so a server that stalls,
  floods or answers as no file server holds its clients as the two `erx_file_remote` items above
  describe. Deferred to Phase 2 with them, when domains other than trusted ones serve facets.
* [Medium] Namespace, raw and resolved tables (`prim_file:erx_mounts/0` and `erx_table/0`): only
  `erx_ns` may read the raw mounts and every resolution must read the resolved table, and nothing
  checks either; a resolution of the raw table meets `{facet, _, _}` and fails with `function_clause`
  in `erx_on/2`. Add a build check that only erx_ns.erl calls `erx_mounts/0`, as
  test/host/ns_writers_test.rb does for the term's writers, and a facet case in
  test/integration/prim_file_compare.erl through the real `prim_file`. `erx_table/0` also rebuilds
  the table's list at every lookup, facets or not; return it unchanged when it holds no facet. The
  `mount` command shows a facet as the grant it resolved to, or `ended`, never by its name.
* [Medium] root's physical records (`liberx/backend/core/boot_manifest.c`, `devices_read`): whether a record is
  given or physical is the pointer test `kind != &hostlink_kind && kind != &line_kind`, a list each new physical
  kind must join; make it follow from the kind's table. `line_uart_read` keeps one UART, the last device parameter
  of the last line facet, and walks the facet parameter span a second time beside the boot view's checked walk
  (`liberx/system/dom_boot_view.c`, `boot_facet_parameters`): ask per device row whether a line facet names it, from
  one walk, when the one-grant limit is lifted.
* [Medium] manifest check, line grants (`check_line_grants`, `tools/lib/erx/manifest.rb`): a grant naming a UART
  that is not a PL011, the Pi's mini UART, passes, and the root then writes no line record; refuse a line UART of
  any compatible but the PL011's row of `erx_uart_kinds`.

## Planned features

* [Medium] web views, a paused view (`erlang/apps/erx_web_line/src/erx_web_line.erl`, the view's loop;
  [design-system.md](design-system.md#a-sessions-lines), "Views and ttys"): the design has a view charge its
  facet's account and, its share spent, pause, taking only the resume message and its facet's `'DOWN'`. No facet
  admits by its grantee's share of reductions yet (the facets item under Bugs), so no view is charged or pauses
  and there is no resume message. The view's charge and its paused receive land with that admission, with the
  design's test of a paused view ending at its facet's end, its table entry freed, and its seeded fault, a
  paused receive that takes only the resume message.

* [Low] grants, the rows held at boot, three verification rows unbuilt
  ([design-system.md](design-system.md#waiting-for-a-grant), "Verification";
  `test/erlang/erx_domain_tests.erl`, `erx_devices_pci_tests.erl`): the hold fixture checks a display a
  held row serves, not a session waiting on a `files` grant it serves, nor a held row whose start is
  refused at the release; no case restarts the PCIe process every 20 s with the fallback running; and
  the restart between a report's intake and its answer is not told apart from one before the intake
  (the fixture's bridge has no layouts). Build each with its seeded fault.
* [Medium] code server, the rest of its inputs (`erlang/apps/erx/src/erx_code_agent.erl`,
  `erxos_env/2`; `erlang/apps/erx_code/src/erx_code_target.erl`): the code server reads
  its boot information's `supervised` flag and its runtime's limits, but no reader of the
  domain's release manifest is built (blob by hash, and a release module's hash), so a blob
  only the release holds is asked of `erx_code`, which ends the load as `invalid`. This
  fails safe, and does not matter before `erx_code` sends loads to domains.
* [Medium] code service, start loads to supervised domains
  (`erlang/apps/erx_code/src/erx_code.erl`, `erx_code_target.erl`;
  `erlang/apps/erx_domain/src/erx_domain_pid.erl`; `liberx/system/dom_core.c`,
  `erx_dom_plan_boot_flags`): the code server's supervised path, the boot information's
  `supervised` flag, its reader, `erx_dist:supervised/0` and the library's build answer
  carrying the flag (`erx_dom_created_t`, `supervised` in `erx_domain_lib:created()`) and
  `erx_code`'s targets for start loads (`erx_code:started/4` and its effect layer) are
  built, but no domain is
  supervised: the domain service never calls `erx_code:started/4`, so no start load is
  sent, and the plan leaves the bit clear, which fails
  safe, since every code server then starts its domain at once on its release
  ([design-live.md](design-live.md#the-code-server), "Targets", "The effect layer").
  The design (design-live.md, "Targets"): a target is the domain service's name for it,
  `{configured, Row}` or `{domain, Id}`, derived from the domain's record
  (`erx_domain_core:target/1`), so a configured row's target outlives its domains'
  restarts, a restarted `erx_code` names it again, and the manifest's rows bound how many
  `erx_code` keeps. No release hash exists: a configured row boots one release while its
  overlay lives, so the hash would guard a state that cannot occur. A code server's
  answers to the load's alias cross as `ALIAS_SEND` frames, which the funnel admits on
  the `send` that encoding the load wrote
  (`liberx/erx_funnel.c`, the `ERX_FUNNEL_ALIAS_SEND` verdict row;
  `otp/erts/emulator/sys/erxos/erx_exports.c`, writer 1), delivered in the domain's
  envelope (`otp/erts/emulator/beam/erl_proc_sig_queue.c`, edit 16), as the inspection agent's answers already
  are (`erlang/apps/erx/src/erx_inspect_worker.erl`). Each load also hands the domain
  `send` on `erx_code`'s pid, as the sender of what `erx_code` sends it, and the word of
  publication on the lifeline; the routing by alias and origin keeps a domain to its own
  load, and what it can queue on `erx_code` is bounded only once the funnel's queue quota
  lands (the funnel item above), while the holders it leaves accumulate across its
  incarnations under the export table's connection-end gap
  ([todo-runtime.md](todo-runtime.md), "Runtime, export table", (2)); both items apply to
  `erx_code` from package 2 on. Packages 2 to 4 remain (package 1 carried the flag in the
  build answer, and package 2's targets are built but for one test), one reviewed commit each, in this order, since a domain supervised
  before the last would wait for a start load that nothing sends:
  2. **A busy connection** (`test/erlang/erx_code_tests.erl`): erx_code's targets for
     start loads are built (`erx_code.erl`, `erx_code_target.erl`), with design-live.md's
     "effect layer for start loads" and "The lifeline on a host node" cases and their
     seeds, but not its "A busy connection" case, which needs a peer node whose
     connection a helper has filled past ERTS's busy limit, with its seed, nor the
     restarted `erx_code`'s one log record that every overlay was dropped
     (design-live.md, "When `erx_code` ends"), which needs `erx_code` to tell a restart
     from its first start.
  3. **The domain service records and announces** (`erx_domain_srv.erl`,
     `erx_domain_core.erl`): `built/5` records the answer's `supervised`;
     `{domain_code_agent, Ref, Id, Agent}` records `code` for the live record `Ref` names
     unless it is stopping, and for a supervised domain calls `erx_code:started/4` with
     `erx_domain_core:target/1`; `started/4` sends only to a registered `erx_code`, since a
     send to an unregistered name raises `badarg` in the domain service. Test:
     design-live.md's "domain service's notice" case in `test/erlang/erx_domain_tests.erl`,
     over `erx_domain_fake_lib`, with its seeds, the wrong `Ref` and the missing `erx_code`
     among them.
  4. **The plan sets the bit** (`erx_dom_plan_boot_flags`): for a configured row whose
     `restarts` is above 0, and for no created domain. Tests: the configured-row, session
     and partial-boot expectations of design-live.md's "plan's flags" case in
     `test/host/dom_core_test.rb` with their seed, and design-live.md's "Start loads under
     QEMU" case, seeded by hand once, with the suite's boot timeout above `code_load_wait`
     so the second seed ends the domain with `{erx_code, unpublished}`. The development
     manifest's storage, display and pcie rows become supervised, so every suite's boot
     takes their start loads: run the full QEMU suite once, re-check the deterministic-mode
     transcript, and record `tools/erx bench boot` before and after. This package closes the item.

  Outside these packages: a created domain is supervised only once `erx_domain:create`'s
  `restart` is built and design-live.md's open decision "A created specification's
  target" is settled with it: the record that keeps a created specification across its
  domains, the name it carries into each, and the domain service's word to `erx_code`
  when it gives a specification up, which bounds the targets `erx_code` keeps. The code
  facet's loads and resets, with `serve`, `reply`, `stop_domain`, the store's hold on a
  load's blobs from `begin_load` to `end_load`, the resolution's
  `overlay` limit (the domain service's answer, read from the target's specification;
  the build answer carries only the `supervised` flag) and the domain
  release's manifest for the verdicts, belong to the item "code service, other domains
  and principals".
* [Low] code bounds, the model's words and depth against the funnel
  (`tools/lib/erx/abi_code_bounds.rb`, `liberx/erx_etf.c`): the bytes agree with stock
  OTP's `external_size/1`, but the words and depth the floors use are counted by hand from
  `erx_etf.c`'s heap sizes. Add a host test that runs the largest terms through
  `erx_etf_check` and asserts its words and depth do not exceed the model's.
* [Low] code service, overlays across reboots and `erx_code` restarts
  (`erlang/apps/erx_code/src/erx_code.erl`): design-live.md keeps every overlay, hot store and history in
  `erx_code`'s memory, so a reboot returns every domain to its release and an `erx_code` restart ends the
  supervised domains that run a published module, which restart on their releases
  ([design-live.md](design-live.md#the-code-server), "When `erx_code` ends"). Both fail safe: the domain
  ends or boots its release, the end is logged, no domain runs code its published overlay does not name, and
  the host reloads (`erx watch` at its next change). If a consumer needs loads to outlive them, add a snapshot
  of each principal's overlays that `erx_code` writes after it publishes, one file per revision so the newest
  whole file wins whatever order writes land in, and reads only when it starts; it never decides a load. Its
  reader of the data partition is untrusted input with a fuzz target. Deferred out of M10 until such a
  consumer appears.
* [Low] domain service, `served_kind/2` (`erlang/apps/erx_domain/src/erx_domain_srv.erl`, `init`): `Trees` lists the
  tree services of every server but is asked only about the system domain's, by name, so a configured domain's tree
  service named `log` or `inspect` makes the system's message service of that name minted as a tree grant, which
  fails and leaves the grantee without the facet; build it from `{system, Name, Interface}` rows, with a test.
* [Low] protocol apps, one clock seam (`erlang/apps/erx_net/src/erx_net_clock.erl`; the process edges of
  `erx_bt`, USB, Wi-Fi and `erx_ntpd`): each protocol process keeps one wake-up timer at its core's
  `next_deadline/1` (docs/design.md, "Deadlines in state"), and only `erx_net` has a clock module, with the
  virtual clock for deterministic runs and the one-timer `arm_by/2` and `hinted/1`. Whether the other apps
  share one clock module, and where it lives, is an open design question: a shared module is a new
  mechanism and needs a design, and `erx_net` must keep depending only on `kernel` and `stdlib`, since it
  is usable outside erXos.
* [Medium] system manifest, `abi/manifest.txt` ([design-usb.md](design-usb.md#mass-storage-reaches-the-file-servers)):
  the boot-time reader checks no `windows[].drive`; add the rule that it is not `mf_none` exactly when the window's
  role is `drive` ([design-drives.md](design-drives.md#manifest-rows)) before `erx_blk_drive` reads the field. The number itself is any value below `mf_none`,
  so nothing may index a table by it.
* [Low] system manifest, `tools/lib/erx/manifest.rb` ([design-system.md](design-system.md#the-manifest)):
  property 9's USB-domain clause, a release build's USB domain holding its controller's unit alone and running no
  file system, is not checked, since the check refuses every release build; it lands with the release build's
  confinement check, with its seed.
* [Medium] erx_domain boot order (`erlang/apps/erx_domain/src/erx_domain_srv.erl`, `handle_continue/2`;
  [design-system.md](design-system.md#boot)): the domain service starts every configured domain at once
  in the manifest's boot order, so on one CPU the runtimes slow each other and the login waits for the slowest.
  Two rules of the boot-order proposal are deferred: (A) a start waits for the
  configured domains serving its `files` grants to settle, each bounded by the machine's boot timeout, and (B)
  configured domains that no start needs are held until the boot is quiet. Measured under TCG on 1 CPU, once
  storage and network run on the interpreter, ordering gives 0.5 s to the prompt and 1.3 s to `/data`; on JIT
  images it gives 2.9 s (raw data: ~/erxos-history commit 34d0390, `boot-slow-2026-11-11`). Rule C, a session
  taking the console only with its namespace in place, is the design
  ([design-system.md](design-system.md#a-session-takes-the-console)).
* [Medium] code service, installed storage (`erlang/apps/erx_code/src/erx_code.erl`):
  the install arena, `erx_code:install_beam/2` and the runtime's
  `ERX_BOOT_INSTALLED_ONLY` refusal with `{error, not_installed}`
  ([design-runtime.md](design-runtime.md#code-in-the-system-domain), V5 of
  [design-live.md](design-live.md#invariants)) wait for M5, where the flag
  first takes effect. Until then `erx_code` loads the verified bytes from its own
  heap with `code:prepare_loading/1` and `code:finish_loading/1`, and any code in
  the system domain can still load bytes with `code:load_binary/3`. One package
  lands them together, tested in medium_boot: setting the flag alone would refuse
  `erx_code`'s own loads, the harness's probes (`code:load_binary` in
  `test/integration/runtime_literal_token_test.rb`, `prim_file_compare.erl`,
  `runtime_hosted_smoke_test.rb`, `tools/lib/erx/bench_guest.rb`,
  `production_image.rb`), which must go through the install facet, and even release
  code, since `prim_file`'s `read_file` copies a release file to the heap
  (`erx_prim_file.c`, `erx_copy_out`) instead of returning a binary over the mapped
  slice; the refusal itself goes in `erts_internal_prepare_loading_2`. The
  chokepoint check that only `erx_code` calls `install_beam/2` lands with it.
* [Medium] code service, other domains and principals
  (`erlang/apps/erx_code/src/erx_code_store.erl`): the store is one in-memory
  store for the system domain's installs, which the host link and `root`'s
  session (`load -s`, through its install facet) reach. Per-principal hot
  stores in memory objects from the principal's budget, the scoped code facet
  (a `code` service of `abi/services/code.txt`, `erx_domain_core:code_scope/3`)
  and with it `load -d`, which answers `no code facet`, one load at a time for
  each target with its 30 s deadline, atomic batches in every ERTS runtime,
  the log record of each load, the code server's fetch of pieces into other
  domains and its keep step, `erx_code`'s lifeline, and overlays per
  supervised specification, in memory, with their revisions, are not
  built ([design-live.md](design-live.md#code-from-the-host)). The host
  link and `root`'s session share the one store, so one holder's uploads can
  drop or free the other's.
* [Low] code service, load timeout (`erlang/apps/erx_code/src/erx_code.erl`): a
  caller of `erx_code:call/1` waits 60 s; a load still running then goes on and
  may finish, while the caller exits with a timeout. design-live.md ("The
  deadline") has the service end every load it starts and the facet wait
  for its answer with no deadline of its own; until then the install facet
  must report such a call's outcome as unknown, not as failed.
* [Low] code service, scope (`erlang/apps/erx_code/src/erx_code.erl`):
  `erx_code:history/2` checks no inspect facet: any caller in the system domain
  reads the system domain's history, and every other domain id answers
  `{error, scope}`. It goes through the caller's inspect facet once facets
  exist.
* [Low] code service, start (`erlang/apps/erx_code/src/erx_code_app.erl`): the
  release starts `erx_code` as an application, so every runtime that boots the
  system release runs one; it belongs to the system release's supervisor
  ([design-system.md](design-system.md#system-services)) once ordinary
  domains boot releases of their own.

