%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Arbitrary bytes through erx_9p, the codec of the file protocol's 9P2000.L bytes:
%% random bytes, valid messages with bytes flipped, inserted, dropped or cut, a size
%% field rewritten, and valid messages under an msize just below their size. Whatever
%% arrives, decoding returns and never raises, and its answer agrees with what the
%% header alone says: a size field past msize is refused as msize, one that is not the
%% number of bytes as size, and a message malformed past its header keeps its tag. A message it accepts encodes back to the same bytes (but an
%% Rlerror whose number names no error of the table, which reads as eio), decodes the
%% same again, and is a term erx_9p_grammar accepts: its request decoder for a request,
%% its builder for a reply. The seed comes from make check-fuzz.

-module(erx_9p_fuzz).
-export([run/1]).

-define(C, erx_9p).
-define(G, erx_9p_grammar).
-define(ROUNDS, 20000).
-define(MSIZE, 65560).

run([Seed]) ->
    rand:seed(exsss, {9, 2000, list_to_integer(Seed)}),
    Corpus = corpus(),
    lists:foreach(fun(_) ->
                          Valid = pick(Corpus),
                          round(random_bytes(), ?MSIZE),
                          round(mutated(Valid), ?MSIZE),
                          %% An msize from 7 to one below the message, which must refuse it.
                          round(Valid, 6 + rand:uniform(max(1, byte_size(Valid) - 7))),
                          round(Valid, max(7, byte_size(Valid) + rand:uniform(64) - 32))
                  end, lists:seq(1, ?ROUNDS)),
    io:format("fuzz: ~p rounds ok~n", [?ROUNDS]).

round(Bytes, Msize) ->
    Result = try ?C:decode(Bytes, Msize)
             catch Class:Reason -> error({decode_raised, Bytes, Msize, Class, Reason})
             end,
    case {header(Bytes, Msize), Result} of
        {msize, {error, msize}} -> ok;
        {msize, _} -> error({oversized_accepted, Bytes, Msize, Result});
        {size, {error, size}} -> ok;
        {size, _} -> error({size_disagrees, Bytes, Msize, Result});
        {{fits, Tag}, {error, {malformed, Tag}}} -> ok;
        {{fits, Tag}, {ok, Tag, Message}} -> accepted(Bytes, Tag, Message);
        {{fits, _}, _} -> error({unexpected_decode, Bytes, Msize, Result})
    end.

%% What 9P2000.L's header alone says of Bytes, read without the codec.
header(<<Size:32/little, _/binary>>, Msize) when Size > Msize -> msize;
header(<<Size:32/little, _:8, Tag:16/little, _/binary>> = Bytes, _) when Size =:= byte_size(Bytes) ->
    {fits, Tag};
header(_, _) -> size.

accepted(Bytes, Tag, Message) ->
    Encoded = ?C:encode(Tag, Message),
    case Encoded =:= Bytes orelse unknown_error_number(Bytes) of
        true -> ok;
        false -> error({encodes_differently, Bytes, Encoded})
    end,
    {ok, Tag, Message} = ?C:decode(Encoded, ?MSIZE),
    grammar_accepts(Message).

unknown_error_number(<<_:32, 7, _:16, _/binary>> = Bytes) ->
    case ?C:decode(Bytes, ?MSIZE) of
        {ok, _, {reply, error, {error, eio}}} -> true;
        _ -> false
    end;
unknown_error_number(_) ->
    false.

grammar_accepts({reply, error, {error, Posix} = Reply}) ->
    Reply = ?G:error_reply(Posix);
grammar_accepts({reply, Op, Reply}) ->
    Fields = case Reply of
                 ok -> [];
                 _ -> tl(tuple_to_list(Reply))
             end,
    Builder = list_to_existing_atom(atom_to_list(Op) ++ "_reply"),
    Reply = apply(?G, Builder, Fields);
grammar_accepts({flush, OldTag}) ->
    true = is_integer(OldTag) andalso OldTag >= 0 andalso OldTag =< 16#ffff;
grammar_accepts(Request) ->
    {ok, Request} = ?G:decode_request(Request).

