%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Edit 75 of docs/design-runtime.md, run on the tree's proc_lib, gen, gen_server, sys,
%% gen_statem, edlin, edlin_key and group loaded over stock's: a process that hides its terms
%% (gen:hides_terms/1) keeps every term it holds out of its terminate report and its
%% crash report (docs/design-log.md, "Reports carry no term"). Each server holds a secret
%% in its state, its dictionary, a message to itself and the arguments of the frame that
%% fails; a handler collects the reports, and no report may carry the secret's bytes. The
%% same server without format_status/1 leaks the secret, so the check is seen to find a
%% leak. No report filter runs: this is the system domain's case, which takes none.
-module(otp_report_status_tests).

-include_lib("eunit/include/eunit.hrl").

-export([log/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_event/4, fails/1]).

-define(HANDLER, otp_report_status).
-define(REPORTS, [{gen_server, terminate}, {gen_statem, terminate}, {proc_lib, crash}]).
-define(ENDED, [{gen_server, terminate}, {proc_lib, crash}]).

%% The capturing handler: every report of a behaviour's end or of a crash, to the test.
log(#{msg := {report, #{label := Label}}} = Event, #{config := #{to := To}}) ->
    case lists:member(Label, ?REPORTS) of
        true -> To ! {logged, Label, Event};
        false -> ok
    end;
log(_Event, _Config) ->
    ok.

%% The modules the cases run are the tree's, from the work directory, not stock's.
tree_modules_are_loaded_test() ->
    {ok, Work} = file:get_cwd(),
    [?assertEqual(filename:basename(Work), filename:basename(filename:dirname(code:which(M))))
     || M <- [proc_lib, gen, gen_server, gen_statem, sys, edlin, edlin_key, group]].

%% The plain server, this module, has no format_status/1, and its reports quote the
%% secret, as stock OTP's do.
server_without_format_status_leaks_the_secret_test() ->
    Reports = reports(gen_server, ?MODULE),
    ?assertEqual(?ENDED, labels(Reports)),
    [?assert(carries(Secret, Report)) || {Secret, Report} <- Reports].

%% otp_report_status_hiding exports a format_status/1 that hides state, message, log and
%% reason, and neither report quotes the secret, which every one of them held.
server_with_format_status_hides_the_secret_test() ->
    Reports = reports(gen_server, otp_report_status_hiding),
    ?assertEqual(?ENDED, labels(Reports)),
    [?assertNot(carries(Secret, Report)) || {Secret, Report} <- Reports].

%% The hiding server fails with the secret in its reason and in the location of the frame
%% the exception names, which erlang:raise/3 takes from the caller.
reason_and_location_carry_the_secret_test() ->
    Reports = reports(gen_server, otp_report_status_hiding, fail_located, []),
    ?assertEqual(?ENDED, labels(Reports)),
    [?assertNot(carries(Secret, Report)) || {Secret, Report} <- Reports].

%% otp_report_status_crashing is a gen_statem whose format_status/1 crashes, holding the
%% secret in its data, a postponed event, its queue and the failing frame: the reports
%% show gen's text for the crash and nothing of what the callback was asked to hide.
statem_whose_format_status_crashes_hides_the_secret_test() ->
    Reports = reports(gen_statem, otp_report_status_crashing),
    ?assertEqual([{gen_statem, terminate}, {proc_lib, crash}], labels(Reports)),
    [?assertNot(carries(Secret, Report)) || {Secret, Report} <- Reports].

%% otp_report_status_changing has no format_status/1 and changes its callback module to
%% otp_report_status_hiding, which has one, before it fails: from then on the process
%% hides its terms, in the crash report as in the terminate report.
statem_that_changes_to_a_hiding_module_hides_the_secret_test() ->
    Reports = reports(gen_statem, otp_report_status_changing),
    ?assertEqual([{gen_statem, terminate}, {proc_lib, crash}], labels(Reports)),
    [?assertNot(carries(Secret, Report)) || {Secret, Report} <- Reports].

%% A server whose format_status/1 crashes shows no sys log in its terminate report; its
%% reason and last message stay raw, as stock OTP's suites require.
crashed_format_status_shows_no_log_test() ->
    Reports = reports(gen_server, otp_report_status_crashing_server, fail, [{debug, [log]}]),
    [{Secret, {{gen_server, terminate}, #{msg := {report, Report}}}}, _Crash] = Reports,
    ?assertMatch(#{log := [], last_message := {'$gen_cast', {fail, Secret}}}, Report).

%% An undef of a process that hides its terms is reported with its frames cut to their
%% arity, and gen_server's text for it still names the function that is not exported.
%% Its reason and last message stay raw, as for any server whose format_status crashes.
undef_of_a_hiding_server_formats_test() ->
    Reports = reports(gen_server, otp_report_status_crashing_server, fail_undef, []),
    [{_Secret, {{gen_server, terminate}, Event}}, _Crash] = Reports,
    #{msg := {report, Report}, meta := #{report_cb := Format}} = Event,
    ?assertMatch(#{reason := {undef, [{?MODULE, missing, 1, []} | _]}}, Report),
    Text = unicode:characters_to_binary(Format(Report, #{depth => unlimited, chars_limit => unlimited,
                                                         single_line => false})),
    ?assertNotEqual(nomatch, binary:match(Text, <<"function not exported">>)).

%% A group's status shows none of the user's input: neither the driver's input
%% postponed while no request reads, nor the line typed so far for a request, nor
%% that line once a nested request has pushed its request aside.
group_status_hides_the_input_test() ->
    Ahead = secret(),
    Typed = secret(),
    Test = self(),
    Driver = spawn(fun() -> driver(Test) end),
    Group = group:start(Driver, noshell, []),
    Reader = spawn(fun() -> receive read -> io:get_line(Group, '') end end),
    try
        Group ! {Driver, {data, binary_to_list(Ahead)}},
        ?assertNot(holds(Ahead, sys:get_status(Group))),
        Reader ! read,
        Ref = receive {asked, Group, R} -> R after 5000 -> error(no_ask) end,
        Group ! {Driver, {read, Ref, binary_to_list(Typed)}},
        Status = sys:get_status(Group),
        ?assertNot(holds(Ahead, Status)),
        ?assertNot(holds(Typed, Status)),
        Group ! {io_request, self(), make_ref(), {get_line, unicode, ''}},
        Pushed = sys:get_status(Group),
        ?assertNot(holds(Ahead, Pushed)),
        ?assertNot(holds(Typed, Pushed))
    after
        [exit(Pid, kill) || Pid <- [Reader, Group, Driver]]
    end.

%% A group's status does not show the text the user killed, which the line editor keeps
%% in the group's process dictionary: sys:get_status shows a hiding process's dictionary
%% empty, as its crash report does.
group_status_hides_the_kill_buffer_test() ->
    Killed = secret(),
    Test = self(),
    Driver = spawn(fun() -> driver(Test) end),
    Group = group:start(Driver, noshell, [{dumb, false}]),
    Reader = spawn(fun() -> io:get_line(Group, "> ") end),
    try
        Ref = receive {asked, Group, R} -> R after 5000 -> error(no_ask) end,
        Group ! {Driver, {read, Ref, binary_to_list(Killed) ++ "\^U"}},
        Again = receive {asked, Group, R2} -> R2 after 5000 -> error(no_ask) end,
        ?assert(is_reference(Again)),
        ?assertNot(holds(Killed, sys:get_status(Group)))
    after
        [exit(Pid, kill) || Pid <- [Reader, Group, Driver]]
    end.

%% The group's driver: each ask for input, to the test.
driver(Test) ->
    receive
        {Group, read, Ref} -> Test ! {asked, Group, Ref};
        _Output -> ok
    end,
    driver(Test).

%% gen_server callbacks of the plain server, which otp_report_status_hiding and
%% otp_report_status_crashing_server take over.
init(Secret) ->
    put(held, Secret),
    {ok, {held, Secret}}.

handle_call(_Request, _From, State) -> {reply, ok, State}.

handle_cast({hold, _Secret}, State) ->
    {noreply, State};
handle_cast({Failure, Secret}, State) ->
    self() ! {held, Secret},
    failure(Failure, Secret),
    {noreply, State}.

handle_info(_Message, State) -> {noreply, State}.

%% The gen_statem events of otp_report_status_crashing and otp_report_status_hiding.
handle_event(cast, {hold, _Secret}, _State, _Data) ->
    {keep_state_and_data, [postpone]};
handle_event(cast, {fail, Secret}, _State, _Data) ->
    self() ! {held, Secret},
    fails(Secret),
    keep_state_and_data.

%% Each way to fail on the secret: a clause, an exception whose reason and frame location
%% carry it, and a call of a function this module does not export.
failure(fail, Secret) -> fails(Secret);
failure(fail_located, Secret) -> erlang:raise(error, {failed, Secret}, [{?MODULE, fails, 1, [{held, Secret}]}]);
failure(fail_undef, Secret) -> apply(?MODULE, missing, [Secret]).

%% A clause that fails on the secret, which is a binary: the frame's argument is it.
fails(Atom) when is_atom(Atom) -> ok.

secret() -> <<"SECRET-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

%% Starts Behaviour's server Mod with StartOptions, holding a fresh secret, fails it with
%% the cast {Failure, Secret} and returns each report it logged, with the secret, sorted
%% by label.
reports(Behaviour, Mod) -> reports(Behaviour, Mod, fail, []).

reports(Behaviour, Mod, Failure, StartOptions) ->
    Secret = secret(),
    ok = logger:add_handler(?HANDLER, ?MODULE, #{config => #{to => self()}}),
    try
        {ok, Pid} = Behaviour:start(Mod, Secret, StartOptions),
        Monitor = monitor(process, Pid),
        ok = Behaviour:cast(Pid, {hold, Secret}),
        ok = Behaviour:cast(Pid, {Failure, Secret}),
        receive {'DOWN', Monitor, process, Pid, _Reason} -> ok after 5000 -> error(no_exit) end,
        lists:sort([{Secret, Report} || Report <- collected(2)])
    after
        ok = logger:remove_handler(?HANDLER)
    end.

collected(0) -> [];
collected(N) ->
    receive {logged, Label, Event} -> [{Label, Event} | collected(N - 1)]
    after 5000 -> error({reports_missing, N})
    end.

labels(Reports) -> [Label || {_Secret, {Label, _Event}} <- Reports].

carries(Secret, {_Label, Event}) -> holds(Secret, Event).

%% A line being read may be held reversed, as io_lib's collectors hold it.
holds(Secret, Term) ->
    Bytes = term_to_binary(Term),
    lists:any(fun(Shape) -> binary:match(Bytes, Shape) =/= nomatch end,
              [Secret, list_to_binary(lists:reverse(binary_to_list(Secret)))]).
