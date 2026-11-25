%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_prog_handler_core).
-moduledoc """
The decisions of a program's handler (docs/design-programs.md, "The
handler"): one pure state machine, step/2, from an event to the next
state and the actions erx_prog_handler performs, in order.

A handler lives through four phases:

* **resolving**, step 4 of "Starting a program", for a start whose image
  is an absolute path, an executable file: the image is resolved through
  the starter's namespace (resolve_image/3) before the holder entry or
  any descriptor is reserved, so a refusal has nothing to undo, though
  the command server has already given the program its id and job row
  (TODO.md). A file it resolves is refused
  `enotsup`, since the filler that opens it, the code object and the loader
  `erx_exec` are not built (TODO.md). A release image, `bin/NAME`, starts
  reserving at once.
* **reserving**, steps 5 and 6: the program's holder entry, then each
  descriptor the starter named, one at a time in the order given (a
  pipe end as an `inherit` with the starter as the end's holder, a
  window's buffer as an allocation and a lease the handler holds), then,
  for a spec that names a window, the window, its draw connection and the program's own `/dev` tree as one `window`
  action, whose grant the core puts at `/dev` in the program's table
  (docs/design-files.md, "A program's window"), then the start itself.
  What the `window` action made needs no undo: it ends with the
  handler. Any refusal undoes everything
  reserved, without knowing how far the start went: every hand-off is
  dropped and the lease given back, both of which do nothing to what the
  start took (docs/design-pipes.md, "Hand-offs", Giving back), and the
  holder entry is let go, so the pipe server reads the program's gone.
* **running**: the handler alone sends to the program. Reports from the
  pipe server, and those that arrived while the program was being built,
  queue in arrival order behind the startup message; the head of the
  queue is sent, or for a hand-off installed first and then sent with the
  values the install gave. A send the driver answers `busy` stays at the
  head, owed, until the program frees room, so nothing newer passes it.
  The program's notices go to the pipe server as events naming the
  program. Its requests are answered on their own reply slots, each
  reply queued like a report, so it reaches the program after every
  frame queued before it (Requests, below).
* **ended**, `{ended, Reason}`, with the reason the handler exits with,
  so a handler that reaches the end cannot stay: `normal` for a refused
  start, once the refusal is answered; `{shutdown, {program_exit,
  Status}}` once the program's exit status reached the handler, `Status`
  as erx_prog:status/1 reads it, the reason its starter reads in the
  `'DOWN'` of its monitor; or `program_lost` for a port closed with no
  status, which tells no status the handler did not read.

A stop, asked by the starter or forced by its exit, stops the program's
anchor with `ERX_EXIT_SIGNAL + SIGKILL`, a stop by its session, and the
handler then waits for the exit status like any other end. So a session
process's programs never outlive it, as a program's children never
outlive their parent (docs/design-programs.md, "A program's end").

Every frame from the program passes the program protocol's grammar
(erx_prog_grammar:check_from_program/1) before anything reads it. The
driver delivers only records that decode, within the program's credit,
so at most one request is outstanding on each slot, but it does not judge
their form: a frame the grammar refuses stops the program with
`ERX_EXIT_SIGNAL + SIGSYS`, as the driver stops one for a malformed
record, and the handler carries on until the program's end.

**Requests** (docs/design-programs.md, "The program protocol"). A
`{kill, Target, Signal}` and a `{probe, Target}` reach the processes the
handler's policy lets the program reach: its own children, itself, and
the processes its `signal` right names. This handler keeps no child
record and its program holds no `signal` right, so a program reaches
itself alone, and every other target is `esrch`, whether or not it
exists, so a kill or a probe tells the program nothing of processes
beyond its reach. A probe of itself is `ok`. A kill of itself with
`sigkill` stops the program as a stop does and answers `ok`; with a stop
or continue signal, which belong to the session's job control, it is
`eperm`; with any other signal it is `enosys`, since the protocol has no
report that carries a signal to a program (TODO.md), and a kill answered
`ok` must have signaled.

**Files** (docs/design-programs.md, "Descriptors and files"). The core
holds the program's namespace, narrowed from its starter's
(docs/design-files.md, "Narrowing for a program"), its working directory,
its open table, from each open to the open-file description that serves
it, and its pending file requests by reply slot. A request is relayed as
an action and its answer comes back as an event, so the handler goes on
taking the program's other frames, a kill included, while a file request
waits. An `lopen` or `lcreate` with a flag bit outside 9P2000.L's open
flags, or the access mode 3, is `einval`, and so is an `lcreate` with
`O_EXCL` and `O_DIRECTORY`; one past `ERX_PROG_FDS_MAX` opens, those
pending included, is `emfile`; otherwise it is resolved and opened over
the narrowed namespace alone, and its answer is a new open. An `lcreate`
with `O_DIRECTORY` creates nothing: it is resolved as an `lopen`, as
FreeBSD's `vn_open_cred` looks up `O_CREAT | O_DIRECTORY`.
A `read`, `pread`, `write`, `pwrite`, `seek`, `getattr` or `clunk` of an open not in
the table is `ebadf`, and a data slot past the program's slots is `einval`.
A `pread` or `pwrite` names its own offset and a `seek` moves the
description's, which the description does through file:position/2. A
read's answer longer than the request's count is `eio` and is never copied; otherwise its
bytes are copied into the slot, and the copy's answer is the reply's. A `getattr`'s
reply holds the attributes the file's server gave and no other (stat/1),
and is `eoverflow` when one lies past what the protocol carries. A `clunk` takes the open
out of the table at once, and its description closes after the requests
it holds. An error the protocol has no name for is `eio`.

A `{pipe, Flags}` makes a pipe whose two ends the program holds
(docs/design-pipes.md, "Making a pipe"): the pipe server makes it, with
`Flags` as the program gave them, and answers each end as a hand-off; the
handler has the driver install the read end's, then the write end's, and
replies `{ok, Read, Write}` with the values the installs gave. A refusal
undoes what came before it: the pipe server's refusal is the reply, and an
install the driver refuses drops the hand-off not yet installed and tells
the pipe server that both ends are closed, so their objects close and the
quota is free again; the copies of an end installed before the refusal,
which the program is never told of, stay in its table until it ends
(TODO.md). The reply is the pipe server's `enfile` at the session's quota,
and `enomem` for every other refusal: a full capability table refuses the
driver's pass, which stops the program, so `emfile` comes only from
`liberx`'s own descriptor table.

**A window at the first open of `/dev/draw`** (docs/design-programs.md,
"The handler"). A program started with neither a window nor a buffer gets
a window when it opens `/dev/draw` and its table resolves that open to the
shared `/dev`, which holds no `draw`: the open's path, read from the
working directory, is `/dev/draw` with no `..`, and no entry of the table
stands at `/dev` or below it on the way to `draw`. An entry at `/dev`,
whatever its provider (a grant the session mounts there, or a windowed
parent's own `/dev`), takes the open, as it takes every name the export
does not serve. A table a window start would refuse (refusal/2: `EINVAL`
for an entry at or below one of the window's names, or no room for its
`/dev` entry) refuses the open and keeps nothing. Otherwise the action
`{first_window, Named}`, `Named` the program's `display` variable or
`none`, has the effect side choose the display (display/2) and open the
window as for `window => Display`. Its
answer comes back within the same step, so every frame the program sent
meanwhile waits in the handler's mailbox and then meets the new tree. A
display the session does not hold answers the open `ENODEV` and keeps
nothing, and a later open tries again. A window opened puts the program's
own `/dev` in its table and relays the open there; it is the one window,
since the table then resolves `/dev/draw` to that tree. A failure once the
opening began ends the handler `{shutdown, {window, Errno}}`, and the
program with it, so the window, its buffer, the connection and the tree go
back through their owner's end.

Every other event the core does not expect in its phase leaves the state
as it was and does nothing: the handler's mailbox is reached only by
session code and the program's own driver.
""".

