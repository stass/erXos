%% Modified by erXos: a path on the release reaches the NIF as its names, and a path on
%% a file server's grant runs through erx_file_remote.
%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
%%
%% Copyright Ericsson AB 2000-2025. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%
-module(prim_file).
-moduledoc false.

-export([on_load/0]).

-export([open/2, close/1,
         sync/1, datasync/1, truncate/1, advise/4, allocate/3,
         read_line/1, read/2, write/2, position/2,
         pread/2, pread/3, pwrite/2, pwrite/3]).

%% OTP internal.

-export([file_desc_to_ref/2]).

-export([ipread_s32bu_p32bu/3, sendfile/8, internal_get_nif_resource/1,
         altname/1, get_handle/1]).

-export([read_file/1, write_file/2]).

%% erXos: the namespace's table, for erx_ns, and the runtime's fid counter and where a
%% path lies, for erx_file_remote.
-export([erx_table/0, erx_fid/0, erx_resolve/1, erx_tmp_limit/0]).

-export([read_link/1, read_link_all/1,
         read_link_info/1, read_link_info/2,
         read_file_info/1, read_file_info/2,
         read_handle_info/1, read_handle_info/2,
         write_file_info/2, write_file_info/3]).

-export([list_dir/1, list_dir_all/1]).

-export([get_cwd/0, get_cwd/1, set_cwd/1,
         delete/1, rename/2,
         make_dir/1, del_dir/1,
         make_link/2, make_symlink/2]).

-define(MIN_READLINE_SIZE, 256).
-define(LARGEFILESIZE, (1 bsl 63)).

-export([copy/3, start/0]).

-include("file_int.hrl").
-include("generated/erx_abi.hrl").

-type prim_file_ref() :: term().

%%% BIFs

-export([internal_name2native/1,
         internal_native2name/1,
         internal_normalize_utf8/1,
         is_translatable/1]).

-nifs([open_nif/2, close_nif/1, read_nif/2, write_nif/2, pread_nif/3,
       pwrite_nif/3, seek_nif/3, sync_nif/2, truncate_nif/1, allocate_nif/3,
       advise_nif/4, read_handle_info_nif/1,
       make_hard_link_nif/2, make_soft_link_nif/2, rename_nif/2,
       read_info_nif/2, set_permissions_nif/2, set_owner_nif/3, set_time_nif/4,
       read_link_nif/1, list_dir_nif/1, make_dir_nif/1, del_file_nif/1,
       del_dir_nif/1, get_device_cwd_nif/1, get_cwd_nif/0,
       ipread_s32bu_p32bu_nif/3, read_file_nif/1,
       get_handle_nif/1, delayed_close_nif/1, altname_nif/1,
       file_desc_to_ref_nif/1,
       release_walk_nif/1, erx_fid_nif/0, erx_tmp_limit_nif/0, erx_set_cwd_nif/1]).

-type prim_file_name() :: string() | unicode:unicode_binary().
-type prim_file_name_error() :: 'error' | 'ignore' | 'warning'.

-spec internal_name2native(prim_file_name()) -> binary().

internal_name2native(_) ->
    erlang:nif_error(undefined).

-spec internal_native2name(binary()) ->
        prim_file_name() | {'error',prim_file_name_error()}.

internal_native2name(_) ->
    erlang:nif_error(undefined).

-spec internal_normalize_utf8(unicode:unicode_binary()) -> string().

internal_normalize_utf8(_) ->
    erlang:nif_error(undefined).

-spec is_translatable(prim_file_name()) -> boolean().

is_translatable(_) ->
    erlang:nif_error(undefined).

%% This is a janitor process used to close files whose controlling process has
%% died. The emulator will be torn down if this is killed.
start() ->
    helper_loop().

helper_loop() ->
    receive
        {close, FRef} when is_reference(FRef) -> delayed_close_nif(FRef);
        _ -> ok
    end,
    helper_loop().

on_load() ->
    %% This is spawned as a system process to prevent init:restart/0 from
    %% killing it.
    Pid = erts_internal:spawn_system_process(?MODULE, start, []),
    ok = erlang:load_nif(atom_to_list(?MODULE), Pid).

%% Returns {error, Reason} | {ok, BytesCopied}
copy(#file_descriptor{module = ?MODULE} = Source,
     #file_descriptor{module = ?MODULE} = Dest,
     Length)
  when is_integer(Length), Length >= 0;
       is_atom(Length) ->
    %% XXX Should be moved down to the driver for optimization.
    file:copy_opened(Source, Dest, Length).

open(Name, Modes) ->
    %% The try/catch pattern seen here is used throughout the file to adhere to
    %% the public file interface, which has leaked through for ages because of
    %% "raw files."
    try
        Encoded = encode_path(Name),
        erx_at(Encoded, fun(Names) -> opened(open_nif(Names, Modes), Modes) end,
               fun(Grant, Place) -> erx_file_remote:open(Grant, Place, Modes, Encoded) end)
    catch
        error:badarg -> {error, badarg}
    end.

opened({ok, Ref}, Modes) -> {ok, make_fd(Modes, Ref)};
opened({error, Reason}, _Modes) -> {error, Reason}.

file_desc_to_ref(FileDescriptorId, Modes) ->
    try file_desc_to_ref_nif(FileDescriptorId) of
        {ok, Ref} -> {ok, make_fd(Modes, Ref)};
        {error, Reason} -> {error, Reason}
    catch
        error:badarg -> {error, badarg}
    end.

make_fd(Modes, FRef) ->
    #file_descriptor{module = ?MODULE, data = build_fd_data(Modes, FRef) }.

close(Fd) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        close_nif(FRef)
    catch
        error:badarg -> {error, badarg}
    end.

read(Fd, Size) ->
    try
        #{ handle := FRef,
           r_ahead_size := RASz,
           r_buffer := RBuf } = get_fd_data_for_read(Fd),
        read_1(FRef, RBuf, prim_buffer:size(RBuf), RASz, Size)
    catch
        throw:Err -> Err;
        error:badarg -> {error, badarg}
    end.

