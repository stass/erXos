%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tty_master_tests).
-moduledoc """
The master's side of a session's tty, erx_tty_master: its receiver checks as a
property over arbitrary terms, and the master against the tty's own core,
erx_tty_link, over random runs in which the line connects and disconnects,
writes are slow, and messages in both directions are lost: the master reports as
lost exactly the outputs whose first send was lost.
""".

-include_lib("eunit/include/eunit.hrl").

-define(RUNS, 400).
-define(STEPS, 60).

%%% The receiver checks

%% A master in each of its states: fresh, holding output 0 while disconnected,
%% writing output 0 while connected, and having taken output 0.
states() ->
    Fresh = erx_tty_master:new(),
    {[], Held} = erx_tty_master:output({tty_output, 0, <<"a">>}, Fresh),
    {_, Connected} = erx_tty_master:connect({24, 80}, Fresh),
    {[{write, 0, <<"a">>}], Writing} = erx_tty_master:output({tty_output, 0, <<"a">>}, Connected),
    {[{send, {tty_taken, 0}}], Taken} = erx_tty_master:written(0, Writing),
    [Fresh, Held, Writing, Taken].

%% Whether Message passes the checks in master M: an output of at most 4 KiB, whose
%% number is the next one, or a repeat, empty, of the one held, being written or
%% last taken.
passes(Message, M) ->
    {Actions, _} = erx_tty_master:output(Message, M),
    not lists:member(detach, Actions).

the_checks_test_() ->
    [Fresh, Held, Writing, Taken] = states(),
    Max = binary:copy(<<$x>>, 4096),
    [?_assert(passes({tty_output, 0, Max}, Fresh)),
     ?_assert(passes({tty_output, 0, <<>>}, Fresh)),
     ?_assertNot(passes({tty_output, 0, <<Max/binary, $x>>}, Fresh)),
     ?_assertNot(passes({tty_output, 1, <<"a">>}, Fresh)),
     ?_assertNot(passes({tty_output, -1, <<>>}, Fresh)),
     ?_assertNot(passes({tty_output, 0, "a"}, Fresh)),
     ?_assertNot(passes({tty_output, 0, [<<"a">>]}, Fresh)),
     ?_assertNot(passes({tty_output, 0.0, <<"a">>}, Fresh)),
     ?_assertNot(passes(tty_output, Fresh)),
     ?_assertNot(passes(tty_hangup, Fresh)),
     ?_assertNot(passes({tty_taken, 0}, Fresh)),
     ?_assertNot(passes({tty_output, 0, <<"a">>, extra}, Fresh)),
     ?_assert(passes({tty_output, 0, <<>>}, Held)),
     ?_assertNot(passes({tty_output, 0, <<"b">>}, Held)),
     ?_assertNot(passes({tty_output, 1, <<"b">>}, Held)),
     ?_assert(passes({tty_output, 0, <<>>}, Writing)),
     ?_assertNot(passes({tty_output, 1, <<"b">>}, Writing)),
     ?_assert(passes({tty_output, 1, <<"b">>}, Taken)),
     ?_assert(passes({tty_output, 0, <<>>}, Taken)),
     ?_assertNot(passes({tty_output, 0, <<"a">>}, Taken)),
     ?_assertNot(passes({tty_output, 2, <<"b">>}, Taken))].

%% A repeat of the output last taken is answered again, with the size.
a_repeat_is_answered_again_test() ->
    [_, _, _, Taken] = states(),
    ?assertMatch({[{send, {tty_taken, 0}}, {send, {tty_size, 24, 80}}], _},
                 erx_tty_master:output({tty_output, 0, <<>>}, Taken)).

%% A resend whose first send was lost arrives as the next output with no bytes: the
%% master takes it, whether it writes it or holds it, and reports the loss for the log.
a_lost_output_is_reported_test() ->
    Fresh = erx_tty_master:new(),
    {_, Connected} = erx_tty_master:connect({24, 80}, Fresh),
    ?assertMatch({[{lost, 0}, {write, 0, <<>>}], _}, erx_tty_master:output({tty_output, 0, <<>>}, Connected)),
    ?assertMatch({[{lost, 0}], _}, erx_tty_master:output({tty_output, 0, <<>>}, Fresh)),
    ?assertMatch({[{write, 0, <<"a">>}], _}, erx_tty_master:output({tty_output, 0, <<"a">>}, Connected)).

