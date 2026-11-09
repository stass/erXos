%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
%%
%% Copyright Ericsson AB 2017-2025. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% Modified by erXos: each event's text is built on one line and shown with the line
%% escape and a CR-LF in one write.
%%
%% %CopyrightEnd%
%%
-module(logger_simple_h).
-moduledoc false.

-export([adding_handler/1, removing_handler/1, log/2]).

-behaviour(logger_handler).

%% This module implements a simple handler for logger. It is the
%% default used during system start.

%%%-----------------------------------------------------------------
%%% Logger callback

adding_handler(#{id:=simple}=Config) ->
    Me = self(),
    case whereis(?MODULE) of
        undefined ->
            {Pid,Ref} = spawn_opt(fun() -> init(Me) end,
                                  [link,monitor,{message_queue_data,off_heap}]),
            receive
                {'DOWN',Ref,process,Pid,Reason} ->
                    {error,Reason};
                {Pid,started} ->
                    erlang:demonitor(Ref),
                    {ok,Config}
            end;
        _ ->
            {error,{handler_process_name_already_exists,?MODULE}}
    end.

removing_handler(#{id:=simple}) ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        Pid ->
            Ref = erlang:monitor(process,Pid),
            Pid ! stop,
            receive {'DOWN',Ref,process,Pid,_} ->
                    ok
            end
    end.

log(#{meta:=#{error_logger:=#{tag:=info_report,type:=Type}}} = Log,_Meta)
  when Type =/= std_info ->
    case logger:allow(debug, ?MODULE) of
        false ->
            %% Skip info reports that are not 'std_info' (ref simple logger in
            %% error_logger)
            ok;
        true ->
            %% If log level is debug or all we emit even these reports
            do_log(Log)
    end;
log(Log,_Config) ->
    _ = do_log(Log),
    ok.

do_log(#{msg:=_,meta:=#{time:=_}=M}=Log) ->
    case whereis(?MODULE) of
        undefined ->
            %% Is the node on the way down? Real emergency?
            %% Log directly from client just to get it out
            case maps:get(internal_log_event, M, false) of
                false ->
                    log_internal(
                      simple,
                      #{level=>error,
                        msg=>{report,{error,simple_handler_process_dead}},
                        meta=>#{time=>logger:timestamp()}});
                true ->
                    ok
            end,
            log_internal(simple,Log);
        _ ->
            ?MODULE ! {log,Log}
    end;
do_log(_) ->
    %% Unexpected log.
    %% We don't want to crash the simple logger, so ignore this.
    ok.

%%%-----------------------------------------------------------------
%%% Process
init(Starter) ->
    register(?MODULE,self()),
    Starter ! {self(),started},
    load_escape(),
    loop(rich, #{buffer_size=>20,dropped=>0,buffer=>[]}).

loop(Mode, Buffer) ->
    receive
        stop ->
            %% We replay the logger messages if there is
            %% a default handler when the simple handler
            %% is removed.
            case logger:get_handler_config(default) of
                {ok, _} ->
                    replay_buffer(Buffer);
                _ ->
                    ok
            end,
            %% Before stopping, we unlink the logger process to avoid
            %% an unexpected EXIT message
            unlink(whereis(logger)),
            ok;
        {log,#{meta:=#{error_logger:=#{tag:=info_report,type:=Type}}} = Log}
          when Type =/= std_info ->
            %% When we get a std_info message, we just want to replay it,
            %% no need to print it right now
            loop(Mode, update_buffer(Buffer,Log));
        {log,#{msg:=_,meta:=#{time:=_}}=Log} ->
            NewMode = log_internal(Mode, Log),
            loop(NewMode, update_buffer(Buffer,Log));
        _ ->
            %% Unexpected message - flush it!
            loop(Mode, Buffer)
    end.

update_buffer(#{buffer_size:=0,dropped:=D}=Buffer,_Log) ->
    Buffer#{dropped=>D+1};
update_buffer(#{buffer_size:=S,buffer:=B}=Buffer,Log) ->
    Buffer#{buffer_size=>S-1,buffer=>[Log|B]}.

replay_buffer(#{ dropped := D, buffer := Buffer }) ->
    lists:foreach(
      fun F(#{msg := {Tag, Msg}} = L) when Tag =:= string; Tag =:= report ->
              F(L#{ msg := Msg });
          F(#{ level := Level, msg := Msg, meta := MD}) ->
              logger:log(Level, Msg, MD)
      end, lists:reverse(Buffer, drop_msg(D))).

drop_msg(0) ->
    [];
drop_msg(N) ->
    [#{level=>info,
       msg=>{"Simple handler buffer full, dropped ~w messages",[N]},
       meta=>#{time=>logger:timestamp()}}].

%%%-----------------------------------------------------------------
%%% Internal

%% If the init process is busy (for instance doing a shutdown)
%% we can get blocked while trying to load code. So we spawn a process
%% for each log message that can potentially block. If the logging cannot
%% be done within 300ms, we instead log the raw log message to stdout
%% and switch mode to always log using the raw format.
%% erXos: each event's text is built on one line and shown through display_line/1,
%% in both modes (edit 43 of docs/design-runtime.md).
log_internal(simple, Log) ->
    display_log(Log), simple;
log_internal(rich = Mode, Log) ->

    {Pid, Ref} =
        spawn_monitor(
          fun() ->
                  Str = logger_formatter:format(
                          Log,
                          #{ legacy_header => false, single_line => true,
                             depth => unlimited, time_offset => "",
                             template => [time, " ", level, ": ", msg]
                           }),
                  display_line(Str)
          end),
    receive
        {'DOWN', Ref, _, _, normal} ->
            Mode;
        {'DOWN', Ref, _, _, _Else} ->
            display_log(Log),
            Mode
    after 300 ->
            %% init:terminate/3 sleeps for 500 ms before exiting,
            %% so we wait for 300 ms for the log to happen
            exit(Pid, kill),
            receive
                {'DOWN', Ref, _, _, normal} ->
                    Mode;
                {'DOWN', Ref, _, _, _Else} ->
                    display_log(Log),
                    simple
            end
    end.

%% erXos: an event's text is attributed text, so it is shown with the line escape,
%% which renders each control in it, tab and newline included, as a token, followed by
%% the line's CR-LF, in one write (docs/design-live.md, "The console", Logs). Text that
%% is not character data, or a runtime that cannot run the escape, shows a fixed line
%% instead.
display_line(Text) ->
    Line = try erx_text:escape_line(Text)
           catch error:_ -> <<"logger_simple_h: an event's text could not be shown">>
           end,
    erlang:display_string(stdout, unicode:characters_to_list([Line, "\r\n"])).

%% erXos: loads erx_text and its tables when the handler starts, so an event shown
%% later while init is busy, when loading code would block, finds them loaded. The
%% handler starts before the code server, so the load goes through error_handler and
%% init:ensure_loaded/1 from the release's code path; should it fail, display_line/1
%% shows its fixed line.
load_escape() ->
    try erx_text:escape_line(<<>>) of
        _Empty -> ok
    catch
        error:_ -> ok
    end.

display_log(Log) ->
    display_line(log_text(Log)).

log_text(#{msg:={report,Report},
         meta:=#{time:=T,error_logger:=#{type:=Type}}}) ->
    [date_text(T), report_text(Type,Report)];
log_text(#{msg:=Msg,meta:=#{time:=T}}) ->
    [date_text(T), msg_text(Msg)].

date_text(Timestamp) when is_integer(Timestamp) ->
    Micro = Timestamp rem 1000000,
    Sec = Timestamp div 1000000,
    {{Y,Mo,D},{H,Mi,S}} = erlang:universaltime_to_localtime(
                            erlang:posixtime_to_universaltime(Sec)),
    integer_to_list(Y) ++ "-" ++
        pad(Mo,2) ++ "-" ++
        pad(D,2)  ++ " " ++
        pad(H,2)  ++ ":" ++
        pad(Mi,2) ++ ":" ++
        pad(S,2)  ++ "." ++
        pad(Micro,6) ++ " ".

pad(Int,Size) when is_integer(Int) ->
    pad(integer_to_list(Int),Size);
pad(Str,Size) when length(Str)==Size ->
    Str;
pad(Str,Size) ->
    pad([$0|Str],Size).

%% A message as stock's simple mode shows it, unformatted: a format string with each
%% argument after it, or a report's terms, on one line.
msg_text({string,Chardata}) ->
    try unicode:characters_to_list(Chardata) of
        String when is_list(String) -> String;
        _Invalid -> term_text(Chardata)
    catch _:_ -> term_text(Chardata)
    end;
msg_text({report,Report}) when is_map(Report) ->
    report_text(maps:to_list(Report));
msg_text({report,Report}) ->
    report_text(Report);
msg_text({F, A}) when is_list(F), is_list(A) ->
    [F | [[$\s, term_text(Arg)] || Arg <- A]].

report_text(Atom, A) when is_atom(Atom) ->
    %% The widest atom seems to be 'supervisor_report' at 17.
    ColumnWidth = 20,
    AtomString = atom_to_list(Atom),
    AtomLength = length(AtomString),
    Padding = lists:duplicate(ColumnWidth - AtomLength, $\s),
    [AtomString, Padding, report_text(A)];
report_text(F, A) ->
    term_text({F, A}).

report_text(#{ report := Report }) ->
    report_text(Report);
report_text([A, []]) ->
    %% Special case for crash reports when process has no links
    report_text(A);
report_text(A = [_|_]) ->
    case lists:all(fun({Key,_Value}) -> is_atom(Key); (_) -> false end, A) of
	true ->
	    [["    ", atom_to_list(Key), ": ", term_text(Value)] || {Key, Value} <- A];
	false ->
	    term_text(A)
    end;
report_text(A) ->
    term_text(A).

term_text(Term) ->
    io_lib:write(Term).
