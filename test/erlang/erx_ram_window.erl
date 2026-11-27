%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A block window held in RAM (docs/design-crash-states.md, "The window recorder";
%% docs/design-recovery.md, "Four places to inject"): the stand-in for a medium's
%% window proxy that the volume tests, the media tree's tests and the crash-state
%% generator share. It answers the window's requests as erx_blk_window does, one at a
%% time and in order: `info`, `{read, Sector, Count}`, `{write, Sector, Bytes}` and
%% `flush`, from a medium held as one binary, or as {synthesized, Sectors, Sector}, a
%% medium of Sectors sectors each Sector(Lba) answers, with the sectors written kept
%% beside it, so a write copies its sectors, not the image.
%%
%% Options, each optional:
%%
%% * `flush`, what every flush answers (ok);
%% * `cut`, the count of writes applied (infinity); every later write is answered
%%   `eio` unapplied, as a stick pulled out mid-batch;
%% * `notify`, a process sent {flushed, Window} at each flush (none);
%% * `record`, true to keep the trace of design-crash-states, "The construction":
%%   each write with its bytes and answer, each flush with its answer, and each mark
%%   the workload driver sends by mark/2 (false). A recording window takes no
%%   fault, neither a cut nor a failing flush, and refuses to start with one:
%%   the trace's epochs take every write as landed once a flush answers ok.
%%
%% A read of one to max_sectors/0 sectors, a USB transport's max_sectors, which `info`
%% reports, answers a copy of its sectors, as the window does, never a sub-binary of
%% the whole medium, which a volume's memory bound counts; a longer one is `einval`,
%% as the window's. The window keeps a tally of the reads it was asked for, by their
%% counts of sectors, which reads/1 answers. Sent `stall`, the window
%% answers nothing more, as a stick that hangs; sent `stop`, it ends. It also ends
%% once final/1 has its medium or when the process that started it ends, so no
%% volume waits on it, and on a request it does not serve, failing the test.

-module(erx_ram_window).

-export([start/2, ram/2, proxy/2, mark/2, final/1, ram_final/1, counts/1, reads/1, fail_reads/1, max_sectors/0]).
-export_type([medium/0, trace/0, event/0]).

-define(SECTOR, 512).
%% A USB transport's max_sectors (erx_blk_usb), the most sectors the window reads at once.
-define(MAX_SECTORS, 64).

-type medium() :: binary() | {synthesized, pos_integer(), fun((non_neg_integer()) -> binary())}.
-type answer() :: ok | {error, term()}.
-type event() :: {write, non_neg_integer(), binary(), answer()} | {flush, answer()}
               | {'begin', pos_integer()} | {answered, pos_integer()}.
-type trace() :: [event()].

%% A window over Medium with Options, as above, linked to the caller.
-spec start(medium(), #{flush => answer(), cut => non_neg_integer() | infinity, notify => pid() | none,
                        record => boolean()}) -> pid().
start(_Medium, #{record := true} = Options) when map_get(flush, Options) =/= ok; map_get(cut, Options) =/= infinity ->
    error({refused, record_with_faults, maps:with([flush, cut], Options)});
start(Medium, Options) ->
    Owner = self(),
    State = #{medium => Medium, sectors => sectors(Medium), written => #{}, writes => 0, reads => 0, tally => #{}, log => [],
              trace => [], fail_reads => false,
              flush => maps:get(flush, Options, ok), cut => maps:get(cut, Options, infinity),
              notify => maps:get(notify, Options, none), record => maps:get(record, Options, false)},
    spawn_link(fun() -> erlang:monitor(process, Owner), serve(State) end).