-spec read_1(FRef, RBuf, RBufSz, RASz, RSz) -> Result when
      FRef :: prim_file_ref(),
      RBuf :: term(),
      RBufSz :: non_neg_integer(),
      RASz :: non_neg_integer(),
      RSz :: non_neg_integer(),
      Result :: eof | {ok, binary()} | {error, Reason :: atom()}.
read_1(_FRef, RBuf, RBufSz, _RASz, RSz) when RBufSz >= RSz ->
    {ok, prim_buffer:read(RBuf, RSz)};
read_1(FRef, RBuf, RBufSz, RASz, RSz) when RBufSz > 0 ->
    Buffered = prim_buffer:read(RBuf, RBufSz),
    case read_1(FRef, RBuf, 0, RASz, RSz - RBufSz) of
        {ok, Data} ->
            {ok, <<Buffered/binary, Data/binary>>};
        eof ->
            {ok, Buffered};
        {error, Reason} ->
            {error, Reason}
    end;
read_1(FRef, RBuf, RBufSz, RASz, RSz) when RBufSz =:= 0 ->
    case read_nif(FRef, RASz + RSz) of
        {ok, Data} when byte_size(Data) > RSz ->
            {First, Rest} = split_binary(Data, RSz),
            prim_buffer:write(RBuf, [Rest]),
            {ok, First};
        {ok, Data} when byte_size(Data) =< RSz ->
            {ok, Data};
        eof ->
            eof;
        {error, Reason} ->
            {error, Reason}
    end.

read_line(Fd) ->
    try
        #{ handle := FRef,
           r_ahead_size := RASz,
           r_buffer := RBuf } = get_fd_data_for_read(Fd),
        SearchResult = prim_buffer:find_byte_index(RBuf, $\n),
        LineSize = max(?MIN_READLINE_SIZE, RASz),
        read_line_1(FRef, RBuf, SearchResult, LineSize)
    catch
        throw:Err -> Err;
        error:badarg -> {error, badarg}
    end.

-spec read_line_1(FRef, RBuf, SearchResult, LineSize) -> Result when
      FRef :: prim_file_ref(),
      RBuf :: term(),
      SearchResult :: not_found | {ok, non_neg_integer()},
      LineSize :: non_neg_integer(),
      Result :: eof | {ok, binary()} | {error, Reason :: atom()}.
read_line_1(FRef, RBuf, not_found, LineSize) ->
    case read_nif(FRef, LineSize) of
        {ok, Data} ->
            prim_buffer:write(RBuf, [Data]),
            SearchResult = prim_buffer:find_byte_index(RBuf, $\n),
            read_line_1(FRef, RBuf, SearchResult, LineSize);
        eof ->
            case prim_buffer:size(RBuf) of
                Size when Size > 0 -> {ok, prim_buffer:read(RBuf, Size)};
                Size when Size =:= 0 -> eof
            end;
        {error, Reason} ->
            {error, Reason}
    end;
read_line_1(_FRef, RBuf, {ok, LFIndex}, _LineSize) ->
    %% Translate CRLF into just LF, completely ignoring which encoding is used.
    CRIndex = (LFIndex - 1),
    case prim_buffer:read(RBuf, LFIndex + 1) of
        <<Line:CRIndex/binary, "\r\n">> -> {ok, <<Line/binary, "\n">>};
        Line -> {ok, Line}
    end.

write(Fd, IOData) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        reset_write_position(Fd),
        write_1(FRef, erlang:iolist_to_iovec(IOData))
    catch
        error:badarg -> {error, badarg}
    end.
write_1(FRef, IOVec) ->
    case write_nif(FRef, IOVec) of
        {continue, Remainder} ->
            write_1(FRef, Remainder);
        ok ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

truncate(Fd) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        reset_write_position(Fd),
        truncate_nif(FRef)
    catch
        error:badarg -> {error, badarg}
    end.

advise(Fd, Offset, Length, Advise) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        advise_nif(FRef, Offset, Length, Advise)
    catch
        error:badarg -> {error, badarg}
    end.

allocate(Fd, Offset, Length) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        allocate_nif(FRef, Offset, Length)
    catch
        error:badarg -> {error, badarg}
    end.

sync(Fd) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        sync_nif(FRef, 0)
    catch
        error:badarg -> {error, badarg}
    end.

datasync(Fd) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        sync_nif(FRef, 1)
    catch
        error:badarg -> {error, badarg}
    end.

position(Fd, {cur, Offset}) ->
    try
        %% Adjust our current position according to how much we've read ahead.
        case get_fd_data(Fd) of
            #{ r_buffer := RBuf } -> position_1(Fd, cur, Offset - prim_buffer:size(RBuf));
            #{} -> position_1(Fd, cur, Offset)
        end
    catch
        error:badarg -> {error, badarg}
    end;
position(Fd, {Mark, Offset}) ->
    try
        position_1(Fd, Mark, Offset)
    catch
        error:badarg -> {error, badarg}
    end;
position(Fd, cur) -> position(Fd, {cur, 0});
position(Fd, bof) -> position(Fd, {bof, 0});
position(Fd, eof) -> position(Fd, {eof, 0});
position(Fd, Offset) -> position(Fd, {bof, Offset}).

position_1(Fd, Mark, Offset) ->
    case get_fd_data(Fd) of
        #{ handle := FRef, r_buffer := RBuf } ->
            prim_buffer:wipe(RBuf),
            seek_nif(FRef, Mark, Offset);
        #{ handle := FRef } ->
            seek_nif(FRef, Mark, Offset)
    end.

pread(Fd, Offset, Size) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        pread_nif(FRef, Offset, Size)
    catch
        error:badarg -> {error, badarg}
    end.

pread(Fd, LocNums) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        pread_list(FRef, LocNums, [])
    catch
        error:badarg -> {error, badarg}
    end.

