# DMA by devices that are not cache-coherent

A device that is not cache-coherent reads and writes memory without
looking in the CPU's caches. Data the CPU wrote may still sit in a cache
when the device reads, and a stale or dirty cache line may hide or
overwrite what the device wrote. The Raspberry Pi 4's Ethernet controller
(GENET) moves packets only by DMA and is not coherent; its SD controller
(EMMC2) can move blocks by DMA through ADMA2 tables and is not coherent
either. This document says how the device NIF
([design-runtime.md](design-runtime.md#the-device-nif)) keeps the CPU and
such a device in agreement, how it learns the address at which a device
sees memory, which registers the NIF must own so that no driver can aim a
device at memory, and the three descriptor forms the NIF drives. It
refines the DMA envelope of
[design-kernel.md](design-kernel.md#dma-and-the-iommu) and the device
NIF; the AArch64 instructions are in
[design-arch-aarch64.md](design-arch-aarch64.md#cache-maintenance).

Decisions every reader needs:

* **Memory changes hands in whole granules, and is maintained line by
  line.** Every region of a device's memory, a ring part, an ADMA2 table,
  a pool buffer or a region of the record, starts and ends on a
  cache-writeback granule, and at any moment either the CPU or the device
  is its writer, never both. No writeback ever carries bytes of two
  writers, so no cache operation on one region can touch another's data.
  Maintenance runs over every cache line of a region, stepping by the
  smallest line, since a granule may span several lines.
* **Cache maintenance follows from the handoff, in one place.** A buffer
  passes to the device when the queue's own bookkeeping posts it, and
  comes back when it completes; one sequencer derives from that change of
  state, and from the ring fields a plan writes, which regions to clean,
  which to clean and invalidate, which bytes to zero, and the barriers in
  their one valid order. No form names a handoff, issues maintenance or a
  barrier, so none can forget or misplace one. For a coherent device the
  maintenance is empty and the barriers remain.
* **The device writes over zeros.** Every byte of a buffer that passes to
  the device and that the plan does not fill is zeroed first, so a
  completion returns the device's bytes or zeros, never an earlier
  request's, whatever length within its bound the device reports.
* **A device is given device addresses only.** Every address the NIF
  writes to a device is the device's own view of memory the record holds:
  the I/O address `erx_dma_map` gave for a confined device, and for an
  unconfined one the physical address moved through the record's DMA
  range. Each DMA device's record carries whether it is coherent and that
  one range, both read at boot from the device tree the firmware hands
  over ([design-device-tree.md](design-device-tree.md)); a device whose
  range is absent, or whose DMA memory would lie outside it, gets no DMA
  memory, and the NIF refuses a queue whose addresses a descriptor form
  cannot hold.
* **A register is the NIF's when a write to it can aim the device.** The
  NIF owns every register, and every field, through which a write could
  change an address the device uses, how many bytes it moves at an
  address, which descriptors it takes as valid, how it reads them, or how
  it reports the end of a transfer the NIF tracks. Drivers write the
  rest, and a write that would change an owned field is `badarg`. Every
  driver write takes the device lock, so no write, a reset included,
  lands between a check the NIF makes and the write that check guards.
* **A buffer is reused only after the device says it is done.** The NIF
  takes a buffer back only on the device's own report, read in the same
  call: a completion without an error, or the idle report that follows a
  reset the NIF wrote. A reset the driver makes can make the device
  forget a transfer; its queue then waits for a completion that does not
  come, until `negotiate/2`, and no buffer is freed by it.

## Context

**The hardware.** Linux 6.18's tree for the BCM2711, which the build
already fetches (`deps.lock`, `linux-dts`), marks no node `dma-coherent`
(no match under `arch/arm/boot/dts/broadcom/`). GENET,
`/scb/ethernet@7d580000`, sits on `scb`, which has `ranges` and no
`dma-ranges` (`bcm2711.dtsi:545-551, 587-594`), nor has the root above
it, so its device addresses equal the CPU's under the walk of
`erx_dma_ranges` ([design-kernel.md](design-kernel.md#dma-and-the-iommu)),
which follows the Devicetree Specification v0.4, section 2.3.9.
GENET's descriptors are not in memory: 256 per direction, each three
32-bit registers (status, address low, address high), sit in its register
window at `0x2000` for receive and `0x4000` for transmit
(FreeBSD's `if_genetreg.h:116-124, 168-192`), and FreeBSD gives its
buffers DMA tags limited to 40-bit addresses (`if_genet.c:586-589,
611-614`). EMMC2,
`/emmc2bus/mmc@7e340000`, sits on a bus of its own whose `dma-ranges` map
bus address `0xC0000000` to the first GiB of RAM
(`bcm2711.dtsi:418-432`); the tree's comment says the firmware rewrites
that property according to the SoC's revision, keyed on the `emmc2bus`
alias (`bcm2711.dtsi:411-417`), which the board's tree defines
(`bcm2711-rpi.dtsi:14`). The legacy peripherals see the first GiB at
`0xC0000000` too (`bcm2711.dtsi:45`). Linux drives EMMC2 with the
controller's own ADMA2 engine when its capabilities offer it, and FreeBSD
moves EMMC2's data with the SoC's separate DMA controller instead
([facts record](research-sdhci-bcm2711.md#dma-for-a-later-design)).
FreeBSD's driver does not use ADMA2; the descriptor comes from the SD
Host Controller Simplified Specification, version 4.20 ("Host
Controller" below, by section and printed page):

* **The entry.** With 32-bit addressing an entry is 8 bytes: the
  attributes in bits 5:0, a length in bits 31:16, and the data's 32-bit
  address in bits 63:32 (section 1.13.2, figure 1-10, p. 17; section
  1.13.3.1, figure 1-11, p. 18). The attributes are valid (bit 0), end
  (bit 1), interrupt (bit 2) and the action bits Act0, Act1 and Act2
  (bits 3 to 5); Act0 is 0 for every ADMA2 entry, and Act2 1 with Act1 0
  is a transfer, 1 and 1 a link, 0 and 0 or 0 and 1 no operation. An entry
  fetched with valid 0 raises the ADMA error and stops the engine
  (figure 1-10). Bits 15:6 hold the upper ten bits of a 26-bit length
  only when host control 2's ADMA2 length mode is 1; with it 0, as the
  NIF keeps it, they are not part of the length and the form writes them
  0 (section 1.13.3.1, p. 18; section 2.2.25, bit 10, p. 97). The
  controller reads entries, and the specification
  gives it no write to them.
* **The length.** In 16-bit length mode a length field of 1 to `0xFFFF`
  moves that many bytes and 0 moves 65,536 (table 1-12, p. 18), while
  section 1.13.1.3 (p. 16) says an entry moves less than 64 KiB. The two
  agree on every value from 1 to 65,535, so the form writes no entry of
  65,536 bytes or of 0.
* **Alignment.** A data address is a multiple of 4 bytes (section
  1.13.1.3, p. 16). With 32-bit addressing the table starts on a 4-byte
  boundary, since the controller ignores the low two bits of
  `adma_address`, whose upper 32 bits are 0 (section 2.2.31, table 2-42,
  p. 116; section 1.13.2, p. 17). DMA select `10b` in host control 1
  selects 32-bit ADMA2 while host version 4 enable is 0 (section 2.2.11,
  pp. 60-61).
* **Lengths and the block count.** The entries' lengths sum to a multiple
  of the block size, or the transfer may not end until a data timeout
  (section 1.13.1.3, p. 16). With block count enable set, a sum that
  differs from block size times block count, or that the block size does
  not divide, sets the ADMA length mismatch error, bit 2 of the ADMA
  error status register at `0x54`, and raises the ADMA error status
  (section 2.2.30, table 2-41, p. 115; section 2.2.19, bit 9, p. 83).
  The engine stops after the entry with end set, and in ADMA2 mode every
  stop raises transfer complete (section 1.13.3.2, table 1-14, p. 20).
  The specification does not say when the mismatch is detected relative
  to the bytes moved, nor whether transfer complete is raised beside the
  ADMA error; the board pass settles both on the BCM2711.

QEMU 11.1.3's `virt` marks every virtio-mmio node `dma-coherent`
(its tree as `-machine virt,dumpdtb=` writes it, read on 2026-11-12), and
QEMU performs that DMA itself, coherently.

**What Arm says.** The cache type register gives two sizes that differ in
general: the cache-writeback granule, `CWG`, the largest block of memory
that the eviction of one modified cache entry can overwrite, and
`DminLine`, the smallest data cache line of any cache the processor
controls. The Cortex-A72, the Pi 4's CPU, reports 16 words, 64 bytes, for
both (Cortex-A72 TRM r0p3, section 4.3.26, Table 4-40); the architecture
does not make them equal. A data cache instruction by address acts on one
line. A `DMB` orders data cache maintenance like a data access, and one
that is meant to order cache maintenance must order both loads and stores
(Arm, *Learn the architecture: Memory Systems, Ordering, and Barriers*,
102336 version 1.0, section 5, p.13); a `DSB` completes the cache
maintenance issued before it by the CPU that executes it (section 6,
p.14).

**What FreeBSD does.** FreeBSD 14.1's arm64 `busdma`, for a tag that is
not coherent, cleans to the point of coherency before the device reads
(`sys/arm64/arm64/busdma_bounce.c:1055-1058`), writes back the partial
lines at a buffer's ends and invalidates before the device writes
(`:1059-1071, 1012-1024`), and invalidates after it wrote (`:1072-1075`),
with `DSB SY` after the maintenance that precedes a transfer and before
the CPU reads what one wrote (`:1097-1102, 1175-1180`). Its maintenance
loops step by the data cache line, which it takes from `DminLine`
(`cpufunc_asm.S:52-80`; `identcpu.c:2780-2790`), and it aligns and sizes
a non-coherent buffer to that line (`busdma_bounce.c:277-290`), not to
`CWG`; on the Pi 4's CPU the two are equal. Memory a driver asks to be
coherent on a non-coherent tag it maps uncached (`:533-541`). Its
`mb()`, `rmb()` and `wmb()` are full-system `DMB`s (`atomic.h:51-56`).
The virtio specification makes a device write at least the
length it reports, and notes that a driver that does not know how much
was written must zero the buffer beforehand to avoid leaking data
(Virtio 1.2, sections 2.7.8 and 2.7.8.2).

**What the code does today.** The device NIF runs virtio's split ring
through the sequencer below, with `G` and `L` from the architecture
layer, but runs a given device's queues as coherent, since the record
does not carry the mark yet, so on the stopgap no maintenance is issued
(`otp/erts/emulator/nifs/erxos/erx_device.c`, `queue_coherent`; the gap
is a `TODO.md` item). Its one lock serialises opens, binding changes and every
queue call, and is held across service calls (`erx_device_nif.c:12-15`);
register writes, which are BIFs, take no lock (`erx_device_bif.c`,
`erx_device.c:372-420`). The manifest's device record has no
coherence mark and no DMA range; its only flag is `hostile`
(`abi/manifest.txt:77-78, 256-277`). On the stopgap, every device's DMA
memory comes from one 2 MiB contiguous pool the root takes from `sigma0`
at boot (`liberx/backend/fiasco/vm.c:228-233`;
`liberx/backend/fiasco/page_pool.h:48`), an object is at most 1 MiB
(`abi/erx_abi.txt:33`), its device address is its physical address
(`vm.c:410-421`), and the create's limit is read as a physical address
(`vm.c:388-391`). Fiasco lets user mode clean and invalidate by address
and read the cache type register
(`fiasco/kernel/src/kern/arm/64/cpu-arm-64.cpp:34-48`).

## The construction: handoffs of granules

**The granule and the line.** `G` is the CPU's cache-writeback granule
and `L` its smallest data cache line, both reported by the architecture
layer; where CPUs differ, it reports the largest granule and the smallest
line of any CPU. The NIF reads them once, when it loads. Ownership is
counted in granules, because one writeback can overwrite a whole
granule; maintenance steps by lines, because one maintenance instruction
acts on one line and a granule may hold several.

**Regions and writers.** The memory a device's record holds, the
contiguous object or the window-mapped memory, is divided into regions,
each a whole number of granules starting on a granule boundary:

* the parts of a queue's rings that one side writes: for virtio the
  descriptor table and the available ring, which the CPU writes, and the
  used ring, which the device writes; for ADMA2 the queue's table, which
  the CPU writes;
* each pool buffer: a queue's buffers lie at a stride of the buffer size
  rounded up to `G`;
* each region of the record
  ([design-runtime.md](design-runtime.md#the-device-nif), Regions):
  written by the CPU for the boot and read by the device whenever a
  request names it. No transfer hands a region over, so nothing would
  clean it before the device reads; a region is therefore made only for a
  coherent device, and `region/3` on another is `{error, enotsup}`.

A region's writer is the CPU or the device, and is a function of the
queue's state. A buffer's writer is the device from its post until its
completion, and the CPU otherwise. A ring region's writer is the one the
form names while the queue is installed; from the device's idle report
in `negotiate/2` until the install's last write the device holds nothing
of the queue, and every region of it, the used ring included, is the
CPU's. A region of the record's is always the CPU's. Which state a
buffer and a queue are in is the queue's bookkeeping,
`erx_device_queue`, which already hands out a buffer only through a post
and takes it back only through a completion or `negotiate/2`. The CPU
stores only into regions whose writer it is, and never into a buffer
between its post and its completion.

**The three rules.**

1. **Zeroing.** When a buffer passes to the device, every byte of it that
   the plan does not fill with an `out` segment's bytes is set to zero,
   before rule 2's clean. A completion then copies, up to the length the
   device reported, the device's bytes or zeros, never bytes an earlier
   request left there.
2. **Handing over.** When a region passes to the device, for it to read
   or to write, the CPU cleans every line of it to the point of
   coherency. Afterwards no line of the region is dirty in any cache.
3. **Taking back.** Before the CPU reads a region the device may have
   written, after it has read the device's report that the region is
   done, the CPU cleans and invalidates every line of it. Since rule 2
   left none dirty and the CPU stored nothing since, the clean writes
   nothing back; the invalidate discards any line the CPU fetched by
   speculation while the device held the region.

Three barriers complete them:

* the **publish barrier**, after the handing over and before the register
  write that tells the device, so the device sees every store and every
  clean, and no load of a region taken back is still pending when the
  device may write it again;
* the **report barrier**, after the read of the device's report and before
  the taking back and the reads that follow; it orders loads and stores
  both, since a barrier that orders cache maintenance must, so neither a
  maintenance instruction nor a read moves before the report;
* the **completion barrier**, after taking back and before the reads, so
  the invalidates are complete when the CPU reads.

For a coherent device rules 2 and 3 are empty, and with them the
completion barrier; rule 1 and the publish and report barriers stay. The
report barrier is the same for both, so there is one kind of it.

**What disappears.** Each failure a non-coherent device invites is a case
the construction cannot reach, not a case it handles:

| Failure | Why it cannot happen |
| --- | --- |
| the device reads data still in a cache | rule 2 cleans every region before the publish barrier, and the device learns of the region only from the write after it |
| a dirty line is evicted over what the device wrote | rule 2 leaves no dirty line, and the CPU stores nothing into a region the device holds |
| the CPU reads a line it fetched before the device wrote | rule 3 invalidates after the report and before the read |
| the install's zeroed used ring is evicted over the device's first completion | the used ring's writer changes from the CPU to the device at the install, so rule 2 cleans it like a posted buffer |
| maintenance misses a line inside a granule | maintenance steps by `L`, the smallest line, not by `G` |
| maintenance of one region destroys another's data | no granule holds bytes of two regions |
| a driver discards data it did not write | there is no invalidate alone, only clean and invalidate, which loses nothing; on AArch64 user mode cannot invalidate alone anyway |
| a descriptor form forgets a handoff, maintenance or a barrier | forms name none of them; the sequencer derives them from the queue's change of state and the ring fields the plan writes |
| a completion returns an earlier request's bytes | rule 1 zeroed every byte the plan did not fill before the device held the buffer |

## Calls, observations and plans

A descriptor form's core is a pure state machine over the queue's state:
its bookkeeping of free and posted buffers and, for ADMA2, whether the
queue is idle, armed or in flight. A queue call runs in rounds. In each
the core returns either an **observation**, a bounded list of reads it
needs, or a **decision**, a plan and the queue's next state. The effect
layer, `erx_device.c`, performs an observation's reads with the
maintenance and barrier the sequencer adds and hands the values back to
the core, which is called again; it runs a decision whole. It decides
nothing itself. A form needs at most two observations per call: an index,
then the entries the index names. virtio's completion reads the used
index, then each used entry it covers; GENET's receive completion reads
the producer index, then the status of each descriptor it covers, at
most the queue's size; GENET's transmit completion reads the consumer
index; ADMA2's reads `interrupt`. A value out of its bound breaks the
queue, as a malformed used entry does today.

A plan is a list over a closed set of steps:

* `write`: a copy of an `out` segment's bytes into a buffer, or a store of
  a ring field (a descriptor, an available entry, an ADMA2 entry);
* `publish`: a write that tells the device, of an owned register or of a
  ring field the form names as its publication, such as virtio's
  available index;
* `copy`: bytes of a buffer coming back, up to the length the device
  reported, into a fresh binary.

An observation is a list of `report` steps, each a read of a register or
of a ring field the device writes.

**The sequencer.** `erx_device_dma_order(before, after, plan, coherent,
G, L)`, a pure function, derives the handoffs from the two states and
returns the effects in their one order. A region whose writer is the CPU
in `before` and the device in `after` passes to the device: a buffer
posted, and at an install the used ring. A region whose writer is the
device in `before` and the CPU in `after` comes back: a buffer completed,
and after a reset's idle report every buffer still posted and the used
ring. And every region a `write` touches, whose writer stays the CPU,
passes to the device for reading. For a decision that hands over: the
zeroing of rule 1 for each buffer passing to the device; every `write`,
the install's zeroing of the rings among them; the clean
of every region passing to the device; then each `publish` in the plan's
order, each after a publish barrier, and a ring field's followed by the
clean of its line. For an observation: each `report` of ring memory after
its lines are cleaned and invalidated and a completion barrier; the
reads; then the report barrier. For a decision that takes back: the clean
and invalidate of every region coming back; the completion barrier; then
each `copy`. A call that takes a buffer back and hands it out again, as
the register ring's receive queue does, is a decision that takes back
followed by one that hands over, each with its own two states, and so is
`negotiate/2` after its idle report: one decision takes every region of
the queue back, the next installs it. So the install's zeroed rings are
clean before the base addresses and the ready bit are written, and no
dirty line of a zeroed used ring is left for a later clean and
invalidate to write over the device's first completion.

**The check.** `erx_device_dma_check(before, after, plan)` validates a
decision before any effect:

* `after` differs from `before` only as the call allows: a post moves
  buffers from free to posted, a completion from posted to free, an
  install starts from every region the CPU's and gives the rings their
  writers and may hand buffers over, a reset after the idle report makes
  every region the CPU's, and an observation changes nothing;
* every `write` lands in a region of the queue whose writer in `before`
  is the CPU, a ring region or a buffer passing to the device in this
  decision;
* every `publish` names an owned register of the record's peripheral, or
  the ring field the form names as its publication; a register is 32 bits,
  and a 64-bit address published over a low and a high register is one
  step naming both, so its whole value is checked;
* every `copy` reads a buffer coming back in this decision, within the
  buffer;
* every region lies inside the record's memory and starts and ends on a
  granule;
* every device address the plan writes, a buffer's, a table's or a
  region's, lies inside the memory the record holds, as the device sees
  it, and below the form's address width, together with the bytes the
  device may reach from it, which the step carries: a descriptor's
  length, a ring's or a table's size;
* the form declares where its memory holds addresses, as a descriptor
  table's place, count and size and each descriptor's address and length
  fields, from its own constants; an address the plan stores in memory is
  an address step at a descriptor's address field, and the same plan
  stores that descriptor's length equal to the step's reach; no other
  store covers either field, zeros cover both fields of a descriptor or
  neither, and a publication in memory is a plain value on neither field,
  so no address reaches the device as a plain value and no length passes
  what its address was checked for.

A plan that fails the check is a bug in the core, not an input, and the
call is `badarg` with nothing applied.

## Device addresses and reach

**The record.** Each DMA device's catalogue entry, and from it the
`given` record its holder reads
([design-stopgap.md](design-stopgap.md#device-records)), carries two
facts the root reads at boot from the device tree the firmware handed
over, with the reader of [design-device-tree.md](design-device-tree.md):

* `coherent`, a flag: set when the device's own node (a PCIe
  function's host bridge node, since the function has none) carries
  `dma-coherent`, the property the Devicetree Specification v0.4
  defines for a device on an architecture whose I/O is not coherent by
  default, with an empty value (section 2.3.10, p. 17); a mark with a
  value makes the facts malformed. Both supported trees mark devices on
  their own nodes: QEMU `virt` each virtio-mmio node, and the BCM2711's
  none. A `dma-noncoherent` on the node says what the default already
  says. Both marks on the node, or either mark on any node above it,
  makes the device's DMA facts absent with the reason `coherence`, so
  the device gets no DMA memory rather than a reading the specification
  does not give: it defines each mark for a device, not for a bus;
* the **DMA range**, `dma_cpu`, `dma_bus` and `dma_last`: the device's
  translation, not a list of memory. The device sees CPU address
  `dma_cpu + x` at bus address `dma_bus + x`, for every CPU address from
  `dma_cpu` through `dma_last`, the last one inclusive so that the whole
  address space can be written. A device with no defining `dma-ranges`
  has `0`, `0` and `2^64 - 1`. The reader computes it with the walk of
  `erx_dma_ranges`
  ([design-kernel.md](design-kernel.md#dma-and-the-iommu)), which keeps
  each window of the translation that RAM backs at least in part, whole,
  and the range is absent when no such window remains, or more than one,
  which no supported board's tree gives. Which RAM inside the window
  holds DMA memory is the allocator's question, answered where the
  memory is made (Reach, below).

The reader checks the tree's encoding and containment; it cannot check
that the hardware does what the tree says. A well-formed tree that
states a wrong translation aims the device outside the object, and a
wrong `dma-coherent` suppresses maintenance the device needs. The tree
is the firmware's, and the firmware is trusted as the machine's own
([design.md](design.md#residual-risks), "Closed firmware"), so these
are the firmware's faults, not inputs the reader defends against; a tree
the reader can see is wrong fails safe, one it cannot see is wrong is
believed.

No build-time record carries either fact: the manifest says which device
gets how much DMA memory, and the tree says how the device sees it, so
the firmware's rewrite of a range needs no record to agree with it
([design-device-tree.md](design-device-tree.md#open-decisions) keeps the
alternative of a manifest copy as an open decision). The reader's host
tests pin each platform's facts from its build-time tree and fail on a
DMA device whose facts are absent there, so a board tree whose marks or
ranges the reader refuses fails at build time, and the same tree from
the firmware fails safe at boot.

**Addresses.** Every address the NIF writes to a device is the device's
view of memory the record holds, computed by the NIF and never given to
or taken from Erlang. For a confined device it is the I/O address that
`erx_dma_map` gave the memory object in the device's window
([design-kernel.md](design-kernel.md#dma-and-the-iommu)), plus the
offset. For an unconfined device it is `erx_mem_dma_addr(mem, offset)`,
`physical + dma_bus - dma_cpu` for the device the object was made for;
the DMA range concerns only this path. Each descriptor form has an
address width, fixed by its descriptor format: 64 bits for virtio's
split ring, 40 for GENET's register ring, 32 for ADMA2 with 32-bit
descriptors. `queue_create/4` refuses with `{error, erange}`, taking
nothing, a queue any of whose device addresses would reach the width.

**Reach.** The object must lie wholly inside the device's range. On
erXos's kernel, `erx_mem_create_contiguous` allocates from the part of
the device's window that its contiguous pool's RAM backs, the window
found by the same walk over the same tree, so the kernel's range and the
record's are one. On the stopgap the root
makes each device's object from the contiguous pool: the object records
the entry's offset, `dma_bus - dma_cpu`, for `erx_mem_dma_addr`; a device
whose range is absent, or whose object's pages would fall outside it,
gets no DMA memory, and the root prints a line naming the device, its
range and the pool's physical address
([design-stopgap.md](design-stopgap.md#the-pool)). EMMC2 has DMA memory
on both kernels, at the range the firmware wrote for the board's
revision.

**The platforms.**

| Device | Coherent | DMA range | Form, width |
| --- | --- | --- | --- |
| QEMU `virt` virtio-mmio | yes | none: `0`, `0`, `2^64 - 1` | split ring, 64 |
| Pi 4 GENET | no | none: `0`, `0`, `2^64 - 1` | register ring, 40 |
| Pi 4 EMMC2 | no | `0`, `0xC0000000`, `0x3FFFFFFF` in Linux's tree; the firmware writes the board's own | ADMA2, 32 |

With `total_mem=1024` all of the Pi 4's RAM that erXos uses lies in the
first GiB (`config/platforms/raspi4b.json`, `ram_bytes`), inside every
range above.

## Register ownership

**The rule.** A register or a field is owned by the NIF when a write to
it can change an address the device uses, how many bytes the device moves
at an address, which descriptors the device takes as valid, how it reads
a descriptor, or how it reports the end of a transfer the NIF tracks.
The SVD source marks each register `ownedByNif`, as it does today, and
may instead mark single fields of a register; the generator refuses a
register with neither. A wholly owned register is refused to `write/3`
and `write_field/4`, as now. For a register with an owned field,
`write/3` and `write_field/4` read the register and refuse, `badarg`, a
value that would change an owned field from what the register holds; a
one-to-clear owned field is changed by writing it 1. A driver keeps its
read, modify and write of a shared register as it is: the owned field
goes back as it was read. A field may be owned only while a transfer is
in flight, marked so in the SVD source; SDHCI's are the only such fields.

**Every driver write takes the device lock.** `write/3` and
`write_field/4` take the device lock that every queue call holds, for
every register, owned field or not. So no driver write lands between a
check a queue call makes and the write that check guards, and the check
of an owned field reads the register under the same lock. The device
lock is held for one queue call or one register write and never across a
service call or a wait, so a register write waits at most for one queue
call; opens and bindings keep a lock of their own.

**Resets.** A software reset is a write like any other, and the rule
classifies it. A reset may return owned fields to their reset values and
stop a transfer. It stays the driver's when every act that makes the
device move data again passes a check the NIF makes, under the lock, that
reads back what the reset changed: then the reset cannot aim the device,
and a transfer it stops leaves its queue waiting for a completion that
does not come, until `negotiate/2`, whose own reset and idle report come
before any buffer is reused. A reset that can change an owned field of an
engine that keeps running across it is owned, since no check stands
between it and the engine's next access.

**virtio-mmio** keeps its list
([design-runtime.md](design-runtime.md#the-device-nif)): status, the
feature selectors and the driver's features, the queue selector, size,
ready bit and doorbell, and the rings' base addresses. Its reset is the
status, already owned.

**GENET** (offsets from FreeBSD's `if_genetreg.h:116-219`). Owned whole: every descriptor's three registers in
both directions; each of the 17 rings' registers in both directions
(producer and consumer index, buffer size and ring size, start and end
address, read and write pointer, and their high halves), from `0xC00`
past each direction's first descriptor and `0x40` apart, for the rings the NIF does
not use as for the one it does; and each direction's ring configuration
and DMA control, which enable rings and the engine. Not owned: DMA status,
burst size, the ring thresholds and timers, interrupt registers, the
receive and transmit buffer controls, the MAC and MDIO. The receive
buffer control's status block and alignment options move where a frame
lands inside a buffer, not how many bytes the engine writes, which the
ring's buffer size bounds; the board pass confirms that bound. GENET's
DMA engine runs between calls, so a reset that reached its ring or
descriptor registers would be owned; its own disable is the owned DMA
control. The UniMAC's software reset and the receive buffer and transmit
flushes (`if_genetreg.h:49-51, 75-77, 96`; FreeBSD's `gen_reset`,
`if_genet.c:457-480`) sit outside the DMA block. FreeBSD makes them
before it disables the engine (`if_genet.c:843-845`); Linux makes the
MAC reset with the engine running but the two flushes only after a
confirmed stop, and both drivers rewrite every ring register they use
afterwards, so neither depends on a reset or a flush leaving the DMA
block's registers alone, and no source says whether one does
([GENET facts record](research-genet-bcm2711.md#mac-reset-rx-buffer-flush-and-tx-flush),
[Reinstalling the rings](research-genet-bcm2711.md#reinstalling-the-rings)).
So GENET's DMA is enabled only once the board pass has read every owned
register back unchanged across each of them
([Concurrency](#concurrency)); where one changes, it is marked owned and
moves into `negotiate/2`'s reset, after its confirmed stop, where the
install that follows rewrites the ring's registers.

**SDHCI** (offsets from FreeBSD's `sys/dev/sdhci/sdhci.h:102-325`). Owned whole: `dma_address`
(`0x00`), `adma_address` (`0x58`) and `cmdtm` (`0x0C`), as now. Owned
fields: the DMA select of host control 1 (`control0`, bits 4:3), and the
ADMA2 length mode, host version 4 enable and 64-bit addressing of host
control 2 (`control2`, bits 26, 28 and 29 of the word), each of which
changes where or how the controller reads addresses or descriptors; and
the stop at block gap request and the continue request of block gap
control (`control0`, bits 16 and 17), since a stop makes the controller
raise transfer complete with the block gap event before the transfer
has ended, and a continue resumes DMA into the buffer afterwards (Host
Controller, section 1.13.3.3, p. 20; section 2.2.13, table 2-19,
pp. 65-66). The NIF never requests a stop, so the driver can neither
pause nor abort a DMA transfer except by a reset.
Owned while a DMA transfer is in flight: `blksizecnt` (`0x04`), whose
block size and count bound the bytes the controller moves; in
`interrupt`, the **end statuses**: transfer complete (bit 1), the block
gap event (bit 2) and the error statuses (bits 16 to 31), each cleared
by writing it 1 (section 2.2.18, p. 76; section 2.2.19, p. 82); and in
its status enable `irpt_mask`, the **required enables**: transfer
complete's (bit 1) and the error status enables of bits 16 to 25,
command timeout through ADMA error, each read and write in every
controller with ADMA2 (section 2.2.21, table 2-28, pp. 88-89). A status
reads 0 while its enable is clear (section 2.2.18, p. 76; section
2.2.19, p. 82), so a required enable cleared during a transfer would
hide its end. The block gap event needs no enable among them: it is set
only by a stop (section 2.2.18, bit 2), which the owned stop request
rules out. The two sets differ on purpose. Bit 15 of `interrupt`, the
error summary, is
read only and set whenever any error status is (section 2.2.18, p. 76),
while bit 15 of `irpt_mask` is fixed to 0 (section 2.2.20, table 2-27,
p. 86); and the error enables of bits 26 to 31, tuning, response and the
vendor's, depend on the controller's version and features, so the NIF
requires none of them, and an error they report still breaks the queue.
The form names the fields of each set; their bits come from the SVD
source's field definitions, as every register bit the NIF uses does.
The software resets in `control1` stay the driver's:
every DMA transfer starts at `command/2`, which reads back under the lock
every field it relies on, whatever a reset returned to its reset value,
and a reset that stops the transfer leaves the queue in flight until
`negotiate/2`. The reset of all returns the controller's settings to
their reset values: both FreeBSD and Linux set power, clock and the
interrupt enables again after it
([facts record](research-sdhci-bcm2711.md#reset); FreeBSD's
`sdhci.c:386-405`). Which other fields each reset clears no source read
here lists in full, and the design does not need it to.

## The three descriptor forms

Each form is a pure core beside `erx_device_queue` and returns
observations and decisions. `queue_create/4`, `post/4`, `post_frame/5`,
`complete/2` and `negotiate/2` keep their meaning and their answers for
every form; the record names the form its peripheral uses.

**The split ring (virtio).** As
[design-runtime.md](design-runtime.md#the-device-nif) describes. Its
descriptor table and available ring are one region, written by the CPU,
and its used ring another, written by the device and starting on a
granule. A post writes the buffer's `out` bytes, the descriptors and the
available entry, and publishes the available index and the doorbell; the
device may take the chain as soon as it sees the available index
(Virtio 1.2, section 2.7.13.3), and the publish barrier before that
index already covers it. A completion observes the used index, then the
used entries it covers, and copies each buffer's bytes up to the length
the device reported.

**The register ring (GENET).** A queue has no ring memory: its rings are
the device's registers, so its pool begins at the queue's first page.
Buffer *i* is descriptor *i*'s for the life of the queue, so the NIF
writes each descriptor's address once, at install, and never again. The
transmit queue is posted like any queue: `post_frame/5` takes the head the
transmit producer index names, copies the prefix and the frame into its
buffer, and publishes the descriptor's status, the length with start,
end and append-CRC fixed by the form, then the producer index. Its
completion observes the transmit consumer index once, which may advance
by at most the number in flight, and returns each tag with no bytes. The
receive queue is standing: install hands every buffer to the device, and
`complete/2` observes the receive producer index once, the low 16 bits
of its register, whose upper 16 count frames the controller discarded
([GENET facts record](research-genet-bcm2711.md#layout-of-a-dma-block)),
which may advance by at most the queue's size, then each new
descriptor's status once, whose length, bits 31:16, may be at most the
buffer size; it copies that many bytes, then hands the buffer back and
publishes the consumer index in the same call, whether or not the driver
will drop the frame, so an errored frame never holds the ring (FreeBSD's
error path does not advance its index, which the record notes as a
stall, [Where the drivers disagree](research-genet-bcm2711.md#where-the-drivers-disagree)).
The length counts everything the controller wrote into the buffer: the
64-byte status block when the driver enables it, the 2-byte alignment
pad when it enables that, and the 4-byte FCS only when the UniMAC's
command register forwards it (CRC forward, bit 6); the driver strips
each it enabled, and writes the command register with CRC forward clear
at its reset, as FreeBSD does, so no FCS is counted
([The receive status word](research-genet-bcm2711.md#the-receive-status-word)).
Each completion carries as its tag the low 16 bits of the descriptor's
status, its flags: start of packet (bit 13), end of packet (bit 14),
and the error bits, overflow (bit 0), CRC error (bit 1), receive error
(bit 2), a frame not a whole number of octets (bit 3) and a length error
(bit 4) (`if_genetreg.h:168-176`; the record, for bits 0, 1, 3 and 4,
whose meanings come from register-field names alone). The driver drops a
frame that lacks start or end of packet or has any of bits 0 to 4 set,
the wider of the two published drivers' rules, since FreeBSD tests only
bit 2 (`if_genet.c:1370-1381`). The status word is the descriptor's
status register when the status block is off (`if_genet.c:1362-1366`),
so the driver needs no status block to see the flags. A receive post is
`badarg`. An index or a length beyond its bound breaks
the queue, as a malformed used entry does.

**The ADMA2 table (SDHCI).** A queue of one buffer and one table, since a
controller moves one command's data at a time; the table's device
address is fixed for the life of the queue. `adma_address` is not: the
controller advances it at every entry it fetches, and the specification
has the table's start written at the beginning of each ADMA2 transfer
(Host Controller, section 2.2.31, table 2-42, p. 116), so every post
writes it. The controller is kept to the transfer it was given by
binding three quantities to one number, the posted extent: the table's
lengths, the controller's block size and count, and the bytes copied
back.

* `post/4` takes one segment, `{out, Binary}` for a write to the card or
  `{in, Length}` for a read, of a positive multiple of 512 bytes no larger
  than the buffer. Its decision writes the table for exactly that extent,
  one transfer entry with valid set per 32 KiB, the last one holding the
  rest and with end set, interrupt clear on every entry; each entry's
  address is the buffer's device address plus the entry's offset. 32 KiB
  is a multiple of the block size and of the 4-byte address unit, and
  lies below both readings of an entry's largest length (Host
  Controller, section 1.13.1.3 and table 1-12), so every entry's length
  and address are ones the specification defines and the lengths sum to
  the extent. A buffer of at most 1 MiB needs at most 32 entries, 256
  bytes of table. Its one register write is the publication of the
  table's device address to `adma_address`, which the sequencer places
  after the table's and the buffer's cleans and the publish barrier, so
  that a controller that initialises ADMA2 at that write, as the
  specification allows (section 1.13.3.2, implementation note, p. 20),
  finds the table in memory. Whether the BCM2711 fetches at that write,
  which would move the register before `command/2` reads it back, the
  board pass settles. The queue is then **armed**.
* `command/2`, while the queue is armed, issues only a word that enables
  DMA, sets block count enable and data present, has the posted
  direction, and selects multiple blocks exactly when the extent is more
  than one block; before writing it, it reads, under the lock, that the
  DMA select is ADMA2 with 32-bit descriptors, host control 2's owned
  fields and the stop and continue requests are clear, `adma_address`
  holds the table's device address, `blksizecnt` holds a block size of
  512 and the extent's count, every required enable is set, and every
  end status and the error summary read clear. Anything else is
  `badarg`. It writes the word and the queue is **in flight**. While the
  queue is armed or in flight `command/2` issues nothing else, so no
  other command uses the data lines, stops the transfer early or raises a
  completion that is not this transfer's.
* `complete/2` in flight reads `interrupt` once. Any end status but
  transfer complete, or the error summary, alone or with transfer
  complete, breaks the queue: errors win, as in FreeBSD's data interrupt
  handler (`sdhci.c:2244-2259`), the buffer stays posted, `interrupt` is
  left as it is for the driver to read and log, and the queue is
  `{error, broken}` until `negotiate/2`. A block gap event cannot arise,
  since no stop is ever requested; were one read, it would say the
  transfer had not ended, so it breaks the queue like an error rather
  than count as an end. Transfer complete alone takes the extent back,
  copies it for a read, clears transfer complete, returns the queue to
  idle and answers `{ok, [{Tag, Bytes}]}`, the bytes empty for a write.
  None of them: `{ok, []}`.

Transfer complete alone is taken to mean the controller moved the whole
extent. The specification supports it as far as it goes: every stop of
ADMA2 raises transfer complete (table 1-14, p. 20), a stop at a block
gap sets the block gap event with it (section 1.13.3.3, p. 20), which
the owned stop request rules out, and with block count enable set, a
table whose lengths differ from the block count times the block size is
an ADMA error, with the length
mismatch bit set (Host Controller, section 2.2.30, table 2-41, p. 115),
and `command/2` has checked that `blksizecnt` holds the extent's count
before the transfer starts, so the two cannot disagree unless the
controller misreads them. It does not say when a mismatch is detected
or whether transfer complete comes with it; errors win over transfer
complete in `complete/2` whichever way, and the board pass confirms on
the BCM2711 that a transfer whose table and block count disagree
reports the ADMA error before the form is enabled. Were it to end short
anyway, the bytes past what it wrote would be the zeros of rule 1, not
an earlier request's.

Each of these calls writes at most one register, so the driver's spacing
of writes on this controller
([design-storage.md](design-storage.md#the-sd-host-controller)) wraps
each call as it wraps `command/2`.

**Install and reset.** `negotiate/2` is, for every form, the form's reset,
the device's report that it holds no descriptor, then the install, and a
buffer goes back to its pool only through a completion or through it, as
[The reset rule](design-runtime.md#the-device-nif) says:

| Form | Reset the NIF writes | Idle report it reads | Install |
| --- | --- | --- | --- |
| split ring | status 0 | status reads 0 | virtio's initialisation, as now |
| register ring | each direction's DMA control with the engine (bit 0) and every ring's enable (bits 1 to 17) cleared in one write, transmit first (`if_genetreg.h:209-218`; FreeBSD's `gen_dma_disable`, `if_genet.c:563-577`; [GENET facts record](research-genet-bcm2711.md#stopping-the-dma-and-confirming-it-stopped)) | each direction's DMA status, block offset `0x1048`, reads bit 0 set, the block disabled, and bit *n* + 1 set for the ring *n* the form uses, bit 17 for FreeBSD's ring 16 ([The DMA status register](research-genet-bcm2711.md#the-dma-status-register)); the ring bit's meaning is inferred, and the board pass settles it | every descriptor's address; for the one ring the form uses, indexes zero, ring and buffer size, start, end and the four pointers, high halves 0; every receive buffer zeroed and handed; ring configuration and DMA control with the ring's enable; then each direction's engine bit, receive first ([Reinstalling the rings](research-genet-bcm2711.md#reinstalling-the-rings)) |
| ADMA2 table | the software reset for the data lines (FreeBSD's `sdhci.h:200-203`) | the reset bit reads clear | host control 2's owned fields checked clear, the DMA select written to ADMA2 with 32-bit descriptors; `adma_address` is written by each post |

Where the idle report does not yet show, `negotiate/2` returns
`{error, ebusy}` with nothing installed, having written the reset once,
and a later call reads the report again; the driver retries on a timer.
The GENET facts record gives the one published bound on confirming a
stop, 5,000 reads 1 us apart, about 5 ms
([Stopping the DMA](research-genet-bcm2711.md#stopping-the-dma-and-confirming-it-stopped));
the driver's retries are bounded by a multiple of it, after which it
reports the device failed, and the board pass measures how long a stop
takes. The
ADMA2 table's `negotiate/2` makes at most one register write per call
and answers `{error, ebusy}` until its last, so it takes two calls at
least, each spaced. A driver that resets the controller itself calls
`negotiate/2` before its next DMA transfer; until then `command/2`
refuses, since it reads back the fields the reset cleared.

## The architecture layer

Generic code names cache maintenance and barriers only: `erx_dma_clean`
and `erx_dma_clean_inval`, each over an address range and a step, which
issue one instruction at each multiple of the step from the range's start;
the sequencer gives every range with the step `L`, so the choice of step
is made once, in the pure core its host tests cover; the publish barrier, the report
barrier and the completion barrier; and `erx_dma_granule` and
`erx_dma_line`. Each architecture provides them in its layer
([design-arch-aarch64.md](design-arch-aarch64.md#cache-maintenance)); the
hosted build provides the model below. Only `erx_device` calls them in a
runtime, the chokepoint the device NIF already has.

## Concurrency

The device lock serialises every queue call and every driver register
write, so a decision's effects run whole, with no other decision's and
no driver write between them, and every check a call makes under the
lock still holds when the write it guards is made. Maintenance by address
reaches every cache of the CPUs that share the memory, so one CPU's
maintenance suffices whichever CPUs fetched the lines.

**Moving between CPUs.** The barrier that completes maintenance
completes the maintenance that the CPU executing it issued (Arm 102336,
section 6, p.14), so a thread moved
to another CPU between its maintenance and its barrier needs something
else to complete it. On erXos's kernel, every exit from user mode
completes every outstanding access
([design-arch-aarch64.md](design-arch-aarch64.md#asynchronous-errors)),
which completes the maintenance before the thread runs elsewhere. Fiasco
does not: its exception entry has no such barrier
(`fiasco/kernel/src/kern/arm/64/ivt.S`), and its switch path orders with
`DMB ISH` at most (`fiasco/kernel/src/lib/libk/arm/mem-arm.cpp:209-231`).
On the stopgap the condition that makes this safe is instead that no
thread is moved while it makes a device call, and it holds by
construction:

* Fiasco moves a thread only when user mode asks it to, through
  `l4_scheduler_run_thread` (`fiasco/kernel/src/kern/scheduler.cpp:94-114`),
  and the backend asks for a started thread only in
  `erx_thread_set_affinity` (`liberx/backend/fiasco/service.c:780-806`);
* device calls run only on normal schedulers: the NIF's functions are not
  dirty (`erx_device_nif.c:521-532`), and the register calls are BIFs;
* each normal scheduler is pinned to one CPU
  ([design-runtime.md](design-runtime.md#scheduling)), and is moved only
  by its own binding, which ERTS makes from that scheduler's own loop,
  between process runs (`erl_process.c:9762`;
  `erl_cpu_topology.c:500-510`), through `sched_setaffinity(0, ...)`
  (`erl_misc_utils.c:87-88`), which names the calling thread
  (`musl/src/internal/erxos/syscall.c:262-264`).

The one way to break it would be a call that moves a normal scheduler
from another thread, which no code in the runtime makes. Non-coherent
DMA on the stopgap is enabled under that condition, and the board pass
that enables GENET's DMA confirms the reset reads of
[Register ownership](#register-ownership) first.

## Failure behaviour and refusals

Nothing after a decision's check can fail, as today. The answers each call
adds:

| Call | Answer | When |
| --- | --- | --- |
| `queue_create/4` | `{error, erange}` | a device address of the queue would reach the form's width, or the queue passes the object's end |
| `region/3` | `{error, enotsup}` | the device is not coherent |
| `post/4` | `badarg` | a receive post on a standing queue; for ADMA2 not exactly one segment, or a length that is not a positive multiple of 512 or is larger than the buffer |
| `post/4` | `{error, full}` | an ADMA2 queue already armed or in flight |
| `command/2` | `badarg` | while an ADMA2 queue is armed or in flight, any word but the armed transfer's, or that word when any field it reads back differs from what the queue installed and posted; a word enabling DMA without an armed queue |
| `complete/2` | `{ok, []}` | nothing is done yet |
| `complete/2`, `post/4` | `{error, broken}` | the device reported an index or a length beyond its bound, or an ADMA2 transfer reported an error, until `negotiate/2` |
| `negotiate/2` | `{error, ebusy}` | the device's idle report does not show yet, or, for ADMA2, the install has writes left |
| `write/3`, `write_field/4` | `badarg` | a write that would change an owned field |
| the root at boot | gives the device no DMA memory, with a line naming it | the tree gives the device no single window that RAM backs, marks coherence on a bus above it or both ways on its node, or its DMA memory would lie outside the range |

## Verification

Each test is paired with the seeded fault that shows the code under test
ran.

* **The order.** Host tests of `erx_device_dma_order` over decisions and
  observations of each form, coherent and not, with `L` smaller than `G`:
  every zeroing before the writes, every clean before the publish
  barrier, the barrier before the first publish, every maintenance
  instruction at every line of its region, the report barrier, of the
  kind that orders loads and stores, before every taking back, and every
  taking back and its barrier before every copy; for a coherent device no
  maintenance and the same barriers. Seeds: a publish moved before the
  clean; the report barrier dropped; the report barrier made loads-only;
  the maintenance stepped by `G`; each fails its assertion.
* **The non-coherent stand-in.** The hosted stand-in device keeps its DMA
  memory twice, a cache of lines of `L` bytes with dirty bits and the
  memory behind it, and a writeback evicts a whole granule of `G` bytes,
  as a CPU may. The CPU's stores go to the cache; the stand-in device
  reads and writes only the memory; the model's clean writes a dirty line
  back, its clean and invalidate also drops it; and, from a seeded random
  source, it evicts dirty granules and refetches clean lines at arbitrary
  points. The stand-in device may act after any publish, the available
  index as well as the doorbell, as virtio allows. Every form's host
  tests run over it, with `L` equal to `G` and with `L` a quarter of `G`:
  posted bytes reach the device intact, and completed bytes are the
  device's. Seeds: the clean removed, so the device reads stale bytes;
  the taking back removed, so a refetched stale line is copied; the
  buffer stride left unrounded, so an eviction of a neighbour overwrites
  what the device wrote; the maintenance stepped by `G` with `L` smaller,
  so a line inside a granule is missed; the sequencer's derivation of the
  buffers passing to the device removed, so a posted buffer is never
  cleaned; the descriptor table's clean moved after the available index,
  so the stand-in takes a stale chain; each fails a byte comparison.
* **The install.** Over the stand-in, a split-ring queue whose used ring
  holds dirty lines of a former record's values when `negotiate/2` runs,
  so the install's zeroing leaves its own dirty lines: the stand-in
  device writes a completion into the used ring after the ready bit,
  the model evicts and the completion is observed, and the entry read is
  the device's, on every eviction schedule the seeded source draws. Seed:
  the sequencer's handover of a region whose writer changes from the CPU
  to the device restricted to buffers, so the zeroed used ring is never
  cleaned and the observation's clean and invalidate, or an eviction,
  writes zeros over the device's entry, which the completion misses.
* **Zeroing.** Over the stand-in, a device that writes a prefix and
  reports the buffer's whole length: the completion's bytes past the
  prefix are zero, on a buffer that held another request's bytes. Seed:
  the zeroing removed, and the earlier request's bytes appear.
* **The check.** `erx_device_dma_check` refuses a region off a granule, a
  region outside the record's memory, a write into a buffer the device
  holds, a publish of a register the driver owns that is not the form's
  publication, a copy of a buffer not coming back, a state change the call
  does not allow and an address past the width; it accepts the address of
  a region of the record. Seed: the granule test removed, and a core
  planted to emit an unaligned region passes it.
* **Ownership and the lock.** Over the stand-in: `write/3` of a GENET
  descriptor address and of `control0` with another DMA select is
  `badarg`; of `control0` with another bus width, `ok`; of `control0`
  setting the stop at block gap request or the continue request,
  `badarg` in every state; of `interrupt` clearing transfer complete or
  an error, of `irpt_mask` clearing a required enable, or of
  `blksizecnt`, while an ADMA2 transfer is in flight, `badarg`, and once
  it completes, `ok`; of `irpt_mask` clearing the tuning error's enable
  in flight, `ok`. A
  host test runs a driver thread writing the reset of all to a stand-in
  SDHCI, which returns every register to zero, against
  `command/2` on another thread: `command/2` either issues with every
  field as installed or refuses, and the stand-in never sees a DMA
  command with the DMA select or the ADMA address cleared. Seeds: the DMA
  select's mark set to not owned in the SVD source, and the field check
  removed, each lets the DMA select write succeed; the lock removed from
  `write/3`, or the read-back of the DMA select removed from `command/2`,
  and the stand-in records a DMA transfer through address 0.
* **The ADMA2 table's states.** Idle, armed and in flight form a protocol
  state machine, tested exhaustively: every call in every state, with
  transfer complete, the block gap event and an error status each set
  and clear, against the answers above. Over the stand-in, whose device
  writes the buffer some steps after the command and advances
  `adma_address` by 8 at every entry it fetches: `complete/2` straight
  after `command/2` is `{ok, []}`, and the buffer is not reused; a
  transfer that reports an error with transfer complete, or the block
  gap event with it, breaks the queue and returns no bytes; a
  `blksizecnt` that differs from the extent makes `command/2` `badarg`;
  two transfers in a row, each posted, commanded and completed, both
  move their bytes, and the stand-in reads each table from its start.
  Seeds: the transfer complete test removed from `complete/2`, and the
  stand-in's late write lands in the next transfer's buffer, which a byte
  comparison catches; the error test placed after the transfer complete
  test, and the erroneous transfer's bytes are returned; the block gap
  event left out of the end statuses, and a stand-in that stops at a
  block gap halfway has half a transfer returned as whole; the post's
  write of `adma_address` removed, and the second `command/2` is
  `badarg`; the required enables taken as bits 15 to 31, and on a
  stand-in whose `irpt_mask` bit 15 reads 0, as the specification fixes
  it, every `command/2` is `badarg`.
* **GENET's receive flags.** Over the stand-in, a frame whose status
  carries a CRC error, and one without end of packet: the completion's
  tag carries the flag, the consumer index advances past both, and the
  driver drops the frame. Seeds: the tag forced to 0, and the driver's
  frame test passes the bad frame; the drop test narrowed to bit 2, as
  FreeBSD's, and the CRC-error frame is delivered.
* **GENET's stop.** Over the stand-in, whose DMA status sets its bits
  some reads after the stop: `negotiate/2` answers `{error, ebusy}` until
  both directions show bit 0 and the ring's bit, and installs nothing
  before. Seed: the idle test reads only the receive direction, and the
  stand-in's transmit engine is still running when the install writes
  its ring.
* **The forms' completions.** The fuzz target of device ring processing
  covers the register ring's and the ADMA2 table's observations and
  decisions: arbitrary index, status and interrupt values against
  arbitrary queue states, under ASan. Seed: the length bound removed, and
  the copy reads past a buffer.
* **The record.** The reader's host tests over each platform's
  build-time tree pin every DMA device's coherence and range and fail on
  a device whose facts are absent, so a board tree that marks coherence
  on a bus above a DMA device fails there, before any boot; a fixture with
  `dma-coherent` on the parent bus gives the device the status
  `coherence`. The QEMU suite's seeded tree shows a record's coherence
  following the live tree
  ([design-device-tree.md](design-device-tree.md#verification)). Seed:
  the reader takes the coherence of the nearest marked ancestor, and the
  fixture's device reads as coherent.
* **The reach.** A host test of the root's device step over a pool
  placed outside a device's range makes no object and gives the record no
  memory, with the line. Seed: the range test removed, and the object is
  made.
* **On QEMU.** QEMU's DMA is coherent, so no omitted maintenance can fail
  there; the QEMU suites check the coherent path, the zeroing and that
  the barriers changed nothing.
* **On the board.** Before GENET's DMA is enabled, the questions the
  GENET facts record leaves to the board
  ([What only the board can settle](research-genet-bcm2711.md#what-only-the-board-can-settle)):
  every owned GENET register read back unchanged across the UniMAC's
  software reset and each flush; each direction's DMA status read with
  the engine and the ring enabled and disabled, which settles whether
  bit *n* + 1 reports ring *n* disabled; how long a stop takes to
  confirm; and received lengths with CRC forward clear, which show that
  no FCS is counted. Then GENET's traffic, with every frame checked end to end,
  at one CPU and at four, for every Pi 4 board pass; ADMA2 reads and
  writes, each block checked, two transfers in a row among them, which
  shows that `adma_address` still holds the table's start between a post
  and its command, and a transfer whose table and block count
  disagree reporting an ADMA error, at the range the board's firmware
  wrote, which the root's line for EMMC2 records.

## Performance

A 2 KiB buffer is 32 lines of 64 bytes, the line the Pi 4's CPU reports,
and is zeroed where no `out` bytes fill it and cleaned at a post, and
cleaned and invalidated at a completion. Every driver register write
takes the device lock. These costs are on the watch list
([todo-performance.md](todo-performance.md)), measured on the board by
`tools/erx bench` against the same traffic with the maintenance and the
zeroing skipped.

## Alternatives considered

* **Non-cacheable mappings for DMA memory**, as FreeBSD uses for coherent
  allocations on a non-coherent tag (`busdma_bounce.c:533-541`). It needs a memory attribute the
  kernel does not have, since it fixes the attributes at boot to normal
  write-back and two device attributes
  ([design-kernel.md](design-kernel.md#dma-and-the-iommu)), and the NIF's
  copies in and out of uncached memory are slow; the handoff rules need
  neither.
* **Maintenance or handoffs written into each form.** Each form would have
  to remember its handoffs, cleans, invalidates and barriers; deriving
  them from the queue's change of state makes that list empty.
* **Invalidate before the device writes**, besides after, as FreeBSD
  does (`busdma_bounce.c:1059-1071`). A clean suffices, since the CPU
  stores nothing into the region afterwards and the clean and invalidate
  after the transfer discards any stale line; and user mode cannot
  invalidate alone.
* **Trusting each device's reported length instead of zeroing.** virtio
  promises at least the reported length written (section 2.7.8.2), GENET's
  status counts the frame it wrote, and ADMA2 ends at the bound extent;
  but the argument would rest on every form's device keeping its promise
  in every error case, which virtio itself says a device may not know.
  Zeroing makes the property hold whatever the device reports, for a
  cost the watch list measures. It does not stop a malicious device,
  which can read the pool it holds and return anything.
* **The NIF owning the software resets.** Not needed where a check reads
  back what the reset changed before the device moves data again, as
  SDHCI's `command/2` does: every driver write is serialised with the
  NIF's sequences, and a stopped transfer only stalls its queue until
  `negotiate/2`.
* **A reset after every ADMA2 transfer** instead of owning `blksizecnt`,
  the end statuses and the required enables while a transfer is in
  flight. It costs a reset and a spaced write per command, and the
  in-flight fields already keep the driver from hiding or shortening the
  transfer's end.

## Open decisions

1. **The granule when the CPU does not report one.** Recommendation:
   2 KiB rather than the line size FreeBSD aligns to; it costs memory
   only. That 2 KiB
   is the architecture's largest writeback granule is unverified here:
   the Arm Architecture Reference Manual's description of the cache type register's `CWG`
   was not read, and the Cortex-A72 manual gives only its own value; it
   is confirmed before the fallback is built. The line has no such case:
   `DminLine` is always reported.

## References

* Linux 6.18's device trees (`deps.lock`, `linux-dts`):
  `arch/arm/boot/dts/broadcom/bcm2711.dtsi` and `bcm2711-rpi.dtsi`, read
  as data.
* FreeBSD 14.1.0 (`release/14.1.0`): `sys/arm64/broadcom/genet/if_genet.c`
  (SHA-256 `5408c2fb...`) and `if_genetreg.h` (`5af53d30...`), the source
  of the GENET driver's design; `sys/dev/sdhci/sdhci.c` (`7c4b440c...`)
  and `sdhci.h` (`363ed505...`); `sys/arm64/arm64/busdma_bounce.c`
  (`1f01f90c...`), `cpufunc_asm.S` (`42ea4027...`) and `identcpu.c`
  (`3c533813...`); `sys/arm64/include/atomic.h` (`604acc09...`).
* The clean-room facts records of the BCM2711's SD controller,
  [research-sdhci-bcm2711.md](research-sdhci-bcm2711.md), and of its
  Ethernet controller, [research-genet-bcm2711.md](research-genet-bcm2711.md).
* SD Association, SD Host Controller Simplified Specification, version
  4.20: sections 1.13.1.3, 1.13.2, 1.13.3.1 to 1.13.3.3, 2.2.11,
  2.2.13, 2.2.18 to 2.2.21, 2.2.25, 2.2.30 and 2.2.31, for ADMA2 and the
  registers the NIF owns (SHA-256 of the PDF read,
  `e430d1d149696580274f876d1cc0624bc9b9dffc4e5a62cd76f1f658f3e6667d`).
* QEMU 11.1.3's `virt` tree, written by `-machine virt,dumpdtb=`.
* Devicetree Specification, release v0.4, sections 2.3.5 and 2.3.8 to
  2.3.11.
* OASIS Virtio 1.2, Committee Specification 01: sections 2.7.8, 2.7.8.2
  and 2.7.13.3.
* Arm, *Learn the architecture: Memory Systems, Ordering, and Barriers*,
  102336 version 1.0, sections 5 and 6; Arm Cortex-A72 MPCore Processor
  Technical Reference Manual, r0p3, 100095_0003_06, section 4.3.26.
* The Arm Architecture Reference Manual: the cache type register, cache
  maintenance by address, the barriers, and the ordering of cache
  maintenance by address against loads and stores.
