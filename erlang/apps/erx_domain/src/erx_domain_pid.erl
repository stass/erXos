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
that agent, the one process of the system domain that does, and passes the
report on as {domain_ready, Ref, Id, Agents}, and each answer as
{domain_answer, Ref, Id, Answer}. Every other message, a second report, the
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
stops the domain.
""".

-export([start_link/4]).

%% The lane driver's port_control command that writes a control record (erx_lane_drv.c),
%% and the SEND_SENDER control term's tag.
-define(CONTROL_RECORD, 3).
-define(SEND_SENDER, 22).

%% What the pid knows of its domain: its service, id, node and secret, the agent its
%% ready report named (none before the report) and how many messages it dropped.
-type state() :: #{service := pid(), id := pos_integer(), node := node(), ref := reference(),
                   agent := pid() | none, port := port() | none, dropped := non_neg_integer()}.

-spec start_link(pid(), pos_integer(), node(), reference()) -> pid().
start_link(Service, Id, Node, Ref) ->
    %% Not proc_lib: a domain pid ends with {domain_down, Id, Info} at every
    %% end of its domain, which is no crash to report.
    State = #{service => Service, id => Id, node => Node, ref => Ref, agent => none, port => none, dropped => 0},
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
        {Ref, info, From} ->
            #{agent := Agent, dropped := Dropped} = State,
            gen_server:reply(From, {ok, #{connections => Agent, dropped => Dropped}}),
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
%% named; the service sends none before the report.
write(Slot, Record, #{agent := Agent, port := Port}) when is_pid(Agent), is_port(Port) ->
    Ctl = term_to_binary({?SEND_SENDER, self(), Agent}),
    erlang:port_control(Port, ?CONTROL_RECORD, [<<Slot:32>>, Ctl, term_to_binary(Record)]).

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
from_domain({erx_ready, #{connections := Agent} = Agents},
            #{service := Service, id := Id, node := Node, ref := Ref, agent := none} = State)
  when is_pid(Agent), node(Agent) =:= Node ->
    Service ! {domain_ready, Ref, Id, Agents},
    State#{agent := Agent};
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

is_answer({erx_connection_mapped, Peer}) -> is_integer(Peer);
is_answer({erx_connection_unmapped, Peer}) -> is_integer(Peer);
is_answer({erx_connection_lost, Peer, _Reason}) -> is_integer(Peer);
is_answer(_Message) -> false.

dropped(#{dropped := Dropped} = State) ->
    State#{dropped := Dropped + 1}.
