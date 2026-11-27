%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_report).
-moduledoc """
The report filter (docs/design-log.md, "Reports carry no term"): a primary logger filter
that rewrites every event OTP's own code logs to a report of names, and drops every other
term the event carries.

An event is OTP's when its domain starts with `otp`, as every report of `gen_server`,
`gen_statem`, `gen_event`, `proc_lib`, `supervisor` and `application_controller` does, or
when the emulator logged it (`error_logger => #{emulator => true}`), as its error for a
process that is not a `proc_lib` process is. Its report keeps, each only after its shape is
checked:

- `label`, the report's label, an atom or a pair of atoms;
- `process` and `name`, the process the report is about and its registered name, or the
  logging process when the report names none;
- `class`, `reason` and `stack`: the error's class, the reason's leading atom and the
  stack trace's `{Module, Function, Arity}` frames.

Everything else is dropped: the format string and its arguments, the last message, the
message queue, the dictionary, the state, the rest of the reason, each frame's arguments
and location, the neighbours of a crash report, and every metadata key but `time`, `pid`,
`gl`, `domain` and `mfa`. The domain's own events, outside OTP's domain, pass unchanged.

The filter never raises and never answers `ignore` for OTP's events: logger removes a
filter that raises (logger_backend's handle_filter_failed/4), which would let every later
report through whole, and an `ignore` leaves the event as it was. Each function the
filter calls is total over any term to keep that true.
""".

-export([primary_filters/0, filter/2, reason_name/1, bytes/1, fields/2, status/2]).
-export_type([view/0]).

-type summary() :: #{label => atom() | {atom(), atom()}, process => pid(), name => atom(),
                     class => error | exit | throw, reason => atom(),
                     stack => [{module(), atom(), arity()}]}.

-define(IS_CLASS(C), (C =:= error orelse C =:= exit orelse C =:= throw)).

-doc """
The primary filters this runtime takes at boot, ahead of any its configuration names: the
filter in every domain but the system domain, whose reports are the trusted base's own, and
none there. Logger's configuration at the kernel's start adds them (edit 57 of
docs/design-runtime.md), before any application starts a process, so no domain has to ask.
""".
-spec primary_filters() -> [{erx_report, logger:filter()}].
primary_filters() ->
    case erx_inspector:is_system_runtime() of
        true -> [];
        false -> [{?MODULE, {fun ?MODULE:filter/2, []}}]
    end.

