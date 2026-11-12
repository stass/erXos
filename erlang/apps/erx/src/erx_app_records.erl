%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_app_records).
-moduledoc """
The collector of the start table's records (docs/design-apps.md,
"Interfaces"), which `/proc/apps` shows: `[apps]`, the table, and
`[apps, Name]`, one start row. Every value comes from the start service,
erx_starter:rows/0, in the system domain, and is reported by `service`.

* `[apps]` carries the configured domains' names in boot order and
  whether rc.conf has been read, and lists the rows by principal; before
  the table is first made its rows are `unknown`.
* `[apps, Name]` carries the row's state and reason, whether rc.conf or
  the manifest enables it, its display, and the fields rc.conf sets. Its
  state is `refused`, with the refusal as its reason, `disabled`, or,
  for an enabled row, where the keepers' branch says its session stands
  (erx_starter:run()): `running`, `down`, `stopped` (marked so by
  `service NAME stop`) or `starting` (neither held nor marked). The
  reason of a down row, its session's last end, is not collected here
  and is `unknown`; the session's domain and the ends within the row's
  period have no collector and are `unsupported`. Before the table is
  first made every attribute of a row is `unknown`.
* With no start service in this runtime, as in the rescue configuration
  or on a development host, both paths are `{error, unsupported}`; a
  start service that does not answer is `{error, failed}`.

The pure core, record/2, takes the start service's table as data.
""".

-export([collect/1]).
-export([record/2]).
-export_type([table/0]).

%% erx_starter:rows/0's answer.
-type table() :: #{rows := [map()] | unmade, rc_conf := read | unread, boot_order := [binary()],
                   skipped := list()}.

-doc "The record of `[apps]` or `[apps, Name]` from the start service of this runtime.".
-spec collect([erx_schema:segment()]) -> {ok, erx_schema:record()} | {error, unsupported | failed | scope}.
collect(Path) ->
    try erx_starter:rows() of
        Table -> record(Path, Table)
    catch
        %% No start service runs here, or its application is not in this release.
        exit:{noproc, _} -> {error, unsupported};
        error:undef -> {error, unsupported};
        exit:_ -> {error, failed}
    end.

-doc """
The record of Path from the start service's Table, checked whole by
erx_schema:validate_record/1; `{error, scope}` for a row the table does
not hold, which names nothing.
""".
-spec record([erx_schema:segment()], table()) -> {ok, erx_schema:record()} | {error, scope}.
record([apps] = Path, #{rows := Rows, rc_conf := RcConf, boot_order := Order}) ->
    Children = case Rows of
                   unmade -> unknown;
                   _ -> [Name || #{principal := Name} <- Rows]
               end,
    validate(Path, start_table, #{boot_order => {service, {ok, Order}}, rc_conf => {service, {ok, RcConf}}},
             Children);
record([apps, _Name] = Path, #{rows := unmade}) ->
    {ok, Keys} = erx_schema:attributes(app),
    validate(Path, app, #{Key => {service, unknown} || Key <- Keys}, []);
record([apps, Name] = Path, #{rows := Rows}) ->
    case [Row || #{principal := Principal} = Row <- Rows, Principal =:= Name] of
        [Row] -> validate(Path, app, attributes(Row), []);
        [] -> {error, scope}
    end.

validate(Path, Kind, Attrs, Children) ->
    {ok, _} = erx_schema:validate_record(#{schema => erx_schema:schema(), path => Path, kind => Kind,
                                           id => lists:last(Path), attrs => Attrs, children => Children}).

%% A merged row's attributes (erx_start_table:merged() with its run).
attributes(#{enable := Enable, display := Display, from_rc_conf := Local, status := Status, run := Run}) ->
    {State, Reason} = state(Status, Run),
    #{state => {service, {ok, State}},
      reason => {service, Reason},
      domain => {service, unsupported},
      enabled => {service, {ok, Enable}},
      display => {service, {ok, display(Display)}},
      local => {service, {ok, Local}},
      ends => {service, unsupported}}.

%% A row's state and its reason's value.
state({refused, Refusal}, _Run) -> {refused, {ok, refusal(Refusal)}};
state(disabled, _Run) -> {disabled, {ok, <<>>}};
state(enabled, down) -> {down, unknown};
state(enabled, Run) when Run =:= running; Run =:= stopped; Run =:= starting -> {Run, {ok, <<>>}}.

%% A refusal as `/proc/apps` prints it: its kind and the name it carries,
%% each an identifier or a field's atom.
refusal({Kind, Name}) when is_binary(Name) -> <<(atom_to_binary(Kind))/binary, " ", Name/binary>>;
refusal({Kind, Field}) when is_atom(Field) -> <<(atom_to_binary(Kind))/binary, " ", (atom_to_binary(Field))/binary>>.

display(none) -> <<>>;
display(Name) -> Name.
