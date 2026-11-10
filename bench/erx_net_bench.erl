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

whose keys `tools/erx bench net-freebsd` reads, followed by one
`COUNTER name=value` line for each counter the interface keeps. `main/1`
adds two lines, `BEAM schedulers=N online=N sbwt=V sbwtdcpu=V sbwtdio=V`
(the emulator's scheduler settings, `default` where no flag set one) and
`WINDOW cpu_ms=N voluntary=N involuntary=N` (the emulator's user and system CPU time and
context switches from just before the run to just after it, so the
emulator's start-up is not in them; no WINDOW line where the host's `ps`
does not report switches). The lwIP client (`bench/lwip/lwip_bench.c`)
prints the same RESULT and WINDOW lines.
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
It prints the BEAM and WINDOW lines around the run.
""".
-spec main([string()]) -> no_return().
main(["echo", Peer, Port, Secs]) ->
    serve(ip(Peer), int(Port), int(Secs));
main([Mode, Device, Peer, Port | Rest]) when Mode =:= "send"; Mode =:= "recv"; Mode =:= "rr" ->
    start_stack(Device, ip(Peer)),
    Spec = maps:merge(#{mode => list_to_atom(Mode), peer => ip(Peer), port => int(Port)}, sizes(Mode, Rest)),
    print_beam(),
    Before = run_usage(),
    Outcome = try run(Spec) catch Class:Reason:Stack -> {error, {Class, Reason, Stack}} end,
    print_window(Before, run_usage()),
    exit_with(Outcome).

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

%% The emulator's scheduler settings, as it was started: the flag's value, or `default`.
print_beam() ->
    Args = erlang:system_info(emu_args),
    io:format("BEAM schedulers=~p online=~p sbwt=~s sbwtdcpu=~s sbwtdio=~s~n",
              [erlang:system_info(schedulers), erlang:system_info(schedulers_online),
               flag("-sbwt", Args), flag("-sbwtdcpu", Args), flag("-sbwtdio", Args)]).

%% The last setting of a flag, as `-flag value` or attached as `-flagvalue` (the beam takes
%% the last of a repeated flag). The values of the sbwt flags never start with `d`, which
%% tells `-sbwtdcpu` from an attached value of `-sbwt`.
flag(Name, Args) ->
    Settings = flag_settings(Name, Args),
    case lists:reverse(Settings) of
        [Value | _] -> Value;
        [] -> "default"
    end.

flag_settings(_, []) -> [];
flag_settings(Name, [Name, Value | Rest]) -> [Value | flag_settings(Name, Rest)];
flag_settings(Name, [Arg | Rest]) ->
    case lists:prefix(Name, Arg) of
        true when length(Arg) > length(Name) ->
            case lists:nthtail(length(Name), Arg) of
                [$d | _] -> flag_settings(Name, Rest);
                Value -> [Value | flag_settings(Name, Rest)]
            end;
        _ ->
            flag_settings(Name, Rest)
    end.

%% The emulator process's CPU time (user and system, all its threads, ms) and its voluntary
%% and involuntary context switches, from one call of the host's ps, which is the
%% getrusage of the whole process that lwip_bench reads too. `unsupported` where ps does
%% not answer in the shape of FreeBSD's `time`, `nvcsw` and `nivcsw` columns, so no WINDOW
%% line carries a number nothing measured.
-spec run_usage() -> {non_neg_integer(), non_neg_integer(), non_neg_integer()} | unsupported.
run_usage() ->
    Ps = os:cmd("ps -o time= -o nvcsw= -o nivcsw= -p " ++ os:getpid()),
    case string:tokens(Ps, " \t\n") of
        [Time, Voluntary, Involuntary] ->
            case {cpu_ms(Time), to_integer(Voluntary), to_integer(Involuntary)} of
                {Cpu, Vol, Invol} when is_integer(Cpu), is_integer(Vol), is_integer(Invol) ->
                    {Cpu, Vol, Invol};
                _ ->
                    unsupported
            end;
        _ ->
            unsupported
    end.

%% ps's `time` column, `[[H:]M:]S.cc`, in milliseconds; anything else is not a number.
cpu_ms(Text) ->
    try
        Parts = string:split(Text, ":", all),
        true = length(Parts) =< 3,
        {Whole, Cs} = case string:split(lists:last(Parts), ".") of
                          [Secs, Frac] when length(Frac) =:= 2 -> {Secs, list_to_integer(Frac)};
                          [Secs] -> {Secs, 0}
                      end,
        Fields = lists:droplast(Parts) ++ [Whole],
        Seconds = lists:foldl(fun(Field, Acc) -> Acc * 60 + list_to_integer(Field) end, 0, Fields),
        true = Cs >= 0 andalso Seconds >= 0,
        Seconds * 1000 + Cs * 10
    catch
        error:_ -> not_a_number
    end.

to_integer(Word) ->
    try list_to_integer(Word) catch error:badarg -> not_a_number end.

print_window({Cpu0, Vol0, Invol0}, {Cpu1, Vol1, Invol1}) ->
    io:format("WINDOW cpu_ms=~p voluntary=~p involuntary=~p~n", [Cpu1 - Cpu0, Vol1 - Vol0, Invol1 - Invol0]);
print_window(_, _) ->
    ok.

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
