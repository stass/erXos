%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_9p, the generated 9P2000.L codec (docs/design-files.md#the-codec).
%% The byte vectors are written from 9P2000.L's message layouts (Linux's
%% Documentation/filesystems/9p.rst and the diod protocol description: size[4] type[1]
%% tag[2], then each field little-endian, a string as len[2] and its bytes, a qid as
%% type[1] version[4] path[8]), never produced by the codec. Every operation of the
%% table round-trips, term to bytes and back, through terms erx_9p_grammar's builders
%% make; a size past msize or the bytes received, a string or count past what remains,
%% and a field its kind refuses are each refused.

-module(erx_9p_tests).
-include_lib("eunit/include/eunit.hrl").

-define(C, erx_9p).
-define(G, erx_9p_grammar).
-define(MSIZE, 65560).
-define(NOTAG, 16#ffff).
-define(NOFID, 16#ffffffff).

%% Encoding Term gives exactly Bytes, and decoding Bytes gives back Term.
vector(Tag, Term, Bytes) ->
    ?assertEqual(Bytes, ?C:encode(Tag, Term)),
    ?assertEqual({ok, Tag, Term}, ?C:decode(Bytes, ?MSIZE)).

version_test() ->
    Bytes = <<21, 0, 0, 0, 100, 16#ff, 16#ff, 0, 16#20, 0, 0, 8, 0, "9P2000.L">>,
    vector(?NOTAG, {version, 8192, <<"9P2000.L">>}, Bytes),
    Reply = <<21, 0, 0, 0, 101, 16#ff, 16#ff, 0, 16#20, 0, 0, 8, 0, "9P2000.L">>,
    vector(?NOTAG, {reply, version, {ok, 8192, <<"9P2000.L">>}}, Reply).

attach_test() ->
    Bytes = <<27, 0, 0, 0, 104, 1, 0, 0, 0, 0, 0, 16#ff, 16#ff, 16#ff, 16#ff,
              4, 0, "root", 0, 0, 0, 0, 0, 0>>,
    vector(1, {attach, 0, ?NOFID, <<"root">>, <<>>, 0}, Bytes),
    Reply = <<20, 0, 0, 0, 105, 1, 0, 16#80, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0>>,
    vector(1, {reply, attach, {ok, {16#80, 0, 1}}}, Reply).

walk_test() ->
    Bytes = <<27, 0, 0, 0, 110, 2, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0,
              3, 0, "usr", 3, 0, "bin">>,
    vector(2, {walk, 0, 1, [<<"usr">>, <<"bin">>]}, Bytes),
    Reply = <<35, 0, 0, 0, 111, 2, 0, 2, 0,
              16#80, 7, 0, 0, 0, 16#10, 0, 0, 0, 0, 0, 0, 0,
              16#80, 8, 0, 0, 0, 16#11, 0, 0, 0, 0, 0, 0, 0>>,
    vector(2, {reply, walk, {ok, [{16#80, 7, 16#10}, {16#80, 8, 16#11}]}}, Reply),
    vector(3, {walk, 4, 4, []}, <<17, 0, 0, 0, 110, 3, 0, 4, 0, 0, 0, 4, 0, 0, 0, 0, 0>>),
    vector(3, {reply, walk, {ok, []}}, <<9, 0, 0, 0, 111, 3, 0, 0, 0>>).

lopen_test() ->
    vector(5, {lopen, 1, 16#8002}, <<15, 0, 0, 0, 12, 5, 0, 1, 0, 0, 0, 2, 16#80, 0, 0>>),
    Reply = <<24, 0, 0, 0, 13, 5, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0,
              0, 16#10, 0, 0>>,
    vector(5, {reply, lopen, {ok, {0, 1, 2}, 4096}}, Reply).

read_test() ->
    vector(6, {read, 1, 16#0102030405060708, 4096},
           <<23, 0, 0, 0, 116, 6, 0, 1, 0, 0, 0, 8, 7, 6, 5, 4, 3, 2, 1, 0, 16#10, 0, 0>>),
    vector(6, {reply, read, {ok, <<"hello">>}},
           <<16, 0, 0, 0, 117, 6, 0, 5, 0, 0, 0, "hello">>).

%% Rwrite carries only the count: At is dropped on the way out and reads as unknown.
write_test() ->
    vector(7, {write, 1, 10, <<"abc">>},
           <<26, 0, 0, 0, 118, 7, 0, 1, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, "abc">>),
    Reply = <<11, 0, 0, 0, 119, 7, 0, 3, 0, 0, 0>>,
    vector(7, {reply, write, {ok, 3, unknown}}, Reply),
    ?assertEqual(Reply, ?C:encode(7, {reply, write, {ok, 3, 13}})).

readdir_test() ->
    vector(8, {readdir, 1, 0, 8168},
           <<23, 0, 0, 0, 40, 8, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16#e8, 16#1f, 0, 0>>),
    %% "." then "..", each qid[13] offset[8] type[1] name[s]: 25 and 26 bytes.
    Entries = <<16#80, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4,
                1, 0, ".",
                16#80, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 4,
                2, 0, "..">>,
    51 = byte_size(Entries),
    vector(8, {reply, readdir, {ok, [{{16#80, 0, 1}, 1, 4, <<".">>}, {{16#80, 0, 2}, 2, 4, <<"..">>}]}},
           <<62, 0, 0, 0, 41, 8, 0, 51, 0, 0, 0, Entries/binary>>),
    vector(8, {reply, readdir, {ok, []}}, <<11, 0, 0, 0, 41, 8, 0, 0, 0, 0, 0>>).

getattr_test() ->
    vector(9, {getattr, 1, 16#3fff},
           <<19, 0, 0, 0, 24, 9, 0, 1, 0, 0, 0, 16#ff, 16#3f, 0, 0, 0, 0, 0, 0>>),
    Attr = #{valid => 16#7ff, qid => {0, 3, 42}, mode => 8#100644, uid => 1000, gid => 100,
             nlink => 1, rdev => 0, size => 5, blksize => 4096, blocks => 8,
             atime_sec => 1, atime_nsec => 2, mtime_sec => 3, mtime_nsec => 4,
             ctime_sec => 5, ctime_nsec => 6, btime_sec => 0, btime_nsec => 0,
             gen => 0, data_version => 9},
    Fields = <<16#7ff:64/little, 0, 3:32/little, 42:64/little, 8#100644:32/little,
               1000:32/little, 100:32/little, 1:64/little, 0:64/little, 5:64/little,
               4096:64/little, 8:64/little, 1:64/little, 2:64/little, 3:64/little,
               4:64/little, 5:64/little, 6:64/little, 0:64/little, 0:64/little,
               0:64/little, 9:64/little>>,
    153 = byte_size(Fields),
    vector(9, {reply, getattr, {ok, Attr}}, <<160, 0, 0, 0, 25, 9, 0, Fields/binary>>).

setattr_test() ->
    Attr = #{valid => 16#9, mode => 8#644, uid => 0, gid => 0, size => 100,
             atime_sec => 0, atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0},
    Fields = <<1:32/little, 16#9:32/little, 8#644:32/little, 0:32/little, 0:32/little,
               100:64/little, 0:64/little, 0:64/little, 0:64/little, 0:64/little>>,
    vector(10, {setattr, 1, Attr}, <<(7 + 60):32/little, 26, 10, 0, Fields/binary>>),
    vector(10, {reply, setattr, ok}, <<7, 0, 0, 0, 27, 10, 0>>).

statfs_test() ->
    vector(11, {statfs, 0}, <<11, 0, 0, 0, 8, 11, 0, 0, 0, 0, 0>>),
    Statfs = #{type => 16#01021997, bsize => 4096, blocks => 10, bfree => 5, bavail => 4,
               files => 100, ffree => 50, fsid => 7, namelen => 255},
    Fields = <<16#01021997:32/little, 4096:32/little, 10:64/little, 5:64/little,
               4:64/little, 100:64/little, 50:64/little, 7:64/little, 255:32/little>>,
    vector(11, {reply, statfs, {ok, Statfs}}, <<(7 + 60):32/little, 9, 11, 0, Fields/binary>>).

directory_test() ->
    vector(12, {mkdir, 1, <<"d">>, 8#755, 0},
           <<22, 0, 0, 0, 72, 12, 0, 1, 0, 0, 0, 1, 0, "d", 16#ed, 1, 0, 0, 0, 0, 0, 0>>),
    vector(12, {unlinkat, 1, <<"d">>, 16#200},
           <<18, 0, 0, 0, 76, 12, 0, 1, 0, 0, 0, 1, 0, "d", 0, 2, 0, 0>>),
    vector(12, {renameat, 1, <<"a">>, 2, <<"b">>},
           <<21, 0, 0, 0, 74, 12, 0, 1, 0, 0, 0, 1, 0, "a", 2, 0, 0, 0, 1, 0, "b">>),
    vector(12, {symlink, 1, <<"l">>, <<"../t">>, 0},
           <<24, 0, 0, 0, 16, 12, 0, 1, 0, 0, 0, 1, 0, "l", 4, 0, "../t", 0, 0, 0, 0>>).

flush_and_clunk_test() ->
    %% Tflush carries the tag it flushes, which the bridge maps to an alias.
    vector(13, {flush, 5}, <<9, 0, 0, 0, 108, 13, 0, 5, 0>>),
    vector(13, {reply, flush, ok}, <<7, 0, 0, 0, 109, 13, 0>>),
    vector(14, {clunk, 3}, <<11, 0, 0, 0, 120, 14, 0, 3, 0, 0, 0>>),
    vector(14, {reply, clunk, ok}, <<7, 0, 0, 0, 121, 14, 0>>).

%% Linux's numbers, from asm-generic/errno-base.h and errno.h, which AArch64 and x86-64
%% share; ENOTSUP is EOPNOTSUPP.
linux_errors() ->
    [{eperm, 1}, {enoent, 2}, {eio, 5}, {enxio, 6}, {ebadf, 9}, {eagain, 11},
     {enomem, 12}, {eacces, 13}, {eexist, 17}, {exdev, 18}, {enotdir, 20}, {eisdir, 21},
     {einval, 22}, {enfile, 23}, {emfile, 24}, {efbig, 27}, {enospc, 28}, {erofs, 30},
     {erange, 34}, {enametoolong, 36}, {enolck, 37}, {enotempty, 39}, {eloop, 40},
     {enodata, 61}, {enotsup, 95}].

lerror_test() ->
    lists:foreach(fun({Posix, Number}) ->
                          Bytes = <<11, 0, 0, 0, 7, 15, 0, Number:32/little>>,
                          vector(15, {reply, error, {error, Posix}}, Bytes),
                          ?assertEqual(Bytes, ?C:encode(15, {reply, walk, {error, Posix}}))
                  end, linux_errors()),
    %% Every error the grammar names has a number, and no other atom does.
    Grammar = [element(2, ?G:error_reply(Posix)) || {Posix, _} <- linux_errors()],
    ?assertEqual(length(linux_errors()), length(lists:usort(Grammar))),
    ?assertError(badarg, ?C:encode(15, {reply, walk, {error, enotty}})),
    ?assertError(badarg, ?C:encode(15, {reply, frobnicate, {error, enoent}})).

%% A number of no error of the table, ENOTTY or Darwin's ENOTSUP (45, Linux's EL2NSYNC),
%% reads as eio (docs/design-files.md#errors).
lerror_outside_the_table_test() ->
    lists:foreach(fun(Number) ->
                          ?assertEqual({ok, 1, {reply, error, {error, eio}}},
                                       ?C:decode(<<11, 0, 0, 0, 7, 1, 0, Number:32/little>>, ?MSIZE))
                  end, [0, 25, 45, 16#ffffffff]).

%% One request and one reply of every operation of the table, made by the grammar's
%% builders, so each is a term the grammar accepts.
samples() ->
    Qid = {16#80, 1, 2},
    Attr = #{valid => 1, mode => 8#644, uid => 0, gid => 0, size => 0, atime_sec => 0,
             atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0},
    Full = #{valid => 16#3fff, qid => Qid, mode => 8#40755, uid => 0, gid => 0, nlink => 2,
             rdev => 0, size => 0, blksize => 4096, blocks => 0, atime_sec => 0,
             atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0, ctime_sec => 0,
             ctime_nsec => 0, btime_sec => 0, btime_nsec => 0, gen => 0, data_version => 1},
    Statfs = #{type => 1, bsize => 512, blocks => 1, bfree => 1, bavail => 1, files => 1,
               ffree => 1, fsid => 1, namelen => 255},
    [{?G:statfs_request(1), ?G:statfs_reply(Statfs)},
     {?G:lopen_request(1, 2), ?G:lopen_reply(Qid, 0)},
     {?G:lcreate_request(1, <<"f">>, 16#42, 8#644, 0), ?G:lcreate_reply(Qid, 8192)},
     {?G:symlink_request(1, <<"l">>, <<"t">>, 0), ?G:symlink_reply(Qid)},
     {?G:mknod_request(1, <<"n">>, 8#20644, 1, 3, 0), ?G:mknod_reply(Qid)},
     {?G:readlink_request(1), ?G:readlink_reply(<<"/a/b">>)},
     {?G:getattr_request(1, 16#7ff), ?G:getattr_reply(Full)},
     {?G:setattr_request(1, Attr), ?G:setattr_reply()},
     {?G:xattrwalk_request(1, 2, <<"user.a">>), ?G:xattrwalk_reply(3)},
     {?G:xattrcreate_request(1, <<"user.a">>, 3, 0), ?G:xattrcreate_reply()},
     {?G:readdir_request(1, 0, 4096), ?G:readdir_reply([{Qid, 1, 4, <<"x">>}])},
     {?G:fsync_request(1, 0), ?G:fsync_reply()},
     {?G:lock_request(1, 1, 0, 0, 0, 7, <<"host">>), ?G:lock_reply(0)},
     {?G:getlock_request(1, 0, 0, 10, 7, <<"host">>), ?G:getlock_reply(2, 0, 10, 7, <<"host">>)},
     {?G:link_request(1, 2, <<"h">>), ?G:link_reply()},
     {?G:mkdir_request(1, <<"d">>, 8#755, 0), ?G:mkdir_reply(Qid)},
     {?G:renameat_request(1, <<"a">>, 2, <<"b">>), ?G:renameat_reply()},
     {?G:unlinkat_request(1, <<"a">>, 0), ?G:unlinkat_reply()},
     {?G:version_request(65560, <<"9P2000.L">>), ?G:version_reply(65560, <<"9P2000.L">>)},
     {?G:auth_request(?NOFID, <<"u">>, <<"a">>, 0), ?G:error_reply(enotsup)},
     {?G:attach_request(0, ?NOFID, <<"u">>, <<"">>, 0), ?G:attach_reply(Qid)},
     {{flush, 9}, ?G:flush_reply()},
     {?G:walk_request(0, 1, [<<"..">>, <<"a">>]), ?G:walk_reply([Qid, Qid])},
     {?G:read_request(1, 0, 3), ?G:read_reply(<<"abc">>)},
     {?G:write_request(1, 0, <<"abc">>), ?G:write_reply(3, unknown)},
     {?G:clunk_request(1), ?G:clunk_reply()},
     {?G:remove_request(1), ?G:remove_reply()}].

every_operation_round_trips_test() ->
    Operations = [element(1, Request) || {Request, _} <- samples()],
    ?assertEqual(lists:sort(?G:operations()), lists:sort(Operations)),
    lists:foreach(fun({Request, Reply}) ->
                          Op = element(1, Request),
                          ?assertEqual({ok, 1, Request}, ?C:decode(?C:encode(1, Request), ?MSIZE)),
                          Decoded = case Reply of
                                        {error, _} -> {reply, error, Reply};
                                        _ -> {reply, Op, Reply}
                                    end,
                          ?assertEqual({ok, 2, Decoded},
                                       ?C:decode(?C:encode(2, {reply, Op, Reply}), ?MSIZE))
                  end, samples()).

%% The codec's request terms are the grammar's, but flush's tag, which is a u16 on the
%% wire and an alias inside the machine.
decoded_requests_pass_the_grammar_test() ->
    lists:foreach(fun({{flush, _}, _}) ->
                          ok;
                     ({Request, _}) ->
                          {ok, 1, Decoded} = ?C:decode(?C:encode(1, Request), ?MSIZE),
                          ?assertEqual({ok, Decoded}, ?G:decode_request(Decoded))
                  end, samples()).

size_past_msize_test() ->
    Bytes = <<21, 0, 0, 0, 100, 16#ff, 16#ff, 0, 16#20, 0, 0, 8, 0, "9P2000.L">>,
    ?assertEqual({error, msize}, ?C:decode(Bytes, 20)),
    ?assertMatch({ok, _, _}, ?C:decode(Bytes, 21)),
    %% A size field past msize is refused before the bytes are looked at.
    ?assertEqual({error, msize}, ?C:decode(<<16#ffffffff:32/little, 100>>, ?MSIZE)).

size_past_bytes_received_test() ->
    Bytes = <<11, 0, 0, 0, 120, 1, 0, 3, 0, 0, 0>>,
    ?assertEqual({error, size}, ?C:decode(binary:part(Bytes, 0, 10), ?MSIZE)),
    ?assertEqual({error, size}, ?C:decode(<<Bytes/binary, 0>>, ?MSIZE)),
    ?assertEqual({error, size}, ?C:decode(<<12, 0, 0, 0, 120, 1, 0, 3, 0, 0, 0>>, ?MSIZE)),
    ?assertEqual({error, size}, ?C:decode(<<6, 0, 0, 0, 120, 1>>, ?MSIZE)),
    ?assertEqual({error, size}, ?C:decode(<<>>, ?MSIZE)),
    ?assertEqual({error, size}, ?C:decode(<<7, 0, 0>>, ?MSIZE)).

%% A message of Type and Tag with Body, its size field right, so that only Body can
%% make it malformed.
message(Type, Body) ->
    <<(7 + byte_size(Body)):32/little, Type, 1:16/little, Body/binary>>.

malformed_test() ->
    Walk = fun(Names) -> <<0:32, 1:32/little, Names/binary>> end,
    Refused = [%% A string that runs past its message.
               message(110, Walk(<<1:16/little, 200:16/little>>)),
               %% A walk that counts three names and holds two.
               message(110, Walk(<<3:16/little, 3:16/little, "usr", 3:16/little, "bin">>)),
               %% A read reply's count past what remains.
               message(117, <<100:32/little, "hello">>),
               %% Bytes left over after the last field.
               message(120, <<3:32/little, 0>>),
               %% Seventeen names, past the walk's bound.
               message(110, Walk(<<17:16/little, (binary:copy(<<1:16/little, "a">>, 17))/binary>>)),
               %% A name past its kind's 255 bytes.
               message(110, Walk(<<1:16/little, 256:16/little, (binary:copy(<<"a">>, 256))/binary>>)),
               %% NOFID as a fid.
               message(120, <<16#ffffffff:32/little>>),
               %% Names their kinds refuse: invalid UTF-8, a slash, "." in a walk, an
               %% empty name and NUL in mkdir.
               message(110, Walk(<<1:16/little, 1:16/little, 16#ff>>)),
               message(110, Walk(<<1:16/little, 3:16/little, "a/b">>)),
               message(110, Walk(<<1:16/little, 1:16/little, ".">>)),
               message(72, <<1:32/little, 0:16, 8#755:32/little, 0:32>>),
               message(72, <<1:32/little, 1:16/little, 0, 8#755:32/little, 0:32>>),
               %% unlinkat's flags other than 0 or AT_REMOVEDIR.
               message(76, <<1:32/little, 1:16/little, "d", 1:32/little>>),
               %% A read's count past p9_io_max.
               message(116, <<1:32/little, 0:64, 16#10001:32/little>>),
               %% A readdir reply whose entries end inside an entry.
               message(41, <<9:32/little, 16#80, 0:32, 1:32/little>>),
               %% Tlerror, Trename (not in the table) and Rauth (auth is refused).
               message(6, <<2:32/little>>),
               message(20, <<1:32/little, 2:32/little, 1:16/little, "a">>),
               message(103, <<0, 0:32, 0:64>>),
               %% Rlerror without its number, and with a short one.
               message(7, <<>>),
               message(7, <<2, 0>>)],
    lists:foreach(fun(Bytes) -> ?assertEqual({error, {malformed, 1}}, ?C:decode(Bytes, ?MSIZE)) end,
                  Refused).

decoding_makes_no_atom_test() ->
    Before = erlang:system_info(atom_count),
    lists:foreach(fun(Name) ->
                          Size = 17 + 2 + byte_size(Name),
                          ?C:decode(<<Size:32/little, 110, 1:16/little, 0:32, 1:32/little, 1:16/little,
                                      (byte_size(Name)):16/little, Name/binary>>, ?MSIZE)
                  end, [<<"never_an_atom_", (integer_to_binary(N))/binary>> || N <- lists:seq(1, 50)]),
    ?assertEqual(Before, erlang:system_info(atom_count)).

encode_refuses_invalid_terms_test() ->
    Long = binary:copy(<<"a">>, 256),
    lists:foreach(fun({Tag, Term}) -> ?assertError(badarg, ?C:encode(Tag, Term)) end,
                  [{1, {walk, 0, 1, [Long]}},
                   {1, {clunk, ?NOFID}},
                   {1, {clunk, 16#100000000}},
                   {16#10000, {clunk, 1}},
                   {-1, {clunk, 1}},
                   {1, {flush, 16#10000}},
                   {1, {frobnicate, 1}},
                   {1, {reply, auth, {ok, {0, 0, 0}}}},
                   {1, {reply, read, {ok, binary:copy(<<0>>, 65537)}}},
                   {1, {reply, clunk, {ok, 1}}},
                   {1, {read, 1, -1, 3}},
                   {1, not_a_message}]).

%% The operations the vectors above leave out, each request and reply as 9P2000.L
%% lays it out.
more_operations_test() ->
    Qid = <<0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0>>,
    vector(16, {lcreate, 1, <<"f">>, 16#42, 8#644, 0},
           <<26, 0, 0, 0, 14, 16, 0, 1, 0, 0, 0, 1, 0, "f", 16#42, 0, 0, 0, 16#a4, 1, 0, 0,
             0, 0, 0, 0>>),
    vector(16, {reply, lcreate, {ok, {0, 1, 2}, 8192}},
           <<24, 0, 0, 0, 15, 16, 0, Qid/binary, 0, 16#20, 0, 0>>),
    vector(16, {mknod, 1, <<"n">>, 8#20644, 1, 3, 0},
           <<30, 0, 0, 0, 18, 16, 0, 1, 0, 0, 0, 1, 0, "n", 16#a4, 16#21, 0, 0, 1, 0, 0, 0,
             3, 0, 0, 0, 0, 0, 0, 0>>),
    vector(16, {reply, mknod, {ok, {0, 1, 2}}}, <<20, 0, 0, 0, 19, 16, 0, Qid/binary>>),
    vector(16, {reply, symlink, {ok, {0, 1, 2}}}, <<20, 0, 0, 0, 17, 16, 0, Qid/binary>>),
    vector(16, {reply, mkdir, {ok, {0, 1, 2}}}, <<20, 0, 0, 0, 73, 16, 0, Qid/binary>>),
    vector(16, {readlink, 1}, <<11, 0, 0, 0, 22, 16, 0, 1, 0, 0, 0>>),
    vector(16, {reply, readlink, {ok, <<"/a">>}}, <<11, 0, 0, 0, 23, 16, 0, 2, 0, "/a">>),
    vector(16, {xattrwalk, 1, 2, <<"user.a">>},
           <<23, 0, 0, 0, 30, 16, 0, 1, 0, 0, 0, 2, 0, 0, 0, 6, 0, "user.a">>),
    vector(16, {reply, xattrwalk, {ok, 3}}, <<15, 0, 0, 0, 31, 16, 0, 3, 0, 0, 0, 0, 0, 0, 0>>),
    vector(16, {xattrcreate, 1, <<"user.a">>, 3, 1},
           <<31, 0, 0, 0, 32, 16, 0, 1, 0, 0, 0, 6, 0, "user.a", 3, 0, 0, 0, 0, 0, 0, 0,
             1, 0, 0, 0>>),
    vector(16, {reply, xattrcreate, ok}, <<7, 0, 0, 0, 33, 16, 0>>),
    vector(16, {fsync, 1, 1}, <<15, 0, 0, 0, 50, 16, 0, 1, 0, 0, 0, 1, 0, 0, 0>>),
    vector(16, {reply, fsync, ok}, <<7, 0, 0, 0, 51, 16, 0>>),
    vector(16, {lock, 1, 1, 2, 16#10, 16#20, 7, <<"host">>},
           <<42, 0, 0, 0, 52, 16, 0, 1, 0, 0, 0, 1, 2, 0, 0, 0, 16#10, 0, 0, 0, 0, 0, 0, 0,
             16#20, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 4, 0, "host">>),
    vector(16, {reply, lock, {ok, 0}}, <<8, 0, 0, 0, 53, 16, 0, 0>>),
    vector(16, {getlock, 1, 0, 0, 10, 7, <<"h">>},
           <<35, 0, 0, 0, 54, 16, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             10, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 1, 0, "h">>),
    vector(16, {reply, getlock, {ok, 2, 0, 10, 7, <<"h">>}},
           <<31, 0, 0, 0, 55, 16, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0,
             7, 0, 0, 0, 1, 0, "h">>),
    vector(16, {link, 1, 2, <<"h">>},
           <<18, 0, 0, 0, 70, 16, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1, 0, "h">>),
    vector(16, {reply, link, ok}, <<7, 0, 0, 0, 71, 16, 0>>),
    vector(16, {auth, ?NOFID, <<"u">>, <<"a">>, 0},
           <<21, 0, 0, 0, 102, 16, 0, 16#ff, 16#ff, 16#ff, 16#ff, 1, 0, "u", 1, 0, "a",
             0, 0, 0, 0>>),
    vector(16, {remove, 1}, <<11, 0, 0, 0, 122, 16, 0, 1, 0, 0, 0>>),
    vector(16, {reply, remove, ok}, <<7, 0, 0, 0, 123, 16, 0>>).

%% p9_dirents_max entries of one-byte names decode, one more does not, and a read
%% reply's data past p9_io_max does not, under an msize that admits them.
bounds_at_the_edge_test() ->
    Entry = <<0, 0:32, 1:64/little, 1:64/little, 0, 1:16/little, "a">>,
    Readdir = fun(Count) ->
                      Entries = binary:copy(Entry, Count),
                      message(41, <<(byte_size(Entries)):32/little, Entries/binary>>)
              end,
    ?assertMatch({ok, 1, {reply, readdir, {ok, [_ | _]}}}, ?C:decode(Readdir(2621), 70000)),
    ?assertEqual({error, {malformed, 1}}, ?C:decode(Readdir(2622), 70000)),
    ?assertMatch({ok, 1, _}, ?C:decode(message(117, <<65536:32/little, 0:65536/unit:8>>), 70000)),
    ?assertEqual({error, {malformed, 1}},
                 ?C:decode(message(117, <<65537:32/little, 0:65537/unit:8>>), 70000)).

%% encode/3 refuses what the negotiated msize does not admit: a full write is 65559
%% bytes.
encode_within_msize_test() ->
    Write = {write, 1, 0, <<0:65536/unit:8>>},
    ?assertEqual({error, msize}, ?C:encode(1, Write, 65536)),
    ?assertMatch({ok, <<65559:32/little, _/binary>>}, ?C:encode(1, Write, 65559)),
    ?assertError(badarg, ?C:encode(1, Write, 6)).
