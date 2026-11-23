%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tty_link_tests).
-moduledoc """
erx_tty_link, the tty's side of the six messages, walked exhaustively: every
sequence of up to ?DEPTH events, each a write (small or past the hold), the
delivery or the loss of the master's oldest message in flight, the oldest
timer firing, a size, the hangup, or the line discipline's flush, stop or
start; each step ends in send/1, as its owner ends one. No new output is
sent while output is stopped, and room/1 is what is held, the outstanding
output and output stopped. A flush drops what was not yet sent, so the
master's bytes are then all that is written. The master here takes every output and
checks it as the console does (the next number, or the last one again and
empty), answering through a channel that may lose any message. After every
step at most 4 KiB is held and the master has a prefix of what was written,
each byte once; after the sequence, delivering everything and firing the
timers leaves every writer done and, unless the line hung up, every byte at
the master.
""".

-include_lib("eunit/include/eunit.hrl").

-define(DEPTH, 5).
-define(EVENTS, [write_small, write_big, deliver, drop, timer, size, hangup,
                 flush, stop, start]).
-define(BIG, 3000).
-define(DRAIN_STEPS, 200).

-record(world, {link, written = <<>>, writers = [], next_writer = 0,
                %% The master: what it took, the next number it expects, whether it hung up.
                got = <<>>, expected = 0, master_hung_up = false,
                %% The master's messages in flight to the tty, oldest first, and the
                %% timers the tty asked for, oldest first.
                channel = [], timers = [],
                %% Whether the line discipline stopped output, and the size of the
                %% output the tty has outstanding, as {N, Size}, or none.
                stopped = false, outstanding = none}).


