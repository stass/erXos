# BCM2711 PCIe bridge and VL805: facts record (clean room)

A point-in-time research record, written on 2026-11-14 on the Apple
Silicon macOS 27.0.1 development host whose scratch directory holds the
sources listed below. It is the clean-room half of the USB design's
work on the Raspberry Pi 4: what Linux's and FreeBSD's drivers for the
BCM2711's PCIe bridge and the VL805 xHCI controller do, and what the
board's device trees say, written so that the authors of
[design-usb.md](design-usb.md) and of erXos's bridge driver never read
the GPL-licensed sources. The design cites it as "facts record" by
section. Facts that only a board can settle are listed at the end; the
design's board probes settle them.

Date: 2026-11-14. Written by the clean-room facts writer. This record states
hardware facts and observed driver behavior in its own words. It contains no
code, no copied comments and no identifiers from Linux except register and
field names, which are hardware facts. Design and code agents read this record,
never the Linux sources.

Citation form: `ML:file:line` is mainline Linux, `RPI:file:line` the Raspberry
Pi downstream tree, `FB:file:line` FreeBSD. Short paths used below:
`brcmstb.c` = drivers/pci/controller/pcie-brcmstb.c,
`rpi-reset.c` = drivers/reset/reset-raspberrypi.c,
`bcm2711.dtsi`, `rpi-4-b.dts`, `rpi-ds.dtsi` = arch/arm/boot/dts/broadcom/...,
`fb-pci.c` = sys/arm/broadcom/bcm2835/bcm2838_pci.c,
`fb-xhci.c` = sys/arm/broadcom/bcm2835/bcm2838_xhci.c.

Statements marked **inference** are my reading of a register or field name, or
arithmetic on cited values, not something a source states. Statements marked
**unknown** could not be established from these sources.

## Sources

All fetched over HTTPS on 2026-11-14 into
`~/erxos-scratch/sources/linux-brcmstb/`, outside the tree, (read as data, nothing run).

**Mainline Linux, stable tag v7.3.4** (latest stable on kernel.org's
releases.json that day), from
`https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/<path>?h=v7.3.4`:

| SHA-256 | path |
|---|---|
| edd83fe0bd5d3ff0989119c6a35001bed63c802a29a7f1567fd18a43b392a9eb | drivers/pci/controller/pcie-brcmstb.c |
| c5c284fea27f9b047c16c51fb11bb4f9f60e1c71bf7763e72cdc770983ee09da | drivers/pci/pci.h |
| 74b10cc81c2d5920dd5c39eafa7464c30d471e86b8fa88bad1d7f86a17f61362 | drivers/reset/reset-raspberrypi.c |
| 490a44a2447031469c30f734380580fe45facf03d19a7c03e075434338c8de64 | drivers/usb/host/pci-quirks.c |
| da9160ed768f9fbd9b17740e0ffb33ac78e97fd8b912ae7dcea9dc05ded0efb3 | drivers/usb/host/xhci-pci.c |
| 44ca06ce699192d60302896df23ef3ee243abe979ac5f3c759de9830ec311cc0 | drivers/usb/host/xhci.h |
| abfe6f6f70bdeaf7a279a734bdab034ef014f329785ccb8c5f5cf3e763320198 | drivers/usb/host/xhci-mem.c |
| ebea76efcaf30e32b6eb3e72f4b18a872a7a542e1ffb7b6d203c28b515caf248 | drivers/usb/host/xhci.c |
| 64fda3a4f8211e17f0cae108ff1fea67804245606ac487d34697e77f1e6f388f | arch/arm/boot/dts/broadcom/bcm2711.dtsi |
| 13a42cdc5aa8e85a2bca0d058eced7fada8213203ea9eacaf8ad32e3eccfbb47 | arch/arm/boot/dts/broadcom/bcm2711-rpi.dtsi |
| c69ee77b38dc3c3b7edff87b4cd24f3ed1d54e5b73154d65a84249d53a51feb1 | arch/arm/boot/dts/broadcom/bcm2711-rpi-4-b.dts |
| 501186ee9e694dc45125a9206a0cf978a4e8fb443e46a7e752bbdec84201679c | include/soc/bcm2835/raspberrypi-firmware.h |
| b5fed4b44b6e23a3e8596cf3de21d06586ae7ea74289515a5ec6775bf8d2b5b9 | include/dt-bindings/reset/raspberrypi,firmware-reset.h |

The BCM2711 device tree lives at `arch/arm/boot/dts/broadcom/bcm2711.dtsi`
(the 32-bit arm directory, included by arm64); no file moved otherwise.

**Raspberry Pi downstream Linux**, default branch `rpi-6.18.y` at commit
`ea17ae02ca28483e508b05c7c44190c01a1ef8eb`, from
`https://raw.githubusercontent.com/raspberrypi/linux/<commit>/<path>`:

| SHA-256 | path |
|---|---|
| 212ec09ab522c2e7b81638be3db833bb7e3ad62b201a08f9858092f6130ec787 | drivers/pci/controller/pcie-brcmstb.c |
| 74b10cc81c2d5920dd5c39eafa7464c30d471e86b8fa88bad1d7f86a17f61362 | drivers/reset/reset-raspberrypi.c (identical to mainline) |
| 490a44a2447031469c30f734380580fe45facf03d19a7c03e075434338c8de64 | drivers/usb/host/pci-quirks.c (identical to mainline) |
| 0abee6ec05b30f133504238bb528657696b5d4f3d925c12cf6184cd7f73f1303 | drivers/usb/host/xhci-pci.c |
| 8a9abc18814d45ac3c1091b6a5f7ba6e4133862a1f8eb39a663c4cc0ea8cf3df | drivers/usb/host/xhci.h |
| 41347abffac2e29c8e11c7d4077c99ad2242b7648f7737488df84f00ac455da0 | drivers/usb/host/xhci-ring.c |
| 9d2a75eae7c4671dffb2db78755efd9e860434ea1706e5967d1b39e45fa512cb | drivers/usb/host/xhci.c |
| 28d6a10f23b43b0c97b4c4ab19e59fc2244cc9706f834e4dbf2244cb7c305e37 | drivers/usb/host/xhci-mem.c |
| 8fdb3a513879c250341bd6e182a33e69d9c6929eab332d8e69ab1d999d8b57af | arch/arm/boot/dts/broadcom/bcm2711.dtsi |
| 788b077359f6d0480a239f2f8a7d50325835e06cda347a61ef2bba1ba329be5d | arch/arm/boot/dts/broadcom/bcm2711-rpi.dtsi |
| 8c4780dbdcfeed32c0cb4da7e27f240e51ef58d6b26595e0de5e33eddb06d9c9 | arch/arm/boot/dts/broadcom/bcm2711-rpi-ds.dtsi |
| d39863c4c41ff6dfb0559604b4d432404789985f547ec1e31e811a091207a3c3 | arch/arm/boot/dts/broadcom/bcm2711-rpi-4-b.dts |

