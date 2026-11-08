%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_uname_tests).
-moduledoc """
EUnit cases of the command shell's `uname` (erx_cmd_uname,
docs/design-shell.md, "Text commands"): the fields each flag selects, `-a`
and no flag, FreeBSD's order whatever the order of the flags, the layout,
the values abi/erx_abi.txt and the architecture's file give, the version's
four words and the date's layout, `unknown` for what the running system
cannot tell, the build facts' reader (erx_build:parse_facts/1), and the
usage errors. The emulator
that runs them is started as the system release is, with
`-sname uname@erxtest -kernel start_distribution false`
(test/host/erx_cmd_uname_test.rb), so it runs no distribution and a line
run through the shell finds the host `erxtest` among init's arguments;
its init has no `-erx build` and its root no build facts, so the build
configurationifier and every build fact are `unknown`, the never-fabricate case
end to end.
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

%% 2026-11-08 18:02:11 UTC, a Sunday.
-define(COMMITTED, 1794160931).
-define(KNOWN, #{nodename => <<"erxos">>, build => <<"2255e43fb7866bb3">>,
                 revision => <<"n1234-5e45e725588e">>, date => ?COMMITTED,
                 configuration => <<"qemu-virt/development">>, kernel => <<"fiasco-50bbe8a98119">>}).
-define(UNKNOWN, #{nodename => unknown, build => unknown, revision => unknown, date => unknown,
                   configuration => unknown, kernel => unknown}).
-define(VERSION, "n1234-5e45e725588e Sun Nov  8 18:02:11 UTC 2026 qemu-virt/development fiasco-50bbe8a98119").

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
     ?_assertEqual([configuration], F("i")),
     ?_assertEqual([kernel], F("K")),
     %% -a is -mnrsv: no processor and no build configurationifier, as on FreeBSD.
     ?_assertEqual([sysname, nodename, release, version, machine], F("a")),
     ?_assertEqual([sysname, nodename, release, version, machine, processor, build], F("abp")),
     ?_assertEqual([sysname, nodename, release, version, machine, processor, configuration, kernel, build], F("abpiK")),
     %% FreeBSD's order, whatever the order of the flags; a repeated flag counts once.
     ?_assertEqual([sysname, release, machine], F("mrs")),
     ?_assertEqual([sysname], F("oso")),
     ?_assertEqual([nodename, processor, build], F("bpn")),
     ?_assertEqual([configuration, kernel], F("Ki"))].

%% Every order of the nine field flags gives FreeBSD's order.
fields_in_any_order_test() ->
    All = [sysname, nodename, release, version, machine, processor, configuration, kernel, build],
    [?assertEqual(All, erx_cmd_uname:fields(Order)) || Order <- permutations("snrvmpiKb")].

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
     ?_assertEqual(<<?VERSION "\n">>, line([version], ?KNOWN)),
     ?_assertEqual(<<"qemu-virt/development\n">>, line([configuration], ?KNOWN)),
     ?_assertEqual(<<"fiasco-50bbe8a98119\n">>, line([kernel], ?KNOWN)),
     ?_assertEqual(<<"erXos erxos 0.1.0 " ?VERSION " arm64\n">>, line(erx_cmd_uname:fields("a"), ?KNOWN)),
     %% A build fact passes the field escape, whatever erx_build admitted.
     ?_assertEqual(<<"a\\x1B]8\n">>, line([kernel], maps:put(kernel, <<"a\e]8">>, ?KNOWN))),
     %% What the running system cannot tell is written unknown, never guessed.
     ?_assertEqual(<<"unknown\n">>, line([nodename], ?UNKNOWN)),
     ?_assertEqual(<<"unknown\n">>, line([build], ?UNKNOWN)),
     ?_assertEqual(<<"unknown unknown unknown unknown\n">>, line([version], ?UNKNOWN)),
     ?_assertEqual(<<"unknown\n">>, line([configuration], ?UNKNOWN)),
     ?_assertEqual(<<"unknown\n">>, line([kernel], ?UNKNOWN))].

%%% The date

%% macOS's date layout in UTC: a space-padded day, zero-padded time.
date_test_() ->
    D = fun erx_cmd_uname:date/1,
    [?_assertEqual(<<"Sun Nov  8 18:02:11 UTC 2026">>, D(?COMMITTED)),
     ?_assertEqual(<<"Thu Jan  1 00:00:00 UTC 1970">>, D(0)),
     ?_assertEqual(<<"Tue Aug 11 21:05:48 UTC 2026">>, D(1786482348)),
     ?_assertEqual(<<"Sat Feb 29 23:59:59 UTC 2020">>, D(1583020799))].

%%% The build facts

-define(FACTS, <<"revision n1234-5e45e725588e\ndate 1794160931\n"
                 "configuration qemu-virt/development\nkernel fiasco-50bbe8a98119\n">>).

parse_facts_test_() ->
    P = fun erx_build:parse_facts/1,
    Replace = fun(Old, New) -> binary:replace(?FACTS, Old, New) end,
    [?_assertEqual({ok, maps:without([nodename, build], ?KNOWN)}, P(?FACTS)),
     %% unknown stands for what the build could not determine, in any field.
     ?_assertEqual({ok, maps:without([nodename, build], ?UNKNOWN)},
                   P(<<"revision unknown\ndate unknown\nconfiguration unknown\nkernel unknown\n">>)),
     ?_assertEqual({ok, (maps:without([nodename, build], ?KNOWN))#{revision => <<"n7-0123456789ab-dirty">>}},
                                 P(Replace(<<"n1234-5e45e725588e">>, <<"n7-0123456789ab-dirty">>))),
%% A shallow clone's revision has no count.
?_assertEqual({ok, (maps:without([nodename, build], ?KNOWN))#{revision => <<"0123456789ab-dirty">>}},
              P(Replace(<<"n1234-5e45e725588e">>, <<"0123456789ab-dirty">>))),
     %% Anything else is refused whole.
     [?_assertMatch({error, {bad_facts, _}}, P(Bytes))
      || Bytes <- [<<>>,
                   binary:part(?FACTS, 0, byte_size(?FACTS) - 1),
                   <<?FACTS/binary, "extra x\n">>,
                   Replace(<<"date">>, <<"time">>),
                   Replace(<<"revision n1234">>, <<"revision  n1234">>),
                   Replace(<<"n1234">>, <<"n12 34">>),
                   Replace(<<"n1234">>, <<"n12\e]8;;34">>),
                   Replace(<<"n1234">>, <<"-n1234">>),
                   %% A branch is not part of the revision.
                   Replace(<<"n1234">>, <<"master-n1234">>),
                   Replace(<<"n1234">>, <<"n01234">>),
                   Replace(<<"n1234">>, <<"n12345678901">>),
                   Replace(<<"n1234-">>, <<"n-">>),
                   Replace(<<"5e45e725588e">>, <<"5E45E725588E">>),
                   Replace(<<"5e45e725588e">>, <<"5e45e725588">>),
                   Replace(<<"5e45e725588e">>, <<"5e45e725588e-clean">>),
                   Replace(<<"1794160931">>, <<"17941609x1">>),
                   Replace(<<"1794160931">>, <<"1794160931000">>),
                   Replace(<<"1794160931">>, <<>>),
                   Replace(<<"qemu-virt/development">>, <<"QEMU-VIRT/DEVELOPMENT">>),
                   Replace(<<"qemu-virt/development">>, <<"qemu-virt">>),
                   Replace(<<"qemu-virt/development">>, <<"qemu/virt/development">>),
                   Replace(<<"fiasco">>, <<"Fiasco">>),
                   Replace(<<"\nkernel">>, <<"\r\nkernel">>),
                   <<"date 1794160931\nrevision n1234-5e45e725588e\n"
                     "configuration qemu-virt/development\nkernel fiasco-50bbe8a98119\n">>,
                   Replace(<<"n1234-5e45e725588e">>, binary:copy(<<"a">>, 161)),
                   <<?FACTS/binary, (binary:copy(<<"x">>, 512))/binary>>]]].

%%% Through the shell

shell_test_() ->
    [?_assertEqual({<<>>, <<"erXos\n">>, <<>>}, run_line(<<"uname">>)),
     ?_assertEqual({<<>>, <<"erXos erxtest 0.1.0 unknown unknown unknown unknown arm64\n">>, <<>>},
                   run_line(<<"uname -a">>)),
     ?_assertEqual({<<>>, <<"erXos 0.1.0 arm64 aarch64\n">>, <<>>}, run_line(<<"uname -p -mrs">>)),
     ?_assertEqual({<<>>, <<"erXos\n">>, <<>>}, run_line(<<"uname -o --">>)),
     ?_assertEqual({<<>>, <<"unknown unknown\n">>, <<>>}, run_line(<<"uname -K -i">>)),
     %% An option FreeBSD's uname has and this one does not offer, an unknown
     %% option and an argument, `-` and a word after `--` included, are each
     %% a usage error.
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: uname [-abiKmnoprsv]\n">>}, run_line(<<"uname -U">>)),
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: uname [-abiKmnoprsv]\n">>}, run_line(<<"uname -z">>)),
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: uname [-abiKmnoprsv]\n">>}, run_line(<<"uname -s extra">>)),
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: uname [-abiKmnoprsv]\n">>}, run_line(<<"uname -">>)),
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: uname [-abiKmnoprsv]\n">>}, run_line(<<"uname -- -s">>))].
