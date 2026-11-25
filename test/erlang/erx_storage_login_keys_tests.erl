%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the `login_keys` tree's holder, erx_storage_login_keys, over the
%% volumes test/fixtures/fat_record_volume.rb writes in ERX_FAT_VOLUMES (docs/design-ssh.md,
%% "When it is there" and "Verification"). Each holder starts with a sector reader the
%% case controls: one the case holds until it releases it, one that fails, one that
%% raises, and the image's own.
-module(erx_storage_login_keys_tests).
-include_lib("eunit/include/eunit.hrl").

%% A sector of Volume's image, as the window's read answers it.
reader(Volume) ->
    {ok, Image} = file:read_file(filename:join(os:getenv("ERX_FAT_VOLUMES"), Volume ++ ".img")),
    fun(Sector) when (Sector + 1) * 512 =< byte_size(Image) -> {ok, binary:part(Image, Sector * 512, 512)};
       (_Sector) -> {error, erange}
    end.

%% Volume's reader, whose first read waits until the case sends the reader `release`;
%% the case hears {held, Reader} when it waits.
held(Volume) ->
    Case = self(),
    Read = reader(Volume),
    fun(Sector) ->
            case get(released) of
                undefined ->
                    Case ! {held, self()},
                    receive release -> put(released, true) end;
                true ->
                    ok
            end,
            Read(Sector)
    end.

%% A holder over Read, linked to a process of its own so a case's kill reaches only
%% the holder's reader, and the monitor reference the holder tagged its reader with,
%% seen by tracing the reader's start. Its log lines come to the case as {log, Line}.
start(Read) ->
    Case = self(),
    Log = fun(Line) -> Case ! {log, iolist_to_binary(Line)} end,
    Owner = spawn(fun() ->
                          receive go -> Case ! {holder, erx_storage_login_keys:start_link(Read, Log)} end,
                          receive stop -> ok end
                  end),
    1 = erlang:trace(Owner, true, [set_on_spawn, 'receive', {tracer, Case}]),
    Owner ! go,
    {ok, Holder} = receive {holder, Started} -> Started end,
    %% The first query starts the reader.
    {error, eagain} = erx_storage_login_keys:root_answer(Holder),
    Monitor = receive {trace, _Reader, 'receive', {start, Ref}} -> Ref end,
    {Holder, Monitor}.

%% Root's answer once the reader has decided it: eagain until then.
settled(Holder) -> settled(Holder, 200).

settled(Holder, 0) -> erx_storage_login_keys:root_answer(Holder);
settled(Holder, Tries) ->
    case erx_storage_login_keys:root_answer(Holder) of
        {error, eagain} -> timer:sleep(10), settled(Holder, Tries - 1);
        Answer -> Answer
    end.

logs() ->
    receive {log, Line} -> [Line | logs()] after 0 -> [] end.

%% What a grant reads of root through the tree's callbacks: walk, open, then a read of
%% 817 bytes from offset 0, as the facet reads it.
grant_read(Holder) ->
    {ok, Tree} = erx_storage_login_keys:init(Holder),
    {ok, <<"login_keys">>, Root, _} = erx_storage_login_keys:root(Tree),
    {ok, File, _} = erx_storage_login_keys:walk(Root, <<"root">>, Tree),
    {ok, Handle} = erx_storage_login_keys:open(File, 0, Tree),
    erx_storage_login_keys:read(Handle, 0, 817, Tree).

blobs(Bytes) -> [Blob || <<Blob:51/binary>> <= Bytes].

%% The fixture's keys: lines of seeds 1 and 2, each blob the name and 32 bytes of its seed.
key(Seed) -> <<11:32, "ssh-ed25519", 32:32, (binary:copy(<<Seed>>, 32))/binary>>.

the_keys_of_the_file_are_root_test() ->
    {Holder, _} = start(reader("found")),
    ?assertEqual({ok, <<(key(1))/binary, (key(2))/binary>>}, settled(Holder)),
    ?assertEqual({ok, <<(key(1))/binary, (key(2))/binary>>}, grant_read(Holder)),
    ?assertEqual([], logs()).

