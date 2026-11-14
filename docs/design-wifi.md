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
* **The network domain lends the link.** The WiFi domain offers its
  medium through the network domain's `ether` interface, and the stack
  runs `wlan0` as a link over `erx_net_ether` for as long as the offer
  lives. The link is up exactly while the station's port is open, so the
  stack never sees an unauthenticated network, and the network domain
  never calls `crypto`.
* **The host runs the handshakes.** The firmware's supplicant is off,
  as OpenBSD turns it off; the 4-way and group handshakes run in Erlang
  in the WiFi domain, and SAE runs there too, through the firmware's
  external authentication, with OTP's `crypto` extended by two
  elliptic-curve point functions.
* **The firmware files ship unmodified** in the WiFi application's
  release on the Pi's image, under Cypress's license, fetched at a
  pinned commit.
* **Power and wiring facts held only in GPL sources are unknowns.** The
  design depends on none of them: a card that does not answer is
  reported and the WiFi domain stops, and the board probe settles each.

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
12. [Configuration, control and inspection](#configuration-control-and-inspection)
13. [The `ether` interface and `wlan0`](#the-ether-interface-and-wlan0)
14. [OTP's `crypto`: two point functions](#otps-crypto-two-point-functions)
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
* **It shares GIC SPI 126 with EMMC2** (6.2, p.86, source 62, "EMMC &
  EMMC2"), so the two are one unit, `sd`, given whole to the storage
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
network domain free of `crypto`, the unit rule unchanged, and the storage
domain's data safe from anything the WiFi card or its client does.

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
 storage domain                 WiFi domain (wifi)                 network domain
 --------------                 ------------------                 --------------
 erx_irq_line (line 126)        erx_bwfm      the chip process     erx_net_ether
  |- erx_blk_sd   EMMC2         erx_wifi_station  station and      over erx_net_driver,
  |- erx_sdio_host legacy SD       supplicant                       interface wlan0,
     controller   <--- sdio --- erx_wifi_fs   ctl tree   --- ether --->  erx_dhcp4
                  (attach, run,                (offer, then frames,
                   card interrupt)              credits, link)
```

The WiFi domain is a configured service domain of the Pi's manifest. It
holds a facet of the storage domain's `sdio` service, through which it
alone talks to the card, and a facet of the network domain's `ether`
service, through which it lends `wlan0`. It holds no device, no unit
and no register.

Each requirement then follows:

* **The unit rule stands as written.** The legacy controller's page and
  line never leave the storage domain; the card's function crosses by a
  declared interface, the home the rule already names.
* **One issuer of commands stands.** The SDIO host issues every command
  through `erx_blk_write`, which gains an SDIO table; the build check of
  U4 is unchanged ([Commands](#commands-go-through-erx_blk_write)).
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
cross-domain acknowledgement or deadline per firing is needed. No WiFi
control protocol reaches into the network domain: scanning, joining and
keys never leave the WiFi domain, so no key handover, port-authorization
message or EAPOL forwarding crosses a boundary. No firmware file enters
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

`erx_blk_sd_host`, EMMC2's controller core (the decode of the `interrupt`
word into a closed set of events, the divider, and one transfer as a
state machine), serves the legacy controller unchanged: the quirks come
from the record, and the register access goes through
`erx_blk_sd_regs:spaced/2` as EMMC2's does. No second SDHCI model
exists.

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

### Transactions are polled

The host runs a client's transaction list with the controller's
interrupt signals off for everything but the card interrupt, polling the
`interrupt` word through each command and each block, and hands each
word to the core's transfer state machine, whose events are the same
whether a word came from a poll or from a firing. Every command and every
data block has the SD driver's deadline of 1 s, which is also the most an
SDIO register access may take (SDIO 6.2, p.39). The host takes any line
notice from its mailbox between blocks, so it adds at most one block's
transfer to a round of the line it shares with EMMC2.

### The card interrupt

The card interrupt is the only signal the host enables. An SDIO
interrupt is level-sensitive: a function holds it until the host removes
its cause, and it reaches the bus only while the function's enable and
the card's master enable in register `04h` are set (SDIO 6.3, p.40). In
the 4-bit mode it shares DAT[1], and the controller samples it only in
the interrupt period (8.1.2, p.59). When the line fires and the host's
`interrupt` word has the card-interrupt bit, the host clears the card
interrupt's status enable, so the card's level no longer holds the line,
tells its client once, and answers the line's owner done. The client
removes the cause with an access to its function's own registers, as
the specification requires (8.1.7, p.60), and its `rearm` step sets the
status enable again. OpenBSD's host does the same, masking at the firing
and setting it again at the acknowledgement (`sdhc.c:1386-1389,
803-821`). A client that never rearms loses only its own notices. The
asynchronous interrupt of version 3.00 is not in the simplified edition
(8.2, p.60), so its enable, register `16h`, stays clear.

### Supervision

The SDIO host, `erx_sdio_host`, is the one child of `erx_sdio_sup`,
which restarts it at most 3 times in 60 s and is itself a `temporary`
child of `erx_blk_sup`, started after the line's owner. A card or
controller error is a transaction's result, never the host's end, so a
misbehaving card ends nothing. A fault of the host itself, a bug,
restarts it; past the supervisor's intensity WiFi is gone until the
storage domain's next start, with one log line, and because the
supervisor is temporary its end ends nothing else in the storage domain.
The driver-control facet's unit `block` keeps naming the block driver.

## The `sdio` interface

`abi/services/sdio.txt` declares the interface, citing this section. The
manifest's service row `wifi_sdio` names the storage domain as its
server, and one facet row grants it to the WiFi domain. One module,
`erx_sdio`, is both sides: the client's calls and the host's decoder of
requests, as `erx_driver_ctl` is for driver control.

| Operation | Request | Answer |
| --- | --- | --- |
| `attach` | none | `{ok, #{functions := 1..7, ocr := Ocr}}`: the card is reset, identified and selected, and the caller is its one client; `{error, no_card}`; `{error, busy}` while another client is attached; `{error, {device, Detail}}` |
| `run` | a list of steps | `{ok, Results}`, one result per step; or `{error, {Index, Reason}, Results}`, the steps before `Index` done and their results, nothing after it run |

The steps, each one command on the card but the last two:

| Step | Command | Result |
| --- | --- | --- |
| `{read, Fn, Addr}` | CMD52 read | the byte |
| `{write, Fn, Addr, Byte}` | CMD52 write | `ok` |
| `{read, Fn, Addr, Len, incr \| fixed}` | CMD53 read | a binary of `Len` bytes |
| `{write, Fn, Addr, Bytes, incr \| fixed}` | CMD53 write | `ok` |
| `{block_size, Fn, Size}` | two CMD52 writes of the function's block-size register | `ok` |
| `rearm` | none: the card interrupt's status enable set | `ok` |

The host checks a list whole before it runs any step: at most
`sdio_steps_max` (64) steps and `sdio_bytes_max` (65,536) bytes of data
in all; `Fn` within the functions the card reported; `Addr` below
`2^17` (SDIO 6.1, p.39; 5.1, p.35); a CMD53 length that is at most the
function's block size, carried in byte mode, or a multiple of it, carried
in block mode with at most 511 blocks (5.3, p.38-39), and any other
length refused, so the client pads as OpenBSD pads a frame longer than
512 bytes (`if_bwfm_sdio.c:1121`); a block size from 1 to 2,048 (4.8,
p.31). And it refuses a write that reaches a register the host's own
state depends on:

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
`{erx_sdio, Ref, interrupt}` once per firing it saw with the card
interrupt set, `Ref` being the attachment's reference, and sends nothing
more until a `rearm` step has run.

**The attachment.** The host monitors its client. The client's end, its
domain's end included, ends the attachment: the host masks the card
interrupt and takes the next `attach`, which resets the card, so a
restarted client never meets a card half-configured by its predecessor.
The facet row's `in_flight` is 2: a client may send its next list while
one runs, and the host runs lists one after the other in arrival order,
never interleaving their steps.

## The WiFi domain

A configured service domain, `wifi`, of the Raspberry Pi's manifests, an
interpreter domain like the storage and network domains, running the
`erx_wifi` application. Its facets: `wifi_sdio` of the storage domain;
`wlan0`, an `ether` facet of the network domain; and a read-only grant
of the data partition's `etc` directory, for `wpa_supplicant.conf`. It
serves one file tree, `wifi`, to root's session. It holds no device.

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
Table 6-1), and save-and-restore where the chip reports it. A chip other
than `0x4345` at a revision other than 9 is refused, since the image
carries only the 43455's files. The boot log names the chip and
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
it says so, then reads of function 2: the 12-byte headers when the next
length is unknown, or the whole next frame when the previous frame's
software header gave it (`if_bwfm_sdio.c:1200-1300`), and `rearm` last
once function 2 has nothing more. `erx_bwfm_sdpcm` checks every header
before any field is used, as OpenBSD's checks do (`if_bwfm_sdio.c:1226-1265`):
the length and its complement, a length of at least the headers and at
most what was read, a data offset inside the frame, a glom descriptor of
whole 16-bit lengths whose sum fits the transfer, and no control frame
or glom inside a glom (`if_bwfm_sdio.c:1294-1410`); a frame that fails a
check is dropped and counted by its reason, and a header that fails ends
the read-ahead, so the next read starts from a header again. Every
software header updates the firmware's maximum sequence number, and
transmission takes at most the window between it and the next sequence
number, at most 32 frames a list (`if_bwfm_sdio.c:1077-1093`).

**Control.** One BCDC request is in flight at a time, with a request id
the reply must carry, and a reply of a length the request did not allow
is refused. A reply missing for 2.5 s, brcmfmac's wait
(`sdio.c:40`), ends the process. Callers are the station and the
process's own bring-up; a variable's name and value are built by the
caller from the generated layouts and never parsed back but by those
layouts.

**Data.** A received data frame is an Ethernet frame behind its BCDC
header. Ethertype `0x886c` with Broadcom's OUI is an event, decoded by
`erx_bwfm_event` and handed to the station; `0x888e` is EAPOL and goes to
the station; any other frame goes to the medium's client while the port
is open and is dropped, counted as `port_closed`, while it is not. Frames
from the medium's client go to the chip only while the port is open.
The station's frames, EAPOL ones, go to the chip in the order the station
sent them, before any control request the station sent after them
([Concurrency](#concurrency-and-ordering)).

**Settings.** Before the station's first command the process sets what
OpenBSD's `bwfm_init` sets (`bwfm.c:435-578`): the event mask, the
power-save mode, the join preference, `mpc`, `txbf`, up, infrastructure
mode, no access point, every offload off (`arp_ol`, `arpoe`, `ndoe`,
`toe`) and `sup_wpa` 0; and `roam_off` 1, so the firmware never roams on
its own and the station chooses every BSS, as Raspberry Pi OS asks of
brcmfmac with `roamoff=1` (`rpi-brcmfmac.conf`; brcmfmac
`cfg80211.c:7095`). When `cap` names `sae_ext`, the mask is set through
`event_msgs_ext` and includes events 187 to 190 (`cyw/core.c:17-21,
79-99`).

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
authentication frame to send, a key to install, the port opened or
closed, a report for `/proc` and a log line.

**Choosing a network.** A scan's results, with the configuration's
network blocks, give the candidates: a BSS whose SSID a block names and
whose security the block allows and the station supports. The station
joins the candidate of the highest `priority`, then the strongest signal.
Joining sets `wpa_auth`, `wsec`, `auth`, `mfp` and, for a protected
network, the station's RSN element in `wpaie`, then `join` with the BSS's
address (`bwfm.c:1985-2060`). The station keeps the RSN element and
RSNXE of the BSS the scan reported, for the checks of the 4-way
handshake.

**The port.** It opens when the pairwise and group keys are installed,
or at once for an open network, and closes at every link down,
deauthentication, disassociation, leave and failure. The chip process
reports it to the medium's client as the link
([The `ether` interface](#the-ether-interface-and-wlan0)).

**Leaving and failing.** A link down, a deauthentication or a failed
handshake closes the port, clears the keys and returns to `idle`, which
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

**Keys from passwords.** For PSK the PMK is PBKDF2-HMAC-SHA1 of the
passphrase, salted with the SSID, 4,096 iterations, 32 bytes, or the 64
hexadecimal digits of a raw PSK, computed with `crypto:pbkdf2_hmac/5`
(`otp/lib/crypto/src/crypto.erl:1028`) once per network block when the
configuration loads. For SAE the PMK comes from the exchange.

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

**The 4-way handshake.** `erx_wpa_key` decodes an EAPOL-Key frame and its
key data's elements, and builds the station's messages; `erx_wpa_kdf`
derives the PTK, computes and checks the MIC, and unwraps the key data
with AES key wrap under the KEK, written over single AES-128-ECB blocks
of `crypto:crypto_one_time/4`. The station follows OpenBSD's supplicant
side (`ieee80211_pae_input.c:188-280, 362-690`):

* **message 1** is taken only with a replay counter above the last
  accepted one (`:210-211`); the station draws its nonce from
  `crypto:strong_rand_bytes/1`, derives a temporary PTK and answers
  message 2 with its RSN element;
* **message 3** is taken only with a valid MIC under the temporary PTK
  (`:407`), a replay counter above the last accepted one (`:384-385`),
  the access point's nonce of message 1, and an RSN element equal byte
  for byte to the one the scan reported for the BSS, else the station
  deauthenticates with "RSN element different" (`:498-501`); an RSNXE in
  message 3 must equal the scan's too; the GTK and, with PMF, the IGTK
  come from the unwrapped key data (`:417`);
* **message 4** is sent, then the pairwise key, the group key and the
  IGTK are installed with `wsec_key`, in OpenBSD's order (`:535, 569-646`), and the port opens;
* **group key message 1** (`:815-860`) is checked as message 3 is, its
  key installed and message 2 answered, with the port left open.

A frame that fails a check is dropped and counted by its check; it never
changes the station's state, so a forged message costs the attacker
nothing but air time. A deauthentication follows only the checks the
source deauthenticates on: a different RSN element or an unusable
cipher.

## SAE and protected management frames

**The form.** SAE runs on the host through the firmware's external
authentication, the form of brcmfmac's Cypress-class chips
([Context](#what-a-fullmac-chip-leaves-to-the-host)), and only when the
firmware's `cap` names `sae_ext`; otherwise a network block that allows
only SAE is not a candidate, with the reason `no_sae_ext` at `/proc`
([Open decisions](#open-decisions), 2).

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
group 19 (P-256) and hash-to-element alone:

* **PT** from the SSID, the password and an optional password
  identifier, by HKDF over HMAC-SHA256 and the simplified SWU map, P1
  plus P2 (`sae_derive_pt_ecc`, `sae.c:874-1052`; `sswu`, `:635-832`),
  computed once per network block when the configuration loads, never in
  answer to a frame;
* **the commit**: PWE as a multiple of PT by a value from both
  addresses (`sae_derive_pwe_from_pt_ecc`, `:1158`), random `rand` and
  `mask` below the group's order, the scalar `(rand + mask) mod r` and
  the element, the negation of `mask x PWE` (`:1298-1384`), sent with
  status 126, hash-to-element (`ieee802_11_defs.h:233`);
* **the peer's commit** parsed and checked (`sae_parse_commit`,
  `:2203-2313`): its group 19, a scalar from 2 to `r - 1`, an element
  that decodes onto the curve, and neither equal to the station's own;
  an anti-clogging token request (status 76) sends the commit again with
  the token (`ieee802_11_defs.h:199`; `:1846`);
* **the keys**: K, the x-coordinate of `rand x (peer scalar x PWE +
  peer element)`, refused at infinity; KCK and PMK by the KDF
  (`sae_derive_keys`, `:1539-1680`);
* **the confirms**: built and checked with HMAC-SHA256 under the KCK
  (`sae_cn_confirm`, `:2314-2375`; `sae_check_confirm`, `:2439` onward).

Its states are wpa_supplicant's: nothing, committed, confirmed, accepted
(`sae.h:113-115`). Its point arithmetic is the two functions of
[OTP's `crypto`](#otps-crypto-two-point-functions); its field arithmetic
for the SWU map and its scalar sums are Erlang integers
([Security](#security), residuals). A network that offers SAE without
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
key (`cfg80211.c:2958-2961`); the firmware protects and checks management
frames with the installed keys.

## Configuration, control and inspection

**`wpa_supplicant.conf`.** The station reads `/etc/wpa_supplicant.conf`,
FreeBSD's file, through its read-only grant of the data partition's
`etc` directory, at its start and at `reconfigure`. `erx_wpa_conf` parses
a subset of wpa_supplicant's format:

* global `country=CC`; `ctrl_interface`, `ctrl_interface_group` and
  `update_config`, which configure wpa_supplicant's own control socket
  and are taken and ignored;
* `network={ ... }` blocks with `ssid` (a quoted string or hexadecimal,
  1 to 32 bytes), `scan_ssid`, `key_mgmt` (`NONE`, `WPA-PSK`,
  `WPA-PSK-SHA256` and `SAE`, a space-separated list), `psk` (a quoted
  passphrase of 8 to 63 printable ASCII characters, or 64 hexadecimal
  digits), `sae_password`, `sae_password_id`, `ieee80211w` (0, 1 or 2) and
  `priority`.

Any other key, a value outside its range or a malformed line refuses the
whole file with its line number and key, at `/proc` and in the log, and
the station keeps the configuration it had, none at its start: a key
the station does not understand may narrow what a block allows, so
reading past it would read the file wrongly. The file is at most 64 KiB.

**The country.** The station sets the configured country with the
`country` variable (brcmfmac `cfg80211.c:8452-8462`) before its first
scan, and `ifconfig wlan0 country CC` sets it until the next
configuration. With none configured, the firmware's own default from its
CLM blob applies, shown at `/proc` as the firmware answers it.

**The tree.** The WiFi domain serves `wifi`, an `erx_fs` tree with one
file, `ctl`, granted to root's session and mounted at `/net/wlan0`. A
write is one command of at most 4,096 bytes: `scan`, which answers when
the scan ends; `ssid NAME`, which joins an open network by name;
`country CC`; `leave`; and `reconfigure`. A malformed command fails the
write with `einval`.

**What `/proc` shows.** The station reports the inspection paths `wifi`,
the chip (id, revision, firmware and CLM versions, `cap`, hardware
address, country), the state and its last reason, the joined BSS, its
channel, security and signal, and counters by reason; and `wifi scan`,
the last scan's BSS records. Every SSID and every firmware string is
text from the air or the chip and reaches a sink only through that
sink's escaping function.

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
| `offer` | `#{lladdr := <<_:48>>, mtu := 1280..1500, credit := 1..256}` | `{ok, #{driver := pid(), credit := pos_integer()}}`; `{error, busy}` while an offer of this name lives; `{error, badarg}` |

An offer starts the interface's link, a `temporary` child of
`erx_net_interfaces`: `erx_net_driver` over the transport `erx_net_ether`,
whose medium is the offering process, then `erx_net_if` and, as the
network domain's configuration says for the name, `erx_dhcp4`. The
network domain's configuration keeps `wlan0`'s addressing under its
name, with `ether` as its transport. The offering process and the
driver then exchange plain messages between introduced processes,
monitoring each other:

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

## OTP's `crypto`: two point functions

SAE needs a point multiplied by a secret scalar and two points added, on
P-256, and OTP's `crypto` exports neither: its NIF multiplies the
generator only, inside key generation and ECDH (`c_src/ec.c:491, 894`).
`otp/lib/crypto` takes one edit, two functions in `crypto.erl` and their
NIF in `c_src/ec.c`:

```erlang
-spec ec_point_mul(Curve, Point, Scalar) -> Point | infinity
          when Curve :: secp256r1, Point :: binary(), Scalar :: binary().
-spec ec_point_add(Curve, Point, Point) -> Point | infinity
          when Curve :: secp256r1, Point :: binary().
```

A point is SEC1's uncompressed form, `<<4, X:32/binary, Y:32/binary>>`;
a scalar is big-endian, from 1 to the group's order less one. Every
point enters through `EC_POINT_oct2point`, which refuses one off the
curve (`c_src/ec.c:739` uses it already), so no operation runs on an
invalid point; a point not of that form, a scalar out of range, the
point at infinity as an argument and any curve but `secp256r1` raise
`badarg`. A result at infinity is the atom `infinity`, which SAE refuses
by name. Multiplication is `EC_POINT_mul` with one point and its scalar,
which OpenSSL 3.5.9 in the tree computes by its Montgomery ladder for a
secret scalar times a variable point (`openssl/crypto/ec/ec_mult.c:485-494`),
or by the P-256 method's windowed multiplication, constant-time for a
scalar below the order (`ecp_nistz256.c:605-642`), which the range check
ensures. Groups 20 and 21 add their curves to `Curve` when SAE needs
them. Nothing else of `crypto` changes, and nothing in the network
domain calls it.

## Invariants

| Invariant | Mechanism | A violation | Check |
| --- | --- | --- | --- |
| **WF1.** The legacy controller's page and line stay in the storage domain | the unit rule and the manifest check; the card reaches another domain only through `sdio` | a manifest that gives the legacy controller to another domain | the boot view's refusal of a split unit, unchanged ([design-shared-devices.md](design-shared-devices.md#the-unit-rule)) |
| **WF2.** Only `erx_blk_write` issues a command to either SD controller, and no SDIO command writes a medium | the SDIO table in `erx_blk_write`; `sdio_issue/2` and `sd_issue/2` each refuse the other kind's record | a second issuing module; an SD command on the legacy record; a CMD53 on EMMC2 | U4's build check, unchanged; host tests of both refusals |
| **WF3.** A client never writes a register the host's state depends on | `erx_sdio:check/2` refuses the list whole | a CMD52 or CMD53 write that reaches a host-owned CCCR register or a block-size register | the host core's property test over addresses and lengths, seeded below |
| **WF4.** No data frame passes between the chip and the network domain while the port is closed, and `wlan0`'s link is up exactly while it is open | the chip process gates both directions on the station's port; the link message is the port | a frame forwarded before the keys are in | the exhaustive station test and the fake chip's port test |
| **WF5.** Keys, passwords and PMKs stay in the WiFi domain, apart from the keys installed in the chip | the supplicant is a part of the station; `ether` carries frames, credits and a link state | a key in any message to another domain | the `ether` and `sdio` schemas carry no key field; a build check that the network stack calls no `crypto`, unchanged |
| **WF6.** Every byte from the chip or the air is parsed once, by a bounds-checked core with a fuzz target, before any decision | the cores of [The chip](#the-chip), [The supplicant](#the-supplicant) and `erx_sae` | a field read from an unchecked binary | the fuzz targets of [Untrusted input](#untrusted-input) |
| **WF7.** Every attachment starts from a reset card | `attach` runs the bring-up from the controller's reset for all and the card's I/O reset | a client that meets the previous client's chip state | the host test that a second attach after a client's death resets, with the fake card |
| **WF8.** No key is installed from a message whose MIC, replay counter, nonce or RSN element check failed | the 4-way handshake's checks are the only path to an install action | an install after a failed check | the exhaustive station test with forged messages |

## Concurrency and ordering

* **One owner per conversation.** The SDIO host owns the card's bus, the
  chip process the chip, the station the network state, each driver in
  the network domain its link. No two processes share state; they
  exchange messages.
* **The host serializes the card.** Lists run one at a time in arrival
  order, a list's steps back to back. EMMC2's process and the SDIO host
  run concurrently on separate controllers, joined only by the line's
  owner, which waits for both members at each firing; the SDIO host
  answers between blocks, and EMMC2's process answers unchanged.
* **The chip process orders what it sends.** Frames and control requests
  from the station reach the bus in the order the station issued them, so
  message 4 is written to function 2 before the `wsec_key` request that
  follows it on the control channel. Whether the firmware transmits a
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
| The firmware fails its read-back, does not start or stops answering control | `erx_bwfm_boot`; a 2.5 s control deadline | the storage and network domains | the WiFi domain restarts, reloading the firmware |
| A frame from the chip fails a check | the core | everything | the frame is dropped and counted; a bad header ends the read-ahead |
| A handshake or SAE message fails a check | the core | the association, until its deadline | dropped and counted; a deadline or a deauthenticating check returns the station to `idle` |
| The SDIO host faults | `erx_sdio_sup` | EMMC2 and `/data` | restarted 3 times in 60 s, then WiFi stays down until the storage domain's next start |
| The storage domain restarts | the attachment's monitor | the network domain | the WiFi domain ends with its attachment, and its restart waits for the storage domain's facet, as at boot |
| The WiFi domain restarts | the offer's monitor in the network domain | `genet0` and every connection on it | `wlan0`'s link ends; the new chip process offers again once its firmware runs |
| The network domain restarts | the chip process's monitor of the driver | the association | the chip process offers again once a second until the network domain answers |

Each failure ends at most the conversation it is part of, and the
recovery is a restart that exists already: the WiFi domain's, the
storage domain's or a link's.

## Refusals and error results

| Result | When |
| --- | --- |
| `sdio` `{error, no_card}` | no answer to CMD5, or a card with memory present |
| `sdio` `{error, busy}` | an attach while another client's attachment lives |
| `sdio` `{error, {I, badarg}}` | step `I` names a function the card lacks, an address of 2^17 or more, a length that is neither within the function's block size nor a multiple of it within 511 blocks, or a block size outside 1 to 2,048 |
| `sdio` `{error, {I, host_owned}}` | step `I` writes a host-owned register |
| `sdio` `{error, {I, too_large}}` | more than 64 steps or 65,536 bytes |
| `sdio` `{error, {I, {device, D}}}`, `{error, {I, {card, Flags}}}` | the controller's or the card's error at step `I` |
| `sdio` `{error, {0, needs_attach}, []}` | a list after a device error, before the next attach |
| `ether` `{error, busy}` | a second offer of a name whose link lives |
| `ether` `{error, badarg}` | an address that is not unicast, an MTU outside 1,280 to 1,500, a credit outside 1 to 256 |
| `ctl` `einval` | a command that is not one of the five, or `ssid` and `country` without a valid argument |
| `ctl` `eio` | `scan` while the chip is not running |
| the station's reasons at `/proc` | `no_sae_ext`, `no_candidate`, `config {Line, Key}`, `join_timeout`, `sae {Status}`, `handshake {Check}`, `deauth {Reason}` |

## Untrusted input

Every byte from the chip, the air through the chip, and the
configuration file is untrusted. Each parser is a pure core with checked
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
| `erx_wpa_conf` | `wpa_supplicant.conf` | `fuzz_wpa_conf` |
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
the right to lend one named link, a read-only view of `etc`, and its own
tree. It holds no device, register, line or DMA memory, and no grant of
the network but its medium; a compromise of its parsers gives what a
radio attacker near the board already has, the medium, plus the card's
registers, which a hostile firmware already has, and the networks'
credentials and `etc`, which it reads. The storage domain's
SDIO host parses only fixed-size responses and status words, and refuses
any write to the registers its own state depends on, so its client
cannot desynchronize the bus. The network domain sees frames within
credits and checks their sizes as for every medium.

**The firmware** is a non-free binary run by the chip, hostile input like
any device's: it reaches the host only through the parsers above, and an
SDIO card has no path to host memory.

**Residuals:**

* **SAE's field and scalar arithmetic is not constant-time.** The SWU map
  that derives PT runs on Erlang integers, in time that depends on the
  password. It runs once per network block at configuration, never in
  answer to a frame, so the air does not time it; a local observer of
  the WiFi domain's timing could. The scalar sums per exchange are
  Erlang integers too. The fix is the map in the NIF over OpenSSL's
  constant-time arithmetic.
* **Credentials are a file.** Passphrases and SAE passwords sit in
  `/etc/wpa_supplicant.conf` on the data partition, as on FreeBSD, read
  by the WiFi domain and by any session that holds the data partition's
  tree; the PMK lives in the WiFi domain's heap. A key facet of the vault
  that keeps them is [Open decisions](#open-decisions), 4.
* **The WiFi domain reads all of `etc`.** Its grant is the directory,
  since a grant roots at a directory.
* **Regulatory.** The chip enforces the CLM blob's rules for the country
  it is given; a wrong country is a legal question, not a crash, and with
  none the firmware's default applies.

## Facts this design does not have

These facts live only in GPL sources (the board's device tree and
Linux's SDIO and controller drivers) or only on the board. A clean-room
facts record, written by a separate agent, or the board probe settles
each; the design depends on none of them, and W0 fails safely, with
`no_card` and a log line naming this list, when one is against it.

| Fact | Where it lies | What the design does with it unknown |
| --- | --- | --- |
| **F1.** Whether GPIO 34 to 39 are in ALT3 when the firmware starts the kernel | the board probe | if not, the slot's `config.txt` sets them with `gpio=` lines, the mechanism UART3's pins use ([design-platforms.md](design-platforms.md#raspberry-pi-4-model-b)); that the firmware honours `gpio=` for these pins is *unverified* |
| **F2.** Which line `WL_REG_ON` is, its controller, polarity and power sequence delays, and its state at handover | the device tree (facts record); the board probe | if the firmware leaves it on, nothing; if it is a SoC GPIO, a `config.txt` `gpio=` line as F1; if it is on the firmware's expander, no domain reaches it (PL2), and powering it is a new mechanism this design does not name: [Open decisions](#open-decisions), 5 |
| **F3.** A host-wake out-of-band interrupt line | the device tree (facts record); brcmfmac reads one from the node's `interrupts` (`of.c:132-152`) | not used: the card's in-band interrupt suffices |
| **F4.** The legacy controller's base clock | the board probe, as for EMMC2 ([design-storage.md](design-storage.md#the-sd-host-controller), "The controller's clock") | the platform record's `clock` for the unit's entry; with none, the SDIO host refuses to attach |
| **F5.** The bus width and maximum clock the tree gives the slot | the device tree (facts record) | 4 bits at 25 MHz, which every full-speed SDIO card supports |
| **F6.** Quirks of Linux's drivers for this controller in SDIO mode, beyond FreeBSD's and OpenBSD's | facts record | FreeBSD's and OpenBSD's quirks; a failure is a W0 diagnosis |
| **F7.** Byte-mode CMD53 limits and delays after function enable in Linux's SDIO core for this chip | facts record | byte mode within the function's block size; function ready polled through `03h` (SDIO Table 6-1) |
| **F8.** Whether the Pi's firmware build offers `sae_ext` and the events 187 to 190, and `mfp` | the chip's `cap` and `mfp` answers at W1 | SAE networks are not candidates without them |
| **F9.** Whether the firmware sends message 4 before applying a key requested after it | W4 on the board | the chip process keeps the order; if the firmware does not, the station waits for message 4's transmission before installing, a change to the station alone |

Drive strength, function 2's watermark, block sizes and save-and-restore
are settled by brcmfmac's ISC sources ([Context](#what-a-fullmac-chip-leaves-to-the-host)).

## Performance

Every byte to and from the chip passes the legacy controller's data port
as 32-bit register accesses in the storage domain, on a 4-bit bus at
25 MHz, at most 12.5 MB/s on the wire. Every non-data register write is
spaced by 6 us, two to a command, so a short command costs about 15 us
before its data. A received frame costs, beyond its bytes, one list
round trip between the storage and WiFi domains, plus one per card
interrupt for the status, and one message to the network domain; a sent
frame costs one message from the network domain and a list.
[todo-performance.md](todo-performance.md) holds the item and its
measurement: firmware load time, TCP throughput both ways and UDP
request-reply latency through an access point to a FreeBSD peer, and CPU
per megabyte in each of the three domains, with GENET's numbers on the
same board as the baseline. The fixes on the table, in the order they
are cheap: high speed at 50 MHz, glom on transmit, a C bulk copy of the
data port, the SoC's DMA controller on DREQ 11 as FreeBSD uses it
(`bcm2835_sdhci.c:126`), and the chip process inside the network domain
([Alternatives considered](#alternatives-considered)).

## Verification

Each test names its passing case and the seeded fault that proves the
code under test ran.

**Host cores.**

* **`erx_sdio:check/2`**, a property test over random lists: every
  accepted list stays within the card's functions, addresses below 2^17,
  lengths of byte or block form and the limits, and writes no host-owned
  register. Seeded: the check without `07h` in the host-owned set, which
  the property fails with a write to the bus width.
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
  credit's window across sequence wraparound. Seeded: a credit that
  ignores the window's top bit (`if_bwfm_sdio.c:1079-1080`), which sends
  past the firmware's maximum after a wrap.
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
  machine: every sequence of its events up to a bound, forged EAPOL and
  SAE messages among them (wrong MIC, stale replay counter, different
  RSN element, wrong nonce), is explored, with the properties: no
  install action after a failed check (WF8), the port open only with
  keys installed (WF4), every path back to `idle` within its deadline.
  Seeded: message 3 accepted without the RSN element comparison, which
  the exploration finds as an install after a downgraded element.
* **`erx_wpa_conf`**: the subset parsed, every refusal with its line.
  Seeded: an unknown network key ignored, which the refusal test fails.
* **The crypto edit**: `ec_point_mul(secp256r1, G, K)` equals the public
  key that `crypto:generate_key(ecdh, secp256r1, K)` makes, for random
  `K`, an independent path through OpenSSL; `ec_point_add` agrees with a
  doubling by multiplication by 2; off-curve points and out-of-range
  scalars raise `badarg`. Seeded: the oct2point check skipped, which the
  off-curve case fails.

**Differential against independent implementations.** wpa_supplicant
2.12 and hostapd 2.12, run unmodified on the FreeBSD x86-64 test host
over FreeBSD's simulated radio, `wtap(4)`, with a known passphrase, give
recordings: with the recorded supplicant nonce and SAE scalars injected
through the station's entropy seam, erXos's message 2 and message 4 are
byte for byte wpa_supplicant's, its derived keys equal, and the same for
SAE's commit and confirm. That `wtap` carries hostapd on FreeBSD 15.1 is
*unverified*; if it does not, the recordings come from the board against
hostapd with a real radio. Seeded: a recording with one byte of the
access point's nonce changed, which the comparison fails.

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
lines; a scan listing the test access point; DHCP, ping and a TCP
transfer on an open network, a WPA2 network across a group rekey, and a
WPA3 network; the wrong passphrase refused with its reason at `/proc`;
the WiFi domain killed under load, restarting and joining again while
`genet0` carries on; the storage domain's power-cut checklist passing
with WiFi under load. QEMU has no WiFi device for any machine.

## Interfaces

* `abi/services/sdio.txt`: the `sdio` interface; `abi/services/ether.txt`:
  the `ether` interface.
* `abi/formats/sdio.txt`, `abi/formats/bwfm.txt`, `abi/formats/ieee80211.txt`:
  the layouts and tables above.
* `abi/inspection.txt`: the paths `wifi` and `wifi scan`.
* The device-kinds row `sdio sdhci` for the legacy controller.
* The Pi's manifests: the `wifi` domain, the services `wifi_sdio`,
  `wlan0` and `wifi`, their facet rows, and the read-only grant of `etc`.
* The network domain's configuration: `wlan0` with transport `ether`.
* `otp/lib/crypto`: `crypto:ec_point_mul/3`, `crypto:ec_point_add/3`.
* Erlang: `erx_sdio`, `erx_sdio_card`, `erx_sdio_host` and
  `erx_sdio_sup` in `erx_blk`; `erx_wifi` with `erx_bwfm` and its cores,
  `erx_wifi_station`, `erx_wifi_sta`, `erx_wpa_key`, `erx_wpa_kdf`,
  `erx_sae`, `erx_wpa_conf` and `erx_wifi_fs`; `erx_ether` and
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
  entry, driven by the SDIO host, the line's second member.
* **[design-storage.md](design-storage.md):** the SD controller's line
  has two members, the SDIO host's supervisor a `temporary` child of
  `erx_blk_sup`; `erx_blk_write` holds the SDIO table, issued only on an
  `sdio` record, and the write path's rule (U4) covers it.
* **[design-network-stack.md](design-network-stack.md):** the transport
  `erx_net_ether` in the seams table, the driver table and the process
  tree; lent links are temporary and are no unit of `network_ctl`; "Who
  holds the network device" names the lending path.
* **[design-crypto.md](design-crypto.md):** `crypto` takes the two point
  functions, which the host oracle does not have.
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

**The legacy controller in another domain, polled (P).** With its signal
enables held at zero, perhaps by the device NIF owning them, the
controller would never raise the shared line, and the unit rule could
exclude a device whose interrupt output its record holds off, as it
excludes PCIe functions. It saves the card interrupt's crossing, at the
cost of polling the card for frames (latency against wakeups), a change
to the unit rule and the NIF, and a coupling to EMMC2 if the hold ever
fails. Kept in reserve if measurement shows the crossings matter more
than polling costs.

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
password (`wcc/core.c:16-20`) W5. But the decision is that the supplicant
runs in Erlang, the firmware's behaviour under it is undocumented, it
hides every check from the host's tests, and Raspberry Pi OS turns both
off.

**wpa_supplicant itself as C.** BSD-3 allows it, but it brings a large C
program with its own event loop and driver layer into a domain, against
principle 1 and porting by redesign.

**SAE's point arithmetic in Erlang.** No OTP edit, but a variable-time
scalar multiplication with the secret `rand` and `mask` per exchange,
which the peer can time, and slow on the Pi. The two NIF functions cost
little and use OpenSSL's constant-time paths.

**The firmware on the boot partition**, beside the VideoCore's files.
The WiFi domain would then need a run-time read grant of a slot's
partition, which only the slot writer holds; in the WiFi
application's release the files are read as any application's `priv`
files.

**SDHOST for the card.** Its line is its own, which would make the
legacy controller's sharing irrelevant, but no SD function but `SD1_*`
reaches GPIO 34 to 39 (*BCM2711 ARM Peripherals*, 5.3, p.77).

## Open decisions

1. **Where the driver runs.** The design takes the `sdio` interface
   served by the storage domain, the chip and supplicant in a WiFi domain,
   and `wlan0` lent through `ether`. The alternatives are S, T, P and A
   above. Recommendation: this design; revisit A only on the measured
   cost of [Performance](#performance).
2. **WPA3 when the firmware lacks `sae_ext`.** If the Pi's firmware does
   not offer external authentication (F8), the choices are no WPA3, a
   newer Cypress firmware build for the 43455 if one offers it, or the
   firmware's own SAE for SAE networks alone, which hands the password to
   the firmware against the decision that the supplicant runs in Erlang.
   Recommendation: read `cap` at W1 first; if `sae_ext` is absent, look
   for a firmware build that has it before considering the firmware's
   SAE, which needs that decision revisited.
3. **The configuration file's grant.** The design grants the WiFi domain
   the data partition's `etc` read-only, attenuated from the system
   domain's `data` facet when the domain service creates the WiFi domain
   ([design-domains.md](design-domains.md#facets), "Handing a facet on").
   The alternative is a directory of the WiFi domain's own, which narrows
   the grant but moves the file from FreeBSD's path. Recommendation:
   FreeBSD's path and the `etc` grant.
4. **Credentials in the vault.** A key facet of the vault for WiFi could
   hold the passphrases and derive the PMK, so that no passphrase sits in
   a file. It covers PSK's PMK only, and SAE's password is used for PT.
   Recommendation: the file, as on FreeBSD, until a consumer needs more.
5. **Power if the firmware leaves `WL_REG_ON` off and it is on the
   expander.** Only the firmware's mailbox reaches the expander, and
   the mailbox is the kernel's (PL2). A one-shot power-on before the
   kernel starts, through `config.txt` if the firmware offers one, is the
   cheapest; a kernel operation to set one expander line is a new
   mechanism. Recommendation: settle F2 at the board probe first, and
   design nothing for power until F2 shows it is needed.
6. **The country with none configured.** The design leaves the firmware's
   default. The alternative refuses to scan or join until a country is
   set. Recommendation: the firmware's default, shown at `/proc`, with a
   log line at the first scan.

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
