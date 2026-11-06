%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_erofs_file).
-moduledoc """
An open file of an EROFS image (docs/design-storage.md, Reading EROFS
images): `prim_file:open/2` answers with `open/3` for a path on an image
that it opens to read, and the descriptor is OTP's `#file_descriptor{}`
with this module as its module, so `file` dispatches the open file's
operations here.

The image never changes, so the descriptor holds the mount and the file's
names from the image's root, and each read is the reader's `pread/4` on
them: the file those names reach at the open is the file they reach at
every later read. Its data holds besides only the opening process, which
alone may use it, as stock's raw files are used, and an atomics array of
its offset and whether it is closed. It reads ahead nothing, and every
operation that writes answers as stock's does on a file opened only to
read.

It calls only BIFs and preloaded modules, since it runs in whatever process
reads a path, the code server included.
""".

-export([open/3]).
%% An open file's operations, which file dispatches to by its descriptor's module.
-export([close/1, read/2, read_line/1, pread/2, pread/3, position/2, read_handle_info/2,
         write/2, pwrite/2, pwrite/3, truncate/1, sync/1, datasync/1, advise/4, allocate/3,
         sendfile/8]).

-include("file.hrl").

%% The cells of the atomics array.
-define(OFFSET, 1).
-define(CLOSED, 2).
%% The largest offset position/2 sets, an off_t's.
-define(OFFSET_MAX, ((1 bsl 63) - 1)).
%% The bytes read_line/1 reads at a time while it looks for the end of a line, stock's
%% least read of read_line.
-define(LINE_READ, 256).

-type posix() :: atom().