**FreeBSD**, branch `releng/15.1` at commit
`95719d8a895bf8170851e9844d9b4092b1d2b6fe` (2026-10-20), from
`https://raw.githubusercontent.com/freebsd/freebsd-src/<commit>/<path>`:

| SHA-256 | path |
|---|---|
| 10a983496e957f3cf01039f5076e189a817bdfc5da53e582f42dad525d1ac6a9 | sys/arm/broadcom/bcm2835/bcm2838_pci.c |
| ad6b745a07c7aa2d227f22f9839ce26fe2162df7cb2c4a41b815e5ba66d24a60 | sys/arm/broadcom/bcm2835/bcm2838_xhci.c |
| d13585891d30fd9171c4c75929a2aa3e48a1bcf7dad6f791871247fbc02a779a | sys/dev/usb/controller/xhci_pci.c (no VL805 handling) |
| 5fddd7a02c70f4a014d65e5e6a3e20d9e69f77e961c035ba975572310350136f | sys/arm/broadcom/bcm2835/bcm2835_mbox_prop.h |
| 5155a952be0086a45df81895cd4fd99244ce48a322347108a756d43731cdca73 | sys/arm/broadcom/bcm2835/bcm2835_mbox.c |

The downstream `pcie-brcmstb.c` differs from mainline mostly in BCM2712 support
(Pi 5), statistics, LTSSM tracing and debugfs. Its BCM2711 configuration entry
is identical to mainline's (RPI:brcmstb.c:2247-2252 vs ML:brcmstb.c:1947-1953).
The downstream differences that touch BCM2711 are listed in section 8.

## 0. Where the block is and what the board's device tree says

* Compatible string `brcm,bcm2711-pcie`; register block at bus address
  0x7d500000, length 0x9310 (ML:bcm2711.dtsi:553-555). The enclosing `scb`
  bus maps child 0x0_7c000000 to CPU 0xfc000000 for 0x03800000 bytes and
  child 0x6_00000000 to CPU 0x6_00000000 (ML:bcm2711.dtsi:545-551), so the
  registers sit at CPU physical 0xfd500000 (**inference**, arithmetic).
* Two interrupts: SPI 147 named `pcie` and SPI 148 named `msi`, both
  level-high (ML:bcm2711.dtsi:560-562).
* INTx: `interrupt-map-mask` keeps only the pin; INTA..INTD map to GIC SPI
  143, 144, 145, 146, level-high (ML:bcm2711.dtsi:563-571). With standard GIC
  numbering these are INTIDs 175-178, and 147/148 are INTIDs 179/180
  (**inference**: SPI n is INTID n+32).
* The node is its own MSI controller (`msi-controller`, `msi-parent` pointing
  at itself) (ML:bcm2711.dtsi:572-573).
* Outbound (`ranges`), mainline: one 32-bit non-prefetchable memory range,
  PCI 0xf8000000 at CPU 0x6_00000000, size 64 MiB (ML:bcm2711.dtsi:575-576).
  Downstream overrides it for the Pi 4 to PCI 0xc0000000 at CPU 0x6_00000000,
  size 1 GiB (RPI:rpi-ds.dtsi:156-160).
* Inbound (`dma-ranges`): PCI 0x0 at CPU 0x0, size 0xc0000000 (3 GiB), with a
  device-tree remark that the wrapper around the PCIe block cannot access
  beyond the first 3 GiB of memory (ML:bcm2711.dtsi:577-583; same downstream,
  RPI:bcm2711.dtsi:577-583).
* `brcm,enable-ssc` is present (ML:bcm2711.dtsi:584).
* None of `max-link-speed`, `brcm,clkreq-mode`, `brcm,enable-l1ss`,
  `aspm-no-l0s`, `num-lanes`, `brcm,scb-sizes`, `brcm,tperst-clk-ms` appear in
  any Pi 4 device-tree file fetched (searched all fetched .dts/.dtsi).
* Pi 4 board file: a child `pci@0,0` (the root port) with child `usb@0,0`
  (the VL805 at bus 1, device 0, function 0) carrying
  `resets = <&reset RASPBERRYPI_FIRMWARE_RESET_ID_USB>` (ML:rpi-4-b.dts:232-245);
  that ID is 0 (ML:include/dt-bindings/reset/raspberrypi,firmware-reset.h:10);
  the provider is a node with compatible `raspberrypi,firmware-reset`
  (ML:bcm2711-rpi.dtsi:53-56).
* No `resets` property on the pcie0 node itself, so on BCM2711 the bridge
  reset and PERST# are driven through the bridge's own register (section 1).

## Register map used on BCM2711 (offsets from the block base)

