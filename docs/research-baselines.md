# Research record: QEMU boot facts and runtime baselines

A point-in-time report of what was measured on the primary host to settle
the machine-level facts the architecture rests on: how QEMU's `virt` board
hands control and the device tree to a kernel, which exception levels and
interrupt controllers each accelerator offers, what an exception round trip
costs under TCG and under HVF, whether TCG transcripts can be made
deterministic, and what an ERTS node costs to boot, keep and talk to. The
design decisions that use these numbers are in [design.md](design.md) and
[design-kernel.md](design-kernel.md). Numbers here are never edited in place;
a re-measurement gets a new record.

**Date:** 2026-10-29.
**Host:** Apple M4 Max, 16 cores (12 performance, 4 efficiency), 64 GiB;
macOS 27.0.1 (26A434), Darwin 27.0.0. The host was heavily loaded: `uptime`
reported load averages of 38 to 81 during the ERTS measurements and 100 to
160 during the interrupt measurements.
**Tools:** QEMU 11.1.2 (Homebrew), machine type `virt-11.1`; Homebrew LLVM
clang 23.1.4 as assembler, `llvm-objcopy` and `llvm-readelf` from the same
release; Ruby 4.0.7; dtc 1.8.1; Erlang/OTP 28.4.2 (erts 16.3.1, Homebrew,
JIT flavor) for the runtime baselines.
**Experiments** live outside the tree in `~/erxos-scratch/`:
`probe/probe.S` (boot and exception probe, SHA-256 prefix `321f74c65d46d5a6`),
`probe/mkelf.rb` (wraps the probe in a one-segment ELF64), `probe/mkprobe2.rb`
(derives `probe2.S`, prefix `94e7fe7e742f6139`, which adds a GICv3 timer
interrupt test, and from it `probe3.S`, which polls instead of waiting),
`bench/bench_pp.erl` (message round trips, prefix `947afe8ab086bc63`),
`bench/gate_dec.erl` (restricted term decoder, prefix `e343d4e2a02d9541`),
and `qemu/*.dts` (decompiled device trees).

## The probe

`probe.S` is one position-independent AArch64 blob with no relocations. Its
first 64 bytes are a Linux arm64 Image header (branch, `text_offset` 0,
`image_size` 4 MiB, flags `0xa`: little-endian, 4 KiB pages, placement
anywhere, magic `ARM\x64`), so QEMU boots it through the Linux protocol;
`mkelf.rb` wraps the same bytes in an ELF64 with one `PT_LOAD` segment for
QEMU's bare-metal ELF path. It prints, to the PL011 at `0x09000000`, the
entry registers `x0` and `x1`, its load address, `CurrentEL`, the first word
of RAM and the word at `x0` (a device tree starts with the big-endian magic
`d00dfeed`, read little-endian as `0xedfe0dd0`), and selected ID registers.
If it entered at EL2 it drops to EL1 (`HCR_EL2.RW`, `CNTHCTL_EL2` = 3,
`CNTVOFF_EL2` = 0, `eret`). It then builds a two-level identity map (one
1 GiB device block below RAM; 2 MiB normal blocks for RAM, one of them
EL0-accessible and PXN), enables the MMU and caches, and times 1,000,000
iterations of each loop with `CNTVCT_EL0`:

* an empty EL1 loop (loop overhead);
* an EL1 loop writing `TTBR0_EL1` with alternating ASIDs followed by `isb`;
* an EL0 loop issuing `svc #0`, whose handler only checks ESR and returns
  (`svc_min`);
* the same with a handler that saves and restores all 31 general registers,
  `ELR_EL1`, `SPSR_EL1` and `SP_EL0` (`svc_full`), a model of a real kernel
  entry;
* the same with a handler that switches `TTBR0_EL1` between two ASIDs and
  executes `isb` (`svc_asid`), a model of a cross-address-space switch.

Every run ends with PSCI `SYSTEM_OFF` (through `hvc`, or `smc` when the probe
entered at EL2), and QEMU exits with status 0.

## Boot conventions

All runs used `-M virt-11.1,gic-version=3 -m 512M -smp 1`.

