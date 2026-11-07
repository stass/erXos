# Source origin

Repository: https://github.com/littlefs-project/littlefs

Revision: v2.11.3 (6cb4e86540eca0d9ba62500a298385c9d863c8be)

littlefs, the stopgap read-write file system of `/data`, imported as
erXos's code ([design-stopgap.md](../docs/design-stopgap.md#littlefs-in-the-system-domain)).
The files were taken from the release archive
`https://github.com/littlefs-project/littlefs/archive/refs/tags/v2.11.3.tar.gz`,
whose SHA-256 is `archive_sha256` below, after checking it against that
hash; the commit is the one the archive's pax header names. Each file
sat at the top of the archive's `littlefs-2.11.3/` directory:

| File | SHA-256 of the imported bytes |
| --- | --- |
| `lfs.c` | `a36d6a095785ddea9571d541d68d3e4ef01d5b255a99d17d3f07fb6ea60ea132` |
| `lfs.h` | `b1befd7288d08815accc8f9af744c55686c0b9e3ac0061c32ceee38a1b3eb96d` |
| `lfs_util.c` | `f2fbde533670560434bd9f5a547174cc7c5a4670a02c47b4bd85180dced8b2ec` |
| `lfs_util.h` | `548d46aa524dc7449e16739286c1a422a52f9de727ff0be0c2ffc5593f5ca981` |
| `LICENSE.md` | `0cb4ff1daf5fdc1359c6a6ee3116092f08fc100c9d58b1b77ab17bfd801f856d` |

Licence: BSD-3-Clause, whose text and copyright holders (the littlefs
authors and Arm Limited) are `LICENSE.md`; each source file declares it
by SPDX in its header. erXos's changes are under the same licence.

Left out: the block-device emulators (`bd/`), the test and benchmark
runners and their cases (`runners/`, `tests/`, `benches/`), the scripts,
the Makefile, the GitHub workflows, `README.md`, `DESIGN.md` and
`SPEC.md`. erXos builds the four source files directly (the ERTS
emulator's Makefile, the host NIF test and the `lfs_image` fuzz target)
and supplies the block device itself.

Each file erXos changes says so in a `Modified by erXos` notice at its
top, which lists the changes. All five are unchanged.

The inventory records the imported bytes and their licence evidence.
Third-party notices remain in their original files.

```json
{
  "version": 1,
  "repository": "https://github.com/littlefs-project/littlefs",
  "revision": "v2.11.3 (6cb4e86540eca0d9ba62500a298385c9d863c8be)",
  "archive_sha256": "15521be8aaed133c453e7337714e029a9f62480ab41f59c4ba5d18297a076207",
  "exclusions": [],
  "files": {
    "LICENSE.md": {
      "license": "BSD-3-Clause",
      "evidence": "reviewed LICENSE.md: the littlefs authors and Arm Limited license littlefs under BSD-3-Clause; each source file declares it by SPDX",
      "reviewed": true,
      "sha256": "0cb4ff1daf5fdc1359c6a6ee3116092f08fc100c9d58b1b77ab17bfd801f856d",
      "kind": "file",
      "non_ascii_lines": []
    },
    "lfs.c": {
      "license": "BSD-3-Clause",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "a36d6a095785ddea9571d541d68d3e4ef01d5b255a99d17d3f07fb6ea60ea132",
      "kind": "file",
      "non_ascii_lines": []
    },
    "lfs.h": {
      "license": "BSD-3-Clause",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "b1befd7288d08815accc8f9af744c55686c0b9e3ac0061c32ceee38a1b3eb96d",
      "kind": "file",
      "non_ascii_lines": []
    },
    "lfs_util.c": {
      "license": "BSD-3-Clause",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "f2fbde533670560434bd9f5a547174cc7c5a4670a02c47b4bd85180dced8b2ec",
      "kind": "file",
      "non_ascii_lines": []
    },
    "lfs_util.h": {
      "license": "BSD-3-Clause",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "548d46aa524dc7449e16739286c1a422a52f9de727ff0be0c2ffc5593f5ca981",
      "kind": "file",
      "non_ascii_lines": []
    }
  },
  "changes": {}
}
```
