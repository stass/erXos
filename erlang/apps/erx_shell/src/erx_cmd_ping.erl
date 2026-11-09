%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_ping).
-moduledoc """
`ping [-c count] [-i wait] [-s packetsize] [-t timeout] host`: sends ICMP echo requests
to an IPv4 host and writes each reply, then the statistics, as FreeBSD's ping does
(sbin/ping/ping.c, ping(8)). The host is an address in dotted form; ping resolves
no names, and one that is not an address is reported as FreeBSD reports a name it
cannot resolve, `ping: cannot resolve HOST: Unknown host`, with status 68.

Flags, as FreeBSD's: `-c` stops after that many requests, `-i` waits that many seconds
between requests (1 when absent; a fraction allowed down to 1 ms, as root may), `-s`
sends that many data bytes (56 when absent, at most 65507, which an IPv4 datagram
holds), and `-t` ends ping after that many seconds (1 to 3600) however many replies came.
A value out of range is FreeBSD's usage diagnostic with status 64. Without `-c` or
`-t`, ping runs until it is interrupted, which ends it without the statistics.

Output, in FreeBSD's layout:

    PING 10.0.2.2 (10.0.2.2): 56 data bytes
    64 bytes from 10.0.2.2: icmp_seq=0 ttl=255 time=0.412 ms

    --- 10.0.2.2 ping statistics ---
    1 packets transmitted, 1 packets received, 0.0% packet loss
    round-trip min/avg/max/stddev = 0.412/0.412/0.412/0.000 ms

A reply's size is its ICMP message's, header included. A reply seen before for its
sequence number is marked `(DUP!)` and counted as a duplicate, as FreeBSD counts it in
the 1024 sequence numbers it remembers. Under 8 data bytes there is no room for the send
time, and, as on FreeBSD, no reply shows a time and no round-trip line is written. The
status is 0 when a reply came and 2 when none did.

Matching. The echo socket (erx_icmp_sock) hands this command only the replies that carry
its identifier, at most 16 waiting. This command matches the sequence number: a reply
counts only when it carries a sequence number this ping sent and still remembers (the
last 1024), and every other reply is ignored. The round-trip time is measured from this
command's own record of when it sent that sequence number, never from the time the
request carried, since a reply's data are the peer's bytes. Nothing of a reply's data is
written: the sender is an address the stack decoded and the other fields are numbers.

The options, the record of what was sent and received, and every line are a pure core
(options/1, payload/2, sent/3, reply/3, header/2, statistics/2), which the tests drive
directly; run/2 owns the socket and the clock.
""".

-behaviour(erx_cmd).
-erx_command(ping).
-erx_usage("ping [-c count] [-i wait] [-s packetsize] [-t timeout] host").

-export([run/2, ping/3]).
-export([options/1, payload/2, sent/3, reply/3, header/2, statistics/2, new/1]).

-export_type([options/0, tally/0]).

-define(DEFDATALEN, 56).
-define(MAXPAYLOAD, 65507).                % IP_MAXPACKET less the IP and ICMP headers
-define(TIMEVAL_LEN, 8).
-define(ICMP_MINLEN, 8).
-define(MAX_DUP_CHK, 1024).
-define(MAXWAIT_MS, 10000).                % FreeBSD's default -W, after the last request
-define(MAXALARM, 3600).
-define(EX_USAGE, <<"64">>).
-define(EX_NOHOST, <<"68">>).

-type options() :: #{count := pos_integer() | infinity, interval := pos_integer(),
                     size := 0..?MAXPAYLOAD, timeout := 1..?MAXALARM | infinity,
                     host := inet:ip4_address(), name := binary()}.

-doc """
What ping knows of its requests and replies: the counts, the send time of each of the
last 1024 sequence numbers and whether a reply to it came, and the sums of the
round-trip times in milliseconds.
""".
-opaque tally() :: #{timing := boolean(), transmitted := non_neg_integer(),
                      received := non_neg_integer(), repeats := non_neg_integer(),
                      sent := #{0..(?MAX_DUP_CHK - 1) => {0..16#ffff, integer(), boolean()}},
                      tmin := float() | none, tmax := float(), tsum := float(),
                      tsumsq := float()}.

%%% The command

run(Args, Ctx) ->
    case options(Args) of
        {ok, Opts} -> ping(Opts, Ctx);
        {error, usage} -> {error, usage};
        {error, {usage, Text}} -> fail(Ctx, Text, ?EX_USAGE);
        {error, {no_host, Name}} -> fail(Ctx, [<<"cannot resolve ">>, Name, <<": Unknown host">>], ?EX_NOHOST)
    end.

