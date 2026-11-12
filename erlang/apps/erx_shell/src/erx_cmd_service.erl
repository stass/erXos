%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_service).
-moduledoc """
`service -e` and `service NAME COMMAND [display=D] [restarts=N]
[period=S]`: the start table's interface (docs/design-apps.md,
"Interfaces"), as FreeBSD's service(8) and rc.subr(8) are rc.d's.

The command reads the table from the inspector, `[apps]` and `[apps,
Name]` (`/proc/apps`), and changes it only by writing one line to
`/apps/ctl` for each act, so it holds no authority of its own: the
session's `apps` grant is what lets it act, and the start service checks
every line it writes.

* `service -e` writes the configured domains in boot order, then each
  row that is enabled and not refused, one name a line. While rc.conf is
  unread it says so on standard error, since the rows may not be what
  the file sets.
* `enable` and `disable` write the row's settings to rc.conf, `enable`
  with any `display=D`, `restarts=N` and `period=S`, and say so as
  FreeBSD's do: `NAME enabled in /apps/rc.conf`. `enable` also starts
  the row.
* `start`, `stop`, `restart` and `status` act on an enabled row. On a row
  that is not enabled each answers as rc.subr does, `Cannot 'start'
  NAME. Set NAME_enable to YES in /apps/rc.conf or use 'onestart'
  instead of 'start'.`, with status 0, and does nothing. `onestart`,
  `onestop`, `onerestart` and `onestatus` skip that check; `onestart`
  starts one session no supervisor keeps, and takes `display=D`. A
  session started so is kept by no row and not shown at `/proc/apps`, so
  `onestatus` of a row that is not enabled says only that.
* `start` of a running row and `stop` of one that is not running answer
  as rc.subr does, with status 1; `status` says whether the row is
  running, and for one that is not, its state from `/proc/apps`.
* A name that is a configured domain is the system's own: every command
  answers that it is configured in the system manifest, with status 1,
  since `service` neither changes one nor reads its state.

A refused ctl write answers an errno (design-apps.md, "The apps tree"),
which the command names in words, with status 1; the row's own reason is
at `/proc/apps`. Every name and value written comes from the inspector or
the command line and passes through the field escape
(erx_text:escape_field/1).

The decisions are a pure core, parse/1, listing/2 and plan/3, which the
tests drive with records made up as data; run/2 reads the inspector,
writes `/apps/ctl` and prints.
""".

-behaviour(erx_cmd).
-erx_command(service).
-erx_usage("service -e | service name command [display=D] [restarts=N] [period=S]").
%% The start table's tree, `/apps`: a session whose template holds no apps grant
%% has none, and every act of the command is a write to its ctl file.
-erx_needs([apps]).

-export([run/2]).
-export([parse/1, listing/2, plan/3]).
-export_type([request/0, step/0]).

-define(CTL, <<"/apps/ctl">>).
-define(RC_CONF, <<"/apps/rc.conf">>).

-doc """
A parsed command line: `-e`, or a command on a row, `one` saying the
command skips the enabled check, with its `key=value` settings.
""".
-type request() :: enabled
                 | {Name :: binary(), Command :: start | stop | restart | status | enable | disable,
                    One :: boolean(), Settings :: [binary()]}.
-doc """
One step of a plan, carried out in order: text to standard output or
standard error, a line written to `/apps/ctl`, which ends the plan with
status 1 when it is refused, or the status the command exits with.
""".
-type step() :: {out, iodata()} | {err, iodata()} | {ctl, binary()} | {status, ok | failed}.

%% The commands and the settings each takes; the `one` forms take their
%% command's, and `onestart` a display besides.
-define(COMMANDS, [{<<"start">>, start, []}, {<<"stop">>, stop, []},
                   {<<"restart">>, restart, []}, {<<"status">>, status, []},
                   {<<"enable">>, enable, [<<"display">>, <<"restarts">>, <<"period">>]},
                   {<<"disable">>, disable, []}]).

%%% The command

