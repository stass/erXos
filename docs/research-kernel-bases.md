# Research record: kernel bases and borrowable parts

A point-in-time report on existing kernels, kernel frameworks and libraries
that could supply parts of erXos for AArch64, and on what QEMU's `virt`
machine offers under TCG and under HVF on the primary host. The surveys
behind it asked what each candidate offers to a kernel that runs a fork of
ERTS (OTP 29.1.2) at EL1 as its engine and scheduler, with untrusted Erlang
code and native C drivers in EL0 protection domains: licence, language, QEMU
and HVF evidence, SMP, memory management and EL0 support, size, build
requirements, and how tightly the useful parts are coupled to the rest. The
record chooses nothing; where a survey judged a candidate's fit, that
judgement appears once, attributed. QEMU facts measured on the same host are
in [research-baselines.md](research-baselines.md). Findings here are never
edited in place; a re-check gets a new record.

**Date:** 2026-10-29.
**Host:** Apple M4 Max, macOS 27.0.1.
**Sources read** (cloned or downloaded at the versions under
[Sources](#sources) and read only; no script, makefile or binary from them
was run): seL4, Microkit, sDDF, LionsOS, CAmkES and Chrysopolis; Little
Kernel, lkuser and Zircon; FreeBSD, NetBSD, OpenBSD and QEMU; and the other
kernels and libraries named below, kept under `~/erxos-scratch/borrow/` in
`sel4/`, `lk-zircon/`, `bsd/` and `survey/`.

## Method

Four survey passes on 2026-10-29 (seL4 and its ecosystem; Little Kernel and
Zircon; FreeBSD, NetBSD, OpenBSD and QEMU's `hw/arm/virt.c`; other kernels
and libraries) cloned sources at a tag or commit, or downloaded release
archives and checked their hashes, and read them with grep, sed and wc. Line
counts are `wc -l` with comments, without tests for LK and Zircon unless
stated, and with headers (good to about 20 percent) for the broad survey.
Web facts name their page; "unverified" marks a claim no primary source
confirmed, "(inferred)" a conclusion drawn from reading code.

For this record, load-bearing claims were re-read in the downloaded trees
with sed, grep, wc, find and cmp, one read-only `git log` (the LK commit) and
one `python3 -I` one-liner that averaged a benchmark record; nothing was
built or run. Confirmed: LK's licences, SPI routing, `thread_lock`,
`lk_time_t`, EL0 entry, compiler flags, MSI doorbell and HVF script; Zircon's
x20 handling, flags, licence and ffx template; seL4's licence, timer and GIC
constants; Microkit's limits and boards; sDDF's seL4-free drivers;
Chrysopolis; the A53 IPC figures (averages of the five series means in the
sel4bench-results record of 2026-10-29T18:59:05Z); the QEMU v11.1.3 rules
below (both surveys' copies of `virt.c` are identical); RTEMS's A72 BSP;
NuttX's HVF recipe; rumpuser's counts; `agintc.c`; FreeBSD's flags and
SError path; Zephyr's DTS; GRiSP's patch; seven licence texts. Corrected:

* sDDF's OS layer has nine functions; the seL4 survey named eight, omitting
  `sddf_deferred_notify_curr`.
* NuttX's and Nanos's GICv2m code serves only their GICv2 paths, and
  NuttX's is off in every qemu-armv8a configuration; the broad survey had
  counted both as GICv2m support usable under HVF.
* NetBSD attaches GICv2m frames under a GICv3 only through the MBI binding,
  which QEMU's device tree does not use; the BSD survey omitted this.
* lwext4's `ext4_xattr.c` is GPL-2.0-or-later, like `ext4_extent.c`.
* RTEMS 6.2 links its PSCI SMP sources only into the ZynqMP BSP; the
  `objsmppsci` object the broad survey named exists on main.
* ERTS starts a run-queue supervisor only with `+sbwt` supervision
  ([research-erts-host.md](research-erts-host.md#what-the-emulator-starts)).
* Zircon's `arch/arm64` holds 108 source and header files, not the 92 the LK
  survey counted; none includes an `object/` header. BEAMAsm does not use
  x18 (`beam_asm.hpp:179`), which the BSD survey had left unverified.

Measured on this host the same day with QEMU 11.1.2
([research-baselines.md](research-baselines.md#accelerator-capabilities)):
CNTFRQ_EL0 is 24,000,000 Hz under HVF and `ID_AA64PFR0_EL1.GIC` reads 0
there, two facts the seL4 and LK surveys had left unverified.

## QEMU virt under TCG and HVF

From QEMU v11.1.3 (`hw/arm/virt.c`, `hw/intc/arm_gicv3_hvf.c`,
`hw/arm/smmuv3.c`, `hw/virtio/virtio-mmio.c`, `target/arm/cpu.c`, and a
`target/arm/hvf/hvf.c` kept with them, its tag not recorded separately);
"measured" means
[research-baselines.md](research-baselines.md#accelerator-capabilities).

* **Machine types.** `virt-11.1` is the latest; `virt-11.0` and older set
  `hvf_no_kernel_irqchip_default` (`virt.c:4447-4457`), so under HVF they use
  QEMU's emulated GIC and `virt-11.1` Apple's in-kernel vGIC (`:4111-4120`;
  patch 15 of Mediouni's HVF series v21). Without `gic-version`, QEMU picks
  GICv2 if the accelerator offers it and at most 8 CPUs are requested, else
  GICv3; the default CPU is `cortex-a15` under TCG, `max` otherwise.
* **Memory map** (`virt.c:180-207`, `264-273`): distributor `0x08000000`,
  GICv2 CPU interface `0x08010000`, GICv2m `0x08020000` (SPIs from 48), ITS
  `0x08080000`, redistributors `0x080A0000`, PL011 `0x09000000`, SMMUv3
  `0x09050000` (SPIs from 74). The HVF vGIC takes the same GIC bases and
  needs macOS 15.0 (`hvf.c:1349-1370`).
* **HVF's vGIC is GICv3 without an ITS.** GICv2 needs the in-kernel irqchip
  off; GICv3 is refused only with the irqchip off and `virtualization=on`
  ("Hypervisor.framework doesn't expose EL2<->1 transition notifiers",
  `virt.c:2717-2724`). The vGIC refuses revisions other than 3 and the
  security extensions (`arm_gicv3_hvf.c:686-695`); with it `msi=auto` becomes
  GICv2m, and `msi=its` fails: "ITS not supported on HVF when using the
  hardware vGIC." (`virt.c:2751-2803`). Measured: GICv2 refused; GICv3 with
  the GICv2m frame and no ITS.
* **GICv2m.** The frame is a child node `v2m@8020000` of the GIC node,
  compatible `arm,gic-v2m-frame`, marked `msi-controller`; the GICv3 node has
  no `msi-controller` or `mbi-ranges` (`virt.c:936-952`). `msi=gicv2m`
  (values `auto`, `gicv2m`, `its`, `off`; `:3430-3447`) gives TCG the same
  layout. FreeBSD and LK (a hard-coded doorbell) reach it under a GICv3
  (inferred); NetBSD (inferred), OpenBSD, NuttX and Nanos do not; RTEMS,
  Zephyr, Unikraft and 9front have no v2m code; RT-Thread is unverified.
* **EL2.** `virtualization=on` works under TCG, KVM with EL2 support and HVF
  (`virt.c:3003-3015`). Under HVF it enables nested virtualisation, which
  needs macOS 15.0 and host support (`hv_vm_config_get_el2_supported`,
  `hvf.c:1311-1346`), M3 or later according to Lima PR 5443 (unverified).
  Apple's implementation "is nVHE only", and a Hypervisor.framework bug keeps
  the virtual-timer exit from firing at EL2 without Apple's vGIC (HVF series
  v21). Measured: entry at EL2 under HVF. `secure=on` (EL3) is TCG-only
  (`virt.c:2996-3001`); HVF rejects MTE (`:3017-3022`).
* **SME.** QEMU issue 2665 (macOS 15.2, M4) reports that HVF exposed SME and
  QEMU would not start until SME was masked; an SME2 series reached v3 (both
  search summaries). The `hvf.c` copy passes SME2 through when
  `hvf_arm_sme2_supported()` holds, saves and restores its state
  (`hvf.c:569-704`, `1186-1191`), and hides SME under nested virtualisation
  (`:1229`); `ID_AA64PFR1_EL1`, which holds the SME field, was not measured.
* **SMMUv3** sits on the PCIe root bus only; with any other bus a
  device-tree boot gets "SMMUv3 device only supported with pcie.0 for DT" and
  no node (`virt.c:2031-2056`). It advertises stage 1 unless its `stage`
  property is `2` or `nested` (`smmuv3.c:278-285`, `2144-2152`).
* **virtio-mmio** is legacy by default (`force-legacy`, `virtio-mmio.c:735`);
  `-global virtio-mmio.force-legacy=false` selects version 2.
* **Counter frequency.** Under TCG, CNTFRQ is 62.5 MHz for CPU types older
  than QEMU's 1 GHz convention and machine types 9.0 or earlier, and 1 GHz
  otherwise (`target/arm/cpu.c:1906-1924`); Maydell's "Default to 1GHz cntfrq
  for 'max' and new CPUs" kept 62.5 MHz for `cortex-a53`, `-a57` and `-a72`.
  Under HVF the guest sees the host's CNTFRQ_EL0 (`hvf.c:1505-1514`),
  reported as 24 MHz on M-series (hvi-vmm issue 183; on M3 and M4 "VMs get
  an unscaled counter", Mediouni's timer-frequency note). Measured:
  62,500,000 Hz under TCG (`cortex-a76`), 24,000,000 Hz under HVF.
* **Other HVF facts** (measured unless cited): `MIDR_EL1` reads `0x610f0000`,
  which QEMU hard-codes (`hvf.c:1196-1205`); `ID_AA64PFR0_EL1.GIC` reads 0
  although the GICv3 system registers work; there is no 64 KiB granule;
  `/psci` names `hvc`, or `smc` when the guest enters at EL2.

## seL4 and its ecosystem

### seL4

seL4 16.0.0 (tag commit `6e7c3b7`); the next release (seL4 issue 1831) was
untagged on 2026-10-29.

* **Licence.** Kernel GPL-2.0-only (615 files in `src/` and `include/`; a
  handful BSD-2-Clause, BSD-3-Clause, MIT or GPL-2.0-or-later). `LICENSE.md`:
  "kernel-level code is licensed under GPLv2 and user-level code under the
  2-clause BSD license", and the kernel GPL "does *not* cover user-level code
  that uses kernel services by normal system calls". libsel4, seL4_libs and
  sel4runtime are BSD-2-Clause, the musllibc fork MIT, util_libs mostly
  BSD-2-Clause with GPL files in libethdrivers (140), libfdt (14),
  libplatsupport (4) and libsatadrivers (1).
* **QEMU `virt`.** Platform `qemu-arm-virt`; CPUs `cortex-a53` (default),
  `-a57` and `-a72`, no `host` or `max`. GICv2 by default;
  `-DQEMU_GIC_VERSION=3` builds `gic_v3.c` and passes `gic-version=3`
  (`src/plat/qemu-arm-virt/config.cmake:75-79`); that driver maps 1 MiB of
  redistributors (8 x 128 KiB, so at most 8 cores; `gic_v3.c:15-18`), has no
  ITS or LPIs, and no CI job sets the option. The counter frequency is
  compiled in (`TIMER_FREQUENCY 62500000`, `CLK_MAGIC 4611686019llu`,
  `CLK_SHIFT 58u`; `config.cmake:227-228`); a debug build only warns if
  CNTFRQ differs (`generic_timer.c:11-21`).
* **SMP and exception levels.** "The SMP kernel uses a big-lock approach" and
  "is not meant to scale to many cores" (FAQ); SMP with MCS "should still be
  considered experimental" (`CAVEATS.md`). `KernelArmHypervisorSupport` puts
  the kernel at EL2: off by default on AArch64, on in the verified
  configurations and in Microkit; only EL2 builds host VMs.
* **HVF.** No report of seL4 under HVF was found; in the devel-list thread
  "HVC is not supported for PSCI!", `-accel hvf` fails because Microkit
  required EL2 (2.3.0 then added an EL1 board). The survey's obstacles: all
  Microkit, sDDF and LionsOS QEMU kernels are GICv2; HVF's 24 MHz counter
  against the compiled 62.5 MHz stretches MCS budgets about 2.6 times; the
  DTB is dumped with `-cpu cortex-a53`, so an HVF DTB must be supplied; EL2
  needs nested virtualisation (nVHE only, like seL4); the Microkit loader
  starts secondaries with PSCI over SMC, untested where `/psci` names `hvc`.
* **Verification** (`CAVEATS.md`, `configs/`). AArch64 proofs cover "Armv8-a
  with hypervisor extensions only, no SMMU, with FPU, with fast path", single
  core, on 16 boards, not qemu-arm-virt or EL1: functional correctness,
  integrity, and confidentiality (completed per seL4 news of 2026-08-24), not
  binary correctness. MCS functional correctness is proved on RISC-V and its
  AArch64 port began on 2026-09-21; MCS has no security proofs; SMP is
  unverified. MCS scheduling contexts carry a budget and period without
  admission test; passive threads run on a caller's donated context.
* **Size and build.** 12,600 SLOC for verified AArch64 with hypervisor
  support (FAQ); 82,509 raw lines for all architectures. CMake 3.16+, Ninja,
  Python 3 with `sel4-deps`, dtc, xmllint, a cross compiler and QEMU at
  configure time; about 7,100 lines of Python generators; Linux hosts.
* The survey assessed seL4 as incompatible with ERTS acting as the kernel and
  sole scheduler, the engine becoming a privileged EL0 protection domain
  above seL4's scheduler and budget enforcement, and as viable instead as a
  hypervisor beneath erXos.

### Microkit

* Microkit 2.3.1 (`ec86afd`): BSD-2-Clause (305 files; two GPL-2.0-only DTS
  files). Its description tool is Rust (13,588 lines) and each image's root
  task is the Rust capDL initialiser (about 3,700 lines plus crates), so Rust
  runs on the target; loader, monitor and libmicrokit are about 5,000 lines
  of C and assembly.
* `qemu_virt_aarch64` runs seL4 at EL2 (Cortex-A53, `virtualization=on`)
  with no GIC version, hence GICv2, and 4 cores in `smp-*` configurations;
  `qemu_virt_aarch64_el1` (2.3.0) runs it at EL1 (`build_sdk.py:298-320`).
* "Static architecture": resources "are assigned up-front at system
  initialisation time" (`docs/manual.md:34-35`). At most 63 PDs (`:134`) and
  63 channels and interrupts per PD (`:294`); protected calls go only to a
  strictly higher priority in an acyclic graph (`:304-306`); child PDs can be
  restarted, not created; no timer API. "PDs are single-threaded to keep the
  programming model and implementations simple" (`:1939`).
* Prebuilt SDKs exist for macOS and Linux; an SDK build, which a GICv3 board
  needs, takes Rust 1.94+, Python 3.12, CMake, Ninja, Arm GNU 12.2.Rel1, dtc,
  xmllint and QEMU.
* The survey assessed Microkit as a poor base: static, 63 PDs, 63 channels
  per PD, single-threaded PDs.

### sDDF

* sDDF 0.7.0 (`650ace5`): BSD-2-Clause (337 files; 15 GPL-2.0-only board DTS
  files), bundling lwIP 2.2.1 (BSD-3-Clause), Arm optimized-routines (MIT OR
  Apache-2.0 WITH LLVM-exception) and libco (ISC). A Driver only translates
  the device protocol and a Virtualiser per direction owns multiplexing,
  policy and address translation, over single-producer single-consumer rings
  and notifications. Drivers include virtio-blk, -net, -console and -gpu,
  PL011, NS16550A, the Arm timer and SoC drivers; DMA uses physical
  addresses, and seL4 supports only the SMMUv2 MMU-500.
* Drivers reach the OS through nine functions (`include/extern/os/sddf.h`):
  `sddf_get_pd_name`, `sddf_irq_ack`, `sddf_notify`, `sddf_deferred_notify`,
  `sddf_deferred_irq_ack`, `sddf_ppcall`, `sddf_get_mr`, `sddf_set_mr`,
  `sddf_deferred_notify_curr`. The header includes `sel4/sel4.h` for
  `seL4_MessageInfo_t` even in the "Agnostic" mode for non-Microkit systems;
  configuration sits in ELF sections filled by sdfgen; EL0 cache maintenance
  needs `SCTLR_EL1.UCI`. The virtio-net (666 lines), virtio-blk (588),
  virtio-console (435) and PL011 (270) drivers contain no seL4 or Microkit
  symbol; all drivers (15,098 lines) hold 53 `seL4_` and 50 `microkit_`
  identifiers.
* Build: Make, Clang, dtc, Python 3.10+, Microkit SDK 2.3.0 and sdfgen
  0.35.0 (about 8,500 lines of Zig, no declared licence). The README calls
  sDDF "largely experimental software", networking "mostly mature".
* The survey assessed sDDF as good to borrow from through its nine-function
  OS layer.

### LionsOS

* LionsOS 0.4.0 (`ad4c35e`, Trustworthy Systems, UNSW Sydney) is
  BSD-2-Clause, with FatFs R0.15p3 (LicenseRef-FatFS), libnfs
  (LGPL-2.1-or-later), MicroPython and musl (MIT), WAMR (Apache-2.0 WITH
  LLVM-exception) and libvmm (BSD-2-Clause). It offers lwIP networking, a
  FatFs server, an NFS client, MicroPython 1.26.1, WAMR and libvmm guests;
  its components use the Microkit API and call no `seL4_` function.
* Its POSIX layer offers files, IPv4 TCP ("UDP is not supported") and time;
  memory "cannot be freed"; it is single-threaded ("PID == TID for a
  single-threaded process", `lib/libc/posix/posix.c:110`). Examples run on
  qemu_virt_aarch64 (GICv2, EL2); "LionsOS systems will always have a static
  architecture."
* The survey assessed LionsOS as weak as a base, with FatFs and its lwIP
  integration worth borrowing.

### CAmkES

* camkes-tool 3.13.0 (`00965e7`): BSD-2-Clause, about 19,500 lines of Python
  and 14,400 of C, needing `camkes-deps` and Haskell Stack; static systems of
  multithreaded components, with a VMM for AArch32, AArch64 and x64; "being
  superseded by Microkit" (tutorials) but "still supported" (tools page).
* The survey assessed CAmkES as a poor base: static and being superseded.

### ERTS on seL4 (Chrysopolis)

* Chrysopolis (byzantine-systems, `07c3011`, AGPL-3.0) boots ERTS from OTP 28
  to the Eshell on LionsOS under QEMU `virt` (GICv2, EL2), maps pthreads onto
  libmicrokitco cothreads, runs one scheduler (`[smp:1:1]`) and answers
  missing POSIX calls with `ENOSYS`. Kry10 offers Erlang on its seL4-based KOS
  (details unverified; see
  [research-erts-host.md](research-erts-host.md#prior-art)).
* ERTS has required threads since OTP 21 (OTP-14518); a Microkit or LionsOS
  PD is one thread. Raw seL4 has TCBs, `seL4_TCB_SetTLSBase` and
  notifications, but no timeout on `Recv` or `Wait` and no user-level timer
  service; libsel4muslcsys ignores `set_thread_area` ("fine provided we do
  not create multiple threads (through libc) or use TLS"); nothing implements
  clone or futex. Kernel objects are retyped from untyped memory, and user
  level builds every page-table level.

### Published IPC costs

Hot cache, fastpath, EL1 builds (sel4bench does not enable hypervisor mode).
Cortex-A57: seL4 performance page generated 2026-10-29 for sel4bench-manifest
`655f2655`; Cortex-A53: sel4bench-results run 2026-10-29T18:59:05Z, kernel
`7a852638`.

| Measurement (cycles) | Cortex-A57 Jetson TX1, 1.9 GHz | Cortex-A53 i.MX8MM EVK |
| --- | --- | --- |
| Call / reply, default kernel | 419 / 431 | - |
| Call / reply, MCS | 434 / 451 | 282 / 325 (passive server) |
| Call / reply, MCS, FPU-using server | - | 419 / 453 |
| Call / reply, MCS, 10-word messages (slowpath) | - | 989 / 1,082 |
| Notify, default / MCS | 1,058 / 1,141 | - |
| Signal a higher-priority process, MCS | - | 1,092 |
| IRQ to user handler, default / MCS | 880 / 1,021 | MCS: 625 |
| Generic fault IPC, MCS (to handler / back) | - | 763 / 1,096 |
| Process-to-process `seL4_Yield`, MCS | - | 989 |
| Null system call | - | 132 |
| Call / reply, SMP kernel (non-MCS, same core) | - | 474 / 566 |

An A53 MCS call and reply total about 607 cycles (872 with an FPU-using
server, about 2,070 with 10-word messages), which the survey equates to about
4.6 null system calls; the SMP kernel raises same-core call and reply from
262/293 to 474/566. Timeout faults are not benchmarked; Lyons et al. measured
recovery at 1.9 to 23.3 microseconds on a 1 GHz Cortex-A9. Mapping one page
costs 759 to 3,796 cycles across the measured AArch64 boards.

## Little Kernel

LK master `e7cefb16` (no release tags; master reached `d3d8ddf8`, an 88-line
thread-pinning fix, during the survey without changing a finding).

* **Licence.** MIT (`LICENSE`; about 1,120 MIT-style headers). In the arm64
  subset, `kernel/semaphore.c` and its header are Apache-2.0 (Christopher
  Anderson, 2012) without SPDX tags; libc `strtol.c`, `strtoll.c`, `qsort.c`,
  `atof.c` and `sys/cdefs.h` are BSD-3-Clause, `bsearch.c` ISC-style;
  `lib/libc/string` cites a "NewOS License" absent from the tree
  (unverified); libfdt is `(GPL-2.0-or-later OR BSD-2-Clause)`.
* **Language and boot.** C (`--std=gnu11`) and assembly; a C++17 subset
  (`engine.mk:84`), in the arm64 subset only in `lib/fdtwalk` (1,405 lines);
  optional Rust. `platform/qemu-virt-arm` boots an ELF linked 1 MiB above RAM
  and reads the DTB at the start of RAM (`platform.c:66`), where QEMU's ELF
  path writes it; there is no Image header (the survey's estimate that one is
  a small change is unverified). `MEMSIZE ?= 0x08000000   # 512MB` is 128 MiB.
* **GIC.** One v2 and v3 driver (1,567 lines; v3 from Trusty, `b6c72e5d`):
  system registers, affinity routing, SGIs via `ICC_SGI1R_EL1`. Every SPI
  goes to affinity 0 (`gic_v3.c:344-346`); no ITS, LPIs or affinity API;
  extended INTIDs, `ICC_CTLR_EL1.RSS` and the DS=1 branch are open comments.
  The version comes from the DT (`helpers.cpp:424`), not
  `ID_AA64PFR0_EL1.GIC`. CI boots arm64 with `-6s4` and no GIC version
  (`run-qemu-boot-tests.py:23-28`), so QEMU picks GICv2; v3 is untested.
* **SMP.** PSCI (150 lines) uses HVC when entered at EL1 and SMC at EL2,
  ignoring the DT; x18 holds per-CPU data; `SMP_MAX_CPUS` defaults to 8, with
  32-bit masks. The EL2 drop leaves `CNTHCTL_EL2` and `ICC_SRE_EL2` unset.
* **MMU, VM, EL0.** `mmu.c` (996 lines): 4K, 16K and 64K granules, a written
  TLB discipline, 16-bit ASIDs, a 30 GiB physmap. `pmm.c` (515) has one
  global mutex; `vmm.c` (940) commits eagerly, with no demand paging, VMOs,
  VM-level protect or partial unmap of large pages. EL0 landed on 2026-09-05
  (`77522239`, `bf9cad64`): `arch_enter_uspace` (`arch.c:146-185`) zeroes x0
  to x30 and EL0 exceptions reach weak hooks, with no syscall layer, PAN or
  user copy, and an unused fault-fixup table (`asm_macros.h:167`). lkuser
  (`bd4ec158`, about 1,170 lines of C++) covers arm32 and RISC-V only.
* **Threads, locks, timers.** `thread.c` (1,360): 32 priorities, a 5-tick
  quantum ("XXX make this smarter", `:502`), single-CPU pinning. One run
  queue and one spinlock, `thread_lock` (`thread.c:53`), guard all run
  queues, thread states and wait queues; mutexes take it on every acquire and
  release, without priority inheritance; spinlocks are unfair. Timers sit on
  per-CPU lists under one `timer_lock`; `lk_time_t` counts milliseconds in 32
  bits (`sys/types.h:33`), while `ethr_event_twait` takes nanoseconds. The
  unmerged `wip/preempt-disable` branch splits both locks. Stacks have no
  guard pages.
* **FP and TLS.** Kernel threads may use FP, restored lazily on the first
  trap; other code builds with `-mgeneral-regs-only`
  (`arch/arm64/rules.mk:112`). TLS is four fixed `tls[]` slots, `TPIDR_EL1`
  the thread and x18 the CPU; BEAMAsm never uses x18 (`beam_asm.hpp:179`).
* **Build, size, quality.** GNU make, GCC 15.2.0 or clang 20 in CI, Python
  only for symbols and tests. Core 17,258 lines, support 20,232 (libc, heap,
  dlmalloc, libfdt), repository 192,396. Kernel and contract tests, UBSan and
  CodeQL in CI; 892 commits in the year to 2026-10-27, 774 by Geiselbrecht.
  `atomic_cmpxchg` is a stub returning 0; MSI setup hard-codes doorbell
  `0x08020040` and CPU 0 (`platform.c:196-209`), QEMU's v2m frame under both
  accelerators (inferred).
* **HVF and relatives.** No report of LK under HVF; `do-qemuarm` passes
  `gic_version=2,accel=hvf` (`:239-240`), which `virt-11.1` refuses. Trusty
  (MIT) supplied the GICv3 driver; NVIDIA TLK adds user mode at Secure-EL1
  ("MIT/FreeBSD" per TF-A, unverified); Zircon was "born as a branch of LK".
* The survey assessed LK as the best fit for running ERTS threads as kernel
  threads as it stands, its scheduler reducible to a switching service for
  per-CPU ERTS contexts, with the risks of no Image header, untested GICv3,
  global locks, millisecond timeouts, unguarded stacks and immature EL0 code.

## Zircon

Fuchsia main `78197f39`, `releases/f32` `6a563ae1`, and spot checks of
`releases/f33` `08effcaa`.

* **Licence.** MIT kernel: at main 2,349 files are MIT-style and 273
  BSD-style (Fuchsia's BSD-2-Clause `/LICENSE` with `/PATENTS`), none Apache
  or GPL; external libraries (fbl, fit, zx, lockdep, others) are BSD-style.
* **Language.** At main the kernel is one Rust crate, "a mix of C++ and Rust
  code" until "the conversion to Rust is complete": 292,930 lines of C, C++
  and assembly and 265,989 of Rust, with MMU, GIC drivers and scheduler in
  Rust. f32 is the newest release with a C++ core (C++23 with ktl, fbl,
  lockdep, chainlock; 11 external libraries of at least 35,814 lines),
  already compiling 17,155 lines of Rust.
* **arm64 at f32.** A 40,774-line VM with copy-on-write VMOs, pagers, VMARs
  with `CAN_MAP_*` ceilings and an ASID allocator; GICv3 (698 lines) and
  GICv2 with GICv2m (893) configured from ZBI records, no GICv3 MSI; per-CPU
  fair and deadline queues with work stealing and priority inheritance;
  nanosecond timers; PAN; LDTR/STTR user copy. Handles encode index,
  generation and a per-table random value (`handle.cc:34-50`), and
  duplication cannot add rights. Boot goes through a Linux Image header.
* **Coupling.** No `arch/arm64` file includes an `object/` header; 5 of 33
  `kernel/` and 9 of 96 `vm/` files do. `Thread` refers to its dispatcher,
  the scheduler to chainlock and `OwnedWaitQueue`, drivers to ZBI; a
  hardware layer at f32 is about 132k lines plus 35.8k of libraries.
* **Other code at EL1.** Kernel code may not use FP or vector registers,
  which "usually still hold the user-mode values" (`arch/arm64/BUILD.gn:31-34`).
  `-ffixed-x20` makes x20 the per-CPU pointer (`:59`); each EL1 exception
  reloads it and an EL1-to-EL1 return keeps the reloaded value
  (`exceptions.S:293-310`, `744-747`), so BEAMAsm, whose Erlang stack
  pointer is x20 (`beam_asm.hpp:86`), or any EL1 code built without
  `-ffixed-x20` would lose x20 (inferred).
* **Build and QEMU.** GN and Ninja in the Fuchsia tree, Clang and Rust;
  x86-64 Linux hosts only ("Windows and macOS are not supported"). Main is
  558,919 lines, f32 382,512. ffx runs arm64 on `virt-9.2,gic-version=3` with
  `-cpu host` and HVF on macOS (`emulator_flags.json.template:86-106`), so
  HVF would use QEMU's emulated GIC (inferred); the emulator page calls arm64
  "very limited and not recommended"; arm64 Fuchsia under HVF is unverified.
* The survey assessed Zircon as unsuitable as a base, its language, register
  conventions and object model conflicting and its upstream moving to Rust,
  and as a design reference for handles, VMAR ceilings, user copy, ASIDs,
  restricted mode and priority inheritance.

## FreeBSD

FreeBSD `releng/15.1` at `95719d8a895b` (release/15.1.0-p6).

* **Whole kernel.** No C++ in `sys/`; arm64 kernel code builds with
  `-mgeneral-regs-only`, `-ffixed-x18` and `-mbranch-protection=standard`
  (`sys/conf/kern.mk:142-148`), uses FP only between `fpu_kern_enter()` and
  `fpu_kern_leave()`, and runs on 4-page stacks (`param.h:100-105`);
  `MAXCPU` is 1024. Scheduling, racct/rctl, Capsicum, jails, VFS and sockets
  key on `struct proc`, `struct thread` and descriptors, which are reused
  integers without generation; Capsicum rights only shrink
  (`sys_capability.c:230-262`); `copyin` clears PAN (`asm.h:97-104`);
  `do_serror()` panics (`trap.c:815-829`). `sys/` has 33,248 files.
* **Build, QEMU, HVF.** bmake; on macOS `tools/build/make.py` (Python 3)
  bootstraps bmake with Homebrew LLVM, and FreeBSD's CI cross-builds arm64
  GENERIC on `macos-latest` (`brew install bmake libarchive llvm@18`).
  aarch64 is Tier 1; GENERIC has `std.virt`, GICv3 and ITS; SMMU support is
  only `options IOMMU`. FreeBSD 15 runs in text mode on an M4 Max under UTM
  4.7.5 with HVF (UTM issue 7598), 14.3 on an M4 Pro (issue 6918).

| Piece | Lines | Licence | Depends on | Extraction (survey) |
| --- | --- | --- | --- | --- |
| pmap | 10,268 + 466 | 4-clause UC text plus a 2-clause section; UC's 1999-07-22 letter in `COPYRIGHT` rescinds only UC's clause | `vm_page`, `vm_object`, `vm_map`, `vm_reserv`, UMA, vmem, locks; `pmap(9)` | very hard |
| GICv3 and ITS | 5,728 (`gic_v3.c` 1,713, `gicv3_its.c` 2,335) | BSD-2-Clause text | newbus, KOBJ `pic_if`, `msi_if`, `gic_if`; INTRNG (1,958); OFW, ACPI | moderate |
| generic timer; PSCI; PL011 | 953; 867; 672 | BSD-3-Clause; BSD-2-Clause; BSD-2-Clause | eventtimers, timecounters; newbus, OFW; uart(4) | rewriting cheaper |
| virtio (42 files) | 22,351 (`virtqueue.c` 879, `if_vtnet.c` 4,656, `virtio_blk.c` 1,679) | BSD-2-Clause, BSD-3-Clause | `virtqueue.c`: sglist, malloc, KOBJ; vtnet: ifnet, mbuf, UMA, netmap; blk: GEOM | easy to moderate (`virtqueue.c`), hard (vtnet, blk) |
| SMMUv3 (`sys/arm64/iommu`) | 4,947 + 2,254 | BSD-2-Clause | newbus, KOBJ, IOMMU and busdma, `vm_page` | moderate to hard |
| network | 372,645 | mostly BSD-3/BSD-2; BSD-4 in `in_cksum.c`, `if_media`, `if_bridge`, `bridgestp`; ISC, MIT-style, CMU | epoch, mbuf, UMA, ifnet, VNET, sockets | very hard |
| file systems | UFS 45,061; msdosfs 8,475; tmpfs 6,250 | UFS BSD-3/BSD-2; msdosfs BSD-4-Clause with the TooLs GmbH clause; tmpfs BSD-2-Clause; OpenZFS CDDL | VFS, buffer cache, `vm_object` | hard |

* pmap holds break-before-make, the ASID and VMID allocator, TLBI helpers
  and the errata table behind FreeBSD-SA-26:31.arm64 (CVE-2025-10263, a
  write landing after its permission is revoked on Cortex-A76 to X925 and
  Neoverse N1, N2, V1, V2, V3). `gic_v3_fdt.c` adds a device for every
  compatible GIC child (`:284-343`) and gicv2m attaches under `gic`
  (`sys/arm/arm/gic_fdt.c:322`, `:363`), so QEMU's v2m frame would attach
  under a GICv3 (inferred; run time unverified).
* The survey assessed FreeBSD as a poor whole-kernel base, needing a deep
  fork, and its pieces as references: pmap, the GICv3 and ITS drivers,
  `virtqueue.c` and the SMMUv3 driver.

## NetBSD and rump kernels

NetBSD `netbsd-11` at `3b308647b144` (11.0_STABLE); trunk metadata
`4a74c4f51700`.

* **Rump kernels** "provide portable, componentized, kernel quality drivers
  such as file systems, POSIX system call handlers, PCI device drivers, a
  SCSI protocol stack, virtio and a TCP/IP stack" (`rumpkernel(7)`) from
  unmodified NetBSD sources plus 39,184 lines of glue. They manage no MMU
  (`pmap_enter` panics); host threads hold one of `RUMP_NCPU` virtual CPUs
  (default 2); `RUMP_MEMLIMIT` caps memory; aarch64 uses `arch/generic`.
* **rumpuser** (`rumpuser.h` rev 1.117, `RUMPUSER_VERSION` 17) has 62
  hypercalls, 8 of them the syscall proxy; the other 54 cover init, memory,
  files and block I/O, clocks, parameters, threads and locks. There are 13
  upcalls; a hypercall must release its rump CPU before blocking. Devices add
  10 `rumpcomp_pci_*` calls and virtif's 4 calls and one upcall.
* **Components:** 27 network libraries (TCP/IP, IPv6, IPsec, NPF, bridge,
  VLAN, WireGuard, virtif), 28 file systems (ffs, msdos, ext2fs, tmpfs, nfs,
  cd9660, udf; libzfs is CDDL) and 42 device libraries (PCI, virtio, SCSI,
  USB), over 245,072 lines of networking and 40,750 of ffs, ufs and ext2fs.
* **Licence.** BSD-2-Clause text without SPDX tags; advertising clauses
  remain in 24 `sys/netinet` files (Cisco in SCTP; UC and US Naval Research
  Laboratory in TCP), 5 in `netinet6`, 5 in `sys/net` and 10 in msdosfs
  (TooLs GmbH); some files are ISC; no GPL.
* **Activity and hosting.** Trunk has 24 commits touching `sys/rump` in 2026,
  the latest on 2026-10-02, and NetBSD's network tests drive rump servers;
  rumprun was last committed on 2020-05-11. `build.sh` needs a POSIX host
  with C and C++ compilers. Genode builds rump with its own makefiles and
  implements rumpuser in 1,562 lines of C++ (ext2, FAT, ISO9660; arm_64);
  Data61 ported rumprun to seL4 on x86. The BSD survey estimated an erXos
  rumpuser layer at 1.5 to 3k lines of C17 (an estimate).
* **arm64 pieces** (BSD-2-Clause): pmap 2,779 lines (tied to UVM); `gicv3.c`
  954, `gicv3_its.c` 1,111, `gicv3_fdt.c` 480, `gic_v2m.c` 377; virtio core
  1,603, PCI 1,347, MMIO 512; LDTR/STTR with PAN; MAXCPUS 256; no SMMU
  driver. `gicv3_fdt.c` sets up v2m frames only when the GIC node itself has
  `msi-controller` and `mbi-ranges` (`:176-180`, `:268-312`), otherwise only
  `arm,gic-v3-its` children, and only the GICv2 driver matches
  `arm,gic-v2m-frame` (`gic_fdt.c:121-123`), so QEMU's v2m frame would not
  attach under a GICv3 (inferred; untested).
* **HVF.** 10.1 failed on an M4 Air under UTM 4.7.4 (issue 6918); 11.0 RC1
  boots on an M1 Max under UTM 4.7.5; no NetBSD 11 on an M4 is reported.
* The survey assessed rump kernels as a good fit for networking and storage
  in EL0 domains behind the rumpuser hypercalls, and NetBSD's arm64 drivers
  as references, its v2m code especially (qualified above).

## OpenBSD

* OpenBSD 8.0 (`sys.tar.gz` checked against the release's SHA256 file).
  `agintc.c` (2,166 lines, rev 1.66, ISC) holds the GICv3 distributor,
  redistributors and ITS over autoconf, bus_dma, FDT and evcount; only the
  GICv2 driver matches `arm,gic-v2m-frame` (`ampintc.c:905`), so with HVF's
  vGIC `agintc` has no MSI (inferred; INTx fallback unverified).
* ISC: `agtimer.c` 372, `psci.c` 370, `pluart.c` 902, pmap 2,420 (UVM, pool)
  and `smmu.c` 2,454 (3,577 with its companions) for SMMU v1/v2 and v3 (v3
  from 7.8, on FDT from 7.9) over bus_dma, pool and extent. BSD-2-Clause:
  `dev/pv/virtio.c` 1,075, needing only the device framework, atomics,
  malloc and bus_dma; `virtio_pci.c` 1,246, `virtio_mmio.c` 560, `if_vio.c`
  2,184. `copy.S` uses LDTR/STTR; MAXCPUS is 256. HVF: 7.1 and 7.5 on an M2
  (QEMU 7.1.0, astreknet); nothing for the M4.
* The survey assessed OpenBSD's drivers as the best fork candidates for
  compact drivers: `agintc.c`, `smmu.c` and the virtio core.

## RTEMS and GRiSP

* RTEMS 6.2 (`be446b02`; main `402de13a`) is mostly BSD-2-Clause (2,262 SPDX
  tags in cpukit and the AArch64 BSPs); 183 files keep the historical
  GPL-2.0+ licence with linking exception (shell, libfs, old CPU ports,
  ns16550, `sapi/src/panic.c`, `rtems/src/clockgetuptimeseconds.c`); the
  engineering manual requires BSD-2-Clause for contributions and says the
  old code is being relicensed, rewritten or removed.
* The `a53` and `a72` QEMU BSPs use `virt,gic-version=3`, the GICv3 driver,
  PL011 and the generic timer (`spec/build/bsps/aarch64/a72/grp.yml`);
  `bsp.h:59-63` hard-codes GICD `0x08000000`, GICR `0x080A0000` and PL011
  `0x9000000`, QEMU's map and the HVF vGIC bases. No GICv2m code, no HVF
  evidence, and no SMP in any QEMU BSP: in 6.2 only ZynqMP links the PSCI SMP
  sources, grouped on main as `objsmppsci` for Xen and ZynqMP; wiring them in
  looks small (inferred; unverified).
* One address space, no EL0 processes, static MMU maps (a paravirtualised
  mode runs RTEMS itself at EL0); a futex handler and SMP schedulers (EDF SMP
  by default, priority, simple, strong-APA, clustered). Score 34k lines plus
  42k of headers, POSIX 20k, AArch64 port about 3.9k; waf (Python), RSB.
* GRiSP (`9dfbeb5`) carries `00100-rtems.patch` for OTP 23 to 29; for OTP 29
  it is 2,484 lines, about 20 of them ERTS C changes (a section name in
  `io.c` and `sys.h`, a crash-dump stub in `sys.c`, `IOV_MAX` in
  `prim_socket_nif.c`, the PowerPC lwsync test in `ethread.c`), the rest
  build system and crypto configuration. GRiSP 2 runs RTEMS 5 on a Cortex-A7
  (`--enable-static-nifs`, `erl_xcomp_poll=no`); upstream OTP master
  (30.0-rc0) has no `__rtems__` in ERTS.
* The survey assessed RTEMS as the closest fit for running ERTS threads as
  kernel threads, GRiSP already running full ERTS on it, with the single
  address space without EL0 processes as the main risk.

## NuttX

* Apache NuttX 13.1.0 (`2b5c0de5`) is Apache-2.0. `qemu-armv8a` has GICv3 by
  default (`arch/arm64/Kconfig:460-464`), GICv2 as an option, and SMP with
  PSCI. `arm64_gicv2m.c` (158 lines) builds only with `ARM64_GICV2M` (off by
  default, needs `PCI_MSIX`), only the GICv2 driver initialises it
  (`arm64_gicv2.c:872-874`), and no qemu-armv8a configuration enables it; the
  GICv3 driver (1,040 lines) has no MSI path.
* The documented `-accel hvf` run (M1, macOS 12.6.1) uses `netnsh_smp_hv`
  with `CONFIG_ARM64_GIC_VERSION=2`, which `virt-11.1` refuses under HVF; a
  GICv3 configuration on HVF is unverified. `knsh` (`CONFIG_BUILD_KERNEL`,
  `CONFIG_ARCH_ADDRENV`) runs EL0 processes with their own page tables.
  `sched/` (58k lines) has no futex; virtio drivers use OpenAMP 2025.10.0
  with 19 NuttX patches. Make with kconfig-frontends (C) or kconfiglib
  (Python), or CMake; no ERTS port.
* The survey assessed NuttX as the best fit for the EL0 phases (GICv3, SMP,
  EL0 processes, broad virtio), against a deep POSIX task model and no ERTS
  port; it counted GICv2m as an asset, which the check above qualifies.

## Zephyr

* Zephyr 4.5.0 (`41d10b59`) is Apache-2.0. `qemu_cortex_a53` runs
  `virt,gic-version=3` with `secure=on` unless `CONFIG_ARMV8_A_NS`
  (`board.cmake:9-13`), and its static DTS declares an ITS at `0x8080000`
  (`qemu-virt-a53.dtsi:75-85`), which the HVF vGIC lacks; the `/smp` variant
  has 2 non-secure CPUs; there is no HVF evidence. `USERSPACE` gives EL0
  threads and memory domains with per-domain page tables and ASIDs, plus
  `k_futex`; virtio-mmio is version 2 only. Kernel 24.8k lines, `arch/arm64`
  9.5k; CMake 3.28+, Python 3.12+, dtc, Ninja, west and the Zephyr SDK.
* The survey assessed Zephyr as offering clean primitives, ARMv8-A userspace
  and the largest community, against heavy tooling, a static Secure-default
  board that needs edits for HVF, and partial POSIX.

## Other kernels

From the broad survey; sizes in lines, with headers.

| Kernel | Licence (SPDX) | Language | QEMU `virt`, GIC, SMP | HVF evidence | VM and EL0 | Size | Build |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Unikraft 0.21.0 | BSD-3-Clause; Buildroot-derived Makefile and kconfig GPL-2.0 | C | KVM platform on `virt`; GICv2 and v3; SMP-safe locks, multicore scheduling unverified; virtio-mmio v1 and v2, PCI, 9p, virtiofs | KraftKit detects `hvf`; an arm64 guest is unverified | single address space | arch/arm 2.9k, plat 2.1k, GIC 2.8k | GNU Make, Kconfig |
| TF-A 2.15.0 libraries | BSD-3-Clause | C | GICv3 init asserts `IS_IN_EL3()` in 14 places, its register helpers (0.85k) do not; `xlat_tables_v2` (2.75k) has TTBR0 only, no ASIDs, no locking | firmware | - | as left | Make, TF-A headers |
| RT-Thread 5.3.0 | Apache-2.0 | C | `qemu-virt64-aarch64`: GICv2 and v3, ITS, GICv2m (`pic-gicv2m.c`, unverified), 4-CPU SMP, PSCI | none; `qemu.py` defaults to GICv2 with `its=on` | RT-Smart processes with own address spaces | src 33.6k, aarch64 9.1k, lwp 43.8k | SCons (Python), Kconfig |
| HelenOS 0.14.1 | BSD-3-Clause-style per file; some GPL third-party code | C | `virt`, HiKey960; GICv2 only; arm64 SMP a stub | none | microkernel | generic 40k, arm64 5.2k | Meson |
| managarm | MIT | C++ kernel; some Rust user space | GICv2 and v3; SMP code | not checked | asynchronous microkernel | thor 38.9k, arm 4.9k | Meson |
| SerenityOS | BSD-2-Clause | C++ | `virt` with `-cpu max`; GICv2 and v3; no AArch64 SMP | `Meta/run.py` uses HVF on macOS | Unix processes | kernel 152k, aarch64 13.1k | CMake, Ninja, Python |
| Plan 9 Foundation | MIT | Plan 9 C | no arm64 kernel | - | - | - | mk |
| 9front | MIT (exceptions listed) | Plan 9 C | `sys/src/9/arm64` conf `qemu`: GICv3, PSCI SMP, virtio-pci | none found | processes | port 70.7k, arm64 4.6k | mk |
| Inferno 4th edition | MIT (bulk) | C, Limbo | native ports 32-bit only; inferno64 is hosted arm64 | - | Dis VM in the kernel; `os/port/dis.c` hands one interpreter between kprocs | os/port 45k, libinterp 34.6k | mk |
| Barrelfish | MIT | C, Haskell | `a57_qemu` CPU driver with `gic_v3.c`; last commit 2020-03-20 | none | multikernel | kernel 56k, armv8 9.4k | Hake (GHC 8.0.2) |
| Nanos 0.1.56 | Apache-2.0 | C | `virt`; GICv2 with v2m or GICv3 with ITS, chosen from `ID_AA64PFR0_EL1.GIC` (`src/aarch64/gic.c:539-549`), which reads 0 under HVF; PSCI SMP | Makefile defaults to `-accel hvf` with `gic-version=2` | one Linux-ABI process at EL0 | kernel 12.2k, aarch64 4.9k | Make |
| Eclipse ThreadX 6.5.2 | MIT; GICv3 sample files under an Arm EULA | C | ARMv8-A SMP ports; FVP samples; no `virt` BSP | none | Modules port for Cortex-A35 (isolation unverified) | common 43k | CMake |
| FreeRTOS 11.3.2 | MIT | C | `ARM_AARCH64` ports, single core | none | none | 16.6k | any |
| OP-TEE OS 4.11.0 | BSD-2-Clause (mostly) | C | `qemu_armv8a`: 4 cores, GICv3 optional, S-EL1 | needs `secure=on`, TCG only | S-EL0 trusted applications | kernel 13.3k, arm 21.9k | Make |
| Hafnium 2.15.0 | BSD-3-Clause | C | `virt,gic_version=3` at EL2; SMMUv3 (stage 2) | EL2, so nested only | stage-2 VMs | 54.9k | GN, Ninja |
| Genode base-hw 26.02 | AGPL-3.0 with Genode linking exception | C++ | `virt_qemu_arm_v8a`, GICv3 | not checked | components at EL0 | not measured | Genode tools |
| NOVA | GPL-2.0 with a hypercall-API note | C++ | QEMU virt; GICv2, v3 and ITS; SMMUv2 and v3; EL2 | EL2 | - | aarch64 12.4k | Make |
| L4Re Microkernel (Fiasco) | MIT since 2025-09-15; bundled parts BSD-3-Clause, Zlib, LGPL-2.1-or-later, GPL-2.0-only | C++ | `virt`: GICv2, v3, ITS, MSI; SMMUv2 and v3 | not checked | microkernel | src/kern 141k, arm 48k | GNU make, gcc 11+ or clang 10+, Perl |
| Xen 4.22.0 | GPL-2.0-only | C | GICv3; SMMUv3 (tech preview); EL2 | EL2 | - | not measured | Make |
| Linux | GPL-2.0 WITH Linux-syscall-note | - | licence note only | - | - | - | - |
| OSv | BSD-3-Clause | C++ | GICv2 and v3 on master (v0.57.0: GICv2 only) | - | single address space | aarch64 8.6k | - |
| ToaruOS | NCSA | C | `virt` and RPi 400; GICv2 only; SMP | - | processes | aarch64 5.5k | - |
| Bao 2.0.0 | Apache-2.0 | C | `qemu-aarch64-virt`; GICv2 and v3; SMMUv2 only; EL2 | EL2 | static partitions | 36.9k | Make |

* Redox (Rust): a scheme is "a uniquely named service that is provided by some driver or daemon program", reached with file-like operations.
* Theseus (Rust): its README aims at "easier and more arbitrary live evolution and runtime flexibility", with kernel components swapped at run time.
* Hubris (Rust): no task is created at run time, a supervisor restarts faulted tasks, and IPC `send` lends memory through leases.
* Tock (Rust): a per-process "grant" region, which the process "can neither read nor write", holds kernel state for that process.

The survey assessed RT-Thread as the runner-up to its three bases; Unikraft,
TF-A's helpers, OP-TEE, Hafnium and Bao as sources of parts; L4Re as a good
reference in C++; and the rest as poor fits or prior art.

## Libraries for later subsystems

| Area | Library | Licence (SPDX) | Size (lines) | State | Needs from the OS |
| --- | --- | --- | --- | --- | --- |
| TCP/IP | lwIP 2.2.1 | BSD-3-Clause | core 34.3k, api 9.8k, netif 4.2k, headers 30k | since 2001; released | `NO_SYS=1`: raw callbacks and `sys_now()` in one context; `NO_SYS=0`: sys_arch semaphores, mutexes, mailboxes, `sys_thread_new` |
| TCP/IP | picoTCP 1.7.0; picoTCP-NG 2.1 | GPL-2.0 or GPL-3.0 (`COPYING`); the 1.7.0 README says GPL v2 only | - | stale | - |
| TCP/IP | FNET 4.7.1 | Apache-2.0 | 32.5k | stale; Cortex-M and Kinetis only | bare metal |
| TCP/IP | uIP 1.0 | BSD-3-Clause | 7.7k | superseded by Contiki-NG | protothreads |
| TCP/IP | FreeRTOS-Plus-TCP 4.4.2 | MIT | 51.5k | active | FreeRTOS task, queue, semaphore and event-group API |
| TCP/IP | NetX Duo 6.5.2 | MIT | not measured | active | ThreadX API |
| Storage | littlefs 2.11.3 | BSD-3-Clause | 7.7k | active | read, prog, erase, sync callbacks; optional malloc and locks |
| Storage | FatFs R0.16 | FatFs licence, 1-clause BSD style | 7.2k plus 15.6k optional tables | mature | diskio callbacks; optional time, malloc and mutex hooks |
| Storage | lwext4 (master `58bcf89a`) | GPL-2.0 as distributed: `ext4_extent.c` and `ext4_xattr.c` GPL-2.0-or-later, the rest BSD-3-Clause | 17.6k | dormant | block device |
| virtio | OpenAMP 2026.04.0 with libmetal | BSD-3-Clause | virtqueue 0.8k, mmio 0.36k; libmetal 8.6k | two releases a year | libmetal (a bare-metal port exists); mmio version 1 only (`virtio_mmio_drv.c:197`) |
| virtio | NuttX `drivers/virtio` 13.1.0 | Apache-2.0 | 10k | active | NuttX and OpenAMP; mmio v1 and v2, PCI legacy and modern |
| virtio | Zephyr virtio 4.5.0 | Apache-2.0 | 1.3k core, 2.0k devices | active | Zephyr device model; mmio v2 only |
| virtio | Unikraft `drivers/virtio` 0.21.0 | BSD-3-Clause | 7.7k | active | uk netdev and blkdev; mmio v1 and v2 |
| virtio | RT-Thread virtio 5.3.0 | Apache-2.0 | 12.2k | active | RT-Thread device model |
| SMMUv3 | TF-A 2.15.0 | BSD-3-Clause | 0.2k | - | initialisation and abort only |
| SMMUv3 | Hafnium 2.15.0 | BSD-3-Clause | 1.8k (C) | active | `hf/` helpers; queues, linear stream table, stage-2 STEs |
| SMMUv3 | L4Re/Fiasco | MIT | about 3.1k (C++) | active | L4Re kernel; stage 1 by default; QEMU instance at `0x09050000` |
| SMMUv3 | NOVA; Xen | GPL-2.0 | - | - | - |
| Device tree | libfdt 1.8.1 | GPL-2.0-or-later OR BSD-2-Clause | 6.5k | mature; used by TF-A and L4Re | `libfdt_env.h` |

* FatFs's `LICENSE.txt` permits redistribution "provided that the following
  condition is met: 1. Redistributions of source code must retain the above
  copyright notice, this condition and the following disclaimer"; ChaN calls
  it "equivalent to the 1-clause BSD license". The sDDF, OpenBSD and FreeBSD
  virtio drivers and the OpenBSD and FreeBSD SMMUv3 drivers appear in their
  sections; the NetBSD, NuttX, RT-Thread, Zephyr, Unikraft and OP-TEE trees
  examined hold no SMMU driver, and no maintained standalone C virtio-blk or
  virtio-net library turned up.
* The survey assessed lwIP, littlefs, FatFs and libfdt as high fit, OpenAMP
  as a virtqueue core, Unikraft's drivers as the best permissive virtio
  source, picoTCP as excluded by its GPL, and lwext4 as usable only with GPL
  consent or without extents and extended attributes.

## Comparison

| Candidate | Licence (SPDX) | Language | QEMU `virt` AArch64, GICv3, HVF evidence | SMP | VM and EL0 | Size | Build and host tools | Coupling and what extraction takes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| seL4 16.0.0, as the kernel | kernel GPL-2.0-only; libsel4, seL4_libs, sel4runtime BSD-2-Clause; util_libs partly GPL | C, assembly; Python generators | qemu-arm-virt, GICv2 by default; GICv3 by build option, at most 8 cores, not CI-tested; 62.5 MHz compiled in; no HVF report | big lock; SMP with MCS experimental; unverified | components at EL0; VMs only in EL2 builds; user level builds page tables from untyped memory | 12,600 SLOC verified AArch64; 82,509 raw lines | CMake 3.16+, Ninja, Python 3 with `sel4-deps`, dtc, xmllint, cross compiler, QEMU; Linux host | it is the kernel: everything else runs at EL0, ERTS needs a thread layer on TCBs and notifications, and timed waits need a timer driver |
| Microkit 2.3.1, sDDF 0.7.0, LionsOS 0.4.0, as parts | BSD-2-Clause; DTS files GPL-2.0-only; sdfgen undeclared; LionsOS dependencies MIT, Apache-2.0, LGPL-2.1-or-later (libnfs), FatFs | Microkit tool and initialiser Rust; runtime, drivers and components C; sdfgen Zig | `qemu_virt_aarch64` (EL2) and `_el1`; GICv2 DTS; no HVF report | `smp-*` configurations, 4 QEMU cores | one-thread PDs at EL0; VMs through libvmm at EL2 | tool 13,588 lines; sDDF drivers 15,098; virtio drivers 435 to 666 each | Make, Clang, dtc, Python 3.10+, sdfgen 0.35.0, Microkit SDK 2.3.0 (prebuilt for macOS and Linux) | sDDF drivers need nine OS functions, a `seL4_MessageInfo_t` header, a dispatch loop, configuration sections and `SCTLR_EL1.UCI`; LionsOS components need the Microkit API and libmicrokitco |
| LK `e7cefb16` | MIT; Apache-2.0 semaphore; BSD-3-Clause and ISC libc files; libfdt dual | C (gnu11), assembly; C++17 only in `fdtwalk`; optional Rust | ELF boot, DTB at RAM start; GICv2 and v3 chosen from the DT, v3 not CI-tested; the HVF script asks for GICv2, which `virt-11.1` refuses | PSCI; one run queue and `thread_lock`; 8 CPUs by default, 32 at most | 4K, 16K, 64K pages, ASIDs, eager allocation; EL0 since 2026-09-05 without PAN, user copy or syscalls | core 17,258 + support 20,232 | GNU make; GCC or Clang with ld.lld; Python for symbols and tests | arch, GIC, timer, PSCI and PL011 code is small and separable; scheduler, locks, wait queues and timers share `thread_lock` |
| Zircon (main `78197f39`; f32 `6a563ae1`) | MIT kernel; BSD-2-Clause with PATENTS libraries | C++23 at f32 with ktl, fbl, lockdep; about half Rust at main, including GIC, MMU and scheduler | Linux Image boot; ffx uses `virt-9.2,gic-version=3`; HVF path exists, no Apple Silicon report | per-CPU fair and deadline queues, work stealing, priority inheritance | VMOs, COW, pagers, VMAR ceilings; PAN and LDTR/STTR copy; FP banned in kernel; x20 reserved | about 132k (f32 subset) + 35.8k libraries; 558,919 at main | GN, Ninja, Clang, Rust, Python in the Fuchsia tree; x86-64 Linux host only | arch code free of object headers; thread, scheduler and drivers tied to dispatchers, chainlock, `OwnedWaitQueue` and ZBI |
| FreeBSD 15.1, whole and pieces | BSD-2-Clause and BSD-3-Clause per file; BSD-4 files (UC clause rescinded; TooLs, Stone, Wright not); OpenZFS CDDL-1.0 | C, assembly; no C++ in `sys/` | GENERIC with `std.virt`, GICv3 and ITS; v2m under GICv3 (inferred); FreeBSD 15 under UTM HVF on an M4 Max | yes; `MAXCPU` 1024, NUMA | full VM, EL0 processes; PAN cleared in `copyin` | `sys/` 33,248 files: kern 291,533, vm 48,593, arm64 119,369 | bmake, `make.py` (Python 3), brew bmake, libarchive, llvm@18; CI on macOS | pieces sit on newbus, KOBJ, INTRNG, UMA and `vm_page`: pmap very hard, GICv3 moderate, `virtqueue.c` easy to moderate, network and file systems very hard |
| NetBSD 11 rump kernels | BSD-2-Clause; NRL, Cisco and TooLs advertising clauses in some sources; libzfs CDDL | C | hosted, no hardware code; aarch64 through generic glue; NetBSD 11.0 RC1 under UTM HVF on an M1 Max, 10.1 failed on an M4 | `RUMP_NCPU` virtual CPUs (default 2) on host threads | none: pmap stubs panic; runs in its host's address space | glue 39,184 + librumpuser 7,317 + unmodified sources (networking 245,072) | `build.sh` (POSIX shell, host C and C++) or own makefiles (Genode) | 54 hypercalls, 10 PCI and 4 virtif calls, 13 upcalls; Genode's rumpuser layer is 1,562 lines |
| OpenBSD 8.0 pieces | ISC (agintc, agtimer, smmu, pmap, psci, pluart); BSD-2-Clause (virtio core, transports, vio) | C | GICv3 and ITS, no v2m under GICv3; 7.1 and 7.5 on an M2 under HVF | MAXCPUS 256 | UVM pmap; LDTR/STTR copy | agintc 2,166; smmu 3,577; virtio 1,075; pmap 2,420 | OpenBSD make; pieces need their own glue | virtio core needs only the device framework, atomics, malloc and bus_dma (easy to moderate); agintc and smmu moderate; pmap hard |
| RTEMS 6.2 | BSD-2-Clause; 183 files GPL-2.0+ with linking exception | C | `a53` and `a72` QEMU BSPs on `gic-version=3` at QEMU's GIC addresses; no GICv2m; no HVF report | SMP schedulers, not enabled in the QEMU BSPs | single address space, no EL0 processes | score 34k + 42k headers; AArch64 port 3.9k | waf (Python); RSB-built GCC and newlib | used whole: its POSIX layer carries ERTS with about 20 lines of ERTS C changes (GRiSP); no process model for domains |
| NuttX 13.1.0 | Apache-2.0 | C | `qemu-armv8a`, GICv3 by default; v2m only with GICv2; HVF documented with a GICv2 configuration | SMP with PSCI | `knsh`: EL0 processes with own page tables | sched 58k; GICv3 driver 1,040 | Make with kconfig-frontends or kconfiglib; CMake | POSIX task model and semaphores throughout; virtio drivers depend on OpenAMP |
| Zephyr 4.5.0 | Apache-2.0 | C | `qemu_cortex_a53`, GICv3 with ITS in a static DTS, `secure=on` by default; no HVF report | `/smp` variant, 2 CPUs | EL0 threads, memory domains with page tables and ASIDs | kernel 24.8k; arch/arm64 9.5k | CMake 3.28+, Python 3.12+, dtc, Ninja, west, SDK | device model and devicetree throughout; virtio-mmio v2 only |

## Sources

Every URL below was accessed on 2026-10-29.

| Source | Version, commit or date | URL |
| --- | --- | --- |
| QEMU | v11.1.3; master `5624b266cdd513506fb333e9041778407b6d1ac4` (11.1.50) | https://github.com/qemu/qemu ; https://gitlab.com/qemu-project/qemu/-/raw/v11.1.3/hw/arm/virt.c |
| QEMU documents: "Arm virt"; S. Mediouni, "HVF: Add support for platform vGIC and nested virtualisation" v21; S. Mediouni, "target/arm: hvf: add timer frequency note"; P. Maydell, "target/arm: Default to 1GHz cntfrq for 'max' and new CPUs"; issue 2665 (search summary only); Lima PR 5443; hvi-vmm issue 183 | 11.1.50; 2026-04-29; 2025-07-21; 2024-04-19; -; -; 2026-09-23 | https://www.qemu.org/docs/master/system/arm/virt.html ; https://ratatoskr.run/qemu-devel/2026/04/14444085/t ; https://www.mail-archive.com/qemu-devel@nongnu.org/msg1128672.html ; https://www.mail-archive.com/qemu-devel@nongnu.org/msg1037038.html ; https://gitlab.com/qemu-project/qemu/-/work_items/2665 ; https://github.com/lima-vm/lima/pull/5443 ; https://github.com/brig-sh/hvi-vmm/issues/183 |
| seL4 | 16.0.0, `6e7c3b733d296cfd88d5fbf635c96e447a882374` (2026-07-22) | https://github.com/seL4/seL4/tree/16.0.0 |
| seL4 libraries, tools, proofs, benchmarks | seL4_libs `262a34dcb2f3285be01df9e5404d911132d567a6`; sel4runtime `86489cf6efab9f314964e79468c036e9035394c7`; util_libs `ef49a397b7044fc38b609a99a8c6265a97913b8e`; musllibc (16.0.x-compatible) `b0005f86fecbd6d0257b15363a5b013446914265`; seL4_tools `6493e0c6fab360eb81a8115a49c9ca7bc280c48a`; sel4test `f27e4f4cdd020ef9b37f15ded76a3b38477761f0`; ci-actions `1d96d20092526f3d1403561a16ce9d7c1aeee397`; sel4bench `18f9d5f079bc23551eccbdc2202cae95c72c69d7`; sel4bench-results `87e0b68be832d7a9828f46a375415ae54cf349d8`; l4v master | https://github.com/seL4/ |
| seL4 documents: release notes; issue 1831; verified configurations; QEMU Arm virt; FAQ; licence; assumptions; tools; host dependencies; CAmkES setup; tutorials; news 2026; Microkit roadmap | - | https://github.com/seL4/seL4/releases/tag/16.0.0 ; https://github.com/seL4/seL4/issues/1831 ; https://docs.sel4.systems/projects/sel4/verified-configurations.html ; https://docs.sel4.systems/Hardware/qemu-arm-virt.html ; https://sel4.systems/About/FAQ.html ; https://sel4.systems/Legal/license.html ; https://sel4.systems/Verification/assumptions.html ; https://sel4.systems/tools.html ; https://docs.sel4.systems/projects/buildsystem/host-dependencies.html ; https://docs.sel4.systems/projects/camkes/setting-up.html ; https://docs.sel4.systems/Tutorials/ ; https://sel4.systems/news/2026.html ; https://docs.sel4.systems/projects/microkit/roadmap.html |
| Proofcraft news; seL4 performance page; devel list, "HVC is not supported for PSCI!"; A. Lyons, K. McLeod, H. Almatary, G. Heiser, "Scheduling-Context Capabilities", EuroSys 2018, doi:10.1145/3190508.3190539 | -; generated 2026-10-29 (manifest `655f2655`); 2025-10-23; 2018 | https://proofcraft.systems/news-2026/ ; https://proofcraft.systems/news-2025/ ; https://sel4.systems/performance.html ; http://www.mail-archive.com/devel@sel4.systems/msg04575.html ; https://trustworthy.systems/publications/full_text/Lyons_MAH_18.pdf |
| Microkit; rust-sel4 | 2.3.1 `ec86afdcd662b5976d11d4994acf1b11a2979882` (2026-09-18); `dbe6445d56059ed9a757e53c7137892aece1d179` | https://github.com/seL4/microkit/tree/2.3.1 ; https://github.com/seL4/rust-sel4 |
| sDDF; sdfgen; Djawula | 0.7.0 `650ace5dba984f5d9c7dd1a005648ff7b40655f7` (2026-08-19); 0.35.0 `0fdbd7429d2e8eceb599b6b4bca67cbccfaf1001`; - | https://github.com/au-ts/sddf/tree/0.7.0 ; https://github.com/au-ts/microkit_sdf_gen ; https://pypi.org/pypi/sdfgen/0.35.0/json ; https://trustworthy.systems/projects/Djawula |
| LionsOS, pinned dependencies and documents; G. Heiser et al., "Fast, Secure, Adaptable: LionsOS Design, Implementation and Performance", arXiv:2501.06234v2 | 0.4.0 `ad4c35ea7ae657d2f450e45c821035e746cfa48a` (2026-08-21); libnfs `c45e08d18589493a1a6818dec203ed23a20b85d4`; micropython `647c8b96cae7e202c7a020395b7cfe65e5b8ce04`; microdot `dac6df7a7a31390dc8970571b89cdb11e3be0041`; wasm-micro-runtime `66c110780991d2227cf7e5c50e928f1c9bac7e49`; musllibc `ee77eeceaeabe97b5a1aed454683e9d39ee6c591`; libvmm 0.2.0 `7069ab99d25d3e05783b8b3fbd68fde2a1b6cf4e`; libmicrokitco `4bf88ee12c19823ff8c6d3122b6a298a5d8147ea`; paper 2025-05-27 | https://github.com/au-ts/lionsos/tree/0.4.0 ; https://lionsos.org/ ; https://lionsos.org/docs/releases/0.4.0/ ; https://lionsos.org/docs/status_and_roadmap/ ; https://lionsos.org/docs/use/language_support/libc/ ; https://arxiv.org/abs/2501.06234 |
| camkes-tool; Chrysopolis | camkes-3.13.0 `00965e755c918da493222f36886b8743a4c1b152` (2026-07-22); `07c3011a1a17e9ac983f2a0853b4d6d27624c61b` (2026-10-20) | https://github.com/seL4/camkes-tool ; https://github.com/byzantine-systems/chrysopolis |
| Erlang/OTP; `erl` flags; OTP 21.0 readme (OTP-14518) | OTP-29.1.2; master `d648a433d2043db81b02fb9bdb6ba72352ca7c01` (30.0-rc0) | https://github.com/erlang/otp ; https://www.erlang.org/doc/apps/erts/erl_cmd.html ; http://erlang.org/download/otp_src_21.0.readme |
| LK; lkuser | `e7cefb16f109e58c92fc82f8e74e514e924d1c4f` (2026-10-27), later `d3d8ddf8c4bbdb393073b9657197cd014b8f0500`, branch `wip/preempt-disable` `ac05bdb3`; lkuser `bd4ec158ede7f3d4ed7de03e1137d0cc2e330bd0` (2026-09-07) | https://github.com/littlekernel/lk ; https://github.com/littlekernel/lkuser |
| Fuchsia; Trusty; fuchsia.dev pages (licensing policies 2025-07-31, emulator and build 2026-10-13, zx_and_lk, fair_scheduler, handle_duplicate, vmar_allocate, restricted_enter, iommu_create); "FEMU on an M1 Mac" (2021-06-17); Android Trusty; TF-A TLK dispatcher | main `78197f39d46dbe494e5d9f6c1f59f45a26ca2ddf` (2026-10-29), releases/f32 `6a563ae1d358f78987bc0c67868bd5ab0a1e39cb` (2026-07-27), releases/f33 `08effcaa9f747b896c2a78b44aa2c939e53297c9` (2026-10-22); trusty/lk/common `3a18735a`, trusty/lk/trusty `a1bb76cc` | https://fuchsia.googlesource.com/fuchsia ; https://android.googlesource.com/trusty/lk/common ; https://android.googlesource.com/trusty/lk/trusty ; https://fuchsia.dev/ ; https://fuchsia.dev/reference/syscalls/iommu_create ; https://groups.google.com/a/fuchsia.dev/g/discuss/c/SUpirxBybQ0 ; https://source.android.com/docs/security/features/trusty ; https://trustedfirmware-a.readthedocs.io/en/latest/components/spd/tlk-dispatcher.html |
| FreeBSD; 15.1 announcement and release notes; platforms; FreeBSD-SA-26:31.arm64 (2026-06-09); wiki `arm64/QEMU` (unreadable); UTM issues 7598 and 6918; smallhacks blog (2022-06-09) | releng/15.1 `95719d8a895bf8170851e9844d9b4092b1d2b6fe` (release/15.1.0-p6, 2026-10-20) | https://git.freebsd.org/src.git ; https://www.freebsd.org/releases/15.1R/announce/ ; https://www.freebsd.org/releases/15.1R/relnotes/ ; https://www.freebsd.org/platforms/ ; https://www.freebsd.org/security/advisories/FreeBSD-SA-26:31.arm64.asc ; https://wiki.freebsd.org/arm64/QEMU ; https://github.com/utmapp/UTM/issues/7598 ; https://github.com/utmapp/UTM/issues/6918 ; https://smallhacks.wordpress.com/2022/06/09/booting-freebsd-13-1-arm64-on-macos-arm64-using-qemu/ |
| NetBSD and rump: source; 11.0 announcement, source sets (`syssrc.tgz` SHA512 `318d451e...3057`) and redistribution page; rumprun, buildrump.sh, rumpkernel.github.io; Genode `dde_rump`; ssumpf/rump; SEL4PROJ/rumprun and its announcement (2017-03-06); Hurd rumpdisk, FOSDEM 2022 (search summary only); astr0baby, NetBSD on M1 | netbsd-11 `3b308647b1447f153e80c9a6efc8a751d858ef57` (2026-10-25); trunk `4a74c4f51700599977158ed45e6d24bf20fb049d`; rumprun `b04d422` (2020-05-11); buildrump.sh `6cccd46` (2017-09-10); rumpkernel.github.io `6e209f1`; Genode master `0f275e7a`; ssumpf/rump `28945d1`; SEL4PROJ/rumprun `0be59c6` | https://github.com/NetBSD/src ; https://www.netbsd.org/releases/formal-11/NetBSD-11.0.html ; https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/source/sets/ ; https://www.netbsd.org/about/redistribution.html ; https://github.com/rumpkernel ; https://github.com/genodelabs/genode/tree/master/repos/dde_rump ; https://github.com/ssumpf/rump ; https://github.com/SEL4PROJ/rumprun ; https://lists.sel4.systems/hyperkitty/list/devel@sel4.systems/thread/ADTORDWZUVEAWJIOT5VMKK72YJDZ7ZDU/ ; https://archive.fosdem.org/2022/schedule/event/dzammit/ ; http://astr0baby.online/M1-Apple/NetBSD-M1-Qemu/ |
| OpenBSD; 7.8 and 7.9 changelogs; policy; astreknet, OpenBSD on M2 | 8.0 (2026-10-20), `sys.tar.gz` SHA256 `964b1aed...2aaf` | https://cdn.openbsd.org/pub/OpenBSD/8.0/ ; https://www.openbsd.org/plus78.html ; https://www.openbsd.org/plus79.html ; https://www.openbsd.org/policy.html ; https://gist.github.com/astreknet/4860e3362ad98e1116f0a970b99e2afc |
| RTEMS; RTEMS documentation 7.5ece2a4 (A72 BSP, build system, licence requirements; 2026-06-12); GRiSP | 6.2 `be446b02d091a2a745e03405eaab4de078571532`; main `402de13a864f8876c48a8c108cc2e3541d87bd07`; GRiSP `9dfbeb5b0317f0254fa4b95a50b9abb8471dacdd` | https://gitlab.rtems.org/rtems/rtos/rtems ; https://docs.rtems.org/docs/main/user/bsps/aarch64/a72.html ; https://docs.rtems.org/docs/main/user/bld/index.html ; https://docs.rtems.org/docs/main/eng/license-requirements.html ; https://github.com/grisp/grisp |
| NuttX and its install guide; Zephyr and its getting-started guide | nuttx-13.1.0 `2b5c0de5e933281c209f954a63b99cf10c132346`; v4.5.0 `41d10b59730406bbab4ca9f1fbbe9e96aafb4966` | https://github.com/apache/nuttx ; https://nuttx.apache.org/docs/latest/quickstart/install.html ; https://github.com/zephyrproject-rtos/zephyr ; https://docs.zephyrproject.org/latest/develop/getting_started/index.html |
| Other kernels I; Unikraft Atlas release post (2023-05-15) | unikraft/unikraft RELEASE-0.21.0 `7351f8b563c9e6773da9fdd5bacde6ac91e32112`; unikraft/kraftkit `adc93ad6b95e5ca6dba6b51cb38178c2c09aee6b`; TrustedFirmware-A/trusted-firmware-a v2.15.0 `da738d5eae93af342fdc4995dd3c05acb4c9d757`; RT-Thread/rt-thread v5.3.0 `99428a1e7f7447955aa860f7c969273a12095b8f`; HelenOS/helenos `776168b19bf9e89b6b6162ca77e9ac593964142f`; managarm/managarm `f60c2640fb13e829b0952ff84ae12d687df74cbf`; SerenityOS/serenity `ccdd6504f91a9bbe98d84d0afbc5dd882c3b5f24`; plan9foundation/plan9 `ed1a9c21e3297d7497a48053d33683375c75fbb4`; 9front/9front `13d3301fc5887ad9dd7f2f487fb55b850eff516b`; inferno-os/inferno-os `36616fe590c21a8d04981dcce15db66639f7bbd7`; caerwynj/inferno64; BarrelfishOS/barrelfish `06a9f54721a8d96874a8939d8973178a562c342f` | https://github.com/ ; https://unikraft.org/blog/2023-05-15-unikraft-releases-atlas |
| Other kernels II; Kernkonzept, switch to the MIT licence | nanovms/nanos 0.1.56 `aad473aad2f73a9893d5c32be333f2796725ab82`; eclipse-threadx/threadx v6.5.2.202603_rel `93387b0a60382a29579bbad5045c68328e3751df`; FreeRTOS/FreeRTOS-Kernel V11.3.2 `640d0c43705e64cd53f46b31d882de6cd8433933`; OP-TEE/optee_os 4.11.0 `f54190f22611dd5ad5d22546fd4209aa100f56bd`; Hafnium v2.15.0 `676ab03c6a3d78f10ddc0f8b96c02475da24392f`; genodelabs/genode 26.02 `24a30a049ae0f79cc52530032802f400ce594d42`; udosteinberg/NOVA `ec4a8794da5ea6057441bd7c84781ea542f37395`; kernkonzept/fiasco `50bbe8a981199e17865e8553a4eb02c387b339cf`; xen-project/xen RELEASE-4.22.0; Linux `COPYING`; cloudius-systems/osv v0.57.0 `e4854b26`, master `28c0f5a4b6687492387fca6b4f325faa4d891f93`; klange/toaruos `60b54503807a38ae1f0692d44cf8b569301febbc`; bao-project/bao-hypervisor v2.0.0 `0af4a1ab558ad60c9658af4f43756c4536dd3141` | https://github.com/ ; https://git.trustedfirmware.org/hafnium/hafnium.git ; https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/COPYING ; https://www.kernkonzept.com/press/kernkonzept-switches-to-l4re-mit-license/ |
| Network libraries | lwIP STABLE-2_2_1_RELEASE `77dcd25a72509eb83f72b033d219b1d40cd8eb95`; tass-belgium/picotcp v1.7.0 `13c00a067190f5ec62340ed932a2bb833c366d63`; virtualsquare/picotcp v2.1 `dc9cfc0145151012cf1946774ef1795fe221079c`; butok/FNET v4.7.1 `9e2764a77582fcc5249c957f6230db589b945dee`; adamdunkels/uip `a49def743f6e5c7d0c0f2d724f0b8e0c563a4a37`; FreeRTOS/FreeRTOS-Plus-TCP V4.4.2 `b86ad086e9870099bb0ac18a75dcb7f6dd508cc7`; eclipse-threadx/netxduo v6.5.2.202603_rel | https://git.savannah.nongnu.org/git/lwip.git ; https://github.com/ |
| Storage, virtio and device-tree libraries | littlefs-project/littlefs v2.11.3 `6cb4e86540eca0d9ba62500a298385c9d863c8be`; FatFs R0.16 (`arc/ff16.zip`); gkostka/lwext4 `58bcf89a121b72d4fb66334f1693d3b30e4cb9c5`; OpenAMP/open-amp v2026.04.0 `5bcc7c0401cace5e3d6719a06a0d1f92e30251aa`; OpenAMP/libmetal v2026.04.0 `80ab6b0d506a0d8eb4f2b87926682ababbb804b3`; dgibson/dtc v1.8.1 `8f48565e5cfedc74d3f7512f1e0188e9d85dc1de` | https://github.com/ ; https://elm-chan.org/fsw/ff/ |
| Rust projects: Redox schemes; Hubris reference; Tock design; Theseus | - | https://doc.redox-os.org/book/schemes.html ; https://hubris.oxide.computer/reference/ ; https://book.tockos.org/doc/design ; https://github.com/theseus-os/Theseus |
| Related research records (QEMU measurements; ERTS host requirements) | 2026-10-29 | [research-baselines.md](research-baselines.md) ; [research-erts-host.md](research-erts-host.md) |