| Path | Accelerator | Entry EL | `x0` at entry | Load address | Device tree |
| --- | --- | --- | --- | --- | --- |
| Linux Image (`-kernel probe.bin`) | TCG `cortex-a76` | 1 | `0x48000000` | `0x40200000` | at `x0`; header `totalsize` 1 MiB |
| Linux Image | HVF `-cpu host` | 1 | `0x48000000` | `0x40200000` | at `x0`; `totalsize` 1 MiB |
| Linux Image, `virtualization=on` | TCG `cortex-a76` | **2** | `0x48000000` | `0x40200000` | at `x0` |
| Linux Image, `virtualization=on` | HVF `-cpu host` | **2** | `0x48000000` | `0x40200000` | at `x0` |
| ELF linked at `0x40080000` | TCG | 1 | `0` | `0x40080000` | **absent**: RAM base reads 0 |
| ELF linked at `0x40400000` | TCG and HVF | 1 | `0` | `0x40400000` | at `0x40000000` |

* Under the Linux protocol the device tree sits at RAM base + 128 MiB
  (`0x48000000`) for 256 MiB, 512 MiB, 2 GiB and 8 GiB of RAM (HVF, `-smp 4`).
  With an initrd, QEMU places the initrd at `0x48000000` and the device tree
  directly after it: a 64 MiB initrd gave `linux,initrd-start` `0x48000000`,
  `linux,initrd-end` `0x4c000000` and `x0` = `0x4c000000`; a 200 MiB initrd
  ended at `0x54800000`. The kernel must read `x0`, never assume an address.
* Under the ELF path QEMU passes nothing in `x0` and writes the 1 MiB device
  tree at the RAM base only when no ELF segment overlaps it. An ELF that
  overlaps the first MiB of RAM boots with no device tree at all, silently.
* Both accelerators drop cleanly from EL2 to EL1 with the sequence above, and
  PSCI through `smc` works at EL2 entry.

## Accelerator capabilities

From `-M ...,dumpdtb=` runs decompiled with dtc, and from QEMU's refusals:

| Question | TCG (`cortex-a76`, `max`) | HVF (`-cpu host`) |
| --- | --- | --- |
| `gic-version=2` | accepted | refused: "HVF does not support GICv2 emulation" |
| `gic-version=3` | accepted; ITS at `0x08080000` | accepted; GICv2m MSI frame at `0x08020000`, no ITS |
| `virtualization=on` (EL2) | accepted; entry at EL2 | accepted; entry at EL2 |
| `secure=on` (EL3, TrustZone) | accepted | refused: "HVF does not support providing Security extensions" |
| `iommu=smmuv3` | accepted (option only; translation not exercised) | accepted (option only) |
| `CNTFRQ_EL0` | 62,500,000 Hz | 24,000,000 Hz |
| `MIDR_EL1` | `0x414fd0b1` (Cortex-A76) | `0x610f0000` (Apple) |
| PSCI method in `/psci` | `hvc` (`smc` with EL2) | `hvc` (`smc` with EL2) |
| `/chosen` | `stdout-path`, 32-byte `rng-seed`, `kaslr-seed` | same |

The GICv3 distributor is at `0x08000000` and the redistributors at
`0x080a0000` under both accelerators. Timer interrupts in `/timer` are PPIs
13, 14, 11 and 10 (INTIDs 29, 30, 27, 26: secure physical, non-secure
physical, virtual, hypervisor), all level-triggered.

ID registers read at EL1:

| Register | TCG `cortex-a76` | HVF (M4) | Reading |
| --- | --- | --- | --- |
| `ID_AA64PFR0_EL1` | `0x1100000011110012` | `0x1101000010110011` | under HVF the GIC field reads 0 although the GICv3 system-register interface works; EL2 and EL3 read as absent at EL1 in both |
| `ID_AA64MMFR0_EL1` | `0x101122` | `0x10000f100022` | 40-bit PA and 16-bit ASIDs in both; HVF supports 4 KiB and 16 KiB granules but **not 64 KiB** |
| `ID_AA64MMFR1_EL1` | `0x10212122` | `0x100011312000` | PAN present in both (level 2 on TCG, level 3 on HVF) |
| `ID_AA64ISAR0_EL1` | `0x100010211120` | `0x221100110212120` | LSE atomics in both; **no RNDR** in either |

Consequences recorded in the design: GICv3 is the only interrupt controller
that works on both accelerators; the kernel finds the GIC from the device
tree, not from `ID_AA64PFR0_EL1`; the 4 KiB granule is the only one common to
every target (Cortex-A57 and A72 lack 16 KiB, HVF lacks 64 KiB); entropy
cannot come from RNDR, so the boot seed is `/chosen/rng-seed`.

## Exception and address-space switch costs

Nanoseconds per iteration, from `CNTVCT_EL0` ticks over 1,000,000
iterations, including loop overhead (the empty loop: 0.3 ns under HVF, 0.9 to
1.2 ns under TCG). Each EL0 test ran twice where two values are shown.

