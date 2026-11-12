# The first Raspberry Pi 4 board pass

A point-in-time record of the first manual pass of
[design-platforms.md](design-platforms.md#trying-a-card-on-a-board) on a
real board, part (a) of
[plan.md](plan.md#1b-i-the-raspberry-pi-4-on-the-stopgap), stage 5, "The
board". The owner ran it by hand on 2026-11-12. This record states what
the owner reported and what the probe runs on the same board showed. It
was written from those reports, not from a serial log: the log is not in
the tree and this record quotes no line of it that the reports do not
give.

## Setup

* **Board.** A Raspberry Pi 4 Model B with 4 GB of memory, board revision
  `c03112`.
* **Console.** A 3.3 V USB-serial adapter on the 40-pin header's GPIO 14
  and 15, at 115200 baud, on an Apple Silicon macOS host.
* **Card.** The image `make pack PLATFORM=raspi4b` builds at master
  commit `42fd470d1`, `build/production-image/raspi4b/sdcard.img`, SHA-256
  `8d4ff556c3f9cdbd9e581467666bae5445a91804c6345086cf6ff718e9a92204`,
  written to the card with `dd`.
* **Firmware.** `start4.elf` from the `raspberrypi/firmware` repository,
  commit `6f0881cb`, release 1.20260915.
* **BL31.** TF-A v2.15.0.
* **fsimg.** Commit `807cd027`, the pin master `42fd470d1` holds.

## Procedure

The procedure is the one in the design document: build the card, write it
with `dd`, put it in the board, open the adapter and power the board. The
owner also ran probe cards, built for the occasion and not kept in the
tree, to learn what the firmware does with the UART and the device tree
(see "Probe runs" below).

## Observations

### The card of master 42fd470d1

* The board boots from the card through the whole chain: the firmware, TF-A
  BL31, erXos's bootstrap, Fiasco, the root task and the command shell,
  whose `%` prompt appears on the console. The owner's verdict: "pi card
  works great".
* The firmware's own log says `MEM GPU: 76 ARM: 948 TOTAL: 1024`, which
  matches the `total_mem` and `gpu_mem` settings of the card's
  `config.txt` and the memory line
  [design-platforms.md](design-platforms.md#trying-a-card-on-a-board)
  expects.
* `ls /data` prints `I/O error`. This is expected: the board has no SD
  controller driver yet, which is part (b) of the plan's 1b-I.

### An earlier card that failed

An earlier card built from the tree before `807cd027` did not boot. The
boot ROM said `start4.elf not found`. The cause was that `fsimg` wrote
numbered FAT short names (`F0000009` and the like) for the boot
partition's files, and the boot ROM reads only 8.3 names. `807cd027`
fixes the writer, and the card build now checks the names.

### Probe runs

Probe runs on the same board, with firmware and BL31 as above, showed:

* BL31 enters its next stage (BL33) at `0x200000` in EL2 with `x0` holding
  the device tree's address, `0x2eff5f00`. The stub header at the start of
  `kernel8.img` read: magic 0, `dtb_ptr32` `0x2eff5f00`, `kernel_entry32`
  `0x200000`.
* The firmware does not rewrite the device tree's `serialN` aliases, so
  the card's tree decides which UART `serial0` names.
* With `enable_uart=1` the firmware puts GPIO 14 and 15 in ALT5, the mini
  UART, whatever `gpio=14=a0` lines `config.txt` has, and the auxiliary
  enable register (`AUX_ENABLES`) reads `0x1`.
* With `enable_uart=0` nothing at all appears on the header's UART, not
  even BL31's banner.

These agree with what
[design-platforms.md](design-platforms.md#trying-a-card-on-a-board) says a
4 GB board shows.

## Not yet verified

* **The host link on UART3** (pins 7, 9 and 29). No second adapter was
  reported connected. Not checked.
* **What each command printed.** The owner typed `erl`, `top`, `ps`,
  `cat /proc/cpus/0/status`, `dmesg` and `ifconfig` at the console and
  reported none failing, so typing reaches the shell through the mini
  UART's receive path, and the Erlang shell, the process and CPU
  inspection paths and the kernel log answer. Their output was not
  supplied, so its content (CPU count, the interfaces `ifconfig` lists,
  the log records) is not checked.
* **The banner lines.** The reports do not give BL31's banner, bootstrap's
  memory line or the `rc: the command shell` line as read from the
  console, and no serial log was supplied. Not checked.
* **`/data` and the SD card.** Not working, as above: there is no SD
  controller driver (part (b)), so nothing a file system does on the card
  is checked.
* **Everything else of 1b-I.** Ethernet (part (c)) and the display
  (part (d)) are not started.
* **Other boards.** Only the 4 GB board of revision `c03112` was run.
  No board of another memory size was tried.

## Sources

* The owner's report of 2026-11-12 (this record's only source for the
  observations above).
* [design-platforms.md](design-platforms.md#trying-a-card-on-a-board),
  [plan.md](plan.md#1b-i-the-raspberry-pi-4-on-the-stopgap) and
  [research-rpi4-bl31-qemu.md](research-rpi4-bl31-qemu.md), the QEMU
  experiment with the same BL31.
