# QEMU virtio-input: behavioural facts for a driver author

Date: 2026-11-14. Recorded by a facts writer who read the QEMU sources below; design and
code agents read this record, not the sources. Everything here is in the writer's own words:
no code, no copied comments, no structure mirrored from QEMU.

## Sources

QEMU, tag `v11.1.3` (the version installed on the development host: `qemu-system-aarch64
--version` reports 11.1.3). Fetched over HTTPS from the project's GitLab, read as data only.

| File | URL | SHA-256 |
|---|---|---|
| `hw/input/virtio-input.c` | https://gitlab.com/qemu-project/qemu/-/raw/v11.1.3/hw/input/virtio-input.c | `0c3cecb7be4b5a115358643ca95788fa111d17efe41ecb3c0124bf73c7d4aad5` |
| `hw/input/virtio-input-hid.c` | https://gitlab.com/qemu-project/qemu/-/raw/v11.1.3/hw/input/virtio-input-hid.c | `aae90a22fda46a0a61939cf3f4e56f93bf751215dffb3d2ba643b7f09a3693f9` |
| `hw/virtio/virtio-mmio.c` | https://gitlab.com/qemu-project/qemu/-/raw/v11.1.3/hw/virtio/virtio-mmio.c | `fee8f5fb996a0baa7f48a6c9be388d2408e49de9922d77009df55b0b7415acdb` |
| `hw/virtio/virtio-config-io.c` | https://gitlab.com/qemu-project/qemu/-/raw/v11.1.3/hw/virtio/virtio-config-io.c | `f9c2364769324d76c5f5701c97b9b378114001a38ce19be010772f62cf37038e` |

Local copies (outside the tree): `~/erxos-scratch/ref-qemu-11.1.3/`.

The OASIS virtio 1.2 specification, csd01, fetched from
https://docs.oasis-open.org/virtio/virtio/v1.2/csd01/virtio-v1.2-csd01.html, SHA-256
`e18d68ee81b03bb9d8fb493356704fa77e3a9eac1c10f79111940cbd482f7bc1`, local copy in
`~/erxos-scratch/ref-virtio-1.2/`. It is not GPL; its facts are in their own
section at the end.

## QEMU facts

### Delivery of an update

1. **An update is held by the device until its end.** Each event QEMU's input layer hands
   the device is appended to a list the device keeps for itself. Nothing reaches the guest
   until an event of type `EV_SYN` with code `SYN_REPORT` is appended; then the device tries
   to deliver everything it holds, that report included, as one update.
   (`virtio-input.c`, lines 32-44.)
2. **That device-side list has no bound.** It grows by one entry per event until the next
   `SYN_REPORT`; the guest cannot limit it. (`virtio-input.c`, lines 32-38.) The HID devices
   end each batch of input with a `SYN_REPORT` of their own (`virtio-input-hid.c`, lines
   152-162), so in practice an update is short.
3. **All or nothing.** At the report, the device takes one available event-queue buffer for
   each event it holds. If it runs out before it has one for every event, it gives back the
   buffers it took, unused, empties its list, and the whole update is gone: no event of it is
   delivered, and no `SYN_DROPPED` is sent, now or later. The only trace is a QEMU trace
   point ("queue full"). (`virtio-input.c`, lines 46-57.)
4. **An update longer than the posted buffers can never arrive.** It follows from fact 3: a
   driver must keep at least as many buffers posted as the longest update has events, the
   report included.
5. **On success**, the device writes one event into each buffer, in the order the events
   were produced, marks each used with the number of bytes it wrote (the event's 8 bytes, or
   fewer if the buffer was shorter), then raises one used-buffer notification for the whole
   update. (`virtio-input.c`, lines 60-69.)
6. **Nothing is sent before the driver is ready.** Events that arrive while the device is
   inactive are discarded on the spot, not held. The device becomes active when the driver
   sets `DRIVER_OK` in the status register, and inactive again on a device reset.
   (`virtio-input.c`, lines 28-30, 192-205, 208-219.)

### Queues

7. **Both queues have 64 entries.** The device creates the event queue (index 0) and the
   status queue (index 1) with a maximum size of 64 each. (`virtio-input.c`, lines 262-263.)
8. **The event queue's own notifications do nothing.** The device ignores the driver's
   kicks on the event queue; it looks for buffers only when it has an update to deliver.
   (`virtio-input.c`, lines 71-74.)
9. **The status queue** takes driver-to-device events of the same 8-byte layout (keyboard
   LEDs, for the keyboard). The device reads each buffer, hands the event to the device
   type's status handler, returns the buffer, and notifies.
   (`virtio-input.c`, lines 77-100; LEDs in `virtio-input-hid.c`, around line 212.)

### Configuration space

10. **Reading.** A read of the configuration area returns the entry that matches the
    current `select` and `subsel`. If no entry matches, the whole area reads as zeros, so
    `size` is 0. (`virtio-input.c`, lines 162-173.)
11. **The configuration area is shorter than 136 bytes.** Its length is the largest data
    size among the device's entries plus the 8-byte header, not the full 8 + 128.
    (`virtio-input.c`, lines 250-261.) On the modern (version 2) MMIO path, a 32-bit read
    that would run past that length returns all-ones and touches nothing. A driver that
    reads all 34 words of the 136-byte layout therefore gets `0xff` bytes past the area's
    end. They lie beyond `size` and must not be interpreted. (`virtio-config-io.c`, lines
    138-151; MMIO dispatch in `virtio-mmio.c`, lines 130-140.)
