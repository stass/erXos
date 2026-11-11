# The web: a browser as a display and an inspector

The web is a view of a running erXos from a browser: the inspector's
records, `/proc`'s tree, the kernel log, traces, and the user interfaces of
Erlang applications. The browser runs one client, written in TypeScript
with React, that the front end serves as static files; the machine sends
that client typed data over one WebSocket protocol and never a byte of
markup or script. Records, log lines and trace records arrive as data the
client lays out itself, as `erx_render` lays them out at a terminal; an
application's widgets arrive as the widget server's changes to its tree,
which the client applies to a model of its own and renders as a web page,
so **a browser is a display**: one more medium behind the widget
interface, rendered the way that medium renders, not a copy of a native
window. A URL is an inspector path, the same path `erx inspect` and
`/proc` take, and a link is a presentation, the same `erx:TYPE/TEXT` a
terminal's hyperlinks carry. The protocol reaches a browser through two
**front ends**: the host tool's, `tools/erx web`, which serves a
developer's browser on the host and relays the protocol over the host
link, so a machine with no network device has a browser UI; and the
network's, cowboy in the **web domain**. Switching between them changes
the transport and nothing else. The architecture is
[design.md](design.md); the inspector, `/proc`, the host link and
attributed text are [design-live.md](design-live.md); widget trees, the
widget server, choosing a display and presentations are
[design-display.md](design-display.md); facets are
[design-domains.md](design-domains.md#facets).

Decisions every reader of this document needs:

* **The machine sends data, the client draws.** Every message the machine
  sends a browser is a message of `abi/protocols/web.txt`: a record, a
  batch of log or trace entries, a batch of widget changes, a status. The
  machine writes no HTML, no CSS and no script, and serves no HTTP over
  the host link. Layout, styling and interaction are the client's.
* **One source for the protocol.** `abi/protocols/web.txt` declares every
  message; a Ruby generator emits the Erlang codec the web domain uses
  and the TypeScript codec and types the client uses, and the generated
  files are generated into the build tree like every other generated output. The
  widget changes inside it are the binary form of `abi/formats/ui.txt`
  that the display declares for renderers outside Erlang. The client's
  `hello` carries one hash over every source generated into the client,
  so a client of another build is refused before any view opens.
* **Machine text is text.** The generated decoder gives the client every
  text from the machine as an opaque `MachineText`, which React refuses
  to render and whose bytes nothing reads but the line escape, generated
  into TypeScript from the same Unicode tables as every other display's;
  one component, `Text`, shows the escape's runs. A build check forbids every
  HTML and code sink, and the content security policy forbids inline
  script, `eval` and every origin but the front end's own.
* **The view is the session's, the relay is the web domain's.** Records,
  log lines and traces are fetched in the principal's **session domain**
  through that session's own inspect and trace facets, so a browser sees
  exactly what that principal's `erx:i/1` shows, by construction; the web
  domain holds no inspect or trace facet and knows nothing of inspection.
* **A browser is a display of its own medium.** The web domain serves the
  display service of `abi/services/display.txt`, the same declaration the
  display domain serves: `open_ui`, `ui_tree` and `close_ui`, the same
  `tree()`, the same `{ui, Window, Term, Detail}` events. Its widget
  server is the display's `erx_ui_server` with a renderer for browsers.
  The tree states what the widgets are, their values and their events,
  and the browser renders each kind as a web page renders it; nothing
  requires it to match the native display's pixels or layout, and scroll
  position, focus and similar presentation state stay in the browser.
* **An application names its display.** A session holds a display facet
  for each display it was introduced to, the web's under the name `web`;
  `erx_ui:open/1` opens on the display its options name, or on the
  session's default, and fails at once with `{error, no_display}` when
  there is none ([Choosing a
  display](design-display.md#choosing-a-display)). The browser is a
  second display, never a mirror of the first.
* **Every view is pulled.** The machine sends a view's next update only
  after the browser asks for it with `next`, which the client sends once
  it has rendered the last; a record or a widget tree that changed
  several times meanwhile is sent once, as its newest state. Live pages
  are views that keep asking; nothing reloads, and nothing queues
  without bound.
* **Two front ends, one protocol.** `erx web` terminates HTTP and the
  WebSocket on the host and relays each protocol message, as bytes, over
  the host link's `web` facet, which exists in development builds alone;
  cowboy terminates them in the web domain. Both hand whole messages to
  the same pure connection core, `erx_web_conn`, and both serve the same
  client files. The host tool serves them from the build tree, so the
  developer's browser never runs code the machine supplied.

## Context

A running erXos is inspected at a terminal: `erx:i/1` and the shell's
records in a console session, `tools/erx inspect` on the host, and `/proc`
from any program. Those show one record at a time, as text; a following
value is a click only where the terminal understands OSC 8 links; a
listing does not update; and an application's widgets need a display
device. A browser gives links on every value, pages that scroll, logs and
traces that follow live, and widgets on any machine: a QEMU guest without
virtio-gpu, a board with only a UART, a laptop.

The owner's direction sets the shape: the web starts with `erx` hosting it
on the developer's host and moves to cowboy on the machine, reusing the
display's parts; the browser UI is JavaScript that receives data over a
WebSocket, so the machine "does not need to bother with layout/html at
all"; React, pnpm and TypeScript are approved for it, and Node.js for the
client's build and test tools. The owner also set that the web UI is a
different medium: "we should not try to replicate native desktop in the
browser: instead we should treat web ui as a different medium and render
UI elements appropriately for that medium. It does not need to match
native display pixel by pixel".

The display design made the two things the web stands on. A user
interface is a term with a closed vocabulary, a schema and a binary form
for renderers outside Erlang, so a browser renderer needs no new interface;
and a presentation is a type with a canonical text that names an
inspector path, so a link is a function of the value, not of the page.

**What it builds on.** The escape's tables come from
`tools/gen_terminal.rb`, which reads `abi/terminal.txt` and OTP's Unicode
data and writes `erlang/apps/erx/src/erx_text_tables.erl`,
`tools/generated/terminal_tables.rb` and the kernel's ASCII class, into
`build/gen/`. This design adds outputs to the ABI generator, which fall
under the generated tree's determinism test and ASCII refusal, to the
inspection schema `abi/inspection.txt` and to the pinned fetch step (`tools/erx fetch` over `deps.lock`), and
`.ts` and `.tsx` files to the source ASCII check (`Erx::SourceText`).

## Requirements

1. A browser on the developer's host shows the inspector's records,
   `/proc`'s tree, the kernel log and traces of a machine reached over the
   host link, with every typed value a link, with no network device on the
   machine.
2. The same client is served from the machine over the network, after a
   login, with no change to the client or to what fetches a view.
3. A browser sees and does exactly what the principal it logged in as
   sees and does at a console: the inspector's scope and the session's
   facets, no more.
4. An Erlang application that shows in a window shows in a browser with
   no change, with the same values and the same events.
5. The machine sends only data. No text from the machine is ever
   interpreted by the browser as markup, script, style or a URL, and a
   compromised machine cannot run script in the developer's browser.
6. Live views (records, listings, the kernel log, traces, widget trees)
   follow the machine without reloads, and what a browser can make the
   machine hold or do is bounded and charged to the principal it acts
   for.
7. The host tool's server gives authority on the machine only to a
   browser that presented the printed token: no other page the developer
   visits, no name an attacker controls and no other user of the host
   gets more from it than the client's public files.
8. Every parser of a browser's or the machine's bytes is bounded and has a
   fuzz target.
9. Never fabricate: a value the inspector did not get shows its status, a
   view whose connection is lost shows that it is stale, and nothing is
   cut silently.
10. The protocol has one source, and the client's build is offline,
    pinned and reproducible.
11. An application chooses which of its session's displays a UI opens on,
    the web or a display domain, by name, with a default the session
    sets; with no display it gets a stated error at once, and when a
    display goes away each of its UIs reports its end.
12. The browser is a medium of its own. Each renderer renders a widget as
    fits its medium; the tree states meaning (what the widgets are, their
    values, their events), not appearance; nothing requires pixel or
    layout parity between the browser and a native display; scroll
    position, focus and similar presentation state live in the browser and
    are not reported back; and every comparison of the browser renderer
    with another is about the tree, the values and the events.

## Overview

```text
 developer's host                       system domain               web domain
+---------------------------+         +--------------------+      +------------------------------+
| browser: the client       |         | erx_hostlink       |      | erx_web_conn: pure core, one |
|  (TypeScript, React)      |         |   web facet:       |      |   per browser connection     |
|      | HTTP + WebSocket   |         |   relays message   |----->| lines and logins             |
| erx web (Ruby):           |--host---|   bytes            |      | erx_ui_server + the browser  |
|   files from build/web,   |  link   | erx_web_login:     |      |   renderer, one per open UI  |
|   token, cookie, Origin,  |         |   login, logout    |<-----| erx_web_cowboy: network      |
|   WebSocket relay         |         | display facets     |      |   front end, same core       |
+---------------------------+         +--------------------+      +---------------+--------------+
                                                                    views |  ^ display service
 browser on the network --TLS--> erx_web_cowboy                           v  |
                                                                  +------------------------------+
                                                                  | session domain               |
                                                                  | erx_web_line: one view       |
                                                                  |   process per path or trace, |
                                                                  |   through the session's own  |
                                                                  |   inspect and trace facets   |
                                                                  | applications: erx_ui on the  |
                                                                  |   facet named web            |
                                                                  +------------------------------+
```

The **web domain** is a configured domain of the manifest, named `web`.
Its release runs the connection core `erx_web_conn`, one widget server
with the browser renderer per open UI, the display service those servers
answer behind, and the network front end `erx_web_cowboy` where the
manifest gives the domain a network facet; it carries the client's files.
It holds a **login facet** of the system domain's `erx_web_login`, whose
two operations are `login` and `logout`. It holds no inspect, trace,
console or shell facet.

**On the stopgap.** The web domain runs on the stopgap Fiasco as designed:
a configured domain holding its login facet, reached through the host
tool's front end over the host link, and through the network front end
once the network domain gives it a network facet. Nothing in this document
changes there. What the stopgap does not enforce is the wall around the
domain and W8's charge to the principal: budgets are records, so W8's
bounds hold as the web domain's own limits but nothing is charged
([design-domains.md](design-domains.md#on-the-stopgap)).

**A browser is a display.** The display domain owns screens and input
devices and serves windows; the web domain owns browser connections and
serves the same widget service. Both serve `abi/services/display.txt`
through the server dispatch the generator emits from it, behind the
display facets the system domain mints; both run `erx_ui_server` with
`erx_ui_schema`, `erx_ui_model` and the state rule; they differ in the
renderer, as the panel and the desktop do. They are two domains because
they hold different things: the display domain sees local pixels and
keystrokes, passphrases typed at the machine included, and the web domain
parses hostile network bytes, and a domain that parses hostile input
holds nothing else ([Trust placement](design.md#trust-placement)).

**The medium.** A widget tree says that a node is a button labelled
"Stop" that takes `on_click`, that an input holds a text, that a list has
these rows and this selection. It does not say how many pixels the button
is or where the page scrolls. The browser renderer shows each kind as a
web page shows it, a native control in the page's flow, and scrolls,
focuses and selects text as the browser does; the native renderers draw
the same tree for a screen or a panel. What the three agree on is the
tree, the values and the events, and that is what their tests compare.

The **line** is the web domain's connection to one session domain: the
session's process `erx_web_line`, exported to the web domain when the
system domain first introduces the session to it, which opens the views
of paths and traces; and, minted at the same introduction, the session's
**display facet named `web`**, through which the session's applications
open UIs on the web. A session has at most one line, and its line and its
`web` facet end with the session domain, so neither has a lifetime of its
own to track.

A **login** binds a browser to a line. On the network front end a login
starts a session, as a console login does, and binds a cookie to its line;
on the host tool's front end, opening the host link's `web` facet in a
development build introduces `root`'s session, as `erx console` reaches
it, and every connection the tool relays is bound to that line.

A **view** is one thing a connection shows: a record, a log, a trace, a
UI, or the list of the session's open UIs. A connection opens a view with
a target, asks for its updates one at a time and closes it; the client
opens one view per thing on its screen.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **W1.** A browser sees and does exactly what its principal's console session would | every record, log and trace is fetched in the principal's session domain by a view of `erx_web_line` through the session's own facets, and every UI is the session's applications'; the web domain holds no inspect, trace or shell facet and reaches the inspector only through a line; a session's inspect facet covers its principal's own domains, and only `root`'s in a development build has scope `all`, so a browser sees machine-wide records only as `root` in a development build, and in a release build none does, since machine-wide inspection there is the system shell's at a secure line; the login facet offers only `login` and `logout`, so the web domain reaches a session only through a login or, in a development build, the one the host's `web` facet introduced | a facet held by the web domain; a view the web domain answers from its own knowledge; a login facet operation that names a session; a cookie bound to a line other than its login's | a test that logs two principals in through the network front end and finds each browser's views equal to its principal's `/proc` snapshots and `ended scope` for the other's domains; a scoped principal's view of `/proc/kernel/log` answers the status its `erx:i/1` gets; an xref check that the web domain's release calls no inspect, trace or console client |
| **W2.** Text from the machine reaches the DOM only as text, through the line escape | the generated decoder types every machine text as `MachineText`, an opaque class React refuses to render, whose bytes only its line escape reads, in `text.ts`; `Text` is the one function that turns one into nodes, through the generated escape, as text nodes; no handwritten source writes an HTML sink | a decoder field typed `string`; a component that reads `MachineText`'s bytes; a sink such as `innerHTML` | the type check (`tsc --noEmit`) of a seeded component rendering a `MachineText` directly fails; the sink source check and its seeded violation; the escape's differential test against `erx_text:escape_line/1`; the headless test of the attributed-text corpus |
| **W3.** The browser runs only the client's own files | the machine's messages are data of `web.txt`; the client evaluates none of them; the policy allows script only from the front end's origin and no `eval`; the host tool serves the files from the build tree, never from the machine; both front ends write only the headers of the generated table | a message kind that carries markup or a URL to load; a policy with `unsafe-inline` or `unsafe-eval`; the host tool fetching files from the machine | the policy test in the headless browser, where a seeded inline script and a seeded `eval` are blocked; a source check that `Erx::Web` reads files only from the bundle's inventory; header parity between the front ends |
| **W4.** The host tool's server gives authority only to the holder of the token | it binds the loopback address; a request whose `Host` is not the tool's address and port is refused first; the WebSocket upgrade needs the session cookie, set once from the printed URL, and an `Origin` equal to the tool's own; without them a client gets only the bundle's public files | a bind to every address; an upgrade without the cookie or the `Origin` check | each refusal tested, with a seeded server that skips the check answering; a test that the token appears in no response and no log line and that the cookie's value is not the token |
| **W5.** Both front ends carry the same protocol | each front end's job is to authenticate, terminate the WebSocket and hand whole messages to `erx_web_conn`, a pure core both drive; neither reads a message's contents | a front end that answers, filters or caches a message | a differential test: one scripted client through the host tool and through cowboy against the same machine state receives byte-identical message sequences |
| **W6.** Opening a URL changes nothing on the machine | the targets a URL names (a path, a UI, the UI list) are queries; a trace starts only by the `trace` target, which the client opens only from a user's action on the trace page, never from a URL and never on a reconnect; UI events come only from user input | a target that starts or selects something; a client route, or a reconnect, that opens `trace` | a headless test that loads every URL form and reconnects with a trace page open, and finds no trace started and no event delivered, with a seeded route that opens a trace failing it |
| **W7.** Never fabricate | a value whose status is not `ok` carries its status on the wire and shows its token, as `erx_render` prints it; a listing cut at the inspector's page limit is marked partial; a log tail that missed entries shows a gap with its count; a view whose connection is lost shows "stale since" its last update; a view the machine ended shows why | a client that prints a status as a value; a reconnect that shows old data as current | status tests over `unknown`, `timeout` and `partial` values in the browser; a test that stops the guest and finds every view marked stale within the ping interval |
| **W8.** What one browser can make the machine hold or do is bounded and charged to its principal | a view is sent one update per `next`, so the web domain holds at most one update of at most 64 KiB per open view, 16 views per connection; the line's views are processes within its bound; every query runs through the session's facets, within their shares; every UI within the session's display grant on the web | an unbounded table; a view that answers twice for one `next`; a query on the web domain's own account | tests at each bound with the next request refused; a test that a client which never sends `next` receives one update per view while the web domain's memory for it stays under 1 MiB |

## Data model

### The protocol

`abi/protocols/web.txt` declares the messages in both directions as
binary layouts, as `abi/protocols/9p.txt` declares the file protocol: each
message a tag byte and its fields; integers little-endian `u8` to `u32`;
bytes and texts with a `u32` length and a declared maximum; lists with a
declared maximum count; unions by tag. One WebSocket binary message is
one protocol message, of at most 64 KiB in either direction; a text
message is a protocol error.

A union may name itself as the element of a `list` or `tuple` member
when it declares `depth N`, N at most 8, as `datum()` does (below). The
generator validates the type graph without the edges out of such a
union's members, so it stays acyclic and every other rule of the grammar
applies unchanged, and each codec carries the level as an argument: N
levels, the innermost without the members that name the union, so a
container's tag at the innermost level is an unknown tag there, refused
as any other. The bytes of a value are the same at every level.

Every bound of the protocol is a `limit` of `web.txt`, generated into
both codecs and covered by the protocol hash, so a client and a machine
that agree on the hash agree on every bound, and none travels on the
wire:

| Limit | Value | Bounds |
| --- | --- | --- |
| `web_message_max` | 65,536 | one message, either direction |
| `web_ui_op_max` | 65,024 | one `ui.txt` message inside an update: the message less 512 bytes kept for the update's header and the list's count |
| `web_views_max` | 16 | views open at once on a connection |
| `web_path_segments_max`, `web_segment_max` | 16, 256 | a `path` target |
| `web_trace_selection_max` | 16 | a `trace` target's presentations |
| `web_entries_max` | 1,000 | an `entries` body |
| `web_uis_max` | 256 | a `uis` body, and a session's open UIs on the web |
| `web_name_max` | 255 | a principal's name, an `ended` or `bye` reason, a UI's label |
| `web_build_id_max` | 64 | the build identifier |
| `web_int_max`, `web_atom_max`, `web_printed_max` | 40, 255, 4,096 | a `datum()`'s integer digits, atom and printed term |
| `web_list_max`, `web_tuple_max`, `web_datum_depth` | 1,000, 16, 8 | a `datum()`'s list, tuple and nesting |
| `web_ping_ms`, `web_idle_ms` | 30,000, 60,000 | the front end's ping interval, and the silence after which a connection closes |

From the browser:

| Message | Fields | Meaning |
| --- | --- | --- |
| `hello` | protocol hash (32 bytes) | first message; the hash the client was built with; another hash is refused with `bye mismatch` |
| `open` | view (`u32`), target | opens a view and asks for its first update; the view number is the client's and is never reused on the connection |
| `next` | view | asks for the view's next update; the client sends it once it has rendered the last |
| `close` | view | ends a view |
| `event` | view, and one event in `ui.txt`'s binary event form, which names the node, the event and its detail | a widget event on a UI view |

The **protocol hash** is the SHA-256 the generator computes over every
source it generates into the client, `web.txt`, `ui.txt`,
`inspection.txt`, `terminal.txt` and the Unicode data, and writes into
both codecs, so a client and a machine agree on it exactly when they were
generated from the same sources.

Targets:

| Target | Fields | Served by |
| --- | --- | --- |
| `path` | segments (at most 16, each at most 256 bytes) | the line: a record, or a log when the schema marks the path append-only |
| `trace` | selection: at most 16 pid or domain presentations, and flags for their frames and for kernel events | the line: a trace through the session's trace facet |
| `ui` | number (`u32`) | the web domain: attaches to the session's open UI of that number |
| `uis` | none | the web domain: the session's open UIs on the web, by number and label |

From the machine:

| Message | Fields | Meaning |
| --- | --- | --- |
| `welcome` | principal name, build identifier | answers `hello` |
| `update` | view, body | the view's answer to one `open` or `next` |
| `ended` | view, reason (an atom's name, at most 255 bytes) | the view is over; the reason is the `Reason` of the inspector's or the tracer's `{error, Reason}` (`scope`, `no_facet` and the rest [Interfaces](design-live.md#erlang-in-every-domain) lists), or one of the web's own: `closed`, the view or what it shows ended; `busy`, a bound refused it; `too_large`, one record does not fit an update |
| `bye` | reason | the connection is about to close: `mismatch`, `protocol`, `limit`, `logout`, `expired`, `shutdown` |

An update's body is one of: `record`, a record (below); `entries`, a list
of log or trace entries, each a value with its time, and `gap` entries
counting what the view could not read, at most 1,000; `ui`, a list of
`ui.txt`'s binary `diff_op()`s, the last of a change ending with
`commit`; `uis`, a list of open UIs, at most `web_uis_max`, the most
the web domain lets a session open on the web.

### Values

The inspector's `value()` holds any Erlang term; the wire holds a closed
set, so the client never parses Erlang. A view projects every record
before it leaves the session with `erx_web_value:project/1`, a pure
function:

```erlang
-type datum() :: {int, binary()}                 % decimal digits with an optional sign, at most 40 bytes
               | {text, binary()}                % bytes as reported, not required to be UTF-8
               | {atom, binary()}                % at most 255 bytes
               | {present, Type :: binary(), Text :: binary()}  % erx_present:text/2 of the value
               | {list, [datum()]}               % at most 1,000 elements
               | {tuple, [datum()]}              % at most 16 elements
               | {printed, binary()}.            % any other term, as erx_render prints it, at most 4 KiB
%% Nesting is at most 8 deep (web.txt's depth 8): a list or tuple that would need a
%% ninth level is printed.

-type wire_attr() :: {Key :: binary(), reporter(), status(), datum()}.
-type reporter() :: kernel | service | runtime
                  | {stopgap, Name :: binary()}.  % a stopgap reporter of abi/inspection.txt
-type status() :: ok | partial | unknown | unsupported | {timeout, pos_integer()} | error.
-type wire_record() :: #{path := [datum()], kind := binary(), id := datum(),
                         attrs := [wire_attr()],                  % in the schema's order
                         children := {complete | partial | unknown, [datum()]}}.
```

For `partial` the datum is the partial value, for `error` the reason, and
for the other statuses that are not `ok` it is the empty list. A value that
the schema shows as a presentation
([Presentations](design-display.md#presentations)) becomes `present`,
with the text the terminal's link carries; an integer travels as its decimal text and the client reads it
as a `bigint`, so no value is rounded; a text keeps its bytes, invalid
UTF-8 included, for the client's escape to show. A child is its entry
name, which the client shows as a link to the child's path. A record whose
encoding does not fit one update ends its view `too_large`, as `/proc`
marks a record over the same 64 KiB `[partial]`. `project/1` answers
`{error, too_large}` itself once its datums pass the 64 KiB: it charges
each datum its encoded size before projecting what the datum holds, so a
term that shares its cells costs at most one update's work, never the
size of its expansion.

### URLs

```text
/                     the machine's record, and the session's open UIs
/proc/SEG/SEG/...     the view of an inspector path; each segment a /proc entry name in /proc's encoding
/TYPE/TEXT            the view of a presentation; TYPE a type of abi/inspection.txt, TEXT its
                      canonical text in the erx: URI encoding
/ui/N                 the session's open UI N
/trace                the trace page; opening it starts nothing
/login                the network front end's login page
```

These are the client's routes: the front end answers every `GET` that
names no file of the client with the client's `index.html`, and the
client opens the view the URL names. The fixed routes (`/proc`, `/ui`,
`/trace`, `/login` and `/ws`) are matched before `/TYPE/TEXT`, and the
generator refuses an inspection type named `proc`, `ui`, `trace`,
`login` or `ws`, so no presentation URL reads as a fixed route. A path
segment is a `/proc` entry name in `/proc`'s own encoding, in which every
byte outside `A-Z a-z 0-9 _ + , : = @ -`, and a leading `.`, is `%` and
two upper-case hexadecimal digits ([The /proc
tree](design-live.md#the-proc-tree)), so no segment is `.` or `..` or
holds `/`; an empty segment is refused by the client and by the line. A
browser's URL parser reads `%2E` and `%2E%2E` as dot segments, so the
client also refuses a segment that decodes to `.` or `..`, as a path that
names nothing, and never puts one in a URL or a link. A canonical name
writes its percent-encodings in upper case, so a segment with one in lower
case names nothing here either. The machine's own record is at `/`, so
`/proc` with no segment names nothing. A presentation's text is in the `erx:` URI encoding, which keeps `.` and `/`
as well ([Presentations](design-display.md#presentations)), so the
`erx:TYPE/TEXT` link a terminal shows and the `/TYPE/TEXT` link a browser
shows are the same text after the scheme. The client resolves a
presentation itself: the inspection schema's `present` marks are
generated into the client as into `erx_present`, a presentation's text
is the variable segments of its marked path, and the client opens a
`path` view of that path with the text's segments in place while the
address keeps the presentation's URL. A text that names
nothing is a path that names nothing, answered `scope`, as `/proc`
answers `enoent`. The client's only other HTTP paths are `/ws`, the
WebSocket, and, on the network front end, `POST /login` and
`POST /logout`.

## Algorithms and behavior

### The connection core

`erx_web_conn` is a pure state machine, one per browser connection:

```erlang
-spec step(Input, State) -> {[Action], State}.
%% Input:  {in, Bytes} | {text, Bytes} | {opened, View, Pid} | {update, View, Body}
%%       | {ended, View, Reason} | tick
%% Action: {send, Bytes} | {close, Reason} | {open, View, Target} | {next, Pid}
%%       | {stop, Pid} | {event, Pid, Record}
```

`{in, Bytes}` and `{text, Bytes}` are a binary and a text WebSocket
message; `{opened, View, Pid}` reports the process `perform/2` started for
an `open`; `tick` reports that `web_idle_ms` passed with no frame from the
browser. An `event` action carries the event's `ui.txt` record as the
browser sent it, for the renderer to decode ([UIs: the browser
renderer](#uis-the-browser-renderer)).

A front end owns the process that drives it: cowboy's WebSocket handler
calls `step/2` from its callbacks; for the host link, the web domain runs
one process per relayed connection that does the same. Both perform the
actions with one function, `erx_web_conn:perform/2`, which sends `open`
for a `path` or `trace` target to the line, for a `ui` target to the UI's
renderer and for `uis` to the line's table of UIs in the web domain, so
the front ends differ in how bytes arrive and leave and in nothing else
(W5).

`step/2`:

1. **decodes** an incoming message with the generated `erx_web_proto`,
   which refuses one over 64 KiB, of an unknown tag or outside its
   bounds; a refused message, a text message or anything before `hello`
   closes the connection with `bye protocol` and is counted;
2. **opens and closes views**: at most 16 open at once per connection, a
   17th `ended busy`, which uses its number; view numbers only grow, so an
   `open` of a number not above every number the connection opened before
   is a protocol error, which keeps every number from being reused
   without the core remembering each; so are a `next` while the view's
   last request, its `open` or its last `next`, is unanswered, a `next`,
   `close` or `event` for a number above every one opened, and an `event`
   for a view that is not a UI; a `next`, `close` or `event` for a view no
   longer open is dropped, since the view's `ended` may be on its way; a
   view closed before its process is reported stays among the 16 until
   the process arrives and is stopped;
3. **pulls**: `open` asks a view for its first update and each `next`
   for one more; the view answers when it has something new, and the core
   sends the answer as one `update`; an answer no request is waiting for
   is dropped, and one the codec refuses as too long ends the view
   `too_large`;
4. **forwards events** of a UI view to its renderer.

So the web domain holds at most one update for each open view, 16 times
64 KiB, 1 MiB for a connection, whatever its views produce, and a browser
that stops asking stops receiving. A view is never asked twice before it
answers, so a source that changes faster than the browser reads is
sampled, never queued. View numbers are never reused on a connection, so
an `ended` always names the view it ended; a connection that reaches the
last `u32` closes with `bye limit` before it wraps.

A connection that sends nothing for 60 s, pings included, is closed; the
front end pings every 30 s, and the browser answers pings by itself. The
front end then feeds the core `tick`, which stops the connection's views
and closes it without a `bye`, since nothing is listening.

### Views on the line

`erx_web_line`, in every session domain's release, is a supervisor of
the session's views and nothing else: `{open, Target}` from the web
domain starts a view process under it and answers `{ok, View}`, the view's
pid, exported to the web domain with the reply, or `{error, busy}` past
64 views. A view's crash ends that view alone, which the web domain sees
through its monitor and reports as `ended closed`; the line is a
significant child of the session's release, so the line and the session
domain end together. A view is one process with one query or one trace at
a time, so the line's inspector queries in flight are at most its open
views.

* **A record view** (`path`). On `next`, the view queries
  `erx:inspect(Path, #{})` through the session's inspect facet, so scope,
  deadlines and page limits are the inspector's, and a path outside the
  scope is `ended scope` exactly as `/proc` shows `enoent` (W1). It
  projects the record and answers when the projection differs from the
  last one it sent; otherwise it queries again after 2 s. The first
  request always answers.
* **A log view** is a record view of a path the inspection schema marks
  append-only, `[kernel, log]`. Its first update holds the newest entries
  that fit one update; each later one the entries after the last it sent,
  at most 1,000 and within the 64 KiB, and the rest follow at the next
  `next`. When the kernel's ring overwrote entries between two reads, the
  update starts with a `gap` entry counting them (W7).
* **A trace view** starts a trace through the session's trace facet, as
  `erx:trace/1` does, with a specification built from the selection, and
  takes the merged stream the facet sends the process that started it,
  which at a shell is the printer; records arrive in the merger's order,
  `late` marks included, and are kept up to 1,000; more are dropped and
  counted, and the next update starts with a `gap` entry. Kernel events
  under a trace facet of a scope other than `all` are `ended scope`, as
  the facet refuses them. Closing the view, or the connection, stops the
  trace, and the facet ends a trace whose receiver ends, so a view that
  crashes leaves none behind. A session without a trace facet gets
  `ended no_facet`.

The line's views answer the web domain with Erlang terms of the
protocol's types; the web domain's funnel admits them by their grammar,
and `erx_web_conn` encodes them. Every query runs on the session's own
facets within their shares, so the inspector's cost of a browser is the
principal's, as at a console (W8).

`/proc/kernel/log` and `/proc/kernel/crash` are paths like any other,
under the inspector's rules
([design-live.md](design-live.md#paths)): every `[kernel, ...]` path
answers only an inspect facet of scope `all`, and `[kernel, crash]`, the
machine's crash record, only a call that presents the system-shell
facet, which no session and so no browser holds. A domain's own crash
dump, `/proc/domains/N/crash`, answers a facet whose scope covers that
domain. The kernel's trace ring is read only by a trace view,
never as a path, since only a tracer drains it.

### UIs: the browser renderer

A session's application calls `erx_ui:open(Options)`, `erx_ui:tree/2`
and `erx_ui:close/1` exactly as for a window; with `display => web` in
`Options`, or with `web` as the session's default display, the UI opens
on the web ([Choosing a display](design-display.md#choosing-a-display)).
On `open_ui` through the session's `web` facet the web domain starts
`erx_ui_server`, the display's widget server, against the grant's
`windows` quota and at most `web_uis_max` open UIs of the session, with
`erx_ui_browser` as its renderer, and replies `{ok, Window}`. The UI's number, its `/ui/N`, counts the session's UIs on
the web and is never reused; its `label`, the same option that is a
window's title on a display, names it in the `uis` list.

`ui_tree` runs as in the display: validate the whole tree with
`erx_ui_schema`, number it with `erx_ui_model:pair/3`, which keeps the
values the tree does not set under the node's identity, and hand the
renderer the operations of `erx_ui_model:delta/2`. Validation and the diff run inside the request, on the
grantee's share; the tree is bounded by the grant's `ui_nodes` and
`max_request` ([The widget server](design-display.md#the-widget-server)).

The operations travel in `ui.txt`'s binary form, written by the generated
encoder in the web domain. That form carries an `on_*` property as the
flag that the node takes the event, never the application's term, and a
`present` property as its type, its canonical text from
`erx_present:text/2` and its status, so the application's terms stay in
the widget server and the browser parses no Erlang.

`erx_ui_browser` is a process per open UI, linked to its server; the
behaviour's `start/3` receives the renderer target `{web, N}`, the UI's
entry in the web domain's table of open UIs, where a window's renderer
receives its window's directory. It keeps two models of the realised
tree, both keyed by the server's node numbers: **sent**, what the
attached browser has, and **pending**, what the server has applied. The
renderer's `apply/2` callback hands it the operations, which it applies
to pending and nothing else. A connection attaches with a `ui` view;
attaching sets sent to the empty tree, and a second attachment replaces
the first, whose view ends `closed`. On a request from the attached view,
when sent and pending differ, it answers with the first operations of
`erx_ui_model:delta(Sent, Pending)`, the display's one difference, whose
operations turn sent into pending
([Widget trees](design-display.md#widget-trees)), as many as fit one update, ending with `commit`
when they are the last, and applies what it sent to sent. A long change
thus reaches the browser over several updates, which the client keeps
and applies at `commit`; no operation of a valid tree exceeds one
update, since `ui.txt` bounds an image's bytes. So a reload, a reconnect and a
new tab are one case, attach, and a browser that falls behind receives
the newest tree's difference, never a backlog.

**Rendering for the browser.** The client renders each kind as a web
page renders it: containers as flex and grid boxes in the page's flow,
whose `width`, `height`, `weight`, `pad` and `align` it reads as hints
for its CSS, never as pixels to reproduce; `scroll` as the browser's own
scrolling; `label` as `Text`; `button`, `checkbox`, `slider`, `input` and
`list` as the browser's controls; `image` as a `blob:` URL of its bytes.
Scroll position, focus, an input's cursor and text selection are the
browser's, kept in the page and never sent to the machine; a UI looks
like a web page, not like the window the same tree makes on a display,
and two browsers may lay it out differently.

The browser sends `event` messages in `ui.txt`'s binary event form; the
renderer process decodes each with the generated Erlang reader, passes it
through `erx_ui_model:hit/4` against pending, which drops a report for a
node that is gone or a value outside the node's bounds and records the
state value (an `input`'s text, a `checkbox`'s state, a `slider`'s value,
a `list`'s selection) into pending, so a tab that attaches later shows
it, records it into sent as well, since the browser shows it already, and
sends the server `{ui_hit, Node, Event, Value}` as the behaviour defines. The
server fires only the events the tree declares and keeps the values as
the display's does, so a browser makes an application receive only what
it asked for (G4 of the display). An event for a node that is gone is
dropped and counted.

An `input` with `secret => true` shows its text as marks, in the browser
as a password input. Its text is never kept: not in pending, so a new
attachment shows it empty, and not in the server's state. It reaches the
application as `{erx_secret, Text}` in the event's detail, which
`erx_render`, the trace relay and the logger's formatter print as
`[secret]` ([Attributed text](design-live.md#attributed-text)); the web
domain's processes that hold message bytes drop them from crash reports
with `format_status/1`.

A UI ends with `close_ui`, with the session's end, or when its opener
exits; its views end `closed` and it leaves the `uis` list. A browser that
closes ends no UI: the UI stays with its application, as a window stays
when nobody looks at it, and the next attachment shows its newest tree.
When the web domain itself ends, each opener receives `{ui_down, Window,
display_down}` from its `web` facet, as from any display that goes away.

### Logging in and the line

`erx_web_login`, a facet of the system domain held by the web domain,
offers `login(Name, Passphrase) -> {ok, Line} | {error, Reason}` and
`logout(Line)`, and nothing else. `login` hands the name and passphrase
to the principal service, which the vault checks with the console's
limits, 5 failures in 60 s from network connections limiting a name, and
its four answers ([The console](design-live.md#the-console)); a principal
that has not enrolled gets `no_match`, the same answer as a wrong
passphrase, since enrolment is at the UART only. On a match the domain
service starts a session for the principal, as a console login does; the
session's environment sets `display` to `web`; and the system domain
introduces the session to the web domain, exporting its `erx_web_line`
and minting its `web` display facet, and the reply names the line.
`logout(Line)` ends a session that a login through this facet started, as
a console's log-out ends the sessions started there, and is refused for
any other line; the session's end ends its line, its `web` facet and its
applications' UIs. When the web domain ends, its login facet ends with
it, and the sessions its logins started end as at a log-out. The web
domain never stores a passphrase.

The host link's `web` facet is the other way in. On its opening in a
development build, the system domain introduces `root`'s session to the
web domain, as the host link's `console` reaches it, unless it is already;
the session's environment is unchanged, so an application of `root`'s
opens on the web when it names `web` or when the user sets `display` to
it. Closing the facet closes its connections and leaves the line, the
`web` facet and their UIs with the session.

### The client

The client is TypeScript with React, under `web/` at the tree's root,
built by esbuild into `build/web/`: one `index.html`, one script and one
stylesheet with content hashes in their names, the third-party licence
notices, and an inventory of the files with their SHA-256,
`inventory.txt`, one line per file in `sha256sum`'s format (the hash in
hexadecimal, two spaces, the path). Every file but `index.html` is named
by its content hash, so the front ends serve it as immutable; the kinds
are `.html`, `.js`, `.css` and `.txt`, and a front end refuses to start
on a file of another kind, a path with a segment that is empty, hidden,
`.` or `..`, or a file whose hash is not the inventory's. Its parts:

* **`generated/`**: the protocol's types, decoder, encoder and hash from
  `web.txt`; the reader and writer of `ui.txt`'s binary form and its
  kinds, properties and events; the inspection schema's kinds, attribute
  names, units, presentation types and the table from a presentation's
  text to its inspector path, from `abi/inspection.txt`; and the line escape's table
  from `abi/terminal.txt` and OTP's Unicode data, from the same generator
  run that writes `erx_text_tables`.
* **`text.ts`**: `MachineText`, the opaque class the decoder gives every
  machine text in, holding its bytes in a JavaScript private field whose
  one outlet, `runs()`, is the text's line escape, so no other code can
  read the bytes; and `escapeLine`, which decodes the bytes strictly as
  UTF-8 by its own table, never with `TextDecoder`, and returns runs of
  plain text and escape tokens by the generated table, as
  `erx_text:escape_line/1` does, tab and newline included. Invalid bytes
  are tokens, never U+FFFD.
* **`text.tsx`**: `Text`, the one component that renders a `MachineText`:
  its plain runs as text nodes, tokens in a styled span, the whole in an
  element with `unicode-bidi: isolate`, so a right-to-left run reorders
  only within its own text.
* **`names.ts`**: the percent encodings of `/proc` entry names, as
  `erx_procfs_core:name/1` writes a text segment, and of `erx:` texts.
  They are two fixed sets of kept bytes, written by hand like their
  Erlang twin and tested against it, since no source declares them;
  and the path a presentation's text names, from the `present` marks
  generated as `web/src/generated/present.ts`.
* **`connection.ts`**: the WebSocket to `/ws`, `hello`, a `next` for a
  view once its last update is rendered (for a UI, once an update without
  `commit` is kept), and reconnection after 1 s, doubling to 30 s. On a
  loss every view shows "stale since" the time of its last update until a
  new update replaces it; a reconnect reopens every view but `trace`,
  whose page shows the trace stopped (W6).
* **Views**: the record view, a table of attributes with name, value,
  unit and reporter, values whose status is not `ok` as their tokens, and
  children as links; the log and trace views, virtual lists of entries
  with gaps shown; the home page; the trace page, whose start button opens
  the `trace` view; the login page.
* **The UI renderer**: applies each `ui` update's operations to its model
  of the tree on `commit` and renders the model with React, keyed by node
  number, for the browser as [Rendering for the
  browser](#uis-the-browser-renderer) says, with styles set through
  React's style objects; `image` with the content type `ui.txt` declares,
  from a table that has no `image/svg+xml`, so an image is never a
  document. It sends an `event` for each event a node declares
  and for each change of a node's state, declared or not, so the machine
  keeps what the page shows, coalescing an `input`'s or a `slider`'s
  changes to one per animation frame, and sends nothing for scrolling,
  focus or text selection.
* **`routes.ts`**: `parseRoute`, which reads a URL's path into a `Route`,
  and `hrefOf/1`, the one function that writes an `href`, from a `Route`.
  A `Route` is checked when it is made, by `parseRoute` or from names the
  machine sent, and cannot be made otherwise: its constructor takes a token
  private to the module, and its value is an instance private field, so
  `Route` is a nominal type and `hrefOf` refuses any other object. So every
  link `hrefOf` writes is a path `parseRoute` reads back to the same route,
  and each route has one URL. A presentation's link writes its canonical
  text in the `erx:` URI encoding, as `erx_present:uri/2` does. A name the
  machine sent is read through its line escape, which is the name itself
  when the bytes are a canonical `/proc` entry name, since the escape keeps
  every printable ASCII character. A name with an escape token holds `<`,
  which no name holds, so it makes no route.
* **Links**: a presentation is always a link to `/TYPE/TEXT`, and a plain
  click on one in a UI whose node declares `on_select` sends the event
  instead of following it.

The client keeps no state that needs the machine's trust: a view's data
is what the last update said, and closing a tab discards it.

### The host tool's front end

`tools/erx web --socket PATH [--build HEX] [--port N] [--open]`, on the
host link at `PATH` as `files` and `load` are, starts an HTTP server on the
loopback address, on any free port unless `--port` names one, opens the
host link's `web` facet with `{open, web}` on the root, and prints the one
URL a browser may use,
`http://127.0.0.1:PORT/?token=HEX`, with `HEX` 16 bytes from the host's
random source; `--open` hands the URL to the host's opener. A machine that
offers no `web` facet stops the start with its answer. A client of
another build is refused by the machine at `hello`. The server is
`Erx::Web`, the Ruby standard library alone (`socket`, `digest`,
`securerandom`), with a reader of its own:

* **HTTP.** HTTP/1.1, `GET` alone, a request line of at most 8 KiB and
  headers of at most 32 KiB, each request read within 10 s, one request
  per connection with `Connection: close`, so there is no pipelining, no
  body and no chunked encoding. A `GET` answers a file of the bundle's
  inventory, looked up by its exact path, or `index.html` for any other
  path; the URL never names a file on the host. Anything else is 400, 405
  or 414 with a one-line text body. At most 16 connections are served at
  once, WebSockets included.
* **Authentication** (W4). The `Host` header must equal the tool's own
  address and port, or the request is 400 before anything else is read.
  A request whose query carries the printed token answers 303 to the same
  path without the query and sets `erx_web_PORT=COOKIE; HttpOnly;
  SameSite=Strict; Path=/`, named after the port so that two front ends on
  one host keep their own, with `COOKIE` another 16 random bytes made
  at the start, so the token itself is in no response. The files need no
  cookie, since they are the same for everyone; the upgrade at `/ws`
  needs the cookie and an `Origin` equal to `http://127.0.0.1:PORT`, or is
  403. Both secrets are compared in constant time, appear in no log line,
  and are made again at each start.
* **WebSocket.** The upgrade follows RFC 6455 with no extension and no
  subprotocol, so no compression is ever negotiated. After the upgrade the
  request's 10 s deadline no longer applies; the ping rule of the
  connection core does. The deframer accepts masked frames from the
  browser, binary and continuation frames up to a message of 64 KiB,
  refusing a declared length past the bound before reading it, and
  control frames of at most 125 bytes; anything else closes the
  connection with the RFC's status code. At most four WebSocket
  connections are open.
* **Relaying.** Each connection is a number on the `web` facet: the tool
  calls `{connect, C}`, then `{data, C, Bytes}` for each whole message,
  each within the host link's call window, and `{close, C}`; the machine
  sends `{web, C, Bytes}` and `{web_closed, C, Reason}` as casts on the
  control stream, which carries every call, reply and cast and
  reassembles a message of up to 64 KiB from its frames within the
  session's resident limit ([Host link frames](design-live.md#host-link-frames)),
  and the tool writes each `Bytes` as one binary frame. The tool reads
  none of the protocol's messages. `{connect, C}` comes before the
  upgrade's answer, so a browser that gets 101 has a connection on the
  machine; a connect the machine refuses, a fifth WebSocket and a host
  link that is down are 503. A call answered other than `ok` closes its
  WebSocket with 1011, as do `Bytes` over 64 KiB and more than 2 MiB
  waiting for one browser, twice what the connection core can have in
  flight for it; `web_closed` closes it with 1000. While the host link is
  retrying or reset, the tool closes every WebSocket with status 1011, and
  the client marks its views stale and reconnects; the next upgrade opens
  a session and the facet again.
* **The `web` facet** is a facet of the system domain, offered by the
  host link's root in development builds alone, like `inspect` and
  `trace`; a release manifest that lists it for the host fails the
  manifest check. On its opening the system domain introduces `root`'s
  session to the web domain, as [Logging in](#logging-in-and-the-line)
  says; each `connect` starts a connection process in the web domain
  bound to that line, and `data` hands it the bytes. The system domain
  relays bytes and decodes no protocol message.

The browser never speaks to the machine, the machine never sees HTTP, a
header, a cookie or the token, and the host link's trust assumptions stand
as written: one trusted local peer on an owner-only socket ([The host
link](design-live.md#the-host-link)).

### The network front end

`erx_web_cowboy` starts cowboy in the web domain on the network facet the
manifest gives it, over OTP's `ssl` with the certificate and key the
manifest names; plain HTTP is allowed only where a development build's
manifest lists it, and a release manifest that lists it fails the
manifest check. cowboy's limits are small: a request line and headers
within 32 KiB, a login body of at most 4 KiB, 64 connections (ranch's
`max_connections`), a request timeout of 10 s, HTTP/1.1, WebSocket
messages of at most 64 KiB (`max_frame_size`) and no compression.

* **Files.** A `GET` answers a file of the inventory, from the web
  domain's release, or `index.html`, with the same headers as the host
  tool's, from the generated table.
* **Login.** `POST /login` with a form body of `name` and `passphrase`,
  read with `cow_qs`, whose `Origin` is the server's own and whose
  `Sec-Fetch-Site`, when present, is `same-origin`, calls the login
  facet. On `{ok, Line}` the handler binds a fresh cookie to the line,
  sets `__Host-erx_web=HEX; HttpOnly; Secure; SameSite=Strict; Path=/;
  Max-Age=43200` with 16 fresh random bytes, and answers 204; otherwise
  403 with the vault's answer as one of `no_match`, `limited` and
  `unavailable`, which the client words. At most 16 logins are live; the
  17th is 503. A login ends 30 minutes after its last connection closes,
  12 hours after it began, or at `POST /logout`; each calls the login
  facet's `logout`, and its connections receive `bye expired` or
  `bye logout`. A login's line has at most four connections.
* **The upgrade** at `/ws` needs a live cookie and an `Origin` equal to
  the server's own; the handler then drives `erx_web_conn` for the
  cookie's line.
* **What cowboy parses** is hostile. Every connection is a process of the
  web domain, so a malformed request crashes at most that process; what
  the web domain holds of another domain is its lines and the display
  services it answers, whose requests are admitted by each session's own
  bounds. cowboy, cowlib and ranch are fetched unmodified and carry no
  fuzz target of erXos's: their parsers rest on their own tests, and what
  reaches erXos's code from them is whole messages, which
  `erx_web_proto` bounds and has its own fuzz target.

## Interfaces

**`abi/protocols/web.txt`**: the messages, targets, update bodies,
`datum()` and their bounds; the connection's limits; the fixed response
headers and the content type of each file kind. The generator emits
`erx_web_proto` (Erlang encoder, decoder, grammar and the protocol hash),
`web/src/generated/proto.ts` (TypeScript types, decoder, encoder and the
hash), and the header table for Erlang and Ruby.

**`abi/formats/ui.txt`**: the display's kinds, properties, events and the
binary form of `diff_op()` and events, and the content types an `image`
may carry; the generator emits a reader and a writer of both directions
in TypeScript, as in Erlang and C.

**`abi/services/display.txt`**: served by the web domain as by a display
domain. **`abi/services/web.txt`**: `erx_web_login`'s `login` and
`logout`, and the host link's `web` facet's `connect`, `data` and
`close`.

**`abi/inspection.txt`**: the `present` marks of its paths, the
append-only mark and the stopgap reporters' labels and scopes, generated
into TypeScript as into Erlang; the decoder refuses a stopgap reporter
the table does not name.

**Erlang**: `erx_web_conn:step/2` and `perform/2`;
`erx_web_value:project/1`; `erx_ui_model`'s `delta/2` and `hit/4`; the
`erx_ui_renderer` behaviour, implemented by `erx_ui_browser`;
`erx_ui:open/1`, `tree/2` and `close/1` of the display.

**The client**: the files of `build/web/` and their inventory; the routes
above.

**The host tool**: `tools/erx web --socket PATH [--build HEX] [--port N]
[--open]`, exit codes as
every command's ([The host tool](design-live.md#the-host-tool)).

**Interaction with other subsystems.** `erx_web_login` checks logins
through the principal service and the vault and starts sessions through
the domain service ([The console](design-live.md#the-console)); the
inspector and tracing answer the line's views through the session's
facets ([Inspection](design-live.md#inspection),
[Tracing](design-live.md#tracing)); `erx_present` and the inspection
schema name a presentation's path
([Presentations](design-display.md#presentations)); the display's widget
server, schema, diff and state rule serve UIs, and its display facets and
default display choose where a UI opens
([The widget server](design-display.md#the-widget-server)); the network
service gives the web domain its network facet
([Networking](design.md#networking)); the manifest check refuses the
web's development paths in release builds
([The manifest](design-system.md#the-manifest)).

## Compatibility and migration

The host tool's front end and the network front end are both the target
design. Adding the network front end adds cowboy, its handler and the
login to the web domain and changes nothing in `erx_web_conn`, the line,
the client or the host tool; W5's differential test is the check. The
protocol, the routes and the client are erXos's own; a change replaces
them, and the protocol hash in `hello` refuses a client of another build.

## Failure handling, diagnostics and debuggability

| Failure | Detected by | Effect | Recovery |
| --- | --- | --- | --- |
| the inspector does not answer within its deadline | `erx:inspect` returns `{timeout, 500}` values | those attributes show `[timeout 500]` (W7) | the view's next query asks again |
| a view does not answer within the inspector's deadline plus 500 ms | the connection core's timer | the view shows stale since its last update; the request stays outstanding | the view's answer clears it |
| a view process crashes | the web domain's monitor of it | that view ends `closed`, counted; other views run on | the client reopens it |
| the session domain ends | the line's exit, which the web domain monitors | every view of the line ends `closed`; its connections receive `bye expired`; its cookie is dropped; its UIs on the web end with the session's applications | the user logs in again; on the host the next opening of `web` introduces `root`'s session again |
| an application exits | the widget server monitors its opener | the UI's views end `closed`; it leaves `uis` | none needed |
| a tree fails validation | `erx_ui_schema` | `ui_tree` answers `{error, Reason}`; the UI keeps its tree | the application's bug, logged with the reason |
| an `erx_ui_browser` crashes | its link to the server | the server and its UI end, the opener receives `{ui_down, Window, Reason}` | the application's own supervisor |
| a connection process or cowboy crashes | the web domain's supervisor | the browser's WebSocket closes; its views go stale | the client reconnects and reopens its views but `trace`; lines and logins live under a separate supervisor and keep their cookies and UIs |
| the host link is busy, retrying or down | the host tool's calls fail or time out | every WebSocket closes with 1011; views go stale | the tool's session recovers as [the host link](design-live.md#the-host-link) describes; the client reconnects |
| the web domain ends | the system domain | every opener of a UI on the web receives `{ui_down, Window, display_down}`; the login facet ends and the sessions its logins started end; `root`'s session runs on | the domain restarts under its manifest policy; browsers log in again; the host tool reopens `web` |
| a protocol error from the browser | `erx_web_proto` or the core's view rules | `bye protocol`, the connection closes, counted | the client reloads |

Every refusal and every count (protocol errors, dropped events, busy
views, crashed views, refused logins, gaps) is a counter in the web
domain's inspector record, under `[domains, Web, web]`, visible in its
own view; no counter or log line carries a message's contents.

## Security

* **Authority** (W1). The web domain holds its network facet, the login
  facet, its lines and the display services behind the session's `web`
  facets; no inspect, trace, console or shell facet. The login facet's
  two operations name no session, so the web domain reaches a session only
  through a login or, in a development build while the host's `web` facet
  is open, `root`'s. Views are fetched in the principal's session with
  that session's facets, so the inspector's scope rules and the trace
  facet's scope apply unchanged: the kernel log answers only a session
  whose inspect facet has scope `all`, as at its console, which is
  `root`'s in a development build and no session's in a release build, and the
  machine's crash record, which only the system shell reads, never
  reaches a browser, since no session holds the system-shell facet. A presentation link grants nothing: the client
  turns it into a path, answered through the session's facet.
* **The machine toward the browser** (W2, W3). The machine sends data of a
  closed grammar. Every text in it is `MachineText` and reaches the DOM as
  text nodes through the line escape; no message carries markup, a style,
  a URL to load or code; the client writes `href`s only from route
  values and image sources only as `blob:` URLs of bytes with a content
  type from `ui.txt`'s table, which has no SVG. The response headers,
  fixed for every file, are `Content-Security-Policy: default-src 'none';
  script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src
  'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none';
  require-trusted-types-for 'script'; trusted-types 'none'`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`,
  `Cross-Origin-Opener-Policy: same-origin`,
  `Cross-Origin-Resource-Policy: same-origin`, and `Cache-Control:
  no-store` for `index.html`, `immutable` for the hashed files. React
  sets styles through the style object, which the policy permits without
  `unsafe-inline`; where the browser enforces Trusted Types, every HTML
  sink throws, and elsewhere the sink check is the guarantee. A
  compromised machine can show false data, within text, and nothing more,
  as a compromised display domain can show a false screen.
* **Where the client's code comes from.** The host tool serves the files
  from the developer's build tree, so the developer's browser never runs
  code the machine supplied. The network front end serves them from the
  web domain's release: a compromised web domain can serve script to
  network browsers, as any compromised web server can; the release's
  files are in the boot image and its hash.
* **The host tool's server** (W4) is reachable by every page the
  developer's browser visits and by every user of the host. Loopback
  binding keeps it off the network; the `Host` check defeats DNS
  rebinding; the `Origin` check and `SameSite=Strict` refuse a
  cross-site WebSocket; the cookie keeps out pages without the token; the files it serves without the cookie are public.
  A cookie names a host and not a port, so the browser also sends it to
  every other server on `127.0.0.1`: another user of the host who runs a
  server on another loopback port, and gets the developer's browser to
  request it, reads the cookie and has the developer's authority on the
  machine until the tool stops.
  A page that learns the token, by reading the developer's terminal, has
  the developer's authority on the machine: the same as reading the host
  link's socket.
* **The browser toward the machine.** A message is at most 64 KiB, checked
  by the generated grammar before any code reads it; a connection has at
  most 16 views, each answered once per `next`; a line at most four
  connections and 64 views; a trace runs on the session's trace facet; a
  UI within the session's display grant. On the network, cowboy parses
  hostile HTTP and WebSocket frames in the web domain, a domain of its
  own; as a domain that parses hostile input, a release manifest that
  gives it an unconfined DMA device fails the manifest check ([The
  manifest](design-system.md#the-manifest)). Logins are bounded by the
  vault's limits, and every login's session is charged to its principal's
  budget and domain quota; cookies are 128 random bits, never reused,
  `HttpOnly`, `Secure` and `SameSite=Strict` with the `__Host-` prefix,
  and expire.
* **Secrets.** A `secret` input's text is never kept by the web domain,
  never in a renderer's model, never in a counter, a log line or a crash
  report, and reaches the application wrapped so that every printer
  shows `[secret]`. The web domain sees it in transit, as the display
  domain sees keystrokes.
* **What the web domain is trusted with.** It sees every view it relays
  and every event a browser sends, and it acts for every principal logged
  in through it: a compromised web domain can open any view those
  sessions' facets allow, start and stop their traces, and send events
  into their applications' UIs, typing into inputs included, as a
  compromised display domain can record keystrokes and inject input. The
  people who log in through it trust it with that, and with nothing of a
  principal that is not logged in. In a development build, while the
  host's `web` facet is open, that includes `root`'s session; release
  builds have no such facet. UI numbers reveal how many UIs a session
  opened on the web. The host tool's server reveals, to a local page that
  probes the port, that something answers there.
* **Residuals.** A UI can show a convincing copy of another; the
  browser's address bar names the route. Implicit bidirectional
  reordering within one text is not escaped, as in design-live, though
  each text is isolated from its neighbours. A compromised machine
  chooses what every view says, within text. The host link's trust bound
  is unchanged. Availability is not promised: a local process can hold
  the host tool's 16 connections, unauthenticated peers can hold cowboy's
  64, and one principal's logins can take all 16 live logins for up to 12
  hours; each costs only the web domain's own budget and the principal's
  own, and the bounds keep the rest of the machine out of reach.

## Verification and testing

The client's tests run on the host with Node's test runner (`node
--test`, with TypeScript's erasable syntax only, so Node runs the sources
without a build) for the pure modules, and Playwright for the browser
tests, in Chromium, with the machine's side played by Playwright's
WebSocket routing and the generated encoder; the end-to-end tests run
`tools/erx web` against a QEMU guest.

| Test | Passing case | Seeded failure |
| --- | --- | --- |
| protocol round trip, both languages | random messages of every kind encode in Erlang and decode in TypeScript, and the reverse, re-encoding to identical bytes; both codecs carry the same hash | a generator change that orders one union's tags differently in TypeScript fails; a hash computed over one source fewer fails |
| `erx_web_proto` fuzz target (Erlang) | random and mutated messages; every accepted one is within the bounds | the decoder with the path-segment bound removed accepts a 17-segment `path` target and fails |
| `datum()` depth | a term nested 9 deep projects with its ninth level printed and round-trips in both languages; hand-built bytes with a list at the eighth level are refused by both decoders | a generator that expands `datum` to nine levels makes both decoders accept those bytes and fails |
| bounds bind both ends | each limit of `web.txt` at its bound is accepted by both codecs and one past it refused by both | a TypeScript codec generated with one limit raised accepts the message past it and fails |
| TypeScript decoder fuzz target | a mutation fuzzer under Node over the generated corpus; no exception escapes but the decoder's typed refusal | the decoder without a list's count check fails on an `entries` list of 1,001 |
| `ui.txt` readers: fuzz targets and parity | mutated event payloads into the generated Erlang event reader, which refuses or decodes within bounds; the C reader and the TypeScript reader accept the same inputs and decode the same operations | an Erlang reader without a detail length check fails; a reader with two property tags swapped fails parity |
| escape differential and fuzz target | `escapeLine` agrees with `erx_text:escape_line/1` and the Ruby twin over the attributed-text corpus and random bytes; invalid bytes are tokens | a decoder using `TextDecoder` with replacement fails on `0xC0` |
| encodings and presentation paths | the client's `/proc` and `erx:` encoders and its presentation path table agree with `erx_procfs`'s and `erx_present`'s over the generated corpus of names and values | a client encoder that keeps `.` in a `/proc` segment fails |
| routes and links | each URL form names its route and is written back as itself; a path with an empty, dot or lower-case segment, or past a bound, names nothing; the router's fuzz target (Node) finds that `parseRoute` never throws, that every route it returns is written back as the same path, and that every link `hrefOf` writes, from a browser's path or from the machine's names, is one a browser's URL parser leaves unchanged and `parseRoute` reads back to the same route | a router without the dot-segment check fails on `/domain/..`; one that keeps a leading zero in a UI number fails on `/ui/00` |
| W2 in the browser | the attributed-text corpus (`<script>`, `&`, U+202E, U+200B, a C1 control, an invalid byte) as attribute values, labels and log lines renders as text and tokens, with no element created | a `Text` that sets `innerHTML` fails; Trusted Types throws in Chromium |
| W2 types | `tsc --noEmit` passes | a seeded component rendering a `MachineText` directly fails to type-check |
| W3 policy | the headers on every file; the client works under them | a seeded inline script and a seeded `eval` are blocked and reported |
| host tool HTTP and WebSocket fuzz target (Ruby) | random and mutated requests and frames; no exception escapes; every answer is a file, a refusal or a relay | a deframer without the length check before reading fails on a declared 2^40-byte frame |
| W4 refusals | no cookie, wrong `Host`, foreign `Origin`, wrong token, a path outside the inventory: each refused or answered with `index.html`; the token in no response; a WebSocket open past 10 s | the server with that check removed upgrades or answers a host file; a server that sets the token as the cookie fails |
| W5 parity | a scripted client through the host tool and through cowboy receives byte-identical messages | a front end that answers `hello` itself fails |
| W1 over the host link | in a development build, every view `tools/erx web` opens through the host link's `web` facet (records, `/proc`, a trace, the kernel log, which both answer alike, and the machine's crash record, which both refuse) equals what `root`'s session reads through its own facets at the same moment, compared view by view against the same reads made from that session's console line; a view of a domain `root`'s session cannot see is `ended scope` in both | a `web` facet bound to the system domain's authority instead of `root`'s session shows a record the session cannot read and fails |
| W1 scope | two principals through the network front end, each view equal to its principal's `/proc` snapshot, the other's domains `ended scope`; a scoped principal's kernel-events trace `ended scope`; a `logout` of another login's line refused | a cookie bound to the wrong line fails |
| logins | two logins of one principal are two sessions, and a logout of one leaves the other's views and UIs running; an unenrolled name answers `no_match` | a logout that ends every session of the principal fails |
| W6 | loading every URL form, and reconnecting with a trace page open, starts no trace and delivers no event | a route, or a reconnect, that opens `trace` fails |
| W7 | records with `unknown`, `timeout` and `partial` values show their tokens; a stopped guest marks every view stale; a ring overrun shows a gap with its count | a client printing a `partial` value bare fails |
| W8 bounds | the 17th view, the 65th line view, the 5th connection of a line, the 17th login, each refused; a client that never sends `next` receives one update per view and the web domain's memory for it stays under 1 MiB; a second `next` before its answer is `bye protocol`; a reused view number is `bye protocol` | a core that answers a view twice for one `next` fails |
| pull sampling | a record changing 100 times while the client is paused is sent once, as its last state; a log of 5,000 new entries arrives over several updates with none lost | a view that queues every change fails |
| UI attach | a UI attached, detached, changed and re-attached shows the newest tree; `apply_ops(delta(A, B), A) == {ok, B}` over random trees; a tree whose delta exceeds one update arrives over several and is applied at `commit` | a renderer that resends the backlog fails on the bound |
| UI parity of meaning | the display's parity corpus of trees and input sequences, through the browser renderer in Playwright, delivers the same events and values to the application and holds the same set of nodes as the Erlang renderer; no pixel or layout is compared | a seeded swap of two event names in the client fails |
| presentation state stays in the browser | scrolling a `scroll`, moving focus and selecting text in the browser sends no message to the machine and changes no server state | a client that reports scroll offsets fails |
| choosing the web display | a session holding `web` opens a UI there with `display => web`; with no display facet `erx_ui:open/1` answers `{error, no_display}` at once; stopping the web domain sends each opener `{ui_down, Window, display_down}`; closing every browser ends no UI | an `erx_ui` that ignores the option opens on the wrong display; a facet without the down report leaves the test's opener waiting past its deadline |
| secrets | a `secret` input's text reaches the application as `{erx_secret, _}`, appears in no counter, log, trace or crash report, and is empty after a re-attach | a renderer that folds the secret into its model fails |
| build | `make web` from the fetched store, with the network disabled, twice gives byte-identical files and inventory | a seeded package missing from the lockfile fails the frozen-lockfile install; a seeded local package whose install script writes a file leaves no file; a Node.js of another version than `web/package.json` records is refused |

### Chokepoints

| Rule | Check |
| --- | --- |
| No handwritten client source writes an HTML or code sink | a source check over `web/src` outside `generated/` that fails on `dangerouslySetInnerHTML`, `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `document.write`, `writeln`, `srcdoc`, `createContextualFragment`, `DOMParser`, `eval`, `new Function`, `setHTMLUnsafe`, `parseHTMLUnsafe`, an event handler set by `setAttribute`, a string passed to `setTimeout` or `setInterval`, and a `javascript:` literal; it reads the code with comments blanked, a comment starting only at a line's start or after white space, so a `//` or `/*` in JSX text is read as code; its test is a seeded file with each |
| Only the line escape reads a `MachineText`'s bytes | by construction: the bytes are a JavaScript private field of the class in `text.ts`, which no code outside the class can name, and its one method returns `escapeLine`'s runs |
| Only `hrefOf` writes an `href` | a source check that every `href` in `.tsx` is `hrefOf(...)`, that nothing assigns `location`, and that `location.assign`, `location.replace`, `window.open` and `history`'s `pushState` and `replaceState` take `hrefOf(...)` as their URL, whose test is a seeded literal `href` and a seeded navigation to a URL |
| Only the generated codecs encode or decode the protocol | the generated tree's determinism test, and a source check that no other module of the web domain or the client reads a message's bytes, whose test is a seeded module that does |
| The web domain's release calls no inspect, trace, console or shell client | an xref check over the release, whose test is a seeded call of `erx:inspect/2` in a module of the release |
| Only the front ends write HTTP headers, from the generated table | a source check that `Content-Type`, `Set-Cookie` and the security headers appear only in `erx_web_cowboy` and `Erx::Web`, as the table's names, whose test is a seeded header literal elsewhere |
| `Erx::Web` serves only the bundle's inventory | a source check that its file reads go through the inventory lookup, whose test is a seeded `File.read` |

The generated tree covers the TypeScript side as it covers Erlang and C:
the protocol's, `ui.txt`'s and the inspection schema's TypeScript files
are outputs of the ABI generator, under `web/src/generated/*` of
`build/gen/`, and the escape table is an output of the terminal
generator, so each is regenerated with the tree, falls under its
determinism test and ASCII refusal, and cannot be checked in or edited; `tsc
--noEmit` then fails on handwritten client code that no longer fits the
generated types. The generated TypeScript is ASCII-only, names its source
and generator, and is never edited. The ASCII check covers the client's
`.ts` and `.tsx` sources.

## Build and dependencies

`web/package.json` and `web/pnpm-lock.yaml` pin every package with its
integrity hash, and `web/package.json` records the Node.js and pnpm
versions (`engines` and `packageManager`), which `make web` checks before
it runs either, so a build means the same on every host.
`tools/erx fetch` is the one step that touches the network: it runs
`pnpm fetch` against the lockfile into a store under the build tree, and
fetches the Chromium of the pinned Playwright, checked against a SHA-256
in `deps.lock`. Every later step is offline: `pnpm install --offline
--frozen-lockfile --ignore-scripts`, so no dependency's install script
runs; `tsc --noEmit`; and esbuild with fixed options (ASCII output, no
source paths, legal comments to a separate notices file) into
`build/web/`. The files are build outputs, never checked in, and enter
the web domain's release, so `make check-reproducible` covers them.

The set is small on purpose: React and React DOM for the client;
TypeScript for checking; esbuild for bundling; Playwright with Chromium
for the browser tests; Node.js and pnpm as host tools. No router, state
library, CSS framework or test framework beyond these: routes, the
connection and the models are a few hundred lines of the client's own.

## Performance

Numbers to measure, on the
[watch list](todo-performance.md):

* a record view's round trip over the host tool's front end, which
  crosses the host link, the system domain's relay, the web domain, the
  line and the inspector, for the machine's record and a 1,000-child
  listing, under HVF and over a 115,200-baud UART, where whole
  records every 2 s may be too much and a record difference would be
  the fix;
* `erx_ui_model:delta/2` and `erx_ui_schema` for a 1,000-node tree, and
  a tree's first attachment over several 64 KiB updates on the UART;
* the client's first load over the host tool and over the network, and
  the bundle's size.

## Portability

Nothing here names an architecture or a platform. The host tool's front
end runs on any host with Ruby and a browser; the network front end needs
the network service and a network device, which are rows of the device
table per platform.

## Dependencies

| Component | Purpose | Licence | Status |
| --- | --- | --- | --- |
| React and React DOM 19, with their `scheduler` | the client's rendering | MIT | permanent, in the client's files; fetched by pnpm at pinned versions and integrity hashes |
| TypeScript 5.x | the client's language and type check | Apache-2.0 | permanent host tool |
| esbuild | bundling the client | MIT | permanent host tool, a native binary pinned by the lockfile |
| Playwright, with its Chromium build | the client's browser tests | Apache-2.0; Chromium BSD-3-Clause with its third-party notices | test tool, never in an image; Chromium fetched with a pinned SHA-256 |
| Node.js and pnpm | running the client's tools and tests; fetching its packages | MIT | host tools, at the versions `web/package.json` records |
| cowboy 2, with cowlib and ranch | the network front end's HTTP, WebSocket and TLS acceptance, in the web domain | ISC | permanent; fetched at a pinned version and hash and built out of tree against erXos's OTP, or imported as erXos's code if changed |
| Ruby standard library (`socket`, `digest`, `securerandom`) | the host tool's front end | Ruby's | no new dependency |

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| HTML rendered on the machine with no script | the machine owns templates, an HTML serialiser and an escaper; live views are reloads; and the browser cannot be a renderer behind the widget interface, so UIs need a page model of their own. Sending data lets the client do layout and makes the browser one more display |
| the browser as a widget renderer only, with the inspector, logs and traces as Erlang applications building widget trees | one message family, but the machine builds layout for every record, a virtual list needs new widget kinds, and every scroll of a log is a tree difference; a record is data, and each display renders it, as `erx_render` and the host tool's printer do |
| a browser renderer that reproduces the native window's layout and look | the browser would need the Erlang renderer's box model, fonts and metrics, and would still differ by browser; a tree that states meaning lets each medium render well, and the tests compare meaning |
| the browser as a mirror of a native display | one UI on two screens with two sets of presentation state and two sources of events; left out: the browser is a display of its own, and an application chooses where a UI opens |
| Erlang's external term format on the wire, decoded in the client | the host link's grammar is a starting point, but the client would parse Erlang terms and print them; a declared protocol with a closed value set is smaller, checked by its own generated codec, and fixes what the client must handle |
| a web front end inside the display domain | one domain fewer and one place for the widget server; but the display domain sees local pixels and keystrokes, passphrases typed at the machine included, and a network parser bug there would reach them. The two domains serve one service declaration and run one widget server, so applications see one service |
| pages or the client served by the machine over the host link | the developer's browser would run code the machine chose; serving the build tree's files keeps the host's browser free of machine code, and the protocol hash binds them to the build |
| the web domain holds inspect facets and answers views itself | one hop fewer; every browser would act with the web domain's authority, and bounding a principal would be checks in the web domain; fetching in the session makes W1 hold by construction |
| `erx_web` in the system domain until cowboy exists | the component that relays hostile input would start in the trusted base; a domain is a manifest entry and a release |
| pushed updates with a queue per view | needs a drop policy per kind and memory proportional to the slowest browser; one update per `next` bounds both, and sampling a record or a tree loses nothing a later state does not show |
| a window of acknowledged messages per connection, with large updates split into parts | sequence numbers, a pool of slots shared by the views, part joining and a rule for which view goes next; one outstanding update per view bounds memory the same way, and a long log or tree continues at the next `next` |
| the machine resolving presentations to paths | a target, a reply and an address rewrite of its own; the schema's path table is generated into the client, which opens an ordinary path |
| server-sent events with `POST`s for events | two channels, two authentications and a body parser on the host tool; one WebSocket carries both directions |
| Preact in place of React | a smaller library with React's interface; React was named, its identity rule is the display's, and the difference in size does not matter for a client served once |
| Vite, Webpack or Rollup | each brings a plugin system and many packages; esbuild alone bundles TypeScript and JSX |
| Vitest or Jest | each brings a large tree; Node's runner covers the pure modules and Playwright the browser |
| WEBrick for the host tool's server | a separate gem, and a far larger parser than one method, no bodies and closed connections need; a bounded reader with a fuzz target is smaller to own |
| the token in every request's URL | the token would sit in links, history and referrers; one redirect sets a cookie |

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| whole records over a UART host link are slow for large listings | medium | a 1,000-child view updates every few seconds | the measurement; the inspector's page limit; a record difference message if the numbers ask for it |
| a browser without Trusted Types | medium | the sink check carries W2 alone | the check is the guarantee; Trusted Types is a second line |
| cowboy's version does not fit erXos's OTP | low | the network front end waits | cowboy is plain Erlang; a patched copy enters as erXos's code |
| `ui.txt`'s widget set lacks what a browser UI wants | medium | plainer UIs | the tree gains a kind for every display, never a browser-only one |
| an attribute type of the schema projects outside `datum()`'s bounds (tuple width, depth 8) | low | such values arrive printed | the generator checks every attribute type of `abi/inspection.txt` against `datum()` and refuses one that does not fit |
| the owner is rethinking login, and that covers the network front end's `erx_web_login` as well as the console's and the display's | certain | this document's login may change | the login question is open in [design-display.md](design-display.md#risks-and-open-questions); nothing here depends on the display's terminals or the console's lines beyond the vault's limits |
| no browser view of a terminal exists: W1 gives the web domain no shell facet, and the views are records, logs and traces | certain | a terminal is reachable only at the serial console and over the host link, not in a browser | a browser terminal is a design of its own, with its own authority question, since it would put a shell facet behind the web domain; it waits for the login rethink, which decides how a person reaches a shell from anywhere |

Decided by the owner: TLS on the network front end, with plain HTTP only
where a development build's manifest lists it; the web domain as its own
domain from the start; `secret` on the widget `input`; the Ruby standard
library for the host tool's server; TypeScript for the client. And:

1. **The host link's `web` facet exists in development builds only,**
   bound to `root`'s session; a release manifest that lists `web` for the
   host fails the manifest check, and a release machine is reached with
   `console` over the host link or through the network front end.
2. **Chromium is the one test browser** for now, as Playwright's build,
   a test tool run as a subprocess and never shipped.
3. **Whole records** travel until a measurement over the serial host link
   shows that differences are needed.
4. **Node.js is approved** for the client's build and test tools, beside
   pnpm.
5. **The web is a different medium**: renderers render for their medium,
   with no pixel or layout parity; presentation state stays in the
   browser; parity tests compare meaning. Mirroring the native display in
   the browser is left out.
6. **The default display's name** is the environment variable `display`,
   lower case as rc's own variables are, which a login sets and a user
   changes as on UNIX. `DISPLAY` would read as X's to a ported program
   that checks it.
7. **One operation fits one update.** `ui.txt` bounds an `image`'s
   encoded bytes at 48 KiB, so every operation of a valid tree fits one
   64 KiB update and every valid tree renders on every display; a picture
   larger than that goes in a draw window beside the widget window, as an
   application's own drawing does.

## References

* [design-display.md](design-display.md): widget trees, the widget
  server, choosing a display, the renderer behaviour and the binary form
  of `ui.txt`, presentations.
* [design-live.md](design-live.md): inspection records, `/proc`'s
  encoding, attributed text and the line escape, tracing, the host link
  and its facets, the console's login.
* [design-system.md](design-system.md#the-manifest): the manifest check.
* [design-generation.md](design-generation.md#build-contract): generated
  outputs and the generated tree.
* The WebSocket Protocol, RFC 6455; HTTP Semantics, RFC 9110; Cookies,
  RFC 6265 and the `SameSite` attribute and cookie prefixes of its
  revision; Content Security Policy Level 3 and Trusted Types, W3C; Fetch
  Metadata Request Headers.
* cowboy 2 user guide: `cowboy_req`, `cowboy_websocket`, `cow_qs`,
  listener options and limits; ranch: `max_connections`.
* Jupyter's token authentication for a local notebook server, the model
  for the host tool's one printed URL.
