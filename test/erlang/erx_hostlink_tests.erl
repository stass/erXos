%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_hostlink's pure parts (docs/design-live.md, "The host link"): the
%% build identifier erx_build reads from the root's `-erx build` word, which a hello reports
%% and the host checks, and what the root answers. The effects themselves run end to end in the
%% production image's host link boot (tools/lib/erx/hostlink_guest.rb).
-module(erx_hostlink_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

%% The root passes the build identifier in decimal, which init can parse as a term; the
%% hello reports it in hexadecimal, as the root's identity line prints it. 2255e43fb7866bb3
%% is one that, passed in hexadecimal, stopped the boot as an illegal integer.
build_test_() ->
    Id = integer_to_list(16#2255e43fb7866bb3),
    Max = integer_to_list((1 bsl 64) - 1),
    [?_assertEqual({ok, <<"2255e43fb7866bb3">>}, erx_build:id([["build", Id]])),
     ?_assertEqual({ok, <<"00000000000000ff">>}, erx_build:id([["build", "255"]])),
     ?_assertEqual({ok, <<"ffffffffffffffff">>}, erx_build:id([["build", Max]])),
     %% A plain word of the kernel command line may follow; it is not the build's.
     ?_assertEqual({ok, <<"2255e43fb7866bb3">>}, erx_build:id([["console_uart", "1", "2", "3"],
                                                                     ["build", Id, "plainword"]])),
     ?_assertMatch({error, {no_build, _}}, erx_build:id([])),
     ?_assertMatch({error, {no_build, _}}, erx_build:id([["build"]])),
     ?_assertMatch({error, {bad_build, _}}, erx_build:id([["build", Id], ["build", Id]])),
     ?_assertMatch({error, {bad_build, _}}, erx_build:id([["build", "2255e43fb7866bb3"]])),
     ?_assertMatch({error, {bad_build, _}}, erx_build:id([["build", "18446744073709551616"]])),
     ?_assertMatch({error, {bad_build, _}}, erx_build:id([["build", "000000000000000000001"]])),
     ?_assertMatch({error, {bad_build, _}}, erx_build:id([["build", "-1"]]))].

%% Every name the design lists but this machine does not serve is unsupported; anything
%% else, other names and other requests, is badarg, and opens nothing.
root_test_() ->
    Link = self(),
    [?_assertEqual({{error, unsupported}, []}, erx_hostlink:root({open, Name}, Link))
     || Name <- [inspect, trace, update, code, domain, console, web]] ++
    [?_assertEqual({{error, badarg}, []}, erx_hostlink:root(Request, Link))
     || Request <- [{open, nosuch}, {open, <<"install">>}, open, {open, install, extra}, 42]].

%% Only the heap bound refuses a payload as too large: a payload whose term passes the
%% session's resident limit (32 MiB) is too_large, and any other end of the measuring
%% process is a failure named with its reason.
bounded_measure_test_() ->
    {timeout, 60,
     [?_assertEqual({error, too_large}, erx_hostlink:bounded_measure(term_to_binary(lists:duplicate(3000000, 0)))),
      ?_assertMatch({error, {failed, {function_clause, _}}}, erx_hostlink:bounded_measure(not_a_payload)),
      ?_assertMatch({ok, _}, erx_hostlink:bounded_measure(term_to_binary(ok)))]}.

%% An install facet is a process the root reports as opened, and it ends with its link.
install_facet_ends_with_its_link_test() ->
    Link = spawn(fun() -> receive stop -> ok end end),
    {{ok, Facet}, [Facet]} = erx_hostlink:root({open, install}, Link),
    Ref = erlang:monitor(process, Facet),
    Link ! stop,
    receive {'DOWN', Ref, process, Facet, Reason} -> ?assertEqual(shutdown, Reason)
    after 5000 -> error(facet_outlived_its_link)
    end.

%% The web facet (erx_hostlink_web). A stand-in relay answers each gen_server call with
%% what the test told it and reports the request and its caller.
relay(Test) ->
    receive
        {answer, Answer} -> relay_answering(Test, Answer)
    end.

relay_answering(Test, Answer) ->
    receive
        {answer, Next} ->
            relay_answering(Test, Next);
        {'$gen_call', {Caller, _} = From, Request} ->
            Test ! {relayed, Caller, Request},
            gen_server:reply(From, Answer),
            relay_answering(Test, Answer)
    end.

-define(ROOT_LINE, #{principal => <<"root">>, build => <<"00000000000000ff">>}).

open_web(Relay) ->
    erx_hostlink_web:open(self(), Relay, {ok, <<"00000000000000ff">>}, ?ERX_MANIFEST_DEVELOPMENT).

%% The root opens a web facet only where the domain holds the web domain's relay and
%% knows its build.
web_facet_needs_the_relay_test() ->
    Relay = spawn(fun() -> receive stop -> ok end end),
    ?assertEqual({{error, unsupported}, []},
                 erx_hostlink_web:open(self(), undefined, {ok, <<"00">>}, ?ERX_MANIFEST_DEVELOPMENT)),
    ?assertEqual({{error, unsupported}, []},
                 erx_hostlink_web:open(self(), Relay, {error, {no_build, "none"}}, ?ERX_MANIFEST_DEVELOPMENT)),
    persistent_term:put({erx, facets}, #{web => Relay}),
    try ?assertEqual({{error, unsupported}, []}, erx_hostlink:root({open, web}, self()))
    after persistent_term:erase({erx, facets})
    end,
    Relay ! stop.

%% The web front end logs every browser in as root, so the root offers the web facet only
%% on a development build: a release build, a partial boot of one, or a build whose
%% manifest flags are unknown is refused with the relay held, and no facet starts.
web_facet_needs_a_development_build_test() ->
    Relay = spawn(fun() -> receive stop -> ok end end),
    Build = {ok, <<"00000000000000ff">>},
    ?assertEqual({{error, unsupported}, []}, erx_hostlink_web:open(self(), Relay, Build, ?ERX_MANIFEST_MODE_RELEASE)),
    ?assertEqual({{error, unsupported}, []}, erx_hostlink_web:open(self(), Relay, Build, ?ERX_MANIFEST_PARTIAL_BOOT)),
    ?assertEqual({{error, unsupported}, []}, erx_hostlink_web:open(self(), Relay, Build, unknown)),
    Relay ! stop.

hostlink_call(Facet, Request) ->
    Ref = make_ref(),
    Facet ! {hostlink_call, self(), Ref, Request},
    receive {Ref, Reply} -> Reply after 5000 -> error(no_reply) end.

%% The facet hands the host's calls of the three shapes to the relay as calls of its own,
%% so the web domain learns the facet as the connection's sink, a connect naming root's
%% line, and refuses any other shape without asking the relay. Of the relay's answers only
%% ok and {error, Atom} pass.
web_facet_relays_the_hosts_calls_test() ->
    Test = self(),
    Relay = spawn_link(fun() -> relay(Test) end),
    Relay ! {answer, ok},
    {{ok, Facet}, [Facet]} = open_web(Relay),
    ?assertEqual(ok, hostlink_call(Facet, {connect, 3})),
    ?assertEqual(ok, hostlink_call(Facet, {data, 3, <<"hello">>})),
    ?assertEqual(ok, hostlink_call(Facet, {close, 3})),
    Relayed = [receive {relayed, Caller, Request} -> {Caller, Request} end || _ <- [1, 2, 3]],
    ?assertEqual([{Facet, {connect, 3, ?ROOT_LINE}}, {Facet, {data, 3, <<"hello">>}}, {Facet, {close, 3}}], Relayed),
    [?assertEqual({error, badarg}, hostlink_call(Facet, Bad))
     || Bad <- [{connect, -1}, {connect, 1 bsl 32}, {data, 3, "list"}, {close, three}, {open, 3}, connect]],
    Relay ! {answer, {error, busy}},
    ?assertEqual({error, busy}, hostlink_call(Facet, {connect, 4})),
    Relay ! {answer, {error, "text"}},
    ?assertEqual({error, failed}, hostlink_call(Facet, {connect, 5})),
    receive {relayed, _, {connect, 4, _}} -> ok end,
    receive {relayed, _, {connect, 5, _}} -> ok end,
    receive {relayed, _, Unasked} -> error({relayed, Unasked}) after 0 -> ok end.

%% What the web domain sends the facet reaches the host link as a cast on the facet, and
%% only in the web domain's envelope and of the two shapes, within their bounds.
web_facet_casts_what_the_web_domain_sends_test() ->
    Test = self(),
    Relay = spawn_link(fun() -> relay(Test) end),
    {{ok, Facet}, [Facet]} = open_web(Relay),
    Web = erx_dist:owner(Relay),
    Facet ! {erx_origin, Web, {web, 3, <<"welcome">>}},
    Facet ! {erx_origin, Web, {web_closed, 3, protocol}},
    Facet ! {erx_origin, Web + 1, {web, 3, <<"other domain">>}},
    Facet ! {web, 3, <<"no envelope">>},
    Facet ! {erx_origin, Web, {web, 3, binary:copy(<<"x">>, 65537)}},
    Facet ! {erx_origin, Web, {web, 3, <<"last">>}},
    Casts = [receive {facet_cast, Facet, Payload} -> binary_to_term(Payload) after 5000 -> none end
             || _ <- [1, 2, 3]],
    ?assertEqual([{web, 3, <<"welcome">>}, {web_closed, 3, protocol}, {web, 3, <<"last">>}], Casts),
    receive {facet_cast, _, Extra} -> error({cast, binary_to_term(Extra)}) after 100 -> ok end.

%% cast_of/2 over terms of the shapes and near them: it passes a term only of the two
%% shapes, within their bounds, and never fails.
web_cast_of_test() ->
    rand:seed(exsss, {1, 2, 3}),
    Pieces = [web, web_closed, 0, -1, 1 bsl 32, (1 bsl 32) - 1, <<"b">>, binary:copy(<<"x">>, 65536),
              binary:copy(<<"x">>, 65537), protocol, "text", self(), {}, #{}],
    Pick = fun() -> lists:nth(rand:uniform(length(Pieces)), Pieces) end,
    lists:foreach(fun(_) ->
                          Message = list_to_tuple([Pick() || _ <- lists:seq(1, rand:uniform(4))]),
                          case erx_hostlink_web:cast_of({erx_origin, 7, Message}, 7) of
                              drop -> ok;
                              {ok, Payload} -> ?assertEqual(Message, binary_to_term(Payload)),
                                               ?assert(well_formed(Message))
                          end
                  end, lists:seq(1, 20000)),
    ?assertEqual(drop, erx_hostlink_web:cast_of({erx_origin, 8, {web, 1, <<>>}}, 7)).

well_formed({web, C, Bytes}) -> C >= 0 andalso C < 1 bsl 32 andalso byte_size(Bytes) =< 65536;
well_formed({web_closed, C, Reason}) -> C >= 0 andalso C < 1 bsl 32 andalso is_atom(Reason).

%% The facet ends with the web domain's relay, whose end took its connections.
web_facet_ends_with_the_relay_test() ->
    Test = self(),
    Relay = spawn(fun() -> relay(Test) end),
    {{ok, Facet}, [Facet]} = open_web(Relay),
    Ref = erlang:monitor(process, Facet),
    exit(Relay, kill),
    receive {'DOWN', Ref, process, Facet, Reason} -> ?assertEqual(shutdown, Reason)
    after 5000 -> error(facet_outlived_its_relay)
    end.
