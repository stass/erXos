# Origin of display/libmemdraw

erXos's copy of Plan 9's `libmemdraw`, with the parts of `libdraw` it
links, from 9front. It is erXos's code: edited in place, no upstream
tracked (CLAUDE.md, Dependencies). Licence: MIT (LICENSE, 9front's
`lib/legal/NOTICE` and `lib/legal/mit`; the notice's exceptions cover
only fonts and programs not imported here).

* Repository: https://github.com/9front/9front (mirror of git.9front.org)
* Commit: 2859ae04e800737307470538a942ab8f8261253b
* Archive: https://github.com/9front/9front/archive/2859ae04e800737307470538a942ab8f8261253b.tar.gz,
  SHA-256 f370f3008b10d3e26a96d30d9a2920c421b5f1e7b644d50e20b6f5bd730ce9f7
  (deps.lock id `9front`, fetched by `ruby tools/erx fetch --source 9front`)

Imported files and the SHA-256 of each as imported, before erXos's edits:

| File | From | SHA-256 |
| --- | --- | --- |
| alloc.c | sys/src/libmemdraw | cc4876cd41288d3a0d3cce3ba27a9c801cb462e260d924d8138f5117fda18708 |
| cload.c | sys/src/libmemdraw | b84a103ad64a7b9fbd1aadae9a4de01e669fd40f71f776eb9f6775cd8fddfc10 |
| cmap.c | sys/src/libmemdraw | c71d109b4e2a46ca04eed5596eaf8e2efc7f196442f92597c38091818186bb2d |
| draw.c | sys/src/libmemdraw | f6565af0e12e8ed5c9a378161e3ad34bc781ec20863c0f041ae116932d1ef90f |
| load.c | sys/src/libmemdraw | b7a5e62097f0993e4c2a922dc3f416f296ad142727d17a23ee6a36a3931369ce |
| unload.c | sys/src/libmemdraw | 9991bd5d3975f3d9928d86b79dc886d155e7a1eb591e2ff05522af609cad97f2 |
| arc.c | sys/src/libmemdraw | e077862019c6a92785d9a3872a54243aa5d757d271d7079196f8687359395e6f |
| ellipse.c | sys/src/libmemdraw | 2dbc7d0225704039e6d5ab5921d73b1222f9b7e79bbbda1c0c0b3cfe32b51bf7 |
| fillpoly.c | sys/src/libmemdraw | e01acac554b3bfd15b23bc4cda6c44ea3a7bc3820cbbc74f51ba7be0ac5aa0d7 |
| line.c | sys/src/libmemdraw | 85d85db8654c44c9a7f91a769b43dad92579c2b0c9e0191a58c26ec3c7c51dd8 |
| poly.c | sys/src/libmemdraw | e7346b6337c4d78bb78fc676c82c2b70feac258368be0079c90b3c44674929e9 |
| arith.c | sys/src/libdraw | 250a5ad77e64ecafb4ba1c06c72139a64c05ff2eacd23d358cb1d84832e1214b |
| badrect.c | sys/src/libdraw | 35d85690837cdb00283306b502f9a09dae9fb6acc200aa8e3312635076eeadea |
| bytesperline.c | sys/src/libdraw | c90a7c3effffcf72008085eedf4e3ecba9efd972e62c5ecf6271d812002ec999 |
| chan.c | sys/src/libdraw | caa678c6b6fceef9d1ca393f5484885a84bfddd48356a464f510691e8dbc255d |
| drawrepl.c | sys/src/libdraw | d52cee37eb90b8ec745eb791b978d8aedfccacf00152f5a26197704a3dd826ce |
| icossin.c | sys/src/libdraw | 820979b653199c258f263d7f4754c2b69fc9c109c53ec0c6b749de2810e263b1 |
| icossin2.c | sys/src/libdraw | 3bf4095f527fcb1bef65eec6fbc5f426f859bd93055c5dce331f560e91313438 |
| rectclip.c | sys/src/libdraw | 62761a26b92291abbf13f7cedb12cdc29f167e0b891ce981732a0fa54b6f6ed1 |
| draw.h | sys/include | 1fb47dffc2d2f1384faddd4617171bd05f59977a81d08849d9612b38344621bb |
| memdraw.h | sys/include | c312cd7660b7822367b572cb80f595137ad73ab5f852e5344d90ea22db460152 |

`u.h` and `libc.h` are erXos's: Plan 9's types with Plan 9's widths
(`ulong` is 32 bits) and the few `libc` calls the copy makes. Their
headers carry erXos's copyright and licence, which is how the origin
check (tools/lib/erx/origin.rb) admits them as erXos's own.

`LICENSE` is 9front's `lib/legal/NOTICE`, a blank line, then
`lib/legal/mit`; the inventory's `changes` records its bytes.

