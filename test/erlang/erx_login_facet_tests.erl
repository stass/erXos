%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The login facet in front of the login service (docs/design-login.md,
%% "Verification"): a real erx_facet of erx_login_facet, started as the domain
%% service mints one, with the row's line as the manifest gives it, its text, in
%% front of a real erx_login. This module stands in for the export table, whose
%% owner/1 names a local process the grantee's and a remote one by its creation, and,
%% as erx_login_tests does, for the domain service and the passphrase checker.
-module(erx_login_facet_tests).
-include_lib("eunit/include/eunit.hrl").

-export([export/3, owner/1]).
-export([start_session_request/2, line_request/4, id/1, stop/2, check_request/4]).

-define(GRANTEE, 7).
-define(OTHER, 9).
-define(SENTINEL, <<"sentinel-passphrase-5c21">>).

%% The export table: the facet exports itself toward its grantee, and a name is the
%% grantee's when it is local, another domain's, by its creation, when it is remote.
export(_Pid, [send], ?GRANTEE) -> ok.

owner(Name) when node(Name) =:= node() ->
    ?GRANTEE;
owner(Pid) when is_pid(Pid) ->
    <<131, 88, 119, Length, _Node:Length/binary, _Number:32, _Serial:32, Creation:32>> = term_to_binary(Pid),
    Creation;
owner(Ref) when is_reference(Ref) ->
    <<131, 90, _Count:16, 119, Length, _Node:Length/binary, Creation:32, _Ids/binary>> = term_to_binary(Ref),
    Creation.

%% A process and a reply alias of domain ?OTHER's.
other_pid() ->
    binary_to_term(<<131, 88, 119, 9, "x@erxos11", 1:32, 0:32, ?OTHER:32>>).

other_ref() ->
    binary_to_term(<<131, 90, 3:16, 119, 9, "x@erxos11", ?OTHER:32, 1:32, 2:32, 3:32>>).

%% The domain service and the checker: each request goes to the stub server, which
%% records it and answers it (answer/1). A passphrase that begins with "leak" crashes the
%% service with a reason that holds it.
start_session_request(Principal, Start) -> gen_server:send_request(stub, {start, Principal, Start}).
line_request(Line, Session, Grantee, Facet) -> gen_server:send_request(stub, {mint, Line, Session, Grantee, Facet}).
id({erx_domain, Id, _Node, _Pid}) -> Id.
stop(_Session, _Reason) -> ok.

check_request(_User, <<"leak", _/binary>> = Passphrase, network, _Terminal) -> error({checker_crashed, Passphrase});
check_request(User, Passphrase, network, Terminal) ->
    gen_server:send_request(stub, {check, User, Passphrase, Terminal}).

stub(Seen) ->
    receive
        {'$gen_call', From, Request} ->
            gen:reply(From, answer(Request)),
            stub([Request | Seen]);
        {seen, Pid} ->
            Pid ! {seen, lists:reverse(Seen)},
            stub(Seen)
    end.

%% The passphrase "right" matches principal 42, whose session and line start; any
%% other matches none.
answer({check, _User, <<"right">>, _Terminal}) -> {match, 42};
answer({check, _User, _Passphrase, _Terminal}) -> no_match;
answer({start, _Principal, _Start}) -> {ok, {erx_domain, 9, node(), self()}};
answer({mint, _Line, _Session, _Grantee, _Facet}) -> {ok, self()}.

seen() ->
    stub ! {seen, self()},
    receive {seen, Seen} -> Seen end.

%% The service, with this module as its checker and domain edge, and the stub.
setup() ->
    true = register(stub, spawn(fun() -> stub([]) end)),
    {ok, Login} = erx_login:start_link(#{checker => ?MODULE, domain => ?MODULE}),
    unlink(Login),
    Login.

cleanup(Login) ->
    exit(Login, kill),
    exit(whereis(stub), kill),
    [wait_unregistered(Name) || Name <- [stub, erx_login]].

wait_unregistered(Name) ->
    case whereis(Name) of
        undefined -> ok;
        _Pid -> timer:sleep(5), wait_unregistered(Name)
    end.

with(Case) ->
    {setup, fun setup/0, fun cleanup/1, fun(Login) -> fun() -> Case(Login) end end}.

%% A facet of the login service for ?GRANTEE, as the domain service mints it
%% (erx_domain_srv:system_facet/4): Row's parameters as the manifest gives them, the
%% holder's manifest name, and every operation.
facet(Login, Row) ->
    Grant = maps:merge(#{grantee => ?GRANTEE, ends_with => [domain_pid(), Login], behind => Login,
                         line => <<"tty_line">>, logins => 16, holder => <<"ssh">>,
                         operations => [cookie, key_ok, login_key, login_passphrase]}, Row),
    {ok, Facet} = erx_facet:start(erx_login_facet, Grant, #{exports => ?MODULE}),
    Facet.

%% Holds until killed: the domain pid a facet ends with.
domain_pid() ->
    spawn(fun() -> receive after infinity -> ok end end).

%% A call of Request to Facet from domain D, from Caller with Alias as its reply tag:
%% the reply, or none if none came in 500 ms.
call(Facet, D, {Caller, Alias}, Request) ->
    Facet ! {erx_origin, D, {'$gen_call', {Caller, [alias | Alias]}, Request}},
    receive {[alias | Alias], Reply} -> Reply after 500 -> none end.

call(Facet, Request) ->
    call(Facet, ?GRANTEE, {self(), alias()}, Request).

passphrase(Passphrase) -> {login_passphrase, <<"alice">>, Passphrase, <<"peer">>}.

%% A front end's connection process, which lives until it is killed.
connection() -> spawn(fun() -> receive after infinity -> ok end end).

%% The row's line reaches the service as the name of ?ERX_LINES its text is, which a
%% login mints, and a text that names no line starts no facet.
%% A user name is a principal's name, a system identifier (docs/design-system.md,
%% "Identifiers"): every name a principal may have decodes, a digit or a hyphen in it
%% included, and nothing else does.
a_user_name_is_a_system_identifier_test() ->
    Login = fun(User) -> erx_login_facet:decode({login_passphrase, User, <<"pass">>, <<>>}) end,
    Longest = binary:copy(<<"a">>, 63),
    [?assertMatch({ok, _}, Login(User)) || User <- [<<"root">>, <<"my-app">>, <<"9lives">>, Longest]],
    [?assertEqual({error, badarg}, Login(User))
     || User <- [<<>>, <<"Root">>, <<"-x">>, <<"_x">>, <<"a.b">>, <<"a b">>, <<Longest/binary, "a">>, root]].

