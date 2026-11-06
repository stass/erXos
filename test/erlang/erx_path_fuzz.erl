%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_path (docs/design-files.md, Verification). Each case
%% builds a random model tree of directories, files and links (relative,
%% absolute, empty, ending in "/" and looping), a random table over it (an
%% entry at "/", binds with roots, or a narrowed table without "/") and a
%% working directory, and resolves random paths of plain names, ".", "..",
%% doubled and trailing "/" with a random operation, FOLLOW and WILLBEDIR.
%% The resolver's walks and link reads are answered from the tree and each
%% resumption is called as the client calls it (erx_path_tree:execute/3), and
%% the outcome must be the reference model's (erx_path_model), FreeBSD's
%% vfs_lookup over the same tree with the table's entries mounted on it.
%%
%% The callbacks check the properties on every walk and link read, and the
%% outcome's walk on every action: no name is ".", ".." or empty; every walk
%% begins with its entry's root names and keeps the place within
%% ERX_NS_NAMES_MAX names; and every entry is one of the table the
%% resolution was handed. A quarter of the resolutions also replace the
%% namespace's persistent term from inside the callbacks, which a resolver
%% that read the table anywhere but from its arguments would see.
%%
%% Then the untrusted inputs go in raw: paths of arbitrary bytes, NUL and
%% invalid UTF-8 among them and some over every bound, which must be refused
%% exactly as the design says; link texts of arbitrary bytes, refused the
%% same way when followed; and hostile walk and link replies, longer than
%% their walks or of the wrong shape, each answered with an error or an
%% action and never a crash, within a bounded number of resumptions.
%%
%% The seed comes from make check-fuzz; tools/fuzz/erx_path.rb runs this
%% against erx_path as it is and against copies with the design's seeded
%% faults, each of which must fail.

-module(erx_path_fuzz).
-export([run/1]).

-define(CASES, 4000).
-define(PATHS, 25).
-define(NAMES, [<<"a">>, <<"b">>, <<"c">>, <<"d">>]).
-define(POINT_NAMES, [<<"a">>, <<"b">>, <<"x">>, <<"y">>]).
-define(TERM, erx_ns).

%% Prints the count, and how many differential outcomes were of each kind, so
%% a passing run shows which answers the cases reached.
run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Outcomes = lists:append([one_case() || _ <- lists:seq(1, ?CASES)]),
    io:format("fuzz: ~b resolutions ok~n", [length(Outcomes) + 3 * ?CASES]),
    io:format("outcomes: ~p~n", [lists:sort(maps:to_list(tally(Outcomes)))]).

tally(Outcomes) ->
    lists:foldl(fun(Kind, Counts) -> maps:update_with(Kind, fun(N) -> N + 1 end, 1, Counts) end,
                #{}, [kind(Outcome) || Outcome <- Outcomes]).

kind({error, Posix}) -> Posix;
kind(Action) -> element(1, Action).

one_case() ->
    Tree = erx_path_tree:new(tree(3)),
    {NS, Table} = erx_path_model:namespace(table(Tree), Tree),
    Cwd = cwd(NS),
    CwdVnode = erx_path_model:cwd(Cwd, NS),
    Outcomes = [differential(Tree, NS, Table, Cwd, CwdVnode) || _ <- lists:seq(1, ?PATHS)],
    raw_path(Tree, Table, Cwd),
    raw_link(),
    hostile(Table, Cwd),
    Outcomes.

%% One resolution compared with the model's.
differential(Tree, NS, Table, Cwd, CwdVnode) ->
    Path = case rand:uniform(2) of
               1 -> path();
               2 -> steered_path(NS, CwdVnode)
           end,
    Op = pick([lookup, create, delete, rename]),
    Flags = #{follow => rand:uniform(2) =:= 1, willbedir => rand:uniform(2) =:= 1},
    Expected = erx_path_model:namei(Path, Op, Flags, NS, CwdVnode),
    Flip = rand:uniform(4) =:= 1,
    Flip andalso persistent_term:put(?TERM, Table),
    Callbacks = checking(Table, answers(Tree), Flip),
    Got = outcome(erx_path:resolve(Path, Op, Flags, Table, Cwd, Callbacks), Tree, Flags, Table),
    Flip andalso persistent_term:erase(?TERM),
    case Got =:= Expected of
        true -> Got;
        false ->
            erlang:error({mismatch, #{path => Path, op => Op, flags => Flags, table => Table,
                                      cwd => Cwd, tree => Tree, expected => Expected,
                                      got => Got}})
    end.

