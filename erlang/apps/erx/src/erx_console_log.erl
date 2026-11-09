%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_console_log).
-moduledoc """
The console's log records (docs/design-live.md, "The console", Logs): which
records `erx_console` accepts from a domain, how much of each domain's log it lets
through in a second, and the log line it writes for each.

A record is `{log, Level, Text}`, Level one of the logger's eight levels and Text a
binary of at most 4096 bytes, as `erx_log_h` sends it. Anything else is refused.
Each domain may have 16 KiB of lines written in each second, the rate
`erx_debug_log` allows a space. A record is charged its whole line, head and escaped
text, so neither empty records nor text that the escape lengthens write more than
that. Past it, and for each refused record, the record is dropped and counted, and
the domain's next accepted line says how many were.

A line is rendered like a kernel log record: the time it arrived, in seconds and
microseconds, the level, the domain's id and principal, which come from where the
record arrived and not from the record, the drop count, and then the domain's name
and the text. The name and the text go through the line escape
(erx_text:escape_line/1), so each control in them, tab and newline included, shows
as a token, and the line holds no raw control but its closing CR-LF. Everything
before the name is the console's own: no domain chooses its time, id, principal or
drop count.

The module is pure: accept/4 takes the arrival time and returns the next state.
""".

-export([new/0, accept/4]).
-export_type([source/0, state/0]).

-define(TEXT_MAX, 4096).
-define(RATE_BYTES, 16384).
-define(NS_PER_S, 1000000000).
-define(NS_PER_US, 1000).
-define(LEVELS, [emergency, alert, critical, error, warning, notice, info, debug]).

%% Where a record arrived from: the domain's id, its principal and its name.
-type source() :: #{id := non_neg_integer(), principal := non_neg_integer(),
                    name := unicode:chardata()}.
%% For each domain that has sent a record: the second its count is for, the bytes of
%% lines written in it, and the records dropped since its last accepted line.
-opaque state() :: #{non_neg_integer() => {Second :: integer(), Bytes :: non_neg_integer(),
                                           Dropped :: non_neg_integer()}}.

-spec new() -> state().
new() ->
    #{}.

-doc """
What the console does with Message, which arrived from Source at monotonic time
Now (nanoseconds): `{line, Line, State}` with the line to write whole, or
`{dropped, State}` with the drop counted.
""".
-spec accept(term(), source(), non_neg_integer(), state()) ->
          {line, binary(), state()} | {dropped, state()}.
accept(Message, #{id := Id} = Source, Now, State) ->
    Second = Now div ?NS_PER_S,
    {Bytes, Dropped} = case State of
                           #{Id := {Second, Used, Lost}} -> {Used, Lost};
                           #{Id := {_Earlier, _Used, Lost}} -> {0, Lost};
                           #{} -> {0, 0}
                       end,
    Line = case valid(Message) of
               {ok, Level, Text} -> iolist_to_binary(line(Source, Now, Level, Text, Dropped));
               refused -> refused
           end,
    case Line of
        <<_/binary>> when Bytes + byte_size(Line) =< ?RATE_BYTES ->
            {line, Line, State#{Id => {Second, Bytes + byte_size(Line), 0}}};
        _RefusedOrOver ->
            {dropped, State#{Id => {Second, Bytes, Dropped + 1}}}
    end.

%% A record of the one shape.
valid({log, Level, Text}) when is_atom(Level), is_binary(Text), byte_size(Text) =< ?TEXT_MAX ->
    case lists:member(Level, ?LEVELS) of
        true -> {ok, Level, Text};
        false -> refused
    end;
valid(_Message) ->
    refused.

line(#{id := Id, principal := Principal, name := Name}, Now, Level, Text, Dropped) ->
    [integer_to_binary(Now div ?NS_PER_S), $., micro(Now rem ?NS_PER_S div ?NS_PER_US),
     $\s, atom_to_binary(Level), <<" domain ">>, integer_to_binary(Id),
     <<" principal ">>, integer_to_binary(Principal), dropped(Dropped), $\s,
     erx_text:escape_line(Name), <<": ">>, erx_text:escape_line(Text), <<"\r\n">>].

micro(Micro) ->
    string:pad(integer_to_binary(Micro), 6, leading, $0).

dropped(0) -> <<>>;
dropped(Count) -> [<<" dropped ">>, integer_to_binary(Count)].