-doc "The filter: an OTP event as its summary, any other event left to the next filter.".
-spec filter(logger:log_event(), []) -> logger:filter_return().
filter(#{level := Level, msg := Msg, meta := Meta}, _Extra) when is_map(Meta) ->
    case from_otp(Meta) of
        true -> #{level => Level, msg => {report, summary(Msg, Meta)}, meta => maps:filter(fun kept/2, Meta)};
        false -> ignore
    end.

from_otp(#{domain := [otp | _]}) -> true;
from_otp(#{error_logger := #{emulator := true}}) -> true;
from_otp(#{}) -> false.

%% The metadata a formatter needs to place the event; none of it is a term a process held.
kept(time, Time) -> is_integer(Time);
kept(pid, Pid) -> is_pid(Pid);
kept(gl, Pid) -> is_pid(Pid);
kept(domain, Domain) -> atoms(Domain);
kept(mfa, {M, F, A}) -> is_atom(M) andalso is_atom(F) andalso is_integer(A);
kept(_Key, _Value) -> false.

atoms([Atom | Atoms]) when is_atom(Atom) -> atoms(Atoms);
atoms(Rest) -> Rest =:= [].

-spec summary(term(), logger:metadata()) -> summary().
summary(Msg, Meta) ->
    Logging = case Meta of
                  #{pid := Pid} when is_pid(Pid) -> #{process => Pid};
                  #{} -> #{}
              end,
    maps:merge(Logging, named(Msg)).

%% A report's facts; a format string and its arguments, or a string, give none.
named({report, Report}) when is_map(Report) -> facts(maps:to_list(Report), #{});
named({report, Report}) -> fact({report, Report}, #{});
named(_Text) -> #{}.

facts([Fact | Facts], Summary) -> facts(Facts, fact(Fact, Summary));
facts(_End, Summary) -> Summary.

%% One key of a report: the map keys of the behaviours' reports, and the pairs of
%% proc_lib's crash report (the first of its two lists, the process's own) and of the
%% supervisor's and the application controller's. Every other key is dropped.
fact({label, Label}, S) when is_atom(Label) -> first(label, Label, S);
fact({label, {A, B} = Label}, S) when is_atom(A), is_atom(B) -> first(label, Label, S);
fact({report, [Own | _Neighbours]}, S) when is_list(Own) -> facts(Own, S);
fact({report, Pairs}, S) -> facts(Pairs, S);
fact({pid, Pid}, S) when is_pid(Pid) -> first(process, Pid, S);
fact({registered_name, Name}, S) when is_atom(Name) -> first(name, Name, S);
fact({name, Name}, S) -> who(Name, S);
fact({supervisor, Name}, S) -> who(Name, S);
fact({error_info, {Class, Reason, Stack}}, S) when ?IS_CLASS(Class) -> exception(Class, Reason, Stack, S);
fact({reason, {Class, Reason, Stack}}, S) when ?IS_CLASS(Class), is_list(Stack) -> exception(Class, Reason, Stack, S);
fact({reason, Reason}, S) -> reason(Reason, S);
fact({exited, Reason}, S) -> reason(Reason, S);
fact(_Other, S) -> S.

%% A process as a behaviour names it: its registered name, {local, Name}, its pid, or a
%% supervisor's {Pid, Module}.
who(Name, S) when is_atom(Name) -> first(name, Name, S);
who({local, Name}, S) when is_atom(Name) -> first(name, Name, S);
who(Pid, S) when is_pid(Pid) -> first(process, Pid, S);
who({Pid, Module}, S) when is_pid(Pid), is_atom(Module) -> first(process, Pid, S);
who(_Other, S) -> S.

exception(Class, Reason, Stack, S) ->
    reason(Reason, first(stack, frames(Stack), first(class, Class, S))).

%% gen_server's reason is {Reason, Stack} when its callback raised, and an exit reason
%% often is too; otherwise the reason alone.
reason({Reason, [{M, F, _, Location} | _] = Stack}, S) when is_atom(M), is_atom(F), is_list(Location) ->
    reason(Reason, first(stack, frames(Stack), S));
reason(Reason, S) ->
    case leading(Reason) of
        none -> S;
        Atom -> first(reason, Atom, S)
    end.

-doc """
The reason's leading atom, or `none`: what this filter shows of a reason, and what the
`format_status/1` of a system domain process that holds other domains' or the host's
bytes shows of its own, since no filter runs there (docs/design-log.md, "Reports
carry no term"). Such a process shows a message or a request as its kind the same way.
""".
-spec reason_name(term()) -> atom().
reason_name(Reason) -> leading(Reason).

-doc """
A binary as its size, `{bytes, Size}`, and any other term as `hidden`: what a view of
status/2 shows of bytes from outside.
""".
-spec bytes(term()) -> {bytes, non_neg_integer()} | hidden.
bytes(Bytes) when is_binary(Bytes) -> {bytes, byte_size(Bytes)};
bytes(_Other) -> hidden.

-doc """
A record as a view of status/2 shows it: a copy with each field at `Position`
(`#record.field`) replaced by its shown value. The copy is a view, no longer a value
of the record's declared type, so it is built as a tuple and not as the record.
Unlike the filter's functions it is not total: a `Position` outside `Record` raises,
and only format_status callbacks, each over its own record, call it.
""".
-spec fields(tuple(), [{pos_integer(), term()}]) -> tuple().
fields(Record, Shown) ->
    lists:foldl(fun({Position, Value}, View) -> setelement(Position, View, Value) end,
                Record, Shown).

-type view() :: keep | fun((term()) -> term()).
-type shown_key() :: state | data | message.

-doc """
The status of a process that keeps its terms out of its reports: what a module's
`format_status/1` returns for the `Status` OTP hands it. `Views` names which of `state`,
`data` and `message` the module shows, and how: `keep` shows a value as it is, a function shows
what it returns, and it must be total over every term the key can hold. A key not named is
hidden. The log, the queue and the postponed events are always empty and the reason is
always its leading atom (reason_name/1), whatever the module says. A key that shows a term of the process
is a decision of the module, and its view says in one place what it keeps.
""".
-spec status(#{atom() => term()}, #{shown_key() => view()}) -> #{atom() => term()}.
status(Status, Views) ->
    maps:map(fun(Key, Value) -> shown(Key, Value, Views) end, Status).

shown(Key, Value, Views) when Key =:= state; Key =:= data; Key =:= message ->
    case maps:find(Key, Views) of
        {ok, View} -> view(View, Value);
        error -> hidden
    end;
shown(Key, Value, _Views) ->
    default(Key, Value).

default(log, _Value) -> [];
default(queue, _Value) -> [];
default(postponed, _Value) -> [];
default(reason, Reason) -> reason_name(Reason);
default(_Key, _Value) -> hidden.

view(keep, Value) -> Value;
view(View, Value) -> View(Value).

leading(Atom) when is_atom(Atom) -> Atom;
leading(Tuple) when tuple_size(Tuple) > 0 -> leading(element(1, Tuple));
leading(_Other) -> none.

%% The frames whose module and function are atoms, each with its arity alone.
frames([{M, F, Arguments, _Location} | Frames]) when is_atom(M), is_atom(F) ->
    case arity(Arguments, 0) of
        none -> frames(Frames);
        Arity -> [{M, F, Arity} | frames(Frames)]
    end;
frames([_Other | Frames]) -> frames(Frames);
frames(_End) -> [].

arity(Arity, 0) when is_integer(Arity), Arity >= 0 -> Arity;
arity([_ | Arguments], N) -> arity(Arguments, N + 1);
arity([], N) -> N;
arity(_Improper, _N) -> none.

%% Each summary key keeps the first fact that names it.
first(Key, Value, S) ->
    case S of
        #{Key := _} -> S;
        #{} -> S#{Key => Value}
    end.
