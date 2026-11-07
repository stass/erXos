%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The system domain's console service (docs/design-runtime.md, "The console and
%% standard I/O"; docs/design-live.md, "The console"): a program with its own line
%% editor on a raw terminal, as on Unix. It sits between its groups and the console's
%% driver, as user_drv does: the current group, which gets the input and is shown, and
%% the `user` group, which the shell's own group can ask for options and which is always
%% shown. Input bytes go to the current group as `{self(), {data, Chars}}`, and each
%% request of a shown group goes through prim_tty's terminal-less state to become bytes
%% for the driver. It runs no line discipline and reads no program's bytes.
%%
%% A shell typed at the shell takes the input on a group of its own (run_shell/1), as
%% user_drv's `s` and `c` start a shell and connect to it, and gives it back to the group
%% below when it ends; the groups below are not shown, so their output is acknowledged
%% and dropped, and only write/1's callers still reach the line. A command's output, which is bytes,
%% goes to the line through write/1, past prim_tty, with only a cooked tty's newline
%% processing.
%%
%% The driver is the module `-erx console_driver Module` names. It implements
%% `Module:start_link(Console) -> {ok, pid(), Terminal}`, where Terminal says whether a
%% person's terminal is on the line, and exchanges these messages:
%%
%%   to the driver:   {erx_console_output, From, Bytes}, written whole and in order
%%   from the driver: {erx_console_written, From}, once those bytes are written
%%                    {erx_console_input, Bytes}, the bytes as they were read
%%                    {erx_console_size, Columns, Rows}, when the line's size changes
%%                    erx_console_eof, after every byte read before the end
%%
%% The console is also the kernel log's one reader (docs/design-live.md, "The console";
%% docs/design-stopgap.md, "The console"). Every LOG_POLL_MS it takes the records nobody has
%% taken, each as the line the log core rendered with every byte of its text escaped, and
%% sends each to the driver whole, ending in CR-LF, between whatever else is written. A log
%% line can therefore land inside a program's line or an edited prompt, as a kernel message
%% does on a Unix serial console. Until the root hands the log to this reader, the root
%% writes each record to the line itself and a read finds nothing.

-module(erx_console).
-behaviour(gen_server).

