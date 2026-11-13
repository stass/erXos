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
channel, the buffer and the window's rectangle. The handle is the
caller's: its fids are owned by the caller, so only the caller uses it.

`image/1` answers an `erx_memdraw` image over the buffer at the window's
size, clipped to the buffer; `present/2` writes a present of rectangles of
that image and waits for its answer; `mouse/1` and `kbd/1` read one record
each, waiting for one; `resized/1`, after an `r` record, reads the
window's rectangle again and answers an image at the new size over the
same buffer, clipped to it, allocating nothing; `resize/2` and `label/2`
write `wctl` and `label`.

Every request to the display passes `erx_file_remote:exchange/2`, which
holds it to the file protocol's grammar and each reply to its request, and
every answer read back passes a reader of `erx_win_core`, so a display's
bytes reach the caller only as a checked term or `{error, eio}`.

**The screen's size.** The window tree names no file that answers the
screen's size, so `open/2` takes it from the new window's rectangle, which
the single policy sets to the screen's (TODO.md, the window tree's
screen size); for the same reason the buffer is allocated after the
window is made, and an area with no room answers `{error, enomem}` after
the `windows` quota rather than before it.
""".

-include("generated/erx_abi.hrl").

-export([open/2, image/1, present/2, mouse/1, kbd/1, resized/1, resize/2, label/2]).
-export_type([window/0, options/0]).

-define(O_RDONLY, 0).
%% A kbd record is at most a kind byte, the runes of a read's worth and a NUL; a read
%% of the display's whole queue takes any record it holds.
-define(KBD_READ, ?ERX_WINDOWS_QUEUE_BYTES).

-doc "What `open/2` takes: `name`, the window's directory, else a name of its own.".
-type options() :: #{name => binary()}.

-doc "A window, as `open/2` answers it; its fields are this module's.".
-opaque window() :: #{tree := {pid(), binary(), rw},
                      peer := non_neg_integer(),
                      name := binary(),
                      fids := #{ctl | mouse | kbd | wctl | label => non_neg_integer()},
                      chan := erx_win_core:chan(),
                      area := term(),
                      buffer := #{offset := non_neg_integer(), width := pos_integer(),
                                  height := pos_integer()},
                      rect := erx_win_core:rect()}.

-doc """
Makes a window on the display `Display`, the name of its grant in this
domain's registry, with the caller as holder. `{error, none}` when the
domain holds no grant of that name or has no pixel area to the display,
`{error, enomem}` when the area has no room for the buffer, `{error, eio}`
for an answer of the display outside its format, and the file protocol's
error of a request it refuses, such as `eexist` for a name in use and
`edquot` past the grant's `windows`.
""".
-spec open(atom(), options()) -> {ok, window()} | {error, atom()}.
open(Display, Options) when is_atom(Display), is_map(Options) ->
    case erx:cap(Display) of
        undefined -> {error, none};
        Grant -> open_on({Grant, ?ERX_WINDOWS_TREE_BYTES, rw}, erx:owner(Grant), name(Options))
    end.

-doc "An image over the window's buffer at the window's size, clipped to the buffer.".
-spec image(window()) -> {ok, erx_memdraw:image()} | {error, einval | enomem}.
image(#{area := Area, buffer := #{offset := Offset, width := Width, height := Height},
        chan := #{code := Code}, rect := Rect}) ->
    erx_memdraw:wrap(Area, Offset, erx_win_core:image_rect(Rect, {Width, Height}), Code).

-doc """
Presents the rectangles `Rects` of the window's image, all of it for `[]`,
and waits for the display's answer.
""".
-spec present(window(), [erx_win_core:rect()]) -> ok | {error, atom()}.
present(#{buffer := #{offset := Offset, width := Width, height := Height}, rect := Rect} = Window,
        Rects) when is_list(Rects) ->
    {0, 0, X1, Y1} = erx_win_core:image_rect(Rect, {Width, Height}),
    write(Window, ctl, erx_win_core:present(Offset, X1, Y1, Rects)).

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
window and an image at the new size over the same buffer, clipped to it.
""".
-spec resized(window()) -> {ok, window(), erx_memdraw:image()} | {error, atom()}.
resized(Window) ->
    maybe
        {ok, #{rect := Rect}} ?= placed(Window),
        Resized = Window#{rect := Rect},
        {ok, Image} ?= image(Resized),
        {ok, Resized, Image}
    end.

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

%% Attaches the root, makes the window and opens its files, then reads its channel and
%% place and allocates its buffer. A failure after the window is made removes it, through
%% a fid walked to the window's directory, which the grant removes only while the name
%% still names that window, so a refused open never removes a window another process
%% made under the same name. A buffer once allocated stays the caller's, as every range
%% of erx_pixels does, so the area is opened first.
open_on(Tree, Peer, Name) ->
    Root = fid(),
    case one(Tree, {attach, Root, ?ERX_P9_NOFID, <<>>, ?ERX_WINDOWS_TREE_BYTES, 0}) of
        {ok, _} ->
            Answer = case one(Tree, {mkdir, Root, Name, 8#755, 0}) of
                         {ok, _} -> opened_window(Tree, Peer, Name, Root);
                         {error, _} = Refused -> Refused
                     end,
            clunk(Tree, [Root]),
            Answer;
        {error, _} = Refused ->
            Refused
    end.

%% The window's directory was made: open it whole or remove it.
opened_window(Tree, Peer, Name, Root) ->
    Dir = fid(),
    Fids = maps:from_list([{File, fid()} || {File, _} <- files()]),
    %% The handle as far as the files: what read_with/4 and placed/1 need.
    Files = #{tree => Tree, peer => Peer, name => Name, fids => Fids},
    Answer = maybe
                 ok ?= walked(one(Tree, {walk, Root, Dir, [Name]}), 1),
                 ok ?= open_files(Tree, Dir, Fids),
                 {ok, Chan} ?= read_with(Files, ctl, ?ERX_WINDOWS_LINE_MAX, fun erx_win_core:ctl/1),
                 {ok, #{rect := {X0, Y0, X1, Y1} = Rect}} ?= placed(Files),
                 {ok, Bytes} ?= sized(erx_win_core:bytes(X1 - X0, Y1 - Y0, maps:get(depth, Chan))),
                 {ok, Area, _} ?= erx_area:open(Peer),
                 {ok, Offset} ?= erx_pixels:alloc(Peer, Bytes),
                 {ok, Files#{chan => Chan, area => Area, rect => Rect,
                             buffer => #{offset => Offset, width => X1 - X0, height => Y1 - Y0}}}
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