erXos's edits. Each changed file (`alloc.c`, `arc.c`, `badrect.c`,
`cload.c`, `draw.c`, `ellipse.c`, `fillpoly.c`, `line.c`, `load.c`,
`memdraw.h`, `poly.c`) opens with a `Modified by erXos`
notice that lists its changes, and each edit is marked `erXos` where it
is not obvious:

* `memimagedraw` takes the rectangles `erx_draw_clip` computed
  (display/memdraw/erx_draw_clip.c) and returns 0, or -1 when
  `alphadraw` cannot allocate its buffer; `drawclip`, `drawclipnorepl`
  and `_drawclipnorepl` are gone, as are `hwdraw`, `memimagemove`, the
  image pool and the format verbs.
* `alphadraw` allocates its buffer per call, in place of a static pool of
  ten that failed a draw silently when all were taken.
* A 1x1 replicated source is a no-op under an operation keeping DoutS only
  when all its channels are 0, not whenever its alpha is (a colour above
  an alpha of 0 adds).
* `memoptdraw`'s all-k1 path, which computes `mask ? src : dst`, is taken
  for SoverD only; under S and the others a 0 mask bit clears.
* `allocmemimage` zeroes the pixels and row padding (calloc) and allocates
  one word past the rows, since `readbyte` loads four bytes for each pixel
  of a 24-bit image.
* `badrect` checks its bounds before it subtracts and multiplies in 64
  bits, so it cannot overflow on any 32-bit rectangle.
* `readbyte`'s per-pixel loop, under an alpha-only read (a mask with
  alpha that replicates), writes only the alpha: it wrote each pixel's
  grey too, so from the second pixel on a grey-and-alpha mask read grey
  as alpha. An upstream bug.
* Shifts of a byte into bit 24 and above are done on `ulong`.
* `loadmemimage` and `cloadmemimage` lose the software-cursor call and
  its static parameter block.
