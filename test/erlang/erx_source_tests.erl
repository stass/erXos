%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_source (docs/design-live.md, "From a process to its
%% source"): the pure decisions on their own, then lines/1 against a probe
%% module compiled into a release-shaped tree, app/src and app/ebin, under
%% the working directory, and loaded from there.
-module(erx_source_tests).
-include_lib("eunit/include/eunit.hrl").

-define(PROBE, erx_source_probe).

%% The probe's source. A process waiting in wait/0's receive is at line 6
%% by ERTS's line table, which has no entry of its own for the receive.
-define(PROBE_V1,
        "-module(erx_source_probe).\n"
        "-export([wait/0, add/2]).\n"
        "add(A, B) ->\n"
        "    A + B.\n"
        "%% A line with a tab\there and an escape \e[31m.\n"
        "wait() ->\n"
        "    receive stop -> ok end.\n").
-define(PROBE_V2,
        "-module(erx_source_probe).\n"
        "-export([wait/0, add/2]).\n"
        "add(A, B) ->\n"
        "    B + A.\n"
        "\n"
        "wait() ->\n"
        "    receive stop -> ok end.\n").

%% candidates/2

candidates_test_() ->
    [?_assertEqual({ok, ["/lib/app-1/src/m.erl", "/lib/app-1/include/m.erl"]},
                   erx_source:candidates("/lib/app-1/ebin/m.beam", "m.erl")),
     %% Only the base name of the location's file counts.
     ?_assertEqual({ok, ["/r/src/m.erl", "/r/include/m.erl"]},
                   erx_source:candidates("/r/ebin/m.beam", "/build/host/src/m.erl")),
     ?_assertEqual({ok, ["/r/src/x.hrl", "/r/include/x.hrl"]},
                   erx_source:candidates("/r/ebin/m.beam", "../../x.hrl")),
     %% A module loaded from the host is named by its hash, with no directory.
     ?_assertEqual(unsupported, erx_source:candidates("0a1b.beam", "m.erl")),
     ?_assertEqual(unsupported, erx_source:candidates("r/ebin/m.beam", "m.erl")),
     ?_assertEqual(unsupported, erx_source:candidates("/r/lib/m.beam", "m.erl")),
     ?_assertEqual(unsupported, erx_source:candidates("/r/ebin/m.so", "m.erl")),
     ?_assertEqual(unsupported, erx_source:candidates(preloaded, "m.erl")),
     ?_assertEqual(unsupported, erx_source:candidates(cover_compiled, "m.erl")),
     ?_assertEqual(unsupported, erx_source:candidates("/r/ebin/m.beam", "..")),
     ?_assertEqual(unsupported, erx_source:candidates("/r/ebin/m.beam", ".")),
     ?_assertEqual(unsupported, erx_source:candidates("/r/ebin/m.beam", "")),
     ?_assertEqual(unsupported, erx_source:candidates("/r/ebin/m.beam", "m\0.erl")),
     ?_assertEqual(unsupported, erx_source:candidates("/r/ebin/m.beam", [16#110000])),
     ?_assertEqual(unsupported, erx_source:candidates("/r/ebin/m.beam", <<"m.erl">>)),
     ?_assertEqual(unsupported, erx_source:candidates("/r/ebin/m.beam", [$m | $x]))].

%% entry_location/3, over code of beam_disasm's shape

entry_location_test_() ->
    Code = [{function, f, 0, 2, [{label, 1}, {line, [{location, "m.erl", 3}]},
                                 {func_info, {atom, m}, {atom, f}, 0}, {label, 2}, return]},
            {function, f, 1, 4, [{label, 3}, {line, [{location, "m.hrl", 9}]},
                                 {func_info, {atom, m}, {atom, f}, 1}, {label, 4}, return]},
            {function, g, 0, 6, [{label, 5}, {func_info, {atom, m}, {atom, g}, 0}, {label, 6}, return]}],
    [?_assertEqual({ok, {"m.erl", 3}}, erx_source:entry_location(Code, f, 0)),
     ?_assertEqual({ok, {"m.hrl", 9}}, erx_source:entry_location(Code, f, 1)),
     %% No line for the entry, no such function, no such arity.
     ?_assertEqual({error, unsupported}, erx_source:entry_location(Code, g, 0)),
     ?_assertEqual({error, unsupported}, erx_source:entry_location(Code, h, 0)),
     ?_assertEqual({error, unsupported}, erx_source:entry_location(Code, f, 2)),
     ?_assertEqual({error, unsupported}, erx_source:entry_location([], f, 0))].

%% excerpt/2

excerpt_test_() ->
    Text = iolist_to_binary([[integer_to_list(N), "\n"] || N <- lists:seq(1, 20)]),
    Location = fun(Line) -> {m, f, 0, "m.erl", Line} end,
    Lines = fun(First, Last) -> [integer_to_binary(N) || N <- lists:seq(First, Last)] end,
    [?_assertMatch({ok, #{first := 5, lines := _}}, erx_source:excerpt(Location(10), Text)),
     ?_assertEqual(Lines(5, 15), maps:get(lines, element(2, erx_source:excerpt(Location(10), Text)))),
     ?_assertEqual(Lines(1, 6), maps:get(lines, element(2, erx_source:excerpt(Location(1), Text)))),
     ?_assertEqual(Lines(15, 20), maps:get(lines, element(2, erx_source:excerpt(Location(20), Text)))),
     ?_assertEqual({error, unsupported}, erx_source:excerpt(Location(21), Text)),
     ?_assertEqual({error, unsupported}, erx_source:excerpt(Location(1), <<>>)),
     ?_assertEqual({error, unsupported}, erx_source:excerpt(Location(-1), Text)),
     %% CR LF line ends, and a last line without one.
     ?_assertEqual([<<"a">>, <<"b">>, <<"c">>],
                   maps:get(lines, element(2, erx_source:excerpt(Location(2), <<"a\r\nb\r\nc">>)))),
     ?_assertEqual({error, unsupported}, erx_source:excerpt(Location(3), <<"a\nb\n">>))].

%% render/1

render_test_() ->
    Excerpt = fun(Location, First, Lines) -> #{location => Location, first => First, lines => Lines} end,
    [?_assertEqual(<<"m.erl:10 in m:f/0\n"
                     "   9  a\n"
                     "> 10  b\n"
                     "  11  c\n">>,
                   erx_source:render(Excerpt({m, f, 0, "m.erl", 10}, 9, [<<"a">>, <<"b">>, <<"c">>]))),
     %% Tabs expand to stops of eight columns, a multibyte character
     %% counting as one; controls and invalid bytes are escaped.
     ?_assertEqual(<<"m.erl:1 in m:f/0\n"
                     "> 1  ab      c\n"
                     "  2  \x{E9}       d\n"/utf8>>,
                   erx_source:render(Excerpt({m, f, 0, "m.erl", 1}, 1, [<<"ab\tc">>, <<"\x{E9}\td"/utf8>>]))),
     ?_assertEqual(<<"m.erl:1 in m:f/0\n"
                     "> 1  <U+001B>[2J<U+0007><0xFF><U+202E>\n">>,
                   erx_source:render(Excerpt({m, f, 0, "m.erl", 1}, 1, [<<27, "[2J", 7, 255, "\x{202E}"/utf8>>]))),
     %% Names from the location are escaped too.
     ?_assertEqual(<<"x<U+001B>.erl:1 in 'a\\nb':'<U+202E>'/0\n"
                     "> 1  t\n">>,
                   erx_source:render(Excerpt({'a\nb', '\x{202E}', 0, "x\e.erl", 1}, 1, [<<"t">>])))].

%% lines/1 on processes and functions of a probe module

probe_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun shows_waiting_process/1,
      fun shows_function_first_line/1,
      fun absent_source_is_unsupported/1,
      fun module_from_binary_is_unsupported/1,
      fun other_code_in_file_is_unsupported/1,
      fun old_code_is_unsupported/1,
      fun dead_pid_is_scope/1]}.

pid_test_() ->
    Remote = binary_to_term(<<131, 88, 119, 10, "other@host", 1:32, 0:32, 1:32>>),
    [?_assertEqual({error, unsupported}, erx_source:lines(Remote)),
     ?_assertEqual({error, scope}, erx_source:lines(list_to_pid("<0.99999.0>"))),
     ?_assertEqual({error, scope}, erx:source(list_to_pid("<0.99999.0>"))),
     ?_assertError(badarg, erx_source:lines(self_name)),
     ?_assertError(badarg, erx_source:lines({m, f, -1})),
     %% A module that is not loaded is not loaded to show it.
     ?_assertEqual({error, unsupported}, erx_source:lines({erx_source_no_such_module, f, 0}))].

setup() ->
    Root = filename:absname("probe"),
    ok = filelib:ensure_path(filename:join(Root, "src")),
    ok = filelib:ensure_path(filename:join(Root, "ebin")),
    install(Root, ?PROBE_V1),
    Root.

cleanup(Root) ->
    code:purge(?PROBE),
    code:delete(?PROBE),
    code:purge(?PROBE),
    ok = file:del_dir_r(Root).

%% Writes the probe's source, compiles it into ebin and loads it from there.
install(Root, Source) ->
    Src = filename:join([Root, "src", "erx_source_probe.erl"]),
    ok = file:write_file(Src, Source),
    {ok, ?PROBE} = compile:file(Src, [{outdir, filename:join(Root, "ebin")}, report_errors]),
    code:purge(?PROBE),
    {module, ?PROBE} = code:load_abs(filename:join([Root, "ebin", "erx_source_probe"])),
    ok.

waiting() ->
    Pid = spawn(?PROBE, wait, []),
    wait_until(fun() -> element(2, process_info(Pid, current_function)) =:= {?PROBE, wait, 0} end),
    Pid.

wait_until(Done) ->
    case Done() of
        true -> ok;
        false -> timer:sleep(5), wait_until(Done)
    end.

shows_waiting_process(_Root) ->
    Pid = waiting(),
    {ok, Excerpt} = erx_source:lines(Pid),
    Pid ! stop,
    #{location := {?PROBE, wait, 0, File, Line}, first := First, lines := Lines} = Excerpt,
    Rendered = erx_source:render(Excerpt),
    [?_assertEqual("erx_source_probe.erl", filename:basename(File)),
     ?_assertEqual(6, Line),
     ?_assertEqual(1, First),
     ?_assertEqual(<<"wait() ->">>, lists:nth(Line - First + 1, Lines)),
     ?_assertMatch({_, _}, binary:match(Rendered, <<"> 6  wait() ->\n">>)),
     ?_assertMatch({_, _}, binary:match(Rendered, <<"tab    here and an escape <U+001B>[31m.">>))].

shows_function_first_line(_Root) ->
    {ok, Excerpt} = erx_source:lines({?PROBE, add, 2}),
    [?_assertMatch(#{location := {?PROBE, add, 2, _, 3}, first := 1}, Excerpt),
     ?_assertEqual({error, unsupported}, erx_source:lines({?PROBE, add, 3}))].

absent_source_is_unsupported(Root) ->
    ok = file:delete(filename:join([Root, "src", "erx_source_probe.erl"])),
    Pid = waiting(),
    Answer = erx_source:lines(Pid),
    Pid ! stop,
    [?_assertEqual({error, unsupported}, Answer),
     ?_assertEqual({error, unsupported}, erx_source:lines({?PROBE, add, 2}))].

%% As the code service loads a module from the host: named by its hash.
module_from_binary_is_unsupported(Root) ->
    {ok, Beam} = file:read_file(filename:join([Root, "ebin", "erx_source_probe.beam"])),
    code:purge(?PROBE),
    {module, ?PROBE} = code:load_binary(?PROBE, "0123abcd.beam", Beam),
    Pid = waiting(),
    Answer = erx_source:lines(Pid),
    Pid ! stop,
    [?_assertEqual({error, unsupported}, Answer)].

%% The file in ebin is no longer the code in memory.
other_code_in_file_is_unsupported(Root) ->
    Src = filename:join([Root, "src", "erx_source_probe.erl"]),
    ok = file:write_file(Src, ?PROBE_V2),
    {ok, ?PROBE} = compile:file(Src, [{outdir, filename:join(Root, "ebin")}, report_errors]),
    [?_assertEqual({error, unsupported}, erx_source:lines({?PROBE, add, 2}))].

%% A process left in the old code by a reload is not shown the new source.
old_code_is_unsupported(Root) ->
    Pid = waiting(),
    install_over(Root, ?PROBE_V2),
    Answer = erx_source:lines(Pid),
    Pid ! stop,
    [?_assertEqual({error, unsupported}, Answer),
     ?_assertMatch({ok, #{location := {?PROBE, add, 2, _, 3}}}, erx_source:lines({?PROBE, add, 2}))].

install_over(Root, Source) ->
    Src = filename:join([Root, "src", "erx_source_probe.erl"]),
    ok = file:write_file(Src, Source),
    {ok, ?PROBE} = compile:file(Src, [{outdir, filename:join(Root, "ebin")}, report_errors]),
    {module, ?PROBE} = code:load_abs(filename:join([Root, "ebin", "erx_source_probe"])),
    ok.

dead_pid_is_scope(_Root) ->
    Pid = waiting(),
    Ref = monitor(process, Pid),
    Pid ! stop,
    receive {'DOWN', Ref, process, Pid, _} -> ok end,
    [?_assertEqual({error, scope}, erx_source:lines(Pid))].

