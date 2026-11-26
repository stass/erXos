%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_svc_client_tests).
-moduledoc """
EUnit cases of erx_svc_client (docs/design-app-trees.md, "Reading with a
deadline", AT6), over a stub tree served by a test process. The client is
compiled with TEST, whose read/5, command/4 and open/4 take the file
module the shipped calls give as `file`; this module is that file module
here: its open/2, read/2, write/2, close/1 and read_file_info/2 ask the
stub tree's process, registered under this module's name, which records
every open and every command its ctl acts on, and can leave a request
unanswered, as a hung server does.

The cases: a whole file, a file cut at `Max + 1` bytes, `svc_status_max`
as the bound; a hung server answered `timeout` at the deadline, the
reader killed and its late answer kept from the caller; the caller's own
end ending the reader; `not_serving` and `enoent`; `einval` for every
`Name` and `File` that leaves the tree, opening nothing; a command's
answers, `unknown` for a write cut off at the deadline or answered `eio`,
each acted on once; open/3 in the caller's process; and the bounds on
`Max` and `Deadline`.
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

%% The stub tree's file module, called by the client.
-export([open/2, read/2, write/2, close/1, read_file_info/2]).

-define(SHORT, 200).
%% How much later than its deadline a call may answer.
-define(SLACK, 1000).

%%% The stub tree's file module

open(Path, Modes) -> call({open, Path, Modes}).
read(Fd, Count) -> call({read, Fd, Count}).
write(Fd, Bytes) -> call({write, Fd, iolist_to_binary(Bytes)}).
close(Fd) -> call({close, Fd}).
read_file_info(Path, _Options) -> call({info, Path}).

call(Request) ->
    Ref = make_ref(),
    ?MODULE ! {call, self(), Ref, Request},
    receive {Ref, Answer} -> Answer end.

%%% The stub tree

%% A tree maps a path to {file, Bytes}, read at most 4,096 bytes a read; hang,
%% whose open is never answered until release/0; or {ctl, How}, whose write is
%% answered by How: ok, {error, Errno}, {late, Ms} (acted on and answered ok
%% Ms later) or acts_then_eio. A path's parents are its tree's directories.
serve(Tree) ->
    Me = self(),
    Pid = spawn(fun() ->
                        register(?MODULE, self()),
                        Me ! served,
                        loop(#{tree => Tree, fds => #{}, opens => [], acted => [], hung => []})
                end),
    receive served -> Pid end.

stop(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok end.

with_tree(Tree, Case) ->
    Pid = serve(Tree),
    try Case() after stop(Pid) end.

loop(State) ->
    receive
        {call, From, Ref, Request} ->
            loop(handle(Request, From, Ref, State));
        {acted, From, Ref, Line} ->
            From ! {Ref, ok},
            loop(acted(Line, State));
        {get, From, Key} ->
            From ! {got, maps:get(Key, State)},
            loop(State);
        release ->
            [From ! {Ref, {error, eio}} || {From, Ref} <- maps:get(hung, State)],
            loop(State#{hung := []})
    end.

handle({open, Path, _Modes}, From, Ref, #{tree := Tree, fds := Fds, opens := Opens} = State) ->
    Opened = State#{opens := Opens ++ [{Path, From}]},
    case maps:get(Path, Tree, absent) of
        hang ->
            Opened#{hung := [{From, Ref} | maps:get(hung, State)]};
        absent ->
            From ! {Ref, {error, enoent}},
            Opened;
        Entry ->
            Fd = {stub_fd, make_ref()},
            From ! {Ref, {ok, Fd}},
            Opened#{fds := Fds#{Fd => {Entry, 0}}}
    end;
handle({read, Fd, Count}, From, Ref, #{fds := Fds} = State) ->
    {{file, Bytes}, At} = maps:get(Fd, Fds),
    Size = min(min(Count, 4096), byte_size(Bytes) - At),
    From ! {Ref, case Size of 0 -> eof; _ -> {ok, binary:part(Bytes, At, Size)} end},
    State#{fds := Fds#{Fd := {{file, Bytes}, At + Size}}};
handle({write, Fd, Line}, From, Ref, #{fds := Fds} = State) ->
    {{ctl, How}, _} = maps:get(Fd, Fds),
    case How of
        {late, Ms} ->
            erlang:send_after(Ms, self(), {acted, From, Ref, Line}),
            State;
        acts_then_eio ->
            From ! {Ref, {error, eio}},
            acted(Line, State);
        ok ->
            From ! {Ref, ok},
            acted(Line, State);
        {error, _} = Error ->
            From ! {Ref, Error},
            State
    end;
handle({close, Fd}, From, Ref, #{fds := Fds} = State) ->
    From ! {Ref, ok},
    State#{fds := maps:remove(Fd, Fds)};
handle({info, Path}, From, Ref, #{tree := Tree} = State) ->
    Prefix = <<Path/binary, "/">>,
    Held = lists:any(fun(Key) -> binary:longest_common_prefix([Key, Prefix]) =:= byte_size(Prefix) end,
                     maps:keys(Tree)),
    From ! {Ref, case Held of true -> {ok, directory}; false -> {error, enoent} end},
    State.

acted(Line, #{acted := Acted} = State) -> State#{acted := Acted ++ [Line]}.

got(Key) ->
    ?MODULE ! {get, self(), Key},
    receive {got, Value} -> Value end.

%% The stub tree's answers so far, then nothing more.
settled(Key) ->
    timer:sleep(50),
    got(Key).

app() ->
    #{<<"/svc/app/status">> => {file, <<"state running\n">>},
      <<"/svc/app/ctl">> => {ctl, ok},
      <<"/svc/start/ctl">> => {file, <<"the start table's ctl\n">>},
      <<"/svc/hung/status">> => hang,
      <<"/svc/hung/ctl">> => hang}.

timed(Call) ->
    Start = erlang:monotonic_time(millisecond),
    Answer = Call(),
    {Answer, erlang:monotonic_time(millisecond) - Start}.

%%% Reading

a_status_is_read_whole_test() ->
    with_tree(app(), fun() ->
        ?assertEqual({ok, <<"state running\n">>},
                     erx_svc_client:read(?MODULE, <<"app">>, <<"status">>, 64, ?SHORT)),
        %% The reader opened the one path, then ended.
        [{<<"/svc/app/status">>, Reader}] = got(opens),
        ?assertNot(is_process_alive(Reader))
    end).

a_long_status_reads_one_byte_past_max_test() ->
    Max = ?ERX_SVC_STATUS_MAX,
    Long = binary:copy(<<"x">>, Max + 100),
    with_tree(#{<<"/svc/app/status">> => {file, Long}}, fun() ->
        {ok, Bytes} = erx_svc_client:read(?MODULE, <<"app">>, <<"status">>, Max, ?SHORT),
        ?assertEqual(Max + 1, byte_size(Bytes)),
        ?assertEqual({ok, binary:part(Long, 0, Max)},
                     erx_svc_client:read(?MODULE, <<"app">>, <<"status">>, Max - 1, ?SHORT))
    end).

a_short_max_cuts_the_file_one_byte_past_it_test() ->
    with_tree(app(), fun() ->
        ?assertEqual({ok, <<"state ">>}, erx_svc_client:read(?MODULE, <<"app">>, <<"status">>, 5, ?SHORT)),
        ?assertEqual({ok, <<"s">>}, erx_svc_client:read(?MODULE, <<"app">>, <<"status">>, 0, ?SHORT))
    end).

a_hung_server_times_out_at_the_deadline_test() ->
    with_tree(app(), fun() ->
        {Answer, Took} = timed(fun() -> erx_svc_client:read(?MODULE, <<"hung">>, <<"status">>, 64, ?SHORT) end),
        ?assertEqual(timeout, Answer),
        ?assert(Took >= ?SHORT andalso Took < ?SHORT + ?SLACK),
        %% The reader was killed at the deadline, so its fids end at the grant.
        [{_, Reader}] = got(opens),
        ?assertNot(is_process_alive(Reader)),
        %% The server's late answer reaches nobody: the reader is gone, and no
        %% message and no exit reach the caller.
        ?MODULE ! release,
        timer:sleep(50),
        ?assertEqual({messages, []}, process_info(self(), messages)),
        ?assertEqual(timeout, erx_svc_client:read(?MODULE, <<"hung">>, <<"status">>, 64, 0))
    end).

the_callers_end_ends_the_reader_test() ->
    with_tree(app(), fun() ->
        {Caller, Ref} = spawn_monitor(fun() ->
                                              erx_svc_client:read(?MODULE, <<"hung">>, <<"status">>, 64,
                                                                  ?ERX_SVC_WAIT_MAX)
                                      end),
        Reader = opener(50),
        exit(Caller, kill),
        receive {'DOWN', Ref, process, Caller, killed} -> ok end,
        Watch = monitor(process, Reader),
        receive {'DOWN', Watch, process, Reader, _} -> ok
        after ?SLACK -> ?assert(false)
        end
    end).

%% The process that opened, once the stub tree has seen its open.
opener(0) ->
    erlang:error(no_open);
opener(Tries) ->
    case got(opens) of
        [{_, Pid}] -> Pid;
        [] -> timer:sleep(10), opener(Tries - 1)
    end.

%%% What a name reaches

a_name_slash_svc_does_not_hold_is_not_serving_test() ->
    with_tree(app(), fun() ->
        ?assertEqual(not_serving, erx_svc_client:read(?MODULE, <<"absent">>, <<"status">>, 64, ?SHORT)),
        ?assertEqual(not_serving, erx_svc_client:command(?MODULE, <<"absent">>, <<"reload">>, ?SHORT)),
        ?assertEqual(not_serving, erx_svc_client:open(?MODULE, <<"absent">>, <<"pair">>, [read])),
        %% A file the tree does not hold is the tree's enoent.
        ?assertEqual({error, enoent}, erx_svc_client:read(?MODULE, <<"app">>, <<"missing">>, 64, ?SHORT)),
        ?assertEqual({error, enoent}, erx_svc_client:open(?MODULE, <<"app">>, <<"missing">>, [read]))
    end).

a_name_or_file_that_leaves_the_tree_opens_nothing_test() ->
    with_tree(app(), fun() ->
        Leaving = [{<<"app">>, <<"../start/ctl">>}, {<<"app">>, <<"/etc/passwd">>},
                   {<<"app">>, <<"a/../../start/ctl">>}, {<<"app">>, <<"./status">>},
                   {<<"app">>, <<"..">>}, {<<"app">>, <<"">>}, {<<"app">>, <<"a//b">>},
                   {<<"app">>, <<"status/">>}, {<<"app">>, <<"st", 0, "atus">>}, {<<"app">>, "status"},
                   {<<"..">>, <<"start/ctl">>}, {<<".">>, <<"status">>}, {<<>>, <<"status">>},
                   {<<"a/b">>, <<"status">>}, {<<"/app">>, <<"status">>}, {<<"app", 0>>, <<"status">>},
                   {app, <<"status">>}],
        [?assertEqual({error, einval}, erx_svc_client:read(?MODULE, Name, File, 64, ?SHORT))
         || {Name, File} <- Leaving],
        [?assertEqual({error, einval}, erx_svc_client:open(?MODULE, Name, File, [read]))
         || {Name, File} <- Leaving],
        [?assertEqual({error, einval}, erx_svc_client:command(?MODULE, Name, <<"reload">>, ?SHORT))
         || Name <- [<<"a/b">>, <<"..">>, <<".">>, <<>>, <<"../start">>]],
        ?assertEqual([], settled(opens))
    end).

%%% Commanding

a_command_is_one_write_to_the_trees_ctl_test() ->
    Tree = #{<<"/svc/app/ctl">> => {ctl, ok}, <<"/svc/refusing/ctl">> => {ctl, {error, eperm}}},
    with_tree(Tree, fun() ->
        ?assertEqual(ok, erx_svc_client:command(?MODULE, <<"app">>, <<"reload\n">>, ?SHORT)),
        ?assertEqual({error, eperm}, erx_svc_client:command(?MODULE, <<"refusing">>, <<"stop">>, ?SHORT)),
        ?assertEqual([<<"reload\n">>], settled(acted)),
        ?assertMatch([{<<"/svc/app/ctl">>, _}, {<<"/svc/refusing/ctl">>, _}], got(opens))
    end).

a_command_cut_off_is_unknown_and_not_repeated_test() ->
    with_tree(#{<<"/svc/app/ctl">> => {ctl, {late, 3 * ?SHORT}}}, fun() ->
        {Answer, Took} = timed(fun() -> erx_svc_client:command(?MODULE, <<"app">>, <<"ping">>, ?SHORT) end),
        ?assertEqual(unknown, Answer),
        ?assert(Took < ?SHORT + ?SLACK),
        timer:sleep(3 * ?SHORT),
        ?assertEqual([<<"ping">>], settled(acted)),
        ?assertEqual(1, length(got(opens)))
    end).

a_command_whose_handler_acts_and_ends_is_unknown_test() ->
    with_tree(#{<<"/svc/app/ctl">> => {ctl, acts_then_eio}}, fun() ->
        ?assertEqual(unknown, erx_svc_client:command(?MODULE, <<"app">>, <<"ping">>, ?SHORT)),
        ?assertEqual([<<"ping">>], settled(acted))
    end).

a_command_to_a_hung_server_is_unknown_at_the_deadline_test() ->
    with_tree(app(), fun() ->
        {Answer, Took} = timed(fun() -> erx_svc_client:command(?MODULE, <<"hung">>, <<"ping">>, ?SHORT) end),
        ?assertEqual(unknown, Answer),
        ?assert(Took < ?SHORT + ?SLACK)
    end).

a_line_past_svc_ctl_max_is_refused_unwritten_test() ->
    with_tree(app(), fun() ->
        Longest = binary:copy(<<"x">>, ?ERX_SVC_CTL_MAX),
        ?assertEqual({error, einval},
                     erx_svc_client:command(?MODULE, <<"app">>, <<Longest/binary, "y">>, ?SHORT)),
        ?assertEqual([], settled(opens)),
        ?assertEqual(ok, erx_svc_client:command(?MODULE, <<"app">>, Longest, ?SHORT)),
        ?assertEqual([Longest], settled(acted))
    end).

%%% Opening

open_opens_in_the_callers_process_test() ->
    with_tree(app(), fun() ->
        {ok, Fd} = erx_svc_client:open(?MODULE, <<"app">>, <<"status">>, [read, binary]),
        ?assertEqual([{<<"/svc/app/status">>, self()}], got(opens)),
        ?assertEqual({ok, <<"state running\n">>}, read(Fd, 64)),
        ok = close(Fd)
    end).

%%% The bounds a caller gives

a_bound_past_the_interfaces_limits_is_refused_test() ->
    with_tree(app(), fun() ->
        ?assertError(function_clause,
                     erx_svc_client:read(?MODULE, <<"app">>, <<"status">>, ?ERX_SVC_STATUS_MAX + 1, ?SHORT)),
        ?assertError(function_clause,
                     erx_svc_client:read(?MODULE, <<"app">>, <<"status">>, 64, ?ERX_SVC_WAIT_MAX + 1)),
        ?assertError(function_clause,
                     erx_svc_client:read(?MODULE, <<"app">>, <<"status">>, 64, infinity)),
        ?assertError(function_clause,
                     erx_svc_client:command(?MODULE, <<"app">>, <<"ping">>, infinity)),
        ?assertEqual([], settled(opens))
    end).
