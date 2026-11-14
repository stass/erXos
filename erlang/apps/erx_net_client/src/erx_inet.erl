%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_inet).
-moduledoc """
The client side's one path to the grant, and the domain's resolver loader
(docs/design-network-stack.md, "Modules", "Answers from the grant", "Name resolution").

**The path to the grant.** call/1 finds the grant through the `erx_net_client`
application's `grant` key, an `{M, F, A}` that answers `{ok, Grant, Origin}` or
`{error, Reason}`, calls it, and answers what erx_sock_admit:answer/3 rebuilt from the
grant's reply. This module alone reads the key and exports no grant pid, so every
answer of the grant passes the check before program code sees it; both are build
checks. The call waits with the timeout `infinity`, as every call of the stack does:
its monitor ends the wait when the grant ends, which answers `{error, closed}`, and an
open's own timeout is the socket's to enforce. An answer that fails the check is
`{error, badarg}` and one line in the log naming the operation and the check, never
the term.

**Exposing.** A socket the network domain starts may link to its socket process, which
a pid handed to another domain does not allow (docs/design-domains.md, "Exports"), so
expose/1 exposes the calling socket process to the grant's domain with `send` and `link`,
trapping its exits first: open/1 calls it for the opener of a listener, before the grant
starts the listener, and an accept's socket process calls it as it starts (erx_gen_tcp).

**Loading.** The loader, the process that keeps inet_db's name servers and search list
those of the grant's `resolver` operation as dhclient-script keeps resolv.conf the
lease's, sends the grant `watch_resolver` through the same path. The grant answers its
resolver and makes the loader its subscriber, so each later change arrives as
`{erx_net_resolver, Grant, Answer}`, bare from a grant of the loader's own domain and
in the envelope `{erx_origin, D, Msg}` from a grant of domain `D`; erx_sock_admit:change/3
takes the envelope off and checks the answer against the grant and the origin it was
found with. Every answer, the first and each change, is loaded by load/1 once it passes;
one that fails is dropped and the previous one stays. The loader watches the grant it
found, whatever its first answer, and looks for a grant again only when it finds none
or the grant ends: after a second, doubling the wait up to thirty seconds. A domain
without a grant keeps inet_db as it is.

load/1 puts the answer in place of resolv.conf: it empties inet_db's `resolv_conf`, so
inet_db stops checking a file that erXos does not have and would clear the name servers
on finding it missing; `nameservers` and `search` replace inet_db's; and `dns` joins the
lookup methods after the ones there, so the hosts file still comes first.

**Checking.** resolver_config/1 is the resolver reply type's check, which
erx_sock_admit applies: a map of exactly `nameservers`, at most three `{Ip, 53}` with an
IPv4 address, and `search`, at most six entries; anything else refuses the whole
answer. Each search entry is checked alone by the DHCP client's rules (erx_dhcp4_wire's
`domain/1`): a binary of labels joined by dots, each label 1 to 63 letters, digits and
hyphens that begins and ends with a letter or digit, as `res_hnok` takes them, at most
253 bytes, with one trailing dot allowed and dropped. That is stricter than `res_hnok`,
which also takes an empty label, since inet_dns cannot encode one and would fail the
caller's query. An entry that fails is dropped and the rest of the answer, its name
servers included, is loaded. A name that passes holds no byte a terminal acts on.
""".

-behaviour(gen_server).

