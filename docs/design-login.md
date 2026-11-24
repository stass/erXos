# Logging in through a front end

A person reaches erXos from somewhere other than its console: an SSH
client or a browser. In each case a
**front end**, a configured domain that parses what that medium sends,
asks the system domain to log the person in, and on success gets the
**line** of a new session of the person's principal and nothing else.
This document is the one interface every front end logs in through,
`login`, a facet of the system domain: its operations and bounds, who
holds it, what it trusts a front end for, how a passphrase is checked,
what a login returns and when a login ends.

What a front end does with its line is its own design: the SSH domain's
channels open ttys ([design-ssh.md](design-ssh.md)), the web domain opens
views ([design-web.md](design-web.md)). The Bluetooth console,
`bleuart`, an app's session rather than a configured domain, logs no
one in: in a development build it takes the line of the session the
console logged `root` in to, through the grant's one operation that
starts no session, `root_line`, and masters ttys of that session as an
SSH channel does
([design-bluetooth.md](design-bluetooth.md#the-console)).
Login at a display, with its prompt, lock and overlay, is
[design-display.md](design-display.md#risks-and-decisions)'s decision
14; a display login that needs a facet takes this one
([Risks and open decisions](#risks-and-open-decisions)). The console's
own lines, the UART and the host link, are the system domain's and call
the principal service directly ([design-live.md](design-live.md#the-console)).

## Context

* **Lines exist.** A session serves a line to a grantee the system domain
  names at run time, minted by `erx_domain:line(Name, Session, Peer,
  Opening)` (`erlang/apps/erx_domain/src/erx_domain.erl:271`), `Peer`
  being the grantee domain's id, ending with the opening, a process of
  the system domain, and with the session
  ([design-system.md](design-system.md#a-sessions-lines)). The host link's
  `web` facet already opens root's line this way
  (`erlang/apps/erx_uart/src/erx_hostlink_web.erl:114`).
* **Sessions start from a principal's template** through
  `erx_domain:start_session/2` (`erx_domain.erl:127`) and end with
  `erx_domain:stop/2`. The domain pid a start makes is linked to the
  domain service (`erlang/apps/erx_domain/src/erx_domain_srv.erl:970`),
  and a start waiting for its domain keeps its caller's reply address
  without monitoring the caller (`erx_domain_srv.erl:1322`), so a session
  today runs until it is stopped, whoever asked for it.
* **A facet tells its service which domain called, not which process.**
  `erx_facet` hands its callback's `admit/3` the caller's pid after
  checking that the caller and its reply alias are both names of the
  grantee's domain (`erx:call_from/3`, `erlang/apps/erx/src/erx.erl:177`),
  and forwards to the service under a fresh alias of its own
  (`erlang/apps/erx/src/erx_facet.erl`, module documentation). A
  process of the grantee can name any other process of its own domain
  as the caller, so the pid is the grantee's word within the grantee.
  The service sees the facet's forward, never the caller, unless the
  callback carries the caller into the forward, as `erx_session_line`'s
  `admit/3` does for every line.
* **A facet ends with the reason of what it ends with**
  (`erx_facet.erl:330`), and its grantee's callers and monitors see that
  reason ([design-domains.md](design-domains.md#facets)). Exit reasons
  cross domains, and the system domain runs no report filter
  ([design-log.md](design-log.md)): a process of it that holds another
  domain's bytes keeps them out of its reports through
  `erx_report:status/2`, and a process that holds secrets sets
  `process_flag(sensitive, true)`, which keeps its heap, stack and queue
  out of a crash dump (`otp/erts/emulator/beam/erl_process_dump.c:228`).
* **The passphrase checker is the vault's**
  ([design-system.md](design-system.md#the-vault), "Logins"): it counts
  failures by name in two classes of terminal and by terminal, answers
  matched, did not match, `limited` or `unavailable`, and answers a
  stranger as it answers a wrong passphrase, after the same time. The
  vault is [plan.md](plan.md#m11-security-closure)'s.
* **What is built.** The facet, its service and its core
  (`erlang/apps/erx_domain/src/erx_login_facet.erl`, `erx_login.erl`,
  `erx_login_core.erl`) and the manifest check's table of holders
  (`tools/lib/erx/manifest.rb`, `LOGIN_HOLDERS`), with the four
  operations below and not `root_line`; the development manifest
  declares the service and no row grants it
  (`config/manifest/development.txt`). No passphrase checker is built,
  so `login_passphrase` answers `unavailable`. SSH runs stage 1 of
  [design-ssh.md](design-ssh.md#stages), `erx_ssh_dev` in root's own
  session with root's authority, and the web front end's login is
  designed but not built.
* **The console's root session.** In a development build the console
  logs `root` in at boot and `erx_console:login_session/0` answers that
  session's domain (`erlang/apps/erx/src/erx_console.erl`); the host
  link's `web` facet mints that session's `web_line` for the web domain
  with no login (`erx_hostlink_web:root_line/2`).

## Requirements

| Requirement | Consumer and what breaks without it |
| --- | --- |
| **L1.** One interface for every front end | the SSH domain, the web domain and `bleuart`; two copies of one check diverge |
| **L2.** A login gives its front end the session's line and nothing else | every front end parses hostile input; a facet that granted more would hand a parser defect authority over principals |
| **L3.** A login ends when the front end's connection ends | SSH and the web; a crashed connection would otherwise leave a session running with nobody at its line |
| **L4.** A passphrase is checked in one place, under the network limits | every front end; a front end that checked passphrases itself, or under the console's local limits, would let a network peer guess faster or lock a name out at the UART |
| **L5.** A passphrase login answers a stranger as it answers a wrong passphrase | every front end; otherwise a failed login tells whether a name has credentials |
| **L6.** What a front end can make the system domain keep or do is bounded and declared | the system domain, whose fault resets the machine |
| **L7.** No login reaches the system shell | the system shell opens only at a line the manifest marks secure ([design.md](design.md#decisions)) |
| **L8.** No secret a front end hands the system domain reaches another domain, a report or a dump | every front end's users; a passphrase or a key exchange's input in an exit reason would reach another front end, and in the log every reader of it |

## Design

### A session ends with what it was started for

The construction: **a session started by a login names, at its start,
the processes it ends with, and the domain service, which makes the
session, stops it when any of them ends.** A login's session ends with
two processes: the front end's process that called for it, its
**owner**, and the login facet the call came through. This is the
`ends_with` a facet's mint names
([design-domains.md](design-domains.md#facets)), given to a session's
start: `erx_domain:start_session/2` takes `ends_with`, a list of
processes, and the domain service monitors each as it admits the start,
before the domain is made, so a process that has already ended stops
the start as one that ends later stops the session
([design-domains.md](design-domains.md#principals-sessions-and-quotas)).

Each requirement that would otherwise be a rule of its own follows:

* **L3 by construction.** A closed SSH connection, a crashed one and a
  browser login the web domain drops
  each end the owner, and its end stops the session. The front end has
  no `logout` to remember: it ends a login by ending the process that
  holds it, so no path of a front end leaves a session behind.
* **No orphan window.** The bond is made inside the one operation that
  makes the session, by the service that makes it, so no moment exists
  in which the session runs and nothing is watching for its owner: not
  while the login service waits for the start's answer, not if the login
  service crashes then. The login service keeps no links and checks no
  row after a start returns.
* **The grant's end and the login service's end.** The login facet ends
  with its grantee's domain, with a revocation of its grant and with the
  login service ([design-domains.md](design-domains.md#facets)). Its end
  stops every session started through it, so a front end's domain that
  ends, and a login service that crashes, stop every session their
  logins started, and the line's facet, whose opening is the login
  facet, ends with them. A front end takes its login facet's end as
  its own end, so the manifest restarts its domain within its start
  row's intensity, and the restarted domain is granted a new facet in front
  of the restarted service: the recovery that exists for any domain's
  end, with no reconnection protocol of its own.

The login service still keeps a table of logins, keyed by owner, which
it monitors. The table is bookkeeping for the bounds and the cookie, not
for lifetimes: a row is what the owner has outstanding, and it goes when
the owner ends.

* **The owner is the front end's word.** The facet behaviour checks that
  the caller is a process of the grantee's domain, and no more
  ([Context](#context)). A front end's own code calls from the process
  that serves a connection, so the row is that connection's: SSH's key
  login binds a signature to the cookie of one connection's first
  exchange ([design-ssh.md](design-ssh.md#logging-in)), and both the
  cookie and the login that uses it come from the connection's state
  machine process, which runs the exchange and authentication. A
  compromised front end can name another process of its own domain as
  the caller: replace another of its connections' cookies, or attribute
  a login to a process that lives longer. That gains it nothing it does
  not hold already, since it runs every one of its connections' code and
  keeps any of its processes alive as long as it likes. What the facet
  guarantees is the boundary between domains: no front end names a
  process of another domain, so none reaches another front end's rows,
  and no session it starts is bound to a process it does not own.
* **One login per owner.** An owner logs in at most once in its life; a
  second login from it is refused `badarg`. A front end that serves
  several people runs a process for each, as the SSH daemon does for
  each connection.
* **L6, a bound per grant.** Each grant's rows are at most its `logins`
  parameter; past it `cookie` and the logins answer `unavailable`. Each
  row costs the system domain a monitor and a few words, so the
  manifest's grants bound the table. Nothing evicts a row to make room:
  a row goes only with its owner, a failed login or its cookie's grace.

### Who holds it

`login` is declared in `abi/services/login.txt`, served by the system
domain. A configured domain, or `bleuart`'s session template, holds it
by a facet row of the manifest naming two parameters:

* `line`, the session line the login mints for this front end, one of
  the `served_by session` interfaces (`?ERX_LINES`): `tty_line` for a
  front end whose connections master ttys, `web_line` for the web
  domain;
* `logins`, the grant's bound on rows.

The row's operation list is the grant's methods, through the facet
behaviour's operation check: a front end calls only the operations its
row lists, and any other is refused `eperm` before the callback sees it
([design-domains.md](design-domains.md#facets)).

| Front end | `line` | operations | `logins` |
| --- | --- | --- | --- |
| the SSH domain ([design-ssh.md](design-ssh.md#the-ssh-domain)) | `tty_line` | `cookie`, `key_ok`, `login_key`, `login_passphrase` | 128, twice the daemon's 64 connections |
| the web domain ([design-web.md](design-web.md#logging-in-and-the-line)) | `web_line` | `login_passphrase` | 16, the front end's live logins |
| `bleuart`'s session template ([design-bluetooth.md](design-bluetooth.md#the-console)) | `tty_line` | `root_line` | 1, its one process |

The manifest check holds the facet to that table, as an allow-list keyed
by the grantee's kind and name, a configured domain for the SSH and web
domains and the session template of the principal `bleuart` for
`bleuart`, so a domain or a template that only shares a holder's name
is another grantee: it refuses a `login` row on any other grantee, a
row whose `line`, operations or `logins` differ from its holder's, a row
whose `max_request` or `in_flight` differs from the interface's (below),
more than one row per holder, and, in a release manifest, a row listing
`root_line`. The Bluetooth domain is not on it: it parses what anyone in
range sends and holds only its radio grants.
`tty_line` is the session line [design-system.md](design-system.md#a-sessions-lines)
serves a front end whose connections master the session's ttys,
`open_tty` and, with design-ssh.md's answer on jobs, `open_job`;
it is served by `erx_tty_line`, and named for what it serves. Whoever
masters a tty of a logged-in session can already type any command its
shell runs, so a front end that never opens a job gains nothing by being
refused one.

### Operations

Every answer is one of the closed set below; the facet behaviour adds
`busy` past the grant's requests in flight and `eperm` for an operation
the row does not list.

| Operation | Checks | Answer |
| --- | --- | --- |
| `cookie()` | the owner has not logged in and has no login being checked; draws 16 bytes from `erx_bytes:entropy/1` and keeps them in the owner's row for the login grace, 120 s, replacing the row's last | `{ok, Cookie}`, or `{error, unavailable}` when the generator fails or the grant's rows are full |
| `key_ok(User, KeyBlob)` | `User` names an enrolled principal whose login keys hold `KeyBlob` | `true` or `false`, the same for an unknown principal and an unknown key |
| `login_key(User, Exchange, Alg, KeyBlob, Sig, Peer)` | the owner's row holds an outstanding cookie; the exchange, signed data and signature as [design-ssh.md](design-ssh.md#logging-in) gives them, checked by the verifier against `KeyBlob` as the request arrives; then `KeyBlob` among `User`'s login keys, as `key_ok` checks | `{ok, Line}` or `{error, no_match \| unavailable \| badarg}` |
| `login_passphrase(User, Passphrase, Peer)` | the owner has not logged in and has no login being checked; the passphrase checker of [The passphrase check](#the-passphrase-check), class `network` | `{ok, Line}` or `{error, no_match \| limited \| unavailable \| badarg}` |
| `root_line()` | the owner has not logged in; the console holds a root session, `erx_console:login_session/0` | `{ok, Line}`, that session's `line` minted for the grantee with the login facet as the opening, as the host link's `web` facet mints root's `web_line` (`erx_hostlink_web:root_line/2`); `{error, unavailable}` when the console holds none or the mint fails, which leaves no row |

`root_line` starts no session and checks no credential: it hands the
grantee a line of the session the console already logged `root` in to,
which only a development build has, and which only a development
manifest can grant (above). The line ends with the login facet, so with
the grantee's session, and with the console's session; each tty opened
through it ends with its master, as every session tty does. The owner's
row is kept for the owner's life, as a login's is, so the grant's
`logins` of 1 bounds what `bleuart` can make the service keep to one
row and one line.

On a match the service starts a session of the principal from its
template (`erx_domain:start_session/2`) with `ends_with` naming the
owner and the facet, and the environment the front end's line implies
(`display` set to `web` for `web_line`), then has the session mint the
grant's `line` for the front end with the login facet as the opening
(`erx_domain:line/4`). The answer is the line's facet. A session start
the principal's quota or budget refuses answers `unavailable`, logged
with its reason; a line the session does not mint answers
`unavailable`, and the service stops the session.

Arguments are bounded where the facet decodes them, before any check:
`User` is a principal's name, a system identifier, which `erx_ident:new/1`
alone checks ([design-system.md](design-system.md#identifiers)), so every
principal the manifest admits can be named at a login; `Passphrase` 1 to
1,024 bytes, `Peer` at most 64 bytes, kept only for the terminal counter
and the log, through the log's escaping; SSH's blobs and exchange input
are `erx_ssh_wire`'s ([design-ssh.md](design-ssh.md#logging-in), S3).
Anything else is `badarg`. The bounds are one header of the `erx`
application, `erx_login.hrl`, which `erx_login_facet` and every front
end's prompt include. The largest request is a `login_key` with its
64 KiB exchange input, so the grant's `max_request` is 131,072, derived
as a line's is; `in_flight` is 8, each passphrase login waiting on the
checker's network queue.

**The terminal.** `Peer` is the front end's word: an address, a bond's
identity address, a browser's remote address. The terminal the checker
counts is `{Holder, Peer}`, `Holder` being the configured domain's name
in the manifest, which the grant carries and the front end never
supplies, so each front end's terminals are its own and keep their
counts across its reconnections and restarts. A lying front end moves
only its own terminals' counters, or evades them by naming a new peer
for each attempt; the per-name limit binds whatever it says, and the
per-terminal limit is only as good as the front end's honesty.

**L5.** A name that is no principal's, an app's principal, which has no
credentials, and a principal that has not enrolled all answer a
passphrase login `no_match`, after the checker's time for a wrong
passphrase, as the vault answers a stranger. Enrolment is at the UART
alone. L5 covers passphrases and nothing more. Principals' names are
not secret, since the manifest lists them, and `key_ok` tells an SSH
client whether a name accepts a public key, as an SSH server's
public-key query does, with no proof that the client holds the private
key and with its timing not equalized
([design-ssh.md](design-ssh.md#security)).

**L7.** The answer is a session line and nothing else. Only the console
grants the system-shell facet, at a secure line, and no front end's line
is one.

### A row's states

The login service keeps one row per owner that has something
outstanding, in one of three states: **cookie**, an outstanding cookie
and its grace timer; **pending**, a login whose check, session start or
line mint is outstanding, holding the request id of that one step, the
facet's reply address, the state to return to on a failed check and
the session the row started, none for `root_line`, which borrows
the console's; and **logged in**, which holds the session and is final. No owner has
more than one row, and a row in pending or logged in refuses every
operation `badarg`, so an owner has at most one login in progress, and a
second request from it while one is checked takes no row and starts
nothing.

| State | Event | Next | Effect and answer |
| --- | --- | --- | --- |
| none | `cookie()` | cookie | a row taken, or `unavailable` when the grant's are full or the generator fails; the owner monitored; the grace armed |
| cookie | `cookie()` | cookie | the cookie replaced, the grace armed again |
| none, cookie | `login_passphrase` | pending | a row taken from none, or `unavailable`; the checker asked |
| cookie | `login_key`, its signature verified | pending | the principal service asked whether `KeyBlob` is among `User`'s login keys |
| cookie | `login_key`, its signature not verified | cookie | `no_match` |
| none | `login_key` | none | `no_match` |
| none | `root_line()`, the console holding a root session | pending | a row taken, or `unavailable`; that session's line minted |
| none | `root_line()`, the console holding none | none | `unavailable` |
| pending, logged in | any operation | unchanged | `badarg` |
| pending | the checker's match, or the key found | pending | a cookie the row returns to retired; the session started |
| pending | the checker's other answer, or the key not found | the state returned to | that answer, `no_match` for a key not found; returning to none frees the row |
| pending | the session started | pending | the line minted |
| pending | the start refused | none | `unavailable`, logged; the row freed |
| pending | the line minted | logged in | `{ok, Line}` |
| pending | the mint refused | none | the session the row started stopped, and none for a `root_line` row, so the console's session is never stopped; `unavailable`; the row freed |
| cookie | the grace's end | none | the row freed |
| pending | the grace's end | pending | the state to return to becomes none |
| any | the owner's end | none | the row freed; its request id forgotten; a pending row answers `unavailable` to the ended caller, so the facet frees the forward's slot in flight |
| any | an answer whose request id no row holds | unchanged | dropped |

The last two rows need no further effect: a session whose owner ended is
stopped by the domain service, which monitors that owner from the
start's admission, so an answer that arrives after its owner has gone
reports a session that has ended or is ending.

A login whose session started answers `{ok, Line}` only after the mint;
the cookie of a key login is retired at the match, so no login reuses
one. Each step of a pending login is one asynchronous request of the
service's, the checker's answer, the start's and the mint's, matched to
its row by the request id the row holds; the service never waits on
one, so eight logins of a grant in flight wait on the checker together
and not on each other.

### The passphrase check

The login service hands the name, the passphrase, the class `network`
and the terminal to the principal service, which passes them to its one
passphrase checker and gives back its answer. Every login facet is
`network`: none of its front ends is a terminal wired to the machine, so
no browser or SSH client can lock a name out at the UART. The
checker is the vault ([design-system.md](design-system.md#the-vault)),
with its limits: 5 failures in 60 s per name in the network class, 5 per
terminal, one derivation at a time for the network class, each answer
after the login envelope. Until a
checker exists, `login_passphrase` answers `unavailable` and no front
end logs anyone in by passphrase; no checker is built before the vault
([Risks and open decisions](#risks-and-open-decisions), 1).

### Secrets

The system domain receives three secrets through the facet: a
passphrase, the input of an SSH key exchange, which holds its shared
secret ([design-ssh.md](design-ssh.md#security)), and the cookie it
mints. The front end sees the passphrase, as the SSH daemon does in
keyboard-interactive and the web domain does in its login form; it
never stores, logs or echoes one. L8 holds on every route a term of the
system domain takes out of a process:

* **A facet's end carries no terms.** A facet ends with the leading atom
  of the reason of what it ends with, `erx_report:reason_name/1`, never
  the reason whole ([design-domains.md](design-domains.md#facets)), so
  a login service that crashes with a request in its reason ends every
  login facet with an atom, and no front end's caller or monitor sees
  more. A forward whose service ends before it replies answers its
  caller `{error, failed}`, a fixed term, and a crash of the facet's own
  process, in its callback or in the behaviour, ends it with its reason's
  leading atom too. This is a rule of the facet behaviour, so it holds
  for every service behind a facet, not only for this one.
* **The facet's own process never crashes on a request.**
  `erx_login_facet`'s `admit/3` is a total function: every request it
  does not admit answers `badarg`, so no front end's request ends the
  facet for its other connections. Its fuzz target checks that `admit/3`
  returns on every input.
* **No dump or `process_info` shows a secret.** The login facet's
  process, the login service and the principal service, the three that
  hold a secret in their queues or heaps, set `process_flag(sensitive,
  true)` before any request can reach them: the facet's in its
  callback's `init/1`, which the behaviour runs before it exports the
  facet's pid toward its grantee, the services' in their `init/1`,
  before they register their names.
* **No report shows a secret.** `erx_login` and the principal service
  export `format_status/1` through `erx_report:status/2`, whose views
  show each row as its state and the counts, never a cookie, and
  requests and reasons by their kind
  ([design-log.md](design-log.md)).
* **No state keeps one.** A row never holds a passphrase or an exchange
  input: the service hands the passphrase to the checker as it asks,
  and verifies a key login's signature over its exchange as the request
  arrives, against the public key the request names, so what a key
  login waits on afterwards, whether that key is the principal's, is
  public. A cookie lives in its row until it is used, replaced or its
  grace ends.

The supervisor's report of a child's exit quotes the child's raw reason,
a gap of the system domain's reports that
[todo-inspection.md](todo-inspection.md) records as a security residual,
with its fix: the supervisor passing the reason through the child's
`format_status/1`. `erx_login`'s core refuses with closed reasons
(`error/1` of an atom), so its own decisions put no request in a reason,
and the residual covers what a defect of the service's shell would put
there, in the system domain's own log alone.

A bearer cookie the web domain gives a browser never reaches the system
domain: the web domain mints and keeps it in its login process, under
the report filter every domain but the system domain runs
([design-web.md](design-web.md#logging-in-and-the-line)).

### The service and its facet

`erx_login`, a process of the system domain, owns the table. Its
decisions are a pure core, `erx_login_core`: the row states and the
transitions of [A row's states](#a-rows-states), each returning the next
table and the effects to carry out (ask the checker, start a session,
mint a line, stop a session, monitor or demonitor an owner, arm a
grace). The process carries the effects out as asynchronous requests and
hands each answer, with its request id, back to the core.
`erx_login_facet` is the facet callback: `operation/1` maps a request to
its operation, and `admit/3` checks the arguments' bounds and forwards
`{Request, Caller, Grant}`, `Grant` holding the row's `line`, `logins`
and holder name and the facet's own pid, which the front end never
supplies.

## Invariants

| Invariant | Holds because |
| --- | --- |
| **G1.** A front end acts only on rows of its own grant, each keyed by a process of its own domain | the key is the caller the facet checked is a name of the grantee's domain; within the grant the key is the front end's word |
| **G2.** No session started by a login outlives its owner or its login facet | the start names both in `ends_with`, which the domain service monitors from the start's admission |
| **G3.** No grant holds more than `logins` rows, and no owner more than one row or one login in progress | the core takes a row before any effect and refuses past the bound; a pending or logged-in row refuses every operation |
| **G4.** A login mints exactly its grant's `line` for its holder | the line comes from the grant the facet forwards, never from the request |
| **G5.** A passphrase is checked only by the principal service's checker, class `network`, at a terminal of the front end's own | the service has no other path; the class and the holder name are fixed by the grant, not the request |
| **G6.** No secret of a request leaves the system domain's processes that hold it | a facet ends with an atom; `admit/3` is total; the holders are sensitive and report through `erx_report:status/2` |

## Failure handling

| Failure | Detected by | Effect | Recovery |
| --- | --- | --- | --- |
| a front end's connection process ends | the domain service's monitor of the owner; the login service's of the row | its session stops, the line's facet and ttys with it; its row goes | the person connects again |
| a front end's domain ends | the facet's grantee | the facet ends; every session started through it stops by its `ends_with`; the owners' rows go with the owners | the manifest restarts the domain |
| the login service crashes | its supervisor in the system domain | every login facet ends with it, with an atom; every session started through them stops; the table is rebuilt empty | each front end takes its facet's end as its own and ends; the manifest restarts its domain, which is granted a new facet; the service's supervisor restarts it within an intensity of its own (design-system.md, "System services"); a lost cookie fails only the login in progress |
| the login service crashes while a start is in flight | the domain service's monitor of the facet | the start is refused or its session stopped | as above |
| the checker is unavailable | its answer | `unavailable` | the person tries later |
| a session start or a line mint fails | its answer | `unavailable`, logged with its reason; a started session stopped | none needed |

## Refusals and error results

| Answer | When |
| --- | --- |
| `no_match` | wrong passphrase, key or signature; unknown, app or unenrolled principal; no outstanding cookie for a key login |
| `limited` | the checker's per-name or per-terminal limit |
| `unavailable` | no checker, the checker failing, the grant's rows full, the generator failing, a session start or line mint refused |
| `badarg` | an argument out of bounds, or an owner with a login in progress or done |
| `busy` | the grant's `in_flight` requests outstanding (the facet behaviour) |
| `eperm` | an operation the grant's row does not list (the facet behaviour) |

## Security

* **What a compromised front end gains.** The facet, the lines its logins
  minted, and what it sees in clear: the passphrases and the sessions'
  traffic of the people using it while it runs. Without a principal's
  passphrase or private key it starts no session but through a person
  logging in; it guesses under the checker's network limits alone, at
  terminals of its own; it can never reach the system shell, another
  front end's rows or terminals, a line of another interface, or a
  secret another front end handed the system domain.
* **What the system domain parses.** The arguments above, each bounded in
  `admit/3` before the service sees it, and SSH's blobs through
  `erx_ssh_wire`, which has a fuzz target. The login service's request
  decoding is a parser of untrusted input and gets a fuzz target of its
  own, over `admit/3`.
* **A passphrase answer tells no stranger from a wrong passphrase** (L5),
  and the class `network` keeps the UART's counters out of reach.

## Verification

Each passing case is paired with the seeded fault that proves the test
ran the code it names.

| Test | Passing case | Seeded fault the test must catch |
| --- | --- | --- |
| core, exhaustive (host) | every row state against every event gives the table of [A row's states](#a-rows-states) | a pending row that admits a second `login_passphrase` |
| connection binding (host) | `login_key` from a process other than the cookie's answers `no_match` | the table keyed by the facet's forward instead of the caller |
| forged caller (host) | a call whose `From` names a process of another domain is dropped by the facet; one naming another process of the grantee acts on that process's row and no other grant's | `erx:call_from/3`'s domain check removed |
| L3 (QEMU) | killing a front end's logged-in process ends its session domain within 5 s | the start's `ends_with` dropped |
| start in flight (host) | an owner that ends, and a login service killed, while `start_session` is outstanding each leave no session | the domain service's monitor taken after the domain is made instead of at admission |
| one login per owner (host) | a second login from a logged-in owner, and from one whose login is pending, answers `badarg` | the pending state's refusal removed: a second session starts |
| bound (host) | the `logins`th row is taken, the next answers `unavailable`, and a row freed by its owner's end makes room | the bound compared with `>` |
| failed mint (host) | a mint refused answers `unavailable` and stops the session it started | the stop removed: a session runs with no line |
| terminal (host) | the same `Peer` from two holders counts at two terminals | the holder dropped from the terminal |
| secrets (host) | a sentinel passphrase, with the login service seeded to crash holding it: absent from the system log, from a crash dump of the service and from the `'DOWN'` reason a monitor of another front end's facet receives | each of the sensitive flag, the status view and the facet's cut reason removed in turn |
| grant's methods (QEMU) | the web domain's grant calling `cookie` is refused `eperm` | the web row listing every operation |
| grant's line (QEMU) | a web grant's login mints `web_line`, the SSH domain's `tty_line` | the line taken from the request |
| passphrase (QEMU, with a checker) | the right passphrase opens a session; a wrong one and an unknown name answer `no_match`; the sixth failure in 60 s answers `limited` | the checker's answer ignored, so a wrong passphrase opens a session |
| no checker (host) | `login_passphrase` answers `unavailable` | a missing checker read as a match |
| bounds and fuzz (host) | `admit/3` refuses each argument one past its bound and returns on every input of the fuzz target | one bound removed |
| manifest check (host) | a `login` row on another domain, the Bluetooth domain included, with another `line`, another operation list, or another `max_request` or `in_flight` is refused | the allow-list rule removed; the quantities' rule removed |
| `root_line` (host) | with a console root session it answers that session's `tty_line` minted for the grantee with the login facet as the opening; with none it answers `unavailable` and keeps no row, so the owner's next call is answered; a second call after a success answers `badarg`; a mint that fails answers `unavailable`, frees the row and leaves the console's session running; in a release manifest a row listing `root_line` is refused, and so is a `login` row granted to a configured domain named `bleuart` | the caller named as the opening, so the line outlives the grant; the failed mint taken as a login's, which stops the console's session; the release rule removed; the holder table keyed by name alone, so the domain named `bleuart` packs |
| user name (host) | every system identifier decodes, a digit, a hyphen and 63 bytes included; an uppercase letter, a leading `-` or `_`, a `.`, a space, 64 bytes and a non-binary are `badarg` | the facet checking a name of its own instead of `erx_ident:new/1` |
| supervision (host) | the domain service's supervisor allows a restart of each permanent child, the login service among them, within one period | the intensity left at OTP's default of 1 |

## Interfaces

| Interface | Between | Declared in |
| --- | --- | --- |
| `login`: `cookie`, `key_ok`, `login_key`, `login_passphrase`, `root_line`; parameters `line` and `logins` | each front end and the system domain | `abi/services/login.txt`, citing this document |
| `erx_login.hrl`: the bounds of a login's arguments | `erx_login_facet` and each front end's prompt | the `erx` application |
| `tty_line`: `open_tty`, later `open_job` | a front end and a session | `abi/services/tty_line.txt` ([design-system.md](design-system.md#a-sessions-lines)) |
| `web_line` | the web domain and a session | `abi/services/web.txt` |
| `start_session/2`'s `ends_with` | the login service and the domain service | `erx_domain` ([design-domains.md](design-domains.md#principals-sessions-and-quotas)) |
| the principal service's passphrase check | the login service and the checker | internal to the system domain |

## Build order

Each package is one agent's, about 80 tool calls, ending in one reviewed
commit. Each runs the host tests of what it touches and the QEMU suite it
names; the full gates run once per batch.

1. **A facet's end and a session's `ends_with`.** `erx_facet` ends with
   its end's leading atom; `erx_domain:start_session/2` takes
   `ends_with`, monitored from the start's admission, with the
   start-in-flight test; the asynchronous request forms of
   `start_session/2` and `line/4` the login service issues.
2. **The login facet.** `abi/services/login.txt` and `erx_login.hrl`;
   `erx_login_core` with its exhaustive host test; `erx_login` and
   `erx_login_facet` in the system domain, sensitive and reporting
   through `erx_report:status/2`; `login_passphrase` wired to the
   principal service, which answers `unavailable` while it has no
   checker; the session start and the line mint; the manifest check's
   allow-list; the fuzz target over `admit/3`; the secrets test;
   `abi/services/web.txt`'s comments pointed at the facet. A host front
   end stands in for a real one in the tests.
3. **`tty_line`.** The session's line to a front end is the `tty_line`
   interface, served by `erx_tty_line`, with its operations and limits in
   `abi/services/tty_line.txt`, in the ABI, the code, the tests and the
   documents together.
4. **SSH's key login.** `cookie`, `key_ok` and `login_key` in the core and
   the service, `erx_ssh_wire` with its fuzz target, and the verifier's
   direct tests ([design-ssh.md](design-ssh.md#verification)).
5. **The SSH domain on the facet.** SSH stage 2's switch: `erx_ssh_keys`'
   hooks call the facet from the connection process, the connection
   process holds its line, and `erx_ssh_dev` goes
   ([design-ssh.md](design-ssh.md#stages)). SSH stage 2's other parts
   are its own packages.
6. **`root_line`**, with `bleuart`'s row of the holder table and the
   manifest check's refusal of the operation in a release manifest, in
   `bleuart`'s package ([design-bluetooth.md](design-bluetooth.md#the-console)).

Packages 1 and 3 are independent; 2 needs 1; 4 needs 2; 5 needs
both 3 and 4; and 6 needs 2 and 3. The web domain's login moves onto
the facet with the web's network front end.

## Alternatives considered

* **Two facets, `erx_ssh_login` and `erx_web_login`.** Two copies of
  one table, one check and one rate limit; a fix to one misses the
  other.
* **A connection identifier in the request.** A front end could name any
  of its connections' cookies, as a forged caller can, and the service
  would have to bound and check a name the facet already gives it.
* **A token the facet mints for each connection.** It separates the
  processes of a front end no better than the caller's pid does: a
  compromised front end holds every token it was handed.
* **Keying by the facet's forward.** Each forward has a fresh alias, so
  a cookie taken in one call could never be found by the next.
* **The login service monitoring owners and linking sessions.** The
  session's domain pid is the domain service's, created linked to it, so
  a service that links it only after the start returns leaves a window
  in which the session runs and nothing watches its owner, and a crash
  of the login service in that window leaves the session running; links
  also carry `normal` exits and run both ways. Naming `ends_with` at
  the start closes the window in the service that makes the session.
* **`logout`.** It made ending a session the front end's duty on every
  path, a crash included, which it cannot keep; ending the process ends
  the login on every path.
* **The terminal class as a row parameter.** Every front end that holds
  the facet is a network one; a parameter with one allowed value is a
  rule nobody needs. A display login that needs the local class adds it
  with its design.

## Risks and open decisions

1. **Decided: no passphrase checker before the vault.** The web login
   and SSH's keyboard-interactive take passphrases, and the vault that
   checks them is M11's. Until the vault exists the principal service
   has no checker, `login_passphrase` answers `unavailable`, and no
   front end logs anyone in by passphrase, so the web login and SSH's
   keyboard-interactive log in only once the vault's checker does.
2. **Display logins.** Decision 14 of
   [design-display.md](design-display.md#risks-and-decisions) settles
   what shows the prompt and which domain sees the passphrase. If a
   display's front end is a domain other than the system domain, it holds
   this facet with the local class added as a parameter and its own
   line; if the prompt is the system domain's, it calls the principal
   service as the console's lines do and needs no facet.
3. **Keys open only to sessions that gave the passphrase.** A key login
   opens nothing in the vault and uses the principal's keys while another
   session holds them open ([design-ssh.md](design-ssh.md#logging-in)).
   A per-session unlock would be a field of the login's row and a vault
   record; it is an item of [todo-session.md](todo-session.md).
4. **Monitors across domains.** The domain service monitors an owner in a
   front end's domain, and the login service monitors the same process
   for its row. Package 1 confirms on QEMU that such a monitor takes its
   `'DOWN'` when the process ends, when its domain ends (`noconnection`)
   and when the process had ended before the monitor was taken
   (`noproc`), and treats each alike; where one fails, it says so before
   building on it.
5. **Open: how `bleuart` gets root's line without a login.** `tty_line`
   reaches a grantee only as the reply of a declared facet's operation
   ([design-system.md](design-system.md#a-sessions-lines)), and no
   manifest row grants a line, so `bleuart`, which has no credential,
   needs one operation that answers a line without one. The ways:
   * **`root_line` on the login facet** (this document's design): one
     operation and one row of the holder table, minting the console's
     root session's line as the host link's `web` facet already mints
     its `web_line`; refused in a release manifest. Its cost is that the
     login facet, whose every other answer follows a checked credential,
     gains one that follows only the manifest's grant, and that the
     holder table names a session template beside configured domains.
   * **A facet of its own**, a new interface with that one operation:
     the same mint and the same release rule, with a second interface
     and a second callback to keep.
   * **A daemon in root's console session**, as SSH's first stage runs,
     holding root's session's `ble` grant: no line and no new operation,
     but no `start` row, so no `service bleuart`, and a `ble` grant on
     root's template, which every root session would hold.

   Recommended: `root_line`, the smallest change that keeps `bleuart` an
   app the start table switches, and the one that puts every handover
   of a session line to a front end behind one facet and one allow-list.
