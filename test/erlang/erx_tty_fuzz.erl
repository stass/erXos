%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_tty's set/2, size/3, input/3 and lost/1, the line
%% discipline's readers of untrusted values, and of erx_abi_termios's
%% decode/1, which reads a program's struct termios (docs/design-live.md,
%% "The tty" and "Verification and testing"): random termios and structs,
%% valid and broken one way at a time; random window sizes; and random
%% bytes in random chunks, up to past the input bound, losses of input
%% among them, and runs of VREPRINT
%% after a long line, under random termios, between random reads, waits and
%% writes. Whatever arrives, nothing crashes, a valid termios is kept as
%% given and a broken one refused, what waits stays within 4 KiB and one loss, every
%% action is one of erx_tty's, nothing is echoed without ECHO or ECHONL but
%% a bell, echo fits the room the owner gives, input fed back until none is
%% left with the room its echo left does what input a byte at a time does,
%% and in raw mode with no flag that changes or takes bytes, every byte is
%% read, still waits or was counted as dropped, beside at most one unit
%% for each loss, a lost/1 or a drop, and a flushed_loss follows its
%% flush_output. The seed comes from
%% make check-fuzz; a failure is error({fuzz_failure, Property, Detail}).

-module(erx_tty_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(ROUNDS, 3000).
-define(MAX_INPUT, ?ERX_TTY_MAX_INPUT).
%% The tables of the ABI file's termios table.
-define(IFLAGS, erx_abi_termios:flags(iflag)).
-define(OFLAGS, erx_abi_termios:flags(oflag)).
-define(CFLAGS, erx_abi_termios:flags(cflag)).
-define(LFLAGS, erx_abi_termios:flags(lflag)).
-define(CHARS, erx_abi_termios:chars()).
%% Flags that change or take received bytes, which the count of bytes leaves out.
-define(TAKERS, [icrnl, igncr, inlcr, istrip, ixon, parmrk, isig, icanon]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    lists:foreach(fun(_) ->
                          termios_round(),
                          struct_round(),
                          size_round(),
                          input_round()
                  end, lists:seq(1, ?ROUNDS)),
    io:format("fuzz: ~p rounds ok~n", [?ROUNDS]).

termios_round() ->
    Tty = erx_tty:new(),
    Valid = random_termios(),
    case erx_tty:set(Valid, Tty) of
        {ok, _, Set} ->
            Kept = erx_tty:termios(Set),
            check(Kept =:= normal(Valid), termios_not_kept, {Valid, Kept});
        {error, einval} ->
            fail(valid_refused, Valid)
    end,
    Broken = broken(Valid),
    check(erx_tty:set(Broken, Tty) =:= {error, einval}, invalid_accepted, Broken).

%% A C program's struct termios through erx_abi_termios, the program
%% protocol's codec: a valid one decodes to a termios set/2 keeps, which
%% encodes back to the struct less what the table does not name and decodes
%% to itself again; a broken one is refused.
struct_round() ->
    Struct = random_struct(),
    case erx_abi_termios:decode(Struct) of
        {ok, Termios} ->
            check(element(1, erx_tty:set(Termios, erx_tty:new())) =:= ok, decoded_refused, Struct),
            Encoded = erx_abi_termios:encode(Termios),
            check(within(Encoded, Struct), codec_added, {Struct, Encoded}),
            check(erx_abi_termios:decode(Encoded) =:= {ok, Termios}, codec_round_trip, Struct);
        {error, einval} ->
            fail(struct_refused, Struct)
    end,
    Broken = broken_struct(Struct),
    check(erx_abi_termios:decode(Broken) =:= {error, einval}, codec_invalid_accepted, Broken).

size_round() ->
    Tty = erx_tty:new(),
    Rows = pick([0, 1, 24, 65535, 65536, -1, 1.0, rows, rand:uniform(70000)]),
    Columns = pick([0, 1, 80, 65535, 65536, -5, "80", rand:uniform(70000)]),
    Valid = is_integer(Rows) andalso Rows >= 1 andalso Rows =< 65535 andalso
        is_integer(Columns) andalso Columns >= 1 andalso Columns =< 65535,
    case erx_tty:size(Rows, Columns, Tty) of
        {ok, Actions, Sized} when Valid ->
            Changed = {Rows, Columns} =/= {24, 80},
            check(Actions =:= [Action || Changed, Action <- [start_output, winch]] andalso
                      erx_tty:winsize(Sized) =:= {Rows, Columns}, size_not_kept, {Rows, Columns});
        {error, einval} when not Valid ->
            ok;
        Other ->
            fail(size_checked_wrong, {Rows, Columns, Other})
    end.

input_round() ->
    Termios = random_termios(),
    {ok, _, Tty} = erx_tty:set(Termios, erx_tty:new()),
    Counted = [] =:= [F || F <- ?TAKERS, has(F, Termios)],
    %% In half the rounds no byte reads as NUL, so every NUL read is a loss.
    put(nul_free, rand:uniform(2) =:= 1),
    steps(rand:uniform(12), Termios, Counted, Tty, {0, 0, 0}).

%% Read and In count the bytes read, NULs aside, and the bytes received,
%% and Lost the calls of lost/1, for the conservation check.
steps(0, _, _, _, _) ->
    ok;
steps(N, Termios, Counted, Tty, {Read, In, Lost}) ->
    case rand:uniform(5) of
        1 ->
            Bytes = nul_free(random_input(Termios)),
            Kept = pick([0, 0, 1, 4000, 4096, rand:uniform(4097) - 1]),
            Room = {min(4096 - Kept, pick([0, 1, 7, 256, 4096, rand:uniform(4097) - 1])), Kept,
                    pick([false, true])},
            {Actions, Rest, Left, Tty1} = erx_tty:input(Bytes, Room, Tty),
            Taken = byte_size(Bytes) - byte_size(Rest),
            check_input(Actions, Rest, {Room, Left}, {Termios, Tty, Tty1}, Bytes),
            check_chunked(Bytes, Room, Termios, Tty),
            check_conserved(Counted, {Read, In + Taken, Lost}, Tty1, {Termios, Bytes}),
            steps(N - 1, Termios, Counted, Tty1, {Read, In + Taken, Lost});
        2 ->
            {Got, Tty1} = erx_tty:read(r, rand:uniform(5000), Tty),
            Bin = case Got of
                      {ok, Bytes} -> Bytes;
                      _ -> <<>>
                  end,
            %% With no NUL typed, two NULs in a row are two losses with no
            %% byte between them, which are one.
            check(not get(nul_free) orelse binary:match(Bin, <<0, 0>>) =:= nomatch,
                  losses_not_one, Bin),
            Taken = byte_size(Bin) - length(binary:matches(Bin, <<0>>)),
            steps(N - 1, Termios, Counted, Tty1, {Read + Taken, In, Lost});
        3 ->
            {Actions, Tty1} = erx_tty:read_wait(pick([r, s]), rand:uniform(4096), Tty),
            check_actions(Actions),
            steps(N - 1, Termios, Counted, Tty1, {Read, In, Lost});
        4 ->
            Widest = erx_tty:widest_rendering(),
            Room = pick([rand:uniform(300) - 1, Widest - 1, Widest]),
            Bytes = random_bytes(),
            {Taken, Out, Tty1} = erx_tty:output(Bytes, Room, Tty),
            check(byte_size(Out) =< Room andalso Taken >= 0, output_over_room, {Room, Out}),
            %% The relay reports an out watch at this room: the write it lets go
            %% must take a byte.
            check(Taken > 0 orelse Room < Widest, output_none_with_room, {Room, Bytes}),
            steps(N - 1, Termios, Counted, Tty1, {Read, In, Lost});
        5 ->
            {Actions, Tty1} = erx_tty:lost(Tty),
            check_actions(Actions),
            check([A || A <- Actions, not lists:member(element(1, A), [ready, timer_start, timer_cancel])] =:= [],
                  loss_did_more_than_settle, Actions),
            check_conserved(Counted, {Read, In, Lost + 1}, Tty1, Termios),
            steps(N - 1, Termios, Counted, Tty1, {Read, In, Lost + 1})
    end.

check_conserved(false, _, _, _) ->
    ok;
check_conserved(true, {Read, In, Lost}, Tty, Detail) ->
    case get(nul_free) of
        true ->
            %% Every byte received was read, still waits or was dropped, the
            %% bytes held stay within the bound, and the rest of what waits are
            %% losses, at most one for each, and one more than the bytes.
            Dropped = erx_tty:dropped(Tty),
            Held = In - Read - Dropped,
            Losses = erx_tty:waiting(Tty) - Held,
            check(Held >= 0 andalso Held =< ?MAX_INPUT, input_over_bound, {Detail, Held}),
            check(Losses >= 0 andalso Losses =< Lost + Dropped andalso Losses =< Held + 1,
                  units_not_conserved, {Detail, Held, Losses});
        false ->
            ok
    end.

%% Input stops only after a signal key, and returns a tail of its bytes;
%% its echo fits its room.
check_input(Actions, Rest, {Room, Left}, {Termios, Before, After}, Bytes) ->
    check_actions(Actions),
    Echo = iolist_to_binary([E || {echo, E} <- Actions]),
    check_room(Actions, Room, Left, {Termios, Bytes}),
    Taken = byte_size(Bytes) - byte_size(Rest),
    check(Taken > 0 orelse Bytes =:= <<>>, input_took_nothing, Bytes),
    check(binary:part(Bytes, Taken, byte_size(Rest)) =:= Rest,
          rest_not_a_tail, {Bytes, Rest}),
    Signals = length([S || {signal, S} <- Actions]),
    check(Rest =:= <<>> orelse Signals =:= 1, stopped_without_signal,
          {Termios, Bytes}),
    %% Only the last byte taken made a signal.
    check(Signals =:= 0 orelse
              not signals(binary:part(Bytes, 0, Taken - 1), Room, Before),
          went_past_a_signal, {Termios, Bytes}),
    Raw = not has(icanon, Termios),
    %% The bytes, and at most one loss more than the bytes.
    check(not Raw orelse erx_tty:waiting(After) =< 2 * ?MAX_INPUT + 1, input_over_bound,
          {erx_tty:waiting(After), byte_size(Bytes)}),
    check(erx_tty:dropped(After) >= erx_tty:dropped(Before), dropped_went_back, Bytes),
    Quiet = not has(echo, Termios) andalso not has(echonl, Termios),
    check(not Quiet orelse Echo =:= binary:copy(<<7>>, byte_size(Echo)),
          echo_without_echo, {Termios, Bytes, Echo}).

%% The echo before a flush_output fits Room, the echo after it the whole
%% room the flush gives back, and the room returned is what the last of
%% them left, with output stopped as the stop_output and start_output
%% among the actions left it, each of which changes it.
%% The room is checked first, so a fault that breaks both fails one
%% property whatever the seed.
check_room(Actions, {Free, Kept, Stopped} = Room, Left, Detail) ->
    StoppedAfter = lists:foldl(fun(stop_output, false) -> true;
                                  (stop_output, true) -> fail(stop_while_stopped, Detail);
                                  (start_output, true) -> false;
                                  (start_output, false) -> fail(start_while_started, Detail);
                                  (_, S) -> S
                               end, Stopped, Actions),
    Segments = segments(Actions, Free, erx_tty:master_room() - Kept),
    {Last, LastRoom} = lists:last(Segments),
    check(Left =:= {LastRoom - echoed(Last), Kept, StoppedAfter}, room_left_wrong,
          {Detail, Room, Left}),
    [check(echoed(Echo) =< Within, echo_over_bound, {Detail, Room, Within, echoed(Echo)})
     || {Echo, Within} <- Segments],
    ok.

%% The actions between flushes, each with the room its echo may take: Room
%% before the first, and after each the whole room a flush gives back.
segments(Actions, Room, Flushed) ->
    case lists:splitwith(fun(A) -> A =/= flush_output end, Actions) of
        {Before, []} -> [{Before, Room}];
        {Before, [flush_output | After]} -> [{Before, Room} | segments(After, Flushed, Flushed)]
    end.

echoed(Actions) -> byte_size(iolist_to_binary([E || {echo, E} <- Actions])).

%% With no reader waiting, input fed back until none is left, each time
%% with the room its echo left, gives the state and the actions,
%% neighbouring echoes joined, of input a byte at a time. A waiting reader
%% is reported once per call, after its last key, so both are cancelled.
check_chunked(Bytes, Room, Termios, Tty0) ->
    {_, Tty1} = erx_tty:cancel(r, Tty0),
    {_, Tty} = erx_tty:cancel(s, Tty1),
    check(fed([Bytes], Room, Tty) =:= fed([<<B>> || <<B>> <= Bytes], Room, Tty),
          chunked_differs, {Termios, Room, Bytes}).

%% Whether Bytes, fed back until none is left, make a signal.
signals(Bytes, Room, Tty) ->
    {Actions, _} = fed([Bytes], Room, Tty),
    lists:keymember(signal, 1, Actions).

%% Each chunk as an owner feeds it with Room for the master: again on what
%% a signal key left untaken, with the room input/3 returned.
fed(Chunks, Room, Tty0) ->
    {Actions, _, Tty} = lists:foldl(fun fed_chunk/2, {[], Room, Tty0}, Chunks),
    {joined(Actions), Tty}.

fed_chunk(<<>>, Acc) ->
    Acc;
fed_chunk(Chunk, {Actions, Room, Tty}) ->
    {More, Rest, Left, Tty1} = erx_tty:input(Chunk, Room, Tty),
    check_room(More, Room, Left, Chunk),
    fed_chunk(Rest, {Actions ++ More, Left, Tty1}).

joined([{echo, A}, {echo, B} | Rest]) ->
    joined([{echo, <<A/binary, B/binary>>} | Rest]);
joined([Action | Rest]) -> [Action | joined(Rest)];
joined([]) -> [].

check_actions(Actions) ->
    lists:foreach(fun(Action) -> check(action(Action), unknown_action, Action) end, Actions),
    check(flushes_report(Actions), flushed_loss_alone, Actions).

flushes_report([flush_output, flushed_loss | Rest]) -> flushes_report(Rest);
flushes_report([flushed_loss | _]) -> false;
flushes_report([_ | Rest]) -> flushes_report(Rest);
flushes_report([]) -> true.

action({echo, Bytes}) -> is_binary(Bytes) andalso Bytes =/= <<>>;
action({signal, S}) -> lists:member(S, [sigint, sigquit, sigtstp]);
action({ready, _}) -> true;
action({timer_start, {_, N}, Ms}) -> is_integer(N) andalso Ms >= 100 andalso Ms =< 25500;
action({timer_cancel, {_, N}}) -> is_integer(N);
action(A) -> lists:member(A, [info, flush_output, flushed_loss, stop_output, start_output]).

%%% Termios, valid and broken

random_termios() ->
    #{iflag => subset(?IFLAGS), oflag => subset(?OFLAGS), cflag => subset(?CFLAGS),
      lflag => subset(?LFLAGS), csize => 4 + rand:uniform(4),
      cc => maps:from_list([{Name, random_char(Name)} || Name <- ?CHARS]),
      ispeed => pick([0, 9600, 115200, 16#ffffffff]), ospeed => pick([0, 9600, 38400])}.

random_char(Name) when Name =:= vmin; Name =:= vtime -> pick([0, 0, 1, 2, 5, 255]);
random_char(_) -> pick([255, 3, 4, 10, 13, 17, 19, 20, 21, 23, 127, rand:uniform(256) - 1]).

%% What set/2 keeps: sorted flags, and an input speed of 0 as the output speed.
normal(#{ispeed := In, ospeed := Out} = Termios) ->
    Sorted = maps:map(fun(_, V) when is_list(V) -> lists:usort(V); (_, V) -> V end, Termios),
    Sorted#{ispeed := case In of 0 -> Out; _ -> In end}.

%% A termios broken one way.
broken(Termios) ->
    #{cc := Chars} = Termios,
    Field = pick([iflag, oflag, cflag, lflag]),
    Flags = maps:get(Field, Termios),
    case rand:uniform(11) of
        1 -> Termios#{Field := [bogus | Flags]};
        2 -> Termios#{Field := [pick(foreign(Field)) | Flags]};
        3 -> Termios#{Field := Flags ++ improper};
        4 -> Termios#{cc := Chars#{pick(?CHARS) := pick([256, -1, x, 1.5])}};
        5 -> Termios#{cc := maps:remove(pick(?CHARS), Chars)};
        6 -> Termios#{cc := Chars#{vbogus => 1}};
        7 -> Termios#{csize := pick([4, 9, eight])};
        8 -> Termios#{pick([ispeed, ospeed]) := pick([-1, 16#100000000, 9600.0])};
        9 -> maps:remove(pick([iflag, cc, csize, ospeed]), Termios);
        10 -> Termios#{extra => []};
        11 -> pick([[], <<>>, {termios}, Chars])
    end.

foreign(iflag) -> ?OFLAGS ++ ?LFLAGS;
foreign(oflag) -> ?IFLAGS ++ ?CFLAGS;
foreign(cflag) -> ?LFLAGS ++ ?OFLAGS;
foreign(lflag) -> ?IFLAGS ++ ?CFLAGS.

%%% Struct termios, valid and broken

random_struct() ->
    Word = fun() -> pick([0, 16#ffffffff, rand:uniform(1 bsl 32) - 1]) end,
    #{iflag => Word(), oflag => Word(), cflag => Word(), lflag => Word(),
      cc => [rand:uniform(256) - 1 || _ <- lists:seq(1, 20)],
      ispeed => pick([0, 9600, 16#ffffffff]), ospeed => pick([0, 38400])}.

%% A struct broken one way.
broken_struct(#{cc := Cc} = Struct) ->
    case rand:uniform(8) of
        1 -> Struct#{pick([iflag, oflag, cflag, lflag, ispeed, ospeed]) := pick([-1, 1 bsl 32, 1.0, x])};
        2 -> Struct#{cc := pick([tl(Cc), [0 | Cc], []])};
        3 -> Struct#{cc := [pick([256, -1, x]) | tl(Cc)]};
        4 -> Struct#{cc := lists:droplast(Cc) ++ 0};
        5 -> maps:remove(pick([iflag, cc, ospeed]), Struct);
        6 -> Struct#{extra => 0};
        7 -> Struct#{cc := list_to_binary(Cc)};
        8 -> pick([[], <<>>, {termios}, Cc])
    end.

%% Every bit of each word of Encoded is set in Struct, and every byte of
%% c_cc is Struct's or _POSIX_VDISABLE.
within(Encoded, Struct) ->
    Words = [W || W <- [iflag, oflag, cflag, lflag, ispeed, ospeed],
                  maps:get(W, Encoded) band bnot maps:get(W, Struct) =/= 0],
    Bytes = [{E, S} || {E, S} <- lists:zip(maps:get(cc, Encoded), maps:get(cc, Struct)),
                       E =/= S, E =/= 16#ff],
    Words =:= [] andalso Bytes =:= [].

%%% Helpers

%% Random bytes, or a long line and a run of the termios's VREPRINT, whose
%% echo with ECHO, ICANON and IEXTEN passes one call's bound many times.
random_input(#{cc := #{vreprint := Reprint}}) ->
    case rand:uniform(8) of
        1 -> <<(binary:copy(<<$a>>, 1000))/binary,
               (binary:copy(<<Reprint>>, 40))/binary>>;
        _ -> random_bytes()
    end.

%% With nul_free, no byte that ISTRIP could make a NUL.
nul_free(Bytes) ->
    case get(nul_free) of
        true -> << <<(case B band 16#7f of 0 -> B + 1; _ -> B end)>> || <<B>> <= Bytes >>;
        _ -> Bytes
    end.

random_bytes() ->
    Size = pick([1, 2, 8, 64, 1000, 5000]),
    Specials = [3, 4, 10, 13, 17, 19, 20, 21, 23, 127, 255, $\t, $\s, $a, 16#c3, 16#a9],
    << <<(case rand:uniform(3) of
              1 -> rand:uniform(256) - 1;
              _ -> pick(Specials)
          end)>> || _ <- lists:seq(1, rand:uniform(Size)) >>.

subset(Table) -> [F || F <- Table, rand:uniform(2) =:= 1].

pick(List) -> lists:nth(rand:uniform(length(List)), List).

has(Flag, #{iflag := I, oflag := O, cflag := C, lflag := L}) ->
    lists:member(Flag, I ++ O ++ C ++ L).

check(true, _, _) -> ok;
check(false, Property, Detail) -> fail(Property, Detail).

fail(Property, Detail) -> error({fuzz_failure, Property, Detail}).
