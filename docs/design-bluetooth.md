# Bluetooth Low Energy: a peripheral that a phone talks to

This document is erXos's Bluetooth stack: how a Bluetooth controller
reaches erXos, which domain parses what it sends, how an erXos machine
advertises itself, serves the GATT services that apps declare to a phone,
carries a serial line to a phone, and pairs and bonds with LE Secure
Connections; and, as later stages, Wi-Fi provisioning from a phone, HID
over GATT into the display's input router, and classic Bluetooth. It
refines the unit rule of
[design-shared-devices.md](design-shared-devices.md#the-unit-rule), the
Raspberry Pi 4's UARTs of
[design-platforms.md](design-platforms.md#raspberry-pi-4-model-b), the
facets and the manifest of [design-system.md](design-system.md#the-manifest),
the vault of [design-system.md](design-system.md#the-vault) and the input
records of [design-display.md](design-display.md#input-events), and says
where each of them changes.

Decisions every reader needs:

* **erXos is a peripheral first.** The first milestone is an erXos
  machine that a phone app finds, connects to and talks to: it
  advertises its name and service UUIDs, serves GATT, carries a serial
  line and pairs. The central role (scanning, connecting, a GATT client)
  arrives with HID over GATT, a later stage.
* **One table, one gate.** The GATT attribute table is configuration:
  it is built from checked-in service declarations that the manifest
  selects, and it never changes while the Bluetooth domain lives. Every
  access a phone makes, and every notification an app sends, passes one
  pure function of the characteristic's declared requirement and the
  link's security, which the controller's own encryption report alone
  sets for the one key the link holds in its life. No app checks
  security, and no app can be reached over a link weaker than its
  declaration asks for.
* **Apps declare; Erlang processes handle.** An app names its services
  in `abi/gatt/` and its facet row; the stack derives handles,
  declarations, descriptors, subscriptions, MTU and long values. The
  app's handler process answers writes, sets the values reads return,
  and sends notifications and indications, through the `ble` facet.
* **The Bluetooth domain parses everything radio-derived.** Every byte
  from the controller is hostile: the controller's closed firmware parses
  the air, and anyone in radio range reaches the parsers above it. The
  Bluetooth domain, `bt`, holds no device; the system domain moves the
  controller's bytes and parses none of them.
* **The controller's line is a file tree.** On the Raspberry Pi 4 the
  controller is on UART0, a sub-device of the PL011 unit the system
  domain holds. The system domain serves it as the unit rule says: a
  tree with a `data` file of H4 bytes and a `ctl` file whose one word,
  `reset`, power-cycles the controller and programs the UART afresh, so
  every bring-up starts from one state.
* **Pairing happens only in a window an operator opens, and a bond is
  only ever made, never replaced.** LE Secure Connections only, with a
  16-octet key; a window is an open file, ends with its first pairing,
  and opens to a radio peer only after the wait that SMP asks after a
  failed pairing.
* **Bonds are machine secrets.** Release builds keep them in a sealed
  state slot of the vault, an opaque blob the vault never parses
  ([design-system.md](design-system.md#state-slots)); development builds
  keep them in the Bluetooth domain's directory on the data partition,
  as the SSH design keeps its host key before the vault.

## Contents

* [Context](#context): what is matched, the hardware, what the tree
  offers today, the sources
* [Requirements](#requirements)
* [The construction](#the-construction): one table, one gate; a name
  dies at once; one owner, one step; what disappears
* [Stages](#stages)
* [Domains and authority](#domains-and-authority): the Bluetooth domain,
  the controller's line with its reset and power line, what a radio
  peer can make the domain spend
* [Stage 1: the controller and advertising](#stage-1-the-controller-and-advertising)
* [Stage 2: the GATT server](#stage-2-the-gatt-server)
* [Stage 3: the serial service](#stage-3-the-serial-service)
* [Stage 4: pairing and bonding](#stage-4-pairing-and-bonding)
* [Later stages](#later-stages): Wi-Fi provisioning, HID over GATT,
  classic Bluetooth
* [Security](#security), with the [attack classes](#attack-classes)
* [Concurrency](#concurrency), [Failure handling](#failure-handling),
  [Refusals and error results](#refusals-and-error-results)
* [Verification](#verification), [Performance](#performance)
* [Changes to other designs](#changes-to-other-designs),
  [Alternatives considered](#alternatives-considered),
  [Decisions](#decisions), [Board probes](#board-probes)

## Context

### What is matched

erXos implements the host side of the Bluetooth Core Specification 6.3
(the HTML edition, [Sources](#sources)) for a device in the LE
peripheral role, and is held to what each part requires of it:

| Part | What erXos implements first | What it rests on |
| --- | --- | --- |
| Vol 4 Part A, UART transport (H4) | the host end of the line | a one-byte packet indicator before each HCI packet, `0x01` command, `0x02` ACL data, `0x04` event (section 2, Table 2.1); 8 data bits, no parity, one stop bit, RTS/CTS, which "should not be used for flow control of HCI" (section 3); a wrong indicator or an out-of-range length is a loss of synchronization, after which "a reset is needed" (section 4) |
| Vol 4 Part E, HCI | the commands and events of a peripheral's host | one command outstanding within the controller's `Num_HCI_Command_Packets` (4.4); no ACL packet sent while the controller's free-buffer count is zero (4.1.1); a Disconnection Complete returns every unacknowledged packet of its handle (4.2); LE Read Buffer Size describes packets from host to controller (7.8.2), and the host states the longest ACL packet it accepts with Host Buffer Size, by which the controller segments what it sends the host, flow control on or off (7.3.39) |
| Vol 3 Part A, L2CAP | the three LE-U fixed channels, ATT `0x0004`, LE signaling `0x0005`, SMP `0x0006` (2.1) | an unknown signaling command answered with `L2CAP_COMMAND_REJECT_RSP`, "Command not understood" (4.1) |
| Vol 3 Part F, ATT | a server | a server answers at least Find Information and Read (3.3); an unsupported request is answered Request Not Supported, an unsupported command ignored (3.3); one request and one indication outstanding per bearer, and commands that cannot be processed are discarded (3.3.2); a transaction not completed in 30 s fails the bearer (3.3.3); a value is at most 512 octets (3.2.9); the error codes of Table 3.4 |
| Vol 3 Part G, GATT | the server features of Table 4.1 | the mandatory discovery and read sub-procedures (4.2); the Service Changed characteristic exists when services can change in the device's lifetime, and is indicated to a bonded client at reconnection (2.5.2); a Client Characteristic Configuration persists for bonded clients and resets for others (3.3.3.3); default ATT_MTU 23 (5.2.1) |
| Vol 3 Part H, SMP | a responder, LE Secure Connections only | the key size between 7 and 16 octets, failed with "Encryption Key Size" when below the minimum (2.3.4); the peer's public key validated on P-256 and failed with "DHKey Check Failed" when off it, the debug key refusable, equal X coordinates failed (2.3.5.6.1); a fresh passkey per pairing (2.3.5.6.3); a fresh key pair after every pairing (2.3.6); after a failed pairing, a wait before answering a Pairing Request from a device claiming the failed one's identity, growing exponentially with each further failure, limited to a maximum and shrinking back to a minimum when no failure follows (2.3.6), the reason Repeated Attempts (`0x09`) for a request it refuses (Table 3.7); a Security Request the peripheral may send, never while pairing or encryption is in progress (2.4.6); a claimed identity address valid only after a reconnection with the pairing's key (2.4.3.2); a 30 s timer (3.4); the reason codes of Table 3.7 |
| Vol 3 Part C, GAP | a peripheral in LE security mode 1 that pairs only by LE Secure Connections | levels 1, 2 and 4 of LE security mode 1, with "the use of LE Secure Connections pairing" enforced for services at level 2, which 10.2.1 permits; not Secure Connections Only mode (10.2.4), which would allow level 4 alone; the error a server answers for each access, link state and pairing state (10.3.1, Table 10.2); security checked before every notification and indication (10.3.1.1); a static address and resolvable private addresses (10.8) |

The serial service follows Nordic's UART service, so that existing phone
terminal apps work: one service, a characteristic the phone writes with
and without response, and one it subscribes to for notifications, with
UUIDs `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, `...0002...` and `...0003...`,
as Apache NimBLE's `bleuart` service declares them
(`nimble/host/services/bleuart/src/bleuart.c:52-86`).

HID over GATT, a later stage, follows the HID over GATT Profile 1.1 and
the HID Service 1.0: a Report Host (HOGP 2.1), which bonds (7.2),
encrypts as early as possible after reconnection (7.2), enables
notifications of every Input Report (4.8), and prepends the Report ID of a
characteristic's Report Reference to each value before the HID parser
sees it (4.8.1); the Report Map is at most 512 octets (HIDS 2.6.1).

### The hardware

* **The Raspberry Pi 4's controller is a Cypress CYW43455 on UART0**, the
  first PL011, on GPIO 30 to 33 in function ALT3: CTS0, RTS0, TXD0 and
  RXD0 (BCM2711 peripherals, section 5.3; Raspberry Pi documentation,
  `interfaces.adoc`, the table of primary and secondary UARTs). Whether
  the firmware leaves those pins in ALT3 is probe B-P1.
* **UART0 is held, undriven.** The five PL011s share one register page
  and one interrupt line, 153, so they are one unit, which the system
  domain holds for UART3, the host link
  ([design-platforms.md](design-platforms.md#raspberry-pi-4-model-b),
  `config/platforms/raspi4b.json`, unit `hostlink-uart`). Each PL011's
  clock is 48 MHz in the record, so 115200 baud divides as the host
  link's does.
* **Power.** The controller's enable line is, by all accounts, a pin of
  the firmware's GPIO expander, which the VideoCore drives on a mailbox
  request. FreeBSD's expander driver numbers those pins from 128
  (`raspberrypi_gpio.c:51`) and sets one with the property tag
  `0x00038041`, whose request is the pin and its state
  (`bcm2835_firmware.h:144`, `:161-168`). Which pin, and its polarity,
  only GPL sources state; probe B-P2 reads them from the device tree the
  firmware passes at run time, which is data, and records whether the
  firmware leaves the controller powered.
* **The patch.** Every permissive host that drives a CYW43xxx loads a
  patch into the controller's RAM before use: NetBSD's `btattach` sends
  the vendor command `0xFC2E` (download minidriver), replays the `.hcd`
  file as HCI commands of the form `opcode(2, little-endian) length(1)
  payload`, each awaiting its Command Complete, sleeps, and resets
  (`init_bcm43xx.c:105-141`); Zephyr's Infineon driver does the same and
  stops at any record but `0xFC4C` (Write RAM) and `0xFC4E` (Launch RAM),
  though only after sending it (`hci_uart_infineon.c:141-191`). The Pi
  4's patch is
  `BCM4345C0.hcd`, which the fetch step downloads and the Pi 4's image
  ships ([Stage 1](#the-bring-up)).
* **QEMU has no Bluetooth.** QEMU removed its Bluetooth emulation in 5.0
  "without replacement" (QEMU's 5.0 change log), and QEMU `virt`'s two
  PL011s are the console and the host link (`virt.rst:36`, `:55-62`). The
  integration tests run in [hosted mode](design-runtime.md#hosted-mode)
  against Google's Bumble, whose virtual controllers speak H4 over a TCP
  socket ([Verification](#verification)).

### What the tree does today

Nothing of Bluetooth exists. `erx_pl011`
(`erlang/apps/erx_uart/src/erx_pl011.erl`) is an Erlang driver over the
device NIF that programs its UART at 115200 baud, 8N1, without hardware
flow control (`erx_pl011.erl:35-38`), and speaks the six console driver
messages to the one process it serves
([design-runtime.md](design-runtime.md#the-console-and-standard-io)). It
keeps what the boot left in the UART: it clears neither FIFO, since the
kernel's last lines and a person's typing are in them, and programs the
divisors only of a UART the boot left unprogrammed
(`erx_pl011.erl:170-181`, `:209-215`), so starting it again resets
neither the bytes nor the rate. The
PL011's register description already has the flow-control enables, `CR`'s
`RTSEN` and `CTSEN` (`hw/svd/pl011/pl011.svd:113-114`). The line owner,
`erx_irq_line` and its core, shares a line among drivers of one domain
([design-shared-devices.md](design-shared-devices.md#lines-inside-a-domain)),
and the system domain's services each start the owner of their own UART's
line. The vault's machine file holds machine keys; no facet stores a
grantee's state. The firmware notification, `erx_firmware_notify`, is
the USB design's narrow kernel call, which the device service makes
through the domain library for the VL805 alone
([design-usb.md](design-usb.md#the-vl805s-firmware),
[design-pcie.md](design-pcie.md#facets)); none of it is built yet. The HID parser and fold, `erx_hid_desc` and
`erx_hid_core`, are the USB design's ([design-usb.md](design-usb.md#hid)).

### Sources

Every source was read at a pinned version, fetched over HTTPS into a
directory outside the tree; none under the GPL or the LGPL was read. The
Bluetooth SIG's specifications are their HTML editions, the Core
Specification at
`https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core_v6.3/out/en/index-en.html`.

| Source | Version | File | SHA-256 |
| --- | --- | --- | --- |
| Core Specification 6.3 | 6.3 | index | `96b569247cc6999f35463c6483efb3392babe9d240c0d22ab20a9c870b5310e6` |
| | | Vol 4 Part A, UART transport | `f5fc6f3977bf3d7f2a86422b38c74590c071b2ec693b9349ce1092616871621b` |
| | | Vol 4 Part E, HCI | `76eb9e21a158ac3a2340087568437b0b91408b333ab135c7a13f9b5bdcc57ed2` |
| | | Vol 3 Part A, L2CAP | `9fc72a9efd4229c3f800ac862808bba7b33d6a95679cfbd2acda5b3650069905` |
| | | Vol 3 Part F, ATT | `272a2472b71b54503d44a16286b9e399a323774d8b7b8246283a7c49e96d0638` |
| | | Vol 3 Part G, GATT | `25539e2ca6f127cf98bb34baae0c2cb774549ccb94d54f331c3c3ef4efa02add` |
| | | Vol 3 Part H, SMP | `16d561aab6cb6a219a55963fdb7acd68bfcac69eacf7387ae0b7366f180a4974` |
| | | Vol 3 Part C, GAP | `e095f6af2a746e898c36ed63ec9655fdf803d747daa4b6b68d21624acde835bf` |
| HID over GATT Profile | 1.1 | index | `b763f6511244e97f2fc1d9387f0e999c6bbbc82c8d58e92b66f1eb025972d725` |
| HID Service | 1.0 | index | `b114fb6930bb11a99bc8b6be72593e185abbbe4827a6ec18851ef2664d5f79a3` |
| NetBSD | trunk `5cebe14c1559` | `usr.sbin/btattach/init_bcm43xx.c` | `2c25439d61fbfd410f9cd8216152a7f8bc4dd9f7dbb974b58dc351d4d9f46f53` |
| | | `usr.sbin/btattach/btattach.c` | `58c3d467335cfb0e2791ef185ca232326f9289e570df887c1387c77df3e92b74` |
| Zephyr | main `7cd4b562b30a` | `drivers/bluetooth/hci/hci_uart_infineon.c` | `07aa15b3b1db206875ab3df72c739174d83e328ed9b59fc65cacd16917b8a288` |
| FreeBSD | releng/15.1 `95719d8a895b` | `sys/arm/broadcom/bcm2835/raspberrypi_gpio.c` | `ad34506dd6f69144bc4bfb3bfb00fb87b6c327ad5fe30ae03ee80437e3a79224` |
| | | `sys/arm/broadcom/bcm2835/bcm2835_firmware.h` | `9dfeb72a9a56556531afab024d80d45baaba40bc07351b970f651325b3d339a7` |
| | | `usr.sbin/bluetooth/hcsecd/hcsecd.h` | `fcb787bdad0ea5cde10d6fd3d6a058414686a1d783d34aa324b148c26de0e849` |
| RPi-Distro bluez-firmware | `cdf61dc691a4` | `LICENSE.cypress` | `a92f031f19089fa63bd24ac4c5298ca1356670321b39c67024a961ee3285fff7` |
| Raspberry Pi documentation | `c6a64966af13` | `computers/configuration/interfaces.adoc` | `20c0c5f8dcf2ba501ec7888028aa576be2c965f9b06dd04022e3c9d187b33cef` |
| BCM2711 ARM Peripherals | unversioned | the PDF | `d6e16ea089a1716e80621f99a26e130a2379f0a81d945dc22e4f80dc49dcdc78` |
| PrimeCell UART (PL011) Technical Reference Manual | ARM DDI 0183G, r1p5 | the PDF, from `documentation-service.arm.com` | `9cfe1a296ebe7accd905fb569e4c545ed9ca01d8341603568017319abe7e51e7` |
| QEMU | wiki, read 2026-11-14 | `wiki.qemu.org/ChangeLog/5.0` | `210bfe5e852d8395bfd937cf312ac62d936ee8948d6c310f19110f161843ca00` |
| QEMU | `v11.1.3` | `docs/system/arm/virt.rst` | `9fbcc9fc3040ef695e3058cd4bab05e10f6282ab7ba0846a93ee9f524933e3e1` |
| Apache NimBLE | master `648fc0213fb7` | `nimble/host/services/bleuart/src/bleuart.c` | `2a51bad8f39685887b10f2301e023baa2af9200685d91528ae330bef78a21ed1` |
| Bumble | `v0.0.237`, `34def7f112f9` | `apps/controllers.py` | `2d57845479e214137210db48bf12f3ac0309f01abb5cb4c6088b1d35ae462a05` |
| | | `bumble/controller.py` | `8869ca13997bcc39b1fd2932438b720ac66db866d17a10b3ec4ba6504dc778db` |
| | | `bumble/keys.py` | `5a06ecf86854108ca9714409a81ef0cc62cdc37010136c8e8f013c012a024b38` |
| | | `examples/device_with_rpa.json` | `d8c7a1515716ed182ddd2e4476f5a5600a30c772bbdb1101ac63c71f50b84c89` |
| | | `apps/scan.py` | `352443d071e7f112d80d1c787cbbd3598ebcf90c4b57076b62da9029e96efee3` |
| | | `apps/gatt_dump.py` | `e04a4958947e3a131614cb0215ef60ec182e09cbd7855aaea32ca1c00ff7f428` |
| | | `apps/pair.py` | `5d137d70db884e78ec1806daac8c848066937fbfdbfd5f2e159b2e781b3bcf9c` |
| | | `examples/run_scanner.py` | `37a0cba92cceb8488422ca00390f944a619278b55a7d7299c9d889b91d992ee7` |
| | | `examples/run_gatt_client.py` | `aec03764d636d0e024dc443d777989fad7ecf45b10e40e56ebd77e7e65613b48` |
| | | `examples/run_connect_and_encrypt.py` | `c15665cf0dc4e8f0437e21940c2a4304a28adfefd2091d732c281bcc28e3f891` |
| | | `bumble/core.py` | `99604dffc77ee642b256d86d1f6e27fdc7e770bd70f62ecd225f485810f87aa0` |
| | | `bumble/transport/common.py` | `c62ac850542cf9ef8668ebbe801e3a5dc369a50464c1faba875fb404935b409d` |

The Core Specification Supplement, which defines the advertising data
types and the Flags structure, and Vol 6 Part B, which defines the formats
of static and resolvable private addresses, were not fetched. The values
this document uses from them come from Bumble's `core.py:1594-1622` and are
marked unverified until the supplement is read.

## Requirements

Each names its consumer.

| | Requirement | Consumer | Stage |
| --- | --- | --- | --- |
| B1 | A phone's scanner shows the machine's name and the UUIDs of the services it advertises | the vendor's phone app, which finds its device by service UUID | 1 |
| B2 | A phone discovers, reads and writes the characteristics apps declare, and subscribes to their notifications and indications | the vendor's phone app | 2 |
| B3 | An app declares its services as data; Erlang processes answer writes, set values and send notifications | the vendor's app on erXos | 2 |
| B4 | A byte stream between a phone and an app, which phone terminal apps for Nordic's UART service open | serial tools; the console | 3 |
| B5 | A characteristic may require an encrypted link, or an authenticated one, reached by LE Secure Connections pairing and bonding | Wi-Fi provisioning, the console | 4 |
| B6 | A pairing is made only in a window someone with the right opened, and no bond is replaced by pairing | every characteristic that requires a bond | 4 |
| B7 | Every byte from the controller and every PDU from a peer is parsed by a bounded parser with a fuzz target; a malformed one ends at most its link, or restarts the controller | the machine's integrity against anyone in radio range | all |
| B8 | The trusted base parses no radio bytes | the system domain's integrity ([design.md](design.md#decisions)) | 1 |
| B9 | Every bring-up starts from one state, whatever the last one left | restarts of the controller, the Bluetooth domain and the line | 1 |
| B10 | A connection's name never names a later connection | apps that notify after a phone left | 2 |

## The construction

### One table, one gate

The attribute table is a pure function of configuration:
`erx_gatt_db:build(Services)` takes the declarations of the services the
manifest selects, in the order of their names, and returns the table:
every attribute's handle, type, value or value source, permissions, and
each characteristic's declaration, value and descriptors. The Bluetooth
domain builds it once at its start; nothing adds, moves or removes an
attribute while the domain lives. The table's **hash**, SHA-256 over its
declarations in table order (`erx_bytes:sha256/1`), names it.

Every access passes one pure function, the **gate**:

```erlang
-spec erx_gatt_gate:check(access(), level(), link_security()) -> ok | {error, att_error()}.
-type access() :: read | write | notify.          % indications and configuration writes are notify's
-type level() :: open | encrypted | authenticated. % GAP 10.2.1 levels 1, 2 and 4
-type link_security() :: #{key := none | encrypted | authenticated, encrypted := boolean()}.
```

It is GAP's Table 10.2 (10.3.1) for the three levels erXos uses, whose
columns are the key the server has for the peer, not whether that key is
stored: an `open` access is allowed; an `encrypted` or `authenticated`
access on a link with no key answers Insufficient Authentication
(`0x05`); on a link with a key but not yet encrypted, Insufficient
Encryption (`0x0F`); an `authenticated` access on a link encrypted with
an unauthenticated key, Insufficient Authentication. Since every key is 16 octets and only
Secure Connections pairs, level 3 and Encryption Key Size Too Short
never arise. The ATT server calls the gate for every read and write of a
characteristic value or a descriptor; the link calls it before every
notification and indication it sends, as GAP 10.3.1.1 requires; nothing
else decides access.

`link_security()` is a derived fact of the link, and one transition
sets it, for the first pairing and for every reconnection alike:

* **A link holds at most one key in its life.** It has none at LE
  Connection Complete. It gets a kept bond's key when the phone's address
  resolves to that bond ([Reconnection](#reconnection)), or the key its
  pairing computes, at the moment SMP's second phase makes it
  ([Secure Connections only](#secure-connections-only)). A link with a
  bond's key never pairs, and a pairing runs only on a link with no key,
  so a key, once a link has one, never changes; a pairing that fails
  after it made its key ends its link, so a link's key is a kept bond's
  or its own pairing's. `key` is its level, `encrypted` for Just Works
  and `authenticated` for Passkey Entry.
* **`encrypted` is set only by the controller, for that key.** At LE Long
  Term Key Request the link answers Reply with its key, or Negative Reply
  when it has none (HCI 7.8.25, 7.8.26). `encrypted` becomes true at the
  controller's next report that encryption started, Encryption Change
  with encryption on or Encryption Key Refresh Complete, each with status
  success, after a Reply; any other report about encryption on the link,
  an error, a change to off or a report after a Negative Reply, ends the
  link.

So the first pairing encrypts as SMP has it, with the pairing's key
before the third phase distributes the phone's identity (SMP 2.4.3),
and reaches its level then; a reconnection encrypts with the bond's key
the same way; and the level a link reaches is always the level of the
key the controller is using on it, which no field a peer sends sets.
Whether a pairing's key has been kept decides what outlives the link,
not what the link may do: only the peer that completed the pairing in
the window holds that key, before the store keeps it as after. A
pairing whose store answers `unavailable` fails and ends its link
([Bonds and the store](#bonds-and-the-store)), so no link outlives the
store's refusal of its key.

From these two constructions:

* **An app is never reached over a link weaker than its declaration.**
  The handler receives a write only after the gate allowed it, and a
  notification it asks for is sent only where the gate allows it, so no
  app checks security and none can forget to.
* **The table never goes stale under a phone.** Within a domain's life
  there is no service change to announce, so a phone that is not bonded
  rediscovers each connection as GATT 2.5.2 requires and is never
  wrong; a bonded phone, whose cache outlives connections, gets Service
  Changed with the whole range at its first connection after the table's
  hash differs from the one its bond records ([Reconnection](#reconnection)).
* **Apps cannot reach each other's attributes.** An app's facet names
  services, never handles, and the registry routes each event to the one
  handler of its service.

### A name dies at once

Connection handles are the controller's and are reused. The controller
process gives each connection a fresh reference, `Conn`, at LE
Connection Complete, and every request an app makes names `Conn`. The
registry maps a live `Conn` to its link process; the link's end removes
it, so a notification to a phone that left answers `{error, gone}` and
never reaches a later phone that took the same handle. As in the USB
design ([design-usb.md](design-usb.md#a-name-dies-at-once-hardware-is-freed-only-on-the-controllers-report)),
the controller's resources are freed only on its report: a handle's
outstanding ACL packets return to the credit count at its Disconnection
Complete, as HCI 4.2 states, and not before.

### One owner, one step

Each kind of process owns its state and decides by a pure step that
returns the actions it performs, as the network stack's and the USB
stack's owners do
([design-network-stack.md](design-network-stack.md#one-owner-one-step)):

| Owner | Its state | Its pure core | Effects |
| --- | --- | --- | --- |
| the **controller process**, `erx_bt_hci` | the bring-up, the command slot, ACL credits, the map from handles to links, advertising | `erx_bt_hci_core` | writes to `data` and `ctl`, starting and ending link processes |
| a **link process**, `erx_bt_link`, one per connection | L2CAP reassembly, the ATT bearer (MTU, the request in progress, queued commands, the prepared write, the indication in flight), the notifications waiting for credits, subscriptions, its one key and whether it is encrypted, the pairing in progress | `erx_bt_link_core`, over `erx_gatt_server`, `erx_gatt_gate` and `erx_smp_core` | ACL fragments to the controller process, events to handlers, store requests |
| the **registry**, `erx_gatt_srv` | the table, each service's handler, the live `Conn` map, the `ble` facets | `erx_gatt_registry` | monitors, events to handlers |
| the **store**, `erx_bt_store` (stage 4) | the identity address and the bonds | `erx_bt_state` | reads and writes through the store's backend |
| the **window**, in `erx_bt_fs` (stage 4) | whether a pairing window is open, its mode and its opener's fid; the pairing wait | `erx_bt_window` | lines on the opener's `pair` file |

Every timer is a deadline in its owner's state, and each step answers the
next deadline among its actions. No caller strings operations together:
the bring-up is one state machine, a pairing is one, and a write's
round trip to a handler is one step out and one step back.

### What disappears

| Case that would need handling | Why it cannot arise |
| --- | --- |
| an app forgets to check that a link is encrypted | the gate decides before the app sees the write, and before a notification leaves |
| a peer raises its link's security by a field it sends | only the controller's report of encryption, after the link gave its one key, sets it |
| the first pairing and a reconnection need different security transitions | both encrypt with the link's one key, through the one transition |
| a pairing on a bonded link, or a second key on one link | a link with a key never pairs, so its key never changes |
| a database change mid-connection, Service Changed to unbonded phones, a client made change-unaware | the table is fixed for the domain's life; Database Hash is not served, so robust caching is not required (GATT 2.5.2.1) |
| two apps declare the same UUID, or the advertising data overflows | the manifest check refuses the configuration ([Declarations](#declarations-abigatt)) |
| a notification reaches a phone that took a departed phone's handle | `Conn` dies at once |
| a bring-up starts from a controller left at an unknown rate, patched or half-patched, or from a UART holding the last controller's bytes or the boot's settings | `reset` power-cycles the controller and programs the UART afresh before every bring-up |
| an app that opens windows one after another lets a guesser retry at once | the pairing wait is the window process's and outlives every window |
| a weaker pairing overwrites a stronger bond (BLURtooth's class) | pairing never replaces a bond; only `forget` ends one |
| a phone's subscription lost at a power cut | a bonded link's configuration write is answered only once the store has kept it |
| an app's crash leaves dangling attributes | attributes are configuration; the handler detaches, values stay |

## Stages

The stages are ordered by the first consumer, a phone app talking to an
erXos device, and each ends in a demo against a phone and a test against
Bumble.

| Stage | Delivers | Needs | Bumble peers |
| --- | --- | --- | --- |
| 1. The controller and advertising | the line tree and its `reset`, H4, the bring-up with the patch, HCI's command and data credits, the identity address, advertising of the name and the declared UUIDs, `/proc/bt` | hosted mode with domains (track H); on the Pi 4, the system domain's line groups, `erx_pl011`'s fresh start, the firmware notification's index and the patch | `apps/controllers.py` joining two virtual controllers; `examples/run_scanner.py` and `apps/scan.py` as the scanner |
| 2. The GATT server | L2CAP's fixed channels, the ATT server, `abi/gatt`, the table, the gate, the `ble` facet and its handlers | stage 1 | `examples/run_gatt_client.py` and `apps/gatt_dump.py` for discovery and reads; a peer script for writes, subscriptions, notifications and indications |
| 3. The serial service | the `nus` declaration and `erx_gatt_serial` for apps | stage 2 | a peer script that writes and subscribes |
| 4. Pairing and bonding | SMP as responder, the pairing window, the store, reconnection with bonds, Service Changed, persistent subscriptions; the phone console | stage 2; for release builds, the vault's state slots ([design-system.md](design-system.md#state-slots)) | `apps/pair.py` as the pairing central; `apps/gatt_dump.py --encrypt` and `examples/run_connect_and_encrypt.py` for reconnection |
| 5. Later | Wi-Fi provisioning, then HID over GATT, then classic Bluetooth | stage 4; a Wi-Fi driver; the USB design's HID cores | per stage ([Later stages](#later-stages)) |

Stages 1 to 3 need no Security Manager: until stage 4 the link answers
every SMP PDU with Pairing Failed, Pairing Not Supported (`0x05`), and the
gate refuses every `encrypted` and `authenticated` access with
Insufficient Authentication, which is the right answer for a server with
no key for the peer (GAP 10.3.1). The phone console is part of stage 3's service but
is offered only once stage 4 exists, since its characteristics are
`authenticated` ([The console](#the-console)).

## Domains and authority

### The Bluetooth domain

The Bluetooth domain is a configured `service` domain of the manifest,
named `bt` (node `bt@erxos`), of the principal that owns the machine's
services, on the BeamAsm image, whose OpenSSL its Security Manager calls
through OTP's `crypto` ([Stage 4](#stage-4-pairing-and-bonding)). It holds
no device. Its release ships `kernel`, `stdlib`, `erx`, `erx_files`,
`crypto` and `erx_bt`. Its manifest row holds:

* one grant of the `line` interface, which the system domain's line
  service serves, its parameters naming the controller's UART
  ([The controller's line](#the-controllers-line));
* its arguments: the advertised name (the machine's host name by
  default), the appearance, the connection limit (1 by default, at most
  `bt_connections_max`), the patch file and the manufacturer it applies
  to where the board needs one, and the service the console serves, if
  any;
* at stage 4, the store's grant: in a release build the vault's state
  facet `{state, "bt"}` ([design-system.md](design-system.md#state-slots)),
  and in a development build a `data` grant rooted at its own directory;
* at stage 4, the system domain's login facet, when the console is
  configured ([The console](#the-console)).

It serves three things: the `ble` facet to apps ([The `ble`
facet](#the-ble-facet)); its **control tree**, an instance of `files`
with `ctl` and `pair` ([Stage 4](#stage-4-pairing-and-bonding)), which
the manifest grants to administrators' sessions and to whichever app
templates it names; and its state at `/proc/bt`, through the inspection
schema ([Inspection](#inspection)).

It is a domain of its own, not a part of the devices domain: what it
parses comes from anyone in radio range, so it holds no device and no
grant that a radio peer should not reach through a parser defect, as the
network domain holds only its network device. The manifest check holds a
`bt` row to exactly the grants listed above, as it holds the SSH
domain's row to its grant, its login facet and its host key facet
([design-ssh.md](design-ssh.md#invariants), H3): it refuses a device, a
partition window, a second `line` grant, and any facet but the `line`
grant, the store's grant and the login facet, and a release manifest
refuses the development store.

### The controller's line

The controller is a sub-device of the system domain's PL011 unit, so it
reaches the Bluetooth domain through the home the unit rule gives:
a file tree its holder serves, with a `ctl` file for one-shot control
([design-shared-devices.md](design-shared-devices.md#the-unit-rule)). The
**line service**, `erx_line`, a service of the system release, serves
one **line tree** for each grant of the `line` interface, which
`abi/services/line.txt` declares with its files, `ctl`'s word and three
parameters, each with its checked consumer as every facet parameter has
([design-abi.md](design-abi.md#system-manifest-representation)): `uart`,
the UART's device-tree path; `rate`, 115200 on every board this design
names; and `flow`, `none` or `rts_cts`. A line is thus configured where
every grant is, in the facet's row, and the manifest needs no field of
its own for it. The manifest check gives the unit of each `line` grant's
UART to the system domain, as property 8 gives the console's and the
host link's ([design-system.md](design-system.md#the-manifest)), and
refuses two grants that name one UART, and a grant that names the
console's or the host link's:

| File | Read | Write |
| --- | --- | --- |
| `data` | the bytes the controller sent, at least one and at most what is buffered, waiting while none is; `eio` once the line is broken | the bytes to send, in order, returning once the driver has taken all of them |
| `ctl` | `eacces` | `reset`, with or without its newline, at most 16 bytes: the steps of [A reset](#a-reset) below; answers once done, or `eio` when a power notification failed; any other write is `einval` |

The line service parses no byte of `data`: it moves bytes between a
fid and its driver. Its one grammar of untrusted input is `ctl`'s, one
word, with a fuzz target. Its receive buffer holds at most
`line_rx_max`, 64 KiB, about five seconds of 115200 baud; a driver input
that would pass it marks the line **broken**: buffered bytes are dropped
and every read answers `eio` until the next `reset`. A loss of bytes is a
loss of synchronization, which H4 answers with a reset anyway (Part A,
section 4), so the line's one failure is the controller's restart.

#### A reset

`reset` takes the line through four steps, in this order, each finished
before the next:

1. **Stop the driver.** The line's driver process ends, so nothing
   touches the UART until step 3.
2. **Device off.** Where the platform names a power line for the UART's
   device, the line service asks for its off notification and waits the
   off time ([The power line](#the-power-line)).
3. **The UART afresh.** The line service starts the driver again with
   `init => fresh` in its record, which programs the UART from nothing
   (below), empties the receive buffer and clears the broken mark.
4. **Device on.** It asks for the on notification and waits the on time,
   then discards whatever the driver delivered during the wait, which a
   controller powering up may send, and answers.

So no byte and no setting of the last bring-up survives a `reset`:
the transmit FIFO is emptied while the controller is off, the receive
side holds only what the new controller sends after the answer, and the
UART's rate, format and flow are the grant's, whatever the boot or the
last driver left. A platform with no power line runs steps 1 and 3 alone,
and its bring-up relies on `HCI_Reset`.

**Its driver is `erx_pl011`, started fresh.** For the console and the
host link, `erx_pl011` keeps what the boot left (What the tree does
today). A line's record carries `init => fresh`, its rate and its flow,
and `erx_pl011:program/2`, a pure function of the record and the UART's
clock, returns the register writes the driver performs, in order,
following the programming note of the PL011's manual (DDI 0183G, page
3-16):

1. `CR` written 0: the UART, the transmitter, the receiver and both flow
   enables off. The driver then waits one character time at the boot's
   divisors, as it does today, for the character in flight, and does not
   wait for `FR`'s `BUSY`: with CTS flow control a controller holding CTS
   off keeps the transmitter busy indefinitely.
2. `LCR_H`'s `FEN` cleared, which flushes the transmit FIFO (the note's
   step 3); then `DR` read until `FR`'s `RXFE` is set, at most 33 reads,
   the receive FIFO's 32 entries (page 2-6) and the holding register,
   which empties the receive side.
3. `IBRD` and `FBRD` written with the divisors of the record's rate, then
   `LCR_H` written whole: 8 data bits, no parity, one stop bit, FIFOs on,
   no break. The `LCR_H` write comes last because it latches the
   divisors (page 3-14).
4. `ICR` written with every interrupt bit, then `IMSC` with the receive
   and receive-timeout interrupts, as the driver does today.
5. `CR` written whole: `UARTEN`, `TXE` and `RXE`, and `RTSEN` and
   `CTSEN` when the flow is `rts_cts`, so the PL011 holds RTS off while
   its receive FIFO is full and sends only while CTS is on.

The console's and the host link's start keep their own sequence,
`init => keep`, which `program/2` also returns, so one function names
both and the driver's effects are the same loop over its list. The
driver speaks the six console driver messages, unchanged. The line runs
at 115200 baud throughout; a faster rate is a measured optimization
([Performance](#performance)).

**The shared line 153.** UART0 and UART3, the host link, interrupt on one
line, so the drivers of two services of the system domain share it, and
a line has one binder. The system domain starts the host link and the
line trees under one supervisor, `erx_uart_sup`, `one_for_one`, of
**line groups**, one for each interrupt line those UARTs use. A group is
a `rest_for_one` supervisor: the line's owner first, when the line is
shared, which `erx_irq_line:owners/1` computes from the drivers'
records, then the host link if its UART is on the line, then each line
tree on it, each starting its own driver, which joins the owner
([design-shared-devices.md](design-shared-devices.md#lines-inside-a-domain)).
So an owner's failure restarts exactly the services whose UARTs share
its line, and a failure on another line restarts nothing here. On the
Pi 4 one group holds line 153's owner, the host link and the Bluetooth
line's tree; on QEMU `virt` the host link's group holds the host link
alone. The console is not in a group: it starts its own line's owner,
under `user_sup` and `erx_console_sup`, and takes that owner's end as
its driver's, which ends the runtime
([design-runtime.md](design-runtime.md#configuration)), and the manifest
check refuses a console UART that shares an interrupt line with any
other UART the system domain drives, as it refuses one that shares the
host link's ([design-shared-devices.md](design-shared-devices.md#open-decisions)).

#### The power line

Power is the device service's, through the one kernel call that the USB
and PCIe designs define for the firmware's notifications,
`erx_firmware_notify` ([design-usb.md](design-usb.md#the-vl805s-firmware)),
under its contract unchanged but for one argument: the index of one of
the notifications the platform record lists for the resource's device,
the VL805's one being index 0. The Pi 4's record lists two for UART0's
device entry, `/soc/serial@7e201000`: index 0 turns the controller off
and index 1 turns it on, each the tag `0x00038041` with the expander pin
`128 + P` and that state, and it gives the off and on times,
provisionally Zephyr's 300 ms and 500 ms
(`hci_uart_infineon.c:38-39`, `:236-246`); probe B-P2 settles the pin,
the polarity and the times. UART0's device record, which the line
service reads at a tree's start, carries the times and whether the
device has a power line.

* **Authority.** The line service asks the device service,
  `erx_devices:power(Device, off | on)`, a call inside the system
  domain. The device service makes the kernel call through the domain
  library, `erx_domain_lib:device_notify(Device, Index)`, with the
  resource UART0's device record holds, carved with `ERX_CARVE_DEVICE`
  from the entry the record names with notifications, as `pci_firmware/1`
  makes it for a bridge ([design-pcie.md](design-pcie.md#facets)). So the
  caller chooses neither the tag nor the value, only which listed
  notification, no device outside the system domain asks for one, and no
  domain but the system domain holds a resource that names the entry.
* **Deadline and answer.** The call's: a poll of at most 1 s, the answer
  matched by its buffer, `ERX_OK` only for a success with the tag's
  response bit set, and `ERX_ENOTSUP` for any other answer, for a
  resource without notifications and for an index past its device's
  list. The device service answers `ok` for `ERX_OK` and `{error,
  Status}` otherwise, and the line service answers `reset` with `eio`
  for any error, before its next step.
* **After a timeout.** The call's rule holds for the whole boot and every
  device: after one `ERX_ETIMEDOUT`, every later notification of the
  boot answers `ERX_ETIMEDOUT` at once without touching the mailbox. So a
  Bluetooth power request that times out also keeps the VL805's
  notification from being sent in that boot, and the bridge's
  `firmware_lost` mark follows at the PCIe domain's next request, as
  design-pcie has it; a VL805 notification that timed out likewise
  leaves the Bluetooth line unable to power-cycle, and every `reset`
  answers `eio` until the next boot. A mailbox that does not answer in
  1 s is broken for every caller, and neither consumer works around it.
* **Concurrency.** The device service makes every notification from its
  one process, so two requests never meet in the kernel and `ERX_EBUSY`
  still arises only beside a trial request. The device service waits on
  the kernel call alone; the off and on times are the line service's
  timers, so a power cycle holds the device service for two calls, at
  most 1 s each.

**In hosted mode** the line's driver is `erx_stdio` over a descriptor the
harness opens to a Bumble controller's TCP transport and passes to the
hosted runtime, speaking the same six messages
([design-runtime.md](design-runtime.md#the-console-and-standard-io)), so
the line service, the tree and everything in the Bluetooth domain are the
ones the board runs; the hosted record names no power line, and a fresh
start of `erx_stdio` drops what it has read. A future transport, a
virtio-console port on QEMU `virt` or HCI over USB, is another driver
behind the same tree.

### What a radio peer can make the domain spend

Every bound is a constant of `abi/formats/bluetooth.txt` or of the
table, fixed before any peer arrives:

| Resource | Bound | Fixed by |
| --- | --- | --- |
| connections | the row's limit, at most `bt_connections_max`, 4; advertising stops at the limit | the controller process |
| ACL packets in flight to the controller | the controller's LE buffer count, at most `bt_acl_credits_max`, 8, split evenly among the configured connections, so no link holds another's | the controller process |
| packets and commands waiting to be written | one: the writer takes the next only after its last write returned | the controller process and the writer |
| notifications waiting for a link's credits | `bt_notify_queue`, 16, per link; past it `notify` answers `{error, busy}` | the link |
| an ACL packet from the controller | `bt_acl_rx_max`, 251 octets of data, which the bring-up states with Host Buffer Size; a longer one is a loss of synchronization | `erx_h4` |
| an L2CAP frame being reassembled | 4 bytes of header and the channel's MTU: 247 for ATT, 65 for SMP, 23 for signaling; a longer frame ends the link | `erx_bt_link_core` |
| ATT requests | one outstanding (ATT 3.3.2); a second before the response ends the link | the link |
| ATT commands waiting for a handler | `bt_write_queue`, 16; past it a command is discarded and counted, as ATT 3.3.2 allows | the link |
| a prepared (long) write | one per link, at most the characteristic's maximum, 512 octets at most | the link |
| subscriptions | one configuration per characteristic with notify or indicate, per link | the table |
| pairings | one at a time, in an open window, which closes at the first, and none during the pairing wait | the window |
| bonds | `bt_bonds_max`, 8 | the store |
| the stored state | `bt_state_max`, 4 KiB | the store |
| time | every HCI command 5 s; every handler's answer 5 s; SMP 30 s (SMP 3.4); an indication 30 s (ATT 3.3.3) | each owner |

A peer that passes a bound loses its link and costs nothing more; the
controller's report of the disconnection returns its credits.

## Stage 1: the controller and advertising

### H4 framing

`erx_h4:split(Bytes) -> {Packets, Rest} | {error, Reason}` takes the bytes
read so far and returns every whole packet, by binary matching on the
indicator and the length field of each packet kind: an event's one-byte
length (`0x04`, code, length), an ACL packet's two-byte length (`0x02`,
handle and flags, length). Any other indicator, and an ACL length beyond
`bt_acl_rx_max`, is a loss of synchronization (Part A, section 4): the
controller process ends, and its restart resets the line and the
controller. The bound is the host's own, the same before and after the
bring-up: 251 octets, the longest L2CAP frame any link accepts (4 bytes
of header and ATT's MTU of 247), so a longer packet could carry nothing
a link takes. The bring-up tells the controller with Host Buffer Size,
by which the controller segments what it sends the host (HCI 7.3.39),
so only a controller that ignores it meets the bound. LE Read Buffer
Size bounds the other direction alone (HCI 7.8.2) and plays no part
here. `Rest`, an incomplete packet, is at most one packet's bound.
Synchronous and ISO packets are never enabled, so their indicators are
errors too.

### The bring-up

The bring-up is a state machine in `erx_bt_hci_core`, explored
exhaustively on the host. Each step sends one command and waits for its
Command Complete with status success, within the command deadline; any
other answer, or none, ends the controller process with the step and the
status as its reason.

1. **Reset the line.** Write `reset` to `ctl`. The controller is fresh
   from power-on where the platform has a power line, and the UART is
   programmed afresh ([A reset](#a-reset)).
2. **`HCI_Reset`** (HCI 7.3.2).
3. **Identify.** Read Local Version Information (7.4.1), Read Local
   Supported Commands (7.4.2), LE Read Local Supported Features Page 0
   (7.8.3) and Read BD_ADDR (7.4.6), each shown at `/proc/bt`.
4. **Patch**, only when the row names a patch; with none, the bring-up
   goes from step 3 to step 5. The row also names the
   manufacturer the patch is for, from probe B-P3; a controller that
   reports another stops the bring-up with `patch_for_other_controller`,
   so no vendor command reaches a controller it was not written for. The
   step sends `0xFC2E` and waits `bt_patch_minidriver_ms`, replays the
   patch's records, each a command whose Command Complete it awaits, waits
   `bt_patch_launch_ms`, and then runs two steps of its own: **`HCI_Reset`
   after the patch** and **identify after the patch**, the commands of
   steps 2 and 3 again, so `/proc/bt` shows the patched version, after
   which it goes to step 5. The patched states are distinct from the
   first ones, so the bring-up patches at most once and is a line of
   states, not a loop. The waits are NetBSD's, 1 s
   and 4 s (`init_bcm43xx.c:123-125`, `:139`), the longer of the two
   permissive hosts' (Zephyr waits none and 270 ms); probe B-P5 settles
   them. The patch is read whole, by `erx_bt_patch:records/1`, before its
   first record is sent: it accepts a file made only of complete records
   of the opcodes `0xFC4C` and `0xFC4E`, which Zephyr's loader also
   requires, and refuses any other, so a damaged file sends nothing
   rather than half a patch. The controller's name, which NetBSD uses to choose the file
   (`init_bcm43xx.c:110-114`), is text the controller writes and chooses
   nothing here.
5. **Buffers.** LE Read Buffer Size (7.8.2); a controller that answers 0
   packets shares its BR/EDR buffers, which Read Buffer Size gives (HCI
   4.1.1); a length from 1 to 26, which 7.8.2 reserves, or a count of 0
   from Read Buffer Size, stops the bring-up. Then Host Buffer Size (7.3.39) with
   `bt_acl_rx_max` and the host's packet count, flow control from the
   controller staying off.
6. **Configure.** Set Event Mask (7.3.1) and LE Set Event Mask (7.8.1)
   with the events erXos decodes and no others; LE Set Random Address
   (7.8.4) with the identity address ([below](#the-identity-address));
   LE Set Advertising Parameters, Data and Scan Response Data (7.8.5,
   7.8.7, 7.8.8).
7. **Ready.** LE Set Advertising Enable (7.8.9) while connections are
   below the limit.

The patch ships in the Pi 4's image as a file of `erx_bt`'s `priv`
directory, unmodified, under its license (Cypress's Driver End User
License Agreement, `LICENSE.cypress` of the firmware repository, which
grants reproduction and distribution "in object code form only, solely
for use in connection with Cypress integrated circuit products" and
forbids modification), with its notice in the image's `NOTICES`; the Pi 4's
manifest alone names it. It is in the boot image rather than on the
boot partition beside the VideoCore firmware because erXos, not the
firmware, reads it, and only the slot writer may read a slot's partitions
([design-system.md](design-system.md#the-manifest), property 8).

### Commands and data credits

The controller process keeps one command in flight: it sends the next
only when the last was answered, by Command Complete or Command Status,
and the controller's latest `Num_HCI_Command_Packets` is at least one (HCI
4.4); a Command Complete or Status with opcode `0x0000` only updates that
count, and one whose opcode is neither `0x0000` nor the command in
flight's ends the controller process, as a loss of synchronization
does. Commands in this design are few and none is urgent, so one in
flight is enough and makes every command's answer the answer to the last.

ACL packets to the controller use packet-based flow control (HCI 4.1.1):
the controller process counts free buffers from LE Read Buffer Size,
at most `bt_acl_credits_max`, takes one for each packet it gives the
writer and keeps, for each live handle, how many of its packets are
outstanding. It returns them on Number Of Completed Packets and, for a
handle, all of its outstanding ones at Disconnection Complete (HCI 4.2).
A completion that names a handle that is not live, or more packets than
the handle has outstanding, is a controller fault and ends the controller
process, so a forged report can return no credit for a packet that was
never sent. Each link may hold at most its share of the buffers in
flight; a link's notifications wait in its own queue, at most
`bt_notify_queue`, for its share. Controller-to-host flow control is not
enabled: the host always reads, and the line's bound is the backstop.

The controller process does no I/O itself: a reader process keeps one
read of `data` outstanding and sends the bytes it got, waiting for the
controller process's acknowledgement before the next read, and a writer
process writes what the controller process gives it, one packet or
command at a time, acknowledging each once its write of `data` returned;
the controller process gives the next only after the acknowledgement.
So what waits for the line is bounded locally, by one item at the writer
and the credits and the command slot at the controller process, whatever
the controller reports; the controller process never waits on the line
and always takes events; and what the line delivers faster than the stack
consumes waits in the line service, up to its bound.

Events the controller process decodes: Command Complete, Command Status,
Disconnection Complete, Encryption Change, Encryption Key Refresh
Complete, Number Of Completed Packets, Hardware Error, and the LE Meta
events LE Connection Complete, LE Long Term Key Request and LE
Connection Update Complete. Any other event is counted and dropped after
its length is checked. Hardware Error ends the controller process.

### The identity address

erXos's identity on the air is a **static random address** that the
Bluetooth domain makes from `erx_bytes:entropy/1` and sets with LE Set
Random Address; advertising uses it as its own address. It names neither
the board nor its controller, so no Bluetooth address of an erXos
machine names its hardware, as no IPv6 address does
([design-network-stack.md](design-network-stack.md#ipv6-neighbour-discovery-and-autoconfiguration)).
It needs no vendor command to set the public address and no address in
the device tree. Before stage 4 a new one is made at each start of the
Bluetooth domain, which costs an unbonded phone nothing, since it
rediscovers at every connection. From stage 4 it is part of the stored
state and lasts as long as the bonds that name it. Its form, two top
bits set and the rest neither all zeros nor all ones, is Vol 6 Part B
1.3.2.1's, unverified until that part is read; the test of its maker
checks it against Bumble's address parser.

### Advertising

The controller process advertises, connectable and undirected, on all
three channels at a 100 ms interval, while connections are below the
row's limit. The data are computed once, from the table:

* **advertising data:** the Flags structure (LE General Discoverable,
  BR/EDR not supported) and the list of UUIDs of the services whose
  declaration says `advertise`, as complete lists of 16-bit and 128-bit
  UUIDs;
* **scan response data:** the complete local name, or the shortened name
  where it does not fit, and the appearance when it fits.

Each is at most 31 bytes, and the manifest check computes both and
refuses a configuration whose advertised UUIDs do not fit; the name is
shortened rather than refused. The AD type values come from Bumble's
`core.py:1594-1622`, unverified against the supplement.

When a connection completes, the controller stops advertising, as it does
for connectable advertising, and the controller process enables it again
while connections remain below the limit.

## Stage 2: the GATT server

### Declarations: `abi/gatt`

A service is one checked-in file, `abi/gatt/NAME.txt`, as a keyboard
layout is ([design-display.md](design-display.md#input-events)). For
example:

```text
# nus: a serial line in the style of Nordic's UART service.
service nus 6e400001-b5a3-f393-e0a9-e50e24dcca9e advertise
#              name uuid                                 max  accesses
characteristic rx   6e400002-b5a3-f393-e0a9-e50e24dcca9e 244  write open write_without_response open
characteristic tx   6e400003-b5a3-f393-e0a9-e50e24dcca9e 244  notify open
```

A `service` line gives the service's name, an identifier, its UUID, 16-bit
or 128-bit, and optionally `advertise`. Each `characteristic` line gives
its name, an identifier unique in the service, its UUID, the maximum
length of its value, at most 512, and the accesses it allows, each with
the level it requires: `read`, `write`, `write_without_response`,
`notify` and `indicate`, each `open`, `encrypted` or `authenticated`. A
readable characteristic may end with `value` and its initial value in
hexadecimal, so a constant needs no handler.

`tools/gen_gatt.rb` reads every file and generates `erx_gatt_decl`, one
term per service, and the list of names the manifest check holds a row
to. It refuses a missing or repeated `service` line, a name that differs
from its file's, a UUID that is malformed or is one of the GATT and GAP
declarations' own, two characteristics of one name or UUID, a maximum
over 512, an access without a level or repeated, a `notify` and an
`indicate` with different levels, a characteristic with no access, an
initial value longer than its maximum or on a characteristic that is not
readable, and a byte above 0x7f. Nothing reads a declaration at run time,
so it is not an input to fuzz.

Which services a machine serves is the manifest's: each `ble` facet row
names, in its `services` parameter, the services its grantee handles, and
the Bluetooth domain's row names its console's. The manifest check refuses
a service no file declares, a service two rows name, two served services
of one UUID, more than `gatt_services_max` services, and advertising data
that do not fit.

### The attribute table

`erx_gatt_db:build/1` lays out, in this order: the GAP service, with
Device Name and Appearance, read `open`; the GATT service, with Service
Changed, `indicate open`, and its Client Characteristic Configuration;
then each served service in the order of its name, each characteristic as
its declaration, its value and, when it allows `notify` or `indicate`,
one Client Characteristic Configuration descriptor. The descriptor is
readable openly and writable at the one level of the characteristic's
`notify` or `indicate`, whichever it declares, since the generator
refuses the two at different levels, so subscribing is gated as
notifying and indicating are, for Service Changed's `indicate open` as
for any other. The GATT service has
no Database Hash: with Service Changed alone, robust caching is not
required (GATT 2.5.2.1).

A characteristic's value is the one the handler last set, or the
declared initial value, or empty: a read never waits on an app. A read of
a value that changes between two Read Blob requests may tear, which ATT
leaves to the higher layer (3.2.9); the one reader such tearing would
hurt, a long read of a value an app changes while a phone reads it, is
named in no stage.

### The ATT server

`erx_gatt_server:request(Pdu, Table, Bearer) -> {Response, Effects,
Bearer}` answers one request over the table and the bearer's state. It
answers Exchange MTU with 247, Find Information, Find By Type Value, Read
By Type, Read, Read Blob, Read By Group Type, Write Request, Prepare
Write and Execute Write, and takes Write Command and Handle Value
Confirmation; every other request is Request Not Supported with handle
0, every other command is ignored (ATT 3.3), and a request whose length is
wrong is Invalid PDU. These cover the server's mandatory features and
the optional ones a first stage needs (GATT Table 4.1): Read Multiple and
Read Multiple Variable stay unsupported. A write of a characteristic's
value whose length exceeds its maximum is Invalid Attribute Value Length;
a prepared write that would exceed it is Prepare Queue Full.

`erx_att` is the PDU codec, generated from `abi/formats/bluetooth.txt`
with a fuzz target. Its MTU is per bearer, 23 until the client exchanges
it (GATT 5.2.1).

### The `ble` facet

An app reaches the Bluetooth domain only through its `ble` facet, an
instance of the interface `abi/services/ble.txt` declares, with one
parameter, `services`, a set of at most `gatt_services_max` identifiers.
The facet is a process of the Bluetooth domain that the registry makes
when the domain service introduces the grantee, as the network service
makes its grants
([design-system.md](design-system.md#the-network-domain)). Its operations:

| Operation | Answer |
| --- | --- |
| `attach(Service)` | `{ok, #{Char => Limits}}`: the caller becomes the service's handler; the facet monitors it, and its end detaches it |
| `set(Service, Char, Value)` | `ok`: reads return `Value` from now on |
| `notify(Conn, Service, Char, Value)` | `ok` once queued for the link, or `{error, busy}` when its queue holds `bt_notify_queue` |
| `indicate(Conn, Service, Char, Value)` | `ok` once the phone confirms |

`Service` is one the grant names; `Char` one the declaration names. A
handler receives, through the envelope rule, which the client module
`erx_gatt` alone takes off ([design-domains.md](design-domains.md#the-funnel)):

| Event | Meaning |
| --- | --- |
| `{connected, Conn, #{address := A, bonded := boolean(), level := L}}` | a phone connected, or its link's security changed: `level` is what the link reaches now, `open` until it is encrypted and then its key's, and `bonded` is true once its key is a kept bond's |
| `{mtu, Conn, Mtu}` | the bearer's MTU changed; a notification carries at most `Mtu - 3` octets |
| `{subscribed, Conn, Char, none \| notify \| indicate}` | the phone wrote the characteristic's configuration |
| `{write, Req, Conn, Char, Value}` | a write the gate allowed; the handler answers `erx_gatt:reply(Req, ok \| {error, Code})` |
| `{disconnected, Conn}` | the phone left; `Conn` is dead |

The link takes the next request of its phone only after the handler
answered the last write request, so a handler sees one write request of a
link at a time, as ATT's sequential protocol has them; write commands
queue behind it, within `bt_write_queue`. For a write command the
handler's answer is awaited and dropped, so the queue is its pace. An
answer `{error, Code}` with `Code` from `0x80` to `0x9F` is the ATT
Application Error of that code; Value Not Allowed is `value_not_allowed`.
No answer within 5 s is Unlikely Error (`0x0E`). A service with no
handler serves reads from its values and answers writes Unlikely Error.

`connected` and `disconnected` come from the registry, which monitors
every link: so every handler of a link's services hears of its end,
however the link ended. `erx_gatt_service`, a behaviour over the facet,
turns these into callbacks for an app that wants them, and `erx_gatt`'s
calls are what it uses.

### Links: the fixed channels

A link process reassembles L2CAP B-frames from the ACL packets of its
handle, as HCI 5.4.2's packet-boundary flags mark them, and refuses a
frame longer than its channel's MTU or a continuation without a start,
which ends the link. Channel `0x0004` is the ATT bearer; `0x0006` is SMP;
on `0x0005`, LE signaling, it answers Command Reject, "Command not
understood", to every request, and drops responses: erXos asks no
connection parameter update and offers no credit-based channel. A frame
on any other channel is dropped and counted.

## Stage 3: the serial service

### For apps

`abi/gatt/nus.txt` (above) declares the service, and `erx_gatt_serial`,
a library over the facet, turns it into a byte stream for each phone:
`rx` writes, each `{write, ...}` answered at once, become `{serial, Conn,
Bytes}` messages to the app, and `erx_gatt_serial:send(Conn, Bytes)`
cuts the bytes into notifications of at most `Mtu - 3` octets on `tx`,
returning once all are queued. The stream is as reliable as ATT makes it:
a phone that writes faster than the app reads loses the commands past
`bt_write_queue` (ATT 3.3.2), which nRF-style terminal apps send as write
commands; an app that needs every byte uses `write` with response.

### The console

The phone console is the serial service made a **login line**, as an SSH
connection is ([design-ssh.md](design-ssh.md#an-ssh-connection-is-a-line)):
`erx_bt_console`, in the Bluetooth domain, is the handler of the
`console` service, a declaration with the UART service's UUIDs whose
`rx` and `tx` require `authenticated`. Each phone's stream is a line: it
asks for a name and a passphrase, logs in through the system domain's
login facet, which the Bluetooth domain holds as the SSH and web front
ends hold theirs, and the session's tty takes the line, with the
console process as the tty's master, speaking the console interface's
messages. The login facet's interface is the one the login design settles
for every place a person meets the system
([design-display.md](design-display.md#risks-and-decisions), 14).

The line never logs anyone in without a passphrase, in any build, and
never offers the system shell, which only the console's secure lines
carry ([design.md](design.md#decisions)). Since a passphrase must not
cross the air in clear and a login prompt must not be reachable by
anyone nearby, the manifest check refuses a `console` service whose `rx`
or `tx` is below `authenticated`, which in turn needs stage 4. The
UART service and the console share UUIDs, so a machine serves one of them.

## Stage 4: pairing and bonding

### Secure Connections only

`erx_smp_core` is the Security Manager as responder, a pure state machine
explored exhaustively on the host; `erx_smp` is its PDU codec, with a
fuzz target; `erx_smp_crypto` computes `f4`, `f5`, `f6` and `ah` with OTP's
`crypto` (AES-CMAC, AES-128) and does the P-256 key agreement, with the
sample data of SMP Appendix D as its tests. The responder:

* answers a Pairing Request only while a window is open; outside one,
  Pairing Failed, Pairing Not Supported (`0x05`);
* answers a Pairing Request only once the pairing wait has passed
  ([The pairing window](#the-pairing-window)), and before that Pairing
  Failed, Repeated Attempts (`0x09`), which leaves the window open;
* fails, with Unspecified Reason (`0x08`), a Pairing Request on a link
  whose address resolved to a kept bond, so a link with a key never
  pairs; a window takes it as its pairing and reports `already_bonded`;
* fails, with Authentication Requirements (`0x03`), a request without the
  Secure Connections flag, so legacy pairing never runs: the device
  enforces LE Secure Connections pairing for its services at level 2, as
  GAP 10.2.1 permits, and level 4 is that pairing's by definition;
* sets its maximum and minimum key size to 16 and fails a smaller
  request with Encryption Key Size (`0x06`) (SMP 2.3.4), so every key is
  16 octets;
* states the IO capability the window's mode gives, DisplayOnly or
  NoInputNoOutput, and fails, with Authentication Requirements, a
  pairing whose method would not reach the window's level: a `display`
  window takes Passkey Entry alone, so a phone that offers no keyboard
  cannot make a weaker bond in it;
* asks the phone to distribute its identity key, the IRK and identity
  address, and distributes none of its own, since erXos's identity
  address is static; it clears the link-key bit in both directions, so no
  key for another transport is ever derived (SMP 2.3.5.7);
* checks the phone's public key on the curve, `y^2 = x^3 - 3x + b mod p`
  with both coordinates below `p`, in Erlang before any key agreement,
  and fails a key off the curve with DHKey Check Failed, as SMP
  2.3.5.6.1 requires; it refuses SMP's debug key with Invalid Parameters,
  and a key with the X coordinate of its own with DHKey Check Failed
  (2.3.5.6.1). The curve's constants, which the specification gives in
  Vol 2 Part H 7.6 (not fetched), come from the OpenSSL tree erXos
  already holds, and the check's test feeds a point with `y + 1`;
* makes a fresh key pair and, for Passkey Entry, a fresh six-digit
  passkey from `crypto:strong_rand_bytes/1` for every pairing (SMP
  2.3.5.6.3, 2.3.6);
* gives the link its key when the second phase computes the LTK, so the
  phone's encryption at the end of that phase uses it
  ([One table, one gate](#one-table-one-gate)), and takes the phone's
  identity in the third phase over the encrypted link;
* ends a pairing at 30 s without a step (SMP 3.4), and the link with it.

Before stage 4, the link answers every SMP PDU with Pairing Not
Supported.

### The pairing window

A window is an open fid of the control tree's `pair` file. Opening it
while another window is open answers `ebusy`. The opener writes one
line, `display` or `nodisplay`, at most 16 bytes, which opens the window
for `bt_pair_window_s`, 120 s, and reads lines that the window writes,
each ASCII the window composes from numbers and addresses alone:

| Line | Meaning |
| --- | --- |
| `wait N` | the window is open, and the pairing wait has `N` seconds to run |
| `waiting` | the window is open, the wait has passed, and the machine is bondable (GAP 9.4.3) |
| `passkey NNNNNN AA:BB:CC:DD:EE:FF` | type this passkey on the phone with this address |
| `bonded AA:BB:CC:DD:EE:FF authenticated` or `unauthenticated` | a bond is kept |
| `failed AA:BB:CC:DD:EE:FF REASON` | the pairing failed, with its reason ([Refusals](#refusals-and-error-results)) |
| `closed timeout` | the time ran out |

After `bonded`, `failed` or `closed`, the file ends. Clunking the fid, or
the opener's end, closes the window at once, so no window outlives the
person who opened it, by construction of the file protocol's fid
lifetime ([design-files.md](design-files.md#fid-owners)). A window takes
one pairing: whatever its outcome, the window closes.

**The pairing wait** is SMP 2.3.6's, kept by the window process and not
by any window, so whoever opens windows, and however fast, does not
shorten it. After a pairing fails, whatever the reason, the phone's
disconnection and the timeout included, so that leaving halfway through
Passkey Entry's rounds is a failure too, no Pairing Request is answered
for the wait, which starts at
`bt_pair_wait_min_s`, 2 s, doubles at each further failure up to
`bt_pair_wait_max_s`, 64 s, and halves for each `bt_pair_wait_decay_s`,
600 s, without a failure, down to the minimum; a success leaves it as
it is. A request during the wait is answered Pairing Failed, Repeated
Attempts (`0x09`), which is not a pairing and changes neither the wait
nor the window. SMP asks the wait of a device claiming the failed one's
identity; before its third phase a pairing has no identity but an
address a peer changes at will, so the wait holds for every claimant at
once, which is the rule's strictest reading. The link asks the window
whether the wait has passed before it answers a Pairing Request and
before it sends a Security Request ([Reconnection](#reconnection)), the
other message 2.3.6 governs. The wait starts each life of the window
process at its minimum; nothing a radio peer sends restarts more than
its own link ([Concurrency](#concurrency)). So a guesser gets one try
per window and at most one per wait, and a fresh passkey for each
(SMP 2.3.5.6.3).

Who may open a window is who holds the control tree: the manifest grants
it to administrators' sessions and to the app templates it names, such
as a vendor app that opens a window when its button is pressed. No
window opens by itself, at first boot or ever.

The `nodisplay` window makes Just Works bonds, unauthenticated: they
reach `encrypted` characteristics and never `authenticated` ones. A
nearby attacker can pair during such a window, which is why the level
is the declaration's to require and the window's to offer.

**Where the passkey is shown.** A `display` window's passkey reaches a
person only on the `pair` file, through whatever the opener holds the
control tree by: an administrator's session at the console, over SSH or
the web client, or an app the manifest grants the tree, which shows it
on a display it holds. Each is a channel the system already trusts to
manage the machine, and the passkey is fresh for each pairing; no
passkey is printed on a device or fixed in its configuration, since a
static passkey leaks over repeated attempts. A machine with no such
channel opens only `nodisplay` windows, so it serves `authenticated`
characteristics, the console and Wi-Fi provisioning among them, to no
one; those wait for an out-of-band method of their own design, such as
NFC or a code the phone scans ([Decisions](#decisions), 3).

### Bonds and the store

A **bond** holds the phone's identity address, its IRK, the LTK, the
level, the table hash it was last served, and its subscriptions to
characteristics with `notify` or `indicate`. The stored **state** is the
identity address and at most `bt_bonds_max` bonds, encoded by `erx_bt_state`
in a form with a version, which refuses any other version and any
malformed or oversized input with a fuzz target, since what a store
returns is untrusted wherever a medium can be written. The store keeps
the whole state through one seam, `get() -> {ok, Blob} | none` and
`put(Blob) -> ok | {error, unavailable}`:

* **in a development build**, a file in the Bluetooth domain's directory
  on the data partition, replaced whole by write, sync and rename, as the
  SSH domain keeps its host key before the vault
  ([design-ssh.md](design-ssh.md#host-keys));
* **in a release build**, the vault's state slot `{state, "bt"}`,
  whose `get` and `put` are the seam's
  ([design-system.md](design-system.md#state-slots)); the release
  manifest check refuses a `bt` row whose store is the development one.

A pairing that completes asks the store to keep the new state, the
bond with the subscriptions its link has made so far, and the link's key
is a kept bond's once the store answered `ok`, which `connected` tells
the handlers with `bonded => true`; the link's level does not wait on
the store ([One table, one gate](#one-table-one-gate)). A store that
answers `unavailable` fails the pairing, `failed ... unavailable`, and
the link ends. On a trial boot both stores are read-only, since every
file system mounts read-only
([design-storage.md](design-storage.md#system-updates)), so pairing
fails `unavailable` there and bonds already kept work.

**Pairing never replaces a bond.** A pairing whose phone turns out, at
its key distribution, to have the identity of a bond already kept fails
with `already_bonded`, its keys discarded; the operator ends a bond with
`forget AA:BB:CC:DD:EE:FF` written to the control tree's `ctl`, or
`forget all`, and pairs again. A ninth bond fails with `bonds_full`.
Forgetting a bond ends its connected link. SMP 2.4.3.2 holds a
distributed identity address valid only once a reconnection has used it
with the pairing's key; the same caution keeps a claimed identity from
ever overwriting a kept one.

A bonded link's subscriptions persist across connections, as GATT
3.3.3.3 requires: a write of a Client Characteristic Configuration that
changes it on a link with a kept bond's key is answered with its Write
Response only once the store has kept the new state, and a store that
answers `unavailable` answers Unlikely Error and leaves the configuration
as it was. So a phone that saw its write answered may rely on it after a
power cut, Service Changed's configuration included, which a change of
the table at a later start needs. A write that changes nothing, and
every write on a link whose key is not yet kept, is answered at once; a
Write Command to the descriptor, which has no answer, changes the
configuration and is kept as a request's would be. ATT's one request at
a time and a bonded peer bound the store's writes.

### Reconnection

At LE Connection Complete the link resolves the phone's address against
the bonds: an identity address by equality, a resolvable private address
by `ah` with each bond's IRK (SMP 2.2.2), whose form, top two bits `01`,
is Vol 6 Part B 1.3.2.2's, unverified until read. A resolved link holds
the bond's key from then on, and the transition of [One table, one
gate](#one-table-one-gate) encrypts it; in Secure Connections the Long
Term Key Request carries zero EDIV and Rand, and one that does not is
answered Negative Reply. A resolved link also sends a Security Request
(SMP 3.6.7) with the bond's authentication requirements, MITM set for
an `authenticated` bond, as soon as the pairing wait has passed, unless
the phone has already begun encryption, which SMP 2.4.6 forbids it to
interrupt: a bonded phone that only waits for its notifications is
thereby asked to encrypt, rather than left waiting, and until it does
the gate keeps every notification above `open` from it. At encryption
the registry tells the handlers with `connected`, and the link restores
the bond's subscriptions. When the
bond's table hash differs from the table's and the phone subscribed to
Service Changed, the link indicates Service Changed for `0x0001` to
`0xFFFF` (GATT 2.5.2) and, at the confirmation, records the new hash.

## Later stages

### Wi-Fi provisioning

A phone gives the machine a network's name and passphrase over an
`authenticated` characteristic, so credentials never cross the air in
clear or to a peer who saw no passkey. The Bluetooth side is a
declaration and an app, with nothing new below them. The other side is
the larger part: erXos drives no Wi-Fi today (the CYW43455's Wi-Fi half
is on the Pi 4's SDIO bus), so this stage waits for the Wi-Fi design,
whose credentials live in a state slot of the vault as bonds do
([design-system.md](design-system.md#state-slots)). Its
`authenticated` characteristic needs a passkey shown through a trusted
channel, so a machine with none waits for an out-of-band method
([Decisions](#decisions), 3).

### HID over GATT

A Bluetooth keyboard or mouse types into a display, as a USB one does.
This stage adds the central role and keeps every rule above:

* **Central.** The controller process gains passive and active scanning
  (LE Set Scan Parameters and Enable), an advertising report decoder with
  a fuzz target, and LE Create Connection to bonded devices through the
  filter accept list; a link gains the GATT client, a pure state machine
  over the same codec, explored exhaustively; pairing as initiator
  shares `erx_smp_core`'s checks, with erXos showing the passkey a
  keyboard types, in a window as above.
* **Input only through a bond.** The HID function of a link, the only
  writer of its input records, starts only when the link is encrypted
  with a bond's key, and the GATT client sends no request before that,
  so encryption is the first thing after connection, as HOGP 7.2 asks; a
  link whose encryption fails is ended, never used in clear. The HID
  function discovers the HID service, reads the Report Map with long
  reads, reads each Report characteristic's Report Reference, enables
  notifications of every Input Report (HOGP 4.6, 4.8), and folds each
  notification, with its Report ID prepended when the layout has report
  ids (HOGP 4.8.1), through the USB design's `erx_hid_desc` and
  `erx_hid_core` ([design-usb.md](design-usb.md#hid)), unchanged; their
  descriptor bound, `hid_report_descriptor_max`, is 4 KiB
  ([design-usb.md](design-usb.md#what-a-device-can-make-the-domain-spend)),
  above HIDS's 512. Notifications that arrive before discovery ends wait
  in a bounded queue and fold after it, so the key that woke a keyboard
  is not lost.
* **Input numbers.** The Bluetooth domain serves an input tree of input
  numbers, granted to a display read-only, through the same module as
  the USB domain's, whose stream process writes `release` when its
  occupant ends ([design-usb.md](design-usb.md#hid-reaches-the-display)).
  The domain then has, toward that display, the reach of a person at it
  and no more ([design.md](design.md#threat-model)).

### Classic Bluetooth

Classic HID (BR/EDR) adds inquiry, an SDP client, L2CAP's
connection-oriented channels with configuration, Secure Simple Pairing,
link keys and the HID control and interrupt channels, each a parser with
its fuzz target, under the same window and store, and a link kind beside
the LE link. Cross-transport key derivation stays off unless a consumer
is named. It is designed when a classic device is needed.

## Security

The Bluetooth domain is outside the trusted base. What it holds and what
a radio peer can do:

| Adversary | Can | Cannot |
| --- | --- | --- |
| A radio peer, anyone in range | send any packet the controller forwards; connect while a slot is free and so hold it; read and write `open` characteristics; pair during a `nodisplay` window and so reach `encrypted` characteristics | reach an `encrypted` characteristic without a bond made in a window, or an `authenticated` one without the passkey the window showed; make the system domain parse a radio byte; make the Bluetooth domain hold more than its bounds; replace a bond |
| The controller, its closed firmware | everything a radio peer can; read every LTK erXos gives it; forge what a bonded peer could send | reach anything erXos does not send it: it sees the line, not the machine |
| A compromised Bluetooth domain | everything the controller can; read the bonds; act as any bonded phone toward the apps it serves; see every byte of the console's lines, passphrases included | reach a device, a partition or a facet beyond its row's; log anyone in without the passphrase, which the vault checks |

The vault cannot keep a bond's key from the Bluetooth domain or the
controller, which needs it in clear in LE Long Term Key Request Reply;
what any store gives is sealing at rest and one owner, not containment.

### Attack classes

* **KNOB, key size downgrade.** Every key is 16 octets by construction:
  the responder's minimum is 16 and a smaller negotiation fails with
  Encryption Key Size (SMP 2.3.4), so no bond and no LTK given to the
  controller is shorter; legacy pairing, where EDIV and Rand would carry
  keys, never runs.
* **BLURtooth, cross-transport key overwrite.** No key is derived for
  another transport: the link-key bit is cleared both ways, and erXos has
  no BR/EDR before the classic stage. Independently, pairing never
  replaces a bond, so no unauthenticated pairing overwrites an
  authenticated key, which is the overwrite the attack needs.
* **BLESA, reconnection spoofing.** It attacks a client that accepts data
  from a reconnected server before re-encrypting. As a server, erXos
  decides access from the link's encryption state, set only by the
  controller for a key the link supplied, never from the peer's
  address, so a peer spoofing a bonded phone's address without its LTK
  gets errors. As a client, in the HID stage, the GATT client sends no
  request and the HID function takes no notification before encryption
  with the bond's key, and a failed encryption ends the link.
* **Unauthenticated HID injection,** a host taking HID reports from a
  peer it never bonded with. Until the HID stage erXos takes no input from
  Bluetooth at all; in it, input records come only from a link encrypted
  with a kept bond.
* **Pairing method confusion,** a man in the middle running Passkey Entry
  with one side and Numeric Comparison with the other, where the person
  compares the passkey shown with a number the phone shows. erXos never
  offers Numeric Comparison, and the window's line says to type the
  passkey on the phone; a person who confirms a matching number instead
  remains the attack's residual, which no one side closes.
* **Passkey guessing.** One pairing per window, a fresh passkey per
  pairing and the pairing wait leave a guesser one try in a million per
  window, and at most one try per wait, which doubles to 64 s, however
  windows are opened (SMP 2.3.5.6.3, 2.3.6).
* **Tracking.** The identity address is static for an installation, so
  a machine advertising is recognizable while it advertises, as any
  peripheral without privacy is; advertising with resolvable private
  addresses is a later option with a consumer to name.
* **Holding the only slot.** With the default limit of one connection, a
  peer that connects and stays keeps the phone out. This is a security
  residual of the design, which fails safely: the peer reaches only
  `open` characteristics, and the phone gets no connection rather than a
  wrong one. Its remedy, accepting connections outside a window only
  from bonded phones, through the filter accept list and the
  controller's resolving list, waits for a deployment that needs it.

### Inspection

`/proc/bt` shows the controller (bring-up state, manufacturer, versions,
the patch applied, the address it reports and the identity address),
each connection (`Conn`'s number, the peer's address, the bond's identity
when resolved, the level, the MTU, subscriptions), each bond (identity
address, level; never a key), and the counters: framing errors, dropped
events and frames, discarded commands, refused PDUs, failed pairings by
reason. A value the domain does not know, such as the version before the
bring-up reached it, is `unknown`, never a guess. The line service shows
its line at the system domain's `/proc`: bytes each way, breaks, resets.

## Concurrency

* **One controller process** serializes everything about the controller:
  commands, credits, the handle map, advertising. Links talk to the
  controller only through it.
* **A link per connection** processes its phone's PDUs in order; a
  handler's write answer is a message back to the link, which takes the
  next request only after it, so a link never waits on a handler while
  events arrive: confirmations, commands and the controller's reports
  still reach it.
* **The registry outlives links and the controller.** It sits before the
  controller group in the domain's `rest_for_one` supervisor, so a
  controller restart ends every link, every handler hears `disconnected`
  for each, and handlers stay attached.
* **A disconnection during a handler's answer** drops the answer: the
  reply goes to an alias of the link, which no longer exists; the handler
  has already heard `disconnected` from the registry or hears it next.
* **A notification and a disconnection** race only at the registry, which
  answers `{error, gone}` for a dead `Conn`; a notification queued before
  the end is dropped with the link's queue, as the controller drops what
  it had.
* **One window** exists at a time; its state and the pairing wait are
  the window process's, and the link asks it at a Pairing Request and
  before a Security Request, and tells it the outcome. The window process
  sits before the controller group, so a controller restart, the only
  restart a radio peer's traffic can cause beyond its own link, keeps the
  wait.
* **The store** is one process; a pairing's `put` and a link's
  configuration writes are serialized there, and each `put` writes the
  whole state.
* **The line service** serves one reader and writers in arrival order; the
  Bluetooth domain has one of each. A `reset` holds both until it
  answers; a read waiting at a `reset` answers `eio`.
* **The device service** makes every firmware notification from its one
  process, so a power cycle and the VL805's notification never meet in
  the kernel ([The power line](#the-power-line)).

The supervision tree of `erx_bt`:

```text
erx_bt_sup                      rest_for_one
  erx_bt_store                  the identity address and the bonds
  erx_gatt_srv                  the table, handlers, Conn map, ble facets
  erx_bt_fs                     the control tree and the window
  erx_bt_host_sup               one_for_all, at most 5 restarts in 60 s
    erx_bt_hci                  the controller process
    erx_bt_line_rx, erx_bt_line_tx
    erx_bt_link_sup             a temporary link per connection
  erx_bt_console                when configured
```

## Failure handling

| Failure | Detected by | What ends | Recovery |
| --- | --- | --- | --- |
| a framing error, a Hardware Error event, a command not answered in 5 s, an answer to another command, a completion for a handle not live or beyond its outstanding packets, a failed bring-up step, `eio` on `data` | the controller process | the controller group: the controller process, the line's reader and writer, every link | the group restarts: `reset`, then the bring-up; past 5 restarts in 60 s the domain ends and the domain service restarts it within its intensity |
| a malformed L2CAP frame, a second outstanding ATT request, an SMP timeout, an encryption change the link did not key | the link | the link: the controller process sends Disconnect | the phone reconnects |
| a malformed ATT request | the ATT server | nothing: Invalid PDU | none needed |
| a handler that does not answer in 5 s | the link's deadline | nothing: Unlikely Error | none |
| a handler that ends | the facet's monitor | the handler's attachment | the app attaches again |
| a store that answers `unavailable` | the store | the pairing; at start, the bonds: the domain runs without them and refuses pairing | `/proc/bt` and the log say so; the next start reads again |
| a broken line | the line service | reads of `data` | the controller group's restart writes `reset` |
| a line tree or the host link ends, or line 153's owner | its line group's supervisor | the group after it: on the Pi 4, the tree's fids and, for the owner, the host link's sessions | the group restarts, its owner first; the Bluetooth domain's reads fail and its controller group restarts; the console, in no group, is untouched |
| a power notification that fails | `reset`'s answer, `eio` | the bring-up | the group's restart retries within its intensity; after an unanswered request every later notification of the boot fails at once, the VL805's included, so the Bluetooth domain ends at its intensity, and its log records and the line service's `/proc` show why |
| a configuration write the store does not keep | the store's `unavailable` | nothing: Unlikely Error, the configuration unchanged | the phone writes again |

## Refusals and error results

| Interface | Refusal | When |
| --- | --- | --- |
| the line's `ctl` | `einval` | any write but `reset` |
| | `eio` | a power notification answered other than `ERX_OK`, `ERX_ETIMEDOUT` for every one after the boot's first timeout included |
| the line's `data` | `eio` | the line is broken |
| the control tree's `pair` | `ebusy` | another window is open |
| | `einval` | a first write other than `display` or `nodisplay` |
| | `eio` | the store is unavailable |
| the control tree's `ctl` | `einval` | any write but `forget ADDRESS` or `forget all` |
| | `enoent` | no bond has that identity |
| `ble` facet | `{error, not_granted}` | a service the grant does not name |
| | `{error, attached}` | the service already has a handler |
| | `{error, no_such_characteristic}`, `{error, not_allowed}` | an unknown name; an access the declaration does not allow |
| | `{error, too_long}` | a value over the characteristic's maximum, or a notification over the bearer's `Mtu - 3` |
| | `{error, busy}` | the link's notification queue holds `bt_notify_queue` |
| | `{error, gone}` | a dead `Conn` |
| | `{error, not_subscribed}`, `{error, insufficient_security}` | the phone did not subscribe; the gate refused |
| | `{error, timeout}` | an indication unconfirmed in 30 s, after which the link ends (ATT 3.3.3) |
| a pairing, on `pair` | `failed ADDR not_supported`, `secure_connections_required`, `key_size`, `method`, `confirm`, `dhkey`, `timeout`, `already_bonded`, `bonds_full`, `unavailable`, `disconnected` | SMP's reasons and the store's, each mapped from one Pairing Failed code or one event |
| a Pairing Request during the pairing wait | Pairing Failed, Repeated Attempts (`0x09`) | the wait has not passed; no line on `pair`, the window stays open |
| a configuration write on a bonded link | Unlikely Error (`0x0E`) | the store answered `unavailable` |

The ATT errors erXos sends are Table 3.4's: Invalid Handle, Read Not
Permitted, Write Not Permitted, Invalid PDU, Insufficient Authentication,
Request Not Supported, Invalid Offset, Prepare Queue Full, Attribute Not
Found, Attribute Not Long, Invalid Attribute Value Length, Unlikely Error,
Insufficient Encryption, Unsupported Group Type, Value Not Allowed and the
handler's Application Errors. The SMP reasons it sends are Table 3.7's
Authentication Requirements, Confirm Value Failed, Pairing Not Supported,
Encryption Key Size, Command Not Supported, Unspecified Reason, Repeated
Attempts, Invalid Parameters and DHKey Check Failed.

## Verification

Agents iterate on the host tests and hosted mode; the board runs by hand,
once per batch, under the manual checklist.

### Host tests of the cores

Each passing case is paired with the seeded fault it must catch.

| Core | Passes | Seeded fault that must fail it |
| --- | --- | --- |
| `erx_h4` | a stream cut at every byte offset splits into the same packets; an unknown indicator and an over-long ACL length are errors | the indicator check removed; the ACL length read as one byte |
| `erx_bt_hci_core`, explored over every reachable state | every command waits for its answer; credits never go below zero and a Disconnection Complete returns a handle's outstanding packets; a completion for a dead handle, one beyond a handle's outstanding packets and an answer naming another command each end the controller process; the writer is never given a second item before its acknowledgement; every bring-up path from `reset` reaches `ready` or a stated reason, patching at most once; advertising is on exactly while connections are below the limit | the command slot not cleared by Command Status; credits not returned at disconnection; a completion's count added without the outstanding bound, so a forged report grows the credits; advertising not re-enabled after a disconnection |
| `erx_h4` against `bt_acl_rx_max` | a 251-octet ACL packet splits; a 252-octet one is an error, before and after the bring-up | the bound taken from LE Read Buffer Size once known |
| `erx_bt_patch` | the records of a synthetic patch replay in order; a file with a truncated last record or a foreign opcode is refused whole, before any record is sent | the record length not checked against the bytes left |
| `erx_gatt_db` | a table built from the declarations matches a hand-written expected table; the hash changes when a characteristic changes and not when the manifest lists rows in another order | services laid out in manifest order |
| `erx_gatt_gate` | GAP Table 10.2's rows for levels 1, 2 and 4, each answer as the table gives | Insufficient Encryption answered on a link with no key |
| `erx_gatt_server` | each supported request against the table; long reads and prepared writes at every MTU from 23 to 247; the gate is asked for every value and descriptor access | the gate skipped for Read Blob; the descriptor's write level taken from `read` |
| `erx_bt_link_core`, explored | reassembly at every fragment size; one outstanding request; commands past the queue discarded and counted; a first pairing encrypts with the pairing's key and reaches its level before the store answers, and a reconnection with the bond's key reaches the bond's; a Pairing Request on a resolved link fails; `encrypted` set only by a success report after a Reply; a resolved link sends one Security Request, never during encryption; a bonded configuration write is answered only after the store's `ok` | an Encryption Change accepted after a Negative Reply; encryption accepted only for kept bonds, so the first pairing never reaches its level; the configuration write answered before the store's answer |
| `erx_smp_core`, explored over every message order | Passkey Entry and Just Works complete; every refusal of [Secure Connections only](#secure-connections-only) fires; a `display` window refuses Just Works; one pairing per window | the key-size check removed; the curve check removed (the `y + 1` point is accepted); the link-key bit kept |
| `erx_bt_window`, the window and the wait | the wait is 2, 4, ... 64 s after successive failures, a disconnection mid-pairing counting as one, stays at 64, halves after 600 s without one; a Pairing Request during it answers Repeated Attempts and leaves the window open; windows opened back to back do not shorten it | the wait reset when a window opens; a disconnection not counted as a failure |
| `erx_pl011:program/2` | `fresh` writes `CR` 0 first, clears `FEN` before the divisors, drains the receive side within 33 reads, writes `IBRD` and `FBRD` before `LCR_H` and `CR` whole last with the flow enables; `keep` is today's sequence | `LCR_H` written before the divisors, so the rate never latches; `fresh` keeping the boot's divisors |
| `erx_smp_crypto` | SMP Appendix D's sample data for `f4`, `f5`, `f6` and `ah` | the AES-CMAC key byte order reversed |
| `erx_bt_state` | a state round-trips; every other version, a truncation and an oversized count are refused | the bond count read without its bound |
| the line's `ctl` grammar | `reset` with and without newline accepted; everything else `einval` | a prefix match accepting `resetx` |
| the line service's reset, over a model driver and a model device service | the four steps run in order; the driver's input during the on time is discarded; a power `{error, _}` answers `eio` before the next step | the driver started before the off notification, so the old FIFO drains into the new controller |
| the identity address | 10,000 addresses all have the static form and parse in Bumble's `Address` as static | the top bits cleared |

### Fuzz targets

`erx_h4`, the HCI event decoder, the L2CAP reassembly and frame decoder,
the LE signaling decoder, `erx_att`, `erx_smp`, `erx_bt_state`, the line
service's `ctl` grammar, the control tree's `pair` and `ctl` grammars,
and the `ble` facet's request decoder; in the HID stage, the advertising
report decoder, the GATT client's response decoder and the Report
Reference decoder (the Report Map is `erx_hid_desc`'s, which has its
own). Each runs at the milestone gate's budget, and the codecs are also
compared with Bumble's decoders on the same corpus, a differential test
on the host.

### Hosted mode against Bumble

The harness, in Ruby, runs Bumble unmodified: `apps/controllers.py` with
two TCP transports joined by its local link, one controller for erXos's
line, whose socket the harness passes to the hosted runtime as the
line's descriptor, and one for the peer. `controllers.py` takes exactly
two transports (`len(sys.argv) != 3`, line 28), which is what a test
needs. Bumble's stream transports carry H4 framing
(`bumble/transport/common.py:41-46`, `:125-144`), and its controller
implements every command stage 1 to 4 send (`bumble/controller.py:1996`,
`:2344`, `:2874`, `:2953`, `:3004-3067`, `:3299-3310`). Python runs only
the peer's scripts, in `test/bt/peer/`, each started by the harness by
argument vector:

| Stage | Peer | Passes | Seeded fault |
| --- | --- | --- | --- |
| 1 | `examples/run_scanner.py tcp-client:...`, and a peer script that scans and prints each report as one JSON line | erXos's name and its advertised UUIDs appear; after a `reset` and bring-up they appear again | the advertising data built with the 16-bit list's type for 128-bit UUIDs: the UUIDs are missing |
| 2 | `examples/run_gatt_client.py` and `apps/gatt_dump.py` | every attribute of the expected table is discovered, with its handle; `open` values read as set; `encrypted` ones answer Insufficient Authentication | the gate allows every read: the `encrypted` value is read |
| 2 | `test/bt/peer/gatt_peer.py`: writes, a write past the maximum, a subscription, notifications, an indication and its confirmation, a long write | each answers as declared; the handler sees each write once, in order | the link takes a second request before the handler answered the first |
| 3 | `test/bt/peer/serial_peer.py`: 64 KiB through an echo app with `write` with response | every byte comes back in order | `erx_gatt_serial:send/2` cutting at `Mtu` rather than `Mtu - 3` |
| 4 | `apps/pair.py --mode le --sc true --mitm true --io keyboard C tcp-client:...`, where the device configuration `C` fixes the peer's address and names its key store, `"keystore": "JsonKeyStore:K"` (`bumble/keys.py:198-206`, `:272-285`); the harness reads the passkey from the `pair` file and writes it to `pair.py`'s standard input, which `input()` reads (`apps/pair.py:102-107`, `:159-168`) | `bonded ... authenticated`; then `apps/gatt_dump.py --device-config C --encrypt` reads an `authenticated` value; after the Bluetooth domain restarts, it reads it again | the LTK reply sending a key of the wrong bond: encryption fails |
| 4 | `apps/pair.py --sc false` | `failed ... secure_connections_required` | the Secure Connections flag check removed |
| 4 | `apps/pair.py` while no window is open | Pairing Not Supported | the window check removed |
| 4 | a second `apps/pair.py` run with the same address and an empty key store, in a new window | `failed ... already_bonded`; the first key store still encrypts | the bond replaced |
| 4 | `apps/pair.py` with a wrong passkey, then again at once in a new window | the first `failed ... confirm`; the second answered Repeated Attempts until 2 s have passed, then pairs | the wait not kept across windows |
| 4 | a bonded peer subscribes, the Bluetooth domain is killed at once after the Write Response, and the peer reconnects encrypting only on erXos's Security Request | the subscription is restored and a notification arrives | the configuration kept only at the link's end; no Security Request sent |

Reconnection with a resolvable private address uses Bumble's
`examples/device_with_rpa.json` as the peer's configuration.

### On the board

The Pi 4's checklist, by hand, with a phone and with a Bumble peer on a
USB dongle on the development host, which makes the peer side scripted:
the machine appears in the phone's scanner with its name; nRF-style GATT
browsers show the declared table; a terminal app for Nordic's UART
service echoes through an app; the phone pairs by typing the passkey the
`pair` file shows, reboots the machine, and reads an `authenticated`
value again; the console logs in from the phone; a `reset` written
while the stack is mid-way through a patch download is followed by a
bring-up that reaches advertising. The board probes precede the first
of these ([Board probes](#board-probes)).

## Performance

Nothing here is on a fast path. What may matter, and is on the watch
list ([todo-performance.md](todo-performance.md)):

* the patch download at 115200 baud: `BCM4345C0.hcd` is 63,806 bytes in
  the firmware repository's tree listing at `cdf61dc691a4`, about 5.5 s
  at 11,520 bytes a second before the record overheads and the 5 s of
  waits, so a boot or a restart advertises some ten seconds after the
  bring-up starts; the vendor rate command `0xFC18`
  (`init_bcm43xx.c:152-158`; `hci_uart_infineon.c:100-131`) and a `rate`
  word of `ctl` would cut it, if a measurement says the wait matters;
* a phone's write reaching a handler and its answer coming back across
  two domains, measured by a peer script that times write requests
  through an echo handler, in hosted mode and on the board;
* `erx_pl011`'s wait of 1 ms at a time while its transmit FIFO is full
  (`erx_pl011.erl:45`, `:236-243`), which the patch download and bursts
  of notifications meet.

## Changes to other designs

* **[design.md](design.md)**: the document map's row; the dependency
  table's rows for the Cypress patch and for Bumble on Python; the license
  allowlist admitting Cypress's driver license for the patch file of the
  Pi 4's image; the languages decision's Python for the test peer's
  scripts; the threat model's rows for a radio peer and for the
  controller or a compromised Bluetooth domain; the line service's `ctl`
  among the funnels into the trusted base.
* **[design-system.md](design-system.md)**: property 8 gives the unit of
  each `line` grant's UART to the system domain beside the console's and
  the host link's, keeps the console's UART off every other system-domain
  UART's interrupt line, and refuses two `line` grants of one UART; the
  line service in the services table; and the vault's **state slots**,
  an opaque sealed blob per purpose `{state, Service}` in the machine's
  file, which the vault bounds and never parses, the store of bonds here
  and of the Wi-Fi design's network keys
  ([design-system.md](design-system.md#state-slots)).
* **[design-shared-devices.md](design-shared-devices.md)**: the system
  domain's line groups, one `rest_for_one` supervisor per interrupt line
  of the host link's and the line trees' UARTs, the line's owner first;
  the console outside them, on a line of its own, as the refusal and the
  open decision on a console and host link on one line already have it.
* **[design-platforms.md](design-platforms.md)**: the Pi 4's UART0 is
  driven, for the Bluetooth line, sharing line 153 with UART3; its device
  entry lists the controller's two power notifications; the firmware's
  power control is used for that one device, through the firmware
  notification; the overview's Bluetooth row.
* **[design-usb.md](design-usb.md)**: `erx_firmware_notify` takes the
  index of one of the notifications the platform record lists for the
  resource's device, the VL805's one being index 0, and answers
  `ERX_ENOTSUP` for an index past the list; the device service makes the
  Bluetooth line's notifications too, from the same process, through
  `erx_domain_lib:device_notify/2`
  ([design-usb.md](design-usb.md#the-vl805s-firmware)); `erx_hid_desc`
  and `erx_hid_core` in an application of their own, `erx_hid`, which the
  USB and Bluetooth releases both ship; the input tree with its stream
  processes as one module both domains use, in place of the input part
  of `erx_usb_places_sup`.
* **[design-runtime.md](design-runtime.md)**: `erx_pl011` takes
  `init => fresh` or `keep` from its record and performs the writes
  `erx_pl011:program/2` returns; the console's and the host link's
  records say `keep`, which is today's sequence.
* **[plan.md](plan.md)**: a proposed track for Bluetooth.

## Alternatives considered

* **A domain registers its services at run time.** Every stack surveyed
  has the application register a service table in code. Here it would
  bring handle allocation while phones are connected, Service Changed and
  change-unaware clients within a connection, run-time conflicts between
  apps, a run-time parser of declarations with its fuzz target, and
  advertising data that may stop fitting. Declarations as configuration
  remove all of these; an app installed later brings its declaration
  with its package, and the table changes at the Bluetooth domain's next
  start.
* **Reads answered by the handler.** A read that waits on an app needs a
  deadline, a policy for a missing handler and a consistency rule across
  Read Blob requests. A value the handler sets covers the constants,
  measurements and states the stages need; a characteristic whose read
  must compute can be added as a declared access when one is named.
* **Characteristics as files.** The display serves windows as files, and
  an app could write `value` and read a stream of writes. A write
  request needs the app's verdict within the ATT transaction, which a
  file stream cannot answer without a second file and a matching rule:
  a live conversation, so a declared protocol.
* **The controller's own P-256** (LE Read Local P-256 Public Key, LE
  Generate DHKey, HCI 7.8.36 and 7.8.37) and ctaes for AES. It would keep
  OpenSSL out of the Bluetooth domain, at the cost of a new AES primitive,
  a dependency on commands a controller may lack, and the curve check
  still in the host. The network domain calls no OpenSSL because a SYN
  flood would make hashing per packet
  ([design-network-stack.md](design-network-stack.md#where-c-is-used-and-what-is-measured));
  here the inputs that reach OpenSSL are one 64-byte public key per
  pairing in a window and 16-byte blocks, checked first.
* **3 Mbaud from the start.** It needs a rate word in `ctl`, the vendor
  rate and clock commands whose details differ between NetBSD and Zephyr
  (`0xFC45` sent or not), a switch timed to a response, and a transmit
  path faster than `erx_pl011`'s millisecond wait. 115200 carries BLE's
  traffic for the stages; the rate is a measured optimization.
* **Choosing the patch by the controller's local name**, as NetBSD does.
  The name is text the controller writes; the manifest names the file.
* **The Bluetooth domain inside the devices domain.** One ERTS fewer, but
  a parser defect reachable from anyone in range would reach every slow
  device's driver.
* **A power line left alone.** Without a power cycle, a restarted
  bring-up meets a controller at an unknown rate, patched or not, and
  needs a case for each.
* **A UART left as the last driver had it.** Restarting `erx_pl011` the
  console's way keeps the boot's divisors and both FIFOs, so a restarted
  bring-up would meet the last controller's bytes and whatever rate the
  boot chose; programming the line afresh makes the UART one state as the
  power cycle makes the controller one.
* **A pairing wait per window, or none.** One pairing per window alone
  gives no interval between attempts when an app opens windows itself;
  a wait per claimed identity cannot hold before a pairing's third phase,
  where the only identity is an address a peer chooses.
* **A `lines` field in the manifest.** A field of its own beside
  `console` and `hostlink` would need its own packed representation and
  reader; a `line` grant's parameters are a facet row the manifest
  already has, checked as every parameter is.

## Decisions

1. **Decided: bonds go in an opaque sealed state slot of the vault.** The
   state is the identity address and the bonds, at most 4 KiB, needed at
   boot before anyone logs in, and sent whole to the controller in use,
   so any store gives sealing at rest and one owner, not containment.
   The vault keeps it as one blob of purpose `{state, "bt"}` in the
   machine's file, sealed as machine keys are, with `get` and `put`; it
   parses nothing of the blob and learns no Bluetooth structure, and the
   Bluetooth domain's `erx_bt_state` decodes it as untrusted input
   ([design-system.md](design-system.md#state-slots)). The slot is
   generic, and the Wi-Fi design keeps its network keys in one too. The
   alternatives were a bond purpose with store, forget and list, which
   teaches the vault a bond's structure for no protection the slot
   lacks; a seal-and-open purpose, which leaves the domain a data grant
   and its own atomic replacement, which the vault's publication already
   gives; and the development file in release builds, as FreeBSD's
   `hcsecd` keeps its link keys in `/var/db/hcsecd.keys` (`hcsecd.h:39`),
   which a copied medium yields whole.
2. **Open: whether release builds may offer the phone console.** It is a
   login line reachable over the air by anyone who completed an
   authenticated pairing in a window. **Recommendation:** allowed only by
   an explicit manifest opt-in, the Bluetooth row's console argument, and
   off in every manifest erXos ships; its characteristics `authenticated`,
   which the manifest check requires; the normal login limits of the
   login facet, as at every other line; and never the system shell,
   which only the console's secure lines carry.
3. **Decided: fresh passkeys, shown through a management channel the
   machine already trusts.** A `display` window shows each pairing's
   fresh passkey on the `pair` file, to an administrator's session or an
   app the manifest grants the control tree ([Where the passkey is
   shown](#the-pairing-window)). A machine with no display and no such
   channel opens only `nodisplay` windows, whose Just Works bonds serve
   only services that declare `encrypted` or `open`. Authenticated
   services on such a machine, the console and Wi-Fi provisioning among
   them, wait for an out-of-band method, by NFC or a code the phone
   scans, designed separately. Static passkeys printed on a device are
   excluded: they leak over repeated attempts.

## Board probes

Each runs on the Pi 4 under the stopgap before the code that depends on
it, and its readings go into a research record.

* **B-P1** Read GPIO 30 to 33's function at erXos's start. If not ALT3,
  `config.txt` gains `gpio=` lines for them, as it has for UART3's pins.
* **B-P2** Before any power notification, send `HCI_Reset` at 115200 on
  UART0: did the firmware leave the controller powered? Read the
  expander node's `gpio-line-names` from the device tree the firmware
  passes, find the controller's enable line, its pin and polarity, and
  check that a cycle with 300 ms off and 500 ms on brings the controller
  back at 115200; record whether the controller sends any byte between
  power-on and `HCI_Reset`.
* **B-P3** Read Local Version and Read BD_ADDR before and after the patch:
  the manufacturer the patch row names, the ROM's and the patch's versions.
* **B-P4** Advertise and accept a connection on the ROM firmware, without
  the patch: is the patch needed for the stages at all?
* **B-P5** The patch's two waits: does the download succeed with
  Zephyr's shorter ones?
* **B-P6** Kill the Bluetooth domain mid-way through a patch download,
  with CTS held off by the controller, and check that the next `reset`
  starts the driver without waiting on `BUSY` and that the next bring-up
  reaches advertising.
