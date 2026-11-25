# Developing erXos

A tour of a developer's loop: set up the host, build, boot in QEMU, change
Erlang code and load it, debug, trace, test and land. Each step is a few
lines with a link to where the detail is; nothing here replaces those pages.

The project's working agreement, which every change follows, is
[CLAUDE.md](../../CLAUDE.md). The architecture is
[design.md](../design.md) and the roadmap [plan.md](../plan.md). Where the
text below says something is designed, the design document says how, and
the page for that step says what is built.

## Where things are

* `erlang/apps/` holds the system services and tools written in Erlang
  (`erx` is the base application: the shell's `erx:i()`, the inspector,
  the log service and the tracer).
* `otp/`, `musl/` and `fiasco/` are the modified OTP, C library and
  kernel, each with an `ORIGIN.md`; `kernel/` and `liberx/` are erXos's own
  C.
* `abi/` holds the files every interface is generated from, including
  `abi/inspection.txt`, the inspector's schema. Generated files are not
  checked in: every `tools/erx` command regenerates them into `build/gen/`.
* `tools/erx` is the one command for building, booting, loading, testing
  and measuring, over the Ruby in `tools/lib/erx/`. Run it with no
  arguments to print its usage line.
* `test/` holds the host tests (`test/host/`), the integration tests
  (`test/integration/`), the Erlang unit tests (`test/erlang/`) and the
  guest programs the QEMU suites boot (`test/guest/`).

## 1. Set up the host

Install the tools, point the build at LLVM's compiler, and prepare the
checkout. A new git worktree needs the same preparation as a clone.

* [Host setup](../../README.md#host-setup): the tools, and the `ERX_CLANG`
  and `ERX_LLD` variables every command needs.
* [Fresh worktree](../../README.md#fresh-worktree): one command,
  `ERX_SOURCE_CACHE=/path/to/main/build/downloads make setup`, readies a new
  worktree. It fetches nothing itself: it builds from sources `make fetch`
  verified, or from another checkout's `build/downloads`, clones LVGL from the
  main checkout's copy, and builds the oracles, the runtime and Fiasco.
* [Fetch, bootstrap and check](../../README.md#fetch-bootstrap-and-check):
  `make fetch`, `make oracle-bootstrap` and `make check`.

## 2. Build

`tools/erx boot` builds the development image it boots, so most days there
is no separate build step. The explicit builds are `make build` (the
kernel, Fiasco), `tools/erx build runtime` (the hosted runtime, macOS
only), `make pack PLATFORM=qemu-virt` (the QEMU medium) and `make pack
PLATFORM=raspi4b` (the Pi 4's card). The first build of ERTS takes a
while. See [Boot erXos](../../README.md#boot-erxos) and the book's
[appendix C](../book/c-building.md).

## 3. Boot in QEMU

```sh
tools/erx boot
tools/erx boot --hostlink
```

The first boots the development image with the serial console on your
terminal and the Erlang shell's `1>` prompt; quit with Ctrl-A then X. The
second also opens the host link, a UNIX socket that `tools/erx load`,
`files` and `web` use. On a board, see [Raspberry Pi 4](raspberry-pi-4.md).

## 4. Change Erlang code and load it

With the host link up, `tools/erx load --socket SOCKET --system FILE.erl`
compiles a module and replaces it in the running system domain, and
`tools/erx watch` does it each time the file changes. A load lasts until
the machine ends; a change that must stay ships in a new image. See
[Loading code into a running machine](loading-code.md).

## 5. Debug

Start from the boot transcript and `dmesg`, then the inspector (`erx:i()`,
`/proc`), which says who reported each value and shows what a value could
not be measured as. A crash in ERTS itself is quicker to chase in hosted
mode under `lldb`. See [Debugging](debugging.md), which also lists what is
not built: a native debugger, a GDB stub and core files.

## 6. Trace

`erx:trace/1` prints one time-ordered stream of a process's scheduling and,
on request, the kernel layer's events. OTP's own tracing is stock OTP's.
`tools/erx bench` measures. See [Tracing](tracing.md).

## 7. Test

`make check` is the everyday gate and `tools/erx check-qemu --suite NAME`
boots one QEMU suite. The slower gates run at milestones. See
[Testing](testing.md), and the README's
[Correctness and testing](../../README.md#correctness-and-testing) for what
each check covers and where its limits are.

## 8. Land

The rules are CLAUDE.md's "Committing" section: a code review before every
commit, with its critical and high findings fixed; a regression test
written first for a non-trivial bug fix; history kept linear, so a branch
takes master's changes with `git rebase master` and lands with `git merge
--ff-only`, never a merge commit. A change to documents also runs `make
check-arch-terms`, which scans them for terms that belong to one
architecture.
