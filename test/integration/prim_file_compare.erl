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

%% How long the case waits for a helper process before it fails; well under the harness's
%% own deadline, so a helper that died on a failed call fails the case with its name.
-define(HELPER_WAIT, 30000).

%% The size cap of the tree the concurrency cases share.
-define(CONC_CAP, 200000).

main([_, "seeded", Seed]) ->
    seeded(Seed),
    erlang:halt(0);
%% The /tmp transcript with a seeded fault loaded: a client beam by code:load_binary (the
%% client is preloaded), any other module from the seed's directory on the code path.
main([_, "tmp-seeded", Seed]) ->
    load_seeded_client(Seed),
    tmp(<<>>, "release"),
    erlang:halt(0);
%% Code from /tmp in a runtime whose first use of /tmp is the code server's.
main([_, "cold", Seed]) ->
    load_seeded_client(Seed),
    cold(),
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
    release_opens(Prefix),
    pins(Mode),
    tmp(Prefix, Mode),
    namespace(Mode),
    image(Mode),
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
    %% The domain's own /tmp leaves the point to these mounts.
    ok = erx_ns:unmount(<<"/tmp">>),
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
    receive {'DOWN', Ref, process, Gone, _} -> ok after ?HELPER_WAIT -> helper_silent(gone_exit) end,
    Show("gone", ended(<<"/gone/x">>, 100)),
    Show("unmount gone", erx_ns:unmount(<<"/gone">>)),
    Show("unmount bound", erx_ns:unmount(<<"/b">>)),
    two_paths(Show),
    First = prim_file:erx_fid(),
    Show("fids", {is_integer(First), prim_file:erx_fid() - First}).