outcome(Action, Tree, #{follow := Follow}, Table) ->
    Outcome = erx_path_tree:execute(checked_action(Action, Table), Tree, Follow),
    check_outcome(Outcome, Table),
    Outcome.

answers(Tree) ->
    {fun(Names) -> erx_path_tree:walk(Tree, Names) end,
     fun(Names) -> erx_path_tree:read_link(Tree, Names) end}.

%% Callbacks that check every walk and link read the resolver asks for, and
%% when Flip is set replace the namespace's term before answering.
checking(Table, {Walk, ReadLink}, Flip) ->
    #{walk => fun(Entry, Names) ->
                      check_walk(walk, Entry, Names, Table),
                      flip(Flip),
                      Walk(Names)
              end,
      read_link => fun(Entry, Names) ->
                           check_walk(read_link, Entry, Names, Table),
                           flip(Flip),
                           ReadLink(Names)
                   end}.

flip(true) -> persistent_term:put(?TERM, []);
flip(false) -> ok.

check_walk(Why, Entry, Names, Table) ->
    #{point := Point, root := Root} = Entry,
    lists:member(Entry, Table) orelse erlang:error({not_in_table, Why, Entry, Table}),
    lists:all(fun plain/1, Names) orelse erlang:error({walk_names, Why, Names}),
    lists:prefix(Root, Names) orelse erlang:error({walk_above_root, Why, Root, Names}),
    length(Names) - length(Root) + length(Point) =< 256
        orelse erlang:error({place_bound, Why, Point, Names}).

plain(Name) ->
    is_binary(Name) andalso Name =/= <<>> andalso Name =/= <<".">> andalso Name =/= <<"..">>.

%% An action whose walk the executor sends checks as a callback's walk does,
%% and each resumption's next action too.
checked_action({target, Entry, Names, Resume}, Table) ->
    check_walk(target, Entry, Names, Table),
    {target, Entry, Names, fun(Reply) -> checked_action(Resume(Reply), Table) end};
checked_action({parent, Entry, Names, Last, Resume}, Table) ->
    check_walk(parent, Entry, Names ++ [Last], Table),
    {parent, Entry, Names, Last, fun(Reply) -> checked_action(Resume(Reply), Table) end};
checked_action(Action, _) ->
    Action.

check_outcome({top, Entry}, Table) ->
    lists:member(Entry, Table) orelse erlang:error({not_in_table, top, Entry, Table});
check_outcome({empty_root, Place}, _) ->
    length(Place) =< 256 andalso lists:all(fun plain/1, Place)
        orelse erlang:error({empty_root_place, Place});
check_outcome({error, Posix}, _) when is_atom(Posix) -> true;
check_outcome({target, _, _}, _) -> true;
check_outcome({parent, _, _, Last}, _) -> plain(Last) orelse erlang:error({last_name, Last});
check_outcome(Other, _) -> erlang:error({outcome, Other}).

%% A random tree: directories two to three levels deep, files and links.
tree(0) ->
    #{};
tree(Depth) ->
    maps:from_list([{pick(?NAMES), tree_node(Depth)} || _ <- lists:seq(1, rand:uniform(5))]).

tree_node(Depth) ->
    case rand:uniform(10) of
        N when N =< 5 -> tree(Depth - 1);
        N when N =< 7 -> file;
        _ -> {link, link_text()}
    end.

link_text() ->
    case rand:uniform(10) of
        1 -> <<>>;
        2 -> <<"/">>;
        _ -> text(?NAMES ++ [<<".">>, <<"..">>], 4)
    end.

%% A table: usually an entry at "/", and up to three more, whose points are
%% drawn from the tree's own directories or from names it may not have.
table(Tree) ->
    Dirs = dirs(Tree, 0, []),
    Root = [#{point => [], root => pick_root(Dirs), provider => release}
            || rand:uniform(5) =/= 1],
    Points = lists:usort([point(Dirs) || _ <- lists:seq(1, rand:uniform(4) - 1)]) -- [[]],
    Root ++ [#{point => P, root => pick_root(Dirs), provider => {grant, I}}
             || {I, P} <- lists:enumerate(Points)].

point(Dirs) ->
    case rand:uniform(2) of
        1 -> pick(Dirs);
        2 -> [pick(?POINT_NAMES) || _ <- lists:seq(1, rand:uniform(3))]
    end.

