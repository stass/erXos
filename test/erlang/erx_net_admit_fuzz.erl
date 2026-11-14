%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_admit_fuzz).
-moduledoc """
The fuzz target of the network stack's admission of messages from the other
domain (docs/design-network-stack.md, "Untrusted input"), driven by
tools/fuzz/erx_net_admit.rb. Two targets:

* `admit`: erx_net_admit's request/2 (the grant), request/3 (a TCP
  connection's socket process) and mint/2, on messages built near the
  admitted forms and mutated: foreign, stale and mistyped domain ids,
  reply pids of other creations and other nodes, wrong socket processes,
  envelopes missing, doubled or of another domain, the stack's own calls
  from outside, options lists and binaries at, over and far over their
  bounds, improper and very long lists. Each verdict must equal this
  module's own reading of the design's rules; a verdict that admits what
  the rules refuse prints `request2_admitted_bad`, `request3_admitted_bad`
  or `mint_admitted_bad`.
* `sock`: erx_sock_admit's answer/3, change/3, push/3 and result/2 on the
  same kind of input, as the network domain could send it. An admitted
  answer must be rebuilt of checked parts only (an interface of exactly its
  six keys, names of 1 to 15 bytes of letters, digits, `.`, `-` and `_`, at
  most 64 interfaces and 64 addresses each, socket pids of the grant's node
  only, data of at most 64 pieces and 65536 bytes). A verdict that admits
  what the rules refuse prints `answer_admitted_bad`, `change_admitted_bad`,
  `push_admitted_bad` or `result_admitted_bad`.

Any other disagreement prints `<function>_refused_good` or
`<function>_differs`, and a call that raises prints `raised`. The checks are
pure functions of their arguments, so a duplicated message is the same
input twice and needs no case of its own. The arguments the stack itself
supplies (grantee, origin, operation, grant, request kind) are well typed.

Prints `fuzz: N inputs ok` when every input passed.
""".

-export([run/1]).

