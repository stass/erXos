%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_win).
-moduledoc """
The client library for windows (docs/design-display.md, "Erlang clients"),
for an Erlang process in any domain that holds a display's grant.

`open(Display, Options)` makes a window in the domain's directory of the
display's tree with the caller as its holder, so the window ends when the
caller does, and allocates its buffer at the screen's size from the
domain's pixel area through `erx_pixels`, owned by the caller too. The
answer is a handle holding the fids of the window's files, the display's
channel, the buffer and the window's rectangle. The caller owns the fids,
so they live as long as the caller does; any process of the domain may
use the handle meanwhile (docs/design-files.md, "Fid owners"), as a
renderer linked to the widget server that opened its window does
(docs/design-display.md, "The widget server"), and as the draw connection
the caller opens on it with `erx_draw:open/1` does, which ends with the
caller too.

`image/1` answers an `erx_memdraw` image over the buffer at the window's
size, clipped to the buffer, and `image_rect/1` and `chan/1` that image's
rectangle and channel; `lease/2` takes a lease of the buffer for the
draw connection that draws in it; `present/2` writes a present of rectangles of
that image and waits for its answer; `mouse/1` and `kbd/1` read one record
each, waiting for one; `resized/1`, after an `r` record, reads the
window's rectangle again and answers an image at the new size over the
same buffer, clipped to it, allocating nothing; `resize/2` and `label/2`
write `wctl` and `label`.

**A program's input** (docs/design-display.md, "Erlang clients"). A
program's draw connection keeps the program's reads of `kbd` and `mouse`
while it serves the program's other requests. `send_read/4` sends such a
read and answers its request id at once; the display's reply arrives as a
message, which `reply/2` takes for that id, held to its request as every
reply here is, and the end of the display's grant answers the read
`{error, eio}`. `send_flush/2` sends the display a flush of the read an id
names: the display answers the read first, with `{error, eintr}` or the
record it had already taken, and then the flush, whose own id `reply/2`
takes too.

**A window over a range it does not own** (docs/design-display.md, "Erlang
clients"). `open(Display, #{buffer => none})` makes the window and
allocates nothing, so the window holds no buffer and its end frees none.
`info/1` answers the window's `peer`, `rect`, `chan`, `scale` and
`palette`, from which a renderer sizes a buffer someone else owns, and `present/3` presents
rectangles of a named `buffer()`, drawn at its own width and height. The
display checks such a present against the client's whole pixel area and
clips the buffer to the window; keeping it inside the range it names is
the caller's. Of a window with no buffer, `image/1`, `lease/2` and
`present/2` answer `{error, none}`, and `resized/1` answers `none` for the image.

Every request to the display passes `erx_file_remote:exchange/2`, whose
grant's funnel holds it to the file protocol's grammar and which holds each
reply to its request, and
every answer read back passes a reader of `erx_win_core`, so a display's
bytes reach the caller only as a checked term or `{error, eio}`.

**The screen's size.** The window tree serves no `screen` file
(TODO.md, the window tree's `screen`), so `open/2` takes the screen's size
from the new window's rectangle, which the single policy sets to the
screen's; for the same reason the buffer is allocated after the window is
made, and an area with no room answers `{error, enomem}` after the
`windows` quota rather than before it.
""".

-include("generated/erx_abi.hrl").

-export([open/2, info/1, image/1, image_rect/1, chan/1, lease/2, present/2, present/3, mouse/1,
         kbd/1, resized/1, resize/2, label/2, read_at/4, write_at/4, send_read/4, reply/2,
         send_flush/2]).
-export([clipboard/1, clipboard_open/2, clipboard_read/3, clipboard_write/3, clipboard_close/1]).
-export_type([window/0, options/0, buffer/0, info/0, clipboard/0, request/0]).

