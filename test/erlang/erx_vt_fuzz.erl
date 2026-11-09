%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_vt:feed/2 over arbitrary program output
%% (docs/design-display.md, "Verification and testing"): streams built from
%% the sequence tables' grammar, with parameters at and past their bounds,
%% long and unterminated strings, wide, zero-width and ill-formed text, are
%% fed to terminals of random small sizes in random pieces. After every call
%% the state must hold erx_vt:check/1's invariants and G8's size bound, and
%% every reply must be one of the three fixed forms; the stream fed whole
%% must give the same state and effects as the pieces; and a resize to a
%% random size must keep the invariants. A failure raises
%% {fuzz_failure, What, Detail}, What naming the property.
-module(erx_vt_fuzz).
-export([run/1]).

-define(ROUNDS, 1500).
%% A cell's words at most: its tuple, six code points, the attributes, eight
%% flags and two RGB colours, and its slot in the row.
-define(CELL_WORDS, 46).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    lists:foreach(fun(_) -> round_of() end, lists:seq(1, ?ROUNDS)),
    io:format("fuzz: ~p rounds ok~n", [?ROUNDS]).

round_of() ->
    Cols = 1 + rand:uniform(11),
    Rows = rand:uniform(6),
    Stream = iolist_to_binary([token() || _ <- lists:seq(1, rand:uniform(40))]),
    Pieces = split(Stream),
    {Fed, Effects} = lists:foldl(fun(Piece, {VT0, Acc}) ->
                                         {VT, New} = erx_vt:feed(VT0, Piece),
                                         verify(VT, New, Stream),
                                         {VT, Acc ++ New}
                                 end, {erx_vt:new(Cols, Rows), []}, Pieces),
    case erx_vt:feed(erx_vt:new(Cols, Rows), Stream) of
        {Fed, Effects} -> ok;
        Whole -> fail(split_differs, {Stream, Pieces, Whole})
    end,
    Resized = erx_vt:resize(Fed, 1 + rand:uniform(11), rand:uniform(6)),
    verify(Resized, [], {resize, Stream}).

verify(VT, Effects, Input) ->
    case erx_vt:check(VT) of
        ok -> ok;
        {error, Invariant} -> fail(Invariant, Input)
    end,
    within_size(VT, Input),
    links_plain(VT, Input),
    [fail(reply_not_fixed, {Reply, Input}) || {reply, Reply} <- Effects, not fixed_reply(Reply, VT)],
    ok.

%% G8: apart from the scrollback, which check/1 bounds by its cells, the
%% state is bounded by the grid's size: two grids and the last row written,
%% the tab stops, and a constant for the parser, the modes and the rest,
%% the link table among them: 256 links of at most an OSC string each.
within_size(VT, Input) ->
    {Cols, Rows} = erx_vt:size(VT),
    Links = 256 * (4096 div 8 + 16),
    Bound = (2 * Rows + 1) * (Cols * ?CELL_WORDS + 8) + 2 * Cols + 600 + Links,
    Words = erts_debug:flat_size(VT) - erts_debug:flat_size(erx_vt:scrollback(VT)),
    case Words =< Bound of
        true -> ok;
        false -> fail(state_over_size, {Words, Bound, Input})
    end.

%% Reports carry nothing from the stream: DA, DSR 5 and the cursor position
%% report, with numbers within the grid.
fixed_reply(<<"\e[?1;2c">>, _VT) -> true;
fixed_reply(<<"\e[0n">>, _VT) -> true;
fixed_reply(Reply, VT) ->
    {Cols, Rows} = erx_vt:size(VT),
    case re:run(Reply, <<"^\e\\[([0-9]{1,3});([0-9]{1,3})R$">>, [{capture, all_but_first, list}]) of
        {match, [Row, Col]} -> list_to_integer(Row) =< Rows andalso list_to_integer(Col) =< Cols;
        nomatch -> false
    end.

%% Every cell's link is none or a presentation type and a printable ASCII
%% text: what link_at/3 hands a click came through erx_present.
links_plain(VT, Input) ->
    {Cols, Rows} = erx_vt:size(VT),
    [check_link(erx_vt:link_at(VT, Row, Col), Input) || Row <- lists:seq(1, Rows), Col <- lists:seq(1, Cols)],
    ok.

check_link(none, _Input) ->
    ok;
