# The AArch64 binding

This document maps the kernel's port contract
([design-kernel.md](design-kernel.md#port-contract)) to AArch64, the first
architecture erXos runs on. The generic designs say kernel mode and user
mode and name no register, instruction or controller; this binding says
what each of them is on AArch64, and so does the architecture layer that
implements it, `kernel/arch/aarch64/`, with `abi/arch/aarch64.txt`,
`hw/sysreg/aarch64.json` and `hw/arch_terms/aarch64.txt`. Kernel mode is
EL1 and user mode EL0. The key idea is one AArch64 mechanism for every
item of the contract, chosen so that the contract's property holds in
hardware wherever the architecture can enforce it: `WXN` for the rule that
no mapping is writable and executable, the direct map in `TTBR1_EL1` for
every kernel access to memory, so no kernel instruction ever goes through
a user translation, non-global ASID-tagged entries for TLB isolation, the
translation entry's dirty state for store tracking where the CPU manages
it, and a trap
of every feature with EL0 state the kernel does not save. The boards these
mechanisms run on are described in
[design-platforms.md](design-platforms.md).

Decisions every reader of this document needs:

* **Kernel mode is EL1 and user mode is EL0.** The kernel enters at EL1 or
  EL2, leaves EL2 at boot for good, and never runs at EL3, which belongs
  to the boards' firmware.
* **The boot protocol is Linux's arm64 Image protocol**, with the device
  tree's address in `x0`.
* **A kernel call is `svc #0x4552`**, with the call number in `x8`, its
  arguments in `x0` to `x5`, and the status and results in `x0` to `x2`.
* **Hardware enforces the generic rules where AArch64 can:** `WXN` forces
  writable mappings execute-never, and `E0PD` hides the kernel half's
  timing where the CPU has it.
* **The kernel never accesses memory through `TTBR0_EL1`.** It reaches
  UTCBs, shared areas and memory objects' pages through the direct map,
  contains no `LDTR` or `STTR`, and finds a umtx word by a software walk
  of the space's tables ([Kernel access to
  memory](#kernel-access-to-memory)).
* **The interrupt controller is a GICv3 with a GICv2m frame or a
  GICv2**; the IOMMU is the SMMUv3; the timer is the EL1 virtual timer;
  the firmware interface is PSCI through SMCCC.
* **Speculation mitigations are Linux's on arm64**, chosen from the CPU's
  identification registers and the firmware's reports.

## Context

The architecture layer is the part of the kernel that the port contract
isolates: the boot entry, the exception vectors, the context switch,
translation and TLB maintenance, cache maintenance, the walk that finds a
umtx word and the firmware call
([design-kernel.md](design-kernel.md#portability)). `liberx`'s trap stubs
for the `erx` backend, the generated headers of `abi/arch/aarch64.txt` and
the system-register accessors of `hw/sysreg/aarch64.json` complete it.
Outside the kernel, ERTS's own AArch64 code, BeamAsm's back end and
musl's architecture layer are AArch64 code behind their own seams
([design.md](design.md#portability)). The
stopgap Fiasco runs on the same architecture, built for EL1 with
`CONFIG_CPU_VIRT` off, since its EL2 build does not boot under HVF
([research](research-hierarchical-scheduling.md#fiasco-under-hvf)).

## Requirements

1. Provide every item of the port contract on AArch64, under QEMU `virt`
   with TCG and HVF and on the Raspberry Pi 4 and 5.
2. Enter at EL1 or EL2, as each loader does, and leave EL2 configured so
   that it traps nothing EL1 or EL0 needs.
3. Keep every piece of EL0-visible state either saved per thread or
   trapped (K15).
4. Hold the kernel's invariants K7, K8, K9, K10, K11, K12 and K15 with the
   mechanisms below.

Non-goals: EL2 as a hypervisor, since HVF enters guests at EL1 and erXos
runs no virtual machines; SVE and SME, which stay trapped; and EL3, the
firmware's.

## Overview

| Port-contract item | AArch64 mechanism |
| --- | --- |
| Modes | EL1 for the kernel, EL0 for every thread; EL2 configured from one generated table and left at boot |
| Boot entry | the Linux arm64 Image protocol: a 64-byte header, the device tree's address in `x0` |
| Exception and interrupt entry | the EL1 vector table on `SP_EL1`, the running thread's kernel stack: synchronous exceptions from EL0 and EL1, IRQs and SErrors; `eret` |
| Kernel stacks and the switch | `SP_EL1` points into the running thread's kernel stack; the switch saves `x19` to `x30` and `SP_EL1` on the old thread's stack and loads the new thread's; an unmapped guard page below each stack |
| System-call trap | `svc #0x4552`; call number in `x8`, arguments in `x0` to `x5`, status and results in `x0` to `x2` |
| Thread state | `x0` to `x30`, `SP_EL0`, `ELR_EL1`, `SPSR_EL1`, `TPIDR_EL0`, `TPIDRRO_EL0`; `q0` to `q31`, `FPCR`, `FPSR`; `TPIDRRO_EL0` holds the address of the thread's kernel-user page |
| Translation | stage 1, 4 KiB granule, four levels, a 48-bit user half in `TTBR0_EL1`, the kernel half in `TTBR1_EL1`; `WXN`, `PXN` and `UXN`; `E0PD1` |
| Address-space tags and TLB maintenance | 16-bit ASIDs; `TLBI VALE1IS` for a page, `TLBI VAE1IS`, or `TLBI RVAE1IS` with `FEAT_TLBIRANGE`, for every level over a freed table's span, and `TLBI ASIDE1IS`, each with `DSB` and `ISB` |
| Kernel access to memory | the direct map in `TTBR1_EL1`; no `LDTR` or `STTR`; `erx_uword_load`, a software walk of the space's stage 1 tables through the direct map that refuses an output address the direct map does not cover; store tracking by the hardware's dirty state (`FEAT_HAFDBS`, `TCR_EL1.HD` and the descriptor's `DBM`), folded into the object's stored marks before an entry is freed, where present, otherwise by write protection and the permission fault |
| Timer | the EL1 virtual timer and `CNTVCT_EL0`, read after an `ISB`, or `CNTVCTSS_EL0` where the CPU has `ECV` |
| Interrupt controller and MSIs | GICv3 with the GICv2m frame, or a GICv2; SGIs for the inter-processor interrupts |
| CPU start and machine end | PSCI through one SMCCC routine: `CPU_ON`, `SYSTEM_OFF`, `SYSTEM_RESET` |
| IOMMU | the SMMUv3 |
| FP and SIMD state | `-mgeneral-regs-only`; `CPACR_EL1` enables FP and SIMD at EL0 and traps SVE and SME |
| Cache maintenance | `DC`, `IC` and `CTR_EL0`; `UCI` and `UCT` for EL0 |
| Asynchronous errors | SErrors, attributed in windows recognised by address |
| Optional hardening | pointer authentication (`EnIA`, `EnIB`) and BTI guarded pages |
| Speculation mitigations | Linux's arm64 mitigations, through SMCCC's `ARCH_WORKAROUND` calls where the firmware provides them |
| Hardware register sources | Arm's machine-readable A-profile specification |

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **AB1.** Nothing left in EL2 changes what EL1 or EL0 can do | every EL2 register that controls EL1 or EL0 is written from one table generated from the system-register specification, and the generator fails the build when the specification has such a register and the table lacks it | a register written by hand; a register the table misses | the generator's check; a boot from EL2 on each board, followed by the register audit |
| **AB2.** Every EL1 control register is written from zero plus listed enables | `SCTLR_EL1`, `CPACR_EL1`, `MDSCR_EL1`, `PMUSERENR_EL0` and `CNTKCTL_EL1` are written whole, never by read-modify-write ([Hardware configuration](#hardware-configuration)) | a read-modify-write of a control register | a source check on the boot code; the boot audit of the ID registers (K15) |
| **AB3.** No kernel instruction accesses memory through a `TTBR0_EL1` translation, and none loads a umtx word from memory the direct map does not cover | the kernel reaches UTCBs, shared areas and memory objects' pages only through the direct map and its own regions in `TTBR1_EL1`; it contains no `LDTR` or `STTR`; `erx_uword_load` reads descriptors and the word through the direct map, and loads the word only from an output address inside the direct map's ranges; no call argument is a pointer (K7) | an `LDTR` or `STTR` anywhere in the kernel; an integer converted to a pointer outside the typed converters; a user address dereferenced; a walk that loads from an output address without the range check | the chokepoint checks; a hostile test that passes kernel-half and user-half addresses wherever an argument is an integer, on Cortex-A72 and under both accelerators; umtx waits on a boot-image slice and a register window, each refused |
| **AB4.** No writable mapping is executable | `WXN` is set whenever the MMU is on, and `erx_pte_make` never builds a writable entry without `UXN` and `PXN` | clearing `WXN` | the kernel-table walk after every test (K8) |

## Data model

### Thread state

A thread record holds, at offsets from a generated header pinned with
`_Static_assert`, the user registers `x0` to `x30`, `SP_EL0`, `ELR_EL1`,
`SPSR_EL1`, `TPIDR_EL0` and `TPIDRRO_EL0`, and the FP state `q0` to `q31`,
`FPCR` and `FPSR`, 528 bytes; the vectors store into them directly
([design-kernel.md](design-kernel.md#threads)).

`TPIDRRO_EL0` holds the address of the thread's kernel-user page, its UTCB
and vCPU state area, as Fiasco keeps its UTCB's address there
([design-kernel.md](design-kernel.md#threads)). The kernel writes it when
it creates the thread, and no call changes it, `erx_thread_write`
included.

The **frame** of a vCPU upcall
([design-kernel.md](design-kernel.md#vcpu-upcalls)) is `x0` to `x30`,
`SP_EL0`, the PC and the `PSTATE` bits EL0 can observe or change: `NZCV`,
and `SSBS`, `DIT` and `BTYPE` where the CPU has them. An upcall enters the
entry with the state area's address in `x0` and `SP_EL0` unchanged, as
Fiasco's AArch64 upcall does outside vCPU user mode; the procedure-call
standard reserves no area below the stack pointer, so the entry's frames
overwrite nothing the interrupted code keeps there. The FP registers,
`FPCR`, `FPSR`, `TPIDR_EL0` and `TPIDRRO_EL0` are not in the frame.
`erx_vcpu_resume` accepts a frame only with EL0's mode in `PSTATE` and no
other bit than the frame may hold, and never writes `TPIDRRO_EL0` or any
EL1 state.

### The ABI file for AArch64

`abi/arch/aarch64.txt` declares, in the grammar of `abi/erx_abi.txt`
([design-kernel.md](design-kernel.md#the-abi-file)), the call convention's
registers, the layouts of the thread state and of the frame a vCPU upcall
saves, and the in-memory
structures the MMU and the SMMU read: translation-table descriptors, which
the CPU and the SMMU share, and the SMMU's stream table entries, context
descriptors and command and event queue entries. A page descriptor, for
example:

```text
arch      aarch64
trap      svc 0x4552                       # any other immediate is foreign
reg       number            x8
reg       args              x0,x1,x2,x3,x4,x5
reg       results           x0,x1,x2       # status, then two results
layout pte_page 1 native 8 8     # stage 1 page descriptor, 4 KiB granule, level 3
  field raw u64 0
    bits valid 0 0
    bits attrindx 2 4
    bits ap 6 7
    bits af 10 10
    bits ng 11 11
    bits oa 12 47 shift 12
    bits gp 50 50
    bits pxn 53 53
    bits uxn 54 54
```

The generator emits a get and set function for every bit range, so no code
packs descriptor bits by hand. The file shares `abi/erx_abi.txt`'s
`ERX_ABI_VERSION`: a change to either is a new version.

## Algorithms and behavior

### Modes

The kernel runs at EL1 and every thread at EL0. A loader may enter the
kernel at EL2, as the Raspberry Pi firmware does; the kernel then
configures EL2 ([Boot entry](#boot-entry)) and drops to EL1 for good. HVF
enters at EL1.

### Boot entry

The kernel image is a flat binary that starts with the 64-byte arm64 Image
header: `text_offset` 0, `image_size` covering `.bss`, and flags `0xa`
(little-endian, 4 KiB pages, placement anywhere). The loader passes the
device tree's physical address in `x0` and the boot image as the initrd;
the platform binding records where each loader puts them
([design-platforms.md](design-platforms.md#boot)). The protocol also
requires the loader to quiesce every DMA-capable device before entry
(Linux v6.12, `Documentation/arch/arm64/booting.rst`, section 4). erXos's
platform contract additionally requires that quiescence drain outstanding
DMA through the platform's documented completion or reset mechanism
before memory is reclaimed. Setting an SMMU to abort future traffic does
not drain requests already beyond it. An unknown or failed drain stops
boot before allocator handoff; the platform's loader evidence is a
security gate ([DMA](design-platforms.md#dma), [IOMMU](#iommu)).

At entry (`boot.S`), with the MMU off, the kernel saves `x0` and checks
the device tree's header. If `CurrentEL` is EL2, it installs an EL2 vector
that writes the syndrome of any exception taken to EL2 to the early
console and stops, then writes every EL2 register that controls EL1 or
EL0 from one table generated from the system-register specification, with
Linux's `init_el2_state` as the reference:

* `HCR_EL2`: AArch64 at EL1, nothing trapped, pointer authentication
  allowed;
* `CPTR_EL2`, `HSTR_EL2` and `MDCR_EL2`: trapping nothing EL1 needs;
* the counters for EL1 (`CNTHCTL_EL2`) and a zero `CNTVOFF_EL2`;
* `VPIDR_EL2` and `VMPIDR_EL2` from `MIDR_EL1` and `MPIDR_EL1`;
* a zero `VTTBR_EL2`;
* the GIC's system registers for EL1 (`ICC_SRE_EL2`) when
  `ID_AA64PFR0_EL1.GIC` reports them, as it does at EL2; a GICv2 has
  none, and under HVF, which enters at EL1, the field reads 0.

The generator fails the build when the specification has an EL2 register
with fields that affect lower levels and the table has no entry for it
(AB1). Then `eret` to EL1 with every exception masked, `SCTLR_EL1` written
with the MMU off, `.bss` zeroed, and the boot CPU's stack in the image.

Turning the MMU on sets `MAIR_EL1`, `TCR_EL1`, `TTBR1_EL1` and `TTBR0_EL1`
(the empty user table), and writes `SCTLR_EL1` from zero plus the enables
of [Hardware configuration](#hardware-configuration). The boot image is
made coherent for instruction fetch by cleaning the data cache and
invalidating the instruction cache over it to the point of unification.
Secondary CPUs are started with PSCI `CPU_ON` when their `enable-method`
is `psci`; each leaves EL2 the same way and initialises its GIC CPU
interface, a GICv3 redistributor or a GICv2's banked registers.

### Exception and interrupt entry

The EL1 vector table has an entry for each synchronous exception from EL0
and from EL1, for IRQs and for SErrors. Every entry runs on the running
thread's kernel stack, which `SP_EL1` points into. The EL0 entries save
the user registers into the thread record; the EL1 IRQ and SError entries,
taken at a preemption point, save the interrupted
EL1 registers, `ELR_EL1` and `SPSR_EL1` as a frame on that stack and leave
the record's user registers as they are, so the record always holds the
state the thread last left EL0 with. The entries then call the generated
dispatch, the fault classifier or the interrupt handler, and handlers
never nest. Every exit is an `eret`. A synchronous exception's class and
syndrome come from `ESR_EL1`, its address from `FAR_EL1` and the faulting
instruction from `ELR_EL1`; these fill the fault record's `cause`, `addr`
and `pc` ([design-kernel.md](design-kernel.md#threads-and-faults)). A data
or instruction abort from EL0 is a memory fault when its fault status code
(`ESR_EL1`'s `DFSC` or `IFSC`) is a translation fault or a permission
fault at any level, with the access from `ESR_EL1.WnR` for a data abort
and fetch for an instruction abort, and goes to the kernel's fault
decision ([design-kernel.md](design-kernel.md#virtual-memory)); every
descriptor `erx_pte_make` builds has its access flag set, so no
access-flag fault arises on a translation erXos made, and any other status
code is a fault record. Trapped SVE and SME instructions are
undefined-instruction faults. A synchronous exception from EL1 is a kernel
bug, since the kernel makes no access that may fault: its entry switches
to the panic stack and panics. The per-CPU record is found from `MPIDR_EL1`
through a table written at boot, so the panic path trusts no pointer.

### System-call trap

A kernel call is `svc #0x4552` ("ER") with the call number in `x8` and up
to six arguments in `x0` to `x5`. On return `x0` holds the status and `x1`
and `x2` up to two results, and every other register is preserved. The
registers carry only the call number, the arguments and the results; an
IPC call's message lies in the UTCB, whose layout, with the capabilities
it carries as typed items, comes from the ABI file
([design-kernel.md](design-kernel.md#the-abi-file)). Any other `svc`
immediate, `svc #0` included, is another system's call and stops the
thread with a fault of kind `ERX_FAULT_FOREIGN_TRAP`.

### Translation

Stage 1 translation with a 4 KiB granule and four levels: the user half
spans 48 bits (`T0SZ` = 16) under `TTBR0_EL1`, and the kernel half lies in
`TTBR1_EL1` with global mappings. Committing memory reserves, at each of
the three lower levels, one table for every region the range touches,
2 MiB for a last-level table, 1 GiB for a level-2 table and 512 GiB for a
level-1 table; the level-0 table comes with the space
([design-kernel.md](design-kernel.md#virtual-memory)).

| Kernel region | Address |
| --- | --- |
| direct map of RAM | `0xffff000000000000` plus the physical address |
| kernel image | `0xffff800000000000` |
| device registers the kernel drives | `0xffffb00000000000` |
| boot image, per-CPU areas and panic stacks | `0xffffc00000000000` |
| kernel stacks, each with a guard page below it | `0xffffd00000000000` |

User pages are always `PXN`, so the kernel never executes user memory, and
kernel pages always `UXN`. `SCTLR_EL1.WXN` forces every writable mapping
execute-never (AB4). `MAIR_EL1`'s attribute slots are fixed at boot:
normal write-back, device-nGnRnE and device-nGnRE; MMIO objects take one
of the device attributes. Where the CPU has `E0PD`, `TCR_EL1.E0PD1` makes
EL0 accesses to the kernel half fault in constant time, so the kernel
needs no randomised layout. Mappings marked guarded (`ERX_SEG_GUARDED`,
`ERX_MAP_GUARDED`) set the descriptor's `GP` bit where the CPU implements
BTI ([Optional hardening](#optional-hardening)).

**Store tracking.** `erx_mem_dirty` learns which pages of a shared object
were stored to in one of two ways, which the boot audit chooses from
`ID_AA64MMFR1_EL1.HAFDBS`
([design-kernel.md](design-kernel.md#virtual-memory)):

* **Hardware dirty state**, where the CPU manages it (`FEAT_HAFDBS` with
  dirty-state management, as the Cortex-A76 of the Raspberry Pi 5
  implements). `TCR_EL1.HA` and `HD` are set; every descriptor already has
  its access flag set, so `HA` changes nothing else. A clean page is
  mapped with `DBM` set and `AP[2]` set, which reads as read-only; the
  CPU's first store clears `AP[2]` atomically and goes on without a fault.
  An entry with `DBM` set and `AP[2]` clear is **dirty**. A report reads
  each translation of the page through the object's reverse map, counts
  the page as stored when its stored mark is set or an entry is dirty, and
  marks it clean by clearing the mark and setting `AP[2]` with a
  compare-and-swap, since the CPU may update the entry at the same moment,
  followed by the invalidation of [TLB maintenance](#tlb-maintenance).
  A removal of a translation, by a range call, an unmap, an `exec`'s new
  space or a space's end, a table detached whole included, reads each
  removed entry after the removal's invalidation has completed, when no
  CPU can update it any more, and before the entry's table is freed, and
  `erx_vm_fold` sets the page's stored mark for each dirty one
  ([design-kernel.md](design-kernel.md#virtual-memory)).
  `erx_pte_make` treats `DBM` as write permission, so such an entry is
  always `UXN` and `PXN` (AB4).
* **Write protection**, elsewhere, as on the Cortex-A72 of the Raspberry
  Pi 4. A clean page is mapped read-only; the first store takes a
  permission fault, which the fault decision answers by recording the
  store and mapping the page writable; a report sets `AP[2]` again and
  invalidates. A store that a stale read-only TLB entry faults again finds
  the page already marked and is mapped again.

Changing only the permission of a valid entry needs no break-before-make.
Which accelerators on the primary host report dirty-state management is
measured, not assumed, and the conformance suite runs both ways on each.

### TLB maintenance

User mappings are non-global and tagged with their space's ASID; kernel
mappings are global. Every change follows the Arm ARM's rules for
translation-table maintenance: the entry is written, `DSB ISHST` makes it
visible to table walks, a `TLBI` that `erx_tlb_plan` chooses invalidates
every CPU's TLB, `DSB ISH` waits for completion, and `ISB` follows where
the current CPU must see the change. The plan chooses by what was cleared
([design-kernel.md](design-kernel.md#virtual-memory)):

| Cleared | Invalidation |
| --- | --- |
| a level 3 page descriptor whose table stays | `TLBI VALE1IS` for the page, which drops last-level entries only |
| a table descriptor, its table detached whole or freed once empty | `TLBI VAE1IS` for every page of the table's span, which drops cached entries of every level used for the address, walk caches included; with `FEAT_TLBIRANGE`, `TLBI RVAE1IS` over the span |
| more than 64 addresses' worth in one plan | `TLBI ASIDE1IS` |

`VALE1IS` never serves a cleared table descriptor: a CPU may hold that
descriptor in a walk cache and walk the freed table after it has been
reused, as data a domain wrote. Linux makes the same distinction: its
range flush issues `VALE1IS` only when the caller passes
`TLBF_NOWALKCACHE` and `VAE1IS` otherwise (arm64's `tlbflush.h` of Linux
7.2, as L4Linux carries it at `arch/l4/include/asm/arch-arm64/tlbflush.h`
in the L4Re 26.09.0 snapshot). TCG need not keep walk caches, so the tests
that free tables run under HVF and on the boards. An entry that maps a
page is replaced by one that maps another only through an invalid entry
and a completed invalidation, which the Arm ARM calls break-before-make.
ASIDs are 16 bits with a generation, allocated as Linux allocates them in
`arch/arm64/mm/context.c`; ASID 0 belongs to the empty table that
`TTBR0_EL1` holds while the idle thread runs. The boot audit verifies
`ID_AA64MMFR0_EL1.ASIDBits` and selects 16-bit ASIDs in `TCR_EL1.AS`;
Cortex-A72 provides them too (its TRM, Table 4-35). ASID 0 never names a
user mapping, and every user mapping is non-global.

### Kernel access to memory

The kernel reaches memory only through its own half, `TTBR1_EL1`: the
direct map of RAM, the image, the stacks and the device registers it
drives ([Translation](#translation)). A thread's kernel-user page, a
group's areas and the time page are kernel memory that is also mapped
into a space; the kernel reads and writes them through the direct map
with the shared accessors, and a memory object's pages through
`erx_window_read` and `erx_window_write`
([design-kernel.md](design-kernel.md#arguments-and-results)). No kernel
instruction uses a `TTBR0_EL1` translation, so the kernel contains no
`LDTR` or `STTR`, no fixup table, and no path that opens user memory to
EL1, and a data abort at EL1 is always a kernel bug (AB3).

**`erx_uword_load`.** The umtx calls name a word by its address in the
caller's space ([design-kernel.md](design-kernel.md#umtx)). The walk
starts from the space's level-0 table, taken from the space's record, not
from `TTBR0_EL1`, and reads one descriptor per level through the direct
map with the generated accessors of `abi/arch/aarch64.txt`, each with one
single-copy-atomic 64-bit load:

1. An address outside the user half (`T0SZ` = 16) or not 4-byte aligned
   is refused by the decoder before the walk.
2. At levels 0 to 2, a descriptor that is not a valid table descriptor
   ends the walk with `ERX_EFAULT`; erXos builds no block descriptor in a
   user half, so a block descriptor ends it the same way.
3. At level 3, a page descriptor that is valid and readable at EL0
   (`AP[1]` set) yields its output address; any other ends the walk with
   `ERX_EFAULT`.
4. The output address must lie inside the direct map's ranges, which the
   boot records when it builds the direct map; any other output, such as
   a device's register page, the boot image or a board's crash region,
   ends the walk with `ERX_EFAULT`. One range check decides, with no rule
   per kind of object, so the load never reaches an address that the
   direct map leaves unmapped and that would abort at EL1.
5. The word is read with one 32-bit load through the direct map of that
   output address.

The walk runs under the lock of the memory object that the word's mapping
names and under the umtx bucket's lock, with interrupts masked, inside
one read side of the kernel's read-copy-update, and a table or page that
leaves a space is freed only after its invalidation has completed and a
grace period has ended ([design-kernel.md](design-kernel.md#the-reaper)),
so every descriptor the walk reads lies in a table that is still a
table, and the page it finds is still a page, when it reads the word. The
walk is a pure function of the descriptors it loads, with a host model
over every descriptor kind at every level.

### Timer

The monotonic clock is the virtual counter `CNTVCT_EL0`, at the frequency
`CNTFRQ_EL0` reports, which the time page publishes;
`CNTKCTL_EL1.EL0VCTEN` lets EL0 read the counter, and every other EL0
timer access stays trapped. Each CPU programs the EL1 virtual timer, INTID
27 (PPI 11) on QEMU `virt`, one-shot from its timer wheel. An idle CPU
waits in `wfi`. A read of `CNTVCT_EL0` follows an `ISB`, so the CPU does
not take it before the code that precedes it, or uses `CNTVCTSS_EL0`, its
self-synchronised view, where the CPU has `ECV`; the time page's readers
do the same. The virtual counter is the system counter less an offset that
is the same on every CPU, so readings agree across CPUs.

### Interrupt controller

A GICv3 runs with affinity routing, non-secure group 1, the
system-register CPU interface and `EOImode` 0, so one write drops priority
and deactivates; a GICv2, the Raspberry Pi boards' GIC-400, runs the same
way through its memory-mapped CPU interface, with SGIs sent by CPU
interface number. The kernel's three inter-processor interrupts,
`ERX_IPI_REQUEST`, `ERX_IPI_SYNC` and `ERX_IPI_STOP`, are SGIs, and it
uses no others; device lines are SPIs. A handler ends an interrupt with
`ICC_EOIR1_EL1`, or `GICC_EOIR` on a GICv2. At each preemption point the
kernel unmasks IRQs in `DAIF` for one instruction, so a pending interrupt
is taken there. The kernel finds the GIC from the device tree, never from
`ID_AA64PFR0_EL1.GIC`, which reads 0 under HVF
([measured](research-baselines.md#accelerator-capabilities)). MSIs arrive
through the platform's frame, the GICv2m frame on QEMU `virt`, which
raises SPIs ([design-platforms.md](design-platforms.md#msi-frames)).
A GICv2m frame takes the SPI from the value written to it, so every
function whose window maps the frame's page can raise any of its SPIs; a
GICv3 ITS, which translates each MSI by the writer's DeviceID, the
requester id the SMMU also sees, would give each function interrupts of
its own, but HVF's GIC has no ITS, and erXos keeps one interrupt path
under both accelerators.

### CPU start and machine end

Every firmware call goes through one SMCCC routine, using the conduit,
`hvc` or `smc`, that `/psci/method` names. It serves PSCI's `CPU_ON` for
secondary CPUs and `SYSTEM_OFF` and `SYSTEM_RESET` for the machine's end,
and the speculation workarounds ([Speculation
mitigations](#speculation-mitigations)). A boot without a PSCI node stops.
A fault of the system domain, a missed deadline of the kernel's watchdog
and a panic under `erx.panic=reset` reach `SYSTEM_RESET` through the same
routine, after the other CPUs are stopped with `ERX_IPI_STOP` and the
crash record is written; the boards' hardware watchdog is a platform
device, not the architecture's
([design-platforms.md](design-platforms.md#the-watchdog)).

### IOMMU

The SMMUv3 driver (`kernel/platform/smmuv3.c`) is erXos's own C17, written
with OpenBSD's and FreeBSD's drivers as references. On a platform without
an SMMU the kernel has nothing to check at boot: every DMA device there
is unconfined, and the loader's quiescence of every bus master ([Boot
entry](#boot-entry)) is what keeps old DMA out of reclaimed memory. On a
platform with one, boot checks the SMMU's reset-state handoff and brings
it up in four ordered stages; the first two precede allocator handoff,
and no stage repairs an unknown live firmware configuration by guessing
how to drain it.

1. **Require a stopped handoff.** The platform's loader contract
   identifies every implemented SMMU memory-access and notification
   facility and establishes its completed shutdown before entry. It
   covers command, event and page-request queues, register and
   command-generated MSIs, and any implemented auxiliary queues or
   monitoring sources. At boot step 4 the kernel reads and requires:
   * `SMMU_CR0`: `SMMUEN`, `CMDQEN`, `EVENTQEN` and `PRIQEN` clear;
   * `SMMU_CR0ACK`: the same four fields clear, so no update of `CR0` is
     still pending;
   * `SMMU_IRQ_CTRL` and `SMMU_IRQ_CTRLACK`: every notification
     disabled in both;
   * `SMMU_IDR0` and `SMMU_IDR1`: no feature the driver does not handle.

   Any other value, or missing platform evidence for a facility the
   registers cannot show, stops boot before memory is reclaimed. A reset
   model with documented inactive facilities is one admissible handoff; a
   running firmware SMMU is not.
2. **Close future access and establish the drain.** The kernel writes
   `SMMU_GBPA` with `ABORT` and `Update` set and polls until the SMMU
   clears `Update`, allocating no memory meanwhile. The port contract
   separately establishes that every outstanding device and
   SMMU-originated memory access has completed to the domain covering
   reclaimed memory. Queue-disable acknowledgement alone does not
   drain a command's outstanding sync MSI, and translation-disable
   acknowledgement alone does not drain old DMA. Unknown completion stops
   boot. Only the completed stopped handoff, global abort and platform
   drain permit boot step 4 to release memory to the allocator.
3. **Initialize and invalidate while closed.** In boot step 5 the driver
   allocates a linear stream table sized from `SMMU_IDR1.SIDSIZE`, refusing
   widths beyond 16 bits, and initializes every entry to valid abort
   (`V` set, `Config` zero). It configures its own queue memory, base and
   size before initializing the producer and consumer indexes, then
   enables its command queue and waits for acknowledgement. It sets
   `SMMU_CR0.ATSCHK` to safe mode where `IDR0.ATS` is set, waits for the
   update, and issues `CMD_CFGI_ALL`, `CMD_TLBI_NSNH_ALL` and, where
   `IDR0.Hyp` is set, `CMD_TLBI_EL2_ALL`, followed by a completed
   `CMD_SYNC`. These cover all implemented Non-secure configuration and
   translation caches, including inherited entries. `SMMUEN` stays clear
   and global bypass stays abort throughout. A disable/enable cycle does
   not itself invalidate those caches.
4. **Enable the empty policy.** Only after that sync succeeds does the
   driver enable its event queue, configured notifications and translation,
   waiting for their update acknowledgements. Every stream still aborts;
   only publishing a window authorizes a function's accesses. The driver
   enables neither a page-request queue nor endpoint translation caching.

**What QEMU `virt` needs and what a board port adds.** QEMU `virt`, the
first platform, runs with an SMMUv3 (`iommu=smmuv3`), which QEMU starts
at its reset state with nothing in flight, so the
handoff of stages 1 and 2 is established by reading the reset values the
stage checks. The interface above, the stream table, windows, commands,
completion and the event queue, is the same for every platform. The
machinery for a live firmware handoff beyond that reset state, the
platform's drain evidence for DMA already issued before entry, and
commands and features QEMU does not model, such as `CMD_TLBI_EL2_ALL`
where `IDR0.Hyp` is set, are the board port's for the first board with an
SMMUv3, written and tested against that board's loader
([design-platforms.md](design-platforms.md#dma)).

The initialization order follows Arm IHI 0070 G.b section 3.11, pp93-94;
queue update and base/index order are sections 6.3.9.3-6.3.9.6 and
`SMMU_CMDQ_BASE`, pp346-349 and 393. Sections 3.18.1 and `IRQ_CTRL`,
pp127 and 369, distinguish notification shutdown from queue shutdown.
These rules establish what the handoff must prove; the platform tests
establish whether a particular loader provides it.

A window is stage-1 translation tables in the CPU's format, a context
descriptor that points at them, and a stream table entry, written and
then published with `CMD_CFGI_STE` and `CMD_SYNC`. Every window maps the
GICv2m frame's page at `ERX_DMA_MSI_IOVA`. Every entry keeps `EATS` zero;
safe ATS checking, or hardware that rejects Translated traffic without ATS
support, prevents a request falsely marked already translated from
bypassing these checks. The context descriptor selects the abort fault
model, never the stall model; no faulty DMA waits on a user-mode response.
Unmapping issues `CMD_TLBI_NH_VA` with `Leaf` set for a cleared page
descriptor and with `Leaf` clear, which reaches every level, for a cleared
table descriptor, over the table's span, or `CMD_TLBI_NH_ASID` for the
window's ASID beyond 64 addresses, then `CMD_SYNC`, and detaches the
mapping record from the object only after the sync completes (K9). Destroying a window writes
its stream table entry back to abort with `CMD_CFGI_STE` and `CMD_SYNC`
before unmapping. The event queue's records are decoded by a pure function
with a host fuzz target
([design-kernel.md](design-kernel.md#dma-and-the-iommu)).

**Completion.** Arm IHI 0070 G.b, section 4.7.3, establishes that a
`CMD_SYNC` after TLBI or CFGI makes transactions translated through the
targeted entries globally observable to their shareability domain before
`SMMU_CMDQ_CONS` reports consumption of the sync. `CS` = `SIG_NONE`
suppresses notification, not this guarantee. This is the completion
criterion; it does not retire requests still queued in the device.

The driver publishes the invalidations and sync under the command queue's
lock, orders descriptor and queue writes before `SMMU_CMDQ_PROD` with
`DMB OSHST`, and polls the consumer between preemption points for at most
`ERX_IOMMU_SYNC_NS` (one second). Every SMMU-read structure, including
stream and context descriptors, translation tables and queue entries, is
coherent with the SMMU or is cleaned to the platform's required point,
with `DSB OSH` completing that maintenance before publication. The
port contract requires the completion shareability domain to cover the
memory that is reclaimed. The successful consumer read is followed by
`DMB OSH` before a page, table or object reference is released: a
control-flow branch alone does not order later stores.

The queue lock covers publication and consumer accounting, never a poll.
Each waiter holds a software completion ticket, not a raw wrapping queue
index. The queue serialises observation of consumer progress and retires
tickets before reusing their serials; before the software serial's
32-bit wrap it stops admission, drains and resets accounting only after
every waiter has retired. Hardware ring wrap is handled independently.
A missed deadline or command error fails the SMMU and keeps affected
memory charged and quarantined; neither timeout nor queue reset counts as
completion. The specification evidence and outstanding implementation and
platform tests are separate in
[the hardware-contract audit](research-hardware-contracts.md).

**Faults and quarantine.** The event queue's interrupt is a line the
kernel masks at the interrupt controller once a period's budget of records
is drained, and unmasks at the next period. The SMMU marks a queue it
could not write in the overflow flag of `SMMU_EVENTQ_PROD` and drops
records until the driver acknowledges the flag in `SMMU_EVENTQ_CONS`,
which it does at its next drain. Inspection counts overflow episodes and
marks the number of lost records unknown; a flag cannot supply an exact
count. A
window is quarantined by keeping `V` set and writing `Config` zero in its
stream table entry (Arm IHI 0070 G.b, section 5.2.1), published with
`CMD_CFGI_STE` and `CMD_SYNC`, which
the event queue's handler queues without polling for the sync's
completion, since a quarantine frees nothing. Setting `V` zero instead
would report `C_BAD_STE` and would not silence a faulty stream. A command
queue without room for both leaves them pending for a bounded retry at
the next period even if no further interrupt arrives. Streams without a window
are set to abort the same way at boot, so a record names either a stream
outside the stream table, which `C_BAD_STREAMID` reports, or a window's.
Before a stream id can name another window, a completed device reset and
platform drain exclude further old traffic; a final sync and event-queue
producer snapshot delimit the records to consume or discard for the old
window. Its stream reservation remains attached to the closing window
until that bounded drain finishes. Old records are never attributed to
the new window; unknown reset, drain or event visibility keeps the stream
unavailable.

### FP and SIMD state

The kernel is compiled with `-mgeneral-regs-only`, and its memory
primitives are general-register code. `CPACR_EL1` enables FP and SIMD at
EL0 and traps SVE and SME. Every switch saves `q0` to `q31`, `FPCR` and
`FPSR` of the thread it leaves and restores those of the thread it enters;
the only FP instructions in the kernel's objects are those two routines
(K10, K11).

### Cache maintenance

EL0 runs with `SCTLR_EL1.UCI` and `UCT` set, so it reads `CTR_EL0` and
cleans and invalidates caches by address, as a JIT needs: BeamAsm's
AArch64 back end issues `DC CVAU` and `IC IVAU` and reads `CTR_EL0`
itself ([design-runtime.md](design-runtime.md#beamasm)). A runtime that
writes code makes it coherent itself and has every executor that may run
it execute an `ISB`, which ERTS's code barrier does: a JIT's publication,
`DC CVAU` over what it wrote through the writable mapping, `DSB ISH`,
`IC IVAU` over the same code at the executable mapping, `DSB ISH`, and an
`ISB` on each executor
before any pointer to the code is reachable, the sequence the Arm
Architecture Reference Manual prescribes for code written at one address
and executed at another. When the kernel fills
a page of an object whose ceiling includes execute, it cleans the data
cache and invalidates the instruction cache over the page before any
mapping reaches it. The device NIF's DMA envelope in `liberx`, the C under
every Erlang driver, cleans with `DC CVAC` before a device reads a buffer
and cleans and invalidates with `DC CIVAC` both before a device writes a
buffer and after; `DC IVAC` is not available at EL0, so a driver can never
discard data it did not write. It skips both for a device the device tree
marks `dma-coherent` and ends with a `DSB` before it writes the device's
doorbell register. Contiguous memory for a device
that is not `dma-coherent` is allocated in whole cache-writeback granules
(`CTR_EL0.CWG`).

### Asynchronous errors

AArch64 reports an error of an earlier access as an SError. SErrors are
masked at EL1 except in short windows that the SError vector recognises by
address, the technique of KVM's exit path (`abort_guest_exit_start` in
`arch/arm64/kvm/hyp/entry.S`):

* **At EL0** SErrors are unmasked; one taken there stops the running
  thread with a fault record of kind `async_error`.
* **The exit window.** Every exit from EL0 executes `DSB SY` and `ISB` and
  reads `ISR_EL1`; if an SError is pending, it unmasks SErrors for one
  instruction, and the SError stops the exiting thread.
* **The device window.** After the kernel touches its own device
  registers, and before it next enters EL0, it does the same, and an
  SError there is logged as an error of its own device.

Attribution is exact for errors of accesses that complete before a
`DSB SY` does. `erx_async_error_classify` reads an SError's severity from
`ESR_EL1.AET` where the CPU implements the RAS extension, as the Pi 5's
Cortex-A76 does:

| Severity | Action |
| --- | --- |
| corrected (`CE`) or restartable and not yet consumed (`UEO`) | a log line; nothing stopped |
| recoverable (`UER`) | the device an error record names quarantined, or else the thread the window or EL0 presumes stopped |
| uncontainable (`UC`) or unrecoverable (`UEU`) | a panic, as Linux's `arm64_is_fatal_ras_serror` decides for both (`arch/arm64/kernel/traps.c`) |

The Pi 4's Cortex-A72 has no RAS extension, so its syndromes carry no
severity. An SError taken there in a window or at EL0 is presumed to be
the thread's and contained to it, as KVM presumes an SError at a guest's
exit to be the guest's and injects it there (`kvm_handle_guest_serror`
and `handle_exit_early`, `arch/arm64/kvm/handle_exit.c`), where Linux,
with no guest to blame, panics on every such error ("non-RAS errors are
not containable", `do_serror`). Which error records a classifier may
read, the RAS extension's records and a PCIe root complex's error status,
is each board's contract to say
([design-platforms.md](design-platforms.md#dma)), and none is relied on
until its board's error-injection test shows what it reports
([design-kernel.md](design-kernel.md#interrupts-time-and-entropy)).

### Optional hardening

Pointer authentication is enabled with per-space keys (`EnIA` and `EnIB`
in `SCTLR_EL1`), drawn from the entropy generator for each space when it
is created, the fresh space of an `exec` included, and copied by
`erx_space_copy` for `fork`. Where the CPU
implements BTI, the kernel's text is guarded, `BT0` is set, and segments
and mappings marked guarded set the descriptor's `GP` bit.

### Speculation mitigations

The kernel applies the mitigations Linux applies on arm64, each chosen
from the CPU's identification registers and from what SMCCC
`ARCH_FEATURES` reports
([research](research-boards-storage.md#linuxs-speculation-mitigations-on-arm64)):

* **Branch-target injection** (Spectre variant 2): where the firmware
  reports `ARCH_WORKAROUND_1` as needed, the kernel calls it when a CPU
  switches to another space and on an entry from EL0 whose PC or fault
  address is a kernel address, as Linux does, rather than on every entry.
  TF-A builds it into its Raspberry Pi 4 BL31
  (`WORKAROUND_CVE_2017_5715`).
* **Branch-history injection**: on every entry from EL0, nothing where the
  CPU has ECBHB; otherwise the `CLRBHB` instruction where the CPU has it;
  otherwise the clearing loop with Linux's count for the core, 8 on the
  Pi 4's Cortex-A72 and 24 on the Pi 5's Cortex-A76; otherwise the
  firmware's `ARCH_WORKAROUND_3`. The boards therefore need nothing from
  their firmware for it.
* **Speculative store bypass**: the kernel runs with `PSTATE.SSBS` clear
  where the CPU has SSBS, and keeps the firmware's `ARCH_WORKAROUND_2`
  enabled where it does not.
* **Rogue data cache loads**: unmapping the kernel from EL0's tables is
  needed only on cores that Arm lists as affected, and each board's port
  decides it from that list ([plan.md](plan.md#beyond-the-plan)).

Each mitigation's cost on entry is measured on each board with
`tools/erx bench nullcall`.

### Hardware configuration

`SCTLR_EL1` is written from zero plus these enables: the MMU, the caches,
stack-alignment checking for EL1 and EL0 (`SA` and `SA0`), with `A` clear,
since `A` would fault every unaligned access to normal memory at both
levels and musl, ERTS and BeamAsm make such accesses, `WXN`, `UCI` and
`UCT` (EL0 cache maintenance and `CTR_EL0`),
`EnIA` and `EnIB` (pointer authentication with per-space keys), `BT0` with
guarded pages where BTI exists, and `EOS` and `EIS` (exception entry and
exit are context synchronising). `SPAN` stays clear, so on a CPU with
`FEAT_PAN` every exception entry sets `PSTATE.PAN`; the kernel relies on
it for nothing, since it makes no access through a user translation
(AB3). `TCR_EL1.HA` and `HD` are set where the CPU manages dirty state
(**Store tracking** in [Translation](#translation)). `CPACR_EL1` enables FP and SIMD at EL0
and traps SVE and SME. `MDSCR_EL1` disables EL0 debug. `PMUSERENR_EL0` is
zero, so EL0 cannot read performance counters. `CNTKCTL_EL1` allows only
the virtual counter at EL0. Every other feature with EL0 state found in
the ID registers is left disabled, and the boot audit lists them (K15,
AB2).

### Stack proof

The stack proof reads the call graph of the linked image, which every
build links with lld's `--emit-relocs` so that the image keeps the
relocations its final link resolves, and decodes every `bl`, `b`,
`b.cond`, `cbz`, `cbnz`, `tbz` and `tbnz` from `llvm-objdump -d -r`
itself: a `bl` is a call, which adds the caller's frame, only with an
`R_AARCH64_CALL26` relocation naming its target; a `b` to the start of
another function is a tail jump, which replaces it, only with an
`R_AARCH64_JUMP26` relocation naming its target; and every other branch, a
conditional one included, must stay inside its function, or the proof
fails (format and relocations measured with clang 23.1.4 for
`aarch64-none-elf` on the development host, 2026-10-29; that lld keeps
both relocations in a linked image under `--emit-relocs` is *to confirm*
when the proof is built). An ordinary tail call is a `bl` at `-O0` and a
`b` at `-Og` and `-O2`, and a `musttail` call is a `b` at every level. An
indirect call is a `blr` or a `br`, and the interrupt and SError vectors'
call graph has none ([design-kernel.md](design-kernel.md#stack-proof)).
The EL1 synchronous vector runs on the panic stack, so no kernel path
counts it on a thread's stack.

### Chokepoints

The AArch64 forms of the generic chokepoint rules
([design-kernel.md](design-kernel.md#chokepoint-checks)):

| Generic rule | On AArch64 |
| --- | --- |
| the kernel never accesses memory through a user address | no `LDTR`, `LDTRB`, `LDTRH`, `LDTRSB`, `LDTRSH`, `LDTRSW`, `STTR`, `STTRB` or `STTRH` anywhere in the kernel image; `erx_uword_t` read only in `kernel/arch/aarch64/uword.c` |
| system-register instructions only in their accessors | `mrs`, `msr`, `sys` and `sysl` only in generated accessors, the named barrier and maintenance helpers and the listed assembly files |
| TLB and cache maintenance only in the helpers | `tlbi`, `dc` and `ic` only in `kernel/arch/aarch64/tlb.c` and `cache.S` |
| exception returns and firmware calls only where listed | `eret` only in the vector and exit object and in the boot entry's drop from EL2; `hvc` and `smc` only in the SMCCC routine; the firmware mailbox's registers only in the trial request and the boot-time key read in `kernel/platform/rpi_mbox.c`, the key read and its derivation in the boot-only section `.text.boot_only`, which the kernel unmaps before the system domain starts |
| only the early-console writer writes a UART's registers in the kernel | the UART register accessors only in the early-console writers `kernel/platform/pl011.c` and `miniuart.c`, which only the boot path, the panic path and the machine's end call |
| the board's watchdog only from its driver, reloaded only from the kernel's timer | its registers only in `kernel/platform/bcm2835_wdt.c`, whose reload function only the timer calls ([design-platforms.md](design-platforms.md#the-watchdog)) |
| the kernel touches no PCIe configuration space | no accessor generated for `pci-host-ecam-generic` or `brcm,bcm2712-pcie` registers is linked into the kernel |
| only the `fiasco` backend issues Fiasco calls | no `svc` other than `svc #0x4552` outside `liberx/backend/fiasco/` |

## Interfaces

* **`kernel/arch/aarch64/`**, the architecture layer: `boot.S`, the
  vectors, the switch, `uword.c` with `erx_uword_load`, `tlb.c` and
  `cache.S`, the SMCCC routine.
* **`abi/arch/aarch64.txt`**, the call convention and the in-memory
  layouts ([The ABI file for AArch64](#the-abi-file-for-aarch64)).
* **`hw/arch_terms/aarch64.txt`**, the terms `make check-arch-terms` keeps
  out of generic code and documents: the exception-level names, the
  system-register and instruction names above, and the names of the GIC,
  the SMMU and their parts
  ([design-kernel.md](design-kernel.md#chokepoint-checks)).

### Hardware register sources

**Device registers** of the architecture's own devices are written into
CMSIS-SVD files under `hw/svd/` from their specifications: the PL011 UART
(Arm DDI 0183), the GICv3 distributor and redistributor (IHI 0069; the CPU
interface is system registers), the GICv2 distributor and CPU interface of
the boards' GIC-400 (IHI 0048), the GICv2m frame (DEN 0029), the PL031
real-time clock (Arm DDI 0224) and the SMMUv3's registers (IHI 0070). The
access sequences SVD cannot express are declared in erXos's own namespace:
the redistributor's wake handshake through `GICR_WAKER`, the SMMU's `CR0`
and `CR0ACK` handshake and waits on the distributor's `RWP`.

**System registers** are described in `hw/sysreg/aarch64.json`, extracted
by `tools/sysreg_extract.rb` from Arm's open-source machine-readable data
(`AARCHMRS_OPENSOURCE_A_profile_FAT`, release 2026-09, schema 2.9.6),
which `make fetch` downloads at a pinned SHA-256; its `Registers.json`
declares itself "licensed under the BSD 3-clause license", so the
extracted file keeps Arm's notice and records its origin. A read of
`ICC_IAR1_EL1` acknowledges an interrupt, an example of a read with a side
effect that the file records. `make check-sysreg` extracts again and
compares.

## Compatibility and migration

Until a release promises compatibility, a change to the binding's call
registers, frames or in-memory layouts replaces the old form outright and
is a new ABI version, with no path kept for an earlier one. An image is
built for one architecture, and `abi/arch/aarch64.txt` shares the ABI
version of `abi/erx_abi.txt`, so the manifest check refuses an image
built against another version of either, with a diagnostic.

## Failure handling, diagnostics and debuggability

| Failure | Detection | What remains | User-visible result |
| --- | --- | --- | --- |
| An exception taken at EL2 during boot | the EL2 vector | nothing: the boot stops | its syndrome on the early console |
| A foreign `svc` | the dispatch | the thread stopped | a fault record of kind `foreign_trap` |
| An SError presumed to be a thread's | the exit window or EL0 | the thread stopped | a fault record of kind `async_error`, shown as a presumption |
| An SError a posted write reports after its window | the next window, or EL0 | the thread there stopped, or a log line, unless an error record names the source | a fault record that may name the wrong thread |
| A corrected or restartable SError (`CE`, `UEO`) | `ESR_EL1.AET` | nothing | a log line |
| An uncontainable or unrecoverable SError (`UC`, `UEU`) | `ESR_EL1.AET` | the machine | a panic report with `ESR_EL1`, `FAR_EL1`, `ELR_EL1` and registers |
| A `CMD_SYNC` that misses `ERX_IOMMU_SYNC_NS`, or a command error in `SMMU_GERROR` | the driver's poll | the SMMU failed, and the pages whose invalidation it owed kept from reuse | a log line naming the SMMU; `ERX_EDEAD` from calls on its windows |
| A window whose device faults past `ERX_DMA_FAULTS` records in a period | the event queue's drain | the stream's entry set to abort | the quarantine in the window's inspection, and its fault IRQ object fired |

## Security

AArch64's part of the kernel's hardening is a kernel that makes no access
through a user translation (AB3), `WXN` (AB4), `PXN` and `UXN`, `E0PD1`, pointer
authentication and BTI where the CPU has them, trapped SVE, SME, EL0 debug
and performance counters, and Linux's speculation mitigations. Residual
risks, which [design.md](design.md#residual-risks) records: an SError
reported too late to attribute; cache side channels across CPUs through
shared read-only pages, since `UCI` lets EL0 clean caches by address;
speculative reads the mitigations do not cover; and MSIs through the
GICv2m frame or the boards' MIP block, which do not identify the writer,
which a GICv3 ITS would close on boards that have one.

## Verification and testing

* **Boot from EL2** on each board, and the register audit after it (AB1,
  AB2).
* **Every EL0 exception class** raised by a fault-injection program, and a
  foreign `svc` that ends with `foreign_trap`.
* **SError injection**: each board's error-injection test, with
  attribution checked in the exit and device windows.
* **Kernel access to memory**: every call given a kernel-half address, a
  tagged address and an unmapped address wherever it takes an integer,
  which must fail with a status and never reach a kernel access;
  `erx_uword_load` against words unmapped, remapped, made read-only and
  freed by other threads during a wait, on four CPUs under HVF and on
  each board; a seeded `LDTR` in a kernel object, which the chokepoint
  check must reject. Passing: a umtx wait and wake across two spaces on a
  shared object. Seeded failure: a walk that skips the level-3 `AP[1]`
  check, which the test of a word mapped without EL0 access must catch.
  Passing: umtx waits on a word of a boot-image slice and of a device's
  register window, each refused with `ERX_EFAULT`, and the host model of
  the walk with outputs in the boot image, a register page and a board's
  crash region, each refused. Seeded failure: a walk that skips the
  direct-map range check, which the register-window test turns into an
  EL1 data abort and a panic.
* **Store tracking** both ways on each CPU that offers both: stores from
  four threads racing reports, each store reported exactly once by the
  report after it. Passing: a page stored after a report appears in the
  next. Seeded failure: a report that clears the mark without the
  invalidation, which a store through a stale writable TLB entry must
  expose as a lost store under HVF and on the boards. Passing: a store,
  then an unmap of the mapping or a kill of the storing space, then a
  report, which reports the page stored. Seeded failure: a removal that
  frees a detached table without folding its entries, which that test
  must expose as a lost store under hardware dirty state.
* **The SMMU** under QEMU and on each board with one: a device that faults
  on every access, whose window is quarantined within one period and whose
  stream then records nothing; an event queue driven into overflow, whose
  overflow episodes are counted and lost-record count stays unknown; and
  a buffer unmapped under continuous DMA,
  whose page is reused only after the device's writes have stopped.
  Delay a sync, force hardware ring and software ticket rollover, suspend
  a waiter, fail a sync and reset, and check that unknown completion
  preserves every affected data and table page. Send traffic marked
  already translated with ATS disabled, including on an abort stream;
  it must never bypass translation. Contrast valid abort with invalid
  STEs to test silent quarantine. Check requester identity under hostile
  configuration writes, and MSI spoofing within the documented interrupt
  trust boundary. Loader tests retain outstanding writes beyond the SMMU
  and verify that failed quiescence prevents allocator handoff. Seed stale
  firmware configuration/TLB entries, inherited live queue and MSI
  controls, and pending writes: unsupported handoff must stop before
  allocator handoff, while a supported handoff must invalidate every
  inherited entry before translation is enabled. Delay an old stream's
  events across destruction and verify that rebinding waits for their
  retirement rather than attributing them to the new window.
* **IRQs taken at EL1 preemption points**, with the interrupted frame
  checked on the stack and the thread record's user registers unchanged.
* **Memory-ordering litmus tests** of the lanes' ring and reader-page
  protocol, which connections, channels and pipes share, checked with herd7
  under the AArch64 model ([design-domains.md](design-domains.md#connections)).
* **`make check-sysreg`** and the chokepoint checks above, each with a
  test that seeds a violation.

## Performance

A minimal trap from EL0 and its return costs about 22 ns, and about 31 ns
with an address-space switch, under HVF on the primary host
([measured](research-baselines.md#exception-and-address-space-switch-costs)).
The counter runs at 62.5 MHz under TCG and 24 MHz under HVF. Each
speculation mitigation's cost on entry is measured on each board with
`tools/erx bench nullcall`.

## Portability

This document is the AArch64 port. What differs between the accelerators
on the primary host: HVF enters at EL1 and reports no GIC in
`ID_AA64PFR0_EL1`, and its in-kernel GIC has no ITS; neither has `RNDR`
([measured](research-baselines.md#accelerator-capabilities)).

## Dependencies

No new dependencies: Arm's machine-readable architecture specification is
in the dependency table of [design.md](design.md#dependencies).

## Alternatives considered

**Running the kernel at EL2.** With the Virtualization Host Extensions the
kernel could stay at EL2. It loses: HVF enters guests at EL1, so a kernel
that needs EL2 would not run on the primary host, and erXos runs no
virtual machines, which is what EL2 is for.

**A user-copy funnel with `LDTR`, `STTR` and PAN.** The kernel could take
pointers into user memory and copy through them with the unprivileged
forms, with PAN set where the CPU has it and, on the Cortex-A72, which
lacks PAN, an empty `TTBR0_EL1` with a reserved ASID outside bounded
assembly copy parts. It loses: every copy could fault at EL1, which needs
a fixup table, fault handling and population inside the kernel's own
accesses, and on the Cortex-A72 a per-entry switch of `TTBR0_EL1` whose
correctness across preemption, helping and ASID rollover is a proof of
its own. Memory windows and the UTCB carry every argument with no access
that can fault ([design-kernel.md](design-kernel.md#arguments-and-results)).

**The GIC's ITS for MSIs.** It loses on the primary host: HVF's in-kernel
GIC has no ITS, so the GICv2m frame serves both accelerators by one path
([research](research-kernel-bases.md#qemu-virt-under-tcg-and-hvf)).

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| GICv2m behaviour differs between TCG and HVF | low | MSI drivers | one path for both, tested on both |
| A new core needs a speculation mitigation Linux adds later | medium | a side channel on that core | mitigations are chosen from the ID registers as Linux chooses them, and each board's port checks Linux's list |

No open question remains for the user.

## References

* Arm Architecture Reference Manual for A-profile, DDI 0487: translation
  table maintenance, hardware management of the access flag and dirty
  state, exception entry, the generic timer, `SCTLR_EL1.UCI` and `UCT`,
  and the cache-maintenance instructions.
* Arm GICv3 and GICv4 architecture specification (IHI 0069); GIC
  architecture specification v1 and v2 (IHI 0048); GICv2m (DEN 0029);
  SMMUv3 (IHI 0070); PL011 (DDI 0183); PL031 (DDI 0224); Power State
  Coordination Interface (DEN 0022).
* Arm IHI 0070 G.b, sections 3.5.2, 3.9.2, 4.7.3, 5.2.1 and the
  `SMMU_CR0` register description; Cortex-A72 TRM
  `100095_0003_06_en`, identification-register summary and Table 4-35;
  Linux v6.12 `entry.S` and `booting.rst`: checked sections
  and evidence limits in
  [research-hardware-contracts.md](research-hardware-contracts.md).
* Arm, "Release notes for BSD license JSON in A profile architecture",
  document 110173, https://developer.arm.com/documentation/110173/.
* Arm's machine-readable A-profile architecture data,
  `AARCHMRS_OPENSOURCE_A_profile_FAT`, release 2026-09, schema 2.9.6.
* Linux arm64 boot protocol, `Documentation/arch/arm64/booting.rst`
  (v7.3), for entry at EL2; `init_el2_state`; `arch/arm64/mm/context.c`
  (ASID allocation) and `arch/arm64/kvm/hyp/entry.S` (SError attribution),
  v7.3.
* Fiasco, https://github.com/kernkonzept/fiasco, commit `50bbe8a9`:
  `arm/iommu-arm-smmuv3.cpp` and `arm/dmar_space-smmuv3.cpp`.
* TF-A 2.15.0's Raspberry Pi 4 port, as read in
  [research-boards-storage.md](research-boards-storage.md).
* [research-baselines.md](research-baselines.md),
  [research-kernel-bases.md](research-kernel-bases.md) and
  [research-boards-storage.md](research-boards-storage.md) for the
  measurements and facts cited above.
