%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The log sink's handler (docs/design-live.md, "The console", Logs): the `default`
%% handler of the logger in every domain (edit 57 of docs/design-runtime.md).
%%
%% log/2 runs in the process that logs, so the event is formatted inside the domain that
%% raised it, on one line, and the system domain never formats another domain's format
%% string. The result is a log record, {log, Level, Text}, Text a binary of at most
%% ?TEXT_MAX bytes, which goes to the console:
%%
%%   * in the system domain to erx_console, which renders it with the line escape under
%%     the domain's id, principal and name;
%%   * in any other domain to the handler's process, the domain's logger proxy, which
%%     sends it on to the domain's console facet.
%%
%% Nothing here escapes the text. It is the domain's own, and only the sink that shows it
%% escapes it, so a domain that sends records of its own making gains nothing.
%%
%% A domain's console facet comes from the domain service, which hands out none (TODO.md),
%% so the proxy writes each record into the kernel log, which escapes it and labels it
%% with the domain's space, and the console writes that record as it writes the kernel's.
%% A record finds no proxy and no erx_console only while either is starting or after it
%% has gone; it then goes into the kernel log from the process that logs.
%%
%% Which of the two a runtime has decides where its records go: erx_console runs only in
%% the system domain, and a process of another domain that took that name would receive
%% only its own domain's records.
-module(erx_log_h).
-moduledoc false.

-behaviour(logger_handler).

-export([adding_handler/1, removing_handler/1, log/2]).
-export([sync/0, record/2]).

-include("generated/erx_abi.hrl").

%% The longest text of a record, in bytes: the log interface's log_write_text_max.
-define(TEXT_MAX, ?ERX_LOG_WRITE_TEXT_MAX).
%% What ends a cut text, so a reader sees that the record holds less than the event.
-define(CUT_MARK, <<"...">>).
%% The proxy's registered name.
-define(PROXY, ?MODULE).

-type log_record() :: {log, logger:level(), binary()}.

-doc """
Starts the domain's logger proxy, or finds it already running. The proxy is no one's
child: should it end, log/2 writes into the kernel log itself.
""".
-spec adding_handler(logger_handler:config()) -> {ok, logger_handler:config()} | {error, term()}.
adding_handler(Config) ->
    case whereis(?PROXY) of
        undefined ->
            Starter = self(),
            {Pid, Ref} = spawn_opt(fun() -> proxy_init(Starter) end, [monitor]),
            receive
                {Pid, started} ->
                    erlang:demonitor(Ref, [flush]),
                    {ok, Config};
                {'DOWN', Ref, process, Pid, Reason} ->
                    {error, Reason}
            end;
        _Running ->
            {ok, Config}
    end.

-spec removing_handler(logger_handler:config()) -> ok.
removing_handler(_Config) ->
    case whereis(?PROXY) of
        undefined ->
            ok;
        Pid ->
            Ref = erlang:monitor(process, Pid),
            exit(Pid, shutdown),
            receive {'DOWN', Ref, process, Pid, _} -> ok end
    end.

-spec log(logger:log_event(), logger_handler:config()) -> ok.
log(Event, Config) ->
    Record = record(Event, Config),
    case sink() of
        none -> write_kernel_log(Record);
        Sink -> Sink ! Record
    end,
    ok.

-doc """
Returns once the proxy has handled every record the caller sent it before, so a
caller that logs and then halts knows its records are in the kernel log. Where
erx_console takes the records, in the system domain, they may still wait in its
queue.
""".
-spec sync() -> ok.
sync() ->
    case whereis(?PROXY) of
        undefined ->
            ok;
        Pid ->
            Ref = erlang:monitor(process, Pid),
            Pid ! {sync, self(), Ref},
            receive
                {Ref, ok} -> erlang:demonitor(Ref, [flush]), ok;
                {'DOWN', Ref, process, Pid, _} -> ok
            end
    end.

