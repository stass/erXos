%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_draw_conn).
-behaviour(gen_server).
-moduledoc """
A draw connection (docs/design-display.md, "The draw connection"): the
process of a client's domain that executes Plan 9's draw messages for one
window. `start/1` starts it under `erx_win_sup`, for `erx_draw:open/2` or a
program's handler. It owns the connection's images, `erx_memdraw` images in
the client's own memory; image 0 is an image over the window's buffer, from
`erx_win:image/1`.

**A write** reaches it as one binary, from `erx_draw` or, for a program,
from its `/dev/draw`. `erx_draw_core:plan/2` decodes it and checks it
whole against the connection; a refused write answers `{error, Errno}`
with the errno of the message that failed, the log records the connection,
the errno and the message's offset, and nothing of the write is applied.
Only a planned write reaches `perform/2`, which carries out each operation
in order with `erx_memdraw`, mapping the core's image ids to the images
held here. The core decides everything that needs the connection; this
module decides nothing but which pixels the window shows.

**The dirty list.** Each operation answers the rectangle it touched; those
of image 0 are the window's, and `erx_win_core:add_dirty/2` keeps them in a
list of at most 16. A `v` presents the list with `erx_win:present/2`, waits
for the answer and clears it, so a client that draws faster than the
display shows waits in its flush; a `v` with nothing dirty presents
nothing, and a present that fails keeps the list for the next `v`.

**Reading.** An `r` replaces the bytes left for reading with its
rectangle's pixels, and each `read/2` takes the next of them, at most one
read of `draw`'s worth, the file protocol's payload; a read with nothing
left answers no bytes.

**The program's input** (docs/design-files.md, "A program's window"). A
program's reads of its `/dev/kbd` and `/dev/mouse` wait for a record, so
its `/dev` tree hands each here as a waiting request (`{read, File,
Offset, Count}`), and the connection is their keeper: it holds each in an
`erx_fs_waits` set and has at most one read of each file at the display,
as the window serves its own readers, so a window's input takes at most
two of its session's display grant's requests in flight, however many
reads its program keeps waiting. `pump/2` marks the first waiting read of
a file begun and sends it on to the display on the window handle's fid
with `erx_win:send_read/4`, from this process; the connection answers it
with the display's reply, which `erx_win:reply/2` takes for the read's
id, once image 0 has the window's new size for an `r` record in a
`mouse` reply, and then sends on the next read of that file. A flush of
a read still waiting here is answered `eintr` by the set; the first flush
of the read sent on goes on to the display with `erx_win:send_flush/2`,
and the display answers the read first, with `eintr` or the record it had
already taken, so no record goes to a read the program has flushed. The
display's end answers each read sent on `eio`,
and the end of a grant that sent reads drops them here; their replies then
answer nothing. The window's fids are its holder's, the handler's, so the
reads the connection sent end with the connection, the handler and the
program's `/dev` grant, which share one life.

**The window and its buffer.** The connection ends with its window's
holder, the process that started it, which it monitors and whose exit ends
the window. It draws into the window's buffer, which belongs to that same
process, under a lease it takes from `erx_pixels` before it makes image 0
and holds until it exits. The holder's exit does not return the lease, so
the buffer's range goes back to the free list, and to another window, only
once the connection has ended, however far a write had gone. A window's
buffer has one lease at a time, so a window has one connection at a time:
a second start on it is refused with `ebusy` until the first connection
has ended and its lease is back. A window that ends while its holder lives,
its directory removed or its display lost, leaves the connection running,
each present failing, until the holder exits.

**Memory.** The core charges every image but image 0 against the pixel
quota, 64 MiB unless the starter names another, so one client cannot spend
its session's whole budget on images. An image is freed when no process
holds it, and only this process holds the connection's images: an `f`
drops one, and the process collects its garbage before its next message,
so the memory goes when the charge does; the connection's end frees them
all, however it ends.

**Failures after the plan** answer `{incomplete, Errno}`. A planned
operation can fail only for want of memory, or, for a `v`, in its present,
unless `erx_memdraw` refuses what the core admitted, a bug, answered with
its errno. A draw, shape, read or present that fails leaves the rest of the
write applied, having drawn what it could. An allocation that fails, for
any reason, ends the connection, since its images are then no longer those
its core holds.
A call to a connection that has ended answers `{error, ebadf}`. A crash
report's state shows neither the images, the pixels nor the write
(format_status/1); its stack trace and queued calls are not scrubbed
(TODO.md).
""".

