# TODO

Open work outside the roadmap in [docs/plan.md](docs/plan.md). Each item has
a `[Severity]` tag and a component pointer. When an item is closed, delete
it; git history is the record of completed work.

This file is the index. The items live in one `docs/todo-<subsystem>.md` per
subsystem, so that branches working on different subsystems never share a
file. Each of those files keeps the five categories below as its own
headings, so a security residual stays visibly a security residual. An item
goes to the document of the subsystem its component pointer names.

## Major initiatives

* [Runtime](docs/todo-runtime.md#major-initiatives): ERTS and OTP, musl and the C library seam, the device NIF, time, tracing, crypto and the runtime build.
  1 item (1 Medium).
* [erXos's kernel](docs/todo-kernel.md#major-initiatives): erXos's own kernel (Phase 2, Track K): the C17 cores, the chokepoint checks, the scheduler and the kernel ABI generator.
  1 item (1 High).
* [Fiasco](docs/todo-fiasco.md#major-initiatives): Fiasco, the release kernel, and `liberx`'s Fiasco backend: 0.2's work, the patches, the boot and the build.
  39 items (22 High, 16 Medium, 1 Low).
* [liberx and the ABI](docs/todo-liberx.md#major-initiatives): liberx and its program layer, the ABI and its generators, the domain library.
  6 items (3 Medium, 3 Low).
* [Network](docs/todo-network.md#major-initiatives): the network stack (`erx_net`), WiFi and HTTPS clients.
  1 item (1 High).
* [Shell and programs](docs/todo-shell.md#major-initiatives): the command shell (rc), programs, the console line and the terminal.
  1 item (1 High).
* [Apps and the start service](docs/todo-apps.md#major-initiatives): applications and packages, the demo apps.
  19 items (6 High, 10 Medium, 3 Low).
* [Storage](docs/todo-storage.md#major-initiatives): storage: file systems, the storage domain, file clients, the object store, the image tree.
  1 item (1 High).
* [Display and desktop](docs/todo-display.md#major-initiatives): the display stack, the window system, the desktop and LVGL in apps.
  1 item (1 Medium).
* [Inspection and logging](docs/todo-inspection.md#major-initiatives): the inspector, /proc, logging and the live tree.
  1 item (1 Low).
* [Build, tooling and tests](docs/todo-build.md#major-initiatives): the build, the host tools, the test harnesses and the gates.
  10 items (2 High, 8 Medium).

## Stopgap replacements

* [Runtime](docs/todo-runtime.md#stopgap-replacements): ERTS and OTP, musl and the C library seam, the device NIF, time, tracing, crypto and the runtime build.
  52 items (24 Medium, 28 Low).
* [erXos's kernel](docs/todo-kernel.md#stopgap-replacements): erXos's own kernel (Phase 2, Track K): the C17 cores, the chokepoint checks, the scheduler and the kernel ABI generator.
  14 items (1 High, 12 Medium, 1 Low).
* [Fiasco](docs/todo-fiasco.md#stopgap-replacements): Fiasco, the release kernel, and `liberx`'s Fiasco backend: 0.2's work, the patches, the boot and the build.
  56 items (1 High, 21 Medium, 34 Low).
* [liberx and the ABI](docs/todo-liberx.md#stopgap-replacements): liberx and its program layer, the ABI and its generators, the domain library.
  22 items (11 Medium, 11 Low).
* [Domains and the system manifest](docs/todo-domains.md#stopgap-replacements): the domain service, domains, the code service, facets, the system manifest and its checks, the funnel.
  16 items (14 Medium, 2 Low).
* [Network](docs/todo-network.md#stopgap-replacements): the network stack (`erx_net`), WiFi and HTTPS clients.
  2 items (2 Medium).
* [Drivers and platforms](docs/todo-drivers.md#stopgap-replacements): drivers and the device layer: PCIe, DMA, the device tree, GENET, SD, UART, the platforms and boards.
  52 items (3 High, 29 Medium, 20 Low).
* [Shell and programs](docs/todo-shell.md#stopgap-replacements): the command shell (rc), programs, the console line and the terminal.
  4 items (1 Medium, 3 Low).
* [Apps and the start service](docs/todo-apps.md#stopgap-replacements): applications and packages, the demo apps.
  15 items (1 High, 7 Medium, 7 Low).
* [Storage](docs/todo-storage.md#stopgap-replacements): storage: file systems, the storage domain, file clients, the object store, the image tree.
  8 items (4 Medium, 4 Low).
* [Display and desktop](docs/todo-display.md#stopgap-replacements): the display stack, the window system, the desktop and LVGL in apps.
  48 items (1 High, 23 Medium, 24 Low).
* [Inspection and logging](docs/todo-inspection.md#stopgap-replacements): the inspector, /proc, logging and the live tree.
  3 items (2 Medium, 1 Low).
* [Web client and host link](docs/todo-web.md#stopgap-replacements): the web client and the host tool's web server.
  21 items (9 Medium, 12 Low).
* [Build, tooling and tests](docs/todo-build.md#stopgap-replacements): the build, the host tools, the test harnesses and the gates.
  46 items (24 Medium, 22 Low).

## Bugs by subsystem

* [Runtime](docs/todo-runtime.md#bugs-by-subsystem): ERTS and OTP, musl and the C library seam, the device NIF, time, tracing, crypto and the runtime build.
  184 items (2 High, 88 Medium, 94 Low).
* [erXos's kernel](docs/todo-kernel.md#bugs-by-subsystem): erXos's own kernel (Phase 2, Track K): the C17 cores, the chokepoint checks, the scheduler and the kernel ABI generator.
  54 items (1 Critical, 1 High, 42 Medium, 10 Low).
* [Fiasco](docs/todo-fiasco.md#bugs-by-subsystem): Fiasco, the release kernel, and `liberx`'s Fiasco backend: 0.2's work, the patches, the boot and the build.
  60 items (30 Medium, 30 Low).
* [liberx and the ABI](docs/todo-liberx.md#bugs-by-subsystem): liberx and its program layer, the ABI and its generators, the domain library.
  90 items (39 Medium, 51 Low).
* [Domains and the system manifest](docs/todo-domains.md#bugs-by-subsystem): the domain service, domains, the code service, facets, the system manifest and its checks, the funnel.
  61 items (1 High, 35 Medium, 25 Low).
* [Network](docs/todo-network.md#bugs-by-subsystem): the network stack (`erx_net`), WiFi and HTTPS clients.
  63 items (2 High, 28 Medium, 33 Low).
* [USB](docs/todo-usb.md#bugs-by-subsystem): the USB stack and its class drivers.
  26 items (16 Medium, 10 Low).
* [Bluetooth](docs/todo-bluetooth.md#bugs-by-subsystem): the Bluetooth host and controller, GATT and the security manager.
  5 items (1 Medium, 4 Low).
* [Drivers and platforms](docs/todo-drivers.md#bugs-by-subsystem): drivers and the device layer: PCIe, DMA, the device tree, GENET, SD, UART, the platforms and boards.
  54 items (2 High, 29 Medium, 23 Low).
* [Shell and programs](docs/todo-shell.md#bugs-by-subsystem): the command shell (rc), programs, the console line and the terminal.
  88 items (44 Medium, 44 Low).
* [Sessions and SSH](docs/todo-session.md#bugs-by-subsystem): sessions, SSH, the vault and login.
  61 items (1 High, 38 Medium, 22 Low).
* [Apps and the start service](docs/todo-apps.md#bugs-by-subsystem): applications and packages, the demo apps.
  15 items (1 High, 8 Medium, 6 Low).
* [Storage](docs/todo-storage.md#bugs-by-subsystem): storage: file systems, the storage domain, file clients, the object store, the image tree.
  39 items (2 High, 19 Medium, 18 Low).
* [Display and desktop](docs/todo-display.md#bugs-by-subsystem): the display stack, the window system, the desktop and LVGL in apps.
  22 items (10 Medium, 12 Low).
* [Inspection and logging](docs/todo-inspection.md#bugs-by-subsystem): the inspector, /proc, logging and the live tree.
  50 items (27 Medium, 23 Low).
* [Web client and host link](docs/todo-web.md#bugs-by-subsystem): the web client and the host tool's web server.
  3 items (3 Medium).
* [Website and book](docs/todo-site.md#bugs-by-subsystem): the website, the book and the user guide.
  21 items (5 Medium, 16 Low).
* [Build, tooling and tests](docs/todo-build.md#bugs-by-subsystem): the build, the host tools, the test harnesses and the gates.
  133 items (61 Medium, 72 Low).

## Security residuals

* [High] erx_uart, the Raspberry Pi 4's console: Fiasco's polled write to the mini UART
  (`fiasco/kernel/src/lib/uart/uart_16550.cc`, `write`) reads `LSR`, clearing the overrun bit
  before `erx_mini_uart` sees it, and saves and restores `IER` around the write. Since the
  driver pauses a full store by writing `IER` 0 and resumes by enabling it
  (docs/design-live.md, "One input message outstanding per console driver"), a write on another CPU
  can hide a FIFO overrun during a pause (a damaged line then runs whole), undo a resume (the
  console stops reading until output polls `LSR`) or undo a pause (a delivery storm on the
  shared auxiliary line until the answer). Fix by ownership: Fiasco stops writing the console
  UART once its driver attaches, or its 16550 write leaves `IER` and `LSR` alone on this board.
  The PL011's write touches neither `IMSC` nor its overrun (`uart_pl011.cc`, `write`), but
  that a PL011 marks an overrun with `OE` on silicon is unverified.

Every other risk the design accepts is stated in its
[threat model](docs/design.md#threat-model) and in each subsystem
document's "residual risks accepted" paragraph.

* [Runtime](docs/todo-runtime.md#security-residuals): ERTS and OTP, musl and the C library seam, the device NIF, time, tracing, crypto and the runtime build.
  13 items (1 High, 9 Medium, 3 Low).
* [erXos's kernel](docs/todo-kernel.md#security-residuals): erXos's own kernel (Phase 2, Track K): the C17 cores, the chokepoint checks, the scheduler and the kernel ABI generator.
  5 items (4 Medium, 1 Low).
* [Fiasco](docs/todo-fiasco.md#security-residuals): Fiasco, the release kernel, and `liberx`'s Fiasco backend: 0.2's work, the patches, the boot and the build.
  14 items (3 High, 6 Medium, 5 Low).
* [liberx and the ABI](docs/todo-liberx.md#security-residuals): liberx and its program layer, the ABI and its generators, the domain library.
  5 items (2 Medium, 3 Low).
* [Domains and the system manifest](docs/todo-domains.md#security-residuals): the domain service, domains, the code service, facets, the system manifest and its checks, the funnel.
  17 items (12 Medium, 5 Low).
* [Network](docs/todo-network.md#security-residuals): the network stack (`erx_net`), WiFi and HTTPS clients.
  13 items (9 Medium, 4 Low).
* [Bluetooth](docs/todo-bluetooth.md#security-residuals): the Bluetooth host and controller, GATT and the security manager.
  14 items (1 High, 3 Medium, 10 Low).
* [Drivers and platforms](docs/todo-drivers.md#security-residuals): drivers and the device layer: PCIe, DMA, the device tree, GENET, SD, UART, the platforms and boards.
  3 items (2 Medium, 1 Low).
* [Shell and programs](docs/todo-shell.md#security-residuals): the command shell (rc), programs, the console line and the terminal.
  12 items (1 High, 6 Medium, 5 Low).
* [Sessions and SSH](docs/todo-session.md#security-residuals): sessions, SSH, the vault and login.
  9 items (5 Medium, 4 Low).
* [Apps and the start service](docs/todo-apps.md#security-residuals): applications and packages, the demo apps.
  4 items (1 High, 3 Medium).
* [Storage](docs/todo-storage.md#security-residuals): storage: file systems, the storage domain, file clients, the object store, the image tree.
  9 items (6 Medium, 3 Low).
* [Display and desktop](docs/todo-display.md#security-residuals): the display stack, the window system, the desktop and LVGL in apps.
  5 items (4 Medium, 1 Low).
* [Inspection and logging](docs/todo-inspection.md#security-residuals): the inspector, /proc, logging and the live tree.
  6 items (5 Medium, 1 Low).
* [Web client and host link](docs/todo-web.md#security-residuals): the web client and the host tool's web server.
  2 items (2 Medium).
* [Website and book](docs/todo-site.md#security-residuals): the website, the book and the user guide.
  2 items (1 Medium, 1 Low).
* [Build, tooling and tests](docs/todo-build.md#security-residuals): the build, the host tools, the test harnesses and the gates.
  5 items (3 Medium, 2 Low).
* [Low] Fiasco, AArch64 spin lock: every kernel spin-lock release ends with `SEV`
  (docs/design-fiasco.md, "The spin lock's event"), and Fiasco leaves user-mode `WFE`
  untrapped, so a user thread looping on `WFE` and the counter can count the kernel's lock
  releases on every CPU, including those made for other domains: a coarse side channel, beside
  the covert one user-mode `SEV` already gives. Trapping user-mode `WFE`, or erXos's kernel,
  closes it.

## Planned features

* [Runtime](docs/todo-runtime.md#planned-features): ERTS and OTP, musl and the C library seam, the device NIF, time, tracing, crypto and the runtime build.
  14 items (8 Medium, 6 Low).
* [erXos's kernel](docs/todo-kernel.md#planned-features): erXos's own kernel (Phase 2, Track K): the C17 cores, the chokepoint checks, the scheduler and the kernel ABI generator.
  7 items (2 High, 4 Medium, 1 Low).
* [Fiasco](docs/todo-fiasco.md#planned-features): Fiasco, the release kernel, and `liberx`'s Fiasco backend: 0.2's work, the patches, the boot and the build.
  9 items (4 Medium, 5 Low).
* [liberx and the ABI](docs/todo-liberx.md#planned-features): liberx and its program layer, the ABI and its generators, the domain library.
  12 items (10 Medium, 2 Low).
* [Domains and the system manifest](docs/todo-domains.md#planned-features): the domain service, domains, the code service, facets, the system manifest and its checks, the funnel.
  14 items (6 Medium, 8 Low).
* [Network](docs/todo-network.md#planned-features): the network stack (`erx_net`), WiFi and HTTPS clients.
  21 items (8 Medium, 13 Low).
* [USB](docs/todo-usb.md#planned-features): the USB stack and its class drivers.
  8 items (4 Medium, 4 Low).
* [Bluetooth](docs/todo-bluetooth.md#planned-features): the Bluetooth host and controller, GATT and the security manager.
  10 items (1 High, 9 Medium).
* [Drivers and platforms](docs/todo-drivers.md#planned-features): drivers and the device layer: PCIe, DMA, the device tree, GENET, SD, UART, pin control, the platforms and boards.
  42 items (23 Medium, 19 Low).
* [Shell and programs](docs/todo-shell.md#planned-features): the command shell (rc), programs, the console line and the terminal.
  15 items (4 Medium, 11 Low).
* [Sessions and SSH](docs/todo-session.md#planned-features): sessions, SSH, the vault and login.
  26 items (11 Medium, 15 Low).
* [Apps and the start service](docs/todo-apps.md#planned-features): applications and packages, the demo apps.
  17 items (1 High, 11 Medium, 5 Low).
* [Storage](docs/todo-storage.md#planned-features): storage: file systems, the storage domain, file clients, the object store, the image tree.
  16 items (7 Medium, 9 Low).
* [Display and desktop](docs/todo-display.md#planned-features): the display stack, the window system, the desktop and LVGL in apps.
  19 items (8 Medium, 11 Low).
* [Inspection and logging](docs/todo-inspection.md#planned-features): the inspector, /proc, logging and the live tree.
  7 items (1 High, 6 Low).
* [Website and book](docs/todo-site.md#planned-features): the website, the book and the user guide.
  19 items (8 Medium, 11 Low).
* [Build, tooling and tests](docs/todo-build.md#planned-features): the build, the host tools, the test harnesses and the gates.
  8 items (5 Medium, 3 Low).

## Other category documents

* [docs/todo-performance.md](docs/todo-performance.md): the performance watch list.
* [docs/todo-simplification.md](docs/todo-simplification.md): simplification candidates.
* [docs/todo-system-partition.md](docs/todo-system-partition.md): the system partition and the `system` tree.
