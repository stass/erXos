%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The system domain's console service, and a session's (docs/design-runtime.md, "The console and
%% standard I/O"; docs/design-live.md, "The console"): a program with its own line
%% editor on a raw terminal, as on Unix. It sits between its groups and the console's
%% driver, as user_drv does: the current group, which gets the input and is shown, and
%% the `user` group, which the shell's own group can ask for options and which is always
%% shown. Input bytes go to the current group as `{self(), {data, Chars}}`, and each
%% request of a shown group goes through prim_tty's terminal-less state to become bytes
%% for the driver. It runs no line discipline and reads no program's bytes.
%%
%% The console's first group runs the command shell (erx_shell:console/0), the shell a
%% person meets at boot, as a UNIX console's login shell is. When it ends, by `exit` or a
%% crash, the console starts a fresh one on a new first group while input may still
%% come, as getty starts another login, and ends the runtime once none can, as stock's
%% shell does at the end of its input. With -noshell or -noinput there is no shell, and
%% `user` is the first group.
%%
%% A shell typed at the shell takes the input on a group of its own (run_shell/1), as
%% user_drv's `s` and `c` start a shell and connect to it, and gives it back to the group
%% below when it ends; the groups below are not shown, so their output is acknowledged
%% and dropped, and only write/1's callers still reach the line. A command's output, which is bytes,
%% goes to the line through write/1, past prim_tty, with only a cooked tty's newline
%% processing.
%%
%% A session's tty relay is a console too, of the `session` role (start_link/1, config()):
%% the same groups on the session's raw tty, registered under a name of its own, with the
%% tty as its driver (erx_session_tty). It has no `user` group, writes no kernel log, starts
%% its first shell again whenever it ends, and at its line's hangup or end it ends every
%% shell and stops, never halting the runtime. A shell holds its console as a terminal (terminal/1),
%% so neither the shell nor its commands name the console they run on.
%%
%% The system console's driver is the module `-erx console_driver Module` names. It implements
%% `Module:start_link(Console) -> {ok, pid(), Terminal}`, where Terminal says whether a
%% person's terminal is on the line, and exchanges these messages:
%%
%%   to the driver:   {erx_console_output, From, Bytes}, written whole and in order
%%   from the driver: {erx_console_written, From}, once those bytes are written
%%                    {erx_console_input, Bytes}, the bytes as they were read
%%                    {erx_console_size, Columns, Rows}, when the line's size changes
%%                    erx_console_eof, after every byte read before the end
%%
%% The console is also the reader that writes the kernel log on the line (docs/design-live.md,
%% "The console"; docs/design-stopgap.md, "The console"). Every LOG_POLL_MS it takes the
%% records nobody has taken, each as the line the log core rendered with every byte of its
%% text escaped, and sends each to the driver whole, ending in CR-LF, between whatever else
%% is written. A log line can therefore land inside a program's line or an edited prompt, as
%% a kernel message does on a UNIX serial console. Until the root hands the log to the
%% console, the root writes each record to the line itself and takes it, so a take finds
%% nothing and no line is written twice. Other readers of the log read from cursors of their
%% own and take nothing from the console.
%%
%% It is the log sink's end too: the system domain's erx_log_h sends it each log event as a
%% record, {log, Level, Text}, and erx_console_log decides whether to take it and renders its
%% line, with the line escape, under the system domain's id, principal and name.
%%
%% It is the master of each session's tty (docs/design-live.md, "Between domains"). A
%% session's create spec names `console => facet()`, and the domain service mints the
%% session its own console facet in front of the console's facet endpoint
%% (facet_endpoint/1); the facet checks the sender, the size and the number in flight,
%% and forwards each of the tty's messages with its grantee's domain id, in a shape no
%% call of the grantee's can take. The endpoint refuses every call, so a session reaches
%% none of the console's own calls through its facet. The console keeps, for
%% each session by domain id, the master's state (erx_tty_master, which checks every
%% message); the tty, name, principal and domain pid that add_session/2 names, whose
%% domain pid it monitors; and a monitor of the facet. Either end is the session's.
%%
%% The line belongs to the console's own groups, to one connected session (connect/1), or
%% to the Ctrl-G menu (erx_console_menu). A connected session's output is copied to the
%% line as bytes, as a tty's master copies them, each answered only once the driver has
%% written it, and the bytes typed go to its tty. A typed Ctrl-G never reaches a session or
%% a group: it opens the menu, which lists the system shell and the line principal's live
%% sessions and connects one or gives the line to the groups, and the rest of the read
%% that carried it is dropped. erx_console_keys tells a typed Ctrl-G from the BEL that ends
%% a terminal's string reply, which stays in the input. While the menu or the groups
%% have the line, every session's tty is stopped, and when the groups get it back their
%% line is drawn again. A tty that fails a check is detached for good, with a log line
%% naming its domain; the console's own notices naming a domain or a session go to the
%% line through the line escape.

-module(erx_console).
-behaviour(gen_server).

-export([start/0, start_link/1, run_shell/1, run_shell/2, write/1, write/2, terminal/0, terminal/1]).
-export([facet/0, add_session/2, connect/1, detach/0]).
-export([input/2, first_shell/1, after_first_shell/2, erlang_shell_group/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([input_event/0, first_shell/0, after_first_shell/0, shell/0, config/0, terminal/0]).

-type input_event() :: {data, unicode:unicode_binary()} | interrupt | suspend.
%% The shell the console starts on its first group: the command shell, or none when
%% init was told -noshell or -noinput, and `user` then gets the input.
-type first_shell() :: {erx_shell, console, []} | none.
%% What follows the first group's end: a fresh command shell, or the runtime's end with
%% this status once no input can come.
-type after_first_shell() :: restart | {halt, 0 | 1}.
%% A shell's start function, as group:start/3 takes it.
-type shell() :: {module(), atom(), [term()]}.
%% A terminal as a shell holds it: its write/1 and its run_shell/1.
-type terminal() :: #{write := fun((iodata()) -> ok),
                      run_shell := fun((shell()) -> ok | {error, term()})}.
%% What a console is started as (start_link/1). `system` is the system domain's console:
%% it starts `user`, writes the kernel log and the system domain's log records, shows the
%% slogan and ends the runtime when its line or its input ends. `session` is a session's
%% tty relay (erx_session_tty): none of that; it starts its first shell again whenever it
%% ends, and ends every shell and stops when its line hangs up or ends. Name is the name
%% it registers.
%% `menu` says whether a typed Ctrl-G opens the Ctrl-G menu, by default for the system
%% console only: a session's relay reads every BEL as a byte, as a raw tty does.
-type config() :: #{role := system | session,
                    menu => boolean(),
                    name := atom(),
                    driver := fun((Console :: pid()) -> {ok, pid(), Terminal :: boolean()}),
                    first_shell := first_shell() | shell()}.