%% Valid messages of every operation, requests and replies, encoded by the codec from
%% terms the grammar's builders make.
corpus() ->
    Qid = {16#80, 1, 2},
    Attr = #{valid => 1, mode => 8#644, uid => 0, gid => 0, size => 0, atime_sec => 0,
             atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0},
    Full = #{valid => 16#3fff, qid => Qid, mode => 8#40755, uid => 0, gid => 0, nlink => 2,
             rdev => 0, size => 0, blksize => 4096, blocks => 0, atime_sec => 0,
             atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0, ctime_sec => 0,
             ctime_nsec => 0, btime_sec => 0, btime_nsec => 0, gen => 0, data_version => 1},
    Statfs = #{type => 1, bsize => 512, blocks => 1, bfree => 1, bavail => 1, files => 1,
               ffree => 1, fsid => 1, namelen => 255},
    Requests = [?G:statfs_request(1), ?G:lopen_request(1, 2),
                ?G:lcreate_request(1, <<"f">>, 16#42, 8#644, 0),
                ?G:symlink_request(1, <<"l">>, <<"t">>, 0),
                ?G:mknod_request(1, <<"n">>, 8#20644, 1, 3, 0), ?G:readlink_request(1),
                ?G:getattr_request(1, 16#7ff), ?G:setattr_request(1, Attr),
                ?G:xattrwalk_request(1, 2, <<"user.a">>),
                ?G:xattrcreate_request(1, <<"user.a">>, 3, 0), ?G:readdir_request(1, 0, 4096),
                ?G:fsync_request(1, 0), ?G:lock_request(1, 1, 0, 0, 0, 7, <<"host">>),
                ?G:getlock_request(1, 0, 0, 10, 7, <<"host">>), ?G:link_request(1, 2, <<"h">>),
                ?G:mkdir_request(1, <<"d">>, 8#755, 0),
                ?G:renameat_request(1, <<"a">>, 2, <<"b">>), ?G:unlinkat_request(1, <<"a">>, 512),
                ?G:version_request(65560, <<"9P2000.L">>),
                ?G:auth_request(16#ffffffff, <<"u">>, <<"a">>, 0),
                ?G:attach_request(0, 16#ffffffff, <<"u">>, <<>>, 0), {flush, 9},
                ?G:walk_request(0, 1, [<<"..">>, <<"a">>, <<"b">>]), ?G:read_request(1, 0, 3),
                ?G:write_request(1, 0, <<"abc">>), ?G:clunk_request(1), ?G:remove_request(1)],
    Replies = [{statfs, ?G:statfs_reply(Statfs)}, {lopen, ?G:lopen_reply(Qid, 0)},
               {mknod, ?G:mknod_reply(Qid)}, {readlink, ?G:readlink_reply(<<"/a">>)},
               {getattr, ?G:getattr_reply(Full)}, {setattr, ?G:setattr_reply()},
               {xattrwalk, ?G:xattrwalk_reply(3)},
               {readdir, ?G:readdir_reply([{Qid, 1, 4, <<".">>}, {Qid, 2, 4, <<"xy">>}])},
               {lock, ?G:lock_reply(0)}, {getlock, ?G:getlock_reply(2, 0, 10, 7, <<"h">>)},
               {version, ?G:version_reply(8192, <<"9P2000.L">>)},
               {walk, ?G:walk_reply([Qid, Qid])}, {read, ?G:read_reply(<<"abc">>)},
               {write, ?G:write_reply(3, unknown)}, {clunk, ?G:clunk_reply()},
               {walk, ?G:error_reply(enoent)}],
    [?C:encode(rand:uniform(16#10000) - 1, Request) || Request <- Requests] ++
        [?C:encode(rand:uniform(16#10000) - 1, {reply, Op, Reply}) || {Op, Reply} <- Replies].

random_bytes() ->
    case rand:uniform(3) of
        1 -> rand:bytes(rand:uniform(64) - 1);
        %% A right size field and a known type, so the fields are what is tried.
        _ ->
            Body = rand:bytes(rand:uniform(48) - 1),
            Type = pick([7, 8, 13, 25, 41, 100, 101, 110, 111, 117, 118, 119]),
            <<(7 + byte_size(Body)):32/little, Type, (rand:uniform(16#10000) - 1):16/little,
              Body/binary>>
    end.

mutated(Bytes) ->
    Size = byte_size(Bytes),
    At = rand:uniform(Size) - 1,
    <<Head:At/binary, Byte, Tail/binary>> = Bytes,
    case rand:uniform(6) of
        1 -> <<Head/binary, (Byte bxor (1 bsl (rand:uniform(8) - 1))), Tail/binary>>;
        2 -> <<Head/binary, (rand:uniform(256) - 1), Tail/binary>>;
        3 -> <<Head/binary, Tail/binary>>;
        4 -> <<Head/binary, (rand:uniform(256) - 1), Byte, Tail/binary>>;
        5 -> binary:part(Bytes, 0, At);
        %% The size field made to fit the bytes after a change of a length inside.
        6 ->
            <<_:32, Rest/binary>> = <<Head/binary, (rand:uniform(256) - 1), Tail/binary>>,
            Changed = <<Rest/binary, (rand:bytes(rand:uniform(4) - 1))/binary>>,
            <<(4 + byte_size(Changed)):32/little, Changed/binary>>
    end.

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