| Run | TTBR0 write + `isb` (EL1) | `svc_min` | `svc_full` | `svc_asid` |
| --- | --- | --- | --- | --- |
| HVF, Image | 11.3 | 23.4, 22.0 | 28.2 | 30.7 |
| HVF, ELF at `0x40400000` | 10.6 | 22.2, 22.4 | 28.2 | 31.2 |
| HVF, Image, entered at EL2 | 10.6 | 23.2, 22.5 | 30.0 | 31.9 |
| TCG `cortex-a76`, Image | 1,801.7 | 531.0, 495.8 | 801.8 | 2,341.4 |
| TCG, ELF at `0x40080000` | 1,465.9 | 483.8, 483.0 | 653.2 | 2,146.8 |
| TCG, ELF at `0x40400000` | 1,483.5 | 484.1, 489.1 | 654.9 | 2,190.2 |
| TCG, Image, entered at EL2 | 1,479.9 | 556.9, 637.0 | 746.9 | 2,403.2 |

Under HVF an EL0 system call never leaves the guest, so these are native
costs of the M4 core: about 22 ns for a minimal trap and return, about 28 ns
with a full register save, about 31 ns when the handler also switches
address spaces. TCG is 20 to 75 times slower on these paths and is not a
performance reference. These tight loops are short (about 23 ms each under
HVF), and repeated runs agreed within 7% despite the host load.

## Timer interrupts

`probe2.S` initialises the GICv3 for a single security state (`GICD_CTLR` =
`0x13`), wakes the redistributor of CPU 0, puts INTID 27 in group 1 with
priority `0x80`, enables the system-register CPU interface (`ICC_SRE_EL1` =
7, `ICC_PMR_EL1` = `0xff`, `ICC_IGRPEN1_EL1` = 1), and arms the EL1 virtual
timer (`CNTV_CVAL_EL0`) every 1 ms, re-arming from the previous deadline in
the handler; it waits with `wfi`. `probe3.S` replaces `wfi` with a busy loop.

All 200 interrupts were delivered under TCG and under HVF in every run, with
200 ms spans for 200 deadlines. Latency from deadline to handler entry was
not characterised: means of 0.4 to 1.4 ms and maxima of 2.8 to 20 ms tracked
the host load (100 to 160), not the guest, and one HVF busy-loop run gave a
mean of 68 µs. A latency measurement needs an idle host and is listed in
[plan.md](plan.md) as part of gate G2.

## Deterministic TCG