| Offset | Name | Fields used | Cite |
|---|---|---|---|
| 0x0000-0x0fff | root port's own config space | read/written directly for bus 0 dev 0 fn 0 | ML:brcmstb.c:782-783 |
| 0x00ac | PCIe capability of the root port | LNKSTA at +0x12, LNKCTL2 at +0x30 (standard layout) | ML:brcmstb.c:44, 1441-1443, 475-485 |
| 0x0188 | RC_CFG_VENDOR_VENDOR_SPECIFIC_REG1 | ENDIAN_MODE_BAR2 bits 3:2; 0 = little endian | ML:brcmstb.c:47-49 |
| 0x043c | RC_CFG_PRIV1_ID_VAL3 | CLASS_CODE bits 23:0 | ML:brcmstb.c:51-52 |
| 0x04dc | RC_CFG_PRIV1_LINK_CAPABILITY | standard LNKCAP layout: speed bits 3:0, MAX_LINK_WIDTH bits 8:4, ASPM L0s bit | ML:brcmstb.c:54-55, 475-485, 1236-1261 |
| 0x04f8 | RC_CFG_PRIV1_ROOT_CAP | L1SS_MODE bits 7:3 | ML:brcmstb.c:57-58 |
| 0x1100/0x1104/0x1108 | RC_DL_MDIO_ADDR / WR_DATA / RD_DATA | see SSC | ML:brcmstb.c:60-62 |
| 0x1804 | RC_PL_REG_PHY_CTL_1 | P2_POWERDOWN_ENA_NOSYNC bit 3 | ML:brcmstb.c:64-65 |
| 0x4008 | MISC_MISC_CTRL | RCB_64B_MODE bit 7, RCB_MPS_MODE bit 10, SCB_ACCESS_EN bit 12, CFG_READ_UR_MODE bit 13, MAX_BURST_SIZE bits 21:20, SCB1_SIZE bits 26:22, SCB0_SIZE bits 31:27, SCB2_SIZE bits 4:0 | ML:brcmstb.c:71-81 |
| 0x400c + 8w / 0x4010 + 8w | CPU_2_PCIE_MEM_WINw_LO / HI | PCI bus address of outbound window w (w = 0..3) | ML:brcmstb.c:83-89, 203 |
| 0x402c + 8(n-1) | MISC_RC_BARn_CONFIG_LO (n = 1..3) | SIZE bits 4:0, PCI address low bits above | ML:brcmstb.c:99-100, 1075-1081 |
| +4 of the above | MISC_RC_BARn_CONFIG_HI | PCI address high 32 bits | ML:brcmstb.c:1111 |
| 0x4044 / 0x4048 | MISC_MSI_BAR_CONFIG_LO / HI | MSI target address; bit 0 of LO is reused as MSI enable | ML:brcmstb.c:105-106, 692-698 |
| 0x404c | MISC_MSI_DATA_CONFIG | 0xffe06540 for 32 vectors, 0xfff86540 for 8 | ML:brcmstb.c:108-110 |
| 0x4060 | MSI EOI (FreeBSD name REG_MSI_EOI) | written 1 by FreeBSD; Linux never touches it | FB:fb-pci.c:83, 391 |
| 0x4064 | MISC_PCIE_CTRL | L23_REQUEST bit 0 (PERSTB bit 2 is for other SoCs) | ML:brcmstb.c:112-114 |
| 0x4068 | MISC_PCIE_STATUS | PHYLINKUP bit 4, DL_ACTIVE bit 5, LINK_IN_L23 bit 6, PORT bit 7 (1 = root complex) | ML:brcmstb.c:116-120 |
| 0x406c | MISC_REVISION | hardware revision; 0x0303 is the MSI-layout threshold | ML:brcmstb.c:122-124 |
| 0x4070 + 4w | CPU_2_PCIE_MEM_WINw_BASE_LIMIT | BASE bits 15:4, LIMIT bits 31:20, both in MiB | ML:brcmstb.c:126-130 |
| 0x4080 + 8w / 0x4084 + 8w | CPU_2_PCIE_MEM_WINw_BASE_HI / LIMIT_HI | upper MiB bits, 8-bit fields | ML:brcmstb.c:132-140 |
| 0x4204 | MISC_HARD_PCIE_HARD_DEBUG | CLKREQ_DEBUG_ENABLE bit 1, L1SS_ENABLE bit 21, SERDES_IDDQ bit 27 | ML:brcmstb.c:142-148, 1907-1912 |
| 0x4300 | INTR2_CPU base | legacy MSI status at bits 31:24 (only if revision < 0x0303) | ML:brcmstb.c:1911, 734-737 |
| 0x4500 | MSI_INTR2 base | STATUS +0x0, CLR +0x8, MASK_SET +0x10, MASK_CLR +0x14 | ML:brcmstb.c:154-160 |
| 0x8000 | EXT_CFG_DATA | 4 KiB window onto the selected device's config space | ML:brcmstb.c:1909 |
| 0x9000 | EXT_CFG_INDEX | selects bus/device/function | ML:brcmstb.c:1908 |
| 0x9208 | RGR1 timeout (two words before RGR1_SW_INIT_1) | units of 1/216 MHz | ML:brcmstb.c:1323-1335 |
| 0x9210 | RGR1_SW_INIT_1 | PERST bit 0 (1 = PERST# asserted), INIT (bridge reset) bit 1 (1 = in reset) | ML:brcmstb.c:195-198, 1907 |

Downstream additionally names HARD_DEBUG PERST_ASSERT bit 3, REFCLK_OVRD_ENABLE
bit 16 and REFCLK_OVRD_OUT bit 20 (RPI:brcmstb.c:166-178), and a statistics and
LTSSM-history block at 0x1940-0x1d2c (RPI:brcmstb.c:67-94).

The error-report block at 0x6000-0x6020 (ML:brcmstb.c:163-193) is used only on
SoCs whose configuration sets error reporting; BCM2711's does not
(ML:brcmstb.c:1947-1953, 2004). Whether BCM2711 implements it is **unknown**.

## 1. Bring-up

Linux's order on BCM2711 (probe, ML:brcmstb.c:2045-2196, then the setup and
link-start steps):

1. Optional clock `sw_pcie` is enabled; the Pi 4 tree names none
   (ML:brcmstb.c:2072, 2104). Optional resets `rescal`, `perst`, `bridge`,
   `swinit` are looked up; the Pi 4 tree gives none, and BCM2711 has no PHY
   block handled by the driver (ML:brcmstb.c:2084-2099, 1947-1953). So on the
   Pi 4 all resets go through register 0x9210.
2. Probe first clears the bridge reset bit (bit 1 of 0x9210)
   (ML:brcmstb.c:2108, 816-840). The swinit pulse with its 1 us hold applies
   only when a `swinit` reset exists (ML:brcmstb.c:2111-2124); not on the Pi 4.
3. Setup (ML:brcmstb.c:1131-1316):
   a. Assert the bridge reset (bit 1 of 0x9210 = 1) (ML:brcmstb.c:1143).
   b. BCM2711 only: assert PERST# (bit 0 of 0x9210 = 1), because a
      bootloader may have left it deasserted (ML:brcmstb.c:1147-1154).
   c. Wait 100-200 us (ML:brcmstb.c:1156).
   d. Release the bridge reset (bit 1 = 0) (ML:brcmstb.c:1159).
   e. Clear SERDES_IDDQ (bit 27 of 0x4204), read-modify-write, then wait
      100-200 us for the SerDes to settle (ML:brcmstb.c:1163-1170).
   f. MISC_CTRL (0x4008), read-modify-write: SCB_ACCESS_EN = 1,
      CFG_READ_UR_MODE = 1, MAX_BURST_SIZE = 0 (128 bytes on BCM2711; the
      encoding is 0=128, 1=256, 2=512), RCB_MPS_MODE = 1, RCB_64B_MODE = 1
      (ML:brcmstb.c:1172-1196). BCM2711 is singled out for the 128-byte burst
      (ML:brcmstb.c:1179-1180); the source gives no reason.
   g. Program inbound windows (section 2) (ML:brcmstb.c:1198-1202).
   h. Check MISC_PCIE_STATUS bit 7; if clear the block is in endpoint mode and
      bring-up fails (ML:brcmstb.c:1204-1207, 757-763).
   i. Write SCB0_SIZE into MISC_CTRL (section 2) (ML:brcmstb.c:1209-1220).
   j. Choose the MSI target address (section 4) (ML:brcmstb.c:1222-1233).
   k. LINK_CAPABILITY 0x4dc is rewritten (L0s cleared only with
      `aspm-no-l0s`; lane count changed only with `num-lanes`, which then
      also sets P2_POWERDOWN_ENA_NOSYNC) (ML:brcmstb.c:1236-1261). Neither
      property is on the Pi 4, so on the Pi this is a rewrite of the same
      value.
   l. Class code in 0x43c bits 23:0 set to 0x060400 (PCI-to-PCI bridge),
      because the block resets presenting an endpoint class
      (ML:brcmstb.c:1263-1270).
   m. Outbound windows from `ranges` (section 2) (ML:brcmstb.c:1272-1301).
   n. ENDIAN_MODE_BAR2 in 0x188 set to little endian (ML:brcmstb.c:1303-1307).
