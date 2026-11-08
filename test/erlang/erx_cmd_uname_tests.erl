%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_uname_tests).
-moduledoc """
EUnit cases of the command shell's `uname` (erx_cmd_uname,
docs/design-shell.md, "Text commands"): the fields each flag selects, `-a`
and no flag, FreeBSD's order whatever the order of the flags, the layout,
the values abi/erx_abi.txt and the architecture's file give, `unknown` for
what the running system cannot tell, and the usage errors. The emulator
that runs them is started as the system release is, with
`-sname uname@erxtest -kernel start_distribution false`
(test/host/erx_cmd_uname_test.rb), so it runs no distribution and a line
run through the shell finds the host `erxtest` among init's arguments;
its init has no `-erx build`, so the build identifier is `unknown`, the
never-fabricate case end to end.
""".

-include_lib("eunit/include/eunit.hrl").

%%% Running a line

%% Runs a line of the shell, answering its status, its standard output and its
%% standard error.
run_line(Source) ->
    {Table, []} = erx_shell_namespace:build(
                    [{Module, Module:module_info(attributes), Module:module_info(exports)}
                     || Module <- [erx_cmd_uname]]),
    State = erx_shell_runner:state(#{cwd => <<"/">>, fds => #{0 => null, 1 => sink(out), 2 => sink(err)},
                                     table => Table, facets => #{}}),
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

line(Fields, Facts) -> iolist_to_binary(erx_cmd_uname:line(Fields, Facts)).

-define(KNOWN, #{nodename => <<"erxos">>, build => <<"2255e43fb7866bb3">>}).
-define(UNKNOWN, #{nodename => unknown, build => unknown}).

%%% Selection

fields_test_() ->
    F = fun erx_cmd_uname:fields/1,
    [?_assertEqual([sysname], F("")),
     ?_assertEqual([sysname], F("s")),
     ?_assertEqual([sysname], F("o")),
     ?_assertEqual([nodename], F("n")),
     ?_assertEqual([release], F("r")),
     ?_assertEqual([version], F("v")),
     ?_assertEqual([machine], F("m")),
     ?_assertEqual([processor], F("p")),
     ?_assertEqual([build], F("b")),
     %% -a is -mnrsv: no processor and no build identifier, as on FreeBSD.
     ?_assertEqual([sysname, nodename, release, version, machine], F("a")),
     ?_assertEqual([sysname, nodename, release, version, machine, processor, build], F("abp")),
     %% FreeBSD's order, whatever the order of the flags; a repeated flag counts once.
     ?_assertEqual([sysname, release, machine], F("mrs")),
     ?_assertEqual([sysname], F("oso")),
          ?_assertEqual([nodename, processor, build], F("bpn"))].

%% Every order of the seven field flags gives FreeBSD's order.
fields_in_any_order_test() ->
    All = [sysname, nodename, release, version, machine, processor, build],
    [?assertEqual(All, erx_cmd_uname:fields(Order)) || Order <- permutations("snrvmpb")].

permutations([]) -> [[]];
permutations(List) -> [[H | T] || H <- List, T <- permutations(List -- [H])].

%%% The host name

host_test_() ->
    H = fun erx_cmd_uname:host/1,
    [?_assertEqual(<<"erxos">>, H(<<"system@erxos">>)),
     ?_assertEqual(<<"erxos.example">>, H(<<"web@erxos.example">>)),
     %% A runtime that is not a node, and a name with no host, have none.
     ?_assertEqual(unknown, H(<<"nonode@nohost">>)),
     ?_assertEqual(unknown, H(none)),
     ?_assertEqual(unknown, H(<<"system">>)),
     ?_assertEqual(unknown, H(<<"system@">>)),
     ?_assertEqual(unknown, H(<<"@erxos">>)),
     ?_assertEqual(unknown, H(<<"a@b@c">>))].

%%% The line

line_test_() ->
    [?_assertEqual(<<"erXos\n">>, line([sysname], ?KNOWN)),
     ?_assertEqual(<<"0.1.0\n">>, line([release], ?KNOWN)),
     ?_assertEqual(<<"arm64\n">>, line([machine], ?KNOWN)),
     ?_assertEqual(<<"aarch64\n">>, line([processor], ?KNOWN)),
     ?_assertEqual(<<"erxos\n">>, line([nodename], ?KNOWN)),
     ?_assertEqual(<<"2255e43fb7866bb3\n">>, line([build], ?KNOWN)),
     ?_assertEqual(<<"erXos 0.1.0 build 2255e43fb7866bb3\n">>, line([version], ?KNOWN)),
     ?_assertEqual(<<"erXos erxos 0.1.0 erXos 0.1.0 build 2255e43fb7866bb3 arm64\n">>,
                   line(erx_cmd_uname:fields("a"), ?KNOWN)),
     %% What the running system cannot tell is written unknown, never guessed.
     ?_assertEqual(<<"unknown\n">>, line([nodename], ?UNKNOWN)),
     ?_assertEqual(<<"unknown\n">>, line([build], ?UNKNOWN)),
     ?_assertEqual(<<"erXos 0.1.0 build unknown\n">>, line([version], ?UNKNOWN))].

%%% Through the shell

shell_test_() ->
    [?_assertEqual({<<>>, <<"erXos\n">>, <<>>}, run_line(<<"uname">>)),
     ?_assertEqual({<<>>, <<"erXos erxtest 0.1.0 erXos 0.1.0 build unknown arm64\n">>, <<>>},
                   run_line(<<"uname -a">>)),
     ?_assertEqual({<<>>, <<"erXos 0.1.0 arm64 aarch64\n">>, <<>>}, run_line(<<"uname -p -mrs">>)),
     ?_assertEqual({<<>>, <<"erXos\n">>, <<>>}, run_line(<<"uname -o --">>)),
     %% An option FreeBSD's uname has and this one does not offer, an unknown
     %% option and an argument, `-` and a word after `--` included, are each
     %% a usage error.
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: uname [-abmnoprsv]\n">>}, run_line(<<"uname -K">>)),
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: uname [-abmnoprsv]\n">>}, run_line(<<"uname -z">>)),
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: uname [-abmnoprsv]\n">>}, run_line(<<"uname -s extra">>)),
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: uname [-abmnoprsv]\n">>}, run_line(<<"uname -">>)),
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: uname [-abmnoprsv]\n">>}, run_line(<<"uname -- -s">>))].
