# Licence texts not shipped with an import

`import-notices.json` pins each document here by SHA-256, and the pack
refuses a document whose bytes differ. Each file is a licence text kept
byte for byte, so it may hold non-ASCII characters such as the copyright
sign.

| File | Source | SHA-256 |
| --- | --- | --- |
| `Unicode-3.0.txt` | `text/Unicode-3.0.txt` of https://github.com/spdx/license-list-data at tag `v3.29.0` (https://raw.githubusercontent.com/spdx/license-list-data/v3.29.0/text/Unicode-3.0.txt), the text of SPDX `Unicode-3.0`, "UNICODE LICENSE V3". | `f7db81051789b729fea528a63ec4c938fdcb93d9d61d97dc8cc2e9df6d47f2a1` |

OTP's `lib/stdlib/uc_spec/vendor.info` declares `Unicode-3.0` for the
Unicode data files and names no licence text; the files point to
https://www.unicode.org/terms_of_use.html. The SPDX text is the reviewed
text for that identifier. Its copyright line is the SPDX template's
(1991-2023); each data file's own header, with its own year, stays in the
notice the pack keeps for that file.

The profile entry is global, as the `MIT` and `BSD-*` entries are: any
import that declares `Unicode-3.0` gets this text unless its package lists
a grant of its own.

To replace a text, fetch it once from the pinned URL, check the hash and
update the profile entry in the same change.
