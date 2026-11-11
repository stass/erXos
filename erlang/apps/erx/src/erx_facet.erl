%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_facet).
-moduledoc """
The facet behaviour (docs/design-domains.md, "Facets"): a process that stands
for one grant of one service to one grantee domain, bound to that grantee
when it is minted, so the checks below hold for every facet by construction.

start/3 runs the callback's init/1 in the new process, exports the facet's
pid toward the grantee with send alone, and only then returns the pid, so
the grantee can message and monitor the facet and nothing more, before
anyone hands the pid out. The facet ends, with the same reason, when a
process its grant names in ends_with ends: the grantee's domain pid, so
the facet ends with its domain, and the facet or service behind it, so
revoking that grant revokes this one. It monitors them and traps no exits,
so its own end ends nothing but itself.

What arrives is sorted by its shape before the callback sees a request:

* a reply to one of the facet's own forwards, {[alias | Alias], Reply},
  whose alias is a forward still outstanding: from a process of the facet's
  own domain, without an envelope, or from the forward's service's domain,
  in the envelope; the facet passes the reply to the grantee's caller. A
  reply from any other party, or a second one, matches nothing and is
  dropped;
* a 'DOWN' of one of its monitors: the end of a process in ends_with ends
  the facet, and the end of a forward's service drops the forward, whose
  request failed there; every other 'DOWN' is dropped;
* {'$erx_facet', From, info}, without an envelope: info/1, from the facet's
  own domain;
* a request: {erx_origin, D, {'$gen_call', {Pid, [alias | Alias]}, Request}},
  a gen_server call from the grantee. D, which the connection sets, must be
  the grantee, the message's encoded size at most the grant's max_request,
  and the caller's pid and alias both names of the grantee's (erx:owner/1),
  so the reply goes to the grantee and never to a third domain. Anything
  else is dropped and counted, with no answer, since an answer would go to
  a name the sender chose. A request past the grant's limit in flight is
  refused with {error, badarg} and counted, as is one the callback refuses.
  admit/3 decides the rest: a reply, a refusal, or a forward, which the
  behaviour sends itself as a gen_server call with a fresh alias as its tag;
* a message of the grantee's in no call's shape, {erx_origin, Grantee, Message},
  within max_request, for a protocol of plain messages such as a tty's: the
  callback's message/2 forwards or drops it, and the behaviour forwards it as
  {'$erx_facet_message', ReplyTo, Grantee, Message}, which the service answers
  as a call, at ReplyTo. No request of the grantee's can take that shape, since
  the behaviour forwards every request inside a '$gen_call', so the service
  learns the grantee from the facet and never from the grantee, and gets
  nothing of the grantee's in a shape an OTP module would act on; a service
  behind a facet that forwards every request must still take none it would not
  serve its grantee. The service's answer is
  dropped. The forward counts toward the limit in flight, so a grantee has at
  most that many messages in the service's queue; past it a message is dropped
  and counted, as is every message to a callback without message/2.

Every other message, a local one without an envelope included, is dropped
and counted: a facet acts for its grantee alone.

Stopgap residuals of the behaviour, each in TODO.md: the
generated admission path from the service's operation schema; admission by
the grantee's share of reductions; the funnel's check of max_request
before a message is queued, and the facet's queue quota and heap limit.
""".

-export([start/3, info/1, provide/2, minted/2, serve/2]).

-callback init(Grant :: grant()) -> {ok, State :: term()}.
-callback admit(Request :: term(), From :: pid(), State :: term()) ->
              {forward, Service :: pid(), Request1 :: term(), State1 :: term()}
            | {reply, Reply :: term(), State1 :: term()}
            | {refuse, Reason :: term(), State1 :: term()}.

%% A message of the grantee's that is no call: forwarded to Service, or dropped.
-callback message(Message :: term(), State :: term()) ->
              {forward, Service :: pid(), State1 :: term()}
            | {drop, State1 :: term()}.
-optional_callbacks([message/2]).

-export_type([grant/0]).

