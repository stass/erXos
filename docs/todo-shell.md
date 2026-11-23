# TODO: Shell and programs

Open work on the command shell (rc), programs, the console line and the terminal. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Major initiatives

* [High] programs, an executable file as a program's image
  ([design-programs.md](design-programs.md#what-a-program-can-start), "File objects"; plan 1b-D,
  "`erx_exec` with `rx` grants"): not built past the resolve. `erx_program:start/1` takes only a program of
  the session's release (`image => <<"bin/NAME">>`). The handler resolves an absolute image through the
  starter's namespace and makes the image check of the entry's `rx` (`erx_prog_handler_core:resolve_image/3`),
  but has no filler to open the file and no code object from the command server (the rest of step 4 of
  "Starting a program"), and the loader `erx_exec`
  is only its load (`liberx/exec/load.c`, `erx_exec_load`: the object viewed and planned, the span
  reserved, segments mapped, copied and committed by a layout decided whole, relocations written), with no
  bootstrap around it (design-programs.md, "The loader's bootstrap" and "The executable's link";
  design-fiasco.md, "An exec's entry"): the loader's window (`abi/protocols/prog.txt`, the task script's link
  at its base and the load's reserve of its rest), the exec record's layout, register 7 and the executable's
  `erx_exec_release` (`liberx/exec/release.c`, from `erx_prog_enter`) are built, and not built are the
  record's writers (the port driver's create, write and map of it, which must map it at the ABI's
  `exec_record_page`, and the command server's keeping of
  the file's length), the loader's own C entry ahead of the helpers, the exec entry, the loader's failure path that copies its reason into a static and calls its
  start-up with the arguments it received,
  the port driver's release of its own view of the record and its close of the record's capability once
  the first thread has started, the SDK's `liberx_program.a` (`liberx`'s program layer, its backend and
  the members of `erx_boot.a`, `libsigma0.a` and `libl4sys.p.a`), the `{ok, Cap, Bytes}` reply to `{map, Path, code}` and the exec switch's
  record, the SDK's link of the task script at base 0 and its dynamic sections, and the removal of `image` from the
  startup message (`abi/protocols/prog.txt`, the `image` union). The static link needs `-fPIE`
  objects: musl's `libc.a` is built without it (`musl.rb`'s `CFLAGS`), so `vmlock.o` and `ofl.o` fail
  the link, and `liberx`'s program objects without it fail with 344 absolute relocations in read-only
  tables, mostly the generated `prog_profile.c`; `task.ld` names none of `.rela.dyn`, `.hash`,
  `.gnu.hash`, `.dynsym`, `.dynstr` and `.dynamic`, which `--orphan-handling=error` then refuses. A
  probe link with those fixed gave the design's shape (622 relocations, all relative); unverified are
  `erx_elf_plan` over that link, a booted run, and whether one release removes the loader's whole window
  on Fiasco. The load trusts its object to be a sealed code
  object: it checks neither, the Fiasco backend maps a pool object read-execute, and the relocations are read
  again from the view, so a writer of an unsealed object could move them [Medium, security residual]; the
  exec record names only an object the command server sealed. `load.c` runs only in its host test, over memory calls
  of the test's own (`test/fixtures/exec_load_effects.c`), which checks its outcomes and releases but not the bytes it maps, and whose stand-in space checks neither page alignment nor that a map lies in a reservation, nor makes an object shorter than the rounded length [Low]; nothing yet states who guarantees the code object's zeros past the file's last byte, which a read-only or executable segment ending in the last page maps into the program [Medium, security residual]: the programs suite gets the bootstrap's cases (design-programs.md, "The loader's bootstrap") when the
  program lands.
  So a native app's start of `/app/bin/NAME` is refused
  `{program, enotsup}` and the session ends; no installable native package (the Doom demo) runs until this
