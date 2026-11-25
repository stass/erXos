# TODO: erXos's kernel

Open work on erXos's own kernel (Phase 2, Track K): the C17 cores, the chokepoint checks, the scheduler and the kernel ABI generator. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Major initiatives

* [High] Phase 2, kernel: replace Fiasco with erXos's own C17 kernel once
  it boots 0.2's system and passes the conformance suite, at milestone M7
  (gate GK3), before the security closure on erXos's kernel (M11)
  ([plan.md](plan.md)). It blocks no release: 0.2 ships on Fiasco, and
  what Fiasco lacks is published with it as the downsides of
  [design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel).
  The tree's `kobject_rpc.h` is erXos's MIT clean-room replacement of
  Fiasco's GPL-2.0 original (`fiasco/kernel/ORIGIN.md`); the one GPL-2.0 file a build carries is
  the kernel debugger's `jdb_object.cpp`, which goes out only in 0.1's
  images, which keep the debugger, with its source offered, and which the
  release kernel's build leaves out (0.1's and
  0.2's items below, [design.md](design.md#dependencies)); the debugger's
  replacement takes the file out of the tree
  ([design-debugger.md](design-debugger.md#on-fiasco), and its item in
  [todo-fiasco.md](todo-fiasco.md)). Both kernels then link one stop core,
  `kernel/core/machine_stop.c`, which is the kernel's panic path when
  erXos's kernel is built. The import also records the
  link closure of L4Re's `bootstrap` and `sigma0`, their `drivers-frst`
  UART support, and the license of each library in it.

## Stopgap replacements

* [Medium] kernel, Track K, shelved Phase 1 work: three pieces of code
  written for the earlier plan, which put erXos's kernel semantics inside
  the Fiasco fork, stay on branch `shelved-phase2-cores` for Track K: the capability
  binding into Fiasco with the first capability calls (12a, commit
  `e2492a64`), the entry classification core (R-a, commit `e90fe78b`) and
  the quota pool's pure core (WP58, commit `c38b3ada`). Phase 1 on a
  near-stock Fiasco does not use them. Track K reviews each against
  erXos's kernel's design and lands what it keeps.
* [Medium] kernel, performance counters on Fiasco: the modified
  Fiasco builds with `CONFIG_PERF_CNT_USER=y`
  (`config/fiasco/kernel.defconfig`), so user mode reads the CPU's
  performance counters directly, and they count every thread and kernel
  mode too: one domain can observe another's activity. erXos's kernel
  leaves user-mode counters disabled
  ([design-kernel.md](design-kernel.md#security)). The benchmarks'
  cycle probe reads the cycle counter through it and reports `unknown`
  without it ([design-bench.md](design-bench.md#the-cycle-counter)). Fiasco keeps
  them for profiling while development builds run trusted code only; they
  go with Fiasco at M7, or earlier once the profiling feature under
  Planned features gives a confined way to count.

* [Medium] kernel, Track K, the slot list's insert
  (`kernel/core/attach.c`, `kernel/core/cap.c`): `erx_attach_object_slots`
  writes only the list's head and leaves the slot's links to
  `cap_list_insert`, and its state check stands behind
  `erx_object_cap_add`'s under the same lock, so removing it alone changes
  nothing a test sees. No rule limits who calls it, and a caller that drops
  the old head loses the rest of the list. Either move the whole link into
  attach.c behind a capability-core helper only it calls, or call the count
  the field's gate and keep attach.c's check as an assertion; then add a
  caller rule on the insert (the Callers kind accepts only exported
  callers, and `cap_list_insert` is static).

* [Medium] verification, Track K, the CBMC gate (`tools/lib/erx/cbmc.rb`,
  `test/cbmc/roster.json`): if CBMC is adopted from the pilot's
  record, settle three things the pilot leaves open. Homebrew offers only
  the latest cbmc, so the pinned version cannot be installed on a fresh
  host once the formula moves on: fetch a pinned release or source by
  hash, as the TLA+ jar is, or document an upgrade step. The report does
  not record the host preprocessor CBMC runs (clang `-E`), which shapes
  what is checked. The runner merges CBMC's standard error into the log
  it parses, so a stray line that looks like a result makes the run a
  tool error rather than a reported warning. The record
  ([research-cbmc-pilot.md](research-cbmc-pilot.md)) recommends
  keeping the seven single-decision harnesses in the gate and moving
  `page_funnel` and `cap_slot_list` out of it: they take about 2 h 27 min
  of the gate's 2 h 33 min and check what the fuzz targets already check.
  Until that is decided, the gate runs all nine. `cap_slot_list`
  checks a table whose page is cut to 4 slots, which its header argues
  checks what the ABI's 64-slot page would; on the Intel second
  development host with cbmc 6.11.0 it verifies in 214 s and its three
  mutants are caught in 219 s, 316 s and 290 s, where on the full page
  the harness and two mutants passed the 3,600 s deadline.

* [High] kernel, Track K, the one route from user mode: in erXos's kernel
  only the trap immediate of `abi/arch/<arch>.txt` reaches `erx_dispatch`,
  and the exception vectors and the synchronous entry from user mode are
  the kernel's own: `erx_user_sync_entry` over `erx_fault_classify` and
  `erx_entry_step` (`docs/design-kernel.md`), with a build check that no
  other route into the kernel exists (the pending `vector-route` rule).
  Phase 1 uses Fiasco's own routes and has none of this.
* [Medium] erXos's kernel, [design-kernel.md](design-kernel.md) (memory objects, "contiguous"): creation zeroes up to
  16 MiB in one kernel call, and the design leaves how that meets the bounded-path rule to the performance watch list.
  Decide it in the design: zero the `erx.dma_pool` once at boot and each range as it returns to the pool, or zero in
  preemptible steps, and keep only the measurement in `docs/todo-performance.md`.
* [Medium] erXos's kernel, [design-kernel.md](design-kernel.md#threads) ("The kernel-user page"): the kernel maps
  each thread's kernel-user page "at an address it picks", and nothing keeps that address out of the places the ABI
  fixes in every program's space: the loader's window (`exec_window_base`, `exec_window_bytes`) and the program
  memory place (`prog_mem_base`, `prog_mem_bytes`) of `abi/protocols/prog.txt`. A kernel-user page inside the
  window makes every exec's fixed, non-replacing reserve of the window's rest fail with `ERX_EEXIST`
  (design-programs.md, "The loader's bootstrap"). State in the design where the kernel places these pages, apart
  from both, and check it against the ABI's places at build time, as `liberx/backend/fiasco/time.h`
  asserts that its fixed task area ends below the window.
* [Medium] `tools/lib/erx/chokepoint_rules/display.rb`, [Chokepoints](design-display.md#chokepoints): no build
  check enforces that only `erx_winfs` and `erx_input` call `erx_wm`'s callbacks, `erx_input` alone `input/4` and
  `erx_keymap`; add the xref check the chokepoint table names, with a seeded violation.
* [Medium] chokepoints, regions ([design-display.md](design-display.md), the `wrap/4` row of the chokepoint
  table): nothing in the build limits who calls `erx_region_view` (only `erx_memdraw_nif.c`) or
  `erx_device_region_memory` (only `erx_device_nif.c`), each a writable pointer into memory a device reads. Add both
  rules to `tools/lib/erx/chokepoint_rules/`, each with a seeded violation.
* [Low] `tools/lib/erx/chokepoint_rules/device.rb`: "no loop over device-written bytes in the NIF" and "within `erx_device.c` only `write_address` writes a ring's address register" have no check: the first holds as `erx_device_complete` copies with `bcopy` alone, the second by reading the file; a check needs a function-level site.
* [Medium] watchdog, `liberx/backend/api.h`: `erx_watchdog_pet` takes no `POWER` resource as `design-kernel.md`'s does.
* [Medium] kernel, `kernel/core/debug_log.c` keeps the ring and its console
  buffers in file statics, and `tools/fuzz/dispatch_fuzz.c` a static UTCB and
  rate, so a fuzz crash can depend on earlier inputs. Make the log an object
  `erx_sys_caller_t` points to.
* [Medium] chokepoint, `erlang/apps/erx/src/erx_log.erl` `take/0`: one module alone takes the kernel log, the log service, `erx_syslog`, under [design-log.md](design-log.md#invariants) (L4), but no build check says so, and any root process can call `erx_log:take()`; a second caller takes lines from the log for good, and no loss is counted. Add a check in the manner of `tools/lib/erx/chokepoint_rules/device.rb` that refuses `erx_log:take` outside that one module, and a C rule that keeps `erx_log_take` and `erx_debug_log_take` to the NIF, the two backends and the core, each with a seeded violation.
* [Medium] chokepoint, the log line (`erlang/apps/erx/src/erx_syslog_core.erl`, `line/5`): [design-log.md](design-log.md#invariants) (L2) has `line/5` as the one function that turns a domain's text into a line, but only a test says so. Either add a build check that only `erx_syslog_core` builds what enters the console's and the store's backlogs, or make it hold by construction (the backlogs take only a line type only the core makes), with a seeded violation.

## Bugs by subsystem

* [Low] Seam headers the glue cannot include, `include/erx/core/`: `bcm2711_pins.h`,
  `vc_mailbox.h` and `vc_property.h` include `erx/abi.h`, `debug_log.h` includes
  `erx/log.h` and `pm_wdt.h` includes `erx/watchdog.h`, none of which the core archive
  copies into the seam, so Fiasco C++ glue cannot include them, and each declares
  functions outside extern "C". Give each the generated seam header it needs, as
  `abi_stop.h` serves `machine_stop.h`, wrap its prototypes, and take it off
  `SEAM_UNCLEAN` in `test/host/core_archive_test.rb`.
* [Medium] crash fuzz, `tools/fuzz/crash_frame.rb`: the Ruby reader's target mutates
  framed bytes without fixing the CRC, so its record checks (registers, frames, CPU
  entries, text) and `report` are never reached. Add a full seed with entries and a mode
  that mutates the record, recomputes the CRC and frames it.
* [Medium] watchdog, `erlang/apps/erx/src/erx_watchdog.erl`: the process pets unconditionally
  and makes no liveness calls, where design-system.md (A6, and the failure table's row for a
  domain service that stops answering) has it pet only after every listed service answers
  within the period, and kill a domain service that does not, whose end then ends the
  machine. A deadlocked domain service therefore leaves the machine up. Make the calls.
  Until then `Manifest::Check` refuses a manifest's `liveness` row (`tools/lib/erx/manifest.rb`).
* [Medium] CPU grants, `config/manifest/development.txt`: the storage and network domains each take the users share, 900 mcpu, 1,800 of the 2,325 mcpu that the system share's reserve leaves configured domains (`dom_system_reserve`, `liberx/system/dom_core.c`), and the web, display and PCIe domains 300 more, 150, 100 and 50, none of them measured, so 225 mcpu remain for a further configured domain. Size each service domain's grant from its measured use, or grow the reserve's bound, before a configured domain is added that needs more.
* [Medium] Kernel page funnel, `kernel/core/page.c` and
  `kernel/core/page_impl.h`: a page record holds only its link and stamp,
  so nothing says where a page is. `erx_page_release` checks counts, not
  which pages its in-use chain holds, and `erx_plist_push` cannot see a
  page already on a chain, so a kernel path that releases a page twice or
  another reserve's page corrupts the released list silently. Add the
  design's owner and a place tag to the record, set by every push, pop and
  splice, and refuse a release or push whose pages are not where it says
  with `ERX_EINVAL` before anything changes.
* [Medium] Kernel page funnel, `include/erx/page.h`: `erx_backing_step`
  leaves to each caller the duties of stepping to `ERX_BACKING_DONE` or
  `ERX_BACKING_CANCELLED` (a caller that stops early leaks its hand and an
  admission stays counted) and of reading its existence locks for
  `closed`. Give the stepper one caller, the backing loop that owns the
  preemption points, with a call-graph chokepoint, and the same for
  `erx_released_free` and the reaper's step. The members of `erx_plist_t`
  and `erx_backing_t` are public in the header with no rule keeping other
  files out of them; add one with P6's cross-cutting chokepoints.
* [Medium] Kernel budget core, `kernel/core/budget.c` and
  `kernel/core/budget_impl.h`: the record carries its own `parent`
  pointer and takes its lock through `erx_effect_budget_lock`, standing
  in for the object header's budget field and the core's ticket lock
  (`erx_spinlock_t`), and the reserve record holds the pool's count
  beside the chain that `kernel/core/page.c` moves, so
  the two agree because only `page.c` calls the steps (its call-graph
  chokepoints) and checks them in host and debug builds. When the object
  header and the ticket lock land, embed them in the records, drop the
  lock effect, and give `erx_reserve_fill`, `erx_reserve_use` and
  `erx_reserve_refund` the chain itself, so the pooled count is the
  chain's length by construction. A record embeds the header in its
  header area (`ERX_OBJECT_HEADER_BYTES`, `erx_object_body`), as the
  child budget's record in its parent's cache already does; the budget's
  own `parent` then becomes its header's `budget`.
* [Medium] Kernel deletion core, `kernel/core/delete.c`: a budget's own
  object finishes its destroy (its put handed out) before the
  budget-death walk empties its `att_charged`, so for a budget the put
  does not wait for every attachment field as the teardown contract
  says; the record is freed only at its object's last put, after the
  walk's reference and the one its counters hold until the tombstone's
  put, so nothing is freed early. Making the walk the teardown's last part for `ERX_K_BUDGET`, a
  part `erx_delete_step` hands out, would make the order hold by
  construction. The carve's caller puts the child's header on the
  parent's list in a second hold of the parent's lock, so a parent
  destroyed in between leaves the caller to close the child; passing the
  object store to `erx_budget_carve` would put both in one hold. The
  deletion model (`test/fixtures/delete_model.c`) does not yet walk a
  child budget or a space's tables.
* [Medium] Kernel cores, `att_charged` (`kernel/core/delete.c`,
  `kernel/core/attach.c`, `kernel/core/budget.c`): three caller duties
  have no check yet. A destroy's runner must call `erx_delete_uncharge`
  at the drain (recording it in the `erx_delete_t` and trapping in
  `erx_delete_step` when the destroy leaves CLOSED without it would make
  a forgotten unlink loud); a record on a list must never be freed
  outside a destroy (the record-free funnel should trap on a member); and
  the carve's caller must take the reference the child's counters hold.
  `erx_kcache_take` has no caller now that the carve takes its own
  record: delete it, or refuse `ERX_KCACHE_BUDGET`, until a second record
  kind exists. Tests: the deletion model's publication actors P and U
  move only model state (no core runs, and `DU` shows the same
  violation as the seed `KU`); a second object charged to B, attached by
  an actor racing K through `erx_attach_budget_charged`, would make the
  seed exercise the insert's dead check. No test pins the walk's take
  (its unlink or its counted reference) by a named diagnosis, nor the
  driver's `put` between walk steps. `erx_object_init` accepts a NULL
  budget, which `erx_delete_uncharge` dereferences; the design text names
  `erx_dlink_t`/`erx_dlist_t` where the code has `erx_charged_list_t`.
* [Medium] Kernel mapping-record core, `kernel/core/map.c`: `erx_map_apply`
  takes no proof that the caller charged a part's `charge_pages`, and
  `erx_map_edges` no proof that it runs after the apply, though it reads the
  records as they stand. A caller that gets either order wrong makes a
  read-write record with no pages behind it, or keeps a table past its
  promise. The reserve plans of `erx_vm_plan` should take both into the one
  plan, so no caller orders them.
* [Medium] Kernel space creation, `docs/design-kernel.md` ("Virtual memory"):
  the placement base has no stated range. The design needs its window (the top
  part of the user half, below fixed-address images and `liberx`'s fixed
  placements, with a build check that they do not meet), its alignment and
  entropy, its deterministic-mode value, and that kernel-user pages and the
  random base of a position-independent image draw from the same window.
* [Medium] Kernel private memory objects, callers of `erx_map_plan_insert` and
  `erx_map_plan_part`: `include/erx/map.h` names `erx_vm_commit`, `erx_image_map`
  and `erx_space_copy` as the only makers of a space's private objects, which
  the core cannot check since it never dereferences a handle. When they land: a
  chokepoint rule holds those three sites; a trim takes its object through the
  kind-checking accessor, so a shared object fails loudly; a writable image
  segment keeps its source on the object as slice, slice offset and first page;
  and the private page tree splits by offset range, so a part's trim goes to the
  reaper as one subtree.
* [Medium] Kernel range calls, callers of `erx_map_plan_part` and
  `erx_map_mark_deleted`: a protect's part and a deletion clear translations in
  place, and must do so through the table step of the edge rule, one table
  between preemption points, since the core's part spans a whole record. A
  deletion's table step is what the core's `ERX_MAP_DELETED` record assumes.
* [Critical] Kernel memory design, `docs/design-kernel.md` ("Virtual
  memory"): the map core's design review (branch
  `shelved/fault-reserve-memory-and-map-doom`, commits `8f893069` and
  `58d89236`, not landed) left three findings open for Phase 2's memory design.
  (Critical) A release's private pages leave the page tree after the
  range is reusable, so a racing commit can map a page that the release
  then frees. (High) The step machine plans outside the lock and has no
  result for a stale plan. (High) The deletion walk's lookup of a
  record's space is not designed. The reviewing agent recommends that a
  fragment inherit its origin's attachment, which removes most of the
  mechanism of the core's third item, and that the boot-image slice's
  rights become (MAP, READ); both still need checking.
* [Low] Kernel mapping-record core, `kernel/core/map.c`: `erx_map_check` judges
  a node's summary with the core's own `map_update`, so a bug in that function
  shows only through the behaviour tests, not the check; and `MapModel` shares
  the core's choice of which record a split reuses. Compute the summary a second
  way in the check.
* [Medium] Kernel space core, `kernel/core/space.c`: the core keeps a
  space's place in the tree and its run state, and decides creations
  and the steps of the stop and deletion walks; what the design puts
  beside it in `erx_space_t` is the integration's (WP16, WP25, WP39).
  Each space's count of children whose exit records are not posted
  belongs in `erx_space_attach`, the one place a child joins, and its
  decrement beside the exit record's posting. A deletion's first
  critical section must also invalidate the space's existence lock and
  set the table's emptied flag
  (`erx_cap_table_set_emptied`): the core unlinks the space under the
  parent's lock and returns `ERX_DELETE_SPACE`, so the caller takes the
  table's lock inside the parent's, which the lock order allows (a
  space's lock at 3, a table's at 4), and sets the flag before dropping
  either. It then empties the table through `erx_cap_slot_clear`, and
  runs the destroy of any space whose last capability a clear removed
  only after the table's lock is dropped, since that destroy takes a
  space's lock. The walks' counted
  references (each walk's root and held space), `erx_space_record_init` after
  the allocation, the reaper's two free steps (`erx_space_free_ready`,
  which runs exactly once, and `erx_space_unhold_parent`:
  the object core should trap a second, and a counted reference rising from
  zero, in debug and host builds), the threads' kill
  list (`test/fixtures/space_driver.c` stands in for all of these) and
  `erx_space_stop`'s refusal of the kernel's exit statuses are the call
  layer's. The values of `ERX_EXIT_PARENT`,
  `ERX_EXIT_RELEASED` and `ERX_EXIT_NOTHREAD` (`abi/erx_abi.txt`,
  INT64_MIN + 1 to + 3) were chosen here, where the design names them
  without values; confirm them before a runtime relies on them.
* [Medium] Kernel space core, `kernel/core/space.c`: K27 asks that every
  stop of a space be made by, or start, one of the two walks, but
  `erx_space_stop` stops one space and leaves starting the walk to each
  caller (the stop call, the last thread's exit, `ERX_EXIT_NOTHREAD`,
  the destroy). Fold the root's stop into `erx_stop_walk_begin(walk,
  root, status, stopper)`, reporting whether it stopped the root, and
  drop the single-space stop, so every stop has its walk by
  construction. Likewise the threads' order (new threads at the front,
  killed ones at the end) is the caller's, and `erx_stop_step` trusts
  the caller's report of the first thread; move the thread list into the
  core with WP25.
* [Medium] Kernel space integration (WP25, WP39), `include/erx/space.h`:
  the core decides the walks and the exit word, and the space destroy is
  the integration's. Split it into one space's own teardown (drain, empty
  its table, detach its mapping records, withdraw its exit record, queue its
  put), which `ERX_DELETE_SPACE` runs for each space and which starts no walk
  and reads no close result, and the destroy (close, drain, stop, stop walk,
  `erx_delete_walk_begin` and the step loop; a close that says `ERX_ESTALE`
  or a begin that says DONE stops there, queuing no put). Add a chokepoint:
  that one function is referenced only from the `ERX_DELETE_SPACE` handler,
  with a test seeding a second caller. The queue of exit records and the
  gate's `exits_dropped` are stand-ins in `test/fixtures/space_driver.c`
  until the integration exists, and `erx_space_clear_caps` has no host test,
  so K27's domain tests are what prove them: the fixture has one queue, so
  it cannot show a record moved between receivers. The word's orders are
  explored single-threaded; add a race when the post has its real path.
* [Medium] Kernel exit records, `docs/design-kernel.md` ("A deletion takes the
  record with it"): the withdrawal needs a place for each record, one ordering
  lock and a word, because the record lives in the space it reports. Weigh
  keeping a posted record in a small fixed record charged to the creator: it
  pins no space, so the withdrawal, the word and the count go, the creator
  learns of every end, and only a party that refuses to receive pays.
* [Medium] Kernel space lifetime, `docs/design-kernel.md` ("Who owns a
  deletion"): a deletion below a space rests on the thread of the call that
  unlinked it, and that thread's group may be unscheduled, leaving the spaces
  below stopped but undeleted and their capabilities answering, one chain
  per stalled call (Security states it). Decision needed before the security
  closure milestone: run the rest of a begun deletion at the finishing level;
  or keep a space listed until its parts end, so a second walker shares them
  and descends, as stop walks do (recommended, since it removes the
  dependence on another's thread); or keep the stated limit.
* [Medium] Kernel objects, `docs/design-kernel.md` ("Closing and deleting"):
  a deleted IRQ object leaves one last delivery at its target, and a posted
  delivery holds a counted reference on its object until it is taken, so a
  target that never receives keeps the IRQ object's record, on whatever
  budget paid for it. Decide it as a space's exit record is decided
  (withdraw and count at the target) or state the bound in Security.
* [Low] Kernel space status, `abi/erx_abi.txt`: `ERX_EXIT_RELEASED` is seldom
  received, since a destroy withdraws or drops the record of a space it
  stops. Decide whether it still earns its place in the status set.
* [Low] Space core tests, `test/fixtures/space_model.rb`: the model cannot
  represent a table emptied by `erx_space_clear_caps` before its space's
  deletion, since it holds `emptied` equal to deleting; add a `clear` command
  when the call exists.
* [Medium] Space core tests, `test/host/space_test.rb`: the
  acquire/release claims on a space's run word and the publication of
  the first stop's status and stopper are exercised single-threaded
  only; add a ThreadSanitizer race of stops, walks and `erx_space_read`
  and list it in `tools/erx check-sanitizers`. The state assertions match
  regular expressions over the driver's positional state line, and the
  refusal table spells raw `plan` commands; parse the line into named
  fields and give the refusals a keyword helper. Untested: a
  `parent_self` request naming another record, `erx_space_init_first`'s
  refusals, `erx_space_attach` with object 0, and the ancestry check
  ahead of the depth limit (no case has a parent outside the tree at the
  deepest level).
* [Medium] Space core tests, `test/host/space_test.rb`
  (`test_the_drops_of_a_hold_race_under_thread_sanitizer`): the mutant
  with the drop's `memory_order_acq_rel` relaxed, built from
  `test/fixtures/space_holds_race.c` under ThreadSanitizer, printed
  nothing and hit its 300 s deadline in two runs on an Apple Silicon host
  under a load average of 13 to 20, while the unmutated program finished
  in about 2 s; the test then fails with an empty log and fails
  `make check`. Find why the relaxed program hangs instead of reporting
  the race, and make it end with the report.
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
  sequence-counted accessor rule does not exist yet and is not in the
  registry. It reads the syntax trees as the `Chokepoints::Writers`
  rules do (`tools/lib/erx/syntax_tree.rb`), counting reads as well as
  writes, for every record the ABI file declares sequence-counted.
* [Medium] Kernel chokepoints, the syntax-tree rules
  (`tools/lib/erx/syntax_tree.rb`): they read only the cores
  `CoreArchive` compiles, in the archive's configuration, so the glue's
  C++ (a `reinterpret_cast` of an `erx_budget_t *` there), liberx and
  code under another configuration's `#ifdef` are not read. A guarded
  member's uses are a closed set (a load, an atomic load's pointer,
  sizeof, a cast to void; any other use is a write), but a record
  pointer's are not: a pointer passed through `...` or a union of
  pointers, a declaration that disagrees with its definition in another
  file, and an embedded record zero-filled by its container's
  initializer still pass. Closing them means inverting the pointer's
  uses too: outside the sites, allow a record pointer only as the base of
  `->`, a parameter, variable or return value of the same record pointer
  type, and an operand of a comparison, and count everything else as a
  write.
* [Medium] Kernel chokepoints, `tools/lib/erx/chokepoint_rules/`: the
  text rules match whole names, so a name a macro pastes together
  (`erx_cap_slot_ ## clear`, `erx_ ## cap_slot`) gets past
  `cap-slot-clear-named`, `budget-records-private`, `cap-table-private`
  and `cap-slot-private`. The syntax-tree rules (`budget-counters`,
  `cap-table-writers`, `cap-slot-writers`, `object-state-writers`,
  `rights-built-in-cap`) see through macros and refuse a cast of a
  pointer to a guarded record outside its writers, so no pasted name or
  hand-copied offset writes one; a pasted call of `erx_cap_slot_clear`
  from outside the cores, or a pasted definition of a private record,
  still passes. Localize every symbol of `erx_cores.a` not on its API
  list. The design: the API list is what the seam headers
  (`include/erx/core/*.h` and their generated twins) declare, read from
  the syntax tree of a source that includes them all, so a new seam
  declaration needs no entry; `CoreArchive.build` links the members
  into one object with `ld.lld -r`, keeps only that list global with
  `llvm-objcopy --keep-global-symbols`, and archives the one object,
  while the stack proof keeps reading the members. It needs `ld.lld`
  passed to the core build (it is not beside clang), and the Fiasco
  build audit (`FiascoProvenance#audit_executable`) to accept a member
  whose construction record is the members' compiles, so it lands with
  a Fiasco build that proves the link. Have the object leg also read the
  cores' debug information (a `-g` compile with `-fdebug-prefix-map`,
  so the archive stays reproducible), so no object but its core's
  defines a private record. The text rules also miss an include through
  a macro in inherited Fiasco, which `include-form` does not read, and a
  `-include` flag in a build file. Nor does any rule stop a caller that
  keeps its own untyped pointer to a table, its directory or a page it
  handed to the core from writing their bytes; the space core should
  allocate them from memory nothing else maps.
* [Medium] Kernel chokepoints, `tools/lib/erx/chokepoint_rules/`:
  `cap-slot-clear-callers` reads only the cores' call graph, so
  `cap-slot-clear-named` keeps `erx_cap_slot_clear` out of the Fiasco glue
  altogether. When the glue (WP12) gives the close and the space's
  emptying their callers, extend the caller check to the glue's objects
  and add the deletion walk's slot-clearing effect by name.
* [Medium] Capability core, `kernel/core/cap.c`: the table's owner hands
  `erx_cap_table_add_page` each page's storage, so the core can refuse a
  page that overlaps its own table, directory or pages, but not one that
  another table already holds, and the check scans the whole directory
  under the table's lock on every page added. Have the core take its
  directory and pages itself through the budget-charging allocation
  effect, so no caller supplies a page pointer and both the scan and the
  aliasing go away
  ([design-kernel.md](design-kernel.md#objects-and-capabilities)).
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
  ([design-kernel.md](design-kernel.md#chokepoint-checks)).
* [Medium] Capability core, `include/erx/cap.h`: a pass's route is a closed
  enum the plan records with both tables, but the caller still states it,
  so a rendezvous that passes `ERX_PASS_OWN_TO_CREATED` by mistake plans
  under the creator's rule. Derive it by construction: a rendezvous entry
  point that takes no route, and `erx_cap_pass` deriving the route from the
  tables' owning spaces, which needs an owner word in the table.
* [Medium] Capability core, `kernel/core/cap.c`: `erx_cap_install_copy`
  shrinks a fork's copy by a mask its caller passes, so K24 for
  `erx_space_copy` rests on that caller passing the type's pass set; and
  `erx_cap_install_kind` accepts any creation kind of the object's type,
  so a budget installs as a root or a carved budget at the caller's
  choice. Record the creation kind in the object's header at
  `erx_object_init` and install from it, and give the copy a purpose (dup
  or fork) that applies the pass set inside the core; decide whether a
  fork skips a type with no pass set.
* [Medium] Capability core, `kernel/core/cap.c` and design-kernel.md's
  chokepoint rows: the design says only `kernel/core/attach.c`'s insert
  functions link onto an object, but the slot list's insert is cap.c's
  `cap_list_insert`, and a pass counts at its take and links at its
  install, correct only while its caller holds every object's capability
  lock from planning to install, which nothing checks. Reconcile the row
  with P3's attach core and assert the lock in debug builds.
* [Low] Capability core, `kernel/core/cap.c`: a taken plan that is never
  installed keeps its counts, so its objects are never released; nothing
  but the caller's sequence enforces the install. Assert it in host and
  debug builds with the other pass preconditions. No concurrent test
  races `erx_cap_install_copy`'s lockless source read against a writer of
  the source table.
* [Medium] Capability core, `kernel/core/cap.c`, for the deletion core: a
  teardown walks its object's slot list and must clear each slot through
  `erx_cap_slot_clear`, which takes the slot's table and value; a listed
  slot holds its table and generation but not its index, and its 64 bytes
  have no room for one, so the index is found by scanning the table's
  directory. Decide between that scan, a clear by slot address that stays
  the one clearing function, and pages that record their first index.
* [Medium] Capability core, `kernel/core/cap.c`: a pass is read sources,
  plan, take, install and release the reservation, and growth is
  `erx_cap_table_pages_needed`, allocate and `erx_cap_table_add_page`,
  each a sequence the caller strings together (the plan's stage already
  makes take and install run once each, in order). When the Fiasco glue
  (WP12) gives them their callers, give each operation one effect-edge
  function around the pure plan so no caller can reorder or skip a step.
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

* [Medium] scheduler, the pick core is configuration C0's
  (`kernel/sched/sched.c`, `erx_sched_pick`): it has no finishing level,
  no throttled lists and no published urgency yet, which the design's
  Pick and dispatch names and erXos's own kernel needs. Fiasco keeps
  Fiasco's ready queue until it leaves, so nothing on the target calls
  `erx_sched_wake`, `erx_sched_remove` or `erx_sched_pick` before Track K's
  kernel does. The pick also has no way to give back a thread whose switch is
  refused because a helper runs it, which the design's finishing level asks for.
* [Medium] scheduler, who refreshes (`include/erx/sched.h`,
  `erx_sched_group_configure`): S5 rests on every caller that changes a base
  or a ceiling walking the threads below it. Have the configure report what
  changed, or the core own the walk's plan, when the first caller lands.
* [High] scheduler, Track K, the cross-CPU protocol has no model and no code
  ([Concurrency](design-scheduler.md#concurrency), `include/erx/sched.h`).
  It does not block M1: Fiasco keeps its own dispatch, and nothing on
  the target calls the core's pick. The first deliverable is the model the
  design's Verification names, with the stack switch as separate steps; no
  code calls `erx_sched_pick` across CPUs before it passes. Then transcribe
  Fiasco's `Pending_rqq::handle_requests`, `Context::drq`, `migrate_away`,
  `migrate_to`, `kernel_context_drq` and the kill's request wait into C17
  against it.
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
  [design-scheduler.md](design-scheduler.md#verification-and-testing)
  names, when Fiasco can produce them.
* [Medium] scheduler, S4: a deferred preemption lets an executor run
  `grace_us` past exhaustion as debt, so a period can reach the quota plus
  one quantum plus the grace per CPU, where S4 promises one quantum.
  Post the yield request a grace before exhaustion, or restate S4 with the
  grace ([design-scheduler.md](design-scheduler.md#invariants)).
* [Medium] kernel and scheduler, wake fan-out: one trigger of a
  device's IRQ object bound to a group may wake every parked executor of
  the group, up to 64 threads, outside K13's bound on a stretch with
  interrupts masked. Bound the fan-out of one trigger, or wake one executor
  per trigger and let the runtime wake the rest
  ([design-kernel.md](design-kernel.md#invariants),
  [design-scheduler.md](design-scheduler.md#park-and-wake)).
* [Low] kernel ABI generator, `tools/lib/erx/abi_model.rb`: a private
  layout stays out of every public declaration by three separate
  refusals (embedding as a field, as a tail, and projection), so a new
  construct that names a layout (a reader table, a call argument) must
  remember a fourth. Walk every type reference of the schema once, after
  parsing, and refuse each one from a public declaration to a private
  layout, so the property holds for any construct
  ([design-abi.md](design-abi.md#source-grammar)).
* [Medium] kernel ABI generator, `tools/lib/erx/abi_model.rb`: a
  record's `version` field is tied to its `*_version` limit only by
  naming, and the names differ (`erx_boot_info` uses `boot_version`,
  `erx_image_manifest` uses `image_version`), so nothing refuses a
  versioned layout without its constant or a writer that stores another
  value. Add a layout member naming the field's constant (`value version
  @time_page_version`, as `reader ... value root.version
  @manifest_version` already does), have the generator emit the encoder's
  store and the decoder's check from it, and refuse a `version` field
  without one ([design-abi.md](design-abi.md#numeric-assignment-and-versions)).
* [Low] kernel ABI, status codes: `ERX_EDEAD` carries two meanings (a
  dropped caller and a dead target). Split it, or state why one code
  serves both
  ([design-kernel.md](design-kernel.md#calling-convention-and-status-codes)).
* [Low] kernel and arch-aarch64, `ERX_DMA_MSI_IOVA`: the constant is a
  GICv2m fact in a generic name. Move it to the platform layer's MSI frame
  description ([design-kernel.md](design-kernel.md#dma-and-the-iommu),
  [design-platforms.md](design-platforms.md#msi-frames)).
* [Low] kernel, `ERX_MEM_INHERIT`: the flag is the remembered creator mark
  that the copy table of `erx_space_copy` says it avoids. Reconcile the
  two
  ([design-kernel.md](design-kernel.md#copy-on-write-children-and-copies-of-spaces)).
* [Medium] kernel, boot image: `erx_image_slice` needs the verdict table and
  hashing in parts of 64 KiB, which `erx_pack_file_check`, hashing a run in one
  call, cannot give it. Make it a pure stepper the core owns, computing the
  digest itself, not a digest the caller passes in, so that function stays the
  one check. The slice also needs `pack.c` in the kernel's archive and its stack
  proof as well as in `bootstrap`, and must decide what a run of only empty
  files, an object of no pages, returns. Until it lands nothing checks a file
  `bootstrap` does not place, so a file cut short inside `system/root` boots,
  though [design-kernel.md](design-kernel.md#the-bootable-file) counts it as
  refused. `tools/erx pack` stays refused until the M1 root startup, so
  `--two-file` and the slot refusal wait for it.
* [Medium] kernel boot, `kernel/core/boot_place.c`: the handoff record's
  `pool_usable`, `pool_heap` and `pool_regions` are zero in Phase 1, which
  has no reader for them
  ([design-fiasco.md](design-fiasco.md#boot-handoff)). Track K
  gives them values from `erx_pool_plan` (`docs/design-kernel.md`) and a
  reader in erXos's kernel, and settles where `kip_size` and the kernel's
  alignment live; they are limits of `abi/erx_abi.txt` today.

## Security residuals

* [Medium] `tools/lib/erx/chokepoint_rules/fiasco_seam.rb`, `one-erx-trap`: the raw-word half names a list of
  directives, and gas has more that place words: `.xword`, `.dword`, `.int`, `.short`, `.octa`, `.fill`,
  `.ascii`/`.asciz`/`.string`, `.dc.*`, `.inst.n`/`.inst.w`. `__attribute__((section(".text")))` data needs no
  directive at all. Neither does a directive that only a compiler joins: adjacent literals on separate lines,
  a prefixed literal after another, a hex escape (`"\x2eword"`, which the C view reads as a space, not
  decoded) or a `%c` operand. The trap half misses the same joins. In a `.S` file, an empty macro or a
  label macro before the dot (`E.word`, `L(foo).word`) reads as a C member access and is exempt. What makes this hold by construction is checking the object, not the source: disassemble each
  erXos object's code sections and refuse any trap or data word outside liberx's backends.
* [Low] `tools/lib/erx/chokepoints.rb`, `CView`: `ADJACENT_LITERALS` joins literals with a regex over the
  view's text, so a literal ending in an escaped quote (`".section \".text\""`) loses that quote and its
  closing quote. The line then reads as one unterminated literal, not as the compiler's literals. Join
  adjacent literal tokens inside `strip_comments` instead.
* [Medium] kernel design, `docs/design-platforms.md` "Data model": erXos's kernel binds the devices of
  `hw/kernel_devices.txt` (the RNG200, the watchdog, the mailbox) by compatible string from the device tree
  alone, so a tree that names another device's page under one of those strings would have the kernel drive
  that page. On Fiasco the root confirms the RNG200's checked-in platform row against the tree
  (`erx_dt_registers`); release needs the kernel's bindings confirmed against checked-in rows the same way.
* [Medium] `tools/lib/erx/chokepoint_rules/memdraw.rb`, `memdraw-pixels`: the rule names `erx_area:zero/3` as the
  area NIF's one writer, but its pattern (`bdata`, `byteaddr`, `wordaddr`) does not see a store through an area's
  `addr` or `erx_area_view`'s `base`; add a check that only `map_nif`, `zero_nif` and `erx_area_view` read them,
  with a seeded violation.
* [Low] scheduler and budgets, a group's charge
  ([per-CPU records](design-scheduler.md#ownership-and-lifetime)): a group
  charges one `erx_group_cpu` record per CPU to its creator's budget, so a domain
  that creates groups and reads its spending through `erx_budget_watch` or a
  carved budget may learn roughly how many CPUs the machine has, which a grant
  read back does not tell it. When the records are written, charge every group
  for `ERX_CPUSET_BITS` records, or state that the count is not a secret.
* [Medium] scheduler, Track K and M11: request batches bound an interrupt's
  length, not how much of a remote CPU a sender consumes
  ([Concurrency](design-scheduler.md#concurrency)). A runtime that
  posts wakes and refreshes in a loop spends another party's time on the
  home CPUs of its threads, charged to whoever runs there, and a configure of
  a group whose threads a hostile child created takes as long as those threads,
  on the parent's time. Fiasco accepts this. Charge the receiver's work to the requester's path, as the finishing
  share's approach to kills does.
* [Medium] kernel, attributing asynchronous errors: on a board with PCIe,
  a device error caused by a posted write can be reported after the window
  that would attribute it, and then ends the wrong domain; one the
  processor reports as uncontainable panics the kernel. Use the
  processor's error records where it keeps them, and run an
  error-injection test on each board before drivers run on it. M12, which
  brings the boards, closes this or records the user's acceptance
  ([design-kernel.md](design-kernel.md#interrupts-time-and-entropy)).

## Planned features

* [Low] kernel and pipes, a pass reservation spanning a hand-off's batches
  ([design-kernel.md](design-kernel.md#passing-capabilities),
  [design-pipes.md](design-pipes.md#hand-offs)): `erx_cap_pass` reserves slots for its own
  four items alone, so an install into a running program whose table or budget fills partway through
  a hand-off stops the program. A reservation spanning a hand-off's batches would let a full table
  lose only its own end instead of stopping the program, and would close the window in which a
  program about to be stopped can write through a copy an earlier batch passed; needs a kernel design.
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
  capability ([design-kernel.md](design-kernel.md#system-call-dispatch)).
* [Medium] kernel dispatch, the retry action: the generator gives only a
  call declared `retry` a handler that takes `erx_sys_action_t`. The
  generated dispatch loop that runs such a call again from its capability
  lookup, and the build check that only the send's path returns
  `ERX_SYS_ACTION_RETRY`, with a seeded second returner failing it, land
  with erXos's kernel's dispatch and IPC send path (Track K).
* [High] chokepoints, the pending M1 rules of
  `tools/lib/erx/chokepoint_rules/`: the object leg (no liberx target
  object outside the fiasco backend references an `l4_` symbol or holds a
  trap but the ABI's, read with `llvm-nm` and `llvm-objdump`; it also
  closes the include-path gap the text rules cannot see, an `-I` flag
  reaching l4sys's headers); the linked-kernel call-site reader the raw
  allocator and pmem converter rules need; and the vector route. Each fails the check as
  soon as a file it awaits lands, except the files it lists as existing
  ([design-kernel.md](design-kernel.md#chokepoint-checks)). The native
  roots build liberx's target objects (for example
  `build/native-watchdog/root/liberx_backend_fiasco_end_how_c.o`), so the
  object leg waits only on its reader; until it lands its exemptions, the
  groups' `unchecked_objects`, grow with every new liberx source, and
  landing it deletes those lists.
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
* [High] kernel memory, file-backed memory objects with evictable clean
  pages, so that large-file `mmap` (LMDB, SQLite in mmap mode) and ML
  weights larger than free RAM work; needs a revised K6 (a fault may wait
  only on a party that already controls the faulting space) and a K6
  wording that separates guaranteed anonymous memory from evictable file
  memory ([design-kernel.md](design-kernel.md#invariants),
  [design-kernel.md](design-kernel.md#virtual-memory)).
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
  `erlang:statistics` use it. Replaces Fiasco's direct user access
  (Stopgap replacements above).
