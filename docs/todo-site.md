# TODO: Website and book

Open work on the website, the book and the user guide. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Bugs by subsystem

* [Low] book, `docs/book/b-design-documents.md` B.4: the counts of the common layout's sections (Context 35, Requirements 33 and the rest) were taken over forty-five documents and the tree holds forty-eight; recount each section name over every `docs/design-*.md` and restate the denominator.
* [Medium] `tools/lib/erx/site.rb` `MARKUP_LOAD`: a regex over HTML enumerates load forms and misses `srcset`, an entity-encoded scheme, `iframe`, `object`, `poster`, SVG `<image href>`, CSS `image-set()` and meta refresh. Replace it with a check of every element's address-valued attributes, so a new form is refused by construction.
* [Medium] `tools/lib/erx/book.rb`, `book/page.rb`, `book/contents.rb`: readability of the book step. Three "plain text of a node" functions (`Book.heading_text`, `Page#text_of`, `Contents.text`) and two sourcepos readers should be one; three placeholder fillers (`Book.fill`, `Site.fill_shared`, `Site.render_index`) with three grammars should be one template function; positional tuples (`shared_files`'s three values, `Result.sections`, `media`, `Contents.neighbours`) should be `Data` values; the heading-anchor table runs cmark-gfm lazily from inside `Page.render` through the resolver, so the render is not pure; `Site.publish` should derive `shared_names` from the book plan instead of taking both.
* [Low] `tools/lib/erx/book/page.rb` `html`: a draft marker or raw HTML after a comment in the same HTML block (`<!-- a --> <!-- check: x -->`) is dropped with the comment; check every comment and tag in the block.
* [Low] `tools/lib/erx/book`: a repeated title slug overwrites another page's contents entry silently; `docs/book/index.md` would be replaced by the contents page; `Book::TITLE` copies the outline's title instead of deriving it; table column alignment is dropped; `Address.https` trusts its caller (`Links::Resolver#outward`) to have parsed the URL.
* [Low] `tools/lib/erx/book/svg.rb`, `book/style.rb`: the SVG writer refuses the library's bold and italic label markup (`font-weight`, `font-style`, `text-decoration` on `tspan`, `multiline-utils.ts`), which the writing guide should state or the writer admit; the restyle treats every paint other than `none`, `var()` and `url()` as a literal color, so `fill="transparent"` would become paper rather than be refused; an uncaptioned drawing is a `role="img"` with no accessible name; a drawing the page never asks for (a renderer branch that skips a mermaid block) is dropped silently rather than refused.
* [Low] `docs/book/01-operating-systems.md` line 238: the message label `write(1, "hello\n", 6)` is drawn on two lines, because beautiful-mermaid reads `\n` as a line break; whether GitHub's Mermaid does the same is unverified. Write the label so both show the C string.
* [Medium] docs, `docs/design-shared-devices.md` (lines ~102 and ~456, invariant SD1): the design says a
  give makes a unit's objects in the holder's budget; the code charges a device's DMA memory to the
  system domain's budget and keeps it across the holder's restarts (`liberx/system/dom_life.c`
  ~1117-1130, `.budget = ERX_DOM_OBJ_SYSTEM_BUDGET`; `config/manifest/qemu-virt-development.txt`
  ~73-75 agrees with the code). Decide which is the design and change the other.
* [Low] docs, `docs/design-runtime.md` "The edits outside `sys/erxos`": edit 68 names two
  changes, init's reboot and the dirty scheduler's elapsed-time charge, so a citation of it is
  ambiguous. Give one a number of its own and update its citations, which include code comments
  (`otp/erts/preloaded/src/init.erl`, `otp/erts/emulator/beam/beam_common.c`,
  `test/host/erl_wakeup_other_test.rb`) as well as the documents.
* [Medium] docs/design-pipes.md ("Ends and their holders", "The program protocol"): the design
  does not say what a program does with a report for an end it no longer holds, though a
  `{pipe_writer}` can cross the program's `{closed}`. `liberx` closes the capabilities the report
  installed. Write the rule into the design, and say whether `{closed}` cancels the `{drained}`
  such a report made due in the port driver's credit.
* [Low] docs, `docs/design-domains.md` ("connections" quota): it counts the system
  connection in a domain's `connections` quota; the library (`life_connections`) and
  design-system.md do not, and property 12 enforces the library's reading.
* [Medium] docs, `docs/design-system.md` "The domain library's records"
  and the entry table: the record and view lack `connections`, `labels`,
  `next_connection`, `system_space` and the device catalogue, and
  `erx_dom_connect`'s `ERX_ELIMIT` lists only a full table, not the
  quota, spent numbers or spent labels.
* [Low] docs/design-kernel.md, **Backing a charge**: `erx_kalloc`'s
  dead-budget path releases a cache page "under the budget's lock", while
  **The record cache** in [Budgets](design-kernel.md#budgets) has the
  free hand the page out and its caller release it through the page
  funnel after dropping the budget's lock, since `erx_page_release`
  takes the owner's lock and the refund the budget's chain. Reword the
  `erx_kalloc` passage to match.
* [Low] docs/design-fiasco.md, the stack proof: the bullet names only the
  `erx_effect_*` calls as leaves of declared cost; the proof also counts
  Fiasco's `memcpy` and `memset`, the archive's two other allowed
  undefined symbols, that way. The reading needs confirming; the
  bullet then says so.
* [Low] docs, [README.md](../README.md#current-status): the sample boot transcript is out of date. Its
  archive is 23.70 MiB (`0x17b4000`) and its `root_memory` 96 MiB (`100663296`), where the development
  image packs an archive of about 54 MiB beside a `root_memory` of 231,079,936 bytes; its build and index
  hashes, baseline, pool pages and entry count are of the same old build. Replace the transcript with one
  from a fresh `tools/erx boot`.
* [Low] docs/research-baselines.md: the experiments behind the record (the
  boot and exception probe and its generators, the ERTS round-trip
  benchmark, the restricted decoder, the decompiled device trees) live
  outside the tree in `~/erxos-scratch/`. Bring them into `bench/` and check
  them against the SHA-256 prefixes the record gives, so the record can be
  reproduced from the repository. Its numbers do not state the compiler
  flags, which CLAUDE.md requires of every performance number; re-measure
  them with the flags recorded, in a new dated record.

* [Low] website, `.github/workflows/site.yml` and `tools/lib/erx/site_v64.rb`:
  the tools that build v64 are not pinned: the workflow installs whatever
  clang, lld, Java, Ruby and Rust the runner's apt and rustup give, and
  `setup-node` takes the newest Node 22, so two runs of the same inputs
  can ship different `libv86.mjs` and `v86-arm64.wasm`. Pin each to a
  version (a Rust toolchain file or `rustup toolchain install` of an exact
  release, exact apt package versions or a pinned container image).
* [Low] website, `site/terminal.js`: `machine.boot()` and `machine.reset()`
  catch their own errors, but the `import()` of v64's module and
  `load_xterm()` start before the manifest and image downloads they are
  awaited after, so when a download fails first, a later failure of either
  promise is an unhandled rejection in the console. Attach a handler where
  each starts.
* [Low] website, `site/terminal.js`: "Try again" after a failed boot
  downloads the image again even when the image arrived and checked out
  and only xterm.js or v64 failed to load; keep a checked image across
  retries.
* [Low] website, `tools/lib/erx/site.rb` (the QEMU virt download): the page
  offers the gzip-compressed image for QEMU's `-kernel`, which unpacks it
  as it loads it. QEMU may stop unpacking a gzipped kernel above a size
  ceiling (unverified: read QEMU 11.1's `hw/arm/boot.c` and
  `include/hw/loader.h`); if it does, the download stops booting once the
  unpacked image outgrows the ceiling while the browser console keeps
  working. Check the ceiling and refuse a larger image in `Erx::Site`.
* [Low] website, `tools/lib/erx/site.rb`: the card's SHA-256 is taken in
  `inventory` and xz reads the card again in `publish`, so a card changed
  in between is published under a digest and a record that do not
  describe it. Hash the bytes xz reads.

## Security residuals

* [Medium] website, `site/index.html`: the page has no Content Security
  Policy. It loads scripts, styles and fonts only from itself, so a
  `<meta http-equiv="Content-Security-Policy">` naming only `'self'`, `'wasm-unsafe-eval'` for v64's core and `worker-src` for its
  workers would bound what an injected script could load.

* [Low] docs/design-fiasco.md, "Device records": the physical record is said to name the page run around its
  registers after CLOCK; the root writes no such words.

## Planned features

* [Medium] docs, the book ([docs/book/](book/README.md)): write erXos: An Operating System in Erlang
  from docs/book/README.md's outline, one chapter per package, each checked against the
  design documents and the tree; built and unbuilt parts marked. Each chapter is written for a reader
  without Erlang, operating-system or microkernel background: Part I teaches the three subjects, and
  each chapter states the background it needs and explains in a Background box what only it uses.
  Chapters follow the prose guide, [docs/book/style.md](book/style.md).
* [Low] book site, the diagram step (`tools/book/diagrams.ts`,
  [design-book-site.md](design-book-site.md#the-parse-check)): no diagram is checked against
  official Mermaid, so the repository host's renderer may reject a diagram the site draws
  (beautiful-mermaid accepts more than Mermaid does: two book diagrams with `;` in a sequence
  message were). `mermaid.parse` needs a DOM under Node, failing in DOMPurify on 40 of the book's 61
  diagrams. Options: a DOM shim such as jsdom for DOMPurify under the driver (a new pinned
  dependency, mermaid pinned with it), or a narrower check of the constructs Mermaid refuses and
  beautiful-mermaid draws. Until then GitHub's preview and the review of rendered pages catch them.
* [Medium] book site, the diagram bundle (`tools/lib/erx/book_diagrams.rb`, `build_bundle` and
  `bundled_versions`): esbuild resolves `elkjs` and `entities` through every `node_modules`
  directory above the importing file (`tools/book/node_modules`, the checkout's parents, `~`)
  before `NODE_PATH`, so a stray install there is bundled unpinned while the build record names
  the pinned versions read from `build/book-modules`. Pass `--metafile`, refuse any input outside
  the import, the driver and `build/book-modules/node_modules`, and take the versions from the
  packages esbuild resolved; or bundle from a staged copy under `build/`, as `WebBuild` does.
* [Medium] book site, the bundle's reuse record (`book_diagrams.rb`, `sources_digest`): it names
  the library, the driver, the package files and the versions but not `ESBUILD_OPTIONS` or the
  bundle's own SHA-256, so a change to esbuild's target or charset reuses an old bundle. Add the
  argument vector and the bundle's digest to the record and check the digest before reuse.
* [Medium] book site, the diagram tool tests (`test/host/book_diagrams_test.rb`): they run Node
  and esbuild in `make check` whenever `tools/erx fetch` installed the book's packages, while
  docs/design-book-site.md's "Tests" puts them in `test/host/book_test.rb`, run with the site
  tests on demand. Move them behind the site-test entry, or change the design.
* [Low] book site, the diagram step's smaller gaps (`book_diagrams.rb`, `tools/book/diagrams.ts`):
  the `--allow-fs-read` guard refuses a comma, but Node 26.13 treats `*` as a wildcard and loads
  the entry script without any grant, so probe Node 25.0 and 26.13 and either drop the grant or
  refuse `*` too, with a test; concurrent bundle builds share `diagrams.mjs.next` and write the
  record after the rename; a diagram that hangs past the deadline is not named (the driver could
  write `diagram N` to standard error before each); Node's output has no `output_limit`; the reply
  check accepts a negative `line` and the unproduced `parse` stage; `Drawn.svgs` is raw
  third-party SVG with nothing in its name or type to keep it out of a page until the SVG writer
  lands; and the module's internals (`request`, `result?`, `build_bundle`, `bundled_versions`) are
  public, `draw`'s local `bundle` shadows the method, and `reply` checks its shape with chained
  conditionals where a `case ... in` pattern reads better.
* [Low] docs, `docs/research-brcmstb-pcie.md` section 2: the worked `BASE_LIMIT` for the mainline tree's 64 MiB window
  reads `0x00300000`; FreeBSD's encoder (`bcm2838_pci.c:591-596`) gives `0x03f00000`, the limit being MiB `0x603f`.
  Re-check the section's worked values in a new dated record.
* [Low] docs, design-system.md "The manifest", property 8: the facet grantee rules of
  [design-pcie.md](design-pcie.md#facets) ("The manifest") are not among the check's properties: only the PCIe
  domain holds `pci_bus`, only the system domain holds `pcie`, and a domain holds a `pci` facet exactly when it holds a
  `pci` device, its scope those devices. State them beside the driver-control facet's rule; the check's `pci_bus`
  half is an entry of `PCIE_DOMAIN_REFERENCES` (`tools/lib/erx/manifest.rb`), which refuses every other record that
  names the domain `pcie`.
* [Low] docs, design-system.md "Devices": `erx_domain_lib:devices/0` gives each entry's `role` as `block`, `net` or
  `none`, while the manifest's `mf_device_role` (`abi/manifest.txt`) has thirteen values, `network` rather than `net`,
  and `usb` among them. Say which roles `devices/0` reports, from the one table.
* [Low] docs, design-live.md "The /proc tree": `/proc/sensors/status` is not among its paths
  ([design-board-sensors.md](design-board-sensors.md#procsensors-and-the-inspector)).
* [Low] docs, design-scheduler.md "Service work" (under the review freeze): a call a service's process makes on a dirty
  I/O scheduler counts at its elapsed time, and a request one of its processes hands to another is charged that
  process's reductions too, returned with its answer, as design-domains.md's admission by measured reductions says.
* [Medium] docs, design-storage.md: the transport is reached by its pid (`erx_blk_usb` per medium is not registered),
  but "The transport" still calls it the device process registered as `erx_blk`, and the transport contract's calls
  (`erx_blk:read(Sector, Count)`, `{error, no_device}` when no device process runs) take no pid. Restate the contract
  over a transport pid and say what `no_device` means for a dead pid.
* [Low] website, `site/terminal.js` (`FAULTS`, [site/README.md](../site/README.md)): what the fault menu still lacks.
  It is tested under Node against a stand-in for v64's objects only: drive each entry in a browser, where the
  site's image reaches the shell, and check that it does under v64 at the development machine's RAM. RAM fail is disabled: v64's bus
  maps RAM as one region and `register_mmio` refuses a range over it, so it needs a change inside v64
  (a list of failed RAM ranges that `AddressSpace::lookup` in `src/rust/aarch64/bus.rs` checks before its RAM
  case, set by a new export that also bumps the bus generation and drops the range's compiled code, as
  `a64_bus_written` does). Clock jump is disabled until erXos reads a wall clock; CPU freeze stops v64's machine
  clock too, so erXos's time does not jump (advancing it would need v64's `MachineClock.set_time`, unchecked
  against its clamp). Make the power cut a new machine on the same disk buffer, and
  take the machine's end from v64's `cpu.powered_off()`: `session.repairs`, `pausing` and `rewatch` then go
  away, and the fault table no longer does lifecycle work. Once drivers run in their own domains (M9, 1b-E), the
  disk faults end only the driver's domain, and the menu's notes should say so.

* [Medium] website, `site/terminal.js` ([site/README.md](../site/README.md)): the page's pure helpers
  (`site_url`, `read_bounded`, `fetch_checked`, `SparseDisk`, `make_disk`) have no test in the tree, since the
  script runs `init()` against `document` when it loads and the tree has no JavaScript test runner for the
  site. Moving them into a module that Node can import, with a test beside `test/host/site_test.rb`, needs the
  language question settled first (CLAUDE.md lists TypeScript for the web client only).

* [Low] website, `site/index.html`: a `Content-Security-Policy` meta tag (`connect-src 'self'`, `script-src
  'self' 'wasm-unsafe-eval'`, styles and fonts likewise) would make "the machine's
  files come only from the page's origin" hold for v64's own fetches too, not only for the names `site_url`
  checks. GitHub Pages sets no headers, so it has to be the meta tag. `connect-src` also bounds the guest's
  HTTP, which v64's fake router turns into the page's own `fetch()` calls
  ([site/README.md](../site/README.md#the-network)): `'self'` alone lets the guest reach only the site.

* [Low] website, `site/terminal.js` ([site/README.md](../site/README.md#the-network)): nothing in the tree boots
  the site's machine. A check that loads a built `build/site` under Node, starts v64 with the page's own
  settings (`virtio_disks`, `NET_DEVICE`) and waits for the guest's DHCP lease from the fake router, its
  gratuitous ARP and an echo reply, would catch a v64 or driver change that the placement test cannot; it
  needs the built image and v64, so it belongs at the milestone gate.

* [Low] docs, the FreeBSD guest: [plan.md](plan.md) (the network
  stage, "packetdrill tests and a FreeBSD guest" and "in a FreeBSD 15.1
  guest") still names a FreeBSD guest for the network stack, whose
  oracle is the FreeBSD test host; and
  [design-shell.md](design-shell.md)'s oracle cases link the
  FreeBSD 15.1 oracle guest to design-network-stack.md, which no longer
  has one. Point plan.md at the test host, and either link the shell's
  guest to design.md's dependency row or move the shell's oracle to the
  test host.
* [Medium] site, the QEMU virt download ([site/README.md](../site/README.md),
  [design-ssh.md](design-ssh.md#the-ssh-domain)): the page offers the browser demo's gzip-compressed
  `image.boot` as its QEMU download; it is to offer the QEMU release medium packed from the development
  manifest (`ProductionImage::MediumKind.published`), with the SSH domain and no `authorized_keys`, and the QEMU
  command line that boots it, while the browser demo keeps its own image. The site takes the medium only with a
  build record written at pack time that names its SHA-256, as the card's does, so it never takes a medium a
  guest has booted, which holds the guest's SSH host key and `/data` (`tools/erx boot --medium` boots a copy, but
  QEMU run by hand on the medium writes it). Plain QEMU has no firmware
  to pick the slot, so the published command needs the device tree naming it (`MediumBoot.firmware_tree`) published
  beside the medium, or a loader on the medium; without it the boot value is `unknown` and no `system` tree, so no
  kiosk and no `/bin/doom`, is served. A published tree is QEMU's own dump for one machine (its RAM, CPU count and,
  unverified, the accelerator and QEMU version it was dumped under), so the command must pin those, and the pack
  would run QEMU, which it does not yet. The published medium carries Doom and is packed for 704 MiB
  (`ProductionImage::Machine.development`), so its command takes `-m 704`, a display and the virtio keyboard,
  as `tools/erx boot --medium --print` gives them.
* [Medium] docs/design-storage.md, failure handling: a device reset in the target design breaks the volumes over
  the device, since each window is bound to one device process's life, but nothing names how a file system that
  restarts after the reset gets a window bound to the new process: the device service would name new windows and
  grant them again, or the reset would end what holds the old windows, as the storage domain's end does in Phase 1.