pick_root(Dirs) ->
    case rand:uniform(3) of
        1 -> pick(Dirs);
        _ -> []
    end.

%% The tree's directories reached without a link, by their names.
dirs(Tree, Id, Names) ->
    {dir, Children, _} = maps:get(Id, Tree),
    [lists:reverse(Names) |
     lists:append([dirs(Tree, Child, [Name | Names])
                   || {Name, Child} <- maps:to_list(Children),
                      is_tuple(maps:get(Child, Tree)),
                      element(1, maps:get(Child, Tree)) =:= dir])].

%% A working directory: a few steps down through directories, crossing
%% mounts as the model's lookup does.
cwd(NS) ->
    cwd(maps:get(root, NS), [], rand:uniform(4) - 1, NS).

cwd(_, Place, 0, _) ->
    Place;
cwd(Vnode, Place, Steps, NS) ->
    Name = pick(?NAMES ++ ?POINT_NAMES),
    case erx_path_model:lookup(Vnode, Name, NS) of
        none -> Place;
        Found ->
            case erx_path_model:type(Found, NS) of
                dir -> cwd(Found, Place ++ [Name], Steps - 1, NS);
                _ -> Place
            end
    end.

%% A path that mostly names what the namespace holds: from "/" or the working
%% directory, each step a name the directory reached holds, or a "." or "..",
%% so more resolutions get past their first names than random names do. Once
%% a step reaches anything but a directory the path goes on with random names.
steered_path(NS, Cwd) ->
    {Lead, Start} = case rand:uniform(2) of
                        1 -> {<<"/">>, maps:get(root, NS)};
                        2 -> {<<>>, Cwd}
                    end,
    Names = steer(Start, rand:uniform(5), NS),
    Trail = pick([<<>>, <<>>, <<>>, <<"/">>]),
    iolist_to_binary([Lead, lists:join(<<"/">>, Names), Trail]).

steer(_, 0, _) ->
    [];
steer(none, Steps, NS) ->
    [pick(?NAMES ++ [<<"..">>]) | steer(none, Steps - 1, NS)];
steer(Dir, Steps, NS) ->
    case {rand:uniform(5), erx_path_model:children(Dir, NS)} of
        {N, [_ | _] = Names} when N =< 3 ->
            Name = pick(Names),
            Next = erx_path_model:lookup(Dir, Name, NS),
            [Name | steer(directory(Next, NS), Steps - 1, NS)];
        {4, _} ->
            [<<".">> | steer(Dir, Steps - 1, NS)];
        _ ->
            [pick([<<"..">>, pick(?NAMES)]) | steer(none, Steps - 1, NS)]
    end.

directory(none, _) -> none;
directory(Vnode, NS) ->
    case erx_path_model:type(Vnode, NS) of
        dir -> Vnode;
        _ -> none
    end.

path() ->
    text(?NAMES ++ ?NAMES ++ ?POINT_NAMES ++ [<<".">>, <<"..">>, <<"..">>], 6).

%% Up to Max pieces joined by "/" or "//", absolute or relative, sometimes
%% with a trailing "/".
text(Pieces, Max) ->
    Names = [pick(Pieces) || _ <- lists:seq(1, rand:uniform(Max + 1) - 1)],
    Joined = lists:join(fun() -> pick([<<"/">>, <<"/">>, <<"/">>, <<"//">>]) end, Names),
    Lead = pick([<<>>, <<>>, <<"/">>]),
    Trail = pick([<<>>, <<>>, <<>>, <<"/">>]),
    iolist_to_binary([Lead, [call(Piece) || Piece <- Joined], Trail]).

call(Fun) when is_function(Fun) -> Fun();
call(Piece) -> Piece.

%% A path of arbitrary bytes: refused exactly as the design says, and any
%% other path resolved without a crash.
raw_path(Tree, Table, Cwd) ->
    Path = raw_bytes(),
    Flags = #{follow => true, willbedir => false},
    Callbacks = checking(Table, answers(Tree), false),
    Got = outcome(erx_path:resolve(Path, lookup, Flags, Table, Cwd, Callbacks), Tree, Flags, Table),
    case refusal(Path) of
        none -> ok;
        Refusal when Got =:= {error, Refusal} -> ok;
        Refusal -> erlang:error({raw_path, Path, Refusal, Got})
    end.

