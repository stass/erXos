# Source origin

Repository: https://github.com/freebsd/freebsd-src

Revision: release/15.1.0-p6 (95719d8a895bf8170851e9844d9b4092b1d2b6fe)

FreeBSD's ChaCha20, imported as erXos's code for the kernel's entropy
generator (`kernel/core/rng.c`). This directory mirrors FreeBSD's
`sys/crypto/chacha20/`; only the two files below were imported, each
fetched once from
`https://raw.githubusercontent.com/freebsd/freebsd-src/95719d8a895bf8170851e9844d9b4092b1d2b6fe/sys/crypto/chacha20/<file>`:

| File | Upstream path | SHA-256 of the imported bytes | License |
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
erXos's changes are BSD-2-Clause, under the repository's `LICENSE`, which
`config/provenance/import-notices.json` names as this tree's notice
document for that grant.

The two imported files name no license document. The dedication in each
file's header is the only license statement it holds, and attribution
keeps that header as the file's notice.

In the inventory, the `files` rows record the imported bytes and their
license evidence, and the `changes` rows each file's license as modified,
as its SPDX line gives it. Tooling does not compare a `changes` row's
`sha256` with a source file; `test/host/production_image_test.rb` does for
these two. Third-party notices remain in their original files.

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
  "changes": {
    "chacha.c": {
      "license": "BSD-2-Clause AND LicenseRef-DJB-public-domain",
      "evidence": "the file's own SPDX line: D. J. Bernstein's public-domain dedication stays in its header, and erXos's changes are BSD-2-Clause",
      "sha256": "44e908f41cc7beac8f1934164ab30038eb680288093f80def81c82a0945a27a5"
    },
    "chacha.h": {
      "license": "BSD-2-Clause AND LicenseRef-DJB-public-domain",
      "evidence": "the file's own SPDX line: D. J. Bernstein's public-domain dedication stays in its header, and erXos's changes are BSD-2-Clause",
      "sha256": "3703994279474231160acc4a7eddab22f02a3dcdbf4c9ba025648b0107f67d3e"
    }
  }
}
```
