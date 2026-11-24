%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_tty).
-moduledoc """
A session's ttys (docs/design-live.md, "The tty", "Where a tty lives", "Between
domains"), each with the command shell on it, and each driven by a terminal
relay of its own (erx_session_relay, docs/design-shell.md, "The terminal relay's
protocol"), which runs the tty's line discipline, carries its bytes to and from
its master in the six messages, and is read by its console on demand
(docs/design-shell.md, "The console reads on demand"):

* the session's console tty (start_link/0), whose master is the console facet
  that erx:cap(console) names; erx_session_sup starts it at boot, and it is the
  domain's line (erx_console:terminal/0), whose console holds the domain's
  `user`, so `user` lives as long as the line whichever other ttys end. Its
  relay alone is registered, under the name the runtime's own writers look
  for (erx_session_relay:start_link/3);
* a tty for each master in the session's own domain that asks for one with
  open/1, as a terminal on a display does (docs/design-display.md, "The
  terminal"), much as a program's posix_openpt makes a pseudo-terminal. Its
  relay holds no name: its console reaches it by pid, and every open names the
  relay that made it;
* a tty for each SSH channel the session's line to the SSH domain opens with
  open_channel/3 (erx_tty_line; docs/design-ssh.md, "Sessions, ttys and
  shells"), whose master is the channel, a process of that domain. Its shell is
  the command shell, or `rc -c Command` for an exec request, and it is not
  started again: once the shell has ended and the channel has taken its last
  output, the console reports how the shell ended and ends, its relay with
  it. A channel with no pseudo-terminal gets no tty: open_job/1 runs its
  command as a job on message pipes (erx_ssh_job), from the same home as a
  tty's shell.

A tty is two processes. The groups that run its shells are driven by a console
of the session role (erx_console:start_link/1), unregistered, exactly as the
system domain's console drives its own: the command shell on the first group,
started again whenever it ends (as on the UART), and run_shell and write with
erx_console's meaning on the tty's terminal, erx_console:terminal(Console). The
relay is the console's line driver and ends with it.

A message from the master arrives as `{erx_origin, D, Msg}` when the master is
in another domain, and the relay takes the envelope off only when `D` is the
master's domain. A master in the session's own domain sends plain messages, and
its end is the tty's hangup, as a pseudo-terminal master's close is
(docs/design-programs.md, "The terminal"): the console ends the tty's shells and
then itself, its relay with it, and the session's other ttys run on.
""".

-export([start_link/0, start_link/1, open/1, open_channel/3, start_channel/3, open_job/1, shell_of/3, master/0]).

-export_type([run/0, channel/0]).

%% What runs on a channel's tty: the command shell, or rc on one command.
-type run() :: shell | {exec, binary()}.
%% A channel's tty: what runs on it, its first window size, and the shell's first
%% variables (erx_shell_script:first_vars/1).
-type channel() :: #{run := run(), size := erx_console:size(), vars := erx_shell_script:vars()}.

