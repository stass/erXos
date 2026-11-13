# Source origin

Repository: https://github.com/freebsd/freebsd-src

Revision: release/15.1.0-p6 (95719d8a895bf8170851e9844d9b4092b1d2b6fe)

FreeBSD's SHA-256, imported as erXos's code for every C caller of the
per-byte primitives. This directory mirrors FreeBSD's
`sys/crypto/sha2/`; only the two files below were imported, each
fetched once from
`https://raw.githubusercontent.com/freebsd/freebsd-src/95719d8a895bf8170851e9844d9b4092b1d2b6fe/sys/crypto/sha2/<file>`:

| File | Upstream path | SHA-256 of the imported bytes | License |
| --- | --- | --- | --- |
| `sha256c.c` | `sys/crypto/sha2/sha256c.c` | `9eed9976f45476f7dd0dd452861416ff1f45b2a7035909171dc6fef836ba9b61` | BSD-2-Clause (Colin Percival) |
| `sha256.h` | `sys/crypto/sha2/sha256.h` | `10f3fd28a59056ad4701c58570d55cd4de4dcebfbaa490c154b7005f8e16dabe` | BSD-2-Clause (Colin Percival) |

Left out: `sha224.h` and `sha256c_impl.h` (SHA-224 and the ARMv8
SHA-2 instruction path, which erXos does not use from here).

The import has no archive, so `archive_sha256` below is the SHA-256 of
the listing `shasum -a 256` prints for the two upstream paths, sorted
by path, one `<sha256>  sys/crypto/sha2/<file>` line each with a final
newline.

Each file erXos changed says so in a `Modified by erXos` notice at its
top, which lists the changes; the original notices stay below it.
erXos's changes are BSD-2-Clause.

The inventory records the imported bytes and their license evidence.
Third-party notices remain in their original files.

```json
{
  "version": 1,
  "repository": "https://github.com/freebsd/freebsd-src",
  "revision": "release/15.1.0-p6 (95719d8a895bf8170851e9844d9b4092b1d2b6fe)",
  "archive_sha256": "2b1d9ac6be0420b103ad64e9071d443a6b841242893520ef5abf73ce9b065210",
  "exclusions": [],
  "files": {
    "sha256.h": {
      "license": "BSD-2-Clause",
      "evidence": "reviewed Colin Percival's notice in the file, the two-clause BSD license text",
      "reviewed": true,
      "sha256": "10f3fd28a59056ad4701c58570d55cd4de4dcebfbaa490c154b7005f8e16dabe",
      "kind": "file",
      "non_ascii_lines": []
    },
    "sha256c.c": {
      "license": "BSD-2-Clause",
      "evidence": "reviewed Colin Percival's notice in the file, the two-clause BSD license text",
      "reviewed": true,
      "sha256": "9eed9976f45476f7dd0dd452861416ff1f45b2a7035909171dc6fef836ba9b61",
      "kind": "file",
      "non_ascii_lines": []
    }
  },
  "changes": {}
}
```
