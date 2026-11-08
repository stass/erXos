%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_top).
-moduledoc """
`top [-bn] [-d count] [-s time] [number]`: FreeBSD's top (usr.bin/top)
over the table `ps` reads (docs/design-live.md, "The command shell").

Each display is a header and a process table. The header is the time of
day and a count of the processes by state, `57 processes:  2 running,
55 sleeping`; the table has the columns of FreeBSD's that the table has
values for, `PID RES STATE TIME WCPU COMMAND`, ordered by `WCPU`,
largest first, the rows without one after them in pid order.

A row's `WCPU` is its share of a CPU since the previous display: the
growth of its CPU time over the time between the two samples. For a
process the previous display did not have, and on the first display, it
is the share since the process started, ps's `%CPU`. A value the table
does not have prints `-`, as ps prints it, so no column shows a number
it does not have; an Erlang process has no CPU time, so its `TIME` and
`WCPU` are `-`. Names are ps's, already through the field escape.

On a screen, a terminal without `-b` or `-n`, each display starts with
the terminal's home and clear sequences and fills its height, and a
display follows every `-s` seconds, 2 by default, until `-d` displays
have been shown or `Ctrl-C` ends the command; top changes no terminal
state, so nothing is restored. Otherwise top writes `-d` displays, one
by default, of at most 18 processes each, FreeBSD's for output it cannot
draw on. `number` caps the processes a display shows.

The decisions are pure: options/1 reads the arguments, plan/2 settles
their defaults for a screen or not, shares/2 works out each row's `WCPU`
and display/2 lays a display out. run/2 samples, writes and sleeps
around them.
""".

-behaviour(erx_cmd).
-erx_command(top).
-erx_usage("top [-bn] [-d count] [-s time] [number]").

-export([run/2]).
-export([options/1, plan/2, shares/2, cpu_times/1, display/2, count/1, format_time/1, format_k/1]).

-export_type([options/0, plan/0, layout/0]).

%% The options as given, `default` where the line gave none.
-type options() :: #{batch := boolean(), displays := pos_integer() | infinity | default,
                     delay_ms := pos_integer(), topn := non_neg_integer() | infinity | default}.

%% What top does: whether it draws on a screen, how many displays it
%% shows, the wait between them and the most processes each shows.
-type plan() :: #{screen := boolean(), displays := pos_integer() | infinity,
                  delay_ms := pos_integer(), topn := non_neg_integer() | infinity}.

%% How a display is laid out: the most process rows it shows, the width
%% each line is cut at, and the time of day its header shows.
-type layout() :: #{max_rows := non_neg_integer() | infinity, width := pos_integer() | infinity,
                    clock := calendar:time()}.