4. Read MISC_REVISION (0x406c) (ML:brcmstb.c:2145).
5. Set up the MSI decoder (section 4), before the bus is scanned
   (ML:brcmstb.c:2152-2163).
6. Scan the bus (ML:brcmstb.c:2173). The link is started only when the PCI
   core adds bus 1 below the root port, from the bus-add hook
   (ML:brcmstb.c:1474-1511): first optional downstream supplies `vpcie3v3`,
   `vpcie3v3aux`, `vpcie12v` are enabled if the root port child node names
   them (ML:brcmstb.c:1451-1455, 1484-1506; the Pi 4 tree names none), then
   link start:
   a. If a generation limit is set, write it into LINK_CAPABILITY speed bits
      and the root port's LNKCTL2 target speed (ML:brcmstb.c:1407-1409,
      475-485). The Pi 4 sets none, so no limit; Linux only accepts limits 1-3
      (ML:brcmstb.c:2076-2080).
   b. Deassert PERST# (bit 0 of 0x9210 = 0) (ML:brcmstb.c:1412, 884-893).
   c. Sleep 100 ms, the PCIe-specified wait before the first configuration
      request after reset (ML:brcmstb.c:1416; ML:drivers/pci/pci.h:56-62).
   d. Poll for link-up (MISC_PCIE_STATUS bits 4 and 5 both set) every 5 ms
      for up to a further 100 ms (ML:brcmstb.c:1423-1424, 765-772). If still
      down, fail with "link down" (ML:brcmstb.c:1426-1429). Worst case is
      about 200 ms from PERST# release.
   e. Configure CLKREQ#/L1SS (below) (ML:brcmstb.c:1431).
   f. If `brcm,enable-ssc`: enable spread-spectrum clocking through MDIO
      (below) (ML:brcmstb.c:1433-1439). This is done after link-up.
   g. Read LNKSTA for the negotiated speed and width (ML:brcmstb.c:1441-1446).
7. After the scan, if the link is not up, the whole host bridge is removed
   and probe fails (ML:brcmstb.c:2174-2178).

Link-up test: link is up only when both PHYLINKUP (bit 4) and DL_ACTIVE
(bit 5) of 0x4068 are set (ML:brcmstb.c:765-772). FreeBSD uses the same two
bits (mask 0x30) (FB:fb-pci.c:674-676).

**SSC through MDIO** (ML:brcmstb.c:390-472): the MDIO address register
(0x1100) takes a packet with port in bits 19:16 (plus an extension bit 21 for
ports above 15), register address bits 15:0, and command bit 20 (1 = read,
0 = write) (ML:brcmstb.c:216-223, 390-401). A read posts the packet, reads the
address register back, then polls RD_DATA (0x1108) until bit 31 is set, every
10 us for up to 100 us; data is bits 30:0 (ML:brcmstb.c:403-417). A write
posts the packet, reads it back, writes data with bit 31 set to WR_DATA
(0x1104), and polls until bit 31 clears, same timing (ML:brcmstb.c:419-437).
SSC sequence: on port 0, write 0x1100 to register 0x1f (selects the SSC
register bank), read register 0x2, set bits 15 (override enable) and 14
(override value), write it back, wait 1-2 ms, read register 0x1 and require
bit 10 (SSC active) and bit 11 (PLL locked) (ML:brcmstb.c:439-472, 225-234).
Failure is reported but not fatal (ML:brcmstb.c:1433-1439).

**CLKREQ#, L1SS, ASPM** (ML:brcmstb.c:1337-1397). Selected by the
`brcm,clkreq-mode` property; absent on the Pi 4, so Linux uses "default"
(ML:brcmstb.c:1340-1348). In all modes it first clears CLKREQ_DEBUG_ENABLE
(bit 1) and L1SS_ENABLE (bit 21) of HARD_DEBUG, then:
* "default": sets L1SS_ENABLE and lengthens the internal-bus (RBUS) access
  timeout to 4 s by writing 216 x 4,000,000 = 864,000,000 to 0x9208, because
  that timeout can fire during L1 substate sleep even without PCIe traffic
  (ML:brcmstb.c:1373-1383, 1323-1335). This mode supports L0s, L1 and L1SS
  but may not meet the PCIe 400 ns clock-restart limit for clock power
  management (ML:brcmstb.c:1374-1381).
* "no-l1ss": sets CLKREQ_DEBUG_ENABLE and sets ROOT_CAP L1SS_MODE to 2 so the
  root port stops advertising L1 substates, because if an L1SS-capable device
  enables L1SS in this mode all traffic may stop and the system can hang
  (ML:brcmstb.c:1354-1372).
* "safe": neither bit; reference clock driven continuously; no power saving
  (ML:brcmstb.c:1385-1393).
ASPM policy itself is left to the PCI core; the driver only gates L0s
advertising with `aspm-no-l0s` (ML:brcmstb.c:1236-1240).

**Clocks.** No clock is named for the Pi 4 bridge; the reference clock is
generated internally (the SSC step locks its PLL). Which clock feeds it and
whether firmware must enable it is **unknown** from these sources.

## 2. Outbound and inbound windows

**Outbound** (ML:brcmstb.c:1272-1301, 487-529). Each memory range in `ranges`
becomes one window, at most 4 (ML:brcmstb.c:203, 1279-1282). For window w:
WINw_LO/HI = PCI start address; BASE_LIMIT bits 15:4 = low 12 bits of the CPU
start in MiB, bits 31:20 = low 12 bits of the CPU end (start + size - 1) in
MiB; BASE_HI and LIMIT_HI = the MiB values shifted right by 12, in 8-bit
fields (ML:brcmstb.c:487-529). So CPU addresses are MiB-granular and window
ends are inclusive. Worked values (**inference**, arithmetic): mainline Pi 4
tree gives WIN0_LO 0xf8000000, WIN0_HI 0, BASE_LIMIT 0x00300000, BASE_HI 6,
LIMIT_HI 6; the downstream tree gives WIN0_LO 0xc0000000, BASE_LIMIT
0x3ff00000, BASE_HI 6, LIMIT_HI 6. I/O ranges are skipped
(ML:brcmstb.c:1276-1277).

