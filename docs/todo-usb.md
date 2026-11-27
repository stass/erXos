# TODO: USB

Open work on the USB stack and its class drivers. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Bugs by subsystem

* [Medium] USB, `erlang/apps/erx_usb/src/erx_usb_bot_core.erl`: on a Pi 4 an 8 GB FAT32 stick held a
  removal about 90 s before the engine logged `medium LUN 0 ended: device` (board time 150.6 s), five
  times `blk_in_flight_ms` (18 s), and the reset recovery that followed timed out in
  `reset_pipe` 31 s later. The FAT server issued only a handful of sectors for that removal (a host
  replay counts 4 reads and 3 writes), so the stick stopped answering. Which wait outlived the
  deadline is unverified: the core checks the deadline on a tick only while a bulk transfer is
  posted, and otherwise only once the function's own calls (control transfers, `reset_pipe`, each
  bounded by the controller) return. Settled by a board run with the volume's failure log
  (`erx_media: volume sN ended: its commit failed: ...`) and the BOT engine's step trace; the fix
  is a deadline that holds across recovery, not a longer one.
* [Low] USB, `erlang/apps/erx_usb/src/erx_usb_bot.erl`: a medium whose function ends (a stick unplugged, a crash)
  logs `ready` and never `ended`: the function logs only the ends it sees itself (its transport's and the
  engine's `medium_ended`). Log it where the function ends, probably in the bus.
* [Medium] USB, `erlang/apps/erx_usb/src/erx_usb_bot.erl`: the two medium lines (`ready`, `ended`) are logged
  on every cycle of a removable LUN that answers NOT READY or UNIT ATTENTION and then ready again, about one
  pair per `usb_bot_poll_ms` per LUN, so a device chooses how many lines the domain logs (design-usb.md R6).
  Log a medium once per unit and count repeats in the inspection record, as the diagnostics row does.
* [Medium] USB, the USB domain's figures (`config/manifest/qemu-virt-development.txt` and
  `config/manifest/raspi4b-development.txt`, `limits usb`, `share usb`):
  its memory, 32 MiB with outer 1 MiB, and its grant, 100 mcpu on CPU 0, are not measured. Measure the domain
  with `Footprint` as the PCIe row was (its largest pool use at rest and with a keyboard typing, rounded up
  with 2 MiB of headroom), and its CPU while a keyboard types, then set the row and move the totals it
  counts (the system principal's memory, `root_memory`).
* [Low] USB, the review's open points on the input tree's hand-out: the USB domain's `connections 2` has no
  room for a display incarnation minted before the old connection is unmapped (design-system A3); the places'
  host fixture finds the grants supervisor through the mint's links (`erx_usb_places_prop:mint_grants/1`)
  rather than starting `erx_fs_grants` itself; the regression case
  `the_mint_provides_before_the_report_and_the_controllers_start_after_test` has no seeded fault;
  `Manifest::Edit.without_domain` would lower a limits record two peers share twice; `erx_fs_mint`'s
  moduledoc lists its callers (and misses `login_keys`); and `erx_driver_ctl` and `erx_winfs` each repeat
  `erx_fs_mint:mint_request/3`'s envelope check.
* [Low] USB, the input tree's service name (`erx_usb_places_sup:start_mint/1`,
  [design-usb.md](design-usb.md#hid-reaches-the-display)): every USB domain's mint names its service
  `usb_input`, written at the mint's start, so a manifest with two USB domains that feed one display cannot
  give each its own service row. Name the service from the manifest, as the display's own service name
  reaches the display domain. A domain with two controllers is not affected: it runs one set of places and
  one mint, and its controllers share the eight input numbers.
* [Medium] USB, the boot mouse's transfer length (`erx_hid_core:plan/2`, `erx_usb_hid`;
  [design-usb.md](design-usb.md#from-reports-to-records)): in the boot protocol the transfer is the boot
  layout's 3 bytes; a boot mouse that sends longer boot reports (unverified: whether HID 1.11, Appendix B.2,
  lets bytes from 3 on be device-specific) babbles on the shorter transfer, halts its pipe and ends the
  function. Check B.2 and, if so, size boot transfers to the endpoint's packet size, at most
  `hid_input_report_max`.
* [Low] USB, a HID interface whose report-descriptor read always times out (`erx_usb_hid`,
  `erx_usb_bus_core`): a timeout counts toward `usb_function_restarts_max`, so a non-boot interface that times
  out every time is restarted to the limit and then the whole device is given up, a composite keyboard's
  working interface with it. Fails safe (replugging recovers it). If it shows up, end such an interface
  unusable once past the limit instead of detaching the device.
* [Medium] USB, a BOT function that cannot drive its interface (`erx_usb_bot_core`, the BOT function;
  [design-usb.md](design-usb.md#ports-hubs-and-devices-the-bus-core)): the bus core takes
  `{shutdown, {unusable, Reason}}` as a final end, but the BOT engine stops on a Get Max LUN answer above 15
  (`{error, {max_lun, Max}}`), which the design lists as a refusal like `no usable report`; unless the BOT
  function ends with the unusable shape, the core counts it, restarts it three times and gives up the
  whole device, a composite device's other functions with it. Say in the BOT section which of its stops end
  unusable (`max_lun`, `not direct access`, `block length`) and end the function so when it is built.
* [Medium] USB, the controller core's EP0 rules (`erx_xhci_core`, [design-usb.md](design-usb.md#the-controller-process)):
  three choices the design does not name. EP0's control requests wait in order in the core, one posted at a time, and
  a pipe that leaves `open` answers what waits on it as a post (`set_pipe/3`), so one function's STALL on a composite
  device answers another's queued request, a pipe reset's CLEAR_FEATURE included, `{error, resetting}`, and that
  reset fails; keeping the queue across EP0's own reset would avoid it. When EP0's reset after a halt fails, the halted
  request is answered with its own result and EP0 stays `halted`, against "never a reason the pipe stays unusable"; the
  abort's rule (fail the controller) may fit better. A NIF refusal of a transfer reaches the caller raw as
  `{error, full}`, an answer `erx_usb_pipe` does not list. Decide each in the design and pin it in the cases.
* [Medium] USB, the controller core's exploration (`test/erlang/erx_xhci_core_tests.erl`): at most one caller's post
  per pipe, so a second bulk transfer left on a halted ring is never explored; the `stopped` answers of a restarted
  ring always precede the command's completion, an order the design does not fix; answer contents are not checked
  against what the model delivered; no invariant catches EP0 left halted after a stall (only the trace case does);
  and bus commands never share the command queue with resets.
* [Medium] USB, a queue's state for `reset_pipe` (`erx_xhci_core`, the device NIF;
  [design-usb.md](design-usb.md#the-controller-process)): the core plans a reset from the queue's state as the
  NIF reports it, asking with the action `{queue_state, Pipe}` and taking the answer `{queue_state, Pipe, Report}`
  (`idle`, `busy`, `stopped` or `halted`), but the NIF's interface names no call that reports a queue's state. Add
  one to the device NIF, or derive the state in the core from what it posted and what completed, and say which in
  the design.
* [Medium] USB, a request to a hub's EP0 that is in its own reset (`erx_xhci_core`,
  [design-usb.md](design-usb.md#the-controller-process)): an internal request is posted as any other and
  answered `{error, resetting}` or `{error, halted}` at once, so an abort's CLEAR_TT_BUFFER behind a hub whose EP0 is
  being reset after a stall fails the controller, and a failed address is answered `{error, {tt_clear, resetting}}`,
  which detaches the hub. Waiting for the hub's EP0 to open, within the request's deadline, would avoid both; decide
  it with the EP0 rules above.
* [Medium] USB, the controller core's exploration of slot reuse (`erx_xhci_core`, `test/erlang/erx_xhci_core_tests.erl`):
  the pipe world explores one device and the address world one failed address, neither enabling a freed slot
  again nor detaching the hub, so the interleavings where a slot's old answers meet its next device are covered
  only by single traces (a reset step answered after the slot's reuse, a detached reference left bound). Add a
  second device enabled at the freed slot with the same endpoint, and the hub's detach, as world events.
* [Low] USB, the translator's clear names its hub by slot (`erx_xhci_core`, [design-usb.md](design-usb.md#the-controller-process)):
  a failed address's CLEAR_TT_BUFFER and a reset's are posted on `{HubSlot, EP0}`. That a detached hub's slot is not
  given to another device first rests on the order of the command queue, and in one order (the hub detached while
  the address is in flight, an Enable Slot queued before the address fails) only on the new device's EP0 not yet
  existing when the clear is posted. Naming the hub by its reference, resolved when the clear is posted, would
  make it hold by construction.
* [Medium] USB, the bus core and the controller core (`erx_usb_bus_core`, [design-usb.md](design-usb.md#ports-hubs-and-devices-the-bus-core)):
  the code differs from the design in two places. A detach while Address Device is in flight releases the
  address-zero turn, which the code derives from the port's state alone, before the controller answers the command,
  so the next port's reset can start while the detached device's address is still being set; the design holds the
  turn with the one Address Device sent and not yet answered, set only by the bus core's request-making function
  and cleared only by its answer, which is never dropped as stale, and has the controller answer every Address
  Device (`{error, gone}` when still unposted at the detach) with the failed address's Disable Slot being the
  teardown's. And the code has no case for `{error, {tt_clear, R}}`: `value/1` throws it as any refusal of the
  `addressing` step (`erx_usb_bus_core.erl:337-339`, `:386-388`), giving up the addressed device's own port, where
  the design detaches the translator's hub, whether or not the addressed device is still
  attached ([The controller process](design-usb.md#the-controller-process), "A failed address"). Bring both
  to the design, with the seeded faults its Verification table names.
* [Medium] USB, the bus core's re-read after clears (`erx_usb_bus_core`, [design-usb.md](design-usb.md#hubs)):
  a read that saw changes queues its port again until a read sees none, and `handled` waits for an empty queue, so
  on an external hub a port whose change bits set again faster than one clear and read (a device toggling its
  pull-up) holds back the hub's next report while it lasts: a sibling port's unplug or plug goes unseen until it
  stops, and the hub's EP0 carries reads and clears back to back. The root hub is not affected. Two ways out:
  answer `handled` once every target the report named has been read once since it, re-reads going on in the queue;
  or, as FreeBSD bounds it (`usb_hub.c:616-637`, one clear and one fresh read), leave the changes a re-read sees
  latched at an external hub for its next report.
* [Low] USB, the bus core's enumeration (`erx_usb_bus_core`, [design-usb.md](design-usb.md#ports-hubs-and-devices-the-bus-core)):
  step 3, the language table and the manufacturer, product and serial strings, is not run, so a device's
  inspection record has no strings; a failure there fails nothing, so adding it is a step between `device` and
  `config_head` with the strings kept on the device.
* [Medium] USB, the bus core's enumeration tests (`test/erlang/erx_usb_bus_core_tests.erl`): no case reaches a
  multi-TT hub (SET_INTERFACE's setup bytes, `multi_tt => true` in Configure Endpoint, `multi => true` in a
  child's translator), a refused `bMaxPacketSize0`, a SuperSpeed hub-class device or a malformed descriptor
  answer; add a multi-TT hub kind and targeted cases, with seeds for the EP0 bound loosened and SET_INTERFACE's
  fields swapped. A full-speed hub gets hub fields and possibly the MTT flag, which FreeBSD
  sets only at high speed (`controller/xhci.c:2662-2690`).
* [Medium] USB, the bus core's exploration reduction (`test/erlang/erx_usb_bus_core_tests.erl`, `taken_alone/2`):
  the answer choices/1 takes alone is chosen from the model's world, and its independence from every other choice is
  argued from what `enumerated/6`, `configured/3` and `settle/3` do, not checked. A step that fails a device on a
  well-formed answer (the refused `bMaxPacketSize0` or malformed-descriptor kinds above) or a deadline on a step after
  the settle would break the argument silently. Check it instead: in `follow/2`, assert for every answer taken alone
  that its actions are only the device's next request, its `start` or its new hub's `power_on`, with the deadline
  unchanged and no detach.
* [Medium] USB, the bus core's seeded depths (`test/host/erx_usb_bus_core_test.rb`): each exploration seed names a
  depth that must lie within one of the test module's `?DEPTHS`, and nothing checks that; export the depths and have
  the host test assert it, so dropping a depth from the module cannot leave a seed caught only by its own run.
* [Low] USB, the bus core's exploration (`test/erlang/erx_usb_bus_core_tests.erl`): the simulated bus never ends a
  reset with the port disabled, never presents a low-speed device or a root port speed the controller cannot run,
  so `{disabled, reset_disabled}` and `unsupported_speed` are reached by no case, and it checks no route or
  translator parameter of Address Device. With one external hub it cannot reach a hub given up while a port below it holds the
  turn and another hub could reset; `a_hub_given_up_keeps_its_childs_turn_test` covers that case alone.
* [Medium] USB, the TRB ring form's contexts, settled from the xHCI specification before the board pass: a non-EP0
  control endpoint takes index
  2n + 1 (xHCI 4.5.1).
* [Low] USB, a USB 3 root port after a disable (`erx_xhci_core`, port_operation/2): writing PORTSC's PED to disable a
  USB 3 port leaves it in the Disabled link state, which leaves only through a PLS write of RxDetect with LWS set
  (xHCI 1.2, 5.4.8, p. 406); the core writes no PLS, so the port stays dead until the controller restarts. Nor does
  the core issue a warm reset (WPR) for a port in SS.Inactive, so such a port also waits for a restart.
* [Medium] USB, events left after a bounded interrupt pass (`erx_xhci_core`, drained/2; design-usb.md, "Completing"):
  a pass that stops at `xhci_events_per_interrupt` acknowledges the line with events still on the ring, which a next
  pass reads only if the controller raises the interrupt again. FreeBSD gets that by writing ERDP with its busy bit
  (EHB) set (xhci.c:1191-1195); the TRB ring form's `complete/2` must publish ERDP the same way, stated in its design
  with the xHCI section that requires it (not yet read) and covered by the model controller's test.
* [Low] USB, the TRB ring form's design text (design-usb.md, "Two rules every ring keeps, on every controller"): it says a transfer that
  continues past the link sets the link's chain bit, but each control stage is a TD of one TRB (xHCI 4.11.2.2), so no
  TD of the form spans the link and the sequencer never sets it. design-device-dma.md's refusals list no answer for a command refused while another is
  in flight or for want of a free block (`ERX_DEVICE_TRB_REFUSE_FULL`), nor for a post on a queue the command in
  flight holds (`ERX_DEVICE_TRB_REFUSE_HALTED`).
* [Medium] USB, the BOT function's test gaps (`erx_usb_bot`, [design-usb.md](design-usb.md#the-bot-engine)): `unit/2` has no host
  test of its own, and the model stick covers no removable medium change, UNIT ATTENTION, READ CAPACITY(16), ILLEGAL REQUEST
  readiness or READ(16).

## Planned features

* [Low] USB, DWC2 on QEMU `raspi4b` ([design-usb.md](design-usb.md#dwc2)): `erx_dwc2`, a
  programmed-I/O host driver for the model's DWC2 beside `erx_xhci` under the same USB core, for low- and
  full-speed devices with control, bulk and interrupt transfers. It serves QEMU `raspi4b` alone, since a real
  Pi 4's DWC2 is the USB-C power connector's, so it comes after Track U's parts
  ([plan.md](plan.md#track-u-usb)); its design keeps the three rules the USB design records.
* [Medium] USB on the Raspberry Pi 4 (`config/manifest/raspi4b-development.txt`,
  [design-usb.md](design-usb.md#who-holds-a-controller); [plan.md](plan.md#track-u-usb), part (c)): a USB keyboard
  works on the board through the BCM2711 bridge driver, the VL805 and `erx_xhci`. Still open: the PCIe domain's
  25 MiB is QEMU virt's measurement and the USB domain's 32 MiB and the media domain's 25 MiB and 50 mcpu are
  measured nowhere, so measure all three on the board; a stick's FAT volume read at `/media/disk0/s1` is not yet
  seen on the board (the scratch stick's one MBR partition probes as `unknown`, so it needs a FAT volume written
  from the Mac first);
  the VL805's line against the bridge's `interrupt-map` is not checked at boot (see "a closed place's line against
  the tree" in [todo-liberx.md](todo-liberx.md)); the controller's level-line handling is host-tested
  (`a_level_line_neither_storms_nor_loses_an_event_test`) and not yet seen under load on the board; the
  stick's check (the `medium LUN L ready` line, which the board shows), and the board checklist of design-usb.md's
  [QEMU suites](design-usb.md#qemu-suites) section, its non-coherent DMA steps among them, are still to be
  added to the guide's Pi 4 checks ([raspberry-pi-4.md](guide/raspberry-pi-4.md)).
* [Low] USB, SuperSpeed hubs ([design-usb.md](design-usb.md#outside-this-design)): the bus core gives up a
  hub at SuperSpeed at its device descriptor (`superspeed_hub`), and no device behind it runs at SuperSpeed. Driving one is a
  design of its own, with the VL805's bulk-out burst quirk for mass storage behind such a hub that the design lists
  beside it.
* [Medium] USB, the `usb` QEMU suite's sector cases (`tools/lib/erx/usb_boot.rb`;
  [design-usb.md](design-usb.md#mass-storage-reaches-the-file-servers)): they read a medium's transport, since
  nothing holds a drive's window before the media domain asks its grant for it (step 4 of the drives item in
  [todo-storage.md](todo-storage.md)). Move them to the media domain's walk of the drive once it serves media,
  and add a case that the medium is named `disk0`.
* [Medium] USB, `abi/inspection.txt` ([design-usb.md](design-usb.md#failure-handling)): no `usb` kind. Declare
  `[usb, Controller]`, `[usb, Controller, ports, Route]`, `[usb, Controller, devices, Route]` and the other paths
  Failure handling lists, shown under `/proc/usb`, with the controller and bus processes that report them. The
  design leaves open the reporter category of a top-level path a configured domain other than the system domain
  reports (the schema's `service` and `runtime` do not fit as declared), the key types of `Controller` and
  `Route`, and the shape of a device's functions, each a kind with an input number or a drive, which the schema's
  types have no alternative for. Without these paths a device that never enumerates leaves no trace: the USB
  domain logs a medium only once it is ready, and nothing for a controller with no ports up or a port whose
  device never answers, so on the Raspberry Pi 4 a dead stick showed only as silence after the PCIe lines and
  `medium none` at `/media/disk0/status`, which a stalled controller, a lost grant or a regression would show
  the same way. The paths must show each controller's state, each port's connect and link state, and each
  device's enumeration result and units, so `cat /proc/usb/...` tells those cases apart.
* [Medium] USB, `docs/design-usb.md` ([The TRB ring form](design-usb.md#the-trb-ring-form)): the design names
  no Erlang call for a queue's state, which `reset_pipe` and `erx_xhci_core` need, nor `complete/2`'s second
  argument or `negotiate/2`'s wanted value and answer for the TRB form. `erx_xhci` assumes
  `erx_device:queue_state(Dev, {Slot, Dci})` answering `idle`, `busy`, `stopped` or `halted`,
  `complete(Dev, events)` and `negotiate(Dev, 0)` answering `{ok, _}`, all in its section "The device NIF's TRB
  ring form"; state the NIF's shapes in the design and make that section match. Neither design document states
  that a register array's `{Name, Index}` counts from 0, which `erx_xhci`'s register mapping assumes.
* [Low] USB, `test/erlang/erx_xhci_tests.erl`: a case that runs past 1 s after its controller's install meets the
  core's status read of `USBSTS` where it expects another call; the cases finish in milliseconds, but a loaded host
  could make one flake. A failed case also leaves its controller waiting on the stand-in.
* [Medium] USB, `tools/lib/erx/chokepoint_rules/device.rb` ([design-usb.md](design-usb.md#the-block-transport)):
  nothing names `erx_blk_write` as the one caller of `erx_usb_pipe:bulk_out/3`. Add it, with a seeded violation.
* [Low] USB, `abi/formats/evdev.txt` ([design-usb.md](design-usb.md#the-usage-table)): the key codes FreeBSD's
  `evdev_usb_scancodes` maps that the file lacks (keypad keys, F13 to F24, `KEY_102ND`, `KEY_COMPOSE` and the others).
  Add them, since the file holds every code erXos reads.