-define(DEFAULT_SIZE, {80, 24}).
-define(MAX_SIDE, 65535).
-define(LOG_POLL_MS, 100).
%% The system principal, number 1, whose domain the system domain is (include/erx/dom.h).
-define(SYSTEM_PRINCIPAL, 1).
-define(ESC, 16#1B).

-record(state, {role :: system | session,
                name :: atom(),
                first_shell :: first_shell() | shell(),
                driver :: pid(),
                %% The group the console started with, which the others return the input to:
                %% the command shell's, or `user` with no shell.
                base :: pid(),
                %% The `user` group, which only the system console has.
                user :: pid() | none,
                tty :: prim_tty:state(),
                size :: {pos_integer(), pos_integer()},
                terminal :: boolean(),
                %% The groups run_shell/1 started, innermost first, each with its caller
                %% to answer when it ends and the shell it runs. The innermost gets the
                %% input, or `base` when there are none (current/1).
                shells = [] :: [{pid(), gen_server:from(), shell()}],
                %% Whether the input has ended: each group that gets the input from then
                %% on is told so.
                input_ended = false :: boolean(),
                %% Each domain's log records this second, and those dropped.
                log_records = erx_console_log:new() :: erx_console_log:state(),
                %% The start of a character whose other bytes have not been read yet.
                pending = <<>> :: binary(),
                %% The input's escape state, which tells a typed Ctrl-G from the BEL that ends
                %% a terminal's string reply.
                keys = erx_console_keys:new() :: erx_console_keys:state(),
                %% Who has the line: the console's own groups, a domain's session, or the
                %% Ctrl-G menu, which knows who had the line before it.
                line = system :: erx_console_menu:owner() | {menu, erx_console_menu:menu()},
                %% The line's principal, whose sessions its menu lists: in a development
                %% build root, who is the system principal (docs/design-domains.md).
                principal = ?SYSTEM_PRINCIPAL :: pos_integer(),
                %% Whether a typed Ctrl-G opens the menu (config()).
                menu :: boolean(),
                %% The sessions whose tty the console is the master of, by domain id.
                sessions = #{} :: #{pos_integer() => session()},
                %% The process behind every session's console facet (facet_endpoint/1).
                endpoint :: pid()}).

%% A session: its tty, name, principal and domain pid with the pid's monitor, once
%% add_session/2 names them; the monitor of its console facet, once the facet has
%% forwarded a message; and the master's side of its tty.
-type session() :: #{tty := pid() | none, name := binary() | none, principal := pos_integer() | none,
                     domain := {pid(), reference()} | none, facet := reference() | none,
                     master := erx_tty_master:master()}.
%% What add_session/2 names of a session: its tty (the `tty` agent of its domain's ready
%% report), its name, its principal and its domain pid (erx_domain:pid/1).
-type session_spec() :: #{tty := pid(), name := binary(), principal := pos_integer(),
                          domain_pid := pid()}.

%% user_sup calls this, and waits for the `user` group to register.
-spec start() -> {ok, pid()} | {error, term()}.
start() ->
    gen_server:start({local, ?MODULE}, ?MODULE,
                     #{role => system, name => ?MODULE,
                       driver => fun(Console) -> (driver_module()):start_link(Console) end,
                       first_shell => first_shell(shell_arguments())}, []).

-doc """
Starts a console as Config says, linked to the caller and registered under Config's
name: a session's tty relay starts its own this way (erx_session_tty).
""".
-spec start_link(config()) -> {ok, pid()} | {error, term()}.
start_link(Config = #{name := Name, first_shell := {_, _, _}}) ->
    gen_server:start_link({local, Name}, ?MODULE, Config, []).

-doc """
Runs Shell, a shell's start function as group:start/3 takes it, on a group of its
own that gets the console's input until the shell ends, and returns then: `ok` if
the shell ended normally, `{error, Reason}` with its exit reason if not. The group
that had the input gets it back; shells started this way may end in any order.
Ctrl-C interrupts the new group's shell. This is how a shell typed at a shell
takes the console: the Erlang shell from the command shell's `erl`
(erx_cmd_erl), or another command shell from the Erlang shell's
erx_shell:start/0. The Erlang shell's group completes Erlang, as on stock;
any other shell's completes nothing.
""".
-spec run_shell(shell()) -> ok | {error, term()}.
run_shell(Shell) ->
    run_shell(?MODULE, Shell).

-doc "run_shell/1 on the console registered as Name.".
-spec run_shell(atom(), shell()) -> ok | {error, term()}.
run_shell(Name, Shell = {Module, Function, Args})
  when is_atom(Module), is_atom(Function), is_list(Args) ->
    gen_server:call(Name, {run_shell, Shell}, infinity).

-doc """
Writes Bytes to the console's line as they are, but for each newline, which goes out
as CR-LF as a cooked tty's ONLCR sends it, and returns once they are written: the
output of a command, which is bytes, never text the console renders.
""".
-spec write(iodata()) -> ok.
write(Bytes) ->
    write(?MODULE, Bytes).

-doc "write/1 on the console registered as Name.".
-spec write(atom(), iodata()) -> ok.
write(Name, Bytes) ->
    gen_server:call(Name, {write, iolist_to_binary(Bytes)}, infinity).

-doc """
The terminal of this domain's line, as a shell holds it: the session's tty in a
session's domain, the console in the system domain.
""".
-spec terminal() -> terminal().
terminal() ->
    terminal(persistent_term:get({?MODULE, line}, ?MODULE)).

-doc "The terminal of the console registered as Name.".
-spec terminal(atom()) -> terminal().
terminal(Name) ->
    #{write => fun(Bytes) -> write(Name, Bytes) end,
      run_shell => fun(Shell) -> run_shell(Name, Shell) end}.