**Inbound** (ML:brcmstb.c:937-1073, 1091-1129). Registers use BAR numbers
1..3 on BCM2711 (3 windows) (ML:brcmstb.c:1951):
* BAR1 (0x402c): size 0, i.e. disabled. On older STB chips BAR1 maps the
  SoC's internal registers rather than memory; the source calls this
  deprecated and a security concern (ML:brcmstb.c:955-961).
* BAR2 (0x4034/0x4038): the one real inbound window. Its CPU side is fixed at
  the start of system memory (CPU 0); the PCI side is the lowest PCI address
  in `dma-ranges` (ML:brcmstb.c:1016-1021). Size: sum of the memory
  controller sizes (`brcm,scb-sizes`, or, if absent as on the Pi 4, the total
  `dma-ranges` size rounded up to a power of two), rounded up again to a power
  of two (ML:brcmstb.c:999-1014). Rules enforced: size must be a power of
  two, the PCI offset must be a multiple of the size, and the offset may not
  lie strictly between 2 GiB and 4 GiB (ML:brcmstb.c:1056-1061). Parts of the
  window that are not memory may overlap outbound space; the bridge sends
  outbound addresses downstream and everything else upstream
  (ML:brcmstb.c:1033-1042).
* BAR3 (0x403c): size 0, disabled; on some chips it repeats BAR2 with
  selectable endianness (ML:brcmstb.c:1066-1070).
* Size encoding in bits 4:0 of BARn_CONFIG_LO: for 4 KiB-32 KiB,
  log2(size) - 12 + 0x1c; for 64 KiB-64 GiB, log2(size) - 15; anything else
  writes 0, which disables (ML:brcmstb.c:376-388). The low bits of the PCI
  address share the register (ML:brcmstb.c:1105-1111).
* SCB0_SIZE in MISC_CTRL bits 31:27 = log2(memory-controller size) - 15
  (ML:brcmstb.c:1209-1220).
* Pi 4 values (**inference**, arithmetic): `dma-ranges` 3 GiB gives a 4 GiB
  window at PCI 0: BAR2_CONFIG_LO = 0x11, BAR2_CONFIG_HI = 0, SCB0_SIZE = 17.

**The DMA limit.** The device tree restricts inbound DMA to the low 3 GiB
because the wrapper around the PCIe block cannot reach beyond it
(ML:bcm2711.dtsi:577-583). The driver adds that on early BCM2711 revisions
the firmware edits `dma-ranges` at boot because of this integration bug
(ML:brcmstb.c:1023-1029). Whether later silicon steppings lift the limit,
and what the firmware writes on them, is **unknown** from these sources.
FreeBSD restricts DMA much further, to below 960 MiB (0x3c000000), stating
that it saw data corruption above that with its driver and that the true
limit is unclear to its author (FB:fb-pci.c:92-106, 629-639).

## 3. Configuration space access

* Bus 0 is the root port only. Device 0 function 0 on bus 0 is the root
  port's own registers at block offset 0 (offset = register number); any
  other devfn on bus 0 returns nothing (ML:brcmstb.c:781-783). FreeBSD gives
  the reason: probing other slots or functions on bus 0 locks up the memory
  controller (FB:fb-pci.c:300-307).
* Other buses: write the target's bus/device/function into EXT_CFG_INDEX
  (0x9000) in standard ECAM layout (bus in bits 27:20, device bits 19:15,
  function bits 14:12, register bits zero), then access EXT_CFG_DATA
  (0x8000) + register offset (ML:brcmstb.c:789-792). One device is visible at
  a time, so index-then-access must be one locked step (FreeBSD holds a mutex,
  FB:fb-pci.c:324-332). Byte, word and dword accesses are used on BCM2711
  (generic accessors, ML:brcmstb.c:2029-2034); the 32-bit-only variant is for
  another SoC (ML:brcmstb.c:2037-2042).
* Linux refuses any non-root config access while the link is down, because an
  access without link-up causes a CPU abort (ML:brcmstb.c:785-787). FreeBSD
  checks the link only once at attach (FB:fb-pci.c:689-694).
* CFG_READ_UR_MODE (MISC_CTRL bit 13) is set by both drivers
  (ML:brcmstb.c:1192; FB:fb-pci.c:110-112, value 0x3000 includes bit 13).
  **Inference** from the name: a config read that completes with
  Unsupported Request returns data (all ones) instead of an error. No source
  explains it.
* Which device numbers respond on bus 1: the Pi 4 tree describes only
  device 0 function 0 (ML:rpi-4-b.dts:232-245). The driver itself does not
  restrict device numbers on bus 1; behavior of accesses to device 1..31 on
  bus 1 is **unknown** (board probe).
* No handling of Configuration Request Retry Status in the mainline driver.
  Downstream re-enables CRS Software Visibility in the root port's Root
  Control after link-up, because PERST# resets Root Control and undoes the
  PCI core's earlier enable (RPI:brcmstb.c:1856-1864).

## 4. Interrupts

**Which GIC lines.** SPI 147 (`pcie`), SPI 148 (`msi`), INTA..INTD on SPI
143..146 (ML:bcm2711.dtsi:560-571). Linux maps only interrupt index 1 (the
MSI line, SPI 148) for the bridge (ML:brcmstb.c:710); it never maps SPI 147
on BCM2711 (the only parse is ML:brcmstb.c:710). FreeBSD also takes resource
1 for MSI (FB:fb-pci.c:510-511). What raises SPI 147 is **unknown**.

**INTx is separate from the bridge's interrupts.** INTx pins map straight to
their own GIC SPIs through `interrupt-map` (ML:bcm2711.dtsi:563-571); they do
not pass through the MSI decoder or SPI 147/148 according to the device tree.
Linux has no INTx code in this driver: no INTx status, mask or acknowledge
register is used (no such access in ML:brcmstb.c). INTx masking is therefore
only at the device (the standard Command register INTx-disable bit) and at
the GIC. Whether the bridge has an INTx status/mask register of its own is
**unknown**. Probe B2 should confirm on the board that a VL805 INTA arrives
on SPI 143 and not on 147/148.

