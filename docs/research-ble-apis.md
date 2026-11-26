# Research: BLE programming interfaces, and what erXos's should be

Point-in-time research record, 2026-11-25. Host: Apple Silicon macOS
(Darwin 27.0.0). It surveys how other systems let a program use Bluetooth
Low Energy (BLE), and compares them with erXos's Bluetooth design as it
stands at commit `5ad00ae6e` of master. It decides nothing: it is input
for a design of erXos's BLE interface for device makers.

The question, from the owner (2026-11-25): how would people using erXos
to build a consumer, industrial, embedded, kiosk or automotive device
interface with erXos's BLE stack, and how would they plug into it?

## Sources

Every external file used lies in
`~/erxos-scratch/research/ble-apis/raw/`, fetched over HTTPS on
2026-11-25; `SHA256SUMS` beside it records each file's URL and SHA-256.
Where a source is cited below as `name:N`, `N` is a line of the file or
of its tag-stripped copy in `txt/` beside it.

| Source | Version | Files |
| --- | --- | --- |
| Apple Core Bluetooth reference (JSON behind developer.apple.com) and the archived Core Bluetooth Programming Guide | as served 2026-11-25 (the guide is Apple's archived edition) | `apple-*.json`, `apple-cb-background.html`, `apple-cb-bestpractice-periph.html` |
| Apple AccessorySetupKit reference | as served 2026-11-25 | `apple-accessorysetupkit.json` |
| Android developer guides and reference (`BluetoothGatt`, `BluetoothGattServer`, `BluetoothDevice`, `BluetoothLeAdvertiser`, permissions, companion device pairing) | as served 2026-11-25 | `android-*.html` |
| Web Bluetooth, W3C Community Group draft report | "Draft Community Group Report, 3 June 2026" (`web-bluetooth-whatwg.html.txt:7`) | `web-bluetooth-whatwg.html`, `web-bluetooth-blocklist.txt` (registries `master`) |
| Zephyr Bluetooth host headers (Apache-2.0) and docs | tag `v4.2.0`; docs `4.2.0` | `zephyr-gatt.h`, `zephyr-conn.h`, `zephyr-l2cap.h`, `zephyr-*.html` |
| Apache NimBLE host headers (Apache-2.0) | tag `nimble_1_8_0_tag` | `nimble-ble_gatt.h`, `nimble-ble_gap.h`, `nimble-ble_store.h` |
| ESP-IDF API reference (Bluedroid GATT server, BLE GAP, NimBLE port) | `v5.4` | `espidf-*.html` |
| BlueZ D-Bus API man pages, as rendered by man.archlinux.org (documentation only; no BlueZ source was read) | package `5.88-1` (`bluez-AgentManager.5.html.txt:139`) | `bluez-*.5.html` |
| Qt Bluetooth LE overview and `QLowEnergyController` | Qt `6.8` | `qt-*.html` |
| Bumble docs and two Python files (Apache-2.0) | docs as served; `examples/run_gatt_server.py` and `bumble/pairing.py`, `bumble/gatt.py` from branch `main` on 2026-11-25 (pinned by their SHA-256 only) | `bumble-*` |
| BlueHeron (Elixir) README and hex.pm metadata | `0.5.4`, Apache-2.0 (`blueheron-hex.json`) | `blueheron-*` |
| connectedhomeip (Matter SDK, Apache-2.0) BLE headers; ESP-Matter developer guide | tag `v1.4.0.0`; ESP-Matter `latest` | `chip-*`, `espmatter-developing.html` |
| Car Connectivity Consortium's Digital Key page | as served | `ccc-digital-key.html` |
| Plan 9 4th edition, 9front and Inferno manual section 3 indexes | as served | `plan9-man3-index.html`, `9front-man3.html`, `inferno-man3-index.html` |

Not obtained, and so not relied on: the Matter specification and the CCC
Digital Key specification (both behind a member or download form, which
this research did not fill in); Nordic's nRF Connect SDK pages (403 to a
plain HTTPS fetch); Android Automotive's Bluetooth page (404 at the
fetched URL). Statements about those are marked **unverified**. No GPL,
LGPL or AGPL source and nothing of Fuchsia was read.

erXos sources read: `docs/design-bluetooth.md`, `docs/design-app-trees.md`,
`docs/book/19-bluetooth.md`, `abi/services/ble.txt`, `abi/gatt/`,
`config/manifest/raspi4b-development.txt`, and the sections of
`docs/design.md`, `docs/design-system.md`, `docs/design-packaging.md`,
`docs/design-header-io.md` and `docs/design-drives.md` cited where used.

## Summary

The interfaces fall into four shapes:

1. **Static declaration plus callbacks** (Zephyr, NimBLE, ESP-IDF's
   attribute tables, BlueHeron, erXos today). The GATT table is data the
   build or the start-up lays out; the program supplies functions that
   answer reads and writes. Security requirements sit on the attribute.
   Embedded stacks all land here, because the table is small, fixed and
   checked once.
2. **Objects with delegates on a system service** (Apple Core Bluetooth,
   Android, Qt, Bumble). A program builds service objects at run time,
   publishes them to a daemon that owns the radio, and gets callbacks
   for requests and events. The operating system owns pairing, its UI and
   the bond list.
