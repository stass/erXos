# Source origin

Archive: https://developer.arm.com/-/cdn-downloads/permalink/Exploration-Tools-OS-Machine-Readable-Data/AARCHMRS_BSD/AARCHMRS_OPENSOURCE_A_profile_FAT-2026-09.tar.gz

Release: `AARCHMRS_OPENSOURCE_A_profile_FAT`, 2026-09, schema 2.9.6 (the
`arm-registers` pin of `deps.lock`, version `2026-09-schema-2.9.6`).

The archive's SHA-256 is
`d5bf3f538663fb18be081ba8e9f08b188ed06f81dd19d4aa2da5b2795103a4ec`, the pin
in `deps.lock`. The archive's `Registers.json`, the one file read from it,
has SHA-256 `06d6f82f60cd3e4defe687f7a9d182acdafca3cf914b432c3fbe848295794e9e`,
which `aarch64.json` records as its `source_sha256`. The archive is not in
the tree: `tools/erx fetch --source arm-registers` downloads and verifies it
into `build/third_party/arm-registers/`, and nothing but the refresh command
below reads it. Neither `make setup` nor `make check` fetches it.
`Instructions.json`, `Features.json`, the schema and the rendered
documentation in the same archive are not used.

License: BSD-3-Clause, Copyright 2010-2026 Arm Limited or its affiliates.
Each register record of `Registers.json` declares itself "licensed under the
BSD 3-clause license" with the notice "Copyright (c) 2010-2026 Arm Limited
or its affiliates. All rights reserved.", which `aarch64.json` keeps as each
register's `copyright`. `LICENSE.md` is the license text of the archive's
`docs/notice.html` (SHA-256
`91e83f6178857ba3e96d69c989bee40c351b775d3a58ff6773c9ec4659ba99d3`), with
the HTML markup removed. Purpose: the system registers erXos code reads,
from which their accessors are made. Status: `permanent`; see the
dependency table in `docs/design.md`.

## What `aarch64.json` keeps

`aarch64.json` is erXos's file, made from `Registers.json` by
`tools/erx sysreg refresh` (`tools/lib/erx/sysreg.rb`). Each register in it
has two parts:

* erXos's access policy, which the refresh reads from the file itself and
  writes back with the same values (registers sorted by name, keys in this
  order): `name`, `read`, `write`, `read_side_effect` and
  `read_barrier`. Arm's data does not decide these; the refresh takes Arm's
  facts, not its access pseudocode.
* Arm's facts for the register's `AArch64` record, which the refresh
  rewrites: `width`, the `MRS` `encoding` (`op0`, `op1`, `CRn`, `CRm`,
  `op2`), the `fields` with their offsets and widths and the `RES0` and
  `RES1` ranges, and the record's `copyright`, `license` and
  `source_version`. Nothing else of the record is kept: no descriptions, no
  accessor pseudocode, no other accessors.

The refresh refuses a `Registers.json` whose SHA-256 differs from
`source_sha256`, a register with a conditional or feature-dependent layout,
split or overlapping fields, fields that leave bits undeclared, and field
enumerations, rather than guessing at them. A constant field, such as an
identification register's feature field, keeps its name and position and
not the values Arm lists for it: what a value means is the reading code's. Without the archive,
`Erx::Sysreg.specification`, the file's one reader, checks every policy
field and fact of the checked-in file (a host test runs it in `make check`),
so a malformed edit fails there; whether the facts are Arm's is what
`--verify` alone can tell.

## Refreshing

```
tools/erx fetch --source arm-registers
tools/erx sysreg refresh --verify   # compare only; fails if the file differs
tools/erx sysreg refresh            # rewrite aarch64.json's facts
```

To add a register, add an entry with its policy fields alone and run
`tools/erx sysreg refresh`, which fills in its facts. To move to a new Arm
release, change the `arm-registers` pin in `deps.lock`, set
`source_sha256` to the new `Registers.json`'s SHA-256, refresh, and update
this file.
