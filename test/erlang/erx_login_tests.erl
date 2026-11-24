%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The login service, erx_login, behind its core (docs/design-login.md,
%% "Verification"): a host front end stands in for a real one, calling the service
%% as the facet forwards, and this module stands in for the domain service and the
%% passphrase checker, whose answers a stub server gives as each case sets them.
-module(erx_login_tests).

-include_lib("eunit/include/eunit.hrl").

-export([start_session_request/2, line_request/4, id/1, stop/2, check_request/4, log/2]).

-define(SENTINEL, <<"sentinel-passphrase-7f3a">>).

%% The stand-ins: each request goes to the stub server, which answers with what
%% its case set for that kind, and records it.
start_session_request(Principal, Start) -> gen_server:send_request(stub, {start, Principal, Start}).
line_request(Line, Session, Grantee, Facet) -> gen_server:send_request(stub, {mint, Line, Session, Grantee, Facet}).
id({erx_domain, Id, _Node, _Pid}) -> Id.
stop(Session, _Reason) -> stub ! {stopped, Session}, ok.
%% A checker that crashes the service while its last message and its state hold the
%% passphrase; the crash reason itself names none (docs/design-login.md, "Secrets").
check_request(_User, <<"crash", _/binary>>, network, _Terminal) -> error(checker_crashed);
check_request(User, Passphrase, network, Terminal) ->
    gen_server:send_request(stub, {check, User, Passphrase, Terminal}).

stub(Answers, Seen) ->
    receive
        {'$gen_call', From, Request} ->
            gen:reply(From, maps:get(element(1, Request), Answers)),
            stub(Answers, [Request | Seen]);
        {stopped, Session} -> stub(Answers, [{stopped, Session} | Seen]);
        {seen, Pid} -> Pid ! {seen, lists:reverse(Seen)}, stub(Answers, Seen)
    end.

seen() ->
    stub ! {seen, self()},
    receive {seen, Seen} -> Seen end.

session() -> {erx_domain, 9, node(), list_to_pid("<0.9.0>")}.

