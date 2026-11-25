<p align="center">
  <img src="erxos-logo.svg" alt="erXos" width="480">
</p>

# erXos

What if every Erlang process were an operating-system process?

erXos is an operating system built on that idea. A small capability
microkernel sits underneath. Above it runs one Erlang system that spans
the whole machine. Drivers, file systems and system services are Erlang
processes, supervised like any other: when one crashes, its supervisor
restarts it. You can inspect, trace and change the running machine from
an Erlang shell, all the way down to kernel objects. And to the people
using it, it feels like UNIX.

> In erXos, Erlang's process is the operating system's process: one
> process space, one message system and one view of identity, supervision
> and inspection span every runtime.

The [architecture](docs/design.md), the [roadmap](docs/plan.md) and the
[working agreement](CLAUDE.md) define the project. The
[user guide](docs/guide/README.md) has the how-tos.

## Goals

* **Secure by construction.** Authority is a capability someone handed
  you. Knowing a pid, a path or a node name grants nothing. The
  guarantees hold because the code cannot express the alternative, not
  because every caller remembered a rule.
* **Millions of processes.** Erlang processes are cheap to create and
  cheap to switch. erXos keeps them cheap. Each runtime schedules its own
  processes without entering the kernel.
* **Crashes are routine.** A file system meets a corrupt block. A driver
  wedges its device. The widget renderer dies. Each fails alone, its
  supervisor restarts it, and the rest of the machine carries on.
* **Erlang wherever practical.** Erlang runs the drivers, the file
  systems, the network stack, the shell and the services. C is for the
  kernel, the thin layer under the runtimes, device shims, and per-byte
  work such as checksums and hashing.
* **A live machine.** Recompile a module on your laptop, and a second
  later it runs on the target. Upgrade a driver in place. Follow any
  process to the line of source it is executing.
* **UNIX look and feel, honestly.** The shell, files, pipes, `ps`,
  `grep` and terminals behave as a UNIX user expects, as on QNX and
  Plan 9, and familiar names and formats stay wherever they fit. Nothing
  pretends to be what it is not: where erXos works differently, it
  looks different. Where a file fits, it is a file, as in Plan 9. A
  POSIX-lite layer runs FreeBSD programs recompiled from source.
* **One kernel, many runtimes.** The kernel hands out CPU time to
  runtimes and native threads alike. ERTS comes first. C programs share
  the machine on the same terms.
* **Simple by design.** A few concepts, used everywhere. The build
  enforces the rules, not the reviewer. Where a declarative description
  is simpler than code, it replaces the code.
* **Cross-platform.** AArch64 comes first, on QEMU `virt` and the
  Raspberry Pi 4; the Raspberry Pi 5 follows. Other architectures are ports, not redesigns.

## Architecture

erXos stands on the shoulders of giants, and adds what none of them had.
From *Erlang/OTP* it takes processes and supervision; from *L4* and *Fiasco*,
the kernel. *EROS* and *Genode* taught it to account for resources; *Plan 9*
and *Inferno*, namespaces, files, the shell and graphics. *QNX* showed how
UNIX can sit on a microkernel, *Genera* how a whole machine can stay open
to inspection, and *Psyche*, *Barrelfish* and *Akaros* how a kernel and a
runtime can share the CPUs.

What is new is how the pieces meet. The Erlang process becomes the
system's process, across address spaces, with Erlang's semantics
intact. Every value the inspector shows says who reported it and
whether it is known. The command shell feels like FreeBSD's, `ps | grep`
included, though its commands are Erlang; one `erl` away, the same
processes are live values to link to, trace or open at their source
line. And a
browser is designed to be simply another display: it receives the same
widget commands as a screen and renders them in its own medium, rather
than mirroring pixels. The [overview](docs/overview.md) tells the longer story.

* **A capability microkernel.** The kernel knows threads, memory,
  capabilities and interrupts. It knows nothing of Erlang. Everything
  else runs in user mode, the runtimes included. erXos's own kernel
  follows *L4* and *Fiasco*, with lessons from *seL4* and *Zircon*; so far
  it is host-built cores that do not boot. A near-stock Fiasco stands in
  behind the same interface and runs today.
  ([kernel](docs/design-kernel.md), [Fiasco](docs/design-fiasco.md))
* **Two-level scheduling, one CPU authority.** In erXos's own kernel, the
  kernel grants CPU time to groups of threads, enforces every grant and
  never calls back into a runtime's scheduler. On Fiasco a domain is meant to get a
  priority band, a CPU set and a thread limit instead; the bands are built, with every configured domain's threads at one level, untrusted code below it and only the watchdog above it. Either way each
  runtime schedules its processes on its threads without a kernel call. *Psyche*,
  *Akaros* and *Barrelfish* showed the way; *scheduler activations*, long
  abandoned, showed what to avoid.
  ([scheduler](docs/design-scheduler.md))
* **Domains: a wall around some processes.** A domain is an address
  space with its own runtime. It is also an Erlang node. Processes in
  different domains link, monitor and message each other as Erlang
  processes always have. But a domain reaches another's process only if
  that process's runtime exported it, so a forged pid reaches nothing.
  A crashed domain looks like a dead node. Think of Erlang distribution
  inside one machine, with *Safe Erlang*'s pids as capabilities.
  ([domains](docs/design-domains.md))
