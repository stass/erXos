# Cryptography: OpenSSL 3.5 and OTP's `crypto`

OTP's `crypto`, `public_key`, `asn1`, `ssl` and `ssh` run on erXos over
OpenSSL 3.5, in every domain that loads them except the system domain,
which never holds OpenSSL. This document says where the library runs, how
it is built, linked and seeded, and how its use is tested. The SSH
service built on it is [design-ssh.md](design-ssh.md); the vault's use of
it is [design-system.md](design-system.md#the-vault); TLS for the web is
[design-web.md](design-web.md#the-network-front-end).

## Context

Three subsystems need cryptography: the web domain's TLS listener, the
vault's Argon2id, HKDF and AES-256-GCM, and SSH. The architecture already
decides the library: "OTP's `crypto`, `ssl` and `ssh` use OpenSSL 3.5"
and "a small verifier keeps the full library out of the system domain"
([design.md](design.md#decisions)); its dependency row says "in
application domains and the vault's, never in the system domain". OTP's
`crypto` is written against OpenSSL, and 3.5 is a long-term-support
series, supported until 2030-04-08
([research](research-boards-storage.md#cryptography-libraries)).

Unpredictable values come from the kernel's generator alone:
`erx_bytes:entropy/1` is Erlang's one entry, and OpenSSL's generator is
seeded from `erx_entropy_read`, never from another source
([design.md](design.md#decisions)). How good the generator's seed is
belongs to the machine: the boot banner reports `entropy_quality`, a
release build stops the boot on a weak seed and a development build
continues ([design-kernel.md](design-kernel.md#interrupts-time-and-entropy));
on the stopgap the seed comes from the counter alone
([design-stopgap.md](design-stopgap.md#the-call-table)).

ERTS is built once per execution flavour, as the interpreter and as
BeamAsm, and each build is linked into the runtime images that use it
([design-runtime.md](design-runtime.md#beamasm)). The system domain runs
the interpreter flavour, so that the trusted base holds no generated code
and no C++; command domains and, in deterministic mode, every domain run
it too.

What the sources say, read at the pins of [Sources](#sources):

* **OTP links its NIFs statically when asked.** With static NIFs, ERTS's
  build adds `asn1rt_nif.a` and `crypto.a` to the emulator
  (`erts/emulator/Makefile.in:229-237`) and generates the static NIF
  table `driver_tab.c` with `utils/make_driver_tab` (`:702-704`);
  `--with-ssl=PATH` names the OpenSSL to build against and
  `--disable-dynamic-ssl-lib` links it statically
  (`make/configure.ac:256-286`). erXos's ERTS loads only statically
  linked NIFs ([design-runtime.md](design-runtime.md#everything-else)).
* **`crypto` builds without engines.** Engine support is compiled only
  when OpenSSL lacks `OPENSSL_NO_ENGINE`
  (`lib/crypto/c_src/openssl_config.h:387-388`).
* **`crypto:strong_rand_bytes/1` is OpenSSL's `RAND_bytes`**
  (`lib/crypto/c_src/rand.c:41`), and `crypto:rand_seed/1` only adds
  bytes through `RAND_seed` (`rand.c:150`).
* **OpenSSL's seed sources are chosen when it is configured**
  (`--with-rand-seed`, `INSTALL.md:476-520`). The `os` method turns on
  both `getrandom` and `devrandom`
  (`providers/implementations/rands/seeding/rand_unix.c:205-210`). The
  `getrandom` method's `syscall_random` first looks for libc's
  `getentropy` through a weak reference, except on FreeBSD, NetBSD and
  DragonFly (`rand_unix.c:354-386`), then calls the `getrandom` system
  call on Linux, `getrandom()` on FreeBSD 12 and later, and on any other
  target fails with `ENOSYS` (`:388-405`). Its caller asks for what the
  pool still needs, gives up after three failed attempts, and leaves the
  pool empty on an error other than `EINTR` (`:637-660`); a generator that
  gets no seed refuses to produce bytes (`INSTALL.md:1979-1983`). `rdcpu`
  reads the CPU's `RNDRRS` on AArch64 (`INSTALL.md:508-511`).
* **A weak reference does not pull a member out of an archive**: LLD
  leaves it undefined, so it resolves to null, unless another reference
  extracts the member (`lld/ELF/Symbols.cpp:416-418`, `:640-646`).
  erXos's runtime code is compiled for `aarch64-none-elf`
  (`tools/lib/erx/musl.rb:17`), which defines neither `__linux` nor
  `__FreeBSD__`.
* **musl's `getrandom` is the system call** `SYS_getrandom`
  (`musl/src/linux/getrandom.c`); its `getentropy` refuses more than 256
  bytes with `EIO` and loops over `getrandom` otherwise
  (`musl/src/misc/getentropy.c`).
* **OpenSSL finds AArch64 CPU features by `getauxval` only on glibc,
  Android, FreeBSD and OpenBSD**; elsewhere it probes instructions and
  catches `SIGILL` (`crypto/armcap.c:61-105`, `:234-250`), from a
  constructor that runs at load (`armcap.c:65-67`). The environment
  variable `OPENSSL_armcap` overrides both (`armcap.c:265-268`).
* **OpenSSL cross-builds from a target description**: `linux-aarch64`
  is `linux-generic64` with the AArch64 assembler
  (`Configurations/10-main.conf:768-772`), and `--config=FILE` adds
  targets without editing the tree (`Configure:30`).
* **OpenSSL's configuration reads more than the library.** The top-level
  `build.info` names `crypto`, `ssl`, `apps`, `util`, `tools`, `fuzz`,
  `providers`, `doc` and `exporters` unconditionally, `test` unless
  `no-tests`, `demos` when enabled, and `engines` while the 3.0
  deprecated interfaces are on (`build.info:4-14`). `Configure` skips a
  directory only for a disabled feature's subdirectory of `crypto/`, or
  `engines/` under `no-engine` (`Configure:1947-1949`, `:2064-2068`), and
  opens the `build.info` of every other (`:2208-2213`). It reads its Perl
  modules from `util/perl` and `external/perl` (`:16`, `:20`; the
  template engine `Text::Template` comes from `PERL5LIB`, below) and its
  version from `VERSION.dat` (`:345`). `demos` is off by default
  (`:601`).

## Requirements

* **CR1.** No code of OpenSSL is mapped into the system domain, and no
  constructor of it runs there.
* **CR2.** OpenSSL's generator is seeded only from `erx_entropy_read`; a
  failed read fails the seeding, and no other source is tried.
* **CR3.** `crypto`, `public_key`, `asn1` and `ssh` on erXos agree with
  stock OTP 29.1.2 built against the same OpenSSL configuration, case by
  case in OTP's own suites.
* **CR4.** OpenSSL uses the CPU's AES and SHA instructions where the CPU
  has them and constant-time software where it does not, decided from the
  features the kernel reports, never from a probe that faults.
* **CR5.** OpenSSL reads no file and opens no socket on erXos.

## What the code does today

* `lib/crypto` and `lib/asn1` are imported into `otp/`; `otp/ORIGIN.md`
  excludes `lib/public_key`, `lib/ssh` and `lib/ssl` as "outside the
  shipped OTP application set in the runtime design".
* OpenSSL 3.5.9 is imported into `openssl/` with its three edits, pinned in
  `deps.lock`, and `tools/erx build openssl` makes `libcrypto.a` for
  `erxos-aarch64` (`tools/lib/erx/libcrypto.rb`,
  `config/openssl/erxos-aarch64.conf`).
* Each runtime build (`tools/lib/erx/native_runtime.rb`) makes
  `libcrypto.a` against its own musl, points OTP's configure at it with
  `--with-ssl`, builds `crypto.a` and `asn1rt_nif.a` by their
  applications' `static_lib` targets, and makes `driver_tab_crypto.o`,
  the static NIF table that names them (`erts/emulator/Makefile.in`,
  `erx_crypto_tab`), from the archives `tools/lib/erx/domain_image_apps.rb`
  lists. `libbeam.a` holds no static NIF table: the system image links
  OTP's `driver_tab.o` by name, and the interpreter and BeamAsm images
  link the four in its place.
* The Fiasco backend's start block (`liberx/backend/fiasco/libc_start.c`,
  `erx_fiasco_libc_start`) gives musl `AT_HWCAP` and `AT_HWCAP2` from the
  boot information page's feature words (`hwcap` and `hwcap2`,
  `abi/erx_abi.txt`), as the C library seam's table says
  ([design-runtime.md](design-runtime.md#the-c-library-seam)): the
  features the boot CPU has and the kernel enables and saves for user
  mode, never `HWCAP_CPUID`
  ([design-arch-aarch64.md](design-arch-aarch64.md#cpu-feature-words)).
  A program takes its session's words from its argument registers
  ([design-programs.md](design-programs.md#the-channel)).
* `erx_bytes:entropy/1` exists (`erlang/apps/erx/src/erx_bytes.erl`).

## Design

### Three runtime images, and OpenSSL in two of them

The construction is that **the system domain runs an image of its own,
and OpenSSL is linked into every other image**. ERTS's two builds are
linked three times:

| Image | Build | Static NIFs beyond ERTS's and erXos's own | Run by |
| --- | --- | --- | --- |
| the **system image** | the interpreter build, no BeamAsm, asmjit or C++ | none | the system domain alone, in every mode |
| the **interpreter image** | the interpreter build | `crypto` and `asn1rt_nif`, with OpenSSL's `libcrypto` | command domains, every domain but the system domain in deterministic mode, and domains whose specification chooses it |
| the **BeamAsm image** | the BeamAsm build | `crypto` and `asn1rt_nif`, with OpenSSL's `libcrypto` | every other ERTS domain |

Each requirement follows:

* **CR1 holds by construction.** OpenSSL is absent from the one file the
  system domain maps, so no call, constructor or data of it exists there.
  No list of modules the system release must avoid loading is needed, and
  a `crypto` beam put into the system release by mistake fails at its
  `on_load`, because the image has no NIF named `crypto`.
* **Every other domain has the same library.** A domain needs no choice
  to get `crypto`: the web domain's TLS, the vault, the SSH domain and
  every session find it in whichever image they run, including in
  deterministic mode, where every domain but the system domain runs the
  interpreter image.
* **The system image is what the system domain runs today, renamed.** The
  interpreter image as [design-runtime.md](design-runtime.md#beamasm)
  describes it (no BeamAsm, asmjit, libc++ or libc++abi, no
  `ERX_IMAGE_JIT`) is the system image. The interpreter image is a second
  link of the same build's objects that differs from it by its static NIF
  table, generated by `make_driver_tab` with the two NIFs, and by the two
  NIFs' archives and `libcrypto`. Each link names its one table, since
  `libbeam.a` holds none, so a link that named two would fail on a
  duplicate symbol and one that named none on an undefined one. It carries
  no `ERX_IMAGE_JIT` either, so command domains still make no code.

The BeamAsm image is the one link of the BeamAsm build, with the same
NIFs as the interpreter image. Each image is a file of the boot image,
mapped and shared by the domains that run it, so OpenSSL's text is in
memory once for the domains of the interpreter image and once for those
of the BeamAsm image, when domains of both run. The build's static NIF
classification ([design-runtime.md](design-runtime.md#everything-else))
gains one column, the images each NIF is linked into.

### Domains that call no OpenSSL

A domain that runs the interpreter or BeamAsm image maps OpenSSL whether
or not it uses it, and the library's constructor on AArch64,
`OPENSSL_cpuid_setup` (`armcap.c:65-67`), runs there at load, reading
the feature words and `OPENSSL_armcap` (below), and the CPU's main ID register
only when those claim `HWCAP_CPUID`, which the kernel's feature words
never do (below). Nothing
more of
OpenSSL runs in a domain that never calls `crypto`. The network domain
is one: no module of the network stack calls `crypto`, which a build
check of the stack proves
([design-network-stack.md](design-network-stack.md#build-checks)), and
its boot script names no `crypto`, so `crypto` is not on its code path,
no `on_load` there reaches the NIF and no packet reaches OpenSSL. (The
one domain release holds every script's applications, so a domain could
still load `crypto` by name; nothing in the network domain does.) So the network domain keeps the BeamAsm image
and its speed, and what keeps OpenSSL off its packets is the stack's own
check rather than the image; the system domain alone needs the image to
lack the library, since a constructor run there is code of the library
in the trusted base.

### Building OpenSSL

OpenSSL 3.5.9 is imported into `openssl/` as erXos's code, with an
`ORIGIN.md` recording the release tarball's SHA-256 and each file's, and
its `LICENSE.txt`. It is changed (below), so it enters the tree rather than
being fetched and built unchanged
([design.md](design.md#dependencies)). The import keeps whole every
directory and file that `Configure` reads under the configuration below,
but one module, so OpenSSL's build machinery runs unedited but for one list:
`Configure`, the
top-level `build.info`, `VERSION.dat`, `configdata.pm.in`, `Configurations/`,
`apps/`, `crypto/`, `doc/`, `exporters/`, `external/`, `fuzz/`,
`include/`, `providers/`, `ssl/`, `tools/` and `util/`. It leaves out only
what that configuration never reads: `test/` (`no-tests`), `demos/` (off
by default), `engines/` (`no-engine`), `os-dep/`, `VMS/` and `ms/`, which
other systems' configurations name, the seven empty directories the
release carries (`cloudflare-quiche/`, `oqs-provider/`,
`pkcs11-provider/`, `python-ecdsa/`, `tlsfuzzer/`, `tlslite-ng/` and
`wycheproof/`), and the Perl module `Text::Template` that the release
bundles under `external/perl/`. That module is a build tool OpenSSL
uses as released: `Configure` and make's generators (`util/dofile.pl`) load
it on the build host. It is fetched, not imported: `deps.lock` pins
Text-Template 1.56's CPAN tarball (`text-template`) by SHA-256, the fetch
step verifies it and unpacks it out of tree, and the build sets `PERL5LIB`
to its `lib/` for `Configure` and make, which see none of the caller's
`PERL5LIB` or `PERL5OPT`. `external/perl/MODULES.txt`, the list of
directories that `OpenSSL::fallback` appends to Perl's search path, is
empty, since that module refuses a listed directory that is absent.
`make check-openssl`'s integration test
(`test/integration/libcrypto_build_test.rb`) proves the set: it runs
`Configure` with erXos's options on the imported tree and builds
`libcrypto.a`, and on a copy without `ssl/build.info` sees `Configure`
fail on the `build.info` it cannot open. OpenSSL's `Configure` and its
Perl assembler generators are inherited build machinery, invoked through
one entry point of erXos's top-level build, as OTP's `configure` is
([design.md](design.md#build-and-toolchain)), and the build makes the
`libcrypto.a` target alone.

The build configures one target of erXos's own, `erxos-aarch64`, in a
file the build passes with `--config`: `linux-aarch64`'s settings with
erXos's compiler, sysroot and flags, and `-D__erxos__`. The configuration:

```
./Configure erxos-aarch64 --config=<erXos's target file>
    --with-rand-seed=getrandom
    no-shared no-module no-dso no-engine no-async no-sock
    no-autoload-config no-ui-console no-apps no-tests no-docs
    no-legacy no-quic no-http
```

Each option has one reason:

| Option | Reason |
| --- | --- |
| `--with-rand-seed=getrandom` | the one seed path (below); `os` would add `devrandom` (`rand_unix.c:205-210`) and `rdcpu` would read the CPU directly |
| `no-shared`, `no-module`, `no-dso` | ERTS links NIFs statically and loads no library at run time; providers are built into `libcrypto` |
| `no-engine` | engines are loadable code; `crypto` compiles without them (`openssl_config.h:387`) |
| `no-async` | its jobs switch stacks with `ucontext`, which musl does not provide and nothing on erXos asks for |
| `no-sock`, `no-http` | `crypto` asks OpenSSL for no network I/O, and the seam has no sockets in a runtime |
| `no-autoload-config`, `no-ui-console` | no configuration file and no terminal prompt are read (CR5) |
| `no-legacy` | the legacy provider (MD4, RC4, Blowfish, single DES and others) serves nothing erXos uses; `crypto:supports/0` lists what remains |
| `no-quic`, `no-apps`, `no-tests`, `no-docs` | nothing erXos ships; OTP's `ssl` implements TLS itself over `crypto` and links no `libssl` |

The assembler is kept: OpenSSL's AArch64 code is where its AES, GHASH,
SHA and ChaCha20 are fast and constant-time.

**Three edits**, each under `__erxos__`, the first two taking FreeBSD's
branch; each file carries its notice:

* `crypto/armcap.c` defines `OSSL_IMPLEMENT_GETAUXVAL` under `__erxos__`,
  so CPU features come from `getauxval(AT_HWCAP)` and `AT_HWCAP2`, which
  the seam answers from the boot information page, or in a program from
  its argument registers, and the `SIGILL`
  probe is never compiled. One read of the CPU stays: when the words
  claim `HWCAP_CPUID`, `OPENSSL_cpuid_setup` reads the main ID register (in the
  tree's `armcap.c`, the `ARMV8_CPUID` test before `_armv8_cpuid_probe`)
  to pick code tuned for the core, and user mode's read of it traps on
  erXos. The kernel's feature words never claim `HWCAP_CPUID` (the rule
  `TODO.md`'s feature-words item carries to where the words are filled),
  so the read is not reached. `OPENSSL_armcap` sets the features and
  returns before that test, so it never causes the read. With the words
  0, as on the stopgap, no feature bit is set, `OPENSSL_armcap_P` stays
  0, and every algorithm takes its software path.
* `providers/implementations/rands/seeding/rand_unix.c` includes
  `<sys/random.h>` and, in `syscall_random`, skips the weak `getentropy`
  lookup and returns `getrandom(buf, buflen, 0)` under `__erxos__`, so
  the seed path is a direct, strong call that the link resolves to musl's
  `getrandom`.
* `crypto/arm64cpuid.pl`'s `_armv7_tick` returns 0 under `__erxos__`
  instead of reading the timer's counter, which only the C library's
  `erx_fiasco_counter` reads (the counter-read build check of every
  linked program refuses the read). OpenSSL calls it only when
  `OPENSSL_armcap` sets `ARMV7_TICK`, and `OPENSSL_rdtsc` answers 0
  without that bit anyway.

### Seeding

OpenSSL's one seed path is `getrandom`, in musl, over the seam's
`SYS_getrandom` row, over `erx_entropy_read`, in `liberx`:

* **The call is strong.** `syscall_random` calls `getrandom` by name, so
  the link takes musl's `getrandom.o` into every image with `libcrypto`;
  no weak reference is left to resolve to null and fall through to
  `ENOSYS` (`rand_unix.c:401-403`).
* **The seam's `SYS_getrandom` row** fills the caller's buffer with
  `erx_entropy_take` in pieces of at most 256 bytes (`entropy_bytes_max`),
  returns the full length, and on any failed piece returns `-EIO`, so musl
  sets `errno` to `EIO`. It never returns a short count and never fills
  from another source. It answers the same in a program
  ([design-programs.md](design-programs.md)), so a native program's
  `getrandom` and `getentropy` behave as a runtime's.
* **Any request size works.** The row loops in pieces, so however much
  OpenSSL's pool asks for at the first seed or at a reseed, the answer is
  all of it or `EIO`; musl's 256-byte bound on `getentropy` is not on
  OpenSSL's path.
* **A failed seed fails the operation.** On `EIO` OpenSSL's pool stays
  empty (`rand_unix.c:637-660`), and its generator refuses to produce
  bytes until it is seeded (`INSTALL.md:1979-1983`), so
  `crypto:strong_rand_bytes/1` raises, key generation fails, and an SSH
  or TLS handshake that needs fresh randomness ends; no caller continues
  with a value it never got, as the entropy decision requires. Since
  `getrandom` is the only method compiled in, there is no second source
  to fall back to.
* **Quality is the machine's.** OpenSSL credits each seed byte with eight
  bits, as from any operating system source. Whether the kernel's seed
  deserves that is reported by `entropy_quality`; a release build never
  runs on a weak seed, and a development build on the stopgap does, with
  the banner saying so. Keys made on such a boot are as weak as the
  seed, which [design-ssh.md](design-ssh.md#host-keys) records for the
  host key.
* **Reseeding** follows OpenSSL's own intervals, each a call through the
  same path; on the stopgap each is a request to the root's generator
  service. A generator already seeded need not read the kernel for every
  request, so a failure of the kernel's generator after the first seed
  shows at the next reseed, not at once.

`crypto:rand_seed/1` adds bytes to OpenSSL's generator and never replaces
its seed, so it cannot weaken it.

### CPU features and constant time

OpenSSL picks its AES, GHASH, SHA and polynomial code from the feature
words, so the choice follows the kernel's report:

* **With the ARMv8 cryptographic extension**, as on the development
  hosts' CPUs under HVF and on the Raspberry Pi 5's Cortex-A76
  (unverified for the Pi 5, settled as for the Pi 4 below), AES-GCM
  uses the AES and polynomial-multiply instructions, which take the same
  time for every key and input.
* **Without it**, as on the Raspberry Pi 4's Cortex-A72 (unverified: the
  board's identification registers, which the boot reads, settle it),
  AES uses OpenSSL's vector-permutation code for NEON, which uses no
  table indexed by secret data, and ChaCha20-Poly1305 is the faster
  cipher, which is first in SSH's order
  ([design-ssh.md](design-ssh.md#algorithm-policy)).
* **X25519, Ed25519 and ML-KEM-768** are OpenSSL's own constant-time
  implementations. erXos adds no cryptographic code to OpenSSL and calls
  no primitive outside `crypto`'s NIF.
* **`OPENSSL_armcap`** in a domain's environment still overrides the
  feature words (`armcap.c:265`). A domain's environment is set by its
  own specification or by its own processes, so the override can only
  slow or weaken that domain's own cryptography, or, by claiming a
  feature the CPU lacks, end that domain at the first use of the
  algorithm that needs it, never another's.

### OTP's applications

`lib/crypto`, `lib/asn1`, `lib/public_key`, `lib/ssh` and `lib/ssl` are
imported into `otp/` from the same OTP 29.1.2 archive as the rest, as
erXos's code, with their test suites as fixtures, and `otp/ORIGIN.md`
drops their exclusions. Each ships its beams, `.app` and headers, as the
other shipped applications do
([design-runtime.md](design-runtime.md#everything-else)), in releases that
ask for them; the system release never does.

* **`crypto`** is unchanged. Its NIF is built as `crypto.a` against
  `openssl/`'s `libcrypto.a` and linked into the interpreter and BeamAsm
  images. Its `on_load` finds the NIF in the static table.
* **`asn1`** ships its run-time module `asn1rt_nif`, which
  `public_key`'s generated decoders call, and none of the ASN.1 compiler,
  which runs at build time on the host to generate `public_key`'s modules.
* **`public_key`** is unchanged.
* **`ssh`** takes the edits of [design-ssh.md](design-ssh.md#edits-to-otps-ssh).
* **`ssl`** is TLS's, under [design-web.md](design-web.md#the-network-front-end).

The oracle's stock OTP 29.1.2 builds `crypto` on the development host
against the same OpenSSL 3.5.9 with the same options, the target and the
three edits aside, so `crypto:supports/0` agrees on both sides and a
difference between them is erXos's
([design-host-oracle.md](design-host-oracle.md)).

## Invariants

| Invariant | Holds because |
| --- | --- |
| **K1.** The system domain holds no OpenSSL | its image's link names neither `libcrypto.a` nor a NIF archive or table of `crypto` or `asn1rt_nif`; the list's shape holds it, and a host test of the list pins that shape (below) |
| **K2.** OpenSSL's only seed is `erx_entropy_read` | `getrandom` is the only seed method compiled in, `syscall_random` calls it directly, and the seam's row reads nothing else |
| **K3.** A failed seed never yields bytes | the seam answers `EIO` and OpenSSL's unseeded generator refuses |
| **K4.** CPU features come from the kernel's report | `armcap.c`'s edit compiles `getauxval` and no `SIGILL` probe; its one read of the CPU, the main ID register, runs only when the feature words claim `HWCAP_CPUID`, which the kernel's never do (`liberx/backend/core/arch/aarch64/cpu_features.c`, `test/host/cpu_features_test.rb`) |
| **K5.** OpenSSL loads no code, and reads no file unless a caller names one | `no-shared`, `no-module`, `no-dso` and `no-engine` leave no loader; `no-autoload-config` reads no configuration file at start. OpenSSL's file functions (`BIO_new_file`, the configuration and store loaders) stay compiled and run only on a path a caller passes, and `crypto`'s NIF passes none |

## Failure handling

| Failure | Seen as | Result |
| --- | --- | --- |
| the kernel's generator does not answer (the stopgap's generator service down) | `getrandom` fails with `EIO` | OpenSSL's generator stays unseeded, or fails its next reseed; `crypto:strong_rand_bytes/1` raises; the caller's operation fails and is retried by its own supervisor |
| a weak seed on a development build | the banner's `entropy_quality` | keys work and are as weak as the seed; a release build never boots so |
| a domain's environment sets `OPENSSL_armcap` | slower or software code paths, or a fault at the first use of an instruction the CPU lacks | that domain's own cryptography only; a fault ends that domain |
| a `crypto` beam in the system release | `on_load` fails: no static NIF `crypto` | the system release does not boot; the build's release check refuses it first |
| the imported tree lacks a directory `Configure` reads | `Configure` fails in the build and in `make check-openssl` | the build fails, naming the `build.info` it could not open |

## Security

* **What OpenSSL's code can reach** is the memory and capabilities of the
  domain it runs in, as any code there can. Which domains load it, and so
  what a defect in it exposes, is each user's design: the web domain's
  connections, the vault's keys
  ([design-system.md](design-system.md#the-vault)), the SSH domain's
  connections ([design-ssh.md](design-ssh.md#security)). It never runs in
  the system domain, so no defect of it reaches the domain library, the
  manifest's policy or the machine's end.
* **No code is made.** OpenSSL makes no machine code at run time; in the
  BeamAsm image it runs beside the JIT under the same rule, that no
  mapping is writable and executable at once.
* **What reaches OpenSSL from outside** is what `crypto`'s NIF passes it:
  key material and data that OTP's Erlang code has already decoded and
  bounded. OTP's own parsers (`public_key`'s key and certificate decoders,
  `asn1rt_nif`'s BER reader, `ssh`'s message decoders) are OTP's, kept as
  OTP ships them, and tested by OTP's suites against the oracle.

## Verification

Each test names the seeded failure that proves it ran.

| Test | Passes when | Seeded failure |
| --- | --- | --- |
| `crypto_SUITE`, `public_key_SUITE`, `pubkey_*_SUITE` and `asn1`'s run-time suites through `make check-oracle` | every case agrees with stock OTP 29.1.2 built against the same OpenSSL | erXos's OpenSSL configured with `no-chacha`: the ChaCha20 cases differ from the oracle and the comparison fails |
| the system image's link list, a host test (`test/host/native_runtime_link_test.rb`) | the system image's link list (`NativeRuntime::Built#system_archives`) names its own static NIF table once and no `libcrypto.a`, `crypto.a`, `asn1rt_nif.a` or `crypto`'s table; each domain image's names `crypto`'s table and not the system image's | stand-ins of `libbeam.a` and the two tables, linked from the list as an image is: with `crypto`'s table added the link fails on a duplicate symbol, and with the system table taken out on an undefined one; a list that takes `crypto`'s archives fails the test |
| the import's configure check, `make check-openssl` | `Configure` with erXos's options succeeds on the imported tree and the build makes `libcrypto.a` | `ssl/build.info` left out of the import: `Configure` fails |
| the seam's `getrandom` row, a host unit test of the seam | 1, 256, 257 and 4,096 bytes come back whole, from 1, 1, 2 and 16 reads of a stub generator; a stub failure on the second piece returns `-EIO` | the row returns the bytes read so far on a failure: the test fails on the short count |
| first seeding on QEMU | `crypto:strong_rand_bytes(32)` returns 32 bytes in a fresh domain of the interpreter image and in one of the BeamAsm image; in a domain of each started with the backend's generator made to fail by the test image's hook, so that its first seed fails, the first call raises, and in the SSH domain so made a key exchange fails | the seam falls back to zeros on failure: the call returns and the test fails |
| OpenSSL's start on QEMU | a domain that loads `crypto` starts on a CPU model with the cryptographic extension and on one without (`-cpu cortex-a72` under TCG), and AES-256-GCM vectors pass on both | `armcap.c` built without its edit: the probe's `SIGILL` ends the domain at load and the test fails |
| known-answer vectors | AES-GCM, ChaCha20-Poly1305, X25519, Ed25519 and ML-KEM-768 vectors from their specifications through `crypto` on QEMU | one vector's expected tag changed: the test fails |

The first-seeding test makes the generator fail before the domain's
first call, since an already seeded generator need not read the kernel
again before its reseed. OpenSSL's own test suite is not run on erXos:
OTP's suites exercise exactly what `crypto` calls, against an oracle,
which OpenSSL's tests do not.

## Dependencies

* OpenSSL 3.5.9, Apache-2.0, permanent, imported into `openssl/`
  ([design.md](design.md#dependencies)).
* OTP 29.1.2's `crypto`, `asn1`, `public_key`, `ssh` and `ssl`, Apache-2.0,
  part of the imported OTP.
* Perl on the build host, for OpenSSL's `Configure` and assembler
  generators, as OTP's build already needs.

## Alternatives considered

* **OpenSSL in both of two images, never loaded by the system release.**
  Rejected: OpenSSL's constructors run in every process that maps it
  (`armcap.c:65-67`), so the library would run in the system domain, and
  keeping it from being called would be a rule about what the system
  release loads rather than a fact of its image.
* **A fourth image, BeamAsm without OpenSSL, for the network domain.** Not
  adopted: one more link of ERTS and one more image file, whose text no
  other domain shares with the network domain, to keep from the network
  domain a library that nothing there calls
  ([Domains that call no OpenSSL](#domains-that-call-no-openssl)).
* **The network domain on the system image.** Rejected: the interpreter
  is up to four times slower than BeamAsm
  ([design-runtime.md](design-runtime.md#one-mechanism-per-job)) on the
  domain that handles every packet.
* **`crypto` in the BeamAsm image only.** Rejected: deterministic mode
  and command domains run the interpreter image, so the web domain's TLS
  and every SSH session would fail in deterministic mode, and a command
  could not use `crypto`.
* **A loadable NIF library.** Rejected: ERTS on erXos links NIFs
  statically, and mapping a library into a runtime would be a second
  loader beside `liberx`'s.
* **Fetching OpenSSL unchanged and setting `OPENSSL_armcap` in every
  domain's environment.** Rejected: an environment variable every domain
  must carry is a rule each specification must remember, and the seed
  path would still end in `ENOSYS`; the edits make the feature words
  and the seam's row the only inputs.
* **Keeping the weak `getentropy` and forcing musl's `getentropy.o` into
  the link** with `-u getentropy`. Rejected: a link flag every image must
  remember for a library call, and musl's 256-byte bound would then sit
  on OpenSSL's path.
* **The library's sources alone, with OpenSSL's build files edited to
  match.** Rejected: edits to the top-level `build.info` and `Configure`
  are inherited build machinery changed for a smaller tree, to save
  directories the build reads but never compiles.
* **BoringSSL, LibreSSL or a smaller library.** Rejected by the existing
  decision: OTP's `crypto` is written against OpenSSL, and 3.5 is
  supported until 2030 ([research](research-boards-storage.md#cryptography-libraries)).

## Risks and open questions

* **Three images.** The system domain's image is a file of its own, one
  more link of the interpreter build and one more file in the boot image;
  it is what makes K1 a fact of the image
  ([design-runtime.md](design-runtime.md#beamasm)).
* **`no-legacy`.** It removes algorithms some stock OTP users call
  through `crypto`, so programs that use them fail on erXos and on the
  oracle alike; SSH, TLS and the vault use none of them.
* **OpenSSL mapped where nothing calls it.** The network domain, and any
  domain whose release has no `crypto`, maps OpenSSL and runs its
  constructor, which reads the feature words and nothing else; the
  network stack's build check keeps its packets from the library
  ([Domains that call no OpenSSL](#domains-that-call-no-openssl)).
* **The cost of `crypto` in the interpreter image**, its size and AES's
  speed without the cryptographic extension on the Pi 4, is on the watch
  list ([todo-performance.md](todo-performance.md)),
  settled by `tools/erx bench` numbers for SSH's bulk transfer.

## Sources

* OTP 29.1.2 source archive, `otp-c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049.tar.gz`,
  SHA-256 `c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049`
  (the pin in `otp/ORIGIN.md`): `erts/emulator/Makefile.in`,
  `make/configure.ac`, `lib/crypto/c_src/openssl_config.h`,
  `lib/crypto/c_src/rand.c`; `crypto` 5.10 (`lib/crypto/vsn.mk`).
* OpenSSL 3.5.9, `https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz`,
  SHA-256 `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a`,
  matching the release's published `.sha256`: `INSTALL.md`,
  `providers/implementations/rands/seeding/rand_unix.c`,
  `crypto/armcap.c`, `Configurations/10-main.conf`, `Configure`,
  `build.info`.
* LLVM 21.1.8, `https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-21.1.8/lld/ELF/Symbols.cpp`,
  SHA-256 `0fa29d79990534b8c3a174356f2492b4c5610e0e88b59f66770c4042c8d2509b`.
* musl 1.2.6 in the tree: `src/misc/getentropy.c`,
  `src/linux/getrandom.c`; erXos's seam
  `musl/src/internal/erxos/syscall.c`; `tools/lib/erx/musl.rb`.