%% A tty refused once is detached for good: nothing it sends is taken, written or
%% answered, and it cannot be connected again.
a_refused_tty_stays_detached_test() ->
    {[detach], Refused} = erx_tty_master:output(nonsense, erx_tty_master:new()),
    ?assert(erx_tty_master:is_refused(Refused)),
    ?assertMatch({[], _}, erx_tty_master:output({tty_output, 0, <<"a">>}, Refused)),
    ?assertMatch({[], _}, erx_tty_master:connect({24, 80}, Refused)),
    ?assertMatch({[], _}, erx_tty_master:input(<<"x">>, Refused)).

%% Arbitrary terms: whatever arrives, the master takes it as the checks say or
%% detaches, and never writes more than 4 KiB at once. Each state's valid outputs are
%% stated here independently of the module: by number, with any bytes or empty only.
arbitrary_terms_test() ->
    rand:seed(exsss, {11, 12, 13}),
    Valid = [[{0, any}], [{0, empty}], [{0, empty}], [{1, any}, {0, empty}]],
    lists:foreach(
      fun({M, Outputs}) ->
              [begin
                   Term = term(3),
                   {Actions, _} = erx_tty_master:output(Term, M),
                   [?assert(byte_size(B) =< 4096) || {write, _, B} <- Actions],
                   ?assertEqual(not valid(Term, Outputs), lists:member(detach, Actions))
               end || _ <- lists:seq(1, 2000)]
      end, lists:zip(states(), Valid)).

valid({tty_output, N, B}, Outputs) when is_integer(N), is_binary(B), byte_size(B) =< 4096 ->
    lists:any(fun({V, any}) -> V =:= N; ({V, empty}) -> V =:= N andalso B =:= <<>> end, Outputs);
valid(_Term, _Outputs) ->
    false.

%% A random term of depth at most Depth, biased toward the five messages' shapes.
term(0) ->
    leaf();
term(Depth) ->
    case rand:uniform(6) of
        1 -> {tty_output, number(), payload()};
        2 -> list_to_tuple([term(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)]);
        3 -> [term(Depth - 1) || _ <- lists:seq(1, rand:uniform(3) - 1)];
        4 -> {tty_output, term(Depth - 1), term(Depth - 1)};
        _ -> leaf()
    end.

leaf() ->
    case rand:uniform(8) of
        1 -> lists:nth(rand:uniform(6), [tty_output, tty_taken, tty_input, tty_size, tty_hangup, other]);
        2 -> number();
        3 -> payload();
        4 -> self();
        5 -> make_ref();
        6 -> 1.5;
        7 -> "text";
        8 -> #{a => 1}
    end.

number() -> rand:uniform(4) - 2.

payload() ->
    case rand:uniform(4) of
        1 -> <<>>;
        2 -> <<"ab">>;
        3 -> binary:copy(<<$z>>, 4096);
        4 -> binary:copy(<<$z>>, 4097)
    end.

%%% The master against the tty's core

%% Random runs of the two cores joined by two queues that may lose any message, the
%% line connecting and disconnecting and the line's writes finishing late. The master
%% never detaches a tty that follows the protocol, and once the line is connected with
%% nothing lost the line has every output the tty sent, in order, less each first send
%% that was lost, whose resend carries no bytes.
against_the_tty_test_() ->
    {timeout, 60, fun() ->
                          rand:seed(exsss, {1, 2, 3}),
                          lists:foreach(fun(_) -> run() end, lists:seq(1, ?RUNS))
                  end}.

