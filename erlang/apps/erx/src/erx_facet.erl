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
anyone hands the pid out. The facet ends when any process or port its grant
names in ends_with ends, with the leading atom of that end's reason
(erx_report:reason_name/1) and never the reason whole, so its grantee's
callers and monitors see no term of the service's (docs/design-domains.md,
"A facet's end carries no terms"): a service's reason can hold what one
grantee sent it. A mint names:

* the grantee, as its domain pid, or as the port of this domain's
  connection to it (erx_connections:connection/1), so the facet ends with
  that domain or that connection;
* the facet or service behind it, so revoking that grant revokes this one.

It monitors them and traps no exits, so its own end ends nothing but itself.

What arrives is sorted by its shape before the callback sees a request:

* a reply to one of the facet's own forwards, {[alias | Alias], Reply},
  whose alias is a forward still outstanding: from a process of the facet's
  own domain, without an envelope, or from the forward's service's domain,
  in the envelope; the facet passes the reply to the grantee's caller. A
  reply from any other party, or a second one, matches nothing and is
  dropped;
* a 'DOWN' of one of its monitors: the end of a process or port in
  ends_with ends the facet, and the end of a forward's service before it replied answers
  the grantee's caller {error, failed}, the request having failed there,
  as an inspect facet's query worker does that OTP ends at its heap limit;
  every other 'DOWN' is dropped. A service's reply precedes its 'DOWN',
  both being its own signals, so a forward it answered is gone by then;
* {'$erx_facet', From, info}, without an envelope: info/1, from the facet's
  own domain;
* a request: {erx_origin, D, {'$gen_call', {Pid, [alias | Alias]}, Request}},
  a gen_server call from the grantee. D, which the connection sets, must be
  the grantee, the message's encoded size at most the grant's max_request,
  and the caller's pid and alias both names of the grantee's (erx:call_from/3),
  so the reply goes to the grantee and never to a third domain. Anything
  else is dropped and counted, with no answer, since an answer would go to
  a name the sender chose. A request past the grant's limit in flight is
  refused with {error, busy}, which the grantee may retry, and one the
  callback refuses with its reason; each is counted. A request of an
  operation the grant does not list is refused before admit/3 sees it (see
  below).
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

From its export on, a facet ends with an atom whatever its loop ends with: a crash of
its callback, in operation/1, admit/3 or message/2, or of the facet itself,
ends it with the leading atom of the crash's reason too, logged with the
callback's name and that atom alone, since the reason can hold the
grantee's request. A callback still refuses what it does not take, since
a crash ends the facet for every caller of its grantee's. An exit signal, which the
facet does not trap, ends it with the signal's own reason; the grantee's export is
send alone, so only processes of the facet's own domain can send one.

A grant's operations, the names its manifest row lists (erx_domain_lib:configured/0),
are checked through the callback's operation/1, which maps a request or a message of
the grantee's to the interface operation it invokes (docs/design-time.md, "On Fiasco").
For a callback with operation/1 the facet admits only the operations the grant lists,
none when it lists none: a request of any other is refused with {error, eperm}, one
that names no operation of the interface with {error, badarg}, and such a message is
dropped, each counted, before the callback's admit/3 or message/2 sees it. A callback
without operation/1 admits what its admit/3 admits, and start/3 refuses a grant that
lists operations to it, since nothing would check them.

