# TODO: Inspection and logging

Open work on the inspector, /proc, logging and the live tree. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Major initiatives

* [Low] inspection, the reporter kind `stopgap` becomes `backend` ([design-abi.md](design-abi.md#inspection-schema)):
  the `stopgap` member of `abi/inspection.txt` and its two declarations, the `stopgap` case of
  `abi/protocols/web.txt`, `tools/lib/erx/abi_emit_inspection.rb` (`stopgaps/0`, `stopgap/1` and the
  `{stopgap, Name}` reporter type), and the readers of `{stopgap, Name}` in Erlang and TypeScript
  (`erx_kernel_records.erl`, `erx_render.erl`, `erx_web_value.erl`, `web/src/record.ts`).


## Stopgap replacements

* [Medium] live and apps, the start table's tree in an inspect facet's scope
  ([design-live.md](design-live.md#the-inspect-service),
  [design-apps.md](design-apps.md#interfaces)): `erx_domain_core:inspect_scope/3` becomes
  `inspect_scope/4`, taking whether a facet row grants the grantee `start`, and a scoped facet becomes
  `{principal, P, Trees}` with `Trees` `[apps]` for a session template that holds `start`; the inspector's
  resolver answers `[apps]` and `[apps, Name]` to such a facet and nothing more, so `service NAME status`,
  `service -e` and `service -c`'s row names work in a release build's administrator session; with the host
  test of `inspect_scope/4` and the release-build QEMU case of design-live.md's tests.
* [Low] log, `kernel/core/log.c`: a task that logs past the rate with `erx_debug_log` and then exits loses the dropped count, which only
  the next admitted record shows, so its log can read as whole when it is partial.
* [Medium] log facet, `abi/services/log.txt`, the manifests, `erx_log_h` and `erlang/apps/erx/src/erx_syslog.erl`: the service serves `{write, Grantee, Records}`, the domain service mints `erx_log_facet` for `log`, and the manifests declare the `log` service, served by the system domain, but no facet row grants it yet, so other domains' proxies still write each record into the kernel ring ([design-log.md](design-log.md#writing)). Land together: the manifest rows; a floor limit in `log.txt` that a row's `max_request` holds one `write` of `log_write_max` records of `log_write_text_max` bytes, checked as `inspect_max_frame_min` is (a row below it drops legal writes unanswered); the proxy's `write`; and the grantee's principal and name from the domain service, which `erx_syslog` shows as `unknown` until then. The floor follows the proxy's batch, at most 16 KiB of text plus its encoding (design-log.md, "The proxy"), not `log_write_max` full records; design-log.md's default `max_request` of 16 KiB is that text alone and must grow by the encoding's overhead.

## Bugs by subsystem

* [Medium] tracing, `erx:trace/1` outside the system domain (`erlang/apps/erx/src/erx.erl`, `-define(TRACE_SCOPE, all)`;
  `erlang/apps/erx/src/erx_trace.erl`, `domains/0` and `domain_of/1`): the trace scope is the constant `all` and
  the traceable domains the constant `[?SYSTEM_DOMAIN]`, on the premise that every shell runs in the system
  domain, which the session_domain QEMU suite shows false. A trace started in a session runtime claims scope
  `all` and counts its own runtime's pids as domain 4's. Take the scope from the caller's trace facet and the
  domain from the runtime's own domain id, and drop the comments' premise.
* [Medium] inspection, `erx:inspect/2`'s options (`erlang/apps/erx/src/erx_inspector.erl`, `inspect/2`): through
  the facet `erx_inspect_query` refuses an unknown key, a bad `offset` or `limit` with `{error, badarg}`, while
  in the system domain and on a development host nothing checks them (`#{foo => 1}` answers `ok`, a bad
  `offset` on `[kernel, log]` answers `invalid`), so programs tested on the host meet behaviour sessions do
  not have. Run the decoder's option check once in `inspect/2` before routing either way. `limit` is admitted
  but nothing reads it.
* [Medium] inspection, `timeout` in the system domain (`erx_inspector.erl`, `route/4`;
  `erx_inspect_worker.erl`, `await/1`): it narrows only the worker's deadline for agents; the view call
  (up to `inspect_agent_wait`) and the local collectors run before or outside it, so the caller can wait
  longer than its timeout. Give `await/1` an `after Wait` answering `{error, failed}`, as the facet path does.
* [Low] inspection, a short `timeout` through the facet (`erx_inspector.erl`, `route/4`): the caller gives up
  but the facet's worker runs on to `inspect_query_max` and holds its in-flight slot, since the timeout is
  not sent, so a program polling with short timeouts can make its session's other queries answer busy.
* [Low] inspection tests, scoped `[cpus]` (`test/erlang/erx_inspector_tests.erl`): stock does not load
  `erx_object_info`'s NIF, so inspect/3 and entries/2 never run for `[cpus]` and `[cpus, N]` at a scoped
  scope, a scoped `/proc` root is not listed, and the facet path of `inspect/2`'s `timeout` is untested; a
  stub collector for `erx_kernel_records:cpus/0` would cover them.
* [Low] inspection consumers, a busy facet (`erlang/apps/erx/src/erx_inspector.erl`, `route/4`): a request past
  the inspect facet's `in_flight` answers `{error, busy}` at once and no consumer retries it, so a browser with
  many views open can make the same session's `top` print `[inspector busy]` and its `/proc` files `[error]`.
  A facet that crashes, through a fault in its callback (`erx_facet:loop/1`), reads as one revoked: `no_facet`,
  so the session's `/proc` is `enoent` and `top` prints `[no inspect facet]` while its grant still names inspect.
* [Medium] inspection schema, `abi/inspection.txt`: design-live.md's path table and
  [The runtime agent](design-live.md#the-runtime-agent) name `[processes, Pid, source]`, the source lines
  around a process's location from `erx_source`, but the schema declares no such path, so the inspector, and a
  domain's `erx_inspect_agent` through it, answer it `{error, scope}`. Declare the path and its collector.
* [Medium] inspector, a domain's record (`erlang/apps/erx/src/erx_runtime_records.erl`, the system domain's;
  `erx_inspect_worker.erl`, `given/2`, another domain's): a domain record's `threads` is `unsupported`,
  and the system domain's own record has no name, principal or state, since the domain service's table does
  not hold the system domain.
* [Medium] query worker, `erlang/apps/erx/src/erx_inspect_worker.erl`: an agent's answer the worker refuses is
  dropped but not counted where an operator can read it, which design-live.md ("The runtime agent") asks; a
  `{principal, P}` query whose view the domain service does not give answers `{error, scope}` for P's
  domains' paths rather than an unknown or failed status; `[domains, D]` of a domain the view lists as ended
  answers `{error, scope}` while its record is kept; an agent's `{error, scope | unsupported}` for its own
  `[domains, D]` becomes the whole answer rather than its runtime attributes' status; and `await/1` waits for
  the worker with no deadline of its own, trusting the worker's `inspect_query_max`.
* [Medium] inspect agent, `erlang/apps/erx/src/erx_inspect_agent.erl`: a session's agent does not relay its
  programs' and pipes' attributes ([The runtime agent](design-live.md#the-runtime-agent),
  `[domains, Id, programs]`), and below `[domains, Self]` it asks `erx_inspector`, whose `collects_domain/2`
  collects a domain's paths only in the system domain, so those paths answer `{error, scope}`.
* [Medium] live, `erx_source` (`erlang/apps/erx/src/erx_source.erl`): nothing ties a module's `src` file to
  its beam, so an edited, unrecompiled source shows lines the module was not compiled from, and a location in
  an included file is looked up by base name in the module's own `src` and `include`, so a header of another
  application with the same base name shows its lines. Have the build record the source's digest in the beam
  and refuse a mismatch, and accept an included file only when its directory is the module's own; record the
  rule in design-live.md, "From a process to its source".
* [Medium] live, `erx_source`: a reload and purge between the process's location read and the module's
  version read shows the old version's line against the new source; lines/1 rechecks the version and old code
  around the source read, which narrows the window without closing it. A `process_info` item that returns the
  current location with the identity of that module instance closes it, as the design's process record
  ("its module's version") implies.
* [Medium] live, the shortcuts' collision test (`test/erlang/erx_shortcut_tests.erl`): the shell's commands
  come from `shell:local_func/0`, which leaves out `ft`, `td` and `exit` that `local_func/8` handles before
  `shell_default`; derive the names from `local_func/8`'s clauses, in the collision check and in the
  resolution test's names.
* [Low] live, the shortcuts' resolution (`otp/lib/stdlib/src/edlin_expand.erl`, `erx_shortcuts/0`): the
  shortcuts reach `edlin_expand` through `shell_default`'s `erx_shortcuts` attribute, read at each call, and
  `beam_lib:strip` drops the attribute chunk, so a stripped `shell_default` would silently resolve
  `trace(P, true, [send])` in a function defined at the prompt to `shell_default:trace/3`. Nothing strips
  beams today; a compile-time single source shared by `shell_default`'s export and `edlin_expand` (an
  `.hrl` cannot serve both, since `-export` takes `F/A` and the resolver tuples) would remove the read.
* [Low] live, `erx_source`: the source read follows symbolic links and checks the size before reading rather
  than reading at most the cap, and a rendered line is not cut at a width, so a 4 MiB line (32 MiB of
  expanded tabs) reaches the console whole. Read with `file:read(Fd, Max + 1)` after `read_link_info`, and cut
  each line with a visible marker.
* [Low] live, the QEMU check of `erx:source/1`: the release ships no `src`, so a console point must compile a
  module into a `src`/`ebin` tree on a writable file system and show a waiting process's line; it also needs
  OTP's `otp_SUITE:undefined_functions` under `check-oracle` to accept `shell_default`'s call of
  `erx:source/1`.
* [Medium] live, `erx_code`'s deadline ([design-live.md](design-live.md#code-from-the-host), "The
  deadline"): a published overlay that wedges its domain after every start makes every load that would fix it
  time out, so the code service discards each fix and stops the domain, whose next domain starts from the
  same overlay, until the restart intensity leaves the specification down. A reboot clears an overlay kept in
  memory but keeps a principal's persisted one, so that principal's specification wedges again after it.
  Recovery needs a way to discard a principal's overlay, or to start its specification without it, that does
  not go through the wedged domain.

* [Medium] `docs/design-abi.md` [Inspection schema](design-abi.md#inspection-schema): `[kernel, crash]` and
  `[kernel, trace]` repeat the fields of the crash-record and trace-record layouts, and the grammar has no form
  that takes a kind's attributes from a root `layout`, so they would be copied by hand. Add one (`fields @layout`)
  before those kinds are declared.
* [Medium] `erlang/apps/erx/src/erx_inspector.erl` [Inspection records](design-live.md#inspection-records):
  `record()`'s `entries` is answered only for `[kernel, log]`; a domain's pids, also marked `entries`, are still
  a listing's children, and no query takes `limit`, so a page is always erx_schema's 1,000. Answer every
  `entries` path with entries and take `limit` in `erx_inspector:inspect/3`.
* [Low] `docs/design-live.md` [The /proc tree](design-live.md#the-proc-tree): the name encoding writes "every
  byte outside `A`-`Z`, `a`-`z`, `0`-`9` and `_+,:=@-`, and a leading `.`" as `%XX`; `.` is outside that set, so
  the leading-`.` clause says nothing, unless `.` was meant to stay plain after the first byte. `erx_schema`
  follows the letter (every `.` is `%2E`); settle it before `erx_procfs` writes names.
* [Low] inspection bindings (`tools/lib/erx/abi_emit_inspection.rb`): `erx_schema` and the host tool's table
  (`build/gen/tools/generated/abi_inspection.rb`) are generated; the bounded C record builders of
  [design-generation.md](design-generation.md#inspection-and-diagnostics) are not, since their consumer is
  erXos's kernel, and the host table has no Ruby validators yet. Generate each with its first consumer.
* [Medium] inspection, `erx_schema` (`tools/lib/erx/abi_emit_inspection.rb`): `validate_record/1` ignores an
  attribute's `build` (a release record may carry a `development` attribute). `cpu_index`'s bound 63 is written
  beside `@cpu_limit` because the grammar has no `@limit - 1`. The domain kind lacks design-live's death record and
  group usage.
* [Medium] kernel reports, tests and collector (`erlang/apps/erx/src/erx_kernel_records.erl`,
  `liberx/backend/core/object_info.c`): design-live's host test that every bit of each backend's `erx_info_partial`
  names an attribute listing a stopgap for `kernel` (seeded on `guarantee`) is missing, as are design-fiasco's
  Kernel reports seeds for `capacity_mcpu`'s bit and for a failed `l4_scheduler_info` through a test hook, and any
  mutant of the Fiasco-only `service_object_info` and `erx_fiasco_task_thread_map`. `derive/2` restates the budget's
  derived formulas apart from `abi/inspection.txt`'s `derived` inputs; emit them from the schema, or at least test
  every derived attribute with all-ok inputs. `erx_fiasco_pool_put` holds `held_pages` at 0 on a put of a page never
  taken, a liberx bug it hides rather than reports. The group topic maps every `erx_group_info` failure to
  `ERX_ENOTSUP`, not `ERX_EINVAL` alone; a CPU listing ends at the first gap in the map; the root's window to
  `service_object_info` and `service_log_read` is checked only for 0 and wrap (trusted root). The QEMU check that
  calls `erx_kernel_records` from `erl` at the console is not written yet.
* [Medium] inspector (`erlang/apps/erx/src/erx_inspector.erl`, `erx.erl`, `erx_process_records.erl`):
  the inspector run in a domain other than the system domain lists that domain's own processes
  (`runtime_domain/0`, from `erx_dist:boot/0`), but names its kernel records and domain record as the system
  domain's (`erx_kernel_records:system_domain/0`, a constant 4), so the scope `{principal, P}` of a session's inspect
  facet, which the query worker resolves to that principal's domains, reaches none of them: `erx:i` there answers `{error, scope}` for them and
  `top`'s header prints `-`. Read the kernel records of the caller's group, budget and threads, and collect
  `[domains, Id | _]` for the runtime's own domain. A process listed in a session links to
  `/proc/processes/<pid>` in the browser, which names it; `[domains, Id, processes]`, declared with paginated
  entries rather than children, needs the web client's entries view (W3) before a browser shows it. `erx_inspector:runtime_domain/0`
  reads the boot page, and `collect/2`, `entries/2` and `proc_id/1` each call it, and `is_system_runtime/0` reads it too; read the
  domain's (`erx_kernel_records:system_domain/0`, a constant 4), so the local scope `[Id]` a session's inspect
  facet has (`erx:cap(inspect)`) reaches none of them: `erx:i` there answers `{error, scope}` for them and
  `top`'s header prints `-`. Read the kernel records of the caller's group, budget and threads, and collect
  `[domains, Id | _]` for the runtime's own domain. A process listed in a session links to
  `/proc/processes/<pid>` in the browser, which names it; `[domains, Id, processes]`, declared with paginated
  entries rather than children, needs the web client's entries view (W3) before a browser shows it. `runtime_domain/0`
  reads the boot page, and `collect/2` calls it after the scope decision; read the
  domain once at the edge (one exported reader) and pass it in. The system domain's runtime is the node
  `system@<host>` at creation 4 (`tools/lib/erx/system_domain.rb`), yet `erx_process_records:proc_id/2` still
  names a pid of its own runtime by the runtime's domain rather than by the creation the pid carries; drop that
  special case wherever the creation already is the domain. The browser shows a
  process's links and monitors, lists of `proc_id()`, as tuples (`erx_web_value`), not as pid presentations.
  The listing page (1,000) and the scoped machine paths (`[]`, `[cpus]`, `[cpus, N]`, `[processes]`) are written
  in `erx_inspector`; have `erx_schema` export the page and the schema mark which machine paths a scoped facet
  reads. A thread past a partial listing's end is answered `{error, scope}`, as one that does not exist.
  Not collected yet: `[groups]`, `[budgets]`, a domain's modules, exports, connections
  and paginated `[domains, Id, processes]`; `erx:ps/0` and `erx:domains/0` with their
  `shell_default` shortcuts, which `test/erlang/erx_shortcut_tests.erl` lists as pending.
* [Medium] /proc (`erlang/apps/erx_files/src/erx_procfs.erl`, `erx_procfs_core.erl`; design-live's
  [The /proc tree](design-live.md#the-proc-tree)): `kernel_safe_sup` starts the tree at boot in every
  runtime, in the system domain over a local query worker at scope `all`; the system shell's tree should instead
  start with the console, presenting the system-shell facet, and be mounted only in the system shell's namespace.
  The design leaves open: a text entry spelled `status`, a module of that
  name, which the directory's `status` file shadows; how many entries `.partial` says were left out, which the
  inspector does not count (the file says `left_out [unknown]`); and what the `status` file of a path the inspector
  answers `{error, unsupported}` holds (one line, `[unsupported]`). Not built: `source`, `crash`
  and `/proc/kernel/crash`, which have no inspector path yet. `/proc/kernel/log` keeps a file's oldest lines when
  its 64 KiB cut applies, as every file does, so a full ring whose escaped lines pass 64 KiB ends in `[partial]`
  where the newest lines would be, which are the ones `dmesg` is read for; cut a log file at its start, after a
  `[missing N]` line, instead. An open asks the inspector in the
  grant's process, so a slow query holds the grant's other requests, and each walk step collects a record (or, for
  a CPU or thread, the listing) only to learn that it exists; the machine record is asked once per status open for
  the build's projection. The tree's grant is a direct child of `kernel_safe_sup` and shares its restart budget
  with `erx_ns` and `/tmp`; give it a supervisor of its own. The 256-snapshot bound counts a directory like a
  status file, but a `/proc/processes` snapshot is a list of about 17 words an entry, so 256 of them over about
  1,000 processes pass the grant's heap limit (estimated); weigh snapshots by size or pack listings into one
  binary. Smaller: a listing's
  `status` file is empty; an open `.unknown` whose listing has since come whole still reads `[unknown]`; statfs
  says `namelen` 255 while an encoded name reaches 765 bytes; `erx_fs_grant`'s lopen does not clunk a handle whose
  reply its check rejects, as lcreate does; and `erx_file_remote`'s read of a size-0 file takes a short piece as
  its end, so an error after the first unit of a piece reads as end of file where stock answers the error.
* [Medium] kernel reports, `liberx` and `abi/erx_abi.txt` (design-abi's
  [Inspection schema](design-abi.md#inspection-schema)):
  `erx_info_budget` declares `kind`, `guarantee`, `cap`, `used`, `carved`, `lent` and
  `threshold` but not `pinned`, which design-kernel's [Budgets](design-kernel.md#budgets)
  and the budget core's `erx_budget_counters` report. Add the field; until then the
  inspector shows `pinned` as `unsupported`. `erx_info_machine` has no field for `development` or `dma_profile`, since the
  design does not say how a boolean or a closed atom set travels in a report, so both read as clear bits; and the
  `group` kind declares only the five attributes `erx_info_group` carries, not design-live's throttling,
  executors, child groups or the policy's intent. `tools/lib/erx/abi_inspection.rb`'s report check compares
  names only: nothing ties `erx_info_cpu`'s `ready_threads` count 64 to `urgency_counts`' 64 (both copies of
  `@urgency_max + 1`), the `capacity` type's 64000 to `@cpu_limit * 1000`, a field's width to its integer type's
  range, or says how `build`'s 8 raw bytes render as `text build_id`; require an array field exactly for a list
  attribute, with its count, and a scalar wide enough. The check exempts a field named `id` in any report layout,
  wider than design-abi's counting topics. design-kernel's [Threads](design-kernel.md#threads) declares
  `erx_thread_state_t` and `erx_wait_kind_t` with `ERX_TS_*` names that clash with the generated ABI's typedefs and
  `ERX_THREAD_STATE_*`; it should use the ABI's. `erx_backend_group_report`'s reported bits are pinned only by the
  `function_api` guest case, not by a host test in `test/host/group_report_test.rb`.
* [Low] `docs/design-live.md` [The /proc tree](design-live.md#the-proc-tree): an Erlang module named `status`
  encodes to the entry `status`, the same name as the `status` file of `/proc/domains/N/modules`. Encode a name equal
  to a file the tree itself writes (for example as `%73tatus`).
* [Low] Inspector, `erlang/apps/erx/src/erx_inspector.erl`: no path shows a runtime's
  `erx_dist:exports_refused/0` (hand-outs and spawns the full export table refused) or
  `erx_dist:names_dropped/0`; both are BIFs only. Give each domain's runtime counters a
  record under `[domains, D]`.
* [Medium] live, host-link handles: the handles of the host link's calls
  on facets (console, code, inspect, trace, install, update and domain),
  `{'$host_cap', N}`, `{'$pid', Text}` and `{'$ref', Text}`, are tuples
  inside term payloads, so a domain's agent can emit a literal one that
  the host tool cannot tell from a facet. Carry them out of band, as
  kernel capabilities pass as typed items. File access over 9P carries no
  such handle, its handles being 9P's fids
  ([design-live.md](design-live.md#the-host-link)).
* [Medium] live, host-link payload check (`erlang/apps/erx_uart/src/erx_hostlink_payload.erl`):
  until `liberx`'s `erx_etf` (`liberx/erx_etf.c`) is reachable from the
  system domain's Erlang, a control payload from the host
  is checked by a size bound, `binary_to_term/2` in safe mode and a walk
  that refuses pids, references, ports and funs, not by the host grammar,
  and it is decoded onto the heap before the resident limit sees its
  size: a 16 MiB payload of empty lists builds about 256 MiB. Replace
  `erx_hostlink_payload:measure/1` with `erx_etf`'s check with the host
  grammar, which gives the decoded size before decoding; until then the
  effect layer may run the check in a process whose `max_heap_size` is the
  room left ([design-live.md](design-live.md#the-host-link)).
* [Medium] live, host-link resident bound
  (`erlang/apps/erx_uart/src/erx_hostlink_session.erl`): the design's
  "The host link" says the credit, the call window and the resident limit
  together bound what a host can make the target hold, but a hello forgets
  the replaced session's executing calls and a cast holds no reservation
  once handed on, so a host that fills the window, sends a new hello and
  repeats holds up to 32 MiB more each round. Count a replaced session's
  outstanding calls, matched by their serial, against the next session's
  room until their `call_done` arrives, and give a cast a reservation
  until its handler has taken it.
* [Medium] live, host-link session (`erlang/apps/erx_uart/src/erx_hostlink_session.erl`):
  choices the design leaves open, to settle in design-live.md's "The host
  link":
  * Funs and ports in a reply are rendered `{'$fun', Text}` and
    `{'$port', Text}` beside the design's `'$pid'` and `'$ref'`, and a reply
    that fails the host grammar or the message limit becomes
    `{error, system_limit}`; `message_max` bounds both directions, so a
    release build's 8 KiB limit also bounds replies.
  * The root (`erlang/apps/erx_uart/src/erx_hostlink.erl`) answers
    `{open, Name}` for a facet the design lists whose service does not
    exist yet with `{error, unsupported}`, and any other request, an
    unlisted name included, with `{error, badarg}`.
* [Medium] live, host-link sink check: "only the host link's own sink
  writes its UART" holds because erx_uart_sup alone asks for the `hostlink`
  device record and hands it to erx_hostlink, which owns its erx_pl011, but no
  build check refuses another
  module that names that record, and erx_pl011 writes whatever any process
  sends it as `{erx_console_output, From, Bytes}`, so the rule rests on no
  other process learning the driver's pid. Have the driver take output only
  from its owner (an alias the owner holds, since `From` is the console's
  reply token), which makes the rule hold for both lines by construction,
  and add the record check beside the `device-posters` chokepoint.
* [Medium] live, host-link facets in a release build
  (`erlang/apps/erx_uart/src/erx_hostlink.erl`, `root/2`): the root offers
  the install facet and takes 16 MiB messages whatever the build, where
  design-live.md gives a release build's host only the facets its manifest
  lists, by default none, and an 8 KiB message limit. Take both from the
  manifest (its `development` flag or a facet list) once the system domain
  can read it.
* [Medium] live, `tools/erx watch` (`tools/lib/erx/code_watch.rb`,
  `tools/lib/erx/code_commands.rb`) and the code service: after the guest
  reboots, its installs are gone, but the watch sends only sources that change
  from then on, and a module whose bytes did not change is loaded again, whose
  second load purges and ends processes still in its old code. design-live.md
  has the watch open a connection for each change and load its whole set
  ("One load, three routes"), and the loading runtime skip a module whose
  current hash, its file name, is the one asked for ("What is already
  current"); build both.
* [Low] live, `tools/erx load` (`tools/lib/erx/code_load.rb`): the store may
  free a blob that `missing` reported as held, to make room for a later blob
  of the same batch (erx_code_store.erl), and the load then answers
  `{error, {missing, Hashes}}`; send the named blobs, when all are of the
  batch, and load again once.
* [Low] live, `tools/erx load` and `watch` (`tools/lib/erx/code_commands.rb`):
  `--tty` (raw mode through `stty`), which design-live.md ("One load, three
  routes") gives them, is not built, and `--socket` takes only `--system`
  until the host link's session opens a code facet; `--ssh --domain` runs and
  is refused on the machine with `no code facet` until the code facet exists.
* [Medium] live, the Raspberry Pi 4's host link (`tools/lib/erx/boot_partition.rb`,
  `command_line_entry`): QEMU's `raspi4b` model has no UART3, so no automated boot has run the
  host link's record on the board, and the firmware's hand-over of `cmdline.txt` as
  `/chosen/bootargs` to a `kernel8.img` started through BL31 is unverified. Boot a development
  card with an adapter on UART3 and Bluetooth active (UART0's interrupt line is shared with
  UART3's), check that it boots and that `tools/erx load` reaches the board, and add the step
  to the Pi manual checklist.
* [Low] live, the root's command line (`liberx/backend/fiasco/boot_args.c`, `next_word`;
  `kernel/core/boot_place.c`, `erx_boot_args_cut`): words split on spaces alone, so a
  `cmdline.txt` edited with a tool that ends the line with a newline or CRLF may refuse the
  boot with a malformed `erx.` word if the firmware keeps that byte; treat space, tab, CR and
  LF as separators in both.
* [Low] live, host-link client (`tools/lib/erx/hostlink_client.rb`): it has no
  host tests of its own, only the production image's host link boot; drive it
  against `erx_hostlink_session` on stock OTP or a scripted IO (credit, hello
  repeats, stale grants). It keeps replies to calls nobody awaits without a
  bound, and a payload it refuses loses the rest of that read's frames.
* [Low] live, host link (`erlang/apps/erx_uart/src/erx_hostlink.erl`): the
  terminal stream's bodies are dropped uncounted until a console session
  consumes them, so the inspector cannot see the loss.
* [Low] live, host link's 9P bridge (`erlang/apps/erx_uart/src/erx_hostlink_9p.erl`):
  its counts (discarded, stray replies) reach no inspector record yet; and
  `tools/erx files` serves one client at a time and reaches only QEMU's UNIX
  socket, like `load` and `watch`.
* [Low] live, host link's files stream (`erlang/apps/erx_uart/src/erx_hostlink_files.erl`): a
  `files_trees` configuration that is not a list of atoms is refused at each session's bridge start, one
  crash report per session, and the host's 9P client hears nothing until its deadline; check it once when
  `erx_hostlink` starts and refuse to start, as a bad build word does.
* [Low] live, 9P client (`tools/lib/erx/ninep_client.rb`, `version`): an agreed msize has no lower bound, so
  below 24 `read_file`'s read size reaches zero or goes negative and packs as a 4 GiB count; refuse an agreed
  msize below 4096, as the bridge refuses one offered. `max_bytes` is not validated either.
* [Low] live, `erx:trace/1` (`erlang/apps/erx/src/erx_trace.erl`, `await_start/3`): `{error, {failed, Why}}`
  returns the trace process's raw exit reason, which the shell prints with printable Unicode unescaped and
  keeps in its history, a fault's reason with the trace's buffers included; return a bounded, escaped
  reason, or `killed` or `fault`, and log the whole reason, before traces are scoped (M5).
* [Low] live, host link (`erlang/apps/erx_uart/src/erx_hostlink.erl`, `bounded_measure/1`): a fault of
  `erx_hostlink_payload:measure/1` is refused as `{failed, Why}` but counted with malformed payloads as
  `bad_payload` and its reason dropped; count it apart or log it once.
* [Low] live, host link's 9P bridge (`erlang/apps/erx_uart/src/erx_hostlink_9p.erl`),
  review findings open: the namespace entry's `ro` is not applied; the bridge's own clunk replies
  count as stray; the tree lookup reads the namespace table on each attach;
  no `proc` tree is mounted yet; and the system manifest has no field for
  the trees a release build lists, so a release build serves none.
* [Low] live, host link's 9P bridge (`erlang/apps/erx_uart/src/erx_hostlink_9p.erl`):
  the bridge reads the whole manifest at each session's start;
  design-live.md still says the host tool counts credit from its hello's
  first byte, where it now counts from the hello's reply.
* [Low] live, host-link driver (`erlang/apps/erx_uart/src/erx_pl011.erl`):
  the design's driver buffers at most 64 KiB of received bytes and drops
  and counts beyond that (design-system.md, "Drivers"); erx_pl011 sends
  every drain to its owner's mailbox, which only the host's keeping to its
  credit bounds. The console's line has the same gap.
* [Medium] live code, overlay publication: specify reconciliation when a
  domain loads a candidate but its acknowledgement is lost, and make the
  inspector distinguish the running module set from the published overlay
  used at restart. Ordinary domains may retain a partial candidate after
  failure; evaluate atomic module loading for eligible batches and a fresh
  domain for changes requiring new application state. Loading an older
  hash does not restore application state or undo external effects
  ([design-live.md](design-live.md#code-from-the-host)).
* [Low] live, the host tree over virtio-9p: QEMU's 9p server on Darwin
  and FreeBSD hosts translates only six errnos to Linux numbering (its
  `errno_to_dotl` has a FIXME), so an error from `/host` on a macOS host
  may carry a host errno. The host-tree bridge treats an errno outside
  the codec's list as `eio`. Record it as QEMU's upstream defect and
  re-check it at each QEMU pin
  ([design-live.md](design-live.md#files-between-the-host-and-the-machine)).

## Security residuals

* [Medium] logging, `erx_report` (design-log.md, "Reports carry no term"): every domain but the
  system domain takes the filter at boot (edit 57 of design-runtime.md). What passes whole:
  `logger:log_allowed/4` (`otp/lib/kernel/src/logger.erl`) forwards an event whose group leader
  is on another node before any primary filter runs; OTP's legacy `error_logger` calls
  (`application_master.erl:407`, `file_server.erl`, `gen.erl:790`) carry no `otp` domain; so do
  erXos's own events that print a raw term; and in the system domain, which takes no filter, a
  process that holds another domain's bytes keeps them out of its own reports only through its
  `format_status/1` (edit 75), so the supervisor's `child_terminated` report still quotes the
  child's raw exit reason (`supervisor.erl:318-324`, `:1426`), and with `error_logger_format_depth`
  set `proc_lib`'s `receive_messages/1` (`proc_lib.erl:1046`) takes the mailbox of a process that
  set `process_flag(sensitive, true)` and has no `format_status/1` into its crash report, which
  stock OTP does too. Also whole in a process that hides its terms: `gen_server`'s
  `no_handle_info` warning shows the raw message; `gen_event`'s report of a handler's crash shows
  the raw stack trace; an exit reason `{Reason, Stack}` keeps its frames' arguments wherever it is
  quoted, since exit reasons stay raw; process labels and logger metadata pass as they are; and
  the protection rests on `'$initial_call'` and `'$erx_status_module'` in the process dictionary,
  which the process itself can erase; and a process whose initial module is not the module
  `gen_statem:enter_loop` or `gen_server:enter_loop` enters is decided by its initial module in
  its crash report (no erXos or OTP caller does so: each enters `?MODULE`). Only a process whose module exports `format_status/1` hides its terms, and nothing checks that every system-domain process that holds another domain's bytes exports one: the chokepoint `format-status-through-report` checks only that each `format_status` goes through `erx_report:status/2`; hiding by default in the system domain would close it. The filter is an entry of the primary filter list, so a
  filter an application adds later (`ssh_app.erl:114`) runs before it and sees the report
  whole, `logger:reconfigure/0` and `set_primary_config(filters, _)` empty the list for a
  moment or for good, and with `filter_default => stop` an OTP report no other filter logs is
  logged as its summary where stock OTP drops it. Make the rewrite a fixed stage of
  `logger_backend:log_allowed/2` ahead of the list (edit 57), which closes all three, run it
  before remote forwarding; have the supervisor's report pass the reason through the child's
  `format_status/1` when the child's module is known, and `receive_messages/1` honour
  `sensitive`.

* [Medium] system log on Fiasco ([design-log.md](design-log.md#the-store)): a development build's `data`
  grant to `root`'s sessions covers the whole of `/data`, read-write, so those sessions reach the log's store at
  `/data/log` past `erx_logfs`: they can rewrite, truncate or forge either family, the kernel's included, so the
  store's one writer and its attribution hold only for what no such session touched. Development builds run
  trusted code alone. Closed by a release's manifest granting no session the whole volume, so each holds only
  its home, with the test that root's session finds no `log`; it blocks 0.2, whose littlefs release contract roots every grant
  ([design-stopgap.md](design-stopgap.md#release-contract)).
* [Medium] erx_logfs ([design-log.md](design-log.md#security)): `/var/log` serves the store's bytes as stored.
  The log service stores only lines that passed the line escape, but a storage domain, or a holder of write access
  to `/data/log`, can put terminal controls in a stored file that `cat /var/log/messages` writes to a terminal.
  Phase 1 domains are trusted and root's whole-`/data` grant reaches the same bytes, which a release manifest
  grants no session. Close it: check each byte against the line escape at read, serving `?`, or keep the store
  where only the system domain writes.
* [Low] inspect service, the runtime agent leg ([design-live.md](design-live.md#the-runtime-agent)): a
  domain's inspection agent takes questions one at a time, so a holder of scope `all` that asks without pause
  keeps the agents busy and another holder's runtime attributes read `{timeout, 500}`, and a domain can answer
  slowly on purpose to the same effect, so that a listing at scope `all` waits 500 ms for each stalled domain
  and ends `partial` at `inspect_query_max`. Development builds run trusted code only; settle it with the
  scheduling of service work on erXos's own kernel.
* [Medium] The kernel log has no reader gate on Fiasco (`erlang/apps/erx/src/erx_log_records.erl`,
  `liberx/backend/fiasco/service.c`): `erx_log_read` takes a resource with the `TRACE` right on erXos's kernel
  ([design-kernel.md](design-kernel.md#console-log-and-panic)), but the Phase 1 service ignores it and reads
  for the root, so `[kernel, log]`, `/proc/kernel/log` and `dmesg` show every domain's log text to any caller
  whose inspect facet has scope `all`. Every such caller is root code today. A less-trusted session, once there
  is one, needs a policy gate on that path, as FreeBSD's `security.bsd.unprivileged_read_msgbuf` gates `dmesg`.
* [Medium] The kernel log's limit is per space, and the ring is shared
  (`kernel/core/log.c`, `erx_log_rate_t`): 16 KiB per second lets one space
  push every record, the kernel's included, out of the 64 KiB ring in about
  four seconds, N spaces in a fraction of that, and a domain that creates
  and ends sub-spaces gets a fresh allowance with each one. Nothing is lost
  silently, since a reader is told how many records it lost, but a space that
  floods and then ends never reports its own drop count. Charge the rate at
  the domain, a sub-space drawing on its parent's state, and show a space's
  count through inspection, when the kernel handler and spaces land.


## Planned features

* [Low] live, `erx:i()`'s processes section (`erlang/apps/erx/src/erx_inspector.erl`, `overview/0`;
  `erx_inspect_worker.erl`, `processes/1`): it prints the `[processes]` listing's first page, which an
  ordinary listing is ([design-live.md](design-live.md#the-inspect-service), "A path is data"). A
  production boot's processes, about 600 encoded bytes each, pass `inspect_reply_max` (256 KiB) near 420
  entries, so the page is `[partial]` and the domains after the cut show none; and since the page
  is cut on every such boot, the production image's `inspect-processes` point, which accepts
  `[partial]`, no longer shows that every domain before the cut answered. The design gives no
  narrower path to read the rest: `[domains, D, processes]` is declared (`abi/inspection.txt`) but
  design-live.md's "A path is data" serves it only for the system domain. Change that sentence so
  the worker answers `[domains, D, processes]` from D's agent, one answer per domain as now, and
  have `erx:i()` print each living domain's processes as its own listing; the point then expects
  whole listings again.

* [Low] live inspection, `ps` and `top` ([design-shell.md](design-shell.md#text-commands)): the `time` and `pcpu` columns of an
  Erlang process show its reductions, labelled as reductions, instead of `-`; real CPU time per process comes
  later as an opt-in scheduler flag.
* [Low] live, the `trace/1` shortcut ([design-live.md](design-live.md#erlang-in-every-domain)): the
  shell resolves each call in a function defined at the prompt by name alone (`shell.erl` `reconstruct1/3`,
  through `edlin_expand:shell_default_or_bif/1`), and argument completion does too (`edlin_context`), so an
  exported `trace/1` would make `trace(P, true, [send])` there call `shell_default:trace/3` instead of
  `erlang:trace/3`. Resolve by name and arity in both (an OTP edit for design-runtime's table), then add
  `trace/1` to `shell_default` and move it from `?PENDING` to `?SHORTCUTS` in
  `test/erlang/erx_shortcut_tests.erl`, whose `shell_name_resolves_like_stock_test` then checks resolution by
  name and arity instead of by name.

* [High] logging: a central system log service that every source writes
  to, with routing to the UART and other readers and per-reader access,
  needs its design; it replaces the console's role as the kernel log's
  reader and decides which log lines each console line shows, the UART's
  and the host link's
  ([design-live.md](design-live.md#the-console)).
* [Low] log, `erx_logfs` and `/var/log` ([design-log.md](design-log.md#the-file-tree)): the read-only file tree that
  serves the log store (the stored `messages` and `kernel/messages` and their archives) is not built. The writer
  keeps the store, so the log is readable only as `/data/log` through the system domain's whole-`/data` grant, and
  a session has no `/var/log`. Build `erx_logfs` as the design's `erx_fs` callback module; the escape-at-read item
  under Security residuals applies to it.
* [Low] crash record, the brief form's promise: `fault` keeps `addr`, `pc` and
  `status`, so a wild dereference or an exit status can carry 8 bytes of what
  the root task held, against [design-kernel.md](design-kernel.md#the-root-task)'s
  "nothing the root task held". Narrow the promise or the fields.
* [Low] erx_syslog ([design-log.md](design-log.md#the-kernels-records)): kernel records the early console
  wrote before the log service's first take are not in `kernel/messages`; they are on the serial line and in
  `/proc/kernel/log`. Read them once per boot with `erx_log:read/1`, below the first take's number, if previous
  boots' early lines are wanted.
* [Low] erx_syslog_sup ([design-log.md](design-log.md#service-lifetime-and-restart)): past its restart
  intensity the log service stays down and the machine runs on, as without `erx_console`. Revisit at the security
  closure ([plan.md](plan.md#m11-security-closure)), where a release build may prefer ending the machine with
  a crash record.