lands. The session asks for code objects through the `code_objects` facet
(`abi/services/code_objects.txt`, design-system.md, "The `code_objects` facet"), which the domain service
grants every session by its own policy and forwards to `erx_domain_lib:code_object/2` and `code_drop/2`.
The domain library makes them (`erx_dom_lib_code_object`, `liberx/system/dom_apply.c`): a paged
`ERX_MEM_CODE` object from the session's own budget, a copy in the session's table without `WRITE` or
`DESTROY`, at most `code_objects_max` in the root's per-domain table, a drop that destroys one, and a
close of the rest at the teardown that closes the session's budget, all checked by the native_domain
suite's `code` case. Not built: the command server's holds (fill, start, row), which decide every drop,
and its table that reuses one object for every start of the same file (design-programs.md, "Holds and
drops"); the cap of one eighth of the session's budget on its code objects together; and an accounting
of their pages beyond the fixed bound of `code_objects_max` objects, so a session can tie up its budget
in code objects up to its own memory, never another's. Nor is it measured that an ERTS session's own
handles and its `code_objects_max` copies fit its handle table (`BOOT_CAP_LIMIT`,
`liberx/system/dom_boot_view.c`): a session short of entries is refused a copy with `elimit` early. Links: a package mount answers `enotsup`
  for a link inode, since a package holds no links (design-storage.md, "Reading EROFS images"), but today
  the reader checks only the header's text (`relative_path`) and only the host packer refuses links, so the
  mount's refusal is part of this item. Meanwhile the resolve refuses every symbolic link on the way
  (`eacces`), on every mount, where design-programs.md has a resolve follow links as FreeBSD's does.
  The image check reads the entry's rights alone, which design-files.md (F6) names as the wrong check until
  every entry's rights are capped by its grant's ("files, the app mount's rights", below). The resolve runs
  in the program's own handler, after the command server gave the program its id and job row, and waits on
  the walks of a grant server, where step 4 puts it in the starter's handler before step 5. The filler, when
  built, must check that the file is regular (a grant's walk answers `other` for devices too) and open it
  without following a link, since its open walks the path again.

## Stopgap replacements

* [Low] `tools/lib/erx/keymap.rb`, [Input events](design-display.md#input-events): the generator accepts
  U+0000, which means no rune, as a modifier's or a lock's rune; `erx_input` drops such a
  rune from `Mods`, but the generator should refuse it.
* [Medium] `tools/lib/erx/keymap.rb`, [Input events](design-display.md#input-events): the generator
  writes `erx_keymap` alone, not the list of layout names the manifest check holds a display entry's
  `display_keymap` to, so until the manifest's display entry carries a layout nothing refuses one the tree
  lacks. Add it with the display entry's layout.
* [Low] Property 17 plans one root session for the console, but a development build's console also logs root in
  at the host link's `console` line when the host opens it, and a console's relogin after a session ends may
  overlap the old session's end; neither is counted, so a manifest that exactly fills the system principal's
  quota or memory can have that login refused at run time, and the line falls back to the system shell
  ([design-live.md](design-live.md#the-console)). Counting each secure line's root session (and the
  relogin overlap, as `tools/lib/erx/apps.rb` budgets two sessions per kept row) would close it.
* [Low] console, `kernel/core/crash_frame.c`: a crash frame after a task's output with no final newline starts mid-line, so
  `tools/lib/erx/crash_frame.rb` reads it as absent; the root's `end NAME fault` line still reports the fault. Write a newline ahead of the
  frame on the console path.

## Bugs by subsystem

* [Low] programs, a narrowing to `/dev` (`erlang/apps/erx/src/erx_prog_handler_core.erl`,
  `narrowed_at/4`): where no entry of the starter's table stands at `/dev`, `within [/dev]` makes
  an entry at `/dev` on the provider above it, such as the release slice's root, so the program
  reaches that provider's own `dev` names, which an unnarrowed program does not, and its first
  open of `/dev/draw` goes to that entry rather than opening a window. Nothing widens beyond what
  the starter reaches. Decide in design-files.md ("Narrowing for a program") whether a narrowing
  to a place the export serves, held only by an entry above it, makes an entry there at all.
* [Medium] programs, the programs suite's `lvgl` case (`tools/lib/erx/programs.rb`) checks only that `erx-lvgl`
  (`display/lvgl/erx_lvgl.c`) reaches main's map of descriptor 3 and ends with status 1: the suite can hand a
  program only a pipe write end (`hand_off`), not the read end its standard input needs, and the session holds no
  window buffer lease for `{mem, Lease, Pages}` without the display server
  ([design-display.md](design-display.md), "A buffer in a program"). The case moves to the display
  suite with `erx_ui_lvgl`'s `open` on erXos (the `erx_ui_lvgl` item above), where the display server hands out
  the window buffer's lease and the read-end pipe, and sees `erx-lvgl` wait in `poll` for the screen record.
* [Medium] programs, `PROT_EXEC` in a program's `mmap` or `mprotect` (`musl/src/internal/erxos/syscall.c`, `mmap_call`
  and `mprotect_call`; `liberx/backend/fiasco/program_task.c`, `erx_fiasco_libc_fd`): design-programs.md, "The
  POSIX-lite personality", says it fails with `ENOTSUP`, since only the loader maps code, but the descriptor seam takes
  only descriptor mmaps, `munmap` and the range check of `MAP_FIXED`, so an anonymous mapping or a protection change of
  anonymous memory reaches musl's own rows, which refuse only write and execute together (a protection change that
  meets a mapping, the window buffer's included, is refused by `liberx/backend/core/vm_table.c` already). Have the
  program's seam refuse `PROT_EXEC` in both with `ENOTSUP`, with a check in the programs suite's `args` program.
* [Low] programs, the bit layout of `erx_prog_sigset_t` (`liberx/program/startup.h`) is written out by hand at
  each use: `liberx/program/spawn_plan.c`, `signal.c`, `spawn.c`, `startup.c`, and the spawn planner's fuzz harness
  and driver (`tools/fuzz/spawn_plan_fuzz.c`, `test/fixtures/spawn_plan_driver.c`). Give the type member and add
  helpers beside it and use them everywhere, so a change to the layout is one edit.
* [Low] programs, the programs suite's `lvgl` case (`tools/lib/erx/programs.rb`) checks only that `erx-lvgl`
  (`display/lvgl/erx_lvgl.c`) reaches main's map of descriptor 3 and ends with status 1. The display suite's
  lvgl-lease cell runs `erx-lvgl` over its pipes and a lent buffer through `erx_ui_lvgl` (the `erx_ui_lvgl` item
  above), which covers that and more, so the programs suite's case can go.
* [Medium] programs, `rt_sigprocmask` keeps no mask (`musl/src/internal/erxos/syscall.c`, `sigprocmask_call`),
  and the startup message's `sigmask` is dropped (`liberx/program/program.c`): the seam accepts any mask and reads
  every mask back as empty, so a program that blocks `SIGPIPE` under `SIG_DFL` and
  writes to a pipe with no read end is ended by the signal (`liberx/program/signal.c`, `erx_prog_sig_raise`)
  where POSIX keeps the signal pending and the write fails with `EPIPE`, and a program reading its mask back sees
  none. It fails safe, by a stop; `SIG_IGN`, the usual way to get `EPIPE`, works. Keep each thread's mask in the
  program layer and hold a blocked `SIGPIPE` pending, as [Signals in liberx](design-programs.md#signals-in-liberx)
  describes.
* [Medium] programs, a program's identifiers ([The startup message](design-programs.md#the-startup-message)):
  the musl seam (`musl/src/internal/erxos/syscall.c`, `SYS_getpid` to `SYS_getegid`) answers every program the
  root's fixed 1, 0 and 0. Add `uid` to the startup message in `abi/protocols/prog.txt`, have the handler fill it from
  the session's `principal` environment variable, keep it in `erx_prog_self_t` (`liberx/program/program.h`), and in a
  program answer `getpid` and `getppid` from the record's `pid` and `ppid` and `getuid`, `geteuid`, `getgid` and
  `getegid` from its `uid`.
* [Low] programs, `writev` through the seam (`liberx/backend/fiasco/program_task.c`, `vector_call`) writes each entry
  separately, so entries that sum to at most `PIPE_BUF` are not one atomic write against another writer of the same
  pipe; gather them into one pipe write. `ioctl` ignores its request on a pipe (`liberx/program/fd.c`), so
  `FIONBIO` on a pipe answers `ENOTTY`.
* [Low] programs, the program's seam keeps two lists by hand (`liberx/backend/fiasco/program_task.c`,
  `erx_fiasco_libc_fd`): the calls it hands back to musl's rows (`musl/src/internal/erxos/syscall.c`), which must name
  every row that names no descriptor, and the calls that name a descriptor, which answer `EBADF` for one the table does
  not hold. Both fail safe, with `ENOSYS`: a new musl row is unreachable from a program until the hand-back list names
  it, and an unlisted descriptor call answers `ENOSYS`, not `EBADF`. Generate both from one table of musl's calls with
  the argument that names a descriptor, or have musl's descriptor-free rows be one function the seam hands back to.
* [Low] programs, descriptor calls the table does not offer yet (`liberx/backend/fiasco/program_task.c`,
  `erx_fiasco_libc_fd`; `liberx/program/fd.c`): `preadv`, `pwritev` and their `2` forms answer `ENOSYS` on a
  descriptor the table holds, where FreeBSD's `kern_preadv` answers as `pread` and `pwrite` do; `FIONREAD` on a pipe end is `ENOTTY`, where FreeBSD's `pipe_ioctl` gives the bytes
  readable; `F_GETOWN` and `F_SETOWN` are `EINVAL`. Answer each from the object's kind in the table.
* [Medium] programs, the spawn's send (`liberx/program/spawn.c`, `send_spawn`; docs/design-programs.md, "Starting
  a program", step 2) must settle, before it is written, what the plan alone cannot: each `addopen` made in action
  order against the working directory of its turn, which a single walk of the actions must give both the planner
  and the send, never two; each `addchdir` target checked in that order, as FreeBSD's `chdir` fails a spawn with
  `ENOENT` or `ENOTDIR`; and argv or env strings that are not UTF-8, or an env entry without `=`, which FreeBSD's
  `execve` takes but the startup message's grammar (`abi/protocols/prog.txt`, `arg` and `env_var`) refuses, so the
  planner accepts a spawn the handler or the child then refuses. Either the protocol carries them as bytes or the
  planner refuses them with a stated errno.
* [Low] programs, `posix_spawn_file_actions_addfchdir_np` on a descriptor an earlier `addopen` of the same spawn
  made fails with `ENOTSUP` (`liberx/program/spawn_plan.c`, `fchdir_error`): the plan cannot tell before the open
  is made whether it is a directory. It fails safe. Let the plan's working directory be such an open, checked by
  the handler at the spawn, once directory descriptors exist.
* [Low] shell, Ctrl-C of a foreground job (`erlang/apps/erx_shell/src/erx_shell.erl`): `docs/design-shell.md`,
  "Interaction", says a job brought forward with `fg` and ended by Ctrl-C interrupts the line as well; that path is not
  built or tested. The plain Ctrl-C of a running line already ends both the job and the line.
* [Medium] shell, `cp` (`erlang/apps/erx_shell/src/erx_cmd_cp.erl`, `copy_bytes/2`): a failed close of the
  target is not reported. `cp` copies with `file:copy/2` between two names, which stock OTP runs in
  `file_server`, whose copy closes the target and drops the close's answer
  (`otp/lib/kernel/src/file_server.erl:177-193`), so `cp` succeeds where the target's server refused the
  close. A copy into `/apps` reports a refused package only through that close
  ([design-packaging.md](design-packaging.md#other-subsystems)). Fix: `cp` opens the target itself and
  copies in the 64 KiB pieces design-shell.md's info report describes, checking `file:close/1`'s answer; a
  test with a tree whose close answers `eio`.
* [Medium] shell, `host` (`erlang/apps/erx_shell/src/erx_cmd_host.erl`, `run/2`): a name or server
  argument with an empty label or a label over 63 bytes (`host a..b`, `host .foo`, `host www .foo`)
  crashes the command with `function_clause` from `inet_dns:encode_labels`, which stock OTP 29.1.2
  raises too, where FreeBSD's host(1) writes `host: 'a..b' is not a legal name (empty label)`. Check
  each candidate and the server name (labels 1 to 63 bytes, 253 in all) before querying and write
  FreeBSD's line, with cases in `test/erlang/erx_cmd_host_tests.erl`. The same crash from
  `erx_gen_tcp:connect/4` through `inet:getaddrs_tm/3` is stock's and belongs with the upstream
  `inet_dns` report.
* [Medium] shell, `ping` (`erlang/apps/erx_shell/src/erx_cmd_ping.erl`): a ping without `-c` or `-t`
  runs until interrupted, and `Ctrl-C` ends it without its statistics, because an Erlang command gets
  no `SIGINT` to catch: FreeBSD's ping writes the statistics and exits on it. Deliver the interrupt to
  an Erlang command as a message it may handle, and have ping write its statistics then.
* [Medium] shell, `ping`'s loop (`erlang/apps/erx_shell/src/erx_cmd_ping.erl`, `loop/2`, `tick/2`, `due/2`):
  the schedule (next request, grace period, `-t` end) lives in an untyped map across three recursive
  functions that each read the clock, and only `-c 3` on QEMU and the reply-stream case test it. Make it a
  pure `next(Schedule, Now, Tally) -> {send, Seq} | {wait, Ms} | done` over a record, tested on the host for
  the count, the grace period, `-t` and exit status 2.
* [Low] shell, `ping`: a reply whose slot of the 1024 a later sequence number took is ignored, so with
  `-i 0.001` and round trips over a second ping reports loss FreeBSD would not; and the grace period
  after the last request is `max(1 s, 2 * tmax)` in milliseconds, where FreeBSD truncates it to whole
  seconds. Pin both against ping.c.
* [Low] shell, usage errors: an Erlang command's `{error, usage}` gives the status `usage`, while ping's
  out-of-range values give 64, FreeBSD's `EX_USAGE`, which FreeBSD's `usage()` gives too
  (`erlang/apps/erx_shell/src/erx_shell_runner.erl`). Give `{error, usage}` status 64.
* [Medium] shell, the facets a command holds (`erlang/apps/erx_shell/src/erx_shell_runner.erl`): the network
  commands (`erx_cmd_ifconfig`, `erx_cmd_ping`, `erx_cmd_host`) declare `-erx_needs([net])` and reach the
  stack through erx_net_client, but every command is handed every facet of its session. Have
  `erx_shell_runner:command/4` hand each command only the facets it declares (`maps:with(Needs, Facets)`; `top` reads `inspect` without
  declaring it, so it needs a way to name a facet it uses when present), so a command that forgets its
  declaration holds no facet by construction, and shrink the command-needs build check
  (`tools/lib/erx/command_needs.rb`) to "no erx_shell module names a stack module": its list of OTP's
  network modules and functions is an enumeration that a new OTP call outside it gets past.
* [Medium] shell, the session_domain QEMU cell of session P6 (`tools/lib/erx/qemu_suites/session_domain.rb`, which
  session P5 brings with the session domain): `ifconfig` typed in a session prints `ifconfig: no_facet`
  and sets the status `no_facet`, and in the system shell lists the interfaces; `ps` lists the session's
  own processes there. The EUnit cases of `test/erlang/erx_shell_runner_tests.erl` run the same commands
  with a session's facets on the host.
* [Medium] shell, `erx_shell` (`above_terminal/1`) and `erx_shell_jobs` (`above/2`): the flag that
  gives the console the terminal while `erl` runs is a boolean the caller sets back in a `try ... after`,
  so a stage running `erl` that is killed leaves the line's terminal with the console until the line
  ends, and two `erl` in one line share the flag. Monitor each caller of `{above, true}` and keep the
  live callers in the line, so the console holds while the set is not empty.
* [Medium] shell, a job's leader (`erx_shell.erl`, `leader/1`) passes input requests to the shell's
  group, and the group answers an interrupt to whichever input request is current, so a job reading
  through `io:get_line` at the prompt would take a `Ctrl-C` the shell never counts, after which every
  `foreground` lags the relay's count and later jobs' reads stay parked. No command reads that way
  yet; have the leader refuse input requests, so the group has one reader by construction.
* [Low] shell, `erx_shell_jobs`: a key the relay reports for the line just before `erl`'s
  `{above, true}` stops or ends the line while the Erlang shell, led by its own group, runs on.
  Every exported step of the table settles on its own; one dispatching entry that always settles
  would make the rule hold for steps added later. `fg` resumes the job before the relay gives it
  the terminal.
* [Medium] programs, a program's `/dev/tty` (`erlang/apps/erx/src/erx_prog_handler.erl`,
  `erlang/apps/erx_session/src/erx_session_export.erl`): the export serves `tty` as a name alone and answers
  every open of it `enxio` (design-files.md, "Native clients: `liberx`'s file client"), but no program's
  handler yet makes the terminal's description that design-programs.md ("The terminal", "`/dev/tty`") has it
  make instead: an open of its tty's relay through `erx_session_relay:open_writer/2` under the program's
  job, through which its reads, writes, watches and controls go to the relay, never through the file
  protocol. Until it does, a program's open of `/dev/tty` (musl's `getpass`, a `ctermid` user) fails with
  `ENXIO`, and its standard streams reach the terminal only through its starter's pumps (the item under
  shell, `erx_shell_program`, below).
* [Low] programs, `fstat` of a file (`liberx/program/file.c` `erx_prog_file_getattr`; abi/protocols/prog.txt
  `stat`): `st_ino`, `st_dev` and `st_rdev` are not carried and read 0. `ino` and `rdev` need an unsigned
  64-bit kind the frame profile does not have (`integer ... u64` is refused in a frame protocol, which keeps
  a capability's spelling unique); `dev` is a `phash2` stand-in (`erx_file_remote`'s `major_device`), of no use
  without `ino`, since a program pairs the two to tell files apart. `st_blksize` and `st_blocks` read 0 too,
  though 9P's `getattr` gives both; `st_blocks` 0 beside a non-zero size reads as a sparse file to `du` and
  libarchive. The description (`erx_file_description`, `file:read_file_info/2`) gives no nanoseconds, since
  `#file_info{}` has no field for them and `erx_file_remote:file_info/2` drops the server's `*_nsec`, so the
  reply's `atime_nsec`, `mtime_nsec` and `ctime_nsec` keys have no producer and every `tv_nsec` reads 0.
  A time before 1970 is `EOVERFLOW` if a 9P server sends it as its two's complement in the `u64` field
  (abi/protocols/9p.txt `atime_sec`), since `erx_file_remote` passes it on unsigned (unverified which
  servers do).
* [Low] programs, FreeBSD's seek rule (a sum past `OFF_MAX` is `EOVERFLOW`, a negative one `EINVAL`, as
  `vn_seek` in sys/kern/vfs_vnops.c answers) has one Erlang home, `erx_file_remote:seek_to/2`, which both
  backends' `file:position/2` and so a program's file description follow, but it is spelled again in C:
  the release file system's `efile_seek` (`otp/erts/emulator/nifs/erxos/erx_prim_file.c`), which no host test
  reaches, and on the program's side `erx_prog_seek_plan` (`liberx/program/fd_plan.c`) for `/dev/null`'s offset, and the file
  client's stand-in (`test/fixtures/prog_file_driver.c`, `serve_seek`). Decide whether null's offset moves
  to a description too. No host test runs the real description's `pread`, `pwrite` or seek; the handler's
  suites stand it in. The two backends also each keep `moved/2`'s whence handling and its `badarg` guard for an
  offset outside off_t; one function taking the eof size and the offset cell would hold the whole decision,
  and `erx_file_remote`'s guard has no test through `file:position/2` (the EROFS copy has one) [Medium].
* [Low] programs, `liberx/program/file.c`: a `pwrite` whose end passes `OFF_MAX` is sent, and the server may
  write part of it before `erx_file_remote` answers `eio`, where FreeBSD's `ffs_write` refuses it whole with
  `EFBIG`; `lseek`'s `SEEK_DATA` and `SEEK_HOLE` answer `EINVAL` without a request, where FreeBSD's `vn_seek`
  asks the file system; and `pread` or `pwrite` on an open of the wrong access mode answers `EINVAL` for a
  negative offset and 0 for no bytes before the handler's `EBADF`, where FreeBSD's `fget_read` checks the mode
  first (`fd.c` `obj_pio`, which can read `obj_access`; `read` has the same gap).
* [Medium] programs suite, `tools/lib/erx/programs.rb` (`opener`): the case checks that a second process
  is refused `einval` by every `port_control` command before and after its `port_connect/2`, which is
  refused, and that the opener stays the owner and gets the exit status, but not docs/design-pipes.md's
  full test: an `install/2` of the handler's own hand-off number from the second process, the
  handler's install after it, and the seeded failure that drops `ERL_DRV_FLAG_ERX_NO_CONNECT`, under
  which the second process's commands are answered. Its
  command list `1..7` copies abi/erx_abi.txt's `program_control`.
* [Medium] shell, `$home` (`erlang/apps/erx_shell/src/erx_shell.erl:205`, docs/design-shell.md "The
  language"): design-shell lists `$home` among rc's variables, but no design says what it holds for a
  session and the interactive shell sets none (scripts get `/` or `/var/empty` from
  `erx_shell_script`). Find and act reads `$home/lib/act`, and its narrowing rule names the session's
  home, so the session's starting home needs one definition, read by the shell and by
  `erx_act_run` alike.
* [Medium] erx_program driver and core (`erx_program_drv.c` `channel_sides`, `install()`;
  `erx_program_core.c` `install_rights`): which channel side sits at which `program_arg` index, how
  the session maps it and what rights the program gets are three tables joined by index, and no
  host test checks that exactly one party may write each side; the `programs` suite's `bigargs`
  checks only what the program receives. Give the core one row per side (index, session
  protection, program rights) with a host check.
* [Low] erx_program driver: each program costs the session about 304 KiB of its own budget (two
  24 KiB lane sides, the data area at 64 KiB a slot, 256 KiB by default, two IRQ objects) with no session-side bound, since
  `PROGRAM_POOL` is unbounded; many starts can exhaust the session's own budget.
* [Medium] programs, `liberx/program/pipe.c` (`pipe_made`): a pipe reply's end that `erx_pipe_open` refuses
  partway (an ENOMEM mapping the lock page or reserving lanes) keeps the capabilities of the writers it
  had not reached in the program's table, a few slots for each failed `pipe2`; and the program owes the
  session, for an end it never opened, only `{closed}`, a hand-written copy of what
  `erx_program:descriptor_grants/1` counts (no `{drained}` for a gone writer, nothing for a
  `socketpair`). Generate `erx_prog_descriptor_caps` and the notices a refused descriptor owes from the
  protocol table, as `erx_prog_report_caps` is, and close and send them on every refusal.
* [Medium] programs, `liberx/program/pipe.c` and `channel.c`: a `pipe_lost` or `pipe_server_lost` report the
  executor reads between a pipe reply and its requester's install finds the new ends in no table and is
  dropped, so those ends never learn they are lost; design-programs.md has startup ends set up before
  any report that may name them. Have the executor open a pipe reply's ends and link them into the live
  list before it reads the next frame, leaving the requester only the install or the release.
* [Medium] programs, `test/fixtures/prog_fd_driver.c`: `pipe_made`'s failure paths (EMFILE releasing both
  ends with two `{closed}`, one end refused, swapped kinds) run in no test; have the driver's
  `erx_prog_channel_request` stand-in call the callback with crafted replies over a nearly full table,
  with a seeded fault that drops the release loop.
* [Low] erx_program driver, `erx_program_drv.c` (`program_control`): `CONTROL_SEND` and
  `CONTROL_STOP` act before `answer` allocates the answer's binary, so when that allocation fails
  the owner gets `badarg` for a frame the driver took or a stop it applied. Allocate the answer
  first and fill it once the status is known.
* [Low] erx_program driver and `erx_program.erl`: the port-control wire constants, the command
  numbers, `CONTROL_SEND`'s reply byte for no reply (255), its grant kinds (1 and 2) and its
  13-byte grant layout, are written twice, as Erlang macros and as the driver's `#define`s, and
  `test/host/erx_program_grants_test.rb` copies the 255 once more, against the rule that the ABI has
  one source. `abi/` has no home for a driver's port-control interface;
  give it one in the generator and generate both sides.
* [Medium] console, `liberx/backend/fiasco/console.c` (`erx_fiasco_console_write`): once the console
  driver holds the UART, a test task's standard output through `task_write` still reaches it beside
  the driver, so its bytes can fall between the driver's at any byte; every runtime's C output and
  the park report are debug log records (`output_line.c`), and the end path's lines are the
  published FD26 row. Have test output reach the console through `erx_console` by a raw form the
  ring does not have yet. A record `erx_console` writes still starts wherever the
  console's line stands, after a prompt with no newline included (`1> #0 ... debug space 0: erx_blk:`).
* [Medium] system console, `erx_console:system_source/1`: the system domain's log records take
  the line's principal, which the console learns from the domain service at its first session
  start, so records before the service has built the boot's configured domains say `principal
  unknown`, and a release login will make the line's principal a user's. Give the system domain's log records the system principal
  apart from the line's principal, once the domain service has named it.
* [Low] shell, `erlang/apps/erx_shell/src/erx_shell.erl:177`: the console's shell waits for the boot in `booted()`
  before `init/3` traps exits (`:192`), so a console `Ctrl-C` during that wait, which the shell's group passes on as
  the exit signal `interrupt` while it serves no request (`otp/lib/kernel/src/group.erl:519-522`), ends the shell
  before its banner. Trap exits before the wait.
* [Low] `erlang/apps/erx_shell/src/erx_render.erl`, `erlang/apps/erx_web_line/src/erx_web_value.erl`: neither shows a
  record's `entries`, so `erx:i([kernel, log])` prints an empty record and the web's log view
  ([design-web.md](design-web.md#views-on-the-line)) has nothing to read; `/proc/kernel/log` and `dmesg`
  are the only readers.
* [Medium] programs and shell, the files a stage hands a program: `docs/design-shell.md` (Overview, "Starting
  programs") has the shell hand a program it starts with `erx_prog_handler:start/1` the files its redirections opened,
  sharing their offsets, where `start/1` takes pipe ends and buffers only (`docs/design-programs.md`, "A session
  process's program"; `erlang/apps/erx/src/erx_prog_handler.erl:19-30, 86-93`). Design the form in design-programs
  and design-shell. It must keep `docs/design-files.md`'s rule that every description a program holds was opened
  through a program's table, so that nothing on a window tree enters a program ("A program's window"): for example
  a description the program's handler opens through the program's own table for the starter, or one whose tree,
  part of its identity, the handler refuses when it is `windows`.
* [Medium] shell and programs, finding a tty's relay ([design-shell.md](design-shell.md#the-terminal-relays-protocol)):
  a relay other than the domain's line's holds no name, and no design names how a program's handler, a
  command domain's stream relay or `erx_cmd` finds the relay of the tty its job runs on. Suggested home:
  the shell's `terminal()` map, which already carries the console's terminal functions, gains the relay's
  pid, and the shell passes it to each job it starts.
* [Medium] shell and programs, several ttys in one session: a display's session runs a shell on a tty per terminal ([design-display.md](design-display.md#the-terminal)), but [design-shell.md](design-shell.md#job-control) and [design-programs.md](design-programs.md#the-terminal) speak of "the session's tty" in the first tier. State that the terminal relay serves each of the session's ttys, that each runs its own command shell and job table, and that a program's `/dev/tty`, standard streams and `ps` `TT` are those of the tty its shell started it from.
* [Low] Program end, `docs/design-runtime.md` and `docs/design-programs.md`
  ("A program's end"): the runtime has the handler destroy the anchor, and
  the programs design has it destroy the program's budget. Both delete the
  tree; one should be the stated step.
* [Low] shell, parser choices to settle against plan9port's rc once its
  oracle runs: `|[a=b]` is read as descriptor a of the left command to b of
  the right one, which may be the reverse of rc's lex.c; an empty operand
  of `|`, `&&` or `||` is refused, where rc's grammar takes one; and
`` `split{cmd} `` is accepted; a here document's body starts after the
next newline, even inside braces, where plan9port may wait for the whole
command; `>>{`, `<>{` and `>[2]{` are refused; and a NUL byte is a word
byte, which the evaluator refuses in a program's arguments and a file
name but hands the runner in a variable's value and name (`$n = 1` with
`n=a=b` exports `a=b=1`), in a `whatis` name (whose `not found` then
writes the NUL to descriptor 2) and in a glob's text; the evaluator
should build the environment it exports itself, of valid names and
values without a NUL, and refuse a NUL in `whatis` and glob requests,
so no runner has to remember them; and a keyword joins no word that touches it,
where rc's hand-written parser joins one in an argument (`echo for=x`
prints `for=x` in rc, `for =x` here), and the same holds after a
subscript's `)` and the `}` of `` `{...} `` and `<{...}` (`echo
$x(1)=2`), while a list followed directly by a word or `(` is refused in rc
(`echo (a)=b`, `x=(a)b`, `x=(a b)(1)`: "No free carats around parens")
and accepted here; `not=1`
and `in=x` are assignments in rc and refused here; and `cat <<=` takes `=`
as its tag in rc. The joining rules would hold by construction if the
lexer marked each token with whether a blank came before it and the
parser joined as rc's yyword does, in place of inserted carets and `sub`.
Add each
to the corpus and follow rc
  (`erlang/apps/erx_shell/src/erx_shell_lex.erl`,
  `erlang/apps/erx_shell/src/erx_shell_parse.erl`).
* [Low] shell, `whatis` of a function: rc prints `fn name {body}` as its
  parser deparses the body; the evaluator has no printer of syntax trees
  and says it cannot show the body, status `not supported`. Write the
  printer, following rc's pcmd.c, and drop the corpus's pinned
  difference `whatis-function.rc` (`erlang/apps/erx_shell/src/erx_shell_eval.erl`).
* [Medium] shell, the evaluator's builtins to come: `.`, `wait`
  and `flag` (rc's), and `erl`, `within`, `jobs`, `fg`, `bg` and `kill`;
  each is an effect, so each goes behind the runner of `erx_shell_eval`
  with the command and job pieces of Track S (`cd` is the runner's,
  `erx_shell_runner`). Until then their names
  reach the runner as commands and give `not found`. `.` runs a file's units in the current
  shell, which `{run, Argv, Vars}` cannot express: it needs a request that
  reads the file for run_source/2; `flag`'s `-e`, `-x` and `-v` are
  evaluator state, which the evaluator does not hold
  (`erlang/apps/erx_shell/src/erx_shell_eval.erl`).
* [Medium] shell, here documents: rc substitutes a template's variables
  when it reads the line (here.c), so a function's here document is fixed
  at its definition and `x=new; cat <<EOF` sees the old `$x`; the
  evaluator substitutes when it runs the redirection. Decide which the
  design wants and record it in design-shell.md, give the fake runner a
  `cat` that reads standard input, and add corpus cases
  (`erlang/apps/erx_shell/src/erx_shell_eval.erl`).
* [Low] shell, the evaluator's smaller differences from rc, each to follow
  rc or record with a corpus case: `shift -1` empties `$*` in rc and
  shifts nothing here; `builtin builtin echo` runs a program `builtin` in
  rc; a copy's status is `1` in rc
  (`@{exit foo}`, a faulting pipeline stage gives `1|`) and the copy's own
  status here; and rc runs `fn sigexit` when the shell exits
  (`erlang/apps/erx_shell/src/erx_shell_eval.erl`).
* [Low] shell, one reader of a source's units: `run_source`, `eval` and
  the parser's fuzz target each step through units by hand, threading
  the rest, the lines read and whether an `if not` may follow; the
  interactive layer's loop (`erx_shell`) is a fourth. A cursor in erx_shell_parse that
  `next_bounded` takes and returns, with diagnostics already counted from
  the source's start, would hold that state in one place; split
  `outcome()` then into a unit's and a source's, since `run_unit` never
  gives `syntax_error` (`erlang/apps/erx_shell/src/erx_shell_parse.erl`).
* [Medium] shell, `erx_shell_program`: a program's standard streams are pipes whose other ends pump
  processes of its starter hold, writing to the shell's terminal, Erlang stage, file or nothing, and
  feeding it from a stage or a file. docs/design-shell.md ("Starting programs") passes a redirection's
  open file itself, sharing its offset, and opens `/dev/tty` for the terminal, which the terminal relay
  serves; that needs a form of `erx_prog_handler:start/1` for an open file (keeping the rule that nothing
  on a window tree enters a program) and the relay's tty readers. Until then a redirected program sees a
  pipe (no `lseek`, `isatty` false), its standard output and error reach the terminal through two pumps
  whose order between them is not kept, a program reading standard input from the terminal reads its
  end at once, and the shell's `kill` of a job reaches its programs as their starter's end, `sigkill`.
* [Medium] shell, a job's processes are found by group leader, not by
  job tag: until the runtime's job tags exist (docs/design-shell.md,
  "Jobs and their tags"), `erx_shell` runs each line and each `&` job,
  and `erx_shell_script:command/3` each `rc -c` on a tty, under a group
  leader of its own (`erx_shell_leader`) that forwards io to the shell's group;
  stopping a job pauses every process that leader leads with
  `erlang:suspend_process/1`, in passes, and `Ctrl-C`, `kill`, the heap
  limit or a crash kill them (`pause/2`, `terminate/2`, `end_line/3`).
  The group leader is a field any process can change, so a process that
  sets its own escapes its job's stop and end, one whose leader code in
  the job re-points to the job's is stopped and killed with it, and work
  done by servers outside the job is not the job's. A shell a job starts
  on the console with `erx_console:run_shell/2`, as `erl` does, runs on a
  group of the console's, so it and what it starts escape the job: a
  `&` block's `erl` outlives an exec that ends, until the console stops
  with the exec's report, when its group ends and kills its shell only
  if that shell is waiting for input (OTP's `group.erl`, the driver's
  `'EXIT'`). Each pass looks at
  every process of the runtime. `erx_prog_handler:start/1` likewise
  records a program in its caller's group leader's job at the command
  server, where the design reads the caller's tag with `erx_job:tag/0`.
  Replace both with the job tag (`erlang/apps/erx_shell/src/erx_shell_leader.erl`,
  `erlang/apps/erx/src/erx_prog_handler.erl`).
* [Medium] shell, a script's processes when its evaluator is killed:
  `erx_shell_script:run/2` runs a source in an evaluator process with a
  heap limit, and when the limit kills it the stages, commands and pipes
  it started run on. The interactive layer ends a line's processes
  through the line's own group leader (`erx_shell:end_line/3`); the
  script runner should do the same, sharing that code
  (`erlang/apps/erx_shell/src/erx_shell_script.erl`).
* [Medium] shell, what a done job leaves running is out of reach: a job
  is done, reported and gone from the table when its first process ends,
  and the processes it started that still run stay with its leader,
  unlisted, so `jobs` does not show them and `kill` and `Ctrl-C` cannot
  reach them until the session ends, where docs/design-shell.md keeps an
  inner `&` block in its job. Keeping the job listed as running until its
  leader leads nothing would make them its own; a foreground line would
  then wait for them too (`erlang/apps/erx_shell/src/erx_shell.erl`,
  `release/2`).
* [Low] shell, `&` inside a piece run apart ends with an interrupted
  line: a block that a pipeline's stage or a subshell of the foreground
  line puts in the background stays in the line's job, as in a UNIX
  subshell, so `Ctrl-C` ends it, where POSIX starts such a block with
  `SIGINT` ignored. Only `&` on the shell's own line starts a job that
  runs on (`erlang/apps/erx_shell/src/erx_shell_runner.erl`).
* [Low] shell, a stopped line finishes as a job and what it changed is
  dropped: a line that `Ctrl-Z` stopped and `fg` brought back ends as a
  job, so its assignments and `cd` do not reach the shell, where a UNIX
  shell has made them already. Taking a line's outcome when it ends in
  the foreground through `fg` would keep them
  (`erlang/apps/erx_shell/src/erx_shell.erl`).
* [Low] shell, the reading loop has no byte bound of its own: the parser
  caps a unit at 4 KiB, but the group's line and the shell's `Line`
  binary, in a process with no `max_heap_size`, hold whatever is typed or
  pasted, as stock's shell does; SH2 bounds a line at 64 KiB
  (`erlang/apps/erx_shell/src/erx_shell.erl`, `read/3`).
* [Low] shell, the command shell's lines go to the Erlang shell's history
  file when `kernel`'s `shell_history` is on, since its group uses the
  same `group_history`; start its group with `{line_history, false}` or
  give it a history of its own. `erx_shell:start/0` also hands the
  operator the shell process's raw exit reason, which a crash in the
  runner's `new/1` or the terminal's `write` would fill with their state
  (`erlang/apps/erx_shell/src/erx_shell.erl`, `erlang/apps/erx/src/erx_console.erl`).
* [Low] console, which requests of a hidden group are answered is a list
  in `from_hidden_group`: a group request it does not name leaves that
  group waiting for a reply, and a hidden group's `set_unicode_state`
  still changes the shared `prim_tty` state. Sending every group message
  through the one request path and discarding a hidden group's bytes at
  the output edge would make hiding one decision
  (`erlang/apps/erx/src/erx_console.erl`).
* [Low] console, a group's shell that exits with reason `kill` kills the
  console: OTP's `group` passes the shell's reason on with `exit(Drv, R)`,
  which cannot be trapped when `R` is `kill`, as with stock `user_drv`;
  have `group` send the reason as a message instead
  (`otp/lib/kernel/src/group.erl`).
* [Low] shell, a line outlives its shell: the line's process is
  monitored, not linked, so a shell killed outright leaves a running line
  spinning. The line's group leader already monitors the shell and ends
  with it; killing every process it leads at that moment, as `end_line/3`
  does, would end the line too (`erlang/apps/erx_shell/src/erx_shell.erl`,
  `run/3`, `forward/2`).
* [Low] shell, the 4 MiB heap limit counts the variables a line starts
  with: once they near it, every later line passes its limit, even
  `x=()`; bound what the shell keeps, or limit a line to its starting
  state plus 4 MiB (`erlang/apps/erx_shell/src/erx_shell.erl`).
* [Low] shell, whether a diagnostic that names a command is program
  output or text attributed to a source: the evaluator writes `Name: not
  found` and `whatis`'s `Name=value` raw, and so does the runner's `Name:
  not found`, while erx_render escapes what it shows; a substitution
  carries a program's output into those names. Decide in
  docs/design-shell.md and make them agree
  (`erlang/apps/erx_shell/src/erx_shell_eval.erl`,
  `erlang/apps/erx_shell/src/erx_shell_runner.erl`).
* [Medium] shell, `Ctrl-D` does not end the command shell at the console:
  edlin binds it to forward delete, and a group in edlin mode that is sent
  `eof` ends the edited line without a newline and waits for more, so
  `get_line` never answers `eof`. An edlin action that deletes forward or,
  on an empty line, ends the input, bound for the command shell's group
  alone, would give rc's `Ctrl-D`; `exit` ends it meanwhile
  (`otp/lib/stdlib/src/edlin.erl`, `otp/lib/kernel/src/group.erl`).
* [Low] shell, `$status` after `Ctrl-C` ends a running line: the shell
  keeps the state it had before the line, where the design sets `$status`
  to say the line was interrupted; it needs a way to set a variable through erx_shell_eval
  (`erlang/apps/erx_shell/src/erx_shell.erl`).
* [Medium] console, a first shell started again while a shell above it has
  the input writes its banner through `erx_console:write/1`, which is shown,
  over the shell above, while its prompt goes through its hidden group and
  is dropped, so when the shell above ends the line shows no prompt; a unit
  of the old shell left waiting in `erl` writes its diagnostic when that
  shell ends. Starting the fresh shell only once the input reaches the first
  group again fixes both. A first shell that fails at its start is started
  again at once, with no limit and no message, so a broken release spins
  where it should halt with the reason; the restart decision wants a rate
  (`erlang/apps/erx/src/erx_console.erl`,
  `test/integration/runtime_console_test.rb`
  `test_a_crash_of_the_first_shell_starts_a_fresh_one`, which kills the
  shell 300 ms after `q()` and so depends on timing).
* [Low] console, typeahead past a line that starts a shell (`erl`,
  `erx_shell:start().`) stays in the group that read the line, which runs it
  once the new shell ends, where on UNIX the program the line started reads
  it: input arriving in one read goes to the group that has the input then,
  and `group` keeps what one `get_line` did not take. Handing a group's unread
  input to the group that takes the console needs a request `group` does not
  have (`erlang/apps/erx/src/erx_console.erl`, `lib/kernel/src/group.erl`).
* [Low] shell, a runner's reply of the wrong shape: `with_redirs`, a
  substitution's capture and `whatis` match the reply directly, so a
  runner that breaks its contract crashes the evaluator with the whole
  shell, its variables included, in the error reason; answer such a
  reply with a language fault that names only the request
  (`erlang/apps/erx_shell/src/erx_shell_eval.erl`).
* [Low] shell, escaping the shell's own diagnostics: `whatis`'s `not
  found` and a runner's fault text name what may come from a shared file
  system and reach descriptor 2 raw, as in rc. Decide whether the runner
  applies the line escaper to the shell's `{write, 2, _}` text
  ([design-shell.md](design-shell.md)).
* [Low] shell, bodies handed to the runner: each turns the evaluator's
  throws into values by hand (`apart` through run_unit/2, `with_redirs`);
  build every body through one constructor that does it
  (`erlang/apps/erx_shell/src/erx_shell_eval.erl`).
* [Medium] shell, the command catalog is read at run time: `erx_shell_namespace:from_applications/1`
  loads the shell application's modules and reads their `-erx_command`, `-erx_usage` and
  `-erx_needs` attributes each time `erx_shell:run/2` starts, where the design has a generated,
  checked catalog bound to each module's blob hash and republished around code replacement
  ([design-generation.md](design-generation.md#configuration-and-command-catalogs)). A module
  with malformed metadata is left out with a problem that `run/2` drops unshown; the generator
  should refuse it at build time (`erlang/apps/erx_shell/src/erx_shell_namespace.erl`).
* [Low] shell, the terminal's table measures a value by its characters (`string:length/1`), so an
  East Asian wide character, which takes two columns, misaligns the rest of its row; measure display
  width from the terminal tables (`erlang/apps/erx_shell/src/erx_render.erl`).
* [Low] shell, the text commands' gaps against docs/design-live.md and docs/design-shell.md
  (`erlang/apps/erx_shell/src/erx_cmd_ps.erl`, `erx_cmd_grep.erl`, `erx_cmd_wc.erl`): `ps` prints `-`
  for `TT` because the session's tty has no name a command can read, leaves out the `+` of a
  foreground job's `STAT`, and lists no programs until programs run in sessions; `grep -r` is not
  offered; `wc`'s status is its first error's text where FreeBSD's is 1; and a usage error's
  status is `usage` where FreeBSD's `sort` and `grep` exit 2 and `top` 1
  (`erx_shell_runner:outcome/3`).
* [Low] shell, the runner's pieces not done yet: `<{...}` and `>{...}` are refused, since the
  namespace has no path that names a pipe; a background block's redirected files close when the
  redirection's request ends, so `{cmd &} > f` loses what `cmd` writes after that; a substitution's
  output is bounded by the evaluator's heap alone; the first Erlang commands lack `i`,
  `umount` and `mount` with arguments, which change the namespace through `erx_ns`
  (`erlang/apps/erx_shell/src/erx_shell_runner.erl`): `erx_cmd_mount.erl` only lists, and
  `mount [-r] SOURCE DIR`, `mount FILE DIR` and `umount DIR` with their refusals of a `/dev` source,
  `-t` and a path that is no entry are [design-shell.md](design-shell.md#interfaces)'s.
* [Medium] shell, the Erlang file utilities (`erlang/apps/erx_shell/src/erx_cmd_*.erl`): `echo`, `cat`, `ls`,
  `pwd`, `mkdir`, `rm`, `mv` and `cp` are erXos's own and replace toybox's applets of those names, but each takes
  only a few of FreeBSD's flags (`ls -l`, `mkdir -p`, `rm -rf`; no `ls -a`, `cp -R`, `mv -i` and the like). Grow each toward
  FreeBSD's utility, flag by flag, with FreeBSD's manual page as the reference and a test per flag.
* [Medium] shell, the stage heap limit (`erlang/apps/erx_shell/src/erx_shell_runner.erl`, `MAX_HEAP_WORDS`):
  the runner sets `8 bsl 20` words, 64 MiB on a 64-bit runtime, where design-shell.md's "One evaluator per
  stage" gives 4 MiB and an allowance of eight stages in 32 MiB; settle one figure in both.
* [Medium] shell, the runner's review findings left open (`erlang/apps/erx_shell/src/erx_shell_runner.erl`):
  a stream has no direction, so `` x=`{cat >[0=1]} `` reads the write end of its own pipe and hangs the
  session; give `{pipe, Pid}` a direction and answer `ebadf` to a read of a write end. Stage, command and
  evaluator processes are monitored, not linked, so a killed evaluator or stage leaves its children
  running and `{while(){}} &` runs until reboot; link each to its starter. A substitution's output has
  no bound but the evaluator's heap, so `` x=`{cat big} `` ends the whole source rather than one stage;
  cap it and record the bound in design-shell.md. The runner's and commands' diagnostics (`not found`,
  `cd`, `can't open`, `erx_cmd:report/3`, crash text) carry file names raw to the terminal; decide in
  design-shell.md whether they pass the line escape. Glob keeps a non-directory before `/` (`echo */`
  lists files) and resolves `f/..` by name. Stages and background blocks are admitted with no stage
  allowance at all (see pipeline admission below). A pump treats a read error as end of input, so `grep` of a
  directory finds nothing where FreeBSD's warns; `ls` and glob skip names that are not UTF-8
  (`list_dir_all`).
* [Medium] shell, `erx_cmd:path/2` (`erlang/apps/erx_shell/src/erx_cmd.erl`): it takes `..` away by name
  before the namespace resolves the path, so with `/tmp/link` a link to `/data/dir`, `cat /tmp/link/../config`
  reads `/tmp/config` where design-files.md's resolution, which follows links before `..`, reaches
  `/data/config`, and `rm`, `mv` and `mkdir` act on that wrong file within the session's grants. Make it only
  join a relative name to the working directory and leave `.` and `..` to the namespace, with a test
  through a link.
* [Medium] shell, pipeline admission: each pipeline stage is admitted at
  its full `max_heap_size`, 16 MiB, against an eighth of the session's
  budget, so a 128 MiB session admits one stage and `ps | where | sort`
  fails. Admit stages against their expected heap, or share the eighth
  among a pipeline's stages ([design-shell.md](design-shell.md)).
  The 8 MiB child each evaluator parses a unit in is admitted nowhere,
  so SH2's claim that stages stay within the allowance leaves it out:
  charge it with its evaluator or admit it against the allowance.
* [Medium] shell, recovery after a refused unit: after `line too long`
  `erx_shell_parse:next/2` resumes nothing it was handed, but the lines
  of the unit that the terminal has not delivered yet (the rest of a
  pasted `fn`, or of a line still being read) would run at the top
  level, and after a syntax error inside a multi-line unit the lines
  after the fault run, as in rc. Decide what the interactive loop
  discards: the terminal's pending input, input up to a newline, or
  input until the open constructs close
  ([design-shell.md](design-shell.md#the-language)).
* [Medium] shell and programs, command domains: `system`, `popen` and
  every Erlang command a program starts begin a command domain, at an
  estimated 0.15 to 0.3 s each, and `wak`'s `system()` pays it per call.
  Make one command domain per image, lazily, which holds the same
  authority by construction. Command domains take their names from the
  per-principal pool of reusable names that
  [design-system.md](design-system.md#identifiers) defines
  ([design-shell.md](design-shell.md),
  [design-programs.md](design-programs.md#what-a-program-can-start)).
* [Medium] shell and programs, what `/bin/sh` and `system()` mean for
  ported programs: `system` and `popen` run `rc`, so a FreeBSD program
  that calls `system("cmd 2>/dev/null")` or similar sh syntax breaks,
  against the goal of running FreeBSD programs ported at the source
  level; a POSIX sh exists only in the second tier. Decide before Track
  S's programs part; the interactive shell stays rc
  ([design-shell.md](design-shell.md#rc-as-a-program),
  [design-programs.md](design-programs.md#toybox)).
* [Medium] programs, signals to self: a signal a program sends itself has
  three delivery paths, so `killpg(getpgrp(), SIGTERM)` in the second tier
  can deliver twice. Make the handler the one path for every signal a
  program sends, its own included
  ([design-programs.md](design-programs.md#signals-in-liberx)).
* [Low] programs, compatibility: `daemon()`, the double fork, toybox's
  `setsid` and `nohup x &` cannot outlive their starter under "a program's
  tree ends with it", and only "no `SIGHUP`" is in the compatibility
  table. List them there as documented differences with tests
  ([design-programs.md](design-programs.md#a-programs-end)).
* [Low] shell, `erx_shell_pipe` (`erlang/apps/erx_shell/src/erx_shell_pipe.erl`):
  the pipe holds every request sent to it, so the bound on what waits in
  it rests on its callers keeping one write and one read unanswered;
  refusing a second waiting request per sender would make it hold by
  construction.

## Security residuals

* [Low] shell, plain spawns that hold the shell's variables (design-shell.md, "Failure handling,
  diagnostics and debuggability"): every evaluator process starts through
  `erx_shell_runner:spawn_evaluator/3`, whose end names nothing, but a few processes that hold
  variable data start otherwise, so a crash of one could quote a variable in its exit reason or
  crash report: a program's handler (`erx_command_srv:perform/2`, `spawn(erx_prog_handler, ...)`,
  with the program's environment), the pumps of a program's pipe ends (`erx_shell_program:pump/2`),
  the pipe's server and its pumps (`erx_shell_pipe:new/0`, `from_binary/1` and `from_file/1`, with the bytes they carry),
  and the exec's own process (`erx_shell_script:start/2`, behind `command/3` and `job/5`, a `proc_lib`
  spawn holding the first variables). None of them evaluates the shell's source; each runs fixed code over what it holds. Fix by giving each
  a fixed-reason end as the funnel has, or by `format_status/1` and `sensitive` where a report is
  the risk.
* [Low] Console line and terminal reports (erx_console.erl, erx_console_keys.erl): a terminal that reports text a session chose, such as xterm's title report where it is allowed, lets the session type anything at the line, `Ctrl-G` included, which no rule over the bytes can tell from typing. The menu drops the rest of the read that opened it and takes only one-byte reads, which stops a reply that arrives in one read; one the line driver splits into single bytes could still choose an entry, the system shell included. Settle it when logins come (M10): the system shell entry asks for the line's login again, or the host tool's console refuses terminal reports the session did not ask for. A terminal that sends 8-bit controls as raw bytes (0x9D, not U+009D written as UTF-8) is not recognized either, since such a byte is a UTF-8 continuation byte; recognizing it needs the rule to track UTF-8 lead bytes.
* [Medium] Console line and keyboard modes (erx_console.erl, erx_console_keys.erl): a session's output reaches the operator's terminal unchanged, so it can switch on the kitty keyboard protocol (`ESC [ > 1 u`), xterm's modifyOtherKeys level 2 (`ESC [ > 4 ; 2 m`) or keyboard lock (KAM, `ESC [ 2 h`), after which `Ctrl-G` arrives as `ESC [ 103 ; 5 u` or `ESC [ 27 ; 5 ; 103 ~`, or not at all, and the operator cannot reach the menu until they reset their terminal; `docs/design-live.md` says Ctrl-G always reaches it. Teach `erx_console_keys` those encodings of `Ctrl-G` (a terminal sends neither unasked), and have the console reset the terminal's keyboard modes whenever it takes the line from a session.
* [Medium] Console line after it comes back (erx_console.erl, `to_groups/2`): a session's output already sent to the line driver, up to 4 KiB, still reaches the line after `Ctrl-G`, `detach/0` or the session's end, after the console's notice, so it can draw a false prompt. Give the line back once the outstanding write is written, holding the groups' output until then.
* [Low] Console and lost-output lines (erx_console.erl, erx_tty_master.erl): each empty resend of a tty's next output logs one line under the system domain's own source, so a session that sends `{tty_output, Next, <<>>}` in a loop spends the system domain's 16 KiB/s log budget and drops its records. Charge the line to the session's source, or count losses in the master and log the count at most once an interval.
* [Medium] Console and a restarted relay (erx_console.erl, erx_tty_master.erl): `erx_session_sup` restarts `erx_session_tty`, whose numbering starts again at 0, so once the master has taken an output the new tty's first output fails the checks and the session is detached for good; `add_session/2` naming a new tty keeps the old master. Reset the master when the tty changes, with a test of a relay's crash.
* [Medium] erx_console:terminal/0 (erx_console.erl, erx_shell.erl `start/0`): the domain's line is a persistent_term that the line's console writes at start (the system console, or a session's console tty), and a stopped line leaves its pid behind. `erx_shell:start()` typed at an Erlang shell on another of a session's ttys, such as a terminal's (erx_session_tty:open/1), runs the new command shell on the line, not on the tty it was typed at. Deriving the terminal from the caller's group leader, whose driver is its console, would remove the shared state; settle it before `erx_term` lands.

* [Low] shell, `ping` (`erlang/apps/erx_shell/src/erx_cmd_ping.erl`): every session is root's, so ping
  takes `-s` up to 65507 and `-i` down to 1 ms for everyone. Once sessions have users, a non-root
  session gets FreeBSD's limits: `-s` at most 56 bytes and `-i` at least 1 s (ping.c's `uid` checks).

* [Low] shell and console, who may take the console: any process of the
  system domain may call `erx_console:run_shell/1`, which gives a group
  of its choosing the operator's keystrokes, or `erx_console:write/1`,
  which puts raw bytes on the line past `prim_tty`, the escaping and
  the hidden groups' policy (a command shell under another one still
  writes). Acceptable while development builds run trusted code only;
  tie both to the current group, and add a chokepoint check of
  `write/1`'s callers, before the security closure
  (`erlang/apps/erx/src/erx_console.erl`).

* [Medium] The pipe's shared-page chokepoint, `pipe-pages-accessor` and
  `pipe-pages-raw-load` in `tools/lib/erx/chokepoint_rules/pipe.rb`: text
  rules over the pipe layouts' generated load accessors and the atomic
  load primitives. A plain dereference of a pointer into a pipe's page (a
  seq_cst load, since every generated field is `_Atomic`), a `memcpy`
  from one, and an atomic load in a liberx file outside the pipe's files,
  typed or not, escape them; the lock's compare-and-swap and the bit-set
  read-modify-writes on `owner`, `waiters` and `sleepers` read the page
  too and match no pattern, as design.md's row allows, so that they touch
  only those words is held by review, as is that only write ends call
  `erx_pipe_rpage_rpos_load` and only read ends `erx_lane_hdr_wpos_load`,
  and that no pipe file reads `wpos` through a relaxed `erx_shm_copy`. Close it
  with the lane reader's item: the syntax-tree leg checks every load whose
  address derives from a pipe end's mapping.
* [Medium] The pipe core's exploration (`test/fixtures/pipe_explore.c`)
  covers one write end with one or two read ends and two write ends with
  one read end. Still to come: three write ends with one read end, where
  the second look covers two lanes the first found empty (with one-byte
  records it did not finish in 25 minutes at -O2 on an Apple Silicon
  host, nor in 400 s with one read, so it needs a further reduction); the shapes with several
  write ends and several read ends at once; the co-readers' loss with
  bytes to read (`coread-lost` explores it with nothing written: with a
  byte, the loss report pending at each party keeps every step of the
  others in play, and the run did not finish in minutes); the bound of
  PI6, that another writer delays a record by at most two lanes'
  capacity, which the model's lengths never reach and no property
  checks; a merge shape with a read shorter than a record, so that a
  partly claimed record of one write end must beat a smaller key in
  another lane; a check at each landing of a reader's `rpos` or `cur`
  store that the reader holds the lock, which the reduction treating
  their loads as local assumes, and claims checked against the owner as
  the claimer sees it, its own buffered release included; renumbering
  the steps' private clock readings in `forget` instead of zeroing them,
  which holds only while the core reads them where it does now; the
  look's order, the clock read before the acquire copy of `wpos`, on
  which the mark rests: an acquire load does not hold an earlier counter
  read before it on AArch64, so `erx_clock_ns` as `liberx/program/pipe.c`
  calls it needs checking for the barrier, and a litmus test; and the instrumented
  `erx_shm_copy` that fails on a second read of one field in one step,
  which belongs to the effect layers that copy (`liberx/program/pipe*`,
  the pipe NIF), since the steps read no page.
* [High] pipes, PI6 and equal clock readings: the merge's argument
  ([design-pipes.md](design-pipes.md#reading-and-merging)) needs a
  reading taken after a record's publication to exceed the stamp read
  before it. A nanosecond clock derived from a slower counter can return
  equal readings, and on equal keys the lower write end goes first, so a
  record written after another's publication can be read before it, a
  wrong order returned as a right one. The
  exploration's clock advances at every reading and never shows it.
  Decide whether the time page promises a strictly advancing reading
  across a publication, or the order key breaks such ties another way,
  and give the model a clock that may repeat a reading.

## Planned features

* [Medium] shell, an Erlang command's streams over pipe-server ends
  ([design-pipes.md](design-pipes.md#the-sessions-pipe-nif)): that is the
  long-term shape of `erx_cmd`; a job's message pipes (`erx_shell_pipe`,
  as the SSH job relay uses them) are the step before it.
* [Medium] programs and shell, terminal reads by programs and by command domains
  ([design-programs.md](design-programs.md#the-terminal), "No terminal input without the signal handshake";
  [design-shell.md](design-shell.md#the-terminal-relays-protocol), "A reader the signal ends"): a program's
  handler and a command domain's stream relay open the terminal write-only, so a program's terminal `read` fails
  with `EBADF` and a command domain's read of a terminal stream, named `write` in its startup message, ends the
  command with status `ebadf`, because neither the handler nor the stream relay belongs to a job, so no tag mark
  stops it, and nothing orders the handler's report of a signal to its program, or the run server's mark in the
  command domain, before the relay's ready report: a program or a narrowed command that a `Ctrl-C` ends could read a
  key typed after it. Design the handshake: each handler and stream relay answers the shell once its program or run
  has taken the signal, and the shell sends `{foreground, Job, current, Signals}` only after every answer; with it
  the handler and the stream relay open the terminal with `erx_session_relay:open_reader/2` (and join the
  chokepoint's list), the stream relay names a terminal stream `{relayed, read_write, tty}` and copies its input, the handler's
  reads pass as "Reading a terminal" describes, and that section's tests run.
* [Medium] shell, edit 73 of [design-runtime.md](design-runtime.md) is built only in part
  (`otp/lib/stdlib/src/edlin_key.erl` `get_valid_escape_key/2`, `otp/lib/stdlib/src/edlin.erl`): a character that
  cannot continue a CSI sequence ends it and is read again, NUL ends any sequence until the loss event below
  replaces that rule, and a key cut after
  two or more CSI digits waits for the rest, but the rest is stock. A delivery that ends after one CSI digit takes `ESC [ 3` as a whole key and inserts
  the `~` that follows. Digits accumulate without the 15-character bound, a complete key takes one more `~`, and
  no line bound is kept: a line has no 65,536-codepoint limit and no count beside it, so a paste grows the group
  without end, and the scan for the lost-input mark each time a line is finished (edit 81) costs the length of
  the line until the loss event below replaces it. Build the rest of edit 73 with its tests, beside
  `test/host/edlin_marker_test.rb`.
* [High] shell and console, the input-loss event ([design-live.md](design-live.md#lost-input), edits 73, 80
  and 81 of [design-runtime.md](design-runtime.md)): a line that lost input can still run today. A
  `tty_input` the system domain's peer drops, a byte the tty drops for room and a character `edlin`'s bounds
  drop are lost silently; and the system console pushes input into a group that may not read, with no bound.
  The console's drivers send `erx_console_lost` in order with their bytes and keep one input message
  outstanding until `erx_console_taken` (`erx_uart_input`), which `erx_console` answers at once, handing the
  group a loss as NUL, which `edlin`'s NUL rule refuses; step 4 replaces that. Build the rest of the design's event in
  steps, each with its rows of the design's verification table:
  2. `erx_tty`: held input as units, `lost/1`, a loss where `input/3` drops for room, settlement over units, one
     consuming step for `read/3` and `read_input/2`, `flushed_loss` from a flush that drops a loss, with `lost` in `erx_tty_modes_tests` and `erx_tty_fuzz`;
  3. the console interface: `{tty_input, N, Bytes}` and `{tty_lost, N}` in `abi/services/console.txt`, numbered by
     every master (`erx_tty_master`, `erx_term`, `erx_ssh_dev_channel`) and checked by `erx_tty_link`, a gap taken
     as a loss; the relay serves `{tty_read_input, Open, N}`;
  4. `erx_console`: both roles read on demand, the system role from its own `erx_tty` with a terminal's or a
     pipe's settings as `Terminal` says, deleting `input/2` and the push; the console answers a terminal's input
     at once and a pipe's once there is room; a loss, and the relay's `lost` event, damage the group's read, and a
     loss drops a cut character and resets `erx_console_keys`;
  5. `group` and `edlin`: the damage in each input request's state, a loss damaging every unfinished request, `edlin:edit_line/3`, `lost` as an input,
     refused bounds as losses, refusal through `finish/4` until the buffer is emptied, a request starting with the group's derived damage, dumb mode; delete
     the hold, the NUL scan, `edlin_key`'s NUL rule and `group`'s history rule; `test/host/edlin_marker_test.rb`
     becomes `edlin_lost_test.rb`.
* [Medium] console, crash reports (`erlang/apps/erx/src/erx_console.erl`): the console exports no
  `format_status/1`, so a crash while it handles `{erx_console_input, Bytes}` reports the message and the state,
  which can hold a typed passphrase. Hide its terms as `erx_pl011` and `erx_mini_uart` do, with a case like
  `erx_pl011_tests`' `format_status_shows_only_the_reasons_name_test`.
* [Low] console, the answer to a driver's input (`erx_uart_input`, `erx_stdio`): a driver takes
  `erx_console_taken` from any process of its domain, so a stray answer lets it send one more message, bounded by
  its input. Tagging each input message with a reference the answer carries would ignore stray answers by
  construction.
* [Low] shell, `prim_tty` `split_cols/6` counts a caret as two characters, so after a vertical move in a
  multi-line edit, deleting a control character shown in caret notation leaves its `^`.
* [Medium] shell and console, the end of input on an unmarked line in `edlin`'s mode (`otp/lib/stdlib/src/edlin.erl`
  `finished/4`, `otp/lib/kernel/src/group.erl` `xterm/3`): as on stock, `edlin` finishes the line and hands no end of
  input on, and `group` reads the line, which has no newline, as an unfinished one and asks for more, so a read
  of a group in `edlin`'s mode, a shell's on a console line with a terminal (`erx_console` `group_options/1`), never
  ends at the end of input, even on an empty line, and the console sends `eof` once. Only a line of a read that lost input, which `edlin` drops, ends the read (edit 81
  of [design-runtime.md](design-runtime.md)). Decide whether every line should: `edlin` would hand the end on
  after any line, and `group` would read the line, if it has text, and then the end, as its dumb mode does, with a
  test beside `test/host/edlin_marker_test.rb`'s end-of-input case.
* [Low] shell, the console's group's line history (`otp/lib/kernel/src/group.erl` `save_line_buffer`, `:1294-1305`):
  the group keeps every line its editor returns, so a long session, or a paste or peer that sends many lines, grows
  the group without end, though edit 73 of [design-runtime.md](design-runtime.md) bounds each line. Keep the
  most recent lines only, with the bound in design-runtime.md's list of edits and a test that measures the whole group
  after many lines, beside design-shell.md's "A line that never ends".
* [Low] shell and programs, `Ctrl-T` (`SIGINFO`, [design-programs.md](design-programs.md#the-terminal),
  [design-shell.md](design-shell.md#ctrl-t-status-and-the-info-request)): the status line and the info
  request, right after the signal and errno table package, which gives `SIGINFO` its number.
* [Low] shell, `ping` (`erlang/apps/erx_shell/src/erx_cmd_ping.erl`): it does not compare a reply's data
  with what it sent, so FreeBSD's `wrong data byte` report of a corrupted reply is missing; the
  checksum check in `erx_icmp4_wire` still drops a reply corrupted on the wire.
* [Low] shell, `ifconfig` (`erlang/apps/erx_shell/src/erx_cmd_ifconfig.erl`): it shows no `lo0`, since
  the stack runs no loopback interface process, and no `inet6` lines or `nd6` options: it
  writes only the IPv4 rows of `erx_net:interfaces/0`. Add `lo0` once a loopback interface
  process exists, and the IPv6 rows in FreeBSD's layout (`prefixlen`, `scopeid`).

* [Low] shell, `host` (`erlang/apps/erx_shell/src/erx_cmd_host.erl`, `search/4`): a candidate whose A query
  answers no records (NODATA) ends the search, where `res_search(3)` notes it and tries the rest of the
  search list, answering NODATA only when no candidate has the name. Go on past NODATA as `res_search`
  does, with a case for a search list whose first domain has the name without an address.
* [Low] shell, `host` (`erlang/apps/erx_shell/src/erx_cmd_host.erl`): FreeBSD's host(1) also asks for MX
  records and writes `name mail is handled by N exchange.`; erXos's asks only A, AAAA and PTR. Add the MX
  query and its line, with a case in `test/erlang/erx_cmd_host_tests.erl`.
* [Medium] console, log lines at console lines: until the log design
  settles routing, state in
  [design-live.md](design-live.md#the-console) the access rule it
  must keep, that a line shows only log lines of domains its principal
  may inspect, and reconcile the **Logs** bullet, which still makes
  `erx_console` the sink, with design-kernel's log service.
* [Medium] console, leftovers of the one-line model: the overview
  diagram and the paragraph after it in
  [design-live.md](design-live.md#overview) describe one serial
  console; the host tool reads `[kernel, crash]`, which only the system
  shell's facet reaches, so either the host link gets its own crash
  reading grant or the tool reads it through the system shell; and the
  system-shell facet, which only the console and the system shell hold,
  may read more simply as the console's per-line login record.
* [Low] console, residuals to state: processes the system shell starts
  are system-domain processes and outlive its login; a development
  manifest does not have to mark the UART secure, though development
  builds assume it; host-link login failures count in the UART's class
  and can lock a name out there
  ([design-live.md](design-live.md#security)).
* [Low] console, moving a session: an explicit detach and attach, as
  screen and tmux offer, run by the session's own user, so a terminal
  can move from one console line to another; connecting a terminal
  already connected at another line is refused
  ([design-live.md](design-live.md#the-console)).
* [Medium] shell, the rc oracle's corpus: import Byron Rakitzis's `trip.rc`
  (zlib, `github.com/rakitzis/rc`, SHA-256 in
  [research-boards-storage.md](research-boards-storage.md#the-command-shells-oracle))
  beside plan9port's `test.rc` in `test/shell/rc/`, pinned like any
  source, with the cases for that implementation's extensions set apart;
  build toybox for the host and put it first in the oracle's `$path`; and
  compare the Erlang shell with `Erx::RcOracle` script by script
  ([design-shell.md](design-shell.md#verification-and-testing)).
* [Low] shell, the rc oracle on Linux: `Erx::RcOracle::Build` links the
  lib9 members rc pulls on macOS; check the list and the flags on Linux
  hosts when the plan reaches them.
* [Low] shell, the rc oracle runner's residuals (`tools/lib/erx/rc_oracle.rb`), for
  trusted corpus scripts: rc stays in the operator's session, so a script
  can open `/dev/tty`; a program that leaves rc's process group escapes the
  kill at the end, and a writer killed mid-write can add bytes after it;
  a script that replaces `sigexit` can write a status report itself; the
  build inherits the host's compiler environment (`CPATH`, `SDKROOT`),
  which its record does not hold; `TZ` and the umask come from the host;
  and programs see `fn#sigexit` and `PLAN9`, which the comparison with the
  Erlang shell must leave out.
* [Low] console interface, typed-ahead input
  ([design-ssh.md](design-ssh.md#sessions-ttys-and-shells),
  [design-live.md](design-live.md#paths)): a tty drops `tty_input`
  past its bound, so a paste over SSH larger than the bound into a program
  that is not reading loses bytes, which the tty marks as a loss, as at the console. An acknowledgement of
  input in the console interface would let the channel open the client's
  window only as the tty takes input.
