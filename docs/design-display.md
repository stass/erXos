# The display: windows, buffers, renderers and presentations

A display is a domain that holds a display device and the input devices
that go with it, and does two things for the rest of the system: it
composes **windows** onto the screen and routes input to them, as rio or
an X server does. A window is a directory of files and a rectangle of
pixels, and its pixels are a **buffer**: memory that its client writes
and the display only reads. Everything that makes pixels runs in the
client's own session, with that session's authority and on its budget: a
program that draws with Plan 9's draw protocol, a terminal, and an Erlang
application that describes a user interface as a term and receives events
as messages, whose widgets a renderer of that same session lays out and
draws. The display domain parses no draw message and no widget tree and
runs no client's renderer. It takes one command about pixels from a
client, `present`, which names a buffer and the rectangles of it that
changed. One display serves a desktop with overlapping windows under QEMU
`virt`, and one serves a kiosk, a dashboard or a pair of smart glasses
with a single full-screen window, a touch panel, an encoder or a keypad,
and a small panel on a serial bus: the same domain, the same files and
the same clients, under a different window policy. A kiosk's application
is an application like any other, a program of a session that holds a
grant on the display.
The architecture is [design.md](design.md); drivers and the device shim
are [design-system.md](design-system.md#drivers) and
[design-runtime.md](design-runtime.md#the-device-nif); namespaces, grants
and the `erx_fs` behaviour are [design-files.md](design-files.md);
connections between domains are
[design-domains.md](design-domains.md#connections); programs as ports of
their session are [design-programs.md](design-programs.md); the tty,
attributed text, the inspector and the console are
[design-live.md](design-live.md); the command shell and its records are
[design-shell.md](design-shell.md); the browser as a medium is
[design-web.md](design-web.md).

Decisions every reader of this document needs:

* **A display is a domain, and a window is a directory of files.** The
  display domain holds its display and input devices, by the manifest,
  and serves an `erx_fs` tree in which each window is a directory holding
  `ctl`, `mouse`, `kbd`, `wctl` and `label`. A client domain reaches the
  tree through a grant rooted at its own directory, so it makes, shows
  and reads only its own windows, by construction. That grant is all a
  client holds of a display: the display serves no other interface.
* **A window's pixels are a buffer its client writes.** The connection
  between a client's domain and a display carries a **pixel area**: one
  memory object that the system domain makes with the connection, that
  the client alone writes and that the display maps read-only. A buffer
  is a range of the area laid out as an image. The client draws there by
  whatever means it has, and the display copies what changed to the
  screen or has the device read the buffer itself. No pixel travels in a
  message.
* **One command, whose answer is the fence.** A client writes `present`
  to its window's `ctl` with the buffer and at most 16 rectangles that
  changed. The display answers when the device has taken the frame that
  shows them. From that answer on the display reads that buffer of the
  window and no other, so the one answer releases the buffer presented
  before, paces the client to the device and holds each window to one
  present in flight.
* **Rendering is the client's.** The draw protocol's executor, the
  widget toolkit and every renderer are libraries and programs of the
  client's session. The display holds no image of a client, renders no
  text and decodes no picture.
* **The draw protocol is Plan 9's, served by the session.** A program
  writes the messages of Plan 9's draw(3) to `/dev/draw`, and its
  session's **draw connection** executes them with the per-byte
  primitives of `libmemdraw` into images of the session, the window's
  buffer among them, as plan9port's `devdraw` does beside each client.
  There are no named images, no screens and no layers, so the mechanism
  by which one Plan 9 client reaches another's image does not exist.
* **One window system, two policies.** The window system owns the screen
  and decides each window's rectangle and visibility. The **overlapping**
  policy is rio's: windows made and moved by the user, borders, a menu.
  The **single** policy shows exactly one window, full-screen, and keeps
  every other hidden, for a kiosk or a pair of glasses. A policy decides
  geometry and which window takes each input event, and nothing else;
  buffers, input formats and clients are the same under both.
* **A kiosk is an app on a display with the single policy.** A kiosk's
  application is an app ([design-apps.md](design-apps.md)): it runs in
  a session of its own principal, with its session template's grants,
  the display's among them, and opens its window as any client does.
  What starts it at boot is the start table, the one place
  that says what starts without a person: a **start row** that names the
  app and the display ([design-apps.md](design-apps.md#the-start-table),
  [Boot](design-system.md#boot), step 5). The session that row starts
  is the **display's session**, and the single policy shows that
  session's window and no other. So putting an application on a kiosk
  is declaring the app and enabling its row: the display's manifest
  entry names the display and its policy, and no application and no
  renderer, and an app of the manifest and one added at run time
  later reach the display the same way. Nothing of the app runs in the
  display domain, and no part of the display is special to it.
* **A terminal is a program of its session.** A user's terminal,
  `erx_term`, is a supervised Erlang process in the user's session
  domain: it makes its window through the session's grant, draws its
  cells with a glyph cache of its own, and is the master of a tty that
  the session's terminal relay serves, as xterm is a client of X and the
  master of a pseudo-terminal. The display has no authority to start a
  program in a session, so the display's menu has no item that opens a
  terminal; a terminal opens its sibling windows itself. The system
  shell is reached only at the UART and the host link.
* **A user interface is a term, and events are messages.** An
  application hands the widget toolkit, a library in its own runtime,
  the whole widget tree of a window whenever its state changes; the
  window's widget server, a process of that runtime, keeps the realised
  tree, computes the difference, hands it to a renderer that lays it out
  and draws it, and sends the application `{ui, Window, Term, Detail}`
  messages. The application holds no widget handles and issues no widget
  commands, and no tree crosses a domain boundary.
* **Three renderers behind one interface, all in the application's
  session.** The widget server's rendering is a behaviour,
  `erx_ui_renderer`. The Erlang renderer lays out and draws into the
  window's buffer. LVGL, a C widget library, renders behind the same
  behaviour as `erx-lvgl`, an ordinary native program of the session,
  for panels where its mature widgets and fonts pay: it runs in a
  sub-space that holds its pipes and its window's buffer, draws into
  that buffer and reports the rectangles it changed. It is a stopgap,
  replaced by the Erlang renderer once that renderer matches it on the
  kiosk's widget set and frame times. The browser renderer hands the
  session's web line the tree's changes
  ([design-web.md](design-web.md#uis-the-browser-renderer)). Every
  renderer renders the tree as fits its medium: the tree states what the
  widgets are, their values and their events, not their appearance, and
  renderers are compared on those, never on pixels or layout.
* **Composition is a plan.** The screen owner's decisions are a pure
  function of the windows' rectangles, their buffers and what the driver
  reports of its device: which pixel comes from which window, and by
  which path it reaches the panel, a copy into the screen image or the
  device reading the client's buffer. A graphics device added later, a
  2D engine, a plane compositor or a 3D GPU, adds a buffer source or a
  composition path ([Graphics hardware](#graphics-hardware)); no client
  and no policy changes.
* **A presentation is a type and a canonical text, and grants nothing.**
  Every value the inspector and the Erlang shell's printers emit already
  carries its type from the inspection schema. Its text is the form the shell parses back
  to the same value, so a plain terminal loses the mouse and nothing
  else. At a terminal the renderer wraps the text in a hyperlink escape
  sequence naming the type and the value; in a widget tree a value is a
  `present` property. Selecting a presentation inserts its text into the
  command line or sends the application a message; whatever runs then runs
  through the ordinary command path with the actor's own capabilities. A
  pid on the screen is a name, as everywhere in erXos.
* **The display domain is trusted by the people who use it.** It sees
  every pixel its clients present and every key typed at it, as an X
  server does. It holds no capability beyond its devices, its own grants,
  the grants it serves and its read-only mappings of its clients' pixel
  areas, and no unconfined DMA device in a release build, so it isolates
  nothing between other domains and is trusted only for the
  confidentiality of what is shown and typed at that display.
* **The display domain parses no client's content.** What it reads of a
  client is the file protocol's terms, one line of text on `ctl` or
  `wctl`, a label, and pixels, which it copies and never interprets. The
  draw decoder, the `Y` decoder, the PNG reader with its inflate, the
  fonts and the widget schema all run in the client's session, where a
  fault costs that session and no other. Native code of unknown
  provenance, LVGL among it, runs in a sub-space of the session that
  uses it.
* **Nothing paints without a change.** Every byte that reaches a panel
  follows from a client's present of a changed rectangle or from a change
  of the windows' geometry. No timer redraws, so an idle display costs no
  CPU and a panel can sleep.

## Context

The system is reachable as text from the serial console and the host
link ([design-live.md](design-live.md)). A display adds a screen, a
pointer, a keyboard and, on the boards, touch panels, encoders and
keypads. Three kinds of use ask for it:

* a desktop on QEMU `virt` and the Raspberry Pi, where plan9port's acme,
  sam and 9term and erXos's own inspector windows run beside terminal
  windows;
* a kiosk or a dashboard: one full-screen application, touch input, a
  machine that runs unattended;
* smart glasses and similar small devices: a panel of a few hundred
  pixels on a serial bus, an encoder or a keypad, a battery, so the
  display must sleep when nothing changes.

Plan 9 and Inferno show the shape of the client's side. Plan 9's
`/dev/draw` is a small command protocol over a file, its pixel work is
`libmemdraw`, and rio gives each program its window as files bound into
its namespace, so graphics need no new kind of object. Inferno's Tk takes
widget commands from a program and returns events on a channel, and its
window manager is library code. Genera's dynamic windows keep displayed
output bound to the object it presents, so a command that wants an
argument of a type can take any presentation of that type on the screen.
erXos keeps the three ideas and removes what each system's weaker
isolation allowed: Plan 9's named images and shared screens, Tk's string
commands, and Genera's single address space, in which a presentation was
the object.

Three later systems show the shape of the display's side. All three put
rendering in the client and leave the display server a composer of
finished buffers:

| System | What it does | What erXos takes |
| --- | --- | --- |
| QNX Screen | each application renders into its window's buffers, in software or through a GPU, and posts a buffer with its dirty rectangles; Screen puts windows on the display controller's hardware layers where it has them and blits the rest; the window manager is one more client, and a kiosk is an application with a full-screen window | the client renders and posts dirty rectangles; composition uses the device's own layers where they exist; a kiosk is not a different system |
| Wayland | a surface's state, its buffer and its damage, is applied atomically at `commit`; buffers are shared memory or GPU buffers passed by handle; the compositor tells the client when it has stopped reading a buffer (`release`) and when to draw the next frame (the frame callback), and may scan a client's buffer out directly or put it on a hardware plane without the client knowing | one atomic present with damage; a release and a frame signal; direct scanout as an optimisation the client cannot observe |
| Fuchsia | sysmem allocates each buffer from the constraints of every party that will touch it; Flatland takes a client's rectangular images and presents them atomically, one credit per frame, with a fence that says when the last image is free; the display coordinator checks a proposed set of layers against the display driver and applies it, and composes on the GPU whatever the hardware refuses; Magma keeps a GPU's hardware in one driver process and builds its command buffers in the client | the allocator is the party that knows every constraint; one present in flight; composition as a plan checked against the device before it is applied; a GPU's hardware in one domain and its command building in the client |

erXos takes these rules and none of the three protocols, since its own
mechanisms already carry each: the system domain makes every page two
domains share, so it is the allocator; a file with a `ctl` is how a
client commands a server; and a request's answer is a signal that needs
no object of its own. Plan 9's own port to other systems made the same
cut: plan9port runs the draw protocol in a `devdraw` process beside each
client and hands the host's window system finished pixels.

What the hardware offers: QEMU `virt` has virtio-gpu in its 2D mode
(create a resource, attach guest memory as its backing, transfer a
rectangle to the host, set the scanout, flush a rectangle) and
virtio-input for a keyboard, a mouse and a tablet; a Raspberry Pi has
the framebuffer its firmware sets up, a range of memory the display
scans out; a small device has a panel on a serial bus that takes
rectangles of pixels. None of these draws, so rendering is software.
Hardware that composes or draws, the Raspberry Pi's plane compositor and
its 3D GPU, virtio-gpu's 3D modes and 2D engines such as TES's D/AVE 2D,
is not driven by this design, which says where each attaches
([Graphics hardware](#graphics-hardware)).

## Requirements

1. A program in a session draws into a window and reads its pointer and
   keyboard through files in its namespace, with Plan 9's draw(3)
   messages and Plan 9's input record formats, so plan9port's programs
   port with their draw library's connection code replaced and nothing
   else.
2. A program reaches only the window it was given, whatever it writes.
3. An Erlang application describes its interface as a term and receives
   events as messages, in any domain that holds a grant on a display or
   a web line, with no widget handles and no imperative widget commands.
4. The same application term renders through the Erlang renderer on a
   desktop, through LVGL on a kiosk and through the browser renderer on
   the web, with the same values and the same events, each as fits its
   medium.
5. A session's shell runs in a terminal window over a tty of its own
   session, unchanged: job control, the line editor and `termios` behave
   as on the serial console, and the window shows that tty and nothing
   else, as xterm does.
6. Typed output of the shell and the inspector stays bound to its value
   in a terminal window and in widgets, degrades to re-parseable text on
   a plain terminal and over the host link, and grants nothing when
   selected.
7. A kiosk boots into one full-screen application, takes touch, encoder
   and keypad input, redraws only what changed, and turns its panel off
   when idle. Its application is an app like any other, started at
   boot by a start row: it runs with its app's authority and a grant on
   the display, no code of it or of its renderer runs in the display
   domain, and when its session ends a new one takes its place. Which
   application a display shows is its start row's to say, the
   manifest's default or the machine's own setting in `rc.conf`, with
   no change to the display's entry or the display domain, and while
   the app's session or the display domain restarts no other client
   takes the screen.
8. Text labelled with its source (a window's label, a value shown in a
   widget, a record in a terminal) is escaped by its displayer; a
   program's own output reaches a terminal window's tty unchanged.
9. What a client can make the display domain spend, in memory and in
   CPU, is bounded by its grant.
10. A client's crash, a window's end, a crash of any process of the
    display domain and a reset of the display device each lose at most
    what that party owned, and the rest redraws.
11. Every parser of input from another domain, from a program or from a
    device has a fuzz target; every "only X does Y" rule is a build
    check.
12. Drivers are Erlang processes over the device shim; the pixel work is
    per-byte C; nothing else of the display stack is native, apart from
    LVGL as a stopgap renderer.
13. An application chooses by name which of its displays a UI opens on,
    with a default its session sets; with no display it gets a stated
    error at once, and when a display goes away each UI on it reports its
    end to its opener.
14. The display domain composes windows and routes input, and does no
    more for any client: it parses no program's output, no draw message
    and no widget tree, holds no console line and starts no program in a
    session.
15. A changed pixel is copied at most once between the client's
    renderer and the device, and not at all where the device can read
    the client's buffer.
16. A graphics device added later adds a buffer source or a composition
    path. It changes no file a client uses, no command, no policy and no
    renderer's interface.

## Overview

```text
 session domain (the client)                  display domain
+----------------------------------------+   +----------------------------------------+
| application --tree--> erx_ui_server    |   | erx_winfs (erx_fs): /S/N/{ctl,mouse,   |
|   <--{ui,...}--   its renderer:        |   |   kbd,wctl,label}, /S/snarf; the       |
|     erx_ui_erlang    draws             |   |   window table, erx_wm's policy,       |
|     erx_ui_lvgl <-pipes-> erx-lvgl     |   |   input routing, the reserved chord    |
|     erx_ui_browser --> the web line    |   | erx_window: one process per window:    |
| program --/dev/draw--> erx_draw_conn   |   |   its last present, its pending input  |
| erx_term: erx_vt, its glyphs, a tty    |   | erx_screen: reads buffers, writes the  |
|          each draws into its buffer    |   |   screen image, the only path to the   |
|   +--------------------------------+   |   |   driver; erx_screen_core plans        |
|   | pixel area: the windows'       |===mapped read-only==>                          |
|   |   buffers                      |   |   | erx_wm_menu: the overlapping menu      |
|   +--------------------------------+   |   | drivers: display, pointer, keyboard,   |
| erx_win --present, wctl, label------------>|   touch, encoder, keypad               |
|         <--mouse, kbd----------------------|                                        |
+----------------------------------------+   +----------------------------------------+
   the system domain makes the pixel area with the connection and deletes it with it
```

A **display domain** is a configured domain of the manifest holding one
display device and its input devices. Its release runs the display
driver, the input drivers, the window file server `erx_winfs`, one window
process `erx_window` per window, the screen owner `erx_screen` and the
overlapping policy's menu. It runs no terminal, no widget, no renderer
and no program of a session, and it has no sub-space.

A **window** is a directory a client makes with `mkdir` in a directory
of a grant it holds. It is one process, `erx_window`, which holds the
window's last present and its pending input. Its files are the control
file `ctl`, the input files `mouse` and `kbd`, the geometry file `wctl`
and the title `label`.

A **buffer** is where a window's pixels are: a range of the client's
**pixel area**, laid out as `libmemdraw` lays out an image of the
window's size in the display's channel. The pixel area is one memory
object of the connection between the client's domain and the display's,
sized by the client's grant, written by the client alone and mapped
read-only by the display ([The pixel area](#the-pixel-area)). The client
chooses where in its area each buffer lies.

**Presenting** is the one thing a client tells the display about pixels:
a line on the window's `ctl` naming the buffer and the rectangles that
changed. `erx_screen` copies those rectangles, clipped to the part of
the window the policy leaves visible, from the buffer into the screen
image and hands the driver the rectangles to push; where one window
covers the screen and the device can read the client's memory, the
driver pushes from the buffer itself and nothing is copied. The answer
to the write comes when the device has taken the frame.

**Drawing** is the client's. The session's libraries all end at a
buffer: `erx_draw` and its draw connection execute Plan 9's draw
messages with `erx_memdraw`, a NIF around the per-byte primitives of
Plan 9's `libmemdraw`, into images the session owns, of which image 0 is
an image over the window's buffer; a program's write to `/dev/draw`
reaches the same connection. The terminal and the Erlang widget renderer
draw through `erx_draw`. The LVGL program has its window's buffer mapped
into its sub-space and draws there itself.

**Widgets** are a retained tree in a widget server, one per window that
an application opens, in the application's own runtime. The application
hands it trees; the server diffs and hands the operations to a renderer
behaviour, which lays out, draws and reads input, and the server sends
events. The Erlang renderer draws into its window's buffer and reads the
window's `mouse` and `kbd`; the LVGL renderer is a native program of the
session that receives the same difference operations and the input on
its standard input, draws into the buffer mapped into it and reports
events and changed rectangles on its standard output, which
`erx_ui_lvgl` presents; the browser renderer hands the operations to the
session's web line.

**A kiosk** is this same arrangement under the single policy: a start
row names an app and the display, its keeper starts the app's session
at boot, the session boots the app's release, which starts the
application, and the application's one window covers the screen ([Kiosks and
glasses](#kiosks-and-glasses)).

**Terminals** are programs of a session. `erx_term`, in the session's
runtime, makes a window as any client does, draws its tty's bytes as a
terminal does and sends the tty the keys typed in its window. It parses
one escape sequence of its own, the presentation link, and binds the
linked text to its type and value. The display domain sees the terminal
as pixels and routes it keys, and nothing more.

**Presentations** are the values of inspection attributes,
typed by the inspection schema. `erx_render` writes each as its canonical
text at a terminal, inside a link when the terminal declares it
understands links; widgets take a value as a `present` property. A
selection puts text where the user is typing, or tells the application;
the shell and the application act with their own capabilities.

What runs where:

| Party | Holds | Runs |
| --- | --- | --- |
| the display domain | the display and input devices; each client's pixel area, read-only; the screen image | `erx_winfs`, `erx_window`, `erx_screen` with `erx_screen_core`, the policies `erx_wm_rio` and `erx_wm_single`, `erx_wm_menu`, the drivers, and `erx_memdraw` for the copy between images |
| a client's domain, a session or a configured domain | a grant on the display's window tree; its pixel area, writable; its own images, fonts and trees | `erx_win`; `erx_draw`, its draw connections and `erx_memdraw`; `erx_term` with `erx_vt`; `erx_ui` with its widget servers and renderers; its programs, `erx-lvgl` among them |
| the system domain | the right to delete the pixel area | the domain library, which makes the area in the connection's plan and deletes it with the connection |

The modules are four Erlang applications, and a release takes each
whole. `erx_memdraw`, the pixel primitives with `erx_chan`, the one reader of a
channel descriptor and the one formula for a buffer's stride, is a library application
both sides take. `erx_display` holds the display side: the driver
behaviour, `erx_winfs`, `erx_window`, `erx_winctl`, `erx_screen` with
its core, the policies with `erx_wm_menu`, and `erx_wctl`; the drivers'
application `erx_fb`, which depends on it, starts `erx_screen` behind
the driver, so no screen runs before a driver. `erx_win` holds a
client's side: the module `erx_win` of the same name with its core
`erx_win_core`, the reader of what the display answers, `erx_pixels` with
its core, `erx_draw` with `erx_draw_conn`, the draw codec and core and
`erx_draw_image`, `erx_font`, and `erx_term` with `erx_vt` and its
width table; its application starts `erx_pixels`. `erx_ui` holds the
widget toolkit ([The widget server](#the-widget-server)): the client
library `erx_ui` of the same name, the toolkit's supervisor
`erx_ui_sup`, which its application starts, `erx_ui_server`, the
renderer behaviour `erx_ui_renderer` and the renderers, the widget model
`erx_ui_model`, and the widget format's generated validator
`erx_ui_schema` and codec `erx_ui_wire`. The display domain's boot
script takes `erx_memdraw`, `erx_display` and `erx_fb`, a client's takes
`erx_memdraw`, `erx_win` and `erx_ui`, and the system release takes
neither side, so what the display domain's boot script loads holds no
module of `erx_win` or `erx_ui`, and the G9 check, which reads every
application that script boots, `erx` and `erx_files` among them,
refuses a client module placed outside them by mistake. One name of a
client module is allowed on the display side: a program's handler, in
`erx`, calls `erx_pixels` to allocate and lend the window buffer it maps
into its program, since that buffer is the handler's ([The pixel
area](#the-pixel-area)). In a domain whose release lacks the allocator,
the display domain's among them, the handler refuses a buffer with
`ENODEV`, so the name loads no client module there; the check allows
that one module that one name and refuses it in any other.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **G1.** A client reaches only its own windows' pixels and input | a client's pixels lie in its own pixel area, which only that client's domain writes and only the display maps, read-only: the display maps no client's area into another domain and writes no pixel into any client's memory, so no path carries one client's pixels to another; a `present` names a range of the presenter's own area and is checked against that area's size, so it cannot name another client's memory; a window's files are a grant rooted at the client's directory of `erx_winfs`; a program is given a mapping of its own window's buffer and fids on its own window's directory, never the area or the grant ([Narrowing](design-files.md#narrowing-for-a-program)); a draw connection names images by ids it allocated and by image 0, its window, and the protocol has no message that names another connection's image; the router delivers each input event to one window: the policy chooses it for what starts something, what follows a down goes only to the window that got the down, and a window that has since been hidden receives of that only the ups ([The input router](#the-input-router)); under the single policy only the one shown window is chosen | an area mapped into a second client; a present checked against another grant's area; a program handed its session's whole area; a draw message that names or attaches to another connection's image; a grant rooted above the client's directory; a down, a repeat or a pointer move delivered to a hidden window | a client that presents every offset and size at and past the ends of its area, each one outside refused with `EINVAL` and nothing shown; two sessions whose grants list only their own windows; a program given one window that walks `..` and sibling names and reaches nothing, and whose writes outside its buffer's mapping fault in its own sub-space; a draw connection that sends every message type with every id of another connection, each refused with `ENOENT`; under the single policy with a second window of the named session and a window of another domain made, each of the two is hidden, its `kbd` receives nothing and its `wctl` write of `show` fails with `EINVAL`, where a seeded delivery to a hidden window fails it; when the shown window ends, the session's second window is shown and the other domain's stays hidden, and when that ends too the screen holds only the background until the session makes another, where a seeded policy that shows the most recent window or any domain's window fails it |
| **G2.** Every image has one writer, no reader faults or leaves its image, and every pixel loop runs over a clipped rectangle | the screen image is written only by `erx_screen`; a client's buffer is written only by the client's domain, and in the display domain is read only by `erx_screen` and by the driver while a frame `erx_screen` handed it is outstanding, during which `erx_screen` writes no image of that frame; the display's mapping of an area is read-only, and the area is deleted only after the display has unmapped it ([The pixel area](#the-pixel-area)), so a read of it never faults, whatever the client does or however it ends; a buffer's size and layout are the display's own record, made from a checked `present`, and nothing of them is read from the area, so a client that writes while the display reads changes pixels of its own window and nothing else; an image is a NIF resource, freed by its destructor when no term refers to it, and `erx_memdraw` has no other free, so a window's end, a resize and an `f` drop a reference and never free memory another process holds; an image over an area keeps the area mapped while it lives; only `erx_memdraw:wrap/4` makes an image over memory it did not allocate, and it checks the range against the memory's size with checked arithmetic; every pixel loop of `erx_memdraw` walks a rectangle one of its checkers produced: a draw, the `erx_clip_t` that only `erx_draw_clip` produces from the operation's rectangles and the images' bounds; a load or read, a rectangle `rows_of` checked inside its image; an allocation's fill and a snapshot, the whole image `badrect` admitted | a second writer of the screen image; a read of a buffer whose area has been unmapped; a layout field read from the area; an explicit free of an image; an image over a range that passes its memory's end; a loop over an unclipped rectangle | the build checks over `erx_memdraw`'s sources and the call direction (Chokepoints); the differential test against the reference renderer with rectangles far outside every image; the display suite in hosted mode under ThreadSanitizer and ASan, with clients drawing, presenting, resizing and ending, and a client's domain killed while `erx_screen` composes from its buffer, where a seeded unmap of an area before its last image is freed makes ASan report, and a seeded `wrap/4` without its bound check fails the range cases |
| **G3.** What a client makes the display domain spend is bounded by its grant | memory: the grant's `pixels` is the size of the client's pixel area, charged when the connection is made and never grown, and its `windows` bounds the client's window processes, each of which holds one present, at most 16 rectangles, a label and at most 4 KiB of pending `mouse` and of pending `kbd`; the display holds no image, font or tree of a client; a write carries at most the file protocol's 64 KiB, and a `ctl` or `wctl` line at most 1,024 bytes; `erx_screen` never waits on the driver, so its mailbox drains while a frame is with the device, and what it holds meanwhile is state, not a queue: the newest layout, which replaces the one before, and at most one waiting present for each live window, dropped when the window ends ([The screen](#the-screen-and-its-one-path-to-the-device)). CPU: a window has one present in flight; `erx_screen` gathers the presents that arrive while the device is busy into one frame and copies for each window at most its present's 16 rectangles, each clipped to the window's visible region, once a frame, so a client that presents as fast as it is answered costs one such copy for each frame of the device and delays no other window by more | a buffer the display allocates for a client; a window with two presents composed in one frame; an unbounded queue; a layout kept for each change instead of the newest; a waiting present kept after its window's end; a call to the driver that blocks `erx_screen`; a layout change that asks a client for work | a client that makes windows past its quota, refused with `EDQUOT`, with the domain's memory unchanged; against a driver model that never answers, a client that writes 100,000 `wctl` moves and makes and removes 100,000 windows leaves `erx_screen`'s message queue empty between messages and its heap within the bound computed from the windows quota, where a seeded `erx_screen` that calls the driver synchronously, or that keeps every layout, fails the bound; a client that floods presents from one window while another window's one present is answered within two frames, where a seeded window process that sends its next present before the last is answered fails it; the queue bounds of the data model |
| **G4.** A presentation grants nothing | a presentation is a type and a canonical text; the terminal emulator's only actions on one are to insert its text as keyboard input and to highlight the presentations of the types an input context names; a widget's only action is the `{select, Type, Value}` event to its application; neither carries a facet, a grant or a capability, and the command that then runs is checked by the shell's facets as any typed command is ([Authority](design.md#authority)) | a terminal that calls a service for a clicked link; a widget server that performs the action a presentation names | a session without an inspect facet clicks a pid presentation and the inserted `i` command fails with `no_facet`; the link parser's fuzz target; a source check that `erx_term` and `erx_ui_server` call no facet |
| **G5.** Attributed text in a window is displayed only through the line escape, and a program's output reaches its terminal window unchanged | a window's label, a widget's `present` text and a widget's text drawn from a record value are escaped by the displayer with `erx_text:escape_line/1` ([Attributed text](design-live.md#attributed-text)): the menu in the display domain, a renderer in the session; the terminal emulator takes its bytes from a tty, which changes nothing but what `termios` says (V1), and interprets them as a terminal does | a label drawn raw; a terminal emulator that filters a program's bytes | the attributed-text test corpus of design-live sent as a label, as a `present` text and as a record value in a widget; V1's byte test with a terminal window in place of the serial line |
| **G6.** Nothing paints without a change | the only path to the device is `erx_screen`, which composes on a window's present and on a change of the layout, and repaints from the buffers it already maps when the driver restarts or the panel wakes; the driver pushes only the rectangles it is given; no process of the display domain has a redraw timer; no renderer has one either: the LVGL program, built with animations off, blocks on its standard input until a record arrives or its next LVGL timer is due, so it reports only what a change invalidated | a periodic repaint; a push of the whole screen for a small change; an LVGL timer that fires without a change | an idle display for one minute makes no device request, counted at the driver, on the desktop and on a kiosk under LVGL, where a seeded animation in the LVGL build fails it; a one-pixel change makes exactly one push of one rectangle; moving a window pushes exactly the area whose content changed |
| **G7.** A widget never fabricates | a `present` property and a value drawn from a record keep their `attr()` status; the renderer shows every status other than `ok` as its token, as `erx_render` does (V2) | a widget that drops a status | the status tests of design-live run through a widget tree, for each status and reporter |
| **G8.** What a program writes to a terminal window costs bounded memory, and nothing of it comes back as input | `erx_vt`'s state is bounded by its size and the constants of [Bounds](#bounds): parameters, intermediates and strings are capped, the scrollback is capped in cells and the link table in entries, and an endless sequence costs no memory; its only replies are DA's and DSR's fixed forms, whose variable parts are numbers it computes; it is Erlang, so a fault in it ends one terminal process, not its session's runtime | a buffer that grows with a sequence; a report that echoes text, such as a title report; a native parser of program output | the fuzz target asserts the state's size against the bound computed from the size and the constants, where a seeded scrollback without its cap fails it; the reply test sends every query form, a title report among them, and checks every reply against the three forms, where a seeded title report fails it; the chokepoint check that only `erx_vt` interprets a terminal's output |
| **G9.** The display domain interprets nothing a client drew | a client's bytes reach the display domain as the file protocol's terms, which the funnel and the protocol's grammar check, as one `ctl` or `wctl` line, which a pure parser reads, as a label or the clipboard's bytes, which are kept and never parsed, and as pixels, which `erx_memdraw` copies between images over rectangles the display computed; the display release holds no draw decoder, no `Y` or PNG decoder, no font reader, no widget schema and no renderer, and has no sub-space | a decoder of client bytes in the display release; a NIF of it that takes a client's binary and parses it | an xref check that the display release contains none of the session's draw, font, picture and widget modules, with a seeded dependency failing it; the build check over the release's NIFs (Chokepoints) |

## Data model

### Windows and buffers

```erlang
-type window_id() :: 1..16#7fffffff.             % unique within a display
-type coord() :: -16#80000000..16#7fffffff.      % draw(3)'s 32-bit coordinate
-type rect() :: {X0 :: coord(), Y0 :: coord(),
                 X1 :: coord(), Y1 :: coord()}.  % half-open, as Plan 9's
-type color() :: 0..16#ffffffff.                 % draw(3)'s RGBA
-type chan() :: binary().        % Plan 9 channel descriptor: <<"x8r8g8b8">>, <<"r5g6b5">>, <<"k8">>, <<"k1">> ...
-type buffer() :: #{offset := non_neg_integer(), % in the client's pixel area
                    width := 1..16384, height := 1..16384}.
-type window() :: #{id := window_id(),
                    dir := {Client :: binary(), Name :: binary()}, % its directory in the tree
                    holder := pid(),           % the mkdir's Owner; the window ends with it
                    rect := rect(),            % on the screen; the policy's to set
                    state := shown | hidden,
                    label := binary(),         % attributed text, escaped when drawn
                    proc := pid()}.            % the window process
%% What a window process holds besides its row of the table:
-type presented() :: #{buffer := none | buffer(),   % the last present's
                       mouse := queue:queue(binary()), % pending records, at most 4 KiB
                       resized := boolean(),        % the next mouse read answers 'r'
                       kbd := queue:queue(binary())}. % pending records, at most 4 KiB
```

**A buffer's layout** is fixed by its width, its height and the
display's channel, and is the layout `libmemdraw` gives an image of the
rectangle (0, 0)-(width, height) in memory: rows from the top, each of
`stride` bytes, a pixel's bytes little-endian as Plan 9 stores them.

```text
stride(width, depth) = 4 * ((width * depth + 31) div 32)     bytes in a row
bytes(buffer)        = stride(width, depth) * height
```

The depth is that of the display's channel, which a client reads from
`ctl`. So a buffer in `x8r8g8b8` has rows of 4 times its width, the
layout virtio-gpu, a plane compositor and a GPU all take, and one in
`r5g6b5` rows of 2 times its width rounded up to 4 bytes. A buffer has no
header and no field: the display computes every address in it from the
`present` that named it, checked, and from nothing the area holds.

A display's grant carries its quotas, from the manifest's facet
parameters: `windows`, the windows it may hold at once; `pixels`, the
size of its pixel area; and `snarf`, whether its tree has the
clipboard. Their defaults are 8 windows, a pixel area of 64 MiB, and no
clipboard. A window is at most 16,384 pixels on a side, so a buffer is
at most 1 GiB, and its size is computed with checked arithmetic.

**A window's buffer is the screen's size.** Every buffer a client
allocates for a window, the first and a second if it keeps two, is at
the size of the display's screen when the window is made, and its
holder keeps it until it exits: a resize changes the width and height
the client draws and presents within it, never the allocation, so a
resize allocates nothing and nothing is left behind to free. A window's
cost is therefore one screen's bytes, rounded up to pages, for each
buffer it keeps, and a grant's `pixels` is sized as its `windows` times
that: the defaults hold one buffer for each of 8 windows on a screen of
1920 by 1080 pixels in `x8r8g8b8`, 8,294,400 bytes each. A client
whose area has no room for a new window's buffer is refused at `open`,
which removes the window it made for the buffer
([The window tree](#the-window-tree)), and a screen that grows after a window was
made shows the background where that window's buffer does not reach
([The window tree](#the-window-tree)) until its client opens a window
at the new size. A `ctl` or
`wctl` line is at most 1,024 bytes, and a write of any file at most the
file protocol's 64 KiB payload
([Bytes](design-files.md#how-a-request-names-its-bytes)).

A present carries at most 16 rectangles; a client with more sends their
bounding box, as Plan 9's `flushimage` does with one. A window's `mouse`
and `kbd` hold at most 4 KiB of pending records each; past that the
oldest record is dropped and counted, as a tty drops typed input past
its bound ([design-live.md](design-live.md)). A resize is not a queued
record but the `resized` flag, which the next read of `mouse` answers
with an `r` record, as Plan 9's mouse device does, so no drop loses one.

### The pixel area

The pixel area is how pixels cross from a client's domain to the
display's without a copy and without a message. It is one object of the
connection between the two domains
([design-domains.md](design-domains.md#connections)), beside the
connection's two sides and two bells:

* **The system domain makes it.** Every page two domains both map is an
  object the system domain created, and the pixel area is no exception:
  the domain library creates it in the plan that makes the connection,
  sized by the `pixels` parameter of the manifest's grant of the
  display's window tree to that client, a facet row's for a configured
  domain or for each session of a session template, and gives each
  party its capability, without the right to delete it
  ([design-system.md](design-system.md#the-domain-library)). A pair of
  domains with no grant of a display between them has a connection
  without one; a grant that states no `pixels` has the default area.
  No request at run time makes, grows or shrinks a pixel area, so no
  party waits on another for memory and a window's making and resizing
  involve the system domain not at all.
* **One writer, one reader.** The client's domain maps it read-write and
  the display's read-only, as each maps the side of the connection it
  writes and the side it reads; D16 of
  [design-domains.md](design-domains.md#invariants) holds for it as
  written. The area carries pixels and nothing else: no pid, no
  capability, no length the reader acts on.
* **The reader pays.** The area is charged to the display's child budget
  for that connection, as the side the display reads is, so the grant's
  `pixels` is exactly what the client makes the display hold (G3), and
  the manifest check sums every grant's `pixels` against the display
  domain's outer budget as it sums lanes: a facet row's `pixels` once
  for a configured domain, and for a session template as many times as
  its principal's `domains` quota lets sessions of it live at once
  (property 18 of [The manifest](design-system.md#the-manifest)). So
  however many sessions of a template start, an app's among them, the
  display never pays more than the board's manifest states.
* **It lives exactly as long as the connection.** It is deleted with the
  connection's other objects, once each party has unmapped it or ended
  ([Introduction and connection
  down](design-domains.md#introduction-and-connection-down)). A dead
  client's area stays mapped in the display until the display lets go, so
  `erx_screen` never reads memory that is gone; a dead display's area
  stays writable in the client until the client lets go, so no renderer
  faults. A display domain that restarts is a new domain with a new
  connection and a new, zeroed area.

In each runtime the connection agent maps a connection's area when it
maps its sides, and `erx_area:open(Peer)` answers `{ok, Area, Bytes}`,
a NIF resource for the mapping, or `{error, none}` for a connection
without one. `erx_memdraw:wrap(Area, Offset, Rect, Chan)` makes an image
over a range of it, refusing an `Offset` that is not a multiple of the
page size and a range that, with the one word `libmemdraw` may load past
an image's rows, passes the area's end, so every word `libmemdraw` loads
or stores in the image is aligned and inside the area; an image over the
display's read-only mapping is never a destination. The image refers to
the area, and the agent unmaps the area, and only then answers that the
connection is unmapped or lost, when the last term that refers to it has
been collected. `erx_winfs` opens a client's area when the
client's grant is minted and drops it when the grant ends, and
`erx_screen` collects its heap when a grant's windows end, so a
connection's end is not held by garbage.

**A client's buffers.** Each client domain runs one allocator,
`erx_pixels`, a process registered locally under that name, with one
pure free list, `erx_pixels_core`, for each display's area it has open.
`alloc(Peer, Bytes)`, where `Peer` is the display's domain id, the one
`erx_area:open/1` takes, answers `{ok, Offset}`, the offset of a range
of whole pages of that display's area, zeroed, `{error, enomem}` when no
free run is long enough, or `{error, none}` when the domain has no area
to `Peer`. The range belongs to
the process that asked, which `erx_pixels` monitors, and its owner may
lend it whole to one program at a time with `lend(Peer, Offset)` (below). It
goes back to the free list once nothing holds it: its owner has exited
and no lease of it is outstanding. It goes back in no other way: there
is no `free`. So a range is reused only once its owner is gone and no
program maps it, and nothing the next owner reads was written by the
last. The owners are chosen so that an owner's exit means no one in the
client can touch the range once its leases are returned:

* a window's buffer for drawing in the runtime belongs to the window's
  holder, the process that opened it with `erx_win` (a widget server, a
  terminal, a draw connection), whose exit ends the window too;
* a buffer mapped into a program belongs to the program's handler,
  which allocates it when a session process names it among a program's
  descriptors as `{N, {buffer, Peer, Bytes}}` and answers the starter its
  offset ([design-programs.md](design-programs.md#the-handler)), and
  the program maps it from a lease, which the program driver returns
  only after it has destroyed the program's anchor, which ends the image
  and its sub-space ([design-programs.md](design-programs.md#a-programs-end)).
  The range waits for that return however the handler ends, a crash
  included. Neither the handler's exit nor the port's marks the moment
  the program's mapping is gone. ERTS sends a linked port its exit while
  it cleans up a dead process and does not wait for the port's stop
  (`erl_process.c`, `erts_proc_exit_handle_link`), and a closing port's
  monitors fire before its driver's stop runs (`io.c`,
  `erts_deliver_port_exit`, then `terminate_port`). The lease's return
  does mark it, so no program still maps a page that is handed out again;
* a client that wants a buffer apart from any one window, such as a
  renderer's second buffer, starts a process to own it.

The display does not see the allocator, and need not: it reads only the
range a window's last present named, within the client's own area. When
a window ends, `erx_screen` drops its buffer from every frame not yet
handed to the driver; a frame already with the driver may read the old
range once more, and what it reads there is that same client's pixels,
which the client could have presented itself. Two live windows of one
client whose buffers overlap show each other's pixels, which is that
client's own affair.

**How many buffers a window has is the client's choice.** The display
keeps one thing for each window, the buffer of its last present, and
reads that buffer whenever it must show the window: at the present, and
again when a window above it moves away. So the rule a client follows is
one: *the display may read a window's presented buffer at any time,
until the answer to a present of another*.

* A client with **one buffer** draws in the buffer the display reads. A
  frame it draws in several steps can be shown part-way through when the
  layout changes, as on Plan 9. Terminals, the Erlang renderer and draw
  connections work this way.
* A client with **two buffers** draws the next frame in the one the
  display does not read and presents it. When that present is answered,
  the other buffer is the client's to write again. Nothing of a
  half-drawn frame is ever shown, on any composition path.

The answer is therefore the release that Wayland sends as an event and
Fuchsia signals as a fence, and it needs no object of its own.

**A buffer in a program.** A session gives one of its programs a
window's buffer as it gives it its data area: while it builds the
program's sub-space it maps the buffer's pages of the pixel area there,
read-write, and names the mapping in the program's startup message as a
`mem` descriptor, which the program's `mmap` of that descriptor returns
([design-programs.md](design-programs.md#the-startup-message)). The
program holds no capability to the area and no other page of it. The
program's handler allocates such a buffer and owns it (above), at the
size of the display's screen, as every window's buffer is, so a resize
of the window changes the width and height the program is told and
never the mapping.

**The lease.** The program's mapping rests on one object, a **lease**:
an object of the area's NIF that names one range of the area, through
the slot of the area's object that the area's resource records from
`map/4`, and keeps the area's resource with `enif_keep_resource`, as an image
over the area does (`erx_area.h`), so the connection agent, which
unmaps the area and answers that the connection is unmapped only once
the resource's last reference is gone, waits for the program's mapping
as it waits for an image's. A lease has a **holder**, the process the
range belongs to, and is in one of three states:

| State | Who has it | Leaves it |
| --- | --- | --- |
| held | the area NIF's table of leases, under a number of its own, from 1, that is never given again | to taken, when the start of a port whose owner is the holder takes it by that number; to returned, when the holder exits, which the lease's down callback learns from its monitor of the holder, or when the holder gives it back with `erx_pixels`'s `unlend(Lease)` |
| taken | one program port's driver | to returned, when that driver has destroyed the program's anchor, or has undone a start that failed after the take |
| returned | no one | never |

A lease is a NIF resource of its own type, opened with a down callback
for its monitor of the holder. Each state is left by one transition
only, decided under the table's one lock, so a lease is taken at most
once and returned exactly once, whichever of the holder's exit, a
give-back, a take or the driver's end comes first. The transition into
returned also removes the lease's entry from the table, so a returned
lease's number names nothing. What follows a return, the message and
`enif_release_resource`, runs after the lock is let go, since a
release that ran the destructor under the lock would take it again.
The driver takes and returns leases under its port's lock, so the one
lock order is the port's lock, then the table's; the down callback and
the give-back take the table's lock alone. Its return sends the process that made it, `erx_pixels`,
`{erx_area_returned, Tag, Lease}`, `Tag` being the reference
`erx_pixels` made for the lend, as the area's end sends the agent
`{erx_area_unmapped, Tag}`, and lets go of the area's resource.
`erx_pixels` acts only on a return whose `Tag` is the one it keeps for
that lease: numbers count up from 1 and any process of the domain can
send the allocator a message, so a return named by its number alone
could be forged and free a range a program still maps. A held
lease that no port takes is given back by its holder, or returned when
the holder exits, as the range itself would be.

The steps, each in the one place that serializes it:

1. **Lend.** The handler calls `erx_pixels`'s `lend(Peer, Offset)`. The
   allocator checks that `Offset` starts a range it handed to the
   caller, and makes the lease with
   `erx_area:lend(Area, Offset, Pages, Holder, Tag)`, for the whole range,
   with the caller as holder and a reference made for this lend as
   `Tag`. While an earlier lease of the range is
   outstanding the allocator answers nothing yet, and makes the new
   lease when that one's return arrives, so a handler that starts a
   program again in the same buffer waits for the last program's
   teardown instead of racing it. It answers `{ok, Lease, Pages}`, the
   lease's number and the range's pages. Only `erx_pixels` calls
   `erx_area:lend/5`, `erx_area:unlend/1` and `erx_area:zero/3`, so every lease is a whole
   range of one owner, and the allocator knows of every lease before it
   can be returned.
2. **Take.** The handler names the buffer among the descriptors of
   `erx_program:start/1`'s spec as `{N, {mem, Lease, Pages}}`, at most
   one such entry, at the number `N` the program expects (3 for
   `erx-lvgl`), and calls `start/1` itself, so the port's owner is the
   lease's holder; with a `mem` entry the spec's handler is its caller.
   `start/1` takes a `Lease` from 1 to 2^64 - 1 and `Pages` from 1 to
   the pages `prog_mem_bytes` holds, and refuses anything else with
   `badarg` before it opens the port. It writes the number and `Pages`
   into the port's open command, as decimal words that the driver reads
   as it reads the command's others, refusing a word above 2^64 - 1, and
   `Pages` into the startup message's descriptor. A start without a
   buffer writes `0 0` in their place, which the driver reads as no
   buffer; the start core refuses a number of 0 with `Pages` above 0 and
   a number with `Pages` of 0. The
   driver's start, which runs under the port's lock inside `open_port`
   ([design-runtime.md](design-runtime.md#programs-as-ports)), takes the
   lease as its first effect, with `erx_area_lease_take`, which answers
   the lease only if it is held, its holder is the port's owner, as
   `driver_connected` names it, and it spans `Pages`. A driver never
   reads a term of the area: the number is all that crosses from Erlang
   to the driver, and the area NIF hands the driver the lease, not the
   area's capability. The table and its lock are made when the area
   NIF loads; a take before then answers no lease without touching
   either, as no lease can exist yet.
3. **Map.** The start maps the leased pages, read-write, at the
   program's **buffer place**, with `erx_area_lease_map`, after it
   creates the image's space and before it maps the image.
4. **Return.** The driver returns the lease with
   `erx_area_lease_return` after its release has destroyed the
   program's anchor, which ends every image of the program and every
   mapping in them; in a start that fails after the take, the return is
   the last undo, after the anchor's destroy when the anchor was made.
   A start that fails returns the lease before `open_port` answers, so
   the port's stop, which does nothing after a failed start, owes it
   nothing. The release runs at the program's end, at `port_close/1`
   and at the handler's exit, which closes the linked port, so every
   way a program ends passes the return.
5. **Give back.** A start that fails before its take, because
   `start/1` refused the spec or the port did not open, leaves the
   lease held. The handler gives it back with `erx_pixels`'s
   `unlend(Lease)`, which returns a held lease of the caller's and does
   nothing to one taken or returned, so after any failed start the
   handler gives back without knowing how far the start went.

**The allocator is not restarted over an area.** Its free list and its
knowledge of outstanding leases live in its own state, so a second
allocator over the same area would hand out ranges that programs still
map and never hear of their returns. `erx_pixels` is therefore a
significant child of the client's release: its exit ends the client
domain, and what starts it again, where its manifest asks for that,
starts a new domain with new connections and new, zeroed areas, the
recovery that already exists for a domain. It is a module of the
client application `erx_win`, with `erx_pixels_core`, and the application's
supervisor, `erx_win_sup`, starts it as a `temporary`,
`significant` child with `auto_shutdown => any_significant`, as the
system release starts the domain service
([design-system.md](design-system.md#system-services)). Every release
that holds a display's grant, a session template's or a configured
domain's, starts `erx_win` as a permanent application, so the
allocator's end ends the application and the domain
([design-apps.md](design-apps.md#starting-a-session)); the display domain's release does
not hold it, so no allocator runs over the display's read-only mappings. A handler
reaches the allocator by its registered name, and names the area by
its display's `Peer`, which `erx_win`'s handle keeps with the buffer.
`erx_win:open/2` takes `Peer` from the display's grant in the domain's
registry: it is `erx:owner/1` of the grant's facet, the pid `erx:cap/1`
answers for the display's name, since a domain's node has its domain id as
creation ([D1](design-domains.md#invariants)) and the system domain
installs a facet only from a pid whose node and creation are the serving
incarnation's (`erx_domain_mints.erl`). A display that restarts is a new
domain, so its new grant names a new `Peer` and a new area.
Holding
each range as a NIF resource freed by its destructor would survive the
allocator's restart, but would move the free list into C and make every
range's life depend on garbage collection, where the owner's exit is
the rule a maintainer reads.

**The allocator's core.** `erx_pixels_core` is a pure state over one
area of `N` pages, `N` the area's bytes over `page_size`
(`abi/erx_abi.txt`): a free list of disjoint runs `{Start, Pages}` in
order of `Start`, and the live ranges by offset, each with its pages,
its owner and its lease. Each call answers the next state and the
effects to perform, in order, and the process performs them before it
takes its next message.

* `alloc` rounds `Bytes`, an integer from 1, up to whole pages and
  takes the range from the start of the first run long enough, the run
  keeping what is left; `{error, enomem}` when none is, however many
  pages are free in all.
* A range joins the free list by **zero, then join**: its pages are
  zeroed with `erx_area:zero/3` (below), then the run is inserted and
  merged with the run that ends where it starts and the run that starts
  where it ends. A new area is zero from its making, so every page on
  the free list is zero and `alloc` itself writes nothing.
* A live range's state is its owner, live or gone, and its lease, none
  or outstanding:

| State | Leaves it |
| --- | --- |
| owned (owner live, no lease) | to lent, when its owner's `lend` makes a lease; to free, by zero then join, at the owner's exit |
| lent (owner live, lease outstanding) | to owned, at the lease's return, unless a `lend` waits, which then makes the next lease and the range stays lent; to orphaned, at the owner's exit, which drops a waiting `lend` |
| orphaned (owner gone, lease outstanding) | to free, by zero then join, at the lease's return |

A range has at most one waiting `lend`, its owner's, which waits inside
its call; the process keeps each lease's number with its area and range,
so a return, which names only the number, finds its range. The process
opens a `Peer`'s area at the first `alloc` that names it and lets go of
the area's term once no range of it is live, so a lost connection's end
waits for its last program's return and for nothing else, and an area
opened again is wholly free and wholly zero.

`erx_area:zero(Area, Offset, Pages)` stores zero over the range, in the
area NIF, on a dirty CPU scheduler. It answers `ok`; `{error, einval}`
for the `Offset`, `Pages`, range and read-only area `lend/5` refuses,
except that `Pages` is bounded by the area and not by
`prog_mem_bytes`; and `badarg` for an `Area`, `Offset` or `Pages`
`lend/5` would call `badarg`. It is the area's one per-byte primitive,
and it maps nothing: it writes through the mapping the connection agent
made, so the area keeps its two mappers. Zeroing through an image of
`erx_memdraw:wrap/4` would need a rectangle and a channel for what is a
byte fill of whole pages, and a drawing call for what is not drawing.

The system domain therefore never deletes an area that a program still
maps, on erXos's kernel, where memory mapped from a deleted object
faults, and on the stopgap, whose delete removes every mapping of the
object (`erx_fiasco_vm_object_revoke`). A program whose display dies
goes on writing its buffer without a fault until its session ends it.

The lease's number names a lease to the driver and grants nothing by
itself: only the holder's own port takes it, so another process of the
session that learns the number cannot map the range.

The **buffer place** is the same in every program: from
`prog_mem_base`, 0x7f00000000, for at most `prog_mem_bytes`, 1 GiB, two
limits of `abi/protocols/prog.txt`. It holds the largest buffer, 16,384
pixels square at 4 bytes a pixel. Its first page is below 2^32, as the
startup message's page number needs. It lies inside the stopgap's task
range, from 2^38 to 2^39 (`liberx/backend/fiasco/vm.h`, `vm.c`), above
the address `task.ld` links a program at, 0x4000100000, so one value
serves both kernels and no image of the boot image meets it.
`erx_area_lease_map` reserves the lent range there with
`ERX_VM_FIXED | ERX_VM_NOREPLACE` and maps the lease over it. Because
the buffer is mapped before the image, an image that meets it fails the
start with the loader's refusal of a range already mapped; on the
stopgap, whose loader takes only fixed images and places them one load
segment at a time (`service_task.c`), a segment that meets the buffer
fails the start with `enomem`, and an image whose segments lie on both
sides of the buffer runs with the buffer between them.

`erx_area:lend/5` answers `{ok, Lease}`, `{error, einval}` for an
`Offset` that is not a multiple of the page size, `Pages` of 0 or more
than `prog_mem_bytes` holds, a range that passes the area's end,
computed with checked arithmetic, and a read-only area, which is the
display's, and `{error, noproc}`, making no lease, for a holder whose
monitor cannot be set because it has exited already: a lease made for a
dead holder would stay held for ever and keep the area mapped.
`Offset` and `Pages` are integers from 0 to 2^64 - 1, `Holder` a
local pid and `Tag` a reference: anything else, or an `Area` that is no
area, is `badarg`, as
`map/4`'s arguments are (`erx_area_nif.c`). `erx_pixels`'s
`lend(Peer, Offset)` answers `{error, einval}` for an `Offset` that starts no
range of the caller's in `Peer`'s area; for a caller that exited while it waited it
makes no lease, and its own monitor frees the range as any owner's exit
does. `erx_area:unlend/1` answers `ok` whatever the lease's state, and
`badarg` for a term that is no integer from 1 to 2^64 - 1.
`erx_area_lease_take` answers no lease for a
number with no held lease, a lease taken or returned, a holder that is
not the port's owner and a lease of another length, and the driver's
start then fails with `einval`.

### The window tree

`erx_winfs` serves one tree per display, declared as the interface
`windows` in `abi/services/windows.txt`: an `erx_fs` grant, as `files`
is, whose operations are the file protocol's own, with the parameters
`windows`, `pixels` and `snarf`. A client's grant is rooted at the
client's directory, so the client sees:

```text
/N/ctl      read: the display's channel; write: a present
/N/mouse    read: 49-byte records 'm x y buttons msec' and 'r ...' after a resize
/N/kbd      read: records 'c' runes typed, 'k' keys down, 'K' keys down after a release
/N/wctl     read: the window's rectangle and state; write: a geometry command
/N/label    read and write: the window's title
/screen     read: the screen's rectangle and channel
/snarf      the display's clipboard, read and write; present only when the grant carries snarf
```

A window is made by `mkdir` of a name of the client's choosing in its
directory; the window takes the next `window_id()` within the display,
and the name is the client's, as any directory's is. Ids are never
reused and never wrap: once a display has issued id 2^31 - 1, every
later `mkdir` fails with `ENOSPC`, and the display logs once that its
window ids are spent. The `mkdir`'s
`Owner` ([Fid owners](design-files.md#fid-owners)) is the window's
holder: a window ends when its holder ends, when its directory is
removed, or when its grant ends, whichever comes first, as a fid ends at
its owner's end. `mouse` and
`wctl` are the formats of Plan 9 and 9front, and `kbd` is the format of
9front's `kbd` file as kbdfs(8) describes it (9front, commit
`eb49f1f8788c`, `sys/man/8/kbdfs`, lines 208-236). A record is one byte
naming its kind, its runes in UTF-8, and a NUL: `k` when a key goes
down and `K` when one goes up, each followed by the runes, in unshifted
form, of every key then held for the window and of every modifier then
held on the display, wherever its own down went, since the display has
one modifier state ([The input router](#the-input-router)); and `c`,
the one rune the key types, at most 6 bytes, which is sent again at the
repeat rate while the key is held. So the set of the `k` record of a
key's down names the modifiers it was typed with, Alt among them, which
selects no layer. Arrows, function keys,
modifiers and the other keys that type no character are runes of
9front's private-use range ([Input events](#input-events)). Because
every `k` and `K` record carries the whole set, a reader that lost
records to the queue's bound has the right set again at the next one. A read of
`mouse`, `kbd` or `wctl` is a
helper-mode read that waits for a record
([The `erx_fs` behaviour](design-files.md#serving-the-erx_fs-behaviour)).
Only these names exist; `cons`, `winname`, `consctl` and `wsys` do not,
since a terminal is a program's choice and attachment by name is gone.

**`screen`.** A read answers one line: the screen's rectangle, as the
four numbers that open a `wctl` read and in their form, and the
display's channel descriptor, as `ctl` answers it. It lies at the
client's root, beside its windows' directories and `snarf`, so a
client reads it before it has a window. Each read answers the screen
as it is at the read, so after a change of the screen's size the next
read answers the new rectangle; a read while the display has no screen
fails with `EIO`, as a `mkdir` then does, and opening it for writing
fails with `EACCES`. `screen` and `snarf` are the tree's own names, so
a `mkdir` of either fails with `EEXIST`. `erx_win:open/2` reads
`screen` first, makes the window, where a client at its `windows` quota
gets `EDQUOT`, and only then allocates the window's buffer at that size
in the client's pixel area; when a full area answers `enomem`, it
removes the window's directory, which ends the window, and answers
`{error, enomem}`. The order follows from the allocator, which has no
`free` ([The pixel area](#the-pixel-area)): a range belongs to its
owner until the owner exits, so a buffer allocated for a window that
then failed to be made would stay spent, while a window is undone by
removing its directory. A refused `open` leaves no window and no
buffer; the window it made for a moment took a window id and showed none
of the client's pixels. A client re-reads `screen` at an
`r` record of any of its windows, to size the next window it opens.

**`ctl`.** A read answers one line, the display's channel descriptor. A
write is one command of one line:

```text
present OFFSET WIDTH HEIGHT [X0 Y0 X1 Y1]...
```

with every number in decimal, the buffer's offset in the client's pixel
area and its width and height in pixels, and from none to 16 rectangles
in the buffer's coordinates; none means the whole buffer. `erx_winctl`,
a pure parser with a fuzz target, reads it, and the window checks it
whole before anything is shown:

* the width and height are from 1 to 16,384;
* the offset is a multiple of the page size, as every range
  `erx_pixels` hands out is, so the buffer's rows are word-aligned for
  `libmemdraw` and page-aligned for a device that reads it;
* the buffer's bytes, by the layout above with checked arithmetic, end
  at or before the end of the client's pixel area;
* each rectangle is well formed, and is clipped to the buffer.

A line outside the grammar or the checks fails the write with `EINVAL`,
and a client whose grant has no pixel area gets `ENXIO`; neither changes
what the window shows. The display does not ask that the buffer's size
equal the window's: the buffer is placed with its top left corner at the
window's, clipped to the window's rectangle, and where the buffer does
not reach the window shows the background. So a client that presents a
frame drawn for the size its window had a moment ago shows that frame
clipped until its next, and a resize needs no handshake.

**A program's `/dev`.** A program that draws is started with a window:
its handler makes the window with itself as the holder, so the window
ends with the program, and starts a draw connection on it. The handler
binds the connection's `draw` and `ctl`, from the session's own export,
and the window's `mouse`, `kbd`, `wctl` and `label`, from the display's
tree, at `/dev/draw`, `/dev/ctl` and the rest, beside the session's own
`/dev` entries, and, when the grant carries `snarf`, `/snarf` at
`/dev/snarf`, so a Plan 9 program finds each where it expects it. The
`ctl` a program sees is the draw connection's, which answers the display
information of draw(3); the window's own `ctl`, which takes presents,
stays with the draw connection and is bound for no program.

### Draw messages

The byte encoding of the draw protocol is declared in
`abi/formats/draw.txt`, from which the generator produces the Erlang
decoder `erx_draw_codec`, its bounded C twin for the fuzz target, the
encoder `erx_draw` uses and the message table of this document's
interface section. The messages are those of draw(3), as 9front's manual
and the `devdraw` of 9front and plan9port implement them (References).
Integers are little-endian, a point is two 32-bit coordinates and a
rectangle four; every drawing message composes with the operation `O`
set, which then returns to `SoverD`.

| Message | Fields after the letter | Effect |
| --- | --- | --- |
| `b` | id, screenid, refresh[1], chan, repl[1], r, clipr, color | allocate image id with rectangle r, channel chan and the replicate bit, filled with color; its clip rectangle is clipr, intersected with r unless repl is set |
| `c` | dstid, repl[1], clipr | set the image's replicate bit when repl is nonzero, and replace its clip rectangle |
| `d` | dstid, srcid, maskid, r, sp, mp | draw: compose src through mask onto r of dst, sp and mp aligned with r's corner |
| `e` | dstid, srcid, c, a, b, thick, sp, alpha, phi | outline the ellipse at c with semi-axes a and b, thickness 1+2·thick; when alpha's high bit is set, only the arc that starts at alpha degrees and extends through phi |
| `E` | as `e` | fill the ellipse, or the sector when alpha's high bit is set |
| `f` | id | free the image |
| `i` | id, n, ascent[1] | make image id a font cache of n glyph records, 1 to 4096, each with that ascent |
| `l` | cacheid, srcid, index[2], r, sp, left[1], width[1] | copy rectangle r of the cache image from src at sp, with operation `S`, and record glyph index's rectangle, left and width |
| `L` | dstid, p0, p1, end0, end1, thick, srcid, sp | draw a line of thickness 1+2·thick with the given ends |
| `o` | id, rmin, scr | position a layer on its screen and set its logical origin |
| `O` | op[1] | set the compose operation, 0 to 11, for the next drawing message |
| `p` | dstid, n[2], end0, end1, thick, srcid, sp, n+1 coded points | draw an open polygon of thickness 1+2·thick |
| `P` | dstid, n[2], wind, ignore[8], srcid, sp, n+1 coded points | fill a polygon under the winding rule wind |
| `r` | id, r | make the next read of `draw` return r's pixels |
| `s` | dstid, srcid, fontid, p, clipr, sp, n[2], n indices[2] | draw n glyphs of the font cache, the first at p on the baseline, clipped to clipr in place of dst's clip rectangle |
| `x` | as `s`, with bgid and bp before the indices | as `s`, first filling the rectangle under the whole string from bgid, bp aligned with its upper left corner, p raised by the cache's ascent |
| `v` | none | flush the dirty rectangles to the screen |
| `y` | id, r, pixels | replace r's pixels with raw pixels in the image's channel |
| `Y` | id, r, compressed pixels | replace r's pixels with pixels in image(6)'s compressed form |

Fields are 4 bytes unless their size is given in brackets. Where erXos's
connection differs from a Plan 9 connection, the difference follows from
its having no screens, no layers and no names, and from image 0 being
the window:

* `b` with a screenid other than 0 is refused with `ENOENT`, as an
  unknown screen is; refresh then means nothing and is ignored, as
  devdraw ignores it for an image on no screen.
* `o` is accepted and changes nothing, as devdraw does for an image that
  is not a layer, which every image of a connection is; a window's place
  is `wctl`'s.
* `f 0` and `i 0` are refused with `EINVAL`: image 0 is the window,
  which lives as long as the window does and is never a font cache.

The rest is draw(3) as written, except where the manual and the
implementations differ; there erXos follows the devdraw of 9front and
plan9port, which agree with each other and which every client is written
against. `c` sets the replicate bit and never clears it, though the
manual says it changes the bit. `s` and `x` take p on the baseline,
where the manual says the upper left corner, because `libdraw` adds the
font's ascent before it sends the message; `x`'s bp aligns with the
corner the manual names, p raised by the ascent. `O` with an operation
above 11 is refused with `EINVAL`, which devdraw does not check: 0 to 11
are the twelve Porter-Duff operations of draw(2).
Every other refusal is devdraw's own check, mapped to an errno: an id the
connection does not hold `ENOENT`; an id it holds, in `b`, `EEXIST`; past
the quota `ENOMEM`; and `EINVAL` for an unknown or refused channel (below), a negative
semi-axis or thickness, a shape point, centre or source point 2^19 or more from the origin, a semi-axis over 2^14 or a line or ellipse thickness over 2^10 (`libmemdraw` computes a shape in `int`, scaling coordinates by 2^10 for its polygon fill, and within these bounds nothing overflows), a glyph index outside the font cache, an `s`,
`x` or `l` naming an image that is not one, an `r`, `y` or `Y` rectangle
not inside its image, an empty `y` or `r` rectangle, as `loadmemimage` and
`unloadmemimage` refuse it, and an image rectangle that 9front's `badrect`
refuses or wider or taller than the quota's side. `badrect` keeps x within
[-2^25, 2^25), y within [-2^28, 2^28) and the width times each y within
2^28, so `libmemdraw`'s 32-bit arithmetic over a rectangle cannot overflow.
An image wider than 2^16 pixels is refused with `EINVAL` whatever the
quota (`erx_memdraw`'s `ERX_MEMDRAW_MAX_WIDTH`): `alphadraw` sizes its row
buffer in `int`, at worst about 136 bytes a pixel of the row, and this
bound keeps it below 2^24 bytes.

**Channels `b` refuses.** `b` refuses with `EINVAL` the channels that
`libmemdraw` does not draw as draw(2) defines them: below 8 bits a pixel,
anything but `k1`, `k2` or `k4` alone; a map channel other than `m8`
alone; grey beside a colour channel (`k8r8`); and a channel type twice
(`x` excepted). This departs from draw(3), which accepts any well-formed
channel descriptor: `libmemdraw`'s `readnbit`, `readcmap` and `writebyte`
would compose these wrongly (a sub-byte image without grey keeps one
colour as its grey, a map channel with alpha is read as two bytes a pixel
and loses its index, `k8r8` writes only the grey), and the pixels would
match no definition. `erx_draw_core`, the reference `erx_draw_ref` and the
NIF all refuse them.

`A`, `F`, `S` and `t` (screens and layers), `N` and `n` (names), `D`
(debugging), `a` and `w` (9front's affine warp, which plan9port's
`libdraw` never sends) and plan9port's `J`, `I` and `q` (requests of its
own connection, which the port's connection code replaces with reads of
`ctl`) are not in the format and decode as unknown messages, which fail
the write.

**Lengths that draw(3) does not state.** Two fields have no length of
their own. The points of `p` and `P` are coded: each coordinate is one
byte holding a 7-bit signed difference from the previous coordinate, the
first counting from 0, or, when that byte's top bit is set, three bytes
holding a 23-bit signed value, as plan9port's `libdraw` writes them and
devdraw reads them; the manual's `dp[2*2*(n+1)]` is their uncoded size.
And the pixels of `y` and `Y` are exactly the bytes that fill the
rectangle: Dy(r) rows of `bytesperline(r, depth)` bytes each, where
depth is that of the image's channel and `bytesperline` is 9front's
formula: the bytes from the one holding the row's first pixel through
the one holding its last, with bytes aligned at x = 0 on both sides of it
(`erx_draw_image:bytes_per_line/2`). A negative x follows the same formula, 9front's, which
rounds the byte holding the first pixel toward minus infinity, so no separate case exists. `y` carries them raw, so its
payload is their count. `Y` carries image(6)'s compressed form, a
sequence of codes each of which is a literal run (a byte c of 128 or
more, then c-127 bytes as they are) or a back-reference (a byte c below
128 and one more, standing for `(c>>2)+3` bytes found earlier in a
1024-byte window), and its payload ends at the code that completes the last row.
So a `y` or `Y` cannot be framed without the depth of the image it
names, which is the connection's state, and the image may have been
allocated by a `b` earlier in the same write.

**Decoding and planning are one fold.** The codec decodes one message at
a time:

```erlang
-spec erx_draw_codec:decode(binary(), Depth) ->
          {ok, erx_draw:msg(), Rest :: binary()} |
          {error, einval | enoent, Offset :: non_neg_integer()}
          when Depth :: fun((image_id()) -> 1..32 | none).
```

`Depth` is the codec's only view of the connection, and only `y` and `Y`
consult it. `draw.txt` declares their payloads as fields of two kinds,
`pixels` and `compressed`, each naming the id and rectangle fields it
depends on, and the generator emits their framing:

* `pixels`: `bytesperline(r, depth)` times Dy(r), computed with checked
  arithmetic, which must lie within the bytes left in the write.
* `compressed`: framed by decoding it. The generated Erlang codec calls
  `erx_draw_image:decode(Bytes, R, Depth)`, the Erlang decoder of
  image(6)'s compressed form written from the manual, which expands the
  codes into exactly the rectangle's pixels and returns them with the
  rest of the write: a code that would cross the end of a row, or input
  that ends before the last row is complete, is malformed. The decoded
  `Y` message carries the pixels, not the codes, so the one pass that
  frames a `Y` also decodes it, and nothing downstream sees compressed
  bytes. The C twin, a host test tool, frames a `compressed` field with
  `cloadmemimage` of the 9front build (Verification).

Both refuse an empty or inverted rectangle, as 9front's `loadmemimage`
and `cloadmemimage` do, so every row holds at least one byte; each code
reads at least one byte, so decoding never takes more steps than the
write has bytes. An id for which `Depth` answers `none` fails with
`ENOENT`. A failure's offset is that of the field that failed, counted
from the message's letter, or 0 for an unknown letter, so a `compressed`
field fails at its start, as `cloadmemimage` reports no position.
A back-reference may reach before the rectangle's first byte, which
`cloadmemimage` accepts and reads from its uninitialised window;
`erx_draw_image` accepts it alike and reads zeros there, so the two frame
every payload alike.

`erx_draw_core:plan(Conn, Bytes)` is a left fold over the write: decode
one message with the depth function of the connection as planned so far,
step the core with it, and continue from the next byte, until the write
is consumed or a message fails. Because the depth function reads the
planned connection, an image a `b` allocated earlier in the same write
has its depth and one an `f` freed has none, and there is no second table
of depths to keep in step with the images. The fold returns the planned
connection and the list of `erx_memdraw` operations, or the errno and the
offset of the message that failed. The draw connection performs the
operations only after the fold returns, so a write is decoded and checked
whole before any of it is applied, and a write that fails applies
nothing (plan, then apply).

**A message never spans writes.** Each write holds whole messages, as
Plan 9's `devdraw` requires: a message whose fields or payload run
past the end of the write fails with `EINVAL` at its offset, as
`devdraw` fails it with "short draw message", and the connection keeps
no bytes of it for the next write. A client loads an image larger than
one write as several `y` or `Y` messages over bands of rows, each
within one write, as `libdraw`'s `loadimage` does. `libdraw` keeps its
messages whole within its buffer, which it sizes from `iounit` of the
`draw` file; a connection's `draw` reports an `iounit` of 64 KiB, the file
protocol's payload, and a `write(2)` on `draw` larger than that is
refused whole with `EINVAL`, never split into requests, so a port of
`libdraw` needs no change. Unlike `devdraw`, which applies a write's
earlier messages before it fails a short one, a connection applies none of
a write that fails.

### Input events

Input has two forms, one on each side of the display's one input
router, `erx_winfs` ([The input router](#the-input-router)). A driver
sends **records** in its device's terms, so it needs nothing of the
display: not the screen's size, not the layout of the keyboard and not
which window takes it. The router turns them into **`input()`**, the
one form the policy and a window see.

```erlang
-type record() :: {pointer, rel, DX :: -16#80000000..16#7fffffff, DY :: -16#80000000..16#7fffffff}
                | {pointer, abs, X :: 0..65535, Y :: 0..65535}
                | {touch, Slot :: 0..9, down | move | up, X :: 0..65535, Y :: 0..65535}
                | {key, down | up, Code :: 0..?ERX_EVDEV_KEY_MAX}
                | {wheel, Steps :: -128..127}
                | release.

-type input() :: #{device := binary(),        % the device's name, its record's PATH
                   at := integer(),           % milliseconds, the runtime's monotonic clock
                   event := {pointer, X :: coord(), Y :: coord(), Buttons :: 0..255}
                          | {touch, Slot :: 0..9, down | move | up, X :: coord(), Y :: coord()}
                          | {key, down | repeat | up, Code :: 0..?ERX_EVDEV_KEY_MAX,
                             Typed :: rune() | none, Unshifted :: rune() | none,
                             Mods :: [rune()]}
                          | {wheel, Steps :: -128..127}}.
-type rune() :: 0..16#d7ff | 16#e000..16#10ffff.
```

A record's bounds, the numbers `record()` shows above and `input()`
repeats for a touch's slot and a wheel's steps, have one home, the
`input_` limits of `abi/formats/input.txt`: the router holds every
record to them through the generated `erx_input_codec:valid/1`, which
checks the type and binary form that file declares for `record()`
([Input records](design-abi.md#input-records)), and each driver's fold
folds within them through the generated header.
A record's relative move is in the device's own units; an absolute
position, a touch's included, is normalized across the device's own
axis range, 0 at its minimum and 65535 at its maximum. A key is an
evdev code, and so is a pointer's button (`BTN_LEFT`, `BTN_MIDDLE`,
`BTN_RIGHT`, `BTN_TOUCH`). A driver sends each key's down once and its
up once, edges only: a device's own repeat is dropped, and repeat is
the router's. `release` says that the device lost track of its own
state: every key, button and touch it holds is to be taken as up. A
record carries no time and no device name: the router stamps each with
its own clock when it arrives and knows its **source**, the process
that sent it, which is a driver's, or for a device in another domain the
display's reader of that device's file ([The display
device](#the-display-device)).

In `input()` a position is the screen's, inside it; `Buttons` are
Plan 9's, bit 0 the left button, bit 1 the middle and bit 2 the right
(plan9port, commit `1f1396913fb5`, `man/man3/mouse.3`, lines 66 and
76-78), and a wheel step is buttons 8 and 16, as Plan 9 reports a scroll
wheel. A key keeps its evdev code; `Typed` is the rune it types at the
layer its modifiers select, and `Unshifted` the rune of its unshifted
layer, which `k` and `K` records carry, and `Mods` the runes of the
modifier keys held on the display, which a `k` and a `K` record's set
includes ([The window tree](#the-window-tree)); a repeat carries the
runes and `Mods` of its down. The window system delivers each
event to one window, which reads it as 49-byte `mouse` records and `kbd`
records; that is the one input form a window has, for every client. A
touch is a pointer with button 1 down. An encoder's driver sends its
steps as wheel steps and its press as a key, and a keypad's driver sends
keys, each by its evdev code, so no window policy maps devices.

**evdev's codes have one home**, `abi/formats/evdev.txt`: the event
types, the codes of keys and buttons, the relative and absolute axes,
`SYN_REPORT` and `SYN_DROPPED`, and the key states, each under its name
in FreeBSD's `sys/dev/evdev/input-event-codes.h` at release/15.1.0, or
for the key states in `enum evdev_key_events` of that release's
`sys/dev/evdev/evdev_private.h`, and with its value from there. The
table spells a name in lower case after `evdev_`, so `KEY_A` is
`evdev_key_a` and the generated `ERX_EVDEV_KEY_A`, and it holds only
the codes erXos reads. The codes of keys and buttons are the members of
one enum, `evdev` (`key_a`, `btn_left`), the closed set a layout's row
is checked against, and everything else is a `limit`: FreeBSD's names
put the key states and `KEY_MAX` under the keys' `KEY_`
prefix, so the prefix cannot tell them apart. The virtio-input core, the keymap's
generator and the bus drivers of touch controllers, keypads and
encoders read the names the build generates from it, and
`abi/formats/virtio.txt` keeps only virtio's own layouts.

**Special keys are 9front's runes.** A key that types no character, an
arrow, a function key, Home, End, Page Up and Page Down, Insert, Print,
Scroll Lock and Break, and each modifier and lock (Shift, Control, Alt,
AltGr, Mod4, Caps Lock and Num Lock) is the rune 9front's
`sys/include/keyboard.h` gives it (9front, commit `eb49f1f8788c`, MIT
under `lib/legal/NOTICE`): `KF|1` to `KF|0xC` for F1 to F12, `Khome`,
`Kup`, `Kdown`, `Kleft`, `Kright`, `Kpgup`, `Kpgdown`, `Kins`, `Kend`,
`Kprint`, `Kscroll`, `Kbreak`, `Kshift`, `Kctl`, `Kalt`, `Kaltgr`,
`Kmod4`, `Kcaps` and `Knum`; Backspace, Delete and Escape are the
header's `Kbs`, `Kdel` and `Kesc`. `abi/formats/input.txt` holds them by
those names, lowercased, as the members of the enum `input_rune`, with
the values taken from that header, so a client, the keymap and `erx_vt`
read one table; F1 to F12, which the header names nothing, are `kf1` to
`kf12`, and a layout spells a member with its first letter capitalized
(`Kup`, `Kf1`). Each is in the private-use range
but `Kbs`, `Kdel` and `Kesc`, which are ASCII; plan9port's
`include/keyboard.h` gives `Kdown` the value 0x80 instead and names
fewer keys, so it is not the source. A key the header names nothing for
has no rune and reaches a window only in the `k` and `K` sets, when its
row gives it one.

**The keymap.** A layout is one checked-in text file,
`abi/keymaps/NAME.txt`, keyed by evdev code, and `us` is the one layout
the tree has. A display's manifest entry names its layout
([A display's session](#a-displays-session)), `us` by default. A file
reads, for example:

```text
# us: the United States layout.
keymap us
#        code            none    shift   ctl     altgr   shiftaltgr
key      KEY_A           a       A       U+0001  a       A        caps
key      KEY_UP          Kup     Kup     Kup     Kup     Kup
modifier KEY_LEFTSHIFT   Kshift  shift
modifier KEY_RIGHTALT    Kalt    alt
lock     KEY_CAPSLOCK    Kcaps   caps
button   BTN_LEFT        1
```

The columns of a `key` row are the layers of 9front's keyboard map,
`none`, `shift`, `ctl`, `altgr` and `shiftaltgr` (kbdfs(8), lines
265-318), without its escaped layers, which an evdev code never needs,
and without its `mod4` layers. Each entry is a printable ASCII character
other than `#`, a code point as `U+` and four to six hexadecimal digits,
or a special rune's name; `U+0000` means the key types nothing at that
layer, as a zero does in 9front's map. A trailing `caps` marks a key
that Caps Lock shifts. A `modifier` row names a key's rune and the
modifier it holds, one of `shift`, `ctl`, `alt` and `altgr`; a `lock`
row the rune and the lock its down toggles, `caps` alone; a `button` row
the Plan 9 button bit a key holds. The layer a key types at follows from
the modifiers held: `shiftaltgr` with AltGr and Shift, `altgr` with
AltGr, `ctl` with Control, `shift` with Shift, or, for a `caps` key,
with Shift or Caps Lock but not both, and `none` otherwise. Alt selects
no layer: a client sees it in the `k` set, and `erx_vt` sends ESC before
the key. A code with no row is dropped by the router and counted.

`tools/gen_keymap.rb` reads every layout and generates `erx_keymap`, one
table for each, which the router alone calls, and the list of layout
names the manifest check holds a display entry's layout to. It refuses
a layout whose `keymap` line is missing, repeated or differs from its
file's name, a code named twice, a code outside the enum `evdev`, a
special rune outside the enum `input_rune`, a row of the wrong width, a
modifier, lock or button bit outside its set, a surrogate or a code
point past U+10FFFF, and a byte above 0x7f or a control byte other
than the line's end. Nothing reads a layout
at run time, so, as for termcap, it is no input to fuzz. Another layout
is one more file; dead keys and compose sequences are not in the format,
and a layout that needs them extends it.

### Widget trees

```erlang
-type tree() :: {Kind :: atom(), Props :: #{atom() => term()}, Children :: [tree()]}.
-type node_id() :: 1..16#ffffffff.  % the server's number for a node, never reused in a window
-type diff_op() :: {insert, node_id(), Parent :: node_id() | 0, Index :: 0..65535,
                    Kind :: atom(), Props :: map()}            % Parent 0 for the root
                 | {remove, node_id()}                          % the node and its subtree
                 | {set, node_id(), Changed :: map(), Removed :: [atom()]}
                 | {move, node_id(), Index :: 0..65535}         % among its own siblings
                 | commit.
-type ui_event() :: {ui, Window :: reference(), Term :: term(),
                     Detail :: click | {change, term()} | {submit, term()}
                             | {select, Type :: atom(), Value :: term()}}.
```

`abi/formats/ui.txt` declares three closed tables, and every other fact
about a tree follows from them: the **properties**, each with one name,
one wire number and one type wherever it appears; the **kinds**, each the
set of properties it takes, with marks, and whether it takes children;
and the **image types**. Its grammar and the binary form derived from it
are in [Widget format](design-abi.md#widget-format). The properties:

| Property | Type | Kinds | Meaning |
| --- | --- | --- | --- |
| `key` | an integer, an atom or a binary of at most 255 bytes | every kind | the node's identity among its siblings (below); it never leaves the widget server |
| `width`, `height` | integer 0 to 16,384 | every kind | a size hint in the renderer's unit: a pixel on a display, a CSS pixel in the browser |
| `weight` | integer 0 to 255 | every kind | the node's share of the room its row or column has left over |
| `pad` | integer 0 to 255 | every kind | space around the node, in the same unit |
| `align` | `start`, `center`, `end` or `fill`; `fill` when absent | every kind | placement within the room the node gets |
| `visible`, `enabled` | boolean; `true` when absent | every kind | whether the node is shown, and whether it takes input |
| `present` | a presentation, `{Type, Value}`, or an `attr()` carrying one | every kind | a typed value ([Presentations](#presentations)) |
| `on_select` | event | every kind | a click on the node's presentation |
| `text` | at most 4,096 bytes of UTF-8, or an `attr()` carrying them | `label`, `button`, `checkbox`, `input` | the caption; an `input`'s edited text, its state |
| `placeholder` | at most 255 bytes of UTF-8 | `input` | shown while the text is empty |
| `secret` | boolean, fixed | `input` | the text is shown as marks and never kept |
| `checked` | boolean, state | `checkbox` | |
| `min`, `max` | integer -2^31 to 2^31 - 1; 0 and 100 when absent | `slider` | the range, `min` below `max` |
| `value` | integer within `min` and `max`, state | `slider` | |
| `items` | at most 256 texts of at most 128 bytes of UTF-8 | `list` | the entries |
| `selected` | an index into `items`, state | `list` | absent when nothing is selected |
| `columns` | integer 1 to 64; 1 when absent | `grid` | children fill the grid row by row |
| `image`, `image_type` | at most 48 KiB of encoded bytes; one of the image types | `image` | the picture and its encoding |
| `alt` | at most 255 bytes of UTF-8 | `image` | the picture's text, for a renderer that cannot show it |
| `on_click` | event | `button` | |
| `on_change` | event | `checkbox`, `slider`, `input`, `list` | the user changed the node's state |
| `on_submit` | event | `input` | the user pressed enter |

The containers are `column` and `row`, which lay their children out in
order; `grid`; `scroll`, a viewport over its children laid out as a
column; and `stack`, which lays its children over one another, the last
on top. The widgets are `label`, `button`, `checkbox`, `slider`, `input`,
`list`, `image` and `spacer`, which takes only the properties every kind
takes. The one image type is PNG, `image/png`, which every renderer
decodes; the table holds no `image/svg+xml`, which the generator refuses,
so an image is never a document in the browser.

A **state** property holds what the user changes: each kind that takes
`on_change` has exactly one, so an event's value has one meaning. A
**fixed** property is part of the node's identity, as its kind is. An
event property holds a term the application chooses; the server sends it
back as `{ui, Window, Term, Detail}` when the event fires. Every renderer
shows a text property through the line escape (G5); `erx_ui_lvgl` writes
each text escaped, so `erx-lvgl` needs no escape of its own.

A tree is **valid** when every node is a three-tuple of a declared kind,
a map of properties that kind takes with values of their types, and
children only if the kind takes them; when no two children of one node
carry the same `key`; when an `input` whose `secret` is `true` carries no
`text`; when it has at most `ui_nodes` nodes, the toolkit's limit of
10,000, and is at most
64 deep, since the renderers lay a tree out recursively in languages whose
stacks are fixed; and when `min` is below `max`, `value` within them and
`selected` an index of `items`; and when no node has more than
`ui_children` children, 1,024, a root limit of `ui.txt` that bounds
`delta/2`'s work and keeps every `insert` and `move` index within 16 bits. `erx_ui_schema`, generated from
`ui.txt`, decides validity for the whole tree before anything is applied
and answers the first fault in depth-first order as `{error, {Reason,
Where}}`, `Reason` one of `not_a_node`, `unknown_kind`,
`unknown_property`, `bad_value`, `children`, `duplicate_key`,
`too_many_nodes` and `too_deep`, and `Where` the list of child indexes
from the root to the node, `{Path, Property}` for the property reasons;
a secret `input` that carries `text` is `bad_value` on `text`, and a
children list that is not a proper list is `children` at its node. No operation of a valid tree exceeds one 64 KiB update
of the web, since the generator checks every kind's largest `insert`
against it ([design-web.md](design-web.md#uis-the-browser-renderer)); a
larger picture goes in a draw window.

A node's **identity** across trees is its parent's identity, its kind,
its fixed properties, and its `key` when present or its index among its
siblings otherwise, React's rule. Keys are unique among one node's
children, not across the tree: the same key under two parents names two
nodes. A node therefore keeps its parent, its kind and its fixed
properties for its whole life. A tree that moves a subtree to another
parent, or changes a node's kind or `secret`, removes the old node and
inserts a new one, as React remounts, and the new node starts with no
kept state; so `move` names no parent, and no operation can make a node
its own ancestor.

A tree states meaning, not appearance: what each node is, its values and
the events it takes; layout properties are hints each renderer reads for
its medium. A property the tree sets is authoritative; a state property
it omits keeps the value the server holds for the node, which is the last
value the tree set or the user made through the renderer, whichever came
later. That one rule is the whole protocol for controlled and
uncontrolled widgets. A kept value that no longer fits the node's new
properties, a `value` outside a new range or a `selected` past the end of
new `items`, is dropped. Presentation state, a `scroll`'s offset, an
`input`'s cursor and the focus, is each renderer's own, kept for its
medium and never part of the tree or the server's state.

An event fires only when the node carries its event property. Its detail
is `click` for `on_click`; `{change, V}` and `{submit, V}`, `V` the
node's new state value, for `on_change` and `on_submit`; and `{select,
Type, Value}` for `on_select`, taken from the node's `present` property
by the server, and only while its status is `ok` or `partial`, so a
renderer reports which node was clicked and never a value. A renderer
reports every change of a state property, whether or not the node takes
`on_change`, so the server keeps what the renderer shows.

An `input` with `secret => true` shows its text as marks. It has no
state: the tree cannot set its text, its text is never kept, by the
server or by a renderer, and it reaches the application only as
`{erx_secret, Text}` in place of `V`, which every printer shows as
`[secret]` ([Attributed text](design-live.md#attributed-text)). To clear
one, the application gives it a new `key`. Content an application draws
itself, acme-like, is a window of its own beside the widget window.

**The realised tree and its one difference.** `erx_ui_model` holds the
realised tree, a tree whose nodes carry their `node_id()` and the
properties a renderer shows, and four pure functions do all the tree
work:

```erlang
-spec pair(Realised, tree(), Next :: node_id()) -> {Realised, Next :: node_id()} | {error, limit}.
-spec delta(Realised, Realised) -> [diff_op()].
-spec apply_ops([diff_op()], Realised) -> {ok, Realised} | {error, term()}.
-spec hit(Realised, node_id(), Event :: atom(), Value :: term()) ->
          {fire, Term :: term(), Detail :: term(), Realised} | {keep, Realised} | drop.
```

`pair/3` gives each node of a valid tree its number: a node whose
identity matches a realised node keeps that node's number and kept state;
any other node takes the next number. `delta/2` turns one realised tree
into another numbered from it: a `remove` for each topmost node of the
first missing from the second; then, in the second's depth-first order,
an `insert` for each new node, a `move` for each child outside the
longest run of its parent's children that kept their order, and a `set`
for each node whose properties differ; then `commit`. An `insert` or
`move` places its node directly after its previous sibling in the second
tree, or first when it has none, and its index is a position among the parent's children as they
stand when the operation applies, the moved node taken out first, so a
renderer applies each operation as it reads it and every prefix of a
delta applies on its own. Since identity
fixes a node's parent and kind, `delta/2` compares nodes by number and
never searches for a subtree. `hit/4` checks a renderer's report against
the realised node, records a state value except on a secret `input`, and
returns the application's term and detail when the node takes the event.
The widget server sends a renderer `delta(R, R1)`, `R1` the tree that
`pair/3` numbered from the realised tree `R`, and the web's browser
renderer sends the browser `delta(Sent, Pending)`
([design-web.md](design-web.md#uis-the-browser-renderer)), so the display
and the web share one difference, and its one property, `apply_ops(delta(A,
B), A) == {ok, B}`, covers both. Node numbers are never reused in a
window, so a late report from a renderer names the node it was made for
or none; a server that would number past 2^32 - 1 ends the window with
`{ui_down, Window, limit}`.

**The binary form.** A renderer outside Erlang receives the operations
and sends its reports in the binary form `ui.txt` declares
([Widget format](design-abi.md#widget-format)), from which the generator
produces a reader and a writer of both directions in Erlang, C and
TypeScript. That form never carries a `key` or an application's term:
an event property travels as the flag that the node takes the event, and
a `present` property as its status, its type and its canonical text from
`erx_present:text/2`. Its readers keep no state: no field's meaning
depends on an earlier message or on the node's kind, so each is fuzzed
alone.

### Presentations

A presentation type is an inspector path that the inspection schema
(`abi/inspection.txt`) marks `present`
([Inspection schema](design-abi.md#inspection-schema)). Everything about
the type follows from that path:

* its **value** is the path's variable segments: the one segment's value,
  or the tuple of them in order when there are several;
* its **canonical text** is those segments written as a path's text
  writes them, a pid as `D.N.S`, an integer in canonical decimal and a
  text in `/proc`'s name encoding, joined by `/`;
* its **grammar** is the path reader of `erx_schema` over those segments,
  so `parse(Type, text(Type, Value)) == {ok, Value}` holds because the
  path's writer and reader are inverses, which the reader's fuzz target
  and round trip already check;
* the **inspector path** it names is the marked path with the value in
  its variable positions.

A pid's text reads back only while the runtime can name the pid: a pid
of a domain the runtime is not connected to, or one `list_to_pid/1`
would write back as other text, parses as `error`.

| Presentation | Marked path | Value | Text |
| --- | --- | --- | --- |
| `pid` | `processes *proc_id` | `{pid, 3, 45, 0}` | `3.45.0` |
| `domain` | `domains *domain_id` | `3` | `3` |
| `module` | `domains *domain_id modules *module_name` | `{3, <<"lists">>}` | `3/lists` |
| `budget` | `budgets *budget_id` | `7` | `7` |
| `group` | `groups *group_id` | `2` | `2` |
| `program` | `domains *domain_id programs *program_number` | `{3, 1}` | `3/1` |
| `device` | `devices *device_name` | `<<"uart0">>` | `uart0` |

A mark sits only on a declared path, so `program` and `device` arrive
with the declarations of their paths. A value that names no inspector
path, a file's path, a hash, a principal or a qid, is not a presentation
and prints as text. A pid's text is the path's `D.N.S`, not `ps`'s
`<D.N.S>`, whose `<` and `>` are rc's redirections and would not survive
a click into the command line.

An attribute's value is shown as a presentation when its type is the
variable segment type of a presentation of one segment, and the generator
refuses two such presentations over one type, so which values are
presentations is a fact derived from the schema: a process's
`group_leader`, of type `proc_id`, shows as a pid presentation, and a
budget's `domain`, of type `domain_id`, as a domain presentation. A value
of a presentation of several segments, a module or a program, is made by
the code that knows the parts, as `erx:ps()` names a program.

The generator emits `erx_present:text/2`, `erx_present:parse/2` and
`erx_present:path/2`; `uri/2` and `parse_uri/1`, which write and read
the link below; `type/1`, which reads a presentation's name from input
without making an atom; and `marks/0`, the table of names and marked
paths. It emits the same marks into the web client. `parse/2` and
`parse_uri/1` read untrusted text and have a fuzz target. A command
declares the types of its arguments with `-erx_args([pid, ...])` beside
`-erx_needs`, from the presentation names, and the catalog carries them
([Interfaces](design-shell.md#interfaces)).

At a terminal a presentation is the text, wrapped by `erx_render` in the
OSC 8 hyperlink sequence that xterm, iTerm2, kitty and WezTerm display
as a link and other terminals ignore:

```text
ESC ] 8 ; ; erx:TYPE/TEXT ESC \  TEXT  ESC ] 8 ; ; ESC \
```

`TEXT` is the canonical text after the line escape, and the URI's `TEXT`
is the same text with every byte outside `A-Z a-z 0-9 _ + , : = @ - . /`
written as `%` and two hexadecimal digits, the encoding of `/proc`'s
names with `.` and `/` kept, so the sequence is ASCII and holds no
control character. The
renderer emits links only when the tty's terminal declares them:
`erx_term` sets the `TERM` of the shell it starts, and the host tool's
`console` the session's, to `xterm`, whose entry in erXos's termcap lists the boolean
capability `links`, which `erx_render` consults through `erx_termcap`;
the serial console's `vt100` entry does not
([TERM and termcap](#term-and-termcap)).

## Algorithms and behavior

### The display device

A display driver is an Erlang process over the device NIF, a
`gen_server` that implements `erx_display`'s one callback and answers
in its `handle_call/3` the two requests the behaviour module defines:

```erlang
-callback info(Driver :: pid()) -> #{width := pos_integer(), height := pos_integer(),
                                    chan := chan(),
                                    screen := erx_memdraw:image(), % the screen image
                                    partial := boolean(),   % whether a frame takes rectangles
                                    direct := boolean()}.   % whether a frame takes a client's buffer
-spec flush_request(Driver :: pid(), Rects :: [rect()], Image :: erx_memdraw:image()) ->
    gen_server:request_id().    % sends {flush, Rects, Image}
-spec power_request(Driver :: pid(), Level :: on | dim | off) ->
    gen_server:request_id().    % sends {power, Level}
```

`erx_screen` hands `info/1` the driver's process. The two requests are
functions of `erx_display`, not callbacks: the module builds the one
term each sends, so every driver answers the same terms and the rule
that `erx_screen` alone sends them is a check over calls of two named
functions ([Chokepoints](#chokepoints)). A driver answers any other call
with a refusal, so no process that reaches it ends it.

`info/1` names the **screen image**, an `erx_memdraw` image of the
display's size and channel over memory the driver chose: the backing of
a virtio-gpu resource, which is a region of memory the device's record
holds in the NIF ([design-runtime.md](design-runtime.md#the-device-nif),
Regions); or, for a firmware framebuffer or a panel on a serial bus,
memory of the driver's own. `erx_screen` composes into it,
and nothing else writes it.

`erx_display:flush_request/3` sends the driver one frame, the rectangles that
changed and the image to read them from, and returns at once with the
request's id, as `gen_server:send_request/2` does; the driver makes the
device show the rectangles, and its answer, `ok` or a refusal, arrives as
a message that `gen_server:check_response/2` reads, or the request ends
with the driver. It is the one way a frame reaches a driver, so every
driver is driven alike, and `erx_screen` alone calls it. A driver
answers it in its own way: a virtio-gpu driver posts a
transfer and a flush for each rectangle on its control queue and parses
the device's responses in Erlang with binary matching; a firmware
framebuffer driver stores the rectangles' rows from the screen image into
the framebuffer, which is device memory, with aligned 32-bit stores
(`erx_memdraw:store/4`), at the firmware's stride; a panel driver on a serial bus sends a window-set command
and the rectangle's bytes, read from the image and converted to the
panel's channel by `erx_memdraw` in the copy. It answers when the device
has taken the rectangles, and that answer is the one thing the driver
promises, since it is the point after which the device reads nothing of
the image again until the next flush: a virtio-gpu driver sends the
frame's last command with `VIRTIO_GPU_FLAG_FENCE` and answers at its
response, which the device sends only once it has processed every
command before it; a panel driver answers at the last byte on the bus;
a firmware framebuffer driver answers once the rows are stored, since
its device scans the framebuffer all along. The answer is also what paces a
client, so a client is paced to the device where the device has a
completion, and to the copy where it has none: on a firmware
framebuffer a client that presents as fast as it is answered presents
as fast as `erx_screen` copies, unless the platform's driver can wait
for a vertical blank, which it then does before it answers.

The display drivers are the display device class's driver application,
`erx_fb`, one application per device class as every driver's is
([design.md](design.md), the tree layout). The virtio-gpu driver is the
process `erx_virtio_gpu`, registered as `erx_fb`, over its pure core
`erx_virtio_gpu_core`, which builds every request, holds every answer to
its request and decides the conversation: the bring-up asks one request
at a time, as FreeBSD's `vtgpu_attach` does (the display's size, the
screen image's region, a 2D resource of that size, its backing, which is
the region, and scanout 0), and each flush and each request of the
bring-up runs as a frame, posted in order and done only when every
request is answered and checked. The process performs what the core
asks and keeps the state between calls. During a flush, an answer that
fails its check, a broken queue or a frame that the device does not
finish within its deadline ends the process, and its restart resets
the device. A failure during the bring-up leaves no process, so the
domain runs without a screen.

The firmware framebuffer's driver is the process `erx_firmware_fb`,
registered as `erx_fb`, over its pure core `erx_firmware_fb_core`. Its
start takes the domain's framebuffer record
([design-device-tree.md](design-device-tree.md#facts-into-records)),
whose format names its channel as Plan 9 names one, highest bits
first; refuses a record whose format `erx_chan` does not take, whose
depth is not 16, 24 or 32 bits, or whose first byte or stride is off a
4-byte boundary or whose stride is shorter than a row rounded up to
4 bytes; maps the framebuffer with `erx_device:framebuffer/0`
([design-runtime.md](design-runtime.md#the-device-nif), The
framebuffer); and allocates the screen image in its own memory. A
frame's rectangles, clipped to the screen, are stored into the
framebuffer by `erx_memdraw:store/4`, which checks the layout and every
rectangle before its first store and widens each row to whole 32-bit
words. The framebuffer is device memory, which takes no unaligned
access, so nothing composes into it: the screen image is the copy's
source, and the copy costs one pass over the changed rectangles
beside the composition. A restart maps the same framebuffer and
allocates a new screen image, which `erx_screen` repaints. Since its
frames are stores the CPU makes, a refused record or a failed step is
one line and no process, as for the virtio-gpu driver, and the domain
runs without a screen. With no display record at all the supervisor
starts no driver and logs one line.

The image is the screen image, or, for a driver whose `info/1` reports
`direct`, a client's buffer that covers the screen ([The screen and its
one path to the device](#the-screen-and-its-one-path-to-the-device)). A
panel driver reads its bytes from whichever image it is handed. A
virtio-gpu driver whose device is confined keeps a second resource whose
backing is the client's buffer, mapped read-only into the device's DMA
window through the display's own read-only capability to the pixel area,
and sets the scanout to it. A driver whose device reaches only memory of
its own, an unconfined device or a firmware framebuffer, reports
`direct` false and is handed no image but the screen image.

The driver reads an image only while it holds the frame, until it answers. Every offset
into an image, from the stride, the row and the column, is computed with
checked arithmetic against the image's length, and every rectangle is
clipped to the image before it is read. The screen image's memory
belongs to the device's record in the NIF or to the device itself, so it
survives the driver's crash; the driver's restart resets the device and
creates the scanout again, and `erx_screen`, which monitors the driver,
repaints the screen from its windows' buffers.

Input drivers are Erlang processes over the device NIF too, and each
sends its device's records to the input router, `erx_winfs`
([Input events](#input-events)). The virtio-input driver's pure core,
`erx_virtio_input_core`, parses the device's event records, and reads
from the configuration the one fact the driver's fold needs: the ranges
of the device's two absolute axes, or `none` when it has none. The
configuration space is the registers of peripheral `VIRTIO_INPUT`
([design-runtime.md](design-runtime.md#the-device-nif)): for each axis the
driver writes the one-byte `select` (ABS_INFO) and `subsel` (the axis's
evdev code), the only fields it may write, then reads `size`, `abs_min` and
`abs_max`, all between two equal reads of the configuration generation.
It does not decide what kind of device it
drives: a device with keys and axes sends both. The fold turns the
events of each update, those up to `SYN_REPORT`, into records, and
keeps of an update only what it has not yet sent: the sum of its
relative moves, its last absolute position and the sum of its wheel
steps, never its events, so its state has the same size however long
an update runs. A key's edge is sent as it arrives, evdev's repeat
value dropped, after what the fold keeps, so a press lands where the
events before it in the update put the pointer; `SYN_REPORT` sends what
is kept. When an event would take a sum past a record's range, the sum
is sent as it stands with all else kept, and a new sum starts at that
event, so no sum overflows and no movement is clamped away; a wheel
event's own value is clamped
to a record's range first. An absolute position is each axis clamped
to its range and normalized across it as `(V - Min) * 65535 div (Max -
Min)`; the core takes a range only with `Min` below `Max`, and a device
that lacks either axis, answering its `ABS_INFO` with size 0 (virtio
1.2, section 5.8.5.2), has none. The core reads a configuration answer
by its `size` alone, as section 5.8.5.1 asks, since QEMU's reads as
zeros, header included, for a query it has nothing for ([facts
record](research-virtio-input-qemu.md#configuration-space), fact 10).
What an update kept is sent in one order, the relative move, the
position, the wheel steps, both at `SYN_REPORT` and when an event would
take a sum past its range. The position
outlives its update, since evdev reports an axis only when it changes,
and it is first sent once both axes have reported: `ABS_INFO` carries a
range but no current value ([facts record](research-virtio-input-qemu.md#what-the-devices-declare-and-send),
fact 20; virtio 1.2, section 5.8.4), so until then the core has no
position it could send but a made-up one. An absolute event of a device
with no axes, and every event the core does not use, is dropped and
counted. At `SYN_DROPPED` the fold drops what it keeps and forgets the
position, which the lost events may have moved and no configuration
read can restore, sends `release`, and ignores every event up to and
including the next `SYN_REPORT`, since those end an update whose start
is lost; it folds the events after that report as usual. A key
held through the gap is up for the router until it goes down again,
and its own up before then is one the router drops. A touch
controller's, an encoder's and a keypad's drivers send the same
records from their buses, with evdev's codes. Each driver is a row of
the device table.

The virtio-input driver, `erx_virtio_input`, is one process for each of
the display domain's `input virtio_input` device records, started by the
display's supervisor after the display driver and the screen, so an
input driver's restart touches neither. Its bring-up is the virtio
driver's sequence: open, identify, the event queue, negotiate, the
configuration's reads, the line, and every buffer of the event queue
posted. It sends its records under its device record's PATH, the
device-tree path the board's device table gives the transport
([design-stopgap.md](design-stopgap.md#device-records)), never under the
device's own `ID_NAME`: the path is the table's, fixed and known to the
manifest before boot, and a device's name is text the device writes,
untrusted and the same for every QEMU keyboard ([facts
record](research-virtio-input-qemu.md#what-the-devices-declare-and-send),
fact 21), so the driver never reads it.

**Input waits at its source.** `erx_winfs:input/2` returns once the
router has stepped the record ([The input router](#the-input-router)),
so a driver has at most one record in the router's mailbox, and it
gives its device back the buffers of the events it folded only after
their records are routed. The driver keeps every entry of the event
queue posted but those whose events it is folding, and posts each buffer
again as soon as its records are routed: QEMU's device delivers an
update only when it has a buffer for each of its events, its
`SYN_REPORT` included, and otherwise drops the whole update and sends no
`SYN_DROPPED` for it ([facts record](research-virtio-input-qemu.md#delivery-of-an-update),
facts 3 and 4; virtio 1.2, section 5.8.6.2), so an update longer than
the buffers posted never arrives. A device that sends faster than the
router routes therefore fills the event buffers its driver posted, a
fixed number, 64 on QEMU (facts record, fact 7), and drops what it
cannot deliver a whole update at a time, never part of one; the display
holds none of it. The router never waits on a source or a window,
so a source waits only for the steps of what is ahead of its record.

A device in another domain, such as a touch controller on a bus the
devices domain holds, is served by its driver there as a file of
records, in the binary form `abi/formats/input.txt` declares
([Input records](design-abi.md#input-records)), in a tree
of that domain which the manifest grants the display domain read-only,
an instance of `files`. A granted tree may hold several such files, as
a USB controller's domain serves one for each of its input numbers
([design-usb.md](design-usb.md#hid-reaches-the-display)); the display
starts one reader for each file the tree holds when the grant arrives,
and the set does not change while the serving domain lives, so the
router's sources stay fixed by the manifest. Each reader is the
source of its file's records: it decodes each read with
`erx_input_codec:decode/1`, which holds each record to the bounds of
`record()`, drops and counts one outside them, and gives back the bytes
of a record the read ended inside, which the reader puts before its next
read; it ends when the file ends or a read fails, so the router releases
what that device held. It has one
read outstanding, of at most the file protocol's 64 KiB, and makes the
next only once every record of the last has been routed, so what the
serving domain sends faster than the router routes waits in that
domain, and the display holds at most one read of it. Such a
domain has the reach of a person at the display, and the trust table
of [design.md](design.md) gives it a row of its own.

### Windows and the window system

`erx_winfs` is the one `erx_fs` server of a display and the window
system's state: it keeps the window table, asks the policy every
question of geometry and input, and routes input. Each client's grant
is rooted at the client's directory and is minted, with its quotas as
its parameters, when the domain service asks for it, on the manifest's
facet row that grants the display to a configured domain or to the
session template the session was made from ([Facets a configured domain
serves](design-system.md#facets-a-configured-domain-serves)). One
parameter no facet row sets: `session`, which every mint carries from
the domain service's record of the grant. It is a parameter the domain service
computes at the mint ([design-system.md](design-system.md#facets-a-configured-domain-serves),
"Parameters the domain service computes at the mint"). The record's **session
mark** is fixed when the session that a start row's keeper started on
this display reports ready, is set on that session's grant on this
display and no other, and is copied into every mint of the grant, the
first and each after the display domain's restart
([Facets a configured domain
serves](design-system.md#facets-a-configured-domain-serves)), so that
grant is the **display's session** on every incarnation of the display
([A display's session](#a-displays-session)). The
introduction that precedes the mint makes the connection and, with it,
the client's pixel area ([The pixel area](#the-pixel-area)), which
`erx_winfs` opens for the grant. `mkdir` makes a window: the server asks the policy for a
rectangle and a state, starts the window process, linked to the server,
and records the window with the `mkdir`'s `Owner` as holder, monitored.
`erx_winfs` knows every window's owner, so no field of shared memory
decides who may do what. A holder's pid is never shown in any file a
client reads: `ctl`, `wctl`, `label`, the records of `mouse` and `kbd`
and the directories' listings carry none.

`erx_wm` is a pure policy module behind one behaviour, called only by
`erx_winfs` and, for `input/4`, by its routing core `erx_input`:

```erlang
-callback init(Config :: map()) -> State.
-callback place(Request :: new | {move, rect()} | {resize, rect()} | hide | show | top | bottom,
                Window :: window_id(), Windows :: [window()], Screen :: rect(),
                Session :: binary() | none, State) ->
          {ok, [window()], State} | {error, einval}.
-callback arrange(Windows :: [window()], Screen :: rect(), Session :: binary() | none, State) ->
          {[window()], State}.
-callback decorate(Windows :: [window()], Screen :: rect()) ->
          [{window_id(), [{rect(), color()}]}].           % borders, or []
-callback input(input(), Windows :: [window()], Session :: binary() | none, State) ->
          {{to, window_id(), input()} | {wm, term()} | {windows, [window()]} | drop, State}.
```

The table a policy sees and returns is in stacking order, topmost
first. `new` is asked with the new
window already in the table, its rectangle and state the policy's to
set. `erx_winfs` calls `arrange/4` after every change it makes itself,
a window's end or a change of the screen's size, so the table always
holds the policy's answer. The policy's state, from the manifest's configuration, which names no session, is threaded
by `erx_winfs` and by its routing core, `erx_input`, which alone calls
`input/4`: the overlapping policy keeps, for example, the buttons last
seen and the drag in progress. `input/4` is asked only about what
starts something: a key's down, and, while no button or touch is held,
a pointer event, a touch's down and a wheel step. A key's repeats and
up go where its down went, and every pointer event, touch and wheel
step of a **gesture**, from the first button's or touch's down to the
last one's up, goes where the gesture's first down went; a gesture the
policy took for itself, such as its menu, is asked of the policy to its
end ([The input router](#the-input-router)). `{windows, Table}` answers an
event that rearranges the table, such as a click that raises a window.

The **overlapping** policy, `erx_wm_rio`, keeps windows in a stacking
order, places a new window where the user drags a rectangle or at a
default, frames each shown window with a border whose colour marks the
window that takes the keyboard, sends pointer events to the window under
the pointer and key events to the current window, and reserves the right
button outside any window for its menu: resize, move, delete, hide, and
the hidden windows by label. The menu is the display's own and no
client's: `erx_wm_menu` draws it, each label through the line escape,
into an image of the display domain's own memory, which `erx_screen`
shows above every window as an overlay. It has no item that
starts a program, a terminal included: the display domain has no
authority to start one in a session, and a terminal opens its sibling
windows itself ([The terminal](#the-terminal)). The **single** policy,
`erx_wm_single`, shows one window at a time, gives it the screen's
rectangle and draws no decoration. `erx_winfs` passes every `place`,
`arrange` and `input` the directory of the display's session, or `none`,
derived at the call from its grants: the live grant most recently minted with
`session` set ([A display's session](#a-displays-session)), and which
window it shows is derived, never stored: from every window table
`erx_winfs` hands it, the shown window is the live window of that
directory with the lowest id. So the first window the session makes is
shown, and when it ends, the session's next oldest live window is shown
in its place, with no event of a window's end for the policy to miss.
Which session is the display's is decided by the start table and
carried by the mint, never by who opens a window first: while the
display's session restarts, another session that holds a grant on the
display opens only hidden windows, and the new session's grant is the
display's from its mint; while the display domain restarts, the
display's session's grant is minted again with the mark, so it is the
display's on the new incarnation too.

Every other window, a later window of that session or a window of any
other domain, is made and kept hidden: its `mkdir` succeeds, its
presents succeed and reach no pixel of the screen, its `wctl` reads
report it hidden, and its `mouse` and `kbd` receive nothing until it
is shown. While the display has no session, or its session has no live
window, the screen shows only the background `erx_screen` fills.

The policy refuses every `wctl` request with `EINVAL`, so no window
takes the screen by asking, and it delivers every event the router
asks it about to the shown window. A
`wctl` write is a `place` request, so a program can resize or hide its
window under a policy that allows it and gets `EINVAL` under one that
does not.

**The reserved chord.** A display's manifest entry may name a key chord,
the **secure attention chord**. The router keeps it, before any policy
is asked ([The input router](#the-input-router)), answering
`{wm, chord}` and delivering it to no window, so no client can read it
or wait for it, and no client comes to depend on receiving it. The
chord is the set of keys the entry names, by evdev code; it fires on
the down of one of its keys that makes the keys held, over every
device of the display, include that set, whatever other keys are held,
and that down, its repeats and its up reach no window. It opens
nothing: which trusted screen it brings up, a
login or a lock, is the login design's ([Risks and
decisions](#risks-and-decisions), 14).

After every change of the table, `erx_winfs` hands `erx_screen` the
**layout**: the shown windows in stacking order, each with its window
process, its rectangle and its decorations from `decorate/2`. The layout
is derived from the table, so `erx_screen` keeps nothing of it that it
could not ask for again. A window whose rectangle changed is told so by
`erx_winfs` and reports the new rectangle in `wctl`; when its size
changed, it sets `resized`, and its client, at the `r` record, draws at
the new size and presents. Until that present the window shows its last
buffer, placed at its corner and clipped to its rectangle ([The window
tree](#the-window-tree)), so a resize is never a hole on the screen and
never a wait.

Before it routes an input event, `erx_winfs` tells `erx_screen` of it,
which keeps the idle clock (Low power, below).

### The input router

`erx_winfs` routes input through one pure step, `erx_input`, the
router's functional core. It holds everything about input that outlives
one record: the pointer, the keys, buttons and touches held, the
gesture, the locks, each window's repeat and the reserved chord.
`erx_winfs` performs what it answers: it monitors a source at its first
record, delivers to window processes, and keeps one timer. A driver, or
a reader of another domain's device, calls `erx_winfs:input(Device,
Record)`, which returns once the router has stepped the record, so the
router knows each record's source, the caller, and each source has at
most one record waiting for the router ([The display
device](#the-display-device)). `erx_winfs` stamps each record, end and
tick with its own clock as it takes it, so the step reads no clock.

```erlang
-spec step(in(), view(), state()) -> {[out()], PolicyState :: term(), state()}.
-type in() :: {record, Source :: pid(), Device :: binary(), At :: integer(), record()}
            | {gone, Source :: pid(), At :: integer()} % the source's process ended
            | {tick, At :: integer()}                  % the timer fired
            | {screen, erx_wm:rect()}.                 % the screen, or its new rectangle
-type view() :: #{windows := [erx_wm:window()], session := erx_wm:session(),
                  policy := module(), policy_state := term()}.
-type out() :: {to, window_id(), input()} | {wm, term()} | {windows, [erx_wm:window()]}
             | {wake, At :: integer() | none}.
```

Its state, made by `new/1` from the manifest entry's layout, repeat
times and chord:

* the **screen**, the last rectangle `erx_winfs` was given, or none
  before the first, and the **pointer**, one position for the display,
  none while there is no screen;
* for each source, its device's name, the device-tree path its
  device record carries
  ([design-stopgap.md](design-stopgap.md#device-records)), and what it holds: each key with
  the runes and the modifiers of its down and the window its down went
  to, or none; each button; each touch slot;
* the **gesture**, while any source holds a button or a touch: its
  destination, a window, the policy or nowhere, fixed at the down that
  began it;
* the locks that are on;
* for each window that has one, its **repeating key**: the source and
  code of the key and the time it next repeats.

The buttons a pointer event carries are the union of the buttons every
source holds, with button 1 while any touch is held, and the modifiers
held, which select a layer, the union of the modifier rows of the keys
every source holds; both are derived at each step, never stored, so a
source's end changes them with nothing to clear. There is one modifier
state for the display, whichever keyboard holds the key, and a key
event's `Mods` are the runes of the modifier rows of the keys held.

The step's rules, by input:

* **Before the display has a screen** it has no window, since a `mkdir`
  then fails, and the step drops every record and counts it; a key held
  then is unknown to the router, and its up is one the router drops.
  The first `{screen, R}` puts the pointer at the screen's centre,
  `((X0 + X1) div 2, (Y0 + Y1) div 2)`, and each later one clamps the
  pointer into the new rectangle.
* **A pointer record** moves the pointer: a relative move adds its
  deltas and clamps the result to the screen, `X0` to `X1 - 1` and `Y0`
  to `Y1 - 1`; an absolute position scales to the screen, `X0 + X * (X1
  - X0 - 1) div 65535`, which lies inside it for every `X`. It answers a
  pointer event.
* **A button's edge** is a key record of a code that has a `button` row.
  A down of a button its source already holds, and an up of one it does
  not, are dropped and counted; otherwise the edge changes the source's
  buttons and answers a pointer event.
* **A touch** first moves the pointer to its scaled position. A down at
  a slot its source already holds, and a move or an up at a slot it does
  not hold, are dropped and counted; otherwise the slot goes down, moves
  or goes up, and the touch answers a pointer event, which is how a
  window's `mouse` reads a touch.
* **A gesture** begins at the down of a button or touch while no source
  holds either, and ends at the event after which none is held. The
  policy routes its first event, and its answer fixes the destination:
  `{to, W, _}` the window `W`, `{wm, _}` the policy, and `{windows, _}`
  or `drop` nowhere, so a click the policy answers with a new table,
  such as one that raises a window, gives no window any of that
  gesture. Every later pointer event and wheel step of the gesture goes
  to that destination: to the window as `{to, W, Event}`, except that
  while `W` is hidden only an event that lets go a button or touch `W`
  saw pressed reaches it, carrying only the buttons `W` saw that are
  still held, so a hidden window never hears of a press made after it
  was hidden; to the policy as a question of `input/4`, whose
  `{to, _, _}` answer is dropped and counted, so no window receives the
  rest of a gesture whose start it did not; or nowhere. Between
  gestures the policy routes each pointer event and wheel step.
* **A key's down**, of a code with no keymap row or of a key its source
  already holds, is dropped and counted, so a window never sees a key
  go down twice. Otherwise its runes come from the keymap at the layer
  the modifiers held select, and a lock's down toggles its lock. A
  modifier's or a lock's key types no rune: its down and up carry its
  rune as `Unshifted` alone, so a window reads them in `k` and `K`
  records with no `c`, and it never repeats. When
  the down makes the keys held, over every source, include every key of
  the reserved chord, the answer is `{wm, chord}`; otherwise the
  policy's `input/4` routes it. Either way the step records where the
  down went, `{to, W, _}` as the window `W` and anything else as none.
  A down that went to a window and types a rune becomes that window's
  repeating key, in place of the one before, at its time plus the delay;
  FreeBSD's evdev starts repeat at every down too, for its device
  (`sys/dev/evdev/evdev.c`, release/15.1.0, lines 707-713).
* **A key's up** of a key its source does not hold is dropped and
  counted. Otherwise the key leaves the source's state and its up goes
  to the window its down went to, whatever that window's state or which
  window takes the keyboard now; a down that went nowhere has no up to
  send. The up stops the repeat of the window its down went to, as
  evdev stops its device's at every up (the same lines).
* **A tick** sends, to every window whose repeating key's time is at or
  before the tick's, that key's repeat with the runes and the modifiers
  of its down while the window is shown, and moves its time one period
  on; a window whose time is later gets nothing, so a tick from a timer
  the step has since moved does nothing.
* **`release`, and the source's end**, send an up for every key the
  source holds to the window its down went to, each stopping that
  window's repeat as an up does, and let go of the source's buttons and
  touches, with one pointer event to the gesture's destination when the
  buttons changed, which ends the gesture when no source holds any; the
  end also forgets the source. FreeBSD's evdev releases stuck keys the
  same way, with an up for every key held (`evdev.c`, lines 915-919).

Whenever the earliest repeating key's time changes, the answer carries
`{wake, At}`, or `{wake, none}`, and `erx_winfs` replaces its one timer
with it.

So the policy is asked only about what starts something, a key's down
and a gesture's first event, and about what a pointer does between
gestures, and what follows a down goes where the down went. From this
each guarantee holds by construction:

* **The pointer lies inside the screen**: it is written only by the
  placement, the clamp and the scaling above, whose ranges are the
  screen.
* **What follows a down goes where the down went.** While a window
  lives, a window that receives a key's down receives its up when its
  source sends the up, sends `release` or ends, and a window that
  receives a gesture's first event receives the event that ends it: an
  up and a gesture's events follow the record of their down, not the
  policy; a key, button or touch leaves the state only by its up, by
  `release` or by its source's end, each of which answers its up; and a
  doubled down and an unmatched up or move are dropped. A driver's
  restart is a new process, so a new source, and the old one's end
  releases what it held. What ends a window cancels its input: a
  window's end, and the display's restart, which ends every window and
  the router, deliver no up, and the window's client sees its files end
  instead. A full `mouse` or `kbd` queue drops its oldest records, ups
  among them, and the next record restores the state, since every `m`
  record carries the buttons held and every `k` and `K` record the keys
  ([The window tree](#the-window-tree)). Window ids are never reused, so
  an up for a window that ended names no other. A source that never
  sends the up keeps the key held, as a person holding it down would.
* **A hidden window learns only that what it saw go down went up**: of
  what follows its downs, it receives only ups and the events that let
  a button or touch go, with no repeat, no move and no press.
* **A window's repeat is its own**: its repeating key is set, stopped
  and timed only by keys whose downs went to it, so typing in another
  window, or a key withheld for the chord, neither starts, stops nor
  delays it, and it repeats only while the window is shown.
* **The reserved chord reaches no window**: it is decided before the
  policy is asked, so no policy can deliver it, and its key's repeats
  and up follow a down that went to no window.
* **What input holds is bounded, from the device to the window's
  file**, because each stage holds a bounded amount and the stage
  before it waits:
  * a device's events wait in the event buffers its driver posted, and
    another domain's in that domain, since a driver or a reader takes
    more only once its last records are routed ([The display
    device](#the-display-device)); a fold holds one update's sums and
    position, and a reader one read of at most 64 KiB;
  * the router's mailbox holds at most one record and one end of each
    source, its one timer's ticks, the screen's changes, which
    `erx_screen` makes one call at a time, and the file protocol's
    requests, which the protocol's lanes bound;
  * the router's state holds for each source at most
    `ERX_EVDEV_KEY_MAX` + 1 keys and buttons and 10 touches, one
    gesture, and one repeating key for each window, and the sources are
    the display domain's input drivers and its readers of other domains'
    devices, one for each row of the device table and each granted
    device file;
  * the router sends to a window process and never waits on it: a
    record answers at most one event, and `release` or a source's end
    at most one up for each key it held and one pointer event; the
    window process takes each event into its `mouse` or `kbd` queue,
    of at most 4 KiB, past which the oldest record is dropped and
    counted ([Windows and buffers](#windows-and-buffers)), and waits on
    nothing while it does, since it holds a client's `ctl` write
    without waiting ([The window process](#the-window-process)), so its
    mailbox drains as `erx_screen`'s does (G3).

### The screen and its one path to the device

`erx_screen` owns the path from windows to the panel. It is the one
process that reads clients' buffers, the one that writes the screen
image, and the one that calls the driver. For each shown window it keeps
an image over the buffer of the window's last present, made with
`erx_memdraw:wrap/4` from the client's pixel area. Its decisions are a
pure core, `erx_screen_core`, which from a layout tiles the screen,
giving each pixel one source: a window's buffer, a decoration, the
overlay or the background. A window's decorations lie over its own
buffer, later ones over earlier, and a window with its decorations lies
over every window below it; a window's visible region is its share of
the tiles. From an old and a new layout the core returns the decorations
and background to fill and the area of each window to copy; each covers
exactly the pixels whose content changed. Fills of one colour show the
same content, and a window shows the same content only from the same
window process at the same origin of its rectangle, so neither a moved
window nor a window id shown again passes for what the screen holds.
From a present it returns the rectangles to copy from the window's
buffer. The core works in screen coordinates; `erx_screen` places a
window's buffer on the screen with its top left corner at the window's.
It cuts the screen into horizontal bands at the edges of every rectangle
and sweeps each band, so a layout of L rectangles costs O(L^2 log L) to
tile and two tilings compare in time linear in their size. It is tested
exhaustively on the host over small screens and layouts.

**A present** reaches `erx_screen` from a window process through
`erx_screen:present_request/2`, after the window has checked the
command ([The window tree](#the-window-tree)). The window sends the next
only after the answer, so a window has one present in flight. The
screen copies a present's rectangles with draw(2)'s `S`, not `SoverD`:
nothing is kept beneath a window, so the buffer's pixels replace the
screen's and its alpha blends with nothing stale.

**A frame** is what `erx_screen` hands the driver in one
`erx_display:flush_request/3`. `erx_screen` never waits on the driver: the request
returns at once, and `erx_screen` takes the answer, or the driver's end,
as a message, so its mailbox keeps draining while the device works.
What arrives meanwhile changes **pending state**, of which there is a
fixed amount and no queue:

* a layout from `erx_winfs` replaces the pending layout, so any number
  of `wctl` requests, window ends and new windows between two frames
  cost one plan;
* a present is held as its window's one waiting present, a window
  having at most one in flight;
* a window's end, which `erx_screen` learns by its monitor on the
  window process, drops that window's waiting present and its image of
  the buffer, and the next layout no longer names the window;
* an input notice resets the idle clock (Low power, below).

So what `erx_screen` holds while the driver is busy is one layout and at
most one present for each live window, bounded by the windows quotas of
the display's grants, whatever clients do and however long the device
takes. When the driver answers, `erx_screen` takes what is pending:

1. for each window with a waiting present, the window's buffer becomes
   the presented one;
2. the core plans the frame from the pending layout: the fills, and for
   each window the rectangles to copy, clipped to its visible region and
   to its buffer;
3. `erx_screen` copies each rectangle from the window's buffer into the
   screen image with `erx_memdraw`'s draw, fills the decorations and the
   background, and hands the driver one list of rectangles, or the whole
   screen for a driver whose `info/1` reported `partial` false, read
   once at start;
4. when the driver answers that frame, `erx_screen` answers every
   present of it, and starts the next frame if anything is pending.

Between handing the driver a frame and its answer, `erx_screen` writes
nothing into the screen image, and the frame's request holds its own
reference to each image it names, so the driver reads only memory that
nobody in the display writes and that stays mapped until it answers.

So a present is answered when the device has taken the frame that shows
it, a client that presents as fast as it is answered draws exactly one
frame for each frame of the device, and a client that floods waits
behind one frame of every other window, not in front of them. A hidden
window's present changes its buffer, copies nothing and is answered at
once.

**Composition paths.** The plan gives every tile a path. There are two:

* **Copy.** `erx_screen` copies the window's pixels into the screen
  image, one copy of each changed pixel, and the device shows the screen
  image. Every device and every layout has this path.
* **Direct.** When the layout shows one window whose rectangle is the
  screen's, with no decoration and no overlay, whose buffer has the
  screen's size, and the driver reports `direct`, nothing is copied:
  `erx_screen` hands the driver the window's buffer itself, and the
  device reads the client's memory. This is a kiosk's path on a panel
  and on a confined virtio-gpu. When the layout leaves the direct path,
  the screen image holds none of the window's pixels, so `erx_screen`
  copies the whole of every shown window. Entering it pushes only what
  the device did not already show from the window.

Which path a frame takes is `erx_screen_core`'s answer from the layout
and the driver's `info/1`, and no client can tell: the files, the
command and its answer are the same. A device with hardware planes or a
GPU adds a path to this list and a case to the plan ([Graphics
hardware](#graphics-hardware)).

**Geometry.** When the layout changes, `erx_screen` fills the
decorations and background the plan names and copies, from the buffers
it already holds, the part of each shown window that the screen does not
already show from it. It asks no window and no client for anything, so a
window drag costs its clients nothing and waits on none of them. A copy
reads a window's buffer as it stands: a client with one buffer that
draws a frame in several steps can be shown part-way through, as on
Plan 9, and a client with two never is ([The pixel
area](#the-pixel-area)). The same copy of every shown window, whole, is
the **repaint** that follows a driver's restart and a wake. There is no
other repaint (G6).

**The overlay.** The overlapping policy's menu is an image of the
display domain's own memory. `erx_wm_menu` draws it and calls
`erx_screen:overlay(Image, Rect)`, or `overlay(none)`, and waits;
`erx_screen` reads the image only inside that call, copying it to an
image of its own, so the menu's process writes nothing that is being
read. The layout places the overlay above every window.

**Who reads what, when.** A client's buffer is written by its client
and, in the display domain, read only by `erx_screen` and, on the direct
path, by the driver while it holds a frame. The screen image is
written only by `erx_screen` and read by the driver only while it holds
a frame, during which `erx_screen` does not write it. Requests go one
way, window to `erx_screen` to driver, and `erx_screen` sends a window
nothing but one asynchronous message, the request to present again
after `erx_screen`'s own restart, so no cycle of waits exists. A
window's call to `erx_screen` waits without a timeout, until the answer
or `erx_screen`'s end, and `erx_screen`'s request to the driver is
answered or ends with the driver, without blocking `erx_screen`. An
image is a NIF resource whose memory, or whose
mapping, its destructor releases when no term refers to it, and
`erx_memdraw` has no other way to release one: a window's end drops
`erx_screen`'s image of its buffer, and a reference the driver still
holds, in a frame it has not answered, keeps the area mapped until it
does. A client's pixel area is deleted only after the display has
unmapped it. So no reader in the display domain reads freed memory, by
construction, and what a client writes while it is read changes that
client's own pixels and nothing else (G2).

**Low power.** `erx_screen` keeps the idle clock, the time since the last
input event `erx_winfs` told it of, and a display's manifest entry names
its idle policy: after a stated idle time `erx_screen` asks the driver
for `dim`, then `off`, each with `erx_display:power_request/2`, whose
answer arrives as a frame's does. While the panel is off, presents change their
windows' buffers and are answered without a copy, and nothing is pushed;
the next input event turns the display `on` and repaints. The idle clock
is a timer for power, not for drawing.

### The window process

Each window is one process, `erx_window`, which serves its `ctl`,
`mouse`, `kbd`, `wctl` and `label` files and holds its pending input and
its last present. A write to `ctl` reaches it as a binary, which
`erx_winctl:parse/1` reads and `erx_window` checks against the client's
pixel area ([The window tree](#the-window-tree)); it then calls
`erx_screen:present_request/2`, which returns at once as
`erx_display:flush_request/3` does, keeps at most one present in flight
to `erx_screen` and holds its client's write until the answer, so the
window still takes input while it waits; it then records the buffer as its last present
and answers the write. A second `ctl` write that arrives while a present
is in flight is held too, and queues behind it. When `erx_screen` ends
while a present is in flight, the held write is answered `EIO` and the
last buffer stays as it was. A refused line fails the write with `EINVAL`,
and the display domain's log records the window and the reason. Input
from `erx_winfs` is encoded into `mouse` and `kbd` records and queued,
within the bounds of the data model, until a read takes it; the window
keeps the `Unshifted` runes of the keys whose downs it received and
whose ups it has not, and the set of a `k` or `K` record is those with
the event's `Mods`. It waits on nothing while it takes input, so its
mailbox drains whatever its client does. When
`erx_screen` restarts, it asks every shown window to present again, as
it asks a window that a layout newly shows and whose buffer it holds no
image of, and
the window presents its last buffer, whole, as if its client had: a
request that arrives while a present is in flight waits for its answer
and then goes before any queued write, and one that arrives before the
window has a last buffer does nothing. A read of `mouse` or `kbd` takes
one whole record, waiting for one, and one whose count cannot hold a
record fails with `EINVAL`. A `label` write replaces the label whole,
and one at a nonzero offset fails with `EINVAL`, erXos's choice. The
window ends with its holder, its directory or its grant, and holds
nothing that outlives it: its buffer is its client's memory.

**The clipboard.** `/snarf` holds at most 1 MiB, and a write that would
take it past that is refused whole with `EFBIG`, leaving it as it was
before that write,
so nothing is ever truncated. It is one display's,
shared by every grant on that display whose facet row turns `snarf`
on, as X's selection is shared by a display's clients; `snarf` is off
unless the row turns it on (Security says with whom).

### The draw connection

A **draw connection** is a process of a client's domain,
`erx_draw_conn`, which executes Plan 9's draw messages for one window.
It owns the connection's images, `erx_memdraw` images in the client's
own memory, and its image 0 is an image over the window's buffer. Bytes
reach it from two callers and by one path: an Erlang client's `erx_draw`
calls hand it the messages they encoded, and a program's write to
`/dev/draw` reaches it through the session's export, which serves each
connection's `draw` and `ctl` as files
([Narrowing](design-files.md#narrowing-for-a-program)). Either way the
connection gets a binary, which `erx_draw_core:plan/2` decodes and
checks whole, message by message against the connection as planned so
far ([Draw messages](#draw-messages)). Its step takes the planned
connection and one decoded message and returns the next state and the
`erx_memdraw` operation to perform, or an errno from the refusals that
section lists. A failure fails the write with that errno, and the
session's log records the connection, the errno and the offset of the
message. The process performs the operations only after the fold has
consumed the whole write, so a failed write applies none of them. The
core is tested exhaustively on the host over small ids and rectangles.

The core's state is the part of the connection later messages read: the
images with their rectangles, depths, replicate bits and glyph records,
the bytes charged, and `op`. Image 0 is an image over the window's
buffer, with the window's size and the display's channel, and is made
anew over the buffer at the new size when the window is resized, keeping
the client's images; it is not charged to the connection's pixel quota,
which bounds what the client allocates: 64 MiB for a connection unless
its session's policy sets another, so one program cannot spend its
session's whole budget on images. An image's charge is a
function of the image, its pixel bytes and its glyph records each rounded
up to 4 KiB, so `f`, and an `i` that remakes a font cache, give back
exactly what was taken. A font cache holds its records as 16 bytes each,
so what the core holds is what it charged. Each `r` replaces what the one
before it left for reading, so a plan keeps only its write's last `r`.
Operations name images by id, and the draw connection maps ids to
its `erx_memdraw` images while it applies them in order. Every decision
that needs the connection is the core's: a `b` carries its clip
rectangle as devdraw's `rectclip` leaves it (a clip rectangle disjoint
from r stays as given), a `c` the replicate bit as it stands after it,
each drawing operation its compose operation, an `e` or `E` whether it
is an arc, and an `s` or `x` becomes one draw for `x`'s background and
one per glyph, the glyph's rectangle of the font cache as the mask,
clipped to the message's clip rectangle, as devdraw's `drawchar`
computes them. Those are the only coordinates the core derives, and a
message one of whose derived coordinates leaves draw(3)'s 32 bits fails
with `EINVAL`, so `erx_memdraw` receives only 32-bit coordinates. An `r`
rectangle that is inverted lies inside no image, and one that is empty is
refused as a `y` is; both fail with `EINVAL`.

Each operation goes to `erx_memdraw`, which computes the clipped
rectangle with `erx_draw_clip` from the destination's clip rectangle,
the source's and the mask's bounds and the operation's rectangle, and
runs `libmemdraw`'s primitive over it: `memimagedraw` for `d`, for `l`
with operation `S`, for each glyph of `s` and `x` with the glyph as
mask, and for `x`'s background; `memline`, `mempoly`, `memfillpoly`,
`memellipse` and `memarc` for the shapes; `loadmemimage` for `y`, and
`unloadmemimage` for `r`. A shape breaks into draws through `memdraw`,
`libmemlayer`'s entry point for an image that is not a layer, which
`erx_memdraw` defines as `erx_draw_clip` and `memimagedraw`, so every
pixel a shape touches is clipped as a `d`'s is; its temporaries (a
disc end's brush, an arc's wedge, figure and mask) are allocated for
the one call and freed by it, and an arc's cover only the columns the
destination shows. A shape runs on a dirty scheduler, since its cost
follows from its geometry, not from the pixels it writes; the dirty
schedulers are one pool for the client's runtime, so until a shape's work
is bounded one program's shapes can delay its own session's other dirty
work, and no other domain's (a residual in TODO.md). A shape whose
source is its destination reads it from a snapshot taken before the
shape, as a draw does. A shape that cannot allocate a temporary answers
`ENOMEM`, and may have drawn part of itself. Each operation returns the clipped rectangle it
touched, or `none` when it drew nothing: for a draw, the destination rectangle
after clipping; for a `y`, its rectangle. The draw connection unions those
into its 16-rectangle dirty list; `erx_draw_core` computes no dirty
rectangles. A `Y` message never reaches `erx_memdraw` as
compressed bytes: the codec decoded it with `erx_draw_image` while
framing it, and the operation it plans is the `y` load of the decoded
pixels. So `erx_memdraw` parses nothing a client wrote: it takes decoded
messages, rectangles and pixel rows, and a load is given exactly the
bytes of its rectangle. `erx_draw_image` is the one decoder of `Y`;
`libmemdraw`'s `cloadmemimage` is linked only into tests, as its oracle.
Every size, offset, stride and count `erx_memdraw` computes from a message,
and the draw connection's union of dirty rectangles, uses checked
arithmetic. The primitives read no global
state after their initialisation at load, which is checked when
`libmemdraw` is imported. An operation over more than 64 KiB of
destination pixels runs on a dirty scheduler, so a full-screen draw
never holds a normal scheduler. Fonts are the client's: `i` makes an
image it allocated a font cache and `l` copies a glyph's pixels into it
from another of its images, so a client's text is drawn from glyphs the
client loaded, and no domain renders text or reads a font for another.

**What a draw leaves.**
* A clip rectangle may be empty or inverted, which draw(3) checks neither
  of; a draw through one touches nothing. `erx_draw_clip` computes
  `drawclip`'s rectangles in 64 bits, so a draw rectangle or point
  anywhere in 32 bits clips without overflow.
* A mask that is the destination, or a replicated source that is, is read
  from a snapshot taken before the draw, so every pixel composes from the
  pixels as they were before the message. `alphadraw` itself buffers only
  a nonreplicated source that is the destination.
* The `x` bits of a pixel are undefined after a draw: a plain copy keeps
  the source's and `alphadraw` writes 0. Clients must not depend on them.

A flush `v` presents: the connection writes the window's `ctl` a
present of its buffer with the dirty rectangles, waits for the answer
and clears them, so a client that draws faster than the device shows
waits in its flush, as it waits in any write. A connection ends with
its window, or with the program or process it was opened for; its
images are resources of its process, and the runtime drops them when it
ends, however it ends.

**Reading pixels.** An `r` message queues the rectangle's bytes for the
next read of `draw`, at most 64 KiB at a time, as Plan 9 does.

### The terminal

`erx_term` is a user's terminal. It is a program of the user's session,
as xterm is a client of an X server and the master of a pseudo-terminal,
written as a supervised Erlang process in the session domain's runtime.
The display serves it a window as it serves any client and knows nothing
else of it. A terminal owns four things:

* **Its window**, which it makes with `erx_win` through the session's
  grant on the display ([A display's session](#a-displays-session)),
  with itself as the holder. So the window counts against the
  session's `windows` quota and its buffer against the session's pixel
  area, the window ends when the terminal ends, and the terminal ends
  when the session's grant does. The terminal draws into the window's
  buffer through a draw connection of its own and reads `mouse` and
  `kbd`, as any Erlang client does ([Erlang
  clients](#erlang-clients)).
* **Its glyphs**, from a subfont file of the session's release, which
  `erx_font` loads into a font cache image of its draw connection, so
  a terminal's text is drawn in its own session, as every client's
  is.
* **`erx_vt`**, the terminal's state: a pure function from that state
  and the bytes the tty sends to the next state and a list of effects
  ([The terminal emulator](#the-terminal-emulator)). The terminal is an
  xterm-compatible subset, named `xterm` as FreeBSD's console is; rio's
  mouse-driven text editing is a program's choice on top, not the
  terminal's.
* **Its tty**, which the session's terminal relay serves
  ([The tty](design-live.md#the-tty)). The terminal asks the relay for a
  new tty, as a program's `posix_openpt` makes a pseudo-terminal
  ([design-programs.md](design-programs.md#the-terminal)), becomes its
  master, and starts the session's command shell on it with
  `TERM=xterm`. A master in the tty's own domain exchanges the tty's
  five messages as plain Erlang messages, which are never dropped.

The terminal's work is the master's side of those messages:

* **Output.** On `{tty_output, N, Bytes}` it feeds the bytes to
  `erx_vt`, draws the rows that changed, flushes, and answers
  `{tty_taken, N}`, so a terminal that draws slowly holds its tty
  stopped and its writers wait, as at a serial line. A `{reply, Bytes}`
  effect goes back as `{tty_input, Bytes}`, and a `{title, Text}`
  effect is written to the window's `label`, which whoever draws it
  escapes (G5).
* **Keys.** Each `kbd` record goes through `erx_vt:key/2` and the bytes
  to the tty as `{tty_input, Bytes}`. `Ctrl-G` is a key like any other:
  a terminal is no console line and has no console menu. The terminal
  keeps two bindings of its own: Shift with Page Up and Page Down moves
  its view through the scrollback, and Ctrl-Shift-N, which it would
  otherwise send as Ctrl-N, opens a sibling window (below).
* **Size.** The window's size, from `wctl` at the start and after each
  `r` record on `mouse`, divided by the font's cell and held within
  [Bounds](#bounds), goes to `erx_vt:resize/3` and to the tty as
  `{tty_size, Rows, Columns}`.
* **The pointer.** A drag selects cells, and a selection is copied to
  `/snarf` when the session's grant carries `snarf` and kept inside the
  window otherwise; the middle button pastes through `erx_vt:paste/2`;
  the wheel moves the view through the scrollback; a click on a
  presentation is the action below.
* **Ending.** The terminal monitors the shell it started and ends when
  it ends, closing its window, as xterm does when its shell exits. When
  the window ends first, removed from the menu, by the end of the grant
  or with the display, the terminal sends `tty_hangup`, and the shell
  and its jobs get the hang-up, as when an xterm is closed.

A terminal shows its tty and nothing else, as xterm does: no log lines,
no console menu and no login. Log lines reach the console lines, the UART
and the host link, and the inspector
([The console](design-live.md#the-console)).

**Sibling windows.** On Ctrl-Shift-N a terminal asks its supervisor,
`erx_term_sup`, for another terminal on the same display: a new window,
tty and shell of the same session, beside the first, as rio's new window
runs a shell in its opener's namespace. Nothing outside the session can
start one. The display's menu has no such item, since the display has no
authority to start a program in a session, and a terminal's sibling is
charged to the session's quotas like any of its windows.

**Presentations in a terminal.** `erx_vt` parses the OSC 8 sequence
above as one of its control sequences, within 4 KiB and the grammar of
[Links and the input context](#links-and-the-input-context); a sequence
outside the grammar ends the open link and opens none. A cell written
while a link is open carries the link's id, so the text stays bound to
its type and value as the screen scrolls, until the cells are
overwritten or the link is evicted. The emulator's actions on a
presentation are two, and neither reaches a service (G4):

* a click sends the presentation's text to the tty as keyboard input,
  as a paste does, so it lands in the shell's command line or in whatever
  program is reading; the grammar admits no control character in the
  text, so a click can fill a line but never submit it;
* while the shell is editing a command whose argument types it knows,
  the shell writes through `erx_render` an **input context**, `ESC ] 8 ;
  ; erx:accept/TYPES ESC \` with `TYPES` a comma-separated list, followed
  at once by the closing sequence `ESC ] 8 ; ; ESC \`, so a host terminal
  that does not know the context sees an empty link. The emulator
  highlights the presentations of those types; a click on one inserts
  its text, and the shell clears the context, with an empty `TYPES`,
  when the line is submitted. The context comes from the catalog's
  `-erx_args` for the command typed so far. A shell without the catalog
  writes none, and the terminal shows links without highlights.

The shell parses what the click inserted exactly as it parses what the
user types, so a presentation cannot carry more than the keyboard
could. The same bytes over the host link reach the host's terminal
unchanged through `erx console`, which copies the tty raw, and a host
terminal that understands OSC 8 shows the link; `tools/erx` registers an
`erx:` URL handler only if the operator installs it, and that handler
runs `erx inspect` with the host session's own facets.

### The terminal emulator

`erx_vt` is the model of one terminal: a grid of cells, a cursor, the
modes programs set, a scrollback and the presentations on screen.
`erx_term` owns one `erx_vt` state, feeds it the bytes its tty sends,
draws the rows that changed and sends the tty what `erx_vt` says to
send ([The terminal](#the-terminal)). Everything a program can do to a
terminal window is decided by `erx_vt`, and `erx_vt` decides nothing
else.

**What it matches.** The terminal is the subset of xterm that the
programs erXos runs at a terminal use, and it calls itself `xterm`, as
FreeBSD's console vt(4) does in FreeBSD's `/etc/ttys`. The subset is the
union of five needs, each recorded against every row of the tables
below:

* **P, `prim_tty`**, in the mode erXos runs it: `init_ssh/3`, with `xn`
  set and no terminfo (`otp/lib/kernel/src/prim_tty.erl:306-330`,
  `:1395-1420`). With no terminfo, `io_ansi` falls back to the ANSI
  strings of its own table (`otp/lib/stdlib/src/io_ansi.erl:2611-2786`),
  so the line editor writes BS for one column left, LF for one row down,
  CSI A and CSI C for up and right (`prim_tty.erl:1008-1015`), CSI J to
  erase below (`:673`, `:741`), CSI H CSI 2 J to clear (`:904`), CSI I for
  a typed tab (`:1207`), SGR for the expansion's status line (`:630`) and
  BEL (`:902`), and it relies on the deferred wrap at the last column that
  termcap calls `xn` (`xnfix`, `:1164-1166`).
* **I, `io_ansi`'s functions** on erXos, which are the same fallback
  strings: cursor hiding, saving, the alternate screen, insert and delete
  of characters and lines, scrolling regions and SGR colours. Four of
  upstream's fallback strings are not the sequences they name, and
  erXos's OTP fixes them (Risks), so the tables hold only the standard
  forms.
* **T, toybox 0.8.15's applets**: cursor addressing, erase in line and in
  display, SGR, cursor hiding, save and restore, the cursor position
  report with which toybox measures the screen, and RIS for `reset`. The
  coverage test of [Verification](#verification-and-testing) checks this
  list against what the applets write.
* **V, `vttest`'s core**: its menus 1 (cursor movements), 2 (screen
  features), 3 (character sets: US ASCII, DEC Special Graphics and the UK
  set), 6 (terminal reports: DA, DSR and the cursor position report, not
  the answerback), 8 (VT102 insert and delete) and the RIS test of menu
  10. Menus 4 (double-size characters), 5 (keyboard), 7 (VT52 mode), 9
  (known bugs), 11 (VT220 and xterm extensions) and the rest of 10 are
  outside the core.
* **C, erXos's termcap `xterm` entry**, which is FreeBSD 15.1's `xterm`
  entry without the capabilities `erx_vt` does not implement
  ([TERM and termcap](#term-and-termcap)).

**No native parser of program output.** `erx_vt` runs in the session's
runtime and parses what the session's programs write, and whatever they
relay from elsewhere, such as an `ssh` session's remote output. It is
Erlang, translated from the DEC parser model below, so a bug in it is
the exit of one terminal process: its window ends and its tty hangs up,
as the failure table says, and the session's other terminals and
processes go on. A NIF's fault would end the session's whole runtime
instead. A native emulator, if one were ever wanted, would run in a
sub-space of the session holding only its window and its tty's master.
No program's output reaches the display domain, which sees a terminal
only as the pixels its window draws.

#### One pipeline over one state

```erlang
-spec erx_vt:new(Cols, Rows) -> state().
-spec erx_vt:feed(state(), binary()) -> {state(), [effect()]}.
-type effect() :: {reply, binary()}     % bytes for the tty's input
                | bell
                | {title, binary()}.    % OSC 0 or 2 text, UTF-8
```

`feed/2` runs each byte through three stages:

1. **UTF-8 decoding** into code points. The decoder holds at most three
   pending bytes, and replaces each maximal ill-formed subsequence (an
   invalid byte, an overlong form, a surrogate, a value past U+10FFFF, a
   sequence cut short) by one U+FFFD, the practice Unicode recommends in
   its chapter 3. The terminal is UTF-8 only: `ESC % G` changes nothing
   and `ESC % @` is ignored.
2. **The DEC parser** of Paul Williams's model of DEC's ANSI-compatible
   terminals (vt100.net), translated to Erlang as a function from a parser
   state and a code point to the next state and at most one action. Its
   states are Williams's: ground, escape, escape intermediate, CSI entry,
   parameter, intermediate and ignore, DCS entry, parameter, intermediate,
   passthrough and ignore, OSC string, and SOS/PM/APC string. Its actions
   are print, execute, collect, param, ESC dispatch, CSI dispatch and the
   string actions. Two extensions are xterm's: BEL ends an OSC string as
   ST does, and the parser runs on code points, so a code point from
   U+0080 to U+009F is a C1 control whether it arrived as ESC and a byte
   from `@` to `_` or encoded in UTF-8, and any code point from U+00A0 up
   is printed in ground and collected in a string.
3. **Grid operations**, which each dispatch names from the tables below:
   a pure function of the grid state and the operation.

Williams's model gives the recovery rules without special cases: CAN and
SUB return to ground from any state, and ESC begins a new sequence from
any state, so an ESC inside a string ends the string. An OSC a program
forgets to terminate swallows output only until the next ESC or BEL, and
`reset`, whose RIS begins with ESC, always reaches the parser.

Every stage keeps constant-size state between calls, so where the bytes
are split does not matter: feeding `A` and then `B` gives the state and
the effects, concatenated, of feeding `A` followed by `B` at once. The
core reads no clock and no global state, so the same bytes give the same
screen on every host.

**What changed is derived, not tracked.** An operation rebuilds only the
rows it changes and keeps every other row the same term, so `erx_term`
finds the rows to redraw by comparing each row of the new grid with the
same row of the old one, which costs a pointer comparison for an
untouched row, and compares the cursor and the reverse-screen mode the
same way. The core keeps no
dirty list. After a scroll every row is new at its position; copying the
moved pixels instead of redrawing is an optimisation of `erx_term` on
the watch list, not a rule of the core.

#### Cells and the grid state

```erlang
-type cell()   :: {Chars :: [char(), ...], Width :: 1 | 2, attrs(), link_id()}
                | wide_tail.                 % right half of a width-2 cell
-type attrs()  :: {[flag()], Fg :: colour(), Bg :: colour()}.
-type flag()   :: bold | dim | italic | underline | blink | inverse
                | invisible | strike.
-type colour() :: default | 0..255 | {0..255, 0..255, 0..255}.
-type link_id() :: none | pos_integer().
-type row()    :: {Wrapped :: boolean(), Cells :: tuple()}.
```

`Chars` is a base code point and the zero-width code points joined to
it, at most six in all. `Wrapped` says the row continued into the next by
autowrap, so a copy joins the two rows without a newline. A blank cell is
a space of width 1 with no flags, the default foreground and the
background of the pen at the time it was erased (xterm's background
colour erase, termcap's `ut`). The representation in memory may pack a
cell; these are the values it holds.

The state holds:

* the size, from 2 to 640 columns and 1 to 256 rows;
* two grids, the main and the alternate, and which is shown;
* the scrollback, a queue of rows with its cell count;
* the cursor: row, column, a pending-wrap flag and visibility;
* the pen (current `attrs()`) and the open link;
* the modes, a closed set: cursor keys (DECCKM), keypad (DECKPAM), insert
  (IRM), new line (LNM), origin (DECOM), autowrap (DECAWM), reverse screen
  (DECSCNM), cursor visible (DECTCEM) and bracketed paste;
* the scrolling region's top and bottom margins and the tab stops;
* G0 and G1, each US ASCII, DEC Special Graphics or UK, and which of the
  two is invoked;
* a saved cursor per grid (DECSC): position, pen, pending wrap, origin
  mode and the character set state;
* the link table and the input context's types;
* the decoder and parser states, and the position of the last cell
  written, for joining zero-width code points;
* counters of the sequences it ignored, by kind.

Its invariants, checked after every step of the exhaustive test: the
cursor lies in the grid; every row of a grid has exactly the grid's
width; every width-2 cell is followed by `wide_tail` and every
`wide_tail` follows a width-2 cell; 1 <= top < bottom <= rows; the
scrollback is within its bound; and the link table holds at most its
bound.

**Width.** A code point's width is 0 if its general category is `Mn`,
`Me` or `Cf` other than U+00AD; 2 if its East Asian Width is `W` or `F`;
and 1 otherwise. Controls never reach it. The table is generated by the
terminal generator from rules in `abi/terminal.txt` and the Unicode data
OTP 29.1.2 carries, `UnicodeData.txt` and `EastAsianWidth.txt` under
`otp/lib/stdlib/uc_spec/`, Unicode 17.0.0, the same version and the same
generator as the line escape's tables ([Escape
rules](design-live.md#escape-rules)). It is the system's one width
table: the same generator writes from the same rule and data musl's
`wcwidth` tables and `erx_width`, which `prim_tty:wcwidth/1` answers
from, so a program, the shell's line editor and the terminal count the
same columns for every character
([design.md](design.md#decisions),
[design-runtime.md](design-runtime.md#the-c-library-seam)). Writing
follows from the widths:

* a width-2 character at the last column wraps first when autowrap is
  on, leaving the last column as it was, and is written ending at the last
  column when autowrap is off, as a narrow character is rewritten there;
* writing over either half of a width-2 cell blanks both halves, and so
  does an insert, delete or erase that splits one;
* a width-0 code point joins the last cell written if nothing has moved
  the cursor since, up to six code points a cell, and is dropped
  otherwise;
* there is no grapheme clustering: an emoji joined by U+200D takes the
  columns of its parts, and a variation selector does not change a width,
  as libvterm and most terminals behave.

**Character sets.** A printed ASCII code point is mapped through the
invoked set: DEC Special Graphics maps `_` to `~` to the line-drawing and
symbol characters of the VT100, the UK set maps `#` to `£`, and US ASCII
maps nothing. Code points outside ASCII are never mapped.

#### The sequences

Each table is closed: a sequence not in it is ignored and counted.
Parameters are written `Ps` with their default in parentheses; a missing
or zero parameter takes the default where the default is 1. "Needed by"
uses the letters above.

C0 and C1 controls:

| Control | Effect | Needed by |
| --- | --- | --- |
| BEL | the `bell` effect; ends an OSC string | P, C |
| BS | one column left, stopping at column 1 | P, V, C |
| HT | to the next tab stop, or the last column | V, C |
| LF, VT, FF | index: down one row, scrolling at the bottom margin; with LNM also to column 1 | P, V, C |
| CR | to column 1 | P, V |
| SO, SI | invoke G1, invoke G0 | V |
| CAN, SUB | end any sequence, back to ground | V |
| ESC | begin a sequence, ending any string | all |
| NUL, DEL, other C0 | nothing, not counted | |
| IND, NEL, HTS, RI, DCS, CSI, ST, OSC, SOS, PM, APC (C1) | as their ESC forms | P (`prim_tty.erl:144` treats U+009B as CSI) |
| other C1 | ignored, counted | |

Which operations clear the pending wrap follows the last column flag of
DEC STD 070; the corpus runs every row of the tables with the flag set.

Escape sequences:

| Sequence | Name | Effect | Needed by |
| --- | --- | --- | --- |
| `ESC 7`, `ESC 8` | DECSC, DECRC | save and restore the cursor | I, T, V, C |
| `ESC D` | IND | index | V |
| `ESC E` | NEL | index and column 1 | V |
| `ESC M` | RI | up one row, scrolling down at the top margin | I, V, C |
| `ESC H` | HTS | a tab stop at the cursor's column | V, C |
| `ESC c` | RIS | the state of `new/2` at the current size, keeping the scrollback, whose links become plain text | T, V |
| `ESC =`, `ESC >` | DECKPAM, DECKPNM | keypad mode on, off | I, C |
| `ESC ( F`, `ESC ) F` | SCS | designate G0, G1: `F` is `B` US ASCII, `0` DEC Special Graphics, `A` UK | V, C |
| `ESC # 8` | DECALN | fill the screen with `E`, margins reset, cursor home | V |
| `ESC \` | ST | end a string | all |
| `ESC % G` | | UTF-8, which it already is: nothing | |

CSI sequences, `ESC [` followed by parameters and a final byte:

| Final | Name | Effect | Needed by |
| --- | --- | --- | --- |
| `@` | ICH Ps (1) | insert blanks at the cursor, shifting right | I, C |
| `A`, `B` | CUU, CUD Ps (1) | up, down, stopping at the margins | P, I, V, C |
| `C`, `D` | CUF, CUB Ps (1) | right, left, stopping at the edges | P, I, V, C |
| `E`, `F` | CNL, CPL Ps (1) | down, up, and column 1 | I |
| `G`, `` ` `` | CHA, HPA Ps (1) | to the column | I, C |
| `H`, `f` | CUP, HVP Pr;Pc (1;1) | to the row and column, relative to the top margin in origin mode | P, I, T, V, C |
| `I`, `Z` | CHT, CBT Ps (1) | forward, back by tab stops | P, I, C |
| `J` | ED Ps (0) | erase below (0), above (1) or all (2); 3 empties the scrollback and leaves the screen | P, I, T, V, C |
| `K` | EL Ps (0) | erase right, left, the whole line | I, T, V, C |
| `L`, `M` | IL, DL Ps (1) | insert, delete lines at the cursor within the region; nothing outside it | I, V, C |
| `P` | DCH Ps (1) | delete characters, shifting left | I, V, C |
| `S`, `T` | SU, SD Ps (1) | scroll the region up, down; only the one-parameter form | I, C |
| `X` | ECH Ps (1) | erase characters without shifting | I, C |
| `a`, `e` | HPR, VPR Ps (1) | right, down by | |
| `c` | DA Ps (0) | reply `ESC [ ? 1 ; 2 c`, a VT100 with the advanced video option | V |
| `d` | VPA Ps (1) | to the row | I, C |
| `g` | TBC Ps (0) | clear the tab stop at the cursor (0) or all (3) | I, V, C |
| `h`, `l` | SM, RM | set, reset mode 4 IRM or 20 LNM | V, C |
| `? h`, `? l` | DECSET, DECRST | set, reset 1 DECCKM, 5 DECSCNM, 6 DECOM, 7 DECAWM, 25 DECTCEM, 1049 (alternate screen, with the cursor saved and the alternate grid cleared on entry) and 2004 (bracketed paste) | I, T, V, C |
| `m` | SGR | the pen, below | P, I, T, V, C |
| `n` | DSR Ps | 5: reply `ESC [ 0 n`; 6: reply `ESC [ Pr ; Pc R` with the cursor's position, relative to the top margin in origin mode | T, V |
| `r` | DECSTBM Pt;Pb (1;rows) | set the region and move the cursor home; ignored unless top < bottom | I, V, C |
| `s`, `u` | | save and restore the cursor, as `ESC 7` and `ESC 8` | |
| `! p` | DECSTR | soft reset: modes, pen, margins, character sets and saved cursor to their initial values, the grids kept | T |

Each list of modes in SM, RM, DECSET and DECRST is applied mode by mode;
an unknown mode is ignored and counted, and the rest still apply. Modes
12 (cursor blink) and 8 (auto-repeat) change nothing: nothing in a
terminal window blinks, since nothing paints without a change (G6).

SGR parameters, applied left to right, an empty list being 0:

| Parameter | Effect |
| --- | --- |
| 0 | the default pen |
| 1, 2, 3, 4, 5, 7, 8, 9 | bold, dim, italic, underline, blink, inverse, invisible, strike on |
| 22, 23, 24, 25, 27, 28, 29 | bold and dim, italic, underline, blink, inverse, invisible, strike off |
| 30-37, 90-97; 39 | foreground 0-7, 8-15; the default |
| 40-47, 100-107; 49 | background 0-7, 8-15; the default |
| 38;5;N, 48;5;N | foreground, background colour N of 256 |
| 38;2;R;G;B, 48;2;R;G;B | foreground, background RGB |
| 58;5;N, 58;2;R;G;B, 59 | underline colour: read and ignored |

Any other parameter is skipped and counted, and the rest still apply;
38 or 48 with a malformed tail ends the list. `blink` is kept in the
cell and drawn as it is, without blinking.

Strings:

| String | Effect |
| --- | --- |
| `OSC 0 ; text`, `OSC 2 ; text` | the `{title, Text}` effect; `erx_term` writes the text to the window's `label`, which its displayer escapes (G5) |
| `OSC 8 ; params ; uri` | a link, an input context or a closing, by the grammar below |
| any other OSC | dropped and counted |
| DCS, SOS, PM, APC | consumed to their end and counted |

**Reports carry nothing from the stream.** The three replies are fixed
forms whose only variable parts are numbers `erx_vt` computes, so no
byte a program wrote comes back as input, whatever it wrote. A terminal
that echoes text back, as xterm's title report does, lets output type
commands; `erx_vt` has no such report.

**What it ignores.** Every sequence outside the tables is parsed to its
end, its effect dropped and its kind counted: among them double-size
lines (`ESC # 3` to `ESC # 6`), the VT52 mode, G2 and G3 with SS2, SS3,
LS2 and LS3, national character sets other than the UK's, 132-column
mode (DECCOLM, which xterm also ignores unless told otherwise), left and
right margins (DECSLRM), selective erase, rectangular operations, REP,
cursor styles (DECSCUSR), mouse reporting, focus events, window
operations (`CSI t`), DA2 and every other query, colour palette changes
and queries (`OSC 4`, `10`, `11`, `104`), the clipboard (`OSC 52`), and
DCS strings, sixel graphics among them. A program asking a question gets
no answer, as from a terminal that lacks the feature. The counters are
inspectable on the terminal's window and are never logged, since
programs write unsupported sequences routinely.

#### Bounds

| What | Bound | Past it |
| --- | --- | --- |
| a UTF-8 sequence pending between calls | 3 bytes | U+FFFD for the ill-formed part |
| CSI parameters | 16 | the rest ignored and the sequence dispatched with the first 16, as in Williams's model |
| a parameter's value | 65,535 | clamped; further digits are consumed |
| intermediate bytes | 2 | the sequence is ignored to its final byte |
| a private marker (`<`, `=`, `>`, `?`) | first position only | elsewhere, or a `:` anywhere, the sequence is ignored to its final byte (Williams's CSI ignore) |
| an OSC string, from after `ESC ]` to before its end | 4 KiB | consumed to its end and dropped |
| DCS, SOS, PM, APC strings | never stored | consumed to their end |
| the grid | 640 columns, 256 rows | `erx_term` asks for no more; the window's surplus is margin |
| code points in a cell | 6 | further zero-width code points dropped |
| the scrollback | 131,072 cells, each row stored without its trailing blank default cells | the oldest rows dropped |
| live links | 256 | the oldest evicted, its cells shown as plain text |
| a presentation's `TYPE` | 32 bytes | the sequence dropped |

So a terminal's state is bounded by its size and these constants
whatever a program writes, and a session's terminals on a display by its
grant's `windows` quota, since each holds a window; all of it is the
session's own memory. A parser's state between calls is
constant-size: an endless CSI or an unterminated string costs no memory.
A burst of report requests yields one reply each, and the tty's input
bound drops what does not fit, as the line discipline drops typed input
past it.

#### Links and the input context

The whole OSC 8 string, within the 4 KiB above, follows this grammar
(RFC 5234, with every quoted string matched case-sensitively):

```text
osc8       = "8;" params ";" uri
params     = *( %x20-3A / %x3C-7E )        ; key=value pairs; ignored
uri        = close / link / context
close      = ""
link       = "erx:" type "/" text
context    = "erx:accept/" [ type *( "," type ) ]
type       = LOWER *31( LOWER / DIGIT / "_" )
text       = 1*( ALPHA / DIGIT / "_" / "+" / "," / ":" / "=" / "@"
                 / "-" / "." / "/" / pct )
pct        = "%" HEXDIG HEXDIG
LOWER      = %x61-7A
```

A `type` must be a presentation name of the inspection schema, which
never names a presentation `accept`; the decoded `text` must be valid
UTF-8 holding no C0 control, DEL or C1 control. Every OSC 8 string ends the open link
first, as the OSC 8 convention has each one replace the one before, and
links do not nest. Then:

* a **link** allocates the next link id, records its type and decoded
  text in the link table, and makes it the pen's open link; every cell
  written from then on carries the id;
* a **closing** does nothing more;
* a **context** replaces the input context's types, and an empty list
  clears it; it opens no link, and `erx_render`'s closing sequence after
  it leaves the context in place;
* a string outside the grammar, a link to an `https:` or `file:` URI
  among them, or past the 4 KiB bound, does nothing more and is counted,
  so the text after it is plain.

Link ids increase and are never reused. The table holds at most 256
links; a new link past that evicts the oldest, and a cell whose id is no
longer in the table is plain text, so eviction needs no scan of the grid
and a stale id never names another link. RIS clears the table, the open
link and the context. `erx_vt:link_at(State, Row, Column)` answers the
type and text under a click, and a cell is highlighted when its link's
type is in the context.

#### Scrollback, the alternate screen and resizing

A row enters the scrollback when it scrolls off the top of the main grid
with the region's top margin at the first row, the rule of xterm and
libvterm; scrolling a region that starts lower saves nothing, and the
alternate grid has no scrollback. `ED 3` empties it. `erx_term` keeps
its own view offset into the scrollback and returns to the bottom when
output arrives; the offset is not terminal state.

`erx_vt:resize/3` keeps the rows' contents without reflowing them. When
the grid gets shorter, the rows above the cursor go to the scrollback as
far as needed to keep the cursor's row on screen, and the rows below it
are dropped after that; when it gets taller, blank rows are added at the
bottom. A narrower grid crops each row, blanking a width-2 cell it
splits; a wider one pads with blanks and default tab stops. The region
resets to the whole grid and the cursor and saved cursors are clamped
into it. `erx_term` takes the new size from its window and hands it to
its tty as `{tty_size, Rows, Columns}`, which the tty applies as
design-live's `size/3` says.

#### Keys and paste

`erx_vt:key(State, Key)` returns the bytes a key sends. `Key` is the
rune of a `kbd` record's `c` with the modifiers, Shift, Control, Alt
and AltGr, in the set of the window's last `k` record, which is the
record of the down that typed it or that its repeats repeat; the set
holds every modifier held on the display, so Alt held for another
window still reaches this one ([The window tree](#the-window-tree)).
The bytes follow from the rune and those modifiers alone, never from
which key typed the rune, so two keys that type one rune under the same
modifiers send the same bytes: Backspace types `Kbs`, 0x08 in
`keyboard.h`, and so does Control-H at the `ctl` layer. From the modes
in the state it sends printable keys as UTF-8, Return as CR, `Kbs` as
DEL (FreeBSD's default `VERASE`) without Control and as BS with it, so
Control-H and Control-Backspace both send BS, Control-Space and
Control-2 as NUL, as FreeBSD's console does (`sys/dev/kbd/kbdtables.h`,
lines 48 and 102; `share/vt/keymaps/us.kbd`, lines 8 and 62), since a
`kbd` record, which a NUL ends, cannot carry one and the keymap's `ctl`
layer types nothing for Space, Tab as HT, any other
control character as the keymap's `ctl` layer typed it, and Alt with a
key as ESC before it; the arrows as `CSI A` to
`CSI D`, or `ESC O A` to `ESC O D` with DECCKM set, Home and End as
`CSI H` and `CSI F`, or their `ESC O` forms with DECCKM, Insert, Delete,
Page Up and Page Down as `CSI 2 ~`, `CSI 3 ~`, `CSI 5 ~` and `CSI 6 ~`,
F1 to F4 as `ESC O P` to `ESC O S`, F5 to F12 as `CSI 15 ~` to
`CSI 24 ~` with xterm's gaps, and a modifier on any of these in xterm's
form, `CSI 1 ; M X` or `CSI N ; M ~` with `M` one more than the sum of
Shift 1, Alt 2 and Control 4. The keypad sends its `ESC O` forms with
DECKPAM set.

`erx_vt:paste(State, Bytes)` returns the bytes of a paste or a
presentation click: the bytes unchanged, or with bracketed paste set,
between `CSI 200 ~` and `CSI 201 ~` with every `CSI 201 ~` inside them
removed, so pasted text cannot end its own bracket.

#### TERM and termcap

`erx_term` gives the shell it starts `TERM=xterm`, and so does the host
tool's `console`; the serial line gives `vt100`, as FreeBSD's `/etc/ttys`
gives its serial ports. Naming the terminal `xterm`, as FreeBSD's vt(4)
does, lets every program that knows xterm drive it, and lets the name
travel to other systems; a program that uses more of xterm than the
subset gets the ignored-sequence behaviour above, as on FreeBSD's
console.

FreeBSD describes terminals in termcap(5), and so does erXos. Its
termcap source, `abi/termcap`, holds two entries in termcap(5)'s text
form, and the release carries it as `/usr/share/misc/termcap`, FreeBSD's
path:

* **`xterm`** is FreeBSD 15.1's `xterm` entry with its `tc=` references
  resolved, without each capability whose sequence is outside the tables
  above, each removal named in a comment, and with one capability added:
  the boolean `links`, which says the terminal shows OSC 8 links. A
  termcap reader finds a capability by name, so one that does not know
  `links` never sees it.
* **`vt100`** is FreeBSD's `vt100` entry restricted the same way, without
  `links`.

The terminal generator also reads `abi/termcap` and writes
`erx_termcap`, a table of the entries, from which `erx_render` reads
`links` for the session's `TERM`; an unknown or unset `TERM` has no
capabilities. Nothing parses termcap at run time on erXos, so the file
is no input to fuzz.

#### Details the tables leave open

The oracle settles these, each with a corpus case, and where libvterm
differs `test/vt/differences.txt` gives the reason:

* CAN and SUB drop an unfinished string without dispatching it; DEL in
  an OSC string is ignored, and so is a code point from U+00A0 inside an
  escape or control sequence, which then completes;
* a C1 control encoded in UTF-8 acts as a C1 control;
* setting or resetting DECOM homes the cursor; DECALN homes it too;
* resetting DECAWM clears the pending wrap, so the next character
  overwrites the last column; HT clears it too;
* IL and DL move the cursor to column 1, as DEC's VT510 manual says;
* VPA and the cursor position report are relative to the top margin in
  origin mode;
* DL and a resize save no rows to the scrollback, except a shorter
  resize, and the scrollback charges every row at least one cell, so
  the cell bound also bounds its rows;
* `CSI ? 1049 h` on the alternate screen and `l` on the main one do
  nothing;
* RIS keeps the ignored counters; DECSTR keeps the cursor's place;
* erasing a row's end clears its `Wrapped` flag;
* writing over either half of a width-2 cell blanks the other half;
* DEC Special Graphics maps `_` to U+00A0, the blank of the VT100's
  table.

#### The oracle

`erx_vt` is compared with **libvterm** 0.3.3, Paul Evans's terminal
emulator library in C under the MIT license, the emulator inside Vim and
Neovim. It is a test oracle only, not a dependency: fetched at its pinned
release and SHA-256 and built out of tree for the host, with a harness of
erXos's own, `test/vt/vterm_dump.c`, that feeds it a corpus and writes
the screen after each checkpoint in the dump format `erx_vt:dump/1` also
writes: each row's cells with their code points, flags and
colours, a width-2 cell's right half marked, the cursor and its visibility, and the replies since the last
checkpoint. libvterm is built without its `unicode.c`, whose two width
functions the harness supplies from `include/erx/vt_width.h`, generated
from `erx_vt`'s width table, so the comparison
covers everything but the widths, which a separate test re-derives from
the Unicode data. libvterm is chosen because it is a library with no
process, clock or host locale in the way: a corpus gives the same dump on
every host. xterm itself, the reference, has no headless screen dump;
tmux takes its widths from the host's C library and needs a server
process; xterm.js would bring Node into host tooling.

Neither side is the standard. Where they disagree, xterm's "XTerm
Control Sequences" and DEC's VT100 and VT220 manuals, as vt100.net keeps
them, decide. Every difference over the corpus is one of:

* a **bug** in `erx_vt`, fixed, with its corpus case as the regression
  test;
* a **documented difference**: the case is listed in
  `test/vt/differences.txt` with the sequence, the reason and `erx_vt`'s
  expected dump, which the test then checks, so the difference is pinned
  as well as explained. The sequences `erx_vt` ignores and libvterm
  implements, the `:` sub-parameters of SGR and the DA2 reply are the
  first entries;
* a **libvterm bug**, where the references agree with `erx_vt`: listed
  in the same file as upstream, with the reference's section.

A difference that matches no entry fails the test.

The corpus:

* a case for every row of the tables, with each parameter omitted, 0, 1,
  at the grid's edge and past it;
* the exhaustive enumeration of [Verification](#verification-and-testing),
  fed to both;
* streams generated from the tables' grammar, with text of narrow, wide
  and zero-width code points between the sequences, from a recorded seed;
* `prim_tty`'s output for a scripted editing session: lines longer than
  the screen, wide characters, tabs, the expansion's status line;
* the output of toybox's applets that drive a terminal (`top`, `vi`,
  `hexedit`, `watch`, `more`, `ls --color`, `grep --color`), recorded on
  erXos;
* `vttest`'s core, recorded live: a Ruby driver runs `vttest` on a host
  pseudo-terminal with the libvterm harness as its terminal, answers each
  pause with Return, and records `vttest`'s bytes, the pauses and
  libvterm's replies; `erx_vt` replays the bytes and must give the same
  replies and the same screen at every pause.

### The widget server

The widget toolkit is the application `erx_ui`, which the release of
every domain that shows widgets starts, and an application's widgets live in
its own runtime: the client library `erx_ui`, one widget server
`erx_ui_server` for each open UI, and a renderer. Nothing of a tree, an
event or an application's term leaves the application's domain, except
what a renderer draws or hands its medium.

* `erx_ui:open(Options)` starts a widget server under the toolkit's
  supervisor for the display that `Options`' `display` names, or the
  default display ([Choosing a display](#choosing-a-display)), with the
  renderer that `Options`' `renderer` names, or the default for that
  display. The server opens its target, on a display a window with the
  `label` option as its title, made with the server as its holder, and
  the reply is `{ok, Window}`, the reference of a monitor the caller
  holds on the server;
* `erx_ui:tree(Window, Tree)` hands the server a tree, answered `ok` or
  `{error, Reason}`;
* `erx_ui:close(Window)` ends the server and its window.

`tree/2` and `close/1` are the opener's calls, since `Window` is the
reference of a monitor the opener holds.

The widget server sends `{ui, Window, Term, Detail}` to the process that
opened the window, plain messages from a process of the opener's own
runtime, and `{ui_down, Window, Reason}` when it ends other than by
`close/1`; a server that is killed outright leaves the opener the
monitor's `'DOWN'` with the same reference. The server monitors its
opener and ends with it. On a tree the server:

1. **validates** the tree whole against the kinds, properties and bounds
   of `abi/formats/ui.txt` with the generated `erx_ui_schema`, answering
   `{error, {Reason, Where}}` and changing nothing when any node fails
   (plan, then apply);
2. **numbers** it against the realised tree with `erx_ui_model:pair/3`
   and **diffs** the two with `erx_ui_model:delta/2`, which emits the
   `diff_op()`s that turn one into the other, ending with `commit`
   ([Widget trees](#widget-trees));
3. **applies** the operations through the renderer behaviour;
4. **routes** events: the renderer reads its target's input and reports
   which node an event hits, and the server passes each report through
   `erx_ui_model:hit/4`, which records the state value and, when the
   node takes the event, gives the term and detail the server sends the
   owner as `{ui, Window, Term, Detail}`.

Validation, the diff, the layout and the drawing all run in the
application's domain, on its CPU grant and in its memory, so a tree
costs the display nothing but the presents it leads to. The schema still
checks every tree: a renderer outside Erlang reads what the server
writes, and a tree's bounds are what keep its operations within theirs.

```erlang
-type target() :: {window, erx_win:window()}  % a window of a display the domain holds
                | {web, Line :: pid()}.       % the domain's web line (design-web.md)
-callback start(Target :: target(), Server :: pid(), Opts :: map()) -> {ok, State}.
%% The renderer reads its target's input in a process of its own, linked to Server:
%% a window's mouse and kbd, or a browser's events.  It sends Server
%% {ui_hit, node_id(), Event :: atom(), Value :: term()} for each event on a node and
%% each change of a state property; Value is the state value, or none.
-callback apply(Ops :: [diff_op()], State) -> {ok, State} | {error, term()}.
-callback stop(State) -> ok.
```

The **Erlang renderer**, `erx_ui_erlang`, keeps the realised tree with
each node's rectangle, lays it out with `erx_ui_layout`, a pure box
model (columns and rows with weights, padding, alignment, fixed sizes, a
grid, a scroll viewport, a stack) and draws the nodes whose rectangle or
properties changed through `erx_draw` into the window's buffer, with
glyphs from a subfont it loaded, then presents the union of their
rectangles. It reads `mouse` and `kbd`, and hit testing is the layout's
rectangles. It decodes an `image` node's PNG with `erx_png`, in
Erlang. Before anything is inflated, the reader checks the header's
width, height, bit depth, colour type and interlace method, refuses
an interlaced image, and computes with checked arithmetic two sizes:
the filtered rows the header declares, one filter byte and the packed
samples per row, and the decoded image's pixel bytes in the window's
channel, rounded up as every image is, which must fit what remains of
the draw connection's pixel quota. `erx_inflate`, an Erlang inflate written for
it, must then yield exactly the filtered size: it stops with an error
the moment its output would pass it, and a stream that ends short of
it, or input that ends before the stream does, is refused. A refused image is shown as
its `alt` text, as a renderer that cannot show it does.

The **LVGL renderer**, `erx_ui_lvgl`, starts the native program
`erx-lvgl` as a program of its own session, as the session starts any
program ([design-programs.md](design-programs.md#starting-a-program)):
a port of the session's runtime in a sub-space, with a handler, with its
standard input and output pipes whose other ends `erx_ui_lvgl` holds and
which the session homes as it homes every pipe
([design-pipes.md](design-pipes.md)), with a namespace narrowed to
nothing, since it opens no file, and with its window's buffer mapped as
descriptor 3 ([The pixel area](#the-pixel-area)). `erx_ui_lvgl` writes
the `diff_op()`s to its standard input in the binary form declared in
`abi/formats/ui.txt`, from which the generator produces the program's
bounded C reader. That form carries an `on_*` property as the flag that
the node takes the event, never the application's term, and a `present`
property as its type, its canonical text from `erx_present:text/2` and
its status, so the application's terms stay in the widget server and no
renderer outside Erlang parses one. The same input carries the program's
view of its target: a `screen` record with the window's size and channel,
at start and on every resize, the window's `input` records, a `repaint`
record when the whole window must be drawn again, and a `presented`
record when a frame it reported has been shown or dropped.

The program maps each kind to an LVGL object, sets its properties and
renders in LVGL's direct mode into the mapped buffer, which has the
layout LVGL's own draw buffers have at a stride aligned to 32 bits ([Windows
and buffers](#windows-and-buffers)). One refresh of LVGL calls the
program's flush callback once for each area it redrew, and LVGL's
single-buffered direct mode waits for the flush before it draws the
next area. So the program answers every callback but the refresh's last
at once: where `lv_display_flush_is_last` is false, it adds the area to
the refresh's damage and calls `lv_display_flush_ready` before it
returns. At the last it adds that area, writes one `damage` report, the
screen's width and height, which the refresh drew at, and the
rectangles it drew within them, at most 16 (their bounding box when
there are more), on its standard output, beside its events in the same format,
which `erx_ui_lvgl` reads with the generated Erlang reader, and returns
without calling `lv_display_flush_ready`. That flush stays open until
the `presented` record for the report arrives: the main loop, which
reads it, calls `lv_display_flush_ready`. Until then the main loop runs
no LVGL timer, so no refresh starts and LVGL never waits on the open
flush; it still applies the records it reads before `presented`, which
`erx_ui_lvgl` wrote before it read the report, and a resize's `screen`
record, since applying a record changes the tree or the screen's size
and draws nothing. After the report `erx_ui_lvgl` writes the program
nothing but a resize's `screen` record and its `presented` (below), so
the wait ends at a record that comes. The program's flush-wait callback
(`lv_display_set_flush_wait_cb`) stops it with a diagnostic, since
LVGL reaching it means a refresh began with a flush open, which would
otherwise spin forever. So on the copy path, and on a device that reads
the buffer only during a present, the program never draws in the
buffer between a `damage` report and the copy that report asks for; a
device that scans the buffer out all the time reads it while the
program draws, which a second buffer avoids ([Risks and
decisions](#risks-and-decisions)). The program never waits on a record
that cannot come, and runs at the device's pace with no timer of its
own.

`erx_ui_lvgl` turns each `damage` report it can show into a present of
the window's buffer and, at the answer, writes `presented`. While a report is
unanswered it holds everything else it would write: the `diff_op()`s
of the next tree, for which its `apply/2` does not return until the
report is answered, so the widget server and the application wait at
the device's pace too; the window's next `mouse` and `kbd` records,
which it reads only after the answer, so they wait in the window's
bounded queues ([Windows and buffers](#windows-and-buffers)). A new
size, the `r` record of a `mouse` read, it writes as a `screen` record
the moment it reads it, even while a report is open, when a read that
was in flight as the report arrived brings one. A
report is judged when it is read, at its own size, the width and
height it names. When that is the size of the last `screen` record
written, the report is presented at that width and height; a resize
read while it is open changes no pixel of the buffer, since the
program draws nothing until `presented`, so the report is still shown
at the size it was judged at, clipped, as any present for a stale size
is ([The window tree](#the-window-tree)), and is no fault. A report
that sat unread in the program's output while a resize's `screen`
record was written names another size than that record's, and its
rows have a stride the buffer no longer has: `erx_ui_lvgl` presents
nothing for it and answers `presented` at once, so the program
continues. Either way the program has applied the new `screen` record,
which invalidates the whole screen, so its next report covers the new
size. These decisions, what to write, when to present and what is the
program's fault, are a pure state machine, `erx_ui_lvgl_core`, whose
actions `erx_ui_lvgl` performs. It turns the window's
`mouse` and `kbd` records into `input` records. A report whose
rectangle leaves the size it names, which the reader refuses, or one
that arrives before the last was answered, is a fault of the program: `erx_ui_lvgl` stops
it, logs the report's position, and ends the UI with `{ui_down,
Window, renderer_down}`. The
program's fonts are LVGL's, and it is built with animations and blinking
cursors off. Between records it blocks in `poll` on its standard input
with the deadline `lv_timer_handler` returns, or with none when no LVGL
timer is due; the POSIX-lite personality gives a native program `poll`
with a deadline over its pipe ends
([design-programs.md](design-programs.md#the-posix-lite-personality)).
So an idle program runs nothing and reports nothing (G6). The renderers
pass the same parity test (Verification), which compares meaning, and an
application cannot tell them apart except by pixels.

The **browser renderer**, `erx_ui_browser`, has no window and no
buffer: its target is the session's web line, to which it hands the
operations in the same binary form, and from which it takes the
browser's events
([design-web.md](design-web.md#uis-the-browser-renderer)).

**Presentations in widgets.** A node's `present` property is `{Type,
Value}` or an `attr()` carrying one; the renderer shows
`erx_present:text/2` of it through the line escape, with its status
token when the status is not `ok` (G7), and a click sends the owner
`{ui, Window, Term, {select, Type, Value}}`, with `Term` the node's
`on_select`. An inspector window is an ordinary application: it renders
a record as a tree of labels with `present` properties and, on a select,
queries the inspector through its own inspect facet (G4).

### A display's session

A display may have a **session**: the one session the start table
starts on it, with no login, which shows what the display is for, a
person's terminals on a desktop and an app on a kiosk. How a person
logs in at a display, locks it and leaves it is the login design's,
which covers every place a person meets the system ([Decisions](#risks-and-decisions), 14); until it exists a
display shows the session its start row names.

erXos is a distribution, and the people who use it and build on it add
apps after a board's image is built. So what a display's session is
comes from a few places, each saying what it owns, and putting an app
on a display edits nothing of the board's:

* **The manifest says what the display is.** A display's manifest entry
  names the `windows` service whose tree its display domain serves,
  whose name is the display's name, and gives the display's policy,
  `rio` or `single`, its idle policy, its keyboard's layout and repeat,
  and its reserved chord, which the domain service puts in the display
  domain's environment when it creates the domain: `display` is the name
  of the display it serves, `display_policy` its policy, which the
  display domain refuses, with one line in its log and no window system
  started, when it is not a policy the domain has,
  `display_idle_dim_s` and `display_idle_off_s` its idle times in
  seconds, `display_keymap` its layout, `us` unless the entry names
  another the tree has ([Input events](#input-events)), and
  `display_repeat_delay_ms` and `display_repeat_period_ms` the time a
  key is held before it repeats and the time between repeats, each a
  positive number of milliseconds, 500 and 126 unless the entry says
  otherwise, the `normal` rate of FreeBSD's kbdcontrol(1)
  (`usr.sbin/kbdcontrol/kbdcontrol.1`, release/15.1.0, lines 115-121;
  `kbdcontrol.c`, lines 1066-1070); the domain's own manifest row sets
  none of them. It names
  no session, no application and no renderer.
* **Facet rows say who may draw there, and how much.** A facet row of
  the display's service grants its tree to a configured domain or to a
  session template, an app's among them, with the grant's quotas,
  `windows`, `pixels` and `snarf`, as its parameters. Every session made
  from a template holds the template's grants, so every session of a
  template that the display is granted to holds one
  ([design-apps.md](design-apps.md#an-app)). The display pays for each
  grant's pixel area, and the manifest check sums them against its
  budget, a template's as many times as its principal's `domains` quota
  allows sessions (property 18 of [The
  manifest](design-system.md#the-manifest)), so no number of sessions
  changes what the display can be made to pay.
* **The start table says which session is the display's.** A start row
  that names the display says whose session starts there at boot
  ([design-apps.md](design-apps.md#the-start-table)): an app's for a
  kiosk, and a person's for a desktop that needs no login. The manifest
  declares every row, and the machine's `rc.conf` enables, disables or
  moves one among the displays its template is granted. The table holds
  at most one enabled row for each display. The row's keeper starts the
  session with the display named in its start; the domain service then
  sets the session's `display` variable to that display, and fixes the
  session mark in its record of the session's grant on it, which every
  mint of that grant carries as `session`
  ([Windows and the window system](#windows-and-the-window-system)).
  Nothing else sets it, so the display's session is the session the
  row keeps, and no other session becomes it by starting first.
* **The template says what the session shows.** A session template's
  release and arguments say what its sessions run. A desktop's session
  runs `erx_term_sup`, which starts a terminal on the session's default
  display when the session receives its grant there, and again whenever
  its last terminal on that display ends while it holds the grant: so
  the first window appears at boot, a last window closed from the menu
  comes back, and after the display domain restarts the session opens
  a terminal on its new grant. A session with no default display, a
  login at the UART among them, opens no terminal on a display it holds.
  An app's session boots its own release, whose applications are the
  app ([Kiosks and glasses](#kiosks-and-glasses)).

From there a display's session is started, restarted and bounded by
what starts, restarts and bounds every session the start table keeps:

* **Boot starts it.** At boot step 5, once the display domain runs, the
  row's keeper starts the session of the principal the row names, as a
  login would start it ([Boot](design-system.md#boot)). The system
  domain introduces the session to the display, which makes their
  connection and its pixel area, and `erx_winfs` mints its grant with
  the facet row's quotas. A display that no row names has no session
  and shows its background, or under the overlapping policy the windows
  of whichever sessions hold its grant.
* **It comes back, by the layers that restart everything else.** What
  fails inside a running session is the session's own to restart: an
  app's applications under their supervisors, a terminal under
  `erx_term_sup`. When the session's domain ends, the row's keeper
  starts a new one within the row's restart intensity
  ([design-apps.md](design-apps.md#keeping-a-session)); past it the row
  is down, shown at `/proc/apps`, the display shows its background and
  the log names the row. The new session is a new domain, with a new
  id, a new connection, a new pixel area and the display's session's
  grant from its mint.
* **The restart rule lives in the row**, beside every other row's, and
  is set by whoever wrote the row: the image's builder for a manifest
  row, the machine's administrator for a local one. A session template
  has no restart intensity, since a session a person logged in to is
  never started again, and a template says what a session is, not how
  hard the machine works to keep it up.
* **Other sessions on the display.** A session whose template holds a
  grant on the display reaches it whether or not it is the display's
  session: under the overlapping policy its windows are ordinary
  windows, as an X client's are on any display it may open, and under
  the single policy they stay hidden. A person's login at the UART
  whose template is granted the display can so open windows there, as
  an X client opens windows on any display that admits it: in a
  development build, `root`'s login at the UART on a desktop board
  whose `root` template is granted the display holds a grant there,
  opens no terminal on it, since its start names no display, and opens
  a window there when a program asks, which the overlapping policy
  shows beside the display's session's windows. A session whose
  template has no such grant answers `erx_ui:open/1` with
  `{error, no_display}`.
* **An app a person starts** runs in a session of its own principal,
  never in the person's: `service APP onestart display=D`, or a
  launcher's `start APP display=D` written to `/apps/ctl`, starts the
  session of a row that is not enabled with `D` as its default display
  and nothing more, and
  its window opens beside the person's under the overlapping policy
  ([design-apps.md](design-apps.md#starting-a-session)). A program or
  an Erlang application a person runs in their own session opens its
  window through that session's grant, as the terminal does.
* **Whoever is at the display holds what the session offers.** A
  desktop's session is a person's, and whoever is at the display holds
  that principal's authority, as at a UNIX console that logs a user in
  automatically: the session has every facet a login of that principal
  would have. Started without a passphrase, it opens none of the
  principal's keys at the vault
  ([design-system.md](design-system.md#the-vault)); work that needs them
  logs in at the UART or the host link. A kiosk's session is an app's,
  whose release runs no shell and no terminal, so whoever is at the
  kiosk holds what the app's interface offers and no more ([Kiosks and
  glasses](#kiosks-and-glasses)).

### Choosing a display

A domain holds a grant for each display whose window tree it is granted,
a configured domain by a facet row of its own and a session by a facet
row of its template, in its capability registry
([Granting a running domain](design-system.md#granting-a-running-domain))
under the name of the service: `display` for a display domain's tree of
that name, another name for a second display's. A session that a browser
reaches also has its web line, which the name `web` stands for
([design-web.md](design-web.md#logging-in-and-the-line)). A session may
hold none of these, one or several. The **default display** is the
domain's environment variable `display`, which whoever starts the domain
sets to the display it was started from: a session a start names a
display for gets that display, the display's session among them ([A
display's session](#a-displays-session)); an app's session whose start
names none gets the one display it holds, where it holds exactly one,
so an app written for one display runs on any board; a web login sets
`web`; a configured domain takes it from its manifest entry; and a login
at the serial console or over the host link sets none. A user changes it
as any environment variable, for the domain or for one program it
starts, as on UNIX.

`erx_ui:open(Options)` looks up `Options`' `display`, or the default when
`Options` names none. `web` opens on the web line with the browser
renderer. Any other name must be a grant of a `windows` tree in the
registry, and the UI opens in a window there, drawn by the renderer
`Options`' `renderer` names, `erlang` or `lvgl`, or else by the one the
domain's environment variable `ui_renderer` names, or else by `erlang`.
A name that is unset, or that names no display the domain holds, answers
`{error, no_display}` at once; nothing waits for a display to appear.
The name selects among what the domain already holds and grants nothing.
A UI lives on the one display it opened on: the web is a second display,
not a mirror of the first, and an application that wants a UI on both
opens two.

When a display goes away, its grant ends and every window of it with it:
each widget server on it ends and sends its opener `{ui_down, Window,
display_down}`, and the registry drops the name, so a later
`erx_ui:open/1` naming it answers `{error, no_display}` until the
display's domain is back and its grant is minted again. A browser that
closes is not a display going away, and neither is the web domain's
restart: a UI on the web stays with its application, and the next
browser to attach shows its newest tree
([design-web.md](design-web.md#uis-the-browser-renderer)).

### Kiosks and glasses

A kiosk, a dashboard or a pair of glasses is a display whose manifest
entry sets the single policy and whose start row names an app. The app
runs as any app runs, with its app's privileges and its grant of the
display, and renders to the display as any client does. That is all a
kiosk is:

* **An app owns it.** The app is a principal of its own with a session
  template, whose release is the app's applications and whose facet
  rows are what its sessions hold, the display among them
  ([design-apps.md](design-apps.md#an-app)). The template's environment
  may name its renderer, `ui_renderer` as `lvgl` or `erlang`, when the
  application does not name one itself. Nothing marks it as a kiosk's:
  what makes it one is the row that starts it on the display.
* **Its authority is declared and bounded by the build.** The session
  holds its template's grants and nothing more; its grant of the
  display carries the board's quotas for it, which the manifest check
  sums against the display's budget, so no app enlarges what the
  display holds for a client.
* **It is an ordinary session, started and restarted as one.** The
  row's keeper starts it at boot with no login, and starts a new one
  when its domain ends, within the row's intensity ([A display's
  session](#a-displays-session)). The session boots the app's release,
  which starts the application, and the application opens its UI with
  `erx_ui:open/1`; the
  widget server, the renderer and, under LVGL, the `erx-lvgl` program
  all run in that session, and when the application fails its own
  supervisor in the session restarts it, with its window, as any Erlang
  application is restarted.
* **It is an ordinary window.** The single policy shows the display's
  session's oldest window over the whole screen with no decoration
  ([Windows and the window system](#windows-and-the-window-system)), so
  the display's work for a frame is the copy of the rectangles the
  renderer changed, and on a device that reads the client's memory, no
  copy at all ([The screen and its one path to the
  device](#the-screen-and-its-one-path-to-the-device)).
* **Nothing else shows.** A window of any other domain and a second
  window of the app stay hidden and receive no input (G1), also while
  the app's session or the display domain restarts, so the guarantee
  that a kiosk shows its one app is the policy's and the start table's,
  checked where each is checked.

**Putting an app on a kiosk** therefore touches the app's own rows
and one start row. A thermostat with a panel of 800 by 480 pixels shows
the parts. The board's part of the manifest holds the display and
nothing of the application:

```
unit panel
  placement "panel"
  holder @domain.display
unit touch
  placement "touch"
  holder @domain.display
domain display
  principal @principal.system
  limits @limits.display
  kind service
  flags none
  runtime @artifact.emu
  release @artifact.display
  restarts 5
  restart_period_s 600
service display
  server @domain.display
  interface windows
display display
  policy single
  idle_dim_s 60
  idle_off_s 600
```

The `display` entry describes the `windows` service of its name, so the
display's name, the name every grant of it is held under and the name a
start row uses, is the service's. The application's part is its
principal, its session template, the facet rows that grant the template
what it needs, and the row that starts it on the display
([design-apps.md](design-apps.md#an-app)):

```
principal thermostat
  memory 33554432
  grant @share.users
  domains 1
  names 4
  default_limits @limits.app
  ceiling_limits @limits.app
session thermostat
  limits @limits.app
  runtime @artifact.emu
  release @artifact.thermostat
  env "ui_renderer=lvgl"
facet thermostat_display
  name "display"
  grantee @session.thermostat
  service @service.display
  parameter windows 2
  parameter pixels 3072000
  ...
facet thermostat_data
  name "data"
  grantee @session.thermostat
  service @service.data
  ...
start thermostat
  display display
```

`pixels` holds one buffer of the screen's size for each of the 2
windows, or two buffers for one window drawn double-buffered: 800 by
480 pixels in `x8r8g8b8`, 1,536,000 bytes each. The manifest check
counts it once for each session the principal's `domains` quota
allows, here one. The row leaves `snarf` off, so the kiosk shares no
clipboard. Where the manifest declares the row with `enable NO`,
`service thermostat enable display=display` on the running machine
turns it on.

At boot the domain service starts the display domain, and the row's
keeper starts `thermostat`'s session on `display`, whose grant is
minted as the display's session. The session boots
`@artifact.thermostat`'s script, the application's `erx_ui:open/1`
opens its window, and the single policy shows it over the whole
screen. Replacing the application changes its rows and its release and
nothing else: the display's entry and the display domain's release stay
the same bytes. An app added to a running machine, once packaging
exists, brings the same rows and needs no rebuild
([design-apps.md](design-apps.md#packaging)).

A panel of 240 by 240 pixels in `r5g6b5` holds about 113 KiB; a pixel area of
one buffer and a screen image of the same size are within the smallest
budgets. A kiosk's `pixels` is one buffer of the screen's size for each
window it may hold, and one more for an application that must never
show a half-drawn frame.

What every display of this kind shares:

* **Input.** A touch panel's events are pointer events with button 1;
  the renderer's hit testing turns them into `on_click`, drags into
  scrolling. An encoder's steps arrive as wheel steps and its press as a
  key, and a keypad's keys as keys, each by its evdev code and with the
  runes the display's layout gives it, an arrow as 9front's `Kup` and
  the rest; the renderer keeps a **focus ring**
  over the focusable nodes in tree order, moves it on wheel steps and
  arrow keys, activates on enter or the encoder's press, and shows focus
  with a mark of its own, so a tree written for touch works from an
  encoder with no change, which is how LVGL's input groups behave.
* **Power.** `erx_screen`'s idle policy turns the panel `dim` and
  `off`; input turns it on. Between events nothing runs (G6), so the
  display domain's cost is its processes waiting on messages, and the
  panel driver's bus is silent.
* **Panels.** A panel on a serial bus is a display driver whose `flush`
  sends each rectangle as the panel's window-set command followed by the
  rectangle's bytes in the panel's channel; partial updates are what
  such panels do best, and the driver reads them straight from the
  application's buffer. A panel on a display serial interface with a
  framebuffer in the controller behaves the same way; one without
  partial update reports `partial` false and gets whole frames.
* **Service.** A kiosk's screen shows no terminal: its operator works at
  the UART or over the host link, under a principal of the operator's
  own. The reserved chord, where the entry names one, reaches no
  window here either. A service terminal on the kiosk's own screen is
  part of the login design ([Risks and decisions](#risks-and-decisions), 14).

### Graphics hardware

Rendering is software and composition is the copy and direct paths
above. Hardware that composes or draws attaches at one of three seams,
and the first two are all the display domain ever sees of it:

* a **buffer source**: where a window's pixels lie. There is one, the
  pixel area in ordinary memory. A device that can only show, or only
  draw into, memory of a particular kind adds a source: the system
  domain makes the pixel area from that memory, by the manifest, and a
  buffer stays a range of a pixel area with the layout above;
* a **composition path**: how `erx_screen` gets the shown windows to the
  panel. There are two, copy and direct. A device adds a path, and
  `erx_screen_core`'s plan gains the case that chooses it;
* a **render service**: how a client fills its buffer. Clients fill
  theirs with the CPU. A device that draws is held by one domain, as
  every device is, and that domain serves drawing into buffers to the
  clients the manifest grants it, through a protocol with a design of
  its own. The client's renderer builds the device's commands; the
  serving domain checks and submits them. The display is no party to it:
  what it is presented is a buffer, whoever filled it.

None of the devices below is driven by this design. Each row says what
the device is, where it attaches, and what its own design must settle.
The statements about each device's hardware come from its public
documentation and Linux drivers as cited in References, and are to be
checked against the hardware's own documents when that design is
written.

| Device | What it is | Buffer source | Composition path | Render service | To settle then |
| --- | --- | --- | --- | --- | --- |
| virtio-gpu, 2D (QEMU `virt`) | a scanout on the host fed from resources backed by guest memory | none added: ordinary memory | copy, into the resource's backing, then a transfer and a flush of each rectangle; direct on a confined device, a resource backed by the client's buffer | none | nothing: this is the display driver of this design |
| virtio-gpu with virgl or venus | the host's GPU, reached by command streams submitted in a context; resources may live on the host alone | resources of the device that no guest memory backs, which the CPU cannot copy from | the device composes: the display holds a context of its own that draws each shown window's resource, or sets the scanout to one resource | the display domain, which holds the one device, relays each client's command buffers in a context of that client's; the host validates them | how a `present` names a device resource in place of a range of memory; a client's Mesa driver over the relay |
| a board's firmware framebuffer (Raspberry Pi) | memory the firmware set up, scanned out by hardware the display domain does not hold, and mapped as device memory | none added | copy, into the screen image in the driver's memory, then each changed rectangle copied from the screen image into the framebuffer with aligned 32-bit stores | none | nothing: a display driver of this design |
| the Raspberry Pi's HVS (VideoCore VI on the Pi 4, VII on the Pi 5) | a plane compositor: a display list of planes, each a pointer to pixels, a pitch, a format, a position, scaling and alpha, applied at vertical blanking | memory the HVS can address: physically contiguous, at a bus address, so the pixel area is made a contiguous object of the device's memory | planes: the plan gives the topmost shown windows a plane each while the device's planes last and copies the rest into the screen image, the bottom plane; a present of a window on a plane changes that plane's pointer or nothing, and is answered after the next blanking | none | the HVS reads and, through its writeback path, writes memory by bus address, so on a board with no IOMMU before it its holder is in the trusted base: the board's DMA contract decides whether a release drives it ([design-platforms.md](design-platforms.md#dma)); the plane limit; formats and scaling a window may ask for |
| the Raspberry Pi's V3D (4.2 on the Pi 4, 7.1 on the Pi 5) | a tile-based 3D renderer with an MMU of its own, driven by binning and rendering command lists that Mesa's `v3d` and `v3dv` build in the client | the HVS's source, when the result is scanned out: the render target is a buffer of the client's pixel area that V3D's page table also maps | whatever the display has: a buffer V3D filled is a buffer | a GPU domain holds V3D's registers and interrupt, owns its page table and job queue, maps into the table only buffers of the client it serves, and takes jobs from the client's Mesa driver | whether clients share one page table, as Linux's driver arranges, or the service switches tables between clients; how the system domain installs a pixel area in a third domain; which domain holds V3D |
| a 2D engine: TES D/AVE 2D (Renesas RA and RZ), and others of its kind | a bus master that executes display lists of blits, fills and anti-aliased primitives into memory at a bus address; LVGL has a draw unit over it | memory at a bus address, as for the HVS | copy, with the engine doing the blit: the plan's copies are a list of clipped blits between images the display already maps | the domain that holds the engine builds its display lists itself, from requests that name buffers and coordinates and never addresses; LVGL's draw unit in `erx-lvgl` sends its draw tasks there | the engine has no MMU, so its lists must be built by its holder; whether the gain over the CPU on a small panel pays for a service |

Three properties keep these additions from reaching clients. A buffer is
described by its width, height and the display's channel, and its rows
are 32 bits aligned, the layout each of these devices takes. A client
learns of the display only its channel and its window's size, and of
composition only the answer to its present. And every path falls back
to the copy path, which needs nothing of the buffer but that the display
can read it; a device resource the CPU cannot read is the one case that
must add its composition path with its source.

### Erlang clients

`erx_win` is the client library for windows, for Erlang processes in any
domain that holds a display's grant: `open(Display, Options)` makes a
window in the domain's directory with the caller as its holder,
allocates its buffer at the screen's size from the domain's pixel area
([Windows and buffers](#windows-and-buffers)) and returns a handle
holding the fids of the window's files, the display's channel and the
buffer; `image/1` answers an `erx_memdraw` image over the buffer at the
window's size; `present/2` writes the present for a list of rectangles
and waits for its answer; `mouse/1` and `kbd/1` read records;
`resized/1`, after an `r` record, re-reads the window's rectangle and
answers an image at the new size over the same buffer, clipped to it,
and allocates nothing; `resize/2` and `label/2` write `wctl`
and `label`.

`erx_draw` draws with Plan 9's messages: `open(Window)` starts a draw
connection on a window; `alloc/4`, `draw/6`, `line/6`, `string/5`,
`load/3`, `flush/1` and the rest encode messages with the generated
encoder and hand them to the connection, batching until a flush or
64 KiB. `erx_font` reads a Plan 9 subfont file and loads its glyphs into
a font cache image with `i` and `l`, so a client's text is a sequence of
`s` messages; it is a parser of file data and has a fuzz target.

## Interfaces

**The window tree**, as the data model lists it, served by `erx_winfs`
through the file protocol and declared as the interface `windows` in
`abi/services/windows.txt`, with the grant's parameters `windows`,
`pixels` and `snarf`, and `session`, which no facet row sets and the
domain service sets for the display's session alone; the `present`
command of `ctl`; `wctl`'s commands
`resize -r X0 Y0 X1 Y1`, `move -r X0 Y0 X1 Y1`, `hide`, `show`, `top`,
which also makes the window take the keyboard, and `bottom`, each one
line; the `mouse` record format of Plan 9 and 9front; the `kbd` record
format of 9front's kbdfs(8), with the special runes of
`abi/formats/input.txt`; and the read-only `screen` file. The display
serves no other interface to a client.

**A display's manifest entry**: a `display` record named after the
`windows` service it describes, whose server is the display domain and
whose name is the display's everywhere: in every grantee's registry and
in a start row; its policy, `rio` or
`single`; its idle policy; its keyboard's layout and repeat delay and
period; the reserved chord, by evdev code. The entry names no
session, no renderer and no application.

**The display's session**: the start row that names the display
([design-apps.md](design-apps.md#the-start-table)), whose keeper's
start names the display; the domain service sets the session's
`display` variable from that start, and fixes the session mark in its
record of the session's grant on the display, which every mint of that
grant carries as the `session` parameter
([design-system.md](design-system.md#facets-a-configured-domain-serves)).

**The pixel area**: the `pixels` parameter; the area as an object of a
connection, in the connection's plan and its control record
([design-domains.md](design-domains.md#connections)); `erx_area:open/1`;
`erx_pixels`'s `alloc(Peer, Bytes)`, `lend(Peer, Offset)` and
`unlend(Lease)`, under its registered name;
`erx_area:lend/5`, `unlend/1` and `zero/3`, the lease, its message
`{erx_area_returned, Tag, Lease}` and the buffer place; `erx_memdraw:wrap/4`; a buffer's layout; the `mem` descriptor of a
program's startup message
([design-programs.md](design-programs.md#the-startup-message)). The
program driver reaches a lease through three functions of `erx_area.h`,
under its port's lock, and through nothing else of the area:

```c
/* The held lease Number, for a port whose owner, driver_connected's
 * answer, is its holder, spanning Pages; now taken. NULL, changing
 * nothing, for anything else, and before the area NIF has loaded. */
erx_area_lease_t *erx_area_lease_take(uint64_t number, ERL_NIF_TERM owner,
    uint64_t pages);
/* Maps the taken lease's range, read-write, at ERX_PROG_MEM_BASE in
 * space, reserved with ERX_VM_FIXED | ERX_VM_NOREPLACE: ERX_OK, or the
 * reserve's or the map's status with nothing left reserved or mapped. */
erx_status_t erx_area_lease_map(const erx_area_lease_t *lease, erx_cap_t space);
/* Returns a taken lease, once, after the anchor's destroy or as a failed
 * start's last undo; the driver does not use lease afterwards. */
void erx_area_lease_return(erx_area_lease_t *lease);
```

**Draw messages**, in `abi/formats/draw.txt`, with the bounds above; the
draw connection's `draw` and `ctl` files in a session's export, `ctl`'s
text twelve 11-character fields followed by a space, as draw(3);
`erx_draw_conn`'s one entry for a write's bytes.

**Widgets**: `erx_ui:open/1` with the `display`, `renderer` and `label`
options, `erx_ui:tree/2`, `erx_ui:close/1`, `{ui, Window, Term, Detail}`,
`{ui_down, Window, Reason}` and `{error, no_display}`; the `display` and
`ui_renderer` environment variables; the kinds, properties, events,
image types and bounds of `abi/formats/ui.txt`, `secret` on `input`
among them, and the binary form of `diff_op()`, events, and the
`screen`, `input`, `repaint`, `presented` and `damage` records derived
from it for renderers outside Erlang; a tree's `{error, {Reason,
Where}}`; the `erx_ui_renderer` behaviour and its `target()`;
`erx_ui_model`'s `pair/3`, `delta/2`, `apply_ops/2` and `hit/4`.

**Presentations**: the `present` marks of `abi/inspection.txt`,
`erx_present:text/2`, `parse/2`, `path/2`, `uri/2`, `parse_uri/1`, `type/1` and
`marks/0`, the `-erx_args` declaration, the link and input-context sequences, the `links` capability of a terminal.

**The terminal**: `erx_term` and its supervisor `erx_term_sup` in a
session's release, its two key bindings, Ctrl-Shift-N and Shift with
Page Up and Page Down; `TERM=xterm` at `erx_term` and the host tool's
console; `abi/termcap`, installed as `/usr/share/misc/termcap`, and the
generated `erx_termcap`; `erx_vt`'s `new/2`, `feed/2`, `resize/3`,
`key/2`, `paste/2`, `link_at/3`, `dump/1` and its `effect()`; the
sequence tables and bounds of [The terminal
emulator](#the-terminal-emulator).

**Drivers**: the `erx_display` behaviour; an input driver's records,
`record()` of [Input events](#input-events), with evdev's codes from
`abi/formats/evdev.txt`, and their binary form in
`abi/formats/input.txt`, for an input device another domain holds.

**Keyboard layouts**: the files `abi/keymaps/NAME.txt` in the format
of [Input events](#input-events), and the generated `erx_keymap`.

**Interaction with other subsystems.** The display domain's creation
gives it the devices the manifest places on its row
([Devices](design-system.md#devices)); the domain service mints each
client's grant on the window tree, and the connection it makes first
carries the pixel area
([design-system.md](design-system.md#facets-a-configured-domain-serves));
a session's handler binds a window's files and a draw connection's into
a program's namespace
([Narrowing](design-files.md#narrowing-for-a-program)), and maps a
window's buffer into a program as it builds it
([design-programs.md](design-programs.md#the-startup-message)); a
session's terminal relay serves the tty whose master `erx_term` is
([The tty](design-live.md#the-tty)); the start table's keeper starts a
display's session and the domain service marks its grant ([A display's
session](#a-displays-session),
[design-apps.md](design-apps.md#keeping-a-session)); the
session's web line carries the browser renderer's operations
([design-web.md](design-web.md#uis-the-browser-renderer)); `erx_render`
emits presentations ([Inspection](design-live.md#inspection)); the
inspector schema supplies the types
([Inspection](design-live.md#inspection)).

## On the stopgap

The display runs on the stopgap Fiasco as designed, with trusted
domains, and what differs is what the stopgap's kernel does not enforce
or its devices do not allow:

* **The pixel area** is a memory object of the root task's pool, made
  and passed by the domain library in the connection's plan, as a
  connection's sides are
  ([Sharing memory between tasks](design-stopgap.md#sharing-memory-between-tasks)).
  The display's `liberx` maps it read-only and the client's read-write;
  nothing holds a domain that bypasses `liberx`, and its charge to the
  display's budget is a record.
* **No direct path on virtio-gpu.** QEMU `virt` under the stopgap has no
  IOMMU, so virtio-gpu attaches over virtio-mmio, unconfined, and
  reaches only its own contiguous memory. Its driver reports `direct`
  false, and every frame takes the copy path: one copy of the changed
  rectangles in the machine, then the device's transfer to the host. The
  direct path needs virtio-pci behind the IOMMU, which erXos's kernel
  brings; it is then a change of the driver's device record and of
  nothing a client sees.
* **Unconfined devices.** The development manifest gives virtio-gpu and
  virtio-input to the display domain, the Phase 1 manifest check allows
  that in a development build, and the display domain is then in the
  trusted base ([Security](#security)).
* **A program's buffer** is mapped by the session while it builds the
  program, as the program's data area is.

Phase 1 defers the hardware of [Graphics hardware](#graphics-hardware),
the bounds a hostile client is held to in CPU, and the confinement of the
display's devices; each is the target design above and none is built on
the stopgap.

## Compatibility and migration

plan9port's `libdraw` connects to a `devdraw` process over a pipe with
its own request messages, in which the draw messages themselves travel
unchanged as the payload of its draw requests and the mouse, keyboard,
label, snarf and resize traffic are requests of their own. erXos's port
of `libdraw` replaces that connection code with Plan 9's own file-based
one against the files in the program's `/dev`, so acme, sam and 9term
run without a translating process; the session's draw connection stands
where plan9port's `devdraw` process does. Plan 9's `getwindow` attaches
to the window by name and allocates a screen over it and a window on
that screen to draw in; the port's `getwindow` re-reads `ctl` and takes
image 0 as the program's screen image, and is part of the connection
code replaced. 9term and acme's `win` need a pseudo-terminal, which the
second tier of programs provides
([design-programs.md](design-programs.md#the-second-tier)). Programs
that allocate screens and layers of their own, rio among them, are not
clients: erXos has its own window system.

Nothing here changes a format of another subsystem. Records in
pipelines and `/proc` files are unchanged; the link sequence appears only
at a terminal that declares `links`.

## Failure handling, diagnostics and debuggability

| Failure | Effect | Recovery |
| --- | --- | --- |
| a malformed or over-quota write to a draw connection's `draw` | the write fails with `EINVAL`, `ENOENT`, `EEXIST` or `ENOMEM`, nothing applied; the session's log records the connection, the reason and the position | the client's |
| a `ctl` line outside the grammar, or a present that passes the end of the pixel area | the write fails with `EINVAL`, and the window shows what it showed; the display domain's log records the window and the reason | the client's |
| a client's pixel area has no room for a buffer | `erx_win:open/2` answers `{error, enomem}` | the client's: it closes a window, or its grant's `pixels` is raised |
| a window's holder ends, or `rmdir` | the window ends; its process and pending input go, and `erx_screen` drops its waiting present and its image of the buffer; the buffer's pages return to the client's allocator when their owner exits, zeroed before they are handed out again | `erx_screen` copies what it uncovered from the windows below |
| a client domain's end | its grant ends and every window of it with it; its connection goes down, the display unmaps its pixel area, and the system domain deletes the area with the connection | as above |
| a client is killed while `erx_screen` copies from its buffer | the copy finishes: the area stays mapped until the display lets go | none needed |
| a kiosk's application fails inside its session | its UI's processes end with it and its window is removed; the screen shows the background | the application's supervisor in the session restarts it, and it opens its UI and its window again |
| a display's session domain ends, a kiosk's among them | as a client domain's end; under the single policy the screen shows the background, and another session's window stays hidden | the start row's keeper starts a new session, which is introduced and marked as at boot, within the row's intensity; a kiosk's app opens its window again, a desktop's session its terminal |
| a display's session domain ends more often than its start row's intensity allows | the row is down, shown at `/proc/apps` with its last reason; the screen keeps the background | `service NAME start`, at the UART or the host link, or the next boot |
| no start row names the display | the display has no session and shows its background, or under the overlapping policy the windows of the sessions that hold its grant | enabling a row that names the display |
| the row's session is refused, its principal's budget or quota full | no session; the refusal is the row's state and reason at `/proc/apps` and counts as an end against the row's intensity | the administrator's: room for the principal |
| a local setting names a display the row's template is not granted, or one another enabled row holds | the row is `refused` with `{no_grant, D}` or `{display_held, Name}` at `/proc/apps` and starts nothing; the display keeps its session or its background | the administrator's: a setting the merge accepts ([design-apps.md](design-apps.md#the-start-table)) |
| a window process crashes | as the window's end, logged with the message that caused it | the client sees `EIO` on its fids and makes a new window |
| `erx_screen` crashes | supervisor restart; it asks `erx_winfs` for the layout and every shown window to present again, which each does from its last present; a window waiting in a present sees the call fail and answers its client `EIO` | the client presents again; nothing is lost but one frame |
| the display driver crashes | restart; device reset; scanout re-created; `erx_screen` repaints from its windows' buffers; the screen image's memory stays in the NIF's record | no client notices |
| the display driver stops answering without ending | the screen keeps its last frame; `erx_screen` keeps draining its mailbox and holds one pending layout and at most one waiting present for each live window (G3); clients wait in their presents | the frame goes out when the driver answers, or the driver ends and restarts as above |
| `erx_winfs` crashes | it holds every grant and window of the display, so its crash ends the display domain, with the effect of the domain's end below | as for the domain's end |
| a terminal, `erx_term`, crashes | a process of the session, not of the display; its window ends with it, its holder, and its tty hangs up, so its shell and jobs get the hang-up, as when an xterm dies; the session's other terminals go on | a sibling from another terminal, or from `erx_term_sup` when it was the session's last on that display |
| a draw connection crashes | a process of the client's domain; its images go, its program's next write to `draw` fails with `EIO`, and the window shows its last present until the program ends | the program's |
| a widget server crashes | a process of the application's domain; its window ends with it, its holder, and the opener receives the monitor's `'DOWN'` for `Window` | the application opens a new window |
| the display domain ends | every window ends; clients' fids fail with the connection down, and their pixel areas go with their connections; each terminal on it ends with its window and hangs up its tty, as above; each widget server on it sends its opener `{ui_down, Window, display_down}` | the domain service restarts the domain within its intensity and mints its clients' grants again, each on a new connection with a new pixel area, the display's session's with the session mark of its record, so it is the display's session on the new incarnation; applications reopen, and a desktop's session opens a terminal on its new grant |
| a widget tree fails validation | `erx_ui:tree/2` answers `{error, {Reason, Where}}`; the realised tree is unchanged | the application's |
| a window's widget server would number a node past 2^32 - 1 | the window ends; the application receives `{ui_down, Window, limit}` | the application opens a new window |
| the LVGL program exits | the widget server ends the window and the application receives `{ui_down, Window, renderer_down}`; the session logs the exit record, as for any of its programs | the application reopens |
| the LVGL program reports a rectangle outside the size it names, or a second report before the first is answered | `erx_ui_lvgl` stops the program and logs the report's position, and the application receives `{ui_down, Window, renderer_down}` | the application reopens |
| the window grows past the buffer the program maps, which the handler allocated at the screen's size before the screen grew | the program refuses the `screen` record and exits, and the application receives `{ui_down, Window, renderer_down}`; `erx_ui_lvgl` does not clamp the size | the application reopens, and the new program's buffer has the new screen's size |
| the LVGL program writes outside its buffer | the write faults in the program's own sub-space, which holds no other page of the pixel area; its exit is the row above | the application reopens |
| an input device stops | its driver restarts and resets it; the router takes the old process's end as its source's end and sends an up for every key and touch it held, to the window each down went to, and releases its buttons | events resume, and no key stays held or repeats |
| an input device reports dropped events (`SYN_DROPPED`) | its driver discards the update in progress and sends `release`, which the router handles as above | a key still pressed is pressed again to be seen |
| another domain's input device file ends or fails a read | the display's reader of it ends, and the router releases what it held, as above | the reader starts again when the file is granted again |
| a record names a key the layout has no row for, a key its source already holds or one it does not hold | dropped and counted, nothing else changes | none needed |
| a window's `mouse` or `kbd` queue is full | the oldest record is dropped and counted; a resize is never lost | the client reads |
| an input device, or a domain serving one, sends faster than the router routes | its driver or reader waits in `erx_winfs:input/2`, and the events wait in the device's buffers or the serving domain; the display holds at most one record of each source and one read of each reader | the router catches up |
| the panel is off and a client presents | the present changes the window's buffer and is answered without a copy | the next input turns the panel on and repaints |

The inspector shows a display under `[domains, Id]` with its windows,
each with owner, rectangle, state, the size of its presented buffer, its
present count and dropped input records, and each client's pixel area
with its size, all marked `service`;
`/proc/domains/Id/windows/N/status` shows the same. A client's domain
shows its draw connections with their image counts and pixel bytes, and
its pixel area with the bytes its allocator has handed out, marked
`runtime`. The display domain's log carries each refused `ctl` line with
the window and the reason.

## Security

* **Isolation of windows** is G1: a client's pixels lie in memory only
  it writes and only the display reads, a present can name only the
  presenter's own pixel area, grants are rooted per client and the
  handler narrows per program. A program given a window learns only its
  own size and input, and holds only its own buffer's pages.
* **What shared memory lets a client do to the display** is show pixels,
  and nothing else. The area holds no field the display acts on: sizes,
  offsets and layouts come from the checked `present`, and the area's
  own size from the system domain. A client that writes its buffer while
  `erx_screen` reads it changes what its own window shows. A client
  cannot delete, shrink or unmap the area under the display, since it
  holds no right to, and its death leaves the area mapped until the
  display lets go (G2). The copy from a buffer is `libmemdraw`'s draw
  between two images over a rectangle the display clipped; it reads
  pixel values and branches on none of them.
* **What it lets the display do to a client** is read the client's pixel
  area: every pixel the client presented, and anything else the client
  wrote there. A client therefore puts nothing in its area but what it
  means to show. The display cannot write a client's memory, since its
  mapping is read-only, and it holds nothing else of the client's.
* **The display domain's trust.** It sees every pixel its clients
  present and every
  keystroke it routes, as an X server does, and holds nothing else:
  device capabilities, its own budget and
  grants, the grants it serves, and its clients' pixel areas, read-only.
  Its display and input devices are
  confined or do no DMA: on QEMU `virt` virtio-gpu and virtio-input
  attach as virtio-pci behind the IOMMU, and a confined virtio-gpu
  function reaches only the screen image's memory and the client buffers
  the driver mapped read-only into its window; a Raspberry Pi's firmware
  framebuffer is memory its display hardware scans out, and the display
  domain holds none of that hardware's registers; whether a board's
  panel or touch bus can be confined is that board's DMA contract
  ([design-platforms.md](design-platforms.md#dma)). The display domain
  parses what its clients and its input devices send, so a release
  manifest that gave it
  an unconfined DMA device, a virtio-mmio one among them, fails the
  manifest check, as for every domain that parses hostile input
  ([Trust placement](design.md#trust-placement)); in a development build
  that holds one, the display domain is in the trusted base. With that,
  a compromised display domain can show a false screen, record
  keystrokes and inject input into the windows it serves, as an X11 or
  Wayland server can. Input injected into a terminal's window is typing
  at that terminal's shell, so it has the authority of the shells in the
  terminals of the session introduced to it, and through them what that
  session's principal reaches. It also reads and writes its display's
  clipboard where `snarf` is on. It has nothing beyond: it cannot write a
  domain's memory or read any of it but the pixel areas, message a
  process it was not introduced to, start a
  program in a session, or reach a session that was not introduced to
  it. No program's terminal output, draw message, picture or font reaches
  it, so nothing a program
  writes to a terminal or draws can attack it through a parser, and it
  never carries the system
  shell, which opens only at a login at the UART or the host link
  ([The console](design-live.md#the-console)). This is the trust an X
  server or a Wayland compositor has, stated.
* **What the display domain parses** is G9: the file protocol's terms,
  one line of `ctl` or `wctl`, and the records of an input device
  another domain holds. Each has a fuzz target, and none is native code.
* **Rendering faults stay with the client.** A draw client's bytes are
  decoded in Erlang, by `erx_draw_codec` and `erx_draw_image`, and
  `erx_memdraw`'s primitives act in C on what Erlang checked,
  rectangles, counts and pixel rows; an `image` node's PNG is read by
  `erx_png` and inflated by `erx_inflate`, in Erlang; ERTS's `zlib`,
  `binary_to_term`, `re` and `erlang:decode_packet` parse in C, and no
  module of the draw or widget applications calls them on a client's
  bytes. All of it runs in the client's own domain, so a fault in the
  NIF ends the runtime of the session that drew, and a shape that takes
  long holds that session's dirty schedulers, not another's. LVGL, code
  of unknown provenance, runs in a sub-space of the session that holds
  its two pipe ends and its window's buffer; what it reads was written
  by its own session's widget server, and what it reports is checked in
  Erlang before anything is presented.
* **On the stopgap.** QEMU `virt` under the stopgap Fiasco, as the harness
  starts it, has no IOMMU, so virtio-gpu and virtio-input attach over
  virtio-mmio and are unconfined. The development manifest gives them to
  the display domain, the Phase 1 manifest check allows that in a
  development build, and the display domain is then in the trusted base,
  as the paragraph above says of any development build that holds such a
  device; a client that compromises it reaches all memory through the
  gpu's DMA. The release manifest's refusal is unchanged, and the drivers
  are the same code on both. Moving the devices to virtio-pci behind the
  IOMMU on erXos's kernel
  changes their device records and DMA profiles, not their drivers
  ([design-system.md](design-system.md#devices)).
* **Input** is routed to one window per event, by the policy for what
  starts something and to the down's window for what follows it, and
  nothing lets a client write another window's input. The reserved
  chord reaches no window under any policy, since the router decides it
  before a policy is asked. A key's up, and the event that lets a
  button or touch go, reach the window its down reached even when that
  window has since been hidden, which tells it only when something it
  saw go down went up, and, in a `K` record's set, which modifiers were
  held then; its repeats, moves and presses do not. A window's repeat
  is set, stopped and timed only by keys whose downs it received, so no
  window learns from its own stream when another window is typed in.
  The modifiers a key is typed with are the display's, so a window
  that receives a down learns which modifiers the person holds as they
  type to it, wherever those modifiers' downs went. A domain
  that serves the display an input device's records has the reach of a
  person at the display, and no more: its records can move the pointer
  within the screen, press and release keys and buttons, hold a key so
  that it repeats to the window its down reached, as a person holding it
  would, touch, scroll and type the chord. They cannot name a window or
  a time, since a record carries neither; move the pointer off the
  screen; make a window receive an up it did not see go down, or a down
  twice; make another source's keys go up; grow the router's state past
  one entry for each key code and touch slot, since a doubled down is
  dropped; or make the display hold more of its records than one read,
  since its reader reads again only once the last read is routed. When
  its file ends, every key, button and touch it held goes up.
* **A kiosk's authority** is its app's: its template's grants, the
  display's among them, and nothing else
  ([design-apps.md](design-apps.md#security)). Its grant of the display
  carries the board's quotas, so no app enlarges what the display holds
  for a client. The app's release runs the app, and no shell and no
  terminal, so a person at the kiosk, or a compromised display domain
  injecting input, reaches only what the app's interface offers. A
  fault of the app's runtime ends its session, which holds no other
  principal's facets, and the session that replaces it starts from the
  template again. Whether the app's principal can be enrolled and
  logged in to at a console line is the login design's (decision 14).
* **Who holds a display's screen** is the start table's to say, and
  the start table changes only through the `apps` grant, the manifest
  and the data partition's `rc.conf`, which sets only rows the manifest
  declares, and only to displays their templates are granted
  ([design-apps.md](design-apps.md#security)).
  Under the single policy no client takes the screen by opening a
  window first, or by asking: the shown window belongs to the session
  whose grant the domain service marked, and only a start row's keeper
  makes the domain service mark one.
* **The clipboard** is shared, per display, by every grant on it whose
  facet row turns `snarf` on, whatever its principal: the sessions of
  those rows' templates, their terminals and every program they give
  `/dev/snarf`, and the configured domains those rows name. What one of
  them copies, any other can read. `snarf` is off unless a row turns it
  on, so an app reads a person's clipboard only where the board's
  manifest turned it on for both; a grant without it has no `/snarf`,
  and its copy and paste stay within a program or a terminal window.
* **Presentations grant nothing** (G4). The link carries a type and a
  text; the terminal inserts text; the shell checks facets. A hostile
  program cannot make the terminal emit a presentation that does more
  than text, because the emulator's actions on any link are the two
  above, whoever wrote the sequence; a program that writes a link with a
  misleading text and a different URI gets a click that inserts the
  URI's text, which the shell then parses as typed, and the inserted text
  is shown in the command line before anything runs.
* **Attributed text** is G5: labels, `present` texts and record values in
  widgets pass through the line escape; a program's bytes reach its
  terminal's tty unchanged (V1) and the emulator interprets them as a
  terminal does.
* **Resource bounds** are G3. The display's memory for a client is the
  client's pixel area and its windows' small records, both fixed by the
  grant. Its CPU for a client is the copy of what the client presents,
  at most once a frame for each window, and the file server's work for
  its requests, which runs on the display domain's own grant as a file
  server's does
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).
  Drawing, layout and decoding cost the client's own grant and budget.
* **Residuals.** Window ids are issued per display and never reused, so
  one client looping `mkdir` and `rmdir` can spend them all, after which
  every `mkdir` on that display fails with `ENOSPC` until the display
  domain restarts; the `windows` quota bounds live windows, not ids
  issued. A client's 16 rectangles may overlap, so one present can make
  `erx_screen` copy the window's visible area up to 16 times in a frame.
  The layout's tiling is paid by `erx_screen` for every window of every
  client. Implicit bidirectional reordering of displayed text is
  not escaped, as in design-live. A window can draw a convincing copy of
  another window's content, a terminal's included; under the overlapping
  policy the border marks the window that takes the keyboard and the menu
  names windows by label. Any program writing
  to a terminal can write an input context, as the shell does, and so
  highlight presentations the shell did not ask for; a click on one
  still inserts only the presentation's text, shown in the command line
  before anything runs.

## Verification and testing

Each passing case has a seeded failure that proves the code ran.

* **The draw core and the codec.** `erx_draw_core` explored exhaustively
  over small ids, every message type and rectangles at and across the
  bounds; a seeded skip of the quota check fails the `ENOMEM` cases.
  `plan/2` over writes that allocate an image and load it in the same
  write, free an image and then load it, and load image 0, at every
  channel depth: a seeded plan that frames with the depths of the
  connection as it stood before the write fails the first case with
  `ENOENT`, and a seeded plan that performs an operation before the fold
  ends fails a write whose last message is malformed, which must leave
  every image unchanged. A `y` cut across two writes fails the first
  write with `EINVAL` at the `y`'s offset, applies none of it and leaves
  the connection holding no bytes, while the same rows loaded as two
  `y`s over bands, one per write, yield the image a single `y` does,
  where a seeded connection that keeps the first write's tail fails
  it. The codec's C twin has a generated fuzz target
  that takes the depths of ids 0 to 7 from the input's first bytes and
  decodes the rest message by message, to its end or its first error;
  the Erlang codec is tested differentially against the twin over the
  corpus with the same depths, message by message (the same message, the
  same next offset, or the same errno at the same offset), where a seeded
  off-by-one in a length field fails it. The `y` lengths are checked
  against `bytesperline` of the 9front build below, over rectangles with
  negative and unaligned coordinates at every depth, where a seeded
  `bytesperline` that ignores the sign of `r.min.x` fails it; coded
  polygon points decode as fixed vectors at the edges of the one-byte
  and three-byte forms say, where a seeded one-byte form read without
  its sign bit fails; messages from `erx_draw`'s generated encoder decode
  to themselves.
* **The pixel primitives.** Two oracles, each the ground truth for a
  stated part.
  * `erx_draw_ref`, a slow Erlang reference, pixel by pixel, of what
    draw(2) and draw(3) define as compositing: the twelve operations,
    masks, channels and their conversion, replication, clipping, `y`
    (which a `Y` plans to), `r`, and `l`, `s` and `x` as the masked draws they consist of. A test
    tool, it lives in `test/erlang/` and takes the messages as
    `erx_draw_codec` decodes them. Its pixels are those of 9front's
    `libmemdraw` test `drawtest.c` (`getpixel`, `putpixel` and
    `drawonepixel`, the image laid out in memory as Plan 9 lays it out),
    widened from `SoverD` to all twelve operations with the factors and
    rounding of `libmemdraw`'s `alphacalc` functions (`CALC11`,
    `CALC12`), which agree with `drawonepixel`'s on every premultiplied
    pixel. Random operations of those kinds
    over random images and channels through `erx_memdraw` and through the
    reference agree pixel for pixel, with the `x` bits masked since a draw
    leaves them undefined; a seeded change to one Porter-Duff
    operation fails it. `erx_draw_ref` draws no shapes.
  * Lines, polygons, ellipses and arcs (`L`, `p`, `P`, `e`, `E`) have no
    definition finer than `libmemdraw`'s algorithms: draw(2) says what
    they draw, not which pixels. Their oracle is **the 9front build**:
    9front's `libmemdraw` and the parts of its `libdraw` it links,
    unmodified, at the commit the import's origin file records, compiled
    for the host as a test tool (Dependencies) and driven by a small C
    program of erXos's that performs a list of operations and returns the
    images. Random operations of every kind through `erx_memdraw` and
    through the 9front build agree pixel for pixel, so each edit the
    import makes (the clip rectangle, checked arithmetic) is checked
    against the code it came from, shapes and compositing alike; a
    seeded change to one step of `memline`'s algorithm fails it. A
    difference is a bug in the import, or an upstream bug the import
    fixes, documented with a test. Both sides run in the test, so no
    reference images are stored. The 9front build is
    `MemdrawBuild.oracle` over `test/display/memdraw_oracle` and the
    harness `test/display/memdraw_shapes.c`. Its shapes compose with
    `SoverD` from premultiplied 1x1 sources, since under the other
    operations a k1 mask, and under `SoverD` a 1x1 colour above an
    alpha of 0, are draws the import fixes; `erx_draw_ref` compares
    those. The same harness draws shapes at and past the limits
    `erx_memdraw` admits under ASan and UBSan, and checks that a shape
    changes no row outside the rectangle it reports.
  * The same runs under ASan and UBSan, with rectangles far outside every
    image, are the test of G2's clipping; a seeded bypass of
    `erx_draw_clip` is caught by the chokepoint check and by ASan.
* **The PNG reader.** `erx_png` and `erx_inflate` have a fuzz target
  over arbitrary bytes and over mutated PNGs, which asserts that every
  call ends with pixels or an error, that the inflated bytes never pass
  the filtered size the header declares, and that an interlaced image,
or one whose decoded pixel bytes pass the draw connection's remaining
pixel quota, is refused before anything is inflated, where a seeded removal of the output bound fails it.
  `erx_inflate` is tested differentially against stock OTP's `zlib` on
  the host over the corpus, accepting the same streams and yielding the
  same bytes, where a seeded off-by-one in a back-reference's distance
  fails the agreement.
* **The `Y` decoder.** `erx_draw_image` has a fuzz target over
  compressed payloads into rectangles of every channel and size, under
  ASan and UBSan in `make check-fuzz`, which asserts that every decoded
  result holds exactly the rectangle's bytes and that the bytes consumed
  never pass the end of the write, where a seeded removal of the
  end-of-row bound fails it. Its oracle is `cloadmemimage` of the imported `libmemdraw` (the import
  edits only its software-cursor call): over Plan 9's compressed images and the fuzz corpus, the two
  accept the same payloads, consume the same count and yield the same
  pixels, where a seeded off-by-one in a run's length fails the
  agreement. The codec's C twin frames a `Y` with the same
  `cloadmemimage`, so the differential test of the codec against its
  twin compares the framing of every `Y` against 9front's decoder too.
  Payloads that would decode past the rectangle or end short fail the
  write and apply nothing.
* **The pixel area.** Each passing case beside the seeded failure that
  proves it ran:
  * the domain library's plan for a connection whose grant carries
    `pixels` makes the area from the reader's child budget, gives the
    grantee a writable capability and the server a read-only one, neither
    with the right to delete it, and deletes it with the connection,
    explored on the host with the connection's other objects over every
    order of ends and unmaps; a plan that charges the area to the
    writer's own budget fails the survivor case below;
  * a client killed while its windows are shown leaves `erx_screen`
    copying from its area without a fault, and the area is deleted only
    once the display has unmapped it, under ASan in hosted mode; a
    connection agent that unmaps before the last image over the area is
    freed makes ASan report;
  * on erXos's kernel a store by the display domain into a client's area
    faults in the display domain, where an install that gives the server
    a writable capability fails it; on the stopgap the case reports
    `unsupported`;
  * `erx_memdraw:wrap/4` over ranges that end at the area's last byte,
    one byte past it and far past it, over sizes whose product
    overflows 64 bits, and at offsets of 1, 2 and 4 bytes past a page
    boundary: the first makes an image and the rest are refused; a
    `wrap/4` without its bound check fails the second, and one without
    its alignment check fails the misaligned cases, which also run
    under UBSan's alignment check;
  * `erx_pixels_core` over random sequences of `alloc`, `lend`, owners'
    exits and leases' returns: no two live ranges overlap, every range
    lies within the area, a lent range stays out while either its owner
    lives or its lease is outstanding, in both orders of the two ends,
    and once every owner has exited and every lease returned one `alloc`
    of the whole area succeeds; a free list that does not join
    neighbours fails the last, and a seeded core that frees a lent range
    at its owner's exit fails the third. Every range that joins the
    free list is zeroed first, with a seeded core that joins before the
    zero failing it, and an area with no live range is let go: in the
    display suite the agent answers a lost display's connection
    unmapped once the client's last program returns its lease, where a
    seeded allocator that keeps the area's term fails;
  * `erx_pixels`'s `lend(Peer, Offset)` from the range's owner, from
    another process, at an offset inside the range and at the range's
    offset in another `Peer`'s area: the first is lent and the rest are
    refused with `einval`; a `lend` without its owner check fails the
    second. A second `lend` of one range before the first lease returns
    waits (below);
  * `erx_area:zero/3` over a range written with a pattern, over ranges
    that end at the area's last page and one page past it, with
    `Offset` plus the range's bytes past 2^64, at an `Offset` one byte
    past a page boundary and over a read-only area: the first two read
    back all zero, with the pages on either side untouched, and the
    rest are refused with `einval`; a `zero/3` without its bound check
    fails the third, and one that zeroes a page too many fails the
    first;
  * reuse: a range whose owner wrote a pattern and exited is handed to
    the next `alloc` all zero, where a seeded allocator that skips the
    zeroing fails; a program given a buffer, whose window then ends
    while the program runs, keeps a mapping no `alloc` hands out again
    until its lease is returned, so a second window's buffer never lies
    under the first program's mapping, where a seeded `erx_win` that
    gives the range back at the window's end fails;
  * `erx_area:lend/5` over ranges that end at the area's last page, one
    page past it, with `Offset` plus the range's bytes past 2^64, at an
    `Offset` one byte past a page boundary, with `Pages` of 0 and one
    page past `prog_mem_bytes`, and over a read-only area: the first is
    lent and the rest are refused with `einval`; a `lend/5` without its
    bound check fails the second. A negative `Offset`, a negative
    `Pages`, an `Offset` of 2^64, a float, a `Holder` that is no pid and a
    `Tag` that is no reference are `badarg`, where a seeded `lend/5` that reads its integers as
    signed fails;
  * the lease's transitions, a pure function of the area NIF explored
    on the host over every order of a take by the holder's port, a take
    by another owner's port, a second take, a give-back, the holder's
    exit and the driver's return: a lease is taken at most once, only by
    its holder's port and only while held, and returned exactly once, by
    the holder's exit or a give-back when held and by the driver when
    taken; a seeded holder's exit that returns a taken lease fails it, as
    a double return. A `lend/5` for a holder that has exited answers
    `{error, noproc}` and leaves the table empty, and the area's
    destructor then runs once its terms are dropped; a seeded `lend/5`
    that ignores the monitor's failure leaves a held lease and fails it;
  * `erx_pixels`'s `lend(Peer, Offset)` for a range whose last lease is taken
    answers only after that lease's return, with the return held back
    in the test until the call is waiting, and a `lend` after a
    give-back answers at once; a seeded allocator that refuses a range
    with a lease outstanding fails the first, and so the end to end runs
    below, which lend the same range anew for each start, wait instead
    of racing the last program's teardown;
  * a forged `{erx_area_returned, ...}` sent to `erx_pixels` while a
    lease of a range is taken, with the lease's number and no tag or
    with a reference of the sender's own, changes nothing: the next
    `lend` of the range still waits for the real return, where a seeded
    allocator that matches a return by its number alone fails;
  * the program driver's start core, explored on the host over a failure
    at every step with a lease and without one, and over every way a
    started program ends (its exit, a fault, `port_close/1` and the
    handler's exit, which closes the port): with a lease the take is the
    first effect and its undo the last, the buffer step comes after the
    image's space is created and before the image is mapped, and the
    lease is returned exactly once, after the anchor's destroy in every
    release and every undone start that made the anchor; a seeded core
    that returns the lease before the anchor's destroy fails it, and one
    whose close at the handler's exit skips the return fails it too;
  * end to end, in the display suite, since `erx_area:open/1` answers
    `{error, none}` in the system domain and the programs suite has no
    display connection. A client session opens a window and starts a
    test program three times, each with the window's buffer as
    descriptor 3, lent anew each time, and drops every term of the area
    it holds. In the first run the program maps the descriptor, writes
    a pattern and exits 0, and the client presents the buffer, whose
    screenshot through QMP shows the pattern; a program build whose C
    library seam takes no call
    ([design-programs.md](design-programs.md#the-posix-lite-personality))
    fails its `mmap` and this run. In the second it stores one page
    past its buffer's end and faults in its own sub-space, with the
    session and the display running on; a driver that maps one page
    more fails it. In the third it writes in a loop while the display
    domain is killed; it runs on without a fault until the session ends
    it, and its end is the session's stop, not a fault. A seeded driver
    that returns the lease right after mapping fails the third run: the
    connection's end deletes the area, and the program ends with a
    fault on the stopgap, whose delete removes its mapping, as on
    erXos's kernel.
* **Presents.** Each passing case beside its seeded failure:
  * `erx_winctl`'s fuzz target over arbitrary lines, which asserts that
    every accepted line is a present within the grammar's bounds, with
    cases at each bound: a seventeenth rectangle, a width of 0 and of
    16,385, a number of 20 digits and a line of 1,025 bytes, each
    refused; a parser that admits a seventeenth rectangle fails;
  * a present whose buffer ends at the area's last byte is shown, and one
    a byte longer fails with `EINVAL` and leaves the screen as it was; a
    check that multiplies without checking fails the case whose size
    wraps to a small number; a present at an offset off a page boundary
    fails with `EINVAL`, where a check without the alignment rule shows
    it;
  * a stalled driver: against a driver model that holds a frame without
    answering, presents from every window, `wctl` moves and windows made
    and removed by the thousand leave `erx_screen` answering messages,
    holding one pending layout and at most one waiting present for each
    live window, and none for an ended one; when the model answers, one
    frame shows the newest layout; a seeded `erx_screen` that keeps
    every layout, or keeps an ended window's present, fails the heap
    bound, and one that calls the driver synchronously fails the
    message-queue bound;
  * the answer follows the device: against a driver model that holds its
    frame, the present stays unanswered until the model answers; an
    `erx_screen` that answers before the flush fails;
  * pacing: against a driver model that takes 10 ms a frame, a client
    that presents as fast as it is answered is answered once a frame,
    and a second window's one present is answered within two frames
    (G3);
  * a buffer smaller than its window shows the background beyond it, and
    one larger is clipped to the window; a placement off by one row
    fails the pixel comparison;
  * one buffer and two: a client that scribbles in the buffer it has not
    presented while windows move above it never has the scribble shown;
    an `erx_screen` that still reads the previous buffer after the
    answer fails.
* **Who touches pixels.** `erx_screen_core` explored exhaustively over
  small screens and layouts: every pixel of the screen comes from exactly
  one shown window, decoration, the overlay or the background; a layout
  change copies exactly the areas whose content changed, where a seeded
  off-by-one in the visible region fails it; and the direct path is
  chosen exactly when one undecorated window with a buffer of the
  screen's size covers the screen and the driver reports `direct`, where
  a core that goes direct under a decoration fails. G2's hosted runs
  under ThreadSanitizer and ASan, with clients drawing, presenting,
  resizing and ending during copies and driver reads. Bounds: a `mouse`
  queue past 4 KiB drops its oldest record and counts it while a pending
  resize still answers `r`, where a seeded unbounded queue fails the
  heap check.
* **Windows.** G1's tests: presents across the ends of an area, two
  sessions' grants, a narrowed program, the single policy's choice of
  the shown window as windows are made and end; the `wctl` grammar's
  fuzz target; a fuzz target over `erx_win`'s readers of what a client
  reads back from a display, the `mouse` and `kbd` records, the `wctl`
  read's rectangle and state and the `ctl` read's channel, where a
  reader without its record-length check fails it; a window's end
  leaving the display domain's memory as it was before the window,
  measured by the domain's budget; a seeded window process that keeps
  its image of the buffer fails it.
* **The window system.** `erx_wm_rio` and `erx_wm_single` are pure and
  tested over sequences of place requests and input events; a property
  test that the single policy shows at most one window and delivers every
  event to it, and that every rectangle lies within the screen under
  both; a seeded unchecked move fails it. The menu, drawn as
  an overlay, lies above every window and reaches the screen only
  through `erx_screen:overlay/2`.
* **The input router.** `erx_input` is a pure state machine and is
  tested as one, with both policies and the keymap `us`, over two
  windows side by side. Two exhaustive runs cover every sequence of up
  to six inputs. The keys run takes two sources, three keys (a letter,
  Shift and a chord key, with a one-key chord), a change of the window
  that takes the keyboard, a hide, `release`, a source's end and a
  tick: after each sequence, every window's key events, per source and
  code, are a down, its repeats and one up, in that order, with no up
  before its down; once every source has ended, no key is held and no
  timer is set; repeats reach only the window of their down, and only
  while it is shown; the repeats a window receives are the same when
  the presses of the letter that went to the other window are taken out
  of the sequence; the chord's key reaches no window. The pointer run
  takes two sources, the left button, one touch slot with its down, a
  move and its up, a pointer move from one window into the other, a
  hide, `release` and a source's end: every window's pointer events
  start with the event that began a gesture at it, carry no button it
  did not see pressed, and end with an event that holds none, which it
  receives while hidden too, with no other event while hidden; a
  doubled touch down and an unmatched move or up change nothing. A
  property test over long random sequences with pointer records of
  both kinds, records before the first screen and screen changes checks
  that the pointer lies inside the screen after every step, and that
  the layer a key types at follows from the modifiers held and the
  locks on alone. Each property has its seeded fault: a clamp to `X1`
  instead of `X1 - 1`, a source's end that forgets its keys without
  their ups, an up routed by the policy instead of to its down's window,
  a repeat sent to the window that takes the keyboard, one repeating
  key for the display instead of one for each window, a button's up or
  a source's end whose pointer event the policy routes, a touch down at
  a held slot that moves the slot to another window, and a modifier kept
  as a flag instead of derived; each fails its property. The repeat's
  delay and period are checked against the manifest entry's values, and
  a tick before its time sends nothing. With one source and a router
  that holds its record, `erx_winfs:input/2` does not return, and the
  router's mailbox holds that one record, where a seeded `input/2` that
  sends without waiting fails it.
* **The keymap.** `gen_keymap.rb`'s tests feed it a layout with each
  refusal its section names, a code named twice, an unknown evdev name,
  an unknown special rune, a row of the wrong width, a surrogate and a
  byte above 0x7f, and each is refused; a seeded generator that keeps
  the first of two rows for one code fails the duplicate case, and one
  that takes its codes from every `evdev_key_` name, so a key state
  passes as a key, fails the unknown-code case. A table
  of every key of the US layout, with the rune each layer types, is
  checked against the generated `erx_keymap`. Through the terminal, an
  Up arrow typed at a terminal window reaches its program as `CSI A`,
  and `ESC O A` with DECCKM set, and F5 as `CSI 15 ~`; a seeded layout
  without the arrow's row fails it. With Alt pressed while another
  window takes the keyboard and the terminal's window taken by a click
  before `x` is typed, the program reads `ESC x`, where a seeded window
  whose `k` set holds only its own keys fails it; Backspace sends DEL,
  and Control-H and Control-Backspace send BS.
* **The `screen` file.** A read answers the screen's rectangle and
  channel, and after a change of the screen's size the new rectangle; a
  seeded server that answers the rectangle at the grant's mint fails
  it. A client whose pixel area has no room for another buffer gets
  `enomem` from `erx_win:open/2` and holds the same number of windows
  as before, where a seeded `open/2` that keeps the window when the
  allocation fails fails it; a client at its `windows` quota gets
  `EDQUOT`, and a hundred such refusals leave its pixel area's free
  space as it was, where a seeded `open/2` that allocates first fails
  it. A `mkdir` of `screen` or `snarf`
  fails with `EEXIST`.
* **Draw connections.** The same bytes written by a program to
  `/dev/draw` and handed over by `erx_draw` leave the same pixels in the
  window's buffer; a `v` presents exactly the rectangles the write's
  operations touched, where a connection that presents the whole window
  for a one-pixel draw fails G6's count; a resize makes image 0 anew
  over the buffer at the new size and keeps the client's other images; a
  connection's end frees its images, measured by the session's budget
  before and after, where a seeded leak of one image fails it.
* **The terminal.** Each test below names the seeded fault that fails
  it.
  * Exhaustive: on a 4-column, 3-row grid, every row of the sequence
    tables with each parameter omitted, 0, 1, 2, 3 and 65,535, from every
    cursor position, with pending wrap set and clear, autowrap and origin
    mode on and off, every region, and a width-2 cell at every position;
    the invariants of [Cells and the grid
    state](#cells-and-the-grid-state) hold after each step, and the same
    enumeration goes to the oracle. An insert that shifts half of a
    width-2 cell without blanking it breaks the pairing invariant.
  * Splitting: every corpus case fed whole, one byte at a time and split
    at every offset gives the same state and effects. A decoder that
    drops a UTF-8 sequence cut at a call's end fails it.
  * The oracle comparison of [The oracle](#the-oracle) over the whole
    corpus, with `test/vt/differences.txt`. A `CUP` that leaves its
    default at 0 fails the per-row cases.
  * Coverage: the test fails if a row of the tables has no corpus case,
    or if the ignored-sequence counters are not zero over the
    `prim_tty`, toybox and `vttest` recordings. With `CHT` removed from
    the table, the `prim_tty` recording's counter fails it.
  * Bounds: a CSI with 17 parameters dispatches the first 16; an OSC of
    4 KiB applies and one of 4 KiB and one byte is dropped; an
    unterminated OSC followed by `ESC c` resets the terminal; a stream
    of 300 links leaves 256 in the table and the oldest cells plain. A
    bound raised to 8 KiB, a 17th parameter accepted or a string that
    ignores ESC fails its case.
  * Replies: G8's reply test.
  * Widths: a test re-derives every code point's width from
    `UnicodeData.txt` and `EastAsianWidth.txt` and compares it with the
    generated table. A table that leaves out `F` fails it.
  * Links: the link parser's fuzz target; cases at every rule of the
    grammar, a `%0A` in a link's text among them, which must drop the
    sequence, and a context followed by its closing, which must keep the
    context. A decoder that admits a decoded control fails the first.
  * termcap: every string capability of `abi/termcap`, with its `%d`
    and `%i` arguments expanded, is fed to `erx_vt` and must leave the
    ignored counters at zero, and every capability removed from FreeBSD
    15.1's entry must be named in the file's comments. An entry that
    keeps a capability outside the tables fails the first.
  * `erx_vt`'s fuzz target over arbitrary bytes, with G8's size check
    and the invariants after every call.
  * V1's byte test with `erx_term` in place of the serial line: the
    bytes handed to its tty reach `erx_vt:feed/2` unchanged, where a
    seeded filter fails it; G4's `no_facet` test; a seeded action in the
    emulator that calls a facet is caught by the source check.
  * The terminal's loop, in hosted mode with a session and a display:
    removing its window from the menu sends `tty_hangup` and the shell
    ends, where a terminal seeded to keep its tty open fails it; the
    shell's `exit` ends the terminal and its window; a resize reaches the
    shell as `{tty_size, Rows, Columns}` within the bounds; Ctrl-Shift-N
    opens a sibling in the session's directory, charged to its `windows`
    quota and refused with `ENOMEM` past it, while Ctrl-N reaches the tty
    as byte 0x0e, where a terminal seeded to keep Ctrl-N fails it.
* **The display's session.** A boot whose manifest has a start row
  naming a person's principal and the display starts that principal's
  session with `display` set, makes its connection to the display with
  a pixel area of the template's facet row's `pixels`, gives it its
  grant with `session` set, and shows its terminal's window, whose
  shell runs in the session's domain; closing that last window brings a
  new one; a restart of the display domain brings one on the new grant;
  and ending the session's domain brings a new session and its
  terminal, from the row's keeper. A seeded domain service that skips
  the grant fails the first, a seeded `erx_term_sup` that starts
  nothing on a new grant fails the third, and a keeper that does not
  monitor its session fails the last. A login at the UART of the same
  principal holds a grant on the display, opens no terminal there, and
  opens a window under the overlapping policy, where a seeded
  `erx_term_sup` that opens a terminal on every grant fails it; a
  session whose template has no row for the display answers `{error,
  no_display}` to `erx_ui:open/1`. A manifest whose display's facet
  rows, each template's counted by its principal's `domains` quota,
  pass the display domain's budget is refused by property 18, where a
  check that counts a template's row once accepts it and fails; a
  facet row that sets `session` is refused. With the display and its
  session running, the console's lines are the UART and the host link
  alone and the display domain holds no facet of the console service,
  where a seeded manifest that grants it one fails it.
* **Widgets.** Each passing case beside the seeded failure that proves it
  ran:
  * `erx_ui_schema`'s fuzz target over arbitrary terms: every
    accepted tree is valid by an independent checker written from the
    property table; a validator without the depth check fails on a tree
    65 deep;
  * keys: duplicate keys under one node refuse the tree whole with
    `duplicate_key` and its index path, and one key under two parents is
    accepted as two nodes; a validator that checks keys across the tree
    fails the second;
  * `pair/3` and `delta/2` over random trees and edits: `apply_ops(delta(A,
    B), A) == {ok, B}`; an unchanged subtree emits no operation; a child
    moved among its siblings keeps its number and its kept state, and a
    subtree moved to another parent gets new numbers and none; a
    `delta/2` that drops the `move`s fails the first property, and a
    `pair/3` that pairs keys across parents fails the last;
  * the state rule: an `input`'s text typed by the user survives a tree
    that omits `text` and yields to one that sets it, and a `slider`'s
    kept value outside a new range is dropped; a `pair/3` that keeps
    every omitted property fails;
  * `hit/4`: a report for a removed node, for an event the node does not
    take, or with a value outside the node's bounds fires nothing; a
    `select` carries the tree's own `{Type, Value}` whatever the renderer
    reported; a `hit/4` that takes the value from the report fails;
  * the binary form: each generated reader, in Erlang, C and TypeScript,
    has a fuzz target, and the three accept the same inputs and decode
    the same operations and events; a reader with two property numbers
    swapped fails the parity, and an event reader without the detail's
    length check fails its fuzz target; the generator refuses a seeded
    `ui.txt` with a property number used twice, a kind that takes
    `on_change` with no state property, a kind whose largest `insert`
    exceeds one update, and an `image/svg+xml` image type;
  * the **parity test**, one corpus of trees and input sequences run
    through every renderer, the web's browser renderer included,
    comparing meaning alone: the events and values the application
    receives and the set of nodes present, never pixels or layout, where
    a seeded swap of two event names in the LVGL mapping fails it;
  * G7's status tests through a widget tree, for `present` and for a
    label's `text`;
  * `erx_ui:open/1` with no display answering `{error, no_display}` at
    once, a UI opened by name landing on that display with the renderer
    its options name, and a stopped display domain making each widget
    server on it send its opener `{ui_down, Window, display_down}`,
    where an `erx_ui` that ignores the `display` option fails;
  * a `secret` input's text absent from the server's state, from every
    renderer's model and from every printed form, and a tree that sets
    its `text` refused; a `hit/4` that records a secret input's text
    fails.
* **Presentations.** The round trip `parse(Type, text(Type, Value)) ==
  {ok, Value}` for every marked path and a generated corpus of values,
  where a seeded change to the URI encoding fails it; `path/2` names the
  marked path with the value in place, where a generator that writes a
  module's segments in the wrong order fails; the generator refuses a
  seeded schema with two presentations of one segment over one type, a
  presentation named by each refused name in turn (`accept`, `proc`,
  `ui`, `trace`, `login` and `ws`), and two marks on one path; the
  renderer emits links only with `links` declared, checked at the tty's
  byte boundary; the input context highlights exactly the types the
  catalog declares for a command.
* **Drivers.** The virtio-gpu driver's response parser, the
  virtio-input event and configuration parsers and its update fold, and
  the touch controller's, the keypad's and the encoder's bus parsers have
  fuzz targets, as does the reader of the records another domain serves,
  whose every accepted record lies within `record()`'s bounds, and the
  fold's target asserts that its state never holds an event; the fold's
  tests check that a device's repeat value sends nothing, where a seeded
  fold that forwards repeats fails it; that `SYN_DROPPED` sends
  `release` and that a key's down after it and before the next
  `SYN_REPORT` sends nothing, where a seeded fold that resumes at once
  fails it; that a move, a button's down and a move in one update send
  the first move before the press; that two relative events of
  2147483647 in one update send two moves of 2147483647, where a seeded
  fold that sums without its range check fails it; and that an axis's
  minimum and maximum normalize to 0 and 65535; a driver's reads of an image
  run under UBSan with strides, rows and columns at their bounds, where a
  seeded unchecked offset fails it; the harness runs the display suite
  under QEMU `virt` with a virtio-gpu and virtio-input attached and
  compares screenshots taken through QEMU's machine protocol (QMP, on an
  owner-only UNIX socket; `-display none` stays) with reference images,
  under HVF; a screenshot equals a reference when the SHA-256 of its
  decoded pixels (width and height as two big-endian 32-bit numbers, then the RGB888 rows) equals the digest
  checked in beside the reference picture; a seeded wrong channel
  conversion fails it.
  A panel driver is tested against a model of its command set on the
  host, on the copy path and on the direct path, which must send the
  same bytes.
* **A kiosk.** Each passing case beside the seeded failure that proves
  it ran:
  * under QEMU `virt` with the kiosk manifest, which ships the app's
    principal, template, facet rows and a start row naming it and the
    display, the app's session starts at boot with no login, its release
    starts the application, the application's window covers the screen,
    and the screenshot through QMP equals the reference image
    under HVF; the start row disabled leaves the background and fails
    it;
  * the two images of the worked example differ in the app alone: the
    manifest, apart from the app's own rows, and the display domain's
    release are byte-identical between a boot with one app and a boot
    with another, and each shows its own app; a display release that
    names the app fails;
  * ownership through the session's restart: a second app whose
    template is granted the display runs and opens a window; the kiosk
    app's session is ended, and while it restarts and after, the second
    app's window stays hidden and takes no input, and the new session's
    window is shown once made; a seeded `erx_wm_single` that shows the
    oldest window of any grant fails it, and a seeded domain service
    that sets `session` on every grant on the display fails it;
  * ownership through the display domain's restart: with the second app
    running, the display domain is killed; it restarts, the kiosk app's
    session, which keeps running, receives its grant again and its
    window covers the screen, and the second app's window stays hidden;
    a seeded domain service that sets the mark only in a grant's first
    mint leaves the background and fails it;
  * killing the application's top process leaves the session's domain
    running and brings the window back from the application's
    supervisor; an application started outside its supervisor fails it;
  * ending the session's domain brings a new session of the same app
    and its window back, and ending it more often than the row's
    intensity allows leaves the background and the row `down` at
    `/proc/apps`; a keeper that starts nothing after the first end
    fails the first half, and a row supervisor without the row's
    intensity fails the second;
  * a second window of the application and a window of another domain
    stay hidden and take no input (G1's test), with the first still
    shown;
  * `erx-lvgl` runs as a program of the session: the session's process
    table lists it, its pipes are the session's, and its sub-space holds
    its buffer's pages and no other page of the pixel area, so a store
    one page past the buffer faults in the program; a session that maps
    the whole area into it fails;
  * the Erlang reader of the program's records and the C reader of the
    server's have fuzz targets, the `damage` report among them; a reader
    without the report's count check fails its fuzz target;
  * a `damage` rectangle outside the size the report names, and
    a second report before the first is answered, each stop the
    program, and the application receives `{ui_down, Window,
    renderer_down}`; an `erx_ui_lvgl` that presents them fails;
  * a refresh with several areas: against the model screen, a tree
    change that invalidates three areas apart from each other makes
    LVGL call the flush three times; the program answers the first two
    at once and writes one `damage` report of three rectangles, and
    the refresh completes at `presented`; a program that holds every
    flush until `presented` stops at the second area, where LVGL waits
    on the first flush, and fails the model screen;
  * a resize during a frame: against the model screen, the window is
    shrunk while a report drawn at the old size is open; the program
    receives the new `screen` record at once, draws nothing until
    `presented`, the report is presented at the old size, clipped, and
    the next report covers the new size; an `erx_ui_lvgl` that judges
    the report again against the `screen` record it wrote after reading
    it fails;
  * `erx_ui_lvgl_core`, explored exhaustively: every event in every
    reachable state to a depth of six, over two sizes, keeping a present
    only of a report at the last `screen` record's size, nothing but
    `screen` records written while a present is outstanding, every
    report answered once, and an apply's operations and the window's
    records written in order and only after the answer; seeded faults
    that hold a resize, write an apply while a report is open, write
    the held records before `presented` or present a second report each
    fail it;
  * a resize while a report is unread: against the model screen, a
    `screen` record is written after a report has arrived and before
    it is read, once smaller and once larger; the report names the old
    size, so it is presented as nothing and answered, and the next
    report covers the new size; a model screen that judges the report
    against the last `screen` record written refuses the smaller case
    as outside the screen, and in the larger case would present rows
    of the old stride as the new size's;
  * the program draws nothing between a `damage` report and its
    `presented` record: the model screen compares the buffer's bytes at
    both ends of that interval; a program that tells LVGL the last
    flush is done at once fails;
  * a driver restart is followed by exactly one push of the whole screen
    from the application's buffer, and no record reaches the program; an
    `erx_screen` that does not monitor the driver fails;
  * `erx-lvgl` builds for the host and runs against a model screen, a
    host process that plays `erx_ui_lvgl` and the display over the two
    pipes and a file both map as the buffer, so the parity corpus and
    the readers' fuzz targets run without QEMU.
* **Power.** G6's idle test at the driver, on the desktop and on a kiosk
  under LVGL, where an LVGL build with animations on fails it.
* **Failures.** One injected fault per row of the failure table above,
  each under QEMU `virt` with clients drawing: the fault is raised in the
  party the row names (a malformed write, a refused present, a full
  pixel area, a holder's end, a client domain's end, a crash of each
  process the table lists, the display domain's end, an invalid tree,
  the LVGL program's exit, an input device stopping, a full queue, a
  present with the panel off), and the test checks the row's effect and
  recovery and that nothing outside what that party owned is lost: other
  windows keep their pixels and input, and a session whose terminal
  crashed keeps its other terminals and its jobs, the crashed terminal's
  shell getting the hang-up. A seeded supervisor that restarts the whole
  display domain for a child's crash fails it.
* **Confinement.** The manifest check refuses a release manifest that
  gives the display domain an unconfined DMA device, a virtio-mmio one
  among them, and names the device and the property; the same manifest
  marked as a development build passes, with the display domain reported
  in the trusted base. A seeded check that skips the display domain's
  devices fails it.
* **Chokepoints** (below) each have a test with a seeded violation.

### Chokepoints

| Rule | Check |
| --- | --- |
| Only `erx_memdraw_draw` and `memdraw`, the shapes' one way to draw, call `memimagedraw`, and only `erx_draw_clip` makes the `erx_clip_t` it walks | `memdraw-clip` (tools/lib/erx/chokepoint_rules/memdraw.rb), over erXos's sources and its copy of `libmemdraw`: `memimagedraw` and `erx_clip_t` appear only in `draw.c`, `memdraw.h`, `erx_draw_clip.c` and `erx_memdraw.c` |
| Only the functions that walk a checked rectangle touch pixel memory: `libmemdraw`'s draw, load, unload, cload and allocation, and `erx_memdraw`'s snapshot; and `erx_area:zero/3`, over a checked range of whole pages, stores zero | `memdraw-pixels`: `bdata`, `byteaddr` and `wordaddr` appear only in their files, so a shape, the NIF or new code that writes pixels itself fails the build |
| Only an image resource's destructor frees an image a term can reach or lets go of the memory it lies over | `memdraw-free`: `erx_memdraw_free` is called only from the NIF, by `image_dtor` and by the test-only `cload` for the image it made itself |
| Only `erx_memdraw:store/4` writes a firmware framebuffer, through `erx_fb_store`'s aligned 32-bit stores after the layout and every rectangle are checked, and only `erx_device:framebuffer/0` maps one, from the domain's own record | `memdraw-framebuffer`: `erx_fb_store`, `erx_framebuffer.h`, `erx_framebuffer_view` and `erx_device_framebuffer_memory` appear only in the store's files, the NIF's, the device NIF's and the store's host test |
| A pixel area is mapped in two places, into the runtime by the connection agent, `erx_connections`, and into a program's sub-space from a lease, and a lease is a whole range of one owner, made by `erx_pixels`. So every mapping is one the agent waits for before it answers that the connection is unmapped, the display's mapping is the read-only one the agent asked for, and a program maps only its handler's buffer | `area-mappers` (tools/lib/erx/area_mappers.rb). Over the Erlang sources of `otp/` and `erlang/`: outside `erx_area` and `erx_connections`, the atom `erx_area` appears only as the module of `open/1` and of the type `area()`, and in `erx_pixels` as the module of `lend/5`, `unlend/1` and `zero/3` too, so `map/4` anywhere, or `lend/5`, `unlend/1` or `zero/3` outside `erx_pixels`, as a call, a fun, an apply's arguments, an import, a macro, a literal or a string fails the build. Over the C of `otp/erts/emulator`: `erx_area_lease_take`, `erx_area_lease_map` and `erx_area_lease_return` are called only from `erx_program_drv.c`, and a seeded call of each from another file fails it |
| Only `erx_memdraw:wrap/4` makes an image over memory `erx_memdraw` did not allocate, and only after checking the range | a source check over the NIF: the one site that sets an image's data pointer from an area or a device's region ([design-runtime.md](design-runtime.md#the-device-nif), Regions) |
| Only `erx_screen` writes the screen image, makes images over clients' pixel areas, and calls `erx_display:flush_request/3` and `erx_display:power_request/2` | the writes and the images: an xref check over the display release; the calls: `display-driver-callers` (tools/lib/erx/chokepoint_rules/display.rb), over the Erlang sources of `otp/` and `erlang/`: outside `erx_screen`, neither function is named as a call target, as a remote call, a fun, an apply, a module and function pair, a call through a module in a variable or a macro, an import from `erx_display` or a macro defined as it |
| Calls run window to `erx_screen` to driver: `erx_screen` makes no call to a window, and the driver none to `erx_screen` or a window | the same xref check, over calls and `gen_server:call` targets |
| Only the display driver's process calls `erx_device`'s functions on the display device | the same xref check; and `device-callers` admits the display drivers' application, `erx_fb`, among the driver applications, while `device-posters` admits `erx_virtio_gpu` alone of it to call `erx_device:post/4` |
| Only `erx_winfs` and its routing core `erx_input` call `erx_wm`'s callbacks: `erx_input` alone calls `input/4` and `erx_keymap`, and `erx_winfs` alone the others | the same xref check |
| The display release holds no draw decoder, picture or font reader, widget module or renderer, and starts no program | an xref check that the display release contains none of `erx_draw_core`, `erx_draw_codec`, `erx_draw_image`, `erx_font`, `erx_png`, `erx_inflate`, any module of the client applications `erx_win` and `erx_ui`, and calls no function that starts a port or a sub-space; a seeded dependency on each fails it |
| Only `erx_winctl` reads a `ctl` line, and only `erx_wctl` a `wctl` line | a source check over the display release |
| Only the generated `erx_draw_codec` decodes draw bytes, and only the generated reader decodes the native renderer's events and reports | the generated tree's determinism test, and a source check that no other module reads those bytes |
| Only `erx_area_lease_map` maps memory into a space other than the runtime's own, and it maps only its lease's range, read-write, at the buffer place | the C half of `area-mappers`, over every C file of `otp/erts/emulator`: an `erx_vm_map` whose space is not `ERX_CAP_SELF` appears only in `erx_area_lease_map`, so no other mapper, whatever slot it is handed, maps into a program; a seeded such call in `erx_program_drv.c` fails it |
| Only `erx_render` writes the link and input-context sequences | a source check for the `erx:` URI prefix |
| `erx_term` and `erx_ui_server` call no facet | an xref check that neither module nor its callees reach `erx_facet` clients |
| Attributed text in a window passes through `erx_text:escape_line/1` | the source check of V9 extended to `erx_wm_menu` in the display release and to `erx_ui_erlang` and `erx_ui_lvgl` in the widget application |
| No NIF of the display release takes a client's bytes to parse | a build check over the release's NIF libraries and ERTS's own NIFs in the display release, `zlib_nif` among them, and their exported functions, a closed list with each function's use of the binaries it takes; a new NIF or function fails it |
| No module of the draw and widget applications calls a native parser of ERTS on a client's bytes | an xref check that no module of those applications calls `zlib`, `binary_to_term/1,2`, `re` or `erlang:decode_packet/3`; a seeded call to each fails it |
| Only `erx_vt` interprets a terminal's output | a source check that no other module of `erx_term`'s application matches on ESC, CSI or OSC bytes |

## Performance

What a changed pixel costs, by path, counting copies in the machine
between the renderer's write and the device:

| Path | Copies | Then the device |
| --- | --- | --- |
| a client's renderer into its buffer (LVGL, the Erlang renderer, a draw connection, a terminal) | none: the buffer is where it draws | |
| copy path: the buffer into the screen image | one, of the changed rectangles, clipped to what is visible | virtio-gpu transfers the rectangles to the host; a firmware framebuffer shows them; a panel driver sends them on its bus |
| direct path: the device reads the buffer | none | as above, from the client's memory |

A kiosk's frame under LVGL on QEMU `virt` on the stopgap is therefore
one copy of the changed rectangles and the device's transfer, and on a
confined virtio-gpu or a panel on a bus no copy.

Numbers to measure, for [todo-performance.md](todo-performance.md):

* the copy path's rate from a mapped pixel area into the screen image,
  in MB/s at 1920 by 1080 on HVF, and the same under TCG;
* a present's round trip, from the client's write of `ctl` to its
  answer, through the lane, the funnel, `erx_winfs`, the window process,
  `erx_screen` and the driver, against the device's frame time: it sets
  the frame rate a client can reach, and decides whether presents need a
  shorter way than a file write;
* a kiosk's frame under LVGL at 800 by 480 and at 1920 by 1080 on HVF:
  LVGL's render into the mapped buffer, the `damage` report's pipe round
  trip, the present, and the `presented` record back;
* what the sessions on a display reserve and leave unused, since a pixel
  area is charged whole when its connection is made; the measurement is
  the bytes `erx_pixels` has handed out against each area's size on a
  desktop in ordinary use, and it settles whether areas need to grow on
  request;
* a terminal's scrolling of a large `cat` at 80 by 24 and at full screen
  on HVF, drawing through `erx_draw` in its own session;
* frame times of several windows animating at once, since copies
  serialise through `erx_screen` and frames gather presents;
* the dirty-scheduler threshold for draw operations;
* the Erlang renderer's diff, layout and draw time per frame on a 240 by
  240 panel against LVGL's, which is the gate that retires LVGL;
* the terminal emulator's redraw per changed line of cells, and the
  pixel copy of scrolled rows against redrawing them;
* `erx_vt`'s throughput in bytes per second, a code point at a time in
  Erlang, over a large `cat` of text, of text with SGR on every word and
  of wide characters, against libvterm's on the same corpus;
* virtio-gpu's transfer and flush latency per rectangle under TCG;
* the direct path against the copy path on a confined virtio-gpu, once
  erXos's kernel runs the device behind the IOMMU.

## Portability

Nothing here names an architecture. The display and input devices are
rows of the device table per platform: virtio-gpu and virtio-input on
QEMU `virt`; the firmware framebuffer and a touch controller, keypad or
encoder on the boards' buses; panels on serial buses on small devices.
A device that shows pixels is a driver behind `erx_display`, a device
that makes input a producer of input records, and a device that composes or
draws attaches as [Graphics hardware](#graphics-hardware) says.

## Dependencies

| Component | Purpose | License | Status |
| --- | --- | --- | --- |
| Plan 9's `libmemdraw`, from 9front | the per-byte pixel primitives of `erx_memdraw`; its image(6) loader `cloadmemimage` is linked into no release, since the `Y` decoder is the Erlang `erx_draw_image` | MIT (9front's `lib/legal/NOTICE`, whose exceptions cover only fonts) | permanent; 9front at commit 2859ae04, imported as erXos's code into `display/libmemdraw` with an `ORIGIN.md` listing its edits |
| the 9front build: 9front's `libmemdraw` and the parts of its `libdraw` it links, unmodified | test tool: the oracle of the shapes' pixels, of every `erx_memdraw` operation against the code it was imported from, and through `cloadmemimage` of `erx_draw_image`'s decoding and of the C twin's framing of `Y` (Verification) | MIT | tool, never part of a shipped image; fetched at the commit the import's origin file records, verified against a pinned SHA-256, and built for the host out of tree by erXos's own compiler invocations against plan9port's `lib9`, which is already fetched for rc; 9front's mkfiles never run |
| plan9port's `libdraw`, acme, sam, 9term | draw clients, and oracles of the draw protocol's compatibility | MIT (to be confirmed at import) | permanent; ported as erXos's code with the connection code replaced |
| LVGL 9 | the native widget renderer for panels, the program `erx-lvgl` of the application's session | MIT; its built-in fonts are OFL-1.1 font data | stopgap, replaced by the Erlang renderer when the parity test and the panel's frame times admit it; a git submodule from erXos's fork pinned at a recorded commit, built out of tree as a native program, its display and input glue erXos's own |
| a bitmap font as Plan 9 subfonts | the glyphs of `erx_term` and of the Erlang renderer, in a session's release, and of the menu, in the display's | plan9port's `fixed` fonts (public domain); anti-aliased fonts, such as the Go fonts (BSD-3-Clause) rasterised by a host step, chosen with the first application that needs them | permanent |
| libvterm 0.3.3 | the differential oracle of `erx_vt` | MIT | test tool, never in an image and never linked into erXos; fetched at its pinned release and SHA-256 and built out of tree for the host with the harness `test/vt/vterm_dump.c` |
| `vttest`, Thomas Dickey's | the source of the corpus's `vttest` recordings | MIT-style (X11), confirmed at the pin | test tool, never in an image; fetched at a pinned release and SHA-256, built out of tree for the host and run on a host pseudo-terminal |
| FreeBSD 15.1's `share/termcap/termcap`, from the pinned FreeBSD source | the `xterm` and `vt100` entries `abi/termcap` restricts | BSD-3-Clause, confirmed at the pin | reference; the restricted entries are erXos's text in `abi/termcap` |

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| the widget toolkit and the LVGL program inside the display domain, with a screen owner of its own for a kiosk | an application's interface then runs with the display's authority and on its budget; the display needs a second screen owner, a widget service behind a facet of its own, a renderer target for a bare screen, and a native program whose pipes no session homes; a kiosk becomes a different system from a desktop, with its own failure rows and tests; with rendering in the client's session each of those is gone and a kiosk is a policy |
| Plan 9's model whole: every pixel reaches the display as a draw message, executed there into images the display holds | keeps the display parsing every client's draw bytes and running a NIF on their behalf, charged to the display; content a client rendered itself, LVGL's or a GPU's, must be sent as `y` loads, each copied into a lane, out of it by the funnel, through the file server and into the image, then to the screen image and to the device, five copies where a buffer costs one; and a buffer a GPU filled has no way in at all |
| both: draw messages executed in the display for draw clients, and buffers for the rest | two kinds of window content, two quotas and two sets of failure rows, and the display still parses draw bytes; executing the same messages in the client's session costs a draw client nothing it can observe, as plan9port shows |
| Wayland's protocol (surfaces, roles, `wl_shm`, `linux-dmabuf`, `xdg-shell`) | its rules for buffers are taken; its protocol assumes file descriptors passed in messages, buffers a client allocates and the compositor must validate, and a library on both sides; a window as five files and one command carries the same rules with mechanisms erXos has |
| Fuchsia's sysmem and Flatland | allocation negotiated at run time among participants, a scene graph for each client and fences as kernel objects; erXos states the one constraint, the area's size and kind, in the manifest, has rectangles of pixels and no scene, and uses the present's answer as the fence |
| QNX Screen's interface | the closest in shape; it allocates each window's buffers on request and gives windows to clients as a C library of properties over messages; the pixel area makes allocation a matter inside the client, and files replace the library |
| a memory object for each buffer, made by the system domain on request and installed in both domains | sizes fit each window exactly, nothing is reserved ahead, and a program is handed its buffer as a capability; but every window and every resize then waits on the trusted base for a creation, two installs, two acknowledgements and, later, a deletion once both have unmapped, a protocol with a state machine and failure rows of its own; one area in the connection's existing plan needs none of it, and its cost, memory reserved ahead, is on the watch list |
| the pixel area as more pages of the client's side of the connection | no object added to a connection, but a session that maps a buffer into a program would be mapping pages of the object that holds its lane to the display, where one wrong offset hands a program the lane; an object of its own makes that mistake impossible |
| the client paying for its pixel area | charges a user's windows to the user; but then the writer pays for memory its reader must keep mapped after the writer's end, the reverse of every other object of a connection; with the reader paying no rule is added, and the grant bounds what it pays |
| the display allocating each window's buffer, as QNX Screen and Android do | the display knows its device's constraints; but the buffer would be memory of the display's that a client must map and write, and no domain passes a capability to another, so the system domain would stand in every allocation as in the per-buffer row above |
| a screen image of the display's own, copied to the device's memory after composing | one more copy of every changed pixel; composing into an image over the memory the device shows needs none |
| asking each window for the pixels a layout change uncovers | the display then waits on every client whose window is uncovered, and a slow client leaves a hole on the screen; with the buffers mapped the display copies what it needs at once |
| a release message and a frame message, as Wayland sends | two messages, an order between them, and a client that must not draw before one and must draw after the other; the present's answer is both |
| the menu as a window of the display domain's own | the display would need a pixel area with itself and a client's path to itself; an overlay that only `erx_screen` reads is less |
| `pixels` reports over the LVGL program's pipe, copied into the buffer by the session | no mapping into the program, but two more copies of every changed pixel, into the pipe and out of it, and a bound on a report's size that cuts large areas into bands |
| a `session` field, session quotas and a restart intensity in the display's manifest entry, with the domain service as the session's starter | a second place that says what starts without a person and a second restart owner beside the start table's keepers, and a pixel area the manifest states apart from every other grant; a start row and the template's facet row say the same with the mechanisms every app uses |
| the first session to open a window on a single-policy display takes the screen | no mark is needed, but while the display's session restarts any other session holding a grant takes the screen and its input; marking the grant from the start row leaves nothing to race |
| a display's restart rule in the session template | a template says how a principal's sessions are made, for a login as much as for a display, and has no restart intensity ([design-system.md](design-system.md#the-manifest), property 14); an intensity there would have to be ignored for every session a person logs in to |
| a display's restart rule in the application's package | the intensity protects the machine from a session that ends at once, again and again, so it is not for the application to choose; the start row sets it, written by the image's builder or the machine's administrator |
| a buffer freed explicitly by its window's code, as a heap block is | one call to remember on every path that ends a window or a program, and a page handed out again while a program still maps it; a range that goes back only when its owner process exits needs no call and cannot be reused under a live mapping |
| `erx_screen` waiting on the driver's answer to a frame, with presents and layouts queued in its mailbox | a stalled device grows the display's heap with every `wctl` and every window made and ended; pending state replaced in place bounds it by construction |
| X11 (a server, or a rootless server over draw) | the server is a large C program with its own authority model; a rootless X server over the draw protocol stays a possible compatibility layer for FreeBSD programs much later and changes nothing here |
| wxWidgets, GTK, Qt | whole native toolkit stacks in C++ with their own event loops and renderers; against the C17-and-Erlang rule and against principle 3 |
| Scenic (Erlang/Elixir scene graph) | a scene graph owned by the application in its own process, drawn by a native driver; its model is close to this document's widget trees, which take its idea of a declarative tree and drop its native driver protocol for the draw protocol |
| keys unique across the whole tree, with `move` naming a new parent | a subtree could change parent and keep its state, but validation, pairing and `apply_ops` would each have to refuse a node moved under its own descendant, and the pairing would search the whole tree for each key; with keys among siblings a node never changes parent, `move` names none and the cycle cannot be written |
| a difference that pairs the application's tree with the realised one, beside a second difference between two realised trees for the web | two functions with two property tests that must agree; numbering first and one difference over numbered trees serves the window and the browser alike |
| a per-kind property namespace | the binary form's `set` would need the node's kind to read its properties, so every reader would keep state; one property table keeps the readers stateless |
| Arcan | a display server with a scripting engine and its own client library; too large a trusted component, and its model of frameservers duplicates erXos's programs |
| LVGL everywhere, as the one renderer | puts every desktop widget's layout and logic in C in a sub-space and makes the widget tree a C data structure; the Erlang renderer keeps layout and state in Erlang where they are small, and LVGL stays where its fonts and widgets pay |
| Inferno's Tk, widget commands as strings | strings parsed at run time, with the quoting and injection problems Tk has; terms are checked by a generated schema and need no parser |
| imperative widgets (`gs`-style create, configure, destroy) | handles and commands put a protocol of sequencing on every application; a retained tree with a diff gives one rule for state and none for order |
| each window composing into the screen image under a lock | spreads writes of the screen image over every window process and `erx_screen`, and needs a lock in the NIF, rules for who takes it, and race tests; one writer of the screen image costs only that composes queue in one process |
| text rendering in the display domain for clients | would need a font engine and font files parsed from untrusted input on the server side; Plan 9's client-side glyph cache keeps the server free of both |
| a terminal in the display domain, as a console line or as rio's own text window | the display would parse every session's program output beside every window's pixels and keys, and would need the console's lines, logins and single-use tokens to decide which session a window serves; a terminal in the session, as xterm is a client of X, needs none of them and is charged to the session that uses it |
| libvterm or another C emulator as a NIF | a native parser of program output whose fault ends the session's whole runtime, its shells and other terminals with it; a C emulator in a sub-space of its own would be safe and is not needed |
| the `Y` decoder in C inside `erx_memdraw` | the one native parser of a client's bytes in the whole stack; compressed loads are fonts and images loaded once, not a hot path, so an Erlang decoder costs nothing that matters and leaves `erx_memdraw` parsing nothing |
| a scrollback size set per terminal or in the manifest | a parameter nobody has asked for; 131,072 cells, about 1,600 rows of 80 columns, stays fixed until a user asks for more |
| a terminal type of erXos's own, `TERM=erxos` | an honest entry, but unknown to every other system a session reaches and to every program with built-in knowledge of xterm; FreeBSD named vt(4) `xterm` for the same reason |
| terminfo, as Linux distributions use | FreeBSD describes terminals in termcap, and erXos follows FreeBSD; its one consumer at run time reads a generated table |
| xterm.js or tmux as the oracle | xterm.js brings Node into host tooling, which TypeScript's rule keeps out; tmux takes its widths from the host's C library and needs a server process; xterm itself has no headless dump |
| grapheme clustering, so an emoji sequence takes one cell pair | terminals disagree on it and programs' `wcwidth` cannot express it, so the cursor would part from what programs compute |

## Risks and decisions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| plan9port's `libdraw` is harder to rebase on the file connection than expected | medium | acme and sam arrive later | the window files match Plan 9's native names and formats, so 9front's `libdraw` is the fallback source of the connection code |
| `libmemdraw` keeps state that is not safe across schedulers | low | races in the NIF | checked at import; the primitives' tables are read-only after `memimageinit`, and within a runtime no image is touched by two processes at once (G2) |
| 9front's `libmemdraw` needs more of a Plan 9 environment than plan9port's `lib9` gives, so the 9front build does not compile on the host unmodified | medium | the shapes lose their oracle until it does | a header of erXos's own beside the build's recipe supplies what is missing; 9front's `.c` files are never edited, since an edited oracle checks nothing |
| copies serialised through `erx_screen` limit a desktop with several animating windows | low | dropped frames under load | the watch-list measurement; `erx_screen` gathers waiting presents into one frame |
| a board's panel bus controller does DMA it cannot confine | medium | the panel cannot be driven from the display domain in a release build | the board's DMA contract says so; such a panel is driven without DMA, which a few hundred pixels afford, or its driver runs in a domain of its own |
| the Erlang renderer never reaches LVGL's frame times on panels | medium | LVGL stays | acceptable; it is a bounded native program behind the seam |
| OSC 8 links confuse a terminal that declares `links` wrongly | low | stray characters | links follow the capability table; the serial console's default is off |
| a program, or a session reached remotely, uses more of xterm than the subset, since the terminal is called `xterm` | medium | a misdrawn screen in that program | local programs read the restricted termcap entry; the ignored counters name the sequences, which become rows of the tables when a program needs them; FreeBSD's console has the same gap |
| `io_ansi`'s fallback strings on erXos include forms that are not the sequences they name: `cursor_home` is `ESC H` (HTS), `scroll_forward` and `scroll_backward` are `ESC S` and `ESC T`, `tab_backward` is `ESC I`, and `hyperlink_start` writes the URI before the parameters (`otp/lib/stdlib/src/io_ansi.erl:2614`, `:2646-2649`, `:2684`, `:2788-2790`) | high, on every erXos terminal, since erXos has no terminfo | `io_ansi` callers misdraw | upstream OTP bugs, which erXos's OTP fixes, since erXos owns its OTP (the work is in `TODO.md`); `erx_vt` implements the standard sequences and does not imitate them |
| a program on a remote host, reached over `ssh`, counts widths from its own tables | medium | a cursor parts from the text after a wide or combining character in that program | every program on erXos, the line editor and `erx_vt` read the one width table; a remote host's tables are its own, as between any two UNIX systems |
| a display's session needs no passphrase | certain, until the login design | whoever is at the display holds what its session offers | a person's principal is named for a display only by a start row of the board's manifest, deliberately, and work that needs the principal's vault keys logs in at the UART or the host link; a kiosk's session is an app's, which holds only its template's grants; the login design (decision 14) replaces the first |
| LVGL's periodic timers, its display refresh and input read, wake the program with nothing changed | medium | an idle kiosk spends CPU on a period, though it reports no pixels | the program reads input in LVGL 9's event mode, once per `input` record, and resumes the refresh timer only on an invalidation; the kiosk's idle test counts the program's wakes beside the driver's requests |
| a pixel area is charged whole when its connection is made | certain | a desktop's sessions hold memory for windows they have not opened, and a template's facet row is budgeted for every session its principal's `domains` quota allows | a grant's `pixels` is the board's choice; the watch list measures what is used; areas that grow on request are the change that measurement would justify |
| a client with one buffer shows a half-drawn frame on a device that reads its buffer all the time | medium, on the direct path of hardware that scans memory out | tearing in that window | two buffers, for which a kiosk's `pixels` leaves room; virtio-gpu and a panel on a bus read the buffer only during the present |
| every session that draws holds the `erx_memdraw` NIF | certain | a fault in `libmemdraw` ends that session's runtime, its shells and terminals with it | the NIF parses nothing and walks only checked rectangles; its differential and sanitizer tests; the same fault in the display domain would end every session's windows |
| the QEMU kiosk waits for programs with pipes in a session and for the start table's apps | certain | the kiosk's demo follows the window stack, track P's first slice and track A's second part | the window stack is shown first by a client that draws in Erlang, in a manifest principal's session that a start row starts, which needs only track A's first part, and `erx-lvgl` runs on the host against its model screen meanwhile ([plan.md](plan.md#track-d-windows-widgets-and-the-web)) |
| a present's round trip through the file protocol is slow against a frame | low | a lower frame rate than the device's | the watch-list measurement; a present is one request a frame, and its answer already waits for the device |
| LVGL's direct mode draws a widget differently from its partial mode | low | a misdrawn widget on a kiosk | the parity test compares meaning and the QEMU screenshot compares pixels with a reference |
| LVGL's flush and wait behaviour changes in a later release | low | a kiosk that hangs at a refresh with several areas | the program uses only LVGL's documented calls, `lv_display_flush_is_last`, `lv_display_flush_ready` and the flush-wait callback; the several-areas test against the model screen runs with every LVGL update |

Decisions:

1. **Input formats.** `mouse` is served in Plan 9's 49-byte form and
   `kbd` in 9front's form of `c`, `k` and `K` records, from kbdfs(8),
   with 9front's runes for its special keys ([The window
   tree](#the-window-tree)), which serve plan9port's programs and give
   key up and down to widgets and games. An `input` file of `input()`
   records is added only when a program needs multi-touch.
2. **LVGL is a stopgap.** The Erlang renderer exists for the desktop
   regardless, and one renderer is the simpler system; LVGL retires on
   panels when the parity test passes and the Erlang renderer matches
   its frame times on a 240x240 panel, and stays until then. Both gates
   compare the two on the same panel: the parity test on meaning, the
   frame times on speed; neither asks for the same pixels.
3. **The web is a medium of its own.** Every renderer renders for its
   medium, and nothing requires pixel or layout parity between the
   browser and a native display; presentation state stays with each
   renderer. Mirroring a display in the browser is left out: the web is a
   second display an application names
   ([design-web.md](design-web.md)).
4. **Fonts.** plan9port's `fixed` fonts serve the terminal and the first
   widgets; anti-aliased fonts (the Go fonts, rasterised by a host step)
   are chosen with the first application that needs them.
5. **A terminal is a program of its session.** `erx_term` runs in the
   session domain, makes its window through the session's grant and is
   the master of a tty of the session's terminal relay; the display
   domain composites windows and routes input, parses no program's
   output, holds no console line and starts no program in a session.
   The system shell is reached only at the UART and the host link.
6. **The clipboard** is shared per display, as X does, by the grants
   whose facet rows turn `snarf` on; it is off by default, so no app
   reads a person's clipboard unless the board's manifest says so, and
   Security states who shares it.
7. **The input context.** The shell announces the argument types each
   command accepts with `-erx_args`, so the terminal highlights the
   presentations a command can take.
8. **The `Y` decoder is Erlang.** Compressed pixels are decoded by
   `erx_draw_image` into the rectangle's pixels and loaded as a `y`
   would be, and a PNG is inflated by `erx_inflate`, so no NIF, ERTS's
   included, parses a client's bytes, in the client's session or anywhere
   else, without exception.
9. **One width table for the whole system.** The terminal generator
   writes `erx_vt`'s widths, musl's `wcwidth` tables and `erx_width`,
   which `prim_tty:wcwidth/1` answers from, from one rule and OTP's
   Unicode data ([design.md](design.md#decisions)).
10. **The scrollback stays fixed** at 131,072 cells a terminal.
11. **erXos's OTP fixes `io_ansi`'s four wrong fallback strings**, since
    erXos owns its OTP (Risks).
12. **A kiosk's application is an app like any other.** A kiosk app runs like any other app on the system, with
    whatever app privileges it holds and access to the display, and
    renders to the display. It is an app of
    [design-apps.md](design-apps.md), in a session of its own
    principal, and the start table starts it at boot, the one place
    that says what starts without a person, with no starter of the
    display's own. The layers that restart everything else restart it:
    the application's supervisor in the session, and the start row's
    keeper for the session's domain, within the row's intensity. The
    widget toolkit, its renderers and the LVGL program run in the app's
    session, and the display domain runs none of them. A kiosk is the
    single policy and a start row.
13. **Applications are added after an image is built.** erXos is a distribution whose users and developers add
    their own apps, so nothing of the display depends on which app it
    shows, and nothing assumes the manifest is the only source of apps.
    The board's manifest names the display domain, its devices and its
    policy; the app of a display's session is an app, a principal of
    the manifest with a template today and one added by a package later
    ([design-apps.md](design-apps.md#packaging)), and the start row that
    names it. An app a person starts on a desktop runs in a session of
    its own principal, beside the person's windows.
14. **Login at a display is designed once, for every place a person
    meets the system.** Login is being rethought, and one design
    covers the display, the console's logins at the UART and the host
    link ([design-live.md](design-live.md#the-console)) and the web
    front end's ([design-web.md](design-web.md#logging-in-and-the-line)),
    keeping two properties the console has today: the system shell
    opens only at a line the manifest marks secure, and a display
    domain's view of what is typed is stated as an X server's is. It
    settles how a person proves who they are at a display, what shows
    the prompt and which domain sees the passphrase; what the reserved
    chord brings up and what of a locked session stays on the screen;
    which sessions and windows a log out ends; several principals on
    one display, in turn or side by side, and who shares the clipboard
    then; how an operator reaches a shell on a kiosk's own screen;
    whether a display's session opens the principal's vault keys; and
    whether a person's start row on a display stays as an option, as an
    automatic login does on UNIX. Until it exists a display shows the
    session its start row names. The enrolment gap is recorded in
    `TODO.md`: a principal a start row names, an app's or a person's,
    that never enrolled can be enrolled by whoever reaches a secure
    console line first, as any principal can, and then logged in to
    with the app's or the person's authority.
15. **PNG is the one image type.** Every renderer must show every image
    type, so the table is the intersection of what the browser, LVGL and
    the Erlang renderer decode. PNG is native to the browser and to
    LVGL, and costs the Erlang renderer a PNG reader, `erx_png`, with its
    fuzz target, over `erx_inflate`, an inflate written in Erlang for
    it, since ERTS's `zlib` is a NIF. JPEG is added only when an
    application shows photographs.
16. **Presentations name inspector paths only.** A file's path, a hash,
    a principal and a qid have no inspector path and print as text, so
    a command such as `cat` declares no `-erx_args` type for its files.
    A presentation of a file path, which would need the path as rc reads
    it beside the path-segment form, waits for a command or view that
    needs one.
17. **Draw messages are executed in the client's session**, so the
    display has one kind of window content, a buffer, and parses nothing
    a client drew. Nothing a Plan 9 program can observe differs from
    executing them in the display; the cost is that every session release
    that draws carries `erx_memdraw`, and a fault in it ends that
    session's runtime.
18. **One pixel area for each connection.** No domain passes a
    capability to another, so the system domain makes whatever both map:
    one pixel area with each connection, sized by the grant, one object
    added to an existing plan and no request at run time. What desktops
    leave unused is measured (the watch list) before anything more is
    built.
19. **The display pays for a pixel area**, as the reader of every other
    object of a connection pays, bounded by each grant's `pixels`, which
    the manifest check sums against the display domain's outer budget,
    at least until the per-user budgets of M10 make display memory
    something users compete for.
20. **A program gets its window's buffer as a `mem` descriptor** of its
    startup message, for memory its session mapped into it while
    building it ([design-programs.md](design-programs.md#the-startup-message)),
    as its data area is; a program holds only its own buffer's pages,
    and no pixel crosses its pipes.
21. **The order of track D.** The LVGL program is a program of the
    kiosk's session, so the QEMU kiosk needs a session that runs
    programs over pipes, which track P's first slice brings, and an app
    shipped in the image, which track A's second part brings. The
    window stack itself needs neither and is shown first, by a client
    that draws in Erlang
    ([plan.md](plan.md#track-d-windows-widgets-and-the-web)).
22. **The display takes its session from the start table.** One start
    row holds a display at a time: the table refuses a second enabled
    row that names a display another enabled row names, so `service APP
    enable display=D` answers with the row that holds `D` until that row
    is disabled, and refuses a display the app's template is not
    granted. Enabling a row starts its session at once, and disabling
    it stops the session; a change to `rc.conf` made by other means
    takes effect at the next boot, where a setting the merge refuses
    leaves its row `refused` at `/proc/apps`. A board's manifest closes
    a display to apps by granting it to no app's template, and decides
    which rows exist; the machine's `rc.conf` only sets them
    ([design-apps.md](design-apps.md#the-start-table)).

23. **Input is translated once, by the router.** Drivers send records in
    their devices' terms, keys by evdev code and as edges only, and
    `erx_input` alone keeps the pointer, applies the layout and makes
    repeat, because only the display knows the screen, the layout and
    the window a key went to: a driver in another domain could know
    none of them. evdev's codes are the key codes because virtio-input
    and FreeBSD's evdev already speak them and every bus driver can
    produce them. The layout is erXos's own table, keyed by evdev code
    and generated from a text file in the shape of 9front's keyboard
    map; FreeBSD's keymaps are not imported.
    Repeat's defaults are kbdcontrol(1)'s `normal` rate. Repeat is each
    window's own, set and stopped by the keys that went to it, where
    FreeBSD's evdev keeps one for its device, so no window learns from
    its repeats when another is typed in. The reserved
    chord is the router's, not each policy's, since the router holds the
    keys every device has down.

## References

* Plan 9 manual: draw(3), draw(2), image(6), font(6), mouse(3), rio(4),
  wctl.
* Input was checked against these files, read at the pinned commits
  with the SHA-256 of each: 9front at commit
  `eb49f1f8788ccbb2f86ce5767d2f046c3593162e`, `sys/man/8/kbdfs`
  (`239f0bbc2ee2a52eb79d4704d0ef0f33d587c30ffdba73bf99bdc0a4825012af`),
  the `kbd` file's records at lines 208-236 and the keyboard map's
  layers at lines 265-318; `sys/man/4/rio`
  (`ef5be2f7e0f9bd0c8eb4a0c377dc4a30d946484cd0ee2a8c609c32ae4e6cd538`);
  `sys/include/keyboard.h`
  (`efbf86fb35c47d8fd59abe51bb1746a8ed46250bccaed364ac8bae3cb8e1654f`);
  `sys/src/cmd/aux/kbdfs/kbdfs.c`
  (`4caa22dd9d599ef859584eac37bf7b107f9281c597fd4ddc581a21cd29dee255`),
  whose US map at lines 162-200 and 282-300 `abi/keymaps/us.txt`
  follows; and `lib/legal/NOTICE`
  (`8daa82fb04eb56344e06902609a580e8fe40cf900043945288fa58bf1ebb3e6c`),
  which puts them under the MIT license. plan9port at commit
  `1f1396913fb5372408f442ed26933f5ae4b399cd`, `include/keyboard.h`
  (`547c06986e3c7fc77d1ed8b253ab86d6fab423771938a6abe3c26f6adf9a0c08`)
  and `man/man3/mouse.3`
  (`5e1f4c8913ca17a71490e1da2a210c994e09dad13ce0da5e9071338b332216db`).
  FreeBSD at release/15.1.0: `sys/dev/evdev/evdev.c`
  (`a261a373deb6eb224d9437a9fd1c34d4bcf78ebb98541f3b4567d34c6b8f3b5a`),
  `sys/dev/evdev/input.h`
  (`cd30f12e285f849dbff83f097118b5f3ab9cd3cc2f26d303ede0a4cfcf623a9b`),
  `sys/dev/virtio/virtio_ids.h`
  (`1287e190b1f2be17eab9370f642574fd61389a9a5fafe39f53f2d7cae07bc37e`)
  and `sys/dev/virtio/gpu/virtio_gpu.h`
  (`fe2a91547ba04bae7ac6b804e14596245084f32b5997e976b0f7ae44d48160dd`),
  which `abi/formats/virtio.txt` cites,
  `usr.sbin/kbdcontrol/kbdcontrol.1`
  (`4ca1bc86d7cbb57b361a6d1183c7a1177ed216bd565852b0e602db38a682fe7b`)
  and `usr.sbin/kbdcontrol/kbdcontrol.c`
  (`0114fcacff4abc9e66efbfea63acfce9d722c829a625f7cccf83011cdc563270`).
  Also at release/15.1.0, under the BSD-2-Clause license, for
  `abi/formats/evdev.txt`: `sys/dev/evdev/input-event-codes.h`
  (`fc9c4946818cefcec359ad3a619d448c4cafffa4f8f9571894516fb980b26142`)
  and `sys/dev/evdev/evdev_private.h`
  (`90763a96ea404d39ad7ee8e5a34f38d246a9c1908354bb95c46121332a91d65f`),
  and for `erx_vt`'s NUL, `sys/dev/kbd/kbdtables.h`
  (`0f817d7706aac3d5d07577d32aaf90572c08b782ec4a00cdae547f48c0723991`)
  and `share/vt/keymaps/us.kbd`
  (`d8042fbc1b74a059aeae0ac7689c91d5e962993250fa1c46ceb1e8d2f6acd524`).
* The draw messages were checked against 9front's `sys/man/3/draw`,
  `sys/src/9/port/devdraw.c`, `sys/src/libmemdraw/load.c` and
  `cload.c` and `sys/src/libdraw/badrect.c` at commit `2859ae04`, and
  against plan9port's `src/cmd/devdraw/devdraw.c`, `src/libdraw/poly.c`
  and `src/libdraw/bytesperline.c` at the pinned commit `1f13969`.
  9front's `libmemdraw` tests are in `sys/src/libmemdraw/test`.
* R. Pike, "Plan 9 from Bell Labs" and "Rio: Design of a Concurrent
  Window System", Bell Labs.
* plan9port, `src/libdraw` and `src/cmd/devdraw`, for the connection
  code this design replaces (not read for this document; see the
  compatibility section).
* Inferno manual: tk(2), wm(2), wmlib(2); S. Dorward, R. Pike, D. Presotto,
  D. Ritchie, H. Trickey, P. Winterbottom, "The Inferno Operating
  System", Bell Labs Technical Journal 2(1), 1997.
* S. McKay, "CLIM: The Common Lisp Interface Manager", Communications of
  the ACM 34(9), 1991; J. Walker, D. Moon, D. Weinreb, M. McMahon, "The
  Symbolics Genera Programming Environment", IEEE Software 4(6), 1987.
* T. Porter, T. Duff, "Compositing Digital Images", SIGGRAPH 1984.
* Virtual I/O Device (VIRTIO) Specification 1.2, sections 5.7 (GPU
  Device) and 5.8 (Input Device).
* LVGL documentation, version 9: display and input device drivers,
  input groups, flex layout.
* E. Moy, S. Gildea, T. Dickey, "XTerm Control Sequences", OSC 8
  hyperlinks, https://invisible-island.net/xterm/ctlseqs/ctlseqs.html.
* P. Williams, "A parser for DEC's ANSI-compatible video terminals",
  https://vt100.net/emu/dec_ansi_parser; DEC, "VT100 User Guide"
  (EK-VT100-UG) and "VT220 Programmer Reference Manual" (EK-VT220-RM),
  https://vt100.net/docs/; DEC STD 070, "Video Systems Reference Manual".
* ECMA-48, "Control Functions for Coded Character Sets", 5th edition,
  1991.
* E. Koblinger, "Hyperlinks (a.k.a. HTML-like anchors) in terminal
  emulators", the OSC 8 convention xterm's document cites.
* Unicode Standard Annex #11, "East Asian Width", and the Unicode
  Standard, chapter 3, "U+FFFD Substitution of Maximal Subparts".
* FreeBSD 15.1 manual: termcap(5), vt(4), ttys(5).
* libvterm, https://www.leonerd.org.uk/code/libvterm/; T. Dickey,
  `vttest`, https://invisible-island.net/vttest/.
* QNX Software Development Platform, "Screen Graphics Subsystem
  Developer's Guide": windows and their buffers, `screen_post_window`
  and its dirty rectangles, pipelines.
* The Wayland protocol, `wl_surface`, `wl_buffer` and `wl_shm`, and the
  `linux-dmabuf` extension, https://wayland.freedesktop.org/.
* Fuchsia documentation, https://fuchsia.dev/: Flatland, sysmem, the
  display coordinator and Magma.
* Linux, `drivers/gpu/drm/vc4` (the HVS and its planes) and
  `drivers/gpu/drm/v3d`; Mesa's `v3d` and `v3dv` drivers.
* TES Electronic Solutions, the D/AVE 2D driver's documentation;
  Renesas's Flexible Software Package, `r_drw`; LVGL's documentation of
  its draw unit for it.
* The five entries above, and the 3D parts of the VIRTIO specification,
  were not read again for this document: the table in
  [Context](#context) and [Graphics hardware](#graphics-hardware) state
  what those sources say as the writer knew them, and a design that
  builds on one of them checks it against the source first.