-define(O_RDONLY, 0).
%% The display's name for its clipboard at the window tree's root.
-define(CLIPBOARD, <<"clipboard">>).
%% The window's files read_at/4 and write_at/4 relay for a program: every one but
%% ctl, which presents any range of the client's pixel area.
-define(RELAYED(File), (File =:= kbd orelse File =:= mouse orelse File =:= wctl orelse File =:= label)).
%% A kbd record is at most a kind byte, the runes of a read's worth and a NUL; a read
%% of the display's whole queue takes any record it holds.
-define(KBD_READ, ?ERX_WINDOWS_QUEUE_BYTES).

-doc """
What `open/2` takes: `name`, the window's directory, else a name of its
own; `buffer => none` for a window that allocates no buffer.
""".
-type options() :: #{name => binary(), buffer => none}.

-doc """
A buffer in the client's pixel area: the range's offset and the width and
height its frame is drawn at (docs/design-display.md, "Windows and buffers").
""".
-type buffer() :: #{offset := non_neg_integer(), width := 1..?ERX_WINDOWS_SIDE_MAX,
                    height := 1..?ERX_WINDOWS_SIDE_MAX}.

-doc """
What `info/1` answers: the display's peer, the window's rectangle, the
display's channel, and the window's scale and palette, as its `ctl` reads.
""".
-type info() :: #{peer := non_neg_integer(), rect := erx_win_core:rect(),
                  chan := erx_win_core:chan(), scale := {pos_integer(), pos_integer()},
                  palette := erx_theme:palette()}.

-doc """
A window, as `open/2` answers it; its fields are this module's. `own` is
the window's own buffer with the area it lies in, or `none` for a window
opened with `buffer => none`.
""".
-opaque window() :: #{tree := {pid(), binary(), rw},
                      peer := non_neg_integer(),
                      name := binary(),
                      fids := #{ctl | mouse | kbd | wctl | label => non_neg_integer()},
                      chan := erx_win_core:chan(),
                      scale := {pos_integer(), pos_integer()},
                      palette := erx_theme:palette(),
                      own := none | #{area := term(), buffer := buffer()},
                      rect := erx_win_core:rect()}.

-doc """
Makes a window on the display `Display`, the name of its grant in this
domain's registry, with the caller as holder. `{error, none}` when the
domain holds no grant of that name or, for a window with a buffer, has no
pixel area to the display, `{error, enomem}` when the area has no room for
the buffer, `{error, eio}` for an answer of the display outside its
format, and the file protocol's error of a request it refuses, such as
`eexist` for a name in use and `edquot` past the grant's `windows`.
""".
-spec open(atom(), options()) -> {ok, window()} | {error, atom()}.
open(Display, Options) when is_atom(Display), is_map(Options) ->
    case erx:cap(Display) of
        undefined -> {error, none};
        Grant -> open_on({Grant, ?ERX_WINDOWS_TREE_BYTES, rw}, erx:owner(Grant), name(Options),
                         allocation(Options))
    end.

-doc "The window's display peer, its rectangle as last read, the display's channel and the window's scale and palette.".
-spec info(window()) -> info().
info(Window) ->
    maps:with([peer, rect, chan, scale, palette], Window).