setup(Answers, Options) ->
    true = register(stub, spawn(fun() -> stub(Answers, []) end)),
    {ok, Login} = erx_login:start_link(Options#{domain => ?MODULE}),
    unlink(Login),
    Login.

cleanup(Login) ->
    exit(Login, kill),
    exit(whereis(stub), kill),
    wait_unregistered(stub),
    wait_unregistered(erx_login).

wait_unregistered(Name) ->
    case whereis(Name) of
        undefined -> ok;
        _Pid -> timer:sleep(5), wait_unregistered(Name)
    end.

matching() -> #{check => {match, 42}, start => {ok, session()}, mint => {ok, list_to_pid("<0.77.0>")}}.

grant() -> grant(self(), 16).
grant(Facet, Logins) -> #{facet => Facet, grantee => 7, line => tty_line, logins => Logins, holder => <<"ssh">>}.

%% A call as the facet forwards it, from Owner's connection.
login(Owner, Request) -> login(Owner, Request, grant()).
login(Owner, Request, Grant) -> gen_server:call(erx_login, {login, Request, Owner, Grant}).

passphrase(Passphrase) -> {login_passphrase, <<"alice">>, Passphrase, <<"peer">>}.

%% A front end's connection process, which lives until it is told to end.
connection() -> spawn(fun() -> receive stop -> ok end end).

with(Answers, Options, Case) ->
    {setup, fun() -> setup(Answers, Options) end, fun cleanup/1, fun(Login) -> fun() -> Case(Login) end end}.

with_no_checker_a_passphrase_login_answers_unavailable_test_() ->
    with(matching(), #{}, fun(_Login) ->
        ?assertEqual({error, unavailable}, login(connection(), passphrase(<<"right">>))),
        ?assertEqual([], seen())
    end).

a_match_starts_the_session_and_mints_the_grant_s_line_test_() ->
    with(matching(), #{checker => ?MODULE}, fun(_Login) ->
        Owner = connection(),
        ?assertEqual({ok, list_to_pid("<0.77.0>")}, login(Owner, passphrase(<<"right">>))),
        Facet = self(),
        ?assertEqual([{check, <<"alice">>, <<"right">>, {<<"ssh">>, <<"peer">>}},
                      {start, 42, #{ends_with => [Owner, Facet]}},
                      {mint, tty_line, 9, 7, Facet}], seen())
    end).

one_login_per_owner_test_() ->
    with(matching(), #{checker => ?MODULE}, fun(_Login) ->
        Owner = connection(),
        {ok, _Line} = login(Owner, passphrase(<<"right">>)),
        ?assertEqual({error, badarg}, login(Owner, passphrase(<<"right">>))),
        ?assertEqual({error, badarg}, login(Owner, cookie)),
        ?assertEqual(1, length([S || {start, _, _} = S <- seen()]))
    end).

a_refused_mint_stops_the_session_it_started_test_() ->
    with((matching())#{mint => {error, no_line}}, #{checker => ?MODULE}, fun(_Login) ->
        ?assertEqual({error, unavailable}, login(connection(), passphrase(<<"right">>))),
        ?assertEqual({stopped, session()}, lists:last(seen()))
    end).

a_wrong_passphrase_answers_no_match_and_frees_the_row_test_() ->
    with((matching())#{check => no_match}, #{checker => ?MODULE}, fun(Login) ->
        Owner = connection(),
        ?assertEqual({error, no_match}, login(Owner, passphrase(<<"wrong">>))),
        {monitors, Monitors} = process_info(Login, monitors),
        ?assertEqual([], Monitors)
    end).

the_owner_s_end_frees_its_row_test_() ->
    with(matching(), #{}, fun(Login) ->
        Owner = connection(),
        {ok, _Cookie} = login(Owner, cookie),
        ?assertMatch({monitors, [_]}, process_info(Login, monitors)),
        Owner ! stop,
        timer:sleep(50),
        ?assertMatch({monitors, []}, process_info(Login, monitors))
    end).

a_cookie_is_sixteen_bytes_test_() ->
    with(matching(), #{}, fun(_Login) ->
        {ok, Cookie} = login(connection(), cookie),
        ?assertEqual(16, byte_size(Cookie))
    end).

the_terminal_is_the_holder_s_test_() ->
    with((matching())#{check => no_match}, #{checker => ?MODULE}, fun(_Login) ->
        {error, no_match} = login(connection(), passphrase(<<"x">>), grant()),
        {error, no_match} = login(connection(), passphrase(<<"x">>), (grant())#{holder => <<"web">>}),
        ?assertEqual([{<<"ssh">>, <<"peer">>}, {<<"web">>, <<"peer">>}], [T || {check, _, _, T} <- seen()])
    end).

%% The secrets: the service's queue is not readable from outside, and a crash of
%% the service holding the sentinel puts it in no report of the system log.
the_service_s_queue_is_hidden_test_() ->
    with(matching(), #{}, fun(Login) ->
        ok = sys:suspend(Login),
        Login ! {held, ?SENTINEL},
        ?assertEqual(nomatch, binary:match(term_to_binary(process_info(Login, messages)), ?SENTINEL)),
        ok = sys:resume(Login)
    end).

a_crash_holding_a_passphrase_logs_none_of_it_test_() ->
    with(matching(), #{checker => ?MODULE}, fun(Login) ->
        ok = logger:add_handler(sentinel_watch, ?MODULE, #{config => self()}),
        Monitor = monitor(process, Login),
        try login(connection(), passphrase(<<"crash", (?SENTINEL)/binary>>)) catch exit:_ -> ok end,
        receive {'DOWN', Monitor, process, Login, _} -> ok end,
        timer:sleep(100),
        ok = logger:remove_handler(sentinel_watch),
        Logged = collect([]),
        ?assertNotEqual([], Logged),
        [?assertEqual(nomatch, binary:match(Text, ?SENTINEL)) || Text <- Logged]
    end).

%% The login service's crash restarts it alone (docs/design-system.md, "System services"):
%% its supervisor allows within one period a restart of each of its permanent children, so
%% a crash of the service and one of the PCIe process, /dev or the machine tree in the same
%% period end neither the supervisor nor the system domain.
each_permanent_child_restarts_once_within_the_period_test() ->
    {ok, {Flags, Children}} = erx_domain_sup:init([]),
    Permanent = [Id || #{id := Id, restart := permanent} <- Children],
    ?assert(lists:member(erx_login, Permanent)),
    ?assert(maps:get(intensity, Flags, 1) >= length(Permanent)).

log(#{msg := Msg} = Event, #{config := Pid}) ->
    Text = case Msg of
               {report, Report} -> io_lib:format("~tp ~tp", [Report, maps:get(meta, Event)]);
               {string, String} -> String;
               {Format, Args} -> io_lib:format(Format, Args)
           end,
    Pid ! {logged, unicode:characters_to_binary(io_lib:format("~ts", [Text]))}.

collect(Acc) ->
    receive {logged, Text} -> collect([Text | Acc])
    after 0 -> Acc
    end.
