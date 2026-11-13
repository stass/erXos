# QEMU's raspi4b SD controller with a card attached: a model check

Checked on 2026-11-12 on an Apple Silicon Mac (macOS, Darwin 27.0.0) with
Homebrew's QEMU 11.1.3 (`qemu-system-aarch64 --version`), machine `raspi4b`,
TCG, by observing QEMU's command line and its human monitor only; no QEMU
source was read. The check is the model half of the SD controller's
record ([design-platforms.md](design-platforms.md), "The model's SD
controller"; [design-storage.md](design-storage.md#the-sd-host-controller)):
whether a card attaches to EMMC2's bus, what the capabilities register
reads and whether an interrupt status reaches the controller's output. It
was timeboxed and ran on the bare machine with the CPUs held at reset
(`-S`), not on erXos's image, since no driver of the image touches the
controller yet.

## Command

```
qemu-system-aarch64 -M raspi4b -S -display none -serial null -no-reboot \
  -monitor unix:mon.sock,server,nowait -gdb unix:gdb.sock,server,nowait \
  -drive if=none,id=card0,file=card.img,format=raw \
  -device sd-card,drive=card0,bus=/generic-sdhci/sd-bus
```

`card.img` was a 2 GiB file of zeros (`mkfile -n 2g`). Registers were read
with the monitor's `xp /1wx ADDRESS` and written through the gdbstub with
lldb (`process connect unix-connect://...`, `memory write -s 4`), with the
CPUs stopped, so the MMU was off and addresses were physical.

## Findings

1. **Two SDHCI controllers, two buses named `sd-bus`.** `info qtree` lists
   two `generic-sdhci` devices, each with `sd-spec-version = 3`,
   `capareg = 0x52134b4`, `pending-insert-quirk = true` and a child bus
   named `sd-bus`; `info mtree` puts their windows at `0xfe300000` and
   `0xfe340000`, `0x100` bytes each. The second in qtree order carries a
   card of its own wired to drive id `sd0`, the default `-drive if=sd`
   drive, so a drive given the id `sd0` is refused ("Device with id 'sd0'
   already exists"); `card0` works.
2. **`bus=/generic-sdhci/sd-bus` reaches EMMC2.** With the card attached
   by that path, `info qtree` shows it (`drive = "card0"`) on the first
   `generic-sdhci`, and the present state at `0xfe340024` reads
   `0x01ff0000`: card inserted, state stable, card-detect pin and write
   protect switch high (write enabled), DAT[3:0] and CMD high. The legacy
   controller's present state at `0xfe300024` reads `0x01fa0000`, card
   inserted clear.
3. **Capabilities.** `0xfe340040` reads `0x052134b4`, as the record of the
   model's controller says (design-platforms.md): timeout clock 52 in MHz
   units, base clock 52 MHz, 1024-byte maximum block, high speed, 3.3 and
   1.8 V, and neither SDMA nor ADMA2. The legacy controller's `0xfe300040`
   reads the same word. The host version at `0xfe3400fc` reads
   `0x24020000`: specification version 3.00, vendor version `0x24`.
4. **An interrupt status reaches the controller.** After writing all ones
   to status enable (`0x34`) and signal enable (`0x38`), `0x00000005` to
   clock control (internal clock and SD clock on; it then reads
   `0x00000007`, internal clock stable), `0x00000f00` to power (bus power
   on, 3.3 V) and `0x00000000` to the transfer mode and command word
   (`0x0C`, CMD0 with no response), the interrupt status at `0x30` reads
   `0x00000041`: command complete and card insertion, the second raised
   when its enable was set, as the model's pending-insert property names.
5. **Not observed: the GIC line.** The monitor's `xp` printed nothing for
   the GIC distributor's set-pending registers (`0xff841210`, the word
   holding interrupt 158), so this check does not show that EMMC2's
   output reaches GIC interrupt 158. That interrupt 158 is SPI 126 (the
   GIC binding's offset of 32) and that the model joins EMMC2's output
   with the legacy controller's on it stay as the design records them,
   unverified by observation; the SD driver's first model test, which
   binds the line and takes the command-complete interrupt, settles it.

## QEMU's `sd-card` model: how it sizes a medium

Read on 2026-11-13 from QEMU's `hw/sd/sd.c` at tag v11.1.3, fetched over
HTTPS from `raw.githubusercontent.com/qemu/qemu/v11.1.3/hw/sd/sd.c`
(3318 lines, SHA-256
`5dbc570c20b8b2b935de0fc5a15d65e740b08d375fc9e42a1dcabb53d0b50fcc`, the
hash [design-storage.md](design-storage.md) pins). This section was
written by an agent that read the file as data, ran nothing from it, and
quotes no code. Each fact was checked by reading the cited lines of that
file only; none was run against a QEMU binary, so none is a behaviour
observation. Line numbers refer to that file at that tag. "Image size"
means the size of the backing drive in bytes, after subtracting the eMMC
boot and replay-protected partitions, which are zero for an SD card.

1. **The boundary is 2 GiB.** The model defines its largest standard
   capacity as 2 GiB (2^31 bytes; line 59). A card of exactly 2 GiB or
   less is standard capacity (SDSC); a card of more than 2 GiB is high
   capacity (SDHC/SDXC). Every capacity decision compares against this
   one constant (lines 414, 600, 2038, 2068, 2111, 2404, 2710).
2. **How the card reports the class.** At power-up the card sets the
   high-capacity bit in its operation conditions register only when the
   size is above 2 GiB (lines 405-416; the bit's meaning, line 394).
   The card-specific data register comes in two forms. For 2 GiB or
   less it is the version 1 form, with a 512-byte block and the device
   size counted in 512-byte-block multiples (lines 600-624). For more
   than 2 GiB it is the version 2 form, whose device size counts units
   of 512 KiB, minus one (lines 626-642). A card of exactly 2 GiB is
   special: the model switches its reported block length to 1024 bytes
   so that the size still fits the version 1 field (lines 594-598).
   Addressing follows the class: SDSC uses byte addresses and SDHC uses
   512-byte block numbers (lines 2038 and 2404 select on the same
   boundary; lines 901 and 911 show the block-number shift).
3. **Accepted image sizes.** Checked when the card is realized
   (lines 3120-3141):
   * Up to 2 GiB: the size must be a power of two. A size of zero or
     an unreadable size skips the check (the tests are for sizes above
     zero). The smallest size the check itself admits is therefore 1
     byte; the CSD arithmetic assumes a real card size, so sizes below
     one 512-byte block are not meaningful (unverified beyond the
     check).
   * Above 2 GiB: the size must be a multiple of 512 KiB. There is no
     power-of-two rule there, and no upper limit in this function.
   * An eMMC device (not the `sd-card` type) is checked differently
     above 2 GiB: a multiple of 512 bytes. It is mentioned only because
     the same function serves both; the SD case is the one above.
4. **The refusal.** A size that breaks the rule makes device creation
   fail with an error that says the SD card size is invalid and prints
   the offending size. A hint follows: the size has to be a power of
   two (or a multiple of 512K), gives the next valid size above the
   given one as an example (the next power of two, or the next multiple
   of 512 KiB), and advises resizing the image with `qemu-img resize`,
   noting that shrinking loses data (lines 3079-3098, 3138-3142). QEMU
   exits at start-up; no card appears.
5. **Other facts a harness needs.**
   * A drive that cannot be opened for writing is refused, with an
     error saying a read-only drive cannot be used as an SD card
     (lines 3115-3118). A harness cannot present a read-only medium
     through this model; write protection is a separate property of the
     controller's switch.
   * The model asks the drive for consistent-read and write
     permission (lines 3148-3150).
   * The model's specification version defaults to the highest it
     accepts, labelled in a comment as really version 4.5 (lines 3201,
     3211-3212); values outside the accepted range are refused
     (lines 3105-3112).
   * Capacity is a property of the image size alone. There is no
     property that forces SDSC or SDHC on a given size, so a harness
     chooses the class by choosing the size: at most 2 GiB (a power of
     two) for SDSC, above 2 GiB (a multiple of 512 KiB) for SDHC/SDXC.
     For SDHC the smallest accepted size is 2 GiB + 512 KiB.

## erXos's SD driver on the model: interrupt 158

Checked on 2026-11-13 on the same host with Homebrew's QEMU 11.1.3,
machine `raspi4b`, TCG, four CPUs, booting erXos's Pi image with its
own 2 GiB card image on EMMC2's bus (the raspi4b suite's
`tcg-sd-card` cell, `tools/lib/erx/raspi4b_shell.rb`). This settles
finding 5 of "Findings" (the GIC line) by the driver's own behaviour,
not by reading the GIC.

1. **Interrupt 158 fires.** The storage domain's device process
   (`erlang/apps/erx_blk/src/erx_blk_sd.erl`) takes every event of
   identification from deliveries of the record's line, record line
   158 ([design-platforms.md](design-platforms.md), "The model's SD
   controller"); `await/3` has no path that reads the interrupt status
   without a delivery. Identification completed and the process logged
   `erx_blk: SD card, standard capacity, 4194304 sectors, 4-bit bus at
   13000000 Hz`; 4194304 sectors of 512 bytes is the card file's
   2147483648 bytes. The block service then admitted the partition
   table (`partition table admitted; 5 windows`), littlefs mounted its
   volume, and two blocks written, flushed and read back over the
   driver matched, as did the same bytes at that sector of the card's
   file after QEMU exited.
2. **A single-block read raises buffer read ready.** An image whose
   driver has the `await` of `buffer_read_ready` removed from the
   single-block read clause of `data/6` in `erx_blk_sd.erl` refuses
   identification at the SCR with
   `{unexpected,transfer_complete,buffer_read_ready}`: the event queued
   after the command's completion was buffer read ready. Whether it
   came in the same interrupt word as transfer complete, where
   `erx_blk_sd_host:decode/1` orders the two, or in an earlier word was
   not recorded.