-include("generated/erx_abi.hrl").
-include("erx_fs_waits.hrl").

-export([start/1, start_link/1, write/2, read/2, resized/1, ctl/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).
-export_type([spec/0, answer/0]).

%% The pixel quota of a connection whose starter names none.
-define(QUOTA, (64 * 1024 * 1024)).

-doc """
What `start/1` takes: the starter, which holds the window and owns its
buffer, the window and, optionally, the pixel quota in bytes.
""".
-type spec() :: #{opener := pid(), window := erx_win:window(), quota => non_neg_integer()}.
-doc """
A write's answer: `ok`; `{error, Errno}` for a write refused with nothing
applied; `{incomplete, Errno}` for a planned write one of whose operations
failed (Failures after the plan).
""".
-type answer() :: ok | {error, atom()} | {incomplete, atom()}.

-record(conn, {opener_monitor :: reference(),
               window :: erx_win:window(),
               core :: erx_draw_core:state(),
               images :: #{erx_draw_codec:image_id() => erx_memdraw:image()},
               dirty = [] :: [erx_win_core:rect()],   % what image 0 changed since the last present
               unread = <<>> :: binary(),             % what the last r left for reading
               %% The program's kbd and mouse reads (erx_fs_waits), in arrival order; at
               %% most one of each file is begun, sent on to the display under its id in
               %% reads until the display answers it, and the rest wait.
               waits = erx_fs_waits:new() :: erx_fs_waits:waits(),
               reads = #{} :: #{erx_fs_waits:wait() => {kbd | mouse, erx_win:request()}},
               %% The flushes sent to the display of reads in reads, until it answers each.
               flushes = [] :: [erx_win:request()]}).

-doc """
Starts a connection on the window of `Spec` under `erx_win_sup`, with the
caller as the starter. `{error, einval}` for a window the caller does not
hold, `{error, ebusy}` for one that has a connection, and the errno of
`erx_win:image/1` when image 0 cannot be made.
""".
-spec start(#{window := erx_win:window(), quota => non_neg_integer()}) -> {ok, pid()} | {error, atom()}.
start(#{window := _} = Options) ->
    Spec = (maps:with([window, quota], Options))#{opener => self()},
    Child = #{id => make_ref(), start => {?MODULE, start_link, [Spec]}, restart => temporary,
              shutdown => 5000, type => worker, modules => [?MODULE]},
    case supervisor:start_child(erx_win_sup, Child) of
        {ok, Conn} -> {ok, Conn};
        {error, {{shutdown, Errno}, _Child}} -> {error, Errno}
    end.

-doc false.
-spec start_link(spec()) -> gen_server:start_ret().
start_link(Spec) ->
    gen_server:start_link(?MODULE, Spec, []).

-doc "Executes the draw messages `Bytes` whole, or none of them.".
-spec write(pid(), binary()) -> answer().
write(Conn, Bytes) when is_binary(Bytes) ->
    call(Conn, {write, Bytes}).

-doc "The next at most `Count` bytes, and at most one read of `draw`'s worth, of what the last `r` left.".
-spec read(pid(), non_neg_integer()) -> {ok, binary()} | {error, ebadf}.
read(Conn, Count) when is_integer(Count), Count >= 0 ->
    call(Conn, {read, Count}).

-doc """
After the window was resized: makes image 0 anew over the buffer at the
window's new size, keeping the other images, and forgets the dirty list,
whose rectangles named pixels of the old size.
""".
-spec resized(pid()) -> ok | {error, atom()}.
resized(Conn) ->
    call(Conn, resized).

-doc """
draw(3)'s 144 bytes of information on image 0 as they stand between writes
(erx_draw_core:ctl/1), what a program reads from its `/dev/ctl`
(docs/design-display.md, "The connection's files").
""".
-spec ctl(pid()) -> {ok, <<_:1152>>} | {error, ebadf}.
ctl(Conn) ->
    call(Conn, ctl).

%% A call, answering {error, ebadf} once the connection has ended.
call(Conn, Request) ->
    try
        gen_server:call(Conn, Request, infinity)
    catch
        exit:{_Why, {gen_server, call, _}} -> {error, ebadf}
    end.

%% The server ----------------------------------------------------------------

-doc false.
init(#{opener := Opener, window := Window} = Spec) ->
    Monitor = monitor(process, Opener),
    maybe
        {ok, _Lease, _Pages} ?= erx_win:lease(Window, Opener),
        {ok, Screen} ?= erx_win:image(Window),
        Quota = #{pixels => maps:get(quota, Spec, ?QUOTA), side => ?ERX_WINDOWS_SIDE_MAX},
        Core = erx_draw_core:new(#{r => erx_win:image_rect(Window), chan => erx_win:chan(Window),
                                   quota => Quota}),
        {ok, #conn{opener_monitor = Monitor, window = Window, core = Core, images = #{0 => Screen}}}
    else
        {error, Errno} -> {stop, {shutdown, Errno}}
    end.

-doc false.
handle_call({write, Bytes}, _From, #conn{core = Core} = Conn) ->
    %% A refusal is a plan's one action and leaves the core as it was.
    case erx_draw_core:plan(Core, Bytes) of
        {Core, [{error, Errno, Offset}]} ->
            log(["write refused: ", atom_to_binary(Errno), " at offset ", integer_to_binary(Offset)]),
            {reply, {error, Errno}, Conn};
        {Planned, Ops} ->
            perform_write(Ops, Conn#conn{core = Planned})
    end;
handle_call({read, Count}, _From, #conn{unread = Unread} = Conn) when is_integer(Count), Count >= 0 ->
    {Bytes, Rest} = take(min(Count, ?ERX_P9_IO_MAX), Unread),
    {reply, {ok, Bytes}, Conn#conn{unread = Rest}};
handle_call(resized, _From, Conn) ->
    {Answer, Resized} = resize(Conn),
    {reply, Answer, Resized};
handle_call(ctl, _From, #conn{core = Core} = Conn) ->
    {reply, {ok, erx_draw_core:ctl(Core)}, Conn};
handle_call(_Request, _From, Conn) ->
    {reply, {error, badarg}, Conn}.

-doc false.
handle_cast(_Message, Conn) ->
    {noreply, Conn}.

-doc false.
handle_info({'DOWN', Monitor, process, _Opener, _Why}, #conn{opener_monitor = Monitor} = Conn) ->
    {stop, normal, Conn};
handle_info(?ERX_FS_WAIT(_Wait, {read, File, _Offset, _Count}) = Held, #conn{waits = Waits} = Conn) ->
    {noreply, pump(File, Conn#conn{waits = erx_fs_waits:hold(Held, Waits)})};
handle_info(Message, #conn{waits = Waits} = Conn) ->
    case erx_fs_waits:info(Message, Waits) of
        {flushed, Settled} -> {noreply, Conn#conn{waits = Settled}};
        {begun, Wait, _Read, Flushing} -> {noreply, flush(Wait, Conn#conn{waits = Flushing})};
        {dropped, Dropped} -> {noreply, Conn#conn{waits = Dropped}};
        unknown -> {noreply, display_reply(Message, Conn)}
    end.

-doc false.
format_status(Status) ->
    erx_report:status(Status, #{state => fun conn_facts/1}).

conn_facts(#conn{} = Conn) ->
    erx_report:fields(Conn, [{#conn.core, hidden}, {#conn.images, hidden}, {#conn.unread, hidden}]);
conn_facts(_State) -> hidden.

%% The program's input ---------------------------------------------------------

%% Sends the first read of File still waiting on to the display, unless a read of File
%% is there already: marked begun and sent on the window's fid, or answered with the
%% refusal of a read the display client sends nowhere, after which the next is tried.
pump(File, #conn{window = Window, waits = Waits, reads = Reads} = Conn) ->
    Sent = [Of || {Of, _Id} <- maps:values(Reads), Of =:= File],
    Waiting = [{Wait, Offset, Count}
               || {Wait, {read, Of, Offset, Count}, waiting} <- erx_fs_waits:list(Waits), Of =:= File],
    case {Sent, Waiting} of
        {[_], _} ->
            Conn;
        {[], []} ->
            Conn;
        {[], [{Wait, Offset, Count} | _]} ->
            case erx_win:send_read(Window, File, Offset, Count) of
                {ok, Id} -> Conn#conn{waits = erx_fs_waits:began(Wait, Waits), reads = Reads#{Wait => {File, Id}}};
                {error, _} = Refused -> pump(File, answer(Wait, Refused, Conn))
            end
    end.

%% The first flush of a read sent on goes on to the display, which answers the read
%% first, with eintr or the record it had already taken, and then the flush. A flush
%% of a read the display client sent passes the grammar the read passed.
flush(Wait, #conn{window = Window, reads = Reads, flushes = Flushes} = Conn) ->
    #{Wait := {_File, Id}} = Reads,
    {ok, Flush} = erx_win:send_flush(Window, Id),
    Conn#conn{flushes = [Flush | Flushes]}.

%% A message that answers a read sent on, which answers the program's read and sends on
%% the next of its file, or a flush sent on, which says only that the display has
%% answered its read; any other message is dropped.
display_reply(Message, #conn{reads = Reads, flushes = Flushes} = Conn) ->
    case answered(Message, maps:to_list(Reads)) of
        {Wait, File, Answer} ->
            pump(File, answer_read(Wait, File, Answer, Conn#conn{reads = maps:remove(Wait, Reads)}));
        none ->
            %% A flush whose answer the message is is spent by the reply that takes it.
            Conn#conn{flushes = [Flush || Flush <- Flushes, erx_win:reply(Message, Flush) =:= no_reply]}
    end.

answered(_Message, []) ->
    none;
answered(Message, [{Wait, {File, Id}} | Reads]) ->
    case erx_win:reply(Message, Id) of
        {reply, Answer} -> {Wait, File, Answer};
        no_reply -> answered(Message, Reads)
    end.

%% The program never sees an r record before image 0 has the window's new size,
%% whatever making it anew answers.
answer_read(Wait, mouse, {ok, Records} = Answer, Conn) ->
    case [Kind || <<Kind, _:(?ERX_WINDOWS_MOUSE_RECORD - 1)/binary>> <= Records, Kind =:= $r] of
        [] -> answer(Wait, Answer, Conn);
        [_ | _] ->
            {_Resized, Remade} = resize(Conn),
            answer(Wait, Answer, Remade)
    end;
answer_read(Wait, _File, Answer, Conn) ->
    answer(Wait, Answer, Conn).

answer(Wait, Answer, #conn{waits = Waits} = Conn) ->
    Conn#conn{waits = erx_fs_waits:answer(Wait, Answer, Waits)}.

%% After the window was resized: image 0 made anew over the buffer at the window's new
%% size, keeping the other images, and the dirty list forgotten, whose rectangles named
%% pixels of the old size.
resize(#conn{window = Window, core = Core, images = Images} = Conn) ->
    case erx_win:resized(Window) of
        {ok, Resized, Screen} ->
            {ok, Conn#conn{window = Resized, core = erx_draw_core:resize(Core, erx_win:image_rect(Resized)),
                           images = Images#{0 := Screen}, dirty = []}};
        {error, _} = Failed ->
            {Failed, Conn}
    end.

%% Applying a planned write ----------------------------------------------------

%% Every operation of the write, in order: the answer is ok, or the first
%% failure of one as {incomplete, Errno}. A write that freed an image ends in
%% hibernation, which collects the process's garbage, so the freed images go
%% before the next message.
perform_write(Ops, Conn) ->
    try lists:foldl(fun perform_next/2, {ok, Conn}, Ops) of
        {Result, Done} ->
            Answer = case Result of
                         ok -> ok;
                         {error, Errno} -> {incomplete, Errno}
                     end,
            case lists:keymember(free, 1, Ops) of
                true -> {reply, Answer, Done, hibernate};
                false -> {reply, Answer, Done}
            end
    catch
        throw:{lost_image, Errno} ->
            log(["ended: an image the core admitted could not be allocated: ", atom_to_binary(Errno)]),
            {stop, {shutdown, Errno}, {incomplete, Errno}, Conn}
    end.

perform_next(Op, {Result, Conn}) ->
    {Answer, Performed} = perform(Op, Conn),
    case Result of
        ok -> {Answer, Performed};
        {error, _} -> {Result, Performed}
    end.

%% One operation of erx_draw_core:op(), as {ok | {error, Errno}, Conn}.
perform({alloc, Id, Chan, R, Clipr, Repl, Color}, #conn{images = Images} = Conn) ->
    case erx_memdraw:alloc(Chan, R, Clipr, Repl, Color) of
        {ok, Image} -> {ok, Conn#conn{images = Images#{Id => Image}}};
        {error, Errno} -> throw({lost_image, Errno})
    end;
perform({clip, Id, Repl, Clipr}, Conn) ->
    ok = erx_memdraw:clip(image(Id, Conn), Repl, Clipr),
    {ok, Conn};
perform({free, Id}, #conn{images = Images} = Conn) ->
    {ok, Conn#conn{images = maps:remove(Id, Images)}};
perform({draw, Dst, R, Src, Sp, Mask, Mp, Op, Clip}, Conn) ->
    drawn(Dst, erx_memdraw:draw(image(Dst, Conn), R, image(Src, Conn), Sp, mask(Mask, Conn), Mp, Op, Clip), Conn);
perform({ellipse, Dst, Src, C, A, B, Thick, Sp, Op}, Conn) ->
    drawn(Dst, erx_memdraw:ellipse(image(Dst, Conn), C, A, B, Thick, image(Src, Conn), Sp, Op), Conn);
perform({fill_ellipse, Dst, Src, C, A, B, Sp, Op}, Conn) ->
    drawn(Dst, erx_memdraw:ellipse(image(Dst, Conn), C, A, B, fill, image(Src, Conn), Sp, Op), Conn);
perform({arc, Dst, Src, C, A, B, Thick, Sp, Alpha, Phi, Op}, Conn) ->
    drawn(Dst, erx_memdraw:arc(image(Dst, Conn), C, A, B, Thick, image(Src, Conn), Sp, Alpha, Phi, Op), Conn);
perform({fill_arc, Dst, Src, C, A, B, Sp, Alpha, Phi, Op}, Conn) ->
    drawn(Dst, erx_memdraw:arc(image(Dst, Conn), C, A, B, fill, image(Src, Conn), Sp, Alpha, Phi, Op), Conn);
perform({line, Dst, P0, P1, End0, End1, Thick, Src, Sp, Op}, Conn) ->
    drawn(Dst, erx_memdraw:line(image(Dst, Conn), P0, P1, End0, End1, Thick, image(Src, Conn), Sp, Op), Conn);
perform({poly, Dst, Points, End0, End1, Thick, Src, Sp, Op}, Conn) ->
    drawn(Dst, erx_memdraw:poly(image(Dst, Conn), Points, End0, End1, Thick, image(Src, Conn), Sp, Op), Conn);
perform({fill_poly, Dst, Points, Wind, Src, Sp, Op}, Conn) ->
    drawn(Dst, erx_memdraw:fill_poly(image(Dst, Conn), Points, Wind, image(Src, Conn), Sp, Op), Conn);
perform({load, Id, R, Pixels}, Conn) ->
    drawn(Id, erx_memdraw:load(image(Id, Conn), R, Pixels), Conn);
perform({read, Id, R}, Conn) ->
    case erx_memdraw:read(image(Id, Conn), R) of
        {ok, Bytes} -> {ok, Conn#conn{unread = Bytes}};
        {error, _} = Failed -> {Failed, Conn#conn{unread = <<>>}}
    end;
perform(flush, Conn) ->
    present(Conn).

%% What a drawing operation answered: the rectangle it touched, which is the
%% window's when it drew into image 0, and the errno of one that failed,
%% after drawing what it touched when it ran out of memory part-way.
drawn(Dst, {ok, Touched}, Conn) -> {ok, dirty(Dst, Touched, Conn)};
drawn(Dst, {error, enomem, Touched}, Conn) -> {{error, enomem}, dirty(Dst, Touched, Conn)};
drawn(_Dst, {error, _Errno} = Failed, Conn) -> {Failed, Conn}.

dirty(0, {_, _, _, _} = Touched, #conn{dirty = Dirty} = Conn) ->
    Conn#conn{dirty = erx_win_core:add_dirty(Touched, Dirty)};
dirty(_Dst, _Touched, Conn) ->
    Conn.

present(#conn{dirty = []} = Conn) ->
    {ok, Conn};
present(#conn{window = Window, dirty = Dirty} = Conn) ->
    case erx_win:present(Window, Dirty) of
        ok -> {ok, Conn#conn{dirty = []}};
        {error, _} = Failed -> {Failed, Conn}
    end.

image(Id, #conn{images = Images}) ->
    maps:get(Id, Images).

mask(opaque, _Conn) -> opaque;
mask(Id, Conn) -> image(Id, Conn).

%% The first Count bytes of Unread and the rest; taking the last of them
%% leaves an empty binary, not a part of the old one, so the pixels go.
take(Count, Unread) when Count >= byte_size(Unread) -> {Unread, <<>>};
take(Count, Unread) -> split_binary(Unread, Count).

log(Text) ->
    _ = erx_log:debug(["erx_draw_conn ", pid_to_list(self()), ": " | Text]),
    ok.
