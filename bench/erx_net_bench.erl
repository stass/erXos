%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_bench).
-moduledoc """
The network benchmarks' Erlang side: bulk transfer and request-reply over
`erx_gen_tcp`, and the echo server that request-reply runs against.

One module serves both places `tools/erx bench` measures. On the FreeBSD test
host `main/1` starts `erx_net` on a tap device (`erl -noshell -run
erx_net_bench main ...`) and `run/1` measures it. In an erXos guest the stack is
already running, so `run/1` measures it as it is. Every run ends in one line,

    RESULT key=value key=value ...

whose keys `tools/erx bench net-p620` reads, followed by one
`COUNTER name=value` line for each counter the interface keeps. The lwIP
client (`bench/lwip/lwip_bench.c`) prints the same RESULT lines.
""".

-export([main/1, run/1, serve/3]).

-define(CHUNK, 65536).
-define(LLADDR, <<16#02, 16#65, 16#72, 16#78, 0, 16#64>>).
-define(LOCAL_IP, {10, 77, 0, 100}).
-define(CONNECT_MS, 10000).
-define(SETTLE_MS, 1000).

-type spec() :: #{mode := send | recv | rr, peer := inet:ip4_address(), port := inet:port_number(),
                  mib => pos_integer(), bytes => pos_integer(), conns => pos_integer(),
                  secs => pos_integer()}.
-export_type([spec/0]).

-doc """
Command line entry. `send|recv DEVICE PEER PORT MIB`, `rr DEVICE PEER PORT BYTES
CONNS SECS` (starting the stack on the tap device DEVICE first) and `echo PEER
PORT SECS` (stock `gen_tcp`, no stack). Exits 0 only if the run completed.
""".
-spec main([string()]) -> no_return().
main(["echo", Peer, Port, Secs]) ->
    serve(ip(Peer), int(Port), int(Secs));