-doc """
What a session's create spec names as its console facet, `console => facet()`: this
console, in front of which the domain service mints each session a facet of its own,
whose max_request is the largest message a tty sends (erx_tty_master:max_message/0).
""".
-spec facet() -> {pid(), #{max_request := pos_integer()}}.
facet() ->
    gen_server:call(?MODULE, facet).

-doc """
Names the session of domain Domain as Spec says: the console sends its tty the session's
input, size and answers, lists it by its name in the Ctrl-G menu of a line whose
principal is its principal, and ends it when its domain pid ends.
""".
-spec add_session(pos_integer(), session_spec()) -> ok.
add_session(Domain, Spec = #{tty := Tty, name := Name, principal := Principal, domain_pid := DomainPid})
  when is_integer(Domain), Domain > 0, is_pid(Tty), is_binary(Name), is_integer(Principal), Principal > 0,
       is_pid(DomainPid) ->
    gen_server:call(?MODULE, {add_session, Domain, maps:with([tty, name, principal, domain_pid], Spec)}).

-doc """
Gives the line to domain Domain's session, taking it from whoever had it: the session's
held output is written, and the bytes typed go to its tty until Ctrl-G or detach/0
gives the line to the menu or the console's own groups, or the session ends or fails a
check. {error, unknown} for a domain with no session or whose domain pid is down,
{error, no_tty} for a session that add_session/2 has not named, and {error, refused} for
one detached for a failed check.
""".
-spec connect(pos_integer()) -> ok | {error, unknown | no_tty | refused}.
connect(Domain) ->
    gen_server:call(?MODULE, {connect, Domain}).

-doc "Gives the line back to the console's own groups; every session's tty is stopped.".
-spec detach() -> ok.
detach() ->
    gen_server:call(?MODULE, detach).

-spec init(config()) -> {ok, #state{}}.
init(Config = #{role := Role, name := Name, driver := Start, first_shell := FirstShell}) ->
    process_flag(trap_exit, true),
    %% A domain has one line, which terminal/0 names.
    persistent_term:put({?MODULE, line}, Name),
    Console = self(),
    {ok, DriverPid, Terminal} = Start(self()),
    %% As user_drv does for a line with no terminal on it: no editing, no echo and bytes
    %% as they are.
    TTY = banner(Role, prim_tty:init_ssh(tty_options(Terminal), ?DEFAULT_SIZE, utf8), DriverPid),
    User = case Role of
               system -> group:start(self(), noshell, [{name, user}]);
               session -> none
           end,
    Group = case FirstShell of
                none -> User;
                Shell -> start_shell(Shell, Terminal)
            end,
    [erlang:send_after(?LOG_POLL_MS, self(), erx_log_poll) || Role =:= system],
    {ok, gets_input(#state{role = Role,
                           name = Name,
                           first_shell = FirstShell,
                           driver = DriverPid,
                           base = Group,
                           user = User,
                           tty = TTY,
                           size = ?DEFAULT_SIZE,
                           terminal = Terminal,
                           menu = maps:get(menu, Config, Role =:= system),
                           endpoint = spawn(fun() -> facet_endpoint(Console) end)})}.

%% What user_drv writes before it starts a shell, ahead of anything the groups write.
banner(session, TTY, _Driver) ->
    TTY;
banner(system, TTY, Driver) ->
    case first_shell(shell_arguments()) =/= none of
        true ->
            Line = unicode:characters_to_binary([slogan(), $\n]),
            {Bytes, NewTTY} = prim_tty:handle_request(TTY, {putc, Line}),
            Driver ! {erx_console_output, none, Bytes},
            NewTTY;
        false ->
            TTY
    end.

slogan() ->
    Default = fun() -> erlang:system_info(system_version) end,
    case application:get_env(stdlib, shell_slogan, Default) of
        Fun when is_function(Fun, 0) -> Fun();
        Slogan -> Slogan
    end.

%% Whether init was told -noshell and -noinput.
shell_arguments() ->
    #{noshell => init:get_argument(noshell) =/= error,
      noinput => init:get_argument(noinput) =/= error}.

-doc """
The shell the console starts on its first group, from whether init was told -noshell
and -noinput: the command shell, or none if either was given.
""".
-spec first_shell(#{noshell := boolean(), noinput := boolean()}) -> first_shell().
first_shell(#{noshell := false, noinput := false}) -> {erx_shell, console, []};
first_shell(#{}) -> none.

-doc """
What the console does when the shell of its first group ends for Reason, given
whether its input has ended: while input may still come, it starts a fresh command
shell, whatever the reason; once none can, it ends the runtime, with status 0 if the
shell ended normally, as stock's shell halts at the end of its input, and 1 if not.
""".
-spec after_first_shell(Reason :: term(), InputEnded :: boolean()) -> after_first_shell().
after_first_shell(_Reason, false) -> restart;
after_first_shell(normal, true) -> {halt, 0};
after_first_shell(_Reason, true) -> {halt, 1}.

-doc """
The group user_drv:whereis_group/0 reports, in which group:whereis_shell/0, and with
it shell:whereis/0, finds the shell, given the groups run_shell/1 started, innermost
first: the innermost one if it runs the Erlang shell, and `undefined` otherwise. shell:get_state/0, which edlin_expand calls, waits for the
Erlang shell's answer to `{shell_state, From}`; a command shell never sends one, so with
a command shell in front there is no Erlang shell to report, as with -noshell on stock.
The first group never runs the Erlang shell (first_shell/1).
""".
-spec erlang_shell_group([{pid(), gen_server:from(), shell()}]) -> pid() | undefined.
erlang_shell_group([{Group, _Caller, {shell, start, _Args}} | _]) -> Group;
erlang_shell_group(_Shells) -> undefined.

%% Starts Shell on a new group with the options every shell but the Erlang shell
%% gets: no completion, since the Erlang shell's would complete Erlang.
start_shell(Shell, Terminal) ->
    Options = [{expand_fun, fun(_Before, _Options) -> {no, [], []} end}
               | group_options(Terminal)],
    group:start(self(), Shell, Options).

%% As user_drv does for a line with no terminal on it: no editing, no echo and bytes as
%% they are; at the end of input the Erlang shell's stock branch ends the runtime.
group_options(Terminal) ->
    [{dumb, not Terminal},
     {expand_below, application:get_env(stdlib, shell_expand_location, below) =:= below}].

tty_options(true) -> #{};
tty_options(false) -> #{input => cooked, output => raw}.

-spec handle_call(term(), gen_server:from(), #state{}) ->
          {reply, term(), #state{}} | {noreply, #state{}}.
handle_call({run_shell, Shell = {shell, start, _}}, From, State = #state{shells = Shells, terminal = Terminal}) ->
    %% The Erlang shell completes Erlang, as on stock.
    New = group:start(self(), Shell, group_options(Terminal)),
    {noreply, gets_input(State#state{shells = [{New, From, Shell} | Shells]})};
handle_call({run_shell, Shell}, From, State = #state{shells = Shells, terminal = Terminal}) ->
    New = start_shell(Shell, Terminal),
    {noreply, gets_input(State#state{shells = [{New, From, Shell} | Shells]})};
handle_call({write, Bytes}, From, State = #state{driver = Driver}) ->
    Driver ! {erx_console_output, {caller, From}, onlcr(Bytes)},
    {noreply, State};
handle_call(facet, _From, State = #state{endpoint = Endpoint}) ->
    {reply, {Endpoint, #{max_request => erx_tty_master:max_message()}}, State};
handle_call({add_session, Domain, #{tty := Tty, name := Name, principal := Principal, domain_pid := Pid}},
            _From, State) ->
    Named = fun(Session = #{domain := Old}) ->
                    [demonitor(Monitor, [flush]) || {_Pid, Monitor} <- [Old]],
                    Session#{tty := Tty, name := Name, principal := Principal,
                             domain := {Pid, monitor(process, Pid)}}
            end,
    {reply, ok, with_session(Domain, Named, State)};
handle_call({connect, Domain}, _From, State) ->
    {Reply, Next} = connect_session(Domain, State),
    {reply, Reply, Next};
handle_call(detach, _From, State) ->
    {reply, ok, to_groups(none, State)};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}} | {stop, term(), #state{}}.
handle_info({erx_console_input, Bytes}, State = #state{keys = Keys, line = {menu, Menu}}) when is_binary(Bytes) ->
    {Action, Next} = erx_console_menu:key(Bytes, Keys, Menu),
    {noreply, menu_action(Action, Menu, State#state{keys = Next})};
handle_info({erx_console_input, Bytes}, State = #state{menu = true, keys = Keys}) when is_binary(Bytes) ->
    {Pieces, Next} = erx_console_keys:split(Bytes, Keys),
    {noreply, read(Pieces, State#state{keys = Next})};
handle_info({erx_console_input, Bytes}, State) when is_binary(Bytes) ->
    %% A console with no menu, a session's relay, reads a BEL as a raw tty does: as a byte.
    {noreply, read([Bytes], State)};
handle_info(erx_console_eof, State = #state{role = session, base = Base, shells = Shells}) ->
    %% A session's line has hung up: every shell on it ends, and the console with them,
    %% as a UNIX session ends at its terminal's hangup. No group is told of the end of
    %% input: the Erlang shell would halt the runtime at it, and edlin edits with it.
    lists:foreach(fun(Group) -> exit(Group, kill) end, [Base | [G || {G, _Caller, _Shell} <- Shells]]),
    {stop, normal, State};
handle_info(erx_console_eof, State = #state{pending = Pending}) ->
    %% What began a character will never end it, so it reads as stock reads a bad byte.
    [deliver({data, latin1(Pending)}, State) || Pending =/= <<>>],
    {noreply, gets_input(State#state{pending = <<>>, input_ended = true})};
handle_info({erx_console_size, Columns, Rows}, State = #state{tty = TTY})
  when is_integer(Columns), is_integer(Rows),
       Columns >= 1, Columns =< ?MAX_SIDE, Rows >= 1, Rows =< ?MAX_SIDE ->
    {noreply, session_size(State#state{tty = prim_tty:update_geometry(TTY, Columns, Rows),
                                       size = {Columns, Rows}})};
handle_info({erx_console_size, _Columns, _Rows}, State) ->
    {noreply, State};
handle_info(erx_log_poll, State = #state{driver = Driver}) ->
    case erx_log:take() of
        {Whole, _Next, Lost, Lines} ->
            Notes = [<<"erx_console: ", (integer_to_binary(Lost))/binary, " kernel log records lost\n">>
                     || Lost > 0],
            Broken = [<<"erx_console: a kernel log record failed its checks\n">> || Whole =:= corrupt],
            lists:foreach(fun(Line) -> Driver ! {erx_console_output, none, log_line(Line)} end,
                          Notes ++ Lines ++ Broken),
            erlang:send_after(?LOG_POLL_MS, self(), erx_log_poll),
            {noreply, State};
        {error, Status} ->
            Line = <<"erx_console: the kernel log refused a take: ", (integer_to_binary(Status))/binary, "\n">>,
            Driver ! {erx_console_output, none, log_line(Line)},
            erlang:send_after(?LOG_POLL_MS, self(), erx_log_poll),
            {noreply, State}
    end;
handle_info({log, _Level, _Text} = Record,
            State = #state{role = system, driver = Driver, log_records = Records}) ->
    %% A record sent to this name is the system domain's: another domain's send to a
    %% registered name never leaves that domain (edit 27 of docs/design-runtime.md),
    %% and its records arrive through its console facet, under its own source.
    case erx_console_log:accept(Record, system_source(), os:perf_counter(nanosecond), Records) of
        {line, Line, Next} ->
            Driver ! {erx_console_output, none, Line},
            {noreply, State#state{log_records = Next}};
        {dropped, Next} ->
            {noreply, State#state{log_records = Next}}
    end;
handle_info({erx_console_written, none}, State) ->
    {noreply, State};
handle_info({erx_console_written, {tty, Domain, N}}, State = #state{sessions = Sessions}) ->
    %% Output N of Domain's tty is on the line: only now is it taken.
    case Sessions of
        #{Domain := #{master := Master}} -> {noreply, carry_out(Domain, erx_tty_master:written(N, Master), State)};
        #{} -> {noreply, State}
    end;
handle_info({erx_tty_message, {Facet, _Tag} = From, Domain, Message}, State) ->
    %% A message of Domain's tty, which its console facet admitted and forwarded through
    %% the endpoint. It is answered once acted on, so the facet's limit in flight bounds
    %% what the session has queued here; the facet drops the answer.
    Next = from_tty(Domain, Facet, Message, State),
    gen:reply(From, ok),
    {noreply, Next};
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State = #state{sessions = Sessions}) ->
    %% A session's domain pid or its console facet, which ends with its domain, has ended:
    %% so has the session.
    case [Domain || Domain := Session <- Sessions, lists:member(Monitor, monitors(Session))] of
        [Domain] -> {noreply, session_ended(Domain, State)};
        [] -> {noreply, State}
    end;
handle_info({erx_console_written, {caller, From}}, State) ->
    gen_server:reply(From, ok),
    {noreply, State};
handle_info({erx_console_written, {Group, Reply}}, State) ->
    Group ! {reply, Reply, ok},
    {noreply, State};
handle_info({'EXIT', User, Reason}, State = #state{user = User}) ->
    %% user_sup kills `user` when the system stops: the runtime is on its way out.
    {stop, Reason, State};
handle_info({'EXIT', Pid, Reason},
            State = #state{role = Role, driver = Driver, base = Base, shells = Shells,
                           first_shell = FirstShell, terminal = Terminal, input_ended = Ended}) ->
    case lists:keytake(Pid, 1, Shells) of
        {value, {Pid, Caller, _Shell}, Others} ->
            %% A shell run_shell/1 started has ended, and its group with it, in whatever
            %% order: its caller gets how it ended, which the group's first exit carries
            %% from its shell, and the input goes to the innermost group left. The group's
            %% own exit, which follows, names a group the console no longer holds.
            gen_server:reply(Caller, shell_ended(Reason)),
            {noreply, gets_input(State#state{shells = Others})};
        false when Pid =:= Base ->
            %% The first group's shell has ended, and the group with it: a fresh one takes
            %% the first group's place. The old group's own exit, which follows, names a
            %% group the console no longer holds.
            case after_first_shell(Reason, Ended) of
                restart ->
                    New = start_shell(FirstShell, Terminal),
                    {noreply, gets_input(State#state{base = New})};
                {halt, 0} ->
                    erlang:halt(0),
                    {stop, Reason, State};
                {halt, Status} ->
                    ended_by(Reason),
                    erlang:halt(Status),
                    {stop, Reason, State}
            end;
        false when Pid =:= Driver, Role =:= session ->
            {stop, Reason, State};
        false when Pid =:= Driver ->
            %% Nothing would read the terminal again, and its keys no longer signal: end
            %% the runtime, whose exit restores the terminal.
            ended_by(Reason),
            erlang:halt(1),
            {stop, Reason, State};
        false ->
            {noreply, State}
    end;
handle_info(Message, State = #state{user = User, line = Line})
  when is_tuple(Message), tuple_size(Message) >= 2, is_pid(element(1, Message)) ->
    Pid = element(1, Message),
    Current = current(State),
    case is_group(Pid, State) of
        %% While a session has the line, the current group is hidden too.
        true when Pid =:= User; Pid =:= Current, Line =:= system ->
            {noreply, from_group(Message, State)};
        true ->
            {noreply, from_hidden_group(Message, State)};
        false ->
            {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

ended_by(Reason) ->
    erlang:display_string(stderr, lists:flatten(io_lib:format("erx_console: ended by ~p\r\n", [Reason]))).

%% Whether Pid is one of the console's groups: `user`, the one it started with, or one
%% run_shell/1 started.
is_group(Pid, #state{user = User, base = Base, shells = Shells}) ->
    Pid =:= User orelse Pid =:= Base orelse lists:keymember(Pid, 1, Shells).

%% The group that gets the input: the innermost shell run_shell/1 started, or the one
%% the console started with.
current(#state{shells = [{Group, _Caller, _Shell} | _]}) -> Group;
current(#state{base = Base}) -> Base.

%% State once its current group has the input: group:whereis_shell/0 finds that group if
%% it runs the Erlang shell (erlang_shell_group/1), and the group reads the input's end
%% if the input has ended. Telling a group twice is
%% harmless, as a second end of input is to a terminal.
gets_input(State = #state{input_ended = Ended}) ->
    Group = current(State),
    %% Not always Group: only the Erlang shell's group answers shell:get_state/0.
    put(current_group, erlang_shell_group(State#state.shells)),
    [Group ! {self(), eof} || Ended],
    State.

%% How a shell run_shell/1 started ended, as its caller is told.
shell_ended(normal) -> ok;
shell_ended(Reason) -> {error, Reason}.

%% A group below the one that has the input is not shown, as user_drv shows only its
%% current group: its output is acknowledged and dropped, so neither its writers nor
%% its shell's hints wait or reach the line, and its questions are answered.
from_hidden_group({Pid, {Sync, _Encoding, _Output, Reply}}, State)
  when Sync =:= put_chars_sync; Sync =:= put_ansi_sync ->
    Pid ! {reply, Reply, ok},
    State;
from_hidden_group(Message = {_Pid, Query}, State)
  when Query =:= tty_geometry; Query =:= get_unicode_state; Query =:= get_terminal_state;
       element(1, Query) =:= open_editor ->
    from_group(Message, State);
from_hidden_group(Message = {_Pid, Query, _Value}, State)
  when Query =:= set_unicode_state; Query =:= read ->
    from_group(Message, State);
from_hidden_group(_Output, State) ->
    State.

from_group({Pid, set_unicode_state, Unicode}, State = #state{tty = TTY}) ->
    ok = io:setopts(standard_error, [{encoding, encoding(Unicode)}]),
    Pid ! {self(), set_unicode_state, prim_tty:unicode(TTY)},
    State#state{tty = prim_tty:unicode(TTY, Unicode)};
from_group({Pid, read, _Count}, State) ->
    Pid ! {self(), {error, enotsup}},
    State;
from_group({Pid, Request}, State) ->
    group_request(Request, Pid, State);
from_group(_Message, State) ->
    State.

%% The driver's module, from the argument the boot information page carries. The last naming
%% wins, since the hosted entry adds its driver after the manifest's arguments, and a plain
%% word of the command line may have joined it.
driver_module() ->
    {ok, Arguments} = init:get_argument(erx),
    list_to_atom(lists:last([Word || ["console_driver", Word | _] <- Arguments])).

encoding(true) -> unicode;
encoding(false) -> latin1.

%% -- Sessions -------------------------------------------------------------------------

%% Domain's session after Update, made first if the console knows none of Domain's: a
%% session begins at its tty's first message or at add_session/2, whichever comes first.
with_session(Domain, Update, State = #state{sessions = Sessions}) ->
    New = #{tty => none, name => none, principal => none, domain => none, facet => none,
            master => erx_tty_master:new()},
    State#state{sessions = Sessions#{Domain => Update(maps:get(Domain, Sessions, New))}}.

%% The monitors whose 'DOWN' ends Session: its console facet's and its domain pid's.
monitors(#{facet := Facet, domain := Domain}) ->
    [Facet || Facet =/= none] ++ [Monitor || {_Pid, Monitor} <- [Domain]].

%% Whether Session can be connected: add_session/2 has named it, its domain pid is up,
%% and its tty has passed every check.
is_live(#{tty := Tty, domain := {Pid, _Monitor}, master := Master}) when is_pid(Tty) ->
    is_process_alive(Pid) andalso not erx_tty_master:is_refused(Master);
is_live(#{}) ->
    false.

%% A message of Domain's tty, through Facet, whose end the console watches from the
%% first one on.
from_tty(Domain, Facet, Message, State0) ->
    State = with_session(Domain, fun(Session = #{facet := none}) -> Session#{facet := monitor(process, Facet)};
                                    (Session) -> Session
                                 end, State0),
    #{Domain := #{master := Master}} = State#state.sessions,
    carry_out(Domain, erx_tty_master:output(Message, Master), State).

%% Bytes typed at the line, for Domain's session, which has it.
to_session(Domain, Bytes, State = #state{sessions = Sessions}) ->
    #{Domain := #{master := Master}} = Sessions,
    carry_out(Domain, erx_tty_master:input(Bytes, Master), State).

%% The line's size, for the session that has the line.
session_size(State = #state{line = {session, Domain}, size = {Columns, Rows}, sessions = Sessions}) ->
    #{Domain := #{master := Master}} = Sessions,
    carry_out(Domain, erx_tty_master:size({Rows, Columns}, Master), State);
session_size(State) ->
    State.

%% Domain's session takes the line from whoever had it, unless it is unnamed, down or
%% refused.
connect_session(Domain, State0 = #state{sessions = Sessions}) ->
    case Sessions of
        #{Domain := #{tty := none}} ->
            {{error, no_tty}, State0};
        #{Domain := Session = #{master := Master}} ->
            case {erx_tty_master:is_refused(Master), is_live(Session)} of
                {true, _} ->
                    {{error, refused}, State0};
                {false, false} ->
                    {{error, unknown}, State0};
                {false, true} ->
                    %% Whatever the line's last holder left, a string open or its text
                    %% hidden, ends before the session's held output.
                    ok = reset_line(State0),
                    State = (release(State0))#state{line = {session, Domain}},
                    #state{size = {Columns, Rows}, sessions = #{Domain := #{master := Disconnected}}} = State,
                    {ok, carry_out(Domain, erx_tty_master:connect({Rows, Columns}, Disconnected), State)}
            end;
        #{} ->
            {{error, unknown}, State0}
    end.

%% State with the line taken from the session that has it, if one does: the session is no
%% longer connected, and its tty is stopped. Who has the line next is the caller's to set.
release(State = #state{line = {session, Domain}, sessions = Sessions}) ->
    case Sessions of
        #{Domain := Session = #{master := Master}} ->
            State#state{sessions = Sessions#{Domain := Session#{master := erx_tty_master:disconnect(Master)}}};
        #{} ->
            State
    end;
release(State) ->
    State.

%% The line back to the console's own groups, after Notice, the console's own text, if
%% there is one. The session that had it is no longer connected, and its tty is stopped;
%% the current group draws its line again, since what it wrote while hidden was dropped.
to_groups(_Notice, State = #state{line = system}) ->
    State;
to_groups(Notice, State0) ->
    State = (release(State0))#state{line = system},
    ok = new_line(Notice, State),
    current(State) ! {self(), activate},
    State.

%% Ends what the line's last holder left on it before another takes it, unless the
%% console's own groups had it.
reset_line(#state{line = system}) -> ok;
reset_line(State) -> new_line(none, State).

%% Ends whatever a session or a command left on the line, a string open or its text
%% hidden, and starts a new line, with Notice on it if there is one.
new_line(Notice, #state{driver = Driver}) ->
    Line = [[erx_text:escape_line(Notice), <<"\r\n">>] || Notice =/= none],
    Driver ! {erx_console_output, none, [<<"\e\\\e[0m\r\n">>, Line]},
    ok.

%% Domain's session has ended: its domain pid or its console facet has. If it had the
%% line, the line goes back to the groups, and if the menu has the line and shows it, the
%% menu is drawn again without it; a session the menu does not show, another principal's,
%% is not named on this line.
session_ended(Domain, State0 = #state{line = Line, sessions = Sessions}) ->
    Principal = maps:get(principal, maps:get(Domain, Sessions)),
    State = State0#state{sessions = maps:remove(Domain, Sessions)},
    Notice = [<<"erx_console: ">>, session_label(Domain, maps:get(Domain, Sessions)), <<" has ended">>],
    case Line of
        {session, Domain} -> to_groups(Notice, State);
        {menu, Menu} ->
            %% A session of the line's principal may be one the menu only counts.
            case erx_console_menu:shows(Domain, Menu) orelse Principal =:= State#state.principal of
                true -> open_menu(Notice, erx_console_menu:back(Menu), State);
                false -> State
            end;
        _ -> State
    end.

%% How a notice names Domain's session: by the name add_session/2 gave it, attributed text
%% that the line escape later makes safe to show, and its domain id.
session_label(Domain, #{name := none}) ->
    [<<"the session of domain ">>, integer_to_binary(Domain)];
session_label(Domain, #{name := Name}) ->
    [<<"session ">>, Name, <<" (domain ">>, integer_to_binary(Domain), <<")">>].

%% -- The Ctrl-G menu ------------------------------------------------------------------

%% A read of the line's input, as erx_console_keys split it, while the groups or a session
%% have the line. A typed Ctrl-G reaches neither: it opens the menu, and the rest of the
%% read is dropped, since a person's next key comes in a read of its own and what a
%% terminal writes in one burst must not choose in the menu.
read([], State) ->
    State;
read([ctrl_g | _Dropped], State = #state{line = Back}) ->
    open_menu(none, Back, State);
read([Bytes | Rest], State = #state{line = {session, Domain}}) ->
    read(Rest, to_session(Domain, Bytes, State));
read([Bytes | Rest], State = #state{pending = Pending}) ->
    {Events, Left} = input(Pending, Bytes),
    lists:foreach(fun(Event) -> deliver(Event, State) end, Events),
    read(Rest, State#state{pending = Left}).

%% The menu takes the line, drawn after Notice if there is one, with Back as the entry
%% Esc returns to; the session that had the line, if one did, is stopped.
open_menu(Notice, Back, State0 = #state{driver = Driver, principal = Principal, sessions = Sessions}) ->
    State = release(State0),
    Listed = [#{domain => Domain, name => Name, principal => P, live => is_live(Session)}
              || Domain := Session = #{name := Name, principal := P} <- Sessions, is_binary(Name)],
    Menu = erx_console_menu:open(Principal, Listed, Back),
    ok = new_line(Notice, State),
    Driver ! {erx_console_output, none, erx_console_menu:text(Menu)},
    State#state{line = {menu, Menu}}.

%% The menu's Action, which a read while the menu had the line asked for, carried out.
menu_action(bell, _Menu, State) ->
    ok = bell(State),
    State;
menu_action(system, _Menu, State) ->
    to_groups(none, State);
menu_action({connect, Domain}, Menu, State = #state{principal = Principal, sessions = Sessions}) ->
    %% The menu lists only the line principal's sessions, but add_session/2 may have named
    %% the domain's session again, under another principal, since the menu was drawn.
    Connected = case Sessions of
                    #{Domain := #{principal := Principal}} -> connect_session(Domain, State);
                    #{} -> {{error, unknown}, State}
                end,
    case Connected of
        {ok, Next} ->
            Next;
        {{error, Reason}, Refused} ->
            Notice = io_lib:format("erx_console: cannot connect domain ~b: ~p", [Domain, Reason]),
            open_menu(Notice, erx_console_menu:back(Menu), Refused)
    end;
menu_action(start, Menu, State = #state{principal = Principal}) ->
    {error, Reason} = start_session(Principal),
    Notice = io_lib:format("erx_console: cannot start a session: ~p", [Reason]),
    open_menu(Notice, erx_console_menu:back(Menu), State).


%% Starts a session of Principal at this line, for the menu's "start a session": the
%% domain service's call that makes one from the principal's session template does not
%% exist yet, so every start is refused.
-spec start_session(pos_integer()) -> {error, enotsup}.
start_session(_Principal) ->
    {error, enotsup}.

bell(#state{driver = Driver, tty = TTY}) ->
    {Bytes, _} = prim_tty:handle_request(TTY, beep),
    Driver ! {erx_console_output, none, Bytes},
    ok.

%% Domain's master after Actions, which it carries out in order: a write goes to the driver,
%% which says when it is written; a message goes to the session's tty; and a detach, for
%% a tty that failed a check, takes the line from it, if it has it, and logs a line naming
%% the domain under the system domain's own source.
carry_out(Domain, {Actions, Master}, State = #state{sessions = Sessions}) ->
    Session = #{tty := Tty} = maps:get(Domain, Sessions),
    Next = State#state{sessions = Sessions#{Domain := Session#{master := Master}}},
    lists:foldl(fun(Action, Acc) -> carry_out_one(Domain, Tty, Action, Acc) end, Next, Actions).

carry_out_one(Domain, _Tty, {write, N, Bytes}, State = #state{driver = Driver}) ->
    Driver ! {erx_console_output, {tty, Domain, N}, Bytes},
    State;
carry_out_one(_Domain, Tty, {send, Message}, State) when is_pid(Tty) ->
    Tty ! Message,
    State;
carry_out_one(_Domain, none, {send, _Message}, State) ->
    State;
carry_out_one(Domain, _Tty, detach, State = #state{line = Line}) ->
    logger:notice("erx_console: domain ~b's tty failed the console's checks; detached", [Domain]),
    case Line of
        {session, Domain} -> to_groups(none, State);
        _ -> State
    end.

%% The process behind every session's console facet. It takes only what a facet forwards
%% of its grantee's messages, '$erx_facet_message', which no request a grantee sends
%% through its facet can be, and passes each to the console; it refuses every call, so no
%% session reaches the console's own calls (run_shell, write, connect and the rest). It
%% ends with the console, whatever the reason, and every console facet with it.
facet_endpoint(Console) ->
    Monitor = monitor(process, Console),
    facet_endpoint(Console, Monitor).

facet_endpoint(Console, Monitor) ->
    receive
        {'$erx_facet_message', {Facet, _Tag} = From, Domain, Message} when is_pid(Facet), is_integer(Domain) ->
            Console ! {erx_tty_message, From, Domain, Message};
        {'$gen_call', {Caller, _Tag} = From, _Request} when is_pid(Caller) ->
            gen:reply(From, {error, badarg});
        {'DOWN', Monitor, process, Console, Reason} ->
            exit(Reason);
        _Other ->
            ok
    end,
    facet_endpoint(Console, Monitor).

%% -- Input ----------------------------------------------------------------------------

%% A pure decision: what the bytes read so far mean, and what must wait for more.
%% Ctrl-C and Ctrl-Z are single bytes that no UTF-8 sequence contains; Ctrl-G never gets
%% here (read/2). Text reaches the
%% group as UTF-8, and a byte that is not part of a character reads as latin-1, as
%% prim_tty's reader does for stock's terminal.
-spec input(Pending :: binary(), Bytes :: binary()) -> {[input_event()], Left :: binary()}.
input(Pending, Bytes) ->
    events(<<Pending/binary, Bytes/binary>>).

events(Bin) ->
    case binary:match(Bin, [<<$\^C>>, <<$\^Z>>]) of
        nomatch ->
            text(Bin);
        {At, 1} ->
            <<Before:At/binary, Control, After/binary>> = Bin,
            {Text, Unfinished} = text(Before),
            {Later, Left} = events(After),
            {Text ++ data(latin1(Unfinished)) ++ [control(Control) | Later], Left}
    end.

text(Bin) ->
    case unicode:characters_to_binary(Bin, utf8) of
        Utf8 when is_binary(Utf8) ->
            {data(Utf8), <<>>};
        {incomplete, Utf8, Left} ->
            {data(Utf8), Left};
        {error, Utf8, <<Bad, Rest/binary>>} ->
            {Later, Left} = text(Rest),
            {data(Utf8) ++ data(latin1(<<Bad>>)) ++ Later, Left}
    end.

data(<<>>) -> [];
data(Utf8) -> [{data, Utf8}].

latin1(Bin) -> unicode:characters_to_binary(Bin, latin1).

control($\^C) -> interrupt;
control($\^Z) -> suspend.

deliver({data, Utf8}, State) ->
    current(State) ! {self(), {data, Utf8}};
deliver(interrupt, State) ->
    %% As ssh_cli does: the group turns this into an interrupt of the shell's evaluator.
    exit(current(State), interrupt);
deliver(suspend, State = #state{shells = Shells}) ->
    %% Ctrl-Z stops a command shell's foreground job: the group passes it on to its
    %% shell, which alone knows its jobs. The Erlang shell has none, and never sees it.
    case Shells of
        [{_Group, _Caller, {shell, start, _}} | _] -> ok;
        _ -> current(State) ! {self(), suspend}
    end.

%% -- Output ---------------------------------------------------------------------------

%% A command's bytes as a cooked tty's OPOST and ONLCR send them: each newline as CR-LF,
%% every other byte unchanged.
-spec onlcr(binary()) -> binary().
onlcr(Bytes) ->
    binary:replace(Bytes, <<"\n">>, <<"\r\n">>, [global]).

%% The system domain as the source of its own log records: its id, the system
%% principal and its name.
system_source() ->
    #{id => erx_kernel_records:system_domain(), principal => ?SYSTEM_PRINCIPAL, name => <<"system">>}.

%% A rendered log line ends in its one newline; a terminal's line ends in CR-LF.
log_line(<<>>) ->
    <<>>;
log_line(Line) ->
    [binary:part(Line, 0, byte_size(Line) - 1), <<"\r\n">>].

group_request(tty_geometry, Pid, State = #state{size = Size}) ->
    Pid ! {self(), tty_geometry, Size},
    State;
group_request(get_unicode_state, Pid, State = #state{tty = TTY}) ->
    Pid ! {self(), get_unicode_state, prim_tty:unicode(TTY)},
    State;
group_request(get_terminal_state, Pid, State = #state{terminal = Terminal}) ->
    Pid ! {self(), get_terminal_state, #{stdin => Terminal, stdout => Terminal, stderr => Terminal}},
    State;
group_request({open_editor, Buffer}, Pid, State) ->
    %% No external editor can run: the buffer comes back unchanged.
    Pid ! {self(), {editor_data, Buffer}},
    State;
group_request({requests, Requests}, _Pid, State = #state{tty = TTY}) ->
    {Bytes, NewTTY} = render_all(Requests, TTY, []),
    write(none, Bytes, State#state{tty = NewTTY});
group_request({put_chars_sync, Encoding, Chars, Reply}, Pid, State = #state{tty = TTY}) ->
    case encode(Encoding, Chars) of
        {ok, Text} ->
            {Bytes, NewTTY} = prim_tty:handle_request(TTY, {putc, Text}),
            write({Pid, Reply}, Bytes, State#state{tty = NewTTY});
        error ->
            Pid ! {reply, Reply, {error, {put_chars, Encoding, Chars}}},
            State
    end;
group_request({put_ansi_sync, Options, Ansi, Reply}, Pid, State) ->
    try io_ansi:format([Ansi], [], [{reset, false} | Options]) of
        Rendered ->
            group_request({put_chars_sync, unicode, Rendered, Reply}, Pid, State)
    catch _:_ ->
            Pid ! {reply, Reply, {error, {put_ansi, unicode, Ansi}}},
            State
    end;
group_request(Request, _Pid, State = #state{tty = TTY}) ->
    {Bytes, NewTTY} = prim_tty:handle_request(TTY, tty_request(Request)),
    write(none, Bytes, State#state{tty = NewTTY}).

write(From, Bytes, State = #state{driver = Driver}) ->
    Driver ! {erx_console_output, From, Bytes},
    State.

encode(Encoding, Chars) ->
    case unicode:characters_to_binary(Chars, Encoding) of
        Text when is_binary(Text) -> {ok, Text};
        _Failure -> error
    end.

%% The same merges as user_drv: prim_tty moves across lines only as one combined request.
render_all([{insert_chars, unicode, C1}, {insert_chars, unicode, C2} | Rs], TTY, Acc) ->
    render_all([{insert_chars, unicode, [C1, C2]} | Rs], TTY, Acc);
render_all([{put_chars, unicode, C1}, {put_chars, unicode, C2} | Rs], TTY, Acc) ->
    render_all([{put_chars, unicode, [C1, C2]} | Rs], TTY, Acc);
render_all([{move_rel, N}, {move_line, R}, {move_rel, M} | Rs], TTY, Acc) ->
    render_all([{move_combo, N, R, M} | Rs], TTY, Acc);
render_all([{move_rel, N}, {move_line, R} | Rs], TTY, Acc) ->
    render_all([{move_combo, N, R, 0} | Rs], TTY, Acc);
render_all([{move_line, R}, {move_rel, M} | Rs], TTY, Acc) ->
    render_all([{move_combo, 0, R, M} | Rs], TTY, Acc);
render_all([Request | Rs], TTY, Acc) ->
    {Bytes, NewTTY} = prim_tty:handle_request(TTY, tty_request(Request)),
    render_all(Rs, NewTTY, [Bytes | Acc]);
render_all([], TTY, Acc) ->
    {lists:reverse(Acc), TTY}.

%% A group's request in prim_tty's terms.
tty_request({put_chars, unicode, Chars}) -> {putc, unicode:characters_to_binary(Chars)};
tty_request({put_expand, unicode, Chars, N}) -> {expand, unicode:characters_to_binary(Chars), N};
tty_request({move_expand, N}) -> {move_expand, N};
tty_request({move_rel, N}) -> {move, N};
tty_request({insert_chars, unicode, Chars}) -> {insert, unicode:characters_to_binary(Chars)};
tty_request({insert_chars_over, unicode, Chars}) -> {insert_over, unicode:characters_to_binary(Chars)};
tty_request({delete_chars, N}) -> {delete, N};
tty_request(Request) -> Request.