-doc """
The record of Event under the handler's Config: its level and its text, formatted
by the configured formatter on one line and cut to ?TEXT_MAX bytes. A formatter that
fails gives a text that says so instead of the event's.
""".
-spec record(logger:log_event(), logger_handler:config()) -> log_record().
record(#{level := Level} = Event, Config) ->
    {Module, FormatterConfig} = maps:get(formatter, Config, {logger_formatter, #{}}),
    {log, Level, cut(text(Module, one_line(Module, FormatterConfig), Event))}.

%% logger_formatter on one line: newlines in the message become ", ", the legacy
%% header with its own newlines is off, and the text is the message alone unless the
%% configuration names a template, since the console shows the level and stamps its
%% own time. Unless configured, formatting stops near ?TEXT_MAX characters, so a huge
%% report is not formatted whole only to be cut. Another formatter's text is used as it
%% comes.
one_line(logger_formatter, FormatterConfig) ->
    maps:merge(#{template => [msg], chars_limit => ?TEXT_MAX, max_size => ?TEXT_MAX},
               FormatterConfig#{single_line => true, legacy_header => false});
one_line(_Module, FormatterConfig) ->
    FormatterConfig.

text(Module, FormatterConfig, Event) ->
    try unicode:characters_to_binary(Module:format(Event, FormatterConfig)) of
        Text when is_binary(Text) -> Text;
        {_Error, Converted, _Rest} -> <<Converted/binary, (?CUT_MARK)/binary>>
    catch
        Class:Reason -> failure_text(Module, Class, Reason)
    end.

%% What a record says when its formatter failed: the formatter and the failure, or, if
%% even that cannot be written as UTF-8, a fixed text, so log/2 never raises and the
%% logger keeps the handler.
failure_text(Module, Class, Reason) ->
    try unicode:characters_to_binary(io_lib:format("erx_log_h: formatter ~0tp failed: ~0tP",
                                                   [Module, {Class, Reason}, 10])) of
        Text when is_binary(Text) -> Text;
        _Invalid -> <<"erx_log_h: a formatter failed">>
    catch
        _:_ -> <<"erx_log_h: a formatter failed">>
    end.

%% The longest start of Text, ending at a character's end, that fits ?TEXT_MAX bytes
%% with the cut mark after it.
cut(Text) when byte_size(Text) =< ?TEXT_MAX ->
    Text;
cut(Text) ->
    Head = binary:part(Text, 0, character_end(Text, ?TEXT_MAX - byte_size(?CUT_MARK))),
    <<Head/binary, (?CUT_MARK)/binary>>.

%% The largest length =< Limit at which no UTF-8 sequence of Text is split: a
%% continuation byte (2#10xxxxxx) at Limit belongs to the character before it.
character_end(_Text, 0) ->
    0;
character_end(Text, Limit) ->
    case binary:at(Text, Limit) of
        Byte when Byte band 16#C0 =:= 16#80 -> character_end(Text, Limit - 1);
        _ -> Limit
    end.

%% Where log/2 sends a record: the system domain's console where it runs, the proxy
%% elsewhere, and none while neither is running.
sink() ->
    case whereis(erx_console) of
        undefined ->
            case whereis(?PROXY) of
                undefined -> none;
                Proxy -> Proxy
            end;
        Console ->
            Console
    end.

%% Where a record goes in a domain with no console facet: the kernel log, one record of
%% the domain's space for each piece of the text, with the level ahead of it. A runtime
%% without erx_log's NIF loses the record rather than the handler, which the logger
%% removes when log/2 fails.
-spec write_kernel_log(log_record()) -> ok.
write_kernel_log({log, Level, Text}) ->
    try erx_log:debug_text([atom_to_binary(Level), <<": ">>, Text]) of
        _Written -> ok
    catch
        error:_ -> ok
    end.

proxy_init(Starter) ->
    register(?PROXY, self()),
    Starter ! {self(), started},
    proxy_loop().

%% The proxy, which is not OTP's logger_proxy (that one forwards events to another
%% node's logger), takes every record from its own domain, as any process of a domain
%% may send to the console facet; what it receives in any other form it drops.
proxy_loop() ->
    receive
        {log, Level, Text} = Record when is_atom(Level), is_binary(Text) ->
            write_kernel_log(Record);
        {sync, From, Ref} ->
            From ! {Ref, ok};
        _Other ->
            ok
    end,
    proxy_loop().