3. **Objects on a message bus** (BlueZ). The program exports an object
   tree on D-Bus; the daemon calls back into it. Pairing UI is an
   "agent" object some program registers. Two calls hand a characteristic
   to the program as a socket descriptor.
4. **Capability-scoped central access** (Web Bluetooth, Android's
   Companion Device Manager, Apple's AccessorySetupKit). A system-drawn
   chooser picks one device; the program gets access to that device and
   the services it named, and nothing else.

No Plan 9 or Inferno release has a Bluetooth device or file interface
(manual section 3 indexes list none: `9front-man3.html.txt`,
`plan9-man3-index.html.txt`, `inferno-man3-index.html.txt`, no match for
"blue"). The nearest file-shaped precedent is BlueZ's `AcquireWrite` and
`AcquireNotify`, which give a program a socket for one characteristic.

erXos's design is a strong peripheral of shape 1: declarative services
in `abi/gatt`, one access gate, an Erlang behaviour per service, a
pairing window that is an open file. Its gaps for device makers are: no
app can be a central or scan; advertising content is fixed; no
characteristic in the tree needs a bond and the pairing control tree is
granted on no image; pairing offers Passkey Entry (erXos displays) and
Just Works only; a handler cannot tell which bonded phone it is talking
to; there is no L2CAP connection-oriented channel and no control of
connection parameters or PHY; and a C program has no route to BLE.

## Comparison

| | Programming model | How a GATT service is declared | Pairing UX | Who may use the radio | Central role | L2CAP CoC | Conn. params / PHY / MTU | Testing story |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Apple Core Bluetooth | objects + delegate callbacks | `CBMutableService`/`CBMutableCharacteristic` built at run time, then `add(_:)`; cached and unchangeable once published | OS alone; the app only marks a characteristic "encryption required" | Info.plist usage string, user consent; background modes | yes (`CBCentralManager`) | `publishL2CAPChannel(withEncryption:)` | latency hint only; MTU and PHY not app-controlled | none built in |
| Android | callbacks (`BluetoothGattCallback`, `BluetoothGattServerCallback`) | `BluetoothGattService` objects added to a `BluetoothGattServer` | OS dialog; apps may see `ACTION_PAIRING_REQUEST` | runtime permissions `BLUETOOTH_SCAN`/`CONNECT`/`ADVERTISE`; CDM association | yes | `listenUsingL2capChannel`, `createL2capChannel` | `requestConnectionPriority`, `setPreferredPhy`, `requestMtu` | emulator; no in-tree radio simulator in the docs read |
| Web Bluetooth | promises on objects | none (central only in its first version) | browser/OS | user gesture, a chooser, filters and `optionalServices`, a blocklist | only role | no | no | none in the spec |
| Zephyr | static macros + callbacks | `BT_GATT_SERVICE_DEFINE` into a linker section, or `bt_gatt_service_register` at run time; permissions per attribute | app callbacks (`bt_conn_auth_cb`): display, entry, confirm, accept; fixed passkey and OOB available | the firmware is the app | yes | yes, credit-based, segmented receive | `bt_conn_le_param_update`, `_phy_update`, `_data_len_update`, MTU exchange | `native_sim`, BabbleSim, QEMU with an HCI controller |
| Apache NimBLE | static tables + one GAP event callback | `ble_gatt_svc_def`/`ble_gatt_chr_def` arrays with an `access_cb` | `BLE_GAP_EVENT_PASSKEY_ACTION`; app decides repeat pairing | the firmware is the app | yes | yes (headers not read for this record) | yes (PHY event in `ble_gap.h`) | host builds; not surveyed further |
| ESP-IDF Bluedroid | callbacks per registered "app" | `esp_ble_gatts_create_attr_tab` from an attribute array | GAP events and `esp_ble_passkey_reply`/`confirm_reply`; static passkey option | the firmware is the app | yes | not surveyed | GAP calls (not surveyed) | none surveyed |
| BlueZ (D-Bus API) | objects exported on D-Bus, daemon calls back | object tree under one `ObjectManager` root, `RegisterApplication` | agent object: `RequestPasskey`, `DisplayPasskey`, `RequestConfirmation`, `RequestAuthorization`, `AuthorizeService` | D-Bus policy (unverified: no policy file read) | yes | profile API (`org.bluez.Profile`, not read in detail) | not surveyed | not surveyed |
| Qt Bluetooth | objects + signals | `QLowEnergyServiceData` built, `addService` | the platform's | the platform's | yes | not surveyed | `requestConnectionUpdate` | none |
| Bumble | Python asyncio objects | `Service`, `Characteristic`, `CharacteristicValue(read=, write=)` | `PairingDelegate` subclass with an IO capability | the process owns an HCI transport | yes | yes (not read in detail) | yes (not read in detail) | its central purpose: virtual controllers, local link, Android emulator bridge |
| BlueHeron (Elixir) | Elixir structs + read/write functions | `BlueHeron.GATT.Service.new(%{...})`, registered with the peripheral | not documented in 0.5.4 README | the process owns an HCI transport | not yet | not documented | not documented | not documented |
| erXos (design) | static declaration + Erlang behaviour over a facet | `abi/gatt/NAME.txt`, selected by the manifest, fixed for the domain's life | a window opened on the control tree's `pair` file; lines show passkey and outcome | the manifest's `ble` grant, narrowed per app at install | designed only inside the Bluetooth domain, for HID | no | MTU answered 247; no params or PHY | host tests of pure cores, QEMU against Bumble, the board |

## Per-API notes

### Apple Core Bluetooth (iOS, macOS)

* **Model.** Objects and delegates. `CBPeripheralManager` "manages and
  advertises peripheral services exposed by this app"; `CBCentralManager`
  "scans for, discovers, connects to, and manages peripherals"
  (`apple-cbperipheralmanager.json`, `apple-cbcentralmanager.json`
  abstracts). Both must be in the powered-on state before use.
* **Declaring a service.** A `CBMutableCharacteristic` is created with
  properties and permissions and published with the manager's `add(_:)`;
  "After you publish a characteristic, Core Bluetooth caches the
  characteristic and you can't make changes to it"
  (`apple-cbmutablecharacteristic.json`). Reads and writes arrive as
  delegate requests answered with `respond(to:withResult:)`; values go
  out with `updateValue(_:for:onSubscribedCentrals:)`, "using a
  notification or indication" (`apple-cbperipheralmanager.json`
  references). A ready-to-send callback after a full queue is widely
  used; its name was not in the files read (unverified).