the_grant_s_line_is_the_row_s_test_() ->
    with(fun(Login) ->
        Facet = facet(Login, #{line => <<"web_line">>}),
        ?assertMatch({ok, _Line}, call(Facet, ?GRANTEE, {connection(), alias()}, passphrase(<<"right">>))),
        ?assertMatch([{mint, web_line, 9, ?GRANTEE, Facet}], [M || {mint, _, _, _, _} = M <- seen()]),
        ?assertEqual({error, unknown_line},
                     erx_facet:start(erx_login_facet,
                                     #{grantee => ?GRANTEE, ends_with => [domain_pid(), Login], behind => Login,
                                       line => <<"ssh_line">>, logins => 16, holder => <<"ssh">>},
                                     #{exports => ?MODULE}))
    end).

%% Forged caller: a call whose caller or reply alias names a process of another domain
%% is dropped by the facet and reaches no checker; one naming another process of the
%% grantee's acts on that process's row, which the service monitors, and on no row of
%% the sender's.
a_forged_caller_reaches_no_row_test_() ->
    with(fun(Login) ->
        Facet = facet(Login, #{}),
        ?assertEqual(none, call(Facet, ?GRANTEE, {other_pid(), alias()}, passphrase(<<"x">>))),
        ?assertEqual(none, call(Facet, ?GRANTEE, {self(), other_ref()}, passphrase(<<"x">>))),
        ?assertEqual([], seen()),
        Owner = connection(),
        {ok, _Cookie} = call(Facet, ?GRANTEE, {Owner, alias()}, cookie),
        {monitors, Monitors} = process_info(Login, monitors),
        ?assertEqual([Owner], [Pid || {process, Pid} <- Monitors]),
        ?assertMatch({ok, _}, call(Facet, cookie))
    end).

%% The terminal a passphrase is counted at is the holder's: the same peer through the
%% grants of two holders reaches the checker as two terminals.
the_terminal_is_the_grant_s_holder_test_() ->
    with(fun(Login) ->
        {error, no_match} = call(facet(Login, #{}), passphrase(<<"x">>)),
        {error, no_match} = call(facet(Login, #{line => <<"web_line">>, holder => <<"web">>}), passphrase(<<"x">>)),
        ?assertEqual([{<<"ssh">>, <<"peer">>}, {<<"web">>, <<"peer">>}], [T || {check, _, _, T} <- seen()])
    end).

%% The facet's process is sensitive from its init on: a request held in its queue is not
%% readable from outside.
the_facet_s_queue_is_hidden_test_() ->
    with(fun(Login) ->
        Facet = facet(Login, #{}),
        true = erlang:suspend_process(Facet),
        Facet ! {erx_origin, ?GRANTEE, {'$gen_call', {self(), [alias | alias()]}, passphrase(?SENTINEL)}},
        {messages, Held} = process_info(Facet, messages),
        true = erlang:resume_process(Facet),
        ?assertEqual(nomatch, binary:match(term_to_binary(Held), ?SENTINEL))
    end).

%% The secrets: the login service crashes with the sentinel passphrase in its reason,
%% and the 'DOWN' a monitor of another front end's facet in front of it receives is an
%% atom, with no byte of the passphrase.
another_front_end_sees_no_passphrase_test_() ->
    with(fun(Login) ->
        Caller = facet(Login, #{}),
        Other = facet(Login, #{line => <<"web_line">>, holder => <<"web">>}),
        Monitor = monitor(process, Other),
        call(Caller, passphrase(<<"leak", (?SENTINEL)/binary>>)),
        Reason = receive {'DOWN', Monitor, process, Other, R} -> R after 1000 -> timeout end,
        ?assertEqual(checker_crashed, Reason),
        ?assertEqual(nomatch, binary:match(term_to_binary(Reason), ?SENTINEL))
    end).
