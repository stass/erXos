# TODO

* [Low] liberx hosted backend (`liberx/backend/hosted/`): macOS and AArch64 only (`os_sync_wait_on_address`, `switch_stack.S`); a Linux host skips `test/host/hosted_function_api_test.rb`.

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
  use, the eager FP switch, and Phase 1's one service thread.
* [Medium] benchmarks (`tools/erx bench g3`, [research-g3-baseline.md](docs/research-g3-baseline.md)):
  repeat the G3 run for HVF and TCG on a quiet host, since the first run was
  taken at a load average of 44 to 55, and find why stock OTP on the host
  is slower than the guest at the same four operations under HVF.

## Stopgap replacements

* [High] kernel: replace the stopgap Fiasco with erXos's own C17 kernel
  once it boots Phase 1's system and passes the conformance suite, at milestone
  M7 (gate GK3), before the security closure of M11
  ([plan.md](docs/plan.md)). Every stopgap build carries GPL-2.0 code,
  Fiasco's `kobject_rpc.h`, without which the kernel does not build, and
  the kernel debugger's `jdb_object.cpp`, so any distribution outside the
  project, in source or binary form, waits for this replacement
  ([design.md](docs/design.md#dependencies)). The import also records
  the link closure of L4Re's `bootstrap` and `sigma0`, their `drivers-frst`
  UART support, and the licence of each library in it.
* [Medium] kernel, Track K, shelved Phase 1 work: three pieces of code
  written for the earlier plan, which put erXos's kernel semantics inside
  the Fiasco fork, stay on branch `shelved-phase2-cores` for Track K: the capability
  binding into Fiasco with the first capability calls (12a, commit
  `e2492a64`), the entry classification core (R-a, commit `e90fe78b`) and
  the quota pool's pure core (WP58, commit `c38b3ada`). Phase 1 on a
  near-stock Fiasco does not use them. Track K reviews each against
  erXos's kernel's design and lands what it keeps.
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

* [High] kernel, Track K, the one route from user mode: in erXos's kernel
  only the trap immediate of `abi/arch/<arch>.txt` reaches `erx_dispatch`,
  and the exception vectors and the synchronous entry from user mode are
  the kernel's own: `erx_user_sync_entry` over `erx_fault_classify` and
  `erx_entry_step` (`docs/design-kernel.md`), with a build check that no
  other route into the kernel exists (the pending `vector-route` rule).
  Phase 1 uses Fiasco's own routes and has none of this.
* [Medium] stopgap, untested glue paths: `erx_log_lock` has never run under
  contention, since the probe has one thread and no call makes another, and
  nothing exercises the alien and vCPU-user guard in `Thread::arm_esr_entry`.
* [Medium] stopgap, `erx_debug_log` on the target: until the root service
  lands, `liberx/backend/fiasco/log.c` runs the kernel's dispatch core in the
  root task with one static public UTCB, a hand-written copy of the generated
  stub, and `liberx/backend/fiasco/arch/aarch64/generated/trap.c` and `utcb.c`
  have no consumer; the service's request stub replaces them. The probe's
  calls run the same core in process on both backends, so its transcript shows
  the console path, the clock and the cross-compiled core, not a kernel entry.
  The test that a call keeps the caller's registers left with the trap route
  and returns with the `erx` backend's kernel.
* [Low] stopgap, `fiasco/kernel/src/erx/erx_probe.cpp` and `erx_syscall.cpp`
  are reference text for erXos's kernel, out of the build: `erx_syscall.cpp`
  names `Space::erx_log`, which is gone, so it no longer compiles.
  `tools/lib/erx/glue_imports.rb`'s `OUT_OF_BUILD` repeats
  `Modules.generic` by hand.
* [Medium] stopgap, native boot's seeded failures: `user_ptr` left 0, the
  archive's sub-type removed and shutdown removed were each run by hand and
  failed as [the verification table](docs/design-stopgap.md#verification) says;
  nothing in the tree repeats them, as `check-qemu-mutant` does for the debug
  log, and nothing shows that a write to the archive faults. The same holds
  for the crash frame's write removed. `make check-native-seeds` keeps the threads
  and watchdog suites' seeds.
* [Low] stopgap, the crash suite's end-path row: `erx_machine_end` runs only with
  `ERX_END_OFF`; under `-no-reboot` both ends exit QEMU, so the suite cannot tell
  them apart, and the refusal of a bad `how` has no case.
* [Low] tooling, `tools/lib/erx/native_crash.rb`: the pc check has no upper bound
  and `test/guest/native_threads`'s `QUEUE_SETTLE_NS` trusts a 50 ms sleep to order
  waiters, which a starved vCPU can break.
* [Medium] stopgap, `liberx/backend/fiasco/service.c`: a root thread's handle is
  its index, with no generation, so a stale handle names the index's next
  thread. The handle table of
  [design-stopgap.md](docs/design-stopgap.md#capabilities-in-fiascos-object-space)
  replaces it.
* [Low] stopgap, Fiasco's `Ipc_gate_obj::unblock_all`, `fiasco/kernel/src/kern/ipc_gate.cpp:142-166`: the gate dequeues
  a blocked sender and activates it afterwards, the race `Semaphore` closes with `Thread_sem_woken`, so a timed send can
  return first and the activation land in what the thread blocks in next. The root's one gate is created bound
  (`service.c:161`), and a sender blocks only on an unbound gate, so nothing in `liberx` reaches it. Other runtimes unchecked.
* [Medium] stopgap, the fork's executable pages under SMP: nothing runs a page rewritten on one CPU and run
  again on another, so instruction-cache coherence across CPUs and the reuse of an executable page are unverified:
  the native suites inspect only data after protection changes. The `native_memory` suite needs
  that case once BeamAsm's JIT alias exists.
* [Medium] stopgap, `liberx/backend/fiasco`, call table of `docs/design-stopgap.md`: `erx_cap_dup`, `erx_cap_close`,
  `erx_object_destroy`, `erx_object_info`, `erx_budget_create`, `erx_log_read`, `erx_group_configure` and
  `erx_group_info` have no body. Their consumers are the Erlang NIF handles, the launcher, the domain library's root
  entry and the Erlang log reader, which arrive with M3; each gets its body and a `test/guest/function_api` row then.
* [Low] stopgap, `test/guest/native_task/guest.c`, `request_against_exit`: no seed shows the dropped-request
  count can move, as the thread deletion seed stops the suite at its earlier `service` case.
* [Low] stopgap, `tools/lib/erx/native_semaphore_race.rb`: the race runs under TCG at 4 CPUs only, as every
  seed under `make check-native-seeds` does, and no gate runs it under HVF.
* [Medium] stopgap, `test/fixtures/fiasco_park_driver.c`: the exhaustive model reads the core rather than
  the status mirror, so `parked` not mirrored and a slot epoch mirrored relaxed pass every mode. It has one waker in flight, and judges a lost wake only with
  no event or timeout left, so a stuck absorb with no work passes. A two-waker variant and a check of every
  quiet state passed the core by hand (623,596 and 287,527 states) and should replace them.
* [Low] stopgap, `test/guest/native_threads/guest.c` and `test/guest/function_api/cases.c`,
  `park_timeout_races_wake`: between its racing parks and its quiet ones the helper waits through `settle`,
  a umtx wait on the semaphore the park shares, so an up the race left over returns that wait early and is
  gone before the quiet park looks. The quiet park catches only an up arriving after `settle`; a wait that
  does not block on the semaphore, or a zero-deadline down right after the race, would catch both.
* [Medium] stopgap, `liberx/backend/fiasco/time.c`: the time page is the root's own page, not yet mapped read-only into a
  test task, whose reads need it; the second task's `erx_vm_map` is the mapping's way in.
* [Low] stopgap, `liberx/backend/fiasco/group.c`, `irq.c`: `erx_group_configure` and `_info` have no body until the adapter
  (M3) calls them; an IRQ object is never unbound or destroyed, which a restarted block driver would want.
* [Low] stopgap, `liberx/backend/fiasco/entropy.c`, `vm.c`: what needs the root to read the manifest. The generator starts from the
  counter alone, not yet the manifest's seed; one contiguous pool exists whatever the device entries ask for, and it serves any device.
* [Medium] stopgap, `liberx/backend/fiasco/vm.c`, `liberx/backend/core/vm_table.c`: the range table sees an object's mapping as uncommitted, so
  `erx_space_protect` over mapped registers or a mapped run returns `ERX_OK` and puts a fresh pool page there, and a decommit or release leaves the
  mapping reachable. No caller does either. Nothing tests a task that ends holding a physical or contiguous object, so `vm_give`'s address check and
  the index's room for run pages stay untested. A restarted driver spends device window pages and contiguous runs each life, since neither comes back.
* [Low] stopgap, `liberx/backend/hosted/vm.c`: `erx_mem_create` and `erx_vm_map` have no hosted body, which the call table's row asks for, so
  `test/guest/function_api` holds no shared object's case and its device cases stay native alone.
* [Low] `otp/erts/emulator/beam/erl_process.c`: the safe point of `docs/design-runtime.md`, "Scheduling", handles the ready list only: its
  capacity and urgency steps land with the adapter that publishes them.
* [Medium] `otp/erts/emulator/beam/erl_crash_dump.c`, `beam/bif.c`, `sys/erxos/sys.c`: what `imports.txt` lists as `[stock_descriptors]`
  and the rest of `[stock_process]`: the crash dump's file, which `open` refuses with `ENOSYS` until the crash area replaces it (edit 34),
  `erlang:display` and `halt`'s output, the terminal's `sys_get_key` and `ethread`'s signal masks. Each is answered as `ENOSYS` tracing shows it.
* [Medium] `liberx/backend/fiasco/group.c`, `liberx/backend/hosted/group.c`: `erx_irq_bind` differs between the backends: Fiasco's refuses every
  group but its own handle, so `ERX_CAP_SELF` and unbinding with `ERX_CAP_NULL` fail there, and `erx_event.h` tells a caller to unbind first.
  The first native consumer needs the unbind defined in the interface, with its status checked.
* [Medium] `otp/erts/emulator/sys/erxos/sys.c`, `beam/erl_crash_dump.c`, `beam/bif.c`: what `imports.txt` lists as
  `[stock_process]` and `[stock_descriptors]`, the UNIX process ERTS still assumes: the signal dispatcher, `sigaction` and the pipes of
  Darwin's main thread, `nice`, `alarm`, `uname` and the crash dump's descriptors (edit 34). The first native boot answers each,
  as `ENOSYS` tracing shows it;
* [Low] `test/fixtures/runtime_event_harness.c`: the sleep step's model copies the park core by hand and has no waker; driving
  `erx_backend_park_step` and a waker would pin the reason the epochs come before the flag.
* [Low] `otp/erts/preloaded/src/prim_inet.erl`: `gen_tcp:listen` answers `{error, eprotonosupport}`, stock's answer for a
  missing inet driver, where `docs/design-runtime.md` says `{error, eacces}` without a grant. The design is the target and
  stays; the answer changes with the network service's grant check or a preloaded rebuild.
* [Low] `otp/erts/emulator/test/binary_SUITE.erl`: `make_port/0` is `hd(erlang:ports())`, and `ports()` is empty by design,
  so its term-ordering cases fail with `hd([])`. Opening `{spawn_driver, "ram_file_drv"}` there gives a real port (checked on
  hosted), and is the route when the suite is next run for its results.
* [Low] `otp/erts/emulator/test/process_SUITE.erl`: `max_heap_size_test/5` fails with `{badmatch, noproc}` under a runner
  with no common_test, because `ct:log` delays its monitor past the process's death. It needs a run under `ct_run` to tell
  whether this is the runner alone.
* [Medium] `test/oracle/erx_ct_oracle.erl`, `config/manifest/qemu-virt-development.txt` (`tmp 167772160`): a whole
  group's `/tmp` use is bounded only by the cap. `erx_ct_oracle` copies every suite's `_data` (stdlib's are 25 MB) into
  `/tmp` before the run, and Common Test's logs and each `priv_dir` stay there. The whole stdlib group fits
  in the 160 MiB cap without `enospc`; the emulator group is untried, and kernel's `file_SUITE` bench and
  `sendfile_SUITE` write more than the cap by design. Copying each suite's `_data` on entry and deleting it and its `priv_dir` on exit (a Common Test hook in the
  reporter, on both sides) would bound it by the largest suite instead.
* [Medium] `tools/lib/erx/release_files.rb` (`OTP_APPLICATIONS`), `tools/lib/erx/native_runtime.rb`: the system
  release, hosted and native, ships `kernel` and `stdlib` only. `compiler` and `runtime_tools`, which design-runtime.md
  keeps, are built only by the hosted runtime and carried only by the oracle's hosted tree, so the target has the
  headers but no compiler to read them, and no `dbg`. Decide how they join the release file: started, which starts
  `runtime_tools`' `ttb_autostart` at boot, or load-only, which puts them on the boot script's code path alone; and
  confirm the image's size and boot budgets take them.
* [Medium] `tools/lib/erx/oracle_suites.rb`: suites are compiled on the host with a relative source path, and
  shell_docs_SUITE's `init_per_suite` recompiles itself with `c:c`, which finds no source on the guest, so the suite is
  auto-skipped on erXos. A harness bug: compile the suites with the guest path of their copied source.
* [Medium] `test/oracle/hosted_known_differences/stdlib.txt`: stdlib differences not yet traced to a cause, each a row
  citing this item: edlin_expand_SUITE `filename_completion`, `function_parameter_completion`;
  erl_pp_SUITE `import_export`; escript_SUITE `archive_script`, `archive_script_file_access` (compilation
  error); filename_SUITE `absname`, `absname_bin` (`enoent`),
  `t_basedir_xdg` (`HOME` is unset on the erXos side); qlc_SUITE `evaluator`; shell_SUITE `otp_5435`, `records`;
  stdlib_SUITE `app_test`; epp_SUITE `deterministic_include`, `nondeterministic_include`; rand_SUITE `doctests`;
  gen_server_SUITE `handle_event_timeout` (failed in both runs, at load average about 86). ets_SUITE `smp_insert` and
  gen_server_SUITE `handle_event_timeout_plain` passed in the full run and failed in the rerun, so they are not in the
  table; rerun them on an idle host.
* [Medium] `otp/erts/preloaded/src/prim_file.erl` (`read/2`) and the file server's read: `file:read(Fd, N)` with an
  absurd N (file_sorter_SUITE `misc` reads a 2^128-1 length field) answers data or `eof` where stock answers `einval` or
  `enomem`, so the case gets `premature_eof` instead of `bad_object`. Read the size path; refuse sizes past the limit
  with `einval`, with a regression test.
* [Low] upstream, `otp/lib/stdlib/test/y2k_SUITE.erl`: `tz_next_date/1` returns its argument when local time equals UTC,
  so seven cases fail wherever the time zone is UTC, as erXos's is; stock passes only off UTC.
* [Medium] `tools/erx oracle hosted`: OTP's emulator group is wired but not yet compared: its table,
  `test/oracle/hosted_known_differences/emulator.txt`, holds no rows. Its run and classification is its own package.
* [Low] `otp/erts/preloaded/src/erl_init.erl`: `if_loaded(prim_socket, ...)` is dead and stays until a preloaded rebuild.
* [Medium] `otp/erts/emulator/beam/erl_process.c`: schedulers are not pinned to the group's run, the default stays stock's
  `+sbwt`, and `+S` is not derived from `erx_group_info`'s capacity, which no one configures yet
  (`docs/design-runtime.md`, "Scheduling"). Each waits for a consumer of a capacity word in Phase 2's groups.
* [Low] stopgap, `liberx/backend/fiasco/irq.c`: an IRQ object is never destroyed: a restarted driver keeps the one its device's record holds.
* [Low] `erlang/apps/erx_uart/src/erx_pl011.erl`, `wait_idle`: a boot that leaves the UART or its transmitter disabled with bytes in the transmit FIFO keeps `FR.BUSY` set, and the driver exits `pl011_busy` where clearing `FEN` would flush the FIFO (DDI 0183G 3-16); the wait is bounded by a count of reads, not a time.
* [Low] `erlang/apps/erx_uart/src/erx_pl011.erl`: a UART the boot left with a baud divisor of 0, as Fiasco leaves it on QEMU virt, gets divisors for virt's 24 MHz clock. The UART's clock belongs in the platform record, from its device tree node's `clocks`, and reaches the driver with the window and line.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`: `erx_device:open/1` takes a physical window and line selectors, since no device service hands a driver a record of slots yet; the
  record's `window` and `lines` become what that service builds, and drivers, which do not look inside the spec, stay as they are.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device.c`: a failed `erx_device_open` keeps the window's mapping and any line objects it made, a retry takes another mapping from the shared device
  window and finds the line `ERX_EBUSY`. A boot's devices are few and a failure is a misconfiguration; the record's cleanup comes with the device service.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`, queues: the NIF does not yet refuse `post/4` after the exit of a
  driver process that used the device until `negotiate/2` (`docs/design-runtime.md`, "The reset rule", R8); it needs the
  device's record to monitor the processes that post, as a line's binding does. A restarted driver's sequence
  (`queue_create/4`, `negotiate/2`) does not depend on it.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`, queues: every device is taken as `dma-coherent`, with no cache
  maintenance, and the barriers before the available index and the doorbell are C11 fences (inner shareable on AArch64),
  enough for QEMU `virt`'s virtio-mmio. A non-coherent device, the Raspberry Pi's, needs the record's coherence flag
  (from the device service) and the envelope's clean and invalidate, and an outer-shareable barrier behind the
  architecture layer.
* [Medium] `docs/design-display.md`: the display's `flush` copies into a framebuffer with `erx_device:fill/3`, which
  the device NIF does not have: requests go through `post/4`, which owns its buffers. A framebuffer or a virtio-gpu
  resource's backing is a long-lived region the device reads again and again, not a request's buffer; the device NIF
  needs a region call of its own (made once, filled by rectangle, never posted) before the display driver.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device_nif.c`: a move of a bound edge line can lose the one delivery taken under the old label just before the old sink was unregistered, while a level
  line fires again at the bind's acknowledgement. A driver of an edge line looks at its device after binding. The PL011's line is level.
* [Low] `tools/lib/erx/chokepoint_rules/device.rb`: "no loop over device-written bytes in the NIF" and "within `erx_device.c` only `write_address` writes a ring's address register" have no check: the first holds as `erx_device_complete` copies with `memcpy` alone, the second by reading the file; a check needs a function-level site.
* [Medium] `erlang/apps/erx/src/erx_device.erl`, queues: no Erlang-level test runs the NIF glue on a virtio stand-in: `negotiate/2` with a `Wanted` below 0 or from 2^64 is `badarg`, its `{ok, Accepted}` shape, `post/4` with an iolist `out` is `badarg`, and `write/3` and `write_field/4` of an owned register by atom are `badarg`. The C paths are covered by `test/fixtures/erx_device_dma_harness.c`; the pattern is `test/integration/runtime_device_test.rb`'s for the PL011.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`, `negotiate/2`: `device_features` and `queue_num_max` stay readable through `read/2` though their selectors are the NIF's, so such a read returns whichever word or queue the NIF selected last; and a driver learns the offered features and a queue's maximum only through a negotiation, so a multi-queue device (virtio-blk with `MQ`) needs two. Refuse reads of selector-banked registers and have `negotiate/2` return the offered set, or design a read-only probe.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device.c`, `negotiate/2`: the reset is read back once, so a device that finishes its reset asynchronously gets `{error, ebusy}`; a short bounded poll would serve it.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device.c`, queues: the install zeroes the rings but not the pool, so a device that reports a used length beyond what it wrote returns an earlier request's bytes of the same driver; and the whole-plan install is tested with one queue only.
* [Low] stopgap, `liberx/backend/fiasco/thread.c`: a join can return before the index and executor slot are
  free, since the clear comes before the recycle and the marker later still, so a `pthread_create` right after
  a join on a nearly full table gets a transient `ERX_ENOMEM`. musl's port would report `EAGAIN`.
* [Low] stopgap, `liberx/backend/fiasco/service.c`, `service_thread_reap`: only the reaper should send this
  request, and nothing checks the caller; `watchdog_thread.c` and `service.c` also share the convention of fixed
  helper slots in the kernel-given UTCB page, which one small enum could own.
* [Low] abi, `abi/erx_abi.txt`: `group_executors` and `group_executors_max` hold the same value. Keep one, and
  update whichever of `design-kernel.md` and `design-scheduler.md` then disagrees.
* [Medium] stopgap, `liberx/backend/fiasco/thread.c`, `erx_fiasco_semaphore_down`: the
  wait, which the umtx and park effects share, retries every IPC error, including permanent
  ones such as a deleted semaphore, so such a thread spins in the kernel forever rather
  than reporting it.
* [Low] stopgap, `liberx/backend/fiasco/root.ld`: nothing checks whether an orphan section
  lands past `erx_fiasco_image_end`, which `sigma0`'s map of the root's image would then
  miss.
* [Medium] tooling, `tools/lib/erx/oracle_guest.rb`: nothing automatic runs
  `test/host/json_input_test.rb` inside the oracle's pinned image, which hid a two-day
  break under its older `json`. The oracle's `probe` operation should exercise a
  duplicate-key refusal there.
* [Medium] tooling, `tools/lib/erx/oracle_hosted.rb`: its hosted release (tree, placeholder
  root, pack rows, `PackWire`, runtime environment) is a second copy of
  `test/integration/runtime_prim_file_test.rb`'s. Extract one hosted-release builder that both use.
* [Low] stopgap, `liberx/backend/fiasco/root.c`: a refused `erx.` word ends the boot with a fixed
  reason that names no word, though `erx_boot_args_parse` gives it in `refused`. Printing it needs
  the console's escaping function, as it is text from the boot loader.
* [Low] tooling, `make check-reproducible`: both builds of OTP and musl run at one path, so a path
  of theirs that reached the image would not show.
* [Low] stopgap, `tools/lib/erx/native_root.rb`: musl's headers are system headers to the root's compile, so a compile record leaves them out and nothing audits them for the root's objects.
* [Low] stopgap, `fiasco/l4re-core/libgcc`: the root links `libgcc.a` for `long double`'s helpers, under GPL-3.0-only WITH GCC-exception-3.1. Replace it with compiler-rt's builtins.
* [Medium] stopgap, `liberx/backend/fiasco/root.c`: the root writes no `erx_boot_info` page for a test task, though [Boot handoff](docs/design-stopgap.md#boot-handoff) says it does, and it seeds no `rng.c`.
* [Medium] tooling, `tools/lib/erx/oracle_qemu.rb`: the suites' events reach the host on the
  console's serial line, which the kernel, the root and ERTS's C output (`erx_output_write`)
  also write, at any byte. Console writers never split an event line, as `erx_console` writes
  each `display_string` whole, but a C writer can; the frame's length and CRC-32 then reject
  it, its sequence number's gap shows it lost, and the run reports itself incomplete rather
  than read it. Move the events to the host
  link (`/pl011@9040000`, M4), which only the host link's own sink writes.
* [Medium] tooling, `tools/lib/erx/pack.rb`, `pack_wire.rb`: `ERX_PACK_TEST_CODE` is set only
  by `ProductionImage#build_test_image`; other packers that carry test code (`BootImage#build`
  for libc-test and the native task suites, `OracleHosted#pack`) leave it clear, since
  `test_code:` defaults to false. The by-construction fix is to derive the header bit from
  per-entry test flags in the packer (ORed into the header, checked against the entries by
  `erx_index_check`); every packer then marks its test image, and the lexical
  `test-image-builder` check (`Checks::TEST_IMAGE_BUILDERS`) can go.
* [Low] stopgap, `tools/lib/erx/qemu.rb`: the harness gives QEMU one `-serial`, and QEMU `virt`
  places `/pl011@9040000`, the manifest's `hostlink`, only with a second one. Add the port with
  the host link's first consumer, M4.
* [Medium] stopgap, `tools/lib/erx/production_image.rb`: the root's link attributes `libl4sys.p.a`,
  `libsigma0.a` and the boot cores whole, under a license the recipe states, and its dependency
  files leave out Fiasco's and the compiler's headers. The boot cores are stated as BSD-2-Clause
  though the root takes BLAKE3's objects from them (BLAKE3's text is present only through the
  audit and its header). `CoreArchive::Built.objects` maps cores to objects, so per-member records
  are within reach for them; this comes before any distribution.
* [Medium] stopgap, `tools/lib/erx/pack_provenance.rb`: an `assembled` receipt binds its artifact to
  its components only by being written. The image packs `users/bin/.../sigma0` while Fiasco's audit
  reads the unstripped `OBJ-.../sigma0`, so a stale installed `sigma0` would pass. The audit should
  record the installed file and how it derives from the audited one.
* [Medium] tooling, `tools/lib/erx/production_image.rb`: the device-path check dumps unversioned `virt`
  on `cortex-a72` with two serial ports, not the `virt-11.1` machine the harness boots. Build the dump
  from `QemuPlan`'s machine and CPU.
* [Medium] stopgap, `liberx/backend/fiasco/root.c`: `root_memory_fits` is a pure decision with no
  boundary test: the 512 and 256 MiB boots do not pin its formula. It belongs in a host-built core.
* [Low] tooling, `tools/lib/erx/pack_provenance.rb`: `attribute` takes a file with no inventory row at
  the audit's word and as `permanent`, whatever the audit's status, and `resolve_fiasco` picks out
  erXos's additions by their evidence text. The audit should emit each one's status and notices.
* [Low] stopgap, `liberx/backend/fiasco/vm.c`: the pool takes all of `sigma0`'s memory and only
  checks it against `root_memory`; nothing keeps the excess for a later budget. Budgets over the
  pool arrive with the domains they guard (M5).
* [Low] musl, `liberx/backend/fiasco/arch/aarch64/task_start.S`: a task's 256 KiB first stack lies in `.bss` with no
  guard page, so a deep test overruns its own globals, possibly `t_status`, instead of faulting.
* [Medium] tooling, `tools/lib/erx/qemu.rb`, `Transcript#consume_lines`: a serial line past 64 KiB ends the boot, and a task's `write` can
  send one with no newline, so that test reads unknown and the rest of its batch not run. Skip an overlong line instead of raising.
* [Low] console, `kernel/core/crash_frame.c`: a crash frame after a task's output with no final newline starts mid-line, so
  `tools/lib/erx/crash_frame.rb` reads it as absent; the root's `end NAME fault` line still reports the fault. Write a newline ahead of the
  frame on the console path.
* [Low] log, `kernel/core/log.c`: a task that logs past the rate with `erx_debug_log` and then exits loses the dropped count, which only
  the next admitted record shows, so its log can read as whole when it is partial.
* [Low] musl, `tools/lib/erx/libc_test.rb`: `NEEDS` also holds back tests using `sigprocmask` and `pthread_sigmask`,
  which the seam answers with no effect; and `Dependencies`'s git fetch reads the user's git configuration, which
  the pinned hash catches only as a failed fetch.
* [Low] musl, `musl/src/internal/erxos/syscall.c`: the seam includes the Fiasco backend's private headers. Move
  it behind a neutral `liberx` header when the erx backend needs musl.
* [Medium] musl, `musl/src/internal/erxos/syscall.c`: the seam includes the Fiasco backend's headers and assumes
  the root (`erx_machine_end` for `exit_group`, a handle that is an index). A task needs the launcher's status path
  and handles with generations; the next part of the port settles it with `libc-test` in a task.
* [Medium] stopgap, `liberx/backend/fiasco/irq.c`: a task's IRQ call is `ERX_ENOTSUP`, since no task has a consumer.
  ERTS in a task needs the dispatcher named by `erx_fiasco_task_thread_cap(task, thread)`, an owner on each object,
  and the task's objects released at its end.
* [Medium] watchdog, `liberx/backend/api.h`: `erx_watchdog_pet` takes no `POWER` resource as `design-kernel.md`'s does.
* [Medium] release comparison, `test/integration/runtime_release_test.rb`: the comparison of the hosted and production archives skips unless both were built from the same sources, and no gate builds both.
* [Low] production image, `tools/lib/erx/production_image.rb`: OTP's and musl's archives are attributed whole, though `libz`, `libzstd`, `libepcre` and `libryu` carry their own licenses.
* [Low] musl, `musl/src/thread/erxos/clone.c`: the start takes three liberx calls in a required order, and the
  registers travel in the UTCB. One call taking the start state and the word to clear ends the order and the leak
  a failed clear-word call would leave, with the thread package's `erx_fiasco_reaper_start` as its second user.
* [Low] musl, `musl/Makefile`: `ARCH_CPU` layering reaches `lib/libc.a` only; `crt1.o`, the dynamic linker and
  `install-headers` still name `arch/$(ARCH)` and `crt/$(ARCH)`.
* [Low] musl, `musl/arch/erxos`: `docs/design-runtime.md` deletes `__syscallN` and the `SYS_` numbers; the seam
  keeps them as the tokens of one switch, so all of musl still compiles and refuses at run time. Delete them when
  the personality has replaced what they name.
* [Low] musl, `tools/lib/erx/native_musl.rb`: binary128 arithmetic comes from Fiasco's `libgcc.a`, built by GCC.
  Replace it with compiler-rt's builtins, the dependency table's row, with the rest of the BeamAsm image's runtime.
* [Low] musl, `musl/src/malloc/mallocng/glue.h`: `AT_RANDOM` is absent, so mallocng's secret comes from an address alone; `erx_entropy_read`
  can supply its 16 bytes at program start.
* [Medium] musl, `musl/src/thread/erxos/pthread_create_executor.c`, `musl/src/internal/erxos/syscall.c`: only the boot covers them. `test/guest/native_musl` needs the hosted
  driver's cases (no attribute, no free slot, the slot given back at exit).
* [Low] `otp/erts/emulator/sys/erxos/sys.c`, `beam/erl_process.c`, `beam/erl_driver.h`: what signals' deletion leaves unused: the break flag and `erts_do_break_handling`, `thr_create_sigmask`,
  the Darwin steal declarations, and the `ERTS_SYS_SUSPEND_SIGNAL` and `ERTS_HAVE_TRY_CATCH` blocks.
* [Low] `otp/erts/emulator/sys/erxos/sys.c`: on hosted a write to a closed pipe now ends the process with `SIGPIPE`, and a crash dump has no time limit; a dump says it could not read a process's stack, where it did not try.
* [Low] tooling, `tools/lib/erx/qemu.rb`'s `machine_end` cannot tell a power-off
  from a reset under `-no-reboot`, and ignores lines after the last checkpoint.
  Settle both with the `erx_machine_end` case.
* [Low] stopgap, `ERX_ROOT_KIP_WINDOW` and `root.ld`'s load address in
  `liberx/backend/fiasco` fit QEMU `virt` only; they move to the platform layer
  with the Raspberry Pi 4.
* [Medium] kernel, `kernel/core/debug_log.c` keeps the ring and its console
  buffers in file statics, and `tools/fuzz/dispatch_fuzz.c` a static UTCB and
  rate, so a fuzz crash can depend on earlier inputs. Make the log an object
  `erx_sys_caller_t` points to.
* [Low] stopgap, `liberx/backend/fiasco/service_task.c`: no test shows that a failed create of the console UART leaves the debug log on the line, and the native console suite counts no `l4_vcon_write` of a log record after the handoff; only the host core test counts console writes. A boot whose first create of the console window fails, and a counter the root prints at its end, would close the "Console handoff" row of `docs/design-stopgap.md`.
* [Medium] stopgap, `kernel/core/debug_log.c` `erx_debug_log_read`: the reader's cursor only decides whether a read is refused; every read starts at the one position of what has been taken, so a second caller of `erx_log:read/1` in the root takes records from the console for good, and `erx_console` starts at cursor 0, which on erXos's kernel (`docs/design-kernel.md`, "Console, log and panic") would replay what the early console already printed. Give the reader its first cursor at the handoff and make the cursor its own, or drop the cursor from the call.
* [Medium] stopgap, `liberx/backend/fiasco/service.c` `service_log_read`: no test shows that a task's `log_read` is refused with `ERX_ENOTSUP`; that check alone keeps a task from having the service write log bytes at an address of the root. Add the case to `test/guest/native_task/program.c` beside `task_write`'s refusals.
* [Low] runtime, `erx_log_nif.c` `read_nif`: a record that fails the reader's checks ends the window, and the console's line says so without saying how many records after it were dropped.
* [Low] stopgap, `liberx/backend/fiasco/end.c`: the watchdog's end skips the debug log's parked records, as the service may be mid-write, so a missed pet after the console handoff loses the records the console had not read. At any end, lines the console has read but its driver has not yet written are lost uncounted, and the end's own drain can interleave with the driver's bytes on the UART.
* [Low] stopgap, `tools/lib/erx/glue_imports.rb` reads what the compiler left
  out of line: a change of inlining can move a symbol such as
  `_ZN13Irq_chip_soft7sw_chipE` on or off the list and fail the build.
* [Medium] stopgap, the debug-log probe's report: `tools/erx check-debug-log`
  compares its own transcript, because the conformance guest's protocol
  needs lines that start with `erx-test:`, and a program's only output here
  is a log record with the kernel's prefix. `debug_log.statuses` stays `pending` in the
  roster until the conformance guest can report.
* [Medium] display, LVGL renderer: replace LVGL on panels with the Erlang
  renderer once the parity test passes and the Erlang renderer's frame
  times match LVGL's on a 240x240 panel
  ([design-display.md](docs/design-display.md#dependencies)).

## Bugs by subsystem

* [Low] tooling, `tools/lib/erx/oracle_comparison.rb:104`, `oracle_qemu.rb:203-213,232,239`: the
  oracle comparison's host side has gaps. (1) A repeated sequence number keeps the first copy
  (`frames.compact.uniq(&:first)`), so a stray or forged frame wins over the real one; the CRC is
  integrity, not authentication, and a frame appended after the last real event goes undetected
  by the sequence logic (state it next to the event-frames residual above). (2) `boot_guest`
  catches errors from `qemu.run` only; an unreadable `report.json` (`JsonInput.parse`) or a
  serial log over 256 MiB (`BoundedFile.read`) raises out of `OracleQemu#run` and aborts
  check-oracle mid-loop; map both to a host state, or to `failed` when the guest booted. (3)
  A `CommandError` from `qemu --version` timing out maps to `timed_out`, and a QEMU or HVF crash
  after the bootstrap memory line maps to `failed`, so host problems read as erXos's; the
  `cancelled` branch (line 208) is unreachable from `run_guest`, which passes no `cancelled:`.
* [Low] tooling, `tools/lib/erx/libc_test.rb:158,270-279,454-457`, `tools/lib/erx/setup.rb`: (1)
  Every serial line between a test's run and end lines that matches `FILE.c:N: ` is
  attributed to that test, including kernel or root C output; a spurious disagreement, never a
  false pass. Require the `src/` path form `t_error` prints. (2) The libc-test make rules
  depend on sources only, and `forget_programs` deletes only `.elf`, so objects built under old
  `FLAGS` are reused; hash the flags into the rule or delete the objects when they change.
  (3) `setup.rb:114-125`: with `ERX_SOURCE_CACHE` set, setup raises if the cache lacks an
  archive this tree already has; the catch-all rescue appends "run `make fetch`..." to every
  error, including a SHA-256 mismatch; `archive_name` duplicates `Dependencies#archive_path`
  (expose and reuse it); the source steps' `deadline: 300` is never used. (4)
  `setup.rb:141-143`: `toolchain_env` hard-codes `/opt/homebrew/...` where Homebrew lives in
  `~/homebrew` and Linux is a host, and passes nothing silently when neither path exists;
  report when no toolchain is found. (5) `leftovers` reads the flavour out of `step.argv`;
  store it on `Step`. `ERX_SOURCE_CACHE` names `build/third_party` but setup reads the sibling
  `build/downloads` (`archive_directory`); name the directory actually read.
* [Medium] `test/oracle/erx_oracle_events.erl`, `test/oracle/common_test/test_server_ctrl.erl` (`start_minor_log_file`),
  `config/manifest/qemu-virt-development.txt` (`tmp 167772160`): the oracle reporter's event file (`events.jsonl`) and the
  controller's logs share `/tmp` with the suites under test, so a suite that fills `/tmp` ends the reporting of the whole
  run: the run dies when the reporter's own write is the one refused. `/tmp` gives back the space of deleted files; the
  fill is real use: kernel's `file_SUITE` bench group writes a 256 MiB scratch file (`large_writes`, deleted only in
  `end_per_group`) and `sendfile_SUITE`'s `init_per_suite` writes one file in 51 writes of 10 MiB (510 MiB) without checking the results.
  Fix: put the reporter's output outside the suites' file system, or make the reporter survive `enospc` and report the
  loss. Until then the kernel group's erXos side runs one runtime per suite, and those two suites cannot finish within the cap.
* [Medium] `tools/lib/erx/oracle_qemu.rb` (`command_line`): the guest's runtime still gets `-pa /lib/<app>/ebin`
  for the stock applications, which its code server also lists from `/lib`, as the hosted runtime's did. Check
  `code:get_path()` on the guest and drop the `-pa` words (`OracleHosted.erxos_command` is the model), and its
  code_SUITE `set_path`, `add_path` and `add_paths` cases.
* [Medium] `tools/lib/erx/oracle_comparison.rb` (`skipped_group_function`): a group function that erXos never
  recorded shows as `auto_skip`, inferred from the skipped cases under its group, and the report prints it like
  a status Common Test recorded. Give the inferred status its own name in the report and the table.
* [Medium] `test/oracle/hosted_known_differences/kernel.txt`: the kernel group is classified but for 63 differing
  and 21 changed cases, each still to be judged by cause: prim_file_SUITE (23), error_logger_warn_SUITE (6),
  logger_disk_log_h_SUITE and logger_std_h_SUITE (`undef` among them), code_coverage_SUITE ("This runtime system
  does not support coverage" on the hosted interpreter), gen_udp_SUITE, prim_net_SUITE, os_SUITE,
  erl_prim_loader_SUITE, disk_log_SUITE `close_deadlock`, application_SUITE's `systools:make_script` cases, the
  `changed` rows whose suite also shows another status, and sendfile_SUITE's 7 cases the erXos run never reached. Reports: erxos-history `oracle-hosted/2026-11-06-kernel`.
* [Medium] `tools/lib/erx/production_image.rb`, QEMU suite: M3's demo has an idle machine show every executor
  parked, and only the hosted suite checks it (`test/integration/runtime_hosted_smoke_test.rb`, through
  `ERX_HOSTED_GROUP_REPORT`). On Fiasco the park table keeps the count in the group status page
  (`liberx/backend/core/park_table.c`), but nothing reads it out: no BIF, and no reporter like the hosted
  backend's `group_report_main`. Add a user-mode reporter to `liberx/backend/fiasco` behind a kernel command-line
  word, and a checkpoint of `parked N of N` at the shell.
* [Low] `tools/lib/erx/interpreter_image.rb`: the check reads the linked program's symbol table, so a link that
  discards locals (`-x`, hidden visibility turned local) could hide C++ while keeping `erl_start`. The root's link
  strips debug information only. Check the lld link map's input members as well, which no stripping changes.
* [Medium] `erlang/apps/erx_files/src/erx_fs_grant.erl`: a fid's path has no depth bound, and `repath/3` counts every
  step of it, so a clone, clunk or walk in place of a fid at depth D costs O(D) and building the path by walks in place
  O(D^2); renames of two directories grow a path without bound. Cap a fid's path length (a walk past it refuses), or
  count steps per shared path suffix so a clone is one increment ([todo-performance.md](docs/todo-performance.md)).
* [Medium] `erlang/apps/erx_files/src/erx_fs_grant.erl`: the grant's hold bookkeeping (`held`, `steps`, `loose`) has
  no test of its own: `erx_fs_test_tree` has no `forget`, so a rejected walk reply's holds (`tree_holds/2`), `remove`
  and `owner_down` with walked fids are seen only end to end, or not at all. Give the test tree `forget`, check in
  `fid_table_model_test_` that the tree holds exactly the walked nodes the fids name after every step, and consider
  making the forget an effect `{forget, Node}` the shell performs, so the core sends nothing.
* [Medium] `erlang/apps/erx_files/src/erx_fs_grant.erl`: an open file's owner process is one per grant, keyed by the node,
  where `docs/design-files.md` starts one per open file on any grant; a file open through two grants of one tree has
  two owners, so its requests are ordered against each other only by the tree. /tmp serves one grant per tree. Add
  a per-tree registry of owners before a tree is served on more than one grant.
* [Medium] `erlang/apps/erx_files/src/erx_fs_grant.erl`: no read helper exists, so an open file's owner calls `read` itself
  whatever the module's `read_mode/0` says, and a read that waits for a medium holds up the file's other requests.
  Build the helper of `docs/design-files.md` (state-stamped results the owner's core accepts or retries) with the
  first tree that answers `helper`.
* [Medium] `erlang/apps/erx_files/src/erx_fs_grant.erl`: a clunk of an opened fid is answered at once and its file process
  leaves `files` when its last clunk is queued, so a tree whose `clunk` is slow can gather file processes still
  draining clunks, beyond the pool and outside the in-flight bound, and two processes of one file can run at once.
  /tmp's clunk is one in-memory step. Defer the clunk's answer to the file process (counted in flight), or keep the
  file in a closing state that new opens join, before a tree with a slow `clunk` is served.
* [Low] `erlang/apps/erx_files/src/erx_fs_grant.erl`: `add_fid` and `end_fid` push effects into the grant's state, which
  every exported step must drain, and an owner's monitor is `pending` until the shell hands its reference back with
  `monitored/3`, as an open file's owner is until `file_started/4`. Thread the effects through the step's return instead, so a step that both makes and ends one
  owner's fid can never emit `{demonitor, pending}`.

* [Medium] `abi/manifest.txt`: the `devices[].selector` choice does not make `base`, `size` and `line` inactive for
  selector 2, so a PCIe row with any of them nonzero is admitted, where `docs/design-abi.md` says they are zero; and
  nothing refuses a device-tree row whose `base + size` wraps. Add the three fields to the choice's `dt` case, decide
  the overflow rule, and give each refusal a fixture case in `test/host/abi_binary_test.rb` and
  `test/host/manifest_reader_test.rb`.
* [Medium] `test/guest/native_irq/guest.c`: the line's unbind and rebind come before the first typed character, so
  nothing checks that a line still fires after it was delivered, acked, detached and attached again. Type a third
  character after the rebind and add its checkpoint to `tools/lib/erx/native_irq.rb`.
* [Medium] `erlang/apps/erx_uart/src/erx_pl011.erl`: QEMU 11.1's PL011 writes each byte straight to its backend, so `FR.TXFF`
  never sets, and it forces the receive interrupt level to one byte, so the receive timeout never has a byte below the
  level to report; a character also arrives whole, never in flight. The `production_image` suite therefore still passes
  with the TXFF check before each `DR` write removed, with `RTIM` left masked, or with the character wait after
  disabling the UART removed. Run the real `erx_pl011` against a host register model behind `erx_device` that holds
  `TXFF` set for a while, delivers input below the level only through the receive timeout, counts `DR` reads and
  refuses a control register write while a received character is in flight, and require each of those mutations to fail.
* [Low] `test/guest/function_api/cases.c`: the hosted function-API binary exits 0 when a case prints `FAILED`, so only
  `hosted_function_api_test.rb`'s comparison against the expected lines catches a failure. Exit nonzero when any case fails.
* [Medium] `liberx/backend/fiasco/runtime_main.c`: `liberxroot.a` holds a `main`, and OTP links a tool with the archive ahead of its
  objects, so any member a libc reference reaches that comes to `runtime_entry.c` collides with the tool's `main`. The host test guards only
  `libc_root_write.c`. Moving `main` out of the archive, into ERTS's own `erl_main.o`, which is linked explicitly, removes the rule.
* [Medium] `tools/lib/erx/runtime_seam.rb`: `check_elf_objects` reads only the emulator's objects and six named libraries, unlike the hosted
  check, which reads the executable, so a library added only to the native link can import an unlisted name. Derive the list from the root's link map.
* [Low] `tools/lib/erx/fiasco.rb`: `Fiasco#build` records the audit report again before pack audits it, so a build output edited after the build, which `make` leaves alone, is recorded as built rather than refused. (From reading the code; not run.)
* [Low] `test/fixtures/runtime_event_harness.c`: the sleep step's waker is a single-threaded model of `sched_set_park_flag` and the wake in `erl_process.c`, at fixed points, and the
  `scheduler_wait` exit test (`erx_event_leave_wait_ready`) pins the call by source text, so the real crossing of a scheduler and its waker is not run.
* [Low] `tools/fuzz/boot_build_target.rb`: the boot fuzz targets do not require that any input is accepted, so a target that
  refuses everything passes, and the script copies the limits layout by hand rather than from `abi/erx_abi.txt`.
* [Low] `otp/erts/lib_src/Makefile.in`: `depend.mk` has no prerequisites and is made once per build copy, so a header that a lib_src source
  includes after that is no dependency of its object, and an edit to that header alone leaves the object stale. Use `-MMD -MP`.
* [Low] `otp/erts/emulator/Makefile.in`: the preloaded beams (`erts/preloaded/ebin`) have no rule, so an edit under `erts/preloaded/src`
  reaches the emulator only when the checked-in beams are regenerated by hand.
* [Low] `otp/erts/emulator/Makefile.in`: `erlang:system_info(compile_info)` answers `N/A` on erXos (edit 49 of
  `docs/design-runtime.md`), which no test pins until the oracle comparison runs.

* [Medium] `libc-test` on native Fiasco, `tools/lib/erx/libc_test.rb`:
  `regression/malloc-brk-fail` passes at 4 CPUs and runs past 60 s at 1 CPU
  under TCG, cause not found, so it is out of the canary set, and
  `check-libc-test tcg 1` would fail on it. Every test has a verdict at 4 CPUs
  under TCG (`test/conformance/libc-test-verdicts.txt`; `~/erxos-history`
  `f6d3e4a`, `libc-test/2026-11-05-tcg-4cpu`); runs at 1 CPU and under HVF
  have not been held to the table.
* [Low] musl, `musl/src/regex/regexec.c`, `src/math/powf.c`, `src/math/jn.c`:
  upstream bugs that `libc-test` pins as `upstream` verdicts. A back
  reference after a multibyte character compares the wrong bytes
  (`regexec.c:785`, `regression/regex-backref-oob`), `\(.\{1,3\}\)\1` finds
  no match in "foo" (`regression/regexec-backref`), `powf(x, 1)` raises
  INEXACT with OVERFLOW or UNDERFLOW (`math/powf`), and `yn` is 3.2 ulp off
  (`math/yn`). None is fixed on musl's master. Fix them in erXos's musl, or
  take upstream's fixes when they land, and drop their verdict lines.
* [Low] ERTS memory, `otp/erts/emulator/sys/common/erl_mmap.h`: stock turns off physical reservation, and with it the literal mapper, under `ADDRESS_SANITIZER`, and erXos's `erl_mmap` keeps it on. No ASan flavour of ERTS has run; settle whether literals stay in the mapper's range when one first does.
* [Low] ERTS memory, `erl_mmap.h`, `beam/erl_alloc_util.c`: `erts_madvise_discard_advice` lost its definition, and its declaration and uses stay behind `HAVE_MADVISE`, which both cross-compile files pin off. Delete them.

* [Medium] runtime, `make check-runtime-seam`: the name checks read `sys/erxos/imports.txt`, still wide, on the hosted objects by `make check-runtime-seam` and `make check-runtime-hosted`, and on the native objects in `Erx::NativeRuntime#build`, not before each link. The `__erx_syscall` number check, the comparison of the
  two `config.h` files, the source check for `__APPLE__` and the like, and the own lists of `erx_output.c` and
  `erx_stdio_nif.c` wait for `sys/erxos` to shrink
  ([design-runtime.md](docs/design-runtime.md#what-erts-imports)).
* [Medium] runtime, `tools/lib/erx/runtime.rb`: the build record covers neither the pack's own inputs (`tools/lib/erx/release.rb`, `pack*.rb`, `manifest.rb`, `config/platforms`, `config/provenance`) nor the archive's bytes, and is written before the pack runs, so a test run alone can read an older `system.pack`. Wants a release record written after the pack.
* [Medium] tools, `tools/lib/erx/pack_provenance.rb`: a `compiled` receipt declares its sources and names no `.hrl`; nothing ties a beam to them, and a `release` pack accepts it. Derive them with `erlc -M`, and hold them under a registered import.
* [Medium] tools, `tools/lib/erx/release.rb`: `boot_file` puts paths into an Erlang expression, so a checkout path holding `"` or `\` breaks or changes it. Pass them with `-extra`.
* [Low] tools, `tools/lib/erx/boot_image.rb`: `BootImage#build` removes its directory before `OutputDirectory.prepare` checks the path, so a `build/` that links out of the tree has the linked directory removed. Clear it through a check first, as `ProductionImage.clear_directory` does, with a test like `production_image_test.rb`'s link test.
* [Medium] runtime, `liberx/backend/core/boot_manifest.c`: `peer_held` and `peer_held_total` stay zero on the page, and the projection is hand-written where the design generates it. No reader yet.
* [Medium] runtime, `tools/fuzz/boot_manifest_fuzz.c`: the target compares the page with the reader's own result, so a swapped limit or a wrong host byte in `erx_boot_manifest_read` passes. Compare with `erx_manifest_open` and `erx_manifest_runtime_limits_at` called directly, field by field.
* [Low] runtime, `liberx/backend/fiasco/runtime_entry.c`: an `erx.arg` word of the kernel command line reaches ERTS's flag diagnostics unchecked, where the reader in `boot_manifest.c` holds `system_args` to printable ASCII. The command line is the operator's own.
* [Medium] runtime, `erlang/apps/erx/src/erx_device_record.erl`: `erx.arg` words of the kernel command line can spell `-erx device ...` and add a device record the manifest never assigned, which a driver opens like the root's own; on the stopgap the command line is the operator's, but the manifest should stay the one source of which domain holds a device. Carry the records in a boot-information field only the root writes, or have the system domain's Erlang select them from the manifest through `erx_manifest`.
* [Medium] runtime, `otp/erts/emulator/nifs/erxos/erx_device_nif.c`: `erx_device:open/1` ignores the spec's `dma_memory`, so the size the boot reserved for a device is not part of its record or of the same-window comparison; decode and bound it there, keep it in the record, and let `pool_create` carve from it, and describe the key in design-runtime.md's "The device NIF".
* [Medium] runtime, `erx_prim_file.c`: that a release file's bytes reach a read only after `erx_release_check` rests on `erx_copy_out` being ERTS's one user of `erx_release_addr`, with no build check. One call, `erx_release_open`, returning the bytes after the verdict with the cache inside `liberx`, removes the import and ERTS's flag, and Phase 2 then changes only what is behind it.
* [Low] runtime, `erx_prim_file.c`: a refused file is hashed and reported again at each open; `docs/design-kernel.md` has later uses fail at once.
* [Low] runtime, `liberx/backend/core/boot_manifest.c`: the printable rule for `system_args` lives in the reader, so `Manifest.admit` packs a manifest that then fails at boot, and `domains[].args`, the same string class, is not covered. The rule belongs in the `args` class of the ABI generator.
* [Low] runtime, `tools/fuzz/release_fuzz.c`: does not call `erx_release_check` or compare `erx_release_fs_lookup`'s index with the entry's, and has no seed at the longest path; its `fix_index` is a copy of `pack_fuzz.c`'s.
* [Medium] runtime, `erlang/apps/erx/src/erx_console.erl`: `Ctrl-G` rings the bell, where `docs/design-live.md` gives it a menu of sessions; the menu comes with the sessions. `erx:console_size/2` waits with it.
* [Low] runtime, `otp/lib/kernel/src/prim_tty.erl`: `init_term/1`, the reader and the writer stay as stubs for `user_drv`'s stock paths, which `load/0` keeps unreachable; they go when `user_drv` itself leaves the release.
* [Low] runtime, `otp/lib/stdlib/src/io_ansi.erl`: with no terminfo a shell's `io_ansi` is plain text where stock on an xterm has colour. A fixed table of the ANSI sequences would answer it.
* [Low] runtime, `shell:start_interactive/0` calls `user_drv`, which does not run: it exits with `noproc` where stock answers `{error, already_started}`.
* [Medium] runtime, `otp/erts/emulator/sys/erxos/sys.c`: `kill -INT` runs the break menu while `erx_stdio`'s reader still reads standard input, so a key can go to either; on this port SIGINT should leave through the exit path. No test.
* [Medium] runtime, `erx_console.erl`: `get_terminal_state` reports standard input's answer for all three streams and `tty_geometry` answers 80 by 24 with no terminal, where stock asks each descriptor and refuses. A start failure of the driver loses its step and reason in `user_sup`'s ten-second wait, and `erx_stdio_nif.c` reports every IRQ failure as `eagain`.
* [Low] runtime, `tools/lib/erx/runtime_seam.rb`: the executable check drops an own list's names, so a library missing from the object list that calls them passes.
* [Low] runtime, `erx_stdio_nif.c`: a fatal signal or SIGKILL leaves the terminal raw; `start_nif`'s failure paths leave what they made; a stalled standard output delays input, which one process handles; and `SIGWINCH`'s `sigaction` skips `sys_signal`'s `SA_ONSTACK`.
* [Low] runtime, `standard_error.erl`: a failed write crashes the server with no log, which a later `set_unicode_state` carries into `erx_console`.
* [Medium] runtime, `liberx/backend/fiasco`: the native root does not read the release's manifest: its page takes
  `erx.arg=WORD` alone, with `system_args`, `limits`, `pack_flags` and `release_addr` empty, and no archive holds
  a native root with these release files. `liberx/backend/core/boot_manifest.c` is the reader to link, and
  `Erx::Release.differences` the comparison `test/integration/runtime_release_test.rb` runs over two hosted packs
  until then.
* [Low] runtime, `prim_file`: EROFS has no provider yet, so a path on it cannot arise; its entry's
  `{erofs, Image}` provider ([design-files.md](docs/design-files.md#namespaces)) arrives with it.
* [Medium] runtime, `otp/erts/preloaded/src/erx_file_remote.erl`: `file:ipread_s32bu_p32bu/3` on an open
  file of a grant has no implementation, so it raises `undef`.
* [Medium] runtime, `otp/lib/kernel/src/file.erl`: `file`'s name calls (`copy`, `delete`,
  `rename`, `read_file_info` and the rest of `check_and_call/2`) still send the path to
  `file_server_2`, which then talks to a 9P server itself, where design-files.md (the
  file server paragraph) says `file` resolves the path first and sends only local paths
  there. A slow or stuck server stalls every name call in the runtime, and a server that
  called `file:` name functions while serving would deadlock. Resolving in the caller
  removes both.
* [Medium] runtime, `file:copy_opened_int/4`: a short read is taken as end of file, and
  `erx_file_remote:read/2` may answer fewer bytes than asked, so a copy from a remote
  file into a local one could stop early and still answer `{ok, N}`. Unreachable today
  (the `/tmp` server answers whole units and the release tree is read-only). Either the
  loop reads until `eof` or `erx_file_remote` fills each read.
* [Medium] runtime, `erx_file_remote`: the read buffer's differences from stock have no pins in
  `prim_file_compare`'s `tmp_ahead`: a `pwrite` through the read-ahead file itself (stock then skips the
  bytes read ahead, an upstream bug to record), an error after buffered bytes (erXos answers the bytes,
  stock the error), and a `{read_ahead, X}` that is not a count (erXos reads none ahead, stock's read
  raises). Unpinned paths too: read-only, write-only and append files with `read_ahead`, a `pread` then
  a `read`, a line longer than 256 bytes and the read-ahead. A server that answers every request in full
  makes one read hold up to 0x7ffff000 bytes in the caller's heap.
* [Low] runtime, `erx_file_remote`: the read buffer agrees with the offset only because every call that
  moves the offset other than the reads goes through `emptied/2`; keeping the buffer's start offset in
  the cells would make it hold by construction. A read whose new offset passes 2^63 - 1 answers eio
  after the buffer has changed, leaving it out of step. `read_file` flattens a large file twice
  (`read_in_units` and `contents`), about three times its size at peak.
* [Medium] runtime, `erx_file_remote`: `read_file` keeps up to the size a server's `getattr` answers and
  `read_line` reads until a server sends a `"\n"`, so a hostile server can make the caller, perhaps the code
  server, hold as much as it sends until the node dies; stock fails such a size up front with `enomem`. A
  bound per call would make the caller's heap the client's to limit.
* [Medium] runtime, `erx_file_remote`: `exchange/2`'s refusal of a writing request through rights other
  than `rw` has no seeded test of its own, since every operation refuses first (`created/4`, `if_writable/3`,
  the descriptor's access), and no build check keeps `sent/2` the module's only send; a seed that drops
  `created/4`'s read-only clause, watched by the tree's observer, and a send-site count in
  `test/host/erx_file_remote_test.rb` would make it a chokepoint as CLAUDE.md asks.
* [Medium] test, `test/integration/runtime_prim_file_test.rb`: the open-file cases (`OPEN_FILES`) are
  hand-written expectations rather than the same calls run on stock over a local directory, which the
  oracle rule asks for. Known differences from stock: `position(Fd, {bof, 1 bsl 64})` answers `einval`
  where stock answers `badarg`; a `pread` at a negative offset through a write-only descriptor answers
  `ebadf` where Linux answers `einval`; `read_file` of a file whose `getattr` size is 0 answers `<<>>`
  where stock reads to the end.
* [Low] runtime, `erx_file_remote`: `list_dir` of a directory on a grant lists only the server's entries,
  not the mount points directly below it ([Resolving a path](docs/design-files.md#resolving-a-path),
  listings across mounts), which needs the namespace's table from the NIF.
* [Low] runtime, `erx_file_remote`: `#file_info.major_device` is a hash of the grant's pid and tree where the
  design has a number the namespace gives each mounted tree; two trees can collide.
* [Low] runtime, `otp/erts/preloaded/src/prim_file.erl`: `delete/1` answers every `einval` as `eperm`, a
  server's answer to `unlinkat` included, where FreeBSD's `kern_funlinkat` turns only `namei`'s `EINVAL`
  and lets `VOP_REMOVE`'s stand ([Errors](docs/design-files.md#erlang-clients-prim_file-and-erx_file_remote),
  step 2); the resolver's answer needs to reach `delete/1` apart from the server's for the translation to
  apply to it alone.
* [Low] runtime, `erx_file_remote`: `del_dir`, `delete` and `rename` of a mount point answer `ebusy` only
  when the point is the tree's root; a bind of a directory below the root is removed or renamed through the
  bind where Linux answers `ebusy`; the remote answer's place says so (`Names =:= Root`), so the check is one
  comparison in `remove`, `renamed` and `make` once `Try` receives the place.
* [Low] runtime, `erx_file_remote`: a relative symbolic link among a bind's root names (a bind made
  through a link) answers `enoent`, since the bind fixed its root as names and the link's directory lies
  above the entry's point; resolving `From`'s links when `erx_ns:bind` binds would remove the case.
* [Medium] runtime, `erx_file_remote`: on a read-only entry `erofs` is answered once the last name's directory is
  reached, before the last name is looked at, where Linux answers `eexist` or `enotdir` for the last name
  first (`make_dir` of an existing name on a read-only bind answers `erofs`, stock `eexist`).
* [Medium] runtime, `erx_file_remote`: the server's replies, the client's untrusted input, have hand-written
  hostile cases in `test/integration/prim_file_compare.erl` but no fuzz target; the fuzz target covers the
  caller's path text only.
* [Low] runtime, `test/integration/runtime_prim_file_test.rb`: no seeded fault shows the /tmp transcript
  catches a missing turn of the error steps (`enotempty` to `eexist`, `einval` and `eisdir` to `eperm`),
  which live in preloaded `prim_file`, which a seed cannot replace after boot; and none shows it catches an
  executor that never hands a stopped walk to its resumption. Seed `erx_file_remote:passed/2` to answer
  `true`, and the turns through a hosted build of their own, or name the transcript lines that cover them.
* [Low] runtime, `erx_file_remote`: `list_dir` opens without `O_DIRECTORY`; a partial walk answers `enoent` for any refusal;
  negative times answer `einval`; an empty symlink target is sent; a listing may hold up to 2^20 names of
  255 bytes; the xref check exempts every call through a variable.
* [Low] build, `otp/erts/preloaded/ebin`: the preloaded beams erXos changes (`prim_file`, `erx_9p_grammar`,
  `erx_file_remote`) are compiled by hand with the oracle's `erlc` and checked in, each recorded in
  `otp/ORIGIN.md`; building them from source in the runtime build, under `make check-reproducible`, would
  remove the hand step and the hashes to keep.
* [Low] runtime, `tools/fuzz/release_names_fuzz.c`: the oracle does not check that an accepted name is valid
  UTF-8, and walks only an empty release, so the walk's cursor past the first name is not fuzzed.
* [Low] runtime, `erx_prim_file.c`: `efile_set_cwd` is dead since stock `set_cwd_nif` went;
  `efile_ns_set_cwd_nif` keeps `ns` in its name; a symlink's text marshals to an empty name list, the
  release top, so a future NIF that used it as a path would act on `/`; docs/design-files.md still names
  `erx_get_cwd_nif/0` and a mutex where the code uses `get_cwd_nif` and an rwlock.
* [Low] runtime, `erx_path.erl`: a run's names are checked against `ERX_NAME_MAX` before its earlier names are
  walked, so `missing/<256-byte name>` answers `enametoolong` where FreeBSD answers `enoent`; and a link's text
  is bounded against the names left to read rather than the bytes, so doubled slashes are not counted. Check
  each name as it is reached and count the path's own bytes, or record both as differences.
* [Low] runtime, `erx_path.erl`: on a read-only provider's entry, a create of a missing last name with a trailing
  `/` (`open("new/")` with `O_CREAT`) answers `enoent` where FreeBSD answers `erofs` before the trailing-`/` check,
  because the resolver does not know which entries are read-only. Give the table's entries their read-only flag,
  as the empty root already answers `erofs`, or record it as a difference.
* [Low] runtime, `erx_path.erl`: a parent's resumption accepts a reply whose kinds are all directories and that
  ends in an error, answering the error where the design says `eio`. Accept only the directory's kinds plus one
  `link`.
* [Low] `test/erlang/erx_path_fuzz.erl`: no seeded fault shows the root-prefix property catches anything, seeds
  are matched by `mismatch` rather than by the case the design names, the differential never reaches
  `enametoolong`, and every entry lies over one tree.
* [Low] runtime, `erx_ns`: `which/1` and `list/0` of
  [design-files.md](docs/design-files.md#interfaces) are not written.
* [Low] /tmp, `erx_ramfs_sup` under `kernel_safe_sup`
  ([design-tmp.md](docs/design-tmp.md#starting-and-mounting)): a crash of the tree process that recurs
  on every restart, such as one a request reproduces, passes `kernel_safe_sup`'s restart intensity, which
  ends `kernel` and halts the node. A Phase 1 residual: `/tmp` is the domain's own, so the domain ends
  with it. The restart test of [/tmp's verification](docs/design-tmp.md#verification) covers one crash,
  not a recurring one; a recurring crash would want `erx_ramfs_sup` to give up on `/tmp` alone.
* [Low] /tmp, `erx_ramfs_serving`: the serving set's `xref` closure follows only calls it can
  name, so a module a serving process reaches through `apply/3` or a fun value it was handed is
  not in it. Two seeded faults of [/tmp's verification](docs/design-tmp.md#verification) are not caught by
  the hosted tests (the concurrency case also does not run `erx_ramfs_core:check/1` afterwards, which
  docs/design-tmp.md's Verification lists): the rename split into two steps (the client unlinks the destination, then renames)
  passes the concurrency case with 0 misses in 1,608 stats over 800 renames, so that case does not yet
  show it runs the interleaving it exists for (one scheduler may starve the statters; a case run with
  schedulers online or with the statters sending ahead of the renamers would settle it); and a grant that
  does not clunk a dead owner's fids passes the hosted killed-process case, probably because the runtime's own handle
  release clunks first, so only `test/host/erx_ramfs_test.rb` catches it. The cold case's seeded start that skips one module of the generated list is not run: no module the
  serving processes need is found unloaded at the cold steps in the one tried (`epp` is loaded by io formatting
  alone), so the choice of module wants a trace of the first calls of the unseeded cold steps, and the
  deadline path (a deadlocked code server) wants the later cold steps under a deadline too. The walk-in-place seed of that section
  breaks every open in the /tmp transcript, so it ends the run before the `victim` case; it is run only against the
  test grant (`test_seeded_walk_removes_the_victim`), and for /tmp it needs a fault confined to the path operations.
  "Held is back" is read through `bfree`, whole 4,096-byte blocks, so a leak of one node's charge goes unseen.
* [Low] runtime, `erx_prim_file.c`: `file:sendfile` on a release file answers `einval`, since `efile_get_handle`'s
  empty binary fails `prim_inet`'s length check, and so misses `file`'s fallback on `enotsup`; the check belongs
  in `prim_file:sendfile`. Two concurrent relative `set_cwd` calls can store an answer no serial order gives:
  the resolve and the store want one hold of the write lock. On a grant a `getattr` exchange lies between
  them, so there the store wants to check that the working directory is still the one the path was
  resolved against.
* [Low] runtime, `liberx/release.c`: `erx_release_entry`'s `ERX_ERANGE` also stands for a failed decode, which
  the kernel's backend must tell apart.
* [Low] runtime, `otp/erts/configure`: edited by hand, because the tree holds autoconf 2.72's output and the
  installed autoconf is 2.73, whose output differs throughout. Each edit is also in `configure.ac`.
* [Medium] runtime, the native boot page: the comparison of the two entries' pages waits for a native release that boots, and so does the range check on `limits`, of which `erx_boot_info_build` and `erx_boot_info_read` check only the reserved word ([design-stopgap.md](docs/design-stopgap.md#boot-information)).
* [Medium] runtime, `otp/lib/kernel/src/dist_util.erl`: `gen_challenge/0` calls `statistics(runtime)`, which fails with `notsup`, so a distribution handshake ends there. No `1>` reaches it; the first carrier does.
* [Low] runtime, `liberx/backend/hosted/start.c`: six names of the host's environment reach the page for the stock fd, spawn and forker ports and the stock terminal driver, where the design's page holds none. They go with those layers. The forker exits when `BINDIR` is unset and runs `erl_child_setup` from that host directory, so a boot is not yet free of host files.
* [Low] runtime, `beam/erl_time_sup.c`: edit 20 of the design is open. The stock correction runs over `erx_clock_ns`, and stays idle since system time moves with it by one offset; deleting it changes nothing a shell sees.
* [Low] runtime, `otp/erts/emulator/sys/erxos/sys_time.c`: `os_monotonic_time_source` and `os_system_time_source` report the nanosecond unit as the resolution, where macOS's clock ticks by the microsecond; a backend call for the granularity would make it true.
* [Low] runtime, `otp/lib/tools`, `otp/erts/etc`, `otp/erts/start_scripts`: not buildable from the imported
  tree (`public_key.hrl`, `ei.h`, `lib/os_mon/vsn.mk`). The runtime does not need them; `lib/tools` is to ship
  or leave the import when the release's application list is settled.
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
  `worktree-agent-a613090776683a3d8`, commits `8f893069` and `58d89236`,
  not landed) left three findings open for Phase 2's memory design.
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
  per stalled call (Security states it). Owner's decision before the security
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
* [Low] Program end, `docs/design-runtime.md` and `docs/design-programs.md`
  ("A program's end"): the runtime has the handler destroy the anchor, and
  the programs design has it destroy the program's budget. Both delete the
  tree; one should be the stated step.
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
  Pick and dispatch names and erXos's own kernel needs. The stopgap keeps
  Fiasco's ready queue until it leaves, so nothing on the target calls
  `erx_sched_wake`, `erx_sched_remove` or `erx_sched_pick` before Track K's
  kernel does. The pick also has no way to give back a thread whose switch is
  refused because a helper runs it, which the design's finishing level asks for.
* [Medium] scheduler, who refreshes (`include/erx/sched.h`,
  `erx_sched_group_configure`): S5 rests on every caller that changes a base
  or a ceiling walking the threads below it. Have the configure report what
  changed, or the core own the walk's plan, when the first caller lands.
* [High] scheduler, Track K, the cross-CPU protocol has no model and no code
  ([Concurrency](docs/design-scheduler.md#concurrency), `include/erx/sched.h`).
  It does not block M1: the stopgap keeps Fiasco's dispatch, and nothing on
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
* [Low] shell, parser choices to settle against plan9port's rc once its
  oracle runs: `|[a=b]` is read as descriptor a of the left command to b of
  the right one, which may be the reverse of rc's lex.c; an empty operand
  of `|`, `&&` or `||` is refused, where rc's grammar takes one; and
`` `split{cmd} `` is accepted; a here document's body starts after the
next newline, even inside braces, where plan9port may wait for the whole
command; `>>{`, `<>{` and `>[2]{` are refused; and a NUL byte is a word
byte, which the evaluator must refuse in a program's arguments. Add each
to the corpus and follow rc
  (`erlang/apps/erx_shell/src/erx_shell_lex.erl`,
  `erlang/apps/erx_shell/src/erx_shell_parse.erl`).
* [Medium] shell, pipeline admission: each pipeline stage is admitted at
  its full `max_heap_size`, 16 MiB, against an eighth of the session's
  budget, so a 128 MiB session admits one stage and `ps | where | sort`
  fails. Admit stages against their expected heap, or share the eighth
  among a pipeline's stages ([design-shell.md](docs/design-shell.md)).
  The 8 MiB child each evaluator parses a unit in is admitted nowhere,
  so SH2's claim that stages stay within the allowance leaves it out:
  charge it with its evaluator or admit it against the allowance.
* [Medium] shell, recovery after a refused unit: after `line too long`
  `erx_shell_parse:next/2` resumes nothing it was handed, but the lines
  of the unit that the terminal has not delivered yet (the rest of a
  pasted `fn`, or of a line still being read) would run at the top
  level, and after a syntax error inside a multi-line unit the lines
  after the fault run, as in rc. Decide what the interactive loop
  discards: the terminal's pending input, input up to a newline, or
  input until the open constructs close
  ([design-shell.md](docs/design-shell.md#the-language)).
* [Medium] shell and programs, command domains: `system`, `popen` and
  every Erlang command a program starts begin a command domain, at an
  estimated 0.15 to 0.3 s each, and `wak`'s `system()` pays it per call.
  Make one command domain per image, lazily, which holds the same
  authority by construction. Command domains take their names from the
  per-principal pool of reusable names that
  [design-system.md](docs/design-system.md#identifiers) defines
  ([design-shell.md](docs/design-shell.md),
  [design-programs.md](docs/design-programs.md#what-a-program-can-start)).
* [Medium] shell and programs, what `/bin/sh` and `system()` mean for
  ported programs: `system` and `popen` run `rc`, so a FreeBSD program
  that calls `system("cmd 2>/dev/null")` or similar sh syntax breaks,
  against the goal of running FreeBSD programs ported at the source
  level; a POSIX sh exists only in the second tier. Decide before Track
  S's programs part; the interactive shell stays rc
  ([design-shell.md](docs/design-shell.md#rc-as-a-program),
  [design-programs.md](docs/design-programs.md#toybox)).
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
* [Low] programs, compatibility: `daemon()`, the double fork, toybox's
  `setsid` and `nohup x &` cannot outlive their starter under "a program's
  tree ends with it", and only "no `SIGHUP`" is in the compatibility
  table. List them there as documented differences with tests
  ([design-programs.md](docs/design-programs.md#a-programs-end)).
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
* [Medium] kernel, boot image: `erx_image_slice` needs the verdict table and
  hashing in parts of 64 KiB, which `erx_pack_file_check`, hashing a run in one
  call, cannot give it. Make it a pure stepper the core owns, computing the
  digest itself, not a digest the caller passes in, so that function stays the
  one check. The slice also needs `pack.c` in the kernel's archive and its stack
  proof as well as in `bootstrap`, and must decide what a run of only empty
  files, an object of no pages, returns. Until it lands nothing checks a file
  `bootstrap` does not place, so a file cut short inside `system/root` boots,
  though [design-kernel.md](docs/design-kernel.md#the-bootable-file) counts it as
  refused. `tools/erx pack` stays refused until the M1 root startup, so
  `--two-file` and the slot refusal wait for it.
* [Medium] boot image, `kernel/core/boot_place.c`: Phase 1 keeps the two
  roles `boot/sigma0` and `boot/stopgap-root`, since Fiasco starts sigma0
  and a root task from its information page, and sigma0 pages that root
  with read, write and execute over its whole range, gaps between segments
  included, which nothing zeroes; Phase 1 accepts this
  ([design-stopgap.md](docs/design-stopgap.md#boot-handoff)). erXos's
  kernel maps the root task from the startup plan, so Track K decides
  whether the image keeps the two entries, which that kernel would ignore,
  or drops them with their ABI paths and the recipe in
  `tools/lib/erx/boot_image.rb`. `tools/lib/erx/boot_image.rb` builds on
  the structural fixture's unadmitted manifest until production packing
  lands.
* [Medium] kernel boot, `kernel/core/boot_place.c`: the handoff record's
  `pool_usable`, `pool_heap` and `pool_regions` are zero in Phase 1, which
  has no reader for them
  ([design-stopgap.md](docs/design-stopgap.md#boot-handoff)). Track K
  gives them values from `erx_pool_plan` (`docs/design-kernel.md`) and a
  reader in erXos's kernel, and settles where `kip_size` and the kernel's
  alignment live; they are limits of `abi/erx_abi.txt` today.
* [Medium] stopgap boot, `kernel/core/boot_place.c`: `bootstrap` places two
  entries the target design does not have, `boot/sigma0` and `boot/stopgap-root`,
  because the kernel still starts sigma0 and a root task from its information
  page; sigma0 pages that root with read, write and execute over its
  whole range, since one range cannot tell its segments apart, gaps between
  segments included, which nothing zeroes. Delete both roles, their ABI paths and the record of the recipe in
  `tools/lib/erx/boot_image.rb` when the kernel maps the root task from the
  startup plan. `tools/lib/erx/boot_image.rb` builds on the structural fixture's
  unadmitted manifest until production packing lands.
* [Medium] stopgap boot, `kernel/core/boot_place.c`: the handoff record's
  `pool_usable`, `pool_heap` and `pool_regions` are zero and `kmemsize` keeps
  Fiasco's default until `erx_pool_plan` and `abi/backend/fiasco.txt` land; the
  kernel does not read them yet. `kip_size` and the kernel's alignment are limits
  of `abi/erx_abi.txt` until that backend file exists to hold them.
* [Medium] stopgap boot, `fiasco/bootstrap/server/src/init_kip.cc`: `init_kip_md`
  writes the memory descriptors at the offset the kernel image's information page
  names, unchecked against the view's size or its count, though
  [design-stopgap.md](docs/design-stopgap.md#boot-handoff) says within the view.
  Only a kernel image whose hash matched gets there, and a kernel image already
  runs in kernel mode, so this is a crash on a bad build and no gain. Check the
  offset and count in the plan or just before the write, with a fixture.
* [Medium] stopgap boot, `tools/lib/erx/boot_image_check.rb`: two cases of the
  verification table are not run on QEMU: a single file whose header asks QEMU to
  place it away from `bootstrap`'s link address, and a boot with the validator
  removed. The first needs the harness to expect a deadline, the second a seeded
  first stage.
* [Low] stopgap boot, `fiasco/bootstrap`: the inherited image tools and module
  code (`build.pl`, `exec.cc`, `module.cc`, `boot_modules.cc`, `mod_info.cc`,
  `uncompress.cc`, `mk/tool/imagebuilder`) are unbuilt and the other platforms'
  sources still name them. Delete them or fix those platforms with the first
  port that needs one.
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
* [Medium] build, Fiasco audit of erXos sources
  (`tools/lib/erx/fiasco_provenance.rb`, `erxos_notice?`): its test is a
  substring in the first eight lines, so `BSD-2-Clause AND GPL-2.0-only`
  is recorded as `BSD-2-Clause`. Use `Attribution.erxos_addition?`, or a
  test of the same strength, once the audit's real inputs can be run
  against it.
* [Low] build, import inventory (`tools/lib/erx/origin.rb`, `Origin#check`,
  and `PackProvenance#imported_item`): a `changes` row whose hash no longer
  matches still supplies the file's licence when the file has an erXos
  header; a stale row should be refused.
* [Medium] build, notice check (`tools/lib/erx/pack_provenance.rb`,
  `attribute`; `tools/lib/erx/import_notices.rb`, `select`): the check that
  a selected import grant has a notice document looks at the whole
  expression, so `<covered> AND <uncovered>` passes with no document for the
  second grant. ChaCha20's `LicenseRef-DJB-public-domain` passes this way,
  rightly, since its notice is the header `leading_notice` keeps; a
  per-grant check must state what a file's own header counts for, and may
  find other imports short of rows.
* [Low] build, licence selection (`tools/lib/erx/license_expression.rb`,
  `PERMISSIVE`, and `PackProvenance#attribute`): the entry for ChaCha20's
  public-domain statement is global, so a file outside any import that
  declares `LicenseRef-DJB-public-domain` passes a release pack with
  erXos's `LICENSE` as its notice. Refuse it outside an import.
* [Low] build, notices (`tools/lib/erx/pack_provenance.rb`,
  `leading_notice`): `#` counts as a comment leader in every language, so a
  C file's leading `#include` and `#define` lines, and comments after them,
  reach `system/NOTICES`. Choose the leaders by file suffix.
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
  `fiasco/kernel/src/erx/erx_handoff.cpp`, the one glue module built, gets only
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

* [Medium] storage, `erx_verity` (Phase 1): the EROFS reader reads blocks
  unchecked until M11 adds the hash check inside `erx_verity:read/3`
  ([design-storage.md](docs/design-storage.md), E1), so a swapped medium or a
  flipped bit reaches the parser.
* [Medium] system domain, the reset count
  ([design-system.md](docs/design-system.md)): any successful login clears the
  count, including a web login or a compromised display domain replaying a
  recorded passphrase at a window, so a machine with a boot fault that lets
  the network come up can be kept out of rescue. Clear it only on a login at
  a secure line, or only after a login has lasted a while. Related: in a
  default release build no principal may open the system shell, so the
  rescue texts' "the operator can inspect the crash record"
  (design-system.md, design-platforms.md) holds only when the manifest names
  a system-shell principal; state that there.

* [Low] console and display, the line cap
  ([Window tokens](docs/design-live.md#window-tokens)): a display holds at most
  the lines its `console_line` parameter allows, 16 by default, and every
  principal whose sessions use that display shares them, so one principal's
  window requests, each with a valid token, can fill the display's lines and
  leave another principal's requests refused. Give each principal's sessions a
  share of the cap, or state that a shared display is one principal's.

* [Low] `erlang/apps/erx_files/src/erx_fs.erl`: a grant takes an open file's answer `{erx_fs_file, Tag, Alias, Reply}` and an
  owner's `DOWN` by matching Erlang references, which a process that can guess one can forge (`list_to_ref/1` on the
  server's node, a crafted external term from a client node). A forged answer can only answer the client's own request
  in flight early, and a forged `DOWN` clunk a fid early. Bind both to the sender when erXos's kernel carries a
  sender with each message.

* [Low] scheduler and budgets, a group's charge
  ([per-CPU records](docs/design-scheduler.md#ownership-and-lifetime)): a group
  charges one `erx_group_cpu` record per CPU to its creator's budget, so a domain
  that creates groups and reads its spending through `erx_budget_watch` or a
  carved budget may learn roughly how many CPUs the machine has, which a grant
  read back does not tell it. When the records are written, charge every group
  for `ERX_CPUSET_BITS` records, or state that the count is not a secret.
* [Medium] scheduler, Track K and M11: request batches bound an interrupt's
  length, not how much of a remote CPU a sender consumes
  ([Concurrency](docs/design-scheduler.md#concurrency)). A runtime that
  posts wakes and refreshes in a loop spends another party's time on the
  home CPUs of its threads, charged to whoever runs there, and a configure of
  a group whose threads a hostile child created takes as long as those threads,
  on the parent's time. The stopgap accepts this. Charge the receiver's work to the requester's path, as the finishing
  share's approach to kills does.
* [Medium] Entropy generator's burn on the kernel's objects
  (`kernel/core/rng.c`, `test/host/rng_test.rb`): the residue test runs
  the host build, whose frames differ from the kernel's, and the stack
  proof holds only the depth, so a flag or compiler change that moves a
  frame's padding onto a message word in the kernel's objects goes
  unseen. Run the residue check on objects built with the core archive's
  flags, under QEMU or reassembled for the host. An assembly leaf that zeroes
  downward from the stack pointer would leave no padding to check and no
  frame cap to meet.
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
* [Low] platforms, QEMU `virt`'s fw-cfg device: check whether its node,
  `qemu,fw-cfg-mmio`, offers the DMA interface on the pinned QEMU. If it
  does, list it among the bus masters of the DMA contract; the system
  manifest gives it to no domain
  ([design-platforms.md](docs/design-platforms.md#dma)).

Every other risk the design accepts is stated in its
[threat model](docs/design.md#threat-model) and in each subsystem
document's "residual risks accepted" paragraph.

## Planned features

* [High] logging: a central system log service that every source writes
  to, with routing to the UART and other readers and per-reader access,
  needs its design; it replaces the console's role as the kernel log's
  reader and decides which log lines each console line shows, a terminal
  window's and the host link's among them
  ([design-live.md](docs/design-live.md#the-console)).
* [Medium] console, log lines at console lines: until the log design
  settles routing, state in
  [design-live.md](docs/design-live.md#the-console) the access rule it
  must keep, that a line shows only log lines of domains its principal
  may inspect, and reconcile the **Logs** bullet, which still makes
  `erx_console` the sink, with design-kernel's log service.
* [Medium] console, leftovers of the one-line model: the overview
  diagram and the paragraph after it in
  [design-live.md](docs/design-live.md#overview) describe one serial
  console; the host tool reads `[kernel, crash]`, which only the system
  shell's facet reaches, so either the host link gets its own crash
  reading grant or the tool reads it through the system shell; and the
  system-shell facet, which only the console and the system shell hold,
  may read more simply as the console's per-line login record.
* [Low] console, residuals to state: processes the system shell starts
  are system-domain processes and outlive its login; a development
  manifest does not have to mark the UART secure, though development
  builds assume it; host-link login failures count in the UART's class
  and can lock a name out there; a refused connection names the line a
  terminal is connected at, which a display can read
  ([design-live.md](docs/design-live.md#security)).
* [Low] console, moving a session: an explicit detach and attach, as
  screen and tmux offer, run by the session's own user, so a terminal
  can move from one console line to another; connecting a terminal
  already connected at another line is refused
  ([design-live.md](docs/design-live.md#the-console)).
* [Low] display, plan9port compatibility: check against plan9port's source
  that acme and sam allocate no screens and reach the screen image only
  through `libdraw`'s `getwindow`, as
  [design-display.md](docs/design-display.md#compatibility-and-migration)
  assumes.

* [Low] POSIX-lite personality, FreeBSD programs: survey what FreeBSD
  programs ported at the source level need beyond the planned layer
  (BSD libc extensions, `sysctl`, `kqueue` and the like) and which of
  them the layer should offer; programs brought in come from FreeBSD or
  are BSD-licensed where possible (CLAUDE.md, principle 5;
  [design-programs.md](docs/design-programs.md#the-posix-lite-personality)).
* [Medium] shell, the rc oracle's corpus: import Byron Rakitzis's `trip.rc`
  (zlib, `github.com/rakitzis/rc`, SHA-256 in
  [research-boards-storage.md](docs/research-boards-storage.md#the-command-shells-oracle))
  beside plan9port's `test.rc` in `test/shell/rc/`, pinned like any
  source, with the cases for that implementation's extensions set apart;
  build toybox for the host and put it first in the oracle's `$path`; and
  compare the Erlang shell with `Erx::RcOracle` script by script
  ([design-shell.md](docs/design-shell.md#verification-and-testing)).
* [Low] shell, the rc oracle on Linux: `Erx::RcOracle::Build` links the
  lib9 members rc pulls on macOS; check the list and the flags on Linux
  hosts when the plan reaches them.
* [Low] shell, the rc oracle runner's residuals (`tools/lib/erx/rc_oracle.rb`), for
  trusted corpus scripts: rc stays in the operator's session, so a script
  can open `/dev/tty`; a program that leaves rc's process group escapes the
  kill at the end, and a writer killed mid-write can add bytes after it;
  a script that replaces `sigexit` can write a status report itself; the
  build inherits the host's compiler environment (`CPATH`, `SDKROOT`),
  which its record does not hold; `TZ` and the umask come from the host;
  and programs see `fn#sigexit` and `PLAN9`, which the comparison with the
  Erlang shell must leave out.
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
  allocator and pmem converter rules need; the glue-imports allowlist over
  the glue's GCC objects (`erx_handoff.cpp` already exists, and its imports
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
  accelerator ([plan.md](docs/plan.md#m1-the-system-boots-on-fiasco)).

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
  ([design-programs.md](docs/design-programs.md)). UNIX software relies on
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
* [Medium] erx_blk, `tools/lib/erx/device_posters.rb`: the rule "only `erx_blk_write` calls `erx_device:post/4`" is
  tree-wide, but every virtio driver will post; once a second poster joins `SITES`, the write path's argument also
  needs "only `erx_blk` opens a block record", which no check holds. Scope the rule per device class. Rename
  `erx_blk_write`, which now posts reads too, to what it is (for example `erx_blk_post`).
* [Low] erx_blk, `tools/lib/erx/device_posters.rb`: the check that only `erx_blk_write` posts is lexical, over Erlang
  sources: a call whose module comes from a macro (or a variable, or `apply/3`) escapes it. The check design.md's
  chokepoint table and design-storage.md's U4 name, over the storage domain's BEAM files with the compiler's call
  graph, replaces it.
* [Medium] runtime, `otp/erts/emulator/nifs/erxos/erx_device.c`: a device record maps the pages that hold its window
  (`erx_device_window_pages`), and an open of another window in one of those pages answers `ebusy`, so only one of
  QEMU `virt`'s eight virtio-mmio slots per page can be driven at a time (the QEMU plan's second disk, on
  `virtio-mmio-bus.30`, shares the first one's page, so its open would be refused). The console handoff
  (`liberx/backend/fiasco/service_task.c`, `erx_fiasco_task_mem_physical_body`) compares the request's base with the
  console's exactly, which holds for a page-aligned UART only; test containment instead. design-platforms.md's
  virtio-mmio rows give each device a domain of its own, which PL2's one-unit-per-page rule rules out on `virt`. Let records whose windows share a page share its one mapping, each still
  reaching only its own window through the register table, and test two slots of one page in
  `test/fixtures/erx_device_harness.c`.
* [Medium] erx_blk, the block driver: the device process's backlog, reply and reset decisions
  (`erlang/apps/erx_blk/src/erx_blk.erl`, `submit/3`, `resume/1`, `recover/2`) are tested only end to end, by the
  `block_device` QEMU suite's good path; they should move into a pure module whose full, held and broken cases are
  tested on the host.
* [Medium] erx_blk: a device that stops completing leaves its callers to time out in `gen_server:call` (an exit, not
  `{error, timeout}`), and a timed-out write still lands later; the driver needs a per-request deadline that resets the
  device, `call/1` should return `{error, _}`, and held requests of a caller that has gone should be dropped.
* [Medium] erx_blk: U4's trial rule is not applied in `erx_blk_write:write/6`, and `erx_blk:write/2` lets any process of
  the system domain write any sector until windows serve clients.
* [Low] erx_blk: `recover/2` answers held requests `broken` though they were never posted; they could be posted after
  the reset. An interrupt storm or a device that breaks its queue on every request costs a scheduler and a log line per
  reset, bounded by the device's rate (Phase 1 residual).
