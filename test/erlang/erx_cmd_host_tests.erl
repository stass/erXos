%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_host_tests).
-moduledoc """
EUnit cases of `host` (erx_cmd_host): its pure core, and run/2 against a
name server on the loopback interface that answers from a fixed zone, as
the QEMU test's does on the link, with one name whose records carry a
terminal escape.
""".

-include_lib("eunit/include/eunit.hrl").

-define(QUIET, 300).

%% --- The pure core ---------------------------------------------------------------

candidates_test() ->
    ?assertEqual(["www.erxos.test", "www.b.test", "www"], erx_cmd_host:candidates("www", ["erxos.test", "b.test"], 1)),
    ?assertEqual(["www.example", "www.example.erxos.test"],
                 erx_cmd_host:candidates("www.example", ["erxos.test"], 1)),
    ?assertEqual(["www.example"], erx_cmd_host:candidates("www.example.", ["erxos.test"], 1)),
    ?assertEqual(["."], erx_cmd_host:candidates(".", [], 1)).

reverse_test() ->
    ?assertEqual("10.2.0.192.in-addr.arpa", erx_cmd_host:reverse({192, 0, 2, 10})),
    ?assertEqual("0.1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa",
                 erx_cmd_host:reverse({16#2001, 16#db8, 0, 0, 0, 0, 0, 16#10})).

answer_lines_test() ->
    Records = [{cname, "www.erxos.test", "web.erxos.test"},
               {a, "web.erxos.test", {192, 0, 2, 10}},
               {cname, "www.erxos.test", "web.erxos.test"},
               {aaaa, "web.erxos.test", {16#2001, 16#db8, 0, 0, 0, 0, 0, 16#10}},
               {ptr, "10.2.0.192.in-addr.arpa", "web.erxos.test"},
               {mx, "web.erxos.test", {10, "mx.erxos.test"}},
               {a, "bad.erxos.test", not_an_address}],
    ?assertEqual([<<"www.erxos.test is an alias for web.erxos.test.\n">>,
                  <<"web.erxos.test has address 192.0.2.10\n">>,
                  <<"web.erxos.test has IPv6 address 2001:db8::10\n">>,
                  <<"10.2.0.192.in-addr.arpa domain name pointer web.erxos.test.\n">>],
                 erx_cmd_host:answer_lines(Records)).

answer_lines_escape_test() ->
    [Line] = erx_cmd_host:answer_lines([{ptr, "1.in-addr.arpa", "x\e]52;c;AA==\^G\r\n.test"}]),
    ?assertEqual(nomatch, binary:match(Line, [<<"\e">>, <<"\^G">>, <<"\r">>])),
    ?assertEqual(1, length(binary:matches(Line, <<"\n">>))).

failure_line_test() ->
    ?assertEqual({ok, <<"Host nonexistent not found: 3(NXDOMAIN)\n">>},
                 erx_cmd_host:failure_line("nonexistent", nxdomain)),
    ?assertEqual({ok, <<"Host www not found: 2(SERVFAIL)\n">>}, erx_cmd_host:failure_line("www", servfail)),
    ?assertEqual({ok, <<";; connection timed out; no servers could be reached\n">>},
                 erx_cmd_host:failure_line("www", timeout)),
    ?assertEqual(error, erx_cmd_host:failure_line("www", enetunreach)).

server_lines_test() ->
    ?assertEqual(<<"Using domain server:\nName: 10.0.2.100\nAddress: 10.0.2.100#53\nAliases: \n\n">>,
                 iolist_to_binary(erx_cmd_host:server_lines(<<"10.0.2.100">>, {10, 0, 2, 100}))).

%% --- run/2 against a name server -------------------------------------------------

run_test_() ->
    {setup, fun start_server/0, fun stop_server/1,
     fun(_) ->
             [{"a name through an alias, A then AAAA", fun name_found/0},
              {"a name no domain has", fun name_not_found/0},
              {"an address by its pointer", fun address_found/0},
              {"names from the wire are escaped", fun hostile_names/0},
              {"a server that never answers", fun no_answer/0},
              {"usage", fun usage/0}]
     end}.

name_found() ->
    ?assertEqual({ok, [<<"www.erxos.test is an alias for web.erxos.test.\n">>,
                       <<"web.erxos.test has address 192.0.2.10\n">>,
                       <<"web.erxos.test has IPv6 address 2001:db8::10\n">>]},
                 host([<<"www">>])).

name_not_found() ->
    ?assertEqual({{error, {reported, nxdomain}}, [<<"Host nonexistent not found: 3(NXDOMAIN)\n">>]},
                 host([<<"nonexistent">>])).

address_found() ->
    ?assertEqual({ok, [<<"10.2.0.192.in-addr.arpa domain name pointer web.erxos.test.\n">>]},
                 host([<<"192.0.2.10">>])).

hostile_names() ->
    {ok, Lines} = host([<<"evil">>]),
    ?assertMatch([_, _], Lines),
    [?assertEqual(nomatch, binary:match(Line, <<"\e">>)) || Line <- Lines].

no_answer() ->
    ?assertEqual({{error, {reported, timeout}},
                  [<<";; connection timed out; no servers could be reached\n">>]},
                 host([<<"silent">>])).

usage() ->
    ?assertEqual({error, usage}, erx_cmd_host:run([], ctx())),
    ?assertEqual({error, usage}, erx_cmd_host:run([<<"a">>, <<"b">>, <<"c">>], ctx())),
    ?assertEqual({error, usage}, erx_cmd_host:run([<<"-x">>, <<"a">>], ctx())).

%% Runs host and answers its status and what it wrote to standard output.
host(Args) ->
    Status = erx_cmd_host:run(Args, ctx()),
    {Status, written()}.

ctx() ->
    Me = self(),
    #{name => <<"host">>,
      stdout => {tty, fun(Bytes) -> Me ! {stdout, Bytes}, ok end},
      stderr => {tty, fun(Bytes) -> Me ! {stderr, Bytes}, ok end}}.

%% The lines written to standard output, each with its newline.
written() ->
    Bytes = iolist_to_binary(stdout()),
    [<<Line/binary, "\n">> || Line <- binary:split(Bytes, <<"\n">>, [global, trim_all])].

stdout() ->
    receive {stdout, Bytes} -> [Bytes | stdout()]
    after 0 -> []
    end.

%% --- The name server -------------------------------------------------------------

start_server() ->
    Saved = [{Opt, inet_db:res_option(Opt)} || Opt <- [resolv_conf, nameservers, search, timeout, retry]],
    {ok, Socket} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}, {active, false}]),
    {ok, Port} = inet:port(Socket),
    Server = spawn(fun() -> receive owner -> serve(Socket) end end),
    ok = gen_udp:controlling_process(Socket, Server),
    Server ! owner,
    ok = inet_db:res_option(resolv_conf, ""),
    ok = inet_db:res_option(nameservers, [{{127, 0, 0, 1}, Port}]),
    ok = inet_db:res_option(search, ["erxos.test"]),
    ok = inet_db:res_option(timeout, ?QUIET),
    ok = inet_db:res_option(retry, 1),
    {Server, Saved}.

stop_server({Server, Saved}) ->
    exit(Server, kill),
    [ok = inet_db:res_option(Opt, Value) || {Opt, Value} <- Saved, Value =/= undefined],
    ok.

serve(Socket) ->
    {ok, {Address, Port, Packet}} = gen_udp:recv(Socket, 0),
    {ok, Query} = inet_dns:decode(Packet),
    [Question] = inet_dns:msg(Query, qdlist),
    Name = string:lowercase(inet_dns:dns_query(Question, domain)),
    case zone(Name, inet_dns:dns_query(Question, type)) of
        silent -> ok;
        {Rcode, Answers} -> ok = gen_udp:send(Socket, Address, Port, reply(Query, Rcode, Answers))
    end,
    serve(Socket).

reply(Query, Rcode, Answers) ->
    Header = inet_dns:msg(Query, header),
    inet_dns:encode(inet_dns:make_msg(
                      [{header, inet_dns:make_header(Header, [{qr, true}, {aa, true}, {ra, true},
                                                              {rcode, Rcode}])},
                       {qdlist, inet_dns:msg(Query, qdlist)},
                       {anlist, [inet_dns:make_rr([{domain, D}, {type, T}, {class, in}, {ttl, 60},
                                                   {data, Data}])
                                 || {T, D, Data} <- Answers]}])).

-define(ALIAS, {cname, "www.erxos.test", "web.erxos.test"}).
-define(EVIL, "x\e[2J.erxos.test").

zone("www.erxos.test", a) -> {0, [?ALIAS, {a, "web.erxos.test", {192, 0, 2, 10}}]};
zone("www.erxos.test", aaaa) -> {0, [?ALIAS, {aaaa, "web.erxos.test", {16#2001, 16#db8, 0, 0, 0, 0, 0, 16#10}}]};
zone("10.2.0.192.in-addr.arpa", ptr) -> {0, [{ptr, "10.2.0.192.in-addr.arpa", "web.erxos.test"}]};
zone("evil.erxos.test", a) -> {0, [{cname, "evil.erxos.test", ?EVIL}, {a, ?EVIL, {192, 0, 2, 66}}]};
zone("evil.erxos.test", aaaa) -> {0, []};
zone("silent.erxos.test", _Type) -> silent;
zone("silent", _Type) -> silent;
zone(_Name, _Type) -> {3, []}.