12. **Writing `select` and `subsel`.** On the modern MMIO path, a write at the
    configuration area accepts 1-, 2- or 4-byte accesses (`virtio-mmio.c`, lines 279-290).
    A 4-byte write stores its four bytes, little-endian, at that offset of the device's copy
    of the area, provided they fit inside the area's length; a write that does not fit is
    ignored. Either way, after storing, the device's set-config handler runs.
    (`virtio-config-io.c`, lines 187-201.) The virtio-input handler takes byte 0 as the new
    `select` and byte 1 as the new `subsel` and ignores every other byte.
    (`virtio-input.c`, lines 175-184.) So on QEMU a single 32-bit write of word 0, select in
    the low byte and subsel in the next, selects a query. The `size` byte written along with
    it has no effect, because the next read refreshes the area from the matching entry
    (fact 10).
13. **Every such write raises a configuration-change interrupt**, whether or not the
    selection changed (`virtio-input.c`, line 183). A driver sees `CONFIG_CHANGE` (bit 1)
    in the interrupt status after each query, and must acknowledge it.

### What the devices declare and send

14. **The event layout** is 8 bytes, little-endian: 16-bit type, 16-bit code, 32-bit value.
    QEMU fills each field with the evdev constants and converts each to little-endian.
    (`virtio-input-hid.c`, lines 89-128.)
15. **Keys and buttons** are `EV_KEY` with value 1 for down and 0 for up. QEMU never sends
    the repeat value 2 for a key it injects. (`virtio-input-hid.c`, lines 89-94 and
    104-108.) The keyboard declares an `EV_REP` bitmap of size 1 with no bits set
    (`virtio-input-hid.c`, lines 271-273) and an `EV_LED` bitmap holding Num Lock,
    Caps Lock and Scroll Lock (lines 274-280).
16. **The wheel** is `EV_REL` `REL_WHEEL`. Each wheel-up button press sends +1 and each
    wheel-down press sends -1; the wheel buttons' releases send nothing.
    (`virtio-input-hid.c`, lines 95-103.) A button with no evdev mapping is logged as a guest
    error and not sent (lines 109-114).
17. **Relative and absolute motion.** A relative move is `EV_REL` with the axis's code and
    the move as its value. An absolute position is `EV_ABS` with the axis's code and the
    position as its value. Each axis is its own event, followed by the batch's
    `SYN_REPORT`. (`virtio-input-hid.c`, lines 117-128.)
18. **Multi-touch** (the multitouch device only) sends `EV_ABS` events with the `ABS_MT_*`
    codes, a slot and a tracking id. (`virtio-input-hid.c`, lines 129-145.)
19. **The tablet's configuration.** `EV_BITS` for `EV_ABS` is a 1-byte bitmap with
    `ABS_X` and `ABS_Y` set (`virtio-input-hid.c`, lines 398-403). `EV_BITS` for `EV_REL`
    is a 2-byte bitmap with only `REL_WHEEL` set (lines 405-411). `ABS_INFO` for `ABS_X`
    and for `ABS_Y` each answers with the absinfo layout's size (lines 413-424).
20. **What ABS_INFO carries.** Only `min` and `max` are set, to QEMU's input-layer
    constants `INPUT_EVENT_ABS_MIN` and `INPUT_EVENT_ABS_MAX`. `fuzz`, `flat` and `res`
    are zero, and no current value is reported. (`virtio-input-hid.c`, lines 413-424.)
    *Unverified:* the numbers those two constants stand for. They are defined in
    `include/ui/input.h`, which was not fetched; the writer recalls 0 and 0x7fff and has
    not checked.
21. **Identification entries.** Each HID device answers `ID_NAME` with a fixed string
    ("QEMU Virtio Keyboard", "QEMU Virtio Mouse", "QEMU Virtio Tablet",
    "QEMU Virtio MultiTouch") and `ID_DEVIDS` with fixed vendor, product and version numbers.
    (`virtio-input-hid.c`, lines 21-24, 258-262, 331-335, 385-389.)

## virtio 1.2 facts (OASIS specification, not GPL)

- **4.2.2.2, MMIO driver requirements.** In the device-specific configuration space, the
  driver must access 8-bit fields with 8-bit accesses, 16-bit fields with aligned 16-bit
  accesses, and 32- and 64-bit fields with aligned 32-bit accesses. `select`, `subsel`,
  `size` and the bitmap bytes of virtio-input are 8-bit fields.
- **5.8.1.** The input device's id is 18.
- **5.8.2.** Queue 0 is the event queue and queue 1 the status queue.
- **5.8.3.** The device has no feature bits of its own.
- **5.8.4.** The configuration layout is `select`, `subsel` and `size` (one byte each),
  5 reserved bytes, then a 128-byte union (a string, a bitmap, an axis's absinfo or device
  ids). `EV_BITS` with an event type as subsel returns that type's code bitmap, with a
  non-zero size when the type is supported. `ABS_INFO` with an axis as subsel returns that
  axis's absinfo: min, max, fuzz, flat, res.
- **5.8.5.1.** The driver must set both `select` and `subsel`, in either order, before it
  reads, must write no other configuration field, and should check `size` before it uses
  the data.
- **5.8.5.2.** The device must set `size` to zero for a select and subsel it does not
  support.
- **5.8.6.** Events on both queues use one 8-byte layout of type, code and value, filled
  as evdev fills them but little-endian.
- **5.8.6.1.** The driver should keep the event queue populated. Its buffers must be
  device-writable and at least one event long. Status-queue buffers must also be at least
  one event long. The driver should ignore events it does not recognize.
- **5.8.6.2.** The device may drop events when the event queue lacks buffers. It should not
  drop part of an update: it should either buffer or drop the whole sequence up to its
  `EV_SYN`. QEMU's behaviour (facts 1-4) is the "drop the whole update" choice.
