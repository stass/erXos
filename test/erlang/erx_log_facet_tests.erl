%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The kernel log facet's pure decisions (erlang/apps/erx/src/erx_log_facet.erl): which
%% builds hand a session the facet, the check of the system domain's answer, and the
%% read a domain pages the log with.
-module(erx_log_facet_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

%% Only a development build's manifest hands the facet, in front of the reader.
grant_test() ->
    Reader = self(),
    ?assertEqual(#{log => {Reader, #{}}}, erx_log_facet:grant(?ERX_MANIFEST_DEVELOPMENT, Reader)),
    ?assertEqual(#{log => {Reader, #{}}}, erx_log_facet:grant(?ERX_MANIFEST_DEVELOPMENT bor 16#100, Reader)),
    ?assertEqual(#{}, erx_log_facet:grant(0, Reader)),
    ?assertEqual(#{}, erx_log_facet:grant(16#100, Reader)),
    ?assertEqual(#{}, erx_log_facet:grant(unknown, Reader)).

%% A read's lines and a refusal pass as they are; any other shape fails the check.
answer_test() ->
    Read = {ok, 7, 2, [<<"#5 0.000001 one">>, <<>>]},
    ?assertEqual(Read, erx_log_facet:answer(Read)),
    ?assertEqual({corrupt, 3, 0, []}, erx_log_facet:answer({corrupt, 3, 0, []})),
    ?assertEqual({error, ?ERX_ENOTSUP}, erx_log_facet:answer({error, ?ERX_ENOTSUP})),
    Longest = binary:copy(<<"x">>, 65536),
    ?assertEqual({ok, 1, 0, [Longest]}, erx_log_facet:answer({ok, 1, 0, [Longest]})),
    Corrupt = {error, ?ERX_ECORRUPT},
    [?assertEqual(Corrupt, erx_log_facet:answer(Bad))
     || Bad <- [{ok, 1, 0, [<<Longest/binary, "x">>]},
                {ok, 1, 0, [line]},
                {ok, 1, 0, [<<"a">> | <<"b">>]},
                {ok, 1, 0, not_lines},
                {done, 1, 0, []},
                {ok, -1, 0, []},
                {ok, 1, -1, []},
                {ok, 16#10000000000000000, 0, []},
                {error, 0},
                {error, enotsup},
                {ok, 1, 0},
                badarg]].

%% Through a facet, the system domain's answer reaches the pager once checked; a facet
%% that is gone answers ERX_EDEAD; a domain with none reads its own log.
reader_test() ->
    Facet = spawn(fun() -> facet([{ok, 4, 1, [<<"#1 0.000002 a">>]}, {ok, 4, 0, [42]}]) end),
    Read = erx_log_facet:read_fun(Facet),
    ?assertEqual({ok, 4, 1, [<<"#1 0.000002 a">>]}, Read(0)),
    ?assertEqual({error, ?ERX_ECORRUPT}, Read(4)),
    ?assertEqual({error, ?ERX_EDEAD}, Read(4)),
    ?assertEqual(fun erx_log:read/1, erx_log_facet:read_fun(undefined)).

%% A facet stand-in that answers each read with the next of Answers, and ends after the
%% last.
facet([]) ->
    ok;
facet([Answer | Rest]) ->
    receive
        {'$gen_call', From, {read, Cursor}} when is_integer(Cursor) ->
            gen:reply(From, Answer),
            facet(Rest)
    end.

%% The reader answers a read of its own node's caller and refuses any other request,
%% and a plain message the facet forwards, so none holds a slot of the facet's.
reader_serves_test() ->
    Reader = erx_log_facet:start_reader(),
    ?assertEqual({error, ?ERX_EINVAL}, gen_server:call(Reader, {read, -1})),
    ?assertEqual({error, ?ERX_EINVAL}, gen_server:call(Reader, {write, 0})),
    Tag = make_ref(),
    Reader ! {'$erx_facet_message', {self(), Tag}, 8, hello},
    receive {Tag, Answer} -> ?assertEqual({error, badarg}, Answer) after 5000 -> ?assert(false) end,
    exit(Reader, kill).
