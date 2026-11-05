%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Runs one set of prim_file calls and prints each result on a line,
%% `<key>\t<term>`, so that a run over the release file system and a run of
%% stock's prim_file over the same files unpacked can be compared line by
%% line. Root is the tree's top: `/` in an archive, a host directory for stock.
%% test/integration/runtime_prim_file_test.rb names what may differ.
-module(prim_file_compare).
-export([main/1]).

-include_lib("kernel/include/file.hrl").

main([_, "seeded", Seed]) ->
    seeded(Seed),
    erlang:halt(0);
main([PrefixText, Mode]) ->
    Prefix = case PrefixText of
                 "/" -> <<>>;
                 _ -> list_to_binary(PrefixText)
             end,
    ok = prim_file:set_cwd(<<Prefix/binary, "/corpus">>),
    [call(Prefix, Op, Path) || Path <- paths(Prefix), Op <- operations()],
    cwd(Prefix),
    loader(Prefix),
    pins(Mode),
    namespace(Mode),
    remote(Mode),
    resources(),
    io:format("end\tok~n"),
    erlang:halt(0).

operations() ->
    [read_file, file_info, link_info, read_link, list_dir, handle, set_cwd].

%% Relative paths run from Prefix/corpus; absolute ones carry Prefix.
paths(Prefix) ->
    Over = binary:copy(<<"n">>, 256),
    Named = binary:copy(<<"n">>, 255),
    Deep = binary:copy(<<"n/">>, 2100),
    Tall = binary:copy(<<"nnnnnnnnnn/">>, 100),
    [<<"a.txt">>, <<"./a.txt">>, <<"sub/../a.txt">>, <<"sub/./deep/../../a.txt">>,
     <<"empty">>, <<"big.bin">>, <<"sub">>, <<"sub/">>, <<"sub/b.txt">>,
     <<"sub/deep/c.txt">>, <<"sub-x">>, <<"sub0">>, <<"sub/deep">>, <<"sub//b.txt">>,
     <<".">>, <<"..">>, <<"../corpus">>, <<"../corpus/a.txt">>,
     <<"missing">>, <<"missing/x">>, <<"sub/missing">>, <<"a.txt/x">>, <<"a.txt/x/y">>,
     <<"su">>, <<"sub-">>, <<"subz">>, <<>>,
     Named, Over, <<"sub/", Over/binary>>, Deep,
     <<Prefix/binary, "/corpus">>, <<Prefix/binary, "/corpus/a.txt">>,
     <<Prefix/binary, "/corpus/sub/deep/c.txt">>, <<Prefix/binary, "/corpus/missing">>,
     <<255, 254>>,
     %% The named differences.
     <<"a.txt/.">>, <<"a.txt/">>, <<"a.txt/../sub/b.txt">>,
     <<"missing/../a.txt">>, <<"missing/../sub/b.txt">>, <<"missing/", Over/binary>>,
     <<Tall/binary, "x">>].

call(Prefix, Op, Path) ->
    Result = try op(Op, Path)
             catch Class:Reason -> {raised, Class, Reason}
             end,
    io:format("~s ~s\t~0tp~n", [Op, hex(display(Prefix, Path)), named(Prefix, Result)]).

op(read_file, Path) ->
    case prim_file:read_file(Path) of
        {ok, Bytes} -> {ok, byte_size(Bytes), erlang:md5(Bytes)};
        Other -> Other
    end;
op(file_info, Path) -> info(prim_file:read_file_info(Path));
op(link_info, Path) -> info(prim_file:read_link_info(Path));
op(read_link, Path) -> prim_file:read_link(Path);
op(list_dir, Path) ->
    case prim_file:list_dir(Path) of
        {ok, Names} -> {ok, lists:sort(Names)};
        Other -> Other
    end;
op(handle, Path) ->
    case prim_file:open(Path, [read, binary]) of
        {ok, File} ->
            Steps = [prim_file:read(File, 7),
                     prim_file:position(File, {cur, 0}),
                     prim_file:position(File, {eof, -3}),
                     prim_file:read(File, 10),
                     prim_file:read(File, 10),
                     prim_file:pread(File, 2, 5),
                     prim_file:pread(File, 90000, 8192),
                     prim_file:pread(File, 1000000, 5),
                     prim_file:position(File, {bof, 90000}),
                     prim_file:read(File, 20000),
                     prim_file:position(File, {cur, -5}),
                     prim_file:position(File, -1),
                     prim_file:position(File, {cur, 5000000}),
                     prim_file:read(File, 1),
                     info(prim_file:read_handle_info(File))],
            Closed = prim_file:close(File),
            Again = prim_file:close(File),
            {[digest(Step) || Step <- Steps], Closed, Again};
        Other -> Other
    end;
op(set_cwd, Path) ->
    {ok, Before} = prim_file:get_cwd(),
    Result = prim_file:set_cwd(Path),
    {ok, After} = prim_file:get_cwd(),
    ok = prim_file:set_cwd(Before),
    {Result, {cwd, After}}.

digest({ok, Bytes}) when is_binary(Bytes), byte_size(Bytes) > 64 ->
    {ok, byte_size(Bytes), erlang:md5(Bytes)};
digest(Other) -> Other.