-export([start/0, run_shell/1, write/1]).
-export([input/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([input_event/0]).

-type input_event() :: {data, unicode:unicode_binary()} | interrupt | menu.

-define(DEFAULT_SIZE, {80, 24}).
-define(MAX_SIDE, 65535).
-define(LOG_POLL_MS, 100).

-record(state, {driver :: pid(),
                %% The group the console started with, which the others return the input to.
                base :: pid(),
                user :: pid(),
                tty :: prim_tty:state(),
                size :: {pos_integer(), pos_integer()},
                terminal :: boolean(),
                %% The groups run_shell/1 started, innermost first, each with its caller
                %% to answer when it ends. The innermost gets the input, or `base` when
                %% there are none (current/1).
                shells = [] :: [{pid(), gen_server:from()}],
                %% Whether the input has ended: each group that gets the input from then
                %% on is told so.
                input_ended = false :: boolean(),
                %% Where the next read of the kernel log starts.
                log_cursor = 0 :: non_neg_integer(),
                %% The start of a character whose other bytes have not been read yet.
                pending = <<>> :: binary()}).

%% user_sup calls this, and waits for the `user` group to register.
-spec start() -> {ok, pid()} | {error, term()}.
start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

-doc """
Runs Shell, a shell's start function as group:start/3 takes it, on a group of its
own that gets the console's input until the shell ends, and returns then: `ok` if
the shell ended normally, `{error, Reason}` with its exit reason if not. The group
that had the input gets it back; shells started this way may end in any order.
Ctrl-C interrupts the new group's shell. This is how a shell typed at the Erlang
shell, such as the command shell (erx_shell:start/0), takes the console.
""".
-spec run_shell({module(), atom(), [term()]}) -> ok | {error, term()}.
run_shell(Shell = {Module, Function, Args})
  when is_atom(Module), is_atom(Function), is_list(Args) ->
    gen_server:call(?MODULE, {run_shell, Shell}, infinity).

-doc """
Writes Bytes to the console's line as they are, but for each newline, which goes out
as CR-LF as a cooked tty's ONLCR sends it, and returns once they are written: the
output of a command, which is bytes, never text the console renders.
""".
-spec write(iodata()) -> ok.
write(Bytes) ->
    gen_server:call(?MODULE, {write, iolist_to_binary(Bytes)}, infinity).

-spec init([]) -> {ok, #state{}}.
init([]) ->
    process_flag(trap_exit, true),
    {ok, DriverPid, Terminal} = (driver_module()):start_link(self()),
    %% As user_drv does for a line with no terminal on it: no editing, no echo and bytes
    %% as they are, and the shell's stock end-of-input branch ends the runtime.
    TTY = banner(prim_tty:init_ssh(tty_options(Terminal), ?DEFAULT_SIZE, utf8), DriverPid),
    User = group:start(self(), noshell, [{name, user}]),
    Group = case wants_shell() of
                true -> group:start(self(), {shell, start, [init]}, group_options(Terminal));
                false -> User
            end,
    %% Where group:whereis_shell/0 looks, as it looks in user_drv.
    put(current_group, Group),
    erlang:send_after(?LOG_POLL_MS, self(), erx_log_poll),
    {ok, #state{driver = DriverPid,
                base = Group,
                user = User,
                tty = TTY,
                size = ?DEFAULT_SIZE,
                terminal = Terminal}}.

%% What user_drv writes before it starts a shell, ahead of anything the groups write.
banner(TTY, Driver) ->
    case wants_shell() of
        true ->
            Line = unicode:characters_to_binary([slogan(), $\n]),
            {Bytes, NewTTY} = prim_tty:handle_request(TTY, {putc, Line}),
            Driver ! {erx_console_output, none, Bytes},
            NewTTY;
        false ->
            TTY
    end.

slogan() ->
    Default = fun() -> erlang:system_info(system_version) end,
    case application:get_env(stdlib, shell_slogan, Default) of
        Fun when is_function(Fun, 0) -> Fun();
        Slogan -> Slogan
    end.

wants_shell() ->
    init:get_argument(noshell) =:= error andalso init:get_argument(noinput) =:= error.

%% As user_drv does for a line with no terminal on it: no editing, no echo and bytes as
%% they are, and the shell's stock end-of-input branch ends the runtime.
group_options(Terminal) ->
    [{dumb, not Terminal},
     {expand_below, application:get_env(stdlib, shell_expand_location, below) =:= below}].

tty_options(true) -> #{};
tty_options(false) -> #{input => cooked, output => raw}.

-spec handle_call(term(), gen_server:from(), #state{}) ->
          {reply, term(), #state{}} | {noreply, #state{}}.
handle_call({run_shell, Shell}, From, State = #state{shells = Shells, terminal = Terminal}) ->
    %% No completion: the Erlang shell's would complete Erlang.
    Options = [{expand_fun, fun(_Before, _Options) -> {no, [], []} end}
               | group_options(Terminal)],
    New = group:start(self(), Shell, Options),
    {noreply, gets_input(State#state{shells = [{New, From} | Shells]})};
handle_call({write, Bytes}, From, State = #state{driver = Driver}) ->
    Driver ! {erx_console_output, {caller, From}, onlcr(Bytes)},
    {noreply, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}} | {stop, term(), #state{}}.
handle_info({erx_console_input, Bytes}, State = #state{pending = Pending}) ->
    {Events, Left} = input(Pending, Bytes),
    lists:foreach(fun(Event) -> deliver(Event, State) end, Events),
    {noreply, State#state{pending = Left}};
handle_info(erx_console_eof, State = #state{pending = Pending}) ->
    %% What began a character will never end it, so it reads as stock reads a bad byte.
    [deliver({data, latin1(Pending)}, State) || Pending =/= <<>>],
    {noreply, gets_input(State#state{pending = <<>>, input_ended = true})};
handle_info({erx_console_size, Columns, Rows}, State = #state{tty = TTY})
  when is_integer(Columns), is_integer(Rows),
       Columns >= 1, Columns =< ?MAX_SIDE, Rows >= 1, Rows =< ?MAX_SIDE ->
    {noreply, State#state{tty = prim_tty:update_geometry(TTY, Columns, Rows),
                          size = {Columns, Rows}}};
handle_info({erx_console_size, _Columns, _Rows}, State) ->
    {noreply, State};
handle_info(erx_log_poll, State = #state{driver = Driver, log_cursor = Cursor}) ->
    case erx_log:read(Cursor) of
        {Whole, Next, Lost, Lines} ->
            Notes = [<<"erx_console: ", (integer_to_binary(Lost))/binary, " kernel log records lost\n">>
                     || Lost > 0],
            Broken = [<<"erx_console: a kernel log record failed its checks\n">> || Whole =:= corrupt],
            lists:foreach(fun(Line) -> Driver ! {erx_console_output, none, log_line(Line)} end,
                          Notes ++ Lines ++ Broken),
            erlang:send_after(?LOG_POLL_MS, self(), erx_log_poll),
            {noreply, State#state{log_cursor = Next}};
        {error, Status} ->
            Line = <<"erx_console: the kernel log refused a read: ", (integer_to_binary(Status))/binary, "\n">>,
            Driver ! {erx_console_output, none, log_line(Line)},
            erlang:send_after(?LOG_POLL_MS, self(), erx_log_poll),
            {noreply, State}
    end;
handle_info({erx_console_written, none}, State) ->
    {noreply, State};
handle_info({erx_console_written, {caller, From}}, State) ->
    gen_server:reply(From, ok),
    {noreply, State};
handle_info({erx_console_written, {Group, Reply}}, State) ->
    Group ! {reply, Reply, ok},
    {noreply, State};
handle_info({'EXIT', User, Reason}, State = #state{user = User}) ->
    %% user_sup kills `user` when the system stops: the runtime is on its way out.
    {stop, Reason, State};
handle_info({'EXIT', Pid, Reason}, State = #state{driver = Driver, base = Base, shells = Shells}) ->
    case lists:keytake(Pid, 1, Shells) of
        {value, {Pid, Caller}, Others} ->
            %% A shell run_shell/1 started has ended, and its group with it, in whatever
            %% order: its caller gets how it ended, which the group's first exit carries
            %% from its shell, and the input goes to the innermost group left. The group's
            %% own exit, which follows, names a group the console no longer holds.
            gen_server:reply(Caller, shell_ended(Reason)),
            {noreply, gets_input(State#state{shells = Others})};
        false when Pid =:= Driver; Pid =:= Base ->
            %% Nothing would read the terminal again, and its keys no longer signal: end
            %% the runtime, whose exit restores the terminal, where stock starts another
            %% shell.
            erlang:display_string(stderr, lists:flatten(io_lib:format("erx_console: ended by ~p\r\n", [Reason]))),
            erlang:halt(1),
            {stop, Reason, State};
        false ->
            {noreply, State}
    end;
handle_info(Message, State = #state{user = User})
  when is_tuple(Message), tuple_size(Message) >= 2, is_pid(element(1, Message)) ->
    Pid = element(1, Message),
    Current = current(State),
    case is_group(Pid, State) of
        true when Pid =:= User; Pid =:= Current ->
            {noreply, from_group(Message, State)};
        true ->
            {noreply, from_hidden_group(Message, State)};
        false ->
            {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

%% Whether Pid is one of the console's groups: `user`, the one it started with, or one
%% run_shell/1 started.
is_group(Pid, #state{user = User, base = Base, shells = Shells}) ->
    Pid =:= User orelse Pid =:= Base orelse lists:keymember(Pid, 1, Shells).

%% The group that gets the input: the innermost shell run_shell/1 started, or the one
%% the console started with.
current(#state{shells = [{Group, _Caller} | _]}) -> Group;
current(#state{base = Base}) -> Base.

%% State once its current group has the input: group:whereis_shell/0 finds that group,
%% and it reads the input's end if the input has ended. Telling a group twice is
%% harmless, as a second end of input is to a terminal.
gets_input(State = #state{input_ended = Ended}) ->
    Group = current(State),
    put(current_group, Group),
    [Group ! {self(), eof} || Ended],
    State.

%% How a shell run_shell/1 started ended, as its caller is told.
shell_ended(normal) -> ok;
shell_ended(Reason) -> {error, Reason}.

%% A group below the one that has the input is not shown, as user_drv shows only its
%% current group: its output is acknowledged and dropped, so neither its writers nor
%% its shell's hints wait or reach the line, and its questions are answered.
from_hidden_group({Pid, {Sync, _Encoding, _Output, Reply}}, State)
  when Sync =:= put_chars_sync; Sync =:= put_ansi_sync ->
    Pid ! {reply, Reply, ok},
    State;
from_hidden_group(Message = {_Pid, Query}, State)
  when Query =:= tty_geometry; Query =:= get_unicode_state; Query =:= get_terminal_state;
       element(1, Query) =:= open_editor ->
    from_group(Message, State);
from_hidden_group(Message = {_Pid, Query, _Value}, State)
  when Query =:= set_unicode_state; Query =:= read ->
    from_group(Message, State);
from_hidden_group(_Output, State) ->
    State.

from_group({Pid, set_unicode_state, Unicode}, State = #state{tty = TTY}) ->
    ok = io:setopts(standard_error, [{encoding, encoding(Unicode)}]),
    Pid ! {self(), set_unicode_state, prim_tty:unicode(TTY)},
    State#state{tty = prim_tty:unicode(TTY, Unicode)};
from_group({Pid, read, _Count}, State) ->
    Pid ! {self(), {error, enotsup}},
    State;
from_group({Pid, Request}, State) ->
    group_request(Request, Pid, State);
from_group(_Message, State) ->
    State.

%% The driver's module, from the argument the boot information page carries. The last naming
%% wins, since the hosted entry adds its driver after the manifest's arguments, and a plain
%% word of the command line may have joined it.
driver_module() ->
    {ok, Arguments} = init:get_argument(erx),
    list_to_atom(lists:last([Word || ["console_driver", Word | _] <- Arguments])).

encoding(true) -> unicode;
encoding(false) -> latin1.

%% -- Input ----------------------------------------------------------------------------

%% A pure decision: what the bytes read so far mean, and what must wait for more.
%% Ctrl-C and Ctrl-G are single bytes that no UTF-8 sequence contains. Text reaches the
%% group as UTF-8, and a byte that is not part of a character reads as latin-1, as
%% prim_tty's reader does for stock's terminal.
-spec input(Pending :: binary(), Bytes :: binary()) -> {[input_event()], Left :: binary()}.
input(Pending, Bytes) ->
    events(<<Pending/binary, Bytes/binary>>).

events(Bin) ->
    case binary:match(Bin, [<<$\^C>>, <<$\^G>>]) of
        nomatch ->
            text(Bin);
        {At, 1} ->
            <<Before:At/binary, Control, After/binary>> = Bin,
            {Text, Unfinished} = text(Before),
            {Later, Left} = events(After),
            {Text ++ data(latin1(Unfinished)) ++ [control(Control) | Later], Left}
    end.

text(Bin) ->
    case unicode:characters_to_binary(Bin, utf8) of
        Utf8 when is_binary(Utf8) ->
            {data(Utf8), <<>>};
        {incomplete, Utf8, Left} ->
            {data(Utf8), Left};
        {error, Utf8, <<Bad, Rest/binary>>} ->
            {Later, Left} = text(Rest),
            {data(Utf8) ++ data(latin1(<<Bad>>)) ++ Later, Left}
    end.

data(<<>>) -> [];
data(Utf8) -> [{data, Utf8}].

latin1(Bin) -> unicode:characters_to_binary(Bin, latin1).

control($\^C) -> interrupt;
control($\^G) -> menu.

deliver({data, Utf8}, State) ->
    current(State) ! {self(), {data, Utf8}};
deliver(interrupt, State) ->
    %% As ssh_cli does: the group turns this into an interrupt of the shell's evaluator.
    exit(current(State), interrupt);
deliver(menu, #state{driver = Driver, tty = TTY}) ->
    %% Ctrl-G belongs to the console's menu and no session reads it. With no sessions to
    %% list, the menu is a bell.
    {Bytes, _} = prim_tty:handle_request(TTY, beep),
    Driver ! {erx_console_output, none, Bytes}.

%% -- Output ---------------------------------------------------------------------------

%% A command's bytes as a cooked tty's OPOST and ONLCR send them: each newline as CR-LF,
%% every other byte unchanged.
-spec onlcr(binary()) -> binary().
onlcr(Bytes) ->
    binary:replace(Bytes, <<"\n">>, <<"\r\n">>, [global]).

%% A rendered log line ends in its one newline; a terminal's line ends in CR-LF.
log_line(<<>>) ->
    <<>>;
log_line(Line) ->
    [binary:part(Line, 0, byte_size(Line) - 1), <<"\r\n">>].

group_request(tty_geometry, Pid, State = #state{size = Size}) ->
    Pid ! {self(), tty_geometry, Size},
    State;
group_request(get_unicode_state, Pid, State = #state{tty = TTY}) ->
    Pid ! {self(), get_unicode_state, prim_tty:unicode(TTY)},
    State;
group_request(get_terminal_state, Pid, State = #state{terminal = Terminal}) ->
    Pid ! {self(), get_terminal_state, #{stdin => Terminal, stdout => Terminal, stderr => Terminal}},
    State;
group_request({open_editor, Buffer}, Pid, State) ->
    %% No external editor can run: the buffer comes back unchanged.
    Pid ! {self(), {editor_data, Buffer}},
    State;
group_request({requests, Requests}, _Pid, State = #state{tty = TTY}) ->
    {Bytes, NewTTY} = render_all(Requests, TTY, []),
    write(none, Bytes, State#state{tty = NewTTY});
group_request({put_chars_sync, Encoding, Chars, Reply}, Pid, State = #state{tty = TTY}) ->
    case encode(Encoding, Chars) of
        {ok, Text} ->
            {Bytes, NewTTY} = prim_tty:handle_request(TTY, {putc, Text}),
            write({Pid, Reply}, Bytes, State#state{tty = NewTTY});
        error ->
            Pid ! {reply, Reply, {error, {put_chars, Encoding, Chars}}},
            State
    end;
group_request({put_ansi_sync, Options, Ansi, Reply}, Pid, State) ->
    try io_ansi:format([Ansi], [], [{reset, false} | Options]) of
        Rendered ->
            group_request({put_chars_sync, unicode, Rendered, Reply}, Pid, State)
    catch _:_ ->
            Pid ! {reply, Reply, {error, {put_ansi, unicode, Ansi}}},
            State
    end;
group_request(Request, _Pid, State = #state{tty = TTY}) ->
    {Bytes, NewTTY} = prim_tty:handle_request(TTY, tty_request(Request)),
    write(none, Bytes, State#state{tty = NewTTY}).

write(From, Bytes, State = #state{driver = Driver}) ->
    Driver ! {erx_console_output, From, Bytes},
    State.

encode(Encoding, Chars) ->
    case unicode:characters_to_binary(Chars, Encoding) of
        Text when is_binary(Text) -> {ok, Text};
        _Failure -> error
    end.

%% The same merges as user_drv: prim_tty moves across lines only as one combined request.
render_all([{insert_chars, unicode, C1}, {insert_chars, unicode, C2} | Rs], TTY, Acc) ->
    render_all([{insert_chars, unicode, [C1, C2]} | Rs], TTY, Acc);
render_all([{put_chars, unicode, C1}, {put_chars, unicode, C2} | Rs], TTY, Acc) ->
    render_all([{put_chars, unicode, [C1, C2]} | Rs], TTY, Acc);
render_all([{move_rel, N}, {move_line, R}, {move_rel, M} | Rs], TTY, Acc) ->
    render_all([{move_combo, N, R, M} | Rs], TTY, Acc);
render_all([{move_rel, N}, {move_line, R} | Rs], TTY, Acc) ->
    render_all([{move_combo, N, R, 0} | Rs], TTY, Acc);
render_all([{move_line, R}, {move_rel, M} | Rs], TTY, Acc) ->
    render_all([{move_combo, 0, R, M} | Rs], TTY, Acc);
render_all([Request | Rs], TTY, Acc) ->
    {Bytes, NewTTY} = prim_tty:handle_request(TTY, tty_request(Request)),
    render_all(Rs, NewTTY, [Bytes | Acc]);
render_all([], TTY, Acc) ->
    {lists:reverse(Acc), TTY}.

%% A group's request in prim_tty's terms.
tty_request({put_chars, unicode, Chars}) -> {putc, unicode:characters_to_binary(Chars)};
tty_request({put_expand, unicode, Chars, N}) -> {expand, unicode:characters_to_binary(Chars), N};
tty_request({move_expand, N}) -> {move_expand, N};
tty_request({move_rel, N}) -> {move, N};
tty_request({insert_chars, unicode, Chars}) -> {insert, unicode:characters_to_binary(Chars)};
tty_request({insert_chars_over, unicode, Chars}) -> {insert_over, unicode:characters_to_binary(Chars)};
tty_request({delete_chars, N}) -> {delete, N};
tty_request(Request) -> Request.