%% A grant: the grantee's domain id, the processes whose end ends the facet, the largest
%% message the facet takes from the grantee, in encoded bytes, and how many forwards may
%% be outstanding at once; the callback's own keys besides.
-type grant() :: #{grantee := pos_integer(), ends_with := [pid()],
                   max_request => pos_integer(), in_flight => pos_integer(), atom() => term()}.

%% docs/design-domains.md, "What a facet costs its domain": 4 KiB by default.
-define(MAX_REQUEST, 4096).
-define(IN_FLIGHT, 16).
%% How long start/3 waits for the new facet's init and export.
-define(START_TIMEOUT, 5000).

%% The facet's state: its grant's checks, the callback and its state, the monitors of
%% ends_with, each outstanding forward by its monitor, which is also its reply's alias,
%% and the counts info/1 reports.
%% A forward's caller: the grantee's, or none for a forwarded message.
-type forward() :: #{from := {pid(), [alias | reference()]} | none, service := pid()}.
-type state() :: #{callback := module(), cb_state := term(), grantee := pos_integer(),
                   max_request := pos_integer(), in_flight := pos_integer(), exports := module(),
                   ends_with := #{reference() => pid()}, forwards := #{reference() => forward()},
                   dropped := non_neg_integer(), refused := non_neg_integer()}.