-include("generated/erx_abi.hrl").
-include_lib("kernel/include/file.hrl").

-export([new/3, step/2, phase/1, exported/0, exported/1, resolve_image/3, display/2]).
-export_type([core/0, event/0, action/0, starter_fd/0, files/0]).

%% A descriptor as the starter names it: a pipe end the starter holds, or a
%% window's buffer of Bytes in the area of the display domain Peer, which
%% the handler allocates and lends to the program (docs/design-display.md,
%% "The pixel area": a buffer mapped into a program belongs to its handler).
-type starter_fd() :: {0..1023, {pipe, term()} | {buffer, pos_integer(), pos_integer()}}.
%% A descriptor as erx_program:start/1 takes it.
-type program_fd() :: {0..1023, {pipe_hand, pos_integer(), term()} | {mem, pos_integer(), pos_integer()}}.

-type event() :: {resolved, {ok, erx_path:entry(), [erx_path:name()]} | {error, atom()}}
               | {holder, ok | {error, atom()}}
               | {reserved, {pipe_hand, pos_integer(), term()}}
               | {reserved, {mem, Lease :: pos_integer(), Pages :: pos_integer(), Offset :: non_neg_integer()}}
               | {windowed, DevGrant :: pid()}
               | {refused, atom()}
               | started
               | {report, term()}
               | {frame, term()}
               | {sent, ok | busy | {error, atom()}}
               | {installed, term()}
               | {install_refused, atom()}
               | {pipe_made, {ok, hand(), hand()} | {error, atom()}}
               | {end_installed, term()}
               | {end_refused, atom()}
               | room
               | pipes_lost
               | stop
               | {signal, atom()}
               | {exit_status, integer()}
               | port_closed
               | {file_opened, slot(), {ok, description()} | {error, atom()}}
               | {file_done, slot(), {ok, binary()} | eof | ok | {error, atom()}}
               | {file_copied, slot(), ok | {error, atom()}}
               | {first_window, {ok, DevGrant :: pid()} | {error, enodev} | {failed, atom()}}
               | ignored.

%% What the starter hands for the program's files: its namespace table
%% (prim_file:erx_mounts/0), the narrowing, `all` for the whole table or each
%% absolute path the program reaches with its rights there, the program's
%% working directory, its data area's slots, for a program with a window,
%% the display it is opened on, the name of the session's grant of it, the
%% program's image as the spec names it, which is resolved through the table when
%% it is an absolute path, and the program's `display` variable, when it has one.
-type files() :: #{table := erx_path:table(), within := all | [{binary(), erx_abi_enums:files_rights()}],
                   cwd := binary(), slots := 1..?ERX_PROG_DATA_SLOTS_MAX, window => atom(),
                   image => term(), display => binary()}.
-type slot() :: non_neg_integer().
%% An open-file description, a session process the effect side made.
-type description() :: pid().
%% A pending file request: the reply case it answers, and for a read or a
%% write its count, and for a read the data slot its bytes go to.
%% A read's answer is copied into its data slot (copy), then answered with
%% the count copied (copied); a write's is answered with its count (count).
-type pending() :: file_lopen | file_lcreate | file_clunk | file_getattr | local_seek
                 | {copy, file_read | file_pread, pos_integer(), slot()}
                 | {copied, file_read | file_pread, non_neg_integer()}
                 | {count, file_write | file_pwrite, pos_integer()}.

-type action() :: {resolve, binary(), erx_path:table()}
                | holder
                | {inherit, term()}
                | {lend, pos_integer(), pos_integer()}
                | {window, atom()}
                | {first_window, none | binary()}
                | {start, [program_fd()]}
                | {answer, {ok, [{0..1023, non_neg_integer()}]} | {error, atom()}}
                | {hand_drop, pos_integer()}
                | {unlend, pos_integer()}
                | holder_drop
                | {send, term()}
                | {install, hand()}
                | {make_pipe, [cloexec | nonblock]}
                | {install_end, hand()}
                | {forward, tuple()}
                | {end_program, non_neg_integer()}
                | {open, slot(), binary(), non_neg_integer(), none | non_neg_integer(),
                   erx_path:table(), erx_path:place()}
                | {read, description(), slot(), pos_integer()}
                | {pread, description(), slot(), non_neg_integer(), pos_integer()}
                | {write, description(), slot(), slot(), pos_integer()}
                | {pwrite, description(), slot(), slot(), non_neg_integer(), pos_integer()}
                | {seek, description(), slot(), integer(), bof | cur | eof}
                | {getattr, description(), slot()}
                | {copy_in, slot(), slot(), binary()}
                | {clunk, description(), slot()}.

%% The reason the handler exits with once it has ended.
-type reason() :: normal | program_lost | {shutdown, {program_exit, erx_prog:status()}}
                | {shutdown, {window, atom()}}.

%% What waits to reach the program, oldest first: a frame to send, or a
%% hand-off to install, whose filled report is then sent.
-type outgoing() :: {frame, term()} | {hand, hand()}.
%% A hand-off the pipe server made, for the driver to install.
-type hand() :: {pipe_hand, pos_integer(), term()}.

-record(core, {pid :: pos_integer(),
               phase = reserving :: resolving | reserving | running | {ended, reason()},
               %% reserving: the starter's descriptors not yet reserved, in order.
               todo = [] :: [starter_fd()],
               %% reserving: the reserved descriptors, newest first, for the start
               %% and for the undo of a refusal.
               made = [] :: [program_fd()],
               %% reserving: each buffer's offset in its area, for the starter.
               offsets = [] :: [{0..1023, non_neg_integer()}],
               %% reserving: the display the program's window is still to be
               %% opened on, or none.
               window = none :: none | {window, atom()},
               %% running: whether an open of /dev/draw opens the program's window,
               %% for one started with neither a window nor a buffer that has none
               %% yet: {first, Named}, Named its display variable or none; or the
               %% open whose window is being opened.
               first = never :: never | {first, none | binary()}
                              | {opening, slot(), file_lopen | file_lcreate, binary(), non_neg_integer(),
                                 none | non_neg_integer(), none | binary()},
               queue = queue:new() :: queue:queue(outgoing()),
               %% The head of the queue is out: sent and not yet answered, or
               %% answered busy and owed until the program frees room; or a
               %% frame was lost, and nothing more is sent to the program.
               out = false :: false | sending | owed | lost,
               %% A stop was asked once; a second asks nothing more.
               stopping = false :: boolean(),
               %% The program's narrowed namespace and working directory.
               table = [] :: erx_path:table(),
               cwd = [] :: erx_path:place(),
               slots = 1 :: 1..?ERX_PROG_DATA_SLOTS_MAX,
               opens = #{} :: #{0..65535 => description()},
               pending = #{} :: #{slot() => pending()},
               %% running: the pipe a request is making, from the request to
               %% its reply, all within the steps of one event: the request's
               %% slot, the hand-offs still to install, the next first, and the
               %% values the installs gave, newest first.
               piping = none :: none | {0..15, [hand()], [term()]}}).