raw_bytes() ->
    case rand:uniform(20) of
        1 -> binary:copy(<<"a/">>, 2048);
        2 -> <<"/", (binary:copy(<<"n">>, 256))/binary>>;
        3 -> iolist_to_binary(lists:join(<<"/">>, lists:duplicate(257, <<"a">>)));
        _ -> iolist_to_binary([pick([<<0>>, <<255>>, <<"/">>, <<"a">>, <<".">>, <<16#c3, 16#a9>>,
                                     <<16#c3>>, <<16#ed, 16#a0, 16#80>>])
                               || _ <- lists:seq(1, rand:uniform(12) - 1)])
    end.

%% What the design refuses a path for before it reads a name, checked here
%% independently of erx_path: too long with its NUL, empty, not UTF-8 or
%% holding a NUL. A path of more than 256 names, or with a name over 255
%% bytes, is refused once its names are read, so whatever lies before them.
refusal(Path) when byte_size(Path) >= 4096 -> enametoolong;
refusal(<<>>) -> enoent;
refusal(Path) ->
    Names = [N || N <- binary:split(Path, <<"/">>, [global]), N =/= <<>>],
    case unicode:characters_to_binary(Path) =:= Path andalso binary:match(Path, <<0>>) =:= nomatch of
        false -> einval;
        true when length(Names) > 256 -> enametoolong;
        true ->
            case lists:any(fun(N) -> byte_size(N) > 255 end, Names) of
                true -> enametoolong;
                false -> none
            end
    end.

%% A link whose text is arbitrary bytes, met before the last name.
raw_link() ->
    Text = case rand:uniform(10) of
               1 -> binary:copy(<<"t">>, 4093 + rand:uniform(3));
               _ -> raw_bytes()
           end,
    Tree = erx_path_tree:new(#{<<"l">> => {link, Text}, <<"a">> => #{}}),
    Table = [#{point => [], root => [], provider => release}],
    Flags = #{follow => true, willbedir => false},
    Callbacks = checking(Table, answers(Tree), false),
    Got = outcome(erx_path:resolve(<<"/l/a">>, lookup, Flags, Table, [], Callbacks), Tree, Flags,
                  Table),
    Expected = case Text of
                   <<>> -> {error, enoent};
                   _ when byte_size(Text) + 3 > 4096 -> {error, enametoolong};
                   _ ->
                       case refusal(Text) of
                           einval -> {error, einval};
                           _ -> any
                       end
               end,
    case Expected of
        any -> ok;
        Got -> ok;
        _ -> erlang:error({raw_text, Text, Expected, Got})
    end.

%% Walk and link replies of any shape, and a caller that resumes with them.
hostile(Table, Cwd) ->
    Path = path(),
    Op = pick([lookup, create, delete, rename]),
    Flags = #{follow => rand:uniform(2) =:= 1, willbedir => rand:uniform(2) =:= 1},
    Callbacks = checking(Table, {fun(_) -> hostile_reply() end, fun(_) -> hostile_text() end},
                         false),
    hostile_drive(erx_path:resolve(Path, Op, Flags, Table, Cwd, Callbacks), Table, 200).

hostile_drive(_, _, 0) ->
    erlang:error(unbounded);
hostile_drive({target, _, _, Resume} = Action, Table, Fuel) ->
    checked_action(Action, Table),
    hostile_drive(Resume(hostile_reply()), Table, Fuel - 1);
hostile_drive({parent, _, _, _, Resume} = Action, Table, Fuel) ->
    checked_action(Action, Table),
    hostile_drive(Resume(hostile_reply()), Table, Fuel - 1);
hostile_drive(Outcome, Table, _) ->
    check_outcome(Outcome, Table).

hostile_reply() ->
    Kinds = [pick([directory, directory, directory, link, other, file, "directory"])
             || _ <- lists:seq(1, rand:uniform(6) - 1)],
    Ending = pick([ok, ok, {error, enoent}, {error, enotdir}, {error, "eio"}, error, {ok}]),
    pick([{Kinds, Ending}, {Kinds, Ending}, {Kinds, Ending}, Kinds, {[directory | link], ok}]).

hostile_text() ->
    pick([{ok, raw_bytes()}, {ok, text(?NAMES ++ [<<"..">>], 3)}, {ok, text(?NAMES, 3)},
          {error, eio}, {error, "x"}, {ok, "text"}, nonsense]).

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
