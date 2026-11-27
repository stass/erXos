%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_btpair).
-moduledoc """
`btpair display | nodisplay`: open the Bluetooth domain's pairing window
and print what it says until it ends (docs/design-bluetooth.md, "The
pairing window"). The command shell has no redirection that opens one file
for reading and writing, and a window is one open file, so a person drives
it with this command. FreeBSD has no command of this name or shape.

It opens the control tree's `pair` through erx_svc_client:open/3, raw,
for reading and writing in binary mode, so the command's own process holds
the file and each read asks the server for no more than the reader asks.
It sets no deadline: the window ends itself after `bt_pair_window_s`, and
the command's own end, an interrupt's included, closes the file and so
the window. It writes the mode once, `display` or `nodisplay`, and then
prints each line it reads through erx_bt_pair:next/1, which never holds
more than `bt_pair_line_max + 1` octets.

The lines are another domain's words, so a line is printed only as
erx_bt_pair:format/1 composes it again from what erx_bt_pair:parse/1
read, and through the field escape (erx_text:escape_field/1), as every
command prints text from another source; a line that does not parse
prints `[invalid]` in its place and the reading goes on. A stream with
no newline within the bound prints `[invalid]` and the file is closed at
once.

Status. A `bonded` line followed by the file's normal end succeeds. A
`failed` line, `closed timeout`, a line that does not parse, an overlong
line, a file error and the end of the file with no outcome each fail
with status 1; an open, write or read error is printed as
`btpair: reason`, and a tree `/svc` does not hold as
`btpair: bluetooth not running?`, as `service` prints it. Nothing is written twice: a write
that fails, or whose answer is lost, is reported and not retried.

Authority. The command needs the `bluetooth` tree, so a session whose
template grants none refuses it with the shell's `no_facet` before it
starts. It starts nothing of the Bluetooth stack: erx_bt_client, which
holds erx_bt_pair, is a library.

parse/1 and outcome/2 decide; window/3 is the effect over an opened file.
""".
-behaviour(erx_cmd).

-erx_command(btpair).
-erx_usage("btpair display | nodisplay").
-erx_needs([bluetooth]).

-export([run/2]).
-export([parse/1, outcome/2, window/3]).
-export_type([mode/0, outcome/0]).

-doc "The window a command asks for: `display` shows a passkey, `nodisplay` pairs with none.".
-type mode() :: display | nodisplay.
-doc """
What a window has said so far: no outcome yet (`none`), a bond, or something
that fails the command whatever follows.
""".
-type outcome() :: none | bonded | failed.

-define(FAILED, {error, {reported, <<"1">>}}).

-doc false.
run(Args, Ctx) ->
    case parse(Args) of
        {ok, Mode} ->
            case erx_svc_client:open(<<"bluetooth">>, <<"pair">>, [read, write, raw, binary]) of
                {ok, File} -> window(File, Mode, Ctx);
                not_serving -> failed(Ctx, <<"bluetooth not running?">>);
                {error, Reason} -> failed(Ctx, erx_cmd:format_error(Reason))
            end;
        {error, usage} = Usage ->
            Usage
    end.

-doc "The mode command line Args asks for, or a usage error.".
-spec parse([binary()]) -> {ok, mode()} | {error, usage}.
parse([<<"display">>]) -> {ok, display};
parse([<<"nodisplay">>]) -> {ok, nodisplay};
parse(_Args) -> {error, usage}.

-doc """
What a window has said once it says Line, a term of erx_bt_pair:parse/1, after
Outcome: `bonded` is a bond; a failure, a timeout or a line that does not parse
fails it for good; every other line leaves it as it was.
""".
-spec outcome(outcome(), erx_bt_pair:line() | invalid) -> outcome().
outcome(failed, _Line) -> failed;
outcome(_Outcome, {bonded, _Bond}) -> bonded;
outcome(_Outcome, {failed, _Address, _Reason}) -> failed;
outcome(_Outcome, {closed, timeout}) -> failed;
outcome(_Outcome, invalid) -> failed;
outcome(Outcome, _Progress) -> Outcome.

-doc """
Drives the window opened as File in Mode: writes the mode once, prints each line
until the file ends, and closes File whatever happens, a write to standard output
that ends the command included.
""".
-spec window(file:io_device(), mode(), erx_cmd:ctx()) -> ok | {error, {reported, binary()}}.
window(File, Mode, Ctx) ->
    try file:write(File, <<(atom_to_binary(Mode))/binary, $\n>>) of
        ok -> lines(erx_bt_pair:reader(File), none, Ctx);
        {error, Reason} -> failed(Ctx, erx_cmd:format_error(Reason))
    after
        file:close(File)
    end.

%% Each line to the file's end, then the status Outcome gives.
lines(Reader, Outcome, Ctx) ->
    case erx_bt_pair:next(Reader) of
        {line, Line, Next} ->
            Term = erx_bt_pair:parse(Line),
            ok = erx_cmd:write(Ctx, [shown(Term), $\n]),
            lines(Next, outcome(Outcome, Term), Ctx);
        eof when Outcome =:= bonded ->
            ok;
        eof ->
            ?FAILED;
        overlong ->
            ok = erx_cmd:write(Ctx, <<"[invalid]\n">>),
            ?FAILED;
        {error, Reason} ->
            failed(Ctx, erx_cmd:format_error(Reason))
    end.

%% What a line shows: the line format/1 composes from its term, or `[invalid]`.
shown(invalid) -> <<"[invalid]">>;
shown(Term) -> erx_text:escape_field(erx_bt_pair:format(Term)).

failed(#{name := Name} = Ctx, Text) ->
    ok = erx_cmd:say(Ctx, [Name, <<": ">>, Text, $\n]),
    ?FAILED.