-doc """
An image over the window's buffer at the window's size, clipped to the
buffer; `{error, none}` for a window with no buffer.
""".
-spec image(window()) -> {ok, erx_memdraw:image()} | {error, none | einval | enomem}.
image(#{own := none}) ->
    {error, none};
image(#{own := #{area := Area, buffer := #{offset := Offset}}} = Window) ->
    erx_memdraw:wrap(Area, Offset, image_rect(Window), chan(Window)).

-doc """
The rectangle of the image `image/1` answers, with its origin at (0, 0), of
a window with a buffer.
""".
-spec image_rect(window()) -> erx_win_core:rect().
image_rect(#{own := #{buffer := Buffer}, rect := Rect}) ->
    erx_win_core:image_rect(Rect, extent(Buffer)).

-doc "The channel of the window's buffer, as `erx_memdraw` takes it.".
-spec chan(window()) -> erx_chan:code().
chan(#{chan := #{code := Code}}) ->
    Code.

-doc """
A lease of the window's buffer held by the caller, from `erx_pixels`: the
buffer's range stays out of the free list until the caller has exited,
whenever `Holder`, the window's holder and so the buffer's owner, exits.
`{error, einval}` when `Holder` does not own the buffer. A window's buffer
has one lease at a time: while one is outstanding, a lease for a caller other
than `Holder` is refused with `{error, ebusy}`. `{error, none}` for a
window with no buffer.
""".
-spec lease(window(), pid()) -> {ok, pos_integer(), pos_integer()} | {error, atom()}.
lease(#{own := none}, Holder) when is_pid(Holder) ->
    {error, none};
lease(#{peer := Peer, own := #{buffer := #{offset := Offset}}}, Holder) when is_pid(Holder) ->
    erx_pixels:lend(Peer, Offset, Holder).

-doc """
Presents the rectangles `Rects` of the window's image, all of it for `[]`,
and waits for the display's answer: `present/3` over the window's own
buffer at the window's size, clipped to it. `{error, none}` for a window
with no buffer.
""".
-spec present(window(), [erx_win_core:rect()]) -> ok | {error, atom()}.
present(#{own := none}, Rects) when is_list(Rects) ->
    {error, none};
present(#{own := #{buffer := Buffer}, rect := Rect} = Window, Rects) when is_list(Rects) ->
    {0, 0, Width, Height} = erx_win_core:image_rect(Rect, extent(Buffer)),
    present(Window, Buffer#{width := Width, height := Height}, Rects).

-doc """
Presents the rectangles `Rects` of `Buffer`, all of it for `[]`, and waits
for the display's answer. The display checks the buffer against the
client's pixel area, not against the range the offset begins, and clips it
to the window, so keeping `Buffer` inside a range is the caller's.
""".
-spec present(window(), buffer(), [erx_win_core:rect()]) -> ok | {error, atom()}.
present(Window, #{offset := Offset, width := Width, height := Height}, Rects)
  when is_integer(Offset), is_integer(Width), is_integer(Height), is_list(Rects) ->
    write(Window, ctl, erx_win_core:present(Offset, Width, Height, Rects)).

-doc """
A read of `Count` bytes at `Offset` of the window's file `File`, one of
`kbd`, `mouse`, `wctl` and `label`, on the fid `open/2` opened, answered as
the display answers it; a program's `/dev` tree relays its program's reads
so (docs/design-files.md, "A program's window"). No clause takes `ctl`, so
no relayed request reaches the window's `ctl`.
""".
-spec read_at(window(), kbd | mouse | wctl | label, non_neg_integer(), non_neg_integer()) ->
          {ok, binary()} | {error, atom()}.
read_at(#{tree := Tree, fids := Fids}, File, Offset, Count) when ?RELAYED(File) ->
    one(Tree, {read, map_get(File, Fids), Offset, Count}).

-doc """
A write of `Bytes` at `Offset` of the window's file `File`, `wctl` or
`label` as the display opens them for writing (or `kbd` and `mouse`, which
the display refuses), on the fid `open/2` opened: `{ok, Count, Offset1}`
as the display answers it, or its error.
""".
-spec write_at(window(), kbd | mouse | wctl | label, non_neg_integer(), binary()) ->
          {ok, non_neg_integer(), non_neg_integer()} | {error, atom()}.
write_at(#{tree := Tree, fids := Fids}, File, Offset, Bytes) when ?RELAYED(File), is_binary(Bytes) ->
    one(Tree, {write, map_get(File, Fids), Offset, Bytes}).

-doc "A read `send_read/4` or a flush `send_flush/2` sent, not yet answered.".
-opaque request() :: erx_file_remote:request_id().

-doc """
Sends a read of `Count` bytes at `Offset` of the window's `kbd` or `mouse`
on the fid `open/2` opened, and answers its id without waiting for the
display, which answers the read when a record arrives; `reply/2` takes
the answer, which is `read_at/4`'s. A read the file protocol's grammar
refuses is sent nowhere and answers `{error, einval}`.
""".
-spec send_read(window(), kbd | mouse, non_neg_integer(), non_neg_integer()) ->
          {ok, request()} | {error, atom()}.
send_read(#{tree := Tree, fids := Fids}, File, Offset, Count) when File =:= kbd; File =:= mouse ->
    erx_file_remote:send(Tree, {read, map_get(File, Fids), Offset, Count}).

-doc """
`{reply, Answer}` when `Message`, a message the caller received, answers
the request `Id`: the display's reply, `{error, eio}` for one outside the
file protocol, or `{error, eio}` once the display's grant has ended with
no reply. `no_reply` for any other message. An answered id is spent.
""".
-spec reply(term(), request()) -> {reply, ok | {ok, binary()} | {error, atom()}} | no_reply.
reply(Message, Id) ->
    erx_file_remote:take(Message, Id).

-doc """
Sends the display a flush of the read `Id` names, and answers the flush's
own id, whose answer `reply/2` takes: `ok`, after the display has
answered the read.
""".
-spec send_flush(window(), request()) -> {ok, request()} | {error, atom()}.
send_flush(#{tree := Tree}, Id) ->
    erx_file_remote:send_flush(Tree, Id).

-doc """
The display's clipboard opened on a fid of its own: the grant's tree and the
fid, which the caller owns.
""".
-opaque clipboard() :: {{pid(), binary(), rw}, non_neg_integer()}.

-doc """
Whether the domain's grant of the display `Display` carries `clipboard`:
whether a walk of `clipboard` from its root reaches the file. `false` for a
display the domain holds no grant of, or one whose root it cannot attach.
""".
-spec clipboard(atom()) -> boolean().
clipboard(Display) when is_atom(Display) ->
    case clipboard_fid(Display) of
        {ok, Tree, Fid} ->
            clunk(Tree, [Fid]),
            true;
        {error, _} ->
            false
    end.

-doc """
Opens the display's clipboard with the 9P2000.L open flags `Flags`, on a fid
of its own owned by the caller, so an open with `O_TRUNC` empties it as the
display answers it (docs/design-files.md, "A program's window"): the
clipboard, or the display's error, with every fid the attempt made clunked.
""".
-spec clipboard_open(atom(), non_neg_integer()) -> {ok, clipboard()} | {error, atom()}.
clipboard_open(Display, Flags) when is_atom(Display), is_integer(Flags), Flags >= 0 ->
    maybe
        {ok, Tree, Fid} ?= clipboard_fid(Display),
        {ok, _Qid, _Iounit} ?= case one(Tree, {lopen, Fid, Flags}) of
                       {error, _} = Refused -> clunk(Tree, [Fid]), Refused;
                       Opened -> Opened
                   end,
        {ok, {Tree, Fid}}
    else
        {error, none} -> {error, enodev};
        {error, _} = Failed -> Failed
    end.

-doc "A read of `Count` bytes at `Offset` of the clipboard, as the display answers it.".
-spec clipboard_read(clipboard(), non_neg_integer(), non_neg_integer()) -> {ok, binary()} | {error, atom()}.
clipboard_read({Tree, Fid}, Offset, Count) ->
    one(Tree, {read, Fid, Offset, Count}).

-doc "A write of `Bytes` at `Offset` of the clipboard: `{ok, Count, Offset1}` as the display answers it.".
-spec clipboard_write(clipboard(), non_neg_integer(), binary()) ->
          {ok, non_neg_integer(), non_neg_integer()} | {error, atom()}.
clipboard_write({Tree, Fid}, Offset, Bytes) when is_binary(Bytes) ->
    one(Tree, {write, Fid, Offset, Bytes}).

-doc "Clunks the clipboard's fid.".
-spec clipboard_close(clipboard()) -> ok.
clipboard_close({Tree, Fid}) ->
    clunk(Tree, [Fid]).

%% A fid walked to the clipboard from a root attached for the walk alone, which
%% is clunked once the walk is answered; a walk that fails leaves no fid.
clipboard_fid(Display) ->
    case erx:cap(Display) of
        undefined ->
            {error, none};
        Grant ->
            Tree = {Grant, ?ERX_WINDOWS_TREE_BYTES, rw},
            Root = fid(),
            Fid = fid(),
            maybe
                {ok, _} ?= one(Tree, {attach, Root, ?ERX_P9_NOFID, <<>>, ?ERX_WINDOWS_TREE_BYTES, 0}),
                Walked = walked(one(Tree, {walk, Root, Fid, [?CLIPBOARD]}), 1),
                clunk(Tree, [Root]),
                ok ?= Walked,
                {ok, Tree, Fid}
            end
    end.

-doc "Reads one `mouse` record, waiting for one.".
-spec mouse(window()) -> {ok, erx_win_core:pointer()} | {error, atom()}.
mouse(Window) ->
    read_with(Window, mouse, ?ERX_WINDOWS_MOUSE_RECORD, fun erx_win_core:mouse/1).

-doc "Reads one `kbd` record, waiting for one.".
-spec kbd(window()) -> {ok, erx_win_core:key()} | {error, atom()}.
kbd(Window) ->
    read_with(Window, kbd, ?KBD_READ, fun erx_win_core:kbd/1).

-doc """
After an `r` record: reads the window's rectangle again and answers the
window and an image at the new size over the same buffer, clipped to it,
or `none` for a window with no buffer.
""".
-spec resized(window()) -> {ok, window(), erx_memdraw:image() | none} | {error, atom()}.
resized(Window) ->
    maybe
        {ok, #{rect := Rect}} ?= placed(Window),
        Resized = Window#{rect := Rect},
        {ok, Image} ?= resized_image(Resized),
        {ok, Resized, Image}
    end.

resized_image(#{own := none}) -> {ok, none};
resized_image(Window) -> image(Window).

-doc "Asks the window's policy for the rectangle `Rect`; `einval` where it refuses.".
-spec resize(window(), erx_win_core:rect()) -> ok | {error, atom()}.
resize(Window, {X0, Y0, X1, Y1} = Rect) when is_integer(X0), is_integer(Y0), is_integer(X1),
                                             is_integer(Y1) ->
    write(Window, wctl, erx_win_core:resize(Rect)).

-doc "Replaces the window's label with `Label`.".
-spec label(window(), binary()) -> ok | {error, atom()}.
label(Window, Label) when is_binary(Label) ->
    write(Window, label, Label).

%% Opening --------------------------------------------------------------------

name(#{name := Name}) when is_binary(Name) -> Name;
name(#{}) -> <<"w", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

%% Whether the window allocates its own buffer: `alloc` unless the options say `none`.
allocation(#{buffer := none}) -> none;
allocation(Options) when not is_map_key(buffer, Options) -> alloc.

%% Attaches the root, makes the window and opens its files, then reads its channel and
%% place and allocates its buffer. A failure after the window is made removes it, through
%% a fid walked to the window's directory, which the grant removes only while the name
%% still names that window, so a refused open never removes a window another process
%% made under the same name.
open_on(Tree, Peer, Name, Allocation) ->
    Root = fid(),
    case one(Tree, {attach, Root, ?ERX_P9_NOFID, <<>>, ?ERX_WINDOWS_TREE_BYTES, 0}) of
        {ok, _} ->
            Answer = case one(Tree, {mkdir, Root, Name, 8#755, 0}) of
                         {ok, _} -> opened_window(Tree, Peer, Name, Root, Allocation);
                         {error, _} = Refused -> Refused
                     end,
            clunk(Tree, [Root]),
            Answer;
        {error, _} = Refused ->
            Refused
    end.

%% The window's directory was made: open it whole or remove it.
opened_window(Tree, Peer, Name, Root, Allocation) ->
    Dir = fid(),
    Fids = maps:from_list([{File, fid()} || {File, _} <- files()]),
    %% The handle as far as the files: what read_with/4 and placed/1 need.
    Files = #{tree => Tree, peer => Peer, name => Name, fids => Fids},
    Answer = maybe
                 ok ?= walked(one(Tree, {walk, Root, Dir, [Name]}), 1),
                 ok ?= open_files(Tree, Dir, Fids),
                 {ok, #{chan := Chan} = Display} ?= read_with(Files, ctl, ?ERX_WINDOWS_LINE_MAX, fun erx_win_core:ctl/1),
                 {ok, #{rect := Rect}} ?= placed(Files),
                 {ok, Own} ?= own(Allocation, Peer, Rect, Chan),
                 {ok, maps:merge(Files, Display#{own => Own, rect => Rect})}
             end,
    case Answer of
        {ok, _} ->
            clunk(Tree, [Dir]),
            Answer;
        {error, _} = Refused ->
            _ = one(Tree, {remove, Dir}),
            clunk(Tree, maps:values(Fids)),
            Refused
    end.

%% The window's own buffer at the window's size, allocated from the domain's pixel area,
%% or none. A range once allocated stays the caller's, as every range of erx_pixels does,
%% so the area is opened first.
own(none, _Peer, _Rect, _Chan) ->
    {ok, none};
own(alloc, Peer, {X0, Y0, X1, Y1}, #{depth := Depth}) ->
    maybe
        {ok, Bytes} ?= sized(erx_win_core:bytes(X1 - X0, Y1 - Y0, Depth)),
        {ok, Area, _} ?= erx_area:open(Peer),
        {ok, Offset} ?= erx_pixels:alloc(Peer, Bytes),
        {ok, #{area => Area, buffer => #{offset => Offset, width => X1 - X0, height => Y1 - Y0}}}
    end.

extent(#{width := Width, height := Height}) -> {Width, Height}.

%% A window's files as the ABI's windows_file lists them, each with the mode it is
%% opened in: the display serves mouse and kbd read-only.
files() -> [{File, open_mode(File)} || {File, _} <- ?ERX_WINDOWS_FILE_MEMBERS].

open_mode(File) when File =:= mouse; File =:= kbd -> ?O_RDONLY;
open_mode(_File) -> ?ERX_P9_O_RDWR.

open_files(Tree, Dir, Fids) ->
    Requests = lists:append([[{walk, Dir, maps:get(File, Fids), [atom_to_binary(File)]},
                              {lopen, maps:get(File, Fids), Flags}] || {File, Flags} <- files()]),
    Replies = erx_file_remote:exchange(Tree, Requests),
    Walks = [walked(Reply, 1) || {Reply, {walk, _, _, _}} <- lists:zip(Replies, Requests)],
    case [Error || {error, _} = Error <- Walks ++ Replies] of
        [] -> ok;
        [First | _] -> First
    end.

%% A walk that passed fewer names than it named made no fid: 9P's answer for a name
%% that is not there.
walked({ok, Qids}, Names) when length(Qids) =:= Names -> ok;
walked({ok, _}, _) -> {error, enoent};
walked({error, _} = Refused, _) -> Refused.

%% A window of no pixels on a side, as an unplaced window's wctl reads, has no buffer;
%% the reader already refuses a side past 16,384.
sized({ok, _} = Bytes) -> Bytes;
sized({error, einval}) -> {error, eio}.

clunk(Tree, Fids) ->
    _ = erx_file_remote:exchange(Tree, [{clunk, Fid} || Fid <- Fids]),
    ok.

fid() ->
    prim_file:erx_fid().

%% Files ----------------------------------------------------------------------

placed(Window) ->
    read_with(Window, wctl, ?ERX_WINDOWS_LINE_MAX, fun erx_win_core:wctl/1).

read_with(#{tree := Tree, fids := Fids}, File, Count, Reader) ->
    case one(Tree, {read, maps:get(File, Fids), 0, Count}) of
        {ok, Bytes} -> Reader(Bytes);
        {error, _} = Refused -> Refused
    end.

%% One write of Data whole; a display that takes less than all of it answers outside the
%% file's format.
write(#{tree := Tree, fids := Fids}, File, Data) ->
    Size = byte_size(Data),
    case one(Tree, {write, maps:get(File, Fids), 0, Data}) of
        {ok, Size, _} -> ok;
        {ok, _, _} -> {error, eio};
        {error, _} = Refused -> Refused
    end.

one(Tree, Request) ->
    [Reply] = erx_file_remote:exchange(Tree, [Request]),
    Reply.
