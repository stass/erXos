%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pipe).
-moduledoc """
The pipe server's decisions (docs/design-pipes.md, "The pipe server"):
one pure function, step/2, from the records of a session's pipes and
one event to the new records and the actions erx_pipe_srv performs, in
order, with the pipe NIF, the port driver and the programs' handlers.

The records hold no capability and read no shared page (PI8). Each
object of a pipe has a name the step derives from its numbers, and the
server keeps its own capability to the object under that name:

* `{lock, Pipe}`, the pipe's lock page;
* `{ring, Pipe, Wend}` and `{rpage, Pipe, Wend}`, the ring and the
  reader page of write end `Wend`'s lane;
* `{bell, Pipe, End}`, the doorbell of end `End`.

Reports and descriptors name objects where the program protocol has a
capability value; the handler installs the copies copies/1 lists and
puts the values it installed in their place.

The events are the first tier's (the second tier's exec, deposits and
collector are not here):

* `{pipe, Holder, Flags}`: make a pipe whose two ends `Holder` holds;
* `{inherit, Holder, Pipe, End, Child}`: make an end of the same kind as
  `Holder`'s end `End` for `Child`, a program being created or a
  session process;
* `{closed, Holder, Pipe, End}`: `Holder` let go of its end `End`;
* `{gone, Holder}`: every end `Holder` held is gone;
* `{drained, Holder, Pipe, End, Writer}`: `Holder`'s read end `End`
  drained the lane of the gone write end `Writer` and let it go;
* `{install_failed, Holder, Pipe, End}`: an install `Holder`'s end
  `End` needed failed.

A request is answered by one `{reply, Reply}` action; a notice from a
holder of no such end, or one that is not due, changes nothing and
returns no action, since a holder can only act on its own ends. The
actions:

* `{make_lock, Lock}`, `{make_lane, Ring, RPage, Size}` and
  `{make_bell, Bell, Holder, Label}`: create objects with the session's
  budget, binding a doorbell to its holder's group with `Label`, or
  with the label the session's event table registers for a process
  (`registered`). The makes of a step come before its other actions,
  so a make that fails leaves nothing to undo but the objects made: the
  server closes them, keeps the old records and answers `enomem`. The
  next step then makes objects of the same names, which is sound since
  nothing outside the server named them.
* `{store_wends, Lock, Wends}`: store the pipe's highest write end
  number in its lock page, with release order, before any install of
  that write end.
* `{free_lock, Lock, Rix}`: free the reader lock if read end `Rix` held
  it, by one compare-and-swap of `owner` from 1 + `Rix` to 0.
* `{report, Holder, Report}`: install what copies/1 lists for `Report`
  into `Holder`, then send it. An install that fails closes the copy it
  made and comes back as `install_failed`.
* `{reply, Reply}`: answer the event's request. The handler installs a
  reply's descriptors into the holder or the child; an install that
  fails there undoes the ends with `closed`, or with `gone` for a child
  whose creation failed, as for any end.
* `{close, Object}`: close the server's own capability to `Object`.
""".

-include("generated/erx_abi.hrl").

-export([new/1, step/2, view/1, copies/1, label/2, label_end/1]).

-export_type([state/0, event/0, action/0, holder/0, object/0,
              descriptor/0, report/0]).

