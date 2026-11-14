%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The host tests of erXos's edits to OTP's ssh (docs/design-ssh.md, "Edits
%% to OTP's ssh" and "Verification"), run on stock OTP's runtime with
%% erXos's ssh modules ahead of stock's on the code path
%% (test/host/erx_ssh_edits_test.rb builds them):
%%
%% * for each key exchange the daemon offers, a client logs in with an
%%   Ed25519 key, once offering the strict key exchange and once from a
%%   peer node whose ssh_transport does not offer it
%%   (ERX_SSH_NOSTRICT_EBIN); the server's first SSH_MSG_KEXINIT carries
%%   the cookie kex_cookie/1 answered, and erx_ssh_edits_keys:verify_user/6
%%   checks the signature over the SHA-256 of the input it is given;
%% * a rekeying after the login asks no cookie and keeps no input;
%% * the input is gone after a login by either method, and neither
%%   sys:get_status/1 nor a terminating handler's report quotes it or the
%%   shared secret;
%% * max_auth_tries disconnects at its count, as FreeBSD counts MaxAuthTries,
%%   and its default does not;
%% * a host key callback may answer {ssh2_pubkey, Blob} and sign in sign/3;
%% * a callback module written for stock OTP sees no change.
-module(erx_ssh_edits_tests).

-include_lib("eunit/include/eunit.hrl").
-include("ssh.hrl").
-include("ssh_transport.hrl").
-include("ssh_auth.hrl").
-include("ssh_connect.hrl").
-include("ssh_fsm.hrl").

%% The logger handler that hands the test each event of a terminating handler.
-export([log/2]).

-define(COOKIE_TEXT, "erx-ssh-cookie16").
-define(COOKIE, <<?COOKIE_TEXT>>).
-define(USER, "erx").
-define(KEXES, ['curve25519-sha256', 'curve25519-sha256@libssh.org',
                'ecdh-sha2-nistp256', 'mlkem768x25519-sha256']).

%%% Logging in, for each exchange, with and without the strict key exchange

login_test_() ->
    {setup, fun start/0, fun stop/1,
     [{timeout, 60, {atom_to_list(Kex) ++ " " ++ atom_to_list(Client),
                     fun() -> login(Kex, Client) end}}
      || Kex <- ?KEXES, Client <- [strict, nostrict]]}.

login(Kex, Client) ->
    {Host, User} = keys(),
    {Daemon, Port} = daemon(erx_ssh_edits_keys, conf(Host, User), []),
    try
        Sid = connect(Client, Port, User, Kex),
        Server = receive {kex_cookie, Pid, ?COOKIE} -> Pid after 5000 -> error(no_kex_cookie) end,
        {Input, AlgSig} = receive {verify_user, Server, I, S} -> {I, S} after 5000 -> error(no_verify_user) end,
        ?assertEqual(83, byte_size(AlgSig)),
        [_VC, _VS, _IC, IS, HostKey | _] = strings(Input, 5),
        ?assertMatch(<<?SSH_MSG_KEXINIT, ?COOKIE_TEXT, _/binary>>, IS),
        ?assertEqual(ssh_message:ssh2_pubkey_encode(Host), HostKey),
        ?assertEqual(Sid, crypto:hash(sha256, Input)),
        #ssh{kex_input = Left, kex_strict_negotiated = Strict} = ssh_params(Server),
        ?assertEqual(undefined, Left),
        ?assertEqual(Client =:= strict, Strict),
        refute_message(kex_cookie)
    after
        ssh:stop_daemon(Daemon)
    end.

%% Logs in and answers the client's session identifier; a nostrict client
%% runs in a peer node whose ssh_transport offers no strict key exchange.
connect(strict, Port, User, Kex) ->
    {ok, C} = ssh:connect({127,0,0,1}, Port, client_opts(User, Kex)),
    #ssh{session_id = Sid} = ssh_params(C),
    ssh:close(C),
    Sid;
connect(nostrict, Port, User, Kex) ->
    Here = filename:dirname(code:which(?MODULE)),
    NoStrict = os:getenv("ERX_SSH_NOSTRICT_EBIN"),
    Args = ["-pa", os:getenv("ERX_SSH_EBIN"), Here],
    Peer = case peer:start_link(#{connection => standard_io, args => Args,
                                  exec => filename:join([code:root_dir(), "bin", "erl"])}) of
               {ok, P} -> P;
               {ok, P, _} -> P
           end,
    try
        true = peer:call(Peer, code, add_patha, [NoStrict]),
        NoStrict = filename:dirname(peer:call(Peer, code, which, [ssh_transport])),
        {ok, _} = peer:call(Peer, application, ensure_all_started, [ssh]),
        {ok, C} = peer:call(Peer, ssh, connect, [{127,0,0,1}, Port, client_opts(User, Kex)], 30000),
        {_, #data{ssh_params = #ssh{session_id = Sid}}} = peer:call(Peer, sys, get_state, [C]),
        Sid
    after
        peer:stop(Peer)
    end.

%%% A rekeying after the login: no cookie asked, no input kept

rekey_test_() ->
    {setup, fun start/0, fun stop/1, {timeout, 60, fun rekey/0}}.

rekey() ->
    {Host, User} = keys(),
    {Daemon, Port} = daemon(erx_ssh_edits_keys, conf(Host, User), []),
    try
        {ok, C} = ssh:connect({127,0,0,1}, Port, client_opts(User, 'curve25519-sha256')),
        Server = receive {kex_cookie, Pid, ?COOKIE} -> Pid after 5000 -> error(no_kex_cookie) end,
        #ssh{session_id = Sid, s_keyinit = <<?SSH_MSG_KEXINIT, ?COOKIE_TEXT, _/binary>>} = ssh_params(C),
        %% A rekeying starts only from the connected state, which follows
        %% the server's ext_info.
        wait(fun() -> element(1, sys:get_state(C)) =:= {connected, client} end),
        ok = ssh_connection_handler:renegotiate(C),
        wait(fun() -> case ssh_params(C) of
                          #ssh{s_keyinit = <<?SSH_MSG_KEXINIT, ?COOKIE_TEXT, _/binary>>} -> false;
                          #ssh{} -> true
                      end
             end),
        %% The server's exchange is over once it is connected again, or
        %% waits for the client's next packet after its ext_info.
        wait(fun() -> case element(1, sys:get_state(Server)) of
                          {connected, server} -> true;
                          {ext_info, server, renegotiate} -> true;
                          _ -> false
                      end
             end),
        #ssh{session_id = Sid, kex_input = undefined} = ssh_params(Server),
        refute_message(kex_cookie),
        ssh:close(C)
    after
        ssh:stop_daemon(Daemon)
    end.

%%% The input's end, and the status reports

%% A keyboard-interactive login clears the input, as a key login does above.
keyboard_interactive_test_() ->
    {setup, fun start/0, fun stop/1, {timeout, 60, fun keyboard_interactive/0}}.

keyboard_interactive() ->
    {Host, User} = keys(),
    {Daemon, Port} = daemon(erx_ssh_edits_keys, conf(Host, User), kbd_daemon_opts()),
    try
        {ok, C} = ssh:connect({127,0,0,1}, Port, kbd_client_opts(fun(_, _, _) -> ["right"] end)),
        Server = receive {kex_cookie, Pid, ?COOKIE} -> Pid after 5000 -> error(no_kex_cookie) end,
        ?assertMatch(#ssh{authenticated = true, kex_input = undefined}, ssh_params(Server)),
        ssh:close(C)
    after
        ssh:stop_daemon(Daemon)
    end.

status_test_() ->
    {setup, fun start/0, fun stop/1, {timeout, 60, fun status/0}}.

status() ->
    {Host, User} = keys(),
    {Daemon, Port} = daemon(erx_ssh_edits_keys, conf(Host, User), kbd_daemon_opts()),
    Test = self(),
    Answer = fun(_, _, _) -> Test ! waiting, receive go -> ["right"] after 10000 -> [] end end,
    Client = spawn(fun() -> ssh:connect({127,0,0,1}, Port, kbd_client_opts(Answer)) end),
    try
        Server = receive {kex_cookie, Pid, ?COOKIE} -> Pid after 5000 -> error(no_kex_cookie) end,
        receive waiting -> ok after 5000 -> error(not_waiting) end,
        #ssh{kex_input = Input, shared_secret = Secret} = ssh_params(Server),
        ?assertMatch({_, _}, binary:match(Input, ?COOKIE)),
        ?assert(is_binary(Secret) andalso byte_size(Secret) >= 32),
        Status = sys:get_status(Server),
        ?assert(holds(Status, '****')),
        ?assertNot(holds(Status, Input)),
        ?assertNot(holds(Status, Secret)),
        ok = logger:add_handler(erx_ssh_edits, ?MODULE, #{config => #{test => Test}}),
        try
            sys:terminate(Server, erx_ssh_edits_error),
            Report = receive {log, #{msg := {report, #{label := {gen_statem, terminate}}}} = E} -> E
                     after 5000 -> error(no_terminate_report)
                     end,
            ?assert(holds(Report, '****')),
            ?assertNot(holds(Report, Input)),
            ?assertNot(holds(Report, Secret))
        after
            logger:remove_handler(erx_ssh_edits)
        end
    after
        Client ! go,
        ssh:stop_daemon(Daemon)
    end.

log(Event, #{config := #{test := Test}}) ->
    Test ! {log, Event}.

%%% max_auth_tries

%% FreeBSD's sshd counts MaxAuthTries so (auth2.c, userauth_finish): every
%% failure counts but a first "none" request, and the failure that brings the
%% count to the maximum is answered with a disconnect.
auth_tries_test_() ->
    {setup, fun start/0, fun stop/1,
     [fun disconnects_at_max/0, fun first_none_is_free/0, fun later_none_counts/0,
      fun success_within_max/0, fun keyboard_interactive_counts/0, fun default_is_infinity/0]}.

disconnects_at_max() ->
    Ssh1 = refused(password("wrong"), auth_ssh([{max_auth_tries, 2}])),
    ?assertThrow({keep_state_and_data,
                  [{next_event, internal,
                    {send_disconnect, ?SSH_DISCONNECT_NO_MORE_AUTH_METHODS_AVAILABLE, _, _, _}}]},
                 ssh_auth:handle_userauth_request(password("wrong"), <<"sid">>, Ssh1)).

first_none_is_free() ->
    Ssh1 = refused(none(), auth_ssh([{max_auth_tries, 2}])),
    Ssh2 = refused(password("wrong"), Ssh1),
    ?assertThrow({keep_state_and_data, [_]},
                 ssh_auth:handle_userauth_request(password("wrong"), <<"sid">>, Ssh2)).

later_none_counts() ->
    Ssh1 = refused(none(), auth_ssh([{max_auth_tries, 2}])),
    Ssh2 = refused(password("wrong"), Ssh1),
    ?assertThrow({keep_state_and_data, [_]},
                 ssh_auth:handle_userauth_request(none(), <<"sid">>, Ssh2)).

success_within_max() ->
    Ssh1 = refused(password("wrong"), auth_ssh([{max_auth_tries, 2}])),
    ?assertMatch({authorized, ?USER, _},
                 ssh_auth:handle_userauth_request(password("right"), <<"sid">>, Ssh1)).

keyboard_interactive_counts() ->
    Ssh1 = refused(password("wrong"), auth_ssh([{max_auth_tries, 2}])),
    Response = #ssh_msg_userauth_info_response{num_responses = 1, data = <<5:32, "wrong">>},
    ?assertThrow({keep_state_and_data, [_]},
                 ssh_auth:handle_userauth_info_response(Response, Ssh1#ssh{user = ?USER,
                                                                           kb_tries_left = 3})).

default_is_infinity() ->
    lists:foldl(fun(_, Ssh) -> refused(password("wrong"), refused(none(), Ssh)) end,
                auth_ssh([]), lists:seq(1, 20)).

auth_ssh(Extra) ->
    Opts = ssh_options:handle_options(server, [{pwdfun, fun(_, P) -> P =:= "right" end} | Extra]),
    #ssh{role = server, opts = Opts, service = "ssh-connection",
         userauth_supported_methods = "password,keyboard-interactive"}.

refused(Request, Ssh0) ->
    {not_authorized, _, {#ssh_msg_userauth_failure{}, Ssh}} =
        ssh_auth:handle_userauth_request(Request, <<"sid">>, Ssh0),
    Ssh.

password(P) ->
    #ssh_msg_userauth_request{user = ?USER, service = "ssh-connection", method = "password",
                              data = <<0, (length(P)):32, (list_to_binary(P))/binary>>}.

none() ->
    #ssh_msg_userauth_request{user = ?USER, service = "ssh-connection", method = "none", data = <<>>}.

%%% Host keys the callback holds: {ssh2_pubkey, Blob} and sign/3

host_key_test_() ->
    {setup, fun start/0, fun stop/1,
     [{timeout, 60, fun host_key_blob/0}, fun host_key_blob_needs_sign/0,
      fun host_key_blob_canonical/0]}.

host_key_blob() ->
    {Host, User} = keys(),
    {Daemon, Port} = daemon(erx_ssh_edits_keys, (conf(Host, User))#{host_form => blob}, []),
    try
        Sid = connect(strict, Port, User, 'curve25519-sha256'),
        Server = receive {kex_cookie, Pid, ?COOKIE} -> Pid after 5000 -> error(no_kex_cookie) end,
        receive {sign, Server, Sid} -> ok after 5000 -> error(no_sign) end
    after
        ssh:stop_daemon(Daemon)
    end.

host_key_blob_needs_sign() ->
    {Host, User} = keys(),
    Opts = key_cb_opts(erx_ssh_edits_plain_keys, (conf(Host, User))#{host_form => blob}),
    ?assertExit({error, bad_hostkey}, ssh_transport:get_host_key('ssh-ed25519', Opts)).

host_key_blob_canonical() ->
    {Host, User} = keys(),
    Opts = key_cb_opts(erx_ssh_edits_keys, (conf(Host, User))#{host_form => padded}),
    ?assertExit({error, bad_hostkey}, ssh_transport:get_host_key('ssh-ed25519', Opts)).

%%% A callback module written for stock OTP, and a refused cookie

stock_test_() ->
    {setup, fun start/0, fun stop/1,
     [{timeout, 60, fun stock_module/0}, {timeout, 60, fun cookie_not_16_bytes/0}]}.

stock_module() ->
    {Host, User} = keys(),
    {Daemon, Port} = daemon(erx_ssh_edits_plain_keys, conf(Host, User), []),
    try
        <<_:32/binary>> = connect(strict, Port, User, 'curve25519-sha256'),
        refute_message(kex_cookie)
    after
        ssh:stop_daemon(Daemon)
    end.

cookie_not_16_bytes() ->
    {Host, User} = keys(),
    {Daemon, Port} = daemon(erx_ssh_edits_keys, (conf(Host, User))#{cookie => <<"short">>}, []),
    try
        ?assertMatch({error, _},
                     ssh:connect({127,0,0,1}, Port, client_opts(User, 'curve25519-sha256')))
    after
        ssh:stop_daemon(Daemon)
    end.

%%% Helpers

start() ->
    {ok, _} = application:ensure_all_started(ssh),
    ok.

stop(_) -> ok.

keys() ->
    {public_key:generate_key({namedCurve, ed25519}), public_key:generate_key({namedCurve, ed25519})}.

conf(Host, User) ->
    #{test => self(), host => Host, host_form => private,
      user => ssh_file:extract_public_key(User), cookie => ?COOKIE}.

daemon(Module, Conf, Extra) ->
    {ok, Daemon} = ssh:daemon({127,0,0,1}, 0,
                              [{key_cb, {Module, [{conf, Conf}]}},
                               {auth_methods, "publickey"},
                               {preferred_algorithms, [{public_key, ['ssh-ed25519']}]}
                               | Extra]),
    [{port, Port}] = ssh:daemon_info(Daemon, [port]),
    {Daemon, Port}.

kbd_daemon_opts() ->
    [{auth_methods, "keyboard-interactive"}, {pwdfun, fun(_, P) -> P =:= "right" end}].

client_opts(User, Kex) ->
    [{user, ?USER}, {key_cb, {erx_ssh_edits_client_keys, [{conf, User}]}},
     {auth_methods, "publickey"}, {user_interaction, false},
     {preferred_algorithms, [{kex, [Kex]}, {public_key, ['ssh-ed25519']}]}].

kbd_client_opts(Answer) ->
    [{user, ?USER}, {key_cb, {erx_ssh_edits_client_keys, [{conf, undefined}]}},
     {auth_methods, "keyboard-interactive"}, {user_interaction, true},
     {keyboard_interact_fun, Answer}].

key_cb_opts(Module, Conf) ->
    ssh_options:handle_options(server, [{key_cb, {Module, [{conf, Conf}]}}]).

ssh_params(Connection) ->
    {_State, #data{ssh_params = Ssh}} = sys:get_state(Connection),
    Ssh.

%% The first N length-prefixed strings of Bin, and what follows them.
strings(Bin, 0) -> [Bin];
strings(<<Len:32, S:Len/binary, Rest/binary>>, N) -> [S | strings(Rest, N - 1)].

%% Whether Term holds Needle: a binary that is or contains it, or the atom.
holds(Needle, Needle) -> true;
holds(Bin, Needle) when is_binary(Bin), is_binary(Needle) -> binary:match(Bin, Needle) =/= nomatch;
holds(List, Needle) when is_list(List) -> holds_list(List, Needle);
holds(Tuple, Needle) when is_tuple(Tuple) -> holds_list(tuple_to_list(Tuple), Needle);
holds(Map, Needle) when is_map(Map) -> holds_list(maps:to_list(Map), Needle);
holds(_, _) -> false.

%% An improper list's tail counts as an element.
holds_list([H | T], Needle) -> holds(H, Needle) orelse holds_list(T, Needle);
holds_list([], _) -> false;
holds_list(Tail, Needle) -> holds(Tail, Needle).

refute_message(Tag) ->
    receive Msg when element(1, Msg) =:= Tag -> error({unexpected, Msg}) after 200 -> ok end.

wait(Done) -> wait(Done, 50).
wait(_Done, 0) -> error(timeout);
wait(Done, N) ->
    case Done() of
        true -> ok;
        false -> timer:sleep(100), wait(Done, N - 1)
    end.
