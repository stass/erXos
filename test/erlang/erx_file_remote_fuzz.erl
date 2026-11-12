%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_file_remote's request function (docs/design-files.md, Erlang
%% clients): batches of random walks of up to 20 names, drawn from plain names, ".",
%% "..", empty names and names that are not UTF-8 or hold "/" or NUL, among stats and
%% mkdirs, go through refused/2 under each set of rights. It must not raise and must
%% agree with a model that reads each request in order: a walk that names ".", ".." or
%% an empty name, or any name the grammar refuses, or more than ?ERX_P9_MAXWELEM names,
%% and a mkdir of such a name, are einval; a write through rights other than rw is erofs;
%% a batch with neither is sent (none).
%%
%% Then the reader of a server's walk replies, walk_reply/2 (Erlang clients, Errors):
%% random walks of up to 40 names, chunked as the client chunks them, each chunk
%% answered by a random term, well formed or not (short or long qid lists, qids of
%% every kind in any order, qids of the wrong shape, unknown errors, other terms), held
%% to its request by the grammar as the client holds it and followed by other requests'
%% replies. The reader must not raise, must answer a reply() whose every kind but the
%% last is a directory, and must agree with a model that reads the raw replies on its
%% own: a malformed reply, or a qid after one that is not a directory, ends the walk in
%% eio. passed/2 must agree with the model on the kinds it answers, under each mode, and
%% every outcome of ?OUTCOMES must be met, a walk read on into a later chunk included.
%%
%% Then the exchange with a server, sent/2: a server process answers each request with
%% random messages at its alias, bare and in other domains' envelopes (Exchanges, below),
%% and the client must take each request's reply as a model does.
%% The seed comes from make check-fuzz.

