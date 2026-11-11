%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_dmesg_tests).
-moduledoc """
EUnit cases of the command shell's `dmesg` (erx_cmd_dmesg,
docs/design-shell.md, "Text commands"): FreeBSD's flags, `-a` accepted
and `-c`, `-M` and `-N` refused with FreeBSD's usage line, as are an
unknown flag and an argument. The host has no `/proc/kernel/log`, so
`dmesg` and `dmesg -a` both report that file: the file is what they
read. What the file holds is erx_procfs_tests' (test/erlang); the QEMU
shell suite reads it through `dmesg | grep`.
""".

-include_lib("eunit/include/eunit.hrl").

-define(USAGE, <<"usage: dmesg [-ac] [-M core [-N system]]\n">>).

run_line(Source) ->
    {Table, []} = erx_shell_namespace:build(
                    [{Module, Module:module_info(attributes), Module:module_info(exports)}
                     || Module <- [erx_cmd_dmesg]]),
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

usage_test_() ->
    [?_assertEqual({<<"usage">>, <<>>, ?USAGE}, run_line(Line))
     || Line <- [<<"dmesg -c">>, <<"dmesg -ac">>, <<"dmesg -M core">>, <<"dmesg -N kernel">>,
                 <<"dmesg -M core -N kernel">>, <<"dmesg -z">>, <<"dmesg extra">>, <<"dmesg -a extra">>,
                 <<"dmesg -">>]].

reads_the_kernel_log_file_test_() ->
    [?_assertMatch({Status, <<>>, <<"dmesg: /proc/kernel/log: ", _/binary>>} when Status =/= <<>>,
                   run_line(Line))
     || Line <- [<<"dmesg">>, <<"dmesg -a">>, <<"dmesg -aa">>, <<"dmesg --">>]].