%% Pipe and end numbers are 32-bit and never wrap (docs/design-pipes.md,
%% "The pipe server's records").
-define(NUMBER_MAX, 16#ffffffff).

-record(writer, {end_id :: id(),
                 holder :: holder(),
                 size :: lane_size(),
                 %% gone: the read ends that have not yet drained its lane
                 state = open :: open | {gone, [rix()]}}).
-record(reader, {end_id :: id(), holder :: holder()}).
-record(pipe, {id :: id(),
               writers = #{} :: #{id() => #writer{}},
               readers = #{} :: #{rix() => #reader{}},
               %% Never reused: a write end's number is below its end's,
               %% so the check on next_end bounds both.
               next_wend = 1 :: pos_integer(),
               next_end = 1 :: pos_integer()}).
-record(state, {quota :: pos_integer(),
                number_max :: id(),
                readers_max :: 1..?ERX_PIPE_READERS_MAX,
                lanes = 0 :: non_neg_integer(),
                next_pipe = 1 :: pos_integer(),
                pipes = #{} :: #{id() => #pipe{}}}).

-opaque state() :: #state{}.
%% A pipe's, an end's or a write end's number: 32-bit, from 1.
-type id() :: 1..?NUMBER_MAX.
-type rix() :: 0..(?ERX_PIPE_READERS_MAX - 1).
-type lane_size() :: ?ERX_PIPE_RING_FIRST | ?ERX_PIPE_RING_NEXT.
-type holder() :: {program, pos_integer()} | {process, pid()}.
-type object() :: {lock, id()} | {ring, id(), id()}
                | {rpage, id(), id()} | {bell, id(), id()}.
-type event() :: {pipe, holder(), [cloexec | nonblock]}
               | {inherit, holder(), term(), term(), holder()}
               | {closed, holder(), term(), term()}
               | {gone, holder()}
               | {drained, holder(), term(), term(), term()}
               | {install_failed, holder(), term(), term()}.
-type descriptor() :: {pipe, write, {id(), id()},
                       #{wend := id(), ring := object(),
                         rpage := object(), size := lane_size(),
                         readers := [{rix(), object()}]}}
                    | {pipe, read, {id(), id()},
                       #{rix := rix(), lock := object(), wends := id(),
                         writers := [{id(), object(), object(),
                                      lane_size(), {open, object()} | gone}],
                         readers := [{rix(), object()}]}}.
-type report() :: {pipe_writer, id(), id(), id(), object(),
                   object(), lane_size(), object(), open}
                | {pipe_writer_gone, id(), id(), id()}
                | {pipe_reader, id(), id(), rix(), object(), open}
                | {pipe_reader_gone, id(), id(), rix()}
                | {pipe_lost, id(), id()}.
-type action() :: {make_lock, object()}
                | {make_lane, object(), object(), lane_size()}
                | {make_bell, object(), holder(), pos_integer() | registered}
                | {store_wends, object(), id()}
                | {free_lock, object(), rix()}
                | {report, holder(), report()}
                | {reply, {ok, descriptor(), descriptor()}
                        | {ok, descriptor()}
                        | {error, enfile | emfile | ebadf}}
                | {close, object()}.

-define(IS_HOLDER(H), ((is_tuple(H) andalso tuple_size(H) =:= 2)
                       andalso ((element(1, H) =:= program
                                 andalso is_integer(element(2, H))
                                 andalso element(2, H) > 0)
                                orelse (element(1, H) =:= process
                                        andalso is_pid(element(2, H)))))).

-doc """
The records of a session with no pipe. `quota` is the session's `pipes`
quota, the lanes its pipes may hold at once: `?ERX_PIPES_QUOTA`, 1,024, unless
given, and never more, since the program port sizes each program's credit
for it (abi/erx_abi.txt, pipes_quota). An
exploration scales the design's other limits down: `number_max`, the
largest pipe or end number given (2^32 - 1), and `readers_max`, the read
ends a pipe may have (64).
""".
-spec new(#{quota => 1..?ERX_PIPES_QUOTA, number_max => 2..?NUMBER_MAX,
            readers_max => 1..?ERX_PIPE_READERS_MAX}) -> state().
new(Opts) when is_map(Opts) ->
    case maps:keys(maps:without([quota, number_max, readers_max], Opts)) of
        [] -> ok;
        _ -> erlang:error(badarg)
    end,
    Quota = maps:get(quota, Opts, ?ERX_PIPES_QUOTA),
    Max = maps:get(number_max, Opts, ?NUMBER_MAX),
    Readers = maps:get(readers_max, Opts, ?ERX_PIPE_READERS_MAX),
    case is_integer(Quota) andalso Quota >= 1 andalso Quota =< ?ERX_PIPES_QUOTA
        andalso is_integer(Max) andalso Max >= 2 andalso Max =< ?NUMBER_MAX
        andalso is_integer(Readers) andalso Readers >= 1
        andalso Readers =< ?ERX_PIPE_READERS_MAX of
        true -> #state{quota = Quota, number_max = Max, readers_max = Readers};
        false -> erlang:error(badarg)
    end.

