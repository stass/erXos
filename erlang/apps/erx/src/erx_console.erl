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
%% Its supervisor, erx_console_sup, starts the system console again whenever it ends
%% (docs/design-live.md, "Failure handling, diagnostics and debuggability"). Its groups,
%% its driver, the owners of its lines and its facet endpoint end with it, and with them
%% every shell on the line and every session's console facet; the restarted console
%% writes the slogan and starts its driver, a new `user` and its command shell, as at
%% boot. It logs no principal in: the sessions its predecessor knew run on, unreachable
%% from the line (TODO.md).
%%
%% A shell typed at the shell takes the input on a group of its own (run_shell/1), as
%% user_drv's `s` and `c` start a shell and connect to it, and gives it back to the group
%% below when it ends; the groups below are not shown, so their output is acknowledged
%% and dropped, and only write/1's callers still reach the line. A command's output, which is bytes,
%% goes to the line through write/1, past prim_tty, with only a cooked tty's newline
%% processing.
%%
%% Each of a session's ttys has a console too, of the `session` role (start_link/1,
%% config()): the same groups, unregistered. Each is driven by a terminal relay of
%% its own (erx_session_relay), which it reads on demand (reader()) and tells which
%% job holds the terminal; only the domain's line's relay is registered, as
%% erx_tty_owner. Only the domain's line among them holds `user`; none writes
%% the kernel log; each starts
%% its first shell again whenever it ends, and at its line's hangup or end it ends every
%% shell and stops, never halting the runtime. A shell holds its console as a terminal (terminal/1),
%% so neither the shell nor its commands name the console they run on.
%%
%% The system console's driver is the module of the peripheral `-erx_record console PERIPHERAL`
%% names (console_driver/1). It implements
%% `Module:console_records() -> [erx_device:spec()]`, the device records it drives, and
%% `Module:start_link(Console) -> {ok, pid(), Terminal}`, where Terminal says whether a
%% person's terminal is on the line, and exchanges these messages:
%%
%%   to the driver:   {erx_console_output, From, Bytes}, written whole and in order
%%                    erx_console_taken, once the input message last sent is taken
%%   from the driver: {erx_console_written, From}, once those bytes are written
%%                    {erx_console_input, Bytes}, the bytes as they were read
%%                    erx_console_lost, where input was lost, in order with the bytes
%%                    {erx_console_size, Rows, Columns}, when the line's size changes
%%                    erx_console_eof, after every byte read before the end
%%
%% A driver sends its next input message, bytes or a loss, only after erx_console_taken
%% answers the last, so the console's mailbox holds at most one input message from it
%% (docs/design-live.md, "Lost input"). It serves output while it waits.
%%
%% Before the driver the console starts the owners of the shared lines its records name
%% (erx_irq_line:start_owners/1), linked to it as the driver is, and takes an owner's end
%% as the driver's (docs/design-shared-devices.md, "Lines inside a domain").
%%
%% The system console is also the system log's console consumer (docs/design-log.md,
%% "Consumers and backlogs"). It asks the log service, erx_syslog, for its next batch
%% (erx_syslog:next/1) without waiting, and writes each line of the batch to the driver
%% whole, ending in CR-LF, between whatever else is written; a log line can therefore land
%% inside a program's line or an edited prompt, as a kernel message does on a UNIX serial
%% console. It asks again once the driver has written the batch, so it holds at most one,
%% and when the service ends or is not running it asks again each LOG_ASK_MS. Every line
%% is the service's, made through the line escape or escaped by the kernel, and the
%% console takes nothing from the kernel's ring: the service is its one taker, and its
%% first take, before user_sup starts the console, hands the UART over from the early
%% console.
%%
%% It is the master of each session's tty (docs/design-live.md, "Between domains"). A
%% session's create spec names `console => facet()`, and the domain service mints the
%% session its own console facet in front of the console's facet endpoint
%% (facet_endpoint/1); the facet checks the sender, the size and the number in flight,
%% and forwards each of the tty's messages with its grantee's domain id, in a shape no
%% call of the grantee's can take. The endpoint refuses every call, so a session reaches
%% none of the console's own calls through its facet. The console keeps, for
%% each session by domain id, the master's state (erx_tty_master, which checks every
%% message); the name, principal and domain pid that add_session/2 names, whose domain
%% pid it monitors; the tty, which names itself through the facet ({tty_open, Tty}, a pid
%% of the facet's grantee); and a monitor of the facet. Either end is the session's.
%%
%% It starts the sessions of its line's principal (start_session/2): at boot, once the
%% domain service runs (login/0, boot step 4 of docs/design-system.md), and from the
%% menu's "start a session". A helper asks the domain service, which builds the session
%% from the principal's session template with the line's console facet, and the console
%% hears the answer as a message, never waiting for a domain to boot. The session the
%% login starts takes the line once its tty names itself, so the UART's first prompt is
%% root's session's; one that cannot start leaves the line with the system shell after
%% one line saying why, and a principal with no session template, or a runtime with no
%% domain service, leaves it there silently. A session that ends while it has the line
%% gives it back after one line, `session root_1 ended: {halt,3}`, through the line
%% escape, and when the login's session ends the console logs the principal in again.
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

-export([start_link/0, start_link/1, run_shell/1, run_shell/2, write/1, write/2, terminal/0, terminal/1]).
-export([facet/0, add_session/2, login/0, login_session/0, connect/1, detach/0, first_group/0]).
-export([chars/2, first_shell/1, shell_end/4, shell_ending/1, erlang_shell_group/1, console_driver/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([first_shell/0, on_shell_end/0, shell_end/0, shell/0, config/0, terminal/0, size/0]).

-include("generated/erx_abi.hrl").

%% The shell the console starts on its first group: the command shell, or none when
%% init was told -noshell or -noinput, and `user` then gets the input.
-type first_shell() :: {erx_shell, console, []} | none.
%% What a console does when its first shell ends (the config's `on_shell_end`): start
%% it again, or report how the shell ended to Notify and stop.
-type on_shell_end() :: restart | {exit, Notify :: fun((erx_prog:status()) -> term())}.
%% What the console does with one exit of its first group (shell_end/4): start a fresh
%% command shell, end the runtime with this status, wait for the relay's drain and then
%% report this ending, or nothing, for the group's own exit after its first.
-type shell_end() :: restart | {halt, 0 | 1} | {drain, erx_prog:status()} | ignore.
%% A shell's start function, as group:start/3 takes it.
-type shell() :: {module(), atom(), [term()]}.
%% A terminal as a shell holds it: its write/1 and its run_shell/1.
-type terminal() :: #{write := fun((iodata()) -> ok),
                      run_shell := fun((shell()) -> ok | {error, term()})}.
%% What a console is started as (start_link/1). `system` is the system domain's console:
%% it starts `user`, writes the kernel log and the system domain's log records, shows the
%% slogan and ends the runtime when its line or its input ends. `session` is a session's
%% tty (erx_session_tty): none of that; it starts its first shell again whenever it
%% ends, and ends every shell and stops when its line hangs up or ends. `name` is the
%% name it registers, if any: a session's ttys register none. `domain_line` says whether it is
%% its domain's line, which terminal/0 names: a session's console tty is. `driver`
%% starts the console's driver and says what it is: `true` or `false` for one that
%% sends the input as it arrives, by whether a person's terminal is at its far end,
%% and `relay` for a terminal relay (erx_session_relay), which the console reads on
%% demand and whose terminal its first shell gives to its jobs, as every session
%% tty's driver is. A
%% `first_shell` that is a function gets the console's own terminal (terminal/1) and
%% returns the shell, so the shell of an unregistered console can reach it.
%% `menu` says whether a typed Ctrl-G opens the Ctrl-G menu, by default for the system
%% console only: a session's relay reads every BEL as a byte, as a raw tty does. A
%% driver with no person's terminal on its line never has one, since no person types
%% at it.
%% `owner` is the domain a pid belongs to, erx:owner/1 by default, which a host test
%% replaces as it replaces the export table.
%% `user` says what the console does with a `user` already registered as it starts
%% (start_user/1). `replace`, which start_link/0 passes, kills it and starts its own.
%% That is the system console's mode under erx_console_sup: in a runtime started with
%% `-user erx_console` nothing but the console registers `user` (user_sup starts no
%% user_drv and no relay), so a registered `user` is its predecessor's. `take`, the
%% default, keeps it: a session's console tty takes its domain's, and a console a host
%% test starts leaves the group of the runtime's own driver (user_drv) alone. `none`
%% neither starts nor takes one: a session's other ttys pass it, so `user` is the line's
%% and lives as long as the line, whichever of the other ttys end.
%% `on_shell_end` says what follows the first group's end on a session's tty whose
%% driver is a relay: `restart`, the default, starts the shell again; `{exit, Notify}`,
%% which a tty of an SSH channel passes (docs/design-ssh.md, "Sessions, ttys and
%% shells"), waits until the relay's master has taken the tty's last output, calls
%% Notify with how the shell ended (shell_ending/1) and stops, its relay with it.
%% `size` is the terminal's first size (size()), 24 rows by 80 columns by default; the
%% driver's size reports change it from then on.
-type config() :: #{role := system | session,
                    menu => boolean(),
                    principal => pos_integer(),
                    owner => fun((pid()) -> non_neg_integer()),
                    name => atom(),
                    domain_line => boolean(),
                    driver := fun((Console :: pid()) -> {ok, pid(), Kind :: boolean() | relay}),
                    line_owners => fun(() -> {ok, [pid()]} | {error, term()}),
                    first_shell := first_shell() | shell() | fun((terminal()) -> shell()),
                    on_shell_end => on_shell_end(),
                    size => size(),
                    user => replace | take | none}.

%% A terminal's size as {Rows, Columns}, the order of POSIX's struct winsize and of
%% tty_size, each side 1 to console_side_max (abi/services/console.txt). Every erXos
%% module that holds a size holds this; only OTP's terminal code takes {Columns, Rows},
%% which otp_geometry/1 alone turns it into.
-type size() :: {Rows :: 1..?ERX_CONSOLE_SIDE_MAX, Columns :: 1..?ERX_CONSOLE_SIDE_MAX}.

-define(DEFAULT_SIZE, {24, 80}).
%% How long the console waits to ask again when the log service is not running.
-define(LOG_ASK_MS, 1000).
-define(ESC, 16#1B).

-record(state, {role :: system | session,
                first_shell :: first_shell() | shell(),
                %% The config's `on_shell_end`, and once the first shell has ended on a
                %% console that exits, the drain it waits on, with the ending Notify gets.
                on_shell_end = restart :: on_shell_end(),
                exiting = none :: none | {reference(), erx_prog:status()},
                driver :: pid(),
                %% The owners of the driver's shared lines, started before it: an owner's end is
                %% the driver's (docs/design-shared-devices.md, "Lines inside a domain").
                line_owners = [] :: [pid()],
                %% The group the console started with, which the others return the input to:
                %% the command shell's, or `user` with no shell.
                base :: pid(),
                %% The `user` group (start_user/1), which a console started with `user => none`
                %% lacks: the groups ask it the line's encoding (shell:prompt_width/1), and a session's
                %% domain, started with -nouser, has no other.
                user :: pid() | undefined,
                tty :: prim_tty:state(),
                size :: size(),
                terminal :: boolean(),
                %% The groups run_shell/1 started, innermost first, each with its caller
                %% to answer when it ends and the shell it runs. The innermost gets the
                %% input, or `base` when there are none (current/1).
                shells = [] :: [{pid(), gen_server:from(), shell()}],
                %% Whether the input has ended: each group that gets the input from then
                %% on is told so.
                input_ended = false :: boolean(),
                %% The system console as the log's console consumer (log_ask/0): asked
                %% for its next batch, writing one, or idle until it asks again; a
                %% session's console is none.
                log = none :: none | idle | writing | {asked, gen_server:request_id()},
                %% The input's escape state, which tells a typed Ctrl-G from the BEL that ends
                %% a terminal's string reply.
                keys = erx_console_keys:new() :: erx_console_keys:state(),
                %% Who has the line: the console's own groups, a domain's session, or the
                %% Ctrl-G menu, which knows who had the line before it.
                line = system :: erx_console_menu:owner() | {menu, erx_console_menu:menu()},
                %% The line's principal, whose sessions its menu lists: in a development
                %% build root, who is the system principal (docs/design-domains.md), as
                %% the domain service names it; unknown until the service has named it
                %% (line_principal/1, principal_and_start/3, {erx_console_principal, P}).
                principal = unknown :: pos_integer() | unknown,
                %% Whether a typed Ctrl-G opens the menu (config()).
                menu :: boolean(),
                %% The sessions whose tty the console is the master of, by domain id.
                sessions = #{} :: #{pos_integer() => session()},
                %% The line's login session (login/0): none, being started, or the domain
                %% of the one started, which takes the line once its tty names itself;
                %% connected once it has had the line, and only then started again when
                %% it ends.
                login = none :: none | starting | {started | connected, pos_integer()},
                %% The login's restarts after a timeout since its session last reported
                %% ready (login_timed_out/1).
                login_restarts = [] :: [erx_domain_core:restart()],
                %% The process behind every session's console facet (facet_endpoint/1).
                endpoint :: pid(),
                %% The domain a pid belongs to (config()).
                owner :: fun((pid()) -> non_neg_integer()),
                %% The console's reads of its terminal, made only for its groups' asks.
                reader :: reader(),
                %% Each group's outstanding ask for input.
                asks = #{} :: #{pid() => reference()}}).

%% Both consoles read on demand (docs/design-live.md, "Lost input"): a unit at a time,
%% a byte or a loss, and only for an ask of the current group, keeping for each group
%% the leading bytes of a character read for it whose other bytes have not been read.
%%
%% The console of a session's tty reads its relay as libedit reads a tty
%% (docs/design-shell.md, "The console reads on demand"): through its one open. It
%% keeps the relay and whether a watch of the open waits for its report. One watch or
%% one read is outstanding at most; a read is a call, so only the watch outlives a step.
%%
%% A console whose driver sends its input as it arrives reads a tty of its own, an
%% erx_tty in its process that holds what the driver sent and makes no output, with a
%% person's terminal's settings or a pipe's (own_termios/1). It keeps whether the line
%% is a pipe; the bytes of the driver's input message not yet in the tty, which a pipe's
%% hold back, or `answered` once all of the message is in and the driver is answered;
%% and whether the driver's input has ended, which the groups are told once nothing read
%% before the end waits.
-type reader() :: #{relay := pid(), open := erx_session_relay:open(), held := held(),
                    watching := boolean()}
                | #{tty := erx_tty:tty(), pipe := boolean(), unread := binary() | answered,
                    ending := boolean(), held := held()}.
-type held() :: #{pid() => binary()}.

%% A session: its tty, name, principal and domain pid with the pid's monitor, once
%% add_session/2 names them; the monitor of its console facet, once the facet has
%% forwarded a message; and the master's side of its tty.
-type session() :: #{tty := pid() | none, name := binary() | none, principal := pos_integer() | none,
                     domain := {pid(), reference()} | none, facet := reference() | none,
                     master := erx_tty_master:master()}.
%% What add_session/2 names of a session: its name, its principal and its domain pid
%% (erx_domain:pid/1). Its tty names itself, through its console facet.
-type session_spec() :: #{name := binary(), principal := pos_integer(), domain_pid := pid()}.

-doc """
Starts the system console, linked to the caller and registered as erx_console: its
supervisor (erx_console_sup) starts it this way at boot and again whenever it ends.
Returns once the console's `user` group is registered.
""".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE,
                     #{role => system, domain_line => true,
                       driver => fun(Console) -> (driver_module()):start_link(Console) end,
                       line_owners => fun() -> line_owners(driver_module()) end,
                       first_shell => first_shell(shell_arguments()),
                       user => replace}, []).

-doc """
Starts a console as Config says, linked to the caller and registered under Config's
name if it has one: each of a session's ttys starts its own this way, unregistered
(erx_session_tty).
""".
-spec start_link(config()) -> {ok, pid()} | {error, term()}.
start_link(Config = #{name := Name}) ->
    gen_server:start_link({local, Name}, ?MODULE, Config, []);
start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

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

-doc "run_shell/1 on Console, a console's pid or registered name.".
-spec run_shell(atom() | pid(), shell()) -> ok | {error, term()}.
run_shell(Console, Shell = {Module, Function, Args})
  when is_atom(Module), is_atom(Function), is_list(Args) ->
    gen_server:call(Console, {run_shell, Shell}, infinity).

-doc """
Writes Bytes to the console's line as they are, but for each newline, which goes out
as CR-LF as a cooked tty's ONLCR sends it, and returns once they are written: the
output of a command, which is bytes, never text the console renders.
""".
-spec write(iodata()) -> ok.
write(Bytes) ->
    write(?MODULE, Bytes).

-doc "write/1 on Console, a console's pid or registered name.".
-spec write(atom() | pid(), iodata()) -> ok.
write(Console, Bytes) ->
    gen_server:call(Console, {write, iolist_to_binary(Bytes)}, infinity).

-doc """
The terminal of this domain's line, as a shell holds it: the session's console tty in
a session's domain, the console in the system domain.
""".
-spec terminal() -> terminal().
terminal() ->
    terminal(persistent_term:get({?MODULE, line}, ?MODULE)).

-doc "The terminal of Console, a console's pid or registered name.".
-spec terminal(atom() | pid()) -> terminal().
terminal(Console) ->
    #{write => fun(Bytes) -> write(Console, Bytes) end,
      run_shell => fun(Shell) -> run_shell(Console, Shell) end}.

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
principal is its principal, and ends it when its domain pid ends. Spec names no tty:
every session's tty names itself, through its console facet ({tty_open, Tty}), which
the console checks is the domain's own.
""".
-spec add_session(pos_integer(), session_spec()) -> ok.
add_session(Domain, Spec = #{name := Name, principal := Principal, domain_pid := DomainPid})
  when is_integer(Domain), Domain > 0, is_binary(Name), is_integer(Principal), Principal > 0,
       is_pid(DomainPid) ->
    gen_server:call(?MODULE, {add_session, Domain, maps:with([name, principal, domain_pid], Spec)}).

-doc """
Boot step 4 (docs/design-system.md, "Boot"), once the domain service runs: the
console logs the line's principal in at the line, root at the UART in a development
build, which starts that principal's session (erx_domain:start_session/2). The session
takes the line once its tty names itself, and is started again whenever it ends; one
that does not report ready within the machine's boot timeout is started again within a
start row's default restart intensity; if it cannot start, the line stays with the system
shell after one line saying why.
""".
-spec login() -> ok.
login() ->
    gen_server:cast(?MODULE, login).

-doc """
The domain of the session login/0 started for the line's principal, root's in a
development build, from its start until its end; none before login/0 has started one,
while one is starting, and between its end and the start of the next.
""".
-spec login_session() -> {ok, pos_integer()} | none.
login_session() ->
    gen_server:call(?MODULE, login_session).

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

-doc """
The console's first group: the one it started with, or the fresh one that replaced it
when its shell ended. It is where input returns when no shell run by run_shell/1 is left.
""".
-spec first_group() -> pid().
first_group() ->
    gen_server:call(?MODULE, first_group).

-spec init(config()) -> {ok, #state{}}.
init(Config = #{role := Role, driver := Start, first_shell := First}) ->
    process_flag(trap_exit, true),
    %% A domain has one line, which terminal/0 names.
    [persistent_term:put({?MODULE, line}, self()) || maps:get(domain_line, Config, false)],
    Console = self(),
    {ok, LineOwners} = (maps:get(line_owners, Config, fun() -> {ok, []} end))(),
    {ok, DriverPid, Kind} = Start(self()),
    {Terminal, Relay} = case Kind of
                            %% A relay runs a line discipline for a person's
                            %% terminal, a window's or the console facet's.
                            relay when Role =:= session -> {true, DriverPid};
                            %% The system console ends the runtime at its line's end,
                            %% and a relay's line ends by a hangup, which only a
                            %% session's console ends at.
                            relay -> exit({bad_driver, "a system console's driver is never a terminal relay"});
                            _ when is_boolean(Kind) -> {Kind, none}
                        end,
    FirstShell = case First of
                     Make when is_function(Make, 1) -> Make(shell_terminal(Relay));
                     Given -> Given
                 end,
    %% As user_drv does for a line with no terminal on it: no editing, no echo and bytes
    %% as they are.
    Size = maps:get(size, Config, ?DEFAULT_SIZE),
    TTY = banner(Role, prim_tty:init_ssh(tty_options(Terminal), otp_geometry(Size), utf8), DriverPid),
    User = start_user(maps:get(user, Config, take)),
    Group = case FirstShell of
                none -> User;
                Shell -> start_shell(Shell, Terminal)
            end,
    {ok, gets_input(#state{role = Role,
                           log = case Role of
                                     system -> log_ask();
                                     session -> none
                                 end,
                           first_shell = FirstShell,
                           on_shell_end = on_shell_end(Config, Role, Kind),
                           driver = DriverPid,
                           line_owners = LineOwners,
                           base = Group,
                           user = User,
                           tty = TTY,
                           size = Size,
                           terminal = Terminal,
                           menu = Terminal andalso maps:get(menu, Config, Role =:= system),
                           principal = line_principal(Config),
                           owner = maps:get(owner, Config, fun erx:owner/1),
                           endpoint = spawn(fun() -> facet_endpoint(Console) end),
                           reader = reader(Relay, Terminal)})}.

%% The terminal the console's first shell holds: on a tty a terminal relay drives, it
%% also tells that relay which job holds the terminal.
shell_terminal(none) ->
    terminal(self());
shell_terminal(Relay) ->
    (terminal(self()))#{foreground => fun(Target, Signals) -> relay_foreground(Relay, Target, Signals) end}.

relay_foreground(Relay, console, Signals) -> erx_session_relay:foreground(Relay, console, Signals);
relay_foreground(Relay, {Tag, Mode}, Signals) -> erx_session_relay:foreground(Relay, Tag, Mode, Signals).

%% The console's reader (reader()): of a tty a terminal relay drives, which the driver
%% function has just started, where the console makes its one open, or of a tty of the
%% console's own, set for a person's terminal or for a pipe as Terminal says.
reader(none, Terminal) ->
    {ok, _NoWaiter, Tty} = erx_tty:set(own_termios(Terminal), erx_tty:new()),
    #{tty => Tty, pipe => not Terminal, unread => answered, ending => false, held => #{}};
reader(Relay, true) ->
    {ok, Open} = erx_session_relay:open_reader(Relay, console),
    #{relay => Relay, open => Open, held => #{}, watching => false}.

%% The settings of the console's own tty (docs/design-live.md, "Lost input"). A person's
%% terminal gets a session prompt's, less IXON and IMAXBEL, since the console's output
%% does not pass through this tty: ISIG makes Ctrl-C, Ctrl-Z and Ctrl-\ signals as they
%% arrive, and ICRNL reads CR as LF. A pipe gets every flag clear, so its bytes reach the
%% group as it gave them.
own_termios(true) ->
    Editing = #{iflag := Input} = erx_tty_modes:editing(erx_tty:termios(erx_tty:new())),
    Editing#{iflag := Input -- [ixon, imaxbel]};
own_termios(false) ->
    (erx_tty:termios(erx_tty:new()))#{iflag := [], oflag := [], lflag := []}.

%% The line's principal as the console starts: the one Config names, as a host test's
%% does, or unknown. The system domain's line takes the system principal from the domain
%% service, its one owner, when it first starts a session (started/3), since the console
%% starts before the service; a session's line has none.
line_principal(#{principal := Principal}) when is_integer(Principal), Principal > 0 ->
    Principal;
line_principal(_Config) ->
    unknown.

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
What the console does with an exit of its first group for Reason, given its
`on_shell_end`, whether it already waits on a drain, and whether its input has ended.
A console that exits waits, at the group's first exit, for the relay's master to take
the last output and then reports the ending that exit carries (shell_ending/1); the
group's own exit after it changes nothing. A console that restarts starts a fresh
command shell while input may still come, whatever the reason; once none can, it ends
the runtime, with status 0 if the shell ended normally, as stock's shell halts at the
end of its input, and 1 if not.
""".
-spec shell_end(on_shell_end(), Draining :: boolean(), Reason :: term(), InputEnded :: boolean()) ->
          shell_end().
shell_end({exit, _Notify}, false, Reason, _InputEnded) -> {drain, shell_ending(Reason)};
shell_end({exit, _Notify}, true, _Reason, _InputEnded) -> ignore;
shell_end(restart, _Draining, _Reason, false) -> restart;
shell_end(restart, _Draining, normal, true) -> {halt, 0};
%% The command shell's end with a status (erx_shell) is a normal end too.
shell_end(restart, _Draining, {shutdown, {exited, _Status}}, true) -> {halt, 0};
shell_end(restart, _Draining, _Reason, true) -> {halt, 1}.

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

%% The `user` group: with none registered, one started and registered as user_drv's
%% start_user/0 does; with one registered, what Mode, the config's `user` (config()),
%% says. Under `replace` a registered `user` is the predecessor's, which ends with its
%% console as a group ends at its driver's exit but may not have taken that exit yet: it
%% is killed and its end awaited, which frees the name. Under `none` there is no `user`
%% group of the console's own.
start_user(none) ->
    undefined;
start_user(Mode) ->
    case {Mode, whereis(user)} of
        {_, undefined} ->
            group:start(self(), noshell, [{name, user}]);
        {replace, Old} ->
            ok = await_kill(Old),
            group:start(self(), noshell, [{name, user}]);
        {take, User} ->
            User
    end.

%% Kills Pid and returns once it has ended; its registered name is free by then.
await_kill(Pid) ->
    Monitor = monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    end.

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
handle_call(first_group, _From, State = #state{base = Base}) ->
    {reply, Base, State};
handle_call({write, Bytes}, From, State = #state{driver = Driver}) ->
    Driver ! {erx_console_output, {caller, From}, onlcr(Bytes)},
    {noreply, State};
handle_call(login_session, _From, State = #state{login = {_Phase, Domain}}) ->
    {reply, {ok, Domain}, State};
handle_call(login_session, _From, State) ->
    {reply, none, State};
handle_call(facet, _From, State = #state{endpoint = Endpoint}) ->
    {reply, console_facet(Endpoint), State};
handle_call({add_session, Domain, Spec}, _From, State) ->
    {reply, ok, named(Domain, Spec, State)};
handle_call({connect, Domain}, _From, State) ->
    {Reply, Next} = connect_session(Domain, State),
    {reply, Reply, Next};
handle_call(detach, _From, State) ->
    {reply, ok, to_groups(none, State)};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(login, State = #state{role = system}) ->
    {noreply, start_login(State)};
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}} | {stop, term(), #state{}}.
handle_info(Message, State = #state{log = {asked, Request}}) ->
    %% The log service's answer, or its end, comes first: its DOWN is no session's.
    case gen_server:check_response(Message, Request) of
        {reply, Lines} when is_list(Lines) ->
            {noreply, log_batch(Lines, State)};
        Ended when element(1, Ended) =:= error; Ended =:= {reply, {error, busy}} ->
            %% The service ended or is not running yet, or still holds the request of
            %% a console that has just ended: ask again then.
            erlang:send_after(?LOG_ASK_MS, self(), erx_console_log_ask),
            {noreply, State#state{log = idle}};
        no_reply ->
            info(Message, State)
    end;
handle_info(Message, State) ->
    info(Message, State).

info({erx_console_input, Bytes}, State = #state{reader = #{unread := _}}) when is_binary(Bytes) ->
    %% A driver keeps one input message outstanding until its answer (docs/design-live.md,
    %% "Lost input"), which serve/1 sends once all of the message is in the tty.
    {noreply, serve(typed(Bytes, unanswered(State)))};
info(erx_console_lost, State = #state{reader = #{unread := _}}) ->
    {noreply, serve(driver_lost(unanswered(State)))};
info(erx_console_eof, State = #state{role = session}) ->
    hang_up(State);
info(erx_console_eof, State = #state{reader = Reader = #{ending := false}}) ->
    %% The groups are told once nothing read before the end waits (serve/1).
    {noreply, serve(State#state{reader = Reader#{ending := true}})};
info({ready, Open, [in], N}, State = #state{reader = Reader = #{open := Open}}) ->
    read_for_ask(N, State#state{reader = Reader#{watching := false}});
info({erx_tty_event, Group, Event}, State = #state{reader = #{relay := _}}) ->
    {noreply, tty_event(Group, Event, State)};
info({erx_console_size, Rows, Columns}, State = #state{tty = TTY, size = Held})
  when is_integer(Rows), is_integer(Columns),
       Rows >= 1, Rows =< ?ERX_CONSOLE_SIDE_MAX, Columns >= 1, Columns =< ?ERX_CONSOLE_SIDE_MAX ->
    Size = {Rows, Columns},
    {Width, Height} = otp_geometry(Size),
    State1 = State#state{tty = prim_tty:update_geometry(TTY, Width, Height), size = Size},
    %% Only a size that differs from the one held is a change, so a repeated
    %% report sends the shell nothing (docs/design-shell.md, "Window size"); a line
    %% handed to a session passes the size on to it instead.
    [resized(State1) || Size =/= Held, State1#state.line =:= system],
    {noreply, session_size(State1)};
info({erx_console_size, _Rows, _Columns}, State) ->
    {noreply, State};
info(erx_console_log_ask, State = #state{log = idle}) ->
    {noreply, State#state{log = log_ask()}};
info({erx_console_written, log_batch}, State = #state{log = writing}) ->
    %% The batch is on the line: only now is the next one asked for.
    {noreply, State#state{log = log_ask()}};
info({erx_console_written, none}, State) ->
    {noreply, State};
info({erx_console_written, {tty, Domain, N}}, State = #state{sessions = Sessions}) ->
    %% Output N of Domain's tty is on the line: only now is it taken.
    case Sessions of
        #{Domain := #{master := Master}} -> {noreply, carry_out(Domain, erx_tty_master:written(N, Master), State)};
        #{} -> {noreply, State}
    end;
info({erx_tty_message, {Facet, _Tag} = From, Domain, Message}, State) ->
    %% A message of Domain's tty, which its console facet admitted and forwarded through
    %% the endpoint. It is answered once acted on, so the facet's limit in flight bounds
    %% what the session has queued here; the facet drops the answer.
    Next = from_tty(Domain, Facet, Message, State),
    gen:reply(From, ok),
    {noreply, Next};
info({'DOWN', Monitor, process, _Pid, Reason}, State = #state{sessions = Sessions}) ->
    %% A session's domain pid or its console facet, which ends with its domain, has ended:
    %% so has the session.
    case [Domain || Domain := Session <- Sessions, lists:member(Monitor, monitors(Session))] of
        [Domain] -> {noreply, session_ended(Domain, Reason, State)};
        [] -> {noreply, State}
    end;
info({erx_console_principal, Principal}, State = #state{principal = unknown}) ->
    %% The system principal, as the domain service names it, which is fixed for the
    %% system domain's life; a line keeps the first it hears.
    {noreply, State#state{principal = Principal}};
info({erx_console_principal, _Principal}, State) ->
    {noreply, State};
info({erx_console_started, Why, Principal, Started}, State) ->
    {noreply, session_started(Why, Principal, Started, State)};
info({erx_console_written, {caller, From}}, State) ->
    gen_server:reply(From, ok),
    {noreply, State};
info({erx_console_written, {Group, Reply}}, State) ->
    Group ! {reply, Reply, ok},
    {noreply, State};
info({Ref, ok}, State = #state{exiting = {Ref, Ending}, on_shell_end = {exit, Notify}}) ->
    Notify(Ending),
    {stop, normal, State};
info({'EXIT', User, Reason}, State = #state{user = User}) ->
    %% `user` ends only with its console or as the runtime stops (user_sup kills the
    %% system console's supervisor, and the console with it).
    {stop, Reason, State};
info({'EXIT', Pid, Reason},
            State = #state{role = Role, driver = Driver, line_owners = LineOwners, base = Base, shells = Shells,
                           first_shell = FirstShell, terminal = Terminal, input_ended = Ended,
                           on_shell_end = OnEnd, exiting = Exiting}) ->
    LineEnded = Pid =:= Driver orelse lists:member(Pid, LineOwners),
    case lists:keytake(Pid, 1, Shells) of
        {value, {Pid, Caller, _Shell}, Others} ->
            %% A shell run_shell/1 started has ended, and its group with it, in whatever
            %% order: its caller gets how it ended, which the group's first exit carries
            %% from its shell, and the input goes to the innermost group left. The group's
            %% own exit, which follows, names a group the console no longer holds.
            gen_server:reply(Caller, shell_ended(Reason)),
            {noreply, gets_input(State#state{shells = Others})};
        false when Pid =:= Base ->
            %% The first group's shell has ended, and the group with it. A fresh group
            %% takes its place, and the old group's own exit, which follows, names a group
            %% the console no longer holds; or a tty that exits with its shell sends its
            %% ending once the relay's master has taken every byte the shell wrote (the
            %% relay's drain), and the group's first exit carries how it ended.
            case shell_end(OnEnd, Exiting =/= none, Reason, Ended) of
                {drain, Ending} ->
                    Ref = make_ref(),
                    Driver ! {tty_drain, self(), Ref},
                    {noreply, State#state{exiting = {Ref, Ending}}};
                ignore ->
                    {noreply, State};
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
        false when LineEnded, Role =:= session ->
            {stop, Reason, State};
        false when LineEnded ->
            %% Nothing would read the terminal again, and its keys no longer signal: end
            %% the runtime, whose exit restores the terminal.
            ended_by(Reason),
            erlang:halt(1),
            {stop, Reason, State};
        false ->
            {noreply, State}
    end;
info(Message, State = #state{user = User, line = Line})
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
info(_Message, State) ->
    {noreply, State}.

%% A session tty's `on_shell_end`, which only a relay's console may make
%% `{exit, Notify}`, since only a relay answers the drain it waits on.
on_shell_end(Config, Role, Kind) ->
    case maps:get(on_shell_end, Config, restart) of
        restart -> restart;
        {exit, Notify} = Exit when Role =:= session, Kind =:= relay, is_function(Notify, 1) -> Exit
    end.

-doc """
How a shell that ended for Reason ended, as a tty's master hears it: with the
status the command shell's end carries (erx_shell:exit_with/1), or by the
signal an exec's end carries when Ctrl-C ended it (erx_shell_script:command/3),
one of the signal set tty_master of abi/signals.txt, the signals a tty's master
hears; with status 0 for a normal end, and 1 for any other, as for a shell
that crashed or was killed or a signal the set does not list. So every ending
a tty reports has the shape its master hears, and the session's line passes it
on unchecked (erx_tty_line_core:report/2).
""".
-spec shell_ending(term()) -> erx_prog:status().
shell_ending(normal) -> {exited, 0};
shell_ending({shutdown, {exited, Status}}) when is_integer(Status), Status >= 0, Status =< 255 ->
    {exited, Status};
shell_ending({shutdown, {signaled, Signal}}) when is_atom(Signal) ->
    case lists:keymember(Signal, 1, ?ERX_TTY_MASTER_SIGNAL_MEMBERS) of
        true -> {signaled, Signal};
        false -> {exited, 1}
    end;
shell_ending(_Reason) -> {exited, 1}.

ended_by(Reason) ->
    erlang:display_string(stderr, lists:flatten(io_lib:format("erx_console: ended by ~p\r\n", [Reason]))).

%% The console's groups: `user`, the one it started with, and each one run_shell/1
%% started.
groups(#state{user = User, base = Base, shells = Shells}) ->
    [User, Base | [Group || {Group, _Caller, _Shell} <- Shells]].

%% Whether Pid is one of the console's groups.
is_group(Pid, State) ->
    lists:member(Pid, groups(State)).

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
    follow_current(Group, State).

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
from_group({Pid, read, Ref}, State = #state{asks = Asks}) when is_reference(Ref) ->
    next_read(State#state{asks = Asks#{Pid => Ref}});
from_group({_Pid, read, _Ask}, State) ->
    State;
from_group({Pid, Request}, State) ->
    group_request(Request, Pid, State);
from_group(_Message, State) ->
    State.

%% The owners of the shared lines of the system console's driver, linked to the console.
line_owners(Module) ->
    erx_irq_line:start_owners([{Module, Module:console_records()}]).

%% The driver's module, from the records the boot information page carries. A record that
%% names no driver stops the console with console_driver/1's reason.
driver_module() ->
    case console_driver(erx_device_record:records()) of
        {ok, Module} -> Module;
        {error, Reason} -> exit(Reason)
    end.

-doc """
The system console's driver among boot records as erx_device_record:records/0 returns
them: the driver of the peripheral the one `-erx_record console PERIPHERAL` names, which
the root writes for the console's UART and the hosted entry for its standard I/O. Words
after the peripheral are the driver's to read. A peripheral that no driver drives is
refused, and no word becomes an atom. Pure, for its tests.
""".
-spec console_driver([[string()]]) -> {ok, module()} | {error, {atom(), string()}}.
console_driver(Records) ->
    case [Peripheral || ["console", Peripheral | _] <- Records] of
        [Peripheral] -> driver(Peripheral);
        [] -> {error, {no_console, "the boot gave no -erx_record console"}};
        [_, _ | _] -> {error, {bad_console, "more than one -erx_record console"}}
    end.

%% The console's driver of each peripheral a console record may name: each row of
%% erx/device_kinds.h's erx_uart_kinds, and the hosted entry's stdio, which
%% test/host/erx_console_shell_test.rb checks these clauses cover.
driver("pl011") -> {ok, erx_pl011};
driver("mini_uart") -> {ok, erx_mini_uart};
driver("stdio") -> {ok, erx_stdio};
driver(_Peripheral) -> {error, {bad_console, "-erx_record console names a peripheral no console driver drives"}}.

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
    #{Domain := Session = #{master := Master}} = State#state.sessions,
    case Message of
        {tty_open, Tty} -> tty_opened(Domain, Tty, Session, State);
        _ -> carry_out(Domain, erx_tty_master:output(Message, Master), State)
    end.

%% The tty of Domain's session names itself through its console facet, which says the
%% message is Domain's (docs/design-live.md, "Between domains"): the first names it, if
%% it is a process of Domain's own; the same again is nothing, since the tty sends it
%% with each resend, and any other fails the master's check, as any message it does not
%% know does. A session the menu then lists is drawn in it, and the login's session takes
%% the line (take_login_line/2).
tty_opened(Domain, Tty, #{tty := none}, State = #state{owner = Owner}) when is_pid(Tty) ->
    case Owner(Tty) of
        Domain ->
            Named = with_session(Domain, fun(Session) -> Session#{tty := Tty} end, State),
            take_login_line(Domain, redraw_if_listed(Domain, Named));
        _Other -> tty_refused(Domain, Tty, State)
    end;
tty_opened(_Domain, Tty, #{tty := Tty}, State) ->
    State;
tty_opened(Domain, Tty, _Session, State) ->
    tty_refused(Domain, Tty, State).

tty_refused(Domain, Tty, State = #state{sessions = Sessions}) ->
    #{Domain := #{master := Master}} = Sessions,
    carry_out(Domain, erx_tty_master:output({tty_open, Tty}, Master), State).

%% Domain's session named by Spec (session_spec()), its domain pid watched from now on.
named(Domain, #{name := Name, principal := Principal, domain_pid := Pid}, State) ->
    Named = fun(Session = #{domain := Old}) ->
                    [demonitor(Monitor, [flush]) || {_Pid, Monitor} <- [Old]],
                    Session#{name := Name, principal := Principal, domain := {Pid, monitor(process, Pid)}}
            end,
    with_session(Domain, Named, State).

%% The menu drawn again when it has the line and Domain's session, now live, is one it
%% lists: one of the line's principal.
redraw_if_listed(Domain, State = #state{line = {menu, Menu}, principal = Principal, sessions = Sessions}) ->
    case Sessions of
        #{Domain := Session = #{principal := Principal}} ->
            case is_live(Session) of
                true -> open_menu(none, erx_console_menu:back(Menu), State);
                false -> State
            end;
        #{} ->
            State
    end;
redraw_if_listed(_Domain, State) ->
    State.

%% A loss the driver placed among its bytes: the escape state goes with it, and the loss
%% goes where the bytes would have gone: to the session that has the line, into the
%% console's own tty after the bytes sent before it, or, while the menu has the line,
%% nowhere, since the menu runs no line. The start of a character it fell among goes when
%% a group reads the loss (damage/2).
driver_lost(State0 = #state{line = Line, sessions = Sessions, keys = Keys}) ->
    State = State0#state{keys = erx_console_keys:lost(Keys)},
    case Line of
        {session, Domain} ->
            #{Domain := #{master := Master}} = Sessions,
            carry_out(Domain, erx_tty_master:lost(Master), State);
        {menu, _Menu} ->
            State;
        system ->
            own_lost(State)
    end.

%% Bytes typed at the line, for Domain's session, which has it.
to_session(Domain, Bytes, State = #state{sessions = Sessions}) ->
    #{Domain := #{master := Master}} = Sessions,
    carry_out(Domain, erx_tty_master:input(Bytes, Master), State).

%% The line's size, for the session that has the line.
session_size(State = #state{line = {session, Domain}, size = Size, sessions = Sessions}) ->
    #{Domain := #{master := Master}} = Sessions,
    carry_out(Domain, erx_tty_master:size(Size, Master), State);
session_size(State) ->
    State.

%% Domain's session takes the line from whoever had it, unless it is unnamed, down or
%% refused.
connect_session(Domain, State0 = #state{sessions = Sessions}) ->
    case Sessions of
        #{Domain := Session = #{tty := Tty, master := Master}} ->
            %% A tty that failed a check is refused, whether or not it named itself first.
            case {erx_tty_master:is_refused(Master), Tty, is_live(Session)} of
                {true, _, _} ->
                    {{error, refused}, State0};
                {false, none, _} ->
                    {{error, no_tty}, State0};
                {false, _, false} ->
                    {{error, unknown}, State0};
                {false, _, true} ->
                    %% Whatever the line's last holder left, a string open, its text
                    %% hidden or the system shell's prompt, ends before the session's
                    %% held output, which starts on a line of its own.
                    ok = new_line(none, State0),
                    State = login_connected(Domain, (release(State0))#state{line = {session, Domain}}),
                    #state{size = Size, sessions = #{Domain := #{master := Disconnected}}} = State,
                    {ok, carry_out(Domain, erx_tty_master:connect(Size, Disconnected), State)}
            end;
        #{} ->
            {{error, unknown}, State0}
    end.

%% State with the login's session marked as one that has had the line, if Domain's is it.
login_connected(Domain, State = #state{login = {started, Domain}}) -> State#state{login = {connected, Domain}};
login_connected(_Domain, State) -> State.

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

%% Ends whatever a session or a command left on the line, a string open or its text
%% hidden, and starts a new line, with Notice on it if there is one.
new_line(Notice, #state{driver = Driver}) ->
    Line = [[erx_text:escape_line(Notice), <<"\r\n">>] || Notice =/= none],
    Driver ! {erx_console_output, none, [<<"\e\\\e[0m\r\n">>, Line]},
    ok.

%% Domain's session has ended, for Reason: its domain pid or its console facet has. If it
%% had the line, the line goes back to the groups after one line saying how, and if the
%% menu has the line and shows it, the menu is drawn again without it, after that line; a
%% session the menu does not show, another principal's, is not named on this line. The
%% login's session is started again (start_login/1), which takes the line when it is up,
%% if it ever had the line; one that never had it, which ended as it came up, is not
%% started again, so a session that ends as it comes up does not loop (one that times
%% out is restarted within an intensity instead, login_timed_out/1), and the line stays
%% with the system shell after the same one line (login_ended/2).
session_ended(Domain, Reason, State0 = #state{line = Line, sessions = Sessions}) ->
    Principal = maps:get(principal, maps:get(Domain, Sessions)),
    State = State0#state{sessions = maps:remove(Domain, Sessions)},
    Notice = [session_label(Domain, maps:get(Domain, Sessions)), <<" ended: ">>, how_ended(Reason)],
    Shown = case Line of
                {session, Domain} -> to_groups(Notice, State);
                {menu, Menu} ->
                    %% A session of the line's principal may be one the menu only counts.
                    case erx_console_menu:shows(Domain, Menu) orelse Principal =:= State#state.principal of
                        true -> open_menu(Notice, erx_console_menu:back(Menu), State);
                        false -> State
                    end;
                _ -> State
            end,
    case Shown of
        #state{login = {connected, Domain}} -> start_login(Shown);
        #state{login = {started, Domain}} -> login_ended(Notice, Shown);
        #state{} -> Shown
    end.

%% The login's session ended before it ever had the line: the line stays with whoever has
%% it, and the system shell, if that is who, prompts again after Notice.
login_ended(Notice, State = #state{line = system}) ->
    ok = new_line(Notice, State),
    current(State) ! {self(), activate},
    State#state{login = none};
login_ended(_Notice, State) ->
    State#state{login = none}.

%% How a notice names Domain's session: by the name add_session/2 gave it, attributed text
%% that the line escape later makes safe to show, or by its domain id.
session_label(Domain, #{name := none}) ->
    [<<"the session of domain ">>, integer_to_binary(Domain)];
session_label(_Domain, #{name := Name}) ->
    [<<"session ">>, Name].

%% How a session's domain ended, as its domain pid's end says: {domain_down, Id, Info}'s
%% Info ({halt, Status}, crash, {fault, Kind} or stopped), or the pid's own exit reason,
%% killed by a kill. Info is one of those four shapes, cut at a depth all the same; any
%% other reason is the system domain's own state, which the line names only by its
%% atom and the kernel log records whole.
how_ended({domain_down, _Domain, Info}) -> io_lib:format("~0P", [Info, 8]);
how_ended(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
how_ended(Reason) ->
    logger:notice("erx_console: a session's domain pid ended: ~0P", [Reason, 16]),
    <<"an error in the system domain">>.

%% -- The Ctrl-G menu ------------------------------------------------------------------

%% The bytes a driver read, to the menu while it has the line, else split by
%% erx_console_keys where the console runs the menu. A raw driver's console with no menu
%% reads a BEL as a raw tty does: as a byte. A relay's console gets no input this way; it
%% reads its relay (reader()).
typed(Bytes, State = #state{keys = Keys, line = {menu, Menu}}) ->
    {Action, Next} = erx_console_menu:key(Bytes, Keys, Menu),
    menu_action(Action, Menu, State#state{keys = Next});
typed(Bytes, State = #state{menu = true, keys = Keys}) ->
    {Pieces, Next} = erx_console_keys:split(Bytes, Keys),
    read(Pieces, State#state{keys = Next});
typed(Bytes, State) ->
    read([Bytes], State).

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
read([Bytes | Rest], State = #state{reader = Reader = #{unread := Unread}}) ->
    %% For the console's own tty, which serve/1 fills.
    read(Rest, State#state{reader = Reader#{unread := <<Unread/binary, Bytes/binary>>}}).

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
menu_action(start, Menu, State) ->
    ok = start_session(menu, State),
    open_menu(<<"erx_console: starting a session">>, erx_console_menu:back(Menu), State).

%% Starts a session of the line's principal at this line, for the boot's login and the
%% menu's "start a session", with the line's console facet as its console. Creating a
%% domain takes seconds, so a helper asks the domain service and the console hears
%% {erx_console_started, Why, Principal, Started}, Principal the line's and Started the
%% service's answer, once the session has reported ready with its namespace in place, or
%% the start is refused (session_started/4; docs/design-system.md, "A session takes the
%% console"). The helper never calls the console, which is not waiting for it, so it may
%% call the domain service, which calls the console (add_session/2).
start_session(Why, #state{role = Role, principal = Principal, endpoint = Endpoint}) ->
    Console = self(),
    ConsoleFacet = console_facet(Endpoint),
    _ = spawn(fun() ->
                      {Named, Started} = principal_and_start(Role, Principal, Console, ConsoleFacet),
                      Console ! {erx_console_started, Why, Named, Started}
              end),
    ok.

%% The line's principal and the domain service's answer to a start of its session. The
%% system domain's line asks the service for the system principal while it has none
%% (erx_domain:system_principal/0) and tells the console at once, so the system domain's
%% log records name it while the session boots ({erx_console_principal, P}); a session's
%% line with none starts nothing.
principal_and_start(system, unknown, Console, ConsoleFacet) ->
    case ask_service(fun erx_domain:system_principal/0) of
        {ok, System} ->
            Console ! {erx_console_principal, System},
            principal_and_start(system, System, Console, ConsoleFacet);
        {error, _} = Refused ->
            {unknown, Refused}
    end;
principal_and_start(session, unknown, _Console, _ConsoleFacet) ->
    {unknown, {error, enotsup}};
principal_and_start(_Role, Principal, _Console, ConsoleFacet) ->
    {Principal, ask_service(fun() -> erx_domain:start_session(Principal, #{console => ConsoleFacet}) end)}.

%% A call of the domain service's; a runtime with no domain service, or none loaded, as a
%% hosted one, answers enotsup.
ask_service(Call) ->
    try
        Call()
    catch
        exit:{noproc, _} -> {error, enotsup};
        error:undef -> {error, enotsup};
        %% The service ended during the call: the start failed, which the menu or the
        %% login's line shows.
        exit:Reason -> {error, Reason}
    end.

%% A session the console started, named by its domain (add_session/2), and the menu drawn
%% again if it lists it; the login's session also takes the line if its tty has named
%% itself by now (take_login_line/2), and otherwise once it does. A session whose domain
%% pid has ended by now leaves nothing to show, and a login's is a start that failed. A
%% refusal is a start that failed (start_failed/3), but a login's timeout starts it
%% again within an intensity (login_timed_out/1), whose count of timeouts in a row a
%% login session that reported ready ends. A login at a line whose principal has no
%% session template (no_template), or in a runtime with no domain service or library
%% (enotsup), starts nothing and says nothing.
session_started(Why, Principal, {ok, Domain}, State) ->
    Id = erx_domain:id(Domain),
    [Name | _] = binary:split(atom_to_binary(erx_domain:node(Domain)), <<"@">>),
    Pid = erx_domain:pid(Domain),
    case {is_process_alive(Pid), Why} of
        {true, login} ->
            Named = named(Id, #{name => Name, principal => Principal, domain_pid => Pid}, State),
            Ready = Named#state{login = {started, Id}, login_restarts = []},
            take_login_line(Id, redraw_if_listed(Id, Ready));
        {true, menu} ->
            redraw_if_listed(Id, named(Id, #{name => Name, principal => Principal, domain_pid => Pid}, State));
        {false, login} ->
            start_failed(login, ended, State);
        {false, menu} ->
            State
    end;
session_started(login, _Principal, {error, Quiet}, State) when Quiet =:= no_template; Quiet =:= enotsup ->
    State#state{login = none};
session_started(login, _Principal, {error, timeout}, State) ->
    login_timed_out(State);
session_started(Why, _Principal, {error, Reason}, State) ->
    start_failed(Why, Reason, State).

%% The login's session did not report ready within the machine's boot timeout, as on
%% a machine merely slower than its manifest allows for: it is started again, as the
%% domain service restarts a configured domain, within a start row's default intensity
%% (abi/manifest.txt, start_restarts_default), which counts restarts after a timeout
%% until a login session reports ready, as for a configured row
%% (erx_domain_core:intensity/4), so a login that hangs every time is given up after
%% that many restarts in a row, whatever the boot timeout; each start is bounded by the
%% timeout, and past the intensity the start has failed as any other does. The login
%% counts only timeouts, so the intensity's period, which ages other restarts, never
%% applies to it.
login_timed_out(State = #state{login_restarts = Earlier}) ->
    Intensity = #{restarts => ?ERX_START_RESTARTS_DEFAULT, period_s => ?ERX_START_PERIOD_DEFAULT_S},
    case erx_domain_core:intensity(Earlier, Intensity, timed_out, erlang:monotonic_time(second)) of
        {yes, Kept} ->
            logger:notice("erx_console: the login session did not start in time; starting it again"),
            start_login(State#state{login_restarts = Kept});
        {no, Kept} ->
            start_failed(login, timeout, State#state{login_restarts = Kept})
    end.

%% A start that failed, for Reason. A login's leaves the line with the system shell, after
%% one line saying why if the shell has the line, so the line is never left without a
%% prompt; the menu shows any refusal if it has the line, and the log reports it otherwise.
start_failed(login, Reason, State = #state{line = system}) ->
    ok = new_line(io_lib:format("erx_console: the login session did not start: ~0P", [Reason, 8]), State),
    current(State) ! {self(), activate},
    State#state{login = none};
start_failed(Why, Reason, State0) ->
    State = case Why of
                login -> State0#state{login = none};
                menu -> State0
            end,
    case State of
        #state{line = {menu, Menu}} ->
            Notice = io_lib:format("erx_console: cannot start a session: ~0P", [Reason, 8]),
            open_menu(Notice, erx_console_menu:back(Menu), State);
        #state{} ->
            logger:notice("erx_console: a session did not start: ~0P", [Reason, 8]),
            State
    end.

%% The console's login (login/0): root's session started at this line, the line's
%% principal's in general (docs/design-system.md, "Boot", step 4).
start_login(State) ->
    ok = start_session(login, State),
    State#state{login = starting}.

%% The line given to Domain's session if it is the login's and the console's own groups
%% have the line: a person who has opened the menu or connected another session keeps it.
%% A session whose tty has not named itself yet takes the line when it does.
take_login_line(Domain, State = #state{login = {started, Domain}, line = system}) ->
    case connect_session(Domain, State) of
        {ok, Next} -> Next;
        {{error, _Reason}, Same} -> Same
    end;
take_login_line(_Domain, State) ->
    State.

%% What a session's create spec names as its console: this console's endpoint, with the
%% largest message a tty sends as the facet's max_request.
console_facet(Endpoint) ->
    {Endpoint, #{max_request => erx_tty_master:max_message()}}.

bell(#state{driver = Driver, tty = TTY}) ->
    {Bytes, _} = prim_tty:handle_request(TTY, beep),
    Driver ! {erx_console_output, none, Bytes},
    ok.

%% Domain's master after Actions, which it carries out in order: a write goes to the driver,
%% which says when it is written; a message goes to the session's tty; a loss logs a line
%% naming the session's domain and the output, by number only, since the line may be
%% another principal's; and a detach, for a tty that failed a check, takes the line from it,
%% if it has it, and logs a line naming the domain under the system domain's own source.
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
carry_out_one(Domain, _Tty, {lost, N}, State) ->
    logger:notice("erx_console: output ~b of domain ~b's tty was lost on its way to the console", [N, Domain]),
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

-doc """
Byte, read for a group, after Held, the leading bytes of a character read for it before:
the text they complete, as UTF-8, and the bytes still waiting for the rest of a
character. A byte that is not part of a character reads as latin-1, as prim_tty's reader
does for stock's terminal. Pure, for its fuzz target.
""".
-spec chars(Held :: binary(), Byte :: byte()) -> {Chars :: binary(), Left :: binary()}.
chars(Held, Byte) ->
    {Pieces, Left} = text(<<Held/binary, Byte>>),
    {<< <<Utf8/binary>> || {data, Utf8} <- Pieces >>, Left}.

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

%% The current group changed to Group, or may have: what the console kept for a group
%% that has ended, its ask and the bytes held for it, is forgotten; a relay is told
%% Group, so the events made from now on carry it; and Group's ask, if it has one, is
%% read for.
follow_current(Group, State = #state{asks = Asks, reader = Reader = #{held := Held}}) ->
    Live = groups(State),
    State1 = State#state{asks = maps:with(Live, Asks), reader = Reader#{held := maps:with(Live, Held)}},
    [ok = erx_session_relay:console_group(Relay, Group) || #{relay := Relay} <- [Reader]],
    next_read(State1).

%% A read for the current group's ask, if it has one, from whichever tty the console
%% reads.
next_read(State = #state{reader = #{relay := _}}) -> watch(State);
next_read(State = #state{reader = #{tty := _}}) -> serve(State).

%% What the relay tells the console of a key or a flush on its tty, made while Group was
%% the current group, or `none`. Each event is handled by name, and the console's own tty
%% makes the same events through the relay core's mapping (own_action/2).
tty_event(Group, Event, State) when Event =:= interrupt; Event =:= suspend; Event =:= quit ->
    %% A signal flushed the tty's input typed with it, so the bytes held for Group go,
    %% and Group's ask stays outstanding. Only a group of this console's is acted on.
    State1 = drop_held(Group, State),
    [signal(Event, Group, State1) || is_pid(Group), is_group(Group, State1)],
    State1;
tty_event(Group, lost, State) ->
    %% A loss the flush of a signal dropped, told ahead of that signal: it damages the
    %% read the signal leaves going (docs/design-live.md, "Lost input").
    damage(Group, State);
tty_event(_Group, winch, State) ->
    %% A size change comes with the size report, which carries it to the current group.
    State;
tty_event(_Group, info, State) ->
    %% VSTATUS at the prompt writes nothing: no job runs.
    State;
tty_event(_Group, Event, State) ->
    %% An event this console has no clause for is logged, so a new event name is seen
    %% rather than dropped unnoticed.
    logger:notice("erx_console: an erx_tty event it has no clause for: ~0P", [Event, 8]),
    State.

%% The relay's reads, for the console of a session's tty.

%% A watch for one unit of input, made only when none waits for its report and the
%% current group has an ask outstanding. It is an `in` watch, which erx_tty reports
%% once a unit waits (a complete line when ICANON is set) whatever VMIN and VTIME
%% are, so a program that leaves VMIN 0 makes no report of nothing; it is ready at once
%% only on a hangup, which ends a session's console (erx_console_eof).
watch(State = #state{asks = Asks, reader = Reader = #{open := Open, watching := false}}) ->
    case is_map_key(current(State), Asks) of
        true ->
            ok = erx_session_relay:watch(Open, in),
            State#state{reader = Reader#{watching := true}};
        false ->
            State
    end;
watch(State) ->
    State.

%% The watch's report, numbered N: one unit of input, a byte or a loss, is read for the
%% current group's ask, if it has one; otherwise it stays in the tty until a group asks.
%% A loss damages the read (damage/2). A read that finds nothing, eagain, waits again:
%% the relay answers it whenever the report is stale, a signal since it or another
%% holder, since the read carries the signal number of its report. An end of file, VEOF at a line's start while a background program left
%% ICANON set, is that read's end and never the hangup, which the relay tells with
%% erx_console_eof: it is a read that found nothing, so the ask stays outstanding and
%% the bytes held for the group go.
read_for_ask(N, State = #state{asks = Asks, reader = #{open := Open}}) ->
    Group = current(State),
    case is_map_key(Group, Asks) andalso erx_session_relay:read_input(Open, N) of
        false -> {noreply, State};
        {ok, <<Byte>>} -> {noreply, watch(answer(Group, Byte, State))};
        lost -> {noreply, watch(damage(Group, State))};
        eagain -> {noreply, watch(State)};
        eof -> {noreply, watch(drop_held(Group, State))}
    end.

%% The one way a loss reaches a group, so no loss is silent and none reaches a process
%% that is not one of the console's groups: the loss is sent at once, in order with the
%% input pushed or answered before it, as the answer to Group's outstanding ask or, while
%% it has none, as an answer to no ask, which group takes as a loss all the same
%% (otp/lib/kernel/src/group.erl, handle_info/3). The leading bytes of a character held
%% for Group go, since the loss fell among them (docs/design-live.md, "Lost input").
damage(Group, State0 = #state{asks = Asks}) ->
    State = drop_held(Group, State0),
    case is_group(Group, State) of
        true ->
            Group ! {self(), {read, maps:get(Group, Asks, make_ref()), lost}},
            State#state{asks = maps:remove(Group, Asks)};
        false ->
            State
    end.

%% The bytes held for Group go: a signal flushed the input typed with them, a loss fell
%% among them, or a read found the end of file.
drop_held(Group, State = #state{reader = Reader = #{held := Held}}) ->
    State#state{reader = Reader#{held := maps:remove(Group, Held)}}.

%% Byte, read for Group's ask, joins the bytes held for Group: what they complete ends
%% the ask, and what they leave incomplete stays held for Group's next ask.
answer(Group, Byte, State = #state{asks = Asks, reader = Reader = #{held := Held}}) ->
    {Chars, Left} = chars(maps:get(Group, Held, <<>>), Byte),
    Reader1 = Reader#{held := Held#{Group => Left}},
    case Chars of
        <<>> ->
            State#state{reader = Reader1};
        Chars ->
            Group ! {self(), {read, map_get(Group, Asks), Chars}},
            State#state{reader = Reader1, asks = maps:remove(Group, Asks)}
    end.

%% A signal key typed while Group was the console's current group; `quit` at the prompt
%% does nothing more, as FreeBSD's sh ignores SIGQUIT. Ctrl-C turns into an interrupt of
%% an Erlang shell's evaluator in the group, as ssh_cli's does, and Ctrl-Z stops a command
%% shell's foreground job, which the group passes on to its shell; the Erlang shell has
%% no jobs, and never sees it.
signal(interrupt, Group, _State) ->
    exit(Group, interrupt);
signal(suspend, Group, #state{shells = Shells}) ->
    case lists:keyfind(Group, 1, Shells) of
        {Group, _Caller, {shell, start, _}} -> ok;
        _ -> Group ! {self(), suspend}
    end;
signal(quit, _Group, _State) ->
    ok.

%% A session's line has hung up: every shell on it ends, and the console with them, as a
%% UNIX session ends at its terminal's hangup. No group is told of the end of input: the
%% Erlang shell would halt the runtime at it, and edlin edits with it.
hang_up(State = #state{base = Base, shells = Shells}) ->
    lists:foreach(fun(Group) -> exit(Group, kill) end, [Base | [G || {G, _Caller, _Shell} <- Shells]]),
    {stop, normal, State}.

%% A size change reaches the foreground job's processes that asked for it: the current
%% group passes it on to its shell, which alone knows its jobs. The Erlang shell has
%% none, and never sees it.
resized(State = #state{shells = Shells}) ->
    case Shells of
        [{_Group, _Caller, {shell, start, _}} | _] -> ok;
        _ -> current(State) ! {self(), winch}
    end.

%% The console's own tty's reads, for a console whose driver sends its input as it
%% arrives.

%% The driver's next input message has come: until all of it is in the tty, the driver
%% is not answered.
unanswered(State = #state{reader = Reader = #{unread := answered}}) ->
    State#state{reader = Reader#{unread := <<>>}};
unanswered(State) ->
    State.

%% The one step the console's own tty moves on by, after anything that may let it: the
%% bytes the driver sent go into the tty as it has room, the current group's ask is read
%% for, and the driver is answered once all of its message is in, at once for a person's
%% terminal, whose input must keep reaching ISIG however much is typed ahead, so that the
%% tty's bound drops the rest as a loss; and once its tty has room for a pipe, which is
%% held back and never cut. Once the driver's input has ended and nothing read before
%% the end waits, the groups are told.
serve(State0) ->
    State = fill(State0),
    case read_own(State) of
        {read, Next} -> serve(Next);
        none -> ended(answer_driver(State))
    end.

%% The driver's bytes the tty has room for, into it: all of them for a person's
%% terminal, as many as fit for a pipe.
fill(State = #state{reader = #{unread := answered}}) ->
    State;
fill(State = #state{reader = #{tty := Tty, pipe := Pipe, unread := Unread}}) ->
    Fits = case Pipe of
               true -> min(byte_size(Unread), erx_tty:input_room(Tty));
               false -> byte_size(Unread)
           end,
    <<Taken:Fits/binary, Left/binary>> = Unread,
    State1 = #state{reader = Reader} = own_input(Taken, State),
    State1#state{reader = Reader#{unread := Left}}.

%% Bytes through the tty's input/3 until none is left: it stops after each signal key,
%% whose event is carried out before the bytes after it go in. The tty makes no output,
%% so its echo has no room.
own_input(<<>>, State) ->
    State;
own_input(Bytes, State = #state{reader = Reader = #{tty := Tty}}) ->
    {Actions, Rest, _Room, Tty1} = erx_tty:input(Bytes, {0, 0, false}, Tty),
    own_input(Rest, own_actions(Actions, State#state{reader = Reader#{tty := Tty1}})).

%% A loss the driver sent, into the tty after every byte sent before it, which goes in
%% first whatever the room, since a byte the bound drops is a loss of its own there.
own_lost(State0 = #state{reader = #{unread := Unread}}) ->
    State = #state{reader = Reader = #{tty := Tty}} = own_input(Unread, State0),
    {Actions, Tty1} = erx_tty:lost(Tty),
    own_actions(Actions, State#state{reader = Reader#{tty := Tty1, unread := <<>>}}).

own_actions(Actions, State) ->
    lists:foldl(fun own_action/2, State, Actions).

%% What the tty's actions mean to the console: a key's signal, a flush that dropped a
%% loss and VSTATUS are the events the relay tells its console, through the relay core's
%% one mapping, for the current group; the tty echoes nothing, holds no output to flush,
%% stop or start, and has no waiter to ready or time.
own_action({echo, _Bytes}, State) -> State;
own_action(flush_output, State) -> State;
own_action(stop_output, State) -> State;
own_action(start_output, State) -> State;
own_action({ready, _Open}, State) -> State;
own_action({timer_start, _Timer, _Ms}, State) -> State;
own_action({timer_cancel, _Timer}, State) -> State;
own_action(Event, State) -> tty_event(current(State), erx_session_relay_core:event_name(Event), State).

%% One unit read from the tty for the current group's ask, if it has one: a byte joins
%% the bytes held for the group (answer/3), and a loss damages the read (damage/2). The
%% tty never hangs up, so a read never finds the end of file.
read_own(State = #state{asks = Asks, reader = Reader = #{tty := Tty}}) ->
    Group = current(State),
    case is_map_key(Group, Asks) andalso erx_tty:read_input(console, Tty) of
        false -> none;
        {eagain, _Tty} -> none;
        {{ok, <<Byte>>}, Tty1} -> {read, answer(Group, Byte, State#state{reader = Reader#{tty := Tty1}})};
        {lost, Tty1} -> {read, damage(Group, State#state{reader = Reader#{tty := Tty1}})}
    end.

answer_driver(State = #state{driver = Driver, reader = Reader = #{unread := <<>>}}) ->
    Driver ! erx_console_taken,
    State#state{reader = Reader#{unread := answered}};
answer_driver(State) ->
    State.

%% The driver's end, once every byte read before it is taken: the leading bytes of a
%% character held for the current group, which nothing will finish, answer its ask as
%% stock reads a bad byte, as latin-1, and then the group gets the end, as every group
%% that gets the input from then on does (gets_input/1).
ended(State = #state{reader = Reader = #{ending := true, unread := answered, tty := Tty, held := Held},
                     asks = Asks}) ->
    Group = current(State),
    case {erx_tty:waiting(Tty), maps:get(Group, Held, <<>>), Asks} of
        {0, <<>>, _} ->
            gets_input(State#state{input_ended = true, reader = Reader#{ending := false}});
        {0, Bytes, #{Group := Ref}} ->
            Group ! {self(), {read, Ref, latin1(Bytes)}},
            ended(State#state{asks = maps:remove(Group, Asks), reader = Reader#{held := maps:remove(Group, Held)}});
        _ ->
            State
    end;
ended(State) ->
    State.

%% -- Output ---------------------------------------------------------------------------

%% A command's bytes as a cooked tty's OPOST and ONLCR send them: each newline as CR-LF,
%% every other byte unchanged.
-spec onlcr(binary()) -> binary().
onlcr(Bytes) ->
    binary:replace(Bytes, <<"\n">>, <<"\r\n">>, [global]).

%% The console's ask for its next batch of the log (erx_syslog:next/1).
log_ask() ->
    {asked, erx_syslog:next(console)}.

%% A batch of the log's lines, each made by the log service through the line escape
%% and ending in nothing: each goes to the driver whole, ending in CR-LF, between
%% whatever else is written. The last one's written says the batch is on the line.
log_batch([], State) ->
    State#state{log = log_ask()};
log_batch(Lines, State = #state{driver = Driver}) ->
    {Head, [Last]} = lists:split(length(Lines) - 1, Lines),
    [Driver ! {erx_console_output, none, [Line, <<"\r\n">>]} || Line <- Head],
    Driver ! {erx_console_output, log_batch, [Last, <<"\r\n">>]},
    State#state{log = writing}.

group_request(tty_geometry, Pid, State = #state{size = Size}) ->
    Pid ! {self(), tty_geometry, otp_geometry(Size)},
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

%% Size as OTP's terminal code takes a geometry, {Columns, Rows}: prim_tty's and a
%% group's tty_geometry answer, as user_drv gives it.
otp_geometry({Rows, Columns}) -> {Columns, Rows}.

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