* **Advertising.** An app may advertise only its local name and service
  UUIDs, in at most 28 bytes in the foreground
  (`apple-cb-bestpractice-periph.html.txt:30-31`). No manufacturer data.
* **Pairing.** The app marks a characteristic encryption-required
  (`CBAttributePermissionsReadEncryptionRequired`,
  `CBCharacteristicPropertyNotifyEncryptionRequired`); on access, "Core
  Bluetooth tries to pair", and both devices show system alerts
  (`apple-cb-bestpractice-periph.html.txt:59-74`). The app never sees a
  passkey, chooses an IO capability, or lists bonds.
* **Authority.** Usage strings `NSBluetoothAlwaysUsageDescription` and
  `NSBluetoothPeripheralUsageDescription` ("why the app needs access to
  Bluetooth") and an authorization status (`apple-corebluetooth.json`,
  `apple-cbperipheralmanager.json` references). AccessorySetupKit adds
  "privacy-preserving discovery and configuration of accessories" with
  system consent, and "accessory pairing removal and renaming"
  (`apple-accessorysetupkit.json` abstract).
* **Background and restart.** Two background modes, `bluetooth-central`
  and `bluetooth-peripheral` (`apple-cb-background.html.txt:45-61`); the
  system may terminate the app anyway (`:27`), so "state preservation and
  restoration" lets the system keep scanning, connections and published
  services on the app's behalf and relaunch it (`:82-98`). The guide's
  example is a door lock that must reconnect after days (`:81`).
* **L2CAP.** `publishL2CAPChannel(withEncryption:)` creates a listener
  (`apple-cbperipheralmanager.json` references); `CBL2CAPChannel` is "a
  live L2CAP connection".
* **Connection parameters.** Only `setDesiredConnectionLatency(_:for:)`.
* **Praised / painful** (from the model above, not from a survey of
  users): pairing is consistent and needs no app code; the app cannot
  control pairing method, bond list, MTU, PHY or advertising content,
  and the cached table means a changed service needs Service Changed or
  a new device identity.

### Android (and the Companion Device Manager)

* **Model.** Callbacks. A central calls `connectGatt` and gets results on
  `BluetoothGattCallback`; a peripheral opens a `BluetoothGattServer`
  and answers requests from `BluetoothGattServerCallback` such as
  `onCharacteristicWriteRequest` (`android-gattserver.html.txt:11149`).
* **One operation at a time.** Writes can fail with
  `ERROR_GATT_WRITE_REQUEST_BUSY` (`android-bluetoothgatt.html.txt:11960`):
  the app must queue its own GATT operations. This is the most common
  complaint about the Android API (common knowledge, not measured here).
* **MTU, PHY, priority.** `requestMtu`; "starting from Android 14, the
  Android Bluetooth stack requests the BLE ATT MTU to 517 bytes when the
  first GATT client requests an MTU, and disregards all subsequent MTU
  requests" (`android-bluetoothgatt.html.txt:11679-11690`);
  `requestConnectionPriority`, `setPreferredPhy` (`:10733-10757`).
* **Reconnection.** `connectGatt(..., autoConnect)`: first connection
  direct, later ones to known devices with `autoConnect` true
  (`android-gattserver.html.txt:10805-10817`).
* **L2CAP.** `BluetoothAdapter.listenUsingL2capChannel()` and
  `BluetoothDevice.createL2capChannel(int)` (`android-bluetoothgatt.html.txt:10570`).
* **Pairing.** The system shows the dialog; apps can receive
  `ACTION_PAIRING_REQUEST` with a `PAIRING_VARIANT_*` such as
  `PAIRING_VARIANT_PASSKEY_CONFIRMATION`
  (`android-bluetoothdevice.html.txt:10500-10779`).
* **Authority.** `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE` and
  `BLUETOOTH_CONNECT` are runtime permissions the user approves;
  location is needed only if the app derives location from scans
  (`android-bt-permissions.html.txt:892-910`).