-spec pread_list(FRef, LocNums, ResultList) -> Result when
      FRef :: prim_file_ref(),
      LocNums :: list({Offset :: non_neg_integer(),
                       Size :: non_neg_integer()}),
      ResultList :: list(eof | binary()),
      Result :: {ok, ResultList} | {error, Reason :: atom()}.
pread_list(_FRef, [], ResultList) ->
    {ok, reverse_list(ResultList)};
pread_list(FRef, [{Offset, Size} | Rest], ResultList) ->
    case pread_nif(FRef, Offset, Size) of
        {ok, Data} ->
            pread_list(FRef, Rest, [Data | ResultList]);
        eof ->
            pread_list(FRef, Rest, [eof | ResultList]);
        {error, Reason} ->
            {error, Reason}
    end.

pwrite(Fd, Offset, IOData) ->
    try
        IOVec = erlang:iolist_to_iovec(IOData),
        case get_fd_data(Fd) of
            #{ handle := FRef, r_buffer := RBuf } ->
                prim_buffer:wipe(RBuf),
                pwrite_plain(FRef, Offset, IOVec);
            #{ handle := FRef } ->
                pwrite_plain(FRef, Offset, IOVec)
        end
    catch
        error:badarg -> {error, badarg}
    end.
pwrite_plain(FRef, Offset, IOVec) ->
    case pwrite_nif(FRef, Offset, IOVec) of
        {continue, BytesWritten, Remainder} ->
            pwrite_plain(FRef, Offset + BytesWritten, Remainder);
        ok ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

pwrite(Fd, LocBytes) ->
    try
        case get_fd_data(Fd) of
            #{ handle := FRef, r_buffer := RBuf } ->
                prim_buffer:wipe(RBuf),
                pwrite_list(FRef, LocBytes, 0);
            #{ handle := FRef } ->
                pwrite_list(FRef, LocBytes, 0)
        end
    catch
        error:badarg -> {error, badarg}
    end.

-spec pwrite_list(FRef, LocBytes, Successes) -> Result when
      FRef :: prim_file_ref(),
      LocBytes :: list({Offset :: non_neg_integer(),
                        IOData :: iodata()}),
      Successes :: non_neg_integer(),
      Result :: ok | {error, {Successes, Reason :: atom()}}.
pwrite_list(_FRef, [], _Successes) ->
    ok;
pwrite_list(FRef, [{Offset, IOData} | Rest], Successes) ->
    case pwrite_plain(FRef, Offset, erlang:iolist_to_iovec(IOData)) of
        {error, Reason} -> {error, {Successes, Reason}};
        ok -> pwrite_list(FRef, Rest, Successes + 1)
    end.

sendfile(Fd, Socket, Offset, Bytes, _ChunkSize, [], [], _Flags) ->
    %% There's a very nasty race in here; if we die just prior to duplicating
    %% the handle down in the sendfile call, it might get reused by something
    %% entirely different and we'll leak unknown data to the socket until it
    %% dies soon after.
    %%
    %% This bug was inherited from the old driver, except it was vulnerable to
    %% the bug at any point and not just during setup.
    %%
    %% We'll have to live with this until we have a way to unambiguously
    %% transfer things between drivers or NIFs. Current ideas all fall afoul
    %% of the Two Generals problem.
    try
        advise(Fd, Offset, Bytes, sequential),
        prim_inet:sendfile(Socket, get_handle(Fd), Offset, Bytes)
    catch
        error:badarg -> {error, badarg}
    end;
sendfile(_Fd, _Socket, _Offset, _Bytes, _ChunkSize, _Headers, _Trailers, _Flags) ->
    {error, enotsup}.

internal_get_nif_resource(Fd) ->
    #{ handle := FRef } = get_fd_data(Fd),
    FRef.

%% Undocumented internal function that reads a data block with indirection.
%%
%% This is only used once in DETS and can easily be emulated with pread/2, but
%% it's pretty performance-sensitive so we've implemented it down in the NIF to
%% avoid excessive rescheduling.
-spec ipread_s32bu_p32bu(Fd, Offset, MaxSize) -> Result when
      Fd :: #file_descriptor{},
      Offset :: non_neg_integer(),
      MaxSize :: non_neg_integer() | infinity,
      Result :: {ok, Size :: non_neg_integer(),
                     Pointer :: non_neg_integer(),
                     Data :: iodata() | eof} |
                eof |
                {error, Reason :: atom()}.
ipread_s32bu_p32bu(Fd, Offset, Infinity) when is_atom(Infinity) ->
    ipread_s32bu_p32bu(Fd, Offset, (1 bsl 31) - 1);
ipread_s32bu_p32bu(Fd, Offset, MaxSize)
        when is_integer(Offset), is_integer(MaxSize) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        ipread_s32bu_p32bu_nif(FRef, Offset, MaxSize)
    catch
        error:badarg -> {error, badarg}
    end;
ipread_s32bu_p32bu(_Fd, _Offset, _MaxSize) ->
    {error, badarg}.
ipread_s32bu_p32bu_nif(_FRef, _Offset, _MaxSize) ->
    erlang:nif_error(undef).

%% Returns the binary representation of the underlying handle, for use in
%% tricky operations like sendfile/8.
-spec get_handle(Fd) -> Result when
      Fd :: #file_descriptor{},
      Result :: binary() | {error, Reason :: atom()}.
get_handle(Fd) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        get_handle_nif(FRef)
    catch
        error:badarg -> {error, badarg}
    end.

%% Resets the write head to the position the user believes we're at, which may
%% not be the same as the real one when read caching is in effect.
reset_write_position(Fd) ->
    case Fd#file_descriptor.data of
        #{ r_buffer := RBuf } ->
            case prim_buffer:size(RBuf) of
                Size when Size > 0 -> position(Fd, cur);
                Size when Size =:= 0 -> ok
            end;
        _ -> ok
    end.

