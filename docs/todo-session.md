# TODO: Sessions and SSH

Open work on sessions, SSH, the vault and login. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Bugs by subsystem

* [Medium] login, a message grant's parameters (`erx_domain_srv:served_grant/3`): the row's
  parameters are merged into the grant map beside the keys the facet and its callback read
  (`behind`, `holder`, `scope`, `worker`), which stay intact only because the domain service
  writes them later and no interface the system domain serves declares a parameter of those
  names. Carry parameters under one key, or have the ABI generator refuse reserved names.
* [Low] erx_facet, the crash log line (`serve/1`): that a crash is logged by its callback's
  name and its reason's leading atom alone has no test; add a capture-handler case with a
  sentinel, as `erx_login_tests` has for the service.
* [Medium] login, a login service crash spends the front ends' intensities (docs/design-login.md,
  "Failure handling"): each crash ends every front end's domain, and each end counts against its
  start row's intensity (5 in 600 s by default), so six crashes in ten minutes leave SSH and the web
  down for the boot. Fails safe, with a stop. Have the domain service not
  count an end a served facet's end caused, and reconcile with docs/todo-domains.md's re-grant item.
* [Medium] login, the user-name rule at the front ends (`erx_ident`, `erx_login.hrl`,
  docs/design-login.md): `erx_ident` ships in the system domain alone, so a
  front end's prompt cannot check a name as the facet does, and `erx_login.hrl` no longer carries
  a name bound. Move `erx_ident` into the `erx` application, its bound from `identifier_max`,
  before a front end checks a name itself.
* [Low] login, long principal names (`erx_domain_core`, session names): a principal named in 62
  or 63 bytes can be named at a login, but its session name `NAME_N` is no identifier, so its
  login answers `unavailable` after the check. Bound the names of principals with a session
  template in the manifest check.
* [Medium] login, the connection-binding test (docs/design-login.md, "Verification"): a
  `login_key` from a process other than the cookie's answering `no_match`, with the table keyed
  by the facet's forward as its seeded fault, lands with the key login, since `login_key`
  answers `unavailable` until the service verifies a key.
* [Medium] session domain, programs: a program's anchor is a sub-space of the session,
  but nothing yet ends a session's programs with the session domain. Until something does, no test ends a
  session while one of its programs runs.
* [Medium] session, process ids beside the command server (`erx_program:start/1`, `tools/lib/erx/programs.rb`
  `spec/2`): the command server gives a pid at most once (docs/design-programs.md, "The command server"), but
  any session process may still call `erx_program:start/1`, the driver's seam below the handler, with a pid
  of its choosing, and the driver does not refuse one a live program already has. The programs suite's driver
  cases do so with pids 2 to 45 in the session whose server gives the suite's handler cases 2 to 4; it holds
  only because none of those three is an id a driver case gives pipe ends, an exception list. Reserve each
  driver case's pid with `erx_command_srv:reserve/1`, the shell's process as its speaker. The
  `program-start` chokepoint keeps every Erlang source but the handler from naming `erx_program`, but the
  suite's driver cases type `erx_program:start/1` at a shell, which no build check reads.
* [Low] session, `erx_command_srv`: a row drops at any `{'DOWN', _, process, Speaker, _}` the server takes,
  so a session process that sends one forged drops a live row (its job's await answered early, a kill of it
  `esrch`; the id is still never given again); keeping each row's monitor reference and matching it would
  count only real ends. A signal that reaches a handler before its start is carried out once the program
  runs, but `{erx_job, pause}` and `{erx_read, _, _}` are dropped with the handler's other unknown messages,
  so a job paused in that window runs its program (the `erx_prog_handler` item below).
* [Low] session, `erx_session_export`: each open of a program's `/dev/clipboard` holds one fid on the
  session's display grant, so a program and its children can hold up to their tree's pool of them and
  make the session's other window opens fail at the display grant's pool.
* [Medium] session, a program's `/dev` (docs/design-files.md, "A program's window"): each open of a
  relayed window file (`kbd`, `mouse`, `wctl`, `label`) holds a fid on the session's grant of the
  display, and each read of `kbd` or `mouse` waits there as a request in flight until the window has
  input. A program and its children can open and read until they fill that grant's fid pool or its
  requests in flight, and the session's other windows, the shell's included, then fail their opens and
  reads at the display grant. Bound what one program's tree may hold on the session's grant (a share of
  the pool per tree, or a grant of the display per windowed program), as the clipboard item above needs
  too.
* [Medium] session, `erx_session_export` (`displays/0`), the displays a session holds: a program's
  first open of `/dev/draw` opens its window on the display its `display` variable names or on the
  session's only display ([design-display.md](design-display.md#choosing-a-display)), which needs
  the names of the `windows` grants among the session's facets. The registry (`erx_facets`) keeps
  each facet under its service's name and records no interface, and a windows grant is a bare pid like
  a `net` or `clock` facet, so `displays/0` answers the facet named `display`, the name every manifest
  gives its one `windows` service. A session holding a second display under another name gets no window
  on it (`ENODEV`), and one holding both opens on `display` rather than refusing. Have the domain
  service mark the `windows` grants in what it installs (`erx_domain_mints:installed_facet/3`, which
  already knows `windows`), keep the mark in `erx_facets:facet/0`, which alone knows a facet's shape,
  and read it here through an `erx_facets` reader.
* [Medium] session, `erx_session_export`: the export serves the fixed tree alone. The tree of each of
  the session's local providers, named from the session's counter when it is mounted
  (docs/design-files.md, "Narrowing for a program"), is not there; `/bin` lists the Erlang commands
  alone, not the boot image's programs the command namespace lists, so `/bin/rc`, the shell
  `/etc/passwd` names, is missing.
* [Low] session, `erx_session_export`: its statfs answers devfs's type for a tree that also holds
  `/bin` and `/etc` (`abi/protocols/9p.txt`, `p9_magic`, one type per kind of tree), its files show
  uid 0 where the design's owner of a file its server records none for is `nobody`
  (docs/design-programs.md, "Users and files"; `erx_fs_node:attr/3`), and `/etc/passwd` shows size 0.
* [Medium] session, `erx_session_sup:export_args/3`: the login name `/etc/passwd` shows is read back
  from the session's node name, the prefix before `_N`, so the format erx_domain_core:session_name/3
  makes is known in two modules, and a change to it gives a wrong name or a session that fails to
  start. Have one function, beside erx_build:principals/0, give a principal's session prefix to both,
  once it is settled that a session may read the system manifest.
* [Low] session, `erx_session_sup`: the export's two grants each build the fixed tree, so `/dev`
  and `/etc` reached through the `rx` grant, and `/bin` through the `rw` one, have other qid paths
  than through the grant a handler walks them on. No reader sees both while the handler reaches
  `/bin` only through the `rx` grant and the rest only through the `rw` one; one tree behind both
  grants would remove the question.
