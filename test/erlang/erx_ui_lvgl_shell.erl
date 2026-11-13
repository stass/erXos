%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_lvgl_shell).
-moduledoc """
The LVGL renderer's shell, erx_ui_lvgl, driving the real erx-lvgl on the
host (docs/design-display.md, "The widget server"). The program runs
through test/fixtures/erx_lvgl_buffer.rb with the file `buffer` in the
current directory as descriptor 3, and the window is played by this
process: the shell's presents come here, and are answered with shown/1
when the case says.

run/1 returns what test/host/erx_ui_lvgl_test.rb checks:

* `first`: the first present's size, after apply/2 returned.
* `held`: the hits that came while that present was unanswered and a
  click was sent, none, since the shell takes the window's input only
  while no report is open; `hit`, the click's hit once it is answered.
* `grown`: a resize past the buffer, which the program refuses: the UI
  ends as `renderer_down`: the shell ends abnormally with the program's
  exit, which the widget server, played by this process, is linked to.
* `closed`: stop/1 after the first frame: the shell ends normally and the
  widget server hears nothing.
""".

-export([run/1]).

-define(WIDTH, 240).
-define(HEIGHT, 160).
-define(X8R8G8B8, 16#68081828).
-define(BUTTON, 3).
-define(BUTTON_Y, 5 + 30 + 40 div 2).
-define(WAIT_MS, 60000).
-define(HOLD_MS, 300).

-spec run(#{program := file:filename(), ruby := file:filename(), launcher := file:filename()}) -> map().
run(Paths) ->
    process_flag(trap_exit, true),
    Buffer = filename:absname("buffer"),
    ok = file:write_file(Buffer, binary:copy(<<0>>, 4 * ?WIDTH * ?HEIGHT)),
    Shell = start(Paths, Buffer),
    {ok, Shell} = erx_ui_lvgl:apply(tree(), Shell),
    {present, Shell, W, H, _Rects} = next_present(),
    click(Shell),
    Held = hits(?HOLD_MS),
    erx_ui_lvgl:shown(Shell),
    Hit = answer_until_hit(Shell),
    erx_ui_lvgl:resize(Shell, 2 * ?WIDTH, 2 * ?HEIGHT),
    Grown = until_down(Shell),
    Shell2 = start(Paths, Buffer),
    {ok, Shell2} = erx_ui_lvgl:apply(tree(), Shell2),
    {present, Shell2, _, _, _} = next_present(),
    erx_ui_lvgl:shown(Shell2),
    ok = erx_ui_lvgl:stop(Shell2),
    Closed = receive {'EXIT', Shell2, Why} -> Why after ?WAIT_MS -> error(close_hung) end,
    Heard = hits(?HOLD_MS),
    #{first => {W, H}, held => Held, hit => Hit, grown => Grown, closed => {Closed, Heard},
      killed => killed(Paths, Buffer)}.

%% Input queued ahead of the program's end: the shell is suspended, sent a
%% click, and the program killed, so the shell writes to a port that has
%% already closed. The UI still ends as renderer_down, by the exit status.
killed(Paths, Buffer) ->
    Shell = start(Paths, Buffer),
    {ok, Shell} = erx_ui_lvgl:apply(tree(), Shell),
    {present, Shell, _, _, _} = next_present(),
    erx_ui_lvgl:shown(Shell),
    {_State, #{port := Port}} = sys:get_state(Shell),
    {os_pid, Pid} = erlang:port_info(Port, os_pid),
    ok = sys:suspend(Shell),
    click(Shell),
    _ = os:cmd("kill -9 " ++ integer_to_list(Pid)),
    timer:sleep(?HOLD_MS),
    ok = sys:resume(Shell),
    until_down(Shell).

start(#{program := Program, ruby := Ruby, launcher := Launcher}, Buffer) ->
    Test = self(),
    Open = fun() ->
                   open_port({spawn_executable, Ruby},
                             [binary, stream, use_stdio, exit_status, {args, [Launcher, Buffer, Program]}])
           end,
    Present = fun(W, H, Rects) -> Test ! {present, self(), W, H, Rects}, ok end,
    {ok, Shell} = erx_ui_lvgl:start({window, test}, Test,
                                    #{width => ?WIDTH, height => ?HEIGHT, chan => ?X8R8G8B8,
                                      open => Open, present => Present,
                                      present_text => fun(_Type, _Value) -> error(no_presentations) end}),
    Shell.

%% The tree of the model screen, test/erlang/erx_lvgl_screen.erl, in short:
%% a column of a label and a button that takes clicks.
tree() ->
    Tree = [{insert, 1, 0, 0, column, #{pad => 5}},
            {insert, 2, 1, 0, label, #{height => 30, text => <<"erXos kiosk">>}},
            {insert, ?BUTTON, 1, 1, button, #{height => 40, text => <<"Press">>, on_click => pressed}},
            commit],
    {ok, Realised} = erx_ui_model:apply_ops(Tree, erx_ui_model:empty()),
    erx_ui_model:delta(erx_ui_model:empty(), Realised).

click(Shell) ->
    erx_ui_lvgl:window(Shell, {input, {pointer, ?WIDTH div 2, ?BUTTON_Y, 1}}),
    erx_ui_lvgl:window(Shell, {input, {pointer, ?WIDTH div 2, ?BUTTON_Y, 0}}).

next_present() ->
    receive {present, _, _, _, _} = Present -> Present after ?WAIT_MS -> error(no_present) end.

hits(Ms) ->
    receive {ui_hit, _, _, _} = Hit -> [Hit | hits(Ms)] after Ms -> [] end.

%% Answers every present until the click's hit comes.
answer_until_hit(Shell) ->
    receive
        {present, Shell, _, _, _} -> erx_ui_lvgl:shown(Shell), answer_until_hit(Shell);
        {ui_hit, _, _, _} = Hit -> Hit
    after ?WAIT_MS -> error(no_hit)
    end.

%% Answers presents until the UI ends: the shell's abnormal exit, which the
%% widget server takes as renderer_down.
until_down(Shell) ->
    receive
        {present, Shell, _, _, _} -> erx_ui_lvgl:shown(Shell), until_down(Shell);
        {'EXIT', Shell, Exit} when Exit =/= normal -> {renderer_down, Exit}
    after ?WAIT_MS -> error(not_down)
    end.
