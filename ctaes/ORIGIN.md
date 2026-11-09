# Source origin

Repository: https://github.com/bitcoin-core/ctaes

Revision: 3b10b89b05ca1ef5fff33316777249df25c8b930 (master, 2025-01-21)

ctaes, Pieter Wuille's bit-sliced constant-time AES, imported as erXos's
code for the runtime's reference identities: `erx_ref_permute`
(`otp/erts/emulator/sys/erxos/erx_ref.c`) is its AES-128
([design-runtime.md](../docs/design-runtime.md#unguessable-references)).
The repository has no releases, so the import is the commit above, cloned
from the repository; each file sat at the repository's top:

| File | SHA-256 of the imported bytes |
| --- | --- |
| `COPYING` | `705391f5c3000c942b63c028977a372a5fb12eb0abc6210b3d835115e2544a06` |
| `ctaes.c` | `78913b0339766c3901825560aaba42f23081bd5ff20658ba4decd849c90e65e2` |
| `ctaes.h` | `a1a62f394eda457b35d9126373d3216cebaff536ba924515162414337dc8e4db` |

Licence: MIT, whose text and copyright holder (Pieter Wuille) are
`COPYING`; each source file names it in its header.

Left out: `bench.c`, `test.c` (its own vectors; erXos tests the import
against FIPS 197 and OpenSSL in `test/host/erx_ref_test.rb`) and
`README.md`. erXos builds `ctaes.c` directly.

Review: the cipher's only branches and table indices are on loop counters
and on the public encrypt-or-decrypt flag, never on key or data bits; the
S-box is Boyar and Peralta's boolean circuit. The file also carries
AES-192, AES-256 and CBC, which erXos does not call.

The import has no archive, so `archive_sha256` below is the SHA-256 of
the listing `shasum -a 256` prints for the three upstream paths, sorted
by path, one `<sha256>  <file>` line each with a final newline.

Each file erXos changes says so in a `Modified by erXos` notice at its
top, which lists the changes. All three are unchanged.

The inventory records the imported bytes and their licence evidence.
Third-party notices remain in their original files.

```json
{
  "version": 1,
  "repository": "https://github.com/bitcoin-core/ctaes",
  "revision": "3b10b89b05ca1ef5fff33316777249df25c8b930",
  "archive_sha256": "91b57d1da5f06bc5501293a1ab21723eab2450630912e6383e43070562c01c61",
  "exclusions": [],
  "files": {
    "COPYING": {
      "license": "MIT",
      "evidence": "reviewed COPYING: the MIT License, copyright (c) 2016 Pieter Wuille",
      "reviewed": true,
      "sha256": "705391f5c3000c942b63c028977a372a5fb12eb0abc6210b3d835115e2544a06",
      "kind": "file",
      "non_ascii_lines": []
    },
    "ctaes.c": {
      "license": "MIT",
      "evidence": "reviewed the file's header: copyright (c) 2016 Pieter Wuille, distributed under the MIT software license, see COPYING",
      "reviewed": true,
      "sha256": "78913b0339766c3901825560aaba42f23081bd5ff20658ba4decd849c90e65e2",
      "kind": "file",
      "non_ascii_lines": []
    },
    "ctaes.h": {
      "license": "MIT",
      "evidence": "reviewed the file's header: copyright (c) 2016 Pieter Wuille, distributed under the MIT software license, see COPYING",
      "reviewed": true,
      "sha256": "a1a62f394eda457b35d9126373d3216cebaff536ba924515162414337dc8e4db",
      "kind": "file",
      "non_ascii_lines": []
    }
  },
  "changes": {}
}
```
