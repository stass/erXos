# The echo app

`examples/echo` is the Bluetooth echo as an installed app
([design-bluetooth.md](../../docs/design-bluetooth.md#decisions),
decisions 6 and 7): every byte a phone writes to Nordic's UART service,
`nus`, comes back to that phone, in order, as notifications of the
service's `tx`. A terminal app for Nordic's UART service shows what it
sent echoed. It is built as a third party builds an app, through the
SDK alone ([design-packaging.md](../../docs/design-packaging.md#examples)).

```text
app echo
  gatt nus
  applications erx_echo
  license "BSD-2-Clause"
```

The package names no `needs`: `gatt nus` is how an app takes `ble`
([design-packaging.md](../../docs/design-packaging.md#the-declaration)).
Admission keeps `nus` only when the machine's `apps` row offers it in
its `gatt` field and no other admitted app holds it, and the app's
session's `ble` grant names that service alone, so the app reaches no
other GATT service and no other app's.

## What it does

`erx_echo` starts the serial service's handler, `erx_gatt_serial`, for
`nus` and sends each `{serial, Conn, Bytes}` back with
`erx_gatt_serial:send(Conn, Bytes)`, to the link the bytes came from and
no other. Once its handler has attached it logs `erx_echo: echoing nus`.
It logs nothing of what a phone writes. Without the grant its start
fails with the attach's refusal and the session ends.

## Where it runs

The Bluetooth suite's app cell boots QEMU `virt` with the package in
the image, enabled, under an `apps` row that offers `ble` and `gatt
nus`, and Bumble's serial peer writes 64 KiB through it
(`tools/lib/erx/bt_domain.rb`). Decision 7 has the Raspberry Pi 4's
development card carry it as its second package.

The host test `test/host/erx_bt_gatt_client_test.rb` runs the module
over the serial service against the real registry: two links' writes
each come back on their own link.
