# The firmware's device tree in the root task

The boot firmware hands the kernel a device tree, and on the Raspberry
Pi 4 it edits that tree before it does: it rewrites the SD controller's
DMA range according to the SoC's revision, it reports the RAM it leaves
to the operating system, and it may add the Ethernet controller's
hardware address and a node for the framebuffer it set up. A record
written at build time cannot hold a value only the firmware knows. This
document says how the system domain's `liberx`, the root task, receives
the tree the firmware handed over, how one bounded reader reads it, and
how the values it reads reach the device records the root writes
([design-stopgap.md](design-stopgap.md#device-records)), on the stopgap
Fiasco and on erXos's kernel alike.

Decisions every reader needs:

* **The manifest holds what the build proves; the live tree, the one the
  firmware handed over at this boot, supplies the rest.** A device's manifest row says which device it is, where its
  registers and line are, who holds it and how much DMA memory it gets,
  and for the firmware's framebuffer the window it must lie in,
  because the manifest check reasons about those. How the device sees
  memory, whether it is cache-coherent, its hardware address and the
  framebuffer's geometry are facts the firmware owns. They are read at
  boot from the tree the firmware handed over and go straight into the
  device's records; no build-time record carries a copy of them, so no
  boot ever compares a copy with the tree.
* **One reader, built from one source.** `erx_dt`
  (`kernel/core/dt.c`), a pure C17 function over the tree's bytes, built
  for the host, reads the tree in the root task on both kernels, and its
  DMA walk is the one erXos's kernel allocates DMA memory by.
  It walks the tree through `libfdt` with every check on, recurses
  nowhere and allocates nothing, and has a fuzz target.
* **The tree reaches the root as a read-only copy at a known place.** On
  the stopgap, `bootstrap` packs a copy of the tree into pages of its own,
  which `sigma0` pages to the root read-only, and the boot handoff record
  names their range. On erXos's kernel, the root holds a read-only object
  of the tree at a well-known slot. `liberx`'s `erx_boot_tree` returns the
  tree's bytes on both, so nothing above it knows which kernel runs.
* **An absent value withholds exactly what is made from it.** A value the
  tree lacks, or that fails its check, is absent, never guessed. A device
  whose DMA range is absent gets no DMA memory; a network device whose
  hardware address is absent gets none in its record, and its driver
  falls back as FreeBSD's does; a framebuffer row whose node is absent
  gets no record. Each absence prints one line naming the device and the
  reason. A tree that fails the reader's acceptance stops the boot, as it
  stops erXos's kernel.

## Context

**What the firmware edits.** Linux 6.18's tree for the BCM2711, which
the build fetches (`deps.lock`, `linux-dts`, SHA-256
`9106a4605da9e31ff17659d958782b815f9591ab308d03b0ee21aad6c7dced4b`),
puts the SD controller, EMMC2, on a bus of its own whose `dma-ranges`
map bus address `0xC0000000` to the first GiB of RAM; the comment above
it says the firmware rewrites that property according to the SoC's
revision when the tree defines the `emmc2bus` alias
(`bcm2711.dtsi:411-424`), which the board's tree does
(`bcm2711-rpi.dtsi:14`). The value the firmware writes for each revision
is unverified here. The board's Ethernet node has no address property
(`bcm2711-rpi-4-b.dts:198-202`), and the board's tree defines the
`ethernet0` alias (`bcm2711-rpi.dtsi:15`); whether the firmware adds
`local-mac-address` through that alias is unverified. No tree under
Linux 6.18's `arch/arm/boot/dts/broadcom/` has a `simple-framebuffer`
node, so a framebuffer node can come only from the firmware, and whether
it adds one is unverified. The firmware also rewrites the memory node
([design-platforms.md](design-platforms.md#bring-up-under-qemu)).

**The bindings.** A `simple-framebuffer` node is a child of `/chosen`
named `framebuffer@<address>`, with `reg`, `width`, `height`, `stride`
in bytes and `format`, one of eleven names (Linux 6.18's
`Documentation/devicetree/bindings/display/simple-framebuffer.yaml:18-20,
68-118`); a `memory-region` property, if present, overrides `reg`
(`:71-74`). FreeBSD's GENET driver takes the hardware address from the
node's `mac-address`, then `local-mac-address`, then `address`; failing
those, from the controller's address registers when the receive buffer
is out of reset; failing that, it generates one (FreeBSD `975e3605ebb1`,
`sys/arm64/broadcom/genet/if_genet.c:353-354, 446-485`, SHA-256
`fbf5c90dd089fa759e04dd0c72f97e688bfc97e2855d65011cf42d4511cfd459`).
The Devicetree Specification v0.4 defines `dma-coherent` and
`dma-noncoherent` as properties of a device, each meaningful on an
architecture whose default is the other (sections 2.3.10 and 2.3.11,
p. 17), and `dma-ranges` as a bus's map from its own addresses to its
parent's (section 2.3.9, p. 16); it does not say what a bus without
`dma-ranges` means.

**QEMU `virt`.** QEMU 11.1.3's `virt-11.1` machine, dumped with
`dumpdtb=` on 2026-11-12 on the primary host, writes a tree whose header
declares 1 MiB (`totalsize` `0x100000`) and whose header, structure and
strings end at byte 7,847, marks 35 nodes `dma-coherent`, each of its 32
virtio-mmio transports among them, and puts 32 bytes of `rng-seed` in
`/chosen`.

**What the code does today.** `bootstrap` holds the tree
(`fiasco/bootstrap/server/src/erx_image.cc:257-260`, refusing a boot
without one) and copies `/chosen`'s `bootargs`, the node `stdout-path`
names and the boot pair into the boot handoff record (`:304-316`;
`abi/kernel.txt:736-752`), which the root reads from a page `sigma0`
pages to it read-only (`erx_image.cc:228-245`). Upstream `bootstrap`
also reserves the tree's bytes as a root region with no access sub-type
(`dt.cc:264-287`) and writes its address into the kernel information
page's `dt_addr` (`platform_dt-arm.h:67-70`, called from
`platform/arm_virt.cc:53` and `platform/arm_gen.cc:53`). `sigma0` answers
a page fault in a root region only with the rights its sub-type grants
(`l4re-core/sigma0/server/src/init_mem.cc:71-80`, `memmap.cc:158-180`,
`mem_man.cc:266-277`), so the root can reach those bytes only through
`sigma0`'s RAM request, which maps them writable and executable
(`memmap.cc:124-128`), and
nothing in the root does: the entropy generator's comment says Fiasco
gives the root no device tree (`liberx/backend/fiasco/entropy.c:14-18`).
The root's device records take every value from the manifest row, and
no Pi 4 device has DMA memory in the code.

The tree carries two copies of `libfdt`, each file under
`GPL-2.0-or-later OR BSD-2-Clause` (`fiasco/libfdt/ORIGIN.md`;
[design.md](design.md#dependencies) records it as permanent, under
BSD-2-Clause). The copy `bootstrap` builds,
`fiasco/libfdt/lib/contrib`, keeps every check
(`libfdt_internal.h:84-85`, `FDT_ASSUME_MASK` 0) and includes
`fdt_check.c`, whose `fdt_check_full` walks the whole structure once,
with a loop and a depth counter. The Fiasco kernel's copy,
`fiasco/kernel/src/lib/libfdt`, defaults to `ASSUME_VALID_DTB |
ASSUME_VALID_INPUT` (`libfdt_internal.h:82-83`), under which, its own
comment says, malicious or truncated trees may make it behave badly or
crash (`:116-129`).

**What erXos's kernel already reads.** Its early pass reads `/memory`,
`/reserved-memory` and `/chosen`, and its full pass the devices it
drives and every other device node's registers and lines, which become
the root resource's entries
([design-kernel.md](design-kernel.md#boot), steps 2 and 5);
`erx_dma_ranges` gives a device's DMA ranges as a pure function of the
tree ([design-kernel.md](design-kernel.md#dma-and-the-iommu)); and the
device service reads the root resource's entries through
`erx_object_info` ([design-system.md](design-system.md#devices)). No
route gives the root a property the kernel does not put in an entry: a
hardware address or a framebuffer's geometry.

## The construction: facts the firmware owns are read where it left them

The root reads the tree once, at boot, before it makes any device object.
For each manifest device row it asks the reader for the facts that row
needs, and the reader answers each fact with a value or with an absence
and its reason. The answers join the row's entry in the device catalogue
([design-system.md](design-system.md#devices)), and every record and
object made for the device
afterwards is computed from that entry. Nothing else reads the tree, and
nothing reads a fact anywhere but in the entry.

Three pieces make it:

1. **The copy** (below, [How the tree reaches the root](#how-the-tree-reaches-the-root)):
   read-only, page-aligned, packed, its range validated with the rest of
   the boot handoff.
2. **The reader** ([The reader](#the-reader)): accepts the tree whole, then
   answers per device: the DMA facts, the hardware address, and, for a
   framebuffer row, the framebuffer's facts.
3. **The records** ([Facts into records](#facts-into-records)): the
   `given` record's coherence and memory, its hardware address, and the
   framebuffer record, each made only from present facts.

**What disappears.** Each problem below is a case the construction cannot
reach, not one it handles:

| Problem | Why it cannot happen |
| --- | --- |
| a range written at build time is wrong on a board of another revision | no build-time record holds a range; the range is the tree's, read on the board that boots |
| the record and the tree disagree | there is one copy of each fact, the tree's |
| the board and QEMU's `raspi4b` model see memory differently | each boots its own tree, so each record describes the machine it runs on |
| erXos's kernel allocates DMA memory from one range and the root records another | both compute the range with `erx_dma_ranges` over the same bytes |
| a missing value is filled with a default | absence is a result of its own, and only present values make records |
| a string from the tree reaches the console | the lines name the manifest's path and fixed words and numbers; a format name is taken from the reader's own table |

## How the tree reaches the root

### On the stopgap

`erx_image_load` makes the copy after the load plan is made and before
anything it places moves, then writes the handoff page (`erx_image.cc`,
step 4 of [Boot handoff](design-stopgap.md#boot-handoff)):

1. take the room the load plan chose for it: the tree's `totalsize` in
   whole pages, clear of every place the plan gives and of the archive
   where the loader left it;
2. copy the tree there with `libfdt`'s `fdt_open_into`, delete `/chosen`'s
   `linux,initrd-start` and `linux,initrd-end`, which name where the
   loader left the two-file form's archive and so, once the archive
   moves, an image or free RAM, and shrink it with `fdt_pack`, so the
   copy holds the memory reservation block, the structure and the
   strings and no free space: a few pages on QEMU `virt`, whose own tree
   declares 1 MiB;
3. reserve the copy's whole pages as a root region named `.erxtree` with
   the read-only sub-type, as the handoff page is reserved, and clean
   them to memory;
4. write the copy's start and length into the handoff record.

A failure of any step, or a packed tree longer than
`ERX_BOOT_TREE_MAX`, refuses the boot with
`erXos image: device tree: <reason>`, as every refusal of the load plan
does. `ERX_BOOT_TREE_MAX` is 1 MiB, a limit of `abi/kernel.txt`, many
times the packed tree of either platform.

The handoff record gains two fields after its last, `tree_start` and
`tree_size`, each a `u64`, so the record grows from 2,408 to 2,424 bytes;
`erx_boot_handoff_accept` refuses, with the reason `tree_range`, a start
that is not page-aligned, a length of 0 or above `ERX_BOOT_TREE_MAX`, or a
range whose end overflows. The view it returns carries the range. In its
step 2 the root reads the copy's pages through page faults, as it reads
the handoff page, so it maps them read-only and never writes them.

The kernel information page's `dt_addr` and the `.dtb` region are not
used: they would give the root the firmware's own bytes, at an alignment
the firmware chose, mapped writable through the RAM request, with a
length only the tree's own header gives.

### On erXos's kernel

The kernel already keeps the tree's pages out of its allocator, rounded
outward ([design-kernel.md](design-kernel.md#boot), step 4). At the root
task's start it makes a read-only memory object over those pages and
installs it at the root slot `device_tree`, of a kind of its own with the
rights `read`, `map` and `inspect` and neither `dup` nor `give`, so the
tree stays in the trusted base; the machine page gives the tree's offset
in the object's first page and its length, `tree_offset` and
`tree_size`. The object is charged to no budget, since its pages were
never the allocator's. Before it makes the object, the kernel overwrites
`/chosen`'s `rng-seed` and `kaslr-seed` in place with zeros, so the bytes
that seeded its generator are in no space.

### The seam

`erx_boot_tree(&bytes, &size)` in `liberx`'s backend interface returns
the tree's bytes, read-only. The Fiasco backend returns the handoff
view's range; erXos's kernel's backend maps the `device_tree` object and
returns the range the machine page names; the hosted backend returns
`ERX_ENOTSUP`, since a hosted runtime has no devices and its entry adds no
device record ([design-stopgap.md](design-stopgap.md#device-records)).
Everything above the seam, the reader, the catalogue and the records, is
the same code on every backend.

## The reader

`erx_dt` lives in `kernel/core/dt.c`, with its view and facts in
`include/erx/core/dt.h`. It is a pure function over bytes: it reads no
global state, allocates nothing, recurses nowhere, and builds for the
host, where its tests and fuzz target run. It reaches the tree only
through `libfdt` from `fiasco/libfdt/lib/contrib`, compiled with
`-DFDT_ASSUME_MASK=0`, so no copy's default decides which checks run.
erXos's kernel links the same file, and its `erx_dma_ranges` is the
reader's DMA walk. On the stopgap the root task links it in user mode and
the kernel's core archive leaves it out (`CoreArchive::ROOT_TASK_SOURCES`),
since Fiasco reads no tree of erXos's and links its own `libfdt`. Besides
`fdt.c`, `fdt_ro.c`, `fdt_check.c` and `fdt_addresses.c`, the reader links
`fdt_rw.c` and `fdt_wip.c` only because `fdt_addresses.c` holds a writer;
it writes nothing. Outside the stopgap's own `fiasco/` tree, only
`kernel/core/dt.c` and erXos's kernel's `kernel/platform/fdt.c` include
`libfdt.h`; a build check fails on any other includer.

**Acceptance.** `erx_dt_accept(bytes, size, &tree)` returns `NULL` and a
view, or a fixed reason:

* `structure`: `size` is shorter than the version 17 header, 40 bytes,
  or `fdt_check_full(bytes, size)` fails. The length test comes first
  because `fdt_check_header` reads the strings block's size, which a
  version 2 header lacks, whatever the version (`fdt.c:139-142`).
  `fdt_check_full` is the first call, and the only one that sees bytes
  not yet accepted: it refuses a
  `size` shorter than the oldest header before reading the header's
  version, one shorter than that version's header before reading the
  rest, and a `totalsize` above `size` before walking the structure
  (`fdt_check.c:24-32`), so no field of an unchecked header is read past
  the buffer or taken as its length. `fdt_check_header`, which takes no
  length (`fdt.c:89`), is never called on its own;
  `kernel/core/dt.c` refuses to build without `FDT_ASSUME_MASK` 0;
* `depth`: a node lies deeper than `ERX_DT_DEPTH_MAX`, 16 levels, found
  in one pass of `fdt_next_node`;
* `memory`: the memory nodes give more than `ERX_DT_MEMORY_MAX`, 16,
  ranges, or a range whose end overflows.

The view holds the bytes, their length and the memory ranges, taken from
every child of the root whose `device_type` is `memory` and whose `status`
is absent or `okay`, its `reg` read with the root's cell counts, which
must be 1 or 2, in whole entries; an entry of length 0 adds no
range, since a board's tree leaves the memory node as zeros for the
firmware to fill. Each later call takes the
view, so no call reads a tree that was not accepted.

**Cells and addresses.** A `reg` entry is read with the cell counts of
its node's parent; a `dma-ranges` entry's bus address and length with
those of the node that holds it and its parent address with its parent's
address count (Devicetree Specification v0.4, sections 2.3.5 and 2.3.9,
pp. 14 and 16). Counts come from `fdt_address_cells` and
`fdt_size_cells`, whose defaults are 2 and 1 (`fdt_addresses.c:34-55`),
as the specification's are.
A count other than 1 or 2, read for a non-empty `dma-ranges`, gives the
DMA facts the status `cells`, and read for a framebuffer's `reg`, the
framebuffer `malformed`, so every address and length read fits 64 bits,
and every sum is checked for overflow. A PCI host
bridge's `dma-ranges` are among them: its child addresses take three
cells, whose meaning the specification leaves to the PCI bus binding
(section 2.4.4, p. 22), which no source read for this design gives, so
an unconfined PCIe function whose walk crosses such a level gets no DMA
range. No device the manifests give DMA memory is one.

**Walking up.** A walk from a node to the root takes the node's path from
the root in one pass of `fdt_next_node` from the tree's start, keeping the
node at each depth in an array of `ERX_DT_DEPTH_MAX + 1` entries, so a
node's ancestors cost one pass and not one pass of `fdt_parent_offset`
(`fdt_ro.c:625-681`) each. At each level the
walk carries at most `ERX_DT_WINDOWS_MAX`, 16, windows, and a level whose
translation would leave more gives the status `ranges`: 1,024 child
entries that all map onto one parent range, under a level that splits
that range 1,024 ways, would otherwise make a million windows from two
thousand entries. A level's work is then at most the windows carried
times its entries, and no path through the reader is longer than the
tree's length times `ERX_DT_DEPTH_MAX` and `ERX_DT_WINDOWS_MAX`; the
input's depth drives no recursion.

**The DMA facts.** `erx_dt_device(tree, path, row, &facts)` finds the
device's node and its bus; `row` says whether the path names a device's
own node or a PCIe function's host bridge. For a device-tree row the node is the one at
the row's path and the bus is that node's parent. A PCIe function has
no node of its own; its host bridge's node stands as its node for the
coherence marks and is itself its bus, so the walk's first level is the
host bridge's own `dma-ranges`, as
[design-kernel.md](design-kernel.md#dma-and-the-iommu) has it. It fills:

* `coherent`: set when the node itself has `dma-coherent`; the
  specification defines the mark for a device, with an empty value
  (section 2.3.10, p. 17), and on AArch64 a device without it is not
  coherent. A mark with a value is `malformed`. A node with both marks,
  or a node above it with a mark the node does not carry itself, gives
  the status `coherence`, since no reading of a mark on a bus is the
  specification's; a mark above that repeats the node's own changes the
  answer under no reading, and QEMU `virt` 11.1 marks its root
  `dma-coherent` above every device that carries the mark itself
  ([design-device-dma.md](design-device-dma.md#device-addresses-and-reach));
* the DMA range, `cpu`, `bus` and `last`, the device's translation, by
  the walk of `erx_dma_ranges`
  ([design-kernel.md](design-kernel.md#dma-and-the-iommu)). The walk
  starts with one window, every bus address mapped to the same CPU
  address, and goes from the bus up to the root: each non-empty
  `dma-ranges` translates the windows, and the parts no entry covers
  drop out; an empty one passes them; a level without the property
  passes them only when no level above it has a non-empty one and is
  `malformed` otherwise. The root has no parent to map into, so a
  non-empty `dma-ranges` on the root is `malformed`. Then each window over which no memory range of
  the view lies drops out, and the windows left are kept whole, not cut
  to RAM. A walk with no non-empty level leaves the one window, `0`, `0`
  and `2^64 - 1`. The range is present only when exactly one window
  remains. Which RAM inside it holds DMA memory is decided where the
  memory is made ([Facts into records](#facts-into-records)), not here.

Its status is `ok`, `no_node`, `coherence` (as above), `cells` (a cell
count other than 1 or 2), `malformed` (an entry not a whole number of
cells, a coherence mark with a value, an overflow, a level without
`dma-ranges` below a non-empty one) or `ranges` (more than
`ERX_DT_WINDOWS_MAX` windows at a level, or no window, or more than one,
that RAM backs). A row naming the root as a device's node has no bus and
is `malformed`; a path that is not absolute, or names no node, is
`no_node`. Any status but `ok` makes both DMA facts absent, so a
device never has a range without its coherence.

**What the reader cannot check.** The reader checks the tree's encoding
and that what it reads fits together; it cannot check that the hardware
does what the tree says. A well-formed tree that states a wrong
translation aims the device outside its memory, and a wrong
`dma-coherent` suppresses maintenance the device needs. The tree is the
firmware's, which every machine trusts as its own
([design.md](design.md#residual-risks), "Closed firmware"), so such a
tree is the firmware's fault, as a wrong memory node would be, and is
believed. What the reader promises is narrower: no tree, however
malformed, makes it read outside the bytes, loop without bound, or
produce a fact it did not check, and a tree it can see is wrong
withholds the facts made from it.

**The hardware address.** In the same call, the first of `mac-address`,
`local-mac-address` and `address`, in FreeBSD's order, that holds exactly
six bytes, not all zero and with the group bit of the first byte clear,
gives the address. A property that fails those tests is passed over, so a
placeholder of zeros counts as absent. Its status is `ok` or `none`.

**The framebuffer.** `erx_dt_framebuffer(tree, path, compatible, window,
&fb)` looks among the children of the row's path, `/chosen`, for nodes whose
`compatible` list holds the row's compatible string,
`simple-framebuffer`, and whose `status` is absent or `okay`. Exactly one
must match: none gives `none`, two or more `ambiguous`. The one node must
have one `reg` entry, `width`, `height` and `stride` of one cell each and
nonzero, and a `format` that is one of the binding's eleven names, which
the reader maps to its own table of names and bits per pixel. It checks
that `stride` is at least `width` times the pixel's bytes and that
`stride` times `height` fits in the `reg` length. Then it checks
authority: the `reg` range, rounded out to whole pages, since whole
pages are what the root maps, must lie inside the row's **window**, the
`base` and `size` of the manifest row, and outside every memory range of
the view, since the firmware keeps the framebuffer out of the RAM it
reports ([design-stopgap.md](design-stopgap.md#the-raspberry-pi-4)); a
range that fails is `outside`. Being outside RAM alone would admit a
register window the manifest does not list, firmware memory, or a
device the kernel keeps; the window is a range the build has checked,
so the tree chooses where in it the framebuffer lies and never which
memory the display domain can write. A node with `memory-region` is `unsupported`; any
other failure is `malformed`. On `ok` it returns the base, the length of
`reg`, the width, height, stride and the format's index in its table;
on `outside` it returns the base and length too, for the line.

Every answer is a value of the facts structure, never a pointer into the
tree, so nothing downstream holds the tree's bytes.

## Facts into records

**When.** The root reads the tree in its step 4, after it has read the
system manifest and before it builds the pool
([Boot handoff](design-stopgap.md#boot-handoff)): it accepts the tree,
then asks the reader for each manifest device row's facts and stores them
in the row's catalogue entry. A refused tree stops the boot with its
reason, as the other failures of steps 1 to 6 do. On erXos's kernel the
root-task entry does the same before the device service starts.

**What each row asks.** A row with DMA memory asks for the DMA facts; a
row of the `network` role also for the hardware address; a row of the
`framebuffer` role, a value `mf_device_role` gains, for the framebuffer's
facts. Other rows ask nothing, and their records take every value from
the row.

The decision of what a row's entry yields, which objects to make and
which record to write from its facts, the pool's range and the row, is a
pure function in `liberx/backend/core/`, beside `erx_boot_device_window`,
so its host tests reach every absence without a boot.

**The `given` record.** Its `COHERENT` is the entry's `coherent` when the
entry admits DMA memory, and 0 for a row that gets none, so no record calls
a device coherent that has no range to use; and it
gains a last number, `MAC`, the hardware address as a 48-bit decimal, 0
when absent or when the row asks for none:
`-erx given ROLE PERIPHERAL PATH WINDOW_H OFFSET SIZE LINE_H MARK MEM_H
MEM_SIZE CLOCK COHERENT MAC`, PATH the row's device-tree path
([design-stopgap.md](design-stopgap.md#device-records)). `erx_device_record:find/3` reads it, refusing a `MAC`
above `2^48 - 1`, and returns it as `mac => Address` for a nonzero value;
the record sizes of `include/erx/boot_words.h` grow by its longest form.
The device's contiguous object is made only when the entry's DMA range is
present, and only if its pages lie inside that range; the object records
`bus - cpu` for `erx_mem_dma_addr`
([design-device-dma.md](design-device-dma.md#device-addresses-and-reach)).
Without a range, or with the pool outside it, the record has `MEM_H` and
`MEM_SIZE` 0: the SD controller's driver then moves blocks by programmed
I/O, and the GENET driver, which can move packets only by DMA, refuses to
start, with a line naming its record.

**The hardware address in the driver.** A GENET driver whose record has
an address uses it; one without follows FreeBSD's order from the
controller's registers on, which is the driver's design, not the root's:
the root never reads a device's registers.

**The framebuffer record.** A `framebuffer` row names `/chosen` as its
path and `simple-framebuffer` as its compatible string, with no DMA and
no line; its `base` and `size` are the window the framebuffer must lie
in, page-aligned, from the checked platform record as every row's are,
and the manifest check refuses a framebuffer window that overlaps
another row's register window. On the Pi 4 the window is the memory the
firmware keeps for the VideoCore out of the RAM it reports; where that
lies is unverified, and the board pass's `outside` line, which prints
where the firmware put the framebuffer, settles it. An empty window
admits no framebuffer. When its facts are present, the
root makes a physical memory object over the framebuffer's pages and,
for the row's holder, the record
`-erx framebuffer WINDOW_H OFFSET SIZE WIDTH HEIGHT STRIDE FORMAT`, where
`OFFSET` places the framebuffer in its first page and `FORMAT` is the
format's name from the reader's table.
The record's form and the display driver that reads it belong to
[design-display.md](design-display.md); this design fixes only the values
it carries and where they come from.

**The lines.** For each row that asked, the root prints one line through
its console writer: `erx: device tree: PATH: coherent C range CPU BUS
LAST` or `dma absent REASON`, `mac present` or `mac absent`, and
`framebuffer WIDTHxHEIGHT STRIDE FORMAT`, `framebuffer absent outside
BASE SIZE` or `framebuffer absent REASON`, with addresses in hexadecimal
and the rest in decimal.
`PATH` is the manifest's, the numbers are the root's, and the reasons and
the format's name come from fixed tables, so no byte of the tree reaches
the console and the lines need no escaping. A board pass reads the
firmware's edits from them.

## Concurrency and failure

The reader runs once, on the root's first thread, before any other
thread exists ([Boot handoff](design-stopgap.md#boot-handoff), "Only the
first thread exists until step 7"). The entries it fills are not written
again, and the copy's pages are read-only and never unmapped, so later
readers on other threads read values that no longer change.

| Event | Detected by | Result | Seen as |
| --- | --- | --- | --- |
| the packed tree does not fit, or a copy step fails | `bootstrap` | the boot stops | `erXos image: device tree: <reason>` |
| the handoff's tree range is malformed | `erx_boot_handoff_accept` | the boot stops | the reason `tree_range` |
| the tree fails acceptance | `erx_dt_accept` | the boot stops | its reason on the console |
| a DMA device's facts are absent (no node, a coherence mark on a bus or both marks, a cell count other than 1 or 2, a malformed range, too many windows, or not exactly one window that RAM backs), or the pool lies outside its range | the root | the device gets no DMA memory | one line naming the device and the reason |
| a network device's address is absent | the root | its record has `MAC` 0 | `mac absent` |
| a framebuffer node is absent, ambiguous, malformed or unsupported | the root | no framebuffer record | `framebuffer absent REASON` |
| a framebuffer's pages leave its row's window or meet the RAM the tree reports | the root | no framebuffer record | `framebuffer absent outside BASE SIZE` |
| no tree on the hosted backend | `erx_boot_tree` | `ERX_ENOTSUP`; no records are made | nothing |

## Verification

Each test is paired with the seeded fault that shows the code under test
ran.

* **The platforms' trees.** Host tests of the reader over the tree QEMU
  `virt` writes for each suite machine, dumped as
  `ProductionImage#check_device_paths` dumps it, and over the Pi 4's card
  tree and the model's tree that `tools/lib/erx/board_tree.rb` builds,
  with each device's expected facts pinned in the test: every virtio-mmio
  transport coherent with the range `0`, `0`, `2^64 - 1` of a walk with
  no non-empty level; GENET not coherent, the same range, no address;
  EMMC2 not coherent, range `0`, `0xC0000000`, `0x3FFFFFFF`. Those are
  the model's tree's facts: the card's tree leaves the memory node as
  zeros, so no window has RAM behind it and every DMA device there is
  `ranges` until the firmware fills the node.
  A test fails on any manifest DMA device whose facts are absent in its
  platform's tree, so a board tree the reader refuses fails at build
  time. Fixtures: `dma-coherent` on the parent bus, and both marks on a
  node, each give `coherence`; `dma-coherent = <0>` gives `malformed`; a
  bus without `dma-ranges` between the device and a non-empty level
  gives `malformed`; a device with no non-empty level over two separate
  memory ranges gives the one window `0`, `0`, `2^64 - 1`; a PCI host
  bridge whose `dma-ranges` take three cells gives its function `cells`;
  a PCIe function under a host bridge with two-cell `dma-ranges` is
  translated by them; 1,024 child entries onto one parent range under a
  level that splits it 1,024 ways gives `ranges`. Seeds: the reader
  takes the nearest marked ancestor's coherence, and the parent-bus
  fixture reads as coherent; the marks tested for presence only, and
  `dma-coherent = <0>` reads as coherent; the translation through the
  level above the first non-empty one dropped, which a fixture with two
  nested `dma-ranges` catches; the windows cut to RAM, and the two-range
  fixture gives `ranges`; a PCIe function's walk started above its host
  bridge, and its fixture is not translated; the windows' bound removed,
  and the splitting fixture overruns the walk's array under ASan.
* **The firmware's edits.** Fixture trees made from the card's tree: one
  whose `emmc2bus` range differs, one with `local-mac-address`, one with a
  zero placeholder and a valid `mac-address`, and framebuffer nodes in
  each state the reader names. Seeds: the RAM filter removed, so a
  fixture window over no RAM is present; the group-bit test removed, so a
  multicast address is accepted; the stride test removed, so a stride
  shorter than a row passes; each fails its test.
* **The fuzz target**, `test/fuzz/dt_fuzz.c`, landing with the reader:
  arbitrary bytes into `erx_dt_accept`, and an accepted view into
  `erx_dt_device` for fixed paths and `erx_dt_framebuffer`, under ASan and
  UBSan, with the platforms' trees, the fixtures and a truncated and a
  nested tree as its corpus, each handed over in a buffer of exactly its
  length. Seeds: acceptance that calls `fdt_check_header` before
  `fdt_check_full`, and a corpus entry shorter than a header reads past
  the buffer; acceptance that passes the header's `totalsize` to
  `fdt_check_full` instead of `size`, and the truncated entry reads past
  it; the reader built with the Fiasco kernel copy's assumption mask,
  and the truncated entry crashes it.
* **The handoff.** `boot_handoff_fuzz.c` covers the two new fields; a host
  test refuses an unaligned start, a zero length and an overflowing end
  with `tree_range`. Seed: the alignment test removed, and the unaligned
  case is accepted.
* **The chokepoint.** The build check of `libfdt.h`'s includers fails on a
  seeded third includer in `liberx`.
* **The records' decision.** Host tests of the root's pure device step:
  a range present with the pool inside makes the object and records
  `bus - cpu`; a range absent, and a pool outside the range, make no
  object and give the record `MEM_SIZE` 0 with the line; an absent
  address gives `MAC` 0. Seed: the inside test removed, and the object
  is made over a pool outside the range.
* **The framebuffer's authority.** Reader tests over fixture nodes: a
  framebuffer inside its row's window is `ok`; one whose `reg` ends
  inside the window but whose last page crosses its end, one over a
  register window outside it, one inside RAM the tree reports, and any
  framebuffer with an empty window are `outside`, with the base and
  length for the line. Seeds: the window test made over the unrounded
  `reg` range, and the crossing fixture is `ok`; the window test removed,
  and the register-window fixture is `ok`.
* **The live tree on QEMU.** The `net_device` suite
  (`tools/lib/erx/net_device.rb`) boots twice. Its stock cell takes the
  tree QEMU writes and expects the network device's line to say
  `coherent 1 range 0x0 0x0 0xffffffffffffffff`, the network domain's
  record for it to carry `coherent => true`, and its traffic to pass.
  The paired boot, its `-noncoherent` cell, takes a seeded tree, QEMU's own
  dumped through `ProductionImage.seeded_tree` with `dma-coherent`
  removed from the network transport's node and from the root, whose
  mark would otherwise stand above a node without its own and give that
  node the status `coherence`; every other device keeps its own mark,
  which the root's only repeated. That device's line says
  `coherent 0`, the network domain's record for it carries
  `coherent => false`, read there with `erx_device_record:find/2`, so
  its queues issue the cache maintenance in user mode, and its traffic
  still passes, since maintenance changes nothing on QEMU's coherent
  DMA. The line prints the tree's
  facts while the record carries `erx_boot_coherent`'s value, so the
  suite checks both. Seed: a root that takes coherence from the
  manifest row, after which the seeded boot's record still carries
  `coherent => true` and the test fails.
* **On the board.** Every Pi 4 board pass records the lines, which settle
  what this design leaves unverified: EMMC2's range on the board's
  revision, whether the firmware supplies GENET's address, and whether it
  adds a framebuffer node; then ADMA2 reads and writes of the card, each
  block checked
  ([design-device-dma.md](design-device-dma.md#verification)), and GENET's
  traffic with the address the record gives.

## Performance

The reader makes one acceptance pass and, per asking row, a walk of at
most 16 levels, each a loop over the tree; the Pi 4's card tree is
39,650 bytes. The copy costs a few pages and one pass over the tree in
`bootstrap`. Neither is on a path that runs after boot, and no number is
claimed for either.

## Alternatives considered

* **Keep a build-time copy of each fact and check it at boot.** The
  manifest would carry coherence and the range, and the root would refuse
  a device whose tree disagrees. The firmware's rewrite of EMMC2's range
  is such a disagreement by design, so the check would refuse DMA on
  exactly the boards whose range the build could not know, and on every
  other device the copy would only repeat the tree. Reading the tree
  alone removes the copy and the comparison.
* **Map the firmware's own tree through `dt_addr`.** Rejected above: an
  alignment the firmware chooses, a writable mapping, and a Fiasco
  structure read above the handoff.
* **Have `bootstrap` extract the values into the handoff record.** It
  would put a second reader in `bootstrap`, which erXos's kernel does not
  have, and the record would grow with each value a driver needs.
* **Extend the root resource's entries on erXos's kernel** with coherence
  and range. It covers DMA, but a hardware address and a framebuffer are
  not the kernel's to interpret, so the root would need the tree anyway;
  one tree object serves all three.
* **Ask the firmware's mailbox** for the framebuffer and the address. The
  mailbox stays out of every driver's reach
  ([design-platforms.md](design-platforms.md#alternatives-considered),
  "Driving more of the boards' firmware").

## Open decisions

1. **No framebuffer node on the board.** If the firmware adds none, the
   display has no framebuffer record. Recommendation: settle it on the
   first board pass before designing anything further, and if the node
   is absent, bring the question back with what the pass showed; a static
   row from the mode `config.txt` asks for would be a guess at where the
   firmware put the framebuffer and how it laid it out.
2. **`rng-seed` on the stopgap.** The root now holds `/chosen`, where QEMU
   `virt` puts 32 bytes of seed. Recommendation: seed the root's
   generator from it when present, which turns the entropy line's
   "from the counter alone" into a named source on QEMU at the cost of one
   more fact.
3. **The tree object on erXos's kernel**, a new root slot and two machine
   page fields, against extending the root resource's entries.
   Recommendation: the object, for the reason under Alternatives.
4. **The host link's `erx.hostlink=1`.** The word exists because the
   stopgap's root cannot see whether the machine has the host link's UART
   ([design-stopgap.md](design-stopgap.md#the-command-line)); with the tree
   in hand it can, as erXos's kernel does. Recommendation: give the host
   link's record exactly when the tree has an enabled node at the
   manifest's `hostlink` path, and delete the word and the harness's
   pairing of it with the second serial port.
5. **No manifest copy of coherence and the DMA range.** The manifest's
   device record carries neither: no coherent flag bit and no
   `dma_cpu`, `dma_bus` and `dma_last`
   ([design-abi.md](design-abi.md#devices-and-partition-windows)), and
   the build checks the facts only through the reader's host tests over
   each platform's tree. The alternative keeps the three fields and flag
   bit 1 in the record, filled from the platform record and checked at
   build time against the platform's tree as `base`, `size` and `line`
   are, and the root then gives DMA memory only where the live tree
   agrees with the row. Recommendation: no copy, for the reason under
   Alternatives: on EMMC2 the firmware's rewrite would make the copy
   disagree by design. Choosing the copy changes only the device
   record's table and its DMA paragraph in design-abi.md, the platform
   record that fills them, and one comparison in the root's pure device
   step; the reader and every record made from its facts stay as they
   are.

## References

* Linux 6.18 (`deps.lock`, `linux-dts`): `arch/arm/boot/dts/broadcom/bcm2711.dtsi`,
  `bcm2711-rpi.dtsi`, `bcm2711-rpi-4-b.dts`; and, from the same release
  tarball, the binding `Documentation/devicetree/bindings/display/simple-framebuffer.yaml`
  (SHA-256 `26362c2194b7fe49df96c22d0e7d786c280fc4aa8bbafafff4f468c20468a9db`).
* Devicetree Specification, release v0.4
  (`https://github.com/devicetree-org/devicetree-specification/releases/download/v0.4/devicetree-specification-v0.4.pdf`,
  SHA-256 `c141dd78af0971fffed19433f84af5beab6aa058cfff2e33076805cef9f92e02`),
  sections 2.3.5 and 2.3.8 to 2.3.11.
* FreeBSD `975e3605ebb1`, `sys/arm64/broadcom/genet/if_genet.c`.
* `libfdt` `5756062b` (`fiasco/libfdt`, `fiasco/kernel/src/lib/libfdt`).
* L4Re `bootstrap` and `sigma0`, as imported under `fiasco/`.
* QEMU 11.1.3's `virt-11.1` tree, written by `-machine virt-11.1,dumpdtb=`.