* **A budget for everything.** In erXos's own kernel every allocation is
  charged to a budget carved from its parent's. Delete the budget, and
  everything charged to it goes too, so ending a domain is one operation,
  and users get memory quotas and a CPU share without a container
  runtime. On Fiasco budgets are not walls yet: 0.2 makes each domain's budget
  a wall ([design-fiasco.md](docs/design-fiasco.md#memory-and-budgets),
  [plan.md](docs/plan.md#02-the-first-release-on-fiasco)). Until then
  the inspector reports a domain's budget as unsupported. *EROS*'s space banks are the model,
  with *Genode*'s quotas.
  ([budgets](docs/design-kernel.md#budgets),
  [resource policy](docs/design-system.md#resource-policy))
* **Private namespaces, one file protocol.** This comes straight from
  *Plan 9*. Each domain sees files through its own table of file servers.
  There is no global root, so a path is the visible face of a
  capability. Every file server, from storage to `/proc` and `/dev`,
  speaks 9P2000.L. ([files](docs/design-files.md),
  [`/tmp`](docs/design-tmp.md))
* **Drivers are Erlang processes.** A driver is a supervised process over
  a thin device shim. Kill the network driver mid-transfer. Its
  supervisor restarts it and resets the device, and the rest of the
  network domain carries on. *HydrOS* and *Midori* took the same view.
  ([drivers](docs/design-system.md#drivers),
  [device shim](docs/design-runtime.md#the-device-nif))
* **Storage in Erlang.** Release images are read-only EROFS, checked block
  by block: the build writes them and a reader checks them. The design keeps data in F2FS
  and removable media in FAT; until F2FS is built, a littlefs stopgap
  serves `/data`. An update will go to a spare slot and commit only after
  a healthy trial boot; none is built yet. A bug in a file system crashes
  a process, not the machine.
  ([storage](docs/design-storage.md))
* **The live machine.** This is *Genera*'s legacy. One inspector shows
  CPUs, kernel objects, domains, budgets and processes as live records,
  and tags each value with who reported it. Tracing follows processes,
  messages between domains and kernel events. Code loads hot from the
  shell or from your laptop. ([live machine](docs/design-live.md))
* **Windows are files.** A display serves each window as a directory of
  files, as *Plan 9*'s *rio* does. A program finds its window at
  `/dev/draw` and draws with *Plan 9*'s draw protocol. The kiosk's
  dashboard runs today as one full-screen window. A terminal window that
  keeps shell output linked to the values behind it, as *Genera*'s
  dynamic windows did, and a desktop of overlapping windows or a pair of
  smart glasses are designed on the same window system; the desktop's
  policy is a tested core that no guest runs yet. ([display](docs/design-display.md))
* **One interface, every medium.** An Erlang application never draws. It
  describes its interface as a term: a tree that says what the widgets
  are, what they hold and which events they raise. When its state
  changes, it sends the new tree, and events come back as messages. It
  holds no widget handles and issues no widget commands.
  ([widgets](docs/design-display.md#widget-trees))
* **Same stream, different medium.** Every display gets the same stream
  of widget changes and sends back the same events. Each renders it in
  its own idiom: a screen as pixels and a panel as *LVGL* widgets today,
  a browser as a web page by design, since the rest of its client is not
  built. Nothing is mirrored. One application, unchanged, is meant to
  look native on a touch panel and in a browser tab.
  ([web](docs/design-web.md))
* **UNIX on the surface.** As on *QNX* and *Plan 9*, UNIX is how the system
  looks wherever that is also how it works, not what it is built on. The command shell speaks rc's language
  and pipes text between commands, as UNIX does. The file commands, `cat`, `ls`, `cp` and the
  rest, are Erlang commands; toybox is to supply the other familiar
  tools, and is designed and not built. Native programs run over musl, each holding only what
  its starter handed it; the POSIX-lite layer that completes them is
  designed and not built.
  ([shell](docs/design-shell.md), [programs](docs/design-programs.md),
  [pipes](docs/design-pipes.md))
* **Declarative where it is simpler.** One system manifest says what the
  machine runs. The build checks it and packs it into the boot image, an
  idea taken from *Barrelfish* and the *BOOM* project. The kernel ABI and the
  hardware registers each have one source, and every header and accessor
  is generated from it. ([manifest](docs/design-system.md#the-manifest),
  [ABI](docs/design-abi.md), [generation](docs/design-generation.md))
* **Checked by the build.** Decisions are pure functions; effects stay at
  the edge. Every "only X may do Y" rule is a build check, with a test
  that proves it catches a violation. TLA+ models check the protocols.
  Every parser of untrusted input has a fuzz target. And OTP's own test
  suites hold erXos's Erlang to stock OTP's behaviour.
  ([verification](docs/design-verification.md),
  [host oracle](docs/design-host-oracle.md), [style](docs/style.md))

## Current status

erXos is in Phase 1 of the [roadmap](docs/plan.md): the system is up on the
Fiasco kernel, and Phase 1b moves the user-facing parts into
domains of their own.
[0.1, the preview](docs/plan.md#01-the-preview), erXos's first public
preview, is published: the [website](https://stass.github.io/erXos/)
offers its browser demo and its Raspberry Pi 4 card, a development
build with the kiosk and its live quotes on the screen, SSH to `rc`, and
Doom. The next milestone is
[0.2, the first release](docs/plan.md#02-the-first-release-on-fiasco),
on Fiasco. Every build is a development build and prints
`development build: trusted code only`. `tools/erx boot` builds an image
and boots it in QEMU to the command shell:

```
development build: trusted code only
erx: erts: erl_start runs, 40 arguments
Erlang/OTP 29 [erts-17.1.1] [source] [64-bit] [smp:1:1] [ds:1:1:10] [async-threads:1]

rc: the command shell; erl starts the Erlang shell
% echo hello from erXos > /tmp/hi
% cat /tmp/hi
hello from erXos
% erl
Eshell V17.1.1 (type help(). for help)
1>
```

**Platforms**

* QEMU `virt` (AArch64) boots to the command shell on 1 to 8 CPUs, under
  HVF and TCG.
* The Raspberry Pi 4 boots on QEMU's `raspi4b` model (TCG only) and on a
  real 4 GB board from an SD card that `make pack PLATFORM=raspi4b`
  builds. On the board the serial console, the SD card (`/data` survives a
  power cycle) and Ethernet (1000 Mb/s, DHCP, `ping`, `host`) work; the
  card's [manual checklist](docs/guide/raspberry-pi-4.md#check-the-sd-card-and-ethernet)
  and the [first pass](docs/research-rpi4-board-pass.md) record what was
  tried. The board's Ethernet is board-verified: the kiosk's live quotes
  and SSH login run over it. `tools/erx netboot` stages the board's boot
  files for a TFTP network boot from a Mac, for development. The kiosk's
  dashboard runs full screen at 1920x1080.
  The board needs a bootloader dated 2022-12-01 or later. When the
  device tree carries no random seed, the system domain seeds its
  generator from the board's RNG200 hardware entropy source.
* Boot images are reproducible, for the QEMU disk image and the Pi 4's
  SD card alike.

**Kernel and domains**

* ERTS runs in user mode as the system domain on Fiasco, behind
  `liberx`; OTP 29.1.2 and musl live in the tree, modified.
* Domains each run their own ERTS (interpreter or BeamAsm) in an address
  space of their own. A domain that ends in a fault has an end line in the
  log that names where the fault struck: the instruction, the cause and
  the address. The domain service starts the manifest's domains
  and creates others on request; domains message each other as Erlang
  nodes do.
* erXos's own kernel has begun as host-built C17 cores (object store,
  capability table, budgets, page funnel). None of it boots yet.

**Erlang runtime and tools**

* The Erlang shell, `erx:i()`, `source(Pid)`, `erx:trace/1` and `/proc`
  show processes and kernel objects; a value Fiasco cannot measure
  reads as unsupported or partial.
* `erx:inspect(Path, Options)` reads an inspection path with a wait of the
  caller's own. Every session sees each CPU's record at `/proc/cpus/N`,
  whose idle time and ready threads read unsupported on Fiasco, and the
  clock's state at `/proc/time/status`: unset, boot, approximate or set,
  and `/proc/time` shows who set it.
  On QEMU `virt` the clock reads the
  PL031 real-time clock at boot. A machine with no real-time clock
  starts at the build's date, approximate, so HTTPS works from boot
  while the image is younger than its peers' certificates.
  The domains listing at `/proc` shows each domain a caller's scope
  covers, with a record of its name, principal, state and
  run queue; another domain's group and budget read as unsupported on
  Fiasco, which answers for the system domain's own only.
* A host link lets `tools/erx load`, `watch` and `files` replace modules in
  the running system and read its files; `tools/erx web` shows the
  machine's records in a browser.
* Hosted mode runs the runtime as a macOS process for fast iteration.
* `tools/erx bench NAME --systems erxos,l4re,linux` boots erXos, L4Re and
  Linux's stock virt kernel side by side under HVF on QEMU `virt` and prints
  each system's counterpart cells in one table. A run's record holds each
  boot of the system it measured, every boot is one side of a comparison,
  the cycle probe reads the cycle counter per tick on every boot, and a cell
  timed in batches keeps its total and shows its mean. The comparison is
  QEMU only.
* The book, `docs/book`, renders to HTML with diagrams drawn in the manual's
  style: `ruby tools/build_book.rb`. The website serves xterm.js itself.
* In every domain but the system domain, `erx_report` filters OTP's crash
  and logger reports at boot: a report names the process, its registered
  name, the error's class, the reason's leading atom and the stack's
  functions, and carries no process state, message, dictionary or call
  argument. A module's `format_status/1` hides its terms from every
  `proc_lib`, `gen_server` and `gen_statem` report.
* The pure Erlang cores return `{State, Actions}`, and one edge loop,
  `erx_actions:perform/3`, performs a step's actions.

**Shell and commands**

* The console's shell is rc, written in Erlang, with job control. Its
  commands (`ls`, `cat`, `grep`, `ps`, `top`, `mount`, `dmesg`, `uname`,
  `ping`, `host` and others) are Erlang commands that follow FreeBSD's
  output, and pipes carry text.
* The start table runs services; `service` enables, starts and stops
  them with FreeBSD's verbs and messages, and its `enable` also starts
  the row, which FreeBSD's does not.
* Root's session can end the machine: `reboot` resets it and `halt`
  powers it off, at root's console session and at the system domain's
  shell.
* A command can ask the terminal's size and stop its own job; the console
  passes a change of its line's size to the foreground jobs that asked
  for it.
* Each terminal master in a session has a tty of its own, and its close
  hangs up that tty's shells. Each tty's terminal relay
  (`erx_session_relay`, with its pure cores `erx_session_relay_core` and
  `erx_tty_link`) runs the line discipline `erx_tty` (cooked editing,
  signals for the foreground group, `termios` modes and timers, after
  FreeBSD's), a pure core with host tests; `erx_output` is not built.
* Programs have pipes and a session process can start one. A program's
  `kill` and `kill(pid, 0)` are answered by its handler, and a program
  reaches only itself. The command shell runs a program of the session's
  `/bin` by name or as `/bin/NAME`, alone or in a pipeline with Erlang
  commands: its standard streams are pipes to the terminal and its
  neighbours, `$status` is its exit status or signal, and `Ctrl-C` ends
  it; a line that `Ctrl-C` ended leaves `$status` as `sigint`. A program does not read the terminal yet, and a redirection reaches
  it as a pipe, not the file. The command server assigns every process id
  and spawns every program handler. A program's files take 64-bit offsets
  (`pread`, `pwrite`, `lseek`, `fstat`). A program started with a window
  gets a `/dev` of its own (`draw`, `ctl`, `kbd`, `mouse`, `wctl`, `label`
  and, if its grant carries it, `clipboard`) from its handler; host tests
  cover it over stand-ins of the window and draw connection (the window and
  the draw connection each have a keeper of their `kbd` and `mouse` reads),
  and the kiosk suite's front cell runs a program that draws, on root's
  `front` display grant, over the dashboard. Every session starts its export, a file server
  of `/bin`, `/dev` (with `null`, `zero`, `urandom` and `tty`, a name that
  answers `ENXIO` as a file) and `/etc` (`passwd` and `group`), as an `rx`
  grant for `/bin` and an `rw` grant for `/dev` and `/etc`; a program's
  handler does not join it into the program's table.
* musl's errno and signal numbers are FreeBSD's, generated from the ABI's
  tables, and `strerror`'s texts are checked against FreeBSD's.

**Files and storage**

* Per-domain namespaces, file servers across domains and `/tmp` on a RAM
  file system in Erlang. The storage, apps and machine services mount
  their own trees at `/data`, `/apps` and `/machine`, so one path reaches
  each in every session, the system shell's included.
* A stream file is one whose read waits for an event: a key, a mouse event
  or bytes. The file's grant hands such a read to a keeper process, which
  holds the waiting requests, so a program waiting on `/dev/kbd` does not
  hold up its other files, their writes, clunks and flushes.
* A storage domain serves `/data` from littlefs over a virtio block driver
  on QEMU and an SD driver on the Pi 4, and restarts cleanly after a
  failure. A QEMU suite kills the block driver in the middle of a transfer
  and finds every closed file intact and the file being written cut at a
  sync. An EROFS reader mounts read-only
  images.
* The build writes a slot's system partition, an EROFS image of the system
  release's files with its dm-verity hash tree after it, and the manifest's
  `system_image` row records the tree. On a guest, the `medium_boot` QEMU
  suite reads a release file from the partition through the hash-checking
  reader. `erx_storage_system`, the read-only backend that serves the
  partition's `apps/` as the `system` tree, is tested on the host: every
  block the EROFS reader parses, directories included, is checked against
  the tree's root hash first, and a block that does not match answers
  `eio`. Image packages lie in the partition's `apps/`; no slot writer or
  update is built to write the partition.
* An F2FS codec reads a volume's superblock and checkpoint pack, its node
  and segment tables, journals, inodes and directory entries, and a mount
  core picks the superblock copy and checkpoint pack and decides the mount
  mode. The file system is not built yet.
* `erx-app pack`, the SDK's packer, compiles an app directory's Erlang
  sources against the SDK and packs it into a `.app` file: a header
  signed by default with a development key the packer makes on the host,
  never shipped in the SDK, an EROFS image of the
  app's files and a dm-verity tree, judged by the machine's file check.
* An app's release carries OTP's compiler, so an Elixir 1.20 app built for
  OTP 29 starts with its supervisors, `GenServer`, `Logger` and `Task`.
  When an app fails to start, the kernel log names the reason.
* In a session with no terminal, such as an app's, what the program
  writes to standard output becomes log records under the session's name.
* The USB domain's mass-storage function serves a Bulk-Only USB stick as a
  medium: it reads the capacity and hands reads, writes and flushes to the
  medium's block transport, and it logs one line when a medium is served
  and one when it ends. On the Pi 4 a USB stick is served this way. On
  QEMU `virt` the `usb` suite serves a `usb-storage` stick beside the
  keyboard, reads its sectors, writes, reads back and flushes them through
  the medium's transport, ejects its medium and unplugs it; host tests
  check the function against a model stick on a fake controller.
* On QEMU `virt` a USB stick's FAT volume is read from root's session: the
  media domain gives the stick the drive `disk0`, mounts its first
  partition, and the `usb` suite lists `/media/disk0/s1` and reads its
  file there with `file:list_dir` and `file:read_file`. It has not run on
  the Pi 4 yet.

**Networking**

* The network stack is `erx_net`, an Erlang redesign of FreeBSD's:
  Ethernet, ARP, IPv4, IPv6 neighbour discovery, ICMP, UDP, TCP and DHCP.
  It runs in a network domain over the virtio-net driver on QEMU and the
  GENET driver on the Pi 4. `ifconfig`, `ping`, `host`, and `gen_tcp`
  connections out and in work in root's session.
* In a development build, root logs in over SSH with the clone's
  development key to `rc` in root's session, served by OTP's
  `ssh` daemon, whose version banner names erXos and the release, and
  `ssh DEST cmd` runs the command with `rc -c`, its output and error
  output byte-clean, and exits with the command's status. The
  first boot imports the `authorized_keys` of the card's FAT volume into
  root's home. The network suite logs in through a host port forward,
  and root's login there reboots the machine; `tools/erx boot` gives its
  guest no network device yet.
* OTP's `ssl` and `inets` are in every domain release, with a trust store
  of five root certificates, which every release with `public_key` carries
  as `priv/cacerts.pem` for `public_key:cacerts_get/0`. Host tests fetch over HTTPS from
  loopback `ssl` servers with no internet; the kiosk suite's quotes cell
  fetches over HTTPS from an offline fixture, never from the internet.
* On QEMU `virt` the Bluetooth domain brings up a controller over a serial
  line, a virtio console, whose device the line's grant names. A QEMU
  suite boots it against an emulated controller (Bumble) and checks the
  reset, the identify commands and the start of advertising. On the Pi 4
  the root sets the on-board pin functions at boot, the domain brings up
  the on-board controller, and a phone's scan sees the board advertising
  as `erxos`. A Mac connects to it, again after each disconnection, and
  macOS's log shows an ATT MTU of 185 and the GAP and GATT services; the
  Mac's `blew` discovers Nordic's UART service and has a read of its
  write-only characteristic refused, which `tools/ble_board_check.rb`
  scripts. Pairing has not run on the board.
* `bleuart` gives a BLE client root's `rc` over Nordic's UART service: each
  connected client gets a tty of root's session with the command shell, as
  an SSH channel does. It is a row of the start table, so
  `service bleuart enable|disable|start|stop` turns it on and off, and the
  UART service is not advertised while it is off. It is on for
  the Pi 4's development manifest and off for the published card. On QEMU
  `virt` the Bluetooth suite's `bleuart` cell, with a Bumble central,
  scans for the service, connects without pairing, gets `rc`'s prompt,
  runs `echo` and `ps`, and after `service bleuart stop` scans again and
  finds no service. The cell does not yet run Ctrl-C, a reconnect or
  `service bleuart start`, and no Pi 4 run of `bleuart` has been made.

**Display and input**

* A window server serves windows as files; clients draw into window buffers
  with `erx_win`, and the virtio-gpu, virtio-input (keyboard and tablet)
  and Pi firmware-framebuffer drivers are Erlang processes. On QEMU `virt`
  a USB domain runs an xHCI driver in Erlang behind the PCIe domain; a USB
  keyboard enumerates and its key presses reach the display domain through
  the USB domain's input tree (the usb suite checks a key's down and up
  there). On the Pi 4 a USB keyboard works the same way, through the PCIe
  bridge's driver, the VL805 and the same xHCI driver. A QEMU suite compares screenshots; the Pi's screen is checked by hand.
* A window's client speaks Plan 9's draw protocol over a draw connection
  (`erx_draw`) and loads Plan 9 subfonts, and the tree holds the 6x13 fixed ones. The
  window tree serves `/clipboard`, the display's shared clipboard, to a
  client whose grant carries it. The widget renderer reads PNG images in
  Erlang (`erx_png`, with its own inflate), and every widget text is
  written through the line escape.
* One theme file declares the desktop's type roles, spacing, radii, shadow
  and palette, with contrast rules the build checks; the Erlang, C and
  TypeScript sides are generated from it.
* `erx-lvgl`, LVGL as a native program, is built into every image whose
  release holds `erx_ui`. A session starts it through its program
  handler, and on QEMU a display-suite cell runs the LVGL renderer over
  the real `erx-lvgl` drawing into a buffer lent from the display's pixel
  area. `erx_ui:open` on a display starts the widget server with that
  renderer, and display-suite cells check the frame against the host's
  render, damage reports, a client confined to its buffer and the
  program's restart. `erx_ui_host` runs an app's interface on the
  development host under stock OTP.
* Inter 4.1's Regular, Medium and SemiBold fonts are in the tree, and
  `erx-raster`, built with FreeType, renders them to Plan 9 subfonts, one
  per type role; the display role's is loaded in tiles. Host tests check
  the glyphs and the tiled load.
* `erx_wm_rio`, a window-manager policy of overlapping windows after rio
  (pick, delete and a menu), is a pure core with exhaustive host
  tests, and the window server's tests run it. No QEMU cell runs it.
* Network time: `ntpd` sets the clock at boot from an NTP server. The
  Raspberry Pi 4 demo image uses `pool.ntp.org`, so the board's clock needs
  no setting by hand; elsewhere it is off until enabled. `ntpctl` steps the
  clock or shows the status.
* The widget format carries type roles, areas, icons, a current item and a
  graph kind, with coverage masks for corners, shadows and graphs. The
  desktop's file list and statistics have pure cores with host tests.
* `examples/dashboard`, the kiosk's app (a clock, the date and live
  quotes of Bitcoin, Ether and Solana from Kraken), is drawn by
  `erx-lvgl` and checked on the host against its reference picture. Its
  package boots on QEMU with no network, each quote showing why it has
  no data. Its quotes come from `erx_quotes`, with pure cores for
  retry holds, body parsing and the board; host tests
  and a fuzz target check them. On the Pi 4 the quotes are fetched live
  over the board's Ethernet; on QEMU the kiosk suite's quotes cell fetches
  them over a guest network device from an offline HTTPS fixture.

* Doom, the example game, is `/bin/doom` in the Pi 4 card and the QEMU
  release medium. Root's session starts it from `rc` (`doom`, or `doom &`
  and `kill %1`). Its window shows over the kiosk dashboard through
  root's `front` display grant, which only development builds give, and
  the dashboard returns when Doom ends. A key's down and repeat reach a
  window only while it is on the screen. The kiosk QEMU suite, and every
  other suite that boots the board's manifest, boots on 704 MiB, as the
  published QEMU medium does.

* `erx_desk`, the desktop application, runs a window of its own and a
  `clock` command that reads the clock's state before the wall clock; its
  pure cores have host tests.

**Web demo and checks**

* The website runs a demo in the browser on an AArch64 emulator, with a
  menu of hardware faults, and offers the Pi 4 card and a QEMU image for
  download. The page holds one copy of the image. `?jit=0` turns the
  arm64 JIT off, the JIT compiles fewer pages and holds its code to
  8 MiB, and `?log=console` mirrors the guest's console lines to the
  browser console.
* The checks are described under [Correctness and testing](#correctness-and-testing).

**Not built yet**

* The rest of erXos's own kernel, terminal input and sockets for programs,
  the Pi 4's Bluetooth echo app and pairing, and the WiFi driver, which has
  host-tested cores only (WiFi's join machine, SAE exchange and EAPOL-Key codec), the
  rest of the browser client, and the POSIX-lite layer. Each has a design document in [docs/](docs/). The
  Pi 4's header (GPIO, SPI, I2C) has register descriptions, a pin table
  and the pure core of a pin's ownership, and no driver yet.

## Getting started

0.1, published on the [website](https://stass.github.io/erXos/), is a
development preview ([plan](docs/plan.md#01-the-preview),
[release notes](site/release-notes.html)): it prints `development build:
trusted code only` at boot and must run trusted code only. It runs on
QEMU `virt` and on a Raspberry Pi 4. Read the release notes' known
limitations before you put it on a network.

To work on erXos, start with the
[developer's guide](docs/guide/developing.md): the loop from setup to a
landed change, with pages on loading code, debugging, tracing and testing.

**Raspberry Pi 4.** You need a Pi 4, a microSD card of at least 1 GB,
an Ethernet cable and, for the kiosk, a screen on the HDMI0 port. A 3.3 V
USB-serial adapter gives you the console
([the wiring](docs/guide/raspberry-pi-4.md#what-you-need)).

1. Download the card image from the website, or build it with
   `make pack PLATFORM=raspi4b` (see
   [Raspberry Pi 4 SD card](#raspberry-pi-4-sd-card)). The build record
   beside it names the unpacked card's SHA-256: check it with
   `xz -dc sdcard.img.xz | shasum -a 256`.
2. The Pi's bootloader must be from 2022-12-01 or later; the steps to
   update it are in
   [the Raspberry Pi 4 guide](docs/guide/raspberry-pi-4.md#update-the-bootloader-once).
3. Write the card, a `.img.xz` file of 718 MiB unpacked, to a microSD
   card of 1 GB or more. Raspberry Pi Imager writes the `.img.xz` as it
   is. Or, on macOS, with `diskN` the card in `diskutil list` (everything
   on it is erased, so check the size twice) and Homebrew's `xz`:

   ```sh
   diskutil unmountDisk /dev/diskN
   xz -dc sdcard.img.xz | sudo dd of=/dev/rdiskN bs=4m
   diskutil eject /dev/diskN
   ```

4. To log in over SSH, put your public key on the card before the first
   boot: copy a file named `authorized_keys`, with one `ssh-ed25519` key
   per line, to the root directory of the FAT volume labelled `ERXOS`.
   On macOS, insert the card again, then:

   ```sh
   cp ~/.ssh/id_ed25519.pub /Volumes/ERXOS/authorized_keys
   diskutil eject /Volumes/ERXOS
   ```

   The published card has no key, so without this file no SSH login
   works. The first boot copies its keys into root's home,
   `/root/.ssh/authorized_keys`, and from then on SSH reads only that
   copy: edit it to add or remove a key, or delete it to take the card's
   file again at the next boot.
5. Put the card in the Pi, connect the Ethernet cable and the screen,
   and power it. The serial console shows the banner and the shell's
   `%` prompt within a minute; the screen shows the kiosk, a clock with a
   quotes panel.
6. From another machine on the same network:

   ```sh
   ssh -p 2222 root@BOARD-ADDRESS
   ```

   You get `rc`, the command shell. Port 2222, not 22, is where 0.1
   listens. BOARD-ADDRESS is the address your network's DHCP server gave
   the board; your router lists it.

**QEMU.** From a clone of the repository,

```sh
make pack PLATFORM=qemu-virt
tools/erx boot --medium build/production-image/qemu-virt/medium.img
```

builds the QEMU release medium, the card's system packed for QEMU `virt`
with the kiosk and Doom, and boots it as a person uses it, on a 704 MiB
machine, which every development and release image of QEMU `virt` is packed
for: the display in QEMU's window
with the virtio keyboard and tablet, user networking that reaches your
network, your host's port 2222 forwarded to the guest's SSH port, and the
serial console on your terminal; quit with Ctrl-A then X. QEMU boots an
owner-only copy of the medium, `build/production-image/medium-copy/medium.img`,
where the guest keeps `/data` and makes its SSH host key; the copy is kept
from boot to boot and made again when the medium changes, so the medium
itself stays as `make pack` wrote it and can be shared. `tools/erx boot
--medium FILE --print` prints the plain `qemu-system-aarch64` command
instead; its kernel and device tree, which names the booted slot as the
firmware would, lie in the tree's `build/production-image/medium-boot` until
the next `--medium`, and its disk is the copy. To log in over SSH, the medium needs your
`authorized_keys` on its first FAT volume, labelled `ERXOS`, as on the card; then
`ssh -p 2222 root@127.0.0.1`. The website does not offer the QEMU medium
for download yet; build it as above.

**What to try.** In the SSH session or on the serial console:

* `date` shows the clock. QEMU `virt` reads it from its real-time clock at
  boot; on the Pi 4 it starts at the build's date at every boot until `ntpd`
  sets it. Set it by hand with FreeBSD's syntax, `date [[[[[cc]yy]mm]dd]HH]MM[.SS]`, for
  example `date 202611161530`. It is not kept across a reboot.
* `ps` and `top` list your session's processes; `erl` starts an Erlang
  shell, where `erx:i()` prints the machine, its CPUs and processes.
* Your home directory is `/root` for root, and `/home/NAME` for other
  users. Files under `/data` and in the home directories survive a power
  cut once they are closed.

**Doom.** The QEMU release medium and the Pi 4 card carry Doom as
`/bin/doom`: type `doom` in `rc`. It is an example, not part of erXos: doomgeneric under
GPL-2.0-or-later with Freedoom's data file under BSD-3-Clause, both
licenses in the image's `NOTICES`, and its source is erXos's fork,
[https://github.com/stass/erxos-doom](https://github.com/stass/erxos-doom), at the commit the tree's gitlink for
`examples/doom/doom` records. Keys come from QEMU's virtio keyboard; the
Pi has no keyboard in 0.1. To build the published images yourself, run
`tools/erx fetch --example doom` first, which fetches the fork and
Freedoom's WAD; `make pack` (`tools/erx pack --published`) refuses without
them, or with a fork that does not hold that commit. `tools/erx pack
--medium` packs your own development medium, which carries no Doom and
needs neither.

## Correctness and testing

erXos checks its code against answers that do not come from the code
itself: stock OTP, musl's own tests, a model checker, a weak-memory
simulator and seeded defects. A check says what it covered and nothing
beyond that. Most of the commands are described under
[Fetch, bootstrap and check](#fetch-bootstrap-and-check), and
[docs/design-verification.md](docs/design-verification.md) holds the rules
for what counts as evidence.

* **Stock OTP is the oracle** (`make check-oracle`). OTP 29.1.2's emulator,
  kernel, stdlib and compiler test suites run on erXos and on stock OTP on
  the development host, and the results are compared case by case. Every
  difference must be listed with its cause in a table of known differences:
  a difference the design states, a case that cannot run yet, a bug
  `TODO.md` names, or an upstream bug. Any other difference, or a listed
  one that no longer occurs, fails the gate. The same gate runs musl's
  `libc-test` against erXos's C library.
* **Weak memory under herd7** (`make check-litmus`). herd7 simulates how a
  processor may reorder memory accesses. The litmus tests (small
  programs with a stated bad outcome) in `test/litmus/` cover the lane's
  wake handshake and ring positions and the pipe's lock, under Arm's AArch64 memory model and,
  for the C11 form, RC11 (the repaired C11 model). Each protocol with its
  fences or acquire loads must never reach the bad outcome. Its twin
  without them must reach it, or the test would pass whatever the fences
  did.
* **TLA+ models under TLC** (`make check-tla`). TLC explores every state
  of a bounded model. Three protocol models check the lane (no record
  overwritten before it is read, records read whole, no lost wake),
  connections (a connection's end handled after every frame it
  published, a name reused only after the earlier connection went down)
  and links (an answer about a process arrives after everything the
  process sent, and a link two processes make towards each other is
  never left with one half). Each model has seeded defects, such as a
  dropped fence or an answer sent early, that must fail on the property
  or the deadlock check they name. The models for the
  host link's sessions, the update protocol and the scheduler's
  cross-CPU protocol are planned and not written.
* **CBMC, a bounded model checker for C** (`make check-cbmc`). The
  harnesses in `test/cbmc/` check the budget arithmetic, the capability
  table's lookup, rights and slot-closing code, the grace tracker and the
  page funnel for every input within stated bounds. Each seeded defect
  must make its harness fail.
* **Fuzzing** (`make check-fuzz`). The rule is that every parser of
  untrusted input gets a fuzz target when it lands; the known gaps are in
  `TODO.md`. The host fuzz targets include the boot image and its
  manifests, executable headers, the funnel's term decoder, the 9P codec
  and the shell's parser.
* **Sanitizers** (`make check-sanitizers`). Host tests of the C code run
  under AddressSanitizer and UndefinedBehaviorSanitizer, and the
  concurrency tests of the budget, capability, lane and log cores build
  under ThreadSanitizer.
* **Chokepoint build checks** (part of `make check`). Rules of the form
  "only X may do Y" fail `make check` on a new site, and the host test of
  each active rule seeds a violation to prove the check reports it. A rule
  whose sites are not written yet is marked pending and fails the moment a
  file it awaits appears.
* **Seeds** (`make check-native-seeds`, `make check-qemu-mutant`). Each
  seeded failure of the native threads, watchdog, task and interrupt suites must
  make its suite fail. A failure seeded into a copy of the Fiasco backend
  must make the QEMU gate fail, while an unmutated copy passes.
* **Stack proof** (`make check-stack-proof`, part of `make check`). The
  worst-case stack depth of the C17 cores is computed from their call
  graph. A frame over the cap, an unlisted indirect call or a cycle that
  is not a tail jump fails the build.
* **Reproducible images** (`make check-reproducible`). Two clean builds of
  the production boot image and its medium, both packing one build of the
  kernel, must be byte-identical, for QEMU's disk image and for the
  Raspberry Pi 4's SD card image, with BL31 built for each. In deterministic mode (`make check-qemu`, under TCG), two
  boots of the same image must write the same transcript.
* **Target suites** (`make check-qemu`). QEMU suites boot guests and check
  the running system: threads, memory, interrupts, crash records and the
  watchdog. `make check-conformance` is the harness for the kernel
  interface's conformance cases; each case lands with the call it tests,
  and the roster holds one pending case, so it boots no guest yet.
* **Review.** The project's rule is an internal review before every code
  commit, and an external review by a model from another vendor for
  designs and large changes.

These checks have limits. TLC checks a model, not the machine code. herd7
checks litmus tests, not the compiled lane. TSan finds data races but does
not show that an acquire and release protocol is right. The CBMC and TLC
reports state their bounds and assumptions.

## Host setup

Apple Silicon macOS is the primary host. You need:

* Ruby, any version, with minitest and REXML;
* GNU make, GNU sed, GNU timeout (`gtimeout`) and Perl;
* LLVM clang and lld, and the LLVM binary tools (`llvm-ar`, `llvm-nm`, `llvm-objcopy`,
  `llvm-objdump`, `llvm-ranlib`, `llvm-size`, `llvm-strip`), installed beside clang;
* Autoconf, Automake and Libtool, and a C and C++ compiler, which build
  fsimg, the tool that writes and verifies the EROFS images (`make setup`
  builds it);
* QEMU 11.1, with its `virt-11.1` machine;
* Node.js and pnpm, for `make web` (the browser client);
* xz (XZ Utils), which compresses the Raspberry Pi 4 card (`make pack PLATFORM=raspi4b`,
  the raspi4b QEMU suite and the website);
* a Homebrew JVM;
* Docker, a local engine or context, for the full stock OTP suites only.
  The [host oracle design](docs/design-host-oracle.md) describes its
  pinned Linux image and its isolation.

Install missing tools through Homebrew.

Point the build at your compiler. The tree is tested with LLVM 23.1;
the build does not check the version, so a compiler that is too old fails
with its own errors. Release images are built with exactly LLVM 23.1.3,
and their hashes are published so a rebuild can be compared.

Only LLVM will do, and not Apple's SDK clang or GCC: the build, Fiasco and L4Re
included, uses clang as a cross compiler (`--target`) and its sanitizers with
`llvm-symbolizer`, links with lld and reads the input list lld prints under `--trace` for the
image's source record, and admits into an image only the LLVM resource
headers that `config/provenance/llvm.json` lists, each by its own LLVM
license line. For Homebrew at
`/opt/homebrew` (Apple Silicon; Intel Macs use `/usr/local`, which
`brew --prefix` prints):

```sh
export ERX_CLANG=/opt/homebrew/opt/llvm/bin/clang
export ERX_LLD=/opt/homebrew/bin/ld.lld
export JAVA=/opt/homebrew/opt/openjdk/bin/java
export PATH=/opt/homebrew/bin:$PATH
```

For another installation, adjust the paths.

FreeBSD (x86-64, 16-CURRENT) is a host too. Install the same tools from
packages: `llvm23`, `gmake`, `coreutils` (for `gtimeout`), `gawk`,
`perl5`, `autoconf`, `automake`, `libtool`, `ruby` with
`rubygem-minitest` and `rubygem-rexml`, `b3sum`, `node`, plus QEMU, a JVM
and Docker for what needs them as above. Fiasco and L4Re build there
with the system's own `cp`, `find` and `sed`. The base
system's `dtc` serves. Run the
top-level targets with GNU make (`gmake check`), and point the build at
the port's LLVM:

```sh
export ERX_CLANG=/usr/local/llvm23/bin/clang
export ERX_LLD=/usr/local/llvm23/bin/ld.lld
```

`make setup` finds the newest `/usr/local/llvmNN` by itself when these
are unset. The hosted runtime builds only on macOS, so on FreeBSD setup
leaves it out, `make check` names the test files that test only it
(`Runtime::HOSTED_ONLY_TESTS`) as not run on this host, and the other
tests that need it skip, saying so.

## Fresh worktree

A new checkout or git worktree needs its sources, the stock OTP oracle and
the native runtime built before `make check` can run. One command does it:

```sh
ERX_SOURCE_CACHE=/path/to/other/checkout/build/downloads make setup
```

`make setup` (`tools/erx setup --jobs N`) runs, in order: every source
`deps.lock` pins, in its order, except those named below, the web
client's packages, the JIT oracle, the `emu` oracle,
`tools/erx build fsimg`, `tools/erx build runtime`,
`tools/erx build rc-oracle` and the development login key.
`make oracle-bootstrap` (`tools/erx setup --bootstrap`) runs only the
oracles' and fsimg's steps, with OTP's and fsimg's sources, from the
cache as `make setup` does. A step whose output is already valid is
skipped, so a second run does nothing. Each build runs under a deadline
with its own log in `build/logs/`.

It never downloads. `ERX_SOURCE_CACHE` names another checkout's
`build/downloads`; its archives are copied only after their SHA-256 matches
`deps.lock`. Without it, the sources must already be there from `make fetch`.
`tools/erx fetch --cache DIR` does the same for every source at once, with DIR the other checkout's
`build/downloads`: it fills each source the cache holds, names each it does
not, and leaves an OCI image (the Docker cache holds those) to
`tools/erx fetch --source ID`. `--source ID` and `--packages NAME` (the
npm package sets `web`, `book` and `site`) each repeat, and a fetch given
either fetches only the sources and package sets it names, as the site
workflow does. Setup does not fetch
`arm-registers`, `tla-tools`, `herdtools7` or the oracle image
(`Erx::Setup::SKIPPED_SOURCES`): only `tools/erx sysreg refresh` reads
the first, only `make check-tla` uses the second, only
`make check-litmus` builds from the third, and the native oracle does
not use the fourth. If `ERX_CLANG` or `ERX_LLD`
is unset, the builds use Homebrew's `opt/llvm/bin/clang` and
`bin/ld.lld` under `HOMEBREW_PREFIX`, or under `brew --prefix` when that
is unset, and setup stops with a diagnostic when they are not there;
export them yourself for later commands.

## Fetch, bootstrap and check

Only `make fetch` downloads anything, and it keeps a fetched source tree
that is the pin's and unchanged, so a copied build directory keeps its
sources. Name your local Docker context, and it fetches the oracle image
too:

```sh
make fetch DOCKER_CONTEXT=NAME
make oracle-bootstrap
make check
```

The bootstrap builds stock native OTP 29.1.2 twice, offline, from the
archive the fetch verified: with the JIT and as the `emu` interpreter,
which the hosted runtime's build runs as its host OTP. It also builds
fsimg, which writes the EROFS images. To rebuild an oracle, run
`tools/erx oracle build --backend native --flavour jit --clean` (or
`--flavour emu`). The
modified dependencies live in `otp/`, `musl/` and `fiasco/`, each with
its recorded origin. LVGL is the git submodule `display/lvgl/lvgl`,
cloned from erXos's fork at the commit its gitlink records
(`display/lvgl/ORIGIN.md` says where it comes from): `make fetch` clones
it, without history, when it is not checked out, and `git submodule update --init display/lvgl/lvgl` does
the same by hand; `git clone --recurse-submodules` fetches it with the
tree. The Doom example's submodule is the exception: its entry says `update = none`, and only
`tools/erx fetch --example doom` obtains it.

`make check` is the everyday gate. It verifies the oracle runtime, the
source provenance and the ASCII rule. It generates every
artifact (ABI, hardware, system registers and terminal tables) into
`build/gen/`, none of which is checked in. It runs
the host tests, compares the generated text tables in Erlang with Ruby,
and runs the native ELF and archive integrations. It never runs the full
stock OTP suites and never downloads.

The slower gates run separately:

```sh
make check-reproducible
make check-sanitizers
make check-fuzz
make check-tla
make check-cbmc
make check-litmus
```

* **Reproducibility** builds the production image and its medium twice
  from clean, for QEMU `virt` and for the Raspberry Pi 4, compares the
  two builds byte for byte, and keeps both and a `result.json` naming
  any part that differs under `build/reproducible/`.
* **Sanitizers** run the host C readers, the `ERXPACK` validator and the
  ELF planner under ASan and UBSan, and the generated atomic accessor
  test and the concurrency tests of the budget, capability, lane and log
  cores under TSan. A sanitizer report ends its command. ASan checks stack
  use after return and lets allocations fail. Leak and
  initialization-order checks need Linux, so macOS reports them
  unsupported. `check-asan` and `check-tsan` both select this combined
  host gate. `check-ubsan` runs it too, then reports its kernel UBSan boot
  unsupported, as it cannot run until erXos's own kernel exists; the host
  run decides its status.
* **Fuzzing** runs the generated C ABI and manifest decoder and the
  `ERXPACK` and ELF C cores under libFuzzer with ASan and UBSan. It also
  runs the generated Erlang reader's hostile corpus and the Ruby parser
  targets. `tools/erx check-fuzz --seconds 5 --runs 100000 --seed 1`
  sets the budgets: seconds for the timed Ruby targets, runs for the C
  targets. The seed applies to the generated C ABI target and the timed
  Ruby targets. The other Ruby targets run 20,000 iterations with seed 1,
  and the logs record the pack and ELF libFuzzer seeds. Fuzzing the
  target's runtime and service parsers, and the production startup
  proof, remain unsupported.
* **TLA+** runs TLC offline and checks its jar against the pin.
  `TLA_TOOLS_JAR` points to another copy of the same bytes.
* **CBMC** runs the bounded model checker over the C cores' harnesses in
  `test/cbmc/` and checks that each seeded defect fails its harness. It
  needs the cbmc version `test/cbmc/roster.json` pins, from Homebrew
  (`CBMC` names another path), and writes its report to `build/cbmc/`.
* **Litmus** runs the weak-memory litmus tests of `test/litmus/` under
  herd7 and checks each protocol's answer and its broken twin's. herd7
  is built offline into `build/herdtools7/` from the herdtools7 release
  `make fetch` verified, the first time and whenever its pin or recipe
  changes (`tools/erx build herd7` builds it on its own). The build needs
  `brew install ocaml dune menhir ocaml-zarith`.

## Boot erXos

```sh
tools/erx boot
tools/erx boot --accel tcg --cpus 4
```

`tools/erx boot` builds the development boot image that the QEMU suites
boot, into `build/production-image/interactive/`. Then it runs the image
in QEMU with the guest's serial console on your terminal, and the Erlang
shell's `1>` prompt comes up. It needs the compiler variables from
[Host setup](#host-setup). It picks HVF when QEMU offers it, and TCG
otherwise. `--accel` chooses; `--cpus` sets the guest's CPUs, from 1 to
8, default 1. Quit with Ctrl-A then X. Ctrl-A then C switches to the
QEMU monitor and back. The first build of ERTS takes a while.
`--hostlink` also puts the guest's host link on a UNIX socket in
`build/production-image/hostlink/`, for `tools/erx load`, `files` and
`web`, and gives it a fresh data medium for `/data`; the boot prints the
`tools/erx web --socket PATH` line to run in another terminal.
`--without-web` builds the website's image instead, from its own manifest,
the development manifest without its web and display domains, into
`build/production-image/site/`, where `tools/build_site.rb` takes it; it
cannot be combined with `--hostlink`, which the web domain serves.

## Raspberry Pi 4 SD card

```sh
make pack PLATFORM=raspi4b
```

builds the Raspberry Pi 4's production image and its SD card, offline
from the pinned sources `make fetch` verified, into
`build/production-image/raspi4b/`: `sdcard.img`, a disk image to write
to a card, which ends at its last partition, 718 MiB in; `sdcard.img.xz`,
the same card xz-compressed, to copy or publish; `boot/`, the same files as a directory, which also serves as
the firmware's network boot root; and `sdcard.img.receipt.json`, their
build record, beside the image's own. The same inputs give the same
bytes (`make check-reproducible`). The raspi4b QEMU suite packs the same
way and boots `boot/`'s files on QEMU's model, so it replaces what
`make pack` left there. Writing the card and what
to expect on a board is in
[the Raspberry Pi 4 guide](docs/guide/raspberry-pi-4.md),
which also holds the checklist for the SD card and Ethernet on a board.

To boot each new build without writing a card, a development board can
netboot from the Mac over an Ethernet cable: `tools/erx netboot` stages
`boot/` into the Mac's TFTP root and prints the TFTP server's command
line. The EEPROM setting, Internet Sharing and what a netboot lacks (the
card's image packages) are in
[Netbooting from a Mac](docs/guide/raspberry-pi-4.md#netbooting-from-a-mac).

## Guest and stock oracle

```sh
make build
make run
make run ACCEL=tcg
make oracle-build DOCKER_CONTEXT=NAME FLAVOUR=emu
make check-oracle-host DOCKER_CONTEXT=NAME FLAVOUR=emu
make bench FLAVOUR=jit
tools/erx status
```

`make run` boots under HVF when QEMU offers it and TCG otherwise; `ACCEL=`
chooses. For BeamAsm, repeat the oracle commands with `FLAVOUR=jit`. The full
stock suites run inside an offline Linux container and keep their
failures, skips and incomplete results. `make check-oracle` runs
`tools/erx oracle qemu`: every `*_SUITE` of OTP's `emulator`, `kernel`, `stdlib` and `compiler` groups (not
the variants compiler's test Makefile generates from them) under Common
Test in the system domain under QEMU with HVF, on one CPU, compared case by case with stock OTP on the host,
run with as many schedulers, against the
tables of known differences in `test/oracle/hosted_known_differences/`, then musl's libc-test in test tasks
on four CPUs (`tools/erx check-libc-test hvf 4`). It takes six to seven hours: the emulator group about 100
minutes on stock and 60 on the guest, the kernel group about 110 and 30, the stdlib group about 40 and 30. Native benchmarks carry their own label, apart from Linux suite
results. Interpreter benchmarks need a separate native bootstrap, built
with `tools/erx oracle build --backend native --flavour emu`.

The aggregate host oracle target stops at its first failed suite. To
keep every outcome, run `tools/erx oracle run emulator`, `kernel` and
`stdlib` one by one, each with `--docker-context` and `--flavour`.

Every command keeps its
logs and deadline records under `build/logs/`, and a failed test keeps
its evidence. The [build design](docs/design-build.md) defines these
boundaries.
