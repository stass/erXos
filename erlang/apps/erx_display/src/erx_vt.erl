%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_vt).
-moduledoc """
The terminal emulator's pure core (docs/design-display.md, "The terminal
emulator"): the model of one terminal, a grid of cells, a cursor, the
modes programs set and a scrollback, and the one function from that
model and the bytes a program wrote to the next model and what the
terminal must do.

feed/2 runs every byte through three stages. A UTF-8 decoder turns
bytes into code points, replacing each maximal ill-formed subsequence by
one U+FFFD. parse/2, Paul Williams's parser of DEC's ANSI-compatible
terminals run on code points, turns a code point into at most two
actions. act/2 carries out an action on the grid state, naming the
operation from the design's closed tables; a sequence outside them is
parsed to its end, dropped and counted by kind in `ignored/1`.

The bytes are a program's output and so untrusted. Every stage keeps
bounded state between calls: three pending UTF-8 bytes, 16 parameters
of at most 65,535, two intermediates, an OSC string of 4 KiB, six code
points a cell, 131,072 scrollback cells and 256 links; no atom is made
from input. The core reads no clock and no global state, and where the
bytes are split between calls does not matter.

The design's invariants are what check/1 tests, after every step of the
tests and the fuzz target: the cursor lies in the grid, every row has
the grid's width, every width-2 cell is followed by `wide_tail` and
every `wide_tail` follows one, the margins are ordered, and every bound
above holds.
""".

-export([new/2, feed/2, resize/3, paste/2, link_at/3]).
-export([size/1, grid/1, cursor/1, modes/1, context/1, scrollback/1, ignored/1, check/1, dump/1]).
-export_type([state/0, effect/0, cell/0, row/0]).

-type effect() :: {reply, binary()}     % bytes for the tty's input
                | bell
                | {title, binary()}.    % OSC 0 or 2 text, UTF-8
-type cell() :: {Chars :: [char(), ...], Width :: 1 | 2, attrs(), link_id()}
              | wide_tail.              % right half of a width-2 cell
-type attrs() :: {[flag()], Fg :: colour(), Bg :: colour()}.
-type flag() :: bold | dim | italic | underline | blink | inverse
              | invisible | strike.
-type colour() :: default | 0..255 | {0..255, 0..255, 0..255}.
-type link_id() :: none | pos_integer().
-type row() :: {Wrapped :: boolean(), Cells :: tuple()}.
-type grid() :: tuple().          % of row()
-type charset() :: us | dec | uk.
%% Row and column, 1-based, and the pending wrap: the cursor sits on the
%% last column with the next printed character due on the next row.
-type position() :: {pos_integer(), pos_integer(), boolean()}.

-define(MIN_COLS, 2).
-define(MAX_COLS, 640).
-define(MAX_ROWS, 256).
-define(MAX_PARAMS, 16).
-define(MAX_PARAM, 65535).
-define(MAX_INTERMEDIATES, 2).
-define(MAX_OSC, 4096).
-define(MAX_CHARS, 6).
-define(MAX_SCROLLBACK, 131072).
-define(MAX_LINKS, 256).
-define(DEFAULT_ATTRS, {[], default, default}).
-define(BLANK, {" ", 1, ?DEFAULT_ATTRS, none}).

%% The parser's state between code points: Williams's state and what the
%% sequence has collected so far. DCS's five states are one here, since
%% erx_vt stores nothing of a DCS string and every one of them leaves on
%% the same transitions.
-record(parser, {
    state = ground :: ground | escape | escape_intermediate | csi_entry
                    | csi_param | csi_intermediate | csi_ignore | dcs | osc | sos,
    private = none :: none | char(),
    intermediates = [] :: [char()] | overflow,
    params = [] :: [0..?MAX_PARAM],            % reversed
    count = 0 :: 0..?MAX_PARAMS,
    current = none :: none | empty | 0..?MAX_PARAM,
    %% Past the 4 KiB bound the text is dropped; an OSC 8 string keeps
    %% that it was one, since it still ends the open link.
    osc = <<>> :: binary() | overflow | link_overflow
}).

-record(modes, {
    cursor_keys = false :: boolean(),          % DECCKM
    keypad = false :: boolean(),               % DECKPAM
    insert = false :: boolean(),               % IRM
    newline = false :: boolean(),              % LNM
    origin = false :: boolean(),               % DECOM
    autowrap = true :: boolean(),              % DECAWM
    reverse = false :: boolean(),              % DECSCNM
    visible = true :: boolean(),               % DECTCEM
    paste = false :: boolean()                 % bracketed paste
}).

%% What DECSC saves, per grid.
-record(saved, {
    position = {1, 1, false} :: position(),
    pen = ?DEFAULT_ATTRS :: attrs(),
    origin = false :: boolean(),
    charsets = {us, us, g0} :: {charset(), charset(), g0 | g1}
}).

-record(vt, {
    cols :: ?MIN_COLS..?MAX_COLS,
    rows :: 1..?MAX_ROWS,
    main :: grid(),
    alt :: grid(),
    shown = main :: main | alt,
    scrollback = queue:new() :: queue:queue(row()),
    scrollback_cells = 0 :: non_neg_integer(),
    cursor = {1, 1, false} :: position(),
    pen = ?DEFAULT_ATTRS :: attrs(),
    link = none :: link_id(),
    modes = #modes{} :: #modes{},
    margins :: {pos_integer(), pos_integer()},
    tabs :: ordsets:ordset(pos_integer()),
    charsets = {us, us, g0} :: {charset(), charset(), g0 | g1},
    saved = {#saved{}, #saved{}} :: {#saved{}, #saved{}},   % main's, alt's
    links = #{} :: #{pos_integer() => {binary(), binary()}},
    next_link = 1 :: pos_integer(),
    context = [] :: [binary()],
    utf8 = <<>> :: binary(),
    parser = #parser{} :: #parser{},
    %% The cell a width-0 code point joins: the grid, the cell's row and
    %% column, and the cursor and row as printing left them. It joins only
    %% while the row is unchanged and no action has moved the cursor.
    last = none :: none | {main | alt, pos_integer(), pos_integer(), position(), row()},
    ignored = #{} :: #{atom() => pos_integer()},
    out = [] :: [effect()]                     % this call's effects, reversed
}).

-opaque state() :: #vt{}.

%%% The interface

-doc "A terminal of Cols columns and Rows rows in its initial state.".
-spec new(?MIN_COLS..?MAX_COLS, 1..?MAX_ROWS) -> state().
new(Cols, Rows) when is_integer(Cols), Cols >= ?MIN_COLS, Cols =< ?MAX_COLS,
                     is_integer(Rows), Rows >= 1, Rows =< ?MAX_ROWS ->
    #vt{cols = Cols, rows = Rows, main = blank_grid(Cols, Rows, ?BLANK),
        alt = blank_grid(Cols, Rows, ?BLANK), margins = {1, Rows},
        tabs = default_tabs(1, Cols)}.

