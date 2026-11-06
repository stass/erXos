# The display: draw, windows, widgets and presentations

A display is a domain that holds a display device and the input devices
that go with it, and serves **windows** to the rest of the system as
files. A window is a rectangle of pixels with an input stream, and the
same window serves three kinds of client: a program that draws, with
Plan 9's draw protocol; an Erlang application that describes a user
interface as a term and receives events as messages; and a terminal,
which shows a session's tty and keeps the typed output of the shell and
the inspector bound to the values it came from, as Genera's dynamic
windows do. One display serves a desktop with overlapping windows under
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
  own terminal emulators, menu and widget renderers included, makes it
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
* **A terminal window is a console line.** A terminal emulator in the
  display domain owns a window and offers the console service a line, as
  the serial port is one. The console service shows its menu and login on
  it and connects a session's tty to it, so the login, the principal and
  the session's authority are those of any console line; a window is not
  a secure line in a release build, so it never carries the system shell,
  and only the console decides which session a window opened without a
  login serves.
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
  Every value the shell and the inspector emit already carries its type
  from the inspection schema. Its text is the form the shell parses back
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
5. A session's shell runs in a terminal window with its tty unchanged:
   the login, `Ctrl-G` menu, job control and `termios` behave as on the
   serial console.
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

## Overview

```text
 session domain                        display domain
+-----------------------------+     +----------------------------------------+
| program --draw bytes--> fid |     | erx_winfs (erx_fs): /S/N/{draw,ctl,     |
|          <--mouse/kbd--     |---->|   mouse,kbd,wctl,label}, /S/snarf;      |
|                             |     |   the window table, erx_wm's policy,    |
|                             |     |   input routing                         |
| Erlang app --ui ops-->      |     | erx_window: one process per window,     |
|   display facet             |---->|   images in erx_memdraw (C)             |
|            <--{ui,...}--    |     | erx_screen: the screen image, compose,  |
| shell <-> tty <-----------> |     |   power, the only path to the driver    |
|   (console service)         |     | erx_ui_server: one per widget window;   |
+-----------------------------+     |   renderers: Erlang, LVGL (sub-space)   |
                                    | erx_term: terminal emulator, a console  |
                                    |   line, presentations                   |
                                    | drivers: display, pointer, keyboard,    |
                                    |   touch, encoder, keypad                |
                                    +----------------------------------------+
```

A **display domain** is a configured domain of the manifest holding one
display device and its input devices. Its release runs the display
driver, the input drivers, the window file server `erx_winfs`, one window
process `erx_window` per window, the screen owner `erx_screen`, the
widget service behind the display facets, widget servers, terminal emulators, the overlapping
policy's menu and, where the manifest asks for it, the LVGL renderer as
a native program.

A **window** is a directory a client makes with `mkdir` in a directory
of a grant it holds. It is one process, `erx_window`, which holds the
draw connection, whose image 0 is the window's pixels, and the window's
pending input. Its files are the connection's `draw` and `ctl`, the
input files `mouse` and `kbd`, the geometry file `wctl` and the title
`label`. The display domain's own windows, terminal windows among them,
are made the same way in its own directory of the tree.

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

**Terminal windows** are console lines: the console service connects a
session's tty to a terminal emulator's line as it connects one to the
serial port. The emulator draws the tty's bytes as a terminal does and
sends keystrokes back. It parses one escape sequence of its own, the
presentation link, and binds the linked text to its type and value.

