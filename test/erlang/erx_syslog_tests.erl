%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The log service, erx_syslog, with stand-ins for its take, its clock and its
%% consumers (docs/design-log.md, "Verification and testing": attribution, rate, no
%% wait, the consumer protocol, restart). The test is both consumers: it asks with
%% erx_syslog:next/1 as the console and the store do.
-module(erx_syslog_tests).
-include_lib("eunit/include/eunit.hrl").

-define(S, 1000000000).
-define(RATE, 16384).

service_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun(_) -> ?_test(attribution()) end,
      fun(_) -> ?_test(rate()) end,
      fun(_) -> ?_test(no_wait()) end,
      fun(_) -> ?_test(one_batch_per_request()) end,
      fun(_) -> ?_test(the_store_waits_for_its_batch()) end,
      fun(_) -> ?_test(kernel_lines_and_losses()) end,
      fun(_) -> ?_test(restart()) end]}.

setup() ->
    process_flag(trap_exit, true),
    persistent_term:erase({erx_syslog, started}),
    Clock = spawn(fun() -> clock(?S) end),
    register(syslog_test_clock, Clock),
    Clock.

cleanup(Clock) ->
    [stop(whereis(Name)) || Name <- [erx_syslog_sup, erx_syslog]],
    stop(Clock),
    persistent_term:erase({erx_syslog, started}),
    flush().

%% The clock the service reads, which the test moves.
clock(Now) ->
    receive
        {get, From, Ref} -> From ! {Ref, Now}, clock(Now);
        {set, Later} -> clock(Later)
    end.

clock_now() ->
    Ref = make_ref(),
    syslog_test_clock ! {get, self(), Ref},
    receive {Ref, Now} -> Now end.

set_clock(Now) ->
    syslog_test_clock ! {set, Now},
    _ = clock_now(),
    ok.

start() ->
    start(fun() -> {ok, 0, 0, []} end).

