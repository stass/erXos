# WiFi

The Raspberry Pi 4's WiFi chip, a Cypress CYW43455, joins open,
WPA2-PSK and WPA3-SAE networks as a station, and the network stack
carries `wlan0` over it as it carries `genet0` over the board's
Ethernet. The chip is a FullMAC chip on the SoC's legacy SD controller:
its firmware runs the 802.11 MAC, and the host loads that firmware,
speaks the chip's control protocol, runs the key handshakes and moves
Ethernet frames. To its users the system behaves as FreeBSD does:
`ifconfig wlan0 scan`, `wpa_supplicant.conf` and DHCP on `wlan0`.

Decisions every reader needs:

* **WiFi is a domain that turns an SDIO card into an Ethernet medium.**
  The **WiFi domain**, `wifi`, holds the chip, its firmware, scanning,
  joining and the supplicant. It reaches the card through a facet of the
  storage domain and lends the network domain one thing, an Ethernet
  medium with a link state
  ([WiFi is a domain that makes a medium](#wifi-is-a-domain-that-makes-a-medium)).
* **The storage domain drives the legacy controller and serves its
  card**, since the controller shares its interrupt line with EMMC2
  ([design-shared-devices.md](design-shared-devices.md#the-unit-rule)).
  A small SDIO host there brings the card up and runs lists of SDIO
  transactions for one client through the `sdio` interface; it
  understands nothing about the chip. It holds the controller's signal
  enables at zero and polls it, so line 126 stays EMMC2's alone
  ([The SDIO host](#the-sdio-host-in-the-storage-domain)).
* **The link is up exactly while the station's port is open**, so the
  stack never sees an unauthenticated network, and the network domain
  never calls `crypto` ([The `ether` interface](#the-ether-interface-and-wlan0)).
* **The station is three pure parts**: a choice, a join machine whose
  legal transitions are one table, and a failure memory that can only
  postpone a candidate the choice admitted ([The station](#the-station)).
* **The host runs the handshakes and installs each key once.** The
  firmware's supplicant is off, as OpenBSD turns it off; the station
  installs only a key that differs from its slot's, so no retransmitted
  or replayed message reinstalls a key ([The supplicant](#the-supplicant)).
* **No password equivalent enters the domain that parses the air.** A
  network's PMK and SAE password element stay with a **key holder**, a
  purpose of the vault that answers the secret steps of each join and
  never gives out the secret, as Plan 9's factotum does; only the
  administrator's session enrolls a network, and its `wlankey` command
  keeps the passphrase at its tty. Development builds run the holder
  inside the WiFi domain over a file, a residual that blocks release
  ([Credentials](#credentials); [Decisions](#decisions), 1).
* **Only a positive statement permits an open network**: a missing,
  forgotten or unanswered secret never does.
* **The chip process is the only thing that knows the chip**: nothing
  above it names a firmware variable
  ([The seam to the station](#the-seam-to-the-station)).
* **The firmware files ship unmodified** in the WiFi application's
  release on the Pi's image, under Cypress's license, fetched at a
  pinned commit.
* **Board facts held only in GPL sources are unknowns** the design
  depends on as little as it can; a card that does not answer is
  reported and the WiFi domain stops
  ([Facts this design does not have](#facts-this-design-does-not-have)).
* **Nothing transmits before a country is configured**
  ([The country](#the-country)).

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
   its default case; OpenBSD leaves a `TODO`); brcmfmac's 6 mA default
   only selects a row of that table (`sdio.c:4042-4046`). Save-and-restore is
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
* **The chip's power is the firmware's.** Its enable, `WL_REG_ON`, is
  line 1 of the firmware's GPIO expander, not a SoC pin
  ([research-wifi-pi4.md](research-wifi-pi4.md), fact 1), and no domain
  reaches the expander (PL2), so the chip runs only if the firmware
  leaves it on. That, and the pins' state at handover, are board facts:
  [Facts this design does not have](#facts-this-design-does-not-have).

### What erXos stands on

The design builds on rules other documents own: a unit goes whole to
one domain, its sub-devices reaching others only through a file tree or
a facet, and a shared line has one owner
([design-shared-devices.md](design-shared-devices.md#the-unit-rule),
[lines inside a domain](design-shared-devices.md#lines-inside-a-domain));
`erx_blk_write` is the one issuer of controller commands, U4
([design-storage.md](design-storage.md#the-sd-host-controller)); an
interface's driver is `erx_net_driver` over a transport, with credits
on every queue
([design-network-stack.md](design-network-stack.md#the-driver)); no
module of the network stack calls `crypto`
([design-crypto.md](design-crypto.md#domains-that-call-no-openssl));
no key enters a domain that uses it, which holds a key facet of the
vault instead ([design-system.md](design-system.md#the-vault)); and a
new need is an inspection path, a file tree with a `ctl` file or a
declared protocol ([design.md](design.md#decisions)).

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
| W2 | **Scan**: a scan, its results decoded into a BSS list at `/proc` with each BSS's verdict, `ifconfig wlan0 scan` printing FreeBSD's columns | choosing a network; W3; a front end that lists networks |
| W3 | **An open network**: the choice and the join machine for an open network, link up, DHCPv4, ping, UDP and TCP as on GENET | a Pi without a cable; the stack's suites on a second medium |
| W4 | **WPA2-PSK** (AKM 2, and AKM 6 where offered) with CCMP: the key holder and the `wlankey` command, the 4-way and group handshakes on the host, keys installed, group rekeying, the failure memory | most networks |
| W5 | **WPA3-SAE** (AKM 8) with hash-to-element on group 19, then the same 4-way handshake, with management-frame protection and the Transition Disable mark | WPA3-only and transition networks |

Beyond the targets: the design keeps the network stack free of WiFi, the
network domain free of `crypto`, the unit rule unchanged, the storage
domain's data and its line safe from anything the WiFi card or its
client does, the networks' secrets off the data partition, every
password equivalent out of the domain that parses what the air sends,
every passphrase out of every domain but the session that typed it, and
the right to enroll a network with the administrator alone, so that a
break of the parsers cannot add a network that outlives it.

What each behaviour rests on is in [Lineage](#lineage): the survey of
other stations (`~/erxos-history/docs-archive/research-wifi-designs.md` at history commit `e38149b`,
"the survey" below) and the facts record of iwd
([research-wifi-iwd.md](research-wifi-iwd.md), cited below as iwd fact N).

Out of scope, each a later design with its own consumer: roaming
between access points while joined ([The station](#the-station) says
where it goes, and what a board that does not move gets without it),
host-AP mode, 802.1X and EAP, power-save tuning, SAE's
hunting-and-pecking and other groups, PMKSA caching, Bluetooth on the
same chip, and SoftMAC chips, where net80211's MLME and a regulatory
table come back.

## The construction

### WiFi is a domain that makes a medium

```text
 storage domain          WiFi domain (wifi)                 network domain
 --------------          ------------------                 --------------
 erx_irq_line (126)      erx_bwfm          the chip         erx_net_ether
  |- erx_blk_sd EMMC2    erx_wifi_station  choice, join,    over erx_net_driver,
                                           memory           interface wlan0,
 erx_sdio_host legacy    erx_wifi_fs       ctl tree         erx_dhcp4
  polled, never  <- sdio -+                +---- ether --->
  on the line   attach,   |                | offer, frames,
                run,      |                | credits, link
                notices   +-- wpa_key --> key holder <-- wpa_admin -- root's session
                              names,      (vault,        set, forget  (wlankey)
                              mark,       purpose)
                              sae_commit,
                              sae_key, ptk
```

The WiFi domain is a configured service domain of the Pi's manifest. It
holds a facet of the storage domain's `sdio` service, through which it
alone talks to the card, a facet of the network domain's `ether`
service, through which it lends `wlan0`, and the station's facet of the
key holder, `wpa_key` ([Credentials](#credentials)). It holds no device,
no unit, no register, no network's secret and no right to give or
forget one: that is the administrator's facet, `wpa_admin`, which the
manifest grants to root's session.

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
* **Hostile parsing has one home, and no password lives there.** Every
  byte from the chip and from the air through it is parsed in the WiFi
  domain, whose authority is the card, the medium and a key facet that
  computes with the networks' secrets, never returns one and cannot add
  one. A break of its parsers yields the keys of the association in
  progress and the use of the facet while the break lasts, not a
  password equivalent of any saved network and not a network of its own
  choosing that outlives it ([Security](#security)).
* **Ingress is bounded where it enters.** The chip process passes the
  station at most a credit of the indications the air or the firmware
  can repeat, and drops the rest; every other indication answers one
  request of the station's. So a flooding firmware or radio costs
  dropped frames, never the station's memory or its progress
  ([The seam](#the-seam-to-the-station)).
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

Because the key holder owns each network's entry, the WiFi domain keeps
no credential store: it decodes no stored blob, tracks no state of a
store it may have failed to read, and needs no rule for a change that
was published or not. Because a secret goes from the administrator's
session to the holder, the WiFi domain relays no passphrase and needs no
rule for dropping one. Because the choice is a function and the join a
machine of its own, no state of the join depends on a scan table or a
configuration, and the rule that an event acts only where it applies is
one table instead of a rule per event.

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

Linux's driver for this controller adds no quirk to these
([research-wifi-pi4.md](research-wifi-pi4.md), facts 16 to 23, "fact N"
below). It accesses whole 32-bit words (fact 16); it substitutes the same
capabilities, 3.3 V, high speed and a 1,024-byte block, with no 1.8 V
mode (fact 20); it never sets the high-speed enable, counts the data
timeout in card clocks and uses no preset values (fact 19); and the slot
has no regulator, so its signalling stays at 3.3 V (fact 22). Against a
write lost when two land within two card clocks, it writes the block size
and count as one word and then the transfer mode with the command as one
word (fact 17), which is the order and width in which `sd_issue/2` of
`erx_blk_write` already writes `blksizecnt` and then `cmdtm`. Its spacing
differs: four card clocks after each write, only at or below 400 kHz
(fact 18). The controller record's spacing, 6 us after every non-data write at every
clock, covers the two-clock window of fact 17 at the slowest clock the
host runs, 400 kHz, and is kept.

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

The one change is to the wait: its data track, which names one block
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
OpenBSD's order (`sdmmc_io.c:73-132, 673-686, 688, 873-884`). Every
command before the last step runs at the 400 kHz identification clock,
Linux's initial rate on this controller (fact 15). Linux's core issues
the same I/O reset first and then CMD0 and CMD8 (fact 31); the host
does not, since CMD0 does not reset an I/O card and the slot holds no
memory. The bring-up drives no power line and waits for none: it takes
the chip as out of reset since before the kernel started (F2), so
Linux's 10 ms before and after power-up (fact 5) have long passed. The pure
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

**One poll.** The status enable, `irpt_mask`, admits the events the
command wait takes and the card interrupt; status bits set without a
signal, which is what a poll reads. A poll is EMMC2's delivery
(`erx_blk_sd.erl:302-316`) without the line's answer: it reads
`interrupt` once, writes that snapshot's one-to-clear bits back
(`erx_blk_sd_host:ack_mask/0`), and only then hands the snapshot to the
command wait, when a command is in flight, and performs the wait's
actions. So no later poll reads a command complete or a buffer event a
second time, which the wait would take as a second event and fail the
command on, and an event the actions cause, the next block's buffer
event once a block is moved, is set after the write-back and is not
cleared unseen. The card interrupt is not among the bits written back:
it is read-only and follows the card's level (the doc of `ack_mask/0`),
so the same snapshot's card-interrupt bit goes to the card-interrupt
rule below, whatever else the snapshot carries.

**Transactions.** The host runs a client's transaction list by polling
through each command and each block. Every command, a CMD53 with all its
blocks, has one deadline: the SD driver's 1 s from its issue
(`erx_blk_sd.erl:57-59, 231`), which is also the most an SDIO register
access may take (SDIO 6.2, p.39).

**The card interrupt.** An SDIO interrupt is level-sensitive: a function
holds it until the host removes its cause, and it reaches the bus only
while the function's enable and the card's master enable in register
`04h` are set (SDIO 6.3, p.40). In the 4-bit mode it shares DAT[1], and
the controller samples it only in the interrupt period (8.1.2, p.59).
While a client is attached and has rearmed, the host reads `interrupt`
every `sdio_poll_ms`, 1 ms, between lists, by the same poll, and when
any poll finds the card-interrupt bit it clears the bit from
`irpt_mask`, so the status no longer follows the card's level, and tells
its client once. The client removes the cause with an access to its
function's own registers, as the specification requires (8.1.7, p.60),
and its `rearm` step sets the bit in `irpt_mask` again. OpenBSD's host
masks the card interrupt in the same place at a firing and sets it again
at the acknowledgement (`sdhc.c:1386-1389, 803-821`); polling moves only
who looks, not the masking rule. A client that never rearms loses only
its own notices. The asynchronous interrupt of version 3.00 is not in
the simplified edition (8.2, p.60), so its enable, register `16h`, stays
clear.

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
longer than 512 bytes to a multiple of 512 (`if_bwfm_sdio.c:1121`).
Linux's core draws the same lines, byte mode within 512 bytes, the
controller's largest block and the function's largest block from its
CIS, which the programmed size stays within, and block mode in at most
511 blocks, and lists no Broadcom or Cypress chip among the cards
whose byte mode is limited further (facts 24 to 26). A
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
* `wpa_key`, the station's facet of the key holder
  ([Credentials](#credentials)); or in a development build a files
  service of its own that the storage domain roots at the data volume's
  `wifi/` directory and grants to the WiFi domain alone, as it serves
  SSH's `ssh_state` ([design-ssh.md](design-ssh.md#host-keys)), where
  the development key holder keeps its file.

It serves one file tree, `wifi`, to root's session. It holds no device.
The `wifi_etc` tree is granted read-write to the session templates the
manifest grants the `wifi` tree, mounted there at `/etc/wifi`, so an
administrator edits `/etc/wifi/wpa_supplicant.conf`. The tree is its own,
beside the machine's `etc` tree: the WiFi domain reads none of the
machine's other settings, and no grant but these two reaches the WiFi
configuration. The WiFi domain can write neither its configuration nor
the holder's entries, since `wpa_key` has no operation that adds or
replaces a secret, so nothing it parses can add a network that outlives
its restart.

```text
erx_wifi_sup  (one_for_all, intensity 0: restarts nothing)
 |- erx_bwfm            the chip process: the card through wifi_sdio,
 |                      SDPCM and BCDC, events, data frames, the medium
 |- erx_wifi_station    the station: the choice, the join machine with
 |                      the supplicant and SAE, the memory, the port,
 |                      what /proc shows
 |- erx_wifi_fs         the wifi tree: ctl
 |- erx_wifi_keys_dev   development builds only: the key holder, serving
                        wpa_admin to root's session
```

`erx_wifi_sup` restarts nothing: the end of any of its processes ends
the domain, and the domain service starts it again within its row's
restarts, which loads the firmware afresh. That is the one recovery, as
the storage domain's is
([design-storage.md](design-storage.md#the-sd-host-controller)): the
chip's state, the station's and the medium's are one conversation, and
rebuilding them together leaves no partial restart to reason about. A
restart loses the scan table and the failure memory, which are caches,
and nothing else: the configuration is a file and the networks' entries
are the key holder's.

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
| `erx_bwfm_mlme` | the station's requests into control requests and frames, and event records into indications for the connection in flight, or a drop ([The seam](#the-seam-to-the-station)) |

**Bring-up.** At its start the process attaches through `wifi_sdio` and
runs `erx_bwfm_boot` to a running firmware, in OpenBSD's order
([What a FullMAC chip leaves to the host](#what-a-fullmac-chip-leaves-to-the-host),
steps 1 to 3): block sizes 64 and 512, function 1 on and ready, the
chip's id and revision through the backplane window
(`if_bwfm_sdio.c:768-781, 912-950`), the PLL forced off, the cores read,
KSO on the SDIO core from revision 12, the card-control reset bit and the
PMU's resource reload, the ARM core halted, firmware written at
`0x198000` and NVRAM at the top of RAM and both read back and compared,
the core started (`if_bwfm_sdio.c:1045`), the HT clock awaited, the
host's protocol version written to the SDIO core's mailbox data word
(`if_bwfm_sdio.c:438-442`; fact 29), function 2 enabled with the
43455's watermark, the host interrupt mask, the card's
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

**Waits.** Every wait of the bring-up is the chip process's, a timer
between `run` lists and never a step, so the SDIO host holds no list
open while the chip settles. Each wait reads its register again every
10 ms until the bit it waits for is set, within a bound: a function's
ready bit in `03h` after its enable, 3 s, the bound brcmfmac gives
function 2 (fact 29), for both functions, since the host reads no CIS
and Linux's core waits up to 1 s for a card without the CIS value
(fact 28); the SDIO core's wake through KSO, 1 s, after a first 2 ms
(fact 30); and the HT clock, 1 s (fact 30). These bounds are Linux's
choices, not the vendor's, and brcmfmac rewrites and reads KSO every 50 us
where the chip process does so every 10 ms, which can delay a wake by
one poll period. A wait that runs out ends the chip process with the wait named
in the log, and the WiFi domain's restart attaches afresh
([Failure handling](#failure-handling)).

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
function 2 has nothing more or 32 frames have been read, whichever
comes first. A card whose interrupt is still asserted at the rearm
brings the next notice at the next poll, so a firmware that always has
another frame cannot keep the process from its mailbox, where the
station's requests and the network domain's frames wait. A frame is read one of two ways, as
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
(`sdio.c:40`), ends the process. Callers are `erx_bwfm_mlme`, for
the station's requests, and the
process's own bring-up; a variable's name and value are built by the
caller from the generated layouts and never parsed back but by those
layouts.

**Events.** An event-channel frame is an Ethernet frame behind its BCDC
header, which `erx_bwfm_event` takes only with ethertype `0x886c`,
Broadcom's OUI and an event message whose data length fits the frame
(`bwfmreg.h:764-786`; brcmfmac `fweh.h:365-390`); anything else on the
event channel is dropped and counted as `bad_event`. Its record goes to
`erx_bwfm_mlme`, which makes an indication of it for the station only
when it concerns the connection in flight
([The seam](#the-seam-to-the-station)).

**Data.** A data-channel frame is an Ethernet frame behind its BCDC
header. Ethertype `0x888e` is EAPOL and goes to the station as an
`eapol` indication, within the station's credit
([The seam](#the-seam-to-the-station)); any other
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

### The seam to the station

The station asks the chip process for what 802.11 calls the MAC
sublayer's management requests, and hears its confirmations and
indications; `erx_wifi_mlme` owns the records of both, and
`erx_bwfm_mlme` is the translation. Fuchsia's layer for FullMAC chips is
the same translation, from standard requests to a vendor's calls
(`wlan/lib/mlme/README.md`). The names are the standard's, with
authentication and association folded into one `connect`, since the
firmware does both:

| Request | The standard's primitive | What `erx_bwfm` does |
| --- | --- | --- |
| `{start, Country}` | none: the radio's start | `country`, then `up` ([The country](#the-country)) |
| `{scan, Ref, Spec}` | MLME-SCAN.request | an escan with a sync id it keeps for `Ref`; `Spec` names the SSIDs to probe for, those of blocks with `scan_ssid` |
| `{connect, Ref, Bss, AKM, PMF, Elements}` | MLME-JOIN, -AUTHENTICATE and -ASSOCIATE.request | `wpa_auth`, `wsec`, `auth`, `mfp`; of `Elements`, the station's RSN element and RSNXE, the RSN element in `wpaie` and the list as the association request's elements, as brcmfmac hands both (`cfg80211.c:2491-2495`); then `join` with the BSS's address (`bwfm.c:1985-2060`) |
| `{auth_frame, Ref, Frame}` | an Authentication frame of MLME-AUTHENTICATE, sent by the host | `mgmt_frame`, with a packet id it keeps |
| `{auth_result, Ref, ok \| failed}` | the host's verdict on external authentication | `auth_status` |
| `{eapol, Ref, Frame}` | MLME-EAPOL.request | a data frame of ethertype `0x888e` |
| `{set_keys, Ref, Id, Keys}` | MLME-SETKEYS.request | one `wsec_key` per key, each with its receive counter; the pairwise key with the access point's address and each group key without one, so the pairwise key and GTK key id 0 are two keys in the chip, as brcmfmac tells them apart (`cfg80211.c:2898-2917`) |
| `{delete_keys, Ref}` | MLME-DELETEKEYS.request | a `wsec_key` of zero length per installed key (`bwfm.c:2928-2938`) |
| `{disconnect, Ref, Reason}` | MLME-DEAUTHENTICATE.request | `BWFM_C_DISASSOC` (`bwfmreg.h:275`; `bwfm.c:2965`) |
| `{port, Ref, open \| closed}` | the 802.1X controlled port | the gate on data frames, and `wlan0`'s link |
| `{credit, N}` | none: flow control | returns `N` units of the station's credit (below) |

| Indication | The standard's primitive | From |
| --- | --- | --- |
| `started` | | `up` answered |
| `{scan_result, Ref, Bss}`, `{scan_end, Ref, ok \| aborted \| timeout}` | MLME-SCAN.confirm | escan result events carrying the kept sync id; `timeout` is the chip process's own (below) |
| `{connect_confirm, Ref, {ok, Sent} \| {failed, Status}}` | MLME-ASSOCIATE.confirm | the join's outcome and link-up events, for the BSS's address; `Sent` is the elements the firmware put in its association request, read from `assoc_info` and `assoc_req_ies` as brcmfmac reads them (`cfg80211.c:6494-6531`) |
| `{auth_request, Ref}` | the request for external authentication | the firmware's external-authentication request event, for the BSS's address |
| `{auth_frame, Ref, Frame}`, `{auth_tx, Ref, ok \| failed}` | MLME-AUTHENTICATE's frames | the received-frame event from that BSS; the transmit status of the kept packet id |
| `{eapol, Ref, Frame}` | MLME-EAPOL.indication | a data frame of ethertype `0x888e` from the BSS |
| `{set_keys_confirm, Ref, Id, ok \| refused}` | MLME-SETKEYS.confirm | the `wsec_key` replies of request `Id` |
| `{disconnected, Ref, By, Reason}` | MLME-DEAUTHENTICATE and -DISASSOCIATE.indication | link down, deauthentication and disassociation of the joined BSS |

**One connection, and what tags an event.** The chip process keeps one
connection for the seam: the reference of the station's last `connect`
and that BSS's address. `erx_bwfm_mlme` turns an event record into an
indication with that reference only when the record concerns that
connection, by the address, sync id or packet id the table names, and
otherwise drops it, counted as `unexpected_event`. With the channel
split above, an indication the station acts on was sent by the
firmware, on the event channel, about the station's own request; the
station's rule is then the reference and its table
([Joining](#joining)).

Sync ids, packet ids and install ids are fresh for each request, so
what they tag is exactly that request's. A BSS's address is not: the
firmware's events name no join, so a late event of an earlier
connection to the same BSS, a link down or an outcome, reaches the
connection that replaced it. The seam narrows what such an event can
do. Each request takes at most one confirmation and each connection at
most one `disconnected`, after which the chip process forgets the
connection; so a late event can only end the new join early, which the
memory takes as `bss` and the next choice recovers, or, for an open
network, open the port a moment before the firmware's own outcome,
which ends the join if the association fails. It can never install a
key or open a protected network's port: keys follow only from
EAPOL-Key frames under the new join's MIC, and that port only from
their confirmed installation.

**Credit.** Three indications are the air's or the firmware's to
repeat: `scan_result`, `eapol` and a received `auth_frame`. The station
grants the chip process `wifi_ind_credit`, 32 of them, when it starts,
and after each step that took any returns as many with `{credit, N}`;
the chip process spends one per such indication and drops one that
finds none, counted as `ind_dropped` by kind. Dropping the newest is
the policy for each because each has a retry of its own: an access
point sends its EAPOL-Key and SAE frames again, and a scan that lost
results lists fewer BSSs until the next. Every other indication answers
one request of the station's, at most once, so those are as many as the
requests in flight, a handful. While the station waits up to 2 s for
the key holder ([Concurrency](#concurrency-and-ordering)), at most 32
repeatable indications and that handful wait in its mailbox, whatever
the firmware or the air sends.

**A scan always ends.** The chip process answers every scan with one
`scan_end`: the firmware's, or its own `timeout` 10 s after it started
the escan, erXos's bound, to be tuned on the board; then it forgets the
sync id, so a later result is dropped as `unexpected_event`. A
firmware that never ends a scan costs one scan, not the radio.

Nothing above the seam names a firmware variable, command or event
number: only `erx_bwfm` and its cores include `abi/formats/bwfm.txt`'s
generated headers, and no other module but the supervisor calls one of
them, which a build check holds. A second chip, or a SoftMAC chip with an MLME of the host's,
replaces the chip process and nothing else. The seam is these few
requests and no table of optional driver operations: wpa_supplicant's
driver interface has 193 (`driver.h:3543`), drawn around every driver's
features, and erXos has one chip.

## The station

`erx_wifi_station` is one process around one pure function,
`erx_wifi_sta:step(State, Event, Ctx) -> {State, Actions}`. The process
performs the actions, owns the timers, and gives every step the time
and 32 fresh random bytes in `Ctx`; the function reads nothing else.
It is made of three parts, each a pure module with one job, and a thin
lifecycle around them:

| Part | Interface | Decides | Keeps |
| --- | --- | --- | --- |
| the choice, `erx_wifi_choose` | `choose(View) -> #{verdicts := [{Bss, Verdict}], pick := Candidate \| none}` | which BSS to join, and for every other BSS seen why not | nothing |
| the join machine, `erx_wifi_join` | `step(Join, Event, Ctx) -> {Join, Actions}` | one join, from the request to an open port: SAE, the handshakes, rekeys, the port, and how the join ended | the association's state |
| the failure memory, `erx_wifi_memory` | `fail/3`, `ok/2`, `held/3` | which BSS and which secret failed lately, and until when each is held | a bounded map |
| the lifecycle, in `erx_wifi_sta` | the step above | whether the radio is up, when to scan, when to ask the choice, and the `ctl` commands | the configuration, the names, the marks it has learned, the scan table, `want` |

The split is Fuchsia's, which keeps policy, the connection states and
the roam monitor apart (the survey, "Fuchsia"), without its components
and protocols: here the parts are functions of one process, so they
share no interface but their arguments.

Events are a closed set: the chip process's indications
([The seam](#the-seam-to-the-station)), the key holder's answers
([Credentials](#credentials)), the configuration read, a `ctl` command
and a deadline. Actions are a closed set too: a request to the chip
process, a request to the key holder, a report for `/proc` and a log
line.

### Choosing a network

The choice is a function of one value, the **view**: the
configuration's network blocks, the **names**, the **marks** the
station has learned, the last scan's BSS table, the memory, `want`,
what the chip can do (`sae_ext` in `cap`, and whether it answers
`mfp`) and the time. It returns a verdict for every BSS in the table
and at most one pick. The verdicts are what `/proc` shows
([Control and inspection](#control-and-inspection)), so what a front
end reads and what the station acts on are one value.

**The names** are the key holder's last answer, and one of two values,
never a third: `unavailable`, when the holder has not answered, or
`{ok, Entries}`, which SSIDs it has which secrets for and which it has
marked SAE-only ([Credentials](#credentials)). Only the second says
that an SSID has no secret. **The marks** are the SSIDs whose access
point has disabled its transition in this run of the station
([The 4-way handshake](#the-4-way-handshake)); an SSID is SAE-only when
the names or the marks say so.

**A network is known** when a block names its SSID or the names list a
secret for it. A network with a secret and no block has the default
block: every value a block may leave out
([Configuration](#configuration-credentials-and-control)). So one
`wlankey set` makes a network joinable, which is what a front end needs
to offer a network from the scan list, and one passphrase serves a
network's WPA2 and WPA3 access points alike, as one iwd profile does
(iwd facts 13 and 31). `want` narrows the known networks: `any`, every
one; `{only, SSID}`, that one; `{open, SSID}`, the open network of that
SSID alone, whatever a block or the names say of it; `none`, no network.

**Open is a statement, never an absence.** An open BSS is admitted for
exactly two reasons: a block whose `key_mgmt` is `NONE`, or `want`
`{open, SSID}`, which only `ctl`'s `ssid NAME open` sets
([Control and inspection](#control-and-inspection)). Nothing else
admits one: not an SSID that no block and no secret names, not a secret
forgotten, not the names `unavailable`. So no state of the key holder,
and no change to the entries, turns a protected network into an open
one; an impostor that advertises a saved SSID without protection is
refused `not_open` whatever the holder answers.

**Admission.** For each BSS of a wanted network, `admit/4` decides the
protection of management frames and the AKM, or refuses the BSS, from
the block, the SSID's names and marks, the BSS's RSN element and RSNXE,
and the chip. A block is open or protected, never both
([Configuration](#configuration-credentials-and-control)): an open
block, or `want` `{open, SSID}`, takes an open BSS alone and refuses a
protected one `akm_unsupported`; every other wanted network takes a
protected BSS alone and refuses an open one `not_open`. For a protected
BSS, PMF comes first:

| Block's `ieee80211w` | The BSS's RSN capabilities | The firmware answers `mfp` | PMF |
| --- | --- | --- | --- |
| 2 | MFPC set | yes | required |
| 2 | MFPC set | no | the BSS refused |
| 2 | MFPC clear | any | the BSS refused |
| 1 | MFPR set | yes | required |
| 1 | MFPR set | no | the BSS refused |
| 1 | MFPC set, MFPR clear | yes | capable |
| 1 | MFPC set, MFPR clear | no | none |
| 1 | MFPC clear | any | none |
| 0 | MFPR set | any | the BSS refused |
| 0 | MFPR clear | any | none |

The refusals by the BSS's capabilities are wpa_supplicant's, a BSS
without MFPC under a block that requires PMF and a BSS that requires it
under a block that disables it (`events.c:787-802`); a firmware that
does not answer `mfp` protects no management frame, so PMF that the
block or the BSS requires refuses the BSS there. Then the AKM: of the
AKMs the block allows, the BSS offers and the station supports, those
whose own secret the names list, a PSK for PSK and PSK-SHA256 and an
SAE secret for SAE, and, for SAE, only with `sae_ext` in `cap`,
hash-to-element in the RSNXE and PMF not `none`; and for an SSID that
is SAE-only, never PSK or PSK-SHA256. Of those the station takes SAE,
then PSK-SHA256, then PSK, the order of wpa_supplicant's selection
(`wpa_supplicant.c:2140-2169`); none left refuses the BSS. With the
names `unavailable` no secret is listed, so every protected BSS is
refused `keys_unavailable`.

Every verdict is one of a closed set:

| Verdict | Meaning |
| --- | --- |
| `joined` | the BSS of the open port |
| `{candidate, AKM, PMF}` | admitted and not held |
| `{held, bss \| secret_failed, Until}` | admitted, and postponed by the memory until `Until` |
| `unknown` | the names are `{ok, _}`, and no block and no secret names its SSID |
| `{refused, Reason}` | `not_wanted`, `no_secret`, `keys_unavailable`, `sae_only`, `no_sae_ext`, `no_h2e`, `pmf_required`, `pmf_unavailable`, `akm_unsupported`, `cipher_unsupported` or `not_open` |

`no_secret` and `unknown` are what a front end offers a passphrase
for; wpa_supplicant asks for a missing secret through a prompt in its
control protocol (`README:719-745`) and iwd through an agent (iwd fact
11), and neither is needed when the reason is state someone reads.
`keys_unavailable` is the verdict of every protected BSS, and of every
BSS whose SSID no block names, while the names are `unavailable`: the
station cannot then tell a network it has no secret for from one whose
secret it cannot reach, so it says neither.

**The pick** is the candidate of the highest `priority`, then the
strongest signal, then the lowest address. A held BSS is never the pick.

**Failure never changes admission.** `admit/4` takes no memory, so what
is admitted, and with which AKM and PMF, is the same after any history
of failures: the memory only turns a candidate into a held one. An SAE
exchange or a handshake that fails ends the join, and the next choice
decides by the same table, so the station never tries PSK on a BSS
because SAE failed there. A block that allows SAE alone never joins
with PSK, and one that requires PMF never joins without it. A block
that allows both accepts a downgrade: an attacker in range that
advertises the SSID with PSK alone is a candidate, and although it
cannot complete the 4-way handshake without the PMK, the station's
message 2 carries a MIC under a KCK that follows from the PMK, the two
nonces and the two addresses ([The 4-way handshake](#the-4-way-handshake)),
against which the attacker tests guesses of the passphrase offline;
where the SAE password is the same passphrase, a right guess gives it
too. That exposure is the price of allowing PSK, as it is under
wpa_supplicant. Two things end it: a block of `key_mgmt=SAE` alone, and
the network's own word that its transition is over, the Transition
Disable indication, after which the SSID is marked SAE-only for good
([The 4-way handshake](#the-4-way-handshake)).

### Joining

`erx_wifi_join` takes one candidate to an open port and keeps it open
until the link ends. It holds the supplicant's state
([The supplicant](#the-supplicant)) and SAE's
([SAE](#sae-and-protected-management-frames)); its cores are pure
functions it calls.

| State | Meaning |
| --- | --- |
| `idle` | no join |
| `joining` | the connect request is issued; its confirmation, or the request for external authentication, is awaited |
| `sae` | the SAE exchange runs: committed, then confirmed |
| `keys` | associated; the 4-way handshake runs, then the keys go to the chip |
| `open` | every negotiated key is installed and confirmed, and the port is open |
| `rekey` | the port stays open under the installed keys while a 4-way handshake for a new PTK runs |

Every join has a reference the lifecycle makes, and every indication of
the chip process and every answer of the key holder carries the
reference of the join it belongs to. An event with another reference is
dropped and counted as `stale`. Then one table, `erx_wifi_join:table/0`,
says where each kind of event applies and which states may follow:

| Event | `idle` | `joining` | `sae` | `keys` | `open` | `rekey` |
| --- | --- | --- | --- | --- | --- | --- |
| `join`, the lifecycle's pick | `joining` | | | | | |
| `leave`, the lifecycle's | | `idle` | `idle` | `idle` | `idle` | `idle` |
| `connect_confirm` | | `keys`, `open`, `idle` | `keys`, `idle` | | | |
| `auth_request` | | `sae`, `idle` | | | | |
| `auth_frame`, a received SAE frame | | | `sae`, `idle` | | | |
| `auth_tx`, a sent frame's status | | | `sae` | | | |
| `key`, the key holder's answer | | | `sae`, `idle` | `keys`, `idle` | | `rekey`, `idle` |
| `eapol`, a received EAPOL-Key frame | | | | `keys`, `idle` | `open`, `rekey`, `idle` | `rekey`, `idle` |
| `set_keys_confirm` | | | | `keys`, `open`, `idle` | `open`, `idle` | `rekey`, `open`, `idle` |
| `disconnected` | | `idle` | `idle` | `idle` | `idle` | `idle` |
| `deadline` | | `idle` | `sae`, `idle` | `idle` | | `open` |

An empty cell is an event that does not apply: `step/3` drops it,
counts it as `unexpected_event` and changes nothing. A filled cell names
a handler and the only states it may leave the machine in; `step/3`
looks the cell up before it calls the handler and checks the handler's
state against it after, and a state outside the cell ends the station,
which is a bug the exhaustive test finds first
([Verification](#verification)). The dispatch and the test read the same
term, so the table is the one statement of the machine's edges, as
Fuchsia's `statemachine!` list is for its client states
(`state/mod.rs:138-150`). It is an Erlang term because Erlang alone
reads it; a second reader in another language would move it to `abi/`.

What the cells do:

* **`join`** issues `connect` for the candidate's BSS with its AKM, PMF
  and, for a protected network, the station's RSN element and, for an
  SAE join, its RSNXE with the hash-to-element bit; and keeps the RSN
  element and RSNXE the scan reported for the BSS, for the checks of
  the 4-way handshake.
* **`connect_confirm`** that succeeds opens the port at once for an
  open network and otherwise moves to `keys`, keeping `Sent`, the
  elements the association request carried; one whose `Sent` holds an
  RSN element other than the station's own ends the join, since the
  access point would compare message 2 with it. For an SAE join it is
  taken only from `sae` with the exchange accepted, and one that
  arrives in `joining` ends the join, since no key exists. One that
  fails ends the join.
* **`auth_request`** starts SAE for an SAE join and ends any other.
* **The key holder's answers** arrive where they were asked for: the
  commit and the exchange's KCK in `sae`, a PTK in `keys` or `rekey`.
  The process performs a request to the key holder by calling it and
  hands the answer to the step before any other event
  ([Concurrency](#concurrency-and-ordering)), so the machine never
  sees another event between a request and its answer. An answer of
  `unavailable` ends the join.
* **`eapol`** in `open` is a group message 1, which installs and stays
  in `open`, or a message 1, which starts a rekey and moves to `rekey`
  ([The 4-way handshake](#the-4-way-handshake)).
* **`set_keys_confirm`** confirms the install it names; when every
  negotiated key is then confirmed in its slot it opens the port from
  `keys` and ends a rekey from `rekey`; one that is refused ends the
  join.
* **`disconnected`**, the firmware's link down or the access point's
  deauthentication or disassociation, ends the join in every state.
* **`deadline`** ends the join in `joining` and `keys`; in `sae` it is
  the exchange's own, which sends a frame again or ends, and once the
  exchange is accepted it is the connect's, which ends the join; one that comes
  before its time is dropped, counted as `early_deadline`, and takes no
  edge, as a handler takes none for any event it refuses. In `rekey` it
  drops the pending PTK and returns to
  `open` under the keys still installed: a message 1 has no MIC, so a
  forged one may start a rekey, and must not end the association. A
  genuine rekey that stalls is the access point's to end, which it does
  by deauthenticating.

**The port.** It opens when every negotiated key is installed and
confirmed ([The 4-way handshake](#the-4-way-handshake)), or at
confirmation for an open network; it is open in `open` and `rekey`, and
closes when the join ends, whatever ended it. The chip process reports
it to the medium's client as the link
([The `ether` interface](#the-ether-interface-and-wlan0)).

**What the states exclude.** A scan runs only in `idle` and `open`
([Scanning and the lifecycle](#scanning-and-the-lifecycle)), so no scan
takes the radio while any handshake runs, the first or a rekey; and
every state in which a handshake waits on the access point, `joining`,
`sae`, `keys` and `rekey`, has a deadline cell, so no wait is without
an end.

**Deadlines.** The connect's answer within 10 s; SAE's exchange within
5 s, each frame sent again after 1 s at most twice; the 4-way
handshake's first message within 10 s of association and each later one
within 5 s, for a rekey as for the first. These are erXos's values, to
be tuned on the board; nothing depends on their exact size.

**How a join ends.** A join that ends closes the port, issues
`disconnect` unless the chip reported the disconnection, deletes every
installed key, empties the key slots, the pending PTK and the
watermark, and returns to `idle` with one action for the lifecycle,
`{ended, Class, Reason}`. The class is all the memory reads:

| Class | When |
| --- | --- |
| `secret` | the station sent a value against which a guess of the secret can be tested offline, and the join ended before the peer proved that it knows the secret: for PSK and PSK-SHA256, message 2 was sent and no message 3 verified, wpa_supplicant's test for a likely wrong key (`events.c:5092-5114`); for SAE, the station's confirm was sent and no peer confirm verified, whether the peer's confirm failed, the peer answered with a failure status, the exchange's deadline passed or the link ended. Also an SAE commit the peer answers with status 123, an unknown password identifier (`ieee802_11_defs.h:231`) |
| `bss` | every other end before the port opened, and a port that closed within `wifi_short_link` (10 s) of opening, as an access point that steers a station to another band does |
| `none` | `leave`; an end the key holder's `unavailable` caused; a port that closed later than `wifi_short_link` |

So the `secret` class counts exactly the exchanges that gave someone a
test of the secret, whoever ended them: an impostor that answers the
station's SAE commit, receives its confirm and then stays silent has
tested one guess, and that exchange counts against the SSID as one a
wrong password ends does. What the class records is a suspicion, not a
proof: a lost frame ends an exchange the same way, and the verdict says
`secret_failed`, never "wrong password". How a wrong PSK shows on this
firmware, a deadline or a deauthentication, is F11 of
[Facts](#facts-this-design-does-not-have); both are the `secret` class.

### Failure memory

`erx_wifi_memory` is one bounded map from a key to a count and a time:

| Key | Counted by | Held | Forgotten |
| --- | --- | --- | --- |
| `{bss, BSSID}` | a join of that BSS ended `bss` or `secret` | from the first: 10 s, doubling with each consecutive failure to 300 s | when the BSS's port has stayed open `wifi_short_link`; an hour after its hold ended; at `reconfigure` and `ssid` |
| `{secret, SSID}` | a join of that SSID ended `secret` | from the third consecutive one: 300 s, doubling to an hour | when a port of the SSID has stayed open `wifi_short_link`; at `names`, `reconfigure` and `ssid` |

A held BSS, and every BSS of an SSID whose secret is held, is not a
candidate until the hold ends; the verdict says which and until when.
Holds are compared with the time at each choice, so the memory has no
timer of its own, as iwd's blocklist has none (iwd fact 20). It holds at
most 32 BSS records, dropping, of the others, the one whose hold ends first, and one
record per SSID with a secret. A restart of the domain empties it.

What the memory is for:

* **An access point that fails does not block the others.** Every
  station surveyed remembers failures per BSS (the survey, idea 2).
  After a failed join the lifecycle scans at once, the failed BSS is
  held, and another BSS of the SSID, or the next network, is the pick.
* **A failing secret is not tried without end.** With a passphrase
  that has changed, every join fails the same way; and every exchange
  of the `secret` class gave whoever answered it one test of a guess
  of the password, an impostor that went silent included
  ([Joining](#joining)). After three such ends the SSID's secret is
  held, the verdict of its BSSs is `{held, secret_failed, Until}`,
  which a front end shows as "authentication failed: the password may
  be wrong", and attempts fall to one an hour. A new secret ends the
  hold at once: `wlankey` writes `names` once the holder has it
  ([Credentials](#credentials)).
* **The hold ends without an administrator.** Android disables a
  network after a wrong password until the user acts (the survey,
  "Android"). An impostor within range can make any join fail, so a
  hold that only a person could end would turn a few minutes of radio
  interference into an outage of an unattended board; a hold with a
  ceiling ends an hour after the interference does
  ([Decisions](#decisions), 2).
* **The memory paces retries.** A network whose only access point
  fails is tried again when its hold ends, at 10 s and then less often,
  so no other backoff follows a failed join.

The security level is no input of the memory and the memory none of
`admit/4`, so no failure, forged or real, moves a join to a weaker AKM.
OpenBSD's single score, which adds a bonus for an access point that
never failed to bonuses for RSN and privacy
(`ieee80211_node.c:448-551`), is the coupling this keeps apart.

### Scanning and the lifecycle

The lifecycle's own state is small: the radio, `down` or `up`; the scan
in flight, if any, with the `ctl` writes waiting for it; `want`; the
names; the marks; and the credit it owes the chip process.

* **The radio is down** until the chip process has been handed a
  country and reports the firmware's interface up
  ([The country](#the-country)). While it is down the station takes the
  configuration and the `ctl` commands that need no radio, and sends no
  scan or connect.
* **A scan runs only while the join machine is `idle` or `open`.** One
  scan is in flight at a time, and a `scan` command that finds one
  waits for it with the others. During a join the command fails with
  `ebusy`: the radio is the join's, the reduced form of iwd's queue of
  radio work in which a connect goes before every scan (iwd fact 6).
  Whether the firmware scans while associated is F13 of
  [Facts](#facts-this-design-does-not-have).
* **The station scans when a choice is due:** when the radio comes up;
  when a join ends; after `names`, `ssid` and `reconfigure`; when the
  earliest hold of an admitted BSS ends; and otherwise, while `idle`
  with `want` not `none`, every `wifi_scan_min` (1 s) doubling to
  `wifi_scan_max` (60 s) for as long as no scan yields a pick.
* **The names are read before every choice**, by the holder's `names`,
  so an entry the administrator gave or forgot takes effect at the next
  choice whether or not `names` was written to `ctl`; the command only
  makes it take effect at once.
* **A scan that ends**, by the firmware's end, an abort or the chip
  process's `timeout`, replaces the BSS table with what it found: at
  most `wifi_bss_max` (64) records, one per BSSID, the strongest kept
  when more were seen and the rest counted as `bss_dropped`. With the
  machine `idle` the lifecycle then asks the choice and joins its pick
  with a fresh reference; with the machine `open` it replaces the
  verdicts and changes nothing else.
* **A join's end** goes to the memory by its class, and a port that has
  stayed open `wifi_short_link` clears the records of its BSS and SSID.
* **`want`** is `any` at the start and after `reconfigure` and `ssid -`;
  `ssid NAME` makes it `{only, NAME}` and `ssid NAME open` makes it
  `{open, NAME}`; `leave` makes it `none`, which keeps the station out
  of every network until one of the others, as iwd's disconnect turns
  its automatic joining off (iwd fact 27).
* **A join the view no longer admits is left.** After every change of
  the view, of `want`, the configuration, the names or the marks, the
  lifecycle asks `admit/4` again for the joined BSS, and leaves it when
  the answer is no longer the join's AKM and PMF: a forgotten secret, a
  narrowed `want`, a block that no longer allows the AKM, or a mark that
  forbids PSK.
* **A Transition Disable indication** the join reports, as
  `{transition_disable, SSID}`, enters the marks at once and is sent to
  the holder as `mark` ([Credentials](#credentials)).

**A board that does not move needs no roaming.** When the access point
in use fades or fails, the link ends, the station scans, and the choice
takes the best BSS in range, another access point of the same network
first if the memory holds the old one. That costs a scan and a join,
seconds, which a kiosk or a desk tolerates. While a port is open the
station looks for nothing better, and the firmware's own roaming is off
(`roam_off`, [The chip](#the-chip)), so one part alone ever chooses a
BSS; FreeBSD's `roaming` switch between two choosers, which the
supplicant must set and restore (`driver_bsd.c:1409-1412, 1757`), has no
counterpart.

**Where roaming goes.** A later design adds a fourth pure part, a roam
function of the link's signal and the scan table that emits one event,
`{roam, Candidate}`, and one state of the join machine that executes
it, as Fuchsia's roam monitor stands apart from its `Roaming` state
(`stationary_monitor.rs`; `state/mod.rs:119, 146`). It decides first
whether the link is sufficient, so that scans, which interrupt traffic
on one radio, stay rare (the survey, idea 9), and it can take iwd's
practice whole: neighbour reports fetched at association, a signal
threshold with hysteresis, the access point's transition requests as
hints, and fast transition (iwd facts 21 to 24). Nothing here changes
for it but one row and one column of the table.

## The supplicant

The supplicant is a part of the join machine: its cores are pure
functions the machine's step calls, and its state is the join's.

**Keys from secrets.** A network's long-term keys are made and kept by
the key holder ([Credentials](#credentials)), never by the supplicant.
For PSK the PMK is PBKDF2-HMAC-SHA1 of the passphrase, salted with the
SSID, 4,096 iterations, 32 bytes, or the 64 hexadecimal digits of a raw
PSK; for SAE, PT ([SAE](#sae-and-protected-management-frames)). The
PMK, and the two hashed values PT is made of, are computed once, in the
administrator's session by `wlankey`, when the network's secret is
given ([Credentials](#credentials)); the holder makes PT and keeps
both, and the passphrase reaches no other domain and is kept nowhere.
For SAE the PMK comes from the exchange and
stays with the holder too. The supplicant asks the holder for each PTK,
naming the SSID, the AKM, the two addresses and the two nonces, as
9front's supplicant asks factotum (`wpa.c:474-520`), and holds the
answer: the PTK's KCK, KEK and TK.

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
and builds the station's messages; `erx_wpa_kdf` computes and checks
the MIC, comparing with `crypto:hash_equals/2`, and unwraps the key
data with AES key wrap under the KEK, written over single AES-128-ECB
blocks of `crypto:crypto_one_time/4`, refusing data whose integrity
value does not unwrap. Its PMK and PTK derivations are the key
holder's arithmetic ([Credentials](#credentials)), which the join
machine never calls. The station follows OpenBSD's supplicant side
(`ieee80211_pae_input.c:188-280, 362-690, 815-980`).

### The key slots

For each association the join machine keeps three things, all emptied
when the association ends:

* **the replay watermark**, the replay counter of the last EAPOL-Key
  frame it accepted under a valid MIC, or none. Every handshake message
  must carry a counter above it (`:210-211, 384-385, 835-838`), and only
  an accepted message 3 and an accepted group message 1 raise it
  (`:526-527, 967`). Message 1 carries no MIC, so it never raises it: a
  forged message 1 with a large counter cannot shut out the access
  point's own later frames;
* **the pending PTK**, the ANonce, the SNonce and the PTK the key holder
  derived from them at the last accepted message 1 (`:255-265`), under
  which message 3's MIC is checked; a new message 1 replaces it;
* **the key slots**, for each slot the key the chip was last asked to
  hold, the id of the install that asked for it, and whether that
  install is confirmed, or none: the pairwise slot, the GTK slots of
  key ids 0 to 3, which the Key ID field's two bits name
  (`rsn_supp/wpa.c:1692`), and the IGTK slots of key ids 4 and 5. The
  pairwise slot and GTK slot 0 are two slots, as the chip holds two
  keys for them ([The seam](#the-seam-to-the-station)).

**A key is installed once.** An accepted message yields the keys it
carries, and the machine's `set_keys` request holds exactly those of
them that differ from their slot's key, confirmed or not; a key equal
to its slot's yields nothing. Each request carries an install id, a
count kept by the join, and each slot it fills records that id as
unconfirmed. A `set_keys_confirm` names its install id and confirms
only the slots that still record it: a slot that a later install has
filled again waits for that install's confirmation, so a delayed
confirmation of an earlier install never confirms a later key. Each install carries the key's receive
counter, the GTK's from the frame's Key RSC and the IGTK's packet number
from its KDE, as OpenBSD carries them (`:605, 642`), written into
`wsec_key`'s receive IV with its initialized flag, as brcmfmac writes a
key's sequence (`cfg80211.c:2919-2934`); the pairwise key starts from
zero. So:

* a retransmitted message 3, which the access point sends with a higher
  counter (`ap/wpa_auth.c:2215`) and the pending PTK's nonces, yields
  the PTK already in the pairwise slot and installs nothing, whether or
  not the chip has answered the first request;
* a retransmitted group message yields the GTK and IGTK already in
  their slots and installs nothing;
* a replayed message, one an attacker recorded and sends again, carries
  a counter no higher than the watermark, which the accepted original
  raised, and is refused before any key is read (WF8); so a key that a
  newer one has replaced in its slot, which only a replay could bring
  back, is never installed again;
* a rekey still installs: a new message 1 draws a new SNonce, so the PTK
  it leads to differs from the slot's, and a new GTK differs from its
  slot's.

The slot rule covers the key a slot holds now, and the watermark every
key a slot held before it, so no key's transmit packet number or
receive counter in the chip is reset by a message an attacker without
the keys can send, which is what a key reinstallation attack needs.

OpenBSD keeps the same property with two guards, a flag that a new PTK is
expected for the pairwise key (`:538-579`) and a comparison with the
installed key for each group key (`ieee80211_must_update_group_key`,
`:345-356`, used at `:598, 637, 895, 929`), and iwd with a rule against
reinstalling an identical group key (iwd fact 41); here one rule covers
every slot, and the slots mirror the chip because nothing else changes
the chip's keys: when the association ends the machine issues
`delete_keys` before emptying the slots, and a restart of the WiFi
domain reloads the firmware, which starts with none.

### The 4-way handshake

* **Message 1** is taken in `keys`, `open` and `rekey`, since an access
  point may rekey with a new message 1 (`:201-208`), with a counter
  above the watermark; in `open` it starts a rekey and moves the
  machine to `rekey`. The machine takes its SNonce from the step's
  random bytes and asks the key holder for the PTK. The answer sets the
  pending PTK, and the machine answers message 2 with the RSN element
  and the RSNXE of `Sent`, as the association request carried them
  (`rsn_supp/wpa.c:1107-1110`): the access point compares both with the
  association request's and deauthenticates on a difference
  (`ap/wpa_auth.c:4085-4099`). The station asks for an RSNXE, the
  hash-to-element bit, in an SAE join's `connect` and none for PSK; but
  brcmfmac hands the firmware only the RSN element through `wpaie` and
  vendor-specific elements through the association request's list
  (`cfg80211.c:2491-2495, 4908`), so whether the firmware sends the
  RSNXE is its own (F14 of [Facts](#facts-this-design-does-not-have)),
  and message 2 repeats what was sent, never what was asked. The
  watermark does not move.
* **Message 3** is taken in `keys` and `rekey` only with a pending PTK;
  a counter above the watermark; the pending ANonce (`:395-398`); a
  valid MIC under the pending PTK's KCK (`:403-409`); encrypted key data
  that unwraps under its KEK; an RSN element equal byte for byte to the
  one the scan reported for the BSS, else the station deauthenticates
  with "RSN element different" (`:494-502`), and an RSNXE equal to the
  scan's too; the Install bit (`:487-492`); a GTK KDE of the group
  cipher's length (`:586-593`); and, when PMF is negotiated, an IGTK
  KDE of 28 bytes and key id 4 or 5 (`:624-635`), since a port opened
  without it would leave the protection of broadcast management frames
  off on a network that requires it. The machine then raises the
  watermark to the message's counter, sends message 4, and asks for
  what differs from the slots: pairwise, GTK, IGTK, in OpenBSD's order
  (`:535, 569-657`). A retransmitted message 3, in `keys`, `rekey` or
  `open` once the install is confirmed, is answered with message 4
  again and installs nothing.
* **The port opens**, and a rekey ends, once every negotiated key, the
  PTK, the GTK and, under PMF, the IGTK, is in its slot and confirmed by
  the chip; a refused install deauthenticates, as OpenBSD's does
  (`:569-578, 609-618, 646-657`).
* **Transition Disable.** Message 3's key data may carry the Wi-Fi
  Alliance's Transition Disable KDE, one byte of bits
  (`wpa_common.h:155, 468-471`; `wpa_common.c:3919-3921`), which an
  access point sends once its network has stopped serving WPA2
  (`ap/wpa_auth.c:3660-3663`). When the join's AKM is SAE and bit 0 is
  set, the machine, having accepted the message, reports
  `{transition_disable, SSID}` to the lifecycle, which applies it to
  admission at once and sends it to the holder
  ([The SAE-only mark](#the-sae-only-mark)). wpa_supplicant removes
  WPA2 from the profile on the same condition (`wpas_glue.c:1342-1349`),
  and iwd keeps the indication in the network's profile (iwd fact 33).
  The indication is authenticated by the message's MIC under a PMK that
  only SAE produced, and it can only narrow what the choice admits. The
  other bits concern modes erXos does not have and are ignored.

### The group key handshake

Group message 1 has a rule of its own, OpenBSD's (`:829-890`), and none
of message 3's checks that belong to the 4-way handshake: it is taken
only in `open` and `rekey`, where the pairwise key is installed; with a
counter above the watermark; with a valid MIC under the installed PTK's
KCK; with the Encrypted bit set and key data that unwraps under the
installed KEK; and with a GTK KDE of the group cipher's length, and,
under PMF, an IGTK KDE of 28 bytes and key id 4 or 5 when one is
present (`:895-950`). It carries no ANonce and the access point sends no
RSN element in it, so the station compares neither. The machine raises
the watermark to its counter (`:967`), asks for what differs from the
slots, and answers group message 2; the port stays open, and the
machine stays in its state.

### What a failed check costs

A frame that fails a check is dropped and counted by its check, and
changes nothing. An accepted message 1, which no MIC protects, changes
only the pending PTK: a forged one can spoil the handshake in progress,
which the access point's retransmission of message 1 or the deadline
recovers, and can install nothing; in `open` it starts a rekey that its
deadline ends, back in `open` under the same keys. A deauthentication
follows only the checks the source deauthenticates on: a different RSN
element, an unusable cipher, a key of the wrong length or a refused
install.

## SAE and protected management frames

**The form.** SAE runs on the host through the firmware's external
authentication, the form of brcmfmac's Cypress-class chips
([Context](#what-a-fullmac-chip-leaves-to-the-host)), and only when the
firmware's `cap` names `sae_ext`. W1 probes the pinned firmware for it,
and W5 then probes the exchange itself and PMF on the board, since
brcmfmac files the 43455 under Broadcom's class and gives no evidence
either way (F8). Without `sae_ext` a BSS that only SAE could join is
refused with the reason `no_sae_ext` at `/proc`, and WPA3 is reported
unsupported. The remedy then is another Cypress firmware build for the
43455 that offers `sae_ext`, under a license the image may carry; the
firmware's own SAE from a password (`wcc/core.c:16-20`) is not used,
since it hands the password to the firmware and hides the exchange from
the host's checks.

**The exchange.** For a candidate whose AKM is SAE the machine issues
`connect` with SAE, which the chip process turns into `wpa_auth` set to
SAE, `auth` 3, `wsec` AES and `mfp` set (below) (brcmfmac
`cfg80211.c:2027-2032, 2066-2068, 2289-2295`). The firmware raises the
external-authentication request with the peer's address and SSID
(`cyw/core.c:239-272`). The machine sends its commit and then its
confirm as authentication frames, which travel through the `mgmt_frame`
variable, each with a packet id whose transmit-status event the chip
process awaits (`cyw/core.c:101-196, 326-352`), takes the peer's frames
from the received-frame event (`cyw/core.c:274-325`), and reports the
outcome, which the chip process writes to `auth_status`, success 4 or
failure 3 (`cyw/fwil_types.h:39-59`). The firmware then associates and
the 4-way handshake runs with AKM 8's row and the exchange's PMK, which
the key holder kept.

**Who computes what.** The exchange has a public half and a secret
half, and the line between them is the line between the WiFi domain and
the key holder; PT, which comes before both, begins where the password
is typed:

| Step | In the join machine, by `erx_sae` | In the key holder |
| --- | --- | --- |
| PT, from the SSID, the password and an optional identifier | | once, when the secret is given: `wlankey` makes two hashed values by HKDF over HMAC-SHA256 in the administrator's session ([Credentials](#credentials)), and the holder's `set` makes PT of them with `sae_pt/3`, which reduces each modulo the prime, maps it by the simplified SWU map and adds the two points (`sae_derive_pt_ecc`, `sae.c:874-1052`; `sswu`, `:635-832`), and keeps it with the entry |
| the commit | asks with the SSID and both addresses; builds the frame from the scalar and element, with status 126, hash-to-element (`ieee802_11_defs.h:233`), and the password identifier when the name has one | the value from both addresses; `rand` and `mask`, 32 random bytes each; `sae_commit/5`, which returns PWE, that value times PT (`sae_derive_pwe_from_pt_ecc`, `:1158`), the scalar `(rand + mask) mod r` and the element, the negation of `mask x PWE` (`:1298-1384`); keeps `rand`, PWE and its own scalar and element as the SSID's exchange, and answers the scalar and element |
| the peer's commit | parsed and checked (`sae_parse_commit`, `:2203-2313`): group 19, a scalar from 2 to `r - 1`, an element of two coordinates below the prime, and neither equal to the station's own; a Rejected Groups element (`ieee802_11_defs.h:531`; `sae_parse_rejected_groups`, `:2141-2172`) of an even length of at most 254 bytes, which ends the exchange, class `bss`, when it names group 19, the station's only group, as wpa_supplicant ends one whose list names a group it has enabled (`sme.c:2674-2706, 2970-2974`); an anti-clogging token request (status 76) sends the commit again with the token (`ieee802_11_defs.h:199`; `:1846`) | |
| the keys | asks with the peer's scalar and element and the peer's Rejected Groups list, empty when its commit carried none; takes the KCK | `sae_key/5`: K's x-coordinate, `rand x (peer scalar x PWE + peer element)`, or `infinity`; KCK and PMK by the KDF over HMAC-SHA256 (`sae_derive_keys`, `:1539-1680`), its keyseed salted, under hash-to-element, with the two parties' Rejected Groups lists in the order of their addresses, or with zeros when both are empty (`:1579-1610`); the station's own list is always empty, since it offers group 19 alone and moves to no other, so the salt is the peer's list or zeros; answers the KCK, keeps the PMK in place of the exchange's values, and answers `bad_element` for a point off the curve or a K at infinity, changing nothing |
| the confirms | built and checked with HMAC-SHA256 under the KCK, compared with `crypto:hash_equals/2` (`sae_cn_confirm`, `:2314-2375`; `sae_check_confirm`, `:2439` onward) | |
| each PTK | asks, with AKM 8 | from the PMK it kept |

`erx_sae`, a pure core, follows wpa_supplicant 2.12's `sae.c` for group
19 (P-256) and hash-to-element alone. No value from which the password
could be tested leaves the holder but the commit, which the protocol
sends on the air, and the KCK, which authenticates one exchange. Every
operation on a secret value, the password's hashed values in `wlankey`,
PT, PWE, `rand`, `mask` and K in the holder, is either HMAC or one of
the three functions of
[OTP's `crypto`: SAE's arithmetic](#otps-crypto-saes-arithmetic); no
secret ever becomes an Erlang integer.

`sae_commit/5` answers `retry` when `rand` or `mask` is outside 2 to
`r - 1` or the scalar is below 2, and the holder draws both again, as
`dragonfly_generate_scalar` draws until `1 < rand, mask < r` and the
scalar exceeds 1 (`dragonfly.c:185-218`, called from
`sae_derive_commit`, `sae.c:1344-1362`); like it, the holder gives up
at the hundredth draw, which only a broken generator reaches, and
answers `unavailable`. Whether the peer's element lies on the curve is
decided once, by `EC_POINT_oct2point` inside `sae_key/5`; `erx_sae`
takes the holder's `bad_element` as the same drop as a failed parse,
counted as `bad_element`, and the exchange goes on to the peer's
genuine commit.

Its states are wpa_supplicant's: nothing, committed, confirmed, accepted
(`sae.h:113-115`), with two while the holder works: committing while it
makes the commit, and keying while it makes the KCK of the peer's
commit. A commit the checks pass moves committed to keying; the KCK
moves keying to confirmed, with the confirm sent; and `bad_element`
returns keying to committed, as it was before that commit. While
keying, any other commit is dropped, counted as `sae_unexpected`, so
the station confirms only over the commit whose KCK it asked for,\nwhatever order the events arrive in; a
refusal still ends the exchange, and nothing is sent again, since the
peer's commit answered the station's. How far the three functions are constant-time is a
residual of [Security](#security). A network that offers SAE without
hash-to-element in its RSNXE (bit 5, `ieee802_11_defs.h:632`) is not an
SAE candidate: hunting-and-pecking derives its element per exchange, in
answer to the peer, and is out of scope.

**Protected management frames.** The `connect` request carries the PMF
of [Choosing a network](#choosing-a-network)'s table, which refuses a
BSS where PMF that either side requires cannot be had, and the chip
process sets `mfp` from it, as brcmfmac sets it from the same two inputs
(`cfg80211.c:2270-2295`); whether the firmware answers the `mfp`
variable at all (`feature.c:332`) is one of the table's inputs. An SAE
join always negotiates PMF. The IGTK from the handshake is installed
with `wsec_key` under its key id, with the firmware's AES-CCM algorithm
code, which brcmfmac also gives an AES-CMAC key
(`cfg80211.c:2958-2961`), and its packet number as the receive IV; the
firmware protects and checks management frames with the installed keys.

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
  1 or 2) and `priority`; a block whose `key_mgmt` allows `SAE` with
  `ieee80211w=0` is refused, since SAE never joins without PMF, and so
  is one whose `key_mgmt` names `NONE` beside another AKM, since a
  block is open or protected and an open AKM beside a protected one
  would let an impostor without protection be admitted
  ([Choosing a network](#choosing-a-network)).

**The default block.** A key a block leaves out has the default block's
value: `key_mgmt=WPA-PSK WPA-PSK-SHA256 SAE`, `ieee80211w=1`,
`priority=0` and `scan_ssid=0`. A network known only by its secret has
that block. wpa_supplicant's own defaults are `WPA-PSK WPA-EAP` and no
PMF (`wpa_supplicant.conf:1107, 1109-1110`); under those a network
given a passphrase and nothing else could never join a WPA3 access
point, so erXos's defaults admit the strongest AKM the secret serves
and protect management frames wherever the access point can. A block
that states `key_mgmt` or `ieee80211w` means what it means to
wpa_supplicant ([Decisions](#decisions), 3).

The file holds no secret. `psk`, `sae_password` and `sae_password_id`
are refused with the reason `{config, Line, secret_in_file}`, and the log
line says that a network's secret is given with `wlankey`
([Credentials](#credentials)). Any other key, a value outside its range
or a malformed line refuses the whole file with its line number and key,
at `/proc` and in the log, and the station keeps the configuration it
had, none at its start: a key the station does not understand may
narrow what a block allows, so reading past it would read the file
wrongly. The file is at most 64 KiB. The file states policy, which
network is preferred and what each may use; which networks have a
secret is the key holder's fact, so no network's existence is written
in two places that could disagree: a block without a secret is an open
network or the verdict `no_secret`, and a secret without a block has
the default block.

### Credentials

**The key holder** owns one entry for each network that has been given
a secret: the SSID; the PMK, when the secret is a passphrase or a raw
PSK; PT with its password identifier, at most 64 bytes, when it is a
passphrase or an SAE password; and the SAE-only mark, `none`, `kept` or
`pending`. It holds at most `wifi_networks_max` (16) entries. The PMK
and PT are derived values, so the passphrase is kept nowhere; each is
still the password's equivalent for its SSID, which is why neither ever
leaves the holder.

**Two facets.** The holder serves two interfaces, declared in
`abi/services` and the same wherever the holder runs, each to its own
grantee:

* `wpa_key`, the station's, which the manifest grants to the WiFi
  domain and the station reaches through one module, `erx_wifi_keys`:
  the operations a join needs, the names, and the one change that only
  narrows, `mark`;
* `wpa_admin`, the administrator's, which the manifest grants to root's
  session template and to no configured domain: the two operations
  that add, replace and remove a secret, which the session's `wlankey`
  command calls.

So the right to enroll a network follows from the facet a domain holds:
the WiFi domain holds none that adds a secret, and nothing it parses
can give the holder a network of an attacker's choosing, forget the
administrator's, or loosen a mark.

| Facet | Operation | Request | Answer |
| --- | --- | --- | --- |
| `wpa_key` | `names` | none | `{ok, Entries}`: for each entry its SSID, whether it has a PSK, whether it has an SAE secret and that secret's identifier, and its mark; never a key |
| `wpa_key` | `mark` | an SSID | `{ok, Entries}`: the entry is SAE-only, its mark `kept` once written and `pending` until then ([The SAE-only mark](#the-sae-only-mark)); `{error, no_entry}` |
| `wpa_key` | `sae_commit` | an SSID, the station's address and the BSS's | `{ok, Scalar, Element}`; `{error, no_secret}` |
| `wpa_key` | `sae_key` | an SSID, the peer's scalar and element, and the peer's Rejected Groups list | `{ok, KCK}`; `{error, bad_element}`; `{error, no_commit}` when the SSID's exchange is not the one in progress |
| `wpa_key` | `ptk` | an SSID, an AKM, the two addresses and the two nonces | `{ok, #{kck, kek, tk}}`; `{error, no_secret}`; `{error, sae_only}` for PSK or PSK-SHA256 on a marked entry, `pending` or `kept`; `{error, no_pmk}` for SAE when the SSID's exchange has left none |
| `wpa_admin` | `set` | an SSID; a PMK of 32 bytes, or none; for SAE, the password's two hashed values of 48 bytes each and its identifier, or none; not both none | `ok` once the entry is kept; `{error, full}` at 16 entries. The holder makes PT from the two hashed values with `sae_pt/3`; the entry's secrets are replaced and its mark kept |
| `wpa_admin` | `forget` | an SSID | `ok`: the entry and its mark are gone |

Every operation may answer `{error, unavailable}`. Every request is of
fixed shape: an SSID of 1 to 32 bytes, addresses of 6, nonces and
scalars of 32, an element of 64, a PMK of 32, hashed values of 48, an
identifier of at most 64 bytes, a Rejected Groups list of an even
length of at most 254, one of three AKMs; every value of the right
length is a valid one, so the holder checks the lengths, refuses
anything else, and parses nothing.

**Giving a secret.** `wlankey` is a command of root's session, as
`sshkeys` is a command of every session that reaches the vault through
the session's credentials facet
([design-ssh.md](design-ssh.md#login-keys)):

* `wlankey set SSID` asks at its tty, with echo off, for a passphrase
  of 8 to 63 printable ASCII characters, which serves WPA2 and WPA3
  alike, or 64 hexadecimal digits, a raw PSK, which serves WPA2 alone;
* `wlankey set -s [-i ID] SSID` asks for that and then for an SAE
  password of 1 to 128 bytes with the identifier `ID`, which WPA3 then
  uses in place of the passphrase; an empty first answer gives the
  network an SAE password alone;
* `wlankey forget SSID` removes the network's entry.

An SSID is written as `ifconfig` takes one, text or `0x` and
hexadecimal. For `set` the command derives, in the session, the PMK, by
PBKDF2-HMAC-SHA1 of the passphrase salted with the SSID, 4,096
iterations, or the raw PSK itself; and, from the SAE password or, with
none, from the passphrase, wpa_supplicant's rule
(`wpa_supplicant.conf:1174-1178`), the two hashed values of
`sae_derive_pt_ecc` (`sae.c:874-1052`), by HKDF over HMAC-SHA256 of the
SSID, the password and the identifier. It sends those to the holder's
`set` and drops the passphrase; no passphrase leaves the session that
typed it, whatever holder answers. When the holder has answered, the
command writes `names` to `/svc/wifi/ctl`, so the station reads the
entries at once, ends the SSID's secret hold and leaves a join that a
forgotten entry no longer admits
([Control and inspection](#control-and-inspection)); without that
write, the change takes effect at the station's next choice. Errors
print as the command's own: `full`, `unavailable`, a secret of the
wrong form.

The secret is kept before any access point has proved it right; iwd
writes a passphrase to its profile only after the handshake succeeds
(iwd fact 11), which needs a secret held in waiting. Here a wrong one
shows as `secret_failed` ([Failure memory](#failure-memory)), and the
next `wlankey set` replaces it. Only a session that holds `wpa_admin`
gives or removes a secret, root's by the default manifests, as only
root edits FreeBSD's `/etc/wpa_supplicant.conf`.

**One exchange.** Beside the entries the holder keeps one SAE exchange:
the SSID, and either `rand`, PWE and its own scalar and element from
the last `sae_commit`, or, after `sae_key`, the PMK that exchange
agreed. A new `sae_commit` replaces it. `ptk` for SAE derives from that
PMK; `ptk` for PSK and PSK-SHA256 from the entry's. So the conversation
of one join is factotum's with 9front's supplicant, the addresses and
nonces in and the PTK out (`wpa.c:474-520`), extended by SAE's two
secret steps ([SAE](#sae-and-protected-management-frames)).

#### The SAE-only mark

An authenticated Transition Disable indication narrows admission at
once and stays narrowed whatever happens to its record:

* **At once, in the station.** The lifecycle adds the SSID to its marks
  in the step that takes the join's `{transition_disable, SSID}`, so
  the next choice, and the check that leaves a join the view no longer
  admits, read it before the holder has answered or even been asked.
* **At once, in the holder.** The station sends `mark`; the holder
  records the mark in its memory before it writes anything, so from
  then on its `ptk` refuses PSK for the SSID and its `names` carry the
  mark, and then publishes it, answering `kept` once the write is
  published and `pending` while it is not: on a trial boot, where every
  change to the vault's file is refused, or when the store fails. The
  holder writes a pending mark again at every later `mark` and every
  later change it publishes.
* **Asked again until kept.** The station sends `mark` again before
  each choice for every SSID of its marks whose name is not `kept`,
  and at each later indication, which an access point sends in every
  handshake. While the holder answers `unavailable` the station's own
  mark holds.
* **Across restarts.** A restart of the WiFi domain loses the station's
  marks, not the holder's: the names it reads at its start carry every
  mark the holder recorded, `pending` ones included. A restart of the
  holder, or of the machine, keeps the `kept` ones.

So a mark is lost only when the holder's memory ends while the mark is
`pending`, or when the WiFi domain ends before the holder has recorded
it at all. Neither is silent: the station logs `mark pending` at a
`pending` answer and `mark not recorded` at an `unavailable` one, with
the SSID, and `wifi
networks` shows each mark's state. Until the network's next SAE
handshake marks it again, the SSID is as the administrator configured
it; an administrator who wants the restriction whatever happens writes
`key_mgmt=SAE` in its block. Only `forget`, an administrator's
operation, removes a mark, and `set` keeps it.

#### Where the holder runs

**The holder's parts.** `erx_wpa_holder` is its pure core: the entries,
the marks, the exchange and the order of its steps, over an arithmetic
module that makes and uses each secret as a handle the core never looks
into. `erx_wpa_arith` is that arithmetic in Erlang over OTP's `crypto`:
the PTK by `erx_wpa_kdf`, and PT, the commit and the key by the three
functions of [OTP's `crypto`](#otps-crypto-saes-arithmetic). The core
takes each commit's random bytes as an input, which the holder's
process draws from `crypto:strong_rand_bytes/1`, so a test gives it the
values a recording used. On the administrator's side, `erx_wpa_secret`
is `wlankey`'s pure derivation: the PMK by `crypto:pbkdf2_hmac/5`
(`otp/lib/crypto/src/crypto.erl:1028`) and the two hashed values by
HKDF.

The seam is the same wherever the holder is; the placements differ in
what a break of the WiFi domain reaches. The release placement is (a);
(c) and (b) are the alternatives it was chosen over
([Decisions](#decisions), 1):

| Placement | A break of the WiFi domain's parsers yields | What it costs |
| --- | --- | --- |
| **(a) the vault**, a purpose `{wpa, "wifi"}` with its two facets | the keys of the association in progress, and the use of `wpa_key` while the break lasts | the vault learns one more protocol's arithmetic, and takes two values the air chose, the peer's scalar and element, and the peer's Rejected Groups list as checked fixed-length inputs |
| **(c) a key domain of WiFi's own**, `wifikeys`, that holds the entries in a state slot and serves both facets | the same | a domain, two declared interfaces served from it and its manifest rows, for a second key agent beside the vault; the entries are Erlang terms there, where the vault keeps keys in resources |
| **(b) the WiFi domain**, over a state slot or, in a development build, a file | every network's PMK and PT; and, since the domain then writes the store itself, the power to enroll a network of its own | nothing beyond the slot |

(b) keeps neither of this design's two guarantees for a break of the
parsers, no password equivalent and no enrollment, so it is not a
release placement: it is the development build's stopgap below. Under
(a), the passphrase stays in the administrator's session, the WiFi
domain holds `wpa_key` alone, and the station's code is the same as
under (b). (a) is the vault's own rule, that no key enters a domain that uses it
([design-system.md](design-system.md#the-vault)), applied to WiFi: the
chip needs the session's keys, the TK, GTK and IGTK, in clear, but
never the PMK or PT, so those are a key facet's material and not a
state slot's. In the vault's terms:

* **Grant.** The WiFi domain's manifest row holds `wpa_key` of the
  purpose `{wpa, "wifi"}`, as the SSH domain's holds its host key
  facet, and root's session template holds `wpa_admin` of the same
  purpose; the system domain stands in front of the vault with both,
  and each acts for its grantee alone.
* **Exact inputs.** The seven operations above and their fixed shapes
  are the purpose's protocol. The facets compute only what the purpose
  names, so neither is a general oracle for HMAC or for the curve.
* **Keys never become terms.** The entries' PMKs and PTs and the
  exchange's values live in the vault's NIF resources, as its other
  keys do, behind an arithmetic module of the vault's whose handles are
  those resources and which binds the same C functions. A `set`'s PMK
  and hashed values arrive as terms of the session's request, as a
  passphrase does at a login, and become resources before the request
  is answered. What leaves is what the protocol gives the station: the
  commit, the exchange's KCK and each PTK, to the grantee alone, as a
  `token` facet's secret leaves.
* **Where the entries live.** A section of the machine's file, sealed
  as a state section is, under a key that HKDF-SHA-256 derives from the
  machine's master key with a label naming the purpose
  ([design-system.md](design-system.md#state-slots)). `set` and
  `forget` answer once the publication's checkpoint has answered, and
  on a trial boot they answer `unavailable`; `mark` answers as
  [The SAE-only mark](#the-sae-only-mark) says.
* **What the vault logs.** Each `set`, `forget` and `mark`, with the
  grantee, as it logs a token's release; no join is logged.

**A development build, before the release placement,** runs the
holder as `erx_wifi_keys_dev`, a process of the WiFi domain that serves
`wpa_admin` to root's session from there: the same core over
`erx_wpa_arith`, with the entries in a file, `keys`, in the WiFi
domain's own tree on the data volume, `wifi/`, one generated layout of
`abi/formats/wpa_keys.txt`, replaced whole by write, sync and rename,
as the SSH domain keeps its host key before the vault
([design-ssh.md](design-ssh.md#host-keys)). The file is decoded with
every length checked and has a fuzz target; one that does not decode
makes every operation answer `unavailable`, with a log line. Nothing is
sealed and nothing is contained: a session that holds the data
partition's tree, or a copy of the medium, reads every network's PMK
and PT, and so does a break of the WiFi domain, which can also write
the file and so enroll a network; the station still reaches the holder
only through `erx_wifi_keys`, which has no `set`, and no passphrase
enters the domain, since `wlankey` derives in the session. That is a
security residual that blocks release ([TODO.md](../TODO.md)), and the
release manifest check refuses a `wifi` row without `wpa_key` or with
`wpa_admin`. The release holder's arithmetic lands differentially
against `erx_wpa_arith` over the vectors of
[Verification](#verification), as every replacement of a stopgap does.

**The names.** The station keeps the holder's last answer and gives it
to the choice. It asks `names` at its start, before each choice, at
`names` and at `reconfigure`, and takes the entries every `mark`
answers. While the holder answers `unavailable` the names are
`unavailable`, never an empty list, so every protected network and
every SSID that no block names reads `keys_unavailable`, and no open
network is admitted but by a statement
([Choosing a network](#choosing-a-network)); open networks of a block
join meanwhile.

### The country

The station scans and joins only once a country is configured, from
`country=CC` or from `ctl`'s `country CC`, which holds until the next
configuration. It hands the country to the chip process, which sets it
with the `country` variable (brcmfmac `cfg80211.c:8452-8462`) and only
then issues `up`. With none configured the radio stays down with the
reason `no_country` at `/proc`, the chip's interface stays down, and
`ctl`'s `scan` and `ssid` fail with `eio`. The firmware's behaviour
with no country set, which country its CLM blob then applies and
whether it transmits under it, is not verified for the pinned firmware
(F10); until it is, nothing transmits without a country.

### Control and inspection

**The tree.** The WiFi domain serves `wifi`, an `erx_fs` tree of the interface `svc` with one
file, `ctl`, granted to root's session and mounted at `/svc/wifi`. A
write is one command of at most 4,096 bytes:

| Command | Does | Answers |
| --- | --- | --- |
| `scan` | starts a scan, or waits for the one in flight | when the scan ends |
| `ssid NAME` | `want` becomes that network alone, as a block or a secret knows it; its holds are cleared | at once |
| `ssid NAME open` | `want` becomes the open network `NAME` alone: an open BSS of that SSID is admitted whatever a block or the names say, and nothing else; its holds are cleared | at once |
| `ssid -` | `want` becomes every known network, FreeBSD's way to clear the SSID (`ifconfig.8:2116-2123`) | at once |
| `leave` | `want` becomes none; the station leaves its network | at once |
| `country CC` | sets the country | at once |
| `names` | reads the names again: every secret hold ends, a join the new names no longer admit is left, and an idle station scans and chooses; `wlankey` writes it after each change | when the holder has answered |
| `reconfigure` | reads the configuration and the names again, clears the memory, leaves and chooses afresh | when the file is read |

A malformed command fails the write with `einval`. No command carries a
secret, and none changes the holder's entries: those are `wpa_admin`'s
([Credentials](#credentials)).

**What `/proc` shows.** The station reports three inspection paths,
declared in `abi/inspection.txt` as machine paths with the station as
their reporter, as the clock service reports `time`
([design-time.md](design-time.md#what-proc-shows)), each attribute with
its readers:

| Path | Every session reads (`visible any`) | Only the machine-wide scope reads (`visible all`) |
| --- | --- | --- |
| `wifi` | the chip (id, revision, firmware and CLM versions, `cap`, hardware address, country), the radio, the join machine's state, `want`, and the joined BSS with its SSID, channel, AKM, PMF and signal: what `ifconfig wlan0` shows any FreeBSD user | the reason of the last join's end and the counters by reason |
| `wifi scan` | each BSS's SSID, address, channel, signal, capabilities and elements: what `ifconfig wlan0 list scan` lists to any user, and anyone in range of the radio sees | each BSS's verdict ([Choosing a network](#choosing-a-network)) |
| `wifi networks` | nothing | one record for each known network: its SSID, whether a block, a secret or both make it known, which secrets the holder has for it and never the secret, the SAE-only mark and its state, its priority, and its secret's hold and until when |

What a session may not read is what tells which networks the machine
has secrets for and how its joins have failed: the verdicts, the saved
networks, the holds and the reasons. The machine-wide scope is the
system shell's and, in a development build, root's session's
([design-live.md](design-live.md#inspection), "Scopes"); a
scoped facet gets the public attributes of `wifi` and `wifi scan` and
`{error, scope}` for `wifi networks`. A front end in a development
build lists `wifi scan`, and for a BSS whose verdict is `unknown`,
`no_secret` or a `secret_failed` hold asks for the passphrase and runs
`wlankey set`. In a release build, where no session has the
machine-wide scope, a front end in root's session lists the BSSs,
offers a passphrase for any protected one, and reads the outcome from
the join machine's state; the verdicts and the saved networks are read
at the system shell, as every machine-wide fact of a release build is.
Every SSID and every firmware string is text from the air or the chip
and reaches a sink only through that sink's escaping function.

**`ifconfig`.** `ifconfig wlan0 scan` writes `scan` to `ctl` when the
session can write it, as FreeBSD starts a scan only for root
(`ifieee80211.c:4093-4097`), then prints `wifi scan` in FreeBSD's columns
(`:4011-4066`), writing an SSID as `copy_essid` does, whole as `0x` and
hexadecimal when any byte is outside `0x20` to `0x7e` (`:3671-3702`);
a `scan` refused as `ebusy` prints the last results, as for a session
that cannot write. `ifconfig wlan0 list scan` prints without scanning;
`ifconfig wlan0 ssid NAME`, `ifconfig wlan0 ssid -` and `ifconfig wlan0
country CC` write their commands, and `ifconfig wlan0 ssid NAME
authmode open` writes `ssid NAME open`, with FreeBSD's `authmode`
parameter (`ifconfig.8:1219-1230`; `ifieee80211.c:859-878`); and
`ifconfig wlan0` adds FreeBSD's status lines (`ieee80211_status`,
`:5164`) for the fields `wifi` shows the session, leaving out those it
does not.

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
-spec sae_commit(Curve, PT, Val, Rand, Mask) -> {PWE, Scalar, Element} | retry
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
  and the element, the negation of `Mask x PWE`; or `retry`, computing
  nothing past the check, when `Rand` or `Mask` is outside 2 to `r - 1`
  or the scalar is below 2, so the range decisions on the two secrets
  are made in the NIF, never on Erlang integers;
* `sae_key` returns K's x-coordinate, `Rand x (PeerScalar x PWE +
  PeerElement)`, or `infinity`.

A point is SEC1's uncompressed form, `<<4, X:32/binary, Y:32/binary>>`;
a scalar is 32 bytes big-endian, from 2 to the group's order less one;
`sae_commit`'s `Rand` and `Mask` are any 32 bytes.
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

Only the key holder's arithmetic calls the three functions
([Credentials](#credentials)), never the station. `erx_wpa_arith`
calls them as they are, in a development build and on the host; the
vault's arithmetic binds the same C functions over its key resources,
so that there PT, PWE and `rand` are never terms.

## Invariants

| Invariant | Mechanism | A violation | Check |
| --- | --- | --- | --- |
| **WF1.** The legacy controller's page and line stay in the storage domain | the unit rule and the manifest check; the card reaches another domain only through `sdio` | a manifest that gives the legacy controller to another domain | the boot view's refusal of a split unit, unchanged ([design-shared-devices.md](design-shared-devices.md#the-unit-rule)) |
| **WF2.** Only `erx_blk_write` issues a command to either SD controller, and no SDIO command writes a medium | the SDIO table in `erx_blk_write`; `sdio_issue/2` and `sd_issue/2` each refuse the other kind's record | a second issuing module; an SD command on the legacy record; a CMD53 on EMMC2 | U4's build check, unchanged; host tests of both refusals |
| **WF3.** A client never writes a register the host's state depends on, and never issues a CMD53 the wire, the function or the controller cannot carry | `erx_sdio:check/2` refuses the list whole, checking the three limits apart | a CMD52 or CMD53 write that reaches a host-owned CCCR register or a block-size register; a byte-mode CMD53 of more than 512 bytes | the host core's property test over addresses and lengths, seeded below |
| **WF4.** No data frame passes between the chip and the network domain while the port is closed, and `wlan0`'s link is up exactly while it is open | the chip process gates both directions on the station's `port` request; the link message is the port; the table lets the join machine reach `open` from `keys` only by `set_keys_confirm`, or from `joining` by `connect_confirm` for an open network, and `rekey` only from `open` | a frame forwarded before the keys are in | the exhaustive join test and the fake chip's port test |
| **WF5.** No PMK or PT, and no passphrase ever, is held by the WiFi domain: the key holder keeps the first two and answers only a commit, an exchange's KCK and a PTK, and the passphrase stays in the administrator's session. The PTK's KCK and KEK and SAE's KCK leave the WiFi domain nowhere; the installed keys reach the chip through the storage domain; and no report or dump of the WiFi domain carries a term its processes held | `wpa_key`'s five operations return no entry's key; `wpa_admin` takes a PMK and hashed values, never a passphrase, and the WiFi domain holds no `wpa_admin`; `ether` carries frames, credits and a link state; the report filter `erx_report` rewrites every report of OTP's domain to names, classes and arities; the holders are `sensitive` ([Where the secrets live](#security)) | an operation that returns a PMK; a station that derives a PTK itself; a passphrase in a request to the holder; a KCK in a termination report; a station's stack in a crash dump | the interfaces' schemas carry no entry key and no passphrase; a build check that only `erx_wpa_arith` calls a PTK derivation or `crypto`'s SAE functions and only `erx_wpa_holder` calls it, that only `erx_wpa_secret` calls `crypto:pbkdf2_hmac/5`, and the unchanged check that the network stack calls no `crypto`; the diagnostics test below. A development build's holder is inside the WiFi domain, the residual of [Security](#security) |
| **WF6.** Every byte from the chip, the air, the configuration or `ctl` is parsed once, by a bounds-checked core with a fuzz target, before any decision | the cores of [The chip](#the-chip), [The supplicant](#the-supplicant), `erx_sae`, `erx_wpa_conf` and `erx_wifi_fs` | a field read from an unchecked binary | the fuzz targets of [Untrusted input](#untrusted-input) |
| **WF7.** Every attachment starts from a reset card, and nothing of an ended attachment acts on the next | `attach` runs the bring-up from the controller's reset for all and the card's I/O reset, and makes a fresh `Ref` that every `run` and notice carries | a client that meets the previous client's chip state; a list of the old attachment run on the new | the host test that a second attach after a client's death resets and refuses the old `Ref`, with the fake card |
| **WF8.** No key is installed from a message whose replay counter, MIC, nonce, key data or RSN element check failed, and only a message authenticated by its MIC raises the replay watermark | the handshakes' checks are the only path to a `set_keys` request; the watermark moves only in the accepting steps of message 3 and group message 1 | an install after a failed check; a watermark raised by message 1 | the exhaustive join test with forged and replayed messages |
| **WF9.** No message an attacker without the keys can send reinstalls a key, so no key's packet numbers are reset | a `set_keys` request holds only keys that differ from their slot's, confirmed or not, which covers the key a slot holds now; a message no newer than the watermark is refused before its keys are read (WF8), which covers every key a slot held before; the slots are emptied only with the chip's keys | a retransmitted message 3 or group message that installs again; a replayed message that brings back a key a rekey replaced | the exhaustive join test with retransmissions and with a replay after a rekey, seeded below |
| **WF10.** Only the firmware's event channel makes an event | `erx_bwfm_sdpcm` tags every frame and glom subframe with its SDPCM channel; only `{event, _}` reaches `erx_bwfm_event` | a data frame of ethertype `0x886c` decoded as an event | the SDPCM core's host test with event-shaped frames on the data channel, seeded below |
| **WF11.** The legacy controller never raises the shared line | the SDIO host's core writes `irpt_en` only as zero | a set bit in `irpt_en` | the host test over the core's register actions, seeded below |
| **WF12.** The join machine makes only the transitions of its table, and takes an event only with its join's reference; an event the chip process tagged by a BSS's address alone can at most end a join early or, for an open network, open its port before the firmware's outcome | `step/3` looks the cell up before the handler and checks the state after it; a reference check comes first; the chip process gives each request at most one confirmation and each connection at most one `disconnected` ([The seam](#the-seam-to-the-station)) | a handler that reaches a state its cell does not list; an event of an ended join acted on; a late event of an earlier connection that installs a key | the exhaustive join test, which reaches every listed edge and no other, and the `erx_bwfm_mlme` test, seeded below |
| **WF13.** A failure never changes what is admitted, or with which AKM and PMF | `admit/4` takes no memory; the memory only turns a candidate into a held one | PSK tried where SAE failed; a held BSS admitted with another AKM | the choice's property test over views with and without memory, seeded below |
| **WF14.** An SSID whose access point disabled its transition never joins with PSK or PSK-SHA256 again until an administrator forgets it, from the step that accepted the indication | the lifecycle adds the mark to its view in that step; the holder records it in memory before it writes it and refuses PSK `ptk` from then on; the station asks again until the mark is `kept`; only `wpa_admin`'s `forget` removes it, and `set` keeps it | a PSK join after a Transition Disable indication, before or after the holder's write, or after a restart of the WiFi domain | the choice's property test, the lifecycle scenario with a holder that answers `pending` and `unavailable`, and the holder core's test, seeded below |
| **WF15.** Nothing above the seam to the chip names the firmware | the station speaks `erx_wifi_mlme`'s records; only `erx_bwfm` and its cores include the firmware's generated layouts, and nothing else calls them | a `wsec_key` built in the join machine | the build check, with a test that a planted call fails it |
| **WF16.** No open BSS is admitted but by a statement that the network is open | `admit/4` admits an open BSS only under a block whose `key_mgmt` is `NONE` or under `want` `{open, SSID}`; the names are `unavailable` or `{ok, _}`, never empty for unavailable; a block is open or protected, never both | an impostor without protection joined under a saved SSID while the holder does not answer, after a `forget`, or under `ssid NAME` | the choice's property test, seeded below |
| **WF17.** Only a session that holds `wpa_admin` adds, replaces or removes a network's secret | `wpa_key` has no such operation, and the release manifest check refuses `wpa_admin` granted to a configured domain and a `wifi` row without `wpa_key` | the station enrolling a network; `wpa_admin` in the WiFi domain's row | the interface's schema; the manifest check with a seeded manifest |
| **WF18.** What the chip and the air send cannot grow the station's queue or table, or stop its scanning | the station's credit bounds `eapol`, `auth_frame` and `scan_result` indications; every other indication answers one request at most once; the BSS table holds at most `wifi_bss_max` records; the chip process ends every scan within 10 s | the station's mailbox growing while it waits for the holder; a scan without end that keeps the station from joining | the flood scenario with a stalled holder, seeded below |

## Concurrency and ordering

* **One owner per conversation.** The SDIO host owns the card's bus, the
  chip process the chip, the station the network state, the key holder
  the entries, each driver in the network domain its link. No two
  processes share state; they exchange messages.
* **The host serializes the card.** Lists run one at a time in arrival
  order, a list's steps back to back. EMMC2's process and the SDIO host
  run concurrently on separate controllers and share nothing at run
  time: the line is EMMC2's alone (WF11), so neither waits on the other.
* **The chip process orders what it sends.** Frames and requests from
  the station reach the bus in the order the station issued them, so
  message 4 is written to function 2 before the `wsec_key` request that
  follows it on the control channel, as brcmfmac waits for its pending
  EAPOL frames to reach the bus before it sends a key
  (`cfg80211.c:607`). Whether the firmware transmits a
  frame queued before a key request with the old key is the firmware's;
  W4's board test settles it ([Facts](#facts-this-design-does-not-have)).
* **A key request is answered before the next event.** The station
  performs a request to the key holder as a call, with a deadline of
  2 s, and gives the answer, or `unavailable` at the deadline, to the
  step before it takes anything else from its mailbox. So the join
  machine has no state that waits for the holder, and the exhaustive
  test explores no interleaving of a request with another event. The
  chip's indications queue meanwhile, within the station's credit
  ([The seam](#the-seam-to-the-station)); the handshake's deadlines are
  longer than the call's.
* **One join, one exchange.** The station runs one join at a time and
  the holder keeps one exchange, replaced by the next `sae_commit`, so
  nothing of an ended join's exchange serves another.
* **Credits bound every queue.** The chip process sends the network
  domain frames only within the driver's credit and takes them only
  within its own; SDPCM's window bounds what it writes to the chip; the
  station's frames and requests wait in the chip process's mailbox, at
  most the handful the join machine has in flight; the station's credit
  bounds the indications the air or the firmware can repeat, and each
  other indication answers one request at most once; the chip process
  reads at most 32 frames a notice. A frame or indication that finds no
  credit is dropped and counted.
* **Timers belong to the station and the chip process**, as deadlines
  in their state, checked at each event; the cores take the time as an
  input and answer `next_deadline/1` ([design.md](design.md#drivers-and-dma),
  "Deadlines in state"), and the memory's holds are compared with it,
  never timed.

## Failure handling

| What fails | What notices | What survives | Recovery |
| --- | --- | --- | --- |
| No card answers CMD5: power, pins or a missing chip | `attach` answers `no_card` | everything else | the WiFi domain logs one line naming the unknown facts and ends; the domain service's restarts bound the retries, then it stays down |
| A command times out or the card reports an error | the step's result | the attachment, until the client acts | the chip process ends, so the WiFi domain restarts and attaches afresh |
| A CMD53 runs slowly, up to its one deadline, 1 s from its issue | the SDIO host's poll | EMMC2 and its line, which never wait on the SDIO host | none needed; a deadline is a device error |
| The firmware fails its read-back, a bring-up wait runs out, or the firmware does not start or stops answering control | `erx_bwfm_boot`; the wait's bound; a 2.5 s control deadline | the storage and network domains | the WiFi domain restarts, reloading the firmware |
| A frame from the chip fails a check | the core | everything | the frame is dropped and counted; a bad header ends the read-ahead |
| The firmware or the air floods EAPOL, SAE frames or scan results, or the station is held in a call to the holder | the chip process's credit; the BSS table's bound | the station, its queue at most the credit and a handful, and its join, which the access point's retransmissions complete | the excess is dropped and counted as `ind_dropped` and `bss_dropped`; nothing waits on it |
| The firmware never ends a scan | the chip process's 10 s deadline | the radio | `scan_end` with `timeout` and the results found; the next choice runs |
| A handshake or SAE message fails a check | the core | the association, until its deadline | dropped and counted; a deadline or a deauthenticating check ends the join |
| A join ends before its port has stayed open `wifi_short_link` | the join machine, with the end's class | the other access points and networks | the memory holds the BSS, and after three ends of the `secret` class the SSID's secret; the station scans at once and joins the next candidate ([Failure memory](#failure-memory)) |
| A network's secret is wrong, or an impostor tests guesses of it | three joins ending in the `secret` class | every other network | the SSID's verdict is `{held, secret_failed, Until}`; one attempt when the hold ends, at most one an hour; a new secret, with `wlankey`'s `names`, ends the hold |
| A key install is refused | `set_keys_confirm` | the WiFi domain | the join ends: the station deauthenticates and deletes what it installed |
| The key holder answers `unavailable`, or not within 2 s | the station | the configuration, open networks of a block, the station's marks, and a port already open, until its next rekey asks for a PTK | a join that needed the answer ends with the class `none`; the names are `unavailable`, so every protected network and every SSID no block names reads `keys_unavailable` and no open BSS is admitted but by a statement; the station asks `names` again before each choice; `wlankey` reports `unavailable` |
| The holder cannot publish a change: a trial boot, or a store that fails | the publication's answer | the change in the holder's memory, for a mark | `set` and `forget` answer `unavailable`; a mark is recorded and answered `pending`, enforced, and written at the next change the holder publishes ([The SAE-only mark](#the-sae-only-mark)) |
| The holder restarts, the vault | the facet's answers | the entries and the `kept` marks, which are its file | the exchange in progress is lost with it: the join ends, and the next join starts a new one; a `pending` mark is lost, which the station logged as pending when it learned it |
| The SDIO host faults | `erx_sdio_sup` | EMMC2, `/data` and line 126, on which the host never signalled | restarted 3 times in 60 s, then WiFi stays down until the storage domain's next start |
| The storage domain restarts | the attachment's monitor | the network domain | the WiFi domain ends with its attachment, and its restart waits for the storage domain's facet, as at boot |
| The WiFi domain restarts | the offer's monitor in the network domain | `genet0` and every connection on it; the networks' entries | `wlan0`'s link ends; the new chip process offers again once its firmware runs, and the station joins with an empty memory |
| The network domain restarts | the chip process's monitor of the driver | the association | the chip process offers again once a second until the network domain answers, with a new `Ref` |

Each failure ends at most the conversation it is part of, and the
recovery is a restart that exists already, the WiFi domain's, the
storage domain's or a link's, or the next choice.

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
| the key holder's `{error, full}` | a `set` for a new SSID at 16 entries |
| the key holder's `{error, no_secret \| sae_only \| no_pmk \| no_commit \| no_entry \| bad_element}` | an operation whose entry, mark or exchange does not allow it ([Credentials](#credentials)) |
| the key holder's `{error, unavailable}` | the holder not answering, a `set` or `forget` it cannot publish (a trial boot's change), a development file that cannot be read or replaced, or a random generator that gave no usable SAE values in a hundred draws |
| the key holder's `pending` mark | a `mark` it recorded and could not yet publish ([The SAE-only mark](#the-sae-only-mark)) |
| the key holder's refusal of a request | a field of the wrong length, a Rejected Groups list of an odd length, an AKM that is not one of the three, a `set` with neither secret; the facet ends the request with `badarg` |
| `wlankey`'s refusals | a passphrase outside 8 to 63 printable ASCII characters and not 64 hexadecimal digits, an SAE password outside 1 to 128 bytes, an identifier over 64 bytes, an SSID outside 1 to 32 bytes; and the holder's `full` and `unavailable`, printed with the SSID |
| `ctl` `einval` | a command that is not one of [the tree's](#control-and-inspection), `ssid` and `country` without a valid argument |
| `ctl` `eio` | `scan` or `ssid` while the radio is down; `names` when the key holder answers `unavailable` |
| `ctl` `ebusy` | `scan` while a join or a rekey is in progress |
| a BSS's verdict at `/proc` | `unknown`, `{held, bss \| secret_failed, Until}`, and the refusals `not_wanted`, `no_secret`, `keys_unavailable`, `sae_only`, `no_sae_ext`, `no_h2e`, `pmf_required`, `pmf_unavailable`, `akm_unsupported`, `cipher_unsupported` and `not_open` |
| the station's reasons at `/proc` | `no_country`, `config {Line, Key}`, `config {Line, secret_in_file}`, `keys_unavailable`, and the last join's end: `connect {Status}`, `connect_timeout`, `sae {Status}`, `sae_confirm`, `sae_timeout`, `sae_rejected_group`, `connect_rsne`, `handshake {Check}`, `handshake_timeout`, `install_refused`, `disconnected {By, Reason}`, `short_link` |

## Untrusted input

Every byte from the chip, the air through the chip, the configuration
file and the `ctl` commands is untrusted, and so is every request the
key holder takes from the WiFi domain or a session. Each parser is a
pure core with
checked lengths and offsets and lands with its fuzz target, built for
the host:

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
| `erx_wifi_fs` | `ctl` commands | `fuzz_wifi_ctl` |
| `erx_wpa_holder` | the requests of `wpa_key` and `wpa_admin`, at the holder; a development build's `keys` file | `fuzz_wpa_holder` |
| `erx_ether` | the `ether` messages, at the driver | `fuzz_ether` |

Every layout they read is declared once: `abi/formats/sdio.txt` (the
CMD52 and CMD53 fields, R4 and R5, the CCCR and FBR offsets and which
are host-owned), `abi/formats/bwfm.txt` (SDPCM's headers, BCDC's, the
event message, the BSS record, the escan, join and key structures, the
management-frame and authentication-status structures, the event
numbers), `abi/formats/ieee80211.txt` (element ids, RSN and RSNXE
fields, suite selectors, the AKM table, EAPOL-Key frames and KDEs, the
Transition Disable KDE and its bits, status and reason codes, SAE's
elements) and `abi/formats/wpa_keys.txt` (the development holder's
file). The generators produce the Erlang records and binary patterns,
and their fuzz seeds.

An SSID, a firmware version string and a `cap` string are text from an
untrusted source: they reach `/proc`, the log and the console only
through each sink's escaping function, and `ifconfig` writes an SSID
FreeBSD's way, as hexadecimal unless every byte is printable ASCII.

## Security

**Authority.** The WiFi domain holds the card's I/O through one facet,
the right to lend one named link, a read-only view of its own
configuration tree, the station's facet of the key holder, and its own
tree. It holds no device, register, line or DMA memory, no grant of the
network but its medium, and no facet that gives or forgets a secret. It
reaches no other file of the data partition and can write neither its
own configuration nor the holder's entries. The storage domain's SDIO
host parses only fixed-size responses and status words, refuses any
write to the registers its own state depends on, so its client cannot
desynchronize the bus, and never enables the controller's signal, so
its client cannot reach the shared line. The network domain sees frames
within credits and checks their sizes as for every medium.

**What a break of the WiFi domain gives.** Whoever breaks its parsers
from the air has what a radio attacker near the board already has, the
medium; the card's registers, which a hostile firmware already has; the
keys of the association in progress; and `wpa_key`, for as long as the
break lasts. With the facet it joins the saved networks as the station
would. It does not leave with a PMK or a PT, but it can leave with
PTKs: for a PSK network a PTK, with the nonces and addresses it was
asked for, is an offline test of the passphrase, as an eavesdropper's
recording of a WPA2 handshake is, so a break can test guesses of a PSK
network's passphrase at its own speed, after it has ended and wherever
it has taken them. A strong passphrase stays unknown; a weak one does
not, under PSK, as under every WPA2 station. For SAE the facet answers
no such test: the KCK of an exchange depends on `rand`, which the
holder keeps, so each SAE exchange the break drives tests one guess, as
each exchange on the air does. A restart of the domain, which reloads
the firmware, ends the use of the facet. The break cannot give the
holder a network, replace a secret or forget one: `wpa_key` has no
operation for it, so nothing of the break's choosing outlives it. It
can mark a network SAE-only, which costs availability on a network
that still serves WPA2 until an administrator forgets and gives the
secret again, and no passphrase passes through it, since `wlankey`
derives in the administrator's session. A key facet is an oracle for
its purpose's protocol role, as the vault's SSH and TLS facets are
([design-system.md](design-system.md#security)); what the purpose adds
to the vault is its arithmetic and three checked values of
the air's choosing, the peer's scalar, element and Rejected Groups
list, inside the boundary of every principal's keys.

**Where the secrets live.** A passphrase is typed into root's session
and stays there: `wlankey` derives the PMK and the two hashed values in
the session and sends those, through the system domain's facet, to the
holder, which makes PT and keeps the entry. From then on a secret
leaves the holder only as the protocol's values: a commit, an
exchange's KCK, a PTK. The keys the station installs, the TK, the GTK
and the IGTK, go to the chip as the bytes of `wsec_key`'s CMD53 writes,
so the storage domain's SDIO host has them in its messages and memory
while a list carries them, and the firmware keeps them. The system
domain and the vault are inside every machine secret's boundary
already, and the storage domain inside the data partition's. Within
the WiFi domain:

| Secret | Held by | Dropped |
| --- | --- | --- |
| SAE's KCK | the join's exchange | once the peer's confirm is checked |
| the pending PTK and the installed PTK, GTK and IGTK | the key slots | when the join ends, with the chip's keys |
| the TK, GTK and IGTK as `wsec_key` bytes | the chip process, until the request's list has run | when the list has run |

No passphrase, PMK, PT, `rand`, `mask`, PWE or K is in the table: the
passphrase is the session's, the others the holder's. A development
build's holder is a process of the WiFi domain, which then holds all
but the passphrase; that is the residual below. In the session, the
passphrase is held by `wlankey` from the tty's read until its request
is sent.

Dropping is not erasing. Erlang has no way to clear a term: a dropped
binary's bytes stay in the domain's memory until the collector or the
allocator reuses it, as for every term of the SSH domain
([design-ssh.md](design-ssh.md#edits-to-otps-ssh)). So the table bounds
how long a secret is reachable from the domain's processes, not how
long its bytes stay in memory.

**What diagnostics carry.** Two rules keep secrets out of what the
domain reports, each by construction rather than by a list of secret
fields:

* **Reports carry no term.** Every process of the WiFi domain is a
  `proc_lib` process, as OTP's behaviours are, so every report its end
  makes is a logger event of OTP's domain. The domain takes the
  report filter, `erx_report`, at boot
  ([design-log.md](design-log.md#reports-carry-no-term)), which rewrites
  every event of OTP's domain to names, classes and arities and drops
  every other term. So no report carries a term a process held,
  whichever process held it and whatever raised.
  The station's `/proc` paths and its own log lines are built from named
  fields, none of them a secret. `sys:get_status/1` returns a process's
  state whole, but only to a caller in the WiFi domain: from another
  domain every `sys` call times out
  ([design-domains.md](design-domains.md#operations-on-another-process)).
* **Dumps omit the holders.** The station, the chip process and a
  development build's key holder each set
  `process_flag(sensitive, true)` at their start, so a crash dump of the
  domain leaves out their stacks, messages and dictionaries, through
  which every term they hold is reached
  (`otp/erts/preloaded/src/erlang.erl:8285-8305`;
  `otp/erts/emulator/beam/erl_process_dump.c:233`, which skips such a
  process's section whole), and no trace reaches them. The domain keeps
  its crash area and its fault records as every configured domain does;
  it does not take `ERX_DOM_SECRET`, which is the vault's alone and comes
  with the sealing page
  ([design-system.md](design-system.md#the-domain-library), the
  record's `flags`). A fault record's registers may hold bytes of a key
  in use at the fault. A development build's full crash record of the
  system domain may hold a `set`'s PMK or hashed values in transit, as
  it may hold a passphrase typed at a login
  ([design-system.md](design-system.md#risks-and-open-questions)).
  `wlankey`, a session's command, sets the same flag for the moment it
  holds the passphrase.

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
  air through the station's requests. The fix is inside the three
  functions: the P-256 method's own field and point routines, which the
  tree's OpenSSL holds (`ecp_nistz256.c:110, 250-252`) and does not
  export. It blocks release.
* **The development key holder contains and seals nothing.** Before the
  release placement, the holder is a process of the WiFi domain and
  the PMKs and PTs sit unsealed in its `keys` file on the data
  partition: a break of the WiFi domain, a session that holds the data
  partition's tree and a copy of the medium each read them, and a break
  of the WiFi domain can write the file, so enroll a network, and lose
  a `pending` mark with the domain's restart. No passphrase enters the
  domain even so. The release placement closes it; it blocks release,
  and the release manifest check refuses a `wifi` row without `wpa_key`
  or with `wpa_admin`.
* **Regulatory.** The chip enforces the CLM blob's rules for the country
  it is given; a wrong country is a legal question, not a crash.

## Facts this design does not have

These facts live only in GPL sources (the board's device tree and
Linux's SDIO and controller drivers) or only on the board. The GPL ones
are settled by the clean-room facts record
[research-wifi-pi4.md](research-wifi-pi4.md), written by a separate
agent from Linux v7.3.4 and cited here by fact number; the design's
other values come from FreeBSD, OpenBSD, brcmfmac's ISC sources and the
published specifications ([Sources](#sources)). The board probe settles
the rest. The design depends on one board fact, that the firmware leaves
`WL_REG_ON` on (F2), and adds no mechanism for it; it works whichever
way the others fall. W0 fails safely, with `no_card` and a log line
naming this list, when one is against it.

| Fact | Where it lies | What the design does with it |
| --- | --- | --- |
| **F1.** Whether GPIO 34 to 39 are in ALT3 when the firmware starts the kernel | the board probe; the tree gives the slot GPIO 34 to 39 in ALT3, the clock on 34 with no pull and 35 to 39 pulled up, and says nothing of their state at handover (fact 33) | if not, the slot's pins are set as UART0's are: on-board rows of the board's pin table, with the pulls the tree states, which the system domain's pin driver sets at its start, before the WiFi domain exists ([design-pinctrl.md](design-pinctrl.md#at-start)). The root's boot write, the implementation that driver replaces, sets functions only and would leave the pulls as the firmware set them. A `gpio=` line is suspect for them: the firmware leaves UART0's GPIO 30 and 31 inputs whatever such a line asks ([research-bluetooth-pi4.md](research-bluetooth-pi4.md#2026-11-23-the-firmware-leaves-uart0s-flow-control-pins-unset)) |
| **F2.** `WL_REG_ON`: its line, polarity, power sequence and state at handover | the facts record for all but the state (facts 1 to 5): a line of the firmware's GPIO expander, not a SoC pin, and active-low,
so the chip runs while the line is high. The state at handover is not in the tree (fact 7): the board probe | No domain reaches the expander (PL2), so nothing in erXos powers the chip: the design depends on the firmware leaving `WL_REG_ON` high at handover, an open board fact. If the probe finds it low, the chip answers no CMD5 and W0 fails with `no_card`. The design then adds no access to the firmware's mailbox or the expander, implicit or otherwise; how the chip gets power returns to the architecture as a decision of its own, taken before anything is built for it |
| **F3.** A host-wake out-of-band interrupt line | settled by the facts record: there is none (facts 9 and 10) | none is used: the SDIO host polls the card's in-band interrupt |
| **F4.** The legacy controller's base clock | the board probe, as for EMMC2 ([design-storage.md](design-storage.md#the-sd-host-controller), "The controller's clock"); the tree names the clock manager's EMMC clock with no rate, which the firmware sets, and Linux takes the rate from its clock framework (facts 21 and 34) | the platform record's `clock` for the unit's entry; with none, the SDIO host refuses to attach |
| **F5.** The bus width and maximum clock the tree gives the slot | settled by the facts record: 4 bits, limited by the controller's base clock (facts 12 to 15) | 4 bits at 25 MHz, which every full-speed SDIO card supports, after identification at 400 kHz; 50 MHz waits for [Performance](#performance) |
| **F6.** Quirks of Linux's driver for this controller, beyond FreeBSD's and OpenBSD's | settled by the facts record: none beyond them (facts 16 to 23) | [The legacy controller's record](#the-legacy-controllers-record) carries them; the spacing stays 6 us after every non-data write |
| **F7.** Byte-mode CMD53 limits and delays after function enable | settled by the facts record (facts 24 to 30) | byte mode within 512 bytes and the function's block size, as [The `sdio` interface](#the-sdio-interface) has it; the chip process's waits and their bounds ([The chip](#the-chip), "Waits") |
| **F8.** Whether the Pi's firmware build offers `sae_ext` and the events 187 to 190, and `mfp`, and whether its external authentication and PMF work | the chip's `cap` and `mfp` answers at W1; the exchange and PMF at W5, on the board | without them SAE networks are not candidates and WPA3 is reported unsupported; another licensed Cypress build is looked for before anything else ([SAE](#sae-and-protected-management-frames)) |
| **F9.** Whether the firmware sends message 4 before applying a key requested after it | W4 on the board | the chip process keeps the order; if the firmware does not, the station waits for message 4's transmission before installing, a change to the station alone |
| **F10.** What the firmware does with no country set, which country its CLM blob then applies, and whether it takes `country` while its interface is down | the board, with the pinned firmware and CLM blob | nothing transmits until a country is configured; if `country` is not taken while down, the order becomes `up`, `country`, then the first scan, still with no scan or join before the country |
| **F11.** How a wrong PSK shows on this firmware: no message 3 until the deadline, or a deauthentication, and with which reason | W4 on the board, under the test access point's `wpa2-wrong` profile | both end the join in `keys` after message 2, the `secret` class either way ([Joining](#joining)); the reason at `/proc` is whichever the board shows |
| **F12.** Whether a message 1 can reach the host before the event that confirms the association | W4 on the board; iwd and Fuchsia each keep one early EAPOL frame for this order (iwd fact 41; `state/mod.rs:124-126`) | a message 1 in `joining` is dropped and the access point's retransmission is taken in `keys`; if the board shows the early frame, the join machine keeps one EAPOL frame from `joining` and replays it at the confirmation, a change to the machine alone |
| **F13.** Whether the firmware scans while associated | W2 and W3 on the board | a scan runs while the port is open; if the firmware refuses one, `scan` fails with `ebusy` there as it does during a join |
| **F14.** Whether the firmware puts an RSNXE in its association request, given one in the association request's element list or of its own | W5 on the board, from `connect_confirm`'s `Sent` under the `wpa3` profile; brcmfmac hands the firmware the RSN element through `wpaie` and only vendor-specific elements through that list (`cfg80211.c:2491-2495, 4908`) | message 2 repeats `Sent`, so the station agrees with the access point either way; if the firmware sends none, an SAE join's association request carries no RSNXE, and whether the access point then accepts hash-to-element is part of W5's probe |

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
idle; and two costs of the station's own: the time from a lost link
to an open port, which a scan of every channel dominates and a scan of
the channels last joined would shorten, and the throughput on an
access point of two bands joined by signal alone. The fixes on the
table for the bus, in the order they are cheap: a poll
period tuned to the measurement, high speed at 50 MHz, glom on transmit, a C bulk copy of the
data port, the SoC's DMA controller on DREQ 11 as FreeBSD uses it
(`bcm2835_sdhci.c:126`), and the chip process inside the network domain
([Alternatives considered](#alternatives-considered)).

## Verification

Every parser has its fuzz target ([Untrusted input](#untrusted-input)).
Each test below names what it holds and the seeded fault that proves the
code under test ran.

**Host cores.**

* **`erx_sdio:check/2`**, a property test over random lists: every
  accepted list stays within the card's functions, addresses below 2^17
  and the CMD53 limits of the wire, the function, the controller and the
  list, and writes no host-owned register. Seeded: `07h` left out of the
  host-owned set (a write to the bus width passes); byte mode bounded by
  the block size alone (a 768-byte CMD53 under a 1,024-byte block
  passes).
* **The controller core's command wait**: a 3-block CMD53 completes
  after three buffer events and transfer complete, in either order of
  command complete, and EMMC2's identification commands keep their
  one-block tests. Seeded: a wait that ends its data track at the first
  block.
* **The SDIO host's core**, over generated sequences of attaches, lists,
  polls and rearms and against a fake controller whose one-to-clear bits
  stay set until written back and that raises the next block's buffer
  event as a block is moved: `irpt_en` is written only as zero (WF11);
  a card interrupt yields exactly one notice until the next `rearm`; a
  `run` with a previous attachment's `Ref` is refused (WF7); each event of
  a many-times-polled CMD53 is taken once, and a snapshot with transfer
  complete and the card interrupt together does both. Seeded: an attach
  that sets the card interrupt in `irpt_en`; a host that ignores `Ref`; a
  poll that never writes back (a second command complete); a poll that
  writes back after the wait's actions (the CMD53 misses its deadline).
* **`erx_blk_write`'s SDIO table**: every command word has the fields of
  SDIO 5.1 and 5.3, checked against OpenBSD's encoding
  (`sdmmc_ioreg.h:27-50`); `sdio_issue/2` refuses an SD record and
  `sd_issue/2` an SDIO one. Seeded: the block-mode bit cleared; a block
  count of 0 encoded.
* **`erx_sdio_card`**: a recorded identification to the selected 4-bit
  card, and `no_card` at a silent CMD5. Seeded: S18R set in the second
  CMD5.
* **`erx_bwfm_sdpcm`**: headers, credit and glom against built frames and
  board recordings, the credit across sequence wraparound, a header-first
  read of a 1,500-byte frame accepted and an over-declared read-ahead
  refused, and an event-shaped Ethernet frame on the data channel or in a
  glom read as `{data, _}` (WF10). Seeded: a credit that ignores the
  window's top bit (`if_bwfm_sdio.c:1079-1080`); a length check against
  the 12 bytes of a header-first read; a frame's kind taken from its
  ethertype.
* **`erx_bwfm_nvram`**: the pinned NVRAM file's conversion against a
  golden computed by hand once. Seeded: comment lines kept.
* **`erx_bwfm_mlme`**, over sequences of requests and events: an event
  becomes an indication only for the current connection; one
  confirmation per request; nothing of a connection after its
  `disconnected`, a late link-down of an earlier connection to the same
  BSS becoming the new one's single `disconnected`; every scan ends, by
  its end event or by `timeout` at 10 s; repeatable indications pass only
  within the credit. Seeded: a second confirmation; a connection kept
  after `disconnected`; no scan deadline.
* **`erx_wpa_kdf`**: PRF-SHA1, the PSK, KDF-SHA256 and the MICs against
  IEEE 802.11-2020 Annex J's vectors as wpa_supplicant's tests carry
  them, AES key unwrap against RFC 3394's.
  Seeded: the PTK's address order reversed.
* **`erx_sae` and the holder's SAE steps**: PT and PWE against Annex
  J.10's vectors (`common_module_tests.c:254-259, 400-497`), the two
  hashed values computed by `erx_wpa_secret` and PT by the holder; a full
  exchange between two instances with holder cores of their own, with
  and without a Rejected Groups list; a recorded hostapd exchange with
  the holder's random values injected; a scalar of 1 from the entropy
  seam replaced by a valid pair; an off-curve peer element answered
  `bad_element`, dropped and counted while the exchange goes on; a
  Rejected Groups list naming group 19 ends the exchange as `bss`.
  Seeded: the element not negated; `sae_key/5`'s `badarg` escaping the
  holder core; the keyseed salted with zeros whatever the list; a list
  check that ignores group 19.
* **`erx_wpa_holder`**, over `erx_wpa_arith`: `set`, `ptk`,
  `sae_commit`, `sae_key`, `mark`, `names` and `forget` answer as
  [Credentials](#credentials) states, the mark `pending` when the store
  refuses the write and `kept` when it takes it, kept by a later `set`
  and cleared by `forget` (WF14); a seventeenth SSID is `full`; a wrong
  length, an odd Rejected Groups list or a `set` with no secret is
  refused; over every sequence of both facets' operations up to a bound,
  no answer but `ptk`'s and `sae_key`'s carries a byte of a marked PMK,
  PT or `rand` (WF5); a development file of 16 entries round-trips, and a
  truncated or overrunning one makes every operation `unavailable`.
  Seeded: a `set` that clears the mark; a `ptk` that ignores it; a mark
  recorded only once written; `names` returning the entry; a file decoder
  that trusts an entry's length.
* **`erx_wifi_join`, exhaustively.** The join is a protocol state
  machine: every sequence of its events up to a bound is explored, with
  the holder's answers, forged, replayed and retransmitted EAPOL and SAE
  messages (a wrong MIC, a stale replay counter, another RSN element, a
  wrong nonce, message 1 with a large counter, message 3 again with a
  higher counter, a group message replayed after a rekey replaced its
  GTK, a GTK of key id 0), genuine rekeys, installs confirmed late or out of order, events that
  do not apply, the holder's `unavailable` and an SAE peer silent after
  the station's confirm. The properties: every transition taken is in
  `table/0` and every edge of `table/0` is taken (WF12); no `set_keys`
  after a failed check, no watermark raised by message 1 (WF8); no key
  installed that equals its slot's or that a slot held before (WF9); a
  slot confirmed only by its last install's confirmation; after a
  handshake the pairwise slot holds the TK and GTK slot `N` key id `N`,
  0 included; a genuine rekey installs its new key, and one its deadline
  ends returns to `open` with the keys unchanged; the port open only with every key
  confirmed (WF4); no scan and a pending deadline wherever a handshake
  waits; no PTK or PMK derived by the machine (WF5); message 2's RSN
  element and RSNXE equal `Sent`'s; genuine messages complete a handshake
  whatever forged message 1s came first, once the access point
  retransmits its message 1; `{transition_disable, SSID}`
  exactly for an accepted message 3 of an SAE join with bit 0 set; every
  end carries its table's class; every path returns to `idle` within its
  deadline. Seeded, each found by the exploration: message 3 accepted
  without the RSN element comparison; every accepted message 3
  installing; a slot filled only at the chip's confirmation; a
  confirmation that confirms every slot; the watermark raised at message
  1; group messages taken without the watermark; GTK key id 0 indexed as
  the pairwise slot; group message 1 checked by message 3's rule;
  `eapol` in `open` removed from the table; `rekey`'s `deadline` cell
  removed; message 2 built from the elements asked for, not `Sent`; the
  port opened at message 3; the indication reported on a PSK join; SAE
  silence classed `bss`.
* **The choice**, a property test over generated views (every block's
  `key_mgmt` and `ieee80211w`, the BSS's AKMs, MFPC, MFPR and
  hash-to-element bit, `sae_ext` and `mfp`, the names `unavailable` or
  listing secrets and marks, every `want`, memories of holds): the AKM
  chosen is allowed by the block, offered by the BSS and has its own
  secret; required PMF is never `none`, nor SAE's; an SAE-only block,
  name or mark never yields PSK (WF14); an open BSS is a candidate only
  under `NONE` or `{open, SSID}` (WF16); with the names `unavailable` no
  protected BSS is a candidate; the pick is an unheld candidate that none
  outranks; the memory changes a verdict only where a candidate is held
  (WF13). Seeded: `ieee80211w` 2 read as 1; a candidate test by any
  secret instead of the AKM's; an `admit` that drops SAE for a held BSS;
  a pick before the holds; `unavailable` names read as an empty list (an
  open impostor picked); the station's marks left out of the view.
* **`erx_wifi_memory` and the lifecycle**, as scenarios over
  `erx_wifi_sta` with a scripted time: the second choice joined while the
  first is held; three `secret` ends hold the SSID's secret until the
  hold ends or `names` shows a new secret; a port that closes after 3 s
  counts against its BSS and one after a minute does not; `leave` holds
  until `ssid -`; `scan` during a join or rekey answers `ebusy`; with the
  holder `unavailable`, open networks of a block join and protected ones
  read `keys_unavailable`; a `forget` leaves the joined network; a
  Transition Disable mark refuses a PSK impostor through `pending`,
  `unavailable` and a WiFi domain restart, asked again until `kept`.
  Seeded: a hold at the first `secret` end; a `names` that keeps the
  hold; a held BSS joined when nothing else is in range; the mark added
  only on `kept`; a join kept that the view no longer admits.
* **Diagnostics with marked secrets.** The station, the chip process over
  the fake chip, `erx_wifi_fs`, the development holder and `wlankey` run
  with `erx_report` and a logger handler that keeps every event, under a
  marker passphrase and SAE password and marker entropy, from which the
  test computes every derived secret it searches for. After giving and
  forgetting a secret, joining, sending each holder an unhandled message
  carrying a mark, ending each with an exception that carries the marks
  and halting with a crash dump: no marked value, as bytes or as Erlang prints it, is in any
  event or the dump, the passphrase in no message a WiFi domain process receives, and
  no marked PMK, PT, `rand` or `mask` in the station's or chip process's
  state. Seeded: the filter left out; the station without `sensitive`; a
  `names` answer with the PMK; a `wlankey` that sends the passphrase.
* **Inspection's readers**: a facet of scope `all` reads every attribute
  of the three paths; a principal-scoped facet reads only public ones and
  gets `{error, scope}` for `wifi networks`. Seeded: the verdict declared
  `visible any`.
* **`erx_wpa_conf`**: the subset parsed, left-out keys read from the
  default block, every refusal with its line, `psk` refused as
  `secret_in_file`, SAE with `ieee80211w=0` and `NONE` beside another AKM
  refused. Seeded: an unknown key ignored; `psk` taken; a left-out
  `ieee80211w` read as 0; `NONE` beside another AKM taken.
* **The build and manifest checks** (WF5, WF15, WF17) as
  [Invariants](#invariants) states them. Seeded: a `wsec_key` built in
  the join machine and a PTK derived there, each failing the build; a
  manifest granting `wpa_admin` to the `wifi` domain, failing the
  manifest check.
* **The crypto edit**: `sae_pt/3` and `sae_commit/5` against Annex J.10;
  two parties' `sae_key/5` agree on K; the scalar equals
  `(Rand + Mask) mod r` computed independently; `retry` for a scalar of 0
  or 1 and for `Rand` 1 or `r`; `badarg` for off-curve points,
  out-of-range scalars and wrong-length hashed values. Seeded: the
  oct2point check skipped; the element not negated; the scalar's check
  against 2 removed.

**Differential against independent implementations.** wpa_supplicant
2.12 and hostapd 2.12, run unmodified, give recordings with a known
passphrase: with the recorded nonce and SAE scalars injected through the
entropy seams, erXos's message 2 and message 4 and SAE's commit and
confirm are byte for byte the oracle's and the derived keys equal. The
recordings include a retransmitted message 3, a group rekey and a
Transition Disable KDE, through which each recorded key is installed
once and the indication reported once. The WPA2 recordings come from
the FreeBSD x86-64 test host over `wtap(4)` (that `wtap` carries hostapd
on FreeBSD 15.1 is *unverified*); the SAE ones cannot, since hostapd's
BSD driver sends and receives no management frame
(`driver_bsd.c:1752-1790`), so they come from the Linux test access
point ([Decisions](#decisions), 4), as do the WPA2 ones if `wtap` does
not serve. Seeded: one byte of the access point's nonce changed.

**The fake chip and its air.** An Erlang process that plays the card
behind the `sdio` interface (CCCR, backplane, firmware read-back, SDPCM,
BCDC, events and frames) runs the whole WiFi domain in hosted mode and
on QEMU `virt`, whose storage domain offers the fake through the same
interface; the network stack's UDP and TCP suites run over `wlan0`
unchanged, and the port test sends a frame both ways before and after
the keys. Seeded: data frames forwarded while the port is closed.

Behind it stands a scripted air, the form iwd's tests take (iwd fact
58): a scenario is data, access points with SSID, address, channel,
signal, security and passphrase, rules that drop, delay and weaken
their frames, and the fake key holder's delays and answers. A small
authenticator built from the supplicant's own cores plays each access
point, so the scenarios test the station's behaviour, not the wire
format, which the vectors, recordings and board hold to independent
implementations. Each runs in hosted mode in well under a second:

| Scenario | Passes when | Seeded fault it fails on |
| --- | --- | --- |
| WPA2, message 4 dropped, the retransmitted message 3 arriving before and after the chip confirms the install | message 4 is sent again each time, each key installed once, the port opens | every accepted message 3 installing; a slot filled only at the confirmation |
| WPA2, the access point's passphrase differs | `secret_failed` after the third join; `wlankey set` with the right one joins at once | the `secret` class never assigned |
| WPA3, an impostor silent after the station's confirm, at a new address each time | `secret_failed` after the third exchange | SAE silence classed `bss` |
| two access points of one SSID, the stronger refusing association | the weaker joined at the second choice | a choice that ignores the memory |
| transition network, Transition Disable with the holder `pending`, a PSK-only impostor, a WiFi domain restart | an SAE join; the mark `pending`; the impostor `sae_only` before and after the restart | a mark the choice does not read; a mark applied only once kept |
| an impostor that fails every SAE exchange | no PSK join follows on a block that allows both | a fallback to PSK after a failed SAE |
| a saved network known only by its secret, the holder `unavailable`, an open impostor under `ssid NAME` | the impostor refused, no open join | unavailable names read as an empty list |
| WPA3, deauthentication 3 s after each port opens | the BSS held as a short link | a memory that counts only ends before the port |
| the holder stalled to its 2 s deadline while the chip floods EAPOL-Key and SAE frames, events and 1,000 BSSs a scan, then a scan that never ends | the mailbox within the credit and requests in flight, the BSS table within 64, drops counted, the scan ended at its deadline, the handshake completing once the holder answers | a chip process that ignores the credit; an unbounded BSS table; no scan deadline |
| the parsers ended by an exception during a handshake | the domain restarts and joins again, nothing marked in a report | the report filter left out |

**The test access point.** hostapd 2.12, unmodified, on a Linux host
with an access-point radio, started by the Ruby harness with one of a
fixed set of generated profiles: `open`, `wpa2`, `wpa2-rekey` (a group
rekey every 30 s), `wpa2-wrong`, `wpa3`, `transition`, `transition-td`
(Transition Disable, bit 0) and `twin` (two BSSs of one SSID, one
refusing the board). The authenticator's fields for the rekey period and
the indication are `wpa_group_rekey` and `transition_disable`
(`ap/ap_config.h:392, 810`); their configuration keys are *unverified*
until the profiles are written. Under `wpa3` the harness also injects,
from a monitor interface, an unprotected deauthentication and
disassociation with the access point's address and a replayed protected
broadcast disassociation, and asks hostapd for a protected
deauthentication; the injecting tool is *unverified* until the host is
chosen. Fuchsia drives an access point from its tests the same way
(`wlan/tests/README.md`). The FreeBSD x86-64 test host, the data peer of
[Performance](#performance), serves `open` and the WPA2 profiles
([Decisions](#decisions), 4).

**The board,** by hand, as the Pi's checklist, each step naming its
profile: W0's and W1's log lines; no scan before a country
(`no_country` at `/proc`); a scan listing the test access point with
  its verdict; DHCP, ping and TCP under `open`, across a
rekey under `wpa2-rekey`, and under `wpa3`; `secret_failed` and recovery
under `wpa2-wrong`; the mark under `transition-td`; the accepting BSS
under `twin`; under `wpa3`, the link surviving the unprotected and
replayed frames and rejoining after the protected deauthentication,
which shows whether the firmware checks management frames as
[SAE](#sae-and-protected-management-frames) assumes; the RSNXE sent
(F14); the WiFi domain killed under load and rejoining while `genet0`
carries on; a 64 MiB write to `/data` and a TCP transfer over `wlan0`
together, no storage request near its deadline; the storage domain's
power-cut checklist with WiFi under load. QEMU has no WiFi device for
any machine.

## Interfaces

* `abi/services/sdio.txt`: the `sdio` interface; `abi/services/ether.txt`:
  the `ether` interface.
* `abi/services/wpa_key.txt` and `abi/services/wpa_admin.txt`: the key
  holder's two interfaces, the station's five operations and the
  administrator's two, served by the vault's purpose
  `{wpa, Service}` with its two facets ([Credentials](#credentials)).
* `abi/formats/sdio.txt`, `abi/formats/bwfm.txt`,
  `abi/formats/ieee80211.txt`, `abi/formats/wpa_keys.txt`: the layouts
  and tables above.
* `abi/inspection.txt`: the paths `wifi`, `wifi scan` and
  `wifi networks`, with each attribute's readers
  ([Control and inspection](#control-and-inspection)).
* The `wifi` tree's `ctl` file and its commands; `ifconfig`'s `scan`,
  `list scan`, `ssid`, `authmode open` and `country` for `wlan0`; the
  session command `wlankey`.
* The device-kinds row `sdio sdhci` for the legacy controller.
* The Pi's manifests: the `wifi` domain, the services `wifi_sdio`,
  `wlan0`, `wifi` and `wifi_etc`, their facet rows, `wpa_key` granted to
  the `wifi` domain and `wpa_admin` to root's session template; in a development
  manifest, the WiFi domain's grant of its own tree, `wifi/`, and
  `wpa_admin` served by the WiFi domain, which the release manifest
  check refuses.
* The data partition's storage service: the `wifi_etc` tree, a service
  directory of its own.
* The network domain's configuration: `wlan0` with transport `ether`.
* `otp/lib/crypto`: `crypto:sae_pt/3`, `crypto:sae_commit/5`,
  `crypto:sae_key/5`.
* Erlang: `erx_sdio`, `erx_sdio_card`, `erx_sdio_host` and
  `erx_sdio_sup` in `erx_blk`; `erx_wifi` with `erx_bwfm` and its cores,
  `erx_wifi_mlme`, `erx_wifi_station`, `erx_wifi_sta`,
  `erx_wifi_choose`, `erx_wifi_join`, `erx_wifi_memory`, `erx_wpa_key`,
  `erx_wpa_kdf`, `erx_sae`, `erx_wpa_conf`, `erx_wifi_keys`,
  `erx_wpa_holder`, `erx_wpa_arith`, `erx_wifi_keys_dev` and `erx_wifi_fs`,
  over the report filter `erx_report` the domain takes at boot; `erx_wpa_secret` and the `wlankey` command;
  `erx_ether` and `erx_net_ether` in `erx_net`.
* Host tooling: the test access point's profiles and the harness
  command that starts hostapd with one.
* The dependency table: the Cypress CYW43455 firmware, NVRAM and CLM
  files; wpa_supplicant and hostapd 2.12, the differential oracle and
  the test access point.

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
may run until its 1 s deadline, servicing line notices between its
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
([design-system.md](design-system.md#the-vault)).

**The networks' keys in a state slot, read whole by the WiFi domain.**
The vault would stay free of WiFi's arithmetic and store one opaque
blob, as it stores Bluetooth's bonds
([design-system.md](design-system.md#state-slots)). A state slot is for
a secret that must leave the vault at every use, as a bond's key must
reach the controller. The PMK and PT never have to: the chip takes the
session's keys alone. Read whole, they would sit beside every parser of
the air, and a break there would take every saved network's password
equivalent, the office's with the cafe's; and the WiFi domain would
decode the blob, track whether it had read it, and reason about a
replacement that may or may not have been published.

**Secrets given through the WiFi domain's `ctl`.** One command beside
the others, and the station would learn of every change at once. But
the passphrase would pass through the domain that parses the air, where
dropping a term does not erase it, and the facet that carries it to the
holder would be the WiFi domain's, so a break of the parsers could give
the holder a network of its own choosing that outlives the break. The
administrator's facet removes both, at the cost of the `names` command
or a wait for the next choice.

**The passphrase to the holder, which derives the keys.** The holder
would take one value and do PBKDF2 itself, and under the vault's
purpose the passphrase would stay out of the WiFi domain too. But in a development
build, where the holder is a process of the WiFi domain, it would enter
it, and every placement would have to take a passphrase and check its
form. Deriving in `wlankey` keeps the passphrase in the one session
that typed it whatever the placement, and leaves the holder fixed-length
inputs of which every value is valid.

**A notice from the holder when its entries change.** The station would
learn of a `set` or `forget` without the `names` command. But a key
facet answers requests and sends nothing of its own; a notice would be
a new kind of message from the vault. Reading the names before every
choice makes a change take effect within one choice, and `names` makes
it immediate.

**A boundary before reusing a BSS's address.** The chip process could
wait, after a connection ends, for the firmware's own word that it has
finished with the BSS before connecting to it again, so that no late
event of the old connection reached the new one. But the firmware's
events name no join, and which event, if any, ends a connection in
every case, and in what order it arrives relative to control replies,
is in no source this design read. The seam instead bounds what a late
event can do ([The seam](#the-seam-to-the-station)), which costs at
most a join ended early and a BSS held 10 s.

**A prompt for a missing secret.** wpa_supplicant asks its front ends
with a request in its control protocol and iwd calls a registered
agent. Either is a live conversation with a protocol of its own; the
verdicts at `/proc` give a front end the same knowledge as state it
reads, and `wlankey` takes the answer.

**One file per network, as iwd keeps them.** An iwd profile is whole in
one small file because it holds the secret (iwd facts 29 and 31).
erXos's files hold none, so a per-network file would hold three
optional lines beside a secret kept elsewhere; one FreeBSD file of
blocks says the same, and a network needs no file at all once it has a
secret. iwd's use of a file's time as the time of the last join orders
networks by recency, which `priority` replaces here.

**A join list in the kernel, and `join` as the configuration
(OpenBSD).** erXos's kernel holds no protocol, and OpenBSD's persistent
form is a file of commands with the passphrase in it
(`hostname.if.5:76-82`). Where UNIX systems differ erXos follows
FreeBSD, whose form is `wpa_supplicant.conf`; `ifconfig wlan0 ssid NAME`
is the one-shot override, as OpenBSD's `nwid` is. Its empty `join`,
which joins any open network (OpenBSD's `ifconfig.8:1031-1037`), hands traffic to
whoever advertises one: erXos joins an open network only by a block or
by `ssid NAME`.

**A score for each BSS.** iwd ranks by an estimate of the data rate
scaled by band, load and signal-to-noise (iwd fact 17), Android by
estimated throughput, OpenBSD by one sum of bonuses. Their inputs, the
rates of both ends and the access point's load, are not in the
station's scan records, and no consumer on a Pi needs them; `priority`,
then signal, with the memory, covers the common case. A dual-band
access point chosen by signal alone may be joined on its slower band;
[todo-performance.md](todo-performance.md) holds that measurement.

**A quick scan of the channels last used (iwd fact 14).** It shortens
a rejoin, and needs the channels kept across a restart, which is state
the station does not otherwise keep. The measurement of the time from a
lost link to an open port decides ([Performance](#performance)).

**The transition table in `abi/`, generated.** A table read by Erlang
alone needs no generator: the dispatch and the test read one term. A
generated table would add a grammar and an emitter for one reader.

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

## Lineage

Which idea came from which system, and what erXos does differently.
The evidence is the survey (the archived `research-wifi-designs.md`)
and the facts record of iwd ([research-wifi-iwd.md](research-wifi-iwd.md)),
the only window this design has onto iwd.

| Idea | From | What erXos does, and why it differs |
| --- | --- | --- |
| The supplicant asks an agent for the PTK and never holds the PMK | 9front's `aux/wpa` and factotum (`wpa.c:474-520`) | the key holder, a purpose of the vault, which is itself made after factotum (decision 1). It also does SAE's two secret steps, which 9front lacks, and keeps the PMK an exchange agrees, so the WiFi domain holds no PMK of any kind |
| The firmware's supplicant off; the host runs the handshakes | OpenBSD's `bwfm` (`bwfm.c:565-569`) | the same, in Erlang, in a domain instead of the kernel |
| One program holds the whole station, with no supplicant beside it and no protocol between them | iwd (fact 1); OpenBSD's net80211 | the station is one process whose parts are pure functions, where iwd's are modules around one event loop and callbacks (fact 8) |
| Policy apart from the connection's state machine, and roaming apart from both | Fuchsia's policy component, SME and roam monitor | three functions and one process, where Fuchsia has four components and the protocols between them |
| The legal transitions written once, and nothing else legal | Fuchsia's `statemachine!` (`state/mod.rs:138-150`) | one Erlang term that the dispatch looks up and the exhaustive test covers edge by edge. Fuchsia's fails at compile time; this fails in the landing gate's test, and lists events as well as states |
| The driver seam named after the standard's management requests | Fuchsia's FullMAC translation layer | ten requests and their indications, where wpa_supplicant's driver table has 193 operations |
| A network is its SSID and security class; one profile serves its WPA2 and WPA3 access points | iwd (facts 13, 31, 34); wpa_supplicant's use of `psk` as the SAE password | one entry and one passphrase per SSID; the AKM is chosen per BSS. erXos keeps `key_mgmt` in a block for the administrator who wants to narrow it |
| Failures remembered per access point | wpa_supplicant's ignore list (`bssid_ignore.c:78-99`), FreeBSD, OpenBSD, Fuchsia, Android, iwd (fact 20) | a hold that doubles to 300 s and is compared with the clock, without timers, as iwd's is. iwd's reaches 24 h and wpa_supplicant's 30 min; an unattended board cannot wait that long for an access point that has recovered. The memory is no input of admission, where OpenBSD and Fuchsia fold failures into one score with security |
| A short link counts as a failure | Fuchsia's penalty for a recent short connection (`scoring_functions.rs:13-69`) | one rule, a port that closes within 10 s |
| A failing secret is not retried without end | Android, which disables the network until the user acts; wpa_supplicant's disable for 10 to 300 s (`wpa_supplicant.c:9597-9625`); its test for a likely wrong key (`events.c:5092-5114`) | a hold from the third failure that doubles to an hour and ends with a new secret; never a hold only a person can end |
| The network's own word ends its transition mode | the Transition Disable indication, as wpa_supplicant (`wpas_glue.c:1342-1349`) and iwd (fact 33) honour it | a mark the station applies in the step that accepts the indication and the holder records before it writes, so no failure to write it restores PSK; only bit 0, on an SAE join. With a block of `key_mgmt=SAE` it gives Fuchsia's rule that a WPA3 entry never joins WPA2 (`config_manager.rs:561-582`) |
| Why a network was not joined is state to read, so a front end can ask for the secret | wpa_supplicant's `CTRL-REQ` and iwd's agents, by contrast | a verdict per BSS at `/proc`; no prompt, no agent and no protocol |
| The port is a state of the layer, and the link follows it | 9front's `blocked` node (`wifi.c:730-745`); iwd's dormant link (fact 28) | the port is `wlan0`'s link in another domain, so the stack cannot send before the keys are in |
| A scan never collides with a join | iwd's queue of radio work (fact 6) | one rule: a scan runs only while the join machine is `idle` or `open` |
| Pure protocol cores fed canned frames; the whole station against simulated air with frame rules; an access point the tests drive | iwd's unit tests and its tests on a simulated radio (facts 57 to 59); Fuchsia's testbed (`wlan/tests/README.md`) | the join machine explored over every sequence; scenarios behind the fake chip; hostapd, by recordings and with generated profiles on the board, as the independent access point |

What iwd says of itself is taken as a warning too. It is bound to one
kernel's interfaces through every layer (fact 60), where erXos keeps
the chip behind one seam. Its documents have drifted from its code
(fact 61), where the table, the verdicts and the AKM rows here are each
one term or one generated fact that the code reads. Its crypto blocks
its event loop while a passphrase is stretched (fact 47), where the
holder derives in another domain. Its secrets are in clear on disk
unless an experimental option is on (facts 31 and 63), and its drivers'
faults are handled by lists of names someone must maintain (fact 55),
which one chip behind one process does not need.

What was weighed and left out, with its reason, is in
[Alternatives considered](#alternatives-considered): a prompt protocol,
a file per network, OpenBSD's join list and its "join any", scores from
estimated throughput, a quick scan of remembered channels and a
generated transition table. Left out where they would have gone: a
generic driver table ([The seam](#the-seam-to-the-station)), stacked
policy services ([The station](#the-station)), FreeBSD's switch between
two choosers of a BSS
([Scanning and the lifecycle](#scanning-and-the-lifecycle)), Fuchsia's
per-network histories and hidden-network probabilities
(`network_config.rs:24-58`), which a block's `scan_ssid` states as a
fact, and software CCMP, which a FullMAC chip does itself.

## Decisions

What lies only in GPL sources, the Pi 4's device tree and Linux's SDIO
and controller drivers, reaches this design only through the clean-room
facts record [research-wifi-pi4.md](research-wifi-pi4.md), and iwd only
through [research-wifi-iwd.md](research-wifi-iwd.md); each was written
by a separate agent who wrote no part of the design, and the design
cites them by fact number. Every other value comes from FreeBSD,
OpenBSD, brcmfmac's ISC sources as FreeBSD carries them,
wpa_supplicant, 9front, Fuchsia's BSD-licensed files and the published
specifications, each cited by file and line or section in
[Sources](#sources); no design or code agent reads the GPL or LGPL
sources. What neither settles is a board fact, left to the board probe
([Facts this design does not have](#facts-this-design-does-not-have)).

Four choices shape the rest, each with its reasons and the alternatives
it was chosen over:

1. **In a release build the key holder is a purpose of the vault,
   `{wpa, Service}`.** The mechanism is the vault's existing one, key
   facets with exact inputs, as written in
   [Credentials](#credentials); the entries live in the vault's
   resources, never as terms. The vault gains the PTK and SAE
   arithmetic over its key resources, an entries section, and three
   fixed-length inputs the air chose. The reason is the vault's own
   rule, that no key enters a domain that uses it
   ([design-system.md](design-system.md#the-vault)): the state slot
   that keeps Bluetooth's bonds
   ([design-system.md](design-system.md#state-slots)) is for a secret
   that must leave the vault at every use, because the controller needs
   the bond's key, which is true of the session's keys and not of the
   PMK or PT. Under this placement the passphrase stays in the
   administrator's session, the WiFi domain holds `wpa_key` alone and
   `wpa_admin` goes to the administrator's session, so no break of the
   parsers yields a password equivalent or enrolls a network.
   * *Rejected: a key domain of WiFi's own,* `wifikeys`, over a state
     slot. It gives the same containment with the vault unchanged, and
     it would keep SAE's new arithmetic and the values the air chooses
     outside the boundary of every principal's keys. It costs one more
     domain, two interfaces served from it, a second key agent beside
     the vault, and entries that are Erlang terms in that domain; the
     vault, a larger trusted component, is taken instead because it
     adds no domain and no second agent.
   * *Development builds only: a file of the WiFi domain's own tree,
     with the holder a process of the WiFi domain.* It is not a release option: the WiFi
     domain would hold every PMK and PT and write the store itself, so
     a break of its parsers could read the password equivalents and
     enroll a network. It is the development build's stopgap, a
     residual that blocks release
     ([Where the holder runs](#where-the-holder-runs)).

   The station's code is the same under all three: W4 and W5 are built
   on the development holder behind the same two interfaces, and only
   the release backend, the vault's edit and the manifest's rows
   differ.
2. **A failing secret is held for a time that doubles to a ceiling of
   one hour,** ended at once by a new secret, as written in
   [Failure memory](#failure-memory). At most 24 attempts a day are
   made with a wrong secret, an impostor's silent exchanges counted
   among them; an outage ends within an hour of the interference. The
   exchanges that exposed a test of the secret are the ones counted,
   which the `secret` class does ([Joining](#joining)). The exact
   ceiling is a policy, not a protocol requirement.
   * *Rejected: hold until the secret changes,* as Android does. It
     makes the fewest attempts, but anyone in range who impersonates
     the access point three times stops the board's WiFi until an
     administrator acts, which lets an impostor disable an unattended
     board indefinitely.
3. **A key a block leaves out has erXos's default block's value:**
   `key_mgmt=WPA-PSK WPA-PSK-SHA256 SAE` and `ieee80211w=1`. A
   passphrase alone joins WPA2 and WPA3, and a block written for
   wpa_supplicant without those keys negotiates PMF and SAE where the
   access point offers them, which wpa_supplicant would not. The
   difference from FreeBSD is toward the stronger join of the same
   network, and it is what lets one `wlankey set` make a network
   joinable. Three things go with it: PSK's exposure to offline
   guessing is stated ([Choosing a network](#choosing-a-network);
   [Security](#security)); SAE-only policy stays expressible, by
   `key_mgmt=SAE` in a block or a Transition Disable mark; and no open
   network is inferred from a missing name, which WF16 holds.
   * *Rejected: wpa_supplicant's defaults,* `WPA-PSK` and no PMF.
     Blocks would mean exactly what they mean on FreeBSD, but WPA3
     would then need a block that says so, and a front end would have
     to write one.
4. **The WPA3 test access point is a Linux host running hostapd, with
   a radio that can serve as an access point.** hostapd's widest
   hardware support, every profile, SAE's recordings for the
   differential test and a monitor interface for the injected frames
   are there; it is one more host to keep. The FreeBSD x86-64 test
   host stays the data peer of [Performance](#performance) and serves
   the `open` profile and the WPA2 ones, over a radio or `wtap` if it
   serves ([Verification](#verification)). W0 to W3 need no access
   point.
   * *Rejected: FreeBSD alone.* hostapd 2.12's BSD driver has no
     operation that sends or receives management frames, so
     unmodified hostapd on FreeBSD cannot run SAE
     (`driver_bsd.c:1752-1790`), and `wpa3`, `transition` and
     `transition-td` need another host whatever radio FreeBSD drives;
     W5 cannot be tested on FreeBSD's driver at all.
   * *Not a test access point: a commodity router set by hand.* It
     costs nothing to buy or keep, but the group rekey period,
     Transition Disable and the refusing twin are then whatever the
     router offers. It may stand in for early bring-up, and the steps
     that need `wpa2-rekey`, `transition-td`, `twin` and the injected
     frames wait for the Linux host.

## Sources

Read as data on 2026-11-14, and `driver_bsd.c` and `sme.c` of wpa_supplicant 2.12 on 2026-11-15; nothing was built or run. Each file with its
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
| `src/common/dragonfly.c` | `e6bc9cc23f21836069941cb80b9ff3d3b93ac192e3af4abcf041b8b40b425eb2` |
| `src/common/wpa_common.c` | `215b2e978ef630124f0b04cde551137b26bc29d625a58c2e63582474af81d48a` |
| `src/common/ieee802_11_defs.h` | `cfb1b7760c209b3b2d2fe60faebb2034a0e7e19574bc3f8a0f7a726eb38629ab` |
| `src/common/common_module_tests.c` | `e3879a57df7f7406bdd0c95586657a9067661b06f19889f8c03198e2694bde8c` |
| `wpa_supplicant/wpa_supplicant.c` | `38711194c4e60c05244e863cecff6acd13351a871eac46411662ef3291025364` |
| `wpa_supplicant/events.c` | `18ced492b8a1057b2ccdbf9893e5fc47e73ec161875eb4ae6bb3d5ffdc2b5596` |
| `wpa_supplicant/config_ssid.h` | `34b01fa370d19eba854d3a9764493fed32bd4ac6a84e548a130cf0f8b84c6ed5` |
| `wpa_supplicant/wpa_supplicant.conf` | `6c808ca084ea5bf511e52c437c92670b917fc4c0a82c45e3de8d9551999fe1e8` |
| `wpa_supplicant/wpas_glue.c` | `1070867e9c9037903e2bb08821b2d345ad643dc59d1c9b17ca0e882465947c17` |
| `wpa_supplicant/bssid_ignore.c` | `b4383848a9420d3a82cd71ffabcc8eceb52a49a3cd111c6e1fdd0000e7b30b19` |
| `src/common/wpa_common.h` | `7ec1e0df859452b19f01019d0e0456e79c50bc0a08d3b7b785c033d5f0e16ac6` |
| `src/rsn_supp/wpa.c` | `60275d6bf6babcbdfb30d3469a088acc6b6cb8fe545dbfe102fce3ea03b2ae0d` |
| `src/ap/wpa_auth.c` | `f746f072008236133a9f07dd9c98c6bb99cb49a3417fb7f415d6bbc4e4b89e54` |
| `src/ap/ap_config.h` | `3fee20f622194d6ff88e4af02ef368ab6c7ec3b1cf166fd58ec7601792b7a166` |
| `src/drivers/driver.h` | `109413f73450e8d4dbe6d70a1270c29717056a014b3986d948ca41b183554cf1` |
| `src/drivers/driver_bsd.c` | `c15a94def111e98075814b44a0f379973fa24a679b5cffed070138037fd8f8bd` |
| `wpa_supplicant/sme.c` | `5a01a850c08d7ce637644c33e165c5ebb38fb71567b2779ba51e8947e7c4afc8` |

**Other stations,** read as data on 2026-11-15. The survey
the archived `research-wifi-designs.md` lists every file
read from wpa_supplicant, OpenBSD, FreeBSD, 9front, Fuchsia, Zephyr and
the vendors' documents with its SHA-256, and this design cites those
files as the survey does. Two it cites for a construction of its own:
9front's `sys/src/cmd/aux/wpa.c`
(`358c5c7167c7db4a1d5124bd350066837631a4864bf2c7098d449a047d82a269`, MIT,
commit `303bbdba4fc9bc9dc178aa3104e6e0d162c93055`), the conversation
with factotum, and Fuchsia's
`src/connectivity/wlan/lib/sme/src/client/state/mod.rs`
(`3c46ff9e81af2c66f540d91a790b45ce3c09671a69d2f01d42bce15b3ee493c6`,
BSD-style, commit `0f3b770945f24131db76f7e3920011b03efcee4e`), the
declared transitions. FreeBSD's `sbin/ifconfig/ifconfig.8`
(`745effccdbede31d74eb7f617b92ea68439ca3e91f8d72dab402d6a594c1466e`)
gives `ssid -`. iwd is cited only through the facts record
[research-wifi-iwd.md](research-wifi-iwd.md), written from iwd 3.12 by
a separate agent; no iwd file was read for this design.

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
in its `ORIGIN.md`; the facts records
[research-sdhci-bcm2711.md](research-sdhci-bcm2711.md) and
[research-wifi-pi4.md](research-wifi-pi4.md), the second written from
Linux v7.3.4 on 2026-11-15, whose sources and their SHA-256 it lists.
