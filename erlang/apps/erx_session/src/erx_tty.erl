%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tty).
-moduledoc """
The line discipline (docs/design-live.md, "The tty"): the decisions of one
tty as a pure state machine. Each call takes the tty and one event and
returns the next tty and what to do, as a list of actions in order. The
process that owns the tty, the terminal relay, carries the actions out and
owns the timers, so time reaches the machine only as timer/2.

Behaviour follows FreeBSD 15.1's line discipline, sys/kern/tty_ttydisc.c,
redesigned as a fold over the bytes rather than translated: a received byte
goes through ttydisc_rint's steps in its order (wake on any key, strip,
signals, start and stop, CR and NL mapping, line editing, storing, echo),
and echo and output share ttydisc_echo_force's and ttydisc_write_oproc's
rendering and the output column they keep.

The input the tty holds is two sequences of units, each unit a byte or a
loss of input (docs/design-live.md, "Lost input"): `ready`, the units a
read can take, and `line`, the cooked line being edited. A byte in raw mode
goes straight to `ready`; in cooked mode a line moves to `ready` at its
end, a newline, VEOF or VEOL. Together they hold at most ?MAX_INPUT bytes,
and a cooked line keeps one byte free for its end, so a line holds at most
4,095 bytes and its end. A byte that does not fit is dropped and counted,
with a bell when IMAXBEL is set, as ttydisc_rint drops a byte when nothing
can be read (tty_ttydisc.c:1220-1236); the relay cannot hold back its
master, so it drops in every case, and the drop is a loss at its place.

A loss, from lost/1 or a drop, is no byte the terminal sent: it matches no
special character, echoes nothing and takes no byte of room, and losses
with no byte between them are one, so the tty holds at most one loss more
than it holds bytes. Readiness counts it as one unit wherever it counts a
byte. read/3 gives each loss as one NUL at its place and read_input/2 as
`lost`, both through one consuming step. An erase never removes a loss
alone: it removes the bytes before it and keeps it at the line's new end,
and a loss goes only with the last byte an edit removes, so an edit that
finds no byte changes nothing, as a key that leaves edlin's empty buffer
empty clears no damage. A signal's flush drops losses with the bytes, and reports `flushed_loss`,
ahead of the signal, when it drops one; a hangup drops them unreported,
since it ends every read. Echo goes to the master with a program's output,
so it takes the room the owner has for the master, which input/3 is given
as output/3 is: a piece of echo that does not fit what is left is dropped
whole, as FreeBSD's ttydisc_echo_force puts echo in the output queue
through ttyoutq_write_nofrag (tty_ttydisc.c:724-760, tty_outq.c:322-334).
So a master that does not read gets no more echo than that room, however
its input is cut into calls. The owner holds at most ?MASTER_ROOM bytes for
the master, master_room/0, and a signal's flush_output empties them but
for the output the master has not taken, so a signal key gives echo that
room back before its own echo, as ttydisc_rint flushes before it echoes
the key (tty_ttydisc.c:1128-1130).

A reader waits before it reads. read_wait/3 and poll_wait/2 register a
waiter for an open, and the tty reports `{ready, Open}` once, when the
waiter's condition holds: a complete line in cooked mode; in raw mode, for
a read, what VMIN and VTIME ask for by POSIX's four cases, or the read's
count when that is fewer, and for a poll one byte, as FreeBSD's poll counts
the canonicalized bytes (ttydisc.h:72). read/3 then answers at once, with
bytes, with `eof` for an end of file or a hung-up tty, with no bytes for a
timed-out raw read, or `eagain` when another reader took the bytes first.
The owner may name a waiter by any term, so it can wait for a read and a
poll of one open as two waiters. A timer is named by `timer()`, which the
tty makes fresh for every start, so a late timer of a cancelled wait does
nothing.

termios is a map of flag lists and characters, checked whole by set/2: a
flag outside this module's tables, a missing or extra key, or a value out
of range fails with `einval`. The numeric encoding of a C program's struct
belongs to the program protocol, not to this module.

What it does not do, each recorded in TODO.md: VLNEXT, VDISCARD and
FLUSHO, ECHOPRT, and the width of a double-width character on erase. Its
other characters and flags behave as FreeBSD's do; IGNBRK, BRKINT, IGNPAR,
INPCK, IXOFF, the control flags and the speeds are kept and returned, and
have nothing to act on, since a master reports no breaks or parity errors
and takes no flow control.
""".

-export([new/0, master_room/0, widest_rendering/0, termios/1, set/2, winsize/1, size/3, input/3,
         input_room/1, lost/1,
         output/3, read_wait/3, poll_wait/2, cancel/2, timer/2, read/3, read_input/2, status/3,
         hangup/1, waiting/1, dropped/1]).
-export_type([tty/0, termios/0, open/0, timer/0, room/0, action/0]).

-include("generated/erx_abi.hrl").

