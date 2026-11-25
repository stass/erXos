# The kiosk dashboard

`examples/dashboard` is the kiosk's app: a full-screen board with the
clock, the date and live prices of Bitcoin, Ether and Solana, each with
a graph of its last 24 hours. It is a demo. Its configuration is
hardcoded in its modules, and it is built as a third party builds an
app, through the SDK alone
([design-packaging.md](../../docs/design-packaging.md#examples)). It is
the first consumer of the HTTPS client that
[design-crypto.md](../../docs/design-crypto.md#https-clients) gives every
session and app: OTP's `ssl` and `httpc` over the `net` grant, with the
image's trust store.

```text
app dashboard
  needs display net
  applications erx_dashboard
  license "BSD-2-Clause"
```

## What it shows

`erx_dashboard` owns the window and draws the board of
`erx_dashboard_view` with the toolkit's LVGL renderer, as a kiosk of
[design-display.md](../../docs/design-display.md) does. Under a header
that credits the source, each quote has its label, its price, its change
since 00:00 UTC with an arrow and a colour for its direction, a status
line and a graph. The graph is the day of 15 min closes the source's
history gave, joined with the live prices since, or, until a history
arrives, the quote's last 180 live prices; the status line says which,
`24 h chart` or `live chart`. A value older than three periods is shown
as `stale` with its age, and a failed round adds its reason. A quote
with no value shows `--` and `waiting` or `no data: REASON`. Offline,
with no network, every quote shows `no data:` and the reason.

## Where the data comes from

Kraken's public REST API, which needs no key or account
(`docs.kraken.com`, "Get Ticker Information" and "Get OHLC Data"):

* the price is `result.PAIR.c[0]` of
  `GET https://api.kraken.com/0/public/Ticker?pair=XBTUSD` (and `ETHUSD`,
  `SOLUSD`), the last trade, and the change is computed against `o`, the
  day's opening price at 00:00 UTC;
* the history is
  `GET https://api.kraken.com/0/public/OHLC?pair=XBTUSD&interval=15&since=T`,
  at most the 720 most recent 15 min entries after `T`, the last one the
  bucket still open.

The result keys are `XXBTZUSD`, `XETHZUSD` and `SOLUSD`. A key that
changes shows as `bad answer`, never as a wrong price. `api.kraken.com`
is served through Cloudflare; its chain ends at GTS Root R4, cross-signed
by GlobalSign Root CA, and its leaf certificates, ECDSA P-256 under
TLS 1.3, live about 90 days, so
the image's trust store holds roots
([design-crypto.md](../../docs/design-crypto.md#the-trust-store)).

Kraken's terms of use could not be read (the page returned an error to
the fetcher), so whether automated access and public display are allowed
is unverified. The kiosk is a demo, not a public service of record, and
credits Kraken on the screen; a deployment that is a public service of
record reads the terms first. CoinGecko's keyless API was left out
because its terms require a credit and forbid storing or redistributing
its data, and Yahoo's because its terms bar automated collection.

## How it is configured

Everything is hardcoded. `erx_quotes_table:table/0` is the source table:
the three quotes, their labels, decimals and 10 s period, and for each
its one source, with the URL, the IPv4 address the URL's host is reached
at, the JSON path of the price, the rule for the change, the credit, the
status line's note and the history request. Changing a source, its
address included, is an edit of that table and touches no reader, core or
view. The table is reviewed code, so nothing checks it at run time.

No name is resolved: the request connects to the row's address and names
the host in the `Host` header and as TLS's server name, so the
certificate is still checked against the host name. Cloudflare's
addresses may change; a changed one shows as `cannot connect` or
`certificate rejected`, never as a value, until the table is edited.
Nothing is kept across a restart, so no value outlives the run that
fetched it.

## How the quotes behave

The live quotes are a pure core and one effect process. `erx_quotes`,
started by the dashboard and linked to it, ticks
`erx_quotes_core` once a second, makes the `httpc` requests the core asks
for, classifies each answer (`erx_quotes_http`), reads each body
(`erx_quotes_extract`) and sends the dashboard the board of
`erx_quotes_view` when it changes. The core reads no clock and no random
generator; time and jitter are its arguments.

Every number on the screen is a value paired with the monotonic time it
was fetched, or nothing, and the board is a pure function of those
pairs, the current monotonic time and each quote's last failure. A
failure never replaces or alters a value; it only adds a reason. So
whether a value is stale, and how old it is, follows from one
subtraction, and no path can show a value `erx_quotes` did not receive
or hide its age. Ages and deadlines are monotonic, so setting the wall
clock moves neither.

* **Rounds.** A quote's round is due once its period has passed. It asks
  the quote's sources in order, passing over one held back by a
  `Retry-After`; a value ends the round, and when every source fails the
  first source's reason is the quote's.
* **Backoff.** After a failed round the quote waits
  `min(period * 2^failed_rounds, 15 min)`, times a jitter in
  `[0.8, 1.2)`, and never less than until its sources' `Retry-After`,
  which holds back that source alone, for up to an hour. `httpc` never
  retries on its own.
* **History.** A quote asks for its history at start and then an hour
  after each request, answered or not. Its `since` is the wall clock less
  a day, rounded down to the start of its 15 min bucket, so the answer is
  about 97 entries, about 10 KB; Kraken's whole answer of 720 entries is
  too near the 64 KiB body bound to leave `since` out. A failed history
  changes nothing but a `Retry-After` hold. Each history replaces the
  series whole. A live price joins the series by its wall-clock bucket,
  repeating the last close over buckets it skips and replacing the last
  close when its bucket is not later, so the line ends at the live price
  whatever the clock reads; one that would skip more than an hour of
  buckets drops the series, since no price was known in that gap, and
  the graph shows the live prices until the next history.
* **Bounds.** At most one round and one history per quote are in flight,
  six requests at once; each body is at most 64 KiB and each head
  10 KiB; a quote keeps 180 samples and a series of at most 96 points.

## Reasons

| Reason | Shown as | Comes from |
| --- | --- | --- |
| `no_net` | `no network` | `eacces` from a socket call: the session holds no `net` grant |
| `connect` | `cannot connect` | a refused or unreachable connect, or its timeout |
| `timeout` | `timed out` | `httpc`'s request timeout |
| `certificate` | `certificate rejected` | a TLS alert of a failed path or name check |
| `clock_unset` | `clock not set` | `certificate_expired` while the wall clock reads before 2000 |
| `tls` | `TLS failed` | any other TLS alert |
| `{status, Code}` | `HTTP CODE` | a status other than 200 and the followed redirects |
| `redirect` | `bad redirect` | a redirect out of the origin asked, without a usable `location`, or a fourth hop |
| `too_big` | `answer too big` | a body or head past its bound, in any framing |
| `bad_data` | `bad answer` | the reader's refusal |
| `failed` | `failed` | an answer the classifier does not recognise |

The classifier never names a cause it did not see.

## The clock

Certificate validation compares each certificate's dates with the wall
clock ([design-crypto.md](../../docs/design-crypto.md#time),
[design-time.md](../../docs/design-time.md)). An unset clock reads 1970
plus the uptime, before every public certificate's validity, so `ssl`
refuses the chain with `certificate_expired`; no machine erXos runs on
reads a time before 2000 once its clock is set, so the dashboard shows
`clock not set` for that case. A clock that starts at the build's date
passes the chain while the image is younger than its certificates. A
wall clock behind the source's makes the history request ask for more
than a day; an answer of more than 200 entries, a lag past 25 h 45 min,
is refused as `bad answer`, and the graph stays `live`.

## Security

* **Untrusted input.** Every response is bounded by `httpc` before it is
  read (the limits in `httpc:request/4`'s fourth argument, which `inets`'
  edit applies in every framing), parsed by total functions with one
  failure path each, and covered by a fuzz target. JSON is decoded by
  `json:decode/1`, which does not recurse and makes no atom; a price is a
  JSON number or a decimal string of at most 32 bytes, from 10^-12 to
  below 10^15; a history holds 1 to 200 entries of exactly 8 items, at
  strictly increasing times on 900 s steps below 2^32. A malformed answer
  is a reason, never a crash or a value.
* **No byte of a response reaches the screen as text.** The board's
  texts are the table's labels, credits and notes, fixed words and
  numbers `erx_quotes_view` formats; history closes reach the screen only
  as points of a graph. The renderer escapes every text property anyway,
  and log lines go through the log service's escaping.
* **HTTPS only.** Every row is `https`; `autoredirect` is off, and
  `erx_quotes` follows a redirect only within the origin it asked (same
  scheme, host and port), through the same address, so no source can send
  it to plain HTTP or another host, this machine's listeners included.
  TLS uses the system's defaults with the server name added: the image's
  trust store, the host name checked, TLS 1.3 or 1.2.
* **One connection per request.** Every request sends
  `connection: close`: `httpc` reuses a kept-alive connection by address
  and scheme alone, so a request for another host at the same address
  would otherwise ride a connection whose certificate was checked against
  the first name.
* **What it trusts** is the image's trust store and its own code. A
  source, whoever holds the address, or anyone on the path can withhold
  an answer, which shows as a reason; none can make the screen show a
  number that did not come over a connection the trust store vouches for,
  named for the table's host.

## Building and running

The package is built through the SDK. The Raspberry Pi 4's card
(`make pack PLATFORM=raspi4b`) carries it enabled, and the board shows
the dashboard within about a minute of boot
([the Pi 4 guide](../../docs/guide/raspberry-pi-4.md)). An image builder
adds it to another image with `tools/erx pack --app examples/dashboard
--enable dashboard`. On the host, `erx_ui_host` draws it without a
display.

## Testing

The host tests run under stock OTP with only the SDK on their paths, as
`make check` runs every example's: `test/host/erx_dashboard_test.rb`
compares the offline dashboard, drawn by the host's erx-lvgl, with the
reference picture `test/display/reference/dashboard`, and `test/host/erx_quotes_test.rb`
runs the EUnit suites in `lib/erx_dashboard/test/`. The core's suites
include a property over generated event sequences: every price on the
board is the price of some successful outcome for that quote, shown
stale exactly when its age passes three periods. The fetch suite runs
`erx_quotes` unchanged against `ssl` servers on the loopback, reached by
address under a name that does not resolve, with a test root; a
certificate for another name must show `certificate rejected`, an
oversized body `answer too big`, and the server answers only requests
that ask for `connection: close`.

### The fuzz target

`lib/erx_dashboard/test/erx_quotes_fuzz.erl`, run by
`tools/fuzz/erx_quotes.rb` at a small budget at the landing gate and at
its configured one by `make check-fuzz`, drives:

* `erx_quotes_extract:value/2` with random bytes, mutated and truncated
  answers, nesting 10,000 deep and 400-digit numbers: nothing raises, and
  every accepted price is finite and within its bounds. *Seeded
  fault:* accepting a JSON number without the bound check lets `1.0e300`
  through.
* `erx_quotes_extract:history/2` and the join into a series, with clocks
  up to two days either side of the history's end: the series stays
  absent or 1 to 96 points on 900 s steps, holds no close that was
  neither an entry's nor a live price, and ends at the last live price.
  *Seeded faults:* removing the price bound; dropping the trim of a
  join; leaving out a live price of an earlier bucket.
* `erx_quotes_http:classify/4` over arbitrary terms: it raises on nothing
  and answers one of its three shapes.

### The QEMU cell

The kiosk suite (`tools/lib/erx/kiosk.rb`) boots the package from its
release medium with no network device and compares the screen with the
reference picture, every quote at `no data:`. Its cell
`kiosk/hvf-1cpu-quotes` checks live quotes without the internet: a test
image whose trust store adds the root of an offline HTTPS fixture
(`tools/lib/erx/quotes_fixture.rb`), and restricted QEMU user networking
whose one `cmd:` guest forward, for the table's address and port 443,
relays each connection to the fixture on the host's loopback, so nothing
the guest sends leaves the host. The fixture's chain is valid from the
epoch to 9999, so the cell depends on no clock. `erx_quotes` logs one line
per change of a quote's state, as `quotes: btc fresh 64,412.50
kraken_btc`; the cell passes when sol shows `quotes: sol no_data --
too_big` for the fixture's first, oversized body, every quote then
reaches `fresh`, and each history is logged (the fixture answers no
history request: `TODO.md`). *Seeded fault:* a trust
store with another root than the fixture's makes every quote `no_data --
certificate`.

## References

* Kraken REST API, "Get Ticker Information",
  <https://docs.kraken.com/api/docs/rest-api/get-ticker-information>, and
  its rate limits guide.
* Kraken REST API, "Get OHLC Data",
  <https://docs.kraken.com/api/docs/rest-api/get-ohlc-data> (SHA-256
  `eca28e113ae318b9d65a56abf808ee712b14683afa466aa07f1349ba67cc79d7`),
  and its OpenAPI description <https://docs.kraken.com/openapi/spot-rest.yaml>,
  OpenAPI 3.0.0, version 1.1.0 (SHA-256
  `4e730d0c503de30a57dadd09fd07883af6aa3538e3bc4adabcd0e3576f1d0e1f`),
  both fetched 2026-11-17.
* CoinGecko API terms, <https://www.coingecko.com/en/api_terms>.
* OTP 29.1.2 source archive, SHA-256
  `c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049`
  (the pin in `deps.lock`): `lib/inets/src/http_client/httpc.erl`,
  `httpc_handler.erl`; `lib/ssl/src/ssl.erl`, `ssl_handshake.erl`;
  `lib/public_key/src/pubkey_cert.erl`, `pubkey_os_cacerts.erl`;
  `lib/stdlib/src/json.erl`. The behaviour `erx_quotes` relies on is cited by
  file and line in its modules.