-doc """
The new records and the actions that carry out one event, in the order
the server performs them.
""".
-spec step(state(), event()) -> {state(), [action()]}.
step(S, {pipe, Holder, Flags}) when ?IS_HOLDER(Holder), is_list(Flags) ->
    make_pipe(S, Holder);
step(S, {inherit, Holder, PipeId, End, Child})
  when ?IS_HOLDER(Holder), ?IS_HOLDER(Child) ->
    case find_end(S, Holder, PipeId, End) of
        {write, Pipe, _Wend} -> inherit_write(S, Pipe, Child);
        {read, Pipe, _Rix} -> inherit_read(S, Pipe, Child);
        none -> {S, [{reply, {error, ebadf}}]}
    end;
step(S, {closed, Holder, PipeId, End}) when ?IS_HOLDER(Holder) ->
    case find_end(S, Holder, PipeId, End) of
        none -> {S, []};
        Found -> end_gone(S, Found)
    end;
step(S, {gone, Holder}) when ?IS_HOLDER(Holder) ->
    {S1, Actions} = lists:foldl(fun({PipeId, End}, {Acc, Done}) ->
                                        Found = find_end(Acc, Holder, PipeId, End),
                                        {Next, More} = end_gone(Acc, Found),
                                        {Next, Done ++ More}
                                end, {S, []}, held_by(S, Holder)),
    %% The holder is gone: nothing reaches it.
    {S1, [A || A <- Actions, not is_report_to(Holder, A)]};
step(S, {drained, Holder, PipeId, End, Wend}) when ?IS_HOLDER(Holder) ->
    case find_end(S, Holder, PipeId, End) of
        {read, Pipe, Rix} -> drained(S, Pipe, Rix, Wend);
        _ -> {S, []}
    end;
step(S, {install_failed, Holder, PipeId, End}) when ?IS_HOLDER(Holder) ->
    case find_end(S, Holder, PipeId, End) of
        none -> {S, []};
        _ -> {S, [{report, Holder, {pipe_lost, PipeId, End}}]}
    end.

-doc """
The records as plain terms, for the inspector and the tests: the lanes
held against the quota, the next pipe number and, by pipe, the highest
write end number made (`wends`), the next end number, its write ends by
number and its read ends by index.
""".
-spec view(state()) -> #{lanes := non_neg_integer(), next_pipe := pos_integer(),
                         pipes := #{id() => map()}}.
view(#state{lanes = Lanes, next_pipe = Next, pipes = Pipes}) ->
    #{lanes => Lanes, next_pipe => Next,
      pipes => maps:map(fun(_, #pipe{writers = Ws, readers = Rs} = P) ->
                                #{wends => P#pipe.next_wend - 1,
                                  next_end => P#pipe.next_end,
                                  writers => maps:map(fun(_, W) -> writer_view(W) end, Ws),
                                  readers => maps:map(fun(_, R) -> reader_view(R) end, Rs)}
                        end, Pipes)}.