%% What stock and the archive share of file information. A directory's size is
%% the host file system's own, and links, owner, group, inode and times are the
%% host's; `pins/1` holds the provider to its fixed values.
info({ok, #file_info{type = regular, size = Size, access = Access, mode = Mode}}) ->
    {ok, regular, Size, Access, Mode};
info({ok, #file_info{type = Type, access = Access, mode = Mode}}) ->
    {ok, Type, Access, Mode};
info(Other) -> Other.

%% An absolute path shows as ROOT and the rest; a long path as its hash.
display(Prefix, Path) ->
    Size = byte_size(Prefix),
    case Path of
        <<Prefix:Size/binary, "/", Rest/binary>> -> <<"ROOT/", Rest/binary>>;
        _ when byte_size(Path) > 64 -> erlang:md5(Path);
        _ -> Path
    end.

hex(Binary) -> [io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Binary].

%% A working directory shows as ROOT and the rest.
named(Prefix, {Result, {cwd, Cwd}}) -> {Result, named_cwd(Prefix, Cwd)};
named(_Prefix, Result) -> Result.

named_cwd(Prefix, Cwd) ->
    Size = byte_size(Prefix),
    case list_to_binary(Cwd) of
        <<Prefix:Size/binary, "/">> -> <<"ROOT">>;
        <<Prefix:Size/binary, Rest/binary>> -> <<"ROOT", Rest/binary>>;
        Other -> Other
    end.

cwd(Prefix) ->
    {ok, Cwd} = prim_file:get_cwd(),
    io:format("get_cwd\t~0tp~n", [named_cwd(Prefix, Cwd)]),
    ok = prim_file:set_cwd(<<"sub/deep">>),
    {ok, Deep} = prim_file:get_cwd(),
    io:format("get_cwd_deep\t~0tp~n", [named_cwd(Prefix, Deep)]),
    io:format("relative_after_cd\t~0tp~n", [op(read_file, <<"c.txt">>)]),
    ok = prim_file:set_cwd(Cwd).

%% What erl_prim_loader calls, through erl_prim_loader.
loader(Prefix) ->
    File = binary_to_list(<<Prefix/binary, "/corpus/a.txt">>),
    Directory = binary_to_list(<<Prefix/binary, "/corpus/sub">>),
    Missing = binary_to_list(<<Prefix/binary, "/corpus/missing">>),
    {ok, Bytes, _} = erl_prim_loader:get_file(File),
    {ok, Names} = erl_prim_loader:list_dir(Directory),
    {ok, Regular} = erl_prim_loader:read_file_info(File),
    {ok, Linked} = erl_prim_loader:read_link_info(File),
    {ok, Cwd} = erl_prim_loader:get_cwd(),
    io:format("loader_get_file\t~0tp~n", [Bytes]),
    io:format("loader_list_dir\t~0tp~n", [lists:sort(Names)]),
    io:format("loader_file_info\t~0tp~n", [info({ok, Regular})]),
    io:format("loader_link_info\t~0tp~n", [info({ok, Linked})]),
    io:format("loader_cwd\t~0tp~n", [named_cwd(Prefix, Cwd)]),
    io:format("loader_missing\t~0tp~n", [erl_prim_loader:get_file(Missing)]).

%% Only the release has erx_ns. A grant's paths reach erx_file_remote, over a grant of
%% erx_fs_test_tree, and leave with the entry; a grant whose process ended answers eio; fids are drawn
%% one after another.
namespace("stock") -> ok;
namespace("release") ->
    Show = fun(Step, Result) -> io:format("ns ~s\t~0tp~n", [Step, Result]) end,
    Show("before", prim_file:read_file_info(<<"/tmp/a">>)),
    Show("mount", erx_ns:mount(test_grant(), <<"/tmp">>, [{tree, <<"test">>}, rw])),
    Show("info", info(prim_file:read_file_info(<<"/tmp/a">>))),
    Show("read", prim_file:read_file(<<"/tmp/a">>)),
    Show("again", erx_ns:mount(self(), <<"/tmp/">>, [{tree, <<"tmp">>}])),
    Show("bad tree", erx_ns:mount(self(), <<"/x">>, [{tree, <<"a/b">>}])),
    Show("bind", erx_ns:bind(<<"/tmp/a">>, <<"/b">>, [ro])),
    Show("bound", info(prim_file:read_file_info(<<"/b/f">>))),
    Show("unmount", erx_ns:unmount(<<"/tmp">>)),
    Show("after", prim_file:read_file_info(<<"/tmp/a">>)),
    Show("root", erx_ns:unmount(<<"/">>)),
    {Gone, Ref} = spawn_monitor(fun() -> receive stop -> ok end end),
    Show("mount gone", erx_ns:mount(Gone, <<"/gone">>, [{tree, <<"t">>}])),
    Gone ! stop,
    receive {'DOWN', Ref, process, Gone, _} -> ok end,
    Show("gone", ended(<<"/gone/x">>, 100)),
    Show("unmount gone", erx_ns:unmount(<<"/gone">>)),
    Show("unmount bound", erx_ns:unmount(<<"/b">>)),
    two_paths(Show),
    First = prim_file:erx_fid(),
    Show("fids", {is_integer(First), prim_file:erx_fid() - First}).

%% A read-only bind of a writable grant reaches erx_file_remote read-only, with the
%% grant's tree; a rename or a link reaches it only when both paths lie on one grant's
%% tree through one set of rights, and is exdev otherwise, before any server is asked.
%% erx_file_remote is traced, so each step shows what reached it, or none.
two_paths(Show) ->
    Reached = fun(Call) -> reached(Call) end,
    ok = erx_ns:mount(test_grant(), <<"/tmp">>, [{tree, <<"test">>}, rw]),
    ok = erx_ns:mount(test_grant(), <<"/u">>, [{tree, <<"u">>}, rw]),
    ok = erx_ns:bind(<<"/tmp/a">>, <<"/ro">>, [ro]),
    {module, erx_file_remote} = code:ensure_loaded(erx_file_remote),
    _ = erlang:trace_pattern({erx_file_remote, '_', '_'}, true, []),
    Show("ro bind", Reached(fun() -> prim_file:read_file_info(<<"/ro/c">>) end)),
    Show("rw mount", Reached(fun() -> prim_file:make_dir(<<"/tmp/c">>) end)),
    Show("rename one", Reached(fun() -> prim_file:rename(<<"/tmp/x">>, <<"/tmp/a/y">>) end)),
    Show("rename two", Reached(fun() -> prim_file:rename(<<"/tmp/x">>, <<"/u/y">>) end)),
    Show("rename ro", Reached(fun() -> prim_file:rename(<<"/tmp/a/x">>, <<"/ro/y">>) end)),
    Show("rename local", Reached(fun() -> prim_file:rename(<<"/tmp/x">>, <<"/lib/y">>) end)),
    Show("link one", Reached(fun() -> prim_file:make_link(<<"/u/x">>, <<"/u/y">>) end)),
    Show("link two", Reached(fun() -> prim_file:make_link(<<"/u/x">>, <<"/tmp/y">>) end)),
    _ = erlang:trace_pattern({erx_file_remote, '_', '_'}, false, []),
    [ok = erx_ns:unmount(Point) || Point <- [<<"/ro">>, <<"/u">>, <<"/tmp">>]],
    ok.

%% The operation's answer and the call that reached erx_file_remote, its pid left out.
%% The operation runs in a process of its own, traced by this one: ERTS sends a
%% process no trace message of its own calls.
reached(Operation) ->
    Parent = self(),
    {Runner, Monitor} = spawn_monitor(fun() -> receive go -> Parent ! {self(), Operation()} end end),
    1 = erlang:trace(Runner, true, [call]),
    Runner ! go,
    Result = receive
                 {Runner, Answer} -> Answer;
                 {'DOWN', Monitor, process, Runner, Reason} -> {died, Reason}
             end,
    Delivered = erlang:trace_delivered(Runner),
    receive {trace_delivered, Runner, Delivered} -> ok end,
    receive
        {trace, Runner, call, {erx_file_remote, Function, [{Pid, Tree, Rights} | Rest]}}
          when is_pid(Pid) ->
            {Result, Function, Tree, Rights, Rest}
    after 0 -> {Result, none}
    end.

%% The NIF learns of a process's end on its own monitor, so it may answer a moment later.
ended(Path, 0) -> prim_file:read_file_info(Path);
ended(Path, Tries) ->
    case prim_file:read_file_info(Path) of
        {error, eio} = Ended -> Ended;
        _ -> receive after 10 -> ended(Path, Tries - 1) end
    end.

%% Only the release answers these: its fixed values and its refusals.
pins("stock") -> ok;
pins("release") ->
    {ok, #file_info{links = Links, major_device = Major, minor_device = Minor,
                    inode = Inode, uid = Uid, gid = Gid, atime = Atime,
                    mtime = Mtime, ctime = Ctime}} =
        prim_file:read_file_info(<<"a.txt">>, [{time, posix}]),
    io:format("pin info\t~0tp~n", [{Links, Major, Minor, Inode, Uid, Gid, Atime, Mtime, Ctime}]),
    {ok, Top} = prim_file:read_file_info(<<"/">>, [{time, posix}]),
    io:format("pin top\t~0tp~n", [{Top#file_info.type, Top#file_info.mode band 8#777,
                                   Top#file_info.size, Top#file_info.links}]),
    {ok, Open} = prim_file:open(<<"a.txt">>, [read, binary]),
    io:format("pin advise\t~0tp~n", [prim_file:advise(Open, 0, 0, normal)]),
    io:format("pin allocate\t~0tp~n", [prim_file:allocate(Open, 0, 0)]),
    io:format("pin sync\t~0tp~n", [prim_file:sync(Open)]),
    io:format("pin write\t~0tp~n", [prim_file:write(Open, <<"x">>)]),
    ok = prim_file:close(Open),
    Refused = [{open_write, prim_file:open(<<"a.txt">>, [write])},
               {open_new, prim_file:open(<<"new">>, [write])},
               {open_append, prim_file:open(<<"a.txt">>, [append])},
               {make_dir, prim_file:make_dir(<<"new">>)},
               {delete, prim_file:delete(<<"a.txt">>)},
               {del_dir, prim_file:del_dir(<<"sub">>)},
               {rename, prim_file:rename(<<"a.txt">>, <<"b.txt">>)},
               {make_link, prim_file:make_link(<<"a.txt">>, <<"l">>)},
               {make_symlink, prim_file:make_symlink(<<"a.txt">>, <<"s">>)},
               {write_file_info, prim_file:write_file_info(<<"a.txt">>, #file_info{mode = 8#600})},
               {open_directory, prim_file:open(<<"sub">>, [read, directory])},
               {altname, prim_file:altname(<<"a.txt">>)}],
    [io:format("pin ~s\t~0tp~n", [Name, Result]) || {Name, Result} <- Refused],
    %% Modules came from the archive.
    Beams = [code:which(lists), code:which(file), code:which(compile)],
    io:format("pin code\t~0tp~n", [Beams]),
    io:format("pin load\t~0tp~n", [code:ensure_loaded(compile)]),
    ok.

%% A resource's allocation shows in binary memory, which every leak of one grows.
resources() ->
    Before = settled(),
    loop(10000, fun() -> {ok, _} = prim_file:read_file(<<"a.txt">>) end),
    AfterRead = settled(),
    loop(10000, fun() ->
                        {ok, File} = prim_file:open(<<"a.txt">>, [read, binary]),
                        ok = prim_file:close(File)
                end),
    AfterOpen = settled(),
    io:format("resources\t~w ~w~n", [AfterRead - Before, AfterOpen - AfterRead]).

settled() ->
    erlang:garbage_collect(),
    receive after 50 -> ok end,
    erlang:garbage_collect(),
    erlang:memory(binary).

loop(0, _Fun) -> ok;
loop(Count, Fun) ->
    Fun(),
    loop(Count - 1, Fun).

%% A grant of erx_fs_test_tree, which test/integration/runtime_prim_file_test.rb compiles
%% into test/ebin with erx_fs: / holds a/ (with b/ and f), the link l -> "a" and f.
test_grant() ->
    {ok, Grant} = erx_fs:start_link(erx_fs_test_tree, [], rw),
    unlink(Grant),
    Grant.

%% erx_file_remote's path operations through prim_file, on a grant mounted at /t and
%% bound read-only at /r (design-files.md, Erlang clients): each operation's success, the
%% error steps, the #file_info{} mapping, the refusals of a read-only entry and replies a
%% hostile server sends. Each line is `remote <case>`; the Ruby test names the answers.
remote("stock") -> ok;
remote("release") ->
    Grant = test_grant(),
    ok = erx_ns:mount(Grant, <<"/t">>, [{tree, <<"test">>}, rw]),
    ok = erx_ns:bind(<<"/t">>, <<"/r">>, [ro]),
    Show = fun(Case, Result) -> io:format("remote ~s\t~0tp~n", [Case, Result]) end,
    Info = fun(Path) -> info(prim_file:read_file_info(Path)) end,
    Show("info dir", Info(<<"/t/a">>)),
    Show("info file", Info(<<"/t/f">>)),
    Show("info root", Info(<<"/t">>)),
    Show("info missing", Info(<<"/t/missing">>)),
    Show("info past a file", Info(<<"/t/f/x">>)),
    Show("info link", info(prim_file:read_link_info(<<"/t/l">>))),
    Show("info through a link", Info(<<"/t/l">>)),
    Show("info fields", fields(prim_file:read_file_info(<<"/t/a/f">>, [{time, posix}]))),
    Show("info same device", same_device(<<"/t/a">>, <<"/r/f">>)),
    Show("read link", prim_file:read_link(<<"/t/l">>)),
    Show("read link of a file", prim_file:read_link(<<"/t/f">>)),
    Show("list", sorted(prim_file:list_dir(<<"/t">>))),
    Show("list a file", prim_file:list_dir(<<"/t/f">>)),
    Show("list missing", prim_file:list_dir(<<"/t/missing">>)),
    Show("make dir", prim_file:make_dir(<<"/t/new">>)),
    Show("made dir", Info(<<"/t/new">>)),
    Show("make dir again", prim_file:make_dir(<<"/t/new">>)),
    Show("make dir in missing", prim_file:make_dir(<<"/t/missing/x">>)),
    Show("make dir dot", prim_file:make_dir(<<"/t/new/.">>)),
    Show("make dir missing dotdot", prim_file:make_dir(<<"/t/missing/..">>)),
    Show("make dir root", prim_file:make_dir(<<"/t">>)),
    Show("del dir full", prim_file:del_dir(<<"/t/a">>)),
    Show("del dir dot", prim_file:del_dir(<<"/t/new/.">>)),
    Show("del dir missing dot", prim_file:del_dir(<<"/t/missing/.">>)),
    Show("del dir file dot", prim_file:del_dir(<<"/t/f/.">>)),
    Show("del dir dotdot", prim_file:del_dir(<<"/t/a/b/..">>)),
    Show("del dir root", prim_file:del_dir(<<"/t">>)),
    Show("del dir file", prim_file:del_dir(<<"/t/f">>)),
    Show("del dir", prim_file:del_dir(<<"/t/new">>)),
    Show("del dir gone", Info(<<"/t/new">>)),
    Show("delete file dot", prim_file:delete(<<"/t/f/.">>)),
    Show("delete dir dot", prim_file:delete(<<"/t/a/.">>)),
    Show("delete dir", prim_file:delete(<<"/t/a">>)),
    Show("delete root", prim_file:delete(<<"/t">>)),
    Show("symlink", prim_file:make_symlink(<<"f">>, <<"/t/victim">>)),
    Show("symlink made", prim_file:read_link(<<"/t/victim">>)),
    Show("delete victim", prim_file:delete(<<"/t/missing/victim">>)),
    Show("victim kept", prim_file:read_link(<<"/t/victim">>)),
    Show("delete link", prim_file:delete(<<"/t/victim">>)),
    Show("link deleted", prim_file:read_link_info(<<"/t/victim">>)),
    Show("symlink dot", prim_file:make_symlink(<<"t">>, <<"/t/a/.">>)),
    Show("symlink missing dotdot", prim_file:make_symlink(<<"t">>, <<"/t/missing/..">>)),
    Show("symlink root", prim_file:make_symlink(<<"t">>, <<"/t">>)),
    Show("rename", prim_file:rename(<<"/t/a/b">>, <<"/t/c">>)),
    Show("renamed", {Info(<<"/t/a/b">>), Info(<<"/t/c">>)}),
    Show("rename missing", prim_file:rename(<<"/t/missing">>, <<"/t/d">>)),
    Show("rename from dot", prim_file:rename(<<"/t/c/.">>, <<"/t/d">>)),
    Show("rename to dot", prim_file:rename(<<"/t/missing">>, <<"/t/a/.">>)),
    Show("rename missing dot", prim_file:rename(<<"/t/missing/.">>, <<"/t/d">>)),
    Show("rename root", prim_file:rename(<<"/t">>, <<"/t/d">>)),
    Show("link", prim_file:make_link(<<"/t/f">>, <<"/t/f2">>)),
    Show("linked", {Info(<<"/t/f2">>), Info(<<"/t/f">>)}),
    Show("link dot", prim_file:make_link(<<"/t/f">>, <<"/t/a/.">>)),
    Show("link missing to dot", prim_file:make_link(<<"/t/missing">>, <<"/t/a/.">>)),
    Show("link missing", prim_file:make_link(<<"/t/missing">>, <<"/t/g">>)),
    Show("link a directory", prim_file:make_link(<<"/t/a">>, <<"/t/g">>)),
    Show("link root", prim_file:make_link(<<"/t/f">>, <<"/t">>)),
    {ok, Read} = prim_file:read_file_info(<<"/t/f">>),
    Show("write info read", prim_file:write_file_info(<<"/t/f">>, Read)),
    Show("write mode", prim_file:write_file_info(<<"/t/f">>, #file_info{mode = 8#104600})),
    Show("written mode", Info(<<"/t/f">>)),
    Show("write bad mode", prim_file:write_file_info(<<"/t/f">>, #file_info{mode = x})),
    Show("write missing", prim_file:write_file_info(<<"/t/missing">>, #file_info{mode = 8#600})),
    Show("ro info", Info(<<"/r/f">>)),
    Show("ro make dir", prim_file:make_dir(<<"/r/x">>)),
    Show("ro del dir", prim_file:del_dir(<<"/r/a">>)),
    Show("ro delete", prim_file:delete(<<"/r/f">>)),
    Show("ro rename", prim_file:rename(<<"/r/f">>, <<"/r/g">>)),
    Show("ro link", prim_file:make_link(<<"/r/f">>, <<"/r/g">>)),
    Show("ro symlink", prim_file:make_symlink(<<"f">>, <<"/r/g">>)),
    Show("ro write info", prim_file:write_file_info(<<"/r/f">>, #file_info{mode = 8#600})),
    Show("ro kept", {Info(<<"/t/f">>), Info(<<"/t/a">>)}),
    Show("exdev rename", prim_file:rename(<<"/t/f">>, <<"/r/g">>)),
    Show("exdev link", prim_file:make_link(<<"/t/f">>, <<"/r/g">>)),
    open_files(Show),
    Show("fids held", fids_held(Grant)),
    slashes(Show),
    links(Show),
    hostile(Show),
    [ok = erx_ns:unmount(Point) || Point <- [<<"/r">>, <<"/t">>]],
    ok.

%% A path written with a trailing "/" on a grant names a directory, as Linux's path
%% resolution has it, on a fresh tree mounted at /s: a last name that is not a directory
%% answers enotdir, a link before the "/" is followed, and make_dir and del_dir act as
%% they do without it.
slashes(Show) ->
    Grant = test_grant(),
    ok = erx_ns:mount(Grant, <<"/s">>, [{tree, <<"test">>}, rw]),
    Info = fun(Path) -> info(prim_file:read_file_info(Path)) end,
    Show("slash info file", Info(<<"/s/f/">>)),
    Show("slash info dir", Info(<<"/s/a/">>)),
    Show("slash link info", info(prim_file:read_link_info(<<"/s/l/">>))),
    Show("slash link info of a file", info(prim_file:read_link_info(<<"/s/f/">>))),
    Show("slash read link", prim_file:read_link(<<"/s/l/">>)),
    Show("slash list file", prim_file:list_dir(<<"/s/f/">>)),
    Show("slash write info", prim_file:write_file_info(<<"/s/f/">>, #file_info{mode = 8#600})),
    Show("slash delete file", prim_file:delete(<<"/s/f/">>)),
    Show("slash delete missing", prim_file:delete(<<"/s/missing/">>)),
    Show("slash delete dir", prim_file:delete(<<"/s/a/">>)),
    Show("slash delete link", prim_file:delete(<<"/s/l/">>)),
    Show("slash kept", {Info(<<"/s/f">>), info(prim_file:read_link_info(<<"/s/l">>))}),
    Show("slash make dir", prim_file:make_dir(<<"/s/d/">>)),
    Show("slash made dir", Info(<<"/s/d">>)),
    Show("slash del dir file", prim_file:del_dir(<<"/s/f/">>)),
    Show("slash del dir link", prim_file:del_dir(<<"/s/l/">>)),
    Show("slash rename file", prim_file:rename(<<"/s/f/">>, <<"/s/g">>)),
    Show("slash rename to", prim_file:rename(<<"/s/f">>, <<"/s/g/">>)),
    Show("slash rename missing", prim_file:rename(<<"/s/missing/">>, <<"/s/g">>)),
    Show("slash rename dir", prim_file:rename(<<"/s/d/">>, <<"/s/e/">>)),
    Show("slash renamed dir", {Info(<<"/s/d">>), Info(<<"/s/e">>)}),
    Show("slash del dir", prim_file:del_dir(<<"/s/e/">>)),
    Show("slash symlink new", prim_file:make_symlink(<<"f">>, <<"/s/n/">>)),
    Show("slash symlink existing", prim_file:make_symlink(<<"f">>, <<"/s/f/">>)),
    Show("slash hard link new", prim_file:make_link(<<"/s/f">>, <<"/s/h/">>)),
    Show("slash hard link existing", prim_file:make_link(<<"/s/f/">>, <<"/s/h">>)),
    Show("slash nothing made", {Info(<<"/s/n">>), Info(<<"/s/h">>)}),
    Show("slash fids held", fids_held(Grant)),
    ok = erx_ns:unmount(<<"/s">>).

%% Symbolic links on a grant (design-files.md, Resolving a path), on a fresh tree mounted
%% at /s, its directory a bound at /ba and the whole tree bound read-only at /sr: a
%% relative link resolves against its directory as a namespace path, an absolute one from
%% the namespace's root, into the same grant or out of it to the release, with the rights
%% of the entry it reaches; 40 links are followed and the 41st answers eloop; operations
%% that do not follow a last link act on the link.
links(Show) ->
    Grant = test_grant(),
    ok = erx_ns:mount(Grant, <<"/s">>, [{tree, <<"test">>}, rw]),
    ok = erx_ns:bind(<<"/s/a">>, <<"/ba">>, []),
    ok = erx_ns:bind(<<"/s">>, <<"/sr">>, [ro]),
    Info = fun(Path) -> info(prim_file:read_file_info(Path)) end,
    Show("link relative", Info(<<"/s/l">>)),
    Show("link relative through", Info(<<"/s/l/f">>)),
    Show("link relative list", sorted(prim_file:list_dir(<<"/s/l">>))),
    ok = prim_file:make_symlink(<<"/s/a/f">>, <<"/s/abs">>),
    Show("link absolute", Info(<<"/s/abs">>)),
    Show("link absolute read", prim_file:read_link(<<"/s/abs">>)),
    Show("link info", info(prim_file:read_link_info(<<"/s/abs">>))),
    ok = prim_file:make_symlink(<<"f">>, <<"/s/a/rf">>),
    Show("link in a bind", Info(<<"/ba/rf">>)),
    ok = prim_file:make_symlink(<<"../f">>, <<"/s/a/up">>),
    Show("link above a bind", {Info(<<"/s/a/up">>), Info(<<"/ba/up">>)}),
    ok = prim_file:make_symlink(<<"/lib">>, <<"/s/rel">>),
    Show("link to the release", same(<<"/s/rel">>, <<"/lib">>)),
    Show("link to the release list", same_listing(<<"/s/rel">>, <<"/lib">>)),
    Show("link out exdev", prim_file:rename(<<"/s/rel/x">>, <<"/s/y">>)),
    ok = prim_file:make_symlink(<<"missing">>, <<"/s/dangling">>),
    Show("link dangling", {Info(<<"/s/dangling">>), info(prim_file:read_link_info(<<"/s/dangling">>))}),
    ok = prim_file:make_symlink(<<"">>, <<"/s/empty">>),
    Show("link empty", Info(<<"/s/empty">>)),
    ok = prim_file:make_symlink(<<"loop">>, <<"/s/loop">>),
    Show("link loop", {Info(<<"/s/loop">>), Info(<<"/s/loop/x">>), prim_file:make_dir(<<"/s/loop/x">>)}),
    [ok = prim_file:make_symlink(<<"c", (integer_to_binary(N + 1))/binary>>,
                                 <<"/s/c", (integer_to_binary(N))/binary>>) || N <- lists:seq(0, 39)],
    ok = prim_file:make_symlink(<<"f">>, <<"/s/c40">>),
    Show("link forty", Info(<<"/s/c1">>)),
    Show("link forty one", Info(<<"/s/c0">>)),
    Show("link make dir through", {prim_file:make_dir(<<"/s/l/via">>), Info(<<"/s/a/via">>)}),
    Show("link rename through", {prim_file:rename(<<"/s/l/via">>, <<"/s/l/moved">>), Info(<<"/s/a/moved">>)}),
    Show("link del dir through", prim_file:del_dir(<<"/s/l/moved">>)),
    Show("link delete through", {prim_file:make_symlink(<<"f">>, <<"/s/a/x">>), prim_file:delete(<<"/s/l/x">>),
                                 prim_file:read_link_info(<<"/s/a/x">>)}),
    Show("link delete not followed", {prim_file:make_symlink(<<"f">>, <<"/s/a/y">>), prim_file:delete(<<"/s/a/y">>),
                                      Info(<<"/s/f">>)}),
    Show("link hard link not followed", {prim_file:make_link(<<"/s/l">>, <<"/s/l2">>),
                                         prim_file:read_link(<<"/s/l2">>)}),
    Show("link ro relative", prim_file:write_file_info(<<"/sr/l/f">>, #file_info{mode = 8#600})),
    Show("link ro absolute", prim_file:write_file_info(<<"/sr/abs">>, #file_info{mode = 8#600})),
    Show("link ro absolute written", Info(<<"/s/a/f">>)),
    Show("link ro delete", prim_file:delete(<<"/sr/l/f">>)),
    ok = prim_file:make_symlink(<<"/s/a">>, <<"/s/wa">>),
    Show("link ro to writable", {prim_file:make_dir(<<"/sr/wa/new">>), Info(<<"/s/a/new">>),
                                 prim_file:del_dir(<<"/sr/wa/new">>), prim_file:make_dir(<<"/sr/missing/x">>)}),
    Deep = lists:foldl(fun(N, Dir) ->
                               Next = <<Dir/binary, "/d", (integer_to_binary(N))/binary>>,
                               ok = prim_file:make_dir(Next),
                               Next
                       end, <<"/s">>, lists:seq(1, 15)),
    ok = prim_file:make_symlink(<<"/s/a">>, <<Deep/binary, "/lk">>),
    Show("link sixteenth name", Info(<<Deep/binary, "/lk/f">>)),
    Show("link fids held", fids_held(Grant)),
    [ok = erx_ns:unmount(Point) || Point <- [<<"/sr">>, <<"/ba">>, <<"/s">>]],
    ok.

same(One, Other) ->
    case {prim_file:read_file_info(One), prim_file:read_file_info(Other)} of
        {{ok, Info}, {ok, Info}} -> true;
        Answers -> Answers
    end.

same_listing(One, Other) ->
    case {sorted(prim_file:list_dir(One)), sorted(prim_file:list_dir(Other))} of
        {{ok, Names}, {ok, Names}} when Names =/= [] -> true;
        Answers -> Answers
    end.

%% Every fid an operation made is clunked by its end: the grant monitors no owner.
fids_held(Grant) ->
    {monitors, Monitors} = process_info(Grant, monitors),
    length(Monitors).

fields({ok, #file_info{size = Size, links = Links, inode = Inode, uid = Uid, gid = Gid,
                       minor_device = Minor, atime = ATime, mtime = MTime}}) ->
    {Size, Links, Inode, Uid, Gid, Minor, is_integer(ATime), is_integer(MTime)};
fields(Other) ->
    Other.

same_device(One, Other) ->
    case {prim_file:read_file_info(One), prim_file:read_file_info(Other)} of
        {{ok, #file_info{major_device = A}}, {ok, #file_info{major_device = B}}} -> A =:= B;
        Answers -> Answers
    end.

sorted({ok, Names}) -> {ok, lists:sort(Names)};
sorted(Other) -> Other.

%% A server's replies are untrusted: whatever it answers, the caller gets an error and
%% goes on.
hostile(Show) ->
    Server = fun(Reply) ->
                     spawn(fun Loop() ->
                                   receive
                                       {erx_9p, Alias, _, Request} ->
                                           Alias ! {erx_9p, Alias, Reply(Request)},
                                           Loop()
                                   end
                           end)
             end,
    Cases = [{"junk", fun(_) -> junk end},
             {"bad qid", fun({attach, _, _, _, _, _}) -> {ok, {0, 0, -1}}; (_) -> ok end},
             {"improper qids", fun({attach, _, _, _, _, _}) -> {ok, {16#80, 0, 1}};
                                  ({walk, _, _, _}) -> {ok, [{16#80, 0, 2} | x]};
                                  (_) -> ok end},
             {"long walk", fun({attach, _, _, _, _, _}) -> {ok, {16#80, 0, 1}};
                              ({walk, _, _, _}) -> {ok, lists:duplicate(20, {16#80, 0, 2})};
                              (_) -> ok end},
             {"attr", fun({attach, _, _, _, _, _}) -> {ok, {16#80, 0, 1}};
                         ({walk, _, _, Names}) -> {ok, [{16#80, 0, 2} || _ <- Names]};
                         ({getattr, _, _}) -> {ok, #{mode => -1}};
                         (_) -> ok end},
             {"endless links", fun({attach, _, _, _, _, _}) -> {ok, {16#80, 0, 1}};
                                  ({walk, _, _, Names}) -> {ok, [{2, 0, 2} || _ <- Names]};
                                  ({readlink, _}) -> {ok, <<"x">>};
                                  (_) -> ok end},
             {"link attr", fun({attach, _, _, _, _, _}) -> {ok, {16#80, 0, 1}};
                              ({walk, _, _, Names}) -> {ok, [{0, 0, 2} || _ <- Names]};
                              ({getattr, _, _}) -> {ok, link_attr()};
                              (_) -> ok end},
             {"bad link", fun({attach, _, _, _, _, _}) -> {ok, {16#80, 0, 1}};
                             ({walk, _, _, Names}) -> {ok, [{2, 0, 2} || _ <- Names]};
                             ({readlink, _}) -> {ok, <<"a", 0, "b">>};
                             (_) -> ok end}],
    [begin
         ok = erx_ns:mount(Server(Reply), <<"/h">>, [{tree, <<"h">>}, rw]),
         Show("hostile " ++ Name, prim_file:read_file_info(<<"/h/x">>)),
         ok = erx_ns:unmount(<<"/h">>)
     end || {Name, Reply} <- Cases],
    Escaping = Server(fun({attach, _, _, _, _, _}) -> {ok, {16#80, 0, 1}};
                         ({walk, _, _, Names}) -> {ok, [{16#80, 0, 2} || _ <- Names]};
                         ({lopen, _, _}) -> {ok, {16#80, 0, 2}, 0};
                         ({readdir, _, 0, _}) -> {ok, [{{0, 0, 3}, 1, 0, <<"../../x">>}]};
                         (_) -> ok end),
    LinkAttr = Server(fun({attach, _, _, _, _, _}) -> {ok, {16#80, 0, 1}};
                         ({walk, _, _, Names}) -> {ok, [{0, 0, 2} || _ <- Names]};
                         ({getattr, _, _}) -> {ok, link_attr()};
                         (_) -> ok end),
    ok = erx_ns:mount(LinkAttr, <<"/h">>, [{tree, <<"h">>}, rw]),
    Show("hostile link attr info", info(prim_file:read_link_info(<<"/h/x">>))),
    ok = erx_ns:unmount(<<"/h">>),
    ok = erx_ns:mount(Escaping, <<"/h">>, [{tree, <<"h">>}, rw]),
    Show("hostile listing", prim_file:list_dir(<<"/h/d">>)),
    ok = erx_ns:unmount(<<"/h">>),
    Dying = spawn(fun() -> receive {erx_9p, _, _, _} -> exit(gone) end end),
    ok = erx_ns:mount(Dying, <<"/h">>, [{tree, <<"h">>}, rw]),
    Show("hostile dies", prim_file:make_dir(<<"/h/x">>)),
    ok = erx_ns:unmount(<<"/h">>).

%% A getattr reply that calls a file a link which the walk did not find as one.
link_attr() ->
    attr(8#120644, 0).

%% A getattr reply of every field, for a node of Mode and Size.
attr(Mode, Size) ->
    #{valid => 16#7ff, qid => {0, 0, 2}, mode => Mode, uid => 0, gid => 0, nlink => 1, rdev => 0,
      size => Size, blksize => 4096, blocks => 0, atime_sec => 0, atime_nsec => 0,
      mtime_sec => 0, mtime_nsec => 0, ctime_sec => 0, ctime_nsec => 0, btime_sec => 0,
      btime_nsec => 0, gen => 0, data_version => 0}.

%% Open files on a grant (design-files.md, Erlang clients, and Open files and offsets),
%% through file's descriptors, on the grant at /t, its read-only bind at /r and fresh
%% trees: the open modes and their refusals, reads, writes and positions, and the cases
%% of design-tmp.md's verification that the seeded runs repeat.
open_files(Show) ->
    Raw = fun(Path, Modes) -> file:open(Path, [raw, binary | Modes]) end,
    {ok, W} = Raw(<<"/t/o">>, [write]),
    Show("open write", {file:write(W, [<<"hel">>, "lo"]), file:position(W, cur)}),
    Show("read through a write fd", file:read(W, 1)),
    Show("close", {file:close(W), file:close(W), file:write(W, <<"x">>)}),
    Show("read file", prim_file:read_file(<<"/t/o">>)),
    {ok, R} = Raw(<<"/t/o">>, [read]),
    Show("read", {file:read(R, 3), file:read(R, 10), file:read(R, 1), file:read(R, 0)}),
    Show("pread", {file:pread(R, 1, 2), file:pread(R, [{0, 1}, {9, 1}]), file:pread(R, -1, 1),
                   file:position(R, cur)}),
    Show("position", {file:position(R, {eof, -2}), file:read(R, 5), file:position(R, {cur, -10}),
                      file:position(R, bof), file:position(R, x)}),
    Show("pread none", {file:pread(R, 0, 0), file:pread(R, 0, -1), file:pread(R, [{0, 0}])}),
    Show("write through a read fd", {file:write(R, <<"x">>), file:pwrite(R, 0, <<"x">>)}),
    Show("truncate through a read fd", file:truncate(R)),
    Show("info of an open file", info(file:read_file_info(R))),
    Show("not on controlling process", elsewhere(fun() -> file:read(R, 1) end)),
    ok = file:close(R),
    {ok, P} = Raw(<<"/t/o">>, [read, write]),
    Show("pwrite", {file:pwrite(P, 1, <<"EL">>), file:position(P, cur),
                    file:pwrite(P, [{0, <<"H">>}, {5, <<"!">>}]), prim_file:read_file(<<"/t/o">>)}),
    Show("truncate", {file:position(P, 4), file:truncate(P), prim_file:read_file(<<"/t/o">>)}),
    Show("sync", {file:sync(P), file:datasync(P), file:advise(P, 0, 0, normal), file:allocate(P, 0, 1)}),
    ok = file:close(P),
    Show("write file", {prim_file:write_file(<<"/t/w">>, <<"one\r\ntwo\nthree">>), lines(<<"/t/w">>)}),
    Show("write file truncates", {prim_file:write_file(<<"/t/w">>, <<"x">>), prim_file:read_file(<<"/t/w">>)}),
    Show("open missing", Raw(<<"/t/missing">>, [read])),
    Show("open to write a directory", {Raw(<<"/t/w">>, [write, directory]), prim_file:read_file(<<"/t/w">>)}),
    Show("open a directory", Raw(<<"/t/a">>, [read])),
    Show("open a directory as one", closed(Raw(<<"/t/a">>, [read, directory]))),
    Show("open through a link", closed(Raw(<<"/t/l/f">>, [read]))),
    Show("open exclusive existing", Raw(<<"/t/w">>, [write, exclusive])),
    Show("open exclusive new", closed(Raw(<<"/t/x">>, [write, exclusive]))),
    Show("open exclusive a link", Raw(<<"/t/l">>, [write, exclusive])),
    Show("create in missing", Raw(<<"/t/missing/x">>, [write])),
    Show("create slashed", Raw(<<"/t/y/">>, [write])),
    Show("create a directory", Raw(<<"/t/a">>, [write])),
    Show("create the root", Raw(<<"/t">>, [write])),
    Show("ro open read", closed(Raw(<<"/r/w">>, [read]))),
    Show("ro open write", Raw(<<"/r/w">>, [write])),
    Show("ro create", Raw(<<"/r/new">>, [write])),
    Show("ro create in missing", Raw(<<"/r/missing/x">>, [write])),
    Show("ro exclusive", Raw(<<"/r/w">>, [write, exclusive])),
    {ok, RO} = Raw(<<"/r/w">>, [read]),
    Show("ro truncate", {file:truncate(RO), file:write(RO, <<"y">>)}),
    ok = file:close(RO),
    Show("ro unchanged", prim_file:read_file(<<"/t/w">>)),
    Show("io server", io_server(<<"/t/w">>)),
    appends(Show),
    past_the_cap(Show),
    split(Show),
    unknown_at(Show),
    grant_gone(Show).

closed({ok, Fd}) -> file:close(Fd);
closed(Other) -> Other.

%% What a call answers in another process, or the error it raises there.
elsewhere(Call) ->
    Self = self(),
    _ = spawn(fun() -> Self ! {elsewhere, try Call() catch error:Why -> {raised, Why} end} end),
    receive {elsewhere, Answer} -> Answer after 5000 -> timeout end.

lines(Path) ->
    {ok, Fd} = file:open(Path, [raw, binary, read]),
    Lines = read_lines(Fd, []),
    ok = file:close(Fd),
    Lines.

read_lines(Fd, Lines) ->
    case file:read_line(Fd) of
        {ok, Line} -> read_lines(Fd, [Line | Lines]);
        eof -> lists:reverse(Lines);
        Error -> Error
    end.

%% file:open without raw: file's io server opens the file and reads it for this process.
io_server(Path) ->
    {ok, Device} = file:open(Path, [read]),
    Answer = file:read(Device, 4),
    {Answer, file:close(Device)}.

%% A grant of erx_fs_test_tree with Args, mounted at Point.
mounted(Point, Args) ->
    {ok, Grant} = erx_fs:start_link(erx_fs_test_tree, Args, rw),
    unlink(Grant),
    ok = erx_ns:mount(Grant, Point, [{tree, <<"test">>}, rw]),
    Grant.

%% Two processes append one distinct byte each, many times, and after each write read the
%% byte before their offset, which must be their own (design-tmp.md, Appends).
appends(Show) ->
    _ = mounted(<<"/p">>, []),
    Self = self(),
    [spawn(fun() ->
                   {ok, Fd} = file:open(<<"/p/log">>, [raw, binary, append, read]),
                   Self ! {appended, Byte, own(Fd, Byte, 1000, 0)},
                   file:close(Fd)
           end) || Byte <- [$a, $b]],
    Own = lists:sort([receive {appended, Byte, Count} -> {Byte, Count} end || _ <- [1, 2]]),
    {ok, Log} = prim_file:read_file(<<"/p/log">>),
    Show("appends", {Own, byte_size(Log)}),
    ok = erx_ns:unmount(<<"/p">>).

own(_, _, 0, Own) ->
    Own;
own(Fd, Byte, Count, Own) ->
    ok = file:write(Fd, <<Byte>>),
    {ok, At} = file:position(Fd, cur),
    Mine = case file:pread(Fd, At - 1, 1) of
               {ok, <<Byte>>} -> 1;
               _ -> 0
           end,
    own(Fd, Byte, Count - 1, Own + Mine).

%% A 128 KiB write with room for 64 KiB: enospc, the first 64 KiB in the file and the
%% offset after them; then a positioned write past the cap, which writes nothing
%% (design-tmp.md, A write past the cap).
past_the_cap(Show) ->
    _ = mounted(<<"/c">>, [{cap, 100000}]),
    {ok, Fd} = file:open(<<"/c/f">>, [raw, binary, write]),
    Write = file:write(Fd, binary:copy(<<"x">>, 131072)),
    Position = file:position(Fd, cur),
    Positioned = file:pwrite(Fd, 99990, binary:copy(<<"y">>, 20)),
    ok = file:close(Fd),
    {ok, Data} = prim_file:read_file(<<"/c/f">>),
    Show("past the cap", {Write, Position, Positioned, byte_size(Data)}),
    ok = erx_ns:unmount(<<"/c">>).

%% A write over 64 KiB is several requests, each one write of the tree.
split(Show) ->
    _ = mounted(<<"/q">>, [{observer, self()}]),
    {ok, Fd} = file:open(<<"/q/f">>, [raw, binary, write]),
    _ = tree_calls(write),
    Bytes = << <<(N rem 251)>> || N <- lists:seq(1, 150000) >>,
    Write = file:write(Fd, Bytes),
    Requests = tree_calls(write),
    ok = file:close(Fd),
    Show("split", {Write, Requests, prim_file:read_file(<<"/q/f">>) =:= {ok, Bytes}}),
    ok = erx_ns:unmount(<<"/q">>).

%% How many of the observer's messages so far name Callback; all are taken.
tree_calls(Callback) ->
    receive
        {tree_call, Callback} -> 1 + tree_calls(Callback);
        {tree_call, _} -> tree_calls(Callback)
    after 0 ->
            0
    end.

%% A server outside erXos answers no At: through a fid without append, the offset moves
%% to where the write was sent plus its count; through an append fid, to the file's size
%% from a getattr after the reply.
unknown_at(Show) ->
    Server = spawn(fun Loop() ->
                           receive
                               {erx_9p, Alias, _, Request} ->
                                   Alias ! {erx_9p, Alias, foreign(Request)},
                                   Loop()
                           end
                   end),
    ok = erx_ns:mount(Server, <<"/u">>, [{tree, <<"u">>}, rw]),
    {ok, Plain} = file:open(<<"/u/x">>, [raw, binary, write]),
    PlainAt = {file:write(Plain, <<"abc">>), file:write(Plain, <<"de">>), file:position(Plain, cur)},
    {ok, Append} = file:open(<<"/u/x">>, [raw, binary, append]),
    AppendAt = {file:write(Append, <<"abc">>), file:position(Append, cur)},
    _ = [file:close(Fd) || Fd <- [Plain, Append]],
    Show("unknown at", {PlainAt, AppendAt}),
    ok = erx_ns:unmount(<<"/u">>),
    exit(Server, kill).

foreign({attach, _, _, _, _, _}) -> {ok, {16#80, 0, 1}};
foreign({walk, _, _, Names}) -> {ok, [{16#80, 0, 2} || _ <- Names]};
foreign({lcreate, _, _, _, _, _}) -> {ok, {0, 0, 3}, 0};
foreign({write, _, _, Data}) -> {ok, byte_size(Data), unknown};
foreign({getattr, _, _}) -> {ok, attr(8#100644, 100)};
foreign(_) -> ok.

%% Once the grant's process has ended, every operation on its open file answers eio.
grant_gone(Show) ->
    Grant = mounted(<<"/d">>, []),
    {ok, Fd} = file:open(<<"/d/f">>, [raw, binary, read, write]),
    Monitor = erlang:monitor(process, Grant),
    exit(Grant, kill),
    receive {'DOWN', Monitor, process, _, _} -> ok end,
    Show("grant gone", {file:write(Fd, <<"x">>), file:read(Fd, 1), file:position(Fd, eof),
                        file:close(Fd)}),
    ok = erx_ns:unmount(<<"/d">>).

%% A client with one seeded fault, loaded over the preloaded one, and the case that must
%% catch it: walks that act on their fid in place, which delete /t/victim for
%% /t/missing/victim; an append's offset from a getattr's size, which finds the other
%% appender's byte; an offset left where it was on an error; an append's unknown At read
%% as a fid's without append.
seeded(Seed) ->
    {ok, Beam} = prim_file:read_file(<<"/test/seeded/", (list_to_binary(Seed))/binary,
                                       "/erx_file_remote.beam">>),
    _ = code:unstick_mod(erx_file_remote),
    {module, erx_file_remote} = code:load_binary(erx_file_remote, "seeded", Beam),
    Show = fun(Case, Result) -> io:format("seeded ~s\t~0tp~n", [Case, Result]) end,
    case Seed of
        "walk" ->
            ok = erx_ns:mount(test_grant(), <<"/t">>, [{tree, <<"test">>}, rw]),
            ok = prim_file:make_symlink(<<"f">>, <<"/t/victim">>),
            Show("delete", prim_file:delete(<<"/t/missing/victim">>)),
            Show("victim", prim_file:read_link(<<"/t/victim">>));
        "append" -> appends(Show);
        "cap" -> past_the_cap(Show);
        "unknown" -> unknown_at(Show)
    end.
