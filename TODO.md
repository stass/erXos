# TODO

Open work outside the roadmap in [docs/plan.md](docs/plan.md). Each item has
a `[Severity]` tag and a component pointer. When an item is closed, delete
it; git history is the record of completed work.

## Major initiatives

* [Medium] architecture: evaluate the remaining
  [simplification candidates](docs/todo-simplification.md), recording for
  each the mechanism it removes, its cost and the evidence needed to adopt
  it: isolated parsing frontends, causal explanations in the inspector,
  and the open proposal
  on the scheduler's target configuration.
  Scheduled experiments live in the roadmap; these proposals do not
  silently replace established design decisions.
* [Medium] performance: measure the suspected costs on the
  [performance watch list](docs/todo-performance.md), each with the
  workload it names, and remove each item once a recorded number settles
  it: the kernel's portable-code hash of large boot image files at first
  use, the eager FP switch, and the stopgap's machine-wide release and
  grace lists.

## Stopgap replacements

* [High] kernel: replace the modified Fiasco with erXos's own C17 kernel
  once it boots the slice and passes the conformance suite, at milestone
  M7 (gate GK3), before the security closure of M11
  ([plan.md](docs/plan.md)). Every stopgap build carries GPL-2.0 code,
  Fiasco's `kobject_rpc.h`, without which the kernel does not build, and
  the kernel debugger's `jdb_object.cpp`, so any distribution outside the
  project, in source or binary form, waits for this replacement
  ([design.md](docs/design.md#dependencies)). The import also records
  the link closure of L4Re's `bootstrap` and `sigma0`, their `drivers-frst`
  UART support, and the licence of each library in it.
* [Medium] storage: replace littlefs, which runs as a sub-space port of
  the storage domains of the data partition and of the vault's partition,
  with erXos's F2FS, written in Erlang, at parity over the file-semantics
  corpus, by gate G13. Nothing written under littlefs is converted: erXos's
  F2FS arrives by an installation, which creates both partitions afresh,
  and an update whose storage formats differ from the running system's is
  refused ([design-storage.md](docs/design-storage.md#system-updates),
  [plan.md](docs/plan.md)).
* [Medium] network: replace lwIP, which runs as a NIF in the network
  domain, with erXos's own TCP/IP stack, written in Erlang, by gate G14.
  The network service gets its own design document before its code, which
  also settles an exposed domain's node name and registration, the error
  a domain without a network grant gets (provisionally `eacces`), and
  sockets with several holders; an early prototype of its packet path,
  measured on QEMU and on a Pi, decides whether TCP's fast path needs
  native code ([plan.md](docs/plan.md)).
* [Medium] kernel, performance counters on the stopgap: the modified
  Fiasco builds with `CONFIG_PERF_CNT_USER=y`
  (`config/fiasco/kernel.defconfig`), so user mode reads the CPU's
  performance counters directly, and they count every thread and kernel
  mode too: one domain can observe another's activity. erXos's kernel
  leaves user-mode counters disabled
  ([design-kernel.md](docs/design-kernel.md#security)). The stopgap keeps
  them for profiling while development builds run trusted code only; they
  go with the stopgap at M7, or earlier once the profiling feature under
  Planned features gives a confined way to count.

## Bugs by subsystem

* [Low] Lane reader, `liberx/erx_lane.c`: the record state machine
  (open, copy, close) is inline in `erx_lane_take` rather than a pure
  step the effect layer applies; `phase` and `fault` are a pair that must
  agree; `erx_lane_reader_init` fixes the connection side layout, so a
  pipe's or channel's reader and a read end that resumes at a position
  need separate pointers and a start position. Settle with the pipe
  server and the channel client.
* [Low] Lane tests, `test/fixtures/lane_driver.c`: the armed take and the
  producer's publication are each one step of the exploration, and the TSan
  race polls instead of parking, so the handshakes' orderings rest on the
  M5 herd7 litmus tests; add a threaded mode in which both parties park on
  `need` and `wake` under a deadline.
* [Low] stopgap bootstrap, overlapping RAM regions:
  `Region_list::optimize` (`fiasco/bootstrap/server/src/region.cc`)
  merges a region into its predecessor by setting the predecessor's end to
  the region's end, so a region wholly inside its predecessor shrinks the
  predecessor and drops RAM. Only the EFI memory-map path adds RAM with
  overlaps allowed (`efi-support.cc`, `ram->add(..., true)`), so QEMU
  `virt` booted from a device tree is unaffected. Found by reading, not
  reproduced; fix with a regression test before any EFI boot path is used.
* [Medium] Kernel budget core, `kernel/core/budget.c` and
  `kernel/core/budget_impl.h`: the record carries its own `parent`
  pointer and takes its lock through `erx_effect_budget_lock`, standing
  in for the object header's budget field and the core's ticket lock
  (`erx_spinlock_t`), and the reserve record holds the pool's count but
  not its chain of page records. When the object header, the ticket lock
  and the page core (`kernel/core/page.c`) land, embed them in the
  records, drop the lock effect, give `page.c` the pool chain (adding it
  to the `budget-records-private` chokepoint of
  `tools/lib/erx/chokepoint_rules/budget.rb`), and compose
  `erx_reserve_charge`, `erx_reserve_take` and `erx_page_release` there
  from `erx_reserve_admit`, `erx_reserve_fill`, `erx_reserve_cancel`,
  `erx_reserve_use` and `erx_reserve_refund`. The record cache, the lists
  of charged objects and the destroy's walk over them are the stopgap
  integration's (WP14), which `test/fixtures/budget_driver.c` stands in
  for. A pin returns the budgets whose `pinned` rose from zero for a
  follow-up pin of their records' cache pages, where the design pins
  them in the same adjustment; fold that in with the cache.
* [Medium] Budget core tests, `test/host/budget_test.rb`: the TSan race
  only charges and releases leaf reserves; K32 asks for resizes, carves
  and destroys racing too, with spending checked against every cap no
  resize lowered. Two of K32's seeded failures are missing: a chain
  applied one level at a time, and a dead or doomed budget's `used`
  counted toward the machine. The counters' chokepoint is enforced by the
  `budget-records-private` text rule of `tools/lib/erx/chokepoint_rules/budget.rb`
  (the header included and the records defined nowhere else), not by the
  syntax-tree check the design's row names, which stays the pending
  `budget-counters` rule; a layout-compatible record under another name,
  cast from an `erx_budget_t` pointer, escapes the text rule.
* [Medium] Kernel invalidation planner, `kernel/core/tlb_plan.c`: a
  cleared table entry carries its span in bytes, and the planner accepts
  any aligned power of two of at least two pages, so a range call that
  reports a level-2 table entry with too small a span gets a valid plan
  that leaves walk-cache copies in the rest of the span (K9). When the
  range call's plan is written, have each entry carry its table depth and
  the removal the table geometry, so the planner derives the span, and use
  the page-number and IOVA types of the data model instead of bare
  `uint64_t` bytes; let the removal also carry the target's ASID width and
  address limit, since an IOMMU's may differ from the CPU's.
* [Medium] Kernel invalidation planner, `include/erx/tlb_plan.h`:
  `erx_tlb_plan_t` is 1544 bytes, a fifth of an 8 KiB kernel stack. Keep
  it in the range call's plan storage rather than on the stack, or shrink
  `erx_tlb_inval_t` to 16 bytes (page number, log2 page count, reach).
* [Medium] Kernel chokepoints, `tools/lib/erx/chokepoint_rules/`: the
  syntax-tree checks of K2 (`erx_rights_t` built only in
  `kernel/core/cap.c`) and the sequence-counted accessor rule do not
  exist yet, and neither is in the registry.
* [Medium] Kernel chokepoints, `tools/lib/erx/chokepoint_rules/`: the
  text rules match whole names, so a name a macro pastes together
  (`erx_cap_slot_ ## clear`, `erx_ ## cap_slot`) gets past
  `cap-slot-clear-named`, `budget-records-private`, `cap-table-private`
  and the rule generated for each private ABI layout (`cap-slot-private`).
  Localize every symbol of `erx_cores.a` not on its API list, so code
  outside the cores cannot reach `erx_cap_slot_clear` however it spells
  it, and have the object leg read the objects' debug information, so no
  object but its core's defines a private record. The same text rules
  miss a slot reached by a cast at an offset copied by hand
  (`*(uint32_t *)((char *)s + 24)`), an include through a macro in
  inherited Fiasco, which `include-form` does not read, and a
  `-include` flag in a build file; the syntax-tree leg should refuse a
  cast from `erx_cap_slot_t *` or `erx_cap_table_t *` outside
  `kernel/core/cap.c`. Nor does any rule stop a caller that keeps its own
  untyped pointer to a table, its directory or a page it handed to the
  core from writing their bytes; the space core should allocate them from
  memory nothing else maps, and the syntax-tree leg refuse a write
  through such a pointer.
* [Medium] Kernel chokepoints, `tools/lib/erx/chokepoint_rules/`:
  `cap-slot-clear-callers` reads only the cores' call graph, so
  `cap-slot-clear-named` keeps `erx_cap_slot_clear` out of the Fiasco glue
  altogether. When the glue (WP12) gives the close and the space's
  emptying their callers, extend the caller check to the glue's objects
  and add the deletion walk's slot-clearing effect by name.
* [Low] Capability core, `kernel/core/cap.c`: the slot-count decrement and
  the release report move into `erx_cap_slot_clear` once the object store
  exists (WP12).
* [Medium] Capability core, `kernel/core/cap.c`: the table's owner hands
  `erx_cap_table_add_page` each page's storage, so the core can refuse a
  page that overlaps its own table, directory or pages, but not one that
  another table already holds, and the check scans the whole directory
  under the table's lock on every page added. Have the core take its
  directory and pages itself through the budget-charging allocation
  effect, so no caller supplies a page pointer and both the scan and the
  aliasing go away
  ([design-kernel.md](docs/design-kernel.md#objects-and-capabilities)).
* [Medium] Kernel chokepoints, `tools/lib/erx/chokepoint_rules/`: two
  mechanisms keep a core's records private. Each private ABI layout's
  rule is built from the ABI file, while `budget-records-private`,
  `cap-table-private` and the core-to-header sites of
  `core-records-private` are written by hand for the hand-written
  `kernel/core/STEM_impl.h` headers. Build all of them with one helper
  from one table, the private layouts plus every `kernel/core/STEM_impl.h`
  owned by `kernel/core/STEM.c`. While at it, have the model expose a
  private layout's stem and refuse a private layout whose generated
  header shares its base name with a hand-written one (`erx_cap_table`,
  `erx_budget`), and narrow `host_tests`, whose `test/fixtures/STEM_*.c`
  also admits the drivers of a later `kernel/core/STEM_x.c`, with a check
  that no build input lies under `test/` or `tools/fuzz/`.
* [Medium] Kernel chokepoints, the pending syntax-tree leg: no `Pending`
  rule awaits the syntax-tree reader for the capability records, so
  nothing fails when it lands without them. Declare one that refuses,
  from syntax trees, a definition of `struct erx_cap_slot` or
  `struct erx_cap_table` outside their headers however its tag is
  spelled, a member access through either type outside
  `kernel/core/cap.c` and its host tests, and a cast from either
  pointer type there
  ([design-kernel.md](docs/design-kernel.md#chokepoint-checks)).
* [Medium] Capability core, `include/erx/cap.h`: a pass's route is two

  flags the caller asserts (`from_own`, `to_created`), and nothing ties
  them to the tables `erx_pass_take` and `erx_pass_install` are given, so
  a rendezvous that sets `to_created` by mistake passes under the
  creator's rule. Make the route a closed enum derived from the tables
  (rendezvous, own to created, created to own, created to created), record
  both tables in the plan, and have the steps refuse a mismatch.
* [Medium] Capability core, `kernel/core/cap.c`: `erx_cap_install` takes a
  type and a rights value from its caller, checked only against the
  type's carryable set, whereas the design's install takes the creation
  kind (K2). Replace it with an install by kind (type and rights from
  `erx_kind_ktype` and `erx_rights_create`, plus a carve variant) and an
  install by copy from an existing view, so no caller supplies a type and
  rights pair.
* [Medium] Capability core, `kernel/core/cap.c`: a pass is read sources,
  plan, take, install and release the reservation, and growth is
  `erx_cap_table_pages_needed`, allocate and `erx_cap_table_add_page`,
  each a sequence the caller strings together (the plan's stage already
  makes take and install run once each, in order). When the Fiasco glue
  (WP12) gives them their callers, give each operation one effect-edge
  function around the pure plan so no caller can reorder or skip a step.
* [Medium] Capability core tests, `test/fixtures/cap_churn.c` and
  `tools/fuzz/cap_fuzz.c`: the ThreadSanitizer churn adds no page while
  readers run, never retires a slot under concurrent lookups and never
  races a reserve and fill; the fuzzer has no seed operation, so a slot's
  generation and count never near exhaustion. Add a growth thread and a
  writer that drives one slot to the terminal count, and a seed operation.
* [Medium] Kernel chokepoints, `tools/lib/erx/chokepoints.rb`: a `Callers`
  rule counts only direct calls and tail jumps, not every relocation that
  names its callee, so a core that takes the address of
  `erx_cap_slot_clear` goes unseen (outside the cores
  `cap-slot-clear-named` refuses any mention). Count every reference and
  test an address-taken one.
* [Low] Capability core, `kernel/core/cap.c`: `erx_pass_take` and
  `erx_pass_install` return `ERX_EINVAL` for a plan or reservation that
  breaks their preconditions (a kernel bug, never a domain's input); make
  that an assertion in host and debug builds as well.


* [High] storage and platforms, the Pi 4's boot image: the Pi 4's secure
  boot checks `boot.img` at about 2.6 MB/s under a firmware watchdog fixed
  at 4 s, and the boot image holds the kernel, the runtime image and the
  whole system release, tens of megabytes with ERTS, so the check alone
  outruns the watchdog. Decide what the signed boot image holds: the
  kernel, `liberx` and a root image that mounts the release's EROFS image
  from the slot under its hash tree, with the slot image's root hash in
  the signed part, or a boot image sized to the firmware's checking rate
  measured by the boot probe; restate "the boot image stays small" and
  "the boot image holds the release" so one of them goes
  ([design-storage.md](docs/design-storage.md#data-model),
  [design-platforms.md](docs/design-platforms.md#trust-in-the-boot)).
* [High] runtime, references on the Raspberry Pi 4: every reference is an
  AES-128 permutation over an image key, and the Pi 4's Cortex-A72 has no
  cryptography extension, so every `make_ref/0`, alias and
  `gen_server:call` pays a bit-sliced AES block where stock pays tens of
  nanoseconds, on the hottest path of the first board, against the 1.2x
  local budget. Decide the fallback: a cheaper permutation for references
  that stay inside their domain, with the full AES-128 applied only where
  a reference crosses a connection, or a cheaper keyed permutation
  everywhere with its unguessability argument restated; measure both with
  `tools/erx bench erts-local` on the Pi 4 at G12. Confirm the A72's
  feature set from Arm's documentation and from the ID registers read at
  the boot probe, since the present evidence is a forum thread
  ([design-runtime.md](docs/design-runtime.md#unguessable-references),
  [design-platforms.md](docs/design-platforms.md)).
* [Medium] runtime and live, standard I/O across domains: every other
  domain's standard I/O goes through Erlang's I/O protocol to a group
  leader in the system domain, whose requests carry the writing domain's
  atoms, which D5 refuses. State which requests cross, with their text
  rendered to binaries in the writing domain, as trace records are
  rendered in the traced domain
  ([design-runtime.md](docs/design-runtime.md#the-console-and-standard-io),
  [design-live.md](docs/design-live.md#tracing)).
* [Medium] scheduler, the pick core is configuration C0's
  (`kernel/sched/sched.c`, `erx_sched_pick`): it has no finishing level,
  no throttled lists and no published urgency yet, which the design's
  Pick and dispatch names and erXos's own kernel and C1 need. The stopgap
  keeps Fiasco's ready queue until C1, so nothing on the target calls
  `erx_sched_wake`, `erx_sched_remove` or `erx_sched_pick` before then.
* [High] scheduler, no design for how a thread passes between CPUs
  ([Concurrency](docs/design-scheduler.md#concurrency), `include/erx/sched.h`):
  the core decides on one CPU and leaves this to its caller, and the design
  says only that a cross-CPU wake is a request. It has to settle, before C1 or
  erXos's own kernel calls `erx_sched_pick`: which CPU a wake and a kill go
  to; how a wake meets a blocking thread's last check without being lost, and
  that a wake means only "check again"; that a thread a pick gave up stays
  untouchable until the switch off its stack is done, even by a kill of a
  thread on its way to another CPU; that a stale wake or arrival cannot revive
  a thread a kill took or join a later move of it; and when a record that
  requests can still name may be freed. Two attempts inside the core, an atomic
  claim and a home CPU with a moving state, each failed review on these cases.
* [Medium] scheduler, a raised urgency waits behind its old level
  (`erx_sched_pick`,
  [Pick and dispatch](docs/design-scheduler.md#pick-and-dispatch)): a pick
  examines only the head of the highest non-empty level, so a ready thread
  whose base or ceiling rose stays on its old level, unseen, for as long as
  a more urgent thread stays ready. The stopgap refreshes priorities when
  they change and is not affected; erXos's own kernel is. Fix: have a
  raising `erx_thread_set_urgency` and `erx_group_configure` post a request
  that requeues each ready thread they raise on its CPU, or state the wait
  as a limit in the design.
* [Medium] scheduler, `erx_sched_thread_init` and `erx_sched_root_init` on a
  live record (`kernel/sched/sched.c`): a second call re-parents a thread,
  changing the group it is charged to (S6), or clears a group's parent,
  removing every ancestor's limit (S5). Add a build check that thread
  creation alone calls the one and kernel boot alone the other, with the
  work that adds those callers.
* [Low] scheduler tests, the model follows the core's order of operations
  (`test/fixtures/sched_model.rb`): it shares no code, but one misreading
  of Pick and dispatch could pass in both; only the literal-value tests of
  `test/host/sched_test.rb` stand apart from it. "Resolved once per pick"
  has no test, since no single-threaded script can observe it. Add the
  decision traces the parity test of
  [design-scheduler.md](docs/design-scheduler.md#verification-and-testing)
  names, when the stopgap can produce them.
* [Medium] scheduler, S4: a deferred preemption lets an executor run
  `grace_us` past exhaustion as debt, so a period can reach the quota plus
  one quantum plus the grace per CPU, where S4 promises one quantum.
  Post the yield request a grace before exhaustion, or restate S4 with the
  grace ([design-scheduler.md](docs/design-scheduler.md#invariants)).
* [Medium] kernel and scheduler, wake fan-out: one trigger of a
  device's IRQ object bound to a group may wake every parked executor of
  the group, up to 64 threads, outside K13's bound on a stretch with
  interrupts masked. Bound the fan-out of one trigger, or wake one executor
  per trigger and let the runtime wake the rest
  ([design-kernel.md](docs/design-kernel.md#invariants),
  [design-scheduler.md](docs/design-scheduler.md#park-and-wake)).
* [Medium] system, devices: a bus abort or a fault inside the device NIF
  ends the whole domain that holds the device, the devices domain with
  every slow device on it. Decide whether the NIF's register access runs
  in a per-device sub-space shim, so an abort ends one device's shim, or
  whether the per-device-domain rule extends to devices that can abort
  ([design-system.md](docs/design-system.md#drivers),
  [design-runtime.md](docs/design-runtime.md#the-device-nif)).
* [Medium] storage, the default configuration: the block driver and the
  data partition's file system share the storage domain, so a storage
  domain's restart drops every window on the medium and a logic bug in the
  file system runs beside the device NIF. Decide whether the release
  configuration gives the block device a domain of its own, and measure
  the extra connection's cost with `tools/erx bench blk`
  ([design-storage.md](docs/design-storage.md#risks-and-open-questions)).
* [Medium] storage and platforms, the boot-selection record: the slot
  writer sees the record as one sector, while the Pi firmware reads it
  through FAT metadata in the same partition, so a damaged directory entry
  leaves erXos seeing a valid record while the firmware boots its default
  forever. Have the slot writer verify the record through the FAT
  structures the firmware walks, and test a damaged entry on the board
  ([design-storage.md](docs/design-storage.md#system-updates),
  [design-platforms.md](docs/design-platforms.md#slots-and-the-boot-selection-record)).
* [Medium] arch-aarch64, boot: the Pi firmware may ignore `image_size` and
  place the initial RAM disk right after the kernel file, and the entry
  zeroes `.bss`. Check at entry that the boot image and the device tree do
  not overlap the kernel image, instead of relying on a one-time probe
  ([design-arch-aarch64.md](docs/design-arch-aarch64.md)).
* [Medium] live, host-link handles: the handles of the host link's calls
  on facets (console, code, inspect, trace, install, update and domain),
  `{'$host_cap', N}`, `{'$pid', Text}` and `{'$ref', Text}`, are tuples
  inside term payloads, so a domain's agent can emit a literal one that
  the host tool cannot tell from a facet. Carry them out of band, as
  kernel capabilities pass as typed items. File access over 9P carries no
  such handle, its handles being 9P's fids
  ([design-live.md](docs/design-live.md#the-host-link)).
* [Medium] shell, pipeline admission: each pipeline stage is admitted at
  its full `max_heap_size`, 16 MiB, against an eighth of the session's
  budget, so a 128 MiB session admits one stage and `ps | where | sort`
  fails. Admit stages against their expected heap, or share the eighth
  among a pipeline's stages ([design-shell.md](docs/design-shell.md)).
* [Medium] shell and programs, command domains: `system`, `popen` and
  every Erlang command a program starts begin a command domain, at an
  estimated 0.15 to 0.3 s each, and `wak`'s `system()` pays it per call.
  Make one command domain per image, lazily, which holds the same
  authority by construction. Command domains take their names from the
  per-principal pool of reusable names that
  [design-system.md](docs/design-system.md#identifiers) defines
  ([design-shell.md](docs/design-shell.md),
  [design-programs.md](docs/design-programs.md#what-a-program-can-start)).
* [Medium] programs, signals to self: a signal a program sends itself has
  three delivery paths, so `killpg(getpgrp(), SIGTERM)` in the second tier
  can deliver twice. Make the handler the one path for every signal a
  program sends, its own included
  ([design-programs.md](docs/design-programs.md#signals-in-liberx)).
* [Medium] live code, overlay publication: specify reconciliation when a
  domain loads a candidate but its acknowledgement is lost, and make the
  inspector distinguish the running module set from the published overlay
  used at restart. Ordinary domains may retain a partial candidate after
  failure; evaluate atomic module loading for eligible batches and a fresh
  domain for changes requiring new application state. Loading an older
  hash does not restore application state or undo external effects
  ([design-live.md](docs/design-live.md#code-from-the-host)).
* [Low] architecture, security claims: distinguish immutable executable
  memory from the stronger file-source claim: no grant carries `rw` and
  `rx` together, but a program may hold both on one file through two
  grants, so "a program never runs what it could rewrite" holds per grant,
  not per file ([design.md](docs/design.md#trust-placement),
  [design-files.md](docs/design-files.md#invariants)).
* [Low] shell and programs, terminal order: each program gets fresh pipes
  to the terminal relay, one per stream, so cross-stream and cross-program
  order at the terminal is undefined and a diagnostic on standard error
  can print between two lines of standard output out of order. Merge a
  job's streams at the relay in arrival order
  ([design-shell.md](docs/design-shell.md)).
* [Low] programs, compatibility: `daemon()`, the double fork, toybox's
  `setsid` and `nohup x &` cannot outlive their starter under "a program's
  tree ends with it", and only "no `SIGHUP`" is in the compatibility
  table. List them there as documented differences with tests
  ([design-programs.md](docs/design-programs.md#a-programs-end)).
* [Low] programs, terminals: `isatty` is true on a `tty`-flagged pipe but
  `tcgetattr` fails with `ENOTTY`, which `less` and `vi` call in that
  order. Make the two agree ([design-programs.md](docs/design-programs.md)).
* [Low] system, principals: a principal can be created but never resized
  or removed. Add both to the principal service, with what happens to its
  sessions, domains, overlays and vault files
  ([design-domains.md](docs/design-domains.md#principals-sessions-and-quotas)).
* [Low] domains, naming: a name binds to the principal whose domain first
  takes it, so a principal can take a name before the principal or the
  configured domain meant to hold it. The design recommends first-use
  binding with the configured domains' names held from boot; the
  alternative is names the administrator assigns to each principal in the
  system manifest, which closes squatting at the cost of a configuration
  step per name. The user decides
  ([design-domains.md](docs/design-domains.md#risks-and-open-questions),
  [design-system.md](docs/design-system.md#identifiers)).
* [Low] domains, retirement: a survivor that never answers
  `connection_down` keeps a dead domain's outer budget and its record in
  the domain library until it unmaps or ends, bounded by the survivor's
  `connections` quota. Leave headroom in `max_domains` for such records,
  and state how much
  ([design-system.md](docs/design-system.md#risks-and-open-questions)).
* [Low] kernel ABI generator, `tools/lib/erx/abi_model.rb`: a private
  layout stays out of every public declaration by three separate
  refusals (embedding as a field, as a tail, and projection), so a new
  construct that names a layout (a reader table, a call argument) must
  remember a fourth. Walk every type reference of the schema once, after
  parsing, and refuse each one from a public declaration to a private
  layout, so the property holds for any construct
  ([design-abi.md](docs/design-abi.md#source-grammar)).
* [Low] kernel ABI, status codes: `ERX_EDEAD` carries two meanings (a
  dropped caller and a dead target). Split it, or state why one code
  serves both
  ([design-kernel.md](docs/design-kernel.md#calling-convention-and-status-codes)).
* [Low] kernel and arch-aarch64, `ERX_DMA_MSI_IOVA`: the constant is a
  GICv2m fact in a generic name. Move it to the platform layer's MSI frame
  description ([design-kernel.md](docs/design-kernel.md#dma-and-the-iommu),
  [design-platforms.md](docs/design-platforms.md#msi-frames)).
* [Low] kernel, `ERX_MEM_INHERIT`: the flag is the remembered creator mark
  that the copy table of `erx_space_copy` says it avoids. Reconcile the
  two
  ([design-kernel.md](docs/design-kernel.md#copy-on-write-children-and-copies-of-spaces)).
* [Low] kernel and platforms, store tracking: measure which accelerators
  and boards report `FEAT_HAFDBS` (`ID_AA64MMFR1_EL1.HAFDBS`), so that
  store tracking uses hardware dirty-state management where it exists
  and write-protect faults elsewhere
  ([design-arch-aarch64.md](docs/design-arch-aarch64.md#translation)).
* [Low] runtime, dirty I/O threads: every Erlang domain gets ERTS's
  default of ten idle dirty I/O schedulers. Size the default for a domain
  of a few megabytes, or start them lazily
  ([design-runtime.md](docs/design-runtime.md#scheduling)).
* [Low] runtime, the text of other machines' pids: a pid of another
  machine's node prints with a creation that can equal one of this
  machine's domain ids. The design recommends keeping the one rule,
  resolving `list_to_pid` to this machine's domain on a collision, and
  showing a pid's node name beside its text in the inspector; the user
  decides
  ([design-runtime.md](docs/design-runtime.md#risks-and-open-questions)).
* [Low] scheduler and runtime, executors per group: the cap is 64, and
  ERTS with dirty CPU schedulers as executors wants up to 128 at 64 CPUs.
  Raise the cap or cap the schedulers from the capacity
  ([design-scheduler.md](docs/design-scheduler.md#data-model)).
* [Low] platforms, the real-time clock: neither board has the PL031 the
  kernel's device table takes as its real-time clock. Name each board's
  clock, or read wall time from the firmware
  ([design-platforms.md](docs/design-platforms.md)).
* [Low] platforms, panic output: the board port measures whether the
  kernel's polled early-console writes at a panic complete after the
  console driver has reconfigured the UART, on each board
  ([design-platforms.md](docs/design-platforms.md#uarts)).
* [Low] platforms: the Pi 4's VL805 USB host sits behind a PCIe bridge no
  domain drives, so the Pi 4 has no USB; decide whether a PCIe domain
  drives the bridge on the Pi 4
  ([design-platforms.md](docs/design-platforms.md)).
* [Low] live, the host tree over virtio-9p: QEMU's 9p server on Darwin
  and FreeBSD hosts translates only six errnos to Linux numbering (its
  `errno_to_dotl` has a FIXME), so an error from `/host` on a macOS host
  may carry a host errno. The host-tree bridge treats an errno outside
  the codec's list as `eio`. Record it as QEMU's upstream defect and
  re-check it at each QEMU pin
  ([design-live.md](docs/design-live.md#files-between-the-host-and-the-machine)).
* [Low] storage, the boot-selection record: a torn record leaves the
  update service refusing every update until an installation writes the
  record afresh, since no normal boot may rewrite it. Consider a repair
  through a trial, on the boards whose firmware can request one
  ([design-storage.md](docs/design-storage.md#risks-and-open-questions),
  [design-platforms.md](docs/design-platforms.md#slots-and-the-boot-selection-record)).
* [Low] storage, FAT and littlefs: a file closed and reopened may get a
  new qid path, since those formats draw paths from the domain's counter;
  stable paths across a close would need a persistent identity the formats
  lack ([design-storage.md](docs/design-storage.md#data-model)).
* [Low] build, stack proof: confirm that lld's `--emit-relocs` keeps the
  call and jump relocations that the stack proof decodes
  ([design-arch-aarch64.md](docs/design-arch-aarch64.md)).
* [Medium] build, stack proof: LLVM 23 resolves a `bl` to a static
  function in the same section without a relocation, which the proof
  refuses, so the proven C must be compiled with `-ffunction-sections`
  (and no shared `section` attribute). The stack-proof passages of
  [design-kernel.md](docs/design-kernel.md#stack-proof),
  [design-arch-aarch64.md](docs/design-arch-aarch64.md#stack-proof) and
  the cores' build flags in [design-stopgap.md](docs/design-stopgap.md)
  name neither the flag nor that `tools/lib/erx/stack_graph.rb` reads
  relocations from `llvm-readobj`'s JSON listing of each object; the owner
  decides between requiring the flag and accepting a relocation-less
  in-section call whose decoded target is a function start.
* [Medium] build, stack proof: `tools/lib/erx/stack_graph.rb` pairs each
  object with its `.su` file by name, so a stale `.su` left by an earlier
  build gives wrong frames silently. Read frames from the object itself
  (`-fstack-size-section`'s `.stack_sizes`, bound to symbols by
  relocations), or have the build delete the `.su` before each compile.
  The build's own proof (`tools/lib/erx/stack_proof_run.rb`) compiles into
  a fresh directory on every run; other callers are exposed.
* [Medium] build, stack proof: the graph does not record which functions
  have their address taken (non-branch relocations naming a function), so
  `kernel/stack_targets.txt` cannot be checked against the functions an
  indirect call may reach: `tools/lib/erx/stack_proof.rb` takes the listed
  targets as given. Record them, and refuse an address-taken function that
  a listed indirect call could reach but the list omits. The same record
  must make every function whose address leaves the cores (a callback
  handed to Fiasco) an entry: today the proof judges only what the
  exported functions reach, so such a callback's frame and callees go
  unchecked.
* [Medium] build, stack proof: a `switch` that clang lowers to a jump
  table ends in an indirect branch that stays inside its function, which
  `kernel/stack_targets.txt` cannot declare (it lists functions, taken as
  tail jumps), so the first such switch in a core fails the proof or
  invites a wrong declaration. The owner decides between
  `-fno-jump-tables` for every proven object (the proof's flags in
  `tools/lib/erx/stack_proof_run.rb`, the archive's in
  [design-stopgap.md](docs/design-stopgap.md) and
  [design-arch-aarch64.md](docs/design-arch-aarch64.md#stack-proof)) and
  teaching `stack_graph.rb` to recognize a jump table's branch whose
  targets lie in its own function.
* [Low] build, stack proof: declarations that nothing uses are accepted
  silently: a `kernel/stack_targets.txt` line whose function holds no
  indirect site at either level, and a `leaf` of `kernel/stack_fiasco.txt`
  that a core defines itself. Report them after both levels have run.
* [Low] docs/design-stopgap.md, the stack proof: the bullet names only the
  `erx_effect_*` calls as leaves of declared cost; the proof also counts
  Fiasco's `memcpy` and `memset`, the archive's two other allowed
  undefined symbols, that way. The owner confirms the reading and the
  bullet says so.
* [Medium] build, stack proof: the stopgap proof's entries are every
  exported function of the cores' archive (`tools/lib/erx/core_archive.rb`),
  a superset of the ones the kernel image references
  ([design-stopgap.md](docs/design-stopgap.md)). Read the entries from the
  linked kernel's references to the archive instead, which needs the proof
  to run after the link as well as before it.
* [Medium] kernel, boot image: nothing calls the file check yet. WP32
  writes `bootstrap`'s use of `erx_boot_locate`, `erx_pack_open` and
  `erx_pack_file_check`; `erx_image_slice` needs the verdict table and
  hashing in parts of 64 KiB, which `erx_pack_file_check`, hashing a run in
  one call, cannot give it. Make it a pure stepper the core owns, computing
  the digest itself, not a digest the caller passes in, so that function
  stays the one check. The slice also needs `pack.c` in the kernel's archive
  and its stack proof as well as in `bootstrap`, and must decide what a run
  of only empty files, an object of no pages, returns. `tools/erx pack` stays refused
  until the M1 root startup, so `--two-file` and the slot refusal wait for
  it; and the harness's single-file boot cases need that first stage
  ([design-kernel.md](docs/design-kernel.md#tests-of-the-boot-image)).
* [Medium] build, stopgap bootstrap: `kernel/core/pack.c` is left out of
  the kernel's archive (`CoreArchive::BOOTSTRAP_SOURCES`) but is not yet
  linked into `bootstrap`, since nothing there calls it until the boot
  handoff ([design-stopgap.md](docs/design-stopgap.md#boot-handoff)) is
  written. That package builds a second archive of `pack.c`, BLAKE3's
  portable C and `liberx/generated/abi_reader.c` for `bootstrap`'s position-independent
  link (`-fPIE`, `-z text` in `fiasco/bootstrap/server/src/Make.rules`),
  adds the seam header `include/erx/core/pack.h` (`erx/pack.h` reaches
  `erx/abi.h`, which is C only), and audits `bootstrap`'s map like the
  kernel's.
* [Medium] build, cores' archive (`tools/lib/erx/core_archive.rb`): the
  compile's argument vector is not recorded beside each object, so the
  Fiasco audit sees a core object's sources (`.NAME.o.d`) but not its
  flags; record it as Fiasco's `.cmd` files do and have the audit compare
  it with `CoreArchive::FLAGS`.
* [Medium] build, Fiasco audit of imported cores
  (`tools/lib/erx/fiasco_provenance.rb`, `erxos_source` and
  `attribute_erxos`): a file under `kernel/` or `include/` is attributed
  as erXos source, `BSD-2-Clause`, whenever its first eight lines carry
  the SPDX line, so FreeBSD's SHA-256 and ChaCha20 in `kernel/crypto/`
  enter the build record without their `ORIGIN.md` files, their recorded
  licences (ChaCha20's public domain) or Colin Percival's notice, and
  BLAKE3 (`Apache-2.0 WITH LLVM-exception`, no BSD-2-Clause line) blocks
  the record as soon as the stopgap kernel links it. Attribute
  every file under a directory with an `ORIGIN.md` through that origin's
  inventory, as the fork parts are, never through the header rule, and
  test it with a captured-inputs fixture.
* [Medium] build, cores' compiler: `tools/erx build fiasco` takes
  `ERX_CLANG` as given, without `host_environment`'s LLVM 23.1.3 version
  check; the audit derives the LLVM installation from the driver's path
  (`FiascoProvenance.llvm_registry`) while `tools/erx` derives it from
  `-print-resource-dir`; and the recorded clang hash is the driver's, not
  `libclang-cpp` and `libLLVM`, which hold the code generator. Share one
  verified compiler identity and hash the linked libraries.
* [Medium] build, glue seam: the glue's include path is a copy of
  `include/erx/core/` under `build/fiasco/cores/seam/`, and the audit
  (`FiascoProvenance#erxos_source`) maps any path below `seam/` back to
  `include/`, wider than the copy. A layout whose seam directory is itself
  captured (for example `include/seam/erx/core/`) would delete the copy and
  the remap; at least restrict the remap to `erx/core/`.
* [Medium] build, tests: the audit's erXos attribution
  (`erxos_source`, `attribute_erxos`, `erxos_addition`), `llvm_registry`,
  `StackProofRun.call(archive:)`'s mismatch refusal, and the archive's
  replacement of an existing output have no host tests; the real build's
  complete audit is their only check. `erxos_notice?` also accepts any
  SPDX expression containing `BSD-2-Clause`; parse it with
  `Attribution`'s parser instead.
* [Medium] build, stopgap glue: the design compiles the glue with GCC's
  `-fstack-usage` and checks it (B2, B3, B9, B11, the import allowlist);
  `fiasco/kernel/src/erx/erx_probe.cpp`, the one glue module, gets only
  `ERX_GLUE_CXXFLAGS` (`fiasco/kernel/src/Makeconf`). The glue checks
  package adds the flag beside the include path.
* [Medium] stopgap kernel, FP state: the fork switches FP state eagerly,
  and nothing runs it. No QEMU case holds distinct vector registers in two
  threads of different spaces across switches and a migration, or reads a
  fresh thread's registers as zero (the FP case of the "every exception
  class" row of [design-stopgap.md](docs/design-stopgap.md)), and no
  `tools/erx bench` workload times the kernel's context switch, so the
  eager switch's cost is unmeasured. `Context::spill_fpu_if_owner`
  (`context.cpp`), which turns the unit on to save a current vCPU that
  disabled its FPU, has no case that reaches it, and the eager
  `Thread::transfer_fpu` (`thread.cpp`) still saves and restores the
  current thread's registers without turning the unit on; the design
  does not build it.
* [Low] build, configuration check: `tools/lib/erx/fiasco.rb` checks the
  resolved `globalconfig.out` before the kernel make, whose own rules can
  rerun `oldconfig` or `syncconfig` (`fiasco/kernel/src/Makefile`). Today
  a changed source recreates the build directory, so nothing rewrites the
  checked file; check the configuration the built kernel embeds
  (`.debug.fiasco_config`, `Makeconf`) after the make as well.
* [Medium] build, stack proof: `kernel/stack_targets.txt` declares no stack
  use of assembly routines, and the proof checks no declared use against
  the routine's stack-pointer adjustments
  ([design-kernel.md](docs/design-kernel.md#stack-proof)). The cores have no
  assembly; erXos's kernel needs both.
* [Medium] liberx, generated ABI reader: `erx_manifest_open`
  (`liberx/generated/abi_reader.c`) has a 2048-byte frame at -O0 and a
  992-byte one at -O2, and `erx_crash_record_decode` a 976-byte one at -O0
  (clang 23.1.3, `aarch64-none-elf`, measured 2026-11-03). The boot
  validator calls the first, so wherever it runs on a proven stack the
  1 KiB frame cap refuses it. Decode into caller-supplied scratch instead
  of stack locals.
* [Low] build, stack proof: `kernel/stack_fiasco.txt` lists its `tick`
  entries by hand; derive them from the glue's tick hook once the glue
  exists, and have the glue's `static_assert` and the conformance suite's
  watermark check read the allowances from that file.
* [Medium] build, stack proof: frames and tail jumps are taken as the
  compiler made them; inline assembly that writes the stack pointer or the
  link register is not accounted for. The inline-assembly chokepoint must
  also refuse either write in its listed functions.
* [Low] build, stack proof: refusal paths of `stack_graph.rb` with no test
  of their own: an instruction outside every function, overlapping or
  weak function symbols, a relocation into a section where no function
  starts, a section symbol plus addend into a function's middle, SHT_REL
  sections, two relocations at one offset, and duplicate executable
  section names. Most need only hand-made tool output fed to
  `StackGraph.build`.
* [Low] docs/research-baselines.md: the experiments behind the record (the
  boot and exception probe and its generators, the ERTS round-trip
  benchmark, the restricted decoder, the decompiled device trees) live
  outside the tree in `~/erxos-scratch/`. Bring them into `bench/` and check
  them against the SHA-256 prefixes the record gives, so the record can be
  reproduced from the repository. Its numbers do not state the compiler
  flags, which CLAUDE.md requires of every performance number; re-measure
  them with the flags recorded, in a new dated record.

* [Medium] host tooling, the source check (`tools/lib/erx/checks.rb`):
  `Runner` writes a child's stdout and stderr to one log, so the check
  finds a git warning only because it breaks the NUL-terminated listing.
  That catches every warning git prints, but a git that skipped an
  unreadable directory without a warning would shrink the file set
  silently; git 2.50 warns, and the oldest git that does is unconfirmed.
  Give `Runner` a separate stderr log and require it to be empty, so the
  guarantee holds whatever git version is installed.
* [Low] host tooling, the pack-tool recipe (`tools/lib/erx/pack_tool_recipe.rb`):
  project inputs are refused by private directory name
  (`Erx::PrivateState`). Requiring each to be a file the source check's git
  listing names would make that hold by construction. Compiler metadata
  outside the project is likewise judged by name; checking it against the
  compiler's own roots (SDK path, resource directory) would also refuse
  credential files whose directory is not on the list.

## Security residuals

* [Medium] Entropy generator's burn on the kernel's objects
  (`kernel/core/rng.c`, `test/host/rng_test.rb`): the residue test runs
  the host build, whose frames differ from the kernel's, and the stack
  proof holds only the depth, so a flag or compiler change that moves a
  frame's padding onto a message word in the kernel's objects goes
  unseen. Run the residue check on objects built with the core archive's
  flags, under QEMU or reassembled for the host.
* [Low] Entropy generator's registers (`kernel/core/rng.c`): secrets stay
  in the registers a callee may change until they are overwritten, and an
  interrupt taken in kernel mode in that window saves them to the stack,
  below any burn. Reading them needs another kernel bug.
* [Medium] The kernel log's limit is per space, and the ring is shared
  (`kernel/core/log.c`, `erx_log_rate_t`): 16 KiB per second lets one space
  push every record, the kernel's included, out of the 64 KiB ring in about
  four seconds, N spaces in a fraction of that, and a domain that creates
  and ends sub-spaces gets a fresh allowance with each one. Nothing is lost
  silently, since a reader is told how many records it lost, but a space that
  floods and then ends never reports its own drop count. Charge the rate at
  the domain, a sub-space drawing on its parent's state, and show a space's
  count through inspection, when the kernel handler and spaces land.

* [Medium] Lane reader chokepoint, `lane-pages-reader` in
  `tools/lib/erx/chokepoint_rules/`: a text rule over the names of a
  lane's layouts, so untyped pointer arithmetic on a side's address (the
  public `peer_side` and `own_side` of `erx_lane_reader_t`, or the mapping
  a runtime made) escapes it, as does a name a macro pastes together
  (`erx_lane_ ## hdr`), and inside `liberx/erx_lane.c` that only
  `erx_lane_take`'s path loads from the producer's side is held by review.
  It reads a listed set of inherited trees (OTP, musl, the stopgap
  kernel), so a new in-tree import that runs in a domain, such as toybox,
  is outside it until listed; read every listed file less named
  exclusions instead. Close it by construction once the mapping calls
  exist: `erx_lane.c` maps a lane's sides itself, the reader record
  becomes opaque with a test-only constructor for a start position, and
  the syntax-tree leg checks loads.
* [High] DMA platform evidence: the SMMUv3 specification and QEMU
  v11.1.2 source audit is recorded in
  [research-hardware-contracts.md](docs/research-hardware-contracts.md).
  Close each platform's outstanding evidence gate for loader/device and
  SMMU queue quiescence and drain, valid-abort and ATS rejection, completed
  invalidation visibility, failed-reset handling and stale-event retirement.
  Source inspection is not executable conformance evidence. Keep unknown
  handoffs and completions closed, a confined device's memory held until
  its window's invalidation completes and an unconfined device's for the
  boot, until the exact supported platform meets the contract
  ([design-platforms.md](docs/design-platforms.md),
  [plan.md](docs/plan.md#m11-security-closure)).
* [Medium] kernel, attributing asynchronous errors: on a board with PCIe,
  a device error caused by a posted write can be reported after the window
  that would attribute it, and then ends the wrong domain; one the
  processor reports as uncontainable panics the kernel. Use the
  processor's error records where it keeps them, and run an
  error-injection test on each board before drivers run on it. M12, which
  brings the boards, closes this or records the user's acceptance
  ([design-kernel.md](docs/design-kernel.md#interrupts-time-and-entropy)).
* [Medium] stopgap kernel, finishing without a share: the modified Fiasco
  runs a killed thread at the fixed finishing priority above every user
  urgency on its own CPU, outside every quota, with no finishing share,
  so a domain that creates threads homed on one CPU and kills them holds
  that CPU's user threads back, the root task's petting thread among
  them, for as long as the stream lasts; the bound is the stopped
  spaces' remaining work, paid for by their budgets. Acceptable only
  while development builds run trusted code; erXos's kernel bounds it
  with the finishing share, and it goes with the stopgap at M7
  ([design-stopgap-scheduling.md](docs/design-stopgap-scheduling.md#security)).
* [Low] platforms, QEMU `virt`'s fw-cfg device: check whether its node,
  `qemu,fw-cfg-mmio`, offers the DMA interface on the pinned QEMU. If it
  does, list it among the bus masters of the DMA contract; the system
  manifest gives it to no domain
  ([design-platforms.md](docs/design-platforms.md#dma)).

Every other risk the design accepts is stated in its
[threat model](docs/design.md#threat-model) and in each subsystem
document's "residual risks accepted" paragraph.

## Planned features

* [Medium] liberx, `erx` backend, `erx_utcb_self`: the generated trap
  wrappers of calls with UTCB parameters
  (`liberx/backend/erx/arch/aarch64/generated/calls.c`) reach the calling
  thread's UTCB through `erx_utcb_self`, which nothing defines yet. On
  AArch64 it reads `TPIDRRO_EL0`, so it lands as a listed
  system-register function generated from the system-register source,
  with the first shipped call that takes a UTCB parameter
  ([design-abi.md](docs/design-abi.md#kernel-calls-and-bindings)).
* [Medium] fuzzing, UTCB call decoding: `fuzz/generated/abi.c` decodes
  every shipped call with a UTCB built from the input, but no shipped call
  takes a UTCB parameter yet, so the decoder's word copy, uncovered-byte
  checks and aggregate field checks reach libFuzzer only through the
  host probe of `test/fixtures/abi_call_marshal.txt`. Have `check-fuzz`
  also build the generated harness against that fixture, or land the
  first UTCB call with its fuzz run
  ([design-abi.md](docs/design-abi.md#kernel-calls-and-bindings)).
* [Medium] kernel dispatch, the effect loop: `erx_dispatch`, which decodes
  the shape, performs the admission core's actions (`kernel/core/admit.c`)
  with `erx_cap_lookup`, `erx_object_lock_existence` and
  `erx_object_unlock_existence`, and
  calls the handler, lands with the object store those functions belong
  to, with the build check that only the dispatch takes admission's lock,
  with the handlers' `erx_object_lock_existence2`, its refusal of two
  references to one object and the one wrapper each such handler has, and with `erx_cap_lookup`'s reading of the calling
  thread's space and thread for `erx_cap_read`'s `erx_cap_self_t`;
  `erx_cap_lookup`'s design signature takes an `erx_rights_t` where
  the plan and `erx_cap_read` hold a mask, which the loop reconciles. Until
  then the plan and the core are driven only by the host probe of
  `test/fixtures/abi_call_marshal.txt`, since no shipped call takes a
  capability ([design-kernel.md](docs/design-kernel.md#system-call-dispatch)).
* [Medium] ABI call grammar, capability forms the design's call table needs
  and the schema cannot declare yet, each of which the admission plan must
  express rather than the dispatch working around its lookup: a nullable
  argument (`erx_budget_watch`, `erx_irq_create`, since a lookup of
  `ERX_CAP_NULL` is stale), either of two types (`erx_irq_bind`), any type
  (`erx_cap_dup`, `erx_cap_close`, `erx_object_destroy`, `erx_object_info`),
  rights that follow a flag (`erx_mem_create_paged`), and typed items in the
  UTCB checked by the pass plan (`erx_cap_pass`, IPC), which
  `carries_capability?` refuses as a plain aggregate
  ([design-abi.md](docs/design-abi.md#kernel-calls-and-bindings)).
* [Low] crash record, the crash frame's constants: the design says the ABI
  file declares `crash_frame_begin`, `crash_frame_end`, `crash_frame_line` and
  `crash_frame_lines_max`, and it does not yet. They land with the frame's
  writer and reader.
* [Low] crash record, the brief form's promise: `fault` keeps `addr`, `pc` and
  `status`, so a wild dereference or an exit status can carry 8 bytes of what
  the root task held, against [design-kernel.md](docs/design-kernel.md#the-root-task)'s
  "nothing the root task held". Narrow the promise or the fields.
* [Medium] boot records, their writers and readers: the ABI file declares
  `erx_machine_page`, `erx_device_secret_page` and `erx_boot_root_extension`,
  and no code writes or reads them yet. The kernel's writers land with the root
  task's construction, and with them the kernel's command-line parser, its
  report of an unknown `erx.` key and their fuzz target. `liberx`'s root-task
  entry reads them, refuses a boot
  value and slot outside the pairs the design lists, treats a status outside
  its enum as no secret, and derives only from a status of present. With it
  land its fuzz targets, known-answer vectors for both HMACs, and the link
  check that only the entry's one derivation function reads the device-secret
  page or references its slot
  ([design-kernel.md](docs/design-kernel.md#the-root-task),
  [design.md](docs/design.md)).
* [Medium] kernel dispatch and stopgap send glue, the retry action: the
  generator gives only a call declared `retry` a handler that takes
  `erx_sys_action_t`. The generated dispatch loop that runs such a call
  again from its capability lookup, and the build check that only the
  send's glue returns `ERX_SYS_ACTION_RETRY`, with a seeded second
  returner failing it, land with the dispatch and the IPC glue
  ([design-stopgap-scheduling.md](docs/design-stopgap-scheduling.md#the-wait-funnel)).
* [High] chokepoints, the pending M1 rules of
  `tools/lib/erx/chokepoint_rules/`: the object leg (no liberx target
  object outside the fiasco backend references an `l4_` symbol or holds a
  trap but the ABI's, read with `llvm-nm` and `llvm-objdump`; it also
  closes the include-path gap the text rules cannot see, an `-I` flag
  reaching l4sys's headers); the linked-kernel call-site reader the raw
  allocator and pmem converter rules need; the glue-imports allowlist over
  the glue's GCC objects (`erx_probe.cpp` already exists, and its imports
  are unchecked until then); the vector route; and the syntax-tree rule of
  the budgets' counters. Each fails the check as soon as a file
  it awaits lands, except the files it lists as existing: the budgets' rule
  exempts `kernel/core/budget.c` and `kernel/core/budget_impl.h`, which the
  active `budget-records-private` text rule covers until then
  ([design-kernel.md](docs/design-kernel.md#chokepoint-checks)).
* [Medium] chokepoints, gaps of the text rules until the object leg
  closes them (`tools/lib/erx/chokepoints.rb`): rules match names, so they
  do not follow includes (a `kernel/core/cap.h` allowed to include
  `cap_impl.h` can be included by the glue), and they do not see token
  pasting or `L4_` macros; files ignored by an exclude rule are not
  scanned though a build file could name them; the glue, inside an
  imported tree, gets no directory-alias or link-name check; and an
  Elsewhere rule checks only that its test file exists, not its named
  check or seeded case. `include-form` reads only erXos's files and the
  glue, so in Fiasco's inherited kernel sources, which
  `budget-records-private` and `seam-only-from-glue` also read, a computed
  include, a climbing path (`../../../../kernel/core/budget.c`) or a
  header outside the C-family extensions passes them. The C view keeps the
  comments of `.S` files, so `# /**/ include "x_impl.h"` there hides the
  directive from every include rule. A differential test of the C view
  against `clang -E` would prove that it never drops code.
* [Low] conformance harness details (`tools/lib/erx/conformance.rb`): hash
  and boot one copy of the image, so a rebuild during the matrix cannot
  mix images; show each failed configuration's reasons on the terminal,
  not only in its report; split protocol lines on single spaces exactly.
* [Medium] conformance, the guest side: a `liberx` reporter that prints
  `erx-test:` lines and ends the machine through `erx_machine_end`, and the
  roster's first cases with their calls; the harness gives one deadline per
  configuration, not per case ([design-build.md](docs/design-build.md#images-and-guests)).
* [Medium] bench, G1's guest workloads (`tools/erx bench timer`, `stop`,
  the null call, IPC, park and wake, boot time): they reuse the conformance
  harness's boot, deadline and guest endings, with results kept per
  accelerator ([plan.md](docs/plan.md#m1-the-stopgap-speaks-erxoss-interface)).

* [High] kernel memory, file-backed memory objects with evictable clean
  pages, so that large-file `mmap` (LMDB, SQLite in mmap mode) and ML
  weights larger than free RAM work; needs a revised K6 (a fault may wait
  only on a party that already controls the faulting space) and a K6
  wording that separates guaranteed anonymous memory from evictable file
  memory ([design-kernel.md](docs/design-kernel.md#invariants),
  [design-kernel.md](docs/design-kernel.md#virtual-memory)).
* [Medium] vault, the TPM 2.0 client: choose between tpm2-tss as a NIF, a
  small C client, and a client of erXos's own with Erlang framing and the
  session cryptography in the vault's NIF; the design recommends the last,
  behind `erx_seal`
  ([design-system.md](docs/design-system.md#risks-and-open-questions)).
* [Low] vault, anchoring under `tpm`: a TPM NV counter that versions the
  machine's file and the set of enrolled principals, so a deleted or
  rolled-back principal file reads as tampering; needs a recovery path for
  a tampered medium
  ([design-system.md](docs/design-system.md#risks-and-open-questions)).
* [Medium] vault, credential slots: FIDO2 slots through `hmac-secret`
  and recovery-code slots, beside the passphrase slot, each wrapping the
  principal's master key ([design-system.md](docs/design-system.md)). A
  recovery slot needs its own policy, since its protection can become the
  easiest route to the master key.
* [Medium] logins over the network: SSH public-key logins, optionally
  backed by a hardware key, before any password login over the network.
* [Medium] boot security on the Raspberry Pis: secure boot as an
  installation option with each slot's measurement; anti-rollback where a
  board offers a counter that its trust root checks before the kernel
  (neither Pi does), the counter taking the committed slot's security
  version at each commit and the spare allowed below it, while without one
  the floor is the running system's security version, which rises only at
  commit; and a TPM 2.0 driver over SPI for add-on modules, an Erlang
  driver in the vault's domain
  ([design-platforms.md](docs/design-platforms.md)).
* [Low] vault: key facets constrained to a destination, in the style of
  OpenSSH's restricted agent, which need authenticated session evidence;
  and a TEE backend for the sealing interface.
* [Low] files, fid pools: a root grant's fid pool is shared by the
  session and every program under it, with a quarter kept back for the
  root ([design-files.md](docs/design-files.md)). Give each derived
  grant a pool carved from its parent's, so one program cannot exhaust a
  sibling's opens.
* [Medium] network and programs, sockets across spawn, fork, `exec` and
  `SCM_RIGHTS`: a socket is owned by one program at the network service,
  whose protocol has no way to share it, so a child inherits no socket
  descriptor and an `exec` closes every socket
  ([design-programs.md](docs/design-programs.md)). Unix software relies on
  keeping them: pre-fork servers, PostgreSQL's backend per connection,
  services started with a socket as their standard input and output, and
  programs that `exec` with a connection open. Design sockets with several
  holders, and a socket's handover across `exec`, into the network
  service's protocol when that service gets its design document
  ([plan.md](docs/plan.md), M12), and implement them when a ported program
  needs them.
* [Medium] storage, FAT: a FAT file server in Erlang, in a storage domain
  that holds only its own partition's window, for removable media and for
  exchanging files with other machines. Booting and updates need none: the
  firmware reads the slots' FAT, and an update writes whole slot images
  ([design-storage.md](docs/design-storage.md)).
* [Low] storage, F2FS per-file encryption: erXos's F2FS implements the
  `encrypt` (fscrypt) feature flag, so a principal's files are encrypted
  at rest under a key the vault hands the storage domain through a key
  facet, with Linux as the oracle for the on-disk format. Until then the
  flag is refused, as every unimplemented feature is
  ([design-storage.md](docs/design-storage.md#read-write-storage)).
* [Low] storage, F2FS compression: the `compression` feature flag, when a
  consumer needs it, with its per-cluster work in a per-byte primitive.
  Until then the flag is refused, as every unimplemented feature is
  ([design-storage.md](docs/design-storage.md#read-write-storage)).
* [Low] toybox: at import, verify the `vfork` and `exec` call sites of
  toybox 0.8.15 and the list of applets left out
  ([design-programs.md](docs/design-programs.md)).
* [Low] tools/erx, mounting an erXos server on the Mac: the 9P2000.L
  mount of the machine's namespace needs a FUSE layer on macOS (macFUSE or
  FUSE-T) for Finder, editors and `grep` to reach `/proc` and the
  machine's files ([design-live.md](docs/design-live.md#the-host-link)).
* [Low] kernel and platforms, isolation groups: confine a board whose
  fabric keeps requester identities only within a bus by isolation groups
  that span several streams ([design-kernel.md](docs/design-kernel.md)).
* [Medium] kernel, profiling with hardware performance counters: give a
  thread confined access to the CPU's counters through a capability, so
  programs and runtimes can count cache misses, branch mispredictions and
  cycles without seeing anyone else. Design first: a counter object
  granted by whoever holds the profiled space's authority; the kernel
  counts only the holder's user-mode execution, saving and restoring the
  counters on every switch so nothing leaks between threads or domains;
  sampling by overflow interrupt delivered as an IRQ object to the
  profiler; the events and counter widths from the architecture's
  specification, generated like other system registers; what the
  inspector shows; the cost on the switch path, measured with
  `tools/erx bench`. Decide whether ERTS's `perf` support and
  `erlang:statistics` use it. Replaces the stopgap's direct user access
  (Stopgap replacements above).