-doc "Runs Bytes through the terminal, returning its next state and its effects in order.".
-spec feed(state(), binary()) -> {state(), [effect()]}.
feed(#vt{utf8 = Pending} = VT, Bytes) when is_binary(Bytes) ->
    Done = decode(<<Pending/binary, Bytes/binary>>, VT#vt{utf8 = <<>>, out = []}),
    {Done#vt{out = []}, lists:reverse(Done#vt.out)}.

-doc """
The terminal at a new size: rows keep their contents without reflowing.
A shorter grid sends the rows above the cursor to the scrollback as far
as keeping the cursor's row needs, then drops rows from the bottom; a
narrower one crops each row. The region becomes the whole grid and the
cursor and saved cursors are clamped into it.
""".
-spec resize(state(), ?MIN_COLS..?MAX_COLS, 1..?MAX_ROWS) -> state().
resize(#vt{cursor = {Row, Col, _}, saved = {Main, Alt}} = VT0, Cols, Rows)
  when is_integer(Cols), Cols >= ?MIN_COLS, Cols =< ?MAX_COLS,
       is_integer(Rows), Rows >= 1, Rows =< ?MAX_ROWS ->
    %% The hidden grid keeps the row its saved cursor names.
    {MainRow, AltRow} = case VT0#vt.shown of
                            main -> {Row, row_of(Alt)};
                            alt -> {row_of(Main), Row}
                        end,
    {MainGrid, Lifted, MainShift} = fit_rows(VT0#vt.main, MainRow, Rows, VT0#vt.cols),
    {AltGrid, _, AltShift} = fit_rows(VT0#vt.alt, AltRow, Rows, VT0#vt.cols),
    VT1 = push_scrollback(Lifted, VT0),
    Shift = case VT0#vt.shown of main -> MainShift; alt -> AltShift end,
    Clamp = fun({R, C, _}) -> {clamp(R, 1, Rows), clamp(C, 1, Cols), false} end,
    VT1#vt{cols = Cols, rows = Rows,
           main = fit_cols(MainGrid, Cols), alt = fit_cols(AltGrid, Cols),
           cursor = Clamp({Row - Shift, Col, false}),
           saved = {Main#saved{position = Clamp(Main#saved.position)},
                    Alt#saved{position = Clamp(Alt#saved.position)}},
           margins = {1, Rows},
           tabs = ordsets:union([T || T <- VT0#vt.tabs, T =< Cols],
                                default_tabs(VT0#vt.cols + 1, Cols)),
           last = none}.

-doc """
The bytes a paste or a presentation click sends: Bytes unchanged, or
with bracketed paste set, between `CSI 200 ~` and `CSI 201 ~` with every
`CSI 201 ~` inside removed, in its 7-bit and its UTF-8 C1 form, until
none is left, so pasted text cannot end its own bracket.
""".
-spec paste(state(), binary()) -> binary().
paste(#vt{modes = #modes{paste = false}}, Bytes) when is_binary(Bytes) ->
    Bytes;
paste(#vt{modes = #modes{paste = true}}, Bytes) when is_binary(Bytes) ->
    <<"\e[200~", (strip_paste_end(Bytes))/binary, "\e[201~">>.

-doc """
The type and text of the link under the cell at Row and Column, the
right half of a width-2 cell being its left half's, or `none`, also for
a place outside the grid such as the window's margin.
""".
-spec link_at(state(), integer(), integer()) -> none | {binary(), binary()}.
link_at(#vt{rows = Rows, cols = Cols} = VT, Row, Col)
  when is_integer(Row), Row >= 1, Row =< Rows, is_integer(Col), Col >= 1, Col =< Cols ->
    case element(Col, cells(VT, Row)) of
        {_, _, _, Id} when is_integer(Id) -> maps:get(Id, VT#vt.links, none);
        wide_tail -> link_at(VT, Row, Col - 1);
        _ -> none
    end;
link_at(_VT, _Row, _Col) ->
    none.

-doc "The grid's size.".
-spec size(state()) -> {Cols :: pos_integer(), Rows :: pos_integer()}.
size(#vt{cols = Cols, rows = Rows}) -> {Cols, Rows}.

-doc "The shown grid: a tuple of rows, each `{Wrapped, Cells}`.".
-spec grid(state()) -> grid().
grid(VT) -> shown(VT).

-doc "The cursor's row and column and whether it is visible.".
-spec cursor(state()) -> {pos_integer(), pos_integer(), boolean()}.
cursor(#vt{cursor = {Row, Col, _}, modes = #modes{visible = Visible}}) -> {Row, Col, Visible}.

-doc "The modes erx_term reads to draw and to encode keys.".
-spec modes(state()) -> #{atom() => boolean()}.
modes(#vt{modes = M, shown = Shown}) ->
    #{cursor_keys => M#modes.cursor_keys, keypad => M#modes.keypad,
      reverse_screen => M#modes.reverse, bracketed_paste => M#modes.paste,
      alternate_screen => Shown =:= alt}.

-doc "The scrollback's rows, oldest first, each without its trailing blank default cells.".
-spec scrollback(state()) -> [row()].
scrollback(#vt{scrollback = Queue}) -> queue:to_list(Queue).

-doc "How many sequences of each kind were parsed and dropped.".
-spec ignored(state()) -> #{atom() => pos_integer()}.
ignored(#vt{ignored = Ignored}) -> Ignored.

-doc "The presentation types of the input context, which links of those types highlight.".
-spec context(state()) -> [binary()].
context(#vt{context = Context}) -> Context.

-doc """
The shown screen in the dump format of design-display.md's oracle, which
test/vt/vterm_dump.c writes for libvterm too, ASCII:

    size COLS ROWS
    cursor ROW COL WRAP VISIBLE    WRAP: wrap | -, VISIBLE: shown | hidden
    row N W CELL ...               W: w if the row continues into the next

A cell is its code points in lower-case hex joined by `+`, `-` for the
right half of a width-2 cell, then, unless its attributes are the
default, `/FLAGS:FG:BG`: FLAGS from `bdikrhsu` (bold, dim, italic, blink,
inverse, invisible, strike, underline) or `-`, and each colour `-`, an
index, or `#rrggbb`. The last row carries no W, which libvterm keeps on
the row below.
""".
-spec dump(state()) -> binary().
dump(#vt{cols = Cols, rows = Rows, cursor = {Row, Col, Pending}, modes = M} = VT) ->
    Grid = shown(VT),
    Lines = [io_lib:format("size ~b ~b\n", [Cols, Rows]),
             io_lib:format("cursor ~b ~b ~s ~s\n",
                           [Row, Col, mark(Pending, "wrap"), visibility(M#modes.visible)])
             | [dump_row(N, element(N, Grid), N < Rows) || N <- lists:seq(1, Rows)]],
    iolist_to_binary(Lines).

dump_row(N, {Wrapped, Cells}, NotLast) ->
    [io_lib:format("row ~b ~s", [N, mark(Wrapped andalso NotLast, "w")]),
     [[$\s, dump_cell(Cell)] || Cell <- tuple_to_list(Cells)], $\n].

mark(true, Text) -> Text;
mark(false, _Text) -> "-".

visibility(true) -> "shown";
visibility(false) -> "hidden".

dump_cell(wide_tail) ->
    "-";
dump_cell({Chars, _Width, Attrs, _Link}) ->
    Points = lists:join($+, [integer_to_list(P, 16) || P <- Chars]),
    case Attrs of
        ?DEFAULT_ATTRS -> string:lowercase(Points);
        {Flags, Fg, Bg} ->
            Letters = [L || {L, F} <- [{$b, bold}, {$d, dim}, {$i, italic}, {$k, blink}, {$r, inverse},
                                       {$h, invisible}, {$s, strike}, {$u, underline}],
                            lists:member(F, Flags)],
            [string:lowercase(Points), $/, case Letters of [] -> "-"; _ -> Letters end,
             $:, dump_colour(Fg), $:, dump_colour(Bg)]
    end.

dump_colour(default) -> "-";
dump_colour(N) when is_integer(N) -> integer_to_list(N);
dump_colour({R, G, B}) -> io_lib:format("#~2.16.0b~2.16.0b~2.16.0b", [R, G, B]).

-doc "`ok` if the state holds every invariant of the design, else the first it breaks.".
-spec check(state()) -> ok | {error, atom()}.
check(VT) ->
    case [Name || {Name, false} <- invariants(VT)] of
        [] -> ok;
        [First | _] -> {error, First}
    end.

invariants(#vt{cols = Cols, rows = Rows, cursor = {Row, Col, _}, margins = {Top, Bottom}} = VT) ->
    [{cursor_outside_grid, Row >= 1 andalso Row =< Rows andalso Col >= 1 andalso Col =< Cols},
     {margins_unordered, 1 =< Top andalso Top < Bottom andalso Bottom =< Rows
                             orelse Rows =:= 1 andalso Top =:= 1 andalso Bottom =:= 1},
     {grid_shape, grid_shaped(VT#vt.main, Cols, Rows) andalso grid_shaped(VT#vt.alt, Cols, Rows)},
     {wide_cell_unpaired, grid_paired(VT#vt.main) andalso grid_paired(VT#vt.alt)},
     {cell_over_bound, cells_bounded(VT#vt.main) andalso cells_bounded(VT#vt.alt)},
     {scrollback_over_bound, VT#vt.scrollback_cells =< ?MAX_SCROLLBACK andalso
                                 VT#vt.scrollback_cells =:= lists:sum([charge(R) || R <- scrollback(VT)])},
     {links_over_bound, map_size(VT#vt.links) =< ?MAX_LINKS},
     {utf8_over_bound, byte_size(VT#vt.utf8) =< 3},
     {parser_over_bound, parser_bounded(VT#vt.parser)}].

%%% Stage 1: UTF-8 decoding

%% Each code point goes on to the parser as soon as it is decoded; a
%% well-formed sequence cut short at the end waits for the next call.
decode(<<>>, VT) ->
    VT;
decode(Bytes, VT) ->
    case next_point(Bytes) of
        {Point, Rest} -> decode(Rest, step(Point, VT));
        more -> VT#vt{utf8 = Bytes}
    end.

%% Unicode's table 3-7 of well-formed sequences: the lead byte gives the
%% length and the range of the second byte; later bytes are 80..BF. An
%% ill-formed sequence gives one U+FFFD for its maximal well-formed prefix,
%% and decoding resumes at the byte that broke it.
next_point(<<B, Rest/binary>>) when B < 16#80 -> {B, Rest};
next_point(<<B, _/binary>> = Bytes) when B >= 16#C2, B =< 16#DF -> sequence(Bytes, 2, 16#80, 16#BF);
next_point(<<16#E0, _/binary>> = Bytes) -> sequence(Bytes, 3, 16#A0, 16#BF);
next_point(<<16#ED, _/binary>> = Bytes) -> sequence(Bytes, 3, 16#80, 16#9F);
next_point(<<B, _/binary>> = Bytes) when B >= 16#E1, B =< 16#EF -> sequence(Bytes, 3, 16#80, 16#BF);
next_point(<<16#F0, _/binary>> = Bytes) -> sequence(Bytes, 4, 16#90, 16#BF);
next_point(<<16#F4, _/binary>> = Bytes) -> sequence(Bytes, 4, 16#80, 16#8F);
next_point(<<B, _/binary>> = Bytes) when B >= 16#F1, B =< 16#F3 -> sequence(Bytes, 4, 16#80, 16#BF);
next_point(<<_, Rest/binary>>) -> {16#FFFD, Rest}.

sequence(<<Lead, Tail/binary>>, Length, Low, High) ->
    continuation(Tail, Length - 1, Low, High, Lead band (16#FF bsr (Length + 1)), 1).

continuation(Rest, 0, _Low, _High, Value, _Taken) ->
    {Value, Rest};
continuation(<<>>, _Left, _Low, _High, _Value, _Taken) ->
    more;
continuation(<<B, Rest/binary>>, Left, Low, High, Value, Taken) when B >= Low, B =< High ->
    continuation(Rest, Left - 1, 16#80, 16#BF, (Value bsl 6) bor (B band 16#3F), Taken + 1);
continuation(Rest, _Left, _Low, _High, _Value, _Taken) ->
    {16#FFFD, Rest}.

%%% Stage 2: the DEC parser

step(Point, #vt{parser = P0} = VT) ->
    {P, Actions} = parse(P0, Point),
    lists:foldl(fun act/2, VT#vt{parser = P}, Actions).

%% CAN and SUB cancel any sequence, a string's text with it; ESC begins a
%% new sequence from any state, ending a string; a C1 control acts from any
%% state. A string ends by dispatching, unless cancelled.
-spec parse(#parser{}, char()) -> {#parser{}, [term()]}.
parse(_P, Point) when Point =:= 16#18; Point =:= 16#1A ->
    {#parser{}, []};
parse(P, 16#1B) ->
    {#parser{state = escape}, ended(P)};
parse(P, Point) when Point >= 16#80, Point =< 16#9F ->
    c1(Point, ended(P));
parse(#parser{state = State} = P, Point) ->
    in(State, Point, P).

ended(#parser{state = osc, osc = Text}) -> [{osc, Text}];
ended(_) -> [].

c1(16#90, Before) -> {#parser{state = dcs}, Before ++ [{ignored, string}]};
c1(16#9B, Before) -> {#parser{state = csi_entry}, Before};
c1(16#9C, Before) -> {#parser{}, Before};
c1(16#9D, Before) -> {#parser{state = osc}, Before};
c1(Point, Before) when Point =:= 16#98; Point =:= 16#9E; Point =:= 16#9F ->
    {#parser{state = sos}, Before ++ [{ignored, string}]};
c1(Point, Before) -> {#parser{}, Before ++ [{execute, Point}]}.

%% DEL, and a code point past ASCII inside a sequence, are ignored where
%% they arrive.
in(ground, Point, P) when Point < 16#20 -> {P, [{execute, Point}]};
in(ground, 16#7F, P) -> {P, []};
in(ground, Point, P) -> {P, [{print, Point}]};
in(State, Point, P) when Point < 16#20, State =/= dcs, State =/= osc, State =/= sos ->
    {P, [{execute, Point}]};
in(State, Point, P) when Point >= 16#7F, State =/= osc ->
    {P, []};
in(escape, Point, P) when Point =< 16#2F -> {collect(P, Point, escape_intermediate), []};
in(escape, Point, _P) when Point >= 16#40, Point =< 16#5F -> c1(Point + 16#40, []);
in(escape, Point, _P) -> {#parser{}, [{esc, [], Point}]};
in(escape_intermediate, Point, P) when Point =< 16#2F -> {collect(P, Point, escape_intermediate), []};
in(escape_intermediate, _Point, #parser{intermediates = overflow}) ->
    {#parser{}, [{ignored, esc}]};
in(escape_intermediate, Point, #parser{intermediates = Inter}) ->
    {#parser{}, [{esc, lists:reverse(Inter), Point}]};
in(csi_entry, Point, P) when Point >= 16#3C, Point =< 16#3F ->
    {P#parser{state = csi_param, private = Point}, []};
in(State, Point, P) when (State =:= csi_entry orelse State =:= csi_param),
                         (Point >= $0 andalso Point =< $9 orelse Point =:= $;) ->
    {param(P#parser{state = csi_param}, Point), []};
in(State, Point, P) when State =:= csi_entry; State =:= csi_param; State =:= csi_intermediate ->
    if
        Point =< 16#2F -> {collect(P, Point, csi_intermediate), []};
        Point =< 16#3F -> {P#parser{state = csi_ignore}, []};
        true -> {#parser{}, [csi_action(P, Point)]}
    end;
in(csi_ignore, Point, _P) when Point >= 16#40 -> {#parser{}, [{ignored, csi}]};
in(csi_ignore, _Point, P) -> {P, []};
in(osc, 16#07, #parser{osc = Text}) -> {#parser{}, [{osc, Text}]};
in(osc, Point, P) when Point < 16#20; Point =:= 16#7F -> {P, []};
in(osc, Point, P) -> {P#parser{osc = osc_append(P#parser.osc, Point)}, []};
in(State, _Point, P) when State =:= dcs; State =:= sos -> {P, []}.

collect(#parser{intermediates = overflow} = P, _Point, State) ->
    P#parser{state = State};
collect(#parser{intermediates = Inter} = P, _Point, State) when length(Inter) >= ?MAX_INTERMEDIATES ->
    P#parser{state = State, intermediates = overflow};
collect(#parser{intermediates = Inter} = P, Point, State) ->
    P#parser{state = State, intermediates = [Point | Inter]}.

%% A digit grows the current parameter, clamped at 65,535; a `;` closes it,
%% an empty one being 0. Past 16 closed parameters the rest are dropped.
param(#parser{current = none} = P, $;) ->
    param(P#parser{current = empty}, $;);
param(P, $;) ->
    (close_param(P))#parser{current = empty};
param(#parser{current = Current} = P, Digit) ->
    Value = case Current of
                N when is_integer(N) -> min(N * 10 + (Digit - $0), ?MAX_PARAM);
                _ -> Digit - $0
            end,
    P#parser{current = Value}.

close_param(#parser{current = none} = P) -> P;
close_param(#parser{count = Count} = P) when Count >= ?MAX_PARAMS -> P#parser{current = none};
close_param(#parser{params = Params, count = Count, current = Current} = P) ->
    Value = case Current of empty -> 0; N -> N end,
    P#parser{params = [Value | Params], count = Count + 1, current = none}.

csi_action(#parser{intermediates = overflow}, _Final) ->
    {ignored, csi};
csi_action(P, Final) ->
    #parser{private = Private, intermediates = Inter, params = Params} = close_param(P),
    {csi, Private, lists:reverse(Inter), lists:reverse(Params), Final}.

%% Near the bound the next code point, at most four bytes, may cross it.
osc_append(overflow, _Point) -> overflow;
osc_append(link_overflow, _Point) -> link_overflow;
osc_append(Text, Point) when byte_size(Text) >= ?MAX_OSC - 3 ->
    case <<Text/binary, Point/utf8>> of
        <<"8;", _/binary>> = Longer when byte_size(Longer) > ?MAX_OSC -> link_overflow;
        Longer when byte_size(Longer) > ?MAX_OSC -> overflow;
        Longer -> Longer
    end;
osc_append(Text, Point) -> <<Text/binary, Point/utf8>>.

%%% Stage 3: the actions

%% A width-0 code point joins the last cell written only if nothing has
%% moved the cursor since, so an action that moves it forgets that cell.
act({print, Point}, VT) ->
    print(Point, VT);
act(Action, #vt{cursor = Cursor} = VT0) ->
    case operate(Action, VT0) of
        #vt{cursor = Cursor} = VT -> VT;
        VT -> VT#vt{last = none}
    end.

operate({execute, Point}, VT) -> control(Point, VT);
operate({esc, Inter, Final}, VT) -> esc(Inter, Final, VT);
operate({csi, Private, Inter, Params, Final}, VT) -> csi(Private, Inter, Params, Final, VT);
operate({osc, Text}, VT) -> osc(Text, VT);
operate({ignored, Kind}, VT) -> count(Kind, VT).

count(Kind, #vt{ignored = Ignored} = VT) ->
    VT#vt{ignored = maps:update_with(Kind, fun(N) -> N + 1 end, 1, Ignored)}.

emit(Effect, #vt{out = Out} = VT) -> VT#vt{out = [Effect | Out]}.

%% C0 and C1 controls.
control(16#07, VT) -> emit(bell, VT);
control(16#08, #vt{cursor = {Row, Col, _}} = VT) -> move(VT, Row, max(Col - 1, 1));
control(16#09, VT) -> tab_forward(1, VT);
control(Point, #vt{modes = #modes{newline = true}} = VT) when Point >= 16#0A, Point =< 16#0C ->
    carriage_return(index(VT));
control(Point, VT) when Point >= 16#0A, Point =< 16#0C -> index(VT);
control(16#0D, VT) -> carriage_return(VT);
control(16#0E, #vt{charsets = {G0, G1, _}} = VT) -> VT#vt{charsets = {G0, G1, g1}};
control(16#0F, #vt{charsets = {G0, G1, _}} = VT) -> VT#vt{charsets = {G0, G1, g0}};
control(16#84, VT) -> index(VT);                           % IND
control(16#85, VT) -> carriage_return(index(VT));          % NEL
control(16#88, #vt{cursor = {_, Col, _}, tabs = Tabs} = VT) ->   % HTS
    VT#vt{tabs = ordsets:add_element(Col, Tabs)};
control(16#8D, VT) -> reverse_index(VT);                   % RI
control(Point, VT) when Point >= 16#80 -> count(c1, VT);
control(_Point, VT) -> VT.

esc([], $7, VT) -> save_cursor(VT);
esc([], $8, VT) -> restore_cursor(VT);
esc([], $c, VT) -> full_reset(VT);
esc([], $=, #vt{modes = M} = VT) -> VT#vt{modes = M#modes{keypad = true}};
esc([], $>, #vt{modes = M} = VT) -> VT#vt{modes = M#modes{keypad = false}};
esc([Slot], Final, #vt{charsets = {G0, G1, GL}} = VT) when Slot =:= $(; Slot =:= $) ->
    case charset(Final) of
        none -> count(esc, VT);
        Set when Slot =:= $( -> VT#vt{charsets = {Set, G1, GL}};
        Set -> VT#vt{charsets = {G0, Set, GL}}
    end;
esc("#", $8, VT) -> alignment(VT);
esc("%", $G, VT) -> VT;
esc(_Inter, _Final, VT) -> count(esc, VT).

charset($B) -> us;
charset($0) -> dec;
charset($A) -> uk;
charset(_) -> none.

%% CSI sequences. A missing or zero parameter takes the default where the
%% default is 1 (arg/2).
csi(none, [], Params, Final, VT) -> csi(Final, Params, VT);
csi($?, [], Params, $h, VT) -> lists:foldl(fun(M, V) -> dec_mode(M, true, V) end, VT, Params);
csi($?, [], Params, $l, VT) -> lists:foldl(fun(M, V) -> dec_mode(M, false, V) end, VT, Params);
csi(none, "!", [], $p, VT) -> soft_reset(VT);
csi(_Private, _Inter, _Params, _Final, VT) -> count(csi, VT).

csi($@, Ps, VT) -> edit_row(VT, fun(L, C, B) -> insert_cells(L, C, arg(Ps, 1), B) end);
csi($A, Ps, VT) -> cursor_up(arg(Ps, 1), VT);
csi($B, Ps, VT) -> cursor_down(arg(Ps, 1), VT);
csi($C, Ps, VT) -> cursor_right(arg(Ps, 1), VT);
csi($D, Ps, #vt{cursor = {Row, Col, _}} = VT) -> move(VT, Row, max(Col - arg(Ps, 1), 1));
csi($E, Ps, VT) -> carriage_return(cursor_down(arg(Ps, 1), VT));
csi($F, Ps, VT) -> carriage_return(cursor_up(arg(Ps, 1), VT));
csi(Final, Ps, #vt{cursor = {Row, _, _}} = VT) when Final =:= $G; Final =:= $` ->
    move(VT, Row, arg(Ps, 1));
csi(Final, Ps, VT) when Final =:= $H; Final =:= $f ->
    #vt{cursor = {Row, _, _}} = VT1 = to_row(arg(Ps, 1), VT),
    move(VT1, Row, arg(tl_or_empty(Ps), 1));
csi($I, Ps, VT) -> tab_forward(arg(Ps, 1), VT);
csi($Z, Ps, VT) -> tab_back(arg(Ps, 1), VT);
csi($J, Ps, VT) -> erase_display(arg0(Ps), VT);
csi($K, Ps, VT) -> erase_line(arg0(Ps), VT);
csi($L, Ps, VT) -> insert_lines(arg(Ps, 1), VT);
csi($M, Ps, VT) -> delete_lines(arg(Ps, 1), VT);
csi($P, Ps, VT) -> edit_row(VT, fun(L, C, B) -> delete_cells(L, C, arg(Ps, 1), B) end);
csi($S, Ps, #vt{margins = {Top, Bottom}} = VT) when length(Ps) =< 1 ->
    scroll_up(VT, Top, Bottom, arg(Ps, 1), save);
csi($T, Ps, #vt{margins = {Top, Bottom}} = VT) when length(Ps) =< 1 ->
    scroll_down(VT, Top, Bottom, arg(Ps, 1));
csi($X, Ps, VT) -> edit_row(VT, fun(L, C, B) -> erase_cells(L, C, C + arg(Ps, 1) - 1, B) end);
csi($a, Ps, VT) -> cursor_right(arg(Ps, 1), VT);
csi($e, Ps, VT) -> cursor_down(arg(Ps, 1), VT);
csi($c, Ps, VT) when Ps =:= []; Ps =:= [0] -> emit({reply, <<"\e[?1;2c">>}, VT);
csi($d, Ps, VT) -> to_row(arg(Ps, 1), VT);
csi($g, Ps, #vt{cursor = {_, Col, _}, tabs = Tabs} = VT) ->
    case arg0(Ps) of
        0 -> VT#vt{tabs = ordsets:del_element(Col, Tabs)};
        3 -> VT#vt{tabs = []};
        _ -> count(csi, VT)
    end;
csi($h, Ps, VT) -> lists:foldl(fun(M, V) -> ansi_mode(M, true, V) end, VT, Ps);
csi($l, Ps, VT) -> lists:foldl(fun(M, V) -> ansi_mode(M, false, V) end, VT, Ps);
csi($m, Ps, VT) -> sgr(Ps, VT);
csi($n, [5], VT) -> emit({reply, <<"\e[0n">>}, VT);
csi($n, [6], #vt{cursor = {Row, Col, _}, margins = {Top, _}, modes = M} = VT) ->
    Shown = case M#modes.origin of true -> Row - Top + 1; false -> Row end,
    emit({reply, iolist_to_binary(io_lib:format("\e[~B;~BR", [Shown, Col]))}, VT);
csi($r, Ps, VT) -> set_margins(Ps, VT);
csi($s, [], VT) -> save_cursor(VT);
csi($u, [], VT) -> restore_cursor(VT);
csi(_Final, _Ps, VT) -> count(csi, VT).

arg([N | _], _Default) when N > 0 -> N;
arg(_, Default) -> Default.

arg0([N | _]) -> N;
arg0([]) -> 0.

tl_or_empty([_ | T]) -> T;
tl_or_empty([]) -> [].

%%% Modes

ansi_mode(4, On, #vt{modes = M} = VT) -> VT#vt{modes = M#modes{insert = On}};
ansi_mode(20, On, #vt{modes = M} = VT) -> VT#vt{modes = M#modes{newline = On}};
ansi_mode(_Mode, _On, VT) -> count(mode, VT).

dec_mode(1, On, #vt{modes = M} = VT) -> VT#vt{modes = M#modes{cursor_keys = On}};
dec_mode(5, On, #vt{modes = M} = VT) -> VT#vt{modes = M#modes{reverse = On}};
dec_mode(6, On, #vt{modes = M} = VT) -> home(VT#vt{modes = M#modes{origin = On}});
dec_mode(7, true, #vt{modes = M} = VT) -> VT#vt{modes = M#modes{autowrap = true}};
dec_mode(7, false, #vt{modes = M, cursor = {Row, Col, _}} = VT) ->
    VT#vt{modes = M#modes{autowrap = false}, cursor = {Row, Col, false}};
dec_mode(8, _On, VT) -> VT;
dec_mode(12, _On, VT) -> VT;
dec_mode(25, On, #vt{modes = M} = VT) -> VT#vt{modes = M#modes{visible = On}};
dec_mode(1049, true, #vt{shown = main} = VT) ->
    VT1 = save_cursor(VT),
    VT1#vt{shown = alt, alt = blank_grid(VT#vt.cols, VT#vt.rows, blank(VT)), last = none};
dec_mode(1049, false, #vt{shown = alt} = VT) ->
    restore_cursor(VT#vt{shown = main, last = none});
dec_mode(1049, _On, VT) -> VT;
dec_mode(2004, On, #vt{modes = M} = VT) -> VT#vt{modes = M#modes{paste = On}};
dec_mode(_Mode, _On, VT) -> count(mode, VT).

%%% SGR, applied left to right

sgr([], VT) -> VT#vt{pen = ?DEFAULT_ATTRS};
sgr(Ps, #vt{pen = Pen} = VT) -> sgr(Ps, Pen, VT).

sgr([], Pen, VT) -> VT#vt{pen = Pen};
sgr([0 | T], _Pen, VT) -> sgr(T, ?DEFAULT_ATTRS, VT);
sgr([P | T], Pen, VT) when P >= 1, P =< 9, P =/= 6 -> sgr(T, flag(Pen, on_flags(P), true), VT);
sgr([22 | T], Pen, VT) -> sgr(T, flag(Pen, [bold, dim], false), VT);
sgr([P | T], Pen, VT) when P >= 23, P =< 29, P =/= 26 -> sgr(T, flag(Pen, on_flags(P - 20), false), VT);
sgr([P | T], {F, _, Bg}, VT) when P >= 30, P =< 37 -> sgr(T, {F, P - 30, Bg}, VT);
sgr([P | T], {F, _, Bg}, VT) when P >= 90, P =< 97 -> sgr(T, {F, P - 82, Bg}, VT);
sgr([39 | T], {F, _, Bg}, VT) -> sgr(T, {F, default, Bg}, VT);
sgr([P | T], {F, Fg, _}, VT) when P >= 40, P =< 47 -> sgr(T, {F, Fg, P - 40}, VT);
sgr([P | T], {F, Fg, _}, VT) when P >= 100, P =< 107 -> sgr(T, {F, Fg, P - 92}, VT);
sgr([49 | T], {F, Fg, _}, VT) -> sgr(T, {F, Fg, default}, VT);
sgr([P | T], {F, Fg, Bg} = Pen, VT) when P =:= 38; P =:= 48; P =:= 58 ->
    case extended_colour(T) of
        {Colour, Rest} when P =:= 38 -> sgr(Rest, {F, Colour, Bg}, VT);
        {Colour, Rest} when P =:= 48 -> sgr(Rest, {F, Fg, Colour}, VT);
        {_Underline, Rest} -> sgr(Rest, Pen, VT);
        malformed -> VT#vt{pen = Pen}
    end;
sgr([59 | T], Pen, VT) -> sgr(T, Pen, VT);
sgr([_ | T], Pen, VT) -> sgr(T, Pen, count(sgr, VT)).

on_flags(1) -> [bold];
on_flags(2) -> [dim];
on_flags(3) -> [italic];
on_flags(4) -> [underline];
on_flags(5) -> [blink];
on_flags(7) -> [inverse];
on_flags(8) -> [invisible];
on_flags(9) -> [strike].

flag({Flags, Fg, Bg}, Names, true) -> {ordsets:union(Flags, ordsets:from_list(Names)), Fg, Bg};
flag({Flags, Fg, Bg}, Names, false) -> {ordsets:subtract(Flags, ordsets:from_list(Names)), Fg, Bg}.

extended_colour([5, N | Rest]) when N =< 255 -> {N, Rest};
extended_colour([2, R, G, B | Rest]) when R =< 255, G =< 255, B =< 255 -> {{R, G, B}, Rest};
extended_colour(_) -> malformed.

%%% Strings

osc(<<"0;", Title/binary>>, VT) -> emit({title, Title}, VT);
osc(<<"2;", Title/binary>>, VT) -> emit({title, Title}, VT);
osc(<<"8;", Rest/binary>>, VT) -> hyperlink(Rest, VT#vt{link = none});
osc(link_overflow, VT) -> count(link, VT#vt{link = none});
osc(_Text, VT) -> count(osc, VT).

%% Every OSC 8 string ends the open link first, by the caller. Then the
%% grammar of "Links and the input context": a closing, whose URI is
%% empty, does nothing more; an `erx:accept/` URI sets the input context;
%% any other `erx:` URI opens a link, read by erx_present:parse_uri/1
%% alone, so a link means here exactly what erx_render wrote. Anything
%% else, an `https:` URI among them, is counted and its text stays plain.
hyperlink(Rest, VT) ->
    maybe
        [Params, URI] ?= binary:split(Rest, <<";">>),
        true ?= link_params(Params),
        hyperlink_uri(URI, VT)
    else
        _ -> count(link, VT)
    end.

hyperlink_uri(<<>>, VT) ->
    VT;
hyperlink_uri(<<"erx:accept/", Types/binary>>, VT) ->
    case context_types(Types) of
        {ok, Names} -> VT#vt{context = Names};
        error -> count(link, VT)
    end;
hyperlink_uri(URI, VT) ->
    maybe
        {ok, Type, Value} ?= erx_present:parse_uri(URI),
        Text = erx_present:text(Type, Value),
        true ?= plain_text(Text),
        open_link(atom_to_binary(Type), Text, VT)
    else
        _ -> count(link, VT)
    end.

%% The types of an input context, each a presentation name; none clears it.
context_types(<<>>) ->
    {ok, []};
context_types(Types) ->
    Names = binary:split(Types, <<",">>, [global]),
    case lists:all(fun(Name) -> erx_present:type(Name) =/= error end, Names) of
        true -> {ok, [binary:copy(Name) || Name <- Names]};
        false -> error
    end.

%% A link's text is shown and handed to a command. erx_present writes
%% canonical text as printable ASCII, so that is what is admitted: no
%% control, and no bidirectional or invisible format character.
plain_text(Text) -> lists:all(fun(B) -> B >= 16#20 andalso B =< 16#7E end, binary_to_list(Text)).

%% Ids increase from 1 and RIS keeps the next one, so the table holds a
%% run of consecutive ids and the oldest is the one 256 below the new one.
open_link(Type, Text, #vt{links = Links, next_link = Id} = VT) ->
    Kept = maps:remove(Id - ?MAX_LINKS, Links),
    VT#vt{links = Kept#{Id => {Type, Text}}, next_link = Id + 1, link = Id}.

link_params(Params) -> lists:all(fun(B) -> B >= 16#20 andalso B =< 16#7E andalso B =/= $; end,
                                 binary_to_list(Params)).

%%% Printing

%% A printed ASCII code point goes through the invoked character set;
%% then a width-0 code point joins the last cell written and any other is
%% written at the cursor.
print(Point0, #vt{charsets = {G0, G1, GL}} = VT) ->
    Point = map_charset(case GL of g0 -> G0; g1 -> G1 end, Point0),
    case erx_vt_width:width(Point) of
        0 -> join(Point, VT);
        Width -> place(Point, Width, VT)
    end.

map_charset(dec, Point) when Point >= 16#5F, Point =< 16#7E ->
    element(Point - 16#5E, dec_special_graphics());
map_charset(uk, $#) -> 16#A3;
map_charset(_Set, Point) -> Point.

%% DEC Special Graphics from `_` to `~`: the VT100's blank, diamond,
%% checkerboard, control pictures, degree and plus-minus, the corners and
%% lines of its line drawing, the scan lines, and its comparison, pi,
%% not-equal, pound and centred-dot characters.
dec_special_graphics() ->
    {16#00A0, 16#25C6, 16#2592, 16#2409, 16#240C, 16#240D, 16#240A, 16#00B0,
     16#00B1, 16#2424, 16#240B, 16#2518, 16#2510, 16#250C, 16#2514, 16#253C,
     16#23BA, 16#23BB, 16#2500, 16#23BC, 16#23BD, 16#251C, 16#2524, 16#2534,
     16#252C, 16#2502, 16#2264, 16#2265, 16#03C0, 16#2260, 16#00A3, 16#00B7}.

join(Point, #vt{last = {Shown, Row, Col, Cursor, Line}, shown = Shown, cursor = Cursor} = VT) ->
    case row(VT, Row) of
        Line ->
            {Wrapped, Cells} = Line,
            case element(Col, Cells) of
                {Chars, Width, Attrs, Link} when length(Chars) < ?MAX_CHARS ->
                    New = {Wrapped, setelement(Col, Cells, {Chars ++ [Point], Width, Attrs, Link})},
                    (put_row(VT, Row, New))#vt{last = {Shown, Row, Col, Cursor, New}};
                _ -> VT
            end;
        _ -> VT
    end;
join(_Point, VT) ->
    VT.

place(Point, Width, VT0) ->
    VT1 = wrap_pending(VT0),
    #vt{cursor = {_, Col0, _}, cols = Cols, modes = M} = VT1,
    {VT2, Col} = if
                     Width =:= 2, Col0 =:= Cols, M#modes.autowrap -> {wrap(VT1), 1};
                     Width =:= 2, Col0 =:= Cols -> {VT1, Cols - 1};
                     true -> {VT1, Col0}
                 end,
    #vt{cursor = {Row, _, _}} = VT2,
    Blank = blank(VT2),
    Cell = {[Point], Width, VT2#vt.pen, VT2#vt.link},
    New = case Width of 1 -> [Cell]; 2 -> [Cell, wide_tail] end,
    VT3 = case M#modes.insert of
              true -> edit_row(VT2, fun(L, C, B) -> insert_cells(L, C, Width, B) end, Col);
              false -> VT2
          end,
    {Wrapped, Cells} = row(VT3, Row),
    Line = {Wrapped, write_cells(Cells, Col, New, Blank)},
    End = Col + Width - 1,
    Cursor = case End >= Cols of
                 true -> {Row, Cols, M#modes.autowrap};
                 false -> {Row, End + 1, false}
             end,
    (put_row(VT3, Row, Line))#vt{cursor = Cursor, last = {VT3#vt.shown, Row, Col, Cursor, Line}}.

%% With the wrap pending, the next character goes to the next row's first
%% column, and the row it left records that it continued.
wrap_pending(#vt{cursor = {_, _, true}, modes = #modes{autowrap = true}} = VT) -> wrap(VT);
wrap_pending(VT) -> VT.

wrap(#vt{cursor = {Row, _, _}} = VT) ->
    {_, Cells} = row(VT, Row),
    carriage_return(index(put_row(VT, Row, {true, Cells}))).

%% Writing over either half of a width-2 cell blanks the other half.
write_cells(Cells0, Col, New, Blank) ->
    Last = Col + length(New) - 1,
    Cells1 = case element(Col, Cells0) of
                 wide_tail -> setelement(Col - 1, Cells0, Blank);
                 _ -> Cells0
             end,
    Cells2 = case element(Last, Cells1) of
                 {_, 2, _, _} when Last < tuple_size(Cells1) -> setelement(Last + 1, Cells1, Blank);
                 _ -> Cells1
             end,
    {Cells, _} = lists:foldl(fun(Cell, {Acc, I}) -> {setelement(I, Acc, Cell), I + 1} end,
                             {Cells2, Col}, New),
    Cells.

%%% Cursor movement

move(#vt{cols = Cols} = VT, Row, Col) ->
    VT#vt{cursor = {Row, clamp(Col, 1, Cols), false}}.

carriage_return(#vt{cursor = {Row, _, _}} = VT) -> VT#vt{cursor = {Row, 1, false}}.

home(#vt{modes = #modes{origin = true}, margins = {Top, _}} = VT) -> VT#vt{cursor = {Top, 1, false}};
home(VT) -> VT#vt{cursor = {1, 1, false}}.

%% To a row given from the top, relative to the top margin and kept within
%% the region in origin mode.
to_row(N, #vt{modes = #modes{origin = true}, margins = {Top, Bottom}, cursor = {_, Col, _}} = VT) ->
    move(VT, clamp(Top + N - 1, Top, Bottom), Col);
to_row(N, #vt{rows = Rows, cursor = {_, Col, _}} = VT) ->
    move(VT, clamp(N, 1, Rows), Col).

%% Up and down stop at the margin when the cursor is inside the region, at
%% the screen's edge when it is outside.
cursor_up(N, #vt{cursor = {Row, Col, _}, margins = {Top, _}} = VT) ->
    Limit = case Row >= Top of true -> Top; false -> 1 end,
    move(VT, max(Row - N, Limit), Col).

cursor_down(N, #vt{cursor = {Row, Col, _}, margins = {_, Bottom}, rows = Rows} = VT) ->
    Limit = case Row =< Bottom of true -> Bottom; false -> Rows end,
    move(VT, min(Row + N, Limit), Col).

cursor_right(N, #vt{cursor = {Row, Col, _}} = VT) -> move(VT, Row, Col + N).

%% Down one row, scrolling the region at the bottom margin.
index(#vt{cursor = {Row, Col, _}, margins = {Top, Bottom}, rows = Rows} = VT) ->
    if
        Row =:= Bottom -> (scroll_up(VT, Top, Bottom, 1, save))#vt{cursor = {Row, Col, false}};
        Row < Rows -> VT#vt{cursor = {Row + 1, Col, false}};
        true -> VT#vt{cursor = {Row, Col, false}}
    end.

reverse_index(#vt{cursor = {Row, Col, _}, margins = {Top, Bottom}} = VT) ->
    if
        Row =:= Top -> (scroll_down(VT, Top, Bottom, 1))#vt{cursor = {Row, Col, false}};
        Row > 1 -> VT#vt{cursor = {Row - 1, Col, false}};
        true -> VT#vt{cursor = {Row, Col, false}}
    end.

tab_forward(0, VT) -> VT;
tab_forward(N, #vt{cursor = {Row, Col, _}, tabs = Tabs, cols = Cols} = VT) ->
    case [T || T <- Tabs, T > Col] of
        [T | _] when T < Cols -> tab_forward(N - 1, move(VT, Row, T));
        _ -> move(VT, Row, Cols)
    end.

tab_back(0, VT) -> VT;
tab_back(N, #vt{cursor = {Row, Col, _}, tabs = Tabs} = VT) ->
    case [T || T <- Tabs, T < Col] of
        [] -> move(VT, Row, 1);
        Before -> tab_back(N - 1, move(VT, Row, lists:last(Before)))
    end.

%%% Saving and resetting

save_cursor(#vt{shown = Shown, saved = {Main, Alt}} = VT) ->
    Saved = #saved{position = VT#vt.cursor, pen = VT#vt.pen,
                   origin = (VT#vt.modes)#modes.origin, charsets = VT#vt.charsets},
    VT#vt{saved = case Shown of main -> {Saved, Alt}; alt -> {Main, Saved} end}.

%% In origin mode the restored row is kept within the current region, as
%% every other move in origin mode is; a pending wrap is restored only
%% while autowrap is on, since only then can it take effect.
restore_cursor(#vt{shown = Shown, saved = {Main, Alt}, modes = M, margins = {Top, Bottom}} = VT) ->
    S = case Shown of main -> Main; alt -> Alt end,
    {Row, Col, Pending} = S#saved.position,
    Kept = case S#saved.origin of
               true -> clamp(Row, Top, Bottom);
               false -> Row
           end,
    VT#vt{cursor = {Kept, Col, Pending andalso M#modes.autowrap}, pen = S#saved.pen,
          charsets = S#saved.charsets, modes = M#modes{origin = S#saved.origin}}.

%% RIS: the state of new/2 at the current size, keeping the scrollback and
%% the counters. The link table empties and link ids keep increasing, so
%% the scrollback's links become plain text.
full_reset(#vt{cols = Cols, rows = Rows} = VT) ->
    Fresh = new(Cols, Rows),
    Fresh#vt{scrollback = VT#vt.scrollback, scrollback_cells = VT#vt.scrollback_cells,
             next_link = VT#vt.next_link, ignored = VT#vt.ignored, out = VT#vt.out,
             utf8 = VT#vt.utf8, parser = VT#vt.parser}.

%% DECSTR: modes, pen, margins, character sets and saved cursors to their
%% initial values; the grids, the grid shown and the cursor's place kept.
soft_reset(#vt{cursor = {Row, Col, _}, rows = Rows} = VT) ->
    VT#vt{modes = #modes{}, pen = ?DEFAULT_ATTRS, link = none, margins = {1, Rows},
          charsets = {us, us, g0}, saved = {#saved{}, #saved{}}, cursor = {Row, Col, false}}.

%% DECALN: the screen filled with `E`, the margins reset and the cursor home.
alignment(#vt{cols = Cols, rows = Rows} = VT) ->
    put_shown(VT#vt{margins = {1, Rows}, cursor = {1, 1, false}, last = none},
              blank_grid(Cols, Rows, {"E", 1, ?DEFAULT_ATTRS, none})).

set_margins(Ps, #vt{rows = Rows} = VT) ->
    Top = arg(Ps, 1),
    Bottom = min(arg(tl_or_empty(Ps), Rows), Rows),
    case Top < Bottom of
        true -> home(VT#vt{margins = {Top, Bottom}});
        false -> VT
    end.

%%% Erasing, inserting and deleting

erase_display(0, #vt{cursor = {Row, _, _}, rows = Rows} = VT) ->
    blank_rows(erase_line(0, VT), Row + 1, Rows);
erase_display(1, #vt{cursor = {Row, _, _}} = VT) ->
    blank_rows(erase_line(1, VT), 1, Row - 1);
erase_display(2, #vt{rows = Rows} = VT) ->
    clear_wrap(blank_rows(VT, 1, Rows));
erase_display(3, VT) ->
    VT#vt{scrollback = queue:new(), scrollback_cells = 0};
erase_display(_, VT) ->
    count(csi, VT).

erase_line(0, #vt{cols = Cols} = VT) ->
    unwrap(edit_row(VT, fun(L, C, B) -> erase_cells(L, C, Cols, B) end));
erase_line(1, VT) ->
    edit_row(VT, fun(L, C, B) -> erase_cells(L, 1, C, B) end);
erase_line(2, #vt{cols = Cols} = VT) ->
    unwrap(edit_row(VT, fun(L, _C, B) -> erase_cells(L, 1, Cols, B) end));
erase_line(_, VT) ->
    count(csi, VT).

%% A row whose end is erased no longer continues into the next.
unwrap(#vt{cursor = {Row, _, _}} = VT) ->
    {_, Cells} = row(VT, Row),
    put_row(VT, Row, {false, Cells}).

clear_wrap(#vt{cursor = {Row, Col, _}} = VT) -> VT#vt{cursor = {Row, Col, false}}.

%% Edits the cursor's row as a list: Fun gets the cells, the column and the
%% blank of the pen, and the result is repaired so that no width-2 cell is
%% split. The pending wrap clears.
edit_row(#vt{cursor = {_, Col, _}} = VT, Fun) ->
    edit_row(VT, Fun, Col).

edit_row(#vt{cursor = {Row, Col, _}, cols = Cols} = VT, Fun, At) ->
    Blank = blank(VT),
    {Wrapped, Cells} = row(VT, Row),
    Edited = lists:sublist(Fun(tuple_to_list(Cells), At, Blank), Cols),
    (put_row(VT, Row, {Wrapped, list_to_tuple(repair(Edited, Blank))}))#vt{cursor = {Row, Col, false}}.

insert_cells(List, Col, N, Blank) ->
    {Before, After} = lists:split(Col - 1, List),
    Before ++ lists:duplicate(min(N, length(After)), Blank) ++ After.

delete_cells(List, Col, N, Blank) ->
    {Before, After} = lists:split(Col - 1, List),
    Gone = min(N, length(After)),
    Before ++ lists:nthtail(Gone, After) ++ lists:duplicate(Gone, Blank).

erase_cells(List, From, To, Blank) ->
    {Before, Rest} = lists:split(From - 1, List),
    {Middle, After} = lists:split(min(To - From + 1, length(Rest)), Rest),
    Before ++ [Blank || _ <- Middle] ++ After.

%% A width-2 cell without its tail, or a tail without its cell, is blank.
repair([{_, 2, _, _} = Head, wide_tail | Rest], Blank) -> [Head, wide_tail | repair(Rest, Blank)];
repair([{_, 2, _, _} | Rest], Blank) -> [Blank | repair(Rest, Blank)];
repair([wide_tail | Rest], Blank) -> [Blank | repair(Rest, Blank)];
repair([Cell | Rest], Blank) -> [Cell | repair(Rest, Blank)];
repair([], _Blank) -> [].

blank_rows(VT, From, To) when From > To ->
    VT;
blank_rows(#vt{cols = Cols} = VT, From, To) ->
    Line = {false, erlang:make_tuple(Cols, blank(VT))},
    put_shown(VT, lists:foldl(fun(R, G) -> setelement(R, G, Line) end, shown(VT), lists:seq(From, To))).

%% Lines go in and out at the cursor's row within the region, and the
%% cursor goes to the first column; outside the region nothing happens.
insert_lines(N, #vt{cursor = {Row, _, _}, margins = {Top, Bottom}} = VT) when Row >= Top, Row =< Bottom ->
    carriage_return(scroll_down(VT, Row, Bottom, N));
insert_lines(_N, VT) ->
    VT.

delete_lines(N, #vt{cursor = {Row, _, _}, margins = {Top, Bottom}} = VT) when Row >= Top, Row =< Bottom ->
    carriage_return(scroll_up(VT, Row, Bottom, N, discard));
delete_lines(_N, VT) ->
    VT.

%%% Scrolling and the scrollback

%% Rows Top..Bottom move up by N, blank rows entering at the bottom. A row
%% that scrolls off the top of the main grid, with the region's top margin
%% at the first row, enters the scrollback when the scroll saves.
scroll_up(#vt{cols = Cols} = VT, Top, Bottom, N0, Save) ->
    N = min(N0, Bottom - Top + 1),
    {Above, Region, Below} = split_rows(shown(VT), Top, Bottom),
    {Gone, Kept} = lists:split(N, Region),
    Blanks = lists:duplicate(N, {false, erlang:make_tuple(Cols, blank(VT))}),
    VT1 = put_shown(VT, list_to_tuple(Above ++ Kept ++ Blanks ++ Below)),
    case Save =:= save andalso Top =:= 1 andalso VT#vt.shown =:= main of
        true -> push_scrollback(Gone, VT1);
        false -> VT1
    end.

scroll_down(#vt{cols = Cols} = VT, Top, Bottom, N0) ->
    N = min(N0, Bottom - Top + 1),
    {Above, Region, Below} = split_rows(shown(VT), Top, Bottom),
    Kept = lists:sublist(Region, length(Region) - N),
    Blanks = lists:duplicate(N, {false, erlang:make_tuple(Cols, blank(VT))}),
    put_shown(VT, list_to_tuple(Above ++ Blanks ++ Kept ++ Below)).

split_rows(Grid, Top, Bottom) ->
    {Above, Rest} = lists:split(Top - 1, tuple_to_list(Grid)),
    {Region, Below} = lists:split(Bottom - Top + 1, Rest),
    {Above, Region, Below}.

%% Rows enter without their trailing blank default cells, each charged at
%% least one cell so that the bound also bounds the rows, and the oldest
%% leave until the bound holds.
push_scrollback(Rows, VT) ->
    lists:foldl(fun push_row/2, VT, Rows).

push_row({Wrapped, Cells}, #vt{scrollback = Queue, scrollback_cells = Count} = VT) ->
    Row = {Wrapped, list_to_tuple(trim(tuple_to_list(Cells)))},
    drop_oldest(VT#vt{scrollback = queue:in(Row, Queue), scrollback_cells = Count + charge(Row)}).

drop_oldest(#vt{scrollback_cells = Count, scrollback = Queue} = VT) when Count > ?MAX_SCROLLBACK ->
    {{value, Row}, Rest} = queue:out(Queue),
    drop_oldest(VT#vt{scrollback = Rest, scrollback_cells = Count - charge(Row)});
drop_oldest(VT) ->
    VT.

charge({_, Cells}) -> max(tuple_size(Cells), 1).

trim(Cells) -> lists:reverse(lists:dropwhile(fun(C) -> C =:= ?BLANK end, lists:reverse(Cells))).

%%% Resizing

%% A grid at Rows rows, lifting rows off the top only as far as keeping the
%% row CursorRow on screen needs, then dropping rows from the bottom: the new
%% grid, the rows lifted, for the scrollback, and how far the rows moved up.
fit_rows(Grid, CursorRow, Rows, Cols) ->
    Old = tuple_size(Grid),
    List = tuple_to_list(Grid),
    case Rows < Old of
        true ->
            Lift = min(Old - Rows, max(CursorRow - Rows, 0)),
            {Lifted, Rest} = lists:split(Lift, List),
            {list_to_tuple(lists:sublist(Rest, Rows)), Lifted, Lift};
        false ->
            Blanks = lists:duplicate(Rows - Old, {false, erlang:make_tuple(Cols, ?BLANK)}),
            {list_to_tuple(List ++ Blanks), [], 0}
    end.

fit_cols(Grid, Cols) ->
    list_to_tuple([{Wrapped, fit_row(Cells, Cols)} || {Wrapped, Cells} <- tuple_to_list(Grid)]).

fit_row(Cells, Cols) when tuple_size(Cells) >= Cols ->
    list_to_tuple(repair(lists:sublist(tuple_to_list(Cells), Cols), ?BLANK));
fit_row(Cells, Cols) ->
    list_to_tuple(tuple_to_list(Cells) ++ lists:duplicate(Cols - tuple_size(Cells), ?BLANK)).

row_of(#saved{position = {Row, _, _}}) -> Row.

%%% Paste

%% One pass: a byte goes on the kept bytes, and whenever they then end in a
%% bracket's end, in either form, that end is removed, so no end can be
%% left by joining what surrounds a removed one. The kept bytes are a
%% binary appended in place, so the pass is linear.
strip_paste_end(Bytes) ->
    strip_paste_end(Bytes, <<>>).

strip_paste_end(<<Byte, Rest/binary>>, Kept0) ->
    Kept = <<Kept0/binary, Byte>>,
    Size = byte_size(Kept),
    case Kept of
        <<Before:(Size - 6)/binary, "\e[201~">> -> strip_paste_end(Rest, Before);
        <<Before:(Size - 6)/binary, 16#C2, 16#9B, "201~">> -> strip_paste_end(Rest, Before);
        _ -> strip_paste_end(Rest, Kept)
    end;
strip_paste_end(<<>>, Kept) ->
    Kept.

%%% The grid's representation

blank(#vt{pen = {_, _, Bg}}) -> {" ", 1, {[], default, Bg}, none}.

blank_grid(Cols, Rows, Cell) -> erlang:make_tuple(Rows, {false, erlang:make_tuple(Cols, Cell)}).

%% The default stops, every eighth column, from From to Cols; none if From > Cols.
default_tabs(From, Cols) -> [T || T <- lists:seq(From, max(Cols, From - 1)), T rem 8 =:= 1, T > 1].

shown(#vt{shown = main, main = Grid}) -> Grid;
shown(#vt{shown = alt, alt = Grid}) -> Grid.

put_shown(#vt{shown = main} = VT, Grid) -> VT#vt{main = Grid};
put_shown(#vt{shown = alt} = VT, Grid) -> VT#vt{alt = Grid}.

row(VT, Row) -> element(Row, shown(VT)).

cells(VT, Row) -> element(2, row(VT, Row)).

put_row(VT, Row, Line) -> put_shown(VT, setelement(Row, shown(VT), Line)).

clamp(N, Low, High) -> max(Low, min(N, High)).

%%% Invariants

grid_shaped(Grid, Cols, Rows) ->
    tuple_size(Grid) =:= Rows andalso
        lists:all(fun({W, Cells}) -> is_boolean(W) andalso tuple_size(Cells) =:= Cols;
                     (_) -> false
                  end, tuple_to_list(Grid)).

grid_paired(Grid) ->
    lists:all(fun({_, Cells}) -> paired(tuple_to_list(Cells)) end, tuple_to_list(Grid)).

paired([{_, 2, _, _}, wide_tail | Rest]) -> paired(Rest);
paired([{_, 2, _, _} | _]) -> false;
paired([wide_tail | _]) -> false;
paired([_ | Rest]) -> paired(Rest);
paired([]) -> true.

cells_bounded(Grid) ->
    lists:all(fun({_, Cells}) ->
                      lists:all(fun({Chars, _, _, _}) -> length(Chars) =< ?MAX_CHARS;
                                   (wide_tail) -> true
                                end, tuple_to_list(Cells))
              end, tuple_to_list(Grid)).

parser_bounded(#parser{intermediates = Inter, params = Params, count = Count, osc = Osc}) ->
    (Inter =:= overflow orelse length(Inter) =< ?MAX_INTERMEDIATES) andalso
        length(Params) =:= Count andalso Count =< ?MAX_PARAMS andalso
        lists:all(fun(P) -> P =< ?MAX_PARAM end, Params) andalso
        (Osc =:= overflow orelse Osc =:= link_overflow orelse byte_size(Osc) =< ?MAX_OSC).
