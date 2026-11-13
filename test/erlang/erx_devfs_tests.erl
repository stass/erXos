%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of /dev (docs/design-system.md, "The /dev tree"): erx_devfs_core's
%% decisions, and erx_devfs's callbacks over a made-up catalogue, the manifest's services
%% and a stand-in for the holder's driver-control facet, a process that answers each
%% gen_server call as erx_driver_ctl's facet would and reports the request to the test.
%% The control tree's grant is rw and the read-only tree's ro; both are called here
%% without a grant, so the read-only tree's own refusal of ctl is what the cases check.
-module(erx_devfs_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

%% The storage domain's id and configured row, and the block device's catalogue entry
%% as the development manifest places it on that row.
-define(HOLDER, 6).
-define(ROW, 1).
-define(BLOCK, block()).
%% Devices the tree does not show: a network device on the system domain and a UART.
-define(NET, #{index => 13, unit => 1, unit_name => <<"net">>, row => system, role => net,
               compatible => <<"virtio,mmio">>, registers => {16#a003c00, 512},
               ranges => [{16#a003000, 4096}], lines => [78], confined => false,
               holder => system}).
-define(UART, #{index => 0, unit => 2, unit_name => <<"console">>, row => system, role => none,
                compatible => none, registers => {16#9000000, 4096},
                ranges => [{16#9000000, 4096}], lines => [33], confined => false,
                holder => system}).
-define(SERVICES, [{?ROW, data, ?ERX_SERVICE_FILES}, {?ROW, storage_ctl, ?ERX_SERVICE_DRIVER_CONTROL}]).

block() ->
    #{index => 12, unit => 0, unit_name => <<"block">>, row => ?ROW, role => block,
      compatible => <<"virtio,mmio">>, registers => {16#a003e00, 512},
      ranges => [{16#a003000, 4096}], lines => [79], confined => false, holder => ?HOLDER}.

%% ---------------------------------------------------------------------------
%% The core
%% ---------------------------------------------------------------------------

only_the_block_device_is_shown_by_index_and_compatible_test() ->
    Devices = [?UART, ?BLOCK, ?NET],
    ?assertEqual([?BLOCK], erx_devfs_core:shown(Devices)),
    ?assertEqual(<<"12-virtio,mmio">>, erx_devfs_core:name(?BLOCK)),
    ?assertEqual(<<"7-a%2Fb%0A">>, erx_devfs_core:name((?BLOCK)#{index => 7, compatible => <<"a/b\n">>})),
    ?assertEqual(<<"7">>, erx_devfs_core:name((?BLOCK)#{index => 7, compatible => none})).

a_name_names_a_shown_device_only_in_its_one_spelling_test() ->
    Devices = [?UART, ?BLOCK, ?NET],
    ?assertEqual({ok, ?BLOCK}, erx_devfs_core:find(<<"12-virtio,mmio">>, Devices)),
    [?assertEqual(error, erx_devfs_core:find(Name, Devices))
     || Name <- [<<"13-virtio,mmio">>, <<"0">>, <<"12">>, <<"12-virtio%2Cmmio">>, <<"012-virtio,mmio">>,
                 <<"12-virtio,mmio/">>, <<>>, <<"..">>]].

status_lines_test() ->
    ?assertEqual(<<"unit\tblock\n"
                   "compatible\tvirtio,mmio\n"
                   "registers\t0xa003e00-0xa003fff\n"
                   "lines\t79\n"
                   "confined\tfalse\n"
                   "holder\t6\n"
                   "driver\t[unknown]\n">>, erx_devfs_core:status(?BLOCK)),
    %% Every value the catalogue may hold is written as itself, and text through the
    %% field escape, so a tab or a newline in it cannot forge a line.
    Other = erx_devfs_core:status((?BLOCK)#{unit_name => <<"a\tb\nc">>, compatible => none,
                                          registers => unknown, lines => [], holder => none}),
    ?assertEqual(<<"unit\ta\\tb\\nc\n"
                   "compatible\tnone\n"
                   "registers\t[unknown]\n"
                   "lines\t\n"
                   "confined\tfalse\n"
                   "holder\tnone\n"
                   "driver\t[unknown]\n">>, Other),
    ?assertMatch(<<"unit\tblock\n", _/binary>>, erx_devfs_core:status((?BLOCK)#{lines => [79, 80], holder => system})),
    ?assertNotEqual(nomatch, binary:match(erx_devfs_core:status((?BLOCK)#{lines => [79, 80]}), <<"lines\t79 80\n">>)),
    ?assertNotEqual(nomatch, binary:match(erx_devfs_core:status((?BLOCK)#{holder => system}), <<"holder\tsystem\n">>)).

ctl_takes_one_word_and_its_newline_test() ->
    [?assertEqual({ok, Operation}, erx_devfs_core:command(Line))
     || {Line, Operation} <- [{<<"stop">>, stop}, {<<"stop\n">>, stop}, {<<"start">>, start},
                              {<<"start\n">>, start}, {<<"reset">>, restart}, {<<"reset\n">>, restart}]],
    [?assertEqual({error, einval}, erx_devfs_core:command(Line))
     || Line <- [<<>>, <<"\n">>, <<"restart\n">>, <<"reset\n\n">>, <<"reset ">>, <<" reset">>,
                 <<"RESET">>, <<"reset\r\n">>, <<"stop\nstart\n">>, <<"res">>, <<0>>]].

a_ctl_write_over_sixteen_bytes_is_refused_test() ->
    Sixteen = <<"reset", (binary:copy(<<"\n">>, 11))/binary>>,
    ?assertEqual(16, byte_size(Sixteen)),
    ?assertEqual({error, einval}, erx_devfs_core:command(Sixteen)),
    ?assertEqual({error, einval}, erx_devfs_core:command(<<Sixteen/binary, "x">>)),
    ?assertEqual({error, einval}, erx_devfs_core:command(binary:copy(<<"reset\n">>, 1000))).

the_holders_driver_control_facet_is_found_by_interface_test() ->
    ?assertEqual({ok, storage_ctl}, erx_devfs_core:facet(?BLOCK, ?SERVICES)),
    %% The files service on the same row is not one, nor a driver-control service of
    %% another row, nor any service of a device the system domain holds or none does.
    ?assertEqual({error, enxio}, erx_devfs_core:facet(?BLOCK, [{?ROW, data, ?ERX_SERVICE_FILES}])),
    ?assertEqual({error, enxio}, erx_devfs_core:facet(?BLOCK, [{?ROW + 1, other_ctl, ?ERX_SERVICE_DRIVER_CONTROL}])),
    ?assertEqual({error, enxio}, erx_devfs_core:facet((?BLOCK)#{holder => none}, ?SERVICES)),
    ?assertEqual({error, enxio}, erx_devfs_core:facet(?NET, ?SERVICES)).

facet_answers_read_as_errors_test() ->
    ?assertEqual(ok, erx_devfs_core:answer(ok)),
    ?assertEqual({error, ebusy}, erx_devfs_core:answer({error, running})),
    ?assertEqual({error, enxio}, erx_devfs_core:answer({error, badarg})),
    ?assertEqual({error, eio}, erx_devfs_core:answer({error, failed})),
    ?assertEqual({error, eio}, erx_devfs_core:answer({exit, timeout})).

%% ---------------------------------------------------------------------------
%% The tree's callbacks
%% ---------------------------------------------------------------------------

%% The tree of Rights over the catalogue [?UART, ?BLOCK, ?NET], whose holder's facet is
%% Facet, a pid or undefined.
tree(Rights, Facet) ->
    {ok, Fs} = erx_devfs:init(#{rights => Rights,
                                catalogue => fun() -> {ok, [?UART, ?BLOCK, ?NET]} end,
                                services => fun() -> {ok, ?SERVICES} end,
                                cap => fun(storage_ctl) -> Facet; (_) -> undefined end}),
    Fs.

walk_path(Fs, Names) ->
    {ok, _Tree, Root, _Qid} = erx_devfs:root(Fs),
    lists:foldl(fun(Name, {ok, Node}) ->
                        case erx_devfs:walk(Node, Name, Fs) of
                            {ok, Next, _} -> {ok, Next};
                            {error, _} = Error -> Error
                        end;
                   (_Name, Error) -> Error
                end, {ok, Root}, Names).

listing(Fs, Names) ->
    {ok, Dir} = walk_path(Fs, Names),
    {ok, Handle} = erx_devfs:open(Dir, 0, Fs),
    {ok, Entries} = erx_devfs:readdir(Handle, 0, 100, Fs),
    [Name || {_Qid, _Offset, _Type, Name} <- Entries].

read_all(Fs, Names) ->
    {ok, File} = walk_path(Fs, Names),
    {ok, Handle} = erx_devfs:open(File, 0, Fs),
    {ok, Bytes} = erx_devfs:read(Handle, 0, 65536, Fs),
    Bytes.

both_trees_list_the_block_device_and_its_status_test() ->
    [begin
         Fs = tree(Rights, undefined),
         ?assertEqual([<<"12-virtio,mmio">>], listing(Fs, [])),
         ?assertEqual(erx_devfs_core:status(?BLOCK), read_all(Fs, [<<"12-virtio,mmio">>, <<"status">>])),
         ?assertEqual({error, enoent}, walk_path(Fs, [<<"13-virtio,mmio">>])),
         {ok, Status} = walk_path(Fs, [<<"12-virtio,mmio">>, <<"status">>]),
         ?assertEqual({error, erofs}, erx_devfs:open(Status, ?ERX_P9_O_WRONLY, Fs))
     end || Rights <- [ro, rw]],
    ?assertEqual([<<"ctl">>, <<"status">>], listing(tree(rw, undefined), [<<"12-virtio,mmio">>])),
    ?assertEqual([<<"status">>], listing(tree(ro, undefined), [<<"12-virtio,mmio">>])).

the_read_only_tree_has_no_ctl_test() ->
    Facet = facet(),
    Fs = tree(ro, Facet),
    ?assertEqual({error, enoent}, walk_path(Fs, [<<"12-virtio,mmio">>, <<"ctl">>])),
    %% A ctl node the read-only tree never handed out does not open, nor take a write.
    ?assertEqual({error, erofs}, erx_devfs:open({ctl, 12}, ?ERX_P9_O_WRONLY, Fs)),
    ?assertEqual({error, erofs}, erx_devfs:write({ctl, 12}, 0, <<"reset\n">>, Fs)),
    ?assertEqual([], requests(Facet)).

a_ctl_write_acts_through_the_holders_facet_test() ->
    Facet = facet(),
    Fs = tree(rw, Facet),
    {ok, Ctl} = walk_path(Fs, [<<"12-virtio,mmio">>, <<"ctl">>]),
    ?assertEqual({error, eacces}, erx_devfs:open(Ctl, 0, Fs)),
    {ok, Handle} = erx_devfs:open(Ctl, ?ERX_P9_O_WRONLY, Fs),
    %% A write answers the offset it was written at, from which the client counts on.
    ?assertEqual({ok, 6, 0}, erx_devfs:write(Handle, 0, <<"reset\n">>, Fs)),
    ?assertEqual({ok, 4, 6}, erx_devfs:write(Handle, 6, <<"stop">>, Fs)),
    ?assertEqual({error, ebusy}, erx_devfs:write(Handle, 0, <<"start\n">>, Fs)),
    ?assertEqual({error, einval}, erx_devfs:write(Handle, 0, <<"restart\n">>, Fs)),
    ?assertEqual({error, einval}, erx_devfs:write(Handle, 0, binary:copy(<<"x">>, 17), Fs)),
    ?assertEqual([{restart, block}, {stop, block}, {start, block}], requests(Facet)).

%% prim_file opens every file it writes through lcreate, as `echo reset > ctl` and
%% file:write_file/2 do: in the control tree a create of ctl, O_TRUNC included, opens the
%% existing file for writing, and every other create is refused.
a_create_of_ctl_opens_it_for_writing_test() ->
    Facet = facet(),
    Fs = tree(rw, Facet),
    {ok, Dir} = walk_path(Fs, [<<"12-virtio,mmio">>]),
    Truncating = ?ERX_P9_O_WRONLY bor ?ERX_P9_O_TRUNC,
    {ok, {ctl, 12}, _Qid, Handle} = erx_devfs:make(Dir, <<"ctl">>, {file, 8#644, Truncating}, Fs),
    ?assertEqual({ok, 6, 0}, erx_devfs:write(Handle, 0, <<"reset\n">>, Fs)),
    ?assertEqual([{restart, block}], requests(Facet)),
    ?assertEqual({error, eexist},
                 erx_devfs:make(Dir, <<"ctl">>, {file, 8#644, Truncating bor ?ERX_P9_O_EXCL}, Fs)),
    ?assertEqual({error, eacces}, erx_devfs:make(Dir, <<"ctl">>, {file, 8#644, ?ERX_P9_O_RDWR}, Fs)),
    ?assertEqual({error, eacces}, erx_devfs:make(Dir, <<"status">>, {file, 8#644, Truncating}, Fs)),
    ?assertEqual({error, eacces}, erx_devfs:make(Dir, <<"other">>, {directory, 8#755, self()}, Fs)),
    ?assertEqual({error, eacces}, erx_devfs:make(root, <<"ctl">>, {file, 8#644, Truncating}, Fs)),
    ?assertEqual({error, erofs}, erx_devfs:make(Dir, <<"ctl">>, {file, 8#644, Truncating}, tree(ro, Facet))),
    ?assertEqual([{restart, block}], requests(Facet)).

a_ctl_write_without_the_facet_test() ->
    %% No facet installed yet, or a facet that ended: the device is not configured, or
    %% the call failed, and the write ends nothing.
    Fs = tree(rw, undefined),
    {ok, Ctl} = walk_path(Fs, [<<"12-virtio,mmio">>, <<"ctl">>]),
    {ok, Handle} = erx_devfs:open(Ctl, ?ERX_P9_O_WRONLY, Fs),
    ?assertEqual({error, enxio}, erx_devfs:write(Handle, 0, <<"reset\n">>, Fs)),
    Dead = spawn(fun() -> ok end),
    Ref = monitor(process, Dead),
    receive {'DOWN', Ref, process, Dead, _} -> ok end,
    ?assertEqual({error, eio}, erx_devfs:write(Handle, 0, <<"reset\n">>, tree(rw, Dead))).

%% A stand-in for the holder's driver-control facet: it answers stop and restart ok and
%% start {error, running}, and keeps each request for requests/1.
facet() ->
    spawn_link(fun() -> facet_loop([]) end).

facet_loop(Requests) ->
    receive
        {'$gen_call', From, {Operation, _Unit} = Request} ->
            gen_server:reply(From, case Operation of start -> {error, running}; _ -> ok end),
            facet_loop([Request | Requests]);
        {requests, Pid} ->
            Pid ! {requests, lists:reverse(Requests)},
            facet_loop(Requests)
    end.

requests(Facet) ->
    Facet ! {requests, self()},
    receive {requests, Requests} -> Requests end.
