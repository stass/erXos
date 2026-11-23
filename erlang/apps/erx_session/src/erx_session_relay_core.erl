%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_relay_core).
-moduledoc """
The terminal relay's decisions (docs/design-shell.md, "The terminal relay's
protocol") as a pure state machine. erx_session_relay, the gen_server
registered as the relay's name, hands every request and message to
request/3 or event/2, each of which returns `{Core, Actions}`, and carries
out the actions in order. A request's first action is its answer,
`{answer, Answer}`: so the answer goes before anything the request sets
off, the design's ordering rule.

The core holds the line discipline (erx_tty) and the tty's side of the
master's messages (erx_tty_link) beside the relay's own state, and derives
the room erx_tty's echo takes from what erx_tty_link holds, so no caller
counts echo or held bytes.

Its construction is the design's: the terminal has one holder at a time,
`console` or one job, given by the shell's `foreground`; an open may read
while its holder holds the terminal and, for a job, the shell has acted on
every signal counted for the group that gave it the terminal (Seen equals
Sent); and a read takes bytes only with the signal number of the moment.
Every step ends in settle/1, the one place a step ends: there every
`read` and `in` wait is armed in erx_tty exactly when its open may read
and parked otherwise, so no rule lists the steps that must park or arm,
and what the step left held goes to the master once, so nothing a flush
in the step drops reaches it first, as FreeBSD wakes the device once a
step (ttydisc_rint_done, sys/kern/tty_ttydisc.c:1293-1305).

Opens and waits are named by the edge: an open by the term the `open`
request carries (the server's pid and a reference it makes), a wait by `{Open, Kind}`,
Kind being `read`, `in` or `out`, the names erx_tty's waiters and timers
carry. Processes, groups and the console are terms the core only compares
and names in actions.
""".

-export([new/2, request/3, event/2]).
-export([holder/1, numbers/2, termios/1, signal_number/1]).
-export_type([core/0, request/0, event/0, answer/0, action/0]).

%% Reads, writes and a read's count carry at most this many bytes.
-define(MAX_BYTES, 4096).

-type open() :: term().
-type kind() :: read | in | out.
-type spec() :: {read, 1..?MAX_BYTES} | in | out.
-type signals() :: {Group :: term(), Seen :: non_neg_integer()}.
-type done() :: {To :: term(), Message :: term()}.

-type request() :: {open, Holder :: term(), read | write, open()}
                 | {close, open()}
                 | {tty, open(), tcgetattr | winsize}
                 | {tty, open(), {tcsetattr, erx_tty:termios()}}
                 | {tty, open(), {tcsetattr, erx_tty:termios(), sigttou_ignored}}
                 | {watch, open(), [spec()]}
                 | {tty_read, open(), 0..?MAX_BYTES, integer()}
                 | {write, open(), binary()}
                 | {console_group, term()}
                 | {status, binary()}
                 | {foreground, console, signals()}
                 | {foreground, term(), cooked | current | erx_tty:termios(), signals()}.
-type event() :: {master, erx_tty_link:master_message()} % from the master
               | {resend, non_neg_integer()}             % erx_tty_link's resend timer
               | {timer, erx_tty:timer()}                % a read's timer ended
               | {write, done(), binary()}               % a writer's message
               | {drain, done()}                         % a normal halt waits for output
               | {down, term()}.                         % a monitored process ended
-type answer() :: ok | {ok, term()} | {ok, term(), non_neg_integer()} | eof | eagain
                | {background, false} | {error, einval | ebadf}.
-type action() :: {send, To :: term(), Message :: term()}
                | {monitor, term()}
                | {output, non_neg_integer(), binary()}  % {tty_output, N, Bytes} to the master
                | open                                   % {tty_open, Tty} to the master
                | {resend_after, non_neg_integer()}      % event {resend, N} in a second
                | {timer_start, erx_tty:timer(), pos_integer()}
                | {timer_cancel, erx_tty:timer()}
                | give_up_name.                          % unregister erx_tty_owner

-type holder() :: console | {job, Tag :: term(), Shell :: term(), Group :: term()}.

