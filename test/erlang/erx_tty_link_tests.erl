%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tty_link_tests).
-moduledoc """
erx_tty_link, the tty's side of the five messages, walked exhaustively: every
sequence of up to ?DEPTH events, each a write (small or past the hold), the
delivery or the loss of the master's oldest message in flight, the oldest
timer firing, a size or the hangup. The master here takes every output and
checks it as the console does (the next number, or the last one again and
empty), answering through a channel that may lose any message. After every
step at most 4 KiB is held and the master has a prefix of what was written,
each byte once; after the sequence, delivering everything and firing the
timers leaves every writer done and, unless the line hung up, every byte at
the master.
""".

-include_lib("eunit/include/eunit.hrl").

-define(DEPTH, 6).
-define(EVENTS, [write_small, write_big, deliver, drop, timer, size, hangup]).
-define(BIG, 3000).
-define(DRAIN_STEPS, 200).

-record(world, {link, written = <<>>, writers = [], next_writer = 0,
                %% The master: what it took, the next number it expects, whether it hung up.
                got = <<>>, expected = 0, master_hung_up = false,
                %% The master's messages in flight to the tty, oldest first, and the
                %% timers the tty asked for, oldest first.
                channel = [], timers = []}).

every_sequence_test_() ->
    {timeout, 300, fun() -> walk(?DEPTH, #world{link = erx_tty_link:new()}, []) end}.

walk(0, _World, _Trace) ->
    ok;
walk(Depth, World, Trace) ->
    lists:foreach(fun(Event) ->
                          Path = [Event | Trace],
                          Next = step(Event, World, Path),
                          check_step(Next, Path),
                          check_drained(drain(Next, ?DRAIN_STEPS, Path), Path),
                          walk(Depth - 1, Next, Path)
                  end, ?EVENTS).

%%% Events

step(write_small, W, Path) -> write(1, W, Path);
step(write_big, W, Path) -> write(?BIG, W, Path);
step(deliver, W = #world{channel = []}, _Path) -> W;
step(deliver, W = #world{channel = [Message | Rest]}, Path) ->
    apply_actions(erx_tty_link:master(Message, W#world.link), W#world{channel = Rest}, Path);
step(drop, W = #world{channel = []}, _Path) -> W;
step(drop, W = #world{channel = [_Lost | Rest]}, _Path) -> W#world{channel = Rest};
step(timer, W = #world{timers = []}, _Path) -> W;
step(timer, W = #world{timers = [N | Rest]}, Path) ->
    apply_actions(erx_tty_link:timeout(N, W#world.link), W#world{timers = Rest}, Path);
step(size, W = #world{channel = Channel}, _Path) ->
    W#world{channel = Channel ++ [{tty_size, 24, 80}]};
step(hangup, W = #world{channel = Channel}, _Path) ->
    W#world{master_hung_up = true, channel = Channel ++ [tty_hangup]}.

%% A write of Size bytes, each numbering its place in all that was written.
write(Size, W = #world{written = Written, writers = Writers, next_writer = Id}, Path) ->
    Bytes = << <<((byte_size(Written) + I) band 255)>> || I <- lists:seq(0, Size - 1) >>,
    apply_actions(erx_tty_link:write(Id, Bytes, W#world.link),
                  W#world{written = <<Written/binary, Bytes/binary>>,
                          writers = [Id | Writers], next_writer = Id + 1}, Path).

apply_actions({Actions, Link}, W, Path) ->
    ok = open_only_with_resend(Actions, Path),
    lists:foldl(fun(Action, Acc) -> act(Action, Acc, Path) end, W#world{link = Link}, Actions).

act({output, N, Bytes}, W, Path) -> master_takes(N, Bytes, W, Path);
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
    ?assert(binary:longest_common_prefix([Got, Written]) =:= byte_size(Got),
            {not_a_prefix, lists:reverse(Path)}),
    W.

%% Delivers every message and fires every timer, without loss, until nothing is
%% left to happen; a tty that keeps something going past ?DRAIN_STEPS stalls.
drain(W = #world{channel = [], timers = []}, _Steps, _Path) ->
    W;
drain(_W, 0, Path) ->
    erlang:error({no_quiescence, lists:reverse(Path)});
drain(W = #world{channel = [_ | _]}, Steps, Path) ->
    drain(check_step(step(deliver, W, Path), Path), Steps - 1, Path);
drain(W, Steps, Path) ->
    drain(check_step(step(timer, W, Path), Path), Steps - 1, Path).

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
    {_, L1} = erx_tty_link:write(w, <<"a">>, erx_tty_link:new()),
    ?assertMatch({[open, {output, 0, <<>>}, {resend_after, 0}], _}, erx_tty_link:timeout(0, L1)),
    {[], L2} = erx_tty_link:master({tty_taken, 0}, L1),
    ?assertMatch({[], _}, erx_tty_link:timeout(0, L2)).

input_and_size_checks_test() ->
    L = erx_tty_link:new(),
    ?assertMatch({[{input, <<"ab">>}], _}, erx_tty_link:master({tty_input, <<"ab">>}, L)),
    {[], L1} = erx_tty_link:master({tty_input, binary:copy(<<"x">>, 4097)}, L),
    {[], L2} = erx_tty_link:master({tty_input, "ab"}, L1),
    {[], L3} = erx_tty_link:master({tty_size, 24, 0}, L2),
    {[], L4} = erx_tty_link:master({tty_size, 65536, 80}, L3),
    ?assertEqual(#{output_dropped => 0, input_dropped => 2, size_refused => 2},
                 erx_tty_link:counts(L4)),
    {[{size, 24, 80}], L5} = erx_tty_link:master({tty_size, 24, 80}, L4),
    ?assertMatch({[], _}, erx_tty_link:master({tty_size, 24, 80}, L5)),
    ?assertMatch({[], _}, erx_tty_link:master({tty_output, 0, <<>>}, L5)).

writes_nobody_waits_on_are_bounded_test() ->
    %% Nothing is taken: the first 4 KiB is held, 64 KiB more may wait, and the
    %% rest is dropped and counted.
    Chunk = binary:copy(<<"y">>, 1024),
    Final = lists:foldl(fun(_, L) -> element(2, erx_tty_link:write(none, Chunk, L)) end,
                        erx_tty_link:new(), lists:seq(1, 4 + 64 + 3)),
    ?assertEqual(4096, erx_tty_link:held(Final)),
    ?assertEqual(64, erx_tty_link:waiting(Final)),
    ?assertMatch(#{output_dropped := 3}, erx_tty_link:counts(Final)).

a_hangup_ends_every_wait_test() ->
    {_, L1} = erx_tty_link:write(a, binary:copy(<<"z">>, 5000), erx_tty_link:new()),
    {_, L2} = erx_tty_link:write(b, <<"later">>, L1),
    ?assertEqual({[hangup, {done, a}, {done, b}], 0},
                 begin {Actions, L3} = erx_tty_link:master(tty_hangup, L2),
                       {Actions, erx_tty_link:held(L3)} end).