get_fd_data(#file_descriptor{ data = Data }) ->
    #{ owner := Owner } = Data,
    case self() of
        Owner -> Data;
        _ -> error(not_on_controlling_process)
    end.

get_fd_data_for_read(Fd) ->
    case get_fd_data(Fd) of
        #{ r_buffer := _ } = Data -> Data;
        _ -> throw({error, ebadf})
    end.

build_fd_data(Modes, FRef) -> build_fd_data(Modes, FRef, self(), 0, default).

build_fd_data([], FRef, Owner, _RASz, write) ->
    #{ handle => FRef, owner => Owner };
build_fd_data([], FRef, Owner, RASz, Mode) when Mode =:= read; Mode =:= default ->
    #{ handle => FRef, owner => Owner, r_ahead_size => RASz, r_buffer => prim_buffer:new() };
build_fd_data([read_ahead | Modes], FRef, Owner, _, Mode) ->
    build_fd_data(Modes, FRef, Owner, 64 bsl 10, Mode);
build_fd_data([{read_ahead, RASz} | Modes], FRef, Owner, _, Mode) ->
    build_fd_data(Modes, FRef, Owner, RASz, Mode);
build_fd_data([write | Modes], FRef, Owner, RASz, default) ->
    build_fd_data(Modes, FRef, Owner, RASz, write);
build_fd_data([read | Modes], FRef, Owner, RASz, _Mode) ->
    build_fd_data(Modes, FRef, Owner, RASz, read);
build_fd_data([_Ignored | Modes], FRef, Owner, RASz, Mode) ->
    build_fd_data(Modes, FRef, Owner, RASz, Mode).

open_nif(_Name, _Modes) ->
    erlang:nif_error(undef).
file_desc_to_ref_nif(_FD) ->
    erlang:nif_error(undef).
close_nif(_FileRef) ->
    erlang:nif_error(undef).
read_nif(_FileRef, _Size) ->
    erlang:nif_error(undef).
write_nif(_FileRef, _IOVec) ->
    erlang:nif_error(undef).
pread_nif(_FileRef, _Offset, _Size) ->
    erlang:nif_error(undef).
pwrite_nif(_FileRef, _Offset, _IOVec) ->
    erlang:nif_error(undef).
seek_nif(_FileRef, _Mark, _Offset) ->
    erlang:nif_error(undef).
sync_nif(_FileRef, _DataOnly) ->
    erlang:nif_error(undef).
advise_nif(_FileRef, _Offset, _Length, _Advise) ->
    erlang:nif_error(undef).
allocate_nif(_FileRef, _Offset, _Length) ->
    erlang:nif_error(undef).
truncate_nif(_FileRef) ->
    erlang:nif_error(undef).
get_handle_nif(_FileRef) ->
    erlang:nif_error(undef).
delayed_close_nif(_FileRef) ->
    erlang:nif_error(undef).
read_handle_info_nif(_FileRef) ->
    erlang:nif_error(undef).

%%
%% Quality-of-life helpers
%%

read_file(Filename) ->
    %% We're doing this operation in the NIF to avoid excessive rescheduling.
    try
        Encoded = encode_path(Filename),
        erx_at(Encoded, fun read_file_nif/1,
               fun(Grant, Place) -> erx_file_remote:read_file(Grant, Place, Encoded) end)
    catch
        error:badarg -> {error, badarg}
    end.
read_file_nif(_Filename) ->
    erlang:nif_error(undef).

%% erXos: where a path lies, read from the namespace's table and the working directory
%% (design-files.md, Erlang clients). A path on the release answers {release, Names},
%% its names from the release's top, and the operation is its NIF's call on them. A
%% path on a file server's grant answers {remote, Grant, Place}, Grant {Pid, Tree,
%% Rights} as the path's entry holds it and Place {Point, Root, Names}, the entry's
%% point and root and the path's names from the tree's root, the entry's root's
%% first, each as text, and the operation runs in this process through
%% erx_file_remote. A path on a grant whose server ended answers eio.
%%
%% Until erx_path resolves every path (TODO.md, "paths resolve logically"), a path is
%% placed here lexically, as the namespace's C table placed it: from the working
%% directory when relative, empty names and . dropped, and .. dropping the name before
%% it, or nothing at /. That placement and remote/2 go once erx_path places the paths.
erx_at(Encoded, Local, Remote) ->
    case erx_locate(Encoded) of
        {release, Names} -> Local(Names);
        {remote, Grant, Place} -> Remote(Grant, Place);
        {error, _} = Error -> Error
    end.

%% A rename's or a hard link's two paths: on the release both, its NIF's call on
%% their names; otherwise {remote, Grant, Place, OtherGrant, OtherPlace}, a path on
%% the release as local and local, for remote/2. A refusal of either path comes
%% before an ended server's eio, the first path's before the second's.
erx_at_two(Encoded, OtherEncoded, Local) ->
    case erx_locate_two(Encoded, OtherEncoded) of
        [{release, Names}, {release, OtherNames}] -> Local(Names, OtherNames);
        [{error, _} = Error, _] -> Error;
        [_, {error, _} = Error] -> Error;
        [First, Second] when First =:= ended; Second =:= ended -> {error, eio};
        [First, Second] -> list_to_tuple([remote | erx_side(First) ++ erx_side(Second)])
    end.

erx_side({remote, Grant, Place}) -> [Grant, Place];
erx_side({release, _Names}) -> [local, local].

%% One provider takes a pair only when the two grants are equal, the same tree of the
%% same server through the same rights; any other pair is exdev, as between two Unix
%% file systems, and no server is asked.
remote({remote, Grant, Place, Grant, OtherPlace}, Operation) -> Operation(Grant, Place, OtherPlace);
remote({remote, _Grant, _Place, _OtherGrant, _OtherPlace}, _Operation) -> {error, exdev};
remote(Result, _Operation) -> Result.

erx_locate(Encoded) ->
    case erx_place(Encoded) of
        {ok, Place} -> erx_ended(erx_located(Place, erx_table()));
        {error, _} = Error -> Error
    end.

