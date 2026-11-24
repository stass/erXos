# TODO: Runtime

Open work on ERTS and OTP, musl and the C library seam, the device NIF, time, tracing, crypto and the runtime build. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Major initiatives

* [Medium] runtime, `docs/design-shared-code.md`: build shared loaded code, one prepared copy of the
  preloaded modules and the applications every domain boots, mapped read-only into every domain that runs
  the interpreter. It is wanted long term. Its trigger, three adopting domains at once, is met: the
  development manifest runs root's session and the storage, network, web and display domains on the interpreter. Each
  domain loads its own `kernel` and `stdlib` at boot, and on one CPU an image that runs everything in the
  system domain still reaches root's shell about 3.2 times sooner under TCG (the measurement and the order
  of work are in [todo-performance.md](todo-performance.md), "every domain loads its own kernel and
  stdlib"; raw logs in ~/erxos-history/boot-slow-2026-11-11 and boot-fast-2026-11-11).
  Order of work: first measure a session's pages at its prompt, with the funnel's scratch sized by frame,
  which replaces the design's memory estimates; then build the image if the adopters and that measurement
  still call for it.

## Stopgap replacements

* [Medium] BeamAsm, `test/guest/native_domain/jit_reload.erl`: the reload case shows no stale version on four CPUs,
  but nothing confirms that a load reused freed code memory, and no seeded fault (the code barrier's instruction
  barrier removed) has been shown to fail it. Record the probe's code address per load through a test hook, count
  the reusing rounds, and plant the fault.
* [Medium] BeamAsm, `beam/jit/asm_load.c` and `beam/beam_load.c`: the failure paths of edit 24 have no test: an
  encoding error's `badfile`, an exhausted code space's `{error, system_limit}`. Add a test hook that fails the next
  codegen each way and check `erlang:load_module/2`'s answer. `BeamModuleAssembler::codegen(char *, size_t)` (NIF
  stubs) still ignores flatten and fixup errors; route the three codegen variants through one checked helper and
  mark the result `[[nodiscard]]`. The design's inspector counter for an exhausted code space does not exist.
* [Low] BeamAsm, `sys/erxos/erx_jit_memory.c` (`erx_jit_memory_unmap`, `erx_jit_memory_map`): an unmap whose second
  release fails has already removed the first alias, against its header's "a refused call changes nothing", and a
  failed handle close after both maps loses the handle; the alias probe hand-encodes its return instruction.
* [Low] `otp/erts/emulator/beam/erl_process.c`: the safe point of `docs/design-runtime.md`, "Scheduling", handles the ready list only: its
  capacity and urgency steps land with the adapter that publishes them.
* [Medium] `otp/erts/emulator/beam/erl_crash_dump.c`, `beam/bif.c`, `sys/erxos/sys.c`: what `imports.txt` lists as `[stock_descriptors]`
  and the rest of `[stock_process]`: the system domain's crash dump file, which `open` refuses with `ENOSYS` (another domain's dump goes to its crash area),
  `erlang:display` and `halt`'s output, the terminal's `sys_get_key` and `ethread`'s signal masks. Each is answered as `ENOSYS` tracing shows it.
* [Medium] `otp/erts/emulator/sys/erxos/sys.c`, `beam/erl_crash_dump.c`, `beam/bif.c`: what `imports.txt` lists as
  `[stock_process]` and `[stock_descriptors]`, the UNIX process ERTS still assumes: the signal dispatcher, `sigaction` and the pipes of
  Darwin's main thread, `nice`, `alarm`, `uname` and the crash dump's descriptors (edit 34). The first native boot answers each,
  as `ENOSYS` tracing shows it;
* [Low] `test/fixtures/runtime_event_harness.c`: the sleep step's model copies the park core by hand and has no waker; driving
  `erx_backend_park_step` and a waker would pin the reason the epochs come before the flag.
* [Medium] `test/integration/runtime_prim_file_test.rb`: no hosted test reads through an EROFS entry with prim_file
  since erx_ns's only EROFS mount became `{erofs, app}`, which takes the session's app record and a file grant; the
  system domain the test boots holds neither. `erx_ns_tests` reads the mount with erx_erofs directly, never through
  prim_file, so no test covers prim_file forwarding an image descriptor to `erx_erofs_file` (read, pread, position,
  write answering ebadf, close, a directory answering eisdir), `set_cwd` into an image, links on an image, or the
  order of erofs against eexist and enoent. A hosted case needs the app record and a packages grant standing in, as
  `erx_ns_tests:app_package/1` does on the host.
* [Medium] `test/integration/runtime_prim_file_test.rb` `test_tmp_serves_the_domain`: `tmpx old owners counted`
  answers false, so `tmp_processes/1` in `prim_file_compare.erl` finds fewer than three processes (the tree, the
  grant and what links to the grant) before it kills /tmp's tree. Find which owner is no longer linked to the
  grant before the expectation moves.
* [Low] `otp/erts/emulator/test/binary_SUITE.erl`: `make_port/0` is `hd(erlang:ports())`, and `ports()` is empty by design,
  so its term-ordering cases fail with `hd([])`. Opening `{spawn_driver, "ram_file_drv"}` there gives a real port (checked on
  hosted), and is the route when the suite is next run for its results.
* [Low] `otp/erts/emulator/test/process_SUITE.erl`: `max_heap_size_test/5` fails with `{badmatch, noproc}` under a runner
  with no common_test, because `ct:log` delays its monitor past the process's death. It needs a run under `ct_run` to tell
  whether this is the runner alone.
* [Medium] `tools/lib/erx/oracle_suites.rb`: the oracle runs each group's checked-in `*_SUITE.erl` only, on both
  sides. OTP's compiler test Makefile (`release_tests_spec`) also generates about a dozen variant families from them
  (`_no_opt`, `_post_opt`, `_inline`, `_r26`, `_no_ssa_opt`, `_no_type_opt`, `_cover`, `_dialyzer` and others), the
  `lfe_*_SUITE`s from `.core` files and `property_test/`, compiled with `+clint +clint0 +ssalint`; stdlib's installs
  `PropList.txt` and `DerivedCoreProperties.txt` into `unicode_SUITE_data`, `otp_version_tickets` into
  `stdlib_SUITE_data` and two doctest guides. A code generation bug that shows only under `no_opt` or `r26` passes
  the oracle. Building each group's suite directory from its own `release_tests_spec` would run the group as stock
  defines it, and replace `RELEASED_HEADERS`.
* [Medium] `tools/lib/erx/oracle_hosted.rb`: map_SUITE `t_tracing` fails on the hosted runtime
  with `dbg` undefined, although the oracle's hosted tree carries `runtime_tools`. The system domain under QEMU
  passes it, so `emulator.txt`, which the QEMU run holds to no stale row, has none for it. Trace why `dbg` is not
  found on the hosted runtime and fix it.
* [Medium] `test/oracle/hosted_known_differences/stdlib.txt`: stdlib differences not yet traced to a cause, each a row
  citing this item: edlin_expand_SUITE `filename_completion`, `function_parameter_completion`;
  escript_SUITE `archive_script`, `archive_script_file_access` (compilation
  error); filename_SUITE `absname`, `absname_bin` (`enoent`),
  `t_basedir_xdg` (`HOME` is unset on the erXos side); qlc_SUITE `evaluator`; shell_SUITE `otp_5435`, `records`;
  stdlib_SUITE `app_test`; rand_SUITE `doctests`.
* [Medium] `otp/lib/stdlib/src/shell.erl` (restricted shell): shell_SUITE `start_restricted_from_shell` is a
  known difference because `q()` is a shell-local command (design-shell.md, "Compatibility and migration"), so it
  stops at its local-function list and its later checks never run on erXos: that a restricted shell refuses each
  local function, `shell:stop_restricted/0`, and the cleared `restricted_shell` env. Add an erXos test that runs
  those checks with `q` in the list and pins `q()` in a restricted shell ending that shell unchecked by the
  restricted module.
* [Medium] `otp/erts/preloaded/src/prim_file.erl` (`read/2`) and the file server's read: `file:read(Fd, N)` with an
  absurd N (file_sorter_SUITE `misc` reads a 2^128-1 length field) answers data or `eof` where stock answers `einval` or
  `enomem`, so the case gets `premature_eof` instead of `bad_object`. Read the size path; refuse sizes past the limit
  with `einval`, with a regression test.
