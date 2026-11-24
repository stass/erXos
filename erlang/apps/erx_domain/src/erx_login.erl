%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_login).
-moduledoc """
The login service (docs/design-login.md, "The service and its facet"): the
process of the system domain behind every front end's login facet
(erx_login_facet), the owner of the table of logins, whose decisions are
erx_login_core's. Each request the facet forwards, `{login, Request, Caller,
Grant}`, and each answer to one of its own steps is handed to the core, and
the service carries out the effects the core answers: replies, the owner's
monitor, a cookie's grace, the passphrase check, a session's start and the
line's mint as asynchronous requests, a failed mint's stop. It never waits on
a step, so the logins of a grant in flight wait on their checks together.

A start names the owner and the facet in its ends_with, so the domain service
stops the session when either ends (G2): the service keeps no link to a
session and checks no row after a start returns.

Secrets (docs/design-login.md, "Secrets"): init/1 marks the process sensitive
before it registers its name or serves the interface, so no request reaches
it before its heap, stack and queue are kept out of a crash dump, and
format_status/1 goes through erx_report:status/2, whose view shows each row by
its state and the counts alone, and every message and reason by its leading
atom. A passphrase passes from the request into the check and is kept
nowhere.

No passphrase checker exists yet (docs/design-login.md, "The passphrase
check", and its open decision 1): with none, a check answers `unavailable`,
so no front end logs anyone in by passphrase. `checker` in start_link/1's
options names one, a module whose check_request/4 sends the check and returns
its request id. The key login's verifier and the principal's login keys are
package 4's: key_ok and login_key answer `unavailable` until then.
`domain`, the module that starts, mints and stops sessions, is erx_domain
unless a test names a stand-in.
""".
-behaviour(gen_server).

-export([start_link/0, start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-include("erx_login.hrl").

-type options() :: #{checker => module() | none, domain => module()}.

-doc "Starts the service with no checker and erx_domain as its domain edge.".
-spec start_link() -> gen_server:start_ret().
start_link() -> start_link(#{}).

-doc "Starts the service with Options, registered as erx_login once it is sensitive.".
-spec start_link(options()) -> gen_server:start_ret().
start_link(Options) -> gen_server:start_link(?MODULE, Options, []).

-doc false.
init(Options) ->
    process_flag(sensitive, true),
    true = register(erx_login, self()),
    ok = erx_facet:serve(login, self()),
    {ok, #{core => erx_login_core:new(),
           checker => maps:get(checker, Options, none),
           domain => maps:get(domain, Options, erx_domain),
           monitors => #{},
           requests => gen_server:reqids_new()}}.

-doc false.
handle_call({login, {login_passphrase, User, Passphrase, Peer}, Caller, Grant}, From, S) ->
    {noreply, core({request, Caller, Grant, From, {login_passphrase, User, Passphrase, Peer}}, S)};
handle_call({login, cookie, Caller, Grant}, From, S) ->
    {noreply, core({request, Caller, Grant, From, {cookie, entropy()}}, S)};
handle_call({login, _KeyRequest, _Caller, _Grant}, _From, S) ->
    {reply, {error, unavailable}, S};
handle_call(_Request, _From, S) ->
    {reply, {error, badarg}, S}.

-doc false.
handle_cast(_Message, S) -> {noreply, S}.

-doc false.
handle_info({'DOWN', Monitor, process, Owner, _Reason}, #{monitors := Monitors} = S) ->
    case Monitors of
        #{Owner := Monitor} -> {noreply, core({down, Owner}, S#{monitors := maps:remove(Owner, Monitors)})};
        #{} -> {noreply, S}
    end;
handle_info({'$erx_login_grace', Step}, S) ->
    {noreply, core({grace, Step}, S)};
handle_info({'$erx_login_unchecked', Step}, S) ->
    {noreply, core({answer, Step, unavailable}, S)};
handle_info(Message, #{requests := Requests} = S) ->
    case gen_server:check_response(Message, Requests, true) of
        {Response, Step, Rest} -> {noreply, core({answer, Step, answered(Response)}, S#{requests := Rest})};
        _NotOurs -> {noreply, S}
    end.

-doc false.
format_status(Status) ->
    erx_report:status(Status, #{state => fun view/1}).

%% What a report shows of the service: each row's state and how many monitors it
%% holds, never a cookie, a request or a session.
view(#{core := Core, monitors := Monitors}) ->
    #{rows => maps:values(erx_login_core:rows(Core)), monitors => map_size(Monitors)};
view(_State) ->
    hidden.

%% A step's answer as the core reads it: the server's reply, or failed when the
%% server ended before it answered.
answered({reply, Reply}) -> Reply;
answered({error, {_Reason, _Server}}) -> {error, failed}.

entropy() ->
    try {ok, erx_bytes:entropy(?ERX_LOGIN_COOKIE_BYTES)}
    catch error:_ -> error
    end.

core(Event, #{core := Core} = S) ->
    {Core1, Effects} = erx_login_core:step(Event, Core),
    lists:foldl(fun carry/2, S#{core := Core1}, Effects).

carry({reply, From, Answer}, S) ->
    gen_server:reply(From, Answer),
    S;
carry({monitor, Owner}, #{monitors := Monitors} = S) ->
    S#{monitors := Monitors#{Owner => monitor(process, Owner)}};
carry({demonitor, Owner}, #{monitors := Monitors} = S) ->
    demonitor(maps:get(Owner, Monitors), [flush]),
    S#{monitors := maps:remove(Owner, Monitors)};
carry({arm_grace, Step}, S) ->
    erlang:send_after(?ERX_LOGIN_GRACE_MS, self(), {'$erx_login_grace', Step}),
    S;
carry({check, Step, _User, _Passphrase, network, _Terminal}, #{checker := none} = S) ->
    self() ! {'$erx_login_unchecked', Step},
    S;
carry({check, Step, User, Passphrase, network, Terminal}, #{checker := Checker} = S) ->
    requested(Checker:check_request(User, Passphrase, network, Terminal), Step, S);
carry({start, Step, Principal, Start}, #{domain := Domain} = S) ->
    requested(Domain:start_session_request(Principal, Start), Step, S);
carry({mint, Step, Line, Session, Grantee, Facet}, #{domain := Domain} = S) ->
    requested(Domain:line_request(Line, Domain:id(Session), Grantee, Facet), Step, S);
carry({stop, Session}, #{domain := Domain} = S) ->
    ok = Domain:stop(Session, shutdown),
    S;
carry({log, What, Reason}, S) ->
    logger:error("erx_login: ~ts: ~0P", [What, Reason, 8]),
    S.

requested(Request, Step, #{requests := Requests} = S) ->
    S#{requests := gen_server:reqids_add(Request, Step, Requests)}.
