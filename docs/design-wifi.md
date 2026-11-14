# WiFi

The Raspberry Pi 4's WiFi chip, a Cypress CYW43455, joins open, WPA2-PSK
and WPA3-SAE networks as a station, and the network stack carries
`wlan0` over it as it carries `genet0` over the board's Ethernet. The
chip is a FullMAC chip on the SoC's legacy SD controller: its firmware
runs the 802.11 MAC, and the host loads that firmware, speaks the chip's
control protocol, runs the key handshakes and moves Ethernet frames. To
its users the system behaves as FreeBSD does: `ifconfig wlan0 scan`,
`wpa_supplicant.conf` and DHCP on `wlan0`.

Decisions every reader needs:

* **WiFi is a domain that turns an SDIO card into an Ethernet medium.**
  The **WiFi domain**, `wifi`, holds the whole WiFi conversation: the
  chip, its firmware, scanning, joining, the supplicant and its keys.
  It reaches the card through a facet of the storage domain, which holds
  the legacy controller, and it lends the network domain one thing, an
  Ethernet medium with a link state. Everything below follows from that
  placement.
* **The storage domain drives the legacy controller and serves its
  card.** The controller shares its interrupt line with EMMC2, so by the
  unit rule it stays in the storage domain's unit
  ([design-shared-devices.md](design-shared-devices.md#the-unit-rule)).
  A small SDIO host there brings the card up on each attach and runs
  lists of SDIO transactions for one client through the `sdio`
  interface; it understands nothing about the chip.
* **The legacy controller never raises the shared line.** The SDIO host
  holds the controller's signal enables at zero and polls it, the card
  interrupt included, so line 126 stays EMMC2's alone: no WiFi transfer
  delays a round of storage's line, and an SDIO host that ends leaves
  nothing asserted on it.
* **The WiFi domain lends the medium; the network domain runs the
  link.** The WiFi domain offers its medium through the network
  domain's `ether` interface, and the stack runs `wlan0` as a link over
  `erx_net_ether` for as long as the offer lives. The link is up exactly
  while the station's port is open, so the stack never sees an
  unauthenticated network, and the network domain never calls `crypto`.
* **The host runs the handshakes, and installs each key once.** The
  firmware's supplicant is off, as OpenBSD turns it off; the 4-way and
  group handshakes run in Erlang in the WiFi domain, and SAE runs there
  too, through the firmware's external authentication, with its
  secret-dependent arithmetic in three functions added to OTP's
  `crypto`. The station keeps the keys the chip holds, slot by slot, and
  installs only a key that differs from its slot's, so no retransmitted
  or replayed message reinstalls a key or resets its counters.
* **Network secrets live in the vault.** The passphrase-derived keys of
  each network are one blob in a sealed state slot of the vault, the
  mechanism the Bluetooth design proposes for its bonds; the
  configuration file holds no secret. Development builds keep the blob
  in a file of the WiFi domain's own directory, a residual that blocks
  release.
* **The firmware files ship unmodified** in the WiFi application's
  release on the Pi's image, under Cypress's license, fetched at a
  pinned commit.
* **Power and wiring facts held only in GPL sources are unknowns.** The
  design depends on none of them: a card that does not answer is
  reported and the WiFi domain stops, and the board probe settles each.
* **Nothing transmits before a country is configured.** The chip is
  brought up and identified without one, but the WiFi domain sends no
  command that makes it transmit until the configuration or `ctl` names
  the country.

## Contents

1. [Context](#context)
2. [Requirements](#requirements)
3. [What the code does today](#what-the-code-does-today)
4. [The construction](#the-construction)
5. [The SDIO host in the storage domain](#the-sdio-host-in-the-storage-domain)
6. [The `sdio` interface](#the-sdio-interface)
7. [The WiFi domain](#the-wifi-domain)
8. [The chip](#the-chip)
9. [The station](#the-station)
10. [The supplicant](#the-supplicant)
11. [SAE and protected management frames](#sae-and-protected-management-frames)
12. [Configuration, credentials and control](#configuration-credentials-and-control)
13. [The `ether` interface and `wlan0`](#the-ether-interface-and-wlan0)
14. [OTP's `crypto`: SAE's arithmetic](#otps-crypto-saes-arithmetic)
15. [Invariants](#invariants)
16. [Concurrency and ordering](#concurrency-and-ordering)
17. [Failure handling](#failure-handling)
18. [Refusals and error results](#refusals-and-error-results)
19. [Untrusted input](#untrusted-input)
20. [Security](#security)
21. [Facts this design does not have](#facts-this-design-does-not-have)
22. [Performance](#performance)
23. [Verification](#verification)
24. [Interfaces](#interfaces)
25. [Edits to other designs](#edits-to-other-designs)
26. [Alternatives considered](#alternatives-considered)
27. [Open decisions](#open-decisions)
28. [Sources](#sources)

## Context

### What a FullMAC chip leaves to the host

The CYW43455's firmware does the 802.11 work: scanning, authentication,
association, CCMP with installed keys, management-frame protection and
power save. OpenBSD's `bwfm(4)` shows the host's whole job, ISC-licensed,
in `bwfm.c` (3,269 lines) and `if_bwfm_sdio.c` (1,528 lines), and
FreeBSD's copy of `brcmfmac`, also ISC, gives the chip's particulars.
In the order it happens:

1. **SDIO bring-up.** Block sizes 64 for function 1 and 512 for function
   2 (`if_bwfm_sdio.c:282-283`; brcmfmac `bcmsdh.c:44-45, 903-929`, no
   other size for this chip); function 1 on; the chip's identity read
   through the backplane window; the PLL forced off; the cores
   enumerated; the SDIO core kept awake on core revision 12 and later;
   a card reset made to reset the WLAN backplane too
   (`if_bwfm_sdio.c:255-345`). Chip `0x4345` is the 43455 at every
   revision but 9, which is the 43456 (`if_bwfm_sdio.c:377-381`;
   brcmfmac `sdio.c:651-652`). Its RAM starts at `0x198000` (brcmfmac
   `chip.c:713-715`).
2. **Firmware.** The image into the chip's RAM, the NVRAM text,
   converted, at its top, both read back and compared
   (`if_bwfm_sdio.c:499-545`; `bwfm.c:3009` onward for the converter);
   the ARM core started; then the CLM blob, the per-country channel and
   power tables, through the `clmload` variable in chunks (`bwfm.c:269,
   3090-3135`; brcmfmac `common.c:149-208`).
3. **The chip's settings on this part.** Function 2's watermark is
   `0x60` words, with the watermark enable and a message-busy control of
   `0x50` (brcmfmac `sdio.c:54-57, 4322-4334`). No drive-strength table
   covers chip `0x4345`, so nothing is written (brcmfmac `sdio.c:3790-3830`,
   its default case; OpenBSD leaves a `TODO`). Save-and-restore is
   used when the PMU's chip-control register 3 has bit 2 set (brcmfmac
   `chip.c:1426-1442`, `sdio.c:3436-3492`; `if_bwfm_sdio.c:452-461`).
4. **SDPCM framing.** Every frame on function 2 carries a 4-byte
   hardware header, a length and its complement, and an 8-byte software
   header: sequence number, channel (control, event, data, glom), next
   length, data offset, flow control and the highest sequence number the
   firmware accepts (`if_bwfm_sdio.h:151-176`). The window between the
   host's sequence and that maximum is the transmit credit
   (`if_bwfm_sdio.c:1077-1093, 1249`); glom packs several received frames
   into one transfer (`if_bwfm_sdio.c:1294-1410`).
5. **BCDC control.** A request is a 16-byte header, command, length,
   flags with get or set, interface and request id, and status, then a
   payload; named variables are a NUL-terminated name and a value; data
   frames carry a 4-byte BCDC header (`bwfmreg.h:314-342`).
6. **Events.** Ethernet frames of ethertype `0x886c` with Broadcom's OUI
   carry an event message in big-endian fields: type, status, reason,
   auth type, data length, address (`bwfmreg.h:764-786`; `bwfm.c:2367-2374`).
   The event numbers below 139 are OpenBSD's (`bwfmreg.h:659-731`); the
   Cypress firmware numbers its external-authentication and
   management-transmit events 187 to 190 (brcmfmac `cyw/core.c:17-21`),
   which need the extended event mask (`cyw/core.c:79-99`).
7. **Data.** Everything else is an Ethernet frame; ethertype `0x888e`
   is EAPOL, for the handshake (`bwfm.c:2375-2407`).
8. **Keys.** The host joins with `wpa_auth`, `wsec`, `auth`, `mfp` and
   its RSN element in `wpaie` (`bwfm.c:1985-2060`) and installs keys with
   `wsec_key` (`bwfm.c:2834-2937`). OpenBSD turns the firmware's
   supplicant off: it "can handle the WPA handshake for us, but we
   honestly want to do this ourselves" (`bwfm.c:565-569`).

No 802.11 frame parsing, rate control, software CCMP, MLME or regulatory
database is the host's: the CLM blob holds the rules and the host names
the country.

**What the firmware offers for SAE.** brcmfmac knows two forms. A chip of
Cypress's vendor class does SAE on the host through external
authentication: the firmware raises an event asking for it, the host
sends and receives SAE authentication frames through the `mgmt_frame`
variable and an event, and reports the outcome with `auth_status`
(`cyw/core.c:101-196, 239-325`; `cyw/fwil_types.h:39-84`). A chip of
Broadcom's class does SAE in the firmware from a password
(`wcc/core.c:16-20`). brcmfmac files the 43455 under Broadcom's class
(`bcmsdh.c:994`), so it gives no evidence that this chip's firmware
offers external authentication. Raspberry Pi OS loads brcmfmac with
`feature_disable=0x282000` (`rpi-brcmfmac.conf`), which by brcmfmac's
feature list is bit 13, the firmware supplicant, bit 19, the firmware's
SAE, and bit 21, OBSS dumps (`feature.h:36-62`, applied at
`feature.c:349-353`). The firmware names what it offers in its `cap`
string, `sae_ext` for external SAE (`feature.c:45-47, 228-252`), and the
chip process reads it at bring-up ([The chip](#the-chip)).

### The board

* **The WiFi host is the legacy SD controller** at `0xfe300000`, the
  board tree's `non-removable` SDIO host with `mmc-pwrseq =
  <&wifi_pwrseq>` ([design-platforms.md](design-platforms.md#raspberry-pi-4-model-b)).
  The BCM2711's alternative-function table offers GPIO 34 to 39 one SD
  function, `SD1_*` in ALT3 (*BCM2711 ARM Peripherals*, 5.3, p.77), so
  no other controller reaches the chip's pins. SDHOST, whose line 56 is
  its own (6.2, p.86), appears there only as `SD0_*` on GPIO 22 to 27.
* **It shares interrupt line 126 with EMMC2** (6.2, p.86, source 62,
  "EMMC & EMMC2"), so the two are one unit, `sd`, given whole to the storage
  domain
  ([design-shared-devices.md](design-shared-devices.md#the-unit-rule)).
  The two controllers' registers lie on different pages; only the line
  joins them.
* **It is an SDHCI with quirks and no ADMA.** OpenBSD replaces its
  capabilities with 3.3 V, high speed and a 1,024-byte block, accesses it
  in 32-bit words and never sets the high-speed enable bit
  (`sdhc_fdt.c:252-261`), and with the capabilities replaced finds no
  ADMA2 (`sdhc.c:274-278`). FreeBSD gives it the same quirks, data
  timeout in SD clocks, a broken timeout value, no high-speed bit and
  missing capabilities, and moves data with the SoC's DMA controller on
  DREQ 11 (`bcm2835_sdhci.c:119-142`). FreeBSD's driver serves it and
  EMMC2 with the same accessors, so the 32-bit access and the 6 us
  write spacing that the facts record gives for EMMC2 apply to it
  ([research-sdhci-bcm2711.md](research-sdhci-bcm2711.md), "Register
  access: width and spacing").
* **No DMA from the chip.** An SDIO card cannot write host memory; the
  host reads every byte through the controller's data port. The firmware
  is hostile input, bounded by the host's parsers alone.
* **Power and pins are unknowns:** [Facts this design does not have](#facts-this-design-does-not-have).

### What erXos stands on

* **The unit rule and its homes.** A unit goes whole to one domain; a
  sub-device's function reaches another domain only through a file tree
  its holder serves or a facet of a declared interface, "never the
  registers or the line"
  ([design-shared-devices.md](design-shared-devices.md#the-unit-rule)).
* **One line, one owner.** Drivers on a shared line join its owner,
  `erx_irq_line`, which tells every member of each firing
  ([design-shared-devices.md](design-shared-devices.md#lines-inside-a-domain)).
* **One issuer of controller commands (U4).** `erx_blk_write` is the one
  module that hands a controller anything to do, and a build check
  holds `erx_device:command/2` to it
  ([design-storage.md](design-storage.md#the-sd-host-controller)).
* **The network driver model.** An interface's driver is
  `erx_net_driver` over a transport, in the network domain; credits
  bound every queue; a driver lives a second at the least
  ([design-network-stack.md](design-network-stack.md#the-driver)).
* **No OpenSSL in the network domain.** No module of the stack calls
  `crypto`, which a build check proves
  ([design-crypto.md](design-crypto.md#domains-that-call-no-openssl)).
* **Secrets in the vault.** The vault holds principals' and the
  machine's keys and secrets on a partition of its own, which no
  principals' storage domain reaches
  ([design-system.md](design-system.md#the-vault)).
* **Three homes for a new need.** State someone reads is an inspection
  path at `/proc`; bytes kept or one-shot commands are a file tree with a
  `ctl` file; a live conversation is a declared protocol
  ([design.md](design.md#decisions)).

### What FreeBSD users expect

`ifconfig wlan0 scan` starts a scan when run as root, waits for it, and
lists the results in columns `SSID/MESH ID`, `BSSID`, `CHAN`, `RATE`,
`S:N`, `INT` and `CAPS`, followed by the information elements
(`sbin/ifconfig/ifieee80211.c:4011-4066, 4068-4123`); for any other user
it lists what the last scan found. An SSID with any byte outside `0x20`
to `0x7e` is printed whole as `0x` and hex (`copy_essid`,
`ifieee80211.c:3671-3702`). `ifconfig wlan0 ssid NAME`,
`ifconfig wlan0 country CC` and `ifconfig wlan0 list scan` are commands
of the same file (`:608, 2524, 4924-4933`), and the interface's status
lines are `ieee80211_status` (`:5164`). Keys come from
`wpa_supplicant.conf`, read by wpa_supplicant.

## Requirements

The targets, smallest useful first, each with its consumer:

| # | Target | Consumer |
| --- | --- | --- |
| W0 | **The SDIO card up**: the legacy controller in SDIO mode, the card identified and selected, function 1 on, the chip's identity and revision read; the boot log names `CYW43455 rev N` | every later step; proves power, pins and the shared line |
| W1 | **Firmware running**: firmware, NVRAM and CLM loaded and verified, function 2 ready, `ver`, `cap` and `cur_etheraddr` answered, events on; `wlan0` offered to the network domain, link down | W2 onward; the `/proc` view of the chip |
| W2 | **Scan**: an escan, its results decoded into a BSS list at `/proc`, `ifconfig wlan0 scan` printing FreeBSD's columns | choosing a network; W3 |
| W3 | **An open network**: join by SSID, link up, DHCPv4, ping, UDP and TCP as on GENET | a Pi without a cable; the stack's suites on a second medium |
| W4 | **WPA2-PSK** (AKM 2, and AKM 6 where offered) with CCMP: passphrase to PMK, 4-way and group handshakes on the host, keys installed, group rekeying | most networks |
| W5 | **WPA3-SAE** (AKM 8) with hash-to-element on group 19, then the same 4-way handshake, with management-frame protection | WPA3-only and transition networks |

Beyond the targets: the design keeps the network stack free of WiFi, the
network domain free of `crypto`, the unit rule unchanged, the storage
domain's data and its line safe from anything the WiFi card or its
client does, and the networks' secrets off the data partition.

Out of scope, each a later design with its own consumer: roaming,
host-AP mode, 802.1X and EAP, power-save tuning, SAE's
hunting-and-pecking and other groups, PMKSA caching, Bluetooth on the
same chip, and SoftMAC chips, where net80211's MLME and a regulatory
table come back.

## What the code does today

The legacy controller is held by the storage domain inside the `sd`
unit, which the manifest names `block`. No device-kinds row matches it,
so it has no record, no register window and no driver; EMMC2's SD device
process is the only member of the shared line's owner
([design-storage.md](design-storage.md#the-sd-host-controller);
`config/manifest/raspi4b-development.txt`). The network domain runs
`genet0`; nothing in the tree speaks SDIO, Broadcom's protocols or WPA.
OTP's `crypto` is unchanged and exports no point arithmetic: its NIF
multiplies the generator inside key generation and ECDH only
(`otp/lib/crypto/c_src/ec.c:491, 894`).

## The construction

### WiFi is a domain that makes a medium

```text
 storage domain              WiFi domain (wifi)              network domain
 --------------              ------------------              --------------
 erx_irq_line (line 126)     erx_bwfm          the chip      erx_net_ether
  |- erx_blk_sd  EMMC2       erx_wifi_station  station and   over erx_net_driver,
                                               supplicant    interface wlan0,
 erx_sdio_host  legacy SD    erx_wifi_fs       ctl tree      erx_dhcp4
  polled, never   <-- sdio --+                 +-- ether -->
  on the line    attach, run,|                 | offer, frames,
                 notices     |                 | credits, link
                             +-- state slot --> vault (target)
```

The WiFi domain is a configured service domain of the Pi's manifest. It
holds a facet of the storage domain's `sdio` service, through which it
alone talks to the card, a facet of the network domain's `ether`
service, through which it lends `wlan0`, and its credential store
([Credentials](#credentials)). It holds no device, no unit and no
register.

Each requirement then follows:

* **The unit rule stands as written.** The legacy controller's page and
  line never leave the storage domain; the card's function crosses by a
  declared interface, the home the rule already names.
* **One issuer of commands stands.** The SDIO host issues every command
  through `erx_blk_write`, which gains an SDIO table; the build check of
  U4 is unchanged ([Commands](#commands-go-through-erx_blk_write)).
* **The shared line stays storage's.** The SDIO host never sets a bit of
  the legacy controller's signal enable, so the controller never raises
  line 126 and the SDIO host is no member of its owner
  ([Transactions and the card interrupt are polled](#transactions-and-the-card-interrupt-are-polled)).
* **The network stack gains a transport, not WiFi.** It sees frames, a
  hardware address, an MTU and a link state. It parses no firmware
  format, holds no key and calls no `crypto`, so the crypto design's
  rule for the network domain holds without exception.
* **Hostile parsing has one home.** Every byte from the chip and from
  the air through it is parsed in the WiFi domain, whose only authority
  is the card and the medium, which a radio attacker reaches anyway.
* **The port is the link.** The station opens the port when its keys are
  in, and the link the network domain sees is that port. DHCP starts on
  the link's `up`, as for every interface
  ([design-network-stack.md](design-network-stack.md#the-driver)).
* **Each domain's failure ends only its conversation.** A restart of the
  WiFi domain ends its offer and its attachment; the storage domain's
  data and the network domain's other interfaces carry on.

### What disappears

No interrupt line or register page crosses a domain, so no line hint,
cross-domain acknowledgement or deadline per firing is needed. Because
the legacy controller never signals the line, no round of EMMC2's line
waits on a WiFi transfer, and no quiescing is owed when the SDIO host
ends: its end leaves the signal enable as it always is, zero. No WiFi
control protocol reaches into the network domain: scanning, joining and
keys never reach the network domain, so no key handover, port-authorization
message or EAPOL forwarding crosses into it. No firmware file enters
the network or storage domain. The supplicant needs no driver interface
of its own: it is a part of the station, beside the chip process, in one
domain.

## The SDIO host in the storage domain

### The legacy controller's record

A device-kinds row matches the legacy controller and makes its record
`sdio sdhci`, the same CMSIS-SVD peripheral as EMMC2's record
(`hw/svd/sdhci/sdhci.svd`), with no DMA memory: the host moves data by
programmed I/O only. The record carries the controller's quirks as data,
so one controller core serves both controllers: 32-bit access only, the
write spacing, the capabilities replaced (3.3 V, a 1,024-byte block, and
no ADMA, as OpenBSD replaces them), the high-speed enable never set, and
its base clock from the platform record's `clock` for the unit's entry,
since FreeBSD marks this controller's capabilities missing and asks the
firmware for the rate (`bcm2835_sdhci.c:119-126`), which erXos cannot
(PL2). The record marks the line shared, as EMMC2's does.

### One controller core

`erx_blk_sd_host`, EMMC2's controller core, holds two kinds of
decision, and the SDIO host takes only the first:

* **The controller's machinery**, which knows SDHCI and no card: the
  decode of the `interrupt` word into a closed set of events, the
  divider, the inhibit and signalling checks, and one command's wait,
  `command/1` and `command_step/2`, whose command track ends at command
  complete and whose data track waits for the buffer event of each
  block and then transfer complete (`erx_blk_sd_host.erl:296-315`). The
  register access goes through `erx_blk_sd_regs:spaced/2` as EMMC2's
  does, and the quirks come from the record.
* **SD memory's command policy**, the request transfer of `new/1` and
  `step/2`: an R1 checked at command complete, Auto CMD12's R1 at
  transfer complete, and CMD13 after every write
  (`erx_blk_sd_host.erl:436-459`). None of it applies to an I/O card,
  whose CMD52 and CMD53 answer R5 and whose counted CMD53 needs no stop
  command (SDIO 5.3.1, p.39), so the SDIO host never runs it.

The one change is to the wait: its data track, today one block
(`{read | write, Size, 1}`), takes a count of blocks, from 1 to 511, so a
block-mode CMD53 is one command's wait with that many buffer events
before transfer complete; EMMC2's identification commands keep their
count of 1. The R5 is read at command complete as R1 is and parsed by
`erx_sdio_card`. No second SDHCI model exists, and SD memory's policy
stays where it is.

### Commands go through `erx_blk_write`

`erx_blk_write` gains an SDIO table beside its SD table: CMD5
(`IO_SEND_OP_COND`, R4), CMD3 (R6), CMD7 (R1b), CMD52 (`IO_RW_DIRECT`,
R5) and CMD53 (`IO_RW_EXTENDED`, R5). The argument fields are the SDIO
Simplified Specification's ("SDIO" below, Part E1 version 3.00): for
CMD52 the write flag, function, read-after-write flag, 17-bit address
and data byte (5.1, p.35); for CMD53 the write flag, function, block
mode, op code (fixed or incrementing address), 17-bit address and a
9-bit count (5.3, p.38), as OpenBSD's `sdmmc_ioreg.h:23-50` has them. A
count of zero means 512 bytes in byte mode and an infinite transfer,
ended only by an abort, in block mode (Table 5-3, p.39); the builders
never make the second, so every CMD53 the host issues ends by itself. Its builders,
`sdio_plan/1`, make an opaque `sdio_plan()`, and `sdio_issue/2` issues
one on a device whose record is of kind `sdio` and refuses any other, as
`sd_issue/2` refuses an `sdio` record. So neither table's commands reach
the other's card, and the build check of U4 needs no new site: the SDIO
host calls `erx_blk_write` and names `erx_device:command/2` nowhere. No
SDIO command writes a medium, so none passes the trial check; on a trial
boot WiFi works as on any other.

### Bringing the card up

An attach ([The `sdio` interface](#the-sdio-interface)) runs the
bring-up from the controller's reset for all, so every client meets the
same card: the card's I/O reset by a CMD52 write of the RES bit, bit 3
of the CCCR's register `06h`, since CMD0 does not reset an I/O card
(SDIO 4.4, p.30); CMD5 with no voltage to read the I/O OCR, the number
of functions and the memory-present bit; CMD5 with the 3.3 V window
until the card reports ready, with S18R, the request to switch to
1.8 V, always clear, so the card's signalling never leaves 3.3 V, which
the platform could not undo (3.2-3.3, p.23-24); CMD3 for its address;
CMD7 to select it; the 4-bit bus through the bus-interface control
register `07h` (4.5, p.30; Table 6-1, p.43), after the card capability
register `08h` shows a full-speed card or a low-speed card with 4-bit
support (`LSC`, `4BLS`, 6.9); and the card clock at 25 MHz. That is
OpenBSD's order (`sdmmc_io.c:73-132, 673-686, 688, 873-884`). The pure
part, `erx_sdio_card`, is the bring-up as a state machine and the
parsers of R4, R5 and R6. A card that answers no CMD5 is
`{error, no_card}`; OpenBSD treats the same silence as no SDIO card
(`sdmmc_io.c:88-92`). A memory-present or a combination card is refused:
the slot holds an I/O card. High speed at 50 MHz is a later step, after
the measurement of [Performance](#performance).

### Transactions and the card interrupt are polled

The host never lets the legacy controller signal: at every attach,
after the controller's reset for all, it writes the signal enable,
`irpt_en`, as zero, and no action of its core writes any other value
there. A set bit of `interrupt` raises the line only where `irpt_en`
has it (`hw/svd/sdhci/sdhci.svd`, `IRPT_EN`; Host Controller 2.2.22-2.2.23,
p.90-93), so the controller never raises line 126, and the host does not
join the line's owner. The line keeps one member, EMMC2's device
process, exactly as it has without WiFi.

**Transactions.** The host runs a client's transaction list by polling
the `interrupt` word through each command and each block, and hands each
word to the core's command wait. The status enable, `irpt_mask`, admits
the events the wait takes and the card interrupt; status bits set
without a signal, which is what a poll reads. Every command and every
data block has the SD driver's deadline of 1 s, which is also the most
an SDIO register access may take (SDIO 6.2, p.39).

**The card interrupt.** An SDIO interrupt is level-sensitive: a function
holds it until the host removes its cause, and it reaches the bus only
while the function's enable and the card's master enable in register
`04h` are set (SDIO 6.3, p.40). In the 4-bit mode it shares DAT[1], and
the controller samples it only in the interrupt period (8.1.2, p.59).
While a client is attached and has rearmed, the host reads `interrupt`
every `sdio_poll_ms`, 1 ms, between lists, and when it finds the
card-interrupt bit it clears the bit from `irpt_mask`, so the status no
longer follows the card's level, and tells its client once. The client
removes the cause with an access to its function's own registers, as the
specification requires (8.1.7, p.60), and its `rearm` step sets the bit
in `irpt_mask` again. OpenBSD's host masks the card interrupt in the same
place at a firing and sets it again at the acknowledgement
(`sdhc.c:1386-1389, 803-821`); polling moves only who looks, not the
masking rule. A client that never rearms loses only its own notices. The
asynchronous interrupt of version 3.00 is not in the simplified edition
(8.2, p.60), so its enable, register `16h`, stays clear.

Every property the shared line needs follows from `irpt_en` being zero,
and none needs a rule of its own:

* **No WiFi transfer delays storage's line.** A round of line 126 waits
  only for EMMC2's process, however slowly the card answers a CMD53.
* **Nothing is owed at the host's end.** A host that crashes, or whose
  supervisor gives up, leaves `irpt_en` zero, so no level it leaves
  behind reaches the line, and no surviving process has to quiesce the
  controller. The card may keep DAT[1] asserted; that reaches only the
  controller's status, which nobody reads until the next attach resets
  it.
* **The cost is latency.** A frame the chip announces waits at most one
  poll period, plus the list in progress, before the host looks; the
  measurement of [Performance](#performance) settles the period, and an
  interrupt-driven host is kept in reserve
  ([Alternatives considered](#alternatives-considered)).

### Supervision

The SDIO host, `erx_sdio_host`, is the one child of `erx_sdio_sup`,
which restarts it at most 3 times in 60 s and is itself a `temporary`
child of `erx_blk_sup`, started after the block driver. A card or
controller error is a transaction's result, never the host's end, so a
misbehaving card ends nothing. A fault of the host itself, a bug,
restarts it, and the restarted host resets the controller at its first
attach; past the supervisor's intensity WiFi is gone until the storage
domain's next start, with one log line, and because the supervisor is
temporary its end ends nothing else in the storage domain. Neither case
leaves anything on the line, since the host never enabled a signal. The
driver-control facet's unit `block` keeps naming the block driver.

## The `sdio` interface

`abi/services/sdio.txt` declares the interface, citing this section. The
manifest's service row `wifi_sdio` names the storage domain as its
server, and one facet row grants it to the WiFi domain. One module,
`erx_sdio`, is both sides: the client's calls and the host's decoder of
requests, as `erx_driver_ctl` is for driver control.

| Operation | Request | Answer |
| --- | --- | --- |
| `attach` | none | `{ok, #{ref := Ref, functions := 1..7, ocr := Ocr}}`: the card is reset, identified and selected, and the caller is its one client, `Ref` naming this attachment; `{error, no_card}`; `{error, busy}` while another client is attached; `{error, {device, Detail}}` |
| `run` | `{Ref, Steps}` | `{ok, Results}`, one result per step; or `{error, {Index, Reason}, Results}`, the steps before `Index` done and their results, nothing after it run; `{error, stale}` when `Ref` is not the living attachment's |

The steps, each one command on the card but the last two:

| Step | Command | Result |
| --- | --- | --- |
| `{read, Fn, Addr}` | CMD52 read | the byte |
| `{write, Fn, Addr, Byte}` | CMD52 write | `ok` |
| `{read, Fn, Addr, Len, incr \| fixed}` | CMD53 read | a binary of `Len` bytes |
| `{write, Fn, Addr, Bytes, incr \| fixed}` | CMD53 write | `ok` |
| `{block_size, Fn, Size}` | two CMD52 writes of the function's block-size register | `ok` |
| `rearm` | none: the card interrupt's bit set in `irpt_mask` | `ok` |

The host checks a list whole before it runs any step: at most
`sdio_steps_max` (64) steps and `sdio_bytes_max` (65,536) bytes of data
in all; `Fn` within the functions the card reported; `Addr` below
`2^17` (SDIO 6.1, p.39; 5.1, p.35). A CMD53's length must fit three
limits, each checked on its own:

* **the wire's**: byte mode carries 1 to 512 bytes (5.3.1, p.39), block
  mode 1 to 511 blocks, since a count of zero would be the infinite
  transfer (Table 5-3, p.39);
* **the function's**: block mode carries a multiple of the block size the
  host last programmed for that function with `block_size`, and byte
  mode no more than that size; a function with no programmed size takes
  byte mode alone, within the wire's 512 bytes;
* **the controller's**: a block size no larger than the record's largest
  block, 1,024 bytes for the legacy controller.

So a length is carried in byte mode when it is at most both 512 and the
function's block size, otherwise in block mode when it is a multiple of
the block size, and is refused when it is neither; the client pads as OpenBSD pads a frame
longer than 512 bytes to a multiple of 512 (`if_bwfm_sdio.c:1121`). A
`block_size` step takes 1 to the smaller of 2,048 (4.8, p.31) and the
controller's largest block. The host reads no CIS, so a function's
`TPLFE_MAX_BLK_SIZE`, the largest block and byte count it supports
(16.7.4), is the client's to respect; the 43455's sizes, 64 and 512, are
brcmfmac's (`bcmsdh.c:44-45`). And the host refuses a write that reaches
a register its own state depends on:

* in the CCCR (Table 6-1, p.43): the I/O abort `06h`, the bus interface
  control `07h`, bus suspend `0Ch`, function select `0Dh`, function 0's
  block size `10h` to `11h`, bus speed select `13h`, driver strength
  `15h` and interrupt extension `16h`;
* in each function's FBR, its I/O block size at `n10h` to `n11h`
  (Table 6-3, p.53), which only `block_size` writes, since the host
  programs the controller's block size from it and the specification
  forbids writing it with a block-mode CMD53 (6.13, p.56).

The client owns everything else: function enables and ready (`02h`,
`03h`), interrupt enables (`04h`), the vendor area (`F0h` to `FFh`, where
the chip's card-control and wake registers lie) and every function's
own registers. A refused list runs nothing.

A step's errors are the controller's, `{device, timeout | crc | inhibit
| {status, Bits}}`, and the card's, `{card, Flags}` with the R5 response's
error flags, `COM_CRC_ERROR`, `ILLEGAL_COMMAND`, `ERROR`,
`FUNCTION_NUMBER` and `OUT_OF_RANGE` (Table 5-1, p.36-37), named. A
device error leaves the controller in a state only a reset clears, so
the host runs nothing more until the next `attach`, which resets the
controller and the card: until then every `run` answers
`{error, {0, needs_attach}, []}`. This is the storage driver's rule of
one recovery path, a full start, rather than resets of the command and
data lines in place
([design-storage.md](design-storage.md#the-sd-host-controller), "Failure").

**Interrupt notices.** While a client is attached, the host sends it
`{erx_sdio, Ref, interrupt}` once for each poll that found the card
interrupt set, `Ref` being the attachment's, and sends nothing more
until a `rearm` step has run.

**The attachment and its reference.** The host makes `Ref` with
`make_ref/0` at each successful `attach` and returns it in the answer,
so the client learns it from the one call that creates it. Every `run`
names it and every notice carries it. The host answers a `run` whose
`Ref` is not the living attachment's `{error, stale}` and runs nothing;
the client takes a notice whose `Ref` is not the one its own `attach`
returned as nothing. The host monitors its client. The client's end, its
domain's end included, ends the attachment: the host masks the card
interrupt, forgets `Ref`, and takes the next `attach`, which resets the
card and makes a new reference, so a restarted client never meets a card
half-configured by its predecessor and nothing addressed to the old
attachment acts on the new one. The facet row's `in_flight` is 2: a
client may send its next list while one runs, and the host runs lists one
after the other in arrival order, never interleaving their steps.

## The WiFi domain

A configured service domain, `wifi`, of the Raspberry Pi's manifests, an
interpreter domain like the storage and network domains, running the
`erx_wifi` application. Its facets:

* `wifi_sdio` of the storage domain;
* `wlan0`, an `ether` facet of the network domain;
* `wifi_etc`, a read-only grant of the data partition's `wifi_etc` tree,
  a service directory of the data partition's storage service that holds
  the WiFi configuration and nothing else, as the `etc` tree holds the
  machine's settings ([design-storage.md](design-storage.md#interfaces)),
  mounted at `/etc` in the WiFi domain's own namespace, so the station
  reads FreeBSD's path, `/etc/wpa_supplicant.conf`;
* its credential store: the vault's state slot for `wifi`, or in a
  development build a `data` grant rooted at the WiFi domain's own
  directory on the data partition ([Credentials](#credentials)).

It serves one file tree, `wifi`, to root's session. It holds no device.
The `wifi_etc` tree is granted read-write to the session templates the
manifest grants the `wifi` tree, mounted there at `/etc/wifi`, so an
administrator edits `/etc/wifi/wpa_supplicant.conf`. The tree is its own,
beside the machine's `etc` tree: the WiFi domain reads none of the
machine's other settings, and no grant but these two reaches the WiFi
configuration.

```text
erx_wifi_sup  (one_for_all, intensity 0: restarts nothing)
 |- erx_bwfm            the chip process: the card through wifi_sdio,
 |                      SDPCM and BCDC, events, data frames, the medium
 |- erx_wifi_station    the station: scanning, joining, the supplicant
 |                      and SAE, the port, what /proc shows
 |- erx_wifi_fs         the wifi tree: ctl
```

`erx_wifi_sup` restarts nothing: the end of any of its processes ends
the domain, and the domain service starts it again within its row's
restarts, which loads the firmware afresh. That is the one recovery, as
the storage domain's is
([design-storage.md](design-storage.md#the-sd-host-controller)): the
chip's state, the station's and the medium's are one conversation, and
rebuilding them together leaves no partial restart to reason about.

## The chip

`erx_bwfm` is the one process that talks to the card, named after
OpenBSD's driver; its decisions are pure cores, each built and tested on
the host:

| Core | Decides |
| --- | --- |
| `erx_bwfm_boot` | the bring-up as a state machine whose actions are `sdio` step lists: block sizes, function 1, the chip's identity, cores and windows, KSO, the card-control reset, firmware and NVRAM writes and their read-back, the core start, function 2, watermark and interrupts, save-and-restore |
| `erx_bwfm_nvram` | the NVRAM text to the chip's form, as `bwfm_nvram_convert` (`bwfm.c:3009` onward) |
| `erx_bwfm_sdpcm` | the hardware and software headers both ways, the transmit credit, read-ahead and glom |
| `erx_bwfm_bcdc` | control requests and replies, matched by request id, and the data header |
| `erx_bwfm_event` | an event frame into a closed set of event records |
| `erx_bwfm_bss` | an escan result's BSS records and their information elements |

**Bring-up.** At its start the process attaches through `wifi_sdio` and
runs `erx_bwfm_boot` to a running firmware, in OpenBSD's order
([What a FullMAC chip leaves to the host](#what-a-fullmac-chip-leaves-to-the-host),
steps 1 to 3): block sizes 64 and 512, function 1 on and ready, the
chip's id and revision through the backplane window
(`if_bwfm_sdio.c:768-781, 912-950`), the PLL forced off, the cores read,
KSO on the SDIO core from revision 12, the card-control reset bit and the
PMU's resource reload, the ARM core halted, firmware written at
`0x198000` and NVRAM at the top of RAM and both read back and compared,
the core started (`if_bwfm_sdio.c:1045`), the HT clock awaited, function
2 enabled with the 43455's watermark, the host interrupt mask, the card's
interrupt enables for functions 1 and 2 and the master enable (SDIO
Table 6-1), and save-and-restore where the chip reports it. The process
accepts chip ID `0x4345` only when its revision is not 9, which is the
43456 (`if_bwfm_sdio.c:377-381`), and refuses every other chip, since
the image carries only the 43455's files. The boot log names the chip and
revision, which is W0's line. Then the firmware's ready mailbox
(`if_bwfm_sdio.c:650, 699-753`), the CLM blob in chunks, and the reads
of `ver`, `clmver`, `cur_etheraddr` and `cap` (brcmfmac `common.c:298,
378, 401`; `feature.c:228-252`), whose answers the station shows at
`/proc` and the log records, which is W1's line.

**The files.** Firmware, NVRAM and CLM blob are files of `erx_wifi`'s
`priv/firmware` directory, read with `file:read_file/1` at bring-up:
`cyfmac43455-sdio-standard.bin`, `brcmfmac43455-sdio.txt` and
`cyfmac43455-sdio.clm_blob`, each with the SHA-256 the fetch step pins
([Sources](#sources)).
The standard image, not the minimal one, which drops roaming, radar
detection and antenna diversity to serve more clients as an access point
(firmware-nonfree's `cypress/README.txt`). The process checks each
file's size against the chip's RAM before it writes anything.

**The bus.** On each interrupt notice the process runs one list: the
SDIO core's interrupt status read and cleared, the mailbox read when
it says so, then the frames of function 2, and `rearm` last once
function 2 has nothing more. A frame is read one of two ways, as
OpenBSD reads it (`if_bwfm_sdio.c:1213-1263`):

* **header first**, when the next length is unknown: a read of the
  12-byte headers; `erx_bwfm_sdpcm` checks the length against its
  complement, at least the headers' 12 bytes and at most the frame
  bound, OpenBSD's 64 KiB buffer (`if_bwfm_sdio.c:266`), and then the
  process reads the rest of the declared length, rounded up to 4 bytes
  as OpenBSD rounds it (`:1257-1263`), in a second list;
* **read-ahead**, when the previous frame's software header gave the
  next length: one read of that many bytes, whose header must declare
  no more than was read (`:1243-1247`).

Then the whole frame is checked before any field is used: a data offset
inside the frame, a length of at most 2,048 bytes for a data or event
frame, brcmfmac's `MAX_RX_DATASZ` (`sdio.c:304, 1419-1425`), and for a
glom a descriptor of whole 16-bit lengths whose sum fits the transfer,
each subframe with headers of its own that pass the same checks and
whose channel is data or event, never control or glom
(`if_bwfm_sdio.c:1294-1410`; brcmfmac `sdio.c:1427-1437`). A frame that
fails a check is dropped and counted by its reason, and a header that
fails ends the read-ahead, so the next read starts from a header again.
Every software header updates the firmware's maximum sequence number,
and transmission takes at most the window between it and the next
sequence number, at most 32 frames a list (`if_bwfm_sdio.c:1077-1093`).

**The channel is the frame's kind.** `erx_bwfm_sdpcm` returns each frame,
and each glom subframe by its own software header, tagged with its
SDPCM channel: `{control, Bytes}`, `{event, Bytes}` or `{data, Bytes}`,
and the process routes by the tag alone. A control frame is a BCDC reply;
an event frame goes to `erx_bwfm_event` and nowhere else; a data frame
is an Ethernet frame and is never parsed as an event. This is
brcmfmac's split, which hands the event channel to its event handler and
the data channel to the network stack with event handling off, a glom's
subframes each by their own channel (`sdio.c:2047-2053, 1714-1718`;
`core.c:502-540`); OpenBSD's driver hands both channels to one receive
path (`if_bwfm_sdio.c:1278-1279, 1401-1402`), where an Ethernet frame
from the air that carries the event ethertype would be read as an event.
Under the split, nothing a radio peer sends becomes a firmware event:
what the air sends arrives on the data channel.

**Control.** One BCDC request is in flight at a time, with a request id
the reply must carry, and a reply of a length the request did not allow
is refused. A reply missing for 2.5 s, brcmfmac's wait
(`sdio.c:40`), ends the process. Callers are the station and the
process's own bring-up; a variable's name and value are built by the
caller from the generated layouts and never parsed back but by those
layouts.

**Events.** An event-channel frame is an Ethernet frame behind its BCDC
header, which `erx_bwfm_event` takes only with ethertype `0x886c`,
Broadcom's OUI and an event message whose data length fits the frame
(`bwfmreg.h:764-786`; brcmfmac `fweh.h:365-390`); anything else on the
event channel is dropped and counted as `bad_event`. Its record goes to
the station, which acts on it only where it applies
([The station](#the-station)).

**Data.** A data-channel frame is an Ethernet frame behind its BCDC
header. Ethertype `0x888e` is EAPOL and goes to the station; any other
frame, `0x886c` included, goes to the medium's client while the port is
open and is dropped, counted as `port_closed`, while it is not. Frames
from the medium's client go to the chip only while the port is open.
The station's frames, EAPOL ones, go to the chip in the order the station
sent them, before any control request the station sent after them
([Concurrency](#concurrency-and-ordering)).

**Settings.** Before the station's first command the process sets what
OpenBSD's `bwfm_init` sets (`bwfm.c:435-578`): the event mask, the
power-save mode, the join preference, `mpc`, `txbf`, infrastructure
mode, no access point, every offload off (`arp_ol`, `arpoe`, `ndoe`,
`toe`) and `sup_wpa` 0; and `roam_off` 1, so the firmware never roams on
its own and the station chooses every BSS, as Raspberry Pi OS asks of
brcmfmac with `roamoff=1` (`rpi-brcmfmac.conf`; brcmfmac
`cfg80211.c:7095`). When `cap` names `sae_ext`, the mask is set through
`event_msgs_ext` and includes events 187 to 190 (`cyw/core.c:17-21,
79-99`). The one setting of `bwfm_init` it holds back is `up`
(`bwfm.c:554`): the process issues `country` and then `up` only when the
station hands it a country ([The country](#the-country)), and until then
the chip runs its firmware and answers control with its interface down,
and the station sends it no scan or join. Whether the firmware takes
`country` while down is F10 of [Facts](#facts-this-design-does-not-have).

## The station

`erx_wifi_station` runs one pure state machine, `erx_wifi_sta`:
`step(State, Event) -> {Actions, State}`. Every decision about networks,
the handshakes and the port is a step; the process performs the actions
and owns the timers.

| State | Meaning |
| --- | --- |
| `down` | the chip is not running yet |
| `idle` | the chip runs; no network is joined |
| `scanning` | an escan is in flight, for a join or for `ctl` |
| `joining` | the join is issued; the firmware's join or authentication request is awaited |
| `sae` | the SAE exchange runs: committed, then confirmed |
| `keys` | associated; the 4-way handshake runs |
| `open` | keys are installed and the port is open |

Events are a closed set: the chip's readiness, the configuration, a
`ctl` command, an escan result and its end, the join's outcome, link up
and down, deauthentication and disassociation, the external
authentication request, a received authentication frame and a
management frame's transmit status, an EAPOL frame, and a deadline.
Actions are a closed set too: a control request, an EAPOL or
authentication frame to send, a key to install or delete, the port
opened or closed, a store write, a report for `/proc` and a log line.

**An event acts only where it applies.** Every event record names what
it concerns, and the step takes it only in a state that awaits it and
only for the operation in flight: an escan result and its end only in
`scanning` and only with the sync id the station's escan carried; the
join's outcome, link up and the external authentication request only in
`joining` and only for the address of the BSS the station joined; a
received authentication frame and a transmit status only in `sae`, from
that BSS and for the packet id the station sent; link down,
deauthentication and disassociation only from the joined BSS. Any other
event is dropped and counted as `unexpected_event`. With the channel
split of [The chip](#the-chip), an event the station acts on was sent by
the firmware, on the event channel, about the station's own request.

**Choosing a network.** The station scans and joins only once a country
is configured ([The country](#the-country)). A scan's results, with the
configuration's network blocks and the credential store, give the
candidates: a BSS whose SSID a block names, whose security the block
allows and the station supports, and, for a protected network, whose
SSID has a secret in the store. The station
joins the candidate of the highest `priority`, then the strongest signal.
Joining sets `wpa_auth`, `wsec`, `auth`, `mfp` and, for a protected
network, the station's RSN element in `wpaie`, then `join` with the BSS's
address (`bwfm.c:1985-2060`). The station keeps the RSN element and
RSNXE of the BSS the scan reported, for the checks of the 4-way
handshake.

**The port.** It opens when every negotiated key is installed
([The 4-way handshake](#the-4-way-handshake)), or at once for an open
network, and closes at every link down, deauthentication,
disassociation, leave and failure. The chip process reports it to the
medium's client as the link
([The `ether` interface](#the-ether-interface-and-wlan0)).

**Leaving and failing.** A link down, a deauthentication or a failed
handshake closes the port, deletes every installed key, empties the key
slots, the pending PTK and the watermark, and returns to `idle`, which
scans again after 1 s and then at a backoff doubling to 60 s while no
candidate joins. Every failure's reason is the state's at `/proc`.

**Deadlines.** The join's answer within 10 s; SAE's exchange within 5 s,
each frame sent again after 1 s at most twice; the 4-way handshake's
first message within 10 s of association and each later one within 5 s.
These are erXos's values, to be tuned on the board; nothing depends on
their exact size.

## The supplicant

The supplicant is a part of the station: its cores are pure functions
the station's step calls, and its state is the station's.

**Keys from secrets.** For PSK the PMK is PBKDF2-HMAC-SHA1 of the
passphrase, salted with the SSID, 4,096 iterations, 32 bytes, or the 64
hexadecimal digits of a raw PSK, computed with `crypto:pbkdf2_hmac/5`
(`otp/lib/crypto/src/crypto.erl:1028`); for SAE the station derives PT
([SAE](#sae-and-protected-management-frames)). Both are computed once,
when an administrator gives the network's secret, and kept in the
credential store in place of it ([Credentials](#credentials)); the
passphrase itself is kept nowhere. For SAE the PMK comes from the
exchange.

**One table per AKM.** Everything that differs between the supported
AKMs is a row of one table in `abi/formats/ieee80211.txt`, generated into
Erlang:

| AKM | Suite | PTK derivation | EAPOL-Key MIC | Key descriptor version | Source |
| --- | --- | --- | --- | --- | --- |
| 2 | PSK | PRF-SHA1 | HMAC-SHA1, first 16 bytes | 2 | OpenBSD `ieee80211_crypto.c:326-450, 474-526` |
| 6 | PSK-SHA256 | KDF-SHA256 | AES-128-CMAC | 3 | the same; `wpa_common.c:375-409, 507-660` |
| 8 | SAE | KDF-SHA256 | AES-128-CMAC | 0 | `wpa_common.c:405-409` |

Pairwise and group ciphers are CCMP-128 alone; a network that offers only
TKIP is not a candidate. The group management cipher for PMF is
BIP-CMAC-128. The KCK, KEK and TK are 16 bytes each for every row.

`erx_wpa_key` decodes an EAPOL-Key frame and its key data's elements,
and builds the station's messages; `erx_wpa_kdf` derives the PTK,
computes and checks the MIC, comparing with `crypto:hash_equals/2`, and
unwraps the key data with AES key wrap under the KEK, written over
single AES-128-ECB blocks of `crypto:crypto_one_time/4`, refusing data
whose integrity value does not unwrap. The station follows OpenBSD's
supplicant side (`ieee80211_pae_input.c:188-280, 362-690, 815-980`).

### The key slots

For each association the station keeps three things, all emptied when
the association ends:

* **the replay watermark**, the replay counter of the last EAPOL-Key
  frame it accepted under a valid MIC, or none. Every handshake message
  must carry a counter above it (`:210-211, 384-385, 835-838`), and only
  an accepted message 3 and an accepted group message 1 raise it
  (`:526-527, 967`). Message 1 carries no MIC, so it never raises it: a
  forged message 1 with a large counter cannot shut out the access
  point's own later frames;
* **the pending PTK**, the ANonce, the SNonce and the PTK derived from
  them at the last accepted message 1 (`:255-265`), under which message
  3's MIC is checked; a new message 1 replaces it;
* **the key slots**, the key the chip holds in each slot, or none: the
  pairwise slot, the GTK slots of key ids 1 to 3 and the IGTK slots of
  key ids 4 and 5.

**A key is installed once.** An accepted message yields the keys it
carries, and the station's install actions are exactly those of them
that differ from their slot's key; a key equal to its slot's yields no
action. Each install carries the key's receive counter, the GTK's from
the frame's Key RSC and the IGTK's packet number from its KDE, as
OpenBSD carries them (`:605, 642`), written into `wsec_key`'s receive IV
with its initialized flag, as brcmfmac writes a key's sequence
(`cfg80211.c:2919-2934`); the pairwise key starts from zero. So:

* a retransmitted message 3, whose nonces are the pending PTK's, yields
  the PTK already in the pairwise slot and installs nothing;
* a retransmitted or replayed group message yields the GTK and IGTK
  already in their slots and installs nothing;
* no installed key is ever installed again within its association, so no
  key's transmit packet number or receive counter in the chip is reset,
  which is what a key reinstallation attack needs;
* a rekey still installs: a new message 1 draws a new SNonce, so the PTK
  it leads to differs from the slot's, and a new GTK differs from its
  slot's.

OpenBSD keeps the same property with two guards, a flag that a new PTK is
expected for the pairwise key (`:538-579`) and a comparison with the
installed key for each group key (`ieee80211_must_update_group_key`,
`:345-356`, used at `:598, 637, 895, 929`); here one rule covers every
slot, and the slots mirror the chip because nothing else changes the
chip's keys: when the association ends the station deletes each
installed key with a `wsec_key` of zero length (`bwfm.c:2928-2938`)
before emptying the slots, and a restart of the WiFi domain reloads the
firmware, which starts with none.

### The 4-way handshake

* **Message 1** is taken in `keys` or `open`, since an access point may
  rekey with a new message 1 (`:201-208`), with a counter above the
  watermark. The station draws its SNonce from `crypto:strong_rand_bytes/1`,
  sets the pending PTK and answers message 2 with its RSN element. The
  watermark does not move.
* **Message 3** is taken only with a pending PTK; a counter above the
  watermark; the pending ANonce (`:395-398`); a valid MIC under the
  pending PTK's KCK (`:403-409`); encrypted key data that unwraps under
  its KEK; an RSN element equal byte for byte to the one the scan
  reported for the BSS, else the station deauthenticates with "RSN
  element different" (`:494-502`), and an RSNXE equal to the scan's too;
  the Install bit (`:487-492`); a GTK KDE of the group cipher's length
  (`:586-593`); and, when PMF is negotiated, an IGTK KDE of 28 bytes and
  key id 4 or 5 (`:624-635`), since a port opened without it would leave
  the protection of broadcast management frames off on a network that
  requires it. The station then raises the watermark to the message's
  counter, sends message 4, and installs what differs from the slots:
  pairwise, GTK, IGTK, in OpenBSD's order (`:535, 569-657`).
* **The port opens** once every negotiated key, the PTK, the GTK and,
  under PMF, the IGTK, is in its slot after a `wsec_key` the chip
  answered `ok`; a refused install deauthenticates, as OpenBSD's does
  (`:569-578, 609-618, 646-657`).

### The group key handshake

Group message 1 has a rule of its own, OpenBSD's (`:829-890`), and none
of message 3's checks that belong to the 4-way handshake: it is taken
only in `open`, where the pairwise key is installed; with a counter
above the watermark; with a valid MIC under the installed PTK's KCK; with
the Encrypted bit set and key data that unwraps under the installed
KEK; and with a GTK KDE of the group cipher's length, and, under PMF, an
IGTK KDE of 28 bytes and key id 4 or 5 when one is present
(`:895-950`). It carries no ANonce and the access point sends no RSN
element in it, so the station compares neither. The station raises the
watermark to its counter (`:967`), installs what differs from the slots,
and answers group message 2; the port stays open.

### What a failed check costs

A frame that fails a check is dropped and counted by its check, and
changes nothing. An accepted message 1, which no MIC protects, changes
only the pending PTK: a forged one can spoil the handshake in progress,
which the access point's retransmission of message 1 or the deadline
recovers, and can install nothing. A deauthentication follows only the
checks the source deauthenticates on: a different RSN element, an
unusable cipher, a key of the wrong length or a refused install.

## SAE and protected management frames

**The form.** SAE runs on the host through the firmware's external
authentication, the form of brcmfmac's Cypress-class chips
([Context](#what-a-fullmac-chip-leaves-to-the-host)), and only when the
firmware's `cap` names `sae_ext`. W1 probes the pinned firmware for it,
and W5 then probes the exchange itself and PMF on the board, since
brcmfmac files the 43455 under Broadcom's class and gives no evidence
either way (F8). Without `sae_ext` a network block that allows only SAE
is not a candidate, with the reason `no_sae_ext` at `/proc`, and WPA3 is
reported unsupported. The remedy then is another Cypress firmware build
for the 43455 that offers `sae_ext`, under a license the image may
carry; the firmware's own SAE from a password (`wcc/core.c:16-20`) is
not used, since it hands the password to the firmware and hides the
exchange from the host's checks.

**The exchange.** For a candidate whose AKM is SAE the station joins with
`wpa_auth` set to SAE, `auth` 3, `wsec` AES and `mfp` set (below) (brcmfmac
`cfg80211.c:2027-2032, 2066-2068, 2289-2295`). The firmware raises the
external-authentication request with the peer's address and SSID
(`cyw/core.c:239-272`). The station sends its commit and then its
confirm as authentication frames through the `mgmt_frame` variable, each
with a packet id whose transmit-status event it awaits
(`cyw/core.c:101-196, 326-352`), takes the peer's frames from the
received-frame event (`cyw/core.c:274-325`), and reports the outcome with
`auth_status`, success 4 or failure 3 (`cyw/fwil_types.h:39-59`). The
firmware then associates and the 4-way handshake runs with AKM 8's row
and the PMK from SAE.

**`erx_sae`**, a pure core, follows wpa_supplicant 2.12's `sae.c` for
group 19 (P-256) and hash-to-element alone. Every operation on a secret
value, the password-derived values, PT, PWE, `rand`, `mask` and K, is
either HMAC through `crypto` or one of the three functions of
[OTP's `crypto`: SAE's arithmetic](#otps-crypto-saes-arithmetic); no
secret ever becomes an Erlang integer:

* **PT** from the SSID, the password and an optional password
  identifier: the two hashed values by HKDF over HMAC-SHA256 in Erlang,
  then `crypto:sae_pt/3`, which reduces each modulo the prime, maps it
  by the simplified SWU map and adds the two points
  (`sae_derive_pt_ecc`, `sae.c:874-1052`; `sswu`, `:635-832`), computed
  once, when the secret is given, and kept in the credential store,
  never in answer to a frame;
* **the commit**: the value from both addresses, which is public,
  computed in Erlang, and `crypto:sae_commit/5`, which returns PWE, that
  value times PT (`sae_derive_pwe_from_pt_ecc`, `:1158`), the scalar
  `(rand + mask) mod r` and the element, the negation of `mask x PWE`
  (`:1298-1384`), for `rand` and `mask` drawn below the group's order
  from `crypto:strong_rand_bytes/1`; sent with status 126,
  hash-to-element (`ieee802_11_defs.h:233`);
* **the peer's commit** parsed and checked (`sae_parse_commit`,
  `:2203-2313`): its group 19, a scalar from 2 to `r - 1`, an element
  that decodes onto the curve, and neither equal to the station's own;
  an anti-clogging token request (status 76) sends the commit again with
  the token (`ieee802_11_defs.h:199`; `:1846`);
* **the keys**: `crypto:sae_key/5`, K's x-coordinate, `rand x (peer
  scalar x PWE + peer element)`, or `infinity`, which the station
  refuses; KCK and PMK by the KDF over HMAC-SHA256
  (`sae_derive_keys`, `:1539-1680`);
* **the confirms**: built and checked with HMAC-SHA256 under the KCK,
  compared with `crypto:hash_equals/2` (`sae_cn_confirm`, `:2314-2375`;
  `sae_check_confirm`, `:2439` onward).

Its states are wpa_supplicant's: nothing, committed, confirmed, accepted
(`sae.h:113-115`). How far the three functions are constant-time is a
residual of [Security](#security). A network that offers SAE without
hash-to-element in its RSNXE (bit 5, `ieee802_11_defs.h:632`) is not an
SAE candidate: hunting-and-pecking derives its element per exchange, in
answer to the peer, and is out of scope.

**Protected management frames.** The station sets `mfp` from the
network's RSN capabilities and its block's `ieee80211w`: required when
either requires it, capable when both allow it, none otherwise (brcmfmac
`cfg80211.c:2270-2295`), once the firmware answers the `mfp` variable at
all (`feature.c:332`). An SAE join always negotiates PMF. The IGTK from
the handshake is installed with `wsec_key` under its key id, with the
firmware's AES-CCM algorithm code, which brcmfmac also gives an AES-CMAC
key (`cfg80211.c:2958-2961`), and its packet number as the receive IV;
the firmware protects and checks management frames with the installed
keys.

## Configuration, credentials and control

**`wpa_supplicant.conf`.** The station reads `/etc/wpa_supplicant.conf`,
FreeBSD's file at FreeBSD's path in the WiFi domain's own namespace,
which is the `wifi_etc` tree ([The WiFi domain](#the-wifi-domain)), at
its start and at `reconfigure`; an administrator edits it as
`/etc/wifi/wpa_supplicant.conf`. `erx_wpa_conf` parses a subset of
wpa_supplicant's format:

* global `country=CC`; `ctrl_interface`, `ctrl_interface_group` and
  `update_config`, which configure wpa_supplicant's own control socket
  and are taken and ignored;
* `network={ ... }` blocks with `ssid` (a quoted string or hexadecimal,
  1 to 32 bytes), `scan_ssid`, `key_mgmt` (`NONE`, `WPA-PSK`,
  `WPA-PSK-SHA256` and `SAE`, a space-separated list), `ieee80211w` (0,
  1 or 2) and `priority`.

The file holds no secret. `psk`, `sae_password` and `sae_password_id`
are refused with the reason `{config, Line, secret_in_file}`, and the log
line says that a network's secret is given through `ctl`
([Credentials](#credentials)). Any other key, a value outside its range
or a malformed line refuses the whole file with its line number and key,
at `/proc` and in the log, and the station keeps the configuration it
had, none at its start: a key the station does not understand may
narrow what a block allows, so reading past it would read the file
wrongly. The file is at most 64 KiB.

### Credentials

The station's secrets are one blob: for each SSID that has been given a
secret, the PMK when the secret is a passphrase or raw PSK, and PT with
its password identifier, at most 64 bytes, when it is an SAE password,
at most `wifi_networks_max` (16) networks and 4 KiB in all. They are derived
values, so the passphrase is kept nowhere; each is still the password's
equivalent for its SSID, and is guarded as the password would be.

The blob is kept through one seam, the one the Bluetooth design gives
its bonds: `get() -> {ok, Blob} | none` at the station's start, and
`put(Blob) -> ok | {error, unavailable}` for each change, the blob
replaced whole:

* **the target**: the vault's sealed state slot for the service `wifi`,
  a purpose of the vault whose facet returns the grantee's blob whole,
  logged as a token's release is, and replaces it through the machine
  file's owner, answered after the checkpoint, as every change to the
  vault's files is ([design-system.md](design-system.md#the-vault)). The
  vault parses nothing of the blob and bounds its size. The purpose is
  the one the Bluetooth design proposes for its bonds, shared by both
  and settled once ([Open decisions](#open-decisions), 1);
* **a development build, before the vault**: a file, `credentials`, in
  the WiFi domain's own directory on the data partition, replaced whole
  by write, sync and rename, as the SSH domain keeps its host key before
  the vault ([design-ssh.md](design-ssh.md#host-keys)). It is not sealed:
  a session that holds the data partition's tree, or a copy of the
  medium, reads every network's PMK and PT. That is a security residual
  that blocks release ([TODO.md](../TODO.md)), and the release manifest
  check refuses a `wifi` row whose store is the development one.

What `get` returns is untrusted wherever the medium can be written:
`erx_wifi_store` decodes it with every length checked and has a fuzz
target. A blob that does not decode is reported as `store_unreadable` at
`/proc` and in the log, and the station runs with no secrets; the next
change writes a blob of only what that change holds.

**Giving a secret.** Two `ctl` commands change the blob, each with
values in `wpa_supplicant.conf`'s own syntax, read by `erx_wpa_conf`'s
value readers:

* `secret ssid=VALUE psk=VALUE`, `secret ssid=VALUE sae_password=VALUE
  [sae_password_id=VALUE]`, or both secrets for a transition network:
  the station derives the PMK and PT
  ([Keys from secrets](#the-supplicant)), puts the new blob, and answers
  the write once the store has answered `ok`;
* `forget ssid=VALUE`: the network's entry removed, answered the same
  way.

A store that answers `{error, unavailable}` fails the write with `eio`
and changes nothing. The `ctl` file is root's session's alone, so only
root gives or removes a secret, as only root edits FreeBSD's
`/etc/wpa_supplicant.conf`.

### The country

The station scans and joins only once a country is configured, from
`country=CC` or from `ctl`'s `country CC`, which holds until the next
configuration. It sets the country with the `country` variable (brcmfmac
`cfg80211.c:8452-8462`), and only then does the chip process issue `up`.
With none configured the station stays in `idle` with the reason
`no_country` at `/proc`, the chip's interface stays down, and `ctl`'s
`scan` and `ssid` fail with `eio`. The firmware's behaviour with no
country set, which country its CLM blob then applies and whether it
transmits under it, is not verified for the pinned firmware (F10);
until it is, nothing transmits without a country.

### Control and inspection

**The tree.** The WiFi domain serves `wifi`, an `erx_fs` tree with one
file, `ctl`, granted to root's session and mounted at `/net/wlan0`. A
write is one command of at most 4,096 bytes: `scan`, which answers when
the scan ends; `ssid NAME`, which joins an open network by name;
`country CC`; `leave`; `reconfigure`; and `secret` and `forget`. A
malformed command fails the write with `einval`.

**What `/proc` shows.** The station reports the inspection paths `wifi`,
the chip (id, revision, firmware and CLM versions, `cap`, hardware
address, country), the state and its last reason, the joined BSS, its
channel, security and signal, the SSIDs that have a secret and never the
secret, and counters by reason; and `wifi scan`, the last scan's BSS
records. Every SSID and every firmware string is text from the air or
the chip and reaches a sink only through that sink's escaping function.

**`ifconfig`.** `ifconfig wlan0 scan` writes `scan` to `ctl` when the
session can write it, as FreeBSD starts a scan only for root
(`ifieee80211.c:4093-4097`), then prints `wifi scan` in FreeBSD's columns
(`:4011-4066`), writing an SSID as `copy_essid` does, whole as `0x` and
hexadecimal when any byte is outside `0x20` to `0x7e` (`:3671-3702`);
`ifconfig wlan0 list scan` prints without scanning; `ifconfig wlan0 ssid
NAME` and `ifconfig wlan0 country CC` write their commands; and
`ifconfig wlan0` adds FreeBSD's status lines (`ieee80211_status`,
`:5164`) for the fields `wifi` holds, leaving out those it does not.

## The `ether` interface and `wlan0`

`abi/services/ether.txt` declares the interface, citing this section: a
domain that drives a network medium lends it to the network domain. The
network domain serves it, one service row per interface it lends, named
after the interface, `wlan0`, and granted to the domain that has the
medium. So the name, and the right to offer it, are the manifest's.

| Operation | Request | Answer |
| --- | --- | --- |
| `offer` | `#{lladdr := <<_:48>>, mtu := 1280..1500, credit := 1..256}` | `{ok, #{driver := pid(), ref := Ref, credit := pos_integer()}}`; `{error, busy}` while an offer of this name lives; `{error, badarg}` |

An offer starts the interface's link, a `temporary` child of
`erx_net_interfaces`: `erx_net_driver` over the transport `erx_net_ether`,
whose medium is the offering process, then `erx_net_if` and, as the
network domain's configuration says for the name, `erx_dhcp4`. The
network domain's configuration keeps `wlan0`'s addressing under its
name, with `ether` as its transport. The new driver makes `Ref` with
`make_ref/0` when it starts, and the facet's answer carries it with the
driver's pid, so the offering process learns both from the call that
made them, and the driver knows the offering process as the facet
request's sender. Every message of the link carries `Ref`; each side
drops and counts, as `stale`, a message whose `Ref` is not that of the
link it is part of, so nothing sent to a link that ended acts on the
offer that replaced it. The offering process and the driver then
exchange plain messages between introduced processes, monitoring each
other:

* `{erx_ether, Ref, frames, [Frame]}` both ways, each within the credit
  the receiver granted, one unit per frame;
* `{erx_ether, Ref, credit, N}` both ways, returning units as the
  receiver passes frames on: the driver as it hands a batch to the
  interface, the chip process as frames leave for the chip;
* `{erx_ether, Ref, link, up | down}` from the offering process, only the
  latest state, which the driver holds as its transport's link.

The credits cross as messages, as the network stack's rule requires
between domains
([design-network-stack.md](design-network-stack.md#credited-queues)).
The transport's row in the stack's driver table: `link` `ethernet`,
`lladdr` and `mtu` from the offer, `state` from the link messages,
`down` until the first, `tx_limit` the credit the offering process
granted, `finish` `none`, since nothing beyond the frame layer finishes
a checksum. The driver drops a frame longer than the MTU and the
Ethernet header as `too_long` and one that is not a binary as
`malformed`, as for every medium.

The offering process's end ends the link: the driver's transport answers
`{stop, far_end}` and the link supervisor, temporary, is not started
again; a later offer starts it anew. The driver's end, the network
domain's end included, ends the medium's client: the chip process keeps
its association and offers again once the network domain's facet
answers, trying once a second. The network domain's `network_ctl` names
no lent link: the unit `net` stays the link of its own network device
([design-network-stack.md](design-network-stack.md#the-process-tree)).

## OTP's `crypto`: SAE's arithmetic

SAE computes on P-256 with secrets: a map of the password's hashed values
onto the curve, a secret point times a public value, sums of secret
scalars, a secret scalar times a point, and the sum of a secret point
and the peer's. OTP's `crypto` exports no point arithmetic: its NIF
multiplies the generator only, inside key generation and ECDH
(`c_src/ec.c:491, 894`). Done in Erlang, the sums and the map would run
on Erlang integers, in time that depends on the secret. So the boundary
is drawn around every secret-dependent step: `otp/lib/crypto` takes one
edit, three functions in `crypto.erl` and their NIF in `c_src/ec.c`,
each one step of SAE whole, taking and returning binaries:

```erlang
-spec sae_pt(Curve, U1, U2) -> PT
          when Curve :: secp256r1, U1 :: binary(), U2 :: binary(),
               PT :: binary().
-spec sae_commit(Curve, PT, Val, Rand, Mask) -> {PWE, Scalar, Element}
          when Curve :: secp256r1, PT :: binary(), Val :: binary(),
               Rand :: binary(), Mask :: binary(),
               PWE :: binary(), Scalar :: binary(), Element :: binary().
-spec sae_key(Curve, PWE, Rand, PeerScalar, PeerElement) -> K | infinity
          when Curve :: secp256r1, PWE :: binary(), Rand :: binary(),
               PeerScalar :: binary(), PeerElement :: binary(),
               K :: binary().
```

* `sae_pt` reduces each 48-byte hashed value modulo the prime, maps each
  by the simplified SWU map, and returns the sum of the two points;
* `sae_commit` returns PWE, `Val x PT`, the scalar `(Rand + Mask) mod r`
  and the element, the negation of `Mask x PWE`;
* `sae_key` returns K's x-coordinate, `Rand x (PeerScalar x PWE +
  PeerElement)`, or `infinity`.

A point is SEC1's uncompressed form, `<<4, X:32/binary, Y:32/binary>>`;
a scalar is 32 bytes big-endian, from 1 to the group's order less one.
Every point enters through `EC_POINT_oct2point`, which refuses one off
the curve (`c_src/ec.c:739` uses it already), so no operation runs on an
invalid point; a point not of that form, a scalar out of range, a hashed
value of another length, the point at infinity as an argument and any
curve but `secp256r1` raise `badarg`. Every intermediate value lives in
the NIF's OpenSSL objects and is cleared before the call returns. The
multiplications are `EC_POINT_mul` with one point and its scalar, which
OpenSSL 3.5.9 in the tree computes by the P-256 method's windowed
multiplication, constant-time for a scalar below the order
(`ecp_nistz256.c:605-642`), which the range check ensures, or, under a
generic method, by its Montgomery ladder for a scalar times a variable
point (`openssl/crypto/ec/ec_mult.c:485-494`). The point additions, the
negation, the scalar sum and the SWU map's field arithmetic use
OpenSSL's general `EC_POINT_add` and BIGNUM routines, which are not
constant-time: the P-256 method's addition is the generic
`ossl_ec_GFp_simple_add` (`ecp_nistz256.c:1591`), whose arithmetic and
branches depend on the coordinates (`ecp_smpl.c:702-721`). That is a
residual of [Security](#security), whose fix is inside these three
functions and changes nothing above them. Groups 20 and 21 add their
curves to `Curve` when SAE needs them. Nothing else of `crypto` changes,
and nothing in the network domain calls it.

## Invariants

| Invariant | Mechanism | A violation | Check |
| --- | --- | --- | --- |
| **WF1.** The legacy controller's page and line stay in the storage domain | the unit rule and the manifest check; the card reaches another domain only through `sdio` | a manifest that gives the legacy controller to another domain | the boot view's refusal of a split unit, unchanged ([design-shared-devices.md](design-shared-devices.md#the-unit-rule)) |
| **WF2.** Only `erx_blk_write` issues a command to either SD controller, and no SDIO command writes a medium | the SDIO table in `erx_blk_write`; `sdio_issue/2` and `sd_issue/2` each refuse the other kind's record | a second issuing module; an SD command on the legacy record; a CMD53 on EMMC2 | U4's build check, unchanged; host tests of both refusals |
| **WF3.** A client never writes a register the host's state depends on, and never issues a CMD53 the wire, the function or the controller cannot carry | `erx_sdio:check/2` refuses the list whole, checking the three limits apart | a CMD52 or CMD53 write that reaches a host-owned CCCR register or a block-size register; a byte-mode CMD53 of more than 512 bytes | the host core's property test over addresses and lengths, seeded below |
| **WF4.** No data frame passes between the chip and the network domain while the port is closed, and `wlan0`'s link is up exactly while it is open | the chip process gates both directions on the station's port; the link message is the port | a frame forwarded before the keys are in | the exhaustive station test and the fake chip's port test |
| **WF5.** Passphrases, PMKs, PT and the PTK's KCK and KEK leave the WiFi domain only for its credential store; the installed keys reach the chip through the storage domain | the supplicant is a part of the station; `ether` carries frames, credits and a link state; the store's seam takes one blob | a secret in a message to any domain but the store's | the `ether` schema carries no key field; a build check that the network stack calls no `crypto`, unchanged. The storage domain receives the TK, GTK and IGTK as the bytes of `wsec_key`'s CMD53 writes, in its messages and memory: it is inside those keys' boundary, as the firmware is ([Security](#security)) |
| **WF6.** Every byte from the chip, the air or the store is parsed once, by a bounds-checked core with a fuzz target, before any decision | the cores of [The chip](#the-chip), [The supplicant](#the-supplicant), `erx_sae` and `erx_wifi_store` | a field read from an unchecked binary | the fuzz targets of [Untrusted input](#untrusted-input) |
| **WF7.** Every attachment starts from a reset card, and nothing of an ended attachment acts on the next | `attach` runs the bring-up from the controller's reset for all and the card's I/O reset, and makes a fresh `Ref` that every `run` and notice carries | a client that meets the previous client's chip state; a list of the old attachment run on the new | the host test that a second attach after a client's death resets and refuses the old `Ref`, with the fake card |
| **WF8.** No key is installed from a message whose replay counter, MIC, nonce, key data or RSN element check failed, and only a message authenticated by its MIC raises the replay watermark | the handshakes' checks are the only path to an install action; the watermark moves only in the accepting steps of message 3 and group message 1 | an install after a failed check; a watermark raised by message 1 | the exhaustive station test with forged and replayed messages |
| **WF9.** No key is installed twice in one association, so no key's packet numbers are reset | an install action exists only for a key that differs from its slot's; the slots are emptied only with the chip's keys | a retransmitted message 3 or group message that installs again | the exhaustive station test with retransmissions, seeded below |
| **WF10.** Only the firmware's event channel makes an event | `erx_bwfm_sdpcm` tags every frame and glom subframe with its SDPCM channel; only `{event, _}` reaches `erx_bwfm_event` | a data frame of ethertype `0x886c` decoded as an event | the SDPCM core's host test with event-shaped frames on the data channel, seeded below |
| **WF11.** The legacy controller never raises the shared line | the SDIO host's core writes `irpt_en` only as zero | a set bit in `irpt_en` | the host test over the core's register actions, seeded below |

## Concurrency and ordering

* **One owner per conversation.** The SDIO host owns the card's bus, the
  chip process the chip, the station the network state, each driver in
  the network domain its link. No two processes share state; they
  exchange messages.
* **The host serializes the card.** Lists run one at a time in arrival
  order, a list's steps back to back. EMMC2's process and the SDIO host
  run concurrently on separate controllers and share nothing at run
  time: the line is EMMC2's alone (WF11), so neither waits on the other.
* **The chip process orders what it sends.** Frames and control requests
  from the station reach the bus in the order the station issued them, so
  message 4 is written to function 2 before the `wsec_key` request that
  follows it on the control channel, as brcmfmac waits for its pending
  EAPOL frames to reach the bus before it sends a key
  (`cfg80211.c:607`). Whether the firmware transmits a
  frame queued before a key request with the old key is the firmware's;
  W4's board test settles it ([Facts](#facts-this-design-does-not-have)).
* **Credits bound every queue.** The chip process sends the network
  domain frames only within the driver's credit and takes them only
  within its own; SDPCM's window bounds what it writes to the chip; the
  station's frames and requests wait in the chip process's mailbox, at
  most the handful the station's state machine has in flight. A frame
  that finds no credit is dropped and counted.
* **Timers belong to the station and the chip process**, as deadlines
  checked at each event; the cores take the time as an input.

## Failure handling

| What fails | What notices | What survives | Recovery |
| --- | --- | --- | --- |
| No card answers CMD5: power, pins or a missing chip | `attach` answers `no_card` | everything else | the WiFi domain logs one line naming the unknown facts and ends; the domain service's restarts bound the retries, then it stays down |
| A command times out or the card reports an error | the step's result | the attachment, until the client acts | the chip process ends, so the WiFi domain restarts and attaches afresh |
| A CMD53 runs slowly, up to its 1 s deadline | the SDIO host's poll | EMMC2 and its line, which never wait on the SDIO host | none needed; a deadline is a device error |
| The firmware fails its read-back, does not start or stops answering control | `erx_bwfm_boot`; a 2.5 s control deadline | the storage and network domains | the WiFi domain restarts, reloading the firmware |
| A frame from the chip fails a check | the core | everything | the frame is dropped and counted; a bad header ends the read-ahead |
| A handshake or SAE message fails a check | the core | the association, until its deadline | dropped and counted; a deadline or a deauthenticating check returns the station to `idle` |
| A `wsec_key` is refused | the control reply | the WiFi domain | the station deauthenticates, deletes what it installed and returns to `idle` |
| The store answers `unavailable`, or returns a blob that does not decode | the station | the configuration and the association in progress | a `secret` or `forget` fails with `eio`; an unreadable blob leaves the station with no secrets, reported |
| The SDIO host faults | `erx_sdio_sup` | EMMC2, `/data` and line 126, on which the host never signalled | restarted 3 times in 60 s, then WiFi stays down until the storage domain's next start |
| The storage domain restarts | the attachment's monitor | the network domain | the WiFi domain ends with its attachment, and its restart waits for the storage domain's facet, as at boot |
| The WiFi domain restarts | the offer's monitor in the network domain | `genet0` and every connection on it | `wlan0`'s link ends; the new chip process offers again once its firmware runs |
| The network domain restarts | the chip process's monitor of the driver | the association | the chip process offers again once a second until the network domain answers, with a new `Ref` |

Each failure ends at most the conversation it is part of, and the
recovery is a restart that exists already: the WiFi domain's, the
storage domain's or a link's.

## Refusals and error results

| Result | When |
| --- | --- |
| `sdio` `{error, no_card}` | no answer to CMD5, or a card with memory present |
| `sdio` `{error, busy}` | an attach while another client's attachment lives |
| `sdio` `{error, stale}` | a `run` whose `Ref` is not the living attachment's |
| `sdio` `{error, {I, badarg}}` | step `I` names a function the card lacks or an address of 2^17 or more; a CMD53 length that fits neither byte mode, at most 512 bytes and the function's block size, nor block mode, a multiple of the function's block size within 511 blocks; or a block size outside 1 to the smaller of 2,048 and the controller's largest block |
| `sdio` `{error, {I, host_owned}}` | step `I` writes a host-owned register |
| `sdio` `{error, {I, too_large}}` | more than 64 steps or 65,536 bytes |
| `sdio` `{error, {I, {device, D}}}`, `{error, {I, {card, Flags}}}` | the controller's or the card's error at step `I` |
| `sdio` `{error, {0, needs_attach}, []}` | a list after a device error, before the next attach |
| `ether` `{error, busy}` | a second offer of a name whose link lives |
| `ether` `{error, badarg}` | an address that is not unicast, an MTU outside 1,280 to 1,500, a credit outside 1 to 256 |
| `ctl` `einval` | a command that is not one of the seven, `ssid` and `country` without a valid argument, or `secret` and `forget` without a valid SSID and secret |
| `ctl` `eio` | `scan` or `ssid` while the chip is not running or no country is configured; `secret` or `forget` when the store is unavailable |
| the station's reasons at `/proc` | `no_country`, `no_sae_ext`, `no_candidate`, `config {Line, Key}`, `config {Line, secret_in_file}`, `store_unreadable`, `join_timeout`, `sae {Status}`, `handshake {Check}`, `install_refused`, `deauth {Reason}` |

## Untrusted input

Every byte from the chip, the air through the chip, the configuration
file, the credential store and the `ctl` commands is untrusted. Each parser is a pure core with checked
lengths and offsets and lands with its fuzz target, built for the host:

| Parser | Input | Fuzz target |
| --- | --- | --- |
| `erx_sdio_card` | R4, R5 and R6 responses | `fuzz_sdio_card` |
| `erx_sdio` | a request list, at the host | `fuzz_sdio_request` |
| `erx_bwfm_sdpcm` | function 2's headers, read-ahead and glom | `fuzz_bwfm_sdpcm` |
| `erx_bwfm_bcdc` | control replies and data headers | `fuzz_bwfm_bcdc` |
| `erx_bwfm_event` | event frames, their data included | `fuzz_bwfm_event` |
| `erx_bwfm_bss` | escan results and every information element | `fuzz_bwfm_bss` |
| `erx_wpa_key` | EAPOL-Key frames and key data elements | `fuzz_wpa_key` |
| `erx_sae` | SAE commit and confirm bodies | `fuzz_sae` |
| `erx_wpa_conf` | `wpa_supplicant.conf`, and the values of `ctl`'s `secret` and `forget` | `fuzz_wpa_conf` |
| `erx_wifi_store` | the blob the credential store returns | `fuzz_wifi_store` |
| `erx_wifi_fs` | `ctl` commands | `fuzz_wifi_ctl` |
| `erx_ether` | the `ether` messages, at the driver | `fuzz_ether` |

Every layout they read is declared once: `abi/formats/sdio.txt` (the
CMD52 and CMD53 fields, R4 and R5, the CCCR and FBR offsets and which
are host-owned), `abi/formats/bwfm.txt` (SDPCM's headers, BCDC's, the
event message, the BSS record, the escan, join and key structures, the
management-frame and authentication-status structures, the event
numbers) and `abi/formats/ieee80211.txt` (element ids, RSN and RSNXE
fields, suite selectors, the AKM table, EAPOL-Key frames and KDEs, status
and reason codes, SAE's elements). The generators produce the Erlang
records and binary patterns, and their fuzz seeds.

An SSID, a firmware version string and a `cap` string are text from an
untrusted source: they reach `/proc`, the log and the console only
through each sink's escaping function, and `ifconfig` writes an SSID
FreeBSD's way, as hexadecimal unless every byte is printable ASCII.

## Security

**Authority.** The WiFi domain holds the card's I/O through one facet,
the right to lend one named link, a read-only view of its own
configuration tree, its credential store, and its own tree. It holds no
device, register, line or DMA memory, and no grant of the network but
its medium; a compromise of its parsers gives what a radio attacker near
the board already has, the medium, plus the card's registers, which a
hostile firmware already has, and the networks' PMKs and PTs, which its
store returns to it. It reaches no other file of the data partition. The
storage domain's SDIO host parses only fixed-size responses and status
words, refuses any write to the registers its own state depends on, so
its client cannot desynchronize the bus, and never enables the
controller's signal, so its client cannot reach the shared line. The
network domain sees frames within credits and checks their sizes as for
every medium.

**Where the keys go.** The PMK, PT, KCK and KEK stay in the WiFi domain
and its store. The keys the station installs, the TK, the GTK and the
IGTK, go to the chip as the bytes of `wsec_key`'s CMD53 writes, so they
cross the storage domain: its SDIO host has them in its messages and its
memory while it writes them, and the storage domain is inside their
boundary, as the firmware that uses them is. An opaque binary hides
nothing from the domain that carries it; the storage domain is already
trusted with the data partition, and keeps no key past the list that
carried it.

**The firmware** is a non-free binary run by the chip, hostile input like
any device's: it reaches the host only through the parsers above, and an
SDIO card has no path to host memory. The host's bounds checks keep a
hostile firmware from corrupting the host; they cannot make it encrypt,
decrypt or check frames correctly. A firmware holding the installed keys
can disclose or forge traffic under them, and CCMP and BIP are only as
sound as the firmware that runs them.

**Residuals,** each recorded in [TODO.md](../TODO.md):

* **SAE is not constant-time throughout.** The three functions of
  [OTP's `crypto`](#otps-crypto-saes-arithmetic) keep every secret out of
  Erlang integers and multiply in constant time, but their point
  additions, negation, scalar sum and the SWU map's field arithmetic use
  OpenSSL's general `EC_POINT_add` and BIGNUM routines, whose time and
  branches depend on the values (`ecp_smpl.c:702-721`). PT's map runs
  once, when a secret is given, never in answer to a frame; the per
  exchange steps run in answer to the peer, which can time them over the
  air. The fix is inside the three functions: the P-256 method's own
  field and point routines, which the tree's OpenSSL holds
  (`ecp_nistz256.c:110, 250-252`) and does not export. It blocks release.
* **The development credential store is a plain file.** Before the
  vault, the PMKs and PTs sit unsealed in the WiFi domain's directory on
  the data partition, readable by any session that holds the data
  partition's tree and from a copy of the medium. The vault's state slot
  closes it; it blocks release, and the release manifest check refuses
  the development store.
* **Regulatory.** The chip enforces the CLM blob's rules for the country
  it is given; a wrong country is a legal question, not a crash.

## Facts this design does not have

These facts live only in GPL sources (the board's device tree and
Linux's SDIO and controller drivers) or only on the board. A clean-room
facts record, written by a separate agent, or the board probe settles
each; the design depends on none of them, and W0 fails safely, with
`no_card` and a log line naming this list, when one is against it.

| Fact | Where it lies | What the design does with it unknown |
| --- | --- | --- |
| **F1.** Whether GPIO 34 to 39 are in ALT3 when the firmware starts the kernel | the board probe | if not, the slot's `config.txt` sets them with `gpio=` lines, the mechanism UART3's pins use ([design-platforms.md](design-platforms.md#raspberry-pi-4-model-b)); that the firmware honours `gpio=` for these pins is *unverified* |
| **F2.** Which line `WL_REG_ON` is, its controller, polarity and power sequence delays, and its state at handover | the device tree (facts record); the board probe | if the firmware leaves it on, nothing; if it is a SoC GPIO, a `config.txt` `gpio=` line as F1; if it is on the firmware's expander, no domain reaches it (PL2): the design adds no access to the firmware's mailbox or the expander, implicit or otherwise, and any mechanism that powers the chip comes back to the architecture as a decision of its own before it is built |
| **F3.** A host-wake out-of-band interrupt line | the device tree (facts record); brcmfmac reads one from the node's `interrupts` (`of.c:132-152`) | not used: the SDIO host polls the card's in-band interrupt |
| **F4.** The legacy controller's base clock | the board probe, as for EMMC2 ([design-storage.md](design-storage.md#the-sd-host-controller), "The controller's clock") | the platform record's `clock` for the unit's entry; with none, the SDIO host refuses to attach |
| **F5.** The bus width and maximum clock the tree gives the slot | the device tree (facts record) | 4 bits at 25 MHz, which every full-speed SDIO card supports |
| **F6.** Quirks of Linux's drivers for this controller in SDIO mode, beyond FreeBSD's and OpenBSD's | facts record | FreeBSD's and OpenBSD's quirks; a failure is a W0 diagnosis |
| **F7.** Byte-mode CMD53 limits and delays after function enable in Linux's SDIO core for this chip | facts record | byte mode within 512 bytes and the function's block size (SDIO 5.3.1); function ready polled through `03h` (SDIO Table 6-1) |
| **F8.** Whether the Pi's firmware build offers `sae_ext` and the events 187 to 190, and `mfp`, and whether its external authentication and PMF work | the chip's `cap` and `mfp` answers at W1; the exchange and PMF at W5, on the board | without them SAE networks are not candidates and WPA3 is reported unsupported; another licensed Cypress build is looked for before anything else ([SAE](#sae-and-protected-management-frames)) |
| **F9.** Whether the firmware sends message 4 before applying a key requested after it | W4 on the board | the chip process keeps the order; if the firmware does not, the station waits for message 4's transmission before installing, a change to the station alone |
| **F10.** What the firmware does with no country set, which country its CLM blob then applies, and whether it takes `country` while its interface is down | the board, with the pinned firmware and CLM blob | nothing transmits until a country is configured; if `country` is not taken while down, the order becomes `up`, `country`, then the first scan, still with no scan or join before the country |

Drive strength, function 2's watermark, block sizes and save-and-restore
are settled by brcmfmac's ISC sources ([Context](#what-a-fullmac-chip-leaves-to-the-host)).

## Performance

Every byte to and from the chip passes the legacy controller's data port
as 32-bit register accesses in the storage domain, on a 4-bit bus at
25 MHz, at most 12.5 MB/s on the wire. Every non-data register write is
spaced by 6 us, two to a command, so a short command costs about 15 us
before its data. A received frame waits up to one poll period,
`sdio_poll_ms` (1 ms), before the host sees the card interrupt, then
costs, beyond its bytes, one list round trip between the storage and
WiFi domains for the status and its read, and one message to the network
domain; a sent frame costs one message from the network domain and a
list. The poll costs the storage domain one register read a millisecond
while a client is attached.
[todo-performance.md](todo-performance.md) holds the item and its
measurement: firmware load time, TCP throughput both ways and UDP
request-reply latency through an access point to a FreeBSD peer, and CPU
per megabyte in each of the three domains, with GENET's numbers on the
same board as the baseline, and the storage domain's CPU while WiFi is
idle. The fixes on the table, in the order they are cheap: a poll
period tuned to the measurement, high speed at 50 MHz, glom on transmit, a C bulk copy of the
data port, the SoC's DMA controller on DREQ 11 as FreeBSD uses it
(`bcm2835_sdhci.c:126`), and the chip process inside the network domain
([Alternatives considered](#alternatives-considered)).

## Verification

Each test names its passing case and the seeded fault that proves the
code under test ran.

**Host cores.**

* **`erx_sdio:check/2`**, a property test over random lists: every
  accepted list stays within the card's functions, addresses below 2^17,
  CMD53 lengths that fit the wire's, the function's and the controller's
  limits and the list's bounds, and writes no host-owned register.
  Seeded: the check without `07h` in the host-owned set, which the
  property fails with a write to the bus width; and byte mode bounded by
  the function's block size alone, which it fails with a 768-byte CMD53
  under a 1,024-byte block.
* **The controller core's command wait**: a block-mode CMD53 of 3 blocks
  completes after three buffer events and transfer complete, in either
  order of command complete, and EMMC2's identification commands keep
  their one-block tests. Seeded: a wait that ends its data track at the
  first block, which the 3-block case fails.
* **The SDIO host's core**: over generated sequences of attaches, lists,
  polls and rearms, its register actions write `irpt_en` only as zero
  (WF11), a poll that finds the card interrupt clears it from
  `irpt_mask` and yields exactly one notice until the next `rearm`, and a
  `run` with the previous attachment's `Ref` is refused (WF7). Seeded: an
  attach that sets the card interrupt in `irpt_en`, and a host that
  ignores `Ref`, each failing its property.
* **`erx_blk_write`'s SDIO table**: every command word it builds has the
  fields of SDIO 5.1 and 5.3, checked against OpenBSD's argument
  encoding (`sdmmc_ioreg.h:27-50`) for a table of steps; `sdio_issue/2`
  refuses an SD record and `sd_issue/2` an SDIO one. Seeded: the block
  mode bit cleared in block-mode builds, and a builder that encodes a
  block count of 0, each failing the table.
* **`erx_sdio_card`**: the bring-up from a recorded identification,
  answer by answer, to the selected 4-bit card, and to `no_card` at a
  silent CMD5. Seeded: S18R set in the second CMD5, which the step check
  refuses.
* **`erx_bwfm_sdpcm`**: headers, credit and glom against frames built
  from the layouts and against recordings from the board, with the
  credit's window across sequence wraparound; a 1,500-byte frame read
  header first is accepted, and a read-ahead whose header declares more
  than was read is refused; an Ethernet frame of ethertype `0x886c` with
  Broadcom's OUI and a well-formed event message, on the data channel
  and as a data subframe of a glom, comes back `{data, _}` (WF10).
  Seeded: a credit that ignores the window's top bit
  (`if_bwfm_sdio.c:1079-1080`), which sends past the firmware's maximum
  after a wrap; a header check that compares the declared length with the
  12 bytes of a header-first read, which the 1,500-byte frame fails; and
  a core that takes a frame's kind from its ethertype, which the
  event-shaped data frame fails.
* **`erx_bwfm_nvram`**: the converter against the conversion of the
  pinned NVRAM file computed by hand once and kept as a golden. Seeded:
  a converter that keeps comment lines.
* **`erx_wpa_kdf`**: PRF-SHA1, the PSK from a passphrase, KDF-SHA256 and
  the MICs against IEEE 802.11-2020 Annex J's vectors as wpa_supplicant's
  tests carry them, and AES key unwrap against RFC 3394's vectors.
  Seeded: the PTK's address order reversed, failing the vectors.
* **`erx_sae`**: PT and PWE against Annex J.10's vectors carried in
  `common_module_tests.c:254-259, 400-497`, then a full exchange between
  two instances, then a recorded hostapd exchange with the station's
  random values injected. Seeded: the element not negated, failing the
  exchange's confirm.
* **`erx_wifi_sta`, exhaustively.** The station is a protocol state
  machine: every sequence of its events up to a bound is explored, with
  forged, replayed and retransmitted EAPOL and SAE messages among them
  (wrong MIC, stale replay counter, different RSN element, wrong nonce,
  message 1 with a large counter, message 3 again with a higher counter
  and the same nonces, a group message again, a genuine group rekey) and
  events that do not apply (another BSS's link down, a result of another
  scan). The properties: no install action after a failed check, and no
  watermark raised by message 1 (WF8); no install action for a key equal
  to its slot's (WF9); the port open only with every negotiated key
  installed (WF4); the access point's genuine messages complete a
  handshake whatever forged message 1s came before them, once it
  retransmits its message 1; a genuine rekey installs its new key; an
  event that does not apply changes nothing; and every path back to
  `idle` within its deadline. Seeded: message 3 accepted without the RSN
  element comparison, which the exploration finds as an install after a
  downgraded element; every accepted message 3 installing its keys,
  which it finds as a reinstall after a retransmission; the watermark
  raised at message 1, which it finds as a genuine handshake shut out;
  and group message 1 checked by message 3's rule, which it finds as a
  genuine rekey refused.
* **`erx_wpa_conf`**: the subset parsed, every refusal with its line, a
  `psk` line refused as `secret_in_file`. Seeded: an unknown network key
  ignored, and `psk` taken, each failing its refusal test.
* **`erx_wifi_store`**: a blob of 16 networks round-trips; a truncated
  blob, an entry whose length runs past the blob, and a blob over 4 KiB
  are refused whole. Seeded: a decoder that trusts an entry's length,
  which the overrunning entry fails.
* **The crypto edit**: `sae_pt/3` and `sae_commit/5` against Annex
  J.10's PT and PWE; `sae_key/5` of two parties, each fed the other's
  commit, gives both the same K; `sae_commit/5`'s scalar equals
  `(Rand + Mask) mod r` computed independently in the test; off-curve
  points, out-of-range scalars and hashed values of the wrong length
  raise `badarg`. Seeded: the oct2point check skipped, which the
  off-curve case fails, and the element not negated, which the
  two-party K fails.

**Differential against independent implementations.** wpa_supplicant
2.12 and hostapd 2.12, run unmodified on the FreeBSD x86-64 test host
over FreeBSD's simulated radio, `wtap(4)`, with a known passphrase, give
recordings: with the recorded supplicant nonce and SAE scalars injected
through the station's entropy seam, erXos's message 2 and message 4 are
byte for byte wpa_supplicant's, its derived keys equal, and the same for
SAE's commit and confirm. The recordings include a retransmitted
message 3 and a group rekey, through which the station's install
actions are the recorded keys once each. That `wtap` carries hostapd on
FreeBSD 15.1 is *unverified*; if it does not, the recordings come from
the board against hostapd with a real radio. Seeded: a recording with
one byte of the access point's nonce changed, which the comparison
fails.

**The fake chip.** An Erlang process that plays the card behind the
`sdio` interface (CCCR, backplane, firmware read-back, SDPCM, BCDC
answers, events and Ethernet frames) lets the whole WiFi domain run in
hosted mode and on QEMU `virt`, whose storage domain offers the fake
through the same interface. Through it the network stack's UDP and TCP
suites run over `wlan0` unchanged, and the port test sends a frame both
ways before and after the keys. Seeded: a chip process that forwards
received data frames while the port is closed, which the port test
fails.

**The board,** by hand, as the Pi's checklist runs: W0's and W1's log
lines; no scan before a country is configured, with `no_country` at
`/proc`; a scan listing the test access point; DHCP, ping and a TCP
transfer on an open network, a WPA2 network across a group rekey, and a
WPA3 network; the wrong passphrase refused with its reason at `/proc`;
the WiFi domain killed under load, restarting and joining again while
`genet0` carries on; a multiblock write of 64 MiB to `/data` and a TCP
transfer over `wlan0` at once, both completing, with no storage request
near its deadline; the storage domain's power-cut checklist passing with
WiFi under load. QEMU has no WiFi device for any machine.

## Interfaces

* `abi/services/sdio.txt`: the `sdio` interface; `abi/services/ether.txt`:
  the `ether` interface.
* `abi/formats/sdio.txt`, `abi/formats/bwfm.txt`, `abi/formats/ieee80211.txt`:
  the layouts and tables above.
* `abi/inspection.txt`: the paths `wifi` and `wifi scan`.
* The device-kinds row `sdio sdhci` for the legacy controller.
* The Pi's manifests: the `wifi` domain, the services `wifi_sdio`,
  `wlan0`, `wifi` and `wifi_etc`, their facet rows, and the credential
  store: the vault's state slot for `wifi`, or in a development
  manifest the `data` grant of the WiFi domain's own directory, which
  the release manifest check refuses.
* The data partition's storage service: the `wifi_etc` tree, a service
  directory of its own.
* The network domain's configuration: `wlan0` with transport `ether`.
* `otp/lib/crypto`: `crypto:sae_pt/3`, `crypto:sae_commit/5`,
  `crypto:sae_key/5`.
* Erlang: `erx_sdio`, `erx_sdio_card`, `erx_sdio_host` and
  `erx_sdio_sup` in `erx_blk`; `erx_wifi` with `erx_bwfm` and its cores,
  `erx_wifi_station`, `erx_wifi_sta`, `erx_wpa_key`, `erx_wpa_kdf`,
  `erx_sae`, `erx_wpa_conf`, `erx_wifi_store` and `erx_wifi_fs`;
  `erx_ether` and
  `erx_net_ether` in `erx_net`.
* The dependency table: the Cypress CYW43455 firmware, NVRAM and CLM
  files.

## Edits to other designs

* **[design.md](design.md):** the index row for this document; a
  dependency row for the Cypress files; the license allowlist admits
  Cypress's license for those three files in the WiFi application's
  release of a Raspberry Pi image.
* **[design-shared-devices.md](design-shared-devices.md):** the legacy
  SD controller leaves the example of a device of no kind (the
  auxiliary SPI controllers remain one); it is the example of a
  sub-device's function crossing by a home.
* **[design-platforms.md](design-platforms.md):** the legacy controller's
  record is `sdio sdhci`, with no DMA memory and its clock from the unit
  entry, driven by the SDIO host, which never signals the line.
* **[design-storage.md](design-storage.md):** the SD controller's line
  keeps one member, EMMC2's device process, since the SDIO host polls
  with the legacy controller's signal enable at zero; the SDIO host's
  supervisor is a `temporary` child of `erx_blk_sup`; `erx_blk_write`
  holds the SDIO table, issued only on an `sdio` record, and the write
  path's rule (U4) covers it; the command wait of the controller core
  takes a count of blocks; the data partition's service serves the
  `wifi_etc` tree.
* **[design-network-stack.md](design-network-stack.md):** the transport
  `erx_net_ether` in the seams table, the driver table and the process
  tree; lent links are temporary and are no unit of `network_ctl`; "Who
  holds the network device" names the lending path.
* **[design-crypto.md](design-crypto.md):** `crypto` takes SAE's three
  functions, which the host oracle does not have.
* **[TODO.md](../TODO.md):** the security residuals of
  [Security](#security): the development credential store and SAE's
  arithmetic that is not constant-time throughout, each blocking
  release.
* **[plan.md](plan.md):** 1b-I's demo, part (f) with W0 to W5, its
  dependencies, its testing off the board and its exit criteria.
* **[todo-performance.md](todo-performance.md):** the WiFi item.

The unit rule, U4's build check, the manifest's property 8 (only the
network domain holds a network device) and the crypto design's rule for
the network domain stand as written.

## Alternatives considered

**The whole WiFi driver in the storage domain (S).** One crossing per
frame and no `sdio` interface. But a firmware hang or a parser fault of
the chip would end the storage domain, which remounts `/data` and stops
serving the boot medium; the storage domain would parse hostile air
input; and the supplicant's keys and `crypto` would live beside the
data partition. It mixes two subsystems in the domain whose failures
cost the most.

**The legacy controller in another domain, its firings forwarded (T).**
The storage domain's line owner would forward a hint to the WiFi domain
and wait for its answer before acknowledging the line. That changes the
unit rule ("never the registers or the line"), puts the legacy
controller's page in a second domain, and makes EMMC2's interrupts wait
on another domain's answer, so a stalled WiFi domain stalls storage: the
cross-domain acknowledgement the shared-devices design rejected.

**The legacy controller in another domain, polled (P).** The design's
host already holds the controller's signal enable at zero, so the
controller could be polled from the WiFi domain itself, saving the
`sdio` crossing per list. But its page would leave the storage domain,
which the unit rule refuses for a device on a shared line, so the rule
and the device NIF would change to exclude a device whose interrupt
output its record holds off, as the rule excludes PCIe functions, and
EMMC2 would depend on another domain keeping that hold. Kept in reserve
if measurement shows the crossings matter.

**The card interrupt on the shared line.** The SDIO host as the line's
second member, enabling the card interrupt's signal, as OpenBSD's host
does (`sdhc.c:803-812`). It saves the poll's latency and its wakeups.
But every round of storage's line would then wait for the SDIO host's
answer, so the host would owe the line a bounded answer while a CMD53
may take up to 1 s (SDIO 6.2, p.39), servicing line notices between its
polls of a transfer; and a host that ended with the signal enabled and
the card's level asserted would hold the line for EMMC2's process to
find empty at every firing, so a surviving process of the storage
domain would have to own quiescing a controller it does not drive
([design-shared-devices.md](design-shared-devices.md#failure-handling)).
Holding the signal at zero removes both obligations. Taken only if the
measured poll latency matters, with both obligations designed then.

**The chip process in the network domain (A).** One crossing per frame
fewer. The network domain would parse the firmware's formats, load the
firmware, and need a WiFi control protocol towards the supplicant's
domain for scans, joins, EAPOL frames, key installation and the port:
a second WiFi-specific interface, crossing exactly where the design has
none. It is the last fix on the performance list, taken only if the
measurement says so.

**The firmware's supplicant.** `sup_wpa 1` with the PMK handed over
(`BWFM_C_SET_WSEC_PMK`, `bwfmreg.h:312`; brcmfmac `cfg80211.c:1775-1800,
2561-2585`) would make W4 nearly free, and the firmware's own SAE from a
password (`wcc/core.c:16-20`) W5. But the supplicant runs in Erlang, the
firmware's behaviour under it is undocumented, it hides every check from
the host's tests, the firmware's SAE takes the password itself, and
Raspberry Pi OS turns both off.

**wpa_supplicant itself as C.** BSD-3 allows it, but it brings a large C
program with its own event loop and driver layer into a domain, against
principle 1 and porting by redesign.

**SAE's arithmetic in Erlang, or two generic point functions.** With no
OTP edit, or with only a point multiplication and an addition exported,
the scalar sums, the negation and the SWU map would run on Erlang
integers with secret values, in time that depends on them, and the peer
can time the per-exchange steps. Three functions, each a whole step,
keep every secret in the NIF and put the remaining constant-time work in
one place.

**Passphrases in `wpa_supplicant.conf`, as on FreeBSD.** Familiar, but
the machine's network secrets would sit on the data partition, readable
by every session that holds its tree, against the vault's rule that
secrets live on the vault's partition alone
([design-system.md](design-system.md#the-vault)). A WiFi-specific key
purpose of the vault that derived the PMK inside it would cover PSK
only: SAE needs PT in the WiFi domain for every exchange, and the TK
goes to the chip in clear either way, so a store gives sealing at rest
and one owner, which the shared state slot gives both WiFi and
Bluetooth.

**The configuration in the machine's `etc` tree.** FreeBSD's path in
the administrator's namespace too, but the WiFi domain's grant would be
the whole of `etc`, since a grant roots at a directory, and the
machine's other settings would reach a domain that parses the air.

**The firmware's default country.** Joining at once on a board with no
country configured, under whatever the CLM blob applies, which is not
verified for the pinned firmware (F10). Requiring a country costs one
configuration line and keeps the chip from transmitting under rules
nobody chose.

**The firmware on the boot partition**, beside the VideoCore's files.
The WiFi domain would then need a run-time read grant of a slot's
partition, which only the slot writer holds; in the WiFi
application's release the files are read as any application's `priv`
files.

**SDHOST for the card.** Its line is its own, which would make the
legacy controller's sharing irrelevant, but no SD function but `SD1_*`
reaches GPIO 34 to 39 (*BCM2711 ARM Peripherals*, 5.3, p.77).

## Open decisions

1. **The vault's state slot, shared with Bluetooth.** WiFi's credential
   store in the target design is a sealed state slot in the vault's
   machine file: a purpose, `{state, Service}`, whose facet's `get`
   returns the grantee's blob whole, logged as a token's release is, and
   whose `put` replaces it through the machine file's owner, answered
   after the checkpoint; the vault parses nothing of the blob and bounds
   its size. The Bluetooth design proposes the same purpose for its
   bonds, as its first open decision, through the same `get` and `put`
   seam with a development file behind it; WiFi takes that seam
   unchanged, with a blob of at most 4 KiB, Bluetooth's bound, so one
   mechanism serves both and the decision is settled once for both. The
   alternatives the Bluetooth design weighs, a purpose that knows each
   service's records or a seal-and-open purpose over a file the service
   keeps itself, would each need a WiFi variant too. Until the vault has
   the purpose, development builds keep the blob in a file, a security
   residual that blocks release. **Recommendation:** the shared state
   slot, as the Bluetooth design recommends, with one size bound for the
   purpose; until then the development file.

## Sources

Read as data on 2026-11-14; nothing was built or run. Each file with its
SHA-256.

**OpenBSD 8.0**, `sys.tar.gz` from `https://cdn.openbsd.org/pub/OpenBSD/8.0/`
(`964b1aed7839b86f4e010a0fdd03dcd409e6f569e69fe85f95e5fceb740c2aaf`), ISC:

| File | SHA-256 |
| --- | --- |
| `sys/dev/ic/bwfm.c` | `dffc156382e4d5fbe640faa53a785e38b2dc645f03bb1628e315173ab0ada142` |
| `sys/dev/ic/bwfmreg.h` | `6ac1513bd71baee17eb001b1c741cbaa441cf918d34816b4e0afbc37a82ad637` |
| `sys/dev/sdmmc/if_bwfm_sdio.c` | `134c93f19500ea0c4f6353160457eef4d7ce4ac2758a59fce92f6af0abc1fb21` |
| `sys/dev/sdmmc/if_bwfm_sdio.h` | `0b80829bf35b75815075280b3e28869ece674818b51c3ed4bdf3f8aa3912738e` |
| `sys/dev/sdmmc/sdmmc_io.c` | `bcd96f55a072291da80e04492ab9f381fd089b0113bfd59bf44a2974075991c5` |
| `sys/dev/sdmmc/sdmmc_ioreg.h` | `d574711afcf3ed3faeb575158461104fb1b29866168f1d706e9b1fca6e97bb49` |
| `sys/dev/sdmmc/sdhc.c` | `6676952662d42558f01f6e94899233a323b24a928000033741357834366e4f08` |
| `sys/dev/fdt/sdhc_fdt.c` | `1885343fc852458ad1643e0c438d8ca13278b3cd1b605e80d111ad6f07aa00c7` |
| `sys/net80211/ieee80211_pae_input.c` | `c5f57f3946d8fbf5c6466e77e97322e50d839a3504db7414f6dc9a0c455585ee` |
| `sys/net80211/ieee80211_crypto.c` | `0f9c541ab0fbcdbeb5000ca8b64432191fc876770a39d389e8d4a07b00cf3627` |

**FreeBSD releng/15.1**, commit `95719d8a895bf8170851e9844d9b4092b1d2b6fe`,
from `https://raw.githubusercontent.com/freebsd/freebsd-src/`. The
`brcmfmac` files are FreeBSD's copy in
`sys/contrib/dev/broadcom/brcm80211/brcmfmac/`, each headed
`SPDX-License-Identifier: ISC`, checked before it was read; Linux's tree
was not read.

| File | SHA-256 |
| --- | --- |
| `sys/arm/broadcom/bcm2835/bcm2835_sdhci.c` | `28c9af6fa2f549dbfc5bd239b0edd592da2df83833e021f76ff599826d8de56f` |
| `sbin/ifconfig/ifieee80211.c` | `2365247694a5fce50962a24cc05d3c3db25b64a2526b3d67924b84002dea8261` |
| `brcmfmac/bcmsdh.c` | `cec9e1a48113b009562d55348e69bfc55bd97caf1baa49fea237ec323988d8d3` |
| `brcmfmac/cfg80211.c` | `bc08b5b8ca4afef281a53a43610afdf7903ad11106dccd19202afce9c69974bd` |
| `brcmfmac/chip.c` | `38a2c3e657bdae2467f6077381fbe7171ea0b7fa9bd88a2e10d9a1225c39efbc` |
| `brcmfmac/core.c` | `6be9e2f7ca8bab0b2e747c20d22efed99f1b0b93adb6c304257c2a12e073973e` |
| `brcmfmac/common.c` | `a9d04f5f739c6b04502c5846a2c3602a4b543f66e5240e80f02b619a047bdcd3` |
| `brcmfmac/feature.c` | `6afeeeab48e2907b8f9b2f7cb6c9999fdf25c565b09847a1e6d9385d80b59b8d` |
| `brcmfmac/feature.h` | `809332a24eb3135eab24a17c9e54057284b5f5809148dcbe940bc13c157ca719` |
| `brcmfmac/fweh.h` | `d36dbcf93b7aa789d1988463915880c20405d8fa09733e021b69675d7bb7ca2c` |
| `brcmfmac/fwil_types.h` | `fa2f1b88f6b33c92a39a86bf4cfda9f368cf025347e03cf4614de9d7be46456d` |
| `brcmfmac/of.c` | `0e80aada2e487c7402aa610a3509a1d16976841250919220e592c7add2303bc4` |
| `brcmfmac/sdio.c` | `74491e8fa7326dacc9049821ed74bec2ac55338443793735e5c3bf8f3f0963ab` |
| `brcmfmac/cyw/core.c` | `46c89a25abefa2adc3445fd1408dd7643bf992f74783b3bc821fa32a29f6b107` |
| `brcmfmac/cyw/fwil_types.h` | `e700b02a130f543f12a238928f84ec9b70b238750ca15d3dfb7570b73bf4973c` |
| `brcmfmac/wcc/core.c` | `a9ce6bb39905dcbf13e4276adc7563c8e20a57768070646abcab48f6c2199885` |

**wpa_supplicant 2.12**, `https://w1.fi/releases/wpa_supplicant-2.12.tar.gz`
(`08e23937e16d0155e55cab2b51f51fbe10d80a1aa91c4e15442645059b737ef6`),
BSD-3-Clause:

| File | SHA-256 |
| --- | --- |
| `src/common/sae.c` | `1659342bbfd2ed5b0fa496cbe1feb67bbd1fff5bcd7c313724bbb140a90d8bb8` |
| `src/common/sae.h` | `11a600cf2e26ab6068ae494a3a81453f083d766f5915338902df047bc4251392` |
| `src/common/wpa_common.c` | `215b2e978ef630124f0b04cde551137b26bc29d625a58c2e63582474af81d48a` |
| `src/common/ieee802_11_defs.h` | `cfb1b7760c209b3b2d2fe60faebb2034a0e7e19574bc3f8a0f7a726eb38629ab` |
| `src/common/common_module_tests.c` | `e3879a57df7f7406bdd0c95586657a9067661b06f19889f8c03198e2694bde8c` |

**SD Specifications Part E1, SDIO Simplified Specification version
3.00**, 2018-07-25, SD Card Association
(`9e4ec3d5a003a27c1eb5721cb12e1827c022ebb989c686e3f10c989fb27adf74`),
cited as "SDIO" by section and printed page; read as a reference and not
copied.

**Raspberry Pi firmware-nonfree**, branch `trixie` at commit
`5d2295b633d94641253e16ba90fc847436fc9d4a`, from
`https://raw.githubusercontent.com/RPi-Distro/firmware-nonfree/`, the
files the fetch step pins:

| File in `debian/` | SHA-256 |
| --- | --- |
| `added-firmware/cypress/cyfmac43455-sdio-standard.bin` | `d608f866582519c0a28d86db43040f4f1b98dd1d153e72e9752586546b4a36c3` |
| `added-firmware/cypress/cyfmac43455-sdio.clm_blob` | `9823842cae9fb9a5dd1e5fb31f595516ec7deee341354bef30bb3026eee29cc1` |
| `added-firmware/brcm/brcmfmac43455-sdio.txt` | `ca709be81a78bdb6932936374f39943acbd7af07fae6151011127599a3ce9e3d` |
| `added-firmware/cypress/README.txt` | `d0d4baf89f30ffa4eb4b7af2a27818a6e1cb6e70bd1d82ffe854b0c6cc50f02f` |
| `copyright` (the Cypress license, l.2139 onward) | `07082fd0bb65e32c73af39a2292dd6c83f169be7427d338ba1fe34f9b86c0e30` |
| `rpi-brcmfmac.conf` | `2b47d6bb8dbe491be5e7f9b9b2862d12eb82eab6628319a239b1a127d1c22499` |

***BCM2711 ARM Peripherals***, build 2022-01-18
(`d6e16ea089a1716e80621f99a26e130a2379f0a81d945dc22e4f80dc49dcdc78`):
sections 4.2.1.3, 5.3 and 6.2.

**In the tree:** OpenSSL 3.5.9's `crypto/ec/ec_mult.c` and
`crypto/ec/ecp_nistz256.c`, and OTP 29.1.2's `lib/crypto`, each recorded
in its `ORIGIN.md`; the facts record
[research-sdhci-bcm2711.md](research-sdhci-bcm2711.md).