* **Companion Device Manager.** The system scans "on behalf of your app
  without requiring the `ACCESS_FINE_LOCATION` permission", filtered by
  `BluetoothLeDeviceFilter`, and the user picks the device; it "doesn't
  create connections on its own"; after association the app may hold
  `REQUEST_COMPANION_RUN_IN_BACKGROUND` and related permissions, and it
  ends with `disassociate()` (`android-companion.html.txt:860-925`). So
  the authority is "this app, this device", granted by a person through
  a system UI.

### Web Bluetooth

* **Central only.** "The first version of this specification allows web
  pages, running on a UA in the Central role, to connect to GATT
  Servers" (`web-bluetooth-whatwg.html.txt:215-220`).
* **Authority.** `requestDevice` with filters and `optionalServices`; the
  page may use only services listed in either (`:607-618`); a chooser is
  shown and "this spec does require a user gesture" to scan (`:487`);
  `getDevices()` returns devices already permitted (`:569`). A blocklist
  excludes services such as HID, `00001812-...`
  (`web-bluetooth-blocklist.txt`).
* **Lesson for erXos.** Access scoped to a device and a set of service
  UUIDs, granted by a person, is the model for an app that is a central.

### Zephyr (and nRF Connect SDK)

* **Declaring a service.** `BT_GATT_SERVICE_DEFINE(name, ...)` places an
  attribute array in an iterable linker section at build time
  (`zephyr-gatt.h:843-846`); `bt_gatt_service_register` adds one at run
  time (`:671`). Each attribute carries permissions such as
  `BT_GATT_PERM_READ_ENCRYPT`, `_READ_AUTHEN`, `_READ_LESC` (Secure
  Connections only) and `_PREPARE_WRITE` (`:60-93`) and read and write
  callbacks (`BT_GATT_CHARACTERISTIC(_uuid, _props, _perm, _read, _write,
  _user_data)`, `:1000`). Notifications: `bt_gatt_notify_cb` (`:1397`).
  Client: `bt_gatt_subscribe`, `bt_gatt_exchange_mtu` (`:2286`, `:1713`).
* **Pairing.** `struct bt_conn_auth_cb` with `pairing_accept`,
  `passkey_display`, `passkey_entry`, `passkey_confirm`
  (`zephyr-conn.h:2241-2363`); the set of callbacks given is the IO
  capability. `bt_passkey_set` sets a fixed passkey under
  `CONFIG_BT_FIXED_PASSKEY` (`:2163-2174`). OOB data for Secure
  Connections: `bt_le_oob_set_sc_data` (`:2131`).
* **Link control.** `bt_conn_le_param_update`, `bt_conn_le_data_len_update`,
  `bt_conn_le_phy_update`, `bt_conn_set_security` (`:1201-1226`, `:1504`).
* **L2CAP CoC.** Credit-based channels with servers
  (`struct bt_l2cap_server`, `zephyr-l2cap.h:672`), per-endpoint credits
  (`:202-203`) and an optional segment-level receive, `seg_recv`, where
  the application gives credits itself (`:568-656`).
* **Testing.** Native builds (`native_sim`), QEMU with a physical or
  virtual controller, and BabbleSim, a simulated radio between simulated
  nRF5x boards (`zephyr-bt-dev.html.txt:150-269`).
* **nRF Connect SDK** builds on Zephyr's host (unverified: its pages were
  not fetched).

### Apache NimBLE

* **Declaring a service.** Arrays of `struct ble_gatt_svc_def` and
  `struct ble_gatt_chr_def`, each characteristic with one `access_cb`
  (`nimble-ble_gatt.h:823-911`), registered with `ble_gatts_count_cfg`
  and `ble_gatts_add_svcs` (`:1064-1095`). Flags carry security:
  `BLE_GATT_CHR_F_READ_ENC`, `_READ_AUTHEN`, `_READ_AUTHOR`,
  `_WRITE_AUTHOR` (`:152-167`); "authorize" asks the app per access.
* **Events.** One `ble_gap_event_fn` per connection or advertising set
  (`nimble-ble_gap.h:1315`) receives `ENC_CHANGE`, `PASSKEY_ACTION`,
  `NOTIFY_TX`, `SUBSCRIBE`, `MTU`, `REPEAT_PAIRING` and PHY changes
  (`:199-220`, `:996-1010`).
* **Repeat pairing.** When a bonded peer pairs again, the app chooses:
  delete the old bond and retry, or ignore (`:985-995`). erXos's design
  instead never replaces a bond by pairing (`design-bluetooth.md:497`).
* **Bond store.** Pluggable read and write functions
  (`nimble-ble_store.h:279-295`) and an overflow event with a ready-made
  "delete the oldest" policy (`BLE_STORE_EVENT_OVERFLOW`,
  `ble_store_util_status_rr`, `:59`, `:745`).

### ESP-IDF (Bluedroid and NimBLE ports)