**MSI decoder.**
* Number of vectors and layout depend on MISC_REVISION: below 0x0303 is the
  legacy layout, 8 vectors in bits 31:24 of the INTR2_CPU block at 0x4300;
  0x0303 and above, 32 vectors in bits 31:0 of the MSI_INTR2 block at 0x4500
  (ML:brcmstb.c:726, 734-741, 203-209). BCM2711's revision value is
  **unknown** from these sources; FreeBSD assumes the 32-vector block at
  0x4500 unconditionally and prints the revision (FB:fb-pci.c:80-84, 655-657).
  A board read of 0x406c settles it.
* Target address: Linux uses 0x0_fffffffc if the inbound window lies wholly
  above 4 GiB or ends below 4 GiB, else 0xf_fffffffc; the aim is a 32-bit
  target for devices that need it (ML:brcmstb.c:1222-1233, 212-213). With the
  Pi 4's 4 GiB window at PCI 0 the window ends exactly at 4 GiB, so the
  target is 0xf_fffffffc (**inference**, arithmetic). FreeBSD hard-codes
  0xf_fffffffc (FB:fb-pci.c:505). So the VL805 must support 64-bit MSI
  addresses (**inference**).
* Setup (ML:brcmstb.c:683-702): unmask all vectors (write the vector mask to
  MASK_CLR), clear all pending (write it to CLR), write the target low word
  with bit 0 set (bit 0 is reused as MSI enable) to 0x4044, the high word to
  0x4048, then 0xffe06540 (32-vector) or 0xfff86540 (8-vector) to 0x404c.
* Message data a device sends: 0x6540 OR the vector number
  (ML:brcmstb.c:572-579; FreeBSD same, FB:fb-pci.c:472). **Inference**: the
  top 16 bits of MSI_DATA_CONFIG are a match mask over the data, leaving the
  low 5 (or 3) bits as the vector.
* Linux supports multi-message MSI with power-of-two aligned blocks
  (ML:brcmstb.c:534-536, 596-606). Whether MSI-X is offered depends on
  generic-layer flags I did not read; **unknown**.
* Handling: on SPI 148, read STATUS (0x4500), shift down by the layout shift,
  dispatch each set bit (ML:brcmstb.c:547-570). Acknowledge one vector by
  writing its bit to CLR (0x4508) (ML:brcmstb.c:581-587). Linux writes no
  end-of-interrupt register. Linux never writes MASK_SET (0x4510); per-vector
  masking is left to the device's MSI capability.
* FreeBSD loops while STATUS is non-zero; per vector it writes CLR, then
  writes 1 to 0x4060 (named MSI EOI), then dispatches (FB:fb-pci.c:376-418).
  The meaning and need of 0x4060 are **unknown**; Linux runs the Pi 4 without
  it.
* Teardown: Linux only unhooks its handler and frees its domains; it writes
  no bridge MSI register (ML:brcmstb.c:673-681). The bridge reset in turn-off
  follows (section 6).

## 5. The VL805

**Firmware-load notify.**
* Mailbox property tag 0x00030058 (ML:include/soc/bcm2835/raspberrypi-firmware.h:93;
  FreeBSD same, FB:bcm2835_mbox_prop.h:110). Request value: one 32-bit word,
  the device address encoded bus << 20 | device << 15 | function << 12. For
  the Pi 4's VL805 at 1:0.0 that is 0x00100000 (ML:rpi-reset.c:41-51;
  FB:fb-xhci.c:70-72, 160-163). Response body is empty (FB:bcm2835_mbox_prop.h:112-123).
* Purpose: after a PCI reset the VL805 loads its firmware either from an
  attached EEPROM or, when no EEPROM is fitted, from the VideoCore, whose
  firmware holds both the loading logic and the VL805 image; the tag starts
  that load (ML:rpi-reset.c:33-41).
* Delay after the call: Linux waits 200-1000 us for the VL805 to start
  (ML:rpi-reset.c:58); FreeBSD waits 1 ms and re-reads 0x50
  (FB:fb-xhci.c:171-172).
* When: Linux sends it from the xHCI PCI probe, before any xHCI register
  access, unconditionally, through the `resets` property of the `usb@0,0`
  node (ML:xhci-pci.c:618-623, 642; ML:rpi-4-b.dts:240-243). So it is sent
  after PERST# release, link-up and bus enumeration (the device must already
  be enumerated for its driver to probe). It is sent again on every xHCI
  resume (ML:xhci-pci.c:864). FreeBSD likewise sends it in the xHCI attach,
  after enumeration, noting that the bridge topology must be registered with
  the controller first (FB:fb-xhci.c:154-158, 179-186).
* Linux also skips the generic USB BIOS-handoff early quirk for the VL805
  under a `brcm,bcm2711-pcie` parent, because the co-processor takes care of
  the controller (ML:pci-quirks.c:1272-1282).
* If it is not sent: on a board without the EEPROM the VL805 has no firmware
  (ML:rpi-reset.c:33-41). The observable symptom (xHCI registers absent,
  all ones, or controller not halting) is **unknown** (board probe).

**Telling whether firmware is loaded.** Config-space dword at 0x50 of the
VL805 holds its firmware version. Downstream Linux reads it (a failed read
counts as version 0) only to choose a quirk (RPI:xhci-pci.c:253-261, 467).
FreeBSD treats 0 or 0xffffffff as "not loaded" (FB:fb-xhci.c:119-120) and
skips the notify when firmware is already present, stating that with boot
firmware older than June 2020 already-installed VL805 firmware cannot be
reloaded (FB:fb-xhci.c:141-149). Linux does not check and always notifies.

**VL805 quirks** (PCI vendor 0x1106, device 0x3483,
ML:xhci-pci.c:42; FB:fb-xhci.c:85).
* Mainline: USB2 LPM support enabled, ring-segment overfetch workaround, DMA
  mask 36 bits (ML:xhci-pci.c:449-453). Reset-on-resume for all VIA hosts
  (ML:xhci-pci.c:437-438).
* Overfetch: the controller prefetches past the end of a ring segment, so each
  segment is allocated at twice the size with the spare half as padding
  (ML:xhci-mem.c:2442-2447).
