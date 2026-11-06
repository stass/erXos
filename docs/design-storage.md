# Storage and system updates

Storage in erXos is a few services in Erlang domains of their own, above
the block driver, an Erlang process over the device NIF, and reached
through facets like every other service: read-only releases in EROFS
images, checked block by block where they are consumed; read-write files
on the data partition, in erXos's F2FS, with littlefs as the stopgap
behind the same interface; FAT partitions for removable media and for
exchanging files with other machines; and system updates written to the
spare of two slots and committed only after a healthy trial boot. This
document is the medium's layout and formats, the block driver, the storage
services, and the update path. The key idea is that every rule rests on
facts a party reads for itself: a domain reaches only the partition
windows it was granted, a block is trusted only after its hash checks in
the domain that uses it, and the slot writer derives what it may write
from the medium's record and the boot value the kernel reports, never from
anything a service tells it. Every file system and the driver are Erlang,
so every open file, every window and the driver itself are processes that
can be inspected, traced, supervised and upgraded live, and a parsing bug
in a file system or in the driver crashes a supervised process instead of
corrupting memory; the work done once per byte, hashing and checksums,
runs in a few C primitives of the runtime.
The architecture is in [design.md](design.md); the kernel's machine page,
lease and trial end in [design-kernel.md](design-kernel.md); the device
service and the driver table in [design-system.md](design-system.md#devices);
the device NIF in [design-runtime.md](design-runtime.md#the-device-nif);
the file protocol the storage services speak in
[design-files.md](design-files.md); the primitives in
[design-runtime.md](design-runtime.md#per-byte-primitives).

Decisions every reader of this document needs:

* **Partitions are windows.** A domain reaches only the sectors of the
  windows granted to it, and each file system runs in a domain that holds
  a window on its own partition and nothing of the medium beyond it.
* **One format per job.** The boot image holds what booting needs, EROFS
  images hold the rest of a release, read-only and hash-checked where
  consumed, the data partition holds what changes, and FAT holds what is
  exchanged with other machines.
* **File systems and the driver are Erlang.** By the user's decision, the
  block driver, the EROFS reader, erXos's F2FS, the FAT server and the
  slot writer are Erlang; the driver touches its device through the
  device NIF, and hashing and checksums are C primitives
  ([design.md](design.md#decisions)). littlefs, the stopgap, is C in a
  sub-space port of the storage domain.
* **The block driver lives where the configuration puts the device.** In
  the default configuration the block device belongs to the storage
  domain and the driver runs there; on a board whose storage controller
  is unconfined, the release configuration gives the device a domain of
  its own ([design-system.md](design-system.md#devices)). The driver's
  windows, seen from their clients, are the **block service**: a client
  reaches a window by the window's pid, local or exported, so the storage
  service and every other client have one code path in both
  configurations.
* **F2FS from a clean room.** erXos implements F2FS, in Erlang, from a
  specification written in its own words, with Linux as the oracle and a
  legal review before any distribution, by the user's decision; littlefs
  is the stopgap.
* **A/B slots with trials, and the record is the whole state.** An update
  goes to the spare slot, boots once as a trial that writes nothing but
  the boot-selection record, and is committed only from that trial, when
  healthy; whether the spare is complete is checked against its manifest,
  never recorded (U1 to U5).
* **No conversion.** By the user's decisions nothing erXos stores is
  converted: the data partition and the vault's partition, which littlefs
  serves until erXos's F2FS, are created afresh by the installation that
  brings erXos's F2FS, and an update never changes a partition's format.

## Context

A machine needs a read-only system that a fault cannot corrupt, files that
survive power cuts, updates that never leave it unbootable, and a way to
move files to and from other machines, and every byte a medium returns is
untrusted input. Storage sits on the block driver and the device service,
which gives the block device to one domain and names which domain holds
which partition's window ([design-system.md](design-system.md#devices));
on the kernel, which reports the boot value in the machine page and takes
a lease over a trial
([design-kernel.md](design-kernel.md#console-log-and-panic)); on the
runtime's file layer, whose EROFS reader is preloaded in every runtime
([design-runtime.md](design-runtime.md#files)); on the runtime's per-byte
primitives ([design-runtime.md](design-runtime.md#per-byte-primitives))
and the device NIF
([design-runtime.md](design-runtime.md#the-device-nif)); and on the file
protocol, 9P2000.L, whose operations the storage services implement
through `erx_fs` ([design-files.md](design-files.md)). The user decided
that system code is Erlang wherever that costs too little performance to
matter, drivers included, with C for the per-byte primitives and the
device shim beneath a driver ([design.md](design.md#decisions)). The
choices rest on the research into file systems and boot selection
([research](research-boards-storage.md#file-systems)), and
[plan.md](plan.md#m6-immutable-code-lasting-data) and
[plan.md](plan.md#m12-storage-networking-boards) schedule them.

## Requirements

* **ST-R1.** Read-only releases verified where they are consumed, so no
  storage domain or driver is trusted with their integrity.
* **ST-R2.** Durable read-write files per principal, with quotas, that
  survive a power cut at any write.
* **ST-R3.** Updates that never leave the machine unbootable: whatever
  ends an update or a trial, the machine boots a complete system.
* **ST-R4.** A crafted medium or file system image damages at most its
  own partition and the domain that parses it.
* **ST-R5.** Reproducible images: the same inputs give the same slot
  image, byte for byte.
* **ST-R6.** FAT partitions served as files, for removable media and for
  exchanging files with other machines, under the same confinement as
  every other file system.

Non-goals: converting a data partition or the vault's partition, in
place or by an update, since an installation creates them afresh;
compressed EROFS images
unless the media lack room; Linux's file-system code or erofs-utils' code
in the tree; exFAT; booting or updating from anything a domain parses as
FAT.

## Overview

```text
  medium:  [ record ][ slot A: boot image + EROFS ][ slot B ][ vault ][ data ]
                |              |                                 |       |
           slot writer    window per EROFS image            a storage domain
           (Erlang; the   -> EROFS reader (Erlang)          for each, in
            only writer      in each domain, on blocks      Erlang: the vault's
            of slots and     the hash-checking reader       serves the vault
            the record)      checked against the tree)      alone; both run
                ^                                           erXos's F2FS,
                |                                           littlefs as stopgap
           update service (system domain), trial and commit

  block driver (Erlang, over the device NIF, in the storage domain by
  default): one window process per partition and client; a window's pid
  is local to the storage service and exported to every other client

  removable medium or exchange partition:  [ FAT ] -> FAT server (Erlang)
```

The block driver serves each partition as a window. The firmware boots the
slot the record names, or the spare once as a trial. Each domain whose
release lives in an EROFS image reads that image through its own window
and checks every block. Principals' files live in the storage domain over
the data partition. The vault's sealed key files and the machine keys
live on the vault's partition, served by a storage domain of its own
whose only client is the vault, so no principal's request reaches them;
it runs the same release as the data partition's
([design-system.md](design-system.md#the-vault)). A FAT partition is
served by a FAT server in a domain of its own. The update service writes
an update into the spare through the slot writer, requests a trial, and
commits by rewriting the record only once the trial is healthy.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **PW1.** A file system reaches the medium only through a window on its own partition, and no window but the slot writer's covers a slot or the record | a window is a process of the block driver that checks every request against the sectors the device service named for it; the device service derives windows from the medium layout of the ABI file and the system configuration's roles, and names slot and record windows for the slot writer alone; a file system holds a window's pid and nothing of the device, since only the block driver's modules call the device NIF, a build check; native code that parses a file system runs in a sub-space holding only its channel, so it reaches no window and no device | a window named by sectors from anything but the layout; a parser that calls the device NIF or holds another window; native file-system code in the driver's domain | a host test of the device service's derivation: no domain but a storage domain or the slot writer receives a window on a data, FAT, vault's or slot partition, each receives one partition's, and only the storage domain that serves the vault receives the vault's ([design.md](design.md#chokepoint-checks)); the build check that only the block driver's modules reference `erx_device`, with a seeded violation; a test that every other request for those windows fails |
| **E1.** A domain parses only EROFS blocks that passed its image's hash tree | the EROFS reader receives an image's bytes only from the hash-checking reader, `erx_verity`, the only module that holds an EROFS window's pid: it receives each block as a binary in the domain's own memory, checks it against the image's tree with the SHA-256 primitive, whose root comes from the boot image, and returns the binary only if it matches | a read path around the hash-checking reader; a check on a copy the driver still holds rather than the domain's | a cross-reference check that no module but `erx_verity` sends to an EROFS window and that the reader's modules reach an image only through `erx_verity:read/3`; a test with a flipped bit in each block |
| **U1.** The slot the machine runs from, and the slot a failed trial falls back to, are never written | the slot writer allows a slot write only on `normal(C)` with the record naming `C`, and only to the other slot | a slot write allowed on any other boot value, or from a service's word | the exhaustive model of the update path |
| **U2.** The record names only the slot first installed or a slot that passed a healthy trial | the slot writer rewrites the record only on `trial(S)` with the record naming the other slot, naming `S`, and the update service asks for that only once the trial is healthy; no other boot value, a firmware's fallback boot included, allows a record write | a record write on a normal boot | the exhaustive model, with every boot value against every record |
| **U3.** After a power cut, a crash or a hang at any point, the machine boots the committed slot, or the spare once as a requested trial | the record changes only by one sector, the trial's request is one-shot, and a hang during a trial ends in the watchdog's reset; the firmware runs the watchdog from power-on on a board configured as [design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record) describes, and on a board without that configuration a trial whose firmware stage hangs, before the kernel's first decision, needs a power cycle | a multi-sector record; a request that survives the trial | the model with a power cut after every write; runs on each board |
| **U4.** A trial boot writes nothing but the record and the reset count | the block driver's one write function refuses every write but the record window's and the reset count's while the boot value is `trial(_)`, reading the boot value from the machine page through its runtime | a second write path in the driver | the build check over the storage domain's BEAM files, with the compiler's call graph, that the device NIF's post is reached only from the driver's write path, which builds every request it posts ([design.md](design.md#chokepoint-checks)), with a seeded violation; a QEMU test of every client's writes on a trial boot |
| **U5.** Only a complete spare is ever tried | the update service asks for a trial only after the spare has passed the check against the update manifest in its manifest window, which runs at each normal boot and after each write and records nothing; the manifest is written last, so a spare whose write was cut short has no manifest that matches it | a recorded "complete" state; a trial requested from a service's word | the model with a power cut after every write of the spare; a QEMU test that cuts a spare's write short and finds no trial requested |

U1 to U5 hold on a medium that writes a sector atomically and honours a
flush, as an SD card does not promise
([design.md](design.md#residual-risks)), and none depends on anything the
update service remembers: each follows from the record, the boot value
and the spare's bytes, which a party reads for itself.

## Data model

**The block driver.** The driver is an Erlang application under a
supervisor in the domain that holds the block device: a **device
process**, which owns the controller's rings through the device NIF,
posts descriptors from a pool of DMA buffers the domain holds, receives
completions and interrupts as messages, and acknowledges them
([design-runtime.md](design-runtime.md#the-device-nif)); a **partition
process**, which reads and parses the partition table with binary
matching and checked bounds, fuzzed on the host; and one **window
process** per window. A window receives `{read, Sector, Count}`,
`{write, Sector, Bytes}` and `flush` from its one client, checks each
against its sectors, and hands it to the device process, which completes
it with the bytes the device NIF copied out of the pool into a fresh
binary at completion, so no binary aliases memory the controller can
still write; a reply to a client in another domain crosses that client's
lane as a frame.
The device NIF parses nothing a device wrote: the Erlang processes do,
with binary matching in supervised processes, so a malicious controller
corrupts no memory. All of the driver's writes to the medium go through
one function, the driver's **write path**, which applies the trial rule
(U4). The NIF posts reads and writes alike, and what makes a request a
write is the type in its header, so the write path holds by construction:
one module, `erx_blk_write`, posts every request the driver makes, it
builds each one's header itself, and only its write function builds a
type that writes. A build check over the storage domain's BEAM files,
with the compiler's call graph, fails on any call of `erx_device:post/4`
reached other than from `erx_blk_write`, however the call names its
module, with a seeded violation that it catches.

**The block service.** The window processes are the driver's face to
every client, and together they are the block service: one window per
client and partition, or per client and EROFS image, each a grant whose
pid the system domain hands the client when it introduces the two domains
([design-system.md](design-system.md#creating-a-domain)), or which the
storage domain's own file system holds as a local pid. A read's blocks
travel to a client in another domain in the window's reply frame on the
client's connection, as a file server's reply does: the client's runtime
copies the frame out of its lane once, into its own memory, and the
storage domain supplies no memory beyond the lane the client's budget
paid for ([design-domains.md](design-domains.md#connections)). A client
in the driver's own domain receives the NIF's binary itself, with no copy
beyond the NIF's one. A window answers one request at a time per client in
order, so a client's own requests in flight bound what the service holds
for it, and a client that stops reading its lane blocks only its own
window.

**Where the driver runs.** The device service gives the block device to
exactly one domain, named by the system configuration
([design-system.md](design-system.md#devices)): by default the storage
domain that serves the data partition, so the common case costs no connection;
on a board whose storage controller's DMA is unconfined, a domain of its
own, so the domain that parses a hostile data partition never holds a
device whose DMA reaches the whole machine. In both the driver is the same
application and a window is the same process; what differs is whether a
client's window pid is local or exported over a connection the system domain
created when it introduced the client's domain to the driver's
([design-domains.md](design-domains.md#connections)). The storage service, the
EROFS reader, the FAT server and the slot writer each send to a pid and
do not care which.

**Partitions are windows.** A client reaches only the sectors of the
windows the device service named for it, and the window checks every
request against them. The device service names the windows from the
medium layout of the ABI file and the system configuration's roles when
it gives the device, and again for each domain it introduces to the
driver's; the driver starts a window process for each and the pid reaches
the client as any grant does. Each file system runs in a domain that holds
a window on its own partition and nothing of the device, so a crafted file
system can damage only its own partition, and no domain that parses a file
system can write a slot or the boot-selection record of [System
updates](#system-updates) (PW1).

**The boot medium's table.** It is a master boot record laid out by the
medium layout of the ABI file:

| Entry | Partition | Read by |
| --- | --- | --- |
| 1 | the boot-selection record's partition | the firmware and the slot writer |
| 2, 3 | slot A, slot B | the firmware, and the slot writer, which alone writes them |
| 4 | an extended partition holding the two logical partitions below, each described by an extended boot record at a sector the layout fixes | the block driver, which reads exactly those two records |
| 4, first logical | the vault's partition | the vault's storage domain alone |
| 4, second logical | the data partition, last on the medium | the principals' storage domain |

The driver admits the table before it serves any window: it must equal
the layout entry for entry, but for the data partition's length, or the
driver serves none of it and reports the medium. It follows no chain of
extended boot records beyond the two, so no crafted table leads it
anywhere the layout does not name. That one length, and the extended
partition's with it, may be anything from the layout's minimum to the
medium's end, so one image fits media of every size and its installer may
give the data partition the whole rest of the medium.

**Removable media** have no fixed layout: the driver serves only primary
entries that lie within the medium and overlap no other entry it serves,
so no crafted table makes two windows share a sector.

**One source.** Where each partition lies, and each slot's signature
window (below), comes from the medium layout of the ABI file alone, which
the kernel, the packer, the QEMU harness and the device service share: the
device service derives the slot writer's windows from it, and the system
configuration assigns data, FAT and the vault's partitions to storage
domains by their role in it, never by sectors.

**What each format holds.** Three formats on the boot medium, and FAT for
exchange:

* The **boot image** (`ERXPACK`) holds everything the machine needs to
  boot: the kernel, the runtime images, the system release and the
  releases of the domains started at boot. The firmware loads it whole,
  and only the kernel parses it.
* **EROFS images** hold the read-only rest. Each release installed with
  the system that no boot needs lives in an image of its own, after the
  boot image in the slot. A domain whose release lives there starts from a
  small release in the boot image, holds a read-only window on that
  image's sectors alone, its hash tree included, and mounts it in its
  runtime's file layer, where the **EROFS reader** parses it
  ([Reading EROFS images](#reading-erofs-images)). The tree has
  dm-verity's on-disk format (version 1, SHA-256), and its root hash and
  salt come from the boot image, so the check happens where the blocks are
  consumed, no storage domain or driver is trusted with it, a block cannot
  change between its check and its use, and the reader parses only blocks
  that passed it. The device service names a window on an image only
  inside the slot that the boot value names, so when the boot value is
  `unknown` it names none, and that boot runs only the releases in the
  boot image. The system domain never loads code from an EROFS image
  ([design-live.md](design-live.md#invariants) V5).

  The packer writes each image with upstream's `mkfs.erofs`, a host tool
  fetched at a pinned release and hash, built out of tree and run as a
  subprocess, with a fixed timestamp (`-T` with `--all-time`), a fixed
  UUID (`-U`), every file owned by root (`--all-root`) and no compression,
  and then computes the image's hash tree itself and writes it after the
  image; `make check-reproducible` compares the images' bytes across two
  builds. `mkfs.erofs` is never linked and never part of an image, so the
  GPL-2.0 files of erofs-utils' library bind nothing erXos ships
  ([research](research-boards-storage.md#file-systems)). The reader is
  erXos's own Erlang, written from the format's documentation and its
  MIT-licensed on-disk header, `erofs_fs.h`, never from Linux's GPL driver.
  The writer and the reader therefore share no code, and both meet an
  independent oracle in the Linux guest that is F2FS's oracle:
  `veritysetup` checks each image's tree, Linux's EROFS driver mounts it,
  and its view of the files is compared with the reader's; upstream's
  `fsck.erofs` also checks each image. Images are uncompressed: the
  boards' media have room for uncompressed slots, an estimate that a
  decision gate of [plan.md](plan.md#decision-gates) checks against the
  slot images' sizes, and LZ4's decompressor, whose library is
  BSD-2-Clause, would join the per-byte primitives if they do not.
* The **data partition** holds what changes: the files of principals and
  services, in a read-write file system, and in each principal's own
  directory that principal's hot-loaded blobs and the overlays of its
  supervised specifications, so code loaded into a domain survives a
  reboot until a system update changes the release beneath it
  ([design-live.md](design-live.md#the-code-store)). The code of the
  system domain and of every specification of the system manifest
  becomes durable only inside a release, through a system update, and
  neither ever loads code from the data partition
  ([design-live.md](design-live.md#invariants) V5). A user
  domain may load code it reads from its own files, with its own
  authority and nobody else's.
* The **vault's partition** holds the vault's files, each principal's
  sealed keys and credential slots and the machine's keys, in erXos's
  F2FS, with littlefs as its stopgap as on the data partition, through a
  storage domain whose only client is the vault
  ([design-system.md](design-system.md#the-vault)).
* **FAT partitions** hold files to exchange with other machines: a
  removable medium's partition, or a partition that the system
  configuration gives the exchange role, such as a FAT image attached to a
  QEMU guest as a second disk. No boot and no update reads one. The
  slots' boot partitions are FAT too, for the firmware, but no domain
  parses them: only the slot writer holds their windows, and it writes
  slot images raw (PW1).

A medium holds the **boot-selection record**, two **slots**, the vault's
partition and the data partition. Each slot holds a system: a boot
image, the EROFS images whose root hashes that boot image carries, and in
its **manifest window**, a run of sectors that the medium layout of the
ABI file fixes inside the slot, the update manifest that the slot image
was installed from. The record names the **committed** slot `C` and is
rewritten only at a commit; the other slot is the **spare**. A **trial**
boots the spare once, by a one-shot request that the firmware clears as
the trial starts, so whatever ends a trial, the next boot is the
committed slot's. The update therefore has two states, and nothing else:

* **`normal(C)`**, the record with no trial request: the firmware boots
  `C`, and the spare may be written;
* **`trial(S)`**, the record together with the firmware's one-shot trial
  request for the spare `S`: the firmware boots `S` once, and the next
  boot returns to `C` unless the trial commits by rewriting the record to
  name `S`.

An update is **committed** when the record names its slot, and **failed**
when a trial of it has ended and the record still names `C`. Whether the
spare holds a complete system is recorded nowhere: it is the result of
checking the spare against the manifest in its manifest window, which the
update service repeats at each normal boot, so a spare whose write was
cut short is not bootable and needs no state of its own (U5).

The update path acts on two durable facts and the spare's own bytes:

* the **record**, which the slot writer reads from the medium;
* the **boot value**, `unknown`, `normal(slot)` or `trial(slot)`, which the
  firmware reports and the kernel passes on in the machine page; it is
  `unknown` on every platform without a trial request.

**Manifests.** The update service checks an update's signature over the
manifest's raw bytes before decoding them. The manifest binds the format
version, the platform, the build kind (development or release), the slot
image's size and its hash with the signature and manifest windows read as
zeros (below),
the boot image's build identifier, the EROFS images' root hashes, the
storage formats its release reads, and a security version that the running
system refuses to go below; a release system refuses a development image,
and every system refuses an update whose storage formats differ from its
own, since that update's trial could not read the partitions, and names an
installation as the way to it. The update service writes the manifest's
raw bytes into the spare's manifest window last, after the slot image,
so a spare holds a manifest only once every byte the manifest hashes is
written; a check of the spare verifies that manifest's signature, as at
install, and the slot image's hash with the signature and manifest
windows read as zeros. The signature is Ed25519, checked by the
small verifier of [Dependencies](design.md#dependencies) against the
public key that the running boot image carries:

* in a release build, the release key, whose custody belongs to the
  release process ([plan.md](plan.md#beyond-the-plan));
* in a development build, a development key that the build tree generates
  and keeps outside the repository. The host tool signs every update it
  sends through the host link with that key, so a spare is checked one
  way in every build, and the Raspberry Pi 5, which has no host link,
  updates over the network, signed with the same key.

**Trust in a boot, and rollback.** A manifest's signature guards what an
update writes; what guards a boot is the platform's trust root, which
decides how far the boot image, and with it the root hashes of the EROFS
images it carries, can be believed
([design-platforms.md](design-platforms.md#trust-in-the-boot)): on QEMU
`virt` the host; on a board with secure boot the firmware, which checks
the slot's boot image against the board's key before the kernel runs; on a
board without it nothing, so whoever writes the medium controls the
machine. On a board with secure boot, each slot also carries the board
owner's signature of its `boot.img`, which the packer makes on the owner's
host with a key it is given and never keeps
([design-platforms.md](design-platforms.md#trust-in-the-boot)). The
signature, `boot.sig`, lies in the slot's **signature window**, a run of
sectors that the medium layout of the ABI file fixes inside the slot,
holding the file's bytes at the fixed length its directory entry gives,
and the release process publishes the window as zeros. A release's
manifest hashes the slot image with the signature and manifest windows
read as zeros, so the
release key covers every byte of the slot but the windows, and the owner's
signing writes the window alone, which the board's firmware checks against
`boot.img` before the kernel runs. An update for such a board passes
through its owner, who signs the slot image the release process published
and sends it on; the update service checks the manifest's signature and
the slot image's hash with the window zeroed, and a slot image without a
valid signature fails the firmware's check at its trial, which falls back
to the committed slot. The rollback policy follows the same split. An
update never installs below the running system's security version, which
therefore rises only when an update commits, and a failed trial falls back
to the committed slot, which passed the same check when it was installed;
nothing on the boot path checks a version, so whoever can write the medium
can put back any image the trust root accepts, an older signed one
included. Refusing that at boot needs a monotonic counter that the
platform's trust root keeps and checks before the kernel runs, which
neither the Pi 4's firmware nor the Pi 5's documents offer; on a board
that offers one, the counter takes the committed slot's security version
at each commit, and the spare, which the next update overwrites, may lie
below it.

## Algorithms and behavior

### Reading EROFS images

The EROFS reader, `erx_erofs`, is Erlang, preloaded in the runtime image
beside `prim_file`, so every domain has it and reads code from an EROFS
image as early as from its release slice, without a release having to
carry it. `erx_path` resolves a path to an EROFS mount, an entry whose
provider is `{erofs, Image}`, with the reader answering its walks and
link reads; the reader then serves the operation of the resolver's last
action in the calling process, as `erx_file_remote` serves a grant
([design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)),
so a slow read delays only its caller and reads of one image run in
parallel.

1. **Mounting.** The runtime opens the image's window inside the
   hash-checking reader, `erx_verity`, with the pid of the block service's
   window on the image and the root hash, salt and tree layout that the
   boot image records, which arrive with the domain's other grants at its
   creation ([design-system.md](design-system.md#creating-a-domain)), and
   the reader reads block 0 through it. It checks the superblock's magic, its
   4 KiB block size, and its incompatible feature bits, and refuses an
   image with a feature it does not implement, naming the bits; with the
   superblock-checksum feature it checks the CRC-32C with the primitive.
   It implements compact and extended inodes, the plain and inline data
   layouts, directories, symbolic links and no compression, the layouts
   the packer's options produce.
2. **Walking.** For each name it reads the directory's inode, then its
   blocks: each block holds directory entries sorted by name, so a binary
   search over the blocks' first names and then within the block finds
   the name in O(log b) block reads for a directory of b blocks. A walk is
   a loop over the path's names, at most 256, and recurses nowhere; a
   symbolic link ends it, and the client resolves the link's text through
   its own namespace, as for every provider
   ([design-files.md](design-files.md#resolving-a-path)).
3. **Reading.** A file's data blocks come from `erx_verity:read(Image,
   Block, Count)`, at most 16 blocks a call, as binaries in the domain's
   memory that matched the tree (E1). `erx_verity` is Erlang running in
   the calling process: it answers from its cache when it holds every
   block it needs, checked; otherwise it sends the reads to the image's
   window at the block service, waits for the reply, which arrives as a
   message, and hands each block with its tree blocks to
   `erx_verity:check/3`, the runtime's pure check of a supplied block
   against the tree with the SHA-256 primitive
   ([design-runtime.md](design-runtime.md#per-byte-primitives)); it keeps
   the tree's blocks in its cache and returns the data blocks, or
   `{error, eio}`. Only the caller waits, in Erlang, so no scheduler
   blocks and no unchecked byte reaches the reader. Whole-file reads
   return the joined binary; positioned reads return the requested range.
4. **Caching.** Verified metadata blocks (the superblock, inode and
   directory blocks) are kept in an ETS table per image, at most 256 of
   them (1 MiB, a default), evicting the oldest first. An image never
   changes, so the cache is always coherent, and a miss costs one checked
   read.

Every structure is decoded by binary matching with checked bounds: an
inode number, an offset or a size that points outside the image, a
directory entry whose name runs past its block, or a name over 255 bytes
fails the operation with `{error, eio}` and a log line naming the image
and the block, inside the reader's own `try`, so a malformed image fails
the operation, not the caller. An image that passed its tree is what the
packer wrote; the checks are there because the reader's fuzz target feeds
it images that did not.

Every domain that mounts an image reads and checks its blocks for itself:
N domains over one image hold N copies of the blocks they use and hash
them N times, which is the price of trusting no storage domain with a
release's integrity (ST-R1). The block service is in the storage domain,
which needs no EROFS image to start: the system release and the small
release every domain starts from live in the boot image, whose slices
the kernel maps, so the boot path reads no block through the service and
nothing the service serves is needed to reach it.

A block read through the service costs one connection round trip to the
window, two copies of the blocks (into the window's lane and out of it at
the client) and the SHA-256 of each block in the client; `erx_verity`
asks for up to 16 blocks a call, so a 64 KiB read pays the round trip
once ([Performance](#performance)).

### Read-write storage

Read-write storage is F2FS, implemented by erXos in Erlang from its
on-disk format. littlefs is the current implementation behind the same
file interface, a stopgap whose limits on large media (files of at most
2 GiB, a design for microcontrollers) are accepted for it. erXos's F2FS:

* **Structure.** An Erlang application in the storage domain: a callback
  module of `erx_fs`, so every grant and every open file is a process of
  its own ([design-files.md](design-files.md#serving-the-erx_fs-behaviour));
  a volume process that owns the checkpoint, the node address table, the
  segment information and the current segments, and orders every update
  to them; a cleaner process; and the block client, `erx_block_client`,
  which sends to the volume's window pid and receives completions as
  messages. The
  format's decisions (where a block goes, what a checkpoint holds, which
  segment the cleaner takes) are pure functions over the volume's state,
  and the volume process applies their results as block writes and
  flushes, so the core is tested on the host without a medium. Checkpoints
  and other checksummed structures use F2FS's CRC-32, which ERTS's own
  `erlang:crc32/2` computes once its seed and result are inverted, since
  zlib's convention inverts both and Linux's does not.
* **Clean room.** Linux's F2FS is GPL-2.0, and none of its code enters the
  tree. One author writes a specification of the format and of the
  cleaner's policies, in erXos's words, from Linux's documentation and
  sources, and implements none of it; the implementers work from that
  specification and the ABI file alone. Implementers that are models
  trained on public code, Linux's included, weaken the separation. A legal
  review of the clean room weighs this, and the user requires that review
  before any distribution includes erXos's F2FS.
* **Linux as the oracle.** Linux's F2FS driver and `fsck.f2fs`, run in a
  Linux guest under QEMU on the host, check every image erXos's F2FS writes
  and every state the power-cut harness produces, and the guest mounts
  erXos's images for differential tests of file semantics.
* **Explicit features.** It mounts only images whose superblock feature
  bits it implements, and refuses the rest with a diagnostic naming them.
  The design refuses `ENCRYPT`, `COMPRESSION` and `ATOMIC_WRITE` among
  them: an image that carries any of the three is not mounted, read-only
  or otherwise, and erXos's F2FS never sets them.
* **Power cuts, proven.** A host harness runs the file system's core on
  the host's stock OTP over a simulated medium that records every write,
  cuts power after every write and reorders the writes between flushes;
  every resulting state must mount at the last completed checkpoint, with
  every acknowledged `fsync` recovered, and pass `fsck.f2fs`.
* **Hostile media.** An image is untrusted input: every structure is
  decoded by binary matching with checked bounds and has a fuzz target,
  run on the host's stock OTP. F2FS checksums its checkpoints and, with
  the matching features, its superblock and inodes; file data carries a
  checksum only in files made read-only under its verity feature. A
  checksum catches corruption, not a crafted image, so a crafted data
  partition can make its file system's process fail, which its supervisor
  restarts, serve wrong data from that partition or damage it, and nothing
  more: Erlang code cannot write outside its own heap.
* **The cleaner**, which reclaims segments, is the hard part; the
  specification describes the policies it implements.
* **Parity.** It replaces littlefs only at parity over the file-semantics
  test corpus, as every stopgap's replacement does.

In Phase 1 littlefs instead runs as a NIF in the system domain, behind the
same `erx_fs` interface; its design is the littlefs section of
[design-stopgap.md](design-stopgap.md#littlefs-in-the-system-domain), and
the port below is the target.

**littlefs, the stopgap**, runs in the same storage domain behind the same
`erx_fs` interface, as a **sub-space port** of the storage domain, with
the shape of a program
([design-programs.md](design-programs.md#a-program-is-a-port)):
single-threaded C under `liberx`, in a sub-space that holds its channel, a
data area the storage domain maps into it, and nothing else. One owner
process of the storage domain holds the port and sends it the volume's
operations as terms on the channel; littlefs's block callbacks become
requests back on the channel, which the owner sends to the volume's
window, and the bytes of both directions move through the data area. So
littlefs's C code holds no window and no device, a crash in it ends the
port and not the domain that runs the block driver, and the owner's
supervisor restarts the port, which mounts the volume afresh. The storage
domain is therefore one Erlang release whatever file system it serves, and
replacing littlefs changes one callback module. littlefs writes a file's
data to the medium only at the file's sync or close (`lfs.h`), so a
client's `fsync` is `lfs_file_sync` on that file followed by a flush of
the medium, and a checkpoint syncs every file open in the volume and then
flushes ([Interfaces](#interfaces)). The one owner runs the volume's
operations one at a time, whichever client asked, so under littlefs a
request waits for the volume's queue, which each client's grant bounds by
its requests in flight and its fid pool; erXos's F2FS, whose open files
have owners of their own, has no such queue. A port that crashes
mid-operation leaves the operation's outcome unknown, as its protocol
specifies; writes it had already sent to the window complete or fail at
the window as any write does, and the owner mounts the volume again only
after the window has answered every request the port had outstanding, so
no newer write races an older one. littlefs states that it has no
unbounded recursion ([research](research-boards-storage.md#file-systems)).
littlefs keeps no links and no device nodes, so its callback module
answers `symlink`, `link` and `mknod` with `eperm`.

**Shared mappings.** A file that programs map shared is served by their
session, which fills its own object with ordinary reads and writes it
back with ordinary writes
([design-files.md](design-files.md#shared-mappings)), so a storage service
sees a mapped file only as reads and writes, and erXos's F2FS, littlefs
and FAT need nothing of their own for it. A write-back is an ordinary
write, so the power-cut harness's rule covers it: an `fsync` or `msync`
that returned is recovered.

**Accounting.** The storage services account per client for space and
admit per client for work. Each principal has a quota and a reserve on the
data partition, so no domain can fill the partition for others. A storage
service runs on its own group's grant, sized by policy for the domains it
serves ([design-system.md](design-system.md#resource-policy)); what it
spends for one client is bounded by that client's grant process, its heap
limit, its fid pool and its requests in flight, and by the client's lane,
which a flooding client fills and then waits on in its own runtime.
Per-client CPU is a statistic the service's processes report to the
inspector, not an enforcement.

**File identity and version.** A file's identity is its server's domain,
its tree and its qid path, and its version is `getattr`'s
`data_version`, which the server draws from its domain's one counter
when it first meets a file and at every change to it
([design-files.md](design-files.md#identity-and-version)). Every server
keeps qid paths unique within a tree and never gives a path to a second
file while its domain lives. The path depends on what the format offers:

* **erXos's F2FS**: the inode's node number in the low 32 bits and its
  `i_generation` in the high 32, so a node number the volume reuses for
  another file makes another path.
* **EROFS**, served through a domain's export: the inode's number; an
  image never changes, so a file's version changes only when the export
  first meets it.
* **littlefs and FAT**, which keep no stable file numbers: a path drawn,
  the first time the server meets a file, from a counter of the domain's
  runtime, kept across the server's restarts as the version counter is,
  so no path is drawn twice while the domain lives. The server keeps the
  path in a table keyed by where the file's entry lies (littlefs's
  metadata pair and id, FAT's directory cluster and index), which a
  rename or a move of the entry updates, for as long as any fid names
  the file, and so as long as any session maps it, since a mapping's
  open holds fids ([design-files.md](design-files.md#shared-mappings)).
  The table holds at most 65,536 entries and never evicts one: when it
  is full, a walk or a create that would add an entry fails with
  `enfile`. A file that no fid names leaves the table, so a file closed
  and opened again may get a new path, which costs a client's cache a
  miss: a documented limitation of these formats, which store no file
  numbers.

So `cc -o t t.c && ./t`, run twice within one FAT timestamp's two seconds,
runs the second build: its write drew a new version, which no file object
of the first build's matches.

### Removable media: FAT

The **FAT server**, `erx_fat`, serves one FAT partition as files, in a
storage domain of its own that holds only that partition's window (PW1),
as an `erx_fs` callback module. It reads FAT12, FAT16
and FAT32 as Microsoft's specification describes them, the type following
from the volume's count of clusters, with long names, and writes FAT16 and
FAT32, mounting FAT12 read-only (Durability, below); exFAT is not
designed. It maps the format onto the file protocol as follows:

* **Names.** A long name is UTF-16 on the medium and UTF-8 in the
  protocol; the server converts between them and refuses with `einval` a
  name holding a character the specification forbids in long names (`"`,
  `*`, `/`, `:`, `<`, `>`, `?`, `\`, `|` and the controls below 0x20), and
  a name that starts or ends with a space or ends with a period, which the
  specification has readers ignore. FAT matches names without regard to
  case, as Windows does: the server compares long names after mapping each
  UTF-16 code unit of the Basic Multilingual Plane to its simple uppercase
  form, from a case table generated from one pinned version of Unicode's
  character database, and leaves each code unit of a surrogate pair as it
  is. So a name that differs from an existing one only in the case of a
  letter of that plane, accented ones included, is the same name, while
  names that differ only in the case of a letter beyond it, such as
  Deseret's, are different names; the server refuses an `lcreate` or
  `mkdir` that matches an existing name with `eexist`, and reports each
  name as stored. A short name is decoded as code page 437, the IBM PC's
  original OEM code page, which maps every byte to one character, so every
  short name has a UTF-8 form. A name that would need more than 255 bytes
  of UTF-8, or that is not valid UTF-16, is listed and walked under its
  short name. Every file the server creates gets a short name too,
  generated as the specification describes from ASCII letters, digits and
  the symbols it allows, so other systems that read only short names find
  it under the same name in every OEM code page.
* **Attributes.** FAT has no owners and no permission bits: a file reports
  mode `0644`, or `0444` with the read-only attribute, and a directory
  `0755`; `setattr` of `mode` sets the read-only attribute exactly when the
  owner's write bit is clear and changes nothing else. Times are read and
  written as UTC, with the modification time's two-second resolution. A
  file holds at most 4 GiB less one byte, and a write beyond fails with
  `efbig`; a directory holds at most 65,536 entries, as the specification
  bounds it, and an `lcreate` or `mkdir` beyond fails with `enospc`.
  There are no symbolic links, hard links, device nodes or extended
  attributes: `symlink`, `link` and `mknod` fail with `eperm`, as Linux's
  `vfat` answers them, and `xattrcreate` with `enotsup`.
* **Durability.** FAT keeps no journal, so the server orders its writes
  with flushes, which the block driver passes to the medium, and relies on
  a sector being written whole, which a medium that tears a write breaks
  ([Risks and open questions](#risks-and-open-questions)). Before the
  first change after a mount, it sets the volume's dirty flag, which FAT16
  and FAT32 carry in the FAT's second entry, and flushes. It then commits
  changes in **batches**, at `fsync`, at unmount and every 5 s while
  changes wait, each batch in five steps with a flush after each, so no
  write of a step reaches the medium before every write of the steps
  before it:
  1. **Data**: the files' data, and every cluster that grows a directory
     or holds a new directory's first entries, written whole with its
     entries or zeroes.
  2. **Allocation**: the FAT entries of every cluster the batch
     allocates, each new run written whole as a chain of its own that
     ends in an end-of-chain mark, which no name and no live chain
     reaches yet.
  3. **Removal**: the directory entries that remove names.
  4. **Publication**: what makes the new runs reachable and cuts the old
     ones: the FAT entry that links a file's old last cluster to its new
     run, the directory entries that add or change names, a renamed
     file's new entry among them, and the end-of-chain marks that cut a
     shrinking file's chain.
  5. **Release**: the FAT entries that free clusters, which since step 4
     no live chain and no name reaches.

  Each FAT entry goes to every copy of the FAT in the same step, the first
  copy first. A cluster freed in a batch is allocated again only in a
  following batch, after this batch's last flush, so a cut before the
  frees reach the medium leaves every old entry naming only its own data.
  A clean unmount clears the dirty flag after the last batch and flushes
  once more. So a power cut or a removal at any point leaves names and
  chains that reach only allocated clusters holding written data, with no
  cluster in two chains or under two names; loses at most the batch being
  committed, whose files may hold old or new bytes block by block; and
  leaves at most lost clusters; and a volume whose flag is clear has no
  change half made. FAT16's and FAT32's entries, two and four bytes at
  aligned offsets, never straddle a sector, so each entry's write is
  whole; a FAT12 entry, a byte and a half, can straddle two sectors, and a
  cut between them makes another valid cluster number, and FAT12 has no
  dirty flag, so the server mounts a FAT12 volume read-only. A volume
  found dirty mounts read-only and reports it, so the files can be copied
  off and the volume repaired on another machine, never by a guess on
  erXos.

A FAT image is untrusted input like any other: the boot sector, the FATs,
the directories and the long-name chains are decoded with checked bounds,
a cluster chain is followed at most as many steps as the volume has
clusters, so a loop ends with `{error, eio}`, and the decoders have a fuzz
target on the host's stock OTP. Linux's `vfat` driver and `fsck.fat` in the
oracle guest check every image the server writes and agree with it on
names, sizes and contents.

### System updates

**A trial writes nothing but the record and the reset count.** On a
trial boot the block driver's write path refuses every write except to
the record's window and the reset count's, and every file system mounts
read-only without recovery: F2FS without
roll-forward, as Linux's `norecovery` mounts it
([research](research-boards-storage.md#file-systems)), littlefs and FAT
without writes. Writers get `{error, erofs}`, which a release's health
checks tolerate. The block driver reads the boot value from the machine
page through its runtime, so the rule holds whatever the storage services
and the system domain do. A failed trial therefore leaves the data
partition and the vault's partition as the committed system left them,
with nothing to undo.

**The slot writer** is one domain of its own, running a small Erlang
release from the boot image. It holds the only writable windows on the
slots and the only window on the record, each a window process of the
block driver exported to it, and the update service in the system domain
holds its only facet. Before every write it reads the record from the
medium and the boot value from the machine page, and decides what it
allows by one pure function over the two, from facts it reads itself.
The update service decides what it asks for by the same two facts and
the check of the spare. The update has two rows:

| State | Boot value and record | The slot writer allows | The update service |
| --- | --- | --- | --- |
| `normal(C)` | `normal(C)`, the record naming `C` | writes to the other slot, the spare | checks the spare against its manifest and reports it as bootable or not; to install an update, writes the slot image into the spare and its manifest into the manifest window last, checks the spare whole, and only then asks the system domain for an ordered end with `trial`, whose freezing checkpoints put every write the services acknowledged in a completed checkpoint that a mount without roll-forward reads ([design-system.md](design-system.md#shutting-down)) |
| `trial(S)` | `trial(S)`, the record naming the other slot | one commit, rewriting the record to name `S` | once the trial is healthy, with at least 60 s of the lease left, asks the slot writer for the commit, then asks the system domain for an ordered end with `reset` |

Every other pair of boot value and record allows nothing and asks for
nothing: an `unknown` boot value, an unreadable record, and a boot value
that names a slot the record does not, as when a firmware falls back to a
complete spare and boots it normally while the record names `C`. A commit
therefore applies only from the trial state, so no boot commits a slot
that has not passed a healthy trial, whatever the firmware boots (U2).

The table decides writes alone: a read of a slot or of the record and a
flush change nothing, and are always allowed. A **commit** is one request
that rewrites the record, flushes it and reads it back, so the flush and
the read-back belong to the write the table allowed and need no row of
their own; it answers `ok` when the record reads back as written. A
rewrite is never repeated: once the record names `S`, a trial of `S`
matches no row that allows a write to the record. Nothing records an
update's progress: a commit is the record naming `S`, a failure the
record still naming `C` after the trial, and a spare whose write was cut
short fails its check and is written again by the next install. The
update service starts a trial only when asked to install, so a failed
update is never retried on its own.

**The reset count.** Beside the record lies the **reset count**: the
number of consecutive boots that ended unordered, by a fault of the
system domain, its halt outside an ordered shutdown or a missed watchdog
deadline. An unordered end leaves no time to write, so the count is kept
from the boot's side: the update service has the slot writer add one to
it early in every boot, before the network domain or any user domain
exists, and set it to zero at an ordered end and at the first successful
login at any line, typed or automatic, a development build's automatic
logins of `root` at the UART and the host link included. A count past three when it is read makes the system release boot
its rescue configuration, the console, a login and the services a login
needs, with no user domain and no network
([design-system.md](design-system.md#boot)). The slot writer alone
writes the count, as it alone writes the record; it saturates at its
largest value, and a count that does not read as one of its encodings is
taken as past three, so a torn count errs toward rescue. The count lies
in a sector of its own, which no firmware reads, so the update's table,
which decides writes that choose a boot, does not govern it: the slot
writer writes the count on every boot whose value is `normal` or
`trial`, a trial's included, since it changes no slot and names no slot
to boot.

**A trial is supervised from the kernel's first decision.** The kernel
takes a machine lease of `erx.trial_deadline` at its early device-tree
pass, as soon as it knows the boot is a trial
([design-kernel.md](design-kernel.md#console-log-and-panic)), and holds it
until the machine ends. While the lease is held, every end of the machine
is a reset (K19): a panic, a call of `halt/0`, a request for another trial
and the deadline all reset the machine, which then boots the slot the
record names. The kernel's watchdog, which the system domain's runtime
pets, runs on a trial as on every boot, so a hung system runtime resets
too, and on a board with a hardware watchdog the platform layer reloads it
from the kernel's own timer for as long as the kernel runs, so a hung
kernel resets as well ([design-kernel.md](design-kernel.md#the-watchdog),
[design-platforms.md](design-platforms.md#the-watchdog)); on a board
without one, the harness's deadline catches a hung kernel under QEMU. A
fault of the system domain during a trial is a machine reset like any
other, and the reset boots the committed slot. A trial is **healthy** when
the slot it runs from passes its check against its manifest, the system
release is ready, its health checks pass, and the update path itself
works: the slot writer answers and the update service reaches its source,
so a committed system can always be updated again. Read-only health checks
do not establish that a release's write path works: the release's
acceptance suite exercises its writes, flushes and recovery on a
disposable volume before it is installed. The trial never writes the live
data or vault partitions to test them. The update service starts a commit
only while at least 60 s of the lease remain, which the machine page
shows, so a medium that responds normally finishes the record's rewrite
before the deadline; a medium that stalls past it leaves a torn record,
which the risks cover. After the commit the update service resets the
machine, and the committed system's first normal boot mounts the data
partition read-write.

**No conversion.** By the user's decisions, nothing erXos stores is
converted, and no release reads an earlier release's storage format. The
data partition and the vault's partition hold littlefs until erXos's
F2FS, and erXos's F2FS arrives by an installation, which writes the medium
afresh and creates both partitions with it; nothing littlefs wrote is
carried across ([plan.md](plan.md#m13-erxoss-f2fs)). An update cannot
bring it: its trial boots a release that cannot read the partitions, so
its health checks fail and it commits nothing, and the update service
refuses such an update before writing it, from its manifest's storage
formats. A fresh installation on a machine that had one has
three one-time consequences: every principal starts with no file and
enrols at the console's UART, where the installer is; the machine's keys are
made afresh, so its SSH host key changes once; and under `tpm` the TPM
keeps the lockout authorization the earlier installation set, which the
vault reports at the console and provisions again by clearing the TPM,
as [design-system.md](design-system.md#the-vault) describes.

**Each platform's record and request.** The rules above are the same on
every platform; what holds the record and the request is the platform's
firmware, or the harness that plays it, as
[design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record)
describes for each platform. Every platform meets one contract:

* the record's selection is one sector with exactly two encodings, byte
  for byte, one for each committed slot, placed alone in an
  erase-unit-aligned region; the slot writer commits only after reading
  the sector back as the encoding it wrote; a sector that reads as
  neither is an unreadable record, which allows nothing; its reset count
  is a sector of its own in the next such region, which the firmware
  never reads;
* each slot is one partition holding what the firmware loads, the kernel
  and the boot image, followed by the EROFS images at offsets that the
  boot image records with their hash trees' layouts, and its signature
  and manifest windows at offsets the medium layout fixes, so a slot image is
  the same bytes in either slot, the update writes it raw, and no domain
  on the target parses the slot's file system to boot or to update;
* the request is one-shot: the firmware clears it as the trial starts,
  `ERX_END_TRIAL` alone sets it, and the firmware reports the slot it
  booted and whether it was a trial in the device tree's `/chosen` node,
  which the kernel turns into the machine page's boot value
  ([design-platforms.md](design-platforms.md#data-model));
* a board whose firmware can run a watchdog from power-on is configured to
  run it and hand it to the kernel, so a trial whose firmware stage hangs
  resets too.

The record's selection is written only at a commit, when both slots hold
complete systems, so a write that tears it leaves either slot a complete
system to fall back to. An unreadable record allows no write and no
commit, since a repair on a normal boot could name a spare that never
passed a trial; the update service reports it, the machine runs what the
firmware booted, and an installation writes the record afresh. What each
board's firmware does with an unreadable record is checked by its port
([risks](#risks-and-open-questions)).

An update whose preparation for the trial fails never sets the trial
flag. Its normal reset boots the committed slot, whose usual file-system
recovery runs, and the update service reports the spare, which still
passes its check, as an update not yet tried. No incomplete freeze is
reported as a durable checkpoint.

## Interfaces

* **The block service.** A window process of the block driver takes
  `{read, Sector, Count}`,
  answered `{ok, Blocks}`, binaries the device NIF copied out of the
  driver's buffer pool;
  `{write, Sector, Bytes}`, answered `ok`; and `flush`, answered `ok` once
  the medium acknowledged it; each may answer `{error, eio}` for a device
  error, `{error, erange}` for sectors outside the window, and
  `{error, erofs}` for a write on a trial boot outside the record's window.
  A window's pid reaches its client at the client domain's creation, with
  its other grants, or locally in the driver's own domain. Beneath the
  driver is the device NIF, `erx_device`
  ([design-runtime.md](design-runtime.md#the-device-nif)), which only the
  driver's modules call.
* **The storage services and the FAT server** implement 9P2000.L's
  operations through `erx_fs` and facets, one grant per client, rooted at
  a principal's directory or a service's
  ([design-files.md](design-files.md#the-file-protocol)), each answering
  the operations its format cannot store, links, nodes or extended
  attributes, with the protocol's error; a client over its quota gets
  `{error, enospc}`.
* **The EROFS reader**, `erx_erofs`, serves `prim_file`'s operations on an
  EROFS mount in the calling process
  ([design-runtime.md](design-runtime.md#files)); it reads through
  `erx_verity:read(Image, Block, Count)`, which returns `{ok, Blocks}`,
  each a binary that matched the tree, or `{error, eio}` when a block did
  not match or the window failed, after a log line naming it ([Reading
  EROFS images](#reading-erofs-images)).
* **The slot writer's facet**, which only the update service holds, takes
  four requests: write a range of the spare slot; read a range of a slot
  or the record back; flush; and commit, which rewrites the record naming
  a slot, flushes it and reads it back, and answers `ok` when the record
  reads back as written, `{error, eio}` when it does not, and
  `{error, etimedout}`, its outcome unknown, when the medium does not
  answer within the lease. The slot writer's table, from the facts it
  reads itself, allows or refuses each write and each commit; a read or a
  flush changes nothing and is always allowed.
* **The data partition's and the vault's storage services** take a
  **checkpoint** request on the **durability facet**, which only the
  system domain holds, answered once a completed checkpoint holds
  every write the service acknowledged, so a mount without roll-forward
  reads them, which may also **freeze** the service, so that it answers
  every later write `{error, erofs}` until the machine ends. A freeze is
  final; there is no thaw request. The system domain's ordered end freezes
  every storage service and selects a trial only after every preparation
  succeeds; a failed preparation selects a normal reset to the committed
  slot instead
  ([design-system.md](design-system.md#shutting-down)). The vault, the only
  client of its storage service, may also ask that service for a
  checkpoint without a freeze, so a change the vault publishes is durable
  before the vault answers it
  ([design-system.md](design-system.md#the-vault)). Under littlefs a
  checkpoint syncs every file open in the volume, then has the block
  driver flush the medium, and answers only then. Before a freezing
  checkpoint reaches that module, `erx_fs` closes mutation admission at
  every grant and each open file's owner finishes the writes it admitted;
  the module's checkpoint and the block flush follow those completions,
  and no later write or successful `fsync` is admitted. A session's
  write-back after the freeze is a write like any other, answered
  `{error, erofs}`. A failed drain or flush fails preparation, and a
  freeze is reported only after every stage succeeded
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).
* **The update service** takes an update from the host link or the
  network service through its install facet, reports what it is doing and
  whether the spare passes its check, and asks the system domain for an
  ordered end with `trial` or `reset`
  ([design-system.md](design-system.md#shutting-down)).
* **The kernel** reports the boot value in the machine page, holds a trial's
  lease, and sets the firmware's trial request only through `ERX_END_TRIAL`
  ([design-kernel.md](design-kernel.md#console-log-and-panic)).
* **The device service** gives the block device to its domain and names
  the partition windows from the medium layout of the ABI file and the
  system configuration's roles
  ([design-system.md](design-system.md#devices)).
* **The runtime's primitives**: the hash-checking reader's SHA-256 and
  CRC-32C, and the device NIF's buffer pool
  ([design-runtime.md](design-runtime.md#per-byte-primitives)).

## Compatibility and migration

Every format carries its version and is refused when it is not one the
reader implements: F2FS's superblock feature bits, the EROFS images'
feature bits and block size and dm-verity's tree (version 1, SHA-256), a
FAT32 volume's file-system version (0.0, the only one the specification
defines), an update manifest's format version and storage formats, and
the record's two encodings. Nothing erXos stores owes compatibility to an
earlier release's form ([design.md](design.md#compatibility)): no release
reads an earlier release's storage format, no partition is converted, and
an update whose release reads other storage formats is refused, so a
change of format arrives by an installation that writes the medium
afresh, as erXos's F2FS does ([System updates](#system-updates)). A
manifest's security version is one the running system refuses to go
below, so an update can never install an older, vulnerable system; that
is a rule against rollback, not compatibility. FAT, an exchange format
that other machines write, is read as its specification defines it.

On a FAT partition, files behave as FAT gives them, each difference with a
test: names match without regard to case for the letters of Unicode's
Basic Multilingual Plane, as on Windows, and names that differ only in the
case of a letter beyond it are different names; a long name that does not
fit erXos's names appears under its short name, permission bits map to the
read-only attribute alone, times are UTC with two-second modification
times, files stop at 4 GiB less one byte, a FAT12 volume is read-only, and
a file closed and opened again may get a new qid path
([File identity and version](#read-write-storage)).

## Failure handling, diagnostics and debuggability

| Failure | Detection | What remains | Who cleans up | What the user sees |
| --- | --- | --- | --- | --- |
| A trial is unhealthy, hangs or panics | the health checks; the lease's deadline; the watchdog | the spare as written; the data partition as the committed system left it (U4) | the reset boots the committed slot, whose record still names it | the update reported failed by the record still naming the committed slot; never retried, since only an install starts a trial |
| A trial request's preparation fails or times out | the ordered-end coordinator | the verified spare and whatever checkpoints completed; no trial flag | a normal reset boots the committed slot and ordinary filesystem recovery runs | preparation failure and incomplete durability; never a successful trial preparation |
| Power cut while the spare is written | the spare's check against its manifest, at the next normal boot | a spare without a matching manifest, never tried (U5) | the next install writes the spare again | the spare reported not bootable |
| The firmware falls back and boots a complete spare normally while the record names the committed slot | the slot writer, from the boot value and the record | both slots as they are; the record unchanged | none: the pair matches no row, so no slot write and no commit (U1, U2) | the update service reports the mismatch and accepts no update until the machine boots the committed slot |
| A torn or unreadable record | the slot writer's read of the record | both slots complete | none on the machine: no row allows a write; an installation writes the record afresh | the update service reports the record and accepts no update |
| An EROFS block fails its hash check | the hash-checking reader | the mount, read-only | none needed | `{error, eio}` for the read, and a log line naming the image and block |
| A verified EROFS block holds a malformed structure | the reader's bounds checks | the mount | none needed | `{error, eio}` for the operation, and a log line naming the image and block |
| A crafted or corrupt data partition | the file system's bounds checks and checksums | that partition | the failing process ends, its supervisor restarts it, and a storage domain that fails beyond its restart intensity is started again by the domain service from its specification | the domain's death record; that partition's files unavailable |
| littlefs's C code crashes | the port's sub-space faults, and its owner sees `{exit_status, N}` | the partition as littlefs left it; an unacknowledged operation has an unknown outcome | the owner's supervisor restarts the port once the window has answered the port's outstanding requests, and the port mounts the volume afresh | affected operations fail with `eio`; the partition unavailable until the remount |
| The block device reports an error, or the controller stops answering | the device process's completions and its deadline | the request's buffer, quarantined until the device is reset ([design-runtime.md](design-runtime.md#the-device-nif)) | the device process reports to the device service, which resets the device | `{error, eio}` on the request; the inspector's device record |
| The domain that runs the block driver ends | the domain service | every window dead; every client's reads and writes fail | the domain service starts the domain again from its specification, the device service gives it the device again and names its windows, and each client receives its window anew as a grant | `eio` on every file of every storage service until the windows return; the domain's death record |
| A FAT volume found dirty, or a removal while mounted | the volume's dirty flag; the window's errors | the volume, read-only | none on erXos; the volume is repaired on another machine | a report naming the volume; `{error, erofs}` for writes, `{error, eio}` after a removal |
| An update's signature or manifest fails its check | the verifier, before decoding | nothing written | none needed | the update refused, with the reason |

**Diagnostics.** The inspector shows the boot value, the record, the
spare's check, each storage domain's state and the block
driver's windows and counters; every grant, window and open file of a
storage service is a process the inspector and the tracer show like any
other; the kernel's final line on every end of the machine names the end
it takes.

## Security

Every byte from a medium is untrusted, and so is every update until its
signature checks. EROFS blocks are checked against their tree in the
domain that consumes them (E1); file system images are parsed only in the
domain over their own partition, with bounds checks and fuzz targets
(PW1); the partition table is parsed by the driver's Erlang partition
process the same way. The parsers and the driver are Erlang, whose code
cannot write outside its own heap, so a parsing bug fails a process
instead of corrupting memory; the C that remains is the device shim
beneath the driver, which parses nothing, the per-byte primitives, and
littlefs, the stopgap, in a sub-space that holds nothing but its channel
and data area, each small and each with a fuzz target. An update's
signature is checked over the manifest's raw bytes before decoding,
against the key the running boot image carries, and a release system
refuses development images and lower security versions. Only the slot
writer can write a slot or the record, and it derives what it may do from
facts it reads itself (U1, U2). In the default configuration the storage
domain holds the block device, so a logic bug in its Erlang file system
could in principle call the device NIF; the build check that only the
driver's modules reference it closes that path for code in the tree, and
a release configuration for a board whose controller is unconfined
separates the two domains. The residual risks, a medium that tears an
acknowledged write and a crafted data or FAT partition that damages its
own files, are recorded in [design.md](design.md#residual-risks).

## Verification and testing

The block driver: a host test of the device service's window derivation
(PW1); a QEMU test that every window refuses sectors outside it with
`erange`; the build check that only the driver's modules reference
`erx_device`, and the one that the NIF's post is reached only from the
driver's write path, each with a seeded violation that it
catches; a QEMU test that a trial boot's driver refuses every write but
the record's, whatever its clients ask; a test of the same storage
service against a local window and against one exported from a driver
domain of its own, which must pass both unchanged; a controller that
returns a malformed completion, whose partition and device processes fail
and restart without the domain ending; and a kill of the driver's domain
while clients hold windows, after which every client sees `eio`, the
domain service restarts the domain, and the clients' windows return.

The littlefs port: a crash injected into littlefs mid-write, after which
the port restarts, the block driver and every other window live on, the
volume mounts, and `fsck` in the oracle guest finds a consistent volume
whose last acknowledged `fsync` is present; a port that stops answering,
ended at the owner's deadline with the same outcome.

An independent TLA+ model checked with TLC covers the update protocol
and the slot writer's rules. Abstract operations and the mechanism's
persistence steps have explicit scopes, targeted broken configurations
and reachability witnesses. Each invariant maps to an implementation
check; [Protocol verification](design-verification.md) defines the suite
and the mapping discipline. The model records firmware and medium
assumptions without substituting them for board conformance.

The actual update state machine and the slot writer's rules are explored
exhaustively on the host against an independent oracle, with a power cut
after every write and every reset, writes lost from the medium's volatile
cache, a torn record sector,
an unreadable record, a torn reset count, a flag set but never used, a
firmware that boots either slot normally whatever the record names, a
spare cut short at every write, and a deadline that passes at every step,
checking that a commit happens only from the trial state and only after
a healthy trial; the reset count reaches rescue
after exactly the fourth unordered end in a row, from every interleaving
of ends, ordered ends and logins, and a torn count errs toward rescue.
A QEMU test acknowledges a write, prepares a trial, cuts the power before
any later checkpoint, and checks that the trial's mount without
roll-forward finds the write; one cuts a spare's write short and finds the
spare reported not bootable and no trial requested; and the commit's
three answers are
each driven by a medium that writes, refuses and stalls. The driver's
admission is tested with a boot medium whose table differs from the
layout in one field, which it refuses, boot media of two sizes, whose data
partitions run to each one's end, which it admits, and removable media
whose entries overlap or pass the end, which it serves without them.

Preparation tests fail or time out each vault and storage reply, including
one storage service after another has frozen, and deliver replies after
the deadline. The selected end is always a normal reset on failure, no
trial flag is written, and no service resumes between preparation and
reset. Successful preparation alone permits a trial. Forced ordinary
shutdown reports incomplete durability, while successful `fsync` and vault
checkpoint operations retain their specified recovery guarantees.
They also acknowledge a write, close its fid and freeze: the normal
recovery and the trial's read-only mount both find that write, and no
write reaches the medium after the freeze acknowledgement.

Admission tests flood a storage service from one client while another
reads, and find the second client's latency bounded by the service's
scheduling and the first client blocked on its own lane; the service's
group alone is charged for both, and the inspector's per-client statistic
attributes the work.

The FAT server has a power-cut harness of its own, which cuts after every
write and every flush, and around both changes of the dirty flag, reorders
the writes between flushes, as F2FS's harness does, and checks each image
with `fsck.fat`: a clean flag never comes with a change half made, no name
and no chain reaches a cluster the FAT does not allocate, no cluster lies
in two chains or under two names, and no file that an earlier batch
committed changes, but for the files of the batch being committed, whose
bytes may be old or new block by block. Its layouts include files whose
old last cluster's entry and new run's entries lie in different sectors of
the FAT, a chain that grows and one that shrinks in one batch, and a FAT12
volume, which mounts read-only. A test also checks littlefs's checkpoint:
a write acknowledged through a file still open, a checkpoint, and a power
cut leave the write on the medium. Its name matching is compared with
Windows' rules over cases that include letters of the Basic Multilingual
Plane with and without simple uppercase forms and Deseret letters in both
cases.

erXos's F2FS is checked by Linux's F2FS driver and `fsck.f2fs` in a Linux
guest and by the power-cut harness ([Read-write
storage](#read-write-storage)); the EROFS reader, on images that
`mkfs.erofs` writes, by `veritysetup`, Linux's EROFS driver and
`fsck.erofs` in the same guest, the reader running on the host's stock OTP
over the image's file and in a domain under QEMU; the FAT server by
Linux's `vfat` driver and `fsck.fat` there, on images each side writes for
the other. Fuzz targets cover the partition table with its two extended
boot records, EROFS, F2FS, FAT and littlefs images, the hash-checking
reader, the driver's completion decoder, update manifests, the
boot-selection record and the QEMU harness's slot parser, each built for
the host (`make check-fuzz`): the Erlang decoders run on the host's stock
OTP, the C parsers natively. Runs on the boards check what QEMU cannot:
each board's trial request across its reset, a damaged record, and the
firmware's watchdog settings
([design-platforms.md](design-platforms.md#trial-requests),
[plan.md](plan.md#m12-storage-networking-boards)).

## Performance

Reading an EROFS block costs a read from the medium, a copy into the
domain and a SHA-256 of the block, which dominates once the block is in
memory: an estimated 4 to 20 us for 4 KiB at the 200 MB/s to 1 GB/s of
portable C (an estimate from the cost model of
[design-live.md](design-live.md#performance)), the only path on the
Raspberry Pi 4, whose cores have CRC instructions but no SHA-256
instructions, and an estimated 2 to 4 us on the Raspberry Pi 5, whose
cores have them, at an estimated 1 to 2 GB/s (the boards' CPU features
are in [design-platforms.md](design-platforms.md#references)). The
reader's Erlang work
per lookup, a binary search over cached directory blocks, is an estimated
1 to 5 us under BeamAsm. Writes to the data partition and to FAT are
bounded by the medium: an SD card's 20 to 100 MB/s is 40 to 200 us per
4 KiB block (an estimate from the cards' rated speeds), against an
estimated few microseconds of Erlang per block. The driver's cost per
request is an Erlang message to the window, the NIF's descriptor post and
one interrupt delivered through the runtime's event loop, so
interrupt-to-completion latency includes the runtime's scheduling; gate G9
measures it per device class and decides the completion batching
([design-system.md](design-system.md#the-driver-table)). A block that
crosses a connection costs one more copy, out of the lane at the client.
`tools/erx bench fs` measures sequential and random reads of an EROFS
image, the data partition and a FAT image, and a `find` over 10,000 files,
on QEMU under HVF and on both boards, against the same operations on the
release file system in the same run, as the baseline, and `tools/erx bench
blk` the driver's throughput and latency against the device's rated
figures. Uncompressed slots fit the boards' media, an estimate that a
decision gate of [plan.md](plan.md#decision-gates) checks against the slot
images' sizes.

## Portability

The rules are the same on every platform; the record and the trial request
are each platform's, under one contract ([System
updates](#system-updates),
[design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record)),
and a platform without a trial request reports the boot value `unknown`
and takes no update. The driver's device process is the part that differs
per controller (virtio-blk on QEMU, the SD host controllers of the
boards); each is an Erlang module over the same device NIF, with the
controller's registers named from its CMSIS-SVD description
([design-platforms.md](design-platforms.md)). Which domain holds the
device is each board's configuration. The primitives' use of a CPU's CRC
and SHA-256 instructions sits behind the architecture layer, with portable
C beside it ([design-runtime.md](design-runtime.md#per-byte-primitives)).

## Dependencies

No dependency beyond those in the dependency table of
[design.md](design.md#dependencies): littlefs as the stopgap for
read-write storage, the Raspberry Pi firmware, and the small verifier of
update signatures; upstream's erofs-utils, whose `mkfs.erofs` writes the
images and whose `fsck.erofs` checks them, and the Linux oracle guest's
file-system tools, as host tools invoked as subprocesses and never part of
an image; LZ4's decompressor is the option if the media lack room for
uncompressed images. The block driver, the EROFS reader, erXos's F2FS,
the FAT server and the slot writer are erXos's own Erlang.

## Alternatives considered

**One storage domain with the whole medium.** A single domain would parse
the partition table and the file systems, verify the EROFS images and
write the slots. A crafted data partition that broke its file system
would then reach the slots, the boot-selection record and every
principal's files, and survive updates. Partitions as windows, a slot
writer of its own and hash checks where blocks are consumed confine each
parser to its own partition ([Invariants](#invariants), PW1).

**A native block driver in a domain of its own.** The driver would be C
in a domain that serves windows to every storage domain over a kernel
gate. Rejected by the user's decision that drivers are Erlang: the
Erlang driver's partition parser and completion decoder fail a process
instead of corrupting memory, its windows are processes the inspector and
tracer show, and it needs no native runtime of its own. A domain of its
own for the device remains the configuration for a board whose controller
is unconfined, with the same driver.

**littlefs as a NIF in the storage domain.** littlefs's C would run on a
dirty scheduler of the storage domain's runtime. It loses: in the default
configuration that runtime also runs the block driver, so a memory bug in
the stopgap could reach the device and every window on the medium, and a
crash in it would end every storage service's windows at once. A
sub-space port confines the C to its channel and data area, by
construction, and its crash ends one volume's port.

**Converting the partitions.** A conversion from littlefs to F2FS, in
place or by an update whose release reads both, would keep files and
keys across the change. Rejected by the user: a conversion needs a proof
of its own, and no release owes compatibility to an earlier one's
storage while erXos is in development, so an installation creates both
partitions afresh.

**File systems in C.** erofs-utils' library as the EROFS reader in every
runtime, and erXos's F2FS in C in a native storage domain. Rejected by the
user's decision that system code is Erlang: an Erlang file system's grants
and open files are processes that can be inspected, traced, supervised and
upgraded live, and its parsing bugs fail processes instead of corrupting
memory. The cost is per block, where the medium and the hash dominate
([Performance](#performance)), and the per-byte work stays in C.

**An EROFS writer in the Ruby packer.** The packer would write EROFS images
itself. It loses: `mkfs.erofs` writes reproducible, uncompressed images,
and as a host tool it costs nothing on the target and shares no code with
erXos's reader, which strengthens the differential test. The packer takes
the job over only if `mkfs.erofs` stops being reproducible.

**The hash tree checked in the driver.** The block driver would check
each EROFS block against the tree before handing it out, once for every
client. It loses: the check is the funnel E1 rests on, and it must happen
in the domain that consumes the block, on the domain's own copy, or a
driver's bug or compromise would be trusted with every release's
integrity (ST-R1); N copies and N hashes for N domains are the price.

**Per-file hash trees.** fs-verity and Fuchsia's blobfs keep one tree
per file. The EROFS metadata the reader parses (superblock, inodes,
directories) then needs a tree of its own, as composefs and Apple's
signed system volume both add, and erXos updates whole slots, so sharing
files between images gains nothing. One tree per image covers metadata
and data with one root hash.

**Whole-file fingerprints.** FreeBSD's and NetBSD's veriexec hash a
whole file before it is used, which reads a multi-gigabyte file before
its first page and cannot report one bad block.

**An HMAC per sector.** FreeBSD's `geli -a` authenticates each sector,
which needs a secret on the device and gives no protection against
replaying an old sector.

**Install-time checks only.** OSTree, Nix and OpenBSD's signify verify
content when it is installed. They give nothing against a medium swapped
later or against bit rot, which the tree catches at read time as `eio`.

The manifest names each image as Android's AVB hashtree descriptor does:
root hash, salt, block size, hash algorithm and data-block count, all
fields of the `image` record
([design-abi.md](design-abi.md)).

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| erXos's F2FS, written from a specification of a GPL implementation's format, is challenged as derived from it | low | high | a clean room: the specification's author implements none of it and the implementers see only the specification; a legal review of the clean room before any distribution includes it |
| An SD card loses or tears an acknowledged write, the one-sector rewrite of the boot-selection record included | medium | high | the record changes only at a commit; the power-cut harness covers lost and reordered writes between flushes; each board's port tests what its firmware does with a damaged record; a torn record needs an installation, since no normal boot may rewrite it |
| On a board, the trial request does not survive the reset that ends a trial, or an unreadable record stops the firmware instead of falling back ([design-platforms.md](design-platforms.md#trial-requests)) | medium | high | each board's port tests the trial path before it accepts updates: a requested trial boots the spare once, a crash or hang in it boots the committed slot, and a damaged record is tried in place; a dropped request shows as a failed trial |
| A board firmware's watchdog settings do not behave as documented, or are missing ([design-platforms.md](design-platforms.md#the-watchdog)) | medium | medium | each board's port tests a trial whose firmware stage hangs; without them, such a trial needs a power cycle, as U3 states |
| The Erlang block driver misses the controller's timing or costs too much of its throughput | medium | slow storage on the boards | `tools/erx bench blk` at gate G9 per controller; completion batching; a per-byte C primitive for the ring work as a measured exception row in the driver table ([design-system.md](design-system.md#the-driver-table)) |
| The default configuration puts the block device and the data partition's file system in one domain | low | a logic bug in the Erlang file system that reaches the device NIF, or a storage-domain restart that drops every window on the medium | the build check that only the driver's modules reference the NIF; Erlang's memory safety; the native stopgap in a sub-space port; the configuration that gives the device a domain of its own, required where the controller is unconfined and available elsewhere |
| Erlang file systems are slower than the boards need, on the Raspberry Pi 4 above all, which has no SHA-256 instructions | medium | medium | `tools/erx bench fs` on both boards; metadata caching in the reader; the per-byte work already in C; G12 and G13 measure before littlefs is replaced |
| A parser bug in the EROFS reader | low | low | it parses only blocks that passed the hash tree, whose root comes from the boot image; a malformed structure fails the operation with `eio`; its fuzz target; Linux's EROFS driver as the oracle |
| A FAT volume removed or cut off while written loses files or clusters | high, for removable media | low | the dirty flag set and flushed before the first change; batches of five flushed steps, new chains allocated before they are linked and chains cut before they are freed; clusters freed in a batch allocated only in a following one; FAT12 read-only; a harness that reorders writes between flushes; a dirty volume mounts read-only; repair on another machine |

No open question remains for storage: the clean room's legal review, the
refusal to convert either partition, and the custody of the release key
outside this design are the user's decisions
([plan.md](plan.md#beyond-the-plan)).

## References

* [research-boards-storage.md](research-boards-storage.md): file systems
  (the EROFS format's documentation and licences, erofs-utils' licences
  file by file, F2FS's feature bits and mount options, dm-verity's
  format, littlefs), booting a chosen partition on the Raspberry Pi, and
  cryptography libraries, each dated, with its sources.
* Linux's dm-verity on-disk format (version 1, SHA-256), as the research
  record checks it.
* erofs-utils 1.9.4, `man/mkfs.erofs.1`: `-T` ("Specify a UNIX timestamp
  for image creation time for reproducible builds"), `--all-time`, `-U`,
  `--all-root`, https://github.com/erofs/erofs-utils (tag `v1.9.4`, read
  2026-10-31).
* Microsoft, "FAT32 File System Specification, FAT: General Overview of
  On-Disk Format", version 1.03, 6 December 2000: FAT type determination,
  long directory entries, name limits and character sets, name matching,
  and the 65,536-entry bound on a directory.
* Unicode Standard Annex #44, "Unicode Character Database", Unicode
  18.0.0, revision 38: field 12 of `UnicodeData.txt`,
  `Simple_Uppercase_Mapping`, https://www.unicode.org/reports/tr44/
  (read 2026-10-31).
* "cp437_DOSLatinUS to Unicode table", table version 2.00, which maps each
  of the 256 bytes to one character,
  https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/PC/CP437.TXT
  (read 2026-10-31).
