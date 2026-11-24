# TODO: Build, tooling and tests

Open work on the build, the host tools, the test harnesses and the gates. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Major initiatives

* [Medium] architecture: evaluate the remaining
  [simplification candidates](todo-simplification.md), recording for
  each the mechanism it removes, its cost and the evidence needed to adopt
  it: isolated parsing frontends, causal explanations in the inspector,
  and the open proposal
  on the scheduler's target configuration.
  Scheduled experiments live in the roadmap; these proposals do not
  silently replace established design decisions.
* [Medium] performance: measure the suspected costs on the
  [performance watch list](todo-performance.md), each with the
  workload it names, and remove each item once a recorded number settles
  it: the kernel's portable-code hash of large boot image files at first
  use, the eager FP switch, and Phase 1's one service thread.
* [Medium] benchmarks (`tools/erx bench g3`, [research-g3-baseline.md](research-g3-baseline.md)):
  repeat the G3 run for HVF and TCG on a quiet host, since the first run was
  taken at a load average of 44 to 55, and find why stock OTP on the host
  is slower than the guest at the same four operations under HVF.
* [High] benchmarks, the record and the comparison (`tools/lib/erx/bench*.rb`,
  [design-bench.md](design-bench.md#the-construction)): `Erx::BenchRecord` with its one writer and
  `Erx::BenchCompare` with its band and verdicts exist; still to build are the side-by-side table, FD32's
  predicate, the existing runners moved into declarations in `tools/lib/erx/benches/` and the chain of name tests
  in `tools/erx` deleted; and
  the three fixes of [Fixing the existing tools](design-bench.md#fixing-the-existing-tools) (`g3`'s TCG ratio,
  `otp-switch`'s observed switches, every runner's output under `build/bench`), with the guide's table in
  `docs/guide/tracing.md` brought to match. Tests: the remaining tool rows of design-bench.md's Verification,
  each with its seed. Open review point of the first slice: `slower` and `faster` are not yet held to a paired run.
* [High] benchmarks, `wake` ([design-bench.md](design-bench.md#1-wake-how-late-a-waiting-thread-runs)): the
  guest library of `test/guest/bench/` and the native bench guest `test/guest/native_bench/` with its runner
  `tools/lib/erx/native_bench.rb` exist: its root times `park-deadline`, the two wake handshakes and
  `trigger-take` on two executors of its group and prints their `BENCH` lines and the `CLOCK` line, and its
  build with `ERX_BENCH_SEED_LOST_WAKE` skips one wake; the `bench` suite boots both, records the first and
  fails its cell unless the second loses its wake. Still to build: `bench/erx_wake_bench.erl` with
  `bench/erx_bench_hist.erl` for `erlang-timer` in the `xdomain` bench image; and the load cells, whose
  spinners are `native_task`'s program in new modes, which the landing matrix does not run yet.
* [Medium] benchmarks, the landing run's record (`tools/lib/erx/native_bench.rb` `Landing`,
  `tools/lib/erx/bench_record.rb`): a `not_run` or `rejected` cell the host makes carries zero counts and batch 1,
  which nobody observed, because `BenchRecord::Cell` requires both; the format should let such a cell carry none. The
  subject holds the compiler's path and the root's `-D` flags, not the compiler's version and the complete compile
  and link flags; the environment's `host_os` is Ruby's build target, not the host's OS version; a boot without a
  valid `CLOCK` line records `clock: {}`; the record has no `boot-1.qemu.log`; a replayed boot's `reused_from`
  names the gate store's log, not the history run that recorded it. `Landing#call` and the suite's notes have no
  test (a stub `Run` would cover the replay, the write before the seeded boot and the escaping), and the line fuzz
  target does not reach `BenchMeasurement.boot`. The pair `[0, cpus - 1]` is stated in `NativeBench.asked` and in
  the guest's choice of executor CPU; `tools/lib/erx/bench.rb`'s load average is a third reader beside
  `QemuGate.one_minute_load`.
* [Medium] benchmarks, the native bench guest's handshake (`test/guest/native_bench/guest.c`): any `ERX_OK` from
  B's park is taken as A's poke, which holds only while nothing else moves the group's epochs; A should
  publish the poke's number and B re-park until it sees it. The executors run fixed scripts that must match the
  root's order, so a lost wake in `wake-same-cpu` leaves `trigger-take` not run; the root should name each
  phase. The root polls every 100 us on CPU 0 during `park-deadline`; a cross-CPU sample corrected below
  minus its uncertainty is clamped to 0 instead of making the cell unsupported; and that the root runs on
  CPU 0, which `same-cpu` and the pair assume, is unverified.
* [Low] benchmarks, reasons the host writes itself (`timed_out`, `not_run`, a `rejected` cell's reason from
  `BenchMeasurement.boot`): `BenchRecord::Cell` holds every reason to `BenchRecord::REASON`, but a refusal's
  message, which embeds `JsonInput`'s reason and path names from the history destination, has no character-set
  check of its own before it reaches the terminal; give the refusal messages the console line escaper or a test
  that every refusal's text is plain.
* [Low] benchmarks, the `BENCH` line fuzz target (`tools/fuzz/bench_line.rb`): its seeded fault, the
  validator's check that a histogram holds the line's sample count removed, is run by hand and kept nowhere;
  make it a test that runs a fixed number of inputs from a fixed seed against the faulted validator, so the
  target's one invariant is shown to catch what it guards.
* [Medium] benchmarks, `sched` ([design-bench.md](design-bench.md#2-sched-how-a-cpu-is-shared)): `native_task`
  program modes for the recording spinners, `share-equal`, `share-tasks` and `band-work`; lands with the quantum
  case's seed run.
* [Medium] benchmarks, `nullcall` ([design-bench.md](design-bench.md#3-nullcall-the-decoder-refusal-round-trip)):
  the decoder-refusal round trips, same and cross space, checked by the service's received count, and the kernel's
  cheapest call chosen from Fiasco's source; then FD32's ten runs a build on the Raspberry Pi 4, judged by its own
  predicate.
* [Medium] benchmarks, `vm` ([design-bench.md](design-bench.md#4-vm-what-memory-costs)): the reserve, commit,
  touch, protect, decommit, release, map and child operations from the root and from a test task.
* [Medium] benchmarks, `xdomain` ([design-bench.md](design-bench.md#5-xdomain-one-message-one-domain-to-another)):
  `bench/erx_xdomain_bench.erl`, a test image from the `system_domain` suite's with the echo facet granted to the
  client's domain, `local-rtt` and `xdomain-pingpong`. `xdomain-throughput` and `xdomain-stall` wait for their own
  design with G5's runs.
* [Medium] benchmarks, the Raspberry Pi 4 and the other systems
  ([design-bench.md](design-bench.md#other-systems-on-the-same-raspberry-pi-4)): a raspi4b build of the native
  bench image; `tools/erx bench import` for console logs and the analyser's captures; `bench/peer/erx_peer_bench.c`;
  the L4Re, FreeBSD and Linux images and L4Re's IPC benchmark pinned in the fetch step; the two GPIO responders.
  Includes the development-only Fiasco patch that stamps the interrupt entry
  ([design-bench.md](design-bench.md#the-interrupt-entrys-stamp)), the check of the Glasgow's stock applets for the
  stimulus ([design-bench.md](design-bench.md#the-analysers-stimulus)) and GPIO 20 and 21 as the two pins.

## Stopgap replacements

* [Medium] tooling, `tools/lib/erx/system_domain_regrant.rb` and `session_domain.rb`: the regrant judge does not
  read the end line, so a root fault that powered off would pass, and its fixture `abort.log` still ends
  `erx: end off` and needs recapturing first; the session suite's halt boot could require `erx: end off`, which
  init's halt after a refused commit, now a reset, no longer prints. The crash and watchdog suites check the end line.
* [Low] tooling, `tools/lib/erx/native_crash.rb`: the pc check asks only that the pc is at or
  above RAM's start, with no upper bound and nothing tying it to the crash root's image,
  whose range the guest could print beside its address; and `test/guest/native_threads`'s `QUEUE_SETTLE_NS` trusts a 50 ms sleep to order
  waiters, which a starved vCPU can break.
* [Low] `test/fixtures/erx_device_dma_harness.c`: nothing shows that `open` and `queue_create` read nothing from kept memory (`mprotect` it `PROT_NONE` until `negotiate` in `next_record`), and the harness's `erx_vm_map` takes offset 0 only, so a given window at a nonzero page of its object is not exercised.
* [Medium] `tools/lib/erx/release_medium.rb`, `system_partition`: its refusal of an image and tree larger than
  the system partition has no test, because reaching it takes an image near the partition's 63 MiB
  (`medium_system_sectors`), which the function reads whole and hashes. Take the partition's size from
  `MediumImage` once and pass it through `system_partition`, `image_extent` and `image_extents`, which each read
  it today, and test the refusal on a small partition.
* [Medium] The `apps` QEMU suite (`tools/lib/erx/apps.rb`) has no reboot cells yet: `service clock disable` and a
  reboot of the same disk leave the row stopped, and `service clock enable` survives a reboot
  (docs/design-apps.md, "Verification and testing"; docs/plan.md, Track A's demo). Its boots each take a fresh
  copy of the release medium; the reboot cells boot one copy twice.
* [Medium] `test/host/erx_web_proto_test.rb`, [Web protocol](design-abi.md#web-protocol): no test encodes a
  term one past each bound in both languages; every encoded term is in bounds or came from a decoder, so an
  encoder that stopped refusing an over-bound list, text or integer would pass. Erlang's encoder refuses
  over-long bytes and texts as `too_long` and over-count lists as `too_many`, as both decoders do, which
  `erx_web_conn` relies on to end a view `too_large`; the TypeScript encoder still answers `bad_term` there. Make
  it match, then a table-driven case over `type/1` and `TYPES` expecting the same reason from both closes it.
* [Medium] `test/host/web_browser_test.rb`, [Verification and testing](design-web.md#verification-and-testing):
  `deps.lock` pins Playwright's Chromium for macOS on arm64 only, as Playwright builds none for FreeBSD, so the
  browser tests are not run on the FreeBSD x86-64 check host that runs the landing gate's `make check`; run them
  in the gate's local step on macOS, or pin a FreeBSD Chromium (the `www/chromium` package) by its SHA-256.
* [Medium] `test/host/erx_ui_wire_test.rb`, [Widget format](design-abi.md#widget-format): no test encodes
  each kind's largest `insert`, every property at its bound, and compares its size with the generator's
  `insert_max` (`tools/lib/erx/abi_ui.rb`'s sizes and the encoder's layout are two descriptions of one form).
* [Low] `test/fixtures/erx_draw_codec_harness.c` and `tools/fuzz/draw_codec_target.rb`, the draw codec's C twin,
  [Draw messages](design-display.md#draw-messages): the twin still frames a `Y` with the stand-in
  `erx_draw_cload_frame`, so the differential test of the codec against it compares `erx_draw_image` with the
  stand-in, not with 9front's decoder. Link `display/libmemdraw/cload.c` behind it and delete the stand-in.
  `cloadmemimage`'s `badrect` bounds are narrower than the stand-in's, so keep the harness's rectangles within them.
* [Low] `tools/lib/erx/`: git is run from many call sites, each of which must pass `GitEnvironment.isolated` and `-c core.fsmonitor=false` itself (`checks.rb`, `submodule.rb`, `source_revision.rb` do; `dependencies.rb` `export_commit`, `fiasco.rb` `import_git` and `net_bench_freebsd.rb` `tree_state` do not). One git funnel with a chokepoint check would make the isolation hold by construction.
* [Low] `tools/lib/erx/lvgl.rb`, `Lvgl::Program::LICENSE`: the archive's license expression is hand-kept against
  `display/lvgl/lv_conf.h` and LVGL's sources, so an option turned on there (an image decoder, another font) or a
  third-party file no option guards (as FrogFS's `decomp_raw.c`, which the Makefile leaves out) is not attributed
  until the expression is edited too. Per-file attribution would read blob hashes from the submodule's tree at the
  gitlink with a small path-to-license map, or check the archive's defining members (`llvm-nm --defined-only`)
  against such a map. `src/misc/lv_lru.c` cites willcannings/C-LRU-Cache with no notice of its own; its upstream
  license is unverified.
* [Medium] `test/host/display_domain_test.rb`: the suite has no cell under `rio`: keys typed at a clicked window
  keep reaching it while a second client makes, raises, hides and shows a window, with a seeded policy that picks
  each new window ([Verification and testing](design-display.md#verification-and-testing), the window
  system). The same sequence runs on the host in `test/erlang/erx_winfs_tests.erl`'s click case, and the
  policy's own exhaustive run is in `test/erlang/erx_wm_rio_tests.erl`.
* [Low] `test/fixtures/erx_device_genet_harness.c` (erx_device_queue_test.rb) plays GENET's controller itself at the access seam: its DMA status, stop reads and both engines, beside `erx_device_genet_model`. Running the model there, with the harness keeping its own checks (ring registers written only while both engines are stopped, both rings installed before a start, receive started first) and a stop count per direction (the transmit engine stops later), would leave one GENET controller model.
* [Low] build checks, `contiguous-create-callers` (`tools/lib/erx/chokepoint_rules/fiasco_seam.rb`): the rule
  limits which files call `erx_mem_create_contiguous`, not where the range comes from, so a hand-built
  `erx_mem_dma_range_t` in `runtime_entry.c` or `dom_apply.c` would pass, and `erx_boot_dma_range` is the one
  builder by convention. Forbid the type's initialisers outside `boot_manifest.c`, the backends and the guests.
* [Medium] tooling, the pinned host builds `tools/lib/erx/fsimg.rb`,
  `tools/lib/erx/rc_oracle.rb` and `tools/lib/erx/herd.rb` each repeat the
  same protocol: the lock record, the build record of pin and recipe,
  `locate` with its MissingBuild and StaleBuild, and `publish`. fsimg's and
  rc_oracle's `publish` lose the previous build when the final rename fails
  (two builds racing), which herd.rb's moves back. Extract one owner of the
  protocol, parameterised by source id, required files and recipe file, so a
  fix lands once. No test of the race.
* [Medium] tooling, `tools/lib/erx/oracle_guest.rb`: nothing automatic runs
  `test/host/json_input_test.rb` inside the oracle's pinned image, which hid a two-day
  break under its older `json`. The oracle's `probe` operation should exercise a
  duplicate-key refusal there.
* [Medium] tooling, `tools/lib/erx/oracle_hosted.rb`: its hosted release (tree, placeholder
  root, pack rows, `PackWire`, runtime environment) is a second copy of
  `test/integration/runtime_prim_file_test.rb`'s. Extract one hosted-release builder that both use.
* [Low] tests, `test/host/erx_hostlink_session_test.rb`: the EUnit run takes 295 s alone on an Apple Silicon host
  and once passed its own 600 s deadline under `make check`'s parallel load, failing the check with every case
  shown passing. Find the slow case and bound it, or give the run a deadline that fits the load.
* [Low] tests, `test/integration/runtime_prim_file_test.rb`, `test_a_changed_byte_is_refused_at_open`: it
  compares the damaged image's lines with the intact run's and drops only a supervisor report's header
  line, so the report's `supervisor:` and `offender: [{pid,...}` lines fail it whenever the two runs
  number their processes differently (seen as `<0.77.0>` and `<0.78.0>` on two runs of one tree). Drop
  or normalize the whole report.
* [Low] tests, `test/integration/runtime_hosted_smoke_test.rb`,
  `test_a_module_reloaded_in_a_loop_on_four_schedulers_never_runs_stale_code`: its 60 s wait for the
  next prompt fails at a host load average near 80. Give the wait a deadline that fits the load.
* [Low] tooling, `tools/build_site.rb`: v64's Makefile runs Closure Compiler with the `java` on PATH, and macOS's
  `/usr/bin/java` stub fails with "Unable to locate a Java Runtime" when no JDK is registered. Find Homebrew's
  `openjdk` (or take `ERX_JAVA`) and pass it to the build, failing with a diagnostic naming it.
* [Low] tooling, `make check-reproducible`: both builds of OTP and musl run at one path, so a path
  of theirs that reached the image would not show.
* [Medium] tooling, `tools/lib/erx/oracle_qemu.rb`: the suites' events reach the host on the
  console's serial line, which the kernel, the root and ERTS's C output also write, at any
  byte. No process holds `erx_tty_owner`, so `display_string` writes straight to the console, and
  `liberx/backend/fiasco/console.c` hands the kernel at most 488 bytes
  (`L4_VCON_WRITE_SIZE`) per call, so another thread's write can land inside an event line
  longer than that: a stdlib run on one CPU lost a peer_SUITE case start this way. The frame's
  length and CRC-32 then reject it, its sequence number's gap shows it lost, and the run is
  read as far as it can be and reports itself incomplete; a case whose start was lost is
  unknown, and so is every run of a case either side ran more than once, since the lost start
  would number its later runs one too low. Move the events to the host
  link (`/pl011@9040000`, M4), which only the host link's own sink writes.
* [Medium] tooling, `tools/lib/erx/pack.rb`, `pack_wire.rb`: `ERX_PACK_TEST_CODE` is set only
  by `ProductionImage#build_test_image`; other packers that carry test code (`BootImage#build`
  for libc-test and the native task suites, `OracleHosted#pack`) leave it clear, since
  `test_code:` defaults to false. The by-construction fix is to derive the header bit from
  per-entry test flags in the packer (ORed into the header, checked against the entries by
  `erx_index_check`); every packer then marks its test image, and the lexical
  `test-image-builder` check (`Checks::TEST_IMAGE_BUILDERS`) can go.
* [Medium] build, `tools/lib/erx/import_notices.rb` and `tools/lib/erx/pack_provenance.rb` (`attribute`): a
  license grant with no text in `config/provenance/import-notices.json` fails only for L4Re's user libraries
  (`Fiasco.user_license_notices`); an imported file under a package that lists notices, and every other
  external archive, passes with the package's notices alone, and an archive's notices are hashed from the live
  file, not held to the profile's pin. Make "every selected grant has a document" part of `ImportNotices.select`
  and route archive notices through it. The copyright extraction for the user libraries
  (`Fiasco.copyright_comment`) is a second leading-comment parser beside `PackProvenance#leading_notice`, and
  its source directories are listed by hand; one parser, and the file set from the build's dependency files,
  would keep each fact once.
* [Medium] tooling, `tools/lib/erx/production_image.rb`: the device-path check dumps unversioned `virt`
  on `cortex-a72` with two serial ports, not the `virt-11.1` machine the harness boots. Build the dump
  from `QemuPlan`'s machine and CPU.
* [Low] tooling, `tools/lib/erx/pack_provenance.rb`: `attribute` takes a file with no inventory row at
  the audit's word and as `permanent`, whatever the audit's status, and `resolve_fiasco` picks out
  erXos's additions by their evidence text. The audit should emit each one's status and notices.
* [Medium] tooling, `tools/lib/erx/qemu.rb`, `Transcript#consume_lines`: a serial line past 64 KiB ends the boot, and a task's `write` can
  send one with no newline, so that test reads unknown and the rest of its batch not run. Skip an overlong line instead of raising.
* [Medium] release comparison, `test/integration/runtime_release_test.rb`: the comparison of the hosted and production archives skips unless both were built from the same sources, and no gate builds both.
* [Low] test, CPU feature words of programs (`test/guest/programs/bigargs.c`): the programs suite checks that a
  program's `AT_HWCAP` has FP and Advanced SIMD and no refused bit and equals its registers, not that it equals its
  session's words, since no Erlang call reads the boot information page's `hwcap`; a driver writing a constant would
  pass. Compare against the session's words once an inspection path (`/proc`) shows them.
* [Medium] test, CPU feature words (`test/guest/native_musl/guest.c` `case_auxv`): the guest checks that `AT_HWCAP`
  has FP and Advanced SIMD and no refused bit, but runs no claimed instruction, so a feature the kernel or a
  hypervisor traps (EL0 `DC CVAP` under HVF is unchecked) would pass. For each claimed bit that is set, run one
  instruction of it (`dc cvap`, `cfinv`, `ldapr`, `ldaddal`, `crc32x`, `aese`, `pmull`, `sha512h`, `eor3`, `sm4e`,
  `sdot`, `fcmla`, `fjcvtzs`, a half-precision `fadd`) under TCG and HVF; and tie each claim to the Fiasco fact
  behind it (`Sctlr_uci` in `Sctlr_el1_generic`, `CONFIG_FPU` required) in the host test.
  domain at load (`docs/design-crypto.md`, K4).
* [Low] tooling, `tools/lib/erx/qemu.rb`'s `machine_end` cannot tell a power-off
  from a reset under `-no-reboot`, and ignores lines after the last checkpoint.
  Settle both with the `erx_machine_end` case.
* [Medium] tooling, `tools/lib/erx/qemu.rb`, `Qemu#run`: QEMU stopped by a signal from outside the run exits 0, so it is
  checked for only when the transcript is incomplete. With `machine_end:` a signal after the transcript is whole reads as a
  pass, and a stopped run raises a plain `Erx::Error`, which `OracleQemu.state_of` counts as an erXos crash instead of an
  unknown result. Check `SIGNAL_STOP_LINE` whenever QEMU exited by itself, and raise a subclass that reports read `cancelled`.
* [Low] tooling, `tools/lib/erx/production_image.rb` (`device_path_problems`): the check of a platform record
  against a device tree reads QEMU virt's tree shape only, and runs only in the production image suite's
  device-path step, so a wrong `ram_first` or PL011 clock in a Raspberry Pi record is never checked against
  the board's tree. 1b-I's stage (a) writes `config.txt`'s `init_uart_clock` from the record; check the Pi's
  record against its device tree (nodes under `/soc`, the firmware's clocks) there.
* [Medium] tooling, `tools/lib/erx/fiasco_provenance.rb` (`image_objects`, `MAPS`): the provenance audit
  covers the main build's bootstrap only and skips `build/fiasco/users-*`, so the Raspberry Pi 4's bootstrap
  (`Fiasco#build_board_bootstrap`) and the 16550 and BCM2835 UART drivers it links have no build record. Make the
  audit take a users directory and run it once per bootstrap build, its object lookup scoped to that directory.
* [Low] tooling, the Raspberry Pi 4's medium (`BootPartition.boot_partition_medium?`, `Fiasco::BOARD_BOOTSTRAPS`,
  `BoardTree::BOARDS`, `QemuPlan::MACHINES`): a board's facts sit in three tables keyed by platform name, and the
  medium is chosen by membership of one of them, so a board added to the others but not to
  `BoardTree::BOARDS` gets QEMU's release medium. Declare the medium, the load address and the board's tree in the
  platform record, checked when it loads, so a board without a medium is refused.
* [Medium] tooling, plan.md 1b-I (e), with the I2C driver (docs/design-header-io.md, "Placement: units and domains"):
  the devices domain on the Pi's development manifest, holding `i2c` and `spi`, its memory from a footprint measured
  with `erx_i2c` loaded, with the raspi4b suite's line for it.
* [Low] tooling, the header map reader (`tools/lib/erx/header_map.rb`): `controller?` matches a device to a pin
  table controller by its path's unit address alone, parsing it apart from `unit_address`, so a driven device whose
  path's address is unreadable (`@07e804000`, upper case) skips the rows rule, and the parent bus is ignored. Let
  the pin table's controller rows name their kind (or compatible string), so a bus device follows from what it is.
  The platform record fuzz target (`tools/fuzz/platform_record.rb`) has neither the `i2c` and `spi` role words nor
  their compatible strings in its values, and does not assert that every device row names a driven device and
  every driven device at a controller has rows.
* [Medium] tooling, the header map reader (`tools/lib/erx/header_map.rb`): the core clock is taken from the devices
  a map names that are not UARTs (`core_clock`), a rule by exclusion that a PWM row with its own clock would break;
  derive it from what the device is (its kind, or a clock column of the pin table's controller rows). The reader
  also reads `hw/pins` from the code tree, not the root `Platform.load` was given (pass the table in); some
  refusals do not name the row (`alternate`'s and `fetch_controller`'s, a decimal address); a record whose
  console or hostlink is no device path skips the UART rule; an overlay whose device the map gives no pins is not
  refused; `Row#device?` and the reader decide a device row two ways; a JSON null passes as an absent key.
* [Low] tooling, `tools/erx pack` and the raspi4b suite share `build/production-image/raspi4b/`, cleared before
  each build: a suite run replaces the card last packed, two packs of one platform at once remove each other's
  files, and a failed pack leaves the directory partial. Build into a sibling directory and rename it into place.
* [Medium] QEMU harness, `QemuPlan::MACHINES['raspi4b']` (`tools/lib/erx/qemu.rb`): the loader's
  addresses for BL31 (0) and the bootable file (0x200000) are not checked against the builds that
  fix them (TF-A's BL31 base, bootstrap's `DEFAULT_RELOC_arm64-arm_gen`); a change there hangs the
  model's boot with no diagnostic. Check them in `Raspi4bShell#build_inputs`, or derive them.
* [Low] tooling, the native harnesses' `MEMORY_MIB = 512`, `tools/lib/erx/medium_boot.rb` (the block
  device's window, `virt.dtb`, the `qemu-virt/development` patterns), `tools/lib/erx/qemu.rb` (`cortex-a76`,
  the virtio-mmio bus arguments) and `ProductionImage::Run#check_device_paths` (`-cpu cortex-a72`) still hold
  QEMU virt's values. QEMU's `raspi4b` takes only its own 2 GiB and has no virtio-mmio; move each into the
  platform record or `QemuPlan::MACHINES` when 1b-I's stage (a) runs a suite on the model.
* [Low] tooling, `tools/lib/erx/native_root.rb` (`build_system_receipted`): the
  root's linked receipt does not name its place, the `--defsym` of
  `erx_fiasco_image_start` that `place_flags` adds, and nothing it binds by
  hash shows it. Record it, which needs a field in `PackProvenance`'s
  `linked` schema (`exact_keys`), or bind the place as a link input.
* [Medium] build, document links: no `make check` step resolves the `file.md#anchor` links of the design
  documents, `TODO.md`, `README.md`, `CLAUDE.md` and the comments of `tools/`, `test/` and the sources, so
  a section that moves or is renamed leaves dangling anchors that nothing reports (five into
  `design-stopgap.md` and one into `design-files.md` were found by hand). Add a check that reads each
  document's headings, forms each anchor as the viewer does, and fails on a link whose file or anchor does not
  exist, with a seeded dangling anchor; a rule that links go through a constant, as `chokepoint_rules.rb`'s
  `design:` fields do, needs the same check over the interpolated strings.
* [Low] build, document links (`tools/lib/erx/doc_links.rb`): four citation forms are not read. A
  `TODO.md` item cited by its words (`TODO.md, "/etc/rc.conf"`) names no section, so a citation of a closed
  item dangles unreported; checking it needs the words to be found in an item. A section of the citing
  document named without its file (`(below, "A facet's mount")`, or a name after a link to the
  document's own anchor, 36 sites), a second name after the first (`/dev/tty` in
  `design-programs.md ("The terminal", "/dev/tty")`) and a possessive (`design-tmp.md's "Core"
  item`, which can also introduce a quoted phrase) are not read either; each needs the citation's
  grammar to say which document a name belongs to. In the Fiasco design, two bold lead-ins, "A
  page's identity is its window address" and "Thread handles" (which a Fiasco backend item cites in
  the possessive), start no paragraph: each follows its previous line with no blank line between,
  so it renders inside that paragraph and a citation of it would fail once the form is read.

## Bugs by subsystem

* [Low] Oracle image fetch, `Dependencies#fetch_image` (`tools/lib/erx/dependencies.rb`): `make fetch` pulls
  every OCI image `deps.lock` pins, so a host pulls the oracle toolchain of each platform although its engine
  runs only its own. Fetch only the image whose platform is the local engine's architecture
  (`DependencySchema::OCI_PLATFORMS`), unless `--source` names another.
* [Medium] check-fuzz, Ruby drivers (`tools/lib/erx/fuzz_drivers.rb`): a driver can leave the gate by declaring
  itself `# erx-gate: fuzz helper`, and `make check` stays green unless the driver is one of the floor in
  `test/host/gate_baseline_test.rb`. Move the four helpers (`tools/fuzz/run_pack.rb`, `manifest_seeds.rb`,
  `package_seeds.rb`, `test/fuzz/abi_corpus.rb`) out of the driver directories and delete the `helper` kind, so
  every `*.rb` there but a native `KIND_target.rb` is a driver by construction; about ten `require_relative` and
  path edits follow, each failing loudly when missed.
* [Medium] check-fuzz, Ruby drivers (`FuzzDrivers.target_names`): a driver with `targets=` is loaded into the
  planning process (`tools/erx check-fuzz`, `tools/erx gates`, `make check`) to read its table, so a driver whose
  main program loses its `$PROGRAM_NAME` guard runs inside the gate and can end it with its own exit status. Ask
  the driver in a subprocess under a deadline instead (for example `ruby FILE --list-targets`, answered from its
  own table), which keeps the table the one source. The `targets=` floor also checks only paths, not how many
  targets a driver keeps.
* [Low] QEMU harness, console record patterns: `Erx::Transcript` (`tools/lib/erx/qemu.rb`) reads a line that ends in
  a console log line as the log line and its head, rejoined with what follows (`LOG_LINE_END`), but the suites keep
  their own copies of the record format (`NativeRoot::DOMAIN_RECORD`, `NativeTask::LOG_RECORD`,
  `debug_log_probe.rb`'s `RECORD`) and two workarounds the split makes needless: `ProductionImage::Run.beside_report`
  with its `REPORT_LINE`, which allows a report line between any two characters, and the unanchored start of
  `Raspi4bShell.memory_fault_restart`. Fold the record patterns into `LOG_LINE_END` and delete the workarounds. A log
  line that lands inside a program line which itself looks like a log record (`dmesg`'s output) is not split off:
  the leftmost record start is the program's, so the program's fragment and the log line go on as one line and the
  fragment does not join the rest of its line; the format cannot tell the two apart.
* [Low] ABI, the boot records' word layouts (`-erx_record given` and `device`, and `function` in part): each form's
  words are written separately in four places, the C writer (`liberx/backend/core/boot_manifest.c`,
  `erx_boot_device_words` and its neighbours), the C comment and word maxima of `include/erx/boot_words.h`, the
  Erlang reader (`erlang/apps/erx/src/erx_device_record.erl`, `spec/2`) and the image packer's word counts
  (`tools/lib/erx/production_image.rb`, `GIVEN_RECORD_WORDS` and `DEVICE_RECORD_WORDS`), so a word added to a form,
  as the device record's power times were, is four edits kept in step by hand. Declare each form's words once in
  the ABI and generate the readers' layouts and the counts. Cost: about 40 to 60 agent calls.
* [Low] ABI, power lines (`abi/formats/vc_property.txt`, `fw_power_line`): a line's pin and its off and on states
  are three separately named limits (`vc_bt_power_pin`, `vc_bt_power_off`, `vc_bt_power_on`) that the manifest
  generator (`tools/lib/erx/manifest.rb`, the power row's firmware rows) finds by names it builds from the line's
  and each phase's, so a line's facts are a naming convention rather than one row. The ABI language has no
  construct for rows of constants (`abi/manifest.txt`'s `table` locates records in a binary manifest, and
  `translation` maps one enum to another, with no numbers), so one would be needed: one row per line with its pin
  and its state for each phase. Cost not judged.
* [Medium] `test/host/book_test.rb`: the design's tool tests "The whole book builds" and "Same bytes" are missing; no test runs cmark-gfm (two builds of the whole book were compared by hand and were identical).
* [Low] `tools/build_book.rb`: `--out build/site` replaces a built site with a book-only tree (both write the site's marker); two concurrent builds into one directory can fail with a bare `Errno` rather than `Erx::Error`.
* [Low] build, the native-jit copy's stamp (`tools/lib/erx/native_jit_runtime.rb`, `otp/erts/emulator/Makefile.in`
  `$(ASMJIT_PCH_OBJ)`): the stamp has no compiler version or clang resource-header identity, so after an LLVM
  upgrade moves the resource directory clang may refuse the old asmjit PCH and nothing restarts the copy
  (inferred, not checked against clang's source). Fix by construction: a PCH-inputs stamp file the PCH rule
  depends on, so OTP's make rebuilds the PCH itself.
* [Medium] tests, `test/host/erx_net_effect_test.rb:250` (`test_seeded_fault_fails_credit_counts_segments`)
  is timing-dependent: on a loaded host (a 610 s run) `erx_net_driver_tests` failed
  `dhcp_starts_when_the_link_comes_up_test` (line 383, `dhcp_sent(300)` saw `discover`) and timed out in
  `far_end_end_restarts_the_link` (`wait_gone/1`, line 427) before the seed's own failure, so the seed's
  expected name never appeared. The same tree passed in 456 s. The driver tests' fixed waits want to wait
  on the event, not a time.
* [Medium] build, the manifest checker's release artifacts (`tools/lib/erx/release_files.rb`
  `domain_artifacts`, `ProductionImage` `assemble`, `Release#build`): the archive's boot scripts
  and the `started` lists the checker reads agree only because both callers pass the same boots
  to both, and `domain_artifacts` compares only the scripts' names. Have the domain release's
  parts return their own artifacts, so what property 18's display client clause reads is what
  the archive boots by construction.
* [Low] build, property 18 (`tools/lib/erx/manifest.rb` `check_display_grants`): the converse of
  the display client clause, docs/design-display.md's "the display domain's release does not
  hold" `erx_win`, is checked nowhere; with `started` in the checker's context it is a few lines
  and a seeded test.
* [Low] tests, the manifest edits of the domain tests (`test/fixtures/manifest_context.rb`, `DOMAIN_ROWS`
  and `SESSION_FACETS`; `test/host/manifest_check_test.rb`, `dom_planner_test.rb` and
  `boot_manifest_test.rb`, their login_keys rows): each test removes the development manifest's
  configured domains and session grants through its own hand-written list of record patterns, so a new
  service or grant must be added to every list, and a list that files a row under the wrong kind fails
  only in the test that feeds it the other kind of source. Derive the removals from the manifest's
  structure instead, as `Manifest::Edit.without_sessions` already does for session grants: drop a
  configured domain with the services it serves and every facet granting them.
* [Medium] host tools, one build scaffold (`tools/lib/erx/raster.rb`, `rc_oracle.rb`, `fsimg.rb`): `source_record`,
  `locate` and its build record, `source_tree`, `compiler_identity` and `publish` are the same code three times.
  Fold them into one module that takes a source id and an output directory.
* [Medium] tests, the medium boot's device catalogue (`tools/lib/erx/medium_boot.rb` `DlDevices` and
  `DlDeviceView`): the expected devices are a hand-written copy of the site manifest's units, so a unit added to the
  QEMU `virt` platform breaks the `medium_boot` suite at whatever landing next runs it rather than in the change
  that added it. Derive the expected rows from the manifest compiler's normalized units and holders
  (`tools/lib/erx/manifest.rb` `unit_devices`, `unit_holder`), keeping literal only the ids and register window the
  suite sets up.
* [Low] development manifests (`tools/lib/erx/platform.rb` `manifest_source`, `config/manifest/`): a reader error in
  a board's composed manifest names the line of the joined text (`config/manifest:403`), not the file and line of
  `development.txt` or the board's part; pass the parts to `ABI::Syntax.parse` with their paths. The network
  domain's row is still written in each board's part because its `-erx_net interfaces` driver differs, a fact the
  platform record's net unit already states; deriving the driver would move the row to the common part. The
  measurements behind the common part's figures are in QEMU virt's part's comment, beside records it no longer holds.
* [Low] native_domain suite, the connection case (`test/guest/native_domain/guest.c`): its eval sits a few bytes under
  the boot page's 2,048-byte string limit (`boot_strings_max`), because every record's room is reserved at its
  longest; the `-erx_record` flag and the PATH word took it to the edge, and its names were shortened to fit. The next
  growth of boot words refuses its create with `EINVAL`. Move the eval's body into a module the guest loads, so the
  boot page carries only a call.
* [Medium] release slice, an empty `/data` (`include/erx/release_fs.h`, `liberx/release_fs.c`, `liberx/release.c`,
  `tools/lib/erx/pack.rb`, `tools/lib/erx/release_files.rb`): a domain the manifest grants no `data` facet has
  no `/data` mount and should find the root's empty, read-only `/data` directory there (design-files.md, "A
  facet's mount"), but the release slice cannot hold an empty directory: a directory is one only when some file
  path is below it, and a pack entry is a file or an image. So `/data` answers `enoent` and `ls /` does not show
  it. Give the pack index an entry kind for an empty directory (no data, prefix of no other path, which the open
  check already refuses), have the release file system's walk, lookup and listing answer it as a directory,
  extend the boot-image fuzz target and its corpus, and have the release write `system/data`.
* [Low] host tests, EUnit runs (`test/host/*_test.rb`): each test file starts `erl` for `eunit:test` on its
  own, and a logger report a case provokes can split EUnit's verbose line for that case on standard output.
  `erx_inspector_test.rb` sends the logger to standard error and matches verdicts on standard output alone;
  `erx_fs_test.rb`, `erx_ramfs_test.rb`, `erx_bt_group_test.rb`, `erx_line_test.rb`,
  `erx_console_reads_test.rb` and `erx_win_test.rb` silence the logger instead; the rest do neither. Give the host tests one EUnit runner that keeps the logger on standard error and returns the two
  streams apart, and move every suite onto it.
* [Low] tests, `test/fixtures/prog_profile_mutations.rb`: the rule helpers pass `[rule, value, reason]`
  triples and `places` passes `[kind, value, path]` triples; name them with `Data.define`.
* [Low] tests, EUnit cases under `test/erlang/` of this shape: after `monitor(process, P)` the
  case sends a third process a message or exit signal, with no signal to P, no other monitor and
  no blocking receive between, and then asserts P's exit reason. As in `erx_hostlink_tests`, P
  can end before the held monitor reaches it, and the case sees `noproc`. Candidates:
  `erx_console_master_tests.erl` (around line 330), `erx_domain_tests.erl` (around lines 179
  and 338). Wait for the monitor first, as `erx_hostlink_tests:monitor_in_effect/1` does; move
  that helper to a shared test module if more than one module needs it.
* [Low] tooling, `tools/lib/erx/erlang_apps.rb` (`check_modules`): an application's `.app.src`
  module list is compared with its `src/` only when a release is built, so `make check` passes a
  module added without its `.app.src` entry and every QEMU suite and `make check-boot-image`
  then fail. Run the same comparison for every application in `make check`, without building.
* [Medium] oracle log tree test (`test/integration/oracle_log_tree_test.rb`, `tools/lib/erx/oracle_hosted.rb`): the
  test assumes a /tmp cap of 160 MiB (`TMP_CAP`), but the hosted oracle takes the system
  domain's cap from the development manifest, 4 MiB, and runs its suites in /tmp/ct on it. Give the
  oracle's work directory a tree of its own, or derive `TMP_CAP` from the manifest.
* [Medium] benchmarks, `tools/lib/erx/bench_guest.rb` (`exchanges`, `transcript`):
  `tools/erx bench g3` times out at its `footprint` checkpoint on the development image,
  whose console starts root's session at boot. The `erl` line typed at the development
  warning starts the system domain's Erlang shell, then root's session takes the UART and
  its command shell reads the footprint expression (`rc: syntax error`). G3 has to say
  whose shell it measures (the system domain's, or the session's `erl`) and wait for that
  prompt before typing.
* [Low] host tests on FreeBSD, `tools/lib/erx/runner.rb`: the seeded-fault (mutant) binaries
  that abort by design dump core into the tree root (`mutant-*.core`, `page.core`,
  `object.core`; FreeBSD's `kern.corefile` is `%N.core` in the working directory), 17 files
  per `make check`. Test commands should run with `RLIMIT_CORE` 0.
* [Medium] build, the Raspberry Pi 4's card (`tools/lib/erx/boot_partition.rb`, `tools/lib/erx/bl31.rb`):
  `LICENSE.tf-a` is TF-A's `docs/license.rst` alone, whose BSD-3-Clause text carries only TF-A's placeholder
  copyright, and none of the notices of the third-party code BL31 links (TF-A's libc, libfdt, compiler-rt's
  builtins). The website offers the card, so BL31's link closure needs its notices beside the armstub, as
  the packer gathers them for the boot image (`NOTICES`).
* [Medium] build, the Raspberry Pi 4's card (`tools/lib/erx/boot_partition.rb`): `docs/design.md` ("Licenses
  and notices") says the same `NOTICES` sits beside the boot image in each slot's boot partition, but the
  card's layout has none beside `kernel8.img`; the production image's `NOTICES` is only inside the image
  (`system/NOTICES`). Write it into the boot partition, from the packer's notices, and have the card's test
  check it.
* [Low] build, `tools/lib/erx/source_revision.rb`, `tools/lib/erx/boot_partition.rb`: the `dirty` flag reads the
  tree by git's ignore rules, so a file that the checkout's `.git/info/exclude` hides but the build globs is not
  counted, and the card's record and the image's build facts read the revision at two times of one pack, so a
  file removed between them can leave a clean record. Derive the flag from the pack's own input catalog, read
  once per pack.
* [Low] build, the website (`.github/workflows/site.yml`, `tools/lib/erx/site.rb`): the card's record is checked
  against the commit the page links, but the demo image is not, though it carries the Fiasco kernel's GPL-2.0
  files; check the image's receipt against that commit the same way.
* [Low] build, `tools/lib/erx/boot_partition.rb` (`lay_out`) and `tools/lib/erx/build_facts.rb`: the card's record
  and the image's build facts each read the source revision, so a commit or stash during a pack can leave them
  naming different revisions. Read it once in `ProductionImage` and pass it to both.
* [Medium] build, the packer's `NOTICES` and `docs/design.md` ("Licenses and notices"): a file of
  erXos's counts as third-party for its notice when its SPDX line names a third-party license, but
  `erx_tcp_cc`, `erx_tcp_cc_newreno` and `erx_tcp_cc_cubic` translate BSD-2-Clause FreeBSD files, so
  their SPDX line is erXos's own `BSD-2-Clause` and their FreeBSD copyright headers may be left out
  of `NOTICES`. Classify erx_net modules by their `%% FreeBSD:` header lines (or NOTICE-freebsd)
  instead, and say so in the design; check what the packer does today first.
* [Medium] tests, a program's window (docs/design-files.md, Verification, "A program's window" and the
  cases after it): `test/erlang/erx_win_dev_tests.erl` covers the display's side over a real `erx_winfs`
  with the test as the tree's 9P client: the corpus as plain-name walks, a window removed and remade (its
  label checked, not its rectangle), a resize read through `ctl`, a killed connection, and the clipboard's
  fids. Still open: the corpus through a test program and the handler's resolver (`/dev/kbd/../ctl`,
  `/dev/./wctl`, `mkdir /dev/w1`), a `d` drawn after a resize and its present at the new size, the seeded
  trees that relay any name to the window's directory or walk each relayed open by name, the descriptor
  case, the refused-rectangle resize and the child case.
* [Medium] tests, `tools/lib/erx/programs.rb` (`pipe_hand`, `install`): no program in the programs
  suite waits on a pipe, so dropping the doorbell's bind from an install would leave every case
  passing, and only a refused bind (`install_refused`) is injected: a pass refused partway and a start's
  or an install's answer that cannot be allocated are not, nor is a check of what holds and copies
  remain after them. The QEMU tests of hand-offs between domains that the `erx_prog_handler` item
  names, with a program reading and writing its ends, establish them.
* [Low] QEMU harness, `tools/lib/erx/programs.rb`: the programs suite shows that `port_close/1` on a
  running program closes its port, reports nothing and gives back the gate worker's registrations,
  but not that the program's spaces stopped, since a close reports nothing to the session. Check
  the anchor's end with status `ERX_EXIT_SIGNAL` + SIGKILL from the session, through kernel trace's
  `space_end` (as `native_trace` reads a task's) or the inspector, once a session may read either.
* [Low] QEMU harness, `tools/lib/erx/programs.rb`: the suite packs its programs as file entries,
  which `erx_fiasco_task_image_map_body` copies into the space. docs/design-runtime.md, "Programs as
  ports", step 3 maps a boot-image program from its slice with its code shared, the image-entry path
  (`task_segment_share`), which no program of a session runs yet. Pack one as an image entry
  inside the domain release and run it.
* [Low] `tools/fuzz/lane_writer_fuzz.c`: the lane writer's fuzz target never puts an item marked
  `whole`; the channel's host test (`test/host/prog_channel_test.rb`) covers the all-or-nothing
  put, the whole-record need and the refusal of a record larger than the area.
* [Low] `test/host/prog_channel_test.rb` (`test_seeded_faults_are_caught`): the planted fault
  "the lock is let go of inside a frame" (`.whole = false`) is caught by case `two` only when its
  threads interleave inside a frame, so under a loaded full `make check` the case can pass on
  the mutant and the test fails. Make case `two` force the interleaving (a barrier between the
  frame's parts) instead of relying on timing.
* [Low] QEMU harness, `tools/lib/erx/programs.rb`: the inbound decision
  (`liberx/program/inbound.c`) is tested on the host only; no `programs` case sends a program a
  malformed later frame (a non-frame record, a nonzero zero word, a report past
  `ERX_PROG_REPORT_MAX` or one the profile refuses) and expects 127. Add one when the session can
  write a raw record to a program, or once `erx_prog_handler` sends reports.
* [Low] QEMU harness, `tools/lib/erx/programs.rb`: no programs case delivers a due notice as
  `{erx_channel, Port, Frame}`, since a frame that makes a notice due names a pipe end, which no
  program holds until `erx_prog_handler` installs one. The note cases cover the decode, the credit's refusals and a
  request's delivery, and the host credit test covers a notice's delivery; add a notice case with
  the first program that holds a pipe end.
* [Medium] tests, `tools/lib/erx/system_domain_regrant.rb`: the re-grant boot's connection room
  has no slack (`MORE_CONNECTIONS = 2`, root_1's session limits `connections 1`). After erts
  halts, each introduced pair row is freed only when its survivor lets go, so erts's next
  incarnation is introduced only because its boot outlasts that release; a slow survivor on a
  loaded multi-CPU cell would leave a grant at `none` and fail the cell. Wait for the old pair
  rows to go (or give the room one row of slack) if the cell flakes.
* [Medium] tests, `test/erlang/erx_domain_tests.erl` and the QEMU suites: design-system.md "A
  session's request" verifies the `machine` mint over `erx_domain_fake_lib` (a template the
  row grants gets one grant started with its principal's name, root's does not) and has a
  `machine_end` suite whose principal `clock` holds no grant. Neither is built: the
  session_domain suite's reboot boot covers root's session, whose grant names root, and a
  session without the grant is covered only by the shell's `no_facet` case in
  `erx_cmd_reboot_tests`.
* [Medium] SH1 check, `tools/lib/erx/command_needs.rb` (`SERVICES`): the hand-kept table lists
  `net`, `apps` and `machine`, the services whose facets commands declare, though
  design-shell.md says the check proves SH1 for every service; a command naming a module of
  `inspect`, `log`, `data`, `display`, `web` or a driver's control service passes, and a new
  service is covered only once someone adds its row. Derive the table instead: the manifest's
  `service` rows name a server domain and an interface, not the modules behind them, so the
  derivation needs one declared fact per service naming its server's modules. `inspect` and
  `log` also need their server modules told apart from the client modules of `erx` that every
  domain runs and the shell calls: `erx_inspector` is called by the commands `top` and
  `service` and by `erx_render` and `erx_shell_runner`, which are no commands, so listing all
  of `erx` under `inspect` would refuse the shell itself.
* [Low] tooling, `tools/lib/erx/erlang_apps.rb` (`APPLICATIONS`) and `release_files.rb`
  (`SYSTEM_APPLICATIONS`): the application order is kept by hand "in dependency order", and
  nothing checks it against the `.app.src` files' `applications`; systools quietly reorders a
  release that breaks it, so an application listed too early pulls its dependencies ahead of
  the applications before it in the system boot (as `erx_shell`, before `erx_code`, would pull
  `erx_domain` and `erx_starter` ahead of `erx_code` and `erx_uart`). Check that the order
  is a topological order of the `.app.src` dependency graph in `make check`.
* [Medium] packer, `tools/lib/erx/production_image.rb` (`build_test_image`): a test
  image's `domains:` is checked against no manifest row, since the test manifest is the
  development one grown. Build test images' domain boot scripts from their manifest's
  rows, as the production image does.
* [Low] test, `test/host/sanitizer_environment_test.rb`: TSan reports nothing for the racing program in about one run
  in five hundred with 16 runs at once, even with the two increments ordered in time and both threads alive; the
  test retries up to three times. Why TSan misses a plain unordered write pair is not known; find out before
  relying on a single TSan run to show a race.
* [Medium] sanitizer environment of host tests, `test/fixtures/sanitizer_environment.rb`: a test run directly with
  `ruby` gets the sanitizer policy and llvm-symbolizer only if it requires that fixture (through `generated_tree.rb`
  or directly) or passes `Erx::SanitizerEnvironment.call` itself. A new test that runs a failing sanitized program
  without either falls back to macOS's `atos`, which can hang until the test's deadline. Load the fixture from one
  place every test loads, or add a check that fails on a test with `-fsanitize` that reaches neither.
* [Medium] build memo, `tools/lib/erx/build_memo.rb`: a warm `check-qemu --suite medium_boot` still runs the native
  runtime builds (OTP make walks, about 25 s of steps: `runtime-emulator`, `runtime-preloaded`, the Erlang apps),
  the pack-time Fiasco audit (70 `fiasco-audit-member` steps) and about 40 s of the orchestrator's own Ruby
  (FiascoInputs hashes all 338 MB of `fiasco/` and its private copy on every build, `Runtime.source_digest` hashes
  `otp/` three times per image build, CompileMemo digests the system header trees once per `compile_all`). Key the
  runtime builds on `Runtime.source_digest`, musl, the sysroot's inputs, the host OTP and the compiler; cache file
  digests by (path, size, mtime, inode) with a racy-time check; run independent steps (the two runtime flavours,
  compiles) in parallel.
* [Low] build memo, `tools/lib/erx/compile_memo.rb`: a quoted include that climbs out of its includer's directory
  (`#include "../x.h"`) and was found through an `-I` directory is not keyed against a file of that name appearing
  above the includer, which would then come first; the native sources use none. Key each quoted include's name
  relative to its includer, or refuse to store a compile whose dependency names `..`.
* [Low] build memo, `tools/lib/erx/build_memo.rb`: `build/memo` grows by one entry per distinct compile and is never
  pruned. Drop entries no build has restored for some number of builds, or keep a bounded number per source.
* [Medium] build memo on Linux hosts, `tools/lib/erx/build_memo.rb` `REUSE`: the operating system's directories
  (`/usr/bin`, `/bin`) are named by the kernel's release, which on Linux does not change with a package upgrade, so
  on Linux the memo reuses nothing and every step runs (its reuse tests then fail). Name those programs by identity
  or by the package database's state, then enable reuse there.
* [Medium] build memo, `tools/lib/erx/build_memo.rb` `program_identity`: a program is named by its own install's
  `lib` directory, not by the libraries it loads from other packages (`cc1` loads Homebrew's isl, mpc, mpfr, gmp,
  zstd), and `/usr/bin`'s Xcode shims (`gcc`, `cc`, `m4`; the Fiasco kconfig's `HOSTCC = gcc`) are named only by
  the macOS release, not by the active developer directory. Key each program's load-command closure (`otool -L`,
  `ldd`) and `xcode-select -p` with its clang, or point the inherited build's host compiler at the keyed clang.
* [Low] build memo, `tools/lib/erx/compile_memo.rb`: clang leaves out of `-MMD` a header included under
  `#pragma GCC system_header` and an `-I` header a system header probes with `__has_include`; the system trees are
  digested once per `compile_all` and a dependency's change during a compile is caught by mtime only; two builds
  storing one key race (`Errno::ENOTEMPTY`). Switch the memo to `-MD`, re-digest before storing, and treat a lost
  rename as success; none of these arise in the tree today.
* [Medium] tests, `test`: the `medium_boot` suite's `release-shell` checkpoint timed out on the first run after a
  fresh tree twice (master ee3bfe47 and branch mb-incr), the 1-CPU boot's serial log showing the shell's banner
  interleaved with the domain ERTS's "hold executor slots" line; the next runs passed. Find whether the checkpoint
  needs a whole line that concurrent console writers can split.
* [Medium] build tree of generated files, `tools/lib/erx/generated.rb`: `tools/erx`'s entry `ensure` releases
  `build/gen.lock` before any compiler runs, so the long readers that follow do not hold it: the hosted liberx
  compiles and OTP's make with `-I$(ERX_GEN)` in `runtime.rb`, the fuzz compiles, the test pool's compilers, the
  Fiasco input capture, and `Checks#generated_sources`, which lists the tree after its `ensure` returned. With a build
  running in one terminal, an edit to a generator's input followed by any `tools/erx` command in another regenerates
  the tree under it, and `swap`'s two renames leave no `build/gen/` between them: a compile fails with `ENOENT`, or,
  silently, the chokepoint listing finds no or few generated files and `Chokepoints.enforce` passes having checked
  less. A translation unit that opened one generated header before the swap and resolves another after it compiles
  against two trees at once, which still builds while the two agree on types. The Ruby loaders
  (`Erx::Generated.require_ruby`) already read under the lock. Fix: have `ensure` return a tree value that the
  libraries take, over versioned, never-rewritten trees (`build/gen.d/<digest>` behind a link replaced by rename,
  each resolved once per build), or have long readers take the lock shared (a `Generated.reading(root:) { |tree| ... }`
  section); and take the chokepoint listing from the stamp's outputs, refusing a missing file.
* [Medium] build tree of generated files, `tools/lib/erx/generated.rb`: whether `build/gen/` is current when a
  compiler reads it rests on the process entry having run `Generated.ensure` (tools/erx before it loads its
  libraries, `test/fixtures/generated_tree.rb` in tests, each standalone script), because `Generated.path` and
  `include_flags` are pure functions of a root. A test or script that skips it compiles against a stale tree. Make it
  hold by construction: ensure returns a tree value (output root, paths, include flags, the stamp's outputs) that
  build libraries take instead of a root, or readers check the stamp (no regeneration) and refuse a stale tree.
* [Low] build tree of generated files, `tools/lib/erx/runtime.rb`, `core_archive.rb`, `test/host/*_test.rb`: the
  generated tree's include directories are spelled out by hand in each FLAGS constant (`-I build/gen -I
  build/gen/include ... -I build/gen/kernel/generated`) and in host tests beside `Generated.include_flags`. No file
  of the tree sits at a generated path (`Generated.ensure` refuses one), so their order decides nothing; derive
  every list from `Generated.include_flags` and drop the repetition.
* [Low] host tooling, `tools/lib/erx/` (QEMU suites and harnesses, e.g. `medium_boot.rb`, `native_irq.rb`,
  `deterministic_transcript.rb`): about a dozen error and verify messages quote guest text with `String#inspect`
  instead of `Erx::Terminal.escape`, the host terminal's one escaping function. `inspect` escapes control bytes, so
  nothing reaches the terminal raw, but the one-escaper-per-sink rule holds only by convention; route them through
  `Terminal.escape` and add a chokepoint check.
* [Medium] tests, `test/host/erx_littlefs_test.rb`: the NIF runs uninstrumented in the stock
  runtime. A loaded NIF under AddressSanitizer needs `DYLD_INSERT_LIBRARIES`, which the
  development host's sandbox strips from every child; on a host that passes it, build the
  library with `-fsanitize=address,undefined` and run `beam.smp` directly with the runtime
  inserted. littlefs itself runs under both sanitizers in `tools/fuzz/lfs_image_fuzz.c`.
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
* [Low] tooling, `tools/lib/erx/libc_test.rb`: libc-test's tasks link liberx's clock
  (`liberx/backend/fiasco/arch/aarch64/clock.c`) through their own generated Makefile with
  `--strip-all`, not through `NativeRoot#build`, so `CounterReads` never reads them and
  could not name the function in a stripped program. Link them through `NativeRoot`, or
  run the check before stripping.
* [Low] tooling, fetched source paths: `tools/lib/erx/libc_test.rb:24` spells libc-test's
  unpacked directory (`libc-test-63e36e9`) by hand, so a pin bump in `deps.lock` fails it with
  a missing-file error, and it reads the tree without checking its provenance record. Route
  it through `Dependencies#fetched_tree`, which has no other caller until then;
  `RcOracle::Build#source_tree`, `Raster`'s `source_tree`, `MemdrawBuild#ninefront_tree` and
  `SiteV64.fetched` each repeat the same check of `.source.json` by hand.
* [Low] tooling, `tools/lib/erx/libc_test.rb:158,270-279,454-457`, `tools/lib/erx/setup.rb`: (1)
  Every serial line between a test's run and end lines that matches `FILE.c:N: ` is
  attributed to that test, including kernel or root C output; a spurious disagreement, never a
  false pass. Require the `src/` path form `t_error` prints. (2) The libc-test make rules
  depend on sources only, and `forget_programs` deletes only `.elf`, so objects built under old
  `FLAGS` are reused; hash the flags into the rule or delete the objects when they change.
  (3) `setup.rb`: the source steps' `deadline: 300` is never used. (4)
  `leftovers` reads the flavour out of `step.argv`;
  store it on `Step`.
* [Low] `tools/lib/erx/interpreter_image.rb`: the check reads the linked program's symbol table, so a link that
  discards locals (`-x`, hidden visibility turned local) could hide C++ while keeping `erl_start`. The root's link
  strips debug information only. Check the link's input list (LLD's `--trace`) as well, which no stripping changes.
* [Medium] `test/guest/native_irq/guest.c`: the line's unbind and rebind come before the first typed character, so
  nothing checks that a line still fires after it was delivered, acked, detached and attached again. Type a third
  character after the rebind and add its checkpoint to `tools/lib/erx/native_irq.rb`.
* [Low] `test/guest/function_api/cases.c`: the hosted function-API binary exits 0 when a case prints `FAILED`, so only
  `hosted_function_api_test.rb`'s comparison against the expected lines catches a failure. Exit nonzero when any case fails.
* [Low] `tools/fuzz/boot_build_target.rb`: the boot fuzz targets do not require that any input is accepted, so a target that
  refuses everything passes, and the script copies the limits layout by hand rather than from `abi/erx_abi.txt`.
* [Medium] `libc-test` on native Fiasco, `tools/lib/erx/libc_test.rb`:
  `regression/malloc-brk-fail` passes at 4 CPUs and runs past 60 s at 1 CPU
  under TCG, cause not found, so it is out of the canary set, and
  `check-libc-test tcg 1` would fail on it. Every test has a verdict at 4 CPUs
  under TCG (`test/conformance/libc-test-verdicts.txt`; `~/erxos-history`
  `f6d3e4a`, `libc-test/2026-11-05-tcg-4cpu`); runs at 1 CPU and under HVF
  have not been held to the table.
* [Medium] tools, `tools/lib/erx/pack_provenance.rb`: a `compiled` receipt declares its sources and names no `.hrl`; nothing ties a beam to them, and a `release` pack accepts it. Derive them with `erlc -M`, and hold them under a registered import.
* [Medium] tools, `tools/lib/erx/release.rb`: `boot_file` puts paths into an Erlang expression, so a checkout path holding `"` or `\` breaks or changes it. Pass them with `-extra`.
* [Medium] tools, `tools/lib/erx/production_image.rb`, `Run.record_words`: it predicts the root's device records with a second copy of `devices_read` (`liberx/backend/core/boot_manifest.c`), reading `include/erx/device_kinds.h` by pattern, and counts no record for a framebuffer row the system domain holds, whose record depends on the firmware's tree. Take the count from the root's own record walk over the manifest (the host build `boot_manifest_test.rb` runs prints the records) and delete the copy.
* [Low] tools, `tools/lib`: about 75 `FileUtils.mkdir_p` calls make directories without `OutputDirectory`, so a file in the way (on macOS also one whose name differs only in case, as `build/fiasco/NOTICES` for `notices`) fails with a bare `File exists` instead of naming it. Sort them into staging directories inside a `mktmpdir`, which are safe, and build output directories, which go through `OutputDirectory.prepare`; a chokepoint check could then refuse a new direct one.
* [Low] tools, `tools/lib/erx/boot_image.rb`: `BootImage#build` removes its directory before `OutputDirectory.prepare` checks the path, so a `build/` that links out of the tree has the linked directory removed. Clear it through a check first, as `ProductionImage.clear_directory` does, with a test like `production_image_test.rb`'s link test.
* [Low] tools, `tools/lib/erx/boot_image.rb`: it requires `test/fixtures/structural_pack.rb`, which loads the sanitizer environment, so requiring `erx/native_task` from host tooling raises unless `ERX_CLANG` names a clang with `llvm-symbolizer` beside it. Move what the image build needs out of the test fixture into `tools/lib/erx`.
* [Low] tests, `test/integration/runtime_console_test.rb` (`make check-runtime-hosted`): the cases that start the Erlang shell wait for `1> ` at the start of a line, but the hosted system domain is a named node and its shell prompts `(system@erxos)1> `, so every `with_erxos` case times out before it begins. Match the prompt with its node name, or make the patterns node-agnostic as the `Ctrl-G` case is.
* [Medium] tooling, configured-domain ids in the QEMU harnesses: `MediumBoot` (`NETWORK_ID`, `STORAGE_ID`, `DOMAIN_IDS`, `FREE_ID` and the catalogue rows of `DlControl` and `DlDevices`), `SystemDomain`, `SessionDomain::FIRST_SESSION`, `Regrant` and `DeviceGive::RESTART_ID` each re-derive by hand that configured domains boot in name order and that each later create spends an id, so adding a configured domain edits six files. Derive every id and row from one helper that sorts the manifest's configured domain names with the cell's added rows.
* [Low] test, `erx_erofs`: the fixtures fsimg writes hold no hard link (fsimg writes none), no chunk-based
  file (incompatible bit 0x4, which the reader refuses) and no regular file in the plain layout with a
  partial last block, so no case reads a shared inode (nlink 2) or checks the chunked refusal or that
  tail; each can be made by patching `compact.img` in the EUnit cases and fixing its superblock checksum.
* [Medium] test, F2FS listing (`test/erlang/erx_f2fs_listing.erl`): cost grows faster than the tree on
  hostile shapes. Each entry of an inode with K names carries its K-path link class, so K names cost
  O(K^2) once the listing is copied or compared (3,000 links to one inode: about 500 MB flattened); a
  class representative (the least stated path) would make it O(N) but changes the decided form. Each
  entry holds its whole path, so a directory chain of depth d costs O(d^2) (depth 4,000: about 640 MB);
  a bound on a path's joined length, refused in the walk, would cap it. A regular file is hashed once
  per name, not per inode, and no listing bounds the bytes it folds, so a sparse file of F2FS's
  largest size, or many links to it, ends only at the test's deadline.
* [Medium] test, F2FS corpora (`test/erlang/erx_f2fs_corpus_tests.erl`): the corpus test checks
  features and segments per section, not `-a` or `-e cold`. The codec's fuzz target takes its
  superblock and checkpoint seeds from the corpus images, but not yet their NAT, SIT, summary, inode
  and dentry blocks, which design-f2fs.md's "Reading the medium" asks for and which wait for stage 2's
  walk of each image's trees. The corpus seeds add few shapes: every image's packs are header-only
  and none sets `SB_CHKSUM`, so weighting distinct shapes rather than images would serve better.
* [Low] test, F2FS corpus reader (`test/erlang/erx_f2fs_corpus.erl`): the zstd context sets no
  `windowLogMax`, so a hostile frame can make it allocate zstd's 128 MiB window cap; a file's form is
  derived from its source id's prefix, which a third form would want in its deps.lock row; no case
  covers bytes after a stream's end; and the fuzz runner, unlike the corpus test, does not check
  `fetched?` first, so an unfetched corpus fails as `{file, enoent}` without the fetch command.
* [Low] test, F2FS listing's `file_reader/1`: OTP's file_info holds `st_rdev`, `st_dev` and `st_ino` in
  32 bits (`otp/erts/emulator/nifs/common/prim_file_nif.h` l.87-89), so a device whose major or minor
  needs the high bits of a 64-bit `dev_t` decodes to another number, and on a host file system with
  64-bit inode numbers two inodes equal modulo 2^32 share a link class; trees of F2FS (32-bit nids)
  and devices with small numbers are not affected. The listing module's lines exceed 80 columns.
* [Medium] test, F2FS oracle: erXos's F2FS is checked against Linux's, which needs a Linux guest under QEMU
  with a pinned v7.3.4 kernel that has F2FS (Debian's generic arm64 kernel is the candidate to check;
  Ubuntu 26.04's is 7.0.0) and f2fs-tools 1.16.0. Neither the guest nor its pins exist.
* [Medium] test, F2FS distribution guest
  ([design-f2fs.md](design-f2fs.md#the-distribution-guest)): the probe booted Ubuntu 26.04's arm64
  cloud image under Lima, not under the oracle guest's QEMU runner. Settle by probe before building on
  them: that image boots under QEMU with UEFI and a cloud-init seed fsimg makes; `flakey` drops writes
  after a chosen point as the Linux cut needs; which other distributions package f2fs-tools with an F2FS
  kernel; that Homebrew has no f2fs-tools formula and Apple's container kernel has no F2FS, which the
  design states as unverified; xfstests' `replay-log`: its pinned commit, and that it builds in the guest
  and replays a `log-writes` log onto a snapshot up to a chosen entry; and syzbot's F2FS images, by URL and
  SHA-256, for the fetch manifest.
* [Low] test, pjdfstest over erXos's file systems: pjdfstest (FreeBSD `contrib/pjdfstest`, BSD-2-Clause)
  built for erXos's POSIX layer and run under QEMU over `/data` on F2FS and littlefs
  ([design-f2fs.md](design-f2fs.md#posix-suites)); whether the POSIX layer offers every call it
  makes is unverified.
* [Medium] test, `test/integration/runtime_prim_file_test.rb`: the open-file cases (`OPEN_FILES`) are
  hand-written expectations rather than the same calls run on stock over a local directory, which the
  oracle rule asks for. Known differences from stock: `position(Fd, {bof, 1 bsl 64})` answers `einval`
  where stock answers `badarg`; a `pread` at a negative offset through a write-only descriptor answers
  `ebadf` where Linux answers `einval`; `read_file` of a file whose `getattr` size is 0 answers `<<>>`
  where stock reads to the end.
* [Low] test, `test/host/space_test.rb`: `test_the_drops_of_a_hold_race_under_thread_sanitizer` fails on this host:
  the seeded relaxed drop exits with an error, but its log holds no `ThreadSanitizer: data race` line (the
  assertion reads an empty log). Seen twice in a row on Apple Silicon macOS with Homebrew LLVM 23.1.3, under
  `make check` and alone. Find whether the log path or TSan's report is missing before trusting the seeded race.
* [Low] Oracle, pid text (edit 18): OTP cases that write a local pid as `"<0.N.S>"` get `badarg` in a runtime
  that is alive with a nonzero creation: compiler `core_fold_SUITE:coverage`, emulator `guard_SUITE:guard_bifs`
  and a case of stdlib `qlc_SUITE`. The hosted runtime is not alive, so they agree there; give them rows in
  `test/oracle/hosted_known_differences/` once an oracle run's runtime is a node.
* [Low] Page funnel tests, `test/host/page_test.rb` and
  `tools/fuzz/page_fuzz.c`: the drivers cannot see a reserve's pool chain,
  so they count pooled pages by exclusion and never walk the chain; and
  neither drives a take or release of a reserve while its own backing is
  under way, or a release the reserve cannot cover (refused before the
  core in the fuzz target). `erx_page_release` repeats
  `erx_reserve_refund`'s count checks so that the refund cannot fail after
  the append; one predicate exported by the budget core would keep them
  one.
* [Low] test, `runtime_console_test.rb`'s nested shells rest on a 300 ms
  sleep for which `run_shell` call comes first; under load the inner
  shell may start first and the case checks inner-first ending instead
  of outer-first. Have the first shell's start function tell the
  evaluator it runs before the second starts
  (`test/integration/runtime_console_test.rb`).
* [Low] architecture, security claims: distinguish immutable executable
  memory from the stronger file-source claim: no grant carries `rw` and
  `rx` together, but a program may hold both on one file through two
  grants, so "a program never runs what it could rewrite" holds per grant,
  not per file ([design.md](design.md#trust-placement),
  [design-files.md](design-files.md#invariants)).
* [Low] build, stack proof: confirm that lld's `--emit-relocs` keeps the
  call and jump relocations that the stack proof decodes
  ([design-arch-aarch64.md](design-arch-aarch64.md)).
* [Medium] build, stack proof: LLVM 23 resolves a `bl` to a static
  function in the same section without a relocation, which the proof
  refuses, so the proven C must be compiled with `-ffunction-sections`
  (and no shared `section` attribute). The stack-proof passages of
  [design-kernel.md](design-kernel.md#stack-proof),
  [design-arch-aarch64.md](design-arch-aarch64.md#stack-proof) and
  the cores' build flags in [design-fiasco.md](design-fiasco.md)
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
* [Low] build, stack proof: declarations that nothing uses are accepted
  silently: a `kernel/stack_targets.txt` line whose function holds no
  indirect site at either level, and a `leaf` of `kernel/stack_fiasco.txt`
  that a core defines itself. Report them after both levels have run.
* [Medium] build, stack proof: the Fiasco proof's entries are every
  exported function of the cores' archive (`tools/lib/erx/core_archive.rb`),
  a superset of the ones the kernel image references
  ([design-fiasco.md](design-fiasco.md)). Read the entries from the
  linked kernel's references to the archive instead, which needs the proof
  to run after the link as well as before it.
* [Medium] build, Fiasco's bootstrap: `kernel/core/pack.c` is left out of
  the kernel's archive (`CoreArchive::BOOTSTRAP_SOURCES`) but is not yet
  linked into `bootstrap`, since nothing there calls it until the boot
  handoff ([design-fiasco.md](design-fiasco.md#boot-handoff)) is
  written. That package builds a second archive of `pack.c`, the image
  planner `liberx/image_plan.c` it checks image entries through, BLAKE3's
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
* [Low] build, import inventory (`tools/lib/erx/pack_provenance.rb`,
  `PackProvenance#imported_item`): a file captured after its tree's
  `Origin#check` takes its `changes` row's license without comparing the
  row's hash to the captured bytes; one Origin reader that returns a row only
  for the bytes it records would serve this, `FiascoProvenance#attribute` and
  `Glyphs` alike.
* [Medium] build, notice check (`tools/lib/erx/pack_provenance.rb`,
  `attribute`; `tools/lib/erx/import_notices.rb`, `select`): the check that
  a selected import grant has a notice document looks at the whole
  expression, so `<covered> AND <uncovered>` passes with no document for the
  second grant. ChaCha20's `LicenseRef-DJB-public-domain` passes this way,
  rightly, since its notice is the header `leading_notice` keeps; a
  per-grant check must state what a file's own header counts for, and may
  find other imports short of rows.
* [Low] build, notice check (`tools/lib/erx/pack_provenance.rb`,
  `attribute`): a file of erXos's own that declares `BSD-2-Clause AND
  Unicode-3.0` (`build/gen/erlang/apps/erx/src/erx_text_tables.erl`,
  `build/gen/tools/generated/terminal_tables.rb`) takes the non-import branch, which
  attaches only `LICENSE` and the file's header and never reads the notice
  profile, so the checked `Unicode-3.0` document does not reach its notice.
  Unverified that these files reach a packed image's records; if they do,
  look up the profile for the selected grants other than erXos's own.
* [Medium] build, license selection (`tools/lib/erx/license_expression.rb`,
  `PERMISSIVE`; `display/font/fixed/ORIGIN.md`): the fixed fonts' grant,
  `LicenseRef-misc-fixed-public-domain` ("Public domain font.  Share and
  enjoy.", X.Org's `misc-fixed` `COPYING`), is not on the permissive list,
  so the first release that packs `display/font/fixed/6x13.*` (the session
  release of `erx_term`) fails with "license expression has no permitted
  grant". Accepting it, with a case in `test/host/license_expression_test.rb`
  and a notice row if `import_notices.rb` wants one, is a license decision
  to make with that release.
* [Low] build, license selection (`tools/lib/erx/license_expression.rb`,
  `PERMISSIVE`, and `PackProvenance#attribute`): the entries for ChaCha20's
  public-domain statement and public_key's RSA notices are global, so a
  file outside any import that declares `LicenseRef-DJB-public-domain`,
  `LicenseRef-RSA-PKCS3` or `LicenseRef-RSA-PKCS5v2-0` passes a release pack
  with erXos's `LICENSE` as its notice. Refuse them outside an import.
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
  licenses (ChaCha20's public domain) or Colin Percival's notice, and
  BLAKE3 (`Apache-2.0 WITH LLVM-exception`, no BSD-2-Clause line) blocks
  the record as soon as the Fiasco kernel links it. Attribute
  every file under a directory with an `ORIGIN.md` through that origin's
  inventory, as the fork parts are, never through the header rule, and
  test it with a captured-inputs fixture.
* [Medium] build, compiler identity: several paths that build Fiasco, an
  image or a QEMU guest read `ERX_CLANG` (and `ERX_LLD`) themselves
  instead of taking what `host_environment` resolved: `tools/erx build
  fiasco` and `BootImageCheck` in `tools/erx`, `Fiasco`'s default compiler
  (`tools/lib/erx/fiasco.rb`), `interactive_boot.rb`, `medium_boot.rb` and
  the `native_*.rb` harnesses. Have them take one toolchain value from
  `host_environment` (absolute clang and lld and the LLVM header
  registry) in place of raw `compiler:` and `linker:` strings, so the
  seven `-print-resource-dir` lookups become one. Separately, the
  recorded clang hash is the driver's, not `libclang-cpp` and `libLLVM`,
  which hold the code generator; hash the linked libraries.
* [Low] build, supported compilers: decide which compilers and versions
  erXos supports (LLVM for erXos's code and for Fiasco) and state them
  in README's Host setup. Nothing checks a
  compiler's version until then; release images are built with exactly
  LLVM 23.1.3 (docs/plan.md, M11).
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
* [Medium] build, the glue in Fiasco: the design compiles the glue with
  `-fstack-usage` and checks it (B2, B3, B9, B11);
  `fiasco/kernel/src/erx/erx_handoff.cpp`, the glue, gets only
  `ERX_GLUE_CXXFLAGS` (`fiasco/kernel/src/Makeconf`). The glue checks
  package adds the flag beside the include path.
* [Low] build, configuration check: `tools/lib/erx/fiasco.rb` checks the
  resolved `globalconfig.out` before the kernel make, whose own rules can
  rerun `oldconfig` or `syncconfig` (`fiasco/kernel/src/Makefile`). Today
  a changed source recreates the build directory, so nothing rewrites the
  checked file; check the configuration the built kernel embeds
  (`.debug.fiasco_config`, `Makeconf`) after the make as well.
* [Medium] build, stack proof: `kernel/stack_targets.txt` declares no stack
  use of assembly routines, and the proof checks no declared use against
  the routine's stack-pointer adjustments
  ([design-kernel.md](design-kernel.md#stack-proof)). The cores have no
  assembly; erXos's kernel needs both.
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
* [Low] host tooling, the build memo (`tools/lib/erx/build_memo.rb`):
  records are reused only on macOS, whose sealed system volume the
  system release names; on FreeBSD every step runs, so a second Fiasco
  build of an unchanged tree runs its commands again. FreeBSD's base
  programs change with a world install or pkgbase upgrade under the
  same `uname` and `freebsd-version -u` on a -CURRENT host; reuse there
  needs the base programs and their libraries named by content, and the
  helpers a package runs by unversioned path (`/usr/local/lib/perl5`), which `directory_identities` does not name;
  Homebrew's versioned Cellar paths name them by path.
* [Low] host tooling, the Fiasco build (`tools/lib/erx/fiasco.rb`, `memo_key`): a
  perl that is a version-manager shim (plenv, mise) goes on the build's PATH
  as such, so the key names the shim, not the interpreter it picks, and
  switching the global perl leaves a stale hit on macOS.
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
* [Medium] build gates, `test/integration/fiasco_reproducible_test.rb`: it is the
  test that builds the Fiasco kernel twice and compares the results, and
  `make check` skips it as a standalone test, but no make target runs it,
  and `make check-reproducible` builds the kernel once and packs that one
  build twice. Give it a gate, or make `check-reproducible` rebuild the
  kernel.
* [Medium] build gates, the published media and the Doom example
  (`ProductionImage::MediumKind.published`): only `tools/erx pack
  --published` (`make pack`) builds the published QEMU medium and the Pi 4
  card with `/bin/doom`; the raspi4b suite and `make check-reproducible`
  build the development kind of those media, on the same machines, the platform records' own
  (`ProductionImage::Machine.development`), but without Doom, so no gate proves that the media as published
  still pack, fit their machine and build reproducibly. Give one gate cell a
  fetched Doom fork and have it pack both published media with Doom.
* [Low] tests, `test/host/erx_starter_test.rb`: the suite takes about 4.5 minutes, most of it seeded fault 0 (the keeper not linking), under which nearly every case waits out EUnit's 5 s timeout. Fail the fault's cases fast instead of by timeout.
* [Low] tests, `liberx/system/dom_args.c` (`args_given_words`): no host test checks the record words written for a framebuffer handed to a domain other than the system domain; placement, the apply steps and `erx_boot_framebuffer_words` itself (`boot_manifest_test.rb`) are tested, and the raspi4b suite's tcg-4cpu cell, one QEMU boot under TCG, checks the display domain's record through its driver's framebuffer line and, for the base and offset, only through its picture.
* [Medium] fuzz, `tools/fuzz/erx_device_record.rb`: the target fails on the module as it is, before
  any mutant runs, with `{too_few_accepted, 159, 648, 482}` at seed 1: its generator
  (`test/erlang/erx_device_record_fuzz.erl`, `entry/0`) finds an accepted device record in 159 of
  20000 rounds, under the floor of 200 (`MIN_ACCEPTED`). The generator's well-formed device entries
  no longer match the record's shape often enough; make them do so, rather than lower the floor.
* [Low] release files, the start-order property where releases are written (`tools/lib/erx/release_files.rb` `release_entry`):
  the check is a host test over `RELEASE_SCRIPTS`, so test images' domain scripts are not covered. Refusing where the release
  file is written would cover every script.
* [Low] qemu, reuse keys a run's inputs in two calls (`tools/lib/erx/qemu.rb` `Qemu#run`, `boot_key`): an input
  `DETERMINED_INPUTS` lists as `:any` must reach both the local `QemuPlan.argv` call and `boot_key`'s keyed one; one passed to
  the first and forgotten in the second replays a stale pass. Build the keyed plan from the hash `run` passes to `argv`, with
  paths by digest, so there is one call to keep.
* [Low] qemu suites, the shared shell helpers: `PcieDomain::WAIT` and `PROMPT` serve the pcie, usb and Bluetooth suites. They
  belong in a shared home.
* [Medium] `tools/lib/erx/medium_boot.rb` `Footprint`: `LoadOnly` is prepended to `ReleaseFiles` as a whole, so the configured
  storage and network domains of the footprint image boot with erx_blk and erx_net only loaded; check whether the storage domain
  fails at boot there (erx_storage needs erx_blk started) and whether the cell's figures assume it.

## Security residuals

* [Medium] build, a link's input list (`PackProvenance.link_inputs` in
  `tools/lib/erx/pack_provenance.rb`): the list has no end record and names no artifact, so that it
  is whole and belongs to the link the audit reads rests on each of its writers
  (`fiasco/kernel/src/Makerules.KERNEL`, `fiasco/mk/mk/prog.mk`, `NativeRoot#build`) renaming or
  binding it only after a link that succeeded. A list cut at a line boundary passes the reader, for
  instance if LLD exits 0 after a failed write to standard output (inferred, not shown). One link
  wrapper that appends an end line with the output's hash, which the reader requires and the audit
  checks against the artifact, would make the property hold by construction.
* [Low] build, the license audit of Fiasco's links (`FiascoProvenance#audit_executable`): LLD's
  `--trace` names no linker script (`-T`, `INCLUDE`), and a script can put bytes into the output.
  NativeRoot names its script in the receipt's `inputs`; check that Fiasco's audit attributes the
  kernel's, bootstrap's and sigma0's scripts, and add them if it does not.
* [Low] build, git started by host tooling (`tools/lib/erx/fiasco.rb`, `submodule.rb`, `source_revision.rb`):
  each site builds its own argv, so "git runs no program a repository names" holds only where someone
  remembered it. `Fiasco#import_git`'s `git archive` runs plain `git` in the Fiasco clone, applying the
  filters its attributes and configuration name (the archive's SHA-256 catches altered output, not the
  filter program running). One argv constructor in `GitEnvironment` (fsmonitor off, no pager, no lazy
  fetch, the isolated environment) with a build check that no other `'git'` argv exists would make it hold
  for every site.
* [Medium] `tools/erx web --open`, [The host tool's front end](design-web.md#the-host-tools-front-end): not
  built, because handing the URL to the host's opener (`open`, `xdg-open`) puts the token in an argument vector,
  which `ps` shows to every user of the host. A channel that keeps it off the command line is needed first, for
  example an owner-only file whose page forwards to the URL, opened by its path.

* [Medium] tests, the system_domain suite's 4-CPU cell under TCG on the second host
  (`tools/lib/erx/system_domain.rb`): under that host's load (load average about 25) the
  service-kill boot failed at `echo-facet` with the system's Erlang shell ended at 31 s: `group` called
  `shell:prompt_width/1`, which passed `{error, timeout}` from the terminal's options to
  `proplists:get_value/3` (function_clause), so the shell died under the long typed line. The cell
  passes under HVF. Make the shell take an options timeout (stock OTP's `shell.erl` has the same
  code, so check it against stock first).

## Planned features

* [Medium] `make check`: no check finds a call to a function no module exports. A removed export with a live
  caller in another application survived to a QEMU run before; the host tests load only the modules they name,
  so a caller outside them compiles and fails only at run time. Add `xref`'s `undefined_function_calls` over
  every application the images ship, compiled as the build compiles them, with OTP's own undefined calls taken
  from the stock oracle's modules, and a seeded fault: an export removed while a caller in another application
  stays.

* [Medium] tools, two copies of the root's physical record selection: `physical_paths` and `held_record_words` in
  `tools/lib/erx/production_image.rb` restate `device_kind` and `line_uart_read` of
  `liberx/backend/core/boot_manifest.c` for `record_words`, so a new physical record kind changes both and only a
  production boot's `erts-start` checkpoint compares them. Count from a host build of `devices_read`.
* [Low] origin check, `tools/lib/erx/origin.rb`: a `removed` entry may name a license or notice file
  (`COPYRIGHT`, `LICENSE*`, `NOTICE*`) or one that rows cite as evidence, which the no-deletion rule protected;
  refuse such a removal.
* [Medium] SDK boundary check (`test/erlang/erx_sdk_boundary.erl`; D1 in
  [design-desktop-programs.md](design-desktop-programs.md#verification-and-testing), and the SDK's boundary row of
  [design-packaging.md](design-packaging.md#verification-and-testing)): a call handed to stock OTP as data, a
  `{Module, Function, Args}` to `proc_lib:spawn/3`, `timer:apply_after/4`, `erpc:call/4`, a child spec's `start`, or
  `erlang:make_fun/3`, reaches neither of `outside/2`'s lists, since xref resolves such triples only for `apply` and
  `spawn`; and a pinned variable call is pinned per caller function and callee shape, so a second call of the same
  shape in that function passes, and a caller may match `{[], _}` and drop the variable half. Close it by
  construction: refuse a literal atom naming a non-public erXos module and the atom-making BIFs, put each pinned call
  alone in a one-call function (the window's worker can dispatch its effect through a local function, which removes
  its `worker/4` pin), and have the check take the reviewed list and answer one list of violations.
* [Medium] tooling, fsimg's append mode (`~/projects/fsimg`, pinned in `deps.lock`;
  [design-ssh.md](design-ssh.md#verification)): fsimg has no mode that adds a file to an existing image
  (its modes are `c`, `x`, `t`, `W` and `i`, `docs/fsimg.1`), which the downloadable-medium row needs to add
  `authorized_keys` as a user's computer does. Add an append mode, as tar's `r`, that adds a file to an
  existing FAT volume, whole or as a partition of an MBR disk, allocating only free clusters and keeping
  every other byte; tests in fsimg's suite: `fsimg W` accepts the result, a second extraction gives every
  earlier file unchanged, and an append to a full root directory is refused. Then repin fsimg in `deps.lock`.
* [Medium] fuzzing, UTCB call decoding: `fuzz/generated/abi.c` decodes
  every shipped call with a UTCB built from the input, but no shipped call
  takes a UTCB parameter yet, so the decoder's word copy, uncovered-byte
  checks and aggregate field checks reach libFuzzer only through the
  host probe of `test/fixtures/abi_call_marshal.txt`. Have `check-fuzz`
  also build the generated harness against that fixture, or land the
  first UTCB call with its fuzz run
  ([design-abi.md](design-abi.md#kernel-calls-and-bindings)).
* [Low] conformance harness details (`tools/lib/erx/conformance.rb`): hash
  and boot one copy of the image, so a rebuild during the matrix cannot
  mix images; show each failed configuration's reasons on the terminal,
  not only in its report; split protocol lines on single spaces exactly.
* [Medium] bench, track K's first guest measurements (`tools/erx bench timer`, `stop`,
  the null call, IPC, park and wake, boot time): they reuse the conformance
  harness's boot, deadline and guest endings, with results kept per
  accelerator ([plan.md](plan.md#track-k-erxoss-kernel)).

* [Low] tools/erx, mounting an erXos server on the Mac: the 9P2000.L
  mount of the machine's namespace needs a FUSE layer on macOS (macFUSE or
  FUSE-T) for Finder, editors and `grep` to reach `/proc` and the
  machine's files ([design-live.md](design-live.md#the-host-link)).