erx_locate_two(Encoded, OtherEncoded) ->
    case {erx_place(Encoded), erx_place(OtherEncoded)} of
        {{ok, Place}, {ok, OtherPlace}} ->
            Table = erx_table(),
            [erx_located(Place, Table), erx_located(OtherPlace, Table)];
        {{error, _} = Error, _} -> [Error, Error];
        {_, {error, _} = Error} -> [Error, Error]
    end.

erx_ended(ended) -> {error, eio};
erx_ended(Located) -> Located.

%% The place an encoded path reaches: enametoolong past ERX_PATH_MAX bytes, for a name
%% past ERX_NAME_MAX, past ERX_NS_NAMES_MAX names or for a place of ERX_PATH_MAX bytes
%% with its NUL; enoent for an empty path; einval for one that is not UTF-8 or holds a
%% NUL.
erx_place(Encoded) ->
    Text = binary:part(Encoded, 0, byte_size(Encoded) - 1),
    Valid = binary:match(Text, <<0>>) =:= nomatch andalso unicode:characters_to_binary(Text, utf8) =:= Text,
    if
        byte_size(Text) > ?ERX_PATH_MAX -> {error, enametoolong};
        Text =:= <<>> -> {error, enoent};
        not Valid -> {error, einval};
        true ->
            {ok, Cwd} = case Text of
                            <<"/", _/binary>> -> {ok, <<>>};
                            _ -> get_cwd_nif()
                        end,
            Split = binary:split(Cwd, <<"/">>, [global]) ++ binary:split(Text, <<"/">>, [global]),
            case erx_steps(Split, [], 0) of
                {ok, Reversed} ->
                    Place = lists:reverse(Reversed, []),
                    case byte_size(erx_text(Place)) < ?ERX_PATH_MAX of
                        true -> {ok, Place};
                        false -> {error, enametoolong}
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

erx_steps([], Names, _Count) -> {ok, Names};
erx_steps([Name | Rest], Names, Count) when Name =:= <<>>; Name =:= <<".">> ->
    erx_steps(Rest, Names, Count);
erx_steps([<<"..">> | Rest], [], 0) -> erx_steps(Rest, [], 0);
erx_steps([<<"..">> | Rest], [_ | Names], Count) -> erx_steps(Rest, Names, Count - 1);
erx_steps([Name | _], _Names, Count) when byte_size(Name) > ?ERX_NAME_MAX; Count =:= ?ERX_NS_NAMES_MAX ->
    {error, enametoolong};
erx_steps([Name | Rest], Names, Count) -> erx_steps(Rest, [Name | Names], Count + 1).