* [Medium] `otp/erts/emulator/beam/erl_process.c`: schedulers are not pinned to the group's run, the default stays stock's
  `+sbwt`, and `+S` is not derived from `erx_group_info`'s capacity, which no one configures yet
  (`docs/design-runtime.md`, "Scheduling"). Each waits for a consumer of a capacity word in Phase 2's groups.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`, `find_open`: a page run (`find_run`), a line entry (`find_line`) and memory held by another record are told by comparing handle values, so one object given under two handles (a give that installs it twice, or the root's own `-erx_record given` records over slots it holds otherwise) passes: two records carve the same pages of one memory, and one IRQ object under two handles is two entries, whose second bind takes the first binder's deliveries. Compare the objects the backend resolves, or make one handle per object a promise of the domain library that the NIF states.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device.h`: the physical form is the zero value of `erx_device_form_t`, so a spec whose form no decoder set makes physical objects; give 0 to a refused `ERX_DEVICE_FORM_NONE` and set the physical form explicitly in `decode_window`.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device.c`: a failed `erx_device_open` keeps the window's mapping and any line objects it made (in the given form, the window's mapping and the memory's reservation), a retry takes another mapping from the shared device
  window and finds the line `ERX_EBUSY`. A boot's devices are few and a failure is a misconfiguration; the record's cleanup comes with the device service.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`, queues: the NIF does not yet refuse `post/4` after the exit of a
  driver process that used the device until `negotiate/2` (`docs/design-runtime.md`, "The reset rule", R8); it needs the
  device's record to monitor the processes that post, as a line's binding does. A restarted driver's sequence
  (`queue_create/4`, `negotiate/2`) does not depend on it. `erx_device:stop_register_ring/1` marks GENET's queues not
  ready and `erx_genet` calls it before any post, so a GENET restart does not post before `negotiate/2`; the
  NIF still refuses nothing between the predecessor's exit and that call, and virtio and xHCI are
  unchanged. The fix by construction is to monitor the process that negotiated and to unready the device's
  queues at its exit, as the interrupt line's binding already monitors its holder.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`, queues: the queues run through the handoff sequencer
  ([design-device-dma.md](design-device-dma.md)) and follow the record's coherence mark. The
  `net_device` suite's `noncoherent` cell runs the non-coherent path on QEMU `virt` under HVF and TCG
  ([design-device-tree.md](design-device-tree.md), "The live tree on QEMU"), so user mode runs `DC CVAC`
  and `DC CIVAC` under Fiasco on both; QEMU's DMA is coherent, so the cell shows that the maintenance
  runs and costs no traffic, not that it is sufficient. A device whose DMA is not coherent has not run it: the
  Raspberry Pi 4's given devices have no queues yet. The host tests count the
  maintenance a non-coherent queue issues but do not run it. What is missing besides: the hosted
  stand-in running its plans over `erx_dma_model.c` (its maintenance is empty, `arch/host/erx_dma_arch.c`), so
  the NIF's non-coherent path has no host test with a cache that hides stores; a virtio-gpu region entry, which
  a post writes as an out segment's bytes, so the check does not see its address; the check tying a memory
  address's reach to a buffer the plan hands to the device, and a register-published address's to the rings;
  a register-held length (virtio's `QueueNum`) checked against the reaches the install publishes; a descriptor rewritten while its
  chain is posted, which no view expresses; field-level register ownership, and the ADMA2 (SDHCI)
  descriptor form. The hosted stand-in GENET's plans run on plain memory, not over
  `erx_dma_model.c`, and its engine sets no receive error flags, so design-device-dma.md's receive-flags case is not run over it; the register ring's effect layer is tested over a given GENET by
  `test/fixtures/erx_device_genet_harness.c`, coherent caches only. The maintenance step `L` is read from the current CPU's CTR_EL0 at each plan, so CPUs reporting different lines
  would need the smallest taken once. Test gaps: no NIF test drives a refused
  plan; the check's fuzz target runs at granule 1 only, and chains of three
  or four segments are not driven through the check.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`, [The display device](design-display.md#the-display-device):
  on the direct path a display driver maps a client's pixel area read-only into its device's DMA window; the device
  NIF cannot map an area into the window yet.
* [Medium] `test/erlang/erx_input_tests.erl`, [Verification and testing](design-display.md#verification-and-testing)
  (The input router): some of the router's properties are not tested: that the repeats a window receives are
  the same when the other window's presses of the letter are taken out of the sequence (the keys run gives the
  second source only the letter); that the layer a key types at follows from the modifiers held and the locks
  on alone; that no pointer event carries a button its window did not see pressed, which the pointer run cannot
  catch with only button 1 in its alphabet (a single case covers it); and that `erx_winfs:input/2` does not
  return while the router holds the record. Of the seeded faults that list names, the chord's, a repeat sent to
  the window that takes the keyboard, one repeating key for the display, a button's up or a source's end whose
  pointer event the policy routes, a touch down at a held slot that moves it and a modifier kept as a flag are
  not planted.
* [Low] `test/erlang/erx_draw_ref.erl` and `erlang/apps/erx_win/src/erx_draw_core.erl`: `supported_chan/2` is
  copied between the core and the reference, so a change to the channels `b` refuses must be made in both. Export it
  from the core, or keep the copy as the oracle's own and say so in it.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device_nif.c`: a move of a bound edge line can lose the one delivery taken under the old label just before the old sink was unregistered, while a level
  line fires again at the bind's acknowledgement. A driver of an edge line looks at its device after binding. The PL011's line is level.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`, the hosted stand-in: its virtio model (`stand_in_preset`, `stand_in_stored`, a hook in `store()`) is a second model of a virtio-mmio transport beside `test/fixtures/erx_device_dma_harness.c`'s, which sits at the access seam and leaves `erx_device.c` untouched. A hosted-only `device_access` over the fixture's model would remove the hook and the duplicate, and keep `queue_ready` per selected queue, which the stand-in's one word cannot (so one queue still ready, `ERX_EBUSY`, is not expressible hosted). Settle it before the SD host gets a stand-in, so each device has one model, as GENET's is `erx_device_genet_model`, which the hosted stand-in and the host harness share.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device_genet.c`, the round function: no fuzz
  target drives `erx_device_genet_round`. `tools/fuzz/device_genet_fuzz.c`
  drives the core beneath it, so the round's handling of the entries,
  GENET's statuses and `bytes_max` is tested only end to end through the stand-ins. Run each round function in a
  loop like `run_call`'s, with fuzzed observation values, and check that its steps and answers stay within the
  effect layer's arrays, every completion step is a copy, each answer's copies sum to its length, and the call
  ends within `ERX_DMA_ROUNDS_MAX`.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device_dma.h`, `erx_dma_round_t`: the round record says by flags
  which of its outputs count (`ends` or a plan, `keeps` or `after`, answers only in a completion, `value` only at
  IDLE's end), and its `steps` and `answers` carry no capacity: each form keeps within the effect layer's arrays
  by its own bounds, which `erx_device.c` asserts at build time. Give the record its capacities, refused at the
  write, or make its output a tagged variant: an end, an observation, or a plan with its answers.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device.c`, `erx_device_complete`: the rule that a queue not ready
  answers `ERX_ECORRUPT` has two owners, the forms' posts and `erx_device_complete` before the completion's
  round. Give it one.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`, `negotiate/2`: `device_features` and `queue_num_max` stay readable through `read/2` though their selectors are the NIF's, so such a read returns whichever word or queue the NIF selected last; and a driver learns the offered features and a queue's maximum only through a negotiation, so a multi-queue device (virtio-blk with `MQ`) needs two. Refuse reads of selector-banked registers and have `negotiate/2` return the offered set, or design a read-only probe.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device.c`, `negotiate/2`: the reset is read back once, so a device that finishes its reset asynchronously gets `{error, ebusy}`; a short bounded poll would serve it.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device.c`, queues: the install zeroes the rings but not the pool, so a device that reports a used length beyond what it wrote returns an earlier request's bytes of the same driver; and the whole-plan install is tested with one queue only.
* [Low] musl, `liberx/backend/fiasco/arch/aarch64/task_start.S`: a task's 256 KiB first stack lies in `.bss` with no
  guard page, so a deep test overruns its own globals, possibly `t_status`, instead of faulting.
* [Low] musl, `tools/lib/erx/libc_test.rb`: `NEEDS` also holds back tests using `sigprocmask` and `pthread_sigmask`,
  which the seam answers with no effect; and `Dependencies`'s git fetch reads the user's git configuration, which
  the pinned hash catches only as a failed fetch.
* [Low] musl, `musl/src/internal/erxos/syscall.c`: the seam includes the Fiasco backend's private headers. Move
  it behind a neutral `liberx` header when the erx backend needs musl.
* [Medium] musl, `musl/src/internal/erxos/syscall.c`: the seam includes the Fiasco backend's headers and assumes
  the root (`erx_machine_end` for `exit_group`, a handle that is an index). A task needs the launcher's status path
  and handles with generations; the next part of the port settles it with `libc-test` in a task.
* [Low] musl, `musl/src/thread/erxos/clone.c`: the start takes three liberx calls in a required order, and the
  registers travel in the UTCB. One call taking the start state and the word to clear ends the order and the leak
  a failed clear-word call would leave, with the thread package's `erx_fiasco_reaper_start` as its second user.
* [Low] musl, `musl/Makefile`: `ARCH_CPU` layering reaches `lib/libc.a` only; `crt1.o`, the dynamic linker and
  `install-headers` still name `arch/$(ARCH)` and `crt/$(ARCH)`.
* [Low] musl, `musl/arch/erxos`: `docs/design-runtime.md` deletes `__syscallN` and the `SYS_` numbers; the seam
  keeps them as the tokens of one switch, so all of musl still compiles and refuses at run time. Delete them when
  the personality has replaced what they name.
* [Low] musl, `musl/src/misc/uname.c`: `uname(3)` reaches the seam as `SYS_uname`, which answers `ENOSYS`.
  It should fill `struct utsname` from `erx/abi.h`'s `ERX_UNAME_SYSNAME_STRING`, `ERX_UNAME_RELEASE_STRING` and
  `ERX_ARCH_MACHINE_STRING`, and the node name from the host part of the boot information's node name, which the shell's `uname`
  (`erlang/apps/erx_shell/src/erx_cmd_uname.erl`) reads as init's `-sname` or `-name`, with no value of its own; `docs/design-shell.md`, "Text commands".
* [Low] musl, `musl/include/sys/ttydefaults.h`: the `TTYDEF_*` flags and the `C*` characters are FreeBSD's
  (`sys/sys/ttydefaults.h`), but they restate `erx_tty:new/0`'s defaults by hand. Generate the header from
  the tty's defaults, or move the defaults into `abi/termios.txt`, so the C and Erlang defaults have one
  source.
* [Low] musl, `abi/termios.txt`: the generated `bits/termios.h` defines only the table's names, so a FreeBSD
  program naming a bit erx_tty drops (`ECHOPRT`, `FLUSHO`, `PENDIN`, `EXTPROC`, `CIGNORE`, `CRTSCTS`,
  `MDMBUF` and the other modem flow-control flags) or `TABDLY`, `TAB0`, `EXTA` and `EXTB` does not build,
  where FreeBSD's `tcsetattr` would drop the bit. Every name is also visible without `_BSD_SOURCE`, where
  FreeBSD hides its BSD names unless `__BSD_VISIBLE`. Give the table a line for a name a program may write
  that the tty drops, and a visibility column, when a ported program needs them.
* [Low] musl, `musl/include/termios.h`: `TCSANOW`, `TCIFLUSH` and `TCOOFF` and their siblings are FreeBSD's
  numbers (`include/termios.h:59-72`) copied by hand, and `TCSASOFT` is missing (musl's `tcsetattr` refuses
  any action above `TCSAFLUSH`). No seam reads them yet: `tcflush` and `tcflow` fail with `ENOTTY` in a
  program and `ENOSYS` in the root domain. Move them into `abi/termios.txt` when the program protocol
  carries them, so the seam's decoder reads the same numbers.
* [Low] bootstrap, CPU feature words (`kernel/arch/aarch64/cpu_id.c`): only the boot CPU's identification
  registers are read, and every CPU is taken to have its features. QEMU `virt` and the Raspberry Pi boards
  have identical CPUs; a board whose CPUs differ needs the intersection over all of them.
* [Medium] musl, `musl/src/thread/erxos/pthread_create_executor.c`, `musl/src/internal/erxos/syscall.c`: only the boot covers them. `test/guest/native_musl` needs the hosted
  driver's cases (no attribute, no free slot, the slot given back at exit).
* [Low] `otp/erts/emulator/sys/erxos/sys.c`, `beam/erl_process.c`, `beam/erl_driver.h`: what signals' deletion leaves unused: the break flag and `erts_do_break_handling`, `thr_create_sigmask`,
  the Darwin steal declarations, and the `ERTS_SYS_SUSPEND_SIGNAL` and `ERTS_HAVE_TRY_CATCH` blocks.
* [Low] `otp/erts/emulator/sys/erxos/sys.c`: on hosted a write to a closed pipe ends the process with `SIGPIPE`, and a crash dump has no time limit; a dump says it could not read a process's stack, where it did not try.
* [Medium] runtime, the host link's kind: `hostlink_kind` (`liberx/backend/core/boot_manifest.c`)
  writes the PL011's compatible string and peripheral by hand beside the PL011 row of
  `erx_uart_kinds` (`include/erx/device_kinds.h`), so renaming that row leaves the host link matching
  the old string and the boot without its host-link record. The host link's row belongs in
  `device_kinds.h` with the UART kinds, where the Ruby reader can check it names a UART kind's.
* [Low] runtime, `erlang/apps/erx/src/erx_syslog.erl` `init/1`: `temporary` covers only a started child, so a crash of the log service's `init` while `kernel_sup` starts fails `kernel_sup` and resets the machine, where [design-log.md](design-log.md#service-lifetime-and-restart) runs on without a log. No such crash is known (the take's answers are the NIF's fixed shapes); make `init` total, turning a failed take into a note, with a test of a take that raises.
* [Low] runtime, `erlang/apps/erx/src/erx_syslog.erl`: the log service takes one window of the kernel log per 100 ms tick, so a burst it is still catching up on can be overwritten and cost a "records lost" line though the records were in the ring when the burst began. [design-log.md](design-log.md#the-kernels-records) takes again at once while a take fills its window, but `erx_log:take/0` does not say whether it did; have the NIF report it.
* [Low] runtime, `erx_log_nif.c` `read_lines`: a record that fails the reader's checks ends the window, and the console's line says so without saying how many records after it were dropped.

## Bugs by subsystem

* [Medium] `otp/erts/emulator/nifs/erxos/erx_device_nif.c` (`status_error`): a hand-kept copy of the ABI's
  status-to-atom table; a status it lacks reaches Erlang as `{error, {status, N}}`. Generate it from
  `abi/errno.txt`, as the other tables are, or route it through the one table ERTS already generates.
* [Medium] runtime, `test/integration/runtime_hosted_smoke_test.rb` fails twice on the hosted
  runtime: `gen_tcp:listen(0, [])` raises `undefined function erx_gen_tcp:listen/2` where the
  test expects `{error,enotsup}`, and `erx_device.o` imports `aligned_alloc`, which the seam's
  import list lacks. Neither touches code loading.
* [Medium] runtime builds (`tools/lib/erx/runtime.rb` `Runtime::LOCK`): the lock covers each runtime build and
  clean only, so two gates in one tree still meet outside it. A build removes the build record and relinks the
  emulator while the other gate reads them after its own build returned: `Runtime.check_current`, the hosted test
  runs, the hosted release (`tools/erx` `build_runtime`, whose `Release#build` empties `release/work`), the BeamAsm
  image link into `build/runtime/native-jit/image` and every image link that reads the runtimes' archives. The
  failures are errors, not silent corruption. Rather than putting each reader under the lock, readers could take a
  shared lock on the same file (`FileLock` with `LOCK_SH`), the build could run its caller's link inside the lock,
  or a gate could hold one lock for its whole run. A build whose Ruby process is killed outright (SIGKILL) also
  leaves its make and configure running in the build directory with the lock released.
* [Medium] runtime readers (`tools/lib/erx/runtime.rb` `Runtime.reading`): each reader of build/runtime takes the
  shared lock at its own site (`tools/erx`, `OracleHosted#run`, `ProductionImage#assemble`, `NativeDomain`,
  `Programs`, the hosted tests), so a new reader that forgets it reads unlocked, and only the hosted tests have a
  source check. A native reader also does not check, inside its read, that the tree still holds the build it
  follows: flock cannot downgrade atomically, so another run may rebuild, or leave a failed build, between the two.
  Making `Runtime#build` yield the build to a block under the shared hold, checking the kind's build record there,
  and keeping the output paths reachable only through it would make both hold by construction. Whether macOS flock
  lets a stream of overlapping readers starve a waiting build is unverified.
* [Low] runtime builds (`tools/lib/erx/runtime.rb` `Runtime::LOCK`, `tools/lib/erx/runner.rb`): a build whose Ruby
  process is killed outright (SIGKILL) leaves its make and configure running in build/runtime with the lock
  released, so the next build or reader meets them. Every other exit, SIGTERM and SIGINT included, ends each
  command's process group in `Runner#run`'s ensure. Handing the lock's open file to the build's commands would keep
  the lock held until the last of them exits.
* [Low] OpenSSL, file access (`docs/design-crypto.md`, K5 and CR5): `libcrypto.a` still references `fopen`, `open`,
  `opendir`, `stat` and `syslog` (file BIOs, the `file:` store loader, `X509_LOOKUP` by directory) and keeps
  `OPENSSLDIR="/usr/local/ssl"`; K5 holds because `no-autoload-config` stops the implicit loads and OTP's `crypto` names
  no file. Give Configure an `--openssldir` of erXos's, so a caller that does name OpenSSL's directory finds erXos's.
* [Medium] HTTPS clients, the trust store's remaining checks (`tools/lib/erx/release_files.rb`, `trust_store`,
  [design-crypto.md](design-crypto.md#the-trust-store)): every release that holds `public_key` carries
  `priv/cacerts.pem`, built from `config/trust/` and attributed through its inventory, but a test image cannot yet
  add roots of its own after the tree's, and the design's "store on QEMU" row (`public_key:cacerts_get/0` in a
  session of the interpreter image) has no suite.
* [Medium] HTTPS clients, the store by construction (`tools/lib/erx/trust_store.rb`): build it from `config/trust/ORIGIN.md`'s
  rows instead of a `*.pem` glob (which is case-insensitive on macOS and follows links): each recorded file a regular
  file by `lstat`, its bytes matching the recorded SHA-256, one block decoding to exactly one DER certificate (two
  certificates base64ed into one block, or an empty block, pass the form check today), and any other entry of the
  directory refused. Build `cacerts.pem` and its receipt's hashes from that one read: `ReleaseFiles#trust_store`
  reads the roots for the store and again for the receipt, so the two are not bound to the same bytes. Also assert in `release_files_test.rb` that the session and app scripts load `ssl` and `inets`.
* [Medium] HTTPS clients, the rest of design-crypto's client work: `inets`' `httpc_bound` edit and its tests (CR8),
  and `ssl` in the web domain's script for its listener
  ([design-crypto.md](design-crypto.md#otps-applications)).
* [Medium] crypto NIFs, rebuild (`tools/lib/erx/native_runtime.rb`, `build_openssl`): the static objects of `crypto.a` and
  `asn1rt_nif.a` have no header dependencies (`otp/lib/crypto/c_src/Makefile.in`'s `%_static` rule, `otp/lib/asn1/c_src/Makefile`)
  and the configure stamp does not cover OpenSSL's options or headers, so a change to `Libcrypto::OPTIONS`, `openssl/include` or
  `erl_nif.h` leaves them compiled against the old headers. Fold a digest of the OpenSSL prefix into the stamp, as
  `NativeJitRuntime#sdk_root` does for libc++, and give the prefix's header copy `--delete`.
* [Low] musl, strerror (`musl/src/errno/__strerror.h`, `abi/errno.txt`): the texts are a hand-edited file kept in step with
  the errno table by `test_strerror_describes_every_errno`, while the signal descriptions are generated. Give `errno` rows a
  description column and generate the strerror table from it, so one file holds each errno's name, number and text.
* [Medium] musl, strerror (`musl/src/errno/__strerror.h`, `test/host/abi_errno_test.rb`): the 17 texts taken
  from FreeBSD's `lib/libc/gen/errlst.c` are a hand-kept copy that no test compares, while the signal table's
  descriptions are checked against a pinned `siglist.c`. Pin `errlst.c` in deps.lock (`freebsd-errlst`), name it
  in design.md's dependency row beside `sys/sys/errno.h`, and compare each FreeBSD-sourced text with it, or give
  `errno` rows a description column and generate them.
* [Medium] crypto, first seeding's failing half (`docs/design-crypto.md`, "Verification"; `test/guest/native_domain/guest.c`,
  the crypto cases): the QEMU test that a domain of each image whose generator fails before its first seed gets an exception
  from `crypto:strong_rand_bytes/1`, not bytes, is not written. No test hook makes the generator service refuse one domain's
  reads, and refusing them from the domain's start ends it before ERTS runs (`liberx/backend/fiasco/libc_start.c`, AT_RANDOM's
  read, `ERX_FIASCO_TASK_STATUS_ENTROPY`), so the hook must refuse a running domain's reads only. The passing half runs in
  native_domain's crypto and jit_crypto cases, and is K2's one test on a built image: it fails if `rand_unix.c`'s edit is
  lost (the weak `getentropy` ends the seed in `ENOSYS`), but only the failing half shows `erx_entropy_read` is the only seed.
* [Low] crypto NIFs, table make rule (`otp/erts/emulator/Makefile.in`, `driver_tab_crypto.c`): the table depends on the
  archives' times, not on `ERX_CRYPTO_NIF_LIBS`'s value, and its empty-variable guard runs only when the table is remade.
  An archive taken out of `DomainImageApps` leaves a stale table whose init function no link defines, so the link fails
  closed, but on an undefined symbol that needs the runtime copy cleaned by hand. A stamp file of the variable's value as
  a prerequisite would remake it.
* [Low] crypto NIFs, seam check (`tools/lib/erx/runtime_seam.rb`, `nifs:`): the NIF archives' definitions count as inside ERTS's
  import check, but their own imports from musl and libcrypto are not compared with `imports.txt`.
* [Low] OpenSSL, build (`tools/lib/erx/libcrypto.rb`): `__FILE__` in libcrypto's error records is the source's path
  relative to the build directory (`../../../openssl/...`), so a build at another depth (a runtime's) makes different
  bytes; build at a fixed depth or configure `no-filenames`. `tools/erx build openssl` and `make check-openssl` share
  `build/openssl/`, so two at once clash.
* [Low] OpenSSL, stack protector (`config/openssl/erxos-aarch64.conf`): libcrypto is built with `-fno-stack-protector`, as
  ERTS is by `otp/xcomp/erl-xcomp-aarch64-unknown-erxos.conf`, though musl provides `__stack_chk_guard` and seeds it from
  `AT_RANDOM`; decide for both whether `-fstack-protector-strong` is wanted.
* [Low] OTP applications, build (`tools/lib/erx/runtime.rb`, `build_application`): the stock oracle's `erlc` compiles
  every application, so each `-include_lib` (ssh's of public_key's headers, public_key's of kernel's) and each
  behaviour a module names resolve to the oracle's installed applications, not to `otp/`'s. Give the application makes
  `ERL_LIBS` (or `-pa`) naming the copy's `lib/`.
* [Medium] asn1, run-time cases (`otp/lib/asn1`, `otp/ORIGIN.md`): the import leaves out asn1's suites, which test the
  ASN.1 compiler, and with them the two cases of OTP 29.1.2's `asn1_SUITE` that call `asn1rt_nif:decode_ber_tlv/1`
  alone: `ber_decode_invalid_length` (a length past the input raises `{asn1,{invalid_value,12}}`) and
  `otp_14440_decode` (32 KiB of `16#7f`, the BER reader's depth). The reader parses certificates and keys from other
  parties. Carry both into a run-time suite of erXos's that `make check-oracle` compares with the oracle.
* [Medium] public_key, imports between ASN.1 specifications (`tools/lib/erx/runtime.rb`, `copy_sources`):
  `lib/public_key/asn1/Makefile` records no dependency between specifications but PKCS-FRAME's members, so an edit to
  one (`PKIX1Explicit-2009.asn1`) regenerates only its module, and its importers (OTP-PKIX, OTP-PKIX-Relaxed) keep code
  generated from the old types. Stamp the copy over the specifications and the ASN.1 compiler's version, and remove every
  generated source and beam when the stamp changes; that also makes `modules_with_generated_erlang` unnecessary.
* [Low] OTP applications, `src/deps/deps.mk` (`otp/ORIGIN.md`): generated by `erlc -M` and imported for nine
  applications; `rsync -a` puts the imported copy back over the build's each time, so make regenerates it and restarts on
  every build. Exclude it from the import.
* [Low] public_key, shipped headers (`tools/lib/erx/release_files.rb`, `headers`): the domain release ships an application's
  headers from the tree, and `include/PKCS-FRAME.hrl`, which public_key's asn1 make generates, is in the build's copy only,
  so it does not ship, though stock OTP installs it; ship generated headers from the copy with their specifications as
  their sources.

* [Low] ERTS start-up (`otp/erts/emulator/beam/erl_process.c`, the "hold executor slots" line): the scheduler
  count follows the manifest's CPU set, not the CPUs present. The system domain and the storage domain report
  4 schedulers on the website's 1-core v64 machine. Size them from the CPUs the kernel reports present.
* [Low] ERTS, a lone normal run queue's balance counters (`otp/erts/emulator/beam/erl_process.c`,
  `check_balance`): with one run queue in use (`+S 1` or `schedulers_online` 1), `check_balance` returns early
  without resetting queue 0's `int` `procs.prio_info[].reds` and `ports.info.reds`, so they grow until they wrap,
  after about 2^31 reductions; raising `schedulers_online` then feeds the wrapped value to one balance round. Stock
  OTP does the same. Reset them in that early return, or widen them.
* [Medium] runtime, `otp/erts/emulator/sys/common/erl_mseg.c` (`mseg_alloc`): when the budget
  refuses the commit behind a new carrier, `mseg_alloc` fails without emptying the segment
  caches, so a domain near its budget can be refused a carrier while its own freed carriers
  (up to two per scheduler's instance, single-block ones of any size) stay committed in them.
  `erts_mseg_clear_cache` runs only on the `malloc` paths of `sys/erxos/sys.c`, and clears only
  two instances. On a refused commit, clear every instance's cache and retry once; the
  regression test frees a large binary in a domain held near its budget and then allocates.
* [Low] Runtime, the envelope (edit 16; `erl_message.c`, `erts_msg_attached_data_size_aux`):
  the size estimate of an undecoded message from another domain leaves out the envelope's
  4 words, so the GC's heap need, `process_info`'s total heap size and the crash dump's
  sizes count each such message 4 words short; the decode itself reserves them.
* [Low] Runtime, the envelope (edit 16; `erts_proc_sig_decode_dist`):
  `make_small(edep->erx_origin)` takes a 32-bit domain id for a small integer, which holds
  only on a 64-bit build; a 32-bit port needs ids bounded below its small range.

* [Medium] runtime build, `tools/lib/erx/runtime_seam.rb` (`check_imports_of`): the BeamAsm image's import check counts
  what libc++ and libc++abi define as available to ERTS, but never checks their own undefined names (`malloc`, `abort`,
  pthreads) against `otp/erts/emulator/sys/erxos/imports.txt`, so the C library seam does not cover the C++ runtime. Add
  the two archives to the undefined-name pass.
* [Low] runtime build, `tools/lib/erx/libcxx.rb`: the libc++ configure stamp records the compiler's path, not its
  version, so a Homebrew upgrade of LLVM at the same path keeps the old objects (ERTS's stamp has the same gap). Stamp
  `clang --version` instead, or `BuildMemo.program_identity` as `Libcrypto#configuration_key` does.
* [Medium] ERTS, `sys/erxos/erx_program_drv.c` (`PROGRAM_POOL`): no session has a pool for programs
  yet, and Fiasco reports no budget's cap, so the driver checks a spec's cap against
  `UINT64_MAX` and only the carve of the program's budget bounds it. Give the session its pool, as
  docs/design-runtime.md, "Programs as ports", step 1 has it, and check against that.
* [Medium] ERTS, `sys/erxos/erx_program_drv.c`: a failed `erx_space_stop` of a program's anchor is
  not fed back to the core, so a program whose anchor did not stop leaves its port waiting for a
  close that only `port_close/1` or its owner's exit gives.
* [Low] ERTS, `sys/erxos/erx_program_drv.c`: the gate worker's 64 registrations (two a program) bound a
  session to 32 programs at once, each start past that refused with `elimit`.
* [Low] ERTS, `sys/erxos/erx_program_drv.c` (`hand_install`) and `erx_program.erl` (`install/2`):
  an install's error answer is allocated after the refused bind or the stop, so when that allocation
  fails `install/2` raises `badarg` instead of answering `{error, _}`. A handler that does not catch
  it exits, which closes the port and ends a program a refused bind had left running. No copy
  stays in a running image either way. Preallocate the error answer with the ok answer.
* [Low] ERTS, `sys/erxos/erx_program_drv.c` (`pass_or_stop`, `frame_write`): both stop the program
  through `end_feed` without reading the stop's answer, so a stop `erx_space_stop` refused would leave
  the program running, with an install's copies in the first case. Read what the Fiasco backend can
  refuse there and fail the port if it can.
* [Medium] ERTS, `sys/erxos/erx_program_drv.c` (`started_values`, `answer`) and `erx_program.erl`
  (`open/7`): when STARTED's answer cannot be allocated, the driver's control returns a negative
  result and `port_control` raises in `erx_program:start/1`, which has no cleanup around the call. A
  caller that catches the exception keeps running with a port it cannot name, which holds the program's
  spaces, its holder hold and its window's lease until the caller exits and the port closes. The answer
  of a start with the most hand-offs, `prog_fds_max` of `pipe_hand_copies_max` copies each, is about
  25 MB, so the failure is not far-fetched. Answer `enomem` from a preallocated reply and stop the
  program, or close the port in `open/8` when the call raises.
* [Medium] musl, `getuid`: `getuid`, `geteuid`, `getgid` and `getegid` answer 0
  (`musl/src/internal/erxos/syscall.c`, `ROOT_USER`), where docs/design-programs.md ("Users and
  files") says the principal's number, never 0, so a program's `id` and its session's
  `/etc/passwd` disagree. A session holds the number as its `principal` variable
  (`erx_dom_plan_session`), but no design names how a program learns it: the startup message
  ("The startup message") lists no such field, and a program's environment is its starter's to
  choose. A `uid` field of the startup message beside `pid`, filled by the handler from the
  session's variable and kept in `erx_prog_self_t`, would carry it as `pgid` carries the job;
  design-programs decides first. `getpid` likewise answers 1 rather than the startup message's
  `pid`.
* [Low] ERTS, `sys/erxos/erx_event.c` (`deliver`): when `enif_alloc_env` answers NULL, a process
  sink's event is not sent, so the process misses that ring. Out of memory only; make the
  message's env with the sink, so sending it cannot fail for memory.
* [Low] ERTS, `nifs/erxos/erx_area_nif.c` (`finish_return`): when `enif_alloc_env` answers NULL, the
  lender never gets the lease's `returned` message. Out of memory
  only; make the message's env with the lease.
* [Low] ERTS, `otp/erts/emulator/sys/erxos/erx_crash_area.c`: a fatal end reaches the crash area
  only through `erts_exit`, `ERTS_EXIT_AFTER_DUMP`, `ERTS_SYS_ABORT` and `erl_assert_error`; any
  other direct `abort()` in ERTS ends the domain as a fault with no slogan. Give `abort` an
  `only_` section of `imports.txt` held by the crash path, so every fatal end goes through it.
* [Low] time, the clock setter's chokepoint (`tools/lib/erx/chokepoint_rules/clock.rb`): it is a text check of five
  spellings, not the call-graph check [design-time.md](design-time.md) names; a variable function name gets past
  it. The QEMU "Set by hand" case sets 2026-11-16 12:30 UTC, where the design sets 2030, a time no boot reading near the
  host's date gives on erXos's kernel, whose PL031 starts at the host's time.
* [Medium] runtime, the device NIF: `erx_device_record` reads a given PCIe function's `-erx_record function`
  record ([design-pcie.md](design-pcie.md#the-catalogue-and-gives)) with its first placed BAR's window and an
  MSI-X route's message and table, checked to lie in that BAR, but nothing writes the table from it yet; have
  the NIF write it after the driver's reset, and give a driver a window per placed BAR when one needs more than
  BAR 0. A confined function's DMA window by its requester id
  waits for erXos's kernel, as every DMA window does.
* [Low] `otp/erts/emulator/beam/erl_proc_sig_queue.c` (`handle_cla`), reasoning only, not reproduced: if a process's
  message queue switches to off-heap between `handle_cla` answering `need_gc` and the literal collection, an on-heap
  message whose term refers to the literal area may be copied off heap with its literal pointers kept
  (`copy_struct_litopt`), and so outlive the area. Probe it as `test/fixtures/literal_token_probe.erl` probes the token.
* [Low] `test/integration/runtime_literal_token_test.rb`, intermittent: one run failed with
  `area_never_collected_in_time` and the next passed. The probe (`test/fixtures/literal_token_probe.erl`,
  `checked_round/1`) raises it when, in each of a round's five attempts, the receiver still found its message a
  shared literal, so the area's collection had not reached it and the round tested nothing. Each attempt waits only
  until the literal area collector reports idle (`wait_until_idle/1`); unverified: the collector may report idle
  before `persistent_term:erase/1`'s release of the area reaches it, which a slow or loaded host makes likelier.
  The probe has no way to see the area's own collection finish; one option is to retry an attempt until the
  message's `erts_debug:size_shared/1` is non-zero, under a deadline, instead of a fixed five times.
* [Medium] `otp/erts/emulator/beam/erl_process.c`, hosted runtime: `statistics_SUITE:scheduler_wall_time_all` fails
  where stock passes: under the case's full load one of 42 schedulers reports 0% wall time
  (`{badmatch, {true, [100,100,100,100,0,...]}}`), so one scheduler never ran the load or its wall-time counter
  missed it, perhaps a scheduler left parked in `erx_park`; `scheduler_SUITE` `few_low` and `equal_and_high_with_part_time_max` fail the same way (`low_min_ratio 0.0`).
  The system domain on QEMU's one CPU passes all three, so `emulator.txt` has no row for them.
* [Medium] `otp/erts/emulator/beam/erl_process.c` (scheduler wall time), system domain on QEMU HVF with one CPU:
  `statistics_SUITE:msb_scheduler_wall_time` fails at `true = 0.9 < WSU andalso WSU < 1.1` (line 542) where stock
  run with as many schedulers passes (WSU 0.99): with multi-scheduling blocked and ten low-priority hogs, the
  schedulers' weighted wall-time utilization is not about one busy thread. The hosted runtime's run shows no
  difference there. It was seen once, on a host running other QEMU guests and `make check-asan`
  (erxos-history `oracle-qemu/emulator/2026-11-07`), so it may depend on host load; if a quiet run passes it, its
  row in `emulator.txt` turns stale and fails `make check-oracle`, which then names it. The value is only in the
  guest's HTML case log, which the run does not print; print the case's `SU` and `WSU` lines, then trace whether
  the blocked schedulers' wall-time counters, the one CPU's other threads or host load cause it.
* [Medium] `tools/lib/erx/oracle_hosted.rb`, `test/oracle/hosted_known_differences/emulator.txt`: both erXos sides
  read one table (design-build.md), but the hosted runtime runs about 42 schedulers and the QEMU guest one, and
  stock runs as many as each, so some cases differ on one side only for that reason. `make check-oracle` holds the
  table to the guest; `tools/erx oracle hosted --suites emulator` then shows unlisted differences: the three bugs
  above, map_SUITE `t_tracing`, and scheduler_SUITE `scheduler_threads` and `poll_threads` and z_SUITE
  `node_container_refc_check`, which start a peer at many schedulers and skip or pass at one. Run the hosted side
  at the guest's scheduler count (`+S 1:1`), so both sides are the same configuration, or give a row the side it
  holds for.
* [Low] `otp/erts/emulator/beam/erl_port_task.c`: `port_SUITE:mon_port_bad_remote_on_local` fails: `erlang:monitor(port, P)` of a fake remote port does not raise the exception stock raises. Unexplained.
* [Low] `otp/erts/emulator/beam/erl_trace.c`, hosted runtime and system domain: `trace_call_count_SUITE:combo` fails in the
  `dynamic_pre_post` group only, with a `badmatch` on trace messages that include `erlang:trace_info/2`'s own
  call, `return_from` and `return_to`; the `legacy_pre_post` run of the same case passes. Unexplained.
* [Low] `test/oracle/common_test/test_server_ctrl.erl` (`file:set_cwd` in `run_test_case` and three other sites),
  `tools/lib/erx/oracle_suites.rb` (`ERXOS_LOG_CAP`): on erXos Common Test's logs have a RAM file system of their own
  (`/ct-logs`, 256 MiB), apart from `/tmp` where each `priv_dir` and `data_dir` is, so a suite that fills `/tmp` fails
  only its own cases. Suites still reach the log tree two ways: each case runs with its current directory set to the
  `ct_run.*` directory, as on stock, so a relative path a suite writes lands there (stock's kernel group leaves a 1.7 MB
  `hostnames_nodedir/erl_crash.dump`), and what a case prints goes to its case log (stock's heart_SUITE prints 144 MB
  into `node_start_soon_after_crash`'s). A group that writes or prints more than the cap there still stops the run.
  Moving the current directory to the suites' tree also needs Common Test's own relative writes found first
  (`start_log_file` writes `last_test.html` through `filename:absname/1`). The other way round, what a suite leaves on
  `/tmp` outside its `priv_dir` (files in its `data_dir` copy or straight in `/tmp`, or a `priv_dir` whose deletion
  failed, which is only noted) stays there, and once that fills `/tmp`, every later suite's job ends in
  `start_log_file`, where `filelib:ensure_path/1` cannot make its `priv_dir` (the hosted run answered `enoent`). Making
  a `priv_dir` that cannot be made fail only its suite would close that. And since the `priv_dir` is not below the
  case's current directory on erXos, as it is on stock, a suite that names its `priv_dir` relative to that directory
  (tar_SUITE:borderline strips the current directory's prefix) fails on erXos for that alone; moving the current
  directory into the `priv_dir` tree would close that too.
* [Medium] `tools/lib/erx/oracle_qemu.rb` (`command_line`): the guest's runtime still gets `-pa /lib/<app>/ebin`
  for the stock applications, which its code server also lists from `/lib`, as the hosted runtime's did. Check
  `code:get_path()` on the guest and drop the `-pa` words (`OracleHosted.erxos_command` is the model), and its
  code_SUITE `set_path`, `add_path` and `add_paths` cases.
* [Medium] `tools/lib/erx/oracle_comparison.rb` (`skipped_group_function`): a group function that erXos never
  recorded shows as `auto_skip`, inferred from the skipped cases under its group, and the report prints it like
  a status Common Test recorded. Give the inferred status its own name in the report and the table.
* [Medium] `test/oracle/hosted_known_differences/kernel.txt`, `emulator.txt`: their rows come from runs that booted the
  oracle's tree from OTP's `bootstrap/bin/start.boot`, whose kernel and stdlib versions (11.0.3, 8.0.4) are not the
  shipped ones (11.0.4, 8.1.1). The tree boots its own start_clean (`OracleHosted.write_boot_script`), and the
  compiler and stdlib tables and kernel.txt's rows for the suites before `sendfile_SUITE` are refreshed from runs
  that boot it. Rerun the emulator group and the kernel suites from `sendfile_SUITE` on (`seq_trace_SUITE`, the
  socket suites, `standard_error_SUITE`, `wrap_log_reader_SUITE`, `zlib_SUITE`, `zzz_SUITE`) and the group functions of `gen_tcp_socket_SUITE`,
  `interactive_shell_SUITE`, `net_SUITE` and `prim_net_SUITE` that an incomplete run leaves unresolved, and refresh
  their rows.
* [Medium] `tools/lib/erx/oracle_comparison.rb`: the tables of known differences cannot name a case whose stock
  result is not stable, so such a case fails `make check-oracle` in some runs. file_SUITE's bench cases
  `tiny_writes` and `tiny_reads` (524,288 one-byte calls each within a 60 s timetrap) failed on stock with
  `{timetrap_timeout,60000}` in `prim_file:write_1` and `read_1` in a kernel-group run on a host with load
  average 15 to 30, where erXos passed them (erxos-history `oracle-qemu/kernel/2026-11-07-whole`), and the sides
  agreed in an earlier run whose host load was not recorded (`oracle-qemu/2026-11-07-kernel-no-sendfile`).
  gen_tcp_misc_SUITE `bidirectional_traffic` below and statistics_SUITE `msb_scheduler_wall_time` above may be the
  same kind. Give the table a row that accepts either stock result for a named cause, or run the stock side's
  timing-bound cases on an idle host.
* [Medium] ERTS, process signals (`erl_bif_info.c` `ERTS_PI_IX_STATUS`): process_SUITE
  `process_info_status_handled_signal` failed once on erXos in a whole emulator-group QEMU run (HVF, one CPU,
  `+S 1:1`) with `{badmatch,[{status,running},{messages,[]}]}` at line 1332, where stock passed: the idle target
  answered `running` to a `[status, messages]` request, which ERTS reports only when the target, while it handles
  the request, is also active or has another signal or a non-priority system task pending. The branch carried no
  ERTS change near signals or scheduling. The earlier whole-group run passed it (erxos-history
  `oracle-qemu/emulator/2026-11-07`); process_SUITE alone passed it three times out of three, and a copy of the case
  that repeats its body 2,000 times in one run failed none on either side, so the pending work comes from what the
  earlier suites of the group leave running, not from the case. Not a known-differences row: the cause is
  unexplained. Rerun the whole emulator group with a diagnostic in the status branch that prints the target's
  `ACTIVE`, `SIG_Q`, `NMSG_SIG_IN_Q` and `SYS_TASKS` flags and the kind of the next pending signal or task, and
  find who sent it.
* [Low] `test/integration/runtime_prim_file_test.rb` (`build_fixture`): its tree boots OTP's `bootstrap/bin/start.boot`,
  whose kernel and stdlib specifications are the bootstrap's (11.0.3, 8.0.4), not the release's. The transcript it
  compares does not read them; boot it from `OracleHosted.write_boot_script` so no hosted tree carries them.
* [Medium] `otp/erts/preloaded/src/prim_file.erl` (`?ERX_FILE`), `erx_erofs_file`: prim_file forwards each open-file
  operation on a descriptor of `erx_file_remote` or `erx_erofs_file` to that module, but only the `/tmp` half is tested
  (`tmp_prim_file_handle` in `test/integration/prim_file_compare.erl`); the image half waits on a hosted EROFS mount (the
  `runtime_prim_file_test` item).
  `erx_erofs_file` has no `ipread_s32bu_p32bu/3` and no `copy/3`, so `prim_file:` and `file:ipread_s32bu_p32bu` and
  `file:copy` on an image descriptor raise `undef` (DETS lookups through `dets_utils` on an image); `prim_file:copy/3`, `get_handle/1` and
  `internal_get_nif_resource/1` do not forward. Make the two lists (the modules `open/2` returns, the operations that
  forward) one source, with a host check that each module exports every forwarded function.
* [Medium] `test/oracle/hosted_known_differences/kernel.txt`: kernel results that change with the run are unexplained. file_SUITE bench
  `tiny_writes` failed on stock and passed on erXos in the group run (stock's failure, not rerun). logger_std_h_SUITE
  `rotate_on_start_compressed`, whose row names a peer, failed on both sides of a rerun of selected suites with `undef`
  in file_SUITE's helpers, which that selection did not compile; its row's os_mon reason is read from the source.
  logger_disk_log_h_SUITE `sync`, `disk_log_full`, `disk_log_wrap`, `disk_log_events` and `op_switch_to_sync` failed on
  erXos in the group run and agree with stock when run with fewer suites; inet_res_SUITE's 8 lookup cases failed on
  erXos in the group run and auto_skip on both sides with fewer suites (their rows were deleted); gen_tcp_misc_SUITE
  `bidirectional_traffic` failed on stock in the group run and skips on both sides with fewer suites. A result that
  depends on which suites ran before it in the runtime may be an erXos bug. Rerun the whole group (the item on
  rerunning every group) and explain each. Reports: erxos-history `oracle-hosted/2026-11-06-kernel` and `2026-11-06-kernel-2`.
* [Low] `test/oracle/hosted_known_differences/kernel.txt`: stock's result of gen_tcp_misc_SUITE `bidirectional_traffic`
  varies between runs (failed, user_skip, passed; erxos-history `oracle-hosted/2026-11-06-kernel`, `2026-11-06-kernel-2`,
  `2026-11-06-kernel-boot`), while erXos skips it in every run that reaches it for want of a local address. Its row is stale whenever
  stock skips too. Find what decides stock's result on the development host.
* [Low] `test/oracle/hosted_known_differences/kernel.txt`: logger_disk_log_h_SUITE `sync`, `disk_log_full`,
  `disk_log_wrap`, `disk_log_events`, `op_switch_to_sync` and inet_res_SUITE's 8 lookup cases failed on erXos in a
  group run that booted OTP's bootstrap `start.boot` (erxos-history `oracle-hosted/2026-11-06-kernel`) and agree with
  stock in one run that boots the tree's start_clean (`2026-11-06-kernel-boot`); file_SUITE bench `tiny_writes`
  failed on stock once. No cause is established; if any recurs, trace it before giving it a row.
* [Medium] `tools/lib/erx/oracle_suites.rb` (`run_stock`), `test/oracle/hosted_known_differences/kernel.txt`: stock's
  distributed peers do not always start on the development host. In hosted kernel runs (erxos-history
  `oracle-hosted/2026-11-06-kernel-boot`, stock's `events.jsonl.gz`) init_SUITE `get_arguments`, `get_argument`, `boot_var`,
  `get_plain_arguments`, `dot_erlang`, `boot/boot1`, `boot/boot2`, logger_filters_SUITE `remote_gl` and every
  rpc_SUITE case that starts a peer failed with `timeout` from `peer:start_it`, and global_SUITE `names` skipped; in the QEMU kernel run
  of 2026-11-07 they all passed, but stock failed rpc_SUITE `call`, `block_call` and `async_call` with
  `{badrpc,nodedown}`, so those three are never compared. Where stock fails a case erXos cannot run, its exact row is
  reported stale. Find what stops stock's peers (host load is a guess), so stock gives a result for these cases.
  QEMU report: erxos-history `oracle-qemu/kernel/2026-11-07`.
* [Medium] `tools/lib/erx/oracle_comparison.rb`, `erx_oracle_events`: a row names a case and erXos's status, not why
  the case fails, so a `*` row accepts any failure of any case it covers. global_SUITE's `*` row (no distribution)
  would also accept a failure of `bad_input`, `otp_5737` or `re_register_name`, which pass on erXos and need no peer;
  heart_SUITE's, global_group_SUITE's and error_logger_warn_SUITE's rows are the same. Carry a failure class (such as
  `not_alive`, or `badarg` from `open_port`) in the case events and let a row name the class it expects, so a
  different failure is reported.
* [Medium] `tools/lib/erx/runtime_seam.rb`: `check_elf_objects` reads only the emulator's objects and six named libraries, unlike the hosted
  check, which reads the executable, so a library added only to the native link can import an unlisted name. Derive the list from the root's link input list (LLD's `--trace`).
* [Low] `test/fixtures/runtime_event_harness.c`: the sleep step's waker is a single-threaded model of `sched_set_park_flag` and the wake in `erl_process.c`, at fixed points, and the
  `scheduler_wait` exit test (`erx_event_leave_wait_ready`) pins the call by source text, so the real crossing of a scheduler and its waker is not run.
* [Low] `otp/erts/lib_src/Makefile.in`: `depend.mk` has no prerequisites and is made once per build copy, so a header that a lib_src source
  includes after that is no dependency of its object, and an edit to that header alone leaves the object stale. Use `-MMD -MP`.
* [Medium] `tools/lib/erx/runtime.rb` (`copy_sources`): `rsync -a` gives each copied source its time in `otp/` or
  build/gen, and make decides staleness from times, so a source whose new bytes carry a time older than its beam (an
  edit during a build, a file restored with `cp -p`, `tar` or `rsync -a`) is never recompiled, and the record, taken
  over the bytes, still says current. Copy with `rsync -rlpc`, so a file whose bytes changed gets the copy's time.
* [Medium] `tools/lib/erx/runtime.rb` (`build_application`): the build copy keeps each shipped application's
  `lib/<app>/ebin` from one build to the next, and OTP's beam rule (`otp/make/otp.mk.in`) names only the `.erl`, so a
  module of `otp/lib/*/src` that includes a generated header (none does) would keep its old beam over a change to
  that header alone, as would every module over a flags-only edit of its application's Makefile, while the record
  says current. The preloaded modules are compiled again on every build for this reason; for the applications, have
  erlc write dependency files (`+makedep`) that their makefiles include, or a build check, with its test, that refuses
  a `generated/` include under `otp/lib`.
* [Low] `otp/erts/preloaded/src`: the runtime build compiles the preloaded modules without OTP's
  `ERL_COMPILE_WARNINGS_AS_ERRORS=yes`, because the generated `erx_9p_grammar.erl` has no `-spec` for its documented
  request functions (`statfs_request/1` and others, from `tools/lib/erx/abi_emit_protocol.rb`). Emit the specs and pass it.
* [Low] `otp/lib`: OTP's source release ships some generated sources, which the import keeps: compiler's
  `beam_opcodes.erl`, `beam_opcodes.hrl`, `OPCODES-GENERATED` and `core_parse.erl`, stdlib's `erl_parse.erl` and
  `unicode_util.erl`, kernel's `inet_dns_record_adts.hrl`, tools' `xref_parser.erl` and each application's
  `src/deps/deps.mk`. Generate them in the runtime build from their inputs (`genop.tab`, the `.yrl` grammars,
  `uc_spec`) and delete them.
* [Low] `otp/erts/emulator/Makefile.in`: `erlang:system_info(compile_info)` answers `N/A` on erXos (edit 49 of
  `docs/design-runtime.md`), which no test pins until the oracle comparison runs.

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
  ([design-runtime.md](design-runtime.md#what-erts-imports)).
* [Medium] runtime, `tools/lib/erx/runtime.rb`: the build record covers neither the pack's own inputs (`tools/lib/erx/release.rb`, `pack*.rb`, `manifest.rb`, `config/platforms`, `config/provenance`) nor the archive's bytes, and is written before the pack runs, so a test run alone can read an older `system.pack`. Wants a release record written after the pack.
* [Medium] runtime, `liberx/backend/fiasco/runtime_entry.c`, `device_give`: the root's own give and the domain library's (`liberx/system/dom_apply.c`, `apply_give_step`, and `dom_args.c`, `args_given_words`) each build a device's objects and its `-erx_record given` record from the manifest row, and the register pages are computed three times (`erx_boot_device_window`, `dom_boot_view.c`'s `boot_pages`, the NIF's `erx_device_window_pages`); they agree today, but nothing compares them. Give the record one producer: build the root's records from the library's catalogue entries (a system give in the library, with the view built before the boot arguments), and keep one pure page function in a shared core header.
* [Medium] runtime, `liberx/backend/core/boot_manifest.c`: `peer_held` and `peer_held_total` stay zero on the page, and the projection is hand-written where the design generates it. No reader yet.
* [Medium] runtime, `liberx/backend/core/boot_info.c` and `liberx/system/dom_core.c`: a startup
  limit ERTS cannot keep (`processes` not a power of two or below 1,024, `atoms` below 8,192) is
  accepted by the manifest check and by domain creation and refused only when the domain's ERTS
  starts, through ERTS's usage text for the minimums. One C predicate used by the argv plan,
  `dom_limits_within` and the manifest reader would refuse it before anything is applied.
* [Medium] runtime, `otp/erts/emulator/beam/erl_init.c`: no test runs ERTS through
  `erx_runtime_settings_check`; the pure check is tested by `test/host/boot_info_test.rb` only.
  A hosted test (`beam ARCHIVE -P <twice the limit>` exits 1, `-SP 200:200` likewise, `-P <half>`
  starts) with a seeded wrong argument would cover the call.
* [Low] runtime, `otp/erts/lib_src/common/erl_misc_utils.c`: ERTS's own scheduler baseline is the
  cpuset's uncapped CPU count, so a relative `+S :M` or `+S -N` resolves against it rather than the
  plan's `-S`, and on a cpuset over 32 CPUs, or with capacity below the cpuset, a flag meant to
  lower a count is refused. Taking configured, online and quota from the plan's limits would let
  the leading `-S`/`-SDcpu` and `ProductionImage::Run.schedulers` go.
* [Low] runtime, `docs/design-runtime.md`, "Starting a runtime": a specification may lower `+t`
  below its own `foreign_atoms`; once `foreign_atoms` is enforced the lowering should be bounded by it.
* [Medium] runtime, `tools/fuzz/boot_manifest_fuzz.c`: the target compares the page with the reader's own result, so a swapped limit or a wrong host byte in `erx_boot_manifest_read` passes. Compare with `erx_manifest_open` and `erx_manifest_runtime_limits_at` called directly, field by field.
* [Low] runtime, `liberx/backend/fiasco/runtime_entry.c`: an `erx.arg` word of the kernel command line reaches ERTS's flag diagnostics unchecked, where the reader in `boot_manifest.c` holds `system_args` to printable ASCII. The command line is the operator's own.
* [Medium] runtime, `erlang/apps/erx/src/erx_device_record.erl`: `erx.arg` words of the kernel command line can spell `-erx_record device ...`, `-erx_record given ...` or `-erx_record function ...` and add a device record the manifest never assigned, which a driver opens like the root's own, or `-erx_record system_image ...` and so start the read-only `system` window in the system domain, against `check_system_window`; on Fiasco the command line is the operator's, but the manifest should stay the one source of which domain holds a device. Carry the records in a boot-information field only the root writes, or have the system domain's Erlang select them from the manifest through `erx_manifest`.
* [Medium] runtime, `erx_prim_file.c`: that a release file's bytes reach a read only after `erx_release_check` rests on `erx_copy_out` being ERTS's one user of `erx_release_addr`, with no build check. One call, `erx_release_open`, returning the bytes after the verdict with the cache inside `liberx`, removes the import and ERTS's flag, and Phase 2 then changes only what is behind it.
* [Low] runtime, `erx_prim_file.c`: a refused file is hashed and reported again at each open; `docs/design-kernel.md` has later uses fail at once.
* [Low] runtime, `liberx/backend/core/boot_manifest.c`: the printable rule for `system_args` lives in the reader, so `Manifest.admit` packs a manifest that then fails at boot, and `domains[].args`, the same string class, is not covered. The rule belongs in the `args` class of the ABI generator.
* [Low] runtime, `tools/fuzz/release_fuzz.c`: does not call `erx_release_check` or compare `erx_release_fs_lookup`'s index with the entry's, and has no seed at the longest path; its `fix_index` is a copy of `pack_fuzz.c`'s.
* [Medium] runtime, `erlang/apps/erx/src/erx_console.erl`: the `Ctrl-G` menu (`erx_console_menu`) lists, connects and detaches; interrupting and killing a session, lock and log out (`docs/design-live.md`, "Job control") come with logins (M10), and `erx:console_size/2` is not built.
* [Medium] runtime, `erlang/apps/erx/src/erx_console.erl`: a login's session that has had the line and keeps ending (a shell that dies at its first input) is started again without limit, a domain build each round; throttle it as FreeBSD's init throttles a getty that keeps failing, and say so on the line.
* [Medium] runtime, `erlang/apps/erx/src/erx_console.erl`: the login's life (`none`, `starting`, `{started, D}`, `{connected, D}`) moves in eight functions on five kinds of event, and only the session_domain QEMU suite covers it; make it a pure `login_next(Event, Login) -> {Login, Actions}` tested over every event in every state.
* [Low] runtime, `erlang/apps/erx/src/erx_console.erl`: a session whose console facet ends before its domain is dropped as ended, and the login started again is refused while the old domain lives; take only the domain pid's end as the session's, or stop the domain when its facet ends.
* [Low] runtime, `erlang/apps/erx/src/erx_console.erl`: at boot the system domain's command shell prints its banner and prompt at the UART before the login's session takes the line, so a person sees two banners. Hold the system shell's first draw until the login has started or failed.
* [Low] runtime, `erlang/apps/erx/src/erx_console.erl`: the console never sends `tty_hangup`, which ending a session from the menu or a log-out sends, and a repeated answer would carry.
* [Low] runtime, `otp/lib/kernel/src/prim_tty.erl`: `init_term/1`, the reader and the writer stay as stubs for `user_drv`'s stock paths, which `load/0` keeps unreachable; they go when `user_drv` itself leaves the release.
* [Low] runtime, `otp/lib/stdlib/src/io_ansi.erl`: with no terminfo a shell's `io_ansi` is plain text where stock on an xterm has colour. A fixed table of the ANSI sequences would answer it.
* [Medium] runtime, `otp/lib/stdlib/src/io_ansi.erl`: fix in erXos's OTP four upstream OTP 29.1.2 bugs in the ANSI fallback strings, which erXos always uses since it has no terminfo: `cursor_home` is `ESC H` (HTS, a tab stop) for `CSI H` (`:2614`); `scroll_forward` and `scroll_backward` are `ESC S` and `ESC T` for `CSI S` and `CSI T` (`:2646-2649`); `tab_backward` is `ESC I` for `CBT`, `CSI Z` (`:2684`); `hyperlink/2` writes the URI before the parameters, the reverse of OSC 8's `OSC 8 ; params ; URI ST` (`:2788-2790`). The fix lands with a test that each string is the standard form `erx_vt` implements ([design-display.md](design-display.md#the-terminal-emulator)), and is a documented difference from stock OTP for `make check-oracle`.
* [Low] runtime, `shell:start_interactive/0` calls `user_drv`, which does not run: it exits with `noproc` where stock answers `{error, already_started}`.
* [Medium] runtime, `otp/erts/emulator/sys/erxos/sys.c`: `kill -INT` runs the break menu while `erx_stdio`'s reader still reads standard input, so a key can go to either; on this port SIGINT should leave through the exit path. No test.
* [Medium] runtime, `erx_console.erl`: `get_terminal_state` reports standard input's answer for all three streams and `tty_geometry` answers 80 by 24 with no terminal, where stock asks each descriptor and refuses. A start failure of the driver loses its step and reason in `user_sup`'s ten-second wait, and `erx_stdio_nif.c` reports every IRQ failure as `eagain`.
* [Low] runtime, `tools/lib/erx/runtime_seam.rb`: the executable check drops an own list's names, so a library missing from the object list that calls them passes.
* [Low] runtime, `erx_stdio_nif.c`: a fatal signal or SIGKILL leaves the terminal raw; `start_nif`'s failure paths leave what they made; a stalled standard output delays input, which one process handles; and `SIGWINCH`'s `sigaction` skips `sys_signal`'s `SA_ONSTACK`.
* [Low] runtime, `standard_error.erl`: a failed write crashes the server with no log, which a later `set_unicode_state` carries into `erx_console`.
* [Medium] runtime, `erlang/apps/erx/src/erx_console.erl`: nothing restarts the system console. `user_sup` starts it
  with `gen_server:start/4` (`erx_console.erl:212`) as the child `user` of `kernel_sup`, which is `temporary`
  (`otp/lib/kernel/src/kernel.erl:163-168`) and never restarted, so its crash leaves the machine without a console,
  while [design-live.md](design-live.md#failure-handling-diagnostics-and-debuggability) has the console restarted by its supervisor
  with every line showing a login. Give the console a supervisor that restarts it, with a test that kills it and
  finds a login prompt on the line.
* [Medium] runtime, `erlang/apps/erx/src/erx_console.erl` `init/1`: the console starts its driver (line 349) before its
  first `erx_log:take/0`, which waits for the first `erx_log_poll`, `LOG_POLL_MS` later (line 358), so for that time
  the root still writes records on the UART while the driver writes it too, and their bytes can interleave on the
  line. [design-fiasco.md](design-fiasco.md#the-console) puts the first take before the driver's first touch
  of a register, and [design-log.md](design-log.md#the-kernels-records) has the log service make it in its
  `init`, before `user_sup` starts the console. Until then, take once before `Start(self())`, with a test that the
  `l4_vcon_write` counter on Fiasco stays still once the driver has started.
* [Medium] runtime, `erlang/apps/erx/src/erx_console.erl`: a restarted system console reaches none of the sessions
  its predecessor knew. Each session's tty holds a console facet minted in front of the old console's facet endpoint,
  which ends with that console, as do its table of sessions and their masters, so the sessions run on unreachable,
  the login's session keeps its principal's domain quota, and the restarted console logs no one in: the line shows
  the system's command shell, and `erx_console:login_session/0` answers `none`, so `erx_hostlink_web` finds no root
  line. [design-live.md](design-live.md#failure-handling-diagnostics-and-debuggability) has the line show a
  login after a restart and the sessions reachable by it. Give the endpoint and the session table a life beyond one
  console, or have the domain service hand a restarted console the live sessions and their ttys name themselves
  again, which meets the master reset of a restarted relay ("Console and a restarted relay").
* [Medium] runtime, `user` across a console restart (`otp/erts/preloaded/src/init.erl`, `erx_console_sup.erl`): an
  io request that reaches `user` while none is registered (between the old console's end and the new one's
  `start_user/1`, or for good once `erx_console_sup` gives up) goes to init, which drops it with a log line holding
  its text, and one sent to the old `user` after its driver ended is never answered; either way the caller, which
  monitors only its group leader (an application master, alive), waits for ever. Processes that still hold the old
  `user`'s pid as their group leader (those `-s`, `-run` and `-eval` start, which `init:start_em/1` gives it, and
  `error_logger_tty_h`) get `{error, terminated}`. Have init answer an io request it cannot forward with an error,
  as an io server that has ended would.
* [Medium] runtime, `liberx/backend/fiasco`: the native root does not read the release's manifest: its page takes
  `erx.arg=WORD` alone, with `system_args`, `limits`, `pack_flags` and `release_addr` empty, and no archive holds
  a native root with these release files. `liberx/backend/core/boot_manifest.c` is the reader to link, and
  `Erx::Release.differences` the comparison `test/integration/runtime_release_test.rb` runs over two hosted packs
  until then.
* [Low] runtime, EROFS mounts: `erx_erofs_file` opens no directory (`[directory]` answers `enotsup`) and
  exports no `copy/3` or `ipread_s32bu_p32bu/3`, so `file:copy/3` from an image's open file and
  `disk_log`'s positioned reads of one fail; `set_cwd` on an image checks no search bit; every image
  reports device 0, so two images' files can share a device and inode pair; and `erx_ns` monitors no
  image's window, so a window pid the runtime later gives another process would receive the image's
  reads. No test.
* [Medium] runtime, `erx_ns`: an image's mount reads the image in `erx_ns`'s own process, so a window
  behind the image it is handed that does not answer holds every mount, bind and unmount of the
  domain for up to 40 s a read (three reads a mount); the mount belongs in a monitored worker whose
  result the process applies once it checks the point again. No test.
* [Medium] runtime, `erx_verity`: it caches no checked tree block, so each read
  fetches its tree path again, and the reader keeps no ETS table
  of 256 metadata blocks per image ([design-storage.md](design-storage.md#reading-erofs-images)
  step 4), so every lookup reads its inode and directory blocks again; a log of a failed read goes only
  to the reader's mount log function.
* [Low] runtime, `erx_erofs`: the superblock's CRC-32C is computed bit by bit in Erlang, not by the
  per-byte primitive `erx_bytes:crc32c/2`: the reader's EUnit cases and fuzz target run it on stock
  OTP, which has no `erx_bytes` BIFs, so moving it needs an Erlang stand-in for those runs (at boot
  only `erx_storage_system` mounts an image, on erXos's ERTS, which has the primitive). The reader's form
  is Linux's, seeded with all ones and not inverted at the end, so over the covered bytes it is
  `erx_bytes:crc32c(0, Covered) bxor 16#FFFFFFFF`. Device, FIFO and socket inodes answer `enotsup`, which the
  packer's trees never hold.
* [Low] runtime, `erx_erofs`: a walk that fails inside an operation (`eio`, `enotsup`, `enametoolong`) answers
  `{[], Error}`, dropping the kinds it passed, so `erx_path` places the error at the first name; a superblock
  claiming more blocks than the window holds fails later as a read failure, not at mount as malformed; the
  fixtures give every entry one mode and one time (the manifest's modes 0644 and 0755 and time 0), and only
  `extended.img` varies the owner (uid and gid 70000), so no case checks the mode-bit and mtime offsets
  with other values; fsimg's manifests can write them.
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
* [Low] runtime, `erx_file_remote`: `list_dir` of a directory on a grant lists only the server's entries,
  not the mount points directly below it ([Resolving a path](design-files.md#resolving-a-path),
  listings across mounts), which needs the namespace's table from the NIF.
* [Low] runtime, `erx_file_remote`: `#file_info.major_device` is a hash of the grant's pid and tree where the
  design has a number the namespace gives each mounted tree; two trees can collide.
* [Low] runtime, `otp/erts/preloaded/src/prim_file.erl`: `delete/1` answers every `einval` as `eperm`, a
  server's answer to `unlinkat` included, where FreeBSD's `kern_funlinkat` turns only `namei`'s `EINVAL`
  and lets `VOP_REMOVE`'s stand ([Errors](design-files.md#erlang-clients-prim_file-and-erx_file_remote),
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
  [design-files.md](design-files.md#interfaces) are not written.
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
* [Medium] runtime, the native boot page: the comparison of the two entries' pages waits for a native release that boots, and so does the range check on `limits`, of which `erx_boot_info_build` and `erx_boot_info_read` check only the reserved word ([design-fiasco.md](design-fiasco.md#boot-information)).
* [Medium] runtime, the log sink (`erlang/apps/erx/src/erx_log_h.erl`, `erlang/apps/erx/src/erx_syslog.erl`): no overload protection. `logger_std_h`, which `erx_log_h` replaces, runs `logger_olp`'s sync, drop and flush modes; `log/2` sends unconditionally, so a flood of events (a crash loop with large reports) grows `erx_syslog`'s queue in the system domain, ahead of the domains' writes, and the proxy's elsewhere. A queue-length check in `log/2` that drops and counts past a bound, or `logger_olp`, would bound both ([todo-performance.md](todo-performance.md)).
* [Medium] runtime, the log sink (`otp/lib/kernel/src/logger.erl` `log_remote`, the default `remote_gl` filter): an event of a process whose group leader is in another domain, such as one an rpc from the system shell spawned, is sent to `{logger_proxy, Node}` on the group leader's node, which never leaves the domain (edit 27), and the local default handler's `remote_gl` filter drops it, so it reaches no sink. A domain's events are its own: drop the forward and the filter in erXos, after checking which OTP suites depend on them.
* [Low] runtime, `otp/lib/kernel/src/logger.erl`: with edit 57 the `default` handler is `erx_log_h`, so OTP's logger suites that expect `logger_std_h` there (`logger_env_var_SUITE` among them) are expected to differ from stock; `make check-oracle` has not run with the edit, and `test/oracle/hosted_known_differences/kernel.txt` wants the cases it finds.
* [Low] runtime, `erlang/apps/erx/src/erx_console.erl` `system_source/0`: the system domain's principal (1) and name (`system`) are written by hand, as `erx_kernel_records` writes its id; the domain service's table should give all three.
* [Medium] runtime, a domain's standard I/O (`otp/lib/kernel/src/user_sup.erl`): a domain has no tty yet, and `-noshell` or `-noinput` start `user_drv`, whose `prim_tty` NIF is gone, so a domain started with them fails at `user`; `native_domain`'s ERTS domain starts with `-nouser` and writes with `erlang:display`. A domain with a user will also need `erx_shell` in its release (`erx.app.src`), beyond `ReleaseFiles::DOMAIN_BASE`. A domain's groups and tty ([design-live.md](design-live.md#the-tty)) replace that.
* [Medium] runtime, `otp/lib/kernel/src/dist_util.erl`: `gen_challenge/0` calls `statistics(runtime)`, which fails with `notsup`, so a distribution handshake ends there. No `1>` reaches it; the first carrier does.
* [Low] runtime, `liberx/backend/hosted/start.c`: six names of the host's environment reach the page for the stock fd, spawn and forker ports and the stock terminal driver, where the design's page holds none. They go with those layers. The forker exits when `BINDIR` is unset and runs `erl_child_setup` from that host directory, so a boot is not yet free of host files.
* [Low] runtime, `beam/erl_time_sup.c`: edit 20 of the design is open. The stock correction runs over `erx_clock_ns`, and stays idle since system time moves with it by one offset; deleting it changes nothing a shell sees.
* [Low] runtime, `otp/erts/emulator/sys/erxos/sys_time.c`: `os_monotonic_time_source` and `os_system_time_source` report the nanosecond unit as the resolution, where macOS's clock ticks by the microsecond; a backend call for the granularity would make it true.
* [Low] runtime, `otp/lib/tools`, `otp/erts/etc`, `otp/erts/start_scripts`: not buildable from the imported
  tree (`ei.h`, `lib/os_mon/vsn.mk`). The runtime does not need them; `lib/tools` is to ship
  or leave the import when the release's application list is settled.
* [Medium] Runtime, export table, `erx_exports.c`: what the table does not do yet.
  (1) The spawner's boot exports (`spawn` on the domain, `send` on init) are not written:
  the boot page names no spawner, only the system domain. (2) A holder of a connection that
  has ended holds nothing, but keeps its entry, counted against the bound, until its name
  ends or the next write for that peer on the name replaces it; a long-lived process handed
  to many peers that have since ended keeps their entries. Drop them at the next write to
  the set, or at the connection's end. (3) The bound is the constant 16,384, not a manifest or
  `-erx exports` value. (4) The hold's `request_words` is 0 until edit 12 (RT8). (5)
  `ERX_FUNNEL_DELIVER_IF_LINKED` is answered `noproc`, which is wrong when the target already
  holds a link with the sender (one a process of this domain made toward the peer's
  process): the peer's process then gets an exit of `noproc` for a live link; it needs a link
  record the input task can read.
* [Medium] Runtime, the system domain's queue to a domain (edit 10 of design-runtime.md,
  `otp/erts/emulator/beam/dist.c` `erts_dsig_prepare` and `erts_dsig_send`): not built.
  `system_queue` is read by the manifest tools only, and a system process that sends to a
  domain whose connection is busy is suspended like any sender (the suspend on
  `ERTS_DE_QFLG_BUSY` in `erts_dsig_send`), so a domain that stops draining can stall a
  system service. The domain pid (`erx_domain_pid:send_or_stop/5`) sends with `nosuspend`,
  so a busy connection refuses its message instead, and `erx_code` does the same from
  package 2 of todo-domains.md's "start loads to supervised domains" (design-live.md, "The
  effect layer"); the other system processes that send to domains have not been checked.
  The edit needs no change in those two: a system domain that suspends no sender refuses
  no `nosuspend` send.
* [Medium] Runtime, export table, `erl_process.c` `erl_create_process` and
  `erx_exports_spawned`: a spawn from another domain when the table is full still creates
  the child, and `erx_exports_spawned` only counts the full answer, so the spawner holds nothing
  on it. Its exit toward the child is unheld, so the parent's death never ends a
  `spawn_link`ed child, and the parent gets a pid it cannot message. Refuse the spawn with
  `system_limit` in the `SPAWN_REPLY`, or reserve the entry before the child is made.
* [Medium] Runtime, export table, `erx_exports.c` `EXPORTS_MAX` and `live`: one bound for
  every peer, so a peer that can make this domain create processes or hand out new pids
  (a spawn, or a server that starts a worker per request and answers from it) fills the
  16,384 entries for all of them, and pids handed to the system domain afterwards behave
  as dead. design-domains says a domain that fills its table hurts only its own
  correspondence. Needs a quota per peer within the bound.
* [Medium] Runtime, export table, `erx_exports.c` `EXPORTS_MAX`: pids and handed-out
  aliases share the 16,384 entries, so a domain holding many handed-out names leaves no
  room for the alias of its next cross-domain `gen_server:call`, and that call times out,
  its reply reaching no one (design-runtime, "Representation and aliases"), however few
  aliases the domain itself has active. A quota per peer (the item above) bounds what one peer
  can make it hold; a separate bound for aliases would only move the limit.
* [Low] Runtime, alias registry, `erl_monitor_link.c` `erts_monotor_tree_lookup_insert` (stock
  OTP's spelling): it does not keep the registry, and it has no caller; delete it, or hook it
  as the tree's insert is. `erts_monitor_tree_replace` keeps it: its callers (`bif.c`,
  `erl_proc_sig_queue.c`) move an alias state to a monitor of the same key and owner, or
  swap node monitors, which hold no alias; an ASSERT there that key and alias state match
  would keep it so.
* [Medium] Runtime, references, `erl_bif_unique.c` `erts_sched_make_ref_in_array`: each
  source is used by its own thread only because every caller passes the calling thread's
  esdp, and a dirty scheduler's `thr_id` gets its offset only in
  `sched_dirty_*_thread_func` (`erl_process.c`), so a call before it, or with another
  thread's esdp, draws from another thread's source. Make it hold by construction: write
  the final `thr_id` once in `init_scheduler_data`, and read the scheduler data from
  thread-local storage instead of an argument.
* [Low] Runtime, export table, `erx_exports.c` `holder_add` and `erx_exports_close`: `live`
  is incremented before the bound check and rolled back after, and a close subtracts only
  after unlocking, so a hand-out racing them near the bound is refused, and counted, while
  the table has room. Refuse at the bound with a compare-and-swap that never overshoots,
  and subtract under the lock.
* [Low] Runtime, alias registry and reference comparison, `erx_alias.c` `entry_cmp` and
  ERTS's reference compares: words a peer sends are compared with live identities by
  `sys_memcmp` and word by word, which may stop at the first differing byte. The timing
  says how many leading bytes of a guess match a live identity in the same bucket; a
  constant-time compare of the four words removes the question.
* [Medium] Runtime and domain service, introduced connections, QEMU cases still to write
  (`tools/lib/erx/system_domain.rb`): design-domains' delayed-ready case (a domain whose init
  delays its ready report while its creator writes a spawn request into their connection, with
  the seeded domain service that hands the domain pid the record before the report) and
  introduce's `system_limit` refusal run on the host only (`erx_domain_tests`). Both need a
  third domain created at run time, which the suite cannot make cheaply: its two configured
  domains, 160 MiB each (`MediumBoot::DOMAIN_MEMORY`), fill the medium machine
  (`MediumBoot::MACHINE`, 768 MiB, room for two), and init sends its report before any `-eval`
  (edit 65), so nothing delays it. Grow the machine or shrink the domains, give the suite an
  `erx_domain:create/1` of a third domain, and give the delayed case a way to hold the report.
* [Medium] Runtime, `erx_connections.erl` `records/3`: the agent serves every record in
  turn and waits inside a finish, which may pause on a process of the domain at its queue
  quota (design-runtime, "Closing"), the agent itself included when a peer handed its pid
  floods it, so one paused finish holds the domain's answers about every other peer, and
  with them those connections' objects and quota. No queue quota is set by default, so
  nothing pauses yet; before edit 15 lands, exempt the agent from the quota or make the
  finish asynchronous (a finishing phase in `Held`, `erx_lane_finished` and the `DOWN`
  matched in `records/3`). The test hold (control command 4) can also be set again during
  a finish, which then never ends; refuse it on a finishing port.
* [Low] ERTS distribution (`beam/dist.c`, `beam/erl_process.c`): where `erts_link_dist_insert` fails (dist.c's DOP_LINK and spawn paths, a remote spawn's link in `erl_process.c`), the link's `dist` stays NULL and `erts_proc_sig_send_link_exit_noconnection` dereferences it; stock, and thought unreachable on erXos, whose lane port holds the port lock across input and `erts_do_net_exits`, but not traced on every input path.
* [Low] OTP kernel, `global_group` (edit 64 of design-runtime): `continue_handle_info/2`'s config-check `DOWN` takes `noconnection` as no contact and every other reason as a sync error, so with `global_groups` configured a domain's end, `{domain_down, D, Info}` (edit 56), puts the node in `sync_error`; erXos configures no global groups, but the guard is one line.
* [Low] Runtime, `otp/erts/emulator/beam/bif.c` (`list_to_ref_1`): report the upstream bug to OTP. In stock
  OTP 29.1.2, a reference text whose six numbers each end in `.` (`"#Ref<4.1.2.3.4.5.>"`) leaves the parse loop
  with `i` at 6, so the copy into `refn` reads `ints[6]` past its six entries and writes `refn[5]` past its five:
  a stack overflow on any text a caller passes to `list_to_ref/1`. erXos's copy refuses that text with `badarg`
  (edit 18; native_domain's connection case checks it).
* [Low] Runtime, `net_adm:ping/1` (edit 28) decides by `erx_dist:select/1` whether
  the carrier is in use; a node of this kernel under another `-proto_dist` answers
  `pang` for an unconnected node at its own host without trying.
* [Medium] Runtime and domain service, `erx_connections.erl` (`close/2`),
  `erx_domain_srv.erl` (`ended/3`): the agent answers `close_side`, and a domain's agent
  answers `connection_unmapped` and `connection_lost` (`records/3`), on the port monitor's
  `DOWN`, which ERTS fires (`erts_deliver_port_exit`, `io.c`) before `terminate_port` calls
  the lane driver's stop, so when the exit ran on another scheduler the domain service's
  `Lib:disconnect` can destroy the connection's objects before `lane_stop` has released the
  answering domain's mappings of them. No driver callback runs in that window. Whether the
  Fiasco backend's destroy also removes the system domain's mapping was not checked; if it
  does not, the pages can be reused while still mapped. Make the unmap the signal: the
  finish (control command 2) or a synchronous close unmaps both sides before it answers.
* [Low] Runtime, `erx_event_table.h`: the system domain binds one connection sink per
  live domain, at most `ERX_EVENT_CONNECTIONS` (64), and nothing ties the manifest's
  `max_domains` to it, so creates past it, or earlier while slots stay unsettled, fail
  with `{system_side, _}`. Bound `max_domains` in the manifest reader, or size the sinks
  from the manifest.
* [Low] Runtime, `erx_dist.erl` (the system connection's owner): a domain's own ordered
  end, `init:stop()`, shuts `net_kernel` down, which takes the system connection's owner
  with it, and the owner halts the domain with status 69 rather than 0. Let the owner
  follow an ordered stop of `net_kernel` quietly, as `erx_connections` does, or have the
  domain's ordered end halt with its own status first.
* [Medium] Runtime, `erx_connections.erl` (`kernel_ended/1`): the agent ends quietly on
  any `shutdown` of `net_kernel`, which is safe only while `net_sup` and `kernel_sup` stay
  `one_for_all` with intensity 0: a local `supervisor:terminate_child` of `net_sup` or
  `net_kernel` with no restart leaves the runtime running with no agent, and in the
  system domain no side reports reach the domain service. Make it hold by construction:
  quiet only when the runtime's ordered end is under way (a mark written on that path),
  halt otherwise. erx_dist's owner follows net_kernel's shutdown the same way
  (`erx_dist:exited/4`) and shares the gap. Also tighten `{system_side_ended, Id, Reason}`,
  which any local process can send
  to the service: carry the side's monitor reference, or check the sender is the agent.
* [Medium] runtime, `erts_internal_dist_spawn_request_4` in `otp/erts/emulator/beam/dist.c`:
  design-domains.md ("The funnel", step 4) has the sender's peer check a spawn request's
  control term with the funnel's grammar before writing it, answering an option of another
  shape with `badopt` and a term past `ERX_CTL_MAX` with `system_limit`; no such check
  exists, so such a spawn toward another domain is written, refused there as malformed,
  and ends the caller's own connection.
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
  ([design-runtime.md](design-runtime.md#unguessable-references),
  [design-platforms.md](design-platforms.md)).
* [Medium] runtime, the reference permutation's hardware path:
  `erx_ref_permute` (`otp/erts/emulator/sys/erxos/erx_ref.c`) is ctaes's
  portable AES-128 alone. Write the hardware path the design names (the
  Arm cryptography extension's AES instructions where the CPU has them),
  settle how a user-mode runtime learns that the CPU has them, test it
  against the portable path over `test/host/erx_ref_test.rb`'s vectors,
  and record both paths with `tools/erx bench erts-local`
  ([design-runtime.md](design-runtime.md#unguessable-references)).
* [Medium] runtime and live, standard I/O across domains: every other
  domain's standard I/O goes through Erlang's I/O protocol to a group
  leader in the system domain, whose requests carry the writing domain's
  atoms, which D5 refuses. State which requests cross, with their text
  rendered to binaries in the writing domain, as trace records are
  rendered in the traced domain
  ([design-runtime.md](design-runtime.md#the-console-and-standard-io),
  [design-live.md](design-live.md#tracing)).
* [Low] runtime, dirty I/O threads: every Erlang domain gets ERTS's
  default of ten idle dirty I/O schedulers. Size the default for a domain
  of a few megabytes, or start them lazily
  ([design-runtime.md](design-runtime.md#scheduling)).
* [Low] runtime, the text of other machines' pids: a pid of another
  machine's node prints with a creation that can equal one of this
  machine's domain ids. The design recommends keeping the one rule,
  resolving `list_to_pid` to this machine's domain on a collision, and
  showing a pid's node name beside its text in the inspector; the user
  decides
  ([design-runtime.md](design-runtime.md#risks-and-open-questions)).
* [Medium] time, ntpd (`erlang/apps/erx_ntpd`, [design-time.md](design-time.md#the-client)): the client
  runs as the design's schedule says, with these left out: (1) the start table carries no row `flags`
  ([design-apps.md](design-apps.md#start-flags)), so the Raspberry Pi 4 manifest's ntpd session template
  sets `ERX_START_FLAGS` in its own environment, and the boot view's refusal of such a template waits for the row
  field; when the start table's settings file carries `flags`, move the value to the row and add the refusal;
  (2) re-resolution waits the doubled interval because `inet:getaddrs/3` answers no TTL; a
  resolver call that answers TTLs lets it wait the shortest TTL instead; (3) the QEMU suites check held then
  stepped (net_device, against the harness 300 s ahead of a clock the PL031 keeper set) but not the cases
  restart, kiss and refusals of design-time.md's verification, nor a cold boot's first-sample step, which QEMU
  virt's real-time clock prevents; (4) `ntpctl` (erlang/apps/erx_shell/src/erx_cmd_ntpctl.erl):
  `-erx_needs([inspect, net])` asks for `net` on the forms that read no network; when every address fails,
  `ntpctl step HOST` gives no reason per address;
  the name rule passes short IPv4 forms such as `1.2.3` to `inet:getaddrs/3`, which reads them as addresses;
  (5) review findings left: the clock facet call is written in both erx_ntpd and erx_cmd_date; the
  core is a one-action loop, not the events and `next_deadline/1` shape "Who does what" describes; `step_from` names every `set` `root`, which
  holds only while root's template alone holds the clock's `set` (derive the kind from the grant row or name the
  check); the net_device suite's ntpd rows (`NetDevice::NTPD`) copy raspi4b-development.txt's (derive them
  through Manifest::Edit); erx_ntp_records and erx_time_records each map a missed answer to schema statuses
  their own way (one helper).
* [Low] time, ntpd's schedule (`erlang/apps/erx_ntpd/src/erx_ntp_core.erl`,
  [design-time.md](design-time.md#schedule)): a run whose servers are IPv4 literals, or names the
  hosts file holds, polls before the network has an address, so its quick rounds end and a network that
  gets its address later is found only after the poll backoff, 128 s at first. The schedule watches no
  network event; connecting it to the network domain's address changes would remove the quick rounds too.
* [Medium] time, setting the clock by hand (`erlang/apps/erx/src/erx_clock.erl`,
  [design-time.md](design-time.md#setting-the-clock-by-hand)): root's session sets the clock with `date`
  through its `root_clock` grant (`operations set`), `erx_clock_facet` and the clock service; what is left:
  a set's log line names the domain, not the grant's principal as the
  design says; in the system domain's own shell a set answers `eagain`, since that shell holds the service
  itself (`erx_cmd_date:request/2`, `local`); a session of a template without the row is checked for `eperm` on
  the host only, as the development manifest has no other session template. `date`'s `%N` pass runs inside the
  strftime scan, not before it as `date.c`'s `strftime_ns` does, so formats such as `%E%N` and `%5%N` differ
  from FreeBSD; make it a format-to-format step first. Add a FreeBSD oracle case for `date -j -u` over the
  operand and format corpus, which settles the `mktime(3)` normalization design-time.md marks unverified.
* [Medium] time, the wall-clock keeper (`docs/design-header-io.md`, "An I2C real-time clock, for the wall clock without a network"): the header design
  says "the system domain's wall-clock keeper, designed with network time, reads `/dev/rtc/time` at boot and writes
  it after each correction", and [design-time.md](design-time.md#the-real-time-clock-at-boot) designs the keeper
  for QEMU `virt`'s PL031 (`erx_rtc_pl031`, a reading at boot sent as `{rtc, Source, Wall}`), but not its `/dev/rtc`
  source, so nothing sets the wall clock from the Pi's clock module. HTTPS clients refuse every certificate on an unset
  clock ([design-crypto.md](design-crypto.md#time)). Design its `/dev/rtc` source in design-time.md: when the keeper reads it, since the devices domain starts after the system domain; how the clock service
  takes the RTC's reading at boot, how it ranks it against network time, and when it writes the RTC.
* [Medium] time, the PL031 keeper (`erlang/apps/erx_rtc/src/erx_rtc_pl031.erl`, `erx_clock_core:decide/4`'s `rtc`
  clause, [design-time.md](design-time.md#the-real-time-clock-at-boot)): a reading leaves the clock `set`, so
  ntpd refuses a later error of 1000 s or more `panic` and only root's `date` corrects a real-time clock that reads
  far wrong. A reading should leave the clock `boot`, cold for ntpd's first sample and distinct from root's `date`,
  but `state` is the time page's (`erx_clock_core:state/2`, which `/proc`'s collector calls in any runtime), and
  on Fiasco the keeper's step moves the page's `seq` as every set does, so nothing in the page tells it from a set;
  the page must carry the state its setter wrote, a change to `erx_time_set_offset` and the page's layout, which
  also tells the approximate start's one write from a set. Also open: the step uses the monotonic time at which erx_clock reads the page, not that of the
  register read, so a reading that waits in erx_clock's queue lands late by the wait (send the read's monotonic
  time with it); the keeper reads at boot synchronously in erx_rtc_sup's init, so an erx_clock that hangs delays the boot
  by up to 10 s.
* [Medium] Runtime, an interpreted receive skips priority messages that arrive while its match runs
  (`otp/erts/emulator/beam/erl_proc_sig_queue.c`, `msgq_finish`, edit 78): `msgq_hand_out` leaves the save pointer at the
  first message, so a priority message inserted meanwhile gets no continuation marker, and the walk back to the held
  message passes it without matching it; the receive then waits for its timeout although a matching message is queued.
  Only a process that made a priority alias receives such messages. Fix: restart from the first message when the
  priority region gained messages since the hand-out, or hold the position so the stock insertion logic applies.
* [Medium] Runtime, the `msgq-length` source check (`tools/lib/erx/chokepoint_rules/msgq.rb`, edit 78) permits its
  lines by text, so a copy of `c_p->sig_qs.mq_len--;` elsewhere in `erl_proc_sig_queue.h`, or of
  `p->sig_qs.mq_len = 0;` elsewhere in `erl_process.c` (where exit code could empty a live queue and free its messages
  past `erts_msgq_count_removed`), passes; and it reads no `.tab` file, so a decrement in `emu/msg_instrs.tab`, where
  the interpreter's `remove_message` lives, passes too. Fix: let a site permit a line at most N times per file (or fold
  the two zero-initializations into one helper), and refuse any `mq_len` in a `.tab` file (none names it).
* [Low] Runtime, upstream: `erts_resume_paused_proc_timer` (`otp/erts/emulator/beam/erl_hl_timer.c`) restores an
  expired paused timer with `erts_set_proc_timer_uword(c_p, 0)`, which sets `F_TIMO`, the after-infinity state, so a
  receive whose timer expired while the debugger paused it waits forever. Unverified by a test.
  counts (the system principal's memory, `root_memory`) in both board parts.
* [Medium] Runtime, an interpreted receive whose match runs a receive of its own (`otp/erts/preloaded/src/prim_eval.S`,
  `erl_eval:receive_clauses/8`): the match fun runs inside `loop_rec`, and a nested receive (erl_eval loading
  `eval_bits` through the code server on its first binary pattern) moves the queue's save pointer to the first
  message, so when the match then succeeds, `remove_message` removes the queue's first message, not the one
  matched, whenever earlier messages did not match: one message is lost and the matched one is matched again.
  Upstream OTP 29.1.2 behaves the same. The message the match sees is a heap copy, so memory stays sound; a fix
  needs `prim_eval` to remove the message it handed out (a marker or a removal by position), not whatever the save
  pointer names.
* [High] Device NIF, every descriptor form against the DMA check (`erx_device_dma.c`,
  `erx_device_genet.c`, `erx_device.c`): the cores store raw ring fields, place their own records
  and state their own writers, while [The check](design-device-dma.md#the-check) has each core describe records
  by meaning, fields and names, and the sequencer write them, make each run live, and end what the device holds only
  by its reports, which it acquires itself (the validity, then the records it covers), against one ledger. The TRB form's tables, bindings and releases are in
  [design-usb.md](design-usb.md#what-the-dma-check-judges). Until then the TRB form's plans cannot run through
  `run_call`. The formats' marks are in `abi/formats` (virtio, xHCI, and SDHCI's ADMA2 entry), and the encoders and
  each structure's meaning list generated from them in `include/erx/abi.h`, which nothing uses yet. Every
  device address in `abi/formats` carries `device_address`, and a marked layout refuses one a description would
  state or the format fix; a device address in an unmarked layout is not refused yet: that rule turns on when the
  last form moves onto the encoders. The sequencer encodes virtio-gpu's region entry, `erx_virtio_gpu_mem_entry`, from a fill that
  names a persistent region its ledger holds; `erx_device.c` adds each region to its device's queue ledgers. The ADMA2 entry's encoder accepts a length of 0, which moves 65,536 bytes; the
  sequencer's split never derives one, and the package that writes the split tests it. The encoders are public in
  `include/erx/abi.h`, beside every layout's generic setters; they end up confined to the sequencer (a private header), and the chokepoint of
  [Descriptions](design-device-dma.md#descriptions), that only the sequencer stores into a region holding a
  structure, is the build check `device-record-encoders`, which names the descriptor formats' layout prefixes rather
  than deriving the encoders from the marks, and covers the encoders but not yet the generic setters. The ledger, the queue's layout, descriptions, the publication rules and the
  sequencer's publication and acquisition for the split ring are in `erx_device_ledger.c`, `erx_device_rules.c` and
  `erx_device_sequencer.c`, and `erx_device.c`'s split ring installs, posts and completes through them. Left in `erx_device.c` by the
split ring's wiring:
`queue_broken`, `break_queue`, `form_round` and `run_call` read `record->genet` from the queue union unchecked
(right only because every split-ring path returns before them), so they should take a `register_ring_t`, with
the record's `context` and `state`, which only GENET uses, moved into it; `queue_bytes`'s ring bytes, always 0,
`pool_offset`, the record's `ready` beside the ring's `installed`, and the comments that still describe one
effect layer for both forms; the completion's used index located by `offsetof` rather than handed over by the
core as its elements are; the activation store copied into a `uint64_t` while its type allows 16 bytes; and
`erx_device_region` keeping its carve when `erx_dma_regions_add` refuses (unreachable while names are fresh).
`ERX_DMA_SEED_HANDOVER_BUFFERS_ONLY` (`erx_device_dma.c`, a ring region passing to the device left uncleaned) is
planted by no test since the split ring left the check; planted in the TRB model harness it passes, so that
harness needs a schedule where a ring region passes to the device dirty (the event ring's zeroing) before it can
plant it (Medium). The split ring's non-coherent order (cleans before the available index and the ready bit,
invalidates before loads) lives in `erx_device.c`'s `apply_sequence` and `split_ring_complete`, and
`erx_device_dma_model_harness.c` checks its own copy of them over the cache model, so a reordering in
`erx_device.c` passes it (Medium): the record memory's effects behind a small interface with a hosted
implementation over `erx_dma_model`, or one ordered effect list from the sequencer that both run, would let the
model harness drive `erx_device.c` itself. `erx_device_dma_check` and `erx_device_dma_order` serve GENET,
  ADMA2 and the TRB form through `accept_plan` until those move, so the old check goes with the last of them. The
  sequencer writes virtio's available entry, which no layout holds, without an encoder; it refuses a report that
  releases nothing (the ledger has no transition that only advances a consumer position) and a release by address,
  as an event TRB's, both of which the TRB form needs.
  `erx_dma_report_holding` takes the record the effect layer read, and nothing ties it to the record at the consumer
  position (an acquisition that holds its second-phase snapshots and consumes them in order would); the ledger's
  exhaustive harness does not explore its acquire transition (each release there follows an acquisition of every
  live holding), and `erx_dma_ledger_acquire` takes a bare count, so no chokepoint yet keeps the ledger's
  transitions to the sequencer;
  `ERX_DMA_STORE_BYTES_MAX` is hand-kept, checked only by static assertions against the layouts the sequencer
  encodes, and should be derived from the widest encoded layout; `erx_dma_ledger_make` takes any layout that passes the
  install's check, so the sequencer's `install()` relies on its one caller, the split ring, deriving its layout
  through `erx_dma_layout_split_ring` (three tables of one count); the
  publication's `erx_dma_publication_call_t` and `erx_device_dma.h`'s `erx_dma_call_t` are two models of a
  call until the old check goes; `free_record`'s loop
  is bounded only by the room rule; `erx_dma_publish` returns check verdicts for refusals that mean the check and the
  sequencer disagree; rule 1 zeroes a buffer's named size while the handover cleans its stride; and the generated
  `erx_report_meaning` carries an unreachable return and casts for a structure with one meaning. Packages, in order: the
  sequencer's publication and its acquisition, with the releases rule and the split ring moved onto them; GENET,
  and ADMA2 with its transfer split into entries by the sequencer, moved onto them; the TRB form's publication and
  bindings; the TRB form's releases from acquired events; the
  stand-ins' ledger check. Before a non-coherent device relies on the acquisition, its unverified AArch64 premise is settled by the Arm
  ARM passage, the litmus test or the VL805 probe [Releases](design-device-dma.md#releases) names.
* [Low] Erlang edges (docs/style.md, "Functional core"): `erx_tcp_listen` (`:176`), `erx_gen_tcp`
  (`:443`), `erx_pipe_srv` (`:312`), `erx_prog_handler` (`:264`) and `erx_blk_sd` (`:394`) walk a
  step's actions with a loop of their own rather than `erx_actions:perform/3`; the first two match a
  bare `stop` with `[stop | _]`, dropping any action after it where the one loop refuses it. Move
  each to `{stop, Reason}` and the one loop, then add a source check that no module but
  `erx_actions` has a clause on a stop at a list's head.


## Security residuals

* [Medium] runtime, the system domain's safe decode (edit 9 of
  [design-runtime.md](design-runtime.md), `erts_proc_sig_decode_dist` in
  `otp/erts/emulator/beam/erl_proc_sig_queue.c`, `erts_net_message` in `dist.c`):
  * Each message family a domain sends the system domain keeps its atoms within
    what the system domain holds by hand: the ready report's provides cross as
    binaries, a mint's refusal as `refused`, a lost connection's reason through
    `lost_reason/1`. A family that names a sender's own atom loses the message
    silently, its caller waiting out a timeout; a facet forwarding to a service
    in another domain whose replies name such atoms would hold its in-flight
    slots until it answers `busy`. Declaring each family's closed atom set in
    `abi/protocols` would make this hold by construction; the count is global,
    not per connection.
  * `{erx_foreign_reason, Bin}` carries the reason's whole encoding; system-domain
    code that decodes Bin with `binary_to_term/1` without `[safe]` makes the
    atoms D5 forbids, and no check holds that.
* [Medium] clock, the approximate start in a release build (`erlang/apps/erx/src/erx_clock_core.erl`,
  `start/2`; [design-time.md](design-time.md#the-approximate-start), open decision 2): a clock without
  a reading starts at the build's date, and certificate validation treats it as set, so until the clock
  is set a certificate that expired between the build and the real date is accepted. Accepted for
  development builds and 0.1; a release build decides whether to keep the start, refuse TLS while
  `state` is `approximate`, or drop it. A release build must also carry a date: without one the floor is
  0, which refuses no sample.
* [Medium] clock, `approximate` is re-entered by a step onto the floor (`erx_clock_core:state/2`): the state
  is "the page changed and its offset is exactly the floor", so a set of exactly that offset, or a
  sample a holder of `clock` steers onto it, makes the next sample unrestricted again, which open
  decision 1 of [design-time.md](design-time.md#open-decisions) reserves to a reboot. Fix by
  having `erx_clock_nif:read/0` give the page's sequence, so `approximate` is "exactly one write, and
  offset is the floor", which no later step can restore.
* [Medium] device NIF, `otp/erts/emulator/nifs/erxos/erx_device.c`: only the driver accesses go through a record's
  layout (`erx_device_layout_offset`); the NIF's own sequences (`get`/`put`, `register_at` for plan steps, the SD
  command store, GENET's `rbuf_ctrl`) address registers by their table offset, which is right only for a register
  at a fixed offset. No such sequence reaches xHCI yet; before one does (the TRB form's install, doorbells, `USBCMD`),
  `load` and `store` should take a register and element and resolve them, so no raw offset can be written.
* [Low] device NIF, `otp/erts/emulator/nifs/erxos/erx_device_bif.c`: `write/3` and `write_field/4` take no device lock,
  though design-device-dma.md ("Register ownership", "Every driver write takes the device lock") has them take the
  lock the queue calls hold; so the read with which `write/3` checks a register's owned fields (xHCI's `USBCMD` and
  `IMAN`) is not ordered against a `negotiate/2` another process of the domain runs on the same device. One driver
  process holds each device, so no driver interleaves them today.
* [Medium] device NIF, `otp/erts/emulator/nifs/erxos/erx_device_nif.c`, `open/1`: a spec's `peripheral` is the
  caller's, so a driver can open a window as any table peripheral whose block fits it, such as a virtio-mmio
  transport as `sdhci`, and reach the transport's owned offsets through that peripheral's writable registers,
  past `ownedByNif` and the per-kind configuration registers of
  [Registers by name](design-runtime.md#the-device-nif). Take the peripheral from the record the system
  domain wrote, with the fix for `window` and `memory` below.
* [Medium] device NIF, `otp/erts/emulator/nifs/erxos/erx_device_nif.c`, `open/1`: a device spec's `window` and
  `memory` are `{object, Handle, ...}` terms Erlang supplies, and the NIF maps whatever handle they name. The
  framebuffer's window handle is readable from Erlang (`erx_device_record:framebuffers/0`), so display-domain
  code can open it as a device's memory, make a region and `erx_memdraw:wrap/4` an image over device memory,
  whose unaligned accesses fault the domain, or open it as a register window. `erx_device:framebuffer/0`
  already reads its record from the boot page; make every record (`given` too) come from the boot page the
  same way, so `open/1` never maps a handle Erlang names and "only `framebuffer/0` maps a framebuffer" holds
  by construction, with a chokepoint row for it.
* [Medium] device NIF, virtio-gpu requests on an unconfined device
  ([design-runtime.md](design-runtime.md#the-device-nif), Regions): the NIF writes the region entries a request
  names, but does not parse GPU commands, so a driver can still put any 64-bit address in a payload, as an
  `{out, Binary}` entry address or an overstated `nr_entries`, and the device will read it. On Phase 1's unconfined
  devices that reaches any memory; it closes with confinement, when the device's window bounds what it reads.
* [High] Runtime, origins (edits 58-61 of design-runtime, design-domains D18): edit 16
  wraps every message from another domain, and `gen` and `io` take call and io replies
  in their envelopes, but nothing serves a request from another domain yet. `gen` and
  `io` take a reply with no check of its domain, since the call's reference, four
  unguessable words (edit 17), was handed only to the callee. What remains, in order:
  1. the io servers' request unwraps (edit 61), without which io from a process spawned
     into another domain waits forever;
  2. `file`'s `file_request` and `file_reply`, which neither edit 60 nor edit 61 covers:
     a positioned operation (`file:pread/3`, `pwrite/3`, `position/2`) on a file server
     of another domain waits forever for its reply, which arrives in its envelope. The
     design needs an edit for it;
  3. `{erx_serve, any}` (edit 59), with `erx:owner/1` to check a request's domain,
     without which no `gen_server` or `gen_statem` serves another domain;
  4. the tests of design-domains' "Origins" and hostile-runtime cases between two ERTS
     domains (a message to an alias arrives wrapped, which waits on aliases holding their
     exports; the served calls; `sys` on a `gen_statem`, a `gen_event` and a plain `sys`
     loop), and the oracle's differing cases recorded per case;
  5. the other stock protocols one ERTS domain speaks to another, which arrive wrapped
     and so go unanswered: net_kernel's `is_auth` call of `net_adm:ping/1` (it lands in
     `handle_info`, and the caller waits forever), `global`'s connect, lock and sync
     messages (`global:sync/0` and `register_name/2` stall on another domain's node),
     `peer`'s own `io_reply` receive and `proc_lib`'s start acks. Each needs its owner's
     unwrap, or a design note that it does not cross domains.
* [Low] Runtime, origins (`gen.erl` and `io.erl`, edits 58 and 60): a reply needs no
  check of its domain only while the call's reference reaches no third domain. A call
  with timeout `infinity` replies to the caller's pid with a plain monitor reference;
  a callee that logs or prints its `From` in full (a crash report, a log record) shows
  the four words to whoever reads that log, and a domain that holds `send` on the caller
  can then forge the reply. Print references short in records another domain reads, or
  check the reply's `D` against `erx:owner/1` of the callee.
* [Medium] Runtime, local decode of an echoed reference, `external.c` `dec_term` with no
  connection: a local `binary_to_term/1` promotes the words of a table or resource
  reference to the live table or resource, as stock does (design-runtime, "Representation
  and aliases"). A peer that was given a table id, or learned its words, can send them
  back inside a binary; local code that decodes that binary with `binary_to_term/1` then
  acts on the live table on the peer's behalf, a confused deputy. A service must not
  `binary_to_term/1` a binary another domain sent and then use a reference in it as a
  table or resource; nothing enforces that.

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

## Planned features

* [Medium] crypto, the system trust store for 0.2
  ([design-crypto.md](design-crypto.md#the-trust-store)): ship Mozilla NSS's root list as the
  system's trust store, as FreeBSD's base does (`secure/caroot`: roots split from NSS's
  `certdata.txt` into `trusted/`, removed ones moved to `untrusted/`, refreshed when Mozilla's list
  changes; `certctl(8)` builds `/etc/ssl/certs` and `/etc/ssl/cert.pem` and takes an administrator's
  additions and blocks). Needs a short design first: where the store lives and how an app's
  session sees it, the import with its source record, and the `certctl` equivalent. The store's
  "a root only with a consumer" rule gives way to this for the system store; a kiosk or app may
  still pin its own roots.
* [Medium] clock record, `abi/inspection.txt` kind `clock`: design-time gives the service's `sample_at`,
  `step_at`, `step_ns`, `offset_ns`, `distance_ns`, `stratum` and `server` the value `none` before a
  sample, but the schema has no integer or text form for "a value or none", and the status `unknown`
  would mix "cannot tell" with "nothing yet". Decide with the clock service's package, before it
  reports them; until then they are `unsupported`. The same package settles the types the review
  questioned: `server` as integers rather than text (design-time's Security), `wall_time` bounded by
  the setter's offset limit, and `record_since` in `ns` like `uptime` rather than the `s` unit.

* [Medium] device NIF, `erx_device.c` `erx_device_config_read`/`_write` and `erx_device_nif.c` `decode_config`: no test
  reaches them (the harness checks the core only): open a `pci_ecam` stand-in and check a round trip at each width,
  a value wider than its width refused, block 256 refused and `elements/2` 256, with a seed on the value bound.
* [Low] bootstrap, boot lines: print `/chosen/bootloader/build-timestamp` from the device tree
  (`rpi-eeprom-update` of `raspberrypi/rpi-eeprom` at `3831e51dba65f4493f3f88c1d049de73165c082e`, l.48), so a
  board report shows the bootloader version, which the Pi 4's A/B card needs to be 2022-12-01 or later
  ([guide](guide/raspberry-pi-4.md#update-the-bootloader-once)). It helps only once the firmware
  has started erXos's code; an older bootloader prints nothing.
* [Medium] musl, `abi/signals.txt`, `erlang/apps/erx_shell/src/erx_shell_jobs.erl`: finish FreeBSD's signal
  numbers from the signal table of the ABI file ([design-programs.md](design-programs.md#signal-numbers)).
  The table generates the `ERX_SIG` constants, `erx_sig_name`, `erx_sig_action`, `erx_sig_valid` and
  `erx_sig_description` in `erx/abi.h`, the Erlang `erx_abi_signals`, and musl's `bits/signum.h` (the numbers,
  `SIGRTMIN` 65, `SIGRTMAX` 126 and `_NSIG` 128), which `strsignal` and `sysconf(_SC_RTSIG_MAX)` follow. The
  shell's `?SIGNALS` still writes FreeBSD's numbers by hand. The work left: `erx_prog`, the protocol's grammar
  and the shell on `erx_abi_signals`; in musl, the generated predicate in `sigaddset`, `sigdelset`,
  `sigismember`, `sigaction` and `pthread_kill` in place of their range tests (today a number 35 to 64 or 127
  enters a set, and `sigaction` refuses it only at liberx's `erx_prog_sig_check`), `sigfillset`'s generated
  set, `strsignal`'s and `psignal`'s `Unknown signal: N` (musl's catch-all `Unknown signal` stands), and new
  `sig2str`, `str2sig`, `sys_signame`, `sys_siglist` and `sys_nsig`; the `difference` kind in
  `test/conformance/libc-test-verdicts.txt` and `tools/lib/erx/libc_test.rb`; the tests of design-programs.md's
  "Signal numbers" bullet. With `sig2str`, the table's reserved numbers take one form,
  `reserved_signal NUMBER [NAME [alias NAME]]` for 32, 33 and 34, so a `signal` line always has a description
  and a default action, and the unnamed ones leave `SignalTable#signals`, whose every entry then has a name
  (`tools/lib/erx/abi_signals.rb`), and musl's `SIGTIMER`, `SIGCANCEL` and `SIGSYNCCALL`
  (`musl/src/internal/pthread_impl.h`) come from it; and the ABI lexer refuses a `\xNN` escape below 32 or of
  127, as it refuses the raw byte, before a description reaches a terminal through `strsignal`
  (`tools/lib/erx/abi_source.rb`). The package lands before the Track P ports.
* [Medium] musl, `musl/arch/aarch64/bits/signal.h`, `abi/signals.txt`,
  `erlang/apps/erx_shell/src/erx_shell_jobs.erl`: give erXos's musl FreeBSD's signal numbers from the signal
  table of the ABI file ([design-programs.md](design-programs.md#signal-numbers)). The table holds each
  signal's name, number and default action, and generates the `ERX_SIG` constants, `erx_sig_name`,
  `erx_sig_action` and `erx_sig_valid` in `erx/abi.h` and the Erlang `erx_abi_signals`; its numbers are compared
  with FreeBSD 15.1's `sys/sys/signal.h`. Today musl keeps Linux's
  numbers (`bits/signal.h`, `SIGSTOP` 19, `SIGCONT` 18, `SIGPWR` 30, `_NSIG` 65), its real-time range starts at
  35 (`musl/src/signal/sigrtmin.c`), and the shell's `?SIGNALS` writes
  FreeBSD's numbers by hand. The work: the table's descriptions (`sys_siglist`'s text) and number 34 as reserved,
  the comparison with the names of `sys_signame` in FreeBSD's `lib/libc/gen/siglist.c`, and musl's number header
  and set of valid signals generated from it; `erx_prog`, the protocol's grammar and the shell on
  `erx_abi_signals`; in musl, the
  generated header in place of the Linux block, `SIGRTMIN` 65 and `SIGRTMAX` 126 as constants, `_NSIG` 128,
  the generated predicate in `sigaddset`, `sigdelset`, `sigismember`, `sigaction` and `pthread_kill`,
  `sigfillset`'s generated set, `strsignal` on FreeBSD's text, `sysconf(_SC_RTSIG_MAX)` 62, and new
  `sig2str`, `str2sig`, `sys_signame`, `sys_siglist` and `sys_nsig`; the shell's table read from the generated
  one; the `difference` kind in `test/conformance/libc-test-verdicts.txt` and `tools/lib/erx/libc_test.rb`;
  the tests of design-programs.md's "Signal numbers" bullet. The package also carries the errno numbers as
  a table of the ABI file, and lands before the Track P ports.
* [Medium] tracer, `erx:trace` ([design-live.md](design-live.md#tracing),
  [design-fiasco.md](design-fiasco.md#the-trace-ring)), in four packages. P1's remainder:
  a test that the
  park core's `trace` effect writes one `park` and one `wake` per sleeping park, none for one that
  returns at once, with the returned status (`test/fixtures/fiasco_park_driver.c`'s is a no-op);
  and the hosted ring through the function API. P2's remainder: `erx_tracer:erts/5` takes the
  system domain's own trace messages, which `erx_trace:classify/2` checks for shape, so P4's
  relay records need their own validation before they reach it; the BIF's 32 KiB buffer comes
  from `erts_alloc`, which ends the VM when memory runs out, where `erts_alloc_fnf` and
  `{error, nomem}` would not; and the generated `erx_status_name` table is sized by the most
  negative status, so a sparse status would need a bound in the model or a switch. P3's
  remainder: the `native_trace` suite's test task started and stopped, with its `space_start`
  and `space_end`; the merger's `unsupported` and `error` entries go out at once without moving
  its latest sent time, so a held entry with an earlier time prints after them unmarked
  (`erx_tracer:ring/4`); the kernel rings are counted from ERTS's `logical_processors`, which
  falls back to one CPU when unknown and on erXos's kernel may disagree with the kernel's
  count, where `liberx` or the boot information should give it; a well-formed `trace_ts`
  tuple any system-domain process sends the trace process is shown as the runtime's event,
  and the alias that is a trace's reference is its stop authority, though a reference can be
  forged inside a node, which both matter once a trace's receiver or caller is in another
  domain (P4); ERTS delivers session messages without flow control, so a session over many
  busy processes on several schedulers can outpace the one trace process, which its
  `max_heap_size` then kills, ending the trace with `killed`, rather than discarding the
  excess; and `check/3` and the session message's shape need fuzz
  targets once Specs and relayed records come from other domains. The window's review left
  these open: a forged far-future `trace_ts` is held until it is 100 ms older than the
  clock, so it ends the trace only through the heap bound; the merger's `lists:merge` over
  the held list after every read belongs on the performance watch list; a forged
  `{erx_trace_ack, Ref}` can open a stuck receiver's window, and since ERTS stamps no
  sender on a message, only an acknowledgement alias given to the receiver alone would tie
  it to the receiver (P4); a trace that ends after a stop before the printer first ran
  leaves the printer a `noproc` it ignores, so a fault in that window prints no failure
  line; the trace process's 2 Mi-word heap bound is an estimate: measure a heavy trace's
  peak with `kill => false` and size it from that, or bound the held list by count into
  the window's counters, and measure the cost of its on-heap mailbox's lock under many
  senders; `{erx_untraced, true}` rests on every ungated reader of a tracer ref's flags
  using `ERTS_IS_P_TRACE_HIDDEN`, not `ERTS_IS_PROC_SENSITIVE`, which a chokepoint check
  listing the allowed `ERTS_IS_PROC_SENSITIVE` sites would enforce; a kill of the trace
  process during its start raises in the caller of `start/3` instead of returning an
  error; `expect()`'s `session` boolean shares a name with the session handle; and
  `park_then_wake?` mutates a set inside `any?`. P4 (the trace facet served across domains,
  the relay, frame tracing and trace records on the host link's events stream) lands with
  M5's kernel part ([plan.md](plan.md#m5-a-wall-around-some-processes)); until then the
  trace view of track D's part 1 (1b-C) traces its session's own domain.
* [Low] POSIX-lite personality, `sysctl(3)` and `sysctl(8)`: build them
  when a ported FreeBSD program first needs them, as a reader of
  `/proc/status` through the program's own namespace that maps
  `hw.ncpu`, `hw.physmem`, `hw.pagesize`, `kern.boottime` and the names
  that program asks for onto the inspector's attributes and answers
  `ENOENT` for a value that is not `ok`; read-only, with no `sysctl`
  facility behind it
  ([design-live.md](design-live.md#system-values-one-tree-many-views)),
  and listed in the C library seam's table of
  [design-runtime.md](design-runtime.md#the-c-library-seam).
* [Low] POSIX-lite personality, FreeBSD programs: survey what FreeBSD
  programs ported at the source level need beyond the planned layer
  (BSD libc extensions, `sysctl`, `kqueue` and the like) and which of
  them the layer should offer; programs brought in come from FreeBSD or
  are BSD-licensed where possible (CLAUDE.md, principle 5;
  [design-programs.md](design-programs.md#the-posix-lite-personality)).
* [Low] OTP's `ssh`, ECDSA private keys in `openssh_key_v1`
  (`otp/lib/ssh/src/ssh_message.erl`, `ssh2_privkey_encode/1`): the
  ECDSA clause, unchanged from stock, may not write the layout OpenSSH
  reads (unverified: read OpenSSH's `sshkey.c` private key serialization
  at a pinned release and compare, with a round trip through
  `ssh-keygen -y` as the test).
* [Low] toybox: at import, verify the `vfork` and `exec` call sites of
  toybox 0.8.15 and the list of applets left out
  ([design-programs.md](design-programs.md)).
* [Medium] runtime, `otp/erts/emulator/nifs/erxos/erx_device.c`: a device record maps the pages that hold its window
  (`erx_device_window_pages`), and an open of another window in one of those pages answers `ebusy`, so only one of
  QEMU `virt`'s eight virtio-mmio slots per page can be driven at a time (the QEMU plan's second disk, on
  `virtio-mmio-bus.30`, shares the first one's page, so its open would be refused). The console handoff
  (`liberx/backend/fiasco/service_task.c`, `erx_fiasco_task_mem_physical_body`) compares the request's base with the
  console's exactly, which holds for a page-aligned UART only; test containment instead. Let records whose windows share a page share its one mapping, each still
  reaching only its own window through the register table
  ([design-shared-devices.md](design-shared-devices.md#pages-inside-a-domain)), and test two slots of one page in
  `test/fixtures/erx_device_harness.c`.
* [Medium] runtime, the device records' writers (`liberx/backend/core/boot_manifest.c`'s `-erx_record device`, the root's
  `-erx_record console`, the domain library's and `runtime_entry.c`'s `-erx_record given`, and `erx_device_record`): no record
  carries the page run its unit's windows cover, which
  [design-shared-devices.md](design-shared-devices.md#pages-inside-a-domain) gives it. The device NIF maps each
  record's own pages as its run (`erx_device.c`, `take_window`), so records over one page share its mapping, but a
  record whose pages meet a run without equalling it is `ebusy`. Write the run from the boot view's unit relation
  into every record form, and read it in `erx_device_record`.
* [Low] runtime, the console handoff (`liberx/backend/fiasco/service_task.c`,
  `erx_fiasco_task_mem_physical_body`) compares the request's base with the console's exactly, which holds for a
  page-aligned UART only; test containment instead.
