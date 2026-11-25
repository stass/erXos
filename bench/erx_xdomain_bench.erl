%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_xdomain_bench).
-moduledoc """
The xdomain benchmark's guest (docs/design-bench.md, "5. `xdomain`: one message,
one domain to another"): one round trip of a small request, inside one domain
(local-rtt) and across a connection to an echo in another (xdomain-pingpong).
Both are the same exchange, a gen_server call of {echo, B} with B a binary of
the asked size, answered {echo, B}; only where the server runs differs.
local-rtt's server is a process of this domain that answers the call as the facet
does. One request is outstanding at a time, and each round trip is stamped on the
client's side, so a cell needs no calibration across CPUs.

The boot chooses xdomain-pingpong's echo, the module's one difference by system
(docs/design-bench.md, "Linux's Erlang guest"): on erXos, `facet`, erx_echo_test's
facet granted to this domain; under stock OTP, {Name, Node}, the process serve/1
registered as Name on the peer node Node, reached over distribution.

cells/2 runs under erx_bench_hist:run/1, which prints the boot's CLOCK line before
these cells' BENCH lines: the host judges them (Erx::BenchMeasurement). A reply
that is not its request fails its cell, as does a call with no reply, an echo
that cannot be reached, or any exception the cell raises, so cells/2 always
answers both cells and the host always sees how each ended.
""".
-export([cells/2, serve/1]).

-define(BENCHMARK, <<"xdomain">>).
-define(CALL_MS, 5000).
%% How long, and how often, cells/2 waits for the domain's echo facet, and for the
%% peer node's echo: a peer node that refuses the connection, as one with another
%% cookie does, looks like one not yet started, so its wait is shorter.
-define(FACET_POLLS, 600).
-define(PEER_POLLS, 100).
-define(POLL_MS, 100).

-type echo() :: facet | {Name :: atom(), Node :: node()}.

-doc """
The cells' fields for a fast profile's Warmup and Samples, a request of Bytes and
xdomain-pingpong's Echo, timed on Clock, the boot's calibration: local-rtt's, then
xdomain-pingpong's.
""".
-spec cells(#{warmup := non_neg_integer(), samples := pos_integer(), bytes := non_neg_integer(),
              echo := echo()}, map()) -> [map()].
cells(#{warmup := Warmup, samples := Samples, bytes := Bytes, echo := Echo}, Clock) ->
    Request = {echo, binary:copy(<<16#a5>>, Bytes)},
    Local = spawn(fun echo/0),
    try
        [cell(<<"local-rtt">>, fun() -> {ok, Local} end, Request, Warmup, Samples, Clock),
         cell(<<"xdomain-pingpong">>, fun() -> reach(Echo) end, Request, Warmup, Samples, Clock)]
    after
        exit(Local, kill)
    end.

-doc """
A stock OTP echo node's entry: registers as Name the echo a peer node's
xdomain-pingpong reaches as {Name, node()}, which answers {echo, Term} with
{echo, Term}, as local-rtt's server does.
""".
-spec serve(atom()) -> ok.
serve(Name) ->
    true = register(Name, spawn(fun echo/0)),
    ok.

%% The echo servers: each answers {echo, Term} with {echo, Term}, as erx_echo_test's
%% facet does, though without the erx_facet behaviour's loop.
echo() ->
    receive
        {'$gen_call', From, {echo, Term}} ->
            gen_server:reply(From, {echo, Term}),
            echo()
    end.

%% The server Echo names, waiting for it to appear.
reach(facet) -> facet(?FACET_POLLS);
reach({Name, Node}) -> peer(Name, Node, ?PEER_POLLS).

%% The echo facet this domain holds, waiting for its grant to be installed.
facet(0) ->
    {error, <<"the domain holds no echo facet">>};
facet(Polls) ->
    case erx:cap(echo) of
        Facet when is_pid(Facet) -> {ok, Facet};
        undefined -> timer:sleep(?POLL_MS), facet(Polls - 1)
    end.

%% Name on the peer node Node, waiting for the node to accept this one's connection
%% and for Name to be registered there.
peer(_Name, _Node, 0) ->
    {error, <<"the echo node refused the connection or has no echo registered">>};
peer(Name, Node, Polls) ->
    case net_kernel:connect_node(Node) =:= true andalso registered(Name, Node) of
        true -> {ok, {Name, Node}};
        false -> timer:sleep(?POLL_MS), peer(Name, Node, Polls - 1)
    end.

registered(Name, Node) ->
    try is_pid(erpc:call(Node, erlang, whereis, [Name], ?CALL_MS))
    catch
        error:_ -> false
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
