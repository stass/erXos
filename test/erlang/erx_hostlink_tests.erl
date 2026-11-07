%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_hostlink's pure parts (docs/design-live.md, "The host link"): the
%% build identifier read from the root's `-erx build` word, which a hello reports and the
%% host checks, and what the root answers. The effects themselves run end to end in the
%% production image's host link boot (tools/lib/erx/hostlink_guest.rb).
-module(erx_hostlink_tests).

-include_lib("eunit/include/eunit.hrl").

%% The root passes the build identifier in decimal, which init can parse as a term; the
%% hello reports it in hexadecimal, as the root's identity line prints it. 2255e43fb7866bb3
%% is one that, passed in hexadecimal, stopped the boot as an illegal integer.
build_test_() ->
    Id = integer_to_list(16#2255e43fb7866bb3),
    Max = integer_to_list((1 bsl 64) - 1),
    [?_assertEqual({ok, <<"2255e43fb7866bb3">>}, erx_hostlink:build([["build", Id]])),
     ?_assertEqual({ok, <<"00000000000000ff">>}, erx_hostlink:build([["build", "255"]])),
     ?_assertEqual({ok, <<"ffffffffffffffff">>}, erx_hostlink:build([["build", Max]])),
     %% A plain word of the kernel command line may follow; it is not the build's.
     ?_assertEqual({ok, <<"2255e43fb7866bb3">>}, erx_hostlink:build([["console_uart", "1", "2", "3"],
                                                                     ["build", Id, "plainword"]])),
     ?_assertMatch({error, {no_build, _}}, erx_hostlink:build([])),
     ?_assertMatch({error, {no_build, _}}, erx_hostlink:build([["build"]])),
     ?_assertMatch({error, {bad_build, _}}, erx_hostlink:build([["build", Id], ["build", Id]])),
     ?_assertMatch({error, {bad_build, _}}, erx_hostlink:build([["build", "2255e43fb7866bb3"]])),
     ?_assertMatch({error, {bad_build, _}}, erx_hostlink:build([["build", "18446744073709551616"]])),
     ?_assertMatch({error, {bad_build, _}}, erx_hostlink:build([["build", "000000000000000000001"]])),
     ?_assertMatch({error, {bad_build, _}}, erx_hostlink:build([["build", "-1"]]))].

%% Every name the design lists but this machine does not serve is unsupported; anything
%% else, other names and other requests, is badarg, and opens nothing.
root_test_() ->
    Link = self(),
    [?_assertEqual({{error, unsupported}, []}, erx_hostlink:root({open, Name}, Link))
     || Name <- [inspect, trace, update, code, domain, console, web]] ++
    [?_assertEqual({{error, badarg}, []}, erx_hostlink:root(Request, Link))
     || Request <- [{open, nosuch}, {open, <<"install">>}, open, {open, install, extra}, 42]].

%% An install facet is a process the root reports as opened, and it ends with its link.
install_facet_ends_with_its_link_test() ->
    Link = spawn(fun() -> receive stop -> ok end end),
    {{ok, Facet}, [Facet]} = erx_hostlink:root({open, install}, Link),
    Ref = erlang:monitor(process, Facet),
    Link ! stop,
    receive {'DOWN', Ref, process, Facet, Reason} -> ?assertEqual(shutdown, Reason)
    after 5000 -> error(facet_outlived_its_link)
    end.
