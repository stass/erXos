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

**Buffers.** Every byte of a connection's send and receive buffers is reserved at the
grant, within its `buffers` limit (erx_net_grant_core). A connect reserves the initial
buffers, FreeBSD's `tcp_sendspace` and `tcp_recvspace`, before the connection starts, and
is answered `{error, enobufs}` when they do not fit; the connection starts with those
sizes. The grant makes a token for each connection and hands it over in the start; every
later call for the connection's buffers names it, and any call without the right token is
answered `{error, badarg}`, so no process charges or frees another's buffers by naming its
pid in a call. Before a connection grows a buffer, by rounding it to whole segments or by
autosizing, it asks `reserve_buffer/4`; a refusal leaves its buffer as it was. A connection
gives both buffers back with `release_buffers/2` once it needs them no more, in TIME-WAIT
with its socket process gone, and its exit, by whatever means, releases what it still
holds; an `'EXIT'` message naming a connection still alive is not its exit, and is ignored.

Each request is checked here before anything acts on it, as `erx_net_admit:request/2`
will check it: addresses and ports as `gen_tcp` and `gen_udp` give them, a list of
options, a timeout, and the caller as owner. The grant's other limits and its account are
not built: the grant admits every well-formed request whose buffers fit.
""".

-behaviour(gen_server).

-export([start_link/2, reserve_buffer/4, release_buffers/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(MAX_REQUEST, 64).
%% tcp_sendspace and tcp_recvspace, FreeBSD's initial buffer sizes (tcp_usrreq.c).
-define(SNDBUF, 32768).
-define(RCVBUF, 65536).
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

-doc """
Asks the grant to let the calling connection, whose start carried `Token`, hold `Bytes` of
its send or receive buffer, before the connection grows it: `ok`, or `{error, enobufs}`
past the grant's `buffers` limit. Any other caller or token is answered `{error, badarg}`.
""".
-spec reserve_buffer(pid(), reference(), snd | rcv, non_neg_integer()) ->
          ok | {error, enobufs | badarg}.
reserve_buffer(Grant, Token, Kind, Bytes) ->
    gen_server:call(Grant, {reserve_buffer, Token, Kind, Bytes}, infinity).

-doc """
Gives back both buffers of the calling connection, whose start carried `Token`, which needs
them no more: `ok`, or `{error, badarg}` for any other caller or token.
""".
-spec release_buffers(pid(), reference()) -> ok | {error, badarg}.
release_buffers(Grant, Token) ->
    gen_server:call(Grant, {release_buffers, Token}, infinity).

-doc false.
init({Grantee, Limits}) ->
    process_flag(trap_exit, true),
    ok = (erx_net_sup:runtime()):serve(?MAX_REQUEST),
    ok = erx_net_tables:watch_resolver(self()),
    {ok, #{grantee => Grantee, limits => Limits, gen => erx_net_rand:new(erx_net_clock:entropy(16)), callers => #{},
           buffers => erx_net_grant_core:new(Limits), subscriber => none, resolver => none}}.

-doc false.
handle_call({tcp_connect, inet, {A, B, C, D}, Port, Opts, Timeout}, {Owner, _} = From,
            #{grantee := Grantee, gen := Gen0, callers := Callers, buffers := Buffers0} = S)
  when ?IS_BYTE4(A, B, C, D), is_integer(Port), Port > 0, Port =< 16#ffff, is_list(Opts),
       Timeout =:= infinity orelse (is_integer(Timeout) andalso Timeout >= 0) ->
    Initial = #{snd => ?SNDBUF, rcv => ?RCVBUF},
    case erx_net_grant_core:room(Buffers0) >= ?SNDBUF + ?RCVBUF of
        false ->
            {reply, {error, enobufs}, S};
        true ->
            {Child, Gen} = erx_net_rand:split(Gen0),
            Token = make_ref(),
            Start = #{owner => Owner, origin => Grantee, from => From,
                      remote => {<<A, B, C, D>>, Port}, opts => Opts, timeout => Timeout,
                      gen => Child, grant => self(), token => Token, buffers => Initial},
            case erx_tcp_conn:start_link(Start) of
                {ok, Conn} ->
                    %% Nothing else ran in the grant since its room was checked, and the
                    %% connection's first call waits until this one returns.
                    {ok, Buffers} = erx_net_grant_core:open(Conn, Token, Initial, Buffers0),
                    {noreply, S#{gen := Gen, callers := Callers#{Conn => From}, buffers := Buffers}};
                {error, Reason} ->
                    {reply, {error, Reason}, S#{gen := Gen}}
            end
    end;
handle_call({reserve_buffer, Token, Kind, Bytes}, {Conn, _}, #{buffers := Buffers0} = S)
  when is_reference(Token), (Kind =:= snd orelse Kind =:= rcv), is_integer(Bytes), Bytes >= 0 ->
    case erx_net_grant_core:reserve(Conn, Token, Kind, Bytes, Buffers0) of
        {ok, Buffers} -> {reply, ok, S#{buffers := Buffers}};
        {error, _} = Error -> {reply, Error, S}
    end;
handle_call({release_buffers, Token}, {Conn, _}, #{buffers := Buffers0} = S)
  when is_reference(Token) ->
    case erx_net_grant_core:release(Conn, Token, Buffers0) of
        {ok, Buffers} -> {reply, ok, S#{buffers := Buffers}};
        {error, _} = Error -> {reply, Error, S}
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
handle_info({'EXIT', Conn, _Reason}, #{callers := Callers0, buffers := Buffers} = S0) ->
    case is_process_alive(Conn) of
        true ->
            %% A linked process's exit signal arrives only once it is dead, so this is a
            %% message some process sent in its name: it frees nothing and answers no one.
            {noreply, S0};
        false ->
            S = S0#{buffers := erx_net_grant_core:exited(Conn, Buffers)},
            case maps:take(Conn, Callers0) of
                {From, Callers} ->
                    gen_server:reply(From, {error, closed}),
                    {noreply, S#{callers := Callers}};
                error ->
                    {noreply, S}
            end
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