* Bluedroid: an "app" registers with `esp_ble_gatts_app_register` and
  creates a whole service from an attribute array with
  `esp_ble_gatts_create_attr_tab` (`espidf-gatts.html.txt:138-180`).
  Pairing arrives as GAP events `ESP_GAP_BLE_PASSKEY_NOTIF_EVT` and
  `ESP_GAP_BLE_NC_REQ_EVT`, answered with `esp_ble_passkey_reply` and
  `esp_ble_confirm_reply`; `ESP_BLE_SM_SET_STATIC_PASSKEY` sets a fixed
  passkey; `esp_ble_remove_bond_device` deletes a bond
  (`espidf-gap-ble.html.txt:668-700`, `:4474-4926`).
* NimBLE port: Espressif ships NimBLE's host as an alternative host,
  run in its own FreeRTOS thread by default (`espidf-nimble.html.txt:92-102`).
* Two hosts with two APIs on one chip is itself a lesson: device makers
  pick one early and port later at cost.

### BlueZ, from its D-Bus API man pages only

* **Declaring a service.** "A GATT service is represented by a D-Bus
  object hierarchy"; the application exports an
  `org.freedesktop.DBus.ObjectManager` root and calls
  `RegisterApplication(object, dict)` (`bluez-GattManager.5.html.txt:42-141`).
  Characteristic flags include `encrypt-read`, `secure-read` (server
  only) and `authorize` (`bluez-GattCharacteristic.5.html.txt:455-479`).
* **A characteristic as a descriptor.** `AcquireWrite` gives "file
  descriptor and MTU for writing. Only sockets are supported"; the fd
  closes, with HUP, at disconnection and reconnection
  (`bluez-GattCharacteristic.5.html.txt:212-240`). `AcquireNotify` is the
  same for notifications (`:267`). This is the closest existing thing to
  "a characteristic is a file".
* **Pairing UI is an agent.** A program registers an agent object with
  an IO capability (`RegisterAgent(object, capability)`, default
  `KeyboardDisplay`), and may ask to be the default agent
  (`bluez-AgentManager.5.html.txt:53-110`). The daemon calls
  `RequestPasskey`, `DisplayPasskey`, `RequestConfirmation`,
  `RequestAuthorization`, `AuthorizeService` and `Cancel` on it
  (`bluez-Agent.5.html.txt:48-169`). The device object has `Pair`,
  `CancelPairing`, `Trusted`, `Blocked` (`bluez-Device.5.html.txt:158-391`).
* **Advertising.** An advertisement is an object registered with
  `RegisterAdvertisement` (`bluez-LEAdvertisingManager.5.html.txt:57`).
* BlueZ is GPL-2.0-only (`bluez-GattManager.5.html.txt:171-179`); only
  its man pages were read.

### Qt Bluetooth

* Both roles, "on all major Qt platforms", except the peripheral role on
  Windows (`qt-ble-overview.html.txt:273`). A service is a
  `QLowEnergyServiceData` value passed to `addService`
  (`:520-545`). On iOS it needs the Info.plist usage string (`:574`).
  `requestConnectionUpdate` asks for parameters
  (`qt-lowenergycontroller.html.txt:331`). It is a portable wrapper over
  each platform's stack and inherits their limits.

### Bumble

* Python asyncio objects: `Service`, `Characteristic` and
  `CharacteristicValue(read=..., write=...)` (`bumble-gatt-server-example.py:98-121`);
  pairing through a `PairingDelegate` subclass whose `IoCapability` names
  the five SMP capabilities (`bumble-pairing-delegate.py:91-126`).
