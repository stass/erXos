%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_tty, the line discipline (docs/design-live.md, "The
%% tty"): first FreeBSD's behaviour case by case, then the exploration, which
%% drives every event from every state it reaches, to a bounded depth, over
%% small configurations, and checks each step against spec_*, a reference of
%% what a reader may get that shares no code with erx_tty, and against the
%% properties named in each failure: no lost or early ready report, the timer
%% of POSIX's VMIN and VTIME cases, no echo without ECHO, signals only with
%% ISIG, VSTATUS only with ICANON and IEXTEN, output only as OPOST says.

-module(erx_tty_tests).
-include_lib("eunit/include/eunit.hrl").

%% The room the relay has for the master when it holds nothing for it.
-define(ROOM, 4096).
-define(FREE, {?ROOM, 0, false}).
-define(STOPPED, {?ROOM, 0, true}).

%%% Cases

defaults_are_freebsds_test() ->
    Termios = erx_tty:termios(erx_tty:new()),
    ?assertEqual([brkint, icrnl, imaxbel, iutf8, ixany, ixon], maps:get(iflag, Termios)),
    ?assertEqual([onlcr, opost], maps:get(oflag, Termios)),
    ?assertEqual([echo, echoctl, echoe, echoke, icanon, iexten, isig], maps:get(lflag, Termios)),
    ?assertMatch(#{veof := 4, verase := 127, vintr := 3, vstatus := 20, vmin := 1, vtime := 0,
                   veol := 255}, maps:get(cc, Termios)).

a_cooked_line_is_edited_echoed_and_read_whole_test() ->
    {Actions, Tty} = input(<<"ab", 127, "c\r">>, erx_tty:new()),
    ?assertEqual([{echo, <<"ab\b \bc\r\n">>}], Actions),
    ?assertEqual(3, erx_tty:waiting(Tty)),
    ?assertMatch({{ok, <<"ac\n">>}, _}, erx_tty:read(r, 64, Tty)).

a_partial_line_is_not_read_test() ->
    {_, Tty} = input(<<"ab">>, erx_tty:new()),
    ?assertMatch({eagain, _}, erx_tty:read(r, 64, Tty)).

veof_ends_a_line_and_alone_is_end_of_file_test() ->
    {[{echo, Echo}], Tty} = input(<<"ab", 4, 4>>, erx_tty:new()),
    ?assertEqual(<<"ab^D\b\b^D\b\b">>, Echo),
    {{ok, <<"ab">>}, Tty1} = erx_tty:read(r, 64, Tty),
    {eof, Tty2} = erx_tty:read(r, 64, Tty1),
    ?assertMatch({eagain, _}, erx_tty:read(r, 64, Tty2)).

a_signal_key_stops_input_and_returns_the_rest_test() ->
    Tty = erx_tty:new(),
    {Actions, <<"ls\n">>, _, Tty1} = erx_tty:input(<<"ab", 3, "ls\n">>, ?FREE, Tty),
    ?assertEqual([{echo, <<"ab">>}, flush_output, {echo, <<"^C">>}, {signal, sigint}], Actions),
    ?assertEqual(0, erx_tty:waiting(Tty1)),
    {[{echo, <<"ls\r\n">>}], <<>>, _, Tty2} = erx_tty:input(<<"ls\n">>, ?FREE, Tty1),
    ?assertMatch({{ok, <<"ls\n">>}, _}, erx_tty:read(r, 64, Tty2)),
    %% A waiting read is not reported the bytes after the key.
    {[], Waiting} = erx_tty:read_wait(r, 4096, Tty),
    {[flush_output, {echo, <<"^C">>}, {signal, sigint}], <<"x\n">>, _, _} =
        erx_tty:input(<<3, "x\n">>, ?FREE, Waiting),
    %% VSTATUS is no signal, and input goes on past it.
    {[info, {echo, <<"x">>}], <<>>, _, _} = erx_tty:input(<<20, "x">>, ?FREE, Tty),
    %% Without ISIG the key is data.
    {_, <<>>, _, Raw} = erx_tty:input(<<3, "y">>, ?FREE, raw(1, 0)),
    ?assertMatch({{ok, <<3, "y">>}, _}, erx_tty:read(r, 64, Raw)).

a_short_raw_read_goes_on_at_its_count_test() ->
    {[], W} = erx_tty:read_wait(r, 1, raw(10, 0)),
    {[{ready, r}], W1} = input(<<"a">>, W),
    ?assertMatch({{ok, <<"a">>}, _}, erx_tty:read(r, 1, W1)),
    {[], V} = erx_tty:read_wait(r, 4096, raw(10, 0)),
    ?assertMatch({[], _}, input(<<"a">>, V)).

kill_and_word_erase_test() ->
    {_, Tty} = input(<<"one two  ", 23, "x", 21, "z\n">>, erx_tty:new()),
    ?assertMatch({{ok, <<"z\n">>}, _}, erx_tty:read(r, 64, Tty)),
    {_, Tty1} = input(<<"one two  ", 23, "\n">>, erx_tty:new()),
    ?assertMatch({{ok, <<"one \n">>}, _}, erx_tty:read(r, 64, Tty1)).

vstatus_gives_info_keeps_the_line_and_echoes_nothing_test() ->
    {Actions, Tty} = input(<<"ab", 20>>, erx_tty:new()),
    ?assertEqual([{echo, <<"ab">>}, info], Actions),
    {_, Tty1} = input(<<"\r">>, Tty),
    ?assertMatch({{ok, <<"ab\n">>}, _}, erx_tty:read(r, 64, Tty1)),
    {[{echo, <<"^T">>}], _} = input(<<20>>, with([], [iexten], erx_tty:new())).

intr_flushes_echoes_and_signals_test() ->
    {_, Tty} = input(<<"ab\rcd">>, erx_tty:new()),
    {Actions, Tty1} = input(<<3>>, Tty),
    ?assertEqual([flush_output, {echo, <<"^C">>}, {signal, sigint}], Actions),
    ?assertEqual(0, erx_tty:waiting(Tty1)),
    {_, Tty2} = input(<<3>>, with([noflsh], [], Tty)),
    ?assertEqual(3, erx_tty:waiting(Tty2)).

a_crlf_is_never_split_test() ->
    Newlines = binary:copy(<<"\n">>, 4096),
    {Taken, Out, _} = erx_tty:output(Newlines, 4096, erx_tty:new()),
    ?assertEqual(2048, Taken),
    ?assertEqual(binary:copy(<<"\r\n">>, 2048), Out).

output_without_opost_is_the_bytes_test() ->
    Every = << <<B>> || B <- lists:seq(0, 255) >>,
    Raw = with([], [opost], erx_tty:new()),
    ?assertMatch({256, Every, _}, erx_tty:output(Every, 4096, Raw)),
    ?assertMatch({4, <<"\r\n\tx\b">>, _},
                 erx_tty:output(<<"\n\tx\b", 4, 127, "\r", 27, "[m">>, 5, erx_tty:new())).

