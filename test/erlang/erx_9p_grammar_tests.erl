%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_9p_grammar, generated from abi/protocols/9p.txt: every field bound at
%% bound - 1, bound and bound + 1, the names a name refuses, each reply check against its
%% request, the read-only refusal set and the builders. test/host/erx_9p_grammar_test.rb
%% runs them on stock OTP, and runs them again against a grammar generated from a table
%% that drops the name bound, which must fail.

-module(erx_9p_grammar_tests).
-include_lib("eunit/include/eunit.hrl").

-define(G, erx_9p_grammar).
-define(NOFID, 16#ffffffff).
-define(U32, 16#ffffffff).
-define(U64, 16#ffffffffffffffff).
-define(QID, {0, 0, 1}).

ok(Request) -> ?assertEqual({ok, Request}, ?G:decode_request(Request)).
bad(Request) -> ?assertEqual({error, einval}, ?G:decode_request(Request)).
reply_ok(Request, Reply) -> ?assertEqual({ok, Reply}, ?G:decode_reply(Request, Reply)).
reply_bad(Request, Reply) -> ?assertEqual({error, eio}, ?G:decode_reply(Request, Reply)).

bytes(N) -> binary:copy(<<"a">>, N).
mkdir(Name) -> {mkdir, 1, Name, 8#755, 0}.
walk(Names) -> {walk, 1, 2, Names}.

operations_are_the_minimum_test() ->
    ?assertEqual(lists:sort([version, auth, attach, walk, lopen, lcreate, read, write, readdir,
                             getattr, setattr, mkdir, symlink, link, readlink, unlinkat,
                             renameat, statfs, fsync, flush, clunk, mknod, xattrwalk,
                             xattrcreate, lock, getlock, remove]),
                 lists:sort(?G:operations())),
    ?assertEqual(110, ?G:message_type(walk)),
    ?assertEqual(76, ?G:message_type(unlinkat)).

every_operation_decodes_test() ->
    Alias = make_ref(),
    SetAttr = #{valid => 1, mode => 8#644, uid => 0, gid => 0, size => 0, atime_sec => 0,
                atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0},
    lists:foreach(fun ok/1,
                  [{version, 65560, <<"9P2000.L">>}, {auth, ?NOFID, <<"u">>, <<"tmp">>, 0},
                   {attach, 1, ?NOFID, <<"u">>, <<"tmp">>, 0}, walk([]), walk([<<"a">>]),
                   {lopen, 1, 0}, {lcreate, 1, <<"f">>, 2, 8#644, 0}, {read, 1, 0, 10},
                   {write, 1, 0, <<"x">>}, {readdir, 1, 0, 4096}, {getattr, 1, 16#3fff},
                   {setattr, 1, SetAttr}, mkdir(<<"d">>), {symlink, 1, <<"l">>, <<"/x">>, 0},
                   {link, 1, 2, <<"h">>}, {readlink, 1}, {unlinkat, 1, <<"f">>, 0},
                   {renameat, 1, <<"a">>, 2, <<"b">>}, {statfs, 1}, {fsync, 1, 0},
                   {flush, Alias}, {clunk, 1}, {mknod, 1, <<"n">>, 0, 0, 0, 0},
                   {xattrwalk, 1, 2, <<>>}, {xattrcreate, 1, <<"user.a">>, 0, 0},
                   {lock, 1, 1, 0, 0, 0, 1, <<"host">>}, {getlock, 1, 0, 0, 0, 1, <<"host">>},
                   {remove, 1}]).

other_terms_are_refused_test() ->
    lists:foreach(fun bad/1, [rename, {rename, 1, 2, <<"a">>}, {clunk}, {clunk, 1, 2},
                              [clunk, 1], <<"clunk">>, {unknown, 1}, #{}, 42]).

fid_bounds_test() ->
    ok({clunk, 0}),
    ok({clunk, ?NOFID - 1}),
    bad({clunk, ?NOFID}),
    bad({clunk, ?NOFID + 1}),
    bad({clunk, -1}),
    bad({clunk, 1.0}),
    bad({clunk, <<1>>}),
    %% Afid may be NOFID; Fid may not.
    ok({attach, 1, ?NOFID, <<>>, <<>>, 0}),
    bad({attach, ?NOFID, ?NOFID, <<>>, <<>>, 0}),
    bad(walk_with_new_fid(?NOFID)).

walk_with_new_fid(NewFid) -> {walk, 1, NewFid, []}.

integer_bounds_test() ->
    ok({lopen, 1, ?U32 - 1}),
    ok({lopen, 1, ?U32}),
    bad({lopen, 1, ?U32 + 1}),
    ok({read, 1, ?U64, 0}),
    bad({read, 1, ?U64 + 1, 0}),
    ok({lock, 1, 254, 0, 0, 0, 1, <<>>}),
    ok({lock, 1, 255, 0, 0, 0, 1, <<>>}),
    bad({lock, 1, 256, 0, 0, 0, 1, <<>>}),
    ok({fsync, 1, ?U32}),
    bad({fsync, 1, true}).

count_bounds_test() ->
    lists:foreach(fun(Op) ->
                          ok({Op, 1, 0, 65535}),
                          ok({Op, 1, 0, 65536}),
                          bad({Op, 1, 0, 65537})
                  end, [read, readdir]),
    ok({write, 1, 0, bytes(65535)}),
    ok({write, 1, 0, bytes(65536)}),
    bad({write, 1, 0, bytes(65537)}),
    bad({write, 1, 0, "list"}),
    ok({xattrcreate, 1, <<"a">>, 65535, 0}),
    ok({xattrcreate, 1, <<"a">>, 65536, 0}),
    bad({xattrcreate, 1, <<"a">>, 65537, 0}).

name_test() ->
    ok(mkdir(bytes(254))),
    ok(mkdir(bytes(255))),
    bad(mkdir(bytes(256))),
    ok(mkdir(<<"caf", 16#c3, 16#a9>>)),
    ok(mkdir(<<"...">>)),
    ok(mkdir(<<".hidden">>)),
    lists:foreach(fun(Name) -> bad(mkdir(Name)) end, refused_names()).

refused_names() ->
    [<<>>, <<".">>, <<"..">>, <<"a", 0, "b">>, <<0>>, <<"a/b">>, <<"/">>,
     <<255>>, <<"a", 16#c0, 16#80>>, <<16#ed, 16#a0, 16#80>>, <<16#e2, 16#82>>,
     <<16#f4, 16#90, 16#80, 16#80>>, "abc", abc, 42].

every_entry_name_is_a_name_test() ->
    Checks = [fun(N) -> {lcreate, 1, N, 0, 0, 0} end, fun(N) -> {symlink, 1, N, <<"t">>, 0} end,
              fun(N) -> {mknod, 1, N, 0, 0, 0, 0} end, fun(N) -> {link, 1, 2, N} end,
              fun(N) -> {renameat, 1, N, 2, <<"b">>} end, fun(N) -> {renameat, 1, <<"a">>, 2, N} end,
              fun(N) -> {unlinkat, 1, N, 0} end],
    lists:foreach(fun(Make) ->
                          ok(Make(bytes(255))),
                          lists:foreach(fun(Name) -> bad(Make(Name)) end,
                                        [bytes(256) | refused_names()])
                  end, Checks).

walk_names_test() ->
    ok(walk([<<"..">>])),
    ok(walk([<<"a">>, <<"..">>, <<"b">>])),
    bad(walk([<<".">>])),
    bad(walk([<<"a/b">>])),
    bad(walk([<<>>])),
    bad(walk([bytes(256)])),
    ok(walk(lists:duplicate(15, <<"a">>))),
    ok(walk(lists:duplicate(16, <<"a">>))),
    bad(walk(lists:duplicate(17, <<"a">>))),
    bad(walk([<<"a">> | <<"b">>])),
    bad(walk(<<"a">>)),
    ok(walk([bytes(255)])),
    bad(walk([<<"a", 0>>])),
    bad(walk([<<255>>])),
    bad(walk([<<16#ed, 16#a0, 16#80>>])),
    %% A long list is refused after its seventeenth element, not walked.
    bad(walk(lists:duplicate(1000000, <<"a">>))).

xattr_name_test() ->
    ok({xattrwalk, 1, 2, <<>>}),
    ok({xattrwalk, 1, 2, bytes(255)}),
    bad({xattrwalk, 1, 2, bytes(256)}),
    bad({xattrwalk, 1, 2, <<"a", 0>>}),
    bad({xattrwalk, 1, 2, <<255>>}),
    bad({xattrwalk, 1, 2, <<"a/b">>}).

string_test() ->
    Attach = fun(Uname, Aname) -> {attach, 1, ?NOFID, Uname, Aname, 0} end,
    ok(Attach(bytes(255), <<>>)),
    bad(Attach(bytes(256), <<>>)),
    bad(Attach(<<>>, bytes(256))),
    bad(Attach(<<0>>, <<>>)),
    bad(Attach(<<255>>, <<>>)),
    ok({version, 8192, bytes(255)}),
    bad({version, 8192, bytes(256)}),
    bad({lock, 1, 0, 0, 0, 0, 1, bytes(256)}).

symlink_target_test() ->
    Link = fun(Target) -> {symlink, 1, <<"l">>, Target, 0} end,
    ok(Link(bytes(4094))),
    ok(Link(bytes(4095))),
    bad(Link(bytes(4096))),
    bad(Link(<<"a", 0>>)),
    %% Stored as given: an empty text reaches the server, which answers enoent, and the
    %% text need not be UTF-8.
    ok(Link(<<>>)),
    ok(Link(<<255, "/..">>)).

unlink_flags_test() ->
    ok({unlinkat, 1, <<"f">>, 0}),
    ok({unlinkat, 1, <<"f">>, 16#200}),
    bad({unlinkat, 1, <<"f">>, 1}),
    bad({unlinkat, 1, <<"f">>, 16#1ff}),
    bad({unlinkat, 1, <<"f">>, 16#201}).

set_attr() ->
    #{valid => 0, mode => 0, uid => 0, gid => 0, size => 0, atime_sec => 0,
      atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0}.

setattr_map_test() ->
    ok({setattr, 1, set_attr()}),
    ok({setattr, 1, (set_attr())#{size := ?U64}}),
    bad({setattr, 1, (set_attr())#{size := ?U64 + 1}}),
    bad({setattr, 1, (set_attr())#{valid := ?U32 + 1}}),
    bad({setattr, 1, maps:remove(mode, set_attr())}),
    bad({setattr, 1, (set_attr())#{extra => 0}}),
    bad({setattr, 1, maps:put(extra, 0, maps:remove(mode, set_attr()))}),
    bad({setattr, 1, maps:to_list(set_attr())}).

flush_test() ->
    ok({flush, make_ref()}),
    bad({flush, 1}),
    bad({flush, self()}).

errors_test() ->
    Request = {clunk, 1},
    lists:foreach(fun(Posix) -> reply_ok(Request, {error, Posix}) end,
                  [enoent, eacces, eperm, eexist, enotdir, eisdir, enotempty, erofs, enospc,
                   efbig, einval, ebadf, emfile, enfile, eio, enametoolong, enotsup, eloop,
                   enxio, exdev, enomem, eagain, enodata, erange, enolck, ebusy]),
    reply_bad(Request, {error, etimedout}),
    reply_bad(Request, {error, "enoent"}),
    reply_bad(Request, {error, 2}),
    reply_bad(Request, {error, enoent, extra}).

read_reply_test() ->
    Request = {read, 1, 0, 3},
    reply_ok(Request, {ok, <<>>}),
    reply_ok(Request, {ok, <<"ab">>}),
    reply_ok(Request, {ok, <<"abc">>}),
    reply_bad(Request, {ok, <<"abcd">>}),
    reply_bad(Request, {ok, "abc"}),
    reply_bad(Request, ok).

write_reply_test() ->
    Request = {write, 1, 10, <<"abc">>},
    reply_ok(Request, {ok, 2, 10}),
    reply_ok(Request, {ok, 3, 10}),
    reply_bad(Request, {ok, 4, 10}),
    reply_ok(Request, {ok, 3, unknown}),
    reply_ok(Request, {ok, 3, ?U64}),
    reply_bad(Request, {ok, 3, ?U64 + 1}),
    reply_bad(Request, {ok, 3, -1}),
    reply_bad(Request, {ok, 3, known}),
    reply_bad(Request, {ok, 3}).

walk_reply_test() ->
    reply_ok(walk([]), {ok, []}),
    reply_bad(walk([]), {ok, [?QID]}),
    Two = walk([<<"a">>, <<"b">>]),
    reply_bad(Two, {ok, []}),
    reply_ok(Two, {ok, [?QID]}),
    reply_ok(Two, {ok, [?QID, ?QID]}),
    reply_bad(Two, {ok, [?QID, ?QID, ?QID]}),
    reply_bad(Two, {ok, [{0, 0}]}),
    reply_bad(Two, {ok, [{256, 0, 0}]}),
    reply_bad(Two, {ok, [?QID | ?QID]}).

readdir_reply_test() ->
    %% Each entry packs as 24 bytes and its name's.
    Entry = fun(Name) -> {?QID, 1, 4, Name} end,
    Request = {readdir, 1, 0, 24 * 2 + 1 + 2},
    reply_ok(Request, {ok, []}),
    reply_ok(Request, {ok, [Entry(<<".">>), Entry(<<"..">>)]}),
    reply_bad(Request, {ok, [Entry(<<".">>), Entry(<<"...">>)]}),
    reply_bad(Request, {ok, [Entry(<<>>)]}),
    reply_bad(Request, {ok, [Entry(<<"a/b">>)]}),
    reply_bad(Request, {ok, [Entry(<<"a", 0>>)]}),
    reply_bad(Request, {ok, [Entry(<<255>>)]}),
    reply_ok({readdir, 1, 0, 65536}, {ok, [Entry(bytes(255))]}),
    reply_bad({readdir, 1, 0, 65536}, {ok, [Entry(bytes(256))]}),
    %% The list bound alone: the builder checks the shape, not the packed size.
    ?assertEqual({ok, lists:duplicate(2621, Entry(<<"a">>))},
                 ?G:readdir_reply(lists:duplicate(2621, Entry(<<"a">>)))),
    ?assertError(badarg, ?G:readdir_reply(lists:duplicate(2622, Entry(<<"a">>)))),
    reply_ok({readdir, 1, 0, 65536}, {ok, lists:duplicate(2621, Entry(<<"a">>))}),
    reply_bad({readdir, 1, 0, 65536}, {ok, lists:duplicate(2622, Entry(<<"a">>))}).

xattrwalk_reply_test() ->
    Request = {xattrwalk, 1, 2, <<>>},
    reply_ok(Request, {ok, 65535}),
    reply_ok(Request, {ok, 65536}),
    reply_bad(Request, {ok, 65537}).

version_reply_test() ->
    Request = {version, 8192, <<"9P2000.L">>},
    reply_ok(Request, {ok, 8191, <<"9P2000.L">>}),
    reply_ok(Request, {ok, 8192, <<"unknown">>}),
    reply_bad(Request, {ok, 8193, <<"9P2000.L">>}).

refused_operation_has_only_errors_test() ->
    Request = {auth, ?NOFID, <<>>, <<>>, 0},
    reply_ok(Request, {error, enotsup}),
    reply_bad(Request, {ok, ?QID}),
    reply_bad(Request, ok).

getattr_reply_test() ->
    Keys = [valid, mode, uid, gid, nlink, rdev, size, blksize, blocks, atime_sec, atime_nsec,
            mtime_sec, mtime_nsec, ctime_sec, ctime_nsec, btime_sec, btime_nsec, gen,
            data_version],
    Attr = maps:from_list([{qid, ?QID} | [{Key, 0} || Key <- Keys]]),
    Request = {getattr, 1, 16#3fff},
    reply_ok(Request, {ok, Attr}),
    reply_bad(Request, {ok, Attr#{qid := 0}}),
    reply_bad(Request, {ok, Attr#{mode := ?U32 + 1}}),
    reply_bad(Request, {ok, maps:remove(gen, Attr)}).

decode_reply_needs_a_valid_request_test() ->
    ?assertError(badarg, ?G:decode_reply({clunk, ?NOFID}, ok)),
    ?assertError(badarg, ?G:decode_reply(nonsense, ok)).

frame_test() ->
    Alias = make_ref(),
    Owner = self(),
    ?assertEqual({ok, Alias, Owner, {clunk, 1}}, ?G:decode_request_frame({erx_9p, Alias, Owner, {clunk, 1}})),
    ?assertEqual({error, Alias, einval}, ?G:decode_request_frame({erx_9p, Alias, Owner, {clunk, ?NOFID}})),
    ?assertEqual({error, Alias, einval}, ?G:decode_request_frame({erx_9p, Alias, owner, {clunk, 1}})),
    ?assertEqual(error, ?G:decode_request_frame({erx_9p, 1, Owner, {clunk, 1}})),
    ?assertEqual(error, ?G:decode_request_frame({other, Alias, Owner, {clunk, 1}})),
    ?assertEqual(error, ?G:decode_request_frame(nonsense)).

writes_test() ->
    Writes = fun(Request) -> ok(Request), ?G:writes(Request) end,
    ?assertNot(Writes({lopen, 1, 0})),
    ?assert(Writes({lopen, 1, 1})),
    ?assert(Writes({lopen, 1, 2})),
    ?assert(Writes({lopen, 1, 8#1000})),
    ?assertNot(Writes({lopen, 1, 8#200000})),
    ?assert(Writes({lcreate, 1, <<"f">>, 0, 0, 0})),
    ?assert(Writes({lock, 1, 1, 0, 0, 0, 1, <<>>})),
    ?assertNot(Writes({lock, 1, 0, 0, 0, 0, 1, <<>>})),
    ?assertNot(Writes({lock, 1, 2, 0, 0, 0, 1, <<>>})),
    lists:foreach(fun(Request) -> ?assert(Writes(Request)) end,
                  [{write, 1, 0, <<>>}, {setattr, 1, set_attr()}, {remove, 1},
                   {unlinkat, 1, <<"f">>, 0}, {renameat, 1, <<"a">>, 2, <<"b">>},
                   {link, 1, 2, <<"h">>}, {symlink, 1, <<"l">>, <<"t">>, 0},
                   {mknod, 1, <<"n">>, 0, 0, 0, 0}, mkdir(<<"d">>),
                   {xattrcreate, 1, <<"a">>, 0, 0}]),
    lists:foreach(fun(Request) -> ?assertNot(Writes(Request)) end,
                  [{read, 1, 0, 1}, {readdir, 1, 0, 1}, walk([]), {clunk, 1}, {getattr, 1, 0},
                   {statfs, 1}, {readlink, 1}, {fsync, 1, 0}, {flush, make_ref()},
                   {version, 8192, <<>>}, {xattrwalk, 1, 2, <<>>},
                   {getlock, 1, 1, 0, 0, 1, <<>>}]).

directory_fids_test() ->
    Directories = fun(Request) -> ok(Request), ?G:directory_fids(Request) end,
    ?assertEqual([1], Directories({lcreate, 1, <<"f">>, 0, 0, 0})),
    ?assertEqual([1], Directories({symlink, 1, <<"l">>, <<"t">>, 0})),
    ?assertEqual([1], Directories({mknod, 1, <<"n">>, 0, 0, 0, 0})),
    ?assertEqual([1], Directories({readdir, 1, 0, 1})),
    ?assertEqual([1], Directories({link, 1, 2, <<"h">>})),
    ?assertEqual([1], Directories({unlinkat, 1, <<"f">>, 0})),
    ?assertEqual([1, 2], Directories({renameat, 1, <<"a">>, 2, <<"b">>})),
    ?assertEqual([1], Directories(mkdir(<<"d">>))),
    lists:foreach(fun(Request) -> ?assertEqual([], Directories(Request)) end,
                  [{read, 1, 0, 1}, walk([]), {clunk, 1}, {remove, 1}, {lopen, 1, 0},
                   {getattr, 1, 0}, {flush, make_ref()}, {xattrwalk, 1, 2, <<>>}]).

builders_test() ->
    ?assertEqual({walk, 1, 2, [<<"a">>]}, ?G:walk_request(1, 2, [<<"a">>])),
    ?assertEqual({write, 1, 0, <<"x">>}, ?G:write_request(1, 0, <<"x">>)),
    ?assertEqual({ok, 1, unknown}, ?G:write_reply(1, unknown)),
    ?assertEqual(ok, ?G:clunk_reply()),
    ?assertEqual({error, enoent}, ?G:error_reply(enoent)),
    ?assertError(badarg, ?G:walk_request(1, 2, [<<"..">>, <<".">>])),
    ?assertError(badarg, ?G:mkdir_request(1, bytes(256), 0, 0)),
    ?assertError(badarg, ?G:read_reply(bytes(65537))),
    ?assertError(badarg, ?G:error_reply(etimedout)).