* Transports include virtual ones: a local link, VHCI, HCI sockets, the
  Android emulator and an HCI bridge (`bumble-index.html.txt:31-169`).
  erXos already tests against it (`design-bluetooth.md`, "On QEMU against
  Bumble").

### Erlang and Elixir: BlueHeron

* Apache-2.0, version 0.5.4 (`blueheron-hex.json`). Peripheral and
  broadcaster roles done; central role and GATT client not
  (`blueheron-readme-v054.md:29-32`); "The API is quite unstable" (`:34`).
* A service is an Elixir struct with characteristics and a `read`
  function (`:174-200`). It is a library linked into one BEAM that owns
  the HCI transport, with no separation between the radio parser and
  the app. No Erlang library surveyed is a better fit than erXos's own
  stack; BlueHeron's value is as a reference for an Elixir-flavoured
  surface.

### Plan 9 and Inferno

No Bluetooth device in the manual section 3 indexes of Plan 9 4th
edition, 9front or Inferno (files above). There is no prior art for a
Bluetooth file tree in that lineage; a tree for erXos would be its own
design in the style of `/net` (Plan 9's network stack as files) rather
than a port.

### Matter commissioning over BLE

* A Matter device advertises the service `0xFFF6` and serves two
  characteristics, C1 `18ee2ef5-...-9d11` and C2 `18ee2ef5-...-9d12`
  (`chip-ble-uuid.h:104-111`); the transport over them, BTP, is the SDK's.
* The device maker supplies a setup passcode and a discriminator
  (`20202021` and `3840` in the example), or a manual pairing code or QR
  code carrying them, and factory data in a factory partition
  (`espmatter-developing.html.txt:79-103`, `:455-475`).
* What this asks of erXos's API: the service data in advertising
  (Matter advertises its discriminator in `0xFFF6` service data;
  unverified, from the specification not read), a stream-like
  characteristic pair, and BLE used only during commissioning, after
  which the device works over IP (unverified).

### Automotive

* CCC Digital Key: "a standardized ecosystem that enables mobile devices
  ... to securely store, authenticate and share Digital Keys for smart
  vehicles", with sharing of whole-vehicle or partial access
  (`ccc-digital-key.html.txt:59-75`). That it uses BLE with UWB ranging,
  owner pairing in the car, and many simultaneous bonded phones is
  **unverified** (the specification was not fetched).
* Android Automotive's Bluetooth is mostly classic profiles (hands-free,
  audio, phone book, messages) and many paired phones with a priority
  order (**unverified**; page not fetched). For erXos this mostly means
  classic Bluetooth, which `design-bluetooth.md` leaves undesigned
  ("Classic Bluetooth" section).

### Industrial: mesh and profiles

* Zephyr's mesh API has models and provisioning sections
  (`zephyr-mesh.html.txt:146-152`). Mesh runs over advertising, not
  connections (unverified detail), so an API that lets an app send and
  receive non-connectable advertising, or a mesh layer in the Bluetooth
  domain, would be needed.
* SIG profiles (Device Information, Battery, Environmental Sensing) are
  plain GATT services and fit erXos's declaration form as they are.

## What each device class needs from the API

| Device class | Typical shape | Needs |
| --- | --- | --- |
| Consumer gadget (lock, light, tracker) | peripheral; a vendor phone app finds it by service UUID; bonds to one or a few phones | declared services with encrypted or bonded access; manufacturer or service data in advertising; pairing when the user presses a button; bond list and "forget"; reconnection by bond; notifications at the link's pace |
| Industrial sensor or controller | peripheral or broadcaster; maybe central reading other sensors; long life, unattended | advertising-only data (beacons, mesh); connection parameters for power; central role to read sensors; OOB or factory-set commissioning; logs at `/proc` |
| Embedded / headless box | peripheral used for setup (Wi-Fi provisioning, Matter) | pairing with no display: Just Works, OOB (NFC, QR), or a passkey shown somewhere else; an `authenticated` path needs a trusted channel (erXos decision 3) |
| Kiosk | peripheral and central: phones connect to it; it reads scanners, badges, HID | the passkey or a numeric comparison shown on its own screen by its app; central role for accessories; per-user identity of a bonded phone for sessions |
| Automotive head unit | central and peripheral; many bonded phones; classic audio | many connections and bonds; bond priority; per-phone identity; classic profiles (out of LE scope); digital key (L2CAP CoC or GATT, unverified) |

## erXos today

### The model

* **One table, one gate.** Services are checked-in files
  `abi/gatt/NAME.txt`; the manifest selects which a machine serves; the
  table "never changes while the Bluetooth domain lives"
  (`design-bluetooth.md:24-32`). Each characteristic access names a
  level, `open`, `encrypted`, `authenticated` or `bonded`, and one pure
  function decides every access and every notification
  (`design-bluetooth.md`, "One table, one gate").
* **The `ble` facet.** Operations `attach`, `set`, `notify`, `indicate`,
  `reply`; parameter `services`, at most 8 names
  (`abi/services/ble.txt`). The holder of an attached service is its one
  handler; events are `connected`, `mtu`, `subscribed`, `write`,
  `disconnected` (`design-bluetooth.md`, "The `ble` facet").
* **Erlang client.** `erx_gatt` (client), `erx_gatt_service`
  (a behaviour with `init/1`, `handle_write/4`, `handle_event/2`,
  `handle_call/3`, `handle_info/2`), `erx_gatt_serial` (a byte stream over
  a Nordic-UART-shaped service) (`design-bluetooth.md`, "The client").
* **Who holds `ble`.** A configured domain, an installed app (its
  package's `gatt` field narrows the app template's row at install), or
  a start row's template; never the system domain (`design-bluetooth.md`,
  "Who holds `ble`").
* **Advertising.** Flags, the UUIDs of advertised services that have a
  handler, the name and appearance; nothing else
  (`design-bluetooth.md`, "Advertising").
