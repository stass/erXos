%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_media_raw).
-moduledoc """
A medium's raw process (docs/design-drives.md, "Raw sectors"): the one way from the raw
tree, erx_media_raw_tree, to the medium. The drive process starts it, a temporary child
of the medium's supervisor, at the first open of a raw file of the medium, and it runs
until that supervisor ends. Its files are `data`, the medium whole, and one for each
volume the table lists, each placed by erx_media_table:place/3.

* **Opens.** A reading open is answered at once and counted nowhere. A writing open is
  counted among the writers as it arrives (erx_media_raw_barrier), its grant monitored,
  and only then is the drive process asked for the volumes the file covers
  (`{raw_take, ...}`); its answer names what it took, which the raw process holds
  whether or not the take succeeded. A take that failed refuses the open with its
  answer; otherwise the window is sent one flush, and anything but `ok` refuses the open,
  `erofs` for `enotsup`. A refused open leaves the count as a close does and hands
  nothing back itself.
* **Closes.** A writing open leaves the count at its clunk, which the grant runs once the
  fid's requests have settled, or at the end of the grant it came through, which counts
  as the close of every open made through it.
* **Requests.** Reads and writes are waiting requests whose keeper this process is,
  checked by plan/3 and sent to the window as pieces of the most sectors one window
  request carries, as the window's `info` names it, one request at a time, in arrival order. A request is begun when its first piece is
  sent; one flushed before that is answered `eintr` by its set. An fsync is the window's
  flush.
* **The barrier.** Whatever the raw process holds returns behind the barrier alone
  (`{raw_hand_back, ...}`), and a flush the barrier sends that fails ends the process,
  which the drive process, monitoring it, takes as the end of the medium.
* **The finish.** The drive process's finish, at an eject (`eio`) or the ordered end
  (`erofs`), answers every later request and every queued request not yet sent with that
  errno, and is answered once nothing sent is unanswered and the window has flushed.
""".

-behaviour(gen_server).

-include("generated/erx_abi.hrl").
-include("erx_fs_waits.hrl").