%% A read-only bind of a writable grant reaches erx_file_remote read-only, with the
%% grant's tree; a rename or a link reaches it only when both paths lie on one grant's
%% tree through one set of rights, and is exdev otherwise (erofs where either lies read-only), once both paths are walked and
%% before any server is asked to act. erx_file_remote is traced, so each step shows the
%% first call that reached it, the source's walk for a rename or a link, or none.
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
    Show("rename two", Reached(fun() -> prim_file:rename(<<"/tmp/a">>, <<"/u/y">>) end)),
    Show("rename ro", Reached(fun() -> prim_file:rename(<<"/tmp/a/f">>, <<"/ro/y">>) end)),
    Show("rename local", Reached(fun() -> prim_file:rename(<<"/tmp/a">>, <<"/lib/y">>) end)),
    %% A rename whose source is "/" is einval before it is exdev or erofs; "//", a mount's
    %% or a bind's top and a last "." keep the order of the other two-path refusals.
    Show("rename root", Reached(fun() -> prim_file:rename(<<"/">>, <<"/tmp/y">>) end)),
    Show("rename root local", Reached(fun() -> prim_file:rename(<<"/">>, <<"/lib/y">>) end)),
    Show("rename mount top", Reached(fun() -> prim_file:rename(<<"/tmp/">>, <<"/u/y">>) end)),
    Show("rename bind top", Reached(fun() -> prim_file:rename(<<"/ro">>, <<"/tmp/y">>) end)),
    Show("rename mount dot", Reached(fun() -> prim_file:rename(<<"/tmp/.">>, <<"/u/y">>) end)),
    Show("link one", Reached(fun() -> prim_file:make_link(<<"/u/x">>, <<"/u/y">>) end)),
    Show("link two", Reached(fun() -> prim_file:make_link(<<"/u/x">>, <<"/tmp/y">>) end)),
    %% The top of a writable bind on the same grant is a mount point too, though its
    %% names are its root's: a rename to or from it, del_dir and delete answer ebusy
    %% without asking the server, and the bound directory stays where it is. The rename
    %% from the top goes last, as without the refusal it moves /tmp/a away.
    ok = erx_ns:bind(<<"/tmp/a">>, <<"/x">>, []),
    Show("rename to bind top", prim_file:rename(<<"/tmp/a/f">>, <<"/x">>)),
    Show("del_dir bind top", prim_file:del_dir(<<"/x">>)),
    Show("delete bind top", prim_file:delete(<<"/x">>)),
    Show("rename from bind top", Reached(fun() -> prim_file:rename(<<"/x">>, <<"/tmp/d">>) end)),
    Show("bind top kept", info(prim_file:read_file_info(<<"/tmp/a/f">>))),
    _ = erlang:trace_pattern({erx_file_remote, '_', '_'}, false, []),
    [ok = erx_ns:unmount(Point) || Point <- [<<"/x">>, <<"/ro">>, <<"/u">>, <<"/tmp">>]],
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
%% Only the release has erx_ns. An EROFS image, the fixture image of the reader's tests at
%% /image.erofs, mounted at /img from a RAM window: its paths reach the EROFS reader, a
%% link on it is followed from the place it lies, an absolute link through the namespace,
%% an operation that writes answers erofs once the directory is walked, a malformed image
%% is refused, and the image leaves with its entry. Each line is `image <case>`.
image("stock") -> ok;
image("release") ->
    Show = fun(Case, Result) -> io:format("image ~s\t~0tp~n", [Case, Result]) end,
    Crc = fun({ok, Data}) -> {ok, erlang:crc32(Data)}; (Other) -> Other end,
    {ok, Bytes} = prim_file:read_file(<<"/image.erofs">>),
    Show("mount", erx_ns:mount({erofs, ram_window(Bytes)}, <<"/img">>, [])),
    Show("read", Crc(prim_file:read_file(<<"/img/big">>))),
    Show("info", info(prim_file:read_file_info(<<"/img/big">>))),
    Show("dir info", info(prim_file:read_file_info(<<"/img/a">>))),
    Show("list", prim_file:list_dir(<<"/img/a">>)),
    Show("link", prim_file:read_link(<<"/img/to-small">>)),
    Show("link info", info(prim_file:read_link_info(<<"/img/to-small">>))),
    Show("via link", Crc(prim_file:read_file(<<"/img/to-small">>))),
    Show("up link", Crc(prim_file:read_file(<<"/img/a/b/up/small">>))),
    Show("absolute link", prim_file:read_file_info(<<"/img/to-b">>)),
    Show("missing", prim_file:read_file(<<"/img/nope">>)),
    Show("not dir", prim_file:read_file(<<"/img/small/x">>)),
    {ok, Fd} = prim_file:open(<<"/img/big">>, [read, binary]),
    Show("open read", Crc(file:read(Fd, 5000))),
    Show("open pread", Crc(file:pread(Fd, 12000, 1000))),
    Show("open position", file:position(Fd, eof)),
    Show("open write", file:write(Fd, <<"x">>)),
    Show("open close", file:close(Fd)),
    Show("open dir", prim_file:open(<<"/img/a">>, [read])),
    {ok, Cwd} = prim_file:get_cwd(),
    Show("cwd", prim_file:set_cwd(<<"/img/a/b">>)),
    Show("cwd read", Crc(prim_file:read_file(<<"c/leaf">>))),
    Show("cwd up", Crc(prim_file:read_file(<<"../../small">>))),
    ok = prim_file:set_cwd(Cwd),
    Show("cwd file", prim_file:set_cwd(<<"/img/small">>)),
    Show("make_dir", prim_file:make_dir(<<"/img/new">>)),
    Show("make_dir missing", prim_file:make_dir(<<"/img/nope/new">>)),
    Show("make_dir existing", prim_file:make_dir(<<"/img/a">>)),
    Show("open exclusive", prim_file:open(<<"/img/small">>, [write, exclusive])),
    Show("open dir to write", prim_file:open(<<"/img/a">>, [write])),
    Show("create via link", prim_file:open(<<"/img/to-b">>, [write])),
    Show("open to write", prim_file:open(<<"/img/small">>, [write])),
    Show("write_file", prim_file:write_file(<<"/img/new">>, <<"x">>)),
    Show("delete", prim_file:delete(<<"/img/small">>)),
    Show("del_dir", prim_file:del_dir(<<"/img/a/b/c">>)),
    Show("rename", prim_file:rename(<<"/img/small">>, <<"/img/moved">>)),
    Show("write_file_info", prim_file:write_file_info(<<"/img/small">>, #file_info{mode = 8#600})),
    Show("symlink", prim_file:make_symlink(<<"small">>, <<"/img/new">>)),
    Show("symlink existing", prim_file:make_symlink(<<"small">>, <<"/img/to-small">>)),
    Show("link to", prim_file:make_link(<<"/img/small">>, <<"/img/new">>)),
    Show("bad image", erx_ns:mount({erofs, ram_window(binary:copy(<<0>>, 8192))}, <<"/bad">>, [])),
    Show("unmount", erx_ns:unmount(<<"/img">>)),
    Show("after", prim_file:read_file_info(<<"/img/big">>)).

%% A RAM window over Bytes: answers gen_server calls as erx_blk_window does.
ram_window(Bytes) ->
    spawn(fun() -> ram_window_loop(Bytes) end).

ram_window_loop(Bytes) ->
    receive
        {'$gen_call', From, info} ->
            gen:reply(From, {ok, #{role => slot_a, sectors => byte_size(Bytes) div 512}});
        {'$gen_call', From, {read, Sector, Count}} ->
            gen:reply(From, {ok, binary:part(Bytes, Sector * 512, Count * 512)})
    end,
    ram_window_loop(Bytes).

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
    Show("rename onto read-only", prim_file:rename(<<"/t/f">>, <<"/r/g">>)),
    Show("exdev link", prim_file:make_link(<<"/t/f">>, <<"/r/g">>)),
    open_files(Show),
    Show("fids held", fids_held(Grant)),
    slashes(Show),
    links(Show),
    hostile(Show),
    [ok = erx_ns:unmount(Point) || Point <- [<<"/r">>, <<"/t">>]],
    ok.

%% A path written with a trailing "/" on a grant names a directory, as FreeBSD's path
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
    Show("link out source missing", prim_file:rename(<<"/s/rel/x">>, <<"/s/y">>)),
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
    Show("link hard link followed", {prim_file:make_link(<<"/s/l">>, <<"/s/l2">>),
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
    Own = lists:sort([receive {appended, Byte, Count} -> {Byte, Count} after ?HELPER_WAIT -> helper_silent(appender) end
                      || _ <- [1, 2]]),
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
    receive {'DOWN', Monitor, process, _, _} -> ok after ?HELPER_WAIT -> helper_silent(grant_kill) end,
    Show("grant gone", {file:write(Fd, <<"x">>), file:read(Fd, 1), file:position(Fd, eof),
                        file:close(Fd)}),
    ok = erx_ns:unmount(<<"/d">>).

%% A client with one seeded fault, loaded over the preloaded one, and the case that must
%% catch it: walks that act on their fid in place, which delete /t/victim for
%% /t/missing/victim; an append's offset from a getattr's size, which finds the other
%% appender's byte; an offset left where it was on an error; an append's unknown At read
%% as a fid's without append.
seeded(Seed) ->
    load_seeded_client(Seed),
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

%% "none" is the unseeded run. A seed of another module has no client beam but is on the
%% code path, so its directory must hold a beam; a seed that names nothing is an error and
%% not an unseeded run.
load_seeded_client("none") ->
    ok;
load_seeded_client(Seed) ->
    Directory = <<"/test/seeded/", (list_to_binary(Seed))/binary>>,
    case prim_file:read_file(<<Directory/binary, "/erx_file_remote.beam">>) of
        {ok, Beam} ->
            _ = code:unstick_mod(erx_file_remote),
            {module, erx_file_remote} = code:load_binary(erx_file_remote, "seeded", Beam),
            ok;
        {error, enoent} ->
            case prim_file:list_dir(Directory) of
                {ok, [_ | _]} -> ok;
                Other -> erlang:error({no_seed, Seed, Other})
            end
    end.

%% /tmp against stock (design-tmp.md, Verification, "Against stock OTP"): the same
%% file calls run under the domain's /tmp and, in stock, in a fresh host directory
%% beside the tree; each prints `tmp <step>\t<result>`, with #file_info{} reduced to
%% what the design maps and listings sorted. runtime_prim_file_test.rb compares the two
%% and names each difference. Then, on erXos only (`tmpx` lines), the size limit, a
%% restart and code loaded from /tmp.
tmp(Prefix, Mode) ->
    Top = case Mode of
              "release" -> <<"/tmp/seq">>;
              "stock" -> <<Prefix/binary, "/../stock-tmp">>
          end,
    ok = file:make_dir(Top),
    At = fun(Name) -> <<Top/binary, "/", Name/binary>> end,
    Show = fun(Step, Result) -> io:format("tmp ~s\t~0tp~n", [Step, Result]) end,
    Show("write", file:write_file(At(<<"x">>), <<"hello">>)),
    Show("read", file:read_file(At(<<"x">>))),
    %% file:copy/2 runs in file_server_2, which opens both files itself: one from the
    %% release (prim_file's descriptor) into /tmp (erx_file_remote's), then one within /tmp,
    %% whose 5 bytes over the 6 already there show that the destination is truncated.
    Show("copy in", file:copy(<<Prefix/binary, "/corpus/a.txt">>, At(<<"copied">>))),
    Show("copy in read", file:read_file(At(<<"copied">>))),
    Show("copy within", file:copy(At(<<"x">>), At(<<"copied">>))),
    Show("copy within read", file:read_file(At(<<"copied">>))),
    Show("copy delete", file:delete(At(<<"copied">>))),
    Show("info", tmp_info(file:read_file_info(At(<<"x">>)))),
    Show("make dir", file:make_dir(At(<<"d">>))),
    Show("make dir again", file:make_dir(At(<<"d">>))),
    Show("write in dir", file:write_file(At(<<"d/f">>), <<"f">>)),
    Show("dir info", tmp_info(file:read_file_info(At(<<"d">>)))),
    Show("del dir full", file:del_dir(At(<<"d">>))),
    Show("rename", file:rename(At(<<"d/f">>), At(<<"d/g">>))),
    Show("list", sorted(file:list_dir(At(<<"d">>)))),
    Show("delete", file:delete(At(<<"d/g">>))),
    Show("delete again", file:delete(At(<<"d/g">>))),
    Show("del dir", file:del_dir(At(<<"d">>))),
    Show("gone", file:read_file_info(At(<<"d">>))),
    %% Open after unlink: the handle keeps the file.
    {ok, Fd} = file:open(At(<<"u">>), [read, write, binary]),
    Show("unlink open", file:delete(At(<<"u">>))),
    Show("write unlinked", file:write(Fd, <<"kept">>)),
    Show("pread unlinked", file:pread(Fd, 0, 10)),
    Show("close unlinked", file:close(Fd)),
    Show("unlinked gone", file:read_file(At(<<"u">>))),
    %% Rename over an open file: its handle still reads the old bytes.
    ok = file:write_file(At(<<"a">>), <<"old">>),
    ok = file:write_file(At(<<"b">>), <<"new">>),
    {ok, Old} = file:open(At(<<"a">>), [read, binary]),
    Show("rename over", file:rename(At(<<"b">>), At(<<"a">>))),
    Show("old handle", file:pread(Old, 0, 10)),
    Show("new name", file:read_file(At(<<"a">>))),
    ok = file:close(Old),
    %% A rename of "/" answers einval, stock's own answer, before the release and /tmp's
    %% grant could answer exdev.
    Show("rename root", file:rename(<<"/">>, At(<<"arne">>))),
    Show("append", tmp_appends(At(<<"log">>))),
    %% Truncation through a read-only descriptor, and through a writable one after
    %% chmod 0444; write_file_info of what read_file_info answered.
    {ok, Ro} = file:open(At(<<"a">>), [read]),
    Show("truncate ro", file:truncate(Ro)),
    ok = file:close(Ro),
    {ok, Rw} = file:open(At(<<"a">>), [read, write]),
    ok = file:change_mode(At(<<"a">>), 8#444),
    Show("truncate 0444", file:truncate(Rw)),
    ok = file:close(Rw),
    Show("read 0444", tmp_info(file:read_file_info(At(<<"a">>)))),
    {ok, Read} = file:read_file_info(At(<<"x">>)),
    Show("write info", file:write_file_info(At(<<"x">>), Read)),
    %% The client's rules for a last . or .. (design-tmp.md, Verification).
    ok = file:make_dir(At(<<"child">>)),
    ok = file:write_file(At(<<"file">>), <<"f">>),
    ok = file:make_symlink(<<"f">>, At(<<"victim">>)),
    Special = [{"del_dir missing/.", fun() -> file:del_dir(At(<<"missing/.">>)) end},
               {"del_dir child/..", fun() -> file:del_dir(At(<<"child/..">>)) end},
               {"delete file/.", fun() -> file:delete(At(<<"file/.">>)) end},
               {"rename child/..", fun() -> file:rename(At(<<"child/..">>), At(<<"y">>)) end},
               {"rename to child/.", fun() -> file:rename(At(<<"x">>), At(<<"child/.">>)) end},
               {"make_dir child/.", fun() -> file:make_dir(At(<<"child/.">>)) end},
               {"make_dir missing/..", fun() -> file:make_dir(At(<<"missing/..">>)) end},
               {"symlink child/..", fun() -> file:make_symlink(<<"t">>, At(<<"child/..">>)) end},
               {"link to child/.", fun() -> file:make_link(At(<<"file">>), At(<<"child/.">>)) end},
               {"link from child/.", fun() -> file:make_link(At(<<"child/.">>), At(<<"new">>)) end},
               {"delete missing/victim", fun() -> file:delete(At(<<"missing/victim">>)) end},
               {"victim kept", fun() -> file:read_link(At(<<"victim">>)) end},
               {"file kept", fun() -> file:read_file(At(<<"file">>)) end}],
    [Show(Step, Call()) || {Step, Call} <- Special],
    tmp_large(At, Show),
    tmp_ahead(At, Show),
    tmp_ipread(At, Show),
    tmp_advise(At, Show),
    tmp_directory_handle(At, Show),
    tmp_cwd(At, Mode, Show),
    tmp_bind_top(At, Mode, Show),
    Show("listing", sorted(file:list_dir(Top))),
    tmp_erxos(Mode).

%% Reads and writes of more than the client's 64 KiB unit (design-files.md, Open files
%% and offsets), as file_SUITE's segment_read and segment_write make them: a read of a
%% regular file answers every byte it asks for up to the end, as stock's does, whatever
%% the unit. Each step shows the sizes it got and whether the bytes are those written.
%% The files are deleted again, so the listing after is unchanged.
tmp_large(At, Show) ->
    Big = At(<<"big">>),
    Bin = << <<I:32>> || I <- lists:seq(0, 65535) >>,
    Size = byte_size(Bin),
    Same = fun({ok, Got}, Want) -> {ok, byte_size(Got), Got =:= Want};
              (Other, _) -> Other
           end,
    {ok, W} = file:open(Big, [write, raw, binary]),
    Show("large write", file:write(W, Bin)),
    ok = file:close(W),
    Show("large read_file", Same(file:read_file(Big), Bin)),
    {ok, R} = file:open(Big, [read, raw, binary]),
    Show("large read", Same(file:read(R, Size), Bin)),
    Show("large read at eof", file:read(R, 1)),
    {ok, _} = file:position(R, 70000),
    Show("large read past eof", Same(file:read(R, Size), binary_part(Bin, 70000, Size - 70000))),
    Show("large pread", Same(file:pread(R, 0, Size), Bin)),
    Show("large pread past eof",
         Same(file:pread(R, 100000, Size), binary_part(Bin, 100000, Size - 100000))),
    Show("large pread list",
         case file:pread(R, [{0, 70000}, {70000, 200000}, {Size, 10}]) of
             {ok, [One, Two, Three]} ->
                 {ok, byte_size(One), byte_size(Two), Three, <<One/binary, Two/binary>> =:= Bin};
             Other ->
                 Other
         end),
    ok = file:close(R),
    %% Segmented writes: two pwrites in one call, each past the unit, then writes of a
    %% unit and a byte more, each read back whole.
    Copy = At(<<"copy">>),
    {ok, P} = file:open(Copy, [write, raw, binary]),
    Show("large pwrite list",
         file:pwrite(P, [{100000, binary_part(Bin, 100000, Size - 100000)},
                         {0, binary_part(Bin, 0, 100000)}])),
    ok = file:close(P),
    Show("large pwrite list back", Same(file:read_file(Copy), Bin)),
    {ok, S} = file:open(Copy, [write, raw, binary]),
    Pieces = [binary_part(Bin, Start, min(65537, Size - Start))
              || Start <- lists:seq(0, Size - 1, 65537)],
    Show("large segments", lists:usort([file:write(S, Piece) || Piece <- Pieces])),
    ok = file:close(S),
    {ok, V} = file:open(Copy, [read, raw, binary]),
    Show("large segments back", Same(file:read(V, Size + 1), Bin)),
    ok = file:close(V),
    Show("large delete", {file:delete(Big), file:delete(Copy)}).

%% The read-ahead buffer, as file_SUITE's read_ahead uses it: a read through a file
%% opened with read_ahead answers what the buffer holds, a write through another file
%% since included; position, write and truncate empty it, and the offset is the one the
%% reads moved to, whatever the buffer holds. read_line buffers as stock's does, without
%% read_ahead too. The files are deleted again.
tmp_ahead(At, Show) ->
    Name = At(<<"ahead">>),
    {ok, W} = file:open(Name, [raw, write]),
    ok = file:write(W, ["asdfghjkl", "asdfghjkl"]),
    {ok, R} = file:open(Name, [raw, read, read_ahead]),
    Show("ahead read", file:read(R, 9)),
    ok = file:pwrite(W, 9, "qwertyuio"),
    Show("ahead cached", file:read(R, 9)),
    Show("ahead at end", file:read(R, 1)),
    Show("ahead position", file:position(R, {cur, -9})),
    Show("ahead after position", file:read(R, 9)),
    ok = file:close(R),
    {ok, Sized} = file:open(Name, [raw, read, {read_ahead, 4}, binary]),
    Show("ahead sized", [file:read(Sized, 3), file:read(Sized, 3), file:read(Sized, 20)]),
    ok = file:close(Sized),
    {ok, RW} = file:open(Name, [raw, read, write, read_ahead, binary]),
    Show("ahead read rw", file:read(RW, 3)),
    Show("ahead write rw", file:write(RW, <<"XYZ">>)),
    Show("ahead offset rw", file:position(RW, cur)),
    Show("ahead read after write", file:read(RW, 3)),
    Show("ahead truncate", file:truncate(RW)),
    ok = file:close(RW),
    Show("ahead file", file:read_file(Name)),
    ok = file:write_file(Name, <<"one\ntwo\r\nthree">>),
    {ok, L} = file:open(Name, [raw, read, binary]),
    Show("ahead line", file:read_line(L)),
    ok = file:pwrite(W, 4, "TWO"),
    Show("ahead line cached", [file:read_line(L), file:read_line(L), file:read_line(L)]),
    Show("ahead line position", file:position(L, cur)),
    ok = file:close(L),
    ok = file:close(W),
    Show("ahead delete", file:delete(Name)).

%% file:ipread_s32bu_p32bu/3 on an open file (file_SUITE's ipread): a pointer block,
%% <<Size:32, Offset:32>>, read at an offset, then Size bytes at Offset. A block past
%% the end or naming more than the maximum answers eof, a payload past the end
%% {ok, {Size, Offset, eof}}, a size of zero eof in place of the data.
tmp_ipread(At, Show) ->
    Name = At(<<"ipread">>),
    ok = file:write_file(Name, <<5:32, 24:32, 0:32, 100:32, 5:32, 100:32, "hello">>),
    {ok, Fd} = file:open(Name, [raw, read, binary]),
    Steps = [{"ipread", 0, infinity}, {"ipread exact", 0, 5}, {"ipread over max", 0, 4},
             {"ipread zero size", 8, infinity}, {"ipread payload past end", 16, infinity},
             {"ipread short block", 24, infinity}, {"ipread past end", 100, infinity},
             {"ipread negative", -1, infinity}, {"ipread max too big", 0, 1 bsl 31},
             {"ipread bad max", 0, foo}],
    [Show(Step, ipread(Fd, Offset, Max)) || {Step, Offset, Max} <- Steps],
    ok = file:close(Fd),
    Show("ipread closed", ipread(Fd, 0, infinity)),
    Show("ipread delete", file:delete(Name)).

%% A raise is a line of its own, so the steps after it still run.
ipread(Fd, Offset, Max) ->
    try file:ipread_s32bu_p32bu(Fd, Offset, Max)
    catch Class:Reason -> {raised, Class, Reason}
    end.

%% file:advise/4 (file_SUITE's advise): each advice POSIX names answers ok, as stock's
%% posix_fadvise or its absence does; an unknown advice, a negative offset or length
%% einval; a closed file einval.
tmp_advise(At, Show) ->
    Name = At(<<"advise">>),
    ok = file:write_file(Name, <<"advise">>),
    {ok, Fd} = file:open(Name, [raw, read]),
    Show("advise known", [file:advise(Fd, 0, 0, Advice)
                          || Advice <- [normal, random, sequential, will_need, dont_need,
                                        no_reuse]]),
    Show("advise unknown", file:advise(Fd, 0, 0, bad_advise)),
    Show("advise negative offset", file:advise(Fd, -1, 0, normal)),
    Show("advise negative length", file:advise(Fd, 0, -1, normal)),
    ok = file:close(Fd),
    Show("advise closed", file:advise(Fd, 0, 0, normal)),
    Show("advise delete", file:delete(Name)).

%% A directory opened with [read, directory] (file_SUITE's
%% file_handle_info_basic_directory): the handle answers its file information, a read
%% eisdir, and a file opened so enotdir.
tmp_directory_handle(At, Show) ->
    Dir = At(<<"dirfd">>),
    ok = file:make_dir(Dir),
    ok = file:write_file(At(<<"dirfd/f">>), <<"f">>),
    directory_handle(Dir, Show, "dirfd"),
    Show("dirfd file", closed(file:open(At(<<"dirfd/f">>), [read, directory]))),
    Show("dirfd delete", {file:delete(At(<<"dirfd/f">>)), file:del_dir(Dir)}).

%% Making a name at a bind's top (design-files.md, Errors, step 3): the top is a name that
%% exists, so make_dir, a creating open, make_symlink and make_link's new name answer as
%% Linux answers for an existing directory at a mount point, writable or read-only, and
%% nothing is made in the bound directory's parent. Stock's counterpart is the bound
%% directory itself. On erXos only: a bind whose root was removed through its parent's
%% mount answers eexist too, and does not make the root again.
tmp_bind_top(At, Mode, Show) ->
    Bound = At(<<"bt">>),
    ok = file:make_dir(Bound),
    ok = file:write_file(At(<<"bt/f">>), <<"f">>),
    {Rw, Ro} = case Mode of
                   "release" ->
                       ok = erx_ns:bind(Bound, <<"/bt">>, []),
                       ok = erx_ns:bind(Bound, <<"/btr">>, [ro]),
                       {<<"/bt">>, <<"/btr">>};
                   "stock" ->
                       {Bound, Bound}
               end,
    Steps = [{"make_dir", fun(Where) -> file:make_dir(Where) end},
             {"make_dir/", fun(Where) -> file:make_dir(<<Where/binary, "/">>) end},
             {"open write", fun(Where) -> closed(file:open(Where, [write])) end},
             {"open read write", fun(Where) -> closed(file:open(Where, [read, write])) end},
             {"open exclusive", fun(Where) -> closed(file:open(Where, [write, exclusive])) end},
             {"symlink", fun(Where) -> file:make_symlink(<<"t">>, Where) end},
             {"symlink/", fun(Where) -> file:make_symlink(<<"t">>, <<Where/binary, "/">>) end},
             {"link", fun(Where) -> file:make_link(<<Where/binary, "/f">>, Where) end}],
    [Show("top " ++ Step ++ Rights, Call(Where))
     || {Rights, Where} <- [{"", Rw}, {" ro", Ro}], {Step, Call} <- Steps],
    Show("top kept", {sorted(file:list_dir(Bound)), file:read_file(At(<<"bt/f">>))}),
    bind_top_gone(At, Mode),
    [ok = erx_ns:unmount(Point) || Mode =:= "release", Point <- [<<"/bt">>, <<"/btr">>]],
    ok = file:delete(At(<<"bt/f">>)),
    ok = file:del_dir(Bound).

bind_top_gone(_, "stock") -> ok;
bind_top_gone(At, "release") ->
    Gone = At(<<"btg">>),
    ok = file:make_dir(Gone),
    ok = erx_ns:bind(Gone, <<"/btg">>, []),
    ok = file:del_dir(Gone),
    io:format("tmpx top gone make_dir\t~0tp~n", [file:make_dir(<<"/btg">>)]),
    io:format("tmpx top gone kept\t~0tp~n", [file:read_file_info(Gone)]),
    ok = erx_ns:unmount(<<"/btg">>),
    _ = file:del_dir(Gone),
    ok.

directory_handle(Dir, Show, Step) ->
    case file:open(Dir, [read, directory]) of
        {ok, Fd} ->
            Show(Step ++ " info", handle_type(file:read_file_info(Fd))),
            Show(Step ++ " raw info", handle_type(file:read_file_info(Fd, [raw]))),
            Show(Step ++ " read", file:read(Fd, 1)),
            Show(Step ++ " close", file:close(Fd));
        Refused ->
            Show(Step ++ " open", Refused)
    end,
    case file:open(Dir, [raw, read, directory]) of
        {ok, Raw} ->
            Show(Step ++ " raw handle", handle_type(file:read_file_info(Raw))),
            Show(Step ++ " raw read", file:read(Raw, 1)),
            Show(Step ++ " raw pread", file:pread(Raw, 0, 1)),
            Show(Step ++ " raw close", file:close(Raw));
        RawRefused ->
            Show(Step ++ " raw open", RawRefused)
    end.

handle_type({ok, #file_info{type = Type, access = Access}}) -> {ok, Type, Access};
handle_type(Other) -> Other.

%% Opens on the read-only release that open(2) refuses before it would meet the read-only
%% file system: a directory opened to write answers eisdir, an exclusive open of a name
%% that exists eexist, a name under a missing directory enoent, under a file enotdir. A
%% release directory opens with [read, directory] as a /tmp one does.
release_opens(Prefix) ->
    At = fun(Name) -> <<Prefix/binary, "/corpus/", Name/binary>> end,
    Show = fun(Step, Result) -> io:format("open ~s\t~0tp~n", [Step, Result]) end,
    Steps = [{"dir write", <<"sub">>, [write]}, {"dir/ write", <<"sub/">>, [write]},
             {"dir read_write", <<"sub">>, [read, write]}, {"dir append", <<"sub">>, [append]},
             {"dir exclusive", <<"sub">>, [write, exclusive]},
             {"file exclusive", <<"a.txt">>, [write, exclusive]},
             {"under missing", <<"missing/x">>, [write]},
             {"under file", <<"a.txt/x">>, [write]}],
    [Show(Step, closed(file:open(At(Name), Modes))) || {Step, Name, Modes} <- Steps],
    directory_handle(At(<<"sub">>), Show, "directory"),
    Show("directory file", closed(file:open(At(<<"a.txt">>), [read, directory]))).

%% A working directory in the tree (design-files.md, Erlang clients, error step 5):
%% relative calls run in it; set_cwd refuses a file and a missing path and keeps the
%% directory; del_dir of the working directory, by its own path or as sub/.., answers
%% einval while it holds names and removes it once it is empty, after which a relative
%% write finds no directory. set_cwd follows links, one to the corpus included, and
%% refuses a directory the user may not search. Then the working directory returns to
%% the corpus.
tmp_cwd(At, Mode, Show) ->
    {ok, Saved} = file:get_cwd(),
    ok = file:make_dir(At(<<"w">>)),
    Show("cwd set", file:set_cwd(At(<<"w">>))),
    Show("cwd get", cwd_name(file:get_cwd())),
    case Mode of
        "release" -> io:format("tmpx cwd path\t~0tp~n", [file:get_cwd()]);
        "stock" -> ok
    end,
    Show("cwd write", file:write_file(<<"f">>, <<"rel">>)),
    Show("cwd read", file:read_file(<<"f">>)),
    Show("cwd read absolute", file:read_file(At(<<"w/f">>))),
    Show("cwd make dir", file:make_dir(<<"sub">>)),
    Show("cwd list", sorted(file:list_dir(<<".">>))),
    Show("cwd set file", file:set_cwd(<<"f">>)),
    Show("cwd set missing", file:set_cwd(<<"missing">>)),
    Show("cwd set file/", file:set_cwd(<<"f/">>)),
    Show("cwd set sub", file:set_cwd(<<"sub">>)),
    Show("cwd sub", cwd_name(file:get_cwd())),
    Show("cwd set ..", file:set_cwd(<<"..">>)),
    ok = file:make_dir(<<"nx">>),
    ok = file:change_mode(<<"nx">>, 8#600),
    Show("cwd set unsearchable", file:set_cwd(<<"nx">>)),
    ok = file:change_mode(<<"nx">>, 8#755),
    ok = file:del_dir(<<"nx">>),
    ok = file:make_symlink(<<"w">>, At(<<"wl">>)),
    Show("cwd set link", file:set_cwd(At(<<"wl">>))),
    Show("cwd link", cwd_name(file:get_cwd())),
    ok = file:make_symlink(Saved, At(<<"corpus">>)),
    Show("cwd set link out", file:set_cwd(At(<<"corpus">>))),
    Show("cwd out", cwd_name(file:get_cwd())),
    ok = file:set_cwd(At(<<"w">>)),
    ok = file:delete(At(<<"wl">>)),
    ok = file:delete(At(<<"corpus">>)),
    Show("cwd kept", cwd_name(file:get_cwd())),
    Show("del_dir cwd full", file:del_dir(At(<<"w">>))),
    Show("del_dir cwd sub/..", file:del_dir(<<"sub/..">>)),
    Show("del_dir other full", file:del_dir(At(<<"child/..">>))),
    ok = file:delete(<<"f">>),
    ok = file:del_dir(<<"sub">>),
    Show("del_dir cwd empty", file:del_dir(At(<<"w">>))),
    Show("cwd gone write", file:write_file(<<"g">>, <<"g">>)),
    Show("cwd back", file:set_cwd(Saved)),
    Show("cwd back where", file:get_cwd() =:= {ok, Saved}).

cwd_name({ok, Cwd}) -> {ok, filename:basename(Cwd)};
cwd_name(Other) -> Other.

%% What the design compares of a #file_info{}: type, access and permission bits,
%% and a regular file's size and links; a directory's size and links are Linux's
%% tmpfs's (design-tmp.md, Differences from stock OTP).
tmp_info({ok, #file_info{type = regular, size = Size, access = Access, mode = Mode, links = Links}}) ->
    {ok, regular, Size, Access, Mode band 8#7777, Links};
tmp_info({ok, #file_info{type = Type, access = Access, mode = Mode}}) ->
    {ok, Type, Access, Mode band 8#7777};
tmp_info(Other) ->
    Other.

%% Two processes append one distinct byte each, many times: each finds its own byte
%% before its position, and the file holds every byte.
tmp_appends(Path) ->
    Self = self(),
    Writer = fun(Byte) ->
                     fun() ->
                             {ok, F} = file:open(Path, [append, read, binary]),
                             Own = lists:all(fun(_) ->
                                                     ok = file:write(F, <<Byte>>),
                                                     {ok, At} = file:position(F, cur),
                                                     {ok, <<Byte>>} =:= file:pread(F, At - 1, 1)
                                             end, lists:seq(1, 200)),
                             ok = file:close(F),
                             Self ! {appended, Byte, Own}
                     end
             end,
    [spawn(Writer(Byte)) || Byte <- [$a, $b]],
    Own = [receive {appended, Byte, O} -> O after ?HELPER_WAIT -> helper_silent({appender, Byte}) end
           || Byte <- [$a, $b]],
    {ok, Bytes} = file:read_file(Path),
    {Own, byte_size(Bytes), lists:sort(maps:to_list(lists:foldl(fun(B, M) -> maps:update_with(B, fun(N) -> N + 1 end, 1, M) end, #{}, binary_to_list(Bytes))))}.

tmp_erxos("stock") -> ok;
tmp_erxos("release") ->
    Show = fun(Step, Result) -> io:format("tmpx ~s\t~0tp~n", [Step, Result]) end,
    Show("limit", erx_ns:tmp_limit() > 0),
    %% A second instance under a small cap: a write past it is refused whole, and
    %% a cap of 0 refuses every creation.
    {ok, Small} = erx_ramfs_sup:start_link(100000, <<"/small">>, erx_ramfs_small),
    Show("small fits", file:write_file(<<"/small/a">>, binary:copy(<<1>>, 60000))),
    Show("small past", file:write_file(<<"/small/b">>, binary:copy(<<2>>, 60000))),
    Show("small b", tmp_info(file:read_file_info(<<"/small/b">>))),
    {ok, Big} = file:open(<<"/small/a">>, [read, write, binary]),
    Show("small write", file:pwrite(Big, 0, binary:copy(<<3>>, 60000))),
    Show("small kept", file:pread(Big, 0, 1)),
    ok = file:close(Big),
    %% A working directory on the grant is a path: once the grant ends its paths answer
    %% eio, and once /small is unmounted they reach the release file system, which holds
    %% no /small.
    {ok, Saved} = file:get_cwd(),
    Show("small cwd", file:set_cwd(<<"/small">>)),
    Show("small cwd info", tmp_info(file:read_file_info(<<"a">>))),
    Down = monitor(process, Small),
    unlink(Small),
    exit(Small, shutdown),
    receive {'DOWN', Down, process, Small, _} -> ok after ?HELPER_WAIT -> helper_silent(small_tree_exit) end,
    Show("small cwd ended", file:read_file_info(<<"a">>)),
    ok = erx_ns:unmount(<<"/small">>),
    Show("small cwd unmounted", file:read_file_info(<<"a">>)),
    Show("small cwd kept", file:get_cwd()),
    ok = file:set_cwd(Saved),
    {ok, Zero} = erx_ramfs_sup:start_link(0, <<"/zero">>, erx_ramfs_zero),
    Show("zero list", file:list_dir(<<"/zero">>)),
    Show("zero write", file:write_file(<<"/zero/a">>, <<>>)),
    Show("zero dir", file:make_dir(<<"/zero/d">>)),
    unlink(Zero),
    exit(Zero, shutdown),
    %% Open after unlink: what a file holds is given back at its last close, and a
    %% process that opens a file, removes it and is killed gives it back too. The
    %% grant answers a close when it hands the clunk to the file's owner, so the
    %% charge comes back just after close returns, and both checks wait for it.
    Free = tmp_free(erx_ramfs),
    {ok, Gone} = file:open(<<"/tmp/held">>, [read, write, binary]),
    ok = file:delete(<<"/tmp/held">>),
    ok = file:write(Gone, binary:copy(<<7>>, 50000)),
    Show("held while open", tmp_free(erx_ramfs) < Free),
    ok = file:close(Gone),
    Show("held after close", tmp_wait_free(erx_ramfs, Free, 100) =:= ok),
    Parent = self(),
    Killed = spawn(fun() ->
                           {ok, Fd} = file:open(<<"/tmp/held2">>, [read, write, binary]),
                           ok = file:delete(<<"/tmp/held2">>),
                           ok = file:write(Fd, binary:copy(<<8>>, 50000)),
                           Parent ! {written, self()},
                           receive never -> ok end
                   end),
    receive {written, Killed} -> ok after ?HELPER_WAIT -> helper_silent(held_writer) end,
    Show("held while owner lives", tmp_free(erx_ramfs) < Free),
    exit(Killed, kill),
    Show("held after owner killed", tmp_wait_free(erx_ramfs, Free, 100)),
    %% A file written and renamed over b while others stat b: every stat finds b. Then
    %% writers filling the tree stop at the cap together.
    {ok, Conc} = erx_ramfs_sup:start_link(?CONC_CAP, <<"/conc">>, erx_ramfs_conc),
    Show("concurrent renames", tmp_concurrent_renames()),
    Show("concurrent fill", tmp_concurrent_fill()),
    unlink(Conc),
    exit(Conc, shutdown),
    %% Restart: kill the tree process with a file open; the open file answers eio,
    %% and /tmp comes back empty, mounted again, with no old owner alive.
    ok = file:write_file(<<"/tmp/before">>, <<"b">>),
    {ok, Open} = file:open(<<"/tmp/before">>, [read, binary]),
    {ok, #file_info{inode = OldInode}} = file:read_file_info(<<"/tmp/before">>),
    OldTree = whereis(erx_ramfs),
    Old = tmp_processes(OldTree),
    exit(OldTree, kill),
    Show("restarted", tmp_restarted(OldTree, 100)),
    Show("old owners counted", length(Old) >= 3),
    Show("no old owner alive", tmp_all_dead(Old, 100)),
    Show("old fd", file:read(Open, 1)),
    Show("empty", file:list_dir(<<"/tmp">>)),
    ok = file:write_file(<<"/tmp/after">>, <<"a">>),
    {ok, #file_info{inode = NewInode}} = file:read_file_info(<<"/tmp/after">>),
    Show("inode above", NewInode > OldInode),
    ok.

%% Free blocks of a tree, through the callback the grant uses.
tmp_free(Name) ->
    {ok, #{bfree := Free}} = erx_ramfs:statfs(persistent_term:get({erx_ramfs, Name})),
    Free.

tmp_wait_free(_Name, _Free, 0) ->
    timeout;
tmp_wait_free(Name, Free, Tries) ->
    case tmp_free(Name) of
        Free -> ok;
        _ -> receive after 20 -> tmp_wait_free(Name, Free, Tries - 1) end
    end.

%% The tree process, its grant and every process linked to the grant: the file owners.
tmp_processes(Tree) ->
    {links, [Sup]} = process_info(Tree, links),
    [Grant] = [Pid || {grant, Pid, _, _} <- supervisor:which_children(Sup)],
    {links, Linked} = process_info(Grant, links),
    lists:usort([Tree, Grant | [P || P <- Linked, P =/= Sup]]).

tmp_all_dead(Old, 0) ->
    [P || P <- Old, is_process_alive(P)];
tmp_all_dead(Old, Tries) ->
    case [P || P <- Old, is_process_alive(P)] of
        [] -> none;
        _ -> receive after 20 -> tmp_all_dead(Old, Tries - 1) end
    end.

%% Eight processes each write a fresh file and rename it over b, while eight stat b.
%% POSIX makes the rename atomic: no stat misses b. Returns {Misses, StatsRan, RenamesDone, EntriesLeft, BWhole}.
tmp_concurrent_renames() ->
    Dir = <<"/conc/r">>,
    B = <<Dir/binary, "/b">>,
    ok = file:make_dir(Dir),
    ok = file:write_file(B, <<"b">>),
    Parent = self(),
    Stop = atomics:new(1, []),
    Stat = fun() ->
                   Count = fun Loop(Stats, Misses) ->
                                   case atomics:get(Stop, 1) of
                                       1 -> {Stats, Misses};
                                       0 ->
                                           case file:read_file_info(B) of
                                               {ok, _} -> Loop(Stats + 1, Misses);
                                               {error, _} -> Loop(Stats + 1, Misses + 1)
                                           end
                                   end
                           end,
                   Parent ! {stats, self(), Count(0, 0)}
           end,
    Rename = fun(N) ->
                     fun() ->
                             Mine = <<Dir/binary, "/w", (integer_to_binary(N))/binary>>,
                             Done = lists:foldl(fun(_, Count) ->
                                                        case file:write_file(Mine, <<"new", N>>) of
                                                            ok -> Count + renamed(Mine, B);
                                                            {error, _} -> Count
                                                        end
                                                end, 0, lists:seq(1, 100)),
                             Parent ! {renamed, self(), Done}
                     end
             end,
    %% Statters run at high priority so that they ask whenever a renamer waits.
    Stats = [spawn_opt(Stat, [{priority, high}]) || _ <- lists:seq(1, 8)],
    Renamers = [spawn(Rename(N)) || N <- lists:seq(1, 8)],
    Renames = [receive {renamed, R, Done} -> Done after ?HELPER_WAIT * 2 -> helper_silent({renamer, R}) end
               || R <- Renamers],
    atomics:put(Stop, 1, 1),
    Counts = [receive {stats, S, Count} -> Count after ?HELPER_WAIT -> helper_silent({statter, S}) end
              || S <- Stats],
    %% Every rename took effect (a file written and renamed over b is gone from its own
    %% name), and b holds one renamer's whole content.
    {ok, Names} = file:list_dir(Dir),
    Final = file:read_file(B),
    Whole = lists:member(Final, [{ok, <<"new", N>>} || N <- lists:seq(1, 8)]),
    {lists:sum([M || {_, M} <- Counts]), lists:sum([N || {N, _} <- Counts]) > 0, lists:sum(Renames),
     length(Names), Whole}.

%% 1 when the file at From was renamed over To, 0 when the rename failed.
renamed(From, To) ->
    case file:rename(From, To) of
        ok -> 1;
        {error, _} -> 0
    end.

helper_silent(Name) ->
    erlang:error({helper_did_not_answer, Name}).

%% Eight writers fill a tree whose cap is small: each ends with enospc, none crashes,
%% and what is left is less than one more file.
tmp_concurrent_fill() ->
    Parent = self(),
    Fill = fun(N) ->
                   fun() ->
                           Last = fun Loop(I) ->
                                          File = <<"/conc/f", (integer_to_binary(N))/binary, "_",
                                                   (integer_to_binary(I))/binary>>,
                                          case file:write_file(File, binary:copy(<<N>>, 3000)) of
                                              ok -> Loop(I + 1);
                                              {error, Posix} -> Posix
                                          end
                                  end(1),
                           Parent ! {filled, self(), Last}
                   end
           end,
    Writers = [spawn(Fill(N)) || N <- lists:seq(1, 8)],
    Ends = [receive {filled, W, Last} -> Last after ?HELPER_WAIT -> helper_silent({filler, W}) end || W <- Writers],
    %% The tree charges a directory entry 64 bytes and its name's length, a node 256 bytes
    %% and each started 4096-byte chunk of a file. What the entries cost, from the files'
    %% sizes (a write refused for space leaves an empty file, which costs its entry and
    %% node), never passes the cap, and leaves less than one more chunk free: a cap
    %% checked before the others' writes landed overruns it, and a cap reached early
    %% leaves more.
    {ok, Names} = file:list_dir(<<"/conc">>),
    Files = [unicode:characters_to_binary(N) || N <- Names, hd(unicode:characters_to_list(N)) =:= $f],
    Cost = lists:sum([charge(File, filled_size(<<"/conc/", File/binary>>)) || File <- Files])
        + charge(<<"r">>, 0) + charge(<<"b">>, 1),
    Left = ?CONC_CAP - Cost,
    io:format("tmpx concurrent fill cost\t~0tp~n", [{length(Files), Cost, Left}]),
    {lists:usort(Ends), Cost =< ?CONC_CAP, Left < 4096}.

filled_size(Path) ->
    {ok, #file_info{size = Size}} = file:read_file_info(Path),
    Size.

%% What the tree charges for a file entry of this name and size.
charge(Name, Size) ->
    64 + byte_size(Name) + 256 + 4096 * ((Size + 4095) div 4096).

%% Code from /tmp in a runtime whose first use of /tmp is the code server's: a path
%% with /tmp on it, a module found nowhere (the code server lists /tmp and reads a missing
%% file in its own process, under a deadline), then a prepared .beam written there and
%% loaded. None of the modules the serving processes call may be loaded by these steps.
cold() ->
    {ok, Beam} = prim_file:read_file(<<"/test/cold/tmp_cold.beam">>),
    Serving = erx_ramfs_serving:modules(),
    %% Nothing is formatted between the two snapshots: formatting loads modules itself.
    Before = erlang:loaded(),
    true = code:add_patha("/tmp"),
    Missing = deadline(30000, fun() -> code:ensure_loaded(tmp_nowhere) end),
    Rest = case Missing of
               timeout -> [];
               _ ->
                   Written = deadline(30000, fun() -> file:write_file(<<"/tmp/tmp_cold.beam">>, Beam) end),
                   Load = deadline(30000, fun() -> code:load_abs("/tmp/tmp_cold") end),
                   [{"write", Written}, {"load", Load}, {"call", deadline(30000, fun() -> tmp_cold:f() end)}]
           end,
    After = erlang:loaded(),
    Show = fun(Step, Result) -> io:format("cold ~s\t~0tp~n", [Step, Result]) end,
    Show("serving missing at start", [M || M <- Serving, not lists:member(M, Before)]),
    Show("missing", Missing),
    [Show(Step, Result) || {Step, Result} <- Rest],
    Show("serving loaded by it", [M || M <- Serving, not lists:member(M, Before), lists:member(M, After)]).

deadline(Millis, Fun) ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({result, Fun()}) end),
    receive
        {'DOWN', Ref, process, Pid, {result, Result}} -> Result;
        {'DOWN', Ref, process, Pid, Reason} -> {crashed, Reason}
    after Millis ->
        exit(Pid, kill),
        timeout
    end.

tmp_restarted(_OldTree, 0) ->
    timeout;
tmp_restarted(OldTree, Tries) ->
    case whereis(erx_ramfs) of
        Pid when is_pid(Pid), Pid =/= OldTree ->
            case file:list_dir(<<"/tmp">>) of
                {ok, _} -> ok;
                _ -> receive after 20 -> tmp_restarted(OldTree, Tries - 1) end
            end;
        _ ->
            receive after 20 -> tmp_restarted(OldTree, Tries - 1) end
    end.