Residuals of the behaviour, each in TODO.md: the
generated admission path from the service's operation schema; admission by
the grantee's share of reductions; the funnel's check of max_request
before a message is queued, and the facet's queue quota and heap limit.
""".

-export([start/3, info/1, provide/2, minted/2, serve/2, served/0]).

-callback init(Grant :: grant()) -> {ok, State :: term()}.
-callback admit(Request :: term(), From :: pid(), State :: term()) ->
              {forward, Service :: pid(), Request1 :: term(), State1 :: term()}
            | {reply, Reply :: term(), State1 :: term()}
            | {refuse, Reason :: term(), State1 :: term()}.

%% A message of the grantee's that is no call: forwarded to Service, or dropped.
-callback message(Message :: term(), State :: term()) ->
              {forward, Service :: pid(), State1 :: term()}
            | {drop, State1 :: term()}.

%% The interface operation a request or a message of the grantee's invokes, by its
%% abi/services name, or error for one that invokes none. It is total over any term and
%% creates no atom, and it reads a request as admit/3 does, so the operation it names
%% is the one admit/3 serves.
-callback operation(Request :: term()) -> {ok, Operation :: atom()} | error.
-optional_callbacks([message/2, operation/1]).

-export_type([grant/0]).

%% A grant: the grantee's domain id, the processes and ports whose end ends the facet, the
%% largest message the facet takes from the grantee, in encoded bytes, how many forwards
%% may be outstanding at once, and the operations it grants, none if absent; the
%% callback's own keys besides.
-type grant() :: #{grantee := pos_integer(), ends_with := [pid() | port()],
                   max_request => pos_integer(), in_flight => pos_integer(), operations => [atom()],
                   atom() => term()}.

%% docs/design-domains.md, "What a facet costs its domain": 4 KiB by default.
-define(MAX_REQUEST, 4096).
-define(IN_FLIGHT, 16).
%% How long start/3 waits for the new facet's init and export.
-define(START_TIMEOUT, 5000).

%% The facet's state: its grant's checks, the operations it admits, all for a callback
%% without operation/1, the callback and its state, the monitors of
%% ends_with, each outstanding forward by its monitor, which is also its reply's alias,
%% and the counts info/1 reports.
%% A forward's caller: the grantee's, or none for a forwarded message.
-type forward() :: #{from := {pid(), [alias | reference()]} | none, service := pid()}.
-type state() :: #{callback := module(), cb_state := term(), grantee := pos_integer(), operations := all | [atom()],
                   max_request := pos_integer(), in_flight := pos_integer(), exports := module(),
                   ends_with := #{reference() => pid() | port()}, forwards := #{reference() => forward()},
                   dropped := non_neg_integer(), refused := non_neg_integer()}.

-doc """
Names Mint, a process of this domain, as the mint of the service Name, which a
configured domain serves (docs/design-system.md, "Facets a configured domain
serves"). Call it from the service application's start/2, before init's ready
report, which carries every mint named so far as its provides, each under its
name's text, so the report makes no atom in the system domain (edit 9 of
docs/design-runtime.md); a second call
for Name replaces the first, and a call after the report is refused with
{error, reported}. The system domain, and a runtime that is no node, report
nothing, so there the call is taken and reaches no one. The domain service keeps the mints the report named until
the domain ends, so a mint must live as long as its domain: its end must end
the domain, as the end of a permanent application's process does, and the
domain's restart then provides again and makes every grant anew. The domain
service accepts a mint only for a
service the manifest's service rows declare for this domain, and then sends
it {erx_facet_mint, Tag, Name, Grantee, Principal, Limits} for each configured grant,
arriving as {erx_origin, 4, Request}: the mint acts only on a request in the
system domain's envelope, and starts the facet with start/3, bound to Grantee
and within Limits, and replies minted(Tag, {ok, Facet}), or minted(Tag, Other)
with any other term to refuse. {error, badarg} for a Name that is no atom or a Mint
that is no process of this domain.

