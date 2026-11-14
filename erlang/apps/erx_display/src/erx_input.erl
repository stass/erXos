%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_input).
-moduledoc """
The input router's functional core (docs/design-display.md, "The input
router"): one pure step that turns a driver's records into the
`erx_wm:input()` events a window reads, and says which window reads
each. `erx_winfs` performs what it answers: it stamps each record with
its clock, monitors each source, delivers to window processes and keeps
one timer.

**What it keeps.** The screen and the pointer, one position for the
display; for each source, the process that sends records, its device's
name and what it holds: each key with the window its down went to and
the runes and modifiers of that down, each button by its evdev code,
each touch slot; the gesture's destination while anything is held; the
locks that are on; and each window's repeating key. The buttons a
pointer event carries and the modifiers that select a layer are derived
from what the sources hold at each step, never stored.

**Who is asked.** The policy's input/4 is asked only about what starts
something: a key's down, a gesture's first event, and a pointer event or
wheel step while nothing is held. What follows goes where the start
went, by the record of the start, not by asking again:

* a key's up goes to the window its down went to, whatever that
  window's state, and stops that window's repeat;
* a key's repeat goes to the window its down went to, and only while it
  is shown;
* every event of a gesture goes to its destination, the window, the
  policy or nowhere, fixed by the policy's answer to its first event; a
  hidden window receives only the events that let a button or touch go;
* the reserved chord is answered `{wm, chord}` before the policy is
  asked, so no window receives its down, repeats or up.

A doubled down, an unmatched up or touch, a code the keymap has no row
for, a malformed record and every record before the first screen are
dropped and counted. `release`, and a source's end (`gone`), send an up
for every key the source holds to its down's window and let go of its
buttons and touches. So a window that saw a down sees its up, and no
window sees an up or a move it saw no down for.
""".

-include("generated/erx_abi.hrl").

%% The design names a driver's record record(), as "Input events" spells it.
-compile({nowarn_redefined_builtin_type, {record, 0}}).

-export([new/1, step/3, dropped/1]).
-export_type([config/0, state/0, record/0, in/0, view/0, out/0]).

-type code() :: 0..?ERX_EVDEV_KEY_MAX.
%% A record's bounds, from abi/formats/input.txt.
-type rel() :: ?ERX_INPUT_REL_MIN..?ERX_INPUT_REL_MAX.
-type axis() :: 0..?ERX_INPUT_AXIS_MAX.
-type slot() :: 0..?ERX_INPUT_TOUCH_SLOT_MAX.
-type rune() :: 0..16#d7ff | 16#e000..16#10ffff.
-doc """
The display's input configuration: the keyboard layout, the time a key
is held before it repeats and the time between repeats, in milliseconds,
and the reserved chord's key codes, or `none`.
""".
-type config() :: #{keymap := erx_keymap:layout(),
                    repeat_delay := pos_integer(),
                    repeat_period := pos_integer(),
                    chord := [code(), ...] | none}.
-doc "One record of a driver, in its device's terms (\"Input events\").".
-type record() :: {pointer, rel, DX :: rel(), DY :: rel()}
                | {pointer, abs, X :: axis(), Y :: axis()}
                | {touch, slot(), down | move | up, X :: axis(), Y :: axis()}
                | {key, down | up, code()}
                | {wheel, Steps :: ?ERX_INPUT_WHEEL_MIN..?ERX_INPUT_WHEEL_MAX}
                | release.
-doc "What erx_winfs hands one step, each stamped with its clock in milliseconds.".
-type in() :: {record, Source :: pid(), Device :: binary(), At :: integer(), record()}
            | {gone, Source :: pid(), At :: integer()}
            | {tick, At :: integer()}
            | {screen, erx_wm:rect()}.
-doc "The window table, the display's session and the policy, as erx_winfs holds them.".
-type view() :: #{windows := [erx_wm:window()], session := erx_wm:session(),
                  policy := module(), policy_state := term()}.