-doc """
Names Mint, a process of this domain, as the mint of the service Name, which a
configured domain serves (docs/design-system.md, "Facets a configured domain
serves"). Call it from the service application's start/2, before init's ready
report, which carries every mint named so far as its provides; a second call
for Name replaces the first, and a call after the report is refused with
{error, reported}. The system domain, and a runtime that is no node, report
nothing, so there the call is taken and reaches no one. The domain service keeps the mints the report named until
the domain ends, so a mint must live as long as its domain: its end must end
the domain, as the end of a permanent application's process does, and the
domain's restart then provides again and makes every grant anew. The domain
service accepts a mint only for a
service the manifest's service rows declare for this domain, and then sends
it {erx_facet_mint, Tag, Name, Grantee, Limits} for each configured grant,
arriving as {erx_origin, 4, Request}: the mint acts only on a request in the
system domain's envelope, and starts the facet with start/3, bound to Grantee
and within Limits, and replies minted(Tag, {ok, Facet}), or minted(Tag, Other)
with any other term to refuse. {error, badarg} for a Name that is no atom or a Mint
that is no process of this domain.

A session names one process this way, its line to the web domain as `web_line`
(erx_web_line_app), which the domain service keeps for erx_domain:web_line/2 until
the session ends and mints nothing for.
""".
-spec provide(atom(), pid()) -> ok | {error, badarg | reported}.
provide(Name, Mint) when is_atom(Name), is_pid(Mint), node(Mint) =:= node() ->
    %% init leaves reported in the term once its ready report has taken the mints.
    case persistent_term:get({erx, provides}, #{}) of
        reported -> {error, reported};
        Provides -> persistent_term:put({erx, provides}, Provides#{Name => Mint})
    end;
provide(_Name, _Mint) ->
    {error, badarg}.

-doc """
Names Pid, a process of the system domain, as the one behind the service Name,
which the system domain serves (docs/design-system.md, "Facets a configured
domain serves"): for each configured domain the manifest grants Name, the
domain service starts a facet in front of Pid in that domain's ready answer, and
the facet ends with Pid. Call it while the service's application starts,
before the domain service starts; a second call for Name replaces the first.
{error, badarg} for a Name that is no atom or a Pid that is no local process.
""".
-spec serve(atom(), pid()) -> ok | {error, badarg}.
serve(Name, Pid) when is_atom(Name), is_pid(Pid), node(Pid) =:= node() ->
    persistent_term:put({erx, serves}, (persistent_term:get({erx, serves}, #{}))#{Name => Pid});
serve(_Name, _Pid) ->
    {error, badarg}.

-doc """
A mint's reply to the request tagged Tag (provide/2): {ok, Facet} names the
facet it started, and any other Reply refuses. It goes to this domain's own
domain pid, which passes it on to the domain service as an answer of this
domain, so the reply names its domain by the connection it came over, and the
mint never needs a pid of the system domain. {error, noconnection} in a
domain with no system connection, which no request reaches.
""".
-spec minted(pos_integer(), term()) -> ok | {error, noconnection}.
minted(Tag, Reply) when is_integer(Tag), Tag > 0 ->
    case persistent_term:get({erx, domain_pid}, none) of
        none -> {error, noconnection};
        DomainPid -> DomainPid ! {erx_facet_minted, Tag, Reply}, ok
    end.

-doc """
Starts a facet of Callback for Grant. Opts may name exports, the export table's
module (erx_dist), for a host test's stand-in. {error, Reason} when the callback's
init fails, when a process of ends_with has already ended, or when the export
table refuses the export.
""".
-spec start(module(), grant(), #{exports => module()}) -> {ok, pid()} | {error, term()}.
start(Callback, #{grantee := Grantee, ends_with := EndsWith} = Grant, Opts)
  when is_atom(Callback), is_integer(Grantee), Grantee > 0, is_list(EndsWith) ->
    Exports = maps:get(exports, Opts, erx_dist),
    Parent = self(),
    Tag = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() -> init(Parent, Tag, Callback, Grant, Exports) end),
    receive
        {Tag, ok} ->
            demonitor(Monitor, [flush]),
            {ok, Pid};
        {'DOWN', Monitor, process, Pid, Reason} ->
            {error, Reason}
    after ?START_TIMEOUT ->
            demonitor(Monitor, [flush]),
            exit(Pid, kill),
            {error, timeout}
    end.

-doc "The facet's grantee, limits and counts, asked from the facet's own domain.".
-spec info(pid()) -> #{grantee := pos_integer(), max_request := pos_integer(), in_flight := pos_integer(),
                       dropped := non_neg_integer(), refused := non_neg_integer(),
                       outstanding := non_neg_integer()}.
info(Facet) ->
    {ok, Info} = gen:call(Facet, '$erx_facet', info),
    Info.

init(Parent, Tag, Callback, #{grantee := Grantee, ends_with := EndsWith} = Grant, Exports) ->
    Monitors = maps:from_list([{monitor(process, Pid), Pid} || Pid <- EndsWith]),
    {ok, CbState} = Callback:init(Grant),
    %% No facet starts, or is exported, for a grant one of whose local processes has
    %% ended; the 'DOWN' of one that ends from here on, or of a remote one, ends the facet.
    case [Pid || Pid <- EndsWith, node(Pid) =:= node(), not is_process_alive(Pid)] of
        [] -> ok;
        [_ | _] -> exit(noproc)
    end,
    case Exports:export(self(), [send], Grantee) of
        ok -> ok;
        {error, Reason} -> exit({export, Reason})
    end,
    Parent ! {Tag, ok},
    loop(#{callback => Callback, cb_state => CbState, grantee => Grantee,
           max_request => maps:get(max_request, Grant, ?MAX_REQUEST),
           in_flight => maps:get(in_flight, Grant, ?IN_FLIGHT), exports => Exports,
           ends_with => Monitors, forwards => #{}, dropped => 0, refused => 0}).

-spec loop(state()) -> no_return().
loop(#{ends_with := EndsWith, forwards := Forwards, exports := Exports} = State) ->
    receive
        {[alias | Alias], Reply} when is_map_key(Alias, Forwards) ->
            loop(replied(Alias, Reply, State));
        {erx_origin, D, {[alias | Alias], Reply}} = Message when is_map_key(Alias, Forwards) ->
            #{Alias := #{service := Service}} = Forwards,
            case Exports:owner(Service) of
                D -> loop(replied(Alias, Reply, State));
                _ -> loop(request(Message, State))
            end;
        {'DOWN', Monitor, process, _Pid, Reason} when is_map_key(Monitor, EndsWith) ->
            exit(Reason);
        {'DOWN', Monitor, process, _Pid, _Reason} when is_map_key(Monitor, Forwards) ->
            loop(State#{forwards := maps:remove(Monitor, Forwards)});
        {'DOWN', _Monitor, _Type, _Object, _Info} ->
            loop(State);
        {'$erx_facet', From, info} ->
            gen:reply(From, info_of(State)),
            loop(State);
        Message ->
            loop(request(Message, State))
    end.

info_of(#{grantee := Grantee, max_request := MaxRequest, in_flight := InFlight, dropped := Dropped,
          refused := Refused, forwards := Forwards}) ->
    #{grantee => Grantee, max_request => MaxRequest, in_flight => InFlight, dropped => Dropped,
      refused => Refused, outstanding => map_size(Forwards)}.

%% The service's reply to the forward under Alias goes to the grantee's caller.
replied(Alias, Reply, #{forwards := Forwards} = State) ->
    {#{from := From}, Rest} = maps:take(Alias, Forwards),
    demonitor(Alias, [flush]),
    [gen:reply(From, Reply) || From =/= none],
    State#{forwards := Rest}.

%% A message that is no reply, signal or info: a request if the grantee sent it in the
%% shape a request has, within the size the grant allows, and its reply goes to a name of
%% the grantee's; a message of the grantee's if it is in no call's shape; dropped and
%% counted otherwise.
request({erx_origin, Grantee, {'$gen_call', {Pid, [alias | Alias]} = From, Request} = Message},
        #{grantee := Grantee, max_request := MaxRequest, exports := Exports} = State)
  when is_pid(Pid), is_reference(Alias) ->
    case erlang:external_size(Message) =< MaxRequest andalso
         Exports:owner(Pid) =:= Grantee andalso Exports:owner(Alias) =:= Grantee of
        true -> admit(Request, From, State);
        false -> dropped(State)
    end;
request({erx_origin, Grantee, Message}, #{grantee := Grantee} = State)
  when not is_tuple(Message); element(1, Message) =/= '$gen_call' ->
    message(Message, State);
request(_Message, State) ->
    dropped(State).

message(Message, #{max_request := MaxRequest, forwards := Forwards, in_flight := InFlight,
                   callback := Callback, cb_state := CbState, grantee := Grantee} = State) ->
    case erlang:external_size(Message) =< MaxRequest andalso map_size(Forwards) < InFlight andalso
         erlang:function_exported(Callback, message, 2) of
        true ->
            case Callback:message(Message, CbState) of
                {forward, Service, CbState1} when is_pid(Service) ->
                    forward(Service, {message, Grantee, Message}, none,
                            State#{cb_state := CbState1});
                {drop, CbState1} ->
                    dropped(State#{cb_state := CbState1})
            end;
        false ->
            dropped(State)
    end.

admit(_Request, From, #{forwards := Forwards, in_flight := InFlight} = State)
  when map_size(Forwards) >= InFlight ->
    refuse(From, badarg, State);
admit(Request, {Pid, _Tag} = From, #{callback := Callback, cb_state := CbState} = State) ->
    case Callback:admit(Request, Pid, CbState) of
        {forward, Service, Request1, CbState1} when is_pid(Service) ->
            forward(Service, {call, Request1}, From, State#{cb_state := CbState1});
        {reply, Reply, CbState1} ->
            gen:reply(From, Reply),
            State#{cb_state := CbState1};
        {refuse, Reason, CbState1} ->
            refuse(From, Reason, State#{cb_state := CbState1})
    end.

%% A forward to Service whose reply target is the alias of a monitor on it, as gen:call
%% makes one, so the reply and the service's end both name the forward: a request as a
%% gen_server call, a message as '$erx_facet_message', which no request can be.
forward(Service, Forward, From, #{forwards := Forwards} = State) ->
    Alias = monitor(process, Service, [{alias, demonitor}]),
    ReplyTo = {self(), [alias | Alias]},
    Service ! case Forward of
                  {call, Request} -> {'$gen_call', ReplyTo, Request};
                  {message, Grantee, Message} -> {'$erx_facet_message', ReplyTo, Grantee, Message}
              end,
    State#{forwards := Forwards#{Alias => #{from => From, service => Service}}}.

refuse(From, Reason, #{refused := Refused} = State) ->
    gen:reply(From, {error, Reason}),
    State#{refused := Refused + 1}.

dropped(#{dropped := Dropped} = State) ->
    State#{dropped := Dropped + 1}.
