%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_ls).
-moduledoc """
`ls [-1al] [file ...]`: FreeBSD's ls (bin/ls) with a small core of its
options (docs/design-live.md, "The command shell").

It lists a file by the name given and a directory by the names it holds,
the working directory's for no operand, sorted byte by byte, without
those that start with `.` unless `-a` is given. With more than one
operand, files come first, and each directory's names follow an empty
line and a line with its name and `:`.

At a terminal (erx_cmd:isatty/2) it writes the names in columns across
the terminal's width (erx_cmd:columns/1, 80 when unknown), sorted down
the columns and separated by tabs, as FreeBSD's printcol() does
(bin/ls/print.c); elsewhere, or under `-1`, one name a line. `-l` writes
FreeBSD's long format: a `total` line for each directory, then for each
name its mode, link count, owner, group, size, modification time and
name, the time with the hour and minute within six months of now and the
year otherwise, in UTC. Owner and group are numbers, as FreeBSD's `-n`
writes them, since no user database exists. A value the file server does
not report prints `-` in its column: the `total` line's block count,
which `file` does not give, and an owner or group the file server keeps
none of.

A name is written through the line escape at a terminal and as its bytes
elsewhere, as FreeBSD's writes `?` for a character that does not print
at a terminal only (bin/ls/ls.c). Status, as FreeBSD's: 1 when an
operand or a directory could not be read, each reported as `ls: name:
reason`.
""".

-behaviour(erx_cmd).
-erx_command(ls).
-erx_usage("ls [-1al] [file ...]").

-export([run/2]).
-export([columns/2, long/2]).

-include_lib("kernel/include/file.hrl").

-define(TAB, 8).
-define(SIX_MONTHS, (182 * 86400)).

run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "1al") of
        {ok, Flags, Operands} ->
            Tty = erx_cmd:isatty(Ctx, stdout),
            Options = #{all => lists:member($a, Flags), long => lists:member($l, Flags),
                        across => Tty andalso not lists:member($1, Flags), tty => Tty,
                        width => case erx_cmd:columns(Ctx) of unknown -> 80; W -> W end,
                        now => os:system_time(second)},
            list(case Operands of [] -> [<<".">>]; _ -> Operands end, Options, Ctx);
        {error, usage} ->
            {error, usage}
    end.

