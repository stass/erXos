# TODO: liberx and the ABI

Open work on liberx and its program layer, the ABI and its generators, the domain library. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Major initiatives

* [Medium] ABI, `liberx/backend/api.h`: the kernel calls are not generated from the ABI.
  `docs/design-kernel.md` ("Kernel calls") says every call is in `abi/erx_abi.txt`, which declares one,
  `debug_log`; `api.h` declares about 70 by hand, and the backends' refusing stubs
  (`liberx/backend/core/refused.c`, `liberx/backend/fiasco/task_refused.c`,
  `liberx/backend/hosted/refused.c`) repeat their signatures. A call's signature and status codes
  thus live in hand-kept copies that agree only at the C compiler, and no decoder or Erlang twin is
  generated for them. Declare the calls in the ABI and generate `api.h` and the stubs from it.
* [Medium] ABI, generated names are reserved by a second list (`Names.validate` in
  `tools/lib/erx/abi_names.rb`): the emitters (`abi_emit_c.rb`, `abi_emit_marks.rb`) and `validate` share
  which layouts get a decoder, encoder or encoder input, but which names each gets is written in both, so
  a name an emitter adds collides only at the C compiler. Have each emitter return its declarations as
  (symbol, origin) pairs from the code that renders them, and reserve that list.
* [Low] ABI, the marks emitter's fixed and per-structure names (`erx_meaning_free`, `erx_report_record`,
  `erx_meanings_of_TARGET`, `ERX_STRUCTURE_TARGET` and the rest in `tools/lib/erx/abi_emit_marks.rb`)
  are not reserved, so a marked layout named `erx_meaning` with free places declares `erx_meaning_free_t`
  twice and only clang refuses it. Reserve them, best through the item above.
* [Low] ABI, `Names.reader_encodes?` is not closed under nesting: a layout the reader encodes that embeds
  a device record or a layout with a tail makes `CEmitter.encode_field` call an encoder the reader does
  not write (none in the tree). Refuse such a layout in the model, or make the rule recursive.
* [Low] ABI, which of `erx_mf_facet`'s fields are quantities is stated in Ruby, not in
  `abi/manifest.txt`: `FACET_QUANTITIES` (`tools/lib/erx/abi_contracts.rb`) names the five fields, whose
  widths come from the layout. Mark them in the layout (a quantities sub-layout, or a field mark the
  reader keeps) so the list is derived.
* [Medium] ABI, the facet quantity fields are copied by hand: `FACET_QUANTITIES`
  (`tools/lib/erx/abi_contracts.rb`) repeats `erx_mf_facet`'s field names and widths from
  `abi/manifest.txt`, and `facet_row` in `tools/lib/erx/manifest.rb` the key list; take both from the
  codec's layout.
