# The display: draw, windows, widgets and presentations

A display is a domain that holds a display device and the input devices
that go with it, and serves **windows** to the rest of the system as
files. A window is a rectangle of pixels with an input stream, and the
same window serves two kinds of client: a program that draws, with
Plan 9's draw protocol, and an Erlang application that describes a user
interface as a term and receives events as messages. A user's terminal
is such a program of the user's own session, as xterm is a client of X:
it shows its tty and keeps the typed output of the shell and the
inspector bound to the values it came from, as Genera's dynamic windows
do. The display domain composites windows and routes input, as rio or an
X server does; it parses no program's output and holds no console line.
One display serves a desktop with overlapping windows under
QEMU `virt`, and one serves a kiosk, a dashboard or a pair of smart
glasses with a single full-screen window, a touch panel, an encoder or a
keypad, and a small panel on a serial bus: the same domain, the same
protocol and the same widget interface, under a different window policy.
The architecture is [design.md](design.md); drivers and the device shim
are [design-system.md](design-system.md#drivers) and
[design-runtime.md](design-runtime.md#the-device-nif); namespaces, grants
and the `erx_fs` behaviour are [design-files.md](design-files.md); the
tty, attributed text, the inspector and the console are
[design-live.md](design-live.md); the command shell and its records are
[design-shell.md](design-shell.md); facets are
[design-domains.md](design-domains.md#facets).

Decisions every reader of this document needs:

* **A display is a domain, and a window is a directory of files.** The
  display domain holds its display and input devices, by the manifest,
  and serves an `erx_fs` tree in which each window is a directory holding
  `draw`, `ctl`, `mouse`, `kbd`, `wctl` and `label`. A session reaches the
  tree through a grant rooted at the session's own directory, and its
  handler binds one window's directory into a program's namespace, so a
  program finds its window at `/dev/draw` and `/dev/mouse` exactly as a
  Plan 9 program does, and reaches no other window by construction.
* **One client path.** Every client of a window, the display domain's
  own menu and widget renderers included, makes it
  with `mkdir`, draws by writing `draw` and reads `mouse` and `kbd`
  through a file grant. The display domain holds a grant to its own tree
  as a domain holds its own `/tmp`, so no window is made or driven any
  other way.
* **The draw protocol is Plan 9's, one connection per window.** A
  window's `draw` file takes the messages of Plan 9's draw(3) and its
  `ctl` file answers with the display information of draw(3), with one
  difference: the connection's screen is the window. There are no named
  images, no screens and no layers in the protocol, so the mechanism by
  which one Plan 9 client reaches another's image does not exist.
* **Pixels stay in the display domain, and each image has one process
  at a time.** A client sends commands and pixel loads; the display
  domain executes them in C per-byte primitives into memory that it alone
  holds. A window's images are written only by the window's process, the
  screen image only by the screen owner `erx_screen`, and a reader reaches
  an image only inside a call its writer makes and waits on. No pixel
  memory is shared across a domain boundary or between two processes at
  once.
* **One window system, two policies.** The window system owns the screen
  and decides each window's rectangle and visibility. The **overlapping**
  policy is rio's: windows made and moved by the user, borders, a menu.
  The **single** policy shows exactly one window, full-screen, and keeps
  every other hidden, for a kiosk or a pair of glasses. A policy decides
  geometry and which window takes each input event, and nothing else;
  drawing, input formats and clients are the same under both.
* **A terminal is a program of its session.** A user's terminal,
  `erx_term`, is a supervised Erlang process in the user's session
  domain: it makes its window through the session's grant, draws with a
  glyph cache of its own, and is the master of a tty that the session's
  terminal relay serves, as xterm is a client of X and the master of a
  pseudo-terminal. The display serves it as it serves any client and
  has no authority to start a program in a session, so the display's
  menu has no item that opens a terminal; a terminal opens its sibling
  windows itself. The system shell is reached only at the UART and the
  host link.
* **A user interface is a term, and events are messages.** An application
  sends the display the whole widget tree of a window as an Erlang term
  whenever its state changes; the window's widget server keeps the
  realised tree, computes the difference, lays it out, draws it through
  the draw protocol, and sends the application `{ui, Window, Term,
  Detail}` messages. The application holds no widget handles and issues
  no widget commands. It reaches the display through its **display
  facet**, minted with its file grant when the system domain introduces
  its domain to the display, so widget work is admitted within that
  grant's share and limits.
* **Two renderers behind one interface.** The widget server's rendering
  is a behaviour, `erx_ui_renderer`. The Erlang renderer lays out and
  draws through the draw protocol. LVGL, a C widget library, renders
  behind the same behaviour as a native program in a sub-space of the
  display domain, for panels where its mature widgets and fonts pay; it
  is a stopgap, replaced by the Erlang renderer once that renderer
  matches it on the kiosk's widget set and frame times. Every renderer,
  the web's browser renderer included
  ([design-web.md](design-web.md#uis-the-browser-renderer)), renders the
  tree as fits its medium: the tree states what the widgets are, their
  values and their events, not their appearance, and renderers are
  compared on those, never on pixels or layout.
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
  every pixel it shows and every key typed at it, as an X server does. It
  holds no capability beyond its devices, its own grants and the grants
  it serves, and no unconfined DMA device in a release build, so it
  isolates nothing between other domains and is trusted only for the
  confidentiality of what is shown and typed at that display.
* **No NIF in the display domain parses untrusted bytes.** A memory
  error in a native parser would reach every window's pixels and keys,
  and a NIF's fault ends the whole runtime. The draw decoder and the
  decoder of compressed pixels are Erlang, and no program's terminal
  output reaches the display domain at all; native code that must parse
  runs in a sub-space holding only its window.
* **Nothing paints without a change.** Every byte that reaches a panel
  follows from a client's flush of a dirty rectangle or from a change of
  the windows' geometry. No timer redraws, so an idle display costs no
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

Plan 9 and Inferno show the shape. Plan 9's `/dev/draw` is a small
command protocol over a file, its pixel work is `libmemdraw`, and rio
gives each program its window as files bound into its namespace, so
graphics need no new kind of object. Inferno's Tk takes widget commands
from a program and returns events on a channel, and its window manager
is library code. Genera's dynamic windows keep displayed output bound to
the object it presents, so a command that wants an argument of a type
can take any presentation of that type on the screen. erXos keeps the
three ideas and removes what each system's weaker isolation allowed:
Plan 9's named images and shared screens, Tk's string commands, and
Genera's single address space, in which a presentation was the object.

What the hardware offers: QEMU `virt` has virtio-gpu in its 2D mode
(create a resource, attach guest memory as its backing, transfer a
rectangle to the host, set the scanout, flush a rectangle) and
virtio-input for a keyboard, a mouse and a tablet; a Raspberry Pi has
the framebuffer its firmware sets up, a range of memory the display
scans out; a small device has a panel on a serial bus that takes
rectangles of pixels. None of them draws: rendering is software
everywhere, and GPU acceleration is out of scope.

## Requirements

1. A program in a session draws into a window and reads its pointer and
   keyboard through files in its namespace, with Plan 9's draw(3)
   messages and Plan 9's input record formats, so plan9port's programs
   port with their draw library's connection code replaced and nothing
   else.
2. A program reaches only the window it was given, whatever it writes.
3. An Erlang application describes its interface as a term and receives
   events as messages, from any domain that holds a display grant, with
   no widget handles and no imperative widget commands.
4. The same application term renders through the Erlang renderer on a
   desktop, through LVGL on a panel and through the browser renderer on
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
7. A kiosk boots into one full-screen application named by the manifest,
   takes touch, encoder and keypad input, redraws only what changed, and
   turns its panel off when idle.
8. Text labelled with its source (a window's label, a value shown in a
   widget, a record in a terminal) is escaped by its displayer; a
   program's own output reaches a terminal window's tty unchanged.
9. What a client can make the display domain spend, in memory and in
   CPU, is bounded by its grant.
10. A client's crash, a window's end, a crash of any process of the
    display domain and a reset of the display device each lose at most
    what that party owned, and the rest redraws.
11. Every parser of input from another domain or from a device has a
    fuzz target; every "only X does Y" rule is a build check.
12. Drivers are Erlang processes over the device shim; the pixel work is
    per-byte C; nothing else of the display stack is native, apart from
    LVGL as a stopgap renderer.
13. An application chooses by name which of its displays a UI opens on,
    with a default its session sets; with no display it gets a stated
    error at once, and when a display goes away each UI on it reports its
    end to its opener.
14. The display domain composites windows and routes input, and does no
    more for a terminal: it parses no program's output, holds no console
    line and starts no program in a session.

## Overview

```text
 session domain                        display domain
+-----------------------------+     +-----------------------------------------+
| program --draw bytes--> fid |     | erx_winfs (erx_fs): /S/N/{draw,ctl,     |
|          <--mouse/kbd--     |---->|   mouse,kbd,wctl,label}, /S/snarf;      |
| erx_term --draw, mouse, kbd |---->|   the window table, erx_wm's policy,    |
|   erx_vt, its glyph cache;  |     |   input routing, the reserved chord     |
|   master of a tty of the    |     | erx_window: one process per window,     |
|   terminal relay <-> shell  |     |   images in erx_memdraw (C)             |
| Erlang app --ui ops-->      |     | erx_screen: the screen image, compose,  |
|   display facet             |---->|   power, the only path to the driver    |
|            <--{ui,...}--    |     | erx_ui_server: one per widget window;   |
+-----------------------------+     |   renderers: Erlang, LVGL (sub-space)   |
                                    | erx_wm_menu: the overlapping menu       |
                                    | drivers: display, pointer, keyboard,    |
                                    |   touch, encoder, keypad                |
                                    +-----------------------------------------+
```

A **display domain** is a configured domain of the manifest holding one
display device and its input devices. Its release runs the display
driver, the input drivers, the window file server `erx_winfs`, one window
process `erx_window` per window, the screen owner `erx_screen`, the
widget service behind the display facets, widget servers, the
overlapping policy's menu and, where the manifest asks for it, the LVGL
renderer as a native program. It runs no terminal and no program of a
session.

A **window** is a directory a client makes with `mkdir` in a directory
of a grant it holds. It is one process, `erx_window`, which holds the
draw connection, whose image 0 is the window's pixels, and the window's
pending input. Its files are the connection's `draw` and `ctl`, the
input files `mouse` and `kbd`, the geometry file `wctl` and the title
`label`. The display domain's own window, the overlapping policy's menu,
is made the same way in its own directory of the tree.

**Drawing** is Plan 9's: a client allocates images, draws between them
with Porter-Duff compositing, loads and reads pixels, draws lines,
polygons, ellipses and strings of glyphs from a font cache image it
filled itself, and flushes. The window process executes each message
with `erx_memdraw`, a NIF around the per-byte primitives of Plan 9's
`libmemdraw`, into images it owns. On a flush the window calls
`erx_screen` with its dirty rectangles and waits; `erx_screen` composes
them from image 0 into the screen image, clipped to the part of the
window the policy leaves visible, answers, and hands the driver the
rectangles to push to the device.

**Widgets** are a retained tree in a widget server, one per window that
an application opens through its display facet. The application sends
trees; the server diffs and hands the operations to a renderer
behaviour, which lays out, draws and reads input, and the server sends
events. The Erlang renderer draws through the draw protocol on the
window's files; the LVGL renderer is a native program that receives the
same difference operations on its standard input and draws into the same
window through its own `/dev/draw`.

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

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **G1.** A client reaches only its own windows' pixels and input | a draw connection names images by ids it allocated and by image 0, its window; the protocol has no message that names or attaches to another connection's image and no screens; a window's image 0 is never the screen image and never holds another window's pixels, so an `r` reads only what the window drew; a window's files are a grant rooted at the session's directory of `erx_winfs`, and a program's handler walks only the one window's directory for it ([Narrowing](design-files.md#narrowing-for-a-program)); the policy delivers each input event to one window, and under the single policy only to the one shown window | a name or attach message; an image shared between windows or with the screen; a grant rooted above the session's directory; a handler that binds the session's whole tree for a program; an event delivered to a hidden window | a connection that sends every message type with every id from another connection, each refused with `ENOENT`; two sessions whose grants list only their own windows; a program given one window that walks `..` and sibling names and reaches nothing; under the single policy with a second window made, the second window's `kbd` receives nothing and the application's `r` of image 0 returns its own pixels, where a seeded delivery to the hidden window fails it; the decoder's fuzz target |
| **G2.** Each image is touched by one process at a time and lives while any process holds it, and every pixel loop runs over a clipped rectangle | a window's images are written only by its window process and the screen image only by `erx_screen`; `erx_screen` reads a window's image 0 only inside that window's flush call, which the window makes and waits on, and the driver reads an image only inside `erx_screen`'s call to it, which `erx_screen` waits on; calls run one way, window to `erx_screen` to driver, so no two wait on each other; an image is a NIF resource, freed by its destructor when no term refers to it, and `erx_memdraw` has no other free, so `f`, a resize and a window's end drop a reference and never free memory another process holds; the framebuffer is written only by the display driver's `erx_device:fill/3`; every function of `erx_memdraw` that touches pixel memory takes an `erx_clip_t`, which only `erx_draw_clip` produces, with checked arithmetic, from the operation's rectangles and both images' bounds | a read of an image outside its writer's call; a call from the driver or `erx_screen` back up the chain; an explicit free of an image; a loop over an unclipped rectangle | the build checks over `erx_memdraw`'s sources and the call direction (Chokepoints); the differential test against the reference renderer with rectangles far outside every image; the display suite in hosted mode under ThreadSanitizer, with windows drawing, resizing and ending while `erx_screen` composes and the driver copies, where a seeded compose outside the flush call makes it report; the same run under ASan, where a seeded explicit free makes it report |
| **G3.** What a client makes the display domain spend is bounded by its grant | memory: a grant carries quotas of windows, pixel bytes and widget nodes; each image is charged its pixel bytes rounded up to 4 KiB, and a font cache its glyph records, so the pixel quota bounds the image count too; a window checks each allocation against the quota with checked arithmetic before it allocates; images die with their window; a write carries at most the file protocol's 64 KiB, a widget tree at most the display facet's `max_request`; a window's pending input and dirty list are bounded. CPU: a client's draw work runs only in its windows' processes, at most the `windows` quota of them, each of which has at most one flush in `erx_screen` at a time; its widget work is admitted by its display facet within the grant's share of reductions | an allocation outside the quota check; an image that outlives its window; an unbounded queue; a window with two flushes outstanding | an allocation loop refused at the quota with `ENOMEM` and the domain's memory unchanged; a window closed with images left, all freed; a widget tree of one node more than the quota, refused whole; a client that floods flushes from one window while another window's one flush waits at most one compose, where a seeded second outstanding flush fails it |
| **G4.** A presentation grants nothing | a presentation is a type and a canonical text; the terminal emulator's only actions on one are to insert its text as keyboard input and to highlight the presentations of the types an input context names; a widget's only action is the `{select, Type, Value}` event to its application; neither carries a facet, a grant or a capability, and the command that then runs is checked by the shell's facets as any typed command is ([Authority](design.md#authority)) | a terminal that calls a service for a clicked link; a widget server that performs the action a presentation names | a session without an inspect facet clicks a pid presentation and the inserted `i` command fails with `no_facet`; the link parser's fuzz target; a source check that `erx_term` and `erx_ui_server` call no facet |
| **G5.** Attributed text in a window is displayed only through the line escape, and a program's output reaches its terminal window unchanged | a window's label, a widget's `present` text and a widget's text drawn from a record value are escaped by the displayer with `erx_text:escape_line/1` ([Attributed text](design-live.md#attributed-text)); the terminal emulator takes its bytes from a tty, which changes nothing but what `termios` says (V1), and interprets them as a terminal does | a label drawn raw; a terminal emulator that filters a program's bytes | the attributed-text test corpus of design-live sent as a label, as a `present` text and as a record value in a widget; V1's byte test with a terminal window in place of the serial line |
| **G6.** Nothing paints without a change | the only path to the device is `erx_screen`, which composes on a window's flush call and asks windows to flush only when the layout changes, the driver restarts, the panel wakes or `erx_screen` itself restarts; the driver pushes only the rectangles it is given; no process of the display domain has a redraw timer | a periodic repaint; a flush of the whole screen for a small change | an idle display for one minute makes no device request, counted at the driver; a one-pixel change makes exactly one flush of one rectangle; moving a window flushes exactly the area whose content changed |
| **G8.** What a program writes to a terminal window costs bounded memory, and nothing of it comes back as input | `erx_vt`'s state is bounded by its size and the constants of [Bounds](#bounds): parameters, intermediates and strings are capped, the scrollback is capped in cells and the link table in entries, and an endless sequence costs no memory; its only replies are DA's and DSR's fixed forms, whose variable parts are numbers it computes; it is Erlang, so a fault in it ends one terminal process, not its session's runtime | a buffer that grows with a sequence; a report that echoes text, such as a title report; a native parser of program output | the fuzz target asserts the state's size against the bound computed from the size and the constants, where a seeded scrollback without its cap fails it; the reply test sends every query form, a title report among them, and checks every reply against the three forms, where a seeded title report fails it; the chokepoint check that only `erx_vt` interprets a terminal's output |
| **G7.** A widget never fabricates | a `present` property and a value drawn from a record keep their `attr()` status; the renderer shows every status other than `ok` as its token, as `erx_render` does (V2) | a widget that drops a status | the status tests of design-live run through a widget tree, for each status and reporter |

## Data model

### Windows and connections

```erlang
-type window_id() :: 1..16#7fffffff.             % unique within a display
-type coord() :: -16#80000000..16#7fffffff.      % draw(3)'s 32-bit coordinate
-type rect() :: {X0 :: coord(), Y0 :: coord(),
                 X1 :: coord(), Y1 :: coord()}.  % half-open, as Plan 9's
-type color() :: 0..16#ffffffff.                 % draw(3)'s RGBA
-type chan() :: binary().        % Plan 9 channel descriptor: <<"r8g8b8a8">>, <<"k8">>, <<"m8">>, <<"r5g6b5">> ...
-type window() :: #{id := window_id(),
                    dir := {Session :: binary(), Name :: binary()}, % its directory in the tree
                    holder := pid(),           % the mkdir's Owner; the window ends with it
                    rect := rect(),            % on the screen; the policy's to set
                    state := shown | hidden,
                    label := binary(),         % attributed text, escaped when drawn
                    proc := pid()}.            % the window process
-type image_id() :: 0..16#ffffffff.             % 0 is the window
-type image() :: #{id := image_id(),
                   r := rect(), clipr := rect(), chan := chan(), repl := boolean(),
                   glyphs := none | {Ascent :: 0..255, tuple()}, % after 'i': the font cache's glyph records
                   mem := reference()}.        % the erx_memdraw resource
-type conn() :: #{window := window_id(),
                  images := #{image_id() => image()},
                  bytes := non_neg_integer(),  % pixel bytes charged, against the quota
                  op := 0..11,                 % for the next drawing message only; SoverD otherwise
                  dirty := [rect()],           % since the last flush, at most 16
                  mouse := queue:queue(binary()), % pending records, at most 4 KiB
                  resized := boolean(),        % the next mouse read answers 'r'
                  kbd := queue:queue(binary())}. % pending records, at most 4 KiB
```

A display's grant carries its quotas, from the manifest's facet
parameters with these defaults: 64 windows, 64 MiB of pixel bytes per
window, 16,384 pixels on a side, 10,000 nodes in a widget tree, and the
facet limits every grant has ([Facets](design-domains.md#facets)), with
the display facet's `max_request` at 1 MiB so that a tree within the node
quota fits. An image's byte size is computed with checked arithmetic
from its rectangle and channel depth, rounded up to 4 KiB, and refused
when it would pass the quota, so the default quota holds at most 16,384
images. An `i` charges the same quota for its glyph records, 16 bytes
each rounded up to 4 KiB, so a font cache's table is bounded with the
pixels. A `draw` write and a read of `r`'s pixels each carry at most the
file protocol's 64 KiB payload
([Bytes](design-files.md#how-a-request-names-its-bytes)), so the display
needs no write quota of its own. A widget tree's depth needs no bound of
its own either: it is at most its node count, and the funnel bounds a
term's nesting ([The funnel](design-domains.md#the-funnel)).

A window holds at most 16 dirty rectangles; a seventeenth replaces the
list by its bounding box, as Plan 9's `flushimage` does with one. Its
`mouse` and `kbd` hold at most 4 KiB of pending records each; past that
the oldest record is dropped and counted, as a tty drops typed input past
its bound ([design-live.md](design-live.md)). A resize is not a queued
record but the `resized` flag, which the next read of `mouse` answers
with an `r` record, as Plan 9's mouse device does, so no drop loses one.

### The window tree

`erx_winfs` serves one tree per display. A session's grant is rooted at
the session's directory, so the session sees:

```text
/N/draw     the draw connection: writes are draw(3) messages, reads return pixels after an 'r'
/N/ctl      read: the display information of draw(3) for the window
/N/mouse    read: 49-byte records 'm x y buttons msec' and 'r ...' after a resize
/N/kbd      read: records 'c' runes typed, 'k' keys down, 'K' keys down after a release
/N/wctl     read: the window's rectangle and state; write: a geometry command
/N/label    read and write: the window's title
/snarf      the display's clipboard, read and write; present only when the grant carries snarf
```

A window is made by `mkdir` of a name of the client's choosing in its
directory; the window takes the next `window_id()` within the display,
and the name is the client's, as any directory's is. The `mkdir`'s
`Owner` ([Fid owners](design-files.md#fid-owners)) is the window's
holder: a window ends when its holder ends, when its directory is
removed, or when its grant ends, whichever comes first, as a fid ends at
its owner's end. A session's handler makes a program's window with
itself as holder, so the window ends with the program. `mouse`, `kbd` and
`wctl` are the formats of Plan 9 and 9front, and a read of them is a
helper-mode read that waits for a record
([The `erx_fs` behaviour](design-files.md#serving-the-erx_fs-behaviour)).
Only these names exist; `cons`, `winname`, `consctl` and `wsys` do not,
since a terminal is a program's choice and attachment by name is gone.
For a program, the handler binds the window's files at `/dev/draw`,
`/dev/mouse` and the rest, beside the session's own `/dev` entries, and,
when the grant carries `snarf`, `/snarf` at `/dev/snarf`, so a Plan 9
program finds both where it expects them.

The display domain holds a grant of its own tree, rooted at the top, as
a domain's runtime mounts its own `/tmp`
([design-tmp.md](design-tmp.md#starting-and-mounting)). Its own window,
the menu, lives in its own directory beside the
sessions', under that grant's quotas from the display's manifest entry;
its widget servers make and draw an application's windows in the
application's directory, so they are charged to the application's grant.

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
the quota `ENOMEM`; and `EINVAL` for an unknown channel, a negative
semi-axis or thickness, a glyph index outside the font cache, an `s`,
`x` or `l` naming an image that is not one, an `r`, `y` or `Y` rectangle
not inside its image, and an image rectangle that 9front's `badrect`
refuses or wider or taller than the quota's side.

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
depth is that of the image's channel. `y` carries them raw, so its
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
`ENOENT`.

`erx_draw_core:plan(Conn, Bytes)` is a left fold over the write: decode
one message with the depth function of the connection as planned so far,
step the core with it, and continue from the next byte, until the write
is consumed or a message fails. Because the depth function reads the
planned connection, an image a `b` allocated earlier in the same write
has its depth and one an `f` freed has none, and there is no second table
of depths to keep in step with the images. The fold returns the planned
connection and the list of `erx_memdraw` operations, or the errno and the
offset of the message that failed. The window process performs the
operations only after the fold returns, so a write is decoded and checked
whole before any of it is applied, and a write that fails applies
nothing (plan, then apply).

### Input events

Inside the display domain an input event is one record, whatever device
made it, and it travels only from the drivers to the window system:

```erlang
-type input() :: #{device := binary(),        % the device's name in the device table
                   at := integer(),           % milliseconds, the runtime's monotonic clock
                   event := {pointer, X :: coord(), Y :: coord(), Buttons :: 0..255}
                          | {touch, Slot :: 0..9, down | move | up, X :: coord(), Y :: coord()}
                          | {key, down | up, Code :: 0..16#ffff,
                             Rune :: 0..16#d7ff | 16#e000..16#10ffff | none}
                          | {wheel, Steps :: -128..127}}.
```

The window system delivers each event to one window, which a window
reads as 49-byte `mouse` records and `kbd` records; that is the one input
form a window has, for every client. A touch is a pointer with button 1
down; a wheel step is buttons 8 and 16, as Plan 9 reports a scroll
wheel. An encoder's driver emits its steps as wheel steps and its press
as a key, and a keypad's driver emits keys, so no window policy maps
devices.

### Widget trees

```erlang
-type tree() :: {Kind :: atom(), Props :: #{atom() => term()}, Children :: [tree()]}.
%% Kinds, their properties and their events are declared in abi/formats/ui.txt:
%%   containers: column, row, grid, scroll, stack
%%   widgets:    label, button, checkbox, slider, input, list, image, spacer
%% Common properties: key, width, height, weight, pad, align, visible, enabled, present.
%% An image's encoded bytes are at most 48 KiB, so every operation fits one update on
%% every display (design-web.md); a larger picture goes in a draw window.
%% An on_* property holds a term the application chooses; the server sends it back
%% as {ui, Window, Term, Detail} when the event fires.
-type ui_event() :: {ui, Window :: reference(), Term :: term(), Detail :: term()}.
-type diff_op() :: {insert, Parent :: key(), Index :: non_neg_integer(), Kind :: atom(), Props :: map()}
                 | {remove, key()}
                 | {set, key(), Props :: map()}
                 | {move, key(), Parent :: key(), Index :: non_neg_integer()}
                 | commit.
-type key() :: 1..16#ffffffff.   % the server's number for a node; the application's key is a term
```

A node's identity across trees is its `key` property when present and
its position among its siblings otherwise, React's rule. A tree states
meaning, not appearance: what each node is, its values and the events it
takes; layout properties are hints each renderer reads for its medium.
Values the application does not set live in the server under the node's
identity: an `input`'s text, a `checkbox`'s state, a `slider`'s value, a
`list`'s selection. A property the tree sets is authoritative; one it
omits keeps the server's value. That one rule is the whole protocol for
controlled and uncontrolled widgets. Presentation state, a `scroll`'s
offset, an `input`'s cursor and the focus, is each renderer's own, kept
for its medium and never part of the tree or the server's state. An
`input` with `secret => true` shows its text as marks; its text is never
kept, by the server or by a renderer, and reaches the application only as
`{erx_secret, Text}` in the event's detail, which every printer shows as
`[secret]` ([Attributed text](design-live.md#attributed-text)). Content
an application draws itself, acme-like, is a window of its own beside the
widget window.

### Presentations

A presentation type is a type of the inspection schema
(`abi/inspection.txt`): `pid`, `domain`, `program`, `path`, `module`,
`hash`, `principal`, `device`, `budget`, `group`, `qid` and the scalar
types. The schema declares for each its canonical text, the grammar that
parses the text back, and the inspector path it names, and the generator
emits `erx_present:text/2`, `erx_present:parse/2` and the table of
inspector paths. A command declares the types of its arguments with
`-erx_args([pid, ...])` beside `-erx_needs`, from the same vocabulary,
and the catalog carries them
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

A display driver is an Erlang process over the device NIF implementing
`erx_display`:

```erlang
-callback info(State) -> #{width := pos_integer(), height := pos_integer(),
                           chan := chan(), stride := pos_integer(),
                           partial := boolean()}.      % whether flush takes rectangles
-callback flush(Rects :: [rect()], Image :: reference(), State) -> {ok, State}.
-callback power(on | dim | off, State) -> {ok, State}.
```

`flush` takes the rectangles to push and the `erx_memdraw` image to read
them from, copies each into the framebuffer with `erx_device:fill/3`, the
one per-byte copy of a transmit path, and tells the device: a virtio-gpu
driver posts a transfer and a flush for each rectangle on its control
queue and parses the device's responses in Erlang with binary matching;
a firmware framebuffer driver has nothing to post, since the device
scans the memory out; a panel driver on a serial bus sends a window-set
command and the rectangle's bytes, converted to the panel's channel by
`erx_memdraw` in the copy. The driver reads the image only while the
callback runs. Every offset into the framebuffer, from the stride, the
row and the column, is computed with checked arithmetic against the
pool buffer's length, and every rectangle is clipped to both the image
and the framebuffer before the copy. The framebuffer is a pool buffer of
the device's record in the NIF, so it survives the driver's crash; the
driver's restart resets the device and creates the scanout again, and
`erx_screen`, which monitors the driver, repaints the screen.

Input drivers are Erlang processes over the device NIF too: the
virtio-input driver parses the device's event records in Erlang and
emits `input()`; a touch controller's, an encoder's and a keypad's
drivers do the same from their buses. Each is a row of the device table
and sends its events to `erx_winfs`. A device in another domain, such as
a touch controller on a bus the devices domain holds, sends them through
a display facet granted to that domain with the `events` operation,
whose generated validator holds each event to the bounds of `input()`.

### Windows and the window system

`erx_winfs` is the one `erx_fs` server of a display and the window
system's state: it keeps the window table, asks the policy every
question of geometry and input, and routes input. Each session's grant
is rooted at the session's directory, made when the system domain
introduces the session's domain to the display, with the grant's quotas
as facet parameters; the same introduction mints the domain's display
facet. `mkdir` makes a window: the server asks the policy for a
rectangle and a state, starts the window process, linked to the server,
and records the window with the `mkdir`'s `Owner` as holder, monitored.
`erx_winfs` knows every window's owner, so no field of shared memory
decides who may do what.

`erx_wm` is a pure policy module behind one behaviour, called only by
`erx_winfs`:

```erlang
-callback place(Request :: new | {move, rect()} | {resize, rect()} | hide | show | top | bottom,
                Window :: window_id(), Windows :: [window()], Screen :: rect()) ->
          {ok, [window()]} | {error, einval}.
-callback decorate(window(), Screen :: rect()) -> [{rect(), color()}].  % borders, or []
-callback input(input(), Windows :: [window()]) -> {to, window_id(), input()} | {wm, term()} | drop.
```

The **overlapping** policy, `erx_wm_rio`, keeps windows in a stacking
order, places a new window where the user drags a rectangle or at a
default, frames each shown window with a border whose colour marks the
window that takes the keyboard, sends pointer events to the window under
the pointer and key events to the current window, and reserves the right
button outside any window for its menu: resize, move, delete, hide, and
the hidden windows by label. The menu is a
window of the display domain's own, drawn by `erx_wm_menu` as any client
draws, with each label through the line escape. It has no item that
starts a program, a terminal included: the display domain has no
authority to start one in a session, and a terminal opens its sibling
windows itself ([The terminal](#the-terminal)). The **single** policy,
`erx_wm_single`, shows exactly one window, the one the manifest names,
gives it the screen's rectangle, keeps every other hidden, delivers
every event but the reserved chord to the shown window, and draws
nothing. A
`wctl` write is a `place` request, so a program can resize or hide its
window under a policy that allows it and gets `EINVAL` under one that
does not.

**The reserved chord.** A display's manifest entry may name a key chord,
the **secure attention chord**. Every policy keeps it, answering
`input/2` for it with `{wm, chord}`, and delivers it to no window, so no
client can read it or wait for it, and no client comes to depend on
receiving it. It opens nothing: which trusted screen it brings up, a
login or a lock, is the login design's ([Risks and open
questions](#risks-and-open-questions)).

After every change of the table, `erx_winfs` hands `erx_screen` the
**layout**: the shown windows in stacking order, each with its window
process, its rectangle and its decorations from `decorate/2`. The layout
is derived from the table, so `erx_screen` keeps nothing it could not ask
for again. A window whose rectangle changed is told so by `erx_winfs`
and reports the new rectangle in `ctl`; when its size changed, it
allocates its new image 0, copies what fits, drops the old one, sets
`resized` and flushes its whole image. A flush or an expose that meets
the old image is harmless: every compose clips to both images' bounds.

Before it routes an input event, `erx_winfs` tells `erx_screen` of it,
which keeps the idle clock (Low power, below).

### The screen and its one path to the device

`erx_screen` owns the screen image, an `erx_memdraw` image of the
display's size and channel, which no other process writes, and the only
path to the driver. Its decisions are a pure core, `erx_screen_core`,
which from a layout computes each window's visible region, and from a
flush returns the plan: the rectangles to copy from the window's image,
the decorations and background to fill, and the rectangles to push; and
from an old and a new layout, the area of each window to expose. The
core is tested exhaustively on the host over small screens and layouts.

**A flush** is a call from a window process: `erx_screen:flush(Image,
Rects)`, where `Image` is the window's image 0 resource and `Rects` its
dirty rectangles. The window waits for the answer, so its image does not
change while `erx_screen` reads it. `erx_screen` copies the rectangles,
clipped to the window's visible region and to both images' bounds, into
the screen image and answers; a hidden window's flush copies nothing and
is answered at once. While the driver is busy with an earlier push,
flushes wait in `erx_screen`'s queue; when it is free, `erx_screen` takes
every flush waiting, composes each, and hands the driver one list of
rectangles, or the whole screen for a driver whose `info/1` reported
`partial` false, read once at start. A window has at most one flush
outstanding, so a window that floods flushes waits behind one compose of
every other window, not in front of them.

**Direct mode.** When the layout shows one window, covering the screen
with no decoration, the core plans no compose: `erx_screen` hands the
driver the window's image itself and answers the window's flush only
after the driver's callback has returned, so the window still writes
nothing that is being read. This is the kiosk's path, one copy per dirty
rectangle into the framebuffer. When the layout leaves direct mode, the
screen image holds none of the window's pixels, so `erx_screen` exposes
the whole of every shown window.

**Geometry.** When the layout changes, `erx_screen` fills the
decorations and background the plan names, and sends each shown window
an **expose** of the part of its visible region that the screen does not
already show from it, an asynchronous message; the window, between two
writes, answers it with a flush of that area. Composes clip to visible regions, so the order in which
windows answer does not matter. A compose shows a window's image as it
stands between two writes: a client that draws a frame over several
writes can be shown part-way through at an expose, as on Plan 9. The
same exposure of every shown window, whole, is the **repaint** that
follows a driver's restart, a wake and `erx_screen`'s own restart. There
is no other repaint (G6).

**Who reads what, when.** A window's images are written only by its
window process. `erx_screen` reads a window's image 0 only inside the
window's flush call, and the driver reads the screen image, or in direct
mode the window's image 0, only inside `erx_screen`'s call to it. Calls
go one way, window to `erx_screen` to driver, and `erx_screen` sends a
window nothing but asynchronous exposes, so no cycle of waits exists.
Both calls wait without a timeout, until the answer or the callee's end,
so a slow compose or copy never lets the writer resume while its image
is read. An image is a NIF resource whose memory its destructor frees when no term
refers to it, and `erx_memdraw` has no other way to free one: a `f`
message, a resize's old image 0 and a window's end drop the window's
reference, and any reference `erx_screen` or the driver still holds, in a
call that has not returned, keeps the memory alive until it does. A
window's crash during its flush call leaves `erx_screen` holding a valid
image to the end of the compose. So no process reads an image another is
writing, and none reads freed memory, by construction (G2).

**Low power.** `erx_screen` keeps the idle clock, the time since the last
input event `erx_winfs` told it of, and a display's manifest entry names
its idle policy: after a stated idle time `erx_screen` asks the driver
for `dim`, then `off`. While the panel is off, flushes are answered
without a compose and nothing is pushed; the next input event turns the
display `on` and repaints. The idle clock is a timer for power, not for
drawing.

### The window process

Each window is one process, `erx_window`, which serves its `draw`,
`ctl`, `mouse` and `kbd` files and holds its pending input. A write to
`draw` reaches it as a binary, which `erx_draw_core:plan/2` decodes and
checks whole, message by message against the connection as planned so
far ([Draw messages](#draw-messages)). Its step takes the planned
connection and one decoded message and returns the next state and the
`erx_memdraw` operation to perform, or an errno from the refusals that
section lists. A failure fails the write with that errno, and the display
domain's log records the window, the errno and the offset of the
message. The process performs the operations only after the fold has
consumed the whole write, so a failed write applies none of them. The
core is tested exhaustively on the host over small ids and rectangles.

Each operation goes to `erx_memdraw`, which computes the clipped
rectangle with `erx_draw_clip` from the destination's clip rectangle,
the source's and the mask's bounds and the operation's rectangle, and
runs `libmemdraw`'s primitive over it: `memimagedraw` for `d`, for `l`
with operation `S`, for each glyph of `s` and `x` with the glyph as
mask, and for `x`'s background; `memline`, `mempoly`, `memfillpoly`,
`memellipse` and `memarc` for the shapes; `loadmemimage` for `y`, and
`unloadmemimage` for `r`. A `Y` message never reaches `erx_memdraw` as
compressed bytes: the codec decoded it with `erx_draw_image` while
framing it, and the operation it plans is the `y` load of the decoded
pixels. So `erx_memdraw` parses nothing a client wrote: it takes decoded
messages, rectangles and pixel rows, and a load is given exactly the
bytes of its rectangle. Every size, offset,
stride and count `erx_memdraw` computes from a message, and the union of
dirty rectangles, uses checked arithmetic. The primitives read no global
state after their initialisation at load, which is checked when
`libmemdraw` is imported. An operation over more than 64 KiB of
destination pixels runs on a dirty scheduler, so a full-screen compose
never holds a normal scheduler. Fonts are the client's: `i` makes an
image it allocated a font cache and `l` copies a glyph's pixels into it
from another of its images, so the display
domain renders no client's text and parses no client's font.

A flush `v` calls `erx_screen:flush/2` with image 0 and the dirty
rectangles, and clears them when it returns. Image 0 is the window's
image, the size the policy gave it. Input from `erx_winfs` is encoded
into `mouse` and `kbd` records and queued, within the bounds of the data
model, until a read takes it. The window ends with its holder, its
directory or its grant; its images are resources of the process and the
runtime drops them when it ends, however it ends (G3).

**Reading pixels.** An `r` message queues the rectangle's bytes for the
next read of `draw`, at most 64 KiB at a time, as Plan 9 does.

**The clipboard.** `/snarf` holds at most 1 MiB and is one display's,
shared by every grant on that display that carries `snarf`, as X's
selection is shared by a display's clients (Security says with whom).

### The terminal

`erx_term` is a user's terminal. It is a program of the user's session,
as xterm is a client of an X server and the master of a pseudo-terminal,
written as a supervised Erlang process in the session domain's runtime.
The display serves it a window as it serves any client and knows nothing
else of it. A terminal owns four things:

* **Its window**, a directory it makes with `mkdir` through the
  session's grant on the display ([A display's
  session](#a-displays-session)), with itself as the holder. So the
  window counts against the session's `windows` and `pixel_bytes`
  quotas, ends when the terminal ends, and ends the terminal when the
  session's grant ends. The terminal draws by writing `draw` and reads
  `mouse` and `kbd` with `erx_draw`, as any Erlang client does ([Erlang
  clients](#erlang-clients)).
* **Its glyphs**, from a subfont file of the session's release, which
  `erx_font` loads into a font cache image of the window's connection,
  so the display renders none of a terminal's text, as it renders no
  client's.
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
* **Size.** The window's size, from `ctl` at the start and after each
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

A `type` must be a type of the inspection schema's table, which never
names a type `accept`; the decoded `text` must be valid UTF-8 holding no
C0 control, DEL or C1 control. Every OSC 8 string ends the open link
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

`erx_vt:key(State, Key)` returns the bytes a key sends, from the modes
in the state: printable keys as UTF-8, Return as CR, Backspace as DEL
(FreeBSD's default `VERASE`), Tab as HT, control and a letter as its C0
control, and Alt with a key as ESC before it; the arrows as `CSI A` to
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

#### The oracle

`erx_vt` is compared with **libvterm** 0.3.3, Paul Evans's terminal
emulator library in C under the MIT licence, the emulator inside Vim and
Neovim. It is a test oracle only, not a dependency: fetched at its pinned
release and SHA-256 and built out of tree for the host, with a harness of
erXos's own, `test/vt/vterm_dump.c`, that feeds it a corpus and writes
the screen after each checkpoint in the dump format `erx_vt:dump/1` also
writes: each row's cells with their code points, width, flags and
colours, the cursor and its visibility, and the replies since the last
checkpoint. libvterm is built with its `WCWIDTH_FUNCTION` hook set to a
C function generated from `erx_vt`'s width table, so the comparison
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

An application reaches its widgets through its **display facet**, an
`erx_facet` instance minted for its domain, beside its file grant, when
the system domain introduces the domain to the display, and declared
with its operations in `abi/services/display.txt`. The facet is a process
of the system domain in front of the display's widget service, as a facet
in front of another domain's service is
([Facets](design-domains.md#facets)), and the same declaration is served
by every display domain and by the web domain
([design-web.md](design-web.md)), so one facet type reaches either. Being
a facet, it acts only for the grantee, admits requests within the
grant's share of reductions and its `max_request`, and ends when revoked.
It keeps the UIs opened through it, at most the grant's `windows`, so it
can report each one's end. The client library `erx_ui` calls its
operations:

* `erx_ui:open(Options)` is `open_ui` on the display that `Options`'
  `display` names, or on the default display ([Choosing a
  display](#choosing-a-display)): the display starts a widget server,
  `erx_ui_server`, which makes the window in the grantee's directory as
  its holder, against the grantee's `windows` quota, with the `label`
  option as the window's title, and the reply is `{ok, Window}`, a
  reference naming it; the window appears in the grantee's tree like any
  other;
* `erx_ui:tree(Window, Tree)` is `ui_tree`, answered `ok` or `{error,
  Reason}`;
* `erx_ui:close(Window)` is `close_ui`, which ends the window.

The widget server sends `{ui, Window, Term, Detail}` to the process that
opened the window, and `{ui_down, Window, Reason}` when the window ends
other than by `close_ui`. On `ui_tree` the server:

1. **validates** the tree whole against the kinds, properties and bounds
   of `abi/formats/ui.txt` with the generated `erx_ui_schema`, answering
   `{error, Reason}` and changing nothing when any node fails (plan,
   then apply);
2. **diffs** it against the realised tree with `erx_ui_diff`, a pure
   function that pairs nodes by key or position and emits the fewest
   `diff_op()`s that turn one into the other, ending with `commit`;
3. **applies** the operations through the renderer behaviour;
4. **routes** events: the renderer reads the window's input, reports
   which node an event hits, and the server sends the owner `{ui, Window,
   Term, Detail}` for each `on_*` property that fires, and updates the
   state it keeps for the node.

Validation, the diff and the renderer's layout run inside the request,
so the generated serving path returns their reductions with the reply
and the grantee's share bounds them ([Facets](design-domains.md#facets));
the drawing they cause runs in the window's process, as any client's
draws do (G3). The atoms a tree can bring into the display domain,
inside `on_*` terms included, are bounded by its runtime's
`foreign_atoms` limit, past which the frame is dropped and counted
([Atoms](design-domains.md#atoms-code-ets-and-names)), and the tree's
size by `max_request`.

```erlang
-type target() :: {window, Dir :: binary()}     % the window's directory in the display domain's own grant
                | {web, Ui :: pos_integer()}.   % the UI's entry in the web domain's table (design-web.md)
-callback start(Target :: target(), Server :: pid(), Opts :: map()) -> {ok, State}.
%% The renderer reads its target's input in a process of its own, linked to Server:
%% a window's mouse and kbd, or a browser's events.  It sends Server
%% {ui_hit, key(), Event :: atom(), Detail :: term()} for each event a node takes.
-callback apply(Ops :: [diff_op()], State) -> {ok, State} | {error, term()}.
-callback stop(State) -> ok.
```

The **Erlang renderer**, `erx_ui_erlang`, keeps the realised tree with
each node's rectangle, lays it out with `erx_ui_layout`, a pure box
model (columns and rows with weights, padding, alignment, fixed sizes, a
grid, a scroll viewport, a stack) and draws the nodes whose rectangle or
properties changed through the draw protocol on the window's files, with
glyphs from a subfont it loaded, then flushes the union of their
rectangles. It reads `mouse` and `kbd`, and hit testing is the layout's
rectangles.

The **LVGL renderer**, `erx_ui_lvgl`, starts the native program
`erx-lvgl` in a sub-space of the display domain, with the window's files
bound in its `/dev` and nothing else of the tree, and writes
the same `diff_op()`s to its standard input in the binary form declared
in `abi/formats/ui.txt`, from which the generator produces the program's
bounded C reader. That form carries an `on_*` property as the flag that
the node takes the event, never the application's term, and a `present`
property as its type, its canonical text from `erx_present:text/2` and
its status, so the application's terms stay in the widget server and no
renderer outside Erlang parses one. The program maps each kind to an LVGL object, sets its
properties, renders into its own buffer, loads dirty rectangles into
image 0 with `y` messages on `/dev/draw` and flushes, reads
`/dev/mouse` and `/dev/kbd` for input, and writes events in the same
format to its standard output, which `erx_ui_lvgl` reads with the same
generated reader. Its fonts are LVGL's. The two renderers pass the same
parity test (Verification), which compares meaning, and an application
cannot tell them apart except by pixels.

**Presentations in widgets.** A node's `present` property is `{Type,
Value}` or an `attr()` carrying one; the renderer shows
`erx_present:text/2` of it through the line escape, with its status
token when the status is not `ok` (G7), and a click sends the owner
`{ui, Window, Term, {select, Type, Value}}`, with `Term` the node's
`on_select`. An inspector window is an ordinary application: it renders
a record as a tree of labels with `present` properties and, on a select,
queries the inspector through its own inspect facet (G4).

### A display's session

How a person logs in at a display, locks it and leaves it is not
designed: the login design is the owner's ([Risks and open
questions](#risks-and-open-questions)). Until it exists, a display
serves at most one session, named by the manifest and started without a
login:

* **The manifest names it.** A display's manifest entry may name a
  principal, `session`. At boot, once the display domain runs, the
  domain service starts that principal's session domain as a console
  login would start it, with its `display` variable set to the
  display's name, and the system domain introduces the session to the
  display: `erx_winfs` makes the session's directory and grant, with the
  entry's quotas, and the session receives its display facet
  ([Windows and the window system](#windows-and-the-window-system)).
* **It keeps a terminal there.** A session's `erx_term_sup` starts a
  terminal on a display when the session receives its grant there, and
  again whenever its last terminal on that display ends while it holds
  the grant. So the first window appears at boot, a last window closed
  from the menu comes back, and after the display domain restarts the
  new introduction opens a terminal on the new grant; between the
  display's end and that introduction the session holds no grant and
  starts nothing.
* **No other session reaches the display.** A session started by a login
  at the UART or the host link is introduced to no display, so
  `erx_ui:open/1` there answers `{error, no_display}`, and an entry that
  names no session, a kiosk's, serves only the configured domains the
  manifest introduces to it.
* **Whoever is at the display holds the principal's authority**, as at
  a UNIX console that logs a user in automatically: the session has
  every facet a login of that principal would have. Started without a
  passphrase, it opens none of the principal's keys at the vault
  ([design-system.md](design-system.md#the-vault)); work that needs them
  logs in at the UART or the host link.

### Choosing a display

A domain holds a display facet for each display it was introduced to, in
its capability registry
([Granting a running domain](design-system.md#granting-a-running-domain))
under the name of the domain that serves it: `display` for a display
domain of that name, another name for a second display domain, `web` for
the web domain. A session may hold none, one or several. The **default
display** is the domain's environment variable `display`, which whoever
starts the domain sets to the display it was started from: a display's
session gets that display ([A display's session](#a-displays-session)),
a web login sets `web`, a configured domain takes it from its manifest
entry, and a login at the serial console or over the host link sets
none. A user changes it as any
environment variable, for the domain or for one program it starts, as on
UNIX.

`erx_ui:open(Options)` looks up `Options`' `display`, or the default when
`Options` names none, in the registry, and opens there. A name that is
unset, or that names no display facet the domain holds, answers `{error,
no_display}` at once; nothing waits for a display to appear. The name
selects among facets the domain already holds and grants nothing. A UI
lives on the one display it opened on: the web is a second display, not a
mirror of the first, and an application that wants a UI on both opens
two.

When a display goes away, its facets report it: each opener of a UI on it
receives `{ui_down, Window, display_down}` from the facet, which then
ends, and the registry drops its name, so a later `erx_ui:open/1` naming
it answers `{error, no_display}` until the display's domain is back and
the system domain introduces the domain to it again. A browser that
closes is not a display going away: the web domain stays, and so do its
UIs ([design-web.md](design-web.md#uis-the-browser-renderer)).

### Kiosks and glasses

A kiosk, a dashboard or a pair of glasses is a display domain under the
single policy, configured in the manifest: the display device, the input
devices, `policy single`, the application domain whose window takes the
screen, the renderer (`erlang` or `lvgl`), the idle policy and,
optionally, the reserved chord. The application
is a configured domain with a display grant and facet, started in the
boot order after the display domain; it opens its widget window at start
and the policy shows it. Nothing else differs from the desktop:

* **Input.** A touch panel's events are pointer events with button 1;
  the renderer's hit testing turns them into `on_click`, drags into
  scrolling. An encoder's steps arrive as wheel steps and its press as a
  key, and a keypad's keys as keys; the renderer keeps a **focus ring**
  over the focusable nodes in tree order, moves it on wheel steps and
  arrow keys, activates on enter or the encoder's press, and shows focus
  by the node's `focus` style, so a tree written for touch works from an
  encoder with no change, which is how LVGL's input groups behave.
* **Drawing.** The one shown window covers the screen with no
  decoration, so `erx_screen` is in direct mode and a kiosk pays one copy
  per dirty rectangle, into the framebuffer, and no more. A panel of 240
  by 240 pixels in `r5g6b5` holds 112 KiB; the screen image and the
  window image together are within the display domain's smallest budget.
* **Power.** The idle policy turns the panel `dim` and `off`; input turns
  it on. Between events nothing runs (G6), so the display domain's cost
  is its processes waiting on messages, and the panel driver's bus is
  silent.
* **Panels.** A panel on a serial bus is a display driver whose `flush`
  sends each rectangle as the panel's window-set command followed by the
  rectangle's bytes in the panel's channel; partial updates are what
  such panels do best. A panel on a display serial interface with a
  framebuffer in the controller behaves the same way; one without
  partial update reports `partial` false and gets whole frames.
* **Service.** A kiosk's screen shows no terminal: its operator works at
  the UART or over the host link. Its entry names no session, so the
  application's window is the only one; the reserved chord, where the
  entry names one, reaches no window here either. A service terminal on
  the kiosk's own screen is part of the login design (Risks and open
  questions).

### Erlang clients

`erx_draw` is the client library for Erlang processes in any domain,
the display domain's own included: `open(Dir)` makes a window in a
directory of a grant the caller holds and returns a handle holding the
fids of its files and the display information from `ctl`; `alloc/4`,
`draw/6`, `line/6`, `string/5`, `load/3`, `flush/1` and the rest encode
messages with the generated encoder and write them to `draw`, batching
until a flush or 64 KiB; `mouse/1` and `kbd/1` read records; `resize/2`
and `label/2` write `wctl` and `label`. `erx_font` reads a Plan 9
subfont file and loads its glyphs into a font cache image with `i` and
`l`, so a client's text is a sequence of `s` messages; it is a parser of
file data and has a fuzz target.

## Interfaces

**The window tree**, as the data model lists it, served by `erx_winfs`
through the file protocol; the display grant's parameters `windows`,
`pixel_bytes`, `ui_nodes` and `snarf`, and the display facet's
operations, `open_ui`, `ui_tree` and `close_ui` for an application and
`events` for a domain that holds input devices of the display, each
grant naming the operations it allows, declared in
`abi/services/display.txt` and served by every display domain and by the
web domain. A display's manifest entry: its policy, under the single
policy its application domain and renderer, its idle policy, the
principal of its session, and the reserved chord.

**Draw messages**, in `abi/formats/draw.txt`, with the bounds above; the
`ctl` text, twelve 11-character fields followed by a space, as draw(3);
the `mouse` and `kbd` record formats of Plan 9 and 9front; `wctl`'s
commands `resize -r X0 Y0 X1 Y1`, `move -r X0 Y0 X1 Y1`, `hide`, `show`,
`top`, which also makes the window take the keyboard, and `bottom`, each
one line, at most 128 bytes.

**Widgets**: `erx_ui:open/1` with the `display` and `label` options,
`erx_ui:tree/2`, `erx_ui:close/1`, `{ui, Window, Term, Detail}`,
`{ui_down, Window, Reason}` and `{error, no_display}`; the `display`
environment variable; the kinds, properties, events and bounds of
`abi/formats/ui.txt`, `secret` on `input` among them, which also declares
the binary form of `diff_op()` and of events for renderers outside
Erlang; the `erx_ui_renderer` behaviour and its `target()`.

**Presentations**: the type table of `abi/inspection.txt`,
`erx_present:text/2` and `parse/2`, the `-erx_args` declaration, the link
and input-context sequences, the `links` capability of a terminal.

**The terminal**: `erx_term` and its supervisor `erx_term_sup` in a
session's release, its two key bindings, Ctrl-Shift-N and Shift with
Page Up and Page Down; `TERM=xterm` at `erx_term` and the host tool's
console; `abi/termcap`, installed as `/usr/share/misc/termcap`, and the
generated `erx_termcap`; `erx_vt`'s `new/2`, `feed/2`, `resize/3`,
`key/2`, `paste/2`, `link_at/3`, `dump/1` and its `effect()`; the
sequence tables and bounds of [The terminal
emulator](#the-terminal-emulator).

**Drivers**: the `erx_display` behaviour; the `input()` record.

**Interaction with other subsystems.** The device service gives the
display domain its devices and the system domain introduces sessions and
applications to it ([Devices](design-system.md#devices)); a session's
handler binds a window's directory into a program's namespace
([Narrowing](design-files.md#narrowing-for-a-program)); a session's
terminal relay serves the tty whose master `erx_term` is
([The tty](design-live.md#the-tty)), and the domain service starts a
display's session ([A display's session](#a-displays-session));
`erx_render` emits
presentations ([Inspection](design-live.md#inspection)); the inspector
schema supplies the types ([Inspection](design-live.md#inspection)).

## Compatibility and migration

plan9port's `libdraw` connects to a `devdraw` process over a pipe with
its own request messages, in which the draw messages themselves travel
unchanged as the payload of its draw requests and the mouse, keyboard,
label, snarf and resize traffic are requests of their own. erXos's port
of `libdraw` replaces that connection code with Plan 9's own file-based
one against the window's files, so acme, sam and 9term run without a
translating process. Plan 9's `getwindow` attaches to the window by name
and allocates a screen over it and a window on that screen to draw in;
the port's `getwindow` re-reads `ctl` and takes image 0 as the program's
screen image, and is part of the connection code replaced. 9term and
acme's `win` need a pseudo-terminal, which the second tier of programs
provides ([design-programs.md](design-programs.md#the-second-tier)).
Programs that allocate screens and layers of their own, rio among them,
are not clients: erXos has its own window system.

Nothing here changes a format of another subsystem. Records in
pipelines and `/proc` files are unchanged; the link sequence appears only
at a terminal that declares `links`.

## Failure handling, diagnostics and debuggability

| Failure | Effect | Recovery |
| --- | --- | --- |
| a malformed or over-quota write to `draw` | the write fails with `EINVAL`, `ENOENT`, `EEXIST` or `ENOMEM`, nothing applied; the display domain's log records the window, the reason and the position | the client's |
| a window's holder ends, or `rmdir` | the window ends; its process, images and pending input go | `erx_screen` exposes what it uncovered |
| a session's end | the grant ends and every window of it with it | as above |
| a window process crashes | as the window's end, logged with the message that caused it | the client sees `EIO` on its fids and makes a new window |
| `erx_screen` crashes | supervisor restart; it asks `erx_winfs` for the layout and repaints; a window waiting in a flush call sees the call fail and drops that flush, which the repaint covers | no client notices |
| the display driver crashes | restart; device reset; scanout re-created; `erx_screen` repaints; the framebuffer pool stays in the NIF's record | no client notices |
| `erx_winfs` crashes | it holds every grant and window of the display, so its crash ends the display domain, with the effect of the domain's end below | as for the domain's end |
| a terminal, `erx_term`, crashes | a process of the session, not of the display; its window ends with it, its holder, and its tty hangs up, so its shell and jobs get the hang-up, as when an xterm dies; the session's other terminals go on | a sibling from another terminal, or from `erx_term_sup` when it was the session's last on that display |
| a widget server crashes | its window ends with it, its holder; the facet sends the application `{ui_down, Window, server_down}` | the application opens a new window |
| the display domain ends | every window ends; sessions' fids fail with the connection down; each terminal on it ends with its window and hangs up its tty, as above; each opener of a UI on it receives `{ui_down, Window, display_down}` from its display facet, which ends | the domain service restarts the domain within its intensity and the system domain introduces its clients again; applications reopen, and the display's session opens a terminal on its new grant |
| a widget tree fails validation | `ui_tree` answers `{error, Reason}`; the realised tree is unchanged | the application's |
| the LVGL program exits | the widget server ends the window and the application receives `{ui_down, Window, renderer_down}` | the application reopens; the display domain logs the exit record |
| an input device stops | its driver restarts and resets it | events resume |
| a window's `mouse` or `kbd` queue is full | the oldest record is dropped and counted; a resize is never lost | the client reads |
| the panel is off and a client flushes | the flush is answered without a compose | the next input turns the panel on and repaints |

The inspector shows a display under `[domains, Id]` with its windows,
each with owner, rectangle, state, image count, pixel bytes, flush count
and dropped input records, all marked `service`;
`/proc/domains/Id/windows/N/status` shows the same. The display domain's
log carries each refused write with the window, the reason and the
position of the fault.

## Security

* **Isolation of windows** is G1: ids are per connection, the protocol
  has no cross-connection reference, no window's image is the screen
  image or another's, grants are rooted per session and the handler
  narrows per program. A program given a window learns only its own size
  and input.
* **The display domain's trust.** It sees every pixel it shows and every
  keystroke it routes, as an X server does, and holds nothing else:
  device capabilities, its own budget and
  grants, the grants it serves. Its display and input devices are
  confined or do no DMA: on QEMU `virt` virtio-gpu and virtio-input
  attach as virtio-pci behind the IOMMU, and a confined virtio-gpu
  function reaches only the framebuffer pool; a Raspberry Pi's firmware
  framebuffer is memory its display hardware scans out, and the display
  domain holds none of that hardware's registers; whether a board's
  panel or touch bus can be confined is that board's DMA contract
  ([design-platforms.md](design-platforms.md#dma)). The display domain
  parses every client's draw bytes, so a release manifest that gave it
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
  clipboard where `snarf` is on. It has nothing beyond: it cannot read a
  domain's memory, message a process it was not introduced to, start a
  program in a session, or reach a session that was not introduced to
  it. No program's terminal output reaches it, so nothing a program
  writes to a terminal can attack it, and it never carries the system
  shell, which opens only at a login at the UART or the host link
  ([The console](design-live.md#the-console)). This is the trust an X
  server or a Wayland compositor has, stated.
* **On the stopgap.** QEMU `virt` under the stopgap Fiasco, as the harness
  starts it, has no IOMMU, so virtio-gpu and virtio-input attach over
  virtio-mmio and are unconfined. The development manifest gives them to
  the display domain, the Phase 1 manifest check allows that in a
  development build, and the display domain is then in the trusted base,
  as the paragraph above says of any development build that holds such a
  device; a draw client that compromises it reaches all memory through the
  gpu's DMA. The release manifest's refusal is unchanged, and the drivers
  are the same code on both. Moving the devices to virtio-pci behind the
  IOMMU on erXos's kernel
  changes their device records and DMA profiles, not their drivers
  ([design-system.md](design-system.md#devices)).
* **Input** is routed by the policy to one window per event, and nothing
  lets a client write another window's input. The reserved chord reaches
  no window under any policy.
* **The clipboard** is shared, per display, by every grant on it that
  carries `snarf`, whatever its principal: the display's session, its
  terminals and every program it gives `/dev/snarf`, the configured
  domains introduced to the display, and the display domain's own
  clients. What one of them copies, any other can read. The `snarf`
  parameter withholds it from a grant, whose tree then has no `/snarf`;
  a display that must keep its grants' clipboards apart sets `snarf` off
  for every grant, the display domain's own included, and copy and
  paste then stay within a program or a terminal window.
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
* **Resource bounds** are G3. Memory is bounded by the grant's quotas.
  The display domain's CPU is not charged per grant for draw work, which
  runs on the display domain's own grant as a file server's work does
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)): a
  client's draws run only in its windows' processes, which the runtime
  schedules among all others, and each window has one flush at a time
  in `erx_screen`, so a client flooding draws slows the display by at
  most its windows' share and starves no other window. Widget work is
  admitted within the display facet's share.
* **Untrusted bytes in C.** Every byte a client writes is parsed in
  Erlang: the draw decoder `erx_draw_codec` and the decoder of
  compressed pixels `erx_draw_image`. `erx_memdraw`'s primitives act in
  C on what they have checked, rectangles, counts and pixel rows, and
  the native renderer's reader parses the renderer's operations in its
  sub-space; each has a fuzz target, and every size, offset and count
  they compute uses checked arithmetic (Verification).
* **Residuals.** Implicit bidirectional reordering of displayed text is
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
  every image unchanged. The codec's C twin has a generated fuzz target
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
    (which a `Y` plans to), `r`, and `l`, `s` and `x` as the masked draws they consist of. Its arithmetic
    is the per-pixel arithmetic of 9front's `libmemdraw` test
    `drawtest.c` (its `drawonepixel` and channel unpacking), widened from
    `SoverD` to all twelve operations. Random operations of those kinds
    over random images and channels through `erx_memdraw` and through the
    reference agree pixel for pixel; a seeded change to one Porter-Duff
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
    reference images are stored.
  * The same runs under ASan and UBSan, with rectangles far outside every
    image, are the test of G2's clipping; a seeded bypass of
    `erx_draw_clip` is caught by the chokepoint check and by ASan.
* **The `Y` decoder.** `erx_draw_image` has a fuzz target over
  compressed payloads into rectangles of every channel and size, under
  ASan and UBSan in `make check-fuzz`, which asserts that every decoded
  result holds exactly the rectangle's bytes and that the bytes consumed
  never pass the end of the write, where a seeded removal of the
  end-of-row bound fails it. Its oracle is `cloadmemimage` of the 9front
  build: over Plan 9's compressed images and the fuzz corpus, the two
  accept the same payloads, consume the same count and yield the same
  pixels, where a seeded off-by-one in a run's length fails the
  agreement. The codec's C twin frames a `Y` with the same
  `cloadmemimage`, so the differential test of the codec against its
  twin compares the framing of every `Y` against 9front's decoder too.
  Payloads that would decode past the rectangle or end short fail the
  write and apply nothing.
* **Who touches pixels.** `erx_screen_core` explored exhaustively over
  small screens and layouts: every pixel of the screen comes from exactly
  one shown window, decoration or the background, and a layout change
  exposes exactly the areas whose content changed, where a seeded
  off-by-one in the visible region fails it. G2's hosted runs under
  ThreadSanitizer and ASan, with windows drawing, resizing and ending
  during composes and driver copies. Bounds: a seventeenth dirty
  rectangle yields one bounding box; a `mouse` queue past 4 KiB drops
  its oldest record and counts it while a pending resize still answers
  `r`, where a seeded unbounded queue fails the heap check.
* **Windows.** G1's tests: cross-connection ids, two sessions' grants, a
  narrowed program, the single policy with a second window made;
  the `wctl` grammar's fuzz target; a window's end freeing its images,
  measured by the domain's budget before and after, and a window ending
  with its holder; a seeded leak of one image fails it.
* **The window system.** `erx_wm_rio` and `erx_wm_single` are pure and
  tested over sequences of place requests and input events; a property
  test that the single policy shows at most one window and delivers every
  event to it, and that every rectangle lies within the screen under
  both; a seeded unchecked move fails it. The reserved chord, typed while
  each window of either policy has the keyboard, reaches no window's
  `kbd`; a seeded policy that delivers it fails it.
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
* **The display's session.** A boot whose display entry names a
  principal starts that principal's session with `display` set, gives it
  a grant and a display facet, and shows its terminal's window, whose
  shell runs in the session's domain; closing that last window brings a
  new one; a restart of the display domain brings one on the new grant.
  A seeded domain service that skips the introduction fails the first,
  and a seeded `erx_term_sup` that starts nothing on a new grant fails
  the last. With the display and its session running, the console's
  lines are the UART and the host link alone and the display domain
  holds no facet of the console service, where a seeded manifest that
  grants it one fails it. A session that logs in at the UART answers
  `{error, no_display}` to `erx_ui:open/1`.
* **Widgets.** `erx_ui_schema`'s fuzz target over trees from another
  domain; a tree whose `on_*` terms carry more fresh atoms than
  `foreign_atoms` is dropped and counted; `erx_ui_diff` tested by the
  property that applying its operations to the old tree yields the new
  one, over random trees, and that an unchanged subtree emits no
  operation; the **parity test**, one corpus of trees and input
  sequences run through every renderer, the web's browser renderer
  included, comparing meaning alone: the events and values the
  application receives and the set of nodes present, never pixels or
  layout, where a seeded swap of two event names in the LVGL mapping
  fails it; the generated C reader's fuzz target; G7's status tests
  through a widget tree; `erx_ui:open/1` with no display facet answering
  `{error, no_display}` at once, a UI opened by name landing on that
  display, and a stopped display domain sending each opener `{ui_down,
  Window, display_down}`, where an `erx_ui` that ignores the `display`
  option fails; a `secret` input's text absent from the server's state
  and from every printed form.
* **Presentations.** The round trip `parse(Type, text(Type, Value)) ==
  Value` for every type and a generated corpus of values; the renderer
  emits links only with `links` declared, checked at the tty's byte
  boundary; the input context highlights exactly the types the catalog
  declares for a command; a seeded change to the URI encoding fails the
  round trip.
* **Drivers.** The virtio-gpu driver's response parser, the
  virtio-input event parser, and the touch controller's, the keypad's and
  the encoder's bus parsers have fuzz targets, as does the `events`
  operation's generated validator; the framebuffer copy runs under UBSan
  with strides, rows and columns at their bounds, where a seeded
  unchecked offset fails it; the harness runs the display suite under
  QEMU `virt` with a virtio-gpu and virtio-input attached as virtio-pci
  and compares screenshots taken through QEMU's monitor with reference
  images, under HVF; a seeded wrong channel conversion fails it.
  A panel driver is tested against a model of its command set on the
  host.
* **Power.** G6's idle test at the driver.
* **Failures.** One injected fault per row of the failure table above,
  each under QEMU `virt` with clients drawing: the fault is raised in the
  party the row names (a malformed write, a holder's end, a session's
  end, a crash of each process the table lists, the domain's end, an
  invalid tree, the LVGL program's exit, an input device stopping, a full
  queue, a flush with the panel off), and the test checks the row's
  effect and recovery and that nothing outside what that party owned is
  lost: other windows keep their images and input, and a session whose
  terminal crashed keeps its other terminals and its jobs, the crashed
  terminal's shell getting the hang-up. A seeded supervisor that
  restarts the whole display domain for a child's crash fails it.
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
| Only `erx_memdraw`'s listed functions touch pixel memory, and each takes an `erx_clip_t` from `erx_draw_clip` | a build check over the NIF's sources lists the functions that dereference image data and fails on a new one or on one without the parameter |
| Only an image resource's destructor frees pixel memory | the same build check, over the NIF's calls to the allocator's free |
| Only `erx_screen` writes the screen image and calls the display driver's `flush` callback | an xref check over the display release |
| Calls run window to `erx_screen` to driver: `erx_screen` makes no call to a window, and the driver none to `erx_screen` or a window | the same xref check, over calls and `gen_server:call` targets |
| Only the display driver's process calls `erx_device:fill/3` and `post/4` on the display device | the same xref check |
| Only `erx_winfs` calls `erx_wm`'s callbacks | the same xref check |
| Only the generated `erx_draw_codec` decodes draw bytes, and only the generated reader decodes the native renderer's operations and events | the generated tree's determinism test, and a source check that no other module reads those bytes |
| Only `erx_render` writes the link and input-context sequences | a source check for the `erx:` URI prefix |
| `erx_term` and `erx_ui_server` call no facet | an xref check that neither module nor its callees reach `erx_facet` clients |
| Attributed text in the display release passes through `erx_text:escape_line/1` | the source check of V9 extended to `erx_wm_menu` and `erx_ui_erlang` |
| No NIF of the display release parses bytes from another domain | a build check over the release's NIF libraries and their exported functions, a closed list with each function's use of the binaries it takes; a new NIF or function, `cloadmemimage` linked in among them, fails it |
| Only `erx_vt` interprets a terminal's output | a source check that no other module of `erx_term`'s application matches on ESC, CSI or OSC bytes |

## Performance

Numbers to measure, for [todo-performance.md](todo-performance.md):

* a full-screen `y` load from a session's program crosses the lane, the
  funnel and the file server before `erx_memdraw` copies it; measure MB/s
  on HVF at 1920 by 1080; the fix on the table is a pixel object made by
  the system domain and installed in both domains, as the session's
  shared mappings are;
* a terminal's draw batches cross the lane, the funnel and the file
  server from the session, as every program's do; measure its scrolling
  of a large `cat` at 80 by 24 and at full screen on HVF, which settles
  whether a terminal needs the pixel object above;
* the display domain's own clients, the menu and the Erlang renderer,
  pass every draw batch through `erx_winfs`'s grant; measure the
  renderer's frame time against the same batches handed to the window
  process directly;
* composes serialise through `erx_screen`, and a window waits in its
  flush call for its compose, or in direct mode for the driver's copy;
  measure frame times of several windows animating at once, and a
  kiosk's flush latency;
* the `fill` copy from the screen image into the framebuffer pool per
  dirty rectangle, against an `erx_memdraw` image over the pool buffer;
* the dirty-scheduler threshold for draw operations;
* the Erlang renderer's diff, layout and draw time per frame on a 240 by
  240 panel against LVGL's, which is the gate that retires LVGL;
* the terminal emulator's redraw per changed line of cells, and the
  pixel copy of scrolled rows against redrawing them;
* `erx_vt`'s throughput in bytes per second, a code point at a time in
  Erlang, over a large `cat` of text, of text with SGR on every word and
  of wide characters, against libvterm's on the same corpus;
* virtio-gpu's transfer and flush latency per rectangle under TCG, and
  how `erx_screen` gathers waiting flushes into one push.

## Portability

Nothing here names an architecture. The display and input devices are
rows of the device table per platform: virtio-gpu and virtio-input on
QEMU `virt`; the firmware framebuffer and a touch controller, keypad or
encoder on the boards' buses; panels on serial buses on small devices.
A new device is a new driver behind `erx_display` or a new producer of
`input()`.

## Dependencies

| Component | Purpose | Licence | Status |
| --- | --- | --- | --- |
| Plan 9's `libmemdraw`, from 9front | the per-byte pixel primitives of `erx_memdraw`; its image(6) loader `cloadmemimage` is linked into no release, since the `Y` decoder is the Erlang `erx_draw_image` | MIT (9front's `lib/legal/NOTICE`, whose exceptions cover only fonts) | permanent; imported as erXos's code with an origin file |
| the 9front build: 9front's `libmemdraw` and the parts of its `libdraw` it links, unmodified | test tool: the oracle of the shapes' pixels, of every `erx_memdraw` operation against the code it was imported from, and through `cloadmemimage` of `erx_draw_image`'s decoding and of the C twin's framing of `Y` (Verification) | MIT | tool, never part of a shipped image; fetched at the commit the import's origin file records, verified against a pinned SHA-256, and built for the host out of tree by erXos's own compiler invocations against plan9port's `lib9`, which is already fetched for rc; 9front's mkfiles never run |
| plan9port's `libdraw`, acme, sam, 9term | draw clients, and oracles of the draw protocol's compatibility | MIT (to be confirmed at import) | permanent; ported as erXos's code with the connection code replaced |
| LVGL 9 | the native widget renderer for panels | MIT | stopgap, replaced by the Erlang renderer when the parity test and the panel's frame times admit it; fetched at a pinned version and built out of tree as a native program, its display and input glue erXos's own |
| a bitmap font as Plan 9 subfonts | the glyphs of `erx_term`, in a session's release, and of the menu and the Erlang renderer, in the display's | plan9port's `fixed` fonts (public domain); anti-aliased fonts, such as the Go fonts (BSD-3-Clause) rasterised by a host step, chosen with the first application that needs them | permanent |
| libvterm 0.3.3 | the differential oracle of `erx_vt` | MIT | test tool, never in an image and never linked into erXos; fetched at its pinned release and SHA-256 and built out of tree for the host with the harness `test/vt/vterm_dump.c` |
| `vttest`, Thomas Dickey's | the source of the corpus's `vttest` recordings | MIT-style (X11), confirmed at the pin | test tool, never in an image; fetched at a pinned release and SHA-256, built out of tree for the host and run on a host pseudo-terminal |
| FreeBSD 15.1's `share/termcap/termcap`, from the pinned FreeBSD source | the `xterm` and `vt100` entries `abi/termcap` restricts | BSD-3-Clause, confirmed at the pin | reference; the restricted entries are erXos's text in `abi/termcap` |

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| Wayland (a compositor and `libwayland`) | assumes Linux's DRM, `dmabuf` and `epoll`; its clients bring Mesa and a toolkit; shared-buffer protocols put pixel memory across domains, which erXos avoids by construction |
| X11 (a server, or a rootless server over draw) | the server is a large C program with its own authority model; a rootless X server over the draw protocol stays a possible compatibility layer for FreeBSD programs much later and changes nothing here |
| wxWidgets, GTK, Qt | whole native toolkit stacks in C++ with their own event loops and renderers; against the C17-and-Erlang rule and against principle 3 |
| Scenic (Erlang/Elixir scene graph) | a scene graph owned by the application in its own process, drawn by a native driver; its model is close to this document's widget trees, which take its idea of a declarative tree and drop its native driver protocol for the draw protocol |
| Arcan | a display server with a scripting engine and its own client library; too large a trusted component, and its model of frameservers duplicates erXos's programs |
| LVGL everywhere, as the one renderer | puts every desktop widget's layout and logic in C in a sub-space and makes the widget tree a C data structure; the Erlang renderer keeps layout and state in Erlang where they are small, and LVGL stays where its fonts and widgets pay |
| Inferno's Tk, widget commands as strings | strings parsed at run time, with the quoting and injection problems Tk has; terms are checked by a generated schema and need no parser |
| imperative widgets (`gs`-style create, configure, destroy) | handles and commands put a protocol of sequencing on every application; a retained tree with a diff gives one rule for state and none for order |
| shared pixel memory between client and display | removes a copy for large loads; costs a system-domain installation per window and couples a client's faults to the display; kept as the fix on the watch list if the copy's cost is measured too high |
| each window composing into the screen image under a lock | spreads writes of the screen image over every window process and `erx_screen`, and needs a lock in the NIF, rules for who takes it, and race tests; one writer of the screen image costs only that composes queue in one process |
| shortcuts for the display domain's own clients (handing batches to a window process, an in-domain widget path) | gives a window two ways to be made and driven and leaves open which quotas the domain's own windows spend; one client path costs one file-server hop per batch, on the watch list |
| text rendering in the display domain for clients | would need a font engine and font files parsed from untrusted input on the server side; Plan 9's client-side glyph cache keeps the server free of both |
| a terminal in the display domain, as a console line or as rio's own text window | the display would parse every session's program output beside every window's pixels and keys, and would need the console's lines, logins and single-use tokens to decide which session a window serves; a terminal in the session, as xterm is a client of X, needs none of them and is charged to the session that uses it |
| libvterm or another C emulator as a NIF | a native parser of program output whose fault ends the session's whole runtime, its shells and other terminals with it; a C emulator in a sub-space of its own would be safe and is not needed |
| the `Y` decoder in C inside `erx_memdraw` | the one native parser of client bytes in the display domain; compressed loads are fonts and images loaded once, not a hot path, so an Erlang decoder costs nothing that matters and leaves `erx_memdraw` parsing nothing |
| a scrollback size set per terminal or in the manifest | a parameter nobody has asked for; 131,072 cells, about 1,600 rows of 80 columns, stays fixed until a user asks for more |
| a terminal type of erXos's own, `TERM=erxos` | an honest entry, but unknown to every other system a session reaches and to every program with built-in knowledge of xterm; FreeBSD named vt(4) `xterm` for the same reason |
| terminfo, as Linux distributions use | FreeBSD describes terminals in termcap, and erXos follows FreeBSD; its one consumer at run time reads a generated table |
| xterm.js or tmux as the oracle | xterm.js brings Node into host tooling, which TypeScript's rule keeps out; tmux takes its widths from the host's C library and needs a server process; xterm itself has no headless dump |
| grapheme clustering, so an emoji sequence takes one cell pair | terminals disagree on it and programs' `wcwidth` cannot express it, so the cursor would part from what programs compute |

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| plan9port's `libdraw` is harder to rebase on the file connection than expected | medium | acme and sam arrive later | the window files match Plan 9's native names and formats, so 9front's `libdraw` is the fallback source of the connection code |
| `libmemdraw` keeps state that is not safe across schedulers | low | races in the NIF | checked at import; the primitives' tables are read-only after `memimageinit`, and no image is touched by two processes at once (G2) |
| 9front's `libmemdraw` needs more of a Plan 9 environment than plan9port's `lib9` gives, so the 9front build does not compile on the host unmodified | medium | the shapes lose their oracle until it does | a header of erXos's own beside the build's recipe supplies what is missing; 9front's `.c` files are never edited, since an edited oracle checks nothing |
| composes serialised through `erx_screen` limit a desktop with several animating windows | low | dropped frames under load | the watch-list measurement; `erx_screen` gathers waiting flushes into one push |
| the `fill` copy per dirty rectangle dominates on large screens under TCG | medium | slow desktop under TCG | the watch-list measurement; an image over the pool buffer |
| a board's panel bus controller does DMA it cannot confine | medium | the panel cannot be driven from the display domain in a release build | the board's DMA contract says so; such a panel is driven without DMA, which a few hundred pixels afford, or its driver runs in a domain of its own |
| the Erlang renderer never reaches LVGL's frame times on panels | medium | LVGL stays | acceptable; it is a bounded native program behind the seam |
| OSC 8 links confuse a terminal that declares `links` wrongly | low | stray characters | links follow the capability table; the serial console's default is off |
| a program, or a session reached remotely, uses more of xterm than the subset, since the terminal is called `xterm` | medium | a misdrawn screen in that program | local programs read the restricted termcap entry; the ignored counters name the sequences, which become rows of the tables when a program needs them; FreeBSD's console has the same gap |
| `io_ansi`'s fallback strings on erXos include forms that are not the sequences they name: `cursor_home` is `ESC H` (HTS), `scroll_forward` and `scroll_backward` are `ESC S` and `ESC T`, `tab_backward` is `ESC I`, and `hyperlink_start` writes the URI before the parameters (`otp/lib/stdlib/src/io_ansi.erl:2614`, `:2646-2649`, `:2684`, `:2788-2790`) | high, on every erXos terminal, since erXos has no terminfo | `io_ansi` callers misdraw | upstream OTP bugs, which erXos's OTP fixes, since erXos owns its OTP (the work is in `TODO.md`); `erx_vt` implements the standard sequences and does not imitate them |
| a program on a remote host, reached over `ssh`, counts widths from its own tables | medium | a cursor parts from the text after a wide or combining character in that program | every program on erXos, the line editor and `erx_vt` read the one width table; a remote host's tables are its own, as between any two UNIX systems |
| a display's session needs no passphrase | certain, until the login design | whoever is at the display holds its principal's authority | the manifest names the principal deliberately; work that needs the principal's vault keys logs in at the UART or the host link; the login design below replaces it |

Decisions taken with the owner:

1. **Input formats.** `mouse` is served in Plan 9's 49-byte form and
   `kbd` in 9front's form, which serve plan9port's programs and give key
   up and down to widgets and games. An `input` file of `input()`
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
6. **The clipboard** is shared per display, as X does; the `snarf`
   parameter withholds it from a grant, and Security states who shares
   it.
7. **The input context.** The shell announces the argument types each
   command accepts with `-erx_args`, so the terminal highlights the
   presentations a command can take.
8. **The `Y` decoder is Erlang.** Compressed pixels are decoded by
   `erx_draw_image` into the rectangle's pixels and loaded as a `y`
   would be, so no NIF of the display domain parses a client's bytes,
   without exception.
9. **One width table for the whole system.** The terminal generator
   writes `erx_vt`'s widths, musl's `wcwidth` tables and `erx_width`,
   which `prim_tty:wcwidth/1` answers from, from one rule and OTP's
   Unicode data ([design.md](design.md#decisions)).
10. **The scrollback stays fixed** at 131,072 cells a terminal.
11. **erXos's OTP fixes `io_ansi`'s four wrong fallback strings**, since
    erXos owns its OTP (Risks).

Open decisions for the owner:

1. **Login at a display.** The owner is rethinking login, and until that
   design exists a display serves the one session its manifest entry
   names, started without a login ([A display's
   session](#a-displays-session)). The design must settle:
   * **login**: how a person proves who they are at a display, what
     shows the prompt, and which domain sees the passphrase, given that
     the display domain sees every keystroke it routes;
   * **lock**: what the reserved chord brings up, and what of a locked
     session stays on the screen;
   * **log out**: which of a principal's sessions and windows end, and
     what the display shows afterwards;
   * **several principals on one display**, in turn or side by side, and
     who shares the clipboard then;
   * **kiosk service terminals**: how an operator reaches a shell on a
     kiosk's own screen, and whether the kiosk's application keeps the
     screen meanwhile;
   * whether a display's session opens the principal's vault keys, and
     whether one manifest-named session stays as an option, as an
     automatic login does on UNIX.

   The same rethink covers the console's logins at the UART and the host
   link ([design-live.md](design-live.md#the-console)) and the web
   front end's ([design-web.md](design-web.md#logging-in-and-the-line)).
   Recommendation: design login once for every place a person meets the
   system, keeping two properties the console has today: the system
   shell opens only at a line the manifest marks secure, and a display
   domain's view of what is typed is stated as an X server's is.

## References

* Plan 9 manual: draw(3), draw(2), image(6), font(6), mouse(3), rio(4),
  wctl; 9front's kbd(3) for the `kbd` record format.
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
