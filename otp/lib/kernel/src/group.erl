%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
%%
%% Copyright Ericsson AB 1996-2026. All Rights Reserved.
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
%% Modified by erXos: the driver's suspend (Ctrl-Z) and window-size change
%% (winch) reach the shell; the group has one ask for input outstanding at
%% most (ask/1), which the driver answers with {read, Ref, Chars}; format_status/1
%% hides the shell history and the input typed or waiting (edit 75).
%%
%% Modified by erXos, the loss of input (edit 81): the driver answers an ask with
%% {read, Ref, lost} where input was lost. A loss damages every unfinished request
%% (lose/1); each request keeps its damage and passes it into every edlin call; a
%% request starts damaged while any unfinished one is. Only the user's Ctrl-C and the
%% end of input end a damaged request's loss: any other ending holds it for the next
%% request (pop_state/2), and so does input an error drops (fail/3). An answer to no
%% outstanding ask, a loss or characters, damages every unfinished request and is held
%% for the next one too. An accepted history search is finished by edlin, a
%% damaged read's line is not kept in the history (keep_line/3), and the end of input
%% edlin hands on after dropping a damaged line ends the read.
%%
%% %CopyrightEnd%
%%
-module(group).
-moduledoc false.

-compile([nowarn_deprecated_catch,
          {nowarn_unsafe_function, {os, cmd, 1}}]).

-include_lib("kernel/include/logger.hrl").

%% A group leader process for user io.
%% This process receives input data from user_drv in this format
%%   {Drv,{data,unicode:charlist()}}
%% It then keeps that data as unicode in its state and converts it
%% to latin1/unicode on a per request basis. If any data is left after
%% a request, that data is again kept as unicode.
%%
%% There are two major modes of group that work in similar though subtly different
%% ways, xterm and dumb. The xterm mode is used when a "newshell" is used and dumb
%% is used when "oldshell" or "noshell" are used.

-export([start/1, start/2, start/3, whereis_shell/0, init/3, server/3,
         xterm/3, dumb/3, handle_info/3]).

%% gen statem callbacks
-export([init/1, callback_mode/0, format_status/1]).

%% Logger report format fun
-export([format_io_request_log/1, log_io_request/3]).

-type mfargs() :: {module(), atom(), [term()]}.
-type nmfargs() :: {node(), module(), atom(), [term()]}.

-define(IS_PUTC_REQ(Req), element(1, Req) =:= put_chars orelse
        element(1, Req) =:= requests orelse
        element(1, Req) =:= put_ansi).
-define(IS_INPUT_REQ(Req),
        element(1, Req) =:= get_chars orelse element(1, Req) =:= get_line orelse
        element(1, Req) =:= get_until orelse element(1, Req) =:= get_password).

-record(input_state,
        {
         %% Used by all input routines
         from,
         reply_as,
         prompt_bytes,
         encoding,
         collect,
         cont,

         %% erXos: whether this request lost input (edit 81). A damaged request
         %% returns no line: an edited one until the user empties its buffer, a dumb
         %% one at all, until Ctrl-C or the end of input ends it.
         damaged = false :: boolean(),

         %% Used by xterm state
         lines = [], %% Previously entered lines that have not yet been consumed
         save_history = true, %% Whether this input request should save history

         %% used by dumb state
         get_fun,
         io_lib_state = start
        }).

-record(state,
        { read_type :: list | binary,
          driver :: pid(),
          echo :: boolean(),
          log = none :: none | input | output | all,
          dumb :: boolean(),
          shell = noshell :: noshell | pid(),

          %% Only used by dumb
          terminal_mode = cooked :: raw | cooked | disabled,

          %% Only used by xterm
          line_history :: [string()] | undefined,
          save_history :: boolean(), %% Whether get_line and get_until should save history
          expand_fun :: function() | undefined,
          expand_below :: boolean() | undefined,

          %% Used to push details about a input requests
          %% if there are multiple ones in progress.
          input_queue = queue:new(),

          %% Keeps extra data inbetween input routines
          buf = [] :: unicode:chardata() | eof,

          input = undefined :: #input_state{} | undefined,

          %% erXos: the reference of the group's one outstanding ask for
          %% input, or none (ask/1). It belongs to the group, not to the
          %% request being read, so a nested request, an interrupt and an
          %% error leave it outstanding for the next request.
          ask = none :: none | reference(),

          %% erXos: a loss held for the next request, which takes it first: the
          %% loss of a damaged request that ended other than by Ctrl-C or the end
          %% of input (pop_state/2), of input an error dropped (fail/3), or of an
          %% answer to no outstanding ask.
          held_loss = false :: boolean(),

          %% erXos: the line editor's kill buffer, the text the user last killed
          %% with its damage, which every edit takes and returns (edlin:read/0). It
          %% lives here, which format_status/1 hides from reports, and not in the
          %% process dictionary (edit 75 of docs/design-runtime.md says what a
          %% report hides and what the group's own domain sees).
          kill = edlin:empty_kill() :: edlin:kill()
        }).

-spec start(pid()) -> pid().
start(Drv) ->
    start(Drv, noshell).
-spec start(pid(), function() | nmfargs() | mfargs() | noshell) -> pid().

start(Drv, Shell) ->
    start(Drv, Shell, []).

-spec start(pid(), function() | nmfargs() | mfargs() | noshell,
            [{name, atom()} |
             {dumb, boolean()} |
             {echo, boolean()} |
             {expand_fun, function()} |
             {expand_below, boolean()}]) -> pid().
start(Drv, Shell, Options) ->
    {ok, Pid} =
        case proplists:get_value(name, Options) of
            undefined ->
                gen_statem:start(?MODULE, [Drv, Shell, Options], []);
            Name ->
                gen_statem:start({local, Name}, ?MODULE, [Drv, Shell, Options], [])
        end,
    Pid.

callback_mode() -> state_functions.

init([Drv, Shell, Options]) ->
    process_flag(trap_exit, true),

    %% Cleanup ancestors so that observer looks nice
    _ = [put('$ancestors',tl(get('$ancestors'))) || Shell =:= noshell],

    %% We link here instead of using start_link so that Drv does not become our parent
    %% We don't want Drv as our parent as Drv will send EXIT signals to us and we need
    %% to handle those and not just terminate.
    link(Drv),

    Dumb = proplists:get_value(dumb, Options, Shell =:= noshell),

    State = #state{
               driver = Drv,
               read_type = list,
               dumb = Dumb,
               save_history = not Dumb,

               %% echo is normally false for dumb and true for non-dumb, but when group is used by
               %% ssh, it can also be set to true when dumb is true.
               echo = proplists:get_value(echo, Options, not Dumb)

              },

    edlin:init(),

    {ok, init, State, {next_event, internal, [Shell, Options]}}.

