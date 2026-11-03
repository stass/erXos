# Source origin

Repository: https://github.com/kernkonzept/drivers-frst

Revision: 6459d70997da1a2ad97775c8772b4a41284b0a9e

The inventory records the imported bytes and their licence evidence.
Third-party notices remain in their original files.

```json
{
  "version": 1,
  "repository": "https://github.com/kernkonzept/drivers-frst",
  "revision": "6459d70997da1a2ad97775c8772b4a41284b0a9e",
  "archive_sha256": "3eb24fe67cf4eb7968ba5379016befd3fb72977066a3708468290e9a9ca9f4ff",
  "exclusions": [
    {
      "path": "README.md",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "SECURITY.md",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "doc/files.cfg",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "hpet/Makefile",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "hpet/include/Makefile",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "hpet/include/hpet",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "hpet/src/Makefile",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "hpet/src/hpet.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "include/ARCH-amd64/asm_access.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "include/ARCH-arm/asm_access.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "include/ARCH-mips/asm_access.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "include/ARCH-riscv/asm_access.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "include/ARCH-x86/asm_access.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "include/asm_access_gen.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "include/hw_mmio_register_block",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "include/hw_register_block",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "include/io_regblock_port.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/Makefile",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/include/Makefile",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/include/lib_nand.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/include/transfer.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/src/Makefile",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/src/common.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/src/gpmc.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/src/gpmc.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/src/lib_nand.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/src/mpc5121.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/src/mpc5121.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/src/nand.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/src/nand.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/src/nand_ids.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "nand/src/types.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "of/Makefile",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "of/include/Makefile",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "of/include/of.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "of/include/of_dev.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "of/include/of_if.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "of/src/Makefile",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "of/src/of.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_16550.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_16550_dw.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_apb.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_bcm2835.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_cadence.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_dcc-v6.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_dm.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_dummy.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_geni.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_imx.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_leon3.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_linflex.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_lpuart.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_mvebu.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_of.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_omap35x.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_s3c2410.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_sa1000.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_sbi.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_sh.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_sifive.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_stm32.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/include/uart_tegra-tcu.h",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_16550.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_16550_dw.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_apb.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_bcm2835.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_cadence.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_dcc-v6.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_dm.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_geni.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_imx.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_leon3.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_linflex.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_lpuart.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_mvebu.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_of.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_omap35x.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_s3c2410.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_sa1000.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_sbi.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_sh.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_sifive.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_stm32.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    },
    {
      "path": "uart/src/uart_tegra-tcu.cc",
      "reason": "outside the frozen bootstrap, sigma0 and kernel source selection"
    }
  ],
  "files": {
    "Control": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a5bea7a9d927601238e9bd03b41d1cf43970a04f563d7dde1a297874bcce0545",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "Kconfig.L4": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "3bf4cd71f5f89a2631173eac003959b7096a7f52bbe2f6b4ce06a92b23163e87",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "LICENSE.spdx": {
      "license": "CC0-1.0",
      "evidence": "LICENSE.spdx DataLicense: CC0-1.0",
      "reviewed": true,
      "sha256": "75e6ac7d0937f58a6009008a4d712a56b9299b0f50e9f83177471980b53b8af1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "Makefile": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "c284955153d35bbf037d65777069fa448926096097737c87df3213669ce2e2d1",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "include/ARCH-arm64/asm_access.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "a780f378d435bfe345119f06cb3d61a15dc03433870aed0dd23202f2ebca56cd",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "include/Makefile": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "94f3e35e206054524218b9fe5628f40e1ecebe6b81de771ecea320412750022f",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "include/io_regblock.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "e3ab79bf418881bc675dbf1a2fea986b3fa4036491e899bfd184750a4f84b090",
      "kind": "file",
      "non_ascii_lines": [
        "50fa768b8e679a098b30afaef2c3731308982ce65874f2a9ec4641102115ecac"
      ]
    },
    "include/poll_timeout_counter.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "960e2379e547b731bd1ce65b7664ee1fd3e79b55729878a63c3e03020ec3b158",
      "kind": "file",
      "non_ascii_lines": [
        "50fa768b8e679a098b30afaef2c3731308982ce65874f2a9ec4641102115ecac"
      ]
    },
    "uart/Makefile": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "91177bd4ee7a7b23325ac31c7252d3e7c8df618c9a22475ecba74727ae159297",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "uart/include/Makefile": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "5bc0b28249a8bfde770dd4f8c5c4c3cdcf08c10dbdc97dac5725daa0e05f9e11",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "uart/include/device.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d81ee82def29115d92aea2b636eca114f5382b1525f2d87628efc6fce48a3067",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "uart/include/uart_base.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "fe275a478aecaa43e51ffc8b1d88ac05a8ac540479b5f017dec48f8bdd26c8c8",
      "kind": "file",
      "non_ascii_lines": [
        "85e3af0cc18338a2ecfc7614f5e335f654e8348e53ee713bb8716398f3632db2"
      ]
    },
    "uart/include/uart_pl011.h": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "d72526ea634e22d145fd1a2c2bfbfff28bae96d5d592087987b6db2f5d771194",
      "kind": "file",
      "non_ascii_lines": [
        "8d001a68a6ff73f56278c65f385facdd24dc5b047cdb4372868782e7a45204d7"
      ]
    },
    "uart/src/Makefile": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "8b6de8ba01256f7345e36079621715ad35bc00b1f6ef4c2c39beed37e0898053",
      "kind": "file",
      "non_ascii_lines": [

      ]
    },
    "uart/src/uart_pl011.cc": {
      "license": "MIT",
      "evidence": "reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence",
      "reviewed": true,
      "sha256": "91cb485d3c5ff075e705db8b9b43274ffa48f88de883cd7a079054e6794f0bde",
      "kind": "file",
      "non_ascii_lines": [
        "85e3af0cc18338a2ecfc7614f5e335f654e8348e53ee713bb8716398f3632db2"
      ]
    }
  },
  "changes": {
  }
}
```