-doc """
Opens the regular file `Names` names on the mount `Fs` to read: `eisdir`
for a directory and `enotdir` for anything else opened with `directory`,
as stock answers; a directory opened with `directory` answers `enotsup`,
since no operation here reads one.
""".
-spec open(erx_erofs:fs(), [binary()], list()) -> {ok, #file_descriptor{}} | {error, posix()}.
open(Fs, Names, Modes) ->
    case {erx_erofs:file_info(Fs, Names), has(directory, Modes)} of
        {{error, _} = Error, _} ->
            Error;
        {#file_info{type = directory}, true} ->
            {error, enotsup};
        {#file_info{type = directory}, false} ->
            {error, eisdir};
        {#file_info{}, true} ->
            {error, enotdir};
        {#file_info{type = regular}, false} ->
            Cells = atomics:new(2, [{signed, false}]),
            {ok, #file_descriptor{module = ?MODULE,
                                  data = #{fs => Fs, names => Names, owner => self(),
                                           cells => Cells}}};
        {#file_info{}, false} ->
            {error, einval}
    end.

%% Whether the mode list holds Mode, reading only its proper part, as the NIF reads it.
has(Mode, [Mode | _]) -> true;
has(Mode, [_ | Modes]) -> has(Mode, Modes);
has(_, _) -> false.

%% The open file's state, for its controlling process alone: any other process's call
%% raises, as stock's get_fd_data/1 raises. A closed file answers einval, as stock's does.
on_open(#file_descriptor{module = ?MODULE, data = #{owner := Owner, cells := Cells} = File}, Act) ->
    case {self(), atomics:get(Cells, ?CLOSED)} of
        {Owner, 0} -> Act(File);
        {Owner, _} -> {error, einval};
        _ -> error(not_on_controlling_process)
    end.

%% A second close answers einval.
-spec close(#file_descriptor{}) -> ok | {error, posix()}.
close(Fd) ->
    on_open(Fd, fun(#{cells := Cells}) -> atomics:put(Cells, ?CLOSED, 1) end).

%% Reading --------------------------------------------------------------------

%% Reads from the offset and moves it past what was read.
-spec read(#file_descriptor{}, non_neg_integer()) -> {ok, binary()} | eof | {error, posix()}.
read(Fd, Size) when is_integer(Size), Size >= 0 ->
    on_open(Fd, fun(#{cells := Cells} = File) ->
                        Offset = atomics:get(Cells, ?OFFSET),
                        case read_at(File, Offset, Size) of
                            {ok, Data} = Read ->
                                atomics:put(Cells, ?OFFSET, Offset + byte_size(Data)),
                                Read;
                            Other ->
                                Other
                        end
                end);
read(_, _) ->
    {error, badarg}.

read_at(#{fs := Fs, names := Names}, Offset, Size) ->
    erx_erofs:pread(Fs, Names, Offset, Size).

%% A positioned read answers eof for no bytes, a request of none included, and einval
%% for a negative offset or size, as stock's pread_nif answers.
-spec pread(#file_descriptor{}, integer(), integer()) -> {ok, binary()} | eof | {error, posix()}.
pread(Fd, Offset, Size) when is_integer(Offset), is_integer(Size) ->
    on_open(Fd, fun(File) -> read_placed(File, Offset, Size) end);
pread(_, _, _) ->
    {error, badarg}.

read_placed(_, Offset, Size) when Offset < 0; Size < 0 ->
    {error, einval};
read_placed(File, Offset, Size) ->
    case read_at(File, Offset, Size) of
        {ok, <<>>} -> eof;
        Read -> Read
    end.

-spec pread(#file_descriptor{}, [{integer(), integer()}]) ->
          {ok, [binary() | eof]} | {error, posix() | badarg}.
pread(Fd, Positions) ->
    on_open(Fd, fun(File) -> read_each(File, Positions, []) end).

read_each(_, [], Results) ->
    {ok, reverse(Results, [])};
read_each(File, [{Offset, Size} | Positions], Results) when is_integer(Offset), is_integer(Size) ->
    case read_placed(File, Offset, Size) of
        {ok, Data} -> read_each(File, Positions, [Data | Results]);
        eof -> read_each(File, Positions, [eof | Results]);
        Error -> Error
    end;
read_each(_, _, _) ->
    {error, badarg}.

%% The bytes up to and including the next "\n", a "\r\n" given as "\n" as stock gives it,
%% or the rest of the file before its end; eof at the end. The offset moves past the line
%% as the file holds it.
-spec read_line(#file_descriptor{}) -> {ok, binary()} | eof | {error, posix()}.
read_line(Fd) ->
    on_open(Fd, fun(#{cells := Cells} = File) ->
                        Offset = atomics:get(Cells, ?OFFSET),
                        case line(File, Offset, <<>>) of
                            {ok, Line} ->
                                atomics:put(Cells, ?OFFSET, Offset + byte_size(Line)),
                                {ok, without_cr(Line)};
                            Other ->
                                Other
                        end
                end).

%% Held is what has been read from Offset on, and holds no "\n".
line(File, Offset, Held) ->
    case read_at(File, Offset + byte_size(Held), ?LINE_READ) of
        {ok, Data} ->
            case binary:match(Data, <<"\n">>) of
                {At, 1} -> {ok, <<Held/binary, (binary:part(Data, 0, At + 1))/binary>>};
                nomatch -> line(File, Offset, <<Held/binary, Data/binary>>)
            end;
        eof when Held =:= <<>> ->
            eof;
        eof ->
            {ok, Held};
        Error ->
            Error
    end.

without_cr(Line) when byte_size(Line) >= 2 ->
    case binary:part(Line, byte_size(Line) - 2, 2) of
        <<"\r\n">> -> <<(binary:part(Line, 0, byte_size(Line) - 2))/binary, "\n">>;
        _ -> Line
    end;
without_cr(Line) ->
    Line.

%% Sets the offset, from the start, the offset or the end; einval for an offset that
%% would fall before the start or past an off_t.
-spec position(#file_descriptor{}, term()) -> {ok, non_neg_integer()} | {error, posix() | badarg}.
position(Fd, At) ->
    on_open(Fd, fun(File) -> moved(File, At) end).

moved(File, Mark) when Mark =:= bof; Mark =:= cur; Mark =:= eof ->
    moved(File, {Mark, 0});
moved(File, Offset) when is_integer(Offset) ->
    moved(File, {bof, Offset});
moved(#{cells := Cells} = File, {Mark, Offset}) when is_integer(Offset) ->
    case base(File, Mark) of
        {ok, Base} when Base + Offset >= 0, Base + Offset =< ?OFFSET_MAX ->
            atomics:put(Cells, ?OFFSET, Base + Offset),
            {ok, Base + Offset};
        {ok, _} -> {error, einval};
        Error -> Error
    end;
moved(_, _) ->
    {error, badarg}.

base(_, bof) ->
    {ok, 0};
base(#{cells := Cells}, cur) ->
    {ok, atomics:get(Cells, ?OFFSET)};
base(#{fs := Fs, names := Names}, eof) ->
    case erx_erofs:file_info(Fs, Names) of
        #file_info{size = Size} -> {ok, Size};
        Error -> Error
    end;
base(_, _) ->
    {error, badarg}.

%% file:read_file_info/2 on an open file: the record of a stat of its names, its times
%% in the type asked for.
-spec read_handle_info(#file_descriptor{}, list()) -> {ok, #file_info{}} | {error, posix()}.
read_handle_info(Fd, Options) ->
    try
        on_open(Fd, fun(#{fs := Fs, names := Names}) ->
                            case {time_type(Options), erx_erofs:file_info(Fs, Names)} of
                                {badarg, _} -> {error, badarg};
                                {_, {error, _} = Error} -> Error;
                                {Type, Info} -> {ok, times(Info, Type)}
                            end
                    end)
    catch
        %% As stock's read_handle_info_1: a call from another process answers badarg and
        %% raises nothing.
        error:_ -> {error, badarg}
    end.

time_type([{time, Type} | _]) when Type =:= posix; Type =:= universal; Type =:= local -> Type;
time_type([{time, _} | _]) -> badarg;
time_type([_ | Options]) -> time_type(Options);
time_type(_) -> local.

%% As stock's adjust_times/2 converts them.
times(Info, posix) ->
    Info;
times(#file_info{atime = ATime, mtime = MTime, ctime = CTime} = Info, Type) ->
    Info#file_info{atime = datetime(ATime, Type), mtime = datetime(MTime, Type),
                   ctime = datetime(CTime, Type)}.

datetime(Seconds, universal) -> erlang:posixtime_to_universaltime(Seconds);
datetime(Seconds, local) -> erlang:universaltime_to_localtime(erlang:posixtime_to_universaltime(Seconds)).

%% Writing --------------------------------------------------------------------

%% The file was opened only to read: a write answers ebadf, as stock's does on such a
%% file, and truncate einval, as FreeBSD's kern_ftruncate answers.
-spec write(#file_descriptor{}, iodata()) -> {error, posix()}.
write(Fd, _Bytes) -> on_open(Fd, fun(_) -> {error, ebadf} end).

-spec pwrite(#file_descriptor{}, integer(), iodata()) -> {error, posix()}.
pwrite(Fd, _Offset, _Bytes) -> on_open(Fd, fun(_) -> {error, ebadf} end).

-spec pwrite(#file_descriptor{}, list()) -> {error, {0, posix()}}.
pwrite(Fd, _Positions) ->
    case on_open(Fd, fun(_) -> {error, ebadf} end) of
        {error, Reason} -> {error, {0, Reason}}
    end.

-spec truncate(#file_descriptor{}) -> {error, posix()}.
truncate(Fd) -> on_open(Fd, fun(_) -> {error, einval} end).

%% Nothing is written, so there is nothing to sync.
-spec sync(#file_descriptor{}) -> ok | {error, posix()}.
sync(Fd) -> on_open(Fd, fun(_) -> ok end).

-spec datasync(#file_descriptor{}) -> ok | {error, posix()}.
datasync(Fd) -> on_open(Fd, fun(_) -> ok end).

%% Advice changes nothing a read answers, and it is taken, as posix_fadvise takes it.
-spec advise(#file_descriptor{}, integer(), integer(), atom()) -> ok | {error, posix()}.
advise(Fd, _Offset, _Length, _Advice) -> on_open(Fd, fun(_) -> ok end).

-spec allocate(#file_descriptor{}, integer(), integer()) -> {error, posix()}.
allocate(Fd, _Offset, _Length) -> on_open(Fd, fun(_) -> {error, ebadf} end).

%% An image's file has no descriptor to hand to the host's sendfile: enotsup, on which
%% file:sendfile/5 takes its fallback of reads and sends.
-spec sendfile(#file_descriptor{}, term(), integer(), integer(), integer(), list(), list(),
               list()) -> {error, enotsup}.
sendfile(_Fd, _Socket, _Offset, _Bytes, _ChunkSize, _Headers, _Trailers, _Flags) ->
    {error, enotsup}.

%% lists:reverse/2, which this module cannot call (lists is not preloaded).
reverse([], Tail) -> Tail;
reverse([Head | List], Tail) -> reverse(List, [Head | Tail]).