-opaque core() :: #core{}.

-define(IS_FD(N), (is_integer(N) andalso N >= 0 andalso N < ?ERX_PROG_FDS_MAX)).
-define(IS_POS(N), (is_integer(N) andalso N > 0)).
-define(IS_PID(P), (is_integer(P) andalso P >= ?ERX_PROG_PID_MIN andalso P =< ?ERX_PROG_PID_MAX)).
-define(IS_HAND(H), (tuple_size(H) =:= 3 andalso element(1, H) =:= pipe_hand andalso ?IS_POS(element(2, H)))).
%% A stop by the session reads as signaled SIGKILL (docs/design-programs.md,
%% "A program's end").
-define(STOP_STATUS, (?ERX_EXIT_SIGNAL + ?ERX_SIGKILL)).
%% A program whose frame the grammar refuses ends signaled SIGSYS
%% (docs/design-programs.md, "Credit").
-define(REFUSED_STATUS, (?ERX_EXIT_SIGNAL + ?ERX_SIGSYS)).
%% 9P2000.L's open flags a program may send (abi/protocols/9p.txt).
-define(OPEN_FLAGS, (?ERX_P9_O_ACCMODE bor ?ERX_P9_O_TRUNC bor ?ERX_P9_O_EXCL bor ?ERX_P9_O_APPEND
                     bor ?ERX_P9_O_SYNC bor ?ERX_P9_O_DIRECTORY bor ?ERX_P9_O_NOFOLLOW)).
-define(EXCL_DIRECTORY, (?ERX_P9_O_EXCL bor ?ERX_P9_O_DIRECTORY)).

-doc """
A handler for program `Pid` that starts it with the starter's
descriptors `Fds` and serves its files as `Files` says, and its first
action, the resolve of an image that is an absolute path or else the
holder; or `{error, einval}` for a `Pid` outside `ERX_PROG_PID_MIN` to `ERX_PROG_PID_MAX`, a descriptor
of another form, a number named twice, more than one buffer, which the
program may have only one of, a working directory that is not an
absolute path of plain names, slots outside 1..`ERX_PROG_DATA_SLOTS_MAX`,
or a narrowing path named twice or not absolute, a program's table with an
entry at or below one of the names of exported/1, a window beside a buffer,
or a window for a table at `ERX_NS_MOUNTS_MAX` entries with none at `/dev`,
which cannot take the window's `/dev`; `{error, enoent}` for a
narrowing path that no entry of the table holds; or `{error, eacces}` for
rights the starter does not hold there, or for a window whose program's
table holds an entry at `/dev` itself that cannot write.
""".
-spec new(term(), term(), files()) -> {ok, core(), [action()]} | {error, einval | enoent | eacces}.
new(Pid, Fds, #{table := Table, within := Within, cwd := Cwd, slots := Slots} = Files)
  when ?IS_PID(Pid), is_list(Fds), is_integer(Slots), Slots >= 1, Slots =< ?ERX_PROG_DATA_SLOTS_MAX,
       not is_map_key(window, Files) orelse is_atom(map_get(window, Files)),
       not is_map_key(display, Files) orelse is_binary(map_get(display, Files)) ->
    %% A display may take any name, none included, so its absence is not an atom.
    Window = case Files of
                 #{window := Display} -> {window, Display};
                 #{} -> none
             end,
    case {valid_fds(Fds) andalso drawn_once(Window, Fds), erx_path:cwd(Cwd),
          program_table(Table, Within, Window)} of
        {false, _, _} -> {error, einval};
        {_, error, _} -> {error, einval};
        {_, _, {error, _} = Refused} -> Refused;
        {true, {ok, Place}, {ok, Narrowed}} ->
            C = #core{pid = Pid, todo = Fds, window = Window, table = Narrowed, cwd = Place,
                      slots = Slots, first = first(Window, Fds, Files)},
            case Files of
                #{image := <<"/", _/binary>> = Image} ->
                    {ok, C#core{phase = resolving}, [{resolve, Image, Table}]};
                #{} ->
                    {ok, C, [holder]}
            end
    end;
new(_Pid, _Fds, _Files) ->
    {error, einval}.

-doc """
Resolve, step 4 of "Starting a program", for an executable file: the
absolute `Path` through `Table`, the starter's namespace with each
facet's grant in place (erx_facets:table/1), each provider walked by
`Walk`, erx_path's `walk` callback. It answers `{ok, Entry, Names}`: the
entry the file lies on, whose provider is the grant it is read through,
and the file's names from the provider's root, which the filler opens.
A file is what the walk answers `other`, so the filler's open checks
that it is a regular file. It answers `{error, enoent}` for no such file;
`{error, eacces}` for a directory (an entry's top and the empty root
included), for a file whose entry is not `rx`, the image check
(docs/design-programs.md, "File objects"), and for any symbolic link on
the way, which unfollowed/2 refuses; or the resolution's own error for a
path it cannot read (`enotdir`, `enametoolong`, `einval`, `eio`).
""".
-spec resolve_image(binary(), erx_path:table(),
                    fun((erx_path:entry(), [erx_path:name()]) -> erx_path:reply())) ->
          {ok, erx_path:entry(), [erx_path:name()]} | {error, atom()}.
resolve_image(<<"/", _/binary>> = Path, Table, Walk) ->
    Callbacks = #{walk => Walk, read_link => fun unfollowed/2},
    Lookup = erx_path:resolve(Path, lookup, #{follow => true, willbedir => false}, Table, [],
                              Callbacks),
    image_at(Lookup, Walk).

%% No symbolic link is followed beneath a mount, the last name's included, so a
%% package's link such as bin/x -> /bin/sh never starts a program outside the
%% package (TODO.md). The resolution follows every link it meets, so each one
%% reaches this callback and is refused here alone.
unfollowed(_Entry, _Names) -> {error, eacces}.

%% A lookup's target is walked, as an open walks it: a file there passes the
%% image check; a walk that did not pass every name goes back to the
%% resolution, which answers it, a link through unfollowed/2. An entry's top,
%% no names from the provider's root, is a directory without a walk.
image_at({target, _Entry, [], _Resume}, _Walk) ->
    {error, eacces};
image_at({target, Entry, Names, Resume}, Walk) ->
    case Walk(Entry, Names) of
        {Kinds, ok} = Reply when length(Kinds) =:= length(Names) ->
            %% The one reading of a walk's kinds that every open makes.
            case erx_file_remote:passed(Kinds, follow) andalso lists:last(Kinds) of
                other -> image_check(Entry, Names);
                directory -> {error, eacces};
                false -> image_at(Resume(Reply), Walk)
            end;
        Reply ->
            image_at(Resume(Reply), Walk)
    end;
image_at({error, _} = Refused, _Walk) ->
    Refused;
image_at({empty_root, _Place}, _Walk) ->
    {error, eacces};
image_at({top, _Entry}, _Walk) ->
    {error, eacces}.

%% The image check reads the entry alone, so it holds only where an entry's
%% rights never exceed its grant's; an rx mount of erx_ns does not yet make
%% that so, and design-files.md (F6) asks for the grant's rx as well (TODO.md,
%% "files, the app mount's rights").
image_check(#{rights := rx} = Entry, Names) -> {ok, Entry, Names};
image_check(_Entry, _Names) -> {error, eacces}.

-doc """
The names the session's export serves every program at `/dev` and `/etc`
(docs/design-programs.md, "Devices"), which erx_session_export serves and
at or below which no entry of a program's table may stand
(docs/design-files.md, "Narrowing for a program").
""".
-spec exported() -> #{dev := [binary()], etc := [binary()]}.
exported() ->
    #{dev => [<<"null">>, <<"tty">>, <<"urandom">>, <<"zero">>],
      etc => [<<"group">>, <<"passwd">>]}.

