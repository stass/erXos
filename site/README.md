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
  packages install offline from a fetched store, because v64 pins its
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
  and every window blank (`Erx::Site.blank_medium`), attached where the
  QEMU harness attaches its guest's disk. At the first boot `/data`'s
  littlefs volume formats itself over the blank data window. The medium is 1.2 GiB, since the layout fixes where the data
  partition starts, but only its partition table's three records hold
  bytes, so it is published as `disk-<digest>.bin`, those 1.5 KiB, and
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
size and the simulated machine, `ARMv8-A · 1 core · 160 MiB RAM`. On a
click it loads xterm.js (from jsDelivr, pinned to an exact version and
checked by Subresource Integrity), v64, the image and the disk, showing a
progress bar on the case; checks the image and the disk against
`boot.json`; and boots the image with 160 MiB of guest memory and one
core (`RAM_MIB` and `CPU_CORES`, the one place to change each, from which
the readout is built too), v64's page-tier JIT on, the kernel command
line `erx.watchdog=1,30,600` and the disk as its virtio block device.
The machine's serial console is attached to the terminal, and the status
line follows boot milestones in the serial output. The case's
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
exists and are usable only while it runs, once the shell is ready, and
while no fault is in progress. An entry the machine cannot take is
disabled, its reason in its label. Nothing asks for confirmation; after
each fault the status line, a polite live region, says what was done,
with the addresses, the interrupt and the seed. Every fault is made in
v64, through its CPU object (`emulator.v86.cpu`), never by a command typed
into the guest, and reaches only the visitor's own emulator.

| Entry | What v64 is made to do |
| --- | --- |
| Dead disk | The disk's virtio-mmio window is unmapped, so the driver's next register access is a synchronous external abort, and its interrupt is raised and held. |
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
"this machine has no disk" when there is none. A fault that changes a v64
object records its undo, which a power cut runs.

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
the site's machine (one core, 160 MiB) booted under QEMU's `virt`, and the
disk faults against a stand-in for v64's objects.

Browsers without WebAssembly or `DecompressionStream` keep the recorded
session and say so.

## Open items

* The footer links (Source, Architecture, Roadmap) point at `#` until the
  source repository has a public address; a TODO comment marks them.
* The fault menu is checked under Node against a stand-in for v64, not
  yet in a browser, and its disk entries wait for the machine's disk
  (`TODO.md`, "Planned features").
