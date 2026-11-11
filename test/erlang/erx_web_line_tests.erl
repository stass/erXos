%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the session's line to the web domain (erx_web_line;
%% docs/design-web.md, "Views on the line"), and of the path from a browser's
%% decoded `open {path, []}` through the web domain's relay connection and the line
%% to an update carrying the machine's record. The inspector is a stand-in that
%% answers a machine record of the schema; the test is each connection's sink.
-module(erx_web_line_tests).

-include_lib("eunit/include/eunit.hrl").

-export([owner/1, export/3]).

-define(PEER, 5).
-define(SYSTEM, 4).
%% The name the test that watches the stand-in export table registers under.
-define(EXPORTS, erx_web_line_tests_exports).
-define(BUILD, <<"00000000000000ff">>).

%% The export table's stand-in: every name is the peer's unless a test has claimed it for
%% another domain, and anything else no name, as erx_dist:owner/1 refuses it.
owner(Name) when is_pid(Name); is_reference(Name); is_port(Name) ->
    persistent_term:get({?MODULE, owner, Name}, ?PEER).

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

line(Inspect) ->
    {ok, Line} = erx_web_line:start_link(#{peer => ?PEER, system => ?SYSTEM, inspect => Inspect,
                                           exports => ?MODULE}),
    Line.

%% A line already serving its peer whose views read through the inspector itself at
%% Scope.
line_at(Scope) ->
    {ok, Line} = erx_web_line:start_link(#{peer => ?PEER, system => ?SYSTEM, scope => Scope,
                                           exports => ?MODULE}),
    Line.

data(Relay, C, Message) ->
    {ok, Bytes} = erx_web_proto:encode(browser, Message),
    gen_server:call(Relay, {data, self(), C, Bytes}).

sent(C) ->
    receive
        {web, C, Bytes} -> {ok, Message} = erx_web_proto:decode(machine, Bytes), Message
    after 5000 -> error(nothing_sent)
    end.

nothing_sent() ->
    receive {web, _, _} = M -> error({sent, M}) after 200 -> ok end.

%% A browser's open of the machine's path, through the relay's connection and the
%% line, is answered with one update carrying the machine's record; a `next` while
%% the record is unchanged is not answered, and the browser's close ends the view.
open_machine_record_test() ->
    Line = line(fun([], _Scope) -> machine(7) end),
    {ok, Relay} = erx_web_relay:start_link(#{system => 4}),
    ?assertEqual(ok, gen_server:call(Relay, {connect, self(), 1, #{principal => <<"root">>, build => ?BUILD,
                                                                   line => Line}})),
    ?assertEqual(ok, data(Relay, 1, {hello, erx_web_proto:hash()})),
    ?assertEqual({welcome, <<"root">>, ?BUILD}, sent(1)),
    ?assertEqual(ok, data(Relay, 1, {open, 1, {path, []}})),
    ?assertMatch({update, 1, {record, #{path := [], kind := <<"machine">>, id := {text, <<"m">>},
                                        attrs := [{_, kernel, ok, {int, <<"7">>}}],
                                        children := {complete, [{text, <<"cpus">>}]}}}},
                 sent(1)),
    [View] = views(Line),
    ?assertEqual(ok, data(Relay, 1, {next, 1})),
    nothing_sent(),
    Watch = erlang:monitor(process, View),
    ?assertEqual(ok, data(Relay, 1, {close, 1})),
    receive {'DOWN', Watch, process, View, normal} -> ok after 5000 -> error(view_lives) end.

