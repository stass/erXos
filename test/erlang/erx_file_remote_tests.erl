%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_file_remote's exchange with a server, sent/2 (docs/design-files.md,
%% Erlang clients), and of its two halves, send/2 and take/2, on stock's emulator. A process of the test plays the server, and the
%% connection as well: a reply from a server of another domain is one it puts in the
%% envelope of edit 16, {erx_origin, D, Reply}, itself. The client takes a reply at a
%% request's alias bare or in one envelope, whatever D, holds it to its request, and
%% answers eio for a request whose server ended before a reply of that shape came.
-module(erx_file_remote_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

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

%% The exchange's two halves, for a keeper that holds a read while it serves others
%% (docs/design-display.md, "Erlang clients"): send/2 answers a request's id at once, and
%% take/2 tells whether a message the caller received is that id's reply, held to its
%% request by the grammar, or its grant's end, which answers eio.
-define(READ, {read, 1, 0, 8}).

%% The earlier cases leave messages no take matched in the test's mailbox; each case
%% here starts from an empty one, and next/0 takes the first message to arrive, as a
%% keeper's receive loop takes it.
empty() ->
    receive _ -> empty() after 0 -> ok end.

next() ->
    receive Message -> Message after 1000 -> erlang:error(no_message) end.

sent_read(Answer) ->
    ok = empty(),
    {ok, Id} = erx_file_remote:send({server(1, Answer), <<"t">>, rw}, ?READ),
    Id.

sent_read_answers_eio_at_its_grants_end_test() ->
    Id = sent_read(fun(_Alias, 1) -> [] end),
    ?assertEqual({reply, {error, eio}}, erx_file_remote:take(next(), Id)).

sent_read_reply_is_held_to_its_request_test() ->
    Read = fun(Messages) ->
                   Id = sent_read(fun(Alias, 1) -> Messages(Alias) end),
                   erx_file_remote:take(next(), Id)
           end,
    ?assertEqual({reply, {ok, <<"k">>}}, Read(fun(Alias) -> [{erx_9p, Alias, {ok, <<"k">>}}] end)),
    ?assertEqual({reply, {ok, <<"k">>}}, Read(fun(Alias) -> [{erx_origin, ?SERVER, {erx_9p, Alias, {ok, <<"k">>}}}] end)),
    ?assertEqual({reply, {error, eio}}, Read(fun(Alias) -> [{erx_9p, Alias, ok}] end)),
    ?assertEqual({reply, {error, eio}}, Read(fun(Alias) -> [{erx_origin, ?SERVER, {erx_9p, Alias, {ok, 1}}}] end)).

%% A message not at the id's alias is not its reply; the grant's end met first still
%% leaves the reply that arrived before it to answer.
sent_read_takes_only_its_own_reply_test() ->
    Id = sent_read(fun(Alias, 1) -> [{erx_9p, make_ref(), {ok, <<"x">>}}, {erx_9p, Alias, {ok, <<"k">>}}] end),
    ?assertEqual(no_reply, erx_file_remote:take(next(), Id)),
    Down = receive {'DOWN', _, process, _, _} = Message -> Message after 1000 -> erlang:error(no_down) end,
    ?assertEqual({reply, {ok, <<"k">>}}, erx_file_remote:take(Down, Id)).

%% The send half refuses what exchange/2 refuses, before anything is sent: a write
%% through rights other than rw, and a walk naming ".", ".." or an empty name.
send_refuses_as_the_exchange_does_test() ->
    Server = server(1, fun(_Alias, 1) -> [] end),
    ?assertEqual({error, erofs}, erx_file_remote:send({Server, <<"t">>, ro}, {write, 1, 0, <<"k">>})),
    [?assertEqual({error, einval}, erx_file_remote:send({Server, <<"t">>, rw}, {walk, 1, 2, Names}))
     || Names <- [[<<"..">>], [<<".">>], [<<>>], [<<"d">>, <<"..">>]]],
    ?assertEqual(true, is_process_alive(Server)),
    exit(Server, kill).

%% A flush names the read's alias, and the two replies are each taken for their own id:
%% the read's with the record the server had already taken for it.
flush_names_the_sent_read_test() ->
    Server = spawn(fun() ->
                           {Read, Flush} = receive {erx_9p, A, _, ?READ} -> receive {erx_9p, F, _, {flush, A}} -> {A, F} end end,
                           Read ! {erx_9p, Read, {ok, <<"k">>}},
                           Flush ! {erx_9p, Flush, ok},
                           receive stop -> ok end
                   end),
    Grant = {Server, <<"t">>, rw},
    ok = empty(),
    {ok, Id} = erx_file_remote:send(Grant, ?READ),
    {ok, FlushId} = erx_file_remote:send_flush(Grant, Id),
    First = next(),
    Second = next(),
    ?assertEqual(no_reply, erx_file_remote:take(Second, Id)),
    ?assertEqual({reply, {ok, <<"k">>}}, erx_file_remote:take(First, Id)),
    ?assertEqual({reply, ok}, erx_file_remote:take(Second, FlushId)),
    Server ! stop.

%% A native program's open, open_flags/4, against a server of one tree: a directory d, a
%% file f and a link l at its root. Its walk stops at the first name that is not a
%% directory, its lopen refuses a link (eloop) and its lcreate meets the link at l
%% (eloop), as erx_fs_grant's do; a walk from NOFID starts at the root. The client's
%% fids come from the test's stand-in for prim_file:erx_fid/0.
-define(QDIR, {?ERX_P9_QTDIR, 0, 1}).
-define(QFILE, {0, 0, 2}).
-define(QLINK, {?ERX_P9_QTSYMLINK, 0, 3}).

tree_server() ->
    spawn(fun() -> tree_loop(#{?ERX_P9_NOFID => ?QDIR}) end).

tree_loop(Fids) ->
    receive
        {erx_9p, Alias, _Owner, Request} ->
            {Reply, Next} = tree_reply(Request, Fids),
            Alias ! {erx_9p, Alias, Reply},
            tree_loop(Next)
    end.

tree_reply({walk, From, New, Names}, Fids) ->
    Qids = walked(Names),
    {{ok, Qids}, Fids#{New => lists:last([maps:get(From, Fids) | Qids])}};
tree_reply({lopen, Fid, _}, Fids) ->
    case maps:get(Fid, Fids) of
        ?QLINK -> {{error, eloop}, Fids};
        Qid -> {{ok, Qid, 0}, Fids}
    end;
tree_reply({lcreate, _, <<"l">>, _, _, _}, Fids) ->
    {{error, eloop}, Fids};
tree_reply({lcreate, Fid, _, _, _, _}, Fids) ->
    {{ok, ?QFILE, 0}, Fids#{Fid => ?QFILE}};
tree_reply({clunk, Fid}, Fids) ->
    {ok, maps:remove(Fid, Fids)}.

walked([]) -> [];
walked([<<"d">> | Names]) -> [?QDIR | walked(Names)];
walked([<<"f">> | _]) -> [?QFILE];
walked([<<"l">> | _]) -> [?QLINK].

open(Where, Flags, Mode) ->
    erx_file_remote:open_flags({tree_server(), <<"t">>, rw}, Where, Flags, Mode).

%% O_NOFOLLOW: a link at the last name answers emlink, for an lopen and an lcreate, an
%% exclusive one eexist first; without it the link goes back to the resolver to follow,
%% and a link before the last name goes back under O_NOFOLLOW too.
nofollow_refuses_a_last_link_test_() ->
    NoFollow = ?ERX_P9_O_NOFOLLOW,
    [?_assertEqual({error, emlink}, open({target, [<<"l">>]}, NoFollow, none)),
     ?_assertEqual({error, emlink}, open({target, [<<"d">>, <<"l">>]}, NoFollow bor ?ERX_P9_O_DIRECTORY, none)),
     ?_assertEqual({error, emlink}, open({parent, [], <<"l">>}, NoFollow bor ?ERX_P9_O_WRONLY, 8#644)),
     ?_assertEqual({error, eexist}, open({parent, [], <<"l">>}, NoFollow bor ?ERX_P9_O_EXCL, 8#644)),
     ?_assertEqual({resume, 1, {[link], ok}}, open({target, [<<"l">>]}, 0, none)),
     ?_assertEqual({resume, 1, {[link], ok}}, open({parent, [], <<"l">>}, ?ERX_P9_O_WRONLY, 8#644)),
     ?_assertMatch({resume, 1, _}, open({target, [<<"l">>, <<"f">>]}, NoFollow, none)),
     ?_assertMatch({ok, _}, open({target, [<<"f">>]}, NoFollow, none))].

%% O_DIRECTORY opens a directory alone: anything else is enotdir.
directory_opens_only_a_directory_test_() ->
    [?_assertEqual({error, enotdir}, open({target, [<<"f">>]}, ?ERX_P9_O_DIRECTORY, none)),
     ?_assertMatch({ok, _}, open({target, [<<"d">>]}, ?ERX_P9_O_DIRECTORY, none)),
     ?_assertMatch({ok, _}, open({target, [<<"f">>]}, 0, none))].

%% Where a seek moves an offset, as FreeBSD's vn_seek moves a regular file's and stock
%% OTP answers on the development host: a sum past off_t is eoverflow, a negative one
%% einval.
seek_to_follows_freebsd_test_() ->
    Max = ?ERX_OFF_MAX,
    [?_assertEqual({ok, 15}, erx_file_remote:seek_to(10, 5)),
     ?_assertEqual({ok, 0}, erx_file_remote:seek_to(10, -10)),
     ?_assertEqual({error, einval}, erx_file_remote:seek_to(10, -11)),
     ?_assertEqual({error, einval}, erx_file_remote:seek_to(0, -Max - 1)),
     ?_assertEqual({ok, Max}, erx_file_remote:seek_to(Max - 1, 1)),
     ?_assertEqual({error, eoverflow}, erx_file_remote:seek_to(Max, 1)),
     ?_assertEqual({error, eoverflow}, erx_file_remote:seek_to(1, Max))].