A session names its lines this way, its line to the web domain as `web_line`
(erx_web_line_app) and to the SSH domain as `tty_line` (erx_tty_line_app), under
names of ?ERX_LINES, and the domain service sends a line's mint request only for
an erx_domain:line/4 of the system domain's, naming its grantee and its opening
(docs/design-system.md, "A session's lines").
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
which the system domain serves (docs/design-system.md, "Facets of the system
domain's services"): for each configured domain or session the manifest grants
Name, the domain service starts a facet in front of Pid in that domain's ready
answer, and the facet ends with Pid; for a service of the `files` interface Pid
is an erx_fs_grants supervisor, which starts an erx_fs grant bound to the domain
instead.

A ready answer carries only the services named by then. A service the
manifest grants a configured domain is named while its application starts,
before the domain service starts, which creates those domains. A service granted
only to session templates may be named later, by an application started after
the domain service, as the start service's `start` tree is, but before any
session starts: the domain service holds every session's start until the
release's boot has ended (erx_domain_srv). A second call for Name replaces
the first. {error, badarg} for a Name that is no atom or a Pid
that is no local process.
""".
-spec serve(atom(), pid()) -> ok | {error, badarg}.
serve(Name, Pid) when is_atom(Name), is_pid(Pid), node(Pid) =:= node() ->
    persistent_term:put({erx, serves}, (persistent_term:get({erx, serves}, #{}))#{Name => Pid});
serve(_Name, _Pid) ->
    {error, badarg}.

-doc """
The names of the services this domain serves, each named by serve/2, sorted:
in the system domain, the services of the system domain that run there.
""".
-spec served() -> [atom()].
served() ->
    lists:sort(maps:keys(persistent_term:get({erx, serves}, #{}))).

-doc """
A mint's reply to the request tagged Tag (provide/2): {ok, Facet} names the
facet it started, and any other Reply refuses and crosses as the atom
`refused`: the domain service reads nothing more of a refusal, and the
system domain decodes the frame in safe mode (edit 9 of
docs/design-runtime.md), where a reason naming an atom it lacks would drop
the reply whole and leave the domain service's mint operation to its
deadline. It goes to this domain's own
domain pid, which passes it on to the domain service as an answer of this
domain, so the reply names its domain by the connection it came over, and the
mint never needs a pid of the system domain. {error, noconnection} in a
domain with no system connection, which no request reaches.
""".
-spec minted(pos_integer(), term()) -> ok | {error, noconnection}.
minted(Tag, Reply) when is_integer(Tag), Tag > 0 ->
    case persistent_term:get({erx, domain_pid}, none) of
        none -> {error, noconnection};
        DomainPid -> DomainPid ! {erx_facet_minted, Tag, crossing_reply(Reply)}, ok
    end.

crossing_reply({ok, Facet}) when is_pid(Facet) -> {ok, Facet};
crossing_reply(_Refusal) -> refused.

-doc """
Starts a facet of Callback for Grant. Opts may name exports, the export table's
module (erx_dist), for a host test's stand-in. {error, unchecked_operations} for a
grant that lists operations to a callback without operation/1, {error, badarg} for
operations that are no list or an ends_with that names anything but processes and
ports of this node, {error, timeout} when the facet has not started within five
seconds, by then killed and ended, and {error, Reason} when the callback's init fails,
when a process or port of ends_with has already ended, or when the export table refuses the
export.
""".
-spec start(module(), grant(), #{exports => module()}) -> {ok, pid()} | {error, term()}.
start(Callback, #{grantee := Grantee, ends_with := EndsWith} = Grant, Opts)
  when is_atom(Callback), is_integer(Grantee), Grantee > 0, is_list(EndsWith) ->
    maybe
        true ?= lists:all(fun is_end/1, EndsWith) orelse {error, badarg},
        {ok, Operations} ?= operations(Callback, maps:get(operations, Grant, [])),
        start(Callback, Grant, Operations, maps:get(exports, Opts, erx_dist))
    end.

%% What a facet can end with: a process, or a port of this node, the only port
%% erlang:monitor/2 takes.
is_end(Pid) when is_pid(Pid) -> true;
is_end(Port) when is_port(Port) -> node(Port) =:= node();
is_end(_) -> false.

start(Callback, Grant, Operations, Exports) ->
    Parent = self(),
    Tag = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() -> init(Parent, Tag, Callback, Grant, Operations, Exports) end),
    receive
        {Tag, ok} ->
            demonitor(Monitor, [flush]),
            {ok, Pid};
        {'DOWN', Monitor, process, Pid, Reason} ->
            {error, Reason}
    after ?START_TIMEOUT ->
            %% Killed, and answered only once its 'DOWN' is taken, so no facet that
            %% failed to start outlives the answer (docs/design-system.md, "A session's
            %% lines", L4). An acknowledgement sent just before the kill precedes the
            %% 'DOWN' and is dropped, so none stays in a long-lived caller's queue.
            exit(Pid, kill),
            receive {'DOWN', Monitor, process, Pid, _Reason} -> ok end,
            receive {Tag, ok} -> ok after 0 -> ok end,
            {error, timeout}
    end.

-doc "The facet's grantee, limits and counts, asked from the facet's own domain.".
-spec info(pid()) -> #{grantee := pos_integer(), max_request := pos_integer(), in_flight := pos_integer(),
                       dropped := non_neg_integer(), refused := non_neg_integer(),
                       outstanding := non_neg_integer()}.
info(Facet) ->
    {ok, Info} = gen:call(Facet, '$erx_facet', info),
    Info.

%% The operations a facet of Callback admits for a grant that lists Listed: Listed for a
%% callback with operation/1, and all for one without it, whose grant must list none.
operations(Callback, Listed) when is_list(Listed) ->
    case code:ensure_loaded(Callback) =:= {module, Callback} andalso erlang:function_exported(Callback, operation, 1) of
        true -> {ok, Listed};
        false when Listed =:= [] -> {ok, all};
        false -> {error, unchecked_operations}
    end;
operations(_Callback, _Listed) ->
    {error, badarg}.

init(Parent, Tag, Callback, #{grantee := Grantee, ends_with := EndsWith} = Grant, Operations, Exports) ->
    Monitors = maps:from_list([{monitor_end(End), End} || End <- EndsWith]),
    {ok, CbState} = Callback:init(Grant),
    %% No facet starts, or is exported, for a grant one of whose local processes or ports
    %% has ended; the 'DOWN' of one that ends from here on, or of a remote process, ends
    %% the facet.
    case [End || End <- EndsWith, ended(End)] of
        [] -> ok;
        [_ | _] -> exit(noproc)
    end,
    case Exports:export(self(), [send], Grantee) of
        ok -> ok;
        {error, Reason} -> exit({export, Reason})
    end,
    Parent ! {Tag, ok},
    serve(#{callback => Callback, cb_state => CbState, grantee => Grantee, operations => Operations,
            max_request => maps:get(max_request, Grant, ?MAX_REQUEST),
            in_flight => maps:get(in_flight, Grant, ?IN_FLIGHT), exports => Exports,
            ends_with => Monitors, forwards => #{}, dropped => 0, refused => 0}).

%% The exported facet's life. loop/1 returns the reason an end of ends_with gave; a crash
%% is logged by the callback's name and its reason's leading atom. Either way the facet
%% exits with the reason's leading atom alone (docs/design-domains.md, "A facet's end
%% carries no terms").
-spec serve(state()) -> no_return().
serve(#{callback := Callback} = State) ->
    Reason = try
                 loop(State)
             catch
                 _Class:Crash ->
                     logger:error("facet of ~ts crashed: ~ts", [Callback, erx_report:reason_name(Crash)]),
                     Crash
             end,
    exit(erx_report:reason_name(Reason)).

%% The monitor of a process or port the facet ends with (is_end/1), and whether a local
%% one has already ended.
monitor_end(Pid) when is_pid(Pid) -> monitor(process, Pid);
monitor_end(Port) when is_port(Port) -> monitor(port, Port).

ended(Pid) when is_pid(Pid) -> node(Pid) =:= node() andalso not is_process_alive(Pid);
ended(Port) when is_port(Port) -> erlang:port_info(Port, id) =:= undefined.

%% The reason of the end of ends_with that ends the facet.
-spec loop(state()) -> term().
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
        {'DOWN', Monitor, _Type, _End, Reason} when is_map_key(Monitor, EndsWith) ->
            Reason;
        {'DOWN', Monitor, process, _Pid, _Reason} when is_map_key(Monitor, Forwards) ->
            loop(replied(Monitor, {error, failed}, State));
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
%% counted otherwise. erx:call_from/3 admits only a From of {Pid, [alias | Alias]},
%% the shape admit/3 and a forward rely on.
request({erx_origin, Grantee, {'$gen_call', From, Request} = Message},
        #{grantee := Grantee, max_request := MaxRequest, exports := Exports} = State) ->
    case erlang:external_size(Message) =< MaxRequest andalso
         erx:call_from(Grantee, From, fun Exports:owner/1) of
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
         erlang:function_exported(Callback, message, 2) andalso granted(Message, State) =:= ok of
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
    refuse(From, busy, State);
admit(Request, {Pid, _Tag} = From, #{callback := Callback, cb_state := CbState} = State) ->
    case granted(Request, State) of
        ok -> decided(Callback:admit(Request, Pid, CbState), From, State);
        Refusal -> refuse(From, Refusal, State)
    end.

%% The callback's decision on a request the grant admits.
decided(Decision, From, State) ->
    case Decision of
        {forward, Service, Request1, CbState1} when is_pid(Service) ->
            forward(Service, {call, Request1}, From, State#{cb_state := CbState1});
        {reply, Reply, CbState1} ->
            gen:reply(From, Reply),
            State#{cb_state := CbState1};
        {refuse, Reason, CbState1} ->
            refuse(From, Reason, State#{cb_state := CbState1})
    end.

%% Whether the grant admits the operation Request, a request or a message of the
%% grantee's, invokes: ok, eperm for an operation the grant does not list, or badarg for
%% a request that invokes no operation of the interface.
granted(_Request, #{operations := all}) ->
    ok;
granted(Request, #{callback := Callback, operations := Operations}) ->
    case Callback:operation(Request) of
        {ok, Operation} ->
            case lists:member(Operation, Operations) of
                true -> ok;
                false -> eperm
            end;
        error ->
            badarg
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
