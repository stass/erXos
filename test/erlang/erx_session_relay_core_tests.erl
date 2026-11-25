%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_session_relay_core, the terminal relay's decisions
%% (docs/design-shell.md, "The terminal relay's protocol" and the
%% verification cases of "The terminal relay's protocol"), and an
%% exhaustive exploration of bounded event sequences over two shells, each
%% with a job that has an open made for reading and a write-only one, and
%% the console. test/host/erx_session_relay_core_test.rb seeds a fault for
%% each case.
%%
%% Processes are atoms: the console `console`, the shells `s1` and `s2`
%% with groups `g1` and `g2`, and the jobs' processes `pa`, `pb` and `pc`.
%% Opens are atoms too, named by the edge in the core.

-module(erx_session_relay_core_tests).
-include_lib("eunit/include/eunit.hrl").

-define(CORE, erx_session_relay_core).
-define(CTRL_C, <<3>>).
-define(CTRL_Z, <<26>>).
-define(CTRL_BACKSLASH, <<28>>).
-define(CTRL_D, <<4>>).

%%% A test relay: the core and the messages it sent, per receiver, not yet
%%% taken by the test.

%% typed: the number of the master's next input message.
-record(t, {core, inbox = #{} :: #{term() => [term()]}, typed = 0 :: non_neg_integer()}).

new() -> #t{core = ?CORE:new(console, #{master => present})}.

do(Caller, Request, #t{core = Core} = T) ->
    {Core1, [{answer, Answer} | Actions]} = ?CORE:request(Caller, Request, Core),
    {Answer, deliver(Actions, T#t{core = Core1})}.

%% A request that must be answered ok or {ok, _}.
ok(Caller, Request, T) ->
    case do(Caller, Request, T) of
        {ok, T1} -> T1;
        {{ok, _}, T1} -> T1;
        {Answer, _} -> error({refused, Request, Answer})
    end.

ev(Event, #t{core = Core} = T) ->
    {Core1, Actions} = ?CORE:event(Event, Core),
    deliver(Actions, T#t{core = Core1}).

type(Bytes, #t{typed = N} = T) -> ev({master, {tty_input, N, Bytes}}, T#t{typed = N + 1}).

lose(#t{typed = N} = T) -> ev({master, {tty_lost, N}}, T#t{typed = N + 1}).

deliver(Actions, #t{inbox = Inbox} = T) ->
    T#t{inbox = lists:foldl(fun({send, To, Message}, Acc) ->
                                    maps:update_with(To, fun(Old) -> Old ++ [Message] end,
                                                     [Message], Acc);
                               ({output, _N, Bytes}, Acc) ->
                                    maps:update_with(master, fun(Old) -> Old ++ [Bytes] end,
                                                     [Bytes], Acc);
                               ({timer_start, Timer, _Ms}, Acc) ->
                                    maps:update_with(timers, fun(Old) -> Old ++ [Timer] end,
                                                     [Timer], Acc);
                               (_Other, Acc) -> Acc
                            end, Inbox, Actions)}.

%% The messages To was sent since it last took them.
take(To, #t{inbox = Inbox} = T) ->
    {maps:get(To, Inbox, []), T#t{inbox = maps:remove(To, Inbox)}}.

%% The one report To was sent, `{Kind, N}`.
report(To, Open, T) ->
    {Messages, T1} = take(To, T),
    ?assertMatch([{ready, Open, [_], _}], Messages),
    [{ready, Open, [Kind], N}] = Messages,
    {Kind, N, T1}.

no_report(To, T) ->
    {Messages, T1} = take(To, T),
    ?assertEqual([], [M || {ready, _, _, _} = M <- Messages]),
    T1.

open(Maker, Holder, Mode, Open, T) -> ok(Maker, {open, Holder, Mode, Open}, T).

%% A relay with the console's open `c` and job a's `ar` (read) and `aw`
%% (write-only), b's `br` and `bw`.
opened() ->
    lists:foldl(fun({Maker, Holder, Mode, Open}, T) -> open(Maker, Holder, Mode, Open, T) end,
                new(),
                [{console, console, read, c}, {pa, a, read, ar}, {pa, a, write, aw},
                 {pb, b, read, br}, {pb, b, write, bw}]).

fg(Shell, Target, Signals, T) ->
    Request = case Target of
                  console -> {foreground, console, Signals};
                  {Tag, Mode} -> {foreground, Tag, Mode, Signals}
              end,
    {Answer, T1} = do(Shell, Request, T),
    ?assertMatch({ok, _, _}, Answer),
    T1.

%% A holding the cooked terminal, given by s1 under g1.
a_holds() -> fg(s1, {a, cooked}, {g1, 0}, opened()).

termios(T) -> ?CORE:termios(T#t.core).

has(Flag, Word, Termios) -> lists:member(Flag, maps:get(Word, Termios)).

with(Word, Set, Clear, Chars, Termios) ->
    Flags = lists:usort((maps:get(Word, Termios) -- Clear) ++ Set),
    (Termios#{Word := Flags})#{cc := maps:merge(maps:get(cc, Termios), Chars)}.

signal_n(T) -> ?CORE:signal_number(T#t.core).

%%% The design's cases

%% Background: B's wait parks while A holds and arms at B's foreground.
background_test() ->
    T0 = ok(pb, {watch, br, [{read, 4096}]}, a_holds()),
    T1 = no_report(pb, type(<<"line\n">>, T0)),
    ?assertMatch({eagain, _}, do(pb, {tty_read, br, 4096, 0}, T1)),
    T2 = fg(s1, {b, cooked}, {g1, 0}, T1),
    {{read, 4096}, N, T3} = report(pb, br, T2),
    ?assertMatch({{ok, <<"line\n">>}, _}, do(pb, {tty_read, br, 4096, N}, T3)).

%% The console during a job: A's line goes to A, and the console reads the
%% next key only once it holds, unechoed.
the_console_during_a_job_test() ->
    T0 = ok(console, {watch, c, [{read, 1}]}, ok(pa, {watch, ar, [{read, 4096}]}, a_holds())),
    {_, N, T1} = report(pa, ar, type(<<"ls\n">>, T0)),
    T2 = no_report(console, T1),
    {{ok, <<"ls\n">>}, T3} = do(pa, {tty_read, ar, 4096, N}, T2),
    T4 = no_report(console, fg(s1, console, {g1, 0}, T3)),
    {_, N2, T5} = report(console, c, type(<<"k">>, T4)),
    ?assertMatch({{ok, <<"k">>}, _}, do(console, {tty_read, c, 1, N2}, T5)).

%% A read of one unit: a loss is `lost`, not a NUL; a write-only open may
%% not read; a stale signal number leaves the unit held.
read_input_test() ->
    T0 = type(<<"b">>, lose(type(<<"a">>, opened()))),
    T1 = ok(console, {watch, c, [{read, 1}]}, T0),
    {_, N, T2} = report(console, c, T1),
    {{ok, <<"a">>}, T3} = do(console, {tty_read_input, c, N}, T2),
    {eagain, T4} = do(console, {tty_read_input, c, N + 1}, T3),
    {lost, T5} = do(console, {tty_read_input, c, N}, T4),
    ?assertMatch({{ok, <<"b">>}, _}, do(console, {tty_read_input, c, N}, T5)),
    T6 = ok(pw, {open, console, write, w}, T5),
    ?assertMatch({{error, ebadf}, _}, do(pw, {tty_read_input, w, N}, T6)).

%% Input on demand: nothing reaches the console unasked, it reads a byte at
%% a time, and the rest stays in the tty for the next holder.
input_on_demand_test() ->
    T0 = type(<<"cat\nsecret\n">>, opened()),
    {[], T1} = take(console, T0),
    T2 = ok(console, {watch, c, [{read, 1}]}, T1),
    {_, N, T3} = report(console, c, T2),
    T4 = lists:foldl(fun(Byte, T) ->
                             {{ok, Got}, Tn} = do(console, {tty_read, c, 1, N}, T),
                             ?assertEqual(<<Byte>>, Got),
                             Tn
                     end, T3, "cat\n"),
    T5 = fg(s1, {a, cooked}, {g1, 0}, T4),
    T6 = ok(pa, {watch, ar, [{read, 4096}]}, T5),
    {_, Na, T7} = report(pa, ar, T6),
    ?assertMatch({{ok, <<"secret\n">>}, _}, do(pa, {tty_read, ar, 4096, Na}, T7)).

%% Ctrl-C at the prompt: the console gets the event for its named group,
%% and the typed input is gone.
ctrl_c_at_the_prompt_test() ->
    T0 = ok(console, {console_group, g1}, opened()),
    T1 = type(<<"abc", 3>>, T0),
    {[{erx_tty_event, g1, interrupt}], T2} = take(console, T1),
    T3 = no_report(console, ok(console, {watch, c, [{read, 1}]}, T2)),
    {_, _, _} = report(console, c, type(<<"z">>, T3)).

%% The swap, by libedit's rule.
the_swap_by_libedits_rule_test() ->
    Cooked = termios(a_holds()),
    Left = with(lflag, [], [echo], #{vstatus => $\^X}, Cooked),
    T0 = ok(pa, {tty, ar, {tcsetattr, Left}}, a_holds()),
    {{ok, Left1, 0}, T1} = do(s1, {foreground, console, {g1, 0}}, T0),
    ?assertEqual(Left, Left1),
    Editing = termios(T1),
    ?assert(has(isig, lflag, Editing) andalso has(icrnl, iflag, Editing)),
    ?assertNot(has(icanon, lflag, Editing) orelse has(echo, lflag, Editing)),
    ?assertMatch(#{vmin := 1, vtime := 0}, maps:get(cc, Editing)),
    T2 = fg(s1, {b, cooked}, {g1, 0}, T1),
    ?assert(has(echo, lflag, termios(T2))),
    ?assertMatch(#{vstatus := $\^X}, maps:get(cc, termios(T2))),
    Raw = with(lflag, [], [icanon], #{vstatus => $\^Y}, termios(T2)),
    T3 = fg(s1, {c, cooked}, {g1, 0}, fg(s1, console, {g1, 0}, ok(pb, {tty, br, {tcsetattr, Raw}}, T2))),
    ?assertMatch(#{vstatus := $\^X}, maps:get(cc, termios(T3))),
    %% A refused termios changes neither the holder nor the mode.
    {{error, einval}, T4} = do(s1, {foreground, b, Cooked#{lflag := [bogus]}, {g1, 0}}, T3),
    ?assertEqual({job, c}, ?CORE:holder(T4#t.core)),
    ?assertEqual(termios(T3), termios(T4)).

%% tcsetattr in the background.
tcsetattr_in_the_background_test() ->
    T0 = a_holds(),
    Raw = with(lflag, [], [icanon], #{}, termios(T0)),
    ?assertMatch({{background, false}, _}, do(pb, {tty, br, {tcsetattr, Raw}}, T0)),
    {{background, false}, T1} = do(pb, {tty, br, {tcsetattr, Raw}}, T0),
    ?assertEqual(termios(T0), termios(T1)),
    {ok, T2} = do(pb, {tty, bw, {tcsetattr, Raw, sigttou_ignored}}, T1),
    ?assertEqual(Raw, termios(T2)),
    %% TOSTOP comes with process groups and is refused.
    Tostop = with(lflag, [tostop], [], #{}, termios(T0)),
    ?assertMatch({{error, einval}, _}, do(pa, {tty, ar, {tcsetattr, Tostop}}, T0)),
    ?assertMatch({{error, einval}, _}, do(s1, {foreground, b, Tostop, {g1, 0}}, T0)).

%% A short raw read: a watch of {read, 1} under VMIN 10 is ready at a byte.
a_short_raw_read_test() ->
    T0 = a_holds(),
    Raw = with(lflag, [], [icanon], #{vmin => 10, vtime => 0}, termios(T0)),
    T1 = ok(pa, {watch, ar, [{read, 1}]}, ok(pa, {tty, ar, {tcsetattr, Raw}}, T0)),
    {_, N, T2} = report(pa, ar, type(<<"q">>, T1)),
    ?assertMatch({{ok, <<"q">>}, _}, do(pa, {tty_read, ar, 1, N}, T2)).

%% Opens: an open not made is ebadf, and so is one whose maker ended.
opens_test() ->
    T0 = a_holds(),
    ?assertMatch({{error, ebadf}, _}, do(pa, {tty, nothing, tcgetattr}, T0)),
    T1 = ev({down, pa}, T0),
    ?assertMatch({{error, ebadf}, _}, do(px, {tty, ar, tcgetattr}, T1)),
    ?assertMatch({{error, einval}, _}, do(pa, {watch, c, [{read, 0}]}, T1)),
    ?assertMatch({{error, einval}, _}, do(pa, nonsense, T1)).

%% Events: each action reaches the holder's shell with its job, and the
%% console's carry the group it named.
events_test() ->
    T0 = ok(pa, {watch, ar, [{read, 4096}]}, a_holds()),
    Info = <<20>>,
    T1 = ev({master, {tty_size, 30, 100}}, type(<<3, 26, 28>>, type(Info, T0))),
    {Events, T2} = take(s1, T1),
    ?assertEqual([{erx_tty_event, a, E} || E <- [info, interrupt, suspend, quit, winch]], Events),
    {[{erx_console_size, 30, 100}], T3} = take(console, T2),
    T4 = fg(s1, {a, current}, {g1, 3}, T3),
    {_, _, T5} = report(pa, ar, type(<<"k\n">>, T4)),
    T6 = type(?CTRL_C, fg(s1, {b, cooked}, {g1, 3}, T5)),
    {[{erx_tty_event, b, interrupt}], T7} = take(s1, T6),
    T8 = type(?CTRL_Z, fg(s1, console, {g1, 4}, T7)),
    {[{erx_tty_event, none, suspend}], T9} = take(console, T8),
    T10 = type(?CTRL_Z, ok(console, {console_group, g1}, T9)),
    {[{erx_tty_event, g1, suspend}], T11} = take(console, T10),
    T12 = type(?CTRL_Z, ok(console, {console_group, g2}, T11)),
    {[{erx_tty_event, g2, suspend}], T13} = take(console, T12),
    ?assertMatch({[], _}, take(s1, T13)).

%% A flush that drops a loss: while the console holds, `lost` reaches it
%% ahead of the signal, with the group it named; while a job holds, its
%% shell gets the signal alone, since no line read of the console's is in
%% progress (docs/design-shell.md, "The terminal relay's protocol").
a_flushed_loss_reaches_only_the_console_test() ->
    T0 = lose(type(<<"rm ">>, ok(console, {console_group, g1}, opened()))),
    {Console, _} = take(console, type(?CTRL_BACKSLASH, T0)),
    ?assertEqual([{erx_tty_event, g1, lost}, {erx_tty_event, g1, quit}], Console),
    T1 = lose(type(<<"rm ">>, a_holds())),
    {Shell, _} = take(s1, type(?CTRL_BACKSLASH, T1)),
    ?assertEqual([{erx_tty_event, a, quit}], Shell).

%% A signal suspends the job's reads, but not its writes or tcsetattr, and
%% makes a report delivered before it stale.
a_signal_suspends_the_jobs_reads_test() ->
    T0 = ok(pa, {watch, ar, [{read, 4096}]}, a_holds()),
    T1 = type(<<3, "ls\n">>, T0),
    {[{erx_tty_event, a, interrupt}], T2} = take(s1, T1),
    T3 = no_report(pa, T2),
    ?assertMatch({eagain, _}, do(pa, {tty_read, ar, 4096, 1}, T3)),
    ?assertMatch({{ok, 2}, _}, do(pa, {write, aw, <<"ok">>}, T3)),
    Raw = with(lflag, [], [icanon], #{}, termios(T3)),
    T4 = ok(pa, {tty, ar, {tcsetattr, Raw}}, T3),
    T5 = fg(s1, {a, current}, {g1, 1}, T4),
    {_, 1, T6} = report(pa, ar, T5),
    {{ok, <<"ls\n">>}, T7} = do(pa, {tty_read, ar, 4096, 1}, T6),
    ?assertEqual(Raw, termios(T7)),
    %% A report delivered before a signal is stale after it.
    T8 = ok(pa, {watch, ar, [{read, 4096}]}, T7),
    {_, 1, T9} = report(pa, ar, type(<<"q">>, T8)),
    T10 = type(<<3, "y\n">>, T9),
    ?assertMatch({eagain, _}, do(pa, {tty_read, ar, 4096, 1}, T10)),
    T11 = ok(pa, {watch, ar, [{read, 4096}]}, fg(s1, {a, current}, {g1, 2}, T10)),
    ?assertMatch({eagain, _}, do(pa, {tty_read, ar, 4096, 1}, T11)),
    {_, 2, T12} = report(pa, ar, T11),
    ?assertMatch({{ok, <<"y\n">>}, _}, do(pa, {tty_read, ar, 4096, 2}, T12)).

%% With NOFLSH a line typed before a signal key is reported in the same
%% input/3 after the signal, which parked the wait: no report comes until
%% the shell's current.
a_report_after_a_signal_in_one_input_test() ->
    T0 = a_holds(),
    Noflsh = with(lflag, [noflsh], [], #{}, termios(T0)),
    T1 = ok(pa, {watch, ar, [{read, 4096}]}, ok(pa, {tty, ar, {tcsetattr, Noflsh}}, T0)),
    T2 = type(<<"ab\n", 3>>, T1),
    {[{erx_tty_event, a, interrupt}], T3} = take(s1, T2),
    T4 = no_report(pa, T3),
    {_, 1, T5} = report(pa, ar, fg(s1, {a, current}, {g1, 1}, T4)),
    ?assertMatch({{ok, <<"ab\n">>}, _}, do(pa, {tty_read, ar, 4096, 1}, T5)).

%% Signal numbers: a current for the first of two signals ends nothing.
signal_numbers_test() ->
    T0 = ok(pa, {watch, ar, [{read, 4096}]}, a_holds()),
    T1 = type(<<3, 26, "bg\n">>, T0),
    {[{erx_tty_event, a, interrupt}, {erx_tty_event, a, suspend}], T2} = take(s1, T1),
    T3 = no_report(pa, fg(s1, {a, current}, {g1, 1}, T2)),
    ?assertMatch({eagain, _}, do(pa, {tty_read, ar, 4096, 2}, T3)),
    T4 = ok(console, {watch, c, [{read, 1}]}, fg(s1, console, {g1, 2}, T3)),
    {_, 2, T5} = report(console, c, T4),
    ?assertMatch({{ok, <<"b">>}, _}, do(console, {tty_read, c, 1, 2}, T5)),
    %% Another job given the terminal while Seen lags reads only after its current.
    T6 = fg(s1, {b, cooked}, {g1, 1}, T2),
    T7 = ok(pb, {watch, br, [{read, 4096}]}, T6),
    T8 = no_report(pb, T7),
    ?assertMatch({eagain, _}, do(pb, {tty_read, br, 4096, 2}, T8)),
    {_, 2, _} = report(pb, br, fg(s1, {b, current}, {g1, 2}, T8)).

%% Signals the console takes count for its group; its quit counts for none.
signals_the_console_takes_test() ->
    lists:foreach(
      fun(Key) ->
              T0 = type(Key, ok(console, {console_group, g1}, opened())),
              {[{erx_tty_event, g1, _}], T1} = take(console, T0),
              T2 = ok(pa, {watch, ar, [{read, 4096}]}, fg(s1, {a, cooked}, {g1, 0}, T1)),
              T3 = no_report(pa, type(<<"y\n">>, T2)),
              ?assertMatch({eagain, _}, do(pa, {tty_read, ar, 4096, 1}, T3)),
              {_, 1, T4} = report(pa, ar, fg(s1, {a, current}, {g1, 1}, T3)),
              ?assertMatch({{ok, <<"y\n">>}, _}, do(pa, {tty_read, ar, 4096, 1}, T4))
      end, [?CTRL_C, ?CTRL_Z]),
    T5 = type(?CTRL_BACKSLASH, ok(console, {console_group, g1}, opened())),
    T6 = ok(pa, {watch, ar, [{read, 4096}]}, fg(s1, {a, cooked}, {g1, 0}, T5)),
    {_, 1, _} = report(pa, ar, type(<<"y\n">>, T6)).

%% A console signal for another group counts for that group alone. The
%% core keeps no group of the last foreground while the console holds, so
%% the design's seeded fault for this case cannot be written against it.
a_console_signal_for_another_group_test() ->
    T0 = fg(s1, console, {g1, 0}, fg(s1, {l, cooked}, {g1, 0}, opened())),
    T1 = type(?CTRL_C, ok(console, {console_group, e}, T0)),
    {[{erx_tty_event, e, interrupt}], T2} = take(console, T1),
    T3 = fg(s1, {l, cooked}, {g1, 0}, ok(console, {console_group, g1}, T2)),
    T4 = open(pc, l, read, lr, T3),
    T5 = ok(pc, {watch, lr, [{read, 4096}]}, type(<<"x\n">>, T4)),
    {_, 1, T6} = report(pc, lr, T5),
    ?assertMatch({{ok, <<"x\n">>}, _}, do(pc, {tty_read, lr, 4096, 1}, T6)).

%% Refusals: a Seen above Sent, and current for a job that does not hold.
refusals_test() ->
    T0 = ok(pa, {watch, ar, [{read, 4096}]}, a_holds()),
    ?assertMatch({{error, einval}, _}, do(s1, {foreground, a, current, {g1, 1}}, T0)),
    ?assertMatch({{error, einval}, _}, do(s1, {foreground, b, cooked, {g1, 1}}, T0)),
    ?assertMatch({{error, einval}, _}, do(s1, {foreground, b, cooked, {g1, -1}}, T0)),
    ?assertMatch({{error, einval}, _}, do(s1, {foreground, b, cooked, {none, 0}}, T0)),
    {{error, einval}, T1} = do(s1, {foreground, a, current, {g1, 1}}, T0),
    {_, _, _} = report(pa, ar, type(<<"k\n">>, T1)),
    T2 = type(<<3, "k\n">>, T1),
    ?assertMatch({eagain, _}, do(pa, {tty_read, ar, 4096, 1}, T2)),
    T3 = ok(console, {watch, c, [{read, 1}]}, fg(s1, console, {g1, 0}, opened())),
    {{error, einval}, T4} = do(s1, {foreground, a, current, {g1, 0}}, T3),
    ?assertEqual(console, ?CORE:holder(T4#t.core)),
    {_, _, _} = report(console, c, type(<<"k">>, T4)).

%% Sent in the answer.
sent_in_the_answer_test() ->
    T0 = type(?CTRL_BACKSLASH, type(?CTRL_C, a_holds())),
    ?assertMatch({{ok, _, 2}, _}, do(s1, {foreground, a, current, {g1, 1}}, T0)).

%% The end of file: Ctrl-D at a line's start, an empty timed read, a hangup.
the_end_of_file_test() ->
    T0 = ok(pa, {watch, ar, [{read, 4096}]}, a_holds()),
    {_, N, T1} = report(pa, ar, type(?CTRL_D, T0)),
    {eof, T1a} = do(pa, {tty_read, ar, 4096, N}, T1),
    Timed = with(lflag, [], [icanon], #{vmin => 0, vtime => 1}, termios(T1a)),
    T2 = ok(pa, {tty, ar, {tcsetattr, Timed}}, T1a),
    {[Timer], T3} = take(timers, ok(pa, {watch, ar, [{read, 4096}]}, T2)),
    T4 = no_report(pa, T3),
    {_, N2, T5} = report(pa, ar, ev({timer, Timer}, T4)),
    ?assertMatch({{ok, <<>>}, _}, do(pa, {tty_read, ar, 4096, N2}, T5)),
    T6 = ev({master, tty_hangup}, T5),
    ?assertMatch({eof, _}, do(pa, {tty_read, ar, 4096, N2}, T6)).

%% A hangup tells the console at once, with no read waiting while a job holds, and
%% drops the input typed before it, so the job's next read is the end of file.
a_hangup_tells_the_console_at_once_test() ->
    {_, T0} = take(console, type(<<"ab\n">>, a_holds())),
    T1 = ev({master, tty_hangup}, T0),
    ?assertMatch({[erx_console_eof], _}, take(console, T1)),
    {_, N, T2} = report(pa, ar, ok(pa, {watch, ar, [{read, 4096}]}, T1)),
    ?assertMatch({eof, _}, do(pa, {tty_read, ar, 4096, N}, T2)).

%% Two shells keep their own numbers.
two_shells_test() ->
    T0 = type(?CTRL_C, a_holds()),
    {[{erx_tty_event, a, interrupt}], T1} = take(s1, T0),
    T2 = ok(console, {console_group, g2}, fg(s1, console, {g1, 1}, T1)),
    T3 = ok(pb, {watch, br, [{read, 4096}]}, fg(s2, {b, cooked}, {g2, 0}, T2)),
    {_, 1, T4} = report(pb, br, type(<<"x\n">>, T3)),
    {{ok, <<"x\n">>}, T5} = do(pb, {tty_read, br, 4096, 1}, T4),
    T6 = type(?CTRL_C, T5),
    {[{erx_tty_event, b, interrupt}], T7} = take(s2, T6),
    {[], T8} = take(s1, T7),
    T9 = ok(console, {console_group, g1}, fg(s2, console, {g2, 1}, T8)),
    T10 = open(pc, c2, read, cr, fg(s1, {c2, cooked}, {g1, 1}, T9)),
    {_, 2, _} = report(pc, cr, ok(pc, {watch, cr, [{read, 4096}]}, type(<<"y\n">>, T10))).

%% A shell that ends while its job holds gives the terminal to the console.
a_shell_that_ends_while_its_job_holds_test() ->
    T0 = ok(console, {watch, c, [{read, 1}]}, fg(s2, {b, cooked}, {g2, 0}, opened())),
    T1 = no_report(console, T0),
    T2 = ev({down, g2}, T1),
    ?assertEqual(console, ?CORE:holder(T2#t.core)),
    ?assertNot(has(icanon, lflag, termios(T2))),
    {_, _, T3} = report(console, c, type(<<"k">>, T2)),
    {[{erx_tty_event, none, interrupt}], _} = take(console, type(?CTRL_C, T3)).

%% The mode: a write-only open never reads, but polls, writes and sets.
the_mode_test() ->
    T0 = type(<<"ls\n">>, a_holds()),
    ?assertMatch({{error, ebadf}, _}, do(pa, {watch, aw, [{read, 4096}]}, T0)),
    ?assertMatch({{error, ebadf}, _}, do(pa, {tty_read, aw, 4096, signal_n(T0)}, T0)),
    {_, _, T1} = report(pa, aw, ok(pa, {watch, aw, [in]}, T0)),
    ?assertMatch({{ok, 1}, _}, do(pa, {write, aw, <<"!">>}, T1)),
    T2 = ok(pa, {tty, aw, {tcsetattr, termios(T1)}}, T1),
    T3 = ok(pa, {watch, ar, [{read, 4096}]}, T2),
    {_, N, T4} = report(pa, ar, T3),
    ?assertMatch({{ok, <<"ls\n">>}, _}, do(pa, {tty_read, ar, 4096, N}, T4)).

%%% Output and the link

%% Writes take the room the link holds, echo shares it, and the master's
%% taken frees it; a writer's message waits for room in order.
output_takes_the_links_room_test() ->
    Raw = with(oflag, [], [opost], #{}, termios(a_holds())),
    T0 = ok(pa, {tty, ar, {tcsetattr, Raw}}, a_holds()),
    Big = binary:copy(<<"x">>, 4096),
    {{ok, 4096}, T1} = do(pa, {write, aw, Big}, T0),
    ?assertMatch({eagain, _}, do(pa, {write, aw, <<"y">>}, T1)),
    T2 = ok(pa, {watch, aw, [out]}, T1),
    T3 = ev({write, {pw, written}, <<"later">>}, no_report(pa, T2)),
    {[], T4} = take(pw, T3),
    T5 = ev({master, {tty_taken, 0}}, T4),
    {[written], T6} = take(pw, T5),
    {_, _, _} = report(pa, aw, T6).

%% Output processing follows the message, not the holder. A program's bytes,
%% a writer's message, take the holder's OPOST and ONLCR: an LF goes out
%% CR-LF, and a CR-LF the program wrote goes out CR CR LF, as on FreeBSD.
%% The console's rendering, made for the terminal already, goes out as it
%% is, while a cooked job holds as while the console edits.
output_processing_follows_the_message_test() ->
    T0 = ev({rendered, {console, r}, <<"c\r\n">>}, ev({write, {pw, w}, <<"a\nb\r\n">>}, a_holds())),
    ?assertMatch({[w], _}, take(pw, T0)),
    ?assert(lists:member(r, element(1, take(console, T0)))),
    {Cooked, N, T1} = master_bytes(0, T0),
    ?assertEqual(<<"a\r\nb\r\r\nc\r\n">>, Cooked),
    T2 = fg(s1, console, {g1, 0}, T1),
    T3 = ev({rendered, {console, r}, <<"% \r\n">>}, ev({write, {pw, w}, <<"bg\n">>}, T2)),
    ?assertMatch({<<"bg\r\n% \r\n">>, _, _}, master_bytes(N, T3)).

%% What the master got from its output N on, taking each output as the console
%% does, and the number of the next output.
master_bytes(N, T) ->
    case take(master, T) of
        {[], T1} ->
            {<<>>, N, T1};
        {Outs, T1} ->
            Next = N + length(Outs),
            Taken = lists:foldl(fun(I, Acc) -> ev({master, {tty_taken, I}}, Acc) end,
                                T1, lists:seq(N, Next - 1)),
            {More, Last, T2} = master_bytes(Next, Taken),
            {iolist_to_binary([Outs, More]), Last, T2}
    end.

%% With OPOST clear a program's LF stays LF.
a_raw_jobs_newline_stays_a_newline_test() ->
    Raw = with(oflag, [], [opost], #{}, termios(a_holds())),
    T0 = ev({write, {pw, w}, <<"a\n">>}, ok(pa, {tty, ar, {tcsetattr, Raw}}, a_holds())),
    {Out, _} = take(master, T0),
    ?assertEqual(<<"a\n">>, iolist_to_binary(Out)).

%% A message the room takes part of keeps its kind for the rest: the rest of
%% the console's rendering goes out as it is, and a program's write behind it
%% is processed, though a cooked job holds.
a_held_rest_keeps_its_kind_test() ->
    Fill = binary:copy(<<"x">>, 4095),
    T0 = ev({write, {pw, w}, <<"p\n">>}, ev({rendered, {console, r}, <<Fill/binary, "ab\n">>}, a_holds())),
    {Out0, T1} = take(master, T0),
    ?assertEqual(<<Fill/binary, "a">>, iolist_to_binary(Out0)),
    {Out1, _} = take(master, ev({master, {tty_taken, 0}}, T1)),
    ?assertEqual(<<"b\np\r\n">>, iolist_to_binary(Out1)).

%% A signal's flush drops the held output and the writers' messages, but
%% the outstanding output stays, and the room is the link's.
a_flush_drops_what_is_held_test() ->
    Raw = with(oflag, [], [opost], #{}, termios(a_holds())),
    T0 = ok(pa, {tty, ar, {tcsetattr, Raw}}, a_holds()),
    {{ok, 4096}, T1} = do(pa, {write, aw, binary:copy(<<"x">>, 4096)}, T0),
    T2 = ev({write, {pw, written}, <<"more">>}, T1),
    T3 = type(?CTRL_C, T2),
    {[written], T4} = take(pw, T3),
    ?assertMatch({eagain, _}, do(pa, {write, aw, <<"y">>}, T4)),
    T5 = ev({master, {tty_taken, 0}}, T4),
    ?assertMatch({{ok, 1}, _}, do(pa, {write, aw, <<"y">>}, T5)).

%% VSTOP holds echo and output in the link until VSTART lets them go; a
%% write while output is stopped fills what the link holds, as FreeBSD's
%% does, and an out watch is reported while there is room.
stopped_output_holds_echo_test() ->
    NoIxany = with(iflag, [], [ixany], #{}, termios(a_holds())),
    T0 = ok(pa, {tty, ar, {tcsetattr, NoIxany}}, a_holds()),
    T1 = type(<<"ab">>, type(<<19>>, T0)),
    {[], T2} = take(master, T1),
    {{ok, 1}, T3} = do(pa, {write, aw, <<"x">>}, T2),
    {_, _, T4} = report(pa, aw, ok(pa, {watch, aw, [out]}, T3)),
    {[], T5} = take(master, T4),
    {[<<"abx">>], _} = take(master, type(<<17>>, T5)).

%% A signal key's flush drops what is held before anything of the step
%% reaches the master, as FreeBSD wakes the device once, at
%% ttydisc_rint_done: echo held by VSTOP and `abc` typed before the key
%% in the same input are dropped, and the master gets the key's echo
%% alone, whether or not output was stopped.
a_signal_drops_held_output_before_any_send_test() ->
    NoIxany = with(iflag, [], [ixany], #{}, termios(a_holds())),
    T0 = ok(pa, {tty, ar, {tcsetattr, NoIxany}}, a_holds()),
    T1 = type(<<"xyz">>, type(<<19>>, T0)),
    {[], T2} = take(master, T1),
    {[<<"^C">>], _} = take(master, type(<<"abc", 3>>, T2)),
    {[<<"^C">>], _} = take(master, type(<<"abc", 3>>, T0)).

%% A drain is answered once the master has taken everything, or at once
%% while output is stopped.
a_drain_waits_for_the_master_test() ->
    T0 = ev({drain, {ph, drained}}, a_holds()),
    {[drained], T1} = take(ph, T0),
    {{ok, 2}, T2} = do(pa, {write, aw, <<"hi">>}, T1),
    T3 = ev({drain, {ph, drained}}, T2),
    {[], T4} = take(ph, T3),
    {[drained], _} = take(ph, ev({master, {tty_taken, 0}}, T4)),
    T5 = ev({drain, {ph, drained}}, type(<<19>>, T2)),
    {[drained], _} = take(ph, T5).

%% An out wait is reported once the room fits the widest rendering of one
%% byte, not at one free byte as FreeBSD's poll is, at which a newline
%% under ONLCR is eagain: with one byte free the watch waits for the
%% master's take.
an_out_wait_waits_for_room_for_any_byte_test() ->
    {{ok, 4095}, T1} = do(pa, {write, aw, binary:copy(<<"x">>, 4095)}, a_holds()),
    {eagain, T2} = do(pa, {write, aw, <<"\n">>}, T1),
    T3 = no_report(pa, ok(pa, {watch, aw, [out]}, T2)),
    {out, _, _} = report(pa, aw, ev({master, {tty_taken, 0}}, T3)).

%% A writer that keeps adding between the master's takes does not hold an
%% out wait off: after a newline found too little room, the take of output
%% 0 leaves 2049 bytes free and the take of output 1, after the writer
%% added 411, 3685, and each reports the watch. A rule that waited, after a
%% short write, for nine tenths of the 4 KiB free reported neither.
a_steady_writer_does_not_hold_an_out_wait_off_test() ->
    T1 = ev({write, {pw, written}, binary:copy(<<"x">>, 2048)}, a_holds()),
    T2 = ev({write, {pw, written}, binary:copy(<<"x">>, 2047)}, T1),
    {eagain, T3} = do(pa, {write, aw, <<"\n">>}, T2),
    T4 = no_report(pa, ok(pa, {watch, aw, [out]}, T3)),
    {out, _, T5} = report(pa, aw, ev({master, {tty_taken, 0}}, T4)),
    T6 = ev({master, {tty_taken, 1}}, ev({write, {pw, written}, binary:copy(<<"x">>, 411)}, T5)),
    {out, _, _} = report(pa, aw, ok(pa, {watch, aw, [out]}, T6)).

%% A drain's answer follows the name's release: the caller answered drained
%% must find erx_tty_owner given up (the relay carries actions in order).
a_drain_gives_the_name_up_before_it_is_answered_test() ->
    Core0 = ?CORE:new(console, #{master => none}),
    {_, Actions} = ?CORE:event({drain, {ph, drained}}, Core0),
    [give_up_name | Rest] = [A || A <- Actions, A =:= give_up_name orelse element(1, A) =:= send],
    ?assert(lists:member({send, ph, drained}, Rest)).

%% With no master, nothing is sent and a drain is answered at once, with
%% bytes held and a writer's message waiting; a message as from a master is
%% dropped.
no_master_test() ->
    T0 = #t{core = ?CORE:new(console, #{master => none})},
    T1 = ok(pa, {open, console, write, cw}, T0),
    {{ok, 4096}, T2} = do(pa, {write, cw, binary:copy(<<"x">>, 4096)}, T1),
    T3 = ev({write, {ph, written}, <<"y">>}, T2),
    T4 = ev({drain, {ph, drained}}, T3),
    {[drained], T5} = take(ph, T4),
    {[], T6} = take(master, T5),
    T7 = ok(console, {open, console, read, c}, T6),
    T8 = ok(console, {watch, c, [in]}, T7),
    T9 = ev({master, {tty_size, 10, 20}}, type(<<"rm\n">>, T8)),
    {[], _} = take(console, T9).

%%% The exploration

%% Two shells, s1 with job a under g1 and s2 with job b under g2, each job
%% with an open for reading and a write-only one, and the console. Every
%% sequence of events of each alphabet up to its depth is run from a fresh
%% relay; after each step a model, which tracks the holder, the signal
%% number and each group's numbers from the events alone, checks the
%% answer, the reports sent and the core's state.

-record(m, {n = 0, holder = console, cg = none, alive = [g1, g2], met = [],
            sent = #{g1 => 0, g2 => 0}, recorded = #{g1 => 0, g2 => 0},
            shell = #{g1 => 0, g2 => 0}, last = #{}}).

shell_of(g1) -> s1;
shell_of(g2) -> s2.

job_of(g1) -> a;
job_of(g2) -> b.

open_holder(c) -> console;
open_holder(ar) -> a;
open_holder(aw) -> a;
open_holder(br) -> b;
open_holder(bw) -> b.

maker(c) -> console;
maker(Open) when Open =:= ar; Open =:= aw -> pa;
maker(_) -> pb.

full_alphabet() ->
    [{type, ?CTRL_C}, {type, ?CTRL_Z}, {type, <<"x\n">>}]
        ++ [{E, G} || G <- [g1, g2],
                      E <- [fg_console, fg_cooked, fg_current, fg_over, catch_up, down, cg]]
        ++ [{watch, O} || O <- [c, ar, br, aw]] ++ [{watch_in, aw}]
        ++ [{read, O} || O <- [c, ar, br, aw]] ++ [{guess, O} || O <- [ar, br]].

signal_alphabet() ->
    [{type, ?CTRL_C}, {type, <<"x\n">>}, {fg_cooked, g1}, {fg_console, g1},
     {fg_current, g1}, {catch_up, g1}, {watch, ar}, {read, ar}, {guess, ar}, {down, g1}].

shells_alphabet() ->
    [{type, ?CTRL_C}, {fg_cooked, g1}, {fg_cooked, g2}, {fg_console, g2}, {catch_up, g1},
     {catch_up, g2}, {watch, br}, {read, br}, {cg, g2}, {down, g2}].

exploration_full_test_() ->
    {timeout, 300, fun() -> ?assert(explore(full_alphabet(), 4) > 100000) end}.

exploration_signals_test_() ->
    {timeout, 300, fun() -> ?assert(explore(signal_alphabet(), 6) > 100000) end}.

exploration_shells_test_() ->
    {timeout, 300, fun() -> ?assert(explore(shells_alphabet(), 6) > 100000) end}.

%% The number of steps run, so a case can check that nothing was pruned.
explore(Alphabet, Depth) ->
    explore(Alphabet, Depth, {opened(), #m{}}, []).

explore(_Alphabet, 0, _State, _Trace) ->
    0;
explore(Alphabet, Depth, {_T, M} = State, Trace) ->
    lists:sum([begin
                   Trace1 = [Event | Trace],
                   Next = try step(Event, State)
                          catch error:Reason:Stack ->
                                  erlang:raise(error, {lists:reverse(Trace1), Reason}, Stack)
                          end,
                   1 + explore(Alphabet, Depth - 1, Next, Trace1)
               end || Event <- Alphabet, live(Event, M)]).

%% A dead group's shell does nothing more.
live({_, G}, #m{alive = Alive}) when G =:= g1; G =:= g2 -> lists:member(G, Alive);
live(_Event, _M) -> true.

step({type, Bytes}, {T, M}) ->
    M1 = typed(Bytes, M),
    checked(type(Bytes, T), M1);
step({fg_over, G}, {T, M}) ->
    foreground(G, {job_of(G), cooked}, maps:get(G, M#m.shell) + 1, T, M);
step({fg_console, G}, {T, M}) ->
    foreground(G, console, maps:get(G, M#m.shell), T, M);
step({fg_cooked, G}, {T, M}) ->
    foreground(G, {job_of(G), cooked}, maps:get(G, M#m.shell), T, M);
step({fg_current, G}, {T, M}) ->
    foreground(G, {job_of(G), current}, maps:get(G, M#m.shell), T, M);
step({catch_up, G}, {T, #m{shell = Shell, sent = Sent} = M}) ->
    checked(T, M#m{shell = Shell#{G := maps:get(G, Sent)}});
step({down, G}, {T, #m{holder = Holder} = M}) ->
    M1 = M#m{alive = lists:delete(G, M#m.alive), met = lists:delete(G, M#m.met),
             sent = (M#m.sent)#{G := 0}, recorded = (M#m.recorded)#{G := 0},
             holder = case Holder of {_, G} -> console; _ -> Holder end},
    checked(ev({down, G}, T), M1);
step({cg, G}, {T, M}) ->
    checked(ok(console, {console_group, G}, T), met(G, M#m{cg = G}));
step({watch, O}, {T, M}) ->
    Count = case O of c -> 1; _ -> 4 end,
    {Answer, T1} = do(maker(O), {watch, O, [{read, Count}]}, T),
    ?assertEqual(case O of aw -> {error, ebadf}; _ -> ok end, Answer),
    checked(T1, M);
step({watch_in, O}, {T, M}) ->
    checked(ok(maker(O), {watch, O, [in]}, T), M);
step({read, O}, {T, #m{last = Last} = M}) ->
    read(O, maps:get(O, Last, 0), T, M);
step({guess, O}, {T, #m{n = N} = M}) ->
    read(O, N, T, M).

%% The model's signal number and counts: a signal key counts for the
%% holding job's group, or for the console's named group, met and alive,
%% when the key is not Ctrl-\.
typed(<<Key>>, #m{n = N, holder = Holder, cg = Cg, met = Met, sent = Sent} = M)
  when Key =:= 3; Key =:= 26; Key =:= 28 ->
    Group = case Holder of
                {_, G} -> G;
                console when Key =/= 28 -> Cg;
                console -> none
            end,
    Counted = case lists:member(Group, Met) of
                  true -> Sent#{Group := maps:get(Group, Sent) + 1};
                  false -> Sent
              end,
    M#m{n = N + 1, sent = Counted};
typed(_Bytes, M) ->
    M.

met(G, #m{met = Met} = M) -> M#m{met = lists:usort([G | Met])}.

foreground(G, Target, Seen, T, #m{sent = Sent, holder = Holder} = M) ->
    Request = case Target of
                  console -> {foreground, console, {G, Seen}};
                  {Tag, Mode} -> {foreground, Tag, Mode, {G, Seen}}
              end,
    {Answer, T1} = do(shell_of(G), Request, T),
    Allowed = Seen =< maps:get(G, Sent) andalso
        case Target of
            {Current, current} -> Holder =:= {Current, G};
            _ -> true
        end,
    case Allowed of
        true ->
            ?assertMatch({ok, _, _}, Answer),
            {ok, _, Answered} = Answer,
            ?assertEqual(maps:get(G, Sent), Answered),
            New = case Target of
                      console -> console;
                      {Job, _} -> {Job, G}
                  end,
            checked(T1, (met(G, M))#m{holder = New, recorded = (M#m.recorded)#{G := Seen}});
        false ->
            ?assertEqual({error, einval}, Answer),
            checked(T1, M)
    end.

read(O, N, T, M) ->
    {Answer, T1} = do(maker(O), {tty_read, O, 4, N}, T),
    case O of
        aw -> ?assertEqual({error, ebadf}, Answer);
        _ -> ok
    end,
    case Answer of
        eagain -> ok;
        {error, ebadf} -> ok;
        _ ->
            %% A read that is answered is fresh and from an open that may read.
            ?assertEqual(M#m.n, N),
            ?assert(may_read(O, M))
    end,
    checked(T1, M).

may_read(aw, _M) -> false;
may_read(bw, _M) -> false;
may_read(O, #m{holder = Holder, sent = Sent, recorded = Recorded}) ->
    case {open_holder(O), Holder} of
        {console, console} -> true;
        {Job, {Job, G}} -> maps:get(G, Sent) =:= maps:get(G, Recorded);
        _ -> false
    end.

%% After every step: every report is fresh and goes to an open that may
%% read; the holder and each group's numbers are the model's, and Seen
%% never exceeds Sent.
checked(T, #m{n = N, holder = Holder, alive = Alive, met = Met} = M) ->
    {Reports, T1} = lists:foldl(fun(P, {Acc, Tn}) ->
                                        {Ms, Tn1} = take(P, Tn),
                                        {Acc ++ [R || {ready, _, _, _} = R <- Ms], Tn1}
                                end, {[], T}, [console, pa, pb, s1, s2]),
    Last = lists:foldl(fun({ready, O, [Kind], Rn}, Acc) ->
                               ?assertEqual(N, Rn),
                               case Kind of
                                   out -> ok;
                                   _ -> ?assert(may_read(O, M) orelse
                                                    (O =:= aw andalso Kind =:= in andalso
                                                     may_read(ar, M)))
                               end,
                               Acc#{O => Rn}
                       end, M#m.last, Reports),
    Core = T1#t.core,
    Expected = case Holder of
                   console -> console;
                   {Job, _} -> {job, Job}
               end,
    ?assertEqual(Expected, ?CORE:holder(Core)),
    ?assertEqual(N, ?CORE:signal_number(Core)),
    lists:foreach(fun(G) ->
                          case lists:member(G, Met) andalso lists:member(G, Alive) of
                              true ->
                                  {Sent, Seen} = ?CORE:numbers(G, Core),
                                  ?assert(Seen =< Sent),
                                  ?assertEqual({maps:get(G, M#m.sent), maps:get(G, M#m.recorded)},
                                               {Sent, Seen});
                              false ->
                                  ?assertEqual(none, ?CORE:numbers(G, Core))
                          end
                  end, [g1, g2]),
    {T1, M#m{last = Last}}.
