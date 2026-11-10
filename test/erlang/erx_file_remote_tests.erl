%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_file_remote's exchange with a server, sent/2 (docs/design-files.md,
%% Erlang clients), on stock's emulator. A process of the test plays the server, and the
%% connection as well: a reply from a server of another domain is one it puts in the
%% envelope of edit 16, {erx_origin, D, Reply}, itself. The client takes a reply at a
%% request's alias bare or in one envelope, whatever D, holds it to its request, and
%% answers eio for a request whose server ended before a reply of that shape came.
-module(erx_file_remote_tests).
-include_lib("eunit/include/eunit.hrl").

%% The server's domain and a third one.
-define(SERVER, 5).
-define(THIRD, 9).
-define(CLUNK, {clunk, 1}).

%% A server that takes each of Count requests, sends the messages Answer(Alias, Index)
%% makes, the Index'th request's, to its alias, and ends once it has answered them all,
%% so a request no message answered meets the server's end.
server(Count, Answer) ->
    spawn(fun() ->
                  Aliases = [receive {erx_9p, Alias, _Owner, _Request} -> Alias end || _ <- lists:seq(1, Count)],
                  [[Alias ! Message || Message <- Answer(Alias, Index)]
                   || {Index, Alias} <- lists:zip(lists:seq(1, Count), Aliases)]
          end).

%% The client's answer to one clunk that the server answers with Messages(Alias).
clunk(Messages) ->
    [Answer] = erx_file_remote:sent(server(1, fun(Alias, 1) -> Messages(Alias) end), [?CLUNK]),
    Answer.

bare_reply_of_a_server_of_this_domain_is_taken_test() ->
    ?assertEqual(ok, clunk(fun(Alias) -> [{erx_9p, Alias, ok}] end)).

%% The regression: a reply from a server of another domain arrives in its envelope.
reply_from_another_domain_is_taken_in_its_envelope_test() ->
    ?assertEqual(ok, clunk(fun(Alias) -> [{erx_origin, ?SERVER, {erx_9p, Alias, ok}}] end)),
    ?assertEqual({error, enoent},
                 clunk(fun(Alias) -> [{erx_origin, ?SERVER, {erx_9p, Alias, {error, enoent}}}] end)).

%% D is not checked, as gen checks no call reply's: the alias reached the server alone,
%% so a reply at it answers for the server, from whichever domain the server had it sent.
reply_at_the_alias_is_taken_from_any_domain_test() ->
    ?assertEqual(ok, clunk(fun(Alias) -> [{erx_origin, ?THIRD, {erx_9p, Alias, ok}}] end)).

%% A reply in its envelope is untrusted as a bare one is: the grammar holds it to its
%% request, and anything else is eio.
enveloped_reply_is_held_to_its_request_test() ->
    ?assertEqual({error, eio}, clunk(fun(Alias) -> [{erx_origin, ?SERVER, {erx_9p, Alias, {ok, 1}}}] end)),
    ?assertEqual({error, eio}, clunk(fun(Alias) -> [{erx_origin, ?SERVER, {erx_9p, Alias, {error, bogus}}}] end)).

%% What is not a reply at the request's alias in at most one envelope is never taken: a
%% reply at another alias, one in a second envelope, as a tuple a sender built to look like
%% the envelope arrives, and one of another shape. The server then ends, and the request
%% answers eio.
only_a_reply_at_the_alias_in_one_envelope_is_taken_test() ->
    [?assertEqual({error, eio}, clunk(Messages))
     || Messages <- [fun(_) -> [{erx_origin, ?SERVER, {erx_9p, make_ref(), ok}}] end,
                     fun(_) -> [{erx_9p, make_ref(), ok}] end,
                     fun(Alias) -> [{erx_origin, ?SERVER, {erx_origin, ?THIRD, {erx_9p, Alias, ok}}}] end,
                     fun(Alias) -> [{erx_origin, ?SERVER, {erx_9p, Alias, ok, ok}}] end,
                     fun(Alias) -> [{erx_origin, ?SERVER, {Alias, ok}}] end,
                     fun(_) -> [] end]].

%% A request's own reply is taken past the messages before it that are not one, and a
%% later reply at the same alias is left alone.
reply_is_found_past_other_messages_test() ->
    ?assertEqual({error, enoent},
                 clunk(fun(Alias) -> [{erx_origin, ?SERVER, {erx_origin, ?SERVER, {erx_9p, Alias, ok}}},
                                      {erx_origin, ?SERVER, {erx_9p, make_ref(), ok}},
                                      {erx_origin, ?SERVER, {erx_9p, Alias, {error, enoent}}},
                                      {erx_origin, ?SERVER, {erx_9p, Alias, ok}}] end)).

%% Pipelined requests each take their own reply, whichever form it comes in.
pipelined_replies_meet_their_requests_test() ->
    Server = server(3, fun(Alias, 1) -> [{erx_origin, ?SERVER, {erx_9p, Alias, {error, enoent}}}];
                          (Alias, 2) -> [{erx_9p, Alias, ok}];
                          (_Alias, 3) -> []
                       end),
    ?assertEqual([{error, enoent}, ok, {error, eio}], erx_file_remote:sent(Server, [?CLUNK, ?CLUNK, ?CLUNK])).