main([Mode, Device, Peer, Port | Rest]) when Mode =:= "send"; Mode =:= "recv"; Mode =:= "rr" ->
    start_stack(Device, ip(Peer)),
    Spec = maps:merge(#{mode => list_to_atom(Mode), peer => ip(Peer), port => int(Port)}, sizes(Mode, Rest)),
    exit_with(try run(Spec) catch Class:Reason:Stack -> {error, {Class, Reason, Stack}} end).

-doc """
Measures one run against the running stack and prints its RESULT and COUNTER
lines. A run that does not complete (the peer closes early, a short transfer,
a connection that fails) returns `{error, Why}` and prints no RESULT line.
""".
-spec run(spec()) -> ok | {error, term()}.
run(#{mode := send, peer := Peer, port := Port, mib := Mib}) ->
    Bytes = Mib * 1048576,
    {ok, S} = erx_gen_tcp:connect(Peer, Port, [binary, {active, false}, {nodelay, true}], ?CONNECT_MS),
    Start = now_us(),
    ok = send_loop(S, binary:copy(<<0>>, ?CHUNK), Bytes),
    ok = erx_gen_tcp:shutdown(S, write),
    %% The sink closes after our FIN; that is the end of the transfer.
    {error, closed} = erx_gen_tcp:recv(S, 0),
    bulk_result(send, Bytes, now_us() - Start);
run(#{mode := recv, peer := Peer, port := Port, mib := Mib}) ->
    Bytes = Mib * 1048576,
    {ok, S} = erx_gen_tcp:connect(Peer, Port, [binary, {active, false}], ?CONNECT_MS),
    Start = now_us(),
    case recv_loop(S, 0) of
        Bytes -> bulk_result(recv, Bytes, now_us() - Start);
        Got -> {error, {short_transfer, Got, Bytes}}
    end;
run(#{mode := rr, peer := Peer, port := Port, bytes := Bytes, conns := Conns, secs := Secs}) ->
    Start = now_us(),
    Deadline = Start + Secs * 1000000,
    Self = self(),
    Workers = [spawn_monitor(fun() -> Self ! {self(), transact(Peer, Port, Bytes, Deadline)} end)
               || _ <- lists:seq(1, Conns)],
    Latencies = lists:append([await(Pid, Ref) || {Pid, Ref} <- Workers]),
    rr_result(Bytes, Conns, now_us() - Start, lists:sort(Latencies)).

-doc """
An echo server for `Secs` seconds on `Peer`:`Port`, on stock `gen_tcp` (it
runs in the peer's jail). It echoes every packet it reads, for any number of
connections, and stops the emulator when the time is up.
""".
-spec serve(inet:ip4_address(), inet:port_number(), pos_integer()) -> no_return().
serve(Peer, Port, Secs) ->
    {ok, Listen} = gen_tcp:listen(Port, [binary, {ip, Peer}, {active, false}, {nodelay, true},
                                         {reuseaddr, true}, {backlog, 64}]),
    spawn(fun() -> accept_loop(Listen) end),
    timer:sleep(Secs * 1000),
    halt(0).

%% Command line parsing

ip(Text) ->
    {ok, Ip} = inet:parse_ipv4strict_address(Text),
    Ip.

int(Text) -> list_to_integer(Text).

sizes("rr", [Bytes, Conns, Secs]) -> #{bytes => int(Bytes), conns => int(Conns), secs => int(Secs)};
sizes(_, [Mib]) -> #{mib => int(Mib)}.

exit_with(ok) -> halt(0);
exit_with({error, Why}) ->
    io:format(standard_error, "erx_net_bench: ~p~n", [Why]),
    halt(1).

%% The stack, started on a tap device as the host runs it, with the peer resolved by
%% ARP before the clock starts.
start_stack(Device, Peer) ->
    {ok, _} = erx_net_sup:start_link(#{interfaces => [#{name => en0,
        ip4 => #{addr => tuple_to_binary(?LOCAL_IP), plen => 24},
        transport => {erx_tap, #{device => Device, lladdr => ?LLADDR}}}]}),
    {ok, Sock} = erx_udp_sock:open(0, #{active => false}),
    _ = erx_udp_sock:send(Sock, Peer, 9, <<"resolve">>),
    ok = erx_udp_sock:close(Sock),
    timer:sleep(?SETTLE_MS).

tuple_to_binary(Tuple) -> list_to_binary(tuple_to_list(Tuple)).

%% Bulk

send_loop(_, _, 0) -> ok;
send_loop(S, Chunk, Left) ->
    N = min(Left, ?CHUNK),
    ok = erx_gen_tcp:send(S, binary:part(Chunk, 0, N)),
    send_loop(S, Chunk, Left - N).

recv_loop(S, Got) ->
    case erx_gen_tcp:recv(S, 0) of
        {ok, B} -> recv_loop(S, Got + byte_size(B));
        {error, closed} -> Got
    end.

bulk_result(Mode, Bytes, Micros) ->
    Secs = Micros / 1.0e6,
    io:format("RESULT mode=~w stack=erx_net bytes=~p secs=~.3f mbit=~.1f~n",
              [Mode, Bytes, Secs, Bytes * 8 / 1.0e6 / Secs]),
    counters().

%% Request-reply: a worker's connection sends Bytes and waits for them to come back,
%% over and over until the deadline, and answers its transactions' latencies in us.

transact(Peer, Port, Bytes, Deadline) ->
    {ok, S} = erx_gen_tcp:connect(Peer, Port, [binary, {active, false}, {nodelay, true}], ?CONNECT_MS),
    Request = binary:copy(<<0>>, Bytes),
    Latencies = transact_loop(S, Request, Bytes, Deadline, []),
    ok = erx_gen_tcp:close(S),
    Latencies.

transact_loop(S, Request, Bytes, Deadline, Acc) ->
    Begin = now_us(),
    ok = erx_gen_tcp:send(S, Request),
    {ok, Request} = erx_gen_tcp:recv(S, Bytes),
    End = now_us(),
    case End >= Deadline of
        true -> [End - Begin | Acc];
        false -> transact_loop(S, Request, Bytes, Deadline, [End - Begin | Acc])
    end.

await(Pid, Ref) ->
    receive
        {Pid, Latencies} -> erlang:demonitor(Ref, [flush]), Latencies;
        {'DOWN', Ref, process, Pid, Why} -> exit({worker_failed, Why})
    end.

rr_result(Bytes, Conns, Micros, Sorted) ->
    Count = length(Sorted),
    Secs = Micros / 1.0e6,
    io:format("RESULT mode=rr stack=erx_net bytes=~p conns=~p secs=~.3f txns=~p tps=~.1f p50_us=~p p99_us=~p~n",
              [Bytes, Conns, Secs, Count, Count / Secs, nth(Count div 2 + 1, Sorted),
               nth(Count * 99 div 100 + 1, Sorted)]),
    counters().

nth(N, List) -> lists:nth(min(N, length(List)), List).

now_us() -> erlang:monotonic_time(microsecond).

%% The interface's counters, one line each, by name. The counters the fast path adds
%% (runs, run_frames, units, unit_segments, frames_dropped) appear here once the
%% interface keeps them; until then they are absent and the reader reports them so.
counters() ->
    case erx_net_tables:interface(en0) of
        {ok, #{pid := If}} ->
            {ok, Counters} = erx_net_if:admin(If, counters),
            [io:format("COUNTER ~s=~p~n", [Name, Value]) || {Name, Value} <- lists:sort(maps:to_list(Counters))],
            ok;
        _ ->
            ok
    end.

%% The echo server

accept_loop(Listen) ->
    case gen_tcp:accept(Listen) of
        {ok, S} ->
            Echo = spawn(fun() -> receive go -> echo(S) end end),
            ok = gen_tcp:controlling_process(S, Echo),
            Echo ! go,
            accept_loop(Listen);
        {error, _} ->
            ok
    end.

echo(S) ->
    case gen_tcp:recv(S, 0) of
        {ok, Data} -> ok = gen_tcp:send(S, Data), echo(S);
        {error, _} -> gen_tcp:close(S)
    end.
