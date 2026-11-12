%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_pid).
-moduledoc """
A domain pid (docs/design-domains.md, "Domains"): an ordinary process of the
system domain that stands for one domain. It traps exits. An exit signal
with any reason but normal, from anyone but the domain service, asks the
service to stop the domain; normal is ignored, as a process that does not
trap exits ignores it. The pid ends with {domain_down, Id, Info} when the
service tells it the domain ended, so its links and monitors see the
domain's end, after passing on every message of the domain still in its
queue, so a report the domain made before its end reaches the service
before the pid's end does; a kill ends it at once, and the service, which links to it,
then stops the domain. The service's own end ends the pid with the
service's reason, once the service is dead, since a trapped exit can be
forged as a plain message: that end ends the system domain and every domain with it
(erx_domain_sup), so there is no domain left to stop.

Ref is the secret the service made with the pid: only messages tagged with
it come from the service.

The pid is also its domain's correspondent. A message from the domain arrives
as {erx_origin, Id, Msg}, the envelope the system domain's peer puts on every
frame of the domain's lane (edit 16 of docs/design-runtime.md), and the pid
acts on Msg only when Id is its own domain's and Msg is init's ready report
(edit 65) or one of the agent's three answers (docs/design-domains.md,
"Messages between the domain service and a runtime"). The first report must
name, as the connection agent, a pid of the domain's own node; the pid keeps
that agent, the one process of the system domain that does, and passes on
the report's provides, the mints the domain names for its services
(docs/design-system.md, "Facets a configured domain serves"), as
{domain_ready, Ref, Id, Provides, Inspect}, untouched for the service to
authenticate, with the inspection agent the report names as `inspect`, kept
only when the domain's incarnation owns it, and `none` otherwise, and each
answer as {domain_answer, Ref, Id, Answer}. Every other message, a second report, the
creator's or any other domain's included, is dropped and counted; the
service reads the count with {Ref, info, From}. A process of the system
domain can write the envelope itself, so the check keeps other domains,
not the system domain's own trusted processes, from speaking for this one.

The pid writes the records the service hands it, {Ref, record, Slot, Record},
into its domain's control table (docs/design-domains.md, "The control
table"), through the system side's port the service handed it, {Ref, port,
Port}: with the lane driver's control command 3, as a frame from itself to the
agent, never as an ordinary message, which could wait behind a full lane or a
paused port. The driver refuses the call with badarg from any other process
and for a record that does not fit; the pid does not catch it, so its end
stops the domain. A record for a side that has ended is dropped, since the
domain's end is under way.

The service's answer to the ready report, {Ref, facets, Facets}, the domain's
facets by name, the pid sends its agent as {erx_facets, Facets}, an ordinary
message, which the agent hands its init (edit 65), and never suspended: if the
domain's lane is too full to take it, the pid asks the service to stop the
domain, whose init would wait in vain. The service sends it only
after the report, which named the agent; one that comes before is dropped
and counted.

An installation, {Ref, install, Tag, Name, Facet}, a facet a configured
domain minted for this one, the pid sends its agent as {erx_facets_install,
Tag, Name, Facet}, an ordinary message, which follows the answer, never
suspended either: one the lane cannot take is dropped, and the service's
deadline for the installation fails it. The agent's acknowledgement,
{erx_facets_installed, Tag}, is an answer the pid passes on.

A mint request, {Ref, mint, Mint, Request}, the pid sends Mint, a process of
its own domain, never suspended, so the request's sender is the domain pid,
which the domain already holds; a send from the service would export the
service's own pid to the domain. The mint's reply, {erx_facet_minted, Tag,
Reply}, which the domain sends its own domain pid (erx_facet:minted/2), is
an answer the pid passes on. So the service's pid never leaves the system
domain.
""".

-export([start_link/4]).

%% The lane driver's port_control command that writes a control record (erx_lane_drv.c),
%% and the SEND_SENDER control term's tag.
-define(CONTROL_RECORD, 3).
-define(SEND_SENDER, 22).

%% What the pid knows of its domain: its service, id, node and secret, the agent and the
%% inspection agent its ready report named (none before the report, and none for an
%% inspection agent it refused) and how many messages it dropped.
-type state() :: #{service := pid(), id := pos_integer(), node := node(), ref := reference(),
                   agent := pid() | none, inspect := pid() | none, port := port() | none,
                   dropped := non_neg_integer()}.

-spec start_link(pid(), pos_integer(), node(), reference()) -> pid().
start_link(Service, Id, Node, Ref) ->
    %% Not proc_lib: a domain pid ends with {domain_down, Id, Info} at every
    %% end of its domain, which is no crash to report.
    State = #{service => Service, id => Id, node => Node, ref => Ref, agent => none, inspect => none,
              port => none, dropped => 0},
    spawn_link(fun() -> init(State) end).

init(State) ->
    process_flag(trap_exit, true),
    loop(State).