%% The CPU times of a sample, by pid, and when it was read, in
%% microseconds of monotonic time.
-type times() :: {integer(), #{binary() => non_neg_integer()}}.

%% FreeBSD's delay between displays and the processes a display shows
%% where top cannot draw on a terminal, Nominal_TOPN (usr.bin/top/top.h).
-define(DEFAULT_DELAY_MS, 2000).
-define(NOMINAL_TOPN, 18).
%% A terminal's size when neither the environment nor the terminal says.
-define(DEFAULT_ROWS, 24).
-define(DEFAULT_COLUMNS, 80).
%% The longest wait timer:sleep/1 takes.
-define(MAX_DELAY_MS, 16#FFFFFFFF).
%% Home and clear the screen, an ANSI terminal's termcap `cl`.
-define(CLEAR, <<"\e[H\e[2J">>).
%% The header's two lines, its blank line and the table's header line.
-define(HEADER_LINES, 4).

run(Args, Ctx) ->
    case options(Args) of
        {ok, Options, Warnings} ->
            [erx_cmd:say(Ctx, [<<"top: warning: ">>, Warning, $\n]) || Warning <- Warnings],
            Plan = plan(Options, erx_cmd:isatty(Ctx, stdout)),
            loop(Ctx, Plan, maps:get(displays, Plan), none);
        {error, usage} ->
            {error, usage}
    end.

%%% Displays

%% Writes a display and, while more are due, sleeps and writes the next.
%% Previous holds the last display's CPU times, `none` before the first.
loop(Ctx, #{screen := Screen, delay_ms := Delay} = Plan, Left, Previous) ->
    Now = erlang:monotonic_time(microsecond),
    Rows = erx_cmd_ps:session_table(),
    Display = display(shares(Previous, {Now, Rows}), layout(Ctx, Plan)),
    erx_cmd:write(Ctx, [lead(Screen, Previous), Display]),
    case remaining(Left) of
        0 ->
            ok;
        Next ->
            timer:sleep(Delay),
            loop(Ctx, Plan, Next, {Now, cpu_times(Rows)})
    end.

remaining(infinity) -> infinity;
remaining(N) -> N - 1.

%% A display on a screen starts on a clear screen; otherwise each after
%% the first follows a blank line.
lead(true, _Previous) -> ?CLEAR;
lead(false, none) -> <<>>;
lead(false, _Previous) -> <<"\n">>.

layout(Ctx, #{screen := true, topn := TopN}) ->
    screen_layout(Ctx, TopN);
layout(_Ctx, #{screen := false, topn := TopN}) ->
    #{max_rows => TopN, width => infinity, clock => clock()}.

%% On a screen the table fills the terminal under the header, leaving the
%% last line for the cursor so that nothing scrolls, and each line is cut
%% one column short of the terminal's width, as FreeBSD's screen is
%% (usr.bin/top/screen.c).
screen_layout(Ctx, TopN) ->
    Fit = max(screen_rows(Ctx) - ?HEADER_LINES - 1, 0),
    MaxRows = case TopN of infinity -> Fit; _ -> min(Fit, TopN) end,
    #{max_rows => MaxRows, width => screen_width(Ctx), clock => clock()}.

clock() -> element(2, erlang:localtime()).

screen_rows(Ctx) ->
    case erx_cmd:rows(Ctx) of
        unknown -> ?DEFAULT_ROWS;
        Rows -> Rows
    end.

screen_width(Ctx) ->
    case erx_cmd:columns(Ctx) of
        unknown -> ?DEFAULT_COLUMNS - 1;
        Columns -> max(Columns - 1, 1)
    end.

%%% The pure core

-doc """
The options of an argument list and the warnings FreeBSD's top prints
for a value it ignores (usr.bin/top/top.c), or `{error, usage}` for an
option it does not offer.
""".
-spec options([binary()]) -> {ok, options(), [binary()]} | {error, usage}.
options(Args) ->
    case erx_cmd:getopt(Args, "bnd:s:") of
        {ok, Flags, Rest} ->
            Initial = {#{batch => false, displays => default, delay_ms => ?DEFAULT_DELAY_MS,
                         topn => default}, []},
            {Options, Warnings} = topn(Rest, lists:foldl(fun flag/2, Initial, Flags)),
            {ok, Options, lists:reverse(Warnings)};
        {error, usage} ->
            {error, usage}
    end.

-doc """
The plan for options and whether standard output is a terminal: a screen
when it is and neither `-b` nor `-n` was given, and then displays until
`Ctrl-C` and as many processes as fit; otherwise one display of at most
18 processes, as FreeBSD's top does for output it cannot draw on. Given
values stand.
""".
-spec plan(options(), boolean()) -> plan().
plan(#{batch := Batch, displays := Displays, delay_ms := Delay, topn := TopN}, Terminal) ->
    Screen = Terminal andalso not Batch,
    {DefaultDisplays, DefaultTopN} = case Screen of
                                         true -> {infinity, infinity};
                                         false -> {1, ?NOMINAL_TOPN}
                                     end,
    #{screen => Screen, delay_ms => Delay,
      displays => given(Displays, DefaultDisplays), topn => given(TopN, DefaultTopN)}.

given(default, Default) -> Default;
given(Value, _Default) -> Value.

flag(Batch, {Options, Warnings}) when Batch =:= $b; Batch =:= $n ->
    {Options#{batch := true}, Warnings};
flag({$d, Text}, {Options, Warnings}) ->
    case count(Text) of
        N when N =:= invalid; N =:= 0 ->
            {Options, [<<"display count should be positive -- option ignored">> | Warnings]};
        N ->
            {Options#{displays := N}, Warnings}
    end;
flag({$s, Text}, {Options, Warnings}) ->
    case delay(Text) of
        invalid -> {Options, [<<"invalid delay">> | Warnings]};
        not_positive -> {Options, [<<"seconds delay should be positive -- using default">> | Warnings]};
        {ok, Ms} -> {Options#{delay_ms := Ms}, Warnings}
    end.

%% The process count is the first argument; any after it are ignored, as
%% on FreeBSD.
topn([], Acc) ->
    Acc;
topn([Text | _], {Options, Warnings}) ->
    case count(Text) of
        invalid ->
            {Options, [<<"process display count should be non-negative -- using default">> | Warnings]};
        N ->
            {Options#{topn := N}, Warnings}
    end.

-doc """
A count as FreeBSD's atoiwi() reads it (usr.bin/top/utils.c): a prefix of
`infinity`, `all` or `maximum` is `infinity`, a leading `-` is invalid,
and anything else is the decimal number strtol(3) reads at its start,
after blanks and a `+`, or 0 when there is none.
""".
-spec count(binary()) -> non_neg_integer() | infinity | invalid.
count(<<>>) ->
    0;
count(Text) ->
    IsPrefixOf = fun(Word) -> binary:longest_common_prefix([Text, Word]) =:= byte_size(Text) end,
    case lists:any(IsPrefixOf, [<<"infinity">>, <<"all">>, <<"maximum">>]) of
        true -> infinity;
        false when binary_part(Text, 0, 1) =:= <<"-">> -> invalid;
        false -> number(element(2, sign(skip_blanks(Text))))
    end.

%% A delay in seconds, read as strtod(3) reads a decimal number without
%% an exponent: blanks, a sign, digits and a fraction, whatever follows
%% ignored. It is answered in whole milliseconds, the fraction past them
%% dropped, at least 1 for any positive delay and at most what
%% timer:sleep/1 takes.
delay(Text) ->
    {Sign, Unsigned} = sign(skip_blanks(Text)),
    {Whole, AfterWhole} = digits(Unsigned),
    {Fraction, _} = case AfterWhole of
                        <<".", More/binary>> -> digits(More);
                        _ -> {<<>>, <<>>}
                    end,
    %% The first three digits of the fraction are the milliseconds.
    <<Millis:3/binary, _/binary>> = <<Fraction/binary, "000">>,
    case {Whole, Fraction} of
        {<<>>, <<>>} ->
            invalid;
        _ when Sign =:= negative ->
            not_positive;
        _ ->
            case {number(Whole), number(Fraction)} of
                {0, 0} -> not_positive;
                {Seconds, _} -> {ok, min(max(Seconds * 1000 + number(Millis), 1), ?MAX_DELAY_MS)}
            end
    end.

%% strtod(3) and strtol(3) skip the blanks of isspace(3) before a number.
skip_blanks(<<C, Rest/binary>>) when C =:= $\s; C >= $\t, C =< $\r -> skip_blanks(Rest);
skip_blanks(Text) -> Text.

sign(<<"-", Rest/binary>>) -> {negative, Rest};
sign(<<"+", Rest/binary>>) -> {positive, Rest};
sign(Text) -> {positive, Text}.

%% The number the leading decimal digits of a binary spell, 0 for none.
number(Text) ->
    case digits(Text) of
        {<<>>, _} -> 0;
        {Digits, _} -> binary_to_integer(Digits)
    end.

%% The leading decimal digits of a binary and what follows them.
digits(Text) ->
    Length = span(Text, 0),
    {binary_part(Text, 0, Length), binary_part(Text, Length, byte_size(Text) - Length)}.

span(<<C, Rest/binary>>, N) when C >= $0, C =< $9 -> span(Rest, N + 1);
span(_Text, N) -> N.

-doc "The CPU times of the rows that have one, by pid, for the next display's shares/2.".
-spec cpu_times([erx_cmd_ps:row()]) -> #{binary() => non_neg_integer()}.
cpu_times(Rows) ->
    #{Pid => Time || #{pid := Pid, time := Time} <- Rows, is_integer(Time)}.

-doc """
The rows of a sample, each with its `wcpu`, ordered by it, largest first,
those without one after them in pid order (erx_cmd_ps:order/2). A row's
`wcpu` is the percentage of a CPU its CPU time grew by since the previous
display's times; when those do not have its time, or there are none, it
is ps's `pcpu`, its share since it started. A time that went down
belongs to another process of the same id, and gets `pcpu` too.
""".
-spec shares(none | times(), {integer(), [erx_cmd_ps:row()]}) -> [erx_cmd_ps:row()].
shares(Previous, {Now, Rows}) ->
    {Then, Times} = case Previous of
                        none -> {Now, #{}};
                        {_, _} -> Previous
                    end,
    erx_cmd_ps:order([Row#{wcpu => share(Row, maps:find(Pid, Times), Now - Then)}
                      || #{pid := Pid} = Row <- Rows], wcpu).

share(#{time := missing}, _Before, _Interval) -> missing;
share(#{time := Time}, {ok, Before}, Interval) when Interval > 0, Time >= Before ->
    100 * (Time - Before) / Interval;
share(#{pcpu := Since}, _Before, _Interval) -> Since.

-doc """
A display of rows in their order: the header, whose counts are of every
row, over the first `max_rows` of them, each line cut at `width`.
""".
-spec display([erx_cmd_ps:row()], layout()) -> iodata().
display(Rows, #{max_rows := MaxRows, width := Width, clock := Clock}) ->
    Shown = case MaxRows of infinity -> Rows; _ -> lists:sublist(Rows, MaxRows) end,
    PidWidth = lists:max([byte_size(<<"PID">>) | [byte_size(Pid) || #{pid := Pid} <- Shown]]),
    Lines = [time_of_day(Clock), states(Rows), <<>>, header(PidWidth)
             | [line(Row, PidWidth) || Row <- Shown]],
    [[erx_cmd_ps:cut(Line, Width), $\n] || Line <- Lines].

time_of_day({H, M, S}) ->
    iolist_to_binary(io_lib:format("~2..0b:~2..0b:~2..0b", [H, M, S])).

%% `N processes:`, padded as FreeBSD pads the count to four digits
%% (usr.bin/top/display.c, i_procstates), then each state some process
%% is in. A process that ended while the table was read counts only in
%% the total.
states(Rows) ->
    Tally = maps:groups_from_list(fun state/1, Rows),
    Counts = [[integer_to_binary(length(InState)), $\s, Name]
              || {State, Name} <- [{run, <<"running">>}, {sleep, <<"sleeping">>}, {stop, <<"stopped">>}],
                 InState <- [maps:get(State, Tally, [])], InState =/= []],
    Total = integer_to_binary(length(Rows)),
    iolist_to_binary([Total, <<" processes:">>, binary:copy(<<" ">>, max(4 - byte_size(Total), 1)),
                      lists:join(<<", ">>, Counts)]).

%% FreeBSD top's state for ps's STAT letter.
state(#{state := <<"R", _/binary>>}) -> run;
state(#{state := <<"S", _/binary>>}) -> sleep;
state(#{state := <<"T", _/binary>>}) -> stop;
state(_Row) -> missing.

state_name(run) -> <<"RUN">>;
state_name(sleep) -> <<"SLEEP">>;
state_name(stop) -> <<"STOP">>;
state_name(missing) -> <<"-">>.

%% The columns as FreeBSD lays them out (usr.bin/top/machine.c): RES in
%% six, STATE in six on the left, TIME in six and WCPU in seven.
header(PidWidth) ->
    columns(PidWidth, [<<"PID">>, <<"RES">>, <<"STATE">>, <<"TIME">>, <<"WCPU">>, <<"COMMAND">>]).

line(#{pid := Pid, rss := Rss, time := Time, wcpu := Wcpu, comm := Comm} = Row, PidWidth) ->
    columns(PidWidth, [Pid, value(Rss, fun format_k/1), state_name(state(Row)),
                       value(Time, fun format_time/1), value(Wcpu, fun format_wcpu/1),
                       value(Comm, fun(Name) -> Name end)]).

columns(PidWidth, [Pid, Res, State, Time, Wcpu, Command]) ->
    iolist_to_binary([right(Pid, PidWidth), $\s, right(Res, 6), $\s, left(State, 6), $\s,
                      right(Time, 6), $\s, right(Wcpu, 7), $\s, Command]).

value(missing, _Format) -> <<"-">>;
value(Value, Format) -> Format(Value).

right(Text, Width) -> [binary:copy(<<" ">>, max(Width - byte_size(Text), 0)), Text].
left(Text, Width) -> [Text, binary:copy(<<" ">>, max(Width - byte_size(Text), 0))].

format_wcpu(Share) ->
    iolist_to_binary(io_lib:format("~.2f%", [float(Share)])).

-doc """
CPU time, in microseconds, as FreeBSD's format_time() writes it
(usr.bin/top/utils.c): `M:SS`, hours to a tenth, `H.hH`, from 1000
minutes on, and `???` past 99999 tenths of an hour.
""".
-spec format_time(non_neg_integer()) -> binary().
format_time(Micros) ->
    Seconds = Micros div 1000000,
    iolist_to_binary(if
                         Seconds > 99999 * 360 -> <<"???">>;
                         Seconds >= 1000 * 60 -> io_lib:format("~.1fH", [Seconds / 3600]);
                         true -> io_lib:format("~b:~2..0b", [Seconds div 60, Seconds rem 60])
                     end).

-doc """
A size in KiB as FreeBSD's format_k() writes it through humanize_number(3)
(usr.bin/top/utils.c): at most four digits and a unit, `K`, `M`, `G` and
on, each 1024 of the one before, rounded to the nearest.
""".
-spec format_k(non_neg_integer()) -> binary().
format_k(KiB) -> format_k(KiB, 1, <<"KMGTPE">>).

format_k(KiB, Divisor, <<Unit, Units/binary>>) ->
    case (KiB + Divisor div 2) div Divisor of
        Scaled when Scaled >= 10000, Units =/= <<>> -> format_k(KiB, Divisor * 1024, Units);
        Scaled -> <<(integer_to_binary(Scaled))/binary, Unit>>
    end.