%% A view the inspector refuses ends with the inspector's reason, and a target the
%% line does not serve is unsupported.
refused_views_end_test() ->
    Line = line(fun([], _Scope) -> {error, scope} end),
    {ok, Relay} = erx_web_relay:start_link(#{system => 4}),
    ok = gen_server:call(Relay, {connect, self(), 2, #{principal => <<"root">>, build => ?BUILD, line => Line}}),
    ok = data(Relay, 2, {hello, erx_web_proto:hash()}),
    {welcome, _, _} = sent(2),
    ok = data(Relay, 2, {open, 1, {path, []}}),
    ?assertEqual({ended, 1, <<"scope">>}, sent(2)),
    ok = data(Relay, 2, {open, 2, {path, [<<"nothing">>]}}),
    ?assertEqual({ended, 2, <<"scope">>}, sent(2)),
    ok = data(Relay, 2, {open, 3, uis}),
    ?assertEqual({ended, 3, <<"unsupported">>}, sent(2)).

%% The session's processes through the inspector itself at the session's scope: the
%% processes of the domain the runtime is, on a development host the system domain
%% (erx_inspector:runtime_domain/0). The open of their listing's path, as /proc
%% entry names, is answered with the listing, and with 1,000 idle processes beside
%% the test's own it holds a page of 1,000 children within one update.
session_processes_test() ->
    Idle = [spawn(fun() -> receive stop -> ok end end) || _ <- lists:seq(1, 1000)],
    try
        Line = line_at([?SYSTEM]),
        {ok, View} = gen_server:call(Line, {open, {path, [<<"processes">>]}}),
        receive
            {web_view, View, {record, #{path := WirePath, kind := Kind, id := Id, attrs := Attrs,
                                        children := {Completeness, Children}}}} ->
                ?assertEqual([{text, <<"processes">>}], WirePath),
                ?assertEqual({{atom, <<"processes">>}, []}, {Id, Attrs}),
                ?assertEqual(<<"listing">>, Kind),
                ?assertEqual(partial, Completeness),
                ?assertEqual(1000, length(Children));
            {web_view_ended, View, Reason} ->
                error({ended, Reason})
        after 5000 -> error(no_update)
        end
    after
        [Pid ! stop || Pid <- Idle]
    end.

%% A process opened by the name its listing gives it, as the client's link names it,
%% is answered with the process's record.
listed_process_test() ->
    Line = line_at([?SYSTEM]),
    Name = erx_procfs_core:name(erx_inspector:proc_id(self())),
    {ok, View} = gen_server:call(Line, {open, {path, [<<"processes">>, Name]}}),
    receive
        {web_view, View, {record, #{path := WirePath, kind := Kind}}} ->
            ?assertEqual({[{text, <<"processes">>}, {text, Name}], <<"process">>}, {WirePath, Kind});
        {web_view_ended, View, Reason} ->
            error({ended, Reason})
    after 5000 -> error(no_update)
    end.

%% A path outside the session's scope ends the view `scope`, as /proc answers enoent:
%% for a session whose scope is another domain, a process of the domain the runtime
%% is and that domain's record, and a machine-wide path. Names that name nothing, or
%% are not names, are answered as a path outside the scope, and the line goes on
%% serving.
scope_test() ->
    Line = line_at([?SYSTEM + 5]),
    Ended = fun(Names) ->
                    {ok, View} = gen_server:call(Line, {open, {path, Names}}),
                    receive
                        {web_view_ended, View, Reason} -> Reason;
                        {web_view, View, Body} -> error({answered, Names, Body})
                    after 5000 -> error(no_end)
                    end
            end,
    ?assertEqual(scope, Ended([<<"processes">>, erx_procfs_core:name(erx_inspector:proc_id(self()))])),
    ?assertEqual(scope, Ended([<<"domains">>, <<"4">>])),
    ?assertEqual(scope, Ended([<<"kernel">>])),
    [?assertEqual({error, scope}, gen_server:call(Line, {open, {path, Names}}))
     || Names <- [[<<"nothing">>], [<<"domains">>, <<"4">>, <<"..">>], [<<"domains/4">>], [<<>>],
                  [<<"domains">> | <<"4">>], [domains], [<<"processes">>, <<"0.1.0">>, <<"x">>]]],
    ?assert(is_process_alive(Line)).

%% A line holds at most 64 views; past them an open is busy until one ends.
bound_test() ->
    Line = line(fun([], _Scope) -> machine(1) end),
    Views = [begin {ok, V} = gen_server:call(Line, {open, {path, []}}), V end || _ <- lists:seq(1, 64)],
    ?assertEqual({error, busy}, gen_server:call(Line, {open, {path, []}})),
    flush_updates(),
    hd(Views) ! stop,
    wait_views(Line, 63),
    ?assertMatch({ok, _}, gen_server:call(Line, {open, {path, []}})).

%% From another domain the line takes a call only in its peer's envelope, and a
%% view a `next` likewise; the view answers its opener alone.
envelope_test() ->
    Line = line(fun([], _Scope) -> machine(1) end),
    Alias = alias(),
    Line ! {erx_origin, ?PEER + 1, {'$gen_call', {self(), [alias | Alias]}, {open, {path, []}}}},
    receive {[alias | Alias], Refused} -> error({answered, Refused}) after 200 -> ok end,
    Line ! {erx_origin, ?PEER, {'$gen_call', {self(), [alias | Alias]}, {open, {path, []}}}},
    View = receive {[alias | Alias], {ok, V}} -> V after 5000 -> error(no_answer) end,
    receive {web_view, View, {record, _}} -> ok after 5000 -> error(no_update) end,
    Watch = erlang:monitor(process, View),
    View ! {erx_origin, ?PEER + 1, stop},
    receive {'DOWN', Watch, _, _, _} -> error(stopped_by_another_domain) after 200 -> ok end,
    View ! {erx_origin, ?PEER, stop},
    receive {'DOWN', Watch, process, View, normal} -> ok after 5000 -> error(view_lives) end.

%% A peer's call whose alias is no reference is dropped unanswered, and the line
%% goes on serving its peer.
peer_alias_test() ->
    Line = line(fun([], _Scope) -> machine(1) end),
    process_flag(trap_exit, true),
    Line ! {erx_origin, ?PEER, {'$gen_call', {self(), [alias | not_an_alias]}, {open, {path, []}}}},
    Alias = alias(),
    Line ! {erx_origin, ?PEER, {'$gen_call', {self(), [alias | Alias]}, {open, {path, []}}}},
    receive
        {[alias | Alias], {ok, _View}} -> ok;
        {'EXIT', Line, Reason} -> error({line_ended, Reason})
    after 5000 -> error(no_answer)
    end,
    process_flag(trap_exit, false).

%% In the peer's envelope, a call whose caller or alias is another domain's is dropped
%% unanswered and opens no view, so no reply and no update goes to a third domain.
third_domain_test() ->
    Line = line(fun([], _Scope) -> machine(1) end),
    Other = alias(),
    persistent_term:put({?MODULE, owner, Other}, ?PEER + 1),
    try
        Line ! {erx_origin, ?PEER, {'$gen_call', {self(), [alias | Other]}, {open, {path, []}}}},
        receive {[alias | Other], Answer} -> error({answered, Answer}) after 200 -> ok end,
        Caller = spawn(fun() -> receive _ -> ok end end),
        persistent_term:put({?MODULE, owner, Caller}, ?PEER + 1),
        Alias = alias(),
        Line ! {erx_origin, ?PEER, {'$gen_call', {Caller, [alias | Alias]}, {open, {path, []}}}},
        receive {[alias | Alias], Answered} -> error({answered, Answered}) after 200 -> ok end,
        persistent_term:erase({?MODULE, owner, Caller}),
        ?assertEqual([], views(Line))
    after
        persistent_term:erase({?MODULE, owner, Other})
    end.

%% A line serves no domain until the system domain has it exported to one: the
%% export is taken only in the system domain's envelope, from no other domain and
%% from no process of the session, and the line serves the domain it was exported to.
export_test() ->
    register(?EXPORTS, self()),
    {ok, Line} = erx_web_line:start_link(#{system => ?SYSTEM, inspect => fun([], _Scope) -> machine(1) end,
                                           exports => ?MODULE}),
    Alias = alias(),
    Call = fun(D, Request) -> Line ! {erx_origin, D, {'$gen_call', {self(), [alias | Alias]}, Request}} end,
    Call(?PEER, {open, {path, []}}),
    receive {[alias | Alias], Early} -> error({served_before_export, Early}) after 200 -> ok end,
    Call(?PEER, {export, ?PEER}),
    Call(?PEER + 1, {export, ?PEER}),
    receive {[alias | Alias], Forged} -> error({export_answered, Forged}) after 200 -> ok end,
    ?assertEqual({error, badarg}, gen_server:call(Line, {export, ?PEER})),
    receive {exported, _, _, _} = Unwanted -> error(Unwanted) after 0 -> ok end,
    Call(?SYSTEM, {export, ?PEER}),
    receive {[alias | Alias], Exported} -> ?assertEqual(ok, Exported) after 5000 -> error(no_answer) end,
    receive {exported, Line, [send], ?PEER} -> ok after 0 -> error(not_exported) end,
    Call(?PEER, {open, {path, []}}),
    receive {[alias | Alias], {ok, View}} when is_pid(View) -> ok after 5000 -> error(not_served) end,
    unregister(?EXPORTS).

%% The system domain exports only root's session's line, and only in a development
%% build (erx_hostlink_web), so from the export on the line's views read at scope
%% `all`, as root's session in a development build inspects (docs/design-live.md,
%% "Scopes"); before it, at the session's own scope. Through the inspector itself, a
%% session whose own scope is another domain gets `scope` for the machine-wide
%% /proc/kernel until the export, and the record after it.
export_reads_all_test() ->
    {ok, Line} = erx_web_line:start_link(#{system => ?SYSTEM, scope => [?SYSTEM + 5],
                                           exports => ?MODULE}),
    Open = fun(Request) ->
                   {ok, View} = gen_server:call(Line, Request),
                   receive
                       {web_view, View, {record, #{path := Path, kind := Kind}}} -> {Path, Kind};
                       {web_view_ended, View, Reason} -> Reason
                   after 5000 -> error(no_answer)
                   end
           end,
    ?assertEqual(scope, Open({open, {path, [<<"kernel">>]}})),
    %% An export asked by a process of the session, or in the peer's envelope, is
    %% refused and widens nothing.
    ?assertEqual({error, badarg}, gen_server:call(Line, {export, ?PEER})),
    Line ! {erx_origin, ?PEER, {'$gen_call', {self(), [alias | alias()]}, {export, ?PEER}}},
    ?assertEqual(scope, Open({open, {path, [<<"kernel">>]}})),
    Alias = alias(),
    Line ! {erx_origin, ?SYSTEM, {'$gen_call', {self(), [alias | Alias]}, {export, ?PEER}}},
    receive {[alias | Alias], Exported} -> ?assertEqual(ok, Exported) after 5000 -> error(no_answer) end,
    ?assertEqual({[{text, <<"kernel">>}], <<"listing">>}, Open({open, {path, [<<"kernel">>]}})).

views(Line) ->
    {links, Links} = erlang:process_info(Line, links),
    [Pid || Pid <- Links, Pid =/= self()].

wait_views(Line, N) ->
    case length(views(Line)) of
        N -> ok;
        _ -> timer:sleep(10), wait_views(Line, N)
    end.

flush_updates() ->
    receive {web_view, _, _} -> flush_updates() after 100 -> ok end.