-doc """
The names exported/0 gives, for a program started without a window
(`none`), or for one with a window (`{window, Display}`): its own `/dev`
tree serves those devices and its window's names, `clipboard` among them
whether or not the session's grant on the display carries it, so no entry
of its table may stand at or below any of them (docs/design-files.md, "A
program's window").
""".
-spec exported(none | {window, atom()}) -> #{dev := [binary()], etc := [binary()]}.
exported(none) ->
    exported();
exported({window, Display}) when is_atom(Display) ->
    #{dev := Devices} = Names = exported(),
    Names#{dev := Devices ++ [<<"draw">>, <<"ctl">>, <<"kbd">>, <<"mouse">>, <<"wctl">>, <<"label">>,
                              <<"clipboard">>]}.

%% Whether the program may get a window at its first open of /dev/draw: only
%% one started with neither a window nor a buffer.
first(none, Fds, Files) ->
    case [Buffer || {_, {buffer, _, _}} = Buffer <- Fds] of
        [] -> {first, maps:get(display, Files, none)};
        [_ | _] -> never
    end;
first({window, _}, _Fds, _Files) -> never.

-doc """
The display a program's window opens on at its first open of `/dev/draw`
(docs/design-display.md, "Choosing a display"), of `Displays`, the displays
the session holds: the one its `display` variable `Named` names, or, for
`Named` `none`, the session's only display, the one it holds when it holds
exactly one; else `{error, enodev}`. A name is matched against the
displays held, so no name makes an atom.
""".
-spec display(none | binary(), [atom()]) -> {ok, atom()} | {error, enodev}.
display(none, [Display]) -> {ok, Display};
display(none, _Displays) -> {error, enodev};
display(Named, Displays) when is_binary(Named) ->
    case [Display || Display <- Displays, atom_to_binary(Display) =:= Named] of
        [Display | _] -> {ok, Display};
        [] -> {error, enodev}
    end.

%% A window and a buffer are two ways to draw, and a spec names at most one.
drawn_once(none, _Fds) -> true;
drawn_once({window, _}, Fds) -> [Buffer || {_, {buffer, _, _}} = Buffer <- Fds] =:= [].

%% The program's table (docs/design-files.md, "Narrowing for a program"):
%% the narrowed table less every entry on a window tree, which passes to no
%% program whatever its point, as a bind of one keeps its source's provider,
%% unless refusal/2 finds a reason the program cannot be started on it.
program_table(Table, Within, Window) ->
    case narrowed(Table, Within) of
        {ok, Narrowed} ->
            Kept = [Entry || Entry <- Narrowed, not on_window_tree(Entry)],
            case refusal(Window, Kept) of
                none -> {ok, Kept};
                Errno -> {error, Errno}
            end;
        {error, _} = Refused ->
            Refused
    end.

%% The first reason, in this order, that a program cannot be started on Table,
%% or none. An entry at or below one of the export's names would hide that
%% name or put a mount beneath a file. A program with a window gets its own
%% /dev in place of every entry at /dev itself once the window is open
%% (window_dev/2), so its table must have room for that entry, and the
%% entries it replaces must let it write, as writes_dev/2 says.
refusal(Window, Table) ->
    Refusals = [{hides_export(Window, Table), einval},
                {not room_for_dev(Window, Table), einval},
                {not writes_dev(Window, Table), eacces}],
    case [Errno || {true, Errno} <- Refusals] of
        [] -> none;
        [Errno | _] -> Errno
    end.

