%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_tcp_syncache under virtual time: the five boundary properties of
%% docs/design-network-stack.md ("The syncache: properties at its boundaries"), the
%% SYN-ACK retransmission schedule with its ECN withdrawal, a repeated SYN that withdraws
%% but never grants ECN, the TCP-MD5 drops, the completing ACK's checks, the RST check, and
%% that no key shows when the secrets are printed.
-module(erx_tcp_syncache_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp_wire.hrl").

-define(KEY0, <<1:128>>).
-define(KEY1, <<2:128>>).
-define(KEY2, <<3:128>>).
-define(KEY3, <<4:128>>).
-define(ISN_SECRETS, erx_tcp_isn:secrets(<<16#a5:128>>, <<16#5a:128>>)).
-define(LISTENER, #{rcv_buf => 65536, rcv_scale => 3}).
-define(V4, {<<10, 0, 0, 1>>, 80, <<192, 0, 2, 7>>, 49152}).
-define(V6, {<<16#20010db8:32, 0:64, 1:32>>, 443, <<16#20010db8:32, 0:64, 2:32>>, 50000}).
-define(IRS, 16#fffffff0).

secrets() -> erx_tcp_syncache:secrets(?ISN_SECRETS, ?KEY0, ?KEY1).

ctx(Now) -> ctx(Now, secrets()).
ctx(Now, Secrets) -> #{now => Now, secrets => Secrets}.

syn(Conn, Opts) -> syn(Conn, Opts, ?TH_SYN).
syn({_, LPort, _, FPort}, Opts, Flags) ->
    #tcp{sport = FPort, dport = LPort, seq = ?IRS, ack = 0, flags = Flags, win = 65535, urp = 0,
         opts = Opts}.

full_opts() -> #tcp_opts{mss = 1460, wscale = 7, sack_permitted = true, ts = {1000, 0}}.

%% The ACK completing the handshake the SYN-ACK Synack opened.
ack_for({_, _, #tcp{seq = Iss, ack = RcvNxt, sport = LPort, dport = FPort}, _}, Opts) ->
    #tcp{sport = FPort, dport = LPort, seq = RcvNxt, ack = erx_tcp_seq:wire(Iss + 1),
         flags = ?TH_ACK, win = 65535, urp = 0, opts = Opts}.

%% A SYN to a table of no room, so its SYN-ACK carries a cookie and no entry is made.
cookie_synack(Conn, Opts, Now, Secrets) ->
    {Cache, [Synack]} = erx_tcp_syncache:add(Conn, syn(Conn, Opts), ?LISTENER, ctx(Now, Secrets),
                                             erx_tcp_syncache:new(0)),
    {Cache, Synack}.

%% Property 1: a cookie validates under the secrets that made it and after one rotation,
%% not after two.
rotation_test() ->
    S0 = secrets(),
    {Cache, Synack} = cookie_synack(?V4, full_opts(), 0, S0),
    Ack = ack_for(Synack, #tcp_opts{ts = {1001, 0}}),
    S1 = erx_tcp_syncache:rotate(?KEY2, S0),
    S2 = erx_tcp_syncache:rotate(?KEY3, S1),
    Outcome = fun(S) -> element(1, erx_tcp_syncache:expand(?V4, Ack, ?LISTENER, ctx(1000, S), Cache)) end,
    ?assertMatch({ok, _}, Outcome(S0)),
    ?assertMatch({ok, _}, Outcome(S1)),
    ?assertEqual(reset, Outcome(S2)).

%% Property 2: the fields a valid cookie gives back are the SYN's, the MSS and window shift
%% rounded down to tcp_sc_msstab and tcp_sc_wstab, for every window shift and an MSS on,
%% between and below the table's values, with and without SACK, IPv4 and IPv6.
fields_test() ->
    MssTab = [216, 536, 1200, 1360, 1400, 1440, 1452, 1460],
    WsTab = [0, 0, 1, 2, 4, 6, 7, 8],
    Down = fun(V, Tab) -> lists:max([0 | [T || T <- Tab, T =< V]]) end,
    Cases = [{Conn, Mss, Ws, Sack} || Conn <- [?V4, ?V6],
                                      Mss <- [none, 0, 100, 216, 1000, 1460, 9000],
                                      Ws <- [none | lists:seq(0, 14)],
                                      Sack <- [false, true]],
    lists:foreach(
      fun({Conn, Mss, Ws, Sack}) ->
              Opts = #tcp_opts{mss = Mss, wscale = Ws, sack_permitted = Sack},
              {Cache, Synack} = cookie_synack(Conn, Opts, 0, secrets()),
              {{ok, H}, _, []} = erx_tcp_syncache:expand(Conn, ack_for(Synack, #tcp_opts{}), ?LISTENER,
                                                         ctx(0), Cache),
              PeerMss = case Mss of none -> 0; _ -> Mss end,
              ?assertEqual(max(216, Down(PeerMss, MssTab)), maps:get(peer_mss, H)),
              ?assertEqual(case Ws of none -> none; _ -> {Down(Ws, WsTab), 3} end, maps:get(wscale, H)),
              ?assertEqual(Sack, maps:get(sack, H)),
              ?assertEqual(?IRS, maps:get(irs, H)),
              ?assertEqual(none, maps:get(ts, H))
      end, Cases).

%% Property 3: a cookie with any bit of its MAC changed, or presented for another
%% four-tuple, does not validate.
forgery_test() ->
    {Cache, Synack} = cookie_synack(?V4, full_opts(), 0, secrets()),
    #tcp{ack = Ack} = Good = ack_for(Synack, #tcp_opts{}),
    Expand = fun(Conn, Seg) -> element(1, erx_tcp_syncache:expand(Conn, Seg, ?LISTENER, ctx(0), Cache)) end,
    ?assertMatch({ok, _}, Expand(?V4, Good)),
    [?assertEqual(reset, Expand(?V4, Good#tcp{ack = Ack bxor (1 bsl Bit)})) || Bit <- lists:seq(8, 31)],
    {L, LP, F, FP} = ?V4,
    [?assertEqual(reset, Expand(Other, Good)) || Other <- [{L, LP, F, FP + 1}, {L, LP + 1, F, FP},
                                                           {L, LP, <<192, 0, 2, 8>>, FP}]].

%% Property 4: an ACK matching no entry is checked as a cookie exactly when the table is
%% paused or overflowed within the last 15 whole seconds of uptime, so still at 15 s, one
%% second after the first pause ends, as FreeBSD's
%% `sch_last_overflow < time_uptime - SYNCOOKIE_LIFETIME` decides, and not at 16 s.
overflow_window_test() ->
    Secrets = secrets(),
    {Overflowed, Synack} = cookie_synack(?V4, full_opts(), 10500, Secrets),
    Ack = ack_for(Synack, #tcp_opts{}),
    Expand = fun(Now, Cache) -> element(1, erx_tcp_syncache:expand(?V4, Ack, ?LISTENER, ctx(Now, Secrets), Cache)) end,
    ?assertEqual(reset, Expand(10500, erx_tcp_syncache:new())),
    ?assertMatch({ok, _}, Expand(10500, Overflowed)),
    ?assertMatch({ok, _}, Expand(25999, Overflowed)),
    ?assertEqual(reset, Expand(26000, Overflowed)),
    %% Uptime rounds down on a negative monotonic clock too: -1 ms is second -1.
    {Negative, Synack2} = cookie_synack(?V4, full_opts(), -1, Secrets),
    Ack2 = ack_for(Synack2, #tcp_opts{}),
    Expand2 = fun(Now) -> element(1, erx_tcp_syncache:expand(?V4, Ack2, ?LISTENER, ctx(Now, Secrets), Negative)) end,
    ?assertMatch({ok, _}, Expand2(14999)),
    ?assertEqual(reset, Expand2(15000)).

conn(Port) -> {<<10, 0, 0, 1>>, 80, <<192, 0, 2, 7>>, Port}.

%% SYNs from ports Ports, each at Now, into Cache; every one must draw one SYN-ACK.
add_all(Ports, Now, Cache) ->
    lists:foldl(fun(Port, C0) ->
                        Conn = conn(Port),
                        {C1, [{send, Conn, #tcp{}, _}]} =
                            erx_tcp_syncache:add(Conn, syn(Conn, #tcp_opts{}), ?LISTENER, ctx(Now), C0),
                        C1
                end, Cache, Ports).

%% Property 5: the table never exceeds its bound, and a SYN that finds it full gets a
%% SYN-ACK, makes no entry and pauses the table: every entry, the oldest FreeBSD would drop
%% among them, is dropped and none is retransmitted, and the SYNs of the next 15 s make no
%% entries. The dropped entries' handshakes still complete by their cookies.
bound_test() ->
    Full = add_all(lists:seq(1000, 1003), 0, erx_tcp_syncache:new(4)),
    ?assertEqual(4, erx_tcp_syncache:size(Full)),
    ?assertNot(erx_tcp_syncache:cookies_only(0, Full)),
    %% The oldest entry's SYN-ACK, the same cookie whichever table answered it.
    {_, [Synack]} = erx_tcp_syncache:add(conn(1000), syn(conn(1000), #tcp_opts{}), ?LISTENER,
                                         ctx(0), erx_tcp_syncache:new()),
    Paused = add_all([1004], 500, Full),
    ?assertEqual(0, erx_tcp_syncache:size(Paused)),
    ?assert(erx_tcp_syncache:cookies_only(500, Paused)),
    ?assertEqual({Paused, []}, erx_tcp_syncache:expired(1000, Paused)),
    ?assertEqual(infinity, erx_tcp_syncache:next_deadline(Paused)),
    ?assertMatch({{ok, _}, _, []},
                 erx_tcp_syncache:expand(conn(1000), ack_for(Synack, #tcp_opts{}), ?LISTENER, ctx(900),
                                         Paused)),
    ?assertEqual(0, erx_tcp_syncache:size(add_all(lists:seq(1005, 1009), 14999, Paused))).

%% syncache_pause and syncache_unpause: the first pause lasts 15 s and ends when uptime
%% reaches its end (pause_until - time_uptime no longer positive), so 14.999 s is paused and
%% 15 s is not. A pause that starts less than the last pause's own length after it ended
%% doubles, at most six times, to 960 s; one that starts exactly that long after starts again
%% at 15 s. While paused, an ACK matching no entry is checked as a cookie even when the
%% overflow was more than 15 s ago.
pause_test() ->
    Overflow = fun(Now, C) -> add_all([2000], Now, C) end,
    P0 = Overflow(0, erx_tcp_syncache:new(0)),
    ?assert(erx_tcp_syncache:cookies_only(14999, P0)),
    ?assertNot(erx_tcp_syncache:cookies_only(15000, P0)),
    %% A paused table makes no entry until the pause ends.
    Refilled = Overflow(0, add_all([3000], 0, erx_tcp_syncache:new(1))),
    ?assertEqual(0, erx_tcp_syncache:size(add_all([3001], 14999, Refilled))),
    ?assertEqual(1, erx_tcp_syncache:size(add_all([3001], 15000, Refilled))),
    %% 20 s is within 15 s of the first pause's end: 30 s, to 50 s.
    P1 = Overflow(20000, P0),
    ?assert(erx_tcp_syncache:cookies_only(49999, P1)),
    ?assertNot(erx_tcp_syncache:cookies_only(50000, P1)),
    %% At 36 s the overflow at 20 s is past its 15 s window: a cookie is checked only while
    %% the 30 s pause holds, not after the 15 s pause of a table that overflowed once.
    {Once, Synack} = cookie_synack(?V4, full_opts(), 20000, secrets()),
    Ack = ack_for(Synack, #tcp_opts{}),
    ?assertMatch({{ok, _}, _, []}, erx_tcp_syncache:expand(?V4, Ack, ?LISTENER, ctx(36000), P1)),
    ?assertEqual(reset, element(1, erx_tcp_syncache:expand(?V4, Ack, ?LISTENER, ctx(36000), Once))),
    %% 79 s is within 30 s of 50 s, so 60 s; 80 s is not, so 15 s.
    ?assert(erx_tcp_syncache:cookies_only(138999, Overflow(79000, P1))),
    ?assertNot(erx_tcp_syncache:cookies_only(139000, Overflow(79000, P1))),
    ?assert(erx_tcp_syncache:cookies_only(94999, Overflow(80000, P1))),
    ?assertNot(erx_tcp_syncache:cookies_only(95000, Overflow(80000, P1))),
    %% Each pause renewed at once at the end of the last: 15, 30, ..., 960, 960 s.
    {_, Lengths} = lists:foldl(
                     fun(_, {{C, Start}, Acc}) ->
                             C1 = Overflow(Start, C),
                             Len = pause_length(Start, C1),
                             {{C1, Start + Len}, [Len div 1000 | Acc]}
                     end, {{erx_tcp_syncache:new(0), 0}, []}, lists:seq(1, 9)),
    ?assertEqual([15, 30, 60, 120, 240, 480, 960, 960, 960], lists:reverse(Lengths)).

%% The milliseconds from Start, a whole second, to the end of the pause in force at Start.
pause_length(Start, Cache) ->
    pause_length(Start, Start, Cache).
pause_length(Start, Now, Cache) ->
    case erx_tcp_syncache:cookies_only(Now, Cache) of
        true -> pause_length(Start, Now + 1000, Cache);
        false -> Now - Start
    end.

%% syncache_timeout and syncache_timer: retransmissions at 1, 3.2 and 7.4 s, the entry
%% dropped at 15.6 s; ECE on the SYN-ACK and its first retransmission only.
retransmit_test() ->
    Ecn = ?TH_SYN bor ?TH_ECE bor ?TH_CWR,
    {C0, [{send, _, #tcp{flags = F0}, _}]} =
        erx_tcp_syncache:add(?V4, syn(?V4, full_opts(), Ecn), ?LISTENER, ctx(0), erx_tcp_syncache:new()),
    ?assertEqual(?TH_SYN bor ?TH_ACK bor ?TH_ECE, F0),
    Step = fun(Expected, {Cache, Log}) ->
                   Due = erx_tcp_syncache:next_deadline(Cache),
                   ?assertEqual(Expected, Due),
                   {Cache1, Actions} = erx_tcp_syncache:expired(Due, Cache),
                   {Cache1, Log ++ [{Due, Flags band ?TH_ECE =/= 0} || {send, _, #tcp{flags = Flags}, _} <- Actions]}
           end,
    {Last, Log} = lists:foldl(Step, {C0, []}, [1000, 3200, 7400, 15600]),
    ?assertEqual([{1000, true}, {3200, false}, {7400, false}], Log),
    ?assertEqual(0, erx_tcp_syncache:size(Last)),
    ?assertEqual(infinity, erx_tcp_syncache:next_deadline(Last)).

%% A repeated SYN restarts the schedule and may withdraw ECN, never grant it.
repeated_syn_test() ->
    Ecn = ?TH_SYN bor ?TH_ECE bor ?TH_CWR,
    Flags = fun({_, [{send, _, #tcp{flags = F}, _}]}) -> F band ?TH_ECE end,
    {WithEcn, _} = erx_tcp_syncache:add(?V4, syn(?V4, #tcp_opts{}, Ecn), ?LISTENER, ctx(0), erx_tcp_syncache:new()),
    Withdrawn = erx_tcp_syncache:add(?V4, syn(?V4, #tcp_opts{}), ?LISTENER, ctx(500), WithEcn),
    ?assertEqual(0, Flags(Withdrawn)),
    ?assertEqual(1500, erx_tcp_syncache:next_deadline(element(1, Withdrawn))),
    ?assertEqual(0, Flags(erx_tcp_syncache:add(?V4, syn(?V4, #tcp_opts{}, Ecn), ?LISTENER, ctx(600),
                                               element(1, Withdrawn)))).

%% A signed SYN draws nothing; a signed ACK is dropped and the entry kept.
signature_test() ->
    Signed = #tcp_opts{signature = true},
    ?assertMatch({_, []}, erx_tcp_syncache:add(?V4, syn(?V4, Signed), ?LISTENER, ctx(0), erx_tcp_syncache:new())),
    {Cache, [Synack]} = erx_tcp_syncache:add(?V4, syn(?V4, #tcp_opts{}), ?LISTENER, ctx(0), erx_tcp_syncache:new()),
    ?assertEqual({drop, Cache, []}, erx_tcp_syncache:expand(?V4, ack_for(Synack, Signed), ?LISTENER, ctx(0), Cache)),
    {Cookies, Synack2} = cookie_synack(?V4, #tcp_opts{}, 0, secrets()),
    ?assertMatch({drop, _, []}, erx_tcp_syncache:expand(?V4, ack_for(Synack2, Signed), ?LISTENER, ctx(0), Cookies)).

%% syncache_expand with an entry: the handshake it yields, PAWS, the sequence window with
%% its rate-limited challenge ACK, and a wrong acknowledgement answered with a RST.
expand_entry_test() ->
    {Cache, [Synack]} = erx_tcp_syncache:add(?V4, syn(?V4, full_opts()), ?LISTENER, ctx(0), erx_tcp_syncache:new()),
    %% The MSS option is left for the sender to fill in from its path (action()).
    {send, _, #tcp{seq = Iss, opts = #tcp_opts{mss = none, ts = {TsVal, 1000}}}, Label} = Synack,
    TsOffset = erx_tcp_isn:ts_offset(?ISN_SECRETS, ?V4),
    ?assertEqual(erx_tcp_seq:wire(TsOffset), TsVal),
    ?assertEqual(Iss band 16#fffff, Label),
    Good = ack_for(Synack, #tcp_opts{ts = {1001, TsVal}}),
    {{ok, H}, Done, []} = erx_tcp_syncache:expand(?V4, Good, ?LISTENER, ctx(10), Cache),
    ?assertEqual(#{iss => Iss, irs => ?IRS, rcv_wnd => 65535, peer_mss => 1460, wscale => {7, 3},
                   sack => true, ts => {1000, TsOffset}, ecn => false,
                   rxmits => 1, challenge => none}, H),
    ?assertEqual(0, erx_tcp_syncache:size(Done)),
    ?assertMatch({drop, _, []}, erx_tcp_syncache:expand(?V4, Good#tcp{opts = #tcp_opts{ts = {999, 0}}},
                                                       ?LISTENER, ctx(10), Cache)),
    ?assertMatch({reset, _, []}, erx_tcp_syncache:expand(?V4, Good#tcp{ack = Iss}, ?LISTENER, ctx(10), Cache)),
    Stale = Good#tcp{seq = ?IRS},
    %% Seven in one second: five challenge ACKs, then two charges of the RST limit alone,
    %% and a new second allows another.
    Challenge = fun(_, {C, Log}) ->
                        {drop, C1, [Action]} = erx_tcp_syncache:expand(?V4, Stale, ?LISTENER, ctx(10), C),
                        {C1, Log ++ [case Action of charge_rst -> charge_rst; _ -> element(1, Action) end]}
                end,
    {Limited, Log} = lists:foldl(Challenge, {Cache, []}, lists:seq(1, 7)),
    ?assertEqual(lists:duplicate(5, challenge_ack) ++ [charge_rst, charge_rst], Log),
    ?assertMatch({drop, _, [{challenge_ack, _, #tcp{flags = ?TH_ACK}, _}]},
                 erx_tcp_syncache:expand(?V4, Stale, ?LISTENER, ctx(1011), Limited)).

%% syncache_chkrst: a RST at exactly IRS + 1 drops the entry, one elsewhere in the window
%% draws a challenge ACK, one outside it is ignored.
chkrst_test() ->
    {Cache, [_]} = erx_tcp_syncache:add(?V4, syn(?V4, #tcp_opts{}), ?LISTENER, ctx(0), erx_tcp_syncache:new()),
    Rst = fun(Seq) -> erx_tcp_syncache:chkrst(?V4, #tcp{seq = Seq, flags = ?TH_RST}, 0, Cache) end,
    {Dropped, []} = Rst(erx_tcp_seq:wire(?IRS + 1)),
    ?assertEqual(0, erx_tcp_syncache:size(Dropped)),
    ?assertMatch({_, [{challenge_ack, _, _, _}]}, Rst(erx_tcp_seq:wire(?IRS + 100))),
    ?assertEqual({Cache, []}, Rst(erx_tcp_seq:wire(?IRS + 1 + 65535))).

%% syncache_unreach: an error quoting another sequence number is ignored, the first one
%% only marks the entry, and a second one drops it only after three retransmissions.
unreach_test() ->
    {C0, [{send, _, #tcp{seq = Iss}, _}]} =
        erx_tcp_syncache:add(?V4, syn(?V4, #tcp_opts{}), ?LISTENER, ctx(0), erx_tcp_syncache:new()),
    Marked = erx_tcp_syncache:unreach(?V4, Iss, erx_tcp_syncache:unreach(?V4, Iss bxor 1, C0)),
    ?assertEqual(1, erx_tcp_syncache:size(erx_tcp_syncache:unreach(?V4, Iss, Marked))),
    Late = lists:foldl(fun(Now, C) -> element(1, erx_tcp_syncache:expired(Now, C)) end, Marked,
                       [1000, 3200, 7400]),
    Dropped = erx_tcp_syncache:unreach(?V4, Iss, Late),
    ?assertEqual(0, erx_tcp_syncache:size(Dropped)),
    ?assertEqual(infinity, erx_tcp_syncache:next_deadline(Dropped)).

%% Printing the secrets, as a crash report would, shows no key.
secrets_hidden_test() ->
    Printed = lists:flatten(io_lib:format("~p", [secrets()])),
    ?assertEqual(nomatch, string:find(Printed, "<<")).

%% tcp_input.c:1295-1338: a SYN to or from itself, from or to a multicast address or from
%% the limited broadcast draws nothing and makes no entry.
address_checks_test_() ->
    Add = fun(Conn) ->
                  {Cache, Actions} = erx_tcp_syncache:add(Conn, syn(Conn, #tcp_opts{}), ?LISTENER,
                                                          ctx(0), erx_tcp_syncache:new()),
                  {erx_tcp_syncache:size(Cache), length(Actions)}
          end,
    Lo = <<127, 0, 0, 1>>,
    V6 = <<16#20010db8:32, 0:64, 1:32>>,
    [?_assertEqual({1, 1}, Add(?V4)),
     ?_assertEqual({1, 1}, Add({Lo, 80, Lo, 81})),
     ?_assertEqual({0, 0}, Add({Lo, 80, Lo, 80})),
     ?_assertEqual({0, 0}, Add({V6, 443, V6, 443})),
     ?_assertEqual({0, 0}, Add({<<224, 0, 0, 1>>, 80, <<192, 0, 2, 7>>, 49152})),
     ?_assertEqual({0, 0}, Add({<<10, 0, 0, 1>>, 80, <<224, 0, 0, 9>>, 49152})),
     ?_assertEqual({0, 0}, Add({<<10, 0, 0, 1>>, 80, <<255, 255, 255, 255>>, 49152})),
     ?_assertEqual({0, 0}, Add({V6, 443, <<16#ff02:16, 0:96, 1:16>>, 50000}))].