* [Medium] session, `erx_pipe:step/2`: the second tier's events are not there: `{deposit}`, `{redeem}`,
  `{discard}`, `{withdraw}` and the collector of deposits no reader can reach
  (docs/design-pipes.md, "The second tier" and "Deposits"), and `holder()` has no
  `{deposit, Ticket}`. `test/erlang/erx_pipe_explore.erl` gains their events with them.
* [High] session, `erx_prog_handler` (file requests): the handler serves `lopen`, `lcreate`, `read`,
  `write` and `clunk` over the program's narrowed namespace through `erx_file_description`, and moves
  their bytes through the data area (`erx_program:data_read/3` and `data_write/3`), but no program
  sends a file request yet: `liberx` has no file client (docs/design-files.md, "Native clients:
  `liberx`'s file client"), so the programs QEMU suite has no C test program that opens, reads, writes
  and closes a file. The driver's two data copies (`erx_program_drv.c` `data_slot`, `DATA_READ`,
  `DATA_WRITE`) run on no target test either, though one needs no file client: a test that owns a
  program's port can write and read back a slot, and be refused a slot equal to `slots`, a caller other
  than the owner and a copy after the program ended. The handler's stand-in `erx_program:data_read/3`
  answers `enosys`, so its effect suite never runs a write that succeeds. `prim_file:erx_open_at/5` and
  `erx_file_remote:open_flags/4` have no host test against a stand-in file server; the handler's effect
  suite stands in `erx_file_description`. The other operations of the `{file, ...}` row wait too. No
  QEMU case runs a program's `pwrite` end to end yet (the programs suite's `fileio` runs `lseek`,
  `pread` and `fstat`).
* [Low] session, `erx_file_remote:open_flags/4`: an `lopen` that writes on an entry that is not `rw`
  answers `erofs` before the path is walked, so a missing file opened to write there is `erofs`, where
  FreeBSD's `vn_open` answers `ENOENT` from the lookup first.
* [Medium] session, `erx_prog_handler_core` (narrowing): a narrowed entry is a path re-walked at each
  open, not a fid the handler walks at the start (docs/design-files.md, "Narrowing for a program"), so
  a narrowing to a missing directory is refused only at each open, and a rename of the narrowed
  directory at the server moves what the program reaches; a description holds one opened fid, not the
  design's unopened and opened pair.
* [Medium] session, `erx_prog_handler` tests: the effect suite runs no file request past an open's
  refusal (its `erx_file_description` stand-in answers `enoent`), so the read, write, copy and clunk
  actions and the description's loop run in no test; and the core's exhaustive walk checks only the
  frames sent, not the relayed actions, and leaves out write, clunk, error answers and an answer of the
  wrong kind on a waiting slot.
* [Low] session, `erx_prog_handler` (files): the release refuses every `lcreate` with `erofs`,
  an exclusive one at an existing name included, where an image answers `eexist`; an open at a
  directory of the empty root answers `eio`; a start whose `cwd` the startup grammar accepts but
  `erx_path:cwd/1` refuses (a trailing `/`) is refused `einval`. An open that writes on a read-only
  grant, the release or an image answers `erofs` before it looks, where FreeBSD's `vn_open_vnode`
  answers a last link under `O_NOFOLLOW` `EMLINK` and a file under `O_DIRECTORY` `ENOTDIR` first; an
  `O_DIRECTORY` open of an image's directory or of a top answers `enotsup`, and a plain read-only open
  of a directory on the release `eisdir`, where FreeBSD opens it. No case of `prim_file:erx_open_at/5`
  runs on the host: its flag rules are reached by the programs suite alone. An `openat` relative to a
  directory a program opened with `O_DIRECTORY` answers `ENOTDIR` (`liberx/program/file.c`, `dirfd_check`),
  since the request carries no directory to resolve from.
