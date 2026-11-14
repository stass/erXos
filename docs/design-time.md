# Network time

A machine without a battery-backed clock starts every boot near
1970-01-01, and file times, log lines and certificate checks are wrong
until something sets the wall clock. This document is the contract for
setting it from the network with SNTP, the simple subset of NTP that RFC
4330 specifies: who measures, who sets, what a step is, what the
operator configures and sees, and how it is tested. The kernel's clock
and its time page are [design-kernel.md](design-kernel.md)'s ("Time");
apps, the start table and `rc.conf` are [design-apps.md](design-apps.md)'s;
UDP sockets and name resolution are
[design-network-stack.md](design-network-stack.md)'s.

Decisions every reader needs:

* **A sample is a wall offset.** The client measures the server's clock
  against the kernel's monotonic clock, never against the wall clock, and
  reduces each exchange to one integer: the server's time minus monotonic
  time, in nanoseconds. That is the number the time page stores, and the
  setter stores it as given. So a measurement does not depend on what the
  wall clock reads, a sample stays true after a step, and setting the
  clock means writing one number ([The construction](#the-construction)).
* **The clock's state is the time page.** Whether this boot has changed
  the clock is read from the page, which nothing resets during a boot, so
  no crash or restart of the client or the clock service can renew the
  unrestricted first step, and no flag has to be consumed.
* **The system domain owns the clock; an app measures it.** The system
  domain holds the time page's `WRITE` right and parses no network
  traffic (design-network-stack.md, decision 19). The SNTP client is an
  app, principal `ntpd`, whose session holds a `net` grant and a `clock`
  facet of the system domain's **clock service**. The facet carries
  samples, never packets ([Who does what](#who-does-what)).
* **Off unless enabled, as on FreeBSD, and no default server.** The
  manifest's `start ntpd` row says `enable NO` and names no server;
  `ntpd_enable="YES"` and `ntpd_flags="SERVER ..."` in `/etc/rc.conf`
  start it at boot against the operator's servers
  ([Configuration](#configuration)).
* **One unrestricted step per boot, then steps above 128 ms.** While the
  page is as the boot left it, a sample sets the clock whatever its
  distance, as `ntpd -g` allows once; never to a time before the release's
  floor date. After that an offset above 128 ms is stepped when two
  samples in a row show it in the same direction, an offset of 1000 s or
  more is refused, and smaller offsets are left alone. There is no slew
  ([Steps](#steps)).
* **The server decides the time.** Without authentication, the server
  the client uses, or anyone on the path to it, controls the wall clock:
  the thresholds filter one bad measurement, they bound nothing over time
  ([Security](#security)).
* **`/proc/time/status` is the clock's record.** It shows whether the
  clock was changed this boot, the last sample and the last step, each
  attribute with its source and lifetime, and nothing it does not know
  ([What /proc shows](#what-proc-shows)).

## Context

### What FreeBSD does

The behavior erXos matches is FreeBSD releng/15.1's, at commit
`95719d8a895bf8170851e9844d9b4092b1d2b6fe`:

* **Network time is off by default.** `/etc/defaults/rc.conf` sets
  `ntpdate_enable="NO"`, `ntpd_enable="NO"` and
  `ntpd_sync_on_start="NO"` (`libexec/rc/rc.conf`, "Network Time
  Services options"). FreeBSD's Raspberry Pi image does not enable it
  (`release/tools/arm.subr`).
* **When enabled, ntpd uses two pool names of FreeBSD's own zone**,
  `pool 0.freebsd.pool.ntp.org iburst` and `pool 2.freebsd.pool.ntp.org
  iburst`, with `tos minclock 3 maxclock 6` and a restrictive `restrict
  default limited kod nomodify notrap noquery nopeer`
  (`usr.sbin/ntp/ntpd/ntp.conf`, lines 19, 32-33 and below).
* **`ntpd_sync_on_start=YES` adds `-g`** (`libexec/rc/rc.d/ntpd`,
  `command_args`). Without it, ntpd exits when the offset exceeds the
  panic threshold of 1000 s. With it, "the time [may] be set to any value
  without restriction; however, this can happen only once"; after that,
  exceeding the threshold again makes ntpd exit. An offset above the step
  threshold of 128 ms is stepped, a smaller one slewed, at the typical
  kernel limit of 0.5 ms/s (`contrib/ntp/ntpd/ntpd.mdoc.in`, options
  `-g`, `-G` and `-x`).
* **dhclient does not ask for DHCP's NTP-server option**; its default
  request list leaves it out (`sbin/dhclient/clparse.c`).

ntpd's source is under the University of Delaware's NTP license, a
permissive notice (`contrib/ntp/COPYRIGHT`); only its documentation was
read for this design.

### What the protocol requires

* **The packet** is a 48-byte header: leap indicator (LI), version (VN)
  and mode in the first byte, stratum, poll, precision, root delay and
  root dispersion (32-bit fixed point), reference ID, and four 64-bit
  timestamps, reference, originate, receive and transmit; extension
  fields and a MAC may follow (RFC 4330 section 4, Figure 1; RFC 5905
  section 7.3). A timestamp is seconds since 1900 in its high 32 bits and
  a binary fraction in its low 32 bits (RFC 4330 section 3).
* **Eras.** The seconds field wraps in 2036. RFC 4330 section 3 gives the
  convention: with the top bit set the time is in 1968-2036, counted from
  1900; with it clear, 2036-2104, counted from 2036-02-07 06:28:16 UTC.
  RFC 5905's first-order differences of 64-bit timestamps span 68 years
  either way, but the offset and delay are sums of two such differences,
  which in 64-bit integers are unambiguous only within 34 years, so "the
  time of the client must be set within 34 years of the server"; taking
  the second-order sums in wider arithmetic restores 68 years (RFC 5905
  section 8; RFC 4330 section 3 states the 34 years). A board booting at
  1970 is 56 years from a 2026 server: past 34, within 68.
* **The client's checks** (RFC 4330 section 5): addresses and ports of
  the reply interchanged from the request's, the reply's originate
  timestamp equal to the request's transmit timestamp, mode 4, VN as
  sent, a non-zero transmit timestamp and a stratum that is not 0. Check
  4 reads "LI, Stratum, or Transmit Timestamp fields is 0"; LI 0 means
  "no warning", so read literally the check discards every good reply.
  RFC 5905's own code discards LI 3, `NOSYNC`, "unknown (clock
  unsynchronized)" (sections 7.3 and A.5.1), and this design follows RFC
  5905. Whether an erratum to RFC 4330 records this is not checked.
  RFC 5905 also discards a reply whose root delay over two plus root
  dispersion reaches 16 s or whose reference time is later than its
  transmit time (A.5.1, `fit`), and a source whose distance exceeds
  `MAXDIST`, 1 s. Its distance takes the root delay and the measured
  delay together, `max(MINDISP, rootdelay + delay) / 2 + rootdisp + ...`
  (A.5.5.2, `root_dist`), and its code types root delay as the unsigned
  short format (`tdist`, A.1.1).
* **Offset and delay** of one exchange, from the client's send and
  receive times T1 and T4 and the server's T2 and T3:
  `delay = (T4 - T1) - (T3 - T2)`, `offset = ((T2 - T1) + (T3 - T4)) / 2`;
  a negative delay happens only in symmetric modes, which SNTP clients
  may not use (RFC 4330 section 5). NTP's clock filter keeps the sample of
  least delay (RFC 5905 section 10 and A.5.2).
* **Kiss-o'-death.** A reply of stratum 0 carries a four-letter kiss
  code in its reference ID. For `DENY` and `RSTR` the client MUST stop
  sending to that server; for `RATE` it MUST poll it less often; codes
  beginning with `X` it ignores if unknown; other codes have no
  significance and the packet is discarded. A kiss's receive and
  transmit timestamps are undefined and "MUST NOT be relied upon" (RFC
  5905 section 7.4; RFC 4330 section 8).
* **Good citizenship** (RFC 4330 section 10): never poll more often than
  every 15 s; back off exponentially; let the operator configure servers
  (MUST); resolve names with DNS and re-resolve no faster than the
  answer's TTL; honour kiss-o'-death. A firmware default server "MUST be
  a server operated by the manufacturer or seller of the device or
  another server, but only with the operator's permission" (item 5).
  Vendors can obtain their own zone of the NTP Pool for this (RFC 8633
  section 3.6).
* **Step and panic thresholds.** RFC 5905 steps above `STEPT`, 125 ms,
  after the offset has persisted for the stepout interval `WATCH`, 900 s,
  and treats more than `PANICT`, 1000 s, as a reason to exit (section
  11.3 and A.5.5.1); its code defines `STEPT` as .128 (A.1.1).
  FreeBSD's ntpd documents 128 ms (above).
* **Restart attacks** (RFC 8633 section 5.2). When a supervisor restarts
  a client that exits at the panic threshold, and the client ignores the
  threshold on every start, a server that sends one large offset gets the
  restarted client to accept it: "the panic threshold offers no
  protection". Operators should ignore the threshold only "in a
  cold-start situation", and implementations SHOULD refuse steps "to a
  time earlier than the compile date". One source decides a client's
  time: "Any issue with the time at the source will be passed on to the
  client" (section 3.2).

### What erXos already has

* **The time page** is one read-only page every domain maps: the
  counter's scale and `wall_offset_ns`, "wall time minus monotonic time".
  A reader takes `seq`, the fields and `seq` again, so every runtime
  reads wall time without a kernel call. The system domain corrects it
  with the setter, which needs `WRITE` on the time page
  ([design-kernel.md](design-kernel.md), "Time"). The setter in the tree
  is `erx_time_set_wall(wall_ns)`, whose body stores `wall_ns` minus a
  monotonic reading of its own, taken after the call has crossed to the
  service on the stopgap (`liberx/backend/fiasco/time_page.c`,
  `erx_fiasco_time_set_wall_body`), and checks no range; this design
  replaces it with `erx_time_set_offset`, which stores the offset it is
  given ([The construction](#the-construction)).
* **ERTS reads both clocks from liberx.** `erts_os_system_time` is
  `erx_time_wall_ns`, read on every call and cast to ERTS's signed 64-bit
  `ErtsSystemTime`, `erts_os_monotonic_time` and
  `erts_sys_hrtime` are `erx_clock_ns`
  (`otp/erts/emulator/sys/erxos/sys_time.c`); `os:perf_counter/0` returns
  `erts_sys_hrtime` in nanoseconds (`erl_unix_sys.h`,
  `erts_sys_perf_counter`; `sys_time.c`, `perf_counter_unit`). So in
  Erlang, `os:perf_counter(nanosecond)` is the kernel's monotonic clock
  and `os:system_time(nanosecond)` the time page's wall clock.
* **ERTS follows a wall step.** Multi-time-warp mode is OTP's default
  since OTP 26 and "Erlang system time can perform time warps both
  forwards and backwards at any time"
  (`otp/erts/doc/guides/time_correction.md`); no manifest's runtime
  arguments set `+C`. ERTS's time supervisor compares OS system time with
  Erlang system time every 60 s (`ERTS_LONG_TIME_CORRECTION_CHECK`,
  15 s for a while after a change) and moves its time offset when they
  differ by more than twice `small_diff`, 50 us for a nanosecond clock
  (`otp/erts/emulator/beam/erl_time_sup.c`, `check_time_correction` and
  the `adj.large_diff` setup). So `os:system_time/1` shows a step at once
  in every domain, and `erlang:system_time/1` within about a minute;
  Erlang monotonic time and timers do not move.
* **UDP and DNS in an app.** A session that holds `net` opens
  `gen_udp` sockets through `erx_gen_udp`, IPv4 only for now, with
  `connect/3`, and the stack draws every ephemeral port at random
  (`erlang/apps/erx_net_client/src/erx_gen_udp.erl`). `inet_res` resolves
  names over the grant's name servers, and `inet_db`'s random draws come
  from `erx_bytes:entropy/1`, the kernel's generator
  ([design-network-stack.md](design-network-stack.md#name-resolution);
  [design-runtime.md](design-runtime.md), edit 63).
* **The system domain parses no network traffic.** The manifest check
  refuses a `net` facet granted to it, and "whatever in it would need the
  network runs in a service domain instead"
  ([design-network-stack.md](design-network-stack.md#the-grant),
  decision 19; [design-system.md](design-system.md#the-network-domain)).
* **Apps and the start table.** An app is a principal with a session
  template; a manifest `start` row declares that it may start and its
  defaults, and `/etc/rc.conf` sets `NAME_enable`, `NAME_display`,
  `NAME_restarts`, `NAME_period` and `NAME_flags` over it
  ([design-apps.md](design-apps.md#the-start-table)).

## Requirements

* **T-R1.** With network time enabled, and the network and a server
  reachable when the client starts, wall time agrees with the server's
  within a minute; when they become reachable later, within the retry
  wait then in effect, which [the schedule](#schedule) bounds at 1024 s,
  plus that minute. "Agrees" means within the error [Steps](#steps)
  states: the stepping sample's distance, below 1 s and in practice tens
  of milliseconds, plus at most 128 ms left alone, plus the counter's
  drift since. The consumers are file times, log times and certificate
  validity ([design-crypto.md](design-crypto.md)), none of which needs
  better than a second.
* **T-R2.** It is off unless enabled, and enabled the way FreeBSD's
  `ntpd_enable` is.
* **T-R3.** The operator configures the servers (RFC 4330 item 4).
* **T-R4.** An NTP packet is hostile input. It is parsed outside the
  trusted base, by a total decoder with a fuzz target, and nothing in it
  reaches a text sink unescaped.
* **T-R5.** Only the system domain changes the wall clock, and only the
  holder of a `clock` facet can ask it to.
* **T-R6.** Nothing reports a time it does not have: until the clock is
  set, `/proc` says so.
* **T-R7.** Every wall time any domain reads lies in `[0, 2^63)` ns from
  1970, the range of ERTS's signed system time, at every moment of a
  boot, whatever a holder of `clock` sends.
* **T-R8.** Only a cold start allows an unrestricted step: no automatic
  restart of the client or the clock service renews it (RFC 8633 section
  5.2).

Not required, and not built: full NTP (selecting and combining several
servers, frequency discipline, symmetric and broadcast modes, serving
time to others), leap-second insertion, authentication, and taking
servers from DHCP.

## The construction

**A sample is the wall offset the server implies.** The client sends a
request at monotonic time `m1`, from `os:perf_counter(nanosecond)`, and
takes the reply at `m4`. It converts the reply's receive and transmit
timestamps once, at decode, to integer nanoseconds since 1970 by RFC
4330's era convention, `t2` and `t3`. Then

```text
delay = (m4 - m1) - (t3 - t2)
W     = ((t2 - m1) + (t3 - m4)) div 2
```

`W` is the server's time minus the kernel's monotonic time, which is
exactly the time page's `wall_offset_ns`. The clock service sets the
clock by storing `W` in the page: `erx_time_set_offset(time_page,
offset_ns)` writes `offset_ns` as the page's offset, unchanged, so no
time between measuring and storing, a descheduled caller or the
stopgap's crossing to its service included, changes what is stored.

**Every offset lies in one range.** The setter refuses with `ERX_EINVAL`
an offset outside `0..time_offset_max`, `2^62 - 1` ns (146 years, to
early 2116), a limit of `abi/erx_abi.txt`; the kernel stores the
real-time clock's boot reading only when its offset lies in the same
range, and leaves zero otherwise. Monotonic time stays below `2^62` ns
for 146 years of uptime, so every wall time, `monotonic + offset`, lies
in `[0, 2^63)`: published, after any step and as it advances (T-R7).
Every time a decoded reply can carry, 1970 to 2104, gives an offset
inside the range, so the bound refuses no real sample.

**The clock's state is the page.** The page's `seq` starts at zero when
the page is published and is never reset during a boot
([design-kernel.md](design-kernel.md), "Time"), so `seq = 0` is a fact
of the boot, true until something first changes the page and false from
then to the next boot. The clock service reads it with the offset,
through `erx_time_offset`, and takes **cold start** to mean exactly
`seq = 0`. No party holds this state, so no crash, restart or lost
answer can renew or lose it (T-R8).

The special cases this removes:

* **No era problem at boot.** The client's own times are counter
  readings, never NTP timestamps, and the server's are converted to
  unbounded Erlang integers, so no difference is taken modulo 2^64. RFC
  5905's 34-year limit on second-order sums in 64-bit integers, which a
  board at 1970 exceeds, and its 68-year limit, which such a board
  exceeds from 2038, do not arise; the first sample needs no other path.
* **No first-sample flag.** Whether a sample may step without limit
  follows from the page, not from a flag the facet or the service keeps
  and consumes, so there is nothing to consume at the wrong moment and
  nothing to renew: a restarted client or service sees the boot's state
  as it is.
* **The request's transmit timestamp is a nonce.** The client never
  sends its clock, which means nothing before the first step. It sends
  64 bits from `erx_bytes:entropy/1` and matches the reply's originate
  timestamp against them, which is RFC 4330's check 3 and the off-path
  defense at once.
* **A step invalidates nothing.** RFC 5905 resets every association
  after a step, since its offsets are relative to the clock that just
  moved. A `W` is relative to the monotonic clock, which no step moves,
  so the client keeps its state across steps and the clock service
  compares a sample with the page as it stands.
* **A request is absolute and idempotent.** The facet carries `W`, not
  an amount to add, and the setter stores it as given, so time spent in
  queues, a repeated request or a second setter cannot make a correction
  apply twice or apply short.
* **The distance from the clock is one subtraction.** The sample's offset
  from the clock as it reads is `D = W - C`, where `C` is the page's
  `wall_offset_ns`; the step rules and `/proc` use that difference.

## Who does what

```text
  ntpd session (app, principal ntpd)          system domain
  ----------------------------------          -------------
  erx_ntpd: flags -> names -> inet_res
  erx_ntp_core (pure): schedule, checks,     erx_clock_facet: decode
    W and distance, kiss-o'-death
  erx_ntp_wire (pure): 48-byte codec    --->  erx_clock: erx_clock_core (pure)
  gen_udp over net (network domain)      clock   decides; erx_clock_nif
                                         facet   reads the page and calls
                                                 erx_time_set_offset
                                                 record -> /proc/time
```

* **The ntpd app** is the measuring side. Its session holds three grants
  and nothing else: `net` with small limits (two sockets), `clock`, and
  the `log` facet every domain has. It runs `erx_ntpd`, an OTP
  application of its own release: a pure core, `erx_ntp_core`, that takes
  events (a timer fired, a datagram arrived, a resolver answer, the clock
  service's answer) and returns the next actions and deadline, and a
  thin effect process that reads its start flags, resolves names, opens
  sockets, sends, receives and calls the facet. The packet codec,
  `erx_ntp_wire`, is pure and the only reader of NTP bytes.
* **The clock service**, `erx_clock`, a system service of the system
  domain under the system release's supervisors, is the setting side. For
  each sample it reads the page through `erx_clock_nif:read/0`, runs
  `erx_clock_core:decide/3`, a pure function from the sample, the page
  and its record to an action and the next record, performs a step
  through `erx_clock_nif:set_offset/1`, and answers the inspector for
  `/proc/time`. A crash restarts it with an empty record and loses only
  the record's history; no grant ends, and every decision reads the
  clock's state from the page ([What /proc shows](#what-proc-shows)).
* **The `clock` facet**, `erx_clock_facet`, is the `erx_facet` callback
  the domain service mints for each grantee of `clock`, as the log facet
  is minted ([design-log.md](design-log.md)). It decodes the request,
  stamps the grantee, and forwards it to the `erx_clock` registered at
  that moment, or refuses with `{error, unavailable}`. It keeps no state
  of its own.
* **`erx_clock_nif`**, a static NIF of the runtime, is the one object
  that calls `erx_time_set_offset`, as `erx_watchdog_nif.c` is the one
  that pets the watchdog. On erXos's kernel only the system domain holds
  the time page's `WRITE` right, so wherever else the NIF is linked the
  call fails; on the stopgap the call checks no right
  ([Phase 1](#phase-1)).

Why an app and not the network domain: the network domain is the stack,
an OTP application usable outside erXos, and the domain that parses every
packet would then also hold the clock. A separate app keeps the clock's
authority with a domain whose only input is NTP replies, and it is the
start table's row that `ntpd_enable` switches. Why not the system
domain: it parses no network traffic, and the facet keeps it that way;
the clock service reads three bounded integers and an address.

## Interfaces

### The clock facet

`abi/services/clock.txt` declares `service clock` with one operation,
`sample`, and the limit `clock_distance_max_ns`, 1 s, RFC 5905's
`MAXDIST`; the generated `erx_abi.hrl` gives it, with the kernel limit
`time_offset_max`, to the client and the facet alike. The manifest serves
the service from the system domain:

```text
service clock
  server system
  interface clock
```

A request is

```erlang
{sample, W, Distance, Stratum, Server}
%% W        :: 0..?ERX_TIME_OFFSET_MAX              wall offset, ns
%% Distance :: 0..(?ERX_CLOCK_DISTANCE_MAX_NS - 1)  root distance, ns
%% Stratum  :: 1..15
%% Server   :: inet:ip4_address()                    the address that answered
```

`erx_clock_facet:decode/1` answers the sample or `{error, badarg}` for
anything else: another operation or arity, a value outside its range, an
address that is not four integers of 0 to 255. It creates no atom and
never raises. `W`'s range is the setter's own, so a sample the facet
admits is one the setter can store. `Distance` is the bound on the
sample's error that the client computed ([Checks on a
reply](#checks-on-a-reply)), and the client sends only samples whose
distance is below the same limit, so the facet refuses nothing the
client accepted. The facet forwards `{sample, Grantee, Sample}` and keeps
nothing.

The answer is `{ok, Action}`:

| Action | Meaning |
| --- | --- |
| `{stepped, StepNs}` | the page now holds `W`; the clock moved by `StepNs`, signed |
| `held` | the sample is recorded and the clock left alone |
| `{refused, floor}` | the sample's time is before the release's floor date; nothing changed |
| `{refused, panic}` | the sample is 1000 s or more from a clock this boot has already changed; nothing changed |

or `{error, badarg}`, `{error, unavailable}` (no clock service),
`{error, unsupported}` (the backend cannot set wall time, `ERX_ENOTSUP`),
`{error, limit}` (the page's sequence has run out, `ERX_ELIMIT`), or the
facet's own `{error, busy}` and `{error, failed}`
([design-domains.md](design-domains.md#facets)). `{error, failed}` means
the service ended before it answered, so the step may or may not have
been applied; the next sample finds out from the page
([Concurrency and failure](#concurrency-and-failure)). The client logs
every refusal and error and goes on polling.

### The NIF and the liberx calls

* **`erx_time_set_offset(time_page, offset_ns)`** stores `offset_ns` as
  the page's offset, under the page's sequence, and returns `ERX_OK`,
  `ERX_EINVAL` for an offset outside `0..time_offset_max`, `ERX_ELIMIT`
  when the sequence has run out, or `ERX_ENOTSUP` on a backend that
  cannot set wall time. It needs `WRITE` on the time page
  ([design-kernel.md](design-kernel.md), "Time").
* **`erx_time_offset(&offset_ns, &cold)`** reads the page's offset and
  whether its `seq` is zero, under the same sequence loop as
  `erx_time_wall_ns`, and is false when the sequence has run out. It
  needs nothing beyond the page every domain maps.
* **`erx_clock_nif:read()`** answers `{ok, #{offset := C, cold :=
  Cold, monotonic := M}}`, the two from one `erx_time_offset` and `M`
  from `erx_clock_ns` right after, or `{error, limit}`.
* **`erx_clock_nif:set_offset(OffsetNs)`** returns `ok` or `{error,
  Status}` for `erx_time_set_offset`'s status.

`otp/erts/emulator/sys/erxos/imports.txt` gains a section
`[only_erx_clock_nif] erx_time_set_offset`, so no other object of the
runtime can call it, and a check over the system release's call graph
allows `erx_clock_nif:set_offset/1` only in `erx_clock`, with a seeded
violation, as for `erx_log:take/0`.

## Steps

`erx_clock_core:decide(Sample, Page, Record)`, with `Page` the read of
`erx_clock_nif:read/0` made when the sample arrives and `D = W - C`,
takes the first row whose condition holds:

| Condition | Action | Record |
| --- | --- | --- |
| `M + W < floor` | refuse `floor` | `excess := none` |
| `Cold` | step to `W` | `excess := none` |
| `abs(D) =< 128 ms` | hold | `excess := none` |
| `128 ms < abs(D) < 1000 s`, and `excess` has `D`'s sign | step to `W` | `excess := none` |
| `128 ms < abs(D) < 1000 s`, otherwise | hold | `excess := sign(D)` |
| `abs(D) >= 1000 s` | refuse `panic` | `excess := none` |

Every row also stores the sample, its time and its source as the last
sample. A step that the setter refuses stores the refusal as the last
step error and answers it; a step it applies stores its time and size
and counts it.

* **The floor.** `floor` is the UTC date of the system release's source,
  a constant of `erx_clock_core` raised when a release is made, so no
  sample sets the clock before the software it runs was written, as RFC
  8633 section 5.2 asks of implementations. A floor that lags the
  release only weakens this check.
* **Three ways a clock is set, told apart by the page.**
  * *Initial bootstrap.* While `Cold`, the page is as the boot published
    it: at the epoch on both boards and the stopgap, or the real-time
    clock's reading. The sample steps whatever its distance, as
    `ntpd_sync_on_start=YES` makes FreeBSD's first one. erXos does not
    offer the `NO` setting: every boot without a real-time clock starts
    56 years from the server, so the client could never set the clock.
  * *Automatic restart.* A crash and restart of the ntpd session or of
    the clock service changes nothing on the page, so the next sample
    meets the panic threshold if the clock was changed this boot. A
    panic refusal does not end the client, so a server that sends large
    offsets causes no restart in the first place; together the two keep
    RFC 8633 section 5.2's attack from applying.
  * *Explicit operator recovery.* When the clock has been set wrong this
    boot, the operator reboots the machine, which starts cold again;
    `service ntpd restart` does not, unlike restarting FreeBSD's ntpd
    with `-g`. Recovery without a reboot is
    [open](#open-decisions).
* **Two samples in a row** stand in for RFC 5905's stepout: one exchange
  whose delay is asymmetric cannot step the clock, and a real offset is
  stepped one poll interval after it appears. They are a filter against
  one bad measurement from an honest server, not a bound on what a server
  can do ([Security](#security)).
* **No slew, and what that means for accuracy.** Offsets of 128 ms and
  less are left alone, and larger ones are stepped. The clock's error
  after a step is the stepping sample's error, which its distance bounds
  for an honest server; from then on it grows by the counter's drift, and
  is stepped back once it exceeds 128 ms in two samples in a row. So the
  128 ms band is not a bound on the error from UTC: the sample's distance,
  the counter's drift between polls, up to 1024 s apart, and polls
  missed while servers are silent all add to it, and a server's own error
  is not measured at all. Slewing needs the time page to carry a rate, a
  kernel mechanism, and no consumer of T-R1 needs it; this departs from
  FreeBSD, whose ntpd slews below 128 ms. The clock can step backward:
  ERTS keeps Erlang monotonic time and timers unmoved, and `os:system_time/1`
  readers see the step.
* **Leap seconds are not inserted.** The LI field is used only to reject
  an unsynchronized server. After a leap second the clock is a second
  off and the next two samples step it back.

## The client

### Server list

The list is an ordered list of at most 8 entries, each a host name (the
resolver's rule for a search domain: labels of letters, digits and
hyphens, 1 to 63 bytes each, 253 in all) or an IPv4 literal. A pool name
resolves to several addresses, used in the order DNS gives them, which
the pool randomizes. The list is the operator's alone: it is the app's
start flags, and no manifest ships a default
([Configuration](#configuration)). The client never takes servers from
DHCP, as FreeBSD's dhclient does not ask for them.

The client uses one address at a time, as RFC 4330's client does: it
does not select or combine servers as ntpd does with `minclock 3
maxclock 6`. Combining several servers is what lets a client outvote one
bad server; without it the server in use decides the time, which is the
residual of [Security](#security).

### Schedule

`erx_ntp_core` keeps, for the current address, a poll interval and a
deadline, and for the run, the addresses still usable:

* **Start.** The session resolves its names as soon as it runs; an
  answer with no address, or no answer, is retried after 15 s, doubling
  to 1024 s. The first poll of an address is a burst of up to four
  exchanges 2 s apart, RFC 5905's `iburst` spacing, and the poll's sample
  is the valid reply of least delay. Every later poll is one exchange.
* **Interval.** 64 s after the first sample, doubling after each valid
  sample up to 1024 s. The poll interval never falls below 64 s, which
  meets RFC 4330's floor of 15 s; the burst is within one poll, as RFC
  5905 defines it.
* **No reply.** An exchange waits 2 s for its reply. A poll with no
  valid reply moves to the next address at the next deadline. When every
  address of every name has failed once in a row, the client resolves the
  names again, no sooner than the shortest TTL of the last answers, and
  doubles the interval, up to 1024 s.
* **Kiss-o'-death.** `DENY` or `RSTR` removes the address for the rest of
  the run. `RATE` doubles that address's interval, up to 1024 s. Any
  other code, `X` codes included, discards the reply. A kiss is believed
  only after the match checks, 1 to 3 below, so an off-path host cannot
  silence a server.
* **Clock answers.** A held, stepped or refused sample is a success to
  the poll interval. An `{error, _}` answer leaves the interval as it
  was, so after a lost answer the next sample comes one unchanged
  interval later and the page tells the service whether the step was
  applied.

The waits are what T-R1 rests on: a server reachable at the start gives
a sample within the first burst; one that becomes reachable later is
found within the wait then in effect, at most 1024 s. The client watches
for no network event; a later design may connect the schedule to one
the network stack offers.

### Checks on a reply

`erx_ntp_wire:decode/1` takes a binary and answers a reply record or
`{error, Reason}`; it reads the first 48 bytes after one length check and
ignores what follows. It decodes root delay as a signed 16.16 number and
root dispersion as an unsigned one, so a root delay with the top bit set
reads as negative rather than as 18 hours. `erx_ntp_core` then checks a
reply for the outstanding exchange in this order, and drops it at the
first check that fails, counting the reason:

1. it came from the address and port the request went to; the socket is
   connected to them, so the stack delivers only such datagrams, and the
   core compares them as part of the exchange's key;
2. its originate timestamp equals the request's nonce;
3. mode 4 and VN 4, as sent.

A reply that passes these is the server's answer to this exchange, and
the exchange ends. If its stratum is 0 it is a kiss: the core acts on the
kiss code as [the schedule](#schedule) says and reads nothing else of it,
neither LI nor its undefined timestamps. Any other reply is a sample only
if all of these hold as well:

4. LI is not 3;
5. stratum is 1 to 15;
6. receive and transmit timestamps are non-zero, convert to times from
   1970 to 2104, and `t3 >= t2`;
7. the reference timestamp is not later than the transmit timestamp;
8. `delay >= 0`;
9. the distance `(max(rootdelay, 0) + delay) div 2 + rootdisp` is below
   `clock_distance_max_ns`, 1 s, RFC 5905's `MAXDIST`.

The distance clamps root delay at zero before adding the measured delay,
so a negative root delay cancels neither the delay this client measured
nor the server's dispersion; RFC 5905's own clamp,
`max(MINDISP, rootdelay + delay)`, would let it cancel the measured
delay. The sample sent to the facet carries this distance, so the client
and the facet hold the same limit.

Every field of a request is zero except LI 0, VN 4, mode 3 and the
transmit nonce, so the request says nothing of the client's clock or
state. Each exchange uses its own socket with its own random port and
nonce, and a second reply to an exchange is dropped, since the exchange
has ended.

## Configuration

The manifest declares the app and leaves it off, with no server:

```text
principal ntpd
  ...
session ntpd
  limits @limits.app
  runtime @artifact.emu
  release @artifact.ntpd
  args "..."
facet ntpd_net
  name "net"
  grantee @session.ntpd
  service @service.net
  ...
facet ntpd_clock
  name "clock"
  grantee @session.ntpd
  service @service.clock
  ...
start ntpd
  enable NO
```

The operator names the servers and enables the app in `/etc/rc.conf`,
as FreeBSD's `ntpd_flags` and `ntpd_enable` do:

```text
ntpd_enable="YES"
ntpd_flags="0.pool.example ntp.example.net"
```

`service ntpd enable` sets the first; `service ntpd restart` restarts
the session, through the start table alone. The facet row is the only
way a domain gets `clock`; root's session does not hold it.

`ntpd_flags` is the row's start flags, which
[design-apps.md](design-apps.md#start-flags) bounds and delivers: the
start table never reads them, and the session finds them, as they were
when it started, in the environment variable `ERX_START_FLAGS`.

`erx_ntpd` reads `ERX_START_FLAGS` once, splits it at spaces into at most
8 entries and checks each against the server-list rule above. Empty
flags, or flags that break the rule, end the session at start with `no
servers` or `bad flags` in its log and its row's last reason at
`/proc/apps`, and the start table's intensity leaves it down. Because no
manifest ships a server, enabling ntpd without naming one does this.

## What /proc shows

`abi/inspection.txt` gains a kind `clock`, reported by the service and
visible to every scope, at path `time`, so `cat /proc/time/status`
reads it. Each attribute names its source and its lifetime: the page
lives for the boot, and the service's record from the service's start,
`record_since`, to its next crash or restart.

| Attribute | Source, lifetime | Value |
| --- | --- | --- |
| `state` | page, boot | `unset` while `seq` and the offset are zero, so wall time is uptime counted from 1970-01-01; `boot` while `seq` is zero and the offset is not, the boot's real-time clock reading or the hosted backend's host clock; `set` once the page has changed this boot |
| `record_since` | record | monotonic time of the service's start, in seconds |
| `sample_at` | record | wall time of the last sample, or `none` |
| `offset_ns` | record | the last sample's `D`, signed |
| `distance_ns` | record | its distance |
| `stratum`, `server` | record | its server's stratum and address |
| `source` | record | the domain whose facet sent it, from the facet, never the request |
| `step_at`, `step_ns` | record | the last applied step's wall time and size, or `none` |
| `step_error` | record | the setter's refusal of the last step it refused, `unsupported`, `limit` or `badarg`, or `none` |
| `steps`, `refused` | record | steps applied and samples refused, floor and panic, since `record_since` |

After a restart of the service, `state` is still true, the record's
attributes are `none` until the next sample, and the counts start from
zero at the new `record_since`, so no count claims more history than the
service has. The client's own state, its names, addresses, delays and
kisses, is in its log lines, which the log service escapes; a kiss code
shown there is one of the known atoms or its four bytes in hex.

## Concurrency and failure

* **One writer.** Only `erx_clock` calls the NIF, one sample at a time
  in its own process, so the page's sequence has one writer in user
  mode, and the call's body serializes in the backend. The service reads
  the page, decides and sets within one sample's handling, so no other
  write falls between its read and its step.
* **Two clients** would interleave samples, each step to its own `W`.
  The manifest grants `clock` only to the ntpd template and the start
  table keeps at most one session of a row, so there is one.
* **Nothing is in flight that a failure must undo.** A sample's effect
  is the page, which the setter changes in one call or not at all; the
  facet and the client hold no state about it.

| Failure | Who sees it | Result |
| --- | --- | --- |
| the network domain restarts | the client, whose sockets end | the next poll opens a new socket on the new grant |
| the clock service crashes before the setter ran | the facet, which answers `{error, unavailable}` or `{error, failed}` | the page is unchanged; the client's next sample, one unchanged interval later, is decided afresh, and steps if the boot is still cold |
| the clock service crashes after the setter ran, before answering | the facet, which answers `{error, failed}` | the page holds `W`; the next sample is about 0 from it and is held. Either way nothing is lost, since the page is the state |
| the ntpd session crashes | the start table | restarted within the row's intensity; the page, not the session, says whether the boot is cold, so the restart renews no unrestricted step |
| a server sends offsets of 1000 s or more | the client, which gets `{refused, panic}` | logged and counted; the client polls on and does not end, so the refusal causes no restart |
| the clock was set wrong this boot | the operator, at `/proc/time` and the log | every later sample from a right server is refused `panic`; the operator reboots ([Steps](#steps)) |
| DNS fails | the client | retried with backoff; `/proc/time` keeps the last sample |
| every server is silent or denies | the client | backoff to 1024 s and re-resolution; the clock runs on its counter |
| the backend cannot set wall time | the clock service | `{error, unsupported}`; `step_error` is `unsupported` until the service restarts, and `state` shows the page as it is |
| the page's sequence runs out | the clock service | `{error, limit}`; wall time readers report it unavailable, and ERTS, which reads wall time on every `erts_os_system_time` call, ends (`sys_time.c`; [design-kernel.md](design-kernel.md), "Time") |

## Security

* **The parser runs in the app.** NTP bytes are decoded only by
  `erx_ntp_wire` in the ntpd session, which holds `net`, `clock` and
  `log`. A fault there ends that session. The system domain decodes a
  five-element tuple of bounded integers and an address through
  `erx_clock_facet:decode/1`, at the funnel's limits.
* **No sample leaves the clock's range.** The facet's bound on `W` is the
  setter's, and the setter refuses any other offset, so not even a
  compromised ntpd, nor a bug of the system domain, can publish a wall
  time outside `[0, 2^63)` (T-R7).
* **Whoever holds `clock` decides the time.** A compromised ntpd can
  fabricate every sample: any time above the floor at a cold start, and
  then up to 1000 s per two samples, forward or backward, without limit
  over time. The thresholds guard an honest client against one bad
  measurement, not the system against the client. On erXos's kernel the
  authority is the facet row; on the stopgap it is held, not enforced
  ([Phase 1](#phase-1)).
* **The server decides the time, and so does anyone on its path.** This
  is the residual, recorded in [design.md](design.md#residual-risks) and
  `TODO.md`. SNTP without authentication cannot tell a forged reply from
  a real one when the forger sees the request, and a client that uses one
  server passes on whatever that server says (RFC 8633 section 3.2). So a
  hostile server, or an attacker on the path to it, sets the clock to any
  time above the floor at a cold start, and afterwards walks it by up to
  1000 s every two polls, which no threshold refuses; it can also forge
  `DENY` and silence a server for the run. The panic threshold, the
  two-sample rule and the floor are filters on single corrections; they
  bound nothing cumulative, and a second's accuracy asked by T-R1 does not
  make a server trustworthy. A wrong clock can make an expired
  certificate look valid to [design-crypto.md](design-crypto.md)'s checks.
  Network Time Security (RFC 8633 section 4.3) is the remedy and is not
  designed here.
* **An off-path attacker** must guess a 64-bit nonce and a random source
  port, and send from the server's address and port, to have a reply or
  a kiss believed.
* **Text.** Kiss codes and server names reach the log only through the
  log service's escaping and `/proc` only through the inspector's;
  addresses are integers.

## Phase 1

On the Fiasco backend the setter is a service call that takes no
capability and checks no right: the dispatch hands the request to the
body without its caller (`liberx/backend/fiasco/service.c`, the
`ERX_FIASCO_CALL_TIME_SET_WALL` case), so any task's call writes the
page (`liberx/backend/fiasco/time_page.c`). That only the system domain
sets the clock is therefore held by the chokepoint and the facet, not
enforced, which is a residual of trusted code recorded in `TODO.md`;
erXos's kernel checks `WRITE` on the time page. The range check of
`erx_time_set_offset` is the body's own and holds on the stopgap as on
the kernel. The page starts zeroed, `seq` and offset included, so every
boot is cold and wall time counts from 1970-01-01 on QEMU `virt`, which
has a PL031 the stopgap does not read, and on the Raspberry Pi 4, which
has no real-time clock (`TODO.md`, platforms). The hosted backend reads
its offset once from the host's clock and keeps it
([design-stopgap.md](design-stopgap.md), "The hosted backend"), so its
`state` is `boot`; its setter answers `ERX_ENOTSUP`. The tree's hosted
backend defines no setter at all, a gap recorded in `TODO.md`.

## Verification and testing

Host tests run the pure modules under EUnit; each names the seeded fault
that proves it ran.

| Test | Passes when | Seeded failure |
| --- | --- | --- |
| era conversion | timestamps with the top bit set map to 1968-2036 and clear to 2036-2104, on vectors either side of 2036-02-07 06:28:16 | treating every timestamp as era 0 fails the 2036 vectors |
| offset at boot | `m1`, `m4` of a few seconds of uptime and `t2`, `t3` in 2026, 56 years apart, give the exact `W` | taking `(T2 - T1) + (T3 - T4)` in 64-bit 32.32 fixed point, as RFC 5905 section 8 warns against past 34 years, wraps by 2^32 s |
| offset and delay | fixed vectors give `W` and `delay` to the nanosecond | dropping the `div 2` doubles `W` |
| reply checks | each of checks 1 to 9 refuses a reply built to break only it, with its reason | removing the nonce comparison accepts the foreign-nonce reply |
| kiss-o'-death | `DENY` and `RSTR` remove the address, `RATE` doubles its interval, `XFOO` and `INIT` are discarded; a kiss with LI 3 and zero timestamps is still acted on; a kiss with a foreign nonce is dropped | running check 4 before the kiss branch ignores the LI-3 `RATE`; believing a kiss before the nonce check silences the server on the foreign-nonce kiss |
| distance | a reply with root delay -4 s, dispersion 2 s and measured delay 0.1 s is refused; one with root delay -4 s, dispersion 0 and measured delay 0.1 s has distance 0.05 s | adding the signed root delay unclamped accepts the first |
| decide | every row of [Steps](#steps), over `Cold`, the floor, the three distance bands and the three `excess` values | dropping the two-sample rule steps on a single 200 ms sample; dropping the floor row steps a cold clock to 1999 |
| restart | a record emptied as a restarted service's is, with `Cold` false, refuses a sample 2000 s off | deciding cold from an empty record instead of the page steps it |
| schedule | over generated event sequences, no two polls to an address closer than 64 s, a burst only on an address's first poll, re-resolution not before the TTL, and an error answer leaves the interval unchanged | a floor of 8 s fails the spacing property |
| flags | `ERX_START_FLAGS` values give their server lists; empty, nine entries, a bad label and a 254-byte name end with their reasons | accepting a ninth entry passes the nine-entry case |
| facet decode | every bound is refused one past its edge, `W` at `time_offset_max + 1` and `Distance` at `clock_distance_max_ns` included | dropping `W`'s upper bound accepts `time_offset_max + 1` |

The setter's range has a test of its own on the stopgap, in the native
guest's time case (`test/guest/native_space/guest.c`): offsets of 0 and
`time_offset_max` are stored and read back exactly by `erx_time_offset`,
and `time_offset_max + 1` and -1 answer `ERX_EINVAL` and leave the page
and its `seq` unchanged; the case also checks that `seq` is zero, so
`cold` true, before its first set and false after. *Seeded failure:* a
body that stores `offset_ns` less a monotonic reading, as
`erx_fiasco_time_set_wall_body` does, fails the exact read-back.

Fuzz targets, run by `make check-fuzz`:

* **`erx_ntp_wire_fuzz`** feeds arbitrary binaries of up to 1 KiB to
  `erx_ntp_wire:decode/1` and every accepted reply to the core's checks
  against a fixed outstanding exchange. Properties: nothing raises; an
  accepted header re-encodes to its 48 bytes; every accepted timestamp
  converts within 1970 to 2104; every accepted sample's distance is below
  `clock_distance_max_ns`. Seeds are generated by the test from the
  encoder: a valid reply, each kiss code, a reply with a MAC, one byte
  short, a negative root delay. *Seeded failure:* removing the length
  check makes a 47-byte seed raise.
* **`erx_clock_facet_fuzz`** feeds arbitrary terms, as the funnel decodes
  them, to `erx_clock_facet:decode/1`, as `erx_log_facet_fuzz` does.
  *Seeded failure:* accepting a `Stratum` of 0 fails the property that an
  accepted sample is within every bound.
* **`erx_ntpd_flags_fuzz`** feeds arbitrary binaries of up to 2 KiB, as
  `ERX_START_FLAGS`, to the client's flags reader. Properties: nothing
  raises; an accepted list has at most 8 entries, each within the
  server-list rule. *Seeded failure:* dropping the 253-byte bound accepts
  a generated 254-byte name.

The QEMU `virt` suite runs the client end to end. The harness's network
plan already joins a raw-frame `dgram` backend to the guest's link
(`tools/lib/erx/qemu.rb`, `nic_arguments`), and its test peer answers
ARP for `HOST_IP` and builds checksummed UDP replies from it
(`tools/lib/erx/net_device_name_server.rb`, which answers DNS on port
53). That peer gains an NTP answer on port 123, so one peer serves both;
the NTP answer is a function from the request and a script to a reply:
the request's transmit timestamp as the originate, receive and transmit
times from a clock the script sets, and the script's LI, stratum and
kiss code. The guest's test manifest enables ntpd with
`ntpd_flags="10.0.2.100"`, the peer's address, and the cases are:

* **Bootstrap.** The peer's clock reads 2030-01-01 plus the time since
  the run began; within one burst `/proc/time/status` is `set`,
  `os:system_time(second)` in another domain is within 1 s of the peer's
  clock at once, and `erlang:system_time(second)` there within 75 s.
  *Seeded failure:* a decoder that reads the transmit timestamp from the
  reference field's offset leaves the guest's time away from the peer's.
* **Restart.** After the bootstrap the peer's clock jumps two hours
  ahead and the test kills the ntpd session and then the clock service;
  the start table and the supervisor restart them, every later sample is
  refused `panic`, `refused` counts them, and the guest's time stays
  within 1 s of where it was. *Seeded failure:* a clock service that
  decides `Cold` from its empty record steps the clock two hours.
* **Held and stepped.** The peer moves 500 ms ahead: the first sample is
  held, the next stepped. *Seeded failure:* the decision without the
  two-sample rule steps on the first.
* **Kiss.** The peer answers `RATE`, then `DENY`: the next request comes
  one doubled interval later, then none. *Seeded failure:* a kiss check
  after check 4, with the peer's kiss carrying LI 3, ignores both.
* **Refusals.** A session without the facet row has no `clock` name;
  `ntpd_flags=""` ends the row with `no servers` and leaves it down.

The network runs against real NTP use the stack's development-host
peers
([design-network-stack.md](design-network-stack.md#the-stack-on-a-development-host)):
the client and the stack run on the host's own OTP over a tap device on
the FreeBSD x86-64 test host, with the clock facet replaced by a recorder
of samples. FreeBSD's ntpd in the jail `erxpeer0` is the interoperability
oracle. A jail shares its host's clock, so the expected `W` is the host's
own wall time minus monotonic time: the first sample agrees within 10 ms,
and a second run agrees again. *Seeded failure:* swapping `t2` and `m1`
in the offset fails the agreement.

The Raspberry Pi 4 checklist: with Ethernet and DHCP, set `ntpd_flags`
to a reachable server and `service ntpd enable`; within a minute
`/proc/time/status` is `set`, and a new file's time in `ls -l` matches a
reference clock within a second.

## Alternatives considered

* **The client in the system domain**, holding `WRITE` itself. It would
  put NTP parsing in the trusted base, which decision 19 forbids.
* **The client in the network domain,** beside DHCP. The domain that
  parses every packet would also hold the clock, and the stack would stop
  being an OTP application with no erXos authority in it.
* **Giving the app the time page's `WRITE` right.** No clock record in
  one place for `/proc`, two policies if a second time source comes, and
  on the stopgap no difference from any task's call.
* **A relative facet, "add this much".** It applies twice if repeated
  and depends on the wall clock not moving between measurement and
  arrival; the absolute `W` has neither problem.
* **The step rule in the client.** It works, since the client is trusted
  with the time anyway, but then `/proc` needs the app's own inspection
  attributes; a service-side rule gives one record for every source.
* **A first-sample flag per grant, or per service record.** Either is
  consumed at some moment, and a crash between consuming it and applying
  the step either loses the bootstrap for the boot or renews it at every
  restart, which is RFC 8633 section 5.2's attack. The page's `seq`
  holds the same fact without anyone consuming it.
* **A setter that takes a wall time.** The time between the caller's
  reading of the monotonic clock and the body's own reading is lost from
  the stored offset, unbounded when the caller is descheduled; an offset
  argument has nothing to lose.
* **A second guest network for the time tests.** The existing peer on the
  guest's link already answers ARP and UDP; one more port is the whole
  addition.

## Decisions

These were open and are settled as stated here:

1. **No default server.** RFC 4330 item 5 allows a built-in server only
   if it is the vendor's own or used with the operator's permission, and
   RFC 8633 section 3.6 sends vendors to a zone of the NTP Pool of their
   own. erXos has none, so the manifests ship no server, and enabling
   ntpd includes naming one. Network time is off by default either way.
   An erXos vendor zone, when one exists, is the default to ship.
2. **The operator's servers are `ntpd_flags`**, a bounded start-row
   field delivered as opaque data ([Configuration](#configuration)),
   rather than a file in the ntpd principal's data directory, which would
   need a way for an administrator to write another principal's files,
   or the manifest only, which would need a rebuilt image to change
   servers.
3. **No slew.** The named consumers need a second, a slew needs a rate on
   the time page, a new kernel mechanism, and the accuracy this gives is
   stated in [Steps](#steps). erXos's kernel can add a rate if a consumer
   needs a wall clock that never steps after the first sample.
4. **The QEMU suite tests the client end to end** through the extended
   test peer, and FreeBSD's ntpd stays the interoperability oracle on the
   test host ([Verification and testing](#verification-and-testing)).

## Open decisions

1. **Recovering a wrong clock without a reboot.** After the clock has
   been changed this boot, only a reboot allows another unrestricted
   step. A recovery without one needs an operator command the clock
   service obeys, a `ctl` file of a tree the clock service serves and
   root mounts, with one command that makes the next sample cold, and its
   grammar, fuzz target and authority; `service ntpd restart` must not
   be that command, since an automatic restart takes the same path.
   Recommendation: not now; a reboot is the recovery that already exists,
   and the command can come with the first consumer that cannot reboot.

## References

* erXos's designs, linked where used: design-kernel.md ("Time"),
  design-network-stack.md, design-system.md, design-apps.md,
  design-log.md, design-domains.md, design-runtime.md, design-stopgap.md,
  design-crypto.md.
* erXos's tree: `liberx/backend/fiasco/time_page.c`,
  `liberx/backend/fiasco/time.h`, `liberx/backend/fiasco/service.c`,
  `otp/erts/emulator/sys/erxos/sys_time.c`,
  `otp/erts/emulator/sys/erxos/erl_unix_sys.h`,
  `otp/erts/emulator/sys/erxos/imports.txt`,
  `otp/erts/emulator/beam/erl_time_sup.c`,
  `otp/erts/doc/guides/time_correction.md`,
  `otp/erts/emulator/nifs/erxos/erx_watchdog_nif.c`,
  `erlang/apps/erx/src/erx_log_facet.erl`,
  `erlang/apps/erx_net_client/src/erx_gen_udp.erl`,
  `erlang/apps/erx_net/src/erx_udp.erl`, `abi/services/log.txt`,
  `abi/inspection.txt`, `abi/kernel.txt` (the time page),
  `config/manifest/qemu-virt-development.txt`, `tools/lib/erx/qemu.rb`,
  `tools/lib/erx/net_device.rb`, `tools/lib/erx/net_device_name_server.rb`,
  `otp/erts/etc/common/erlexec.c`, `test/guest/native_space/guest.c`.
* FreeBSD releng/15.1, commit `95719d8a895bf8170851e9844d9b4092b1d2b6fe`,
  from `https://git.freebsd.org/src.git`:
  * `libexec/rc/rc.conf`, SHA-256
    `44cc40aa3ddf9a2bbedcd4a93eac693fa6842d4664d3877ad8830e078da68ec8`;
  * `libexec/rc/rc.d/ntpd`, SHA-256
    `23305427f3ee243e956e9e94ef495df1cc075d13bdb3f69fc3f25c28a3f028c8`;
  * `usr.sbin/ntp/ntpd/ntp.conf`, SHA-256
    `f518111399afe23bc29e1812b27dcb2c967e629c4c4de4669b6482f2fff24121`;
  * `contrib/ntp/ntpd/ntpd.mdoc.in`, SHA-256
    `4e2b8f354b11f51b347046215d0963f468bdf937fae4bfae3f6bffb862dae301`;
  * `contrib/ntp/COPYRIGHT`, SHA-256
    `45b6e5a0a5f0ac4afdd9e23caa2241779e4da463e4dba32a41b4dbd61577b2a3`;
  * `release/tools/arm.subr`, SHA-256
    `d428bf01378a688a6c30b92a90598451538a180f52b99377f806e81bf163ac40`;
  * `sbin/dhclient/clparse.c`, SHA-256
    `115ea86f8a2b9550f03ddfbb8059fc13b2ed81e97fed7e5eb27c3764fa5ccac1`.
* RFCs from `https://www.rfc-editor.org/rfc/`: RFC 4330 (SNTPv4), SHA-256
  `e0a5344883d62f9ff58a6cf3a44398bda097badd3013236fab47ea7fdc25bc33`;
  RFC 5905 (NTPv4), SHA-256
  `8b7abd903c60202e2953ee012fefa6916666c3b0c71825c748cdd262024fb268`;
  RFC 8633 (NTP best practices; sections 3.2, 3.6, 4.3 and 5.2), SHA-256
  `fb275c82378be983511db4fcd533a92a54028c7762be2d9bc0d6fa5c06dc5a84`.
* The research record behind this design:
  `/Users/stas/erxos-scratch/notes/research-pi4-peripherals.md`, section 5,
  written 2026-11-14.