output_flags_test() ->
    Tty = with([tab3, onoeot, onocr, ocrnl], [], erx_tty:new()),
    ?assertMatch({6, <<"ab      \n">>, _}, erx_tty:output(<<"\rab\t", 4, "\r">>, 64, Tty)).

%% The owner records output stopped and passes it in the room; input/3
%% returns the room with it as its keys left it.
ixon_stops_and_starts_output_test() ->
    Tty = erx_tty:new(),
    ?assertMatch({[stop_output], <<>>, {_, 0, true}, _}, erx_tty:input(<<19>>, ?FREE, Tty)),
    %% With IXANY the key starts output before it stops it again.
    ?assertMatch({[start_output, stop_output], <<>>, {_, 0, true}, _},
                 erx_tty:input(<<19>>, ?STOPPED, Tty)),
    Strict = with([], [ixany], Tty),
    ?assertMatch({[], <<>>, {_, 0, true}, _}, erx_tty:input(<<19>>, ?STOPPED, Strict)),
    ?assertMatch({[start_output], <<>>, {_, 0, false}, _}, erx_tty:input(<<17>>, ?STOPPED, Strict)),
    ?assertMatch({[], <<>>, {_, 0, false}, _}, erx_tty:input(<<17>>, ?FREE, Strict)),
    %% With VSTOP and VSTART the same, the key toggles (tty_ttydisc.c:1141-1159).
    Toggle = erx_tty:termios(Strict),
    {ok, _, Same} = erx_tty:set(Toggle#{cc := (maps:get(cc, Toggle))#{vstart := $\^S}}, Strict),
    ?assertMatch({[stop_output, start_output], <<>>, {_, 0, false}, _},
                 erx_tty:input(<<19, 19>>, ?FREE, Same)),
    %% Output stopped takes bytes as any output does; the owner holds them.
    ?assertMatch({1, <<"x">>, _}, erx_tty:output(<<"x">>, 64, Tty)),
    %% IXANY: any key restarts output, and is itself input.
    ?assertMatch({[start_output, {echo, <<"q">>}], <<>>, {_, 0, false}, _},
                 erx_tty:input(<<"q">>, ?STOPPED, Tty)),
    %% A signal from a key and VSTATUS start it too, as on FreeBSD, and a
    %% new size starts it whatever the owner holds (tty.c:1536-1538, :1646).
    ?assertMatch({[start_output, flush_output, {echo, <<"^C">>}, {signal, sigint}], <<>>, _, _},
                 erx_tty:input(<<3>>, ?STOPPED, Strict)),
    ?assertMatch({[start_output, info], <<>>, _, _}, erx_tty:input(<<20>>, ?STOPPED, Strict)),
    ?assertMatch({[flush_output, {echo, <<"^C">>}, {signal, sigint}], <<>>, _, _},
                 erx_tty:input(<<3>>, ?FREE, Strict)),
    {ok, [start_output, winch], _} = erx_tty:size(30, 100, Strict).

%% A signal's flush empties what the owner holds for the master, so the
%% key's echo and the bytes after it have the whole room again, whatever
%% was left before, as ttydisc_rint flushes before it echoes the key
%% (tty_ttydisc.c:1128-1130), all but the output the master has not taken.
%% With NOFLSH nothing is flushed, and the room stays as the echo left it.
a_flush_gives_the_room_back_test() ->
    Full = erx_tty:master_room(),
    {Actions, <<"x">>, Left, Tty} = erx_tty:input(<<"ab", 3, "x">>, {0, 0, false}, erx_tty:new()),
    ?assertEqual([flush_output, {echo, <<"^C">>}, {signal, sigint}], Actions),
    ?assertEqual({Full - 2, 0, false}, Left),
    ?assertMatch({[{echo, <<"x">>}], <<>>, _, _}, erx_tty:input(<<"x">>, Left, Tty)),
    Kept = with([noflsh], [], erx_tty:new()),
    ?assertMatch({[{signal, sigint}], <<>>, {0, 0, false}, _}, erx_tty:input(<<"ab", 3>>, {0, 0, false}, Kept)),
    ?assertMatch({[{echo, <<"a">>}, {signal, sigint}], <<>>, {0, 0, false}, _},
                 erx_tty:input(<<"a", 3>>, {1, 0, false}, Kept)),
    %% Output sent and not taken stays: the flush gives back the rest.
    ?assertMatch({[flush_output, {echo, <<"^C">>}, {signal, sigint}], <<>>, {94, 4000, false}, _},
                 erx_tty:input(<<3>>, {0, 4000, false}, erx_tty:new())),
    ?assertMatch({[flush_output, {signal, sigint}], <<>>, {1, 4095, false}, _},
                 erx_tty:input(<<3>>, {0, 4095, false}, erx_tty:new())).

%% The retyped line ends at its first piece that does not fit: with room
%% for "^R", CR-LF, "a" and one byte more, ^A's two bytes end the walk,
%% and the "b" after it, which FreeBSD's queue would still take, is not
%% echoed.
a_reprint_ends_at_its_first_dropped_piece_test() ->
    {_, Typed} = input(<<"a", 1, "b">>, erx_tty:new()),
    ?assertMatch({[{echo, <<"^R\r\na">>}], <<>>, {1, 0, false}, _}, erx_tty:input(<<18>>, {6, 0, false}, Typed)),
    ?assertMatch({[{echo, <<"^R\r\na^Ab">>}], <<>>, {0, 0, false}, _}, erx_tty:input(<<18>>, {8, 0, false}, Typed)),
    %% With ECHO clear nothing echoes, and the line is not walked: 4 KiB of
    %% VREPRINT after a full line makes no action, within a bound on
    %% heap and work that a walk of the line per key, or an action per
    %% character, passes: the case takes 0.7 M reductions.
    {_, Quiet} = input(binary:copy(<<"a">>, 4095), with([], [echo], erx_tty:new())),
    ?assertMatch({[], _}, bounded(fun() -> input(binary:copy(<<18>>, 4096), Quiet) end)).

%% 2,048 bytes of the line, then 2,052 for each VREPRINT ("^R", CR-LF and
%% the line): the first cut where the room ends, and nothing after it.
echo_takes_only_its_room_test() ->
    Keys = <<(binary:copy(<<"a">>, 2048))/binary,
             (binary:copy(<<18>>, 2048))/binary>>,
    {Actions, _} = input(Keys, erx_tty:new()),
    ?assertEqual(?ROOM, byte_size(echoed(Actions))),
    {[], _} = input(<<"x">>, 0, erx_tty:new()).

%% With NOFLSH each VINTR ends a call and keeps the line, so a master that
%% sends VREPRINT and VINTR over and over, and reads nothing, makes many
%% calls; their echo together still fits the one room. Room given again,
%% once the master reads, echoes again.
echo_across_calls_takes_one_room_test() ->
    Tty = with([noflsh], [], erx_tty:new()),
    Keys = <<(binary:copy(<<"a">>, 1000))/binary,
             (binary:copy(<<18, 3>>, 200))/binary>>,
    {Actions, Typed} = input(Keys, Tty),
    ?assertEqual(?ROOM, byte_size(echoed(Actions))),
    ?assertEqual(200, length([S || {signal, S} <- Actions])),
    ?assertMatch({[{echo, <<"x">>}], _}, input(<<"x">>, 1, Typed)).

%% A piece of echo that does not fit is dropped whole, and a smaller one
%% after it still fits, as ttyoutq_write_nofrag drops only what it cannot
%% take: ^A is two bytes, a is one.
a_piece_that_does_not_fit_is_dropped_alone_test() ->
    ?assertMatch({[{echo, <<"a">>}], _}, input(<<1, "a">>, 1, erx_tty:new())).

%% A full line of 4,095 bytes, then four bells for the bytes that do not
%% fit and 1,364 visual erases of 3 bytes fill the whole room exactly; the
%% next byte is stored but not echoed.
echo_at_its_bound_test() ->
    {_, Full} = input(binary:copy(<<"a">>, 4095), erx_tty:new()),
    Keys = <<"aaaa", (binary:copy(<<127>>, 1364))/binary, "b">>,
    {Actions, Tty} = input(Keys, Full),
    Echo = echoed(Actions),
    ?assertEqual(?ROOM, byte_size(Echo)),
    ?assertEqual(<<7, 7, 7, 7, "\b \b">>, binary:part(Echo, 0, 7)),
    ?assertEqual(<<"\b \b">>, binary:part(Echo, ?ROOM - 3, 3)),
    {_, Ended} = input(<<"\n">>, Tty),
    {{ok, Line}, _} = erx_tty:read(r, 8192, Ended),
    %% The four bytes dropped for room are a loss, which the erases keep.
    ?assertEqual(<<(binary:copy(<<"a">>, 2731))/binary, 0, "b\n">>, Line).

input_beyond_its_bound_is_dropped_and_counted_test() ->
    {Actions, Raw} = input(binary:copy(<<"a">>, 5000), raw(1, 0)),
    ?assertEqual([], Actions),
    %% The bytes and one loss for every byte dropped after them.
    ?assertEqual({4097, 904}, {erx_tty:waiting(Raw), erx_tty:dropped(Raw)}),
    Quiet = with([], [echo], erx_tty:new()),
    {Bells, Full} = input(binary:copy(<<"a">>, 4096), Quiet),
    ?assertEqual([{echo, <<7>>}], Bells),
    {[], Ended} = input(<<"\n">>, Full),
    ?assertEqual(4097, erx_tty:waiting(Ended)).

utf8_tab_and_covered_erase_test() ->
    {_, Utf8} = input(<<"x", 16#c3, 16#a9>>, erx_tty:new()),
    {[{echo, <<"\b \b">>}], Erased} = input(<<127>>, Utf8),
    {_, Erased1} = input(<<"\n">>, Erased),
    ?assertMatch({{ok, <<"x\n">>}, _}, erx_tty:read(r, 64, Erased1)),
    {_, Tab} = input(<<"a\t">>, erx_tty:new()),
    {[{echo, <<"\b\b\b\b\b\b\b">>}], _} = input(<<127>>, Tab),
    %% Output written over the line since: the line is typed again.
    {_, Typed} = input(<<"ab">>, erx_tty:new()),
    {1, _, Covered} = erx_tty:output(<<"x">>, 64, Typed),
    {[{echo, <<"^R\r\na">>}], _} = input(<<127>>, Covered).

status_line_test() ->
    Line = <<"load: 0.00\n">>,
    {<<"load: 0.00\r\n">>, _} = erx_tty:status(Line, 256, erx_tty:new()),
    {_, Typed} = input(<<"ab">>, erx_tty:new()),
    {<<"\r\nload: 0.00\r\n">>, _} = erx_tty:status(Line, 256, Typed),
    {<<>>, _} = erx_tty:status(Line, 255, erx_tty:new()),
    {<<>>, _} = erx_tty:status(binary:copy(<<"x">>, 300), 299, erx_tty:new()),
    {<<>>, _} = erx_tty:status(Line, 4096, with([nokerninfo], [], erx_tty:new())).

window_size_test() ->
    Tty = erx_tty:new(),
    {ok, [start_output, winch], Tty1} = erx_tty:size(50, 132, Tty),
    ?assertEqual({50, 132}, erx_tty:winsize(Tty1)),
    {ok, [], _} = erx_tty:size(50, 132, Tty1),
    [?assertEqual({error, einval}, erx_tty:size(R, C, Tty))
     || {R, C} <- [{0, 80}, {24, 0}, {65536, 80}, {24, -1}, {a, 80}, {24, 1.0}]].

set_checks_the_termios_whole_test() ->
    Tty = erx_tty:new(),
    Good = erx_tty:termios(Tty),
    Bad = [Good#{lflag := [echo, bogus]}, Good#{iflag := [icrnl | ixon]},
           Good#{cc := (maps:get(cc, Good))#{vmin := 256}},
           Good#{cc := maps:remove(vtime, maps:get(cc, Good))},
           Good#{cc := (maps:get(cc, Good))#{vbogus => 1}},
           Good#{csize := 9}, Good#{ospeed := -1}, Good#{extra => 1},
           maps:remove(oflag, Good), Good#{oflag := [onlcr, echo]}, [], undefined],
    [?assertEqual({error, einval}, erx_tty:set(Termios, Tty)) || Termios <- Bad],
    {ok, [], Set} = erx_tty:set(Good#{ispeed := 0, ospeed := 38400, lflag := [isig, echo, echo]}, Tty),
    ?assertMatch(#{ispeed := 38400, lflag := [echo, isig]}, erx_tty:termios(Set)).

switching_to_raw_makes_the_line_readable_test() ->
    {_, Typed} = input(<<"ab">>, erx_tty:new()),
    {[], Waiting} = erx_tty:read_wait(r, 4096, Typed),
    {ok, [{ready, r}], Raw} = erx_tty:set(erx_tty:termios(raw(1, 0)), Waiting),
    ?assertMatch({{ok, <<"ab">>}, _}, erx_tty:read(r, 64, Raw)).

%% POSIX's four cases, each driven event by event.
vmin_and_vtime_test() ->
    %% VMIN 2, VTIME 0: ready at two bytes.
    {[], W1} = erx_tty:read_wait(r, 4096, raw(2, 0)),
    {[], W2} = input(<<"a">>, W1),
    {[{ready, r}], W3} = input(<<"b">>, W2),
    {{ok, <<"ab">>}, _} = erx_tty:read(r, 64, W3),
    %% VMIN 3, VTIME 1: the first byte starts a timer, and later bytes keep
    %% its deadline, as FreeBSD's interbyte timer does.
    {[], T0} = erx_tty:read_wait(r, 4096, raw(3, 1)),
    {[{timer_start, Timer1, 100}], T1} = input(<<"a">>, T0),
    {[], T2} = input(<<"b">>, T1),
    {[], T2} = erx_tty:timer({r, 999}, T2),
    {[{ready, r}], T3} = erx_tty:timer(Timer1, T2),
    {{ok, <<"ab">>}, _} = erx_tty:read(r, 64, T3),
    %% VMIN 0, VTIME 1: the wait starts the timer; its end gives no bytes.
    {[{timer_start, Timer2, 100}], E1} = erx_tty:read_wait(r, 4096, raw(0, 1)),
    {[{ready, r}], E2} = erx_tty:timer(Timer2, E1),
    {{ok, <<>>}, _} = erx_tty:read(r, 64, E2),
    {[{timer_start, Timer3, 100}], F1} = erx_tty:read_wait(r, 4096, raw(0, 1)),
    {[{timer_cancel, Timer3}, {ready, r}], _} = input(<<"a">>, F1),
    %% VMIN 0, VTIME 0: at once, with whatever waits.
    {[{ready, r}], Z} = erx_tty:read_wait(r, 4096, raw(0, 0)),
    {{ok, <<>>}, _} = erx_tty:read(r, 64, Z).

hangup_readies_every_waiter_test() ->
    {[], W} = erx_tty:poll_wait(p, element(2, erx_tty:read_wait(r, 4096, erx_tty:new()))),
    {[{ready, p}, {ready, r}], H} = erx_tty:hangup(W),
    eof = element(1, erx_tty:read(r, 64, H)),
    eof = element(1, erx_tty:read(r, 64, element(3, erx_tty:set(erx_tty:termios(raw(0, 0)), H)))).

%% A hangup drops the input the tty holds, a line ended and one being typed, as
%% FreeBSD's carrier loss flushes the input queue: every later read is the end of file.
hangup_drops_the_input_test() ->
    {[], H} = erx_tty:hangup(element(2, input(<<"ab\ncd">>, erx_tty:new()))),
    eof = element(1, erx_tty:read(r, 64, H)),
    eof = element(1, erx_tty:read(r, 64, element(3, erx_tty:set(erx_tty:termios(raw(1, 0)), H)))).

%%% Lost input (docs/design-live.md, "Lost input")

%% A loss is one unit among the bytes: a read gives it as one NUL at its
%% place, read_input/2 as `lost`, and a short read leaves the rest in order.
%% read_input/2 that finds nothing is `eagain` even where read/3 would
%% answer no bytes, raw with VMIN 0.
a_raw_loss_is_one_unit_at_its_place_test() ->
    {[], W0} = erx_tty:read_wait(r, 4096, raw(5, 0)),
    {[], W1} = input(<<"ab">>, W0),
    {[], W2} = erx_tty:lost(W1),
    {[], W3} = input(<<"c">>, W2),
    {[{ready, r}], W4} = input(<<"d">>, W3),
    ?assertEqual(5, erx_tty:waiting(W4)),
    ?assertMatch({{ok, <<"ab", 0, "cd">>}, _}, erx_tty:read(r, 5, W4)),
    {{ok, <<"ab">>}, Short} = erx_tty:read(r, 2, W4),
    ?assertMatch({{ok, <<0, "cd">>}, _}, erx_tty:read(r, 5, Short)),
    {Units, _} = lists:mapfoldl(fun(_, T) -> erx_tty:read_input(r, T) end, W4, lists:seq(1, 6)),
    ?assertEqual([{ok, <<"a">>}, {ok, <<"b">>}, lost, {ok, <<"c">>}, {ok, <<"d">>}, eagain], Units),
    ?assertMatch({eagain, _}, erx_tty:read_input(r, raw(0, 0))).

%% A loss alone readies what one byte readies, and starts the timer one
%% byte starts: lost/1 returns what input/3 returns for a byte that ends no
%% line and makes no signal.
a_loss_alone_is_ready_as_a_byte_is_test() ->
    {[], R} = erx_tty:read_wait(r, 4096, raw(1, 0)),
    ?assertMatch({[{ready, r}], _}, erx_tty:lost(R)),
    {[], P} = erx_tty:poll_wait(p, raw(0, 0)),
    {[{ready, p}], Polled} = erx_tty:lost(P),
    ?assertMatch({lost, _}, erx_tty:read_input(r, Polled)),
    {[], T} = erx_tty:read_wait(r, 4096, raw(2, 1)),
    {[{timer_start, _, 100}], _} = erx_tty:lost(T),
    ?assertEqual(element(1, input(<<"a">>, T)), element(1, erx_tty:lost(T))),
    %% Losses with no byte between them are one.
    {_, Twice} = erx_tty:lost(element(2, erx_tty:lost(raw(1, 0)))),
    ?assertMatch({{ok, <<0>>}, _}, erx_tty:read(r, 64, Twice)).

%% A byte dropped for room is a loss at its place, kept though the bytes
%% fill the bound, and the drops after it are the same loss.
a_byte_dropped_for_room_is_a_loss_test() ->
    {[], Full} = input(<<(binary:copy(<<"a">>, 4096))/binary, "xyz">>, raw(1, 0)),
    ?assertEqual({4097, 3}, {erx_tty:waiting(Full), erx_tty:dropped(Full)}),
    {{ok, Read}, _} = erx_tty:read(r, 4097, Full),
    ?assertEqual(<<(binary:copy(<<"a">>, 4096))/binary, 0>>, Read).

%% In a cooked line a loss is a unit of the line: an erase removes the
%% bytes before it and keeps it at the line's new end, and only an edit
%% that removes the line's last byte drops it; a loss and VEOF read as one
%% NUL.
a_cooked_line_keeps_its_loss_test() ->
    {_, Typed} = input(<<"cd">>, erx_tty:new()),
    {[], Lost} = erx_tty:lost(Typed),
    {_, Slash} = input(<<"/">>, Lost),
    {_, Erased} = input(<<127>>, Slash),
    {_, Ended} = input(<<"\n">>, Erased),
    ?assertMatch({{ok, <<"cd", 0, "\n">>}, _}, erx_tty:read(r, 64, Ended)),
    {_, Erased2} = input(<<127, 127>>, Erased),
    ?assertMatch({{ok, <<"\n">>}, _}, erx_tty:read(r, 64, element(2, input(<<"\n">>, Erased2)))),
    {_, Killed} = input(<<21, "\n">>, Erased),
    ?assertMatch({{ok, <<"\n">>}, _}, erx_tty:read(r, 64, Killed)),
    %% "ab", a loss, VERASE and a newline read as "a", NUL and a newline.
    {_, Ab} = input(<<"ab">>, erx_tty:new()),
    {_, AbErased} = input(<<127, "\n">>, element(2, erx_tty:lost(Ab))),
    ?assertMatch({{ok, <<"a", 0, "\n">>}, _}, erx_tty:read(r, 64, AbErased)),
    {_, Eof} = input(<<4>>, element(2, erx_tty:lost(erx_tty:new()))),
    ?assertMatch({{ok, <<0>>}, _}, erx_tty:read(r, 64, Eof)),
    %% ICANON cleared over a line with a loss: the loss is readable in its place.
    {_, Line} = input(<<"b">>, element(2, erx_tty:lost(element(2, input(<<"a">>, erx_tty:new()))))),
    {ok, _, Raw} = erx_tty:set(erx_tty:termios(raw(1, 0)), Line),
    ?assertMatch({{ok, <<"a", 0, "b">>}, _}, erx_tty:read(r, 64, Raw)).

%% A loss goes only with the last byte an edit removes: on a line holding a
%% loss and no byte, VERASE, VWERASE and VKILL find nothing and end
%% nothing, as a key that leaves edlin's empty buffer empty clears no damage;
%% erasing a byte typed after the loss takes it.
an_edit_that_removes_no_byte_keeps_the_loss_test() ->
    {[], Lost} = erx_tty:lost(erx_tty:new()),
    Line = fun(Key) ->
                   {_, Edited} = input(<<Key, "\n">>, Lost),
                   {element(1, erx_tty:read(r, 64, Edited)), Key}
           end,
    ?assertEqual([{{ok, <<0, "\n">>}, Key} || Key <- [127, $\^W, $\^U]],
                 [Line(Key) || Key <- [127, $\^W, $\^U]]),
    {_, Erased} = input(<<"x", 127, "\n">>, Lost),
    ?assertMatch({{ok, <<"\n">>}, _}, erx_tty:read(r, 64, Erased)).

%% A signal's flush drops the losses with the bytes, and reports that it
%% dropped one ahead of the signal; a flush that drops none reports nothing.
a_flush_reports_the_loss_it_drops_test() ->
    {_, Typed} = input(<<"rm ">>, erx_tty:new()),
    {[], Lost} = erx_tty:lost(Typed),
    {Actions, Flushed} = input(<<28>>, Lost),
    ?assertMatch([flush_output, flushed_loss, {echo, _}, {signal, sigquit}], Actions),
    ?assertMatch({{ok, <<"\n">>}, _}, erx_tty:read(r, 64, element(2, input(<<"\n">>, Flushed)))),
    {Clean, _} = input(<<28>>, Typed),
    ?assertNot(lists:member(flushed_loss, Clean)),
    {Kept, _} = input(<<28>>, element(2, erx_tty:lost(with([noflsh], [], erx_tty:new())))),
    ?assertNot(lists:member(flushed_loss, Kept)).

%% All of Bytes, as an owner feeds them with Room for the master: input/3
%% again on what a signal key left untaken, with the room it returned,
%% the actions joined in order.
input(Bytes, Tty) -> input(Bytes, ?ROOM, Tty).

input(Bytes, Room, Tty) when is_integer(Room) ->
    input(Bytes, {Room, 0, false}, Tty);
input(Bytes, Room, Tty) ->
    case erx_tty:input(Bytes, Room, Tty) of
        {Actions, <<>>, _, Tty1} -> {Actions, Tty1};
        {Actions, Rest, Left, Tty1} ->
            {More, Tty2} = input(Rest, Left, Tty1),
            {Actions ++ More, Tty2}
    end.

echoed(Actions) -> iolist_to_binary([Bytes || {echo, Bytes} <- Actions]).

%% Fun's value, from a process killed past a heap of 1 Mi words, and an
% error if it took 10 M reductions or more.
bounded(Fun) ->
    Measured = fun() ->
                       {reductions, Before} = process_info(self(), reductions),
                       Value = Fun(),
                       {reductions, After} = process_info(self(), reductions),
                       exit({value, Value, After - Before})
               end,
    {Pid, Ref} = spawn_opt(Measured,
                           [monitor, {max_heap_size, #{size => 1 bsl 20, kill => true}}]),
    receive
        {'DOWN', Ref, process, Pid, {value, Value, Work}} when Work < 10000000 -> Value;
        {'DOWN', Ref, process, Pid, Reason} -> error({over_bound, Reason})
    end.

%%% Exploration

-record(model, {tty, spec, waiting = #{}, armed = #{}, expired = [], stale = []}).
-record(spec, {ready = [], line = [], stopped = false, hungup = false}).

-define(COOKED_KEYS, [$a, $\s, $\r, $\n, 127, 21, 23, 4, 3, 20, 19, 17, 18]).
-define(RAW_KEYS, [$a, $\r, 3]).

explore_test_() ->
    Cooked = erx_tty:new(),
    Configs =
        [{cooked, Cooked, ?COOKED_KEYS, 4},
         {cooked_quiet, with([], [echo], Cooked), ?COOKED_KEYS, 4},
         {cooked_echonl, with([echonl], [echo, ixon], Cooked), ?COOKED_KEYS, 4},
         {cooked_plain_erase, with([], [echoe, echoctl, opost], Cooked), ?COOKED_KEYS, 4},
         {cooked_noflsh_altwerase, with([noflsh, altwerase], [ixany], Cooked), ?COOKED_KEYS, 4},
         {cooked_no_iexten, with([istrip], [iexten], Cooked), ?COOKED_KEYS, 4},
         {cooked_cr_maps, with([igncr, inlcr], [], Cooked), ?COOKED_KEYS, 4},
         {cooked_no_isig, with([], [isig, icrnl], Cooked), ?COOKED_KEYS, 4},
         {raw_vmin1, raw(1, 0), ?RAW_KEYS, 6},
         {raw_vmin2, raw(2, 0), ?RAW_KEYS, 6},
         {raw_vmin2_vtime1, raw(2, 1), ?RAW_KEYS, 6},
         {raw_vtime1, raw(0, 1), ?RAW_KEYS, 6},
         {raw_poll, raw(0, 0), ?RAW_KEYS, 6},
         {raw_isig_echo, with([isig, echo, ixon], [], raw(2, 1)), ?RAW_KEYS, 6}],
    [{atom_to_list(Name), {timeout, 300, fun() -> explore(Tty, Keys, Depth) end}}
     || {Name, Tty, Keys, Depth} <- Configs].

explore(Tty, Keys, Depth) ->
    explore(#model{tty = Tty, spec = #spec{}}, Keys, Depth, []).

explore(_, _, 0, _) ->
    ok;
explore(Model, Keys, Depth, Path) ->
    lists:foreach(fun(Event) ->
                          Next = step(Event, Model, [Event | Path]),
                          explore(Next, Keys, Depth - 1, [Event | Path])
                  end, events(Model, Keys)).

events(#model{armed = Armed, stale = Stale}, Keys) ->
    [{input, <<Key>>} || Key <- Keys] ++
        [{read_wait, r, 4096}, {read_wait, s, 1}, {poll_wait, p}, {cancel, r},
         {read, r, 1}, {read, s, 64}, {output, <<"a\n\tb">>, 3}, toggle, hangup, lost] ++
        [{timer, Timer} || Timer <- lists:sort(maps:keys(Armed))] ++
        [{timer, Timer} || Timer <- lists:sublist(Stale, 1)].

step({input, <<Key>> = Bytes}, #model{tty = Tty, spec = Spec} = M, Path) ->
    {Actions, Rest, _, Tty1} = erx_tty:input(Bytes, {?ROOM, 0, Spec#spec.stopped}, Tty),
    property(Rest =:= <<>>, one_byte_left_untaken, Path),
    Spec1 = spec_key(Key, Spec, erx_tty:termios(Tty)),
    check_keyed(Key, Actions, erx_tty:termios(Tty), Spec#spec.stopped, Path),
    check_flushed_loss(Actions, Spec, Path),
    M1 = acted(Actions, input, M#model{tty = Tty1, spec = Spec1}, Path),
    check_interbyte(M, M1, Actions, Path),
    M1;
step(lost, #model{tty = Tty, spec = Spec} = M, Path) ->
    {Actions, Tty1} = erx_tty:lost(Tty),
    M1 = acted(Actions, input, M#model{tty = Tty1, spec = spec_lost(Spec, erx_tty:termios(Tty))}, Path),
    check_interbyte(M, M1, Actions, Path),
    M1;
step({read_wait, Open, Count}, #model{tty = Tty} = M, Path) ->
    {Actions, Tty1} = erx_tty:read_wait(Open, Count, Tty),
    acted(Actions, wait, (forget(Open, M))#model{tty = Tty1,
        waiting = (M#model.waiting)#{Open => {read, Count}}}, Path);
step({poll_wait, Open}, #model{tty = Tty} = M, Path) ->
    {Actions, Tty1} = erx_tty:poll_wait(Open, Tty),
    acted(Actions, wait, M#model{tty = Tty1, waiting = (M#model.waiting)#{Open => poll}}, Path);
step({cancel, Open}, #model{tty = Tty} = M, Path) ->
    {Actions, Tty1} = erx_tty:cancel(Open, Tty),
    acted(Actions, cancel, (forget(Open, M))#model{tty = Tty1,
        waiting = maps:remove(Open, M#model.waiting)}, Path);
step({timer, Timer}, #model{tty = Tty, armed = Armed} = M, Path) ->
    {Actions, Tty1} = erx_tty:timer(Timer, Tty),
    case maps:is_key(Timer, Armed) of
        true ->
            {Open, _} = Timer,
            property(Actions =:= [{ready, Open}], timer_end, Path),
            acted(Actions, {timer, Timer},
                  M#model{tty = Tty1, armed = maps:remove(Timer, Armed),
                          expired = [Open | M#model.expired]}, Path);
        false ->
            property(Actions =:= [], stale_timer, Path),
            M#model{tty = Tty1}
    end;
step({read, Open, Max}, #model{tty = Tty, spec = Spec} = M, Path) ->
    {Got, Tty1} = erx_tty:read(Open, Max, Tty),
    Expired = lists:member(Open, M#model.expired),
    {Want, Spec1} = spec_read(Max, Expired, Spec, erx_tty:termios(Tty)),
    property(Got =:= Want, read_differs, Path),
    M#model{tty = Tty1, spec = Spec1, expired = lists:delete(Open, M#model.expired)};
step({output, Bytes, Room}, #model{tty = Tty} = M, Path) ->
    {Taken, Out, Tty1} = erx_tty:output(Bytes, Room, Tty),
    Opost = has(opost, erx_tty:termios(Tty)),
    property(byte_size(Out) =< Room, output_over_room, Path),
    property(Opost orelse Out =:= binary:part(Bytes, 0, Taken), opost_clear_changes_bytes, Path),
    M#model{tty = Tty1};
step(toggle, #model{tty = Tty, spec = Spec} = M, Path) ->
    Termios = erx_tty:termios(Tty),
    #{lflag := L} = Termios,
    Flipped = case lists:member(icanon, L) of
                  true -> L -- [icanon];
                  false -> [icanon | L]
              end,
    {ok, Actions, Tty1} = erx_tty:set(Termios#{lflag := Flipped}, Tty),
    Spec1 = spec_switch(Spec, Termios#{lflag := Flipped}),
    acted(Actions, set, M#model{tty = Tty1, spec = Spec1, expired = []}, Path);
step(hangup, #model{tty = Tty, spec = Spec} = M, Path) ->
    {Actions, Tty1} = erx_tty:hangup(Tty),
    acted(Actions, hangup, M#model{tty = Tty1, spec = Spec#spec{hungup = true, ready = [], line = []}}, Path).

forget(Open, #model{expired = Expired} = M) ->
    M#model{expired = lists:delete(Open, Expired)}.

%% The actions of one event, in order, then the invariants of the state.
acted(Actions, Cause, M0, Path) ->
    M = lists:foldl(fun(Action, M) -> act(Action, Cause, M, Path) end, M0, Actions),
    Termios = erx_tty:termios(M#model.tty),
    property(spec_waiting(M#model.spec, Termios) =:= erx_tty:waiting(M#model.tty),
             waiting_differs, Path),
    maps:foreach(
      fun(Open, Kind) ->
              property(not spec_ready(Kind, M#model.spec, Termios), lost_wakeup, Path),
              Timers = [T || {O, _} = T <- maps:keys(M#model.armed), O =:= Open],
              property(lists:member(length(Timers), spec_timers(Kind, M#model.spec, Termios)),
                       timer_discipline, Path)
      end, M#model.waiting),
    Idle = [T || {O, _} = T <- maps:keys(M#model.armed), not maps:is_key(O, M#model.waiting)],
    property(Idle =:= [], timer_without_waiter, Path),
    M.

act({timer_cancel, Timer}, _, #model{armed = Armed, stale = Stale} = M, Path) ->
    property(maps:is_key(Timer, Armed), timer_cancel_unknown, Path),
    M#model{armed = maps:remove(Timer, Armed), stale = [Timer | Stale]};
act({timer_start, {Open, _} = Timer, Ms}, _, #model{armed = Armed} = M, Path) ->
    #{cc := #{vtime := Time}} = erx_tty:termios(M#model.tty),
    property(Ms =:= Time * 100 andalso not maps:is_key(Timer, Armed), timer_start, Path),
    M#model{armed = Armed#{Timer => Open}};
act({ready, Open}, Cause, #model{waiting = Waiting, spec = Spec} = M, Path) ->
    Kind = maps:get(Open, Waiting, none),
    Termios = erx_tty:termios(M#model.tty),
    Timed = case Cause of
                {timer, {Open, _}} -> true;
                _ -> false
            end,
    property(Kind =/= none, ready_without_waiter, Path),
    property(Timed orelse spec_ready(Kind, Spec, Termios), early_wakeup, Path),
    M#model{waiting = maps:remove(Open, Waiting)};
act(_, _, M, _) ->
    M.

%% Echo, signals and VSTATUS for one received byte.
check_keyed(Key, Actions, Termios, Stopped, Path) ->
    Char = case has(istrip, Termios) of
               true -> Key band 16#7f;
               false -> Key
           end,
    Echo = iolist_to_binary([Bytes || {echo, Bytes} <- Actions]),
    Signals = [A || A <- Actions, A =:= info orelse element(1, A) =:= signal],
    Isig = has(isig, Termios),
    Status = Isig andalso has(icanon, Termios) andalso has(iexten, Termios)
        andalso cc(vstatus, Char, Termios),
    Quiet = not has(echo, Termios),
    property(not Quiet orelse has(echonl, Termios) orelse
                 Echo =:= binary:copy(<<7>>, byte_size(Echo)),
             echo_without_echo, Path),
    property(Isig orelse Signals =:= [], signal_without_isig, Path),
    property(Status =:= lists:member(info, Actions), vstatus, Path),
    property(not Status orelse Echo =:= <<>>, vstatus_echoed, Path),
    property(not (Isig andalso cc(vintr, Char, Termios)) orelse
                 lists:member({signal, sigint}, Actions), vintr, Path),
    property(Stopped orelse not lists:member(start_output, Actions), start_unstopped, Path),
    property(not (Stopped andalso Signals =/= []) orelse lists:member(start_output, Actions),
             signal_left_output_stopped, Path).

%% A signal's flush reports flushed_loss, ahead of the signal, exactly
%% when the input it drops holds a loss.
check_flushed_loss(Actions, #spec{ready = Ready, line = Line}, Path) ->
    Dropped = lists:member(flush_output, Actions) andalso lists:member(lost, Ready ++ Line),
    property(lists:member(flushed_loss, Actions) =:= Dropped, flushed_loss, Path),
    Ahead = lists:dropwhile(fun(A) -> A =/= flushed_loss end, Actions),
    property(not Dropped orelse lists:keymember(signal, 1, Ahead), flushed_loss_order, Path).

%% Bytes that arrive for a raw read with VMIN and VTIME above 0 start its
%% timer when it has none and leave a running one alone: one deadline after
%% the first byte, as FreeBSD's interbyte timer sets it.
check_interbyte(#model{spec = #spec{ready = Before}, armed = Armed},
                #model{waiting = Waiting, spec = Spec} = M, Actions, Path) ->
    #{cc := #{vmin := Min, vtime := Time}} = Termios = erx_tty:termios(M#model.tty),
    Arrived = not has(icanon, Termios) andalso length(Spec#spec.ready) > length(Before),
    Started = fun(Open) -> lists:any(fun({timer_start, {O, _}, _}) -> O =:= Open;
                                        (_) -> false
                                     end, Actions)
              end,
    [property(Started(Open) =/= lists:member(Open, maps:values(Armed)),
              interbyte_deadline, Path)
     || Arrived, Min > 0, Time > 0, {Open, {read, _}} <- maps:to_list(Waiting)],
    ok.

property(true, _, _) -> ok;
property(false, Name, Path) -> error({property, Name, lists:reverse(Path)}).

%%% The reference: what a reader may get, by FreeBSD's rules, as lists.

spec_key(Key, Spec0, Tm) ->
    Spec = case has(ixany, Tm) of
               true -> Spec0#spec{stopped = false};
               false -> Spec0
           end,
    C = case has(istrip, Tm) of
            true -> Key band 16#7f;
            false -> Key
        end,
    Isig = has(isig, Tm),
    Status = Isig andalso has(icanon, Tm) andalso has(iexten, Tm) andalso cc(vstatus, C, Tm),
    Signal = Isig andalso lists:any(fun(V) -> cc(V, C, Tm) end, [vintr, vquit, vsusp]),
    Flow = has(ixon, Tm) andalso (cc(vstop, C, Tm) orelse cc(vstart, C, Tm)),
    if
        Status -> Spec#spec{stopped = false};
        Signal ->
            case has(noflsh, Tm) of
                true -> Spec#spec{stopped = false};
                false -> Spec#spec{ready = [], line = [], stopped = false}
            end;
        Flow ->
            Stop = cc(vstop, C, Tm) andalso not Spec#spec.stopped,
            Start = cc(vstart, C, Tm) andalso Spec#spec.stopped,
            Spec#spec{stopped = Stop orelse (Spec#spec.stopped andalso not Start)};
        true ->
            spec_edit(spec_map(C, Tm), Spec, Tm)
    end.

spec_map($\r, Tm) ->
    case {has(igncr, Tm), has(icrnl, Tm)} of
        {true, _} -> ignored;
        {false, true} -> $\n;
        {false, false} -> $\r
    end;
spec_map($\n, Tm) ->
    case has(inlcr, Tm) of
        true -> $\r;
        false -> $\n
    end;
spec_map(C, _) ->
    C.

spec_edit(ignored, Spec, _) ->
    Spec;
spec_edit(C, #spec{ready = Ready, line = Line} = Spec, Tm) ->
    Cooked = has(icanon, Tm),
    Ext = Cooked andalso has(iexten, Tm),
    Erase = Cooked andalso (cc(verase, C, Tm) orelse cc(verase2, C, Tm)),
    Kill = Cooked andalso cc(vkill, C, Tm),
    Word = Ext andalso cc(vwerase, C, Tm),
    Reprint = Ext andalso cc(vreprint, C, Tm),
    %% An edit that finds no byte changes nothing, a loss included.
    Bare = spec_bytes(Line) =:= [],
    if
        (Erase orelse Kill orelse Word) andalso Bare -> Spec;
        Erase -> Spec#spec{line = spec_truncate(Line, length(spec_bytes(Line)) - 1)};
        Kill -> Spec#spec{line = []};
        Word -> Spec#spec{line = spec_truncate(Line, length(spec_word(spec_bytes(Line), Tm)))};
        Reprint -> Spec;
        not Cooked -> Spec#spec{ready = Ready ++ [C]};
        true ->
            case spec_end(C, Tm) of
                true -> Spec#spec{ready = Ready ++ Line ++ [C], line = []};
                false -> Spec#spec{line = Line ++ [C]}
            end
    end.

spec_word(Line, Tm) ->
    White = fun(X) -> X =:= $\s orelse X =:= $\t end,
    case lists:dropwhile(White, lists:reverse(Line)) of
        [] ->
            [];
        [Last | _] = Reversed ->
            Alt = has(altwerase, Tm),
            Same = fun(X) -> not White(X) andalso (not Alt orelse alnum(X) =:= alnum(Last)) end,
            lists:reverse(lists:dropwhile(Same, Reversed))
    end.

%% A loss at the end of the held input, where the next byte would go,
%% unless the input ends with one: losses with no byte between are one.
spec_lost(#spec{ready = Ready, line = Line} = Spec, Tm) ->
    case {lists:reverse(Ready ++ Line), has(icanon, Tm)} of
        {[lost | _], _} -> Spec;
        {_, true} -> Spec#spec{line = Line ++ [lost]};
        {_, false} -> Spec#spec{ready = Ready ++ [lost]}
    end.

spec_bytes(Units) -> [U || U <- Units, U =/= lost].

%% A read's bytes: each loss one NUL.
spec_nuls(Units) -> list_to_binary([case U of lost -> 0; _ -> U end || U <- Units]).

%% The line's first Keep bytes with the losses among them, and one loss at
%% its end for those after them; nothing when no byte is kept.
spec_truncate(_, 0) -> [];
spec_truncate(Line, Keep) -> spec_truncate(Line, Keep, []).

spec_truncate(Rest, 0, Acc) -> lists:reverse(Acc) ++ [lost || lists:member(lost, Rest)];
spec_truncate([lost | Rest], Keep, Acc) -> spec_truncate(Rest, Keep, [lost | Acc]);
spec_truncate([C | Rest], Keep, Acc) -> spec_truncate(Rest, Keep - 1, [C | Acc]).

alnum(X) -> (X >= $0 andalso X =< $9) orelse (X >= $a andalso X =< $z) orelse (X >= $A andalso X =< $Z).

spec_end(C, Tm) -> C =:= $\n orelse cc(veof, C, Tm) orelse cc(veol, C, Tm).

spec_switch(#spec{ready = Ready, line = Line} = Spec, Tm) ->
    case has(icanon, Tm) of
        false -> Spec#spec{ready = Ready ++ Line, line = []};
        true -> Spec
    end.

%% The first line: {Data, Consumed} with VEOF dropped, or none.
spec_line(Ready, Tm) ->
    case lists:splitwith(fun(C) -> not spec_end(C, Tm) end, Ready) of
        {_, []} -> none;
        {Data, [End | _]} ->
            case cc(veof, End, Tm) of
                true -> {Data, true};
                false -> {Data ++ [End], false}
            end
    end.

spec_waiting(#spec{ready = Ready}, Tm) ->
    case has(icanon, Tm) of
        false -> length(Ready);
        true ->
            case spec_line(Ready, Tm) of
                none -> 0;
                {Data, _} -> length(Data)
            end
    end.

spec_ready(_, #spec{hungup = true}, _) ->
    true;
spec_ready(Kind, #spec{ready = Ready}, #{cc := #{vmin := Min, vtime := Time}} = Tm) ->
    case {has(icanon, Tm), Kind} of
        {true, _} -> spec_line(Ready, Tm) =/= none;
        {false, poll} -> length(Ready) >= 1;
        {false, {read, _}} when Min =:= 0, Time =:= 0 -> true;
        {false, {read, _}} when Min =:= 0 -> length(Ready) >= 1;
        {false, {read, Count}} -> length(Ready) >= min(Min, Count)
    end.

%% How many timers a waiting read may have: one when raw with VTIME and VMIN
%% 0 or a byte waits; with VMIN above 0 and no byte left, the timer of bytes
%% another read took may still run, and its end readies a read that finds
%% nothing and waits again.
spec_timers(poll, _, _) ->
    [0];
spec_timers({read, _}, #spec{ready = Ready}, #{cc := #{vmin := Min, vtime := Time}} = Tm) ->
    Timed = not has(icanon, Tm) andalso Time > 0,
    if
        Timed, Min =:= 0; Timed, Ready =/= [] -> [1];
        Timed -> [0, 1];
        true -> [0]
    end.

spec_read(Max, Expired, #spec{ready = Ready, hungup = Hungup} = Spec,
          #{cc := #{vmin := Min, vtime := Time}} = Tm) ->
    case has(icanon, Tm) of
        true ->
            case spec_line(Ready, Tm) of
                none when Hungup -> {eof, Spec};
{[], true} -> {eof, Spec#spec{ready = tl(Ready)}};
                none -> {eagain, Spec};
                {Data, Eof} ->
                    Got = lists:sublist(Data, Max),
                    Gone = case Eof andalso length(Got) =:= length(Data) of
                               true -> length(Got) + 1;
                               false -> length(Got)
                           end,
                    {{ok, spec_nuls(Got)}, Spec#spec{ready = lists:nthtail(Gone, Ready)}}
            end;
        false when Ready =:= [], Hungup ->
            {eof, Spec};
        false when Ready =:= [] ->
            case Min =:= 0 andalso (Time =:= 0 orelse Expired) of
                true -> {{ok, <<>>}, Spec};
                false -> {eagain, Spec}
            end;
        false ->
            Got = lists:sublist(Ready, Max),
            {{ok, spec_nuls(Got)}, Spec#spec{ready = lists:nthtail(length(Got), Ready)}}
    end.

%%% Helpers

has(Flag, #{iflag := I, oflag := O, cflag := C, lflag := L}) ->
    lists:member(Flag, I ++ O ++ C ++ L).

cc(Name, Char, #{cc := Chars}) ->
    maps:get(Name, Chars) =/= 255 andalso maps:get(Name, Chars) =:= Char.

%% The tty with flags set and cleared, wherever each belongs.
with(Set, Cleared, Tty) ->
    Termios = erx_tty:termios(Tty),
    Changed = maps:map(fun(Field, Flags) when is_list(Flags) ->
                               Known = erx_abi_termios:flags(Field),
                               (Flags -- Cleared) ++ [F || F <- Set, lists:member(F, Known)];
                          (_, Value) -> Value
                       end, Termios),
    {ok, _, Tty1} = erx_tty:set(Changed, Tty),
    Tty1.

%% As cfmakeraw leaves a tty, with VMIN and VTIME.
raw(Min, Time) ->
    Tty = with([], [ignbrk, brkint, parmrk, istrip, inlcr, igncr, icrnl, ixon, imaxbel, opost,
                    echo, echonl, icanon, isig, iexten], erx_tty:new()),
    Termios = erx_tty:termios(Tty),
    {ok, _, Raw} = erx_tty:set(Termios#{cc := (maps:get(cc, Termios))#{vmin := Min, vtime := Time}},
                               Tty),
    Raw.
