# erXos website

The landing page for erXos: one static page in plain HTML and CSS, with
one script, `terminal.js`, that boots erXos in the visitor's browser.

## Building and viewing it

The page runs erXos under [v64](https://github.com/speedyHKjournalist/v64),
an emulator of an AArch64 virt machine compiled to WebAssembly. erXos uses
v64 unmodified, so it stays outside the tree: `deps.lock` pins its commit,
and Closure Compiler, which its JavaScript build needs. None of the built
files (v64's `libv86.mjs` and `v86-arm64.wasm`, the compressed boot image)
is checked in. `tools/build_site.rb` builds v64 and assembles it with the
page and the image into `build/site/`:

```
tools/erx fetch --source v64
tools/erx fetch --source closure-compiler
ruby tools/build_site.rb [--image IMAGE] [--serve 8000]
```

* Building v64 copies the fetched tree, after checking its download
  record against `deps.lock`, to a fresh `build/site-v64/`, and runs
  `npm ci --ignore-scripts` (its build tools, from its
  `package-lock.json`, without their install scripts) and its own
  Makefile for `build/libv86.mjs` and `build/v86-arm64.wasm` there, each
  under a deadline with its output in `build/logs/`. It needs Node with
  npm, clang with the wasm32 target, Rust with the
  `wasm32-unknown-unknown` target, and Java. `npm ci` fetches from the
  npm registry: the site build alone is exempt from the rule that npm
  packages install through the fetch step against the lockfile, because v64 pins its
  tools with its own lockfile and nothing it fetches reaches an erXos
  image. `--v64 DIR` instead takes a tree an earlier run built, such as
  `build/site-v64`, and builds nothing.
* The licence notices of what the two files contain ship beside them in
  `v64/`: v64's `LICENSE` (BSD-2-Clause) and `LICENSE.MIT`, published with a
  `.txt` suffix so a static host serves them as text; `NOTICES.txt`,
  every copyright block of the third-party C compiled into the core
  (Berkeley SoftFloat, BSD-3-Clause, and zstd, BSD-3-Clause, with zstd's
  licence text from `otp/erts/emulator/zstd/LICENSE`, which zstd's
  headers refer to); and `COPYRIGHT-rust-library.html`, the Rust
  toolchain's notices for the standard library the core links. The
  build scans the sources v64's Makefile compiles and fails on one that
  states a licence `Erx::SiteV64` does not list, so a new third-party
  input cannot ship without its notice.
* `--image` is the erXos boot image, by default
  `build/production-image/interactive/image.boot`. It is stored
  gzip-compressed as `image-<digest>.boot.gz`.
* The machine's disk is made by the build, not taken: a boot medium laid
  out by `abi/medium.txt` with the data partition at its minimum length
  and every window blank but for the data partition, which holds a fresh
  littlefs volume (`Erx::Site.fresh_medium`), attached where the QEMU
  harness attaches its guest's disk. Making the disk is the page's
  installation: the guest's mount never formats, so the build formats
  `/data`'s volume with the host formatter (`Erx::DataVolume`). The medium
  is 1.2 GiB, since the layout fixes where the data partition starts, but
  only its partition table's three records and the volume's first blocks
  hold bytes, so it is published as `disk-<digest>.bin`, those bytes, and
  `boot.json` lists the extents they fill.
* `--source REF` is the erXos release tag or full commit the image was
  built from, by default this tree's `HEAD`. The image carries the
  stopgap kernel's GPL-2.0 files, so the page links that source on
  github.com beside the console, and `boot.json` records it.
* `terminal.js`, `libv86.mjs` and `v86-arm64.wasm` are published under
  names that carry their digests. `index.html` names the script and
  `boot.json`, which the page fetches past the browser's cache, names
  the image, the disk and v64's two files, so after a redeploy a browser never
  pairs one deployment's module with another's core. A browser holding
  a stale `index.html` (GitHub Pages lets it be cached for ten minutes)
  asks for a `terminal.js` the new deployment no longer has, so its Boot
  button stays inert until a reload.
* `--serve PORT` then serves `build/site/` on `127.0.0.1:PORT` until
  interrupted. Any static file server works too; the page needs no
  special headers, because the guest has one core and the page
  decompresses the image itself.

Opening `site/index.html` straight from disk shows the page with the
recorded session; the Boot button needs the built site.

`.github/workflows/site.yml` runs the same steps on GitHub, by hand only,
and publishes `build/site` to GitHub Pages. It does not build the erXos
image, which needs the whole erXos toolchain; it downloads a release
asset's `image.boot`, named by its URL and SHA-256 as the workflow's
inputs, and refuses one whose digest differs. Its third input names the
release tag or commit the image was built from, for the source link.
Runs share one `pages` concurrency group, so two deployments never
overlap; a run waiting there is replaced by a newer dispatch.

To publish: in the repository settings, set Pages to deploy from GitHub
Actions; attach an interactive production `image.boot` to a release; then
run the `site` workflow with that asset's URL and SHA-256:

```
gh workflow run site.yml -f image_url=URL -f image_sha256=DIGEST -f image_source=TAG
```

`ruby test/host/site_test.rb` tests the build step.

## Files

* `index.html` is the page. Its sections, in order: the hero (logo, the
  question and a short lede beside the console window), the idea and
  goals, the four principles, the architecture with a layer sketch, the
  current status, correctness and testing, and "Try it" (what the console
  runs and what to type, beside the status-light panel and a short spec
  list). The logo is
  inlined as an SVG path taken from `erxos-logo.svg` at the top of the
  tree, filled with `currentColor` so it follows light and dark themes.
* `style.css` holds every style. Colours are tokens on `:root`, redefined
  for dark mode. The status lights are CSS only; their blinking and the
  progress bar's easing stop under `prefers-reduced-motion`.
* `favicon.svg` is the tab icon: the orange square of the header bar's
  mark on the page's ink.
* `terminal.js` runs the console window (below).

The text follows the README's "Current status". When that section
changes, update the Status section here to match; claim nothing the
README does not.

## Fonts

Loaded at run time from Google Fonts:

| Font | Use | License |
| --- | --- | --- |
| Archivo (variable, width and weight axes) | headings (widest cut) and body | SIL Open Font License 1.1 |
| IBM Plex Mono | labels, the layer sketch, the terminal | SIL Open Font License 1.1 |

The page sends no tracking or analytics requests.

## The console window

The console window sits in the hero, above the fold on a desktop screen.
It is drawn as a stylised VT100: a putty case (graphite in the dark
theme), dark glass around the screen, and a chin below the screen with
the name plate, a lamp labelled with the console's state, a readout and
the keys. Only the guest's output appears on the screen. The screen,
`<div id="erx-terminal">`, holds a recorded session in a `<pre>`: that is
what readers without JavaScript see, and what everyone sees before
booting. The hint and the source line are page text below the case.

With JavaScript, `terminal.js` shows a "Boot erXos" key, the download
size and the simulated machine, `ARMv8-A · 1 core · 256 MiB RAM`. On a
click it loads xterm.js (from jsDelivr, pinned to an exact version and
checked by Subresource Integrity), v64, the image and the disk, showing a
progress bar on the case; checks the image and the disk against
`boot.json`; and boots the image with 256 MiB of guest memory and one
core (`RAM_MIB` and `CPU_CORES`, the one place to change each, from which
the readout is built too), v64's page-tier JIT on, the kernel command
line `erx.watchdog=1,30,600`, the disk as its virtio block device and a
virtio network device (below). The machine's serial console is attached
to the terminal, and the status line follows boot milestones in the
serial output. The case's
`data-erx-phase` (booting, live or stopped) colours the lamp and the
status. Reset destroys the machine and boots the same image again without
downloading it. Under reduced motion the cursor and the lamp do not
blink.

The disk lives in the page's memory for the visit. `SparseDisk` holds
only the 64 KiB chunks something wrote and reads every other byte as
zero, so the 1.2 GiB medium costs a few kilobytes until the guest writes
to it; a visitor who fills `/data` makes the page hold up to its 128 MiB
more. v64 takes it as a disk object of its own (`load`, `get`, `set`)
and writes the guest's writes straight into it; Reset starts the new
machine on the same object, so files written under `/data` survive a
reset or a power cut until the page is closed or reloaded. Nothing
persists across page loads. The disk is the guest's untrusted input, as
any disk is; the page does not parse it, it only places the published
bytes at the extents `boot.json` lists, after checking that they are
whole sectors, in order, apart, within the disk and use the bytes
exactly.

### The network

The machine has a virtio-net device on v64's fake router, its `fetch`
backend (`net_device: { type: "virtio", relay_url: "fetch" }`,
`NET_DEVICE` in `terminal.js`). The router lives in the page: there is
no relay server and no CORS proxy (`cors_proxy` is not set). erXos's own
stack drives the device: the system domain's `erx_net`, through its
`erx_virtio_net` driver, takes a DHCP lease from the router at boot,
as it takes one from QEMU's user network. The demo is two shell commands:
`ifconfig`, which shows the interface with the lease's address,
192.168.86.100/24, and `ping 192.168.86.1`, which the router answers.

What the router does, and so what the guest's network can do:

* DHCP: one lease, always 192.168.86.100/24, router and name server
  192.168.86.1.
* ARP: the router answers for every address but 192.168.86.100 to .255,
  so the guest reaches any address through it.
* ICMP: the router answers every echo request itself, to any address
  the guest can reach; nothing is sent further. A ping shows only that
  erXos's stack and driver work, not that a host is reachable.
* DNS: every name's A record is 192.168.87.1; other queries get an
  empty answer.
* HTTP: a TCP connection to port 80, at any address the guest can
  reach, ends in the router; the request on it becomes a `fetch()` by
  the page, to the URL the request's `Host` header and path name,
  upgraded to `https:` when the page is served over HTTPS. That is any
  host: the open Internet, the visitor's LAN, and, for a host named
  `PORT.external`, the visitor's own `http://localhost:PORT`, under the
  browser's limits on pages reaching local addresses. The browser's
  CORS rules apply: the request is sent, but without a proxy its
  response reaches the guest only from a server that allows the page's
  origin by its `Access-Control-Allow-Origin`; otherwise the router
  answers the guest with an error. Cross-origin fetches carry no
  cookies (the default `credentials: "same-origin"`), and same-origin
  ones only the site's own, of which GitHub Pages sets none.
* Nothing else: no other TCP port, no UDP beyond DHCP, DNS, NTP and an
  echo on port 8, no IPv6, and nothing in the page connects to the
  guest.

At boot the guest sends only DHCP and ARP; only what the visitor types
makes it send more. So the network reaches nothing that a script typed
into the visitor's own browser console could not.

v64 has no setting for which virtio-mmio transport a device takes: it
gives each the next one down from the last, the disks first and the
network device after them. erXos's platform record, which the site's
image shares with the QEMU harness (the production image, built from
`config/platforms/qemu-virt.json` and the development manifest), puts the
disk on the last transport, 0x0a003e00, and the network device on the
last of the page below, 0x0a002e00 (interrupt 71), since a 4 KiB page
holds eight transports and is one device's alone
([design-stopgap.md](../docs/design-stopgap.md)). So `terminal.js` gives
v64 the disk and then seven blank read-only disks of one sector, which
fill the rest of the disk's 4 KiB page and which no erXos driver is
given, and the network device lands on the transport the record names.
`virtio_slots` in `terminal.js` models v64's placement rule, and
`test/site/terminal_test.mjs` checks that it puts the disk and the
network device on the record's transports and interrupts, the network
device on a page of its own, and the blank disks where the record names
no device.

Every file `boot.json` names (the image, the disk, v64's module and
core) must be an http or https URL on the page's own origin, or the boot
fails. The image's and the disk's downloads are bounded by the sizes
`boot.json` gives, which must fit in the guest's memory, and so is the
image's decompression; the disk's capacity is at most 2 GiB. A failure
of any part of the boot stops the downloads still running.

Beside Reset, the fault menu injects a hardware fault into the running
machine, so the visitor sees how erXos handles it. It is a native
`<select>` drawn as a key, grouped Devices, Memory and Machine, and an
Inject key with alert ink. Both are shown with Reset once a machine
exists and are usable only while it runs, once `/data` is mounted or its mount has failed, and
while no fault is in progress. An entry the machine cannot take is
disabled, its reason in its label. Nothing asks for confirmation; after
each fault the status line, a polite live region, says what was done,
with the addresses, the interrupt and the seed. Every fault is made in
v64, through its CPU object (`emulator.v86.cpu`), never by a command typed
into the guest, and reaches only the visitor's own emulator.

| Entry | What v64 is made to do |
| --- | --- |
| Disk controller failure | As Dead disk, then the controller answers again by itself 3 s later in wall time: the window is mapped again with the device as it was, the interrupt follows the device, and the restarted driver resets the device as it starts. The note tells the visitor to watch the storage domain end on the driver's fault, restart, find the controller and mount `/data` again; a second note says when the controller is back. A power cut before then undoes the fault at once. Refused while Hung disk or Interrupt storm holds the interrupt, since the controller's return would let go of it. |
| Dead disk | The disk's virtio-mmio window is unmapped, so the driver's next register access is a synchronous external abort, and its interrupt is raised and held. The storage domain ends on the driver's fault and restarts up to 5 times (its manifest row allows 5 restarts in 600 s), then stays down: `/data` answers an error and the rest of the system keeps running. The note says so. |
| Hung disk | The disk still does its work, but its interrupt never rises: the transport's `update_irq` is shadowed on the instance. |
| Interrupt storm | The disk's interrupt is held asserted whatever the device says. |
| Corrupt disk | 8 bytes, chosen from a seed, are inverted in blocks that hold data (past the first 64 KiB, and not one byte value throughout); the visitor is told to read files. |
| Corrupt RAM | 64 bit positions, chosen from a seed, are flipped in the system domain's program, never in the kernel's memory (below). |
| RAM fail | Disabled: needs a change inside v64, whose bus maps RAM as one region and refuses an MMIO range over it. |
| Power cut | The machine stops at once and powers on again (`restart("power-on")`: RAM cleared, devices reset, the image loaded again). The disk keeps what reached it before the cut, and the faults above are undone first. |
| Clock jump | Disabled: erXos has no wall clock yet, so moving the PL031's offset changes nothing it reads. The action is written. |
| CPU freeze | The machine stops for 15 s and runs again. v64 stops the machine's clock with the processor, so erXos's own time does not move, and the note says so. |

The disk entries take the machine's first virtio-blk disk on a virtio-mmio
slot (`cpu.virtio_devices`, the list v64's `disk_devices()` reads) and say
"this machine has no disk" when there is none. While the controller is
down or the disk is dead, the disk entries are refused. A fault that
changes a v64 object records its undo, which a power cut runs.

Corrupt RAM aims at the range the page reads from the boot console's
output it already shows: the first 32 KiB of the log, up to the root
task's `manifest` line. The range is the one sigma0's RAM map gives the
root task (owner 4) that is writable and holds the root task's entry
point (`Roottask config ... ip:`), and it must lie in the bootstrapper's
RAM, be whole pages, be at most 64 MiB and overlap none of the
bootstrapper's regions that are not the root task's (the kernel's,
sigma0's). Otherwise the entry is disabled with the parse's reason. The
action also refuses a range outside the RAM the page gave the machine.

A fault that ends the machine reaches the end below. When the machine
powers off by itself, after a crash or a halt typed at the console, the
lamp shows Stopped, the menu and Reset go away, and Boot starts the
machine again from the image in memory, taking the focus if a control that
went away held it.

`terminal.js` runs under Node too, without a page, for its pure parts:
`ruby test/host/site_faults_test.rb` runs `test/site/terminal_test.mjs`,
which checks the boot-log parse against `test/site/fixtures/boot-160m.log`,
a boot on one core and 160 MiB under QEMU's `virt`, and the
disk faults against a stand-in for v64's objects.

Browsers without WebAssembly or `DecompressionStream` keep the recorded
session and say so.

## Open items

* The footer links (Source, Architecture, Roadmap) point at `#` until the
  source repository has a public address; a TODO comment marks them.
* The fault menu is checked under Node against a stand-in for v64, not
  yet in a browser (`TODO.md`, "Planned features").
* The network's placement is checked under Node against v64's rule, and
  no test in the tree boots the site's machine to see its lease
  (`TODO.md`).
