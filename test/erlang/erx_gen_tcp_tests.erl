%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gen_tcp_tests).
-moduledoc """
EUnit cases of erx_gen_tcp's calls outside an open connection
(docs/design-network-stack.md, "The backend"): the calls the backend does not offer
answer `{error, enotsup}`, a host name given to `connect/4` resolves through inet's own
path before the grant is asked, and a listener of another domain than its socket
process's, which can link only to a process that exported `link` to it, takes an accept.
Each grant is a stand-in process named by the `erx_net_client` application's `grant`
key: for the connects, one that reports each request to the test and refuses it; for the
listener, one of another domain with a stand-in listener. The host name comes from
inet_db's own hosts table, with `file` the only lookup method, so the case needs no
network.
""".

-include_lib("eunit/include/eunit.hrl").

-define(WAIT, 3000).

unsupported_test_() ->
    [{"fdopen is not offered", ?_assertEqual({error, enotsup}, erx_gen_tcp:fdopen(3, []))},
     {"connect with a socket-address map is not offered",
      ?_assertEqual({error, enotsup},
                    erx_gen_tcp:connect(#{family => inet, addr => {10, 0, 2, 2}, port => 80}, [], 1000))}].

%% An option stock takes but the backend does not, `{packet, 4}`, is refused before any
%% socket process starts: the caller, traced for its spawns, spawns nothing. The tracer is
%% a process of its own, since a process is sent no trace of itself.
bad_option_starts_nothing_test() ->
    Tracer = spawn_link(fun() -> receive {traced, From} -> From ! {traces, traces([])} end end),
    1 = erlang:trace(self(), true, [procs, {tracer, Tracer}]),
    try
        ?assertEqual({error, einval}, erx_gen_tcp:connect({127, 0, 0, 1}, 1, [{packet, 4}], 1000)),
        ?assertEqual({error, einval}, erx_gen_tcp:listen(0, [{packet, 4}]))
    after
        erlang:trace(self(), false, [procs])
    end,
    Ref = erlang:trace_delivered(self()),
    receive {trace_delivered, _, Ref} -> ok end,
    Tracer ! {traced, self()},
    receive {traces, Traces} -> ?assertEqual([], [Pid || {trace, _, spawn, Pid, _} <- Traces]) end.

traces(Acc) ->
    receive Trace -> traces([Trace | Acc])
    after 0 -> lists:reverse(Acc)
    end.

%% A connection that crashes while it holds a call answers as a closed socket, whatever its
%% reason, so no crash of the stack reaches the caller.
crashed_connection_test() ->
    Conn = spawn(fun() -> receive {'$gen_call', _, _} -> exit(boom) end end),
    ?assertEqual({error, closed}, erx_gen_tcp:recv({'$inet', erx_gen_tcp, Conn}, 0, 1000)).

host_name_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [{"a host name is resolved and each address tried in turn", fun connect_resolves/0},
      {"an unknown host name fails as inet's lookup does", fun connect_unknown/0},
      {"an address list is refused", ?_assertEqual({error, einval}, erx_gen_tcp:connect(<<"peer">>, 80, [], 1000))}]}.

setup() ->
    Lookup = inet_db:res_option(lookup),
    ok = inet_db:set_lookup([file]),
    ok = inet_db:add_host({192, 0, 2, 10}, ["peer.erxos.test"]),
    ok = inet_db:add_host({192, 0, 2, 11}, ["peer.erxos.test"]),
    Lookup.

cleanup(Lookup) ->
    ok = inet_db:del_host({192, 0, 2, 10}),
    ok = inet_db:del_host({192, 0, 2, 11}),
    ok = inet_db:set_lookup(Lookup).

%% Runs Case with a stand-in grant that reports each request to this process and
%% refuses it, as a peer that answers RST does.
with_grant(Case) ->
    Self = self(),
    Grant = spawn(fun() -> grant(Self) end),
    ok = application:set_env(erx_net_client, grant, {erlang, apply, [fun() -> {ok, Grant, local} end, []]}),
    try Case()
    after
        exit(Grant, kill),
        ok = application:unset_env(erx_net_client, grant)
    end.

grant(Test) ->
    receive
        {'$gen_call', From, Request} ->
            Test ! {grant, Request},
            gen_server:reply(From, {error, econnrefused}),
            grant(Test)
    end.

connect_resolves() ->
    with_grant(fun connect_resolves_case/0).

connect_resolves_case() ->
    ?assertEqual({error, econnrefused}, erx_gen_tcp:connect("peer.erxos.test", 80, [binary], 1000)),
    Asked = [receive {grant, {tcp_connect, inet, Address, 80, [], _Timeout}} -> Address
             after ?WAIT -> none end || _ <- [1, 2]],
    ?assertEqual([{192, 0, 2, 10}, {192, 0, 2, 11}], lists:sort(Asked)),
    receive {grant, Extra} -> ?assertEqual(none, Extra) after 0 -> ok end.

connect_unknown() ->
    with_grant(fun connect_unknown_case/0).

connect_unknown_case() ->
    ?assertEqual({error, nxdomain}, erx_gen_tcp:connect("absent.erxos.test", 80, [], 1000)),
    receive {grant, Request} -> ?assertEqual(none, Request) after 0 -> ok end.

%% --- A listener in another domain --------------------------------------------------------

%% On erXos a domain holds only `send` on a pid it was handed, so its link to that pid fails
%% as a link to a dead process does (docs/design-domains.md, "Exports"), and a listener whose
%% link to its socket process fails ends at the `noproc`. The stand-in network domain, of id
%% ?NET, links where the funnel would let it, to a process that exported `send` and `link`
%% to ?NET, and, beyond the funnel, only where the export came after the process trapped
%% exits, as the design requires of a socket process (docs/design-network-stack.md, "Two
%% places, four seams"). A link it would not make ends its listener. So the
%% listening socket's process, before the grant starts its listener, and each accept's
%% socket process, before the listener takes the accept, must expose themselves to the
%% grant's domain, or the accept answers `{error, closed}` at once.
-define(NET, 7).

listener_in_another_domain_test() ->
    with_erx_exports(fun() -> with_net_grant(fun listener_in_another_domain/0) end).

listener_in_another_domain() ->
    {ok, L} = erx_gen_tcp:listen(0, [binary, {active, false}]),
    ?assertEqual({error, timeout}, erx_gen_tcp:accept(L, 100)),
    ?assertEqual(ok, erx_gen_tcp:close(L)).

%% Runs Fun with a stand-in of erx whose export/3 records what each name exports to whom,
%% and whether the name trapped exits then, in the table erx_exports.
with_erx_exports(Fun) ->
    Text = ["-module(erx).", "-export([export/3]).",
            "export(Name, Rights, Peer) ->"
            "    {trap_exit, Traps} = erlang:process_info(Name, trap_exit),"
            "    true = ets:insert(erx_exports, {{Name, Peer}, Rights, Traps}),"
            "    ok."],
    {ok, erx, Beam} = compile:forms(lists:map(fun parse_form/1, Text)),
    {module, erx} = code:load_binary(erx, "erx.erl", Beam),
    erx_exports = ets:new(erx_exports, [named_table, public]),
    try Fun()
    after
        ets:delete(erx_exports),
        code:purge(erx),
        code:delete(erx)
    end.

parse_form(Text) ->
    {ok, Tokens, _} = erl_scan:string(Text),
    {ok, Form} = erl_parse:parse_form(Tokens),
    Form.

%% Whether the stand-in network domain links to Pid.
linkable(Pid) ->
    case ets:lookup(erx_exports, {Pid, ?NET}) of
        [{_, Rights, true}] -> lists:member(send, Rights) andalso lists:member(link, Rights);
        _ -> false
    end.

%% Runs Case with the grant key naming a stand-in grant of the domain ?NET, which starts a
%% stand-in listener for each listen.
with_net_grant(Case) ->
    Grant = spawn(fun net_grant/0),
    ok = application:set_env(erx_net_client, grant, {erlang, apply, [fun() -> {ok, Grant, ?NET} end, []]}),
    try Case()
    after
        exit(Grant, kill),
        ok = application:unset_env(erx_net_client, grant)
    end.

net_grant() ->
    receive
        {'$gen_call', {Socket, _} = From, {tcp_listen, inet, any, 0, _Opts}} ->
            gen_server:reply(From, {ok, spawn(fun() -> net_listener(Socket) end)}),
            net_grant()
    end.

%% A listener that links to its socket process as erx_tcp_listen does, answers an accept,
%% once linked to its socket process, with the deadline, and answers close.
net_listener(Socket) ->
    case linkable(Socket) of
        true -> true = link(Socket), net_listening(Socket);
        false -> exit(normal)
    end.

net_listening(Socket) ->
    receive
        {erx_net, Socket, {call, N, {accept, Acceptor, _Timeout}}} ->
            case linkable(Acceptor) of
                true ->
                    true = link(Acceptor),
                    net_reply(Socket, N, {error, timeout}),
                    net_listening(Socket);
                false ->
                    exit(normal)
            end;
        {erx_net, Socket, {call, N, close}} ->
            net_reply(Socket, N, ok)
    end.

net_reply(Socket, N, Reply) ->
    Socket ! {erx_origin, ?NET, {erx_net, self(), {reply, N, Reply}}}.

%% --- Stock's end of a stream ----------------------------------------------------------

%% What erx_gen_tcp_core's end follows (docs/design-network-stack.md, "The socket
%% process"), shown on the oracle's own gen_tcp over loopback: a passive socket meets the
%% peer's FIN only when it reads, so its sends go on, a recv the FIN leaves short answers
%% `{error, closed}`, every recv after it `{error, enotconn}` and a send `{error, closed}`
%% (inet_drv's tcp_recv_closed); and once an active count runs out, the bytes and the FIN
%% wait for the owner to re-arm.
stock_end_test_() ->
    [{"stock: passive sends go on after the FIN until a recv meets it", fun stock_passive_end/0},
     {"stock: the end waits for an owner whose once ran out", fun stock_once_end/0}].

%% A connected pair on loopback: ours with Opts, the peer's passive.
stock_pair(Opts) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    {ok, Ours} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary | Opts], ?WAIT),
    {ok, Peer} = gen_tcp:accept(L, ?WAIT),
    ok = gen_tcp:close(L),
    {Ours, Peer}.

%% The FIN reaches our kernel; nothing on our side reads it.
fin_arrives() ->
    timer:sleep(200).

stock_passive_end() ->
    {Ours, Peer} = stock_pair([{active, false}]),
    ok = gen_tcp:send(Peer, <<"tail">>),
    ok = gen_tcp:shutdown(Peer, write),
    fin_arrives(),
    ?assertEqual(ok, gen_tcp:send(Ours, <<"x">>)),
    ?assertEqual({ok, <<"x">>}, gen_tcp:recv(Peer, 1, ?WAIT)),
    ?assertEqual({error, closed}, gen_tcp:recv(Ours, 10, ?WAIT)),
    ?assertEqual({error, enotconn}, gen_tcp:recv(Ours, 0, ?WAIT)),
    ?assertEqual({error, closed}, gen_tcp:send(Ours, <<"y">>)),
    gen_tcp:close(Peer).

stock_once_end() ->
    {Ours, Peer} = stock_pair([{active, once}]),
    ok = gen_tcp:send(Peer, <<"a">>),
    ?assertEqual({tcp, Ours, <<"a">>}, receive {tcp, Ours, _} = M -> M after ?WAIT -> timeout end),
    ok = gen_tcp:send(Peer, <<"b">>),
    ok = gen_tcp:shutdown(Peer, write),
    fin_arrives(),
    ?assertEqual(none, receive M1 -> M1 after 0 -> none end),
    ok = inet:setopts(Ours, [{active, once}]),
    ?assertEqual({tcp, Ours, <<"b">>}, receive M2 -> M2 after ?WAIT -> timeout end),
    ok = inet:setopts(Ours, [{active, once}]),
    ?assertEqual({tcp_closed, Ours}, receive M3 -> M3 after ?WAIT -> timeout end),
    gen_tcp:close(Peer).