-export([call/1, open/1, expose/1, start_link/0, resolver_config/1, load/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([request/0, resolver/0]).

-define(MAXNS, 3).
-define(MAXDNSRCH, 6).
-define(DNS_PORT, 53).
-define(RETRY_FIRST, 1000).
-define(RETRY_MOST, 30000).
-define(IS_BYTE(X), (is_integer(X) andalso X >= 0 andalso X =< 255)).

-type resolver() :: #{nameservers := [{inet:ip4_address(), 53}], search := [string()]}.

-doc "A request of the grant, each operation's as the grant takes it.".
-type request() :: {tcp_connect, inet, inet:ip4_address(), inet:port_number(), [term()], timeout()}
                 | {udp_open, inet, any | inet:ip4_address(), inet:port_number(), [term()]}
                 | {tcp_listen, inet, any | inet:ip4_address(), inet:port_number(), [term()]}
                 | {icmp_open, inet}
                 | interfaces
                 | resolver
                 | watch_resolver.

-doc """
Calls the grant with `Request` and answers its reply as erx_sock_admit admitted it: an
open's `{ok, Pid}`, the interfaces' `{ok, [map()]}`, a resolver's `{ok, resolver()}`, or
`{error, Reason}`.
""".
-spec call(request()) -> {ok, pid() | [map()] | resolver()} | {error, term()}.
call(Request) ->
    case find() of
        {ok, Grant, _Origin} -> ask(Grant, Request);
        {error, _} = Error -> Error
    end.

-doc """
Opens a socket as call/1 does, and answers with the socket's pid the origin its grant
was found with (erx_sock_admit:origin()), against which the socket's pushes are checked.
A listener links to its socket process, the caller, as it starts, so a listen first
exposes the caller to the grant's domain (expose/1), and a refused export is the listen's
answer; a connection, a datagram and an echo socket only monitor their socket processes,
and their opens expose nothing.
""".
-spec open(request()) -> {ok, pid(), erx_sock_admit:origin()} | {error, term()}.
open(Request) ->
    maybe
        {ok, Grant, Origin} ?= find(),
        ok ?= expose_opener(Request, Origin),
        {ok, Socket} ?= ask(Grant, Request),
        {ok, Socket, Origin}
    end.

-doc """
Exposes the calling socket process to `Origin`, the domain its grant's messages arrive
from, so that its socket can link to it (erx_net_client_erxos:expose/2). It sets
`trap_exit` first, so a link from that domain can never end the caller, whoever calls
this. Within one domain, `Origin` `local`, a link needs no export: nothing is exposed and
no module of erXos is called. A grant's domain with no connection to this one answers as
a closed socket, as a grant that has ended does (ask/2).
""".
-spec expose(erx_sock_admit:origin()) -> ok | {error, closed | badarg | system_limit}.
expose(local) ->
    ok;
expose(Origin) ->
    process_flag(trap_exit, true),
    case erx_net_client_erxos:expose(self(), Origin) of
        {error, noconnection} -> {error, closed};
        Answer -> Answer
    end.

%% The opens whose socket links to its socket process, the caller: a listener's, as it
%% starts (erx_tcp_listen). This list widens with every socket of the network side that
%% comes to link to its socket process.
expose_opener({tcp_listen, _Family, _Local, _Port, _Opts}, Origin) -> expose(Origin);
expose_opener(_Request, _Origin) -> ok.

%% The grant and its origin, from the one reader of the `grant` key.
find() ->
    {M, F, A} = application:get_env(erx_net_client, grant, {erx_net, local_grant, []}),
    case apply(M, F, A) of
        {ok, Grant, Origin} when is_pid(Grant) -> {ok, Grant, Origin};
        {error, _} = Error -> Error
    end.

%% The one call of the grant: the request, then the reply through its admission. Only
%% the call is guarded, so a grant that ends answers as a closed socket and no crash of
%% the check is mistaken for one.
ask(Grant, Request) ->
    Operation = operation(Request),
    try gen_server:call(Grant, Request, infinity) of
        Answer -> admitted(Operation, Grant, Answer)
    catch
        exit:_ -> {error, closed}
    end.

operation(Request) when is_atom(Request) -> Request;
operation(Request) when is_tuple(Request) -> element(1, Request).

admitted(Operation, Grant, Answer) ->
    case erx_sock_admit:answer(Operation, Grant, Answer) of
        {ok, Reply} ->
            Reply;
        {refused, Check} ->
            logger:warning("erx_inet: the grant's answer to ~s fails the ~s check", [Operation, Check]),
            {error, badarg}
    end.

-doc "Starts the resolver loader, registered as `erx_inet`.".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Checks the grant's `resolver` answer; the search list comes back as strings, as inet_db takes it.".
-spec resolver_config(term()) -> {ok, resolver()} | {error, badarg}.
resolver_config(#{nameservers := Servers, search := Search} = Answer)
  when map_size(Answer) =:= 2, is_list(Servers), length(Servers) =< ?MAXNS,
       is_list(Search), length(Search) =< ?MAXDNSRCH ->
    case lists:all(fun server/1, Servers) of
        true -> {ok, #{nameservers => Servers,
                       search => [binary_to_list(D) || {ok, D} <- lists:map(fun domain/1, Search)]}};
        false -> {error, badarg}
    end;
resolver_config(_Answer) ->
    {error, badarg}.

server({{A, B, C, D}, ?DNS_PORT}) -> ?IS_BYTE(A) andalso ?IS_BYTE(B) andalso ?IS_BYTE(C) andalso ?IS_BYTE(D);
server(_) -> false.

%% A search domain without its trailing dot, by erx_dhcp4_wire's domain/1, whose rules
%% these are: erx_net_client needs only kernel and stdlib, so it cannot call it.
domain(Name) when is_binary(Name) ->
    Bare = case Name of
               <<Head:(byte_size(Name) - 1)/binary, $.>> -> Head;
               _ -> Name
           end,
    case byte_size(Bare) =< 253 andalso lists:all(fun label/1, binary:split(Bare, <<".">>, [global])) of
        true -> {ok, Bare};
        false -> error
    end;
domain(_) ->
    error.

label(Label) when byte_size(Label) >= 1, byte_size(Label) =< 63 ->
    border(binary:first(Label)) andalso border(binary:last(Label))
        andalso lists:all(fun(C) -> border(C) orelse C =:= $- end, binary_to_list(Label));
label(_) ->
    false.

border(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse (C >= $0 andalso C =< $9).

-doc "Loads a checked answer into inet_db.".
-spec load(resolver()) -> ok.
load(#{nameservers := Servers, search := Search}) ->
    ok = inet_db:res_option(resolv_conf, ""),
    ok = inet_db:res_option(nameservers, Servers),
    ok = inet_db:res_option(search, Search),
    Lookup = inet_db:res_option(lookup),
    case lists:member(dns, Lookup) of
        true -> ok;
        false -> inet_db:res_option(lookup, Lookup ++ [dns])
    end.

%% --- The loader ------------------------------------------------------------------

-doc false.
init([]) ->
    self() ! find,
    {ok, #{grant => none, retry => ?RETRY_FIRST}}.

-doc false.
handle_call(_Request, _From, S) ->
    {reply, {error, badarg}, S}.

-doc false.
handle_cast(_Msg, S) ->
    {noreply, S}.

%% `grant` is `none` or the grant watched, `{Grant, Origin, Monitor}`; it is set before
%% the first answer is asked for, so the grant's end is seen whatever that answer is.
-doc false.
handle_info(find, #{grant := none, retry := Retry} = S) ->
    case find() of
        {ok, Grant, Origin} ->
            Ref = erlang:monitor(process, Grant),
            ok = take(ask(Grant, watch_resolver)),
            {noreply, S#{grant := {Grant, Origin, Ref}, retry := ?RETRY_FIRST}};
        {error, _} ->
            {noreply, again(S#{retry := min(Retry * 2, ?RETRY_MOST)}, Retry)}
    end;
handle_info({'DOWN', Ref, process, _, _}, #{grant := {_, _, Ref}, retry := Retry} = S) ->
    {noreply, again(S#{grant := none}, Retry)};
%% Every other message to a loader that watches a grant is checked as a change of that
%% grant; whatever fails the check, a stray message among them, is dropped.
handle_info(Message, #{grant := {Grant, Origin, _}} = S) ->
    case erx_sock_admit:change(Origin, Grant, Message) of
        {ok, Resolver} -> ok = load(Resolver);
        {refused, _} -> ok
    end,
    {noreply, S};
handle_info(_Message, S) ->
    {noreply, S}.

again(S, After) ->
    _ = erlang:send_after(After, self(), find),
    S.

%% Loads the first answer when it passed; a refusal leaves inet_db as it is.
take({ok, Resolver}) -> load(Resolver);
take({error, _}) -> ok.
