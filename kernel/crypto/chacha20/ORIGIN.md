# Source origin

Repository: https://github.com/freebsd/freebsd-src

Revision: release/15.1.0-p6 (95719d8a895bf8170851e9844d9b4092b1d2b6fe)

FreeBSD's ChaCha20, imported as erXos's code for the kernel's entropy
generator (`kernel/core/rng.c`). This directory mirrors FreeBSD's
`sys/crypto/chacha20/`; only the two files below were imported, each
fetched once from
`https://raw.githubusercontent.com/freebsd/freebsd-src/95719d8a895bf8170851e9844d9b4092b1d2b6fe/sys/crypto/chacha20/<file>`:

| File | Upstream path | SHA-256 of the imported bytes | Licence |
| --- | --- | --- | --- |
| `chacha.c` | `sys/crypto/chacha20/chacha.c` | `00e2b5166219cd30d747bca90b5759971a1a5855a1cc33c4550fdc32157c1321` | public domain (D. J. Bernstein, via OpenBSD) |
| `chacha.h` | `sys/crypto/chacha20/chacha.h` | `22c2686f6060c8c6cf8fc080ab7c42e90d984fd8154318cf02e9e1cf0acc151f` | public domain (D. J. Bernstein, via OpenBSD) |

Left out: `_chacha.h` (the three-line context structure, which
`chacha.c` defines privately).

The import has no archive, so `archive_sha256` below is the SHA-256 of
the listing `shasum -a 256` prints for the two upstream paths, sorted
by path, one `<sha256>  sys/crypto/chacha20/<file>` line each with a
final newline.

Each file erXos changed says so in a `Modified by erXos` notice at its
top, which lists the changes; the original notices stay below it.
erXos's changes are BSD-2-Clause.

The inventory records the imported bytes and their licence evidence.
Third-party notices remain in their original files.

```json
{
  "version": 1,
  "repository": "https://github.com/freebsd/freebsd-src",
  "revision": "release/15.1.0-p6 (95719d8a895bf8170851e9844d9b4092b1d2b6fe)",
  "archive_sha256": "6fc6e5a43ff2f695ce61dd9532309c40fd8ba4f0c7f52c52a576aadb64b91e6e",
  "exclusions": [],
  "files": {
    "chacha.c": {
      "license": "LicenseRef-DJB-public-domain",
      "evidence": "reviewed D. J. Bernstein's public-domain dedication in the file (chacha-merged.c version 20080118, via OpenBSD)",
      "reviewed": true,
      "sha256": "00e2b5166219cd30d747bca90b5759971a1a5855a1cc33c4550fdc32157c1321",
      "kind": "file",
      "non_ascii_lines": []
    },
    "chacha.h": {
      "license": "LicenseRef-DJB-public-domain",
      "evidence": "reviewed D. J. Bernstein's public-domain dedication in the file (chacha-merged.c version 20080118, via OpenBSD)",
      "reviewed": true,
      "sha256": "22c2686f6060c8c6cf8fc080ab7c42e90d984fd8154318cf02e9e1cf0acc151f",
      "kind": "file",
      "non_ascii_lines": []
    }
  },
  "changes": {}
}
```