run() ->
    Start = #{tty => erx_tty_link:new(), master => erx_tty_master:new(),
              to_master => [], to_tty => [], writing => [], timers => [],
              line => <<>>, wrote => <<>>, sent => [], lost => [], reported => []},
    End = drain(lists:foldl(fun(_, S) -> step(event(), S) end, Start, lists:seq(1, ?STEPS))),
    #{line := Line, wrote := Wrote, sent := Sent, lost := Lost, reported := Reported} = End,
    ?assertEqual(lists:sort(Lost), lists:sort(Reported)),
    ?assertEqual(Wrote, iolist_to_binary([Bytes || {_N, Bytes} <- Sent])),
    ?assertEqual(iolist_to_binary([Bytes || {N, Bytes} <- Sent, not lists:member(N, Lost)]), Line).

event() ->
    case rand:uniform(9) of
        1 -> {write, binary:copy(<<(rand:uniform(26) + $a - 1)>>, rand:uniform(3000))};
        2 -> deliver_to_master;
        3 -> deliver_to_tty;
        4 -> lose;
        5 -> written;
        6 -> timer;
        7 -> connect;
        8 -> disconnect;
        9 -> deliver_to_master
    end.

%% After the run: connected, nothing lost, until nothing moves.
drain(S0) ->
    S1 = step(connect, S0),
    drain(S1, 0).

drain(S, 200) ->
    S;
drain(S, Count) ->
    Next = lists:foldl(fun step/2, S, [deliver_to_master, written, deliver_to_tty, timer]),
    drain(Next, Count + 1).

step({write, Bytes}, S = #{tty := Tty, wrote := Wrote}) ->
    %% A writer that waits, so no write is dropped.
    tty(erx_tty_link:write(writer, Bytes, Tty), S#{wrote := <<Wrote/binary, Bytes/binary>>});
step(deliver_to_master, S = #{to_master := [Message | Rest], master := M}) ->
    master(erx_tty_master:output(Message, M), S#{to_master := Rest});
step(deliver_to_tty, S = #{to_tty := [Message | Rest], tty := Tty}) ->
    tty(erx_tty_link:master(Message, Tty), S#{to_tty := Rest});
step(lose, S = #{to_master := ToMaster, to_tty := ToTty}) ->
    case rand:uniform(2) of
        1 when ToMaster =/= [] -> lost(hd(ToMaster), S#{to_master := tl(ToMaster)});
        _ when ToTty =/= [] -> S#{to_tty := tl(ToTty)};
        _ -> S
    end;
step(written, S = #{writing := [{N, Bytes} | Rest], master := M, line := Line}) ->
    master(erx_tty_master:written(N, M), S#{writing := Rest, line := <<Line/binary, Bytes/binary>>});
step(timer, S = #{timers := [N | Rest], tty := Tty}) ->
    tty(erx_tty_link:timeout(N, Tty), S#{timers := Rest});
step(connect, S = #{master := M}) ->
    master(erx_tty_master:connect({24, 80}, M), S);
step(disconnect, S = #{master := M}) ->
    S#{master := erx_tty_master:disconnect(M)};
step(_Nothing, S) ->
    S.

%% A lost first send of output N takes its bytes off the line.
lost({tty_output, N, Bytes}, S = #{lost := Lost}) when Bytes =/= <<>> ->
    S#{lost := [N | Lost]};
lost(_Message, S) ->
    S.

tty({Actions, Tty}, S) ->
    lists:foldl(fun({output, N, Bytes}, Acc = #{to_master := Q, sent := Sent}) ->
                        Acc#{to_master := Q ++ [{tty_output, N, Bytes}],
                             sent := Sent ++ [{N, Bytes} || Bytes =/= <<>>]};
                   ({resend_after, N}, Acc = #{timers := T}) ->
                        Acc#{timers := T ++ [N]};
                   (_Other, Acc) ->
                        Acc
                end, S#{tty := Tty}, Actions).

master({Actions, M}, S) ->
    ?assertNot(lists:member(detach, Actions)),
    lists:foldl(fun({write, N, Bytes}, Acc = #{writing := W}) -> Acc#{writing := W ++ [{N, Bytes}]};
                   ({send, Message}, Acc = #{to_tty := Q}) -> Acc#{to_tty := Q ++ [Message]};
                   ({lost, N}, Acc = #{reported := R}) -> Acc#{reported := [N | R]}
                end, S#{master := M}, Actions).