-doc "What erx_winfs performs: a delivery, the policy's word, a new table, the timer.".
-type out() :: {to, erx_wm:window_id(), erx_wm:input()} | {wm, term()}
             | {windows, [erx_wm:window()]} | {wake, At :: integer() | none}.

%% A key a source holds: the window its down went to, or none, and what its down typed,
%% the unshifted rune, the modifier row it holds and the modifiers then held, which its
%% repeats and up carry.
-type held_key() :: #{dest := erx_wm:window_id() | none,
                      typed := rune() | none,
                      unshifted := rune() | none,
                      modifier := {rune() | none, shift | ctl | alt | altgr} | none,
                      mods := [rune()]}.
-record(source, {device :: binary(),
                 keys = #{} :: #{code() => held_key()},
                 buttons = #{} :: #{code() => 1..255},
                 touches = [] :: ordsets:ordset(slot())}).
%% A gesture's destination, fixed by the policy's answer to its first event. A window's
%% names the buttons of the last pointer event it received, so that once hidden it hears
%% only those go up.
-type destination() :: {window, erx_wm:window_id(), Seen :: 0..255} | policy | nowhere.
-record(input, {config :: config(),
                screen = none :: erx_wm:rect() | none,
                pointer = none :: {erx_wm:coord(), erx_wm:coord()} | none,
                sources = #{} :: #{pid() => #source{}},
                gesture = none :: destination() | none,
                locks = [] :: ordsets:ordset(caps),
                %% Each window's repeating key: its source, its code and when it next
                %% repeats.
                repeats = #{} :: #{erx_wm:window_id() => {pid(), code(), integer()}},
                wake = none :: integer() | none,
                dropped = 0 :: non_neg_integer()}).
-opaque state() :: #input{}.

%% One step's view, the policy's state as the step leaves it, its answers, newest first,
%% and the policy's answers it dropped.
-record(step, {view :: view(), policy_state :: term(), outs = [] :: [out()],
               drops = 0 :: non_neg_integer()}).

%% How a pointer event relates to the gesture: it presses, it lets a button or touch go,
%% or it only moves.
-type edge() :: press | letgo | move.

