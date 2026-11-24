%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the session's line to the web domain (erx_web_line over
%% erx_session_line; docs/design-web.md, "Views on the line"; docs/design-system.md,
%% "A session's lines"): the line's mint, its facet's replacement and lifetime, the
%% views opened through the facet, and the bounds of a request and of a view's heap.
%% The export table, the session's connection to the grantee and the opening are the
%% test's stand-ins, and so is the inspector but in the cases of a domain's processes
%% and of the scope, which ask it itself. The test is the domain pid a mint replies to
%% (erx_facet:minted/2).
-module(erx_web_line_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([owner/1, export/3]).

-define(PEER, 5).
-define(SYSTEM, 4).
%% The name the test that watches the stand-in export table registers under.
-define(EXPORTS, erx_web_line_tests_exports).

%% The export table's stand-in: every name is the peer's, or the domain a test has made
%% every name's, unless a test has claimed it for another domain, and anything else no name, as erx_dist:owner/1 refuses it.
owner(Name) when is_pid(Name); is_reference(Name); is_port(Name) ->
    persistent_term:get({?MODULE, owner, Name}, persistent_term:get({?MODULE, owner}, ?PEER)).

%% Every export is taken, and told to the test registered as ?EXPORTS, if any.
export(Name, Rights, Peer) ->
    case whereis(?EXPORTS) of
        undefined -> ok;
        Test -> Test ! {exported, Name, Rights, Peer}
    end,
    ok.

machine(Uptime) ->
    {ok, [First | _]} = erx_schema:attributes(machine),
    {ok, #{schema => 1, path => [], kind => machine, id => <<"m">>,
           attrs => #{First => {kernel, {ok, Uptime}}}, children => [cpus]}}.

%% A process standing for the session's connection to the grantee or for the opening,
%% which lives until it is told to stop.
stand_in() ->
    spawn(fun() -> receive stop -> ok end end).

%% A line whose views read through Inspect, and the stand-in of its connection to any
%% grantee, which Connection answers unless it refuses that grantee.
line(Inspect) ->
    line(Inspect, fun(_Grantee) -> ok end).

line(Inspect, Refuses) ->
    Conn = stand_in(),
    Connection = fun(Grantee) ->
                         case Refuses(Grantee) of
                             ok -> {ok, Conn};
                             Error -> Error
                         end
                 end,
    {ok, Line} = erx_web_line:start_link(#{system => ?SYSTEM, inspect => Inspect, exports => ?MODULE,
                                           connection => Connection}),
    #{line => Line, conn => Conn}.

%% The mint request for Grantee within Opening's life, in Domain's envelope, and the
%% line's reply, or none.
mint(Line, Domain, Grantee, Opening) ->
    mint(Line, Domain, web_line, Grantee, Opening).

mint(Line, Domain, Name, Grantee, Opening) ->
    persistent_term:put({erx, domain_pid}, self()),
    Tag = erlang:unique_integer([positive]),
    Limits = (maps:get(web_line, ?ERX_LINES))#{opening => Opening},
    Line ! {erx_origin, Domain, {erx_facet_mint, Tag, Name, Grantee, <<"root">>, Limits}},
    receive {erx_facet_minted, Tag, Reply} -> Reply after 500 -> none end.

%% A line with its facet minted for the peer, as the host's opening of its `web` facet
%% does.
open_line(Inspect) ->
    #{line := Line} = Opened = line(Inspect),
    Opening = stand_in(),
    {ok, Facet} = mint(Line, ?SYSTEM, ?PEER, Opening),
    Opened#{facet => Facet, opening => Opening}.

%% Request in Domain's envelope as a call, and the answer, or none.
call(Facet, Request) ->
    call(Facet, ?PEER, Request).

call(Facet, Domain, Request) ->
    Alias = alias([reply]),
    Facet ! {erx_origin, Domain, {'$gen_call', {self(), [alias | Alias]}, Request}},
    receive {[alias | Alias], Reply} -> Reply after 500 -> unalias(Alias), none end.

%% The next message of View's.
update(View) ->
    receive
        {web_view, View, Body} -> Body;
        {web_view_ended, View, Reason} -> {ended, Reason}
    after 5000 -> error(no_update)
    end.

nothing_sent(View) ->
    receive {web_view, View, _} = M -> error({sent, M}) after 200 -> ok end.

ended(Pid) ->
    Watch = erlang:monitor(process, Pid),
    receive {'DOWN', Watch, process, Pid, Reason} -> {ended, Reason} after 5000 -> lives end.

%%% Views.

%% An open through the facet is answered with a view whose first update carries the
%% machine's record; a `next` while the record is unchanged is not answered; the view
%% takes `stop` in the grantee's envelope alone.
open_machine_record_test() ->
    #{facet := Facet} = open_line(fun([]) -> machine(7) end),
    {ok, View} = call(Facet, {open, {path, []}}),
    ?assertMatch({record, #{path := [], kind := <<"machine">>, id := {text, <<"m">>},
                            attrs := [{_, kernel, ok, {int, <<"7">>}}],
                            children := {complete, [{text, <<"cpus">>}]}}},
                 update(View)),
    View ! {erx_origin, ?PEER, next},
    nothing_sent(View),
    Watch = erlang:monitor(process, View),
    View ! stop,
    View ! {erx_origin, ?PEER + 1, stop},
    receive {'DOWN', Watch, _, _, _} -> error(stopped_by_another) after 200 -> ok end,
    View ! {erx_origin, ?PEER, stop},
    receive {'DOWN', Watch, process, View, normal} -> ok after 5000 -> error(view_lives) end.

