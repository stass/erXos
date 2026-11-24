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

cells/2 runs in a domain the echo facet is granted to, under erx_bench_hist:run/1,
which prints the boot's CLOCK line before these cells' BENCH lines: the host
judges them (Erx::BenchMeasurement). A reply that is not its request fails its
cell, as does a call with no reply, a domain that holds no echo facet, or any
exception the cell raises, so cells/2 always answers both cells and the host
always sees how each ended.
""".
-export([cells/2]).

-define(BENCHMARK, <<"xdomain">>).
-define(CALL_MS, 5000).
%% How long, and how often, run/1 waits for the domain's echo facet.
-define(FACET_POLLS, 600).
-define(FACET_POLL_MS, 100).

-doc """
The cells' fields for a fast profile's Warmup and Samples and a request of Bytes,
timed on Clock, the boot's calibration: local-rtt's, then xdomain-pingpong's.
""".
-spec cells(#{warmup := non_neg_integer(), samples := pos_integer(), bytes := non_neg_integer()}, map()) -> [map()].
cells(#{warmup := Warmup, samples := Samples, bytes := Bytes}, Clock) ->
    Request = {echo, binary:copy(<<16#a5>>, Bytes)},
    Local = spawn(fun echo/0),
    try
        [cell(<<"local-rtt">>, fun() -> {ok, Local} end, Request, Warmup, Samples, Clock),
         cell(<<"xdomain-pingpong">>, fun() -> facet(?FACET_POLLS) end, Request, Warmup, Samples, Clock)]
    after
        exit(Local, kill)
    end.

%% local-rtt's server: it answers {echo, Term} with {echo, Term}, as
%% erx_echo_test's facet does, though without the erx_facet behaviour's loop.
echo() ->
    receive
        {'$gen_call', From, {echo, Term}} ->
            gen_server:reply(From, {echo, Term}),
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

%% One cell's fields: its round trips to the server Find answers, timed after the
%% warm-up in the batch the warm-up's median asks for, or its failure with the
%% samples taken before it.
cell(Operation, Find, Request, Warmup, Samples, Clock) ->
    try timed(Operation, Find(), Request, Warmup, Samples, Clock)
    catch
        _:_ -> summary(Operation, Request, 1, {failed, <<"the cell raised an exception">>}, [], Clock)
    end.

timed(Operation, {error, Reason}, Request, _Warmup, _Samples, Clock) ->
    summary(Operation, Request, 1, {failed, Reason}, [], Clock);
timed(Operation, {ok, Server}, Request, Warmup, Samples, Clock) ->
    case trips(Server, Request, 1, Warmup, []) of
        {ok, []} ->
            measure(Operation, Server, Request, 1, Samples, Clock);
        {ok, Warm} ->
            Batch = erx_bench_hist:batch(median(Warm), maps:get(increment, Clock)),
            measure(Operation, Server, Request, Batch, Samples, Clock);
        {failed, Why, _} ->
            summary(Operation, Request, 1, {failed, Why}, [], Clock)
    end.

measure(Operation, Server, Request, Batch, Samples, Clock) ->
    {Outcome, Taken} = case trips(Server, Request, Batch, Samples, []) of
                           {ok, Timed} -> {measured, Timed};
                           {failed, Why, Timed} -> {{failed, Why}, Timed}
                       end,
    summary(Operation, Request, Batch, Outcome, Taken, Clock).

%% Count samples of Batch round trips each, each sample the batch's mean in ticks,
%% in the order taken; the first wrong or missing reply ends them.
trips(_Server, _Request, _Batch, 0, Taken) ->
    {ok, lists:reverse(Taken)};
trips(Server, Request, Batch, Count, Taken) ->
    Start = erlang:monotonic_time(),
    case round_trips(Server, Request, Batch) of
        ok -> trips(Server, Request, Batch, Count - 1, [(erlang:monotonic_time() - Start) div Batch | Taken]);
        {failed, Why} -> {failed, Why, lists:reverse(Taken)}
    end.

%% Left round trips, each answered by its request.
round_trips(_Server, _Request, 0) ->
    ok;
round_trips(Server, Request, Left) ->
    try gen_server:call(Server, Request, ?CALL_MS) of
        Request -> round_trips(Server, Request, Left - 1);
        _ -> {failed, <<"a reply was not its request">>}
    catch
        exit:{timeout, _} -> {failed, <<"a request had no reply in time">>};
        exit:_ -> {failed, <<"the server ended during a request">>}
    end.

median([]) -> 0;
median(Samples) -> lists:nth((length(Samples) + 1) div 2, lists:sort(Samples)).

summary(Operation, {echo, Binary} = Request, Batch, Outcome, Taken, Clock) ->
    {Status, Reason} = case Outcome of
                           measured -> {<<"measured">>, #{}};
                           {failed, Why} -> {<<"failed">>, #{reason => Why}}
                       end,
    Parameters = #{bytes => byte_size(Binary), encoded => byte_size(term_to_binary(Request))},
    Conditions = #{load => <<"idle">>, placement => <<"runtime">>, clock => maps:get(clock, Clock),
                   batch => Batch, parameters => Parameters},
    Fields = #{benchmark => ?BENCHMARK, operation => Operation, conditions => Conditions,
               frequency_hz => maps:get(frequency_hz, Clock), status => Status,
               counts => #{lost => 0, early => 0, missed => 0}},
    erx_bench_hist:cell(maps:merge(Fields, Reason), Taken).
