%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_export).
-moduledoc """
The fixed tree of the session's export (docs/design-files.md, "Narrowing for
a program"; docs/design-programs.md, "Devices"): the `erx_fs` callback module
of the tree that holds `/bin`, `/dev` and `/etc` for the session's programs,
whose handlers walk their fids on it. The session serves it to itself through
two grants of its own domain, an `rx` grant for `/bin`, an `rx` directory,
and an `rw` grant for `/dev` and `/etc`, and each handler narrows what a
program reaches of them.

* **The tree is fixed when the grant starts.** init/1 builds every
  directory's listing and draws each node's qid path from the domain's
  counter (erx_fs_version), so no two files of the tree share a qid path, and
  a grant started again serves new files.
* **Each file's kind and permission bits decide its opens** (file/1): a
  directory opens for reading only, and a file other than `tty` opens for
  reading or writing exactly when its bits let it be read or written, so a
  command of `/bin`, execute-only, never opens; a handler starts a command
  by its name.
* **`/bin`** lists the session's Erlang commands
  (erx_shell_namespace:commands/1).
* **`/dev`** holds four character devices. `null` reads as empty and takes
  every write; `zero` reads as zeros and takes every write; `urandom` reads
  from the kernel's generator (erx_bytes:entropy/1) and takes no write; and
  `tty` is a name alone: a walk and a getattr reach it, and an open of it,
  or a create that would open it, answers `enxio` (docs/design-files.md,
  "Native clients: `liberx`'s file client"). The handler that opens the
  name makes a terminal's description instead, an open of the terminal
  relay under the program's job (docs/design-programs.md, "The terminal"),
  so no terminal read or write reaches this tree.
* **`/etc`** holds `passwd` and `group`, read-only: the session's principal,
  with its number as uid and gid, and `nobody` (65534).
* **A create** of an existing device opens it (erx_fs_node:open_by_create/4),
  since prim_file opens every file it writes through a create, so
  `>/dev/null` reaches `null`; a create of any other name answers `eacces`,
  as the tree's names are its own and fixed.

**A program's own `/dev`** (docs/design-files.md, "A program's window") is
this tree started by a program's handler for that program alone, with its
window, its draw connection and its display among its arguments. Its root
holds `dev` alone, which holds the four devices and the window's names,
`clipboard` only when the session's grant on the display carries it:

* `draw` is the connection's (erx_draw_conn:write/2 and read/2): a write's
  bytes are one call, executed whole or not at all, answered with the whole
  count or the errno of a refused or an incomplete write, and `ebadf` once
  the connection has ended.
* `ctl` is read-only: a read at offset 0 of at least 144 bytes answers
  erx_draw_conn:ctl/1's text, one of fewer `einval`, and a read at any other
  offset no bytes (docs/design-display.md, "The connection's files").
* `kbd`, `mouse`, `wctl` and `label` are relayed on the window handle's own
  fids, which no request of this tree walks or opens; no relay reaches the
  window's `ctl`. A read of `kbd` or `mouse`, which waits for a record, is a
  waiting request whose keeper is the draw connection (`{wait, Conn,
  {read, File, Offset, Count}}`), which relays it and makes image 0 anew for
  an `r` record before it answers; `wctl` and `label` answer at once, and are
  relayed within the callback (erx_win:read_at/4 and write_at/4).
* `clipboard` is opened on a fid of its own per open (erx_win:clipboard_open/2),
  owned by this grant and clunked by the open's clunk.

An open records its access mode, and a read or a write that the mode does not
allow answers `ebadf`, as on UNIX.
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([start_window/1, displays/0]).
-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, write/4, make/4,
         readdir/4, statfs/1, clunk/2]).

-export_type([args/0]).

-doc """
What init/1 takes: for the shared tree, the session's principal and the names
`/bin` lists; for a program's own `/dev`, its window; and, for a test, a
stand-in for the kernel's generator.
""".
-type args() :: #{principal := #{name := binary(), number := pos_integer()},
                  commands := [binary()],
                  entropy => fun((1..?ERX_ENTROPY_BYTES_MAX) -> binary())}
              | #{window := window(),
                  entropy => fun((1..?ERX_ENTROPY_BYTES_MAX) -> binary())}.

-doc """
A program's window: the window erx_win:open/2 made, the draw connection on
it, the display, the name of the session's grant of it, and whether that
grant carries `clipboard`.
""".
-type window() :: #{window := erx_win:window(), conn := pid(), display := atom(),
                    clipboard := boolean()}.

%% The tree's name, which attach's Aname names.
-define(TREE, <<"export">>).
-define(NOBODY, 65534).
-define(IS_RELAYED(File), (File =:= kbd orelse File =:= mouse orelse File =:= wctl orelse File =:= label)).

%% A directory, a command of /bin, a device of /dev or a file of /etc, or one of a
%% program's window files.
-type node_() :: root | bin | dev | etc | {command, binary()}
               | null | zero | urandom | tty | passwd | group
               | draw | ctl | kbd | mouse | wctl | label | clipboard.
-type access() :: read | write | read_write.

-doc """
A program's own `/dev` on a window of its own on `Display` (docs/design-files.md,
"A program's window"), started in the calling process, the program's handler, which
becomes the one owner of all three: the window's holder (erx_win:open/2), the draw
connection's starter and what the tree's grant ends with. Each therefore ends when the
handler does, whatever its reason, and a refused start undoes nothing by hand. The
handler is linked to the connection, which ends `normal` only at the handler's end, so
the connection's end ends the handler, as a crash of the tree's grant does. Answers
the tree's grant, `enodev` in a domain without the display client or with no grant of
`Display`, the window's or the connection's own errno, or `eio` for a tree that does not
start. The display's window modules are named here, in the session's application,
and not by the handler, since the display domain's release ships the handler's
application and none of the client's (docs/design-display.md, G9).
""".
-spec start_window(atom()) -> {ok, pid()} | {error, atom()}.
start_window(Display) ->
    maybe
        {ok, Window} ?= open_window(Display),
        {ok, Conn} ?= erx_draw_conn:start(#{window => Window}),
        %% The handler ends at the connection's end, which keeps its program's input
        %% reads at the display on the window's fids (docs/design-files.md, "A program's
        %% window", "Ownership and lifetime").
        true = link(Conn),
        Args = #{window => #{window => Window, conn => Conn, display => Display,
                             clipboard => erx_win:clipboard(Display)}},
        {ok, _} ?= tree(erx_fs:start_link(?MODULE, Args, rw, #{client => own, ends_with => self()}))
    end.

-doc """
The displays whose `windows` grant the domain holds, by the name its registry
gives each (docs/design-display.md, "Choosing a display"). The registry names a
facet after its service and does not record its interface, so this answers
`display`, the name every manifest gives its one display's `windows` service, when
the domain holds a facet of that name (docs/todo-session.md, "the displays a session holds").
""".
-spec displays() -> [atom()].
displays() ->
    [display || erx:cap(display) =/= undefined].

%% The window, or enodev in a domain that holds no grant of Display or whose release
%% lacks the display client, whose erx_win is then not loaded; any other undef is a
%% fault of the code, raised again.
open_window(Display) ->
    try erx_win:open(Display, #{}) of
        {error, none} -> {error, enodev};
        Answer -> Answer
    catch
        error:undef:Stack ->
            case {Stack, erlang:module_loaded(erx_win)} of
                {[{erx_win, _, _, _} | _], false} -> {error, enodev};
                _ -> erlang:raise(error, undef, Stack)
            end
    end.

%% A tree that does not start refuses the start with eio.
tree({ok, Pid, _Handle}) -> {ok, Pid};
tree({error, _}) -> {error, eio}.

%% ---------------------------------------------------------------------------
%% The erx_fs callbacks
%% ---------------------------------------------------------------------------

-doc false.
-spec init(args()) -> {ok, map()}.
init(Args) ->
    Dirs = dirs(Args),
    Files = [Node || Entries <- maps:values(Dirs), {_, Node} <- Entries,
                     not is_map_key(Node, Dirs)],
    Qids = maps:from_list([{Dir, qid(?ERX_P9_QTDIR)} || Dir <- maps:keys(Dirs)]
                          ++ [{File, qid(0)} || File <- Files]),
    {ok, (maps:with([window], Args))#{dirs => Dirs, qids => Qids, texts => texts(Args),
                                       entropy => maps:get(entropy, Args, fun erx_bytes:entropy/1)}}.

%% Each directory's listing, in order: /bin's commands, and /dev's devices and
%% /etc's files as every program's handler knows them
%% (erx_prog_handler_core:exported/1), each the node of its name. A program's
%% own /dev holds dev alone, with the window's names, clipboard only when the
%% session's grant on the display carries it.
dirs(#{window := #{display := Display, clipboard := Clipboard}}) ->
    #{dev := Names} = erx_prog_handler_core:exported({window, Display}),
    #{root => [{<<"dev">>, dev}],
      dev => [{Name, binary_to_existing_atom(Name)} || Name <- Names, Clipboard orelse Name =/= <<"clipboard">>]};
dirs(#{commands := Commands}) ->
    #{dev := Devices, etc := Texts} = erx_prog_handler_core:exported(),
    #{root => [{<<"bin">>, bin}, {<<"dev">>, dev}, {<<"etc">>, etc}],
      bin => [{Name, {command, Name}} || Name <- lists:usort(Commands)],
      dev => [{Name, binary_to_existing_atom(Name)} || Name <- Devices],
      etc => [{Name, binary_to_existing_atom(Name)} || Name <- Texts]}.

%% A qid of Type whose path is drawn from the domain's counter; a counter spent
%% to 2^64 - 1 fails the grant's start.
qid(Type) ->
    {ok, Path} = erx_fs_version:draw(),
    {Type, 0, Path}.

%% The seven fields of a passwd line, as musl's getpwent reads them (name,
%% password, uid, gid, gecos, home and shell), and the four of a group line
%% (name, password, gid and members). No password is set: a session is
%% already its principal's.
texts(#{principal := Principal}) -> passwd_group(Principal);
texts(#{window := _}) -> #{}.

passwd_group(#{name := Name, number := Number}) ->
    Id = integer_to_binary(Number),
    Nobody = integer_to_binary(?NOBODY),
    #{passwd => <<Name/binary, ":*:", Id/binary, ":", Id/binary, "::/:/bin/rc\n",
                  "nobody:*:", Nobody/binary, ":", Nobody/binary,
                  ":Unprivileged user:/nonexistent:/usr/sbin/nologin\n">>,
      group => <<Name/binary, ":*:", Id/binary, ":\n", "nobody:*:", Nobody/binary, ":\n">>}.

%% A file's kind and permission bits: what getattr shows and what its opens
%% allow. Every directory is r-x.
-spec file(node_()) -> {file | char, 0..8#777}.
file({command, _}) -> {file, 8#111};
file(Device) when Device =:= null; Device =:= zero; Device =:= tty -> {char, 8#666};
file(urandom) -> {char, 8#444};
file(Device) when Device =:= draw; Device =:= wctl; Device =:= label; Device =:= clipboard -> {char, 8#666};
file(Device) when Device =:= ctl; Device =:= kbd; Device =:= mouse -> {char, 8#444};
file(Text) when Text =:= passwd; Text =:= group -> {file, 8#444}.

-doc false.
root(#{qids := #{root := Qid}}) ->
    {ok, ?TREE, root, Qid}.

-doc false.
walk(Dir, Name, #{dirs := Dirs, qids := Qids}) ->
    case Dirs of
        #{Dir := Entries} ->
            case lists:keyfind(Name, 1, Entries) of
                {Name, Node} -> {ok, Node, map_get(Node, Qids)};
                false -> {error, enoent}
            end;
        #{} ->
            {error, enotdir}
    end.

-doc false.
getattr(Node, #{dirs := Dirs, qids := Qids}) when is_map_key(Node, Dirs) ->
    erx_fs_node:attr(map_get(Node, Qids), dir, 8#555);
getattr(Node, #{qids := Qids}) ->
    {Kind, Mode} = file(Node),
    erx_fs_node:attr(map_get(Node, Qids), Kind, Mode).

%% A program's terminal is opened by its handler, never through this tree, so
%% `tty` answers enxio whatever the mode.
-doc false.
open(tty, _Flags, _Fs) ->
    {error, enxio};
open(Node, Flags, #{dirs := Dirs} = Fs) ->
    case {access(Flags), Dirs} of
        {error, _} -> {error, einval};
        {{ok, read}, #{Node := Entries}} -> {ok, {entries, listing(Entries, Fs)}};
        {{ok, _}, #{Node := _}} -> {error, eisdir};
        {{ok, Access}, #{}} -> opened(Node, Access, Flags, Fs)
    end.

-spec access(non_neg_integer()) -> {ok, access()} | error.
access(Flags) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        0 -> {ok, read};
        ?ERX_P9_O_WRONLY -> {ok, write};
        ?ERX_P9_O_RDWR -> {ok, read_write};
        _ -> error
    end.

listing(Entries, #{dirs := Dirs, qids := Qids}) ->
    [{map_get(Node, Qids), Offset, dirent_type(Node, Dirs), Name}
     || {Offset, {Name, Node}} <- lists:enumerate(1, Entries)].

dirent_type(Node, Dirs) when is_map_key(Node, Dirs) -> ?ERX_P9_DT_DIR;
dirent_type(Node, _Dirs) ->
    case file(Node) of
        {char, _} -> ?ERX_P9_DT_CHR;
        {file, _} -> ?ERX_P9_DT_REG
    end.

%% A file opens with Access when its permission bits allow every part of it. The
%% clipboard is opened at the display with the program's flags, on a fid of the
%% open's own.
opened(Node, Access, Flags, Fs) ->
    {_Kind, Mode} = file(Node),
    Reads = Mode band 8#444 =/= 0,
    Writes = Mode band 8#222 =/= 0,
    case {Access, Reads, Writes} of
        {read, true, _} -> handle(Node, read, Flags, Fs);
        {write, _, true} -> handle(Node, write, Flags, Fs);
        {read_write, true, true} -> handle(Node, read_write, Flags, Fs);
        _ -> {error, eacces}
    end.

handle(clipboard, Access, Flags, #{window := #{display := Display}}) ->
    case erx_win:clipboard_open(Display, Flags) of
        {ok, Clipboard} -> {ok, {{clipboard, Clipboard}, Access}};
        {error, _} = Refused -> Refused
    end;
handle(Node, Access, _Flags, _Fs) ->
    {ok, {Node, Access}}.

-doc false.
read({entries, _}, _Offset, _Count, _Fs) ->
    {error, eisdir};
read({_Node, write}, _Offset, _Count, _Fs) ->
    {error, ebadf};
read({null, _}, _Offset, _Count, _Fs) ->
    {ok, <<>>};
read({zero, _}, _Offset, Count, _Fs) ->
    {ok, <<0:(Count * 8)>>};
read({urandom, _}, _Offset, Count, #{entropy := Entropy}) ->
    random(Count, Entropy);
read({draw, _}, _Offset, Count, #{window := #{conn := Conn}}) ->
    erx_draw_conn:read(Conn, Count);
read({ctl, _}, 0, Count, #{window := #{conn := Conn}}) ->
    %% Whole or not at all, as devdraw refuses a short read.
    case erx_draw_conn:ctl(Conn) of
        {ok, Text} when byte_size(Text) > Count -> {error, einval};
        Answer -> Answer
    end;
read({ctl, _}, _Offset, _Count, _Fs) ->
    {ok, <<>>};
read({File, _}, Offset, Count, #{window := #{conn := Conn}}) when File =:= kbd; File =:= mouse ->
    %% A read that waits for a record waits at the draw connection, its keeper.
    {wait, Conn, {read, File, Offset, Count}};
read({File, _}, Offset, Count, #{window := #{window := Window}}) when ?IS_RELAYED(File) ->
    erx_win:read_at(Window, File, Offset, Count);
read({{clipboard, Clipboard}, _}, Offset, Count, _Fs) ->
    erx_win:clipboard_read(Clipboard, Offset, Count);
read({Text, _}, Offset, Count, #{texts := Texts}) when Text =:= passwd; Text =:= group ->
    Bytes = map_get(Text, Texts),
    Start = min(Offset, byte_size(Bytes)),
    {ok, binary:part(Bytes, Start, min(Count, byte_size(Bytes) - Start))}.

%% Count bytes of the kernel's generator, which gives at most
%% ERX_ENTROPY_BYTES_MAX a read; a read it refuses answers eio, and nothing
%% else stands in for its bytes.
random(Count, Entropy) ->
    Sizes = lists:duplicate(Count div ?ERX_ENTROPY_BYTES_MAX, ?ERX_ENTROPY_BYTES_MAX)
        ++ [Count rem ?ERX_ENTROPY_BYTES_MAX || Count rem ?ERX_ENTROPY_BYTES_MAX > 0],
    try
        {ok, << <<(Entropy(Size))/binary>> || Size <- Sizes >>}
    catch
        error:{entropy, _Status} -> {error, eio}
    end.

%% Only the files whose bits allow it open for writing (file/1); tty opens for
%% nothing (open/3).
-doc false.
write({_Node, read}, _Offset, _Bytes, _Fs) ->
    {error, ebadf};
write({Sink, _}, Offset, Bytes, _Fs) when Sink =:= null; Sink =:= zero ->
    {ok, byte_size(Bytes), Offset};
write({draw, _}, Offset, Bytes, #{window := #{conn := Conn}}) ->
    case erx_draw_conn:write(Conn, Bytes) of
        ok -> {ok, byte_size(Bytes), Offset};
        {error, Errno} -> {error, Errno};
        {incomplete, Errno} -> {error, Errno}
    end;
write({File, _}, Offset, Bytes, #{window := #{window := Window}}) when ?IS_RELAYED(File) ->
    relayed(erx_win:write_at(Window, File, Offset, Bytes), Offset);
write({{clipboard, Clipboard}, _}, Offset, Bytes, _Fs) ->
    relayed(erx_win:clipboard_write(Clipboard, Offset, Bytes), Offset);
write({entries, _}, _Offset, _Bytes, _Fs) ->
    {error, ebadf}.

%% A relayed write's answer at the request's offset; the file protocol's reader
%% already refuses a count past the bytes sent (erx_file_remote).
relayed({ok, Count, _}, Offset) -> {ok, Count, Offset};
relayed({error, _} = Refused, _Offset) -> Refused.

-doc false.
make(dev, Name, {file, _Mode, Flags}, Fs) ->
    case walk(dev, Name, Fs) of
        {ok, Device, Qid} ->
            erx_fs_node:open_by_create(Device, Qid, Flags, fun(F) -> open(Device, F, Fs) end);
        {error, enoent} ->
            {error, eacces}
    end;
make(_Dir, _Name, _What, _Fs) ->
    {error, eacces}.

-doc false.
readdir(Handle, Offset, Max, _Fs) ->
    erx_fs_node:readdir(Handle, Offset, Max).

-doc false.
statfs(_Fs) ->
    erx_fs_node:statfs(?ERX_P9_MAGIC_DEVFS).

-doc false.
clunk({{clipboard, Clipboard}, _}, _Fs) ->
    erx_win:clipboard_close(Clipboard);
clunk(_Handle, _Fs) ->
    ok.