hides_export(Window, Table) ->
    Names = [[atom_to_binary(Dir), Name] || Dir := Names <- exported(Window), Name <- Names],
    Hides = fun(#{point := Point}) -> lists:any(fun(Name) -> lists:prefix(Name, Point) end, Names) end,
    lists:any(Hides, Table).

room_for_dev(none, _Table) -> true;
room_for_dev({window, _}, Table) -> length(without_dev(Table)) < ?ERX_NS_MOUNTS_MAX.

%% Whether a program with a window may write its own /dev, which is rw: every
%% entry window_dev/2 replaces must be rw, since rights only shrink and step 4
%% of "Starting" drops what it replaces (docs/design-files.md, "A program's
%% window"), so a program draws only where its starter let it write /dev.
%% With no entry at /dev itself, /dev is the export's, whose names reach every
%% program whatever its narrowing ("Narrowing for a program"), so the window's
%% /dev widens nothing; an entry above /dev, such as the release slice's
%% read-only root, does not cap it.
writes_dev(none, _Table) -> true;
writes_dev({window, _}, Table) -> lists:all(fun(Rights) -> Rights =:= rw end, dev_rights(Table)).

dev_rights(Table) -> [Rights || #{rights := Rights} <- Table -- without_dev(Table)].

%% The program's table with its own /dev tree's grant at /dev, in place of
%% every entry at /dev itself (docs/design-files.md, "A program's window").
%% Until the handler joins the export and a grant at /dev, that drops a grant
%% the session mounts there, so the program reaches fewer files, never more
%% (TODO.md).
window_dev(Table, DevGrant) ->
    without_dev(Table) ++ [#{point => [<<"dev">>], provider => {grant, DevGrant, <<"export">>},
                             root => [<<"dev">>], rights => rw}].

without_dev(Table) -> [Entry || #{point := Point} = Entry <- Table, Point =/= [<<"dev">>]].

%% An entry on a window tree names the tree in its provider, a grant's or a
%% facet's (docs/design-files.md, "Namespaces").
on_window_tree(#{provider := {Kind, _, ?ERX_WINDOWS_TREE_BYTES}})
  when Kind =:= grant; Kind =:= facet ->
    true;
on_window_tree(_Entry) -> false.

%% The starter's table narrowed: the whole table, or for each path the starter names
%% an entry at that path, on the provider of the starter's entry that holds
%% it, rooted where the path lies there, with the rights asked, the
%% starter's own there or read-only; and each of the starter's entries
%% below the path, read-only when read-only was asked, so the program sees
%% at every path below it what the starter sees. Nothing above a narrowed
%% path stays, so the paths above it read as the empty root.
narrowed(Table, all) ->
    {ok, Table};
narrowed(Table, Within) when is_list(Within) ->
    Groups = [narrowed_entries(Table, Path) || Path <- Within],
    Entries = lists:append([Group || Group <- Groups, is_list(Group)]),
    Points = [Point || #{point := Point} <- Entries],
    case {[Refused || {error, Refused} <- Groups], length(lists:usort(Points)) =:= length(Points)} of
        {[Refused | _], _} -> {error, Refused};
        {[], false} -> {error, einval};
        {[], true} -> {ok, Entries}
    end;
narrowed(_Table, _Within) ->
    {error, einval}.

narrowed_entries(Table, {Path, Rights}) when ?ERX_IS_FILES_RIGHTS(Rights) ->
    case erx_path:cwd(Path) of
        {ok, Place} -> narrowed_at(deepest_entry(Table, Place), Place, Rights, Table);
        error -> {error, einval}
    end;
narrowed_entries(_Table, _Path) ->
    {error, einval}.

%% The deepest entry whose point Place lies at or under, as a resolution
%% picks it, or none.
deepest_entry(Table, Place) ->
    case [Entry || #{point := Point} = Entry <- Table, lists:prefix(Point, Place)] of
        [] -> none;
        Holding -> lists:last(lists:sort(fun shallower/2, Holding))
    end.

shallower(#{point := A}, #{point := B}) -> length(A) =< length(B).

narrowed_at(none, _Place, _Rights, _Table) ->
    {error, enoent};
narrowed_at(#{point := Point, root := Root, rights := Own} = Entry, Place, Rights, Table)
  when Rights =:= Own; Rights =:= ro ->
    Below = [Mount#{rights := below_rights(Rights, Mount)}
             || #{point := Under} = Mount <- Table, Under =/= Place, lists:prefix(Place, Under)],
    [Entry#{point := Place, root := Root ++ lists:nthtail(length(Point), Place), rights := Rights}
     | Below];
narrowed_at(_Entry, _Place, _Rights, _Table) ->
    {error, eacces}.

below_rights(ro, _Mount) -> ro;
below_rights(_Own, #{rights := Rights}) -> Rights.

-doc "The handler's phase: `resolving`, `reserving`, `running` or `{ended, Reason}`.".
-spec phase(core()) -> resolving | reserving | running | {ended, reason()}.
phase(#core{phase = Phase}) -> Phase.

-doc "The next state and the actions that carry out one event.".
-spec step(core(), event()) -> {core(), [action()]}.
%% Resolving: the image, before anything is reserved, so a refusal has nothing to
%% undo. A resolved file goes to the filler, which is not built.
step(#core{phase = resolving} = C, {resolved, Resolved}) ->
    Errno = case Resolved of
                {ok, _Entry, _Names} -> enotsup;
                {error, Refused} when is_atom(Refused) -> Refused
            end,
    {C#core{phase = {ended, normal}}, [{answer, {error, Errno}}]};
step(#core{phase = reserving} = C, {holder, ok}) ->
    reserve_next(C);
step(#core{phase = reserving} = C, {holder, {error, Errno}}) when is_atom(Errno) ->
    %% No entry was made for this handler, so it has nothing to let go.
    %% eexist: the pid has an entry, another handler speaks for it, and
    %% the starter named a pid that is not its program's.
    {C#core{phase = {ended, normal}}, [{answer, {error, holder_errno(Errno)}}]};
step(#core{phase = reserving, todo = [{N, {pipe, _}} | Todo], made = Made} = C,
     {reserved, {pipe_hand, Number, _Term} = Hand}) when ?IS_POS(Number) ->
    reserve_next(C#core{todo = Todo, made = [{N, Hand} | Made]});
step(#core{phase = reserving, todo = [{N, {buffer, _, _}} | Todo], made = Made, offsets = Offsets} = C,
     {reserved, {mem, Lease, Pages, Offset}}) when ?IS_POS(Lease), ?IS_POS(Pages) ->
    reserve_next(C#core{todo = Todo, made = [{N, {mem, Lease, Pages}} | Made],
                        offsets = [{N, Offset} | Offsets]});
step(#core{phase = reserving, todo = [], window = {window, _}, table = Table} = C, {windowed, DevGrant})
  when is_pid(DevGrant) ->
    reserve_next(C#core{window = none, table = window_dev(Table, DevGrant)});
step(#core{phase = reserving} = C, {refused, Errno}) when is_atom(Errno) ->
    {C#core{phase = {ended, normal}}, undo(C) ++ [{answer, {error, Errno}}]};
step(#core{phase = reserving, todo = []} = C, started) ->
    {C1, Actions} = pump(C#core{phase = running}),
    {C1, [{answer, {ok, lists:reverse(C#core.offsets)}} | Actions]};
%% Reports queue from the first: those that arrive while the program is
%% built wait behind its startup message, which the start wrote.
step(#core{phase = Phase} = C, {report, Report}) when not is_tuple(Phase) ->
    pump(enqueue(C, outgoing(Report)));
step(#core{phase = Phase} = C, pipes_lost) when not is_tuple(Phase) ->
    pump(enqueue(C, {frame, {erx_prog, 1, pipe_server_lost}}));
%% Running: the queue's head, and the program's notices.
step(#core{phase = running, out = sending} = C, {sent, ok}) ->
    pump(drop_head(C));
step(#core{phase = running, out = sending} = C, {sent, busy}) ->
    {C#core{out = owed}, []};
step(#core{phase = running, out = sending} = C, {sent, {error, _}}) ->
    %% A frame the driver refused is lost, and a running program must never
    %% miss a report and read the later ones, so nothing more is sent and the
    %% program is stopped, as a refused install's pass stops it; one already
    %% ending refuses the stop.
    stop(C#core{out = lost, queue = queue:new()}, ?STOP_STATUS);
step(#core{phase = running, out = owed} = C, room) ->
    pump(C#core{out = false});
step(#core{phase = running, out = sending, queue = Q} = C, {installed, Filled}) ->
    %% The values the install gave stand where the hand-off named copies.
    pump(C#core{out = false, queue = queue:in_r({frame, {erx_prog, 1, Filled}}, queue:drop(Q))});
step(#core{phase = running, out = sending, queue = Q} = C, {install_refused, _}) ->
    %% The end the report concerns stays the program's and is lost
    %% (docs/design-pipes.md, "Hand-offs").
    {hand, {pipe_hand, _, Report}} = queue:head(Q),
    {C1, Actions} = pump(drop_head(C)),
    {C1, [{forward, {install_failed, holder(C), element(2, Report), element(3, Report)}} | Actions]};
%% A pipe's making and its two installs, within the event of its request.
step(#core{phase = running, piping = {Slot, [], []}} = C, {pipe_made, {ok, Read, Write}})
  when ?IS_HAND(Read), ?IS_HAND(Write) ->
    install_end(C#core{piping = {Slot, [Read, Write], []}});
step(#core{phase = running, piping = {Slot, [], []}} = C, {pipe_made, {error, Errno}}) when is_atom(Errno) ->
    reply(C#core{piping = none}, pipe, Slot, {error, pipe_errno(Errno)});
step(#core{phase = running, piping = {Slot, [_ | Todo], Done}} = C, {end_installed, Filled}) ->
    install_end(C#core{piping = {Slot, Todo, [Filled | Done]}});
step(#core{phase = running, piping = {Slot, [_ | _] = Hands, Done}} = C, {end_refused, Errno})
  when is_atom(Errno) ->
    %% Every end of the pipe is the program's in the pipe server's records,
    %% whether its install was done, refused or never tried. The refused
    %% hand-off is dropped too: a refusal before the driver's take leaves it
    %% held, and a drop of one taken does nothing.
    Ends = [PipeEnd || {pipe, _, PipeEnd, _} <- lists:reverse(Done)] ++
        [PipeEnd || {pipe_hand, _, {pipe, _, PipeEnd, _}} <- Hands],
    {C1, Sent} = reply(C#core{piping = none}, pipe, Slot, {error, pipe_errno(Errno)}),
    {C1, [{hand_drop, Number} || {pipe_hand, Number, _} <- Hands] ++
         [{forward, {closed, holder(C), Pipe, End}} || {Pipe, End} <- Ends] ++ Sent};
step(#core{phase = running} = C, {frame, Frame}) ->
    case erx_prog_grammar:check_from_program(Frame) of
        ok -> from_program(C, Frame);
        {error, _} -> stop(C, ?REFUSED_STATUS)
    end;
step(#core{phase = running} = C, stop) ->
    stop(C, ?STOP_STATUS);
%% A signal from the session, a kill or the program's job's. The protocol
%% has no report that carries a signal into a program (TODO.md), and only
%% sigkill ends a program whatever it set at run time, so sigkill stops it
%% as a stop does and every other signal does nothing.
step(#core{phase = running} = C, {signal, sigkill}) ->
    stop(C, ?STOP_STATUS);
step(#core{phase = running} = C, {exit_status, Status}) when is_integer(Status) ->
    {C#core{phase = {ended, {shutdown, {program_exit, erx_prog:status(Status)}}}, queue = queue:new()}, []};
step(#core{phase = running} = C, port_closed) ->
    %% The port closed with no status: a record of the end may be lost, and
    %% the starter is told no status the handler did not read.
    {C#core{phase = {ended, program_lost}, queue = queue:new()}, []};
step(#core{phase = running, pending = Pending} = C, {file_opened, Slot, Result}) ->
    case maps:take(Slot, Pending) of
        {Case, Rest} when Case =:= file_lopen; Case =:= file_lcreate ->
            opened(C#core{pending = Rest}, Slot, Case, Result);
        _ ->
            {C, []}
    end;
step(#core{phase = running, pending = Pending} = C, {file_done, Slot, Result}) ->
    case maps:take(Slot, Pending) of
        {{copy, _, _, _} = Waiting, Rest} -> done(C#core{pending = Rest}, Slot, Waiting, Result);
        {{count, _, _} = Waiting, Rest} -> done(C#core{pending = Rest}, Slot, Waiting, Result);
        {Case, Rest} when Case =:= file_clunk; Case =:= file_getattr; Case =:= local_seek ->
            done(C#core{pending = Rest}, Slot, Case, Result);
        _ -> {C, []}
    end;
step(#core{phase = running, pending = Pending} = C, {file_copied, Slot, Result}) ->
    case {maps:take(Slot, Pending), Result} of
        {{{copied, Case, Done}, Rest}, ok} -> file_reply(C#core{pending = Rest}, Case, Slot, {ok, Done});
        {{{copied, Case, _}, Rest}, {error, Errno}} -> file_reply(C#core{pending = Rest}, Case, Slot, {error, Errno});
        _ -> {C, []}
    end;
step(#core{phase = running, first = {opening, Slot, Case, Path, Flags, Mode, Named}} = C,
     {first_window, Result}) ->
    first_window(C#core{first = {first, Named}}, Slot, Case, Path, Flags, Mode, Result);
step(C, _Event) ->
    {C, []}.

%% The answer to a first window: an open the effect side refused before anything
%% opened fails and keeps nothing; a window opened puts the program's own /dev in its
%% table and relays the open there, where no later open of /dev/draw meets the shared
%% /dev; a window that failed once its opening began ends the handler.
first_window(C, Slot, Case, _Path, _Flags, _Mode, {error, enodev}) ->
    file_reply(C, Case, Slot, {error, enodev});
first_window(#core{table = Table} = C, Slot, Case, Path, Flags, Mode, {ok, DevGrant})
  when is_pid(DevGrant) ->
    relay_open(C#core{first = never, table = window_dev(Table, DevGrant)}, Slot, Case, Path, Flags, Mode);
first_window(C, _Slot, _Case, _Path, _Flags, _Mode, {failed, Errno}) when is_atom(Errno) ->
    {C#core{phase = {ended, {shutdown, {window, Errno}}}, queue = queue:new()}, []}.

%% A stop of the program with Status, asked once: the action end_program.
stop(#core{stopping = false} = C, Status) -> {C#core{stopping = true}, [{end_program, Status}]};
stop(C, _Status) -> {C, []}.

%% A frame from the program, which the grammar accepted.
from_program(C, {erx_prog, _, {closed, Pipe, End}}) ->
    {C, [{forward, {closed, holder(C), Pipe, End}}]};
from_program(C, {erx_prog, _, {drained, Pipe, End, Writer}}) ->
    {C, [{forward, {drained, holder(C), Pipe, End, Writer}}]};
from_program(C, {erx_prog, _, Slot, {pipe, Flags}}) ->
    {C#core{piping = {Slot, [], []}}, [{make_pipe, Flags}]};
from_program(C, {erx_prog, _, Slot, {kill, Target, Signal}}) ->
    case reach(C, Target) of
        none -> reply(C, kill, Slot, {error, esrch});
        self -> kill_self(C, Slot, Signal)
    end;
from_program(C, {erx_prog, _, Slot, {probe, Target}}) ->
    case reach(C, Target) of
        none -> reply(C, probe, Slot, {error, esrch});
        self -> reply(C, probe, Slot, ok)
    end;
from_program(C, {erx_prog, _, Slot, {file, lopen, Path, Flags}}) ->
    open(C, Slot, file_lopen, Path, Flags, none);
from_program(C, {erx_prog, _, Slot, {file, lcreate, Path, Flags, Mode}}) ->
    open(C, Slot, file_lcreate, Path, Flags, Mode);
from_program(C, {erx_prog, _, Slot, {file, read, Open, Count, Data}}) ->
    on_open(C, Slot, file_read, Open, Data,
            fun(Desc) -> {{copy, file_read, Count, Data}, {read, Desc, Slot, Count}} end);
from_program(C, {erx_prog, _, Slot, {file, write, Open, Count, Data}}) ->
    on_open(C, Slot, file_write, Open, Data,
            fun(Desc) -> {{count, file_write, Count}, {write, Desc, Slot, Data, Count}} end);
from_program(C, {erx_prog, _, Slot, {file, pread, Open, Offset, Count, Data}}) ->
    on_open(C, Slot, file_pread, Open, Data,
            fun(Desc) -> {{copy, file_pread, Count, Data}, {pread, Desc, Slot, Offset, Count}} end);
from_program(C, {erx_prog, _, Slot, {file, pwrite, Open, Offset, Count, Data}}) ->
    on_open(C, Slot, file_pwrite, Open, Data,
            fun(Desc) -> {{count, file_pwrite, Count}, {pwrite, Desc, Slot, Data, Offset, Count}} end);
from_program(C, {erx_prog, _, Slot, {local, seek, Open, Offset, Whence}}) ->
    on_open(C, Slot, local_seek, Open, fun(Desc) -> {local_seek, {seek, Desc, Slot, Offset, Whence}} end);
from_program(C, {erx_prog, _, Slot, {file, getattr, Open}}) ->
    on_open(C, Slot, file_getattr, Open, fun(Desc) -> {file_getattr, {getattr, Desc, Slot}} end);
from_program(#core{opens = Opens} = C, {erx_prog, _, Slot, {file, clunk, Open}}) ->
    case maps:take(Open, Opens) of
        {Desc, Rest} -> relay(C#core{opens = Rest}, Slot, file_clunk, {clunk, Desc, Slot});
        error -> file_reply(C, file_clunk, Slot, {error, ebadf})
    end.

%% An lopen or an lcreate, relayed to be resolved over the program's
%% namespace from its working directory, or refused; or, for the program's
%% first open of /dev/draw, its window opened first.
open(#core{opens = Opens, pending = Pending, first = First} = C, Slot, Case, Path, Flags, Mode) ->
    %% The opens held and those still pending, each of which may become one:
    %% the relayed ones, and a first open of /dev/draw waiting for its window.
    Taken = map_size(Opens)
        + length([P || P <- maps:values(Pending), P =:= file_lopen orelse P =:= file_lcreate])
        + length([Waiting || {opening, _, _, _, _, _, _} = Waiting <- [First]]),
    if
        Flags band bnot ?OPEN_FLAGS =/= 0; Flags band ?ERX_P9_O_ACCMODE =:= ?ERX_P9_O_ACCMODE;
        Case =:= file_lcreate, Flags band ?EXCL_DIRECTORY =:= ?EXCL_DIRECTORY ->
            file_reply(C, Case, Slot, {error, einval});
        Taken >= ?ERX_PROG_FDS_MAX ->
            file_reply(C, Case, Slot, {error, emfile});
        true ->
            case first_draw(C, Path, Flags) of
                no -> relay_open(C, Slot, Case, Path, Flags, Mode);
                {refused, Errno} -> file_reply(C, Case, Slot, {error, Errno});
                {open, Named} ->
                    {C#core{first = {opening, Slot, Case, Path, Flags, Mode, Named}}, [{first_window, Named}]}
            end
    end.

relay_open(#core{table = Table, cwd = Cwd} = C, Slot, Case, Path, Flags, Mode) ->
    relay(C, Slot, Case, {open, Slot, Path, Flags, create_mode(Flags, Mode), Table, Cwd}).

%% Whether an open of Path opens the program's window first: no; {open, Named};
%% or {refused, Errno} for a table a window start refuses (refusal/2). Path
%% names /dev/draw from the working directory, with no `..`, which only the
%% resolver takes, and the table resolves that place to the shared /dev
%% (shared_dev/1). Its last name is `draw` itself and it opens no directory,
%% so the open the window's /dev then serves can be granted.
first_draw(#core{first = {first, Named}, table = Table, cwd = Cwd}, Path, Flags) ->
    Draws = place(Path, Cwd) =:= [<<"dev">>, <<"draw">>]
        andalso lists:last(binary:split(Path, <<"/">>, [global])) =:= <<"draw">>
        andalso Flags band ?ERX_P9_O_DIRECTORY =:= 0,
    case Draws andalso shared_dev(Table) of
        false ->
            no;
        true ->
            case refusal({window, none}, Table) of
                none -> {open, Named};
                Errno -> {refused, Errno}
            end
    end;
first_draw(_C, _Path, _Flags) ->
    no.

%% Whether the table resolves /dev/draw to the session's shared /dev, the
%% export's `dev`, which holds no `draw`. The export's `dev` is no entry of the
%% table: it answers its own names at /dev over whatever the table holds there
%% (docs/design-files.md, "Where the export and a grant meet"), and an entry at
%% /dev, whatever its provider, takes `draw` as it takes every name the export
%% does not serve: a grant the session mounts there, or a windowed parent's own
%% /dev, whose `draw` a child shares by path ("A program's children"). So the
%% open meets the shared /dev exactly when no entry holds that place, or the
%% one that does lies above /dev.
shared_dev(Table) ->
    case deepest_entry(Table, [<<"dev">>, <<"draw">>]) of
        none -> true;
        #{point := Point} -> Point =:= []
    end.

%% The place Path names from Cwd, read lexically: each empty or `.` name
%% dropped, and none for a path with a `..`.
place(Path, Cwd) ->
    Names = [Name || Name <- binary:split(Path, <<"/">>, [global]), Name =/= <<>>, Name =/= <<".">>],
    case {lists:member(<<"..">>, Names), Path} of
        {true, _} -> none;
        {false, <<"/", _/binary>>} -> Names;
        {false, _} -> Cwd ++ Names
    end.

%% The mode an open creates its file with: none, a lookup, for one with O_DIRECTORY.
create_mode(Flags, _Mode) when Flags band ?ERX_P9_O_DIRECTORY =/= 0 -> none;
create_mode(_Flags, Mode) -> Mode.

%% A read or a write of Open through data slot Data, relayed to the open's
%% description as Relay says, or refused.
on_open(#core{opens = Opens, slots = Slots} = C, Slot, Case, Open, Data, Relay) ->
    case maps:is_key(Open, Opens) of
        true when Data >= Slots -> file_reply(C, Case, Slot, {error, einval});
        _ -> on_open(C, Slot, Case, Open, Relay)
    end.

%% A request on Open, relayed to the open's description as Relay says, or refused.
on_open(#core{opens = Opens} = C, Slot, Case, Open, Relay) ->
    case maps:find(Open, Opens) of
        error ->
            file_reply(C, Case, Slot, {error, ebadf});
        {ok, Desc} ->
            {Waiting, Action} = Relay(Desc),
            relay(C, Slot, Waiting, Action)
    end.

%% A request handed on, its slot waiting for the answer.
relay(#core{pending = Pending} = C, Slot, Waiting, Action) ->
    {C#core{pending = Pending#{Slot => Waiting}}, [Action]}.

%% An open's answer: the lowest open number free names the description.
opened(#core{opens = Opens} = C, Slot, Case, {ok, Desc}) ->
    Open = lowest_free(0, Opens),
    file_reply(C#core{opens = Opens#{Open => Desc}}, Case, Slot, {ok, Open});
opened(C, Slot, Case, {error, Errno}) ->
    file_reply(C, Case, Slot, {error, Errno}).

%% The lowest open number from N up that Opens does not hold. open/6 counts
%% every open held or on its way and refuses one at ?ERX_PROG_FDS_MAX, so the
%% scan stops below that bound.
lowest_free(N, Opens) when is_map_key(N, Opens) -> lowest_free(N + 1, Opens);
lowest_free(N, _Opens) -> N.

%% A read's, a write's, a seek's, a getattr's or a clunk's answer. A read's bytes are
%% copied into the data slot, and the copy's answer, file_copied, gives the
%% reply that names their count; never more bytes than the request asked
%% for are copied, which no grammar can hold a reply to. A seek's offset
%% past off_t, which the protocol cannot carry, is eio, and a getattr's
%% attribute past its field is eoverflow, as FreeBSD's freebsd11_stat
%% answers an nlink past its old nlink_t: the protocol's grammar holds each
%% field's bound.
done(C, Slot, {copy, Case, Count, Data}, {ok, Bytes}) when byte_size(Bytes) =< Count ->
    relay(C, Slot, {copied, Case, byte_size(Bytes)}, {copy_in, Slot, Data, Bytes});
done(C, Slot, {copy, Case, _, _}, {ok, _TooMany}) ->
    file_reply(C, Case, Slot, {error, eio});
done(C, Slot, {copy, Case, _, _}, eof) ->
    file_reply(C, Case, Slot, {ok, 0});
done(C, Slot, {count, Case, Count}, ok) ->
    file_reply(C, Case, Slot, {ok, Count});
done(C, Slot, local_seek, {ok, Offset}) when Offset >= 0, Offset =< ?ERX_OFF_MAX ->
    file_reply(C, local_seek, Slot, {ok, Offset});
done(C, Slot, local_seek, {ok, _Past}) ->
    file_reply(C, local_seek, Slot, {error, eio});
done(C, Slot, file_getattr, {ok, #file_info{} = Info}) ->
    checked_reply(C, file_getattr, Slot, {ok, stat(Info)}, {error, eoverflow});
done(C, Slot, file_clunk, ok) ->
    file_reply(C, file_clunk, Slot, ok);
done(C, Slot, Waiting, {error, Errno}) ->
    file_reply(C, case_of(Waiting), Slot, {error, Errno}).

%% A getattr's attributes: each field of the description's record that
%% holds a value, so a field the server did not give is no key at all.
%% The record holds whole seconds and no nanoseconds, so no time's
%% nanoseconds are given.
stat(#file_info{mode = Mode, links = Links, uid = Uid, gid = Gid, size = Size,
                atime = ATime, mtime = MTime, ctime = CTime}) ->
    maps:filter(fun(_, Value) -> is_integer(Value) end,
                #{mode => Mode, nlink => Links, uid => Uid, gid => Gid, size => Size,
                  atime => ATime, mtime => MTime, ctime => CTime}).

case_of({copy, Case, _, _}) -> Case;
case_of({count, Case, _}) -> Case;
case_of(Case) -> Case.

%% A file request's reply. Its error comes from a file server or the
%% release, whose names the protocol may lack; one it lacks is eio.
file_reply(C, Case, Slot, {error, Errno}) ->
    checked_reply(C, Case, Slot, {error, Errno}, {error, eio});
file_reply(C, Case, Slot, Value) ->
    reply(C, Case, Slot, Value).

%% A kill of the program itself. A signal whose default action in the
%% signal table is stop or continue belongs to the session's job control.
kill_self(C, Slot, Signal) ->
    case {Signal, erx_abi_signals:default_action(Signal)} of
        {_, Action} when Action =:= stop; Action =:= continue ->
            reply(C, kill, Slot, {error, eperm});
        {sigkill, _} ->
            {C1, Stop} = stop(C, ?STOP_STATUS),
            {C2, Sent} = reply(C1, kill, Slot, ok),
            {C2, Stop ++ Sent};
        _ ->
            reply(C, kill, Slot, {error, enosys})
    end.

%% The install of a pipe's next hand-off, or once both are installed the
%% reply that names the values they gave, the read end's first. Those come
%% from the pipe server and the driver, so the reply is checked; one the
%% grammar refuses is their bug, and crashes the handler with it.
install_end(#core{piping = {_Slot, [Hand | _], _Done}} = C) ->
    {C, [{install_end, Hand}]};
install_end(#core{piping = {Slot, [], Done}} = C) ->
    [Read, Write] = lists:reverse(Done),
    {ok, Frame} = erx_prog_grammar:build_reply(pipe, Slot, {ok, Read, Write}),
    queued(C#core{piping = none}, Frame).

%% The errno of a pipe's refusal: the quota's as given, and enomem for the
%% budget's and every other.
pipe_errno(enfile) -> enfile;
pipe_errno(_Errno) -> enomem.

%% Whom a kill or a probe of Target reaches: the program itself, or no one,
%% as the handler keeps no child record and the program holds no signal right.
reach(#core{pid = Pid}, Pid) -> self;
reach(_C, _Target) -> none.

%% The reply Value to the request of case Request on Slot, queued behind the
%% frames already waiting. Value is the handler's own, a constant or a value
%% it bounded itself, so the frame is made unchecked: the grammar would only
%% re-validate it, and the program checks every frame it receives.
reply(C, Request, Slot, Value) ->
    queued(C, erx_prog_grammar:frame_reply(Request, Slot, Value)).

%% A reply whose Value came from beyond the handler (a file server's errno or
%% attributes), checked once against the grammar; one it refuses is answered
%% with Refused, the handler's own.
checked_reply(C, Request, Slot, Value, Refused) ->
    case erx_prog_grammar:build_reply(Request, Slot, Value) of
        {ok, Frame} -> queued(C, Frame);
        {error, _} -> reply(C, Request, Slot, Refused)
    end.

%% Frame, queued behind the frames already waiting.
queued(C, Frame) ->
    pump(enqueue(C, {frame, Frame})).

%% The next descriptor's reservation, or the start once none is left.
reserve_next(#core{todo = [{_N, {pipe, End}} | _]} = C) ->
    {C, [{inherit, End}]};
reserve_next(#core{todo = [{_N, {buffer, Peer, Bytes}} | _]} = C) ->
    {C, [{lend, Peer, Bytes}]};
reserve_next(#core{todo = [], window = {window, Display}} = C) ->
    {C, [{window, Display}]};
reserve_next(#core{todo = [], made = Made} = C) ->
    {C, [{start, lists:reverse(Made)}]}.

%% Everything a refused start reserved, given back whatever the start took.
undo(#core{made = Newest}) ->
    Made = lists:reverse(Newest),
    [{hand_drop, Number} || {_, {pipe_hand, Number, _}} <- Made] ++
        [{unlend, Lease} || {_, {mem, Lease, _}} <- Made] ++
        [holder_drop].

%% Sends the queue's head when nothing is out.
pump(#core{phase = running, out = false, queue = Q} = C) ->
    case queue:peek(Q) of
        {value, {frame, Frame}} -> {C#core{out = sending}, [{send, Frame}]};
        {value, {hand, Hand}} -> {C#core{out = sending}, [{install, Hand}]};
        empty -> {C, []}
    end;
pump(C) ->
    {C, []}.

enqueue(#core{queue = Q} = C, Out) ->
    C#core{queue = queue:in(Out, Q)}.

drop_head(#core{queue = Q} = C) ->
    C#core{out = false, queue = queue:drop(Q)}.

%% A report that lists copies arrives as the pipe server's hand-off.
outgoing({pipe_hand, Number, _Term} = Hand) when ?IS_POS(Number) -> {hand, Hand};
outgoing(Report) -> {frame, {erx_prog, 1, Report}}.

holder(#core{pid = Pid}) -> {program, Pid}.

holder_errno(eexist) -> einval;
holder_errno(Errno) -> Errno.

%% Each number once, each descriptor of a starter's form, at most one buffer.
valid_fds(Fds) ->
    Numbers = [N || {N, _} <- Fds],
    lists:all(fun valid_fd/1, Fds)
        andalso length(lists:usort(Numbers)) =:= length(Fds)
        andalso length([B || {_, {buffer, _, _}} = B <- Fds]) =< 1.

valid_fd({N, {pipe, _End}}) when ?IS_FD(N) -> true;
valid_fd({N, {buffer, Peer, Bytes}}) when ?IS_FD(N), ?IS_POS(Peer), ?IS_POS(Bytes) -> true;
valid_fd(_) -> false.