%% Bytes held: complete lines unread and the line being edited.
-define(MAX_INPUT, 4096).
%% Bytes the owner holds for the master at most (docs/design-shell.md,
%% "Output").
-define(MASTER_ROOM, 4096).
%% FreeBSD's _POSIX_VDISABLE (sys/sys/_termios.h:77).
-define(VDISABLE, 16#ff).
-define(MAX_SPEED, 16#ffffffff).
%% FreeBSD prints a status line only with this much room
%% (sys/kern/tty.c:2057-2062).
-define(STATUS_ROOM, 256).
%% Erlang has no escape for BEL.
-define(BELL, 7).
%% Columns from one tab stop to the next.
-define(TAB_WIDTH, 8).

%% The termios map and its tables, every flag and character a termios may
%% hold, are the ABI file's termios table (abi/termios.txt), which
%% erx_abi_termios gives: FreeBSD's supported sets (sys/kern/tty.c:88-96)
%% less those named in the moduledoc.
-type termios() :: erx_abi_termios:termios().
-doc "Whatever names a reader: the relay's open.".
-type open() :: term().
-doc "A read's timer: the open it times and a serial no other timer has.".
-type timer() :: {open(), non_neg_integer()}.
-doc """
The room the owner has for the master, `{Free, Kept, Stopped}`: what is
free of master_room() now; what it holds that a flush cannot drop, the
output already sent to the master and not yet taken; and whether output
is stopped, which only the owner records, as FreeBSD keeps TF_STOPPED
with the output queue (sys/sys/tty.h:82): while it is stopped, writes
and echo still fill the room and nothing goes to the master.
""".
-type room() :: {non_neg_integer(), non_neg_integer(), boolean()}.
-type action() :: {echo, binary()}               % bytes for the master
                | {signal, sigint | sigquit | sigtstp} % for the foreground group
                | info                           % VSTATUS: the foreground job's status
                | flush_output                   % drop output not yet at the master
                | flushed_loss                   % the flush dropped a loss
                | stop_output | start_output     % IXON's VSTOP and VSTART
                | {ready, open()}                % the waiter may read now
                | {timer_start, timer(), pos_integer()} % milliseconds
                | {timer_cancel, timer()}
                | winch.                         % the window size changed
%% Held input: its bytes, and each loss named by the number of bytes
%% before it, ascending, no two the same, since losses with no byte
%% between them are one. A loss named N comes before the byte at offset N.
-record(units, {bytes = <<>> :: binary(), losses = [] :: [non_neg_integer()]}).

%% A read waits for its count, a poll for one unit of input.
-type kind() :: {read, pos_integer()} | poll.
-type waiter() :: {read, pos_integer(), timer() | none} | poll.

-record(tty, {
    termios :: termios(),
    size = {24, 80} :: erx_console:size(),
    ready = #units{} :: #units{},
    line = #units{} :: #units{},
    %% The output column, the column after the last write, and how much of
    %% the line was echoed before it (FreeBSD's t_column, t_writepos and
    %% reprint position), which erase and the status line read, counted
    %% in the line's bytes.
    column = 0 :: non_neg_integer(),
    writepos = 0 :: non_neg_integer(),
    reprintpos = 0 :: non_neg_integer(),
    hungup = false :: boolean(),
    waiters = #{} :: #{open() => waiter()},
    %% Opens whose read timer ended, so their next raw read with VMIN 0
    %% returns no bytes rather than eagain.
    expired = [] :: [open()],
    serial = 0 :: non_neg_integer(),
    received = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer(),
    %% The room for echo left to the input/3 under way, 0 between calls.
    echo_room = 0 :: non_neg_integer(),
    %% What the owner holds for the master that a flush cannot drop, for
    %% the input/3 under way, 0 between calls.
    echo_kept = 0 :: non_neg_integer(),
    %% Whether output is stopped, for the input/3 under way, false between
    %% calls: the owner records it, and input/3's keys change it as they
    %% return stop_output and start_output.
    out_stopped = false :: boolean()
}).

-opaque tty() :: #tty{}.

%%% The tty and its termios

-doc """
A new tty, cooked, with FreeBSD's default termios (sys/sys/ttydefaults.h:46-52,
:102-104) and a 24-by-80 window until the master reports one.
""".
-spec new() -> tty().
new() ->
    #tty{termios = #{iflag => [brkint, icrnl, imaxbel, iutf8, ixany, ixon],
                     oflag => [onlcr, opost],
                     cflag => [cread, hupcl],
                     lflag => [echo, echoctl, echoe, echoke, icanon, iexten,
                               isig],
                     csize => 8,
                     cc => #{veof => $\^D, veol => ?VDISABLE,
                             veol2 => ?VDISABLE, verase => $\^?,
                             vwerase => $\^W, vkill => $\^U,
                             vreprint => $\^R, verase2 => $\^H,
                             vintr => $\^C, vquit => $\^\, vsusp => $\^Z,
                             vdsusp => $\^Y, vstart => $\^Q, vstop => $\^S,
                             vlnext => $\^V, vdiscard => $\^O, vmin => 1,
                             vtime => 0, vstatus => $\^T},
                     ispeed => 9600, ospeed => 9600}}.

-doc """
All the room the owner has for the master: the bytes it holds for the
master at most, and the room a signal's flush_output leaves.
""".
-spec master_room() -> pos_integer().
master_room() -> ?MASTER_ROOM.

-doc """
The most bytes output/3 renders one byte into, whatever the termios: a tab
under TAB3 at a tab stop, which becomes a tab's width of spaces. A newline
under ONLCR becomes two bytes, and every other byte one or none. A room this
large takes the next byte of any write.
""".
-spec widest_rendering() -> pos_integer().
widest_rendering() -> ?TAB_WIDTH.

