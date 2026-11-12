# TF-A's Raspberry Pi 4 BL31 on QEMU's raspi4b model

A point-in-time record of the experiment of stage (a), package 1 of
[plan.md](plan.md#1b-i-the-raspberry-pi-4-on-the-stopgap), "BL31 on the
model". It was run on 2026-11-12 on an Apple Silicon macOS host with QEMU
11.1.3 under TCG, TF-A v2.15.0 (the tag commit `da738d5e`) and Homebrew's
LLVM (clang and lld) as the compiler, with Homebrew's GNU sed, `dtc` and
Ruby. The experiment's files are in `~/erxos-scratch/rpi4-spike/` and
`~/erxos-scratch/tools/rpi4_patch_stub.rb`. They are not in the tree and
are not kept in it; this record quotes only the lines that matter. The
settings the harness needs are in
[design-platforms.md](design-platforms.md#bring-up-under-qemu).

## Question

[design-platforms.md](design-platforms.md#bring-up-under-qemu) named four
things it did not know about running TF-A's Pi 4 BL31 on the model in
place of the Pi firmware, which QEMU does not emulate:

1. at which addresses BL31 expects a device tree and a kernel already
   loaded;
2. how the other three CPUs start under QEMU's generic loader, which
   sets only CPU 0's entry;
3. whether BL31's set-up of the GIC's security groups works on a GIC-400
   modelled without them;
4. whether the model resets through the power-management watchdog, as
   BL31's `SYSTEM_RESET` and `SYSTEM_OFF` do.

If the chain runs, the model's gate covers EL2 entry, PSCI, four CPUs and
reset; if it does not, the model runs one CPU and the board alone covers
the rest.

## Setup

* **BL31.** `PLAT=rpi4 DEBUG=1`, built from the v2.15.0 release tarball
  (SHA-256 `67b772aaa58218712c062ccd103f1d53cf74d9543e251f20ac037a6dbf821a10`
  as downloaded; this was not checked against any published value, and the
  tree so far pins only the tag commit). It builds with LLVM alone, no GCC.
  TF-A's makefiles need GNU sed; macOS's BSD sed does not do. The debug
  build is 145 lines of make output with no error
  (`rpi4-spike/logs/build.log`).
* **Test image.** A small AArch64 program, `rpi4-spike/payload/payload.S`,
  linked at `0x80000`. It prints the exception level, the address in `x0`,
  `MPIDR_EL1`, the GIC distributor's `GICD_TYPER` and PSCI's version on
  both the PL011 and the mini UART; starts CPUs 1 to 3 with `CPU_ON`, each
  reporting back and ending with `CPU_OFF`; reads the timer's interrupt
  from the GIC's CPU interface; and ends with `SYSTEM_OFF` or, built with
  `-DDO_RESET`, `SYSTEM_RESET`.
* **Device tree.** QEMU gives raspi4b none, so the experiment used a
  hand-written minimal tree, `rpi4-spike/payload/raspi4b-min.dts`, with
  a memory node, four Cortex-A72 CPU nodes, the two UARTs and the GIC.
* **Loading.** `-M raspi4b` with no `-kernel` and no `-bios`, and QEMU's
  `-device loader` three times: BL31 at address 0 with `cpu-num=0`, the
  test image at `0x80000`, the device tree at `0x3000000`. `-no-reboot`,
  serial output to files, `-display none`. The exact command lines were
  not kept; the harness of package 4 owns the final form.
* **Stub header.** The Pi firmware patches the 8 bytes at `0xf0` of the
  armstub it loads. BL31's entry reads them: `stub_magic` (0),
  `dtb_ptr32` and `kernel_entry32`. The loader does not, so
  `tools/rpi4_patch_stub.rb` writes them into a copy of `bl31.bin` before
  it is loaded (`bl31-patched.bin`, with the device tree address and
  `0x80000`). Setting TF-A's `PRELOADED_BL33_BASE` and `PRELOADED_DTB_BASE`
  build options alone did not work.

## Results

The four uncertainties, in order, and what else the runs showed. Four
runs (`rpi4-spike/logs/run1-*` to `run4-*`) used `SYSTEM_OFF` and
`SYSTEM_RESET` images, with and without the GIC option below.

1. **Addresses.** BL31 takes both from the stub header at `0xf0`. With it
   patched, BL31 enters the test image at `0x80000` with `x0` holding the
   device tree address; it also reads the tree and writes `Changed device
   tree to advertise PSCI`. The kernel entry printed is `Entry point
   address = 0x80000`.
2. **Other CPUs.** All four CPUs leave reset at address 0 in EL3 when the
   machine has no `-kernel` and no `-bios`, as on the board. BL31 parks
   CPUs 1 to 3 (`CPU Node : MPID 0x1 ... State OFF`) and `CPU_ON` starts
   each at the entry given, in EL2, with the context argument passed
   through (`secondary: ctx=0x...3 mpidr=0x...80000003 EL=0x...2`). The
   model refuses `-smp` below 4, so there is no one-CPU variant to
   compare with.
3. **GIC.** QEMU's raspi4b GIC-400 is built without the security
   extensions, and BL31 still runs: it initialises the GICv2 driver and
   enters the normal world. But behind BL31 the normal world sees the
   secure layout. `GICD_TYPER` reads `0x66` and interrupts arrive
   spurious: the timer's interrupt reads `GICC_IAR = 0x3fe`, with
   `GICC_CTLR = 0x9` and `GICD_IGROUPR0 = 0xffffffff`. With `-global
   arm_gic.has-security-extensions=on` `GICD_TYPER` reads `0x466` and the
   timer arrives as `GICC_IAR = 0x1e`. See the next section.
4. **Reset.** `SYSTEM_OFF` logs `PSCI_SYSTEM_OFF: Invoking watchdog
   reset`, writes the power-management watchdog, and QEMU exits with
   status 0 under `-no-reboot`; `SYSTEM_RESET` does the same. On a board
   `SYSTEM_OFF` halts in the firmware instead, so the model shows reset
   where the board halts
   ([design-platforms.md](design-platforms.md#ending-the-machine)).

Also:

* **Entry state.** EL2, `SPSR = 0x3c9` (EL2h, all of DAIF masked), MMU
  off, `x0` the device tree.
* **PSCI.** Version 1.1 (`PSCI_VERSION = 0x10001`); `CPU_ON` for CPUs 1 to
  3 returned 0; `CPU_OFF` completed on each.
* **UARTs.** BL31's own console uses the PL011 on the model, since
  TF-A's Pi 4 port picks the mini UART only when GPIO14 is in ALT5, which
  the model does not set. The test image printed on both, so the mini UART
  works for a kernel. QEMU logs `AUX_MU_LCR_REG unsupported` and
  `AUX_MU_CNTL_REG unsupported` for the mini UART's registers; these are
  harmless.
* **Errata.** The debug BL31 prints `WARNING: BL31: cortex_a72: CPU
  workaround for erratum 1319367 was missing!`, beside notices that the
  workarounds for 859971 and for CVE-2017-5715, CVE-2018-3639 and
  CVE-2022-23960 were applied. The Pi 4 port's `platform.mk` sets
  `ERRATA_A72_859971` and `WORKAROUND_CVE_2017_5715` and not
  `ERRATA_A72_1319367`, which TF-A documents as applying to all
  Cortex-A72 revisions. No design document names this erratum:
  [design-arch-aarch64.md](design-arch-aarch64.md#speculation-mitigations)
  relies on the branch-target-injection workaround only. The flag is a
  one-line build option (`ERRATA_A72_1319367=1`); whether erXos's kernel
  or the stopgap needs it was not decided here and is a `TODO.md` item.

## The GIC finding

The model's GIC-400 has no security extensions, but BL31 configures it
as one that has them. The runs show the result, not the mechanism: the
normal world reads the distributor as the secure layout and its
interrupts arrive spurious. QEMU's `arm_gic` device has the switch:
`-global arm_gic.has-security-extensions=on` gives the GIC-400 of the board
(`GICD_TYPER` `0x466`), and the timer's interrupt arrives as interrupt 30.
The harness therefore always passes it for `raspi4b`. The board's GIC-400
has the extensions, so the option makes the model closer to the board, not
further.

## What the model still never checks

The model runs the chain from BL31 on. Everything before it is the Pi
firmware's, which QEMU does not emulate: reading `config.txt`, the
firmware's edits to the device tree (the memory node, `/chosen/stdout-path`,
the Ethernet MAC address), where it places the tree and the bootable file,
the entry state it leaves, and the size of bootable file it accepts. The
stub header patch above stands in for one of them, and the experiment's
device tree is not the board's. The model's DMA is coherent, it has no
UART3, its mini UART takes no clock, and it has no Ethernet or PCIe
([design-platforms.md](design-platforms.md#bring-up-under-qemu)). Its
power-management watchdog ends the run where a board's `SYSTEM_OFF` halts.
A stage proven on the model therefore still counts only once it has passed
on a board.

## What erXos's harness must do

* Boot `raspi4b` with the 2 GiB model, four CPUs, no `-kernel` and no
  `-bios`, with `-global arm_gic.has-security-extensions=on`.
* Load, with `-device loader`: BL31 (patched as below) at 0 with
  `cpu-num=0`, the bootable file at the entry address, the device tree at
  its address.
* Patch the stub header at `0xf0` of the BL31 it loads: `stub_magic` 0,
  `dtb_ptr32`, `kernel_entry32`, as the firmware does.
* Supply the device tree itself, since QEMU has none: the board's tree
  with `config.txt`'s overlays and the firmware's edits applied on the host.
* Take the console from the second serial port, as
  [design-platforms.md](design-platforms.md#bring-up-under-qemu) says. BL31
  itself prints on the PL011, the first port. Run with `-no-reboot`, so a
  PSCI reset or off ends QEMU with status 0.
* Build BL31 with GNU sed on the path.
* Not rely on `SYSTEM_OFF` halting: on the model it resets.

## Open items

* The TF-A tarball's SHA-256 above is what was downloaded; the fetch step
  pins it against a value checked from a second source.
* Whether to build BL31 with `ERRATA_A72_1319367=1`.