* The shapes draw through `memdraw` (defined by erXos in
  display/memdraw/erx_memdraw.c as `erx_draw_clip` and `memimagedraw`,
  `libmemlayer`'s entry point for an image that is not a layer), where
  `line.c` and `arc.c` called `memimagedraw` directly; none includes
  `memlayer.h`.
* `line.c` allocates a disc end's brush for each end and frees it, in
  place of a static brush cached across calls.
* `ellipse.c`'s brushed ellipse frees its disc, which upstream leaked.
* `arc.c`'s wedge, figure and mask cover only the part of the arc's
  bounding box the destination shows; the wedge's clip rectangle keeps
  the box's top, since its polygon fill rounds each edge from the row
  its scan starts at.
* `fillpoly.c`'s `mod` and `sdiv` test signs in `long`: Plan 9's test,
  an XOR cast through `ulong`, assumes `long` and `ulong` have one
  width, so with erXos's 32-bit `ulong` and 64-bit `long` every sign
  read positive, and a polygon edge whose x falls as y grows stopped
  sloping. `fillpoly.c` asserts that `long` is 64 bits, which its
  scan's products need.
* `fillpoly.c`'s comparators take `const void *`, as `qsort` calls
  them, and `fillpoly.c` and `ellipse.c` scale values that may be
  negative by multiplying, not by shifting, which C leaves undefined.
* `allocmemimage` and `fillpoly.c`'s allocations report a failure
  through `erx_memdraw_nomem`, so a shape that could not draw answers
  `ENOMEM`.

The inventory records the imported bytes and their licence evidence.
Third-party notices remain in their original files.

```json
{
  "version": 1,
  "repository": "https://github.com/9front/9front",
  "revision": "2859ae04e800737307470538a942ab8f8261253b",
  "archive_sha256": "f370f3008b10d3e26a96d30d9a2920c421b5f1e7b644d50e20b6f5bd730ce9f7",
  "exclusions": [],
  "files": {
    "alloc.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "cc4876cd41288d3a0d3cce3ba27a9c801cb462e260d924d8138f5117fda18708",
      "kind": "file",
      "non_ascii_lines": []
    },
    "arith.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "250a5ad77e64ecafb4ba1c06c72139a64c05ff2eacd23d358cb1d84832e1214b",
      "kind": "file",
      "non_ascii_lines": []
    },
    "badrect.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "35d85690837cdb00283306b502f9a09dae9fb6acc200aa8e3312635076eeadea",
      "kind": "file",
      "non_ascii_lines": [
        "5870792216a33c4388e9aa5be02afb5d53875f79813f6156c6a15b898171a27f",
        "d4389c76eef7358a97b7128c99d080c78ca0874a7698907cd24222d856fbf419",
        "074136b3df8b15255b4a734a6ae56c2ba8f972563478acfca48bd036cbcd55b7",
        "a87098f96b9bd1985b1e6559f1e598ab1de4d54179a8684108a08c012ac6af7c",
        "78fb863de3e72a4af2f142ec0d621662426fb4472dac7f2c4826eba76b699a79",
        "6ca0437c29761a0c6f7b50ab929077c09a89050a5a05a5bfd86473cd765fa3ad"
      ]
    },
    "bytesperline.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "c90a7c3effffcf72008085eedf4e3ecba9efd972e62c5ecf6271d812002ec999",
      "kind": "file",
      "non_ascii_lines": []
    },
    "chan.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "caa678c6b6fceef9d1ca393f5484885a84bfddd48356a464f510691e8dbc255d",
      "kind": "file",
      "non_ascii_lines": []
    },
    "cload.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "b84a103ad64a7b9fbd1aadae9a4de01e669fd40f71f776eb9f6775cd8fddfc10",
      "kind": "file",
      "non_ascii_lines": []
    },
    "cmap.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "c71d109b4e2a46ca04eed5596eaf8e2efc7f196442f92597c38091818186bb2d",
      "kind": "file",
      "non_ascii_lines": []
    },
    "draw.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "f6565af0e12e8ed5c9a378161e3ad34bc781ec20863c0f041ae116932d1ef90f",
      "kind": "file",
      "non_ascii_lines": [
        "a9f14a0c36c9a2e2e39b6aaf32ee02fd0c35e83a39f3baeac247648937763e44",
        "f862c85ef774996b1c1314f997d93ec283ba2dff5d2112a0996758880564c7cf",
        "18717712bd85f4d3f8d3653163e533ee24d863a60fccf0645a646f350f34dc49",
        "10b1c3d6345560910790220d48835ada2ef5aac889d9d08e47268c52fd7f2c46",
        "13ac1ca68f57754b781e3ca51ac9dfe4e65b2ef0db8d0a6818834c1ece2299df"
      ]
    },
    "draw.h": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "1fb47dffc2d2f1384faddd4617171bd05f59977a81d08849d9612b38344621bb",
      "kind": "file",
      "non_ascii_lines": []
    },
    "drawrepl.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "d52cee37eb90b8ec745eb791b978d8aedfccacf00152f5a26197704a3dd826ce",
      "kind": "file",
      "non_ascii_lines": []
    },
    "load.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "b7a5e62097f0993e4c2a922dc3f416f296ad142727d17a23ee6a36a3931369ce",
      "kind": "file",
      "non_ascii_lines": []
    },
    "memdraw.h": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "c312cd7660b7822367b572cb80f595137ad73ab5f852e5344d90ea22db460152",
      "kind": "file",
      "non_ascii_lines": []
    },
    "rectclip.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "62761a26b92291abbf13f7cedb12cdc29f167e0b891ce981732a0fa54b6f6ed1",
      "kind": "file",
      "non_ascii_lines": []
    },
    "unload.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "9991bd5d3975f3d9928d86b79dc886d155e7a1eb591e2ff05522af609cad97f2",
      "kind": "file",
      "non_ascii_lines": []
    },
    "arc.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "e077862019c6a92785d9a3872a54243aa5d757d271d7079196f8687359395e6f",
      "kind": "file",
      "non_ascii_lines": []
    },
    "ellipse.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "2dbc7d0225704039e6d5ab5921d73b1222f9b7e79bbbda1c0c0b3cfe32b51bf7",
      "kind": "file",
      "non_ascii_lines": []
    },
    "fillpoly.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "e01acac554b3bfd15b23bc4cda6c44ea3a7bc3820cbbc74f51ba7be0ac5aa0d7",
      "kind": "file",
      "non_ascii_lines": []
    },
    "line.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "85d85db8654c44c9a7f91a769b43dad92579c2b0c9e0191a58c26ec3c7c51dd8",
      "kind": "file",
      "non_ascii_lines": []
    },
    "poly.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "e7346b6337c4d78bb78fc676c82c2b70feac258368be0079c90b3c44674929e9",
      "kind": "file",
      "non_ascii_lines": []
    },
    "icossin.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "820979b653199c258f263d7f4754c2b69fc9c109c53ec0c6b749de2810e263b1",
      "kind": "file",
      "non_ascii_lines": []
    },
    "icossin2.c": {
      "license": "MIT",
      "evidence": "reviewed 9front's lib/legal/NOTICE: Plan 9 and 9front's changes are MIT (lib/legal/mit); its exceptions name only fonts and programs not imported here",
      "reviewed": true,
      "sha256": "3bf4095f527fcb1bef65eec6fbc5f426f859bd93055c5dce331f560e91313438",
      "kind": "file",
      "non_ascii_lines": []
    }
  },
  "changes": {
    "LICENSE": {
      "license": "MIT",
      "evidence": "9front's lib/legal/NOTICE, a blank line, then lib/legal/mit",
      "sha256": "4241c803e0be9a871331a97674879f8787a240ec9203a9df35210b6d6eec702b"
    }
  }
}
```
