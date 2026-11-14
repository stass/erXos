%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_reboot_tests).
-moduledoc """
EUnit cases of the command shell's `reboot` and `halt` (erx_cmd_reboot):
the request each name and flag set parses to, the usage errors FreeBSD's
command gives, each under its own name's usage line, and the authority
rule, which refuses every runtime but the system domain's. No case ends
anything: a development host's runtime stands for the system domain, so
only lines that fail before the end are run through the shell.
""".

-include_lib("eunit/include/eunit.hrl").

run_line(Source) ->
    {Table, []} = erx_shell_namespace:build(
                    [{Module, Module:module_info(attributes), Module:module_info(exports)}
                     || Module <- [erx_cmd_reboot, erx_cmd_halt]]),
    State = erx_shell_runner:state(#{cwd => <<"/">>, fds => #{0 => null, 1 => sink(out), 2 => sink(err)},
                                     table => Table, facets => fun() -> #{} end}),
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

authority_test_() ->
    [?_assert(erx_cmd_reboot:may_end(system)),
     ?_assertNot(erx_cmd_reboot:may_end(domain))].

usage_test_() ->
    [?_assertEqual({<<"usage">>, <<>>, <<"usage: reboot [-lpq]\n">>}, run_line(<<"reboot -c">>)),
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: halt [-lpq]\n">>}, run_line(<<"halt -r">>)),
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: halt [-lpq]\n">>}, run_line(<<"halt now">>))].