Seven runs of the probe with `-accel tcg,thread=single -icount
shift=0,sleep=off -M virt-11.1,gic-version=3,dtb-randomness=off` produced
byte-identical guest output, including every `CNTVCT_EL0`-derived timing,
because under `icount` virtual time advances with the instruction count. The
only variation was a QEMU host-side warning on standard error ("icount sleep
disabled and no active timers") in some runs, so a transcript harness must
capture the guest's serial stream separately from QEMU's own output.
`dtb-randomness=off` removes the random `rng-seed` and `kaslr-seed`
properties, which would otherwise differ per run.

## ERTS node baselines (host, OTP 28.4.2)

These are indicative stand-ins for OTP 29.1.2 on erXos: they use macOS, the
JIT flavor and Homebrew's build. They bound orders of magnitude; the
measurements that count are repeated on erXos (plan gates G4 and G5).

**Boot.** `erl -noshell -boot start_clean -eval 'halt().'`, six runs:
0.11 to 0.27 s wall-clock including the `erl` script and `erlexec`. The VM's
own `statistics(wall_clock)` at the `-eval` point, with one scheduler, one
dirty CPU, one dirty I/O and one async thread:

| Mode | Wall at `-eval` | CPU at `-eval` | Modules loaded | `erlang:memory(code)` |
| --- | --- | --- | --- | --- |
| interactive | 82 to 105 ms | 67 to 71 ms | 108 | 5.3 MB |
| embedded | 131 to 140 ms (466 ms on the first, cold run) | 115 to 131 ms | 221 | 9.6 MB |

**Size.** An idle node, measured after 1.2 s:

| Flags | `erlang:memory(total)` | of which processes / system | RSS | Threads |
| --- | --- | --- | --- | --- |
| defaults (16 cores) | 50.0 MB | 13.3 / 36.7 MB | 83 MB | 48 |
| `+S 1 +SDcpu 1 +SDio 1 +A 1` and no busy waiting | 42.8 MB | 12.8 / 30.0 MB | 70 MB | 9 |
| the same with `+P 1024 +Q 1024 +t 65536` | 10.0 MB | 0.5 / 9.5 MB | 37 MB | 9 |

The process and port tables are preallocated from `+P` and `+Q` (defaults
1,048,576 and 65,536), which dominate a small node; shrinking them moves a
node from about 43 MB to about 10 MB of runtime-accounted memory. macOS RSS
also counts shared libraries and the JIT's code, so it overstates what a node
would privately own on erXos.

**Messages.** `bench_pp.erl` sends `{ping, From, Payload}` and waits for
`{pong, _}`, 200,000 round trips locally and 50,000 between two nodes on the
same host over TCP loopback distribution (two runs each):

| Path | `ok` | 1 KiB binary | 64-tuple list (about 1 KiB as a term) |
| --- | --- | --- | --- |
| same node | 410 ns, 1,734 ns | 427 ns, 516 ns | 2.77 µs, 2.36 µs |
| two nodes, TCP loopback | 57.4 µs, 56.8 µs | 47.6 µs, 42.5 µs | 49.7 µs, 44.4 µs |

**Restricted decoding.** `gate_dec.erl` decodes a subset of the external term
format in Erlang (existing atoms, integers, floats, binaries, lists, tuples,
maps; depth and node budgets; no pids, ports, references or funs) and is
compared with `binary_to_term(Bin, [safe])`, 20,000 iterations:

| Term | Encoded size | `binary_to_term/2` with `safe` | Erlang subset decoder | Ratio |
| --- | --- | --- | --- | --- |
| `{call, 17, {write, <<"hello world">>, [{opt, true}, {timeout, 5000}]}}` | 71 bytes | 0.18 µs | 0.50 µs | 2.7 |
| a map holding 200 four-element tuples | 7,111 bytes | 15.39 µs | 58.63 µs | 3.8 |

Under the JIT the Erlang decoder costs 3 to 4 times the C decoder; the
interpreter is expected to widen this gap, which gate G6 measures on erXos.

## BeamAsm code size and load time

On the host, with OTP 28.4.2: `bench/jitsize/jitsize.erl` (SHA-256 prefix
`131b8b91cbfb5d00`) loads every module that the `kernel`, `stdlib` and
`compiler` applications list, with `code:ensure_loaded/1` from one process,
and reports `erlang:memory(code)`, which under the JIT includes the
generated code of every loaded module, and the time spent loading. Three
runs of `erl -noshell -pa . -s jitsize main`, OTP 28.4.2's JIT flavour (the
Homebrew build has no interpreter flavour), with a load average of 8 to 12:

| Run | Modules loaded by the probe | `erlang:memory(code)` before | after | Loading time |
| --- | --- | --- | --- | --- |
| 1 (cold file cache) | 178 of 259 | 4,878,541 bytes | 12,768,666 bytes | 427 ms |
| 2 | 178 of 259 | 4,878,469 bytes | 12,768,642 bytes | 168 ms |
| 3 | 178 of 259 | 4,878,317 bytes | 12,768,282 bytes | 146 ms |

The other 81 modules were already loaded at the `-s` point. Loading
includes reading each file, translating it and committing it; it averages
0.8 to 2.4 ms per module, sequentially.

## Atomic builtins under LLVM clang

`probe/atomics/acq.c` (SHA-256 prefix `c717146c4bebd4d8`) compiles an
acquire load, a release store and a sequentially consistent fetch-and-add
with Homebrew clang 23.1.4, `--target=aarch64-none-elf -O2`, disassembled
with `llvm-objdump` from the same release:

| Operation | `-march=armv8-a` | `-march=armv8.1-a` |
| --- | --- | --- |
| `__atomic_load_n(p, __ATOMIC_ACQUIRE)` | `ldar` | `ldar` |
| `__atomic_store_n(p, v, __ATOMIC_RELEASE)` | `stlr` | `stlr` |
| `__atomic_fetch_add(p, v, __ATOMIC_SEQ_CST)` | `ldaxr`, `add`, `stlxr` loop | `ldaddal` |

The acquire load is an acquiring instruction, not a plain load needing a
barrier after it, which is the defect ERTS's check for untrusted compilers
guards against ([research](research-erts-internals.md#the-operating-system-layer)).

## What was not measured

* Interrupt latency on an idle host.
* SMMUv3 translation (only option acceptance was checked).
* Any OTP 29.1.2 binary: the static, interpreter-flavor ERTS for erXos has
  not been built; gate G0 of [plan.md](plan.md) builds it and repeats the
  ERTS baselines on Linux and erXos.
