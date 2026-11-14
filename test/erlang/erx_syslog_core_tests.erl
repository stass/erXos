%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The EUnit cases of erx_syslog_core (docs/design-log.md, "Verification and
%% testing"): the line's head, the escape of a record's name and text over
%% every class of test/fixtures/line_escape_vectors.json (whose path
%% ERX_TEXT_VECTORS names), the rate's charge of each line as stored, and
%% the rate table across a thousand incarnations of one domain, with a
%% stand-in clock.
-module(erx_syslog_core_tests).

-include_lib("eunit/include/eunit.hrl").

-define(S, 1000000000).
-define(MS, 1000000).
%% The design's rate: 16 KiB of stored lines per domain and second.
-define(RATE, 16384).
%% A write carries at most log_write_max records.
-define(WRITE_MAX, 16).

web() ->
    #{id => 7, principal => 3, name => <<"web">>}.

system() ->
    #{id => 0, principal => unknown, name => <<"system">>}.

vectors() ->
    {ok, Json} = file:read_file(os:getenv("ERX_TEXT_VECTORS")),
    #{<<"vectors">> := Vectors} = json:decode(Json),
    [{Class, binary:decode_hex(Input), Line}
     || #{<<"class">> := Class, <<"input">> := Input, <<"line">> := Line}
            <- Vectors].

%% Count records of Text from Source at Now, sent as writes of at most
%% WRITE_MAX records each: the lines kept, in order, and the next table.
flood(Now, Source, Count, Text, Table) ->
    Batches = batches(lists:duplicate(Count, {info, Text})),
    lists:foldl(
      fun(Batch, {Kept, Table0}) ->
              {Lines, Table1} = erx_syslog_core:write(Now, Source, Batch, Table0),
              {Kept ++ Lines, Table1}
      end, {[], Table}, Batches).

batches([]) ->
    [];
batches(Records) when length(Records) =< ?WRITE_MAX ->
    [Records];
batches(Records) ->
    {Batch, Rest} = lists:split(?WRITE_MAX, Records),
    [Batch | batches(Rest)].

%% The bytes the store keeps for Lines, each ended in LF.
stored(Lines) ->
    lists:sum([byte_size(Line) + 1 || Line <- Lines]).

%% The system domain's drops line for Domain at the whole second Second.
dropped_line(Second, Domain, Count) ->
    iolist_to_binary(
      [integer_to_binary(Second),
       <<".000000 notice domain 0 principal unknown system: ">>,
       <<"erx_syslog: domain ">>, integer_to_binary(Domain), <<": ">>,
       integer_to_binary(Count), <<" records dropped">>]).

%%% The line

line_head_is_the_services_test() ->
    ?assertEqual(
       <<"1234.000567 warning domain 7 principal 3 web: hello">>,
       erx_syslog_core:line(1234 * ?S + 567890, 7, 3, <<"web">>,
                            {warning, <<"hello">>})),
    ?assertEqual(
       <<"0.000000 info domain 0 principal unknown system: up">>,
       erx_syslog_core:line(0, 0, unknown, <<"system">>, {info, <<"up">>})).

%% Each class as a domain's name and as its text: both read as the line
%% escape writes them, and the line holds nothing the escape would change.
line_escapes_name_and_text_test() ->
    Head = <<"1.000000 info domain 1 principal 0 ">>,
    [begin
         Line = erx_syslog_core:line(?S, 1, 0, Input, {info, Input}),
         ?assertEqual({Class, <<Head/binary, Escaped/binary, ": ",
                                Escaped/binary>>},
                      {Class, Line}),
         ?assertEqual({Class, Line}, {Class, erx_text:escape_line(Line)})
     end || {Class, Input, Escaped} <- vectors()].

%%% The rate

%% Twice the rate and more of empty records in one second: the lines kept
%% come to at most 16 KiB as stored, the next one would not have fitted, and
%% the turn counts every record not kept.
empty_records_are_charged_their_whole_line_test() ->
    charged_as_stored(<<>>).

%% Text that the escape lengthens eightfold is charged as escaped.
lengthened_text_is_charged_as_escaped_test() ->
    charged_as_stored(binary:copy(<<"\t">>, 100)).

%% A thousand records are past twice the rate for either text.
charged_as_stored(Text) ->
    Count = 1000,
    {Kept, Table} = flood(?S, web(), Count, Text, erx_syslog_core:new(?S)),
    [Line | _] = Kept,
    ?assert(stored(Kept) =< ?RATE),
    ?assert(stored(Kept) + byte_size(Line) + 1 > ?RATE),
    ?assertEqual({[dropped_line(2, 7, Count - length(Kept))],
                  erx_syslog_core:new(2 * ?S)},
                 erx_syslog_core:turn(2 * ?S, system(), Table)).

%% Lines that fill the rate to its last byte are all kept: web's head at
%% 1 s is the 40 bytes "1.000000 info domain 7 principal 3 web: ", so a
%% 983-byte text stores 1024 bytes and exactly 16 fit; the 17th is dropped.
the_rate_is_filled_to_its_last_byte_test() ->
    Text = binary:copy(<<"a">>, 983),
    {Kept, Table} = flood(?S, web(), 17, Text, erx_syslog_core:new(?S)),
    ?assertEqual({16, ?RATE}, {length(Kept), stored(Kept)}),
    ?assertMatch({[_], _}, erx_syslog_core:turn(2 * ?S, system(), Table)).

%% Ticks inside the second change nothing: the domain stays past its rate
%% until the second turns, and its drops are counted on one line.
ticks_within_the_second_keep_the_table_test() ->
    {Kept, Flooded} = flood(?S, web(), 1000, <<"x">>, erx_syslog_core:new(?S)),
    ?assertEqual({[], Flooded},
                 erx_syslog_core:turn(?S + 500 * ?MS, system(), Flooded)),
    {Late, Table} = erx_syslog_core:write(?S + 600 * ?MS, web(),
                                          [{info, <<"late">>}], Flooded),
    ?assertEqual([], Late),
    {[Drops], _Empty} = erx_syslog_core:turn(2 * ?S, system(), Table),
    ?assertEqual(dropped_line(2, 7, 1000 - length(Kept) + 1), Drops).

%% Forty domains past their rate, written in descending order of id, are
%% each counted on their own line, in ascending order of id (more than 32,
%% so the map's own order is not the ids'); a domain within its rate has no
%% line; and in the new second a flooding domain writes again.
each_domain_is_counted_apart_test() ->
    Ids = lists:seq(40, 1, -1),
    {Expected, Flooded} =
        lists:foldl(
          fun(Id, {Lines0, Table0}) ->
                  Source = #{id => Id, principal => 1, name => <<"d">>},
                  {Kept, Table1} = flood(?S, Source, 1000, <<"x">>, Table0),
                  {[dropped_line(2, Id, 1000 - length(Kept)) | Lines0],
                   Table1}
          end, {[], erx_syslog_core:new(?S)}, Ids),
    Quiet = #{id => 50, principal => 1, name => <<"quiet">>},
    {[_], Written} = erx_syslog_core:write(?S, Quiet, [{info, <<"one">>}],
                                           Flooded),
    {Lines, Turned} = erx_syslog_core:turn(2 * ?S, system(), Written),
    ?assertEqual(Expected, Lines),
    Again = #{id => 7, principal => 1, name => <<"d">>},
    ?assertMatch({[_], _},
                 erx_syslog_core:write(2 * ?S, Again, [{info, <<"again">>}],
                                       Turned)).

%% A record that is not a level and a binary text is dropped and counted,
%% and the records beside it in the write are kept.
malformed_records_are_dropped_and_counted_test() ->
    Records = [{bogus, <<"x">>}, {info, "a list"}, not_a_pair,
               {info, <<"kept">>}],
    {[Line], Table} = erx_syslog_core:write(?S, web(), Records,
                                            erx_syslog_core:new(?S)),
    ?assertEqual(<<"1.000000 info domain 7 principal 3 web: kept">>, Line),
    ?assertEqual({[dropped_line(2, 7, 3)], erx_syslog_core:new(2 * ?S)},
                 erx_syslog_core:turn(2 * ?S, system(), Table)).

%% The design's rate table test: a thousand incarnations of one domain name,
%% each a new domain id flooding past its rate in its own second and then
%% ending. After each turn the table is as empty as a new one, and each
%% incarnation's drops are one line of their own.
incarnations_leave_nothing_behind_test() ->
    Final = lists:foldl(fun incarnation/2, erx_syslog_core:new(?S),
                        lists:seq(1, 1000)),
    ?assertEqual(erx_syslog_core:new(1001 * ?S), Final).

incarnation(N, Table) ->
    Source = #{id => 100 + N, principal => 2, name => <<"app">>},
    {Kept, Flooded} = flood(N * ?S + ?MS, Source, 500, <<"flood">>, Table),
    {Lines, Turned} = erx_syslog_core:turn((N + 1) * ?S, system(), Flooded),
    ?assertEqual({N, [dropped_line(N + 1, 100 + N, 500 - length(Kept))]},
                 {N, Lines}),
    ?assertEqual({N, erx_syslog_core:new((N + 1) * ?S)}, {N, Turned}),
    Turned.

%% The consumer protocol, exhaustively over each role's states and events
%% (docs/design-log.md, "Consumers and backlogs"): from idle and from waiting on
%% consumer A, with and without a line in the backlog, each of A's own request,
%% another process B's request, a line joining, the store's wait running out, and
%% A's end followed by a line.
consumer_protocol_test_() ->
    [?_test(protocol(Role, State, Backlog, Event))
     || Role <- [console, store], State <- [idle, waiting], Backlog <- [empty, line],
        Event <- [ask_a, ask_b, line, late, end_a]].

a_pid() -> list_to_pid("<0.1.0>").
b_pid() -> list_to_pid("<0.2.0>").

requester(Pid, Tag) -> {{Pid, Tag}, make_ref()}.

%% Consumers with Role in State, its backlog empty or holding one line joined at 0,
%% and A's monitor. A waiting console with a line has been answered at once; at time
%% 0 no store's batch is due.
consumers(Role, State, Backlog) ->
    C0 = erx_syslog_core:consumers(),
    {[], C1} = case Backlog of
                   empty -> {[], C0};
                   line -> erx_syslog_core:lines(0, system(), [{messages, <<"old">>}], C0)
               end,
    case State of
        idle ->
            {C1, make_ref()};
        waiting ->
            {_, Monitor} = A = requester(a_pid(), a),
            {Actions, C2} = erx_syslog_core:ask(Role, A, 0, system(), C1),
            ?assertEqual(case {Role, Backlog} of
                             {console, line} -> [{send, a, 1}];
                             _ -> []
                         end, [shape(Action) || Action <- Actions]),
            {C2, Monitor}
    end.

protocol(Role, State, Backlog, Event) ->
    {C, Monitor} = consumers(Role, State, Backlog),
    Waiting = State =:= waiting andalso not (Role =:= console andalso Backlog =:= line),
    Held = Backlog =:= line andalso not (Role =:= console andalso State =:= waiting),
    {Actions, _Next} =
        case Event of
            ask_a -> erx_syslog_core:ask(Role, requester(a_pid(), a2), 0, system(), C);
            ask_b -> erx_syslog_core:ask(Role, requester(b_pid(), b), 0, system(), C);
            line -> erx_syslog_core:lines(0, system(), [{kernel, <<"new">>}], C);
            late -> erx_syslog_core:due(2 * ?S, system(), C);
            end_a -> erx_syslog_core:lines(0, system(), [{kernel, <<"new">>}],
                                           erx_syslog_core:ended(Monitor, C))
        end,
    ?assertEqual({Role, State, Backlog, Event, expected(Role, Waiting, Held, Event)},
                 {Role, State, Backlog, Event, [shape(Action) || Action <- Actions]}).

%% An action by kind and requester tag, with a batch's line count.
shape({send, {{_, Tag}, _}, Batch}) -> {send, Tag, length(Batch)};
shape({forget, {{_, Tag}, _}}) -> {forget, Tag};
shape({refuse, {{_, Tag}, _}}) -> {refuse, Tag}.

%% The protocol's answers: A's own request replaces its kept one; B's is refused while
%% A's is kept; a waiting console gets a line at once and a waiting store only past
%% its wait; and after A's end nothing is answered.
expected(Role, true, Held, ask_a) -> [{forget, a} | due_now(Role, Held, a2)];
expected(Role, false, Held, ask_a) -> due_now(Role, Held, a2);
expected(_Role, true, _Held, ask_b) -> [{refuse, b}];
expected(Role, false, Held, ask_b) -> due_now(Role, Held, b);
expected(console, true, Held, line) -> [{send, a, count(Held) + 1}];
expected(_Role, _Waiting, _Held, line) -> [];
expected(store, true, true, late) -> [{send, a, 1}];
expected(_Role, _Waiting, _Held, late) -> [];
expected(_Role, _Waiting, _Held, end_a) -> [].

due_now(console, true, Tag) -> [{send, Tag, 1}];
due_now(_Role, _Held, _Tag) -> [].

count(true) -> 1;
count(false) -> 0.
