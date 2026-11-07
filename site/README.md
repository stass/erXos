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

* Building v64 runs `npm ci` (its build tools, from its
  `package-lock.json`) and its own Makefile for `build/libv86.mjs` and
  `build/v86-arm64.wasm`. It needs Node with npm, clang with the wasm32
  target, Rust with the `wasm32-unknown-unknown` target, and Java. v64's
  `LICENSE` and `LICENSE.MIT` are copied beside the built files, as their
  BSD and MIT licenses require. `--v64 DIR` instead takes a v64 tree whose
  `build/` already holds both files, and builds nothing.
* `--image` is the erXos boot image, by default
  `build/production-image/interactive/image.boot`. It is stored
  gzip-compressed as `image-<digest>.boot.gz`; `boot.json` gives the page
  its name, its sizes and its SHA-256.
* `--serve PORT` then serves `build/site/` on `127.0.0.1:PORT` until
  interrupted. Any static file server works too; the page needs no
  special headers, because the guest has one core and the page
  decompresses the image itself.

Opening `site/index.html` straight from disk shows the page with the
recorded session; the Boot button needs the built site.

`.github/workflows/site.yml` runs the same steps on GitHub, by hand only,
and uploads `build/site` as a Pages artifact. It does not build the erXos
image, which needs the whole erXos toolchain; it downloads one from a URL
given with its SHA-256, such as a release asset.

`ruby test/host/site_test.rb` tests the build step.

## Files

* `index.html` is the page. Its sections, in order: the hero (logo, the
  question and a short lede beside the console window), the idea and
  goals, the five principles, the architecture with a layer sketch, the
  current status, and "Try it" (what the console runs and what to type,
  beside the status-light panel and a short spec list). The logo is
  inlined as an SVG path taken from `erxos-logo.svg` at the top of the
  tree, filled with `currentColor` so it follows light and dark themes.
* `style.css` holds every style. Colours are tokens on `:root`, redefined
  for dark mode. The status lights are CSS only; their blinking and the
  progress bar's easing stop under `prefers-reduced-motion`.
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
Its screen, `<div id="erx-terminal">`, holds a recorded session in a
`<pre>`: that is what readers without JavaScript see, and what everyone
sees before booting.

With JavaScript, `terminal.js` shows a "Boot erXos" button and the
download size. On a click it loads xterm.js (from jsDelivr, pinned to an
exact version and checked by Subresource Integrity), v64 and the image,
showing a progress bar; checks the image against `boot.json`; and boots
it with 512 MiB of guest memory (`RAM_MIB`, the one place to change it),
one core, v64's page-tier JIT on and the kernel command line
`erx.watchdog=1,30,600`. The machine's serial console is attached to the
terminal, and the status line follows boot milestones in the serial
output. Reset destroys the machine and boots the same image again
without downloading it. Under reduced motion the cursor does not blink.

Browsers without WebAssembly or `DecompressionStream` keep the recorded
session and say so.

## Open items

* The footer links (Source, Architecture, Roadmap) point at `#` until the
  source repository has a public address; a TODO comment marks them.
