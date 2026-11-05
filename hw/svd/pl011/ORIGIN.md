# Source origin

Repository: https://github.com/raspberrypi/pico-sdk

Revision: 1.5.1

The UART0 peripheral of the Raspberry Pi Pico SDK's RP2040 register
description, fetched once from
`https://raw.githubusercontent.com/raspberrypi/pico-sdk/1.5.1/src/rp2040/hardware_regs/rp2040.svd`.
Its SHA-256 is `5a046202808f07c660ade1a4b38ad31d10309ec1abbafea4a0342fc538f626c8`,
the `archive_sha256` below. Licence: BSD-3-Clause, Copyright (c) 2020 Raspberry
Pi (Trading) Ltd.; `pl011.svd` keeps that notice in its head comment, and
`LICENSE.TXT` is the SDK's licence text, unchanged, fetched once from
`https://raw.githubusercontent.com/raspberrypi/pico-sdk/1.5.1/LICENSE.TXT`. Purpose: the
register layout of the Arm PrimeCell UART PL011, which the RP2040 carries and
which `erx_device`, the console UART's table and the generated accessors are
built from. Status: `permanent`; see the dependency table in `docs/design.md`.
Only UART0 is in the tree; the rest of `rp2040.svd` is not.

`pl011.svd` here is made from the upstream file by
`ruby tools/carve_pl011_svd.rb rp2040.svd hw/svd/pl011/pl011.svd`,
which refuses any `rp2040.svd` whose SHA-256 differs. The `files` row below records the SHA-256
of the carved file as it stands in the tree. The edits, all made by that script:

* Only the `UART0` peripheral is kept. The upstream `vendor`, `cpu`,
  `licenseText`, the peripheral's `version`, `size` and `interrupt`, and each
  register's `resetValue` are left out, because the generator's SVD profile
  refuses them; the licence text becomes the head comment. `schemaVersion` is
  `1.3`, the version the profile accepts. The `xmlns` and schema-location
  attributes of the upstream `device` element are dropped with it.
* The device and the peripheral are named `PL011` and the base address is `0`,
  because the table is generic over the device's instances; the board gives
  the address. The device `version` and `description` are erXos's (`1` and
  "PrimeCell UART register interface") where upstream describes the RP2040.
* The peripheral has the UART's registers up to `PCELLID3` only. The Arm
  manual's integration test registers at 0x80 to 0x8C are in neither upstream
  nor this file.
* The `UART` prefix is stripped from register names (`UARTDR` is `DR`,
  `UARTLCR_H` is `LCR_H`, `UARTPERIPHID0` is `PERIPHID0`). Field names stay as
  upstream has them, so `DIVINT` and `DIVFRAC` of the earlier hand-written file
  are `BAUD_DIVINT` and `BAUD_DIVFRAC`.
* `bitRange` `[high:low]` becomes `bitOffset` and `bitWidth`.
* The upstream states access on fields only. Each register gets the weakest
  access that admits all its fields: read-only if every field is, otherwise
  read-write. Fields are listed from the lowest bit up.
* `holdsDeviceAddress` is `false` on every register, the mark the profile
  requires.
* Three registers differ from upstream on purpose, because the Arm manual (DDI
  0183G, sections 3.2 and 3.3) says so: `DR` carries `readAction` `modify`,
  since a read pops the receive FIFO; `ICR` and its fields are `write-only`
  where upstream says read-write; and the fields of `RSR` are `read-only`
  with no `modifiedWriteValues`, where upstream has one-to-clear fields,
  because any write to `RSR` clears all four errors at once (section 3.3),
  so a zero written to one error does not leave the others alone.
* Descriptions are upstream's, with runs of white space made single spaces.

Not changed, and different from the manual: `RSR` stays read-write. The manual
has a read-only `RSR` and a write-only `ECR` at the same offset; the profile has
one access per register, so the generated table lets Erlang write `RSR` as a
whole, which clears all four errors, as the manual says a write does. Its
fields are read-only, so no field of it is written alone.

The head comment says the layout was also compared with Arm DDI 0183G r1p5,
which is not redistributable and is not in the tree.

```json
{
  "version": 1,
  "repository": "https://github.com/raspberrypi/pico-sdk",
  "revision": "1.5.1",
  "archive_sha256": "5a046202808f07c660ade1a4b38ad31d10309ec1abbafea4a0342fc538f626c8",
  "exclusions": [],
  "files": {
    "LICENSE.TXT": {
      "license": "BSD-3-Clause",
      "evidence": "the SDK licence text, fetched from the pinned URL",
      "reviewed": true,
      "sha256": "483f865953435b66c443dee7558debe3cc3cf8fcbb6a112fd9fc6a795d53f1f6",
      "kind": "file",
      "non_ascii_lines": []
    },
    "pl011.svd": {
      "license": "BSD-3-Clause",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "64d44cf45b7029536b91a6dfe10dc9361f4076a737ebc2b917f441d7a99e0e1c",
      "kind": "file",
      "non_ascii_lines": []
    }
  },
  "changes": {}
}
```
