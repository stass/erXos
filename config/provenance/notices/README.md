# License texts not shipped with an import

`import-notices.json` pins each document here by SHA-256, and the pack
refuses a document whose bytes differ. Each file is a license text kept
byte for byte, so it may hold non-ASCII characters such as the copyright
sign.

| File | Source | SHA-256 |
| --- | --- | --- |
| `Unicode-3.0.txt` | `text/Unicode-3.0.txt` of https://github.com/spdx/license-list-data at tag `v3.29.0` (https://raw.githubusercontent.com/spdx/license-list-data/v3.29.0/text/Unicode-3.0.txt), the text of SPDX `Unicode-3.0`, "UNICODE LICENSE V3". | `f7db81051789b729fea528a63ec4c938fdcb93d9d61d97dc8cc2e9df6d47f2a1` |
| `COPYING3` | `COPYING3` of GCC 16, the copy `libgcc/contrib/gcc-16/COPYING3` of kernkonzept/l4re-core at `e2e2d5af9de7aa0e1df2a25ebadee54488fa4a49` (https://raw.githubusercontent.com/kernkonzept/l4re-core/e2e2d5af9de7aa0e1df2a25ebadee54488fa4a49/libgcc/contrib/gcc-16/COPYING3), the text of the GNU General Public License version 3. | `8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903` |
| `COPYING.RUNTIME` | `COPYING.RUNTIME` of GCC 16, the copy `libgcc/contrib/gcc-16/COPYING.RUNTIME` of the same commit (https://raw.githubusercontent.com/kernkonzept/l4re-core/e2e2d5af9de7aa0e1df2a25ebadee54488fa4a49/libgcc/contrib/gcc-16/COPYING.RUNTIME), the text of the GCC Runtime Library Exception, version 3.1. | `9d6b43ce4d8de0c878bf16b54d8e7a10d9bd42b75178153e3af6a815bdc90f74` |

OTP's `lib/stdlib/uc_spec/vendor.info` declares `Unicode-3.0` for the
Unicode data files and names no license text; the files point to
https://www.unicode.org/terms_of_use.html. The SPDX text is the reviewed
text for that identifier. Its copyright line is the SPDX template's
(1991-2023); each data file's own header, with its own year, stays in the
notice the pack keeps for that file.

The profile entry is global, as the `MIT` and `BSD-*` entries are: any
import that declares `Unicode-3.0` gets this text unless its package lists
a grant of its own.

To replace a text, fetch it once from the pinned URL, check the hash and
update the profile entry in the same change.