every_sequence_test_() ->
    {timeout, 300, fun() -> walk(?DEPTH, #world{link = erx_tty_link:new(present)}, []) end}.

walk(0, _World, _Trace) ->
    ok;
walk(Depth, World, Trace) ->
    lists:foreach(fun(Event) ->
                          Path = [Event | Trace],
                          Next = sent(step(Event, World, Path), Path),
                          check_step(Next, Path),
                          check_drained(drain(Next, ?DRAIN_STEPS, Path), Path),
                          walk(Depth - 1, Next, Path)
                  end, ?EVENTS).

%%% Events

step(write_small, W, Path) -> write(1, W, Path);
step(write_big, W, Path) -> write(?BIG, W, Path);
step(deliver, W = #world{channel = []}, _Path) -> W;
step(deliver, W = #world{channel = [Message | Rest]}, Path) ->
    apply_actions(erx_tty_link:master(Message, W#world.link),
                  W#world{channel = Rest, outstanding = answered(Message, W#world.outstanding)}, Path);
step(drop, W = #world{channel = []}, _Path) -> W;
step(drop, W = #world{channel = [_Lost | Rest]}, _Path) -> W#world{channel = Rest};
step(timer, W = #world{timers = []}, _Path) -> W;
step(timer, W = #world{timers = [N | Rest]}, Path) ->
    apply_actions(erx_tty_link:timeout(N, W#world.link), W#world{timers = Rest}, Path);
step(size, W = #world{channel = Channel}, _Path) ->
    W#world{channel = Channel ++ [{tty_size, 24, 80}]};
step(hangup, W = #world{channel = Channel}, _Path) ->
    W#world{master_hung_up = true, channel = Channel ++ [tty_hangup]};
step(flush, W, Path) ->
    Flushed = apply_actions(erx_tty_link:flush(W#world.link), W, Path),
    Flushed#world{written = Flushed#world.got};
step(stop, W, _Path) ->
    W#world{link = erx_tty_link:stop(W#world.link), stopped = true};
step(start, W, _Path) ->
    W#world{link = erx_tty_link:start(W#world.link), stopped = false}.

%% The end of a step, as the owner ends it: what is held goes out.
sent(W = #world{stopped = Stopped}, Path) ->
    {Actions, Link} = erx_tty_link:send(W#world.link),
    ?assert(not Stopped orelse Actions =:= [], {sent_while_stopped, lists:reverse(Path)}),
    apply_actions({Actions, Link}, W, Path).

%% A write of Size bytes, each numbering its place in all that was written.
write(Size, W = #world{written = Written, writers = Writers, next_writer = Id}, Path) ->
    Bytes = << <<((byte_size(Written) + I) band 255)>> || I <- lists:seq(0, Size - 1) >>,
    apply_actions(erx_tty_link:write(Id, Bytes, W#world.link),
                  W#world{written = <<Written/binary, Bytes/binary>>,
                          writers = [Id | Writers], next_writer = Id + 1}, Path).

apply_actions({Actions, Link}, W, Path) ->
    ok = open_only_with_resend(Actions, Path),
    lists:foldl(fun(Action, Acc) -> act(Action, Acc, Path) end, W#world{link = Link}, Actions).

act({output, N, <<>>}, W, Path) -> master_takes(N, <<>>, W, Path);
act({output, N, Bytes}, W, Path) ->
    master_takes(N, Bytes, W#world{outstanding = {N, byte_size(Bytes)}}, Path);
act({resend_after, N}, W = #world{timers = Timers}, _Path) -> W#world{timers = Timers ++ [N]};
act({done, Id}, W = #world{writers = Writers}, Path) ->
    ?assert(lists:member(Id, Writers), {done_twice, Id, lists:reverse(Path)}),
    W#world{writers = lists:delete(Id, Writers)};
act({size, 24, 80}, W, _Path) -> W;
act(hangup, W, _Path) -> W;
act(open, W, _Path) -> W;
act(Action, _W, Path) -> erlang:error({unexpected_action, Action, lists:reverse(Path)}).

%% The master's checks, as the console's: the next output, or the last one again
%% with nothing in it; a master that hung up says so to every output.
master_takes(_N, _Bytes, W = #world{master_hung_up = true, channel = Channel}, _Path) ->
    W#world{channel = Channel ++ [tty_hangup]};
master_takes(N, Bytes, W = #world{expected = N, got = Got, channel = Channel}, Path) ->
    ?assertNotEqual(<<>>, Bytes, {empty_new_output, N, lists:reverse(Path)}),
    W#world{got = <<Got/binary, Bytes/binary>>, expected = N + 1,
            channel = Channel ++ [{tty_taken, N}]};
master_takes(N, <<>>, W = #world{expected = Expected, channel = Channel}, _Path)
  when N =:= Expected - 1 ->
    W#world{channel = Channel ++ [{tty_taken, N}]};
master_takes(N, Bytes, #world{expected = Expected}, Path) ->
    erlang:error({master_detaches, {output, N, byte_size(Bytes)}, {expected, Expected},
                  lists:reverse(Path)}).

%%% Checks

%% The tty names itself again only together with the empty resend of its outstanding
%% output, never at the timer of an output already taken.
open_only_with_resend([open, {output, _N, <<>>} | Rest], Path) -> open_only_with_resend(Rest, Path);
open_only_with_resend([open | _], Path) -> erlang:error({open_without_resend, lists:reverse(Path)});
open_only_with_resend([_ | Rest], Path) -> open_only_with_resend(Rest, Path);
open_only_with_resend([], _Path) -> ok.

check_step(W = #world{link = Link, got = Got, written = Written}, Path) ->
    ?assert(erx_tty_link:held(Link) =< 4096, {held, erx_tty_link:held(Link), lists:reverse(Path)}),
    ?assertEqual({4096 - erx_tty_link:held(Link), outstanding(W), W#world.stopped},
                 erx_tty_link:room(Link), {room, lists:reverse(Path)}),
    ?assertEqual(W#world.stopped, erx_tty_link:stopped(Link), {stopped, lists:reverse(Path)}),
    ?assert(binary:longest_common_prefix([Got, Written]) =:= byte_size(Got),
            {not_a_prefix, lists:reverse(Path)}),
    W.

%% The size of the output the tty has outstanding: the last new one, until
%% the tty takes its tty_taken or the hangup.
outstanding(#world{outstanding = none}) -> 0;
outstanding(#world{outstanding = {_N, Size}}) -> Size.

answered({tty_taken, N}, {N, _Size}) -> none;
answered(tty_hangup, _Outstanding) -> none;
answered(_Message, Outstanding) -> Outstanding.

%% Starts output if it is stopped, then delivers every message and fires every
%% timer, without loss, each step ending in send/1, until nothing is left to
%% happen; a tty that keeps something going past ?DRAIN_STEPS stalls.
drain(W = #world{stopped = true}, Steps, Path) ->
    drain(sent(step(start, W, Path), Path), Steps, Path);
drain(W = #world{channel = [], timers = []}, _Steps, _Path) ->
    W;
drain(_W, 0, Path) ->
    erlang:error({no_quiescence, lists:reverse(Path)});
drain(W = #world{channel = [_ | _]}, Steps, Path) ->
    drain(check_step(sent(step(deliver, W, Path), Path), Path), Steps - 1, Path);
drain(W, Steps, Path) ->
    drain(check_step(sent(step(timer, W, Path), Path), Path), Steps - 1, Path).

check_drained(#world{writers = Writers, got = Got, written = Written, master_hung_up = HungUp}, Path) ->
    ?assertEqual([], Writers, {writers_left, lists:reverse(Path)}),
    case HungUp of
        false -> ?assertEqual(byte_size(Written), byte_size(Got), {bytes_left, lists:reverse(Path)});
        true -> ok
    end.

%%% Single cases the walk does not reach

%% The timer of an outstanding output names the tty again and sends the output again,
%% empty (docs/design-live.md, "A lost answer does not stop a tty"); the timer of an
%% output already taken does nothing, so a burst of output is never followed a second
%% later by a burst of messages to the master.
resend_timer_test() ->
    {_, L0} = erx_tty_link:write(w, <<"a">>, erx_tty_link:new(present)),
    {[{output, 0, <<"a">>}, {resend_after, 0}], L1} = erx_tty_link:send(L0),
    ?assertMatch({[open, {output, 0, <<>>}, {resend_after, 0}], _}, erx_tty_link:timeout(0, L1)),
    {[], L2} = erx_tty_link:master({tty_taken, 0}, L1),
    ?assertMatch({[], _}, erx_tty_link:timeout(0, L2)).

input_and_size_checks_test() ->
    L = erx_tty_link:new(present),
    ?assertMatch({[{input, <<"ab">>}], _}, erx_tty_link:master({tty_input, 0, <<"ab">>}, L)),
    {[], L1} = erx_tty_link:master({tty_input, 0, binary:copy(<<"x">>, 4097)}, L),
    {[], L2} = erx_tty_link:master({tty_input, 0, "ab"}, L1),
    {[], L3} = erx_tty_link:master({tty_size, 24, 0}, L2),
    {[], L4} = erx_tty_link:master({tty_size, 65536, 80}, L3),
    ?assertEqual(#{output_dropped => 0, input_dropped => 2, input_refused => 0, size_refused => 2},
                 erx_tty_link:counts(L4)),
    {[{size, 24, 80}], L5} = erx_tty_link:master({tty_size, 24, 80}, L4),
    ?assertMatch({[], _}, erx_tty_link:master({tty_size, 24, 80}, L5)),
    ?assertMatch({[], _}, erx_tty_link:master({tty_output, 0, <<>>}, L5)).

%% The master's input is one numbered sequence (docs/design-live.md, "One
%% input sequence across domains"): a gap is a loss at its place, a number
%% not past the last taken is refused, a bad shape dropped, and after a
%% hangup a loss is ignored.
input_numbers_test() ->
    Steps = [{tty_input, 0, <<"a">>}, {tty_input, 1, <<"b">>}, {tty_input, 3, <<"d">>},
             {tty_input, 2, <<"c">>}, {tty_lost, x}, {tty_lost, 4}, {tty_lost, 6},
             {tty_input, 7, <<>>}, {tty_input, 9, <<>>}],
    {Actions, L} = lists:foldl(fun(Message, {Acc, L0}) ->
                                       {More, L1} = erx_tty_link:master(Message, L0),
                                       {Acc ++ [More], L1}
                               end, {[], erx_tty_link:new(present)}, Steps),
    ?assertEqual([[{input, <<"a">>}], [{input, <<"b">>}], [lost, {input, <<"d">>}],
                  [], [], [lost], [lost], [], [lost]], Actions),
    ?assertMatch(#{input_refused := 1, input_dropped := 1}, erx_tty_link:counts(L)),
    {[hangup], Hung} = erx_tty_link:master(tty_hangup, L),
    ?assertMatch({[], _}, erx_tty_link:master({tty_lost, 10}, Hung)),
    ?assertMatch({[], _}, erx_tty_link:master({tty_input, 10, <<"e">>}, Hung)).

writes_nobody_waits_on_are_bounded_test() ->
    %% Nothing is taken: the first 4 KiB is held, 64 KiB more may wait, and the
    %% rest is dropped and counted.
    Chunk = binary:copy(<<"y">>, 1024),
    Final = lists:foldl(fun(_, L) -> element(2, erx_tty_link:write(none, Chunk, L)) end,
                        erx_tty_link:new(present), lists:seq(1, 4 + 64 + 3)),
    ?assertEqual(4096, erx_tty_link:held(Final)),
    ?assertEqual(64, erx_tty_link:waiting(Final)),
    ?assertMatch(#{output_dropped := 3}, erx_tty_link:counts(Final)).

%% A tty with no master sends nothing, so it holds 4 KiB and its writer
%% waits, asks for no timer, and drops every message as from a master.
no_master_test() ->
    {[], L1} = erx_tty_link:write(a, binary:copy(<<"z">>, 5000), erx_tty_link:new(none)),
    {[], L2} = erx_tty_link:send(L1),
    ?assertEqual({4096, 1, false}, {erx_tty_link:held(L2), erx_tty_link:waiting(L2),
                                    erx_tty_link:flowing(L2)}),
    ?assertMatch({[], _}, erx_tty_link:timeout(0, L2)),
    ?assertMatch({[], _}, erx_tty_link:master({tty_input, 0, <<"ab">>}, L2)),
    ?assertMatch({[], _}, erx_tty_link:master({tty_lost, 0}, L2)),
    ?assertMatch({[], _}, erx_tty_link:master(tty_hangup, L2)).

a_hangup_ends_every_wait_test() ->
    {_, L1} = erx_tty_link:write(a, binary:copy(<<"z">>, 5000), erx_tty_link:new(present)),
    {_, L2} = erx_tty_link:write(b, <<"later">>, L1),
    ?assertEqual({[hangup, {done, a}, {done, b}], 0},
                 begin {Actions, L3} = erx_tty_link:master(tty_hangup, L2),
                       {Actions, erx_tty_link:held(L3)} end).
