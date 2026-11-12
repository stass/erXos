%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_tty).
-moduledoc """
The session's tty relay (docs/design-live.md, "Where a tty lives", "Between
domains"): the session's one tty, raw for as long as it lives, with the
command shell on it, and the five messages that carry its bytes to and from
its master, the console facet that erx:cap(console) names.

It is two processes. The groups that run the session's shells are driven by a
console of the session role (erx_console:start_link/1), registered as
erx_session_shell, exactly as the system domain's console drives its own: the
command shell on the first group, started again whenever it ends (as on the
UART), and run_shell/1 and write/1 with erx_console's meaning. That console's
line driver is the tty itself, registered as erx_session_tty, which turns the
console's writes into numbered outputs to the master and the master's messages
into the console's input, size and end of input, by the pure core
erx_tty_link. The tty is raw, since no program opens it: no line
discipline runs, and the bytes the session's writers hand it reach the master
unchanged, as a program's output reaches a tty on UNIX. The console, which
shows them, applies its own receiver checks.

A message from the master arrives as `{erx_origin, D, Msg}` when the master
is in another domain, and the tty takes the envelope off only when `D` is the
master's domain; a master in the session's own domain sends plain messages.
With no master, the tty is stopped from the start: it holds 4 KiB and its
writers wait.
""".

-export([start_link/0, start_link/1, run_shell/1, write/1, terminal/0]).
%% The tty's own process.
-export([start_tty/2, tty_init/3]).

-define(SHELLS, erx_session_shell).
-define(RESEND_MS, 1000).

-doc "Starts the relay with the master erx:cap(console) names.".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(fun() -> erx:cap(console) end).

-doc """
Starts the relay with the master that Master returns when the tty starts, or
none if it returns `undefined`.
""".
-spec start_link(fun(() -> pid() | undefined)) -> {ok, pid()} | {error, term()}.
start_link(Master) when is_function(Master, 0) ->
    erx_console:start_link(#{role => session, name => ?SHELLS,
                             driver => fun(Console) -> start_tty(Console, Master) end,
                             first_shell => {erx_shell, server, [{erx_shell_runner, terminal()}]}}).

-doc "erx_console:run_shell/1 on the session's tty.".
-spec run_shell(erx_console:shell()) -> ok | {error, term()}.
run_shell(Shell) -> erx_console:run_shell(?SHELLS, Shell).

-doc "erx_console:write/1 on the session's tty.".
-spec write(iodata()) -> ok.
write(Bytes) -> erx_console:write(?SHELLS, Bytes).

-doc "The session's tty as a shell holds it.".
-spec terminal() -> erx_console:terminal().
terminal() -> erx_console:terminal(?SHELLS).

%%% The tty: erx_console's line driver, around erx_tty_link

-doc false.
-spec start_tty(pid(), fun(() -> pid() | undefined)) -> {ok, pid(), true}.
start_tty(Console, Master) ->
    {ok, Pid} = proc_lib:start_link(?MODULE, tty_init, [self(), Console, Master]),
    %% A person's terminal is at the master's end.
    {ok, Pid, true}.

-doc false.
-spec tty_init(pid(), pid(), fun(() -> pid() | undefined)) -> no_return().
tty_init(Parent, Console, MasterFun) ->
    true = register(?MODULE, self()),
    %% The tty is its console's line and ends with it, whatever the reason.
    _ = erlang:monitor(process, Console),
    proc_lib:init_ack(Parent, {ok, self()}),
    Master = MasterFun(),
    ok = open(Master),
    loop(#{console => Console, master => Master, origin => origin(Master),
           link => erx_tty_link:new()}).

%% The tty names itself to its master, the console facet that tells the console whose tty
%% it is (docs/design-live.md, "Between domains"), and again with each resend, which
%% erx_tty_link asks for: the facet drops a message past its limit in flight, and a
%% console that never had the tty's name answers none of its outputs. The master takes
%% the first and ignores the same again.
open(undefined) -> ok;
open(Master) -> Master ! {tty_open, self()}, ok.

%% Where the master's messages come from: plain from a master in this domain,
%% enveloped from one in another, and from nowhere with no master.
origin(undefined) -> none;
origin(Master) when node(Master) =:= node() -> local;
origin(Master) -> {domain, erx:owner(Master)}.

loop(Tty = #{link := Link, origin := Origin}) ->
    receive
        {erx_console_output, From, Bytes} ->
            loop(effects(erx_tty_link:write(From, iolist_to_binary(Bytes), Link), Tty));
        {'DOWN', _Ref, process, Console, Reason} when Console =:= map_get(console, Tty) ->
            exit(Reason);
        {erx_tty_resend, N} ->
            loop(effects(erx_tty_link:timeout(N, Link), Tty));
        {erx_origin, D, Message} when Origin =:= {domain, D} ->
            loop(effects(erx_tty_link:master(Message, Link), Tty));
        {erx_origin, _D, _Message} ->
            loop(Tty);
        Message when Origin =:= local ->
            loop(effects(erx_tty_link:master(Message, Link), Tty));
        _Other ->
            loop(Tty)
    end.

effects({Actions, Link}, Tty) ->
    lists:foreach(fun(Action) -> effect(Action, Tty) end, Actions),
    Tty#{link := Link}.

%% With no master, nothing is sent and no timer runs: the tty stays stopped.
effect({output, _N, _Bytes}, #{master := undefined}) -> ok;
effect({output, N, Bytes}, #{master := Master}) -> Master ! {tty_output, N, Bytes};
effect(open, #{master := Master}) -> open(Master);
effect({resend_after, _N}, #{master := undefined}) -> ok;
effect({resend_after, N}, _Tty) -> erlang:send_after(?RESEND_MS, self(), {erx_tty_resend, N});
effect({done, From}, #{console := Console}) -> Console ! {erx_console_written, From};
effect({input, Bytes}, #{console := Console}) -> Console ! {erx_console_input, Bytes};
effect({size, Rows, Columns}, #{console := Console}) -> Console ! {erx_console_size, Columns, Rows};
effect(hangup, #{console := Console}) -> Console ! erx_console_eof.
