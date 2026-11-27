# TODO: Display and desktop

Open work on the display stack, the window system, the desktop and LVGL in apps. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Major initiatives

* [Medium] display, GPU acceleration (OpenGL-class) for the desktop and kiosk apps, design after
  research ([plan.md](plan.md#track-d-windows-widgets-and-the-web), part 10). The research record
  is [research-gpu.md](research-gpu.md) (the Raspberry Pi's V3D and QEMU's virtio-gpu 3D modes, Mesa or what replaces it, how a client's
  driver reaches a render service); next is a design of the render service. The display's side is fixed in
  [design-display.md](design-display.md#graphics-hardware), "What a render service owes the
  display": a client presents only a buffer whose jobs have ended, a buffer stays a range of the client's
  pixel area, the present's answer releases it, and an accepted job keeps its ranges and the area alive
  until its device can no longer reach them, whoever ends first.


## Stopgap replacements

* [Low] `erlang/apps/erx_display/src/erx_input.erl`, [The input router](design-display.md#the-input-router):
  a tick moves a repeat's time one period on from its last, as the design says, so after the window system
  stalls for a while each following tick sends one repeat at once until the repeat catches up with the clock.
  Settle in the design whether a late repeat skips to the next period after the tick.
* [Low] `erlang/apps/erx_display/src/erx_window.erl`, [The window tree](design-display.md#the-window-tree):
  a window's set of held keys is keyed by code alone, so when two sources hold one key down to the same window
  the first source's up drops it from the `K` set while the other still holds it. Key it by source and code.
* [Low] `erlang/apps/erx_display/src/erx_window.erl`, [Input events](design-display.md#input-events): a
  wheel step reaches a window but is not encoded in its `mouse` file as buttons 8 and 16.
* [Medium] `erlang/apps/erx_fb/src/erx_virtio_gpu.erl`, [The display device](design-display.md#the-display-device):
  the driver process runs on QEMU's virtio-gpu only in the `display_domain` suite, whose one boot brings the
  device up and shows a client's window; its failure paths have run only as its pure core's host tests. A host test
  of the process on stock OTP is cheap: stub modules `erx_device`, `erx_irq_line`, `erx_memdraw` and `erx_log` that script a
  device answering out of order, refusing a post as full, firing a spurious line, returning a stray completion
  between frames and staying silent past the deadline (a `-D` macro shortening it).
* [Medium] `erlang/apps/erx_fb/src/erx_virtio_gpu.erl`: the screen image's region is sized from the display size
  the device reports at each bring-up, and `erx_device:region/3` refuses the same index with other bytes, so a
  restart after the display's size changed leaves the domain without a screen until the next boot. Size the region
  from a bound that does not change between restarts and show any mode that fits it. The driver also acknowledges a
  configuration-change interrupt without reading `events_read` or writing `events_clear` (virtio 1.2, 5.7.4.2),
  so a change of display size is not followed.
* [Medium] the Raspberry Pi 4's display domain row (`config/manifest/raspi4b-development.txt`, `limits display`;
  [design-display.md](design-display.md#the-display-device)): the display domain holds the `framebuffer`
  unit and drives it with `erx_firmware_fb` on the `display` share's 100 mcpu and 40 MiB, QEMU virt's
  unmeasured 24 MiB with the 8 MiB screen image of one 1920x1080 screen of 32 bits, which on the Pi lives in
  the domain's own memory, and 8 MiB of headroom (about 33 MiB at 4K, where `alloc` answers `enomem` and the
  driver `ignore`s). Neither figure is measured: size both from a measurement of the domain driving the
  dashboard on a 1920x1080 screen on the Pi, a hand step (design-platforms.md, "Trying a card on a board",
  step 5).
* [Medium] `erlang/apps/erx_display/src/erx_screen.erl`: the overlay and the idle policy, whose times are the display
  domain's `display_idle_dim_s` and `display_idle_off_s` variables, are not built; the screen receives the input notice
  from `erx_winfs` and ignores it, so no idle clock runs
  ([The screen and its one path to the device](design-display.md#the-screen-and-its-one-path-to-the-device)).
* [Low] `erlang/apps/erx_fb/src/erx_virtio_gpu_core.erl`: `mode/2` bounds scanout 0 only by the memory given;
  bound its width and height by `erx_memdraw`'s limits once `wrap/4` sets them.
* [High] [design-display.md](design-display.md): the code the design asks for that the tree does not have, in the
  order [Track D](plan.md#track-d-windows-widgets-and-the-web) builds it. Nothing below is built; the cores named
  as landed are kept and changed as listed.
  * **The pixel area** ([The pixel area](design-display.md#the-pixel-area)): the domain library makes it
    (`erx_dom_connect`'s `area`, `area_reader`), `connection_up` carries it, the connection agent maps it and
    unmaps it after the last image over it (`erx_area`, `erx_memdraw:wrap/4`), and the domain service makes it
    for every pair a `windows` grant joins (`erx_domain_mints:pair_area/3`); still missing is a QEMU case in
    which one domain writes an area's pixels and the other reads them, which needs a reader in the display domain
    (`erx_winfs`).
* [Low] `erx_domain_mints:pair_area/3`: two display domains each granted the other's `windows` service share one
  connection, which carries one area, so the pair takes the lower server row's grant and the other display's grant
  is installed without an area it writes. A nested display, a display that is another display's client, is the
  case; give a connection one area per direction, or have property 18
  refuse the pair, when one is configured.
* [Low] `erx_memdraw_nif.c`: read-only images are refused as destinations by each writing NIF calling `get_dst`;
  carry the bit in the core or a separate resource type so a new writer cannot miss it, and cover poly,
  fill_poly, ellipse and arc in `wrap_read_only`. The stand-in area has no guard page before the area.
  * **The manifest** ([A display's session](design-display.md#a-displays-session)): the `display` record in
    `abi/manifest.txt`, named after the `windows` service it describes, and its reader; property 18 of the manifest
    check (a template's `pixels` counted by its principal's `domains` quota, no facet row setting `session`) with its
    seeded violations; `abi/services/windows.txt` with the parameters `windows`, `pixels`, `clipboard` and `session`; the
  * **The pixel area** ([The pixel area](design-display.md#the-pixel-area)): `erx_dom_connect` with `area` and
    `area_reader`, the connection record's `area`, the grant-table rows and the Fiasco backend's row for an object two
    tasks map (`liberx/system`); `connection_up`'s `Area` and `ERX_LANE_CTL_SLOT`'s pinned length; the connection
    agent's mapping and unmapping of an area; the `erx_area` NIF and `erx_memdraw:wrap/4`, an image over memory the
    NIF did not allocate, which the agent unmaps only after the last image over it is gone.
  * **The display's session and grant** ([A display's session](design-display.md#a-displays-session)): the
    display's session from a start row ([Track A](plan.md#track-a-apps), part 1), with `session` carried by
    every mint of its grant from the session mark the domain service alone sets. A window's buffer at the screen's
    size, allocated once by `erx_win:open/2`, with
    `resized/1` allocating nothing; the grant defaults of 1 window, 8 MiB and `clipboard` off at the server.
  * **The reserved chord** ([The reserved chord](design-display.md#windows-and-the-window-system)): its field in the
    `display` record, its source spelling and its key encoding, which land with the login design's choice of what
    the chord brings up ([Risks and decisions](design-display.md#risks-and-decisions), 14). Until then no
    display has a chord, so every key reaches a window.
  * **Property 18 and the domain library** ([The pixel area](design-display.md#the-pixel-area)): property 18
    sums each display grant's pixel area and the side the display reads against the display domain's `outer`, but
    the outer budget also pays for the crash area, bells, the system connection and every other side it reads, and
    the grants are not compared with the `connections` quota, so a manifest at the limit passes the build and the
    last session's connection is refused at run time. Plan the display grants' connections in the boot view of
    property 12, so the domain library's arithmetic is the one judge. And `session` is declared as a manifest
    parameter of `windows` that only property 18 refuses: carry the session mark only in the domain service's mint
    request, so no manifest can spell it.
  * **The screen and the allocator** ([The screen](design-display.md#the-screen-and-its-one-path-to-the-device),
    [The pixel area](design-display.md#the-pixel-area)): `erx_screen` sends frames with
    `gen_server:send_request/2` and keeps only pending state (the newest layout, one waiting present per live window,
    dropped at the window's end); presents and `erx_memdraw:wrap/4` refuse an offset off a page boundary.
  * **The display domain**: the display side gains `erx_winfs`, `erx_window`, the
    policies and `erx_wm_menu`, and the client side `erx_win`'s library, `erx_draw`'s `string/5`, `erx_font`,
    `erx_draw_conn`'s crash report scrubbing (its state is hidden, its stack trace and queued writes are not),
    `erx_term` and `erx_ui` with its servers and renderers (docs/design-display.md, "Overview"). The G9 build
    check (`tools/lib/erx/display_release.rb`) reads module names in the display script's sources; the design's xref
    check over the display release's beams, with its refusal of calls that start a port or a sub-space, is not built.
    `erx_screen_core` knows no buffer's size: a layout entry carries only the window's rectangle, so the plan
    cannot fill the background where a buffer smaller than its window does not reach, and the direct path's third
    condition, a buffer of the screen's size, cannot be judged. Since that size changes with each present, the
    path can change on a present, which `present/4`'s answer must then express (entering or leaving the direct
    path), not only a layout.
  * **The widget server** ([The widget server](design-display.md#the-widget-server)): `erx_ui` with `open/1`,
    `tree/2`, `close/1`, the renderer behaviour and the toolkit's supervisor, and `erx_ui_server`, which validates a
    tree with `erx_ui_schema`, numbers it with `erx_ui_model:pair/3`, applies `delta/2` through the renderer and
    routes its hits through `erx_ui_model:hit/4`; `pair/3` and `hit/4` themselves, with their property tests
    ([Verification](design-display.md#verification-and-testing)).
    `erx_screen_core` keeps its plan and takes the design's names: a present for a flush, and no expose, since
    `erx_screen` copies what a layout change uncovers from the windows' buffers.
  * **The widget server** ([The widget server](design-display.md#the-widget-server)): `erx_ui`, `erx_ui_sup`,
    `erx_ui_server`, the `erx_ui_renderer` behaviour and `erx_ui_model:pair/3` and `hit/4` run on the host over a
    target the caller makes (`erx_ui:start/1`). Left: `erx_ui:open/1` answers `{error, enotsup}` for a display the
    domain holds and for `web` until the server opens its window as its holder (with the window stack, `erx_win`) and
    the web line; the server's `{ui_down, Window, display_down}`; `erx_ui_erlang`; and the seeded faults of the
    Verification bullets for `pair/3` and `hit/4` (keys paired across parents, every omitted property kept, the value
    taken from the report) as property tests under PropEr, which the tree does not have yet; the cases run as seeded
    EUnit in `test/erlang/erx_ui_model_tests.erl`. The opener's map from a window to its server keeps a stale
    entry after `ui_down` until the opener calls `close/1`. `erx_ui:open/1` takes any facet the domain holds as a
    display, where the design asks for a grant of a `windows` tree. Only the `client` boot row takes `erx_ui`; a
    session's script, which the design gives widgets, and a web-only domain's do not yet.
  * **`erx_ui_lvgl`** ([The widget server](design-display.md#the-widget-server)): the shell
    (`erlang/apps/erx_ui/src/erx_ui_lvgl.erl`) performs `erx_ui_lvgl_core`'s actions over a port its `open`
    callback starts and a `present` callback, and `test/host/erx_ui_lvgl_test.rb` drives the real `erx-lvgl` with it
    on the host. Left: `open` on erXos, which starts the program in the session with the window's buffer as its
    `mem` descriptor 3 (the Programs item below), and `present`, `window/2` and `resize/3` bound to the window, with
    the display domain; the fault log names the window and the report's byte position, which the design asks for
    and the shell does not count yet. A window grown past its buffer is refused by the program and ends the UI as
    `renderer_down`, because the shell does not clamp; the design has the shell write each `screen` record clipped
    to the buffer's size, which it asks for at the size of `erx_win:info/1`'s `screen`, so clip it there. A fault
    fails a waiting `apply/2` only by the shell's exit. A program that stops reading its input blocks the shell in
    `port_command/2`, and with it `apply/2`, `close/1`, the window's input and the program's exit, a residual until
    writes are bounded (`nosuspend` and a busy event for the core, or a `close/1` that kills the program itself).
    (`erlang/apps/erx_ui/src/erx_ui_lvgl.erl`) performs `erx_ui_lvgl_core`'s actions over the program's pipes on
    erXos, started with `erx_prog_handler:start/1` and a lent buffer (the display suite's lvgl-lease cell), and
    over a port on the host (`test/host/erx_ui_lvgl_test.rb`); `erx_ui:open/1` binds it to a window the widget
    server opens with `buffer => none`, with a presenter process and mouse and kbd readers linked to the server.
    Left: `erx_ui_server:init/1` answers every renderer start failure as `renderer_down`, so a caller cannot
    tell a full pixel area (`enomem`) from a crash and the display suite's lvgl client retries every refusal;
    the wheel's
    buttons, which `erx_ui_lvgl_core:input/2` drops. The window-bound path (presents through `erx_win:present/3`
    from the shell, the window readers, `await_reading/1`, the `r` record's resize) has no host test, since it
    needs a display; the display suite's lvgl cell is its test. A pointer is made window-relative with the rectangle the mouse
    reader last read, which an `r` record refreshes, but `erx_window` marks `r` only when the size changes, so a
    move at the same size leaves every later pointer off by the move (latent under the single policy, which
    never moves a window): the display should mark `r` on any change of the rectangle, as Plan 9's mouse device
    does, or send window-relative positions, a choice for docs/design-display.md. A resize is taken at once
    and so overtakes a pointer record postponed while a report is open, which may then lie outside the smaller
    screen. The shell waits for each present's answer, so a display that never answers holds the shell, a
    waiting `apply/2` and `stop/1`; the supervisor's shutdown then kills the widget server, and the shell,
    blocked in the request's receive, its readers and the program stay. The range is the handler's, not the
    shell's, so the program's damage report and its handler's end race: a report the shell takes before the
    handler's `DOWN` is presented even when the range has already returned and been lent again, and once the
    lease is back the window, held by the widget server until it ends, still names the range in its last
    present (the client's own pixels in its own area either way; the ordering in `erx_pixels` and the window
    tree is unverified); a shell that held the range would close both by construction. The widget server's start, the window's open and up to `?START_MS` of
    the program's start, runs inside `erx_ui_sup`'s `start_child`, so one slow start holds every other
    `erx_ui:open/1`. The fault log names the window
    and the report's byte position, which the design asks for and the shell does not count yet. A fault fails
    a waiting `apply/2` only by the shell's exit. On the
    host a program that stops reading its input blocks the shell in `port_command/2`, and with it every call;
    erXos's writes are bounded by `erx_pipe_srv:write/3`'s deadline. The reader passes on every read of the
    program's output, so a program that floods events grows the shell's mailbox, as a port's data does.
    [Medium] `start/3`'s 30 s deadline kills the shell, but a handler blocked in its start actions
    (`erx_pixels:alloc/2` and `lend/2`, `erx_pipe_srv:forward/1`, all without a bound) reads the starter's
    `DOWN` only once it is back in its loop, so it keeps its range, holder entry and hand-offs until the call
    answers; the deadline belongs in `erx_prog_handler:start/1`, which kills the handler and so frees what it
    holds for every starter, once docs/design-programs.md ("The handler") names it. In the lease cell
    and `erx_ui_lvgl_shell.erl`, a present the program sends after the tree is written can reach the test
    before the apply's answer and be taken as an earlier frame's, which leaves the first-present wait to
    time out; the cell's 240x160 check shows only that a present came.
  * **`erx_ui_host`** ([The SDK](design-packaging.md#the-sdk)) [Medium]: `sdk/erx_ui_host.erl` runs an app's UI
    under stock OTP with the LVGL renderer, and `test/host/erx_ui_host_test.rb` checks its frame against
    `test/display/reference/ui-host-lvgl`. Left: the Erlang renderer, for which `start/1` answers `{error, enotsup}`
    until `erx_ui_erlang` exists; a tree with a `present` property ends the UI as `renderer_down`, since the host
    has no canonical text for a presentation until `erx_present:text/2` exists; and the host starts `erx-lvgl`
    through `ruby -e`, because a port cannot hand a program its buffer as descriptor 3, so an app's host test needs
    Ruby on the path.
    time out; the cell's 240x160 check shows only that a present came. The display suite's lvgl-confine cell
    checks only the store past the buffer: the design's other two checks, that the session's process table lists
    the program and that its pipes are the session's, wait for a reader of each, since `ps` lists the runtime's
    Erlang processes rather than the command server's table (`erx_command_srv:read/2`) and no inspection path
    names a pipe end's holder.
  * **Programs** ([The startup message](design-programs.md#the-startup-message)): the profile, `liberx`'s
    decoder, its fuzz targets and the descriptor table (`erx_prog_fd_mmap`, `erx_prog_fd_fstat`) take the `mem`
    descriptor; `erx_program:start/1` takes a window buffer's lease, the driver maps it at the buffer place, and
    musl's descriptor seam routes a program's descriptor calls to the table; the display suite's lvgl-lease cell
    runs `erx-lvgl` over real lent buffers, so the driver's `LEASE_MAP`, a program's `fstat` and `mmap` of fd 3
    and the lease's return run on the target. Left: a `MAP_FIXED` over fd 3's mapping and the order of the
    anchor's destroy, the lease's return and `{erx_area_returned, N}`, checked on the target; and `fstat`'s modes
    (a pipe end a FIFO of 0600, a mem range a regular file of 0600) checked against FreeBSD's `pipe_stat` and
    `shm_stat`, unverified, and a pipe end's size, 0 where FreeBSD reports the bytes readable.
  * **Input from another domain** ([The display device](design-display.md#the-display-device)): the
    display's reader of each file of a granted input tree, a source of the router with one read outstanding, which
    decodes each read with `erx_input_codec:decode/1` and puts the bytes of a split record before its next read, and
    `erx_input_follower`, which keeps one reader for each file of each grant of the `input` interface.
  * **The web** ([UIs: the browser renderer](design-web.md#uis-the-browser-renderer)): `erx_ui_server` and
    `erx_ui_browser` start in the application's session; `erx_web_line` keeps the table of open UIs and serves the
    `ui` and `uis` targets as views; `erx_web_conn` decodes an event's record and sends every `open` to the line,
    where it answers `ui`, `uis` and `event` as unsupported today.
* [Low] display, `erx_input_follower` and `erx_input_reader:files/1`
  ([The display device](design-display.md#the-display-device)): a tree's listing is held whole, up to
  `erx_file_remote`'s 1,048,576 entries, before `input_tree_files_max` refuses it, in a lister with no
  `max_heap_size`, and a tree whose listing fails is listed again each second; a residual of trusted serving domains.
* [Medium] `erlang/apps/erx_display/src/erx_winfs.erl` and `erlang/apps/erx_win/src/erx_win.erl`, [The window
  tree](design-display.md#the-window-tree): the tree serves no `screen` file at a client's root, and
  `abi/services/windows.txt` names no root file, so `erx_win:open/2` sizes the buffer by the new window's `wctl`
  rectangle, which only the single policy sets to the screen's; under `erx_wm_rio` a buffer would be the size of the
  window's first placement. Serve `screen` as the design gives it (`EIO` while there is no screen, `EACCES` when
  opened for writing, `EEXIST` for a `mkdir` of `screen` or `clipboard`), have `open/2` read it before the `mkdir` for
  the size and the channel, keep the allocation after the `mkdir`, and correct the moduledoc's account of the order.
* [Medium] `erlang/apps/erx_win/src/erx_pixels.erl`, [The lease](design-display.md#the-pixel-area): a lease
  `lend/3` makes for a holder other than the range's owner can be taken by that holder's program port like any, so
  "a program maps only a range its handler owns" holds only because `erx_draw_conn`, the one caller of `lend/3`,
  starts no port. Nothing widens today, since every process of the domain can open the area, but make it hold by
  construction: a lease whose holder is not the owner is one no port takes (a flag of `erx_area:lend`, checked by
  `erx_area_lease_take`). The same "taken" knowledge would let an owner's second lend of a lease it still holds
  untaken answer `ebusy` instead of waiting for a return only it can cause; today every failed start unlends.
* [Low] `erlang/apps/erx_win/src/erx_draw_conn.erl`, [The draw connection](design-display.md#the-draw-connection):
  a connection ends only with its window's holder; a window ended otherwise (its directory removed, its display
  lost) leaves it running, each present failing with `EIO`. End it when a present answers that the window is gone.
* [Medium] `erlang/apps/erx_win/src/erx_draw_conn.erl`, `perform_write/2`: design-files.md ("A program's window")
  promises that a `draw` write holds its grant's later requests for at most one present, but the write runs every
  operation in its callback, each `v` waiting for its present, so a write alternating drawing and `v` holds the
  grant, a `kbd` clunk among its requests, and the connection's input replies and flushes for several presents.
  Give a draw write keeper handling that stays responsive between presents, or restate the promise and bound the
  whole write's delay; add a regression with several drawing and `v` pairs in one write followed by a `kbd` clunk.
* [Medium] `erlang/apps/erx_win/src/erx_vt.erl`, [The terminal
  emulator](design-display.md#the-terminal-emulator): the oracle test
  (`test/host/erx_vt_oracle_test.rb`, libvterm 0.3.3 with `test/vt/vterm_dump.c`) runs only the per-row cases
  and the open details of `test/vt/corpus.rb`: the exhaustive enumeration, the streams generated from the
  tables' grammar, the `prim_tty` and toybox recordings, `vttest`'s core (pin `vttest` 20251205, SHA-256
  `cd6886f9aefe6a3f6c566fa61271a55710901a71849c630bf5376aa984bf77cc` as Homebrew records it, and write the
  pseudo-terminal driver) and the coverage check of [Verification](design-display.md#verification-and-testing)
  are not built. Three entries of `test/vt/differences.txt` keep `erx_vt`'s choice where the references read did
  not settle it, and want xterm's source or DEC STD 070 checked: HT at the last column with a wrap pending,
  U+00A0 inside a control sequence, and `CSI ? 1049 h` on the alternate screen. The dump holds no scrollback,
  so what DL and a resize save, and the scrollback's charge per row, are checked only by the EUnit cases.
  The terminal generator writes the width table for Erlang and `include/erx/vt_width.h`, not musl's
  `wcwidth` tables or `erx_width`.
* [Medium] `erlang/apps/erx_ui` and the generated `erx_ui_wire:encode/2`, [Widget
  trees](design-display.md#widget-trees): an `input` whose application-set `text` holds a character the line
  escape changes (a tab, a control, a format character) is shown escaped, and a user's edit of it reports the
  escaped text back as typed, so the application stores `<U+0009>` where it set a tab. Make what an input shows and
  what it holds one text by construction, for example a validity rule that refuses a state text the line escape
  changes. Until then the widget tests cover only inputs of printable text. The cut at the bound adds a second
  loss: an input text whose escape is longer than 4,096 bytes is shown cut with `...`, and an edit reports the cut
  text back.
* [Low] `erlang/apps/erx_ui/src/erx_ui_lvgl.erl`: `format_status/1` keeps only the state, but a crash's stack
  trace does not pass through it, so a `function_clause` in `handle_event/4` (a stray `'EXIT'` while it traps exits)
  or in `erx_ui_lvgl_core:step/2` logs the widget tree as an argument. Add a catch-all clause that drops an unknown
  message, and end a core or encode failure through `down/2` with a reason that names no term.
* [Medium] `erlang/apps/erx_memdraw/src/erx_chan.erl`, `display/memdraw/erx_memdraw.c`,
  `erlang/apps/erx_fb/src/erx_virtio_gpu_core.erl`, [Windows and
  buffers](design-display.md#windows-and-buffers): the 4 bytes past a buffer's rows are stated by hand in
  three places: `erx_chan:bytes/3` (`+ 4`), `erx_memdraw_wrap` (`sizeof(ulong)`) and `region_size/1` (its own
  `WORD_PAST_ROWS`, 8). A change to libmemdraw's load width would make the window admit presents the wrap
  refuses. Add a limit such as `windows_buffer_tail` to `abi/services/windows.txt`; `erx_chan:bytes/3` uses it,
  `erx_memdraw_wrap` uses it under `_Static_assert(ERX_WINDOWS_BUFFER_TAIL >= sizeof(ulong))`, and
  `region_size/1` calls `erx_chan:bytes/3` (with `erx_chan` added to the module lists of
  `test/host/erx_virtio_gpu_core_test.rb` and `tools/fuzz/erx_virtio_gpu_core.rb`). Add a property test that
  `erx_window:check/2` admits a present exactly when `erx_memdraw:wrap/4` accepts it, over random sides, every
  supported depth and offsets near the area's end.
* [Medium] `display/memdraw/erx_memdraw.c`, [the pixel
  primitives](design-display.md#verification-and-testing): the 9front build (unmodified 9front `libmemdraw`
  built for the host, the test tool of design.md's dependency table) does not exist yet, so `erx_memdraw` is checked
  only against `erx_draw_ref`. Build it, run `erx_memdraw`'s operations and the shapes against it, and treat each
  of erXos's edits listed in `display/libmemdraw/ORIGIN.md` as a documented difference with a test. One of those
  edits is an upstream bug (`readbyte`'s alpha-only read of a replicated grey-and-alpha mask wrote grey into the
  alpha buffer): the item below reports it.
* [Low] display, `display/libmemdraw/draw.c` (`readbyte`): report the upstream bug to 9front. Under an alpha-only read
  of a replicated grey-and-alpha mask, `readbyte` wrote each pixel's grey into the alpha buffer; erXos's copy fixes it
  (marked erXos, recorded in `display/libmemdraw/ORIGIN.md`).
  primitives](design-display.md#verification-and-testing): the 9front build (`MemdrawBuild.oracle`) checks
  only the shapes, under `SoverD`. Run `erx_memdraw`'s draws and loads against it too, and treat each of erXos's
  edits listed in `display/libmemdraw/ORIGIN.md` as a documented difference with a test. One of those edits is an
  upstream bug (`readbyte`'s alpha-only read of a replicated grey-and-alpha mask wrote grey into the alpha
  buffer): a candidate report to 9front.
* [Medium] `display/memdraw/erx_memdraw_nif.c`, [Draw messages](design-display.md#draw-messages): the move to a
  dirty scheduler counts only the clipped destination's bytes, so two calls that cost more stay on a normal scheduler:
  `alloc`, whose fill writes the whole image, and a draw whose mask, or replicated source, is the destination, which
  copies the whole destination image first (`snapshot`) however small the clipped rectangle. Count the bytes each call
  actually touches; measure a full-screen `alloc` and a 1-pixel self-masked draw on a 4K screen image to set the bound.
  `erx_memdraw_draw_bytes` also reads the live image headers, apart from the draw's own copy, so a concurrent `clip`
  can make a large draw count small (scheduling only; the draw itself is checked on its copy).
* [Medium] `display/memdraw/erx_memdraw.c`: `clip` rewrites `flags` and `clipr` in an image's shared `Memimage`
  while another process may be drawing from it, a C11 data race that is memory-safe only because
  `erx_memdraw_draw` and `shape_begin` each copy every header once and check the copy whole. Take the replicate
  bit and clip rectangle out of the shared header (kept by the image's owner and passed to each call, or a
  per-image record `clip` replaces whole), so the header is immutable after `alloc` and no copy is needed.
* [Medium] `display/memdraw/`, the chokepoints `memdraw-clip` and `memdraw-pixels`
  (tools/lib/erx/chokepoint_rules/memdraw.rb) are file-level: they admit every function of `erx_memdraw.c` and
  `draw.c`, where the design names `erx_memdraw_draw` and `memdraw` as `memimagedraw`'s only callers and
  `snapshot` as erx_memdraw's only pixel copy. Move the two funnels and the snapshot into a file of their own, or
  scope the rules by function.
* [Low] `display/memdraw/erx_memdraw_nif.c`, `get_points`: a failed `enif_alloc` of a shape's points answers
  `badarg`, not `enomem`.
* [Low] `display/memdraw/`, erx_memdraw's tests: nothing exercises a draw that moves to a dirty scheduler or an
  `enomem` answer (`alphadraw`'s buffer or the snapshot failing to allocate). Add a draw over 64 KiB and an
  allocation-failure seed to `test/erlang/erx_memdraw_tests.erl`.
* [Low] `display/libmemdraw/draw.c`, `alphadraw`: its per-call buffer comes from `mallocz(n, 0)`, not zeroed, as
  upstream's was not. Zero it (`mallocz(n, 1)`), or show that every byte is written before it is read and
  say so beside the call.
* [Low] `display/memdraw/erx_memdraw_nif.c`: `ERL_NIF_INIT` gives no `upgrade` callback, so reloading `erx_memdraw`
  while images are live fails rather than taking over the resource type. Add one (`enif_open_resource_type` with
  `ERL_NIF_RT_TAKEOVER`) when hot reload of the display domain is wanted.
* [Medium] `display/lvgl/erx_lvgl.c` and `erlang/apps/erx_ui/src/erx_ui_layout.erl`, [Widget
  trees](design-display.md#widget-trees): an absent `pad` is none in the box model, but `erx_lvgl.c` strips the
  theme style only from containers (`lv_obj_remove_style_all`, line 401), so a widget keeps the LVGL default theme
  pad (a button sets `pad_hor` to `PAD_DEF`, `lv_theme_default.c:292` at lvgl `80ca777e3`) and the two renderers size
  a button without `pad` differently. Clear the theme pad on every widget, or declare the default in `ui.txt` for
  both.
* [Low] `erlang/apps/erx_ui/src/erx_ui_layout.erl`, [The widget server](design-display.md#the-widget-server):
  `layout/3` takes a `tree()` and returns a placed tree of the same shape, while `erx_ui_erlang` will hold the
  opaque `erx_ui_model:realised()` the operations build, so it must walk the two side by side. When `erx_ui_erlang`
  is written, decide whether the layout takes the realised tree through an `erx_ui_model` accessor and returns a map
  from `node_id()` to `{Rect, Content}`, which makes redraw a map comparison and hit testing a lookup.
* [Medium] `display/lvgl/erx_lvgl.c`, [The widget server](design-display.md#the-widget-server) and design-abi.md
  "Widget format": gaps the LVGL program had to fill. (1) An `input` key's `code` has no stated meaning; the program
  uses the rune alone, with keyboard(6)'s private-use runes for the cursor keys. (2) `align` `start`, `center` and
  `end` have no LVGL flex equivalent per child; the program gives such a node its own size at the start of the cross
  axis, so the parity test will differ there. (3) No source declares Plan 9 channel descriptors (`draw.txt` declares only
  the messages); the program computes the four it renders in (`r5g6b5`, `r8g8b8`, `x8r8g8b8`, `a8r8g8b8`) with draw(2)'s
  `CHAN` packing, and should take them from the generated table once it exists.
  (4) A `present` property is shown as LVGL glyphs without the line escape the design asks for, since no C twin of
  `erx_text:escape_line/1` is generated. Glyph rendering cannot inject terminal controls, but bidirectional overrides
  and invisible format characters still mislead, and LVGL's font draws U+F000-U+F8FF as its built-in icons; the
  simplest fix is for the widget server to escape the canonical text before encoding it.
* [Medium] `display/lvgl/erx_lvgl.c`, [Widget trees](design-display.md#widget-trees): `align`'s `start`,
  `center` and `end` are not placed; `node_size()` only tells `fill` from a node's own size, and LVGL's flex
  layout places every child at the start of the cross axis. `examples/dashboard` centres its clock and right-aligns
  its prices with weighted spacers meanwhile. Place a non-`fill` child within its slot, as `erx_ui_layout` does.
* [Medium] `display/lvgl/erx_lvgl.c`, review findings left open. (1) A slider whose `max - min` exceeds a signed 32-bit
  integer overflows inside LVGL (`lv_bar.c`), which the sanitized build aborts on; scale such a range. (2) `set_slider`
  re-applies the last `value` the server sent on any set of the slider, undoing the user's drag, and `items` alone
  resets a list's selection to 0; which state value a set keeps is a question for `erx_ui_model:hit/4`'s design.
  (3) The focus ring follows LVGL's group, which orders nodes by creation, not tree order as design-display.md
  "Kiosks and glasses" asks; rebuild the group at commit. (4) A status shows as `[timeout]` with no milliseconds and
  no reporter, unlike `erx_render`'s tokens (G7). (5) A text holding U+0000 is cut there by LVGL. (6) The Makefile
  rebuilds LVGL's objects when `lv_conf.h` or a source or header they read changes, not when the compiler does.
* [Medium] `display/lvgl/lvgl` (the fork submodule), `make check`: erXos's own patches committed on the fork are not
  seen by `make check`'s ASCII and chokepoint scans, which skip the submodule as imported code, though CLAUDE.md (Forks as submodules) holds those patches to the
  same ASCII and review rules. Scan the fork's diff from the commit ORIGIN.md names to the gitlink; due with the
  first patch.
* [Low] `display/lvgl/ORIGIN.md`: nothing checks the commit it records against the superproject's gitlink.
* [Low] `display/lvgl/Makefile`: `-I$(LVGL)` exposes the whole checkout, so a header at its root could shadow a system
  header.
* [Low] `display/lvgl/Makefile`: a `.c` file deleted on a fork branch stays in `liblvgl.a`.
* [Medium] `erlang/apps/erx_display/src/erx_wm_rio.erl`: the menu works but nothing draws it: `erx_wm_menu`
  and `erx_screen:overlay/2` are not built, so a right press on the background opens an invisible column of
  items, and `erx_winfs` does not yet derive `menu/2` after every message and hand it to the drawer as
  [Windows and the window system](design-display.md#windows-and-the-window-system) says. The menu's labels
  are the `body` role's glyphs, whose generated module waits on plan items 8.11 and 8.12 (FreeType,
  `erx-raster`, Inter and `Erx::Glyphs`).
* [Low] `erlang/apps/erx_display/src/erx_wm_rio.erl` (security residual): a client learns where the pointer is
  while it crosses its window and can raise or move its window under it with `wctl`, so the user's next click
  picks that window, as under rio. The same race steers a menu command's naming press, which acts on the window
  under the press when it comes: a client that hides or moves its window, or opens a new one, just before the
  press can turn the user's `delete` aimed at it onto another session's window beneath, which then ends.
* [Low] `erlang/apps/erx_display/src/erx_wm_rio.erl`: open points of the menu. A move's or resize's naming press
  picks without raising, and a cancel keeps the pick, so the keyboard may go to a covered window; Escape while
  the menu is held goes to the current window and leaves the menu open, which the design does not state; the
  menu's rectangles, fixed at its press, can lie off a screen re-attached smaller while it is held, against
  `erx_wm`'s rule that every rectangle lies within the screen.
* [Low] `erlang/apps/erx_display/src/erx_input.erl`: `destination/1` ends in a catch-all, so a new route that
  should give the policy its gesture would silently go nowhere.
* [Medium] the display driver over the root's framebuffer record (`liberx/backend/fiasco/runtime_entry.c`,
  `framebuffer_give`, and its future Erlang driver): the framebuffer's object is device memory
  (`ERX_MEM_ATTR_DEVICE`). Unverified against the Arm Architecture Reference Manual: that an unaligned access or
  `DC ZVA` to device memory faults, so a `memset`, `memcpy` or the compiler's zeroing of a mapped framebuffer may
  fault where normal memory would not. Read the manual's device-memory rules before the driver writes to the
  mapping, and keep its bulk copies aligned or map the framebuffer as normal non-cacheable memory
  ([todo-performance.md](todo-performance.md), the framebuffer mapped as device memory).
* [Medium] the framebuffer record's target paths (`liberx/system/dom_args.c`, `args_given_words` and
  `args_unrecorded`; `liberx/backend/fiasco/runtime_entry.c`, `gather_args`, `framebuffer_facts`,
  `framebuffer_give`): only the pure core and the view are host-tested, and no shipped manifest gives a framebuffer
  to a configured domain. A check that a configured holder's boot page carries one `-erx_record framebuffer` record with a
  non-null handle for a placed framebuffer and none for an unplaced one would catch a dropped skip or a wrong
  installed index.
* [Low] the framebuffer format names exist in three hand copies (`kernel/core/dt.c`'s table,
  `erx_device_record.erl` `format/1`, the record fuzz target's `?FORMATS`), and `ERX_BOOT_FORMAT_WORD_MAX`
  (`include/erx/boot_words.h`) is sized by hand to the longest: a new or longer name makes the Erlang reader refuse
  every record, or the root print no line at all for an OK framebuffer. Check every `erx_dt_fb_format_name` against
  both in a host test, or generate them from one source, and print a fixed reason when an OK framebuffer has no
  usable format.
* [Low] `erlang/apps/erx/src/erx_device_record.erl`, the `-erx_record framebuffer` reader: it accepts an OFFSET of a
  page or more, which the root never writes; refuse it, and teach the fuzz reference
  (`test/erlang/erx_device_record_fuzz.erl`) the same bound.
* [Low] [design-display.md](design-display.md): the display design never names the root's `-erx_record
  framebuffer` record ([design-device-tree.md](design-device-tree.md), "Facts into records"), from which a
  framebuffer domain's driver learns its framebuffer.
* [Medium] display, LVGL renderer: replace LVGL on panels with the Erlang
  renderer once the parity test passes and the Erlang renderer's frame
  times match LVGL's on a 240x240 panel
  ([design-display.md](design-display.md#dependencies)). It blocks
  no release: 0.2 ships LVGL under its release contract
  ([design-display.md](design-display.md#lvgls-release-contract)).

## Bugs by subsystem

* [Low] display, a display domain learns the name of the display it serves from the
  `display=` word the domain library writes into its environment from its display record
  (`liberx/system/dom_core.c`), a second route beside the `-erx_serves` declaration every
  domain gets ([design-system.md](design-system.md#facets-a-configured-domain-serves), "The
  declaration"). Take the name from the declaration and keep only the record's policy,
  idle times and palette in the environment, so a served service's name has one route.
* [Low] display, a window opened where no connection agent runs answers `noproc`, which is no
  errno (`erx_win:own/4` passes `erx_area:open/1`'s `{error, noproc}` up through `erx_win:open/2`,
  and `erx_session_export:open_window/1` maps only `none` to `ENODEV`): a program's first open
  of /dev/draw would fail with it. `erx_pixels` answers `none` for every refusal of
  `erx_area:open/1`; the window path should too, in the one place that opens the area.
* [Low] display, "an undef of a module that is not loaded means the domain lacks it" has two
  copies (`erx_prog_handler`'s `absent/3` and `erx_session_export:open_window/1`), and both
  read a beam that fails to load as one that is absent; one helper in `erx`, which both
  applications depend on, could tell them apart by `code:which/1`.
* [Medium] desktop, the glyph step's glyph count (`tools/lib/erx/glyphs.rb`, `erx_draw_core.erl` `?MAX_GLYPHS`):
  `Erx::Glyphs` refuses only at font(7)'s field limits, so it would write a subfont of more than 4096 glyphs, the
  most a font cache holds, which `erx_font:parse/1` then refuses. No spec holds that limit (`abi/formats/draw.txt`
  gives only the messages' layouts), so it is not shared. Make it a fact of the draw format that `tools/gen_abi.rb`
  gives both `erx_draw_core` and the step, and refuse there. The theme's ranges hold 543 code points. The subfont
  format's own field limits, x in two bytes and rows in one, are written twice the same way (`Erx::Glyphs` `MAX_X`
  and `ROW`, `erx_font` `?MAX_W` and `?MAX_H`), and the pair section's limits (an adjustment in a signed byte, a kerned
  advance in 0 to 255, design-desktop-programs "Kerning") need both too: a spec of the subfont format would give both.
* [Medium] display, two splitters of pixels into `y` messages (`erlang/apps/erx_win/src/erx_font.erl` `tiles/3`,
  `erx_draw.erl` `band_rows/2`): `erx_font` cuts an image into tiles of columns and bands of rows of at most 8192
  bytes each, while `erx_draw:load/4` cuts only bands of rows, as many as fit a write (`?ERX_P9_IO_MAX` less the
  header), and refuses a row wider than a write. Make one pure planner of a rectangle's `y`s, its limit taken from
  the write size, that both call.
* [Medium] desktop, a present glyph of zero advance (`tools/lib/erx/glyphs.rb` `place`, design-desktop-programs "The
  glyph step"): width 0 is how a subfont marks a missing glyph, so a glyph whose advance rounds to 0 reads as
  missing too. Inter has U+200B (zero width space) at advance 0, inside the theme's range `2000-206F`, so the
  renderer would draw a replacement box for it. Take the format controls out of the ranges, or decide another mark.
* [Medium] desktop, the glyph step's output enters no runtime build (`build/glyphs`, `tools/lib/erx/erlang_apps.rb`):
  `erx_menu_glyphs.erl` is written beside the subfonts, and nothing compiles it into `erx_display`; the build would
  then need erx-raster and the FreeType pin. Decide how with `erx_wm_menu` (plan 8.15). Its outputs declare
  OFL-1.1 (Inter's glyph data); the release packer attributes a generated `build/` source by its SPDX line with
  erXos's `LICENSE` as the notice and no font-data statement (`tools/lib/erx/pack_provenance.rb` `attribute`), so
  it refuses them until the build that takes them in states them font data with Inter's `LICENSE.txt` as notice.
* [Low] desktop, the glyph step's refusals of a glyph offset beyond a byte or an advance beyond 255 have no test
  (`test/host/glyphs_test.rb`).
* [Low] LVGL, rebuild (`tools/lib/erx/lvgl.rb`, `make_library`): `display/lvgl/Makefile`'s `-MMD` leaves out musl's
  headers, which `library_flags` names with `-isystem`, and `library_directory` is keyed on the flags alone, so a changed
  errno, signal or other musl header leaves `liblvgl.a`'s objects compiled against the old one. Key the objects on
  `BuildMemo.tree_digest` of the sysroot's headers, as `NativeRuntime#sdk_root` and `Libcrypto#configuration_key` do,
  without leaving one directory behind per header change.
* [Medium] `erlang/apps/erx_display/src/erx_winfs.erl`: `start_link/1` given a service starts the single policy with an
  empty configuration; the window policy and its chord come from the display domain's manifest entry
  ([design-display.md](design-display.md#windows-and-the-window-system)).
* [Low] display client, a dropped grant's read (`erlang/apps/erx_win/src/erx_draw_conn.erl`, `handle_info/2`'s
  `dropped` clause): the end of a grant that sent the connection reads forgets them but leaves the one of each file
  already at the display there, so the next read of that file waits until a record answers the dead one, and that
  record goes nowhere. Unreachable while the connection has one grant, which shares its life (`start_window/1`'s
  link); sending the display a flush of each such read makes it hold without the shared life.
* [Low] display, a session's display grant (design-display.md, "The program's input"): a window takes at most two
  of the grant's 64 requests in flight for its input, one for a present and one for a relayed `wctl`, `label` or
  `clipboard` call, so a session whose `windows` quota passes 16 can still fill the grant with ordinary programs and
  make a present answer `emfile`. State the count per window and bound the quota by it, or record the limit.
* [Low] `erlang/apps/erx_display/src/erx_winfs.erl`: `/clipboard` answers size 0 to `getattr`, and `ftruncate` of it fails with
  `EPERM` (no `setattr`); an open with `O_TRUNC` is the one way to empty it.
* [Medium] display, the keepers' heaps (`erlang/apps/erx_display/src/erx_window.erl`,
  `erlang/apps/erx_win/src/erx_draw_conn.erl`): design-files.md ("What waiting holds") has a keeper run under a
  `max_heap_size` its tree sets from its counts, and design-display.md has the display set the window's ("The window
  process") and the draw connection's cover its held reads beside its images ("The program's input"), but names
  neither value, so both start with none. Name each in design-display.md (the window's from its 64 held requests of
  at most 1,024 bytes, its pending input and its last present; the connection's from its 64 held reads and its
  images, whose `erx_memdraw` memory a heap bound may not count, unverified) and set it.
* [Medium] `erlang/apps/erx_display/src/erx_window.erl`: no test covers a flush or a clunk of a `ctl` write whose
  present is in flight (answered with the present's answer, never `EINTR`) or of one waiting behind it (`EINTR`);
  `never_answers/0` in `test/erlang/erx_winfs_tests.erl` holds such a present, with a seeded fault that drops
  `began/2` in `pump/1`.
* [Low] `erlang/apps/erx_display/src/erx_winfs.erl`: the window table carries no label, so a decorating policy cannot
  see it.
* [Low] `erlang/apps/erx_display/src/erx_screen.erl`: a present the core refuses (a rectangle past the coordinate limit
  once the window's origin is added) is answered ok and shows nothing.
* [Low] `erlang/apps/erx_display/src/erx_winfs.erl`: `readdir` offsets are positions, so an `rmdir` between reads can
  skip a window.
* [Low] display, `wctl`'s `current` field (`erlang/apps/erx_display/src/erx_window.erl:101`): the field
  rio defines as whether the window takes the keyboard is filled from whether the window is shown, so
  every shown window reads `current`, and a change of the current window gives no window a new `wctl`
  record. Report the overlapping policy's current window there and send the record on a change;
  find and act's palette needs both to close when another window is picked (the [Medium] find and act item
  under "Planned features").
* [Medium] display client, `erx_pixels` tests: `erx_prog_handler:start/1`'s deadline frees what a
  killed handler reserved through the allocator's handling of a dead owner, which
  `test/erlang/erx_pixels_tests.erl` does not cover: an alloc whose caller has already exited (the
  monitor's immediate `'DOWN'` releases the range), a lend whose caller is killed before the reply
  (`{error, noproc}` from `erx_area:lend/5`, then `owner_down`), and a holder that dies with its lease
  outstanding (`returned/2` and `owner_down/2` in either order).
* [Low] erx_program driver, `erx_program_drv.c`: a frame delivered as `{erx_channel, Port, Frame}`
  is queued with `erts_queue_message` and no `trace_port_send`, so a port traced for sends does not
  show it; trace it as `driver_output_term` does. `end_feed`'s answer to the owner picks the action
  by a list of kinds (THREAD_START, WRITE, BUSY, a STOP's STOP_ANCHOR); have the core name the
  action that answers each input instead. A STOP after the anchor ended answers `einval`, yet the
  program's end later reports the status the image ended with; say in `stop/3`'s doc that a
  refused stop changes nothing, and that STOP carries the session's own kills too.

## Security residuals

* [Low] `erlang/apps/erx_fb/src/erx_fb_sup.erl`: the input drivers count toward the display supervisor's restart
  intensity (3 in 60 s), so an input device that breaks its queue four times a minute ends the display domain.
  A `one_for_one` supervisor of its own for the input drivers would end input alone.
* [Medium] `config/platforms/qemu-virt.json`, `erlang/apps/erx_fb/src/erx_virtio_input.erl`: each input row's
  64 KiB of DMA memory fits its 64 one-event buffers only when the cache granule is small. A review computed that
  with the granule unreported (2048, `erx_device.c`'s pool rounding) `queue_create` needs 128 KiB and fails, so
  the driver starts no process. Both devices come up under HVF; TCG and boards are not checked. Derive the row's
  memory from the queue's needs at the granule the platform reports instead of writing a size by hand.

* [Medium] [The pixel area](design-display.md#the-pixel-area), zero before reuse: an `erx_memdraw:wrap/4` image
  over a range is not tied to the range, so an image handed to a process that outlives the range's owner writes the
  range after its zero and after it is handed out again. The design takes same-client overlap as the client's own
  affair; either tie `wrap/4` over an area to a range `erx_pixels` issued or state the limit in the design.
* [Medium] `display/memdraw/` and `display/libmemdraw/`, the shapes, G3: a shape's cost follows from its geometry,
  not from the pixels it writes, and every shape runs on the display domain's one pool of dirty CPU schedulers, so
  one client can delay every other's dirty work (composes included). A very thick, skinny ellipse is brushed with
  a disc of up to (2*2^10+1)^2 pixels at each of up to about 2^16 steps, minutes of one scheduler; a `p` of
  thickness 2^10 builds two 2049 by 2049 brushes a vertex; a disc end's brush (up to 2049 by 2049 bits) is
  allocated from the domain's heap and not charged to the window's quota. Bound the work a shape may do (steps
  times the brush's area, vertices times brushes) and refuse past it, or charge it to the window's grant; cache
  the brush in the thread's shape record.
* [Medium] display, layout work in `erx_screen`
  ([G3](design-display.md#the-screen-and-its-one-path-to-the-device)):
  `erx_screen_core:layout/2` costs O(L^2 log L) for L window and decoration
  rectangles across every grant on the display, and runs in `erx_screen`, not
  in the client's window processes, so a client that moves its windows with
  `wctl` spends shared time that its grant does not bound. A weave of 64
  windows with four border rectangles each (about 4,300 tiles) costs about
  90 ms per move, 128 windows about 430 ms, 256 about 2 s (Homebrew OTP 28
  JIT on the Apple Silicon development host, 4096x4096 screen; an
  unrecorded spot measurement). `erx_screen` keeps only the newest pending
  layout, so layouts cost at most one per frame; cap the rectangles of a
  layout or charge them to the grant that placed them.
  `flush/4` also costs a window's visible tiles times its 16 dirty
  rectangles.


## Planned features

* [Low] display, `erx_ui:open/1` falls back to the session's only display
  ([design-display.md](design-display.md#choosing-a-display)): when `Options` and the
  `display` variable name none, open on the one display the session holds where it holds exactly
  one, as a program's handler does at its first open of `/dev/draw`, instead of answering
  `{error, no_display}`. A separate change with its own design edit and tests.
* [Medium] find and act, changes its design needs in other designs ([design-find-act.md](design-find-act.md)),
  not yet made in them:
  * The inspection schema: a segment type `app_name` for `apps *app_name`, marked `present app`.
  * design-shell: `service` declares `-erx_args([app])`; commands that take a pid, a domain or another
    presentation first declare it, so the Services offers find them. The variables a session's shell starts
    with, `$home` among them, are one value both the shell and `erx_act_run` start from (the [Medium] shell item
    on `$home`). A job whose evaluator a session process other than a terminal's shell starts with
    `erx_job:spawn/1`, an act, is ended as any job is and listed by no terminal's `jobs`.
  * design-files: narrowing for a program refuses, with `EACCES`, a writable root that lies within the session's
    `lib` directory or contains it, judged on the root's path on its grant; the same holds for a command domain
    that `within` narrows.
  * design-apps: which sessions may read the start table's row names in a release build (the [Medium] item on
    `[apps]` below).
* [Low] display theme, transitions (`abi/theme.txt`): the theme has no `transition` rows and no `ui_transition`
  set, which [design-desktop-programs.md](design-desktop-programs.md#the-theme-one-declaration) and
  [design-abi.md](design-abi.md#theme) declare (`press` 120 ms, `state` 160 ms, `reveal` 200 ms, each
  `ease_out`), nor the generator's check of them.
* [Low] find and act, rules written by a program given the whole namespace
  ([design-find-act.md](design-find-act.md#security)): such a program holds the session's files but
  no right beyond files unless `within -f` names one, yet a binding or route it writes to
  `$home/lib/act` runs with the session's rights once `erx_act` reads it. A narrowed program cannot
  write the file. Closing it needs a home for the rules that no program's namespace holds, as
  crontab(1) keeps a user's table, which no design names; `rc.conf` has the same gap.
* [Low] find and act, a covered palette ([design-find-act.md](design-find-act.md#security)): a
  client may raise a window of its own over the current palette with `wctl` `top`, which leaves the
  keyboard with the palette, so a person typing into what looks like the raised window types into
  the palette and a Return runs its selected offer. The reserved chord's overlay is the planned way to
  tell windows apart; a rule that a covered current window takes no Return is the cheaper fix if one is
  needed first.
* [Low] `erx-lvgl` (`display/lvgl/erx_lvgl.c`, `text_style`): a node with no `role` shows body's font (LVGL's
  default, `lv_conf.h`) but LVGL's own colour, while ui.txt makes `body` the default, which an explicit `role => body` shows in the theme's
  `text` colour; applying `body` to every node that takes a role means re-recording the LVGL references.

* [Low] `erx-lvgl` (`display/lvgl/erx_lvgl.c`): `icon` is not drawn.
* [Medium] `erx-lvgl` (`tools/lib/erx/lvgl.rb`, `Lvgl::Program::NOTICES` and `LICENSE`): the archive's font
  notice (`display/fonts/inter/LICENSE.txt`) and its OFL-1.1 are written by hand, while `abi/theme.txt` names
  the fonts and their `ORIGIN.md` rows the license (`Glyphs.font_notice` reads both); a theme font in another
  directory or under another license would ship under Inter's notice. Derive both from the glyph step that
  built the archive and hand them to `ProductionImage.toolkit_parts` with the program.
* [Low] glyph step (`Glyphs.ensure`, `display/lvgl/Makefile`): the output's lock covers the write, not the
  make that compiles the fonts after it, so a writer that changes `build/glyphs` while another build compiles
  from it can leave an object newer than its new source; hold the lock shared around the make.
* [Low] `erx-lvgl` (`display/lvgl/erx_lvgl.c`, `CHECK_MARK`, `LIST_ARROW`): the checkbox mark U+2713 and the
  drop-down arrow U+2193 must lie in the theme's range and in its font, which nothing checks and no test
  draws; a missing one shows LVGL's placeholder box.

* [Low] desktop, a graphical editor: the desktop's editor is Emacs, a larger task than the desktop
  programs of [design-desktop-programs.md](design-desktop-programs.md); until it lands, text is
  edited with `vi` in a terminal ([design-vi.md](design-vi.md)). It needs its own design: an Emacs written in
  Erlang, or GNU Emacs or a BSD-licensed Emacs ported, with the license question settled first.

* [Medium] desktop, the shadow's placement in one place: `erx_mask` makes a shadow's four corners
  and four strips, but where each is drawn (the corners Blur pixels outside the rectangle's corners,
  the strips between them with the replicate bit, the rectangle at least 2 (R + Blur) on each side)
  is prose in its moduledoc that the Erlang renderer and the display domain's menu would each encode.
  An `erx_mask` function from the rectangle, radius and blur to the parts and their places would be
  the one source; the theme's generator checks that `shadow`'s offset is at most its blur
  ([design-desktop-programs.md](design-desktop-programs.md#anti-aliasing-corners-and-depth-coverage-masks)).

* [Medium] display and desktop, the UI survey's decisions as designed but not built
  ([research-ui-synthesis.md](research-ui-synthesis.md), section 8): `ctl`'s read with the last present's report with `TAKEN` and `SHOWN` apart, from the drivers' `flushed()`
  answers and `info/1`'s `period`, and `erx_win:report/1`
  ([design-display.md](design-display.md#the-window-tree)); the clipboard served only through the
  keyboard window's grant within `windows_clipboard_ms` of a key or button there, a copy replacing the
  clipboard whole at its close, and the manifest check's refusal of `clipboard` for a configured domain on a `single` display;
  `erx_input`'s "seen before pressed" on every gesture's first down, from the displayed windows, with
  `erx_screen`'s `{shown, D}` carrying each window's time of the last frame in which it gained pixels
  ([design-display.md](design-display.md#the-input-router)); `erx_png` reading the
  colour-space chunks as sRGB; the theme's sizes as
  logical pixels at the window's scale. Each is small and lands with the next change to its module.
  Transitions ([Motion](design-desktop-programs.md#motion)) come after the basic desktop runs,
  widgets first; window transitions wait for a Raspberry Pi measurement of a moving window. The trusted
  overlay on the reserved chord and the `windows` grant's `principal` come with the login design, and
  the window tree's inspection path with its first reader, carrying `erx_ui_model:public/1`'s tree under
  the visibility class `display`, with the `inspect` grant's `principal` beside its scope
  ([design-live.md](design-live.md#inspection)).

* [Medium] desktop, the display's palette beyond `erx-lvgl` ([design-desktop-programs.md](design-desktop-programs.md#colour)):
  a display's manifest entry chooses its palette, which reaches `erx_fb_sup`, every window's `ctl` and
  `erx-lvgl` and `erx_screen`, but two drawers keep the light one. `erx_wm_rio`'s borders take
  `erx_theme:color(light, ...)` and want the palette in the window manager's configuration from `erx_fb_sup`;
  and the dashboard's clock (`examples/dashboard`, `erx_dashboard.erl`
  `?PALETTE`) draws in the light palette because `erx_ui` does not answer the palette of the window it
  opened, which `erx_win:info/1` holds. Reference pictures in the dark palette come with the first program
  that runs in it.

* [Medium] desktop, the release of `erx_desk` (`tools/lib/erx/release_files.rb`, `RELEASE_SCRIPTS`):
  design-desktop-programs.md ("Shipping and starting") puts `erx_desk` in the desktop session's release, and
  `erx_desk_files_core` calls `erx_ui_schema`, so `erx_desk` names `erx_ui` in its
  `applications`. Only the client script, a domain holding a display's grant, holds `erx_ui`, so `erx_desk` ships
  there and not in the session script, where systools would refuse the boot script. Settle which script a desktop
  session boots: the client script, or the session script with `erx_memdraw`, `erx_win` and `erx_ui` added. Until
  then the command `clock` (`erx_desk_cmd_clock`) is in no command namespace, since every shell builds its table
  from `erx_shell` alone (`erx_shell_namespace:from_applications([erx_shell])` in `erx_session_sup`,
  `erx_shell_runner` and `erx_shell_script`), and it names no `-behaviour(erx_cmd)`, which would make `erx_desk`
  build after `erx_shell`. 8.4's QEMU cell, `clock` opened in the desktop session, waits on this.
* [Medium] desktop, clock's dimmed reading ([design-desktop-programs.md](design-desktop-programs.md#clock),
  the state table and D3): a state that is not `ok` asks for the time and date in the `tertiary` colour, which
  `abi/formats/ui.txt` cannot express; clock shows them in their roles with the status token beside the zone.
* [Low] desktop, stats (`erlang/apps/erx_desk/src/erx_desk_stats_core.erl`,
  [design-desktop-programs.md](design-desktop-programs.md#what-it-reads)): `abi/inspection.txt` declares no
  `[domains, Id, connections]` path, so the inspector answers it `{error, scope}`, as for a path that names
  nothing, and every domain's frames show that error. Declared with no collector, it answers `unsupported`, as
  the design says. The core reads that record's `frames` attribute, a count of frames accepted on each lane;
  design-live puts the per-lane counts on `[domains, Id, connections, Peer]`, so the declaration settles which
  record stats reads.
* [Medium] desktop, stats (`erlang/apps/erx_desk/src/erx_desk_stats_core.erl`, `domains/3`): a partial domain
  listing keeps the rows it does not name and never asks for them again, and the inspector's listing stays
  partial while there are more domains than a page, so a domain that ends unlisted keeps an `unknown` row and its
  rings for the window's life. Asking `[domains, Id]` for each kept row would let its `{error, scope}` end it.
* [Low] desktop, stats (`erx_desk_stats_core.erl`, `machine/4`): a machine record whose `memory_free` exceeds
  `memory_total`, two reporters apart, gives a negative used share instead of a gap.