**Presentations** are the values of records and inspection attributes,
typed by the inspection schema. `erx_render` writes each as its canonical
text at a terminal, inside a link when the terminal declares it
understands links; widgets take a value as a `present` property. A
selection puts text where the user is typing, or tells the application;
the shell and the application act with their own capabilities.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **G1.** A client reaches only its own windows' pixels and input | a draw connection names images by ids it allocated and by image 0, its window; the protocol has no message that names or attaches to another connection's image and no screens; a window's image 0 is never the screen image and never holds another window's pixels, so an `r` reads only what the window drew; a window's files are a grant rooted at the session's directory of `erx_winfs`, and a program's handler walks only the one window's directory for it ([Narrowing](design-files.md#narrowing-for-a-program)); the policy delivers each input event to one window, and under the single policy only to the one shown window | a name or attach message; an image shared between windows or with the screen; a grant rooted above the session's directory; a handler that binds the session's whole tree for a program; an event delivered to a hidden window | a connection that sends every message type with every id from another connection, each refused with `ENOENT`; two sessions whose grants list only their own windows; a program given one window that walks `..` and sibling names and reaches nothing; under the single policy with the service terminal shown, the application's `kbd` receives nothing and its `r` of image 0 returns its own pixels, where a seeded delivery to the application fails it; the decoder's fuzz target |
| **G2.** Each image is touched by one process at a time and lives while any process holds it, and every pixel loop runs over a clipped rectangle | a window's images are written only by its window process and the screen image only by `erx_screen`; `erx_screen` reads a window's image 0 only inside that window's flush call, which the window makes and waits on, and the driver reads an image only inside `erx_screen`'s call to it, which `erx_screen` waits on; calls run one way, window to `erx_screen` to driver, so no two wait on each other; an image is a NIF resource, freed by its destructor when no term refers to it, and `erx_memdraw` has no other free, so `f`, a resize and a window's end drop a reference and never free memory another process holds; the framebuffer is written only by the display driver's `erx_device:fill/3`; every function of `erx_memdraw` that touches pixel memory takes an `erx_clip_t`, which only `erx_draw_clip` produces, with checked arithmetic, from the operation's rectangles and both images' bounds | a read of an image outside its writer's call; a call from the driver or `erx_screen` back up the chain; an explicit free of an image; a loop over an unclipped rectangle | the build checks over `erx_memdraw`'s sources and the call direction (Chokepoints); the differential test against the reference renderer with rectangles far outside every image; the display suite in hosted mode under ThreadSanitizer, with windows drawing, resizing and ending while `erx_screen` composes and the driver copies, where a seeded compose outside the flush call makes it report; the same run under ASan, where a seeded explicit free makes it report |
| **G3.** What a client makes the display domain spend is bounded by its grant | memory: a grant carries quotas of windows, pixel bytes and widget nodes; each image is charged its pixel bytes rounded up to 4 KiB, so the pixel quota bounds the image count too; a window checks each allocation against the quota with checked arithmetic before it allocates; images die with their window; a write carries at most the file protocol's 64 KiB, a widget tree at most the display facet's `max_request`; a window's pending input and dirty list are bounded. CPU: a client's draw work runs only in its windows' processes, at most the `windows` quota of them, each of which has at most one flush in `erx_screen` at a time; its widget work is admitted by its display facet within the grant's share of reductions | an allocation outside the quota check; an image that outlives its window; an unbounded queue; a window with two flushes outstanding | an allocation loop refused at the quota with `ENOMEM` and the domain's memory unchanged; a window closed with images left, all freed; a widget tree of one node more than the quota, refused whole; a client that floods flushes from one window while another window's one flush waits at most one compose, where a seeded second outstanding flush fails it |
| **G4.** A presentation grants nothing | a presentation is a type and a canonical text; the terminal emulator's only actions on one are to insert its text as keyboard input and to highlight the presentations of the types an input context names; a widget's only action is the `{select, Type, Value}` event to its application; neither carries a facet, a grant or a capability, and the command that then runs is checked by the shell's facets as any typed command is ([Authority](design.md#authority)) | a terminal that calls a service for a clicked link; a widget server that performs the action a presentation names | a session without an inspect facet clicks a pid presentation and the inserted `i` command fails with `no_facet`; the link parser's fuzz target; a source check that `erx_term` and `erx_ui_server` call no facet |
| **G5.** Attributed text in a window is displayed only through the line escape, and a program's output reaches its terminal window unchanged | a window's label, a widget's `present` text and a widget's text drawn from a record value are escaped by the displayer with `erx_text:escape_line/1` ([Attributed text](design-live.md#attributed-text)); the terminal emulator takes its bytes from a tty, which changes nothing but what `termios` says (V1), and interprets them as a terminal does | a label drawn raw; a terminal emulator that filters a program's bytes | the attributed-text test corpus of design-live sent as a label, as a `present` text and as a record value in a widget; V1's byte test with a terminal window in place of the serial line |
| **G6.** Nothing paints without a change | the only path to the device is `erx_screen`, which composes on a window's flush call and asks windows to flush only when the layout changes, the driver restarts, the panel wakes or `erx_screen` itself restarts; the driver pushes only the rectangles it is given; no process of the display domain has a redraw timer | a periodic repaint; a flush of the whole screen for a small change | an idle display for one minute makes no device request, counted at the driver; a one-pixel change makes exactly one flush of one rectangle; moving a window flushes exactly the area whose content changed |
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
                   mem := reference()}.        % the erx_memdraw resource
-type conn() :: #{window := window_id(),
                  images := #{image_id() => image()},
                  bytes := non_neg_integer(),  % pixel bytes charged, against the quota
                  op := 0..11,                 % the compose operation, SoverD by default
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
images. A `draw` write and a read of `r`'s pixels each carry at most the
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
([design-tmp.md](design-tmp.md#starting-and-mounting)). Its own windows,
the terminal windows and the menu, live in its own directory beside the
sessions', under that grant's quotas from the display's manifest entry;
its widget servers make and draw an application's windows in the
application's directory, so they are charged to the application's grant.

### Draw messages

The byte encoding of the draw protocol is declared in
`abi/formats/draw.txt`, from which the generator produces the Erlang
decoder `erx_draw_codec`, its bounded C twin for the fuzz target and the
message table of this document's interface section. The messages are
those of draw(3): `b` allocate an image, `f` free one, `d` draw, `L`
line, `p` poly, `P` fill poly, `e` ellipse, `E` arc, `s` string, `x`
string with background, `i` allocate a font cache image, `l` load a
glyph into one, `y` load pixels, `Y` load compressed pixels, `r` read
pixels, `O` set the compose operation, `o` set the origin, `c` set the
cursor and `v` flush. `A`, `F` and `t` (screens and layers), `N` and `n`
(names) and `D` (debugging) are not in the format and decode as unknown
messages, which fail the write. A write to `draw` is a sequence of
messages, decoded whole before any is applied; a write that fails applies
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
renderer emits links only when the tty's terminal declares them: the
terminal emulator and the host tool's `console` set the session's
`TERM` to a value whose terminfo-style capability table lists `links`,
which `erx_render` consults; the serial console's default does not.

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
button outside any window for its menu: new terminal window, resize,
move, delete, hide, and the hidden windows by label. The menu is a
window of the display domain's own, drawn by `erx_wm_menu` as any client
draws, with each label through the line escape. The **single** policy,
`erx_wm_single`, shows exactly one window, the one the manifest names or,
while the service chord has called it, the service terminal, gives it
the screen's rectangle, keeps every other hidden, delivers every event to
the shown window, keeps the chord for itself, and draws nothing. A
`wctl` write is a `place` request, so a program can resize or hide its
window under a policy that allows it and gets `EINVAL` under one that
does not.

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
`draw` reaches it as a binary, which `erx_draw_codec` decodes into a list
of messages or fails with the position of the first malformed byte; the
write then fails with `EINVAL` and the display domain's log records the
window and the position. A decoded list is applied in order by a pure
core, `erx_draw_core`, which takes the connection's state and a message
and returns the next state and the `erx_memdraw` operation to perform, or
an error: `ENOENT` for an id the connection does not hold, `EEXIST` for
an id it does, `ENOMEM` for an allocation past the quota, `EINVAL` for a
rectangle, channel or count outside the bounds. The process performs the
operations only after every message of the write has been checked, so a
failed write applies none of them. The core is tested exhaustively on the
host over small ids and rectangles.

Each operation goes to `erx_memdraw`, which computes the clipped
rectangle with `erx_draw_clip` from the destination's clip rectangle,
the source's and the mask's bounds and the operation's rectangle, and
runs `libmemdraw`'s primitive over it: `memimagedraw` for `d`, `y` and
`x`; `memline`, `mempoly`, `memfillpoly`, `memellipse` and `memarc` for
the shapes; `memimagedraw` with the glyph as mask for each character of
`s`; the image(6) decoder for `Y`, which writes only into the clipped
rectangle of the destination already allocated and fails the write on
any input that would decode past it or end short. Every size, offset,
stride and count `erx_memdraw` computes from a message, and the union of
dirty rectangles, uses checked arithmetic. The primitives read no global
state after their initialisation at load, which is checked when
`libmemdraw` is imported. An operation over more than 64 KiB of
destination pixels runs on a dirty scheduler, so a full-screen compose
never holds a normal scheduler. Fonts are the client's: `i` allocates a
font cache image and `l` loads a glyph's pixels into it, so the display
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

### Terminal windows

`erx_term` is a terminal emulator in the display domain: a client of a
window in the display domain's own directory, a font cache it filled
from a subfont file of its release, and `erx_vt`, a pure state machine
from bytes to a grid of cells and a cursor, exhaustively tested on the
host for its control sequences and fuzzed. It implements the sequences
OTP's `prim_tty`, toybox's programs and `vttest`'s core expect of a
VT-style terminal; rio's mouse-driven text editing is a program's choice
on top, not the terminal's. Its copy and paste use the display domain's
own `/snarf` when its grant carries `snarf`, and stay inside the
terminal window otherwise.

A terminal window is a **console line**. `erx_console` connects one
session's tty to a line at a time and shows its menu and login on it
([The console](design-live.md#the-console)); a serial port is a line, and
so is a terminal emulator, which offers itself through the console
service's `offer_line` operation, with its size from `wctl`, once its
window exists. The system domain grants the display domain that
operation only when the display's manifest entry sets `console_line`,
which also carries the most lines the display may offer, 16 by default,
and the windows' `secure` attribute: never set in a
release manifest, and allowed in a development one. The console service
writes to a window's line what it writes to any line and receives from
it what any line receives, so the login, the principal, `Ctrl-G`, lock
and log out are those of design-live, unchanged; the kernel's early
console and the system runtime's emergency output reach the UART alone,
and a window shows its session's own output and the log lines the log
service sends it. The display domain sees the bytes, the login's
passphrase among them; that is the trust Security states, and a window
that is not secure never carries the system shell, which only a login at
a secure line opens. A release manifest that does not accept that trust
leaves `console_line` unset. That removes the display's terminal windows
altogether, not only their login: a window's line shows a login whenever
it is locked or offered without a valid token, so a display that may
show no login can offer no line. Sessions of such a display log in at
the UART or the host link, and their programs' windows still open on
it.

**New windows and their tokens.** Which session a window serves is the
console's choice, never the display's
([Window tokens](design-live.md#window-tokens)). When a session asks
for a new terminal window, the console mints a single-use **window
token** bound to that session and to this display and sends it to the
display domain, whose new `erx_term` makes its window and presents the
token with `offer_line`. A valid token connects at the new line a tty
with a shell of the session that asked, with no login, as rio's new
window runs a shell in its opener's namespace, and the line then has
that session's principal, as any UNIX terminal carries its user's
authority. An offer without a valid token gets a login and never a
shell. So the display's first window, which it offers alone before any
session is introduced to it, shows a login, and so does the single
policy's service terminal, in every build. The overlapping policy's
menu item "new terminal window" is the line's own menu action at the
line of the window that has the keyboard, so there is one path to a
token: it gives the session connected there a new window, or a window
that shows a login when no session is connected there, and it does
nothing the display could not do by typing `Ctrl-G` and that item into
the window. A session that logs in at a terminal window is introduced
by the system domain to that display, so programs it starts get
windows beside their terminal.

**Presentations in a terminal.** `erx_vt` parses the OSC 8 sequence
above as one of its control sequences, with a bound of 4 KiB on the
sequence and the URI grammar `erx:TYPE/TEXT` with `TYPE` an identifier of
the schema's type table and `TEXT` the encoded canonical text; a
sequence outside the grammar is dropped as any unknown OSC is. A cell
written while a link is open carries the link's id, so the text stays
bound to its type and value as the screen scrolls, until the cells are
overwritten. The emulator's actions on a presentation are two, and
neither reaches a service (G4):

* a click sends the presentation's text to the tty as keyboard input,
  as a paste does, so it lands in the shell's command line or in whatever
  program is reading;
* while the shell is editing a command whose argument types it knows,
  the shell writes through `erx_render` an **input context**, `ESC ] 8 ;
  ; erx:accept/TYPES ESC \` with `TYPES` a comma-separated list, and the
  emulator highlights the presentations of those types; a click on one
  inserts its text and the shell clears the context when the line is
  submitted. The context comes from the catalog's `-erx_args` for the
  command typed so far. A shell without the catalog writes none, and the
  terminal shows links without highlights.

The shell parses what the click inserted exactly as it parses what the
user types, so a presentation cannot carry more than the keyboard
could. The same bytes over the host link reach the host's terminal
unchanged through `erx console`, which copies the tty raw, and a host
terminal that understands OSC 8 shows the link; `tools/erx` registers an
`erx:` URL handler only if the operator installs it, and that handler
runs `erx inspect` with the host session's own facets.

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

### Choosing a display

A domain holds a display facet for each display it was introduced to, in
its capability registry
([Granting a running domain](design-system.md#granting-a-running-domain))
under the name of the domain that serves it: `display` for a display
domain of that name, another name for a second display domain, `web` for
the web domain. A session may hold none, one or several. The **default
display** is the domain's environment variable `display`, which whoever
starts the domain sets to the display it was started from: a login at a
terminal window sets that window's display, a web login sets `web`, a
configured domain takes it from its manifest entry, and a login at the
serial console or over the host link sets none. A user changes it as any
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
optionally, a key chord that shows the service terminal. The application
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
* **Service.** The optional chord, which `erx_wm_single` keeps and never
  delivers, shows the service terminal, a terminal window of the display
  domain with the release's login on its console line, in place of the
  application's window: the application's window is hidden, receives no
  input and shows nothing while the terminal is shown, and returns on the
  chord or at log out. The terminal is composed from its own image, so
  nothing of it reaches the application's. A manifest without the chord
  has no service terminal and no console line.

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
web domain. The console service's `offer_line`, in
`abi/services/console.txt`, with the window token it presents or none,
granted to a display domain whose manifest entry sets `console_line`,
and the console's request to that display for a new terminal window,
which carries the token.

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

**Drivers**: the `erx_display` behaviour; the `input()` record.

**Interaction with other subsystems.** The device service gives the
display domain its devices and the system domain introduces sessions and
applications to it ([Devices](design-system.md#devices)); a session's
handler binds a window's directory into a program's namespace
([Narrowing](design-files.md#narrowing-for-a-program)); the console
service treats a terminal window as a line
([The console](design-live.md#the-console)); `erx_render` emits
presentations ([Pipelines](design-shell.md#pipelines)); the inspector
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
| a terminal emulator crashes | its window ends with it, its holder; its line drops, and the terminal connected at it detaches, as a serial console's does when the line drops, its session reachable from another line | a new terminal window from the menu |
| a widget server crashes | its window ends with it, its holder; the facet sends the application `{ui_down, Window, server_down}` | the application opens a new window |
| the display domain ends | every window ends; sessions' fids fail with the connection down; the terminals connected at its windows detach, as above; each opener of a UI on it receives `{ui_down, Window, display_down}` from its display facet, which ends | the domain service restarts the domain within its intensity and the system domain introduces its clients again; applications reopen |
| a widget tree fails validation | `ui_tree` answers `{error, Reason}`; the realised tree is unchanged | the application's |
| the LVGL program exits | the widget server ends the window and the application receives `{ui_down, Window, renderer_down}` | the application reopens; the display domain logs the exit record |
| an input device stops | its driver restarts and resets it | events resume |
| a window's `mouse` or `kbd` queue is full | the oldest record is dropped and counted; a resize is never lost | the client reads |
| the panel is off and a client flushes | the flush is answered without a compose | the next input turns the panel on and repaints |

The inspector shows a display under `[domains, Id]` with its windows,
each with owner, rectangle, state, image count, pixel bytes, flush count
and dropped input records, and a terminal window with its line and
connected session, all marked `service`;
`/proc/domains/Id/windows/N/status` shows the same. The display domain's
log carries each refused write with the window, the reason and the
position of the fault.

## Security

* **Isolation of windows** is G1: ids are per connection, the protocol
  has no cross-connection reference, no window's image is the screen
  image or another's, grants are rooted per session and the handler
  narrows per program. A program given a window learns only its own size
  and input.
* **The display domain's trust.** It sees what it shows and what is typed
  at it, and holds nothing else: device capabilities, its own budget and
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
  keystrokes and inject input into the windows it serves, with the
  authority of the shells in its windows, as an X11 or Wayland server
  has: through them it reaches what their principals reach, their
  other sessions included, and a lock at the UART leaves the windows
  opened from it running, as on UNIX. It also routes the input of the
  sessions introduced to it, reads and writes its display's clipboard
  where `snarf` is on, and records the
  passphrase of whoever logs in at its windows. It has nothing beyond:
  it cannot read a domain's memory, message a process it was not
  introduced to, or reach anything of a principal that neither uses the
  display nor types at it
  ([Window tokens](design-live.md#window-tokens)). It
  cannot reach the system shell in a release build, nor at a window
  opened without a login in any build: the system-shell facet belongs to
  a login at a secure line and never to a session, and no window is a
  secure line in a release build, since the manifest check refuses a release
  manifest that marks a display's windows `secure`. It cannot choose the
  session a window without a login serves: only a window token the
  console minted for a session's own request opens one, and an offer without
  a valid token gets a login. Its windows' logins are never presence at
  the machine, cannot enrol a principal, and count against a name in
  their own class, so its wrong passphrases cannot lock that name out at
  the UART ([The console](design-live.md#the-console)). A release
  manifest that keeps logins off the display leaves `console_line` unset,
  which removes its terminal windows. This is the trust an X server or a
  Wayland compositor has, stated.
* **Input** is routed by the policy to one window per event, and nothing
  lets a client write another window's input. Under the single policy
  the service chord never reaches the application, and while the service
  terminal is shown the application receives no input, so the operator's
  keys at the login go to the console line alone.
* **The clipboard** is shared, per display, by every grant on it that
  carries `snarf`, whatever its principal: the sessions of every
  principal introduced to that display, whether logged in at one of its
  terminal windows or at another console line, in turn or side by side,
  every program those sessions give `/dev/snarf`, and the
  display domain's own terminal emulators. What one of them copies, any
  other can read. The `snarf` parameter withholds it from a grant, whose
  tree then has no `/snarf`; a release manifest that serves more than one
  principal at a display and must keep their clipboards apart sets
  `snarf` off for every grant of that display, the display domain's own
  included, and copy and paste then stay within a program or a terminal
  window.
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
* **Untrusted bytes in C.** The draw decoder's C twin, the `Y` decoder,
  `erx_memdraw`'s primitives and the native renderer's reader parse or
  act on client bytes; each has a fuzz target, and every size, offset and
  count they compute uses checked arithmetic (Verification).
* **Residuals.** Implicit bidirectional reordering of displayed text is
  not escaped, as in design-live. A window can draw a convincing copy of
  another window's content or of the login prompt; under the overlapping
  policy the border marks the window that takes the keyboard and the menu
  names windows by label, and the login's reserved chord shows the real
  console menu, as `Ctrl-G` does on the serial line. Any program writing
  to a terminal can write an input context, as the shell does, and so
  highlight presentations the shell did not ask for; a click on one
  still inserts only the presentation's text, shown in the command line
  before anything runs.

## Verification and testing

Each passing case has a seeded failure that proves the code ran.

* **The draw core.** `erx_draw_core` explored exhaustively over small
  ids, every message type and rectangles at and across the bounds; a
  seeded skip of the quota check fails the `ENOMEM` cases. The decoder
  `erx_draw_codec` has a generated fuzz target and a differential test
  against its C twin over the corpus; a seeded off-by-one in a length
  field fails it.
* **The pixel primitives.** `erx_draw_ref`, a slow reference
  implementation of draw(2)'s semantics in Erlang, pixel by pixel and
  with its own decoder of image(6)'s compressed form, is the oracle:
  random operations over random images and channels through
  `erx_memdraw` and through the reference must agree pixel for pixel, and
  Plan 9's own `draw` test images are a fixed corpus. A seeded change to
  one Porter-Duff operator fails it. The same run under ASan and UBSan,
  with rectangles far outside every image, is the test of G2's clipping;
  a seeded bypass of `erx_draw_clip` is caught by the chokepoint check
  and by ASan.
* **The `Y` decoder.** A fuzz target over compressed payloads into
  destinations of every channel and size, under ASan and UBSan in `make
  check-fuzz`, landing with the import; the differential test against
  `erx_draw_ref`'s decoder over the corpus, where a seeded off-by-one in
  a run's length fails it; payloads that would decode past the
  destination or end short fail the write, where a seeded removal of the
  bound makes ASan report.
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
  narrowed program, the single policy with the service terminal shown;
  the `wctl` grammar's fuzz target; a window's end freeing its images,
  measured by the domain's budget before and after, and a window ending
  with its holder; a seeded leak of one image fails it.
* **The window system.** `erx_wm_rio` and `erx_wm_single` are pure and
  tested over sequences of place requests and input events; a property
  test that the single policy shows at most one window and delivers every
  event to it, never the chord, and that every rectangle lies within the
  screen under both; a seeded unchecked move fails it.
* **The terminal.** `erx_vt` explored over its control sequences and
  fuzzed; differentially against a host terminal emulator's screen dump
  over a corpus of program output, `vttest`'s core among it; V1's byte
  test with a terminal window in place of the serial line, where a
  seeded filter fails it; the link parser's fuzz target; G4's `no_facet`
  test; a seeded action in the emulator that calls a facet is caught by
  the source check.
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
  images, under TCG and HVF; a seeded wrong channel conversion fails it.
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
  lost: other windows keep their images and input, other sessions keep
  their terminals, and the terminal whose window crashed detaches with
  its session reachable from another line. A seeded supervisor that
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
| Only the display driver's process calls `erx_device:fill/3` and `post/3` on the display device | the same xref check |
| Only `erx_winfs` calls `erx_wm`'s callbacks | the same xref check |
| Only the generated `erx_draw_codec` decodes draw bytes, and only the generated reader decodes the native renderer's operations and events | the generated-output drift check |
| Only `erx_render` writes the link and input-context sequences | a source check for the `erx:` URI prefix |
| `erx_term` and `erx_ui_server` call no facet | an xref check that neither module nor its callees reach `erx_facet` clients |
| Attributed text in the display release passes through `erx_text:escape_line/1` | the source check of V9 extended to `erx_wm_menu`, `erx_ui_erlang` and `erx_term` |

## Performance

Numbers to measure, for [todo-performance.md](todo-performance.md):

* a full-screen `y` load from a session's program crosses the lane, the
  funnel and the file server before `erx_memdraw` copies it; measure MB/s
  on HVF at 1920 by 1080; the fix on the table is a pixel object made by
  the system domain and installed in both domains, as the session's
  shared mappings are;
* the display domain's own clients, the terminal emulator and the Erlang
  renderer, pass every draw batch through `erx_winfs`'s grant; measure
  the terminal's scrolling and the renderer's frame time against the
  same batches handed to the window process directly;
* composes serialise through `erx_screen`, and a window waits in its
  flush call for its compose, or in direct mode for the driver's copy;
  measure frame times of several windows animating at once, and a
  kiosk's flush latency;
* the `fill` copy from the screen image into the framebuffer pool per
  dirty rectangle, against an `erx_memdraw` image over the pool buffer;
* the dirty-scheduler threshold for draw operations;
* the Erlang renderer's diff, layout and draw time per frame on a 240 by
  240 panel against LVGL's, which is the gate that retires LVGL;
* the terminal emulator's redraw per changed line of cells;
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
| Plan 9's `libmemdraw` and the image(6) codec, from 9front | the per-byte pixel primitives of `erx_memdraw` and the `Y` decoder | MIT (to be confirmed at import against 9front's licence file) | permanent; imported as erXos's code with an origin file |
| plan9port's `libdraw`, acme, sam, 9term | draw clients, and oracles of the draw protocol's compatibility | MIT (to be confirmed at import) | permanent; ported as erXos's code with the connection code replaced |
| LVGL 9 | the native widget renderer for panels | MIT | stopgap, replaced by the Erlang renderer when the parity test and the panel's frame times admit it; fetched at a pinned version and built out of tree as a native program, its display and input glue erXos's own |
| a bitmap font as Plan 9 subfonts | the terminal emulator's, the menu's and the Erlang renderer's glyphs | plan9port's `fixed` fonts (public domain); anti-aliased fonts, such as the Go fonts (BSD-3-Clause) rasterised by a host step, chosen with the first application that needs them | permanent |

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
| a rio-style text window as the window system's own | duplicates the tty, the line discipline and the console's menu in the display domain; a terminal emulator as a console line reuses all three |

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| plan9port's `libdraw` is harder to rebase on the file connection than expected | medium | acme and sam arrive later | the window files match Plan 9's native names and formats, so 9front's `libdraw` is the fallback source of the connection code |
| `libmemdraw` keeps state that is not safe across schedulers | low | races in the NIF | checked at import; the primitives' tables are read-only after `memimageinit`, and no image is touched by two processes at once (G2) |
| composes serialised through `erx_screen` limit a desktop with several animating windows | low | dropped frames under load | the watch-list measurement; `erx_screen` gathers waiting flushes into one push |
| the `fill` copy per dirty rectangle dominates on large screens under TCG | medium | slow desktop under TCG | the watch-list measurement; an image over the pool buffer |
| a board's panel bus controller does DMA it cannot confine | medium | the panel cannot be driven from the display domain in a release build | the board's DMA contract says so; such a panel is driven without DMA, which a few hundred pixels afford, or its driver runs in a domain of its own |
| the Erlang renderer never reaches LVGL's frame times on panels | medium | LVGL stays | acceptable; it is a bounded native program behind the seam |
| OSC 8 links confuse a terminal that declares `links` wrongly | low | stray characters | links follow the capability table; the serial console's default is off |
| the display domain's view of the login's passphrase is unacceptable for some deployments | medium | no login at the display | the manifest's `console_line` parameter; a serial login, whose programs' windows open on the display, and no terminal windows |

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
5. **The login on a terminal window.** A release build may show its
   login on a terminal window, so the display domain sees the passphrase,
   with the trust stated in Security; the `console_line` parameter of
   the display's manifest entry turns it off, and with it the display's
   terminal windows. A window is never a secure line in a release build,
   so the system shell, which only a login at a secure line opens, is
   never connected there; a development manifest may mark windows
   secure, its display domain being in that build's trusted base, and a
   `root` login at such a window gets the system shell. A window
   without a login shows the shell of the session whose window token it
   presents, with that session's principal's authority.
6. **The clipboard** is shared per display, as X does; the `snarf`
   parameter withholds it from a grant, and Security states who shares
   it.
7. **The input context.** The shell announces the argument types each
   command accepts with `-erx_args`, so the terminal highlights the
   presentations a command can take.

## References

* Plan 9 manual: draw(3), draw(2), image(6), font(6), mouse(3), rio(4),
  wctl; 9front's kbd(3) for the `kbd` record format.
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
