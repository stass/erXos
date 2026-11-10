%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_grant).
-moduledoc """
A client domain's grant (docs/design-network-stack.md, "The grant's contract", "The
grant"), as far as an active open, a datagram socket and name resolution need it.

**Connect.** `{tcp_connect, inet, Ip, Port, Opts, Timeout}` starts the connection linked
to the grant, with a generator split from its own, owned by the caller, its socket
process, whose messages arrive as the grantee's do; and the grant traps exits, so a
connection's end never ends the grant. The connection answers the connect caller; when it
exits, however it ends, the grant answers that caller `{error, closed}` too, so a
connection that dies before answering leaves no caller waiting. A caller already answered
never sees the second answer: a call's reply alias is gone once its first reply arrived.
A connection's demultiplexing entries are deleted by erx_net_tables, which watches it in
the grant's place.

**Open.** `{udp_open, inet, Local, Port, Opts}` starts a datagram socket (erx_udp_sock)
linked to the grant and owned by the caller, which the socket monitors; `Local` is `any`
or an IPv4 address, `Port` 0 for an ephemeral port, and `Opts` the gen_udp options the
socket checks.

**Resolver.** `resolver` answers `{ok, #{nameservers := [{Ip, 53}], search :=
[binary()]}}`, the name servers and search list of the interfaces' rows
(erx_net:interfaces/0), and changes nothing. `watch_resolver` answers the same and
makes the caller the grant's one subscriber: whenever the answer changes, the
subscriber gets `{erx_net_resolver, Grant, Answer}`, so its domain's inet_db follows the
lease as resolv.conf follows dhclient-script. A domain loads its resolver from one
process, erx_inet, the one caller of `watch_resolver`; a later watcher replaces the
earlier one, so the grant holds one subscriber whatever its client does, and a reader
never displaces it. The grant asks the interfaces only for a request and, while it has
a subscriber, after each notice of erx_net_tables, so a grant nobody asks never calls an
interface.

Each request is checked here before anything acts on it, as `erx_net_admit:request/2`
will check it: addresses and ports as `gen_tcp` and `gen_udp` give them, a list of
options, a timeout, and the caller as owner. The limits, the account and the buffer
reservations of `erx_net_grant_core` are not built: the grant admits every well-formed
request.
""".

-behaviour(gen_server).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(MAX_REQUEST, 64).
-define(DNS_PORT, 53).
-define(MAXNS, 3).
-define(MAXDNSRCH, 6).
-define(IS_BYTE(X), (is_integer(X) andalso X >= 0 andalso X =< 255)).
-define(IS_BYTE4(A, B, C, D), (?IS_BYTE(A) andalso ?IS_BYTE(B) andalso ?IS_BYTE(C) andalso ?IS_BYTE(D))).
-define(IS_IP4(T), (is_tuple(T) andalso tuple_size(T) =:= 4 andalso
                    ?IS_BYTE4(element(1, T), element(2, T), element(3, T), element(4, T)))).

-doc """
Starts the grant of `Grantee`. The node's own grant, `local`, is registered as
`erx_net_grant`, where erx_net:local_grant/0 finds it.
""".
-spec start_link(local, map()) -> {ok, pid()} | {error, term()}.
start_link(local, Limits) when is_map(Limits) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {local, Limits}, []).

-doc false.
init({Grantee, Limits}) ->
    process_flag(trap_exit, true),
    ok = (erx_net_sup:runtime()):serve(?MAX_REQUEST),
    ok = erx_net_tables:watch_resolver(self()),
    {ok, #{grantee => Grantee, limits => Limits, gen => erx_net_rand:new(erx_net_clock:entropy(16)), callers => #{},
           subscriber => none, resolver => none}}.

