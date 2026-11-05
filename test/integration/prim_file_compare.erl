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

%% Only the release has erx_ns. A grant's paths reach erx_file_remote, here its stub,
%% and leave with the entry; a grant whose process ended answers eio; fids are drawn
%% one after another.
namespace("stock") -> ok;
namespace("release") ->
    Show = fun(Step, Result) -> io:format("ns ~s\t~0tp~n", [Step, Result]) end,
    Show("before", prim_file:read_file_info(<<"/tmp/a">>)),
    Show("mount", erx_ns:mount(self(), <<"/tmp">>, [{tree, <<"tmp">>}, rw])),
    Show("info", prim_file:read_file_info(<<"/tmp/a">>)),
    Show("read", prim_file:read_file(<<"/tmp/a">>)),
    Show("again", erx_ns:mount(self(), <<"/tmp/">>, [{tree, <<"tmp">>}])),
    Show("bad tree", erx_ns:mount(self(), <<"/x">>, [{tree, <<"a/b">>}])),
    Show("bind", erx_ns:bind(<<"/tmp/a">>, <<"/b">>, [ro])),
    Show("bound", prim_file:read_file_info(<<"/b/c">>)),
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
    ok = erx_ns:mount(self(), <<"/tmp">>, [{tree, <<"tmp">>}, rw]),
    ok = erx_ns:mount(self(), <<"/u">>, [{tree, <<"u">>}, rw]),
    ok = erx_ns:bind(<<"/tmp/a">>, <<"/ro">>, [ro]),
    {module, erx_file_remote} = code:ensure_loaded(erx_file_remote),
    _ = erlang:trace_pattern({erx_file_remote, '_', '_'}, true, [local]),
    Show("ro bind", Reached(fun() -> prim_file:read_file_info(<<"/ro/c">>) end)),
    Show("rw mount", Reached(fun() -> prim_file:make_dir(<<"/tmp/c">>) end)),
    Show("rename one", Reached(fun() -> prim_file:rename(<<"/tmp/x">>, <<"/tmp/a/y">>) end)),
    Show("rename two", Reached(fun() -> prim_file:rename(<<"/tmp/x">>, <<"/u/y">>) end)),
    Show("rename ro", Reached(fun() -> prim_file:rename(<<"/tmp/a/x">>, <<"/ro/y">>) end)),
    Show("rename local", Reached(fun() -> prim_file:rename(<<"/tmp/x">>, <<"/lib/y">>) end)),
    Show("link one", Reached(fun() -> prim_file:make_link(<<"/u/x">>, <<"/u/y">>) end)),
    Show("link two", Reached(fun() -> prim_file:make_link(<<"/u/x">>, <<"/tmp/y">>) end)),
    _ = erlang:trace_pattern({erx_file_remote, '_', '_'}, false, [local]),
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