%% erXos, edit 75: what the user typed stays out of the group's reports and of what
%% format_status/1 gives sys:get_status: the shell history, the kill buffer, the line
%% being typed (the input state of the request in progress and of each request a
%% nested one pushed, and buf, the keys read ahead of a request) and the driver's
%% input waiting in the queue or postponed, each such event keeping its shape with
%% its characters emptied. The sys log, which holds the same events, is shown empty.
%% The data is beside the state name, as gen_statem hands it over; stock OTP matches
%% the state name here and returns a record, which crashes on every call. Any other
%% map, such as proc_lib's #{reason => Reason}, holds no input.
format_status(Status) ->
    maps:map(fun(data, #state{} = Data) -> hidden_input(Data);
                (Key, Events) when Key =:= queue; Key =:= postponed ->
                     [hidden_event(Event) || Event <- Events];
                (log, _Log) -> [];
                (_Key, Value) -> Value
             end, Status).

hidden_input(#state{ input = Input, input_queue = Pushed } = Data) ->
    Data#state{ line_history = undefined, buf = [], kill = edlin:empty_kill(),
                input = hidden_input_state(Input),
                input_queue = queue:from_list([{State, hidden_input_state(PushedInput)}
                                               || {State, PushedInput} <- queue:to_list(Pushed)]) }.

hidden_input_state(#input_state{} = Input) ->
    Input#input_state{ cont = hidden, lines = hidden, io_lib_state = hidden };
hidden_input_state(undefined) ->
    undefined.

hidden_event({info, {Drv, {data, _Chars}}}) -> {info, {Drv, {data, []}}};
hidden_event({info, {Drv, {read, Ref, _Chars}}}) -> {info, {Drv, {read, Ref, []}}};
hidden_event(Event) -> Event.

init(internal, [Shell, Options], State = #state{ dumb = Dumb }) ->

    StartedShell = start_shell(Shell),

    NonDumbState =
        if not Dumb ->
                State#state{
                  line_history = group_history:load(),
                  expand_below = proplists:get_value(expand_below, Options, not Dumb),
                  expand_fun = normalize_expand_fun(Options, fun edlin_expand:expand/2)
                 };
           Dumb ->
                State
        end,

    {next_state, server, NonDumbState#state{ shell = StartedShell }}.

-spec whereis_shell() -> undefined | pid().
whereis_shell() ->
    case node(group_leader()) of
        Node when Node =:= node() ->
            case user_drv:whereis_group() of
                undefined -> undefined;
                GroupPid ->
                    {dictionary, Dict} = erlang:process_info(GroupPid, dictionary),
                    proplists:get_value(shell, Dict)
            end;
        OtherNode ->
            erpc:call(OtherNode, group, whereis_shell, [])
    end.

%% start_shell(Shell)
%%  Spawn a shell with its group_leader from the beginning set to ourselves.
%%  If Shell a pid the set its group_leader.

-spec start_shell(mfargs() | nmfargs() |
                  module() | function() | pid() | noshell) -> pid() | noshell.
start_shell(noshell) -> noshell;
start_shell({Mod,Func,Args}) ->
    start_shell_mfa(Mod, Func, Args);
start_shell({Node,Mod,Func,Args}) ->
    start_shell_mfa(erpc, call, [Node,Mod,Func,Args]);
start_shell(Shell) when is_atom(Shell) ->
    start_shell_mfa(Shell, start, []);
start_shell(Shell) when is_function(Shell) ->
    start_shell_fun(Shell);
start_shell(Shell) when is_pid(Shell) ->
    group_leader(self(), Shell),    % we are the shells group leader
    link(Shell),                % we're linked to it.
    put(shell, Shell),
    proc_lib:set_label({group, Shell}),
    Shell.

start_shell_mfa(M, F, Args) ->
    G = group_leader(),
    group_leader(self(), self()),
    case apply(M, F, Args) of
        Shell when is_pid(Shell) ->
            group_leader(G, self()),
            link(Shell),            % we're linked to it.
            proc_lib:set_label({group, {M, F, Args}}),
            put(shell, Shell),
            Shell;
        Error ->                % start failure
            exit(Error) % let the group process crash

    end.

start_shell_fun(Fun) ->
    G = group_leader(),
    group_leader(self(), self()),
    case Fun() of
        Shell when is_pid(Shell) ->
            group_leader(G, self()),
            link(Shell),            % we're linked to it.
            proc_lib:set_label({group, Fun}),
            put(shell, Shell),
            Shell;
        Error ->                % start failure
            exit(Error) % let the group process crash
    end.

%% When there are no outstanding input requests we are in this state
server(info, {io_request,From,ReplyAs,Req} = IOReq, Data) when is_pid(From), ?IS_INPUT_REQ(Req) ->
    log_io_request(IOReq, Data#state.log, server_name()),
    {next_state,
     if Data#state.dumb orelse not Data#state.echo -> dumb; true -> xterm end,
     %% erXos: a request starts damaged while any unfinished request is damaged, and
     %% takes a held loss first.
     Data#state{ input = #input_state{ from = From, reply_as = ReplyAs,
                                       damaged = Data#state.held_loss orelse
                                           any_damaged(Data#state.input_queue) },
                 held_loss = false },
     {next_event, internal, Req} };
server(info, {Drv, Event}, #state{ driver = Drv, shell = Shell })
  when Event =:= suspend; Event =:= winch ->
    %% erXos: Ctrl-Z or a size change while no line is read, as while the
    %% shell runs one.
    [Shell ! {self(), Event} || is_pid(Shell)],
    keep_state_and_data;
server(info, {Drv, _}, #state{ driver = Drv }) ->
    %% We postpone any Drv event sent to us as they are handled in xterm or dumb states
    {keep_state_and_data, postpone};
server(info, Msg, Data) ->
    handle_info(server, Msg, Data).

%% This is the dumb terminal state, also used for noshell and xterm get_password

%% When terminal_mode == raw, the terminal is in '{noshell,raw}'  mode, which means that
%% for get_until and get_chars we change the behaviour a bit so that characters are
%% delivered as they are typed instead of at new-lines.
dumb(internal, {get_chars, Encoding, Prompt, N}, Data = #state{ terminal_mode = raw }) ->
    dumb(input_request, {collect_chars_eager, N, Prompt, Encoding, fun get_chars_dumb/5}, Data);
dumb(internal, {get_line, Encoding, Prompt}, Data = #state{ terminal_mode = raw }) ->
    dumb(input_request, {collect_line, [], Prompt, Encoding, fun get_line_dumb/5}, Data);
dumb(internal, {get_until, Encoding, Prompt, M, F, As}, Data = #state{ terminal_mode = raw }) ->
    dumb(input_request, {get_until, {M, F, As}, Prompt, Encoding, fun get_chars_dumb/5}, Data);

dumb(internal, {get_chars, Encoding, Prompt, N}, Data) ->
    dumb(input_request, {collect_chars, N, Prompt, Encoding, fun get_chars_dumb/5}, Data);
dumb(internal, {get_line, Encoding, Prompt}, Data) ->
    dumb(input_request, {collect_line, [], Prompt, Encoding, fun get_line_dumb/5}, Data);
dumb(internal, {get_until, Encoding, Prompt, M, F, As}, Data) ->
    dumb(input_request, {get_until, {M, F, As}, Prompt, Encoding, fun get_line_dumb/5}, Data);

dumb(internal, {get_password, Encoding}, Data = #state{ terminal_mode = raw }) ->

    %% When getting the password we force echo to be off for the time of
    %% the get password and set a shell in order to use edit_line_dumb instead
    %% of edit_line_noshell.
    GetLine = fun(Buf, Pbs, Cont, LineEncoding, LineData) ->
                      get_line_dumb(Buf, Pbs, Cont, LineEncoding,
                                    LineData#state{ echo = false, shell = self() })
              end,
    dumb(input_request, {collect_line_no_eol, [], "", Encoding, GetLine}, Data);
dumb(internal, {get_password, _Encoding}, Data) ->
    %% TODO: Implement for noshell by disabling characters echo if isatty(stdin)
    io_reply(Data, {error, enotsup}),
    pop_state(error, Data);

dumb(input_request, {CollectF, CollectAs, Prompt, Encoding, GetFun},
     Data = #state{ input = OrigInputState }) ->

    InputState = OrigInputState#input_state{
                   prompt_bytes = prompt_bytes(Prompt, Encoding),
                   collect = {CollectF, CollectAs},
                   encoding = Encoding, get_fun = GetFun },

    dumb(data, Data#state.buf, Data#state{ input = InputState, buf = [] });

%% If we get an input request while handling this request we push the current state
%% and re-issue event in server state
dumb(info, {io_request, _From, _ReplyAs, Req}, Data) when ?IS_INPUT_REQ(Req) ->
    {next_state, server, push_state(dumb, Data), [{postpone, true}]};
dumb(internal, restore_input_request, Data = #state{ buf = Buf }) ->
    dumb(data, Buf, Data#state{ buf = [] });

%% erXos: the loss, which lose/1 has marked in every unfinished request.
dumb(data, lost, Data = #state{ driver = Drv }) ->
    send_drv(Drv, beep),
    {keep_state, ask(Data)};
dumb(data, Buf, Data = #state{ input = #input_state{ prompt_bytes = Pbs, encoding = Encoding,
                                                     io_lib_state = State, cont = Cont,
                                                     collect = {CollectF, CollectAs},
                                                     get_fun = GetFun, damaged = Damaged } = InputState }) ->

    %% Get a single line using get_line_dumb, or a single character using get_chars_dumb
    case GetFun(Buf, Pbs, Cont, Encoding, Data) of
        %% erXos: the input after the line that failed is dropped with the request.
        {no_translation, unicode, latin1, Unread} ->
            fail({error,{no_translation, unicode, latin1}}, Unread, Data);
        %% erXos: a damaged read returns no line: the end of input ends it, and a line
        %% is dropped with the bell.
        {done, _Dropped, eof} when Damaged ->
            io_reply(Data, eof),
            pop_state(eof, Data#state{ buf = eof });
        {done, _Dropped, RemainBuf} when Damaged ->
            send_drv(Data#state.driver, beep),
            dumb(data, RemainBuf, Data#state{ input = InputState#input_state{ cont = [] } });
        {done, NewLine, RemainBuf} ->
            EncodedLine = cast(NewLine, Data#state.read_type, Encoding),
            case io_lib:CollectF(State, EncodedLine, Encoding, CollectAs) of
                {stop, eof, _} ->
                    io_reply(Data, eof),
                    pop_state(eof, Data#state{ buf = eof });
                {stop, Result, eof} ->
                    io_reply(Data, Result),
                    pop_state(returned, Data#state{ buf = eof });
                {stop, Result, Rest} ->
                    io_reply(Data, Result),
                    pop_state(returned, Data#state{ buf = append(Rest, RemainBuf, Encoding) });
                {'EXIT',_} ->
                    fail({error,err_func(io_lib, CollectF, CollectAs)}, RemainBuf, Data);
                NewState ->
                    dumb(data, RemainBuf, Data#state{ input = InputState#input_state{ cont = undefined, io_lib_state = NewState } })
            end;
        {more_chars, NewCont} ->
            {keep_state, ask(Data#state{ input = InputState#input_state{ cont = NewCont } }) }
    end;

dumb(info, {Drv, activate}, #state{ driver = Drv }) ->
    keep_state_and_data;
dumb(info, Msg, Data) ->
    handle_info(dumb, Msg, Data).

%% The xterm state handles the "newshell" mode. This is the most advanced shell
%% that has a shell history, can open text editors and navigate in multiline shell
%% expressions.
xterm(internal, {get_chars, Encoding, Prompt, N}, Data) ->
    xterm(input_request, {collect_chars, N, Prompt, Encoding}, Data);
xterm(internal, {get_line, Encoding, Prompt}, Data) ->
    xterm(input_request, {collect_line, [], Prompt, Encoding}, Data);
xterm(internal, {get_until, Encoding, Prompt, M, F, As}, Data) ->
    xterm(input_request, {get_until, {M, F, As}, Prompt, Encoding}, Data);
xterm(internal, {get_password, Encoding}, Data) ->

    %% When getting the password we change state to dumb and use its
    %% implementation and set echo to false.
    GetLine = fun(Buf, Pbs, Cont, LineEncoding, LineData) ->
                      get_line_dumb(Buf, Pbs, Cont, LineEncoding,
                                    LineData#state{ echo = false  })
              end,
    case dumb(input_request, {collect_line_no_eol, [], "", Encoding, GetLine}, Data) of
        {keep_state, NewData} ->
            %% As we are currently in the xterm state, we transition to dumb
            {next_state, dumb, NewData};
        Else when element(1, Else) =:= next_state -> Else
    end;
xterm(input_request, {CollectF, CollectAs, Prompt, Encoding},
      Data = #state{ input = OrigInputState }) ->

    InputState = OrigInputState#input_state{
                   prompt_bytes = prompt_bytes(Prompt, Encoding),
                   collect = {CollectF, CollectAs},
                   save_history = Data#state.save_history,
                   encoding = Encoding },

    xterm(data, Data#state.buf, Data#state{ input = InputState, buf = [] });

xterm(info, {io_request, _From, _ReplyAs, Req}, Data = #state{ driver = Drv })
  when ?IS_INPUT_REQ(Req) ->
    %% We got an new input request while serving this one, we:
    %% * erase current line
    %% * push the current input state
    %% * re-issue the input event in the server state
    send_drv_reqs(Drv, edlin:erase_line()),
    {next_state, server, push_state(xterm, Data), [{postpone, true}]};
xterm(internal, restore_input_request,
      #state{ buf = Buf, driver = Drv, input = #input_state{ cont = {EdlinCont, _} }} = Data) ->
    %% We are restoring an input request so we redraw the line
    send_drv_reqs(Drv, edlin:redraw_line(EdlinCont)),
    xterm(data, Buf, Data#state{ buf = [] });

xterm(data, Buf, Data = #state{ input = #input_state{
                                           prompt_bytes = Pbs, encoding = Encoding,
                                           lines = Lines, cont = Cont,
                                           save_history = SaveHistory, damaged = Damaged,
                                           collect = {CollectF, CollectAs} } = InputState }) ->

    %% Get a single line using edlin
    case get_line_edlin(Buf, Pbs, Cont, Lines, Encoding, {Damaged, Data#state.kill}, Data) of
        {done, NewLines, RemainBuf, {Damaged1, Kill}} ->
            %% erXos: the request's damage after the edit, which pop_state/2 reads, and
            %% the kill buffer.
            Edited = Data#state{ input = InputState#input_state{ damaged = Damaged1 }, kill = Kill },
            CurrentLine = case RemainBuf of
                              %% erXos: edlin hands the end of input on only once it has
                              %% dropped the line (edit 81), so the reader reads the end.
                              eof -> eof;
                              _ -> cast(edlin:current_line(NewLines), Data#state.read_type, Encoding)
                          end,
            case io_lib:CollectF(start, CurrentLine, Encoding, CollectAs) of
                {stop, eof, _} ->
                    io_reply(Data, eof),
                    pop_state(eof, Edited#state{ buf = eof });
                {stop, Result, eof} ->
                    io_reply(Data, Result),
                    pop_state(returned, Edited#state{ buf = eof });
                {stop, Result, Rest} ->
                    %% Prompt was valid expression, clear the prompt in user_drv and redraw
                    %% the formatted expression.
                    FormattedLine = format_expression(NewLines, Data#state.driver),
                    [CL1|LB1] = lists:reverse(string:split(FormattedLine, "\n", all)),
                    LineCont1 = {LB1,{lists:reverse(CL1++"\n"), []},[]},
                    MultiLinePrompt = lists:duplicate(shell:prompt_width(Pbs), $\s),
                    send_drv_reqs(Data#state.driver, [{redraw_prompt, Pbs, MultiLinePrompt, LineCont1},new_prompt]),

                    NewHistory =
                        if SaveHistory ->
                                %% Save into history buffer if issued from shell process
                                save_line_buffer(string:trim(FormattedLine, both)++"\n",
                                                 Data#state.line_history);
                           not SaveHistory ->
                                Data#state.line_history
                        end,

                    io_reply(Data, Result),
                    pop_state(
                      returned,
                      Edited#state{ line_history = NewHistory,
                                    buf = append(Rest, RemainBuf, Encoding) });
                {'EXIT',_} ->
                    fail({error,err_func(io_lib, CollectF, CollectAs)}, RemainBuf, Edited);
                _NewState ->
                    xterm(data, RemainBuf, Edited#state{ input = InputState#input_state{ cont = undefined, lines = NewLines,
                                                                                        damaged = Damaged1 } })
            end;
        {blink, NewCont, {Damaged1, Kill}} ->
            {keep_state, ask(Data#state{ input = InputState#input_state{ cont = NewCont, damaged = Damaged1 },
                                         kill = Kill }), 1000};
        {more_chars, NewCont, {Damaged1, Kill}} ->
            {keep_state, ask(Data#state{ input = InputState#input_state{ cont = NewCont, damaged = Damaged1 },
                                         kill = Kill }) }
    end;

xterm(info, {io_request,From,ReplyAs,Req}, State)
  when ?IS_PUTC_REQ(Req) ->
    putc_request(Req, From, ReplyAs, State),
    keep_state_and_data;

xterm(info, {Drv, activate},
      #state{ driver = Drv, input = #input_state{ cont = {EdlinCont, _} } }) ->
    send_drv_reqs(Drv, edlin:redraw_line(EdlinCont)),
    keep_state_and_data;

xterm(info, Msg, Data) ->
    handle_info(xterm, Msg, Data);

xterm(timeout, 1000, Data) ->
    %% Blink timeout triggered
    xterm(data, [], Data).

%% erXos: the line editor waits for more input. The driver is asked for it
%% only when no ask of the group's is outstanding, so a driver that reads its
%% terminal only for an ask never hands the group a byte it did not ask for
%% (docs/design-shell.md, "The console reads on demand").
ask(Data = #state{ ask = none, driver = Drv }) ->
    Ref = make_ref(),
    Drv ! {self(), read, Ref},
    Data#state{ ask = Ref };
ask(Data) ->
    Data.

%% Handle the info messages that needs to be managed in all states
handle_info(State, {Drv, {read, Ref, Chars}}, Data = #state{ driver = Drv, ask = Ref })
  when is_list(Chars); is_binary(Chars) ->
    %% erXos: the answer to the outstanding ask ends it.
    ?MODULE:State(data, Chars, Data#state{ ask = none });
handle_info(State, {Drv, {read, Ref, lost}}, Data = #state{ driver = Drv, ask = Ref }) ->
    %% erXos: the ask's answer where input was lost.
    ?MODULE:State(data, lost, lose(Data#state{ ask = none }));
handle_info(_State, {Drv, {read, _Stray, Answer}}, Data = #state{ driver = Drv })
  when Answer =:= lost; is_list(Answer); is_binary(Answer) ->
    %% erXos: an answer to no outstanding ask, a loss or characters the group cannot
    %% place, is input lost: it damages every unfinished request and is held for the
    %% next one, so no loss is silent (edit 81).
    {keep_state, lose(Data#state{ held_loss = true })};
handle_info(State, {Drv, {data, Buf}}, Data = #state{ driver = Drv }) ->
    ?MODULE:State(data, Buf, Data);
handle_info(State, {Drv, eof}, Data = #state{ driver = Drv }) ->
    ?MODULE:State(data, eof, Data);
handle_info(_State, {Drv, echo, Bool}, Data = #state{ driver = Drv }) ->
    {keep_state, Data#state{ echo = Bool } };
handle_info(_State, {Drv, {error, _} = Error}, Data = #state{ driver = Drv }) ->
    fail(Error, Data#state.buf, Data);
handle_info(_State, {Drv, terminal_mode, Mode}, Data = #state{ driver = Drv }) ->
    noshell = Data#state.shell,
    true = lists:member(Mode, [raw, cooked, disabled]),
    {keep_state, Data#state{ terminal_mode = Mode }};

handle_info(_State, {io_request, From, ReplyAs, {setopts, Opts}}, Data) ->
    {Reply, NewData} = setopts(Opts, Data),
    io_reply(From, ReplyAs, Reply),
    {keep_state, NewData};
handle_info(_State, {io_request,From,ReplyAs, getopts}, Data) ->
    io_reply(From, ReplyAs, getopts(Data)),
    keep_state_and_data;
handle_info(_State, {io_request,From,ReplyAs, {get_geometry, What}}, Data) ->
    case get_tty_geometry(Data#state.driver) of
        {Width, _Height} when What =:= columns->
            io_reply(From, ReplyAs, Width);
        {_Width, Height} when What =:= rows->
            io_reply(From, ReplyAs, Height);
        _ ->
            io_reply(From, ReplyAs, {error, enotsup})
    end,
    keep_state_and_data;
handle_info(_State, {io_request,From,ReplyAs,Req}, Data) when ?IS_PUTC_REQ(Req) ->
    putc_request(Req, From, ReplyAs, Data);
handle_info(_State, {io_request,From,ReplyAs, _Req}, _Data) ->
    io_reply(From, ReplyAs, {error, request}),
    keep_state_and_data;

handle_info(_State, {reply, undefined, _Reply}, _Data) ->
    %% Ignore any reply with an undefined From.
    keep_state_and_data;
handle_info(_State, {reply,{From,ReplyAs},Reply}, _Data) ->
    io_reply(From, ReplyAs, Reply),
    keep_state_and_data;

handle_info(_State, {driver_id,ReplyTo}, Data) -> %% TODO: Remove this?
    ReplyTo ! {self(),driver_id, Data#state.driver},
    keep_state_and_data;
handle_info(_State, {'EXIT', Drv, interrupt}, #state{ driver = Drv, shell = Shell, input = undefined }) ->
    %% Send interrupt to the shell of there is no current input request
    [exit(Shell, interrupt) || is_pid(Shell)],
    keep_state_and_data;
handle_info(_State, {'EXIT', Drv, interrupt}, #state{ driver = Drv }  = Data) ->
    %% Interrupt current input request
    io_reply(Data, {error, interrupted}),
    pop_state(interrupted, Data#state{ buf = [] });

handle_info(_State, {Drv, Event}, #state{ driver = Drv, shell = Shell })
  when Event =:= suspend; Event =:= winch ->
    %% erXos: the terminal's Ctrl-Z, which stops the foreground job of the
    %% command shell, and a change of the terminal's size, which reaches the
    %% foreground job's processes that asked for it. The shell alone knows its
    %% jobs, so the group passes both on, as it passes Ctrl-C on as an interrupt.
    [Shell ! {self(), Event} || is_pid(Shell)],
    keep_state_and_data;
handle_info(_State, {'EXIT',Drv,_R}, #state{ driver = Drv } = Data) ->
    [ exit(Data#state.shell, kill)
      || is_pid(Data#state.shell) andalso Data#state.input =/= undefined],
    {stop, normal};
handle_info(_State, {'EXIT',Shell,R}, #state{ shell = Shell, driver = Drv }) ->
    %% We propagate the error reason from the shell to the driver, but we don't
    %% want to exit ourselves with that reason as it will generate crash report
    %% messages that we do not want.
    exit(Drv, R),
    {stop, normal};

handle_info(_State, _UnknownEvent, _Data) ->
    %% Ignore this unknown message.
    keep_state_and_data.

%% erXos: a loss damages every unfinished request, the current one and each one set
%% aside, since the group's one ask may be answered to a request other than the one
%% the lost bytes were meant for (edit 81).
lose(Data = #state{ input = Input, input_queue = Queue }) ->
    Data#state{ input = Input#input_state{ damaged = true },
                input_queue = queue:from_list([{State, Set#input_state{ damaged = true }}
                                               || {State, Set} <- queue:to_list(Queue)]) }.

%% erXos: whether any request set aside is damaged, the group's damage, derived and
%% stored nowhere.
any_damaged(Queue) ->
    lists:any(fun({_State, #input_state{ damaged = Damaged }}) -> Damaged end,
              queue:to_list(Queue)).

%% erXos: ends the current request with Error and drops Unread, the input read but not
%% yet taken, with the group's buffer. Dropped input is input lost, so when Unread held
%% any a loss is held for the next request (edit 81).
fail(Error, Unread, Data) ->
    io_reply(Data, Error),
    pop_state(error, Data#state{ buf = [],
                                 held_loss = Data#state.held_loss orelse holds_input(Unread) }).

holds_input(eof) -> false;
holds_input(Unread) -> not string:is_empty(Unread).

%% When we get an input request while already serving another, we
%% push the state of the current request into the input_queue and
%% switch to handling the new request.
push_state(State, Data) ->
    Data#state{ input_queue = queue:in({State, Data#state.input}, Data#state.input_queue) }.

%% erXos: ends the current request, which ended How: interrupted (the user's Ctrl-C),
%% eof (the end of input), returned (with its answer) or error. Only the user's
%% discard and the end of input end a damaged request's loss; any other ending, a
%% returned one included, holds it for the next request, so an ending that forgets to
%% say how it ended over-damages rather than drops a loss (edit 81).
pop_state(How, Data = #state{ input = #input_state{ damaged = Damaged } }) ->
    Ends = How =:= interrupted orelse How =:= eof,
    resume_set_aside(Data#state{ held_loss = Data#state.held_loss orelse (Damaged andalso not Ends) }).

%% When an input request is done we then need to check if there was
%% another request in progress, and if so we pop its state and resume it.
%% erXos: reached only through pop_state/2, so every ending says how it ended.
resume_set_aside(Data) ->
    case queue:out(Data#state.input_queue) of
        {empty, _} ->
            {next_state, server, Data#state{ input = undefined }};
        {{value, {State, InputState}}, NewInputQueue} ->
            %% erXos: the request resumed takes a held loss first (pop_state/2).
            Resumed = InputState#input_state{ damaged = InputState#input_state.damaged orelse
                                                  Data#state.held_loss },
            {next_state, State, Data#state{ input = Resumed, input_queue = NewInputQueue,
                                            held_loss = false },
             {next_event, internal, restore_input_request } }
    end.

%% Functions for getting data from the driver
get_tty_geometry(Drv) ->
    Drv ! {self(),tty_geometry},
    receive
        {Drv,tty_geometry,Geometry} ->
            Geometry
    after 2000 ->
            timeout
    end.
get_unicode_state(Drv) ->
    Drv ! {self(),get_unicode_state},
    receive
        {Drv,get_unicode_state,UniState} ->
            UniState;
        {Drv,get_unicode_state,error} ->
            {error, internal}
    after 2000 ->
            {error,timeout}
    end.
set_unicode_state(Drv,Bool) ->
    Drv ! {self(),set_unicode_state,Bool},
    receive
        {Drv,set_unicode_state,_OldUniState} ->
            ok
    after 2000 ->
            timeout
    end.

get_terminal_state(Drv) ->
    Drv ! {self(),get_terminal_state},
    receive
        {Drv,get_terminal_state,Terminal} ->
            Terminal;
        {Drv,get_terminal_state,error} ->
            {error, internal}
    after 2000 ->
            {error,timeout}
    end.

%% This function handles any put_chars request
putc_request(Req, From, ReplyAs, State) ->
    log_io_request({io_request, From, ReplyAs, Req}, State#state.log, server_name()),
    case putc_request(Req, State#state.driver, {From, ReplyAs}) of
        {reply,Reply} ->
            io_reply(From, ReplyAs, Reply),
            keep_state_and_data;
        noreply ->
            %% We expect a {reply,_} message from the Drv when request is done
            keep_state_and_data
    end.

%% Put_chars, unicode is the normal message, characters are always in
%% standard unicode format.
%% You might be tempted to send binaries unchecked, but the driver
%% expects unicode, so that is what we should send...
%% putc_request({put_chars,unicode,Binary}, Drv, Buf) when is_binary(Binary) ->
%%     send_drv(Drv, {put_chars,Binary}),
%%     {ok,ok,Buf};
%%
%% These put requests have to be synchronous to the driver as otherwise
%% there is no guarantee that the data has actually been printed.
putc_request({put_ansi, Opts, Ansi}, Drv, From) ->
    send_drv(Drv, {put_ansi_sync, Opts, Ansi, From}),
    noreply;
putc_request({put_chars,unicode,Chars}, Drv, From) ->
    case catch unicode:characters_to_binary(Chars,utf8) of
        Binary when is_binary(Binary) ->
            send_drv(Drv, {put_chars_sync, unicode, Binary, From}),
            noreply;
        _ ->
            {reply,{error,{put_chars, unicode,Chars}}}
    end;
putc_request({put_chars,unicode,M,F,As}, Drv, From) ->
    case catch apply(M, F, As) of
        Binary when is_binary(Binary) ->
            send_drv(Drv, {put_chars_sync, unicode, Binary, From}),
            noreply;
        Chars ->
            case catch unicode:characters_to_binary(Chars,utf8) of
                B when is_binary(B) ->
                    send_drv(Drv, {put_chars_sync, unicode, B, From}),
                    noreply;
                _ ->
                    {reply,{error,F}}
            end
    end;
putc_request({put_chars,latin1,Output}, Drv, From) ->
    send_drv(Drv, {put_chars_sync, latin1, Output, From}),
    noreply;
putc_request({put_chars,latin1,M,F,As}, Drv, From) ->
    case catch apply(M, F, As) of
        Ret when is_list(Ret) =:= false, is_binary(Ret) =:= false ->
            {reply, {error, F}};
        Chars -> send_drv(Drv, {put_chars_sync, latin1, Chars, From}),
            noreply
    end;
putc_request({requests,Reqs}, Drv, From) ->
    putc_requests(Reqs, {reply, ok}, Drv, From);

%% BC with pre-R13
putc_request({put_chars,Chars}, Drv, From) ->
    putc_request({put_chars,latin1,Chars}, Drv, From);
putc_request({put_chars,M,F,As}, Drv, From) ->
    putc_request({put_chars,latin1,M,F,As}, Drv, From);

putc_request(_, _Drv, _From) ->
    {error,{error,request}}.

%% Status = putc_requests(RequestList, PrevStat, From, Drv, Shell)
%%  Process a list of output requests as long as
%%  the previous status is 'ok' or noreply.
%%
%%  We use undefined as the From for all but the last request
%%  in order to discards acknowledgements from those requests.
%%
putc_requests([R|Rs], noreply, Drv, From) ->
    ReqFrom = if Rs =:= [] -> From; true -> undefined end,
    putc_requests(Rs, putc_request(R, Drv, ReqFrom), Drv, From);
putc_requests([R|Rs], {reply,ok}, Drv, From) ->
    ReqFrom = if Rs =:= [] -> From; true -> undefined end,
    putc_requests(Rs, putc_request(R, Drv, ReqFrom), Drv, From);
putc_requests([_|_], Error,  _Drv, _From) ->
    Error;
putc_requests([], Stat, _Drv, _From) ->
    Stat.

%% io_reply(From, ReplyAs, Reply)
%%  The function for sending i/o command acknowledgement.
%%  The ACK contains the return value.

io_reply(#state{ input = #input_state{ from = From, reply_as = As } }, Reply) ->
    io_reply(From, As, Reply).

io_reply(undefined, _ReplyAs, _Reply) ->
    %% Ignore these replies as they are generated from io_requests/5.
    ok;
io_reply(From, ReplyAs, Reply) ->
    From ! {io_reply,ReplyAs,Reply},
    ok.

%% send_drv(Drv, Message)
%% send_drv_reqs(Drv, Requests)

send_drv(Drv, Msg) ->
    Drv ! {self(),Msg},
    ok.

send_drv_reqs(_Drv, []) -> ok;
send_drv_reqs(Drv, Rs) ->
    send_drv(Drv, {requests,Rs}).

expand_encoding([]) ->
    [];
expand_encoding([latin1 | T]) ->
    [{encoding,latin1} | expand_encoding(T)];
expand_encoding([unicode | T]) ->
    [{encoding,unicode} | expand_encoding(T)];
expand_encoding([H|T]) ->
    [H|expand_encoding(T)].
%% setopts
setopts(Opts0,Data) ->
    Opts = proplists:unfold(
             proplists:substitute_negations(
               [{list,binary}],
               expand_encoding(Opts0))),
    case check_valid_opts(Opts, Data#state.shell =/= noshell) of
        true ->
            do_setopts(Opts,Data);
        false ->
            {{error,enotsup},Data}
    end.
check_valid_opts([], _) ->
    true;
check_valid_opts([{binary,Flag}|T], HasShell) when is_boolean(Flag) ->
    check_valid_opts(T, HasShell);
check_valid_opts([{encoding,Valid}|T], HasShell) when Valid =:= unicode;
                                                      Valid =:= utf8;
                                                      Valid =:= latin1 ->
    check_valid_opts(T, HasShell);
check_valid_opts([{echo,Flag}|T], HasShell) when is_boolean(Flag) ->
    check_valid_opts(T, HasShell);
check_valid_opts([{line_history,Flag}|T], HasShell = true) when is_boolean(Flag) ->
    check_valid_opts(T, HasShell);
check_valid_opts([{expand_fun,Fun}|T], HasShell = true) when is_function(Fun, 1);
                                                             is_function(Fun, 2) ->
    check_valid_opts(T, HasShell);
check_valid_opts([{log,Flag}|T], HasShell) ->
    case lists:member(Flag, [none, output, input, all]) of
        true -> check_valid_opts(T, HasShell);
        false -> false
    end;
check_valid_opts(_, _HasShell) ->
    false.

do_setopts(Opts, Data) ->
    ExpandFun = normalize_expand_fun(Opts, Data#state.expand_fun),
    Echo = proplists:get_value(echo, Opts, Data#state.echo),
    case proplists:get_value(encoding, Opts) of
        Valid when Valid =:= unicode; Valid =:= utf8 ->
            set_unicode_state(Data#state.driver,true);
        latin1 ->
            set_unicode_state(Data#state.driver,false);
        undefined ->
            ok
    end,
    ReadType =
        case proplists:get_value(binary, Opts,
                                 case Data#state.read_type of
                                     binary -> true;
                                     _ -> false
                                 end) of
            true ->
                binary;
            false ->
                list
        end,
    LineHistory = proplists:get_value(line_history, Opts, Data#state.save_history),
    Log = proplists:get_value(log, Opts, Data#state.log),
    {ok, Data#state{ expand_fun = ExpandFun, echo = Echo, read_type = ReadType,
                     save_history = LineHistory, log = Log }}.

normalize_expand_fun(Options, Default) ->
    case proplists:get_value(expand_fun, Options, Default) of
        Fun when is_function(Fun, 1) -> fun(X,_) -> Fun(X) end;
        Fun -> Fun
    end.

getopts(Data) ->
    Exp = {expand_fun, case Data#state.expand_fun of
                           Func when is_function(Func) ->
                               Func;
                           _ ->
                               false
                       end},
    Echo = {echo, case Data#state.echo of
                      Bool when Bool =:= true; Bool =:= false ->
                          Bool;
                      _ ->
                          false
                  end},
    LineHistory = {line_history,
                   case Data#state.save_history of
                       HistBool when HistBool =:= true; HistBool =:= false ->
                           HistBool;
                       _ ->
                           false
                   end},
    Log = {log, Data#state.log},
    Bin = {binary, case Data#state.read_type of
                       binary ->
                           true;
                       _ ->
                           false
                   end},
    Uni = {encoding, case get_unicode_state(Data#state.driver) of
                         true -> unicode;
                         _ -> latin1
                     end},
    case get_terminal_state(Data#state.driver) of
        Terminal when is_map(Terminal) ->
            Tty = {terminal, maps:get(stdout, Terminal)},
            [Exp,Echo,LineHistory,Log,Bin,Uni,Tty|maps:to_list(Terminal)];
        Error ->
            Error
    end.

%% Convert error code to make it look as before
err_func(io_lib, get_until, {_,F,_}) ->
    F;
err_func(_, F, _) ->
    F.

%% get_line(Chars, PromptBytes, Drv)
%%  Get a line with eventual line editing.
%%  Returns:
%%      {done,LineChars,RestChars}
%%      {more_data, Cont, Ls}
%%      {blink, Cons, Ls}

-record(get_line_edlin_state, {history, encoding, expand_fun, expand_below,
                               search, search_quit_prompt, search_result}).

get_line_edlin(Chars, Pbs, undefined, Lines, Encoding, Read,
               #state{ driver = Drv, line_history = History,
                       expand_fun = ExpandFun, expand_below = ExpandBelow}) ->
    {more_chars,Cont1,Rs} = case Lines of
                                [] -> edlin:start(Pbs);
                                _ -> edlin:start(Pbs, Lines)
                            end,
    send_drv_reqs(Drv, Rs),
    get_line_edlin(edlin:edit_line(Chars, Cont1, Read), Drv, #get_line_edlin_state{
                                                          history = new_stack(History),
                                                          encoding = Encoding,
                                                          expand_fun = ExpandFun,
                                                          expand_below = ExpandBelow });
get_line_edlin(Chars, _Pbs, {EdlinCont, GetLineState}, _Lines, _Encoding, Read,
               #state{ driver = Drv }) ->
    get_line_edlin(edlin:edit_line(cast(Chars, list), EdlinCont, Read),
                   Drv, GetLineState).

get_line_edlin({{done, Cont, Rest, Rs}, Read}, Drv, _State) ->
    send_drv_reqs(Drv, Rs),
    {done, Cont, Rest, Read};
get_line_edlin({{open_editor, _Cs, Cont, Rs}, Read}, Drv, State) ->
    send_drv_reqs(Drv, Rs),
    Buffer = edlin:current_line(Cont),
    send_drv(Drv, {open_editor, Buffer}),
    receive
        {Drv, {editor_data, Cs1}} ->
            send_drv_reqs(Drv, edlin:erase_line()),
            {more_chars,NewCont,NewRs} = edlin:start(edlin:prompt(Cont)),
            send_drv_reqs(Drv, NewRs),
            get_line_edlin(edlin:edit_line(Cs1, NewCont, Read), Drv, State);
        {Drv, not_supported} ->
            get_line_edlin(edlin:edit_line(_Cs, Cont, Read), Drv, State)
    end;
get_line_edlin({{format_expression, _Cs, {line, _, _, _} = Cont, Rs}, Read}, Drv, State) ->
    send_drv_reqs(Drv, Rs),
    Cs1 = format_expression(Cont, Drv),
    send_drv_reqs(Drv, edlin:erase_line()),
    {more_chars,NewCont,NewRs} = edlin:start(edlin:prompt(Cont)),
    send_drv_reqs(Drv, NewRs),
    get_line_edlin(edlin:edit_line(Cs1, NewCont, Read), Drv, State);
%% Move Up, Down in History: Ctrl+P, Ctrl+N
get_line_edlin({{history_up,Cs,{_,_,_,Mode0}=Cont,Rs}, Read}, Drv, State) ->
    send_drv_reqs(Drv, Rs),
    case up_stack(keep_line(State#get_line_edlin_state.history, edlin:current_line(Cont), Read)) of
        {none,_Ls} ->
            send_drv(Drv, beep),
            get_line_edlin(edlin:edit_line(Cs, Cont, Read), Drv, State);
        {Lcs,Ls} ->
            send_drv_reqs(Drv, edlin:erase_line()),
            {more_chars,{A,B,C,_},Nrs} = edlin:start(edlin:prompt(Cont)),
            Ncont = {A,B,C,Mode0},
            send_drv_reqs(Drv, Nrs),
            get_line_edlin(
              edlin:edit_line1(
                string:to_graphemes(
                  lists:sublist(Lcs, 1, length(Lcs)-1)),
                Ncont, Read),
              Drv, State#get_line_edlin_state{ history = Ls })
    end;
get_line_edlin({{history_down,Cs,{_,_,_,Mode0}=Cont,Rs}, Read}, Drv, State) ->
    send_drv_reqs(Drv, Rs),
    case down_stack(keep_line(State#get_line_edlin_state.history, edlin:current_line(Cont), Read)) of
        {none,_Ls} ->
            send_drv(Drv, beep),
            get_line_edlin(edlin:edit_line(Cs, Cont, Read), Drv, State);
        {Lcs,Ls} ->
            send_drv_reqs(Drv, edlin:erase_line()),
            {more_chars,{A,B,C,_},Nrs} = edlin:start(edlin:prompt(Cont)),
            Ncont = {A,B,C,Mode0},
            send_drv_reqs(Drv, Nrs),
            get_line_edlin(edlin:edit_line1(string:to_graphemes(lists:sublist(Lcs,
                                                                              1,
                                                                              length(Lcs)-1)),
                                            Ncont, Read),
                           Drv, State#get_line_edlin_state{ history = Ls })
    end;
%% ^R = backward search, ^S = forward search.
%% Search is tricky to implement and does a lot of back-and-forth
%% work with edlin.erl (from stdlib). Edlin takes care of writing
%% and handling lines and escape characters to get out of search,
%% whereas this module does the actual searching and appending to lines.
%% Erlang's shell wasn't exactly meant to traverse the wall between
%% line and line stack, so we at least restrict it by introducing
%% new modes: search, search_quit, search_found. These are added to
%% the regular ones (none, meta_left_sq_bracket) and handle special
%% cases of history search.
get_line_edlin({{search,Cs,Cont,Rs}, Read}, Drv, State) ->
    send_drv_reqs(Drv, Rs),
    %% drop current line, move to search mode. We store the current
    %% prompt ('N>') and substitute it with the search prompt.
    Pbs = prompt_bytes("\033[;1;4msearch:\033[0m ", State#get_line_edlin_state.encoding),
    {more_chars,Ncont,_Nrs} = edlin:start(Pbs, {search,none}),
    get_line_edlin(edlin:edit_line1(Cs, Ncont, Read), Drv,
                   State#get_line_edlin_state{ search = new_search,
                                               search_quit_prompt = Cont});
get_line_edlin({{Help, Before, Cs0, Cont, Rs}, Read}, Drv, State)
    when Help =:= help; Help =:= help_full ->
    send_drv_reqs(Drv, Rs),
    NLines = case Help of
        help -> 7;
        help_full -> 0
    end,
    {_,Word,_} = edlin:over_word(Before, [], 0),
    {R,Docs} = case edlin_context:get_context(Before) of
                   {function, Mod} when Word =/= [] -> try
                                                           {ok, [{atom,_,Module}], _} = erl_scan:string(Mod),
                                                           {ok, [{atom,_,Word1}], _} = erl_scan:string(Word),
                                                           {function, c:h1(Module, Word1)}
                                                       catch _:_ ->
                                                               {ok, [{atom,_,Module1}], _} = erl_scan:string(Mod),
                                                               {module, c:h1(Module1)}
                                                       end;
                   {function, Mod} ->
                       {ok, [{atom,_,Module}], _} = erl_scan:string(Mod),
                       {module, c:h1(Module)};
                   {function, Mod, Fun, _Args, _Unfinished, _Nesting} ->
                       {ok, [{atom,_,Module}], _} = erl_scan:string(Mod),
                       {ok, [{atom,_,Function}], _} = erl_scan:string(Fun),
                       {function, c:h1(Module, Function)};
                   {term, _, {atom, Word1}}->
                       {ok, [{atom,_,Module}], _} = erl_scan:string(Word1),
                       {module, c:h1(Module)};
                   _ -> {error, {error, no_help}}
               end,
    case {R, Docs} of
        {_, {error, _}} -> send_drv(Drv, beep);
        {module, _} ->
            Docs1 = "  "++string:trim(lists:nthtail(3, Docs),both),
            send_drv(Drv, {put_expand, unicode,
                           [unicode:characters_to_binary(Docs1)], NLines});
        {function, _} ->
            Docs1 = "  "++string:trim(Docs,both),
            send_drv(Drv, {put_expand, unicode,
                           [unicode:characters_to_binary(Docs1)], NLines})
    end,
    get_line_edlin(edlin:edit_line(Cs0, Cont, Read), Drv, State);
get_line_edlin({{Expand, Before, Cs0, Cont,Rs}, Read}, Drv, State = #get_line_edlin_state{ expand_fun = ExpandFun })
  when Expand =:= expand; Expand =:= expand_full ->
    send_drv_reqs(Drv, Rs),
    {Found, CompleteChars, Matches} = ExpandFun(Before, []),
    case Found of
        no -> send_drv(Drv, beep);
        _ -> ok
    end,
    {Width, _Height} = get_tty_geometry(Drv),
    Cs1 = append(CompleteChars, Cs0, State#get_line_edlin_state.encoding),

    MatchStr = case Matches of
                   [] -> [];
                   _ -> edlin_expand:format_matches(Matches, Width)
               end,
    Cs = case {Cs1, MatchStr} of
             {_, []} -> Cs1;
             {Cs1, _} when Cs1 =/= [] -> Cs1;
             _ ->
                 NlMatchStr = unicode:characters_to_binary("\n"++MatchStr),
                 NLines = case Expand of
                              expand -> 7;
                              expand_full -> 0
                          end,
                 case State#get_line_edlin_state.expand_below of
                     true ->
                         send_drv(Drv, {put_expand, unicode, unicode:characters_to_binary(string:trim(MatchStr, trailing)), NLines}),
                         Cs1;
                     false ->
                         send_drv(Drv, {put_chars, unicode, NlMatchStr}),
                         [$\e, $l | Cs1]
                 end
         end,
    get_line_edlin(edlin:edit_line(Cs, Cont, Read), Drv, State);

%% The search item was found and accepted (new line entered on the exact
%% result found)
get_line_edlin({{search_found,_Cs,_,Rs}, Read}, Drv, State) ->
    LineCont = case State#get_line_edlin_state.search_result of
                   [] -> {[],{[],[]},[]};
                   SearchResult ->
                       [Last| LB] = lists:reverse(SearchResult),
                       {LB, {lists:reverse(Last),[]},[]}
               end,
    Prompt = edlin:prompt(State#get_line_edlin_state.search_quit_prompt),
    send_drv_reqs(Drv, Rs),
    send_drv_reqs(Drv, edlin:erase_line()),
    Found = {line, Prompt, LineCont, {normal,none}},
    send_drv_reqs(Drv, edlin:redraw_line(Found)),
    %% erXos: edlin finishes the line, as it finishes every line, so a damaged read's
    %% line stays in the editor here too.
    get_line_edlin(edlin:finish_line(Found, Rs, Read), Drv,
                   State#get_line_edlin_state{ search_result = []});
%% The search mode has been exited, but the user wants to remain in line
%% editing mode wherever that was, but editing the search result.
get_line_edlin({{search_quit,_Cs,_,Rs}, Read}, Drv, State) ->
    %% Load back the old prompt with the correct line number.
    case edlin:prompt(State#get_line_edlin_state.search_quit_prompt) of
        Prompt -> % redraw the line and keep going with the same stack position
            L = case State#get_line_edlin_state.search_result of
                    [] -> {[],{[],[]},[]};
                    SearchResult  ->
                        [Last|LB] = lists:reverse(SearchResult),
                        {LB, {lists:reverse(Last), []}, []}
                end,
            NCont = {line,Prompt,L,{normal,none}},
            send_drv_reqs(Drv, [delete_line|Rs]),
            send_drv_reqs(Drv, edlin:redraw_line(NCont)),
            get_line_edlin({{more_chars, NCont ,[]}, Read}, Drv,
                           State#get_line_edlin_state{ history = pad_stack(State#get_line_edlin_state.history),
                                                       search_result = [] })
    end;
get_line_edlin({{search_cancel,_Cs,_,Rs}, Read}, Drv, State = #get_line_edlin_state{ search_quit_prompt = NCont }) ->
    send_drv_reqs(Drv, [delete_line|Rs]),
    send_drv_reqs(Drv, edlin:redraw_line(NCont)),
    get_line_edlin({{more_chars, NCont, []}, Read}, Drv, State#get_line_edlin_state{ search_result = [] });
%% Search mode is entered.
get_line_edlin({{What,{line,Prompt,{_,{RevCmd0,_},_},{search, none}}=Cont0,Rs}, Read},
               Drv, State = #get_line_edlin_state{ search = OldSearch, history = Ls0 }) ->
    %% Figure out search direction. ^S and ^R are returned through edlin
    %% whenever we received a search while being already in search mode.
    {Search, Ls1, RevCmd} = case RevCmd0 of
                                [$\^S|RevCmd1] ->
                                    {fun search_down_stack/2, Ls0, RevCmd1};
                                [$\^R|RevCmd1] ->
                                    {fun search_up_stack/2, Ls0, RevCmd1};
                                _ when RevCmd0 =/= OldSearch -> % new search, rewind stack for a proper search.
                                    {fun search_up_stack/2, new_stack(get_lines(Ls0)), RevCmd0};
                                _ ->
                                    {skip, Ls0, RevCmd0}
                            end,
    Cmd = lists:reverse(RevCmd),
    if Search =:= skip ->
            %% Move expand are the only valid requests to bypass search mode
            %% Sending delete_chars, insert_chars, etc. will result in
            %% expand area being cleared.
            Rs1 = [R||{move_expand,_}=R<-Rs],
            send_drv_reqs(Drv, Rs1),
            {What, {Cont0, State#get_line_edlin_state{ search = RevCmd }}, Read};
       true ->
            {Ls, SearchResult, NewStack} = case Search(Ls1, Cmd) of
                                               {none, Ls2} ->
                                                   send_drv(Drv, beep),
                                                   send_drv(Drv, delete_line),
                                                   send_drv(Drv, {insert_chars, unicode, unicode:characters_to_binary(Prompt++Cmd)}),
                                                   {Ls2, [], {[],{RevCmd, []},[]}};
                                               {Line, Ls2} -> % found. Complete the output edlin couldn't have done.
                                                   Lines = string:split(string:to_graphemes(Line), "\n", all),
                                                   send_drv(Drv, delete_line),
                                                   send_drv(Drv, {insert_chars, unicode, unicode:characters_to_binary(Prompt++Cmd)}),
                                                   send_drv(Drv, {put_expand, unicode, unicode:characters_to_binary("  "++lists:join("\n  ",Lines)), 7}),
                                                   {Ls2, Lines, {[],{RevCmd, []},[]}}
                                           end,
            Cont = {line,Prompt,NewStack,{search, none}},
            {What, {Cont, State#get_line_edlin_state{ history = Ls, search = RevCmd, search_result = SearchResult }}, Read}
    end;
get_line_edlin({{What,Cont0,Rs}, Read}, Drv, State) ->
    send_drv_reqs(Drv, Rs),
    {What, {Cont0, State}, Read}.

format_expression(Cont, Drv) ->
    FormatingCommand = application:get_env(stdlib, format_shell_func, default),
    Buffer = edlin:current_line(Cont),
    try
        case FormatingCommand of
            default ->
                string:trim(Buffer, trailing, "\n");
            {M,F} when is_atom(M), is_atom(F) ->
                M:F(Buffer);
            FormatingCommand1 when is_list(FormatingCommand1) ->
                format_expression1(Buffer, FormatingCommand1)
        end
    catch _:_ ->
            send_drv_reqs(Drv, [{put_chars, unicode, io_lib:format("* Bad format function: ~tp~n", [FormatingCommand])}]),
            _ = shell:format_shell_func(default),
            string:trim(Buffer, trailing, "\n")
    end.
format_expression1(Buffer, FormatingCommand) ->
    %% Write the current expression to a file, format it with a formatting tool
    %% provided by the user and read the file back
    MkTemp = case os:type() of
                 {win32, _} ->
                     os:cmd("powershell \"write-host (& New-TemporaryFile | Select-Object -ExpandProperty FullName)\"");
                 {unix,_} ->
                     os:cmd("mktemp")
             end,
    TmpFile = string:chomp(MkTemp) ++ ".erl",
    _ = file:write_file(TmpFile, unicode:characters_to_binary(Buffer, unicode)),
    FormattingCommand1 = string:replace(FormatingCommand, "${file}", TmpFile),
    _ = os:cmd(FormattingCommand1),
    {ok, Content} = file:read_file(TmpFile),
    _ = file:del_dir_r(TmpFile),
    Unicode = case unicode:characters_to_list(Content,unicode) of
                  {error, _, _} -> unicode:characters_to_list(
                                     unicode:characters_to_list(Content,latin1), unicode);
                  U -> U
              end,
    string:chomp(Unicode).

get_line_dumb(Buf, Pbs, undefined, ToEnc, Data) ->
    send_drv_reqs(Data#state.driver, [{put_chars, unicode, Pbs}]),
    get_line_dumb(Buf, Pbs, [], ToEnc, Data);
get_line_dumb(Buf, _Pbs, Cont, ToEnc, Data = #state{ driver = Drv }) ->

    EditLineRes =
        if
            Data#state.shell =:= noshell ->
                edit_line_noshell(cast(Buf, list), Cont, [], Data#state.terminal_mode);
            true -> edit_line_dumb(cast(Buf, list), Cont, [])
        end,

    case EditLineRes of
        {more, NewCont, Rs} ->
            [send_drv_reqs(Drv, Rs) || Data#state.echo],
            {more_chars, NewCont};
        eof ->
            {done, eof, eof};
        {done, Enil, Rest, Rs} ->
            [send_drv_reqs(Drv, Rs) || Data#state.echo],

            Line = lists:reverse(Enil),
            case check_encoding(Line, ToEnc) of
                false ->
                    {no_translation, unicode, ToEnc, Rest};
                true ->
                    {done, Line, Rest}
            end
    end.

get_chars_dumb(Buf, Pbs, undefined, ToEnc, Data) ->
    send_drv_reqs(Data#state.driver, [{put_chars, unicode, Pbs}]),
    get_chars_dumb(Buf, Pbs, [], ToEnc, Data);
get_chars_dumb(Buf, _Pbs, _Cont, ToEnc, Data = #state{ driver = Drv }) ->

    case cast(Buf, list) of
        [] ->
            {more_chars, []};
        eof ->
            {done, eof, eof};
        Chars ->
            [send_drv_reqs(Drv, [{put_chars, unicode, Chars}]) || Data#state.echo],

            case check_encoding(Chars, ToEnc) of
                false ->
                    {no_translation, unicode, ToEnc, []};
                true ->
                    {done, Chars, []}
            end
    end.

%% This is used by oldshell to get a basic line editor
%% We support line editing for the ICANON mode except the following
%% line editing characters, which already has another meaning in
%% echo-on mode (See Advanced Programming in the Unix Environment, 2nd ed,
%% Stevens, page 638):
%% - ^u in posix/icanon mode: erase-line, prefix-arg in edlin
%% - ^t in posix/icanon mode: status, transpose-char in edlin
%% - ^d in posix/icanon mode: eof, delete-forward in edlin
%% - ^r in posix/icanon mode: reprint (silly in echo-off mode :-))
%% - ^w in posix/icanon mode: word-erase (produces a beep in edlin)
edit_line_dumb(eof, [], _) ->
    eof;
edit_line_dumb(eof, Chars, Rs) ->
    {done, Chars, eof, lists:reverse(Rs)};
edit_line_dumb([], Chars, Rs) ->
    {more, Chars, lists:reverse(Rs)};
edit_line_dumb([$\r,$\n|Cs],Chars, Rs) ->
    {done, [$\n | Chars], Cs, lists:reverse([{put_chars, unicode, "\n"}|Rs])};
edit_line_dumb([NL|Cs],Chars, Rs) when NL =:= $\r; NL =:= $\n ->
    {done, [$\n | Chars], Cs, lists:reverse([{put_chars, unicode, "\n"}|Rs])};
edit_line_dumb([Erase|Cs],[], Rs) when Erase =:= $\177; Erase =:= $\^H ->
    edit_line_dumb(Cs,[], Rs);
edit_line_dumb([Erase|Cs],[_|Chars], Rs) when Erase =:= $\177; Erase =:= $\^H ->
    edit_line_dumb(Cs,Chars, [{delete_chars, -1}|Rs]);
edit_line_dumb([$\e, $l |Cs],Chars, Rs) ->
    %% this is a key sequence sent by to_erl to refresh the screen
    edit_line_dumb(Cs,Chars, Rs);
edit_line_dumb([CtrlChar|Cs],Chars, Rs) when CtrlChar < 32 ->
    edit_line_dumb(Cs,Chars,Rs);
edit_line_dumb([Char|Cs],Chars, Rs) ->
    edit_line_dumb(Cs,[Char|Chars], [{put_chars, unicode, [Char]}|Rs]).

%% This is used by noshell to get just get everything until the next \n
edit_line_noshell(eof, [], _, _) ->
    eof;
edit_line_noshell(eof, Chars, Rs, _) ->
    {done, Chars, eof, lists:reverse(Rs)};
edit_line_noshell([],Chars, Rs, _) ->
    {more, Chars, lists:reverse(Rs)};
edit_line_noshell([NL|Cs],Chars, Rs, raw) when NL =:= $\r ->
    {done, [$\n | Chars], Cs, lists:reverse([{put_chars, unicode, "\r\n"}|Rs])};
edit_line_noshell([NL|Cs],Chars, Rs, _) when NL =:= $\n ->
    {done, [$\n | Chars], Cs, lists:reverse([{put_chars, unicode, "\n"}|Rs])};
edit_line_noshell([Char|Cs],Chars, Rs, TerminalMode) ->
    edit_line_noshell(Cs, [Char|Chars], [{put_chars, unicode, [Char]}|Rs], TerminalMode).

%% Handling of the line history stack
new_stack(Ls) -> {stack,Ls,{},[]}.

up_stack({stack,[L|U],{},D}) ->
    {L,{stack,U,L,D}};
up_stack({stack,[],{},D}) ->
    {none,{stack,[],{},D}};
up_stack({stack,U,C,D}) ->
    up_stack({stack,U,{},[C|D]}).

down_stack({stack,U,{},[L|D]}) ->
    {L,{stack,U,L,D}};
down_stack({stack,U,{},[]}) ->
    {none,{stack,U,{},[]}};
down_stack({stack,U,C,D}) ->
    down_stack({stack,[C|U],{},D}).

%% erXos: the line of a damaged read is not kept, so moving through the history drops
%% it: emptying a recalled line ends the damage (edlin:damage_after/4), and moving back
%% must not then bring the damaged line back undamaged. Text a damaged read stores
%% keeps its damage or is not stored; the kill buffer keeps it (edlin:do_op/4), and the
%% history stack, whose lines a search reads as text, does not store it.
keep_line(Stack, _Line, {true, _Kill}) ->
    Stack;
keep_line(Stack, Line, {false, _Kill}) ->
    save_line(Stack, Line).

save_line({stack, U, {}, []}, Line) ->
    {stack, U, {}, [Line]};
save_line({stack, U, _L, D}, Line) ->
    {stack, U, Line, D}.

get_lines(Ls) -> get_all_lines(Ls).

%% There's a funny behaviour whenever the line stack doesn't have a "\n"
%% at its end -- get_lines() seemed to work on the assumption it *will* be
%% there, but the manipulations done with search history do not require it.
%%
%% It is an assumption because the function was built with either the full
%% stack being on the 'Up' side (we're on the new line) where it isn't
%% stripped. The only other case when it isn't on the 'Up' side is when
%% someone has used the up/down arrows (or ^P and ^N) to navigate lines,
%% in which case, a line with only a \n is stored at the end of the stack
%% (the \n is returned by edlin:current_line/1).
%%
%% get_all_lines works the same as get_lines, but only strips the trailing
%% character if it's a linebreak. Otherwise it's kept the same. This is
%% because traversing the stack due to search history will *not* insert
%% said empty line in the stack at the same time as other commands do,
%% and thus it should not always be stripped unless we know a new line
%% is the last entry.
get_all_lines({stack, U, {}, []}) ->
    U;
get_all_lines({stack, U, {}, D}) ->
    case lists:reverse(D, U) of
        ["\n"|Lines] -> Lines;
        Lines -> Lines
    end;
get_all_lines({stack, U, L, D}) ->
    get_all_lines({stack, U, {}, [L|D]}).

%% For the same reason as above, though, we need to expand the stack
%% in some cases to make sure we play nice with up/down arrows. We need
%% to insert newlines, but not always.
pad_stack({stack, U, L, D}) ->
    {stack, U, L, D++["\n"]}.

save_line_buffer("\n", Lines) ->
    Lines;
save_line_buffer(Line, [Line|_Lines]=Lines) ->
    Lines;
save_line_buffer(Line, Lines) ->
    try
        group_history:add(Line)
    catch E:R:ST ->
            ?LOG_ERROR(#{ msg => "Failed to write to shell history",
                          error => {E, R, ST} })
    end,
    [Line|Lines].

search_up_stack(Stack, Substr) ->
    case up_stack(Stack) of
        {none,NewStack} -> {none,NewStack};
        {L, NewStack} ->
            case string:find(L, Substr) of
                nomatch -> search_up_stack(NewStack, Substr);
                _ -> {string:trim(L, trailing, "$\n"), NewStack}
            end
    end.

search_down_stack(Stack, Substr) ->
    case down_stack(Stack) of
        {none,NewStack} -> {none,NewStack};
        {L, NewStack} ->
            case string:find(L, Substr) of
                nomatch -> search_down_stack(NewStack, Substr);
                _ -> {string:trim(L, trailing, "$\n"), NewStack}
            end
    end.

%% prompt_bytes(Prompt, Encoding)
%%  Return a flat list of characters for the Prompt.
prompt_bytes(Prompt, Encoding) ->
    lists:flatten(io_lib:format_prompt(Prompt, Encoding)).

cast(Buf, Type) ->
    cast(Buf, Type, utf8).
cast(eof, _, _) ->
    eof;
cast(lost, _, _) ->
    lost;
cast(L, binary, ToEnc) ->
    unicode:characters_to_binary(L, utf8, ToEnc);
cast(L, list, _ToEnc) when is_list(L) ->
    L;
cast(L, list, _ToEnc) ->
    unicode:characters_to_list(L, utf8).

append(eof, [], _) ->
    eof;
append(eof, L, _) ->
    L;
append(L, [], _) when is_list(L) ->
    %% When doing ++ all of L needs to be traversed to check if it is
    %% a proper list. Since we know it is a proper list we just return
    %% the list without checking.
    L;
append(L, A, _) when is_list(L) ->
    L ++ A; %% We know L is valid unicode, so we just append the two
append(B, L, FromEnc) ->
    append(unicode:characters_to_list(B, FromEnc), L, FromEnc).

check_encoding(ListOrBinary, unicode) when is_list(ListOrBinary); is_binary(ListOrBinary) ->
    true;
check_encoding(List, latin1) when is_list(List) ->
    is_latin1(List).

is_latin1([H|T]) when 0 =< H, H =< 255 ->
    is_latin1(T);
is_latin1([]) ->
    true;
is_latin1(_) ->
    false.

server_name() ->
    case erlang:process_info(self(), registered_name) of
        [] ->
            case proc_lib:get_label(self()) of
                undefined -> [];
                Name -> Name
            end;
        {registered_name, Name} ->
            Name
    end.

log_io_request(Request, LogLevel, Name) ->
    lists:member(LogLevel, [type(Request), all]) andalso
                ?LOG_INFO(#{ request => Request, server => self(), server_name => Name},
                          #{ report_cb => fun group:format_io_request_log/1,
                             domain => [otp, kernel, io, type(Request)]}).

type({io_request, _From, _ReplyAs, Req}) ->
    type(Req);
type(getopts) ->
    ctrl;
type(Req) when tuple_size(Req) > 1 ->
    ReqType = element(1, Req),
    case {lists:member(ReqType, [put_chars, requests]),
            lists:member(ReqType, [get_chars, get_line, get_until, get_password])} of
        {true, false} ->
            output;
        {false, true} ->
            input;
        {false, false} ->
            ctrl
    end;
type(_InvalidReq) ->
    ctrl.

format_io_request_log(#{ request := {io_request, From, ReplyAs, Request},
                         server := Server,
                         server_name := Name }) ->
    format_io_request_log(normalize_request(Request), From, ReplyAs, Server, Name).

format_io_request_log({put_chars, unicode, Data}, From, _ReplyAs, _Server, Name) ->
    {"~p wrote to ~p~n~ts", [From, Name, Data]};
format_io_request_log({put_chars, latin1, Data}, From, _ReplyAs, _Server, Name) ->
    {"~p wrote to ~p~n~s", [From, Name, Data]};
format_io_request_log(Request, From, ReplyAs, Server, Name) ->
    {"Request: ~p\n"
     "  From: ~p\n"
     "  ReplyAs: ~p\n"
     "Server: ~p\n"
     "Name: ~p\n",
     [Request, From, ReplyAs, Server, Name]}.

normalize_request({put_chars, Chars}) ->
    normalize_request({put_chars, latin1, Chars});
normalize_request({put_chars, Mod, Func, Args}) ->
    normalize_request({put_chars, latin1, Mod, Func, Args});
normalize_request({put_chars, Enc, Mod, Func, Args} = Req) ->
    case catch apply(Mod, Func, Args) of
        Data when is_list(Data); is_binary(Data) ->
            {put_chars, Enc, unicode:characters_to_list(Data, Enc)};
        _ -> Req
    end;
normalize_request({requests, Reqs}) ->
    case lists:foldr(
           fun(Req, []) ->
                   [normalize_request(Req)];
              (Req, [{put_chars, Enc, Data} | Acc] = NormReqs) ->
                   case normalize_request(Req) of
                       {put_chars, Enc, NewData} ->
                           [{put_chars, Enc, unicode:characters_to_list([NewData, Data], Enc)} | Acc];
                       NormReq ->
                           [NormReq | NormReqs]
                   end;
              (Req, Acc) ->
                   [normalize_request(Req) | Acc]
           end, [], Reqs) of
        [Req] -> Req;
        NormReqs -> {requests, NormReqs}
    end;
normalize_request(Req) -> Req.