-doc false.
handle_call({tcp_connect, inet, {A, B, C, D}, Port, Opts, Timeout}, {Owner, _} = From,
            #{grantee := Grantee, gen := Gen0, callers := Callers} = S)
  when ?IS_BYTE4(A, B, C, D), is_integer(Port), Port > 0, Port =< 16#ffff, is_list(Opts),
       Timeout =:= infinity orelse (is_integer(Timeout) andalso Timeout >= 0) ->
    {Child, Gen} = erx_net_rand:split(Gen0),
    Start = #{owner => Owner, origin => Grantee, from => From, remote => {<<A, B, C, D>>, Port}, opts => Opts,
              timeout => Timeout, gen => Child},
    case erx_tcp_conn:start_link(Start) of
        {ok, Conn} -> {noreply, S#{gen := Gen, callers := Callers#{Conn => From}}};
        {error, Reason} -> {reply, {error, Reason}, S#{gen := Gen}}
    end;
handle_call({udp_open, inet, Local, Port, Opts}, {Owner, _}, S)
  when (Local =:= any orelse ?IS_IP4(Local)), is_integer(Port), Port >= 0, Port =< 16#ffff,
       is_list(Opts) ->
    Reply = case erx_udp_sock:options(Opts) of
                {ok, SockOpts} -> erx_udp_sock:open(Port, SockOpts#{ip => Local, owner => Owner});
                {error, _} = Error -> Error
            end,
    {reply, Reply, S};
handle_call(resolver, _From, S) ->
    {reply, {ok, resolver()}, S};
handle_call(watch_resolver, {Pid, _}, #{subscriber := Old} = S) ->
    Resolver = resolver(),
    {reply, {ok, Resolver}, S#{subscriber := subscribe(Pid, Old), resolver := Resolver}};
handle_call(_Request, _From, S) ->
    {reply, {error, badarg}, S}.

-doc false.
handle_cast(_Msg, S) ->
    {noreply, S}.

-doc false.
handle_info({erx_net_tables, resolver}, #{subscriber := none} = S) ->
    {noreply, S};
handle_info({erx_net_tables, resolver}, #{resolver := Old, subscriber := {Pid, _}} = S) ->
    case resolver() of
        Old ->
            {noreply, S};
        New ->
            Pid ! {erx_net_resolver, self(), New},
            {noreply, S#{resolver := New}}
    end;
handle_info({'DOWN', Ref, process, _, _}, #{subscriber := {_, Ref}} = S) ->
    {noreply, S#{subscriber := none}};
handle_info({'EXIT', Conn, _Reason}, #{callers := Callers0} = S) ->
    case maps:take(Conn, Callers0) of
        {From, Callers} ->
            gen_server:reply(From, {error, closed}),
            {noreply, S#{callers := Callers}};
        error ->
            {noreply, S}
    end;
handle_info(_Msg, S) ->
    {noreply, S}.

%% The resolver operation's answer: the interfaces' name servers and search lists, in the
%% order of the interfaces' names, repeats dropped, cut to resolv.conf's limits, three
%% servers and six domains, as FreeBSD's resolver reads at most MAXNS `nameserver` lines
%% and MAXDNSRCH `search` domains (resolv.h).
resolver() ->
    {ok, Ifs} = erx_net:interfaces(),
    Servers = lists:uniq(lists:append([Dns || #{dns := Dns} <- Ifs])),
    Search = lists:uniq(lists:append([Domains || #{search := Domains} <- Ifs])),
    #{nameservers => [{Ip, ?DNS_PORT} || Ip <- lists:sublist(Servers, ?MAXNS)],
      search => lists:sublist(Search, ?MAXDNSRCH)}.

%% The one subscriber: Pid, monitored, in place of the one before it.
subscribe(Pid, {Pid, _} = Same) ->
    Same;
subscribe(Pid, none) ->
    {Pid, erlang:monitor(process, Pid)};
subscribe(Pid, {_, Ref}) ->
    true = erlang:demonitor(Ref, [flush]),
    subscribe(Pid, none).