run(Args, Ctx) ->
    case parse(Args) of
        {ok, enabled} ->
            carry_out(listed(), Ctx);
        {ok, {Name, _Command, _One, _Settings} = Request} ->
            carry_out(plan(Request, erx_inspector:inspect([apps]), row(Name)), Ctx);
        {error, usage} ->
            {error, usage}
    end.

%% `service -e`'s plan, from the table and each of its rows.
listed() ->
    Table = erx_inspector:inspect([apps]),
    Rows = case Table of
               {ok, #{children := Names}} when is_list(Names) -> [{Name, row(Name)} || Name <- Names];
               _ -> []
           end,
    listing(Table, Rows).

%% The record of row Name; a name no row has is no row.
row(Name) ->
    case erx_inspector:inspect([apps, Name]) of
        {error, scope} -> none;
        Answer -> Answer
    end.

carry_out([], _Ctx) ->
    ok;
carry_out([{out, Text} | Rest], Ctx) ->
    erx_cmd:write(Ctx, Text),
    carry_out(Rest, Ctx);
carry_out([{err, Text} | Rest], Ctx) ->
    erx_cmd:say(Ctx, Text),
    carry_out(Rest, Ctx);
carry_out([{ctl, Line} | Rest], Ctx) ->
    case write_ctl(Ctx, Line) of
        ok ->
            carry_out(Rest, Ctx);
        {error, Reason} ->
            erx_cmd:say(Ctx, [<<"service: ">>, refusal(Reason), $\n]),
            {error, {reported, <<"1">>}}
    end;
carry_out([{status, ok} | _], _Ctx) ->
    ok;
carry_out([{status, failed} | _], _Ctx) ->
    {error, {reported, <<"1">>}}.

%% One write of Line to the ctl file: its answer is the command's.
write_ctl(Ctx, Line) ->
    case file:open(erx_cmd:path(Ctx, ?CTL), [write, raw, binary]) of
        {ok, Fd} ->
            try file:write(Fd, Line) after file:close(Fd) end;
        {error, _} = Error ->
            Error
    end.

%% A ctl write's errno in words (docs/design-apps.md, "The apps tree").
refusal(einval) -> <<"the start service refused the request; the log says why">>;
refusal(ebusy) -> <<"the display is held by another enabled row">>;
refusal(eperm) -> <<"the display is not granted to the row's template">>;
refusal(eagain) -> <<"rc.conf has not been read yet; try again">>;
refusal(eio) -> <<"rc.conf could not be written or the row could not be started">>;
refusal(Reason) -> [?CTL, <<": ">>, erx_cmd:format_error(Reason)].

%%% The core

-doc "The request a command line makes, or a usage error.".
-spec parse([binary()]) -> {ok, request()} | {error, usage}.
parse([<<"-e">>]) ->
    {ok, enabled};
parse([<<"-", _/binary>> | _]) ->
    {error, usage};
parse([Name, Word | Settings]) ->
    {One, Base} = case Word of
                      <<"one", Rest/binary>> -> {true, Rest};
                      _ -> {false, Word}
                  end,
    case lists:keyfind(Base, 1, ?COMMANDS) of
        {_, Command, Keys} ->
            Allowed = case {One, Command} of
                          {true, start} -> [<<"display">>];
                          _ -> Keys
                      end,
            case has_one_form(One, Command) andalso
                 lists:all(fun(Setting) -> setting(Setting, Allowed) end, Settings) of
                true -> {ok, {Name, Command, One, Settings}};
                false -> {error, usage}
            end;
        _ ->
            {error, usage}
    end;
parse(_Args) ->
    {error, usage}.

%% Whether a command has the `one` form it is written with: enable and
%% disable have none.
has_one_form(true, Command) -> Command =/= enable andalso Command =/= disable;
has_one_form(false, _Command) -> true.

%% Whether Setting is `key=value` with a key of Keys and a value of printable
%% bytes with no blank, so one argument is one setting of the ctl line.
setting(Setting, Keys) ->
    case binary:split(Setting, <<"=">>) of
        [Key, Value] ->
            lists:member(Key, Keys) andalso
                lists:all(fun(Byte) -> Byte > $\s andalso Byte < 127 end,
                          binary_to_list(Value));
        _ -> false
    end.

-doc """
`service -e`'s plan from the inspector's answers: the record of `[apps]`
and, for each of its rows, the name and the answer for `[apps, Name]`.
""".
-spec listing(erx_inspector:answer(), [{binary(), erx_inspector:answer() | none}]) -> [step()].
listing({ok, #{attrs := #{boot_order := {_, {ok, Order}}} = Attrs, children := Names}}, Rows) ->
    Unread = case Attrs of
                 #{rc_conf := {_, {ok, read}}} -> [];
                 #{} -> [{err, [<<"service: ">>, ?RC_CONF, <<" has not been read yet; the rows may not be what it sets\n">>]}]
             end,
    Domains = [{out, [field(Domain), $\n]} || Domain <- Order],
    case Names of
        _ when is_list(Names) ->
            Listed = lists:append([listed_row(Name, Answer) || {Name, Answer} <- Rows]),
            Unread ++ Domains ++ Listed ++ [{status, case lists:keymember(err, 1, Listed) of
                                                         true -> failed;
                                                         false -> ok
                                                     end}];
        _ ->
            %% unknown before the table is made; nothing else is answered whole.
            Unread ++ Domains ++ [{err, <<"service: the start table is not made yet\n">>}, {status, failed}]
    end;
listing(Answer, _Rows) ->
    [{err, [<<"service: ">>, inspector(Answer)]}, {status, failed}].

%% A row of `service -e`: listed when it is enabled and not refused.
listed_row(Name, {ok, #{attrs := Attrs}}) ->
    case {value(enabled, Attrs), value(state, Attrs)} of
        {{ok, true}, {ok, State}} when State =/= refused -> [{out, [field(Name), $\n]}];
        {{ok, _}, {ok, _}} -> [];
        _ -> [{err, [<<"service: ">>, field(Name), <<": its state is unknown\n">>]}]
    end;
listed_row(Name, Answer) ->
    [{err, [<<"service: ">>, field(Name), <<": ">>, inspector(Answer)]}].

-doc """
The plan of a command on a row, from the inspector's answers for `[apps]`
and for `[apps, Name]`, `none` when no row has that name.
""".
-spec plan(request(), erx_inspector:answer(), erx_inspector:answer() | none) -> [step()].
plan({Name, _Command, _One, _Settings}, {ok, #{attrs := #{boot_order := {_, {ok, Order}}}}}, none) ->
    case lists:member(Name, Order) of
        true -> [{err, [field(Name), <<" is configured in the system manifest\n">>]}, {status, failed}];
        false -> [{err, [<<"service: ">>, field(Name), <<" does not exist in the system manifest\n">>]},
                  {status, failed}]
    end;
plan(Request, {ok, _Table}, {ok, #{attrs := Attrs}} = Row) ->
    case {value(enabled, Attrs), value(state, Attrs)} of
        {{ok, Enabled}, {ok, State}} -> act(Request, Enabled, State, Row);
        {{ok, _}, Other} -> not_known(Request, <<"state">>, Other);
        {Other, _} -> not_known(Request, <<"enabled">>, Other)
    end;
plan(_Request, {ok, _Table}, Answer) ->
    [{err, [<<"service: ">>, inspector(Answer)]}, {status, failed}];
plan(_Request, Answer, _Row) ->
    [{err, [<<"service: ">>, inspector(Answer)]}, {status, failed}].

act({Name, enable, _One, Settings}, _Enabled, _State, _Row) ->
    [{ctl, line(<<"enable">>, Name, Settings)}, {out, [field(Name), <<" enabled in ">>, ?RC_CONF, $\n]}];
act({Name, disable, _One, []}, _Enabled, _State, _Row) ->
    [{ctl, line(<<"disable">>, Name, [])}, {out, [field(Name), <<" disabled in ">>, ?RC_CONF, $\n]}];
act({Name, Command, false, _Settings}, false, _State, _Row) ->
    Word = atom_to_binary(Command),
    %% rc.subr answers so and returns 0.
    [{out, [<<"Cannot '">>, Word, <<"' ">>, field(Name), <<". Set ">>, field(Name),
            <<"_enable to YES in ">>, ?RC_CONF, <<" or use 'one">>, Word, <<"' instead of '">>, Word, <<"'.\n">>]},
     {status, ok}];
act({Name, start, _One, _Settings}, _Enabled, running, _Row) ->
    [{err, [field(Name), <<" already running?\n">>]}, {status, failed}];
act({Name, start, _One, Settings}, _Enabled, _State, _Row) ->
    start_steps(Name, Settings);
act({Name, stop, _One, _Settings}, Enabled, State, _Row) ->
    case stoppable(Enabled, State) of
        true -> stop_steps(Name);
        false -> [{err, [field(Name), <<" not running? (">>, atom_to_binary(State), <<")\n">>]}, {status, failed}]
    end;
act({Name, restart, _One, _Settings}, Enabled, State, _Row) ->
    case stoppable(Enabled, State) of
        true -> stop_steps(Name);
        false -> [{err, [field(Name), <<" not running? (">>, atom_to_binary(State), <<")\n">>]}]
    end ++ start_steps(Name, []);
act({Name, status, _One, _Settings}, _Enabled, running, _Row) ->
    [{out, [field(Name), <<" is running.\n">>]}];
act({Name, status, _One, _Settings}, _Enabled, disabled, _Row) ->
    %% A session onestart started is kept by no row, and the table does not show it.
    [{out, [field(Name), <<" is not enabled; a session started with onestart is not shown.\n">>]},
     {status, failed}];
act({Name, status, _One, _Settings}, _Enabled, State, {ok, #{attrs := Attrs}}) ->
    Reason = case value(reason, Attrs) of
                 {ok, <<>>} -> [];
                 {ok, Text} -> [<<": ">>, field(Text)];
                 _ -> []
             end,
    [{out, [field(Name), <<" is not running (">>, atom_to_binary(State), Reason, <<").\n">>]}, {status, failed}].

%% Whether stop acts: on a row that runs or is yet to start, which stop
%% marks so the table does not start it, or on one not enabled, whose
%% session started once the start service alone knows of.
stoppable(_Enabled, running) -> true;
stoppable(_Enabled, starting) -> true;
stoppable(false, _State) -> true;
stoppable(true, _State) -> false.

start_steps(Name, Settings) ->
    [{out, [<<"Starting ">>, field(Name), <<".\n">>]}, {ctl, line(<<"start">>, Name, Settings)}].

stop_steps(Name) ->
    [{out, [<<"Stopping ">>, field(Name), <<".\n">>]}, {ctl, line(<<"stop">>, Name, [])}].

%% A ctl line: the verb, the row's name and its settings, as one write.
line(Verb, Name, Settings) ->
    iolist_to_binary([lists:join($\s, [Verb, Name | Settings]), $\n]).

%% An attribute's value, or what stands in its place.
value(Key, Attrs) ->
    case Attrs of
        #{Key := {_Reporter, {ok, Value}}} -> {ok, Value};
        #{Key := {_Reporter, Other}} -> Other;
        #{} -> unknown
    end.

%% An inspector answer that holds no record, as a diagnostic line.
inspector({error, no_facet}) -> <<"/proc/apps: no inspect facet\n">>;
inspector({error, Reason}) when is_atom(Reason) -> [<<"/proc/apps: ">>, atom_to_binary(Reason), $\n];
inspector(_Answer) -> <<"/proc/apps: unexpected answer\n">>.

field(Text) -> erx_text:escape_field(Text).

%% The plan when a row's attribute Attr is not known: its status, never a
%% made-up value.
not_known({Name, _Command, _One, _Settings}, Attr, Value) ->
    [{err, [<<"service: ">>, field(Name), $:, $\s, Attr, $\s, status(Value), $\n]},
     {status, failed}].

%% A value that is not known, as its status: unknown, unsupported, error...
status({Status, _Detail}) when is_atom(Status) -> atom_to_binary(Status);
status(Status) when is_atom(Status) -> atom_to_binary(Status);
status(_Value) -> <<"unexpected">>.