check_link({Type, Text}, Input) ->
    Plain = lists:all(fun(B) -> B >= 16#20 andalso B =< 16#7E end, binary_to_list(Text)),
    case erx_present:type(Type) =/= error andalso Plain of
        true -> ok;
        false -> fail(link_not_plain, {Type, Text, Input})
    end.

fail(What, Detail) -> error({fuzz_failure, What, Detail}).

%%% The streams

split(Stream) ->
    Cuts = lists:usort([rand:uniform(byte_size(Stream) + 1) - 1 || _ <- lists:seq(1, rand:uniform(4) - 1)]),
    pieces(Stream, 0, Cuts).

pieces(Stream, From, []) -> [binary:part(Stream, From, byte_size(Stream) - From)];
pieces(Stream, From, [At | Rest]) -> [binary:part(Stream, From, At - From) | pieces(Stream, At, Rest)].

token() ->
    case rand:uniform(11) of
        1 -> text();
        2 -> text();
        3 -> control();
        4 -> escape();
        5 -> csi();
        6 -> csi();
        7 -> sgr();
        8 -> string();
        9 -> modes();
        10 -> bytes();
        11 -> link()
    end.

text() ->
    [pick([<<"a">>, <<"Z">>, <<"#">>, <<"q">>, <<" ">>, utf8(16#4E2D), utf8(16#301), utf8(16#200D),
           utf8(16#1F600), utf8(16#FF01), utf8(16#AD), utf8(16#E9)])
     || _ <- lists:seq(1, rand:uniform(12))].

control() ->
    pick([[7], [8], [9], [10], [11], [12], [13], [14], [15], [16#18], [16#1A], [0], [16#7F],
          utf8(16#84), utf8(16#85), utf8(16#88), utf8(16#8D), utf8(16#8E), utf8(16#9B), utf8(16#9C)]).

escape() ->
    [27 | pick(["7", "8", "D", "E", "M", "H", "c", "=", ">", "(0", "(B", "(A", ")0", "(K", "*0", "#8",
                "#3", "\\", "%G", "%@", "N", "Z", "(((0", " F", [rand:uniform(95) + 31]])].

csi() ->
    Private = pick(["", "", "", "?", ">", "<", "="]),
    Params = lists:join(pick([";", ";", ";", ":"]), [param() || _ <- lists:seq(0, pick([0, 1, 2, 3, 17, 20]))]),
    Inter = pick(["", "", "", "!", " ", "!!", "!!!"]),
    Final = pick("@ABCDEFGHIJKLMPSTXZ`acdefghlmnrsu" ++ [rand:uniform(63) + 63]),
    ["\e[", Private, Params, Inter, [Final]].

param() ->
    pick(["", "0", "1", "2", "3", "4", "5", "6", "7", "20", "25", "1049", "2004", "65535", "99999999",
          integer_to_list(rand:uniform(300))]).

sgr() ->
    Ps = [pick(["0", "1", "4", "7", "22", "31", "38;5;200", "38;2;1;2;3", "48;5;", "48;2;300;0;0", "58;5;1",
                "59", "97", "107", "6", ""])
          || _ <- lists:seq(1, rand:uniform(20))],
    ["\e[", lists:join($;, Ps), "m"].

string() ->
    Opener = pick(["\e]0;", "\e]2;", "\e]8;;", "\e]8;id=1;erx:pid/x", "\e]52;c;", "\e]4;1;", "\eP", "\e^",
                   "\e_", "\eX", utf8(16#90), utf8(16#9D)]),
    Length = pick([0, 3, 40, 4090, 4094, 4095, 5000]),
    Body = binary:copy(pick([<<"a">>, <<"\e">>, utf8(16#E9), <<7>>]), max(1, Length div 8 + rand:uniform(8))),
    Ender = pick([[7], "\e\\", utf8(16#9C), [16#18], "", "\ec"]),
    [Opener, binary:part(binary:copy(<<"x">>, Length), 0, Length), Body, Ender].

%% OSC 8 strings of the link grammar and near it, sometimes a run of more
%% links than the table holds.
link() ->
    Uri = pick([["erx:domain/", integer_to_list(rand:uniform(300))], "erx:module/3/lists", "erx:module/3/%252E",
                "erx:module/3/a%2eb", "erx:module/3/%2501", "erx:pid/%3C0.1.0%3E", "erx:accept/domain,module",
                "erx:accept/", "erx:accept/domain,", "erx:nothing/1", "erx:domain/", "https://example.com/", "",
                ["erx:", bytes()], ["erx:domain/", binary:copy(<<"9">>, 4090 + rand:uniform(8))]]),
    One = ["\e]8;", pick(["", "id=1", "a=b:c=d", "x;y"]), $;, Uri, pick(["\e\\", [7]])],
    case rand:uniform(8) of
        1 -> lists:duplicate(250 + rand:uniform(20), [One, "a"]);
        _ -> One
    end.

modes() ->
    ["\e[?", lists:join($;, [pick(["1", "5", "6", "7", "8", "12", "25", "1049", "2004", "9"])
                            || _ <- lists:seq(1, rand:uniform(3))]), pick(["h", "l"])].

bytes() ->
    << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, rand:uniform(12)) >>.

utf8(Point) -> <<Point/utf8>>.

pick(List) -> lists:nth(rand:uniform(length(List)), List).