* [Medium] session, `erx_prog_handler`: the handler starts a program for a session process with its pipe
  ends and a window's buffer, forwards its notices and reports, and tells the starter its end; the command
  server (`erx_command_srv`) assigns its process id and spawns it. What remains: the program's requests
  other than `kill` and `probe`, a program as a starter (step 3's checks of its table), the handler's side of
  the server's messages to a row's handler (`{erx_job, pause}` and `{erx_job, resume}`, carried out with the
  `job` cause, which no handler acts on, so `Ctrl-Z` pauses a line's Erlang processes and not its programs;
  `{erx_signal, Signal, Sender}` and `{erx_job, {signal, Signal}}`, of which only `sigkill` acts, as a stop,
  since the program protocol has no report that carries a signal into a program: `Ctrl-C` ends a program
  through its starter's end (`sigkill`), `kill -INT` or `-TERM` of a program answers `ok` and does nothing,
  and `-STOP` and `-CONT` likewise; and
  `{erx_read, Alias, Keys}`, which no handler answers yet, so
  `erx_command_srv:read/2` gives every handler's value as `missing` after its whole wait), and the
  QEMU tests of hand-offs between domains (docs/design-pipes.md, "Verification and testing"). The programs
  suite's `handler` case runs the handler at root_1's shell; `pipe_hand` and `install` test the driver's
  takes and installs directly.
* [Medium] session, `erx_prog_handler_core` tests: the exploration in
  `test/erlang/erx_prog_handler_core_tests.erl` offers neither hand-off reports, the install answers, a
  send error nor `pipes_lost`, and does not walk the reserving phase against every refusal point; a protocol
  state machine is explored exhaustively.
* [Low] session, `erx_prog_handler`: the core's running clauses read the queue head's kind by matching
  it (`{install_refused, _}` with a frame at the head crashes, which the effect layer never produces);
  an `out` of `{sending, frame | hand}` makes those states unrepresentable. Errno decisions (`none` to
  `einval`, `undef`/`noproc` to `enodev`, a lost pipe server to `enomem`, `badarg` to `einval`) sit in the
  effect layer, and `error:undef` also reads a missing function of a present allocator as `enodev`. A
  buffer's `Bytes` is not bounded by `prog_mem_bytes` before the alloc. `watch_pipes/0` is not retried
  after a loss that finds no restarted server, so a second loss does not reach the program. `perform/2`
  runs a nested step's actions before the rest of its list and is not a tail call; the `exit` action does
  nothing. `pipe_report` and `erx_prog_stop` are taken from any process (session code is trusted), and
  the pipe server's starter-named inherit trusts the `Starter` the handler names. In the reserving
  phase an event the core does not expect is ignored, which leaves `start/1` waiting until its deadline; refusing it as
  `einval` ends the phase by construction. `start/1` passes through `noproc` from `erx_pixels:lend/2`
  and `badarg` from the pipe server, neither an errno it documents. A `closed` or `drained` notice
  taken ahead of the pipe server's `'DOWN'` goes to the restarted server before `pipe_server_lost`
  reaches the program, against docs/design-pipes.md, "The pipe server" (harmless: the restarted server
  numbers its pipes past the old ones, so the notice names no end).
* [Medium] session, `erx_pipe_nif.c` and `erx_event.c`: each ring of a session end's doorbell is one
  `{erx_pipe_ready, _, _}` message, uncoalesced, so while an end waits (bits set for that wait only) a
  co-reader that loops on the lock or a writer's repeated crossings can queue many messages before the
  owner reads again, and `erx_pipe_srv:retry/2` leaves the extras in the mailbox. Coalesce per end (a
  ready-sent flag the next `nif_read` re-arms), as a program's doorbell counts triggers once.
* [Low] session, `erx_pipe_nif.c`: when `enif_alloc_env` fails, a `closed`, `drained` or
  `pipe_server_lost` notice is dropped, so a closed end never reaches the server (no eof or `EPIPE`
  follows) or a drained lane is never forgotten. Out of memory only; retry from the next call or
  preallocate one environment per end.
* [Low] session, `erx_pipe_nif.erl`: `make_lock/1`, `make_lane/1`, `make_bell/3`, `hand_make/2` and
  `program_holder/1` are exported, so code that does not come from the tree (an expression at a session's `erl`
  shell, an app installed at run time) can make pipe objects outside the step's `pipes` quota, or make the holder
  entry of a program whose handler has not made it yet and so speak for that program; objects are collected
  with their terms. The build check `tools/lib/erx/chokepoint_rules/pipe.rb` keeps the tree's own modules from calling
  them; restrict them to `erx_pipe_srv`'s and the handlers' processes when `erx_policy` sets the quota.
* [Low] session, `erx_pipe_nif.c` (`end_broken`): the broken-lane line goes to stderr, not to the
  debug log as one escaped line (docs/design-pipes.md, "Failure handling, diagnostics and
  debuggability"); it carries integers only.
* [Low] session, `erx_pipe_nif.c` (`get_obj`, `obj_keep`): for a session process's end, `closed` is
  read without `obj_mutex`, and a keep does not refuse a closed object; reachable only if the server
  passed an object after its own close. Check and count under `obj_mutex`, as `obj_keep_held` does
  for a hand-off.
* [Medium] session, `erx_pipe_nif.c` (`erx_pipe_hand_take`, `erx_pipe_holder_release`): the port's
  hold names the program, not its port. An owner that starts P1, then a second port P2 under the same
  pid whose start takes a valid hand-off and then fails, has P2's undo release the hold P1 took; the
  owner's `holder_drop` then sends the program's gone while P1 can still touch the pipe pages, so its
  peers read the end of the stream early. Only the handler's one port per program prevents it. Pass
  the driver's port as an opaque token to both calls, record it at the first take, and refuse a take or
  ignore a release with another token.
* [Low] session, `erx_pipe.erl` (`copies/1`) and `abi/erx_abi.txt` (`pipe_hand_copies_max`): the
  build checks the limit's arithmetic, not that `copies/1` keeps to it. Add a pure test that fills a
  session's quota with one pipe's write ends and 64 read ends and checks that a read end's descriptor
  has exactly `?ERX_PIPE_HAND_COPIES_MAX` copies, and that `erx_program:install/2`'s walk
  (`hand_count/2`) takes that descriptor within `?HOLES_WALK_MAX`.
* [Low] session, `erx_pipe_nif.c` (`holder_gone`): when `enif_alloc_env` fails, the program's gone
  is not sent and the entry is forgotten, so the pipe server keeps the program's ends until it
  restarts and their peers never read the end of the stream. Make the message's env with the entry,
  so sending it cannot fail for memory.
* [Low] session, `erx_pipe_srv` (`retry/2`): each wake restarts the whole timeout, `write/3`'s spec
  leaves out `{error, eio}`, and a timeout after a partial write does not say how much was written.
* [Medium] session, `erx_pipe:step/2` (`end_gone`, read end) and docs/design-pipes.md ("Ends and
  their holders"): the pipe server closes a gone read end's doorbell at its gone, while the handler
  may still have installs to make from an earlier step that name it: a child's write descriptor
  lists every read end's doorbell, a child's read descriptor every other read end's, and a
  `pipe_reader` report carries the new read end's. Such an install then fails, so a child's
  creation fails or a running holder loses its end, though nothing was wrong (a reader that exits
  while a sibling's write end is still being installed). The handler's merged join,
  `{pipe_reader, ..., gone}` (docs/design-pipes.md, the program protocol's reports), installs a
  copy of a read end's doorbell after that end went, so as written it can never succeed. A gone
  write end's doorbell avoids this by staying with the server until it forgets the write end.
  Two candidate fixes: a step's installs finish before the server takes its next event, or a
  doorbell closes only once no pending install can name it; either makes both kinds of doorbell
  follow one rule. The explorer applies a step's copies in that step, so it cannot see this; with
  the fix it keeps each holder's copies pending until a separate install event and checks
  `names_only_live` at the install, which shows the race on the unfixed tree.
* [Low] session, `erx_pipe:new/1` (`quota`): the `pipes` quota is a parameter, at most and by
  default `abi/erx_abi.txt`'s `pipes_quota` lanes, a fixed value that `erx_policy` replaces with
  each principal's own quota at M10. It counts lanes, so a pipe whose write ends have all gone and
  drained keeps its lock page and its read ends' doorbells outside it, bounded only by its holders'
  ends; settle that when `erx_policy` sets the quota.
* [Medium] security residual (Phase 1), session, `erx_pipe:new/1` (`quota`): one program can
  exhaust its session's memory budget through `pipe` and `pipe2` before the quota stops it, since
  `pipes_quota` lanes at up to 76 KiB each (`docs/design-pipes.md`, "The objects of a pipe") hold
  more than a session template's budget, and so starve the session's own runtime; `pipe` then fails
  with `ENOMEM`, which `docs/design-pipes.md`'s "Making a pipe" allows. `erx_policy`'s per-session
  quota at M10, sized from the session's budget, settles it.
* [Low] session, `test/erlang/erx_pipe_explore.erl`: the exploration of `erx_pipe:step/2` is bounded by
  depth, 7 at the landing gate and 8 at `tools/erx check-fuzz`, not run to completion: a complete run
  with a quota of one lane, numbers up to 3 and two read ends did not finish in 3 minutes. A state key
  that identifies worlds equal up to renaming the two programs (symmetry reduction) may make a complete
  run, or a deeper one, affordable.
* [Medium] session, `erx_prog_handler_core` (`kill`, `probe`): a program reaches itself alone.
  The handler keeps no child record and the program holds no `signal` right, and it asks the
  command server neither `{kill, Scope, Target, Signal, Sender}` nor `{probe, Scope, Target}`,
  nor acts on the `{erx_signal, Signal, Sender}` the server sends a row's handler, so every other
  target is `esrch` (docs/design-programs.md, "The program protocol"). A kill of
  itself with a signal other than `sigkill` and the job-control ones is `enosys`: the protocol has
  no `{signal, Signal, Sender}` report, and `liberx` raises none. Add the report to
  `abi/protocols/prog.txt` with its raise in the event executor, then answer such a kill by
  queueing the report ahead of the reply.
* [Low] session, `erx_prog_handler_core` (`pipe`): when the driver refuses the write end's install
  after the read end's, the handler closes both ends at the pipe server, but the read end's copies
  and its doorbell's bind stay in the program's table, untold to the program, until it ends; on
  Fiasco they hold a few capability slots and the pipe's objects, outside the session's `pipes`
  quota, which the closes freed. Give the program driver an
  uninstall of a hand-off's copies, or install both ends as one hand-off that passes whole or not
  at all.
* [Low] session, `erx_prog_handler_core` (`from_program/2`): it has a clause for each request and
  notice case `abi/protocols/prog.txt` declares, and no other, so a case added to the protocol
  without its clause crashes the handler on the first such frame. Have the grammar generator export
  the cases from the program, and an EUnit case feed the core one accepted frame of each.
* [Low] session start, `erlang/apps/erx_session/src/erx_session_app.erl` (`start/2`): a
  facet mount that fails, of `/data`, `/apps` or `/machine`, fails the `ok =` match and ends
  the session's start, where the session could start without that path and refuse the
  commands that need it with `enoent`.
* [Medium] session start, the session templates' `-eval` (`config/manifest/development.txt`,
  `tools/lib/erx/apps.rb` `TEMPLATE_ARGS`, `tools/lib/erx/display_domain.rb` `CLIENT`):
  `application:start(erx_session)` starts it `temporary`, where docs/design-programs.md ("The
  command server") has every session start it permanent, so the command server's end ends the
  session's domain; as it is, that end leaves a live domain that starts no program. Start it
  with `application:start(erx_session, permanent)` and check the QEMU session cells.
* [Medium] session, terminal relay (`erlang/apps/erx_session/src/erx_session_relay.erl`): each tty of the
  session has a relay, which its console reads on demand, but `erx_cmd` does not read through
  `open_reader/2` ([design-shell.md](design-shell.md#the-terminal-relays-protocol)): a stage's
  standard input with no pipe or redirection is end of input (`erx_shell_runner:new/1`'s and
  `erx_shell_script:run/2`'s `0 => null`), not the session's tty as design-shell.md ("Pipelines") has it,
  so an SSH `exec` on a channel with a tty reads nothing where FreeBSD's sshd gives it the pty. The runtime's
  writers' sender, `otp/lib/kernel/src/erx_output.erl`, which the design and the `relay-name` rule name, is
  not in the tree, so only the console's write/1 sends `tty_write`, and `tty_drain` comes only from a console that exits with
  its shell (`erx_console`'s `on_shell_end`), nor are edit 35's trap and edit 42
  (`beam/bif.c`), which reach it; and `erx_tty_owner` is missing from `erx_session.app.src`'s
  `registered` list. In a session with no console facet nothing holds `erx_tty_owner`, against
  design-runtime.md's table, which names the logger proxy, a process already registered as `erx_log_h`:
  when `erx_output` lands, that row's owner is built, splitting lines with `erx_log_user:lines/2` rather
  than a second splitter, and the table's first row says "a session with a console tty".
* [Medium] session, the masterless console tty (`erlang/apps/erx_session/src/erx_session_sup.erl`,
  `erx_session_tty.erl`, `erx_session_relay_core.erl`, `erx_tty_link.erl`): `erx_session_sup:line/1` starts
  the console tty only for a session with a console facet, but `erx_session_tty:start_link/0` reads the
  facet again, and the relay core's `master => none`, `erx_tty_link`'s path for no master and
  `test/erlang/erx_session_tty_tests.erl`'s `in_session/1` keep a tty with no master that no session now
  builds. Pass the facet `line/1` holds to the start and delete the masterless path and its cases.
* [Medium] session, terminal relay requests (`erlang/apps/erx_session/src/erx_session_relay.erl`): the
  chokepoints keep `erx_tty_owner` and the request for an open made for reading to `erx_session_relay`, and
  an open is opaque, but a module that holds a relay's pid can still build any other request by hand
  (`{tty, Open, ...}`, `{foreground, ...}`, `{console_group, G}`), which nothing checks. Option: one request
  tag, `{erx_relay, Req}`, that the relay requires of every call, with one atom chokepoint keeping
  `erx_relay` to `erx_session_relay`, which replaces the `relay-requests` shape rule.
* [Low] session, the column after the console's rendering (`erlang/apps/erx/src/erx_tty.erl`, `rendered/3`):
  rendered output counts every byte as a column, CR and LF included, as `output/3` does with `OPOST`
  clear, so after the line editor's redraw the tty's column is not 0. Erasing a tab typed first in a cooked
  job then backs up too few columns, `^T`'s status line starts with a newline it does not need, and `TAB3`
  expands a program's first tab to the wrong width. Option: move the column for CR, LF, BS and TAB as
  `post/2` does, bytes unchanged; what FreeBSD does with `t_column` under a clear `OPOST` is unverified.
* [Medium] session, the console's reads of the relay (`erlang/apps/erx/src/erx_console.erl`, `read_for_ask/2`):
  a process of the session's domain that sets the tty raw with `VMIN` 0 and `VTIME` 0 (an open's
  `tcsetattr` with SIGTTOU ignored) makes the console's one-byte watch ready at once and its read answer
  `{ok, <<>>}`, which `read_for_ask/2` has no clause for, so the console crashes and the line's shells
  end. Watching again would spin; the console should not watch while such a setting holds, or read
  through a mode of its own.
* [Medium] session, the console's reads of the relay (`erlang/apps/erx/src/erx_console.erl`, `reader()`):
  (1) The console-read
  cases and seeded faults the design's Verification lists beyond the seven in
  `test/erlang/erx_console_reads_tests.erl` (reads per ask, held bytes across a signal, one held set per
  group, an interrupt queued before a read, one ask through blink and interrupt, a late event) are not
  written, and the interrupt case does not pin that the group keeps its ask. (2) The ask, report, read and
  event decisions are effects in the console; a pure core returning actions would let them be tested
  without a relay. (3) After the relay gives up its name at a halt, a group's ask makes the console's call
  exit `noproc`.
* [Medium] session, terminal relay core (`erlang/apps/erx_session/src/erx_session_relay_core.erl`):
  (1) The exploration checks safety only, and its alphabets leave out close, hangup, `tcsetattr`, timers and
  output; reports are pooled across receivers.
  (2) `erx_tty:input/3` returns a room the relay core discards, since it derives the next room from the
  link; drop it from the result, or use it.
  (3) `input/3`'s per-call room and output stopped live in the persistent `#tty{}` record, reset by
  `input/3`; thread them as a call-local value.
  (4) A writer's message (`{write, Done, Bytes}`) has no size bound and the queue no length bound; with no
  master it drains only by a flush or a hangup. The writers are synchronous and in the session's own domain.
  Writers whose messages refill the room exactly as it empties hold `out` waits off for as long as they keep
  it up, since an `out` wait is reported only while no message waits.
* [Medium] session, how the console learns a session's tty (`docs/design-live.md`, "Between domains"): the design has the console learn the tty from a `tty` agent in the session domain's ready report, but the relay needs `erx:cap(console)`, which init sets only after that report, so a relay started by the boot script has no master and one started after the report is not in it. Edit 65's `tty` agent, the domain pid's check that every agent is a pid of the domain's node, and a way for the session's creator to read the agents are not built; `erx_console:add_session/2` takes the tty from whoever creates the session. Settle the order when root's session starts at boot.
* [Low] session memory, `config/manifest/development.txt`: re-measure one session at its command shell under the lane driver's frame-sized funnel scratch (at most about 132 KiB a connection) and lower the session's 36 MiB budget, the principal's memory and its `max_message_heap` of 131,072 words if the numbers allow; they were sized for a scratch of 16 bytes a word of `max_message_heap`.
* [Medium] session, `erlang/apps/erx_session/src/erx_session_sup.erl`: a restarted tty relay names itself with a new pid, which the console refuses (`tty_opened/4`), so the session is cut off from its line while its domain lives and holds the principal's one domain; make the relay's end end the session domain, or accept a new tty of the same domain once the old one is dead.
* [Medium] session, `erlang/apps/erx/src/erx_tty.erl`: `VLNEXT`, `VDISCARD` with `FLUSHO`, and `ECHOPRT` are not built. The two characters are kept and returned but act as ordinary bytes, and `FLUSHO` and `ECHOPRT` are outside the flag table, so the program protocol will drop them. `VLNEXT` needs a quoted mark on each held byte, as FreeBSD's input queue keeps (`sys/kern/tty_ttydisc.c:1072-1083`).
* [Medium] session, `erlang/apps/erx/src/erx_tty.erl`: a raw read's readiness ignores the reader's size. FreeBSD's read returns once its buffer is full, before `VMIN` bytes (`tty_ttydisc.c:290`), but `read_wait/2` has no size, so a read of fewer than `VMIN` bytes waits for `VMIN`. Carry the size in liberx's `{watch, Open, [read]}`.
* [Medium] session, `test/erlang/erx_tty_tests.erl`: the line discipline is checked against its own reference only; the differential run against a host pseudo-terminal with the same `termios` (`docs/design-live.md`, "Verification and testing", "The line discipline") is not built.
* [Low] session, `erlang/apps/erx/src/erx_tty.erl`: erasing a UTF-8 character backs over one column, where FreeBSD measures it with `teken_wcwidth` and backs over two for a double-width character (`tty_ttydisc.c:889-962`).
* [Medium] session, `erlang/apps/erx/src/erx_tty.erl`: waiters are keyed by open, so a blocking read and a `poll` of one open replace each other and the read loses its `VMIN`/`VTIME` timer. Key a wait by a handle (`{Open, read}`, `{Open, poll}`) before the terminal relay lets two threads wait on one open.
* [Medium] session, `erlang/apps/erx/src/erx_tty.erl`: `set/2` re-arms every waiting read's timer and forgets which reads timed out, even when `VMIN`, `VTIME` and `ICANON` did not change, so frequent `tcsetattr` calls keep a timed read of another open waiting, where FreeBSD fixes the deadline at the read's start (`sys/kern/tty_ttydisc.c:314-318`). Re-arm only on a change, and keep the expiry in the waiter's own state.
* [Medium] session, `erlang/apps/erx/src/erx_tty.erl`: `?VDISABLE` (0xff) and `?MAX_SPEED` restate
  `abi/termios.txt`'s `UNNAMED` byte and the codec's 32-bit word, which musl's generated `bits/vdisable.h`
  and `erx_abi_termios` take from the table; a changed `UNNAMED` would leave a byte that C programs think
  disabled live in the tty. Export them from `erx_abi_termios` and use them in `erx_tty`.
* [Medium] session, `erlang/apps/erx/src/erx_tty.erl`: no flush of held input or output, which `tcflush`, `TCSAFLUSH` (`readpassphrase`) and FreeBSD's flush on last close (`tty.c:1768-1773`, `tty_ttydisc.c:104-108`) need; add `flush/2` and name it in design-live.md ("The tty"). `TOSTOP` is in the flag table, but design-programs.md has a first-tier `tcsetattr` with it fail with `EINVAL`; the relay must refuse it until the second tier.
* [Medium] session, `test/erlang/erx_tty_tests.erl`: the exploration checks what readers get, not what is echoed or sent to the master (caret notation, erase widths, reprint, the output flags and the column), its only `set` event flips `ICANON`, and the seeded faults design-live.md names for the timers and the bound (a `read_wait` that starts no timer, a `poll` that starts one, the bound removed) and for stale timers and lost wakeups are not planted. The flag tables are written out again in the test and the fuzz target; export them from `erx_tty` or generate all three from the program protocol's termios table.
* [Low] session, `erlang/apps/erx/src/erx_tty.erl`: a full raw queue switched to cooked holds no line end and takes none, so reads get `eagain` until a signal flushes it; FreeBSD's cooked read takes a partial canonicalized line (`tty_ttydisc.c:236-256`). `read/3`, `input/3`, `output/3` and `status/3` crash on a non-integer or negative size where `set/2` and `size/3` return `einval`, so the relay checks those arguments.
* [Medium] session, `erlang/apps/erx_session/src/erx_session_tty.erl`: a restarted console tty of a session (it is
  `transient` under `erx_session_sup`) takes the `user` its predecessor started, since its config leaves `user` at
  `take` (erx_console:start_user/1); that group ends at its dead driver's exit, after which the session domain has
  no `user` and nothing restarts the console. Session domains run `-nouser`, so nothing but the console registers
  `user` there: pass `user => replace`, as the system console's start_link/0 does, with a session QEMU case that
  kills the console tty. While the session has no `user`, the groups of its other ttys (erx_session_tty:open/1),
  which hold none of their own, fail at their next prompt, since `shell:prompt_width/1` asks `user` for its encoding.
* [Medium] session and console, `otp/lib/stdlib/src/shell.erl` `prompt_width/1` (called from `group` and from
  `prim_tty` inside a session console): every session console asks `io:getopts(user)` for its encoding, since none is
  registered as `erx_console`, the one exception. On the line's own console that asks its own `user` group, which asks
  the busy console back and times out after 2 s, so `getopts` returns an error that `proplists:get_value/3` crashes on;
  on a terminal's tty it waits on the line's console, and fails once the line has hung up or crashed. Have both call
  sites pass their own encoding to `prompt_width/2` (`prim_tty` holds `unicode`, `group` its `encoding`), extending edit
  44 of design-runtime.md; then no session console needs `user`, and `user => none` (erx_console.erl) can go.
* [Medium] session lines, a tty's ending from its relay (`erlang/apps/erx_tty_line/src/erx_tty_line.erl`,
  `erlang/apps/erx_session/src/erx_session_relay.erl`; [design-system.md](design-system.md#a-sessions-lines)):
  each line is minted as a facet, but the SSH line still sends a channel its tty's ending itself, which exports
  the line process to the SSH domain beside its facet. The tty's console hands its ending to the tty's relay
  (`erx_console`'s `on_shell_end`, `erx_session_tty:open_channel/3`), which sends it to the channel as its last
  message, as `erx_ssh_dev_channel` then takes it, and `erx_tty_line` sends a front end nothing; its `Notify`
  and its `{erx_tty_line, ended, Tty, Ending}` report go. The design's "no door beside the facet" test, row 7
  of its tests table, lands with it, with its seeded fault, the line process sending a tty's ending itself.
* [Medium] session lines, a line for the system domain (`erlang/apps/erx_domain/src/erx_domain_mints.erl`,
  `request_line`, `start_line`, `live_peer/2`; [design-system.md](design-system.md#a-sessions-lines), the answers
  table): the design answers `erx_domain:line/4` for the system domain as peer `{error, refused}`, but the mint core
  sends the line a mint request at once, which the line drops (`erx_session_line`, `Grantee =/= System`), so the
  caller waits out the 10 s deadline and gets `unavailable`. No caller asks for it. Refuse it in `request_line` and
  delete the core's system-peer branches, with a case in the core's tests.
* [Low] session lines, a forward from an ended facet (`erlang/apps/erx/src/erx_session_line.erl`, the forward
  clause of `line/4`; `erx_web_line:view_init/1`): a forward the old facet sent before a replacement or the host's
  close still reaches `request/4`, so a web view it starts sends one record to the old grantee's caller before it
  takes its facet's `'DOWN'`, and a stale `open_tty` opens a tty whose reply is lost. Match the held facet in
  the forward clause, so only its forwards are served, and change the design's replacement row with it.
* [Low] web line, calls of the session's own ([design-system.md](design-system.md#a-sessions-lines), "Calls of the
  session's own"; `erlang/apps/erx_web_line/src/erx_web_line.erl`): the design has session processes call the line
  directly, but the line serves no local call, which reaches `info/2` and is dropped. Nothing calls it yet; the
  browser renderer adds the clause, or the design says the session reaches the line by messages.
* [Medium] SSH, how a job's messages reach their job ([design-ssh.md](design-ssh.md#risks-and-open-questions)):
  the channel's `job_input`, `job_eof`, `job_sent` and `job_hangup` name no job, and through the line's facet they
  would arrive by `message/2`, which names the grantee and not the sender and is dropped once `in_flight` forwards
  are outstanding, so a lost `job_eof`, `job_hangup` or `job_sent` would leave a job stuck. `open_job`'s design
  settles routing and delivery together, by the open question's two ways: the job's relay handed to the channel
  as the endpoint (recommended), or the channel's alias for the job as its key through the facet, bound to the
  admitted grantee and a live job, with an admission that never drops them. `open_job` and the four messages stay
  out of `tty_line`'s interface until then.

## Security residuals

* [Low] SSH, root's login keys on the medium (development builds, before the vault;
  [design-ssh.md](design-ssh.md#roots-login-keys-on-the-medium)): the keys are as sound as the
  storage domain that reads `authorized_keys` and serves them as `login_keys`, and that domain serves
  `system` to every domain and `data` to every principal, so a flaw in it that a client's requests could steer would be a way to
  root's login. A storage domain whose only client is the system domain, as the vault's is, would
  close it; the vault's arrival, after which the file is not read, closes it too.
* [Medium] SSH, the browser demo's manifest ([design-ssh.md](design-ssh.md#roots-login-keys-on-the-medium)):
  `config/platforms/qemu-virt.json:10`'s `site_leaves_out` gains `ssh` in the same change that puts the SSH
  domain into the development manifest, or the demo's image holds a domain that no one can give a key.
  The same change (P7, the SSH domain's package) takes the `record_volume` window, the `login_keys`
  service and the system domain's `login_keys` facet out of the site manifest
  (`Erx::Platform#site_manifest_source`), which holds them because it derives from QEMU virt's
  development manifest, although design-ssh.md's browser-demo bullet and its "each product's SSH domain" test
  row say the demo holds no `record_volume` window. Until then they are inert there: the demo's
  storage domain reads a medium with no `authorized_keys`, so `login_keys` serves an empty `root`, and no
  SSH domain reads it.
* [Medium] SSH, release builds and the record volume ([design-ssh.md](design-ssh.md#roots-login-keys-on-the-medium),
  the test row "release builds refuse the development key"): the manifest check does not yet refuse a
  release-kind manifest that holds a `record_volume` window, since `Check#check_mode`
  (`tools/lib/erx/manifest.rb`) refuses every manifest that is not of the development kind. When
  `check_mode` accepts release manifests, the release check refuses the window, with its seeded test
  (the release check skipping the `record_volume` row: the manifest with the window passes).
* [Medium] session, a window's terminal relay (`erlang/apps/erx_session/src/erx_session_relay.erl`,
  `handle_info/2`): a relay whose master is in the session's own domain takes every plain message it
  does not otherwise know as its master's, and its pid travels in every open, so any process of the
  domain that holds an open can send it master messages (input, a hangup, a size). Acceptable for Phase
  1's trusted domains. Fix: the relay names the reference of its monitor of the master in its `tty_open`,
  and the master tags each message with it, which the relay requires.
* [Medium] SSH before the vault, stages 2 and 3, development builds only
  ([design-ssh.md](design-ssh.md#login-keys)): the login facet's
  `login_key` checks the signature itself but compares no host key, and
  the host key is the file `/data/ssh/ssh_host_ed25519_key`, which the SSH
  domain reaches through `ssh_state` and whoever reads the data partition
  reads. So whoever takes the key poses as this machine to clients, and a
  compromised SSH domain logs in as root whenever a client holding one of
  root's keys completes an exchange with it, under any host key that
  client accepts. Stage 4 closes both, with the vault's host key and the
  facet's comparison of it.
* [Medium] ssh, a channel's window and packet
  ([design-ssh.md](design-ssh.md#risks-and-open-questions),
  `otp/lib/ssh/src/ssh_connection.erl`): OTP sets a channel's window from
  the socket's receive buffer and its packet at most 64 KiB, with no
  option, so the SSH domain's 64 KiB and 32 KiB
  ([Limits and who pays](design-ssh.md#limits-and-who-pays)) need a
  daemon option in OTP's ssh for the window and packet a channel offers
  before its worst case is the one that table counts.
* [Low] SSH, unauthenticated floods
  ([design-ssh.md](design-ssh.md#limits-and-who-pays)): OTP has no
  counterpart of FreeBSD's `MaxStartups`, so a flood of unauthenticated
  connections holds the 64 slots until their 120 s grace ends, refusing
  others. It refuses; it admits no one.
* [Low] SSH on a weak seed ([design-ssh.md](design-ssh.md#host-keys)):
  on a boot whose seed is weak, as a boot's on Fiasco is when its device
  tree carries no seed (`liberx/backend/fiasco/entropy.c` then seeds from
  the counter alone: deterministic mode, and the Raspberry Pi 4 unless its
  firmware writes one), the
  host key is as guessable as the seed, and the login facet's cookies are
  only as unique across boots as the seed, so a key login that a
  compromised SSH domain recorded opens a session again on a later boot
  whose generator repeats that cookie, as a deterministic-mode boot does.
  Release builds refuse a weak seed.

* [Low] login at a display, the enrolment gap ([design-display.md](design-display.md#risks-and-decisions), 14):
  a principal that a start row names, an app's or a person's, and that never enrolled can be enrolled by whoever
  first reaches a secure console line, as any principal can, and then logged in to with its authority. Settle it in
  the login design, which covers every place a person meets the system.
- [Low] program channel on Fiasco (`liberx/backend/fiasco/object.c`): a program can map the session's lane side read-write, the High item on rights per handle above. It can bind or unbind only IRQ objects it holds in its own group: it holds no handle to its channel doorbell, and `irq_group_allowed` refuses the session's doorbell, which is also the gate worker's IRQ for the program's port. A program also holds `TRIGGER` copies of its own pipe ends' doorbells, bound in its own group, and can rebind them to any label, label 1 included; that costs it only its own wakes. That any task can fill the machine-wide 256 IRQ objects is the High per-domain limits item of "0.2 on Fiasco". erXos's kernel enforces the rights the install grants (`erx_program_core.c` `install_rights`).

* [Medium] Session tty input (erx_session_tty, erx_tty_link): each `{tty_input, Bytes}` is checked at 4 KiB, but what waits unread in the shell's group has no bound; a master that types faster than the session reads grows the session's heap. erx_tty's `input/3` bound (docs/design-live.md, "Between domains") closes it when the line discipline lands.

## Planned features

* [Low] login, the parked facet ([design-login.md](design-login.md#risks-and-open-decisions), 1): when the
  login design resumes, give erx_login the vault's checker as its `checker` and grant the facet to its
  front ends; until then no manifest grants it and login by passphrase answers `unavailable`.
* [Medium] SSH, stage 2's source of root's keys ([design-ssh.md](design-ssh.md#roots-login-keys-on-the-medium)):
  stage 1 reads root's home copy, `/root/.ssh/authorized_keys`, imported from `login_keys`, while the design's
  stage 2 facet reads `login_keys` from the record volume. The direction is that 0.2's storage domain serves
  `login_keys` from the home copy, so the SSH domain admits what stage 1 admits; that needs a design: which
  domain reads the home copy under which facet, where the first-boot import then reads the medium, and the
  manifest check's binding of `login_keys` to the `record_volume` holder.
* [Medium] SSH, the QEMU test of a downloadable medium ([design-ssh.md](design-ssh.md#the-ssh-domain)):
  `MediumBoot` packs its medium from `site_manifest_source` (`tools/lib/erx/medium_boot.rb:499`,
  `tools/lib/erx/bench_g5.rb:82`), the browser demo's manifest, which leaves the SSH domain out, so no harness
  boots the QEMU release medium the website offers. The test needs `MediumBoot` to take its manifest from the
  caller, the published medium of the development manifest for that test and
  `site_manifest_source` for the medium suite and G5 as now.
* [Medium] vault, the TPM 2.0 client: choose between tpm2-tss as a NIF, a
  small C client, and a client of erXos's own with Erlang framing and the
  session cryptography in the vault's NIF; the design recommends the last,
  behind `erx_seal`
  ([design-system.md](design-system.md#risks-and-open-questions)).
* [Low] vault, anchoring under `tpm`: a TPM NV counter that versions the
  machine's file and the set of enrolled principals, so a deleted or
  rolled-back principal file reads as tampering; needs a recovery path for
  a tampered medium
  ([design-system.md](design-system.md#risks-and-open-questions)).
* [Medium] vault, credential slots: FIDO2 slots through `hmac-secret`
  and recovery-code slots, beside the passphrase slot, each wrapping the
  principal's master key ([design-system.md](design-system.md)). A
  recovery slot needs its own policy, since its protection can become the
  easiest route to the master key.
* [Medium] SSH from `tools/erx boot`
  ([design-ssh.md](design-ssh.md#stages),
  `tools/lib/erx/interactive_boot.rb`): the interactive boot gives the
  guest no network device and its image no login key, so `tools/erx ssh`
  reaches nothing there; only the network domain's QEMU case logs in. It
  needs a network device with a host forward from loopback port
  `DevKey::PORT` to the guest's daemon, the key in its image, and with
  them a refusal by construction of the key in the images the website
  offers, beside the chokepoint check `Checks::LOGIN_KEY_BUILDERS`:
  `ProductionImage` refusing `login_key` together with
  `ProductionImage::Machine.site`.
* [Low] SSH stage 1, the port (`tools/lib/erx/dev_key.rb`,
  `erlang/apps/erx_session/src/erx_ssh_dev.erl`): `DevKey::PORT` is a
  Ruby constant while the guest's port is the argument of the development
  manifest's `-eval ok=erx_ssh_dev:boot(2222)` for root's session, so the
  two agree only by being written alike. A constant of `abi/erx_abi.txt` that both read would make them one
  fact.
* [Medium] SSH stage 2, root's session's grant of `login_keys`
  (`config/manifest/development.txt`, `facet login_keys_session`;
  `tools/lib/erx/manifest.rb`, `WELL_KNOWN`'s `login_keys_service` row;
  [design-ssh.md](design-ssh.md#invariants) H8): stage 1's daemon
  reads the card's keys through a read-only grant to root's session
  template, which the check accepts beside the system domain's. When the
  SSH domain lands, remove the grant and narrow the check back to the
  system domain alone, as 0.1's known limitations say.
* [Medium] SSH stage 2, port 22 ([design-ssh.md](design-ssh.md#stages),
  `tools/lib/erx/manifest.rb`, `check_net_ports`): stage 1 listens on
  2222, since a privileged port is only a configured domain's; the SSH
  domain takes port 22.
* [Low] SSH, the browser demo's record volume
  (`tools/lib/erx/platform.rb`, `site_manifest_source`;
  [design-ssh.md](design-ssh.md#roots-login-keys-on-the-medium)):
  the design says the demo's manifest holds no `record_volume` window,
  but qemu-virt's site manifest leaves out only web and display, so it
  keeps the window, `login_keys` and both its grants. Harmless, since
  the demo's medium holds no `authorized_keys`; the site manifest should
  drop the window as the design says.
* [Low] SSH stage 1, one lookup of root's session template
  (`tools/lib/erx/manifest.rb`, `root_template?` and
  `planned_sessions`): both find the system principal's template by
  the same predicate, and the check resolves the system principal from
  the source again though the header holds it; one helper would serve
  both.
* [Low] SSH stage 1, the channel's refusal
  (`erlang/apps/erx_session/src/erx_ssh_dev_channel.erl`, `refuse/2`): it
  decides that a request wants a reply by the tuple's shape (an integer
  second element and a boolean third) instead of matching the request
  shapes OTP's `ssh_connection` delivers, so a request of another shape is
  silently ignored.
* [Low] SSH stage 1, empty output
  (`erlang/apps/erx_session/src/erx_ssh_dev_channel.erl`, `tty_output`):
  an empty piece of the tty's output is sent as a zero-length channel
  data message instead of being skipped.
* [Low] SSH stage 1, channels per connection
  (`erlang/apps/erx_session/src/erx_ssh_dev.erl`, `daemon/2`): the daemon
  sets no `max_channels`, so one admitted connection can open a tty per
  channel without bound.
* [Low] SSH stage 1, the card read untested
  (`erlang/apps/erx_session/src/erx_ssh_dev.erl`, `medium_file/0`): the
  host tests give the key callback a stand-in for the read of
  `login_keys`; the read through `erx:cap(login_keys)` and
  `erx_file_remote` runs in no test. A QEMU case whose medium holds
  `authorized_keys` on its record volume, logging in with that key, would
  run it.
* [Low] SSH stage 1, signals
  (`erlang/apps/erx_session/src/erx_ssh_dev_channel.erl`, `ending/3`): the
  tty's ending maps to SSH's signal names by one clause for `sigint`,
  while `erx_console:shell_ending/1` reports `{signaled, S}` for every
  member of the generated `ERX_TTY_MASTER_SIGNAL_MEMBERS`. That set
  (`abi/signals.txt`, `signal_set tty_master`) holds only `int`, so a
  signal added to it would crash the channel; the name should come from
  that table.
* [Low] SSH stage 1, the tty relay's messages
  (`erlang/apps/erx_session/src/erx_ssh_dev_channel.erl`): `tty_output`
  and `tty_open` from the tty's relay arrive untagged; tag them as the
  job's messages are.
* [Low] SSH stage 1, `erlang/apps/erx_session/src/erx_session.app.src`
  does not list `erx_tty_line`, whose modules `erx_session` calls.
* [Low] SSH stage 1, the channel's names
  (`erlang/apps/erx_session/src/erx_ssh_dev_channel.erl`): rename
  `#state.input`, `job/2` and `erx_ssh_job_core`'s `job` key, and give
  `channel_step/2`'s ending its own place in its result rather than
  relying on it coming last.
* [Low] SSH stage 1, the funnel's tests
  (`test/erlang/erx_ssh_dev_tests.erl`): the forged events should also
  name the real connection with another channel, and another connection
  with the real channel, so that dropping either check fails a case.
* [Low] SSH, the job relay's sends
  (`erlang/apps/erx_tty_line/src/erx_ssh_job.erl`): a relay sending to a
  channel of the SSH domain can be suspended by a busy queue to that
  domain ([design-domains.md](design-domains.md#the-peer)); send with
  `nosuspend` or state the wait in design-ssh.md.
* [Low] SSH, output requests as bytes
  (`erlang/apps/erx_tty_line/src/erx_ssh_job.erl`,
  `erlang/apps/erx/src/erx_log_user.erl`): both turn an io output
  request into bytes; one module should do it for both.
* [Low] ssh edits, the manual window (`otp/lib/ssh/src/ssh_client_channel.erl`,
  `manual_window/1`): no test pins that a callback without `window/0`
  has its window reopened past the first window; seed
  `auto_adjust = false` to check that such a test fails.
* [Low] `tools/erx ssh` cannot ask for a tty with a command (no `-t`);
  add one only if someone needs it.
* [Low] design-ssh.md, `tools/erx ssh`
  ([Login keys](design-ssh.md#login-keys)):
  the passage speaks only of the session with a pseudo-terminal; a
  clause on an exec without a tty, whose output and error output reach
  the operator's terminal unchanged as `ssh`'s do, would complete it.
* [Low] SSH stage 1, the chokepoint on login keys
  (`tools/lib/erx/checks.rb`, `LOGIN_KEY_ENTRY`): the check matches the
  keyword `login_key:` only, so `:login_key => key` or a splatted hash
  passes it. Match any use of the identifier outside the definer and the
  listed builders, with a test of the hash-rocket form, until
  `ProductionImage` refuses the key by construction (the item above on
  SSH from `tools/erx boot`).
* [Medium] SSH, SFTP ([design-ssh.md](design-ssh.md#sftp)): both stages
  refuse the `sftp` subsystem, so OpenSSH's default `scp` fails. Not built:
  the `subsystems` option naming `sftp`, `Run = sftp` on the job relay,
  `erx_sftp_server`, the `ssh_xfer` and `ssh_sftpd` stream edits, and the
  fuzz target of the server's stream.
* [Medium] SSH, stage 1's `shell` without a `pty-req`
  (`erlang/apps/erx_session/src/erx_ssh_dev_channel.erl`): it opens a tty
  of 24 by 80, `vt100`, where design-ssh.md
  ([Sessions, ttys and shells](design-ssh.md#sessions-ttys-and-shells),
  `Run`'s `shell`) runs `rc` on standard input as a job, as OpenSSH runs
  the user's shell without a tty; that needs `erx_ssh_job` to run `rc`
  without `-c`.
* [Medium] SSH, forwarding ([design-ssh.md](design-ssh.md#channel-policy)):
  the daemon refuses every forwarding request, since a forwarded
  connection would use the SSH domain's `net` grant. Design it to run in
  the principal's session, as SFTP runs, on the session's own `net` grant.
* [Low] ssh, `max_auth_tries` against FreeBSD's `MaxAuthTries`
  ([design-ssh.md](design-ssh.md#limits-and-who-pays),
  `otp/lib/ssh/src/ssh_auth.erl`, `handle_userauth_request/3`): FreeBSD's
  sshd (`crypto/openssh/auth2.c`) disconnects at 1,024 requests of any
  kind (`:290-291`) and when the user name or service changes between
  requests (`:323-328`), and counts an unoffered method sent as the first
  request; OTP's daemon does none of these, so a client that knows an
  authorized key can send `pk_ok` queries, each a `key_ok` call to the
  system domain, for the whole 120 s grace.
* [Low] ssh, a held host key's `sign/3` is not told the signature algorithm
  (`otp/lib/ssh/src/ssh_transport.erl`, `sign_with/4`): fine for Ed25519,
  the only host key erXos offers, but a held RSA key could not choose
  between `rsa-sha2-256` and `rsa-sha2-512`.
* [Medium] login, keys open only to sessions that gave the passphrase
  ([design-login.md](design-login.md#risks-and-open-decisions), 3):
  a key login's session uses the principal's vault keys while another
  session of the principal holds them open
  ([design-system.md](design-system.md#the-vault)). Opening them only
  to sessions that gave the passphrase themselves needs a per-session
  unlock in the login's row and the vault, and a way to give the
  passphrase in a session after an SSH key login.
* [Low] SSH, hardware-backed login keys
  ([design-ssh.md](design-ssh.md#risks-and-open-questions)): FIDO keys
  (`sk-ssh-ed25519@openssh.com`) are not accepted; accepting them needs
  their signed data, with its flags and counter, in the login facet's check.
* [Low] vault: key facets constrained to a destination, in the style of
  OpenSSH's restricted agent, which need authenticated session evidence;
  and a TEE backend for the sealing interface.