-module(erx_file_remote_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(BATCHES, 100000).
-define(WALKS, 100000).
%% erx_9p_grammar's errors: one it drops makes the model and the client disagree.
-define(ERRORS, [enoent, eacces, eperm, eexist, enotdir, eisdir, enotempty, erofs, enospc,
                 efbig, einval, ebadf, emfile, enfile, eio, enametoolong, enotsup, eloop,
                 enxio, exdev, enomem, eagain, enodata, erange, enolck, ebusy]).
-define(OUTCOMES, [ok, enoent, enotdir, server, malformed, past_a_file, later_chunk_ok,
                   later_chunk_stop]).
-define(EXCHANGES, 20000).
-define(EXCHANGE_OUTCOMES, [none, bare, enveloped, enveloped_rejected]).
-define(NAMES, [<<"a">>, <<"bc">>, <<".">>, <<"..">>, <<"...">>, <<>>, <<"a/b">>, <<"a", 0>>,
                <<255>>, <<".a">>, <<"a.">>, <<" ">>]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    loop(?BATCHES),
    io:format("fuzz: ~b batches ok~n", [?BATCHES]),
    walk_loop(?WALKS, #{}),
    io:format("fuzz: ~b walk replies ok~n", [?WALKS]),
    exchange_loop(?EXCHANGES, #{}),
    io:format("fuzz: ~b exchanges ok~n", [?EXCHANGES]).

loop(0) ->
    ok;
loop(Left) ->
    Batch = [request() || _ <- lists:seq(1, rand:uniform(3))],
    Rights = pick([ro, rw, rx]),
    Got = erx_file_remote:refused(Batch, Rights),
    case model(Batch, Rights) of
        Got -> ok;
        Want -> erlang:error({refused, Batch, Rights, Got, Want})
    end,
    loop(Left - 1).

request() ->
    case rand:uniform(3) of
        1 -> {walk, 1, 2, [pick(?NAMES) || _ <- lists:seq(1, rand:uniform(21) - 1)]};
        2 -> {getattr, 1, 16#3fff};
        3 -> {mkdir, 1, pick(?NAMES), 8#755, 0}
    end.

model([], _) ->
    none;
model([Request | Batch], Rights) ->
    case {valid(Request), writes(Request)} of
        {false, _} -> einval;
        {true, true} when Rights =/= rw -> erofs;
        {true, _} -> model(Batch, Rights)
    end.

valid({walk, _, _, Names}) -> length(Names) =< 16 andalso lists:all(fun plain/1, Names);
valid({getattr, _, _}) -> true;
valid({mkdir, _, Name, _, _}) -> plain(Name).

writes({mkdir, _, _, _, _}) -> true;
writes(_) -> false.

plain(Name) ->
    Name =/= <<>> andalso Name =/= <<".">> andalso Name =/= <<"..">> andalso
        binary:match(Name, [<<"/">>, <<0>>]) =:= nomatch andalso
        unicode:characters_to_binary(Name) =:= Name.

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).

%% Walk replies --------------------------------------------------------------

%% Each walk's outcome is counted, and a run that never met one of ?OUTCOMES fails, so
%% the generator cannot pass by missing a case.
walk_loop(0, Seen) ->
    case [Outcome || Outcome <- ?OUTCOMES, not maps:is_key(Outcome, Seen)] of
        [] -> ok;
        Missing -> erlang:error({outcomes_never_met, Missing, Seen})
    end;
walk_loop(Left, Seen) ->
    Chunks = chunks([<<"n">> || _ <- lists:seq(1, rand:uniform(41) - 1)]),
    Walks = [{walk, Fid, Fid + 1, Chunk} || {Fid, Chunk} <- lists:zip(lists:seq(1, length(Chunks)), Chunks)],
    Raw = [raw(length(Chunk)) || Chunk <- Chunks],
    Checked = [checked(Walk, Reply) || {Walk, Reply} <- lists:zip(Walks, Raw)],
    Others = [pick([ok, {error, eio}, {ok, []}]) || _ <- lists:seq(1, rand:uniform(3) - 1)],
    Got = try erx_file_remote:walk_reply(Walks, Checked ++ Others)
          catch Class:Reason -> erlang:error({raised, Walks, Raw, Class, Reason})
          end,
    {Want, Why} = walk_model(Chunks, Raw, []),
    case {Got, shaped(Got)} of
        {Want, true} -> ok;
        _ -> erlang:error({walk_reply, Walks, Raw, Got, Want})
    end,
    {Kinds, _} = Got,
    [erlang:error({passed, Kinds, Mode}) || Mode <- [follow, nofollow, directory],
                                            erx_file_remote:passed(Kinds, Mode) =/= passes(Kinds, Mode)],
    walk_loop(Left - 1, maps:update_with(Why, fun(Count) -> Count + 1 end, 1,
                                         maps:update_with(later(Want), fun(Count) -> Count + 1 end, 1, Seen))).

%% Whether the reading went past the first chunk and how it ended there.
later({Kinds, ok}) when length(Kinds) > ?ERX_P9_MAXWELEM -> later_chunk_ok;
later({Kinds, _}) when length(Kinds) >= ?ERX_P9_MAXWELEM -> later_chunk_stop;
later(_) -> first_chunk.

%% The client's chunks: ?ERX_P9_MAXWELEM names each, and one empty walk for no names.
chunks(Names) when length(Names) =< ?ERX_P9_MAXWELEM -> [Names];
chunks(Names) ->
    {First, Rest} = lists:split(?ERX_P9_MAXWELEM, Names),
    [First | chunks(Rest)].

%% A server's reply to a walk of Count names. Most are well formed, directories and then
%% a last qid of any kind, whole or short, so that a walk reaches its later chunks; the
%% rest are qids of any kind in any order, errors known and unknown, qids of the wrong
%% shape, lists of the wrong shape or length, and other terms.
raw(Count) ->
    case rand:uniform(12) of
        N when N =< 5 -> {ok, path(Count)};
        6 -> {ok, path(rand:uniform(Count + 1) - 1)};
        7 -> {ok, [qid() || _ <- lists:seq(1, Count)]};
        8 -> {ok, [qid() || _ <- lists:seq(1, Count + rand:uniform(2))]};
        9 -> {error, pick(?ERRORS ++ [enosuch, 5, <<"enoent">>])};
        10 -> {ok, [pick([qid(), {0, 0}, {-1, 0, 0}, {0, 1 bsl 32, 0}, {0, 0, 1 bsl 64}, qid])
                    || _ <- lists:seq(1, Count)]};
        11 -> {ok, [qid() | pick([qid, [qid()], {}])]};
        12 -> pick([ok, error, {ok}, {ok, [], extra}, [], <<>>, {error, eio, eio}, self()])
    end.

%% Count qids, every one a directory but the last, which is of any kind.
path(0) -> [];
path(Count) -> [directory() || _ <- lists:seq(1, Count - 1)] ++ [qid()].

directory() ->
    {pick([?ERX_P9_QTDIR, ?ERX_P9_QTDIR bor 1]), rand:uniform(16#ffffffff + 1) - 1, rand:uniform(1 bsl 64) - 1}.

qid() ->
    {pick([?ERX_P9_QTDIR, ?ERX_P9_QTDIR bor 1, ?ERX_P9_QTSYMLINK, 0, 1, 16#ff]),
     rand:uniform(16#ffffffff + 1) - 1, rand:uniform(1 bsl 64) - 1}.

%% As the client's exchange holds a reply to its request.
checked(Walk, Reply) ->
    case erx_9p_grammar:decode_reply(Walk, Reply) of
        {ok, Valid} -> Valid;
        {error, eio} -> {error, eio}
    end.

shaped({Kinds, End}) when is_list(Kinds) ->
    lists:all(fun(Kind) -> lists:member(Kind, [directory, link, other]) end, Kinds)
        andalso lists:all(fun(Kind) -> Kind =:= directory end, but_last(Kinds))
        andalso (End =:= ok orelse (is_tuple(End) andalso tuple_size(End) =:= 2
                                     andalso element(1, End) =:= error andalso is_atom(element(2, End))));
shaped(_) ->
    false.

%% The model reads each chunk's raw reply as 9P2000.L's walk(5) says a server answers:
%% one of the protocol's errors, or one qid for each name walked, at least one of a chunk
%% of names and at most one for each, every qid a directory but the last. A qid after one
%% that is not a directory is past_a_file and anything else malformed, both eio. It
%% answers the reply and why the reading ended.
walk_model([], _, Kinds) ->
    {{Kinds, ok}, ok};
walk_model([Chunk | Chunks], [Reply | Replies], Kinds) ->
    case read_reply(length(Chunk), Reply) of
        {error, Why} when Why =:= malformed; Why =:= past_a_file ->
            {{Kinds, {error, eio}}, Why};
        {error, Posix} ->
            {{Kinds, {error, Posix}}, server};
        {ok, Read} when length(Read) < length(Chunk) ->
            Stop = case lists:last(Read) of directory -> enoent; _ -> enotdir end,
            {{Kinds ++ Read, {error, Stop}}, Stop};
        {ok, Read} when Chunks =:= [] ->
            {{Kinds ++ Read, ok}, ok};
        {ok, Read} ->
            case lists:last(Read) of
                directory -> walk_model(Chunks, Replies, Kinds ++ Read);
                _ -> {{Kinds ++ Read, {error, enotdir}}, enotdir}
            end
    end.

read_reply(_, {error, Posix}) ->
    case lists:member(Posix, ?ERRORS) of
        true -> {error, Posix};
        false -> {error, malformed}
    end;
read_reply(Count, {ok, Qids}) when is_list(Qids), length(Qids) =< Count, (Count =:= 0 orelse Qids =/= []) ->
    case lists:all(fun valid_qid/1, Qids) of
        true ->
            Kinds = [qid_kind(Qid) || Qid <- Qids],
            case lists:all(fun(Kind) -> Kind =:= directory end, but_last(Kinds)) of
                true -> {ok, Kinds};
                false -> {error, past_a_file}
            end;
        false ->
            {error, malformed}
    end;
read_reply(_, _) ->
    {error, malformed}.

valid_qid({Type, Version, Path}) ->
    is_integer(Type) andalso Type >= 0 andalso Type =< 16#ff
        andalso is_integer(Version) andalso Version >= 0 andalso Version =< 16#ffffffff
        andalso is_integer(Path) andalso Path >= 0 andalso Path < 1 bsl 64;
valid_qid(_) ->
    false.

qid_kind({Type, _, _}) when Type band ?ERX_P9_QTDIR =/= 0 -> directory;
qid_kind({Type, _, _}) when Type band ?ERX_P9_QTSYMLINK =/= 0 -> link;
qid_kind(_) -> other.

%% passed/2 as the resolver reads kinds: every name before the last a directory, and
%% the last anything (nofollow), not a link (follow) or a directory (directory).
but_last([]) -> [];
but_last(Kinds) -> lists:droplast(Kinds).

passes([], _) -> true;
passes(Kinds, Mode) ->
    lists:all(fun(Kind) -> Kind =:= directory end, lists:droplast(Kinds))
        andalso case {Mode, lists:last(Kinds)} of
                    {nofollow, _} -> true;
                    {follow, Last} -> Last =/= link;
                    {directory, Last} -> Last =:= directory
                end.

%% Exchanges -----------------------------------------------------------------

%% Batches of up to three clunks through sent/2, each answered by a server process with
%% a random list of messages at its alias, then the server's end. Each message is a reply,
%% bare or in a random domain's envelope, at the request's alias or another, in two
%% envelopes, of another shape, or any term. The client must take, for each request, the
%% first message that is its reply bare or in one envelope, held to its request, and eio
%% when none came; every outcome of ?EXCHANGE_OUTCOMES must be met.
exchange_loop(0, Seen) ->
    case [Outcome || Outcome <- ?EXCHANGE_OUTCOMES, not maps:is_key(Outcome, Seen)] of
        [] -> ok;
        Missing -> erlang:error({exchange_outcomes_never_met, Missing, Seen})
    end;
exchange_loop(Left, Seen) ->
    Plans = [[message() || _ <- lists:seq(1, rand:uniform(5) - 1)] || _ <- lists:seq(1, rand:uniform(3))],
    Requests = [{clunk, Fid} || Fid <- lists:seq(1, length(Plans))],
    Got = erx_file_remote:sent(exchange_server(Plans), Requests),
    flush(),
    Want = [exchange_model(Plan) || Plan <- Plans],
    case Got of
        Want -> ok;
        _ -> erlang:error({sent, Plans, Got, Want})
    end,
    exchange_loop(Left - 1, lists:foldl(fun(Plan, Acc) -> Acc#{exchange_outcome(Plan) => true} end,
                                        Seen, Plans)).

%% A message of a plan, which the server makes into a term with the request's alias.
message() ->
    Reply = pick([ok, {error, enoent}, {error, eio}, {ok, 1}, {error, bogus}, junk]),
    pick([{bare, Reply}, {enveloped, pick([1, 5, 9]), Reply}, {other_alias, Reply},
          {enveloped_other_alias, Reply}, {twice, Reply}, other_shape, junk]).

exchange_server(Plans) ->
    spawn(fun() ->
                  Aliases = [receive {erx_9p, Alias, _, _} -> Alias end || _ <- Plans],
                  [[Alias ! term(Message, Alias) || Message <- Plan]
                   || {Alias, Plan} <- lists:zip(Aliases, Plans)]
          end).

term({bare, Reply}, Alias) -> {erx_9p, Alias, Reply};
term({enveloped, D, Reply}, Alias) -> {erx_origin, D, {erx_9p, Alias, Reply}};
term({other_alias, Reply}, _) -> {erx_9p, make_ref(), Reply};
term({enveloped_other_alias, Reply}, _) -> {erx_origin, 5, {erx_9p, make_ref(), Reply}};
term({twice, Reply}, Alias) -> {erx_origin, 5, {erx_origin, 9, {erx_9p, Alias, Reply}}};
term(other_shape, Alias) -> {erx_origin, 5, {erx_9p, Alias}};
term(junk, Alias) -> {Alias, junk}.

%% The first reply of the plan, bare or in one envelope, read as the grammar reads a
%% clunk's reply; eio when the plan holds none.
exchange_model(Plan) ->
    case [Reply || {Form, Reply} <- [taken(Message) || Message <- Plan], Form =:= reply] of
        [ok | _] -> ok;
        [{error, enoent} | _] -> {error, enoent};
        _ -> {error, eio}
    end.

taken({bare, Reply}) -> {reply, Reply};
taken({enveloped, _, Reply}) -> {reply, Reply};
taken(_) -> {none, none}.

exchange_outcome(Plan) ->
    case {[Message || Message <- Plan, element(1, taken(Message)) =:= reply], exchange_model(Plan)} of
        {[], _} -> none;
        {[{enveloped, _, _} | _], {error, eio}} -> enveloped_rejected;
        {[{enveloped, _, _} | _], _} -> enveloped;
        {[{bare, _} | _], _} -> bare
    end.

flush() ->
    receive _ -> flush() after 0 -> ok end.
