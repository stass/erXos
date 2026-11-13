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
