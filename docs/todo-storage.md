# TODO: Storage

Open work on storage: file systems, the storage domain, file clients, the object store, the image tree. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Major initiatives

* [High] storage and USB, drives: every medium's FAT16, FAT32 and EROFS volumes at `/media`, and littlefs
  volumes in development builds and test images ([design-drives.md](design-drives.md),
  [plan.md](plan.md#track-u-usb), part (e)). Steps, each with the host tests and fuzz target its section
  names, landing in this order:
  1. `abi/manifest.txt` and the manifest check: the window role `fat` becomes `drive`, which names no
     partition and is held only by the media domain; the rules of design-drives.md's "Manifest rows",
     each with a seeded manifest; the 9P statfs type `media` in `abi/protocols/9p.txt`; the `media`
     service and its mount point in `erx_ns`.
  2. The whole-medium window. `erx_blk_drive`, the drive grant, and USB's block service (the transport
     and its one window over the medium, ended through the engine when a grant is asked again) are
     built. What remains, as three packages in this order:
     1. Drive records ([design-fiasco.md](design-fiasco.md#drive-records)): the domain library writes
        `-erx_record drive ROLE N` for each drive window on a device a configured domain holds
        (`dom_boot_view.c` hangs them on their devices, `dom_args.c` writes them beside the device records,
        `ERX_BOOT_DRIVE_WORDS_MAX` in `include/erx/boot_words.h`); `erx_device_record:drives/2` reads
        them, joining `tools/fuzz/erx_device_record.rb`; the manifest check refuses a drive on any
        device the system domain holds, not only a block device. The host tests and seeds are that
        section's, and the check's clause gets a seeded manifest.
     2. The medium reference on `erx_blk_virtio`, USB's rule
        ([design-drives.md](design-drives.md#a-drive-and-its-medium)): the device process takes a fresh
        reference for each block service it starts over a drive; every request of the drive's window
        carries it; the process checks it at the head of its queue, and the step that ends it answers
        every waiting request of the old reference `{error, {device, gone}}` at once, so the held
        list and anything arriving later are both refused unissued; it ends the old block service only
        once the requests already issued have completed, and starts the next under a fresh reference,
        which tells the grant as `erx_blk_usb` does. The decisions go into a pure module with the
        full, held and broken cases todo-drivers.md asks for, tested by name, and the restart
        handoff's row of design-drives.md's host tests runs over it. A hung device's end is bounded
        only by the transport contract's in-flight bound, 18 s past issue, which ends the device
        process and every window with it ([design-storage.md](design-storage.md#data-model)); virtio has
        no bound today ([todo-drivers.md](todo-drivers.md), erx_blk's two items on a device that stops
        completing), so this package lands with that bound or after it. Until then a hung virtio
        drive holds its end, its old window and the grant's held asks until its driver is restarted,
        each holder's ask giving up at the grant's 60 s. The same bound bounds the held asks: they
        are those of holders that restarted during one end, each answered at the window's end.
     3. `erx_blk` serving a `block` device's medium as a drive: `erx_blk_service` reads its `block`
        drive; with one it starts the grant and one window of role `drive` over the whole medium and
        reads no table; with none it reads the layout; on a refusal it serves no window and logs why.
        The grant is started by the device process, linked to it and occupied by it for its life
        (design-drives.md, "One occupant"), and `erx_blk_drive:step/2`'s clause that lets a grant
        with no occupant take a serve from any issuer goes, with that section's occupant host test
        and its two seeds; the module's doc's "an unoccupied grant takes a serve from any issuer"
        goes with it. Host tests over a fake device for each of the three, seeded with a service
        that reads the table beside the drive; the QEMU case of a second virtio disk waits for step 4.
  3. `erx_media_table` (MBR, GPT with both copies and the metadata rule, none, whole-table refusal,
     `place/3`) and `erx_media_probe` with `abi/formats/probe.txt`, pure, with their fuzz targets and
     seeds; FAT's row through the FAT server's boot-sector decoder, FAT12 refused by name.
  4. The `erx_media` application (`erx_media_app` and `erx_media_sup` are built, and of the drive
     process, `erx_media_drive`, its ask through the registry's facet and its proxy's end): the
     drive process's medium supervisor, the medium supervisor and reader, the volume
     process with its probe and memory bound, the media tree with `status`, `ctl` and the two-volume
     `exdev` rule, the writable rule over the formats the build writes (built, with the volume's
     finish, the drive's `eject` through `ctl`, and `erx_media_sup:freeze/0`, which finishes every
     mounted volume of every drive); the freezing checkpoint around that freeze: `erx_fs` closing
     mutation admission at every `media` grant and letting each finish the writes it admitted, then
     calling the freeze, and answering every later write `erofs`, reached through the durability
     facet below; the drive grants of design-drives.md's "How the grant reaches the media domain":
     `abi/services/drive.txt`, one operation `window` and the five quantities design-drives.md
     gives, marked `served_by drive` (a value the closed set of `tools/lib/erx/abi_contracts.rb`
     gains, whose quantity rule it meets); the domain service's grant for each drive window row and
     its admission of `drive` in a ready report (`erx_domain_mints`, design-system.md's "A drive
     window as a grant"), with each record's service apart from its installed name
     (design-system.md's "One operation per grant"): `key()`'s name becomes the installed name, and
     `current_pair/2` and `mint_request/4` look the mint up and name it by the service, where today
     one `Name` serves all three; for a block drive, its grant in the
     device process, which occupies it for its whole life, and the drive's mint started in
     `erx_blk_sup` before the device process (`erx_blk_drive:start_mint/1`, the USB places' mint
     child, `erx_blk_drive_facet` and `erx_blk_drive_proxy` are built); the window proxy's charge
     of the facet's account and its pause while the share is spent (design-domains.md's
     "Processes a facet starts"), which wait for `erx_facet`'s account: its residuals in TODO.md; the facet table check passing
     `served_by drive` as it passes a session's lines; the manifest check's refusal of a service or
     facet row of `drive`; and in each board
     manifest one more of the media domain's and the serving domain's `connections` and of
     `max_connections` for each pair of media and serving domain, however many drives it carries;
     with the host tests and QEMU cases those sections' tables name;
     the release check that `erx_media` lies only in the media domain's release, which names
     no `erx_storage` or `erx_blk`, and in a release build no `erx_lfs`; the ordered end's step 2 freezing the media
     service; the shell's `mount` and `umount` forms ([todo-shell.md](todo-shell.md)). The media
     domain's durability facet to the system domain in the facet table, which `check_drive_domains`'
     list then admits, lands here too. QEMU virt's and the Raspberry Pi 4's development manifests
     each name a media domain, the service `media`, root's session's `media` facet (rights `rw`)
     and the drive `disk0` on the xhci row, so their USB domains serve a stick as `disk0`. The quotas count no system connection
     (`life_connections` in `liberx/system/dom_life.c`), so at rest the media domain's
     `connections` of 3 hold the drive connection and root's session's `media` with its
     replacement's, and the USB domain's of 2 hold the drive connection beside the display's
     `usb_input`; a peer's restart, while its old row is still closing, needs one more on the USB
     domain, 3, which the manifest's rows for other configured peers do not reckon either.
  5. The FAT server, `erx_fat`, over a FAT16 or FAT32 volume. Its read path is built (mount,
     directories, lookups and reads, with `erx_fat`'s fuzz target); what remains: its batches, dirty
     flag and finish, the write path behind them with `fat` added to `erx_media_volume`'s
     `WRITE_PATHS` (until then every FAT volume mounts `ro`, `erXos has no fat write path`); lookups through the generated simple-uppercase case table of
     design-storage.md's "Names", where they ignore only ASCII case today, so a name differing from
     a stored one only in a non-ASCII letter's case is `not_found`; the root directory's label
     entry as `sN_label` beside the boot sector's; and `erx_fat_read:root_file/3` reading through
     `erx_fat`'s core, so that FAT has one volume model and design-storage.md's "the pure read core
     ... that the FAT server reads through too" holds (today the server shares only
     `boot_sector/1`). The batches' FAT entries are built: `erx_fat_alloc` plans grows, shrinks
     and frees in the preparation, linking, cutting and release steps, the dirty flag's step and the
     finish, and `erx_fat:check/1` runs the ownership check, neither yet called by the volume. A volume whose sectors are not 512 bytes is
     `not_its_volume`.
  6. EROFS: `erx_erofs` reading through its mount's source function, with `mount_source/2` beside
     `mount/2`; `erx_media_blocks` and `erx_media_erofs`; `erx_erofs_tree` factored out of
     `erx_storage_system`; the compression refusal by name; `Erx::ErofsReads` extended to the two callers
     of `mount_source/2`; and `erx_verity`'s `unchecked` form deleted, its tests and fuzz target moved to
     `erx_media_blocks`.
  7. littlefs for development builds and test images, through its port once the port exists (the port
     item under "Stopgap replacements"): the media domain's row's `spaces none` grown to the sub-spaces
     of the ports (design-drives.md, "Manifest rows"); the owner's placement and write admission of the port's block
     requests, the port's budget, and the port's channel decoders with their fuzz targets. A steerable
     memory error in littlefs on a crafted stick reaches the port's sub-space, its own volume through
     its owner's checks, the kernel's calls and the CPU: a residual of development builds, which run only
     trusted code, and of no release, since none serves littlefs volumes.
  8. The harness: stick images from a declared tree with their files' SHA-256 (fsimg's FAT12, FAT16,
     FAT32 and EROFS; a host tool that writes a littlefs volume's files with `erx_lfs_config`; an MBR and
     a GPT writer; signature-only images of the refused formats), and the QEMU cases of design-drives.md
     in the `usb` suite, over its stick plumbing.
  * [Medium] The drive grant (`erx_blk_drive`) holds every ask that arrives while a medium ends,
    those of proxies the facet has since ended included, and answers the one window to all of them:
    the held list grows with each re-ask during a stuck end, outside any `max_heap_size`, and a
    second live asker would get a second proxy on one window. The grant should monitor each held
    asker and drop it at its end, so at most one live ask is held by construction.
  * [Medium] `erx_media_drive` makes its 60 s ask inside `handle_call`, so walks queue one behind
    another and each may ask again; the ask should go out with `gen_server:send_request/2` and its
    one answer serve every waiting caller, as "Concurrency" says two walks share one reading.
  * [Medium] The drive's facet runs without the grant's `max_heap_size`, which `erx_facet:start/3`
    applies to no facet (`erx_facet`'s heap-limit residual), though design-drives.md says the facet
    and its proxy each run with it.
  * [Low] The drive facet and proxy's untested verification cases: the facet finding the grant
    afresh across a grant's restart, its own `{error, no_medium}` while Find answers `none`, the
    proxy's end past `max_heap_size`, and the mint process itself (`start_mint/1`).
  * [Low] Smaller review findings of the drive facet, proxy and drive process: the facet's
    `init/1` checks its limits' presence and not their types, so a grant missing `exports` or with
    a bad `max_heap_size` fails at the first ask, not by a named refusal; the proxy's export module
    is the grant map's while the facet's is `erx_facet:start/3`'s option, two sources for one fact;
    a failed export crashes the proxy by badmatch instead of ending it quietly;
    `erx_media_sup:drive/1` relies on its caller's registry check and matches no `already_present`;
    the 60 s ask is written in `erx_media_drive` and `erx_blk_drive` both; the proxy's loop state
    has no type of its own; `erx_media_drive_tests` kills the proxy without waiting for its
    `'DOWN'` before the next ask, a race.
  Open findings of step 3's reviews:
  * [Medium] `erx_lfs` lies in `erx_storage`, which the media domain's release may not name, so
    step 4's littlefs volumes need it moved to an application of its own, as `erx_fat_read` moved to
    `erx_fat`, before the release check of step 4 can pass with littlefs in a development build.
  * [Medium] `erx_media_volume`'s read-only log line names the volume (`volume s1`) but not its drive,
    which the volume process does not know, so two sticks' lines read alike; pass `diskN` to the volume
    at its start.
  * [Low] `erx_media_tree` shows a drive status's `transport` and `flush` as `unknown`: the window's
    `info` answers neither (design-drives.md, "Status"). Show them once the window reports them.
  * [Low] `erx_media_tree`: a
    volume's waiting read answers its alias directly rather than through `erx_fs_waits`, as design-files.md's
    "Waiting requests" asks; a GPT entry's name and GUID do not show as `sN_label` and `sN_serial`; the
    `{volume, ...}` node carries a qid path no clause reads; `erx_media_app`'s moduledoc says the domain has no
    files facet, and `erx_fs_mint`'s does not list `media`.
  * [Low] `erx_media_sup` makes the mount counter at each of its starts, so paths stay unique while the domain
    lives only because the supervisor never restarts within it; make it only when absent.
  * [Low] A stick that stalls holds a session's `media` grant for as many window deadlines as a listing reads
    sectors; measure whether the proxy ends at the window's deadline.
* [Low] Step 4's medium reader refuses the table on a failed read of any sector `erx_media_table`
  asks for, and hands it only 512-byte sectors: `read/2` has no way to be told a sector is
  unreadable, so a read answered as zeros would make a failed sector 0 read as no table.
* [Low] `erx_media_table`'s entry size check uses `gpt_entry_min` while the name is read up to
  `erx_gpt_entry`'s size; check against the layout's size and drop the limit.
* [Low] No seeded fault covers `erx_fat_read:volume/1`'s `{fat, 16}` term weakened to `=/= not_fat`:
  add a record volume of FAT12's cluster count.
* [Low] `erx_media_probe_fuzz`'s mutated sectors are a copy of `erx_media_probe:sectors/0`; derive them.
* [Low] `fat => none`, a FAT-signed sector with no cluster count, selects `fat`; design-drives.md
  names only FAT12's refusal, so say what `status` shows for it or refuse it by name.
* [Low] Small copies of generated facts: `erx_media_probe`'s `?SECTOR`, `erx_media_table`'s
  `Type =/= 0` for `?ERX_MBR_TYPE_EMPTY`.
* [Low] Readability of `erx_media_table`: the throws inside booleans in `metadata/3` and
  `integrity/3`; `taken/3`'s mixed tuple and the partial `header_of/1`; `header/3` builds its
  `#header{}` before the header passed; `erx_media_probe` calls `boot_sector/1` twice for one
  decision; lines past 80 columns.
* [Low] The metadata rule counts a passing backup's array that FreeBSD would set aside when the two
  headers disagree (`gpt_matched_hdrs`), so it refuses some tables FreeBSD reads; it errs on refusal.
* [High] storage and apps, the system partition and the `system` tree
  ([docs/todo-system-partition.md](todo-system-partition.md),
  [design-storage.md](design-storage.md#the-system-tree)): each slot
  becomes a FAT boot partition and a read-only EROFS system partition; the
  storage domain serves the booted slot's as the `system` tree through a
  read-only `erx_fs` backend over `erx_erofs`; packages are self-checking
  files in it, mounted with
  `erx_ns:mount({erofs, Source}, ...)`; image packages leave
  the boot image under a packer check of what it may hold; `/apps` is one
  flat tree; the slot writer and the update write two partitions; image
  windows, `erx_blk_image`, image extents and the slot's release copy are
  deleted.

## Stopgap replacements

* [Medium] storage: littlefs's sub-space port, its next placement
  ([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain), "The port";
  [design-storage.md](design-storage.md#read-write-storage)): littlefs's C code in a sub-space of the
  storage domain holding its channel and data area alone, so a memory error in it reaches the port and the
  volume, not the storage domain's runtime, its DMA-capable block device or the vault's keys, which closes the
  NIF form's published downside. It waits for track S's port driver (1b-B). With it: the confinement case,
  the port's space read through `/proc` holding no handle but its channel and no mapping but its data area,
  with a port given the storage domain's window as its seeded failure, and the production image's check
  refusing a release manifest that runs the NIF form. Drives' tests need it too: a drive's littlefs volume,
  which only development builds and test images serve, runs only in the port
  ([design-drives.md](design-drives.md#littlefs-through-its-port)); no release waits for it.
* [Medium] storage: replace littlefs, which runs as a NIF in the storage domains of
  the data partition and of the vault's partition, with erXos's F2FS, written in Erlang, at parity over the file-semantics
  corpus, by gate G13. Nothing written under littlefs is converted: erXos's
  F2FS arrives by an installation, which creates both partitions afresh,
  and an update whose storage formats differ from the running system's is
  refused ([design-storage.md](design-storage.md#system-updates),
  [plan.md](plan.md)). It blocks no release: 0.2 ships littlefs
  under its release contract
  ([design-stopgap.md](design-stopgap.md#release-contract)).
* [Medium] production image, `tools/lib/erx/production_image.rb`: OTP's and musl's archives are attributed whole, though `libz`, `libzstd`, `libepcre` and `libryu` carry their own licenses. `libbeam.a`'s littlefs objects (and, in the BeamAsm flavour, asmjit's) are the one exception, by a hand-written case in `emulator_license` (`EMULATOR_ARCHIVE`) that nothing checks against the build: moving `lfs.o` out of `OS_OBJS` drops or misplaces littlefs's notice and its stopgap status silently. Replace the case with one table of the imports each archive holds, take each import's grant and notice from `config/provenance/import-notices.json`, and check the archive's members at pack time, as `CoreArchive::Built.objects` does for the boot cores.
* [Low] production image, `ProductionImage#catalog`: the build record lists Fiasco's QEMU virt
  bootstrap even when the image's first stage is the board's (`Fiasco#first_stage_path`), and a build
  packs whatever board bootstrap is on disk.
* [Low] image build, the Pi's single file against the loader's device tree (`ProductionImage::Machine#check_single_file`,
  `Fiasco#first_stage_address`): the bound starts at the entry of users-raspi4b's `bootstrap.elf`, not checked
  against the address QEMU's raspi4b model and the firmware load it at (`QemuPlan::MACHINES` loads, 0x200000). If
  they differ the check is off by the difference; confirm they agree on a raspi4b build, or take the load address
  from the platform.
* [Low] image build, the single-file check's reach (`ProductionImage#assemble`): only the production image's build
  checks its single file against RAM and the loader's device tree; `BootImage`'s images (native roots,
  `function_api`, `libc_test`) fail only at boot, at the loader or in bootstrap's `archive_no_room`. Move the check
  into `BootFile.write`, the one writer, so every image gets it.
* [Low] image build, one root place for every machine (`ProductionImage::Machine#root_mib`, `OracleQemu`,
  `MediumBoot.machine`): the oracle's machine and the medium boot's link their roots 192 MiB into RAM only to keep
  their archives below the root, which bootstrap's archive move (`kernel/core/boot_place.c`, `erx_boot_place_archive`)
  makes unnecessary. Link every root at the development place and delete `root_mib`, once a boot of the oracle's
  image with the archive moved has been measured.
* [Medium] image build, the single file's bound on QEMU `virt` (`ProductionImage::Machine#check_single_file`): the
  check accepts a file up to the end of RAM, but a moved archive goes behind the device tree QEMU puts right behind
  the file, so a boot needs RAM for the archive twice, and one with an archive over about half of RAM
  passes the build and stops at boot with `archive_no_room`. Model the move in the check: when
  the file passes the root's place on a loader that puts the tree behind the file, require the file, the tree's
  slack, the archive again, the kernel and `sigma0`, and the tree's copy and the handoff page, which the plan keeps
  clear of the loaded archive too, to fit in RAM.

## Bugs by subsystem

* [Medium] storage, create-or-open's refused truncate (`erx_media_volume:emptied/3`): a refusal
  after part of the truncate committed forgets the caller's hold of the file outright, though a
  holder is counted once however many fids name the file, so a hold an earlier walk took goes too
  and the grant and the volume disagree about the node. No medium is known to refuse a shrink to
  0; keep the hold the walk took (rethrow `refused` when nothing committed, else count holds).
* [Low] storage, the volume's finish and the usb suite: `finished/1` catches only `failed`, so a
  `refused` from `released_all/1` crashes the finish call and `terminate/2` retries the last batch;
  the suite's `RC_STEPS` and `TREE_AFTER` spell `hello.txt` rather than `Stick::FILE`, and
  `Stick`'s doc names only the list and read; `Stick.check` passes fsimg no output limit, so the
  extraction is bounded only by the 8 MiB volume; the host test's volume has no label where the
  suite's has `ERXOS`.
* [Medium] storage, the FAT volume's crash report (`erlang/apps/erx_media/src/erx_media_volume.erl`):
  a crash of the volume process logs its state, the batch's sector images among them (client file
  data), and formatting that report in the volume can pass its heap bound and kill it; a
  `format_status/1` that leaves out the batch and a write's bytes removes both.
* [Medium] storage, the FAT volume's cuts test (`test/erlang/erx_media_volume_write_tests.erl`,
  `cuts_test_`): a cut that leaves the medium `{ro, dirty}` has its tree checked by nothing, and the
  RAM proxy fails every write after the cut, so a write after a failed one is never seen; check each
  cut medium with `erx_fat:check` or fsimg's verify (lost clusters allowed) and add a proxy that
  fails one write and takes the next, with a seeded fault on `terminate`'s failed clause.
* [Medium] storage, a FAT listing's memory (`erx_media_volume:listed/3`, `erx_fat:list/2`): a
  listing holds two lists of every entry, so a directory of some ten thousand names, which a
  client of a writable volume can make, brings the volume near its memory bound; fold the
  listing a page at a time.
* [Medium] storage, the FAT volume's finish within its shutdown (`erx_media_medium.erl`, the
  volume's child spec): a volume that ends without `finish/1`, as when its medium's supervisor
  stops, finishes in `terminate/2`, and the default 5 s shutdown can end a finish that releases many
  chains on a slow stick, which then mounts `{ro, dirty}`; derive the shutdown from the finish's
  bound. An eject's `finish/1` waits on no such deadline.
* [Medium] storage, a long FAT file's chain as a list (`erlang/apps/erx_fat/src/erx_fat_dir.erl`,
  `contents/6`; `erx_fat:read/4`): a write, a cut or a read of a file holds the file's whole chain
  as a list, two words a cluster, so a file of more than some tens of thousands of clusters (about
  100 MiB at 4 KiB clusters) passes the volume's memory bound and ends the volume; the medium then
  mounts read-only as dirty. The per-fid cursor of [todo-performance.md](todo-performance.md)'s
  FAT write path item removes the list; a test writes and reads a file past the bound.
* [Medium] media, an eject waits inside the ejecting grant (`erx_media_tree:write/4` on `ctl`,
  `erx_media_drive`'s `eject`): the finish answers every request a volume holds first, so a slow or
  stalled stick with many reads queued holds the drive process, every walk of `diskN` and `status`
  open behind it, and the writer's grant, for as long as those reads take, each bounded by the
  window's deadline; a grant's callback otherwise waits on no event (`erx_fs`). Answer the eject as a
  waiting request whose keeper is the drive process, so only the writer waits.
* [High] files, a grant's heap bound does not model ERTS's collections (`erlang/apps/erx_files/src/erx_fs.erl`,
  `reserve_words/2`; `erlang/apps/erx_files/src/erx_ramfs_sup.erl`, `heap_words/1`): the bound counts the
  reserve's heap words three times, a factor measured on /tmp's deep-fid case, and `/tmp`'s tree twice for what a
  step leaves behind, but
  ERTS checks `max_heap_size` during a collection against the heaps' allocated sizes plus the heap it
  copies into: at a major collection the young and old heaps and `next_heap_size` of their use, at a
  minor one with no old heap yet about five times the young heap's use (`otp/erts/emulator/beam/erl_gc.c`,
  `minor_collection` and `major_collection`). A legal request mix near `/tmp`'s cap may then kill the grant
  at a collection, and `/tmp` restarts empty. Model the collection once, where the bound is set, over the
  reserve and the tree together, measured by a case that drives a full pool at its worst and a full tree
  through collections.
* [Medium] files, the per-fid reserve lists a fid's parts by hand (`erx_fs_grant.erl`, `fid_words/2`):
  the terms and the seven map entries it measures must follow `#grant{}`'s fields by hand; it measures
  map entries on a map of `Pool` keys where `named` and `held` reach twice that, a closing answer of
  `closed` where a remove keeps `{error, Posix}`, and a local owner and alias where a grant for another
  domain holds remote pids and references. No case fills the pool at the worst case it models (distinct
  nodes, 255-byte names, open handles, one owner per fid, a u64 qid path) and no seeded fault in
  `fid_words/2` is caught. Measure a grant state built through `add_fid/4`, `place/4` and `opened/3` at N
  and N+k fids instead, and add that case with its seed.
* [Medium] files, trees whose nodes outgrow the default (`erx_fs.erl`, `largest_node/0`): a tree without
  `largest_node/0` is counted with a node of a few words, and nothing fails when one is larger;
  `erx_procfs`'s `{dir, Path}` nodes hold a list of inspector ids that grows with depth. Declare procfs's
  bound (it has `ERX_INSPECT_NAME_MAX` names and a depth its inspector bounds) or make the callback
  required.

* [Medium] files, facet-row grants under a heap bound below their reserve (`abi/services/files.txt`,
  `max_heap_size`; `erlang/apps/erx_files/src/erx_fs.erl`, `reserve_words/2`): a facet row's grant
  runs under the row's `max_heap_size` of 262,144 words with the default pool of 4,096 fids, while
  `reserve_words/2` puts that pool alone above 1.5 million words, so a client that opens its whole
  pool kills its own grant at the heap bound rather than meeting `emfile`. The failure is safe (the
  grant ends, its client sees `eio`) and the tree's `largest_node/0` is not counted. Derive the row's
  heap bound from `reserve_words/2` and the row's pool, or shrink the row's pool to what its bound
  holds.
* [Low] storage, the system tree's node grows with its depth (`erx_storage_system.erl`, `walk/3`,
  `open/3`): a node is the list of names below `apps/` and a directory's handle its whole listing, so
  neither is bounded and the tree declares no `largest_node/0`; its grants run under the facet row's
  fixed heap bound. The image is trusted, so a deep tree costs only its own grant. Give a node a
  constant size (the image's inode number) or refuse a walk past a path of 1,023 bytes, and declare
  the largest node.
* [Low] hostlink, a malformed `Tclunk` keeps the bridge's fid (`erx_hostlink_9p.erl`, `refused/2`):
  the bridge answers a request the codec refuses on a free tag `einval` and changes no fid, so a
  `Tclunk` or `Tremove` the codec refuses leaves the bridge's fid and the grant's fid in place, where
  clunk(5) says the fid ends whatever the outcome. The host's fids stay bounded by the grant's pool.
  Have the bridge end its own fid for any `Tclunk` or `Tremove` whose fid it can read, through a
  header peek the generated codec offers.

* [Medium] files, the client's frame bound unproven (`otp/erts/preloaded/src/erx_file_remote.erl`, `posted/2`):
  the client refuses a request whose message passes `files_max_frame_min` as `erlang:external_size/1`
  measures it, which rests on two facts nothing checks. That size equals the frame's `payload_len`
  under the transport's flags (no atom cache, design-domains.md), unverified for an alias and a local
  pid against ERTS's `external.c`; and that the largest request the grammar admits, a write of
  `p9_io_max` or an xattr of `p9_xattr_max` with names, alias and pid at their bounds, fits
  `files_max_frame_min`, two limits declared apart in `abi/protocols/9p.txt` and
  `abi/services/files.txt`. Derive or check the second in the generator, and confirm the first with
  file and line or a hosted case across a real lane. If either fails, a valid request is refused
  einval or an oversized one hangs.
* [Medium] files, the windows facet's tree (`erlang/apps/erx_win/src/erx_win.erl:134`, `:326`): `erx_win`
  builds its display handle as `{Grant, ?ERX_WINDOWS_TREE_BYTES, rw}`, a second source of the tree and
  rights the registry holds with the facet, from the mint's reply and the facet row (design-files.md, "The
  tree beneath an entry"). A display server whose `root` names another tree would be installed on it and
  every attach of `erx_win` refused. Give `erx_facets` one reader that answers a tree facet's own
  `{Pid, Tree, Rights}` (`file_grant/2` answers only `ro` handles) and have `erx_win` use it.
* [Low] files, tree names a server chooses (`erlang/apps/erx_shell/src/erx_cmd_mount.erl:115`): a facet's
  tree comes from its server's mint reply, admitted as any 9P name, up to 255 bytes with spaces, and
  `mount` prints it as `PID:/TREE` through `erx_text:escape_field/1`, which keeps spaces, so a files
  server can name its tree like the rest of a mount line (`x on /etc (local)`). Narrow tree names to an
  identifier in the ABI, as every tree the ABI declares is, or escape spaces in that field.
* [Low] files, the names `erx_facets:files/3` and `erx_fs_grants:facet/3`: both build the facet of any
  service served as a tree (windows, line, input and media too), and `erx_fs_grants:rights/1`'s `rw`
  default cites only `abi/services/files.txt`; rename to say tree.
* [Low] files, a grant handle's opacity (`erlang/apps/erx_files/src/erx_fs.erl`, `grant_handle()`):
  design-files.md ("A grant handle is built by its starter") rests a handle's tree on
  `erx_fs:grant_handle()` being opaque, "so Dialyzer refuses any other construction", but no gate runs
  Dialyzer, and `erx_ns:checked/2` and `erx_prog_handler_core:window_dev/2` take a handle apart outside
  `erx_fs`. Run Dialyzer over the modules that take a handle, or have `erx_fs` own every reading of one,
  as `erx_fs:handle_tree/1` does, with a build check that no other module destructures it, as the
  `erx_ident` item of [todo-domains.md](todo-domains.md) has for identifiers.
* [Medium] storage and images, the development boot image is 68 MB (`kernel8.img` on the Pi 4 boot
  partition, 68,202,496 bytes) and stays in RAM for the whole boot; it also weighs on the Pi 4 secure-boot
  check item below. Three shrinks are open: 12.2 MB are byte-identical OTP files in both `system/lib` and
  `domains/erxos/lib`; OpenSSL (3.3 MB) is linked into both the system domain's ERTS and the domains' ERTS;
  and `public_key`, `ssl`, `ssh` and `inets` hold 8.8 MB. Each is decided by the measurement in
  [docs/todo-performance.md](todo-performance.md) ("every release in the boot image"). The packer
  bounds a file by the partition (192 MiB), so this size packs.
* [Medium] files, the lock table (`erlang/apps/erx_files/src/erx_fs_grant.erl`): `erx_fs_locks`, the tree's lock
  table and the keeper of blocking locks (design-files.md, "Locks", "Waiting requests"), does not exist yet (the grant
  serves no lock, `erx_fs_grant.erl:591`); when it is built, `erx_fs_grants` supervises it and its grants' supervisor
  `rest_for_one`, as design-files.md ("Locks") has it.
* [High] files, waiting requests (`erlang/apps/erx_files/src/erx_fs_grant.erl`, and the trees named below): the
  grant calls every callback itself and hands a read or a write that answers `{wait, Keeper, Request}` to its keeper,
  which keeps it in `erx_fs_waits`, and a clunk settles its fid's held requests first behind one table of live
  aliases, and a grant whose client has ended drains, as design-files.md ("Serving: the `erx_fs` behaviour", "Waiting requests", rules 1, 2
  and 4 to 6, "Bounds") has it; a program's `/dev/kbd` and `/dev/mouse` reads wait at its draw connection, their
  keeper, which shares one life with the handler. What is left is the one tree that still waits for an event inside
  a callback, the Bluetooth line service's `pair` file (`erx_line`, design-bluetooth.md, "The controller's line"),
  which stops its whole grant, every other request, clunk and flush of it included, until the event comes, as each
  wait for an event left in a callback does now that callbacks run in the grant. `erx_fs_locks`, the tree's lock
  table, does not exist yet (the grant serves no lock, `erx_fs_grant.erl:591`); when it is built, `erx_fs_grants`
  supervises it and its grants' supervisor `rest_for_one`, as design-files.md ("Locks") has it.
* [Medium] files, the grant's drain (`test/erlang/erx_fs_core_model_tests.erl`, `erx_fs_grant:client_ended/1`):
  design-files.md ("Verification and testing") has the core's model explore the client's end and names the seeded
  fault "a grant that ends at its client's end without its fids' clunks", but `?EVENTS` has no client-end event and
  only `erx_fs_tests:a_grant_whose_client_ended_drains_test` covers the drain. Add a `client_end` event that checks no
  reply follows it, each fid's clunk runs once and `drained/1` holds after settling, and seed that fault.
* [Medium] files, a lock table's end (design-files.md, "Locks"): `erx_fs_grants` ends every grant of its tree with the
  table, the system domain's own grants included, which are not remounted (the `own/1,2` item below), and the table's
  `max_heap_size` is not derived from a bound on the grants it serves. Name that bound and the heap it gives.
* [Low] `erlang/apps/erx_files/src/erx_fs_grants.erl`: the per-grant `Args` (`start_link/2`, `grant/4`) are not named by
  design-files.md; name them there or fold them into the grant's options.
* [Low] storage, docs (`docs/design-stopgap.md`, the paragraph on a restart: "answers its start only once the volume
  has mounted, so ... the domain reports ready, only over a mounted volume, and a mount that fails fails the domain's
  boot"): `erx_fs_mint` runs its mount after the ready report, in its own process, and holds a mint request
  until the mount is done, so the domain reports ready before the volume mounts and a failed mount ends the domain
  after its boot; design-system.md's "Providers" says so. Restate the paragraph from the mint's order.
* [Medium] storage, `erx_fs_mint` loop (`mint/3`): no host test drives the loop itself.
  `test/erlang/erx_fs_mint_tests.erl` covers `mint_request/3`, `erx_fs_grants:grant_options/1` and the
  answers `grant/5` gives, refusals included, but not that the loop (`mint/3`,
  `mint_one/3`) sends each through `erx_facet:minted/2`; drive it with a stand-in of
  `erx_facet`, as the network mint's item below asks.
* [Medium] Image build, `tools/lib/erx/source_revision.rb` (`QUERIES` branch shape): a branch name
  git accepts but the shape refuses (`fix#123`, `stas@wip`, `_tmp`, over 100 bytes) fails the whole
  image build. Either leave such a branch out of the revision, as newvers.sh leaves out a detached
  head, or widen the shape in both `BuildFacts::SHAPES` and `erx_build`, since `uname` writes the
  revision through the field escape anyway.
* [Medium] the system domain's own grants, `erlang/apps/erx_files/src/erx_fs_grants.erl`
  (`own/1,2`), `erx_machine_fs:start_link/0` and `erx_starter_fs:start_link/1`: the own grant
  is a temporary child of the grants supervisor, so one that ends alone, at its heap bound for
  instance, leaves the system shell's `/svc/machine` or `/svc/start` answering `eio` until the grants
  supervisor itself restarts, where docs/design-system.md ("A session's request", Failure)
  has it started again and remounted, as `erx_devfs` and `erx_lfs_sup` keep theirs. Each
  service also repeats the four serving steps (start the grants, `erx_facet:serve/2`, the own
  grant, `erx_ns:mount_own/2`). One function that serves a system domain's files service under
  a supervisor of its own, the grants beside a permanent own-grant child that mounts itself,
  fixes both and lets `own/1,2` go.
* [Low] files, `erx_9p` codec (`tools/lib/erx/abi_emit_wire.rb`, `abi/protocols/9p.txt`): a packed list's
  per-element size (`packed @p9_dirent_fixed`, 24) is declared rather than derived from the dirent tuple's wire
  widths, so a change to `dirent` would make the grammar's `packed_dirents/1` disagree with the bytes the codec
  writes; derive it in the generator or refuse a mismatch. `decode/2` also accepts T and R messages alike, so a
  bridge must itself refuse a reply from its client and a request from its server; split it into
  `decode_request/2` and `decode_reply/2` when the first bridge is written. The wire emitter subclasses
  `ProtocolEmitter` and reaches into its private renderers; extract a kind-check renderer parameterised by the
  alias's form if the grammar emitter's internals change.

* [Medium] storage, `erx_driver_ctl` and `erx_lfs`: a `stop` or `restart` of the
  block unit through `storage_ctl` while `/data` is in use leaves `/data` failed until
  the domain restarts, and the facet still answers `ok`. Between the stop and the start
  `erx_blk` answers `no_device`, a request it was serving exits, the window answers
  `eio`, and littlefs fails the volume on any failed block request
  (`erx_lfs.erl`, "unavailable until reboot"). A restart fails it too, by design: each
  window is bound to the device process it first reached and answers `eio` once that
  process has ended (design-stopgap.md, "littlefs in the storage domain"). Decide whether the holder's
  units name what depends on each driver, so the facet refuses a stop while it is
  mounted, or remounts after the start; the block_device cell checks only a raw read.
* [Low] storage and network, `erx_storage_sup` and `erx_net_erxos:children/1`: the
  driver-control facets' units tables, `#{block => {erx_blk_sup, erx_blk}}` and
  `#{net => {erx_net_interfaces, Name}}`, repeat the manifest's unit names by hand, and
  nothing checks them against the units the domain holds; a renamed unit is refused as
  `badarg` while the stale name works. The network's link name is the transport's, and
  `net` names a link only while the stack has one interface, so a unit of several
  network devices cannot be stopped or started. Derive each from the domain's installed
  units, or check each key at start.
* [Medium] storage, `erx_lfs`: any process of the system domain can send the owner
  `{erx_lfs_block, ...}` or `{erx_lfs, Worker, done, _}`. A forged block message fails the
  volume or, with a request of a volume of its own, writes any sector of the data window;
  a forged `done` answers one client's request with another's result. Tie each request to
  its volume in the NIF and tag each run with a fresh reference.
* [High] storage, littlefs: one open does not see another's writes. Each open is a littlefs file of its own
  (`lfs_file_t` in its slot), a write changes only the file it was made through
  (`otp/erts/emulator/nifs/erxos/erx_littlefs_nif.c:707`), and a read through another open of the same file stops at
  that open's own recorded size and block chain (`littlefs/lfs.c:3505`), so running the volume's calls one at a time
  in its worker does not show one open's write to another. design-files.md ("Serving: the `erx_fs` behaviour", "Each tree makes its own
  requests atomic") requires every open to see the file as it is, with only its access mode and position its own, and
  OTP's `file_SUITE` checks it through a reader opened before the writes
  (`otp/lib/kernel/test/file_SUITE.erl:3393-3397, 3516-3520`). Make the file's state shared across its opens in the
  port, keeping access modes and positions per open, with tests of two opens reading and writing one file, disjoint
  writes, a truncate and appends from both, regression first.
* [Medium] storage, `erx_lfs`: once the qid table is full, `listing/4` leaves out entries it
  cannot draw a qid for and numbers the next offset from the entries kept, so a listing
  repeats entries or ends early instead of answering `enfile`.
* [Low] storage, `erx_lfs`: a make whose qid draw fails leaves the new file open in its
  slot; the owner traps exits and ignores its supervisor's abnormal end; `remove/3` ignores
  the node unlink names, so it removes whatever entry has the name now; a 65,537-byte write
  (msize 65560) and a readdir offset of 2^32 or more answer `eio`.
* [Low] storage, `erx_lfs` (`clunk/2`) and `erx_fs`'s `clunk` callback, typed `-> ok`:
  littlefs commits a file's cached writes at close, and `clunk/2` drops the close's
  result, so a write that fits in the cache and fails to commit (a full volume) is
  answered `ok` at `file:close/1`. A writer that must know syncs first, as
  `erx_ssh_dev`'s host key does, since `fsync` answers the error. Let the callback answer
  an error and the grant answer it as Rlerror.
* [Medium] storage, block service: a window has no `flush` (design-storage.md, Interfaces):
  `erx_lfs` answers littlefs's sync itself (`erlang/apps/erx_storage/src/erx_lfs.erl:249-263`) and
  `erx_blk_window` has no `flush` handler, so nothing reaches the transport's `flush/0`; the transport
  split's implementation forwards it (design-storage.md, "The transport contract"), and on the SD card it
  is durable only because the start turns the card's cache off. A write is answered once the device has
  completed it, which holds across a QEMU kill but not across a power cut on a medium with a
  write cache. `erx_blk_window` answers no `flush` and the driver negotiates no
  `VIRTIO_BLK_F_FLUSH`, so a file system cannot order its writes against the medium's cache.
* [Low] storage, `erx_littlefs_nif.c`: `deadline_after` ignores `clock_gettime`'s result, and
  `CLOCK_REALTIME` is the wall clock, on the hosted build and on erXos, where the clock service
  steps it to the build date while the storage domain mounts /data, so a clock step landing
  between the deadline's read and the wait fails a block wait or stretches it. Waiting with `erx_umtx_wait` against an `erx_clock_ns` deadline fixes both
  and empties `imports.txt`'s `[only_erx_littlefs_nif]`.
* [Medium] storage, `tools/lib/erx/data_volume.rb` and the medium writers: a data volume and its
  partition's length travel separately (`ReleaseMedium.write`, `Site.fresh_medium`,
  `BlockDevice::Run#fresh_medium`), and each writer must remember to place the volume, since
  `MediumImage.create` accepts a medium without one. A volume formatted for another length, or a
  writer that forgets it, gives a /data that never mounts. `MediumImage.create` should require the
  volume, or format it itself from `data_sectors`, so every medium has one by construction.
* [Medium] storage, `erx_storage`: a data volume that fails every mount ends the whole storage
  domain after its row's restarts, so the block driver, its windows and `storage_ctl` go with
  `/data` until a reboot. Serving the domain without `/data` (erx_lfs answering a failed mount
  with an unmounted state) would keep the rest, and design.md's "served read-only or not at all"
  row wants an operator's repair or reformat path.
* [Low] storage, `erx_lfs`: the qid table is keyed by path, not by littlefs's metadata pair
  and id, and has no `forget`, so it shrinks only at a remove and fills at 65,536 paths met
  (`enfile`), unlike design-storage.md's "littlefs and FAT".

* [Low] `/tmp` (`erx_file_remote`, `erx_ramfs_core`): a `list_dir` or a `[read, directory]` open of a directory that a
  rename of another directory replaces between the client's walk and its `lopen` answers `enoent`, where FreeBSD
  answers the old listing or the new one; the tree refuses to open a removed directory, and cannot tell that open from
  a later re-open of a narrowed namespace root, which must answer `enoent` (docs/design-tmp.md). Files no longer have
  this window, since an `lopen` of a file with no name opens it. The cure by construction is a walk and an open that
  reach the tree as one step. Not reproduced; found by reading the code.
* [Medium] `erlang/apps/erx_files/src/erx_fs.erl` (`MAX_HEAP_WORDS`, 4 Mi words with shared binaries): one
  `file:write_file("/tmp/big", binary:copy(<<1>>, 16777216))` at the shell kills `/tmp`'s grant process on
  `maximum heap size reached`; the caller gets `{error, eio}` and the supervisor restarts the grant. On FreeBSD a
  single 16 MiB `write` to tmpfs succeeds. The same 16 MiB in 1 MiB writes succeeds. Split a large write into
  bounded jobs (or bound the binary a grant holds per request) so a write within the cap never kills the grant, and
  add the one-call 16 MiB write as a regression test.
* [Medium] `erlang/apps/erx_files/src/erx_fs_grant.erl`: the grant's hold bookkeeping (`held`, `named`, `loose`) has
  no test of its own: `erx_fs_test_tree` has no `forget`, so a rejected walk reply's holds (`kept_when_rejected/3`), `remove`
  and an owner's `down/3` with walked fids are seen only end to end, or not at all. Give the test tree `forget`, check in
  `fid_table_model_test_` that the tree holds exactly the walked nodes the fids name after every step, and consider
  making the forget an effect `{forget, Node}` the shell performs, so the core sends nothing.
* [Low] `erlang/apps/erx_files/src/erx_fs_grant.erl:71-72`: `lopen` and `lcreate` answer an `Iounit` of 0, which
  `erx_file_remote` reads as `ERX_P9_IO_MAX` (`otp/erts/preloaded/src/erx_file_remote.erl:515-518`), where
  `docs/design-files.md`'s operation table has the server answer 65,536 inside the machine. The two size a client's
  transfers alike; make the code answer the table's value, or the table say 0, so one statement holds.
* [Low] `erlang/apps/erx_files/src/erx_fs_grant.erl`: `add_fid` and `end_fid` push effects into the grant's state, which
  every exported step must drain, and an owner's monitor is `pending` until the shell hands its reference back with
  `monitored/3`. Thread the effects through the step's return instead, so a step that both makes and ends one
  owner's fid can never emit `{demonitor, pending}`.
* [Low] `erlang/apps/erx_files/src/erx_fs_grant.erl`, the pure core: design-files.md ("Serving: the `erx_fs` behaviour") has the core take
  each callback result and return the callbacks to run as effects, but `call/3`, `unlinked/2`, `forget_loose/1` and
  `close_fid/3` run callbacks themselves, as the module's own doc says ("The core calls the tree's callback module
  itself"), so replaying a transition repeats an unlink or a clunk instead of reproducing an effect list, and
  `test/erlang/erx_fs_core_model_tests.erl` counts clunks in the process dictionary. Make the grant's shell the
  callbacks' one executor, feeding their results to pure transitions, and correct the module doc; the forget part
  is the `{forget, Node}` effect the hold bookkeeping item above considers, so one change closes both.

* [Medium] /tmp, `test/integration/prim_file_compare.erl` `tmp_processes/1` (`:1513`):
  `RuntimePrimFileTest#test_tmp_serves_the_domain`, run by `make check-runtime-hosted`, fails on "tmpx old owners
  counted" (`:1463`, at least three processes under the old tree before the kill), in two runs out of two on the
  tree of commit 3c5b79691 with a freshly built hosted runtime, so the console and line-editor changes after it
  did not cause it. Either the tree no longer links its grant process the way `tmp_processes/1` walks (its
  supervisor's `grant` child and that child's links), or the count of three is stale; find which, and fix the
  walk or the tree, so the restart cases after it check every old owner again.
* [Low] /tmp, `test/host/erx_ramfs_test.rb`: `test_seeded_fault_2_is_caught` expects the mutant to fail
  `a_dead_owners_open_file_gives_back_what_it_held_test`, but under load (a full `make check`) the mutant runs into
  EUnit's timeout in `wait_free/3` first and the case reads `*timed out*`, so the seeded-fault test fails though the
  fault was caught; it passes run alone. Accept a timeout as caught, or bound `wait_free/3` below EUnit's timeout.
* [Medium] /tmp, the heap-bound tests miss the cases that decide the bound (`test/erlang/erx_ramfs_tests.erl`;
  [design-tmp.md](design-tmp.md#verification)): the fills use 4 KiB chunks, which live off the heap; the
  worst tree, its cap full of empty files, directories and links (`o` about 1 by `erx_ramfs`'s own comment),
  is never built; the pool is clones sharing one path of 1-byte names, never 16 unshared steps of 255-byte
  names; the 32 MiB chain stops at 1,024 directories ([watch list](todo-performance.md)); no seeded fault
  counts the tree's part once, so the doubling is unproven; and the cases run in EUnit on stock's emulator,
  not the hosted runtime the design names. The watch-list item measuring `o` the design cites is missing.
* [Medium] files, the grant's bound defaults are copied (`erx_fs`, `erx_fs_grant`, `erx_ramfs_sup`): `erx_fs`'s
  `DEFAULT_POOL`, `DEFAULT_IN_FLIGHT` and `DEFAULT_MSIZE` repeat `erx_fs_grant`'s, `erx_ramfs_tests` repeats
  the pool, and `erx_ramfs_sup:heap_words/1` computes the reserve for `#{}` rather than the options the grant
  gets. Compute the reserve from the bounds `erx_fs_grant:new/1` resolves, in one place.
* [Medium] files, a tree of the grant's own has no grant-core test (`erx_fs_grant`, `erx_fs_grant_fuzz`,
  [design-files.md](design-files.md#serving-the-erx_fs-behaviour)): the fuzz target, the model and
  `erx_fs_tests` serve only handles; that a rejected reply keeps the own tree's step
  (`kept_when_rejected/3`) and that a non-pair answer ends the grant are untested, so dropping the kept tree
  passes every test. Add an own tree to `erx_fs_tests` with both cases, or an own-tree variant to the fuzz
  target.
* [Low] /tmp, `erx_ramfs_sup` under `kernel_safe_sup`
  ([design-tmp.md](design-tmp.md#starting-and-mounting)): a crash of `/tmp`'s grant that recurs
  on every restart, such as one a request reproduces, passes `kernel_safe_sup`'s restart intensity, which
  ends `kernel` and halts the node. A Phase 1 residual: `/tmp` is the domain's own, so the domain ends
  with it. The restart test of [/tmp's verification](design-tmp.md#verification) covers one crash,
  not a recurring one; a recurring crash would want `erx_ramfs_sup` to give up on `/tmp` alone.
* [Low] /tmp, `erx_ramfs_serving`: the serving set's `xref` closure follows only calls it can
  name, so a module a serving process reaches through `apply/3` or a fun value it was handed is
  not in it. Two seeded faults of [/tmp's verification](design-tmp.md#verification) are not caught by
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
* [Medium] Object store, `kernel/core/object.c`: `erx_object_init` writes
  the state word and the counts of any record it is given, so a call on a
  published record would move it back to LIVE; add a `Callers` rule that
  only the allocation funnel calls it once that funnel exists, and a
  syntax-tree rule that within `object.c` only `erx_object_init`,
  `erx_object_cap_remove` and `erx_object_close` write `state`.
* [Medium] Object store, `kernel/core/object.c`: no test runs two threads,
  so the memory orders of `erx_object_put`, `erx_object_close` and the id
  counter are unchecked. Add a pthread host test under TSan and ASan:
  refs and puts racing a final put that frees the record, a close racing
  the last `erx_object_cap_remove` (one close returns true, the state ends
  DELETED), and concurrent creations on one store (distinct ids).
* [Low] Object store, `kernel/core/object.c`: the reserved object id
  (zero) is hand-written in `oid_reserved`; declare the reserved encodings
  in `abi/erx_abi.txt` and generate the set. `ERX_KERNEL_DEBUG`, which
  turns on the epoch check in a target build, is defined by no build yet.
* [Medium] storage, the default configuration: the block driver and the
  data partition's file system share the storage domain, so a storage
  domain's restart drops every window on the medium and a logic bug in the
  file system runs beside the device NIF. Decide whether the release
  configuration gives the block device a domain of its own, and measure
  the extra connection's cost with `tools/erx bench blk`
  ([design-storage.md](design-storage.md#risks-and-open-questions)).
* [Low] storage, the boot-selection record: a torn record leaves the
  update service refusing every update until an installation writes the
  record afresh, since no normal boot may rewrite it. Consider a repair
  through a trial, on the boards whose firmware can request one
  ([design-storage.md](design-storage.md#risks-and-open-questions),
  [design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record)).
* [Low] storage, FAT and littlefs: a file closed and reopened may get a
  new qid path, since those formats draw paths from the domain's counter;
  stable paths across a close would need a persistent identity the formats
  lack ([design-storage.md](design-storage.md#data-model)).

## Security residuals

* [Low] files, a path-named grant's moved root (`erlang/apps/erx_storage/src/erx_lfs.erl`, `root/1`;
  design-files.md, "Version and attach"): a grant's root identity is fixed at its start, so a rename or
  removal of its root directory through another grant leaves it failing until it is restarted, and a
  directory made later at the same path is served while a walk of no names from `NOFID` records the old
  identity. Restarting the grants rooted at a moved directory, or refusing the move, would close it.
* [Medium] storage, a window served to another domain (`erlang/apps/erx_blk/src/erx_blk_window.erl`;
  [design-storage.md](design-storage.md#data-model), "The block service"): a client in another domain
  reaches its window directly, outside any facet, so one that sends requests without waiting for their
  answers queues them on the window without a bound the grant declares, and its requests' work is
  charged to no account. A drive's window has a proxy under its grant's admission
  ([design-drives.md](design-drives.md#how-the-grant-reaches-the-media-domain)); the storage domain's
  windows to other domains need the same, or a bound of their own, before an untrusted domain holds one.
* [Medium] USB, a USB domain's holdings (`tools/lib/erx/manifest.rb`; [design-usb.md](design-usb.md)):
  the rule that a USB domain holds its controller's unit and nothing else, which keeps what drives a
  stick from parsing anything, has no check, as the media domain's and a block drive holder's
  allow-lists have (`check_drive_domains`).
* [Low] storage, a host writing beside the boot-selection record (`erlang/apps/erx_fat/src/erx_fat_read.erl`;
  [design-storage.md](design-storage.md#removable-media-fat)): a computer that writes the `ERXOS` volume,
  copying `authorized_keys` or its own metadata (macOS's `.Trashes`, `._` files, `.fseventsd`), may put clusters
  beside the record in its erase unit, and a card pulled mid-copy, or a flash erase of that unit, can tear the
  record, after which the card no longer boots and is written again. Bad-cluster marks over the rest of the unit,
  or a filler file the image build places there, would keep host writes out of it; neither is made, since the
  keys are read only until the first boot imports them.

* [Medium] Storage domain, littlefs's and the block driver's failures end the whole domain
  (`erx_lfs.erl`, `erx_lfs_sup.erl`, `erx_storage_sup.erl`, `erx_blk_sup.erl`): any end of
  littlefs's owner, worker or `/data` grant, and any end of the block driver's device or
  partition process, a malformed completion (a broken queue) included, ends the storage
  domain, the block driver and every window it serves with it, and after `restarts 5`
  within `restart_period_s 600` the domain stays down. The system domain and root's
  session reach `/data` through the `data` facet, so a client whose requests can end
  littlefs's owner or worker, or break the volume, six times in a minute takes down
  every partition's driver, not only `/data`. The facet's design bounds what a client can make the grant do (its own lane),
  or littlefs moves into a sub-space port whose end the domain survives
  (design-storage.md), which waits for track S's port driver (1b-B), so no build
  yet ends only a port on a littlefs crash. A device that fails six times in ten minutes
  keeps the domain down too.
* [Medium] Storage domain, file data in crash dumps (`erx_blk_window.erl`, `erx_blk.erl`,
  the `erx_fs` grant): a littlefs failure halts the storage node, whose crash dump goes to
  the domain's crash area (design-runtime.md). `erx_lfs`'s owner and worker are
  `sensitive`, so the dump shows no heap, stack or messages of theirs, but the windows,
  the block driver and the grant are not, and their heaps and queues can hold sectors of
  `/data`. Mark them sensitive, or keep file data out of the crash area, and test that a
  dump after a write holds none of its bytes.

* [Medium] Storage domain's write authority (`erlang/apps/erx_blk/src/erx_blk_service.erl`
  `serve/1`, `config/manifest/qemu-virt-development.txt`): the block driver starts a writable
  window on every partition role of the layout but the system partitions (record,
  `boot_a`, `boot_b`, vault, data)
  whatever the manifest's window rows say, so the storage domain, which holds the block unit
  and also runs the littlefs NIF over medium data, can rewrite the boot slots and the
  boot-selection record that the manifest gives the system domain (property 8) and the vault
  that PW1 gives only the vault's storage domain. A fault in that domain, say through a crafted
  littlefs image, could persist across reboots. Have the driver serve only the windows the
  domain library names for its own domain (data, the image and `system`), refusing boot,
  record and vault roles outside the slot writer's domain, with a test that a request for
  them fails. The `system` window is read-only, but the writable `boot_a` and `boot_b`
  windows show the gap: the slot writer's `system_a` and `system_b` windows are not served
  until that grant exists, so the driver's domain writes no system partition.
* [Low] `erlang/apps/erx_files/src/erx_fs.erl`: a grant takes a keeper's answer at its wait's alias and a fid
  owner's `DOWN` by matching Erlang references, which a process that can guess one can forge (`list_to_ref/1` on the
  server's node, a crafted external term from a client node). A forged answer can only answer the client's own request
  in flight early, and a forged `DOWN` clunk a fid early. Bind both to the sender when erXos's kernel carries a
  sender with each message.

* [Medium] Origins from other machines (edit 16 of design-runtime, `erx_fs_grant.erl`
  `decode/2` and `of_client/2`, gen_server's `{erx_serve, any}` check): an envelope's
  `D` is the creation of the distribution entry a message came on, and
  `erx_dist:owner/1` the creation a name carries, neither with its node name. A node
  of another machine connected to an exposed domain chooses its own creation in the
  handshake, so once a network carrier exists it can present a domain's id as `D`
  and in the names it builds, and an `erx_fs` grant for that domain admits its frames.
  Checking the node name beside the id does not close it, since such a node can build
  names at any node. Settle it before the network carrier lands: give envelopes from
  network entries a `D` no domain id can equal, and add the test that a remote node of
  creation equal to a client's id is refused at its grant.
* [Medium] File clients (`erx_file_remote.erl`, `arrived/1` and `take/2`): an alias stays active
  until its reply arrives and the wait while the server lives has no deadline, so a
  server of another domain can hold a request open and send its alias, or the
  caller's pid it was handed as the owner, messages of any other shape without limit;
  they stay in the caller's mailbox, the code server's included, and each receive
  rescans them. Bound what a caller keeps from a server (a deadline, or dropping what
  arrives at the alias that is not its reply) with a test of a flooding server.
* [Medium] erx_fs grant fuzz (`test/erlang/erx_fs_grant_fuzz.erl`): every sequence
  runs a grant for its own domain, and the model's "a reply goes only to the client's
  domain" is stated by node, so the funnel's path for another domain's client
  (`decode/2`'s envelope clause, `of_client/2` by id) has only the unit cases of
  `erx_fs_tests.erl`. Run part of the sequences with an integer client, its frames in
  its envelope and its names built with that creation.
* [Low] erx_fs grant client (`erx_fs_grant:new/1`): a grant whose `client` is the
  server's own domain id, not `own`, drops every frame, since its own domain's frames
  arrive bare; nothing refuses that option. Refuse it, or take it as `own`, in
  `erx_fs:init/2`.

## Planned features

* [Low] storage, a drive's `status` and `ctl` at `/svc/media`
  ([design-drives.md](design-drives.md#the-media-tree), [design-app-trees.md](design-app-trees.md)): every
  other service's control tree is at `/svc/NAME`, and `/media/diskN` keeps its `status` and `ctl` beside the
  volumes, so `cp -r` and a file manager meet them. Moving them is accepted in principle and needs a design of
  its own: one grant of the `media` tree cannot appear as files at `/media` and as control at `/svc/media` as
  things stand, since `/svc` lists facets of interface `svc` while the tree's is `media`, a grant names one
  tree root, and mounting the grant twice shows the same mixed tree twice. The design chooses a rule that
  selects each place's part (one `place/1` row with two mount points, or a second, derived `svc` service of the
  media domain), the `eject diskN` grammar of `/svc/media/ctl`, a top-level `status`, and the changes to
  `erx_media_tree`, its tests and the QEMU cases.
* [Medium] storage, one drive allocator for the machine
  ([design-usb.md](design-usb.md#mass-storage-reaches-the-file-servers)): a medium takes the lowest
  free drive among those the manifest names for its USB domain's controllers, which is the machine's
  lowest free drive number only while USB is the one transport serving media as drives and its
  manifest names `disk0` upward without a gap. When a second transport serves media as drives (an SD
  card's removable partitions), or a second domain holds USB controllers, design the one allocator
  they share, so a medium takes the lowest free number on the machine, and the bound on drives across
  the machine with it.
* [Low] storage, FAT's dirty flag cleared when a drive's volume goes idle
  ([design-storage.md](design-storage.md#removable-media-fat)): the FAT server sets the flag before a
  volume's first change and clears it only at the volume's finish, so a stick pulled without `eject`
  after any write mounts read-only on erXos until another machine repairs it. Clearing the flag after a
  batch with nothing waiting, and setting it again before the next change, would leave a stick pulled
  while idle clean and keep "a volume whose flag is clear has no change half made"; it costs two
  flushes for each burst of writes and wear on the FAT's first sector, neither measured.
* [Low] storage, raw access to a drive's medium ([design-drives.md](design-drives.md#alternatives-considered)):
  a file `data` in the drive's directory, the medium whole, served by the media domain through an
  administrator's facet and opened only while the medium is idle, with FreeBSD's `newfs_msdos` and
  `fsck_msdosfs` as programs over it. No release consumer needs it yet.
* [Low] storage, compressed EROFS images on drives ([design-drives.md](design-drives.md#erofs-unauthenticated)):
  the media domain serves uncompressed EROFS volumes only and refuses a compressed one by name. LZ4 first,
  then LZMA, DEFLATE and Zstandard, the other algorithms EROFS defines, would make the images Linux's
  `mkfs.erofs -z` writes readable. LZ4 is also the decompressor design-storage.md names for the slots'
  system images should the media lack room, so one per-byte primitive would serve both; on a drive it
  parses a stranger's compressed bytes in C in the media domain's runtime, which its design must weigh,
  with a fuzz target of its own.
* [Medium] storage, a card image that holds only what is written
  ([design-storage.md](design-storage.md), `abi/medium.txt`, the image packer): order the
  partitions with the populated ones first (record, system A, boot A), end the image after boot
  A's last used cluster, and let the partition table describe boot B, system B, the vault and
  data beyond the image's end; first boot formats the vault and data (data taking the rest of the
  card), and the B slots stay empty until an update writes one. A reused card holds old bytes
  there, so the record carries a first-boot mark and no such partition is read before it is
  formatted. About 100 MiB to write instead of 718 MiB. Needs a short design first, and a QEMU
  test that boots a truncated image on a card full of old bytes. Covers growing the data partition
  at first boot.
* [Medium] storage, the release medium for QEMU (`tools/lib/erx/medium_image.rb`,
  `tools/erx pack --medium`): its slots hold no FAT: the bootable file lies at `medium_slot_boot_start`
  after 4 MiB of zeros, where
  [design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record)
  places it inside the FAT's file. The EROFS image in the slot holds a copy
  of the whole system release, its manifest excepted, which no domain
  mounts while the storage domain holds the block unit (next item), and the boot
  image holds the release too, from which the system domain starts, until
  the boot from the medium decides which releases leave the boot image
  ([design-storage.md](design-storage.md#data-model)).
* [Low] storage, long-name case in `erx_fat_read` (`erlang/apps/erx_fat/src/erx_fat_read.erl`, `upper/1`;
  [design-storage.md](design-storage.md#removable-media-fat)): the read core maps only ASCII letters to upper
  case before comparing long names, where the design compares after mapping every Basic Multilingual Plane code
  unit through a case table generated from Unicode's character database; so a name whose letters differ only by
  a non-ASCII code unit whose simple uppercase is an ASCII letter (U+0131, U+017F) is not found, which fails safe for
  `authorized_keys`. The FAT server, which needs the table, generates it and `upper/1` takes it.
* [Low] storage, FAT's format constants have two copies (`tools/lib/erx/fat_volume.rb`, `FAT16_MIN`, `FAT32_MIN`,
  the entry markers and attributes; `erlang/apps/erx_fat/src/erx_fat_read.erl`, the same as macros): an
  `abi/formats/fat.txt` would give both, and the FAT server, one source, as `abi/formats/erofs.txt` does for EROFS.
  The test fixture (`test/fixtures/fat_record_volume.rb`) and the fuzz target keep their own values on purpose, as
  oracles independent of the reader.
* [Medium] storage, `erx_fat_read` over a volume another writer made (`test/host/erx_fat_read_test.rb`;
  [design-ssh.md](design-ssh.md#verification)): every case and fuzz seed is a volume of
  `test/fixtures/fat_record_volume.rb`, written from the same reading of the FAT specification as the reader, where
  the design's row reads volumes fsimg writes; a shared misreading would refuse every real card. Add a case over
  the record volume `RecordVolume::ARGUMENTS` has fsimg write (`not_found` proves its layout is admitted), and one
  that finds an `authorized_keys` fsimg placed beside the record.
* [Medium] storage, the reset count's encoding (`abi/medium.txt`, `tools/lib/erx/pi_medium.rb`): no encoding of the
  count is defined, so the Pi card's writer leaves its sector the zeros fsimg writes in the reserved area instead of
  the count's first value (design-platforms.md, "Slots and the boot-selection record"), as the QEMU medium does.
  Define the encodings in the layout file when M12 builds the count, preferably with an all-zero sector reading as
  zero so a fresh medium needs no write, and have both medium writers write the first value.
* [Low] storage, the release image across domains (`liberx/system/dom_apply.c`,
  `erlang/apps/erx_blk/src/erx_blk_service.erl`, `erx_blk_image.erl`): with the block
  unit held by the storage domain, no image window is served
  ([design-fiasco.md](design-fiasco.md#the-booted-slot)): the storage domain's
  namespace holds no manifest, and `erx_blk_image` picks only windows the system domain
  holds. Nothing outside tests reads `/images/release` yet. When a reader appears, have
  the domain library write each image window's placement (image name, format, extent)
  into the holder's boot page beside `-erx_record boot`, and have `erx_blk_image` read those
  words instead of the manifest file.
* [Low] storage, log lines at every boot (`erlang/apps/erx_blk/src/erx_blk_service.erl`
  `image_windows/0`, `mount_images/0`): in the storage domain the driver logs that the manifest
  cannot be read and that no image is served or mounted on every normal boot, which reads as an
  error. Skip the manifest read outside the system domain, or log it once as information,
  until the image placement reaches the holder's boot page (the release image item above).
* [Low] storage, slot windows (`config/manifest/qemu-virt-development.txt`,
  `tools/lib/erx/manifest.rb` property 8): the six slot-writer windows (`boot_a`,
  `boot_b`, `system_a`, `system_b`, `boot_selection`, `reset_count`) are held by the system domain, as property
  8 requires of the slot writer, but their driver runs in the storage domain and no
  grant carries slot writes from the storage domain to the system domain, so the rows
  describe a grant nothing implements. The slot writer needs that grant (a facet of the
  storage domain's driver, or the device service's window grants, PW1) before it writes.
* [Low] storage, the boot-selection record (`abi/medium.txt`): the record and
  the reset count each have a MiB of their own, the layout's alignment taken as
  the erase unit; SD cards commonly erase 4 MiB, under which the record
  partition's FAT, the record and the count share one unit, against the
  isolation of [design-storage.md](design-storage.md#system-updates).
  Measure or look up the boards' cards before the slot writer writes the count
  at every boot; the reset count's own encoding is undefined until then too.

* [Low] files, fid pools: a root grant's fid pool is shared by the
  session and every program under it, with a quarter kept back for the
  root ([design-files.md](design-files.md)). Give each derived
  grant a pool carved from its parent's, so one program cannot exhaust a
  sibling's opens.
* [Medium] storage, FAT: a FAT file server in Erlang, in a storage domain
  that holds only its own partition's window, for removable media and for
  exchanging files with other machines. Booting and updates need none: the
  firmware reads the slots' FAT, and an update writes whole slot images
  ([design-storage.md](design-storage.md)).
* [Low] storage, F2FS per-file encryption: erXos's F2FS implements the
  `encrypt` (fscrypt) feature flag, so a principal's files are encrypted
  at rest under a key the vault hands the storage domain through a key
  facet, with Linux as the oracle for the on-disk format. Until then the
  flag is refused, as every unimplemented feature is
  ([design-storage.md](design-storage.md#read-write-storage)).
* [Low] storage, F2FS compression: the `compression` feature flag, when a
  consumer needs it, with its per-cluster work in a per-byte primitive.
  Until then the flag is refused, as every unimplemented feature is
  ([design-storage.md](design-storage.md#read-write-storage)).
* [Medium] storage, the data partition: a medium as packed holds the layout's minimum data partition, 128 MiB,
  and the medium ends there, so a card writes fast and the rest of a larger card lies unused. Grow the data
  partition to the medium's end at first boot, as Raspberry Pi OS grows its root file system: rewrite the data
  partition's extended boot record and the master boot record's extended entry, which the block driver already
  admits at any length up to the medium's end (docs/design-storage.md, "The boot medium's table"), and grow the
  littlefs volume. It needs its own design first: who may write the table (only the slot writer writes the
  record and slots today), how a power cut midway is recovered, and how littlefs grows in place.