-doc "The tty's termios, for tcgetattr.".
-spec termios(tty()) -> termios().
termios(#tty{termios = Termios}) -> Termios.

-doc """
Takes a new termios, for tcsetattr, checked whole: anything but a termios
of this module's tables fails with `einval` and changes nothing. An input
speed of 0 takes the output speed, as POSIX and FreeBSD have it
(sys/kern/tty.c:1757-1758). A change of ICANON, VEOF or VEOL moves what the
new mode counts as complete into `ready` (tty.c:1803-1812), and every
waiter waits again under the new rules.
""".
-spec set(term(), tty()) -> {ok, [action()], tty()} | {error, einval}.
set(Candidate, Tty) ->
    try checked(Candidate) of
        Termios -> retermios(Termios, Tty)
    catch
        throw:einval -> {error, einval}
    end.

-doc "The window size the master last reported, as {Rows, Columns}.".
-spec winsize(tty()) -> erx_console:size().
winsize(#tty{size = Size}) -> Size.

-doc """
Takes a window size the master reports, each side from 1 to 65,535, and
refuses any other. It returns `winch` only when the size changes, after
`start_output`, since SIGWINCH starts output as every signal does on
FreeBSD (sys/kern/tty.c:1646, :1536-1538).
""".
-spec size(term(), term(), tty()) -> {ok, [action()], tty()} | {error, einval}.
size(Rows, Columns, #tty{size = Size} = Tty)
  when is_integer(Rows), Rows >= 1, Rows =< ?ERX_CONSOLE_SIDE_MAX,
       is_integer(Columns), Columns >= 1, Columns =< ?ERX_CONSOLE_SIDE_MAX ->
    case Size of
        {Rows, Columns} -> {ok, [], Tty};
        _ ->
            {ok, [start_output, winch], Tty#tty{size = {Rows, Columns}}}
    end;
size(_, _, _) ->
    {error, einval}.

-doc """
The master hung up. The input the tty holds is dropped, as FreeBSD's
carrier loss flushes both queues (sys/kern/tty_ttydisc.c:713-714), every
waiter is ready, and from now on every read that finds no bytes returns
`eof`.
""".
-spec hangup(tty()) -> {[action()], tty()}.
hangup(Tty) ->
    rewait(Tty#tty{hungup = true, ready = #units{}, line = #units{}, reprintpos = 0}).

-doc """
The units a read can take now, FreeBSD's FIONREAD (ttydisc_bytesavail),
each loss counted as the NUL a read gives for it.
""".
-spec waiting(tty()) -> non_neg_integer().
waiting(#tty{ready = Ready} = Tty) ->
    case on(icanon, Tty) of
        false -> count(Ready);
        true ->
            case line_end(Tty) of
                none -> 0;
                {Length, true} -> Length - 1;
                {Length, false} -> Length
            end
    end.

-doc "How many received bytes did not fit and were dropped.".
-spec dropped(tty()) -> non_neg_integer().
dropped(#tty{dropped = Dropped}) -> Dropped.

checked(#{iflag := I, oflag := O, cflag := C, lflag := L, csize := Size,
          cc := Chars, ispeed := ISpeed, ospeed := OSpeed} = Map)
  when map_size(Map) =:= 8, is_integer(Size), Size >= 5, Size =< 8 ->
    Out = speed(OSpeed),
    In = case speed(ISpeed) of
             0 -> Out;
             Speed -> Speed
         end,
    #{iflag => flags(I, iflag), oflag => flags(O, oflag),
      cflag => flags(C, cflag), lflag => flags(L, lflag),
      csize => Size, cc => chars(Chars), ispeed => In, ospeed => Out};
checked(_) ->
    throw(einval).

%% The flags of a word of termios, each one the table names.
flags(List, Word) -> flags(List, erx_abi_termios:flags(Word), []).

flags([], _, Acc) ->
    lists:usort(Acc);
flags([Flag | Rest], Table, Acc) ->
    case lists:member(Flag, Table) of
        true -> flags(Rest, Table, [Flag | Acc]);
        false -> throw(einval)
    end;
flags(_, _, _) ->
    throw(einval).

chars(Chars) when is_map(Chars) ->
    Names = erx_abi_termios:chars(),
    map_size(Chars) =:= length(Names) orelse throw(einval),
    lists:foreach(fun(Name) ->
                          case Chars of
                              #{Name := Value} when is_integer(Value),
                                                    Value >= 0,
                                                    Value =< 255 -> ok;
                              _ -> throw(einval)
                          end
                  end, Names),
    Chars;
chars(_) ->
    throw(einval).

speed(Speed) when is_integer(Speed), Speed >= 0, Speed =< ?MAX_SPEED -> Speed;
speed(_) -> throw(einval).

retermios(New, #tty{termios = Old} = Tty0) ->
    Tty1 = Tty0#tty{termios = New, expired = []},
    Ends = fun(#{lflag := L, cc := #{veof := Eof, veol := Eol}}) ->
                   {lists:member(icanon, L), Eof, Eol}
           end,
    Tty2 = case Ends(Old) =/= Ends(New) of
               true -> canonicalize(Tty1);
               false -> Tty1
           end,
    {Actions, Tty3} = rewait(Tty2),
    {ok, Actions, Tty3}.

%% Moves into `ready` what the mode counts as complete: in raw mode the whole
%% line, in cooked mode the line up to its last end (ttydisc_canonicalize).
canonicalize(#tty{ready = Ready, line = Line, reprintpos = Shown} = Tty) ->
    case on(icanon, Tty) of
        false ->
            Tty#tty{ready = join(Ready, Line), line = #units{}, reprintpos = 0};
        true ->
            Cut = last_end(Line#units.bytes, Tty),
            {Done, Rest} = split(Line, Cut),
            Tty#tty{ready = join(Ready, Done), line = Rest,
                    reprintpos = max(0, Shown - Cut)}
    end.

last_end(Line, Tty) ->
    {_, Cut} = lists:foldl(fun(Byte, {Position, Cut}) ->
                                   Next = Position + 1,
                                   case is_end(Byte, Tty) of
                                       true -> {Next, Next};
                                       false -> {Next, Cut}
                                   end
                           end, {0, 0}, binary_to_list(Line)),
    Cut.

%%% Input

-doc """
Bytes from the master, with at most Room bytes of echo to give, the room
the owner has for the master. Each goes through FreeBSD's steps in ttydisc_rint's
order (tty_ttydisc.c:1012-1250); then every waiter whose condition now
holds is ready, and a raw read waiting with VMIN and VTIME above 0 starts
its timer at its first byte and keeps that deadline. It stops after a key
that makes a signal and returns the bytes after it untaken, as
ttydisc_rint signals the foreground group before it takes the next byte
(tty_ttydisc.c:1124-1133), so the owner acts on the signal before any
reader is reported a byte typed after the key, and then passes the rest
to input/3 again, with the room it returns. That room is what the echo
left of Room, or after a flush_output of master_room() less what the
owner keeps, since the flush empties the rest of what it holds.
""".
-spec input(binary(), room(), tty()) -> {[action()], binary(), room(), tty()}.
input(Bytes, {Free, Kept, Stopped}, #tty{received = Before} = Tty0)
  when is_binary(Bytes), is_integer(Free), Free >= 0, is_integer(Kept), Kept >= 0,
       Free + Kept =< ?MASTER_ROOM, is_boolean(Stopped) ->
    {Keyed, Rest, Tty1} = keys(Bytes, [], Tty0#tty{echo_room = Free, echo_kept = Kept,
                                                   out_stopped = Stopped}),
    Arrived = Tty1#tty.received > Before,
    %% The room lives only within a call: it is read from Tty1 and
    %% cleared in the tty returned.
    {Settled, Tty2} = settle(Arrived, Tty1#tty{echo_room = 0, echo_kept = 0,
                                               out_stopped = false}),
    {merge(lists:reverse(Keyed)) ++ Settled, Rest,
     {Tty1#tty.echo_room, Kept, Tty1#tty.out_stopped}, Tty2}.

-doc """
How many more bytes input/3 takes before its bound drops one, under a termios
without PARMRK, which doubles a received 0xff: what an owner that must lose
nothing, the console of a pipe, gives it at most.
""".
-spec input_room(tty()) -> non_neg_integer().
input_room(#tty{ready = Ready, line = Line} = Tty) ->
    Reserve = case on(icanon, Tty) of
                  true -> 1;
                  false -> 0
              end,
    max(0, ?MAX_INPUT - byte_size(Ready#units.bytes) - byte_size(Line#units.bytes) - Reserve).

-doc """
Input was lost here (docs/design-live.md, "Lost input"): a loss goes where
the next byte would, at the end of the cooked line or of the readable raw
input, unless the input already ends with one. It returns the actions
input/3 returns for one byte that ends no line and makes no signal: the
waiters it readies, and the timer it starts as a first unit.
""".
-spec lost(tty()) -> {[action()], tty()}.
lost(Tty) ->
    settle(true, add_loss(Tty)).

add_loss(#tty{ready = Ready, line = Line} = Tty) ->
    Last = case Line of
               #units{bytes = <<>>, losses = []} -> Ready;
               _ -> Line
           end,
    case {ends_lost(Last), on(icanon, Tty)} of
        {true, _} -> Tty;
        {false, true} -> Tty#tty{line = append_loss(Line)};
        {false, false} -> Tty#tty{ready = append_loss(Ready)}
    end.

%% The keys up to and including the first that makes a signal.
keys(<<Byte, Rest/binary>>, Actions0, Tty0) ->
    case key(Byte, {Actions0, Tty0}) of
        {[{signal, _} | _] = Actions, Tty} -> {Actions, Rest, Tty};
        {Actions, Tty} -> keys(Rest, Actions, Tty)
    end;
keys(<<>>, Actions, Tty) ->
    {Actions, <<>>, Tty}.

%% Actions are gathered newest first, and merge/1 joins neighbouring echoes.
key(Byte, {Actions0, Tty0}) ->
    {Actions, Tty} = case on(ixany, Tty0) andalso Tty0#tty.out_stopped of
                         true -> {[start_output | Actions0],
                                  Tty0#tty{out_stopped = false}};
                         false -> {Actions0, Tty0}
                     end,
    Char = case on(istrip, Tty) of
               true -> Byte band 16#7f;
               false -> Byte
           end,
    signal_key(Char, Actions, Tty).

signal_key(Char, Actions, Tty) ->
    case on(isig, Tty) andalso signal_of(Char, Tty) of
        info ->
            {Started, Tty1} = start(Actions, Tty),
            {[info | Started], Tty1};
        {signal, _} = Signal ->
            {Started, Tty0} = start(Actions, Tty),
            {Flushed, Tty1} = flush(Started, Tty0),
            {Echoed, Tty2} = echo(Char, Flushed, Tty1),
            {[Signal | Echoed], Tty2};
        _ ->
            flow_key(Char, Actions, Tty)
    end.

%% VSTATUS needs ICANON and IEXTEN as well as ISIG (tty_ttydisc.c:1101-1106).
signal_of(Char, Tty) ->
    case on(icanon, Tty) andalso on(iexten, Tty) andalso
        is_char(vstatus, Char, Tty) of
        true ->
            info;
        false ->
            Keys = [{vintr, sigint}, {vquit, sigquit}, {vsusp, sigtstp}],
            case [{signal, Signal} || {Name, Signal} <- Keys,
                                      is_char(Name, Char, Tty)] of
                [First | _] -> First;
                [] -> none
            end
    end.

%% A signal from a key starts stopped output, as FreeBSD's tty_signal_pgrp
%% does (sys/kern/tty.c:1538-1540).
start(Actions, #tty{out_stopped = true} = Tty) ->
    {[start_output | Actions], Tty#tty{out_stopped = false}};
start(Actions, Tty) ->
    {Actions, Tty}.

%% The owner drops what it holds for the master at flush_output, all but
%% what it has sent and the master has not taken, so echo has the rest of
%% the whole room.
flush(Actions, Tty) ->
    case on(noflsh, Tty) of
        true -> {Actions, Tty};
        false ->
            Dropped = (Tty#tty.ready)#units.losses ++ (Tty#tty.line)#units.losses,
            Reported = case Dropped of
                           [] -> [flush_output | Actions];
                           _ -> [flushed_loss, flush_output | Actions]
                       end,
            {Reported, Tty#tty{ready = #units{}, line = #units{}, reprintpos = 0,
                               echo_room = ?MASTER_ROOM - Tty#tty.echo_kept}}
    end.

%% IXON: VSTOP stops output and VSTART starts it; with both the same
%% character, it toggles (tty_ttydisc.c:1140-1162).
flow_key(Char, Actions, #tty{out_stopped = Stopped} = Tty) ->
    Stop = on(ixon, Tty) andalso is_char(vstop, Char, Tty),
    Start = on(ixon, Tty) andalso is_char(vstart, Char, Tty),
    if
        Stop, not Stopped -> {[stop_output | Actions], Tty#tty{out_stopped = true}};
        Start, Stopped -> {[start_output | Actions], Tty#tty{out_stopped = false}};
        Stop; Start -> {Actions, Tty};
        true -> map_key(Char, Actions, Tty)
    end.

map_key($\r, Actions, Tty) ->
    case {on(igncr, Tty), on(icrnl, Tty)} of
        {true, _} -> {Actions, Tty};
        {false, true} -> edit_key($\n, Actions, Tty);
        {false, false} -> edit_key($\r, Actions, Tty)
    end;
map_key($\n, Actions, Tty) ->
    case on(inlcr, Tty) of
        true -> edit_key($\r, Actions, Tty);
        false -> edit_key($\n, Actions, Tty)
    end;
map_key(Char, Actions, Tty) ->
    edit_key(Char, Actions, Tty).

edit_key(Char, Actions, Tty) ->
    Cooked = on(icanon, Tty),
    Extended = Cooked andalso on(iexten, Tty),
    Edits = [{Cooked, verase, erase}, {Cooked, verase2, erase},
             {Cooked, vkill, kill}, {Extended, vwerase, word},
             {Extended, vreprint, reprint}],
    case [Edit || {true, Name, Edit} <- Edits, is_char(Name, Char, Tty)] of
        [erase | _] -> rub_char(Actions, Tty);
        [kill | _] -> rub_line(Actions, Tty);
        [word | _] -> rub_word(Actions, Tty);
        [reprint | _] -> reprint(Actions, Tty);
        [] -> store(Char, Actions, Tty)
    end.

%% PARMRK marks a received 0xff by doubling it (tty_ttydisc.c:1195-1200).
store(Char, Actions, #tty{ready = Ready, line = Line} = Tty) ->
    Bytes = case on(parmrk, Tty) andalso Char =:= 16#ff of
                true -> <<16#ff, 16#ff>>;
                false -> <<Char>>
            end,
    Cooked = on(icanon, Tty),
    End = Cooked andalso is_end(Char, Tty),
    Reserve = case Cooked andalso not End of
                  true -> 1;
                  false -> 0
              end,
    Held = byte_size(Ready#units.bytes) + byte_size(Line#units.bytes) + byte_size(Bytes) + Reserve,
    Received = Tty#tty.received + byte_size(Bytes),
    if
        Held > ?MAX_INPUT ->
            full(Actions, Tty);
        not Cooked ->
            echo(Char, Actions, Tty#tty{ready = append(Ready, Bytes), received = Received});
        End ->
            echo(Char, Actions,
                 Tty#tty{ready = join(Ready, append(Line, Bytes)),
                         line = #units{}, reprintpos = 0, received = Received});
        true ->
            echo(Char, Actions, Tty#tty{line = append(Line, Bytes), received = Received})
    end.

%% A byte with no room is dropped, counted and lost at its place.
full(Actions, #tty{dropped = Dropped} = Tty) ->
    Counted = add_loss(Tty#tty{dropped = Dropped + 1}),
    case on(imaxbel, Tty) of
        true -> emit(<<?BELL>>, Actions, Counted);
        false -> {Actions, Counted}
    end.

%%% Line editing (tty_ttydisc.c:833-1010)

rub_char(Actions, Tty) ->
    {_, Rubbed, Tty1} = rub(Actions, Tty),
    {Rubbed, Tty1}.

rub_line(Actions, Tty) ->
    case rub(Actions, Tty) of
        {empty, Rubbed, Tty1} -> {Rubbed, Tty1};
        {ok, Rubbed, Tty1} -> rub_line(Rubbed, Tty1)
    end.

%% Whitespace first, then the word; with ALTWERASE a word also ends where
%% letters and digits meet other characters.
rub_word(Actions, Tty) ->
    case last(Tty) of
        none ->
            %% No byte to remove: the line, and any loss it holds, stays.
            {Actions, Tty};
        Char ->
            case white(Char) of
                true ->
                    {ok, Rubbed, Tty1} = rub(Actions, Tty),
                    rub_word(Rubbed, Tty1);
                false ->
                    rub_word(alnum(Char), Actions, Tty)
            end
    end.

rub_word(Alnum, Actions, Tty) ->
    {_, Rubbed, Tty1} = rub(Actions, Tty),
    case last(Tty1) of
        none ->
            {Rubbed, Tty1};
        Char ->
            case white(Char) orelse
                (on(altwerase, Tty1) andalso alnum(Char) =/= Alnum) of
                true -> {Rubbed, Tty1};
                false -> rub_word(Alnum, Rubbed, Tty1)
            end
    end.

%% Removes the last character of the line and, with ECHO, from the screen:
%% by retyping the line when output has been written over it since, by
%% ECHOE's visual erase, or else by echoing VERASE. The line's losses stay
%% at its new end, and go with its last byte.
rub(Actions, #tty{line = #units{bytes = <<>>}} = Tty) ->
    {empty, Actions, Tty};
rub(Actions, #tty{line = #units{bytes = Line}} = Tty0) ->
    Keep = byte_size(Line) - 1,
    <<_:Keep/binary, Char>> = Line,
    Tty = shorten(Keep, Tty0),
    Echo = on(echo, Tty),
    Covered = Tty#tty.writepos >= Tty#tty.column,
    if
        not Echo ->
            {ok, Actions, Tty};
        Covered ->
            {Retyped, Tty1} = reprint(Actions, Tty),
            {ok, Retyped, Tty1};
        true ->
            {Erased, Tty1} = erase_shown(Char, Actions, Tty),
            {ok, Erased, Tty1}
    end.

erase_shown(Char, Actions, Tty) ->
    case on(echoe, Tty) of
        false -> echo(char(verase, Tty), Actions, Tty);
        true -> erase_visually(Char, Actions, Tty)
    end.

erase_visually(Char, Actions, Tty) ->
    Utf8 = on(iutf8, Tty) andalso Char >= 16#80,
    case caret(Char) of
        true ->
            case on(echoctl, Tty) of
                true -> emit(<<"\b\b  \b\b">>, Actions, back(2, Tty));
                false -> {Actions, Tty}
            end;
        false when Char =:= $\s ->
            emit(<<$\b>>, Actions, back(1, Tty));
        false when Char =:= $\t ->
            %% The tab's width is what the line before it leaves to the
            %% column, within 1 to a tab's width.
            Before = line_width(Tty),
            Width = case Before >= Tty#tty.column of
                        true -> 1;
                        false -> min(?TAB_WIDTH, Tty#tty.column - Before)
                    end,
            emit(binary:copy(<<$\b>>, Width), Actions, Tty#tty{column = Before});
        false when Utf8 ->
            %% The rest of a UTF-8 character goes with its last byte.
            #units{bytes = Line} = Tty#tty.line,
            More = utf8_tail(<<Line/binary, Char>>) - 1,
            emit(<<"\b \b">>, Actions, back(1, shorten(byte_size(Line) - More, Tty)));
        false ->
            emit(<<"\b \b">>, Actions, back(1, Tty))
    end.

%% The length of the valid UTF-8 character that ends Bytes, else 1.
utf8_tail(Bytes) ->
    Size = byte_size(Bytes),
    case [N || N <- [2, 3, 4], N =< Size,
               one_character(binary:part(Bytes, Size - N, N))] of
        [N] -> N;
        [] -> 1
    end.

one_character(<<_/utf8>>) -> true;
one_character(_) -> false.

%% VREPRINT and a newline, then the line again, as FreeBSD's
%% ttydisc_reprint (tty_ttydisc.c:786-799), but the walk ends at its first
%% piece that does not fit the room. FreeBSD echoes every piece and its
%% output queue drops each that does not fit, so each VREPRINT costs the
%% whole line; a master that reads nothing and sends VREPRINT over and
%% over, with a little room left, then costs the owner a walk of the line
%% per key. Ending the walk there bounds each VREPRINT by the room it
%% fills, but for pieces that render to nothing. What reaches the master
%% differs from FreeBSD's only in the smaller pieces that would still fit
%% after the first that does not, and those make no sense on the screen
%% without it. With ECHO clear no character of a cooked line echoes (it
%% holds no newline), so the line is not walked.
reprint(Actions, Tty) ->
    Keys = case char(vreprint, Tty) of
               ?VDISABLE -> [$\n];
               Reprint -> [Reprint, $\n]
           end,
    {Fit, Ended, Tty1} = retype(Keys, Actions, Tty),
    Line = case Fit andalso on(echo, Tty) of
               true -> binary_to_list((Tty1#tty.line)#units.bytes);
               false -> []
           end,
    {_, Retyped, Tty2} = retype(Line, Ended, Tty1#tty{reprintpos = 0}),
    {Retyped, Tty2}.

%% Echoes Chars in order up to the first piece that does not fit, which
%% moves the column as any dropped echo does, and says whether all fit.
%% The column then leaves out the rest of the line, which was not shown.
retype([], Actions, Tty) ->
    {true, Actions, Tty};
retype([Char | Rest], Actions, Tty) ->
    {Bytes, Tty1} = echoed(Char, Tty),
    case put_echo(Bytes, Actions, Tty1) of
        {true, Echoed, Tty2} -> retype(Rest, Echoed, Tty2);
        {false, _, _} = Cut -> Cut
    end.

%% Where the column was before the line's last character: the column of
%% the last write plus the width of what was echoed since.
line_width(#tty{line = #units{bytes = Line}, reprintpos = Shown, writepos = Start} = Tty) ->
    <<_:Shown/binary, Echoed/binary>> = Line,
    Caret = case on(echoctl, Tty) of
                true -> 2;
                false -> 0
            end,
    lists:foldl(fun($\t, Width) -> Width + ?TAB_WIDTH - Width rem ?TAB_WIDTH;
                   (Char, Width) ->
                        case caret(Char) of
                            true -> Width + Caret;
                            false -> Width + 1
                        end
                end, Start, binary_to_list(Echoed)).

%% The line cut to its first Keep bytes.
shorten(Keep, #tty{line = Line, reprintpos = Shown} = Tty) ->
    Tty#tty{line = truncate(Line, Keep), reprintpos = min(Shown, Keep)}.

back(Width, #tty{column = Column} = Tty) ->
    Tty#tty{column = max(0, Column - Width)}.

last(#tty{line = #units{bytes = <<>>}}) -> none;
last(#tty{line = #units{bytes = Line}}) -> binary:last(Line).

white(Char) -> Char =:= $\s orelse Char =:= $\t.

alnum(Char) ->
    (Char >= $0 andalso Char =< $9) orelse (Char >= $a andalso Char =< $z)
        orelse (Char >= $A andalso Char =< $Z).

%%% Echo and output rendering (tty_ttydisc.c:452-536, :725-776)

echo(Char, Actions, Tty) ->
    {Bytes, Tty1} = echoed(Char, Tty),
    emit(Bytes, Actions, Tty1).

%% What echo makes of Char: ECHO echoes every byte, ECHONL alone a newline.
echoed(Char, Tty) ->
    case on(echo, Tty) orelse (Char =:= $\n andalso on(echonl, Tty)) of
        true -> render(Char, Tty);
        false -> {<<>>, Tty}
    end.

%% Every echo goes through here: a piece that does not fit what is left of
%% the room is dropped whole and leaves the room as it was, as
%% ttyoutq_write_nofrag drops it (tty_outq.c:322-334). The room left is
%% then a function of what was echoed, so input fed back with the room
%% its echo left echoes as input a byte at a time does. An empty piece
%% fits and adds nothing.
emit(Bytes, Actions, Tty) ->
    {_, Actions1, Tty1} = put_echo(Bytes, Actions, Tty),
    {Actions1, Tty1}.

%% emit/3 that also says whether the piece fit.
put_echo(<<>>, Actions, Tty) ->
    {true, Actions, Tty};
put_echo(Bytes, Actions, #tty{echo_room = Room} = Tty) when byte_size(Bytes) =< Room ->
    {true, [{echo, Bytes} | Actions], Tty#tty{echo_room = Room - byte_size(Bytes)}};
put_echo(_, Actions, Tty) ->
    {false, Actions, Tty}.

%% One byte for the screen: OPOST's processing for backspace, tab, newline
%% and carriage return; ECHOCTL's caret notation for another control
%% character, with VEOF backed over; anything else as it is.
render(Char, Tty) ->
    Post = on(opost, Tty) andalso lists:member(Char, [$\b, $\t, $\n, $\r]),
    Caret = on(echoctl, Tty) andalso caret(Char),
    if
        Post -> post(Char, Tty);
        Caret -> caret_notation(Char, Tty);
        true -> {<<Char>>, forward(1, Tty)}
    end.

caret(Char) ->
    Char =:= 16#7f orelse (Char < 16#20 andalso Char =/= $\t andalso Char =/= $\n).

caret_notation(Char, Tty) ->
    Letter = case Char of
                 16#7f -> $?;
                 _ -> Char + $A - 1
             end,
    case is_char(veof, Char, Tty) of
        true -> {<<$^, Letter, $\b, $\b>>, Tty};
        false -> {<<$^, Letter>>, forward(2, Tty)}
    end.

%% OPOST's processing of a control character.
post($\^D, Tty) ->
    case on(onoeot, Tty) of
        true -> {<<>>, Tty};
        false -> {<<$\^D>>, Tty}
    end;
post($\b, Tty) ->
    {<<$\b>>, back(1, Tty)};
post($\t, #tty{column = Column} = Tty) ->
    Width = ?TAB_WIDTH - Column rem ?TAB_WIDTH,
    Bytes = case on(tab3, Tty) of
                true -> binary:copy(<<$\s>>, Width);
                false -> <<$\t>>
            end,
    {Bytes, Tty#tty{column = Column + Width}};
post($\n, Tty) ->
    Bytes = case on(onlcr, Tty) of
                true -> <<"\r\n">>;
                false -> <<"\n">>
            end,
    case on(onlcr, Tty) orelse on(onlret, Tty) of
        true -> {Bytes, line_start(Tty)};
        false -> {Bytes, Tty}
    end;
post($\r, #tty{column = Column} = Tty) ->
    Byte = case on(ocrnl, Tty) of
               true -> $\n;
               false -> $\r
           end,
    case on(onocr, Tty) andalso Column =:= 0 of
        true -> {<<>>, Tty};
        false -> {<<Byte>>, line_start(Tty)}
    end;
post(Char, Tty) ->
    {<<Char>>, Tty}.

forward(Width, #tty{column = Column} = Tty) ->
    Tty#tty{column = Column + Width}.

line_start(#tty{line = #units{bytes = Line}} = Tty) ->
    Tty#tty{column = 0, writepos = 0, reprintpos = byte_size(Line)}.

%% After a write: the line echoed so far is behind it.
written(#tty{column = Column, line = #units{bytes = Line}} = Tty) ->
    Tty#tty{writepos = Column, reprintpos = byte_size(Line)}.

-doc """
A program's bytes for the master, with at most Room bytes to give. It
returns how many of Bytes it took and what they became. With OPOST clear
the bytes are themselves; with OPOST, each control character becomes what
its output flags make it (ttydisc_write_oproc), and a byte's rendering is
never split, so 4 KiB of newlines with ONLCR and 4 KiB of room takes 2 KiB.
Output stopped by VSTOP takes bytes as any other output does, as FreeBSD's
ttydisc_write fills the output queue whatever TF_STOPPED says
(sys/kern/tty_ttydisc.c:560-665): the owner holds them until output starts.
""".
-spec output(binary(), non_neg_integer(), tty()) ->
          {non_neg_integer(), binary(), tty()}.
output(Bytes, Room, Tty) when is_binary(Bytes), is_integer(Room), Room >= 0 ->
    case on(opost, Tty) of
        false ->
            Taken = min(Room, byte_size(Bytes)),
            <<Out:Taken/binary, _/binary>> = Bytes,
            {Taken, Out, wrote(Taken, forward(Taken, Tty), Tty)};
        true ->
            post_bytes(Bytes, Room, 0, [], Tty)
    end.

post_bytes(<<Byte, Rest/binary>>, Room, Taken, Acc, Tty) ->
    {Piece, Tty1} = case caret(Byte) orelse Byte =:= $\t orelse Byte =:= $\n of
                        true -> post(Byte, Tty);
                        false -> {<<Byte>>, forward(1, Tty)}
                    end,
    case byte_size(Piece) =< Room of
        true ->
            post_bytes(Rest, Room - byte_size(Piece), Taken + 1,
                       [Piece | Acc], written(Tty1));
        false ->
            post_bytes(<<>>, 0, Taken, Acc, Tty)
    end;
post_bytes(<<>>, _Room, Taken, Acc, Tty) ->
    {Taken, iolist_to_binary(lists:reverse(Acc)), Tty}.

wrote(0, _, Unchanged) -> Unchanged;
wrote(_, Tty, _) -> written(Tty).

-doc """
The bytes of a status line for the master, rendered as echo renders
(tty_putstrn). They start with a newline when the output column is not 0.
There are none when NOKERNINFO is set (sys/kern/tty.c:1542-1543), when Room
is under 256 bytes (tty.c:2057-2062), or when the line does not fit whole.
""".
-spec status(binary(), non_neg_integer(), tty()) -> {binary(), tty()}.
status(Line, Room, #tty{column = Column} = Tty) when is_binary(Line) ->
    case on(nokerninfo, Tty) orelse Room < ?STATUS_ROOM of
        true ->
            {<<>>, Tty};
        false ->
            Text = case Column of
                       0 -> Line;
                       _ -> <<$\n, Line/binary>>
                   end,
            {Pieces, Tty1} = lists:mapfoldl(fun render/2, Tty,
                                            binary_to_list(Text)),
            Bytes = iolist_to_binary(Pieces),
            case byte_size(Bytes) =< Room of
                true -> {Bytes, written(Tty1)};
                false -> {<<>>, Tty}
            end
    end.

%%% Readers

-doc """
A blocking read of Count bytes from Open starts to wait. The tty reports
`{ready, Open}` at once when the read can go on, and otherwise when it
can: with a timer started now for VMIN 0 and VTIME above 0, or for VMIN
and VTIME above 0 when bytes already wait. A raw read with VMIN above 0
can go on at Count bytes when Count is fewer than VMIN, as FreeBSD's read
returns once its buffer is full (tty_ttydisc.c:290, :331, :384). A wait of
the same open replaces it.
""".
-spec read_wait(open(), pos_integer(), tty()) -> {[action()], tty()}.
read_wait(Open, Count, Tty) when is_integer(Count), Count > 0 ->
    wait(Open, {read, Count}, Tty#tty{expired = lists:delete(Open, Tty#tty.expired)}).

-doc """
A poll of Open waits for input, with no timer: `{ready, Open}` comes when a
line is complete in cooked mode, or a byte waits in raw mode.
""".
-spec poll_wait(open(), tty()) -> {[action()], tty()}.
poll_wait(Open, Tty) ->
    wait(Open, poll, Tty).

-doc "Open waits no more, for a signal or a close, and its timer stops.".
-spec cancel(open(), tty()) -> {[action()], tty()}.
cancel(Open, Tty) ->
    unwait(Open, Tty#tty{expired = lists:delete(Open, Tty#tty.expired)}).

-doc """
A timer ended. If it is the current timer of a waiting read, the read can
go on; any other timer, cancelled or replaced, does nothing.
""".
-spec timer(timer(), tty()) -> {[action()], tty()}.
timer({Open, _} = Timer, #tty{waiters = Waiters, expired = Expired} = Tty) ->
    case Waiters of
        #{Open := {read, _, Timer}} ->
            {[{ready, Open}],
             Tty#tty{waiters = maps:remove(Open, Waiters),
                     expired = [Open | lists:delete(Open, Expired)]}};
        _ ->
            {[], Tty}
    end.

-doc """
Open reads at most Max units, at once, each loss given as one NUL at its
place. In cooked mode it gets the first line, or as much of it as fits,
with its newline or VEOL and without its VEOF, so VEOF at the start of a
line is `eof`, an end of file (ttydisc_read_canonical), and a loss and
VEOF are one NUL. In raw mode it gets what waits, up to Max. A read that
finds nothing gets `eof` once the tty has hung up, and no bytes in raw
mode with VMIN 0 when VTIME is 0 or its timer ended; otherwise `eagain`.
The end of file and an empty raw read stay apart because an Erlang
command's read returns `eof` for one and `<<>>` for the other.
""".
-spec read(open(), non_neg_integer(), tty()) ->
          {{ok, binary()} | eof | eagain, tty()}.
read(_Open, 0, Tty) ->
    {{ok, <<>>}, Tty};
read(Open, Max, Tty) when is_integer(Max), Max > 0 ->
    case consume(Open, Max, Tty) of
        {{ok, Units}, Tty1} -> {{ok, with_nuls(Units)}, Tty1};
        Other -> Other
    end.

-doc """
Open reads one unit, as read/3 reads one byte, but a loss is `lost`
rather than a NUL: the read of a line editor, which refuses a line that
lost input (docs/design-live.md, "Lost input"). A read that finds nothing
is `eagain` whatever VMIN is, since a line editor has no use for an empty
read.
""".
-spec read_input(open(), tty()) -> {{ok, <<_:8>>} | lost | eof | eagain, tty()}.
read_input(Open, Tty) ->
    case consume(Open, 1, Tty) of
        {{ok, #units{losses = [_]}}, Tty1} -> {lost, Tty1};
        {{ok, #units{bytes = <<>>}}, Tty1} -> {eagain, Tty1};
        {{ok, #units{bytes = Bytes}}, Tty1} -> {{ok, Bytes}, Tty1};
        Other -> Other
    end.

%% The one step both reads take input by: at most Max units from the front
%% of what a read can take, up to the first line's end when cooked.
consume(Open, Max, #tty{expired = Expired} = Tty0) ->
    Tty = Tty0#tty{expired = lists:delete(Open, Expired)},
    case on(icanon, Tty) of
        true -> read_line(Max, Tty);
        false -> read_raw(Max, lists:member(Open, Expired), Tty)
    end.

read_line(Max, #tty{ready = Ready, hungup = Hungup} = Tty) ->
    case line_end(Tty) of
        none when Hungup ->
            {eof, Tty};
        none ->
            {eagain, Tty};
        {Length, Eof} ->
            Data = case Eof of
                       true -> Length - 1;
                       false -> Length
                   end,
            Taken = min(Max, Data),
            Consumed = case Eof andalso Taken =:= Data of
                           true -> Length;
                           false -> Taken
                       end,
            {Got, Behind} = take(Ready, Taken),
            {_, Rest} = take(Behind, Consumed - Taken),
            Answer = case count(Got) of
                         0 -> eof;
                         _ -> {ok, Got}
                     end,
            {Answer, Tty#tty{ready = Rest}}
    end.

read_raw(Max, Expired, #tty{ready = Ready, hungup = Hungup} = Tty) ->
    Empty = char(vmin, Tty) =:= 0 andalso (char(vtime, Tty) =:= 0 orelse Expired),
    case min(Max, count(Ready)) of
        0 when Hungup ->
            {eof, Tty};
        0 when Empty ->
            {{ok, #units{}}, Tty};
        0 ->
            {eagain, Tty};
        Taken ->
            {Got, Rest} = take(Ready, Taken),
            {{ok, Got}, Tty#tty{ready = Rest}}
    end.

wait(Open, Kind, Tty0) ->
    {Cancelled, Tty} = unwait(Open, Tty0),
    case ready_for(Kind, Tty) of
        true ->
            {Cancelled ++ [{ready, Open}], Tty};
        false ->
            {Armed, Tty1} = arm(Open, Kind, Tty),
            {Cancelled ++ Armed, Tty1}
    end.

unwait(Open, #tty{waiters = Waiters} = Tty) ->
    case maps:take(Open, Waiters) of
        {{read, _, {_, _} = Timer}, Rest} ->
            {[{timer_cancel, Timer}], Tty#tty{waiters = Rest}};
        {_, Rest} ->
            {[], Tty#tty{waiters = Rest}};
        error ->
            {[], Tty}
    end.

arm(Open, poll, #tty{waiters = Waiters} = Tty) ->
    {[], Tty#tty{waiters = Waiters#{Open => poll}}};
arm(Open, {read, Count}, #tty{waiters = Waiters, ready = Ready} = Tty) ->
    Timed = raw_timer(Tty) andalso
        (char(vmin, Tty) =:= 0 orelse count(Ready) > 0),
    case Timed of
        true -> start_timer(Open, Count, Tty);
        false -> {[], Tty#tty{waiters = Waiters#{Open => {read, Count, none}}}}
    end.

start_timer(Open, Count, #tty{serial = Serial, waiters = Waiters} = Tty) ->
    Timer = {Open, Serial},
    {[{timer_start, Timer, char(vtime, Tty) * 100}],
     Tty#tty{serial = Serial + 1, waiters = Waiters#{Open => {read, Count, Timer}}}}.

raw_timer(Tty) ->
    not on(icanon, Tty) andalso char(vtime, Tty) > 0.

%% POSIX's four cases for a read, at most its count, one unit for a poll, a
%% line when cooked.
-spec ready_for(kind(), tty()) -> boolean().
ready_for(_, #tty{hungup = true}) ->
    true;
ready_for(Kind, #tty{ready = Ready} = Tty) ->
    case on(icanon, Tty) of
        true -> line_end(Tty) =/= none;
        false -> count(Ready) >= wanted(Kind, Tty)
    end.

wanted(poll, _) ->
    1;
wanted({read, Count}, Tty) ->
    case {char(vmin, Tty), char(vtime, Tty)} of
        {0, 0} -> 0;
        {0, _} -> 1;
        {Min, _} -> min(Min, Count)
    end.

%% After input: each waiter whose condition holds is ready. A raw read with
%% VMIN and VTIME above 0 that still waits starts its timer when its first
%% byte arrives, and keeps that one deadline as more bytes arrive, as
%% FreeBSD's ttydisc_read_raw_interbyte_timer sets it once after the first
%% byte (tty_ttydisc.c:360-405, :306-320); a flush that left nothing stops it.
settle(Arrived, #tty{waiters = Waiters} = Tty0) ->
    lists:foldl(fun({Open, Waiter}, {Actions, Tty}) ->
                        {More, Tty1} = settle(Open, Waiter, Arrived, Tty),
                        {Actions ++ More, Tty1}
                end, {[], Tty0}, lists:sort(maps:to_list(Waiters))).

settle(Open, Waiter, Arrived, #tty{ready = Ready} = Tty) ->
    Kind = kind(Waiter),
    Interbyte = Kind =/= poll andalso raw_timer(Tty) andalso char(vmin, Tty) > 0,
    Held = count(Ready) > 0,
    case ready_for(Kind, Tty) of
        true ->
            {Cancelled, Tty1} = unwait(Open, Tty),
            {Cancelled ++ [{ready, Open}], Tty1};
        false when Interbyte, Arrived, Held, element(3, Waiter) =:= none ->
            start_timer(Open, element(2, Waiter), Tty);
        false when Interbyte, not Held, element(3, Waiter) =/= none ->
            {Cancelled, Tty1} = unwait(Open, Tty),
            Untimed = (Tty1#tty.waiters)#{Open => setelement(3, Waiter, none)},
            {Cancelled, Tty1#tty{waiters = Untimed}};
        false ->
            {[], Tty}
    end.

%% Every waiter waits again, as it would start now.
rewait(#tty{waiters = Waiters} = Tty0) ->
    lists:foldl(fun({Open, Waiter}, {Actions, Tty}) ->
                        {More, Tty1} = wait(Open, kind(Waiter), Tty),
                        {Actions ++ More, Tty1}
                end, {[], Tty0}, lists:sort(maps:to_list(Waiters))).

kind(poll) -> poll;
kind({read, Count, _}) -> {read, Count}.

%%% termios lookups

on(Flag, #tty{termios = #{iflag := I, oflag := O, cflag := C, lflag := L}}) ->
    lists:member(Flag, L) orelse lists:member(Flag, I) orelse
        lists:member(Flag, O) orelse lists:member(Flag, C).

char(Name, #tty{termios = #{cc := Chars}}) ->
    maps:get(Name, Chars).

%% A special character matches only when it is not disabled.
is_char(Name, Char, Tty) ->
    case char(Name, Tty) of
        ?VDISABLE -> false;
        Value -> Value =:= Char
    end.

%% The ends of a cooked line: newline, VEOF and VEOL, as FreeBSD's
%% ttydisc_read_break has them; VEOL2 is not one.
is_end(Char, Tty) ->
    Char =:= $\n orelse is_char(veof, Char, Tty) orelse is_char(veol, Char, Tty).

%% The first line in `ready`: its length in units with its end, and
%% whether the end is VEOF. The losses before its end byte are its own.
line_end(#tty{ready = #units{bytes = Bytes, losses = Losses}} = Tty) ->
    case first_end(Bytes, 0, Tty) of
        none ->
            none;
        At ->
            {At + 1 + length([L || L <- Losses, L =< At]),
             is_char(veof, binary:at(Bytes, At), Tty)}
    end.

first_end(<<Char, Rest/binary>>, Position, Tty) ->
    case is_end(Char, Tty) of
        true -> Position;
        false -> first_end(Rest, Position + 1, Tty)
    end;
first_end(<<>>, _, _) ->
    none.

%%% Held input as units: bytes and the losses among them

count(#units{bytes = Bytes, losses = Losses}) ->
    byte_size(Bytes) + length(Losses).

append(#units{bytes = Held} = Units, Bytes) ->
    Units#units{bytes = <<Held/binary, Bytes/binary>>}.

append_loss(#units{bytes = Bytes, losses = Losses} = Units) ->
    Units#units{losses = Losses ++ [byte_size(Bytes)]}.

ends_lost(#units{bytes = Bytes, losses = Losses}) ->
    Losses =/= [] andalso lists:last(Losses) =:= byte_size(Bytes).

%% A then B: a loss that ends A and one that starts B are one.
join(#units{bytes = A, losses = LossesA}, #units{bytes = B, losses = LossesB}) ->
    Size = byte_size(A),
    #units{bytes = <<A/binary, B/binary>>,
           losses = lists:usort(LossesA ++ [L + Size || L <- LossesB])}.

%% Split before the byte at Cut; a loss there is the second part's.
split(#units{bytes = Bytes, losses = Losses}, Cut) ->
    {Before, After} = lists:splitwith(fun(L) -> L < Cut end, Losses),
    <<Front:Cut/binary, Back/binary>> = Bytes,
    {#units{bytes = Front, losses = Before},
     #units{bytes = Back, losses = [L - Cut || L <- After]}}.

%% The first N units, N at most count(Units), and the rest, each loss
%% named from the rest's own start.
take(#units{bytes = Bytes, losses = Losses}, N) ->
    {Size, Lost} = units_in(Losses, 0, 0, N),
    {Taken, Kept} = lists:split(Lost, Losses),
    <<Front:Size/binary, Back/binary>> = Bytes,
    {#units{bytes = Front, losses = Taken},
     #units{bytes = Back, losses = [L - Size || L <- Kept]}}.

%% How many bytes and losses the first N units hold, Size bytes and Lost
%% losses counted so far.
units_in(_, Size, Lost, 0) ->
    {Size, Lost};
units_in([Size | Losses], Size, Lost, N) ->
    units_in(Losses, Size, Lost + 1, N - 1);
units_in([Next | _] = Losses, Size, Lost, N) ->
    Step = min(N, Next - Size),
    units_in(Losses, Size + Step, Lost, N - Step);
units_in([], Size, Lost, N) ->
    {Size + N, Lost}.

%% The first Keep bytes, the losses after them kept as one at the new end;
%% nothing when no byte is kept.
truncate(_, 0) ->
    #units{};
truncate(#units{bytes = Bytes, losses = Losses}, Keep) ->
    <<Front:Keep/binary, _/binary>> = Bytes,
    #units{bytes = Front, losses = lists:usort([min(L, Keep) || L <- Losses])}.

%% The units as a read gives them, each loss one NUL.
with_nuls(#units{bytes = Bytes, losses = Losses}) ->
    {Pieces, Last} = lists:mapfoldl(fun(L, From) -> {[binary:part(Bytes, From, L - From), 0], L} end,
                                    0, Losses),
    iolist_to_binary([Pieces, binary:part(Bytes, Last, byte_size(Bytes) - Last)]).

merge([{echo, <<>>} | Rest]) -> merge(Rest);
merge([{echo, A}, {echo, B} | Rest]) -> merge([{echo, <<A/binary, B/binary>>} | Rest]);
merge([Action | Rest]) -> [Action | merge(Rest)];
merge([]) -> [].
