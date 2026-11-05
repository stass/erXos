%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The system domain's console service (docs/design-runtime.md, "The console and
%% standard I/O"; docs/design-live.md, "The console"): a program with its own line
%% editor on a raw terminal, as on Unix. It sits between two groups and the console's
%% driver, as user_drv does: the shell's group, which gets the input, and the `user`
%% group, which the shell's own group can ask for options. Input bytes go to the shell's
%% group as `{self(), {data, Chars}}`, and each request of either group goes through
%% prim_tty's terminal-less state to become bytes for the driver. It runs no line
%% discipline and reads no program's bytes.
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

-module(erx_console).
-behaviour(gen_server).

-export([start/0]).
-export([input/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([input_event/0]).

-type input_event() :: {data, unicode:unicode_binary()} | interrupt | menu.

-define(DEFAULT_SIZE, {80, 24}).
-define(MAX_SIDE, 65535).

-record(state, {driver :: pid(),
                group :: pid(),
                user :: pid(),
                tty :: prim_tty:state(),
                size :: {pos_integer(), pos_integer()},
                terminal :: boolean(),
                %% The start of a character whose other bytes have not been read yet.
                pending = <<>> :: binary()}).

%% user_sup calls this, and waits for the `user` group to register.
-spec start() -> {ok, pid()} | {error, term()}.
start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

-spec init([]) -> {ok, #state{}}.
init([]) ->
    process_flag(trap_exit, true),
    {ok, DriverPid, Terminal} = (driver_module()):start_link(self()),
    %% As user_drv does for a line with no terminal on it: no editing, no echo and bytes
    %% as they are, and the shell's stock end-of-input branch ends the runtime.
    GroupOptions = [{dumb, not Terminal},
                    {expand_below,
                     application:get_env(stdlib, shell_expand_location, below) =:= below}],
    TTY = banner(prim_tty:init_ssh(tty_options(Terminal), ?DEFAULT_SIZE, utf8), DriverPid),
    User = group:start(self(), noshell, [{name, user}]),
    Group = case wants_shell() of
                true -> group:start(self(), {shell, start, [init]}, GroupOptions);
                false -> User
            end,
    %% Where group:whereis_shell/0 looks, as it looks in user_drv.
    put(current_group, Group),
    {ok, #state{driver = DriverPid,
                group = Group,
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

tty_options(true) -> #{};
tty_options(false) -> #{input => cooked, output => raw}.

-spec handle_call(term(), gen_server:from(), #state{}) -> {reply, {error, unknown_call}, #state{}}.
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
handle_info(erx_console_eof, State = #state{group = Group, pending = Pending}) ->
    %% What began a character will never end it, so it reads as stock reads a bad byte.
    [deliver({data, latin1(Pending)}, State) || Pending =/= <<>>],
    Group ! {self(), eof},
    {noreply, State#state{pending = <<>>}};
handle_info({erx_console_size, Columns, Rows}, State = #state{tty = TTY})
  when is_integer(Columns), is_integer(Rows),
       Columns >= 1, Columns =< ?MAX_SIDE, Rows >= 1, Rows =< ?MAX_SIDE ->
    {noreply, State#state{tty = prim_tty:update_geometry(TTY, Columns, Rows),
                          size = {Columns, Rows}}};
handle_info({erx_console_size, _Columns, _Rows}, State) ->
    {noreply, State};
handle_info({erx_console_written, none}, State) ->
    {noreply, State};
handle_info({erx_console_written, {Group, Reply}}, State) ->
    Group ! {reply, Reply, ok},
    {noreply, State};
handle_info({Pid, Request}, State = #state{group = Group, user = User})
  when Pid =:= Group; Pid =:= User ->
    {noreply, group_request(Request, Pid, State)};
handle_info({Pid, set_unicode_state, Unicode}, State = #state{group = Group, user = User, tty = TTY})
  when Pid =:= Group; Pid =:= User ->
    ok = io:setopts(standard_error, [{encoding, encoding(Unicode)}]),
    Pid ! {self(), set_unicode_state, prim_tty:unicode(TTY)},
    {noreply, State#state{tty = prim_tty:unicode(TTY, Unicode)}};
handle_info({Pid, read, _Count}, State = #state{group = Group, user = User})
  when Pid =:= Group; Pid =:= User ->
    Pid ! {self(), {error, enotsup}},
    {noreply, State};
handle_info({'EXIT', User, Reason}, State = #state{user = User}) ->
    %% user_sup kills `user` when the system stops: the runtime is on its way out.
    {stop, Reason, State};
handle_info({'EXIT', Pid, Reason}, State = #state{driver = Driver, group = Group})
  when Pid =:= Driver; Pid =:= Group ->
    %% Nothing would read the terminal again, and its keys no longer signal: end the
    %% runtime, whose exit restores the terminal, where stock starts another shell.
    erlang:display_string(stderr, lists:flatten(io_lib:format("erx_console: ended by ~p\r\n", [Reason]))),
    erlang:halt(1),
    {stop, Reason, State};
handle_info(_Message, State) ->
    {noreply, State}.

%% The driver's module, from the argument the boot information page carries.
driver_module() ->
    {ok, Arguments} = init:get_argument(erx),
    [Module] = [Word || ["console_driver", Word] <- Arguments],
    list_to_atom(Module).

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

deliver({data, Utf8}, #state{group = Group}) ->
    Group ! {self(), {data, Utf8}};
deliver(interrupt, #state{group = Group}) ->
    %% As ssh_cli does: the group turns this into an interrupt of the shell's evaluator.
    exit(Group, interrupt);
deliver(menu, #state{driver = Driver, tty = TTY}) ->
    %% Ctrl-G belongs to the console's menu and no session reads it. With no sessions to
    %% list, the menu is a bell.
    {Bytes, _} = prim_tty:handle_request(TTY, beep),
    Driver ! {erx_console_output, none, Bytes}.

%% -- Output ---------------------------------------------------------------------------

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