-record(open, {holder :: term(), mode :: read | write, maker :: term()}).
-record(wait, {caller :: term(), spec :: spec(), armed :: boolean()}).

-record(core, {
    tty :: erx_tty:tty(),
    link :: erx_tty_link:link(),
    %% The console process, which the console's events and size go to.
    console :: term(),
    %% The group the console last named, which its events carry.
    console_group = none :: term(),
    holder = console :: holder(),
    %% The session's cooked termios, the setting commands run under.
    cooked :: erx_tty:termios(),
    opens = #{} :: #{open() => #open{}},
    waits = #{} :: #{{open(), kind()} => #wait{}},
    %% The relay's signal number: the {signal, _} actions made so far.
    signal = 0 :: non_neg_integer(),
    %% Each group met and not ended: {Sent, Seen}.
    groups = #{} :: #{term() => {non_neg_integer(), non_neg_integer()}},
    %% The writers' messages not yet all through output/3, oldest first.
    writes = queue:new() :: queue:queue({done(), binary()}),
    drains = [] :: [done()]
}).

-opaque core() :: #core{}.

-doc """
A relay whose console is Console: the console holds the terminal from the
start, in the editing setting made from the tty's defaults. With `master`
`none` the relay has no master, as a session's console tty may have none
(erx_session_tty:start_link/0): erx_tty_link sends nothing for one and drops a master
message, and a drain is answered at once. `size`, {Rows, Columns}, is the
tty's window size from the start, as a master's first report would make it;
without it the tty has erx_tty's default.
""".
-spec new(term(), #{master := none | present, size => erx_console:size()}) -> core().
new(Console, #{master := Master} = Options) ->
    Tty = case Options of
              #{size := {Rows, Columns}} ->
                  {ok, _NothingToWake, Sized} = erx_tty:size(Rows, Columns, erx_tty:new()),
                  Sized;
              #{} -> erx_tty:new()
          end,
    Cooked = erx_tty:termios(Tty),
    {ok, _, Editing} = erx_tty:set(erx_tty_modes:editing(Cooked), Tty),
    #core{tty = Editing, link = erx_tty_link:new(Master), console = Console,
          cooked = Cooked}.

-doc "Caller's request: the next core and what to do, first `{answer, Answer}`.".
-spec request(term(), term(), core()) -> {core(), [{answer, answer()} | action()]}.
request(Caller, Request, Core0) ->
    {Answer, Actions, Core1} = handle(Caller, Request, Core0),
    {Settled, Core2} = settle(Core1),
    {Core2, [{answer, Answer} | Actions ++ Settled]}.

-doc "A message that is not a request: the next core and what to do.".
-spec event(event(), core()) -> {core(), [action()]}.
event(Event, Core0) ->
    {Actions, Core1} = on_event(Event, Core0),
    {Settled, Core2} = settle(Core1),
    {Core2, Actions ++ Settled}.

-doc "Who holds the terminal: `console` or `{job, Tag}`.".
-spec holder(core()) -> console | {job, term()}.
holder(#core{holder = console}) -> console;
holder(#core{holder = {job, Tag, _, _}}) -> {job, Tag}.

-doc "A group's `{Sent, Seen}`, or `none` for a group not met or ended.".
-spec numbers(term(), core()) -> {non_neg_integer(), non_neg_integer()} | none.
numbers(Group, #core{groups = Groups}) -> maps:get(Group, Groups, none).

-doc "The tty's termios.".
-spec termios(core()) -> erx_tty:termios().
termios(#core{tty = Tty}) -> erx_tty:termios(Tty).

-doc "The relay's signal number.".
-spec signal_number(core()) -> non_neg_integer().
signal_number(#core{signal = N}) -> N.

%%% Requests

handle(Caller, {open, Holder, Mode, Open}, #core{opens = Opens} = Core)
  when (Mode =:= read orelse Mode =:= write), not is_map_key(Open, Opens) ->
    Made = #open{holder = Holder, mode = Mode, maker = Caller},
    {{ok, Open}, [{monitor, Caller}], Core#core{opens = Opens#{Open => Made}}};
handle(_Caller, {console_group, Group}, Core) when Group =/= none ->
    {Met, Core1} = meet(Group, Core),
    {ok, Met, Core1#core{console_group = Group}};
handle(_Caller, {status, Line}, #core{tty = Tty, link = Link} = Core) when is_binary(Line) ->
    {Free, _Kept, _Stopped} = erx_tty_link:room(Link),
    {Bytes, Tty1} = erx_tty:status(Line, Free, Tty),
    {Actions, Core1} = to_master(Bytes, Core#core{tty = Tty1}),
    {ok, Actions, Core1};
handle(Caller, {foreground, console, Signals}, Core) ->
    foreground(Caller, console, Signals, Core);
handle(Caller, {foreground, Tag, Mode, Signals}, Core) when Tag =/= console ->
    foreground(Caller, {Tag, Mode}, Signals, Core);
handle(Caller, Request, #core{opens = Opens} = Core) ->
    case named(Request) of
        {ok, Open} when is_map_key(Open, Opens) ->
            on_open(Caller, Request, maps:get(Open, Opens), Core);
        {ok, _Unknown} ->
            {{error, ebadf}, [], Core};
        error ->
            {{error, einval}, [], Core}
    end.

%% The open a well-formed request names.
named({close, Open}) -> {ok, Open};
named({tty, Open, tcgetattr}) -> {ok, Open};
named({tty, Open, winsize}) -> {ok, Open};
named({tty, Open, {tcsetattr, _}}) -> {ok, Open};
named({tty, Open, {tcsetattr, _, sigttou_ignored}}) -> {ok, Open};
named({watch, Open, [{read, Count}]})
  when is_integer(Count), Count >= 1, Count =< ?MAX_BYTES -> {ok, Open};
named({watch, Open, [Kind]}) when Kind =:= in; Kind =:= out -> {ok, Open};
named({tty_read, Open, Max, N})
  when is_integer(Max), Max >= 0, Max =< ?MAX_BYTES, is_integer(N) -> {ok, Open};
named({write, Open, Bytes}) when is_binary(Bytes), byte_size(Bytes) =< ?MAX_BYTES -> {ok, Open};
named(_) -> error.

on_open(_Caller, {close, Open}, _Made, Core) ->
    {Cancelled, Core1} = close(Open, Core),
    {ok, Cancelled, Core1};
on_open(_Caller, {tty, _, tcgetattr}, _Made, #core{tty = Tty} = Core) ->
    {{ok, erx_tty:termios(Tty)}, [], Core};
on_open(_Caller, {tty, _, winsize}, _Made, #core{tty = Tty} = Core) ->
    {{ok, erx_tty:winsize(Tty)}, [], Core};
on_open(_Caller, {tty, _, {tcsetattr, Termios}}, Made, Core) ->
    case holds(Made, Core) of
        true -> tcsetattr(Termios, Core);
        false -> {{background, false}, [], Core}
    end;
on_open(_Caller, {tty, _, {tcsetattr, Termios, sigttou_ignored}}, _Made, Core) ->
    tcsetattr(Termios, Core);
on_open(_Caller, {watch, _, [{read, _}]}, #open{mode = write}, Core) ->
    {{error, ebadf}, [], Core};
on_open(Caller, {watch, Open, [Spec]}, _Made, Core) ->
    watch(Caller, Open, Spec, Core);
on_open(_Caller, {tty_read, _, _, _}, #open{mode = write}, Core) ->
    {{error, ebadf}, [], Core};
on_open(_Caller, {tty_read, Open, Max, N}, Made, Core) ->
    tty_read(Open, Max, N, Made, Core);
on_open(_Caller, {write, _, Bytes}, _Made, Core) ->
    write(Bytes, Core).

tcsetattr(Termios, #core{tty = Tty} = Core) ->
    case settable(Termios, Tty) of
        {ok, Actions, Tty1} ->
            {Done, Core1} = carry(Actions, Core#core{tty = Tty1}),
            {ok, Done, Core1};
        {error, einval} ->
            {{error, einval}, [], Core}
    end.

%% erx_tty:set/2, refusing TOSTOP too, which comes with process groups in
%% the second tier: the one check of a termios a request carries.
settable(Termios, Tty) ->
    case erx_tty:set(Termios, Tty) of
        {ok, _Actions, Tty1} = Set ->
            case lists:member(tostop, maps:get(lflag, erx_tty:termios(Tty1))) of
                true -> {error, einval};
                false -> Set
            end;
        {error, einval} ->
            {error, einval}
    end.

%% A watch replaces the open's wait of its kind. settle/1 arms a `read` or
%% `in` wait if its open may read; an `out` wait is never parked, and
%% settle/1 reports it.
watch(Caller, Open, Spec, Core0) ->
    Key = {Open, kind(Spec)},
    {Cancelled, Core1} = unwait(Key, Core0),
    Wait = #wait{caller = Caller, spec = Spec, armed = Spec =:= out},
    {ok, Cancelled, Core1#core{waits = (Core1#core.waits)#{Key => Wait}}}.

kind({read, _}) -> read;
kind(in) -> in;
kind(out) -> out.

%% A read takes bytes only while its open may read and only with the
%% signal number of the moment; a read of 0 bytes is erx_tty's {ok, <<>>}
%% and never waits, so it needs no wait of its own.
tty_read(Open, Max, N, Made, #core{tty = Tty, signal = Signal} = Core) ->
    case may_read(Made, Core) andalso N =:= Signal of
        true ->
            {Answer, Tty1} = erx_tty:read({Open, read}, Max, Tty),
            {Answer, [], Core#core{tty = Tty1}};
        false ->
            {eagain, [], Core}
    end.

%% An open's write takes what room there is now, behind no writer's message.
write(<<>>, Core) ->
    {{ok, 0}, [], Core};
write(Bytes, #core{writes = Writes} = Core) ->
    case queue:is_empty(Writes) of
        false ->
            {eagain, [], Core};
        true ->
            case put_output(Bytes, Core) of
                {0, Actions, Core1} -> {eagain, Actions, Core1};
                {Taken, Actions, Core1} -> {{ok, Taken}, Actions, Core1}
            end
    end.

%% A foreground checks Seen and its target first and changes nothing if
%% either fails; then the new holder takes the terminal in one hand-over.
foreground(Caller, Target, {Group, Seen}, Core)
  when Group =/= none, is_integer(Seen), Seen >= 0 ->
    case Seen =< sent(Group, Core) andalso plan(Target, Caller, Group, Core) of
        {ok, Holder, Termios, Cooked} ->
            Left = erx_tty:termios(Core#core.tty),
            {Met, Core1} = meet(Group, Core),
            {Changed, Core2} = hand_over(Holder, Termios,
                                         seen(Group, Seen, Core1#core{cooked = Cooked})),
            {{ok, Left, sent(Group, Core2)}, Met ++ Changed, Core2};
        _Refused ->
            {{error, einval}, [], Core}
    end;
foreground(_Caller, _Target, _Signals, Core) ->
    {{error, einval}, [], Core}.

%% What a foreground makes: the new holder, its termios (`keep` for none)
%% and the cooked termios after it; `refused` when it cannot be made.
plan(console, _Caller, _Group, #core{cooked = Cooked, tty = Tty}) ->
    Adopted = erx_tty_modes:adopt(Cooked, erx_tty:termios(Tty)),
    {ok, console, erx_tty_modes:editing(Adopted), Adopted};
plan({Tag, cooked}, Caller, Group, #core{cooked = Cooked}) ->
    {ok, {job, Tag, Caller, Group}, Cooked, Cooked};
plan({Tag, current}, Caller, Group, #core{holder = {job, Tag, _, _}, cooked = Cooked}) ->
    {ok, {job, Tag, Caller, Group}, keep, Cooked};
plan({_Tag, current}, _Caller, _Group, _Core) ->
    refused;
plan({Tag, Termios}, Caller, Group, #core{tty = Tty, cooked = Cooked}) ->
    case settable(Termios, Tty) of
        {ok, _, _} -> {ok, {job, Tag, Caller, Group}, Termios, Cooked};
        {error, einval} -> refused
    end.

%% The one change of holder: the waits of opens that may no longer read
%% park before the termios is set, so the old holder's waits are not
%% checked under the new one; settle/1 arms the new holder's.
hand_over(Holder, Termios, Core0) ->
    {Parked, Core1} = park(Core0#core{holder = Holder}),
    {Set, Core2} = set_termios(Termios, Core1),
    {Parked ++ Set, Core2}.

set_termios(keep, Core) ->
    {[], Core};
set_termios(Termios, #core{tty = Tty} = Core) ->
    {ok, Actions, Tty1} = erx_tty:set(Termios, Tty),
    carry(Actions, Core#core{tty = Tty1}).

%% The console takes the terminal back, as {foreground, console, _} gives
%% it, when the group of the job that holds ends.
to_console(Core) ->
    {ok, console, Editing, Cooked} = plan(console, none, none, Core),
    hand_over(console, Editing, Core#core{cooked = Cooked}).

%%% Groups and their numbers

%% A group met for the first time starts at {0, 0} and is monitored.
meet(Group, #core{groups = Groups} = Core) when is_map_key(Group, Groups) ->
    {[], Core};
meet(Group, #core{groups = Groups} = Core) ->
    {[{monitor, Group}], Core#core{groups = Groups#{Group => {0, 0}}}}.

sent(Group, #core{groups = Groups}) ->
    case Groups of
        #{Group := {Sent, _Seen}} -> Sent;
        _ -> 0
    end.

seen(Group, Seen, #core{groups = Groups} = Core) ->
    #{Group := {Sent, _}} = Groups,
    Core#core{groups = Groups#{Group := {Sent, Seen}}}.

%% The group a signal counts for: the holding job's, or the console's
%% named group for an interrupt or suspend, which the console passes on.
counted_for(_Signal, #core{holder = {job, _, _, Group}}) -> Group;
counted_for(sigquit, #core{holder = console}) -> none;
counted_for(_Signal, #core{holder = console, console_group = Group}) -> Group.

count(Signal, #core{groups = Groups} = Core) ->
    Group = counted_for(Signal, Core),
    case Groups of
        #{Group := {Sent, Seen}} -> Core#core{groups = Groups#{Group := {Sent + 1, Seen}}};
        _ -> Core
    end.

%%% Who may read

holds(#open{holder = console}, #core{holder = console}) -> true;
holds(#open{holder = Tag}, #core{holder = {job, Tag, _, _}}) -> true;
holds(#open{}, #core{}) -> false.

may_read(Made, Core) ->
    holds(Made, Core) andalso caught_up(Core).

caught_up(#core{holder = console}) ->
    true;
caught_up(#core{holder = {job, _, _, Group}, groups = Groups}) ->
    case Groups of
        #{Group := {Same, Same}} -> true;
        _ -> false
    end.

may_wait({Open, _Kind}, #core{opens = Opens} = Core) ->
    may_read(maps:get(Open, Opens), Core).

%% Every `read` and `in` wait armed exactly when its open may read. A step
%% parks earlier where the order within it matters: a signal parks before
%% the next key's report, and a change of holder before the new termios.
reconcile(Core0) ->
    {Parked, Core1} = park(Core0),
    {Armed, Core2} = arm(Core1),
    {Parked ++ Armed, Core2}.

park(#core{waits = Waits} = Core) ->
    Losing = [{Open, Kind} || {Open, Kind} := #wait{armed = true} <- Waits,
                              Kind =/= out, not may_wait({Open, Kind}, Core)],
    lists:foldl(fun(Key, {Acc, C}) ->
                        {Cancelled, Tty} = erx_tty:cancel(Key, C#core.tty),
                        Wait = maps:get(Key, C#core.waits),
                        {Acc ++ Cancelled,
                         C#core{tty = Tty,
                                waits = (C#core.waits)#{Key := Wait#wait{armed = false}}}}
                end, {[], Core}, lists:sort(Losing)).

arm(#core{waits = Waits} = Core) ->
    Gaining = [Key || Key := #wait{armed = false} <- Waits, may_wait(Key, Core)],
    lists:foldl(fun(Key, {Acc, C}) ->
                        Wait = #wait{spec = Spec} = maps:get(Key, C#core.waits),
                        Armed = C#core{waits = (C#core.waits)#{Key := Wait#wait{armed = true}}},
                        {Actions, Tty} = tty_wait(Key, Spec, Armed#core.tty),
                        {Done, C1} = carry(Actions, Armed#core{tty = Tty}),
                        {Acc ++ Done, C1}
                end, {[], Core}, lists:sort(Gaining)).

tty_wait(Key, {read, Count}, Tty) -> erx_tty:read_wait(Key, Count, Tty);
tty_wait(Key, in, Tty) -> erx_tty:poll_wait(Key, Tty).

unwait(Key, #core{tty = Tty, waits = Waits} = Core) ->
    {Cancelled, Tty1} = erx_tty:cancel(Key, Tty),
    {Cancelled, Core#core{tty = Tty1, waits = maps:remove(Key, Waits)}}.

close(Open, #core{opens = Opens} = Core) ->
    lists:foldl(fun(Kind, {Acc, C}) ->
                        {Cancelled, C1} = unwait({Open, Kind}, C),
                        {Acc ++ Cancelled, C1}
                end, {[], Core#core{opens = maps:remove(Open, Opens)}}, [read, in, out]).

%%% Events

on_event({master, Message}, #core{link = Link} = Core) ->
    {Actions, Link1} = erx_tty_link:master(Message, Link),
    link_actions(Actions, Core#core{link = Link1});
on_event({resend, N}, #core{link = Link} = Core) ->
    {Actions, Link1} = erx_tty_link:timeout(N, Link),
    link_actions(Actions, Core#core{link = Link1});
on_event({timer, Timer}, #core{tty = Tty} = Core) ->
    {Actions, Tty1} = erx_tty:timer(Timer, Tty),
    carry(Actions, Core#core{tty = Tty1});
on_event({write, Done, Bytes}, #core{writes = Writes} = Core) when is_binary(Bytes) ->
    {[], Core#core{writes = queue:in({Done, Bytes}, Writes)}};
on_event({drain, Done}, #core{drains = Drains} = Core) ->
    {[], Core#core{drains = Drains ++ [Done]}};
on_event({down, Process}, Core) ->
    down(Process, Core).

%% A process ended: the opens it made close, and if it is a group its
%% numbers go; the console takes the terminal if a job under it held.
down(Process, #core{opens = Opens} = Core0) ->
    Made = lists:sort([Open || Open := #open{maker = Maker} <- Opens, Maker =:= Process]),
    {Closed, Core1} = lists:foldl(fun(Open, {Acc, C}) ->
                                          {Cancelled, C1} = close(Open, C),
                                          {Acc ++ Cancelled, C1}
                                  end, {[], Core0}, Made),
    {Ended, Core2} = group_ends(Process, Core1),
    {Closed ++ Ended, Core2}.

group_ends(Group, #core{groups = Groups} = Core) when is_map_key(Group, Groups) ->
    Forgotten = Core#core{groups = maps:remove(Group, Groups)},
    case Forgotten#core.holder of
        {job, _, _, Group} -> to_console(Forgotten);
        _ -> {[], Forgotten}
    end;
group_ends(_Process, Core) ->
    {[], Core}.

%% What erx_tty_link decides: messages for the master pass on, the rest
%% reaches the line discipline.
link_actions(Actions, Core) ->
    lists:foldl(fun(Action, {Acc, C}) ->
                        {Done, C1} = link_action(Action, C),
                        {Acc ++ Done, C1}
                end, {[], Core}, Actions).

link_action({output, _, _} = Output, Core) -> {[Output], Core};
link_action(open, Core) -> {[open], Core};
link_action({resend_after, _} = Resend, Core) -> {[Resend], Core};
link_action({done, _Writer}, Core) -> {[], Core};
link_action({input, Bytes}, Core) -> typed(Bytes, Core);
link_action({size, Rows, Columns}, Core) -> resize(Rows, Columns, Core);
%% The hangup is the permanent end of the console's line, told at once whether or
%% not a read waits (erx_tty_link emits hangup at most once), before the waits it readies.
link_action(hangup, #core{tty = Tty, console = Console} = Core) ->
    {Actions, Tty1} = erx_tty:hangup(Tty),
    {Ready, Core1} = carry(Actions, Core#core{tty = Tty1}),
    {[{send, Console, erx_console_eof} | Ready] ++ drop_writes(Core1),
     Core1#core{writes = queue:new()}}.

%% Typed bytes go to input/3 until none is left: it stops after each
%% signal key, and the next call gets the room the link holds after it.
typed(<<>>, Core) ->
    {[], Core};
typed(Bytes, #core{tty = Tty, link = Link} = Core) ->
    {Actions, Rest, _Room, Tty1} = erx_tty:input(Bytes, erx_tty_link:room(Link), Tty),
    {Done, Core1} = carry(Actions, Core#core{tty = Tty1}),
    {More, Core2} = typed(Rest, Core1),
    {Done ++ More, Core2}.

resize(Rows, Columns, #core{tty = Tty, console = Console} = Core) ->
    {ok, Actions, Tty1} = erx_tty:size(Rows, Columns, Tty),
    {Done, Core1} = carry(Actions, Core#core{tty = Tty1}),
    {Done ++ [{send, Console, {erx_console_size, Rows, Columns}}], Core1}.

%% The line discipline's actions, in order.
carry(Actions, Core) ->
    lists:foldl(fun(Action, {Acc, C}) ->
                        {Done, C1} = carry_one(Action, C),
                        {Acc ++ Done, C1}
                end, {[], Core}, Actions).

carry_one({echo, Bytes}, Core) -> to_master(Bytes, Core);
carry_one({signal, Signal}, Core) -> signal(Signal, Core);
carry_one(info, Core) -> {notify(info, Core), Core};
carry_one(winch, Core) -> {notify(winch, Core), Core};
carry_one(flush_output, Core) -> flush(Core);
carry_one(flushed_loss, Core) -> {notify(lost, Core), Core};
carry_one(stop_output, #core{link = Link} = Core) ->
    {[], Core#core{link = erx_tty_link:stop(Link)}};
carry_one(start_output, #core{link = Link} = Core) ->
    {[], Core#core{link = erx_tty_link:start(Link)}};
carry_one({ready, Key}, Core) -> report(Key, Core);
carry_one({timer_start, _, _} = Start, Core) -> {[Start], Core};
carry_one({timer_cancel, _} = Cancel, Core) -> {[Cancel], Core}.

%% A signal key: the signal number moves on, the signal counts for its
%% group, the reads of a job that now lags park, and the holder is told.
signal(Signal, #core{signal = N} = Core0) ->
    Core1 = count(Signal, Core0#core{signal = N + 1}),
    {Parked, Core2} = park(Core1),
    {Parked ++ notify(event_name(Signal), Core2), Core2}.

event_name(sigint) -> interrupt;
event_name(sigtstp) -> suspend;
event_name(sigquit) -> quit.

notify(Event, #core{holder = {job, Tag, Shell, _}}) ->
    [{send, Shell, {erx_tty_event, Tag, Event}}];
notify(Event, #core{holder = console, console = Console, console_group = Group}) ->
    [{send, Console, {erx_tty_event, Group, Event}}].

%% A wait the tty reports is answered only if it is still armed: with
%% NOFLSH a report can follow, in one input/3, the signal that parked it.
report({Open, _} = Key, #core{waits = Waits, signal = N} = Core) ->
    case Waits of
        #{Key := #wait{armed = true, caller = Caller, spec = Spec}} ->
            {[{send, Caller, {ready, Open, [Spec], N}}],
             Core#core{waits = maps:remove(Key, Waits)}};
        _ ->
            {[], Core}
    end.

%%% Output

flush(#core{link = Link} = Core) ->
    {Actions, Link1} = erx_tty_link:flush(Link),
    {Linked, Core1} = link_actions(Actions, Core#core{link = Link1}),
    {Linked ++ drop_writes(Core1), Core1#core{writes = queue:new()}}.

drop_writes(#core{writes = Writes}) ->
    [done(Done) || {Done, _Bytes} <- queue:to_list(Writes)].

done({To, Message}) -> {send, To, Message}.

%% Bytes through output/3 with the room free now, and what it took to the
%% link, which holds it within that room.
put_output(Bytes, #core{tty = Tty, link = Link} = Core) ->
    {Free, _Kept, _Stopped} = erx_tty_link:room(Link),
    {Taken, Out, Tty1} = erx_tty:output(Bytes, Free, Tty),
    {Actions, Core1} = to_master(Out, Core#core{tty = Tty1}),
    {Taken, Actions, Core1}.

to_master(<<>>, Core) ->
    {[], Core};
to_master(Bytes, #core{link = Link} = Core) ->
    {Actions, Link1} = erx_tty_link:write(none, Bytes, Link),
    link_actions(Actions, Core#core{link = Link1}).

%% The end of every step: the waits are reconciled with who may read; the
%% writers' messages take the room there is, in order; `out` waits are
%% reported once no message waits and any byte's rendering fits; drains
%% are answered once nothing waits or nothing would take it; and what is
%% held goes to the master.
settle(Core0) ->
    {Reconciled, Core1} = reconcile(Core0),
    {Pumped, Core2} = pump(Core1),
    {Writable, Core3} = writable(Core2),
    {Drained, Core4} = drained(Core3),
    {Sent, Link} = erx_tty_link:send(Core4#core.link),
    {Reconciled ++ Pumped ++ Writable ++ Drained ++ Sent, Core4#core{link = Link}}.

pump(#core{writes = Writes} = Core) ->
    case queue:out(Writes) of
        {{value, {Done, Bytes}}, Rest} ->
            {Taken, Actions, Core1} = put_output(Bytes, Core),
            case Bytes of
                <<_:Taken/binary>> ->
                    {More, Core2} = pump(Core1#core{writes = Rest}),
                    {Actions ++ [done(Done)] ++ More, Core2};
                <<_:Taken/binary, Left/binary>> ->
                    {Actions, Core1#core{writes = queue:in_r({Done, Left}, Rest)}}
            end;
        {empty, _} ->
            {[], Core}
    end.

%% An out wait is reported once no writer's message waits and the room fits
%% the widest rendering of one byte, so the write it lets go takes at least
%% its first byte. FreeBSD's poll reports at one free byte (ttydev_poll,
%% sys/kern/tty.c:667), where a newline under ONLCR is EAGAIN and a
%% program polling for out would spin until the master took output. The
%% rule keeps no state, so no writer can hold it off while the room is
%% there. Output stopped does not matter, as it does not to FreeBSD's poll.
writable(#core{waits = Waits, writes = Writes, link = Link, signal = N} = Core) ->
    {Free, _Kept, _Stopped} = erx_tty_link:room(Link),
    case queue:is_empty(Writes) andalso Free >= erx_tty:widest_rendering() of
        true ->
            Ready = lists:sort([{Open, Caller} || {Open, out} := #wait{caller = Caller} <- Waits]),
            {[{send, Caller, {ready, Open, [out], N}} || {Open, Caller} <- Ready],
             Core#core{waits = maps:without([{Open, out} || {Open, _} <- Ready], Waits)}};
        false ->
            {[], Core}
    end.

%% A drain waits for the master to take what is held, while what is held
%% flows to a master (erx_tty_link:flowing/1); otherwise nothing would
%% take it.
drained(#core{drains = []} = Core) ->
    {[], Core};
drained(#core{drains = Drains, writes = Writes, link = Link} = Core) ->
    Empty = queue:is_empty(Writes) andalso erx_tty_link:held(Link) =:= 0,
    case Empty orelse not erx_tty_link:flowing(Link) of
        %% The name goes first, so a caller answered drained finds it given up.
        true -> {[give_up_name | [done(Done) || Done <- Drains]], Core#core{drains = []}};
        false -> {[], Core}
    end.