%% A view the inspector refuses ends with the inspector's reason, one whose query got
%% no answer ends `failed`, names that name nothing are `scope`, a target the line does
%% not serve is unsupported, and a request of no operation is badarg.
refused_views_end_test() ->
    #{facet := Facet} = open_line(fun([]) -> {error, scope} end),
    {ok, View} = call(Facet, {open, {path, []}}),
    ?assertEqual({ended, scope}, update(View)),
    ?assertEqual({error, scope}, call(Facet, {open, {path, [<<"nothing">>]}})),
    ?assertEqual({error, unsupported}, call(Facet, {open, uis})),
    [?assertEqual({error, badarg}, call(Facet, Request)) || Request <- [nonsense, {open}, {next, View}]],
    #{facet := Busy} = open_line(fun([]) -> {error, busy} end),
    {ok, Failed} = call(Busy, {open, {path, []}}),
    ?assertEqual({ended, failed}, update(Failed)).

%% The session's processes through the inspector itself at the session's scope: the
%% processes of the domain the runtime is, on a development host the system domain
%% (erx_inspector:runtime_domain/0). With 1,000 idle processes beside the test's own
%% the listing holds one partial page within one update, and the view holding that
%% page stays within its heap limit.
session_processes_test() ->
    Idle = [spawn(fun() -> receive stop -> ok end end) || _ <- lists:seq(1, 1000)],
    try
        #{facet := Facet} = open_line(as_facet([?SYSTEM])),
        {ok, View} = call(Facet, {open, {path, [<<"processes">>]}}),
        {record, #{path := WirePath, kind := Kind, id := Id, attrs := Attrs,
                   children := {Completeness, Children}}} = update(View),
        ?assertEqual([{text, <<"processes">>}], WirePath),
        ?assertEqual({{atom, <<"processes">>}, []}, {Id, Attrs}),
        ?assertEqual(<<"listing">>, Kind),
        ?assertEqual(partial, Completeness),
        ?assert(length(Children) >= 1 andalso length(Children) =< 1000),
        true = erlang:garbage_collect(View),
        ?assert(is_process_alive(View))
    after
        [Pid ! stop || Pid <- Idle]
    end.