* Downstream instead uses a 40-bit DMA mask and adds four quirks
  (RPI:xhci-pci.c:460-469):
  - Broken DCS write-back: the dequeue-cycle-state bit the controller writes
    back in the endpoint context is wrong; take the cycle bit from the TRB the
    hardware dequeue pointer points at (RPI:xhci-ring.c:734-741).
  - Dequeue on a link TRB: the controller misparses a link TRB when the
    dequeue pointer is set onto one; when moving the dequeue pointer, step past
    a link TRB (toggling the cycle if the link toggles it) (RPI:xhci-ring.c:782-790).
  - SuperSpeed bulk-out bug: for bulk-out endpoints of mass-storage devices
    behind a hub (non-zero route string), max burst is forced to 0
    (RPI:xhci-mem.c:1494-1499).
  - Internal-hub TT babble (only when the firmware version at 0x50 is below
    0x0138C0): queuing a TD to an idle ring of a full-speed device directly on
    the root hub's internal TT late in microframe 7 can cause downstream port
    babble; before ringing the doorbell for such a single TD, wait (10 us
    steps, up to 200 us) until MFINDEX low 3 bits are non-zero
    (RPI:xhci-pci.c:30, 467-468; RPI:xhci-ring.c:3715-3753, 3911-3912, 4061-4062).
* Neither tree applies a 32-bit DMA mask; the 3 GiB bus limit comes from
  `dma-ranges` through the DMA layer (**inference**). FreeBSD sets the xHCI
  to 32-bit DMA, calling it a PCIe-controller limit, not a VL805 one
  (FB:fb-xhci.c:190-192), on top of the 960 MiB bus limit.
* Interrupts: the xHCI driver tries MSI-X, then MSI, then INTx
  (ML:xhci-pci.c:143-205).

## 6. Suspend, resume, removal: what this says about restart

* Turn-off (ML:brcmstb.c:1600-1627): if the link is up, request L23
  (MISC_PCIE_CTRL bit 0 = 1) and poll LINK_IN_L23 (0x4068 bit 6) up to 15
  times at 2-2.4 ms (about 36 ms), logging on timeout (ML:brcmstb.c:1529-1552);
  assert PERST#; clear the L23 request; set SERDES_IDDQ (bit 27 of 0x4204);
  assert the bridge reset (bit 1 of 0x9210). The "avoid bridge shutdown"
  exception is for SoCs whose shared RESCAL block would become unreachable
  (ML:brcmstb.c:280-287); BCM2711 does not set it (ML:brcmstb.c:1947-1953),
  so its bridge is put in reset.
