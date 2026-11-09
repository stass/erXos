%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_inet).
-moduledoc """
The client side's shared requests (docs/design-network-stack.md, "Modules", "Name
resolution"): grant/0, the one way the backends find their grant, and the domain's
resolver loader, the process that keeps inet_db's name servers and search list those of
the grant's `resolver` operation, as dhclient-script keeps resolv.conf the lease's.

**Loading.** The loader sends the grant `watch_resolver`, which answers the grant's
resolver and makes the loader its subscriber, so each later change arrives as
`{erx_net_resolver, Grant, Answer}`. Every answer, the first and each change, is checked
by resolver_config/1 and loaded by load/1; one that fails the check is dropped and the
previous one stays. When the grant cannot be found, does not answer, or ends, the loader
tries again after a second, doubling the wait up to thirty seconds. A domain without a
grant keeps inet_db as it is.

load/1 puts the answer in place of resolv.conf: it empties inet_db's `resolv_conf`, so
inet_db stops checking a file that erXos does not have and would clear the name servers
on finding it missing; `nameservers` and `search` replace inet_db's; and `dns` joins the
lookup methods after the ones there, so the hosts file still comes first.

**Checking.** The answer comes from another domain, so it is untrusted: a map of exactly
`nameservers`, at most three `{Ip, 53}` with an IPv4 address, and `search`, at most six
entries; anything else refuses the whole answer. Each search entry is checked alone by
the DHCP client's rules (erx_dhcp4_wire's `domain/1`): a binary of labels joined by
dots, each label 1 to 63 letters, digits and hyphens that begins and ends with a letter
or digit, as `res_hnok` takes them, at most 253 bytes, with one trailing dot allowed and
dropped. That is stricter than `res_hnok`, which also takes an empty label, since
inet_dns cannot encode one and would fail the caller's query. An entry that fails is
dropped and the rest of the answer, its name servers included, is loaded. A name that
passes holds no byte a terminal acts on.
""".

-behaviour(gen_server).

-export([grant/0, start_link/0, resolver_config/1, load/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([resolver/0]).

-define(MAXNS, 3).
-define(MAXDNSRCH, 6).
-define(DNS_PORT, 53).
-define(CALL_TIMEOUT, 5000).
-define(RETRY_FIRST, 1000).
-define(RETRY_MOST, 30000).
-define(IS_BYTE(X), (is_integer(X) andalso X >= 0 andalso X =< 255)).

-type resolver() :: #{nameservers := [{inet:ip4_address(), 53}], search := [string()]}.

-doc "The grant the `erx_net_client` application's `grant` key names.".
-spec grant() -> {ok, pid()} | {error, term()}.
grant() ->
    {M, F, A} = application:get_env(erx_net_client, grant, {erx_net, local_grant, []}),
    apply(M, F, A).

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

-doc false.
handle_info(find, #{grant := none, retry := Retry} = S) ->
    case subscribe() of
        {ok, Grant, Ref} -> {noreply, S#{grant := {Grant, Ref}, retry := ?RETRY_FIRST}};
        error -> {noreply, again(S#{retry := min(Retry * 2, ?RETRY_MOST)}, Retry)}
    end;
handle_info({erx_net_resolver, Grant, Answer}, #{grant := {Grant, _}} = S) ->
    ok = take(Answer),
    {noreply, S};
handle_info({'DOWN', Ref, process, _, _}, #{grant := {_, Ref}, retry := Retry} = S) ->
    {noreply, again(S#{grant := none}, Retry)};
handle_info(_Msg, S) ->
    {noreply, S}.

again(S, After) ->
    _ = erlang:send_after(After, self(), find),
    S.

%% Finds the grant, watches it, and loads its first answer. A grant that does not answer
%% is let go, so each retry watches only the grant it found.
subscribe() ->
    maybe
        {ok, Grant} ?= grant(),
        Ref = erlang:monitor(process, Grant),
        {ok, Grant, Ref} ?= answered(Grant, Ref, ask(Grant))
    else
        _ -> error
    end.

answered(Grant, Ref, {ok, Answer}) ->
    ok = take(Answer),
    {ok, Grant, Ref};
answered(_Grant, Ref, _Refused) ->
    true = erlang:demonitor(Ref, [flush]),
    error.

ask(Grant) ->
    try gen_server:call(Grant, watch_resolver, ?CALL_TIMEOUT)
    catch exit:_ -> {error, unreachable}
    end.

take(Answer) ->
    case resolver_config(Answer) of
        {ok, Resolver} -> load(Resolver);
        {error, badarg} -> ok
    end.