fail(Ctx, Text, Status) ->
    erx_cmd:say(Ctx, [<<"ping: ">>, Text, $\n]),
    {error, {reported, Status}}.

%% FreeBSD's ping ends with EX_OSERR when it cannot open its socket.
ping(Opts, Ctx) ->
    case erx_icmp_sock:open(#{}) of
        {ok, Sock} ->
            ping(Sock, Opts, Ctx);
        {error, Reason} ->
            erx_cmd:report(Ctx, <<"socket">>, Reason),
            {error, {reported, <<"71">>}}
    end.

-doc """
Runs ping over the open echo socket Sock, which it closes at the end: the header, the
requests and replies, the statistics, and the exit status (2 when no reply came).
""".
ping(Sock, #{size := Size, timeout := Timeout} = Opts, Ctx) ->
    try
        erx_cmd:write(Ctx, header(Opts, Size)),
        Now = now_us(),
        End = case Timeout of
                  infinity -> infinity;
                  Seconds -> Now + Seconds * 1000000
              end,
        Record = loop(#{sock => Sock, opts => Opts, ctx => Ctx, next => Now, last => none,
                        lingering => false, finish => End}, new(Size)),
        erx_cmd:write(Ctx, statistics(Opts, Record)),
        case Record of
            #{received := 0} -> {error, {reported, <<"2">>}};
            #{} -> ok
        end
    after
        erx_icmp_sock:close(Sock)
    end.

%% FreeBSD's main loop: a request at each interval while the count allows, then one more
%% interval and the wait for the last replies; replies as they come; the -t alarm, and
%% every reply in, end it early. The interval timer is checked after every reply as well
%% as after every timeout, so a peer that keeps replies queued cannot hold it back.
loop(#{finish := Finish} = L, Record) ->
    Now = now_us(),
    case Now >= Finish orelse all_in(L, Record) of
        true ->
            Record;
        false ->
            #{next := Next} = L,
            Wait = max(0, (min(Next, Finish) - Now + 999) div 1000),
            case erx_icmp_sock:recv(maps:get(sock, L), Wait) of
                {ok, Reply} -> tick(L, received(Reply, L, Record));
                {error, timeout} -> tick(L, Record)
            end
    end.

all_in(#{opts := #{count := Count}}, #{received := Received}) ->
    Count =/= infinity andalso Received >= Count.

received(Reply, #{ctx := Ctx}, Record0) ->
    {Line, Record} = reply(Reply, now_us(), Record0),
    ok = erx_cmd:write(Ctx, Line),
    Record.

%% The interval timer: the next request, or, past the count, one interval of grace and
%% then the wait for the last replies, which ends the loop.
tick(#{next := Next} = L, Record) ->
    case now_us() >= Next of
        false -> loop(L, Record);
        true -> due(L, Record)
    end.

due(#{lingering := true} = L, Record) ->
    loop(L#{finish := now_us()}, Record);
due(#{opts := #{count := Count}, next := Next} = L, #{transmitted := Count} = Record) ->
    loop(L#{lingering := true, next := Next + linger_us(Record)}, Record);
due(#{opts := #{interval := Interval, size := Size, host := Host}, sock := Sock, ctx := Ctx,
      next := Next} = L, #{transmitted := N} = Record) ->
    Seq = N band 16#ffff,
    Now = now_us(),
    case erx_icmp_sock:send(Sock, Host, Seq, #{data => payload(Size, Now)}) of
        ok -> ok;
        {error, Reason} -> erx_cmd:report(Ctx, <<"sendto">>, Reason)
    end,
    loop(L#{next := Next + Interval * 1000}, sent(Seq, Now, Record)).

%% After the last request: twice the longest round trip, at least a second, when a reply
%% came, else FreeBSD's default wait.
linger_us(#{received := 0}) -> ?MAXWAIT_MS * 1000;
linger_us(#{tmax := Tmax}) -> max(1000, trunc(2 * Tmax)) * 1000.

now_us() -> erlang:monotonic_time(microsecond).

%%% The core

-doc """
The options and host of an argument list, or the diagnostic FreeBSD gives: a usage error
for an unknown flag or a missing or extra operand, `{usage, Text}` for a value out of
range, `{no_host, Name}` for a host that is not an IPv4 address.
""".
-spec options([binary()]) ->
          {ok, options()} | {error, usage | {usage, iodata()} | {no_host, binary()}}.
options(Args) ->
    Defaults = #{count => infinity, interval => 1000, size => ?DEFDATALEN, timeout => infinity},
    maybe
        {ok, Flags, [Name]} ?= operands(erx_cmd:getopt(Args, "c:i:s:t:")),
        {ok, Opts} ?= flags(Flags, Defaults),
        {ok, Host} ?= host(Name),
        {ok, Opts#{host => Host, name => Name}}
    end.

operands({ok, Flags, [Name]}) -> {ok, Flags, [Name]};
operands({ok, _, _}) -> {error, usage};
operands({error, usage}) -> {error, usage}.

flags([], Opts) ->
    {ok, Opts};
flags([{Flag, Value} | Rest], Opts) ->
    case flag(Flag, Value) of
        {ok, Key, Parsed} -> flags(Rest, Opts#{Key => Parsed});
        {error, _} = Error -> Error
    end.

flag($c, Value) ->
    case integer(Value) of
        {ok, N} when N > 0, N =< 16#7fffffff -> {ok, count, N};
        _ -> invalid(<<"invalid count of packets to transmit">>, Value)
    end;
flag($i, Value) ->
    case seconds(Value) of
        {ok, Ms} when Ms >= 1, Ms =< 16#7fffffff -> {ok, interval, Ms};
        _ -> invalid(<<"invalid timing interval">>, Value)
    end;
flag($s, Value) ->
    case integer(Value) of
        {ok, N} when N >= 0, N =< ?MAXPAYLOAD -> {ok, size, N};
        {ok, N} when N > ?MAXPAYLOAD ->
            {error, {usage, [<<"packet size too large: ">>, integer_to_binary(N), <<" > ">>,
                             integer_to_binary(?MAXPAYLOAD)]}};
        _ -> invalid(<<"invalid packet size">>, Value)
    end;
flag($t, Value) ->
    case integer(Value) of
        {ok, N} when N > 0, N =< ?MAXALARM -> {ok, timeout, N};
        _ -> invalid(<<"invalid timeout">>, Value)
    end.

%% FreeBSD's errx(EX_USAGE, "...: `%s'"), the value escaped since it is the user's text.
invalid(What, Value) ->
    {error, {usage, [What, <<": `">>, erx_text:escape_field(Value), $']}}.

integer(Value) when byte_size(Value) >= 1, byte_size(Value) =< 12 ->
    try {ok, binary_to_integer(Value)}
    catch error:badarg -> error
    end;
integer(_) ->
    error.

%% Seconds as strtod reads a plain decimal, in whole milliseconds.
seconds(Value) when byte_size(Value) >= 1, byte_size(Value) =< 16 ->
    case binary:split(Value, <<".">>) of
        [Whole] -> scaled(Whole, <<>>);
        [Whole, Fraction] -> scaled(Whole, Fraction)
    end;
seconds(_) ->
    error.

scaled(Whole, Fraction) ->
    Digits = <<Whole/binary, Fraction/binary>>,
    case Digits =/= <<>> andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Digits)) of
        true ->
            Milli = binary:part(<<Fraction/binary, "000">>, 0, 3),
            {ok, binary_to_integer(<<"0", Whole/binary>>) * 1000 + binary_to_integer(Milli)};
        false ->
            error
    end.

host(Name) ->
    case inet:parse_ipv4strict_address(binary_to_list(Name)) of
        {ok, Host} -> {ok, Host};
        {error, einval} -> {error, {no_host, erx_text:escape_field(Name)}}
    end.

-doc "A new record, for requests of Size data bytes.".
-spec new(0..?MAXPAYLOAD) -> tally().
new(Size) ->
    #{timing => Size >= ?TIMEVAL_LEN, transmitted => 0, received => 0, repeats => 0, sent => #{},
      tmin => none, tmax => 0.0, tsum => 0.0, tsumsq => 0.0}.

-doc """
The data of a request, as FreeBSD's pinger fills them: the send time in its first eight
bytes when they fit, and byte `I` holding `I` from the eighth on.
""".
-spec payload(0..?MAXPAYLOAD, integer()) -> binary().
payload(Size, Now) when Size >= ?TIMEVAL_LEN ->
    Sec = (Now div 1000000) band 16#ffffffff,
    Nsec = (Now rem 1000000) * 1000,
    <<Sec:32, Nsec:32, (fill(?TIMEVAL_LEN, Size))/binary>>;
payload(Size, _Now) ->
    <<0:(Size * 8)>>.

fill(From, To) -> << <<(I band 16#ff)>> || I <- lists:seq(From, To - 1) >>.

-doc "The record after request `Seq` left at `Now` (microseconds).".
-spec sent(0..16#ffff, integer(), tally()) -> tally().
sent(Seq, Now, #{transmitted := N, sent := Sent} = Record) ->
    Record#{transmitted := N + 1, sent := Sent#{Seq rem ?MAX_DUP_CHK => {Seq, Now, false}}}.

-doc """
The line for a reply that arrived at `Now`, and the record after it, or no line and the
record unchanged for a reply to a sequence number this ping does not remember sending.
""".
-spec reply(erx_icmp_sock:reply(), integer(), tally()) -> {iodata(), tally()}.
reply({Src, Ttl, Seq, Data}, Now, #{sent := Sent} = Record0) ->
    Slot = Seq rem ?MAX_DUP_CHK,
    case Sent of
        #{Slot := {Seq, At, Seen}} ->
            Ms = (Now - At) / 1000,
            Record = counted(Seen, Ms, Record0#{sent := Sent#{Slot := {Seq, At, true}}}),
            {[integer_to_binary(?ICMP_MINLEN + byte_size(Data)), <<" bytes from ">>, inet:ntoa(Src),
              <<": icmp_seq=">>, integer_to_binary(Seq), <<" ttl=">>, integer_to_binary(Ttl),
              time(Record, Ms), [<<" (DUP!)">> || Seen], $\n],
             Record};
        #{} ->
            {[], Record0}
    end.

counted(Seen, Ms, #{timing := Timing, tmin := Tmin, tmax := Tmax, tsum := Tsum,
                    tsumsq := Tsumsq} = Record0) ->
    Record = case Seen of
                 true -> Record0#{repeats := maps:get(repeats, Record0) + 1};
                 false -> Record0#{received := maps:get(received, Record0) + 1}
             end,
    case Timing of
        true -> Record#{tmin := min_time(Tmin, Ms), tmax := max(Tmax, Ms), tsum := Tsum + Ms,
                        tsumsq := Tsumsq + Ms * Ms};
        false -> Record
    end.

min_time(none, Ms) -> Ms;
min_time(Tmin, Ms) -> min(Tmin, Ms).

time(#{timing := true}, Ms) -> [<<" time=">>, ms(Ms), <<" ms">>];
time(#{timing := false}, _Ms) -> [].

ms(Ms) -> float_to_binary(float(Ms), [{decimals, 3}]).

-doc "The line ping writes first.".
-spec header(#{host := inet:ip4_address(), name := binary(), atom() => term()}, non_neg_integer()) -> iodata().
header(#{host := Host, name := Name}, Size) ->
    [<<"PING ">>, Name, <<" (">>, inet:ntoa(Host), <<"): ">>, integer_to_binary(Size), <<" data bytes\n">>].

-doc "The statistics ping writes last.".
-spec statistics(#{name := binary(), atom() => term()}, tally()) -> iodata().
statistics(#{name := Name}, #{transmitted := Sent, received := Received, repeats := Repeats,
                              timing := Timing} = Record) ->
    [<<"\n--- ">>, Name, <<" ping statistics ---\n">>,
     integer_to_binary(Sent), <<" packets transmitted, ">>,
     integer_to_binary(Received), <<" packets received, ">>,
     [[$+, integer_to_binary(Repeats), <<" duplicates, ">>] || Repeats > 0],
     loss(Sent, Received), $\n,
     [round_trip(Record) || Received > 0, Timing]].

loss(0, _Received) -> [];
loss(Sent, Received) when Received > Sent -> <<"-- somebody's printing up packets!">>;
loss(Sent, Received) ->
    Percent = (Sent - Received) * 100 / Sent,
    [float_to_binary(Percent, [{decimals, 1}]), <<"% packet loss">>].

round_trip(#{received := Received, repeats := Repeats, tmin := Tmin, tmax := Tmax, tsum := Tsum,
             tsumsq := Tsumsq}) ->
    N = Received + Repeats,
    Avg = Tsum / N,
    Stddev = math:sqrt(max(0.0, Tsumsq / N - Avg * Avg)),
    [<<"round-trip min/avg/max/stddev = ">>, lists:join($/, [ms(T) || T <- [Tmin, Avg, Tmax, Stddev]]),
     <<" ms\n">>].