* [Medium] ABI, per-member enum attributes (fix the tool): the ABI spec language attaches no property to an
  enum member, so which window roles of `mf_window_role` (`abi/manifest.txt`) are read-only and which belong
  to the slot writer is written out twice, in the Ruby manifest check (`tools/lib/erx/manifest.rb`, its
  slot-writer role list and `window_rights`'s read-only roles) and in `erx_blk_table:read_only/1`
  (`erlang/apps/erx_blk/src/erx_blk_table.erl`). Extend the enum grammar with attributes per member, such as
  `value system 8 read_only slot_writer=false`, each attribute declared once for its enum with a closed set
  of values the generator validates, and generate them into Ruby and Erlang (which also gives Erlang enum
  types), then delete both copies; a seeded member without a declared attribute fails the generator.

## Stopgap replacements

* [Medium] security residual, `liberx/backend/fiasco/vm_rules.c`: `erx_vm_map` lets every `erx_mem_create`
  object run, not only a JIT one, so any such object maps read-write at one address and read-execute at another, a protect moves RW to RX freely, and the
  root maps RX into a child made without `ERX_SPACE_JIT`. No single mapping is ever writable and executable,
  but code-making does not yet follow from the image.
* [Medium] `abi/manifest.txt`, `liberx/system/dom_core.c`, `erlang/apps/erx_display/src/erx_winfs.erl`, [A display's
  session](design-display.md#a-displays-session): a display's manifest entry carries no `display_keymap`,
  `display_repeat_delay_ms`, `display_repeat_period_ms` or reserved chord, and the domain service puts none of
  them in the display domain's environment, so `erx_winfs` starts the router with its built-in defaults: keymap
  `us`, a repeat delay of 500 ms and a period of 126 ms, and no chord. Add the entry's fields, the environment
  variables and their reading, and check the repeat values against the entry's as the router's tests require.
* [Medium] `tools/lib/erx/abi_input.rb`, [Input records](design-abi.md#input-records): the `input`
  declaration is a fourth reader of tagged records beside the draw messages and the program and web protocols'
  `union`s. Its term rule (`distinct!`) repeats the program grammar's case selection and its member grouping copies
  `Draw.messages`; fold the term rules and the grouping into one shared reader. Its `rel`, `axis` and `wheel`
  limits span their scalars' base types, so widening one takes two edits the generator checks agree; let a scalar
  with no range be the source and derive the `ERX_INPUT_*` macros from it. `erx_input`'s `code()`, `slot()` and
  `is_code/1` parallel the codec's field types; export those from `erx_input_codec` and name them there.
* [Low] `tools/lib/erx/abi_emit_ui_wire.rb` and `abi_emit_ui_wire_ts.rb`, [Widget format](design-abi.md#widget-format):
  the server's records are declared in `abi/formats/ui.txt` and their code generated, but the two reports' fields
  (event's node, event number and detail; damage's count and rectangles) and the report reader's six reasons are
  still fixed text in the Erlang encoder and `read/1`, the C writers and the TypeScript `readReport`, `writeEvent`
  and `writeDamage`, tied by the parity test. Give `report` lines fields (a `detail`, and a width, a height and a
  list of rectangles for `damage`) and generate them as the records are. The C damage layout's
  offsets (`ERX_UI_DAMAGE_SIZE_AT` and the rest) then come from that row instead of the emitter's constants, and
  `erx/ui_wire.h`'s `ERX_UI_DAMAGE_MAX` goes, since `erx/abi.h`, which it includes, names the same limit
  `ERX_UI_DAMAGE_RECTS`.
* [Medium] `tools/lib/erx/abi_emit_ui_fields.rb`, [Widget format](design-abi.md#widget-format): a field type's
  code is spread beyond its `UIFields::CODE` row (the Erlang `read_props`/`read_removed`, the C `erx_ui_props`/
  `erx_ui_removed`, `kind_number/1`, the `input()` type, the TypeScript `nodeId`/`kindName`/`rune`/`writeRune`
  helpers, `?IS_I8`/`?IS_DIRECTION`, `c_locals`' and `c_members`' type lists), and much of it is emitted whether
  or not a field uses the type; so a ui.txt that drops every `removals`, `kind` or `input` field, or declares no
  input form, is accepted but fails `-Werror` or does not parse. Move each type's helpers into its row and emit
  them only when used. Lows from the same review: record and form names are not checked against generated C
  macros (`op_max` makes `ERX_UI_OP_MAX` twice), C keywords or Erlang reserved words; `insert_header` counts only
  fixed fields and props, so a `removals` or `input` field in insert would undercount `insert_max`;
  `encode({input, Bad}, _)` raises `{bad_value, Bad}` where other records raise `bad_record`; no refusal case pins
  that a key input with a bad direction and a truncated code is `bad_key_direction`.
* [Medium] `tools/lib/erx/abi_emit_web.rb`, [The protocol](design-web.md#the-protocol): the protocol hash
  covers the declarations, not the codec code (`abi_web.rb`, both emitters' interpreters, `web/src/wire.ts`), so a
  change to the interpreter alone keeps the hash and an old client passes `hello`. Fold the generator files'
  digests into the hash or hash the generated tables, and say which in design-web.md.
* [Low] `abi/formats/ui.txt` and the generated readers: a `present` name is checked only as UTF-8 of at most 63
  bytes, while design-abi.md calls it "a presentation name of the inspection schema", which `abi/inspection.txt`
  declares: generate the name table into both readers, as `erx_ui_schema` checks it against `erx_present:marks/0`.
* [Low] `abi/keymaps/us.txt`, [Input events](design-display.md#input-events) and [Keys and
  paste](design-display.md#keys-and-paste): the `ctl` layer of every key other than the letters, `[`, `\`
  and `]` follows 9front's low-five-bits rule, not FreeBSD's console, and `erx_vt:key/2` sends it as typed. For
  example Control-minus types CR where FreeBSD gives US (release/15.1.0 `sys/dev/kbd/kbdtables.h` line 57),
  Control-1 XON and Control-3 XOFF where it gives nothing (lines 47 and 49), Control-6 SYN where it gives RS
  (line 52), Control-semicolon ESC, and the keypad's minus, `*` and 2 type CR, LF and DC2, so Control-keypad-2
  differs from Control-2's NUL. Take the `ctl` layer of the non-letter keys from `kbdtables.h`, with the keymap
  test's table; FreeBSD's Control-keypad-2 types `2`, which `key/2` would send as NUL, and Control-Shift-Space
  types Space where `key/2` sends NUL (`share/vt/keymaps/us.kbd` line 62), so decide those two in the design.
* [Medium] `abi/formats/ui.txt` validity and `erlang/apps/erx_ui/src/erx_ui_model.erl`, [Widget
  trees](design-display.md#widget-trees): no rule bounds one node's children below the grant's `ui_nodes`, which
  has no value yet. `delta/2`'s longest kept run and its index bookkeeping, and `apply_ops/2`'s insert and move, are
  quadratic in a node's children (a reversed flat node of 16,000 children: 10 s for `delta/2`, 20 s to apply, on
  Homebrew erl), and an index above 65,535 does not fit `diff_op()` or the binary form. Add a per-node children
  limit to the validity rules (at most 65,536; 1,024 suggested), which bounds both by construction.
* [Low] `tools/lib/erx/abi_emit_draw.rb`: design-display.md says the generator also produces the message table of its
  interface section from `draw.txt`; it does not, and the table in "Draw messages" is hand-written.
* [Low] abi, `abi/erx_abi.txt`: `group_executors` and `group_executors_max` hold the same value. Keep one, and
  update whichever of `design-kernel.md` and `design-scheduler.md` then disagrees.
* [Low] `liberx/backend/core/boot_manifest.h`, `erx_boot_device_t`: `given` and `framebuffer` are two bools for
  one closed kind (physical, given, framebuffer), so `given && framebuffer` is representable and a consumer that
  forgets the framebuffer case reads a NULL `role`. One enum switched on exhaustively.
* [Low] domain library, windows from the root's resource (`liberx/system/dom_life.c`, `erx_dom_plan_unit_give`;
  `liberx/system/dom_apply.c`, `give_object`): each WINDOW step makes its window from the root's resource, since
  a page run may span several devices, and `give_object` passes the root's resource as a placeholder handle,
  `APPLY_NO_HANDLE`, because no backend has a resource object and each create ignores the argument. For erXos's
  kernel, make each window from a resource carved over its run (`ERX_CARVE_RANGE`) and give `give_object` a real
  root-resource case.
* [Low] domain library, a unit's lines against other units (`liberx/system/dom_life.c`, `life_overlaps`,
  `life_unit_lines`): the planner refuses a range that meets another unit's but not a line another unit names;
  only the boot view refuses two units on one line, at build and again at boot. A view built some other way
  would let two holders each make an IRQ object on the line, which the kernel refuses for the second. Have the
  planner refuse it with the boot view's own predicate if a second builder of views appears.
* [Low] domain library fuzzing, the give's reach (`tools/fuzz/dom_core_fuzz.c`, the give section and
  `fuzz_window_covered`): the fuzzed view holds two device entries, so a give of three or more devices, runs
  joining several ranges, and a line shared by more than two devices are reached only by the host drivers. Widen the
  view to `ERX_DOM_DEVICES_MAX` entries.
* [Medium] domain library and root, a closed place's line against the tree (`liberx/system/dom_boot_view.c`,
  [design-pcie.md](design-pcie.md#the-closed-bus)): a `pci` row's line at a closed bridge's place is copied
  from the platform record and joins the unit rule's line relation, but nothing at boot compares it with the line
  the bridge's `interrupt-map` routes for the place's pin (`erx_dt_intx`) or refuses a route to one of the bridge's
  own lines, and no give refuses a function whose reported pin is not its place's. A wrong record line passes the
  unit rule against a line the hardware does not raise. Add the boot view's refusal ("At boot") and the give's
  ("At the give"), each with its seed; better, carry the line on the place row and have the packer copy it.
* [Medium] domain library and device service, a host bridge's catalogue's callers (`erlang/apps/erx_domain`,
  `erx_devices`; `otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c`;
  [design-pcie.md](design-pcie.md#the-catalogue-and-gives)): the view holds a catalogue per bridge row, the
  root joins the tree's windows and `erx_domain_lib:pci_report/2` takes a report into it, as the device service's
  PCIe process (`erx_devices_pci`) does, but `/dev`'s `status` does not show a pci row's layout, state, mode and route or `firmware lost` (`devices/0` gives the place
  and setting, `pci_bridges/0` the rest), and `erx_domain_lib:firmware/2` makes the bridge's request and marks the bridge `firmware_lost` on
  `{error, etimedout}` before it answers. Also refuse in `erx_dt_bridge` a window whose
  PCI, CPU or size is not page-aligned, and check BAR spans across a machine's bridges, not only within one.
  `pci_report/2`, `pci_bridges/0`, `pci_mode/2`, `pci_answered/1` and `firmware/2` answer any system-domain caller, since their caller is the device
  service and not the registered domain service; a process that reports before the PCIe domain lays the bridge's
  layouts for the boot, and one that writes a mode can lower a held function's setting or raise it for its holder
  beyond what the PCIe domain was asked. Hold them to
  the device service's process (a registration of its own, or the call routed through the domain service), and
  hold `erx_dom_lib_pci_report` and `erx_dom_lib_pci_mode` to the NIF and `erx_dom_view_bridge` to the root with
  chokepoints. The root's join
  (`tree_facts`) and the NIF's term handling run only on the target; the `pcie` QEMU suite (P12) covers them.
* [Medium] domain library, domain service and device service, a bridge's function used during or after its
  failed firmware request (`otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c` `bridge_firmware_nif`,
  `erlang/apps/erx_domain/src/erx_domain_srv.erl`, `erx_devices_pci_core.erl` `request/3`,
  [design-fiasco.md](design-fiasco.md#the-firmware-request)): the NIF marks a bridge whose notification timed
  out `firmware_lost` only after the request returns, and the device service's PCIe process parks a report while
  a request is in flight (`erx_devices_pci_core:report_waits/1`), but three paths still use the bridge. Gives are
  made by the library as each holder is created, which the domain service orders and the PCIe process does not
  see, so a holder created during the flight is given a function whose notification then times out. The in-flight
  state lives in the process alone, so a restart of the device service while its old worker is still in the NIF
  takes reports again before the mark. And a holder's `open`, `master` or `reset` is decided on grantee and place
  alone (`held_row/2`), never on the catalogue's `firmware_lost`, so a holder of a bridge whose notification timed
  out raises its function again after the next report lowers it. Close all three by construction in the library:
  mark the bridge's request in flight under the lock before the request, so the intake, every give and the PCIe
  process's raises (through a predicate shared with `lowered/3`) refuse until the status lands, and the
  process's parking can go.
* [Medium] hardware generator, `tools/lib/erx/hardware.rb`, no field arrays or shared enumerations:
  `dim` applies to registers only and `derivedFrom` to clusters only, so `hw/svd/bcm2711_gpio/bcm2711_gpio.svd`
  writes the FSEL encoding (eight values) and the pull encoding (three) once per pin, about 470 of its 612
  lines, and `test_every_gpio_pin_has_its_function_select_and_pull` in `test/host/hardware_test.rb` keeps the
  58 copies in step. CMSIS-SVD's field `dim`/`dimIndex` (`FSEL%s`, indexes 10 to 19 and so on) or an
  `enumeratedValues` `derivedFrom` in the profile would state each once and delete that test. The header probe
  (`test/raspi4b/header_probe.c`) pays too: a 62-row table naming each pin's getter, and FSEL0's and PULL0's
  value names standing for every pin's; a field array would let it index the fields.
* [Low] hardware generator, read-write fields the hardware also changes: `plain_update?` takes the SPI
  master's `CS` (`hw/svd/bcm2711_spi/bcm2711_spi.svd`) as safe to read, modify and write back, but its `TA`
  is cleared by the DMA controller's frame-end pulse (BCM2711 ARM Peripherals, Table 160), so a field write
  racing that pulse sets `TA` again. Polled transfers are unaffected; DMA on SPI settles how `CS` is marked.
* [Low] liberx, `liberx/backend/fiasco/vm.h`, `vm.c`, `thread.c`: the backend's fixed addresses
  (`ERX_FIASCO_KIP_WINDOW`, the device window, the UTCB area, the VM window, the area start) are spread over
  three files, and only the KIP window's place below the device window is asserted. Gather them in one layout
  header with static asserts of their order.

## Bugs by subsystem

* [Low] ABI, the generated C manifest reader has no span accessor: `liberx/system/dom_boot_view.c`
  (`boot_facet_parameters`' caller) and `liberx/backend/core/boot_manifest.c` each turn a facet row's
  `parameters` span into a first index by hand (`(offset - header offset) / ERX_MF_PARAMETER_SIZE`),
  where the Erlang reader gives a span's records through `erx_manifest:span/3`; a generated
  `erx_manifest_<table>_span` would give both C readers that one idiom. The same idiom decodes
  `facet.operations` (`dom_boot_view.c`, beside the `parameters` site) and, in Erlang, an image row's
  `extents` (`erlang/apps/erx_blk/src/erx_blk_image.erl`, `images/4` and `extents/4`), which
  `erx_manifest:span/3` replaces.
* [Low] ABI, the manifest test fixtures (`test/fixtures/abi_manifest_fixture.rb`,
  `test/fixtures/abi_erlang_fixture.rb`, `test/fixtures/erx_abi_reader_tests.erl`, and
  `test/host/abi_schema_test.rb`'s header size, `496`): their byte offsets
  are written by hand and shifted by hand each time `erx_manifest`'s header grows in
  `abi/manifest.txt`. A generator that derives them from the layout is missing.

* [Low] liberx hosted backend (`liberx/backend/hosted/`): macOS only (`os_sync_wait_on_address`, and the stack switches in `arch/*/switch_stack.S` use Darwin's symbol names); a Linux host skips `test/host/hosted_function_api_test.rb`.

* [Low] domain library, `liberx/system/dom_boot.c` (the apps budget and each principal's budget): both are
  created with `ERX_BUDGET_ELASTIC`, while the comments beside them and
  [design-fiasco.md](design-fiasco.md) make a domain's budgets walls (cap equal to guarantee). Change
  the kind with the budget-wall implementation package.
* [Medium] liberx, capability calls (`liberx/backend/api.h`, `docs/design-abi.md` "Program protocol"): the program
  profile's capability fields, the walk's array, the pipe ends' handles, the startup record's, `erx_prog_object_map`
  and `erx_cap_close` are `erx_cap_t`, but every other call of `api.h` takes or returns a handle as `uint64_t`
  (`erx_cap_dup`, `erx_object_destroy`, `erx_cap_pass`, the `erx_*_create` out-handles, `erx_vm_map`, `erx_irq_*`,
  `erx_ipc_*`, `erx_gate_*`, `erx_thread_*`, `erx_space_*`, `erx_image_*`, `erx_mem_*`, `erx_log_*`,
  `erx_object_info`), as do the program channel's doorbell (`liberx/program/channel.c`, `erx_prog_channel_open`). A
  handle crosses into those as `.raw` and leaves them as an integer that callers wrap with
  `(erx_cap_t){ .raw = ... }`: the domain library's `made[]` and `remains_held` (`dom_apply.c`), the pipe and
  domain-library NIFs, the program driver, the JIT memory, two guests inline and the `handle_close` helpers of the
  function_api and native_space guests. Type them, with the Fiasco and hosted backends and their callers. Null and
  identity tests are spelled `.raw == ERX_CAP_NULL` and `a.raw == b.raw`, and pipe.c keeps a file-local `cap_null`;
  have `abi_emit_c.rb` emit a typed null and `erx_cap_is_null` and `erx_cap_same` beside `struct erx_cap`, so `.raw`
  appears only where a handle arrives as an integer (registers, Erlang terms, a service request).
* [Low] `docs/design-runtime.md`, "The edits outside `sys/erxos`": the numbers 66, 67 and 68 each name two edits
  (`link/1,2` on a connection and the `select_val` fall-through; `erlang:send/3`'s `notify` and the controller keeping
  `init` as its group leader; init's reboot and the dirty scheduler's elapsed-time charge), so a reference such as
  "edit 68" is ambiguous. Give the second of each pair a number of its own and update the references in
  `docs/design-runtime.md`, `docs/design-domains.md`, `docs/design-network-stack.md` and `docs/todo-performance.md`.
* [Medium] `abi/services/files.txt`: the default of `rights` when a row states none, `rw`, is said in the file's
  comment and applied in `erx_fs_grants:grant_options/1`; a `parameter` line has no way to declare a default, so
  it is not one generated fact. Add `default MEMBER` to member parameters (checked a member, emitted as a macro),
  and decide whether a security parameter's default should be `rw`, `ro` or none (a required parameter).
* [Low] `tools/lib/erx/abi_contracts.rb` `services`: the `allowed` parameter kinds copy `mf_parameter_kind`'s
  members, and the kind switches of `dom_boot_view.c`, `erx_domain_terms.c` and `tools/fuzz/manifest_fuzz.c` end
  in `default:`, so a new kind is not a build failure where it is unhandled; derive `allowed` from the enum and
  drop the `default:` cases. `Contracts.member_bound`'s enum may hold negative values, which fail safe at the
  view but should be refused at the declaration.
* [Low] `tools/lib/erx/abi_emit_erlang.rb` `enum_members`: an atom enum is emitted only as the list
  `?ERX_<ENUM>_MEMBERS`, with no guard macro and no `-type`, so code that needs a guard or a type copies the
  members by hand: `files_rights`'s `ro | rw | rx` in `erx_fs_grant.erl`, `erx_prog_handler_core.erl`, `erx_ns.erl`
  (`mount_options/3`, `rights()`), `erx.erl` (`facet()`), `erx_file_remote.erl` and `erx_verity.erl`, about a
  dozen copies that refuse a member the ABI gains while the generated list accepts it. Emit
  `?ERX_IS_<ENUM>(X)` and a type per atom enum and convert the copies.
* [Low] `tools/lib/erx/abi_emit_erlang.rb`: the two generated readers carry a second decoder of fixed
  `wire_le` layouts (`decode`, `decode_field`) beside `erx_abi_layout`. At the next change to the reader
  generator, emit them over `erx_abi_layout` and delete the second decoder.
* [Low] `abi/protocols/9p.txt`: `error edquot 122` follows 9P2000.L and musl; check the POSIX layer's mapping if it
  follows FreeBSD's numbering (69).

* [Low] ABI generator, frame profiles (`tools/lib/erx/abi_profile.rb`, `include/erx/profile.h`): the C
  check's bounds on depth and totals are written in both files, tied only by the generated table's static
  asserts, and the 64-key bound of a map or union (`ERX_PROFILE_KEYS_MAX`) has no model rule, so a protocol
  past it fails as a C compile error rather than at its declaration. Give the bounds one source and add the
  keys rule to the model.
* [Medium] ABI generator, the node-path character class (`abi/erx_abi.txt`, `device_path_max`): the characters a
  device-tree node path may hold, `/` then `A-Za-z0-9,._+@/-`, are written four times, in
  `erx_boot_node_path_valid` (`include/erx/core/boot_handoff.h`), `NODE_PATH` (`tools/lib/erx/manifest.rb`),
  `alias_source` (`tools/lib/erx/board_tree.rb`) and `node_char/1` (`erlang/apps/erx/src/erx_device_record.erl`),
  and the manifest grammar's `dt_path` class is a different rule (clean UTF-8, no empty or dot components). The
  bound has one source; the class does not. Declare the class in the ABI file, generate its C, Ruby and Erlang
  predicates, and make the grammar's `dt_path` the same rule, so every reader of a device's path checks one rule.
* [Low] liberx program layer, signals: until signals reach programs, a pipe write to a closed
  reader takes SIGPIPE's default action (the program ends with the signal) unless the start's
  `sigignore` names it, and a run-time `signal(SIGPIPE, SIG_IGN)` is not honoured. It fails safe,
  with a stop of the writing program, never a hang or a wrong answer; output the program would
  have written after the `EPIPE` is lost.
* [Low] liberx program layer, `liberx/program/wake.h`: P6 (docs/design-programs.md) says every
  wait of `liberx` sleeps on the thread's wake word, and no build check holds it. A chokepoint
  rule that lets only `liberx/program/wake.c` and the listed stop and startup waits of
  `program.c` call `erx_umtx_wait`, with a seeded site in its test, would.
* [Low] liberx program layer, signals: a waiter (`erx_prog_waiter_t`) lives on the waiting
  thread's stack while it sleeps, on a pipe end's list or the channel's. A signal design that
  lets a handler leave a wait without returning through it (`siglongjmp` from an upcall) would
  leave a dangling waiter; it must forbid that or take the thread's waiters off first.
* [Low] liberx domain library, `test/fixtures/dom_core_driver.c`: the session template's principal is
  1, so no case tells the `principal` word's number from a constant or the template index plus one,
  and no case plans a session at the reserve's limit (the largest number and a display name of
  ERX_DOM_NAME_MAX bytes after an environment that leaves exactly the reserve).
* [Medium] liberx program layer, `liberx/program/fd.c` (`status_change`): a file's `O_APPEND` is fixed
  at its open, and `F_SETFL` that would change it is `EINVAL`, since no request tells the handler's
  description of the change. musl's `fdopen(fd, "a")` (musl/src/stdio/__fdopen.c) therefore fails
  with `EINVAL` on a file opened without `O_APPEND`, rather than give a stream that writes at the
  current offset; the programs suite's `fileio` case checks both. FreeBSD's `fdopen` leaves the
  descriptor alone and seeks to the end before each write of such a stream, so there `fdopen(1, "a")`
  on a standard output redirected with `>` succeeds, and here it fails until `F_SETFL` can change
  `O_APPEND`. The design's answer is the description's second opened fid with the other append flag
  (docs/design-files.md, the `F_SETFL` paragraph; docs/design-programs.md, "Descriptors and files"):
  a request that carries the change to the description, and `fd.c` sending it.
* [Low] liberx program layer, `liberx/program/file.c` and `fd.c`: the startup plan refuses a
  `{file, Open, Access}` descriptor, so a file reaches a program only through its own `open`; a clunk's
  error at a file's last close reaches no caller; `O_DSYNC` asks
  for 9P2000.L's sync, the one sync value the ABI offers; and poll answers a file ready at once, whose
  parity with FreeBSD's regular files is unverified. `umask()` is not offered, so an `lcreate`'s mode is
  less the startup message's umask for the program's life; modes gate no access on erXos
  (docs/design-programs.md), so only the mode a server records is affected.
* [Medium] liberx program layer, tests of `liberx/program/file.c`: `test/host/prog_file_test.rb` builds
  `open_plan` against the host's `<fcntl.h>`, never musl's aarch64 values (`O_ACCMODE` holding `O_PATH`,
  `O_SYNC` holding `O_DSYNC`'s bit, the `O_LARGEFILE` musl's `open` always passes); the programs suite's
  `fileio` case runs the target's values only for the flags `fileio.c` passes (`O_RDONLY`, `O_WRONLY`,
  `O_CREAT`, `O_TRUNC`, `O_EXCL`, `O_APPEND` and musl's `O_LARGEFILE`), so a mapping wrong only for the target's
  value of another flag passes every test. A host build of the mapping against the sysroot's
  `bits/fcntl.h` values closes it. A failed part after an earlier part moved bytes, and a write
  answered with 0 bytes, are in no case either.
* [Low] liberx program layer, request values (`file.c`, `signal.c`, `pipe.c`): each request's value is
  written term by term with `erx_etf_put_*` against the generated profile's types, which a host test's
  stand-in checks with the generated request check; a generated C writer for each request case
  (tools/lib/erx/abi_emit_profile.rb) would make a value that disagrees with abi/protocols/prog.txt
  fail to build instead.
* [Low] ABI, abi/protocols/prog.txt: `data_slot`'s bound writes out `prog_data_slots_max - 1`, since an
  integer kind's bound cannot be a limit less one; an exclusive bound (`below @prog_data_slots_max`)
  in tools/lib/erx/abi_protocol.rb would make it one fact.
* [Low] liberx, `erx_pipe_run.c`: the runner relies on its caller for a lane size that is a power of
  two of at least 16 and a mapping of `ERX_PIPE_RING_DATA` plus that size; P7's program ends must
  give the same. `test/host/pipe_run_test.rb` seeds no fault in `run_within` or `run_lane`'s check.
* [Medium] liberx program layer, `liberx/program/startup.c` (`erx_prog_startup_plan`): a startup
  message with a descriptor other than `null` or a pipe's read or write end ends the program with
  status 127 before `main`, because liberx sets up no socketpair, file, tty, directory, socket or
  `dup` yet. Each case replaces the refusal with its set-up when the file descriptors arrive
  (docs/design-programs.md, "Descriptors and files").
* [Medium] liberx program layer, `tools/fuzz/erx_prog_target.rb` and
  `test/fixtures/prog_profile_frames.rb`: no seed holds a socketpair, file, directory or socket
  descriptor, so a plan that wrongly accepts one of them passes `test/host/erx_prog_fuzz_test.rb`,
  and the harness's socketpair read branch has no seed to start from. Add a start-frame seed per
  kind as each case gets its set-up. The accepted set is also written in three places that must
  agree (`startup.h`'s prose, `find_unsupported_fd` in `startup.c`, `fd_setup_one` in `fd.c`);
  one predicate in `fd.h` that the plan and the set-up both use would make them agree by
  construction, with the harness keeping its own list as the oracle.
* [Low] liberx program layer, `liberx/program/fd.c` and `pipe.c`: a handler bug is trusted rather
  than refused. Two descriptors of one startup message naming the same pipe end make two end
  objects, the reports reach only one, and the second `{closed}` ends the program with `SIGSYS`;
  reports can add lanes to a read end without bound, each costing two mappings. Refuse a second
  descriptor of one end in `erx_prog_fd_setup`, and bound joins by the pipe's write-end quota.
  `erx_pipe_open` closes on failure only the capabilities it kept, which is enough while only the
  set-up calls it and stops the program; a `{pipe}` reply that opens ends in a running program
  must close the descriptor's other capabilities and say whether it owes `{closed}`.
* [Low] liberx program layer, `liberx/program/`: the build check that the layer's entry macro
  opens every function a program may call (docs/design-programs.md, "Verification and testing")
  is not built. Decide with it whether `erx_prog_startup_plan`, a pure function the layer exports
  for its own executor, counts as exported, or moves beside `elf_plan.c`.
* [Medium] liberx program layer, `liberx/program/channel.c` (`erx_prog_channel_send`): the send
  writes a frame whole under the lane's lock, so it refuses with `ERX_ERANGE` a frame whose record
  is larger than the 16 KiB outbound ring, while a spawn's arguments reach 131,072 bytes
  (`args_max`). How a request larger than the ring reaches the session is open for the request
  work: a frame streamed under the lock breaks the rule that the lock is never held across a wait.
* [Medium] liberx program layer, `liberx/program/channel.c`: design-programs.md has the event
  executor send `{waited}` reaps from slot 15 and never wait, but the channel's send may wait
  for outbound room, which only the executor announces. The reap work must give the executor a
  send that never waits (an owed reap it retries on the next channel label, for one).
* [Low] liberx program layer, `liberx/program/channel.c` (`whole_put`): a sender that finds room
  takes it even while others wait, so a large frame can wait behind a steady stream of small
  ones for as long as the stream lasts. A queue of waiters under the lock, whose head alone
  publishes a need, would serve them in order.
* [Low] liberx program layer, `liberx/program/program.c` (`executor_main`): the executor takes
  labels, and so announces outbound room, only once the inbound lane is empty, so a session that
  keeps the inbound lane busy delays every sender waiting for room.
* [Low] `abi/erx_abi.txt` (`program_arg`): the generator marks no value as an object, so
  `ERX_PROGRAM_INSTALL_DATA` (`erx_program_core.h`) assumes the objects end at `doorbell`; its static
  assertion catches an object put between `doorbell` and `hwcap`, not one appended after `hwcap2`.
* [Medium] ABI generator, `tools/lib/erx/abi_profile.rb` (`capability_fields`): the generated
  capability walk covers only a union a frame to the program carries. A capability in a
  to-program frame of another kind (a tuple, a map) is neither walked nor refused, which is
  right only for the startup message, since a refused start ends the program. A second
  to-program union holding capabilities would get a walk that no executor code calls, because
  `liberx/program/pipe.c` calls `erx_prog_report_caps` by name. Mark the startup frame, refuse a
  capability in any other to-program frame that is not a union, and refuse a second walked
  union until the executor dispatches walks by frame.
* [Medium] liberx program layer, `liberx/program/inbound.c` (`ERX_PROG_REPORT_MAX`): every frame
  after the startup message is bounded by `prog.txt`'s `prog_report_max`, 512 bytes, which
  `erx_program:send/2` does not enforce. A reply to a worker's request
  (`{erx_prog, 1, Slot, Reply}`), such as `pipe`'s, can carry a read end's descriptor far past it,
  and the header decision cannot tell a reply from a report. Have `send/2` refuse past it with
  `einval`, and size the executor's copy for replies before workers send requests.
* [Medium] liberx program layer, `liberx/program/channel.c` (`erx_prog_channel_request`): a reply
  is copied out of its slot as the check's struct, whose texts and lists are views into the
  executor's one frame buffer, which the next frame overwrites. `kill_reply` holds none; the first
  reply with a text or a list (`readlink`, `walk`) needs the frame kept with its slot, for example
  a frame buffer per slot that the executor swaps with its own when it reads a reply. The requests
  are also written by hand with `erx_etf_put_*`, as the notices are; a writer generated from the
  profile, the inverse of its check, would keep each request's encoding one fact with its grammar.
* [Medium] liberx program layer, `liberx/program/signal.c` (`erx_prog_kill`): musl's `kill` is
  not offered to the program's seam yet. It waits on musl numbering signals as the ABI's signal
  table does (musl's Linux numbers would send `sigbus` for `SIGUSR1`). Once it does, add
  `SYS_kill` to `seam_offered` and `erx_fiasco_libc_fd`, and a `programs` QEMU case of a kill
  and a probe round trip.
* [Medium] ABI, `abi/protocols/prog.txt` (`pipe_reply`): its `ok` takes any two `descriptor`s, so
  a swapped, foreign or very long end passes the grammar, and the reply's bound under
  `prog_report_max` is written by hand. Narrow the case to a read end and a write end and have the
  generator check each reply kind's largest frame against `prog_report_max`. The generator's
  capability walk now covers reports only (`abi_profile.rb`, `capability_fields`); the passages
  that still say it covers every frame to the program (`abi_profile.rb` on reply kinds,
  `prog.txt` above the profile, `docs/design-abi.md` twice) need the same change, and liberx's
  cleanup of a reply it cannot take is then hand-written per reply case.
* [Low] liberx program layer, `liberx/program/channel.c` (`slot_take`): the wait for a free reply
  slot is open, and its waiter is on the thread's stack; once signal handlers run on workers, an
  unwind out of it must take the waiter off `slot_waiters` first.
* [Low] liberx program layer, `liberx/program/program.c` (`report_apply`): a refused later frame
  stops the program with 127 without the line design-abi.md and design-programs.md require
  (`erx: FRAME frame refused: REASON in KIND at byte N`), and `erx_prog_report_read` drops the
  refusal that names them. Return the refusal and write the line once a program has a standard
  error. The executor also closes whatever capability values a report names, its own channel,
  group, budget, doorbell or data area included; the session is trusted, but refusing a report
  that names one of `self.regs` or the data area is cheap.
* [Low] liberx program layer, `liberx/program/program.c` (`main_run`): design-programs.md's step 9
  has the first thread set its signal mask; the layer keeps `sigmask` and `sigignore` in
  `erx_prog_self_t` and applies neither until signals reach programs.
* [Medium] domain library, `liberx/system/dom_boot.c` (`erx_dom_boot_up`): each principal's
  group is a plain `erx_group_create(0, 0)`: no `users` group with the manifest's
  `users_share`, no principal group under it, and the principal's share never applied
  (docs/design-system.md, "The root task", step 2). Fiasco ignores the parent, so
  nothing notices yet.
* [Medium] domain library, `liberx/system/dom_apply.c`: two Fiasco backend details reach permanent
  code: the fault thread's `erx_dom_lib_take` uses the Fiasco backend's `erx_ipc_wait(deadline,
  *label)` before the target receive signature is settled (the `erx_ipc_wait` item above),
  and the boot image is named by 0, the root's name for Fiasco's whole archive, in `erx_image_slice` and
  `erx_image_map`;
  `erx_dom_held_t` should hold the image's handle.
* [Medium] domain library, `liberx/system/dom_apply.c` (`apply_pass`): design-system.md A7
  asks that every `erx_cap_pass` of the library go through one function, `erx_dom_install`,
  with a chokepoint rule in `tools/lib/erx/chokepoint_rules/` and its seeded violation;
  `apply_pass` is the one call, for a creation's and a connection's installs, but it takes a
  bare rights mask rather than the `erx_dom_grants` row, and no rule checks it.
* [High] domain library, `test/guest/native_domain` (`lane_party`): the suite fails its
  `connection`, `exports`, `refs` and `origins` cases, each domain logging "init: no answer
  to the ready report in 5000 ms" and the system party never taking the burst's first
  frame; every other case passes. It passed before `erx_code_agent` landed, so the likely
  cause, not yet confirmed, is a frame the code agent's start puts on the system
  connection before the burst, which `party_open`/`party_burst_index` do not expect. Find
  the first frame after the ready report, and teach the party the code agent's frames
  and the ready report's answer.
* [Medium] domain library, `test/guest/native_domain` (`hook_step`): the hooked failure
  refuses a step before it is applied or after it completed, never between a step's two
  calls (a bell's create and bind, a group's create and configure), so a handle noted
  only after the second call would pass the undo cases. Put a hook point between the calls.
* [Low] domain library, `test/guest/native_domain` (`case_link`): the case checks each
  party's connection values only as present and its labels; no party maps its sides or
  triggers the other's bell, so a swapped side or peer side would pass.
* [Low] domain library, `liberx/system/dom_apply.c`: `apply_plan` and `erx_dom_lib_connect`
  repeat one apply loop (hooks, record, undo of the refused step included); the device give
  will be a third. One runner over a step list, or a core undo for "refused at step k",
  would keep the rule in one place. `link_value` also restates the connection rows of
  `erx_dom_grants`; a role carried in the row would remove that second list.
* [Medium] domain library, `test/guest/native_domain`: no case fails a step after it made its
  object (a bell's bind, a group's configure), and none checks that the root's handle table
  returns to its starting occupancy after a retire or an undo, which would catch a handle the
  library forgot to close.
* [Medium] domain library, `tools/fuzz/dom_core_fuzz.c`: the planner's view has no devices, so
  `dom_plan_gives`, `ngives` and the GIVE-before-BOOTINFO order are never reached through
  `erx_dom_plan_configured`. Give the view fuzzed device entries with fuzzed rows, and check in
  `fuzz_check` that a configured plan gives every entry of its row once, to its own holder and
  slot, with its GIVE steps just before BOOTINFO.
* [Medium] domain library, `liberx/system/dom_apply.c` (`apply_keep_gives`, `lib_devices_end`):
  a device record's `holder` is a stored field that two effects outside the host-tested core keep
  in step, and ERX_EBUSY and `devices/0` read it. Only a domain of the entry's row holds the
  device and every living domain of the row holds all of its devices, so derive the holder from
  the living domains (`life_alive` and `erx_dom_from_row`) and keep only the handles the end
  needs in the record.
* [Low] domain library, `liberx/system/dom_core.c` (`erx_dom_plan_check`): the check has no
  view, so it cannot refuse a plan whose gives repeat a device index or name an entry of another
  row; `dom_apply.c` indexes `device_records` by `give->index` on the strength of plans coming
  only from the planner. Check distinct indices in the plan check, or re-check gives against the
  library's view in `erx_dom_lib_apply`.
* [Low] domain library, `liberx/backend/fiasco/runtime_entry.c` (`library_up`): the boot pair
  (`lib.boot`) and the writable `device_records` are set beside the view rather than by its
  constructor, so a constructor that forgets either fails a creation (an unnamed pair) or
  dereferences NULL (records); `erx_boot_pair_words` also writes a pair
  `erx_boot_pair_valid` would refuse. Pass both to `erx_dom_view_build`, and refuse an invalid
  pair there.
* [Low] domain library, `include/erx/device_kinds.h`: no check ties a kind's peripheral name to
  `ERX_BOOT_NAME_WORD_MAX`, so a kind with a longer name would make every creation of its holder
  fail with ERX_EINVAL. Refuse it in the view build or test the table.
* [Medium] domain library, `liberx/system/dom_core.c` (`dom_check_sizes`): every crash area is
  `ERX_CRASH_SIZE`, 16 KiB, not design-runtime.md's per-domain size with its 1 MiB default, so
  a full dump arrives truncated with its slogan intact, and the design's one-page crash area
  test cannot be written: `limits.crash` never reaches the view. Take the size from the
  startup limits and add that test.
* [Medium] domain library, `liberx/system/dom_install.c` (`erx_dom_install`): design-system.md
  A7 and "The grant table" have the install funnel take a row of `erx_dom_grants`, but it
  takes a step with a raw object, recipient and rights and checks only the step's kind. That
  the rights lie within the row and the recipient is the row's rests on `erx_dom_plan_check`
  having run first, and chokepoint `dom-install-funnel` checks only that every `erx_cap_pass`
  is spelled inside the funnel. Have the funnel take the row and the plan, derive the object
  and the recipient from them, and refuse rights outside the row's.
* [Medium] domain library NIFs, `otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c`
  (`fault_main`): an end is lost for good when no process is registered, as for a domain the
  root made before the domain service registered. The library has already torn the domain
  down, so its ended record keeps its view slot and its principal's domain count, and
  `retire/1` needs an id nobody heard. Keep a reported flag per record in the view, set when
  the report is sent, and have `register/0` send every ended record not yet reported.
* [Low] domain library, `liberx/backend/core/boot_info.c` (`erx_boot_argv_fill`): the node
  flag (`-sname` or `-name` and the domain's node name) follows the boot page's args, so args
  that end in `-extra`, or in a `-S` with no later `--`, make it a plain argument and the
  domain boots without its node name. Place it right after the args' first `--`, as the
  packer and the domain service place `-boot`.
* [Low] domain library, `liberx/backend/core/boot_info.c` (`node_flag`), `boot_info.h`,
  `test/fixtures/boot_info_driver.c`, `docs/design-runtime.md`: a host is an identifier and has no
  `.`, so the `-name` branch for a dotted host is unreachable; always pass `-sname`, delete
  `BOOT_FLAG_DOTTED` and its test case and sentence, and have `erx_boot_info_read` refuse a node
  whose two parts are not identifiers.
* [Low] ABI, `abi/manifest.txt` and `tools/lib/erx/abi_contracts.rb`: the identifier rule has
  seven hand-written copies (`erx_ident.erl`, `erx_etf.c` `node_ok`, `dom_core.c` `dom_name`,
  `abi_binary.rb`, the emitters `abi_emit_erlang.rb` and `abi_emit_reader.rb`, `manifest.rb`
  `IDENTIFIER`). Define the `identifier` string class once in the ABI source and generate the C
  predicate, the Erlang predicate and the Ruby pattern from it.
* [Low] domain library, `include/erx/dom_lib.h` (`ERX_DOM_HOST_MAX`): the host bound is 64
  bytes and `dom_boot_view.c` checks only its length, where design-system.md has the host an
  identifier of at most 63. Check the host with the identifier rule and bound it at 63.
* [Medium] domain library NIFs, `otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c`
  (`fault_main`): the fault thread waits at the gate with `ERX_WAIT_FOREVER`, while
  design-system.md A3 has its wait time out to check the ending record's deadline; add the
  timeout once `erx_dom_end_begin` keeps a deadline. The thread also ends without a
  diagnostic on a take refused for any reason but a message that is not a record, after which
  no domain's end is handled; report that to the registered process or the log.
* [Medium] ordered end, `liberx/system/dom_apply.c` (`erx_dom_lib_end_commit`),
  `otp/erts/preloaded/src/init.erl` (edit 68) and `erlang/apps/erx_domain/src/erx_machine.erl`:
  the machine's end is only its last step. design-system.md "Shutting down" also has
  `erx_dom_end_begin` with its ending record and absolute deadline, which the fault thread
  enforces; no domain created or restarted once the end has begun; the vault's quiesce and
  the storage freeze (the durability facet's checkpoint and freeze, which `erx_lfs` does not serve), with
  the end chosen from their outcomes. The coordinator's one entry,
  `erx_machine:request/2`, takes `reboot` and `halt` from the system shell and from a
  session's `/machine/ctl`, writes the one log line and answers a second request `busy`, but
  it keeps the accepted request in its own state in place of the ending record and then asks
  `init:reboot/0` or `init:stop/0`, which run stock OTP's application stop before
  `erx_dom_lib_end_commit`. `init:stop/0`, `init:reboot/0`, a numeric `erlang:halt/0,1` and
  the update service's `trial` do not go through the entry: they log no line, a request after
  them is not answered `busy`, and the entry takes no `trial`. Meanwhile
  `erx_domain_lib:end_commit/1` commits with no begin for any process of the system domain;
  once the record exists the library refuses a commit without one. The coordinator's log line
  goes to `erx_syslog` as an ordinary record, which the application stop may outrun, so it can
  be lost before the end.
* [Medium] domain library NIFs, `erlang/apps/erx` and `test/guest/native_domain`: no test
  reaches the module's paths with a library present: a real create's decoding refusals (an
  unknown key, a u32 overflow, strings beyond the boot page), the lock, the fault thread's
  bind handshake and the `{domain_ended, ...}` message. medium_boot's `domain-lib`
  checkpoint covers only the shape refusals that come before the library. Add them to the
  end-to-end create, start, stop, `domain_ended` and retire cell once the library's boot
  view exists (DL2d).
* [Low] domain library, `liberx/system/dom_apply.c` (`apply_install`): it takes its rights
  from an `erx_dom_grants` row but is neither so named nor checked by a rule.
* [Medium] domain library, `liberx/system/dom_core.c` (`erx_dom_plan_record`): the record
  fills only the plan-made fields and leaves the capability fields of a reused slot for
  the applier, so one function should write the whole record from the plan and the
  apply's made objects; dropping `const` on the view's tables lets every planner write
  them, so give the record functions their own writable tables and keep the planners'
  view const; and a stale partial-boot plan (no connection number) passes record's
  re-checks, which a view generation stamped into each plan would refuse whole. The host
  planner records each plan at once and meets none of these. Found by MF1b's review.
* [Low] domain library, `liberx/system/dom_apply.c` (`erx_dom_lib_record`): the record
  enters `ERX_DOM_ENDED` whatever `teardown_apply` and its own-budget destroy returned,
  and `dom_system_reserve` stops counting an ended configured domain's grant because its
  group went with that budget; a failed destroy would leave the group under `system`
  uncounted, so a restart of its row could pass the reserve. Enter ENDED only on a
  destroy that succeeded, or keep such a record counted.
* [Low] domain library fuzz target, `tools/fuzz/dom_core_fuzz.c`: the planning view's
  records are always `fuzz_domains`, so the input never chooses a living, ended or
  garbage record for `dom_system_reserve` to sum; seed them from the input and check an
  accepted configured plan against an independent sum of the counted rates.
* [Medium] domain library, `liberx/system/dom_core.c`: a specification
  with `ERX_DOM_SECRET`, or a release file marked `ERX_ENTRY_SEAL`, is
  refused with `ERX_EINVAL` until the vault exists (M11); the plan then
  needs the sealing-page mapping and install of
  [design-system.md](design-system.md#creating-a-domain), step 5.
* [Low] domain library, `dom_core.c`: `ERX_DOM_SPACES` is not gated by
  the principal's policy, which design-system.md requires for an ordinary
  domain; add the policy bit with the principal work after Phase 1b-A's
  one built-in principal.
* [Low] domain library, `include/erx/dom.h`: `ERX_DOM_BELL_BYTES` (a page
  per bell) is a hand-chosen bound; it should be the kernel's IRQ object
  cost.
* [Low] domain library, `dom_core.c`: `erx_dom_plan_check` checks a
  plan's structure (order, charges, grants) but not the fields derivable
  from its specification (slice index and count, carve and object sizes,
  the parent); cross-check them so a wrong field fails before apply.
* [Low] domain library, `dom_core.c` `dom_grant_rate`: rates round up,
  the parent's too, so a child within a thousandth of a CPU of a tiny
  parent fits it; compare quota over period exactly.
* [Low] domain library, `dom_core.c` `dom_check_files`: a runtime image
  flagged `ERX_ENTRY_SYSTEM` is refused; confirm against the boot image's
  layout for domain releases (IM1) that service domains never run the
  system release's ERTS entry.
* [Medium] domain library, the give of a PCIe function (`liberx/system/dom_life.c` `life_unit_function`,
  `liberx/system/dom_apply.c` `apply_function_words`, [design-pcie.md](design-pcie.md#the-catalogue-and-gives)):
  the BAR each range came from is found again in the apply by repeating the planner's "memory and placed" test, so
  a change to one copy pairs a BAR with another's window; store each range's BAR index in `erx_dom_unit_device_t`
  and read each BAR's window from the planner's layout rather than scanning the WINDOW steps. `erx_dom_unit_check`
  does not tie an msi or msix device's line to an MSI step from its own resource, nor an intx device's to an IRQ
  step, so a plan built otherwise could pass with a zero message. A function whose reported pin is not its
  place's is held silently, where the design wants a log line naming both pins; have `erx_dom_pci_given` return
  the reason. `erx_dom_pci_route` and the plan check take msix for a table in any memory BAR it fits, where
  `erx_device_record` takes only a table in the first placed BAR, so a function whose table is elsewhere is handed
  over with a record its holder refuses (it fails safe, with no record); refuse or downgrade such a route at the plan. `route_word` and `ERX_BOOT_ROUTE_WORD_MAX` copy the generated route names by hand. No host test
  reads the `-erx_record function` words, the setting or the message, and `tools/fuzz/dom_core_fuzz.c` holds no
  catalogue, so the PCIe path of the give is not fuzzed.
* [Medium] domain library, `liberx/system/dom_boot_view.c`, `boot_devices`:
  the refusal of a split unit says which relation met (a register page or an
  interrupt line) but not which two devices or which line, where
  [design-shared-devices.md](design-shared-devices.md#refusals) names
  both devices. Record the pair's two entry indices in the view, print them
  from `tools/host/dom_plan.c`, map them to device paths and the line in
  `Manifest` `check_plans`, and have the root's log line print both paths from
  the manifest's strings; assert the names in `test/host/dom_planner_test.rb`.
* [Low] domain library, `dom_core.c` request planning: a requested
  domain's args and env are checked against `ERX_BOOT_STRINGS_MAX` alone,
  while its boot page also holds both node names, so a request that
  leaves no room for them is planned and fails at `apply_bootinfo` after
  its objects are made (the undo clears them). Hold requests to the boot
  view's reserve (`boot_strings_fit` in `dom_boot_view.c`, both node names
  at `ERX_DOM_NODE_MAX`) so the plan refuses them.
* [Medium] domain library, `dom.h`: the apply phase's rules are not
  written down: who sets a connection's `closing`; that `labels` and
  `next_connection` advance only after a successful apply, and
  `next_connection` becomes 0 past `UINT32_MAX`; that plan and apply
  run under the one library lock, so two gives of a device never both see
  it free; and that a device record's `holder` and `memory` are written
  only after the give's last step. Return the counters' next values in
  the plans, or state them in the plan comments.
* [Low] domain library, `dom_life.c`: connect allows a second connection
  between the same pair, which the domain service's "the connection that
  joins D and that peer" assumes away (refuse with `ERX_EEXIST`);
  disconnect frees a living domain's system connection; `erx_dom_plan_stop`
  lists the kernel's exit statuses one by one; and the charging rule is
  stated twice, in the planner's steps and in `life_step_ok`.
* [Low] domain library tests, `test/host/dom_core_test.rb`: a mutant is
  caught by any difference in the driver's output rather than by the line
  its seed must change (`dom_life_test.rb` judges by the line), and the
  origin rule has no `chokepoints_dom_test.rb` showing its allowed sites
  pass.

* [Medium] `abi/manifest.txt`: the `devices[].selector` choice does not make `base`, `size` and `line` inactive for
  selector 2, so a PCIe row with any of them nonzero is admitted, where `docs/design-abi.md` makes them inactive; and
  nothing refuses a device-tree row whose `base + size` wraps. Add the three fields to the choice's `dt` case, decide
  the overflow rule, and give each refusal a fixture case in `test/host/abi_binary_test.rb` and
  `test/host/manifest_reader_test.rb`.
* [Medium] `liberx/backend/fiasco/runtime_main.c`: `liberxroot.a` holds a `main`, and OTP links a tool with the archive ahead of its
  objects, so any member a libc reference reaches that comes to `runtime_entry.c` collides with the tool's `main`. The host test guards only
  `libc_root_write.c`. Moving `main` out of the archive, into ERTS's own `erl_main.o`, which is linked explicitly, removes the rule.
* [Low] domain library, `include/erx/dom.h`: `erx_dom_template_t` repeats `erx_dom_configured_t`'s resolved limits field by field, and `dom_spec_session` copies `dom_spec_configured` (`liberx/system/dom_core.c`); one resolved-limits record embedded in both, filled by one function, would leave a new limit one place to add.
* [Medium] domain library, `tools/host/dom_plan.c`: the build's planner plans the configured domains but no session template, so a template whose limits pass property 14 but not its principal's ceilings, share, budget or domain quota is refused only when a session starts, and the console logs `a session did not start: einval`. Plan each template once there with `erx_dom_plan_session`, unrecorded, beside the configured domains.
* [Low] Lane reader and writer, `liberx/erx_lane.c`: each record state
  machine (open, copy, close) is inline in `erx_lane_take` or
  `erx_lane_put` rather than a pure step the effect layer applies;
  `phase` and `fault` are a pair that must agree; `erx_lane_reader_init`
  and `erx_lane_writer_init` fix the connection side layout, so a pipe's
  or channel's reader or writer and an end that resumes at a position
  need separate pointers and a start position. Settle with the pipe
  server and the channel client.
* [Medium] Lane writer, `liberx/erx_lane.c` `lane_write_header`: the record
  header is packed by hand from the generated offsets, because the ABI
  generator emits only `_decode` for `wire_le` layouts; a field whose width
  changed in `abi/erx_abi.txt` would be written at its old width. Emit an
  `_encode` for `wire_le` layouts and call `erx_lane_rec_encode`.
* [Medium] Lane control table, `liberx/erx_lane.c` `erx_lane_ctl_take`: the reader loads a
  slot's `seq`, then copies its frame, and does not load `seq` again after the copy, so a
  writer that rewrote the slot during the copy (one that broke "A slot is rewritten only
  after its last record is answered") yields a torn frame taken as one record. Load `seq`
  again after the copy and report a change as a rewritten slot, with a host test that
  rewrites between the two loads.
* [Low] Domain library, `liberx/system/dom_core.c` `dom_strings` and `boot_info.c`: the plan admits
  arguments and environment up to `ERX_BOOT_STRINGS_MAX`, but the boot page counts the node and the system
  node against the same limit, so a request within the plan's bound fails at apply (step 23, `ERX_EINVAL`)
  instead of being refused by the plan. Count the names in the plan, or give them their own bound.
* [Low] Domain library, `liberx/system/dom_core.c` (connection numbers): `next_connection`
  runs to `UINT32_MAX`, but the system domain's bell takes the number as its label, and
  labels at or above `ERX_LABEL_SPLIT` belong to the runtime's half of the event table, so
  the lane driver refuses such an open once the objects are built. Refuse the number in the
  plan with `ERX_ELIMIT`, as a link's label is (`dom_life.c`).
* [Low] Lane layouts, `abi/erx_abi.txt` `erx_lane_hdr.need` and
  `erx_lane_rpage.wake`: the ABI loads them with acquire order, where
  design-domains.md "Publishing is a release, reading an acquire" says
  relaxed; the litmus tests model the design's relaxed loads. Make the ABI
  relaxed, or the design acquire with the litmus twins' comments saying so.
* [Low] Lane tests, `test/fixtures/lane_driver.c`: the armed take and the
  producer's publication are each one step of the exploration, and the TSan
  race polls instead of parking, so the handshakes' orderings rest on the
  M5 herd7 litmus tests; add a threaded mode in which both parties park on
  `need` and `wake` under a deadline.
* [Medium] liberx, generated ABI reader: `erx_manifest_open`
  (`liberx/generated/abi_reader.c`) has a 2048-byte frame at -O0 and a
  992-byte one at -O2, and `erx_crash_record_decode` a 976-byte one at -O0
  (clang 23.1.3, `aarch64-none-elf`, measured 2026-11-03). The boot
  validator calls the first, so wherever it runs on a proven stack the
  1 KiB frame cap refuses it. Decode into caller-supplied scratch instead
  of stack locals.
* [Medium] domain library, `boot_system_image` (`liberx/system/dom_boot_view.c`): its two `record_volume`
  refusals, a second window and one held by a row other than the `system` window's holder, have no test;
  add `dom_planner_test.rb` cases that run the view on such manifest bytes past the check, with each
  refusal's removal seeded.

## Security residuals

* [Medium] `liberx/system/dom_boot_view.c`, `boot_devices`, `config/platforms/qemu-virt.json`: a give windows a
  device's whole register page, and the library checks a page's sharing only among the platform record's device
  rows, so a device the machine has on that page but the record does not list is reachable through the holder's
  window. On QEMU virt the display unit lists every transport on its page (`ordinary` rows for the empty ones), as
  [design-fiasco.md](design-fiasco.md) states for all four units, but the block, net and line units still
  list their driven transport alone: a device QEMU attached on another transport of those pages would reach their
  holders unlisted. Listing them needs the tests and probes that take a unit's first device as its driven one
  (`test/site/terminal_test.mjs`, `test/host/dom_planner_test.rb`'s `device_of`
  and net-unit fixtures, `MediumBoot`'s expected catalogue and `/dev` listing) to pick it by role, and the
  `ERX_DOM_DEVICES_MAX` item below. Better still, generate the virtio rows, and `QemuPlan`'s transports, from one
  table, or have the production image suite check that every tree node on a unit's pages is a row of that unit.
* [Low] `tools/lib/erx/area_mappers.rb`, C half: it catches a slip, not evasion. Not refused: a macro over
  `erx_vm_map` defined inside `erx_area_lease_map`, a redefined `ERX_CAP_SELF`, token pasting, a column-0 call
  `erx_area_lease_map(` that moves the body's start, C++ digit separators and raw strings that desync the literal
  blanker, and `.hpp`/`.inc` files, which it does not scan.

* [Low] Facet limits in a create spec (erx_domain_srv.erl, `facet/1`): any positive `max_request` and `in_flight` are taken; every creator is a system-domain process, but nothing intersects them with a ceiling or the creator's own grant, as "attenuated for it" says.
* [Low] liberx, `liberx/backend/core/boot_info.c` (`node_valid`): a boot page's node name is checked only for
  no NUL and one `@` inside it. Every name today comes from the manifest's checked identifiers, so `uname -n` and
  anything else that shows a node's host write it unescaped; require both parts to be system identifiers here, so
  that holds whichever path builds the page.
* [Medium] Lane reader chokepoint, `lane-pages-reader` in
  `tools/lib/erx/chokepoint_rules/`: a text rule over the names of a
  lane's layouts, so untyped pointer arithmetic on a side's address (the
  public `peer_side` and `own_side` of `erx_lane_reader_t` and
  `erx_lane_writer_t`, or the mapping a runtime made) escapes it, as does a
  name a macro pastes together (`erx_lane_ ## hdr`), and inside
  `liberx/erx_lane.c` that only `erx_lane_take`'s path loads from the
  producer's side and only `erx_lane_put`'s from the consumer's is held by
  review.
  It reads a listed set of inherited trees (OTP, musl, Fiasco
  kernel), so a new in-tree import that runs in a domain, such as toybox,
  is outside it until listed; read every listed file less named
  exclusions instead. Close it by construction once the mapping calls
  exist: `erx_lane.c` maps a lane's sides itself, the reader record
  becomes opaque with a test-only constructor for a start position, and
  the syntax-tree leg checks loads.

## Planned features

* [Medium] firmware request, `liberx/backend/fiasco/vc_mbox.c` ([design-fiasco.md](design-fiasco.md#the-firmware-request)):
  no test drives `erx_firmware_request_row` itself; `test/host/vc_mailbox_test.rb` checks only the core through its
  driver's own loop, so the shim's steps, its sleep and its cache maintenance first run on a board (probe B1). Add a
  `raspi4b` suite case that makes one request through the root, if QEMU's property channel takes the raw physical
  address, and otherwise one shared runner of the protocol that a host test drives over a model mailbox. The
  request's deadline also rests on a nonzero counter frequency: `erx_fiasco_clock_ns` reads 0 when CNTFRQ_EL0 does,
  so an unanswered request would poll forever; refuse that frequency where the root starts.
* [Medium] ABI, `abi/erx_abi.txt` and `abi/manifest.txt` ([design-kernel.md](design-kernel.md#firmware-requests),
  [design-board-sensors.md](design-board-sensors.md#the-requests)): no `erx_firmware_request` in the machine
  family; the system manifest's firmware request record and the closed set `fw_tag` carry the device rows only, and
  no machine row or `fw_reading` exists yet. Add the call and the machine rows.
* [Medium] domain library, `include/erx/device_kinds.h` ([design-usb.md](design-usb.md#who-holds-a-controller),
  [design-pcie.md](design-pcie.md#the-bridge-seam)): the host bridges' kinds drive a bridge row, but neither
  platform record (`config/platforms/`) has a `configuration` row and no manifest a PCIe domain, so no bridge is
  given yet (package P12). No host test checks a bridge's given record (role `configuration`, LINE_H 0 for
  QEMU's ECAM, INDEX its row) through the domain library's apply, and the manifest check does not refuse a
  `configuration` row with DMA memory, which the boot view refused while bridges were of no kind.
* [Medium] ABI, `abi/errno.txt`, `tools/lib/erx/abi_errno.rb`: the errno table lists every name of musl's
  `errno.h` and `erx_abi_errno` maps names and numbers, but the directed mappings of
  [design-programs.md](design-programs.md#the-posix-lite-personality)'s "Errors and absent calls" are not
  declared: from each kernel status and each error atom of the file and program protocols to an errno, with a
  context where one status has several POSIX meanings, the generated C, Erlang and Ruby translations, and the
  generator's check that every status has an errno, seeded with a status without one. The `error ATOM NUMBER`
  rows of `abi/protocols/9p.txt` state names and numbers the errno table also states, unchecked against it;
  they name an errno of the table and take its number from it (9P2000.L's Linux numbers are musl's generic
  ones on every architecture erXos targets).
* [Medium] ABI, frame grammar replies (`abi/protocols/prog.txt`, `tools/lib/erx/abi_profile.rb`,
  `tools/lib/erx/abi_emit_profile.rb`, [design-abi.md](design-abi.md#program-protocol)): review findings
  left open. A reply union holding capabilities gets its own walk, but there is no walk of a whole reply
  or of `erx_prog_to_program_t`, so a C consumer switches on `reply->request` to pick one; generate
  `P_reply_caps` and `P_to_program_caps` with the first reply that holds a capability. The startup
  message is told from the channel's frames by its tag alone (a frame tagged other than the protocol's
  name leaves the dispatch unnoticed); declare the startup frame and fail generation on any other tag.
  The slot count (`Profile::SLOTS`, `ERX_PROFILE_SLOTS`) is not derived from `prog_data_slots_max`, which
  `prog.txt` calls the slots a request may name; derive one from the other. `erx_abi_signals` and
  `erx_abi_errno` (`abi_emit_erlang.rb`) form the protocol names again instead of reading
  `Protocols::NAMED_NUMBERS`. Names that collide only at compile time (a kind or frame named
  `to_program`, a union named `frame`, a request case named `errno`) want a generator diagnostic.
  The differential cannot state a busy entry naming no case (only the C fuzz target covers it), and its
  Erlang side names a malformed `to_program` frame by the corpus token, not the frame C selects.
  Reply lines on an inner union's cases (design-abi.md's Extension) need busy to name an inner case;
  specify that with the first request that needs it.
  ones on every architecture erXos targets). The frame grammar's
  rows of `abi/protocols/9p.txt` carry 9P2000.L's wire numbers, which are Linux's and differ from the errno
  table's FreeBSD numbers; check that each row names an errno of the table, keeping its own wire number.
  `enodata` (wire 61), which `erx_littlefs_nif.c` answers for a missing attribute and design-files.md lists, is
  9P2000.L's name for FreeBSD's `enoattr` (87) and names no errno of the table: the check makes that row name
  `enoattr`, keeping wire 61, and the littlefs NIF answer it, and design-files.md's "Errors" list changes with
  them; OTP's `file:posix()` holds neither atom, so that list's claim that each atom is one of `file:posix()`
  changes too. The frame grammar's
  `errno` kind joins with the first reply that carries an error name (P2a).
* [Low] ABI, `tools/lib/erx/abi_errno.rb`: an errno name is any `e[a-z0-9]{1,15}`, so a row `errno eof 99` would
  generate `#define EOF 99` against `<stdio.h>`; and `abi_errno_test.rb`'s `ERRNO_DEFINE` drops a FreeBSD define
  of another form unnoticed, where the musl comparison counted every define.
* [Medium] liberx, `erx` backend, `erx_utcb_self`: the generated trap
  wrappers of calls with UTCB parameters
  (`liberx/backend/erx/arch/aarch64/generated/calls.c`) reach the calling
  thread's UTCB through `erx_utcb_self`, which nothing defines yet. On
  AArch64 it reads `TPIDRRO_EL0`, so it lands as a listed
  system-register function generated from the system-register source,
  with the first shipped call that takes a UTCB parameter
  ([design-abi.md](design-abi.md#kernel-calls-and-bindings)).
* [Medium] ABI call grammar, capability forms the design's call table needs
  and the schema cannot declare yet, each of which the admission plan must
  express rather than the dispatch working around its lookup: a nullable
  argument (`erx_budget_watch`, `erx_irq_create`, since a lookup of
  `ERX_CAP_NULL` is stale), either of two types (`erx_irq_bind`), any type
  (`erx_cap_dup`, `erx_cap_close`, `erx_object_destroy`, `erx_object_info`),
  rights that follow a flag (`erx_mem_create_paged`), and typed items in the
  UTCB checked by the pass plan (`erx_cap_pass`, IPC), which
  `carries_capability?` refuses as a plain aggregate
  ([design-abi.md](design-abi.md#kernel-calls-and-bindings)). The
  `call erx_object_info` declaration waits on the any-type form; its topic
  enum, `reported` flags and report layouts do not
  ([design-abi.md](design-abi.md#inspection-schema)).
* [Medium] conformance, the guest side: a `liberx` reporter that prints
  `erx-test:` lines and ends the machine through `erx_machine_end`, and the
  roster's first cases with their calls; the harness gives one deadline per
  configuration, not per case ([design-build.md](design-build.md#images-and-guests)).
* [Low] abi/formats/mbr.txt: `erx_mbr_entry` declares alignment 4, but entries lie at 446 + 16i on the medium;
  declare 1 if the generator accepts it, so no C reader casts a sector buffer to the struct.
* [Medium] abi/medium.txt: every partition start and record sector is written down, though each follows from the
  order, the lengths and the 1 MiB before each extended boot record; only `layout_is_consistent_test` in
  `test/erlang/erx_blk_table_tests.erl` checks they agree. The ABI generator should derive them (or check those
  written), and the order of the logical partitions, now listed in both `erx_blk_table` and `MediumImage`, should
  come from the file.
* [Medium] abi/medium.txt: the medium layout's sizes (the record's partition 8 MiB, each slot 256 MiB (boot 192 MiB,
  system 63 MiB), the vault's partition 64 MiB, the data partition at least 128 MiB, every boundary on 1 MiB) follow
  the rule of docs/design-storage.md ("The boot medium's table"), at least twice the largest boot image and EROFS image
  erXos packs; nothing flags a release that passes half its partition, the point where the rule asks the
  layout to grow (the packer refuses only one that does not fit). They are not yet checked against the Pi firmware's
  needs of the record's and the slots' FAT partitions, and each slot's signature window is not in the layout yet.
