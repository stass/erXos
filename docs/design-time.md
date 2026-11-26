# Network time

A machine without a battery-backed clock starts every boot near
1970-01-01, and file times, log lines and certificate checks are wrong
until something sets the wall clock. The clock service starts such a
clock at the build's date, an approximate time good enough for
certificate checks, and this document is the contract for
setting it from the network with SNTP, the simple subset of NTP that RFC
4330 specifies: who measures, who sets, what a step is, what the
operator configures and sees, and how it is tested. The kernel's clock
and its time page are [design-kernel.md](design-kernel.md)'s ("Time");
apps, the start table and `start.conf` are [design-apps.md](design-apps.md)'s;
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
  `ntpd_enable="YES"` and `ntpd_flags="SERVER ..."` in `/etc/start.conf`
  start it at boot against the operator's servers
  ([Configuration](#configuration)).
* **A clock with no reading starts at the build date.** When the clock
  service starts on a clock that reads before the build's date, the
  commit time of the image's source, it sets the clock to that date, and
  `/proc` shows it `approximate` until a sample or `date` sets it. So
  HTTPS works from boot without anyone setting the clock, at the cost of
  accepting a certificate that expired between the build and the real date
  ([The approximate start](#the-approximate-start)).
* **One unrestricted step per boot, then steps above 128 ms.** While the
  page is as the boot or the approximate start left it, a sample sets the
  clock whatever its distance, as `ntpd -g` allows once; never to a time
  before the floor, the build's date. After that an offset above 128 ms is stepped when two
  samples in a row show it in the same direction, an offset of 1000 s or
  more is refused, and smaller offsets are left alone. There is no slew
  ([Steps](#steps)).
* **The server decides the time.** Without authentication, the server
  the client uses, or anyone on the path to it, controls the wall clock:
  the thresholds filter one bad measurement, they bound nothing over time
  ([Security](#security)).
* **The operator sets the clock with `date`.** Root's session holds a
  `clock` grant, and `date [[[[[cc]yy]mm]dd]HH]MM[.SS]` sets the wall
  offset as FreeBSD's `date` sets the time, without the step rules; the
  change lasts until the next reboot
  ([Setting the clock by hand](#setting-the-clock-by-hand)).
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

### What the design rests on

* **The time page** is one read-only page every domain maps: the
  counter's scale and `wall_offset_ns`, "wall time minus monotonic time".
  A reader takes `seq`, the fields and `seq` again, so every runtime
  reads wall time without a kernel call. The system domain corrects it
  with the setter, which needs `WRITE` on the time page
  ([design-kernel.md](design-kernel.md), "Time"). The setter is
  `erx_time_set_offset`, which stores the offset it is given
  ([The construction](#the-construction)).
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
  (OTP 29.1.2's `erts/doc/guides/time_correction.md`); no manifest's runtime
  arguments set `+C`. ERTS's time supervisor compares OS system time with
  Erlang system time every 60 s (`ERTS_LONG_TIME_CORRECTION_CHECK`,
  15 s for a while after a change) and moves its time offset when they
  differ by more than twice `small_diff`, 50 us for a nanosecond clock
  (`otp/erts/emulator/beam/erl_time_sup.c`, `check_time_correction` and
  the `adj.large_diff` setup). So `os:system_time/1` shows a step at once
  in every domain, and `erlang:system_time/1` within about a minute;
  Erlang monotonic time and timers do not move.
* **UDP and DNS in an app.** A session that holds `net` opens
  `gen_udp` sockets through `erx_gen_udp`, IPv4 only, with
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
  defaults, and `/etc/start.conf` sets `NAME_enable`, `NAME_display`,
  `NAME_restarts`, `NAME_restart_period_s` and `NAME_flags` over it
  ([design-apps.md](design-apps.md#the-start-table)).

## Requirements

* **T-R1.** With network time enabled, and the network and a server
  reachable when the client starts, wall time agrees with the server's
  within a minute, provided a reachable server is among the first four
  addresses its names give and no name whose resolution times out comes
  before it ([the schedule](#schedule) prices what comes before); when they become reachable later, within the retry
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
* **T-R9.** Root can set the wall clock by hand, with FreeBSD's `date`
  forms and without a network, and no session without a `clock` grant
  can.

Not required, and not built: full NTP (selecting and combining several
servers, frequency discipline, symmetric and broadcast modes, serving
time to others), leap-second insertion, authentication, and taking
servers from DHCP.

## The construction

**A sample is the wall offset the server implies.** The client sends a
request at monotonic time `m1`, from `os:perf_counter(nanosecond)`, and
takes the reply at `m4`. It converts the reply's receive and transmit
timestamps once, when it checks the reply, to integer nanoseconds since 1970 by RFC
4330's era convention, `t2` and `t3`. Then

```text
delay = (m4 - m1) - (t3 - t2)
W     = ((t2 - m1) + (t3 - m4)) div 2
```

`W` is the server's time minus the kernel's monotonic time, which is
exactly the time page's `wall_offset_ns`. The clock service sets the
clock by storing `W` in the page: `erx_time_set_offset(time_page,
offset_ns)` writes `offset_ns` as the page's offset, unchanged, so no
time between measuring and storing, a descheduled caller or,
on Fiasco, the crossing to its service included, changes what is stored.

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
through `erx_time_offset`, and takes **cold start** to mean that only
the boot changed the page, `seq = 0`, or only the approximate start did,
which leaves the offset exactly the floor
([The approximate start](#the-approximate-start)). No party holds this
state, so no crash, restart or lost answer can renew or lose it (T-R8).

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
  service's answer) and returns the next actions, with its next
  deadline answered by `next_deadline/1` ([design.md](design.md#drivers-and-dma), "Deadlines in state"), and a
  thin effect process that reads its start flags, resolves names, opens
  sockets, sends, receives and calls the facet. The packet codec,
  `erx_ntp_wire`, is pure and the only reader of NTP bytes; it and the
  checks of one reply, `erx_ntp_sample`, are modules of the `erx` library
  application, which root's `ntpctl` calls too
  ([Setting the clock from a server once](#setting-the-clock-from-a-server-once)).
* **The clock service**, `erx_clock`, a system service of the system
  domain under its own supervisor, `erx_clock_sup`, is the setting side. For
  each sample it reads the page through `erx_clock_nif:read/0`, runs
  `erx_clock_core:decide/4`, a pure function from the request, its
  source domain, the page and its record to an action and the next
  record, performs a step through `erx_clock_nif:set_offset/1`, and
  answers the inspector for
  `/proc/time`. A crash restarts it with an empty record and loses only
  the record's history; no grant ends, and every decision reads the
  clock's state from the page ([What /proc shows](#what-proc-shows)).
  `erx_clock_sup` is an `erx_service_sup`, as the log service's
  `erx_syslog_sup` is ([design-log.md](design-log.md#service-lifetime-and-restart)):
  it is the server of `clock`, so the facets stand in front of it and
  outlive the service's restarts; it restarts the service at most four
  times an hour; and it is a `temporary` child of `kernel_safe_sup`,
  started before the domain service, so its end is neither restarted nor
  counted there. Past that intensity it ends, and with it every clock
  facet ([Concurrency and failure](#concurrency-and-failure)).
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
  call fails, on Fiasco as on erXos's kernel ([On Fiasco](#on-fiasco)).

Why an app and not the network domain: the network domain is the stack,
an OTP application usable outside erXos, and the domain that parses every
packet would then also hold the clock. A separate app keeps the clock's
authority with a domain whose only input is NTP replies, and it is the
start table's row that `ntpd_enable` switches. Why not the system
domain: it parses no network traffic, and the facet keeps it that way;
the clock service reads three bounded integers and an address.

## Interfaces

### The clock facet

`abi/services/clock.txt` declares `service clock` with two operations,
`sample`, ntpd's, and `set`, the operator's
([Setting the clock by hand](#setting-the-clock-by-hand)), and the limit `clock_distance_max_ns`, 1 s, RFC 5905's
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

The operator's request is `{set, W}`, with `W` in the same range, which
`decode/1` admits by the same rules and forwards as `{set, Grantee, W}`.
Each facet row grants one of the two operations, by its `operations`
list ([design-abi.md](design-abi.md), the facet record's operations
span): ntpd's row `sample` alone and root's `set` alone, so ntpd cannot
set and root's sessions send no samples, and the facet refuses an
operation its row does not grant with `{error, eperm}` before it forwards
anything ([Who may set it](#who-may-set-it)). `erx_clock_facet:operation/1`
names the operation of what `decode/1` admits and nothing else, so the
operation check and the decode cannot read one request two ways, and a
request `decode/1` refuses is `{error, badarg}` whatever its row grants. A row's `operations` reach the
facet by the manifest's own path: the manifest compiler resolves each
name against `abi/services/clock.txt` into the facet record's operations
span, the boot's reader of the manifest checks each number against the
interface's declared operations, and the facet admits only the operations
the list names, so a row of `operations none` admits nothing
([design-domains.md](design-domains.md#facets)).

The answer is `{ok, Action}`:

| Action | Meaning |
| --- | --- |
| `{stepped, StepNs}` | the page now holds `W`; the clock moved by `StepNs`, signed |
| `held` | the sample is recorded and the clock left alone |
| `{refused, floor}` | the sample's time is before the floor, the build's date; nothing changed |
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

`otp/erts/emulator/sys/erxos/imports.txt` holds a section
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

Every row also stores the sample, its time, wall and monotonic, its
source and the row it took, its verdict, as the last sample. A step that the setter refuses stores the refusal as the last
step error and answers it; a step it applies stores its time and size
and counts it.

* **The floor.** `floor` is the build's date, the commit time of the
  image's source that the build facts carry
  ([The approximate start](#the-approximate-start)), so no sample sets
  the clock before the software it runs was written, as RFC 8633 section
  5.2 asks of implementations. A build that could not read its commit,
  from a tree that is no git checkout, has no floor: it refuses no
  sample and starts no clock.
* **Three ways a clock is set, told apart by the page.**
  * *Initial bootstrap.* While `Cold`, the page is as the boot published
    it, at the epoch or at the real-time clock's reading, or as the
    approximate start left it, at the build's date. The sample steps whatever its distance, as
    `ntpd_sync_on_start=YES` makes FreeBSD's first one. erXos does not
    offer the `NO` setting: every boot without a real-time clock starts
    at the build date, as far from the server as the image is old, so the
    client could not set the clock once that passed 1000 s.
  * *Automatic restart.* A crash and restart of the ntpd session or of
    the clock service changes nothing on the page, so the next sample
    meets the panic threshold if the clock was changed this boot. A
    panic refusal does not end the client, so a server that sends large
    offsets causes no restart in the first place; together the two keep
    RFC 8633 section 5.2's attack from applying.
  * *Explicit operator recovery.* When the clock has been set wrong this
    boot, the operator sets it right with `date`
    ([Setting the clock by hand](#setting-the-clock-by-hand)), or reboots
    the machine, which starts cold again; `service ntpd restart` does
    not, unlike restarting FreeBSD's ntpd with `-g`. Making the next
    sample unrestricted again without a reboot is
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

## The approximate start

A board without a real-time clock the system domain reads, the Raspberry
Pi 4 without a module, boots at 1970-01-01, where every certificate a public authority issues is not yet
valid, so nothing reaches live data over TLS until someone sets the
clock. The build knows a better time: the image cannot run before its
source was committed. So the clock service, when it starts, sets a clock
that reads before that date to it.

* **The date is a build fact.** The build facts file of each release,
  which `uname -v` reads (`erx_build`, `tools/lib/erx/build_facts.rb`),
  carries `date`, the commit time of the image's source in seconds since
  the epoch, read from git. It is a fact of the commit, not of the moment
  of the build, so two builds of one commit stay byte-identical
  (`make check-reproducible`). `erx_clock_core:build_floor/1` turns it into the
  floor in nanoseconds, the one value both the start and the
  [Steps](#steps) table's floor row use; a build without the date has
  floor 0.
* **The start.** `erx_clock_core:start/2` answers a step to offset
  `floor`, wall time "the build's date plus the uptime", when the page is
  cold (`seq = 0`) and reads before the floor, `M + C < floor`; for any
  other page, `none`. The service applies it through the setter once, in
  its `init`, before any facet's request, and logs one line with the
  date. A clock the boot set at or past the floor, from a real-time
  clock or the hosted backend's host clock, is left as it is, so the
  start never moves a clock backward; one whose real-time clock reads
  before the floor, a module with a flat battery, starts at the floor
  too.
* **The state is the page's.** `erx_clock_core:state/2` reads
  `approximate` from a page whose `seq` has moved and whose offset is
  exactly the floor, the only change the start makes. So a restarted
  service finds the page approximate, or set if anything changed it
  since, and starts nothing: a restart can neither undo a set nor renew
  the start. A step that lands on exactly the floor's offset, to the
  nanosecond, reads as approximate too, and so makes the next sample
  unrestricted again: root can do that with a set of exactly that
  offset, and a holder of `sample` by steering its samples onto it,
  which an attacker on the network cannot, since `W` depends on the
  client's own counter readings. Telling the start's one write from
  any other by the page's sequence closes it (`TODO.md`).
* **Approximate is cold.** A sample meets an approximate clock as it
  meets one the boot left alone: the first steps whatever its distance,
  since a build may be months older than the real date. A set by hand
  replaces it like any other clock, and `date` below the floor stays the
  operator's word ([What it changes](#what-it-changes)).
* **Readers.** `date` writes the wall time as FreeBSD's does, so at boot
  it writes the build's date plus the uptime; `/proc/time/status` shows
  `state` `approximate`, and the desktop clock the time with the caption
  "approximate, from the build date"
  ([design-desktop-programs.md](design-desktop-programs.md#clock)).

**What it costs.** Certificate validity is checked against the wall
clock ([design-crypto.md](design-crypto.md#time)), and validation treats
an approximate clock as a set one: that is its point. A certificate that
expired after the build date but before the real date is therefore
accepted until something sets the clock; a certificate not yet valid at the build date
but valid at the real date is refused. The window is the image's age.
For development builds and 0.1, trusted code on a machine its operator
watches, that is accepted; whether a release build keeps the start, or
refuses TLS on an approximate clock, is [open](#open-decisions).

## The real-time clock at boot

A machine whose manifest gives the system domain a real-time clock the
system domain can read sets the clock from it at boot, so its time is
exact from the first second rather than the build's date. QEMU `virt`
has one, the Arm PrimeCell RTC PL031 at `/pl031@9010000`, which QEMU
starts at the host's time; the Raspberry Pi 4 has none of its own.

* **The device is the system domain's by the manifest.** The platform
  record's `rtc` unit holds the PL031, a device of kind `rtc` and
  compatible string `arm,pl031` (`include/erx/device_kinds.h`), and the
  manifest's `unit rtc` row names the system domain its holder, so the
  root writes the system domain a given record of role `rtc` and
  peripheral `pl031` ([design-system.md](design-system.md), property 8).
* **The keeper is a driver.** `erx_rtc_pl031`, in the `erx_rtc`
  application of the real-time clocks' device class
  ([design-header-io.md](design-header-io.md#drivers)), is the system
  domain's wall-clock keeper: started once at boot by `erx_rtc_sup`, a
  temporary child for each record, it opens the record through
  `erx_device` and reads the data register, `RTCDR`, the clock's count
  of seconds (Arm DDI 0224C, section 3.3). Its hardware description,
  `hw/svd/pl031`, names `RTCDR` alone, so the driver can reach no
  register that changes the clock, and erXos never writes it. It sends
  the clock service `{rtc, Source, Wall}`, `Wall` the reading in
  nanoseconds and `Source` the system domain, and leaves no process
  behind.
* **The clock service decides it.** `erx_clock_core:decide/4` takes
  `{rtc, Wall}` in one step with the page it reads when the request
  arrives: on a clock with no time of its own, state `unset`, or the
  [approximate start](#the-approximate-start)'s `approximate`, a
  reading at or past the floor steps the clock to read `Wall`, and the
  clock is `set`; a reading
  before the floor, or before the uptime since 1970 where the build has
  no floor, is refused `floor` and changes nothing, so a clock with a
  flat battery or a hostile reading never moves the clock below the
  floor; on a clock that already has a time, the boot's own reading
  (`boot`) or a set this boot by `date` or `ntpd` (`set`), it is
  refused with that state, since the reading is a start, not a
  correction, so a second source never steps a clock that has a time
  at or past the floor. It is
  no facet's request: `erx_clock_facet` admits only `sample` and `set`,
  so only the system domain's own processes send it.
* **What a reading can do.** The PL031 is a device of the machine, as
  trusted as the machine's other devices: a reading picks any time from
  the floor to 2106, the largest count its 32 bits hold, and the
  certificate checks of [design-crypto.md](design-crypto.md#time) then
  run against it until `date` corrects it. Every later sample meets a
  `set` clock, so `ntpd` steps it only while it is within the
  [Steps](#steps) table's 1000 s and refuses a larger error `panic`;
  a reading more than 1000 s wrong stays until root's `date` sets the
  clock ([TODO.md](../TODO.md)).
* **Deterministic mode** starts the PL031 at 2026-01-01
  ([design-fiasco.md](design-fiasco.md#deterministic-mode)), before any
  build's floor, so the reading is refused and the clock keeps the
  approximate start, as the transcript needs.
* **A machine without one,** the Raspberry Pi 4 without a module, has no
  `rtc` unit, no record and no keeper, and keeps the approximate start;
  the DS3231 module's `/dev/rtc` is the same keeper's other source
  ([design-header-io.md](design-header-io.md#devrtc)), which
  [TODO.md](../TODO.md) holds. On erXos's kernel, which reads the PL031
  itself at boot ([design-kernel.md](design-kernel.md), "Time"), the
  page arrives `boot`, so a keeper's reading is refused `boot` and
  changes nothing; where the kernel's reading falls before the floor,
  the start leaves the clock `approximate` and the keeper's reading,
  from the same device, is refused `floor` too.

## The client

### Server list

The list is an ordered list of at most 8 entries, each a host name (the
resolver's host-name rule, `erx_host_name:host_name/1`: labels of letters,
digits and hyphens, 1 to 63 bytes each, neither starting nor ending with
a hyphen as RFC 1123 has it, 253 in all, and no trailing dot) or a
dotted-decimal IPv4 literal, which that rule takes too. The rule is
`erx_ntp_exchange:servers/1`, which `ntpctl step` applies to its
operands too, so no flag is taken for a server. A pool name
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

* **Start.** The session starts a round as soon as it runs. A round
  resolves the names one at a time, in the list's order, and polls the
  usable addresses of a name before it resolves the next, so the first
  address found is polled as soon as its name resolves and a name whose
  resolution times out delays only the names after it. A round that
  ends with no usable address, none found or every one denied, starts
  again after 2 s while the run has polled no address, at most 30
  times, and otherwise after 15 s, doubling to 1024 s. Before the first
  poll a round that finds nothing is most often a network that has no
  address yet, whose resolver has no name server to ask: the 2 s wait
  asks again within 2 s of the address, and the bound of 30 rounds, a
  minute of waits, holds what a name list that never resolves costs its
  name servers to 30 rounds, each resolving every name, more than the
  backoff would make. An IPv4 literal, or a name the hosts file holds,
  resolves without the network, so its first poll ends the quick
  rounds and a network that gets its address later is found only after
  the poll interval's backoff. The first poll of an address is a burst of up to four
  exchanges 2 s apart, RFC 5905's `iburst` spacing, and the poll's sample
  is the valid reply of least delay. Every later poll is one exchange.
* **Interval.** 64 s after the first sample, doubling after each valid
  sample up to 1024 s. The poll interval never falls below 64 s, which
  meets RFC 4330's floor of 15 s; the burst is within one poll, as RFC
  5905 defines it.
* **No reply.** An exchange waits 2 s for its reply. A poll with no
  valid reply moves to the next address: at once when that address has
  never been polled, since its first poll is the burst and no wait
  spaces it from an earlier one, and otherwise at the next deadline.
  When every address resolved so far has failed once in a row, the next
  name is resolved at once; when every address of every name has, the
  client doubles the interval, up to 1024 s, and starts a new round
  after it. The session's resolver (`inet:getaddrs/3`) answers no TTL,
  so the doubled interval, at least 128 s, stands in for the shortest
  TTL of the last answers; a resolver call that answers TTLs is in
  `TODO.md`. The run keeps one interval, which moves with the address in
  use, and the burst's 2 s spacing runs from the end of one exchange to
  the start of the next. The client remembers the last 64 addresses it
  polled, so a pool that rotates its addresses cannot grow its state.
* **Kiss-o'-death.** `DENY` or `RSTR` removes the address for the rest of
  the run, and the client moves to the next address as after a poll with
  no reply. The client remembers at most 32 denied addresses, a bound
  of `erx_ntp_core`'s own, and [`/svc/ntpd/status`](#what-ntpd-serves)
  shows them. Once that
  list is full it fails closed: it admits only addresses it has polled,
  which no denial has removed, so a denial past the bound needs no
  record and no denied address is polled again, while the state stays
  bounded. A resolver that names 32 denying servers, or a pool whose
  servers deny that often, thereby leaves the run only the addresses it
  has polled, and none once the answers stop naming them; ending the run
  instead would forget the denials at its restart. A resolver can end
  network time anyway by answering no address, and `/svc/ntpd/status`
  shows the full `denied` list. `RATE` doubles that address's interval, up to 1024 s. Any
  other code, `X` codes included, discards the reply. A kiss is believed
  only after the match checks, 1 to 3 below, so an off-path host cannot
  silence a server.
* **Clock answers.** A held, stepped or refused sample is a success to
  the poll interval. An `{error, _}` answer leaves the interval as it
  was, so after a lost answer the next sample comes one unchanged
  interval later and the page tells the service whether the step was
  applied.

The waits are what T-R1 rests on: a server reachable at the start gives
a sample within the first burst of its address, and each silent address
polled before it costs that address's burst, four exchanges and three
gaps, at most 14 s, and each name resolved before it its resolution, at
most 10 s. So with the default `pool.ntp.org`, whose answer the client
cuts to 4 addresses, the first sample comes within the minute even when
the first three addresses are silent: 42 s of silent bursts after at
most 10 s of resolution, then the reachable address's own burst, whose
last exchange starts 6 s after its first, about 58 s in all. A reachable server later than the fourth address,
or a name whose resolution times out ahead of it, delays it past the
minute, since the client asks one address at a time
([Server list](#server-list)). One that becomes
reachable later is found within the wait then in effect, at most
1024 s, and within 2 s of the network's address when the network gets
one during the first 30 rounds and the names are resolved through DNS. The client watches
for no network event; a later design may connect the schedule to one
the network stack offers.

### Checks on a reply

`erx_ntp_wire:decode/1` takes a binary and answers a reply record or
`{error, Reason}`; it reads the first 48 bytes after one length check and
ignores what follows. It decodes root delay as a signed 16.16 number and
root dispersion as an unsigned one, so a root delay with the top bit set
reads as negative rather than as 18 hours. `erx_ntp_sample:check/4`, which
`erx_ntp_core` and `ntpctl` both call, then checks a reply for the
outstanding exchange in this order, and drops it at the
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
7. the reference timestamp is not later than the transmit timestamp,
   a zero reference timestamp meaning none;
8. `delay >= 0`;
9. the distance `(max(rootdelay, 0) + delay) div 2 + rootdisp` is below
   `clock_distance_max_ns`, 1 s, RFC 5905's `MAXDIST`;
10. the wall offset `W` the timestamps imply is one the time page holds,
    0 to `time_offset_max`, counted as check 6's drop: a server time
    earlier than the client's uptime since 1970 implies a negative `W`,
    which the clock facet would refuse as `badarg`.

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
  serves svc
facet ntpd_net
  name "net"
  grantee @session.ntpd
  service @service.net
  ...
facet ntpd_clock
  name "clock"
  grantee @session.ntpd
  service @service.clock
  operations sample
  ...
start ntpd
  enable NO
```

The operator names the servers and enables the app in `/etc/start.conf`,
as FreeBSD's `ntpd_flags` and `ntpd_enable` do:

```text
ntpd_enable="YES"
ntpd_flags="0.pool.example ntp.example.net"
```

`service ntpd enable` sets the first; `service ntpd restart` restarts
the session, through the start table alone. The facet rows are the only
way a domain gets `clock`: ntpd's template holds one and root's another
([Who may set it](#who-may-set-it)), and no other template does.

`ntpd_flags` is the row's start flags, which
[design-apps.md](design-apps.md#start-flags) bounds and delivers: the
start table never reads them, and the session finds them, as they were
when it started, in the environment variable `ERX_START_FLAGS`.

`erx_ntpd` reads `ERX_START_FLAGS` once, splits it at spaces into at most
8 entries and checks each against the server-list rule above. Empty
flags, or flags that break the rule, end the session at start with `no
servers` or `bad flags` in its log and its row's last reason at
`/proc/svc`, and the start table's intensity leaves it down. Because no
manifest ships a server, enabling ntpd without naming one does this.

**The Raspberry Pi 4 development image** is the one exception to
[decision 1](#decisions): the board has no real-time clock, its demo
shows the time, and its manifest (`config/manifest/raspi4b-development.txt`)
declares ntpd enabled with `pool.ntp.org`, so the board's wall clock is
right within one burst of the network coming up. No other manifest names
a server, and a release image ships none. Until the start table carries
a row's `flags` ([design-apps.md](design-apps.md#start-flags)), the ntpd
session template's own environment sets `ERX_START_FLAGS`, which is the
same variable ntpd reads, so moving the value to the row changes the
manifest and nothing in ntpd; that stand-in, and the boot view's refusal
of a template that sets the variable, which it postpones, are recorded
in `TODO.md`.

## What /proc shows

`abi/inspection.txt` declares a kind `clock`, visible to every scope, at
path `time`, so `cat /proc/time/status` reads it. Five attributes are
visible only to the whole-machine scope (`visible all`): `server`, the
address the client samples, `source`, the id of the domain whose facet
sent the sample, `step_source`, the one whose facet sent the last
step, and `sample_from` and `step_from` below, which name the server,
all facts of another domain, so a scoped caller
reads the record without them. The inspector reads `state` from the page
through `erx_clock_nif:read/0`, reported by `kernel`, whose object the
page is; the clock service reports the rest. Each attribute names its
source and its lifetime: the page lives for the boot, and the service's
record from the service's start, `record_since`, to its next crash or
restart.

| Attribute | Source, lifetime | Value |
| --- | --- | --- |
| `state` | page, boot | `unset` while `seq` and the offset are zero, so wall time is uptime counted from 1970-01-01, which a running clock service leaves only on a build without a date; `boot` while `seq` is zero and the offset is not, the boot's real-time clock reading or the hosted backend's host clock; `approximate` while the offset is the floor, as [the approximate start](#the-approximate-start) leaves it, or `unset` or `boot` where the setter refused the start, so wall time is the build's date plus the uptime; `set` once anything else has changed the page this boot |
| `record_since` | record | monotonic time of the service's start, in seconds |
| `sample_at` | record | wall time of the last sample, or `unknown` |
| `offset_ns` | record | the last sample's `D`, signed |
| `sample_wall_offset_ns` | record | the last sample's `W`, the wall offset it gives, which `ntpctl step` sets ([Setting the clock from a server once](#setting-the-clock-from-a-server-once)) |
| `sample_verdict` | record | the row of [Steps](#steps) the last sample took: `step`, `hold`, or its refusal, `floor` or `panic`; a step the setter then refused is `step`, with the refusal in `step_error` |
| `sample_monotonic_ns` | record | monotonic time of the last sample, from the page read when it arrived, so its age is known however the clock steps after it |
| `distance_ns` | record | its distance |
| `stratum`, `server` | record | its server's stratum and address |
| `source` | record | the domain whose facet sent it, from the facet, never the request |
| `step_at`, `step_ns` | record | the last applied step's wall time and size, or `unknown` |
| `step_source` | record | the domain whose facet asked for the last applied step, a sample's or a set's, from the facet; or `unknown` |
| `sample_from`, `step_from` | record | the kind of source of the last sample and of the last applied step, below; or `unknown` |
| `step_error` | record | the setter's refusal of the last step it refused, `unsupported`, `limit` or `badarg`, or `unknown` |
| `steps`, `refused` | record | steps applied and samples refused, floor and panic, since `record_since` |

After a restart of the service, `state` is still true, the record's
attributes are `unknown` until the next sample, and the counts start from
zero at the new `record_since`, so no count claims more history than the
service has.

**Who set the clock.** `/proc/time` is the one place that answers it,
whatever the source: two attributes, `sample_from` and `step_from`, name
the kind of source of the last sample and of the last applied step, as
`ntp ADDRESS` for ntpd's sample from that server, `rtc` for the
wall-clock keeper's reading at boot and `root` for an operator's set
(`date` or `ntpctl step`). The kind follows from the operation the facet
admitted and from the grant, never from a request's content: `sample` is
ntpd's, `set` is root's, and the keeper's reading reaches the service
inside the system domain. A later source, PTP, GPS or a DS3231 module
read by another domain, adds an operation of its own to
`abi/services/clock.txt`, granted by a facet row of its own, and so a
kind of its own here; no request carries a kind field. Each such source
keeps its own state where its owner keeps it: a configured domain at a
path of its own beside `/proc/time`, an app in its own tree, as ntpd
does at `/svc/ntpd/status` ([What ntpd serves](#what-ntpd-serves)).

A value the record does not hold yet is `unknown`, which `/proc` writes
as `[unknown]`: the inspection schema has no `none` value, and an
unknown attribute is the schema's own way to say that nothing is
recorded.

## What ntpd serves

ntpd's own state is its words, not the system's, so it is in ntpd's own
tree, `/svc/ntpd`, which its template declares that it serves
([design-app-trees.md](design-app-trees.md)), and not at `/proc`. The tree
holds one file, `status`, which ntpd sets with `erx_svc:set_status/1`
from `erx_ntp_core:status/1` after each exchange, resolution and answer
of the clock service, one attribute a line, a name, a tab and the value
in the field escape:

| Attribute | Value |
| --- | --- |
| `servers` | the names of the start flags, as the session read them, separated by spaces |
| `addresses` | the addresses in use, the current first, separated by spaces; `denied`, the ones `DENY` or `RSTR` removed |
| `last` | the address that last answered and how, separated by a space: `sample`, a drop reason of [Checks on a reply](#checks-on-a-reply), `deny`, `rate`, `other` for any other kiss, or `no_reply` |
| `interval_s`, `resolve_wait_s` | the poll interval, and the wait after a round that finds no usable address, in effect, in decimal seconds |
| `samples`, `dropped`, `kisses`, `silent` | replies that gave a sample, replies dropped, kisses, and exchanges with no reply, since the session started, in decimal |

The counts and `last` start empty with each session, and an attribute
with no value yet is left out of the file, so nothing claims more
history than the session has; while no ntpd session runs there is no
`/svc/ntpd`. `erx_svc` answers a read from the text ntpd last set, so a
read while ntpd is resolving, exchanging or waiting for the clock
service's answer is answered at once. A kiss code is written as one of
the known atoms, never as the server's bytes. ntpd's tree has no `ctl`;
`ntpctl -s` writes this file ([Decisions](#decisions), 8). Only a session
whose template holds `start` has `/svc`, which is also who reads
`/proc/svc/ntpd`.

## Setting the clock by hand

A board without a real-time clock starts at the build's date
([The approximate start](#the-approximate-start)), and with network
time off, as it is by default, nothing sets the wall clock closer; it
is as far behind as the image is old. The operator sets it with
`date`, as on FreeBSD, and no network is needed for it.

### The command

`date` is an Erlang command of the command shell, `erx_cmd_date`
([design-shell.md](design-shell.md#text-commands)), and behaves as
FreeBSD releng/15.1's `date` does for the forms it offers
(`bin/date/date.c` and `bin/date/date.1`):

```text
date [-jnu] [[[[[cc]yy]mm]dd]HH]MM[.SS] [+format]
```

* **Reading.** With no time operand it writes the wall time, the time
  page's, as `os:system_time(nanosecond)` reads it, through the format
  and a newline. The default format is `%+`, which FreeBSD's C locale
  spells `%a %b %e %H:%M:%S %Z %Y` (`lib/libc/stdtime/timelocal.c`,
  `date_fmt`). erXos has no time zones, so local time is UTC, as on a
  FreeBSD machine without `/etc/localtime`: `-u` is accepted and changes
  nothing, `%Z` is `UTC` and `%z` is `+0000`.
* **The format** is an operand beginning with `+`, before or after the
  time operand ("allow the operands in any order", `date.c`, `main`).
  Its conversions are strftime(3)'s as FreeBSD's C locale writes them
  (`lib/libc/stdtime/strftime.c`): `%a %A %b %B %h %c %C %d %D %e %F %H
  %G %g %I %j %k %l %m %M %n %p %r %R %s %S %t %T %u %U %V %v %w %W %x
  %X %y %Y %z %Z %+ %%`; the `E` and `O` modifiers, which the C locale
  ignores; and the padding flags `-`, `_` and `0` on the conversions
  `strftime.c` pads through its padding table (`%d %e %H %I %j %k %l %M
  %m %S %U %V %W %z`), while `%C %y %Y %G %g` keep two digits a part and
  `%u %w %s` none. `date`'s own pass comes first (`date.c`,
  `strftime_ns`): `%N` is the nanoseconds in nine digits, `%`*n*`N` in
  *n*, cut or padded with zeros, and `%-N` in nine, the wall clock's
  resolution being a nanosecond. Any other conversion character is
  written as itself without its `%`, and a format that ends inside a
  conversion as its last character, as `strftime.c` does; a second flag
  or modifier is written as itself the same way.
* **Setting.** A time operand that does not begin with `+` is the new
  time. Its digits are read from the left in pairs: `cc` the century,
  `yy` the year in it, `mm` the month, `dd` the day, `HH` the hour and
  `MM` the minute, of which only `MM` is required, and `.SS` the second.
  A field left out keeps the current UTC date's value, the second
  defaults to 0 and the nanoseconds are 0 (`date.c`, `setthetime`). A
  `yy` without `cc` below 69 is in 2000-2068 and otherwise in
  1969-1999. A month above 12, a day above 31, an hour above 23, a minute
  above 59, a second above 61, digits that are not an even count of 2
  to 12, a
  `.SS` that is not two digits, a second dot or any other character is
  `date: illegal time format` and the usage line, with the shell's
  `usage` status, and nothing is set. The fields are then normalized as `mktime(3)` does, so a month
  of `00` is December of the year before, a day of `00` the last day of
  the month before, month and day `0230` the first or second of March,
  and a second of 60 or 61 the first or second second of the next
  minute; in UTC every normalized time exists, so
  `date`'s `nonexistent time` cannot occur. That FreeBSD's `mktime(3)`
  normalizes these values so (`lib/libc/stdtime/localtime.c`, not read
  for this design) is unverified until the FreeBSD oracle runs `date -j`
  over the same operands.
* **`-n`** is accepted and ignored, as FreeBSD's is (`date.1`).
* **`-j`** parses the operand and writes the time it names without
  setting the clock, as FreeBSD's `-j` does, and needs no authority.
* **After a set** `date` writes the new time through the format, as
  FreeBSD's prints the time it set.
* **Not offered**, each a usage error: `-f` (another input format),
  `-I` and `-R` (ISO 8601 and RFC 2822 output), `-r` (a file's or
  a number's time), `-v` (adjustments) and `-z` (an output zone), and
  FreeBSD's securelevel limit, which erXos does not have.

Parsing, the named time and formatting are pure functions of
`erx_cmd_date`; `run/2` alone reads the clocks, asks the clock service
and writes.

### Who may set it

Setting needs the `clock` grant, the one authority over the wall clock
this document names. Root's session template holds it by a facet row
beside ntpd's, as it holds `machine`
([design-system.md](design-system.md#a-sessions-request)); the row
grants `set` and not `sample`, and ntpd's grants `sample` and not `set`:

```text
facet root_clock
  name "clock"
  grantee @session.system
  service @service.clock
  operations set
  ...
```

Every session of root therefore holds it, whatever started the session,
and no other development template does; a release manifest grants it to
root's template and to any administrator's template its author lists,
as for `machine` ([design-system.md](design-system.md#a-sessions-request)).
Root may already enable ntpd against a server of its choosing, and so
choose the time within the step rules: any time above the floor at a
cold start, then up to 1000 s every two polls, given a server the machine
reaches. The grant adds what the step rules refuse: a time below the
floor and an immediate step of any size, with no network. On erXos's
kernel the facet row is the authority; on Fiasco it is held, not
enforced, since any task's call writes the page ([On Fiasco](#on-fiasco)),
so there a session's `eperm` is how `date` behaves, not a bound on what
the session's code can do. A session without
the grant writes `date: clock_settime: ` and the text of `eperm`, status
1, as FreeBSD's `date` does for a user other than the superuser
(`date.1`, "Only the superuser may set the date"). Reading and `-j` need
no grant.

### What it changes

`run/2` reads the monotonic clock `M`, from `os:perf_counter(nanosecond)`,
and the wall time it fills the left-out fields from, at one moment,
computes the named time `T`, and sends the clock facet

```erlang
{set, W}
%% W :: 0..?ERX_TIME_OFFSET_MAX    T - M, the wall offset that makes the clock read T at M
```

the same absolute offset a sample carries, so a repeated or delayed
request cannot apply twice or short ([The
construction](#the-construction)). The clock service stores `W` through
`erx_clock_nif:set_offset/1`, unconditionally: a set is the operator's
word, not a measurement, so the [Steps](#steps) table, the floor and
both thresholds included, does not apply to it. The answer is `{ok,
{stepped, StepNs}}` or one of the facet's errors.

* **Every domain sees it at once.** The setter changes the time page,
  which every domain maps, so `os:system_time/1` in every domain reads
  the new time from the next call, and `erlang:system_time/1` within
  about a minute, through ERTS's time supervisor
  ([What the design rests on](#what-the-design-rests-on)).
* **Monotonic time does not move.** Neither the kernel's counter nor
  Erlang monotonic time nor any timer changes; a set backward is seen
  only by readers of wall time.
* **The boot is no longer cold.** The page's `seq` has moved, so a later
  sample from ntpd is decided by the thresholds: one 1000 s or more from
  the operator's time is refused `panic`, and the operator's time stands
  until a set or a reboot changes it. A `date` with the right time is
  therefore also the recovery without a reboot that [Open
  decisions](#open-decisions) asks for.
* **The record.** The clock service records a set as the last applied
  step, `step_at`, `step_ns` and `steps` at `/proc/time/status`, with
  `step_source` the domain whose facet sent it, and logs one line naming
  the grant's principal, as FreeBSD's `date` logs `date set by` its user
  (`date.c`, `syslog`) and the machine tree names who ended the machine.
  The sample attributes, `source` included, are left as they were. A set
  is a clause of `erx_clock_core` like a sample's rows: it steps to `W`
  whatever `Cold`, the floor or the distance, sets `excess := none`, so
  a sample held before it cannot step on one more sample after it, and
  stores a refusal of the setter as `step_error`, as for a sample.
* **A board without a writable real-time clock forgets it.** The setter
  changes the page, which the next boot publishes afresh. Where the
  wall-clock keeper of [design-header-io.md](design-header-io.md#devrtc)
  holds a real-time clock it writes a set like any other correction, as
  FreeBSD's `date` writes the hardware clock (`date.1`). A board without
  one, the Raspberry Pi 4 without a clock module, starts at the build's
  date again; there the operator sets the exact time after each boot,
  which the user documentation says. QEMU `virt` reads its PL031 again
  at each boot ([The real-time clock at boot](#the-real-time-clock-at-boot)).

### Failure paths

Every path ends with a status and, but for success, one diagnostic; the
parser is total over every argument list, so no argument makes the
command raise.

| Failure | Result |
| --- | --- |
| an operand or flag the command does not take | `date: illegal time format` for a bad time operand, then the usage line; status `usage`; nothing is sent |
| the session holds no `clock` grant, or its template grants one but the clock service had ended when the session started, so none was minted | `date: clock_settime: ` and `eperm`'s text; status 1 |
| `W` outside `0..time_offset_max`: a time before 1970-01-01 plus the uptime, or after early 2116 | the facet's `{error, badarg}`, `einval`'s text; status 1; the page is unchanged |
| no clock service registered, or the facet has ended | `{error, unavailable}`, or a facet that ended before the call, `eagain`'s text; status 1; the page is unchanged |
| the backend cannot set wall time | `{error, unsupported}`, `enotsup`'s text; status 1 |
| the page's sequence has run out | `{error, limit}`, `eoverflow`'s text; status 1 |
| the facet is busy | `{error, busy}`, `ebusy`'s text; status 1 |
| the clock service ended, or no answer came within 10 s | `{error, failed}`, `eio`'s text; status 1; the set may or may not have been applied, which a reading `date` or `/proc/time/status` shows |
| standard output cannot be written | the shell's write failure ends the command with its reason as the status, as for every command |

## Setting the clock from a server once

`ntpctl` is root's command for network time beside ntpd: it steps the
clock once, through the same `set` that `date` sends, and shows ntpd's
own words. It adds no facet row, template, service or operation. It is
an Erlang command of the command shell, `erx_cmd_ntpctl`, declared
`-erx_needs([inspect, net])`. Its name and its `-s` form are those of
OpenBSD's ntpctl(8), the control program of OpenBSD's ntpd
(`usr.sbin/ntpd/ntpctl.8`, openbsd/src `master` at
`09db4a01d52cabae9f4ffbc42eabe9378f87b1b6`, SHA-256
`9ca4faffad6069925142fba92d0b4849e1f143dfe15acc1c24862d5b23bc50f5`);
`step` is erXos's own, since OpenBSD's ntpctl sets nothing:

```text
ntpctl step [server ...]
ntpctl -s status | peers
```

The arguments choose the source of a step, and nothing else does
([Decisions](#decisions), 8):

* **`ntpctl step server ...`** asks the servers named and needs no ntpd.
  It takes one to 8 operands by ntpd's server-list rule
  ([Server list](#server-list)), `erx_ntp_exchange:servers/1`; anything
  else is a usage error. Each is resolved as ntpd resolves its names,
  by `erx_ntp_exchange:addresses/1`: an IPv4 literal is its address, and
  a name gives the first four addresses the session's resolver answers,
  in DNS order. A name with none writes `ntpctl: NAME: no address` and
  the command goes on; no address at all writes `ntpctl: no address to
  ask`, status 1. The addresses are asked in order, one SNTPv4 exchange
  each over a socket of its own, by `erx_ntp_exchange:ask/1`, the
  exchange ntpd makes: a random port, a 64-bit nonce from
  `erx_bytes:entropy/1`, 2 s for the reply, and checks 2 to 9 of
  [Checks on a reply](#checks-on-a-reply) by the same code as ntpd's. A
  datagram that does not decode or fails checks 2 or 3 is not this
  exchange's answer: it is dropped and the wait goes on to the same
  deadline, so a forged datagram cannot cut the exchange short. The
  first address whose reply passes gives the sample's `W`
  ([The construction](#the-construction)); a kiss, a dropped reply, no
  reply in time or a socket that cannot be opened moves to the next
  address. When none gives one, the command writes `ntpctl: no server
  gave a sample`, status 1, and sets nothing.
* **`ntpctl step`** takes ntpd's last sample from the clock service's
  record at `/proc/time` ([What /proc shows](#what-proc-shows)): its
  `sample_wall_offset_ns`, the sample's `W`, `sample_from`, which must
  be `ntp ADDRESS`, `server`, the server that gave it, `sample_verdict`,
  what the clock service did with it, and `sample_monotonic_ns`, when it
  came, all from one read of the record. A sample stays true after a step
  ([The construction](#the-construction)), so setting its `W` sets the
  time that server gave, less the drift of the clock since. ntpd must be
  running, as its start-table row says at `/proc/svc/ntpd`; when it is
  not, or when the record holds no sample of ntpd's, the command writes
  `ntpctl: ntpd is not running` or `ntpctl: ntpd has no sample`, status
  1, and sets nothing. A record it cannot read, or an attribute it
  cannot see or that holds no value, writes its path and that status,
  as `ntpctl: /proc/time: unavailable` or `ntpctl: /proc/svc/ntpd:
  state not visible`, status 1, and never claims either. The
  sample is the last one ntpd sent, and the command applies it whether
  the clock service stepped to it, held it, or refused it as `panic`: a
  sample 1000 s or more from a clock set this boot is still the time
  that server gave, and stepping to it is root's explicit fix, as a set
  is. A sample refused as `floor`, a time before the build's date, it
  does not apply: it writes `ntpctl: ntpd's sample of 192.0.2.7 is
  before the build date (refused as floor); nothing set`, status 1, so
  a step from ntpd's sample stays within the floor every sample meets.
  The command only reads `/proc`: it sends ntpd nothing, and ntpd gains
  no channel and no authority.
* **Setting.** Either way the command sends the clock facet `{set, W}`,
  as `date` does, and on `{ok, {stepped, StepNs}}` writes to standard
  output the step, in seconds with its sign and three decimals, cut
  toward zero, and what gave it; for ntpd's sample also the clock
  service's verdict, `accepted` for a step, `held` or `refused as
  panic`, and the sample's age in whole seconds, from
  `sample_monotonic_ns` and the monotonic clock the command reads:

  ```text
  ntpctl: stepped +1234.567 s from ntpd's sample of 192.0.2.7 (refused as panic, 12 s old)
  ntpctl: stepped -0.004 s from 192.0.2.10
  ```

  Every set is a step: erXos has no slew ([Decisions](#decisions), 3). A
  refusal of the facet writes `ntpctl: clock_settime: ` and its text,
  with `date`'s texts and status 1 ([Failure paths](#failure-paths)),
  and a session without the grant refuses as `date` does, with `eperm`.
* **`-s status`** and **`-s peers`** write ntpd's own words,
  `/svc/ntpd/status` ([What ntpd serves](#what-ntpd-serves)), with erXos's
  attributes rather than an imitation of OpenBSD's columns, which name
  values erXos's ntpd does not keep. `status` writes the servers, the
  last answer, the poll interval and the resolution wait, and the counts:

  ```text
  servers pool.ntp.org
  last 192.0.2.7 sample
  interval 64 s, resolve wait 15 s
  3 samples, 1 dropped, 0 kisses, 2 silent
  ```

  `peers` writes one line for each address in use, the current one
  marked `current`, then one for each denied address, marked `denied`.
  The command reads the file through `erx_svc_client:read/3` at `svc_wait_max`, writes
  `ntpctl: ntpd is not running`, status 1, when no session of ntpd's
  row serves it, kept or started by `onestart`, and parses it with
  `erx_svc_status:parse/1`
  ([design-app-trees.md](design-app-trees.md#reading-with-a-deadline)):
  an attribute the file leaves out is written `[unknown]` and one on a
  line the parser refuses `[invalid]`, each where its value goes, and a
  read that fails writes `ntpctl: /svc/ntpd/status: ` and the errno's
  text, or `timed out` at `svc_wait_max`, status 1. A value is written
  as the file holds it, escaped. OpenBSD's other keywords, `all` and
  `Sensors`, and its abbreviations are usage errors.

Failures are written to standard error after `ntpctl: `. Every name and
address written passes the field escape (`erx_text:escape_field/1`).

Parsing, the choice of ntpd's sample, the lines written, the wire codec
and the reply checks are pure; `run/2` alone reads the inspector,
resolves, asks and sets. `erx_ntp_exchange`, `erx_ntp_wire`
and `erx_ntp_sample` are modules of the `erx` library application,
which every runtime carries, so ntpd and the command share one
server-list rule, one resolution and one exchange rather than copies.

**What it changes** is what a set changes
([What it changes](#what-it-changes)): the page holds `W` at once, the
boot is no longer cold, and the clock service records and logs a set
from root's domain, so a later ntpd sample meets the thresholds.

**Security.** The command decodes NTP bytes in root's session, as `host`
decodes DNS replies there; the decoder is total and bounded, and a
failure ends only the command. A reply is unauthenticated: for `ntpctl
step server`, the server root names, or anyone on the path to it,
chooses the time the command sets, with no floor and no threshold, as
on FreeBSD, where ntpdate run as root steps the clock to whatever its
selected server says; for `ntpctl step`, the time of the sample root
applies was chosen by ntpd's server, or anyone on the path to it, or by
ntpd itself, whose session sends the samples, past the thresholds the
clock service held that sample to, but never below the floor: a sample
it refused as `panic` is still applied, one it refused as `floor` is
not. The line names the server, the size of the step, the service's
verdict on the sample and its age, so root sees a refused or stale
sample in the line that applied it. An off-path host cannot, since it must
guess the nonce and the random port. That is the residual of
[Security](#security), wider by the thresholds a sample meets and a set
does not, and for `ntpctl step server` by the floor as well, and it is
open only while root runs the command. Since a set ends the cold start, a forged time also outlasts
the command: a later ntpd sample 1000 s or more from it is refused
`panic` until root sets the clock again or the machine reboots. ntpctl
sets through `set`, and this wider residual is published
([Decisions](#decisions), 7).

No `ntpctl step` runs at boot, as FreeBSD's `ntpdate_enable` would run
ntpdate: the boot-time path is ntpd's first sample
([Decisions](#decisions), 6).

## Concurrency and failure

* **One writer.** Only `erx_clock` calls the NIF, one sample at a time
  in its own process, so the page's sequence has one writer in user
  mode, and the call's body serializes in the backend. The service reads
  the page, decides and sets within one sample's handling, so no other
  write falls between its read and its step.
* **Two clients** would interleave samples, each step to its own `W`.
  The manifest grants `clock` for samples only to the ntpd template and
  the start table keeps at most one session of a row, so there is one.
  Root's sets interleave with ntpd's samples, and each request is absolute,
  so the later one decides the page; after a set, the thresholds decide
  ntpd's samples against the operator's time.
* **Nothing is in flight that a failure must undo.** A sample's effect
  is the page, which the setter changes in one call or not at all; the
  facet and the client hold no state about it.

| Failure | Who sees it | Result |
| --- | --- | --- |
| the network domain restarts | the client, whose sockets end | the next poll opens a new socket on the new grant |
| the clock service crashes before the setter ran | the facet, which answers `{error, unavailable}` or `{error, failed}` | the page is unchanged; the client's next sample, one unchanged interval later, is decided afresh, and steps if the boot is still cold |
| the clock service crashes after the setter ran, before answering | the facet, which answers `{error, failed}` | the page holds `W`; the next sample is about 0 from it and is held. Either way nothing is lost, since the page is the state |
| the clock service crashes a fifth time within an hour, as a request that crashes it each time and is sent again would make it | `erx_clock_sup`, which ends, and with it every clock facet | the machine runs on without a clock service, as it runs on without a log service: the page keeps its offset and wall time runs on from it with no step until the next boot. A session's `date` that sets answers `eagain`'s text, the facet having ended; a session started later is minted no `clock` facet, the server having ended, and its `date` answers `eperm`'s; `kernel_safe_sup` and the system domain run on |
| the ntpd session crashes | the start table | restarted within the row's intensity; the page, not the session, says whether the boot is cold, so the restart renews no unrestricted step |
| a server sends offsets of 1000 s or more | the client, which gets `{refused, panic}` | logged and counted; the client polls on and does not end, so the refusal causes no restart |
| the clock was set wrong this boot | the operator, at `/proc/time` and the log | every later sample from a right server is refused `panic`; the operator sets the right time with `date` or reboots ([Steps](#steps)) |
| DNS fails | the client | retried with backoff; `/proc/time` keeps the last sample |
| every server is silent or denies | the client | backoff to 1024 s and re-resolution; the clock runs on its counter |
| the backend cannot set wall time | the clock service | `{error, unsupported}`; `step_error` is `unsupported` until the service restarts, and `state` shows the page as it is |
| the page's sequence runs out | the clock service | `{error, limit}`; wall time readers report it unavailable, and ERTS, which reads wall time on every `erts_os_system_time` call, ends (`sys_time.c`; [design-kernel.md](design-kernel.md), "Time") |

## Security

* **The parser runs in the app.** NTP bytes are decoded only by
  `erx_ntp_wire` in the ntpd session, which holds `net`, `clock` and
  `log`, and in root's session while root runs `ntpctl step`
  ([Setting the clock from a server once](#setting-the-clock-from-a-server-once)).
  A fault there ends that session, or the command. The system domain decodes a
  five-element tuple of bounded integers and an address, or a `set` of
  one bounded integer, through
  `erx_clock_facet:decode/1`, at the funnel's limits.
* **No sample leaves the clock's range.** The facet's bound on `W` is the
  setter's, and the setter refuses any other offset, so not even a
  compromised ntpd, nor a bug of the system domain, can publish a wall
  time outside `[0, 2^63)` (T-R7).
* **Root's `set` is not filtered.** A set skips the floor and both
  thresholds, as an operator's `date` and ntpdate do on FreeBSD, and only the
  setter's range bounds it (T-R7). Only rows that grant `set` admit it,
  and the manifest gives that operation to root's template alone, so a
  compromised ntpd still sends only samples
  ([Who may set it](#who-may-set-it)).
* **Whoever holds `clock` decides the time.** A compromised ntpd can
  fabricate every sample: any time above the floor at a cold start, and
  then up to 1000 s per two samples, forward or backward, without limit
  over time. The thresholds guard an honest client against one bad
  measurement, not the system against the client. On erXos's kernel the
  authority is the facet row; on Fiasco it is held, not enforced
  ([On Fiasco](#on-fiasco)).
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
* **An approximate clock passes certificates the real date would
  refuse.** Until the clock is set, validation reads the build's date
  plus the uptime, so a certificate that expired between the build and
  the real date is accepted; the window is the image's age. It is
  accepted for development builds and 0.1; a release build's choice is
  open ([The approximate start](#the-approximate-start)). No party can
  renew the start: it follows from a cold page, which only a reboot
  gives, though a step onto exactly the floor's offset makes the page
  approximate again ([The approximate start](#the-approximate-start)).
  A certificate first valid after the build date is refused, so the
  start helps only an image younger than its peers' certificates.
* **An off-path attacker** must guess a 64-bit nonce and a random source
  port, and send from the server's address and port, to have a reply or
  a kiss believed.
* **Text.** Kiss codes and server names reach the log only through the
  log service's escaping and `/proc` only through the inspector's;
  addresses are integers.

## On Fiasco

On the Fiasco backend the setter is a service call on the time page's
handle: the root checks the caller's `WRITE` right on that handle and
answers `ERX_ERIGHTS` without it, so only the system domain sets the
clock, as on erXos's kernel, and the chokepoint and the facet stand
behind that check rather than in its place
([The release's cases](design-fiasco.md#the-releases-cases)). The
`erx_facet` module has no generated admission path, so the
operations a grant lists are checked through its callback: a callback
that maps a request to its operation (`erx_clock_facet:operation/1`)
gets every request checked against the grant's `operations`, an empty
list admitting nothing, and `erx_facet:start/3` refuses a grant that
lists operations to a callback without that map. A row of `operations
none` of any other service therefore admits every request its facet
admits, and the boot refuses
operations on a row a configured domain serves or a tree grant, since
nothing there checks them. The range check of
`erx_time_set_offset` is the body's own and holds on Fiasco as on
the kernel. The page starts zeroed, `seq` and offset included, so every
boot is cold. The Fiasco backend puts no real-time clock's reading in
the page at boot. On QEMU `virt` the system domain's wall-clock keeper,
a user-mode driver of the PL031, reads it once at boot and sets the clock
([The real-time clock at boot](#the-real-time-clock-at-boot)); the
Raspberry Pi 4 has no clock of its own, so there the clock service
starts the clock at the build's date, `approximate`
([The approximate start](#the-approximate-start)), until root's `date` or
`ntpd` sets it, or, on a Pi 4 with a DS3231 module, the
wall-clock keeper does
([design-header-io.md](design-header-io.md#devrtc)). The hosted backend reads
its offset once from the host's clock and keeps it
([design-fiasco.md](design-fiasco.md), "The hosted backend"), so its
`state` is `boot`; its setter answers `ERX_ENOTSUP`, as the Fiasco
backend's does in every task but the root's, so only the system domain
sets the clock.

## Verification and testing

Host tests run the pure modules under EUnit, over fixed vectors and, for
the schedule, generated event sequences and simulated time. They cover
the era conversion either side of 2036-02-07 06:28:16, the offset and
delay arithmetic, each reply check and kiss code, the root distance,
every row of [Steps](#steps), a restarted service, the approximate
start and the real-time clock at boot over unset, approximate, boot and
set pages, the schedule's spacing, bursts, re-resolution and denied
list, T-R1's first-sample minute, the flags reader, the facet's bounds
for `sample` and `set`, `date`'s operands, formats and set, and
`ntpctl`'s forms, its sources, its `-s` output and its exchange. Each
names the seeded fault that proves it ran:

* treating every timestamp as era 0 fails the 2036 vectors;
* taking `(T2 - T1) + (T3 - T4)` in 64-bit 32.32 fixed point, as RFC
  5905 section 8 warns against past 34 years, wraps the boot offset by
  2^32 s; dropping the `div 2` doubles `W`;
* removing the nonce comparison accepts a foreign-nonce reply, in ntpd's
  checks and in `ntpctl`'s exchange alike; running check 4 before the
  kiss branch ignores an LI-3 `RATE`; believing a kiss before the nonce
  check silences the server on a foreign-nonce kiss;
* adding the signed root delay unclamped accepts a reply whose distance
  is out of bounds;
* dropping the two-sample rule steps on a single 200 ms sample; dropping
  the floor row steps a cold clock to 1999; deciding cold from an empty
  record instead of the page steps a restarted service 2000 s;
* an approximate start without the floor's comparison moves a boot clock
  past the floor back to it; a start over any page renews it on a page
  set below the floor; dropping the approximate clause refuses a 2000 s
  sample as panic; a constant floor admits a sample the record's later
  floor refuses; the real-time clock's floor check, its refusal over a
  boot clock and its refusal over a set clock, each removed;
* a poll floor of 8 s fails the spacing property; admitting any address
  not denied once the denied list is full fails its bound; a 15 s wait
  in place of 2 s before the first poll misses a name first answered
  20 s into the run;
* accepting a ninth entry passes the nine-server case, of `ntpd_flags`
  and of `ntpctl step` alike; dropping `W`'s upper bound accepts
  `time_offset_max + 1` at the facet;
* a `date` pivot of 70 makes `69` 2069; dropping the month bound
  accepts `13`; `%e` padded with `0` fails the single-digit day; looking
  up the grant before parsing refuses `-j` without one;
* `ntpctl step` without the running check steps from a stopped ntpd's
  sample, and without the floor clause applies a sample refused as
  `floor`; a `-s` formatter that writes a missing attribute as an empty
  value prints `servers` with nothing after it.

The setter's range is tested on Fiasco in the native guest's time case
(`test/guest/native_space/guest.c`): 0 and `time_offset_max` read back
exactly, `time_offset_max + 1` and -1 answer `ERX_EINVAL` and leave the
page and its `seq` unchanged, and `cold` is true before the first set
and false after. *Seeded failure:* a body that stores `offset_ns` less a
monotonic reading fails the exact read-back.

Fuzz targets, run by `make check-fuzz`:

* **`erx_ntp_wire_fuzz`**: binaries of up to 1 KiB to
  `erx_ntp_wire:decode/1`, and every accepted reply to the core's checks
  against a fixed outstanding exchange. Nothing raises, an accepted
  header re-encodes to its 48 bytes, every accepted timestamp converts
  within 1970 to 2104, and every accepted sample's distance is below
  `clock_distance_max_ns`. Seeds are generated from the encoder.
  *Seeded failure:* removing the length check makes a 47-byte seed raise.
* **`erx_clock_facet_fuzz`**: arbitrary terms, as the funnel decodes
  them, to `erx_clock_facet:decode/1`. *Seeded failure:* accepting a
  `Stratum` of 0 fails the property that an accepted sample is within
  every bound.
* **`erx_ntpd_flags_fuzz`**: binaries of up to 2 KiB, as
  `ERX_START_FLAGS`, to the client's flags reader; an accepted list has
  at most 8 entries, each within the server-list rule. *Seeded failure:*
  dropping the 253-byte bound accepts a 254-byte name.
* **`erx_cmd_date_fuzz`**: argument lists to `erx_cmd_date:parse/1`, and
  each accepted operand to `target/2`; an accepted operand is within the
  grammar and its bounds, its time written back as `%Y%m%d%H%M.%S` and
  parsed again names the same time, and `format/2` never raises.
  *Seeded failure:* dropping the `.SS` length check accepts `1200.5`.

The QEMU `virt` suite runs the client end to end against the harness's
test peer on the guest's link (`tools/lib/erx/net_device_name_server.rb`),
which answers DNS on port 53 and NTP on port 123 from a clock and an LI,
stratum and kiss code the test script sets; the guest's test manifest
enables ntpd against the peer. Its cases and seeded faults:

* **Bootstrap**: the first burst sets the clock to the peer's 2030,
  within 1 s, at once for `os:system_time/1` in another domain and within 75 s for
  `erlang:system_time/1`. *Seeded:* reading the transmit timestamp from
  the reference field's offset.
* **Restart**: the peer jumps two hours, ntpd and the clock service are
  killed and restarted, every later sample is refused `panic`, and the
  guest's time stays within 1 s of where it was.
  *Seeded:* deciding `Cold` from the empty record.
* **Held and stepped**: a 500 ms offset is held once, then stepped.
  *Seeded:* no two-sample rule.
* **ntpctl**: `ntpctl step` steps from ntpd's sample, and `ntpctl step
  ADDRESS` from the peer.
* **ntpd's tree**: while resolution is delayed, `ntpctl -s status`
  answers at once and `/svc/ntpd` holds `status` alone. *Seeded:*
  `erx_svc`'s read asking ntpd's loop for its status writes `timed out`.
* **Kiss**: `RATE` doubles the interval, then `DENY` stops the requests.
  *Seeded:* the kiss check after check 4, with LI 3.
* **Refusals**: a session without the facet row has no `clock` name, and
  `ntpd_flags=""` ends the row with `no servers`.
* **The real-time clock at boot**: `date` before any set writes the
  host's hour, from the PL031 the harness starts at the host's time.
* **Set by hand**: root's `date 203001011200` moves the clock in every
  domain and `/proc/time/status` says `set`; a session without the
  `clock` row gets `eperm`. *Seeded:* root's template without the row.

The oracle for real NTP is FreeBSD's ntpd, in a jail of the FreeBSD
x86-64 test host, with the client and the stack running on the host's
own OTP over a tap device
([design-network-stack.md](design-network-stack.md#the-stack-on-a-development-host))
and the clock facet replaced by a recorder of samples. A jail shares its
host's clock, so the first sample's `W` agrees with the host's wall time
minus monotonic time within 10 ms, on two runs. *Seeded failure:*
swapping `t2` and `m1` in the offset. FreeBSD's `date -j` over the same
operands is the oracle for `date`'s normalization.

On the Raspberry Pi 4, by hand: with Ethernet and DHCP and ntpd enabled
against a reachable server, `/proc/time/status` is `set` within a
minute, and a new file's time in `ls -l` matches a reference clock
within a second.

## Alternatives considered

* **The client in the system domain**, holding `WRITE` itself. It would
  put NTP parsing in the trusted base, which decision 19 forbids.
* **The client in the network domain,** beside DHCP. The domain that
  parses every packet would also hold the clock, and the stack would stop
  being an OTP application with no erXos authority in it.
* **Giving the app the time page's `WRITE` right.** No clock record in
  one place for `/proc`, two policies if a second time source comes, and
  on Fiasco no difference from any task's call.
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
   An erXos vendor zone, when one exists, is the default to ship. The
   Raspberry Pi 4 development image, a demo with no real-time clock, is
   the one exception: it enables ntpd with `pool.ntp.org`
   ([Configuration](#configuration)); a release image ships no server.
2. **The operator's servers are `ntpd_flags`**, a bounded start-row
   field delivered as opaque data ([Configuration](#configuration)),
   rather than a file in the ntpd user's home, which would need a way for
   an administrator to write another user's home in a release build,
   or the manifest only, which would need a rebuilt image to change
   servers.
3. **No slew.** The named consumers need a second, a slew needs a rate on
   the time page, a new kernel mechanism, and the accuracy this gives is
   stated in [Steps](#steps). erXos's kernel can add a rate if a consumer
   needs a wall clock that never steps after the first sample.
4. **The QEMU suite tests the client end to end** through the extended
   test peer, and FreeBSD's ntpd stays the interoperability oracle on the
   test host ([Verification and testing](#verification-and-testing)).
5. **`date` sets the clock through the `clock` facet**, with a `set`
   operation that root's template holds by a facet row of its own,
   `root_clock`, granting `set` alone, while ntpd's row grants `sample`
   alone ([Who may set it](#who-may-set-it)). There is one authority
   over the wall clock, the clock service, with one decode, one setter
   path and one record, and the rows' `operations` keep measuring and
   commanding apart. A one-shot command's usual home is a `ctl` file,
   but this adds one operation to a protocol already declared, not a new
   protocol or mechanism, and the operator's command is a protocol
   request, as `host` uses `net`. A line of `/svc/machine/ctl` was rejected because the
   right to end the machine would also set the clock and the
   coordinator's tree would forward to a service it does not own; a
   `ctl` file of a tree the clock service serves was rejected because it
   adds a `files` service, a mount, a text grammar with its fuzz target
   and a second route to the clock beside `clock`. Open decision 1's
   tree, if it comes, takes `cold` alone, or becomes a `clock` operation
   the same way.

6. **The boot-time path is ntpd's first sample**, not a boot-time
   ntpdate. FreeBSD runs ntpdate once at boot when `/etc/rc.conf` sets
   `ntpdate_enable="YES"` (`libexec/rc/rc.d/ntpdate`), but a start row
   is not one-shot: its keeper starts a session that ends again
   ([design-apps.md](design-apps.md#keeping-a-session)). ntpd's session
   stays up, and its first sample, sent as `sample`, meets
   [Steps](#steps): free from a cold or approximate start, never below
   the floor. A network that is not up when the session starts needs no
   ordering: the resolution or the exchange fails and the
   [schedule](#schedule) asks again.
7. **`ntpctl step` keeps `set`**, as FreeBSD's ntpdate run as root steps
   to whatever its server says. A forged or wrong reply to `ntpctl step
   server` can move the clock below the floor and, since the boot is then no longer cold,
   hold it against ntpd for the rest of the boot; that wider residual is
   published ([Security](#security); `TODO.md`), and root's `date`
   corrects it.
8. **One command for network time, its source chosen by its
   arguments.** Root's manual fixes are `date` and `ntpctl step`. Named
   servers are asked directly, and no server named takes ntpd's last
   sample; neither form falls back to the other. A fallback would set a
   time from a source root did not choose, a silent change of meaning
   the command's line could only confess after the fact; with the source
   explicit, the line states what root asked for, and a source with
   nothing to give fails without changing the clock. `ntpctl step` reads
   ntpd's sample from the record the clock service already keeps
   (`sample_wall_offset_ns`, [What /proc shows](#what-proc-shows)) and sets
   through root's own `set`, so ntpd offers no control file and gains
   no channel or authority, and boot-time sync stays its first sample.
   It applies a sample the service held or refused as `panic`, which is
   the operator's fix for a clock set wrong this boot, but not one it
   refused as `floor`: ntpd's sample never sets a time before the
   build's date, by the service or by root's command, and only `date`
   or a server root names directly can. Its line names the service's
   verdict and the sample's age, which the record keeps
   (`sample_verdict`, `sample_monotonic_ns`), so a refused or stale
   sample is never applied unseen.
   The command is ntpctl, the control program of an ntpd, as OpenBSD's
   is, since ntpd is what erXos runs, and one command instead of a
   separate ntpdate keeps one exchange for both ways of setting. ntpd's
   state is read at `/svc/ntpd/status`, which `ntpctl -s` writes, and
   ntpd's tree has no `ctl`.

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
   `date` with the right time, or `ntpctl step` with a server's or with
   ntpd's last sample, already recovers the clock without a reboot
   ([What it changes](#what-it-changes)); what stays open is handing the
   next correction back to an unrestricted sample.
2. **The approximate start in a release build.** A release runs
   untrusted workloads, and an approximate clock accepts a certificate
   that expired between the build and the real date. The choices: keep
   the start, as development builds and 0.1 do; keep it and have
   validation refuse TLS while `state` is `approximate`, so a release
   needs `ntpd` or a real-time clock for HTTPS; or drop it. It is the
   release's decision, recorded in `TODO.md`.
## References

* erXos's designs, linked where used: design-kernel.md ("Time"),
  design-network-stack.md, design-system.md, design-apps.md,
  design-log.md, design-domains.md, design-runtime.md, design-fiasco.md,
  design-crypto.md.
* erXos's tree: `liberx/backend/fiasco/time_page.c`,
  `liberx/backend/fiasco/time.h`, `liberx/backend/fiasco/service.c`,
  `otp/erts/emulator/sys/erxos/sys_time.c`,
  `otp/erts/emulator/sys/erxos/erl_unix_sys.h`,
  `otp/erts/emulator/sys/erxos/imports.txt`,
  `otp/erts/emulator/beam/erl_time_sup.c`,
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
* FreeBSD releng/15.1 at the same commit, from FreeBSD's official
  mirror `https://github.com/freebsd/freebsd-src` (raw files), for
  `date`:
  * `bin/date/date.1`, SHA-256
    `25e38f29eeeedf3358d79adecb54a877f23a53ef7fb191a7ea3512734733e3b0`;
  * `bin/date/date.c`, SHA-256
    `e60ac5347d6ad3a34eef666606907d67fcf7e87b12ef4d707c6f8c8be96a455b`;
  * `lib/libc/stdtime/strftime.c`, SHA-256
    `82ee008e3db2d3724921bc0dfd972ea7f98d8d4b5adf85df608330a2c62ba084`;
  * `lib/libc/stdtime/timelocal.c`, SHA-256
    `1f7a2182c4257ae5a87566bacdf24e3a64aa7b6278ac8527b255d01aec4955f0`.
* RFCs from `https://www.rfc-editor.org/rfc/`: RFC 4330 (SNTPv4), SHA-256
  `e0a5344883d62f9ff58a6cf3a44398bda097badd3013236fab47ea7fdc25bc33`;
  RFC 5905 (NTPv4), SHA-256
  `8b7abd903c60202e2953ee012fefa6916666c3b0c71825c748cdd262024fb268`;
  RFC 8633 (NTP best practices; sections 3.2, 3.6, 4.3 and 5.2), SHA-256
  `fb275c82378be983511db4fcd533a92a54028c7762be2d9bc0d6fa5c06dc5a84`.
* The research record behind this design:
  `~/erxos-history/notes/research-pi4-peripherals.md` (history commit `e38149b`), section 5,
  written 2026-11-14.
