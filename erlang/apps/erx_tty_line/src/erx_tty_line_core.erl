%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tty_line_core).
-moduledoc """
The decisions of a session's line to the SSH domain (erx_tty_line;
docs/design-ssh.md, "Sessions, ttys and shells"), pure: which requests the
line takes and how many channels it holds open.

The line serves one peer, the SSH domain its facet is bound to, whose
requests that facet admits and forwards (erx_session_line). A request from the
peer is untrusted, so request/4 checks its whole shape before anything acts
on it, and answers
`{error, badarg}` for any shape but the one below, and for a channel that is
no process of the peer's: a channel of a third domain would make the session
send a tty's bytes there. Past tty_line_max_channels open channels,
`max_channels`, it answers `{error, limited}`.

* `{open_tty, Channel, Run, Term, Rows, Columns}`: Channel a pid of the
  peer's, Run `shell` or `{exec, Command}` with Command a binary of 1 to
  tty_line_command_max bytes holding no NUL, Term a binary of at most
  tty_term_max bytes, and Rows and Columns integers from 0, which `pty-req`
  allows, to console_side_max (abi/services/tty_line.txt and console.txt).

The tty opens at Rows by Columns, a side of zero taken as 24 rows or 80
columns, and its shell's TERM is Term when abi/terminal.txt lists it and
that file's default otherwise (term/1), as design-ssh.md has it, so
no byte of the peer's reaches the shell's variables. A channel counts from
its open (opened/3)
until its tty ends (ended/2), and the tty's report of how its shell ended
goes to that channel alone (report/2).
""".

-export([new/0, request/4, valid_run/1, tty/4, term/1, opened/3, ended/2, report/2]).
-export_type([core/0]).

-include("generated/erx_abi.hrl").

%% A pseudo-terminal's size when pty-req gives a side as zero.
-define(DEFAULT_ROWS, 24).
-define(DEFAULT_COLUMNS, 80).

%% The open channels' ttys, each by the process that ends with it, the tty's console.
-opaque core() :: #{ttys := #{pid() => pid()}}.

-doc "A line that holds no channel.".
-spec new() -> core().
new() -> #{ttys => #{}}.

-doc """
What the line does with Request from its peer Peer, given Owner, the domain
of a pid: open a tty on the channel, or answer the error.
""".
-spec request(term(), pos_integer(), fun((pid()) -> non_neg_integer()), core()) ->
          {open_tty, pid(), erx_session_tty:channel()} | {error, limited | badarg}.
request({open_tty, Channel, Run, Term, Rows, Columns}, Peer, Owner, #{ttys := Ttys})
  when is_pid(Channel), is_binary(Term), byte_size(Term) =< ?ERX_TTY_TERM_MAX,
       is_integer(Rows), Rows >= 0, Rows =< ?ERX_CONSOLE_SIDE_MAX,
       is_integer(Columns), Columns >= 0, Columns =< ?ERX_CONSOLE_SIDE_MAX ->
    case {valid_run(Run), Owner(Channel) =:= Peer} of
        {true, true} when map_size(Ttys) >= ?ERX_TTY_LINE_MAX_CHANNELS -> {error, limited};
        {true, true} -> {open_tty, Channel, tty(Run, Term, Rows, Columns)};
        _ -> {error, badarg}
    end;
request(_Request, _Peer, _Owner, _Core) ->
    {error, badarg}.

-doc """
The tty a channel asked for: Run on it at Rows by Columns, a side of zero
taken as 24 rows or 80 columns, its shell's TERM from Term (term/1). The
caller has bounded Term and the sides, as request/4 does; erx_ssh_dev_channel,
SSH's first stage in the session, takes its ttys from here too.
""".
-spec tty(erx_session_tty:run(), binary(), 0..?ERX_CONSOLE_SIDE_MAX, 0..?ERX_CONSOLE_SIDE_MAX) ->
          erx_session_tty:channel().
tty(Run, Term, Rows, Columns) ->
    #{run => Run, size => {side(Rows, ?DEFAULT_ROWS), side(Columns, ?DEFAULT_COLUMNS)},
      vars => #{<<"TERM">> => [term(Term)]}}.

-doc """
The shell's TERM for a channel that asked for Term: Term itself when
abi/terminal.txt lists it, else that file's default.
""".
-spec term(binary()) -> binary().
term(Term) ->
    case lists:member(Term, erx_text_tables:term_types()) of
        true -> Term;
        false -> erx_text_tables:term_default()
    end.

side(0, Default) -> Default;
side(Side, _Default) -> Side.

-doc """
Whether Run is what a channel may ask to run: `shell`, or `{exec, Command}` with
Command a binary of 1 to tty_line_command_max bytes holding no NUL byte.
erx_ssh_dev_channel, SSH's first stage in the session, checks its exec requests here.
""".
-spec valid_run(term()) -> boolean().
valid_run(shell) -> true;
valid_run({exec, Command})
  when is_binary(Command), byte_size(Command) >= 1, byte_size(Command) =< ?ERX_TTY_LINE_COMMAND_MAX ->
    binary:match(Command, <<0>>) =:= nomatch;
valid_run(_Run) -> false.

-doc "The line once Channel's tty, which ends with Tty, is open.".
-spec opened(pid(), pid(), core()) -> core().
opened(Tty, Channel, #{ttys := Ttys} = Core) -> Core#{ttys := Ttys#{Tty => Channel}}.

-doc "The line once the tty Tty has ended; a pid it holds no tty for changes nothing.".
-spec ended(pid(), core()) -> core().
ended(Tty, #{ttys := Ttys} = Core) -> Core#{ttys := maps:remove(Tty, Ttys)}.

-doc """
Where the tty Tty's report of how its shell ended goes: to the channel whose
tty it is, `{send, Channel}`, or `drop` for a pid the line holds no tty for.
The report is the session's own and has the shape the channel hears
(erx_console:shell_ending/1), so the line passes it on unchecked; the
channel checks it as it arrives from the session's domain (design-ssh.md).
""".
-spec report(pid(), core()) -> {send, pid()} | drop.
report(Tty, #{ttys := Ttys}) ->
    case Ttys of
        #{Tty := Channel} -> {send, Channel};
        #{} -> drop
    end.