-doc """
Starts the session's console tty, with the master erx:cap(console) names, as the
domain's line, whose console holds the domain's `user` and whose relay is
registered. Returns its console.
""".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_console(master(), #{domain_line => true}).

-doc """
The master of the session's console tty: the session's console facet, or
undefined for a session that holds none, which has no terminal and so no console
tty (erx_session_sup:line/1).
""".
-spec master() -> pid() | undefined.
master() ->
    erx:cap(console).

-doc """
Starts a tty whose master is Master, a process of this domain, linked to the
caller. Returns its console; the master learns the tty, its relay, from its
`{tty_open, Tty}`.
""".
-spec start_link(pid()) -> {ok, pid()} | {error, term()}.
start_link(Master) when is_pid(Master), node(Master) =:= node() ->
    start_console(Master, #{user => none}).

-doc """
Opens a new tty of the session for Master, a process of this domain, under the
session's supervisor, which never restarts it: it ends with its master. Returns
its console.
""".
-spec open(pid()) -> {ok, pid()} | {error, term()}.
open(Master) when is_pid(Master), node(Master) =:= node() ->
    supervisor:start_child(erx_session_sup,
                           #{id => {?MODULE, make_ref()},
                             start => {?MODULE, start_link, [Master]},
                             restart => temporary,
                             type => worker,
                             modules => [?MODULE, erx_console, erx_session_relay]}).

-doc """
Opens a tty of the session for Channel under the session's supervisor, which
never restarts it. Channel is a process of the SSH domain the session's line
serves, or, at SSH's first stage, a channel of the daemon the session runs
itself (erx_ssh_dev_channel). Tty says what runs on it and its first size
(channel()); Notify gets how what ran ended (erx_console:shell_ending/1) once
Channel has taken the tty's last output (erx_console's `on_shell_end`).
Returns its console. A caller with a channel of another domain has checked
that it is a process of the domain it serves: the relay hears such a channel
only in that domain's envelope, and one of this domain plainly.
""".
-spec open_channel(pid(), channel(), fun((erx_prog:status()) -> term())) -> {ok, pid()} | {error, term()}.
open_channel(Channel, Tty, Notify) when is_pid(Channel), is_function(Notify, 1) ->
    supervisor:start_child(erx_session_sup,
                           #{id => {?MODULE, make_ref()},
                             start => {?MODULE, start_channel, [Channel, Tty, Notify]},
                             restart => temporary,
                             type => worker,
                             modules => [?MODULE, erx_console, erx_session_relay]}).

-doc false.
start_channel(Channel, #{run := Run, size := Size, vars := Vars}, Notify) ->
    %% The relay's tty and the console's terminal both start at the size.
    erx_console:start_link(#{role => session, user => none,
                             on_shell_end => {exit, Notify},
                             size => Size,
                             driver => relay(Channel, #{size => Size}),
                             first_shell => fun(Terminal) -> shell_of(Run, Terminal#{vars => Vars}, erx_session_sup:home()) end}).

-doc """
Starts the job relay that runs `rc -c Command` for the calling process, a
channel with no pseudo-terminal (erx_ssh_job:start/2), with no first variables
and, as on a tty, from the session's home when it has one (shell_of/3).
Returns the relay, which ends with the job or at the channel's end, and the
alias that tags the job messages between them.
""".
-spec open_job(binary()) -> {pid(), erx_ssh_job:tag()}.
open_job(Command) ->
    erx_ssh_job:start(Command, at_home(erx_session_sup:home(), #{vars => #{}, cwd => <<"/">>})).

-doc """
What runs on a tty's terminal: the command shell, or rc on one command, each
with the terminal's first variables, and, for a session with a home, Home
(erx_session_sup:home/0), `$home` set to the home's path and its working
directory there, as FreeBSD's login(1) sets HOME and changes to the home
(docs/design-files.md, "A user's home"); without one, from `/`.
""".
-spec shell_of(shell | {exec, binary()}, erx_shell:terminal(), {ok, {binary(), list()}} | none) -> mfa().
shell_of(Run, Terminal, Home) ->
    run_on(Run, at_home(Home, Terminal)).

at_home(none, Terminal) ->
    Terminal;
at_home({ok, {Path, _Options}}, Terminal) ->
    Vars = maps:get(vars, Terminal, #{}),
    Terminal#{vars => Vars#{<<"home">> => [Path]}, cwd => Path}.

run_on(shell, Terminal) ->
    {erx_shell, server, [{erx_shell_runner, Terminal}]};
run_on({exec, Command}, #{vars := Vars} = Terminal) ->
    {erx_shell_script, command, [Command, Vars, maps:get(cwd, Terminal, <<"/">>)]}.

%% A console of the session role driven by a relay for Master, the relay of the
%% domain's line when Options says the console is that line, and whose first
%% shell is the command shell on that console's own terminal.
start_console(Master, Options) ->
    RelayOptions = maps:with([domain_line], Options),
    erx_console:start_link(Options#{role => session,
                                    driver => relay(Master, RelayOptions),
                                    first_shell => fun(Terminal) -> shell_of(shell, Terminal, erx_session_sup:home()) end}).

%% The console's driver: a relay for Master, the console's line driver.
relay(Master, RelayOptions) ->
    fun(Console) ->
            {ok, Pid} = erx_session_relay:start_link(Console, Master, RelayOptions),
            {ok, Pid, relay}
    end.