-define(INPUTS, 6000).
-define(MAX_U32, 16#ffffffff).

run([Target, Seed]) ->
    _ = rand:seed(exsss, {list_to_integer(Seed), 7, 13}),
    Check = check(list_to_atom(Target)),
    Failures = lists:filtermap(fun(_) -> Check() end, lists:seq(1, ?INPUTS)),
    case Failures of
        [] -> io:format("fuzz: ~b inputs ok~n", [?INPUTS]);
        [First | _] ->
            Tags = lists:usort([element(1, Failure) || Failure <- Failures]),
            io:format("fuzz: ~b failed, tags ~p, first ~P~n", [length(Failures), Tags, First, 14])
    end.

check(admit) ->
    Cases = [fun request2/0, fun request2/0, fun request2/0, fun request3/0, fun request3/0, fun mint/0],
    fun() -> (pick(Cases))() end;
check(sock) ->
    Cases = [fun answer/0, fun answer/0, fun change/0, fun push/0, fun push/0, fun result/0],
    fun() -> (pick(Cases))() end.

%% One input: `Actual` must not raise and must give `Expected`; anything else is a failure
%% tagged by the function and by the direction of the disagreement.
judge(Name, Actual, Expected, Input) ->
    try Actual() of
        Expected -> false;
        Got -> {true, {tag(Name, Got, Expected), Input, Got, Expected}}
    catch
        Class:Reason -> {true, {raised, Name, Class, Reason, Input}}
    end.

tag(Name, Got, Expected) ->
    Direction = case {admits(Got), admits(Expected)} of
                    {true, false} -> admitted_bad;
                    {false, true} -> refused_good;
                    _ -> differs
                end,
    list_to_atom(atom_to_list(Name) ++ "_" ++ atom_to_list(Direction)).

admits({ok, _}) -> true;
admits({ok, _, _}) -> true;
admits({ok, _, _, _}) -> true;
admits(_) -> false.

%% --- request/2 -------------------------------------------------------------------

request2() ->
    Grantee = grantee(),
    Message = case rand:uniform(12) of
                  1 -> garbage();
                  _ -> frame(Grantee, call(Grantee, grant_request()))
              end,
    judge(request2, fun() -> erx_net_admit:request(Message, Grantee) end,
          expected_request2(Message, Grantee), {Message, Grantee}).

%% What the design says of a grant's message: a call whose reply goes to the grantee's
%% domain (a process of this node for `local`; for a domain, a reply alias whose pid and
%% reference both carry the creation `Grantee`), within the operation's bounds; the
%% stack's own calls only bare and from this node.
expected_request2({'$gen_call', {Pid, _} = From, Request}, Grantee) when is_pid(Pid) ->
    case {node(Pid) =:= node(), is_own(Request), Grantee} of
        {true, true, _} -> verdict(own_ok(Request), Request, From);
        {true, false, local} -> verdict(grant_ok(Request), Request, From);
        _ -> unknown
    end;
expected_request2({erx_origin, Origin, {'$gen_call', {Pid, [alias | Alias]} = From, Request}}, Grantee)
  when is_integer(Grantee), Origin =:= Grantee, is_pid(Pid), is_reference(Alias) ->
    case creation(Pid) =:= Grantee andalso creation(Alias) =:= Grantee of
        true -> verdict(grant_ok(Request), Request, From);
        false -> unknown
    end;
expected_request2(_Message, _Grantee) ->
    unknown.

verdict(true, Request, From) -> {ok, Request, From};
verdict(false, _Request, From) -> {refused, shape, From}.

is_own(counts) -> true;
is_own(Request) -> is_tuple(Request) andalso tuple_size(Request) >= 1 andalso
                       lists:member(element(1, Request), [reserve_buffer, release_buffers]).

own_ok({reserve_buffer, Token, Kind, Bytes}) ->
    is_reference(Token) andalso lists:member(Kind, [snd, rcv]) andalso is_integer(Bytes) andalso Bytes >= 0;
own_ok({release_buffers, Token}) -> is_reference(Token);
own_ok(counts) -> true;
own_ok(_) -> false.

grant_ok({tcp_connect, inet, Ip, Port, Options, Timeout}) ->
    ip4(Ip) andalso within(Port, 1, 16#ffff) andalso short(Options) andalso timeout_ok(Timeout);
grant_ok({udp_open, inet, Local, Port, Options}) ->
    (Local =:= any orelse ip4(Local)) andalso within(Port, 0, 16#ffff) andalso short(Options);
grant_ok({icmp_open, inet}) -> true;
grant_ok(interfaces) -> true;
grant_ok(resolver) -> true;
grant_ok(watch_resolver) -> true;
grant_ok(_) -> false.

timeout_ok(infinity) -> true;
timeout_ok(Timeout) -> within(Timeout, 0, 4294967295).

%% A proper list of at most 64 elements.
short(List) -> proper_upto(List, 64).

proper_upto(List, Max) ->
    try length(List) =< Max catch error:badarg -> false end.

within(X, Low, High) -> is_integer(X) andalso X >= Low andalso X =< High.

ip4({A, B, C, D}) -> lists:all(fun(X) -> within(X, 0, 255) end, [A, B, C, D]);
ip4(_) -> false.

%% The creation of a pid made here, as it was chosen (a pid of this process is 0).
creation(Pid) ->
    case get({creation, Pid}) of
        undefined -> 0;
        Creation -> Creation
    end.

%% --- request/4 -------------------------------------------------------------------

request3() ->
    Origin = grantee(),
    Sock = pick([self(), self(), self(), none, pid(other_node(), 5), sock]),
    Wrong = pick([Sock, Sock, Sock, self(), pid(other_node(), 9)]),
    Message = case rand:uniform(12) of
                  1 -> garbage();
                  _ -> frame(Origin, {erx_net, Wrong, socket_body()})
              end,
    Kind = pick([tcp, tcp_listen, udp, icmp]),
    judge(request3, fun() -> erx_net_admit:request(Kind, Origin, Sock, Message) end,
          expected_request3(Kind, Origin, Sock, Message), {Kind, Origin, Sock, Message}).

expected_request3(Kind, Origin, Sock, Message) ->
    case taken(Origin, Sock, Message) of
        {ok, Body} ->
            case body_ok(Kind, Origin, Body) of
                true -> {ok, Body};
                false -> {refused, shape}
            end;
        unknown -> unknown
    end.

%% The body of a message of this socket process, in the envelope its origin arrives by.
taken(local, Sock, {erx_net, Sock, Body}) when is_pid(Sock) -> {ok, Body};
taken(Origin, Sock, {erx_origin, Origin, {erx_net, Sock, Body}}) when Origin =/= local, is_pid(Sock) -> {ok, Body};
taken(_Origin, _Sock, _Message) -> unknown.

body_ok(_Kind, _Origin, {credit, Bytes}) -> within(Bytes, 1, 67108864);
body_ok(Kind, Origin, {call, N, Request}) ->
    is_integer(N) andalso N >= 0 andalso call_ok(Kind, Request) andalso acceptor_ok(Request, Origin);
body_ok(_Kind, _Origin, _) -> false.

%% The socket process an accept names is of the grantee's domain: of this node when the
%% grantee is local, of the grantee's creation otherwise.
acceptor_ok({accept, Acceptor, _}, local) -> node(Acceptor) =:= node();
acceptor_ok({accept, Acceptor, _}, Grantee) -> creation(Acceptor) =:= Grantee;
acceptor_ok(_Request, _Origin) -> true.

call_ok(tcp, {send, Piece}) -> is_binary(Piece) andalso byte_size(Piece) =< 65536;
call_ok(tcp, {shutdown, How}) -> lists:member(How, [read, write, read_write]);
call_ok(tcp, {setopts, Options}) -> lists:member(Options, [[], [{nodelay, true}], [{nodelay, false}]]);
call_ok(tcp, {getopts, Options}) -> lists:member(Options, [[], [nodelay]]);
call_ok(tcp, peername) -> true;
call_ok(tcp_listen, {accept, Acceptor, Timeout}) -> is_pid(Acceptor) andalso timeout_ok(Timeout);
call_ok(tcp_listen, _) -> false;
call_ok(udp, {send_to, Ip, Port, Data}) -> ip4(Ip) andalso within(Port, 0, 65535) andalso datagram(Data, 65527);
call_ok(udp, {send, Data}) -> datagram(Data, 65527);
call_ok(udp, {connect, Ip, Port}) -> ip4(Ip) andalso within(Port, 1, 65535);
call_ok(icmp, {echo_send, Ip, Seq, Ttl, Data}) ->
    ip4(Ip) andalso within(Seq, 0, 65535) andalso (Ttl =:= default orelse within(Ttl, 1, 255))
        andalso datagram(Data, 65507);
call_ok(Kind, sockname) -> Kind =/= icmp;
call_ok(_Kind, close) -> true;
call_ok(_Kind, _) -> false.

datagram(Data, Max) -> is_binary(Data) andalso byte_size(Data) =< Max.

socket_body() ->
    case rand:uniform(10) of
        1 -> {credit, pick([1, 64, 67108864, 67108865, 0, -1, 1 bsl 70, 1.0, x])};
        2 -> {credit, rand:uniform(1000)};
        10 -> garbage();
        _ -> {call, pick([0, 1, 1 bsl 40, -1, x, 1.5]), socket_call()}
    end.

socket_call() ->
    case rand:uniform(30) of
        N when N >= 25, N =< 28 -> {accept, acceptor(), timeout_value()};
        N when N >= 29 -> {accept, acceptor(), infinity};
        1 -> {send, piece()};
        2 -> {send, piece()};
        3 -> {shutdown, pick([read, write, read_write, rw, 1])};
        4 -> close;
        5 -> {setopts, pick([[], [{nodelay, true}], [{nodelay, false}], [{nodelay, 1}], [{nodelay, true}, {nodelay, true}],
                             [{keepalive, true}], x])};
        6 -> {getopts, pick([[], [nodelay], [nodelay, nodelay], [keepalive], x])};
        7 -> sockname;
        8 -> peername;
        9 -> pick([{close}, {send}, abc, {sockname, 1}, [], <<>>]);
        N when N >= 17; N =:= 11 -> {send_to, address(), port(), datagram()};
        12 -> {send, datagram()};
        13 -> {connect, address(), port()};
        14 -> {echo_send, address(), port(), pick([default, 0, 1, 64, 255, 256, x]), datagram()};
        15 -> {send_to, address(), port()};
        16 -> {echo_send, address(), 1, 64};
        _ -> {send, <<"hello">>}
    end.

%% An acceptor's socket process: of this node, of another domain's, or no pid.
acceptor() ->
    pick([self(), self(), pid(other_node(), pick([1, 2, 3, 7])), pid(atom_to_binary(node()), 2), x]).

address() -> pick([{10, 0, 2, 3}, {10, 0, 2, 3}, {10, 0, 2, 3}, {10, 0, 2, 3}, {255, 255, 255, 255}, {0, 0, 0, 0}, {256, 0, 0, 1}, {1, 2, 3}, {-1, 0, 0, 0},
                   {0, 0, 0, 0, 0, 0, 0, 1}, "10.0.2.3", x]).

port() -> pick([0, 1, 53, 53, 53, 53, 65535, 65536, -1, x]).

%% Data around the largest IPv4 and IPv6 payloads.
datagram() ->
    case rand:uniform(6) of
        1 -> pick([<<1:3>>, [<<"io">>], x]);
        _ -> binary:copy(<<"d">>, pick([0, 1, 65507, 65508, 65527, 65528, 70000]))
    end.

piece() ->
    case rand:uniform(8) of
        1 -> <<1:3>>;
        2 -> [<<"io">>, $l];
        3 -> x;
        _ -> binary:copy(<<"x">>, pick([0, 1, 65535, 65536, 65537, 1000000]))
    end.

%% --- mint/2 ----------------------------------------------------------------------

mint() ->
    System = pick([1, 2, 5]),
    Inner = case rand:uniform(14) of
                1 -> {erx_facet_mint, 1, net, 3};
                2 -> {erx_facet_mint, 1, net, 3, <<"user">>, #{}, extra};
                _ -> {erx_facet_mint, pick([1, 7, 0, -1, x, 1 bsl 70]), pick([net, net, net, fs]),
                      pick([1, 2, 5, 9, 0, -1, x]), pick([<<"user">>, <<>>, user, 1]),
                      pick([#{}, #{a => 1}, [], x])}
            end,
    Message = case rand:uniform(8) of
                  1 -> Inner;
                  2 -> {erx_origin, System + 1, Inner};
                  3 -> garbage();
                  _ -> {erx_origin, System, Inner}
              end,
    judge(mint, fun() -> erx_net_admit:mint(System, Message) end, expected_mint(System, Message), {System, Message}).

expected_mint(System, {erx_origin, System, {erx_facet_mint, Tag, net, Grantee, Principal, Limits}}) ->
    case within(Tag, 1, 1 bsl 80) andalso within(Grantee, 1, 1 bsl 80) andalso is_binary(Principal)
         andalso is_map(Limits) of
        true when Grantee =:= System -> {refused, eperm, Tag};
        true -> {ok, Tag, Grantee, Limits};
        false -> unknown
    end;
expected_mint(_System, _Message) ->
    unknown.

%% --- the grant's requests --------------------------------------------------------

grant_request() ->
    case rand:uniform(12) of
        1 -> {tcp_connect, pick([inet, inet, inet6]), ip(), port(1), options(), timeout_value()};
        2 -> {tcp_connect, inet, ip(), port(1), options(), timeout_value()};
        3 -> {tcp_connect, inet, ip(), port(1), options(), timeout_value()};
        4 -> {tcp_connect, inet, ip(), port(1), options()};
        5 -> {udp_open, inet, pick([any, any, ip(), x]), port(0), options()};
        6 -> {udp_open, inet, pick([any, ip()]), port(0), options()};
        7 -> pick([{icmp_open, inet}, {icmp_open, inet6}, {icmp_open}, interfaces, resolver, watch_resolver]);
        8 -> pick([{reserve_buffer, make_ref(), pick([snd, rcv, other]), pick([0, 1500, -1, x])},
                   {reserve_buffer, make_ref()}, {release_buffers, make_ref()}, {release_buffers, x}, counts,
                   {counts}, {reserve_buffer}]);
        9 -> pick([interfaces, resolver, watch_resolver, {interfaces}, {resolver, 1}, 'resolver']);
        10 -> garbage();
        _ -> {tcp_connect, inet, ip(), port(1), options(), timeout_value()}
    end.

ip() -> pick([{192, 0, 2, rand:uniform(256) - 1}, {10, 0, 2, 3}, {0, 0, 0, 0}, {255, 255, 255, 255}, {256, 0, 0, 1},
              {-1, 0, 0, 1}, {1, 2, 3}, {1, 2, 3, 4, 5}, {a, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}, {1.0, 0, 0, 1}, x,
              <<1, 2, 3, 4>>, [1, 2, 3, 4]]).

port(Least) -> pick([Least, 1, 80, 65535, 65535, 65536, 0, -1, 1.0, x, 1 bsl 64, Least + 1]).

timeout_value() -> pick([infinity, infinity, 1000, 0, 4294967295, 4294967296, -1, 1.5, forever, 1 bsl 100, 5000]).

%% A list at and around the bound of 64, now and then improper, far longer or nested far deeper
%% than anything may recurse.
options() ->
    Length = pick([0, 1, 3, 63, 64, 64, 65, 100]),
    List = [pick([a, {nodelay, true}, {active, false}, [], <<>>, {a, [b, [c]]}]) || _ <- lists:seq(1, Length)],
    case rand:uniform(24) of
        1 -> List ++ b;
        2 -> lists:duplicate(64, a) ++ b;
        3 -> lists:duplicate(63, a) ++ [b | c];
        4 -> lists:duplicate(200000, a);
        5 -> pick([x, {a}, <<"opts">>, 1]);
        6 -> [deep(100000)];
        7 -> deep(100000);
        _ -> List
    end.

deep(Depth) -> lists:foldl(fun(_, Acc) -> [Acc] end, [], lists:seq(1, Depth)).

%% --- the grant's answers and the socket's messages -------------------------------

answer() ->
    Operation = pick([tcp_connect, udp_open, icmp_open, interfaces, interfaces, interfaces, resolver, watch_resolver,
                      counts, bogus]),
    Grant = pick([self(), pid(other_node(), 1)]),
    Answer = answer_value(Operation, Grant),
    judge(answer, fun() -> erx_sock_admit:answer(Operation, Grant, Answer) end,
          expected_answer(Operation, Grant, Answer), {Operation, Grant, Answer}).

answer_value(Operation, Grant) ->
    Natural = case Operation of
                  interfaces -> interfaces;
                  Resolver when Resolver =:= resolver; Resolver =:= watch_resolver -> resolver;
                  _ -> socket
              end,
    case rand:uniform(14) of
        1 -> {ok, ok_value(pick([socket, interfaces, resolver]), Grant)};
        2 -> {error, reason()};
        3 -> {error, reason()};
        4 -> garbage();
        5 -> pick([{ok}, ok, {ok, a, b}, {error}, {error, a, b}]);
        _ -> {ok, ok_value(Natural, Grant)}
    end.

ok_value(socket, Grant) ->
    pick([self(), pid(node_name(Grant), pick([0, 3, 77])), pid(other_node(), pick([0, 3])), erx_net_grant,
          {global, sock}, {via, global, sock}, {erx_net_grant, node()}, "pid", make_ref()]);
ok_value(interfaces, _Grant) ->
    interfaces();
ok_value(resolver, _Grant) ->
    resolver_map().

node_name(Pid) -> atom_to_binary(node(Pid)).

expected_answer(Operation, Grant, Answer) ->
    case reply_type(Operation) of
        none -> {refused, operation};
        {Carried, Reasons} ->
            case Answer of
                {ok, Value} -> carried(Carried, Grant, Value);
                {error, Reason} ->
                    case lists:member(Reason, Reasons) of
                        true -> {ok, {error, Reason}};
                        false -> {refused, reason}
                    end;
                _ -> {refused, shape}
            end
    end.

reply_type(tcp_connect) -> {socket, connect_reasons()};
reply_type(udp_open) -> {socket, open_reasons()};
reply_type(icmp_open) -> {socket, open_reasons()};
reply_type(interfaces) -> {interfaces, [enotconn, eacces, badarg]};
reply_type(resolver) -> {resolver, [eacces, badarg]};
reply_type(watch_resolver) -> {resolver, [eacces, badarg]};
reply_type(_) -> none.

open_reasons() -> [eacces, emfile, enobufs, eaddrinuse, eaddrnotavail, einval, enotsup, badarg].

connect_reasons() ->
    [econnrefused, etimedout, enetunreach, ehostunreach, enoprotoopt, econnreset, closed, timeout | open_reasons()].

end_reasons() ->
    [closed, econnreset, econnaborted, econnrefused, etimedout, ehostunreach, enetunreach, enoprotoopt, epipe, timeout].

%% What each kind of socket request may be answered with, besides its `ok`.
kind_reasons(send) -> [epipe, ebusy, enotconn, badarg | end_reasons()];
kind_reasons(shutdown) -> [enotconn, badarg | end_reasons()];
kind_reasons(Kind) when Kind =:= udp_send; Kind =:= echo_send ->
    [edestaddrreq, emsgsize, enobufs, enetunreach, ehostunreach, eaddrnotavail, eacces, einval, badarg];
kind_reasons(_) -> [badarg].

result_kinds() -> [send, shutdown, setopts, getopts, sockname, peername, udp_send, udp_connect, echo_send, close].

%% Every reason of any list above, and some of none.
reason() ->
    pick(connect_reasons() ++ end_reasons() ++ lists:append([kind_reasons(K) || K <- result_kinds()]) ++
             [enotconn, eperm, enoent, 1, {crash, [stack]}, "closed", <<"closed">>]).

carried(socket, Grant, Value) ->
    case is_pid(Value) andalso node(Value) =:= node(Grant) of
        true -> {ok, {ok, Value}};
        false -> {refused, socket}
    end;
carried(interfaces, _Grant, Value) ->
    case expected_interfaces(Value) of
        {ok, Interfaces} -> {ok, {ok, Interfaces}};
        error -> {refused, interface}
    end;
carried(resolver, _Grant, Value) ->
    case erx_inet:resolver_config(Value) of
        {ok, Resolver} -> {ok, {ok, Resolver}};
        {error, badarg} -> {refused, resolver}
    end.

%% The interfaces the rules admit, each rebuilt of its six keys alone.
expected_interfaces(List) ->
    case proper_upto(List, 64) of
        false -> error;
        true ->
            Rebuilt = [expected_interface(Interface) || Interface <- List],
            case lists:member(error, Rebuilt) of
                true -> error;
                false -> {ok, [Checked || {ok, Checked} <- Rebuilt]}
            end
    end.

expected_interface(#{name := Name, lladdr := Lladdr, mtu := Mtu, link := Link, config := Config, addrs := Addrs}) ->
    Checked = expected_addrs(Addrs),
    Fine = valid_name(Name) andalso (Lladdr =:= none orelse is_bitstring(Lladdr) andalso bit_size(Lladdr) =:= 48)
        andalso within(Mtu, 1, 16#ffff)
        andalso lists:member(Link, [up, down]) andalso lists:member(Config, [static, dhcp]) andalso Checked =/= error,
    case Fine of
        true -> {ok, #{name => Name, lladdr => Lladdr, mtu => Mtu, link => Link, config => Config,
                       addrs => element(2, Checked)}};
        false -> error
    end;
expected_interface(_) ->
    error.

valid_name(Name) ->
    is_binary(Name) andalso byte_size(Name) >= 1 andalso byte_size(Name) =< 15 andalso
        lists:all(fun name_byte/1, binary_to_list(Name)).

name_byte(C) -> lists:member(C, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").

expected_addrs(Addrs) ->
    case proper_upto(Addrs, 64) of
        false -> error;
        true ->
            Rebuilt = [expected_addr(Addr) || Addr <- Addrs],
            case lists:member(error, Rebuilt) of
                true -> error;
                false -> {ok, [Checked || {ok, Checked} <- Rebuilt]}
            end
    end.

expected_addr(#{addr := Ip, plen := Plen} = Addr) when is_tuple(Ip) ->
    case {tuple_size(Ip), ip4(Ip)} of
        {4, true} when is_integer(Plen), Plen >= 0, Plen =< 32 ->
            case maps:find(broadcast, Addr) of
                error -> {ok, #{addr => Ip, plen => Plen}};
                {ok, Broadcast} ->
                    case ip4(Broadcast) of
                        true -> {ok, #{addr => Ip, plen => Plen, broadcast => Broadcast}};
                        false -> error
                    end
            end;
        {8, _} when is_integer(Plen), Plen >= 0, Plen =< 128 ->
            case lists:all(fun(Word) -> within(Word, 0, 16#ffff) end, tuple_to_list(Ip)) of
                true -> {ok, #{addr => Ip, plen => Plen}};
                false -> error
            end;
        _ -> error
    end;
expected_addr(_) ->
    error.

%% Lists at the bound of 64 hold only sound interfaces, so that the bound alone decides them.
%% Of the shorter ones half have sound fields and the addresses, if any, to decide them.
interfaces() ->
    Count = pick([0, 1, 1, 1, 2, 3, 64, 64, 65, 65]),
    Mode = if Count >= 64 -> sound; true -> pick([free, free, addrs, addrs]) end,
    List = [interface(Mode) || _ <- lists:seq(1, Count)],
    case rand:uniform(30) of
        1 -> List ++ pick([a, <<>>]);
        2 -> pick([a, #{}, {List}]);
        3 -> List ++ [x];
        _ -> List
    end.

interface(Mode) ->
    Sound = Mode =/= free,
    Interface = sound(Sound, #{name => name(Sound), lladdr => lladdr(),
                               mtu => pick([1500, 1500, 1500, 1500, 1500, 1500, 1500, 1, 65535, 0, 65536, -1, 1500.0, x]),
                               link => pick([up, down, up, down, up, down, up, down, left, 1]),
                               config => pick([static, dhcp, static, dhcp, static, dhcp, static, dhcp, manual]),
                               addrs => addrs(Mode)}),
    case rand:uniform(40) of
        1 when not Sound -> maps:remove(pick(maps:keys(Interface)), Interface);
        2 -> Interface#{extra => pick([1, #{a => b}, broadcast])};
        3 when not Sound -> pick([#{}, [], x]);
        _ -> Interface
    end.

sound(true, Interface) -> Interface#{lladdr := <<0:48>>, mtu := 1500, link := up, config := static};
sound(false, Interface) -> Interface.

%% Names at and over the bound of 15 bytes, with the bytes a name admits and now and then
%% one it does not.
name(Sound) ->
    Length = case Sound of
                 true -> pick([1, 5, 15]);
                 false -> pick([1, 2, 5, 14, 15, 15, 16, 16, 17, 17, 18, 0, 40])
             end,
    Name = << <<(pick("abzAZ09.-_"))>> || _ <- lists:seq(1, Length) >>,
    case rand:uniform(24) of
        1 when Length > 0, not Sound ->
            <<(pick([0, $\s, $/, $:, 128, $\n, 255, $\e])), (binary:part(Name, 1, Length - 1))/binary>>;
        2 when not Sound -> pick(["eth0", eth0, 7]);
        3 when not Sound -> <<Name/binary, 0>>;
        _ -> Name
    end.

lladdr() ->
    case rand:uniform(30) of
        1 -> rand:bytes(5);
        2 -> rand:bytes(7);
        3 -> <<0:47>>;
        4 -> pick([x, "lladdr", nil]);
        5 -> none;
        _ -> rand:bytes(6)
    end.

addrs(addrs) ->
    [addr(false) || _ <- lists:seq(1, pick([1, 1, 2]))];
addrs(Mode) ->
    Sound = Mode =:= sound,
    Count = pick([0, 0, 1, 1, 2, 3, 64, 64, 65, 65]),
    List = [addr(Sound orelse Count >= 64) || _ <- lists:seq(1, Count)],
    case rand:uniform(30) of
        1 when not Sound -> List ++ pick([a, <<>>]);
        2 when not Sound -> pick([x, #{}]);
        3 when not Sound -> List ++ [#{}];
        _ -> List
    end.

addr(Sound) ->
    Addr = case {rand:uniform(4), Sound} of
               {1, false} -> #{addr => gen_ip6(false), plen => pick([0, 64, 128, 128, 129, 255, -1, x])};
               {2, _} -> #{addr => gen_ip6(Sound), plen => pick([0, 64, 128])};
               {_, false} -> #{addr => gen_ip4(false), plen => pick([0, 24, 32, 32, 33, -1, 1.0, x])};
               {_, true} -> #{addr => gen_ip4(true), plen => pick([0, 24, 32])}
           end,
    case rand:uniform(16) of
        1 when not Sound -> maps:remove(plen, Addr);
        2 when not Sound -> maps:remove(addr, Addr);
        3 when not Sound -> Addr#{broadcast => pick([{255, 255, 255, 255}, {1, 2, 3}, {256, 0, 0, 0}, x, gen_ip6(false)])};
        4 -> Addr#{broadcast => {10, 0, 0, 255}};
        5 -> Addr#{extra => 1};
        _ -> Addr
    end.

gen_ip4() -> gen_ip4(false).

gen_ip4(Sound) ->
    case rand:uniform(10) of
        1 when not Sound -> pick([{256, 0, 0, 1}, {-1, 0, 0, 1}, {1, 2, 3}, {a, 0, 0, 1}, x]);
        _ -> {rand:uniform(256) - 1, 0, 2, rand:uniform(256) - 1}
    end.

gen_ip6() -> gen_ip6(false).

gen_ip6(Sound) ->
    Words = [rand:uniform(65536) - 1 || _ <- lists:seq(1, 8)],
    case rand:uniform(20) of
        1 when not Sound -> list_to_tuple([65536 | tl(Words)]);
        2 when not Sound -> list_to_tuple([-1 | tl(Words)]);
        3 when not Sound -> list_to_tuple(tl(Words));
        4 when not Sound -> list_to_tuple([x | tl(Words)]);
        _ -> list_to_tuple(Words)
    end.

resolver_map() ->
    case rand:uniform(8) of
        1 -> pick([#{}, #{nameservers => []}, #{nameservers => [], search => [], extra => 1}, x, []]);
        2 -> #{nameservers => [{{10, 0, 2, 3}, 54}], search => []};
        _ -> #{nameservers => [{{10, 0, 2, 3}, 53} || _ <- lists:seq(1, rand:uniform(4) - 1)],
               search => [pick([<<"example.com">>, <<"a.b.">>, <<"bad name">>, x]) || _ <- lists:seq(1, rand:uniform(7) - 1)]}
    end.

%% --- change/3 --------------------------------------------------------------------

change() ->
    Origin = grantee(),
    Grant = pick([self(), pid(other_node(), 2)]),
    Wrong = pick([Grant, Grant, Grant, pid(other_node(), 3)]),
    Message = case rand:uniform(12) of
                  1 -> garbage();
                  _ -> frame(Origin, {erx_net_resolver, Wrong, pick([resolver_map(), resolver_map(), garbage()])})
              end,
    judge(change, fun() -> erx_sock_admit:change(Origin, Grant, Message) end,
          expected_change(Origin, Grant, Message), {Origin, Grant, Message}).

expected_change(Origin, Grant, Message) ->
    case taken_change(Origin, Grant, Message) of
        {ok, Answer} ->
            case erx_inet:resolver_config(Answer) of
                {ok, Resolver} -> {ok, Resolver};
                {error, badarg} -> {refused, resolver}
            end;
        unknown -> {refused, origin}
    end.

taken_change(local, Grant, {erx_net_resolver, Grant, Answer}) -> {ok, Answer};
taken_change(Origin, Grant, {erx_origin, Origin, {erx_net_resolver, Grant, Answer}}) when Origin =/= local ->
    {ok, Answer};
taken_change(_Origin, _Grant, _Message) -> unknown.

%% --- push/4 ----------------------------------------------------------------------

push() ->
    Origin = grantee(),
    Socket = pick([self(), pid(other_node(), 3)]),
    Wrong = pick([Socket, Socket, Socket, pid(other_node(), 4)]),
    Message = case rand:uniform(12) of
                  1 -> garbage();
                  _ -> frame(Origin, {erx_net, Wrong, push_body()})
              end,
    Kind = pick([tcp, udp, icmp]),
    judge(push, fun() -> erx_sock_admit:push(Kind, Origin, Socket, Message) end,
          expected_push(Kind, Origin, Socket, Message), {Kind, Origin, Socket, Message}).

expected_push(Kind, Origin, Socket, Message) ->
    case taken(Origin, Socket, Message) of
        unknown -> unknown;
        {ok, Body} -> push_verdict(Kind, Body)
    end.

push_verdict(_Kind, {reply, N, _Result} = Body) when is_integer(N), N >= 0 -> {ok, Body};
push_verdict(udp, {datagram, Ip, Port, Data} = Body) ->
    case ip4(Ip) andalso within(Port, 0, 65535) andalso datagram(Data, 65527) of
        true -> {ok, Body};
        false -> {refused, push}
    end;
push_verdict(icmp, {echo, Ip, Ttl, Seq, Data} = Body) ->
    case ip4(Ip) andalso within(Ttl, 0, 255) andalso within(Seq, 0, 65535) andalso datagram(Data, 65507) of
        true -> {ok, Body};
        false -> {refused, push}
    end;
push_verdict(tcp, {data, Pieces} = Body) ->
    case pieces_ok(Pieces) of
        true -> {ok, Body};
        false -> {refused, push}
    end;
push_verdict(tcp, eof) -> {ok, eof};
push_verdict(tcp, {error, Reason} = Body) ->
    case lists:member(Reason, end_reasons()) of
        true -> {ok, Body};
        false -> {refused, push}
    end;
push_verdict(_Kind, _) -> {refused, push}.

%% 1 to 64 binaries of 1 to 65536 bytes in all.
pieces_ok(Pieces) ->
    proper_upto(Pieces, 64) andalso Pieces =/= [] andalso lists:all(fun is_binary/1, Pieces)
        andalso within(lists:sum([byte_size(Piece) || Piece <- Pieces]), 1, 65536).

push_body() ->
    case rand:uniform(12) of
        1 -> {reply, pick([0, 1, 1 bsl 40, -1, x, 1.5]), garbage()};
        2 -> {reply, rand:uniform(100), result_value()};
        3 -> {reply, rand:uniform(100), ok};
        4 -> eof;
        5 -> {error, reason()};
        6 -> pick([{error}, {data}, {reply, 1}, {reply, 1, ok, extra}, {eof}, x, [], <<"data">>]);
        7 -> {datagram, address(), port(), datagram()};
        8 -> {echo, address(), pick([0, 64, 255, 256, -1, x]), port(), datagram()};
        9 -> pick([{datagram, {10, 0, 2, 3}, 53}, {echo, {10, 0, 2, 3}, 64, 1}]);
        _ -> {data, pieces()}
    end.

%% Piece counts and sizes at and over the bounds of 64 and 65536 bytes in all.
pieces() ->
    Sizes = case rand:uniform(9) of
                1 -> [];
                2 -> [0];
                3 -> [65536];
                4 -> [65537];
                5 -> lists:duplicate(64, 1024);
                6 -> lists:duplicate(64, 1025);
                7 -> lists:duplicate(65, 1);
                8 -> [0, 0, 1];
                _ -> [rand:uniform(100) || _ <- lists:seq(1, rand:uniform(5))]
            end,
    Pieces = [binary:copy(<<"p">>, Size) || Size <- Sizes],
    case rand:uniform(14) of
        1 -> Pieces ++ <<"tail">>;
        2 -> Pieces ++ [x];
        3 -> lists:duplicate(100000, <<1>>);
        4 -> {Pieces};
        5 -> [<<"a">>, [<<"b">>]];
        6 -> [<<1:3>>];
        7 -> [<<1>> | <<2>>];
        8 -> x;
        _ -> Pieces
    end.

%% --- result/2 --------------------------------------------------------------------

result() ->
    Kind = pick(result_kinds()),
    Result = result_value(),
    judge(result, fun() -> erx_sock_admit:result(Kind, Result) end, expected_result(Kind, Result), {Kind, Result}).

result_value() ->
    case rand:uniform(16) of
        1 -> ok;
        2 -> pick([{ok, []}, {ok, [{nodelay, true}]}, {ok, [{nodelay, false}]}, {ok, [{nodelay, 1}]},
                   {ok, [{nodelay, true}, {nodelay, true}]}, {ok, [nodelay]}, {ok, x}]);
        3 -> {ok, {pick([gen_ip4(), gen_ip4(), {10, 0, 2, 3}]), port(0)}};
        4 -> {ok, {gen_ip6(), 80}};
        7 -> {error, timeout};
        8 -> {error, reason()};
        9 -> {error, reason()};
        10 -> garbage();
        11 -> pick([{ok}, {ok, a, b}, {error}, {error, a, b}, error, true]);
        _ -> {ok, {{10, 0, 2, 3}, 80}}
    end.

%% A reply is admitted by what it says for its kind of request: `ok` for the kinds that
%% answer it, the shapes of the reply types, and errors from the kind's closed list.
expected_result(Kind, Result) ->
    case result_ok(Kind, Result) of
        true -> {ok, Result};
        false -> result_refusal(Result)
    end.

result_ok(Kind, ok) ->
    lists:member(Kind, [send, shutdown, setopts, udp_send, udp_connect, echo_send, close]);
result_ok(getopts, {ok, []}) ->
    true;
result_ok(getopts, {ok, [{nodelay, Boolean}]}) ->
    is_boolean(Boolean);
result_ok(Kind, {ok, {Ip, Port}}) ->
    lists:member(Kind, [sockname, peername]) andalso ip4(Ip) andalso within(Port, 0, 16#ffff);
result_ok(Kind, {error, Reason}) ->
    lists:member(Reason, kind_reasons(Kind));
result_ok(_Kind, _Result) ->
    false.

result_refusal({error, _}) -> {refused, reason};
result_refusal(_Result) -> {refused, shape}.

%% --- messages and pids -----------------------------------------------------------

grantee() -> pick([local, local, local, 1, 2, 3, 7, ?MAX_U32]).

%% A call, as gen_server:call/3 sends it, now and then malformed.
call(Grantee, Request) ->
    Pid = reply_pid(Grantee),
    From = case rand:uniform(20) of
               1 -> Pid;
               2 -> {Pid};
               3 -> {Pid, tag, extra};
               _ -> {Pid, reply_tag(Grantee)}
           end,
    case rand:uniform(20) of
        1 -> {'$gen_cast', From, Request};
        2 -> {'$gen_call', From};
        3 -> {'$gen_call', From, Request, extra};
        _ -> {'$gen_call', From, Request}
    end.

%% How the grantee's messages arrive, or now and then how they do not: bare, enveloped,
%% enveloped for another domain, enveloped twice or half.
frame(Grantee, Message) ->
    Good = case Grantee of
               local -> Message;
               _ -> {erx_origin, Grantee, Message}
           end,
    pick([Good, Good, Good, Good, Good, Message, {erx_origin, other_origin(Grantee), Message},
          {erx_origin, Grantee, {erx_origin, Grantee, Message}}, {erx_origin, Grantee},
          {erx_origin, Grantee, Message, extra}]).

other_origin(Grantee) when is_integer(Grantee) -> pick([Grantee + 1, Grantee - 1, local, foo, 0]);
other_origin(local) -> pick([1, foo, 0]).

%% A reply target: a process of this process's own domain, of a domain at, next to and far
%% from the grantee's creation, of another node, or no pid at all.
reply_pid(Grantee) ->
    Creations = case Grantee of
                    local -> [0, 1, 2, ?MAX_U32];
                    _ -> [Grantee, Grantee, Grantee, (Grantee + 1) band ?MAX_U32, 0, 1, ?MAX_U32]
                end,
    case rand:uniform(10) of
        1 -> self();
        2 -> self();
        3 -> pid(atom_to_binary(node()), pick(Creations));
        4 -> pid(atom_to_binary(node()), pick(Creations));
        5 -> pid(other_node(), pick(Creations));
        6 -> pid(other_node(), pick(Creations));
        7 -> pid(other_node(), pick(Creations));
        8 -> pick([ok, make_ref(), {a, b}, <<"pid">>, 1, {global, x}]);
        _ -> pid(atom_to_binary(node()), pick(Creations))
    end.

%% A call's tag: a plain reference, as a call with no alias sends, or a reply alias,
%% `[alias | Ref]`, whose reference is of the grantee's domain, of another, of this
%% process's own, or no reference at all. gen:reply/2 sends to the alias.
reply_tag(Grantee) ->
    Creations = case Grantee of
                    local -> [0, 1, ?MAX_U32];
                    _ -> [Grantee, Grantee, Grantee, (Grantee + 1) band ?MAX_U32, 0, ?MAX_U32]
                end,
    case rand:uniform(8) of
        1 -> make_ref();
        2 -> [alias | make_ref()];
        3 -> [alias | ref(other_node(), pick(Creations))];
        4 -> pick([[alias], [alias | self()], [[alias | make_ref()] | x], alias]);
        _ -> [alias | ref(atom_to_binary(node()), pick(Creations))]
    end.

%% A reference of the given node and creation, as NEWER_REFERENCE_EXT carries it, its
%% creation remembered as pid/2 remembers a pid's.
ref(Node, Creation) ->
    Atom = case byte_size(Node) of
               Size when Size < 256 -> <<119, Size, Node/binary>>;
               Size -> <<118, Size:16, Node/binary>>
           end,
    Ref = binary_to_term(<<131, 90, 3:16, Atom/binary, Creation:32, 1:32, 2:32, 3:32>>),
    put({creation, Ref}, Creation),
    Ref.

other_node() ->
    pick([<<"erx_other@nowhere">>, <<"erx_other@nowhere">>, <<"d1@host">>,
          unicode:characters_to_binary(lists:duplicate(100, 16#20ac) ++ "@x")]).

%% A pid of the given node and creation, as the external term format carries it. Its creation
%% is remembered, to be known without reading it back the way the code under test does.
pid(Node, Creation) ->
    Atom = case byte_size(Node) of
               Size when Size < 256 -> <<119, Size, Node/binary>>;
               Size -> <<118, Size:16, Node/binary>>
           end,
    Pid = binary_to_term(<<131, 88, Atom/binary, 1:32, 0:32, Creation:32>>),
    put({creation, Pid}, Creation),
    Pid.

garbage() ->
    case rand:uniform(14) of
        1 -> deep(100000);
        2 -> lists:duplicate(200000, a);
        3 -> binary:copy(<<"x">>, 1000000);
        4 -> {'$gen_call', {self(), make_ref()}, garbage_term(3)};
        5 -> {erx_origin, garbage_term(1), garbage_term(2)};
        6 -> {erx_net, garbage_term(1), garbage_term(2)};
        _ -> garbage_term(4)
    end.

garbage_term(0) ->
    pick([0, -1, 1 bsl 70, 1.5, a, [], <<>>, <<"bin">>, <<1:3>>, self(), make_ref(), "text", #{}, fun() -> ok end]);
garbage_term(Depth) ->
    case rand:uniform(6) of
        1 -> list_to_tuple([garbage_term(Depth - 1) || _ <- lists:seq(1, rand:uniform(5) - 1)]);
        2 -> [garbage_term(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)];
        3 -> [garbage_term(Depth - 1) | garbage_term(Depth - 1)];
        4 -> #{garbage_term(0) => garbage_term(Depth - 1)};
        _ -> garbage_term(0)
    end.

pick(List) -> lists:nth(rand:uniform(length(List)), List).