-export([start_link/3, open/3, close/2, fsync/1, plan/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export_type([file/0]).

-define(SECTOR, 512).

%% A raw file: `data`, the medium whole, or volume N's sectors.
-type file() :: data | pos_integer().

-doc """
Starts the raw process of the medium behind the window proxy Proxy, linked to the
caller, the medium's supervisor: Drive is the drive process and Volumes the volumes the
medium's table lists. It asks the window for the medium's capacity, and fails to start
when the window does not answer it.
""".
-spec start_link(pid(), pid(), [erx_media_table:volume()]) -> {ok, pid()} | {error, term()}.
start_link(Drive, Proxy, Volumes) ->
    gen_server:start_link(?MODULE, {Drive, Proxy, Volumes}, []).

-doc """
Opens File of the raw process Raw for Mode, for the calling grant: `{ok, Open}`, the
open's name for close/2, or `{error, Errno}`: `enoent` for a file the medium does not
hold, the take's or the flush's failure for a writing open, the finish's errno once it
has come, and `eio` for a raw process that has ended.
""".
-spec open(pid(), file(), read | write) -> {ok, reference() | read} | {error, atom()}.
open(Raw, File, Mode) -> call(Raw, {open, File, Mode}).

-doc "Closes the writing open Open of the calling grant.".
-spec close(pid(), reference()) -> ok | {error, atom()}.
close(Raw, Open) -> call(Raw, {close, Open}).

-doc "The window's flush, as an fsync of a raw file asks it.".
-spec fsync(pid()) -> ok | {error, atom()}.
fsync(Raw) -> call(Raw, fsync).

-doc """
The window requests of a client's Request on a file of Volume's placement (the medium
whole is `#{first => 0, length => Capacity}`), or `einval`: offsets and counts must be
multiples of 512 and counts at most `p9_io_max`, the file protocol's own bound; a write must end within the file; a
read that runs past the end is cut at it, and one that starts at or past it has no
request. Each request is at most Piece sectors, placed by erx_media_table:place/3.
""".
-spec plan({read, non_neg_integer(), non_neg_integer()} | {write, non_neg_integer(), binary()},
           #{first := non_neg_integer(), length := non_neg_integer(), _ => _}, pos_integer()) ->
          {ok, [{read, non_neg_integer(), pos_integer()} | {write, non_neg_integer(), binary()}]}
        | {error, einval}.
plan({read, Offset, Count}, #{length := Length} = Volume, Piece)
  when is_integer(Offset), Offset >= 0, Offset rem ?SECTOR =:= 0,
       is_integer(Count), Count >= 0, Count rem ?SECTOR =:= 0, Count =< ?ERX_P9_IO_MAX ->
    First = Offset div ?SECTOR,
    Sectors = max(0, min(Count div ?SECTOR, Length - First)),
    placed([{read, Sector, N} || {Sector, N} <- pieces(First, Sectors, Piece)], Volume);
plan({write, Offset, Bytes}, #{length := Length} = Volume, Piece)
  when is_integer(Offset), Offset >= 0, Offset rem ?SECTOR =:= 0, is_binary(Bytes),
       byte_size(Bytes) rem ?SECTOR =:= 0, byte_size(Bytes) =< ?ERX_P9_IO_MAX,
       Offset + byte_size(Bytes) =< Length * ?SECTOR ->
    First = Offset div ?SECTOR,
    placed([{write, Sector, binary:part(Bytes, (Sector - First) * ?SECTOR, N * ?SECTOR)}
            || {Sector, N} <- pieces(First, byte_size(Bytes) div ?SECTOR, Piece)], Volume);
plan(_Request, _Volume, _Piece) ->
    {error, einval}.

%% Sectors from First split into pieces of at most Piece sectors.
pieces(_First, 0, _Piece) -> [];
pieces(First, Sectors, Piece) ->
    N = min(Sectors, Piece),
    [{First, N} | pieces(First + N, Sectors - N, Piece)].

%% Each piece placed on the medium; a piece placement refuses is the request's einval.
placed(Pieces, Volume) ->
    try
        {ok, [place(Piece, Volume) || Piece <- Pieces]}
    catch
        throw:{?MODULE, erange} -> {error, einval}
    end.

place({read, Sector, N}, Volume) -> {read, lba(Volume, Sector, N), N};
place({write, Sector, Bytes}, Volume) -> {write, lba(Volume, Sector, byte_size(Bytes) div ?SECTOR), Bytes}.

lba(Volume, Sector, N) ->
    case erx_media_table:place(Volume, Sector, N) of
        {ok, Lba} -> Lba;
        {error, erange} -> throw({?MODULE, erange})
    end.

call(Raw, Request) ->
    try gen_server:call(Raw, Request, infinity) catch exit:_Ended -> {error, eio} end.

%% ---------------------------------------------------------------------------
%% The process
%% ---------------------------------------------------------------------------

%% The state:
%%
%% * files: each raw file's placement; piece: the most sectors one window request carries;
%% * barrier: erx_media_raw_barrier's counts;
%% * queue: the window's requests not yet sent, in order, and current, the one sent, as
%%   {Origin, Pieces, Done}: Origin is {client, Wait, Kind, Offset}, {open, Open}, fsync
%%   with its caller, or flush (the barrier's or the finish's); Pieces the window
%%   requests left and Done the answers so far, newest first;
%% * waits: the waiting requests held (erx_fs_waits);
%% * opens: each writing open by its name, with its grant and its caller while it waits
%%   for its take and its flush, or none once answered; grants: each grant with an open
%%   counted, with its monitor;
%% * finish: none, or the errno later requests answer and the caller of the finish.
-doc false.
init({Drive, Proxy, Volumes}) ->
    case erx_media_medium:window(Proxy, info) of
        {ok, #{sectors := Capacity}} = Info when is_integer(Capacity), Capacity >= 0 ->
            Files = maps:from_list([{data, #{first => 0, length => Capacity}}
                                    | [{N, V} || #{number := N} = V <- Volumes]]),
            {ok, #{drive => Drive, proxy => Proxy, files => Files, piece => erx_media_medium:run_sectors(Info),
                   barrier => erx_media_raw_barrier:new(),
                   queue => queue:new(), current => none, waits => erx_fs_waits:new(),
                   opens => #{}, grants => #{}, finish => none}};
        Answer ->
            {stop, {info, Answer}}
    end.

-doc false.
%% The drive process's finish, answered once the barrier has flushed.
handle_call({finish, Errno}, From, #{finish := none} = State) ->
    finish_requested(Errno, From, State);
handle_call(_Request, _From, #{finish := {Errno, _}} = State) ->
    {reply, {error, Errno}, State};
handle_call({open, File, Mode}, From, #{files := Files} = State) when is_map_key(File, Files) ->
    opened(Mode, File, From, State);
handle_call({open, _File, _Mode}, _From, State) ->
    {reply, {error, enoent}, State};
handle_call({close, Open}, {Grant, _}, #{opens := Opens} = State) ->
    case Opens of
        #{Open := {Grant, none}} -> {reply, ok, left(Open, State)};
        #{} -> {reply, ok, State}
    end;
handle_call(fsync, From, State) ->
    {noreply, queued({fsync, From}, [flush], State)};
handle_call(_Other, _From, State) ->
    {reply, {error, badarg}, State}.

-doc false.
handle_cast(_Cast, State) ->
    {noreply, State}.

-doc false.
handle_info(?ERX_FS_WAIT(Wait, _Request), #{finish := {Errno, _}, waits := Waits} = State) ->
    {noreply, State#{waits := erx_fs_waits:answer(Wait, {error, Errno}, erx_fs_waits:hold(?ERX_FS_WAIT(Wait, none), Waits))}};
handle_info(?ERX_FS_WAIT(Wait, Request) = Message, #{files := Files, piece := Piece, waits := Waits} = State) ->
    Held = erx_fs_waits:hold(Message, Waits),
    case client(Request, Files, Piece) of
        {ok, [], Kind, Offset} ->
            {noreply, State#{waits := erx_fs_waits:answer(Wait, empty(Kind, Offset), Held)}};
        {ok, Pieces, Kind, Offset} ->
            {noreply, queued({client, Wait, Kind, Offset}, Pieces, State#{waits := Held})};
        {error, _} = Refused ->
            {noreply, State#{waits := erx_fs_waits:answer(Wait, Refused, Held)}}
    end;
handle_info({raw_took, Open, Covers, Answer}, State) ->
    took(Open, Answer, step({took, Covers}, State));
handle_info({'DOWN', Monitor, process, Grant, _Why}, #{grants := Grants} = State)
  when map_get(Grant, Grants) =:= Monitor ->
    Ended = [Open || {Open, {G, _}} <- maps:to_list(maps:get(opens, State)), G =:= Grant],
    {noreply, lists:foldl(fun left/2, State, Ended)};
handle_info(Message, #{current := {_Origin, Request, _Pieces, _Done}} = State) ->
    case gen_server:check_response(Message, Request) of
        no_reply -> waits_info(Message, State);
        {reply, Answer} -> piece_answered(Answer, State);
        {error, {_Reason, _Proxy}} -> piece_answered({error, eio}, State)
    end;
handle_info(Message, State) ->
    waits_info(Message, State).

%% A message of the waits set: a flush answers a request not yet begun eintr and forgets
%% it, which the queue drops when it reaches it; a grant's end forgets its requests.
waits_info(Message, #{waits := Waits} = State) ->
    case erx_fs_waits:info(Message, Waits) of
        {flushed, Waits1} -> {noreply, State#{waits := Waits1}};
        {begun, _Wait, _Request, Waits1} -> {noreply, State#{waits := Waits1}};
        {dropped, Waits1} -> {noreply, State#{waits := Waits1}};
        unknown -> {noreply, State}
    end.

%% A client's waiting request checked and placed: its pieces, its kind and its offset.
client({Kind, File, Offset, CountOrBytes}, Files, Piece) when Kind =:= read; Kind =:= write ->
    case Files of
        #{File := Volume} ->
            case plan({Kind, Offset, CountOrBytes}, Volume, Piece) of
                {ok, Pieces} when Kind =:= read -> {ok, Pieces, read, Offset};
                {ok, Pieces} -> {ok, Pieces, {write, byte_size(CountOrBytes)}, Offset};
                {error, _} = Refused -> Refused
            end;
        #{} ->
            {error, eio}
    end;
client(_Request, _Files, _Piece) ->
    {error, einval}.

empty(read, _Offset) -> {ok, <<>>};
empty({write, 0}, Offset) -> {ok, 0, Offset}.

%% Opens ----------------------------------------------------------------------

opened(read, _File, _From, State) ->
    {reply, {ok, read}, State};
opened(write, File, {Grant, _} = From, #{drive := Drive, opens := Opens, grants := Grants} = State) ->
    Open = make_ref(),
    Monitored = case Grants of
                    #{Grant := _} -> Grants;
                    #{} -> Grants#{Grant => monitor(process, Grant)}
                end,
    Counted = step(arrive, State#{opens := Opens#{Open => {Grant, From}}, grants := Monitored}),
    Drive ! {raw_take, self(), Open, cover(File)},
    {noreply, Counted}.

cover(data) -> medium;
cover(N) -> {volume, N}.

%% The drive process's answer to a take: the open, unless it has left meanwhile, flushes
%% the window or is refused.
took(Open, Answer, #{opens := Opens} = State) ->
    case {Opens, Answer} of
        {#{Open := {_Grant, From}}, ok} when From =/= none -> {noreply, queued({open, Open}, [flush], State)};
        {#{Open := {_Grant, From}}, {error, Errno}} when From =/= none -> {noreply, refused(Open, Errno, State)};
        _Left -> {noreply, State}
    end.

%% The open's flush answered: ok answers the open, anything else refuses it.
open_flushed(Open, Answer, #{opens := Opens} = State) ->
    case {Opens, Answer} of
        {#{Open := {Grant, From}}, ok} ->
            gen_server:reply(From, {ok, Open}),
            State#{opens := Opens#{Open := {Grant, none}}};
        {#{Open := _}, {error, enotsup}} -> refused(Open, erofs, State);
        {#{Open := _}, {error, Errno}} when is_atom(Errno) -> refused(Open, Errno, State);
        {#{Open := _}, _Other} -> refused(Open, eio, State);
        {#{}, _} -> State
    end.

refused(Open, Errno, #{opens := Opens} = State) ->
    #{Open := {_Grant, From}} = Opens,
    gen_server:reply(From, {error, Errno}),
    left(Open, State).

%% An open leaves the count: its clunk, its grant's end, or its refusal.
left(Open, #{opens := Opens, grants := Grants} = State) ->
    #{Open := {Grant, _From}} = Opens,
    Remaining = maps:remove(Open, Opens),
    Kept = case [O || {O, {G, _}} <- maps:to_list(Remaining), G =:= Grant] of
               [] -> demonitor(maps:get(Grant, Grants), [flush]), maps:remove(Grant, Grants);
               _ -> Grants
           end,
    step(leave, State#{opens := Remaining, grants := Kept}).

%% The finish --------------------------------------------------------------------

%% Every queued request not yet sent answers Errno, every open still waiting is refused
%% with it, and the barrier answers the finish once nothing sent is unanswered.
finish_requested(Errno, From, #{queue := Queue, opens := Opens} = State) ->
    Finishing = step(finish, State#{queue := queue:new(), finish := {Errno, From}}),
    Waiting = [Open || {Open, {_Grant, Caller}} <- maps:to_list(Opens), Caller =/= none],
    Refused = lists:foldl(fun(Open, S) -> refused(Open, Errno, S) end, Finishing, Waiting),
    {noreply, lists:foldl(fun(Entry, S) -> step(answered, dropped(Entry, Errno, S)) end, Refused,
                          queue:to_list(Queue))}.

dropped({{client, Wait, _Kind, _Offset}, _Pieces}, Errno, #{waits := Waits} = State) ->
    State#{waits := erx_fs_waits:answer(Wait, {error, Errno}, Waits)};
dropped({{fsync, From}, _Pieces}, Errno, State) ->
    gen_server:reply(From, {error, Errno}),
    State;
dropped({_Origin, _Pieces}, _Errno, State) ->
    State.

%% The window -------------------------------------------------------------------

%% A request queued for the window, counted as sent, and the queue run.
queued(Origin, Pieces, #{queue := Queue} = State) ->
    next(step(queued, State#{queue := queue:in({Origin, Pieces}, Queue)})).

%% The next queued request sent, when none is on its way. A client's request flushed
%% before it began is dropped, answered already.
next(#{current := none, queue := Queue} = State) ->
    case queue:out(Queue) of
        {empty, _} -> State;
        {{value, Entry}, Rest} -> started(Entry, State#{queue := Rest})
    end;
next(State) ->
    State.

%% A client's request is begun as its first piece is sent; one its set no longer holds
%% waiting, flushed meanwhile, is dropped, answered already.
started({{client, Wait, _, _} = Origin, Pieces}, #{waits := Waits} = State) ->
    case lists:member(Wait, [W || {W, _Request, waiting} <- erx_fs_waits:list(Waits)]) of
        true -> send(Origin, Pieces, [], State#{waits := erx_fs_waits:began(Wait, Waits)});
        false -> next(step(answered, State))
    end;
started({Origin, Pieces}, State) ->
    send(Origin, Pieces, [], State).

%% A request's next piece sent to the window, Done the answers of the pieces before it,
%% newest first; a write piece marks the barrier's wrote.
send(Origin, [Piece | Pieces], Done, #{proxy := Proxy} = State) ->
    Sent = State#{current := {Origin, gen_server:send_request(Proxy, Piece), Pieces, Done}},
    case Piece of
        {write, _, _} -> step(wrote, Sent);
        _ -> Sent
    end.

%% A piece's answer: the request's next piece, once this one succeeded, or its end.
piece_answered(Answer, #{current := {Origin, _Request, Pieces, Done}} = State) ->
    case {Answer, Pieces} of
        {ok, [_ | _]} -> {noreply, send(Origin, Pieces, [ok | Done], State)};
        {{ok, Bytes}, [_ | _]} when is_binary(Bytes) -> {noreply, send(Origin, Pieces, [{ok, Bytes} | Done], State)};
        _Last -> {noreply, next(ended(Origin, lists:reverse([Answer | Done]), State#{current := none}))}
    end.

%% A request's end, with every piece's answer in order: the requester answered, and the
%% barrier told.
ended({client, Wait, read, _Offset}, Answers, #{waits := Waits} = State) ->
    step(answered, State#{waits := erx_fs_waits:answer(Wait, read_answer(Answers, []), Waits)});
ended({client, Wait, {write, Size}, Offset}, Answers, #{waits := Waits} = State) ->
    step(answered, State#{waits := erx_fs_waits:answer(Wait, write_answer(Answers, Size, Offset), Waits)});
ended({open, Open}, [Answer], State) ->
    step(answered, open_flushed(Open, Answer, State));
ended({fsync, From}, [Answer], State) ->
    gen_server:reply(From, Answer),
    step(answered, State);
ended(flush, [Answer], State) ->
    step({flushed, Answer}, State).

%% A read answers the bytes of its pieces up to the first that failed, or that failure
%% when it was the first.
read_answer([{ok, Bytes} | Rest], Read) when is_binary(Bytes) -> read_answer(Rest, [Bytes | Read]);
read_answer([], Read) -> {ok, iolist_to_binary(lists:reverse(Read))};
read_answer([_Failed | _], [_ | _] = Read) -> {ok, iolist_to_binary(lists:reverse(Read))};
read_answer([Failed | _], []) -> failure(Failed).

%% A write answers its count when every piece landed, and otherwise the first failure.
write_answer([ok | Rest], Size, Offset) -> write_answer(Rest, Size, Offset);
write_answer([], Size, Offset) -> {ok, Size, Offset};
write_answer([Failed | _], _Size, _Offset) -> failure(Failed).

failure({error, Errno}) when is_atom(Errno) -> {error, Errno};
failure(_Other) -> {error, eio}.

%% The barrier ------------------------------------------------------------------

%% An event fed to the barrier, and its actions performed in order.
step(Event, #{barrier := Barrier} = State) ->
    {Actions, Barrier1} = erx_media_raw_barrier:step(Event, Barrier),
    lists:foldl(fun act/2, State#{barrier := Barrier1}, Actions).

act(flush, #{queue := Queue} = State) ->
    next(State#{queue := queue:in_r({flush, [flush]}, Queue)});
act({hand_back, Covers}, #{drive := Drive} = State) ->
    Drive ! {raw_hand_back, self(), Covers},
    State;
act({fail, Why}, _State) ->
    exit({raw, Why});
act({finished, Answer}, #{finish := {_Errno, From}} = State) ->
    gen_server:reply(From, finish_answer(Answer)),
    State.

finish_answer(ok) -> ok;
finish_answer(Answer) -> failure(Answer).