-doc "The router's state from a display's configuration: no screen, no source.".
-spec new(config()) -> state().
new(#{keymap := Layout, repeat_delay := Delay, repeat_period := Period, chord := Chord} = Config)
  when is_integer(Delay), Delay > 0, is_integer(Period), Period > 0 ->
    true = lists:member(Layout, erx_keymap:layouts()),
    true = Chord =:= none orelse (Chord =/= [] andalso lists:all(fun is_code/1, Chord)),
    #input{config = Config#{chord := case Chord of none -> none; _ -> ordsets:from_list(Chord) end}}.

-doc """
Steps one input: returns what erx_winfs is to perform, in order, the
policy's state after any question the step asked it, and the next state.
""".
-spec step(in(), view(), state()) -> {[out()], term(), state()}.
step(In, #{policy_state := PolicyState} = View, State) ->
    {Step, Taken} = take(In, #step{view = View, policy_state = PolicyState}, State),
    {#step{outs = Outs, policy_state = PolicyState1, drops = Drops}, Next} = wake(Step, Taken),
    {lists:reverse(Outs), PolicyState1, Next#input{dropped = Next#input.dropped + Drops}}.

-doc "How many records and answers the router has dropped.".
-spec dropped(state()) -> non_neg_integer().
dropped(#input{dropped = Dropped}) -> Dropped.

%% Inputs ---------------------------------------------------------------------

take({screen, {X0, Y0, X1, Y1} = Rect}, Step, S) when X0 < X1, Y0 < Y1 ->
    {Step, S#input{screen = Rect, pointer = place(Rect, S#input.pointer)}};
take({tick, At}, Step, S) when is_integer(At) ->
    tick(At, Step, S);
take({gone, Source, At}, Step, S) when is_pid(Source), is_integer(At) ->
    {Released, R} = release(Source, At, Step, S),
    {Released, R#input{sources = maps:remove(Source, R#input.sources)}};
take({record, Source, Device, At, Record}, Step, #input{screen = Screen} = S)
  when Screen =/= none, is_pid(Source), is_binary(Device), is_integer(At) ->
    case is_record_ok(Record) of
        true -> record(Record, Source, At, Step, enrol(Source, Device, S));
        false -> {Step, count(S)}
    end;
take(_In, Step, S) ->
    {Step, count(S)}.

%% A source enrols at its first record; its device is the one that record names.
enrol(Source, Device, #input{sources = Sources} = S) ->
    case Sources of
        #{Source := _} -> S;
        #{} -> S#input{sources = Sources#{Source => #source{device = Device}}}
    end.

record({pointer, rel, DX, DY}, Source, At, Step,
       #input{screen = {X0, Y0, X1, Y1}, pointer = {X, Y}} = S) ->
    Moved = S#input{pointer = {clamp(X + DX, X0, X1 - 1), clamp(Y + DY, Y0, Y1 - 1)}},
    pointer(Source, At, move, Step, Moved);
record({pointer, abs, X, Y}, Source, At, Step, S) ->
    pointer(Source, At, move, Step, S#input{pointer = scale(X, Y, S#input.screen)});
record({touch, Slot, Phase, X, Y}, Source, At, Step, S) ->
    touch(Slot, Phase, Source, At, Step, S#input{pointer = scale(X, Y, S#input.screen)});
record({wheel, Steps}, Source, At, Step, #input{gesture = Gesture} = S) ->
    Event = event(Source, At, {wheel, Steps}, S),
    case Gesture of
        none ->
            {Route, Asked} = ask(Event, Step),
            {answer(Route, Asked), S};
        _ ->
            {Delivered, _Same} = deliver(Gesture, Event, move, Step),
            {Delivered, S}
    end;
record(release, Source, At, Step, S) ->
    release(Source, At, Step, S);
record({key, Edge, Code}, Source, At, Step, #input{config = #{keymap := Layout}} = S) ->
    case erx_keymap:row(Layout, Code) of
        none -> {Step, count(S)};
        {button, Bit} -> button(Edge, Code, Bit, Source, At, Step, S);
        Row -> key(Edge, Code, Row, Source, At, Step, S)
    end.

%% Pointer --------------------------------------------------------------------

button(Edge, Code, Bit, Source, At, Step, S) ->
    #source{buttons = Buttons} = Src = source(Source, S),
    case {Edge, maps:is_key(Code, Buttons)} of
        {down, false} ->
            Pressed = put_source(Source, Src#source{buttons = Buttons#{Code => Bit}}, S),
            pointer(Source, At, press, Step, Pressed);
        {up, true} ->
            Let = put_source(Source, Src#source{buttons = maps:remove(Code, Buttons)}, S),
            pointer(Source, At, letgo, Step, Let);
        _Doubled ->
            {Step, count(S)}
    end.

touch(Slot, Phase, Source, At, Step, S) ->
    #source{touches = Touches} = Src = source(Source, S),
    case {Phase, ordsets:is_element(Slot, Touches)} of
        {down, false} ->
            Down = put_source(Source, Src#source{touches = ordsets:add_element(Slot, Touches)}, S),
            pointer(Source, At, press, Step, Down);
        {move, true} ->
            pointer(Source, At, move, Step, S);
        {up, true} ->
            Up = put_source(Source, Src#source{touches = ordsets:del_element(Slot, Touches)}, S),
            pointer(Source, At, letgo, Step, Up);
        _Unmatched ->
            {Step, count(S)}
    end.

%% One pointer event at the pointer with the buttons held after the record. A gesture
%% runs exactly while some source holds a button or touch, which is while the buttons
%% are not 0, so the gesture before the record and the buttons after it say which of
%% four things the event is.
pointer(Source, At, Edge, Step, #input{pointer = {X, Y}, gesture = Gesture} = S) ->
    Buttons = buttons(S),
    Event = event(Source, At, {pointer, X, Y, Buttons}, S),
    case {Gesture, Buttons} of
        {none, 0} ->
            %% Between gestures the policy routes it.
            {Route, Asked} = ask(Event, Step),
            {answer(Route, Asked), S};
        {none, _} ->
            %% A press begins a gesture, whose destination the policy's answer fixes.
            {Route, Asked} = ask(Event, Step),
            {answer(Route, Asked), S#input{gesture = destination(Route)}};
        {_, 0} ->
            %% The gesture ends with the event after which nothing is held.
            {Delivered, _Ended} = deliver(Gesture, Event, Edge, Step),
            {Delivered, S#input{gesture = none}};
        {_, _} ->
            %% The gesture goes on, to its destination.
            {Delivered, Destination} = deliver(Gesture, Event, Edge, Step),
            {Delivered, S#input{gesture = Destination}}
    end.

destination({to, Window, #{event := {pointer, _, _, Buttons}}}) -> {window, Window, Buttons};
destination({to, Window, _NotPointer}) -> {window, Window, 0};
destination({wm, _}) -> policy;
destination(_WindowsOrDrop) -> nowhere.

%% An event of a gesture after its first, and the gesture's destination after it. A
%% window receives it while shown. While hidden it receives only an event that lets go a
%% button it saw pressed, carrying only the buttons it saw that are still held, so a
%% hidden window never hears of a button pressed after it was hidden. The policy is
%% asked, and an answer naming a window is dropped and counted, since that window did
%% not see the gesture start.
-spec deliver(destination(), erx_wm:input(), edge(), #step{}) -> {#step{}, destination()}.
deliver({window, Window, Seen} = Dest, #{event := Ev} = Event, Edge,
        #step{view = #{windows := Windows}} = Step) ->
    case {erx_wm:fetch(Window, Windows), Edge, Ev} of
        {{ok, #{state := shown}}, _, {pointer, _, _, Buttons}} ->
            {out({to, Window, Event}, Step), {window, Window, Buttons}};
        {{ok, #{state := shown}}, _, _Wheel} ->
            {out({to, Window, Event}, Step), Dest};
        {{ok, #{state := hidden}}, letgo, {pointer, X, Y, Buttons}}
          when Buttons band Seen =/= Seen ->
            Kept = Buttons band Seen,
            {out({to, Window, Event#{event := {pointer, X, Y, Kept}}}, Step), {window, Window, Kept}};
        _HiddenOrEnded ->
            {Step, Dest}
    end;
deliver(policy, Event, _Edge, Step) ->
    case ask(Event, Step) of
        {{to, _, _}, #step{drops = Drops} = Asked} -> {Asked#step{drops = Drops + 1}, policy};
        {Route, Asked} -> {answer(Route, Asked), policy}
    end;
deliver(nowhere, _Event, _Edge, Step) ->
    {Step, nowhere}.

%% Keys -----------------------------------------------------------------------

key(down, Code, Row, Source, At, Step, S) ->
    #source{keys = Keys} = Src = source(Source, S),
    case maps:is_key(Code, Keys) of
        true -> {Step, count(S)};
        false -> key_down(Code, Row, Src, Source, At, Step, S)
    end;
key(up, Code, _Row, Source, At, Step, S) ->
    #source{keys = Keys} = Src = source(Source, S),
    case Keys of
        #{Code := Held} ->
            Up = put_source(Source, Src#source{keys = maps:remove(Code, Keys)}, S),
            key_up(Code, Held, Source, At, Step, Up);
        #{} ->
            {Step, count(S)}
    end.

%% A key's down types at the layer the modifiers held and the locks select; a lock's down
%% toggles its lock. The chord is decided before the policy is asked. Where the down went
%% is recorded, and a down that went to a window and types a rune becomes that window's
%% repeating key.
key_down(Code, Row, #source{keys = Keys} = Src, Source, At, Step, S) ->
    {Typed, Unshifted, Modifier} = runes(Row, modifiers(S), S#input.locks),
    Mods = lists:usort([Rune || {Rune, _} <- [Modifier], Rune =/= none] ++ mods(S)),
    Event = event(Source, At, {key, down, Code, Typed, Unshifted, Mods}, S),
    {Route, Asked} = case chord(Code, S) of
                         true -> {{wm, chord}, Step};
                         false -> ask(Event, Step)
                     end,
    Dest = case Route of {to, Window, _} -> Window; _ -> none end,
    Held = #{dest => Dest, typed => Typed, unshifted => Unshifted, modifier => Modifier,
             mods => Mods},
    Pressed = put_source(Source, Src#source{keys = Keys#{Code => Held}},
                         S#input{locks = toggle(Row, S#input.locks)}),
    {answer(Route, Asked), repeat_from(Dest, Typed, Source, Code, At, Pressed)}.

%% A key's up goes to its down's window, whatever that window's state, and stops that
%% window's repeat; a down that went nowhere has no up to send.
key_up(_Code, #{dest := none}, _Source, _At, Step, S) ->
    {Step, S};
key_up(Code, #{dest := Window, typed := Typed, unshifted := Unshifted}, Source, At, Step, S) ->
    Event = event(Source, At, {key, up, Code, Typed, Unshifted, mods(S)}, S),
    {out({to, Window, Event}, Step), S#input{repeats = maps:remove(Window, S#input.repeats)}}.

repeat_from(Window, Typed, Source, Code, At, #input{config = #{repeat_delay := Delay}} = S)
  when Window =/= none, Typed =/= none ->
    S#input{repeats = (S#input.repeats)#{Window => {Source, Code, At + Delay}}};
repeat_from(_Window, _Typed, _Source, _Code, _At, S) ->
    S.

%% Whether a key's down completes the reserved chord: it is one of the chord's keys, and
%% with it every chord key is held, over every source.
chord(Code, #input{config = #{chord := Chord}} = S) ->
    Chord =/= none andalso ordsets:is_element(Code, Chord)
        andalso ordsets:is_subset(Chord, ordsets:from_list([Code | held_codes(S)])).

%% The runes a key's row gives at the layer selected, and the modifier it holds. A
%% modifier and a lock type nothing and name their rune in the k set alone.
runes({key, Layers, Caps}, Modifiers, Locks) ->
    {rune(maps:get(layer(Modifiers, Caps, Locks), Layers)), rune(maps:get(none, Layers)), none};
runes({modifier, Rune, Modifier}, _Modifiers, _Locks) ->
    {none, rune(Rune), {rune(Rune), Modifier}};
runes({lock, Rune, _Lock}, _Modifiers, _Locks) ->
    {none, rune(Rune), none}.

%% The layer of 9front's map the modifiers held select; Caps Lock shifts a caps key, and
%% Shift with Caps Lock unshifts it.
layer(Modifiers, Caps, Locks) ->
    Shift = lists:member(shift, Modifiers),
    Shifted = case Caps of
                  true -> Shift xor ordsets:is_element(caps, Locks);
                  false -> Shift
              end,
    AltGr = lists:member(altgr, Modifiers),
    Ctl = lists:member(ctl, Modifiers),
    if
        AltGr, Shift -> shiftaltgr;
        AltGr -> altgr;
        Ctl -> ctl;
        Shifted -> shift;
        true -> none
    end.

toggle({lock, _Rune, Lock}, Locks) ->
    case ordsets:is_element(Lock, Locks) of
        true -> ordsets:del_element(Lock, Locks);
        false -> ordsets:add_element(Lock, Locks)
    end;
toggle(_Row, Locks) ->
    Locks.

rune(0) -> none;
rune(Rune) -> Rune.

%% Repeat ---------------------------------------------------------------------

%% Every window whose repeating key is due repeats it, while shown, with the runes and
%% modifiers of its down, and its time moves one period on; a window that has left the
%% table, or whose key its source no longer holds, loses its repeat.
tick(At, Step, #input{repeats = Repeats, config = #{repeat_period := Period}} = S) ->
    #step{view = #{windows := Windows}} = Step,
    Due = lists:sort([{Window, Repeat} || {Window, {_, _, Time} = Repeat} <- maps:to_list(Repeats),
                                          Time =< At]),
    lists:foldl(
      fun({Window, {Source, Code, Time}}, {StepAcc, SAcc = #input{repeats = R}}) ->
              case {erx_wm:fetch(Window, Windows), down(Source, Code, SAcc)} of
                  {error, _} ->
                      {StepAcc, SAcc#input{repeats = maps:remove(Window, R)}};
                  {_, none} ->
                      {StepAcc, SAcc#input{repeats = maps:remove(Window, R)}};
                  {{ok, #{state := WindowState}}, Down} ->
                      Next = SAcc#input{repeats = R#{Window := {Source, Code, Time + Period}}},
                      {repeat(WindowState, Window, Source, Code, Down, At, StepAcc, SAcc), Next}
              end
      end, {Step, S}, Due).

repeat(shown, Window, Source, Code, #{typed := Typed, unshifted := Unshifted, mods := Mods}, At,
       Step, S) ->
    out({to, Window, event(Source, At, {key, repeat, Code, Typed, Unshifted, Mods}, S)}, Step);
repeat(hidden, _Window, _Source, _Code, _Down, _At, Step, _S) ->
    Step.

%% The held key a source's down of Code left, or none.
down(Source, Code, #input{sources = Sources}) ->
    case Sources of
        #{Source := #source{keys = #{Code := Held}}} -> Held;
        #{} -> none
    end.

%% The timer follows the earliest repeat; erx_winfs is told only when that changes.
wake(Step, #input{repeats = Repeats, wake = Last} = S) ->
    Earliest = case [Time || {_, _, Time} <- maps:values(Repeats)] of
                   [] -> none;
                   Times -> lists:min(Times)
               end,
    case Earliest of
        Last -> {Step, S};
        _Changed -> {out({wake, Earliest}, Step), S#input{wake = Earliest}}
    end.

%% Release --------------------------------------------------------------------

%% A source's release, or its end: an up for every key it holds, in code order, to its
%% down's window, then its buttons and touches let go with one pointer event to the
%% gesture's destination when the buttons held changed.
release(Source, At, Step, #input{sources = Sources} = S) ->
    case Sources of
        #{Source := #source{keys = Keys}} ->
            {KeysUp, Up} = lists:foldl(
                             fun(Code, {StepAcc, SAcc}) ->
                                     #source{keys = K} = Src = source(Source, SAcc),
                                     Without = put_source(Source,
                                                          Src#source{keys = maps:remove(Code, K)}, SAcc),
                                     key_up(Code, maps:get(Code, K), Source, At, StepAcc, Without)
                             end, {Step, S}, lists:sort(maps:keys(Keys))),
            let_go(Source, At, KeysUp, Up);
        #{} ->
            {Step, S}
    end.

let_go(Source, At, Step, S) ->
    Src = source(Source, S),
    Let = put_source(Source, Src#source{buttons = #{}, touches = []}, S),
    case buttons(Let) =:= buttons(S) of
        true -> {Step, Let};
        false -> pointer(Source, At, letgo, Step, Let)
    end.

%% Derived state --------------------------------------------------------------

%% Plan 9's buttons: the union of every source's, with button 1 while any touch is held.
buttons(#input{sources = Sources}) ->
    lists:foldl(fun(#source{buttons = B, touches = T}, Acc) ->
                        Touch = case T of [] -> 0; _ -> 1 end,
                        lists:foldl(fun(Bit, A) -> A bor Bit end, Acc bor Touch, maps:values(B))
                end, 0, maps:values(Sources)).

%% Every key held, over every source, and their codes.
held_keys(#input{sources = Sources}) ->
    [Held || #source{keys = Keys} <- maps:values(Sources), Held <- maps:values(Keys)].

held_codes(#input{sources = Sources}) ->
    [Code || #source{keys = Keys} <- maps:values(Sources), Code <- maps:keys(Keys)].

%% The modifiers held on the display, for the layer, and their runes, for an event.
modifiers(S) -> [Modifier || #{modifier := {_, Modifier}} <- held_keys(S)].
mods(S) -> lists:usort([Rune || #{modifier := {Rune, _}} <- held_keys(S), Rune =/= none]).

%% Helpers --------------------------------------------------------------------

ask(Event, #step{view = #{windows := Windows, session := Session, policy := Policy},
                 policy_state = PolicyState} = Step) ->
    {Route, PolicyState1} = Policy:input(Event, Windows, Session, PolicyState),
    {Route, Step#step{policy_state = PolicyState1}}.

%% The policy's answer as what erx_winfs performs.
answer({to, Window, Event}, Step) -> out({to, Window, Event}, Step);
answer({wm, Term}, Step) -> out({wm, Term}, Step);
answer({windows, Table}, Step) -> out({windows, Table}, Step);
answer(drop, Step) -> Step.

out(Out, #step{outs = Outs} = Step) -> Step#step{outs = [Out | Outs]}.

event(Source, At, Event, #input{sources = Sources}) ->
    #{Source := #source{device = Device}} = Sources,
    #{device => Device, at => At, event => Event}.

source(Source, #input{sources = Sources}) -> maps:get(Source, Sources).

put_source(Source, Src, #input{sources = Sources} = S) -> S#input{sources = Sources#{Source := Src}}.

count(#input{dropped = Dropped} = S) -> S#input{dropped = Dropped + 1}.

%% The pointer's first place is the screen's centre; a new screen clamps it inside.
place({X0, Y0, X1, Y1}, none) -> {(X0 + X1) div 2, (Y0 + Y1) div 2};
place({X0, Y0, X1, Y1}, {X, Y}) -> {clamp(X, X0, X1 - 1), clamp(Y, Y0, Y1 - 1)}.

%% A normalized position, 0..?ERX_INPUT_AXIS_MAX on each axis, lies inside the screen.
scale(X, Y, {X0, Y0, X1, Y1}) ->
    {X0 + X * (X1 - X0 - 1) div ?ERX_INPUT_AXIS_MAX, Y0 + Y * (Y1 - Y0 - 1) div ?ERX_INPUT_AXIS_MAX}.

clamp(V, Low, High) -> max(Low, min(High, V)).

is_code(Code) -> is_integer(Code) andalso Code >= 0 andalso Code =< ?ERX_EVDEV_KEY_MAX.

%% A record within record()'s bounds; anything else is dropped.
is_record_ok({pointer, rel, DX, DY}) -> is_rel(DX) andalso is_rel(DY);
is_record_ok({pointer, abs, X, Y}) -> is_axis(X) andalso is_axis(Y);
is_record_ok({touch, Slot, Phase, X, Y}) ->
    is_integer(Slot) andalso Slot >= 0 andalso Slot =< ?ERX_INPUT_TOUCH_SLOT_MAX
        andalso lists:member(Phase, [down, move, up]) andalso is_axis(X) andalso is_axis(Y);
is_record_ok({key, Edge, Code}) -> (Edge =:= down orelse Edge =:= up) andalso is_code(Code);
is_record_ok({wheel, Steps}) -> is_integer(Steps) andalso Steps >= ?ERX_INPUT_WHEEL_MIN andalso Steps =< ?ERX_INPUT_WHEEL_MAX;
is_record_ok(release) -> true;
is_record_ok(_Record) -> false.

is_rel(V) -> is_integer(V) andalso V >= ?ERX_INPUT_REL_MIN andalso V =< ?ERX_INPUT_REL_MAX.
is_axis(V) -> is_integer(V) andalso V >= 0 andalso V =< ?ERX_INPUT_AXIS_MAX.