list(Operands, Options, Ctx) ->
    Infos = [{Name, file:read_link_info(erx_cmd:path(Ctx, Name), [{time, posix}])} || Name <- Operands],
    Missing = [report(Ctx, Name, Reason) || {Name, {error, Reason}} <- Infos],
    Files = lists:sort([{Name, Info} || {Name, {ok, #file_info{type = Type} = Info}} <- Infos,
                                        Type =/= directory]),
    Dirs = lists:sort([Name || {Name, {ok, #file_info{type = directory}}} <- Infos]),
    Files =/= [] andalso print(Files, false, Options, Ctx),
    Headed = length(Operands) > 1,
    Unread = [Dir || {Index, Dir} <- lists:enumerate(Dirs),
                     directory(Dir, Headed, Index =:= 1 andalso Files =:= [], Options, Ctx) =:= error],
    case Missing ++ Unread of
        [] -> ok;
        _ -> {error, {reported, <<"1">>}}
    end.

report(Ctx, Name, Reason) ->
    erx_cmd:say(Ctx, [<<"ls: ">>, Name, <<": ">>, erx_cmd:format_error(Reason), $\n]),
    Name.

%% A directory's names, after its heading when there are several operands,
%% the first heading with no empty line before it.
directory(Dir, Headed, First, Options, Ctx) ->
    Path = erx_cmd:path(Ctx, Dir),
    case file:list_dir(Path) of
        {ok, Raw} ->
            Headed andalso erx_cmd:write(Ctx, [[$\n || not First], shown(Dir, Options), <<":\n">>]),
            Names = lists:sort([Name || Name <- lists:map(fun binary_name/1, Raw),
                                        maps:get(all, Options) orelse binary:first(Name) =/= $.]),
            Entries = [{Name, info(erx_cmd:path(Path, Name))} || Name <- Names],
            print(Entries, true, Options, Ctx),
            ok;
        {error, Reason} ->
            report(Ctx, Dir, Reason),
            error
    end.

info(Path) ->
    case file:read_link_info(Path, [{time, posix}]) of
        {ok, Info} -> Info;
        {error, _} -> unknown
    end.

print(Entries, InDirectory, #{long := true} = Options, Ctx) ->
    erx_cmd:write(Ctx, [[<<"total -\n">> || InDirectory],
                        long([{shown(Name, Options), Info} || {Name, Info} <- Entries], Options)]);
print(Entries, _InDirectory, #{across := true, width := Width} = Options, Ctx) ->
    erx_cmd:write(Ctx, columns([shown(Name, Options) || {Name, _} <- Entries], Width));
print(Entries, _InDirectory, Options, Ctx) ->
    erx_cmd:write(Ctx, [[shown(Name, Options), $\n] || {Name, _} <- Entries]).

%% A name as it is written: escaped at a terminal, its bytes elsewhere.
shown(Name, #{tty := true}) -> erx_text:escape_line(Name);
shown(Name, #{tty := false}) -> Name.

binary_name(Name) when is_binary(Name) -> Name;
binary_name(Name) -> unicode:characters_to_binary(Name).

%%% The pure layouts

-doc """
Names, each already escaped for the terminal, in columns across Width,
sorted down the columns, as FreeBSD's printcol(): each column is as wide
as the longest name rounded up past the next tab stop, and a row reaches
the next column with tabs; when two columns do not fit, one name a line.
""".
-spec columns([binary()], pos_integer()) -> iodata().
columns([], _Width) ->
    [];
columns(Names, Width) ->
    Max = lists:max([string:length(Name) || Name <- Names]),
    ColWidth = (Max + ?TAB) band bnot (?TAB - 1),
    case Width < 2 * ColWidth of
        true ->
            [[Name, $\n] || Name <- Names];
        false ->
            Count = length(Names),
            NumCols = Width div ColWidth,
            NumRows = (Count + NumCols - 1) div NumCols,
            Array = list_to_tuple(Names),
            [row([element(Base + 1, Array) || Base <- lists:seq(Row, Count - 1, NumRows)], ColWidth)
             || Row <- lists:seq(0, NumRows - 1)]
    end.

%% A row's names, each but the last followed by tabs to its column's end.
row(Names, ColWidth) ->
    {Text, _} = lists:foldl(fun(Name, {Acc, Col}) ->
                                    Chars = string:length(Name),
                                    {[Acc, Name, tabs(Col * ColWidth + Chars, (Col + 1) * ColWidth)], Col + 1}
                            end, {[], 0}, lists:droplast(Names)),
    [Text, lists:last(Names), $\n].

%% The tabs from column At to the last tab stop at or before End.
tabs(At, End) ->
    Next = (At + ?TAB) band bnot (?TAB - 1),
    case Next =< End of
        true -> [$\t | tabs(Next, End)];
        false -> []
    end.

-doc """
Names and their file information in FreeBSD's long format, printlong()'s
columns: mode, link count, owner, group, size, time and name, with `-`
for what the file server did not report.
""".
-spec long([{binary(), #file_info{} | unknown}], #{now := integer(), _ => _}) -> iodata().
long([], _Options) ->
    [];
long(Entries, #{now := Now}) ->
    Rows = [fields(Info, Now) ++ [Name] || {Name, Info} <- Entries],
    [Links, Owner, Group, Size] = [lists:max([string:length(lists:nth(I, Row)) || Row <- Rows])
                                   || I <- [2, 3, 4, 5]],
    [[Mode, $\s, pad(right, L, Links), $\s, pad(left, U, Owner), $\s, pad(left, G, Group), $\s,
      pad(right, S, Size), $\s, Time, $\s, Name, $\n]
     || [Mode, L, U, G, S, Time, Name] <- Rows].

fields(unknown, _Now) ->
    [<<"?--------- ">>, <<"-">>, <<"-">>, <<"-">>, <<"-">>, <<"-">>];
fields(#file_info{} = Info, Now) ->
    [mode(Info), number(Info#file_info.links), number(Info#file_info.uid),
     number(Info#file_info.gid), number(Info#file_info.size), time(Info#file_info.mtime, Now)].

number(N) when is_integer(N), N >= 0 -> integer_to_binary(N);
number(_Missing) -> <<"-">>.

pad(left, Text, Width) -> [Text, binary:copy(<<" ">>, max(0, Width - string:length(Text)))];
pad(right, Text, Width) -> [binary:copy(<<" ">>, max(0, Width - string:length(Text))), Text].

%% strmode(3): the type, three triplets with the set-id and sticky bits,
%% and a space where FreeBSD marks an ACL.
mode(#file_info{type = Type, mode = Mode}) when is_integer(Mode) ->
    Bit = fun(Mask, Char) -> case Mode band Mask of 0 -> $-; _ -> Char end end,
    Special = fun(Exec, Set, Lower, Upper) ->
                      case {Mode band Exec =/= 0, Mode band Set =/= 0} of
                          {true, true} -> Lower;
                          {false, true} -> Upper;
                          {true, false} -> $x;
                          {false, false} -> $-
                      end
              end,
    <<(type_char(Type)), (Bit(8#400, $r)), (Bit(8#200, $w)), (Special(8#100, 8#4000, $s, $S)),
      (Bit(8#40, $r)), (Bit(8#20, $w)), (Special(8#10, 8#2000, $s, $S)),
      (Bit(8#4, $r)), (Bit(8#2, $w)), (Special(8#1, 8#1000, $t, $T)), $\s>>;
mode(#file_info{type = Type}) ->
    <<(type_char(Type)), "--------- ">>.

type_char(directory) -> $d;
type_char(regular) -> $-;
type_char(symlink) -> $l;
type_char(device) -> $c;
type_char(_Other) -> $?.

%% `%b %e %R` within six months of now, `%b %e  %Y` otherwise.
time(Seconds, Now) when is_integer(Seconds) ->
    {{Year, Month, Day}, {Hour, Minute, _}} =
        calendar:system_time_to_universal_time(Seconds, second),
    Mon = element(Month, {<<"Jan">>, <<"Feb">>, <<"Mar">>, <<"Apr">>, <<"May">>, <<"Jun">>,
                          <<"Jul">>, <<"Aug">>, <<"Sep">>, <<"Oct">>, <<"Nov">>, <<"Dec">>}),
    Recent = Seconds + ?SIX_MONTHS > Now andalso Seconds < Now + ?SIX_MONTHS,
    Tail = case Recent of
               true -> io_lib:format("~2..0B:~2..0B", [Hour, Minute]);
               false -> io_lib:format(" ~4..0B", [Year])
           end,
    iolist_to_binary([Mon, io_lib:format(" ~2.. B ", [Day]), Tail]);
time(_Missing, _Now) ->
    <<"-">>.
