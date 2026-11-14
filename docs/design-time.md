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
  time, in nanoseconds. That is the number the time page stores. So a
  measurement does not depend on what the wall clock reads, a sample stays
  true after a step, and setting the clock means writing one number
  ([The construction](#the-construction)).
* **The system domain owns the clock; an app measures it.** The system
  domain holds the time page's `WRITE` right and parses no network
  traffic (design-network-stack.md, decision 19). The SNTP client is an
  app, principal `ntpd`, whose session holds a `net` grant and a `clock`
  facet of the system domain's **clock service**. The facet carries
  samples, never packets ([Who does what](#who-does-what)).
* **Off unless enabled, as on FreeBSD.** The manifest's `start ntpd` row
  says `enable NO`; `ntpd_enable="YES"` in `/apps/rc.conf`, or `service
  ntpd enable`, starts it at boot ([Configuration](#configuration)).
* **One unrestricted step per run, then steps above 128 ms.** A grant's
  first sample sets the clock whatever its distance, as `ntpd -g` allows
  once. After that an offset above 128 ms is stepped when two samples in
  a row show it in the same direction, an offset of 1000 s or more is
  refused, and smaller offsets are left alone. There is no slew
  ([Steps](#steps)).
* **`/proc/time/status` is the clock's record.** It shows whether the
  clock was set this boot, the last sample and the last step, and nothing
  it does not know ([What /proc shows](#what-proc-shows)).

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
  RFC 5905's modular arithmetic gives correct offsets only "if the client
  is set within 68 years of the server" (section 6), and RFC 4330 notes
  the computation needs the client "within 34 years of the server";
  a board booting at 1970 is 56 years out.
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
  `MAXDIST`, 1 s.
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
  significance and the packet is discarded (RFC 5905 section 7.4; RFC
  4330 section 8).
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
  11.3 and A.5.5.1). FreeBSD's ntpd documents 128 ms (above).

### What erXos already has

* **The time page** is one read-only page every domain maps: the
  counter's scale and `wall_offset_ns`, "wall time minus monotonic time".
  A reader takes `seq`, the fields and `seq` again, so every runtime
  reads wall time without a kernel call. `erx_time_set_wall`, which needs
  `WRITE` on the time page, sets wall time from the call on, and the
  system domain is the party that corrects it
  ([design-kernel.md](design-kernel.md), "Time").
* **ERTS reads both clocks from liberx.** `erts_os_system_time` is
  `erx_time_wall_ns`, read on every call, `erts_os_monotonic_time` and
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
  defaults, and `/apps/rc.conf` sets `NAME_enable`, `NAME_display`,
  `NAME_restarts` and `NAME_period` over it
  ([design-apps.md](design-apps.md#the-start-table)).

## Requirements

* **T-R1.** With network time enabled and a server reachable, wall time
  is within a second of the server's within a minute of the network
  coming up. The consumers are file times, log times and certificate
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
clock by making the page's offset `W`: it reads the monotonic clock `m`
and calls `erx_time_set_wall(m + W)`, whose body stores
`(m + W) - monotonic` and so is off only by the microseconds between the
two reads.

The special cases this removes:

* **No era problem at boot.** The client's own times are counter
  readings, never NTP timestamps, and the server's are converted to
  unbounded Erlang integers, so no difference is taken modulo 2^64. The
  68-year limit of RFC 5905's arithmetic, which a clock starting at 1970
  breaks, does not arise; the first sample needs no other path.
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
  an amount to add, so time spent in queues, a repeated request or a
  second setter cannot make a correction apply twice.
* **The distance from the clock is one subtraction.** The sample's offset
  from the clock as it reads is `W - C`, where `C` is the page's
  `wall_offset_ns`; the step rules and `/proc` use that difference.

## Who does what

```text
  ntpd session (app, principal ntpd)          system domain
  ----------------------------------          -------------
  erx_ntpd: names -> inet_res -> addresses
  erx_ntp_core (pure): schedule, checks,     erx_clock_facet: decode,
    W and delay, kiss-o'-death                  per-grant first flag
  erx_ntp_wire (pure): 48-byte codec    --->  erx_clock: erx_clock_core (pure)
  gen_udp over net (network domain)      clock   decides; erx_clock_nif
                                         facet   calls erx_time_set_wall
                                                 record -> /proc/time
```

* **The ntpd app** is the measuring side. Its session holds three grants
  and nothing else: `net` with small limits (two sockets), `clock`, and
  the `log` facet every domain has. It runs `erx_ntpd`, an OTP
  application of its own release: a pure core, `erx_ntp_core`, that takes
  events (a timer fired, a datagram arrived, a resolver answer, the clock
  service's answer) and returns the next actions and deadline, and a
  thin effect process that resolves names, opens sockets, sends, receives
  and calls the facet. The packet codec, `erx_ntp_wire`, is pure and the
  only reader of NTP bytes.
* **The clock service**, `erx_clock`, a system service of the system
  domain under the system release's supervisors, is the setting side. It
  keeps the clock's record, runs `erx_clock_core:decide/2`, a pure
  function from a sample and the record to an action and the next
  record, performs a step through `erx_clock_nif:set_wall/1`, and answers
  the inspector for `/proc/time`. A crash restarts it with an empty
  record; no grant ends, and the clock's state is read from the page
  ([What /proc shows](#what-proc-shows)).
* **The `clock` facet**, `erx_clock_facet`, is the `erx_facet` callback
  the domain service mints for each grantee of `clock`, as the log facet
  is minted ([design-log.md](design-log.md)). It decodes the request,
  stamps the grantee and the grant's first-sample flag, and forwards it
  to the `erx_clock` registered at that moment, or refuses with
  `{error, unavailable}`.
* **`erx_clock_nif`**, a static NIF of the runtime, is the one object
  that calls `erx_time_set_wall`, as `erx_watchdog_nif.c` is the one
  that pets the watchdog. Only the system domain holds the time page's
  `WRITE` right, so wherever else the NIF is linked the call fails.

Why an app and not the network domain: the network domain is the stack,
an OTP application usable outside erXos, and the domain that parses every
packet would then also hold the clock. A separate app keeps the clock's
authority with a domain whose only input is NTP replies, and it is the
start table's row that `ntpd_enable` switches. Why not the system
domain: it parses no network traffic, and the facet keeps it that way;
the clock service reads five bounded integers.

## Interfaces

### The clock facet

`abi/services/clock.txt` declares `service clock` with one operation,
`sample`; the manifest serves it from the system domain:

```text
service clock
  server system
  interface clock
```

A request is

```erlang
{sample, W, Delay, Stratum, Server}
%% W       :: 0..(1 bsl 63 - 1)      wall offset, ns
%% Delay   :: 0..1_000_000_000       round-trip delay, ns
%% Stratum :: 1..15
%% Server  :: inet:ip4_address()     the address that answered
```

`erx_clock_facet:decode/1` answers the sample or `{error, badarg}` for
anything else: another operation or arity, a value outside its range, an
address that is not four integers of 0 to 255. It creates no atom and
never raises. `W` is non-negative because any real time is later than
1970 plus the machine's uptime, and below 2^63 because the page's field
is a signed 64-bit integer. The facet forwards
`{sample, Grantee, First, Sample}`; `First` is `true` for the first
sample it forwards in the grant's life and `false` after, held in the
facet's own state, so it dies with the grant. A grant lives as long as
the ntpd session that holds it, so `First` means "first sample of this
run", as `-g` does.

The answer is `{ok, Action}`:

| Action | Meaning |
| --- | --- |
| `{stepped, StepNs}` | the clock moved by `StepNs`, signed |
| `held` | the sample is recorded and the clock left alone |
| `{refused, panic}` | the sample is 1000 s or more from the clock after this run's first; nothing changed |

or `{error, badarg}`, `{error, unavailable}` (no clock service),
`{error, unsupported}` (the backend cannot set wall time), `{error,
limit}` (the page's sequence has run out, `ERX_ELIMIT`), or the facet's
own `{error, busy}` and `{error, failed}` ([design-domains.md](design-domains.md#facets)).
The client logs every refusal and error and goes on polling.

### The NIF

`erx_clock_nif:set_wall(WallNs)` returns `ok` or `{error, Status}` for
`erx_time_set_wall`'s status. `otp/erts/emulator/sys/erxos/imports.txt`
gains a section `[only_erx_clock_nif] erx_time_set_wall`, so no other
object of the runtime can call it, and a check over the system release's
call graph allows `erx_clock_nif:set_wall/1` only in `erx_clock`, with a
seeded violation, as for `erx_log:take/0`.

## Steps

`erx_clock_core:decide(Sample, Record)` with `D = W - C`, `C` the page's
offset when the sample arrives:

| Condition | Action | Record |
| --- | --- | --- |
| `First` | step to `W` | `excess := none` |
| `abs(D) =< 128 ms` | hold | `excess := none` |
| `128 ms < abs(D) < 1000 s`, and `excess` has `D`'s sign | step to `W` | `excess := none` |
| `128 ms < abs(D) < 1000 s`, otherwise | hold | `excess := sign(D)` |
| `abs(D) >= 1000 s` | refuse `panic` | `excess := none` |

Every row also stores the sample, its time and its source as the last
sample, and a step stores its time and size and counts it.

* **The first step** is unrestricted, as `ntpd_sync_on_start=YES` makes
  it. erXos does not offer the `NO` setting: both boards and the stopgap
  start wall time at the epoch (see [Phase 1](#phase-1)), so every
  boot's first sample exceeds the panic threshold and the client could
  never set the clock. A restart of the ntpd session, `service ntpd
  restart`, is a new grant and so a new first sample, which is how an
  operator recovers from a clock set wrong, as restarting ntpd with `-g`
  is on FreeBSD.
* **Two samples in a row** stand in for RFC 5905's stepout: one exchange
  whose delay is asymmetric cannot step the clock, and a real offset is
  stepped one poll interval after it appears.
* **No slew.** Offsets of 128 ms and less are left alone, so the clock's
  error stays below 128 ms plus the drift of two poll intervals, then is
  stepped. Slewing needs the time page to carry a rate, a kernel
  mechanism, and no consumer of T-R1 needs it; this departs from
  FreeBSD, whose ntpd slews below 128 ms ([Open decisions](#open-decisions)).
* **Leap seconds are not inserted.** The LI field is used only to reject
  an unsynchronized server. After a leap second the clock is a second
  off and the next two samples step it back.

## The client

### Server list

The list is an ordered list of at most 8 entries, each a host name (the
resolver's rule for a search domain: labels of letters, digits and
hyphens, 1 to 63 bytes each, 253 in all) or an IPv4 literal. A pool name
resolves to several addresses, used in the order DNS gives them, which
the pool randomizes. The manifest's session template gives the default
list in its arguments; the operator's list replaces it
([Configuration](#configuration)). The client never takes servers from
DHCP, as FreeBSD's dhclient does not ask for them.

The client uses one address at a time, as RFC 4330's client does: it
does not select or combine servers as ntpd does with `minclock 3
maxclock 6`. Combining guards against one bad server; the consumers here
need a second's accuracy, and the panic threshold and the two-sample rule
bound what one bad server can do once the clock is set.

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
  only when it passes every match check below, so an off-path host
  cannot silence a server.
* **Clock answers** change nothing in the schedule: a held, stepped or
  refused sample is the same success to the poll interval.

### Checks on a reply

`erx_ntp_wire:decode/1` takes a binary and answers a reply record or
`{error, Reason}`; it reads the first 48 bytes after one length check and
ignores what follows. `erx_ntp_core` then accepts a reply for the
outstanding exchange only if all of these hold, and otherwise drops it,
counting the reason:

1. it came from the address and port the request went to; the socket is
   connected to them, so the stack delivers only such datagrams, and the
   core compares them as part of the exchange's key;
2. its originate timestamp equals the request's nonce;
3. mode 4 and VN 4, as sent;
4. LI is not 3;
5. stratum 0 is a kiss (above); stratum 16 to 255 is dropped;
6. receive and transmit timestamps are non-zero, convert to times from
   1970 to 2104, and `t3 >= t2`;
7. the reference timestamp is not later than the transmit timestamp;
8. `delay >= 0`;
9. the distance `rootdelay / 2 + rootdisp + delay / 2` is below 1 s,
   RFC 5905's `MAXDIST`.

Each exchange uses its own socket with its own random port and nonce,
and a second reply to an exchange is dropped, since the exchange has
ended.

## Configuration

The manifest declares the app and leaves it off:

```text
principal ntpd
  ...
session ntpd
  limits @limits.app
  runtime @artifact.emu
  release @artifact.ntpd
  args "... -erx_ntpd servers [...]"
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

`/apps/rc.conf`'s `ntpd_enable="YES"`, or `service ntpd enable`, starts it
at boot, and `service ntpd restart` restarts it, through the start table
alone. The facet row is the only way a domain gets `clock`; root's
session does not hold it. The default list is
[open](#open-decisions), and so is where the operator's list lives.

An enabled app with an empty list ends at start with `no servers` in its
log and its row's last reason at `/proc/apps`, and the start table's
intensity leaves it down.

## What /proc shows

`abi/inspection.txt` gains a kind `clock`, reported by the service and
visible to every scope, at path `time`, so `cat /proc/time/status`
reads it:

| Attribute | Value |
| --- | --- |
| `state` | `unset` while the page's wall offset is zero, so wall time is uptime counted from 1970-01-01; `set` once anything has given it a value, a real-time clock at boot or a step; `unsupported` once the backend has refused a step with `ERX_ENOTSUP` |
| `sample_at` | wall time of the last sample, or `none` |
| `offset_ns` | the last sample's `D`, signed |
| `delay_ns` | its round-trip delay |
| `stratum`, `server` | its server's stratum and address |
| `source` | the domain whose facet sent it, from the facet, never the request |
| `step_at`, `step_ns` | the last step's wall time and size, or `none` |
| `steps` | steps this boot |
| `refused` | panic refusals this boot |

`state` is read from the page at each query, not kept, so a restarted
clock service reports it truly; the restarted service's other attributes
are `none` until the next sample, and its counts start again. The
client's own state, its
names, addresses and kisses, is in its log lines, which the log service
escapes; a kiss code shown there is one of the known atoms or its four
bytes in hex.

## Concurrency and failure

* **One writer.** Only `erx_clock` calls the NIF, one sample at a time
  in its own process, so the page's sequence has one writer in user
  mode, and the call's body serializes in the backend.
* **Two clients** would interleave samples, each step to its own `W`.
  The manifest grants `clock` only to the ntpd template and the start
  table keeps at most one session of a row, so there is one.

| Failure | Who sees it | Result |
| --- | --- | --- |
| the network domain restarts | the client, whose sockets end | the next poll opens a new socket on the new grant |
| the clock service crashes | the facet, which answers `{error, unavailable}` or `{error, failed}` | the client logs it and polls on; the service restarts with its state read from the page |
| the ntpd session crashes | the start table | restarted within the row's intensity; a new grant, so a new first sample |
| DNS fails | the client | retried with backoff; `/proc/time` keeps the last sample |
| every server is silent or denies | the client | backoff to 1024 s and re-resolution; the clock runs on its counter |
| the backend cannot set wall time | the clock service | `{error, unsupported}`; `state` is `unsupported` |
| the page's sequence runs out | the clock service | `{error, limit}`; wall time readers already report it unavailable ([design-kernel.md](design-kernel.md), "Time") |

## Security

* **The parser runs in the app.** NTP bytes are decoded only by
  `erx_ntp_wire` in the ntpd session, which holds `net`, `clock` and
  `log`. A fault there ends that session. The system domain decodes a
  five-element tuple through `erx_clock_facet:decode/1`, at the funnel's
  limits.
* **Whoever holds `clock` decides the time.** Any value within the panic
  threshold per sample, and any value at a grant's first, is accepted;
  the thresholds guard an honest client against a bad server, not the
  system against the client. The authority is the facet row.
* **An on-path attacker can set the clock.** SNTP without authentication
  cannot tell a forged reply from a real one when the forger sees the
  request. That is the residual; Network Time Security (RFC 8633 section
  4.3) is the remedy and is not designed here. A wrong clock can make an
  expired certificate look valid to [design-crypto.md](design-crypto.md)'s
  checks.
* **An off-path attacker** must guess a 64-bit nonce and a random source
  port, and send from the server's address and port.
* **Text.** Kiss codes and server names reach the log only through the
  log service's escaping and `/proc` only through the inspector's;
  addresses are integers.

## Phase 1

On the Fiasco backend, `erx_time_set_wall(wall_ns)` is a service call
that takes no capability and checks no right: any task's call reaches
`erx_fiasco_time_set_wall_body`, which writes the page
(`liberx/backend/fiasco/time_page.c`, `liberx/backend/fiasco/service.c`).
That only the system domain sets the clock is therefore held by the
chokepoint and the facet, not enforced, which is a residual of trusted
code; erXos's kernel checks `WRITE` on the time page. The page starts
zeroed, offset included, so wall time counts from 1970-01-01 at boot
on QEMU `virt`, which has a PL031 the stopgap does not read, and on the
Raspberry Pi 4, which has no real-time clock (`TODO.md`, platforms). The
hosted backend reads its offset once from the host's clock and keeps it
([design-stopgap.md](design-stopgap.md), "The hosted backend"); its
`erx_time_set_wall` answers `ERX_ENOTSUP`, and the clock reports
`unsupported`.

## Verification and testing

Host tests run the pure modules under EUnit; each names the seeded fault
that proves it ran.

| Test | Passes when | Seeded failure |
| --- | --- | --- |
| era conversion | timestamps with the top bit set map to 1968-2036 and clear to 2036-2104, on vectors either side of 2036-02-07 06:28:16 | treating every timestamp as era 0 fails the 2036 vectors |
| offset at boot | `m1`, `m4` of a few seconds of uptime and `t2`, `t3` in 2026 give the exact `W` | RFC 5905's 64-bit modular difference gives a value off by 2^32 s multiples |
| offset and delay | fixed vectors give `W` and `delay` to the nanosecond | dropping the `div 2` doubles `W` |
| reply checks | each of checks 1 to 9 refuses a reply built to break only it, with its reason | removing the nonce comparison accepts the foreign-nonce reply |
| kiss-o'-death | `DENY` and `RSTR` remove the address, `RATE` doubles its interval, `XFOO` and `INIT` are discarded, a kiss with a foreign nonce is dropped | believing a kiss before the nonce check silences the server on the foreign-nonce kiss |
| decide | every row of [Steps](#steps), over `First`, the three distance bands and the three `excess` values | dropping the two-sample rule steps on a single 200 ms sample |
| schedule | over generated event sequences, no two polls to an address closer than 64 s, a burst only on an address's first poll, re-resolution not before the TTL | a floor of 8 s fails the spacing property |
| facet decode | every bound is refused one past its edge | dropping `W`'s upper bound accepts `1 bsl 63` |

Fuzz targets, run by `make check-fuzz`:

* **`erx_ntp_wire_fuzz`** feeds arbitrary binaries of up to 1 KiB to
  `erx_ntp_wire:decode/1` and every accepted reply to the core's checks
  against a fixed outstanding exchange. Properties: nothing raises; an
  accepted header re-encodes to its 48 bytes; every accepted timestamp
  converts within 1970 to 2104. Seeds are generated by the test from the
  encoder: a valid reply, each kiss code, a reply with a MAC, one byte
  short. *Seeded failure:* removing the length check makes a 47-byte
  seed raise.
* **`erx_clock_facet_fuzz`** feeds arbitrary terms, as the funnel decodes
  them, to `erx_clock_facet:decode/1`, as `erx_log_facet_fuzz` does.
  *Seeded failure:* accepting a `Stratum` of 0 fails the property that an
  accepted sample is within every bound.

The network runs use the stack's development-host peers
([design-network-stack.md](design-network-stack.md#the-stack-on-a-development-host)):
the client and the stack run on the host's own OTP over a tap device on
the FreeBSD x86-64 test host, with the clock facet replaced by a recorder
of samples.

* **Against FreeBSD's ntpd** in the jail `erxpeer0`. A jail shares its
  host's clock, so the expected `W` is the host's own wall time minus
  monotonic time: the first sample agrees within 10 ms, and a second
  run agrees again. *Seeded failure:* swapping `t2` and `m1` in the
  offset fails the agreement.
* **Against a scripted responder,** a Ruby program on a UDP socket at a
  jail's address that answers each request by a script: a valid reply
  one hour ahead (one sample, `W` one hour ahead); a foreign nonce, LI 3,
  stratum 16, mode 5 (no sample, each counted under its reason); `RATE`
  (the next request one doubled interval later); `DENY` (no further
  request to it, the next address used); a reply from another port
  (dropped by the stack, no sample). *Seeded failure:* a decoder that
  ignores LI makes the LI-3 script yield a sample.

The QEMU `virt` suite, in a cell with the usual user network, checks the
system side with a test session whose template holds `clock` and which
sends samples itself:

* a first sample for 2026-11-14 makes `/proc/time/status` `set`,
  `os:system_time(second)` in another domain within 1 s of it at once,
  and `erlang:system_time(second)` there within 75 s; *seeded failure:*
  a NIF that answers `ok` without the call leaves `state` `set` but the
  other domain's time near 1970, which fails;
* a later sample 500 ms off is held, the next stepped; one 2000 s off is
  refused and changes nothing; *seeded failure:* the decision without
  the two-sample rule steps on the first;
* a session without the facet row has no `clock` name;
* `service ntpd enable` writes `ntpd_enable="YES"` and starts the
  session, shown at `/proc/apps`, with a manifest whose default list is
  empty, so the row ends `no servers` and goes down.

The QEMU cells have no UDP path from the guest to a host responder: the
harness's user network forwards only TCP into the host
(`tools/lib/erx/qemu.rb`, `guestfwd=tcp:`), with `restrict=on`, and
QEMU's networking page names UDP only for forwards from host to guest
(`docs/system/devices/net.rst`, "hostfwd"). Whether to add one is
[open](#open-decisions).

The Raspberry Pi 4 checklist: with Ethernet and DHCP, `service ntpd
enable`; within a minute `/proc/time/status` is `set`, and a new file's
time in `ls -l` matches a reference clock within a second.

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

## Open decisions

1. **The default server list.** RFC 4330 item 5 requires a built-in
   server to be the vendor's own or used with the operator's permission.
   The options:
   * `pool.ntp.org`: the pool's own guidance and RFC 8633 section 3.6
     send vendors to a zone of their own, so shipping the generic name is
     not that permission;
   * an erXos vendor zone of the NTP Pool, `0.erxos.pool.ntp.org` and so
     on, as FreeBSD ships `freebsd.pool.ntp.org`; it needs a request to
     the pool project, which is for a person of the project to make;
   * none: the manifests ship an empty list, and the operator names
     servers before enabling ntpd.

   Recommendation: none until an erXos vendor zone exists, then the zone.
   Network time is off by default either way, so an empty default costs
   only the step of naming a server on enabling it.
2. **Where the operator's server list lives** (T-R3). `rc.conf` holds
   only `enable`, `display`, `restarts` and `period`
   ([design-apps.md](design-apps.md#the-start-table), AP3), and an
   app's data directory is reachable only by the app. The options:
   * a fifth start-row field, `NAME_flags`, FreeBSD's `rc.subr`
     convention, whose text reaches the app as one argument, for ntpd
     the server list (`ntpd_flags="0.pool.example ntp.example.net"`);
     it changes design-apps' grammar and AP1's argument, though it
     carries no limit, grant or code;
   * a file `ntp.conf` in the ntpd principal's data directory, which
     needs a way for an administrator to write another principal's
     files, which no design gives;
   * the manifest only, which needs a rebuilt image to change servers.

   Recommendation: `NAME_flags`, the general form of FreeBSD's
   per-service flags, decided in design-apps.
3. **Slewing.** Offsets of 128 ms and less are not corrected, so the
   clock saws within that band and steps, by about 128 ms, as often as
   the counter's drift requires; FreeBSD slews them. A slew needs a rate
   on the time page, a new kernel mechanism. Recommendation: no slew; add
   it in erXos's kernel if a consumer needs a wall clock that never steps
   after the first sample.
4. **A UDP path to the host in the QEMU suites.** The system side is
   tested in QEMU by injected samples and the wire against FreeBSD's
   ntpd and the scripted responder on the test host. A QEMU cell with a
   host responder needs a second guest network, a QEMU `stream` netdev
   to a host process that answers ARP and UDP itself. Recommendation:
   do not build it; the tap runs test the same client and stack against
   a better oracle.

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
  `abi/inspection.txt`, `config/manifest/qemu-virt-development.txt`,
  `tools/lib/erx/qemu.rb`.
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
  RFC 8633 (NTP best practices), SHA-256
  `fb275c82378be983511db4fcd533a92a54028c7762be2d9bc0d6fa5c06dc5a84`.
* QEMU v11.1.3 documentation, `docs/system/devices/net.rst`, from
  `https://gitlab.com/qemu-project/qemu/-/raw/v11.1.3/`, SHA-256
  `86f818ab71e6faa113c61f1458ad881e78a29d3c4ad5d8ce5c923f995be1d14b`.
* The research record behind this design:
  `/Users/stas/erxos-scratch/notes/research-pi4-peripherals.md`, section 5,
  written 2026-11-14.