%% No sector is read until root is first asked for, so a boot whose session has
%% imported its keys never reads the medium.
no_sector_is_read_until_root_is_asked_test() ->
    Case = self(),
    Read = reader("found"),
    {ok, Holder} = erx_storage_login_keys:start_link(fun(Sector) -> Case ! {read, Sector}, Read(Sector) end,
                                                     fun(_Line) -> ok end),
    ?assertEqual(none, receive {read, _} -> read after 100 -> none end),
    ?assertEqual({error, eagain}, erx_storage_login_keys:root_answer(Holder)),
    ?assertEqual(read, receive {read, _} -> read after 5000 -> none end),
    unlink(Holder),
    exit(Holder, kill).

%% The mount returns before the reader reads: root answers eagain, an error and not an
%% empty file, through the grant too, until the reader is released.
a_held_reader_leaves_root_answering_eagain_until_it_is_released_test() ->
    {Holder, _} = start(held("found")),
    Reader = receive {held, Pid} -> Pid end,
    ?assertEqual({error, eagain}, erx_storage_login_keys:root_answer(Holder)),
    ?assertEqual({error, eagain}, grant_read(Holder)),
    {ok, Tree} = erx_storage_login_keys:init(Holder),
    ?assertEqual({error, eagain}, erx_storage_login_keys:getattr({file, root}, Tree)),
    Reader ! release,
    ?assertEqual({ok, <<(key(1))/binary, (key(2))/binary>>}, settled(Holder)),
    {ok, #{size := Size}} = erx_storage_login_keys:getattr({file, root}, Tree),
    ?assertEqual(102, Size).

a_file_the_decoder_refuses_is_an_empty_root_with_its_finding_test() ->
    {Holder, _} = start(reader("too_many_keys")),
    ?assertEqual({ok, <<>>}, settled(Holder)),
    ?assertEqual({ok, <<>>}, grant_read(Holder)),
    ?assertEqual([<<"authorized_keys: more than 16 keys">>], logs()).

no_file_is_an_empty_root_with_its_finding_test() ->
    {Holder, _} = start(reader("absent")),
    ?assertEqual({ok, <<>>}, settled(Holder)),
    ?assertEqual([<<"authorized_keys: no authorized_keys">>], logs()).

a_skipped_line_is_logged_by_its_number_and_the_other_keys_kept_test() ->
    {Holder, _} = start(reader("skipped_line")),
    ?assertEqual([key(1), key(2)], blobs(element(2, settled(Holder)))),
    ?assertEqual([<<"authorized_keys line 2: not a plain ssh-ed25519 key">>], logs()).

%% The medium was not read, so no empty file stands in for it.
a_killed_reader_is_eio_not_an_empty_root_test() ->
    {Holder, _} = start(held("found")),
    Reader = receive {held, Pid} -> Pid end,
    exit(Reader, kill),
    ?assertEqual({error, eio}, settled(Holder)),
    ?assertEqual({error, eio}, grant_read(Holder)),
    ?assertEqual([<<"authorized_keys: read failed">>], logs()).

a_failed_sector_read_is_eio_test() ->
    {Holder, _} = start(fun(_Sector) -> {error, eio} end),
    ?assertEqual({error, eio}, settled(Holder)),
    ?assertEqual([<<"authorized_keys: read failed">>], logs()).

a_reader_that_raises_is_eio_test() ->
    {Holder, _} = start(fun(_Sector) -> error(window_gone) end),
    ?assertEqual({error, eio}, settled(Holder)),
    ?assertEqual([<<"authorized_keys: read failed">>], logs()).

%% A query that names no alias is dropped, not a crash of the holder.
a_query_without_an_alias_is_dropped_test() ->
    {Holder, _} = start(reader("absent")),
    Holder ! {erx_storage_login_keys, root, 42},
    ?assertEqual({ok, <<>>}, settled(Holder)).

%% Once decided, root never changes: a result under the reader's own tag after its
%% 'DOWN', or after its result, is dropped, as is one under any other tag.
a_result_after_the_reader_s_end_changes_nothing_test() ->
    {Holder, Monitor} = start(held("found")),
    Reader = receive {held, Pid} -> Pid end,
    exit(Reader, kill),
    ?assertEqual({error, eio}, settled(Holder)),
    Holder ! {Monitor, {result, {keys, [key(7)], []}}},
    ?assertEqual({error, eio}, erx_storage_login_keys:root_answer(Holder)).

a_second_result_changes_nothing_test() ->
    {Holder, Monitor} = start(reader("absent")),
    ?assertEqual({ok, <<>>}, settled(Holder)),
    Holder ! {Monitor, {result, {keys, [key(7)], []}}},
    Holder ! {'DOWN', Monitor, process, self(), killed},
    ?assertEqual({ok, <<>>}, erx_storage_login_keys:root_answer(Holder)).

a_result_under_another_tag_is_dropped_test() ->
    {Holder, _} = start(held("found")),
    Reader = receive {held, Pid} -> Pid end,
    Holder ! {make_ref(), {result, {keys, [key(7)], []}}},
    ?assertEqual({error, eagain}, erx_storage_login_keys:root_answer(Holder)),
    Reader ! release,
    ?assertEqual({ok, <<(key(1))/binary, (key(2))/binary>>}, settled(Holder)).

%% A grant reads within the file: from an offset, a count past its end, and past it.
reads_stay_within_the_file_test() ->
    {Holder, _} = start(reader("found")),
    _ = settled(Holder),
    {ok, Tree} = erx_storage_login_keys:init(Holder),
    ?assertEqual({ok, binary:part(key(2), 0, 10)}, erx_storage_login_keys:read({file, root}, 51, 10, Tree)),
    ?assertEqual({ok, key(2)}, erx_storage_login_keys:read({file, root}, 51, 817, Tree)),
    ?assertEqual({ok, <<>>}, erx_storage_login_keys:read({file, root}, 102, 817, Tree)),
    ?assertEqual({error, enoent}, erx_storage_login_keys:walk({file, root}, <<"root">>, Tree)),
    ?assertEqual({error, enoent}, erx_storage_login_keys:walk(root, <<"other">>, Tree)).

%% start_mint/0 starts the mint on the block service's record_volume window, which the
%% service serves exactly when the holder's system_image record names it
%% (erx_blk_table:booted/1), and answers ignore otherwise. A stand-in registered as the
%% block service serves the windows booted/1 gives each record and answers every other
%% call eio, so the reader it starts reads nothing.
start_mint_follows_the_record_test_() ->
    Record = ["system_image", "8192", "8192", "4096", "5a", lists:duplicate(64, $0)],
    [?_assertMatch({ok, Mint} when is_pid(Mint), mint_on([["boot", "normal", "a"], Record ++ ["record_volume"]])),
     ?_assertEqual(ignore, mint_on([["boot", "normal", "a"], Record])),
     ?_assertEqual(ignore, mint_on([]))].

mint_on(Arguments) ->
    {_Slot, Windows, _Status} = erx_blk_table:booted(Arguments),
    Service = spawn(fun() -> block_service([Role || {Role, _Start, _Sectors} <- Windows]) end),
    true = register(erx_blk_service, Service),
    Self = self(),
    Starter = spawn(fun() -> Self ! {started, erx_storage_login_keys:start_mint()}, receive stop -> ok end end),
    Started = receive {started, Answer} -> Answer end,
    exit(Starter, kill),
    exit(Service, kill),
    _ = persistent_term:erase({erx, provides}),
    wait_unregistered(),
    Started.

block_service(Roles) ->
    receive
        {'$gen_call', From, {window, Role}} ->
            gen_server:reply(From, case lists:member(Role, Roles) of
                                       true -> {ok, self()};
                                       false -> {error, no_window}
                                   end);
        {'$gen_call', From, _Other} ->
            gen_server:reply(From, {error, eio})
    end,
    block_service(Roles).

wait_unregistered() ->
    case whereis(erx_blk_service) of
        undefined -> ok;
        _ -> timer:sleep(1), wait_unregistered()
    end.