* **Pairing.** LE Secure Connections only, as responder; a window is an
  open fid of the control tree's `pair` file; the opener writes
  `display` (Passkey Entry, erXos shows the passkey, IO capability
  DisplayOnly) or `nodisplay` (Just Works, NoInputNoOutput), and reads
  lines `wait`, `waiting`, `passkey NNNNNN ADDR`, `bonded ...`,
  `failed ...`, `closed timeout`; closing the fid withdraws the pairing
  (`design-bluetooth.md`, "The pairing window"). Fixed passkeys are
  refused by decision 3 ("no passkey is printed on a device or fixed in
  its configuration").
* **Bonds.** At most `bt_bonds_max` (eight: "A ninth bond fails with
  `bonds_full`"); `forget ADDRESS TYPE` and `forget all` on `ctl`; a bond
  is never replaced by pairing (`design-bluetooth.md`, "Bonds and the
  store").
* **Built.** The book's status box: the stack through pairing and the
  bond store is built with host tests; on the Pi 4 it advertises and a
  Mac connects; an echo through an app and pairing have not run on the
  board; installed apps' grants and `bleuart` are designed
  (`docs/book/19-bluetooth.md:3-25`).

### Gaps

1. **The control tree is granted nowhere.** `erx_bt_fs` serves `ctl`
   and `pair` (`erlang/apps/erx_bt/src/erx_bt_fs.erl`), but the Pi 4's
   development manifest declares only the `ble` service and the `line`
   facet for `bt` (`config/manifest/raspi4b-development.txt:553-581`),
   and the QEMU development manifest has no `bt` rows. No session can
   open `pair`, and no store grant is there either, so no image can pair.
2. **No characteristic needs security.** `abi/gatt/` holds only
   `nus.txt`, every access `open`. The gate's levels have no consumer
   yet; Wi-Fi provisioning is the first named one.
3. **Apps cannot be centrals.** The central role is designed only inside
   the Bluetooth domain, for HID ("HID over GATT"); there is no scan,
   connect or GATT-client operation in `abi/services/ble.txt`.
4. **Advertising is fixed.** No manufacturer data, service data, or
   non-connectable or beacon advertising; Matter, beacons, mesh and most
   consumer gadgets need one of them.
5. **Pairing methods.** Passkey Entry with erXos displaying, and Just
   Works. No numeric comparison (DisplayYesNo, which a kiosk with a touch
   screen could offer), no erXos-side keyboard entry, no OOB yet
   (named as future in decision 3).
6. **No per-bond identity for apps.** "No handler hears a bonded phone's
   identity address" (`design-bluetooth.md`, "The `ble` facet"); a
   handler learns only `bonded := true`. A kiosk or a car that wants to
   know *which* bonded phone is present has nothing stable to key on.
7. **Bonds are machine-wide.** Any bond reaches every `bonded`
   characteristic of every app. Android's CDM and Apple's
   AccessorySetupKit scope an association to one app; erXos has no such
   scope.
8. **Link control.** The server answers Exchange MTU with 247; no
   connection-parameter, data-length or PHY request; no L2CAP CoC (a
   bulk channel for firmware updates or a digital key).
9. **One connection by default**, at most `bt_connections_max`.
10. **C and shell programs.** The only client is Erlang. A native
    program "opens files through its handler" (`design-packaging.md:130`,
    citing `design-programs.md`, "Descriptors and files"), so a file tree
    would be its route; there is none for GATT today.
11. **Restart behaviour is right but unadvertised.** Attributes are
    configuration, so a crashed handler leaves the service serving its
    declared values and its supervisor's restart re-attaches. This is
    already what Apple's "state restoration" buys at much greater cost.

## Where the trees live in the namespace

The control tree (`ctl`, `pair`, and any bond, connection or service
files a design adds) needs a path. Existing homes:

* `/proc/bt` is what the Bluetooth domain reports as observed state
  (`design-bluetooth.md`, "Inspection"); it holds no control.
* `/svc/NAME` is "an app's own tree": the providing session is the one
  running NAME's start row (AT2), only sessions whose template holds
  `start` hold `svc` grants, and "the system domain is never a grantee"
  (AT8); system commands reach it only through `erx_svc_client`, bounded
  by `svc_wait_max` (AT6) (`design-app-trees.md:1-20`, `:66-78`).
* System services' own trees sit at their own top-level names:
  `/media/diskN` from the media domain (`design-drives.md:12`, `:138`),
  `/machine/ctl` (`design-system.md:2266-2273`), and device trees
  `/dev/gpio`, `/dev/i2c1` and others, "each served by its driver ...
  reached through a facet the manifest grants" (`design-header-io.md:63-66`).

| Option | For | Against |
| --- | --- | --- |
| **Top-level tree per system service**, e.g. `/bluetooth` (Plan 9's `/net` style) | matches `/media` and `/machine`; principle 5's "a service is a file tree its owner serves"; one facet in the checked table, as every grant is; `/proc/bt` keeps observation and the tree keeps control, the split CLAUDE.md names | one more root name; needs a naming rule for system service trees so roots do not sprawl; the root of `ls /` grows with services |
| **Widen `/svc` to system services** | one place to look for "things that take commands"; reuses `erx_svc_client`'s bounded wait, which a system command reading a tree served by a radio-facing domain also wants | contradicts AT2 and AT8 as written: the Bluetooth domain is a configured domain of the system principal, not a start row, and `/svc` would mean two different provider rules; `service bt status` would imply `service` controls `bt`, which it does not |
| **Under `/dev`**, e.g. `/dev/bt` | short; where a UNIX user looks for hardware | the Bluetooth domain "holds no device" (`design-bluetooth.md:47-51`); the tree is a protocol stack's control, not a device, so a `/dev` name wears the shape of something it is not (principle 5, "no skeuomorphism"); the drives design already refuses `/dev` sources (`design-drives.md:1599`); the controller's own line is the device and lives in the system domain |

Per-connection names, if a design adds them, must follow B10, "A
connection's name never names a later connection"
(`design-bluetooth.md`, Requirements): a never-reused counter, as `Conn`
is, not the controller's handle.

## Candidate directions

These are directions for the design agent to weigh, not a design. They
are not exclusive: A is the base, B and C are surfaces on it, D is
orthogonal.

### A. Extend the declarative core and the Erlang behaviour

Keep `abi/gatt` and the gate as the one source of what is served and
how it is protected; grow what a declaration and the facet can say.

* Declarations gain advertising content (service data, manufacturer
  data, connectable or not) and a characteristic kind for streams (the
  Nordic UART shape, Matter's C1/C2).
* The facet gains a central side: `scan(Filter)` delivering reports for
  declared UUIDs only, `connect(Address | Bond)`, and a client behaviour
  (`erx_gatt_client`) whose operations are queued by the stack, never by
  the app (Android's busy error is the warning). The grant names the
  remote service UUIDs an app may use as a client, as Web Bluetooth's
  `optionalServices` does.
* Handlers get a stable per-bond token (an opaque number or a hash of the
  identity under a machine key), never the address, so a kiosk or a car
  can tell phones apart without the identity address leaving the domain.
* Optional: bonds scoped to an app (CDM's model), so a bond made in an
  app's window reaches only that app's `bonded` characteristics.

For: smallest change; keeps "one table, one gate" and the static table
(the same choice Zephyr and NimBLE make); Erlang-first (principle 1).
Against: a C program, a shell script or a tool on the host still cannot
use BLE; every new capability is a facet operation.

### B. A Plan 9 style file tree per service and per connection

The Bluetooth domain serves a tree, for example:

```text
/bluetooth/ctl                     forget ADDRESS TYPE | forget all
/bluetooth/pair                    the pairing window, as today
/bluetooth/bonds/N/status          one bond: level, token, last seen
/bluetooth/conn/N/{status,ctl}     one connection (N never reused)
/bluetooth/gatt/SERVICE/CHAR/value   write = a write; read = current value
/bluetooth/gatt/SERVICE/CHAR/events  read blocks for writes, subscriptions
```

The gate still decides every access; the tree is a view of the facet,
not a second authority.

For: reaches C programs through `open`/`read`/`write` on their handler
(`design-packaging.md:130`) and shell scripts; principle 5 (Plan 9 files
where they fit); BlueZ's `AcquireWrite`/`AcquireNotify` show a
characteristic as a descriptor works for streams.
Against: GATT is message-shaped, with per-write answers (application
error codes), MTU limits and indications that wait for a confirmation;
mapping these to `write` return values and `errno` loses detail or
invents conventions; a "file" whose write is a remote request may
promise what a file does not (the "familiar only where true" check);
one handler per service has to become "one opener of `events`".

### C. Erlang facet as the one API, files only where they fit

The facet (A) is the interface; the Bluetooth domain serves files only
for what is naturally a file:

* the operator's control tree (`ctl`, `pair`, bond list), granted to
  administrators and to apps the manifest names, at one of the
  namespace options above;
* stream characteristics as a byte stream, which `erx_gatt_serial`
  already is, exposed to a native program as a descriptor its handler
  derives (the way a tty or a pipe is), not as a general GATT tree.

A native program that needs full GATT gets a small C library over the
same facet through `liberx` (unverified that `liberx`'s program layer can
carry facet messages; not read for this record).

For: one model for maintainers; files where a UNIX user would expect
them (a serial line, a control file); no invented GATT-as-files
conventions. Against: two client surfaces (Erlang and C) to keep in
step, unless the C one is generated from `abi/services/ble.txt`.

### D. Pairing UX reaches the device's own UI

Independent of A to C: who shows the passkey or asks for confirmation.

* **Today's agent is the opener of `pair`.** It is BlueZ's agent model
  expressed as a file: whoever holds the open fid sees the passkey and
  ends the pairing by closing it. A kiosk app granted the control tree
  shows the passkey on its screen; an administrator sees it over SSH.
* **Add numeric comparison** (`confirm NNNNNN ADDR` line, answered by
  writing `yes`/`no`) for kiosks and head units with a screen and a
  touch: it is the method phones handle best and the only authenticated
  one where neither side types.
* **Headless devices.** A `nodisplay` window opened by a physical button
  (a GPIO the app watches) gives Just Works, reaching `encrypted` only;
  `authenticated` needs OOB (NFC, or a QR code printed per device that
  carries OOB data rather than a fixed passkey) per decision 3. Zephyr
  and ESP-IDF offer fixed passkeys (`zephyr-conn.h:2163-2174`,
  `ESP_BLE_SM_SET_STATIC_PASSKEY`); erXos decided against them.
* **System-owned consent** (Android CDM, AccessorySetupKit, Web Bluetooth
  choosers) is the model for an app that wants to be a central: the
  system, not the app, shows the device list and the person's choice
  becomes the grant.

Trade-offs: numeric comparison needs the window to state DisplayYesNo
and a two-way line protocol on `pair`; app-scoped bonds (A) and
system-owned choosers (D) together give the CDM model but add a
per-app dimension to the bond store, which today is one blob of up to
eight bonds.

## Open points for the design

* Whether apps get the central role at all in 0.2, or only the HID
  function inside the Bluetooth domain.
* Whether bonds stay machine-wide or become per-app.
* Which namespace option holds the control tree, and which images grant
  it (gap 1 blocks any pairing test on hardware).
* Whether a C client is a file tree, a descriptor for streams only, or a
  generated library.
* Whether advertising content belongs in `abi/gatt` (static) or in a
  facet operation (dynamic, for beacons and Matter's discriminator).