%% The place on the entry whose point is its longest prefix, with the names below the
%% point added to the entry's root. The table always holds /, which erx_ns never
%% unmounts, so every place has an entry. Like the rest of the bridge this calls only
%% BIFs: read_file/1 reads the boot script before stdlib is loaded.
erx_located(Place, Table) ->
    {Below, #{root := Root} = Entry} = erx_holder(Table, Place, none),
    Names = Root ++ Below,
    Joined = erx_joined(Names),
    case length(Names) =< ?ERX_NS_NAMES_MAX andalso byte_size(Joined) < ?ERX_PATH_MAX of
        true -> erx_provided(Entry, Names, Joined);
        false -> {error, enametoolong}
    end.

erx_provided(#{provider := release}, Names, _Joined) ->
    {release, Names};
erx_provided(#{provider := {grant, Pid, Tree}, point := Point, root := Root, rights := Rights}, _Names, Joined) ->
    {remote, {Pid, Tree, Rights}, {erx_text(Point), erx_joined(Root), Joined}};
erx_provided(#{provider := ended}, _Names, _Joined) ->
    ended.

%% A place as text, / and each name; and names joined by /.
erx_text([]) -> <<"/">>;
erx_text(Names) -> iolist_to_binary([[<<"/">>, Name] || Name <- Names]).
erx_joined([]) -> <<>>;
erx_joined([First | Rest]) -> iolist_to_binary([First | [[<<"/">>, Name] || Name <- Rest]]).

%% The entry whose point is Place's longest prefix, with the names of Place below it.
erx_holder([], _Place, Held) ->
    Held;
erx_holder([#{point := Point} = Entry | Rest], Place, Held) ->
    case {erx_below(Point, Place), Held} of
        {false, _} -> erx_holder(Rest, Place, Held);
        {Below, {HeldBelow, _}} when length(Below) > length(HeldBelow) -> erx_holder(Rest, Place, Held);
        {Below, _} -> erx_holder(Rest, Place, {Below, Entry})
    end.

%% The names of Place after Point, or false when Point is not a prefix of it.
erx_below([], Place) -> Place;
erx_below([Name | Point], [Name | Place]) -> erx_below(Point, Place);
erx_below(_Point, _Place) -> false.

%% The working directory set_cwd/1 would store, as {cwd, Place}, or the refusal: on
%% the release, a place whose names all walk as directories; on a grant, the place
%% erx_file_remote:set_cwd/3 reached.
erx_cwd(Encoded) ->
    case erx_place(Encoded) of
        {ok, Place} ->
            case erx_located(Place, erx_table()) of
                {release, Names} -> erx_cwd_on_release(release_walk_nif(Names), Place);
                {remote, Grant, At} -> erx_file_remote:set_cwd(Grant, At, Encoded);
                ended -> {error, eio};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

erx_cwd_on_release({_Kinds, {error, Reason}}, _Place) -> {error, Reason};
erx_cwd_on_release({Kinds, ok}, Place) ->
    case lists:member(other, Kinds) of
        true -> {error, enotdir};
        false -> {cwd, erx_text(Place)}
    end;
erx_cwd_on_release({error, Reason}, _Place) -> {error, Reason}.

%% erXos: one draw of the runtime's fid counter (design-files.md, Version and
%% attach), for erx_file_remote.
erx_fid() ->
    erx_fid_nif().

%% erXos: the cap of the domain's /tmp in bytes, the tmp field of the runtime's startup
%% limits (design-tmp.md, Starting and mounting), for erx_ns.
erx_tmp_limit() ->
    erx_tmp_limit_nif().

%% erXos: the runtime's namespace table (design-files.md, Building, binding and
%% mounting): the persistent term erx_ns's process alone writes, or until it writes one
%% the boot table, the domain's local entries. These are the release slice at /, and
%% each EROFS image where its release names it, of which the boot information names
%% none yet.
erx_table() ->
    persistent_term:get(erx_ns, [#{point => [], provider => release, root => [], rights => ro}]).

%% erXos: where one path lies, or the two of a rename or a link, as their operations
%% would find them, acting on nothing: their remote term, local on the release, or the
%% refusal. erx_file_remote asks it for the path a symbolic link leads to; a text the
%% namespace cannot hold, such as a link's that is not UTF-8, answers einval.
erx_resolve(Paths) ->
    try
        case Paths of
            [Path] ->
                erx_local(erx_locate(encode_path(Path)));
            [Path, OtherPath] ->
                Release = fun(_Names, _OtherNames) -> local end,
                remote(erx_at_two(encode_path(Path), encode_path(OtherPath), Release),
                       fun(Grant, Place, OtherPlace) -> {remote, Grant, Place, OtherPlace} end)
        end
    catch
        error:badarg -> {error, einval}
    end.

erx_local({release, _Names}) -> local;
erx_local(Located) -> Located.

release_walk_nif(_Names) ->
    erlang:nif_error(undef).
erx_set_cwd_nif(_Path) ->
    erlang:nif_error(undef).
erx_fid_nif() ->
    erlang:nif_error(undef).
erx_tmp_limit_nif() ->
    erlang:nif_error(undef).

write_file(Filename, Bytes) ->
    write_file(Filename, Bytes, []).
%% erXos: the file may be a server's, whose descriptor names erx_file_remote.
write_file(Filename, Bytes, Modes) ->
    case open(Filename, [write, binary | Modes]) of
        {ok, #file_descriptor{module = Module} = Fd} ->
            Result = Module:write(Fd, Bytes),
            Module:close(Fd),
            Result;
        {error, Reason} ->
            {error, Reason}
    end.

%%
%% Filesystem operations
%%

read_link(Name) -> read_link_1(Name, false).
read_link_all(Name) -> read_link_1(Name, true).

read_link_1(Name, AcceptRawNames) ->
    Encoded = encode_path(Name),
    try erx_at(Encoded, fun read_link_nif/1,
               fun(Grant, Place) -> erx_file_remote:read_link(Grant, Place, Encoded) end) of
        {ok, RawName} -> translate_raw_name(RawName, AcceptRawNames);
        {error, Reason} -> {error, Reason}
    catch
        error:badarg -> {error, badarg}
    end.

translate_raw_name(RawName, SilentFailure) ->
    case decode_path(RawName) of
        Converted when is_list(Converted) -> {ok, Converted};
        {error, _Reason} when SilentFailure =:= false -> {error, einval};
        {error, _Reason} when SilentFailure =:= true -> {ok, RawName}
    end.

list_dir(Name) -> list_dir_1(Name, true).
list_dir_all(Name) -> list_dir_1(Name, false).

list_dir_1(Name, SkipInvalid) ->
    Encoded = encode_path(Name),
    try erx_at(Encoded, fun list_dir_nif/1,
               fun(Grant, Place) -> erx_file_remote:list_dir(Grant, Place, Encoded) end) of
        {ok, RawNames} -> list_dir_convert(RawNames, SkipInvalid, []);
        {error, Reason} -> {error, Reason}
    catch
        error:badarg -> {error, badarg}
    end.

list_dir_convert([], _SkipInvalid, Result) ->
    {ok, Result};
list_dir_convert([RawName | Rest], SkipInvalid, Result) ->
    case decode_path(RawName) of
        Converted when is_list(Converted) ->
            list_dir_convert(Rest, SkipInvalid, [Converted | Result]);
        {error, _} when SkipInvalid =:= false ->
            list_dir_convert(Rest, SkipInvalid, [RawName | Result]);

        %% If the filename cannot be converted, return error or ignore with
        %% optional error logger warning depending on +fn{u|a}{i|e|w} emulator
        %% switches.
        {error, ignore} ->
            list_dir_convert(Rest, SkipInvalid, Result);
        {error, warning} ->
            %% This is equal to calling logger:warning/3 which
            %% we don't want to do from code_server during system boot.
            %% We don't want to call logger:timestamp() either.
            catch logger ! {log,warning,"Non-unicode filename ~p ignored\n", [RawName],
                          #{pid=>self(),
                            gl=>group_leader(),
                            time=>os:system_time(microsecond),
                            error_logger=>#{tag=>warning_msg}}},
            list_dir_convert(Rest, SkipInvalid, Result);
        {error, _} ->
            {error, {no_translation, RawName}}
    end.

read_file_info(Filename) ->
    read_info_1(Filename, 1, local).
read_file_info(Filename, Opts) ->
    read_info_1(Filename, 1, proplist_get_value(time, Opts, local)).

read_link_info(Name) ->
    read_info_1(Name, 0, local).
read_link_info(Name, Opts) ->
    read_info_1(Name, 0, proplist_get_value(time, Opts, local)).

read_info_1(Name, FollowLinks, TimeType) ->
    try
        Encoded = encode_path(Name),
        case erx_at(Encoded, fun(Names) -> read_info_nif(Names, FollowLinks) end,
                    fun(Grant, Place) ->
                            erx_file_remote:read_file_info(Grant, Place, FollowLinks, Encoded)
                    end) of
            {error, Reason} -> {error, Reason};
            FileInfo -> {ok, adjust_times(FileInfo, TimeType)}
        end
    catch
        error:_ -> {error, badarg}
    end.

read_handle_info(Fd) ->
  read_handle_info_1(Fd, local).
read_handle_info(Fd, Opts) ->
  read_handle_info_1(Fd, proplist_get_value(time, Opts, local)).

read_handle_info_1(Fd, TimeType) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        case read_handle_info_nif(FRef) of
            {error, Reason} -> {error, Reason};
            FileInfo -> {ok, adjust_times(FileInfo, TimeType)}
        end
    catch
        error:_ -> {error, badarg}
    end.

adjust_times(FileInfo, posix) ->
    FileInfo;
adjust_times(FileInfo, TimeType) ->
    CTime = from_posix_seconds(FileInfo#file_info.ctime, TimeType),
    MTime = from_posix_seconds(FileInfo#file_info.mtime, TimeType),
    ATime = from_posix_seconds(FileInfo#file_info.atime, TimeType),
    FileInfo#file_info{ ctime = CTime,
                        mtime = MTime,
                        atime = ATime }.

write_file_info(Filename, Info) ->
    write_file_info_1(Filename, Info, local).
write_file_info(Filename, Info, Opts) ->
    write_file_info_1(Filename, Info, proplist_get_value(time, Opts, local)).

write_file_info_1(Filename, Info, TimeType) ->
    #file_info{ mode = Modes,
                uid = Uid,
                gid = Gid,
                atime = ATime0,
                mtime = MTime0,
                ctime = CTime0} = Info,
    try
        % ATime and/or MTime might be undefined
        %  - use localtime() for atime, if atime is undefined
        %  - use atime as mtime if mtime is undefined
        %  - use mtime as ctime if ctime is undefined
        ATime = file_info_convert_atime(ATime0, TimeType),
        MTime = file_info_convert_mtime(MTime0, ATime, TimeType),
        CTime = file_info_convert_ctime(CTime0, MTime, TimeType),
        EncodedName = encode_path(Filename),

        %% This is a bit ugly but we need to handle partial failures the same
        %% way the old driver did.
        %% erXos: on a grant erx_file_remote sends the steps with the times worked
        %% out here.
        case erx_locate(EncodedName) of
            {release, Names} ->
                throw_on_error(set_owner(Names, Uid, Gid)),
                throw_on_error(set_permissions(Names, Modes)),
                throw_on_error(set_time(Names, ATime, MTime, CTime));
            {remote, Grant, Place} ->
                erx_file_remote:write_file_info(Grant, Place,
                                                Info#file_info{atime = ATime, mtime = MTime},
                                                EncodedName);
            {error, Failure} ->
                throw(Failure)
        end
    catch
        throw:Reason -> {error, Reason};
        error:_ -> {error, badarg}
    end.

set_owner(EncodedName, Uid, undefined) ->
    set_owner(EncodedName, Uid, -1);
set_owner(EncodedName, undefined, Gid) ->
    set_owner(EncodedName, -1, Gid);
set_owner(EncodedName, Uid, Gid) ->
    set_owner_nif(EncodedName, Uid, Gid).
set_owner_nif(_Path, _Uid, _Gid) ->
    erlang:nif_error(undef).

set_permissions(_EncodedName, undefined) ->
    ok;
set_permissions(EncodedName, Permissions) ->
    set_permissions_nif(EncodedName, Permissions).
set_permissions_nif(_Path, _Permissions) ->
    erlang:nif_error(undef).

set_time(EncodedName, ATime, MTime, CTime) ->
    set_time_nif(EncodedName, ATime, MTime, CTime).
set_time_nif(_Path, _ATime, _MTime, _CTime) ->
    erlang:nif_error(undef).

throw_on_error(ok) -> ok;
throw_on_error({error, enotsup}) -> ok;
throw_on_error({error, Reason}) -> throw(Reason).

file_info_convert_atime(ATime, TimeType) when ATime =/= undefined ->
    to_posix_seconds(ATime, TimeType);
file_info_convert_atime(undefined, local) ->
    to_posix_seconds(erlang:localtime(), local);
file_info_convert_atime(undefined, universal) ->
    to_posix_seconds(erlang:universaltime(), universal);
file_info_convert_atime(undefined, posix) ->
    erlang:universaltime_to_posixtime(erlang:universaltime()).

file_info_convert_mtime(undefined, ATime, _TimeType) ->
    ATime;
file_info_convert_mtime(MTime, _ATime, TimeType) ->
    to_posix_seconds(MTime, TimeType).

file_info_convert_ctime(undefined, MTime, _TimeType) ->
    MTime;
file_info_convert_ctime(CTime, _MTime, TimeType) ->
    to_posix_seconds(CTime, TimeType).

%% This is only relevant on Windows, so we assume that format to simplify the
%% internals.
get_cwd([Letter, $:]) when Letter >= $A, Letter =< $Z ->
    get_dcwd(Letter - $A + 1);
get_cwd([Letter, $:]) when Letter >= $a, Letter =< $z ->
    get_dcwd(Letter - $a + 1);
get_cwd([_|_]) ->
    {error, einval};
get_cwd(_) ->
    {error, badarg}.
get_dcwd(Index) ->
    try get_device_cwd_nif(Index) of
        {ok, RawPath} -> {ok, decode_path(RawPath)};
        {error, Reason} -> {error, Reason}
    catch
        error:badarg -> {error, badarg}
    end.

get_cwd() ->
    try get_cwd_nif() of
        {ok, RawPath} -> {ok, decode_path(RawPath)};
        {error, Reason} -> {error, Reason}
    catch
        error:badarg -> {error, badarg}
    end.
%% erXos: the working directory changes only here (design-files.md, Erlang clients). On
%% the release its walk finds a directory, and on a grant erx_file_remote finds one and
%% answers the place it reached; either is stored only once erx_path:cwd/1 reads it as a
%% place, so a relative path is always read from one.
set_cwd(Path) ->
    try
        case is_path_translatable(Path) of
            true ->
                case erx_cwd(encode_path(Path)) of
                    {cwd, Reached} ->
                        case erx_path:cwd(Reached) of
                            {ok, _Place} -> erx_set_cwd_nif(Reached);
                            error -> {error, einval}
                        end;
                    Answer ->
                        Answer
                end;
            false -> {error, no_translation}
        end
    catch
        error:badarg -> {error, badarg}
    end.

delete(Path) ->
    try
        Encoded = encode_path(Path),
        erx_at(Encoded, fun del_file_nif/1,
               fun(Grant, Place) -> erx_file_remote:delete(Grant, Place, Encoded) end)
    catch
        error:badarg -> {error, badarg}
    end.

rename(Source, Destination) ->
    try
        {EncodedSource, EncodedDestination} = {encode_path(Source), encode_path(Destination)},
        remote(renamed_root(EncodedSource, erx_at_two(EncodedSource, EncodedDestination, fun rename_nif/2)),
               fun(Grant, Place, OtherPlace) ->
                       erx_file_remote:rename(Grant, Place, OtherPlace,
                                              EncodedSource, EncodedDestination)
               end)
    catch
        error:badarg -> {error, badarg}
    end.
%% erXos: the one site of rename's step 1 (design-files.md, Errors): a source written
%% "/" answers einval once both paths resolve, as stock's efile_rename answers a failed
%% rename of "/" by its text. Its NIF answers past resolution are a pair a grant takes
%% part in, before remote/2 compares the grants and before a server is asked; eio, a
%% path on a grant whose server ended; and erofs, from the NIF's read-only providers.
%% A refusal of a path itself, such as enoent or enametoolong, comes first.
renamed_root(<<"/", 0>>, {remote, _Grant, _Place, _OtherGrant, _OtherPlace}) -> {error, einval};
renamed_root(<<"/", 0>>, {error, Reason}) when Reason =:= eio; Reason =:= erofs -> {error, einval};
renamed_root(_Source, Answer) -> Answer.

make_dir(Path) ->
    try
        Encoded = encode_path(Path),
        erx_at(Encoded, fun make_dir_nif/1,
               fun(Grant, Place) -> erx_file_remote:make_dir(Grant, Place, Encoded) end)
    catch
        error:badarg -> {error, badarg}
    end.
del_dir(Path) ->
    try
        Encoded = encode_path(Path),
        erx_at(Encoded, fun del_dir_nif/1,
               fun(Grant, Place) -> erx_file_remote:del_dir(Grant, Place, Encoded) end)
    catch
        error:badarg -> {error, badarg}
    end.
make_link(Existing, New) ->
    try
        {EncodedExisting, EncodedNew} = {encode_path(Existing), encode_path(New)},
        remote(erx_at_two(EncodedExisting, EncodedNew, fun make_hard_link_nif/2),
               fun(Grant, Place, OtherPlace) ->
                       erx_file_remote:make_link(Grant, Place, OtherPlace,
                                                 EncodedExisting, EncodedNew)
               end)
    catch
        error:badarg -> {error, badarg}
    end.
make_symlink(Existing, New) ->
    try
        {Target, EncodedNew} = {encode_path(Existing), encode_path(New)},
        erx_at(EncodedNew, fun(Names) -> make_soft_link_nif(Target, Names) end,
               fun(Grant, Place) ->
                       erx_file_remote:make_symlink(Grant, Place, Target, EncodedNew)
               end)
    catch
        error:badarg -> {error, badarg}
    end.

altname(Path) ->
    try altname_nif(encode_path(Path)) of
        {ok, RawPath} -> {ok, decode_path(RawPath)};
        Other -> Other
    catch
        error:badarg -> {error, badarg}
    end.

list_dir_nif(_Path) ->
    erlang:nif_error(undef).
read_link_nif(_Path) ->
    erlang:nif_error(undef).
read_info_nif(_Path, _FollowLinks) ->
    erlang:nif_error(undef).
make_hard_link_nif(_Existing, _New) ->
    erlang:nif_error(undef).
make_soft_link_nif(_Existing, _New) ->
    erlang:nif_error(undef).
rename_nif(_Source, _Destination) ->
    erlang:nif_error(undef).
make_dir_nif(_Path) ->
    erlang:nif_error(undef).
del_file_nif(_Path) ->
    erlang:nif_error(undef).
del_dir_nif(_Path) ->
    erlang:nif_error(undef).
get_device_cwd_nif(_DevicePath) ->
    erlang:nif_error(undef).
get_cwd_nif() ->
    erlang:nif_error(undef).
altname_nif(_Path) ->
    erlang:nif_error(undef).

%%
%% General helper functions.
%%

%% We know for certain that lists:reverse/2 is a BIF, so it's safe to use it
%% even though this module is preloaded.
reverse_list(List) -> lists:reverse(List, []).

proplist_get_value(_Key, [], Default) ->
    Default;
proplist_get_value(Key, [{Key, Value} | _Rest], _Default) ->
    Value;
proplist_get_value(Key, [Key | _Rest], _Default) ->
    true;
proplist_get_value(Key, [_Other | Rest], Default) ->
    proplist_get_value(Key, Rest, Default).

encode_path(Path) ->
    prim_file:internal_name2native(Path).
decode_path(NativePath) when is_binary(NativePath) ->
    prim_file:internal_native2name(NativePath).

is_path_translatable(Path) when is_list(Path) ->
    true;
is_path_translatable(Path) ->
    prim_file:is_translatable(Path).

%% We don't actually want this here
%%
%% We want to use posix time in all prim but erl_prim_loader makes that tricky
%% It is probably needed to redo the whole erl_prim_loader

from_posix_seconds(Seconds, universal) when is_integer(Seconds) ->
    erlang:posixtime_to_universaltime(Seconds);
from_posix_seconds(Seconds, local) when is_integer(Seconds) ->
    erlang:universaltime_to_localtime(erlang:posixtime_to_universaltime(Seconds)).

to_posix_seconds(Seconds, posix) when is_integer(Seconds) ->
    Seconds;
to_posix_seconds({_,_} = Datetime, universal) ->
    erlang:universaltime_to_posixtime(Datetime);
to_posix_seconds({_,_} = Datetime, local) ->
    erlang:universaltime_to_posixtime(erlang:localtime_to_universaltime(Datetime)).
