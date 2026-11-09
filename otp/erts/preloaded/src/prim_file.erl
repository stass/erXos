%% Modified by erXos: a path on the release reaches the NIF as its names, a path on an
%% EROFS image the EROFS reader, and a path on a file server's grant erx_file_remote.
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

%% erXos: the namespace's table, for erx_ns, and the runtime's fid counter, for
%% erx_file_remote.
-export([erx_table/0, erx_fid/0, erx_tmp_limit/0]).

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
%% erXos: FreeBSD's FOLLOW and WILLBEDIR for erx_path (design-files.md, Resolving a path).
-define(ERX_FOLLOW, #{follow => true, willbedir => false}).
-define(ERX_NOFOLLOW, #{follow => false, willbedir => false}).
-define(LARGEFILESIZE, (1 bsl 63)).

%% erXos: open/2 answers for a file of a server (erx_file_remote) or of a mounted
%% image (erx_erofs_file) with a descriptor naming that module. Each operation on an
%% open file forwards such a descriptor to its module, as file does, so prim_file
%% takes every descriptor its own open returns.
-define(ERX_FILE(Module), (Module =:= erx_file_remote orelse Module =:= erx_erofs_file)).

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
        Ops = #{release => fun(Names) -> opened(open_nif(Names, Modes), Modes) end,
                remote => fun(Grant, Where) -> erx_file_remote:open(Grant, Where, Modes) end,
                image => fun(Fs, Names) -> erx_erofs_file:open(Fs, Names, Modes) end,
                image_exists => erx_open_exists(Modes),
                top => erx_open_top(Modes)},
        case {erx_has(write, Modes) orelse erx_has(append, Modes), erx_has(exclusive, Modes)} of
            {_, true} -> erx_do(Encoded, create, ?ERX_NOFOLLOW, Ops);
            {true, false} -> erx_do(Encoded, create, ?ERX_FOLLOW, Ops);
            {false, false} -> erx_do(Encoded, lookup, ?ERX_FOLLOW, Ops)
        end
    catch
        error:badarg -> {error, badarg}
    end.

opened({ok, Ref}, Modes) -> {ok, make_fd(Modes, Ref)};
opened({error, Reason}, _Modes) -> {error, Reason}.

%% erXos: an open that creates, at a top, an existing directory (design-files.md, Errors,
%% step 3): einval for [directory], which is never opened to write, else eexist when
%% exclusive and eisdir otherwise, as vn_open_cred answers.
erx_open_top(Modes) ->
    case {erx_has(directory, Modes), erx_has(exclusive, Modes)} of
        {true, _} -> {error, einval};
        {false, true} -> {error, eexist};
        {false, false} -> {error, eisdir}
    end.

%% Whether the mode list holds Mode, reading only its proper part, as the NIF reads it.
erx_has(Mode, [Mode | _]) -> true;
erx_has(Mode, [_ | Modes]) -> erx_has(Mode, Modes);
erx_has(_, _) -> false.

file_desc_to_ref(FileDescriptorId, Modes) ->
    try file_desc_to_ref_nif(FileDescriptorId) of
        {ok, Ref} -> {ok, make_fd(Modes, Ref)};
        {error, Reason} -> {error, Reason}
    catch
        error:badarg -> {error, badarg}
    end.

make_fd(Modes, FRef) ->
    #file_descriptor{module = ?MODULE, data = build_fd_data(Modes, FRef) }.

close(#file_descriptor{module = Module} = Fd) when ?ERX_FILE(Module) ->
    Module:close(Fd);
close(Fd) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        close_nif(FRef)
    catch
        error:badarg -> {error, badarg}
    end.

read(#file_descriptor{module = Module} = Fd, Size) when ?ERX_FILE(Module) ->
    Module:read(Fd, Size);
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

read_line(#file_descriptor{module = Module} = Fd) when ?ERX_FILE(Module) ->
    Module:read_line(Fd);
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

write(#file_descriptor{module = Module} = Fd, IOData) when ?ERX_FILE(Module) ->
    Module:write(Fd, IOData);
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

truncate(#file_descriptor{module = Module} = Fd) when ?ERX_FILE(Module) ->
    Module:truncate(Fd);
truncate(Fd) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        reset_write_position(Fd),
        truncate_nif(FRef)
    catch
        error:badarg -> {error, badarg}
    end.

advise(#file_descriptor{module = Module} = Fd, Offset, Length, Advise) when ?ERX_FILE(Module) ->
    Module:advise(Fd, Offset, Length, Advise);
advise(Fd, Offset, Length, Advise) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        advise_nif(FRef, Offset, Length, Advise)
    catch
        error:badarg -> {error, badarg}
    end.

allocate(#file_descriptor{module = Module} = Fd, Offset, Length) when ?ERX_FILE(Module) ->
    Module:allocate(Fd, Offset, Length);
allocate(Fd, Offset, Length) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        allocate_nif(FRef, Offset, Length)
    catch
        error:badarg -> {error, badarg}
    end.

sync(#file_descriptor{module = Module} = Fd) when ?ERX_FILE(Module) ->
    Module:sync(Fd);
sync(Fd) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        sync_nif(FRef, 0)
    catch
        error:badarg -> {error, badarg}
    end.

datasync(#file_descriptor{module = Module} = Fd) when ?ERX_FILE(Module) ->
    Module:datasync(Fd);
datasync(Fd) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        sync_nif(FRef, 1)
    catch
        error:badarg -> {error, badarg}
    end.

position(#file_descriptor{module = Module} = Fd, At) when ?ERX_FILE(Module) ->
    Module:position(Fd, At);
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

pread(#file_descriptor{module = Module} = Fd, Offset, Size) when ?ERX_FILE(Module) ->
    Module:pread(Fd, Offset, Size);
pread(Fd, Offset, Size) ->
    try
        #{ handle := FRef } = get_fd_data(Fd),
        pread_nif(FRef, Offset, Size)
    catch
        error:badarg -> {error, badarg}
    end.

pread(#file_descriptor{module = Module} = Fd, LocNums) when ?ERX_FILE(Module) ->
    Module:pread(Fd, LocNums);
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

pwrite(#file_descriptor{module = Module} = Fd, Offset, IOData) when ?ERX_FILE(Module) ->
    Module:pwrite(Fd, Offset, IOData);
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

pwrite(#file_descriptor{module = Module} = Fd, LocBytes) when ?ERX_FILE(Module) ->
    Module:pwrite(Fd, LocBytes);
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

sendfile(#file_descriptor{module = Module} = Fd, Socket, Offset, Bytes, ChunkSize, Headers, Trailers, Flags) when ?ERX_FILE(Module) ->
    Module:sendfile(Fd, Socket, Offset, Bytes, ChunkSize, Headers, Trailers, Flags);
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
ipread_s32bu_p32bu(#file_descriptor{module = Module} = Fd, Offset, MaxSize) when ?ERX_FILE(Module) ->
    Module:ipread_s32bu_p32bu(Fd, Offset, MaxSize);
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
        erx_do(Encoded, lookup, ?ERX_FOLLOW,
               #{release => fun read_file_nif/1, remote => fun erx_file_remote:read_file/2,
                 image => fun erx_erofs:read_file/2})
    catch
        error:badarg -> {error, badarg}
    end.
read_file_nif(_Filename) ->
    erlang:nif_error(undef).

%% erXos: every path resolves through erx_path (design-files.md, Erlang clients), over the
%% namespace's table and the working directory, with the operation's nameiop and FreeBSD's
%% flags, and the operation runs where the resolver's last action lies: on the release,
%% its NIF's call on the action's names, the last name's included; on a file server's
%% grant, through erx_file_remote, whose {resume, Which, Reply} hands a walk's reply back
%% to that path's resumption; on an EROFS image, the reader's call (erx_image/4); on a
%% grant whose server ended, eio. Ops holds the operation's release and remote calls, its
%% image call if it only reads, its image_exists answer if it creates, and, for one that
%% names its last name, its answer at a top; any other answers eio, as no lookup ends at
%% one. Like erx_path this calls only BIFs and preloaded modules: read_file/1 reads the
%% boot script before stdlib is loaded.
erx_do(Encoded, Op, Flags, Ops) ->
    element(2, erx_do_at(Encoded, Op, Flags, erx_table(), Ops)).

%% erx_do/4 over Table, answering the action the operation ran at as well.
erx_do_at(Encoded, Op, Flags, Table, Ops) ->
    erx_run_at(erx_resolve(Encoded, Op, Flags, Table), erx_mode(Flags), Ops).

%% How a target's last name is walked, as the operation's flags follow it.
erx_mode(#{follow := true}) -> follow;
erx_mode(#{}) -> nofollow.

erx_resolve(Encoded, Op, Flags, Table) ->
    Text = binary:part(Encoded, 0, byte_size(Encoded) - 1),
    {ok, Cwd} = get_cwd_nif(),
    case erx_path:cwd(Cwd) of
        {ok, Place} ->
            erx_path:resolve(Text, Op, Flags, Table, Place,
                             #{walk => fun erx_walk/2, read_link => fun erx_link_text/2});
        error ->
            {error, eio}
    end.

%% The action an operation ran at, each walk that stopped handed to its resumption, and
%% the operation's answer there.
erx_run_at({error, _} = Error, _Mode, _Ops) ->
    {Error, Error};
erx_run_at(Action, Mode, #{release := Local, remote := Remote} = Ops) ->
    case erx_where(Action) of
        top -> {Action, erx_top(Ops)};
        {release, Names} -> {Action, Local(Names)};
        {grant, Grant, Where} -> erx_ran(Action, Remote(Grant, Where), Mode, Ops);
        {image, Entry, Where} -> erx_ran(Action, erx_image(Entry, Where, Mode, Ops), Mode, Ops);
        ended -> {Action, {error, eio}}
    end.

erx_ran(Action, {resume, 1, Reply}, Mode, Ops) -> erx_run_at(erx_resume(Action, Reply), Mode, Ops);
erx_ran(Action, Answer, _Mode, _Ops) -> {Action, Answer}.

%% An operation on an EROFS image (design-storage.md, Reading EROFS images), run in the
%% calling process as a grant's runs at its server.
%%
%% The action's names are walked first. A walk that did not pass as the operation asks,
%% having stopped short or ended on a link it follows, goes back as {resume, 1, Reply},
%% as erx_file_remote's does, for the action's resumption.
%%
%% A target then runs the operation's image call on its names; an operation that
%% writes has none and answers erofs.
%%
%% A parent comes from an operation that creates, deletes or renames. One that creates
%% names in its image_exists call what it answers for a last name that exists: the last
%% name is walked with the directory, a link followed as the operation's flags say, and
%% a missing one answers erofs, as FreeBSD's lookup answers CREATE on a read-only mount.
%% Delete and rename have no such call and answer erofs once the directory is walked,
%% as FreeBSD refuses their last name before it looks it up.
erx_image(#{provider := {erofs, Fs}} = Entry, {target, Names}, Mode, Ops) ->
    case {erx_walked(Entry, Names, Mode), Ops} of
        {{stopped, Reply}, _} -> {resume, 1, Reply};
        {{passed, _}, #{image := Image}} -> Image(Fs, Names);
        {{passed, _}, #{}} -> {error, erofs}
    end;
erx_image(Entry, {parent, Names, Last}, Mode, #{image_exists := Exists}) ->
    Directories = length(Names),
    case erx_walked(Entry, Names ++ [Last], Mode) of
        {passed, Kind} -> Exists(Kind);
        {stopped, {Kinds, {error, enoent}}} when length(Kinds) =:= Directories -> {error, erofs};
        {stopped, Reply} -> {resume, 1, Reply}
    end;
erx_image(Entry, {parent, Names, _Last}, _Mode, _Ops) ->
    case erx_walked(Entry, Names, directory) of
        {stopped, Reply} -> {resume, 1, Reply};
        {passed, _} -> {error, erofs}
    end.

%% What an open that writes answers at an existing name on an EROFS image, in the order
%% of open(2) with O_CREAT, as the release's NIF answers: eexist when exclusive, eisdir
%% for a directory, and erofs for anything else.
erx_open_exists(Modes) ->
    Exclusive = erx_has(exclusive, Modes),
    fun(_) when Exclusive -> {error, eexist};
       (directory) -> {error, eisdir};
       (_) -> {error, erofs}
    end.

%% What make_dir, make_symlink and make_link answer at an existing name on an image.
erx_eexist(_Kind) ->
    {error, eexist}.

%% A rename's or a hard link's two last actions, from one table, the first settled. On
%% one grant, one tree and one set of rights Remote's one request takes both, and a walk
%% that stopped goes to its own path's resumption before the two are compared again; on
%% the release both, its NIF's call on their names. A second path on an EROFS image
%% answers as Ops's image_exists call says once it is walked (erx_image/4); only
%% make_link reaches it, since a rename onto an image is refused before (erx_read_only/1).
%% Any other
%% pair is exdev, as between two UNIX file systems, once the second's walk has passed,
%% and no server is asked to act. A failure comes first, the first path's before the
%% second's, then a top's Top.
erx_two({error, _} = Error, _, _) ->
    Error;
erx_two(_, {error, _} = Error, _) ->
    Error;
erx_two(First, Second, #{release := Local, remote := Remote} = Ops) ->
    case {erx_where(First), erx_where(Second)} of
        {top, _} ->
            erx_top(Ops);
        {_, top} ->
            erx_top(Ops);
        {{release, Names}, {release, OtherNames}} ->
            Local(Names, OtherNames);
        {{grant, Grant, Where}, {grant, Grant, OtherWhere}} ->
            case Remote(Grant, Where, OtherWhere) of
                {resume, 1, Reply} -> erx_two(erx_resume(First, Reply), Second, Ops);
                {resume, 2, Reply} -> erx_two(First, erx_resume(Second, Reply), Ops);
                Answer -> Answer
            end;
        {ended, _} ->
            {error, eio};
        {_, ended} ->
            {error, eio};
        {_, {image, Entry, Where}} ->
            case erx_image(Entry, Where, nofollow, Ops) of
                {resume, 1, Reply} -> erx_two(First, erx_resume(Second, Reply), Ops);
                Answer -> Answer
            end;
        _ ->
            case erx_settle(Second, directory) of
                {Second, _} -> {error, exdev};
                {Moved, _} -> erx_two(First, Moved, Ops)
            end
    end.

%% Where an action lies. prim_file's table always holds /, which erx_ns never unmounts,
%% so no action lies in the empty root; one would answer eio.
erx_where({target, Entry, Names, _}) -> erx_on(Entry, {target, Names});
erx_where({parent, Entry, Names, Last, _}) -> erx_on(Entry, {parent, Names, Last});
erx_where({top, _}) -> top;
erx_where({empty_root, _}) -> ended.

erx_top(#{top := Top}) -> Top;
erx_top(_Ops) -> {error, eio}.

erx_on(#{provider := release}, {target, Names}) -> {release, Names};
erx_on(#{provider := release}, {parent, Names, Last}) -> {release, Names ++ [Last]};
erx_on(#{provider := {grant, Pid, Tree}, rights := Rights}, Where) -> {grant, {Pid, Tree, Rights}, Where};
erx_on(#{provider := {erofs, _}} = Entry, Where) -> {image, Entry, Where};
erx_on(#{provider := ended}, _) -> ended.

erx_resume({target, _, _, Resume}, Reply) -> Resume(Reply);
erx_resume({parent, _, _, _, Resume}, Reply) -> Resume(Reply).

%% Walks an action's names until they pass as Mode asks (erx_file_remote:passed/2), each
%% reply that does not going to the action's resumption, and answers the action reached
%% and the kind of the last name walked. A parent is walked as its directory, or under
%% nofollow with its last name too, as a rename's source must exist: so kern_renameat
%% and kern_linkat look up the first path whole before the second, and the second before
%% they compare the two.
erx_settle(Action, Mode) ->
    case erx_walk_action(Action, Mode) of
        {passed, Kind} -> {Action, Kind};
        {stopped, Reply} -> erx_settle(erx_resume(Action, Reply), Mode);
        none -> {Action, none}
    end.

erx_walk_action({target, Entry, Names, _}, Mode) -> erx_walked(Entry, Names, Mode);
erx_walk_action({parent, Entry, Names, Last, _}, nofollow) -> erx_walked(Entry, Names ++ [Last], nofollow);
erx_walk_action({parent, Entry, Names, _, _}, Mode) -> erx_walked(Entry, Names, Mode);
erx_walk_action(_, _) -> none.

erx_walked(_Entry, [], _Mode) ->
    {passed, directory};
erx_walked(Entry, Names, Mode) ->
    case erx_walk(Entry, Names) of
        {Kinds, ok} = Reply when length(Kinds) =:= length(Names) ->
            case erx_file_remote:passed(Kinds, Mode) of
                true -> {passed, erx_last(Kinds)};
                false -> {stopped, Reply}
            end;
        Reply ->
            {stopped, Reply}
    end.

erx_last([Kind]) -> Kind;
erx_last([_ | Kinds]) -> erx_last(Kinds).

%% erx_path's callbacks, by the entry's provider. The release holds no links, so its walk
%% never reports one to read; an EROFS image's are read by the reader.
erx_walk(#{provider := release}, Names) -> release_walk_nif(Names);
erx_walk(#{provider := {grant, Pid, Tree}, rights := Rights}, Names) -> erx_file_remote:walk({Pid, Tree, Rights}, Names);
erx_walk(#{provider := {erofs, Fs}}, Names) -> erx_erofs:walk(Fs, Names);
erx_walk(#{provider := ended}, _Names) -> {[], {error, eio}}.

erx_link_text(#{provider := {grant, Pid, Tree}, rights := Rights}, Names) ->
    erx_file_remote:link_text({Pid, Tree, Rights}, Names);
erx_link_text(#{provider := {erofs, Fs}}, Names) ->
    erx_erofs:read_link(Fs, Names);
erx_link_text(_Entry, _Names) ->
    {error, eio}.

%% The working directory set_cwd/1 would store, as {cwd, Text}: the place its target
%% reached (erx_path:target_place/1), once the release's walk, the image's or
%% erx_file_remote:set_cwd/2 has found a directory there.
erx_cwd({target, _, Names, _} = Action) ->
    Found = case erx_where(Action) of
                {release, _} -> erx_cwd_on_release(release_walk_nif(Names));
                {grant, Grant, Where} -> erx_file_remote:set_cwd(Grant, Where);
                {image, Entry, _} -> erx_image_cwd(erx_walked(Entry, Names, follow));
                ended -> {error, eio}
            end,
    case Found of
        ok -> {cwd, erx_text(erx_path:target_place(Action))};
        {resume, 1, Reply} -> erx_cwd(erx_resume(Action, Reply));
        Error -> Error
    end;
erx_cwd({error, _} = Error) ->
    Error;
erx_cwd(_Elsewhere) ->
    {error, eio}.

%% set_cwd's answer on an image: a directory, its last link followed, or enotdir.
erx_image_cwd({passed, directory}) -> ok;
erx_image_cwd({passed, _}) -> {error, enotdir};
erx_image_cwd({stopped, Reply}) -> {resume, 1, Reply}.

erx_cwd_on_release({[], ok}) -> ok;
erx_cwd_on_release({[_ | _] = Kinds, ok}) ->
    case erx_last(Kinds) of
        directory -> ok;
        _ -> {error, enotdir}
    end;
erx_cwd_on_release({_Kinds, {error, Reason}}) -> {error, Reason};
erx_cwd_on_release({error, Reason}) -> {error, Reason}.

%% A place as text: / and each name.
erx_text([]) -> <<"/">>;
erx_text(Names) -> iolist_to_binary([[<<"/">>, Name] || Name <- Names]).

%% Error step 5's identity of the directory a path reaches, its last link followed, or
%% none when it lies on no grant or reaching it fails, so two failures never compare as
%% one directory.
erx_identity(Encoded) ->
    case erx_do(Encoded, lookup, ?ERX_FOLLOW, #{release => fun(_) -> none end,
                                                remote => fun erx_file_remote:identity/2,
                                                image => fun(_, _) -> none end}) of
        {Pid, Tree, QidPath} -> {Pid, Tree, QidPath};
        _ -> none
    end.

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
%% none yet; erx_ns:mount/3 mounts an image the runtime holds a window on.
erx_table() ->
    persistent_term:get(erx_ns, [#{point => [], provider => release, root => [], rights => ro}]).


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
    try erx_do(encode_path(Name), lookup, ?ERX_NOFOLLOW,
               #{release => fun read_link_nif/1, remote => fun erx_file_remote:read_link/2,
                 image => fun erx_erofs:read_link/2}) of
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

%% erXos: a directory lists its provider's names and the mount points directly below it
%% (erx_path:listing/3), from the one table the path resolved over.
list_dir_1(Name, SkipInvalid) ->
    Table = erx_table(),
    try erx_do_at(encode_path(Name), lookup, ?ERX_FOLLOW, Table,
                  #{release => fun list_dir_nif/1, remote => fun erx_file_remote:list_dir/2,
                    image => fun erx_erofs:list_dir/2}) of
        {Action, {ok, RawNames}} ->
            list_dir_convert(erx_path:listing(Action, RawNames, Table), SkipInvalid, []);
        {_, {error, Reason}} ->
            {error, Reason}
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
        case erx_info(Encoded, FollowLinks) of
            {error, Reason} -> {error, Reason};
            #file_info{type = symlink, access = undefined} = FileInfo ->
                {ok, adjust_times(FileInfo#file_info{access = erx_link_access(Encoded)}, TimeType)};
            FileInfo -> {ok, adjust_times(FileInfo, TimeType)}
        end
    catch
        error:_ -> {error, badarg}
    end.

%% erXos: a path's #file_info{}, its last link followed when FollowLinks is 1.
erx_info(Encoded, FollowLinks) ->
    erx_do(Encoded, lookup, #{follow => FollowLinks =:= 1, willbedir => false},
           #{release => fun(Names) -> read_info_nif(Names, FollowLinks) end,
             remote => fun(Grant, Where) -> erx_file_remote:read_file_info(Grant, Where, FollowLinks =:= 1) end,
             image => fun erx_erofs:file_info/2}).

%% erXos: a link's own record takes the access of the file it leads to, as stock's
%% access(2) follows links, or none when that is a link again or is not reached.
erx_link_access(Encoded) ->
    case erx_info(Encoded, 1) of
        #file_info{type = Type, access = Access} when Type =/= symlink -> Access;
        _ -> none
    end.

read_handle_info(Fd) ->
    read_handle_info(Fd, []).
read_handle_info(#file_descriptor{module = Module} = Fd, Opts) when ?ERX_FILE(Module) ->
    Module:read_handle_info(Fd, Opts);
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
        Remote = fun(Grant, Where) ->
                         erx_file_remote:write_file_info(Grant, Where, Info#file_info{atime = ATime, mtime = MTime})
                 end,
        case erx_do(EncodedName, lookup, ?ERX_FOLLOW, #{release => fun(Names) -> {release, Names} end,
                                                         remote => Remote}) of
            {release, Names} ->
                throw_on_error(set_owner(Names, Uid, Gid)),
                throw_on_error(set_permissions(Names, Modes)),
                throw_on_error(set_time(Names, ATime, MTime, CTime));
            Answer ->
                Answer
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
%% erXos: the working directory changes only here (design-files.md, Erlang clients): the
%% path resolves as chdir resolves it, its last link followed, and the place it reached,
%% once a directory is found there, is stored only when erx_path:cwd/1 reads it as a
%% place, so a relative path is always read from one.
set_cwd(Path) ->
    try
        case is_path_translatable(Path) of
            true ->
                case erx_cwd(erx_resolve(encode_path(Path), lookup, ?ERX_FOLLOW, erx_table())) of
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
        %% Error steps 2 to 4: a last "." or ".." (einval) and a directory (eisdir) are
        %% eperm, as kern_funlinkat and stock's efile_del_file turn them, and so is a top.
        case erx_do(encode_path(Path), delete, ?ERX_NOFOLLOW,
                    #{release => fun del_file_nif/1, remote => fun erx_file_remote:delete/2,
                      top => {error, eperm}}) of
            {error, Reason} when Reason =:= einval; Reason =:= eisdir -> {error, eperm};
            Answer -> Answer
        end
    catch
        error:badarg -> {error, badarg}
    end.

rename(Source, Destination) ->
    try
        {EncodedSource, EncodedDestination} = {encode_path(Source), encode_path(Destination)},
        case EncodedSource of
            <<"/", 0>> -> {error, einval};
            _ -> erx_rename(EncodedSource, EncodedDestination, erx_table())
        end
    catch
        error:badarg -> {error, badarg}
    end.

%% erXos: rename's two paths on one table (design-files.md, Erlang clients). Step 1 of
%% the errors, a source written "/", answers einval above, before the source is resolved,
%% the one place a path's text as written is read. A source that is an entry's top
%% answers ebusy before the destination is resolved, as kern_renameat answers. The source
%% is settled first, its last name walked, so that the destination's missing last name
%% written with a trailing "/" may be made only for a directory (WILLBEDIR), and the
%% destination's degenerate "/" answers einval for a directory, as kern_renameat sets
%% the one and turns the other. A path on a read-only entry, the release's included, answers erofs once its
%% directory is walked, before its last name is looked up, as FreeBSD's lookup refuses
%% DELETE's and RENAME's last name on a read-only mount. enotempty becomes eexist (step 4).
erx_rename(EncodedSource, EncodedDestination, Table) ->
    Source = erx_resolve(EncodedSource, delete, ?ERX_NOFOLLOW, Table),
    case erx_read_only(Source) orelse erx_settle(Source, nofollow) of
        true ->
            erx_refused(Source);
        {{error, _} = Error, _} ->
            Error;
        {{top, _}, _} ->
            {error, ebusy};
        {From, Kind} ->
            Directory = Kind =:= directory,
            To = case erx_resolve(EncodedDestination, rename, #{follow => false, willbedir => Directory}, Table) of
                     {error, eisdir} when Directory -> {error, einval};
                     Resolved -> Resolved
                 end,
            case erx_read_only(To) orelse erx_two(From, To, #{release => fun rename_nif/2,
                                                              remote => fun erx_file_remote:rename/3,
                                                              top => {error, ebusy}}) of
                true -> erx_refused(To);
                {error, enotempty} -> {error, eexist};
                Answer -> Answer
            end
    end.

%% Whether a parent lies on an entry that takes no write.
erx_read_only({parent, #{provider := release}, _, _, _}) -> true;
erx_read_only({parent, #{rights := Rights}, _, _, _}) -> Rights =/= rw;
erx_read_only(_) -> false.

%% erofs for a read-only parent once its directory is walked, or the walk's failure.
erx_refused(Action) ->
    case erx_settle(Action, directory) of
        {{error, _} = Error, _} -> Error;
        _ -> {error, erofs}
    end.

make_dir(Path) ->
    try
        erx_do(encode_path(Path), create, #{follow => false, willbedir => true},
               #{release => fun make_dir_nif/1, remote => fun erx_file_remote:make_dir/2,
                 image_exists => fun erx_eexist/1,
                 top => {error, eexist}})
    catch
        error:badarg -> {error, badarg}
    end.
del_dir(Path) ->
    try
        Encoded = encode_path(Path),
        case erx_do(Encoded, delete, ?ERX_NOFOLLOW,
                    #{release => fun del_dir_nif/1, remote => fun erx_file_remote:del_dir/2,
                      top => {error, ebusy}}) of
            {error, Full} when Full =:= enotempty; Full =:= eexist -> erx_working_directory(Encoded);
            Answer -> Answer
        end
    catch
        error:badarg -> {error, badarg}
    end.

%% erXos: error steps 4 and 5: a directory del_dir found full answers einval when it is
%% the working directory, as stock answers after it compares the stats of the path and of
%% ".", else eexist.
erx_working_directory(Encoded) ->
    {ok, Cwd} = get_cwd_nif(),
    case erx_identity(Encoded) of
        none -> {error, eexist};
        Identity ->
            case erx_identity(<<Cwd/binary, 0>>) of
                Identity -> {error, einval};
                _ -> {error, eexist}
            end
    end.
make_link(Existing, New) ->
    try
        %% erXos: the existing path, its last link followed, is settled before the new
        %% name is resolved, as kern_linkat looks it up first, so its failure answers,
        %% and a directory answers eperm before the new name is looked up, as
        %% kern_linkat_vp answers.
        {EncodedExisting, EncodedNew} = {encode_path(Existing), encode_path(New)},
        Table = erx_table(),
        case erx_settle(erx_resolve(EncodedExisting, lookup, ?ERX_FOLLOW, Table), follow) of
            {{error, _} = Error, _} ->
                Error;
            {_, directory} ->
                {error, eperm};
            {Linked, _} ->
                erx_two(Linked, erx_resolve(EncodedNew, create, ?ERX_NOFOLLOW, Table),
                        #{release => fun make_hard_link_nif/2, remote => fun erx_file_remote:make_link/3,
                          image_exists => fun erx_eexist/1,
                          top => {error, eexist}})
        end
    catch
        error:badarg -> {error, badarg}
    end.
make_symlink(Existing, New) ->
    try
        {Target, EncodedNew} = {encode_path(Existing), encode_path(New)},
        erx_do(EncodedNew, create, ?ERX_NOFOLLOW,
               #{release => fun(Names) -> make_soft_link_nif(Target, Names) end,
                 remote => fun(Grant, Where) -> erx_file_remote:make_symlink(Grant, Where, Target) end,
                 image_exists => fun erx_eexist/1,
                 top => {error, eexist}})
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