* Resume (ML:brcmstb.c:1691-1767): release the bridge reset, clear
  SERDES_IDDQ, wait 100 us, rerun the whole setup (which resets the bridge and
  asserts PERST# again on BCM2711), re-enable supplies, rerun link start, and
  rewrite the MSI registers (ML:brcmstb.c:1711-1752). **Inference**: bridge
  reset clears the window, MISC_CTRL and MSI registers, since all are
  rewritten.
* PERST# resets the VL805 and with it its firmware load; the notify must
  follow each PERST# cycle (ML:rpi-reset.c:33-41; ML:xhci-pci.c:864). PERST#
  also resets the root port's Root Control (RPI:brcmstb.c:1856-1859).
* Re-running bring-up with the link already up is the normal case: setup
  always starts by putting the bridge in reset and, on BCM2711, asserting
  PERST#, precisely because the boot firmware may leave PERST# released
  (ML:brcmstb.c:1142-1156). No source records a problem with doing so.
  Whether a reset with DMA still in flight from a previous instance is safe is
  **unknown**; turn-off's L23 handshake is the clean shutdown.
* Removal is turn-off plus freeing (ML:brcmstb.c:1881-1903).

## 7. Errata and workarounds, with reasons

| Item | What | Reason given | Cite |
|---|---|---|---|
| 3 GiB inbound limit | dma-ranges 3 GiB | wrapper around the block cannot reach above 3 GiB; firmware edits dma-ranges on early revisions | ML:bcm2711.dtsi:577-583; ML:brcmstb.c:1023-1029 |
| FreeBSD 960 MiB limit | DMA below 0x3c000000 | corruption seen above it with FreeBSD's driver; true limit unclear | FB:fb-pci.c:92-106 |
| PERST# re-assert | assert PERST# at the start of setup | bootloaders may release it | ML:brcmstb.c:1147-1154 |
| SerDes settle | 100-200 us after clearing IDDQ | SerDes stability | ML:brcmstb.c:1163-1170 |
| 128-byte burst | MAX_BURST_SIZE 0 on BCM2711 | none given | ML:brcmstb.c:1172-1184 |
| RCB modes | RCB_MPS_MODE and RCB_64B_MODE set | none given | ML:brcmstb.c:1186-1196 |
| SSC | enabled via MDIO after link-up when brcm,enable-ssc | (spread spectrum; no further reason) | ML:brcmstb.c:439-472, 1433-1439 |
| RBUS timeout | 4 s at 0x9208 in "default" clkreq mode | internal-bus timeouts can fire during L1SS sleep | ML:brcmstb.c:1317-1335 |
| no-l1ss | un-advertise L1SS | L1SS in this mode can halt all traffic and hang | ML:brcmstb.c:1354-1372 |
| Config access without link | refused | causes a CPU abort | ML:brcmstb.c:785-787 |
| Bus 0 devices other than 0.0 | refused | locks up the memory controller | FB:fb-pci.c:300-307; ML:brcmstb.c:781-783 |
| BAR1 disabled | inbound BAR1 size 0 | maps SoC registers; deprecated; security | ML:brcmstb.c:955-961 |
| Class code | set to PCI bridge | resets as endpoint class | ML:brcmstb.c:1263-1270 |
| 100 ms wait | after PERST# release | PCIe-mandated wait before first config request | ML:brcmstb.c:1416; ML:pci.h:56-62 |
| VL805 overfetch, DCS, link-TRB dequeue, bulk-out burst, TT babble | see section 5 | hardware bugs as stated there | section 5 |

Config reads to absent devices on bus 1: no timeout handling in either
driver; with CFG_READ_UR_MODE set an Unsupported Request is expected to read
as all ones (**inference**). Whether a read to an absent device number on bus 1
raises an SError on BCM2711 is **unknown** (board probe).

## 8. Differences from FreeBSD

| # | Linux | FreeBSD | Matters for a working Pi 4? |
|---|---|---|---|
| 1 | Setup asserts bridge reset, asserts PERST# separately, 100-200 us, releases bridge reset, clears only SERDES_IDDQ in HARD_DEBUG (ML:brcmstb.c:1142-1170) | Sets both bits of 0x9210 together, 100 us, clears bridge reset, 100 us, writes 0 to the whole HARD_DEBUG, 100 us (FB:fb-pci.c:179-199) | Equivalent in effect for the Pi 4; FreeBSD also clears CLKREQ/L1SS bits. Low. |
| 2 | 100 ms fixed wait after PERST# release, then poll every 5 ms up to 100 ms more (ML:brcmstb.c:1412-1429) | Poll 0x4068 for bits 0x30 every 1 ms, about 101 tries, no fixed wait (FB:fb-pci.c:670-687) | Linux follows the PCIe 100 ms rule before the first config read. FreeBSD may read config sooner after link-up. Medium: follow Linux's timing. |
| 3 | MISC_CTRL read-modify-write: SCB_ACCESS_EN, CFG_READ_UR_MODE, burst 128, RCB_MPS_MODE, RCB_64B_MODE (ML:brcmstb.c:1186-1196) | Whole-register write of SCB0_SIZE 18 + SCB_ACCESS_EN + CFG_READ_UR_MODE; RCB bits end up 0, burst 0 (FB:fb-pci.c:106-112, 663-665) | RCB setting differs; FreeBSD works without it, effect unknown. Low-medium; Linux's value is the vendor's. |
| 4 | Inbound window sized from dma-ranges: 4 GiB, SCB0_SIZE 17 (ML:brcmstb.c:999-1014, 1209-1220) | Fixed 8 GiB (encoding 0x12) in BAR2 and SCB0_SIZE (FB:fb-pci.c:107-112, 663-665) | Both cover all memory DMA may target, and both end below the MSI target 0xf_fffffffc. Low. |
| 5 | DMA allowed below 3 GiB (dma-ranges) | Below 960 MiB (FB:fb-pci.c:92-106, 629-639) | Yes for buffer placement: 960 MiB is the conservative proven value on FreeBSD; 3 GiB is Linux's. Settle by board test. |
| 6 | MSI handling: clear per vector, no EOI (ML:brcmstb.c:547-587) | Clear per vector and write 1 to 0x4060 each time, loop until status 0 (FB:fb-pci.c:376-418) | Unknown; both work. Medium: probe whether SPI 148 deasserts without the 0x4060 write. |
| 7 | MSI layout chosen by MISC_REVISION (ML:brcmstb.c:726, 734-741) | Always 32 vectors at 0x4500 (FB:fb-pci.c:80-84) | Only if BCM2711's revision is below 0x0303; FreeBSD working suggests not. Read 0x406c. |
| 8 | CLKREQ "default" mode: L1SS_ENABLE set, RBUS timeout 4 s, CLKREQ_DEBUG_ENABLE clear (ML:brcmstb.c:1373-1383) | CLKREQ_DEBUG_ENABLE set, L1SS_ENABLE only with brcm,enable-l1ss; no RBUS timeout change; ROOT_CAP not touched (FB:fb-pci.c:725-737) | FreeBSD's setting is Linux's "no-l1ss" without un-advertising L1SS. Matters only if ASPM L1SS is enabled. Low for a first driver that leaves ASPM off. |
| 9 | SSC enabled through MDIO after link-up (ML:brcmstb.c:1433-1439) | No SSC (no MDIO code in fb-pci.c) | Link works without it; SSC is an EMI measure. Low. |
| 10 | Link-up tested in 0x4068 before each non-root config access (ML:brcmstb.c:785-787) | Tested once at attach (FB:fb-pci.c:689-694) | Yes for robustness: an access with the link down aborts the CPU. |
| 11 | Outbound windows from all ranges (up to 4) (ML:brcmstb.c:1272-1301) | First range only (FB:fb-pci.c:213-245, 704-716) | No on the Pi 4 (one range). |
| 12 | Root port bridge windows assigned by the PCI core | Driver rewrites the root port's memory base/limit to start at the outbound PCI base (FB:fb-pci.c:559-580) | Implementation detail of each OS's resource code; erXos must program the root port's windows itself either way. |
| 13 | ENDIAN_MODE_BAR2 set little endian (ML:brcmstb.c:1303-1307) | Not written | Reset default presumably little endian since FreeBSD works (**inference**). Low. |
| 14 | Class code: read-modify-write of bits 23:0 (ML:brcmstb.c:1263-1270) | Whole-register write of 0x060400 (FB:fb-pci.c:722-723) | Low. |
| 15 | MSI target chosen from window geometry (ML:brcmstb.c:1222-1233) | Fixed 0xf_fffffffc (FB:fb-pci.c:505) | Same value on the Pi 4. None. |
| 16 | VL805 notify always sent, via reset controller, also on resume (ML:xhci-pci.c:618-623, 864) | Sent only if 0x50 reads 0 or all ones; old boot firmware cannot reload (FB:fb-xhci.c:119-149) | Yes after a restart without PERST#: FreeBSD's check avoids a reload that old firmware can't do. After a PERST# cycle firmware is gone and must be reloaded. |
| 17 | VL805 quirks: overfetch padding, LPM, (downstream) DCS, link-TRB dequeue, bulk-out burst, TT babble (section 5) | None beyond 32-bit DMA (FB:fb-xhci.c:179-193; xhci_pci.c has no VL805 entry) | Yes for the xHCI driver: overfetch padding and the link-TRB dequeue rule can corrupt or hang transfers if ignored. Downstream quirks reflect field experience. |
| 18 | Teardown: L23 handshake, PERST#, SerDes off, bridge reset (ML:brcmstb.c:1600-1627) | No detach path in fb-pci.c | Yes for safe restart of the bridge domain. |
| 19 | Downstream: CLKREQ bits cleared before PERST# release; optional extra PERST# hold (brcm,tperst-clk-ms, not on the Pi 4) using HARD_DEBUG PERST_ASSERT bit 3 to give the refclk PLL more time; "safe" mode also forces refclk output and un-advertises L1SS; CRS visibility re-enabled after PERST# (RPI:brcmstb.c:1787-1811, 1622-1638, 1856-1864) | None | Low for the Pi 4 as configured. |

## Unknowns that only a board probe can settle

1. MISC_REVISION (0x406c) on BCM2711: selects the MSI register layout.
2. Whether SPI 148 deasserts after a CLR write alone, or needs FreeBSD's 0x4060
   write; what 0x4060 is.
3. What raises SPI 147 (`pcie`).
4. That VL805 INTA arrives on SPI 143 only, separate from 147/148 (probe B2).
5. The true inbound DMA ceiling on the board in hand (960 MiB proven by
   FreeBSD; 3 GiB per Linux), and whether the boot firmware rewrote
   `dma-ranges` in the device tree it hands over.
6. Config accesses to bus 1 devices 1..31 and to absent functions: all ones,
   or SError.
7. The VL805's state when erXos starts: EEPROM fitted or not, value at 0x50
   before and after the notify, the symptom of a missing notify, and whether
   this board's boot firmware can reload firmware already present.
8. Whether the boot firmware leaves the link up and PERST# released at
   handover (Linux assumes it may).
9. What the reference clock source is and whether anything must enable it.
10. MSI-X support through this decoder.
