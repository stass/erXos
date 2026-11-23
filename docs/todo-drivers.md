# TODO: Drivers and platforms

Open work on drivers and the device layer: PCIe, DMA, the device tree, GENET, SD, UART, the platforms and boards. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Stopgap replacements

* [Low] `erlang/apps/erx_uart/src/erx_pl011.erl`, `wait_idle`: a boot that leaves the UART or its transmitter disabled with bytes in the transmit FIFO keeps `FR.BUSY` set, and the driver exits `pl011_busy` where clearing `FEN` would flush the FIFO (DDI 0183G 3-16); the wait is bounded by a count of reads, not a time.
* [Low] `hw/sysreg/aarch64.json`, CTR_EL0: the DMA architecture layer
  (`otp/erts/emulator/nifs/erxos/arch/aarch64/erx_dma_arch.c`) and `liberx/backend/fiasco/arch/aarch64/cache.c`
  each write CTR_EL0's field positions by hand, and `clock.c` writes its counter reads by hand. The refresh takes
  `Fields.ConstantField` and `tools/lib/erx/sysreg_headers.rb` generates read and field accessors, so the fix
  is to add CTR_EL0 to the file and have these files call the generated accessors, listing them on the
  `sysreg-read` chokepoint.
* [Medium] QEMU virt's display domain row (`config/manifest/development.txt` and `qemu-virt-development.txt`;
  [design-display.md](design-display.md#the-display-device)): the display domain holds the `display` unit
  (the transport page of the virtio-gpu, keyboard and tablet transports and five spare ones), on the `display` share's 100 mcpu with 24 MiB, the
  `display_domain` suite's unmeasured figures; size both from a measurement of the domain driving a screen. No
  boot of the development image attaches a gpu (`tools/erx boot` included), so the domain runs there without a
  screen, and no session is granted the display.
* [Low] `tools/lib/erx/device_give.rb` and `system_domain.rb`, `ARGS_LINE`, `RESTARTS_LINE`, `CONNECTIONS_LINE`
  and `PEER_ROW`: each harness's row is `MediumBoot::DOMAIN_ROW` changed by regular expressions on its text,
  outside `Manifest::Edit`, which edits only a whole manifest (it needs the machine record). Build the rows from
  one row builder whose fields are named, or let `Manifest::Edit` edit a record of a part
  (`Manifest::Frontend.records`), and delete the patterns.
* [Medium] `erlang/apps/erx_uart/src/erx_hostlink_web.erl`, `tools/lib/erx/web_server.rb`,
  [The host tool's front end](design-web.md#the-host-tools-front-end): a restart of the web domain ends the
  system domain's facet with the relay (`exit(shutdown)`), and the session drops the facet's number without
  telling the host. The host tool keeps the dead number: every later call is answered `{error, noproc}`, a reply
  rather than a link failure, so each new WebSocket is refused with 503 until the host link breaks or `erx web`
  restarts, and an open one stays open while its browser answers the tool's pings. Give the host a signal (a
  cast of `{web_closed, C, down}` for each connection the facet relayed before it exits, and the host tool
  reopening the facet on `noproc`), with a host test that ends the relay under an open connection.
* [Medium] `erlang/apps/erx_blk/src/erx_blk_sd_host.erl` (`issued/2`), the request transfer: it expects command
  complete before the buffer events and transfer complete, so a controller that raises a data event before the
  response, in a separate interrupt word, fails the request and restarts the storage domain. The start's commands
  take both orders (`command/1`, two tracks as FreeBSD's `cmd_done` and `data_done`, `sdhci.c:1921-1923,
  2057-2059`). On the Pi 4 the start was refused at CMD7 by one of two behaviours, unverified which: CMD7's
  transfer complete in a word before its command complete, or a data end in CMD9's word; the request path may
  meet the same, though on the board littlefs mounted `/data` and a file written there survived a power cycle
  with no refusal. One word's events can also reach the next request inside `handle_info`'s fold, after a CMD13
  answer starts it; feed the transfer one word at a time as the start's wait is fed. Give the transfer the same
  two tracks: command complete may come at any point before the data track ends, and the request is answered once
  both are done; the exhaustive oracle in `erx_blk_sd_host_tests.erl` then allows the command at any position.
* [Medium] `erlang/apps/erx_blk/src/erx_blk_sup.erl`: a line owner (`erx_irq_line:start_owner/2`) that fails to start
  fails the supervisor's start, so the permanent application ends the storage domain, and the same failure repeats on
  each restart until the domain row's intensity runs out, with no line from the driver. The owner child should refuse
  with one line and `ignore`, after which the device process's `attach/2` fails and it refuses too.
* [Medium] `erlang/apps/erx_blk/src/erx_blk_write.erl` (`sd_step/4`): a plan is built from the command index alone,
  so `{acmd, 13, ...}` is CMD13 and an ACMD issued without CMD55 first is the plain command (ACMD6 becomes CMD6 with
  any argument); that CMD55 always precedes an ACMD rests on the card core's phases. ACMD41's, CMD7's, CMD55's and
  CMD48's arguments are not checked. Make an app command one plan that issues CMD55 with the card's address, checks
  APP_CMD in its R1, then issues the ACMD.
* [Low] `erlang/apps/erx_blk/src/erx_blk_sd.erl`: events left in an interrupt word after a request is answered are
  handed to the next request, issued within the same word's fold; a stray buffer bit then fails it. Drop the rest of
  the word once a request is answered. A refusal partway through the start also leaves `irpt_en` set; clear it
  before `ignore`.
* [Medium] `tools/lib/erx/raspi4b_shell.rb`, the SD model tests of docs/design-storage.md ("Verification and testing"):
  the `tcg-sd-card` cell identifies the card, reads the partition table, mounts littlefs, writes a file at root's
  `/data` and finds its bytes in the card's data partition, and writes and reads back two
  blocks outside every partition, on the packed card only, padded to a 2 GiB standard-capacity card. Still to come: the
  `/data` file read back after the storage domain is killed and restarted, a 4 GiB
  high-capacity card, the seeded medium whose data partition holds a different file, and the recovery test under a write load.
* [Low] `erlang/apps/erx_blk/src/erx_blk_sd_host.erl`: OUT_OF_RANGE is type X in Physical Layer Table 4-42 (p.120), so a card may report the last-sector out of range of a CMD18 in the next command's R1 instead of Auto CMD12's; the transfer machine exempts only Auto CMD12's, so such a card would fail the next request and restart the storage domain. The board probe should record whether a card does this; if one does, exempt OUT_OF_RANGE alone in the first R1 after such a read.
* [Low] hardware facts, BSC5's address: the datasheet's section 3.2 lists `0x7e205a80`, the board's tree has
  BSC5 at `0x7e205a00` (board_tree_test passes with the record at that address), so the platform record says
  `0x7e205a00` while `hw/pins/bcm2711.txt`'s `bsc5` row and docs/design-header-io.md's hardware table still say
  `0x7e205a80`. Settle it on the board (the board checklist's BSC5 item) and make the three agree.
* [Medium] erx_uart, `erx_pl011:console_uart/1` and `erx_mini_uart:console_uart/1`: the parse of
  `-erx_record console` is copied in each driver, as are their fuzz targets. One parse of the four
  numbers, with each driver checking only its clock rule, and one fuzz target.
* [Medium] erx_uart, `erx_pl011`, a line's driver (the host link's, a Bluetooth controller's): a drain
  stopped at its 64-word bound is continued at once, and a line's driver hands each drain up as read, so a
  device whose `RXFE` never sets, or a line faster than its owner, puts 64-byte messages in the owner's
  mailbox without bound; pace a line's continued drains by its owner's consumption, as the console's store
  does. The continuation in `send/2`'s full-FIFO wait has no test, since QEMU never sets `TXFF`.
* [Low] erx_uart, `erx_mini_uart` does not check LCR.DLAB, with which its IER writes would change the
  divisor; refuse to start with DLAB set.
* [Medium] 1b-I's stage (a) (docs/research-rpi4-board-pass.md), the board pass, the framebuffer
  (`liberx/backend/fiasco/runtime_entry.c`, `framebuffer_give`): unverified is whether sigma0 grants the
  VideoCore's memory, the `framebuffer` row's window in `config/platforms/raspi4b.json`, as I/O memory, which
  `erx_mem_create_physical` needs; if not, the root stops with "the backend refused the framebuffer's pages".
  The board's console shows the root's line: `framebuffer WxH STRIDE FORMAT`, or `framebuffer absent outside
  BASE SIZE`, which says where the firmware put the framebuffer, so the row's window is moved over it.
* [Low] Pi board pass, the storage domain's `sd` unit (docs/design-storage.md, "The SD controller's line"): no
  driver quiets the legacy SD controller `/soc/mmc@7e300000`, which shares EMMC2's line 158, so if the firmware
  leaves its interrupts enabled and it asserts the line, EMMC2's line owner is woken on every delivery. Check on
  the board that the line is quiet with EMMC2 idle; if not, the design must say who quiets the legacy controller.
* [Low] Pi board pass, the device tree's address (`tools/lib/erx/boot_partition.rb`, `config_txt`): the card's
  `config.txt` sets `kernel_address` from the QEMU harness's loads but no tree address, so the firmware chooses
  where it loads the tree and writes that address into BL31's stub header. Where it chooses for a development
  image of about 48 MB at `0x200000` is unverified; the QEMU harness loads the tree at `0x8000000`
  (`tools/lib/erx/qemu.rb`) because at `0x3000000` the image reached it. Read the address on the board (BL31's
  `Changed device tree` line, or `x0` at bootstrap's entry) and check it lies past the image's end; if it does
  not, pin it in `config.txt` to the harness's address, after checking in Raspberry Pi's `config.txt`
  documentation which setting does that.
* [Medium] PCIe domain and device service, the start's other side (`erlang/apps/erx_pcie/src/erx_pcie_enumerator.erl`,
  `erlang/apps/erx_domain/src/erx_devices_pci.erl`, `abi/services/pci_bus.txt`, `pci.txt`, `pcie.txt`,
  [design-pcie.md](design-pcie.md#facets)): the enumerator runs its start and serves `set` and `reset` over its
  edge on the host, and on the target opens an ECAM bridge's driver over its given record and calls `pci_bus`
  through the facet `erx:cap/1` finds; its mint (`erx_pcie_facet`) grants `pcie` to the system domain. The device service's PCIe process (`erx_devices_pci`) applies
  `erx_devices_pci_core` behind the `pci_bus` and `pci` facets (`erx_pci_bus_facet`, `erx_pci_facet`, minted in
  front of the domain service and forwarding to the registered process), takes every domain's end from the domain
  service's forward, answers `report` after `erx_domain:await_grant(pcie, D)` with the incarnation written to the
  catalogue's `answered` first, and after a restart begins `synced` from it. The domain service serves `pci_bus`
  and `pci`, whose service rows the shared development manifest declares, and the manifest check holds the three
  interfaces' servers and grantees to design-pcie.md's "The manifest". `firmware` queues each request for a bridge
  the library holds and hands it to the linked firmware worker (`erx_firmware_worker`), which calls `erx_domain_lib:firmware/2` one at a
  time (design-system.md, "Firmware requests"). Still to build: the worker's reductions returned with its answer, for
  the reply's cost that admission by measured share charges (the `erx_facet.erl` item); the identity check
  of a reported function against its row's compatible string ("The catalogue and gives"); and the `pcie` QEMU
  suite's cases beyond walk-and-report and hold (design-pcie.md, "The `pcie` QEMU suite").
* [Medium] PCIe, the BCM2711 bridge on the Pi 4 (`config/platforms/raspi4b.json`, `config/manifest/`,
  [design-pcie.md](design-pcie.md#the-bridge-seam)): the driver starts on the target over the bridge's device
  record, but the Pi 4's platform record has no bridge unit or VL805 unit and its manifest no PCIe domain, so the
  enumerator finds no configuration record there and the driver has run only over the host tests' register model.
* [High] PCIe, the VL805's DMA memory on the Pi 4, unconfirmed on the board (`kernel/core/dt.c` `range_read`,
  [design-pcie.md](design-pcie.md#dma)): one boot's root line showed the handed-over tree mapping CPU `0`
  through `0x3fffffff` to PCI `0x4_0000_0000` (`window 0x0 0x400000000 0x3fffffff`), for which the reader gives the
  VL805's row `range 0x0 0x400000000 0x3bffffff` in the host tests (`pci-high-window`); a boot on the board
  confirms it, or its line shows what differs.
* [High] Pi 4 USB, the VL805 must reach 64-bit bus addresses (`otp/erts/emulator/nifs/erxos/erx_device.c`
  `trb_ring_create`, [design-usb.md](design-usb.md#install), "Address width"): with the handed-over tree's window at
  PCI `0x4_0000_0000` every bus address of the VL805's memory lies above 4 GiB, so unless its `HCCPARAMS1.AC64`
  is set the TRB ring's install refuses with `ERX_ERANGE` (`erx_device.c:2499-2501`, the test at `erx_device_trb_form.c:926`;
  [design-usb.md](design-usb.md#refusals-and-error-results), `{error, erange}`) and the USB domain cannot run the controller. FreeBSD's VL805 driver uses 32-bit DMA
  and Linux 36-bit and 40-bit masks (design-usb.md, "The BCM2711 bridge"); what the VL805 reports is unverified on
  the board. If `AC64` is clear, the bridge's window has to move below 4 GiB on the bus, which the bridge driver
  programs from the tree (`erx_pcie_bcm2711_core:inbound/1`), and the tree's window is the firmware's.
* [High] PCIe, the bridge's start on the board (`erlang/apps/erx_pcie/src/erx_pcie_bcm2711_core.erl` `decide/1`,
  `erlang/apps/erx_pcie/src/erx_pcie_bcm2711.erl` `describe/1`,
  [design-usb.md](design-usb.md#the-bcm2711-bridge)): on a Raspberry Pi 4 the console stopped mid-line as the
  bridge driver started and the watchdog reset the board at every boot, with a JTAG halt of cpu0 timing out, while
  the core's first access was a read of `MISC_PCIE_STATUS`. The core reads `RGR1_SW_INIT_1` and `HARD_DEBUG` first
  and runs bring-up for a bridge in reset or with its SerDes powered down; that the boot firmware leaves the bridge
  in one of those states is an inference from the facts record's order (unknowns 8 and 9), not confirmed on the
  board. The start's log line says `reset` alike for a bridge in reset, one with its SerDes off and one whose link
  was down, and nothing is logged before the first access, so a board run cannot tell which branch ran or whether
  the `RGR1_SW_INIT_1` read itself hangs: carry the branch in the start's result and log it, with one line before
  the first register access.
* [Medium] PCIe, the BCM2711 bridge's keep path (`erlang/apps/erx_pcie/src/erx_pcie_bcm2711_core.erl` `keep/1`,
  `by_link/1`, [design-usb.md](design-usb.md#the-bcm2711-bridge)): a kept bridge rewrites `MISC_CTRL`
  (`SCB0_SIZE`, the burst size and the read modes) and `BAR1`/`BAR2`/`BAR3_CONFIG_LO` with the link up, and the
  firmware register is read at `0x50` before `MISC_CTRL` is rewritten, under the read modes the boot firmware left.
  The facts record has no source that writes those registers with the link up (every source resets the bridge
  first, section 6) and does not establish what the firmware programs (unknown 5): equal values change nothing,
  but a firmware window that differs from the tree's is moved under a VL805 that may be mastering. Probe B3 should
  also read `MISC_CTRL` and the three BAR words before the keep writes them, and compare them with the tree's.
* [Medium] PCIe and the drivers' control, one mint for system-domain-only grants (`erlang/apps/erx_pcie/src/erx_pcie_facet.erl`
  `start_link/0`, `mint_init/1`, `mint/1`; `erlang/apps/erx/src/erx_driver_ctl.erl` `start_mint`, `mint_init`, `mint`): the pcie
  mint repeats the driver-control mint line for line but for its callback module and the grant's extra keys, so a fix
  to either (its system messages, the withdrawal of an abandoned grant) must be made twice, and the pcie mint's
  grant path has no host test. Fold both into one mint that takes the callback and the extra grant keys.
* [Medium] PCIe, the start's leftovers (`erlang/apps/erx_pcie/src/erx_pcie_enumerator.erl`, `abi/services/pci.txt`,
  [design-pcie.md](design-pcie.md#facets)): the start holds a changed function off by its own copy of the
  intake's comparison (`changed` in `erx_pcie_enumerator`, `pci_same` in `dom_core.c`), which the answer to `report`
  does not rely on, since `erx_devices_pci_core:lowered/3` lowers every row the catalogue does not keep; delete the
  copy if the enumerator can take its off settings from the answer alone. `lowered/3` restates the library's
  givability (`erx_dom_pci_givable`, `erx_dom_pci_given`) as confirmed, `ready` and not `firmware_lost`, leaving out
  identity and pin, which fix no setting above `off` today because only a raise through `erx_dom_pci_given` makes
  one; have `devices/0` answer each `pci` row's `given` from `erx_dom_pci_given` and lower the rows not given, one
  source. `erx_domain_lib:pci_mode/2` admits a raise for a
  function its catalogue gives now, though its holder's give, made while it was not givable (a VL805 `not_ready`
  before its firmware), drove nothing; record in `erx_dom_device_t` whether the give drove it and require that too.
  No `dom_core_test` case lays a layout from a `not_ready` placing report and confirms it with a `ready` one, the
  VL805's path, which a `pci_same` comparing the states would break. A start whose route does not fit
  leaves the function as it reads, where Failure handling turns it off; a root port's reopening that fails and the
  walk's `past_bound` are not logged. The `pci` interface's scope, a `device` parameter for each device its grantee
  holds, is not declared: the service grammar takes a parameter set of `u64` alone (`tools/lib/erx/abi_contracts.rb`),
  and the manifest check has no checker to hold the scope to the grantee's `pci` rows, so both wait for the device
  service's `pci` facet. `erx_pcie_report:later/3` reports a BAR its layout
  calls absent as absent even when it reads nonzero, which hides an implemented BAR from the intake; report such a BAR
  as unsized memory. The planner checks the route in mode `off` too, so an `off` setting cannot lower a function
  whose route no longer fits. `erx_pcie_apply_tests` keeps a broken property's rule and target but not the input's
  switch levels and differing fields, and every walk seed reruns it (about 10 s each).
* [Medium] PCIe, `erx_pcie_apply`'s verification and the later record (`erlang/apps/erx_pcie/src/erx_pcie_apply.erl`,
  `erx_pcie_enumerator.erl`, [design-pcie.md](design-pcie.md#host-tests-of-the-pure-cores)): the host test the
  design names for `erx_pcie_apply` (every plan run with each write ignored alone, and with a register ignoring writes
  from one write on) and its two seeded faults are not written; the model has no write-ignoring registers. A later
  start reports a drivable function as its stored layout rather than as it reads, so a change the planner's identity
  does not cover (class, subsystem, pin, MSI-X table, Express offset or FLR flag) is confirmed; build the later record
  from the read with the layout's BAR sizes and addresses. `targets` must carry each layout's latest state, which the
  library's intake zeroes, since the enumerator drives only layouts found ready or not_ready. A `set` the planner
  refuses for the mastering rule is answered `{error, reset}` without turning the function off, and a start whose route
  does not fit leaves it as it reads, where Failure handling turns it off; a root port's reopening that fails and the
  walk's `past_bound` are not logged. The `pci` interface's scope, its `device` parameters, is not declared.
* [Low] boot, the archive move's overlapping case (`fiasco/bootstrap/server/src/erx_image.cc`, `move_archive`): no
  target boot moves the archive onto part of its loaded range; only the host test and the fuzz seed plan one. On
  QEMU `virt` a forced move always lands behind the device tree, which QEMU puts right behind the loaded file, so it
  never overlaps its source. On `raspi4b`, whose tree is fixed 126 MiB past the file's start, a single file whose
  archive ends within the root's length past the root's place (64 MiB) moves onto its own tail. Add a `raspi4b`
  cell with an archive sized into that window of about 2 MiB.
* [Medium] boot, the move's order is a rule bootstrap must remember (`fiasco/bootstrap/server/src/erx_image.cc`,
  `move_and_copy`; `kernel/core/boot_place.c`): the plan gives the archive's old and new place, and the effect layer
  must move it before any copy, since the copies read the new place. The host driver's `apply` runs the plan in that
  order, but bootstrap's own order is checked only by the `boot_image` suite's moved cell. Likewise nothing past
  `move_and_copy` may refuse the boot or reserve a region, which only a comment in `erx_image_load` guards. Have the
  plan emit one ordered step list, the move first, that bootstrap runs in order, with a commit step that has no
  path to `refuse`.
* [Low] boot, the plan ignores bootstrap's `-sysalloc=` window (`erx_image.cc`, `erx_image_load`): the request's
  memory is `mem_manager->ram` alone, so the images, the moved archive, the device tree's copy and the handoff page
  may land outside a window given on bootstrap's command line, where `find_free_ram` kept its own allocations.
  Without the option the window is all of memory. Pass RAM intersected with `sysalloc` as the request's memory.
* [Low] boot, the cache line stride (`fiasco/bootstrap/server/src/arch/arm/mem_v8_64.h`, `linesize_bytes`): the
  range clean steps by the first level's line size from `CCSIDR_EL1`, not by `CTR_EL0.DminLine`, which names the
  smallest data cache line of any level (not yet checked against the Arm ARM), so an outer cache with shorter lines
  would be cleaned in part. Confirm the field's meaning in the Arm ARM and read the stride from `CTR_EL0`.
* [Low] boot, planner test gaps (`test/host/boot_place_test.rb`, `tools/fuzz/boot_place_fuzz.c`): no host test puts
  the device tree in the move's way, as QEMU `virt` does (the fuzz target's layouts and a seed do), and the fuzz
  target's plan check does not assert that a moved archive lies behind every image placed at its link addresses,
  since the plan does not say which those were.
* [Medium] Pi board pass (docs/plan.md, 1b-I (a) 5), the mini UART's interrupt enables: settle on
  silicon the two facts `hw/svd/mini_uart/mini_uart.svd` marks unverified, because the BCM2711
  ARM Peripherals PDF contradicts the first and does not mention the second. IER's receive
  enable is bit 0 as the 16550 has it, where the PDF's table prints it at bit 1 and the transmit
  enable at bit 0, and `erx_mini_uart` writes bit 0. If the PDF is right the driver enables the
  transmit interrupt, a level interrupt asserted whenever the transmit FIFO is empty, so on the
  line it shares with the auxiliary SPI controllers it fires without end, the driver spins on the
  CPU, and it receives nothing. The receive interrupt may also need IER's `RX_ERRATA` bits (2 and
  3), which `erx_mini_uart` sets; whether QEMU's model ignores them is unchecked. Probe by writing
  each IER bit alone and watching the interrupt line and IIR, then correct the file and the
  driver, and drop the bits if not needed.
* [Low] 1b-I's stage (a) (docs/research-rpi4-board-pass.md), the board pass: confirm on silicon that the mini
  UART's receive interrupt needs IER's `RX_ERRATA` bits (`hw/svd/mini_uart/mini_uart.svd`), which
  `erx_mini_uart` sets as the BCM2835 errata asks and QEMU's model ignores, and drop them if not.
* [Low] header probe, `test/raspi4b/header_probe.c`: the GPIO block's and the clock manager's bases are the
  probe's own constants, cited to BCM2711 ARM Peripherals 5.2 and 5.4.2, because the platform record has no
  `gpio` or `clocks` unit (docs/design-header-io.md, "Placement: units and domains"); once the GPIO package
  adds them, `HeaderProbe.defines` passes the bases from the record as it passes the console's.
* [Medium] header map, docs/design-header-io.md "Verification", checklist item 1: the tree's facts (the header
  blocks' nodes with compatible strings, bases, lines and status; BSC5's base; whether BSC2 and BSC7 are listed;
  the oscillator's rate) are left to "the header map's own checks" through `erx_dt`, but the header map reader's
  contract and its verification rows name no such check, nor whether it runs at build time or at boot. Until the
  design names it, nothing settles those facts.
* [Medium] SD host controller, `hw/svd/sdhci/sdhci.svd` (docs/design-storage.md, "The SD host controller"), unnamed
  bits: the file names only the bits FreeBSD's `sdhci.h` names, so `write_field/4` writes every other bit of a word
  back as zero. In `CONTROL0` that is the block gap control byte, whose stop at block gap and continue requests
  the device NIF always owns: a driver's field write to `CONTROL0` clears them. The file also shows the four
  fields the NIF owns ([design-device-dma.md](design-device-dma.md), "Register ownership"), `CONTROL0`'s
  `DMA_SELECT` and `CONTROL2`'s `ADMA2_LENGTH_MODE`, `HOST_V4_ENABLE` and `ADDRESSING_64BIT`, as plain fields,
  since the generator has no field mark (the field-ownership item). Programmed I/O sets none of them; the
  field marks, or the ADMA2 mode's design, settle how the driver changes these words.
* [Medium] GENET, `erlang/apps/erx_net/erxos/erx_genet_core.erl` `configure/1`: the
  driver's ring settings (both burst sizes, ring 16's transmit done threshold and flow
  period, its receive XON/XOFF thresholds) are written before `negotiate/2`'s
  install. They follow the confirmed stop
  of both engines (`erx_device:stop_register_ring/1`, which `reset/0` calls), as FreeBSD writes
  them after `gen_dma_disable` (`if_genet.c:286-288, 873-875`), so they land on stopped
  engines. The two XON/XOFF field writes pass through a word with the new low half and
  the old high half. If the board shows that matters, the NIF takes them as owned and
  writes them in its install after the confirmed stop (docs/design-device-dma.md,
  "GENET"), which also removes the driver's copy of the ring index.
* [Medium] GENET, receive descriptors past the buffer, and the stop after a broken queue: with
  2,048-byte buffers and a reset that flushed both buffers, on SD and HTTP netboots the Pi 4 filled receive
  descriptors whose status shows end of packet without start of packet and a length past the
  buffer: `0x2d764800`, `0x1b954000` and `0x3dde4800` (bits 27:16 3446, 2965 and 3550), 20 ms to
  1 s after link-up. The device NIF copies no bytes for such a length, hands the buffer back and
  tags the completion with the whole status, and `erx_genet_rx` drops it as `too_long`
  (docs/design-device-dma.md, "The register ring (GENET)"). With `reset/0` the UEFI firmware's
  driver's reset, both rings' buffers 1,536 bytes and the MAC held until link-up, three boots
  in a row at 100 Mb/s dropped no frame at all (`rx_dropped=0` after 60 s, `~/erxos-history` 19bc5cd,
  `pi4/2026-11-22-rx-wedge/both-linkup-run{1,2,3}.uart.log`), so these descriptors most likely
  came from the receive buffer's misconfiguration under a reset that flushed both buffers, which also chained 2 KiB pieces into frames of
  4.7 and 5.4 KB (`uart-rx-wedge.log`). Open: whether a `too_long` drop ever returns on a long
  run (`erx_net_driver:counters/1`), and, separately, the restart after a broken queue, whose
  `negotiate/2` once timed out (`{negotiate, stop_timeout}`, `rx_dma_status` `0x1fffe`) when the
  restart reset the receive buffer and MAC before any DMA stop; `reset/0` turns the MAC off, waits
  a frame's time and stops and confirms both engines first, and no board run has broken a queue
  with that order to show whether it ends the timeout.
* [Medium] GENET, `erlang/apps/erx_net/erxos/erx_genet_core.erl` `start/0` and `link_up/1`, the
  MAC's hold, at gigabit and at a later link-up: `start/0` holds the MAC in software reset, and
  every link-up turns both directions off at a frame's end, holds the MAC, sets the RGMII control
  and the speed, releases it and only then enables both directions, since on the board either
  direction enabled before link-up gave short transmitted frames or each received frame some 30
  times, even with the speed rewritten at link-up (`~/erxos-history` 19bc5cd,
  `pi4/2026-11-22-rx-wedge`). Every working run linked at 100 Mb/s, with 1000BASE-T not
  advertised; with it advertised, as erx_phy_c22 does, the link comes up at 1000 Mb/s, where the
  `rgmii-rxid` timing matters most, and no run has tried this order there. The facts record's
  other driver holds the MAC only until its first link-up (docs/research-genet-bcm2711.md,
  `L.mii` 79-91); the hold at a later one is erXos's and untried, as are frames posted before the
  first link-up, which wait in the transmit ring through the hold. Settle on the board: a gigabit
  boot (frame lengths on the wire, receive deliveries per frame, ping); a cable pulled and
  replugged at the same speed and moved between a gigabit and a 100 Mb/s port, counted the same
  way; and the owned ring registers, the start and end addresses included, read back across the
  hold and its release.
* [Medium] GENET, `otp/erts/emulator/nifs/erxos/erx_device.c` `register_ring_stop`: the NIF writes both DMA
  stops, transmit first, then reads both idle reports; the other published driver stops and confirms
  transmit before it writes receive's stop, and at its interface stop waits 10 to 20 ms between (GENET
  facts record, "Stopping the DMA and confirming it stopped"). If the board still shows `{dma_stop,
  stop_timeout}` with the receive engine running, try that order and the wait in `register_ring_stop`,
  which serves both `stop_register_ring/1` and `negotiate/2`, and update the design table's row.
* [Low] GENET, `otp/erts/emulator/nifs/erxos/erx_device_genet_model.c`: the hosted controller model resets its
  stop count at every DMA control store, so with stop reads above 0 a stop rewritten at each call never
  shows, and the hosted stand-in (`erx_device.c`) runs with 0; the harness's engine counts only from a stop
  of a running engine. The model counts as the harness does, then a hosted case where `stop_register_ring/1` answers
  `ebusy` a few times drives `erx_genet`'s `retry_busy/3` and the `dma_stop` refusal through `init/1`.
* [Medium] GENET, `erlang/apps/erx_net/erxos/erx_genet.erl`, the broken-queue ending: no test runs
  `event/2`'s catch, `log_broken/2` or the `{stop, {broken, _}}` hand-off; only the pure
  `erx_genet_core:rx_fault/1` and `evidence/0` are tested. The hosted GENET run
  (`test/integration/runtime_genet_test.rb`) is the place for a case that breaks a queue on the stand-in
  and expects the link to end with `{shutdown, {broken, rx}}` and the lines logged. `rx_fault/1` also
  re-reads the NIF's receive index bound from the registers, later than the NIF did; the one-source
  form is the NIF recording why it broke a queue (the index advance) and reporting it, which needs a design home such as an inspection path.
* [Low] network, `erlang/apps/erx_net/src/erx_net_driver.erl`: after a transport's `{stop, _}`
  within the one-second hold the driver still passes events to the transport, so `erx_genet` logs a
  broken queue's diagnosis again at each later interrupt of the hold; and the `transmit` callback
  cannot answer `{stop, Reason}`, so `erx_genet` turns a broken post into a message to itself.
  Stopping transport events once ending, and a `{stop, Reason}` answer from `transmit`, would remove
  both; `erx_virtio_net` then takes the same ending for a broken queue in place of its crash
  (`error({virtio_net, broken, _})`), as design-network-stack.md's "Ending" states.
* [Medium] GENET, `hw/svd/genet/genet.svd`, `TX_DESC_STATUS`'s `BUFLEN`: 12 bits (`__BITS(27,16)`,
  `if_genetreg.h:181`) or 11 (the mask `0x7ff0000` at `:189`) is unverified. Keep every transmit length below
  2048 bytes, which both widths hold, until the board pass settles it.
* [Medium] GENET, `hw/svd/genet/genet.svd` (docs/plan.md, 1b-I (c)), unnamed bits: the file names
  only the bits FreeBSD's `if_genetreg.h` names. `write/3` refuses a word with any other bit set, and
  `write_field/4` writes every other bit back as zero, while FreeBSD reads, modifies and writes back
  `UMAC_CMD`, `EXT_RGMII_OOB_CTRL`, `RBUF_CTRL`, `RBUF_CHECK_CTRL`, `SYS_RBUF_FLUSH_CTRL` and
  `TBUF_CTRL` whole, keeping them. The transport, `erx_genet`, writes them by named fields
  (`erx_genet_core`), so it clears every unnamed bit of each where FreeBSD keeps its reset value;
  `UMAC_CMD` alone is written 0 first by both. The board pass reads each register's reset value,
  and the file gains the bits that turn out to be set.
* [Medium] GENET, the bound on its DMA writes: the device NIF owns the descriptors and ring
  registers, but the frame length limit, the status block, the two-byte alignment and the burst
  sizes stay the driver's. The board pass confirms that a ring's buffer size bounds every byte the
  controller writes per descriptor whatever those say; if not, the NIF owns them too.
* [Medium] GENET, `hw/svd/genet/genet.svd`, `RX_DMA_STATUS` and `TX_DMA_STATUS` (`0x1048` past each
  direction's base), which the register ring's reset reads for its idle report: FreeBSD's
  `if_genetreg.h` does not name them, so their definition comes from the clean-room facts record
  alone (docs/research-genet-bcm2711.md, "The DMA status register"), its ring bit inferred. A source
  that is not Linux's driver would confirm them; the board pass reads them in any case.
* [Low] GENET, `test/fixtures/erx_device_genet_model_harness.c`, test gaps in the register ring's core:
  no case fills the receive ring to exactly 256, runs the 16-bit indexes past 0xffff, or has good
  frames before a too-long one; the stand-in's DMA status sets every ring bit at once, so a core that
  ignored ring 16's bit would pass; and `erx_device_genet_registers` keeps its names, `found[]` and
  `ring[]` in step by position, which one table of names and field offsets would replace.
* [Low] GENET, facts the board pass settles: the transmit length's width (`__BITS(27,16)` against
  the mask `0x7ff0000`, neither compiled by FreeBSD; until settled the transport sends less than
  2048 bytes per descriptor), what receive status bit 15 means, the interrupt mask registers'
  sense (FreeBSD writes all ones to set-mask and then to clear-mask to disable them), and whether
  the firmware leaves GENET's DMA stopped when the Pi netboots, since no domain resets a GENET no
  manifest places: the bootloader resets the MAC and PHY only when its final boot mode is not the
  network (rpi-eeprom's release notes, 2020-06-12), and the first netboot from the Mac
  (docs/design-platforms.md, "Netbooting from a Mac") shows what follows. That netboot also shows,
  in the console's `erx: boot value` line, which `/chosen/bootloader/partition` value the firmware
  passes on a network boot; the netboot passage takes it to name no slot, and a stale 2 or 3 would
  meet the slot's system partition under another root hash, which answers `eio`, not a wrong file.
  The PHY's MDIO address, 1, and its RGMII mode are in no record; `erx_genet`
  holds them as constants, which the board pass confirms. Also: whether the UniMAC accepts its
  software reset when local loopback is set by one write before it (FreeBSD sets both in one
  write), whether short frames are padded to 60 bytes by the controller, and that the PHY answers
  at that address with the BCM54213PE's ID.
* [Medium] platforms, netboot from a Mac (`tools/erx netboot`,
  [design-platforms.md](design-platforms.md#netbooting-from-a-mac)): two points of the section are
  unverified and wait for the first netboot, whose console log and `dnsmasq`'s log (with the home
  directory cut from the paths) settle them. (1) A network boot names no slot and comes up as an
  unknown boot: the block service starts no `system` window, the `system` tree is empty and the card's
  system-partition packages are absent, while `/data` and the `ERXOS` volume still come from the card;
  the GENET item above reads the `erx: boot value` line for the same netboot. (2) `TFTP_IP` in the EEPROM's configuration is enough with Internet
  Sharing's DHCP server, which sends no option 43 and knows nothing of TFTP, though the bootloader
  matches the reply on its option 43. Where either fails, change the section to what the boot did.
* [Low] platforms, the soak (`docs/design-platforms.md`, "The soak"): nothing tests repeated boots of the
  board: the soak boots it once and the power-cut checklist covers power cuts, so no test
  boots the machine many times in a row. Add a repeated-boot check to the soak's rounds, judged by
  the same pure judge, or decide that 0.2 needs none.
* [Medium] platforms, building the soak (`docs/design-platforms.md`, "The soak"; one of 0.2's exit criteria in
  [plan.md](plan.md#02-the-first-release-on-fiasco)): 0.1 is published without it. Four packages of about
  50 to 100 calls each (unverified until they run): the judge and the round's readers (`tools/lib/erx/soak.rb`,
  a pure core, with `test/host/soak_test.rb`), the board's driver (`tools/erx soak board` and `soak judge`,
  extending `DevKey.ssh_argv` to take a destination and an identity path), the QEMU run, and the runs
  themselves, whose records go to the history repository.

## Bugs by subsystem

* [Medium] virtio drivers, one interrupt acknowledgement (`erx_virtio_gpu`, `erx_virtio_input`, `erx_blk_virtio`,
  `erx_virtio_net`, `erx_virtio_console`): each reads `interrupt_status`, writes `interrupt_ack` with its low two bits
  and acknowledges the line, and each copies `step/2` and the start sequence; the acknowledgement is a fact of the
  virtio-mmio transport and belongs in `erx_virtio`. `erx_virtio_input`'s drain also takes buffers until the device
  has none, so a device that refills at once holds the driver; take one batch and ask for more, as
  `erx_virtio_console` and `erx_virtio_net` do.
 * [Low] domain service, `served_kind/2` (`erlang/apps/erx_domain/src/erx_domain_srv.erl`, `init`): `Trees` lists the
* [Medium] device-tree reader, split DMA translations (`kernel/core/dt.c`, `range_read`): a translation written as
  several adjacent `dma-ranges` entries, as a full 32-bit identity map under a one-cell `#size-cells` must be,
  leaves several windows with RAM behind them, and the device gets `ranges` (no DMA range). It fails safe. Merge
  windows contiguous in both bus and CPU addresses before the RAM filter, with the design's "exactly one window"
  rule read after the merge. No tree of the manifests' devices does this.
* [Low] libfdt, a version 2 header read past (`fiasco/libfdt/lib/contrib/fdt.c:139-142`, `fdt_check_header`):
  the strings block's size, which version 3 added, is read and checked whatever the header's version, so
  `fdt_check_full` on a 32-byte buffer claiming version 2 reads 4 bytes past it (found by `dt_fuzz`).
  `erx_dt_accept` refuses a buffer shorter than the version 17 header first. Check the field only from version 3,
  in this copy and in Fiasco's `fiasco/kernel/src/lib/libfdt`.
* [Low] device-tree reader, duplicate sibling names (`kernel/core/dt.c`, `node_find`): `fdt_check_full` does not
  refuse two siblings of one name, and `fdt_path_offset_namelen` takes the first, so a tree the reader could see
  is wrong gives the first node's facts. Refuse a path that matches two nodes. The firmware is trusted.
* [Medium] device-tree reader, a PCI host bridge's `ranges` in the give (`kernel/core/dt.c`;
  [design-device-tree.md](design-device-tree.md#the-reader), "A PCI host bridge";
  [design-pcie.md](design-pcie.md#dma)): the reader takes a host bridge's three-cell `dma-ranges`, cut at a
  function's `dma_limit`, its `ranges` and `bus-range` (`erx_dt_bridge`) and the line its `interrupt-map` routes for
  a closed place's pin; the give's window containment check needs the bridge's `ranges`. The
  reader takes a closed place (`erx_dt_intx`) as valid, device below 32, function below 8 and pin 1 to 4; the
  platform record's reader of a bridge's places (`Manifest#bridge_places`) refuses any other.
* [Medium] PCIe, the row's `dma_limit` on erXos's kernel ([design-kernel.md](design-kernel.md#dma-and-the-iommu),
  [design-pcie.md](design-pcie.md#dma)): design-pcie.md cuts a function's windows on erXos's kernel at its
  row's `dma_limit`, a ceiling on CPU addresses, but design-kernel.md's `erx_dma_ranges` takes only the device's
  own address width and nothing there carries the row's ceiling to the function's resource; design the carrier
  before the kernel gives PCIe functions memory.
* [Low] device-tree reader, a closed place's bounds (`kernel/core/dt.c`, `erx_dt_intx`, `intx_key`): the reader
  takes the place it is handed as valid, device below 32, function below 8 and pin 1 to 4, and shifts the fields
  into the unit address unmasked, so a place with device 32 matches another place's entry. The platform record's
  reader of a bridge's places must refuse any other place when the places land.
* [Medium] device-tree reader, the PCI ranges entry read twice (`kernel/core/dt.c`, `windows_translate` and
  `windows_read`): both decode the bus binding's three-cell entry (phys.hi's space code, the PCI address, the
  parent's address, the size) and skip I/O space, and they already differ: `windows_read` refuses configuration
  space, `windows_translate` takes a configuration-space entry of a bridge's `dma-ranges` as memory. Give both one
  entry decoder and refuse configuration space in `dma-ranges` too.
* [Low] device-tree reader, its sources listed twice (`tools/fuzz/dt_target.rb`, `tools/lib/erx/native_root.rb`,
  `DEVICE_TREE`): the reader, its architecture's interrupt binding and libfdt's files are named in both, so a new
  source is added in two places. Derive one list from the other.
* [Low] device-tree reader linked into no target (`tools/lib/erx/core_archive.rb`, `ROOT_TASK_SOURCES`): only the
  host tests and the fuzz target compile `kernel/core/dt.c`; the root task links it with the package that hands
  the tree over, and a target-only build break surfaces only then.

* [Medium] lane driver's finish, `otp/erts/emulator/sys/erxos/erx_lane_drv.c` and the
  system_domain QEMU suite: the finish's decisions are tested on the host
  (`test/host/erx_lane_core_test.rb`, with the cut record, the full answers bound and their
  seeded failures), but no QEMU test runs the driver through them end to end. A peer that
  halts with half of a long record published, and a finish whose outbound lane is full with
  the bound on unsent answers reached, each ending with `{domain_down, D, Info}` and the cut
  record counted as dropped, cannot be reached on purpose from the shell, and a port's counts
  are gone once it ends, so each needs a test hook that holds the system side's input task.
  The burst cell's seeded failure (an agent that ends the port without the finish) does not
  fail either: the domain service is suspended while erts halts, so the system side has read
  the whole burst before the side ends; the same hook would hold the input task until the
  service ends the side. The same hook would show that `close_side` keeps a ready report
  still in the lane when a domain reports and ends at once (medium_boot's halting
  domains), which only the finish guarantees.
* [Medium] drivers, `erlang/apps/erx_blk` (and `erx_net`, `erx_fb`): no
  configured domain's driver starter calls `erx_irq_line:start_owners/1`, so a
  driver on a line its unit shares, which the domain library now marks
  shared in a configured domain's records, fails its start with
  `{error, unbound}`. `erx_blk_sup` starts the owners before the device
  process, `rest_for_one`, as
  [design-storage.md](design-storage.md) "The SD controller's line"
  has it; land it with the Raspberry Pi 4's SD transport, the first driver
  on such a line.
* [Medium] device service, `erlang/apps/erx_domain/src/erx_devices.erl`: the
  boot view relates only the devices the manifest places, and the platform
  records list a few of the machine's devices (QEMU `virt`'s record lists 3 of
  its 32 virtio-mmio transports), so a holder's page can cover, and its line
  carry, devices no record names. They go to no domain, so no page or line is
  held twice, but the device service's boot check of
  [design-shared-devices.md](design-shared-devices.md#the-unit-rule),
  which relates the catalogue to the kernel's listing and gives a unit the
  machine splits differently to no domain, does not exist, and
  `Erx::Platform` does not check that a record's own units, placed or not,
  are closed under sharing a page and a line.
* [Low] QEMU gate cell placement, `tools/lib/erx/qemu_cells.rb`: only native_task declares `offload`, from its
  measured 4-CPU HVF cell (about 42 s). Measure every suite's multi-CPU cell under HVF and declare `offload` where
  one takes 30 s or more. The suites whose runs do not go through `QemuCells::Placement` (conformance,
  native_libc_canary, medium_boot, production_image, block_device, net_device) never boot their local cells
  side by side; move the ones that only boot `Qemu#run` without a disk or host link onto it.
* [Medium] QEMU gate cell placement, `tools/lib/erx/qemu_cells.rb`: `QemuCells.lanes` stops a lane with
  `Thread#kill`, which can land between `Process.spawn` and the pid's assignment in `Runner#run` or inside a
  cleanup ensure, leaving a local QEMU to its deadline or a remote one to the remote timeout. Give every lane a
  shared cancellation flag passed to `Runner#run`'s `cancelled:` instead. Cell names are agreed by string: each
  Run spells `"#{accel}-#{count}cpu"` (boot_image adds its case after it) and the gate parses declared names
  with `CELL_CASE_NAME`; have suites declare `QemuCells::Cell` values and `Placement#each` yield the `Cell`, so
  names have one source. A moved cell is placed before reuse is consulted: with the default `--busy-load` a
  load that crosses it turns a stored HVF pass into a fresh TCG boot; with `--busy-load 0` placement does not
  depend on load, and only an HVF pass `make check-qemu` stored goes unused by the landing gate. Nothing
  sweeps run directories a failed remote cleanup leaves under the remote work directory.
* [Medium] devices, `erx_devfs`: only the system domain's namespace mounts `/dev`,
  the control tree. Administrator sessions do not get the read-only tree, and no
  device-service control facet serves the control tree to a session
  ([design-system.md](design-system.md#devices), "The `/dev` tree"). Mount
  `erx_devfs`'s `ro` tree from the session namespace setup, and serve the control
  tree through the facet when a session needs it. Decide then how the device tree
  shares `/dev` with the session's own `/dev/null`, `/dev/tty` and the rest
  (design-files.md, "Narrowing for a program"), and that a program started from the
  system shell does not inherit the control tree; `erx_devfs:start_link/0` unmounts
  whatever is at `/dev` before it mounts.
* [Medium] devices, `erx_devfs`: it is a permanent child of `erx_domain_sup`, whose
  intensity is one restart per permanent child within 5 s, shared by all of them, so a
  bug that crashes the `/dev` grant in a loop ends the system domain and resets the machine. Move it under a supervisor whose end
  the domain service survives, when the device service gets its own.
* [Low] devices, `erx_devfs`, `/dev`'s ctl writes: the facet call is the control tree's bounded work, with
  `erx_driver_ctl`'s 30 s deadline as the bound its grant may stop for (design-system.md, "The `/dev`
  tree"), and that bound is per write, not per tree: the facet takes no other request while a start runs,
  which nothing bounds (`erx_driver_ctl`'s moduledoc), so a second write queues behind the first and may
  answer `eio` after 30 s of its own for an operation not yet begun; a start that never returns holds
  the facet for good, and each later write then holds the grant 30 s before it answers `eio`. Bound the
  driver's start where the facet waits for it.
* [Low] devices, `erx_devfs`: `/dev` shows only the block device. Its `status` has no
  `path` line, because the catalogue that reaches Erlang has no device-tree path, and
  its `driver` line is `[unknown]`, because no facet says which process drives a unit.
  Show every catalogue entry, export the path from the boot view, and add a driver
  query to the driver-control interface.
* [Medium] `tools/lib/erx/native_irq.rb`, `DEVICE_NIF`: the device NIF's target sources are listed there and again in
  `otp/erts/emulator/Makefile.in`'s objects, and nothing keeps the two in step; a new NIF source added to the Makefile
  alone passes `make check` and breaks only the native_irq suite's link. Keep the list in one checked-in source that
  both builds read.
* [Medium] `erlang/apps/erx_uart/src/erx_mini_uart.erl`, the Raspberry Pi 4 console: a paste can lose bytes. The
  receive FIFO holds eight bytes (about 0.7 ms at 115200 baud) and the line has no flow control, and on Fiasco the
  interrupt raised after the line's acknowledgement is handled by its owner 0.6 to 6 ms later, longer than the
  FIFO lasts (docs/todo-fiasco.md, the late interrupt after an unmask). The driver drains the receive FIFO between
  the bytes of a send (`send_step/1`) and the shared line's owner runs at `high` priority
  (docs/design-shared-devices.md, "The owner"): at `normal` the owner waited about a millisecond behind the
  console process before it acknowledged, and at `high` it ran within about 25 to 40 us (Pi 4, native, the timing
  probe pasting 41-byte lines; history repository `pi4/2026-11-22-uart-gap/`, `uartgap1.txt` and
  `uartgap-high.txt`). What remains is not in the kernel: the interrupt probe found Fiasco's path to the
  dispatcher under 10 us and the delay in the owner's ERTS scheduler waiting behind other ERTS threads at the
  same priority on CPU 0 (history repository `pi4/2026-11-22-irq-probe/`, commits 924e652, de6a618 and 66b1a9e).
  The work is the bands of docs/design-fiasco.md ("Bands", "Urgency", "Scheduling"), with this driver at priority `high` (docs/design-shared-devices.md, "The owner"), after which that document's Pi 4 measurement is run. A lost byte is
  marked: the driver puts a NUL where the bytes were lost and the line editor refuses to finish a line that
  holds it (docs/design-live.md, "The console"), so what is left is the loss itself, a pasted line refused and
  typed again. Typing at human speed loses nothing, and the user guide sends pastes to SSH. Should a loss
  remain after both, the fallback is a native drain at the delivery into a ring the driver reads
  (docs/design-shared-devices.md and docs/design-fiasco.md, "Interrupts and readiness"), or the console on the
  PL011 UART0, with Bluetooth on the mini UART. A polled write of Fiasco's or the root's to the same UART also
  reads LSR (`fiasco/kernel/src/lib/uart/uart_16550.cc`, `write`), clearing the overrun bit before the driver
  sees it, so that loss goes unmarked, and holds a CPU while it writes; the overrun count is shown nowhere but
  the log, which an inspection path would fix. QEMU's `raspi4b` model is unlikely to show the loss: its mini
  UART is believed to take a byte only when its FIFO has room (unverified: read QEMU's `hw/char/bcm2835_aux.c`).
* [Low] `erlang/apps/erx_uart/src/erx_pl011.erl`, `send/2`: while `FR.TXFF` is clear the transmit loop writes without
  looking at `FR.RXFE` or its mailbox, so receive is not served at all during a run of writes, the shape
  `erx_mini_uart` polls around with `send_step/1`. The PL011's receive FIFO holds 32 bytes (DDI 0183G 2-6), so a run
  starves it only at that depth, and under `rts_cts` flow the UART holds RTS off when its receive FIFO is full.
  Mirroring the poll needs its own choice of whether a drain inside a send clears the interrupts (`deliver_input/1`
  writes ICR from MIS) and a played-device case like `erx_mini_uart_tests`'s.
* [Medium] `erlang/apps/erx_uart/src/erx_pl011.erl`: QEMU 11.1's PL011 writes each byte straight to its backend, so `FR.TXFF`
  never sets, and it forces the receive interrupt level to one byte, so the receive timeout never has a byte below the
  level to report; a character also arrives whole, never in flight. The `production_image` suite therefore still passes
  with the TXFF check before each `DR` write removed, with `RTIM` left masked, or with the character wait after
  disabling the UART removed. Run the real `erx_pl011` against a host register model behind `erx_device` that holds
  `TXFF` set for a while, delivers input below the level only through the receive timeout, counts `DR` reads and
  refuses a control register write while a received character is in flight, and require each of those mutations to fail.
* [Medium] Lane driver test between two domains, `test/guest/native_domain`:
  the `connection` cell drives the driver over one domain's system
  connection, with the root as the system party. Two domains connected by
  `erx_dom_lib_connect` cannot open their ports until `connection_up`
  (RT6b) tells a runtime the connection's values; that cell lands with RT6b.
* [Low] Lane driver, a test hook: the lane driver's control command 4 (`erx_lane_drv.c`,
  `control_hold`, allowed only under `-erx test_lane_hold`) holds a port's ring takes so the
  system_domain suite can fill the lane from the system domain, and so its connection_down
  step's burst waits in an introduced lane for the finish. Edit 15's queue quota fills a ring
  and pauses a port by design; once it lands, drive both steps from it and delete the hook,
  with the flag and `DOMAIN_ARGS`'s use of it.
* [Medium] Lane driver, `erx_lane_drv.c`: a side's part in its control table (writer,
  reader, none) is read from which of `ctl_seq` and `ctl_in` are NULL at each site
  (`table_step`, `control_record`, `control_hold`, the open). Give the connection an
  explicit role enum set once at open, so each site matches on it.
* [Low] Lane driver, `-erx lane_batch`: the allowance is
  `ERX_LANE_BATCH_DEFAULT` (64); `erl_init.c` does not parse the flag yet.
* [Medium] Lane driver review residuals, `otp/erts/emulator/sys/erxos/erx_lane_drv.c`
  and `test/guest/native_domain`: (1) one run of the input task is bounded by
  frames, not bytes, so 64 frames of `max_frame` each hold a scheduler for one
  run; bound it by bytes too, or charge reductions per byte. (2) The
  `ERX_FUNNEL_TOO_LARGE`, malformed-record, failed-grow, allowance-reschedule
  and port-stop paths have no QEMU case; the connection cell covers output
  pause and resume, an answer and the answers bound only; no case delivers a
  right-0 frame (`PAYLOAD_EXIT`, `UNLINK_ID`). (3) The step's sequencing
  (plan, grow or take, took, check, the answer gate, deliver, next) lives in
  `input_step`, which does not build for the host, so "DELIVER only with the
  record whole" and the answer gate have no unit test; design-domains.md's
  `erx_funnel_step` is that step as a pure function in `liberx` returning the
  next action, with host tests and a fuzz target, and the driver only carries
  the action out. Until then the asm fuzz target should feed several records
  through one grown buffer and assert no `DELIVER` while `held < frame`; no
  landing-gate host test drives `erx_funnel_asm` either. (4) The party's and
  the driver's frame headers are packed by hand until the generator emits
  `erx_frame_header_encode` (see the `wire_le` item above); until then the
  driver should use `ERX_FRAME_HEADER_OFF_*`, and output relies on the
  header's last byte doubling as the pass-through byte. (5) `answers_unsent` measures `total_qsize -
  qsize`, which also counts this domain's own sends with no process and its
  `async_dist` processes' sends, so a healthy connection can end; and an
  `UNLINK_ID` to a live target is acked later by the target, past the check.
  Count the answers at their source in `erts_net_message`'s `ERX_NET_*` path
  and take the bound from the boot page's `peer_held` (design-domains.md,
  "Flow control"), which deletes `op_answered`; `ERX_LANE_ANSWERS_MAX` stands
  in for it. (6) The connection case can end the port between two of the
  domain's 50 ms polls, and `domain_run` does not stop a domain whose end it
  did not see; `party_flood` does not tell a stall from a refusal. (7) No case
  streams between two domains (the deadlock the busy gate could cause); it
  lands with RT6b's two-domain cell. (8) `erx_funnel_asm_ungrown` and its
  `funnel.h` contract are used only by the fuzz target, and
  `erx_funnel_asm_took` treats a `GROW` plan as a skip rather than refusing
  it. (9) The open command (`lane_open_parse`) takes raw capability slots, a
  label and the peer's node name from any Erlang caller in the domain: open
  by an opaque connection id the runtime recorded from `connection_up` or
  the boot page instead, with the node name from the same record, and map
  the sides where that record is made, so the driver leaves the
  `device-memory-mapping` rule's sites; a table of
  {field, maximum} would also replace the positional `words[7]`. (10)
  `erts_net_message`'s result is ignored, so a frame the funnel accepted and
  ERTS refused does not end the port; output drops a frame with a control
  term of length 0 or past the limit but keeps the connection. Both should
  end the port. (11) The generic `erx_event_unregister` resolves a label below
  `ERX_LABEL_SPLIT` to a connection slot and frees it without aborting its
  tasks; no caller passes one, but it should refuse them. (12) `erx_funnel_asm_t`'s `held` and `hold` differ by a
  letter and mean different things; rename `hold` to `keep`.
  `connection_schedule` finds its handles by pointer arithmetic on the
  global table; keep them in the slot or pass the index. (13) A peer can grow
  a live process's signal queue without limit with right-0 signals
  (`UNLINK_ID`, `DEMONITOR_P`, `PAYLOAD_EXIT`); the queue quota covers only
  undecoded messages, and no design text bounds these.
* [Low] Lane driver, `otp/erts/emulator/sys/erxos/erx_lane_drv.c` (`frame_judge`): a frame the
  funnel refuses is counted (`ERX_LANE_COUNT_MALFORMED`) and ends the port with
  `erx_lane_malformed`, but nothing logs the funnel's reason (`verdict.reason`), where
  design-domains.md's failure table promises a diagnostic with the reason code, logged once
  per reason. The reason names live only in `test/fixtures/funnel_driver.c`; one table in
  `liberx` would serve the log and the fixture.
* [Medium] Security residual, object ids (`kernel/core/object.c`,
  `oid_round`): the Feistel round function is murmur3's finalizer keyed
  by one XOR, not a keyed PRF, so the claim that ids say nothing about how
  many objects anyone created rests on obscurity; the design names no
  round function or threat model. Choose a keyed PRF round (SipHash-1-3
  or HalfSipHash) and state the threat model in design-kernel.md.
* [High] storage and platforms, the Pi 4's boot image: the Pi 4's secure
  boot checks `boot.img` at about 2.6 MB/s under a firmware watchdog fixed
  at 4 s, and the boot image holds the kernel, the runtime image and the
  whole system release, tens of megabytes with ERTS, so the check alone
  outruns the watchdog. Decide what the signed boot image holds: the
  kernel, `liberx` and a root image that mounts the release's EROFS image
  from the slot under its hash tree, with the slot image's root hash in
  the signed part, or a boot image sized to the firmware's checking rate
  measured by the boot probe; restate "the boot image stays small" and
  "the boot image holds the release" so one of them goes
  ([design-storage.md](design-storage.md#data-model),
  [design-platforms.md](design-platforms.md#trust-in-the-boot)).
* [Medium] system, devices: a bus abort or a fault inside the device NIF
  ends the whole domain that holds the device, the devices domain with
  every slow device on it. Decide whether the NIF's register access runs
  in a per-device sub-space shim, so an abort ends one device's shim, or
  whether the per-device-domain rule extends to devices that can abort
  ([design-system.md](design-system.md#drivers),
  [design-runtime.md](design-runtime.md#the-device-nif)).
* [Medium] storage and platforms, the boot-selection record: the slot
  writer sees the record as one sector, while the Pi firmware reads it
  through FAT metadata in the same partition, so a damaged directory entry
  leaves erXos seeing a valid record while the firmware boots its default
  forever. Have the slot writer verify the record through the FAT
  structures the firmware walks, and test a damaged entry on the board
  ([design-storage.md](design-storage.md#system-updates),
  [design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record)).
* [Medium] arch-aarch64, boot: the Pi firmware may ignore `image_size` and
  place the initial RAM disk right after the kernel file, and the entry
  zeroes `.bss`. Check at entry that the boot image and the device tree do
  not overlap the kernel image, instead of relying on a one-time probe
  ([design-arch-aarch64.md](design-arch-aarch64.md)).
* [Low] kernel and platforms, store tracking: measure which accelerators
  and boards report `FEAT_HAFDBS` (`ID_AA64MMFR1_EL1.HAFDBS`), so that
  store tracking uses hardware dirty-state management where it exists
  and write-protect faults elsewhere
  ([design-arch-aarch64.md](design-arch-aarch64.md#translation)).
* [Low] platforms, the real-time clock: no board but QEMU `virt` has the PL031 the
  kernel's device table takes as its real-time clock, and the Raspberry Pi 4 takes a DS3231 module. Name the
  Raspberry Pi 5's clock, or read wall time from the firmware
  ([design-platforms.md](design-platforms.md)).
* [Low] platforms, panic output: the board port measures whether the
  kernel's polled early-console writes at a panic complete after the
  console driver has reconfigured the UART, on each board
  ([design-platforms.md](design-platforms.md#uarts)).
* [Medium] boot image, `kernel/core/boot_place.c`: Phase 1 keeps the two
  roles `boot/sigma0` and `boot/fiasco-root`, since Fiasco starts sigma0
  and a root task from its information page, and sigma0 pages that root
  with read, write and execute over its whole range, gaps between segments
  included, which nothing zeroes; Phase 1 accepts this
  ([design-fiasco.md](design-fiasco.md#boot-handoff)). erXos's
  kernel maps the root task from the startup plan, so Track K decides
  whether the image keeps the two entries, which that kernel would ignore,
  or drops them with their ABI paths and the recipe in
  `tools/lib/erx/boot_image.rb`. `tools/lib/erx/boot_image.rb` builds on
  the test fixtures' empty manifest until production packing
  lands.
* [Medium] DMA, the slot device context's ownership rests on the reach rules (`erx_device_sequencer.c`,
  `erx_dma_publish_controller`; `erx_device_ledger.c`): the sequencer zeroes slot k's device context at any
  publication that binds EP0, which is safe because Address Device alone binds index 1, no reach drops it, and
  only Disable Slot or the reset unbinds it. Nothing checks that as one property, so a reach added later (Reset
  Device, xHCI 4.6.11) or a wider drop mask would let the CPU zero a context the controller holds. Make it a
  ledger fact: a host test over the reach rules with a seed that widens a drop mask, or a ledger predicate the
  sequencer asks.
* [Medium] DMA, the TRB form's core (`erx_device_trb_form.c`): it is the one xHCI path, host-tested. Its posts, completions and queue states are applied in C by `erx_device_trb_post`, `erx_device_trb_command`, `erx_device_trb_complete` and `erx_device_trb_queue_state` (`erx_device_xhci.h`), host-tested over the harness below, and `erx_device_nif.c` decodes `erx_device:post/4`'s TRB shapes, `complete(Dev, events)` and `queue_state/2` onto them; the hosted test (`runtime_device_test.rb`) checks only the decoding's refusals on a virtio stand-in, since no stand-in xHCI runs the form under the hosted runtime yet: a stand-in over `erx_device_trb_model`, as GENET's is over its model, would test what a decode builds and the answer terms end to end. From the decoding's review: (High) the NIF takes at most `ERX_DMA_BINDS_MAX` (4) adds in one Configure Endpoint and refuses more with badarg, as design-usb.md says ("a configuration that adds more is added by several commands"), but `erx_xhci_core` posts every claimed pipe, up to 7 (`erx_usb_claim`'s `ERX_USB_ENDPOINTS_MAX`), in one command and `erx_xhci` does not catch the badarg, so a device with 5 to 7 pipes ends the controller on every enumeration; `erx_xhci_core` must split the adds (wt-usb-xhci). (Medium) four bulk blocks a controller and a drop-and-add needing a spare one: with two mass-storage devices attached, a bulk pipe's reset is `{error, full}`, which `erx_xhci_core` turns into a controller failure. (Medium) block choice is a step `erx_device_trb_command` runs before `erx_trb_form_command` (`erx_trb_form_choose_blocks`), while `erx_trb_add_t.block` stays an input the form honours and its harness exercises; the form should choose inside `erx_trb_form_command`, after its parameter checks (an out-of-range slot with no free block is `{error, full}` where the design says badarg), with one table from endpoint type to block kind instead of `type_kind` beside `endpoint_type`. (Low) `erx_xhci_core` counts `complete(Dev, events)`'s answers as events read, so a batch of events that answer nothing ends a pass early. From the posts' review: (Medium) ERDP is written on every completion call, the empty pass that ends an interrupt drain included, where design-usb.md says after each decision that consumes events; one of the two should change. (Medium) `erx_device_trb_complete` answers ERX_EINVAL, dropping the answers the core already gave and leaving the form whole, when ERDP cannot be stated for the core's dequeue position, and `erx_device_trb_command` the same when doorbell 0 cannot be named; neither is reachable from a layout the record accepted, and checking both once when the record is made would remove these paths. (Low) the TRB sink is handed the whole `erx_trb_answer_t`, `data.offset` included, an offset only the effect layer needs. A port event's port is not checked against the port count, as design-usb.md's Completing says it is, nor is what a failed check does stated there. Its install and `negotiate/2`'s reset and start before it (`erx_trb_form_start_next`, applied by `trb_ring_negotiate` in `erx_device.c`) are built and host-tested over a harness that plays the controller (`erx_device_xhci_harness.c`); nothing has run them on `qemu-xhci` or the VL805 yet. From the start's review: [High, open, needs a decision] `trb_ring_t.step` outlives a controller process, so a restart after the install deadline resumes the old wait (halted, or HCH clearing after run) instead of resetting again, and a controller that ignored the first run-0 write waits at HALTING for good, where GENET rewrites its stop every call; the NIF needs an explicit start of a negotiation (negotiate/2's unused `wanted`, the record's reopen, or an abandon call from the deadline path), and STARTING should go back to BEGIN on `USBSTS.HCE` or `HSE`. (Medium) `field_word` keeps every preserve bit as read, so owned bits the install should decide (`USBCMD.HSEE`, `RS` in the reset word, `CONFIG.CIE` and `U3E`, `ERDP.DESI`) are copied from the controller; start an owned register from 0 and keep only `preserve & ~owned` elsewhere, as a pure `erx_device_owned_word` beside `erx_device_field_plan` in `erx_device_core.h`. (Medium) MaxSlots 0 or MaxPorts 0 is refused through the layout as `erange`, and `trb_ring_create` folds no room, a kernel `erx_mem_dma_addr` failure, the contiguity check and a form-make bug into one `erange`; split them and add the rows to design-usb.md's refusal table. (Medium) the TRB record shares `queues[]`'s union, so `reset_queues`, `install_queues` and `queue_of` stay safe only by a list of call sites; give it its own home or one `queue_form_of(device)`, and form checks in the two iterators. (Medium) `xhci_registers` looks registers and fields up by name at run time with a failure path each, beside the generated `ERX_DEVICE_OWNED_XHCI_*` indices, into a hand-sized `fields[16]`, and `xhci_field` copies `stand_in_field`. (Low) HALTING writes `HCRST` again to a controller found mid-reset (wait while `resetting`); the CRCR cycle state is taken out with RCS's field position rather than the sequencer's bit 0; `INTE` follows run in one write; PAGESIZE is read before CNR is seen clear (unchecked against xHCI 4.2); reserved-and-preserved bits are written 0 (unchecked against xHCI 5.1); the comment above `apply_memory` still describes the select, registers and doorbell; tests lack an abandoned negotiation, an install refusal returning to BEGIN, MaxSlots/MaxPorts 0, a refusal taking nothing, and seeds for the RCS bit, swapped address words and memory after registers. It still needs a generated way to write `ERDP` with its busy bit, whose `oneToClear` field in a register with other fields gets no setter from the SVD generator (`erx_trb_form_complete` gives the dequeue pointer alone). `erx_trb_form_t` keeps its `shape`, `ports` and `slots` beside the `layout` that holds them, so that the queue-state branch's edits of the command checks merge cleanly; they fold into `layout` once both have landed. From the install's review (Medium): `erx_dma_register_t` holds virtio's and xHCI's registers in one enum, so each effect layer lists the other form's values and `put_ring_register` drops an xHCI write silently; give each form its own register type, or tag the sequence's writes by form. `erx_dma_install_controller` takes the ledger and the controller's layout on trust that one was derived from the other (the link and `CRCR` come from the ledger, the rest from the layout), and `store_scratchpad` repeats the layout's placement of the scratchpad array after its pages; the layout should record the array's offset, or the DCBAA, scratchpad and segment table become regions of `erx_dma_layout_t`, so one `install` serves both forms. The xHCI install has no seeded faults, and the top of `erx_device_sequencer.h` still describes only virtio's install. Also open there: `pool_first_buffer` repeats the ledger's numbering of buffers across pools; the ledger's bounds come from `erx_device_trb.h`, which a neutral bounds header would hold instead; the input context's pool size is its region's granule-rounded length.
* [Medium] DMA, the TRB form's core (`erx_device_trb_form.c`): its install and `negotiate/2`'s reset and start before it (`erx_trb_form_start_next`, applied by `trb_ring_negotiate` in `erx_device.c`) are built and host-tested over a harness that plays the controller (`erx_device_xhci_harness.c`); nothing has run them on `qemu-xhci` or the VL805 yet. From the start's review: (Medium) the rule that a `negotiate/2` call begins unless it passes `continue` is stated for the TRB form alone (design-usb.md "Install", the refusal rows of design-usb.md and design-device-dma.md), and `erx_device_negotiate` refuses `continue` on every form but xHCI; the ADMA2 table's install (design-device-dma.md, "Install and reset") also takes steps across calls, so state the rule once there for every form (a form with steps continues from its kept step, one without refuses `continue`) and test "does this form keep a step" in C instead of "is it xHCI", before ADMA2 is built. (Medium) `field_word` keeps every preserve bit as read, so owned bits the install should decide (`USBCMD.HSEE`, `RS` in the reset word, `CONFIG.CIE` and `U3E`, `ERDP.DESI`) are copied from the controller; start an owned register from 0 and keep only `preserve & ~owned` elsewhere, as a pure `erx_device_owned_word` beside `erx_device_field_plan` in `erx_device_core.h`. (Medium) MaxSlots 0 or MaxPorts 0 is refused through the layout as `erange`, and `trb_ring_create` folds no room, a kernel `erx_mem_dma_addr` failure, the contiguity check and a form-make bug into one `erange`; split them and add the rows to design-usb.md's refusal table. (Medium) the TRB record shares `queues[]`'s union, so `reset_queues`, `install_queues` and `queue_of` stay safe only by a list of call sites; give it its own home or one `queue_form_of(device)`, and form checks in the two iterators. (Medium) `xhci_registers` looks registers and fields up by name at run time with a failure path each, beside the generated `ERX_DEVICE_OWNED_XHCI_*` indices, into a hand-sized `fields[16]`, and `xhci_field` copies `stand_in_field`. (Low) the CRCR cycle state is taken out with RCS's field position rather than the sequencer's bit 0; `INTE` follows run in one write; PAGESIZE is read before CNR is seen clear (unchecked against xHCI 4.2); reserved-and-preserved bits are written 0 (unchecked against xHCI 5.1); the comment above `apply_memory` still describes the select, registers and doorbell; tests lack an install refusal returning to BEGIN, MaxSlots/MaxPorts 0, a refusal taking nothing, and seeds for the RCS bit, swapped address words and memory after registers. It still needs a generated way to write `ERDP` with its busy bit, whose `oneToClear` field in a register with other fields gets no setter from the SVD generator (`erx_trb_form_complete` gives the dequeue pointer alone). `erx_trb_form_t` keeps its `shape`, `ports` and `slots` beside the `layout` that holds them, so that the queue-state branch's edits of the command checks merge cleanly; they fold into `layout` once both have landed. From the install's review (Medium): `erx_dma_register_t` holds virtio's and xHCI's registers in one enum, so each effect layer lists the other form's values and `put_ring_register` drops an xHCI write silently; give each form its own register type, or tag the sequence's writes by form. `erx_dma_install_controller` takes the ledger and the controller's layout on trust that one was derived from the other (the link and `CRCR` come from the ledger, the rest from the layout), and `store_scratchpad` repeats the layout's placement of the scratchpad array after its pages; the layout should record the array's offset, or the DCBAA, scratchpad and segment table become regions of `erx_dma_layout_t`, so one `install` serves both forms. The xHCI install has no seeded faults, and the top of `erx_device_sequencer.h` still describes only virtio's install. Also open there: `pool_first_buffer` repeats the ledger's numbering of buffers across pools; the ledger's bounds come from `erx_device_trb.h`, which a neutral bounds header would hold instead; the input context's pool size is its region's granule-rounded length.
* [Medium] DMA, the TRB form's input context and slots (`erx_device_sequencer.c`, `erx_device_ledger.c`): `place_input_context` composes into 33 parts though a publication carries at most `ERX_DMA_INPUT_PARTS_MAX`; the commands that carry the input context are one list (`erx_dma_carries_input_context`), where a mark in abi/formats could make it generated; nor is a slot's holding, its DCBAA entry and device context from its first Address Device, in the ledger, as design-usb.md's "Bindings and holdings" gives it.
* [Medium] DMA, the TRB form's Error state (`reach_restart` in `erx_device_ledger.c`, `error_event` in `erx_device_trb_form.c`): the ledger halts an endpoint on every error code, as xHCI 1.2, 4.10.2 (p. 195) says, but 4.8.3 (p. 164) has a TRB Error enter the Error state, which only Set TR Dequeue Pointer leaves (4.6.10, p. 141). On a controller that follows 4.8.3 the ledger holds `halted`, Reset Endpoint answers Context State Error, Set TR Dequeue Pointer is badarg (accepted only on `stopped`) and a drop is refused, so only Disable Slot recovers the endpoint. Fails safe; a TRB Error should come only from a form bug or a quirky controller. Fix: an Error state entered on the TRB Error code, with `reach_restart` taking it beside `stopped`, and erx_xhci_core.erl planning Set TR Dequeue Pointer from it.
* [Low] DMA, the TRB form's slots (`command_event` in `erx_device_trb_form.c`): an Enable Slot success naming slot 0, a slot past the layout's or one already enabled enables nothing and is answered as a plain success, where a value the controller cannot rightly write should fail the event with ECORRUPT (checked before `erx_dma_ledger_complete_command` changes the ledger); the slot's state is two parallel arrays (`enabled`, and `addressed` whose nonzero `route_speed` means addressed) that one per-slot record would join; and the fuzz target's honest command completion leaves the slot field 0, so a script's Enable Slot never enables a slot and Disable Slot then Enable Slot then Address Device goes unfuzzed.
* [Low] DMA, the TRB form's shape (`shape_valid` in `erx_device_trb.c`): a shape must leave three positions of each
  ring free beside its posted TRBs, a reserve sized for a stop span the form does not keep; the check's room rule
  may make one or two enough.
* [Medium] DMA, the TRB form's model harness (`test/fixtures/erx_device_trb_form_model_harness.c`,
  `erx_device_trb_model.c`): the model's Stopped event inside a TD never runs, since the form publishes a whole TD
  at once and the model takes it in one go (a per-call TRB budget would let a run end mid-TD), and the trace checks
  none of its failure, short and stopped counts; its effect layer (`maintain`, `activate_run`, the zeros, fills,
  stores and cleans of `apply_sequence`) copies `erx_device_dma_model_harness.c`'s, which one fixture header could
  hold, settle and activation passed in; the transaction-error check trusts a count `start_ring`, drops and Disable
  Slot leave stale, where the model could record the TD it failed; the seed tests match any FAILED line rather than
  each seed's check; the model refuses ERDP's low bits, where the form's header has the effect layer write the busy
  bit; `report` writes Command Completion events through the Transfer Event's offsets, equal in abi/formats/xhci.txt
  but unasserted; and the harness sets the model's `fail` and `short_packet` fields directly.
* [Low] DMA, the TRB form's stop events (`stop_event` in `erx_device_trb_form.c`): a stop's transfer event is accepted when it names any record of the ring bound to the stopping endpoint, not only one inside the stop span design-usb.md's "Completing" gives. It completes nothing, so the gap fails safe, but an event the controller could not have written passes.
* [Low] DMA, the ledger's reach rules (`reach_rule_t` in `erx_device_ledger.c`): the endpoints a reach acts on are a flag (`whole_group`) and two masks (`named_states`, whose being nonzero means the named endpoint, and `holds`) beside the implicit binds-and-drops case, so a row can set several, where an enum would make that unwritable; the state preconditions in `erx_dma_ledger_reach_allows` (a drop neither disabled nor halted, a removal not busy, a held endpoint running or stopped and idle) are code, not columns, but the named endpoint's, which is `named_states`; and no test keeps the attempt to build a reach without its row (`ERX_REACHES`), which fails by construction (`&reach_##name` names an undeclared identifier).
* [Low] DMA, the TRB form's commands, small findings: `holding_of` reads `records[0]` under the places count rather than `record_count`; a second binding command adding the in-flight one's block is refused as BADARG, not FULL; a stop's success sets stopped over halted; `erx_trb_form_endpoint` and `erx_dma_endpoint` number endpoints twice; the fuzz target never adds 3 or 4 endpoints, and a drop-and-add's failure has no directed test; `refuse_misplaced_reach` in `abi_marks.rb` sits between `refuse_writer_marks` and its comment.
* [Low] DMA, `erx_device_sequencer.c` (`encode`): the switch from meaning to encoder is written by hand, a case per meaning (each command TRB adds one); the generator could emit one encoder entry per meaning from the marks.
* [Medium] devices, a piece's kind (`erx_device.h`'s `erx_device_piece_t`, `erx_device_dma.h`'s
  `erx_dma_piece_t`): two booleans, `device_writes` and `names_region`, say what a piece is, so a region the
  device writes is representable and refused at run time (`erx_device_virtio_core.c`'s chain check). One closed
  enum (the device reads, the device writes, a region) makes it unrepresentable. About sixty sites in eighteen
  files use the booleans, most in the old virtio core, its harness and fuzz target and the TRB form; done after
  the old core goes, and with the TRB form's branch landed, it is a mechanical change.
* [Low] PCIe, a 32-bit MSI with per-vector masking (`erx_pcie_cfg`, `erx_pcie_plan`): where its mask and pending
  registers lie is unverified. FreeBSD 15.1.0's `pcireg.h` gives `PCIR_MSI_MASK` (0x10) only for the 64-bit layout,
  and its `pci.c` never touches the mask register, so the parser ends that layout's extent at its data and the
  planner leaves its mask register unwritten, where a firmware that masked vector 0 would keep its message masked.
  Settle the offsets from the PCI Local Bus Specification or another BSD source and plan the register as the 64-bit
  one is.
* [Medium] PCIe, a root port's closed windows (`erx_pcie_plan`, [design-pcie.md](design-pcie.md#root-ports)): the
  plan closes a root port's I/O and prefetchable windows by writing base above limit, but a root port that implements
  neither window reads those registers as zero and never reads as its target: every walk lowers it to quiet, cutting
  off the bus below it, and its plan ends `stuck`, so a restart would disturb running functions. Whether
  QEMU's `pcie-root-port` and the BCM2711's root port implement both is unverified; probe B4 and the `pcie` suite
  settle it, and a window a root port lacks then drops out of its target.
* [Low] boot records, `Erx::Manifest#boot_args` (`tools/lib/erx/manifest.rb`) and
  `erx_domain_srv:boot_args/2`: a row's `args` may carry `-erx_record`, as they may not carry `-boot`, so
  a row's own words can read as a record the domain library writes (for `system_image`, the
  `record_volume` mark, which grants nothing without the block device). Refuse `-erx_record` there.


## Security residuals

* [Medium] hostile suites, an interrupt storm on a driver's line on Fiasco: a line held asserted, or
  raised at the device's fastest rate, whose pass is that the machine and the other domains keep
  running, so the downside above is measured rather than assumed (FD33's recommendation). It needs a
  device on QEMU `virt` that a test can make interrupt without end.

* [Medium] platforms, bus masters the loader left running
  ([design-platforms.md](design-platforms.md#dma)): a bus master
  the loader started is part of the trusted loader until its driver
  resets it. A device's own buffers and descriptors are installed only
  after that reset, through the one install path (`negotiate/2` in the
  device NIF, or a native shim's `negotiate` under the same contract),
  but nothing keeps the device away from memory before it: from the
  kernel's first instruction until the reset, a master the firmware
  started can write whatever memory it reaches, memory the kernel has
  already handed out included, and no check sees it. The design does not
  close this window. On the Pi 4 every DMA master is unconfined:
  the window is all memory below its bus's limit, and it closes for the
  VL805 at the PCIe domain's first start, which clears its bus
  mastering, and for each driven device at its driver's `negotiate/2`.
  A master no driver of erXos resets, the DWC2 on the USB-C connector,
  each DMA channel the manifest gives no driver and the VideoCore's
  blocks among them, stays the loader's for the whole boot. On the
  Raspberry Pi 5 RP1 is one PCIe function, so the PCIe domain's first
  start stops all of its masters, and its mastering is raised again once
  the GEM's and the named USB hosts' drivers have reset them
  ([design-rp1.md](design-rp1.md#mastering)); RP1's other masters,
  its DMA controller among them, which erXos does not drive, go on from
  then as the loader left them. On QEMU
  `virt` the window is all memory for a virtio-mmio device, and for a
  confined function ends at the kernel's IOMMU abort. The board's
  installation sets the EEPROM's boot order to the microSD card alone, so
  that the boot firmware has no reason to start the VL805; probe B3
  ([design-usb.md](design-usb.md#the-bcm2711-bridge)) shows whether
  it does, and its answer belongs here. The stand-in test of a device the
  loader left running, under Reset before use in the same design's
  verification, is not written yet.
* [Low] platforms, QEMU `virt`'s fw-cfg device: check whether its node,
  `qemu,fw-cfg-mmio`, offers the DMA interface on the pinned QEMU. If it
  does, list it among the bus masters of the DMA contract; the system
  manifest gives it to no domain
  ([design-platforms.md](design-platforms.md#dma)).

## Planned features

* [Low] DMA check and device NIF, simplicity pass (CLAUDE.md, "Checks stay few and earn their place"): the DMA
  check is past the 1,000-line mark (`erx_device_ledger.c`, `erx_device_sequencer.c`, `erx_device_rules.c` and
  their headers, about 3,600 lines), and `otp/erts/emulator/nifs/erxos/erx_device.c` (about 3,250 lines) holds the
  open, three forms' glue, MSI-X, the xHCI register walk and the virtio and GENET stand-ins. Give both a
  simplicity pass before either grows further.
* [Medium] pin control, the pin table ([design-pinctrl.md](design-pinctrl.md#the-pin-table);
  `tools/lib/erx/pin_table.rb`, `abi/manifest.txt`): the header probe's GPFSEL1 and GPFSEL2 readings recorded as
  its board evidence; the `pins` record and its packed layout in `abi/erx_abi.txt`, counted in the boot page's room,
  and the domain library's writer; the map of function numbers generated from `hw/pins/<kind>.txt`, from which
  `ERX_BCM2711_PINS_FIRST` (`include/erx/core/bcm2711_pins.h`) and `Pins::BANK0_PIN_COUNT` (`tools/lib/erx/pins.rb`),
  two hand-written copies of bank 0's size, are derived; a range on `pins[].pin` in the manifest reader, bounded
  by the most pins a controller of `hw/pins` has (today only the root's shim refuses a pin past GPIO 57); the
  manifest check's unit, holder and one-GPIO-controller clauses.
* [Medium] pin control, the rows the root writes at boot: `erx_boot_pin_rows`
  (`liberx/backend/core/boot_manifest.c`) and the manifest report's `boot_pin_rows` (`tools/lib/erx/manifest.rb`),
  which the boot's checkpoint expects, state one selection twice, in C and in Ruby; `boot_manifest_test.rb` holds
  them to one count on the shipped Pi 4 manifest. The C takes the rows whose device column is the first
  device-tree row of the BCM2711's compatible string in a unit the system domain holds (erx_boot_held_row), the
  Ruby the rows of any device in a unit the system domain holds. The C's rows are always among the Ruby's, so
  they differ only by the C taking fewer, which fails the boot's checkpoint rather than passing it: on a
  manifest whose system domain holds a second row of that compatible string earlier in the devices table (a
  gpiomem alias in another unit), or whose entry's first controller device is of another compatible string. And
  since the checkpoint's count is the packer's, a packer that dropped a row from `pins` would pass the boot; only
  `boot_manifest_test.rb`'s count of UART0's four rows catches that. The domain library's writer replaces both.
* [Medium] pin control, the `erx_pins` driver on the BCM2711 ([design-pinctrl.md](design-pinctrl.md#the-pin-driver)),
  after the table, over the pure `erx_pins_core` and `erx_pins_bcm2711` that are built: the register module with
  `hw/svd/bcm2711_gpio`'s pull registers, the driver process that reads, plans, applies and checks, its start in
  the system release before the domain service and the line service with the release booting the configuration
  `erx_pins_core:configuration/1` chooses, the generated mark of which configurations use each device, the log
  line, the chokepoint entry and `/proc/domains/D/pins`. The QEMU `raspi4b` cases run over every row: the model
  keeps function and pull fields and shows GPSET and GPCLR at GPLEV, and no row states an edge
  ([research-qemu-raspi4b-pins.md](research-qemu-raspi4b-pins.md)). The platform record's `gpio` row is 180
  bytes, shorter than the SVD's block of `0xf4`, which holds the pull registers at `0xe4`; widen it, since the device
  NIF refuses a record smaller than its peripheral's block. In the same change the root's write goes:
  `kernel/core/bcm2711_pins.c` and its header, `liberx/backend/fiasco/bcm2711_pins.c`, `board_pins` and
  `root_report_pins`, the chokepoint group and `onboard_pins`. Parity on the board: GPFSEL3 reads `0x00000fff` and the
  Bluetooth controller answers; the boot time before and after.
* [Medium] pin control, `/dev/gpio` ([design-header-io.md](design-header-io.md#devgpio); plan.md 1b-I (e), package
  4): the `gpio` service of `erx_pins`, `erx_hold`, an unheld pin taken only when it reads idle,
  edge events, the LED and the button. QEMU `raspi4b` keeps none of the detect enables
  ([research-qemu-raspi4b-pins.md](research-qemu-raspi4b-pins.md)), so on the model an `edge` line answers `eio` and
  `event` reports nothing; how the QEMU suite's edge cases treat the model is settled with them.
* [Medium] pin control, RP1 ([design-rp1.md](design-rp1.md#pins)), with 1b-J's RP1 package: `hw/pins/rp1.txt` from
  [research-rp1-clocks.md](research-rp1-clocks.md), section 6; the `rp1` kind, which plans a pin's `CTRL` and pad together
  in the order the design gives; the pin parts, `pads_bank2` among them, and RP1's rows; `erx_pins` in the unit
  supervisor after `erx_rp1`, and the mastering barrier leaving the pin blocks out by role; `erx_pins:select/2`,
  first used by the GEM driver's PHY reset; `INOVER`'s values into
  the facts record, after which the kind plans the field; from the board, the pulls the firmware leaves on GPIO 42
  and 43.
* [Medium] pin control, the BCM2712's two pin controllers: no binding document exists for them at the pinned commit,
  so a clean-room facts record of their function and pad registers and encodings comes first; then
  `hw/pins/bcm2712.txt`, the `bcm2712` kind and the Pi 5's rows for the SD slot, the Bluetooth UART and the WiFi slot.
  Until then those pins are as the firmware leaves them.
* [Low] pin control, WiFi's SDIO pins ([design-wifi.md](design-wifi.md#facts-this-design-does-not-have), F1): GPIO 34
  to 39 as on-board rows with their pulls, and their rows of `hw/pins/bcm2711.txt` from Table 94, once `erx_pins`
  sets pulls.
* [Low] pin control, the host link's overlay (`hw/dts/raspi4b-uart3.dtso`): remove `pinctrl-names` and `pinctrl-0`,
  which nothing reads and which state rows 4 and 5 of the header map a second time.
* [Low] pin control, `erx_pins_bcm2711` (`erlang/apps/erx_pins/src/erx_pins_bcm2711.erl`): a pin's field is read
  in three places, `field_agrees/2`, `drives/3` and `read_code/5`; fold them into one reader of a `#field{}`.
* [Low] pin control, `erx_pins_core:start_verdict/3` (`erlang/apps/erx_pins/src/erx_pins_core.erl`): the verdict
  does not name its controller, so the release's log of a failed start cannot say which one; add the name with the
  driver process, which knows it.
* [Low] pin control, `config.txt`'s `gpio=` lines (`tools/lib/erx/boot_partition.rb`): delete them with `erx_pins`'
  landing ([design-pinctrl.md](design-pinctrl.md#decisions), 3), once it is settled whether the probe card or a native
  partial boot, which run no pin driver, needs the host link.
* [Low] pin control, the `pins` service and `/dev/pins` ([design-pinctrl.md](design-pinctrl.md#interfaces)): built
  with the first driver that selects a state from another domain, likely the Pi 5's SD power cycle, whose
  hardware start then runs from its row's `-eval`, after the ready answer brings the grant
  ([design-storage.md](design-storage.md#the-raspberry-pi-5s-controller)).
* [Low] pin control, one pin served both as plain GPIO and as a device's
  ([design-pinctrl.md](design-pinctrl.md#a-pin-that-is-sometimes-a-devices)): not designed. Design it with PWM, its
  first consumer, as a hold in `erx_hold` that is never inferred from the registers, and state what a restart of
  the pin driver does to it.
* [Low] pin control, rows from a board's tree ([design-pinctrl.md](design-pinctrl.md#rows-from-a-boards-tree)):
  `erx_dt`'s pin query, the two group decoders and their fuzz targets, built for the first board that needs them, on
  open decision 4.
* [Low] pin control, pins per app ([design-packaging.md](design-packaging.md#the-declaration)): every app shares the
  app template's `gpio` scope. If two apps of one image need different pins, the `apps` row offers pins and a
  declaration chooses among them, one app to a pin, as `gatt` chooses GATT services.
* [Low] pin control, research records: the surveys of other systems and the two clean-room facts records of
  2026-11-23 that [design-pinctrl.md](design-pinctrl.md#references) rests on are not in the tree; land them as
  research records and cite them from the design.
* [Low] line groups (`erx_uart_sup:fresh/2`): a manifest binary whose line-interface service is not named `line`,
  which the manifest check refuses but the root's reader does not, gives a line record with no grant and a badmatch
  that stops `erx_uart`; refuse it with a stated reason.
* [Medium] platform (Raspberry Pi 4), hardware watchdog on Fiasco: a board that runs unattended has no
  hardware watchdog behind a hang of Fiasco or of the root's watchdog thread, because the watchdog the
  firmware starts from `kernel_watchdog_timeout` needs a reload that only erXos's kernel makes
  ([design-platforms.md](design-platforms.md#the-watchdog)); a reload from the root would rebuild a
  kernel mechanism in user mode. Residual until M12: the unattended board's `config.txt` sets the line
  once erXos's kernel runs there.
* [Medium] platform (Raspberry Pi 4), RNG200, `liberx/backend/fiasco/rng200.c`: the root's read is written from
  the clean-room facts record alone and has run on no RNG200: QEMU's `raspi4b` model has none, and its tree
  disables the node. The Pi 4 boots recorded in the history repository, `pi4/2026-11-23-fiasco-llvm/boot.uart.log`
  at commit 466fd21 and `pi4/2026-11-23-onboard-pins/boot.uart.log` at commit f2e3cc9, print `erx: entropy: from
  /chosen/rng-seed (64 bytes), /chosen/kaslr-seed (8 bytes) and the counter`: that board's firmware writes both
  seeds, so the root skips the RNG200 read there. What no boot has settled matters only on firmware that writes no
  seed, and a probe on such a Pi 4, read from the entropy line, settles it: whether the generator, started only by
  setting CTRL bit 0, with no warm-up and no soft reset, gives FIFO_COUNT eight words within the 100 ms bound;
  whether the firmware leaves CTRL bits above bit 0 set with bit 0 clear, which the root does not write back, so the line
  says the RNG200 could not be read (if it does, the SVD names those bits or marks them kept on write); and whether the registers that rest on one source
  each (the soft resets at 0x04 and 0x08, the total bit count and its threshold at 0x0c and 0x10, the status at
  0x18) matter to a read after a cold boot. erXos's kernel's platform layer reads it through the same
  `kernel/core/rng200.c` ([design-platforms.md](design-platforms.md#entropy-sources)).
* [Medium] board sensors, [design-board-sensors.md](design-board-sensors.md): not built. The root's firmware request
  (`erx_firmware_request_row`) reaches the mailbox, and the device service's PCIe process and its firmware worker
  ([design-system.md](design-system.md#devices), "Firmware requests") make the VL805's notification for
  `pci_bus:firmware/1` and the Bluetooth power line's off and on requests (`erx_devices:power/2`, which the
  UART line service calls), but nothing makes a sensor's request: no reading, throttle or other sensor tag is
  declared and no sensor driver exists. They come with the sensor driver; probes S1 and S2 come first.
* [Medium] board sensors, `abi/formats/vc_property.txt` and `abi/inspection.txt`
  ([design-board-sensors.md](design-board-sensors.md#the-requests)): `vc_property.txt` declares the property
  buffer's layouts, the closed set `fw_tag` with NOTIFY_XHCI_RESET and SET_GPIO_STATE, the power line
  `fw_power_line` (`bt_power`) with its phases, and four loose limits per tag (request, window, least answer and
  result word) that `kernel/core/vc_property.c` assembles by hand into one `erx_vc_tag_t` per tag and bounds with a
  `_Static_assert` each, and the schema has no `sensors` kind. Make the tags one
  generated table (tag, belonging, request, window, least answer, whether the tag answers in its first value word) whose
  generator checks each row's bounds, derives `vc_request_max` and the buffer's size from the rows and emits the
  core's table, so no caller builds a declaration and the hand-kept asserts go; add `fw_reading` and `fw_throttle` with
  its span and `board_sensor_period`; add the kind `sensors` at `[sensors]`, the units `mdegC`, `uV` and `Hz`, and
  `@fw_throttle`. The device-kind table that Ruby parses from `include/erx/device_kinds.h` folds with the same ABI
  form, as typed columns on ABI enum members, when these requests land.
* [Low] boot records, `-erx_record given` ([design-fiasco.md](design-fiasco.md#device-records)): the record's
  field list is kept by hand in its C writer (`erx_boot_given_words`), its room (`ERX_BOOT_GIVEN_WORDS_MAX`), its
  Erlang reader (`erx_device_record:spec/2`, whose error clauses match a positional tuple), the native guest's
  reader and `ProductionImage::Run::GIVEN_RECORD_WORDS`; one declared grammar would generate them.
* [Medium] PCIe, `erlang/apps/erx_pcie/src/erx_pcie_bcm2711_core.erl` ([design-pcie.md](design-pcie.md#the-bridge-seam)):
  the core runs an agenda of closures, so its state cannot be printed, compared or explored exhaustively, and its
  operation vocabulary (`{wait, Us}`, `{read, Register}`, `{write, Register, Word}`) is a second one beside
  `erx_genet_core`'s. Recast it as straight-line write lists with its four decision points (the link, the firmware
  register, the port bit, the link poll) as named states, sharing one effect type with the other register cores.
* [Medium] Raspberry Pi card (`tools/lib/erx/pi_medium.rb`, `boot_partition.rb`, `site.rb`): the data volume is formatted for `PiMedium.data_sectors` by the
  caller and nothing ties its length to the card's partition; the finished card is not read back through
  `BootRecord.read` and `extract`; `release.erofs` and `data.lfs` are not scanned for the build path (the EROFS
  files are, through `image.boot`); an oversized `kernel8.img` fails in fsimg rather than with a diagnostic;
  `FatVolume::Layout` keeps a root offset and a root cluster for both FAT types where each means something for one.
* [Medium] `tools/lib/erx/raspi4b_shell.rb` (`located_inputs`): the raspi4b suite boots the card it packed in
  `build/production-image/raspi4b/` in place, so a card taken from there after the suite ran may hold what its guest
  wrote, an SSH host key or `/data` among it (unverified whether that guest writes the card). Boot an owner-only copy,
  as `tools/erx boot --medium` does (`InteractiveBoot.medium_copy`), or make pack outputs read-only so no boot writes one.
* [Low] Raspberry Pi boot, residual: a damaged record partition, or a slot without valid boot files, lets the
  bootloader's `PARTITION_WALK` boot a partition the record does not name, or leaves the card unbootable until it is
  reinstalled, as the external design review reads the bootloader documentation
  (https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#PARTITION_WALK), not yet checked. The board pass
  records the board's EEPROM configuration (`BOOT_ORDER`, `PARTITION_WALK`) and what a card with a damaged record
  partition boots.
* [Medium] boot records, their writers and readers: the ABI file declares
  `erx_machine_page`, `erx_device_secret_page` and `erx_boot_root_extension`,
  and no code writes or reads them yet. The kernel's writers land with the root
  task's construction, and with them the kernel's command-line parser, its
  report of an unknown `erx.` key and their fuzz target. `liberx`'s root-task
  entry reads them, refuses a boot
  value and slot outside the pairs the design lists, treats a status outside
  its enum as no secret, and derives only from a status of present. With it
  land its fuzz targets, known-answer vectors for both HMACs, and the link
  check that only the entry's one derivation function reads the device-secret
  page or references its slot
  ([design-kernel.md](design-kernel.md#the-root-task),
  [design.md](design.md)).
* [Medium] boot security on the Raspberry Pis: secure boot as an
  installation option with each slot's measurement; anti-rollback where a
  board offers a counter that its trust root checks before the kernel
  (neither Pi does), the counter taking the committed slot's security
  version at each commit and the spare allowed below it, while without one
  the floor is the running system's security version, which rises only at
  commit; and a TPM 2.0 driver over SPI for add-on modules, an Erlang
  driver in the vault's domain
  ([design-platforms.md](design-platforms.md)).
* [Low] kernel and platforms, isolation groups: confine a board whose
  fabric keeps requester identities only within a bus by isolation groups
  that span several streams ([design-kernel.md](design-kernel.md)).
* [Medium] erx_blk, `tools/lib/erx/chokepoint_rules/device.rb`: the rule "only `erx_blk_write` calls `erx_device:post/4`" is
  tree-wide, but every virtio driver will post; once a second poster joins `SITES`, the write path's argument also
  needs "only the block driver's device process (`erx_blk_virtio`) opens a block record", which no check holds. Scope the rule per device class. Rename
  `erx_blk_write`, which now posts reads too, to what it is (for example `erx_blk_post`).
* [Low] erx_blk, `tools/lib/erx/chokepoint_rules/device.rb`: the check that only `erx_blk_write` posts sees only literal
  calls, and holds `erx_device:command/2` to `erx_blk_write` the same way: a call whose module comes from a macro,
  a variable or `apply/3` escapes it. design-storage.md's U4 extends it over the driver applications: `erx_device`
  never a value (only the module of a literal remote call), and no atom made from data, with the seeded violations
  of design-storage.md's verification (`M:command/2`, `list_to_existing_atom/1`).
* [Medium] drivers, shared interrupt lines, who may reach a line
  ([design-shared-devices.md](design-shared-devices.md#invariants), SD3 and SD4): the line-call check
  (`tools/lib/erx/chokepoint_rules/device.rb`) reads source tokens, so an atom spelled with escapes passes it; the BEAM-file
  pass the design names is not built. Any module may call `erx_irq_line`, so `attach/2` of a guessed record moves a
  direct line's binding, `ack/1` of a forged direct handle acknowledges a shared line behind its owner, and
  `start_owner/2` through the owner's record takes the line silently; `irq_ack/2` checks neither the caller nor
  the mark (`erx_device_bif.c`). A forged `{erx_irq, ...}` to a driver or a forged join to an owner can likewise
  acknowledge a line early or hold it masked. Fix by construction: `irq_ack/2` accepts only the line's binder, and
  a naming rule holds `erx_irq_line` to drivers and their starters.
* [Low] drivers, shared interrupt lines
  ([design-shared-devices.md](design-shared-devices.md#failure-handling)): a line owner keeps no deadline per
  firing (`erlang/apps/erx/src/erx_irq_line.erl`), so a hung driver holds its sharers masked until the unit is
  restarted; a deadline after which the owner restarts the slow driver belongs with the hostile-driver work.
* [Medium] erx_blk, the block driver: the device process's backlog, reply and reset decisions
  (`erlang/apps/erx_blk/src/erx_blk_virtio.erl`, `submit/3`, `resume/1`, `broken/2`) are tested only end to end, by the
  `block_device` QEMU suite's good path; they should move into a pure module whose full, held and broken cases are
  tested on the host.
* [Medium] erx_blk: a device that stops completing leaves its callers to time out in `gen_server:call` (an exit, not
  `{error, timeout}`), and a timed-out write still lands later. design-storage.md's transport contract gives every
  request a wait limit of 10 s from its acceptance and an in-flight bound of 18 s, past which the device process ends,
  below `call/1`'s 30 s; the device process implements neither, and `call/1` should return `{error, _}`.
* [Medium] erx_blk: a virtio device that stops completing leaves its callers to time out in `gen_server:call` (an exit, not
  `{error, timeout}`), and a timed-out write still lands later; the driver needs a per-request deadline that ends the
  device process (as a broken queue does), `call/1` should return `{error, _}`, and held requests of a caller that has gone should be dropped.
* [Medium] erx_blk, SD register spacing (`erx_blk_sd_regs`; docs/design-storage.md, "The SD host controller"): the
  6 us spacing between non-`data` writes holds only while every such write goes through `erx_blk_sd_regs` with the
  latest handle; spacing in the device NIF for `sdhci` records, or a chokepoint check, would make it hold by
  construction.
* [Medium] erx_blk: U4's trial rule is not applied in `erx_blk_write:write/6` or `erx_blk_write:sd_write_plan/3`, and `erx_blk`'s reads and writes (`read/2`, `write/2`,
  and their pid forms `read/3`, `write/3`) still let any process of the system domain reach any sector: the block service's windows (`erx_blk_window`) check
  their sectors, but nothing yet confines clients to them. The device service, which names each client's windows by
  role and hands their pids out as grants (PW1), replaces `erx_blk_service:window/1`, which hands any role's window to
  any caller, slot and record windows included.
* [Medium] erx_blk_table, `tools/lib/erx/medium_image.rb`: the extended boot records' encoding (first entry relative
  to its own record, link entry relative to the extended partition and spanning the next record and its partition) is
  checked only by copies written from one reading of the format; list a `MediumImage` medium with an independent
  reader (FreeBSD's `gpart` on an md device, or util-linux `sfdisk --json`) and compare every start and length.
* [Medium] erx_blk_window, erx_blk_service: beyond the window's binding to one device process
  (`test/erlang/erx_blk_window_tests.erl`), tested only by the QEMU suite's admitted medium. Host EUnit cases over a
  stub `erx_blk` should cover the window's error mapping and argument checks, and the service's refused, no-device and
  failed-read paths and its restart; a QEMU medium with one corrupted entry should show "blk: no windows".
* [Low] erx_blk_window: a request that waits in a window's mailbox behind another client's stuck request can time
  out at its caller and still be posted later, a second way into the timed-out-write item above.
* [Low] erx_blk_table: a data partition whose extended partition, from system A's record at sector 548,864, would
  pass 2^32 - 1 sectors (about 2 TiB less 834 MiB), which an MBR cannot describe, is refused as
  `{mbr, 4, sectors}` rather than as a data length the table cannot hold.
* [Low] erx_blk_window: a request for more sectors than one device request carries (`erx_blk_request:max_sectors/0`)
  is refused with `einval` rather than split, so every client splits its own.
* [Low] erx_blk_virtio: an interrupt storm costs a scheduler, bounded by the device's rate (Phase 1 residual).
