# Bluetooth Low Energy: a peripheral that a phone talks to

This document is erXos's Bluetooth stack: how a Bluetooth controller
reaches erXos, which domain parses what it sends, how an erXos machine
advertises itself, serves the GATT services that apps declare to a phone,
carries a serial line to a phone, and pairs and bonds with LE Secure
Connections; what the maker of a device writes to use each of these
([The interface](#the-interface)); and, as later stages, a service's
own octets in the advertising, Wi-Fi provisioning from a phone, the
central role, for HID over GATT into the display's input router and for
apps that read other devices, and classic Bluetooth. It
refines the unit rule of
[design-shared-devices.md](design-shared-devices.md#the-unit-rule), the
Raspberry Pi 4's UARTs of
[design-platforms.md](design-platforms.md#raspberry-pi-4-model-b), the
facets and the manifest of [design-system.md](design-system.md#the-manifest),
the vault of [design-system.md](design-system.md#the-vault) and the input
records of [design-display.md](design-display.md#input-events).

Decisions every reader needs:

* **erXos is a peripheral first.** The first milestone is an erXos
  machine that a phone app finds, connects to and talks to: it
  advertises its name and service UUIDs, serves GATT, carries a serial
  line and pairs. The central role (scanning, connecting, a GATT client)
  is a later stage with two users: HID over GATT inside the Bluetooth
  domain, and apps, through the same facet and the same declarations
  ([The central role](#the-central-role)).
* **A device plugs in at four places, each with one home.** What a
  phone sees is declared as data in `abi/gatt`; an Erlang process
  handles it through the `ble` facet; pairing and bonds are commanded in
  a file tree at `/svc/bluetooth`; and what the stack observes is read at
  `/proc/bt` ([The interface](#the-interface)). Only Erlang code uses
  the `ble` facet.
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
* **A phone gets root's shell over Nordic's UART service.** On a
  development build, `bleuart`, an app shaped as `ntpd` is, masters a
  tty of root's session for the client of Nordic's UART service, as an
  SSH channel masters one: any client in range gets the command shell,
  with no login and no pairing, and never the console's menu or the
  system shell. `service bleuart enable|disable|start|stop` turns it on
  and off; it is on by default on a builder's own card and off on the
  published one, and a release build has none
  ([The console](#the-console)).
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
  failed pairing. Whoever holds the control tree is the machine's
  Bluetooth administrator: a person at a shell, or the one app a device's
  maker gives it to.
* **A bond is the machine's, and a handler knows a bonded phone by its
  bond, never by an address.** A bond reaches every service at its
  level. Each bond has a random name made with it, which only a link
  encrypted with that bond's key carries to a handler, so an app that
  keys its own records by it cannot be fooled by a copied address or a
  later pairing. The name is not a secret: every handler on that link
  hears it, so it lets apps tell phones apart and also lets them
  recognize one phone across services.
* **Bonds are machine secrets.** Release builds keep them in a sealed
  state slot of the vault, an opaque blob the vault never parses
  ([design-system.md](design-system.md#state-slots)); development builds
  keep them in the Bluetooth domain's directory on the data partition,
  as the SSH design keeps its host key before the vault.

## Context

### What is matched

erXos implements the host side of the Bluetooth Core Specification 6.3
(the HTML edition, [Sources](#sources)) for a device in the LE
peripheral role, and is held to what each part requires of it:

| Part | What erXos implements first | What it rests on |
| --- | --- | --- |
| Vol 4 Part A, UART transport (H4) | the host end of the line | a one-byte packet indicator before each HCI packet, `0x01` command, `0x02` ACL data, `0x04` event (section 2, Table 2.1); 8 data bits, no parity, one stop bit, RTS/CTS, which "should not be used for flow control of HCI" (section 3); a wrong indicator or an out-of-range length is a loss of synchronization, after which "a reset is needed" (section 4) |
| Vol 4 Part E, HCI | the commands and events of a peripheral's host | one command outstanding within the controller's `Num_HCI_Command_Packets` (4.4); no ACL packet sent while the controller's free-buffer count is zero (4.1.1); a Disconnection Complete returns every unacknowledged packet of its handle (4.3); LE Read Buffer Size describes packets from host to controller (7.8.2), and the host states the longest ACL packet it accepts with Host Buffer Size, by which the controller segments what it sends the host, flow control on or off (7.3.39) |
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
  `interfaces.adoc`, the table of primary and secondary UARTs). The
  firmware does not set them: probe B-P1 found all four inputs, and with
  a `gpio=30-33=a3` line in `config.txt` it still leaves GPIO 30 and 31
  inputs
  ([research-bluetooth-pi4.md](research-bluetooth-pi4.md#2026-11-23-the-firmware-leaves-uart0s-flow-control-pins-unset)).
  So the system domain sets the four to ALT3 from the platform record's
  on-board pin rows, before the line service opens the line
  ([design-header-io.md](design-header-io.md#on-board-pins);
  [Decisions](#decisions), 5). The rows state no pull, so
  each pin keeps its pull from power-on; the probe set the same function
  with the pulls untouched, and UART0 carried the controller's answers
  at once.
* **UART0 is held, undriven.** The five PL011s share one register page
  and one interrupt line, 153, so they are one unit, which the system
  domain holds for UART3, the host link
  ([design-platforms.md](design-platforms.md#raspberry-pi-4-model-b),
  `config/platforms/raspi4b.json`, unit `hostlink-uart`). Each PL011's
  clock is 48 MHz in the record, so 115200 baud divides as the host
  link's does.
* **Power.** The controller's enable line is pin 0 of the firmware's
  GPIO expander, which the VideoCore drives on a mailbox request: the
  firmware's device tree names it in the `shutdown-gpios` property of
  UART0's `bluetooth` child, with flags 0, and the expander's
  `gpio-line-names` call it `BT_ON` (probe B-P2,
  [research-bluetooth-pi4.md](research-bluetooth-pi4.md#b-p2-the-controllers-power)).
  FreeBSD's expander driver numbers the expander's eight pins from 128
  (`raspberrypi_gpio.c:50-51`) and sets one with the property tag
  `0x00038041`, whose request is the pin and its state
  (`bcm2835_firmware.h:144`, `:161-168`), so the request names pin 128.
  The line is active high: state 1 powers the controller and state 0
  turns it off. 300 ms off and 500 ms on bring the controller back at
  115200 baud, answering `HCI_Reset` 1 ms after the on time, and it sends
  nothing between power-on and that command. The firmware leaves the
  controller powered, so the first reset of a boot turns off a running
  controller. The firmware leaves the set tag's response word 0, as
  FreeBSD records, and writes its first value word, the pin word, 0 on
  every set, which is what FreeBSD takes as the set's success
  (`raspberrypi_gpio.c:253-255`; probe B-P2, run 1, whose every set
  reads response word 0 and pin word 0); it answers the get tag `0x00030041`
  normally, its state word reading as the level set; erXos sends only
  the set tag
  ([The power line](#the-power-line)).
* **The controller reads the host's RTS as it powers up.** Powered up
  with UART0's RTS, its own CTS, deasserted, the controller's ROM answers
  every standard command tried and advertises; powered up with RTS
  asserted, it is in a download mode that answers only `HCI_Reset` and
  the vendor patch commands, and only when `HCI_Reset` comes first
  (probe B-P3, runs 1 to 4). Infineon's firmware download guide describes
  the same choice for its controllers: the boot code reads the chip's
  CTS when reset is released, LOW giving download mode and HIGH "a mode
  ready to accept all HCI commands" (AIROC HCI firmware download, 3.1 to
  3.3). So every power-up holds RTS deasserted until the on time has
  passed ([A reset](#a-reset)).
* **The ROM begins the stages without a patch.** In the mode ready for
  every command the controller's ROM reports HCI version 7, LMP version
  7, manufacturer `0x000f` and LMP subversion `0x6119`, advertises, and
  accepts a connection as a peripheral (probes B-P3 and B-P4,
  [research-bluetooth-pi4.md](research-bluetooth-pi4.md#b-p4-advertising-on-the-rom-firmware)):
  in run 5 a Mac connected, the controller reported LE Connection
  Complete with status 0 and the peripheral role, and the Mac's ATT
  Exchange MTU Request, client MTU 185, reached the host on CID
  `0x0004`. That is what was seen: advertising, a connection and one
  incoming ATT PDU. Whether the ROM serves the rest of GATT, the serial
  service and pairing is read by the board's checklist
  ([On the board](#on-the-board)). Hosts that
  drive a CYW43xxx load a patch into the controller's RAM before use:
  NetBSD's `btattach` sends the vendor command `0xFC2E` (download
  minidriver), replays the `.hcd` file as HCI commands of the form
  `opcode(2, little-endian) length(1) payload`, each awaiting its Command
  Complete, sleeps, and resets (`init_bcm43xx.c:105-141`); Zephyr's
  Infineon driver does the same and stops at any record but `0xFC4C`
  (Write RAM) and `0xFC4E` (Launch RAM), though only after sending it
  (`hci_uart_infineon.c:141-191`). erXos does the same where a board's
  manifest names a patch, and the Pi 4's manifests name
  `BCM4345C0.hcd`, which the bring-up loads in the mode every reset
  boots ([The bring-up](#the-bring-up), step 4;
  [Decisions](#decisions), 4).
* **QEMU has no Bluetooth.** QEMU removed its Bluetooth emulation in 5.0
  "without replacement" (QEMU's 5.0 change log), and QEMU `virt`'s two
  PL011s are the console and the host link (`virt.rst:36`, `:55-62`). The
  integration tests run on QEMU `virt`, where the Bluetooth controller's
  line is a virtio-console port that QEMU joins through a socket to a
  virtual controller of Google's Bumble, which speaks H4 over a TCP socket
  ([Verification](#verification)).

### Sources

Every source was read at a pinned version, fetched over HTTPS into a
directory outside the tree; none under the GPL or the LGPL was read,
except `bluez-firmware`'s `debian/copyright`, license records that hold
no code. The Bluetooth SIG's specifications are their HTML editions,
the Core Specification at
`https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core_v6.3/out/en/index-en.html`.

| Source | Version | File | SHA-256 |
| --- | --- | --- | --- |
| Core Specification 6.3 | 6.3 | index | `96b569247cc6999f35463c6483efb3392babe9d240c0d22ab20a9c870b5310e6` |
| | | Vol 4 Part A, UART transport | `f5fc6f3977bf3d7f2a86422b38c74590c071b2ec693b9349ce1092616871621b` |
| | | Vol 4 Part E, HCI | `76eb9e21a158ac3a2340087568437b0b91408b333ab135c7a13f9b5bdcc57ed2` |
| | | Vol 1 Part F, Controller Error Codes | `94a09e8511b332a3ed584d8495f46afac40d8fc53e350369ecfaaae713b5dd50` |
| | | Vol 3 Part A, L2CAP | `9fc72a9efd4229c3f800ac862808bba7b33d6a95679cfbd2acda5b3650069905` |
| | | Vol 3 Part F, ATT | `272a2472b71b54503d44a16286b9e399a323774d8b7b8246283a7c49e96d0638` |
| | | Vol 3 Part G, GATT | `25539e2ca6f127cf98bb34baae0c2cb774549ccb94d54f331c3c3ef4efa02add` |
| | | Vol 3 Part H, SMP | `16d561aab6cb6a219a55963fdb7acd68bfcac69eacf7387ae0b7366f180a4974` |
| | | Vol 3 Part C, GAP | `e095f6af2a746e898c36ed63ec9655fdf803d747daa4b6b68d21624acde835bf` |
| | | Vol 3 Part H Figure 2.4, Passkey Entry, its image `img-424860bacdb6b4a15c3d3f1a37a820d6.png` | `d6540d5fbbf99dbe76bcac968f2a375c9bd19ca06baeb1047b90aa36a709fad8` |
| | | Vol 6 Part B, Link Layer | `a983ac32050c6753dcfe7c2ecc1a13685931dbd45788e302c0b30ea5025350ed` |
| HID over GATT Profile | 1.1 | index | `b763f6511244e97f2fc1d9387f0e999c6bbbc82c8d58e92b66f1eb025972d725` |
| HID Service | 1.0 | index | `b114fb6930bb11a99bc8b6be72593e185abbbe4827a6ec18851ef2664d5f79a3` |
| NetBSD | trunk `5cebe14c1559` | `usr.sbin/btattach/init_bcm43xx.c` | `2c25439d61fbfd410f9cd8216152a7f8bc4dd9f7dbb974b58dc351d4d9f46f53` |
| | | `usr.sbin/btattach/btattach.c` | `58c3d467335cfb0e2791ef185ca232326f9289e570df887c1387c77df3e92b74` |
| Zephyr | main `7cd4b562b30a` | `drivers/bluetooth/hci/hci_uart_infineon.c` | `07aa15b3b1db206875ab3df72c739174d83e328ed9b59fc65cacd16917b8a288` |
| | | `subsys/bluetooth/controller/ll_sw/ull_conn.c` | `d1924c47dc5ce20aba6625c31c226874f75b055d953313febe6f6c39e6feb620` |
| | | `subsys/bluetooth/controller/ll_sw/ull_llcp.c` | `ecae74df5b3c4baa1e3e8d396a1a768dba3784d952b462b5b9de02bf233a9fa1` |
| Zephyr | `v4.2.0` | `drivers/bluetooth/hci/Kconfig.infineon` | `faaf674fd582dc4925cf873200b1f01bb6e24bac6c18511ac67e16d1e1310f90` |
| FreeBSD | releng/15.1 `95719d8a895b` | `sys/arm/broadcom/bcm2835/raspberrypi_gpio.c` | `ad34506dd6f69144bc4bfb3bfb00fb87b6c327ad5fe30ae03ee80437e3a79224` |
| | | `sys/arm/broadcom/bcm2835/bcm2835_firmware.h` | `9dfeb72a9a56556531afab024d80d45baaba40bc07351b970f651325b3d339a7` |
| | | `usr.sbin/bluetooth/hcsecd/hcsecd.h` | `fcb787bdad0ea5cde10d6fd3d6a058414686a1d783d34aa324b148c26de0e849` |
| RPi-Distro bluez-firmware | `cdf61dc691a49ff01a124752bd04194907f0f9cd`, release 1.2-13+rpt2 | `debian/firmware/broadcom/BCM4345C0.hcd`, git blob `007611e37b40` | `51c45e77ddad91a19e96dc8fb75295b2087c279940df2634b23baf71b6dea42c` |
| | | `debian/firmware/broadcom/LICENSE.cypress`, a saved web page of linux-firmware blob `070ef66f4342` | `a92f031f19089fa63bd24ac4c5298ca1356670321b39c67024a961ee3285fff7` |
| | | `debian/copyright` | `5f6acad870790f7e23150a30cab85c643f926266bf16e6a63acbde4257b957d4` |
| linux-firmware | `a1ebb5ad7eae3caca60b8b3db5792cf43339ba58`, from `git.kernel.org` | `LICENSES/LICENCE.cypress`, git blob `070ef66f43421ab8913299953926bfdd8c7b7a91` | `ae0db6cc4db33941148df0f67de53e76a77b1b5a46b3165edb7040aa2750015f` |
| Raspberry Pi documentation | `c6a64966af13` | `computers/configuration/interfaces.adoc` | `20c0c5f8dcf2ba501ec7888028aa576be2c965f9b06dd04022e3c9d187b33cef` |
| | | `config_txt-gpio.adoc` | `4ad5c0286da3f97f4eb0031af2377c11bd89d78c81f92c3c022187b942b454c0` |
| Infineon, AIROC HCI firmware download user guide | 002-32056 Rev. *B | `infineon.github.io/btsdk-docs/BT-SDK/AIROC-HCI-Firmware-Download.pdf`, fetched 2026-11-22 | `a9c593bdd184c673eeb0df2b76a70cd86cfed6d7f1e9fbbd001f4f38254b8e60` |
| BCM2711 ARM Peripherals | unversioned | the PDF | `d6e16ea089a1716e80621f99a26e130a2379f0a81d945dc22e4f80dc49dcdc78` |
| PrimeCell UART (PL011) Technical Reference Manual | ARM DDI 0183G, r1p5 | the PDF, from `documentation-service.arm.com` | `9cfe1a296ebe7accd905fb569e4c545ed9ca01d8341603568017319abe7e51e7` |
| QEMU | wiki, read 2026-11-14 | `wiki.qemu.org/ChangeLog/5.0` | `210bfe5e852d8395bfd937cf312ac62d936ee8948d6c310f19110f161843ca00` |
| QEMU | `v11.1.3` | `docs/system/arm/virt.rst` | `9fbcc9fc3040ef695e3058cd4bab05e10f6282ab7ba0846a93ee9f524933e3e1` |
| Apache NimBLE | master `648fc0213fb7` | `nimble/host/services/bleuart/src/bleuart.c` | `2a51bad8f39685887b10f2301e023baa2af9200685d91528ae330bef78a21ed1` |
| | | `nimble/controller/src/ble_ll_conn_hci.c` | `ae5f3a5e3cfb29d019ddb64c4b799e84bc833c9c6a87df0f75de848c7c465fd4` |
| | | `nimble/controller/src/ble_ll_conn.c` | `60b6a4d69539c1ebaeae9f8e863b2e626a59786f020cb7cd655338803ce8f222` |
| | | `nimble/controller/src/ble_ll_ctrl.c` | `dafdde45dd4f497c6496edd736bcb5b7bccbd518b0cb67f26c16d89fb9e654a4` |
| | | `nimble/controller/include/controller/ble_ll_ctrl.h` | `05670d740e370b6e9e2b8dd4d2c4b83cd99d3c124d8479f636ae9f4dd5d69320` |
| | | `nimble/host/src/ble_sm_sc.c` | `50b53e8e91be40ec84f75b37c9b8fd4924e55beb64c86e5a25f34bf006ceb8a7` |
| | | `nimble/host/src/ble_sm.c` | `b83bd3014e5afa23f24cd51cd082e2e2dcfba9a605ea3505cf92f4735ac41a47` |
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
| | | `bumble/hci.py` | `6eacd9bd72df40da6a5b79e9e7130e8c20434d01e6d379b150808b3de8c0e865` |
| | | `bumble/transport/common.py` | `c62ac850542cf9ef8668ebbe801e3a5dc369a50464c1faba875fb404935b409d` |
| | | `bumble/smp.py` | `d785a52fba8af900bb8da8a13129c92ef294286ec51bfcf084e9d50801d9440e` |
| Virtio 1.2, csd01 | 1.2 csd01 | `https://docs.oasis-open.org/virtio/virtio/v1.2/csd01/virtio-v1.2-csd01.html`, section 5.3 | `e18d68ee81b03bb9d8fb493356704fa77e3a9eac1c10f79111940cbd482f7bc1` |

The Core Specification Supplement, which defines the advertising data
types and the Flags structure, was not fetched. The values this document
uses from it come from Bumble's `core.py:1594-1622` and are marked
unverified until the supplement is read.

QEMU's virtio console is QEMU's, whose source is under the GPL and was
not read, so the line on QEMU `virt` relies on three facts that only
boots settle. The first is settled: QEMU joins port 0 to its socket when
the driver negotiates no `VIRTIO_CONSOLE_F_MULTIPORT` and sends no
port-open message. The Bluetooth suite's boot (QEMU 11.1.3, HVF, one
guest CPU, an Apple M3 Max host) ran the bring-up from `HCI_Reset`
through advertising against Bumble's controller over that port. Two are
unverified: whether QEMU holds or drops bytes that arrive while no
receive buffer is posted, and whether a device reset drops what QEMU's
character device holds. The bring-up does not tell them apart, since
Bumble's controller writes only answers, and the line drops what it
buffered at every `reset`; a stand-in controller that writes before the
driver's start and across a `reset` settles them.

## Requirements

Each names its consumer.

| | Requirement | Consumer | Stage |
| --- | --- | --- | --- |
| B1 | A phone's scanner shows the machine's name and the UUIDs of the services it advertises | the vendor's phone app, which finds its device by service UUID | 1 |
| B2 | A phone discovers, reads and writes the characteristics apps declare, and subscribes to their notifications and indications | the vendor's phone app | 2 |
| B3 | An app declares its services as data; Erlang processes answer writes, set values and send notifications | the vendor's app on erXos | 2 |
| B4 | A byte stream between a phone and an app, which phone terminal apps for Nordic's UART service open | serial tools; the console | 3 |
| B5 | A characteristic may require an encrypted link, or an authenticated one, reached by LE Secure Connections pairing and bonding | Wi-Fi provisioning | 4 |
| B6 | A pairing is made only in a window someone with the right opened, and no bond is replaced by pairing | every characteristic that requires a bond | 4 |
| B7 | Every byte from the controller and every PDU from a peer is parsed by a bounded parser with a fuzz target; a malformed one ends at most its link, or restarts the controller | the machine's integrity against anyone in radio range | all |
| B8 | The trusted base parses no radio bytes | the system domain's integrity ([design.md](design.md#decisions)) | 1 |
| B9 | Every bring-up starts from one state, whatever the last one left | restarts of the controller, the Bluetooth domain and the line | 1 |
| B10 | A connection's name never names a later connection | apps that notify after a phone left | 2 |
| B11 | Someone can open a pairing window, read the bonds and forget one, on every image that can pair | the administrator of a development board; a device's own app, which pairs a phone when its button is pressed or from its settings screen | 4 |
| B12 | A handler tells bonded phones apart by a name that a link carries only once it is encrypted with that bond's key, and never by an address | an app that gives each phone its own rights: a lock's owner and its guests, the users of a kiosk or a head unit | 4 |
| B13 | A handled service puts a few octets of its own into the advertising, in room its declaration reserves | a vendor's phone app that tells its devices, or their state, apart before it connects; commissioning schemes whose phone side looks for service data | later |
| B14 | An app hears the advertisements of the services it declares, connects only to devices that advertise one of them, and reads, writes and subscribes to those services on those devices; it hears no other advertisement | a gateway that collects from Bluetooth sensors; the accessories of a kiosk or a controller that are not HID | later |

What no consumer asks for is not designed, and
[What waits for a consumer](#what-waits-for-a-consumer) lists it with
what each would need.

## The interface

This section is the map for someone building a device on erXos: what
they write, where it goes, and which section defines it. It rests on a
survey of how other systems let a program use Bluetooth Low Energy
([research-ble-apis.md](research-ble-apis.md)), whose interfaces fall
into four shapes: a static attribute table with callbacks (Zephyr,
Apache NimBLE, ESP-IDF); objects a program builds at run time and
publishes to a system service that owns pairing (Apple's Core Bluetooth,
Android); objects on a message bus with a registered pairing agent
(BlueZ); and central access scoped to named services and one chosen
device (Web Bluetooth, Android's Companion Device Manager). erXos takes
one idea from each and no interface whole:

* the **static table** of the embedded stacks, because a device's
  services are few, fixed and checkable before anything runs
  ([One table, one gate](#one-table-one-gate));
* **pairing and the bond list owned by the system**, as on the phone
  systems, so that no app writes pairing code and none can get it wrong;
* the **pairing agent as whoever opened one thing**, BlueZ's agent
  reduced to the opener of a file
  ([The pairing window](#the-pairing-window));
* **authority as a list of named services**, Web Bluetooth's rule that a
  page uses only the services it named, made a manifest grant that the
  build checks ([The `ble` facet](#the-ble-facet),
  [The central role](#the-central-role)).

**Four places, each with one home.** The homes are those of
[design.md](design.md#decisions): observed state at `/proc`, a thing
someone commands as a file tree its owner serves, a live conversation as
a declared protocol.

| A device's maker | Writes | Home | Defined in |
| --- | --- | --- | --- |
| says what a phone sees, what each access requires of the link, and what the machine advertises for the service | a declaration, `abi/gatt/NAME.txt`, which the board's manifest selects | configuration, checked when the image is built | [Declarations](#declarations-abigatt), [Advertising](#advertising) |
| answers the phone | an Erlang process, the service's handler, over the `ble` facet: an `erx_gatt_service` callback module, or `erx_gatt_serial` for a byte stream; its package names the service in `gatt` | a declared protocol | [The `ble` facet](#the-ble-facet), [The client](#the-client) |
| pairs phones, lists the bonds and forgets them | reads and writes of the control tree's `pair`, `bonds` and `ctl`, by a person at a shell (`btpair`, `cat`, `echo`) or by the one app the manifest gives the tree | a file tree, found at `/svc/bluetooth` | [The pairing window](#the-pairing-window), [Bonds and the store](#bonds-and-the-store) |
| watches the stack | nothing: the Bluetooth domain reports it | `/proc/bt` | [Inspection](#inspection) |

**What each kind of device uses.**

| Device | Serves | Who opens the pairing window | Beyond stage 4 |
| --- | --- | --- | --- |
| a consumer gadget: a lock, a light, a tracker | its own declared services, at `encrypted` or `authenticated`; it tells its owner's phone from a guest's by `bond` | its app, when its button is pressed: `nodisplay` with no screen, `display` with one | the advertised payload (B13) |
| an industrial sensor or controller | its own services and the standard ones, each a plain declaration | a technician's session over SSH or the console, at commissioning: `btpair display` | the central role, to read other sensors (B14) |
| a headless box set up from a phone | a setup service | its app, at a button or for a time after power-on: `nodisplay`, so `encrypted` at most | an out-of-band pairing method, for `authenticated` ([Decisions](#decisions), 3) |
| a kiosk | services for phones that walk up to it | its own app, which shows the passkey on its screen and lists the bonds in its settings | the central role, for accessories; HID over GATT, for keyboards and scanners that type |
| a head unit | services for the driver's and the passengers' phones | as the kiosk | classic Bluetooth, which hands-free and audio need and no stage here designs |

**A restart costs a reattach.** The attributes are configuration and
not a handler's objects, so a handler that crashes takes no service
with it: the service serves its declared values, its supervisor starts
the handler again, and the handler attaches and sets its values
([A service belongs to its handler](#a-service-belongs-to-its-handler)).
An app keeps nothing across a restart to have its services back, and the
system keeps nothing on its behalf.

**Erlang only.** The `ble` facet's client is Erlang code in the app's
session. A native program has no route to it: a program holds no facet
([design-programs.md](design-programs.md#facets)), and none is designed
here. An app whose logic is native runs it as a helper of its Erlang
application, which holds the service
([What waits for a consumer](#what-waits-for-a-consumer)).

## The construction

### One table, one gate

The attribute table is a pure function of configuration:
`erx_gatt_db:build(Services)` takes the declarations of the services the
manifest selects, in the order of their names, and returns the table:
every attribute's handle, type, value or value source, permissions, and
each characteristic's declaration, value and descriptors. The Bluetooth
domain builds it once at its start; nothing adds, moves or removes an
attribute while the domain lives. The table's **hash**, SHA-256 over every
attribute's handle and type and every declaration's value, in table
order (`erx_bytes:sha256/1`), names it.

Every access passes one pure function, the **gate**:

```erlang
-spec erx_gatt_gate:check(level(), link_security()) -> ok | {error, att_error()}.
-type level() :: open | encrypted | authenticated | bonded. % GAP 10.2.1 levels 1, 2 and 4, and bonded
-type link_security() :: #{key := none | encrypted | authenticated, encrypted := boolean(),
                           bonded := boolean()}.
```

It is GAP's Table 10.2 (10.3.1) for the three levels erXos uses, whose
columns are the key the server has for the peer, not whether that key is
stored: an `open` access is allowed; an `encrypted` or `authenticated`
access on a link with no key answers Insufficient Authentication
(`0x05`); on a link with a key but not yet encrypted, Insufficient
Encryption (`0x0F`); an `authenticated` access on a link encrypted with
an unauthenticated key, Insufficient Authentication. `bonded` is erXos's
own level, level 4 on a link whose key is a kept bond's, the fact
`bonded` of the link's security: it is refused as `authenticated` is,
and on a link with an authenticated key that is no kept bond's, a
pairing link before the store has kept its bond, Insufficient
Authentication, so no access at `bonded` reaches a handler on a link
whose phone is not yet a bond. Since every key is 16 octets and only
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

### A bond's name is made with its key

A handler that gives each phone its own rights needs a name for a
bonded phone that stays across its connections. No address is one. A
phone that uses privacy connects from a resolvable private address that
changes. An identity address is what a peer says it is, and anyone who
heard it can repeat it. And a name computed from the identity would
pass to whoever pairs under that identity after a `forget`, since a
pairing's identity is a claim until a reconnection proves it with the
pairing's key (SMP 2.4.3.2).

So each bond has an **id**, 128 random bits, written everywhere as 32
lower-case hexadecimal digits. The store draws it from
`crypto:strong_rand_bytes/1` in the step that keeps the bond, draws
again if a kept bond has it, and stores it with the bond
([Bonds and the store](#bonds-and-the-store)). From that:

* **Only the key brings it.** A handler hears a bond's id only in
  `connected`, for a link encrypted with that kept bond's key, by the
  transition that makes the link `bonded` for the gate
  ([One table, one gate](#one-table-one-gate)). A peer that copied a
  bonded phone's address has a link with no bond, and a peer that knows
  an id gains nothing by it: the id is a name the stack attaches to an
  authenticated link, never something a peer presents.
* **It dies with its bond.** `forget` ends the bond and its id. The
  same phone, paired again, is another bond with another id, so what an
  app recorded under the old one passes to nobody.
* **It names no later bond, with high probability.** The id is drawn,
  not counted, and owes nothing to the phone's address or to how many
  bonds the store has kept. An app's own records can outlive the store:
  a `forget all` over a state that did not decode, or a data partition
  made again, starts the store empty, and a counter that began again at
  1 would hand a stranger's phone the id an app recorded for its
  owner's. The store keeps no record of ids it no longer holds, so it
  cannot rule a repeat out: two given bonds share an id with a
  probability of 2^-128, and among all the bonds a machine ever makes,
  n of them, some two share one with a probability below n^2 / 2^129.
  A repeat among the bonds the store holds is ruled out, by drawing
  again.

**What the id is not.** It is not a secret and not a credential. Every
handler of every service a link reaches hears the id of the link's
bond, whether or not the phone used that handler's service, so two
apps that compare notes recognize the same phone, and an app that logs
ids learns when each bonded phone comes and goes. What the id promises
is narrower: a handler that is told an id is talking over a link
encrypted with that bond's key. An app that must not learn which bonded
phones come near is served by no grant of this design
([Decisions](#decisions), 13).

**What `forget` promises.** A confirmed `forget` takes the bond, its
key and its id off the medium, and the domain's next start does not
bring them back ([Bonds and the store](#bonds-and-the-store)). It does
not survive a rollback of the medium: a vault medium rolled back to an
older machine file brings back the older blob, with every bond and id
it held, as it brings back every other machine secret
([design-system.md](design-system.md#state-slots)), and a development
data partition restored from an older copy brings back the older
directory.

A handler's `connected` carries no address at all
([The `ble` facet](#the-ble-facet)): an address in the event would
invite an app to key on it. The control tree names a bond by the same
id, in `bonds`, in a window's `bonded` line and in `forget`, so a bond
has one name wherever it is named.

### A service belongs to its handler

A served service has at most one handler, the process that attached to
it ([The `ble` facet](#the-ble-facet)), and that process holds it until
its end: no operation detaches, and the registry's monitor of the
handler is the one way an attachment ends. A pid never names two
processes within a boot
([design-domains.md](design-domains.md#invariants), D1), so a service's
handler, or `none`, names its **owner**, and an owner, once gone, never
comes back. Everything about a service that changes while the domain
lives belongs to its owner, and every path into that state compares
against the owner:

* **What the owner does.** The registry takes `set`, `notify` and
  `indicate` of a service only from its handler, the caller its facet
  wrote into the forwarded request, and `reply` only for a write it
  handed that handler. A request that reaches the registry
  after the end of its caller has detached it, however long it was on
  its way from a facet that has since ended, is refused `{error,
  not_attached}`. That is the check
  [design-domains.md](design-domains.md#facets) asks of a service that
  must take back what a revoked grant started: a check on each use
  against something that ends with the grant, here the handler, which
  ends with the grantee's session. An `attach` forwarded before its
  caller's end and taken after it makes the ended process the owner
  only until the monitor's `'DOWN'`, which a monitor of an ended process
  gives at once; meanwhile only writes reach it, and the links'
  deadline answers them.
* **What the phone sends the owner.** Each link keeps, for each served
  service, the handler the registry last told it of. A write carries
  the handler under which its first byte reached the link: a Write
  Request or Write Command its own arrival's, a prepared write its first
  Prepare Write's. The registry hands a write to the service's handler
  only when that handler is the one the write carries, and otherwise
  answers it Unlikely Error, as a service with no handler is answered.
  So a phone's bytes sent while one process owned a service, a Prepare
  Write queue, write commands queued behind a request or a write on its
  way to the registry as the owner changes, reach that owner or nobody.
* **What the owner left.** At each change of a service's owner, an
  `attach` or a handler's end, the registry sends every link `{handler,
  Service, Handler | none}`. The link then serves the service's
  declared initial values and drops the service's notifications still
  waiting for credits. The registry drops, at a handler's end, the
  values that handler set, so a link that joins later is answered the
  declared values too. A new owner starts from the declarations, and a
  service no one owns serves only them.

What a phone can see across a change is bounded by one message inside
the domain: until its link takes the change, the link serves the
previous owner's values and sends the notifications it had already
queued; nothing the phone sends meanwhile reaches the next owner. A
notification already handed to the controller, and an indication
already sent, complete as they would have.

The construction adds one field to a link's write and one message from
the registry to its links; the handler's pid is already in every
request and the registry already monitors it. Two other ways were
rejected. Draining the old owner's effects before its services are free
would make a removal or an update wait on the Bluetooth domain, a
domain the package process otherwise never waits on, since it frees the
services at its commit. Ending the links that touched the service would need the
registry to know what each link holds, which only the link knows, and
would cut a phone's other services, the console's among them, at every
restart of an app.

### One owner, one step

Each kind of process owns its state and decides by a pure step that
returns the actions it performs, as the network stack's and the USB
stack's owners do
([design-network-stack.md](design-network-stack.md#one-owner-one-step)):

| Owner | Its state | Its pure core | Effects |
| --- | --- | --- | --- |
| the **controller process**, `erx_bt_hci` | the bring-up, the command slot, ACL credits, the map from handles to links, advertising | `erx_bt_hci_core` | items for its writer, which writes `data` and `ctl`; acknowledgements to its reader; starting and ending link processes ([The controller process's effects](#the-controller-processs-effects)) |
| a **link process**, `erx_bt_link`, one per connection | L2CAP reassembly, the ATT bearer (MTU, the request in progress, queued commands, the prepared write, the indication in flight), each service's handler as the registry last told it, the notifications waiting for credits, subscriptions, its one key and whether it is encrypted, the pairing in progress | `erx_bt_link_core`, over `erx_gatt_server`, `erx_gatt_gate` and `erx_smp_core` | messages to the controller process, the registry, the window and the store, and its two calls at its start ([The link's messages](#the-links-messages)) |
| the **registry**, `erx_gatt_srv` | the table, each service's handler and the values it set, the live `Conn` map, the writes handed to handlers | `erx_gatt_registry` | a monitor of each link and each handler, events to handlers, requests to links |
| the **store**, `erx_bt_store` | the identity address, from stage 1; the bonds, from stage 4 | `erx_bt_state` (stage 4) | reads and writes through the store's backend; a monitor of each link holding a bond, and `forgotten` to it (stage 4) |
| the **window**, in `erx_bt_fs` (stage 4) | whether a pairing window is open, its mode and its opener's fid; the pairing wait | `erx_bt_window` | lines on the opener's `pair` file; a monitor of each link that owes it a pairing's outcome |

Every timer is a deadline in its owner's state, and `next_deadline/1`
answers the earliest ([design.md](design.md#drivers-and-dma), "Deadlines in state"). No caller strings operations together:
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
| a peer with a bonded phone's address changes that bond's kept subscriptions or table hash | a link is its bond's only from its encryption with the bond's key, and only the bond's own link writes them |
| a window closed as its pairing completes leaves a kept bond counted failed, or a failure kept | the link's one step that hands the bond to the store decides which side the close fell on, and the store's answer is the outcome |
| an app's crash leaves dangling attributes | attributes are configuration; the handler detaches, and its service serves its declarations |
| a removed or restarted app's late `set` or notification, or a phone's bytes buffered for it, reaches the service's next owner | a service's state is its handler's, and every effect and every write is compared with the handler it was made under ([A service belongs to its handler](#a-service-belongs-to-its-handler)) |
| an app keys a phone's rights by an address, which a peer copies | a handler hears no address; a bond's id comes only with the bond's key ([A bond's name is made with its key](#a-bonds-name-is-made-with-its-key)) |
| a phone paired after a `forget`, or after the store was lost, inherits what an app recorded for an earlier bond | a bond's id is drawn with the bond and ends with it |
| a handler's advertised octets overflow the advertising data, or stay after the handler | their room is reserved by the declaration and checked when the image is built, and they are their handler's, as its values are ([Advertising](#advertising)) |
| a compromised Bluetooth domain serves a link as `ctl`, and an administrator's `echo forget all > /svc/bluetooth/ctl` empties one of the administrator's own files | no link in the control tree is followed ([The Bluetooth domain](#the-bluetooth-domain)) |

## Stages

The work is ordered by the first consumer, a phone app talking to an
erXos device, in four stages whose sections follow: the controller and
advertising, the GATT server, the serial service, and pairing and
bonding. Each ends in a demo against a phone and a test against Bumble
([On QEMU against Bumble](#on-qemu-against-bumble)); the advertised
payload ([Advertising](#advertising)), Wi-Fi provisioning, the central
role with HID over GATT and with apps as centrals, and classic Bluetooth
come after them ([Later stages](#later-stages)). [plan.md](plan.md#track-b-bluetooth)
schedules the work.

Stages 1 to 3 need no Security Manager: until stage 4 the link answers
every SMP PDU with Pairing Failed, Pairing Not Supported (`0x05`), and the
gate refuses every `encrypted` and `authenticated` access with
Insufficient Authentication, which is the right answer for a server with
no key for the peer (GAP 10.3.1). The console, `bleuart`, is stage 3's: its
service's accesses are `open` ([The console](#the-console)).

## Domains and authority

### The Bluetooth domain

The Bluetooth domain is a configured `service` domain of the manifest,
named `bt` (node `bt@erxos`), of the principal that owns the machine's
services, on the BeamAsm image, whose OpenSSL its Security Manager calls
through OTP's `crypto` ([Stage 4](#stage-4-pairing-and-bonding)). It holds
no device. Its release script, `bt`, ships `kernel`, `stdlib`, `erx`, `erx_files`,
`crypto` and `erx_bt`, and starts `crypto`, which other releases only load, so that
`erx_bt` starts before init's ready report: a release script may start an application
the release otherwise only loads, declared per script
([design-runtime.md](design-runtime.md#everything-else)). Its manifest row holds:

* one grant of the `line` interface, which the system domain's line
  service serves as its service named `line`, its parameters naming the controller's UART
  ([The controller's line](#the-controllers-line));
* its arguments: the advertised name (the machine's host name by
  default), the appearance, the connection limit (1 by default, at most
  `bt_connections_max`), the patch file and the manufacturer it applies
  to where the board's manifest names one (on the Pi 4,
  `-erx_bt patch 'BCM4345C0.hcd' -erx_bt patch_manufacturer 15`, the
  manufacturer `0x000f` its ROM reports, [The bring-up](#the-bring-up)), and the services it serves, which the
  build derives from the manifest's `ble` rows
  ([Declarations](#declarations-abigatt)). They are application keys of `erx_bt` in OTP's
  own form, `-erx_bt Key Value` among the row's `init` arguments, which
  `application:get_env/2` reads, as the network domain's row sets
  `-erx_net interfaces` (`config/manifest/qemu-virt-development.txt`):
  `name`, `appearance`, `connections`, `patch`, a file of `erx_bt`'s
  `priv` directory, `patch_manufacturer` and `services`. The host name is
  the host part of the domain's node name up to its first dot, so
  `bt@pi.example.com` advertises `pi`
  ([design-system.md](design-system.md#identifiers)). The release's boot
  script starts `erx_bt`, and the `crypto` it requires, before init's
  ready report, and `erx_bt` then runs only the domain's two mints, of
  `ble` ([The `ble` facet](#the-ble-facet)) and of `bluetooth`, the
  control tree (below), since a mint named after the ready report is
  refused ([design-system.md](design-system.md#facets-a-configured-domain-serves));
  the row's `-eval`,
  `ok=erx_bt_top:start_stack()`, starts the rest, `erx_bt_sup`, once
  init holds the ready answer's facets, the `line` grant among them, as
  the PCIe domain starts its enumerator
  ([design-pcie.md](design-pcie.md#processes));
* at stage 4, the store's grant: in a release build the vault's state
  facet `{state, "bt"}` ([design-system.md](design-system.md#state-slots)),
  and in a development build a files service of its own that the storage
  domain roots at the data volume's `bt/` directory and grants to the
  Bluetooth domain alone, as it serves SSH's `ssh_state`
  ([design-ssh.md](design-ssh.md#host-keys));

It serves three things: the `ble` facet to apps, as the service `ble`
that the manifest declares beside the domain's row ([The `ble`
facet](#the-ble-facet)); its **control tree**, the service `bluetooth`,
with `pair`, `bonds` and `ctl` ([Stage 4](#stage-4-pairing-and-bonding));
and its state at `/proc/bt`, through the inspection schema
([Inspection](#inspection)).

**The control tree.** The manifest declares the service `bluetooth`
beside the domain's row, as it declares `ble`, and the domain mints its
grants with `erx_fs_mint`, the mint of every files service a configured
domain serves, as the storage domain mints `data`
([design-system.md](design-system.md#facets-a-configured-domain-serves)).
The tree's server, the window process `erx_bt_fs`, starts with the
rest of the stack after the ready report, so the mint uses
`erx_fs_mint`'s deferred mount, as the storage domain's mint waits for
its volume ([design-storage.md](design-storage.md#the-system-tree)):
`erx_bt_top` starts the mint from the boot script and registers it as
`erx_bt_tree_mint`; the mint names itself the service's mint and
acknowledges its start, both before the ready report, and only then
runs its mount, `erx_bt_fs:mounted/0`, which waits for the message
`{erx_bt_fs, Pid}` that `erx_bt_fs` sends the registered mint as it
starts and answers `Pid`, the argument every grant of the tree serves
from. A mint request that arrives first waits in the mint's queue, as
it does in the storage domain's. The wait ends when the stack has
started, whose one wait is the store's first read, bounded by
`bt_store_timeout_ms`, 5 s, inside the domain service's 10 s deadline
for a mint ([design-system.md](design-system.md#facets-a-configured-domain-serves));
a grant whose mint misses that deadline fails and is logged, as any
mint's does, and the domain's next incarnation mints it again.
`erx_bt_fs` is a temporary, `significant` child of `erx_bt_sup`, as
the store and the registry are, so its end ends the domain, and with
it the mint and every grant of the tree; the domain service restarts
the domain, and the new incarnation mints every grant anew
([Concurrency](#concurrency)). No grant ever holds the pid of a window
process that has ended, and nothing re-binds one.
A grantee finds it at `/svc/bluetooth`, by the rule that every
service's control tree is at `/svc/NAME`, NAME being the service's
name and not its server's ([design-app-trees.md](design-app-trees.md));
a session whose template holds no grant of it has no `/svc/bluetooth`
([Decisions](#decisions), 11).

* **Its interface is `svc`, and no link in it is followed.** The
  manifest declares the service as it declares every service tree:

  ```text
  service bluetooth
    server @domain.bt
    interface svc
  ```

  This design declares no interface of its own. `svc` speaks 9P2000.L
  as `files` does, with one parameter, the grant's rights, `ro` or
  `rw`, and `rw` where a row states none, and its row says `links
  none` ([design-app-trees.md](design-app-trees.md)): the tree's server parses what strangers send,
  so a link in it is a stranger's, and the resolver follows none,
  answering `eacces` where it would
  ([design-files.md](design-files.md#resolving-a-path), "Symbolic
  links"). The mark comes with the facet's interface number, which the
  domain service sets from the manifest and no server's reply does, so
  it holds for every mount and bind of the tree. Without it a Bluetooth
  domain taken over from radio range could serve `ctl` as a link to
  `/etc/start.conf`, and the administrator's next `echo forget all >
  /svc/bluetooth/ctl` would empty that file: the takeover would reach,
  through the administrator's hand, files its row gives it no grant to.
  `svc` admits no `rx`, so nothing runs from the tree. The domain thus
  serves two services under two names: `ble`, of the interface `ble`,
  through which apps' handlers serve GATT services, and `bluetooth`, of
  the interface `svc`, through which an administrator pairs phones and
  forgets bonds. Holding one gives nothing of the other.
* **The right is the grant.** Whoever holds the tree `rw` is the
  machine's Bluetooth administrator: it opens pairing windows, sees
  each passkey, reads every bond's identity and forgets bonds; a holder
  of an `ro` grant reads `bonds` and nothing else, since `pair` opens
  only for reading and writing and `ctl` only for writing. The tree
  checks no name: there is no administrator flag beside the facet rows,
  as for `/svc/machine`
  ([design-system.md](design-system.md#a-sessions-request)).
* **Who is granted it.** Every development manifest that has a `bt` row
  grants it `rw` to root's session template, so an administrator at the
  console, over SSH or in the web client's terminal pairs with `btpair`
  ([The pairing window](#the-pairing-window)). A release manifest grants
  it to root's template, to any administrator's template its author
  lists, and to the app that is the device's pairing interface, by a
  facet row of a start row's template, as `bleuart` holds `ble`, which
  names its one holder. An `apps` row may offer it too, by naming
  `bluetooth` in its `services`, where an app's package says `needs
  bluetooth` ([design-packaging.md](design-packaging.md#the-apps-row)),
  and that naming is the board's explicit opt-in: no default and no
  derived row ever adds it ([Decisions](#decisions), 14). Such a
  row makes every admitted app that asks an administrator of all the
  machine's bonds, and a shared signer is no separation between those
  apps, so a board on which one app should administer Bluetooth grants
  the tree to that app's template by name instead. `bleuart` holds no grant of it: the console over
  Nordic's UART service requires no bond and opens no window
  ([The console](#the-console)).
* **The store's grant comes with it.** A manifest that grants the
  control tree also holds the `bt` row's store grant, above: without a
  store every window answers `eio`
  ([The pairing window](#the-pairing-window)), so the manifest check
  refuses a `bluetooth` grant in a manifest whose `bt` row has no
  store, which would be an image that offers pairing and can never
  pair.

It is a domain of its own, not a part of the devices domain: what it
parses comes from anyone in radio range, so it holds no device and no
grant that a radio peer should not reach through a parser defect, as the
network domain holds only its network device. The manifest check holds a
`bt` row to exactly the grants listed above, as it holds the SSH
domain's row to its grant, its login facet and its host key facet
([design-ssh.md](design-ssh.md#invariants), H3): it refuses a device, a
partition window, a second `line` grant, and any facet but the `line`
grant and the store's grant, and a release manifest refuses the
development store. The console, `bleuart`, runs in a session of its own
principal, a client of the `ble` facet ([The console](#the-console)).

### The controller's line

The controller is a sub-device of the system domain's PL011 unit, so it
reaches the Bluetooth domain through the home the unit rule gives:
a file tree its holder serves, with a `ctl` file for one-shot control
([design-shared-devices.md](design-shared-devices.md#the-unit-rule)). The
**line service**, `erx_line`, a service of the system release, serves
one **line tree** for each grant of the `line` interface, which
`abi/services/line.txt` declares with its files, `ctl`'s word and three
parameters, each with its checked consumer as every facet parameter has
([design-abi.md](design-abi.md#system-manifest-representation)):
`device`, the device-tree path of the line's device, a UART (role
`uart`) on a board and a virtio-console transport (role `serial`) on
QEMU `virt` ([The line on QEMU `virt`](#the-line-on-qemu-virt)); and,
for a UART alone, `rate`, 115200 on every board this design names, and
`flow`, `none` or `rts_cts`. A virtio port has neither: its queues are
its flow control. The grant names its device, not a transport or a
driver: the device's row says what the device is, and the row's role
and compatible string pick the record the root writes and the driver
that opens it. A line is thus configured where every grant is, in the
facet's row, and the manifest needs no field of its own for it. The
manifest check gives the unit of each `line` grant's device to the
system domain, as property 8 gives the console's and the host link's
([design-system.md](design-system.md#the-manifest)); requires `rate`
and `flow` for a `uart` device and refuses them for a `serial` one;
refuses a device of any other role; refuses
two grants that name one device, and a grant that names the console's
or the host link's; and refuses a placed `serial` device that no line
grant names, since the root gives itself, and writes a `given` record
for, every device of the `serial` kind row it is handed, so an
ungranted one would get unconfined DMA memory and a line record no
grant serves:

| File | Read | Write |
| --- | --- | --- |
| `data` | the bytes the controller sent, at least one and at most what is buffered, waiting while none is; `eio` once the line is broken | the bytes to send, in order, returning once the driver has taken all of them; `eio` while the line has no driver |
| `ctl` | `eacces` | `reset`, with or without its newline, at most 16 bytes: the steps of [A reset](#a-reset) below; answers once done, or `eio`, the line left broken with no driver, when a power notification failed or the driver did not start; any other write is `einval` |

`line.txt` is shaped as `windows.txt` is, an `erx_fs` grant of one tree
with typed parameters: `device` of kind `device`, an optional `rate`, a
`u64` held to 115200, and an optional `flow`, an `identifier` of `none`
or `rts_cts`, each `checked_by` the line's grant checker; the tree's name in an attach,
`line_tree`, `line`; its files, `line_file`, `data` and `ctl`; and
`line_rx_max` and `ctl`'s 16 bytes as limits. Every grantee carries
frames of at least `files_max_frame_min`, as a `files` grantee does, so
a read of `line_rx_max` answers in one frame. The line service is a
service of the system domain, so the domain service hands each grantee
its grant in the grantee's ready answer, before any of its applications
starts, and the grant ends with the grantee or with the tree behind it
([design-system.md](design-system.md#facets-a-configured-domain-serves),
"Facets of the system domain's services"). The grantee mounts it as
every `files` service of the system domain is mounted, at the place
`erx_ns` gives its facet name: `line` at `/dev/line`, read-write on the tree
`line`
([design-files.md](design-files.md#building-binding-and-mounting), "A
facet's mount"). `erx_bt`'s application start mounts its facets with
`erx_ns:mount_facets/1`, as a session's does, so the Bluetooth domain's
processes open `/dev/line/data` and `/dev/line/ctl`.

The line service parses no byte of `data`: it moves bytes between a
fid and its driver. Its one grammar of untrusted input is `ctl`'s, one
word, with a fuzz target. Its receive buffer holds at most
`line_rx_max`, 64 KiB, about five seconds of 115200 baud; a driver input
that would pass it marks the line **broken**: buffered bytes are dropped
and every read answers `eio` until the next `reset`. A loss of bytes is a
loss of synchronization, which H4 answers with a reset anyway (Part A,
section 4), so the line's one failure is the controller's restart. A
driver that does not start at the line's start, a driver that ends
outside a reset, as a broken queue ends one, and a reset that fails at
any step mark the line broken as well and leave it with no driver: the
line ends the driver it holds, if any, buffered bytes are dropped, every
`data` read and write answers `eio`, and the next `reset` tries the
driver again ([A reset](#a-reset), "A reset that fails"). So whatever a device does ends at most its line's driver, never
the line's process, and nothing it does restarts a supervisor whose end
would take the host link with it. The driver's start logs why it
failed, except for an empty transport, which has no device to report.

Every read and write of `data` that cannot finish at once, and every
`reset`, is a waiting request whose keeper is the line's process, the
one owner of its buffer and its driver
([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
"Waiting requests"): the tree's `read` and `write` answer `{wait, Line,
Request}` and return, and the line answers each when its bytes arrive,
its driver has taken them or its reset is done. So the reader's read
that waits for the controller never holds up the writer's command, on
one `data` file through one grant, and a clunk or the Bluetooth
domain's end settles a waiting read without taking bytes the next
reader should have. A `reset` begins when it arrives, unless another
runs, ahead of every `data` write: each write sent before it, the one
the driver holds and those still waiting, answers `eio`, as does each
read waiting, since no byte of the last bring-up survives a reset; a
read that arrives during one answers `eio`, and a write that arrives
during one waits at the line until the reset answers, then goes to the
new driver, or answers `eio` if the reset failed.

A request the line has begun is answered with what it did, flushed or
not ([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
"Waiting requests", rule 3): a `reset` is begun at its first step, since
stopping the driver already changes the line, and is answered when its
last step is done; a `data` write is begun once its bytes are handed to
the driver, and is answered with its count when the driver has taken
them. Each step of a reset waits on a timer of the line's or on a
process it monitors, so a reset ends; a data write may not
([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
"Waiting requests", rule 4):

* a `reset` waits for the old driver's end, then for two notifications
  of [The power line](#the-power-line), each at most 1 s at the device
  service's firmware worker once the worker's earlier requests, each at
  most 1 s, have run, for the off and on times, and for the holding
  driver's end; each fresh start of the driver programs its registers
  without waiting; a notification that fails or times out ends the
  reset as a failed one ([A reset](#a-reset), "A reset that fails");
* a `data` write waits for the driver, which may hold bytes for as long
  as a controller holds CTS off under `rts_cts` flow. Such a write ends
  at the line's next `reset`, whose first step ends the driver and
  answers the write `eio`, and the controller's side writes one at
  every restart: the controller group's, which a command left
  unanswered for 5 s forces ([Failure handling](#failure-handling)),
  and a restarted Bluetooth domain's bring-up, whose first step it is
  ([The bring-up](#the-bring-up)). So a write a controller holds delays
  its fid's clunk, and the end of a grant whose domain has ended, until
  that reset.

A read waiting for bytes, and a write waiting behind a
`reset`, have begun nothing, and a flush or a clunk answers them `eintr`
at once. The line keeps them in one `erx_fs_waits` set, at most the
grant's 64 requests in flight, each a read's count or a write's bytes
of at most 64 KiB, beside its receive buffer, and its process's heap
bound covers both.

#### A reset

A reset is a power cycle between two fresh starts of the driver: the
first holds the UART's RTS deasserted while the controller powers up, so
the controller boots in the mode that answers every command
([The hardware](#the-hardware)), and the second opens the grant's flow
once the on time has passed. A fresh start is the one place a line's
registers are programmed, so holding RTS and releasing it need no
message beyond the driver's start. `reset` takes the line through five
steps, in this order, each finished before the next:

1. **Stop the driver.** The line's driver process ends, so nothing
   touches the UART until step 2.
2. **The UART held.** The line service starts the driver with
   `init => fresh` and flow `none` in its record, whatever the grant's
   flow, which programs the UART from nothing (below) with neither
   `RTSEN` nor `CR`'s `RTS` set, so RTS is deasserted, and empties the
   line's receive buffer.
3. **Device off.** The line service asks for the power line's off
   notification and waits the off time
   ([The power line](#the-power-line)).
4. **Device on.** It asks for the on notification and waits the on time.
   The controller reads its CTS, the UART's RTS, as it powers up, and
   finds it deasserted.
5. **The UART afresh.** The holding driver ends, and the line service
   starts the driver again with `init => fresh` and the grant's rate and
   flow, which writes `CR` 0 first, so RTS stays deasserted, empties both
   FIFOs, and sets `RTSEN` only in its last write; it empties the line's
   receive buffer and clears the broken mark, and the line answers.

So no byte and no setting of the last bring-up survives a `reset`:
the transmit FIFO is emptied before the controller goes off, the
receive side holds only what the new controller sends after the answer,
since what it sent during the on time is in a FIFO step 5 empties or in
the buffer it empties, and the UART's rate, format and flow are the
grant's, whatever the boot or the last driver left. A holding driver
that ends during the power cycle keeps RTS deasserted: it leaves `CR` as
it wrote it, and its end is step 5's first act anyway.

No driver's end masks the UART's interrupts: a driver unmasks the
receive and receive-timeout interrupts as its start ends
(`erlang/apps/erx_uart/src/erx_pl011.erl:104`) and leaves `IMSC` so, and
what masks them again is the next fresh start's first step, `CR` 0 then
`IMSC` 0 (below). So from a driver's end until the next start's first
step (through the rest of a power cycle whose holding driver ended
early, after a start that fails before that step, as one whose record
`program/1` refuses or whose open fails, and after a failed reset) a
controller that sends against a deasserted RTS raises line 153, which
the host link shares, with no driver to clear it; that window is a
residual of [todo-bluetooth.md](todo-bluetooth.md) (`erx_pl011`'s start
effects).

**A reset that fails.** A driver that does not start at step 2 or 5,
or a notification that fails or times out at step 3 or 4, ends the
reset there: the line ends the driver it holds, which is the holding
one when step 3 or 4 fails, and waits for its end as it waits for any
event, answering flushes, clunks and reads meanwhile, so no driver runs
with flow `none` past a failed reset; then it marks the line broken with
no driver, answers the `reset` `eio`, and answers `eio` to every write that arrived during the reset,
so none reaches the controller without the grant's flow. The broken
mark is cleared only at step 5, so a reset that fails leaves the line
as a driver that did not start leaves it, and the next `reset` begins
at step 1 with no driver to stop.

A platform that names no power line for the UART's device runs steps 1
and 5 alone, and its bring-up relies on `HCI_Reset`; the platforms
this design names are the Pi 4, which has a power line, and QEMU
`virt`, whose line is a virtio port with no RTS
([The line on QEMU `virt`](#the-line-on-qemu-virt)). A UART controller
on a board with no power line would meet the controller in the mode its
own power-up chose.

**Its driver is `erx_pl011`, started fresh.** For the console and the
host link, `erx_pl011` keeps what the boot left: it clears neither FIFO,
since the kernel's last lines and a person's typing are in them, and
programs the divisors only of a UART the boot left unprogrammed, so
starting it again resets neither the bytes nor the rate. A line's record carries `init => fresh`, its rate and its flow,
and `erx_pl011:program/1`, a pure function of the record, which carries
the UART's clock, returns the register steps the driver performs, in
order,
following the programming note of the PL011's manual (DDI 0183G, page
3-16):

1. `CR` written 0: the UART, the transmitter, the receiver and both flow
   enables off; then `IMSC` written 0, so the controller's bytes raise
   nothing on a line another driver shares until the start ends. The driver then waits one character time at the boot's
   divisors, as `keep` does, for the character in flight, and does not
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
4. `ICR` written with every interrupt bit.
5. `CR` written whole: `UARTEN`, `TXE` and `RXE`, and `RTSEN` and
   `CTSEN` when the flow is `rts_cts`, so the PL011 holds RTS off while
   its receive FIFO is full and sends only while CTS is on. With flow
   `none` the write sets neither `RTSEN` nor `RTS`, so RTS is
   deasserted, the state [A reset](#a-reset)'s step 2 holds through the
   power cycle: the board read RTS0 high with `CR` `0x8301`, which
   differs from that write only in `CTSEN`, a transmit control
   ([research-bluetooth-pi4.md](research-bluetooth-pi4.md#b-p3-the-controller-before-the-patch),
   run 4).

Either start ends by attaching the UART's interrupt line and then
writing `IMSC` whole with the receive and receive-timeout interrupts
and no other. The console's and the host link's start keep their
own sequence, `init => keep`, which a record that names no `init` takes
and `program/1` also returns, so one function names both and the
driver's effects are the same loop over its list. The
driver speaks the six console driver messages, unchanged. The line runs
at 115200 baud throughout; a faster rate is a measured optimization
([Performance](#performance)).

**The shared line 153.** UART0 and UART3, the host link, interrupt on one
line, so the drivers of two services of the system domain share it, and
a line has one binder. The system domain starts the host link and the
line trees under one supervisor, `erx_uart_sup`, `one_for_one`, of
**line groups**, one for each interrupt line those UARTs use and one for
each virtio console, which has a line object of its own. A group is
a `rest_for_one` supervisor: the line's owner first, when the line is
shared, which `erx_irq_line:owners/1` computes from the drivers'
records, then the line's services, a `one_for_one` supervisor of the
host link if its UART is on the line and each line tree on it, each
starting its own driver, which joins the owner
([design-shared-devices.md](design-shared-devices.md#lines-inside-a-domain)).
So an owner's failure restarts exactly the services whose UARTs share
its line, one service's failure restarts no other, and a failure on
another line restarts nothing here. On the
Pi 4 one group holds line 153's owner, the host link and the Bluetooth
line's tree; on QEMU `virt` the host link's group holds the host link
alone, and the Bluetooth line's tree, over its virtio-console
transport, is a group of its own with no owner. The console is not in a group: it starts its own line's owner,
under `user_sup` and `erx_console_sup`, and takes that owner's end as
its driver's, which ends the runtime
([design-runtime.md](design-runtime.md#configuration)), and the manifest
check refuses a console UART that shares an interrupt line with any
other UART the system domain drives, as it refuses one that shares the
host link's ([design-shared-devices.md](design-shared-devices.md#open-decisions)).

#### The power line

Power is the device service's, through the one kernel call for the
firmware's requests, `erx_firmware_request`
([design-kernel.md](design-kernel.md#firmware-requests)), whose
`index` names one of the notifications the platform record lists for the resource's device,
the VL805's one being index 0. A device's power line is one fact of
the platform record: a **power row**, which names the device and a
member of the closed set `fw_power_line`, and gives the off and on
times. The Pi 4's record has one, for UART0's device entry,
`/soc/serial@7e201000`: the power line `bt_power`, with 300 ms off and
500 ms on, Zephyr's (`hci_uart_infineon.c:38-39`, `:236-246`), which
bring the controller back at 115200 baud (probe B-P2,
[research-bluetooth-pi4.md](research-bluetooth-pi4.md#the-power-phases)).
`abi/formats/vc_property.txt` declares `bt_power` as the tag
`set_gpio_state`, request pin 128, off state 0 and on state 1:
expander pin 0, which the firmware's device tree names in the
`shutdown-gpios` of UART0's `bluetooth` child and whose
`gpio-line-names` entry is `BT_ON`, active high (probe B-P2). Neither
the build nor the boot reads the device tree for it: the declaration
holds what the probe read there, and a board whose tree names another
pin gets a power line of its own in the set. From the
power row the generator derives the device's two notifications: index
0, `bt_off`, the tag with the words 128 and 0, and index 1, `bt_on`,
the words 128 and 1; and UART0's device row carries the times
(`erx_mf_device`'s `power_off_ms` and `power_on_ms`, 16 bits each, so the
codec refuses a longer time), which the root writes into its device
record, which the line service reads at a tree's start as
`power => {Off, On}`, its presence saying that the device has a power
line, 0 and 0 meaning none. The line service names the device to the
device service by the record's INDEX, its row in the manifest's device
table, which is the row the domain library's firmware entries take. So the pins a record can drive are those
`fw_power_line` declares, one, and no record row chooses a pin or a
state.

* **The request.** `abi/formats/vc_property.txt` declares the tag as a
  member of the closed set `fw_tag`, `set_gpio_state`, `0x00038041`,
  beside `notify_xhci_reset`: its request is two words, the pin and the
  state (`bcm2835_firmware.h:161-168`), its answer window empty, its
  least answer 0, and its answer is its first value word, 0 when
  performed (below). The same
  file declares `vc_row_words`, 2, the most request words a device row
  carries, and the generator refuses a device row whose tag's request is
  longer. A firmware request row carries its tag's request
  words: in the platform record a row's `arguments` is a list as long as
  its tag's request, `[1048576]` for the VL805's notification, and a
  power row's two rows carry the words its power line declares; the
  manifest's `erx_mf_firmware_request`
  (`abi/manifest.txt`) carries `vc_row_words` words, `arguments`,
  the generator writing 0 past the tag's request; `liberx`'s
  `erx_firmware_row_t` (`liberx/backend/api.h`) carries the same two
  words, which the system library copies from the record
  (`liberx/system/dom_apply.c`) and the mailbox core writes as the
  request's first words, reading only as many as the tag's declaration
  says. So each row's words are stated once, in the platform record or
  in the power line's declaration, the tag's declaration says how many
  are sent, and no caller supplies one. The manifest generator checks
  each row against its tag: a `notify_xhci_reset` row names a PCIe
  bridge, and its one word is one of the bridge's places' addresses; a
  row that names `set_gpio_state` itself is refused, since that tag's
  rows come only from a power row; and a power row is refused unless it
  names a power line `fw_power_line` declares and a placed UART device
  that no other row names, so the power line's two rows are that
  device's only ones, each phase's at its value in `fw_power_phase`
  (`abi/formats/vc_property.txt`): off at index 0 and on at index 1. The get tag,
  `0x00030041`, is not declared: nothing reads the line's state back.
* **Authority.** The line service asks the device service,
  `erx_devices:power(Device, off | on)`, a call inside the system
  domain. The device service's firmware worker (`erx_firmware_worker`)
  makes the kernel call through the domain library,
  `erx_domain_lib:firmware(Device, {power, Phase})`
  ([design-board-sensors.md](design-board-sensors.md#the-requests)), with the
  resource UART0's device record holds, carved with `ERX_CARVE_DEVICE`
  from the entry the record names with notifications, as
  `firmware(Bridge, bridge)` makes it for a bridge
  ([design-pcie.md](design-pcie.md#facets)). The library offers a power
  phase only to a device whose manifest row carries a power line's
  times, and a bridge's notification only to a host bridge row, so the
  caller chooses neither the tag nor the value, only which phase; only
  the system domain's device service calls the library, and no domain
  but the system domain holds a resource that names the entry.
* **Deadline and answer.** The call's: a poll of at most 1 s, the answer
  matched by its buffer, and an error status for a resource without
  notifications and for an index past its device's list
  ([design-kernel.md](design-kernel.md#firmware-requests)). The answer
  check reads the response code, the first tag and the tag's response
  word, and for `set_gpio_state` its first value word, the pin word, and
  accepts per tag:

  | Answer | `notify_xhci_reset` | `set_gpio_state` |
  | --- | --- | --- |
  | response code other than `0x80000000`, or a first tag other than the row's | `ERX_EPROTO` | `ERX_EPROTO` |
  | response word with bit 31 set | `ERX_OK`, no bytes | `ERX_OK`, no bytes, if the pin word is 0; else `ERX_ENOTSUP` |
  | response word 0 | `ERX_ENOTSUP`: the firmware ignored the tag | `ERX_OK`, no bytes, if the pin word is 0; else `ERX_ENOTSUP` |
  | any other response word without bit 31 | `ERX_ENOTSUP` | `ERX_ENOTSUP` |

  Both are facts of `0x00038041`. FreeBSD records that the firmware
  does not set the set-GPIO-state tag's response word, and takes a word
  of 0 as its answer (`bcm2835_mbox.c:362-370`); its expander driver
  then takes the set as done only when the firmware has written the pin
  word 0 (`raspberrypi_gpio.c:253-255`, "The firmware sets gpio to 0 on
  success"), and fails it with `EINVAL` otherwise. The Pi 4's firmware
  leaves the response word 0 and writes the pin word 0 on every set,
  while the controller's power follows the state (probe B-P2, run 1,
  [research-bluetooth-pi4.md](research-bluetooth-pi4.md#the-power-phases)).
  So that tag's declaration states it, once, for every caller
  ([design-board-sensors.md](design-board-sensors.md#the-requests)): the
  mailbox core's tag declaration, `erx_vc_tag_t`
  (`include/erx/core/vc_property.h`), carries a field `result_word`,
  which only `set_gpio_state`'s declaration sets, and where it is set
  `erx_vc_answer` (`kernel/core/vc_property.c`) takes a response word
  of 0 or with bit 31 set as an answer and returns `ERX_OK` with no
  bytes only if the first value word reads 0, `ERX_ENOTSUP` otherwise;
  where it is not set, a word of 0 is `ERX_ENOTSUP`, as is any word
  without bit 31. The pin word lies within the request the kernel laid
  out from the tag's declaration, so reading it moves by no length from
  the reply, and with an empty window nothing is copied to the caller.
  A buffer the firmware left untouched keeps the pin word the request
  wrote, 128, so an ignored request is refused rather than taken as
  performed; the generator refuses a power line whose pin word is 0,
  which an untouched buffer would read as performed. The device
  service answers `ok` for `ERX_OK` and `{error, Status}` otherwise,
  and for any error the line service ends the reset as a failed one,
  answering it `eio` ([A reset](#a-reset), "A reset that fails").
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
  one firmware worker
  ([design-system.md](design-system.md#devices), "Firmware requests"),
  so two requests never meet in the kernel and `ERX_EBUSY` arises only
  beside a trial request or a call a restarted device service's old
  worker left in the kernel. The worker waits on the kernel call alone,
  and the device service's own process on nothing, so it answers the
  watchdog's liveness call throughout; the off and on times are the
  line service's timers, so a power cycle holds the worker for two
  calls, at most 1 s each.

#### The line on QEMU `virt`

On QEMU `virt` the line's driver is `erx_virtio_console`, the driver
of port 0 of a virtio console (virtio 1.2, section 5.3), over a
virtio-mmio transport, of a unit the system domain holds, whose device
row, of role `serial`, the line grant's `device` names. The
development manifest's common part declares the system domain's `line`
service, which the line's keeper names, but grants it to no domain, and
on QEMU `virt` only the manifest of its Bluetooth suite places the unit,
grants `line` and runs the Bluetooth domain, so no development boot meets
an empty transport. The Raspberry Pi 4's board part grants it on UART0,
whose unit, the host link's, the system domain holds already.
Its record is a `given` one, with the window, the line and the DMA
memory the root makes for it, and the peripheral of the `serial` kind
row, the transport alone, since the driver reads no configuration field
([design-fiasco.md](design-fiasco.md#device-records)): the kind row,
matched by the role and compatible string the platform record fixes,
never the grant, picks the peripheral, so no manifest pairs a device
with another device's driver. The device is unconfined, so it puts
QEMU's device model in the system domain's trusted base, which only a
development build may run, since property 9 refuses it in a release. It speaks the PL011's driver messages
([design-runtime.md](design-runtime.md#the-console-and-standard-io)), so
the line service, the tree and everything in the Bluetooth domain are the
ones the board runs. It negotiates no feature of the device type's: without
`VIRTIO_CONSOLE_F_MULTIPORT` the device has port 0 alone, on queue 0, its
receive queue, and queue 1, its transmit queue, and no control queue
(section 5.3.2). Its start does not wait: a device whose reset has not
finished answers `negotiate/2` `ebusy`, which fails the start, as any
failed step does, and an empty transport, with no device behind it,
fails it too.

It keeps the receive queue full of device-writable
buffers and passes the bytes of each the device returns, as many as its
used length says, unchanged to the line; it lays a write's bytes in
device-readable buffers of the transmit queue, in order, and answers the
write once the device has returned every one of them. A used element or
used index the device NIF's ring core refuses, such as a length past its
buffer or a buffer not in flight, breaks the queue; a broken
queue ends the driver, which leaves the line broken with no driver, as
any driver's end outside a `reset` does.

QEMU `virt`'s platform record names no power line, so a
`reset` is steps 1 and 5 of [A reset](#a-reset) alone: the
driver's fresh start resets the device, which returns every buffer and
drops what the device held, and the line drops what it buffered. Bytes
QEMU or the socket still holds may reach the fresh driver, so the line
is resynchronized, as on the board, by the bring-up's `HCI_Reset` and
its answer ([The bring-up](#the-bring-up)). The QEMU
harness joins the port through a socket to a Bumble controller's TCP
transport ([On QEMU against Bumble](#on-qemu-against-bumble)). HCI over
USB is another driver behind the same tree.

### What a radio peer can make the domain spend

Every bound is a constant of `abi/formats/bluetooth.txt` or of the
table, fixed before any peer arrives:

| Resource | Bound | Fixed by |
| --- | --- | --- |
| connections | the row's limit, at most `bt_connections_max`, 4; advertising stops at the limit | the controller process |
| ACL packets in flight to the controller | the controller's LE buffer count, at most `bt_acl_credits_max`, 8, split evenly among the configured connections, so no link holds another's | the controller process |
| packets and commands waiting to be written | one: the writer takes the next only after its last write returned | the controller process and the writer |
| notifications waiting for a link's credits | `bt_notify_queue`, 16 frames, per link; past it `notify` answers `{error, busy}`, and an SMP or signaling answer is dropped and counted, a dropped SMP answer failing its pairing at SMP's timeout; ATT's responses and its one indication queue past it, and one that would make the queue hold more than 18 frames ends the link, since an honest phone sends a request only after it received the last response (ATT 3.3.2) | the link |
| an ACL packet from the controller | `bt_acl_rx_max`, 251 octets of data, which the bring-up states with Host Buffer Size; a longer one is a loss of synchronization | `erx_h4` |
| messages from the controller process waiting in a link's mailbox | `bt_link_backlog`, 32, each an event or one ACL packet; the link acknowledges each once stepped, and a link at the bound is sent nothing more and disconnected ([Commands and data credits](#commands-and-data-credits)) | the controller process |
| an L2CAP frame being reassembled | 4 bytes of header and the channel's MTU: 65 for SMP, and ATT's 247 for ATT and every other channel; a longer frame ends the link, and a signaling frame past MTUsig, 23, is answered Command Reject (L2CAP 4) | `erx_bt_link_core` |
| ATT requests | one outstanding (ATT 3.3.2); a second before the response ends the link | the link |
| ATT commands waiting for a handler | `bt_write_queue`, 16; past it the link ends, counted, although ATT 3.3.2 would allow the command to be discarded, since a discarded write is a silent gap in a handler's stream ([For apps](#for-apps)) | the link |
| a prepared (long) write | one per link, at most the characteristic's maximum, 512 octets at most | the link |
| subscriptions | one configuration per characteristic with notify or indicate, per link | the table |
| pairings | one at a time, in an open window, which closes at the first, and none during the pairing wait | the window |
| bonds | `bt_bonds_max`, 8 | the store |
| a service's advertised payload | its declared maximum, fitted into the advertising data when the image is built; however fast handlers change what is advertised, one `advertising_changed` outstanding in the controller process's mailbox and one pending write in the core | the registry and the controller process |
| with the central role: reports kept for one scan | `bt_scan_reports_max`, 32, each with one payload cut to its declared maximum; a scan lasts at most `bt_scan_ms_max` | the controller process |
| with the central role: what a peer's table makes a link keep | the handles of the declared characteristics of the services the link's owner uses, and nothing else | the link |
| with the central role: a peer's notifications not yet taken by their owner | `bt_write_queue`, 16; past it the link ends, counted | the link |
| the stored state | `bt_state_max`, 4 KiB | the store |
| time | every HCI command 5 s; every handler's answer 5 s; every call of the store's backend 5 s; SMP 30 s (SMP 3.4); an indication 30 s (ATT 3.3.3) | each owner |

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

1. **Reset the line.** The writer writes `reset` to `ctl`, and its
   answer is the core's input `line_ready`
   ([The controller process's effects](#the-controller-processs-effects)).
   The controller is fresh
   from power-on where the platform has a power line, booted with RTS
   deasserted in the mode that answers every command, and the UART is
   programmed afresh ([A reset](#a-reset)). The reset is under its own
   deadline, `bt_line_reset_timeout_ms`, 5 s: two power notifications,
   each answered within the mailbox's 1 s, and the off and on times, with
   room to spare; a reset that has not answered by then ends the
   controller process, so every step of the bring-up has a deadline. The
   controller process does not wait on the `ctl` write: the line's answer
   arrives as one more input, so a line service that never answers
   cannot hold it.
2. **`HCI_Reset`** (HCI 7.3.2).
3. **Identify.** Read Local Version Information (7.4.1), Read Local
   Supported Commands (7.4.2), LE Read Local Supported Features Page 0
   (7.8.3) and Read BD_ADDR (7.4.6), each shown at `/proc/bt`. The Pi
   4's ROM answers HCI version 7, manufacturer `0x000f`, LMP subversion
   `0x6119`, and the address `aa:aa:aa:aa:aa:aa`, a placeholder that
   names no board, which the identity address never uses
   ([The identity address](#the-identity-address)).
4. **Patch**, when the row names a patch, as the Pi 4's does; with
   none the bring-up goes from step 3 to step 5. The row also names the
   manufacturer the patch is for, as Read Local Version reports it; a
   controller that reports another stops the bring-up with
   `patch_for_other_controller`, so no vendor command reaches a
   controller it was not written for. The patch is loaded in the mode
   step 1 boots, the one that answers every command, so loading it is a
   run of commands on the line every bring-up already has: no second
   kind of reset, no word of `ctl` and no state of the line exists for
   it. The step sends Download Minidriver, `0xFC2E`, with no
   parameters, and waits `bt_patch_minidriver_ms`; replays the patch's
   records in file order, each a command whose Command Complete it
   awaits, the last of them Launch RAM, `0xFC4E`; waits
   `bt_patch_launch_ms`; and then runs two steps of its own:
   **`HCI_Reset` after the patch** and **identify after the patch**, the
   commands of steps 2 and 3 again, so `/proc/bt` shows the patched
   version, after which it goes to step 5. The patched states are
   distinct from the first ones, so the bring-up patches at most once
   and is a line of states, not a loop. The patch is read whole, by
   `erx_bt_patch:records/1`, before its first record is sent: it
   accepts a file made only of complete records of the opcodes `0xFC4C`
   and `0xFC4E`, which Zephyr's loader also requires, and refuses any
   other, so a damaged file sends nothing rather than half a patch. The
   controller's name, which NetBSD uses to choose the file
   (`init_bcm43xx.c:110-114`), is text the controller writes and
   chooses nothing here.

   **Why the mode every reset boots.** NetBSD sends `0xFC2E` right
   after Read Local Name (`init_bcm43xx.c:105-125`), a command only that
   mode answers (probe B-P3, run 3), so its download starts there, and
   it waits for every record's Command Complete, Launch RAM's included,
   before its wait and its reset (`:127-141`; `btattach.c:523-550`,
   which reads until the matching Command Complete arrives). Zephyr's
   Infineon driver sends `HCI_Reset` and then the same commands the
   same way (`hci_uart_infineon.c:141-191`, `:261-295`); it requires
   hardware flow control (`:34-35`) and powers the controller with its
   UART open (`:239-246`), so its controller probably boots in the
   download mode, but whether its UART asserts RTS during the power-up
   is not in the source read, and its Kconfig says the download mode is
   "not required on older AIROC controllers", only on newer ones such as
   the CYW555xx (`Kconfig.infineon:199-212`, v4.2.0). Infineon's guide
   loads its parts with flash from the download mode, which accepts
   "read, write, and launch commands", and expects each Write RAM's and
   Launch RAM's Command Complete within 200 ms (AIROC HCI firmware
   download, 3.2, 3.3). So no source says the mode ready for every
   command refuses the download, and one host's download starts from
   it. On the Pi 4 the download mode answered `0xFC2E` (B-P3, run 3);
   the mode step 1 boots has not yet been sent `0xFC2E` or any record,
   and probe B-P5 reads it ([Board probes](#board-probes)). Were it to
   refuse, the patch would need a power-up with RTS asserted, a second
   kind of reset with a `ctl` word of its own, and a launch that leaves
   the download mode, which no run has read (run 4's launches decided
   nothing); that change comes back to this design before step 4 runs
   on the board.

   **The waits.** NetBSD waits 1 s after the minidriver and 4 s after
   the launch (`init_bcm43xx.c:125`, `:139`); Zephyr waits none and
   270 ms (`hci_uart_infineon.c:42`, `:284`); `bt_patch_minidriver_ms`
   and `bt_patch_launch_ms` are NetBSD's, the longer, and B-P5 reads
   whether Zephyr's suffice.

   **The Pi 4's patch.** `BCM4345C0.hcd` is 63,806 bytes of 323
   records: 322 Write RAM, each an address and at most 200 bytes, and
   one Launch RAM, last, to the address `0xFFFFFFFF`, whose meaning no
   source read states (the guide's reboot address is 0, 4.3).
5. **Buffers.** LE Read Buffer Size (7.8.2); a controller that answers a
   length or a count of 0 has no LE buffers of its own and shares its
   BR/EDR buffers, which Read Buffer Size gives (7.8.2, 4.1.1). A length
   from 1 to 26, which 7.8.2 alone reserves, stops the bring-up; Read
   Buffer Size reserves no length, and a length or count of 0 from it,
   outside the ranges 7.4.5 gives, stops the bring-up. A controller with
   fewer buffers than the row's connection limit lowers the limit to its
   buffer count, so each link's share is at least one buffer, and
   `/proc/bt` shows the limit in force. Then Host Buffer Size (7.3.39)
   with `bt_acl_rx_max` and `bt_host_acl_packets`, 8, flow control from
   the controller staying off. The count is required, from 1 to 0xFFFF
   (7.3.39), but with flow control off the controller sends without
   counting the host's buffers (4.2), so it bounds nothing: the host
   always reads, and the line's bound is the backstop ([Commands and data
   credits](#commands-and-data-credits)). It stays a small nominal 8;
   turning flow control on would make it a limit, with Host Number Of
   Completed Packets returning the host's buffers (4.2), and needs a
   design of its own.
6. **Configure.** Set Event Mask (7.3.1) and LE Set Event Mask (7.8.1)
   with the events erXos decodes and no others; LE Set Random Address
   (7.8.4) with the identity address ([below](#the-identity-address));
   LE Set Advertising Parameters, Data and Scan Response Data (7.8.5,
   7.8.7, 7.8.8).
7. **Ready.** LE Set Advertising Enable (7.8.9) while connections are
   below the limit.

A patch, where a board's manifest names one, ships in that board's image
as a file of `erx_bt`'s `priv` directory, unmodified, under its license,
with the license's text in the image's `NOTICES`, and only the manifest
that names it brings it in. It is in the boot image rather than on the boot
partition beside the VideoCore firmware because erXos, not the
firmware, reads it, and only the slot writer may read a slot's partitions
([design-system.md](design-system.md#the-manifest), property 8).

**The Pi 4's patch and its license.** The Pi 4's patch is the file
Raspberry Pi OS ships for this controller: `BCM4345C0.hcd` of Raspberry
Pi's `bluez-firmware` repository, `RPi-Distro/bluez-firmware` at commit
`cdf61dc691a4` (its release 1.2-13+rpt2), path
`debian/firmware/broadcom/BCM4345C0.hcd`, SHA-256
`51c45e77ddad91a19e96dc8fb75295b2087c279940df2634b23baf71b6dea42c`. The
fetch step pins it in `deps.lock` as the source `cypress-bt-bcm4345c0`,
with the license's text as the source `cypress-bt-license`
([Sources](#sources)). It is under Cypress's Wireless Connectivity
Devices Driver End User License Agreement: the repository's
`debian/copyright` names that license for `debian/firmware/broadcom/*`,
and the `LICENSE.cypress` beside the file is a saved web page of
linux-firmware's `LICENCE.cypress`, git blob `070ef66f4342`, whose plain
text is pinned from linux-firmware, where the same blob is
`LICENSES/LICENCE.cypress`. The license grants a non-exclusive,
non-transferable right "to reproduce and distribute the Software in
object code form only, solely for use in connection with Cypress
integrated circuit products"; forbids modifying the file, making works
derived from it and reverse engineering it; asks for no notice to be
kept with object code, its notice clause covering source code alone;
binds the distributor to export-control law; and ends on any breach. A
Pi 4 image meets it. The file is copied byte for byte: the fetch step
checks its SHA-256 and the packer changes nothing. It goes only into an
image whose manifest names it, the Pi 4's, whose controller is
Cypress's CYW43455, and is sent only to a controller that reports the
manifest's manufacturer. Nothing in erXos reads it beyond splitting it
into records. The image's notices carry the license's text, which the
license does not ask for, so a recipient reads the terms the file comes
under. QEMU `virt`'s manifests name no patch, so the QEMU images and
the browser demo carry none. The license is accepted for this one file
([Decisions](#decisions), 4;
[design.md](design.md#licenses-and-notices)). Its preamble binds
whoever downloads the file, so every host whose fetch step fetches it
accepts the license too.

Both pins are `file` sources of `deps.lock`, status `permanent`, each
with the SHA-256 of [Sources](#sources): `cypress-bt-bcm4345c0`, file
`BCM4345C0.hcd`, from
`https://raw.githubusercontent.com/RPi-Distro/bluez-firmware/cdf61dc691a49ff01a124752bd04194907f0f9cd/debian/firmware/broadcom/BCM4345C0.hcd`,
and `cypress-bt-license`, file `LICENCE.cypress`, from
`https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/LICENSES/LICENCE.cypress?id=a1ebb5ad7eae3caca60b8b3db5792cf43339ba58`.
The patch is `permanent`, board-specific, in the dependency table of
[design.md](design.md): it runs in the controller, outside every
domain's trusted base, so it is not a `release` component, and no stage
of the roadmap replaces it, so it is not a `stopgap`; it is the chip
vendor's code for the chip, as the WiFi chip's firmware is
([design-wifi.md](design-wifi.md#the-chip)).

### Commands and data credits

The controller process keeps one command in flight: it sends the next
only when the last was answered, by Command Complete or Command Status,
and the controller's latest `Num_HCI_Command_Packets` is at least one (HCI
4.4); a Command Complete or Status with opcode `0x0000` only updates that
count, and one whose opcode is neither `0x0000` nor the command in
flight's ends the controller process, as a loss of synchronization
does. Commands in this design are few and none is urgent, so one in
flight is enough and makes every command's answer the answer to the last.
A command's deadline, `bt_command_timeout_ms`, starts when the command
falls due, not when it is written, and runs through any time the
controller allows none: a controller that answers
`Num_HCI_Command_Packets` 0 and never follows with an opcode-0 event
ends the controller process at the deadline. The deadline ends only
when the command is written, or when the line would take a command
and none is due, so a command that stops being due and falls due again
in between keeps the deadline it first fell due with: a controller
that reports connections completing and ending in turn at the limit,
making the advertising enable due and not due, does not hold off that
end. Which command is due is
decided again on every step, and the command is chosen and taken only
when the writer takes it, so a disconnect for a handle that has gone,
even one the controller has since given a new peer, or advertising at
the limit, is never sent. A link's disconnect stays with its handle,
asked and then taken, until the handle's Disconnection Complete, so a
second request is ignored and no disconnect is decided for a handle
after its Disconnection Complete. A connection on a handle whose
disconnect is handed to the writer and unanswered ends the controller
process: the controller may carry that disconnect out on the new peer,
and the restart, the one recovery that exists, resets every link rather
than leaving the core to guess which peer the disconnect reached.
Unknown Connection Identifier (Vol 1 Part F, 2.2) means the handle has
gone. Command Disallowed (2.12) says only that the controller cannot
take the command now, and HCI 7.7.5 lists a disconnect "not presently
allowed" among those that fail; the controllers read give it to a
connection already ending: NimBLE's to one whose termination it has
started, its own or the host's, as at a Negative Reply that leaves it no
key (`ble_ll_conn_hci.c:1366-1367`), and Zephyr's to one already ended,
the peer's termination included (`ull_conn.c:407-413`). So a disconnect
answered with either keeps its mark until the handle's Disconnection
Complete, as one answered with success does, and a peer leaving as the
host disconnects it costs nothing; any other failure ends the controller
process. But Zephyr's also answers Command Disallowed for a connection
that is not ending, when it has no procedure context free
(`ull_llcp.c:772-775`), and a Disconnection Complete may fail; either
would leave the connection up, holding a connection slot with no
`link_down` for its link. Asking again at once would hold off the Long
Term Key replies, which fall due after disconnects, so a disconnect is
asked of the controller once: the mark it takes when the writer takes it
holds a deadline, `bt_disconnect_timeout_ms`, 45 s, and a handle whose
successful Disconnection Complete has not come by then ends the
controller process, whose restart ends every connection: a refused
disconnect costs every peer its link, as any stop does. The deadline
counts from the writer's take, and a termination already under way ends
within the longest LE supervision timeout, 32 s (HCI 7.7.65.1; NimBLE's
ends one at its supervision timeout, `ble_ll_ctrl.c:2787-2789`), which
the controller checks at a connection event (`ble_ll_conn.c:2861-2862`),
at most one connection interval, 4 s, later (HCI 7.7.65.1); the command
reaches the controller within `bt_command_timeout_ms`, 5 s, or the core
stops. So the deadline must stay above `bt_command_timeout_ms` plus 36 s,
41 s, for a connection the controllers read are still ending to have
ended by then; 45 s also passes NimBLE's 40 s control procedure timeout
(`ble_ll_ctrl.h:54`). The controller reuses handles, so a
link is named by its handle and the connection that gave it the handle: the
controller process gives a link its name when it starts it, names the link in
everything it sends it, and every request of a link, a packet, a disconnect or a
Long Term Key reply, carries the name, in one envelope whose name the core checks before it reads the
request. A request whose name is not its handle's current link is refused and
changes nothing, so a link that has gone can never send a packet
to, or disconnect, the peer the controller gave its handle next. A link
answers LE Long Term Key Request with `{ltk_reply, Key}`, or
`{ltk_reply, none}` when it has no key, which the controller process
sends as Reply or Negative Reply for the link's own handle (HCI 7.8.25,
7.8.26) and whose Command Complete it passes back as
`{ltk_reply_complete, ok | {failed, Status}}`; the reply waits with its
handle as a disconnect does, goes with it at Disconnection Complete, and
once handed to the writer and unanswered ends the controller process at a
connection on its handle. A command is in
flight once the writer has it, and the writer takes the command before
any queued packet: an answer to a command still waiting for the writer
is a controller fault and ends the controller process. The line's reset,
a bring-up wait and a command are the states of one slot, each holding
its own deadline, so the slot has at most one deadline at a time and
leaving a state drops it; a taken disconnect holds its own, which its
Disconnection Complete drops with the mark, and the core's next deadline
is the earliest of them.

ACL packets to the controller use packet-based flow control (HCI 4.1.1).
The controller process keeps, for each live handle, how many of its
packets are outstanding, from the moment the link hands one over, and
the free credits are derived: the buffer count from the bring-up, at
most `bt_acl_credits_max`, less the live handles' outstanding packets.
Number Of Completed Packets returns a handle's packets, and a handle's
Disconnection Complete returns all of them by removing it (HCI 4.3),
which cannot be forgotten since nothing else holds them. A completion
that names a handle that is not live, or more packets than the handle
has given the writer, is a controller fault and ends the controller
process: a forged report can return no credit for a packet that was
never sent, nor for one still waiting for the writer, so what waits for
the writer stays within the credits however long the line stalls. Each
link may hold at most its share of the buffers in flight, the buffer
count divided by the connection limit, at least one since the bring-up
keeps the limit at most the buffer count. A link learns its share when it
starts, and its handle's returned packets from the core, which passes
each live handle's count in Number Of Completed Packets to the handle's
link as `{completed, Count}`; so a link hands over a packet only while
its outstanding packets are below its share, and its notifications wait
in its own queue, at most `bt_notify_queue`. The core answers a packet
beyond the share with `busy`, which a link that counts never meets; a
link that meets it ends, and its end disconnects it
([The controller process's effects](#the-controller-processs-effects)).
Controller-to-host flow control is not enabled: the host always reads,
and the line's bound is the backstop.

**A link's backlog** is the other direction's share. The controller
process never waits on a link, so what it forwards faster than the link
steps would otherwise wait in the link's mailbox without bound, as it
does while the link makes its two calls at its start ([The link's
messages](#the-links-messages)). The core keeps, for each live handle,
how many of the messages it has sent the handle's link, events and ACL
packets alike, the link has not yet taken; the link's core returns
`taken` from its step of each such message, which the link process
sends as a request in the link's envelope like its packets, so the
acknowledgement of a link that has gone changes nothing. A message for
a link whose backlog is `bt_link_backlog`, 32, is not sent: the core
drops it, sends that link nothing more, and asks the handle's
disconnect with Remote Device Terminated Connection due to Low
Resources (`0x14`, one of the reasons HCI 7.1.6 allows), and the link
ends at its `link_down` as every link does (or, for a disconnect the
controller refuses and never completes, at the controller process's stop
when the disconnect's deadline passes, above). So a link's mailbox holds
at most 32 of the controller's messages, about 8 KiB, whatever the peer
sends and however long the link is held up, and a peer that outruns
its link loses the link, as a peer that passes any other bound does.
An honest phone does not meet it: it sends an ATT request only after
the last response (ATT 3.3.2) and a link steps a packet in far less
time than the line takes to carry one; a stream of Write Commands
past `bt_write_queue` ends the link as the link steps it, never held.

The controller process does no I/O itself: a reader process keeps one
read of `data` outstanding and sends the bytes it got, waiting for the
controller process's acknowledgement before the next read, and a writer
process writes what the controller process gives it, one packet or
command at a time, acknowledging each once its write of `data` returned;
the controller process gives the next only after the acknowledgement.
So what waits for the line is bounded locally, by one item at the writer
and the credits and the command slot at the controller process, whatever
the controller reports; the controller process never waits on the line
and always takes events; what the line delivers faster than the
controller process consumes waits in the line service, up to its bound;
and what the controller process forwards faster than a link consumes
waits in that link's mailbox, up to its backlog. How the process
finds its reader, writer and links, and where its configuration comes
from, is [The controller process's effects](#the-controller-processs-effects).

Events the controller process decodes: Command Complete, Command Status,
Disconnection Complete, Encryption Change, Encryption Key Refresh
Complete, Number Of Completed Packets, Hardware Error, and the LE Meta
events LE Connection Complete, LE Long Term Key Request and LE
Connection Update Complete. Any other event is counted and dropped after
its length is checked. Hardware Error ends the controller process.

### The controller process's effects

`erx_bt_hci` is a loop around `erx_bt_hci_core`: it turns each message
into one input, steps the core and performs the actions in order. Its
group, `erx_bt_host_sup`, `one_for_all`, starts its children in this
order: `erx_bt_link_sup`, `erx_bt_line_rx`, `erx_bt_line_tx`, then
`erx_bt_hci`. The first three register their names in the Bluetooth
domain's runtime, so when the controller process starts its siblings
run and it reaches each by its registered name; the reader and the
writer answer whichever process gave them work and never look it up.
Any child's end ends the whole group, which starts again in the same
order, so the four always belong to one run of the core. Neither the
reader nor the writer traps exits, so the group's shutdown also ends one
blocked in a call to the line service.

**Configuration.** At its start the controller process builds the
core's `new/1` configuration from owners that outlive its group, so a
restart of the group rebuilds the same configuration:

* `connections`, from the application key `connections`
  ([The Bluetooth domain](#the-bluetooth-domain));
* `address`, the identity address, from the store,
  `erx_bt_store:address/0` ([The identity address](#the-identity-address));
* `advertising_data` and `scan_response_data`, from `erx_bt_adv:data/1`,
  a pure function of what the registry answers `erx_gatt_srv:advertised/0`:
  the UUIDs of the served services whose declarations say `advertise`
  and that have a handler now, the payloads those handlers set, and
  GAP's name and appearance; at each change the registry sends
  `advertising_changed`, at most one outstanding, and the controller
  process asks again ([Advertising](#advertising));
* `patch`: `none` when the row names no patch, else the manufacturer from
  `patch_manufacturer` and the records `erx_bt_patch:records/1` returns
  for the file `patch` names. The file is read whole here, so a file the
  reader refuses ends the process before the line is touched.

It then steps `start`, whose one action is `line_reset`.

**The writer** takes two kinds of item. Bytes it writes to `/dev/line/data`,
and acknowledges with `written`. The action `line_reset` it carries out
by writing `reset` to `/dev/line/ctl`, and acknowledges with `line_ready`.
The core gives `line_reset` only as the bring-up's first step, before any
other item, so the writer is idle then and still holds one item at a
time. A write that fails, `eio` from `data` or from `ctl` included, ends
the writer and so the group: the group's restart is the recovery for a
broken line and for a failed power notification alike, and the core has
no input for a line failure. A reset that never answers is the core's
own: the slot's deadline passes and the core stops with
`line_reset_timeout`.

**The reader** opens `/dev/line/data` at its start and reads only after an
acknowledgement; the controller process gives the first when it steps
`line_ready`. A read waiting at a reset answers `eio`
([Concurrency](#concurrency)), so a reader that read before the reset
answered would end its group at every start; reading only after an
acknowledgement puts the bring-up's reset before every read, with no
case of its own. Each read asks for `line_rx_max` bytes, so one read can
take everything the line holds. The controller process appends what
arrives to the bytes the last split left, splits them with
`erx_h4:split/1`, decodes each packet with `erx_hci` and steps it, then
acknowledges. A split error ends the controller process
([H4 framing](#h4-framing)); a read that fails ends the reader, and so
the group.

**Links.** The core's link actions go to link processes, one for each
link the core has named:

* `{link_up, Name, Info}`: the controller process makes the link's
  `Conn`, a fresh reference, starts `erx_bt_link` as a temporary child of
  `erx_bt_link_sup` with `Name`, `Conn`, `Info` (the peer's address,
  the identity address, `acl_tx_max` and the link's share) and its own
  pid, monitors it, and maps `Name` to it;
* `{to_link, Name, Event}`, `busy` among the events: sent as `{hci, Event}`
  to the process `Name` maps to; an action for a name that maps to none is dropped, since
  its link has already ended. Every message for a link, `busy` included, leaves the core
  through the one count of the link's backlog ([Commands and data credits](#commands-and-data-credits));
* `{link_down, Name}`: the controller process removes `Name` and ends its
  process through `erx_bt_link_sup`;
* a link process that ends while its name is mapped: the controller
  process removes the name and steps `{request, Name, {disconnect,
  16#13}}`, Remote User Terminated Connection (`bumble/hci.py:752`). So a
  link's end is its disconnect, whatever ended it; a link that wants
  another reason asks for it before it ends, and the core ignores a
  second disconnect for the handle and refuses one whose name is no
  longer current ([Commands and data credits](#commands-and-data-credits)).

The core's names are unique only within one run of the core: the serial
in a name starts again at each `new/1`. So the controller process maps
full names, never handles, to link processes, and every link process is
a child of `erx_bt_link_sup` in the same `one_for_all` group, which ends
with the core: no link outlives the core that named it, and no name a
later run gives can reach it. What leaves the group is `Conn`, which is
unique for the runtime's life, so no app meets a name that a later run
reuses ([A name dies at once](#a-name-dies-at-once)). From stage 2 a link
registers its `Conn` with the registry when it starts, and the registry
monitors it ([The link's messages](#the-links-messages)).

Before stage 2 a link process has no channels: it hands over no packet,
drops and counts every ACL packet it is given, and ends at `link_down`;
stage 2 gives it the fixed channels ([Links: the fixed
channels](#links-the-fixed-channels)). The core's `{ready, Facts}`, and
`facts/1` at any moment, are what the controller process shows at
`/proc/bt` ([Inspection](#inspection)).

### The identity address

erXos's identity on the air is a **static random address** that the
Bluetooth domain makes from `erx_bytes:entropy/1` and sets with LE Set
Random Address; advertising uses it as its own address. It names neither
the board nor its controller, so no Bluetooth address of an erXos
machine names its hardware, as no IPv6 address does
([design-network-stack.md](design-network-stack.md#ipv6-neighbour-discovery-and-autoconfiguration)).
It needs no vendor command to set the public address and no address in
the device tree. Its one owner is the store, `erx_bt_store`, from stage
1 on: before stage 4 the store makes a new one when it starts, which is
at each start of the Bluetooth domain, and keeps it in memory, which
costs an unbonded phone nothing, since it rediscovers at every
connection. From stage 4 it is part of the stored state and lasts as
long as the bonds that name it. The store sits before the controller
group in `erx_bt_sup` ([Concurrency](#concurrency)), so a restart of the
group keeps the address, and the controller process asks for it,
`erx_bt_store:address/0`, at each of its starts. Its form, two top
bits set and the rest neither all zeros nor all ones, is Vol 6 Part B
1.3.2.1's, stated once by `erx_smp_crypto:static_random/1`; the test of
its maker checks it against Bumble's address parser.

### Advertising

The controller process advertises, connectable and undirected, on all
three channels at a 100 ms interval, while connections are below the
row's limit. The data are a pure function of the advertised services,
the payloads their handlers set, the name and the appearance,
`erx_bt_adv:data/1`, which the controller process calls at its start and
again at each change of the advertised services or of a payload
([The controller process's effects](#the-controller-processs-effects)):

* **advertising data:** the Flags structure (LE General Discoverable,
  BR/EDR not supported); the list of UUIDs of the services whose
  declaration says `advertise` and that have a handler, as complete
  lists of 16-bit and 128-bit UUIDs; and each payload a handler has set,
  in the order of its service's name (below);
* **scan response data:** the complete local name, or the shortened name
  where it does not fit, and the appearance when it fits.

Each is at most 31 bytes, and the manifest check computes both, with
every declared payload at its maximum, and refuses a configuration whose
advertised UUIDs and payloads do not fit; the name is shortened rather
than refused. The AD type values come from Bumble's
`core.py:1594-1622`, unverified against the supplement.

**A service is advertised while someone handles it.** The table is fixed
for the domain's life, but which of its services a phone is told of
follows their handlers: a service that says `advertise` is in the
advertising data from its handler's `attach` until that handler's end
([A service belongs to its handler](#a-service-belongs-to-its-handler)).
**The registry holds what is advertised; the controller process asks
for it.** The registry already sees both events, and sends each link
`{handler, Service, Handler | none}` at them. What is advertised, the
set of advertised services with a handler and each handler's payload
(below), is part of its state, which `erx_gatt_srv:advertised/0`
answers. When that state changes, the registry tells the controller
process with one message, `advertising_changed`, which carries nothing,
and only if no such message is outstanding: it marks one outstanding
when it sends it, and clears the mark when it answers the controller
process's `advertised/0`. So:

* **The controller's mailbox holds at most one such message**, however
  fast handlers attach, end or set payloads, and the answer it fetches
  is always the latest state, never one a later change has replaced.
* **No change is lost.** A change after the answer finds the mark clear
  and sends again. A controller process that starts asks `advertised/0`
  for its configuration, which clears a mark left for a group that
  ended, and its bring-up advertises the answer; with no controller
  process registered the registry sends nothing and marks nothing.
* **A caller never waits on the controller.** The registry answers an
  `attach`, an `advertise` and a handler's end once its own state has
  changed, so a facet's request ends with a value the registry holds,
  never with a message queued behind a busy controller.
* **No two processes wait on each other.** The controller process calls
  the registry, which waits on no process; the registry only sends to
  the controller process.

The controller process turns the answer into one input of
`erx_bt_hci_core`, `{advertising_data, Data}`, `Data` from
`erx_bt_adv:data/1`, and the core writes LE Set Advertising Data with
it at its next free command slot, a later input replacing one not yet
written. Nothing restarts, no link ends and the scan response is
unchanged. A controller that takes LE Set Advertising Data while legacy
advertising is enabled uses the new data in the advertising events
that follow, and an event already under way may use either (HCI 7.8.7,
Vol 4 Part E); the Bumble cell checks the stack against it, and probe
B-P7 checks that the Pi 4's patched controller conforms
([Board probes](#board-probes)).

**A service's payload: its shape is declared, its octets are its
handler's** (B13). A declaration may reserve one payload for its service
([Declarations](#declarations-abigatt)): `data MAX`, a Service Data
structure under the service's UUID, or `manufacturer COMPANY MAX`, a
Manufacturer Specific Data structure of that company identifier, each
of at most `MAX` octets. The handler gives the octets with
`erx_gatt:advertise(Service, Octets)`
([The `ble` facet](#the-ble-facet)), and the payload is advertised from
then until the handler's next `advertise`, an empty one taking it out,
or the handler's end. It is the same construction as a characteristic's
value: the declaration fixes the room, the owner sets the content, and
the content ends with the owner
([A service belongs to its handler](#a-service-belongs-to-its-handler)).
From it:

* **The advertising never overflows at run time.** The manifest check
  has already fitted every served service's payload at its maximum, so
  no `advertise` can be refused for room, and none changes what another
  service advertises.
* **A service speaks only under its own name.** Service Data carries the
  service's own UUID, and the manifest check refuses two served
  services that declare one company identifier, so no handler puts
  octets into the advertising under another service's UUID or another
  maker's company.
* **One state, one message.** A payload is part of what the registry
  holds as advertised, so `advertise` changes that state and answers,
  and the controller process fetches it as above: a handler that calls
  `advertise` a thousand times while the controller is busy leaves one
  message in the controller's mailbox and one pending write in the
  core.
* **A payload is public.** Advertising is sent in the clear to anyone
  in range, whatever level the service's characteristics require. A
  reservation in a declaration is permission to broadcast public
  octets, and a handler puts there nothing it would not show every
  scanner.

A payload is in the advertising data, never the scan response, so a
phone that scans passively sees it. Legacy advertising's 31 octets are
the room, and each structure in them spends one octet on its length
and one on its type before its data. The two forms of payload cost
differently, since Service Data carries its service's UUID again:

| The advertising data hold | Octets before the payload | Most payload octets |
| --- | --- | --- |
| Flags (3), the service's 128-bit UUID listed (18), Manufacturer Specific Data with its company identifier (4) | 25 | 6 |
| Flags (3), 128-bit Service Data with its UUID (18), the UUID not listed | 21 | 10 |
| Flags (3), the 128-bit UUID listed (18), 128-bit Service Data (18) | 39 | none: it does not fit |
| Flags (3), a 16-bit UUID listed (4), 16-bit Service Data (4) | 11 | 20 |

So a service with a 128-bit UUID that reserves `data` does not also say
`advertise`: its Service Data already names it, and the manifest check
refuses the pair as it refuses any configuration that does not fit.
Each further advertised service takes its room from the same 31
octets. The structures' type values come from the same source as the
others, and the octets each structure spends on its length, type and
UUID or company identifier are the Core Specification Supplement's
(Part A, 1.4 and 1.11), not read for this design and unverified until
they are; `erx_bt_adv` and the manifest check take them from
`abi/formats/bluetooth.txt`, the one place they are written, and the
payload test compares `erx_bt_adv`'s data with Bumble's encoder of
advertising data for each row above. What stays out, each for want of
a consumer: advertising that goes on while every connection slot is
taken, which needs non-connectable advertising beside the connectable;
extended advertising and its longer data; a second payload for one
service ([What waits for a consumer](#what-waits-for-a-consumer)).

When a connection completes, the controller stops advertising, as it does
for connectable advertising, and the controller process enables it again
while connections remain below the limit. A connection that completes
while the enable is written and unanswered came from that enable, which
the controller carried out before it answered, so the enable's answer
leaves advertising off.

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

A service that asks for security and speaks in the advertising reads:

```text
# lock: a door lock that its owner's phone opens.
service lock 5f0e0001-7c1b-4c3a-9d2e-0b6a1f3c8e11 advertise manufacturer 0x1234 2
#              name    uuid                                 max accesses
characteristic state   5f0e0002-7c1b-4c3a-9d2e-0b6a1f3c8e11 1   read encrypted notify encrypted
characteristic command 5f0e0003-7c1b-4c3a-9d2e-0b6a1f3c8e11 16  write bonded
```

A `service` line gives the service's name, an identifier, its UUID, 16-bit
or 128-bit, and optionally `advertise`, which lists the UUID in the
advertising, and one payload, `data MAX` or `manufacturer COMPANY MAX`,
whose octets the service's handler sets ([Advertising](#advertising)):
`COMPANY` is the 16-bit company identifier the Bluetooth SIG assigned
the device's maker, in hexadecimal, and `MAX` the most octets the
payload holds. Each `characteristic` line gives
its name, an identifier unique in the service, its UUID, the maximum
length of its value, at most 512, and the accesses it allows, each with
the level it requires: `read`, `write`, `write_without_response`,
`notify` and `indicate`, each `open`, `encrypted`, `authenticated` or
`bonded` ([One table, one gate](#one-table-one-gate)). A
readable characteristic may end with `value` and its initial value in
hexadecimal, so a constant needs no handler.

`tools/gen_gatt.rb` reads every file and generates `erx_gatt_decl`, one
term per service, and the names of those that say `advertise`; the
manifest check takes the declared names, which it holds a row to,
through its checked context, read by the same reader, as it takes the
device kinds. A UUID has one
spelling: one of the Base UUID with a 16-bit value is written in 16
bits, since Find By Type Value compares a service declaration's value
octet by octet (ATT 3.4.3.3) and a phone looks for the 2-octet form. It
refuses a missing or repeated `service` line, a name that differs
from its file's, a UUID that is malformed, the 128-bit form of a 16-bit
one included, or is one of the GATT and GAP
declarations' own (the enum `gatt_uuid` of `abi/formats/bluetooth.txt`)
or, in 16 bits, one of GATT's attribute types, its declarations from
0x2800 and descriptors from 0x2900 to 0x29ff, which a client would read
as what they name,
a service named `gap` or `gatt`, the names the table
gives GAP's and GATT's own services, two characteristics of one name or UUID, a maximum
over 512, an access without a level or repeated, a `notify` and an
`indicate` with different levels, a characteristic with no access, an
initial value longer than its maximum or on a characteristic that is not
readable, a second payload, a payload whose maximum is 0 or which
alone, with the Flags, would not fit one advertising data, a company
identifier past 16 bits, and a byte above 0x7f or a control byte. Nothing
reads a declaration at run time, so it is not an input to fuzz.

Which services a machine serves is the manifest's: each `ble` facet row
names, in its `services` parameter, the services its grantee handles,
and the app template's row those installed apps may handle; the domain
serves exactly these, whether or not their holders run, and advertises
each that says `advertise` only while it has a handler
([Advertising](#advertising)). The packer sorts a `services` set into strict byte order and
refuses a name twice or more than 8 names, and the boot view takes the
packed set only in that order
([design-abi.md](design-abi.md#services-facets-and-their-parameter-schemas)).
`ble_grant`, the parameter's checker, refuses a service of the `ble`
interface not named `ble`, or named `ble` and of another interface, as
the line service's is named `line`
([design-system.md](design-system.md#the-manifest), property 8), so the
name the mint provides and the interface the check reasons from pick one
service; a service of the `ble` interface served by no configured
domain; a `ble` grant to the system domain, whose handler would take a
phone's bytes (B8); a `ble` grant to a session template that is neither
the app template nor a start row's template, since every session made
from any other template would hold it, so that two sessions would
contend for one service's handler, as `line_grant` refuses one
([Who holds `ble`](#the-ble-facet)); a service no file
declares, a service two rows name,
two served services of one UUID or of one company identifier, and
advertising data that do not fit with every payload at its maximum.
Every served set is thus a subset of `abi/gatt`'s services with none
served twice, so the declarations bound what a machine serves and no
count of its own is needed: the host tests build the table of every
declared service ([The attribute table](#the-attribute-table)).

### The attribute table

`erx_gatt_db:build/2` lays out, in this order: the GAP service, with
Device Name and Appearance, read `open`; the GATT service, with Service
Changed, `indicate open`, and its Client Characteristic Configuration;
then each served service in the order of its name, each characteristic as
its declaration, its value and, when it allows `notify` or `indicate`,
one Client Characteristic Configuration descriptor. GAP's Device Name is
the machine's host name, the advertising's local name, and its one owner
is `erx_bt_sup`, which reads it and the appearance once from the `name`
and `appearance` keys ([The Bluetooth domain](#the-bluetooth-domain)),
refusing a name that is not UTF-8 or is longer than Device Name's 248
octets, and hands both to the registry, which lays them into the table
and answers them to the controller process for the advertising data. The descriptor is
readable openly and writable at the one level of the characteristic's
`notify` or `indicate`, whichever it declares, since the generator
refuses the two at different levels, so subscribing is gated as
notifying and indicating are, for Service Changed's `indicate open` as
for any other; on a link that holds a key the write requires at least
`encrypted`, since there it writes the bond's kept configuration
([The link's messages](#the-links-messages)). The GATT service has
no Database Hash: with Service Changed alone, robust caching is not
required (GATT 2.5.2.1).

Handles run from 1 in that order, and `build/2`, which gives every
handle, is the one place that counts them: a table of more than 0xFFFF
attributes, past the 16 bits ATT names a handle in, fails to build, so
no table names a wrapped handle and no other module copies the layout to
count it. Every served set is a subset of the declared services, and the
host tests build the table of all of them, so a set of declarations that
would reach that failure fails them before it lands; one that did not
would stop the Bluetooth domain at start with `{handles_past_0xffff,
Count}`, never serve a wrong table. (That 0xFFFF is the last valid
handle, ATT 3.2.2, is unverified: it is the 16-bit field's last value.)

A characteristic's value is the one its service's current handler last
set, or the declared initial value, or empty: a read never waits on an
app, and a handler's values end with it
([A service belongs to its handler](#a-service-belongs-to-its-handler)). A read of
a value that changes between two Read Blob requests may tear, which ATT
leaves to the higher layer (3.2.9); the one reader such tearing would
hurt, a long read of a value an app changes while a phone reads it, is
named in no stage.

### The ATT server

`erx_gatt_server:request(Pdu, Server, Bearer) -> {Actions, Bearer}`
answers one PDU over `Server`, the table, the values the handlers last
set and the link's security, and the bearer's state; `reply(Ref, Answer,
Server, Bearer)` takes a handler's answer to the write `Ref`, and drops
it unless the bearer waits on that write, so an answer that comes after
its write timed out is never taken for the next one; and `notify(Kind,
Key, Value, Server, Bearer)` makes a notification or an indication the
gate allows. The actions are the PDUs to send, the write for the
handler, numbered by the bearer, and the events for the handlers. A
`Ref` is the link's own, from 1 on every bearer, so it never leaves
the domain as it is: the registry hands the handler a `Req` it makes
unique, and maps it back to the link and its `Ref`, accepting an
answer only for a `Req` it delivered to that handler and not yet
answered ([The `ble` facet](#the-ble-facet)). It
answers Exchange MTU with 247, Find Information, Find By Type Value, Read
By Type, Read, Read Blob, Read By Group Type, Write Request, Prepare
Write and Execute Write, and takes Write Command and Handle Value
Confirmation; every other request is Request Not Supported with handle
0, every other command is ignored (ATT 3.3), and a request whose length is
wrong is Invalid PDU. These cover the server's mandatory features and
the optional ones a first stage needs (GATT Table 4.1): Read Multiple and
Read Multiple Variable stay unsupported. A write of a characteristic's
value whose length exceeds its maximum is Invalid Attribute Value Length;
a prepared write that would exceed it, or that names another
characteristic than the one already prepared, is Prepare Queue Full,
and one to a descriptor is Write Not Permitted. Execute Write joins the
parts from an empty value, each at an offset at most the length the
parts before it wrote, so the handler receives the whole value; ATT
leaves a long value's meaning to the higher layer (3.4.6.1). A request
longer than the bearer's MTU is Invalid PDU, and a command that long is
ignored.

`erx_att` is the PDU codec, whose codes `abi/formats/bluetooth.txt`
holds, with a fuzz target. Its MTU is per bearer, 23 until the client exchanges
it (GATT 5.2.1).

### The `ble` facet

An app reaches the Bluetooth domain only through its `ble` facet, an
instance of the interface `abi/services/ble.txt` declares. Its
parameter `services` names the services the grantee handles, at most 8
names of `abi/gatt`, an identifier set in strict byte order
([design-abi.md](design-abi.md#services-facets-and-their-parameter-schemas)):

```text
parameter services 1 identifier set 8 bytes 63 checked_by ble_grant
```

No handler hears an address, neither the one a phone connected from nor
a bonded phone's identity address: a handler knows a phone by its `Conn`
while it is connected, and a bonded phone across its connections by its
bond's id
([A bond's name is made with its key](#a-bonds-name-is-made-with-its-key)).
The addresses are the administrator's to see, in the control tree and
at `/proc/bt`.

The bound is written there once; [Declarations](#declarations-abigatt)
gives what `ble_grant` refuses. The interface declares the six
operations below, `attach 1`, `set 2`, `notify 3`, `indicate 4`,
`reply 5` and `advertise 6`; the central role adds its own, with two
more parameters ([Apps as centrals](#apps-as-centrals)). A facet row of `ble` says `operations none`, and the facet's
`admit/3` decides what passes, as the `pcie` facet's does
([design-pcie.md](design-pcie.md#processes)), since the boot refuses
operations on a row whose service a configured domain serves: nothing
there would check them ([design-time.md](design-time.md#on-fiasco)).

**The service and its mint.** The Pi 4's board manifest declares the
service `ble`, served by the `bt` domain, beside that domain's row, and
the QEMU Bluetooth suite's manifest declares rows of the same name. The
mint of `ble`, `erx_ble_facet`, is a process of its own below `erx_bt`'s
top supervisor, `erx_bt_top`, and starts with the boot script, as it
must: it names itself the service's mint with `erx_facet:provide/2`, which is refused
after init's ready report, while the registry starts only from the
row's `-eval`, after the report ([The Bluetooth
domain](#the-bluetooth-domain)). For each configured grant the domain
service sends it, the mint starts a facet bound to the grantee, within
the row's limits, that ends with the mint
([design-system.md](design-system.md#facets-a-configured-domain-serves)).
The mint outlives every restart of the registry, and its end ends the
domain ([Concurrency](#concurrency)), whose restart mints every grant
anew.

**Who holds `ble`.** A service has one handler at a time, so every
served service has at most one grantee that can attach to it at a time,
and the rules below follow from that:

* **A configured domain** holds `ble` by a facet row of its own, whose
  `services` names the services it handles. A domain runs one
  incarnation at a time, so the row's services have one grantee.
* **An installed app** holds `ble` through the one row the build
  derives for the app template when the `apps` row's `services` names
  `ble`. That row's `services` is the `apps` row's `gatt` field, the
  GATT services the board lets apps handle
  ([design-packaging.md](design-packaging.md#the-apps-row)). An app's
  grant is that row narrowed to the services its package declares in
  its own `gatt` field
  ([design-packaging.md](design-packaging.md#the-declaration)).
  Admission keeps the declaration when every name is one the row
  offers and no other admitted app declares it
  ([design-packaging.md](design-packaging.md#admission)), and the
  install's commit records it in the app's principal record. Each
  session of the app then holds the template's row with `services`
  replaced by the intersection of the row's set and the record's, which
  the domain service computes as it plans the session
  ([design-system.md](design-system.md#facets-a-configured-domain-serves),
  "Parameters the domain service computes at the mint"). An app's
  principal has a `domains` quota of 1, so an app runs one session at a
  time, and its services have one grantee too.
* **A start row's template**, the session template of a principal that
  has a `start` row and a `domains` quota of 1, holds `ble` by a facet
  row of its own, as `bleuart`'s does ([The console](#the-console)):
  the quota, not the start table alone, lets one session of it live at
  a time, so the row's services have one grantee. The check compares
  the grantee row itself, a session template and the principal it
  belongs to, never a name, so a configured domain named as a start row
  is another grantee.
* **No other grantee** holds it: not the system domain (B8), not
  root's session template, the console's, even when the system
  principal has a `start` row and a `domains` quota of 1, since a radio
  peer reaches root's line only through `bleuart`'s login
  ([The console](#the-console)), and not any other session template,
  every session of which would hold the same services and contend for
  their handlers.

So the scope of an app's grant is fixed at its install, in its record,
and its facet is minted for each session of the app, as every template
grant is ([design-system.md](design-system.md#facets-a-configured-domain-serves));
an installed app that is not running holds no facet. The mint, the
facet and its one check are the same for both kinds of grantee: the
facet's `init/1` keeps the `services` its mint carries, here the
narrowed set, and its `admit/3` refuses any other service with `{error,
not_granted}`.

The Bluetooth domain serves every service of every `ble` row, the app
template's included, whether or not an app that declares it is
installed. A service no app handles serves reads from its declared
values and answers writes Unlikely Error, as any service with no handler
does, and is not advertised ([Advertising](#advertising)). So
installing, updating or removing an app never changes the attribute
table or its hash; only an app's handler, while it runs, puts its
services in the advertising data. `ble_grant`'s checks over
the manifest's rows ([Declarations](#declarations-abigatt)) cover every
app that can be installed.

What happens to an app's grant at each event:

* **Install.** A package whose `gatt` names a service the template's row
  does not offer is refused `{gatt_not_offered, S}`, and one naming a
  service another admitted app declares, `{gatt_taken, S, Other}`; `cp`
  sees `EPERM` and `EEXIST` at its close
  ([design-packaging.md](design-packaging.md#interfaces)), and an
  installed package of the name goes on running as before.
* **A service a configured domain holds.** `ble_grant` refuses a service
  two rows name, so the `apps` row's `gatt` never names a service a
  configured domain's row names, and a package declaring one is refused
  `{gatt_not_offered, S}`. No run-time rule decides between a domain and
  an app.
* **Removal.** The publication without the app ends its session, its
  facet ends with it, and the registry's monitor detaches its handler,
  which ends its ownership of its services: their values return to the
  declared ones, and what a phone sent while the app owned them reaches
  no one else ([A service belongs to its
  handler](#a-service-belongs-to-its-handler)). The package leaves the
  admitted set, so its services are free for the next install at once,
  before the handler's end has reached the registry; a next owner's
  attach waits for that end in `erx_gatt` ([The client](#the-client)).
  The record keeps its `gatt` until the reboot, as it keeps the rest,
  but no session of a removed app starts
  ([design-packaging.md](design-packaging.md#invariants), PK7).
* **Update.** The update ends the app's session before its package's
  name changes, which ends its handler's ownership as a removal does;
  admission of the new package counts the services of every admitted
  app but the one of the name, so an update keeps its own services, may
  add free ones and may drop some, which are free from its commit on.
  The next session's facet names the new set.
* **A restart of the app's session.** The new session's grant is minted
  anew and its handler attaches again, a new owner that starts from the
  declared values and sets its own. Its attach may meet the previous
  session's handler, whose end has not yet reached the registry, and
  `erx_gatt` asks again until it has ([The client](#the-client)).
* **A recovery of the package process.** A recovery after the boot's
  reads the package directory again, which a crafted storage domain may
  have changed, for instance by putting back an older package of an
  installed app that declares other services. Before it registers a
  record that differs from the one the registry holds, it publishes a
  set without that app, and without every app whose package it no longer
  admits, which ends their sessions
  ([design-packaging.md](design-packaging.md#boot-and-recovery)). So no
  session runs on a grant its principal's record no longer gives
  ([design-packaging.md](design-packaging.md#invariants), PK7), and two
  live sessions never hold one service, whatever the recovery read.
* **The Bluetooth domain's restart.** The new mint mints the grant of
  every live session again, as it mints every configured grant.
* **Boot.** The recovery admits the image's packages first and then the
  installed ones in name order, each against the services the packages
  admitted before it declare
  ([design-packaging.md](design-packaging.md#boot-and-recovery)). Two
  admitted packages of one service arise only when a system update gives
  an image package, or takes from the `apps` row's `gatt`, a service an
  installed app declared; the installed package is then refused and
  shown `refused` with its reason at `/proc/packages`.

**The one check.** A facet's `init/1` keeps its grant's `services`, and
its `admit/3` refuses a request naming any other service with `{error,
not_granted}` and one of no operation's shape with `{error, badarg}`;
the facet is the only path to the registry from another domain, so this
is the one check of a grant, and the registry checks no grant: it
checks only the owner, that an effect on a service comes from the
service's handler ([A service belongs to its
handler](#a-service-belongs-to-its-handler)). The facet finds the
registry by its registered name at each request, refusing `{error,
unavailable}` while none is registered, and forwards the request with
its caller, the grantee's process, which it took from the call. The
registry's entry, `erx_gatt_srv:facet/3`, takes that caller and the
operation and no grant; the forwarded call's `From` names the facet,
and the caller in the request is the process that becomes a service's
handler, hears its events, alone sets and notifies its values and alone
answers the writes handed to it.

| Operation | Answer |
| --- | --- |
| `attach(Service)` | `{ok, #{Char => #{max := Max, access := Accesses}}}`, each characteristic's maximum and its accesses with their levels: the caller becomes the service's handler, and hears `connected` for each live link once, when it handles no other service yet, then that link's `mtu` when it changed and a `subscribed` for each of the service's characteristics the phone configured, which the registry keeps from the links' messages until each link's end, so a handler that attaches while a phone stays connected hears what one attached before it connected heard; the registry monitors it, and its end detaches it |
| `set(Service, Char, Value)` | `ok`: reads return `Value` from now on, until the caller's end; `{error, not_attached}` when the caller is not the service's handler |
| `notify(Conn, Service, Char, Value)` | `ok` once queued for the link, or `{error, busy}` when its queue holds `bt_notify_queue`; `{error, not_attached}` as for `set` |
| `indicate(Conn, Service, Char, Value)` | `ok` once the phone confirms; `{error, not_attached}` as for `set` |
| `reply(Req, ok \| {error, Code})` | `ok`: the answer goes to the write's link when `Req` names a write the registry handed to the caller and not yet answered; any other answer is dropped |
| `advertise(Service, Octets)` | `ok`: the service's payload is `Octets` from now on, until the caller's next `advertise` or its end, and an empty `Octets` takes it out of the advertising ([Advertising](#advertising)); `{error, not_allowed}` when the declaration reserves no payload, `{error, too_long}` past its maximum, `{error, not_attached}` as for `set` |

`Service` is one the grant names; `Char` one the declaration names. A
handler receives, through the envelope rule, which the client module
`erx_gatt` alone takes off ([design-domains.md](design-domains.md#the-funnel)):

| Event | Meaning |
| --- | --- |
| `{connected, Conn, #{level := L, bond := none \| Bond}}` | a phone connected, or its link's security changed: `level` is what the link reaches now, `open` until it is encrypted and then its key's, and `bond` is the id of the kept bond whose key encrypts the link, a resolved bond's or its own pairing's once kept, and `none` until then, so it is a bond's id exactly where the gate's `bonded` holds; the event carries no address |
| `{mtu, Conn, Mtu}` | the bearer's MTU changed; a notification carries at most `Mtu - 3` octets |
| `{subscribed, Conn, Char, none \| notify \| indicate}` | the phone wrote the characteristic's configuration |
| `{write, Req, Conn, Char, Value}` | a write the gate allowed; the handler answers `erx_gatt:reply(Req, ok \| {error, Code})`, where `Req` is a reference the registry made for this write, which names it to no other handler, link or write |
| `{disconnected, Conn}` | the phone left; `Conn` is dead |

The link takes the next request of its phone only after the handler
answered the last write request, so a handler sees one write request of a
link at a time, as ATT's sequential protocol has them; write commands
queue behind it, within `bt_write_queue`. For a write command the
handler's answer is awaited and dropped, so the queue is its pace. An
answer `{error, Code}` with `Code` from `0x80` to `0x9F` is the ATT
Application Error of that code; Value Not Allowed is `value_not_allowed`;
and `not_authorized` is ATT's Insufficient Authorization (Table 3.4),
the answer of a handler that knows the phone by its bond and does not
let that bond write; its code joins `att_error` in
`abi/formats/bluetooth.txt`. The gate decides what a level may
do; a handler decides, among the phones that reach it, which may do
what, and it can refuse only what it is asked: a read never reaches a
handler ([The attribute table](#the-attribute-table)), so what one
phone alone may read is sent to it as a notification on its `Conn`.
No answer within `bt_handler_timeout_ms`, 5 s, is Unlikely Error (`0x0E`). A service with no
handler serves reads from its values and answers writes Unlikely Error.

`connected` and `disconnected` come from the registry, which monitors
every link: so every handler of a link's services hears of its end,
however the link ended, while the registry lives. A registry that ends,
by its own crash or the store's before it, ends the domain
([Concurrency](#concurrency)), so every facet ends with the mint and
every handler stops at its facet's end ([The client](#the-client)): no
handler outlives the registry that knew it, and its supervisor's
restart attaches through the facet the next incarnation mints.

#### The client

An app's code reaches the facet through three modules that run in its
own session, whose public functions the SDK lists
([design-packaging.md](design-packaging.md#the-sdk)):

* **`erx_gatt`**, the client, the one module that takes the events'
  envelope off. `erx_gatt:attach(Service)` asks the facet; an answer
  `{error, attached}` it does not pass on at once but asks again every
  `bt_attach_retry_ms`, 50 ms, until `bt_attach_wait_ms`, 5 s, has
  passed since its first ask, and only then answers `{error, attached}`;
  every other answer it passes on as it comes. Nothing tells a
  would-be handler that a previous one's end has reached the registry,
  which happens inside the Bluetooth domain, so the one that wants the
  service asks again, and the deadline is the bound on how long that
  end may take. The previous handler may be the same app's previous
  session's, after a restart or an update, or another app's, after a
  removal freed its services and this app was installed; both are ended
  sessions, so the end arrives. A second process of the same session
  that attaches a service its sibling holds meets no end and gets
  `{error, attached}` at the deadline: a service has one handler, and
  an app gives it one process. `set/3`, `notify/4`, `indicate/4` and
  `advertise/2` make the facet's operations and answer theirs, except
  `{error, not_attached}`, at which they exit the calling process with
  `{not_attached, Service}`: the caller is no longer the service's
  owner, and only an attach makes it one.
* **`erx_gatt_service`**, a behaviour whose process is one service's
  handler. `erx_gatt_service:start_link(Service, Module, Args)` answers
  `{ok, Pid}` at once, since a session's grants are installed only
  after its start has finished and it has reported ready
  ([design-system.md](design-system.md#waiting-for-a-grant)). The
  handler then waits for its grant, `erx_facets:await(ble, none,
  infinity)`, attaches through `erx_gatt:attach/1`, calls
  `Module:init(Args)`, which answers `{ok, Values, State}`, and sets
  each characteristic of `Values`, a map from characteristic to value,
  before it takes any event; an attach that fails ends it with the
  answer, `{error, attached}` past the deadline among them, so the
  app's supervisor restarts it within its intensity. A write is
  `Module:handle_write(Conn, Char, Value, State)`, whose `{Answer,
  State}` is the write's reply, `ok` or `{error, Code}`; every other
  event of the table above is `Module:handle_event(Event, State)`,
  answering `{ok, State}`; `erx_gatt_service:call(Server, Request)` is
  `Module:handle_call(Request, From, State)`, answering `{reply, Reply,
  State}`, and any other message `Module:handle_info(Info, State)`,
  answering `{ok, State}`. The callbacks run in the handler's process,
  so their calls of `erx_gatt:set/3`, `notify/4` and `indicate/4` come
  from the owner, and another process of the app reaches the service
  through `call/2`. The handler monitors the facet and stops with
  `{facet, Reason}` when it ends: the Bluetooth domain's restart takes
  the registry and every attachment, and a handler that only listens
  would otherwise hear nothing more; its supervisor's restart attaches
  through the facet the new incarnation mints.
* **`erx_gatt_serial`**, the serial service over `erx_gatt_service`
  ([For apps](#for-apps)): `erx_gatt_serial:start_link(Service, Owner)`
  starts the handler of `Service`, a declaration of the UART
  service's shape, an `rx` written and a `tx` notified, `nus` among
  them, for attaching and notifying, registered in the session under its module's
  name, which sends `Owner` `{serial, Conn, Bytes}` messages,
  `{serial_lost, Conn}` where it dropped a write's bytes
  ([For apps](#for-apps)), and the `connected`, `subscribed` and
  `disconnected` events; `erx_gatt_serial:send(Conn, Bytes)` calls it.

A holder of the control tree needs no facet, only files: it opens
`/svc/bluetooth/pair` for reading and writing, an app with
`file:open/2` and a system command through `erx_svc_client:open/3`, the
one way a system command opens a file under `/svc`, writes the
window's mode and reads its lines
([The pairing window](#the-pairing-window)). One more module of the
client application, **`erx_bt_pair`**, owns the grammar of the tree's
lines in both directions, and the reading of them:

* **One bond record.** A bond is named in the tree by one record, the
  term `#{id := Bond, address := Address, type := public | random,
  level := authenticated | unauthenticated}` and the text `BOND
  AA:BB:CC:DD:EE:FF TYPE LEVEL`, `BOND` its 32 hexadecimal digits.
  `format_bond/1` and `parse_bond/1` are its one formatter and its one
  parser. A line of `bonds` is a record, and a window's `bonded` line
  is the word `bonded` and a record, composed and parsed by the same
  two functions, so the list and the event cannot disagree on a field.
* **The window's lines.** `format/1` is how the window composes each
  line, and `parse/1` turns one line into a term: `{wait, N}`,
  `waiting`, `{passkey, Digits, Address}`, `{bonded, Record}`,
  `{failed, Address, Reason}`, `{closed, timeout}`, or `invalid` for
  anything else.
* **Bounded reading.** A reader takes the tree's files only through
  `erx_bt_pair:next/1`, over the reader `erx_bt_pair:reader/1` makes of
  a file opened for reading in binary mode, which reads with a count of at most
  `bt_pair_line_max + 1` octets and holds at most that many octets that
  do not yet end a line. When it holds `bt_pair_line_max + 1` octets
  with no newline among them it answers `overlong` and reads no more,
  and the reader closes the file: `btpair` prints `[invalid]` and ends
  with a failure status, and an app treats it as the end of the window
  or of the list. `bt_pair_line_max`, 128, is a limit of
  `abi/formats/bluetooth.txt`; the longest line the window composes,
  `bonded` with a random identity and an unauthenticated level, is 80
  octets. A read of `bonds` that yields more than `bt_bonds_max`
  records is refused the same way. So what another domain writes costs
  a reader a bounded buffer whatever it sends, and only a compromised
  Bluetooth domain ever sends a line that long, so ending is the
  recovery. `erx_bt_pair:bonds/1` reads a whole `bonds` file through
  `next/1` and answers `{ok, Records}`, `invalid` for a line that is no
  record, or `overlong`. A read that gives no octet or more than it
  asked answers `{error, einval}`, and a file that ends inside a line
  `{error, truncated}`; the reader closes the file after either.

What a reader parses is another domain's bytes, so `next/1`,
`parse/1` and `parse_bond/1` have a fuzz target, and an app that shows
a passkey shows the digits of a parsed line and never the line. The
`bt` release ships the client application for `format/1` and
`format_bond/1`, so the two directions cannot drift.

`bt_attach_retry_ms` and `bt_attach_wait_ms` are limits of
`abi/formats/bluetooth.txt`, beside `bt_handler_timeout_ms`. That the
end of a handler in another domain reaches the registry within 5 s is
unverified, as the monitor's firing itself is
([todo-bluetooth.md](todo-bluetooth.md)); the Bluetooth suite's restart
and removal cases settle it.

### Links: the fixed channels

A link process reassembles L2CAP B-frames from the ACL packets of its
handle, as HCI 5.4.2's packet-boundary flags mark them, and refuses a
frame longer than its channel's bound, a continuation without a start, a
start inside a frame or bytes past a frame's length, which ends the link
(`erx_l2cap`). Channel `0x0004` is the ATT bearer; `0x0006` is SMP; on
`0x0005`, LE signaling, it answers Command Reject, "Command not
understood", to every command but a response, and drops responses:
erXos asks no connection parameter update and offers no credit-based
channel. A signaling frame longer than MTUsig, 23 octets, is answered
Command Reject, "Signaling MTU exceeded", with 23, as L2CAP 4 requires,
rather than ending the link; one too short to carry a command, or whose
Data Length disagrees with it, is not correctly formed (L2CAP 4) and is
dropped. A frame on any other channel is dropped and counted.

### The link's messages

`erx_bt_link_core:step(Input, Now, Core) -> {Actions, Core}` is the
link's pure core, and `next_deadline/1` its earliest deadline: a
handler's answer, `bt_handler_timeout_ms`, 5 s; an indication's
confirmation, `att_transaction_timeout_ms`, 30 s (ATT 3.3.3); a
pairing's step, `smp_timeout_ms`, 30 s (SMP 3.4); the next look at the pairing wait
before a Security Request ([Reconnection](#reconnection)). The link
process reads the clock, keeps one wake-up at that deadline and steps
`expired` when it fires.

**A link's pid is its address, and the runtime reports its end.** Every
message to a link is `{Role, Input}`, sent to its pid, but for the
registry's notifications, which are requests (below); every message
from it is `{erx_bt_link, Link, Message}`, sent to the owner's
registered name, where `Link` is the link's pid, and for the controller
process, which maps its core's names to links, the link's name
([The controller process's effects](#the-controller-processs-effects)).
An owner that keeps a link's pid past one answer monitors the link from
the moment it takes the pid, and acts on the link's end at the
monitor's `'DOWN'`:

| Owner | Monitors a link | At the link's end |
| --- | --- | --- |
| the controller process | from `link_up` | disconnects the handle |
| the registry | from the link's `join` | tells the handlers `disconnected`; `Conn` answers `{error, gone}` from then on |
| the window | from its `open` verdict until the link reports the pairing failed or hands its bond to the store (`keeping`) | counts the pairing failed, `disconnected`, for the pairing wait, and writes `failed ADDR disconnected` if the window is still open |
| the store | from a `resolve` it answers with a bond, or a `keep` it answers `ok` | drops the link |

So no owner learns of a link's end from the link. A kill, the shutdown
that `link_down` gives, a raise in `step/3` and the controller group's
restart all reach every owner that holds the pid, and the link traps no
exits and has no `terminate/2`. An alias would not do: no process can
monitor one, and the pid already dies with the link. A link monitors no
owner: the store, the registry and `erx_bt_fs` start before the
controller group under `erx_bt_sup`, `rest_for_one`, so each outlives
every link, and the end of one ends the group after it
([Concurrency](#concurrency)).

**The core is the one table of who sends what.** `Role` is `hci`,
`window`, `registry` or `store`. The core's `input()` is keyed by it, and
so is its `action()`, the controller process's included (`{hci, {send,
Boundary, Data}}`): the link process steps each message as it arrives
and sends each action `{Role, Message}` to that role's owner, so the
core's clauses are the only list of what each owner may send, and the
process keeps no copy of it, nor of any core state. A message no clause
takes is a defect of the domain's own code and ends the link through
`step/3`'s raise. The role is a label, not a proof: only the domain's
own processes reach a link, and a peer's bytes reach it only as the
controller process's `acl`.

**The link's start.** `erx_bt_link_sup:start_child/1` is a synchronous
call of the controller process, so `init/1` reads only its argument and
nothing in it can fail: the link's name and `Conn`, the controller
process's pid and, from `link_up`'s `Info`, the phone's address, which
`erx_hci` decodes as `{public | random, Address}`, the identity address
the controller advertises with, `acl_tx_max` and the share. `erx_hci`
reads LE Connection Complete's Status first: a failed one carries no
valid parameter but its Status (HCI 4.5.1, Table 4.1), so it decodes as
`{le_connection_complete, {failed, Status}}` with nothing after the
Status read, whatever those octets hold, and the controller core takes
it as no connection. Only a successful one is read further, and there a
Peer_Address_Type other than `0x00` and `0x01` is reserved (HCI
7.7.65.1), so `erx_hci` decodes it as malformed, as it does a reserved
handle, and the controller process ends as for any malformed event: a
controller's breach of HCI, not a start that fails. The controller
process's `{ok, Pid} = start_child(...)` therefore holds. Then, before
its first step, the link makes its only two calls, each to an owner
that never waits on a link:

1. `erx_bt_store:resolve(Address) -> none | Bond`. The store resolves
   the address against the bonds ([Reconnection](#reconnection)) and
   answers the one bond it names, with its id, LTK, level, identity,
   table hash and subscriptions and without its IRK, so no other bond's
   key leaves the store. A store left `unknown` by its start's read
   holds no bonds and answers `none`; one `unknown` after an unconfirmed
   `put` answers from the bonds it holds, so bonds already kept work on a
   trial boot (below). The
   address names a candidate, not a proven bond: what of the bond the
   link may use before its encryption is the key alone (below).
2. `erx_gatt_srv:join(Conn, #{address := Address}) -> #{table := Table,
   values := Values, handlers := Handlers}`. The registry maps `Conn` to
   the link, tells the services' handlers `connected` at level `open`
   and with no bond, as every link starts, keeps the address for
   `/proc/bt` alone, and answers the table, the
   values the current handlers set and each served service's handler or
   `none`. It takes `join`, `set` and every change of a handler in one
   order, so every `set` and every `{handler, ...}` after what it
   answered reaches the link.

`erx_bt_link_core:new/1` builds the core from these. What the controller
process sends meanwhile waits in the mailbox, within the link's backlog
([Commands and data credits](#commands-and-data-credits)), and is
stepped in order after. A call that fails, or is not answered within
OTP's 5 s default, ends the link, and the phone reconnects.

**A link is its bond's only from its encryption.** An address is
whatever the peer sends: a public address is copied by anyone, and a
resolvable private address resolves for whoever repeats it, since `ah`
is computed from the address's own random part and the IRK alone (SMP
2.2.2). Only the key proves the bond, since a central must hold the
LTK to set up an encrypted session with it (SMP 2.4.4.2), which is the
same fact the gate rests on. So the core holds a resolved bond in two
parts. The key it holds from its start: it answers the Long Term Key
Request and gives the gate its column, so an `encrypted` access answers
Insufficient Encryption and the phone knows to encrypt (ATT 3.2.5). The
rest, the bond's subscriptions and table
hash, enters the core only at the transition that sets `encrypted`
([One table, one gate](#one-table-one-gate)): there the link restores
the subscriptions, tells the registry `bonded`, and may indicate
Service Changed ([Reconnection](#reconnection)). Every store write for
a bonded link, `subscriptions` and `served`, is made from that rest, so
a link not yet encrypted has nothing to send one from, and a peer
without the key never changes a bond's kept state. A pairing's bond is
made over its link encrypted with the pairing's key (SMP 2.4.3.2), so the
same holds for it. A configuration
write is a write of that state, which GATT lets a server guard (GATT
3.3.3.3: "Authentication and authorization may be required by the
server to write the configuration descriptor"): on a link that holds a
key, the descriptor's write requires at least `encrypted`, so until the
link is encrypted the gate answers it Insufficient Encryption, as it
answers any `encrypted` access there, and the configuration stays the
link's default.

No setting says whether a link may pair. Every link runs its Security
Manager, and the window decides: its verdict is `closed` while no window
is open, and no window opens while the start's read has left the store
`unknown` ([Refusals](#refusals-and-error-results)), so a domain running
without bonds refuses every Pairing Request with Pairing Not Supported
through the verdict, and a pairing whose store fails it later fails
`unavailable` ([Bonds and the store](#bonds-and-the-store)). Before
stage 4, which brings the window, the link's Security Manager is
disabled and answers so itself.

**The messages.** Each row names the consumer that needs the message.
LE Connection Update Complete goes to no link: erXos asks no parameter
update and new parameters change nothing, so the controller process
takes it and forwards nothing.

| From, to | Message | When | Consumer, and what breaks without it |
| --- | --- | --- | --- |
| controller process, link | `{acl, Boundary, Data}` | an ACL packet of the link's handle | reassembly; no channel works |
| | `{completed, Count}` | the controller sent `Count` of the link's packets | the link's share; once used up, nothing more is sent |
| | `busy` | the controller's core counted the link past its share | the link ends, since its count of packets outstanding is wrong |
| | `{le_long_term_key_request, Handle, Rand, Ediv}`, `{encryption_change, Status, Handle, Enabled}`, `{encryption_key_refresh_complete, Status, Handle}` | the controller's reports for the handle, as `erx_hci` decodes them (HCI 7.7.65.5, 7.7.8, 7.7.39) | the one key's transition ([One table, one gate](#one-table-one-gate)); nothing encrypts |
| | `{ltk_reply_complete, ok \| {failed, Status}}` | the controller answered the link's `ltk_reply` | a Reply that failed counts as none |
| link, controller process | `{send, Boundary, Data}` | while the link's packets outstanding are below its share | the writer; nothing reaches the phone |
| | `{ltk_reply, Ltk \| none}` | at each Long Term Key Request | Reply, or for `none` Negative Reply (HCI 7.8.25, 7.8.26); the phone's encryption never completes |
| | `taken` | with the step of every message the controller process sent | the link's backlog ([Commands and data credits](#commands-and-data-credits)); without it the controller's messages would wait in the mailbox without bound |
| link, window | `{admit, Tag, Address}` | a Pairing Request | the window's verdict; at `open` the window monitors the link |
| | `{passkey, Tag, N}` | Passkey Entry made its passkey | the `passkey` line; nobody can type it |
| | `{outcome, Tag, {failed, Reason}}` | the pairing the link last sent to admit failed before `keeping`, its verdict still on its way included | for the pairing the window opened, the `failed` line and the pairing wait; the window then drops its monitor. Without it every failure would end as `disconnected`. For a pairing it refused, nothing ([The pairing window](#the-pairing-window)) |
| | `{keeping, Tag}` | the link handed the pairing's bond to the store, in the step that sends `keep` | the window drops its monitor and takes the store's `outcome` as the pairing's; without it a link that ends while the store writes would count a kept bond as failed |
| | `wait` | a link holding a kept bond's key, at its start and at the deadline the last answer set | the Security Request ([Reconnection](#reconnection)), which SMP 2.3.6 holds to the pairing wait |
| window, link | `{admission, Tag, Verdict}` | at once, for each `admit` | the Security Manager |
| | `{withdraw, Tag}` | the window closes while the link runs its pairing, before its `keeping` | Pairing Failed, Unspecified Reason, and the outcome `withdrawn` ([The pairing window](#the-pairing-window)); after the link sent `keeping` it changes nothing |
| | `{wait, Ms}` | at once, for each `wait` | at `0` the link sends the Security Request unless the phone has begun encryption; otherwise it asks again `Ms` later |
| link, registry | `{write, Ref, Key, Value, Handler}` | a write the gate allowed; `Handler` is the service's handler as the link knew it when the write's first byte arrived | the service's handler, which the registry hands it under a fresh `Req` when it is `Handler`, and otherwise answers Unlikely Error; without `Handler`, bytes a phone sent while one app owned a service could reach the next ([A service belongs to its handler](#a-service-belongs-to-its-handler)) |
| | `{subscribed, Key, none \| notify \| indicate}`, `{mtu, Mtu}` | the phone wrote a configuration; the bearer's MTU changed | the handlers' `subscribed` and `mtu` |
| | `{security, #{level := L, bond := none \| Bond}}` | the link's level changed, or it became a kept bond's | the handlers' `connected` |
| registry, link | `{answer, Ref, Answer}` | the handler answered the write `Ref` | the write's response; an answer to a write no longer awaited changes nothing |
| | `{set, Key, Value}` | a handler set a value | reads return it |
| | `{handler, Service, Handler \| none}` | an `attach` of the service, or its handler's end | the service's owner as later writes carry it; the link serves the service's declared values and drops its notifications still waiting for credits. Without it a removed app's values and queued notifications would stay before its successor's phones |
| | `{notify, notify \| indicate, Key, Value}`, a request of `gen_server:send_request/2`, answered `ok \| {error, Reason}` | a handler's `notify` or `indicate` | the registry answers its own caller from the answer, and the request's monitor makes a link that ends first answer `{error, gone}`; a caller's `From` passed to the link would wait for nothing when the link ends |
| link, store | `{keep, Tag, Bond, Subscriptions}` | the pairing's third phase ended | the store keeps the bond, tells the window the outcome and, at `ok`, monitors the link ([Bonds and the store](#bonds-and-the-store)) |
| | `{subscriptions, Subscriptions}` | a link encrypted with a kept bond's key changed a configuration | GATT 3.3.3.3: the Write Response waits for the store's answer |
| | `{served, Hash}` | a link encrypted with a kept bond's key had Service Changed confirmed | the bond's table hash; not answered, since a hash not kept costs one more Service Changed |
| store, window | `{outcome, Link, Tag, {bonded, Bond, Identity, Level} \| {failed, Reason}}` | the store answered the `keep` of `Link`, the pid it came from | the `bonded` or `failed` line and the pairing wait |
| store, link | `{kept, {ok, Bond} \| {error, Reason}}` | the store answered `keep` or `subscriptions` | for `keep`, at `{ok, Bond}` the key is the kept bond's, whose id the link's next `security` carries, otherwise the link ends; the configuration write's response or Unlikely Error |
| | `forgotten` | the link's bond is forgotten, or missing from the state read after a `put` left unconfirmed | the link ends ([Bonds and the store](#bonds-and-the-store)) |

**A pairing's outcome has one ordering point: the link's step that ends
its third phase.** Before that step the pairing is the link's: a
withdrawal or the link's end fails it, and no key reaches the store.
In that step the link sends `keep` to the store and `keeping` to the
window, and from it the pairing is the store's: the link's Security
Manager is done, so a withdrawal that arrives later changes nothing,
and the store's answer to `keep` is the outcome, which it sends the
window whether or not the link still lives. The window learns which
side of the step a link's end fell on from the link's own messages,
since a process's messages reach the window before the `'DOWN'` its end
gives: `keeping` then `'DOWN'` is a pairing the store decides,
`'DOWN'` alone one the link's end failed. So the outcome the window
counts and writes is the store's own answer to `keep` whenever the
store was asked, and a pairing the window counts failed before that
step never reached the store; a `put` left unconfirmed is the store's
`unavailable`, with what follows it there. The window matches each
outcome by the link and its tag. The store's outcome and the link's
`keeping` come from two processes and reach the window in either
order, so the window takes the outcome before `keeping` as after it:
a link sends `keeping` or a failure for a pairing, never both, so an
outcome that comes first never meets a second one from the link.

The store finds the bond of `subscriptions` and `served` by the link it
monitors, and `kept` carries no tag because a link asks the store one
thing at a time and the store answers every request
([Bonds and the store](#bonds-and-the-store)), so a link never
abandons one and no late answer can meet a later request: a pairing's
`keep` comes only from a link without a kept bond's key and
`subscriptions` only from one encrypted with it, and a configuration
write, request or command, waits for the store's last answer as a
write request waits for its handler. The link process takes
the registry's request in `handle_call/3` and steps it as `{registry,
{notify, From, Kind, Key, Value}}`; the core answers `{reply, From,
Answer}` when the notification is queued or refused, or the indication
confirmed or timed out.

The link answers a Long Term Key Request with Reply only when it holds
a key and the request carries zero EDIV and Rand. A Reply the
controller answers with a failure counts as no Reply, so the link's
next report about encryption ends it: HCI 7.8.25's Status says only
that the command failed, not whether the controller kept the key, and
ending the link is the reading that never takes an unconfirmed key as
the link's. A step's actions end at its first `{close, Reason}`, after
the packets it hands over, and what is still queued is dropped with the
link, whose end disconnects it. A link with a key
passes the window's `open` verdict to the Security Manager as `bonded`,
so its pairing fails. The core's `key` and Security Manager state, and
the bond in `resolve`'s answer and in `keep`, hold secrets; the link
process shows `erx_bt_link_core:facts/1`, which holds none, in crash
reports and `/proc`, and ends with a reason built from it alone when
`step/3` raises, since a stack trace carries the core.

## Stage 3: the serial service

### For apps

`abi/gatt/nus.txt` (above) declares the service, and `erx_gatt_serial`,
a library over the facet, turns it into a byte stream for each phone:
`rx` writes, each `{write, ...}` answered at once, become `{serial, Conn,
Bytes}` messages to the app, and `erx_gatt_serial:send(Conn, Bytes)`
cuts the bytes into notifications of at most `Mtu - 3` octets on `tx`,
returning once all are queued; a notification the link's full queue
refuses `busy` is asked again until the queue takes it, for at most
`bt_handler_timeout_ms`, after which `send/2` answers `{error, busy}`.
A write that finds the owner's queue holding `bt_write_queue` messages
or more is answered the Application Error `0x80` and its bytes are
dropped, so a phone cannot grow the owner's queue without bound; the
owner is sent `{serial_lost, Conn}` in their place, once for each run of
drops, so it always knows where its stream has a gap. A phone that
writes faster than the link hands its write commands on, which nRF-style
terminal apps send, loses its link past `bt_write_queue`
([What a radio peer can make the domain spend](#what-a-radio-peer-can-make-the-domain-spend)),
and the owner hears `disconnected`. So the stream never loses bytes
without saying so: a gap is a `serial_lost` or the stream's end.

### The console

**`bleuart` gives a phone root's shell.** A BLE client that connects to
the machine and opens Nordic's UART service gets a tty of root's session
with the command shell on it, as an SSH client's channel gets one: rc's
prompt, root's files and commands, and `Ctrl-C` and job control through
the tty's line discipline. It never gets the console's `Ctrl-G` menu,
and never the system shell. There is no login, no pairing and no bond.
The service is `nus` as declared above, with `open` accesses, so every
phone terminal app for Nordic's UART service works unchanged.

**The construction: `bleuart` is an SSH channel without the login.**
Each part exists already. An app shaped as `ntpd` is, a principal with
a session template, its facet rows and a `start` row
([design-time.md](design-time.md#configuration),
[design-apps.md](design-apps.md#the-start-table)), runs the code. The
`ble` facet and `erx_gatt_serial` give it the client's byte stream
([For apps](#for-apps)). The session line `tty_line` gives it a tty of
another session, through which an SSH connection's channels master
ttys ([design-ssh.md](design-ssh.md#sessions-ttys-and-shells),
[design-system.md](design-system.md#a-sessions-lines)). What `bleuart`
lacks is the login that hands an SSH connection its line. It takes
instead the session the console logs `root` in to at boot in a
development build ([design-live.md](design-live.md#the-console)), whose
line the host link's `web` facet already hands the web domain with no
login (`erx_hostlink_web:root_line/2`,
`erlang/apps/erx_uart/src/erx_hostlink_web.erl`), through the one
operation of its login grant, `root_line`
([design-login.md](design-login.md#operations)):

```text
 phone --- radio --- bt: ATT, nus --- ble facet --- bleuart's session: erx_bleuart
                                                        |  tty_line: open_tty, then
                                                        |  the tty's messages
                                                        v
                              root's session, the console's: a tty, its line discipline, rc
```

* **The app.** The Raspberry Pi 4's development manifest declares it as
  it declares `ntpd`:

  ```text
  principal bleuart
    ...
  session bleuart
    limits @limits.app
    runtime @artifact.emu
    release @artifact.bleuart
    args "..."
  facet bleuart_ble
    name "ble"
    grantee @session.bleuart
    service @service.ble
    services nus
  facet bleuart_login
    name "login"
    grantee @session.bleuart
    service @service.login
    line tty_line
    logins 1
    operations root_line
  start bleuart
    enable YES
    published_enable NO
  ```

  Its release, `bleuart`, ships `kernel`, `stdlib`, `erx`,
  `erx_bt_client` and `erx_bleuart`, whose process `erx_bleuart`, the
  owner of the `nus` handler, is the release's permanent application: its end ends the session, and
  the start row's supervisor starts it again within the row's
  intensity ([design-apps.md](design-apps.md#keeping-a-session)). The
  session holds no device, no file grant and no line of its own.
* **The line.** At its first client's connection `erx_bleuart` calls
  `root_line()` on its login grant, which answers `{ok, Line}`, the
  `tty_line` of the console's root session minted for `bleuart`'s
  domain, or `{error, unavailable}` while the console has no such
  session. It keeps the line for its life. The line ends with the
  console's session or with the login facet, and its end ends
  `erx_bleuart`, so the next session asks for the line of whatever
  session the console holds then. An `unavailable` leaves no row in the
  login service, so the process asks again at the next connection; the
  client it was asked for is sent, once it subscribes to `tx` and so can
  hear it, the one line `bleuart: root's session is not running` and
  nothing else.
* **A tty for each connection.** At each `connected`, `erx_bleuart`
  starts the connection's master, `erx_bleuart_channel`, linked, and
  calls `open_tty(Master, shell, <<>>, 0, 0)` through the line: a tty of
  root's session, 24 rows of 80 columns, with `abi/terminal.txt`'s
  default `TERM` and the command shell on it
  ([design-ssh.md](design-ssh.md#sessions-ttys-and-shells)). A tty's
  messages do not name the tty, so each tty has a master process of its
  own, as each SSH channel has. `erx_bleuart` keeps the connection's
  stream and hands its master each event; the master speaks the tty's
  messages ([design-live.md](design-live.md#the-tty), "Between domains")
  through the console's own master core, `erx_tty_master`, which checks
  every message from the tty. An event reaches the master only while the
  master's queue holds fewer than twice `bt_write_queue` messages; past it
  the event is a `serial_lost`, so no queue a phone fills grows past that
  bound. The headroom is for the writes `erx_gatt_serial` holds when a
  master's send reaches it, at most the `bt_write_queue` the link keeps
  unanswered, which it forwards while the master waits on that send:
  * **Input.** Each `{serial, Conn, Bytes}` is the master core's
    input, numbered `{tty_input, N, Bytes}` messages, in order, whether
    or not the client has subscribed to `tx`. A `{serial_lost, Conn}` ends the relay, as does a write
    before the tty names itself, which has no tty to go to: the master
    sends `tty_hangup`, which ends the shell, and takes nothing more of
    the connection, so for every drop `bleuart` and the Bluetooth domain
    see, the bytes after a gap never complete a command line the bytes
    before it began. The client's link stays until the phone
    disconnects, its writes reaching no tty, and the master sends it one
    constant line saying the shell has ended, as it does at the shell's
    own end and at a tty that fails a check.
  * **Output.** Each `{tty_output, N, Bytes}` is sent with
    `erx_gatt_serial:send(Conn, Bytes)` and answered `{tty_taken, N}`
    once `send/2` returns, `ok` or `{error, busy}`, so a phone that
    stalls past `bt_handler_timeout_ms` loses that output and stops
    nothing. Until the client subscribes to `tx`, which an attach
    replays for a client already subscribed, the tty's one output
    is held unanswered, so the shell waits and its first prompt reaches
    the client; the tty's resend each second changes nothing meanwhile.
  * **Size.** A client of the UART service has no way to report its
    size, so the master sends none, and `stty` changes the tty's, as
    at the UART.
  * **Hangup.** At `disconnected` the master sends `tty_hangup`,
    which ends the shell and its jobs, as a hangup ends a UNIX login's.
    The shell's own end ends the relay too: the line's report of how it
    ended, `{exited, Status}` or `{signaled, Signal}`, stops the master,
    and the connection's later writes reach no tty. A master's end, and
    so `erx_bleuart`'s, its domain's included, hangs its tty up, since a
    tty's relay watches its master. A link that ends for
    passing a bound, `bt_write_queue` among them, is a disconnect, so a
    gap the radio stack makes in the stream ends the shell rather than
    completing a different command
    ([What a radio peer can make the domain spend](#what-a-radio-peer-can-make-the-domain-spend)).
* **One client at a time** follows from the Bluetooth domain's
  connection limit, 1 by default
  ([The Bluetooth domain](#the-bluetooth-domain)): a second phone is not
  connected while one is. `erx_bleuart` counts no clients; a board whose
  row raises the limit gives each connected client a tty of its own, as
  SSH gives each channel one, within `tty_line_max_channels`.

**Radio bytes reach root's session as terminal input, never a
system-domain parser.** The Bluetooth domain parses the radio and hands
`bleuart` each write's bytes; `bleuart` passes them to the tty in root's
session's domain, where the tty's line discipline and the shell read
them, as they read an SSH client's keys. The system domain mints the
line at `root_line` and never carries or parses a byte of the stream
(B8); it holds no `ble` grant, which `ble_grant` refuses. What a program
writes reaches the phone unchanged, as it reaches the UART (V1 of
[design-live.md](design-live.md#invariants)): `bleuart` escapes and
filters nothing, since what shows the text is the phone's terminal app,
the operator's own terminal. Its lines of its own, the unavailable line
and the notices at a relay's end, are constant ASCII.

**Off means not advertised.** `bleuart`'s handler is attached while its
session runs, and the Bluetooth domain advertises `nus` only while it
has a handler ([Advertising](#advertising)). `service bleuart stop` ends
the session and its handler with it, and the Bluetooth domain
writes advertising data without the UART service at the controller's
next free command slot, and the controller uses the new data from the
advertising events that follow (HCI 7.8.7), which probe B-P7 checks on
the Pi 4 ([Advertising](#advertising)); `service bleuart start` attaches it again
and puts it back. Nothing restarts the Bluetooth domain, and no other
service or link changes. With `bleuart` off the machine still
advertises its name, so a scanner lists the machine but a terminal app's
list of UART devices does not. `service bleuart enable` and `disable`
set `bleuart_enable` in `/etc/start.conf`, which the next boot applies
([design-apps.md](design-apps.md#how-a-command-is-judged)).

**Where it is offered.**

* **A builder's own card**, the Raspberry Pi 4's development medium,
  runs `bleuart` at boot: its row says `enable YES`.
* **The published card**, packed from the same manifest, ships it off:
  the published medium's build packs the row's `published_enable NO` in
  `enable`'s place ([design-apps.md](design-apps.md#the-start-table),
  [design-packaging.md](design-packaging.md#the-apps-row)), and an
  administrator at the board's console turns it on with `service
  bleuart enable` and `service bleuart start`.
* **A release build offers none**: the manifest check refuses a `login`
  row listing `root_line` in a release manifest, so no release image can
  hand anyone the console's root session, whatever its other rows say,
  and erXos's release manifests carry no `bleuart` rows.

**Failure.** A crash of `erx_bleuart` hangs its ttys up and ends the
session, which its row starts again. `erx_bleuart` starts
`erx_gatt_serial` with `start_link`, so the end of either ends the
other: a restart of the Bluetooth domain, its registry's end included,
ends the facet, so the handler stops ([The client](#the-client)), and
`erx_bleuart` with it, which hangs every tty up, and the session's
restart attaches through the facet the new incarnation mints; no shell
outlives its client's link. The end of the console's root session ends
the line and so `erx_bleuart`. A boot whose read of `/etc/start.conf`
fails starts each row at its published default, so `bleuart` does not
start
([design-apps.md](design-apps.md#the-start-table), "A read that cannot
read the file").

**Security: a development-build limitation, published with the
development images.** On a development build with `bleuart` on, anyone
within radio range who connects to the machine's UART service gets a
root shell in the console's root session, without a passphrase, a
pairing or any other proof, and can do whatever that session can: read
and write root's files, run and stop root's programs, start sessions of
its own through them. The link is not encrypted, so anyone in range can
also read what the client types and what the shell writes. A client can
hold the machine's one connection, so that no other phone gets the
shell until it leaves. The system shell stays out of reach: a tty of the
line runs only the command shell, and only a login at a secure console
line opens the system shell (L7 of
[design-login.md](design-login.md#requirements)). The limitation is
published beside SSH's development keys
([design-ssh.md](design-ssh.md#the-ssh-domain)), not a residual:
`service bleuart stop` and `disable` turn it off, the published card
ships it off, and a release build has none.

**Tests.** Each with the seeded fault that proves it ran:

| Test | Passing case | Seeded fault |
| --- | --- | --- |
| relay (host) | `erx_bleuart` over a stub line and a stub `erx_gatt_serial`: a connection opens one tty with `shell`; each connection's bytes become its own tty's `tty_input` in order and its tty's output reaches its own client; a `serial_lost` sends `tty_hangup` and the bytes after it reach no tty; a burst of `bt_write_queue` writes while a send is pending reaches the tty whole and a master past twice that loses the shell, with a notice; output before `subscribed` is held and taken after it; `disconnected` sends `tty_hangup`; the shell's `exited` ends the relay; `unavailable` sends the one line at the subscription and opens no tty; a refused `open_tty` leaves no tty; the line's end ends `erx_bleuart` | `serial_lost` ignored, so the bytes after the gap continue the line; every event forwarded, so the master's queue grows past the bound |
| `serial_lost` (host) | `erx_gatt_serial` with an owner whose queue holds `bt_write_queue` messages answers the next write `0x80` and sends one `serial_lost` for a run of three such writes | the bytes dropped with no message |
| the link's queue (host) | `erx_bt_link_core` holding `bt_write_queue` write commands for a handler ends the link at the next and the registry sends `disconnected` | the command discarded and the link kept |
| advertising (host) | after `nus`'s attach the registry has sent one `advertising_changed` and `advertised/0` answers `nus`; after its handler's end it answers no service; a service that does not say `advertise` changes neither; `erx_bt_hci_core`, in its exhaustive exploration, writes LE Set Advertising Data with `{advertising_data, D}`'s bytes at its next free command slot while advertising, and two inputs before the slot frees write only the later; a controller process started after `nus`'s attach writes data with `nus` before it enables advertising | the registry's state changed at attach only, which keeps the UUID after the handler's end; the controller's ask at its start dropped (the restarted controller advertises without `nus`) |
| advertising under a paused controller (host), the registry with a controller process the test suspends with `sys:suspend/1` | a handler calls `advertise` 1,000 times with distinct octets and each call answers `ok`; the suspended process's mailbox then holds exactly one `advertising_changed`; after `sys:resume/1` the next LE Set Advertising Data the core writes carries the last octets, and a further `advertise` sends one more message | the registry sending at every change (the mailbox holds 1,000 messages); the mark cleared when the message is sent rather than at the controller's ask (the mailbox holds 1,000); the state sent in the message rather than fetched (the data written after the resume are the first octets) |
| `root_line` (host) | the login service answers the console's root session's `tty_line` minted for the grantee with the login facet as opening; with no console session it answers `unavailable` and keeps no row, so a second call is answered | the caller named as the opening, so the line outlives the grant |
| manifest (host) | the Raspberry Pi 4's development manifest packs; a `login` row listing `root_line` in a release manifest is refused; a `ble` grant to a template with no `start` row, or whose principal's `domains` quota is not 1, is refused; `nus` named by `bleuart` and by the `apps` row's `gatt` is refused | the release rule removed |
| Bumble (QEMU) | a cell whose manifest runs `bleuart` in the echo's place, since both handle `nus`: a Bumble central's scan shows the UART service; it connects with no pairing, subscribes to `tx`, reads the `% ` prompt, writes `echo hello` and a CR and reads `hello`; `Ctrl-C` interrupts a `top` on the terminal, which nothing else ends; it disconnects; it reconnects and gets a new prompt, and `ps` there lists no more shells than before, so the one it had is gone from root's session; after `service bleuart stop` a scan shows no UART service and after `service bleuart start` it shows it again | the disconnect ignored, so the master lives on with its tty and the old shell is still in root's session (leaving out only the `tty_hangup` proves nothing: the master's end hangs its tty up) |

The Raspberry Pi 4's checklist repeats the Bumble case with a phone's
terminal app on the development card, and checks on the published card
that a scan shows no UART service until `service bleuart enable` and
`service bleuart start` are typed at the board's console.

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
* fails, with Authentication Requirements, a request that does not ask
  for bonding or does not offer the phone's identity key, since such a
  pairing could leave no bond ([Bonds and the store](#bonds-and-the-store));
* checks the phone's public key on the curve, `y^2 = x^3 - 3x + b mod p`
  with both coordinates below `p`, in Erlang before any key agreement,
  and fails a key off the curve with DHKey Check Failed, as SMP
  2.3.5.6.1 requires; it refuses SMP's debug key with Invalid Parameters,
  and a key with the X coordinate of its own with DHKey Check Failed
  (2.3.5.6.1). The curve's constants, which the specification gives in
  Vol 2 Part H 7.6 (not fetched), come from OTP crypto's curve table,
  `crypto:ec_curve(secp256r1)`, so no copy of them is written down, and
  the check's test feeds a point with `y + 1`;
* makes a fresh key pair and, for Passkey Entry, a fresh six-digit
  passkey from `crypto:strong_rand_bytes/1` for every pairing (SMP
  2.3.5.6.3, 2.3.6);
* gives the link its key when the second phase computes the LTK, so the
  phone's encryption at the end of that phase uses it
  ([One table, one gate](#one-table-one-gate)), and takes the phone's
  identity in the third phase over the encrypted link; an identity
  address neither public nor static random fails with Invalid
  Parameters (3.6.5; Vol 6 Part B 1.3.2, 1.3.2.1);
* ends a pairing at 30 s without a step (SMP 3.4), and the link with it.

Before stage 4, the link answers every SMP command with Pairing Failed,
Pairing Not Supported, but the phone's own Pairing Failed, which is
never answered, and the reserved codes and empty PDUs the Security
Manager ignores in every phase.

### The pairing window

A window is an open fid of the control tree's `pair` file,
`/svc/bluetooth/pair` for every holder of the tree
([The Bluetooth domain](#the-bluetooth-domain)), opened for reading and
writing; any other open answers `eacces`, so a holder of a read-only
grant opens no window and keeps none from others. Opening it
while another window is open, or while the pairing a closed window
admitted has no outcome yet, answers `ebusy`, so the window process
awaits at most one pairing. The window process takes the store's state
at its start (`erx_bt_store:known/0`) and answers `eio` to every open
while the store is `unknown` since its start, which refuses every
change ([Bonds and the store](#bonds-and-the-store)). The store leaves
that state only by `forget all`, which a grant of the control tree asks
of it on a write to `ctl`, and that grant tells the window process the
confirmed answer; it enters that state only at its own start, which
restarts the
window process after it ([Concurrency](#concurrency)). A store
`unknown` since a put it could not confirm reads before its next
change, so a window still opens, and the store's outcome of that
pairing, `failed ... unavailable` when the read or the put fails, is
all the window needs of it. The opener writes one
line, `display` or `nodisplay`, at most 16 bytes, which opens the window
for `bt_pair_window_s`, 120 s, and reads lines that the window writes,
each ASCII the window composes from numbers and addresses alone:

| Line | Meaning |
| --- | --- |
| `wait N` | the window is open, and the pairing wait has `N` seconds to run |
| `waiting` | the window is open, the wait has passed, and the machine is bondable (GAP 9.4.3) |
| `passkey NNNNNN AA:BB:CC:DD:EE:FF` | type this passkey on the phone with this address |
| `bonded BOND AA:BB:CC:DD:EE:FF TYPE LEVEL` | a bond is kept: the word `bonded` and the bond's record, as `bonds` lists it ([The client](#the-client)): its id, 32 hexadecimal digits ([A bond's name is made with its key](#a-bonds-name-is-made-with-its-key)), its identity, the address with its type `public` or `random`, and its level `authenticated` or `unauthenticated` |
| `failed AA:BB:CC:DD:EE:FF REASON` | the pairing failed, with its reason ([Refusals](#refusals-and-error-results)) |
| `closed timeout` | the time ran out |

After `bonded`, `failed` or `closed`, the file ends. A read that finds no
line waits for one as a waiting request the window process keeps
([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
"Waiting requests"). Clunking the fid, or
the opener's end, closes the window at once, so no window outlives the
person who opened it, by construction of the file protocol's fid
lifetime ([design-files.md](design-files.md#fid-owners)). A window takes
one pairing: whatever its outcome, the window closes.

**Closing a window withdraws its pairing.** The authority to bond is the
opener's, so it ends with the window: when the fid is clunked, or the
opener ends, while the link still runs the pairing the window admitted,
the window withdraws it, and the link fails it with Pairing Failed,
Unspecified Reason (`0x08`) and reports `withdrawn` to the window
process, which counts it as a failure like any other for the pairing
wait and writes the log's record; the `pair` file has no reader by
then, so its line is never written. Closing the window is the
opener's one way to stop a pairing, for instance one whose `passkey`
line names an address the opener does not expect. A pairing withdrawn
after its second phase ends its link with the pairing's key, as every
failure does once a link has a key
([One table, one gate](#one-table-one-gate)); the key never reaches
the store. A pairing whose third phase the link ended before the
withdrawal reached it is complete: the opener's window was open when
the phone distributed its keys, the link has handed the bond to the
store, and the store's answer is its outcome, which the window process
counts and logs as for any other pairing
([The link's messages](#the-links-messages)). Closing a window and a
pairing completing race only at that one step of the link, and
whichever comes first decides. The window's time bounds admission only: once it has
admitted a pairing, it waits for that pairing's outcome, so a person
typing a passkey as the time runs out is not cut off. SMP's 30 s timer
bounds each step, not the pairing (3.4): a phone that steps just inside
it through Passkey Entry's some 45 PDUs holds the window, which answers
`ebusy` to other openers, for about 20 minutes, and the opener ends
that by closing the window. The link's `admit` carries the
number of its Pairing Request, and the window's verdict and withdrawal
carry it back, so a verdict or a withdrawal that arrives late, after
its request failed and the phone asked again, changes nothing
(`erx_smp_core`). The link's failure carries it too. A request can
fail, by the phone's Pairing Failed or the Security Manager Timer,
while its verdict is on its way, and the link, which cannot know the
verdict, reports that failure as it does any other; the window takes a
failure only of a pairing it opened, so the failure of one it refused,
`closed` or `waiting`, changes nothing.

**The pairing wait** is SMP 2.3.6's, kept by the window process and not
by any window, so whoever opens windows, and however fast, does not
shorten it. After a pairing fails, whatever the reason, the timeout and
the end of its link included, so that leaving halfway through Passkey
Entry's rounds is a failure too, no Pairing Request is answered for the
wait the failure imposes: `bt_pair_wait_min_s`, 2 s, for the window
process's first failure, and after that twice the wait the previous
failure imposed, halved for each whole `bt_pair_wait_decay_s`, 600 s,
since that failure, and kept between 2 s and `bt_pair_wait_max_s`, 64 s.
So the wait doubles at each failure up to 64 s and quiet brings it
down: after a 64 s wait the next failure imposes 64 s until 1200 s have
passed, and 32 s then. A success leaves it as it is. The window process monitors a link from its `open` verdict until
the link reports the pairing failed or hands its bond to the store, so
a link that ends first, however it ends, is a failure, `disconnected`,
and one that ends while the store writes is not
([The link's messages](#the-links-messages)). A request during the wait is answered Pairing Failed, Repeated
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

**Who opens a window** is who holds the control tree with the right to
write ([The Bluetooth domain](#the-bluetooth-domain)), and a device's
maker chooses among three openers by whom the manifest grants it:

| Opener | How | Mode |
| --- | --- | --- |
| a person at a shell: the console, SSH, the web client's terminal | `btpair display` or `btpair nodisplay` | either |
| the device's own app, on its screen | it opens `pair`, writes `display` and shows the digits of the `passkey` line; a settings screen lists `bonds` and writes `forget` | `display` |
| the device's own app, at a button | it opens `pair` and writes `nodisplay` when the button is pressed, and closes the file at the outcome | `nodisplay` |

The system opens no window by an act of its own, at first boot or ever.
An app that opens one at its start, for the minutes after a headless
box is powered on, does so by the grant its maker gave it, and the
window is that app's act. No app without the tree can open one, see a
passkey or learn a pairing peer's address, and no app with only a `ble`
grant needs to: its declaration states the level, the gate answers a
phone that has not reached it with the error GAP gives (10.3.1), and
starting the pairing is the phone's part. A handler learns of a
pairing only as its link's `connected` event, once the bond is kept.

**A window admits one pairing, in either role.** The window is the
administrator's consent to one pairing, and it is the same consent
whichever side starts it: a phone's Pairing Request, or, with the
central role, a pairing the machine starts on a link it made
([The central role](#the-central-role)). The first such pairing to
reach the window takes it, and the window closes at it, as it does for
a phone. A window does not choose the peer. What the administrator
sees instead is the peer's address, on the `passkey` line before any
key is kept and on the `bonded` line after, and a wrong bond is undone
with `forget`. Under `display`, a peer other than the one the
administrator meant fails, unless someone at that peer types the
passkey the machine shows; under `nodisplay`, the nearby attacker who
can pair during a window can do so in either role, which is the risk
`nodisplay` already carries (below).

**`btpair`.** The command shell has no redirection that opens one file
for reading and writing ([design-shell.md](design-shell.md#the-language)),
and a window is one open file, so a person drives it with a command:
`btpair display` or `btpair nodisplay`, an Erlang command of the command
shell ([design-shell.md](design-shell.md#commands)) that declares
`-erx_needs([bluetooth])`, as `reboot` declares `machine`. It opens `/svc/bluetooth/pair` through `erx_svc_client:open/3`, in
its own process, which sets no deadline, writes the mode, and prints each
line it reads, through `erx_bt_pair:next/1`, until the file ends; its
own end, an interrupt's included, closes the file and so the window. It
prints another domain's words, so it prints a line only after
`erx_bt_pair:parse/1` accepts it, composed again from the parsed
digits, addresses and words, and `[invalid]` for any other line; a line
past `bt_pair_line_max` prints `[invalid]` and ends it
([The client](#the-client)). The rest of the tree needs
no command of its own: `cat /svc/bluetooth/bonds`, and `echo forget
BOND > /svc/bluetooth/ctl` or `service bluetooth forget BOND`, which
writes the same line through `erx_svc_client:command/3`.

The `nodisplay` window makes Just Works bonds, unauthenticated: they
reach `encrypted` characteristics and never `authenticated` ones. A
nearby attacker can pair during such a window, which is why the level
is the declaration's to require and the window's to offer. A window
offers these two methods and no other: Numeric Comparison is not
offered ([Decisions](#decisions), 12), and a method that works
out of band waits for its design ([Decisions](#decisions), 3).

**Where the passkey is shown.** A `display` window's passkey reaches a
person only on the `pair` file, through whatever the opener holds the
control tree by: an administrator's session at the console, over SSH or
the web client, or an app the manifest grants the tree, which shows it
on a display it holds. Each is a channel the system already trusts to
manage the machine, and the passkey is fresh for each pairing; no
passkey is printed on a device or fixed in its configuration, since a
static passkey leaks over repeated attempts. A machine with no such
channel opens only `nodisplay` windows, so it serves `authenticated`
characteristics, Wi-Fi provisioning among them, to no
one; those wait for an out-of-band method of their own design, such as
NFC or a code the phone scans ([Decisions](#decisions), 3).

### Bonds and the store

A **bond** holds its id
([A bond's name is made with its key](#a-bonds-name-is-made-with-its-key)),
the phone's identity address, its IRK, the LTK, the
level, the table hash it was last served, and its subscriptions to
characteristics with `notify` or `indicate`. The stored **state** is the
identity address and at most `bt_bonds_max` bonds, encoded by `erx_bt_state`
in a form with a version, which refuses any other version and any
malformed or oversized input with a fuzz target, since what a store
returns is untrusted wherever a medium can be written. The store keeps
the whole state through one seam, taken with all its results:
`get() -> {ok, Generation, Blob | none} | {error, unavailable}` and
`put(Generation, Blob) -> ok | {error, too_large | unavailable}`, the
blob replaced whole. Every put names a **generation**, one above the
highest the store has read or put; `get` answers the blob of the
highest generation put, whatever order the puts completed in, or `none`
before the first, and the highest generation the store names, counting
every put that may still complete. So a put that completes after a
later one, as a put cut off by its deadline may (below), lands beneath
it and is never read, and no forgotten bond comes back that way. The
stores behind the seam answer with exactly these results:

* **in a development build**, files in the Bluetooth domain's
  directory on the data partition, one per generation, as the SSH
  domain keeps its host key before the vault
  ([design-ssh.md](design-ssh.md#host-keys)): a put of generation `N`
  writes `bonds.N.new`, created exclusively, syncs it, renames it to
  `bonds.N` and syncs the directory, whose fsync answers once the
  medium holds its entries
  ([design-files.md](design-files.md#the-file-protocol)), so the rename is
  on the medium before the put answers and before any deletion, then deletes every
  name of a lower generation; `get`
  answers `bonds.N` of the highest `N` and the highest `N` any name
  carries, `.new` included, `none` when no `bonds.N` exists and the
  directory or the volume it lies in does, an empty blob, which does not
  decode, when the newest file cannot be read, so `forget all` still
  learns the generation, and `unavailable` when the directory cannot be
  listed; a put answers
  `unavailable` when any step fails. A put renames only once its
  `.new` name has answered, so every put that may still land is
  counted by every listing made after its process ended. That rests on
  the files protocol's rename and exclusive `lcreate` each being one
  step, and on each tree making its requests atomic, so a listing
  shows every name an answered request made
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour));
  and, across a store restart, on the short-lived process of a dying
  store's backend call sending at most one more request, since the
  store's kill takes effect at that process's next receive;
* **in a release build**, the vault's state slot `{state, "bt"}`
  ([design-system.md](design-system.md#state-slots)), which must take
  the seam's generation: its `put` refuses a generation not strictly
  above the one it keeps, and its `get` answers the kept blob and
  generation, reflecting every put the domain sent before it. The slot
  as [design-system.md](design-system.md#state-slots) defines it takes
  no generation yet, a gap that blocks the release store; the release
  manifest check refuses a `bt` row whose store is the development one.

What `get` returns is untrusted wherever the medium can be written:
`erx_bt_state` decodes it, and a blob that does not decode is not a
state.

**Every call of the backend ends by a deadline.** Neither store behind
the seam promises to answer in any time: a vault checkpoint or a
storage domain may stall. So the store makes each `get` and `put` from
a short-lived process of its own that it monitors, and ends that
process at `bt_store_timeout_ms`, 5 s. A `get` not answered by then is
`{error, unavailable}`, and a `put` not answered by then is
unconfirmed, as any `put` that does not answer `ok` is (below): it may
yet complete, so the store becomes `unknown` and the next change reads
first. A put cut off may still complete inside the storage domain or
the vault after a later put; its generation, counted when it was made,
is below the later one's, so it never wins. Those are results the store
already takes, so the deadline adds no state. The store waits on
nothing else, so it answers every request
it takes, a pairing's `keep` and a link's `subscriptions` included,
within two backend calls, a read and a put, of reaching it; no link,
window or configuration write waits on the store without end, and none
keeps a deadline of its own for it. A link that starts while the store
waits on its backend may meet its own call's 5 s and end, and the
phone reconnects.

**The domain changes only a state it has read.** The store process
holds the store in one of three states: `read`, the state last read or
confirmed; `unknown` since its start, whose read gave no state; or
`unknown` since a put it could not confirm. At the start of the
Bluetooth domain it starts `unknown` and calls `get`:

| `get` answers | The store | The bonds | The identity address | Reason at `/proc/bt` and in the log |
| --- | --- | --- | --- | --- |
| `none` | `read`, empty | none | made now, kept by the first `put` | none |
| `{ok, Blob}` that decodes | `read` | the blob's | the blob's | none |
| `{ok, Blob}` that does not decode | `unknown` | none | made now, for this start only | `store_unreadable` |
| `{error, unavailable}` | `unknown` | none | made now, for this start only | `store_unavailable` |

A store that is `unknown` after the start's read refuses every change
until `forget all`, below, or the next start, which reads again: the
domain runs without bonds and refuses pairing, as it did before stage 4,
and the address made for this start is not the one a stored state may
name, so a later read could give bonds an address they were never
advertised under. A pairing, a bonded link's configuration write and
`forget` are the changes. Each puts the whole new state, built from the
state last read or confirmed, and goes on only from `read`; a store that
is `unknown` otherwise fails the change as the next paragraphs say and
is left as it was. So no ordinary change replaces a state the domain
could not read. The one write that does not start from a read state is
`forget all`: it puts an empty state with the identity address in use,
whatever the store holds, the explicit way past a blob that does not
decode, and a confirmed answer makes the store `read` and the address
kept. It calls `get` first, for the highest generation, which a start
whose read was unavailable never learned, and fails `eio` when that
`get` is unavailable; a blob that does not decode still names its
generation.

**Publication.** A `put` that answers `ok` is confirmed: the store holds
the new state and the domain's `read` value is it. Any other answer
leaves the change unconfirmed: the medium may keep the old blob or the
new, each complete, as for every change to the vault's files that fails
before its checkpoint answers
([design-system.md](design-system.md#the-vault), One owner per file),
and as for a development file whose rename may or may not have reached
the medium. The domain then keeps what it had, fails the change, and
sets the store to `unknown`, so the next change reads first and starts
from whichever blob the store kept; when that read leaves the store
`unknown` the change fails and the store stays so. A read that follows
an unconfirmed put replaces the bonds with the blob's, and a connected
link whose bond the blob lacks ends, as forgetting a bond ends it. The
identity address a stored blob names is the one in use, since the domain
made it or read it before any `put`. `too_large` takes the same path: the
encoder bounds a state to `bt_bonds_max` bonds, and a bond's
subscriptions name only characteristics of the table served when its
link made them, so the largest encoding is `bt_bonds_max` bonds each subscribed to every
characteristic the table lets a phone configure. A host test of
`erx_bt_state` encodes that state for the table every `abi/gatt`
declaration makes and fails when it passes the vault's 4 KiB, so a
declaration too large for it fails the build's tests and meeting
`too_large` for a state this domain wrote is a bug; a medium written
by other means can still hold a near-full state, and the change then
fails `unavailable`.

A pairing that completes asks the store to keep the new state, the
bond with the subscriptions its link has made so far, under the tag the
window admitted it by; the store tells the window its answer, which is
the pairing's outcome however the link has fared since
([The link's messages](#the-links-messages)). The store process draws
the bond's id in that step and hands it to `erx_bt_state`, which stays
pure. The bond is kept with no
table hash, since `keep` carries none, so the first reconnection
encrypted with its key indicates Service Changed once if the phone
subscribed to it ([Reconnection](#reconnection)). The link's key
is a kept bond's once the store answered `{ok, Bond}`, which `connected`
tells the handlers with the bond's id; the link's level does not wait on
the store ([One table, one gate](#one-table-one-gate)). A pairing whose
store is `unknown`, or whose `put` is not `ok`, fails `failed ...
unavailable`, its keys are discarded and the link ends. On a trial boot
both stores are read-only, since every file system mounts read-only
([design-storage.md](design-storage.md#system-updates)), so a `put`
fails `unavailable` there, pairing fails, and bonds already kept work.

**Pairing never replaces a bond.** A pairing whose phone turns out, at
its key distribution, to have the identity of a bond already kept fails
with `already_bonded`, its keys discarded; the operator ends a bond with
`forget BOND` written to the control tree's `ctl`, the id as its
`bonded` line and `bonds` show it, or `forget all`, and pairs again; a
bond is its whole identity, so a
public and a random address of the same octets are two bonds, each with
its id. A ninth bond fails with `bonds_full`; a device that must hold
more phones, a head unit's, asks for a larger `bt_bonds_max`, within the
state slot's 4 KiB.
Forgetting a bond ends its connected link: the store sends `forgotten`
to each link it monitors for that bond
([The link's messages](#the-links-messages)). SMP 2.4.3.2 holds a
distributed identity address valid only once a reconnection has used it
with the pairing's key; the same caution keeps a claimed identity from
ever overwriting a kept one.

**A bond is the machine's.** A bond is made with the machine, in a
window its administrator opened, and reaches every served service at
its level, whichever app handles it. A phone holds one key for one
peer, and its own system shows its user one device to pair with; a bond
that reached one app's services alone would leave the phone bonded,
refused by the other apps' services, and unable to pair again, since a
link with a key never pairs. So an `encrypted` access means a phone the
machine's administrator admitted, and what differs between phones is
what each handler allows each bond
([The `ble` facet](#the-ble-facet)). A machine whose apps do not trust
the phones of one another's users is not served by this
([Decisions](#decisions), 13).

**`bonds`** is the control tree's list of what `forget` names. It reads
as one line for each kept bond, in the order of their ids,

```text
BOND AA:BB:CC:DD:EE:FF TYPE LEVEL
```

the record a window's `bonded` line carries after its first word,
composed by the same function (`erx_bt_pair:format_bond/1`) from the state
the store last read or confirmed. It holds no key, and nothing a peer
chose but its identity address. While the store is `unknown` since its
start a read answers `eio`, never an empty list, which would read as a
machine with no bonds. It is what an app's list of paired phones reads;
an administrator's session also finds the bonds at `/proc/bt`
([Inspection](#inspection)).

A bonded link's subscriptions persist across connections, as GATT
3.3.3.3 requires: a write of a Client Characteristic Configuration that
changes it on a link encrypted with a kept bond's key is answered with
its Write Response only once the store has kept the new state, and a
store that is `unknown` or does not answer `ok` answers Unlikely Error
and leaves the configuration as it was. So a phone that saw its write
answered may rely on it after a power cut, Service Changed's
configuration included, which a change of the table at a later start
needs. On a link that holds a key and is not yet encrypted, a resolved
one or a pairing's between its second phase and the encryption, the
write is answered Insufficient Encryption and changes nothing, since
only the key in use proves whose configuration it is ([The link's
messages](#the-links-messages)). A write that changes nothing, and
every other write the gate allows on a link whose key is neither kept
nor being kept, is answered at once; one that comes
while the store keeps the link's pairing waits for the store's answer,
and is then kept as a bonded link's write is, so `keep` never leaves
out a subscription the phone saw answered; a Write Command to the
descriptor, which has no answer, changes the configuration where the
gate allows the write, and is then kept as a request's would be. ATT's
one request at a time and a bonded peer bound the store's writes.

### Reconnection

At its start the link asks the store to resolve the phone's address
against the bonds ([The link's messages](#the-links-messages)): an identity address by equality, a resolvable private address
by `ah` with each bond's IRK (SMP 2.2.2), whose form, top two bits `01`,
is Vol 6 Part B 1.3.2.2's, resolved as 1.3.2.3 describes. A resolved link holds
the bond's key from then on, and the transition of [One table, one
gate](#one-table-one-gate) encrypts it; in Secure Connections the Long
Term Key Request carries zero EDIV and Rand, and one that does not is
answered Negative Reply. A resolved link also sends a Security Request
(SMP 3.6.7) with the bond's authentication requirements, MITM set for
an `authenticated` bond, as soon as the pairing wait has passed, unless
the phone has already begun encryption, which SMP 2.4.6 forbids it to
interrupt: a bonded phone that only waits for its notifications is
thereby asked to encrypt, rather than left waiting. Until it does, the
link is not yet its bond's ([The link's messages](#the-links-messages)):
it has the default configuration and no subscription, refuses a
configuration write with Insufficient Encryption, and sends no
notification. At encryption the link becomes the bond's: the registry
tells the handlers with `connected`, now `bonded`, and the link
restores the bond's subscriptions. Then, when the bond's table hash
differs from the table's and the phone subscribed to Service Changed,
the link indicates Service Changed for `0x0001` to `0xFFFF` (GATT
2.5.2) and, at the confirmation, records the new hash. So neither the
subscriptions nor the hash a bond keeps change at the word of a peer
that only copied its phone's address.

## Later stages

### Wi-Fi provisioning

A phone gives the machine a network's name and passphrase over an
`authenticated` characteristic, so credentials never cross the air in
clear or to a peer who saw no passkey. The Bluetooth side is a
declaration and an app, with nothing new below them. The app derives
the network's PMK and hashed values as the session's `wlankey` does and
hands them to the vault's `{wpa, Service}` purpose through a
`wpa_admin` facet of its own session template, never to the WiFi
domain, and no state slot of Bluetooth's holds them
([design-wifi.md](design-wifi.md#credentials)). Its `authenticated`
characteristic needs a passkey shown through a trusted channel, so a
machine with none waits for an out-of-band method
([Decisions](#decisions), 3).

### The central role

A central scans, connects and is a GATT client. It has two users, the
HID function inside the Bluetooth domain ([HID over GATT](#hid-over-gatt))
and apps ([Apps as centrals](#apps-as-centrals)), which stand on one set
of parts and one rule.

**The parts.** The controller process gains passive and active scanning
(LE Set Scan Parameters and Enable), an advertising report decoder with
a fuzz target, and LE Create Connection. A link gains the GATT client, a
pure state machine over the same codec, explored exhaustively. Pairing
as initiator shares `erx_smp_core`'s checks and runs only in a window,
as a responder's does, and takes the window as a phone's pairing does
([The pairing window](#the-pairing-window)). A link the machine made
serves the table to its peer through the gate, as every link does, and
connections of both roles count against the `bt` row's one limit.

**A connection goes only to a device that matched.** The controller
process writes LE Create Connection only for an address it has just
heard advertise a service the connection's user may use, matched as a
scan matches (below), or, for a reconnection to a bond, through the
filter accept list of bonded identities. Nothing a user names reaches
the controller as a target unless the air confirmed it within the same
request, so no user can turn the machine's central role on a device
outside its services.

**One declaration for both roles, one gate for both directions.** A
service the machine uses on another device is declared in the form and
the directory of one it serves, `abi/gatt/NAME.txt`, and each word of
the declaration reads from the other side. The UUIDs are what the client
looks for. A characteristic's maximum is the longest value the client
accepts. Its accesses are the operations the client may make. Each
access's level is what the link must reach before the client makes it,
or takes what it brings. And `advertise`, `data` and `manufacturer` say
what a scan matches, as they say what a server advertises. The client
calls the gate, `erx_gatt_gate:check/2`, before it sends a request and
before it hands on a notification or an indication. From that:

* **No user of the client takes a peer's data over a link weaker than
  its declaration asks for.** The reconnection attack on clients, BLESA
  ([Attack classes](#attack-classes)), is closed by the gate and not by
  each user's care: the HID function's rule that nothing is asked or
  taken before encryption with a bond's key is this gate at `bonded`.
* **A user never sees a handle or a UUID.** Discovery is the link's: at
  connection it finds, by UUID, the declared services its users named
  and the handles of their declared characteristics, and keeps nothing
  else of the peer's table. So a hostile peer's table can make the link
  hold only what the declarations name.
* **A value is bounded by its declaration.** One longer than its
  declared maximum is refused and counted, never delivered.
* **What can be named at all is an allow-list.** The generator refuses
  a declaration of the HID service's UUID, as it refuses GAP's and
  GATT's own ([Declarations](#declarations-abigatt)), so no grant can
  name a keyboard's reports to read them and none can make the machine a
  keyboard to a phone; input reaches a display only through the HID
  function below. Web Bluetooth keeps HID from pages with a list of
  blocked services ([research-ble-apis.md](research-ble-apis.md)); here
  nothing is nameable until a declaration is checked in.

### HID over GATT

A Bluetooth keyboard or mouse types into a display, as a USB one does.
This stage uses the central role and keeps every rule above:

* **Central.** The parts of [The central role](#the-central-role), with
  LE Create Connection to bonded devices through the filter accept
  list, and with erXos showing the passkey a keyboard types, in a
  window as above.
* **The first connection is the window's.** A keyboard that has never
  paired has no bond to reconnect by, so while a window is open, and
  only then, the HID function scans for a connectable advertiser of the
  HID service that no bond names, connects to the first it hears and
  pairs as initiator; that pairing takes the window, as any first
  pairing does ([The pairing window](#the-pairing-window)). Under
  `display` the machine shows the passkey and the person types it on
  the keyboard in their hand, so a neighbour's keyboard in pairing mode
  fails unless someone types the passkey on it; a mouse, with no keys
  to type on, pairs Just Works, which only a `nodisplay` window offers.
  Once bonded, the keyboard reconnects through the accept list with no
  window.
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
  numbers, a service of the `input` interface under a name of its own,
  granted to a display read-only, through the same module as
  the USB domain's, whose stream process writes `release` when its
  occupant ends ([design-usb.md](design-usb.md#hid-reaches-the-display)).
  The domain then has, toward that display, the reach of a person at it
  and no more ([design.md](design.md#threat-model)).

### Apps as centrals

An app reads other devices through its `ble` grant (B14), which says in
two more parameters what it may do as a central:

```text
parameter uses 2 identifier set 8 bytes 63 checked_by ble_grant
parameter links 3 u64 optional range 0 4 checked_by ble_grant
```

* `uses` names the services of `abi/gatt` the grantee may use on other
  devices, at most 8. Several grants may name one service: a connection
  has one owner, a used service has none.
* `links` is how many connections the row's grantees may hold together
  as centrals, none where the row states none; a grant without it is
  refused every central operation, `{error, not_granted}`, by its facet.

**A row's links are counted for all its grantees together.** A row of
a configured domain or a start row's template has one principal, and
an `apps` row has as many grantees as installed apps, all drawing on
one row. So the registry counts a central connection against the
principal of the grantee that asked for it, the name every mint request
carries ([design-system.md](design-system.md#facets-a-configured-domain-serves)),
and counts the connections of every installed app's principal together
against the `apps` row's `links`. The limits come in `erx_bt`'s
application key `central`, which the build derives from the manifest's
`ble` rows as it derives `services`: each principal whose rows state
`links`, with their sum, and `apps`, with the `apps` row's. A principal
that `central` does not name is an installed app's, since admission
refuses an app named as any principal of the manifest
([design-packaging.md](design-packaging.md#admission)), and every
principal whose row states `links` is named, both coming from the same
rows. `ble_grant` refuses a manifest whose `central` limits together,
the `apps` row's counted once, pass the `bt` row's connection limit, so
what centrals can take from the slots phones connect to is fixed when
the image is built, and two apps share the `apps` row's `links` rather
than each taking them.

An installed app takes `uses` as it takes `gatt`: the `apps` row offers
the services and its `links`, and a package names the services it uses
([design-packaging.md](design-packaging.md#the-declaration)), fields
that design adds with this stage.

**The authority is the list of services, not a choice of device.** The
phone systems put a chooser the system draws between an app and the
devices in range, and the person's pick becomes the app's access to one
device (Web Bluetooth, Android's Companion Device Manager,
[research-ble-apis.md](research-ble-apis.md)). A device built on erXos
often has no screen and nobody at it, so no chooser is drawn, and
nothing here stands in for one: the grant bounds which kinds of device
an app reaches, by the services it names, and an app reaches every
device in range that advertises one of them.

| An app might want | It gets |
| --- | --- |
| to see what is in the air | reports only of advertisements that match a service it uses: the service's UUID in a list, its Service Data or its company's Manufacturer Specific Data. It hears no report of an advertiser that matches none. Of each one that matches it learns the address and the signal strength, so the device's presence and rough distance; a company identifier matches every product of that company that advertises it, and a phone whose app advertises a used service is reported as any matching device is |
| to connect | to a device it names by address or by bond, only while that device advertises a service the app uses, which the Bluetooth domain hears within the call |
| to read and write | the declared characteristics of the services it uses, each at its declared level, and nothing else the device serves |
| a device that asks for a bond | one made in a window an administrator opened; no app starts a pairing outside one |

The operations join the `ble` interface, and `erx_gatt_client`, a module
of the client application, makes them and takes the events' envelope
off:

| Operation | Answer |
| --- | --- |
| `scan(Service, Ms)` | `{ok, Reports}` after `Ms` milliseconds, at most `bt_scan_ms_max`, 10 s: one report for each advertiser that matched `Service`, the latest heard from it, at most `bt_scan_reports_max`, 32, the strongest kept. A report is `#{address := Address, rssi := Dbm, connectable := boolean(), payload := none \| Octets}`, the payload the one the declaration reserves, cut to its maximum |
| `connect(Service, Address \| {bond, Bond})` | `Service` one the grant's `uses` names. The Bluetooth domain scans for at most `bt_scan_ms_max` for an advertisement from `Address`, or from an address that resolves to `Bond`, that matches `Service` as `scan` matches, and only then connects to that address. `{ok, Conn, Found}` once the link is up and discovery has ended, `Found` the used services the device has; the caller is the connection's owner. `{error, not_found}` when no such advertisement is heard, with nothing sent to any device; `{error, limit}` at the count of the caller's principal, or of the apps, or at the row's connection limit; `{error, timeout}` past `bt_connect_timeout_ms` for the connection. A connection to a bond encrypts with its key first; a peer without the key loses the link |
| `disconnect(Conn)` | `ok` |
| `read(Conn, Service, Char)` | `{ok, Value}`; `{error, insufficient_security}` when the gate refuses, with nothing sent; `{error, {att, Code}}` for the peer's ATT error; `{error, too_long}` past the declared maximum |
| `write(Conn, Service, Char, Value)` | `ok` at the peer's response, or once queued for a characteristic that declares `write_without_response` alone; the errors of `read` |
| `subscribe(Conn, Service, Char, none \| notify \| indicate)` | `ok` once the peer answered the configuration write |

The owner hears `{value, Conn, Service, Char, Value}` for each
notification and indication the gate allows, `{connected, Conn, #{level
:= L, bond := none | Bond}}` when the link's security changes, and
`{disconnected, Conn}`. From the construction:

* **A connection goes only where the call's own scan found it.**
  `connect` keeps no candidate and trusts no address the caller brings:
  it confirms in the air, within the call, that the target advertises a
  service the caller's grant uses. An address made up, or one another
  app's scan of another service reported, connects to nothing unless
  that device advertises a service of the caller's, and then the caller
  could have scanned for it itself. A bond's id gives no more, since an
  id is a name and not a credential
  ([A bond's name is made with its key](#a-bonds-name-is-made-with-its-key)):
  a connection by bond needs the bonded device to advertise a used
  service too.
* **A connection belongs to the process that asked for it.** The
  registry monitors the owner, and the owner's end disconnects, so no
  link outlives the process that wanted it. Every operation on a
  `Conn`, `disconnect`, `read`, `write` and `subscribe`, is checked
  against its owner at the registry, and any other caller, another
  process of the same app or another app's, is answered `{error, gone}`,
  as for a `Conn` that has ended, so a `Conn` passed on or seen
  elsewhere reaches nothing and tells nothing. A link a phone made has
  no owner, so every client operation on its `Conn` is answered so.
  Reconnection is the owner's supervisor starting it again; the system
  restores nothing on an app's behalf.
* **Requests queue in the link, not in the app.** ATT allows one request
  at a time on a bearer; the link holds the others, within the facet's
  `in_flight`, and answers each call in order. No call is refused
  because another is in progress.
* **A scan is one bounded call.** There is no stream of reports that a
  neighbour's advertising rate could pour into an app's mailbox: the
  Bluetooth domain keeps the latest report of each matching advertiser
  within the bound, and the call returns them. A listener of broadcast
  sensors calls again.
* **A peer's notifications are paced by their taker.** The client
  answers each `value` it takes; a link holding `bt_write_queue` values
  not yet taken ends, counted, as one whose write commands outrun a
  handler does
  ([What a radio peer can make the domain spend](#what-a-radio-peer-can-make-the-domain-spend)),
  so a gap in a peer's stream is a disconnection and never silent.
* **Pairing stays the administrator's.** A request the gate refuses for
  want of a key starts a pairing, as initiator, only while a window is
  open, and that pairing takes the window as a phone's would, the first
  to reach it ([The pairing window](#the-pairing-window)); otherwise it
  answers `insufficient_security`. The bond it makes is the machine's,
  with an id, as a phone's is.

What a link the machine made serves to its peer is unchanged: the table,
through the gate. Client operations on a link a phone made, for the
services some phones offer their accessories, are not designed
([What waits for a consumer](#what-waits-for-a-consumer)).

### Classic Bluetooth

Classic HID (BR/EDR) adds inquiry, an SDP client, L2CAP's
connection-oriented channels with configuration, Secure Simple Pairing,
link keys and the HID control and interrupt channels, each a parser with
its fuzz target, under the same window and store, and a link kind beside
the LE link. Cross-transport key derivation stays off unless a consumer
is named. It is designed when a classic device is needed.

### What waits for a consumer

Each of these was weighed for the interface
([research-ble-apis.md](research-ble-apis.md)) and is not designed,
because nothing built or planned needs it. Each names who would ask and
what it would take.

| Not designed | Who would ask | What it would take |
| --- | --- | --- |
| a route to Bluetooth for native programs | an app whose Bluetooth logic is C and cannot sit behind an Erlang handler that starts it as a helper | a program holds no facet ([design-programs.md](design-programs.md#facets)), so either requests of their own in the program protocol, relayed by the program's handler, with a C client generated from `abi/services/ble.txt`, or a file tree for stream-shaped services. Neither changes the Erlang interface |
| an out-of-band pairing method | an `authenticated` service on a machine with no display and no management channel: Wi-Fi provisioning on a headless box | a carrier for the out-of-band data, NFC or a code printed for each device, and so data written into each device when it is made; SMP's out-of-band exchange in `erx_smp_core` ([Decisions](#decisions), 3) |
| requests for connection parameters, data length or PHY | a battery-powered peripheral that must stretch its connection interval; a transfer that needs another PHY | LE signaling's parameter update, which a link answers Command Reject today ([Links: the fixed channels](#links-the-fixed-channels)), and the HCI commands; the wish stated in a declaration or the `bt` row, not by a handler's call |
| L2CAP connection-oriented channels | a bulk transfer GATT is too slow for; a profile that requires one | credit-based channels in the link, with bounds, and operations of their own |
| a value for one connection, or a read a handler answers | data one phone alone may read, where a notification on its `Conn` will not do | [Alternatives considered](#alternatives-considered), "Reads answered by the handler" |
| client operations on a link a phone made | a gadget that takes the time or its notices from the phone | the GATT client on a link no app owns, and a rule for who subscribes |
| advertising while every slot is taken; extended advertising; a second payload | a broadcaster that must be heard while phones are connected | non-connectable advertising beside the connectable, which legacy advertising cannot run at once |
| more than 4 connections or 8 bonds | a head unit | larger constants in `abi/formats/bluetooth.txt`, within the controller's buffers and the state slot's 4 KiB |
| a package that brings its own declaration | an app for an image whose maker did not declare its service | [Alternatives considered](#alternatives-considered) |
| Bluetooth mesh; the HID device role | none named | designs of their own |

## Security

The Bluetooth domain is outside the trusted base. What it holds and what
a radio peer can do:

| Adversary | Can | Cannot |
| --- | --- | --- |
| A radio peer, anyone in range | send any packet the controller forwards; connect while a slot is free and so hold it; read and write `open` characteristics; pair during a `nodisplay` window and so reach `encrypted` characteristics; on a development build with `bleuart` on, use a root shell of the console's root session ([The console](#the-console)) | reach an `encrypted` characteristic without a bond made in a window, or an `authenticated` one without the passkey the window showed; make the system domain parse a radio byte, since no `ble` grant names it and what a client types on `bleuart` reaches root's session's tty, not the system domain; make the Bluetooth domain hold more than its bounds; replace a bond |
| An app holding a `ble` grant | attach to, set, notify and indicate the services its grant names, and answer the writes handed to it; keep its facet's requests in flight up to the row's `in_flight`; hear the bond id of every bonded link its services reach, and so recognize a bonded phone at each connection and across apps that compare ids; broadcast in the clear the octets its declared payload reserves; with the central role, scan for, connect to and use every device in range that advertises a service its grant uses, within its row's `links` | handle, set or notify a service its grant does not name, which its facet refuses before the registry sees it, an installed app's grant naming only the services admission gave it and no other app; take a service another app or a configured domain holds by installing a package that declares it, which admission refuses; set, notify or receive a phone's bytes on a service once its handler has ended, or leave values or buffered bytes for the service's next owner, since a service's state is its handler's; answer a write handed to another process; reach a link, the store or the controller except through the registry; learn a phone's address, or name a bond no link encrypted with that bond's key showed it; open a pairing window, see a passkey or forget a bond; put octets into the advertising under another service's UUID or company, or past the room its own declaration reserves; connect to a device that does not advertise a service its grant uses, or operate on a connection another process owns |
| A holder of the control tree, `rw`: an administrator's session, or the app a device's maker gave it | open pairing windows of either mode and so admit a phone to every service at that level; see each passkey and each bond's identity address; forget any bond or all | pair outside a window or faster than the pairing wait, which outlives its windows; replace a bond; read a key; with an `ro` grant, do more than read `bonds` |
| The controller, its closed firmware | everything a radio peer can; read every LTK erXos gives it; forge what a bonded peer could send | reach anything erXos does not send it: it sees the line, not the machine |
| A compromised Bluetooth domain | everything the controller can; read the bonds; act as any bonded phone toward the apps it serves; type into `bleuart`'s shells and read them, where `bleuart` runs, as any radio peer can | reach a device, a partition or a facet beyond its row's; reach the system domain but through the `ble` facet's grantees; open the system shell, which no line it reaches carries; make a holder of the control tree read or write a file outside the tree, since no link in it is followed; the false lines it can show that holder gain it nothing, since it already holds every bond and answers every phone |

The vault cannot keep a bond's key from the Bluetooth domain or the
controller, which needs it in clear in LE Long Term Key Request Reply;
what any store gives is sealing at rest and one owner, not containment.

No report of the domain carries a radio peer's or the controller's
bytes, nor a key: the domain takes the report filter, `erx_report`,
at boot, before any process of it starts
([design-log.md](design-log.md#reports-carry-no-term)), so the crash
of a process with controller bytes in its mailbox or its stack trace's
arguments (an unknown action, a `function_clause` in a core, the
`badarg` of a send to a line process that has gone) is logged as names,
classes and arities.

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
  gets errors; nor does it reach the bond's kept subscriptions or table
  hash, which a link takes on only at encryption with the bond's key.
  As a client, in the HID stage, the GATT client sends no
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
  addresses is a later option with a consumer to name. In the other
  direction, what is enforced is narrower than "no app can track a
  phone". A handler is given no phone's address, but it hears the bond
  id of every bonded link it serves, whether or not the phone used its
  service, so it can log when each bonded phone comes and goes, and two
  apps that compare ids recognize the same phone. An app that scans
  hears only advertisers of the services it declares
  ([Apps as centrals](#apps-as-centrals)), but of each it learns the
  address and signal strength, and a company identifier matches every
  product of that company. A service's advertised payload is public,
  whatever its characteristics require ([Advertising](#advertising)).
  Keeping bonded phones' comings and goings from apps would take an
  authority this design does not give, one that withholds the id from
  handlers of services the link has not used; no consumer has asked
  for it ([Decisions](#decisions), 13).
* **A handler that trusts an address.** An app that gave rights to an
  address would give them to anyone who copied it. No handler is given
  one: a bonded phone's name is its bond's id, which only a link
  encrypted with that bond's key carries
  ([A bond's name is made with its key](#a-bonds-name-is-made-with-its-key)).
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
each connection (`Conn`'s number, the peer's address, the bond's id and
identity when resolved, the level, the MTU, subscriptions), each bond
(id, identity address, level; never a key), and the counters: framing errors, dropped
events and frames, refused PDUs, failed pairings by
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
  still reach it. A link waits on another process only at its start,
  on the store's `resolve` and the registry's `join`, and no owner waits
  on a link, so no two processes wait on each other.
* **The registry outlives links and the controller.** It sits before the
  controller group in the domain's `rest_for_one` supervisor, so a
  controller restart ends every link, every handler hears `disconnected`
  for each, and handlers stay attached.
* **No facet outlives the registry, and no grant of the control tree
  outlives its server.** The store, the registry and the window process
  are temporary, `significant` children of `erx_bt_sup`, whose
  `auto_shutdown` is `any_significant`, so the end of any of them ends
  `erx_bt_sup` and so the domain, and every facet and every grant of
  the tree ends with its mint: no handler stays attached to a registry
  that has forgotten it, no grant of the tree serves from a window
  process that has ended, and none needs telling. Each facet finds the
  registry by name at each request,
  and one made while the domain stops is refused `{error,
  unavailable}`. A facet never
  blocks on the registry, since `erx_facet` sends a forward with an
  alias and passes the reply on when it comes, and the registry waits on
  no facet.
* **What is advertised** is the registry's state, and the controller
  process fetches it with `erx_gatt_srv:advertised/0` after the one
  `advertising_changed` the registry keeps outstanding; the registry
  never waits on the controller process, so this call adds no wait
  cycle, and the controller's mailbox holds at most one such message
  ([Advertising](#advertising)).
* **A disconnection during a handler's answer** drops the answer: the
  reply goes to the link's pid, whose process no longer exists; the handler
  has already heard `disconnected` from the registry or hears it next.
* **A notification and a disconnection** race only at the registry, which
  answers `{error, gone}` for a dead `Conn`, and for a notification whose
  link ended before answering it; a notification queued before
  the end is dropped with the link's queue, as the controller drops what
  it had.
* **A handler's end and its effects in flight** race only at the
  registry and at each link, and the owner decides both: the registry
  takes an effect only from the service's current handler and hands a
  write on only under the handler it carries, and its `{handler, ...}`
  reaches each link before any `set` of the next owner, since the
  registry sends both in its one order. A request forwarded by a facet
  that has since ended, a write a link sent before it took the change,
  and the handler's end reaching the registry after its successor first
  asked to attach each fall in one of these cases, and no process waits
  on another for any of them
  ([A service belongs to its handler](#a-service-belongs-to-its-handler)).
* **One window** exists at a time; its state and the pairing wait are
  the window process's, and the link asks it at a Pairing Request and
  before a Security Request, and tells it a failure or that the store
  has the bond, whose answer the store then sends it; the window
  process monitors a link from its `open` verdict until one of those,
  so a link that ends mid-pairing, however it ends, counts as a
  failure, and one that ends while the store writes its bond does not.
  The window process needs no monitor of the store: the store sits
  before it under `rest_for_one`, so the store's end ends the window
  process too. A write to `ctl` waits in its grant, as a write of its
  medium may ([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
  "Waiting requests"): on the store, behind the
  requests queued there and then a read and a put, each bounded by
  `bt_store_timeout_ms`, then on the window process to tell it a
  confirmed answer. The window process waits on neither, since it answers
  links' admissions and other grants' calls, and the store waits on
  neither, so no two processes wait on each other; meanwhile that grant's
  other answers, a `pair` line among them, wait with it. The window process
  sits before the controller group, so a controller restart, the only
  restart a radio peer's traffic can cause beyond its own link, keeps the
  wait.
* **The store** is one process; a pairing's `put` and a link's
  configuration writes are serialized there, and each `put` writes the
  whole state. Its one wait, on its backend, ends at
  `bt_store_timeout_ms`, so it answers every request it takes.
* **The line service** serves one reader and writers in arrival order; the
  Bluetooth domain has one of each. Its reads, writes and resets that
  wait are waiting requests the line's process keeps, so a read that
  waits holds up no write, and the grant in `erx_fs` waits on
  neither ([The controller's line](#the-controllers-line)). A `reset`
  holds both until it answers; a read waiting at a `reset` answers
  `eio`.
* **The device service** makes every firmware notification from its one
  firmware worker, so a power cycle and the VL805's notification never
  meet in the kernel, and its own process stays free to answer
  ([The power line](#the-power-line)).

The supervision tree of `erx_bt`:

```text
erx_bt_top                      one_for_all, intensity 0
  erx_ble_facet                 the mint of ble, from the boot script; the ble facets
  erx_bt_tree_mint              erx_fs_mint of bluetooth, from the boot script; the tree's grants
  erx_bt_sup                    rest_for_one, from the row's -eval
    erx_bt_store                the identity address and the bonds
    erx_gatt_srv                the table, handlers, Conn map, advertising state
    erx_bt_fs                   the control tree's server and the window
    erx_bt_host_sup             one_for_all, at most 5 restarts in 60 s
      erx_bt_link_sup           a temporary link per connection
      erx_bt_line_rx            the reader, registered
      erx_bt_line_tx            the writer, registered
      erx_bt_hci                the controller process, started last
```

The console is no part of this tree: `erx_bleuart` and its
`erx_gatt_serial` run in `bleuart`'s session ([The console](#the-console)).

`erx_bt_top` restarts nothing: either mint's end, or `erx_bt_sup`'s,
ends `erx_bt`, a permanent application, and so the
domain, which the domain service restarts within the row's intensity,
as the PCIe domain's supervisor does
([design-pcie.md](design-pcie.md#processes)). Both mints start before
init's ready report, the only time a mint can be named
([The Bluetooth domain](#the-bluetooth-domain)). The facets are not
children of the tree: each `ble` facet is a process the mint started
with `erx_facet:start/3`, and each grant of the control tree a child of
the `erx_fs_grants` its mint links to itself; each ends with its mint.

The controller group starts in that order, so the controller process
finds its siblings running and registered when it starts
([The controller process's effects](#the-controller-processs-effects)),
and stops in the reverse order, the controller process first.

## Failure handling

| Failure | Detected by | What ends | Recovery |
| --- | --- | --- | --- |
| a framing error, a malformed event (a reserved handle or Peer_Address_Type included), a Hardware Error event, a command not answered in 5 s, an answer to another command, a completion for a handle not live or beyond its outstanding packets, a failed bring-up step, a line reset not answered in 5 s; a failed open, read or write of `data` or `ctl` | the controller process; for the line's files, the reader or the writer, whose end ends the group | the controller group: the controller process, the line's reader and writer, every link | the group restarts: `reset`, then the bring-up; past 5 restarts in 60 s the domain ends and the domain service restarts it within its intensity |
| a malformed L2CAP frame, a second outstanding ATT request, an SMP timeout, an encryption change the link did not key, a packet the core answered `busy`, a link process's crash | the link | the link: its end makes the controller process send Disconnect | the phone reconnects |
| a link whose backlog of the controller's messages reaches `bt_link_backlog` | the controller process | the link: its handle is disconnected with `0x14` and it ends at `link_down` | the phone reconnects |
| a malformed ATT request | the ATT server | nothing: Invalid PDU | none needed |
| a handler that does not answer in 5 s | the link's deadline | nothing: Unlikely Error | none |
| the registry's end, or the store's | `erx_bt_sup`, which shuts down at either | the domain, as the mint's end does: every facet, attachment and link | the domain service restarts the domain within its intensity; every handler stops at its facet's end, and its supervisor's restart attaches through the facet the new incarnation mints ([The client](#the-client)) |
| the end of either mint, or of the window process | `erx_bt_top`; for the window process, `erx_bt_sup`, which shuts down at it | the domain: every facet and every grant of the control tree ends with its mint | the domain service restarts the domain within its intensity, and its mints mint every grant anew |
| a handler that ends | the registry's monitor | the handler's attachment: its services' values return to the declared ones, the writes handed to it are left to the links' deadlines, and what phones sent under it reaches no one | the app's supervisor restarts the handler, which attaches again through `erx_gatt`'s retry and sets its values ([The client](#the-client)) |
| the store answers `unavailable`, returns a blob that does not decode, or leaves a `put` unconfirmed, a backend call past `bt_store_timeout_ms` included | the store | the pairing; at start, the bonds: the domain runs without them and refuses pairing; the configuration write; `forget` | `/proc/bt` and the log say `store_unavailable` or `store_unreadable`; the store is `unknown`; after an unconfirmed `put` a change reads first and fails unless the read succeeds; after the start's read the next start reads again; `forget all` alone replaces a blob that does not decode ([Bonds and the store](#bonds-and-the-store)) |
| a broken line, its driver's start failed included | the line service | reads of `data`; with no driver, writes too | the controller group's restart writes `reset`, which starts the driver again |
| a line tree or the host link ends, or line 153's owner | its line group's supervisor | the group after it: on the Pi 4, the tree's fids and, for the owner, the host link's sessions | the group restarts, its owner first; the console, in no group, is untouched. The Bluetooth domain's `line` grant ended with the tree, and a grant of a system domain's service comes only in a ready answer, so `/dev/line` answers `eio` to the controller group's restarts until the domain ends at its intensity; the domain service restarts it, and its ready answer brings a grant of the new tree |
| a power notification that fails | `reset`'s answer, `eio` | the bring-up; the line, left broken with no driver, the holding one ended | the group's restart retries within its intensity; after an unanswered request every later notification of the boot fails at once, the VL805's included, so the Bluetooth domain ends at its intensity, and its log records and the line service's `/proc` show why |
| a configuration write the store does not keep | the store, `unknown` or a `put` not `ok` | nothing: Unlikely Error, the configuration unchanged | the phone writes again |
| the row's patch file missing, or not made only of complete Write RAM and Launch RAM records | `erx_bt_patch:records/1`, as the controller process starts, before the line is touched | the controller process, `{patch_refused, File, Reason}`, at every start | none: the image is wrong; the group restarts until the domain ends at its intensity, its log naming the file and the reason |
| a controller reporting another manufacturer than the row's `patch_manufacturer` | the first identify | the controller group, `patch_for_other_controller`, before any vendor command | none: the manifest names a patch for another controller; the domain ends at its intensity as above |
| a patch command answered with a status other than success, or not within the command deadline | the controller process, as any bring-up step | the controller group, with the record's number as the step | the group restarts; its `reset` power-cycles the controller, so no part of a half-loaded patch survives in its RAM |

## Refusals and error results

| Interface | Refusal | When |
| --- | --- | --- |
| the line's `ctl` | `einval` | any write but `reset` |
| | `eio` | a power notification answered other than `ERX_OK`, `ERX_ETIMEDOUT` for every one after the boot's first timeout included; the holding or the fresh driver did not start |
| the line's `data` | `eio` | a read while the line is broken; a read or a write while it has no driver |
| the control tree's `pair` | `ebusy` | another window is open |
| | `einval` | a first write other than `display` or `nodisplay` |
| | `eio` | the store is `unknown` since its start |
| | `eacces` | an open that is not for both reading and writing, so a holder of an `ro` grant opens no window and holds none shut against others |
| the control tree's `ctl` | `einval` | any write but `forget BOND`, `BOND` 32 lower-case hexadecimal digits, or `forget all` |
| | `eio` | `forget BOND` while the store stays `unknown`, or any `forget` whose `put` is unconfirmed |
| | `enoent` | no bond has that id |
| the control tree's `bonds` | `eio` | a read while the store is `unknown` since its start |
| | `eacces` | an open for writing |
| any path of the control tree | `eacces` | a link the resolver would follow ([The Bluetooth domain](#the-bluetooth-domain)) |
| | `erofs` | a write through an `ro` grant, refused by the grant before any callback ([design-files.md](design-files.md#invariants), F5) |
| `btpair` | the shell's refusal of a command whose `-erx_needs` its session does not hold; `[invalid]` in place of a line | the session holds no `bluetooth` grant; a line `erx_bt_pair:parse/1` does not accept |
| `ble` facet | `{error, not_granted}` | a service the grant does not name, refused by the facet before the registry sees it; with the central role, a `Service` its `uses` does not name, or any central operation on a grant without `links` |
| | `{error, not_found}` | with the central role, a `connect` for which no advertisement from the address, or from one resolving to the bond, matching the service is heard within `bt_scan_ms_max`; nothing is sent to any device |
| | `{error, limit}` | with the central role, a `connect` past the count of the caller's principal, or of the installed apps together, or past the `bt` row's connection limit |
| | `{error, attached}` | the service already has a handler: one whose end has not yet reached the registry, the same app's previous session's or, after a removal, the previous owner app's, which `erx_gatt:attach/1` waits out for up to `bt_attach_wait_ms` before it answers this; or another process of the same session that holds the service, which it answers at that deadline |
| | `{error, not_attached}` | a `set`, `notify` or `indicate` whose caller is not the service's handler: another process of the grantee, or a handler whose end has detached it; `erx_gatt` exits the caller with `{not_attached, Service}` |
| | `{error, badarg}` | an operation of another shape, or a `reply` whose answer is not `ok`, `{error, value_not_allowed}`, `{error, not_authorized}` or `{error, Code}` with `Code` in `16#80..16#9F`, refused by the facet |
| | `{error, unavailable}` | no registry is registered: before the row's `-eval` has started it, or while it restarts |
| | `{error, no_such_characteristic}`, `{error, not_allowed}` | an unknown name; an access the declaration does not allow, an `advertise` for a service whose declaration reserves no payload among them |
| | `{error, too_long}` | a value over the characteristic's maximum, a notification over the bearer's `Mtu - 3`, or a payload over its declared maximum |
| | `{error, busy}` | the link's notification queue holds `bt_notify_queue` |
| | `{error, gone}` | a dead `Conn`; with the central role, a client operation on a `Conn` the caller does not own, another process's or a link a phone made |
| | `{error, not_subscribed}`, `{error, insufficient_security}` | the phone did not subscribe; the gate refused |
| | `{error, timeout}` | an indication unconfirmed in 30 s, after which the link ends (ATT 3.3.3) |
| installing a package, at `cp`'s close (admission, [design-packaging.md](design-packaging.md#admission)) | `eperm`, `{gatt_not_offered, S}` in the log | the package's `gatt` names a service the `apps` row's `gatt` does not offer, a service a configured domain's row names among them |
| | `eexist`, `{gatt_taken, S, Other}` in the log | another admitted app, `Other`, declares `S` |
| a pairing, on `pair` | `failed ADDR secure_connections_required`, `key_size`, `method`, `confirm`, `dhkey`, `bonding`, `invalid`, `unexpected`, `peer`, `timeout`, `already_bonded`, `bonds_full`, `unavailable`, `disconnected` | SMP's reasons and the store's, each mapped from one Pairing Failed code or one event |
| a Pairing Request during the pairing wait | Pairing Failed, Repeated Attempts (`0x09`) | the wait has not passed; no line on `pair`, the window stays open |
| a configuration write on a bonded link | Unlikely Error (`0x0E`) | the store is `unknown` or its `put` was not `ok` |
| a configuration write on a link that holds a key | Insufficient Encryption (`0x0F`) | the link is not yet encrypted |
| a write command past `bt_write_queue` | the link's end, counted | the handler has not answered the commands before it ([What a radio peer can make the domain spend](#what-a-radio-peer-can-make-the-domain-spend)) |
| `root_line` on `bleuart`'s login grant | `{error, unavailable}`; `bleuart` sends the client one line and opens no tty | the console holds no root session, or the mint failed ([design-login.md](design-login.md#operations)) |
| a message of `bleuart`'s tty that fails `erx_tty_master`'s check | the tty is hung up and its shell ends | the tty's messages of [design-live.md](design-live.md#the-tty) |
| `service bleuart start` and the other commands | the start table's errnos ([design-apps.md](design-apps.md#how-a-command-is-judged)); `NAME does not exist in the system manifest` where the manifest has no `bleuart` row, as in every release manifest | |

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

Agents iterate on the host tests and the QEMU suite against Bumble, on its
1-CPU cell; the board runs by hand, once per batch, under the manual
checklist. Hosted mode runs none of the Bluetooth stack: the Bluetooth
domain is a domain of its own beside the system domain, which only hosted
mode's multi-process form could run
([plan.md](plan.md#track-h-hosted-mode)), and QEMU runs the line
service, the domain and its facets as the board does.

### Host tests of the cores

Each core's test is paired with the seeded faults it must catch.

| Core | Holds | Seeded fault that must fail it |
| --- | --- | --- |
| `erx_h4` | a stream cut at every byte offset splits into the same packets; an unknown indicator, an over-long ACL length and an ACL packet past `bt_acl_rx_max` (251 octets) are errors, before and after the bring-up | the indicator check removed; the ACL length read as one byte; the bound one octet too long. A bound taken from LE Read Buffer Size cannot be written: `split/1` takes only the constant |
| `erx_bt_hci_core`, explored over every reachable state until none is left (the clock moves only to a deadline that passes, so it takes at most three values; the count of dropped events, a statistic, is explored to one; a path makes at most three connections, enough for one handle to be given a new peer while the other is live), and case by case | the writer never holds two items; a wake-up before the deadline changes nothing, and the deadline's passing stops the core or changes it; a command the controller never allows ends at its deadline, which a command due, not due and due again keeps until the line would take one; every state before `ready`, the line's reset included, has a deadline, so every bring-up reaches `ready` or a stated reason, patching at most once; an opcode-0 event never moves the deadline; credits never go below zero and connections never pass the limit; a disconnect is written only for a handle whose disconnect was asked since it last connected, and at most once before the handle connects again; a request naming a gone link changes nothing, even on a reused handle; Number Of Completed Packets reaches each live handle's link as `{completed, Count}`; advertising is never on at the limit, and with nothing written, sent or due it is on exactly while connections are below the limit; the controller process ends for exactly these reasons: an answer naming another command, a deadline passed, a completion beyond a handle's outstanding packets or for a dead handle, a connection past the limit, during the bring-up, on a live handle or on one whose disconnect is unanswered, a disconnect failed with neither Unknown Connection Identifier nor Command Disallowed, a disconnect not completed by its deadline, a patch for another controller, a hardware error, an unanswered line reset, a malformed event and a failed step; fewer buffers than the connection limit lower the limit; Read Buffer Size takes any length from 1 | the command slot not cleared by Command Status; a handle kept live after Disconnection Complete; a completion count taken without the outstanding bound (a forged report grows the credits), or counting packets still waiting for the writer; advertising not re-enabled after a disconnection; the deadline armed only once the controller allows the command; a due slot emptied while the line takes no command; the connection limit kept above the buffer count; LE's 27-octet minimum applied to Read Buffer Size; any failed disconnect taken as the handle gone; a taken disconnect's deadline never armed; the line's reset under no deadline; and, each caught by the exploration, a disconnect kept after Disconnection Complete, a connection on a handle being disconnected accepted, a connection before the enable's answer leaving advertising on, completions not passed to their links, a deadline passed a millisecond early or only after its instant, a request's link name ignored, and a disconnect answered Command Disallowed asked again at once. A second deadline, or cancelling one never armed, cannot be written: each deadline is a field of the state it guards, the slot or a taken disconnect. Credits not returned at disconnection cannot be written: the free credits are derived from the live handles' outstanding packets |
| `erx_bt_patch` | a synthetic patch replays in order; a truncated last record or a foreign opcode refuses the file whole, before any record is sent | the record length not checked against the bytes left |
| `erx_gatt_db` | a built table matches a hand-written one; the hash changes with a characteristic's declaration or descriptors, not with its maximum, levels or initial value, nor with the manifest's row order; a table of 0xFFFF attributes builds and one more fails, and every declared service builds into one table | services laid out in manifest order; the handle bound removed |
| `erx_gatt_gate` | GAP Table 10.2's rows for levels 1, 2 and 4 | Insufficient Encryption answered on a link with no key |
| `erx_gatt_server` | each supported request; long reads and prepared writes at every MTU from 23 to 247; the gate asked for every value and descriptor access; a descriptor write on a link that holds a key and is not encrypted answers Insufficient Encryption, at every level the characteristic declares | the gate skipped for Read Blob; the descriptor's write level taken from `read`; the descriptor's write level taken from the declaration alone (an `open` write before encryption answered) |
| `erx_bt_link_core`, explored | reassembly at every fragment size; one outstanding request; a command past the queue ends the link; a first pairing reaches its level before the store answers, a reconnection the bond's; a Pairing Request on a resolved link fails; `encrypted` set only by a success report after a Reply; one Security Request, never during encryption; a bonded configuration write answered only after the store's `ok`; a resolved link sends no `subscriptions` or `served` and indicates no Service Changed before its encryption, and restores the bond's subscriptions at it, refusing a configuration write before it Insufficient Encryption; a failure before the verdict reaches the window; every controller message's step returns `taken`; `keep` and `keeping` leave in one step, and a `withdraw` after it changes nothing | an Encryption Change accepted after a Negative Reply; encryption accepted only for kept bonds; the configuration write answered before the store; the bond's subscriptions taken at `new/1` (a resolved link's configuration reads as the bond's before encryption); a `withdraw` taken in the Security Manager's `done` (the outcome `withdrawn` while the store keeps the bond); the pairing not awaited from its `admit` |
| `erx_smp_core`, explored over every message order | Passkey Entry and Just Works complete; every refusal of [Secure Connections only](#secure-connections-only) fires; a `display` window refuses Just Works; one pairing per window | the key-size check removed; the curve check removed (the `y + 1` point accepted); the link-key bit kept |
| `erx_bt_window` | the wait doubles from 2 to 64 s after failures, a disconnection mid-pairing counting as one, and a failure imposes twice the last one's wait halved for each whole 600 s since it, within 2 and 64 s; a Pairing Request during it answers Repeated Attempts and leaves the window open; back-to-back windows do not shorten it | the wait reset when a window opens; a disconnection not counted; the wait never decayed; the maximum applied before the decay |
| `erx_pl011:program/1` | `fresh` writes `CR` 0 first, clears `FEN` before the divisors, drains the receive side within 33 reads, writes the divisors before `LCR_H` and `CR` whole last with the flow enables; under flow `none` no step sets `RTSEN` or `RTS`, and under `rts_cts` only the last sets `RTSEN`; `keep` clears no FIFO and programs the divisors only of an unprogrammed UART | `LCR_H` before the divisors, so the rate never latches; `fresh` keeping the boot's divisors; `RTS` set under flow `none` |
| `erx_smp_crypto` | SMP Appendix D's sample data for `f4`, `f5`, `f6` and `ah` | the AES-CMAC key byte order reversed |
| `erx_bt_state` | a state round-trips; another version, a truncation and an oversized count are refused; the largest state the declared table allows encodes in at most 4 KiB | the bond count read without its bound |
| the store's table, against a scripted fake store and a development file over a fake data tree that fails a chosen step | a start reading `unavailable` or an undecodable blob runs with no bonds and refuses pairing, configuration writes and `forget BOND`, and `forget all` replaces the bad blob; a start reading `none` makes the identity address; a `put` that reached the medium but answered `unavailable` fails the pairing, and the next pairing reads first and keeps its bond; after every confirmed change and read the domain's bonds are the store's; over the development file, a pairing's `put` that the storage completes after its deadline and after a confirmed `forget` of a bond it holds does not bring the bond back at the next start; a lower generation landing late, a `.new` name and names not the store's leave `get`'s blob the highest generation's | `unavailable` read as `none` (a pairing overwrites the stored bonds); the pre-put state kept after an unconfirmed `put` (the failed pairing's bond lost); the development file read at its lowest generation, and an unconfirmed `put` not counted in the next generation (each brings the forgotten bond back); a `.new` name not counted; `forget all` put without reading the generation |
| the line's `ctl` grammar | `reset`, with or without newline; everything else `einval` | a prefix match accepting `resetx` |
| the line service's reset, over a model driver and device service | the five steps in order: the driver started with flow `none` before the off notification, the off and on notifications with their times between, and the driver started with the grant's flow only after the on time; input during the power cycle never reaches a reader; a power `{error, _}` at the off or the on notification ends the holding driver before the next step and, once it has ended, answers `eio`, leaves the line broken with no driver and answers `eio` to a write that arrived during the reset; with no power line, steps 1 and 5 alone | the grant's flow passed to the holding start, so RTS is asserted as the controller powers up; the second start made before the on time has passed; the holding start dropped, so the old driver's settings meet the power-up; the failure path that skips ending the holding driver, so a write queued during the reset reaches the controller under flow `none` |
| the line keeper's core (`erx_line_core`), explored | from a fresh line, with and without a power line, every event in every reachable state up to three requests and two power-cycling resets, each start both answering and refusing: no driver of flow `none` outside a reset, the one live driver of the grant's flow the core's and the only one sent bytes, a reset always waiting on an event still to come, `ok` only at the fresh start and `eio` only with the line broken | a failed reset answered while its holding driver still runs; a failing reset that never takes its holding driver's end |
| the mailbox core's answer check, `erx_vc_answer`, over buffers the test writes | `set_gpio_state` with response word 0, and with bit 31 set, and pin word 0 is `ERX_OK` with no bytes; with either word and the pin word left at 128, as an untouched buffer has it, `ERX_ENOTSUP`; `notify_xhci_reset` with word 0 is `ERX_ENOTSUP`; a nonzero word without bit 31 is `ERX_ENOTSUP` for both; a wrong code or first tag is `ERX_EPROTO`; both request words of a `set_gpio_state` row reach the buffer, and one of a `notify_xhci_reset` row | `result_word` ignored, so the power line's answer is refused as the probe saw; `result_word` taken as true for every tag, so an ignored VL805 notification reads as performed; the pin word's check dropped, so an untouched buffer reads as performed; the request built from the row's first word alone |
| the manifest generator's firmware request rows | the Pi 4's record packs UART0's power row as `bt_off`, words 128 and 0, at index 0 and `bt_on`, words 128 and 1, at index 1, and the VL805's row with its one word; a row that names `set_gpio_state` itself, a power row naming a power line `fw_power_line` does not declare, a device other than a placed UART, or a device another row names, and `arguments` longer or shorter than a tag's request are refused | the refusal of a row that names `set_gpio_state` itself removed, so a record row with pin 131, `GLOBAL_RESET`, packs |
| the manifest check's `ble` rows (`ble_grant`) and the identifier sets of the packer and the boot view | a `ble` grant to a suite domain packs, and the boot view reads it; each refusal of [Declarations](#declarations-abigatt) fires on a manifest that differs from a passing one in it alone: a service of the `ble` interface named otherwise, a `ble` grant to the system domain, one to a session template that is neither the app template nor a start row's, one to a start row's template whose principal's `domains` quota is 2, one to a configured domain that shares a start row's name, an undeclared name, a name two rows give, an `apps` row whose `gatt` names a service a configured domain's row names, `gatt` without `ble` in the `apps` row's `services` and `ble` there without `gatt`, two served services of one UUID, a ninth name, advertising data one octet too long; the packer packs `nus`, `nusb`, `nv` in that order from every order of its lines and refuses a name twice; the boot view takes that packed set and refuses a name twice and every other packed order | the system domain's refusal removed (a manifest granting `ble` to the system domain packs); identifiers compared length first (`nv` before `nusb`); a prefix ordered after its extension; the duplicate check dropped from the boot view (a forged packed set with a name twice reaches the mint); the template refusal widened to the app template (the development manifest with `ble` and `gatt nus` in its `apps` row fails to pack); the app template's exception widened to every template (a source row granting `ble` to `@session.system` packs) |
| the line service through a real `erx_fs` grant, reader and writer on one `data` file | a write is answered within 1 s while a read waits, and the driver's answer reaches the read once; a `reset` answers a waiting read `eio`; a clunk during a waiting read is answered within 1 s and the next reader gets the next bytes whole | a `read` that waits inside its callback; a dropped flush of a waiting read |
| flushes of begun and buffered requests, with power notifications held by the test | a `reset` flushed at any step is answered once its last step is done, then the flush; a write flushed after the driver took its bytes answers its count; a read flushed with bytes buffered answers with them, and before bytes arrive `eintr`, the next read getting them whole | a flushed `reset` answered `eintr` while its steps run; a read held while bytes are buffered |
| the identity address | 10,000 addresses have the static form and parse in Bumble's `Address` as static | the top bits cleared |
| the controller group, over a model line, store and registry (the group's start takes the open function, since on stock's emulator no namespace reaches a mounted tree; the model `ctl` answers after a set delay, and a `data` read waiting at a reset answers `eio`) | `ready` from start and again after the controller process is killed; the first `data` read after `ctl`'s answer; the identity address unchanged across the restart; a killed link process leads to one `HCI_Disconnect` with reason `0x13`; after `link_down` a `to_link` for the name reaches no process; completions reach their links; a `ctl` answering `eio` ends the group | the reader reading at its start, so the group never reaches `ready`; the controller process making the address itself; a link process's end ignored; completions not passed to the link |
| `erx_hci`'s LE Connection Complete | Peer_Address_Type `0x00` and `0x01` decode as `public` and `random`; `0x02` and `0xFF` make a successful event malformed; a failed one, Status `0x3C` with Peer_Address_Type `0xFF` and handle `0xFFFF`, decodes as `{failed, 16#3C}` | the type passed through as its octet; the type or the handle checked before the Status (the failed event malformed) |
| the link's start, against a store and a registry that hold its calls until the test releases them | `start_child` returns while both calls wait; what the controller process sends meanwhile is stepped in order once the core is built; a phone whose address resolves gets its bond's key | the store's `resolve` called from `init/1`, so `start_child` does not return within the test's deadline |
| a link's end, with the window process and the registry running | a link killed by `exit(Link, kill)` after an `open` verdict writes `failed ADDR disconnected` and doubles the wait; a link that reports its outcome and then ends counts once; the handlers hear `disconnected` once | the window's monitor not taken (nothing written, the wait unchanged); the monitor kept after the outcome (counted twice) |
| a notification to a link that ends before answering it | the registry's caller gets `{error, gone}` | the caller's `From` handed to the link in a plain message (the caller waits until its own timeout) |
| the `ble` facet, over a registry the test registers | a request naming a service its grant names reaches the registry with the grantee's caller in it, and the answer reaches the caller; one naming another service is refused `{error, not_granted}`, and the registry sees nothing; with no registry registered, `{error, unavailable}`; an attaching caller, not the facet, hears the events, and only it answers its writes | the service check dropped from `admit/3` (another app's service attached); the handler taken from the forwarded call's `From` (events go to the facet, which drops them) |
| `forget` with bonded links connected | the link whose address resolved to the forgotten bond at its start ends; a link of another bond stays | the store taking a link's pid only at `keep` |
| the two identities of one address | a public and a random bond of the same octets are two bonds with two ids: the second pairing is kept, forgetting one id leaves the other, and forgetting it again is `enoent` | the bonds compared by their octets alone (the second pairing fails `already_bonded`) |
| `erx_bt_hci_core`'s backlog, case by case | a link that acknowledges nothing is sent exactly `bt_link_backlog` messages, events and ACL packets alike; the next is dropped, the handle's disconnect is asked with `0x14`, and nothing more reaches the link; a link that acknowledges every message is never disconnected; a `taken` naming a gone link changes nothing, even on a reused handle | the bound compared one too late (33 sent); `completed` not counted; `taken` taken without its name (a gone link's acknowledgement lowers the next link's backlog) |
| the link's backlog through the controller group, a link held at its start by a store that does not answer while the model line delivers 40 ACL packets for its handle | `HCI_Disconnect` with `0x14` is written after the 32nd; the link's mailbox never holds more than 32 of the controller's messages | the bound removed (all 40 delivered) |
| a pairing's outcome, with the link, the window process and the store running | a window closed after the link's `keeping` leaves the bond kept, the window process logging `bonded` and counting no failure; a window closed before it fails the pairing `withdrawn`, and the store gets no `keep`; a link killed after `keeping` leaves the store's outcome as the pairing's; a window opened before that outcome answers `ebusy` | the window's monitor kept past `keeping` (the killed link counted `disconnected` while its bond is kept); the store's outcome sent to the link alone (the window waits) |
| the store against a backend that never answers | a `put` is unconfirmed at `bt_store_timeout_ms`: the pairing fails `unavailable`, the window gets that outcome, a configuration write answers Unlikely Error, and the store is `unknown`; a `get` at the start leaves the store `unknown` at the same deadline | the backend called with no deadline (the test's own deadline passes with `keep` unanswered) |
| an app's `ble` grant, through the session plan (`erx_domain_core:app_session/4`) over a template `ble` row whose `services` is `nus` and `nusb` | an app whose record holds `gatt nus` gets a `ble` row whose `services` is `[nus]`, and one whose record holds no `gatt` gets no `ble` row; the install refusals are admission's ([design-packaging.md](design-packaging.md#verification-and-testing)) | the row's `services` passed whole (the session's facet admits `nusb`, which the app did not declare) |
| the registry's core (`erx_gatt_registry`), a service's owner, over a core serving `nus` and `nusb` with two joined links, handler `A` attached to `nus` and `nusb` | a `set` of `nus` from another caller is `{error, not_attached}` and changes no value; at `A`'s `down` every link gets `{handler, nus, none}` and `{handler, nusb, none}`, a later join answers `nus`'s declared values, and `A`'s `set` and `notify` stepped after that `down`, as a facet's late forwards, are `{error, not_attached}`; `B` then attaches `nus` and every link gets `{handler, nus, B}` before `B`'s first `set` reaches it; a write carrying `A` stepped after `B`'s attach is answered Unlikely Error and `B` hears nothing, and one carrying `B` reaches `B` | the caller check dropped from `set` (`A`'s late `set` reaches the value `B` owns); the write's handler compared with nothing (the write carrying `A` is handed to `B`); the values kept at a handler's `down` (the later join answers `A`'s value); `{handler, ...}` sent after the attach's own answer rather than in the same step (a `set` of `B` stepped at once reaches a link before the change) |
| the link's core (`erx_bt_link_core`), a change of owner, with `nus` handled by `A` | a Prepare Write of `rx` under `A`, then `{handler, nus, none}` and `{handler, nus, B}`, then a second part and Execute Write: the write sent carries `A`; a Write Request after the change carries `B`; after `{handler, nus, none}` a Read of a readable characteristic of `nus` that `A` set, in the test's own declaration of `nus`, answers its declared value, and of two notifications queued for credits, one of `nus` and one of `nusb`, only `nusb`'s is sent | the handler taken at Execute Write rather than at the first Prepare Write (the prepared bytes carry `B`); the values kept at the change (the read answers `A`'s value); every queued notification dropped, or none (`nusb`'s lost, or `nus`'s sent) |
| the registry's core, an attach while a phone stays connected | with a link joined, its MTU 247 and `nus`'s `tx` configured `notify`, an attach of `nus` hears `connected`, then `{mtu, Conn, 247}` and `{subscribed, Conn, tx, notify}`, in that order; after the link's end an attach hears none of them | the replay dropped (the handler hears `connected` alone, so `erx_bleuart` holds its prompt for good); the kept configuration not dropped at the link's end (the later attach hears a dead link's `subscribed`) |
| `erx_bt_top`'s tree, with a stub controller line | killing `erx_gatt_srv`, and killing `erx_bt_store`, ends `erx_bt_top` and so the application | the registry made permanent (`erx_bt_sup` restarts it and every facet lives on, with no handler attached) |
| `erx_gatt_service` against a stub facet registry | `start_link` answers `{ok, Pid}` with no `ble` grant installed; once the stub installs it the handler attaches and sets its values; an attach answered `{error, not_granted}` ends the handler with it | the attach made before the answer (the start fails `not_granted` before the session can report ready) |
| `erx_gatt:attach/1` against a stub facet, on a clock the test moves | a stub that answers `{error, attached}` twice and then `{ok, ...}` gives `{ok, ...}` after two waits of `bt_attach_retry_ms`; one that answers `{error, attached}` throughout gives `{error, attached}` once `bt_attach_wait_ms` has passed, and not before; `{error, not_granted}` and `{error, unavailable}` come back at the first ask; `set/3` answered `{error, not_attached}` exits the caller with `{not_attached, nus}` | the retry removed (the first case answers `{error, attached}`); the deadline removed (the second case asks without end, past the test's own deadline); `not_attached` returned rather than exiting (the caller lives on, detached) |
| a bond's id, in `erx_bt_state` and the store over a fake backend | a kept bond has an id of 32 hexadecimal digits, which the store's outcome to the window, `resolve/1` and the `kept` answer all give alike; two pairings from one address, the second after a `forget`, get different ids, and after `forget all` over a blob that does not decode the next bond's id is none the lost state held; with the random source replaced by one that repeats a kept bond's id once, the store draws again and keeps the new bond under a fresh id; a state round-trips its ids, and one in which two bonds share an id is refused | the id taken from the count of bonds kept (the bond after the loss gets the first bond's id); the id computed from the address (the second pairing gets the first id); the redraw dropped (two kept bonds share an id, which the next encode refuses); the decoder's check for a shared id dropped |
| the registry's `connected`, over a core with one joined link | at the join the event's map holds `level` and `bond := none` and no other key; after the link's `{security, #{bond := B}}` it holds `B`; for a link whose address resolved and which has not encrypted it holds `none` | the join's address copied into the event (the map has an `address` key); the bond's id taken at `resolve` (a peer that copied a bonded phone's address is shown that bond's id) |
| the payload, in `erx_bt_adv:data/1` and the registry's core | the octets a handler gave are in the advertising data under its service's UUID or company, payloads in the order of their services' names; they leave at an empty `advertise` and at the handler's end; one past its maximum is `{error, too_long}`, one for a service that reserves none `{error, not_allowed}`, another caller's `{error, not_attached}`; for each row of the budget table in [Advertising](#advertising), the data built with a full payload equal Bumble's encoding of the same structures and take the octets the table gives; for every pair of declared maxima the manifest check admits, the data built with full payloads are at most 31 octets, and a 128-bit service that says `advertise` and reserves `data` is refused | the payload kept at the handler's end (a removed app's octets stay in the air); the manifest check fitting payloads at no length (a manifest whose maxima overflow packs, and the built data pass 31 octets); Service Data counted without its UUID (the listed-and-data row packs) |
| the control tree, `erx_bt_fs_tree` with `erx_bt_pair` | `forget` with a kept id forgets that bond alone, with an id no bond has answers `enoent`, and with 31 digits, an upper-case digit or an address answers `einval`; `bonds` lists every kept bond, one line each, no line holding an octet run of any key, and answers `eio` while the store is unknown since its start; an open of `pair` for reading alone answers `eacces`, and a read-write open after it is answered; `parse/1` reads back every line `format/1` makes, and answers `invalid` for a line with a control byte or a passkey of five digits | `forget` matching a prefix of the id; `bonds` read as empty for an unknown store; the read-only open admitted (the open after it answers `ebusy`) |
| one bond record, `erx_bt_pair` | for bonds of both address types and both levels, `parse_bond(format_bond(R))` is `R`, a `bonds` line and the rest of a `bonded` line made for one bond are the same octets, and `parse/1` of the `bonded` line gives `{bonded, R}` with the same `R` as `parse_bond/1` of the `bonds` line | the `bonded` line composed by its own code that drops the type (the round trip of a random identity fails) |
| bounded reading, `erx_bt_pair:next/1` over a stub file | a stream of window lines yields the same terms whatever its split into reads, at every split point including inside a newline's neighbours and one octet per read; a line of exactly `bt_pair_line_max` octets is read whole; a stream of `bt_pair_line_max + 1` octets, or of 1 MiB, with no newline answers `overlong` after reads that asked each for no more than the bound less what the reader holds and were served no more than `bt_pair_line_max + 1` octets in all, and the stub sees no further read; a read of no octet or of more than it asked is refused; a `bonds` file of `bt_bonds_max + 1` records is refused | the buffer bound checked only at a newline (the stub serves 1 MiB with no newline and `next/1` takes it all); a read count of the remaining file size rather than the bound |
| both mints before readiness, `erx_bt_top` started from the boot script against a stub `erx_facet` | both `ble` and `bluetooth` are provided before the start returns; a mint request for `bluetooth` sent before the stack starts is answered once `erx_bt_fs` has started, with a grant that serves `bonds`; killing `erx_bt_fs` ends `erx_bt_top` | the tree's mint started under `erx_bt_sup` (the provide is refused after the report); the mount run before the acknowledgement (the boot script's start waits on a stack that starts only after readiness, and the start times out); `erx_bt_fs` not significant (it restarts and the grant answers from a dead pid) |
| the control tree's links, through a grant of the `svc` interface mounted in a test namespace, its server a stub that serves `ctl` as a link to a file of that namespace | a write to `/svc/bluetooth/ctl` answers `eacces` and the file is unchanged | the stub's service declared of the `files` interface (the write lands in the file) |
| a handler's `not_authorized` | the write is answered Insufficient Authorization, and the next write still reaches the handler | the answer sent as an Application Error |
| `btpair` over a stub tree | it prints a pairing's parsed lines in order and ends at the file's end; an interrupt closes the file, which the stub sees as a clunk; a line that does not parse prints `[invalid]`; a stream with no newline past `bt_pair_line_max` prints `[invalid]`, ends with a failure status and clunks the file | the line printed as read (a line holding an escape sequence reaches the terminal); `btpair` reading with `file:read_line/1` (the unterminated stream is read whole) |
| the manifest check's `bluetooth` rows | a development manifest that grants the tree to root's template packs; each refusal fires on a manifest that differs from it in that alone: a grant with `rx`, and a grant where the `bt` row has no store | the store rule removed (an image that offers pairing and can never pair packs) |

### Fuzz targets

`erx_h4`, the HCI event decoder and its Command Complete returns
(`erx_hci:event/2`, `return/2`), the L2CAP reassembly and frame decoder,
the LE signaling decoder, `erx_att`, `erx_smp`, `erx_bt_state` and the
development store's file names (`erx_bt_state_file:generation/1`), the line
service's `ctl` grammar, the control tree's `pair` and `ctl` grammars,
the reader of the tree's lines (`erx_bt_pair:next/1` over a stub file
that splits its input into reads at fuzzer-chosen points, with seeds
for a split inside every line and for an unterminated stream past
`bt_pair_line_max`, and `parse/1` and `parse_bond/1` on what it yields),
and the `ble` facet's admission (`erx_ble_facet:admit/3`); with the central role, the advertising
report decoder and the GATT client's response decoder, and in the HID stage the Report
Reference decoder (the Report Map is `erx_hid_desc`'s, which has its
own). Each runs at the milestone gate's budget, and the codecs are also
compared with Bumble's decoders on the same corpus, a differential test
on the host.

### On QEMU against Bumble

The harness, in Ruby, runs Bumble unmodified: `apps/controllers.py` with
two TCP server transports joined by its local link, one controller for
erXos's line and one for the peer, each bound to 127.0.0.1
(`tcp-server:127.0.0.1:PORT`), since a listener on every interface would
let any host that reaches the development host write HCI traffic into
the guest's line or the peer. It then boots QEMU `virt` with the
suite's manifest, the Bluetooth suite's own, which places the
virtio-console transport and a Bluetooth domain whose `line` grant names
it, with the `service ble` row it serves, and that transport's
port 0 on a socket chardev that connects to the first controller's
port, so the bytes erXos's line writes reach Bumble's controller
unchanged ([The line on QEMU `virt`](#the-line-on-qemu-virt)). Bumble's stream transports carry H4 framing
(`bumble/transport/common.py:41-46`, `:125-144`), and its controller
implements every command stage 1 to 4 send (`bumble/controller.py:1996`,
`:2344`, `:2874`, `:2953`, `:3004-3067`, `:3299-3310`). Python runs only
on the development host and only erXos's scripts under `test/bt/`: the
peers' scripts, in `test/bt/peer/`, and `test/bt/bumble_decode.py`, which
prints Bumble's decoding of the corpus for the codecs' comparison of
[Fuzz targets](#fuzz-targets), started by `test/host/erx_bt_bumble_test.rb`.
Each is started by argument vector, the peers by the harness, never on the
target and never in build tooling.

The handlers the peers of stages 2 and 3 talk to are those of
`erx_gatt_echo_test`, a test-only application in
`test/erlang/apps/erx_gatt_echo_test/` over `erx_gatt` and
`erx_gatt_serial`, which answers each write as the peer script expects
and sends the serial service's bytes back. It runs in a domain of the
suite's own, which the suite's `ble` grant names, from a release only a
test image carries, as the system-domain suite boots its test-only
`erx_echo_test` (`tools/lib/erx/system_domain.rb`, `ECHO_BOOT`); no
handler runs in the system domain, which `ble_grant` refuses (B8).

**The bond check.** What a bond reaches is shown on one test service,
`abi/gatt/bondcheck.txt`, whose three characteristics are constants read
at the three levels above `open`, with no write, no subscription and no
handler, since a declared value is served whether or not a handler runs
([The attribute table](#the-attribute-table)):

```text
service bondcheck eb417d8e-58b1-4f45-b9f5-e9e24e229b0f
characteristic encrypted     eb417d8f-58b1-4f45-b9f5-e9e24e229b0f 9  read encrypted     value 656e63727970746564
characteristic authenticated eb417d90-58b1-4f45-b9f5-e9e24e229b0f 13 read authenticated value 61757468656e74696361746564
characteristic bonded        eb417d91-58b1-4f45-b9f5-e9e24e229b0f 6  read bonded        value 626f6e646564
```

Each value is its own level's name in ASCII, so the service proves the
gate and holds no secret. A link with no key reads none of the three,
each answered Insufficient Authentication (`0x05`); a link encrypted
with a Just Works bond's key reads `encrypted` alone; a link encrypted
with a Passkey Entry bond's key reads all three, `bonded` once the
store has kept the bond. It is a declaration like any other, so the
generator, the manifest check and the gate need nothing for it. The
suite's `ble` grant names it beside `nus`, and the board's pairing
checklist runs on a test image whose `apps` row offers `ble` with `gatt
bondcheck`, which serves the service with no app installed, as the
domain serves every service a `ble` row names
([The `ble` facet](#the-ble-facet)). `bleuart`'s grant never names it
and no shipped manifest serves it: the console over Nordic's UART service stays without a bond
([The console](#the-console)).

The suite's manifest grants the control tree to root's session and the
store's development grant to the `bt` row, and the harness drives a
window as an administrator does, by typing `btpair display` or `btpair
nodisplay` at the console and reading the lines it prints. The stages'
peers:

| Stage | Peer | Passes | Seeded fault |
| --- | --- | --- | --- |
| 1 | `examples/run_scanner.py tcp-client:...`, and a peer script that scans and prints each report as one JSON line | erXos's name and its advertised UUIDs appear; after a `reset` and bring-up they appear again | the advertising data built with the 16-bit list's type for 128-bit UUIDs: the UUIDs are missing |
| 2 | `examples/run_gatt_client.py` and `apps/gatt_dump.py` | every attribute of the expected table is discovered, with its handle; `open` values read as set; `encrypted` ones answer Insufficient Authentication | the gate allows every read: the `encrypted` value is read |
| 2 | `test/bt/peer/gatt_peer.py`: writes, a write past the maximum, a subscription, notifications, an indication and its confirmation, a long write | each answers as declared; the handler sees each write once, in order | the link takes a second request before the handler answered the first |
| 3 | `test/bt/peer/serial_peer.py`: 64 KiB through `erx_gatt_echo_test` with `write` with response | every byte comes back in order | `erx_gatt_serial:send/2` cutting at `Mtu` rather than `Mtu - 3` |
| 3 | decision 7's echo package, `examples/echo`, declaring `gatt nus`, in the system partition of a medium whose `apps` row offers `ble` and `gatt nus` in place of the echo domain's grant, enabled, so it starts at boot; once it logs that it echoes, `serial_peer.py` | every byte comes back through the app | the session's `ble` row narrowed to no service (`erx_domain_core:granted/4`): the echo's serial handler stops `not_granted`, its session ends, and the cell fails at the echo's attach |
| 3 | an app's grant, in a cell whose manifest offers `ble` and `gatt nus` in its `apps` row in place of the echo domain's grant: two test packages over `erx_gatt_echo_test`, `echo_a` and `echo_b`, each declaring `gatt nus`; `cp echo_a.app /apps/`, `service echo_a start`, then `serial_peer.py`; `cp echo_b.app /apps/`; `rm /apps/echo_a.app`, `cp echo_b.app /apps/`, `service echo_b start`, then `serial_peer.py` again | the bytes come back through `echo_a`; `echo_b`'s first copy fails with `EEXIST` and `/apps` holds no `echo_b.app`; after the removal its copy succeeds and the bytes come back through it | admission's check of the other apps' services removed: `echo_b`'s first copy succeeds |
| 3 | the same cell, owners changing while a phone stays connected: with `echo_a` running, `test/bt/peer/gatt_peer.py` sends a Prepare Write of `rx` and waits for the harness; the harness runs `rm /apps/echo_a.app`, `cp echo_b.app /apps/` and `service echo_b start`; the peer then sends Execute Write and, after it, `serial_peer.py`'s stream; then `service echo_b restart` and the stream again | Execute Write is answered Unlikely Error and none of the prepared bytes comes back on `tx`; `echo_b`'s start attaches within `bt_attach_wait_ms`, after the removal and after the restart, and each stream comes back through `echo_b` whole | the link's write carrying the handler at Execute Write (the prepared bytes come back through `echo_b`); the registry ignoring a handler's end (`echo_b`'s start fails `{attached, nus}` at the deadline, and the stream gets Unlikely Error) |
| 4 | `test/bt/peer/pair_peer.py --io keyboard`, with a fixed address and a Bumble key store `K` (`"keystore": "JsonKeyStore:K"`, `bumble/keys.py:198-206`, `:272-285`): it reads `bondcheck`'s three values, then pairs with Secure Connections, MITM and bonding while the harness runs `btpair display` and writes the passkey it prints to the peer's standard input, then reads the three again | before the pairing each read answers Insufficient Authentication; `btpair` prints `bonded BOND ... authenticated` and ends; after it all three read their values | the gate allowing a read on a link with no key: the reads before the pairing return values |
| 4 | `pair_peer.py --reconnect` with the same address and `K`, after the Bluetooth domain restarts | the link encrypts with the kept key and `bonded` reads its value, with no Pairing Request sent and no window open | the LTK reply sending a key of the wrong bond: encryption fails |
| 4 | `pair_peer.py --io none`, with a second address and key store, while the harness runs `btpair nodisplay` | `bonded BOND ... unauthenticated`; `encrypted` reads its value; `authenticated` and `bonded` answer Insufficient Authentication | the Just Works key recorded as `authenticated` in the link's `key`: `authenticated` reads its value |
| 4 | the bond's name: `erx_gatt_echo_test`, the handler of `nus`, logs every `connected` it hears; the first peer above connects after its pairing and again after the Bluetooth domain restarts, and then a peer with the first's address and an empty key store connects | the id `btpair` printed is in `cat /svc/bluetooth/bonds` and is the `bond` the echo logs for the first peer, both times; the echo logs `none` for the peer with the copied address; no `connected` it logs holds an address | the bond's id given to the link at `resolve`: the echo logs the first peer's id for the peer with the copied address |
| 4 | `echo forget BOND > /svc/bluetooth/ctl` with the first peer's id while that peer is connected, then `pair_peer.py --reconnect` | the peer's link ends; `bonds` no longer lists the id; the reconnection does not encrypt, and `encrypted` answers Insufficient Authentication | `forget` taking the bond out of the list and leaving its link: the peer's next read of `bonded` returns its value |
| 4 | `apps/pair.py --sc false` | `failed ... secure_connections_required` | the Secure Connections flag check removed |
| 4 | `apps/pair.py` while no window is open | Pairing Not Supported | the window check removed |
| 4 | a second `apps/pair.py` run with the same address and an empty key store, in a new window | `failed ... already_bonded`; the first key store still encrypts | the bond replaced |
| 4 | `apps/pair.py` with a wrong passkey, then again at once in a new window | the first `failed ... confirm`; the second answered Repeated Attempts until 2 s have passed, then pairs | the wait not kept across windows |
| 4 | a bonded peer subscribes, the Bluetooth domain is killed at once after the Write Response, and the peer reconnects encrypting only on erXos's Security Request | the subscription is restored and a notification arrives | the configuration kept only at the link's end; no Security Request sent |
| 4 | a peer with the bonded peer's address and an empty key store connects and writes Service Changed's configuration | Insufficient Encryption; the bonded peer then reconnects and finds its subscription as it kept it | the configuration write kept on a resolved link before its encryption |
| payload | a second test declaration, `abi/gatt/advcheck.txt`, a service of a 128-bit UUID that reserves `data 4` and does not say `advertise`, since its Service Data names it ([Advertising](#advertising)), with a characteristic `value` read and notified `open` and a characteristic `guarded` read `encrypted`; the cell's manifest serves `advcheck` and `bondcheck` and no service that says `advertise`, so its advertising data are the Flags and one Service Data, 25 octets at the payload's maximum; `erx_gatt_echo_test` handles it, advertises four octets and then four others, and its domain is then stopped; the stage 1 scanner prints each report | the scan shows the first octets and then the second in Service Data under the service's UUID, and after the stop no Service Data | the payload kept at the handler's end: the scan still shows it after the stop |
| central | `test/bt/peer/server_peer.py`, a Bumble peripheral that serves and advertises `advcheck` and logs every request it receives, beside a second Bumble advertiser of another UUID; a test app whose grant says `uses advcheck` and `links 1` scans, connects with `connect(advcheck, Address)` to the address its scan reported, reads, subscribes, and is then killed | the scan returns one report, the server's, with its payload; the read of `value` returns it and each notification arrives; the read of `guarded` answers `insufficient_security` and the server logs no request for it; at the app's end the server sees the disconnection | the scan's match dropped (two reports); the client's gate skipped (the server logs the Read Request); the owner's end ignored (the server's link stays up) |
| central, targets | the same peers, the test app, and a second test app whose grant says `uses other`, the second advertiser's service: the second app scans and hands the first the address its scan reported; the first calls `connect(advcheck, A)` with that address and with an address no device uses; once the first holds a connection, the second calls `read` and `disconnect` on its `Conn` | both connects answer `{error, not_found}` and neither peer logs a connection request; the second app's calls answer `{error, gone}`, the server logs no request and the first app's link stays up | the match skipped in `connect` (the second advertiser logs a connection); the owner check dropped (the server logs the second app's Read Request) |
| central, two apps | a cell whose `apps` row offers `ble` with `uses advcheck` and `links 1`, two test packages that each declare `uses advcheck`, and two server peers advertising `advcheck` at two addresses: the first app connects to one, then the second to the other; the first disconnects and the second asks again | the first connects; the second is answered `{error, limit}` while the first holds its link, and connects once it has disconnected | the apps' connections counted for each grant rather than together (the second app connects while the first holds its link) |
| central, pairing | the central cell's server, which serves `guarded` only over an encrypted link and pairs with no input or output: the test app reads `guarded` with no window open, then the harness runs `btpair nodisplay` and the app reads it again, and then a phone peer sends a Pairing Request | without a window the read answers `insufficient_security` and the server logs no Pairing Request; in the window the app's read starts the pairing, `btpair` prints `bonded BOND ... unauthenticated` with the server's identity and ends, and the read returns the value; the phone's Pairing Request is answered Pairing Not Supported, the window having closed at the first pairing | the initiator's window check dropped (the server logs a Pairing Request without a window) |
| HID | a Bumble peer serving the HID service and advertising it connectably, with a keyboard's input and output: with no window open the HID function connects to nothing; with `btpair display` open it connects, pairs with the passkey the harness reads from `btpair` and types at the peer, and a key the peer reports reaches the display's input tree; after the Bluetooth domain restarts the peer reconnects with no window | no connection without a window; `bonded BOND ... authenticated`; the key arrives; the reconnection encrypts | the HID function's scan run without a window (the peer logs a connection with none open) |

Reconnection with a resolvable private address uses Bumble's
`examples/device_with_rpa.json` as the peer's configuration;
`apps/scan.py` is stage 1's second scanner, and
`examples/run_connect_and_encrypt.py` stage 4's second reconnecting
peer.

### On the board

The Pi 4's checklist, by hand, with a phone and with a Bumble peer on
the development host, which makes the peer side scripted: its
controller is an nRF52840 dongle running Zephyr's HCI USB firmware,
which Bumble opens over its `usb:` transport, in place of the QEMU
suite's virtual controller (that the pair carries a Secure Connections
pairing is unverified until its first run); and with a Mac as a second
scripted peer: `tools/ble_board_check.rb` drives
`blew`, a macOS command-line tool over CoreBluetooth, to scan, connect and
discover, write and read Nordic's UART service, one `blew` run per step
and one connection per step after the scan, then two `blew nus` sessions
on `bleuart`: the first types `echo`, `ps -o comm`, a `top` and Ctrl-C
with pauses between them, the second, a reconnection, needs a fresh
prompt and as many shells as before. CoreBluetooth hides GAP and GATT's own services from
an app, so the Mac's steps work on the UART service, and a step reports
unknown when `blew` times out or cannot use Bluetooth. The list:
the machine appears in the phone's scanner with its name; nRF-style GATT
browsers show the declared table; a terminal app for Nordic's UART
service gets root's shell through `bleuart` ([The console](#the-console),
[Decisions](#decisions), 7); on the test image that serves `bondcheck`
([On QEMU against Bumble](#on-qemu-against-bumble)), the Bumble peer on
the dongle runs that table's three pairing rows and its rows for the
bond's name and for `forget` against the board, with `btpair` typed at
the board's console, and a phone then pairs by typing the passkey that
`btpair display` prints, the machine is rebooted, and the phone reads
`bondcheck`'s `bonded` value again with no new pairing. The seeded
failure of that last step is the development store's directory emptied
before the reboot: the phone's link then does not encrypt and the read
answers Insufficient Authentication, which shows the passing read rests
on the kept bond and not on a link that stayed up. A `reset` written
while a phone is connected is followed by a bring-up that reaches
advertising. Its seeded failure is a line whose reset passes the grant's
flow to the holding start: the controller then boots in download mode,
answers `HCI_Reset` and not Read Local Version, and the bring-up stops at
its identify step at the command deadline, which shows the reset's order
is what the passing run rests on. The Pi 4 loads its patch at every
bring-up: `/proc/bt` shows the versions identify read after the patch
beside the ROM's, the LMP subversion after it being the one probe B-P5
recorded rather than the ROM's `0x6119`, and a `reset` written mid-way
through the patch download is also followed by a bring-up that reaches
advertising. Its seeded failures are two rows: one whose
`patch_manufacturer` is another company's, which stops the bring-up at
its first identify with `patch_for_other_controller` before `0xFC2E` is
sent, and one with no `patch`, whose `/proc/bt` shows the ROM's
subversion and no reading after a patch; together they show the passing
reading comes from the patch step. The board probes precede the first
of these ([Board probes](#board-probes)).

## Performance

Nothing here is on a fast path. What may matter, and is on the watch
list ([todo-performance.md](todo-performance.md)):

* the patch download at 115200 baud on the Pi 4: `BCM4345C0.hcd`
  puts 64,129 bytes on the line, its 323 records with their indicators
  and headers, about 5.6 s at 11,520 bytes a second, and each record
  waits for its 7-byte Command Complete, so with the 5 s of waits a boot
  or a restart advertises some eleven seconds after the bring-up
  starts; the vendor rate command `0xFC18`
  (`init_bcm43xx.c:152-158`; `hci_uart_infineon.c:100-131`) and a `rate`
  word of `ctl` would cut it, if a measurement says the wait matters;
* a phone's write reaching a handler and its answer coming back across
  two domains, measured by a peer script that times write requests
  through the suite's echo handler on QEMU, and on the board through
  `bleuart` ([Decisions](#decisions), 7);
* `erx_pl011`'s wait of 1 ms at a time while its transmit FIFO is full
  (`erx_pl011.erl:45`, `:236-243`), which bursts of notifications and a
  patch download meet.

## Alternatives considered

* **A domain registers its services at run time.** Every stack surveyed
  has the application register a service table in code. Here it would
  bring handle allocation while phones are connected, Service Changed and
  change-unaware clients within a connection, run-time conflicts between
  apps, a run-time parser of declarations with its fuzz target, and
  advertising data that may stop fitting. Declarations as configuration
  remove all of these; an installed app names, in its package, which of
  the services the `apps` row offers it handles, and the table does not
  change ([Who holds `ble`](#the-ble-facet)).
* **A package that brings its own service declarations.** An app
  would carry `abi/gatt`-style files in its package, and the Bluetooth
  domain would rebuild its table at its next start from the installed
  packages. It brings back a run-time parser of declarations with its
  fuzz target, a table and advertising data that change with every
  install, a restart of the Bluetooth domain to apply one, which ends
  every link, and the whole-manifest checks of `ble_grant` redone at
  each install. A service an app needs is declared in the tree and
  offered by the board's `apps` row instead, as every other service an
  app takes is.
* **Only configured domains hold `ble`.** An app that handles a
  service would need a configured domain of its own in the board's
  manifest, so adding one would mean editing the manifest and
  rebuilding, against the model in which apps are installed at run time
  with checked declared needs
  ([design-packaging.md](design-packaging.md)).
* **A grant to the app template, the first attach winning.** Every
  app's session would hold every service the row names, and the
  registry's `{error, attached}` would decide between them by timing:
  which app handles a phone's writes would depend on which started
  first, any app could take another's service while it restarts, and
  nothing would record which app a service belongs to. Narrowing each
  app's grant to the services admission gave it alone leaves the
  registry's refusal for a previous handler whose end has not yet
  reached it, of the same app or of the one a removal freed the service
  from, which `erx_gatt` waits out.
* **Draining a removed app's effects, or ending the links that touched
  its services.** Either would keep a removed app's late effects and a
  phone's buffered bytes from its successor, but the first makes a
  removal wait on the Bluetooth domain and the second needs the registry
  to know what each link holds and cuts a phone's other services;
  making a service's state its handler's settles both with one field
  and one message ([A service belongs to its
  handler](#a-service-belongs-to-its-handler)).
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
* **A pairing agent that an app registers**, as BlueZ's agent object
  and Zephyr's authentication callbacks are
  ([research-ble-apis.md](research-ble-apis.md)). It brings a
  registration, a rule for which of two registrants is asked, a pairing
  that waits on a callback into an app, and an agent that must be
  tracked to its end. The opener of `pair` is the agent, for exactly as
  long as it holds the file open, with nothing registered.
* **The window's mode in the file's name, opened for reading**, so that
  `cat /svc/bluetooth/pair/passkey` would be a window and no `btpair` were
  needed. A read would then change what the machine accepts from the
  air, a read-only grant could open windows, and a command that reads a
  whole tree would make the machine bondable. Control is a file to
  write.
* **Bonds that belong to the app whose window made them.** It would
  keep one app's phones from another app's services. But a phone has
  one key for the machine, so the phone would be bonded and yet refused
  by the other apps' services, with no way to pair again; the store
  would hold a list of apps for each bond and the tree a way to edit
  it; and the gate would decide by service owner as well as by level.
  The phone systems scope an association to an app on the central's
  side, where one system draws the pairing dialog for all apps; a
  peripheral's bond is with the device ([Decisions](#decisions),
  13).
* **A bonded phone's name computed from its identity**, a hash of the
  identity address under a machine key. It would be the same after a
  `forget` and a new pairing, so whoever pairs next under a claimed
  identity would take over what an app recorded for the phone before;
  an id drawn with the bond is bound to the bond's key.
* **The phone's address in `connected`.** No handler named a use for
  it, an app that keyed on it would be fooled by a copied address, and
  every app would learn the identity address of a phone that does not
  hide it.
* **Advertising data a handler builds whole**, as Android's advertiser
  and BlueZ's advertisement object take them. The data could overflow at
  run time, one app could take the room another needs, and a handler
  could advertise a UUID that is not its own. **Advertising fixed
  wholly by the declaration** cannot carry what differs for each device
  or changes while it runs, a commissioning discriminator or a state.
  A declared room with the handler's octets in it has neither fault.
* **Scan reports as a stream of events.** The rate of the reports is
  the neighbours' to set, so the stream would need credits between the
  Bluetooth domain and each scanning app; one bounded call needs none.
* **A chooser the system draws for a central app's device**, as the
  phone systems have. It needs a display the system owns and a person
    at it, which a gateway has neither of
    ([Apps as centrals](#apps-as-centrals)).
  * **Candidates a scan hands out**, opaque names for the devices one
    grantee's scan reported, which `connect` would take in place of an
    address. They would be state per grantee with a lifetime, a bound and
    an owner to check, to prove what one advertisement heard inside
    `connect` proves with none: that the target advertises a service the
    caller uses.
  * **A commissioning operation in the control tree**, which pairs with
    one peer the administrator selects, by address, as initiator or as
    responder. It would let an administrator in a crowded room choose the
    device rather than take the first, but it needs a list of the devices
    in range in the tree, a grammar for a target and a window keyed by a
    peer. No consumer of the central role needs it: a keyboard's holder
    types the passkey the machine shows, which a neighbour's keyboard
    does not get, and the `passkey` and `bonded` lines name the peer.
    It is the step to take when one does
    ([The pairing window](#the-pairing-window)).
* **The control tree at `/bluetooth`, or at `/dev/bt`**
  ([Decisions](#decisions), 11).
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
* **Opening the flow with a message to the driver.** One fresh start
  holding RTS through the power cycle and a message that then sets
  `RTSEN` would save a start, but the driver speaks the console's six
  messages and no other; a second fresh start, a few register writes,
  opens the flow with nothing new.
* **Setting UART0's pins from the line service.** The pin controller's page sets
  every pin, the console's included, so a manifest gives it to no
  domain or to the system domain
  ([design-system.md](design-system.md#the-manifest), property 8;
  [design-header-io.md](design-header-io.md#the-pin-controller-and-the-console)).
  There it has one writer, the pin controller's own driver, which sets
  the pins from the pin table
  ([design-pinctrl.md](design-pinctrl.md#at-start)); the line service
  writing them too would make a second writer of one page.
* **The Pi 4 on its ROM alone.** The ROM advertises, accepts a
  connection and carries the first ATT PDU without the patch (probes
  B-P3 and B-P4), and leaving the patch out would save some eleven
  seconds of every bring-up ([Performance](#performance)) and keep a
  binary under Cypress's driver license out of the image. But every
  host surveyed loads the patch before use, NetBSD and Zephyr in their
  code and Raspberry Pi OS by shipping it in its `bluez-firmware`
  package, so the ROM alone is a state no other host runs this
  controller in, and a defect of it would show only as a failure of
  the board's checklist.
* **The patch from the download mode.** A power-up with RTS asserted
  boots the mode that Infineon's guide loads from, and in which the Pi
  4 answered `0xFC2E`. It needs a second kind of reset, holding RTS
  asserted through the power cycle, with a `ctl` word of its own, and a
  launch that leaves the download mode, which no run has read; the mode
  every reset boots needs neither, and one host loads from it
  ([The bring-up](#the-bring-up), step 4).
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
   generic; the WiFi design keeps no network key in one, since a PMK
   never has to leave the vault ([design-wifi.md](design-wifi.md#decisions), 1). The
   alternatives were a bond purpose with store, forget and list, which
   teaches the vault a bond's structure for no protection the slot
   lacks; a seal-and-open purpose, which leaves the domain a data grant
   and its own atomic replacement, which the vault's publication already
   gives; and the development file in release builds, as FreeBSD's
   `hcsecd` keeps its link keys in `/var/db/hcsecd.keys` (`hcsecd.h:39`),
   which a copied medium yields whole.
2. **Decided: release builds offer no Bluetooth console.** `bleuart`
   gives anyone in radio range a root shell, with no login, which only a
   development build's bench allows. The manifest check refuses a
   `login` row listing `root_line` in a release manifest, so no release
   image can hand anyone the console's root session, and a tty of a
   session line runs only the command shell in any build, so it never
   carries the system shell ([The console](#the-console)).
3. **Decided: fresh passkeys, shown through a management channel the
   machine already trusts.** A `display` window shows each pairing's
   fresh passkey on the `pair` file, to an administrator's session or an
   app the manifest grants the control tree ([Where the passkey is
   shown](#the-pairing-window)). A machine with no display and no such
   channel opens only `nodisplay` windows, whose Just Works bonds serve
   only services that declare `encrypted` or `open`. Authenticated
   services on such a machine, Wi-Fi provisioning among
   them, wait for an out-of-band method, by NFC or a code the phone
   scans, designed separately. Static passkeys printed on a device are
   excluded: they leak over repeated attempts.
4. **Decided: a Pi 4 image ships `BCM4345C0.hcd`, and the Pi 4's
   manifests name it.** The bring-up loads it at every start, in the
   mode every reset boots ([The bring-up](#the-bring-up), step 4), so
   the controller runs in the state every surveyed host runs it in,
   although its ROM advertises, accepts a connection and carries the
   peer's first ATT PDU without it (probes B-P3 and B-P4). The file
   ships unmodified, in `erx_bt`'s `priv` directory of the Pi 4's
   images only, under Cypress's Wireless Connectivity Devices Driver
   End User License Agreement, which is accepted for this one file:
   the dependency table of [design.md](design.md) lists it, and the
   image license check admits that license for that file and no
   other ("The Pi 4's patch and its license" in
   [The bring-up](#the-bring-up)). The cost is some eleven seconds of
   every bring-up at 115200 baud, on the watch list
   ([Performance](#performance)).
5. **Decided: erXos sets UART0's pins from the platform record's
   on-board pin rows.** UART0's pins, GPIO 30 to 33, are on the board,
   not the header, so the header map's on-board rows name each with
   UART0's device path and its function; the manifest packer writes
   them into the manifest, and the system domain's pin driver sets them
   at its start, before the line service opens the line
   ([design-header-io.md](design-header-io.md#on-board-pins),
   [design-pinctrl.md](design-pinctrl.md#at-start)). The root's write of
   their functions at boot is the implementation that driver replaces
   ([design-pinctrl.md](design-pinctrl.md#what-the-code-does-today)). The pin
   table `hw/pins/bcm2711.txt` carries the four pins from Table 94. A
   `config.txt` line is no substitute: the firmware leaves GPIO 30 and
   31 inputs whatever the line asks. Whether WiFi's slot sets GPIO 34
   to 39, and with what pulls, is that design's
   ([design-wifi.md](design-wifi.md#facts-this-design-does-not-have), F1).
   A fixed write in the bring-up would be a second source of pins,
   which that design rules out.
6. **Decided: an installed app holds its own `ble` grant, scoped to the
   GATT services its package declares, and a second app declaring a
   service already held is refused at install.** Apps are installed at
   run time with checked declared needs, never by editing the board's
   manifest or rebuilding, so an app that handles a service gets its
   grant from its package. The board's `apps` row offers the services
   apps may handle in its `gatt` field, the build gives them to the app
   template's one `ble` row, admission keeps a package's `gatt` only
   within that set and disjoint from every other admitted app's, and the
   domain service narrows each app's session's grant to it ([Who holds
   `ble`](#the-ble-facet)); a service's state is its handler's, so
   what one app left or was sent never reaches the next ([A service
   belongs to its handler](#a-service-belongs-to-its-handler)). The rejected choices were to let only
   configured domains hold `ble`, and to grant the app template every
   offered service with the first attach winning ([Alternatives
   considered](#alternatives-considered)). The QEMU suite's echo stays a
   test-only configured domain, which its release, carried only by a
   test image, runs.
7. **Decided: the Raspberry Pi 4's development manifest carries
   `bleuart`, on by default on the development card and off on the
   published one, and its `apps` row offers no `ble`.** The Bluetooth
   track's demo ([plan.md](plan.md#track-b-bluetooth)) and the board's
   checklist have a terminal app on the phone talk to the Pi 4 over
   Nordic's UART service, and that service is `bleuart`'s. Its `start`
   row says `enable YES` and `published_enable NO`
   ([design-apps.md](design-apps.md#the-start-table)), so a builder's
   own card runs it at boot and the published card, packed from the same
   manifest, runs it only after `service bleuart enable` and `service
   bleuart start` at the board's console. A machine serves `nus` through
   one grant, so no app on the board may handle it, and the `apps` row
   keeps `services display net` and `max 1`, with the kiosk alone on
   every card, whatever its kind
   ([design-packaging.md](design-packaging.md#the-apps-row)). The echo
   stays a test-only configured domain of the QEMU suite (decision 6),
   and the echo package, `examples/echo`, declaring `gatt nus` under
   decision 6, is the path an installed app takes to a GATT service; it
   runs on QEMU, in the Bluetooth suite's app cell, under an `apps` row
   that offers `ble` and `gatt nus` ([Verification](#verification)).

8. **Decided: the Bluetooth console is an app, `bleuart`, shaped as
   `ntpd` is, whose session holds a `ble` grant naming `nus` and a
   `login` grant whose one operation is `root_line`, and masters ttys of
   the console's root session through `tty_line`.** Each part is one the
   system has: the start table turns it on and off with `service`, the
   `ble` facet carries the client's bytes, and a session line gives it
   root's ttys as it gives an SSH connection's channels theirs. The
   other places weighed:
   * **The system domain** is excluded by B8: it would hold a `ble`
     grant and take a phone's bytes from the radio stack's facet.
   * **The Bluetooth domain** would put root's shell in the domain every
     radio peer reaches through its parsers, and give the radio stack a
     grant beyond its radio, which this section's rule for that domain
     refuses.
   * **A daemon in root's session**, as SSH's first stage runs
     ([design-ssh.md](design-ssh.md#stages)), has no `start` row, so no
     `service bleuart` turns it off, and every session made from root's
     template would hold its `ble` grant, which `ble_grant` refuses.
   * **A configured domain of its own** would need the start table to
     switch configured domains, a mechanism of its own for one consumer;
     an app's row already is the switch, and SSH stays on always.
   * **A console line driven from another domain** would give the
     client the console's `Ctrl-G` menu, which nobody asked for, at the
     cost of a new interface between the domains and a second driven
     line in the console.

   Against a compromised radio stack nothing changes wherever `bleuart`
   runs: the Bluetooth domain carries every byte, so a defect there
   reached from radio range can type into and read the shell, as anyone
   in range can on a development build anyway. Apart, the Bluetooth
   domain holds nothing but its radio grants, and a defect in `bleuart`
   ends its session, which hangs its ttys up, not the radio stack, its
   bonds or the other services. The cost is one session's runtime and a
   lane hop for each write and each notification, which at a typing
   person's rate is not measurable against the link's own interval. How
   the login grant hands over the line, `root_line`, is
   [design-login.md](design-login.md#risks-and-open-decisions)'s open
   decision 5.
9. **Decided: only Erlang code uses Bluetooth.** The interface is the
   declarations, the `ble` facet with its Erlang client, the control
   tree and `/proc/bt` ([The interface](#the-interface)). No route for
   native programs is designed, and its absence shapes nothing above: a
   program holds no facet, so a route would be requests of the program
   protocol with a generated C client, or a file tree for stream-shaped
   services, either of which sits beside the Erlang interface without
   changing it ([What waits for a consumer](#what-waits-for-a-consumer)).
10. **Decided: `bleuart` requires no bond.** `nus` stays `open`,
    `bleuart`'s grant names `nus` alone, and it holds no grant of the
    control tree and opens no window ([The console](#the-console)).
    Pairing and the gate's levels are exercised on the test service
    `bondcheck`, which no shipped manifest serves
    ([On QEMU against Bumble](#on-qemu-against-bumble)).
11. **Decided: the control tree is the service `bluetooth`, found at
    `/svc/bluetooth`.** Every service's control tree, an app's, a
    configured domain's or the system domain's, is at `/svc/NAME`
    ([design-app-trees.md](design-app-trees.md)), and the Bluetooth domain's is no exception: its
    `pair`, `bonds` and `ctl` are a tree of the interface `svc`, whose
    row gives the one property the tree needs from its interface, that
    no link in it is followed ([The Bluetooth domain](#the-bluetooth-domain)).
    A tree of its own at `/bluetooth` would add a name at `/` and an
    interface that differs from `svc` in its name alone. `/dev/bt`
    would put a protocol stack's control under `/dev`, although the
    Bluetooth domain holds no device: the controller's line is the
    device, and it lies in the system domain.
12. **Decided: a window offers Passkey Entry with the machine showing
    the passkey, or Just Works, and never Numeric Comparison.** Its
    modes are `display` and `nodisplay`. Numeric Comparison, where both
    sides show six digits and each user confirms, would save a kiosk's
    or a head unit's user from typing them on the phone, but every
    device that could offer it has a screen, and Passkey Entry with the
    machine displaying needs only that. Offering it would open the
    method-confusion attack ([Attack classes](#attack-classes)) on the
    machine's side: an attacker in the middle runs Numeric Comparison
    with the machine and Passkey Entry with the phone, and a user who
    accepts on the Numeric Comparison side gives the attacker a bond
    with the machine even though the phone's Passkey Entry side fails.
    The Bluetooth SIG's notice on the vulnerability states that
    consequence
    ([method-vulnerability](https://www.bluetooth.com/learn-about-bluetooth/key-attributes/bluetooth-security/method-vulnerability/),
    not read for this design and unverified until it is). Offering it
    would take a third mode word, `compare`, a `confirm NNNNNN ADDRESS`
    line and a `yes` or `no` written to the open file.
13. **Decided: a bond is the machine's, named by a drawn id.** A bond
    reaches every service at its level. Each bond has an id of 128
    bits drawn when it is kept; handlers hear the id and no address,
    and the id is a name every handler on the link hears, not a secret
    ([A bond's name is made with its key](#a-bonds-name-is-made-with-its-key),
    [Bonds and the store](#bonds-and-the-store)). So the client's
    `connected` event carries `bond`, `ctl` forgets a bond by
    `forget BOND`, and the stored state holds each bond's id. Bonds
    scoped to the app whose window made them, weighed in
    [Alternatives considered](#alternatives-considered), would serve a
    machine whose apps come from makers that do not trust each other's
    users, which no planned device is.
14. **Decided: an `apps` row offers the control tree only by the
    board's explicit opt-in, naming `bluetooth` in its `services`.**
    The opt-in lets an installed app, a kiosk's own among them, be the
    device's pairing interface without a row of its own in the board's
    manifest; its cost is that every admitted app that asks becomes an
    administrator of all the bonds, and a shared signer does not
    separate those apps from each other
    ([The Bluetooth domain](#the-bluetooth-domain)). Where one app
    should administer Bluetooth, a facet row grants the tree to that
    app's template by name, so the manifest lists every holder and the
    pairing app is a principal of the board's manifest with a start
    row; that is the form to prefer. Forbidding the `apps` row to offer
    the tree would cost a kiosk built only from installed apps its
    pairing screen; allowing it with no opt-in serves no consumer.
15. **Decided: the pairing path is built first, as one piece; the
    advertised payload and the central role wait for a consumer.** The
    piece is both mints before readiness, the store's grant and the
    control tree's grants in the development manifests, the bond's id,
    `btpair` with `erx_bt_pair`'s bounded reading and one bond record,
    `bondcheck`, and the pairing, reconnection and `forget` cells;
    without them no image pairs and nothing on hardware tests stage 4.
    The advertised payload and the central role, apps as centrals and
    HID over GATT alike, are built when a consumer justifies each:
    nothing in the first release needs them, and the central role is
    most of this design's new obligations (scan state, connection
    owners, the counted links, discovery and pairing as initiator).
    [plan.md](plan.md#track-b-bluetooth) schedules the work.

## Open decisions

None.

## Board probes

Each runs on the Pi 4 under Fiasco before the code that depends on
it, and its readings go into a research record,
[research-bluetooth-pi4.md](research-bluetooth-pi4.md). B-P1 to B-P4
are read; what they settle is in [The hardware](#the-hardware),
[A reset](#a-reset) and [The power line](#the-power-line).

* **B-P1, read.** GPIO 30 to 33 are inputs at erXos's start, and a
  `config.txt` line leaves GPIO 30 and 31 so, so the root sets them to
  ALT3 ([Decisions](#decisions), 5).
* **B-P2, read.** The firmware leaves the controller powered; the
  enable line is expander pin 0, `BT_ON`, request pin 128, active high;
  300 ms off and 500 ms on bring the controller back at 115200; it sends
  nothing between power-on and `HCI_Reset`; the set tag's response word
  is 0 and its pin word is 0 on every set, which its declaration takes
  as performed.
* **B-P3, read before any patch.** Powered up with RTS deasserted, the
  ROM reports HCI version 7, LMP version 7, manufacturer `0x000f`, LMP
  subversion `0x6119` and the placeholder address `aa:aa:aa:aa:aa:aa`;
  powered up with RTS asserted, it is in download mode. The reading
  after the patch is B-P5's.
* **B-P4, read.** On the ROM the controller advertises (runs 4 and 5)
  and accepts a connection as a peripheral, after which the peer sends
  its ATT Exchange MTU Request (run 5): the stages need no patch to begin. Whether the
  ROM serves GATT, the serial service and pairing as the stages build
  them is read by the board's checklist over the real stack
  ([On the board](#on-the-board)), not by a probe.
* **B-P5**, the patch in the mode every reset boots, which step 4 of
  [The bring-up](#the-bring-up) rests on. After a reset as
  [A reset](#a-reset) gives it, RTS deasserted through the power-up
  and the grant's `rts_cts` flow after it, and `HCI_Reset` and identify
  as steps 2 and 3, the probe sends `BCM4345C0.hcd` as step 4 does and
  logs, for each command, the bytes sent, every byte received and the
  time to its Command Complete. It reads:
  1. `0xFC2E`'s Command Complete and its status. Status 0 keeps the
     mode step 4 uses; another status, or none within the command
     deadline, sends the probe to item 6;
  2. each Write RAM's Command Complete, its status, and the longest
     time to one, against the guide's 200 ms, and whether a first
     Write RAM sent at once after `0xFC2E`'s answer, Zephyr's way, is
     answered;
  3. Launch RAM's Command Complete and its status, which says whether
     the answer comes before the controller relaunches;
  4. every byte the controller sends unasked in the 4 s after the
     launch's answer, each decoded as the core would take it;
  5. the shortest of 0, 50, 270, 1000 and 4000 ms after the launch at
     which `HCI_Reset` is answered, a power cycle and a fresh download
     before each; then Read Local Version, Read Local Supported
     Commands, LE Read Local Supported Features and Read BD_ADDR,
     beside B-P3's readings of the ROM, which shows whether the patch
     took (the LMP subversion against `0x6119`) and what it changes;
     then B-P4's advertising and a connection on the patched
     controller;
  6. only when item 1, 2 or 3 fails: the same download after a
     power-up with RTS asserted, `HCI_Reset` first, and, after the
     launch, whether Read Local Version is answered with RTS under the
     grant's flow, which says whether a launch leaves the download
     mode. A pass here changes step 4's mode and comes back to this
     design.

  Items 2 and 5 settle `bt_patch_minidriver_ms` and
  `bt_patch_launch_ms`.
* **B-P6**, on the Pi 4: kill the Bluetooth
  domain mid-way through a patch download, with CTS held off by the
  controller, and check that the next `reset` starts the driver without
  waiting on `BUSY` and that the next bring-up reaches advertising.
* **B-P7**, on the Pi 4, the patched controller: while advertising,
  write LE Set Advertising Data with the UART service's UUID added and
  then removed, and read its Command Complete status and what a phone's
  scanner shows after each, which checks that the controller uses new
  data while advertising as HCI 7.8.7 requires, so that advertising
  follows its handlers without a disable ([Advertising](#advertising)).
