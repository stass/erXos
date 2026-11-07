%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_trace's pure parts (docs/design-live.md, "Tracing"): the check of
%% erx:trace/1's Spec with each refusal, the printed line with its escape, and the trace
%% process's decisions: which messages it takes, its window, its batch and its rings.
%% test/host/erx_trace_test.rb runs them on stock's emulator, and runs each seed there,
%% which must make the case it names fail.

-module(erx_trace_tests).
-include_lib("eunit/include/eunit.hrl").

%% A caller's view of pids: this test process is a live process of the system domain,
%% every other pid names nothing.
domain_of(Pid) when Pid =:= self() -> {ok, 4};
domain_of(_Pid) -> error.

check(Spec) -> check(Spec, all).
check(Spec, Scope) -> erx_trace:check(Spec, Scope, fun domain_of/1).

defaults_test() ->
    ?assertEqual({ok, #{select => [4], frames => false, kernel => false}}, check(#{select => [4]})),
    ?assertEqual({ok, #{select => [], frames => false, kernel => true}}, check(#{kernel => true})),
    Self = self(),
    ?assertEqual({ok, #{select => [Self], frames => true, kernel => true}},
                 check(#{select => [Self], frames => true, kernel => true})).

badarg_test() ->
    Sixteen = lists:duplicate(16, 4),
    ?assertMatch({ok, _}, check(#{select => Sixteen})),
    ?assertEqual({error, badarg}, check(#{select => [4 | Sixteen]})),
    ?assertEqual({error, badarg}, check(#{select => [4], colour => red})),
    ?assertEqual({error, badarg}, check(#{})),
    ?assertEqual({error, badarg}, check(#{select => [], kernel => false})),
    ?assertEqual({error, badarg}, check(#{frames => true, kernel => true})),
    ?assertEqual({error, badarg}, check([{select, [4]}])),
    ?assertEqual({error, badarg}, check(#{select => [4 | 4]})),
    ?assertEqual({error, badarg}, check(#{select => [-1]})),
    ?assertEqual({error, badarg}, check(#{select => [16#100000000]})),
    ?assertEqual({error, badarg}, check(#{select => [atom]})),
    ?assertEqual({error, badarg}, check(#{select => [4], kernel => yes})),
    ?assertEqual({error, badarg}, check(#{select => [4], frames => 1})).

%% The refusals come in order: a malformed Spec before a missing facet before scope.
no_facet_test() ->
    ?assertEqual({error, no_facet}, check(#{select => [4]}, none)),
    ?assertEqual({error, badarg}, check(#{}, none)).

scope_test() ->
    ?assertEqual({error, scope}, check(#{kernel => true}, [4])),
    ?assertMatch({ok, _}, check(#{select => [4]}, [4])),
    ?assertEqual({error, scope}, check(#{select => [4]}, [5])),
    ?assertEqual({error, scope}, check(#{select => [self()]}, [5])),
    %% start/3 asks the runtime itself whether a pid names a live process.
    Dead = spawn(fun() -> ok end),
    Monitor = monitor(process, Dead),
    receive {'DOWN', Monitor, process, Dead, _} -> ok end,
    ?assertEqual({error, scope}, erx_trace:start(#{select => [Dead]}, all, self())).

%% An unknown domain id and an existing one outside the scope answer alike, so the
%% answer does not tell which domains exist.
unknown_domain_test() ->
    ?assertEqual({error, scope}, check(#{select => [5]}, all)),
    ?assertEqual(check(#{select => [4]}, [6]), check(#{select => [6]}, [6])).

line_test() ->
    Entry = #{time => 41207119044, row => backend, event => wake,
              fields => #{slot => 2, result => ok, cpu => unknown, thread => 4, space => 1},
              reporter => {stopgap, liberx_trace}, late => false},
    ?assertEqual(<<"   41.207119044 backend wake result=ok slot=2 cpu=unknown thread=4 space=1 [liberx trace]\n">>,
                 erx_trace:line(Entry)),
    Erts = #{time => 7, row => erts, event => in, late => true, reporter => runtime,
             fields => #{pid => list_to_pid("<0.91.0>"), domain => 4, mfa => {timer, sleep, 1}}},
    ?assertEqual(<<"    0.000000007 erts in pid=<0.91.0> domain=4 mfa=timer:sleep/1 [runtime] late\n">>,
                 erx_trace:line(Erts)),
    Unsupported = #{time => 40993000112, row => kernel, event => unsupported, fields => #{},
                    reporter => kernel, late => false},
    ?assertEqual(<<"   40.993000112 kernel unsupported [kernel]\n">>, erx_trace:line(Unsupported)),
    %% A clock past 99,999 seconds widens the column; it is never cut or starred.
    ?assertEqual(<<"2464513.631646625 kernel unsupported [kernel]\n">>,
                 erx_trace:line(Unsupported#{time := 2464513631646625})),
    Unknown = #{time => 1, row => kernel, event => {unknown, 99}, fields => #{status => limit, cpu => 1},
                reporter => kernel, late => false},
    ?assertEqual(<<"    0.000000001 kernel unknown(99) status=limit cpu=1 [kernel]\n">>, erx_trace:line(Unknown)).

%% A traced process scheduled in a function whose name holds an escape sequence and a
%% newline: the line shows both escaped and stays one line.
escaped_line_test() ->
    Entry = #{time => 1, row => erts, event => out, late => false, reporter => runtime,
              fields => #{pid => self(), domain => 4,
                          mfa => {list_to_atom("m\e]0;x\^G"), list_to_atom("f\e[31m\nnext"), 0}}},
    Line = erx_trace:line(Entry),
    ?assertEqual(nomatch, binary:match(Line, [<<"\e">>, <<7>>])),
    %% The one newline is the line's own end.
    ?assertEqual([{byte_size(Line) - 1, 1}], binary:matches(Line, <<"\n">>)),
    ?assertNotEqual(nomatch, binary:match(Line, <<"mfa=m<U+001B>]0;x<U+0007>:f<U+001B>[31m<U+000A>next/0">>)).

%%% The trace process's decisions.

expect() ->
    #{ref => make_ref(), timer => make_ref(), receiver => make_ref(), session => true}.

%% Each message the trace process takes is named by its own reference, timer and monitor;
%% the same shapes with another reference, and a session message in any other shape, are
%% ignored.
classify_test() ->
    #{ref := Ref, timer := Timer, receiver := Monitor} = Expect = expect(),
    Other = make_ref(),
    In = {trace_ts, self(), in, {timer, sleep, 1}, 12},
    ?assertEqual(tick, erx_trace:classify({timeout, Timer, tick}, Expect)),
    ?assertEqual(stop, erx_trace:classify({erx_trace_stop, Ref}, Expect)),
    ?assertEqual(ack, erx_trace:classify({erx_trace_ack, Ref}, Expect)),
    ?assertEqual(receiver_down, erx_trace:classify({'DOWN', Monitor, process, self(), normal}, Expect)),
    ?assertEqual({session, In}, erx_trace:classify(In, Expect)),
    Out = {trace_ts, self(), out_exited, 0, 13},
    ?assertEqual({session, Out}, erx_trace:classify(Out, Expect)),
    Ignored = [tick, {timeout, Other, tick}, {erx_trace_stop, Other}, {erx_trace_ack, Other},
               {'DOWN', Other, process, self(), normal},
               {trace_ts, not_a_pid, in, 0, 1}, {trace_ts, self(), send, 0, 1},
               {trace_ts, self(), in, {m, f, a}, 1}, {trace_ts, self(), in, {m, f, -1}, 1},
               {trace_ts, self(), in, 0, 1.0}, {trace_ts, self(), in, 0, {1, 2, 3}},
               {trace_ts, self(), in, 0, 1, extra}],
    ?assertEqual([], [M || M <- Ignored, erx_trace:classify(M, Expect) =/= ignore]),
    %% A trace without a session takes no session message, and before its first timer
    %% no tick.
    ?assertEqual(ignore, erx_trace:classify(In, Expect#{session := false})),
    ?assertEqual(ignore, erx_trace:classify({timeout, none, tick}, Expect#{timer := none})).

entries(Row, Count) ->
    [#{time => Time, row => Row, event => in, fields => #{}, reporter => runtime, late => false}
     || Time <- lists:seq(1, Count)].

%% Sends Entries one at a time, as rounds would, never acknowledging: what went out.
unacknowledged(Window, Entries) ->
    lists:foldl(fun(Entry, {W, Sent}) ->
                        {W1, Out} = erx_trace:deliver(W, [Entry], 0),
                        {W1, Sent ++ Out}
                end, {Window, []}, Entries).

%% A receiver that never acknowledges gets the window and no more, however much is
%% traced; the rest is counted.
window_test() ->
    {W1, Sent} = unacknowledged(erx_trace:window(), entries(erts, 1000)),
    ?assertEqual(256, length(Sent)),
    ?assertMatch({_, []}, erx_trace:deliver(W1, entries(backend, 5), 0)),
    %% Each acknowledgement opens the window by 64; the first delivery after it reports
    %% each row's drops, at the time of the first entry it sends.
    {W2, []} = erx_trace:deliver(W1, entries(backend, 5), 0),
    {W3, Out} = erx_trace:deliver(erx_trace:acked(W2), entries(kernel, 100), 0),
    ?assertMatch([#{row := backend, event := dropped, fields := #{count := 5}, time := 1},
                  #{row := erts, event := dropped, fields := #{count := 744}, time := 1} | _], Out),
    ?assertEqual(64, length(Out)),
    %% The 38 entries of kernel that did not fit are the next report.
    {_, [Report]} = erx_trace:deliver(erx_trace:acked(W3), [], 77),
    ?assertMatch(#{row := kernel, event := dropped, fields := #{count := 38}, time := 77}, Report).

%% Acknowledgements never open the window past 256, however many arrive: a receiver
%% that acknowledges what it has not handled still has at most 256 entries out.
ack_bound_test() ->
    Flooded = lists:foldl(fun(_, W) -> erx_trace:acked(W) end, erx_trace:window(), lists:seq(1, 100)),
    {_, Sent} = erx_trace:deliver(Flooded, entries(erts, 1000), 0),
    ?assertEqual(256, length(Sent)).

%% A report that does not fit the window waits with its count.
report_wait_test() ->
    {W1, _} = erx_trace:deliver(erx_trace:window(), entries(erts, 300), 0),
    {W2, []} = erx_trace:deliver(W1, entries(backend, 1), 0),
    Open1 = lists:foldl(fun(_, W) -> erx_trace:acked(W) end, W2, [1]),
    %% 64 open: both reports go, then 62 entries.
    {_, Out} = erx_trace:deliver(Open1, entries(kernel, 70), 0),
    ?assertMatch([#{row := backend, fields := #{count := 1}}, #{row := erts, fields := #{count := 44}} | _], Out).

%% The round's batch holds 4,096 session messages; the next are counted as dropped erts
%% entries.
buffer_test() ->
    Message = {trace_ts, self(), in, 0, 1},
    {Batch, W} = lists:foldl(fun(_, {B, W0}) -> erx_trace:buffer(Message, B, W0) end,
                             {{0, []}, erx_trace:window()}, lists:seq(1, 4100)),
    ?assertMatch({4096, _}, Batch),
    ?assertEqual(4096, length(element(2, Batch))),
    {_, [Report]} = erx_trace:deliver(W, [], 5),
    ?assertMatch(#{row := erts, event := dropped, fields := #{count := 4}}, Report).

%% A ring moves to the next cursor and is read again after a full read; a refused ring
%% is read no more, and the others go on.
cursor_test() ->
    Cursors = #{backend => present, {kernel, 0} => 7},
    Full = lists:duplicate(512, record),
    ?assertEqual({false, Cursors#{backend := 40}}, erx_trace:cursor(Cursors, backend, {ok, [], 40, 0})),
    ?assertEqual({true, Cursors#{backend := 552}}, erx_trace:cursor(Cursors, backend, {ok, Full, 552, 3})),
    ?assertEqual({false, Cursors#{backend := 9}}, erx_trace:cursor(Cursors, backend, {ok, [a, b], 9, 0})),
    ?assertEqual({false, #{backend => present}}, erx_trace:cursor(Cursors, {kernel, 0}, {error, unsupported})),
    ?assertEqual({false, #{{kernel, 0} => 7}}, erx_trace:cursor(Cursors, backend, {error, inval})).

%% A receiver acknowledges every 64th entry it handled, and counts again from 0.
handled_test() ->
    Ref = alias(),
    ?assertEqual(64, lists:foldl(fun(_, N) -> erx_trace:handled(Ref, N) end, 0, lists:seq(1, 63)) + 1),
    ?assertEqual(0, erx_trace:handled(Ref, 63)),
    ?assertEqual({messages, [{erx_trace_ack, Ref}]}, process_info(self(), messages)),
    receive {erx_trace_ack, Ref} -> ok end.
