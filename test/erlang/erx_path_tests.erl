%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_path: the answers docs/design-files.md gives by name in
%% Resolving a path and in the client's Links and a trailing "/", each driven
%% to its outcome over one fixed tree by erx_path_tree's executor, and the
%% refusals of input that reaches the resolver from outside.

-module(erx_path_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(LOOKUP, #{follow => true, willbedir => false}).
-define(NOFOLLOW, #{follow => false, willbedir => false}).
-define(WILLBEDIR, #{follow => false, willbedir => true}).

%% The tree: directories d/e and data/logs, files file and d/g, a directory b
%% that the bind mounts over, and links of every kind the design names.
tree() ->
    Chain = maps:from_list([{n(K), {link, n(K + 1)}} || K <- lists:seq(1, 32)]),
    erx_path_tree:new(
      Chain#{<<"d">> => #{<<"e">> => #{<<"f">> => file}, <<"g">> => file},
             <<"b">> => #{},
             <<"file">> => file,
             <<"data">> => #{<<"logs">> => #{<<"x">> => file}},
             <<"n33">> => {link, <<"d">>},
             <<"lnk">> => {link, <<"d/e">>},
             <<"dang">> => {link, <<"newdir">>},
             <<"root">> => {link, <<"/">>},
             <<"fslash">> => {link, <<"file/">>},
             <<"dslash">> => {link, <<"d/">>},
             <<"empty">> => {link, <<>>},
             <<"loop">> => {link, <<"loop">>},
             <<"nul">> => {link, <<"a", 0, "b">>},
             <<"bad">> => {link, <<255>>}}).

n(K) -> <<"n", (integer_to_binary(K))/binary>>.

root_entry() -> #{point => [], root => [], provider => release}.
bind_entry() -> #{point => [<<"b">>], root => [<<"d">>], provider => release}.
logs_entry() -> #{point => [<<"data">>, <<"logs">>], root => [<<"data">>, <<"logs">>],
                  provider => release}.

full() -> [root_entry(), bind_entry()].
narrowed() -> [logs_entry()].

resolve(Path, Op, Flags) -> resolve(Path, Op, Flags, full(), []).

resolve(Path, Op, Flags, Table, Cwd) ->
    erx_path_tree:resolve(Path, Op, Flags, Table, Cwd, tree()).

target(Names) -> {target, root_entry(), Names}.
parent(Names, Last) -> {parent, root_entry(), Names, Last}.

%% "." and ".." act only on names the path has walked.

missing_dotdot_is_enoent_test() ->
    ?assertEqual({error, enoent}, resolve(<<"missing/..">>, lookup, ?LOOKUP)).

file_dot_is_enotdir_for_every_operation_test() ->
    ?assertEqual({error, enotdir}, resolve(<<"file/.">>, lookup, ?LOOKUP)),
    ?assertEqual({error, enotdir}, resolve(<<"file/.">>, delete, ?NOFOLLOW)),
    ?assertEqual({error, enotdir}, resolve(<<"file/..">>, rename, ?NOFOLLOW)).

last_dot_of_delete_or_rename_is_einval_test() ->
    ?assertEqual({error, einval}, resolve(<<"d/.">>, delete, ?NOFOLLOW)),
    ?assertEqual({error, einval}, resolve(<<"d/..">>, rename, ?NOFOLLOW)).

last_dot_of_create_is_the_top_test() ->
    ?assertEqual({top, root_entry()}, resolve(<<"d/.">>, create, ?NOFOLLOW)).

dotdot_removes_the_last_walked_name_test() ->
    ?assertEqual(target([<<"d">>]), resolve(<<"d/e/..">>, lookup, ?LOOKUP)),
    ?assertEqual(target([]), resolve(<<"/../..">>, lookup, ?LOOKUP)).

dotdot_after_a_link_names_the_parent_of_its_target_test() ->
    ?assertEqual(target([<<"d">>]), resolve(<<"lnk/..">>, lookup, ?LOOKUP)).

relative_paths_start_at_the_working_directory_test() ->
    Cwd = [<<"d">>],
    ?assertEqual(target([<<"d">>, <<"e">>]),
                 resolve(<<"e">>, lookup, ?LOOKUP, full(), Cwd)),
    ?assertEqual(target([]), resolve(<<"..">>, lookup, ?LOOKUP, full(), Cwd)).

%% Links.

thirty_two_links_are_followed_and_the_next_is_eloop_test() ->
    ?assertEqual(target([<<"d">>]), resolve(<<"n2">>, lookup, ?LOOKUP)),
    ?assertEqual({error, eloop}, resolve(<<"n1">>, lookup, ?LOOKUP)),
    ?assertEqual({error, eloop}, resolve(<<"loop">>, lookup, ?LOOKUP)).

a_last_link_is_acted_on_without_follow_test() ->
    ?assertEqual(target([<<"lnk">>]), resolve(<<"lnk">>, lookup, ?NOFOLLOW)),
    ?assertEqual(parent([], <<"dang">>), resolve(<<"dang">>, create, ?NOFOLLOW)).

a_create_that_follows_makes_the_name_its_link_names_test() ->
    ?assertEqual(parent([], <<"newdir">>), resolve(<<"dang">>, create, ?LOOKUP)).

a_link_before_the_last_name_is_always_followed_test() ->
    ?assertEqual(parent([<<"d">>, <<"e">>], <<"f">>),
                 resolve(<<"lnk/f">>, delete, ?NOFOLLOW)).

an_empty_link_is_enoent_test() ->
    ?assertEqual({error, enoent}, resolve(<<"empty">>, lookup, ?LOOKUP)).

a_link_text_holding_nul_or_invalid_utf8_is_einval_test() ->
    ?assertEqual({error, einval}, resolve(<<"nul/x">>, lookup, ?NOFOLLOW)),
    ?assertEqual({error, einval}, resolve(<<"bad">>, lookup, ?LOOKUP)).

%% The degenerate "/" and a trailing "/".

slash_alone_is_the_root_for_lookup_and_eisdir_otherwise_test() ->
    ?assertEqual(target([]), resolve(<<"///">>, lookup, ?NOFOLLOW)),
    ?assertEqual({error, eisdir}, resolve(<<"/">>, create, ?WILLBEDIR)),
    ?assertEqual({error, eisdir}, resolve(<<"/">>, delete, ?NOFOLLOW)),
    ?assertEqual({error, eisdir}, resolve(<<"root/">>, delete, ?NOFOLLOW)),
    ?assertEqual(parent([], <<"root">>), resolve(<<"root">>, delete, ?NOFOLLOW)).

a_trailing_slash_follows_the_last_link_test() ->
    ?assertEqual(parent([<<"d">>], <<"e">>), resolve(<<"lnk/">>, delete, ?NOFOLLOW)),
    ?assertEqual(target([<<"d">>, <<"e">>]), resolve(<<"lnk/">>, lookup, ?NOFOLLOW)).

a_trailing_slash_requires_a_directory_test() ->
    ?assertEqual({error, enotdir}, resolve(<<"file/">>, lookup, ?NOFOLLOW)),
    ?assertEqual({error, enotdir}, resolve(<<"file//">>, delete, ?NOFOLLOW)).

a_missing_name_with_a_trailing_slash_is_made_only_as_a_directory_test() ->
    ?assertEqual({error, enoent}, resolve(<<"missing/">>, create, ?NOFOLLOW)),
    ?assertEqual(parent([], <<"missing">>), resolve(<<"missing/">>, create, ?WILLBEDIR)),
    ?assertEqual(parent([], <<"newdir">>), resolve(<<"dang/">>, create, ?WILLBEDIR)),
    ?assertEqual({error, enoent}, resolve(<<"missing/">>, lookup, ?WILLBEDIR)).

a_last_link_text_ending_in_slash_requires_a_directory_test() ->
    ?assertEqual({error, enotdir}, resolve(<<"fslash">>, lookup, ?LOOKUP)),
    ?assertEqual(target([<<"d">>, <<"g">>]), resolve(<<"dslash/g">>, lookup, ?NOFOLLOW)).

%% Entries: a bind's top, and a narrowed table without "/".

dotdot_at_a_binds_top_steps_out_of_its_mount_point_test() ->
    ?assertEqual({target, bind_entry(), [<<"d">>, <<"e">>]},
                 resolve(<<"/b/e">>, lookup, ?LOOKUP)),
    ?assertEqual(target([]), resolve(<<"/b/..">>, lookup, ?LOOKUP)),
    ?assertEqual(target([]), resolve(<<"/b/e/../..">>, lookup, ?LOOKUP)).

a_binds_top_is_answered_by_its_operation_test() ->
    ?assertEqual({top, bind_entry()}, resolve(<<"/b">>, delete, ?NOFOLLOW)),
    ?assertEqual({top, bind_entry()}, resolve(<<"/b/">>, rename, ?WILLBEDIR)),
    ?assertEqual({target, bind_entry(), [<<"d">>]}, resolve(<<"/b">>, lookup, ?LOOKUP)).

a_root_name_that_is_not_a_directory_is_enoent_test() ->
    Table = [root_entry(), #{point => [<<"b">>], root => [<<"file">>]}],
    ?assertEqual({error, enoent}, resolve(<<"/b/x">>, lookup, ?LOOKUP, Table, [])).

a_narrowed_table_reaches_only_its_mounts_test() ->
    Logs = logs_entry(),
    Resolve = fun(Path, Op) -> resolve(Path, Op, ?LOOKUP, narrowed(), []) end,
    ?assertEqual({empty_root, []}, Resolve(<<"/">>, lookup)),
    ?assertEqual({empty_root, [<<"data">>]}, Resolve(<<"/data">>, lookup)),
    ?assertEqual({target, Logs, [<<"data">>, <<"logs">>, <<"x">>]},
                 Resolve(<<"/data/logs/x">>, lookup)),
    ?assertEqual({empty_root, [<<"data">>]}, Resolve(<<"/data/logs/..">>, lookup)),
    ?assertEqual({error, enoent}, Resolve(<<"/etc/passwd">>, lookup)),
    ?assertEqual({top, Logs}, Resolve(<<"/data/logs">>, create)).

%% The empty root is read-only, so a change to it answers erofs, as FreeBSD
%% answers on a read-only mount: for every last name of a delete or rename,
%% a mount point included, and for a create of a missing name, ahead of the
%% trailing "/" check. A create of an existing name gets that directory.
the_empty_root_is_read_only_test() ->
    Resolve = fun(Path, Op, Flags) -> resolve(Path, Op, Flags, narrowed(), []) end,
    Data = {empty_root, [<<"data">>]},
    ?assertEqual({error, erofs}, Resolve(<<"/data/new">>, create, ?LOOKUP)),
    ?assertEqual({error, erofs}, Resolve(<<"/new">>, create, ?LOOKUP)),
    ?assertEqual({error, erofs}, Resolve(<<"/data/new/">>, create, ?LOOKUP)),
    ?assertEqual({error, erofs}, Resolve(<<"/data/new/">>, create, ?WILLBEDIR)),
    ?assertEqual({error, erofs}, Resolve(<<"/data/new/">>, rename, ?NOFOLLOW)),
    ?assertEqual({error, erofs}, Resolve(<<"/data/new">>, delete, ?NOFOLLOW)),
    ?assertEqual({error, erofs}, Resolve(<<"/data/new/">>, delete, ?NOFOLLOW)),
    ?assertEqual({error, erofs}, Resolve(<<"/data/logs">>, delete, ?NOFOLLOW)),
    ?assertEqual({error, erofs}, Resolve(<<"/data/logs/">>, rename, ?NOFOLLOW)),
    ?assertEqual({top, logs_entry()}, Resolve(<<"/data/logs/">>, create, ?WILLBEDIR)),
    ?assertEqual({error, enoent}, Resolve(<<"/data/new/">>, lookup, ?LOOKUP)),
    ?assertEqual({error, enoent}, Resolve(<<"/etc/new">>, create, ?LOOKUP)),
    ?assertEqual(Data, Resolve(<<"/data">>, create, ?LOOKUP)),
    ?assertEqual(Data, Resolve(<<"/data/">>, create, ?WILLBEDIR)),
    ?assertEqual({error, erofs}, Resolve(<<"/data">>, delete, ?NOFOLLOW)),
    ?assertEqual({error, erofs}, Resolve(<<"/data/">>, rename, ?NOFOLLOW)),
    ?assertEqual({error, einval}, Resolve(<<"/data/.">>, delete, ?NOFOLLOW)).

%% Input from outside: the path, link texts and walk replies.

a_malformed_path_is_refused_before_any_walk_test() ->
    Refuse = fun(Path) -> erx_path:resolve(Path, lookup, ?LOOKUP, full(), [], unreachable()) end,
    ?assertEqual({error, enoent}, Refuse(<<>>)),
    ?assertEqual({error, einval}, Refuse(<<"a", 0>>)),
    ?assertEqual({error, einval}, Refuse(<<"a", 255>>)),
    ?assertEqual({error, einval}, Refuse(<<"a", 16#ed, 16#a0, 16#80>>)),
    ?assertEqual({error, enametoolong}, Refuse(binary:copy(<<"a">>, 4096))),
    ?assertEqual({error, enametoolong}, Refuse(binary:copy(<<"a">>, 256))),
    TooMany = iolist_to_binary(lists:join(<<"/">>, lists:duplicate(257, <<"a">>))),
    ?assertEqual({error, enametoolong}, Refuse(TooMany)).

unreachable() ->
    #{walk => fun(_, _) -> erlang:error(walked) end,
      read_link => fun(_, _) -> erlang:error(read) end}.

a_malformed_walk_reply_is_eio_test() ->
    Names = [<<"d">>, <<"e">>],
    Replies = [{[directory, directory, directory], ok}, {[directory], ok},
               {[other, directory], ok}, {[directory], {error, "enoent"}},
               {[directory | directory], ok}, nonsense, {[], unknown}],
    lists:foreach(
      fun(Reply) ->
              Callbacks = #{walk => fun(_, _) -> Reply end,
                            read_link => fun(_, _) -> erlang:error(read) end},
              Action = erx_path:resolve(<<"d/e/..">>, lookup, ?LOOKUP, full(), [],
                                        Callbacks),
              ?assertEqual({Reply, {error, eio}}, {Reply, Action})
      end, Replies),
    {target, _, Names, Resume} = erx_path:resolve(<<"d/e">>, lookup, ?LOOKUP, full(), [],
                                                  erx_path_tree:callbacks(tree())),
    ?assertEqual({error, eio}, Resume({[directory, directory], ok})).

a_malformed_link_read_is_eio_test() ->
    Callbacks = #{walk => fun(_, _) -> {[link], ok} end,
                  read_link => fun(_, _) -> {ok, "text"} end},
    ?assertEqual({error, eio},
                 erx_path:resolve(<<"l/x/..">>, lookup, ?LOOKUP, full(), [], Callbacks)).

%% The working directory's text is read as a place, and anything else refused, so
%% prim_file:set_cwd/1 stores only a place.
cwd_reads_only_a_place_test() ->
    Long = binary:copy(<<"n">>, ?ERX_NAME_MAX),
    ?assertEqual({ok, []}, erx_path:cwd(<<"/">>)),
    ?assertEqual({ok, [<<"a">>, <<"b">>]}, erx_path:cwd(<<"/a/b">>)),
    ?assertEqual({ok, [Long]}, erx_path:cwd(<<"/", Long/binary>>)),
    ?assertEqual({ok, lists:duplicate(?ERX_NS_NAMES_MAX, <<"n">>)},
                 erx_path:cwd(binary:copy(<<"/n">>, ?ERX_NS_NAMES_MAX))),
    Refused = [<<>>, <<"a">>, <<"a/b">>, <<"/a/">>, <<"//a">>, <<"/a//b">>, <<"/.">>,
               <<"/a/..">>, <<"/a/./b">>, <<"/a", 0, "b">>, <<"/", 16#ff>>,
               <<"/", 16#ed, 16#a0, 16#80>>, <<"/", Long/binary, "n">>,
               binary:copy(<<"/n">>, ?ERX_NS_NAMES_MAX + 1),
               binary:copy(<<"/nnnnnnn">>, ?ERX_PATH_MAX div 8),
               "/a", '/', [<<"/">>]],
    ?assertEqual([], [Text || Text <- Refused, erx_path:cwd(Text) =/= error]).
