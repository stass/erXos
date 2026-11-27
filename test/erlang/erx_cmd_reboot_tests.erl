%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_reboot_tests).
-moduledoc """
EUnit cases of the command shell's `reboot` and `halt` (erx_cmd_reboot):
the request each name and flag set parses to, the line each end writes,
what an accepted end does in each runtime, the usage errors FreeBSD's
command gives, each under its own name's usage line, the shell's
no_facet for a session without the machine grant, and a refused write's
diagnostic. No case ends anything: the host's /svc holds no machine tree,
so every write finds none (erx_svc_client's not_serving).
""".

-include_lib("eunit/include/eunit.hrl").

run_line(Source) ->
    run_line(Source, #{machine => grant}).

run_line(Source, Facets) ->
    {Table, []} = erx_shell_namespace:build(
                    [{Module, Module:module_info(attributes), Module:module_info(exports)}
                     || Module <- [erx_cmd_reboot, erx_cmd_halt]]),
    State = erx_shell_runner:state(#{cwd => <<"/">>, fds => #{0 => null, 1 => sink(out), 2 => sink(err)},
                                     table => Table, facets => fun() -> Facets end}),
    Shell = erx_shell_eval:new(#{}, erx_shell_runner:runner(), State),
    {ok, Done} = erx_shell_eval:run_source(Source, Shell),
    {erx_shell_eval:status(Done), shown(out), shown(err)}.

sink(Stream) ->
    Me = self(),
    {tty, fun(Bytes) -> Me ! {Stream, iolist_to_binary(Bytes)}, ok end}.

shown(Stream) -> shown(Stream, []).

shown(Stream, Acc) ->
    receive {Stream, Bytes} -> shown(Stream, [Acc, Bytes])
    after 0 -> iolist_to_binary(Acc)
    end.

parse_test_() ->
    [?_assertEqual({ok, reset}, erx_cmd_reboot:parse(<<"reboot">>, [])),
     ?_assertEqual({ok, off}, erx_cmd_reboot:parse(<<"halt">>, [])),
     %% -p is plain halt for halt, and a power-off for reboot, as FreeBSD's.
     ?_assertEqual({ok, off}, erx_cmd_reboot:parse(<<"halt">>, [<<"-p">>])),
     ?_assertEqual({ok, off}, erx_cmd_reboot:parse(<<"reboot">>, [<<"-p">>])),
     %% -q and -l ask for the same end.
     ?_assertEqual({ok, reset}, erx_cmd_reboot:parse(<<"reboot">>, [<<"-q">>])),
     ?_assertEqual({ok, reset}, erx_cmd_reboot:parse(<<"reboot">>, [<<"-l">>])),
     ?_assertEqual({ok, off}, erx_cmd_reboot:parse(<<"halt">>, [<<"-lq">>])),
     ?_assertEqual({ok, off}, erx_cmd_reboot:parse(<<"reboot">>, [<<"-q">>, <<"-lp">>])),
     %% The flags left out, and an argument after the flags.
     [?_assertEqual({error, usage}, erx_cmd_reboot:parse(<<"reboot">>, [Flag]))
      || Flag <- [<<"-c">>, <<"-d">>, <<"-k">>, <<"-r">>, <<"-n">>, <<"-N">>, <<"-D">>, <<"-f">>]],
     ?_assertEqual({error, usage}, erx_cmd_reboot:parse(<<"halt">>, [<<"now">>])),
     ?_assertEqual({error, usage}, erx_cmd_reboot:parse(<<"reboot">>, [<<"-q">>, <<"now">>]))].

%% Every shell writes the end's line to the machine tree's ctl under /svc; once the end is accepted only the
%% system domain's shell, which the end ends too, waits for it.
line_test_() ->
    [?_assertEqual(<<"reset\n">>, erx_cmd_reboot:line(reset)),
     ?_assertEqual(<<"off\n">>, erx_cmd_reboot:line(off))].

accepted_test_() ->
    [?_assertEqual(wait, erx_cmd_reboot:accepted(true)),
     ?_assertEqual(exit, erx_cmd_reboot:accepted(false))].

%% A session without the grant: the shell refuses before the command starts.
no_facet_test_() ->
    [?_assertEqual({<<"no_facet">>, <<>>, <<"reboot: no_facet\n">>}, run_line(<<"reboot">>, #{})),
     ?_assertEqual({<<"no_facet">>, <<>>, <<"halt: no_facet\n">>}, run_line(<<"halt -p">>, #{}))].

%% A write that finds no machine tree under /svc prints enoent's text under the
%% command's name and exits 1, as a refused write prints its errno's.
refused_test_() ->
    [?_assertEqual({<<"1">>, <<>>, <<"halt: no such file or directory\n">>}, run_line(<<"halt">>)),
     ?_assertEqual({<<"1">>, <<>>, <<"reboot: no such file or directory\n">>}, run_line(<<"reboot -q">>))].

%% A write whose answer is not known, at the deadline or because the machine
%% tree's handler ended (eio, which erx_svc_client answers as unknown), prints
%% etimedout's text: the end may have begun.
reason_test_() ->
    [?_assertEqual(etimedout, erx_cmd_reboot:reason(unknown)),
     ?_assertEqual(enoent, erx_cmd_reboot:reason(not_serving)),
     ?_assertEqual(ebusy, erx_cmd_reboot:reason({error, ebusy}))].

usage_test_() ->
    [?_assertEqual({<<"usage">>, <<>>, <<"usage: reboot [-lpq]\n">>}, run_line(<<"reboot -c">>)),
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: halt [-lpq]\n">>}, run_line(<<"halt -r">>)),
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: halt [-lpq]\n">>}, run_line(<<"halt now">>))].
