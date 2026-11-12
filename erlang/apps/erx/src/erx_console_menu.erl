%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_console_menu).
-moduledoc """
The pure core of a console line's Ctrl-G menu (docs/design-live.md, "The
console", Job control): what it lists, what it draws and what each key does.
erx_console owns the line and carries out the action.

The menu lists the system shell, each live session of the line's principal,
by domain id, and an entry that starts a session. A session is live when its
domain pid is up and the console can connect it: its tty is named and has
passed every check. The system shell's key is `s`, the sessions' are `1` to
`9` and then the letters but `n` and `s`, and `n` starts a session; a
principal with more sessions than keys sees how many are not listed. Esc or
Ctrl-G returns the line to the session that had it when Ctrl-G was typed, while
the menu lists it, and otherwise to the system shell; that entry is marked `*`.

A key is one read of one byte, read while the input is in no string, escape or
control sequence a terminal is sending (erx_console_keys). A read of more than one byte is never
a key a person typed (an arrow key, a paste or a terminal's reply), nor is a
byte of a reply read alone, and either only rings the bell, as does any other
byte. The menu reaches only the sessions it lists, so a key never connects a
session of another principal or one whose domain is down.

The menu's text is the console's own; each session's name is attributed text,
the session creator's, and is drawn through the line escape (erx_text).
""".

-export([open/3, back/1, shows/2, text/1, key/3, keys/0]).
-export_type([menu/0, session/0, owner/0, action/0]).

-define(ESC, 16#1B).
-define(BEL, 16#07).
%% The sessions' keys, in order: the digits, then the letters but the menu's own.
-define(KEYS, <<"123456789abcdefghijklmopqrtuvwxyz">>).

%% A session as the console reports it: its domain id, name and principal, and whether
%% it is live (its domain pid is up and the console can connect it).
-type session() :: #{domain := pos_integer(), name := binary(), principal := pos_integer(),
                     live := boolean()}.
%% Who has a line: the console's own groups, the system shell, or a domain's session.
-type owner() :: system | {session, pos_integer()}.
%% What a key asks the console for: the line for the system shell or a session, a new
%% session for the line's principal, or the bell, the menu staying open.
-type action() :: system | {connect, pos_integer()} | start | bell.

-record(menu, {%% The listed sessions with their keys, by domain id.
               entries :: [{byte(), pos_integer(), binary()}],
               %% How many live sessions of the principal have no key.
               unlisted :: non_neg_integer(),
               %% Where Esc returns the line.
               back :: owner()}).
-opaque menu() :: #menu{}.

-doc """
The menu of a line whose principal is Principal, over Sessions, the console's, opened
while Back had the line. A line whose principal is unknown lists no session.
""".
-spec open(pos_integer() | unknown, [session()], owner()) -> menu().
open(Principal, Sessions, Back) ->
    Live = lists:sort([{Domain, Name} || #{domain := Domain, name := Name, principal := P, live := true} <- Sessions,
                                         P =:= Principal]),
    {Keyed, Unkeyed} = lists:split(min(length(Live), byte_size(?KEYS)), Live),
    Keys = lists:sublist(binary_to_list(?KEYS), length(Keyed)),
    #menu{entries = [{Key, Domain, Name} || {Key, {Domain, Name}} <- lists:zip(Keys, Keyed)],
          unlisted = length(Unkeyed),
          back = Back}.

-doc "Who had the line when Menu opened.".
-spec back(menu()) -> owner().
back(#menu{back = Back}) -> Back.

-doc "The sessions' keys, in the order the menu gives them.".
-spec keys() -> binary().
keys() -> ?KEYS.

-doc """
Whether Menu shows domain Domain's session: as an entry, or as the one Esc returns to.
Only then does the session's end concern the line.
""".
-spec shows(pos_integer(), menu()) -> boolean().
shows(Domain, #menu{entries = Entries, back = Back}) ->
    lists:keymember(Domain, 2, Entries) orelse Back =:= {session, Domain}.

-doc """
The menu as the line shows it: its lines, each ending in CR-LF. The entry Esc returns to
is marked.
""".
-spec text(menu()) -> iodata().
text(Menu = #menu{entries = Entries, unlisted = Unlisted}) ->
    Return = return(Menu),
    Sessions = [entry(Key, Return =:= {connect, Domain},
                      [erx_text:escape_line(Name), <<" (domain ">>, integer_to_binary(Domain), <<")">>])
                || {Key, Domain, Name} <- Entries],
    More = [[<<"     ">>, integer_to_binary(Unlisted), <<" more sessions, not listed\r\n">>] || Unlisted > 0],
    [<<"erx_console: Ctrl-G menu\r\n">>,
     entry($s, Return =:= system, <<"system shell">>),
     Sessions, More,
     entry($n, false, <<"start a session">>),
     <<"Esc returns. ">>].

entry(Key, Current, Label) ->
    [<<"  ", Key, (mark(Current)), " ">>, Label, <<"\r\n">>].

mark(true) -> $*;
mark(false) -> $\s.

-doc """
What Read, one read of the line's input while the menu has it, asks for, given Before,
the input's escape state (erx_console_keys) before it, and that state after it. A key is
a read of one byte in the ground state; in any other state the byte belongs to a string,
an escape or a control sequence a terminal is sending, and is no key, but for Esc after
an escape, which no terminal sends. Anything else only rings the bell. The state after
Esc stays an escape, as the parser sees it: if the Esc was a reply's first byte, cut
from the rest, the reply's BEL stays the reply's.
""".
-spec key(binary(), erx_console_keys:state(), menu()) -> {action(), erx_console_keys:state()}.
key(Read, Before, Menu) ->
    {_Pieces, After} = erx_console_keys:split(Read, Before),
    case {Read, Before} of
        {<<Key>>, ground} -> {action(Key, Menu), After};
        {<<?ESC>>, escape} -> {action(?ESC, Menu), After};
        _ -> {bell, After}
    end.

action($s, #menu{}) ->
    system;
action($n, #menu{}) ->
    start;
action(Back, Menu) when Back =:= ?ESC; Back =:= ?BEL ->
    return(Menu);
action(Key, #menu{entries = Entries}) ->
    case lists:keyfind(Key, 1, Entries) of
        {Key, Domain, _Name} -> {connect, Domain};
        false -> bell
    end.

%% Esc returns the line to the session that had it while the menu lists it, and otherwise
%% to the system shell.
return(#menu{back = {session, Domain}, entries = Entries}) ->
    case lists:keymember(Domain, 2, Entries) of
        true -> {connect, Domain};
        false -> system
    end;
return(#menu{back = system}) ->
    system.