-spec loop(state()) -> no_return().
loop(#{service := Service, id := Id, ref := Ref} = State) ->
    receive
        {Ref, domain_down, Info} ->
            finish(Info, State);
        {Ref, port, Port} ->
            loop(State#{port := Port});
        {Ref, record, Slot, Record} ->
            write(Slot, Record, State),
            loop(State);
        {Ref, facets, Facets} when is_pid(map_get(agent, State)) ->
            %% Never suspended behind a lane the domain leaves full: a domain that does
            %% not take its answer is stopped, as one whose boot fails.
            case erlang:send(map_get(agent, State), {erx_facets, Facets}, [nosuspend]) of
                ok -> ok;
                nosuspend -> Service ! {stop_request, Ref, Id}
            end,
            loop(State);
        {Ref, install, Tag, Name, Facet} when is_pid(map_get(agent, State)) ->
            _ = erlang:send(map_get(agent, State), {erx_facets_install, Tag, Name, Facet}, [nosuspend]),
            loop(State);
        {Ref, mint, Mint, Request} when is_pid(Mint), node(Mint) =:= map_get(node, State) ->
            %% Never suspended behind the domain's lane: a request that does not go
            %% fails at the service's deadline.
            _ = erlang:send(Mint, Request, [nosuspend]),
            loop(State);
        {Ref, info, From} ->
            #{agent := Agent, inspect := Inspect, dropped := Dropped} = State,
            gen_server:reply(From, {ok, #{connections => Agent, inspect => Inspect, dropped => Dropped}}),
            loop(State);
        {'EXIT', Service, Reason} ->
            %% A trapped exit is a message, which any process here can forge;
            %% only a service that has ended sent a real one.
            case is_process_alive(Service) of
                false -> exit(Reason);
                true -> loop(State)
            end;
        {'EXIT', _From, normal} ->
            loop(State);
        {'EXIT', _From, _Reason} ->
            Service ! {stop_request, Ref, Id},
            loop(State);
        {erx_origin, Id, Msg} ->
            loop(from_domain(Msg, State));
        _Other ->
            loop(dropped(State))
    end.

%% A record into slot Slot of the table, from this pid to the agent the domain's report
%% named; the service sends none before the report. A side that has ended has no table to
%% write into, and the record is dropped: the agent's report of that end has the service
%% stop the domain (system_side_ended), and the domain's end answers the record for it
%% (erx_domain_links:ended/3), so the pid ends with {domain_down, Id, Info} as at every
%% end of its domain. Any other refusal ends the pid.
write(Slot, Record, #{agent := Agent, port := Port}) when is_pid(Agent), is_port(Port) ->
    Ctl = term_to_binary({?SEND_SENDER, self(), Agent}),
    try erlang:port_control(Port, ?CONTROL_RECORD, [<<Slot:32>>, Ctl, term_to_binary(Record)])
    catch
        error:badarg:Stack ->
            case erlang:port_info(Port, id) of
                undefined -> ok;
                _ -> erlang:raise(error, badarg, Stack)
            end
    end.

%% The domain's end, which the service tells the pid only once it has closed the domain's
%% system side, so every frame the side delivered is in the pid's queue by then, though
%% one may sit behind this message, since ERTS orders only the messages of one sender.
%% The pid acts on each still there and then ends: a report the domain made before its
%% end reaches the service before the pid's exit signal does, both being the pid's own.
-spec finish(term(), state()) -> no_return().
finish(Info, #{id := Id} = State) ->
    receive
        {erx_origin, Id, Msg} -> finish(Info, from_domain(Msg, State))
    after 0 ->
        exit({domain_down, Id, Info})
    end.

%% A message of the pid's own domain: its first ready report, which names a pid of the
%% domain's node as its agent, or, after it, an answer by its shape; nothing else. The
%% service sends no record before the report, so an answer before it answers nothing.
from_domain({erx_ready, #{connections := Agent} = Report},
            #{service := Service, id := Id, node := Node, ref := Ref, agent := none} = State)
  when is_pid(Agent), node(Agent) =:= Node ->
    {Inspect, Checked} = inspect_agent(Report, State),
    Service ! {domain_ready, Ref, Id, maps:get(provides, Report, #{}), Inspect},
    Checked#{agent := Agent, inspect := Inspect};
from_domain(_Message, #{agent := none} = State) ->
    dropped(State);
from_domain(Answer, #{service := Service, id := Id, ref := Ref} = State) ->
    case is_answer(Answer) of
        true ->
            Service ! {domain_answer, Ref, Id, Answer},
            State;
        false ->
            dropped(State)
    end.

%% The inspection agent the report names (docs/design-live.md, "The runtime agent"),
%% kept only when the reporting incarnation owns it: its node is the domain's node and
%% its creation the domain's id, the check a provider's mint passes
%% (erx_domain_mints:is_owned/3). A report that names none leaves the domain without
%% one; any other value is refused, logged and counted, and leaves it without one too.
inspect_agent(Report, #{id := Id} = State) ->
    case inspect_verdict(Report, State) of
        {kept, Inspect} ->
            {Inspect, State};
        absent ->
            {none, State};
        refused ->
            logger:notice("erx_domain: domain ~b's ready report named an inspection agent it does not own; refused",
                          [Id]),
            {none, dropped(State)}
    end.

inspect_verdict(Report, #{id := Id, node := Node}) ->
    case maps:find(inspect, Report) of
        {ok, Inspect} when is_pid(Inspect), node(Inspect) =:= Node ->
            case erx_dist:owner(Inspect) =:= Id of
                true -> {kept, Inspect};
                false -> refused
            end;
        {ok, _Other} ->
            refused;
        error ->
            absent
    end.

is_answer({erx_connection_mapped, Peer}) -> is_integer(Peer);
is_answer({erx_connection_unmapped, Peer}) -> is_integer(Peer);
is_answer({erx_connection_lost, Peer, _Reason}) -> is_integer(Peer);
is_answer({erx_facets_installed, Tag}) -> is_integer(Tag);
is_answer({erx_facet_minted, Tag, _Reply}) -> is_integer(Tag);
is_answer(_Message) -> false.

dropped(#{dropped := Dropped} = State) ->
    State#{dropped := Dropped + 1}.
