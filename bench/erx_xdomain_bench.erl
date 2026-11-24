%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_xdomain_bench).
-moduledoc """
The xdomain benchmark's guest (docs/design-bench.md, "5. `xdomain`: one message,
one domain to another"): one round trip of a small request, inside one domain
(local-rtt) and across a connection to erx_echo_test's facet in another
(xdomain-pingpong). Both are the same exchange, a gen_server call of {echo, B}
with B a binary of the asked size, answered {echo, B}; only where the server runs
differs. local-rtt's server is a process of this domain that answers the call as
the facet does. One request is outstanding at a time, and each round trip is
stamped on the client's side, so a cell needs no calibration across CPUs.

run/1 runs in a domain the echo facet is granted to and answers the boot's lines,
the CLOCK line first: the host prints them and judges them
(Erx::BenchMeasurement). A reply that is not its request fails its cell, as does
a call with no reply or a domain that holds no echo facet.
""".
-export([run/1]).

-define(BENCHMARK, <<"xdomain">>).
-define(CALL_MS, 5000).
%% How long, and how often, run/1 waits for the domain's echo facet.
-define(FACET_POLLS, 600).
-define(FACET_POLL_MS, 100).

-doc """
The boot's lines for a fast profile's Warmup and Samples and a request of Bytes:
the CLOCK line, then local-rtt's BENCH line, then xdomain-pingpong's.
""".
-spec run(#{warmup := non_neg_integer(), samples := pos_integer(), bytes := non_neg_integer()}) -> [binary()].
run(#{warmup := Warmup, samples := Samples, bytes := Bytes}) ->
    Clock = erx_bench_hist:calibrate(),
    Request = {echo, binary:copy(<<16#a5>>, Bytes)},
    Local = spawn_link(fun echo/0),
    Cells = [cell(<<"local-rtt">>, {ok, Local}, Request, Warmup, Samples, Clock),
             cell(<<"xdomain-pingpong">>, facet(?FACET_POLLS), Request, Warmup, Samples, Clock)],
    unlink(Local),
    exit(Local, kill),
    [erx_bench_hist:clock_line(Clock) | [erx_bench_hist:cell_line(Cell) || Cell <- Cells]].

%% local-rtt's server: it answers {echo, Term} as erx_echo_test's facet does.
echo() ->
    receive
        {'$gen_call', From, {echo, Term}} ->
            gen:reply(From, {echo, Term}),
            echo()
    end.

%% The echo facet this domain holds, waiting for its grant to be installed.
facet(0) ->
    {error, <<"the domain holds no echo facet">>};
facet(Polls) ->
    case erx:cap(echo) of
        Facet when is_pid(Facet) -> {ok, Facet};
        undefined -> timer:sleep(?FACET_POLL_MS), facet(Polls - 1)
    end.

%% One cell's fields: its round trips timed after the warm-up, in the batch the
%% warm-up's median asks for, or its failure with the samples taken before it.
cell(Operation, {error, Reason}, Request, _Warmup, _Samples, Clock) ->
    summary(Operation, Request, 1, {failed, Reason}, [], Clock);
cell(Operation, {ok, Server}, Request, Warmup, Samples, Clock) ->
    case trips(Server, Request, 1, Warmup, []) of
        {ok, Warm} ->
            Batch = erx_bench_hist:batch(median(Warm)),
            {Outcome, Taken} = case trips(Server, Request, Batch, Samples, []) of
                                   {ok, Timed} -> {measured, Timed};
                                   {failed, Why, Timed} -> {{failed, Why}, Timed}
                               end,
            summary(Operation, Request, Batch, Outcome, Taken, Clock);
        {failed, Why, _} ->
            summary(Operation, Request, 1, {failed, Why}, [], Clock)
    end.

%% Count samples of Batch round trips each, each sample the batch's mean in ticks,
%% in the order taken; the first wrong or missing reply ends them.
trips(_Server, _Request, _Batch, 0, Taken) ->
    {ok, lists:reverse(Taken)};
trips(Server, Request, Batch, Count, Taken) ->
    Start = erlang:monotonic_time(),
    case batch(Server, Request, Batch) of
        ok -> trips(Server, Request, Batch, Count - 1, [(erlang:monotonic_time() - Start) div Batch | Taken]);
        {failed, Why} -> {failed, Why, lists:reverse(Taken)}
    end.

batch(_Server, _Request, 0) ->
    ok;
batch(Server, Request, Left) ->
    try gen_server:call(Server, Request, ?CALL_MS) of
        Request -> batch(Server, Request, Left - 1);
        _ -> {failed, <<"a reply was not its request">>}
    catch
        exit:{timeout, _} -> {failed, <<"a request had no reply within 5 s">>};
        exit:_ -> {failed, <<"the server ended during a request">>}
    end.

median([]) -> 0;
median(Samples) -> lists:nth((length(Samples) + 1) div 2, lists:sort(Samples)).

summary(Operation, {echo, Binary} = Request, Batch, Outcome, Taken, Clock) ->
    {Status, Reason} = case Outcome of
                           measured -> {<<"measured">>, #{}};
                           {failed, Why} -> {<<"failed">>, #{reason => Why}}
                       end,
    Conditions = #{load => <<"idle">>, placement => <<"runtime">>, clock => maps:get(clock, Clock),
                   batch => Batch,
                   parameters => #{bytes => byte_size(Binary), encoded => byte_size(term_to_binary(Request))}},
    erx_bench_hist:cell(Reason#{benchmark => ?BENCHMARK, operation => Operation, conditions => Conditions,
                                frequency_hz => maps:get(frequency_hz, Clock), status => Status,
                                counts => #{lost => 0, early => 0, missed => 0}}, Taken).