%% A writable medium cut after Cut writes, every flush answered ok.
-spec ram(medium(), non_neg_integer() | infinity) -> pid().
ram(Medium, Cut) -> start(Medium, #{cut => Cut}).

%% A medium that writes nothing (every write answered `eio`), whose flush answers
%% Flush and tells the caller {flushed, Window}.
-spec proxy(medium(), answer()) -> pid().
proxy(Medium, Flush) -> start(Medium, #{flush => Flush, cut => 0, notify => self()}).

%% Mark, {'begin', I} or {answered, I}, appended to the trace. It is a call, as the
%% window's requests are, so it falls after every request sent before it.
-spec mark(pid(), {'begin' | answered, pos_integer()}) -> ok.
mark(Window, {Kind, I} = Mark) when (Kind =:= 'begin' orelse Kind =:= answered), is_integer(I), I > 0 ->
    {ok, ok} = gen:call(Window, '$gen_call', {mark, Mark}),
    ok.

%% The medium as Window leaves it, its count of applied writes, its log of written
%% sectors and flushes, and its trace (empty unless recording), as it ends. A
%% window that ended before fails the test rather than leaving it waiting.
-spec final(pid()) -> #{medium := binary() | synthesized, writes := non_neg_integer(), log := [flush | {write, non_neg_integer()}],
                        trace := trace()}.
final(Window) ->
    Ref = erlang:monitor(process, Window),
    Window ! {final, self()},
    receive
        {final, Window, Final} -> erlang:demonitor(Ref, [flush]), Final;
        {'DOWN', Ref, process, Window, Why} -> error({window_ended, Why})
    end.

%% final/1's medium, count of writes and log, as the volume tests read them.
-spec ram_final(pid()) -> {binary() | synthesized, non_neg_integer(), [flush | {write, non_neg_integer()}]}.
ram_final(Window) ->
    #{medium := Medium, writes := Writes, log := Log} = final(Window),
    {Medium, Writes, Log}.

%% The reads and writes Window has answered so far.
-spec counts(pid()) -> {non_neg_integer(), non_neg_integer()}.
counts(Window) ->
    Window ! {counts, self()},
    receive {counts, Window, Reads, Writes} -> {Reads, Writes} end.

%% The reads Window has been asked for: a map from a read's count of sectors to how
%% many reads asked for that count.
-spec reads(pid()) -> #{pos_integer() => pos_integer()}.
reads(Window) ->
    Window ! {tally, self()},
    receive {tally, Window, Tally} -> Tally end.

%% The most sectors a read asks for.
-spec max_sectors() -> pos_integer().
max_sectors() -> ?MAX_SECTORS.

%% Every later read answered `eio`, once the window has said so.
-spec fail_reads(pid()) -> ok.
fail_reads(Window) ->
    Window ! {fail_reads, self()},
    receive reads_failing -> ok end.

%% ---------------------------------------------------------------------------
%% The server
%% ---------------------------------------------------------------------------

serve(S) ->
    receive
        {'DOWN', _, process, _Owner, _} -> ok;
        stop -> ok;
        stall -> stalled();
        {'$gen_call', From, Request} ->
            {Answer, S1} = answer(Request, tallied(Request, S)),
            gen:reply(From, Answer),
            serve(S1);
        {fail_reads, Test} ->
            Test ! reads_failing, serve(S#{fail_reads := true});
        {counts, Test} ->
            #{reads := Reads, writes := Writes} = S,
            Test ! {counts, self(), Reads, Writes}, serve(S);
        {tally, Test} ->
            Test ! {tally, self(), map_get(tally, S)}, serve(S);
        {final, Test} ->
            #{medium := Medium, written := Written, writes := Writes, log := Log, trace := Trace} = S,
            Test ! {final, self(), #{medium => applied(Medium, Written), writes => Writes, log => lists:reverse(Log),
                                     trace => lists:reverse(Trace)}}
    end.

stalled() ->
    receive stop -> ok; _Unanswered -> stalled() end.

answer(info, #{sectors := Sectors} = S) ->
    {{ok, #{role => drive, sectors => Sectors, max_sectors => ?MAX_SECTORS}}, S};
answer({read, _Lba, Count}, S) when not is_integer(Count); Count < 1; Count > ?MAX_SECTORS ->
    {{error, einval}, S};
answer({read, _Lba, _Count}, #{fail_reads := true} = S) ->
    {{error, eio}, S};
answer({read, Lba, Count}, #{sectors := Sectors, reads := Reads} = S)
  when is_integer(Lba), is_integer(Count), Lba >= 0, Count > 0, Lba + Count =< Sectors ->
    {{ok, iolist_to_binary([sector(Sector, S) || Sector <- lists:seq(Lba, Lba + Count - 1)])}, S#{reads := Reads + 1}};
answer({read, _Lba, _Count}, S) ->
    {{error, erange}, S};
answer(flush, #{flush := Flush, notify := Notify, log := Log} = S) ->
    _ = Notify =:= none orelse (Notify ! {flushed, self()}),
    {Flush, traced({flush, Flush}, S#{log := [flush | Log]})};
answer({write, Lba, Bytes}, #{writes := Writes, cut := Cut} = S) when Writes >= Cut ->
    {{error, eio}, traced({write, Lba, Bytes, {error, eio}}, S)};
answer({write, Lba, Bytes}, #{sectors := Sectors, written := Written, writes := Writes, log := Log} = S)
  when is_integer(Lba), Lba >= 0, is_binary(Bytes), byte_size(Bytes) > 0, byte_size(Bytes) rem ?SECTOR =:= 0,
       Lba + byte_size(Bytes) div ?SECTOR =< Sectors ->
    Placed = maps:from_list([{Lba + I, binary:copy(Part)} || {I, Part} <- lists:enumerate(0, split(Bytes))]),
    {ok, traced({write, Lba, Bytes, ok},
                S#{written := maps:merge(Written, Placed), writes := Writes + 1, log := [{write, Lba} | Log]})};
answer({mark, Mark}, S) ->
    {ok, traced(Mark, S)};
answer(Unserved, _S) ->
    error({unserved, Unserved}).

tallied({read, _Lba, Count}, #{tally := Tally} = S) -> S#{tally := maps:update_with(Count, fun(N) -> N + 1 end, 1, Tally)};
tallied(_Request, S) -> S.

traced(Event, #{record := true, trace := Trace} = S) -> S#{trace := [Event | Trace]};
traced(_Event, S) -> S.

sector(Lba, #{written := Written}) when is_map_key(Lba, Written) -> map_get(Lba, Written);
sector(Lba, #{medium := {synthesized, _Sectors, Sector}}) -> binary:copy(Sector(Lba));
sector(Lba, #{medium := Medium}) -> binary:copy(binary:part(Medium, Lba * ?SECTOR, ?SECTOR)).

split(<<>>) -> [];
split(<<Sector:?SECTOR/binary, Rest/binary>>) -> [Sector | split(Rest)].

sectors({synthesized, Sectors, _Sector}) -> Sectors;
sectors(Medium) -> byte_size(Medium) div ?SECTOR.

%% Medium with each sector of Written in its place.
applied({synthesized, _, _}, _Written) ->
    synthesized;
applied(Medium, Written) ->
    {End, Parts} = maps:fold(fun(Lba, Bytes, {At, Acc}) ->
                                     {(Lba + 1) * ?SECTOR, [Acc, binary:part(Medium, At, Lba * ?SECTOR - At), Bytes]}
                             end, {0, []}, maps:iterator(Written, ordered)),
    iolist_to_binary([Parts, binary:part(Medium, End, byte_size(Medium) - End)]).
