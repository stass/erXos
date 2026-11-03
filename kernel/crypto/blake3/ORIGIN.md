# Source origin

Repository: https://github.com/BLAKE3-team/BLAKE3

Revision: 1.8.7 (f3149ec5bb5449af877ba20377a11008ff499fa2)

BLAKE3's official C implementation, its portable code only, imported as
erXos's code for the boot image's index and file hashes
([design-kernel.md](../../../docs/design-kernel.md#the-boot-image)).
Each file was fetched once, at release tag 1.8.7, from
`https://raw.githubusercontent.com/BLAKE3-team/BLAKE3/f3149ec5bb5449af877ba20377a11008ff499fa2/<path>`:

| File | Upstream path | SHA-256 of the imported bytes |
| --- | --- | --- |
| `blake3.h` | `c/blake3.h` | `81bbb11ad1909341565dce4914cc0e5c29718eca27e6950b28f9226a91aaf8c5` |
| `blake3.c` | `c/blake3.c` | `b118ddf7cf9e6e5ef3fded72dcb1acf9dfdc4ea923cbe4605900ad6ee9afe1af` |
| `blake3_impl.h` | `c/blake3_impl.h` | `d388dca3574602c8849805ea3c8c0a12d082ac0e428756f305e111942f099af4` |
| `blake3_portable.c` | `c/blake3_portable.c` | `2bc25b0dad67b4329d0b49cfa075ab2b0d04e424addbddc4e9c389c52a192524` |
| `test_vectors.json` | `test_vectors/test_vectors.json` | `dcb91ea8accc77e6d6e632af7cdc1a99a9f3ae78cf648da595c7d064db32f624` |
| `LICENSE_A2LLVM` | `LICENSE_A2LLVM` | `a5695f57ea0c221e0e8b7d784ff774c35e88c3d3270353646a925880bb3492cc` |

Licence: the BLAKE3 authors offer the code under CC0-1.0, Apache-2.0 or
Apache-2.0 WITH LLVM-exception (`LICENSE_CC0`, `LICENSE_A2` and
`LICENSE_A2LLVM` at the repository root); the source files carry no
notices of their own. erXos takes it under Apache-2.0 WITH
LLVM-exception, whose text is `LICENSE_A2LLVM` here, and erXos's
changes are under the same licence.

Left out: `blake3_dispatch.c` (run-time CPU-feature detection and the
choice among SIMD paths), every SIMD implementation (SSE2, SSE4.1, AVX2,
AVX-512, NEON, in C and assembly), the TBB code, the build files and the
example. The kernel executes no FP or SIMD instruction, so the portable
path is the only one, by construction rather than by build defines.

The import has no archive, so `archive_sha256` below is the SHA-256 of
the listing `shasum -a 256` prints for the six upstream paths, sorted by
path, one `<sha256>  <path>` line each with a final newline.

Each file erXos changed says so in a `Modified by erXos` notice at its
top, which lists the changes. `test_vectors.json` and `LICENSE_A2LLVM`
are unchanged.

The inventory records the imported bytes and their licence evidence.
Third-party notices remain in their original files.

```json
{
  "version": 1,
  "repository": "https://github.com/BLAKE3-team/BLAKE3",
  "revision": "1.8.7 (f3149ec5bb5449af877ba20377a11008ff499fa2)",
  "archive_sha256": "00a0d839dabfb693a6320d93a08e6ec74e0c4d3627627e24f2e2f087970c2527",
  "exclusions": [],
  "files": {
    "LICENSE_A2LLVM": {
      "license": "Apache-2.0 WITH LLVM-exception",
      "evidence": "reviewed the repository root: BLAKE3 is offered under CC0-1.0, Apache-2.0 or Apache-2.0 WITH LLVM-exception (LICENSE_CC0, LICENSE_A2, LICENSE_A2LLVM); the files carry no notices of their own; erXos takes it under Apache-2.0 WITH LLVM-exception",
      "reviewed": true,
      "sha256": "a5695f57ea0c221e0e8b7d784ff774c35e88c3d3270353646a925880bb3492cc",
      "kind": "file",
      "non_ascii_lines": []
    },
    "blake3.c": {
      "license": "Apache-2.0 WITH LLVM-exception",
      "evidence": "reviewed the repository root: BLAKE3 is offered under CC0-1.0, Apache-2.0 or Apache-2.0 WITH LLVM-exception (LICENSE_CC0, LICENSE_A2, LICENSE_A2LLVM); the files carry no notices of their own; erXos takes it under Apache-2.0 WITH LLVM-exception",
      "reviewed": true,
      "sha256": "b118ddf7cf9e6e5ef3fded72dcb1acf9dfdc4ea923cbe4605900ad6ee9afe1af",
      "kind": "file",
      "non_ascii_lines": []
    },
    "blake3.h": {
      "license": "Apache-2.0 WITH LLVM-exception",
      "evidence": "reviewed the repository root: BLAKE3 is offered under CC0-1.0, Apache-2.0 or Apache-2.0 WITH LLVM-exception (LICENSE_CC0, LICENSE_A2, LICENSE_A2LLVM); the files carry no notices of their own; erXos takes it under Apache-2.0 WITH LLVM-exception",
      "reviewed": true,
      "sha256": "81bbb11ad1909341565dce4914cc0e5c29718eca27e6950b28f9226a91aaf8c5",
      "kind": "file",
      "non_ascii_lines": []
    },
    "blake3_impl.h": {
      "license": "Apache-2.0 WITH LLVM-exception",
      "evidence": "reviewed the repository root: BLAKE3 is offered under CC0-1.0, Apache-2.0 or Apache-2.0 WITH LLVM-exception (LICENSE_CC0, LICENSE_A2, LICENSE_A2LLVM); the files carry no notices of their own; erXos takes it under Apache-2.0 WITH LLVM-exception",
      "reviewed": true,
      "sha256": "d388dca3574602c8849805ea3c8c0a12d082ac0e428756f305e111942f099af4",
      "kind": "file",
      "non_ascii_lines": []
    },
    "blake3_portable.c": {
      "license": "Apache-2.0 WITH LLVM-exception",
      "evidence": "reviewed the repository root: BLAKE3 is offered under CC0-1.0, Apache-2.0 or Apache-2.0 WITH LLVM-exception (LICENSE_CC0, LICENSE_A2, LICENSE_A2LLVM); the files carry no notices of their own; erXos takes it under Apache-2.0 WITH LLVM-exception",
      "reviewed": true,
      "sha256": "2bc25b0dad67b4329d0b49cfa075ab2b0d04e424addbddc4e9c389c52a192524",
      "kind": "file",
      "non_ascii_lines": []
    },
    "test_vectors.json": {
      "license": "Apache-2.0 WITH LLVM-exception",
      "evidence": "reviewed the repository root: BLAKE3 is offered under CC0-1.0, Apache-2.0 or Apache-2.0 WITH LLVM-exception (LICENSE_CC0, LICENSE_A2, LICENSE_A2LLVM); the files carry no notices of their own; erXos takes it under Apache-2.0 WITH LLVM-exception",
      "reviewed": true,
      "sha256": "dcb91ea8accc77e6d6e632af7cdc1a99a9f3ae78cf648da595c7d064db32f624",
      "kind": "file",
      "non_ascii_lines": []
    }
  },
  "changes": {}
}
```
