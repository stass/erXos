%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_vt (docs/design-display.md, "The terminal emulator"):
%% one case per row of the sequence tables, the bounds and the main failure
%% paths of each stage. Every state a case builds goes through erx_vt:check/1,
%% the design's invariants.
-module(erx_vt_tests).
-include_lib("eunit/include/eunit.hrl").

-define(BEL, 7).
-define(CAN, 16#18).

%%% Helpers

%% A 10-column, 5-row terminal fed Bytes; every case's state must hold the
%% invariants.
run(Bytes) -> run(10, 5, Bytes).

run(Cols, Rows, Bytes) ->
    {VT, _} = feed(erx_vt:new(Cols, Rows), Bytes),
    VT.

effects(Bytes) ->
    {_, Effects} = feed(erx_vt:new(10, 5), Bytes),
    Effects.

feed(VT0, Bytes) ->
    {VT, Effects} = erx_vt:feed(VT0, iolist_to_binary(Bytes)),
    ?assertEqual(ok, erx_vt:check(VT)),
    {VT, Effects}.

%% A row's text, a width-2 cell's tail contributing nothing.
text(VT, Row) ->
    {_, Cells} = element(Row, erx_vt:grid(VT)),
    unicode:characters_to_binary([Chars || {Chars, _, _, _} <- tuple_to_list(Cells)]).

cell(VT, Row, Col) -> element(Col, element(2, element(Row, erx_vt:grid(VT)))).

attrs(VT, Row, Col) -> element(3, cell(VT, Row, Col)).

at(VT) -> {Row, Col, _} = erx_vt:cursor(VT), {Row, Col}.

ignored(VT, Kind) -> maps:get(Kind, erx_vt:ignored(VT), 0).

utf8(Points) -> unicode:characters_to_binary(Points).

%%% C0 and C1 controls

bell_test() ->
    ?assertEqual([bell], effects([?BEL])).

backspace_stops_at_column_one_test() ->
    ?assertEqual({1, 1}, at(run("ab\b\b\b"))),
    ?assertEqual({1, 9}, at(run("0123456789\b"))).

tab_goes_to_the_next_stop_or_the_last_column_test() ->
    ?assertEqual({1, 9}, at(run("a\t"))),
    ?assertEqual({1, 10}, at(run("a\t\t\t"))).

line_feed_vertical_tab_and_form_feed_index_test() ->
    VT = run("a\nb\vc\fd\ne\n"),
    ?assertEqual({5, 6}, at(VT)),
    ?assertEqual(<<" b        ">>, text(VT, 1)),
    ?assertEqual([{false, {{"a", 1, {[], default, default}, none}}}], erx_vt:scrollback(VT)).

new_line_mode_returns_the_carriage_test() ->
    ?assertEqual({2, 1}, at(run("\e[20hab\n"))),
    ?assertEqual({2, 3}, at(run("\e[20h\e[20lab\n"))).

carriage_return_test() ->
    ?assertEqual({1, 1}, at(run("abc\r"))).

shift_out_and_in_invoke_g1_and_g0_test() ->
    VT = run("\e)0\x0eq\x0fq"),
    ?assertEqual(utf8([16#2500, $q]), binary:part(text(VT, 1), 0, 4)).

cancel_and_substitute_end_a_sequence_test() ->
    ?assertEqual(<<"J         ">>, text(run(["\e[2", ?CAN, "J"]), 1)),
    ?assertEqual(<<"J         ">>, text(run(["\e[2", 16#1A, "J"]), 1)),
    ?assertEqual([bell], effects(["\e]0;dropped", ?CAN, ?BEL])).

escape_ends_a_string_test() ->
    ?assertEqual([{title, <<"t">>}], effects("\e]2;t\e\\")),
    VT = run("\e]2;never ended\ecx"),
    ?assertEqual(<<"x         ">>, text(VT, 1)).

null_and_delete_do_nothing_uncounted_test() ->
    VT = run([0, 16#7F, "a", 1, 16#1F]),
    ?assertEqual({1, 2}, at(VT)),
    ?assertEqual(#{}, erx_vt:ignored(VT)).

c1_controls_as_their_escape_forms_test() ->
    %% IND, NEL, HTS and RI in UTF-8, and CSI as U+009B, as prim_tty writes it.
    ?assertEqual({2, 3}, at(run(["ab", utf8([16#84])]))),
    ?assertEqual({2, 1}, at(run(["ab", utf8([16#85])]))),
    ?assertEqual({1, 3}, at(run(["ab", utf8([16#88]), "\r\t"]))),
    ?assertEqual({1, 3}, at(run(["\nab", utf8([16#8D])]))),
    ?assertEqual({3, 4}, at(run([utf8([16#9B]), "3;4H"]))),
    VT = run(utf8([16#8E, 16#9A])),
    ?assertEqual(2, ignored(VT, c1)).

%%% Escape sequences

save_and_restore_the_cursor_test() ->
    VT = run("\e[2;3H\e[1m\e(0\e7\e[H\e[0m\e(B\e8q"),
    ?assertEqual({2, 4}, at(VT)),
    ?assertEqual({[bold], default, default}, attrs(VT, 2, 3)),
    ?assertEqual([16#2500], element(1, cell(VT, 2, 3))),
    ?assertEqual({2, 4}, at(run("\e[2;3H\e[s\e[H\e[ux"))).

restore_keeps_the_cursor_in_the_region_in_origin_mode_test() ->
    VT = run(80, 24, "\e[1;5r\e[?6h\e7\e[10;20r\e8"),
    ?assertEqual({10, 1}, at(VT)),
    ?assertEqual([{reply, <<"\e[1;1R">>}], element(2, feed(VT, "\e[6n"))).

restore_without_autowrap_does_not_wrap_test() ->
    VT = run("0123456789\e7\e[?7l\e8X"),
    ?assertEqual(<<"012345678X">>, text(VT, 1)),
    ?assertEqual({1, 10}, at(VT)).

index_next_line_and_reverse_index_test() ->
    ?assertEqual({2, 2}, at(run("a\eD"))),
    ?assertEqual({2, 1}, at(run("a\eE"))),
    Top = run("top\e[H\eM"),
    ?assertEqual(<<"          ">>, text(Top, 1)),
    ?assertEqual(<<"top       ">>, text(Top, 2)).

tab_stop_set_test() ->
    ?assertEqual({1, 4}, at(run("abc\eH\r\t"))).

full_reset_keeps_the_scrollback_test() ->
    VT = run("\e[1;31mgone\n\n\n\n\n\e[?25l\e[4h\e[2;3r\ec"),
    ?assertEqual({1, 1, true}, erx_vt:cursor(VT)),
    ?assertEqual(<<"          ">>, text(VT, 1)),
    ?assertEqual(1, length(erx_vt:scrollback(VT))),
    {After, _} = feed(VT, "\e[3Bx"),
    ?assertEqual({4, 2}, at(After)),
    ?assertEqual({[], default, default}, attrs(After, 4, 1)).

keypad_modes_test() ->
    ?assertMatch(#{keypad := true}, erx_vt:modes(run("\e="))),
    ?assertMatch(#{keypad := false}, erx_vt:modes(run("\e=\e>"))).

character_sets_test() ->
    ?assertEqual(utf8([16#250C, 16#2500, 16#2510]), binary:part(text(run("\e(0lqk"), 1), 0, 9)),
    ?assertEqual(utf8([16#A3]), binary:part(text(run("\e(A#"), 1), 0, 2)),
    ?assertEqual(<<"#">>, binary:part(text(run("\e(A\e(B#"), 1), 0, 1)),
    ?assertEqual(utf8([16#2500]), binary:part(text(run("\e)0\x0eq"), 1), 0, 3)),
    %% Code points outside ASCII are never mapped; other sets are ignored.
    ?assertEqual(utf8([16#E9]), binary:part(text(run(["\e(0", utf8([16#E9])]), 1), 0, 2)),
    VT = run("\e(Kq\e*0"),
    ?assertEqual(<<"q">>, binary:part(text(VT, 1), 0, 1)),
    ?assertEqual(2, ignored(VT, esc)).

screen_alignment_test() ->
    VT = run("\e[2;3r\e[4;4H\e#8"),
    ?assertEqual(<<"EEEEEEEEEE">>, text(VT, 5)),
    ?assertEqual({1, 1}, at(VT)),
    ?assertEqual({5, 1}, at(element(1, feed(VT, "\e[9B")))).

string_terminator_and_utf8_designation_test() ->
    VT = run("\e\\\e%Ga"),
    ?assertEqual({1, 2}, at(VT)),
    ?assertEqual(#{}, erx_vt:ignored(VT)),
    ?assertEqual(2, ignored(run("\e#3\e%@"), esc)).

%%% CSI sequences

insert_characters_test() ->
    ?assertEqual(<<"a  bc     ">>, text(run("abc\e[2D\e[2@"), 1)),
    ?assertEqual(<<"a bc      ">>, text(run("abc\e[2D\e[@"), 1)),
    %% An insert that splits a width-2 cell blanks both halves.
    Wide = run(["a", utf8([16#4E2D]), "b\e[3G\e[@"]),
    ?assertEqual(<<"a   b     ">>, text(Wide, 1)).

cursor_up_and_down_stop_at_the_margins_test() ->
    ?assertEqual({2, 1}, at(run("\e[2;4r\e[3;1H\e[9A"))),
    ?assertEqual({4, 1}, at(run("\e[2;4r\e[3;1H\e[9B"))),
    ?assertEqual({1, 1}, at(run("\e[2;4r\e[1;1H\e[A"))),
    ?assertEqual({4, 1}, at(run("\e[5;1H\e[0A"))),
    ?assertEqual({5, 1}, at(run("\e[2;4r\e[5;1H\e[9B"))).

cursor_forward_and_back_stop_at_the_edges_test() ->
    ?assertEqual({1, 10}, at(run("\e[99C"))),
    ?assertEqual({1, 2}, at(run("\e[C"))),
    ?assertEqual({1, 1}, at(run("abc\e[99D"))),
    ?assertEqual({1, 3}, at(run("abc\e[0D"))).

next_and_previous_line_test() ->
    ?assertEqual({3, 1}, at(run("ab\e[2E"))),
    ?assertEqual({1, 1}, at(run("\n\nab\e[2F"))).

column_absolute_test() ->
    ?assertEqual({1, 4}, at(run("\e[4G"))),
    ?assertEqual({1, 10}, at(run("\e[40`"))),
    ?assertEqual({1, 1}, at(run("abc\e[G"))).

cursor_position_test() ->
    ?assertEqual({1, 1}, at(run("abc\e[H"))),
    ?assertEqual({1, 1}, at(run("abc\e[0;0H"))),
    ?assertEqual({3, 4}, at(run("\e[3;4f"))),
    ?assertEqual({5, 10}, at(run("\e[99;99H"))),
    ?assertEqual({3, 1}, at(run("\e[3H"))),
    ?assertEqual({1, 5}, at(run("\e[;5H"))),
    %% Relative to the top margin, and kept in the region, in origin mode.
    ?assertEqual({3, 2}, at(run("\e[2;4r\e[?6h\e[2;2H"))),
    ?assertEqual({4, 1}, at(run("\e[2;4r\e[?6h\e[9H"))).

tab_forward_and_back_test() ->
    ?assertEqual({1, 17}, at(run(20, 2, "\e[2I"))),
    ?assertEqual({1, 17}, at(run(20, 2, "\e[19G\e[Z"))),
    ?assertEqual({1, 1}, at(run(20, 2, "\e[19G\e[9Z"))),
    ?assertEqual({1, 20}, at(run(20, 2, "\e[65535I"))).

erase_in_display_test() ->
    Filled = "aaaaaaaaaa\r\nbbbbbbbbbb\r\ncccccccccc\e[2;5H",
    Below = run([Filled, "\e[J"]),
    ?assertEqual(<<"bbbb      ">>, text(Below, 2)),
    ?assertEqual(<<"          ">>, text(Below, 3)),
    Above = run([Filled, "\e[1J"]),
    ?assertEqual(<<"          ">>, text(Above, 1)),
    ?assertEqual(<<"     bbbbb">>, text(Above, 2)),
    All = run([Filled, "\e[2J"]),
    ?assertEqual(<<"          ">>, text(All, 3)),
    ?assertEqual({2, 5}, at(All)),
    %% ED 3 empties the scrollback and leaves the screen.
    Saved = run("old\r\n\r\n\r\n\r\n\r\nnew\e[3J"),
    ?assertEqual([], erx_vt:scrollback(Saved)),
    ?assertEqual(<<"new       ">>, text(Saved, 5)).

erase_uses_the_pen_background_test() ->
    VT = run("abc\e[44m\e[2K"),
    ?assertEqual({" ", 1, {[], default, 4}, none}, cell(VT, 1, 1)).

erase_in_line_test() ->
    ?assertEqual(<<"abc       ">>, text(run("abcdef\e[4G\e[K"), 1)),
    ?assertEqual(<<"    ef    ">>, text(run("abcdef\e[4G\e[1K"), 1)),
    ?assertEqual(<<"          ">>, text(run("abcdef\e[2K"), 1)),
    ?assertEqual(1, ignored(run("\e[5K"), csi)).

insert_and_delete_lines_test() ->
    Rows = "1\r\n2\r\n3\r\n4\r\n5",
    Insert = run([Rows, "\e[2;4r\e[3;5H\e[L"]),
    ?assertEqual([<<"1">>, <<"2">>, <<" ">>, <<"3">>, <<"5">>], firsts(Insert)),
    ?assertEqual({3, 1}, at(Insert)),
    Delete = run([Rows, "\e[2;4r\e[2;1H\e[2M"]),
    ?assertEqual([<<"1">>, <<"4">>, <<" ">>, <<" ">>, <<"5">>], firsts(Delete)),
    Outside = run([Rows, "\e[2;4r\e[5;1H\e[L"]),
    ?assertEqual([<<"1">>, <<"2">>, <<"3">>, <<"4">>, <<"5">>], firsts(Outside)),
    ?assertEqual([], erx_vt:scrollback(run([Rows, "\e[H\e[M"]))).

firsts(VT) -> [binary:part(text(VT, R), 0, 1) || R <- lists:seq(1, 5)].

delete_characters_test() ->
    ?assertEqual(<<"adef      ">>, text(run("abcdef\e[2G\e[2P"), 1)),
    ?assertEqual(<<"a         ">>, text(run("abcdef\e[2G\e[99P"), 1)).

scroll_up_and_down_test() ->
    Rows = "1\r\n2\r\n3\r\n4\r\n5",
    Up = run([Rows, "\e[2S"]),
    ?assertEqual([<<"3">>, <<"4">>, <<"5">>, <<" ">>, <<" ">>], firsts(Up)),
    ?assertEqual(2, length(erx_vt:scrollback(Up))),
    Down = run([Rows, "\e[2;4r\e[T"]),
    ?assertEqual([<<"1">>, <<" ">>, <<"2">>, <<"3">>, <<"5">>], firsts(Down)),
    %% A region below the first row saves nothing; SD's five-parameter form is
    %% ignored.
    ?assertEqual([], erx_vt:scrollback(run([Rows, "\e[2;5r\e[S"]))),
    Mouse = run([Rows, "\e[1;2;3;4;5T"]),
    ?assertEqual(firsts(run(Rows)), firsts(Mouse)),
    ?assertEqual(1, ignored(Mouse, csi)).

erase_characters_test() ->
    ?assertEqual(<<"a  def    ">>, text(run("abcdef\e[2G\e[2X"), 1)),
    ?assertEqual(<<"a cdef    ">>, text(run("abcdef\e[2G\e[X"), 1)).

relative_position_test() ->
    ?assertEqual({1, 4}, at(run("a\e[2a"))),
    ?assertEqual({3, 1}, at(run("\e[2e"))).

device_attributes_test() ->
    ?assertEqual([{reply, <<"\e[?1;2c">>}], effects("\e[c")),
    ?assertEqual([{reply, <<"\e[?1;2c">>}], effects("\e[0c")),
    ?assertEqual([], effects("\e[>c")).

row_absolute_test() ->
    ?assertEqual({4, 3}, at(run("ab\e[4d"))),
    ?assertEqual({3, 1}, at(run("\e[2;4r\e[?6h\e[2d"))).

tab_clear_test() ->
    ?assertEqual({1, 17}, at(run(20, 2, "\e[9G\e[g\r\t"))),
    ?assertEqual({1, 20}, at(run(20, 2, "\e[3g\t"))).

ansi_modes_test() ->
    Insert = run("abc\r\e[4hX"),
    ?assertEqual(<<"Xabc      ">>, text(Insert, 1)),
    ?assertEqual(<<"Xbc       ">>, text(run("abc\r\e[4h\e[4lX"), 1)),
    Unknown = run("\e[4;3;20h"),
    ?assertEqual(1, ignored(Unknown, mode)),
    ?assertEqual({2, 1}, at(element(1, feed(Unknown, "a\n")))).

dec_modes_test() ->
    ?assertMatch(#{cursor_keys := true, reverse_screen := true, bracketed_paste := true},
                 erx_vt:modes(run("\e[?1;5;2004h"))),
    ?assertMatch(#{cursor_keys := false, reverse_screen := false, bracketed_paste := false},
                 erx_vt:modes(run("\e[?1;5;2004h\e[?1;5;2004l"))),
    ?assertEqual({1, 10, false}, erx_vt:cursor(run("\e[?25l\e[99C"))),
    %% Without autowrap the last column is rewritten.
    ?assertEqual(<<"012345678b">>, text(run("\e[?7l0123456789ab"), 1)),
    %% Cursor blink and auto-repeat change nothing and are not counted.
    ?assertEqual(#{}, erx_vt:ignored(run("\e[?12;8h"))),
    ?assertEqual(1, ignored(run("\e[?1000h"), mode)).

alternate_screen_test() ->
    Alt = run("main\e[1;3H\e[?1049hx"),
    ?assertMatch(#{alternate_screen := true}, erx_vt:modes(Alt)),
    ?assertEqual(<<"  x       ">>, text(Alt, 1)),
    Back = element(1, feed(Alt, "\e[5;5H\e[?1049l")),
    ?assertEqual(<<"main      ">>, text(Back, 1)),
    ?assertEqual({1, 3}, at(Back)),
    %% The alternate grid has no scrollback.
    ?assertEqual([], erx_vt:scrollback(run("\e[?1049h\n\n\n\n\n\n"))).

sgr_test() ->
    ?assertEqual({[bold, italic, underline, blink, inverse, invisible, strike, dim], default, default},
                 sort_flags(attrs(run("\e[1;2;3;4;5;7;8;9mx"), 1, 1))),
    ?assertEqual({[], default, default}, attrs(run("\e[1;2;3;4;5;7;8;9;22;23;24;25;27;28;29mx"), 1, 1)),
    ?assertEqual({[], 1, 2}, attrs(run("\e[31;42mx"), 1, 1)),
    ?assertEqual({[], 9, 15}, attrs(run("\e[91;107mx"), 1, 1)),
    ?assertEqual({[], default, default}, attrs(run("\e[31;42;39;49mx"), 1, 1)),
    ?assertEqual({[], 200, {1, 2, 3}}, attrs(run("\e[38;5;200;48;2;1;2;3mx"), 1, 1)),
    ?assertEqual({[bold], default, default}, attrs(run("\e[4;0;1mx"), 1, 1)),
    ?assertEqual({[], default, default}, attrs(run("\e[1m\e[mx"), 1, 1)),
    %% Underline colour is read and ignored; an unknown parameter is skipped
    %% and counted; 38 with a malformed tail ends the list.
    ?assertEqual({[bold], default, default}, attrs(run("\e[58;5;9;58;2;1;2;3;59;1mx"), 1, 1)),
    Unknown = run("\e[6;1mx"),
    ?assertEqual({[bold], default, default}, attrs(Unknown, 1, 1)),
    ?assertEqual(1, ignored(Unknown, sgr)),
    ?assertEqual({[bold], default, default}, attrs(run("\e[1;38;5;256;4mx"), 1, 1)),
    ?assertEqual({[bold], default, default}, attrs(run("\e[1;38;2;1;2mx"), 1, 1)).

sort_flags({Flags, Fg, Bg}) ->
    Order = [bold, italic, underline, blink, inverse, invisible, strike, dim],
    {[F || F <- Order, lists:member(F, Flags)], Fg, Bg}.

status_reports_test() ->
    ?assertEqual([{reply, <<"\e[0n">>}], effects("\e[5n")),
    ?assertEqual([{reply, <<"\e[3;4R">>}], effects("\e[3;4H\e[6n")),
    ?assertEqual([{reply, <<"\e[2;1R">>}], effects("\e[2;5r\e[?6h\e[2;1H\e[6n")),
    ?assertEqual([], effects("\e[?6n\e[7n")).

scrolling_region_test() ->
    VT = run("\e[3;3H\e[2;4r"),
    ?assertEqual({1, 1}, at(VT)),
    ?assertEqual({4, 1}, at(element(1, feed(VT, "\e[4;1H\n\n")))),
    %% A region whose top is not above its bottom is ignored.
    ?assertEqual({3, 3}, at(run("\e[3;3H\e[4;4r"))),
    ?assertEqual({3, 3}, at(run("\e[3;3H\e[4;2r"))),
    Clamped = run("\e[2;99r\e[5;1H\n"),
    ?assertEqual({5, 1}, at(Clamped)).

soft_reset_test() ->
    VT = run("\e[1m\e[2;3r\e[?6h\e[4h\e(0\e[?25l\e[!p"),
    ?assertEqual({2, 1, true}, erx_vt:cursor(VT)),
    {After, _} = feed(VT, "abc\rq\e[5;1H\n"),
    ?assertEqual(<<"qbc       ">>, text(After, 1)),
    ?assertEqual({[], default, default}, attrs(After, 1, 1)),
    ?assertEqual({5, 1}, at(After)).

%%% Strings

titles_test() ->
    ?assertEqual([{title, <<"zero">>}], effects(["\e]0;zero", ?BEL])),
    ?assertEqual([{title, utf8([16#E9])}], effects(["\e]2;", utf8([16#E9]), "\e\\"])),
    ?assertEqual([{title, <<"ab">>}], effects(["\e]2;a", 1, 16#7F, "b", utf8([16#9C])])).

hyperlinks_test() ->
    %% A closing is a sequence of the table and is not counted; a link or a
    %% context that the grammar does not admit is counted, its text plain.
    ?assertEqual(#{}, erx_vt:ignored(run("\e]8;;\e\\x"))),
    Link = run("\e]8;;https://example.com\e\\x"),
    ?assertEqual(1, ignored(Link, link)),
    ?assertEqual(none, erx_vt:link_at(Link, 1, 1)),
    ?assertEqual(none, element(4, cell(Link, 1, 1))).

other_strings_are_consumed_and_counted_test() ->
    VT = run(["\e]52;c;eA==", ?BEL, "\ePq#0;2;0;0;0\e\\\e^pm\e\\\e_apc\e\\\eXsos\e\\", utf8([16#90]), "dcs",
              utf8([16#9C]), "x"]),
    ?assertEqual(<<"x         ">>, text(VT, 1)),
    ?assertMatch(#{osc := 1, string := 5}, erx_vt:ignored(VT)).

%%% Bounds

seventeen_parameters_dispatch_the_first_sixteen_test() ->
    Sixteen = lists:join($;, lists:duplicate(16, "1")),
    ?assertEqual({[bold], default, default}, attrs(run(["\e[", Sixteen, ";4mx"]), 1, 1)),
    ?assertEqual({[bold, underline], default, default},
                 attrs(run(["\e[", lists:join($;, lists:duplicate(15, "1")), ";4mx"]), 1, 1)).

a_parameter_is_clamped_test() ->
    ?assertEqual({1, 10}, at(run("\e[99999999999999999999C"))),
    ?assertEqual({[], 3, default}, attrs(run("\e[00000000000000000033mx"), 1, 1)).

three_intermediates_are_ignored_test() ->
    CSI = run("\e[ !\"pa"),
    ?assertEqual(1, ignored(CSI, csi)),
    ?assertEqual({1, 2}, at(CSI)),
    ?assertEqual(1, ignored(run("\e(((0q"), esc)).

private_markers_and_colons_test() ->
    ?assertEqual(1, ignored(run("\e[1?h"), csi)),
    Colon = run("\e[38:2:1:2:3mx"),
    ?assertEqual({[], default, default}, attrs(Colon, 1, 1)),
    ?assertEqual(1, ignored(Colon, csi)).

osc_bound_test() ->
    Fits = ["\e]2;", lists:duplicate(4094, $a), ?BEL],
    ?assertMatch([{title, T}] when byte_size(T) =:= 4094, effects(Fits)),
    Over = ["\e]2;", lists:duplicate(4095, $a), ?BEL, "x"],
    ?assertEqual([], effects(Over)),
    VT = run(Over),
    ?assertEqual(1, ignored(VT, osc)),
    ?assertEqual(<<"x         ">>, text(VT, 1)).

an_unterminated_osc_does_not_stop_a_reset_test() ->
    VT = run(["abc\e]2;", lists:duplicate(10000, $a), "\ecx"]),
    ?assertEqual(<<"x         ">>, text(VT, 1)).

six_code_points_a_cell_test() ->
    VT = run(["e", utf8(lists:duplicate(8, 16#301))]),
    ?assertEqual([$e | lists:duplicate(5, 16#301)], element(1, cell(VT, 1, 1))),
    ?assertEqual({1, 2}, at(VT)).

the_scrollback_is_bounded_test() ->
    VT = run(2, 1, lists:duplicate(140000, "a\r\n")),
    ?assertEqual(131072, length(erx_vt:scrollback(VT))).

%%% Decoding

ill_formed_utf8_test() ->
    Fffd = 16#FFFD,
    Cases = [{<<16#C0, 16#80>>, [Fffd, Fffd]},                 % overlong
             {<<16#E0, 16#80, $a>>, [Fffd, Fffd, $a]},         % overlong lead
             {<<16#ED, 16#A0, 16#80>>, [Fffd, Fffd, Fffd]},    % surrogate
             {<<16#F4, 16#90, 16#80, 16#80>>, [Fffd, Fffd, Fffd, Fffd]},  % past U+10FFFF
             {<<16#E2, 16#82, $a>>, [Fffd, $a]},               % cut short
             {<<16#FF, $a>>, [Fffd, $a]}],
    [?assertEqual(Points, [hd(element(1, cell(run(Bytes), 1, C))) || C <- lists:seq(1, length(Points))])
     || {Bytes, Points} <- Cases].

a_sequence_cut_short_across_calls_test() ->
    {VT1, []} = feed(erx_vt:new(10, 5), <<16#E2, 16#82>>),
    {VT, []} = feed(VT1, <<$a>>),
    ?assertEqual(iolist_to_binary([utf8([16#FFFD]), "a        "]), text(VT, 1)).

splitting_the_input_changes_nothing_test() ->
    Corpus = iolist_to_binary(["a", utf8([16#4E2D, 16#301]), "\e[2;3Hb\e[1;31m\e]2;t", utf8([16#E9]),
                               "\e\\\e[6n", ?BEL, utf8([16#9B]), "2J\e(0q\nwrap the row", ?BEL]),
    Whole = erx_vt:feed(erx_vt:new(10, 5), Corpus),
    [?assertEqual(Whole, split_feed(Corpus, At)) || At <- lists:seq(0, byte_size(Corpus))],
    {Bytewise, Effects} = lists:foldl(fun(B, {V, E}) -> {V1, E1} = erx_vt:feed(V, <<B>>), {V1, E ++ E1} end,
                                      {erx_vt:new(10, 5), []}, binary_to_list(Corpus)),
    ?assertEqual(Whole, {Bytewise, Effects}).

split_feed(Bytes, At) ->
    <<A:At/binary, B/binary>> = Bytes,
    {V1, E1} = erx_vt:feed(erx_vt:new(10, 5), A),
    {V2, E2} = erx_vt:feed(V1, B),
    {V2, E1 ++ E2}.

%%% Widths, wrapping and joining

deferred_wrap_test() ->
    Pending = run("0123456789"),
    ?assertEqual({1, 10}, at(Pending)),
    ?assertEqual({1, 1}, at(element(1, feed(Pending, "\r")))),
    Wrapped = element(1, feed(Pending, "x")),
    ?assertEqual({2, 2}, at(Wrapped)),
    ?assertMatch({true, _}, element(1, erx_vt:grid(Wrapped))).

wide_characters_test() ->
    Wide = run(["012345678", utf8([16#4E2D])]),
    ?assertEqual(<<"012345678 ">>, text(Wide, 1)),
    ?assertEqual(wide_tail, cell(Wide, 2, 2)),
    NoWrap = run(["\e[?7l012345678", utf8([16#4E2D])]),
    ?assertEqual(iolist_to_binary(["01234567", utf8([16#4E2D])]), text(NoWrap, 1)),
    %% Writing over either half blanks both.
    Over = run([utf8([16#4E2D, 16#4E2D]), "\e[2Gx"]),
    ?assertEqual(iolist_to_binary([" x", utf8([16#4E2D]), "      "]), text(Over, 1)).

zero_width_joins_until_the_cursor_moves_test() ->
    Joined = run(["e", utf8([16#301])]),
    ?assertEqual([$e, 16#301], element(1, cell(Joined, 1, 1))),
    Moved = run(["e\e[C\e[D", utf8([16#301])]),
    ?assertEqual([$e], element(1, cell(Moved, 1, 1))),
    ?assertEqual([$e, 16#301], element(1, cell(run(["e\e[1m", utf8([16#301])]), 1, 1))),
    ?assertEqual({1, 1}, at(run(utf8([16#301])))).

%%% Resizing and paste

resize_test() ->
    VT = run("1\r\n2\r\n3\r\n4\r\n5\e[4;1H"),
    Short = erx_vt:resize(VT, 10, 2),
    ?assertEqual(ok, erx_vt:check(Short)),
    ?assertEqual({2, 1}, at(Short)),
    ?assertEqual([<<"3">>, <<"4">>], [binary:part(text(Short, R), 0, 1) || R <- [1, 2]]),
    ?assertEqual(2, length(erx_vt:scrollback(Short))),
    Tall = erx_vt:resize(Short, 10, 4),
    ?assertEqual(<<"          ">>, text(Tall, 4)),
    Narrow = erx_vt:resize(run(["01234567", utf8([16#4E2D])]), 9, 5),
    ?assertEqual(ok, erx_vt:check(Narrow)),
    ?assertEqual(<<"01234567 ">>, text(Narrow, 1)),
    ?assertEqual(none, erx_vt:link_at(Narrow, 1, 99)),
    Wide = erx_vt:resize(run(""), 20, 5),
    ?assertEqual({1, 17}, at(element(1, feed(Wide, "\t\t")))),
    ?assertError(function_clause, erx_vt:resize(VT, 1, 5)).

paste_test() ->
    Plain = erx_vt:new(10, 5),
    ?assertEqual(<<"a\e[201~b">>, erx_vt:paste(Plain, <<"a\e[201~b">>)),
    Bracketed = run("\e[?2004h"),
    ?assertEqual(<<"\e[200~ab\e[201~">>, erx_vt:paste(Bracketed, <<"a\e[201~b">>)),
    ?assertEqual(<<"\e[200~\e[201~">>, erx_vt:paste(Bracketed, <<"\e[20\e[201~1~">>)),
    ?assertEqual(<<"\e[200~x\e[201~">>, erx_vt:paste(Bracketed, <<16#C2, 16#9B, "201~x">>)),
    Nested = iolist_to_binary([lists:duplicate(3, "\e[20"), "\e[201~", lists:duplicate(3, "1~")]),
    ?assertEqual(<<"\e[200~\e[201~">>, erx_vt:paste(Bracketed, Nested)).

new_refuses_sizes_outside_the_bounds_test() ->
    ?assertError(function_clause, erx_vt:new(641, 5)),
    ?assertError(function_clause, erx_vt:new(10, 257)),
    ?assertMatch(ok, erx_vt:check(erx_vt:new(640, 256))).