start(Take) ->
    {ok, Pid} = erx_syslog:start_link(#{take => Take, clock => fun clock_now/0,
                                        source => fun(Id) -> #{id => Id, principal => 3, name => <<"web">>} end}),
    Pid.

%% The console's next batch, waiting at most Ms for it.
batch(Role, Ms) ->
    Request = erx_syslog:next(Role),
    receive_batch(Request, Ms).

receive_batch(Request, Ms) ->
    case gen_server:receive_response(Request, Ms) of
        {reply, Lines} -> Lines;
        timeout -> timeout;
        {error, Reason} -> {error, Reason}
    end.

write(Grantee, Records) ->
    gen_server:call(erx_syslog, {write, Grantee, Records}, 1000).

%% L1: a domain's line is under the facet's grantee, with the service's time, whatever
%% its text claims. The facet's callback forwards the grantee it was minted for.
attribution() ->
    start(),
    _Start = batch(console, 1000),
    set_clock(5 * ?S + 250000000),
    Request = {write, [{info, <<"domain 1 principal 0 erx_syslog: start">>}]},
    {forward, Service, Forward, _} = erx_log_facet:admit(Request, self(), #{grantee => 7}),
    ok = gen_server:call(Service, Forward),
    ?assertEqual([<<"5.250000 info domain 7 principal 3 web: domain 1 principal 0 erx_syslog: start">>],
                 batch(console, 1000)),
    ?assertMatch({refuse, badarg, _}, erx_log_facet:admit({write, [{info, x}]}, self(), #{grantee => 7})).

%% A flood at twice the rate keeps at most the rate's bytes of lines in its second, and
%% the next second's turn writes the domain's drops line.
rate() ->
    start(),
    _Start = batch(console, 1000),
    Empty = lists:duplicate(16, {info, <<>>}),
    [ok = write(7, Empty) || _ <- lists:seq(1, 2 * ?RATE div (16 * 40))],
    Kept = batch(console, 1000),
    ?assert(lists:sum([byte_size(L) + 1 || L <- Kept]) =< ?RATE),
    set_clock(2 * ?S),
    Drops = batch(console, 1000),
    ?assertMatch([_], [L || L <- Drops, binary:match(L, <<"erx_syslog: domain 7: ">>) =/= nomatch]).

%% L3: with a console that never asks again and a store that never asks, every write
%% answers at once, the service's memory stays bounded, and the console's next batch
%% begins with the lines its backlog dropped.
no_wait() ->
    Pid = start(),
    _Start = batch(console, 1000),
    _Stalled = erx_syslog:next(console),
    Text = binary:copy(<<"x">>, 4000),
    %% Each second's writes, 100 domains at their rate, past a backlog's 1 MiB; the
    %% pause lets a tick turn the rate's second.
    [begin
         set_clock(Second * ?S),
         timer:sleep(150),
         [ok = write(Domain, lists:duplicate(4, {info, Text})) || Domain <- lists:seq(1, 100)]
     end || Second <- lists:seq(2, 4)],
    %% Its heap and the line binaries it holds, which live off the heap: two backlogs
    %% of at most 1 MiB, sharing their lines.
    [{memory, Heap}, {binary, Binaries}] = process_info(Pid, [memory, binary]),
    ?assert(Heap + lists:sum([Size || {_Id, Size, _Refs} <- Binaries]) < 4 * 1048576),
    [First | _] = batch(console, 1000),
    ?assertNotEqual(nomatch, binary:match(First, <<"lines missed">>)).

%% A consumer receives a batch only as the answer to its own request: one request, one
%% batch, however many lines join after it.
one_batch_per_request() ->
    start(),
    Request = erx_syslog:next(console),
    {reply, _Start} = gen_server:receive_response(Request, 1000),
    Second = erx_syslog:next(console),
    ok = write(7, [{info, <<"one">>}]),
    {reply, [_]} = gen_server:receive_response(Second, 1000),
    %% Unasked, "two" waits in the backlog: a batch sent without a request would carry
    %% it to a request already answered, and the next request would find nothing.
    ok = write(7, [{info, <<"two">>}]),
    timer:sleep(200),
    ?assertMatch([_], batch(console, 1000)),
    %% Another process's request is refused while the consumer's is kept.
    Kept = erx_syslog:next(console),
    Test = self(),
    spawn_link(fun() -> Test ! {other, batch(console, 1000)} end),
    ?assertEqual({error, busy}, receive {other, Other} -> Other after 1000 -> timeout end),
    ok = write(7, [{info, <<"three">>}]),
    ?assertMatch({reply, [_]}, gen_server:receive_response(Kept, 1000)).

%% The store's batch waits for a second after its oldest line, or for 64 KiB.
the_store_waits_for_its_batch() ->
    start(),
    Request = erx_syslog:next(store),
    ?assertEqual(timeout, gen_server:wait_response(Request, 300)),
    set_clock(2 * ?S + 1),
    {reply, Batch} = gen_server:receive_response(Request, 1000),
    ?assertMatch([{messages, _}], Batch).

%% Each kernel line joins the backlogs once as a kernel line, without its newline, and
%% a loss or a failed check is the service's note.
kernel_lines_and_losses() ->
    Answers = spawn_link(fun() -> answers([{corrupt, 2, 3, [<<"#9 0.5 info k\n">>]}]) end),
    start(fun() -> Ref = make_ref(), Answers ! {take, self(), Ref}, receive {Ref, A} -> A end end),
    Lines = batch(console, 1000),
    ?assertEqual([<<"#9 0.5 info k">>], [L || <<"#", _/binary>> = L <- Lines]),
    ?assertMatch([_], [L || L <- Lines, binary:match(L, <<"erx_syslog: 3 kernel log records lost">>) =/= nomatch]),
    ?assertMatch([_], [L || L <- Lines, binary:match(L, <<"failed its checks">>) =/= nomatch]).

answers(Queue) ->
    receive
        {take, From, Ref} ->
            case Queue of
                [A | Rest] -> From ! {Ref, A}, answers(Rest);
                [] -> From ! {Ref, {ok, 0, 0, []}}, answers([])
            end
    end.

%% Killed, the service restarts under its supervisor: the new service writes
%% `restarted`, and the facet's callback, which finds the service by its name at each
%% request, forwards the next write to it. (A held write's `{error, failed}` is
%% erx_facet's, through its monitor of the service, and erx_facet_tests' to show.)
restart() ->
    {ok, _Sup} = supervisor:start_link({local, erx_syslog_sup}, erx_syslog_sup, []),
    Old = whereis(erx_syslog),
    ?assertMatch([_ | _], batch(console, 1000)),
    exit(Old, kill),
    New = wait_new(Old),
    Lines = batch(console, 1000),
    ?assertMatch([_], [L || L <- Lines, binary:match(L, <<"erx_syslog: restarted">>) =/= nomatch]),
    ?assertMatch({forward, New, _, _}, erx_log_facet:admit({write, [{info, <<"x">>}]}, self(), #{grantee => 7})).

wait_new(Old) ->
    case whereis(erx_syslog) of
        Pid when is_pid(Pid), Pid =/= Old -> Pid;
        _ -> timer:sleep(5), wait_new(Old)
    end.

%% Kill a process (none when undefined) and return once it is dead, so the name it held
%% is free for the next case.
stop(undefined) ->
    ok;
stop(Pid) ->
    Ref = monitor(process, Pid),
    unlink(Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok end.

flush() ->
    receive _ -> flush() after 0 -> ok end.