%% The inspector at Scope, answering in a process of its own as the session's inspect
%% facet's query worker does, so the view holds the answer and not the query's work.
as_facet(Scope) ->
    fun(Path) ->
            {Worker, Watch} = spawn_monitor(fun() -> exit({answer, erx_inspector:inspect(Path, Scope, #{})}) end),
            receive {'DOWN', Watch, process, Worker, {answer, Answer}} -> Answer end
    end.

%% A process opened by the name its listing gives it is answered with its record.
listed_process_test() ->
    #{facet := Facet} = open_line(as_facet([?SYSTEM])),
    Name = erx_procfs_core:name(erx_inspector:proc_id(self())),
    {ok, View} = call(Facet, {open, {path, [<<"processes">>, Name]}}),
    ?assertMatch({record, #{path := [{text, <<"processes">>}, {text, Name}], kind := <<"process">>}}, update(View)).

%% A path outside the session's scope ends the view `scope`, as /proc answers enoent;
%% names that name nothing, or are not names, are answered as such a path.
scope_test() ->
    #{line := Line, facet := Facet} = open_line(as_facet([?SYSTEM + 5])),
    Ended = fun(Names) ->
                    {ok, View} = call(Facet, {open, {path, Names}}),
                    update(View)
            end,
    ?assertEqual({ended, scope}, Ended([<<"processes">>, erx_procfs_core:name(erx_inspector:proc_id(self()))])),
    ?assertEqual({ended, scope}, Ended([<<"domains">>, <<"4">>])),
    ?assertEqual({ended, scope}, Ended([<<"kernel">>])),
    [?assertEqual({error, scope}, call(Facet, {open, {path, Names}}))
     || Names <- [[<<"nothing">>], [<<"domains">>, <<"4">>, <<"..">>], [<<"domains/4">>], [<<>>],
                  [<<"domains">> | <<"4">>], [domains], [<<"processes">>, <<"0.1.0">>, <<"x">>]]],
    ?assert(is_process_alive(Line)).

%% A line holds at most 64 views; past them an open is busy until one ends.
bound_test() ->
    #{line := Line, facet := Facet} = open_line(fun([]) -> machine(1) end),
    Views = [begin {ok, V} = call(Facet, {open, {path, []}}), V end || _ <- lists:seq(1, 64)],
    ?assertEqual({error, busy}, call(Facet, {open, {path, []}})),
    hd(Views) ! {erx_origin, ?PEER, stop},
    wait_views(Line, 63),
    ?assertMatch({ok, _}, call(Facet, {open, {path, []}})).

%% A call from a third domain, or whose caller is a third domain's, is answered
%% nowhere and opens no view.
third_domain_test() ->
    #{line := Line, facet := Facet} = open_line(fun([]) -> machine(1) end),
    ?assertEqual(none, call(Facet, ?PEER + 1, {open, {path, []}})),
    Caller = spawn(fun() -> receive _ -> ok end end),
    persistent_term:put({?MODULE, owner, Caller}, ?PEER + 1),
    try
        Alias = alias([reply]),
        Facet ! {erx_origin, ?PEER, {'$gen_call', {Caller, [alias | Alias]}, {open, {path, []}}}},
        receive {[alias | Alias], Answered} -> error({answered, Answered}) after 200 -> ok end,
        ?assertEqual([], views(Line))
    after
        persistent_term:erase({?MODULE, owner, Caller})
    end.

%% A flood of messages from the grantee that the view leaves unread ends that view
%% alone at its heap limit: its queue is on its heap, and the binaries it references
%% count toward the limit.
view_heap_test() ->
    #{line := Line, facet := Facet} = open_line(fun([]) -> receive never -> ok end end),
    {ok, Flooded} = call(Facet, {open, {path, []}}),
    {ok, Other} = call(Facet, {open, {path, []}}),
    Watch = erlang:monitor(process, Flooded),
    Chunk = 65536,
    [Flooded ! {erx_origin, ?PEER, {junk, binary:copy(<<N:8>>, Chunk)}}
     || N <- lists:seq(1, 2 * ?ERX_WEB_LINE_VIEW_HEAP_MAX * erlang:system_info(wordsize) div Chunk)],
    %% The first collection takes the queued messages onto the heap, and the next finds
    %% the heap past its limit.
    [erlang:garbage_collect(Flooded) || _ <- [first, next]],
    ?assertEqual(killed, receive {'DOWN', Watch, process, Flooded, Reason} -> Reason after 5000 -> lives end),
    ?assert(is_process_alive(Other)),
    ?assert(is_process_alive(Line)).

%%% The mint.

%% The mint request in the system domain's envelope starts a facet bound to the
%% grantee and exported to it with send alone; the same request in the grantee's
%% envelope, naming the system domain as grantee, or naming another line starts none,
%% and a call to the line process itself in the grantee's envelope reaches no callback.
mint_test() ->
    register(?EXPORTS, self()),
    try
        #{line := Line} = line(fun([]) -> machine(1) end),
        Opening = stand_in(),
        ?assertEqual(none, mint(Line, ?PEER, ?PEER, Opening)),
        ?assertEqual(none, mint(Line, ?SYSTEM, ?SYSTEM, Opening)),
        ?assertEqual(none, mint(Line, ?SYSTEM, tty_line, ?PEER, Opening)),
        receive {exported, _, _, _} = Early -> error(Early) after 0 -> ok end,
        ?assertEqual(none, call(Line, {open, {path, []}})),
        {ok, Facet} = mint(Line, ?SYSTEM, ?PEER, Opening),
        receive {exported, Facet, [send], ?PEER} -> ok after 0 -> error(not_exported) end,
        ?assertEqual(?PEER, maps:get(grantee, erx_facet:info(Facet))),
        ?assertEqual(none, call(Line, {open, {path, []}})),
        ?assertEqual([], views(Line)),
        ?assertMatch({ok, _}, call(Facet, {open, {path, []}}))
    after
        unregister(?EXPORTS)
    end.

%% A second mint ends the first facet, and takes its 'DOWN', before the new facet is
%% exported; the first facet's views end and the old grantee reaches the new facet
%% nowhere. A forward the old facet sent before its end is served at the line, and the
%% view it opens ends with that facet.
replacement_test() ->
    register(?EXPORTS, self()),
    try
        #{line := Line, facet := Old} = open_line(fun([]) -> machine(1) end),
        receive {exported, Old, _, _} -> ok after 0 -> ok end,
        {ok, OldView} = call(Old, {open, {path, []}}),
        Opening = stand_in(),
        Watch = erlang:monitor(process, OldView),
        {ok, New} = mint(Line, ?SYSTEM, ?PEER + 1, Opening),
        receive
            {exported, New, [send], ?PEER + 1} -> ?assertNot(is_process_alive(Old))
        after 0 -> error(not_exported)
        end,
        receive {'DOWN', Watch, process, OldView, _} -> ok after 2000 -> error(old_view_lives) end,
        ?assertEqual(none, call(Old, {open, {path, []}})),
        ?assertEqual(none, call(New, ?PEER, {open, {path, []}})),
        persistent_term:put({?MODULE, owner}, ?PEER + 1),
        ?assertMatch({ok, _}, call(New, ?PEER + 1, {open, {path, []}})),
        persistent_term:erase({?MODULE, owner}),
        Alias = alias([reply]),
        Line ! {'$gen_call', {Old, [alias | Alias]}, {erx_session_line, ?PEER, self(), Old, {open, {path, []}}}},
        Late = receive {[alias | Alias], {ok, V}} -> V after 5000 -> error(late_forward_unserved) end,
        ?assertMatch({ended, _}, ended(Late))
    after
        unregister(?EXPORTS)
    end.

%% A new facet that fails to start leaves the line with none, the old one having
%% ended, and the mint answers a refusal.
failed_start_test() ->
    #{line := Line} = line(fun([]) -> machine(1) end,
                           fun(?PEER) -> ok; (_) -> {error, noconnection} end),
    Opening = stand_in(),
    {ok, Old} = mint(Line, ?SYSTEM, ?PEER, Opening),
    ?assertEqual(refused, mint(Line, ?SYSTEM, ?PEER + 1, Opening)),
    ?assertNot(is_process_alive(Old)),
    ?assertEqual(none, call(Old, {open, {path, []}})).

%% The facet, and every view opened through it, ends with the session's connection to
%% the grantee, with the opening and with the line process.
lifetime_test_() ->
    [?_test(lifetime(fun(#{conn := Conn}) -> Conn ! stop end)),
     ?_test(lifetime(fun(#{opening := Opening}) -> Opening ! stop end)),
     ?_test(lifetime(fun(#{line := Line}) -> unlink(Line), exit(Line, kill) end))].

lifetime(End) ->
    #{facet := Facet} = Opened = open_line(fun([]) -> machine(1) end),
    {ok, View} = call(Facet, {open, {path, []}}),
    {record, _} = update(View),
    Watches = [{Pid, erlang:monitor(process, Pid)} || Pid <- [Facet, View]],
    End(Opened),
    [receive {'DOWN', Watch, process, Pid, _} -> ok after 2000 -> error({lives, Pid}) end || {Pid, Watch} <- Watches].

%%% A request's bound.

%% The largest request the line serves, an open of a path of 16 segments of 256 bytes
%% from a caller whose pid and alias are of a 255-character node name, fits web_line's
%% max_request under both measures, and that bound is the smallest power of two not
%% below the larger of them; through the facet such a request is admitted.
request_bound_test() ->
    Path = [binary:copy(<<"p">>, 256) || _ <- lists:seq(1, 16)],
    Measure = erx_line_bound:measure({open, {path, Path}}),
    Max = maps:get(max_request, maps:get(web_line, ?ERX_LINES)),
    ?assert(Measure =< Max andalso Measure > Max div 2),
    #{facet := Facet} = open_line(fun(_) -> {error, scope} end),
    ?assertEqual({error, scope}, call(Facet, {open, {path, Path}})).

views(Line) ->
    {links, Links} = erlang:process_info(Line, links),
    [Pid || Pid <- Links, Pid =/= self()].

wait_views(Line, N) ->
    case length(views(Line)) of
        N -> ok;
        _ -> timer:sleep(10), wait_views(Line, N)
    end.