-doc """
The copies a descriptor or a report needs installed into its holder,
each an object with the handle rights of its copy
(docs/design-pipes.md, "Making a pipe"): a write end writes its own ring
and reads its reader page; a read end reads every ring and writes their
reader pages and the lock page; a doorbell is only rung. No copy carries
more, and none carries `DUP` or `GIVE`.
""".
-spec copies(descriptor() | report()) -> [{object(), pos_integer()}].
copies({pipe, write, _, #{ring := Ring, rpage := RPage, readers := Readers}}) ->
    [{Ring, ?ERX_HR_READ bor ?ERX_HR_WRITE}, {RPage, ?ERX_HR_READ}
     | [{Bell, ?ERX_HR_TRIGGER} || {_, Bell} <- Readers]];
copies({pipe, read, _, #{lock := Lock, writers := Writers, readers := Readers}}) ->
    [{Lock, ?ERX_HR_READ bor ?ERX_HR_WRITE}
     | lists:append([lane_copies(Ring, RPage) ++ bell_copies(State)
                     || {_, Ring, RPage, _, State} <- Writers])
     ++ [{Bell, ?ERX_HR_TRIGGER} || {_, Bell} <- Readers]];
copies({pipe_writer, _, _, _, Ring, RPage, _, Bell, _}) ->
    lane_copies(Ring, RPage) ++ [{Bell, ?ERX_HR_TRIGGER}];
copies({pipe_reader, _, _, _, Bell, _}) ->
    [{Bell, ?ERX_HR_TRIGGER}];
copies({Gone, _, _, _}) when Gone =:= pipe_writer_gone; Gone =:= pipe_reader_gone ->
    [];
copies({pipe_lost, _, _}) ->
    [].

-doc """
The label of end `End`'s doorbell in a program's group, `(Pipe <<
ERX_PIPE_LABEL_SHIFT) | End`, a u64 of at least 2^32 since `Pipe` is at
least 1, so it never equals the channel's label
(docs/design-pipes.md, "Waiting and doorbells").
""".
-spec label(id(), id()) -> pos_integer().
label(Pipe, End) when is_integer(Pipe), Pipe >= 1, Pipe =< ?NUMBER_MAX,
                      is_integer(End), End >= 1, End =< ?NUMBER_MAX ->
    (Pipe bsl ?ERX_PIPE_LABEL_SHIFT) bor End.

-doc "The pipe and end a label of label/2 names.".
-spec label_end(pos_integer()) -> {id(), id()}.
label_end(Label) when is_integer(Label), Label >= 1 bsl ?ERX_PIPE_LABEL_SHIFT,
                      Label =< 16#ffffffffffffffff,
                      Label band ((1 bsl ?ERX_PIPE_LABEL_SHIFT) - 1) >= 1 ->
    {Label bsr ?ERX_PIPE_LABEL_SHIFT,
     Label band ((1 bsl ?ERX_PIPE_LABEL_SHIFT) - 1)}.

%% ---------------------------------------------------------------------
%% Making ends

%% A pipe of read end 1, at index 0, and write end 2, with lane 1 of the
%% first ring size.
make_pipe(#state{lanes = Lanes, quota = Quota, next_pipe = Id,
                 number_max = Max} = S, _Holder)
  when Lanes >= Quota; Id > Max ->
    {S, [{reply, {error, enfile}}]};
make_pipe(#state{next_pipe = Id, pipes = Pipes} = S, Holder) ->
    Pipe = #pipe{id = Id,
                 writers = #{1 => #writer{end_id = 2, holder = Holder,
                                          size = ?ERX_PIPE_RING_FIRST}},
                 readers = #{0 => #reader{end_id = 1, holder = Holder}},
                 next_wend = 2, next_end = 3},
    Actions = [{make_lock, {lock, Id}},
               {make_lane, {ring, Id, 1}, {rpage, Id, 1}, ?ERX_PIPE_RING_FIRST},
               make_bell(Id, 1, Holder),
               make_bell(Id, 2, Holder),
               {store_wends, {lock, Id}, 1},
               {reply, {ok, read_descriptor(Pipe, 0), write_descriptor(Pipe, 1)}}],
    {S#state{lanes = S#state.lanes + 1, next_pipe = Id + 1,
             pipes = Pipes#{Id => Pipe}}, Actions}.

%% A write end for a child: the pipe's next number, a lane of the second
%% ring size, its number in wends before any install, and a report to
%% every read end.
inherit_write(#state{lanes = Lanes, quota = Quota, number_max = Max} = S,
              #pipe{next_end = End}, _Child)
  when Lanes >= Quota; End > Max ->
    {S, [{reply, {error, enfile}}]};
inherit_write(S, #pipe{id = Id, next_wend = Wend, next_end = End} = Pipe0, Child) ->
    Writer = #writer{end_id = End, holder = Child, size = ?ERX_PIPE_RING_NEXT},
    Pipe = Pipe0#pipe{writers = (Pipe0#pipe.writers)#{Wend => Writer},
                      next_wend = Wend + 1, next_end = End + 1},
    {Ring, RPage} = lane(Id, Wend),
    Bell = {bell, Id, End},
    Reports = [{report, H, {pipe_writer, Id, E, Wend, Ring, RPage, ?ERX_PIPE_RING_NEXT, Bell, open}}
               || {_, #reader{end_id = E, holder = H}} <- readers(Pipe0)],
    Actions = [{make_lane, Ring, RPage, ?ERX_PIPE_RING_NEXT},
               make_bell(Id, End, Child),
               {store_wends, {lock, Id}, Wend}
               | Reports] ++ [{reply, {ok, write_descriptor(Pipe, Wend)}}],
    {put_pipe(S#state{lanes = S#state.lanes + 1}, Pipe), Actions}.

%% A read end for a child: the lowest free index, a report to every open
%% write end and every other read end, and the drain of every gone write
%% end's lane, which the new end shares.
inherit_read(#state{number_max = Max, readers_max = ReadersMax} = S,
             #pipe{id = Id, next_end = End, readers = Readers} = Pipe0, Child) ->
    case free_rix(Readers, ReadersMax) of
        none ->
            {S, [{reply, {error, emfile}}]};
        _ when End > Max ->
            {S, [{reply, {error, enfile}}]};
        Rix ->
            Bell = {bell, Id, End},
            ToWriters = [{report, H, {pipe_reader, Id, E, Rix, Bell, open}}
                         || {_, #writer{end_id = E, holder = H, state = open}}
                                <- writers(Pipe0)],
            ToReaders = [{report, H, {pipe_reader, Id, E, Rix, Bell, open}}
                         || {_, #reader{end_id = E, holder = H}} <- readers(Pipe0)],
            Writers = maps:map(fun(_, #writer{state = {gone, Left}} = W) ->
                                       W#writer{state = {gone, lists:sort([Rix | Left])}};
                                  (_, W) ->
                                       W
                               end, Pipe0#pipe.writers),
            Pipe = Pipe0#pipe{writers = Writers,
                              readers = Readers#{Rix => #reader{end_id = End, holder = Child}},
                              next_end = End + 1},
            Actions = [make_bell(Id, End, Child) | ToWriters ++ ToReaders]
                ++ [{reply, {ok, read_descriptor(Pipe, Rix)}}],
            {put_pipe(S, Pipe), Actions}
    end.

free_rix(Readers, ReadersMax) ->
    case [R || R <- lists:seq(0, ReadersMax - 1), not is_map_key(R, Readers)] of
        [Rix | _] -> Rix;
        [] -> none
    end.

make_bell(Id, End, {program, _} = Holder) ->
    {make_bell, {bell, Id, End}, Holder, label(Id, End)};
make_bell(Id, End, {process, _} = Holder) ->
    {make_bell, {bell, Id, End}, Holder, registered}.

write_descriptor(#pipe{id = Id} = Pipe, Wend) ->
    #writer{end_id = End, size = Size} = maps:get(Wend, Pipe#pipe.writers),
    {Ring, RPage} = lane(Id, Wend),
    {pipe, write, {Id, End},
     #{wend => Wend, ring => Ring, rpage => RPage, size => Size,
       readers => [{R, {bell, Id, E}} || {R, #reader{end_id = E}} <- readers(Pipe)]}}.

%% A gone write end's lane is listed gone and without a doorbell: the
%% server keeps its own capability to that doorbell until it forgets the
%% write end, but hands out no copy of it.
read_descriptor(#pipe{id = Id, next_wend = Next} = Pipe, Rix) ->
    #reader{end_id = End} = maps:get(Rix, Pipe#pipe.readers),
    Writers = [begin
                   {Ring, RPage} = lane(Id, Wend),
                   {Wend, Ring, RPage, Size, writer_state(State, {bell, Id, E})}
               end || {Wend, #writer{end_id = E, size = Size, state = State}}
                          <- writers(Pipe)],
    {pipe, read, {Id, End},
     #{rix => Rix, lock => {lock, Id}, wends => Next - 1, writers => Writers,
       readers => [{R, {bell, Id, E}}
                   || {R, #reader{end_id = E}} <- readers(Pipe), R =/= Rix]}}.

writer_state(open, Bell) -> {open, Bell};
writer_state({gone, _}, _) -> gone.

%% ---------------------------------------------------------------------
%% Ends going

%% docs/design-pipes.md, "Ends and their holders". A write end goes gone,
%% kept until every read end drains its lane, or is forgotten at once
%% with no read end; every read end is told. The server keeps its
%% capability to the write end's doorbell until it forgets the write end,
%% since an install still in progress may name it; no later descriptor
%% or report does. A read end frees the lock if it held it, closes its
%% doorbell and frees its index; every other end is told, and no gone
%% write end waits for it any more.
end_gone(S, {write, #pipe{id = Id} = Pipe0, Wend}) ->
    Readers = readers(Pipe0),
    Reports = [{report, H, {pipe_writer_gone, Id, E, Wend}}
               || {_, #reader{end_id = E, holder = H}} <- Readers],
    {S1, Pipe, Closes} = case Readers of
                             [] -> forget_writer(S, Pipe0, Wend);
                             _ -> {S, mark_gone(Pipe0, Wend), []}
                         end,
    forget_if_empty(S1, Pipe, Closes ++ Reports);
end_gone(S, {read, #pipe{id = Id} = Pipe0, Rix}) ->
    #reader{end_id = End} = maps:get(Rix, Pipe0#pipe.readers),
    Pipe1 = Pipe0#pipe{readers = maps:remove(Rix, Pipe0#pipe.readers)},
    ToWriters = [{report, H, {pipe_reader_gone, Id, E, Rix}}
                 || {_, #writer{end_id = E, holder = H, state = open}} <- writers(Pipe1)],
    ToReaders = [{report, H, {pipe_reader_gone, Id, E, Rix}}
                 || {_, #reader{end_id = E, holder = H}} <- readers(Pipe1)],
    {S1, Pipe, Forgotten} =
        lists:foldl(fun({Wend, #writer{state = {gone, _}}}, {AccS, AccPipe, Closes}) ->
                            {NextS, NextPipe, More} = drop_rix(AccS, AccPipe, Wend, Rix),
                            {NextS, NextPipe, Closes ++ More};
                       (_, Acc) ->
                            Acc
                    end, {S, Pipe1, []}, writers(Pipe1)),
    forget_if_empty(S1, Pipe, [{free_lock, {lock, Id}, Rix}, {close, {bell, Id, End}}
                               | ToWriters ++ ToReaders ++ Forgotten]).

%% A drained notice is due only from a read end whose index the gone
%% write end still waits for; any other changes nothing.
drained(S, #pipe{writers = Writers} = Pipe0, Rix, Wend) ->
    case maps:find(Wend, Writers) of
        {ok, #writer{state = {gone, Left}}} ->
            case lists:member(Rix, Left) of
                true ->
                    {S1, Pipe, Closes} = drop_rix(S, Pipe0, Wend, Rix),
                    {put_pipe(S1, Pipe), Closes};
                false ->
                    {S, []}
            end;
        _ ->
            {S, []}
    end.

%% Read end Rix no longer holds gone write end Wend's lane; the last one
%% to let it go lets the server forget it.
drop_rix(S, Pipe, Wend, Rix) ->
    #writer{state = {gone, Left}} = W = maps:get(Wend, Pipe#pipe.writers),
    case lists:delete(Rix, Left) of
        [] ->
            forget_writer(S, Pipe, Wend);
        Rest ->
            {S, Pipe#pipe{writers = (Pipe#pipe.writers)#{Wend => W#writer{state = {gone, Rest}}}},
             []}
    end.

mark_gone(Pipe, Wend) ->
    W = maps:get(Wend, Pipe#pipe.writers),
    Rixes = lists:sort(maps:keys(Pipe#pipe.readers)),
    Pipe#pipe{writers = (Pipe#pipe.writers)#{Wend => W#writer{state = {gone, Rixes}}}}.

%% The server's last capabilities to the write end's objects close here:
%% its lane and its doorbell. No install still in progress names the
%% doorbell by then: one that does goes to a read end whose index is still
%% in the gone write end's list, or to a holder that is itself gone, and
%% the handler installs a holder's reports in order, before that holder
%% can report the lane drained.
forget_writer(S, #pipe{id = Id} = Pipe, Wend) ->
    #writer{end_id = End} = maps:get(Wend, Pipe#pipe.writers),
    {Ring, RPage} = lane(Id, Wend),
    {S#state{lanes = S#state.lanes - 1},
     Pipe#pipe{writers = maps:remove(Wend, Pipe#pipe.writers)},
     [{close, Ring}, {close, RPage}, {close, {bell, Id, End}}]}.

%% docs/design-pipes.md, "The pipe server": the last end of a pipe gone.
%% A gone write end waits only for read ends, so with none left none
%% remains either.
forget_if_empty(S, #pipe{id = Id, writers = W, readers = R}, Actions)
  when map_size(W) =:= 0, map_size(R) =:= 0 ->
    {S#state{pipes = maps:remove(Id, S#state.pipes)}, Actions ++ [{close, {lock, Id}}]};
forget_if_empty(S, Pipe, Actions) ->
    {put_pipe(S, Pipe), Actions}.

%% ---------------------------------------------------------------------
%% Records

%% The end End of pipe PipeId, if Holder holds it: an open write end by
%% its number, or a read end by its index. A gone write end has no
%% holder.
find_end(#state{pipes = Pipes}, Holder, PipeId, End) ->
    case maps:find(PipeId, Pipes) of
        {ok, Pipe} ->
            Writers = [{write, Pipe, Wend}
                       || {Wend, #writer{end_id = E, holder = H, state = open}}
                              <- writers(Pipe), E =:= End, H =:= Holder],
            Readers = [{read, Pipe, Rix}
                       || {Rix, #reader{end_id = E, holder = H}}
                              <- readers(Pipe), E =:= End, H =:= Holder],
            case Writers ++ Readers of
                [Found] -> Found;
                [] -> none
            end;
        error ->
            none
    end.

%% Every end Holder holds, by pipe and end number.
held_by(#state{pipes = Pipes}, Holder) ->
    lists:sort([{Id, E} || {Id, Pipe} <- maps:to_list(Pipes),
                           {_, #writer{end_id = E, holder = H, state = open}}
                               <- writers(Pipe), H =:= Holder]
               ++ [{Id, E} || {Id, Pipe} <- maps:to_list(Pipes),
                              {_, #reader{end_id = E, holder = H}} <- readers(Pipe),
                              H =:= Holder]).

is_report_to(Holder, {report, Holder, _}) -> true;
is_report_to(_, _) -> false.

lane(Id, Wend) ->
    {{ring, Id, Wend}, {rpage, Id, Wend}}.

%% Ascending by number and by index, so every holder hears of ends in
%% one order and descriptors list them as the protocol's lists require.
writers(#pipe{writers = Writers}) -> lists:sort(maps:to_list(Writers)).
readers(#pipe{readers = Readers}) -> lists:sort(maps:to_list(Readers)).

put_pipe(#state{pipes = Pipes} = S, #pipe{id = Id} = Pipe) ->
    S#state{pipes = Pipes#{Id => Pipe}}.

lane_copies(Ring, RPage) ->
    [{Ring, ?ERX_HR_READ}, {RPage, ?ERX_HR_READ bor ?ERX_HR_WRITE}].

bell_copies({open, Bell}) -> [{Bell, ?ERX_HR_TRIGGER}];
bell_copies(gone) -> [].

writer_view(#writer{end_id = E, holder = H, size = Size, state = State}) ->
    #{end_id => E, holder => H, size => Size, state => State}.

reader_view(#reader{end_id = E, holder = H}) ->
    #{end_id => E, holder => H}.
