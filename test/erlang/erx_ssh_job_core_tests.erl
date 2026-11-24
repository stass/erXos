%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_ssh_job_core, the job relay's protocol (docs/design-ssh.md, "Sessions, ttys
%% and shells"), explored exhaustively: from a new job, every order of the
%% channel's messages, well-formed or not, of the input writer's answer, of each
%% reader's pieces and end and of the job's end, up to two inputs and two pieces a
%% stream. After every step the test checks what the relay may do and what it
%% must do: a well-formed input is written and a bad one hangs the job up,
%% job_hangup hangs it up, a write is answered with job_written, standard input
%% is closed once job_eof came and every write is done, and never sooner; one
%% write and one job_output unanswered at most, a reader reads again only once
%% its piece is answered, and exited goes once, as soon as every piece was sent
%% and answered after the job ended, and is the step's last action but stop.
-module(erx_ssh_job_core_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(INPUTS, 2).
-define(PIECES, 2).

%% The test's record of the relay: whether a write is unanswered, inputs sent,
%% whether job_eof was sent and standard input closed, which readers are reading,
%% each stream's pieces read, at its end, and read but not answered,
%% job_outputs unanswered and the stream of the last one sent, pieces sent,
%% whether the job has ended, and whether the relay is done. The *_due keys are
%% what the event obliges the relay to do in this step.
model() ->
    #{writing => false, inputs => 0, eof_sent => false, closed => false,
      reading => #{stdout => true, stderr => true},
      pieces => #{stdout => 0, stderr => 0},
      at_end => #{stdout => false, stderr => false},
      held => #{stdout => 0, stderr => 0},
      unanswered => 0, last => none, sent => 0, ended => false, exited => false,
      done => false,
      input_due => none, written_due => false, hangup_due => false}.

exhaustive_test() ->
    Seen = explore([{erx_ssh_job_core:new(), model()}], #{}, 0),
    ?assert(map_size(Seen) > 500).

explore([], Seen, Endings) ->
    %% The exploration reaches the ending along many orders.
    ?assert(Endings > 100),
    Seen;
explore([State | Rest], Seen, Endings) when is_map_key(State, Seen) ->
    explore(Rest, Seen, Endings);
explore([{Job, M} = State | Rest], Seen, Endings) ->
    Next = [begin
                {Job1, Actions} = erx_ssh_job_core:step(Event, Job),
                {Job1, check(Event, Actions, M)}
            end || Event <- events(M)],
    Ended = length([S || {_, #{done := true}} = S <- Next]),
    explore([S || {_, #{done := false}} = S <- Next] ++ Rest,
            Seen#{State => true}, Endings + Ended).

%% The events the relay can meet in M: any channel message, and the writer's,
%% readers' and job's events only where they can happen.
events(#{writing := Writing, inputs := Inputs, reading := Reading,
         pieces := Pieces, ended := Ended}) ->
    Big = binary:copy(<<0>>, ?ERX_TTY_LINE_DATA_MAX + 1),
    Channel = [{job_input, <<0, 255>>} || Inputs < ?INPUTS]
        ++ [{job_input, Big}, {job_input, nope}, job_eof, job_sent,
            job_hangup, {job_output, stdout, <<"x">>}],
    [{channel, Message} || Message <- Channel]
        ++ [written || Writing]
        ++ [{read, S, atom_to_binary(S)}
            || S <- [stdout, stderr], maps:get(S, Reading),
               maps:get(S, Pieces) < ?PIECES]
        ++ [{read, S, eof} || S <- [stdout, stderr], maps:get(S, Reading)]
        ++ [{ended, 3} || not Ended].

%% M after Event and the relay's Actions, every rule asserted.
check(Event, Actions, M0) ->
    M = lists:foldl(fun act/2, before(Event, M0), Actions),
    Context = {Event, Actions, M0},
    ?assertMatch(#{input_due := none, written_due := false, hangup_due := false},
                 M, Context),
    ?assert(maps:get(unanswered, M) =< 1, Context),
    case M of
        #{done := false, eof_sent := true, writing := false} ->
            ?assert(maps:get(closed, M), Context);
        #{} ->
            ok
    end,
    case ready(M) andalso not maps:get(done, M) of
        true -> ?assert(false, {no_exited, Context});
        false -> ok
    end,
    M.

%% The model once Event has happened, before the relay acts on it, with what
%% the event obliges the relay to do.
before({channel, {job_input, Bytes}}, #{writing := false, eof_sent := false,
                                        inputs := N} = M)
  when is_binary(Bytes), byte_size(Bytes) =< ?ERX_TTY_LINE_DATA_MAX ->
    M#{inputs := N + 1, input_due := Bytes};
before({channel, {job_input, _}}, M) ->
    M#{hangup_due := true};
before({channel, job_eof}, M) ->
    M#{eof_sent := true};
before({channel, job_sent}, #{unanswered := 1, last := S, held := H} = M) ->
    M#{unanswered := 0, held := H#{S := maps:get(S, H) - 1}};
before({channel, job_sent}, M) ->
    M;
before({channel, job_hangup}, M) ->
    M#{hangup_due := true};
before({channel, _}, M) ->
    M;
before(written, M) ->
    M#{writing := false, written_due := true};
before({read, S, eof}, #{reading := R, at_end := E} = M) ->
    M#{reading := R#{S := false}, at_end := E#{S := true}};
before({read, S, _}, #{reading := R, pieces := P, held := H} = M) ->
    M#{reading := R#{S := false}, pieces := P#{S := maps:get(S, P) + 1},
       held := H#{S := maps:get(S, H) + 1}};
before({ended, _}, M) ->
    M#{ended := true}.

act(_Action, #{done := true} = M) ->
    ?assert(false, {action_after_the_end, M});
act({write, Bytes}, #{writing := false, closed := false, input_due := Bytes} = M) ->
    M#{writing := true, input_due := none};
act(close_input, #{closed := false, writing := false, eof_sent := true} = M) ->
    M#{closed := true};
act({send, job_written}, #{written_due := true} = M) ->
    M#{written_due := false};
act({send, {job_output, S, Bytes}}, #{unanswered := 0, sent := N} = M) ->
    ?assertEqual(atom_to_binary(S), Bytes),
    M#{unanswered := 1, last := S, sent := N + 1};
act({read, S}, #{reading := R, at_end := E, held := H} = M) ->
    ?assertNot(maps:get(S, R)),
    ?assertNot(maps:get(S, E)),
    %% A reader reads again only once its last piece has been answered.
    ?assertEqual(0, maps:get(S, H)),
    M#{reading := R#{S := true}};
act({send, {exited, 3}}, #{exited := false} = M) ->
    ?assert(ready(M)),
    M#{exited := true};
act(stop, #{exited := true} = M) ->
    M#{done := true};
act(hangup, #{hangup_due := true} = M) ->
    M#{done := true, hangup_due := false};
act(Action, M) ->
    ?assert(false, {unexpected, Action, M}).

%% Whether exited is due: the job ended, both readers at their end, every piece
%% sent and answered.
ready(#{ended := Ended, at_end := #{stdout := true, stderr := true},
        pieces := #{stdout := A, stderr := B}, sent := Sent, unanswered := 0}) ->
    Ended andalso Sent =:= A + B;
ready(_M) ->
    false.

%% Once the relay is over, by hangup or its ending, nothing changes it.
nothing_after_the_end_test() ->
    {Over, [hangup]} = erx_ssh_job_core:step({channel, job_hangup},
                                             erx_ssh_job_core:new()),
    ?assertEqual([{Over, []}, {Over, []}, {Over, []}],
                 [erx_ssh_job_core:step(Event, Over)
                  || Event <- [{channel, {job_input, <<"x">>}}, {read, stdout, eof},
                               {ended, 0}]]).

%%% The channel's side, channel_step/2, explored the same way: from a new channel,
%%% every order of the client's data (up to three messages, one past a piece's
%%% size) and end of input, of the job's start, and of what the line sends,
%%% well-formed or not. After every step the test checks that the job gets
%%% exactly the client's data sent after the start and before its end of input,
%%% in order, in pieces of 1 to tty_line_data_max bytes, one unanswered at a time,
%%% each sent as soon as none is unanswered; that job_eof goes once, after the
%%% last piece is answered, and as soon as it is; that the window opens by a
%%% piece's size only once it is answered and by data that goes nowhere at once,
%%% so what the channel holds is never more than the client sent; that output is
%%% sent before job_sent answers it; and that an exited ends the channel and a
%%% message that fails its check closes it.

-define(DATA, 3).

channel_model() ->
    #{started => false, eof => false, eof_sent => false, data => 0,
      accepted => <<>>, sent => <<>>, unanswered => none, owed => 0,
      output_due => none, end_due => false, done => false}.

channel_exhaustive_test() ->
    Seen = channel_explore([{erx_ssh_job_core:new_channel(), channel_model()}], #{}),
    ?assert(map_size(Seen) > 200).

channel_explore([], Seen) ->
    Seen;
channel_explore([State | Rest], Seen) when is_map_key(State, Seen) ->
    channel_explore(Rest, Seen);
channel_explore([{Channel, M} = State | Rest], Seen) ->
    Next = [begin
                {Channel1, Actions} = erx_ssh_job_core:channel_step(Event, Channel),
                {Channel1, channel_check(Event, Actions, M)}
            end || Event <- channel_events(M)],
    channel_explore([S || {_, #{done := false}} = S <- Next] ++ Rest, Seen#{State => true}).

channel_events(#{started := Started, data := Data}) ->
    Big = binary:copy(<<7>>, ?ERX_TTY_LINE_DATA_MAX + 1),
    [{data, Bytes} || Data < ?DATA, Bytes <- [<<Data, 1>>, Big]]
        ++ [eof]
        ++ [started || not Started]
        ++ [{heard, Message}
            || Message <- [job_written, {job_output, stdout, <<"o">>},
                           {job_output, stdin, <<"o">>}, {exited, 3}, {exited, 256},
                           {signaled, sigint}]].

channel_check(Event, Actions, M0) ->
    M = lists:foldl(fun channel_act/2, channel_before(Event, M0), Actions),
    Context = {Event, Actions, M0},
    ?assertMatch(#{owed := 0, output_due := none}, M, Context),
    ?assert(maps:get(done, M) orelse not maps:get(end_due, M), {no_ending, Context}),
    case M of
        #{done := true} ->
            ok;
        #{started := true, unanswered := none, sent := Sent, accepted := Accepted}
          when Sent =/= Accepted ->
            ?assert(false, {piece_not_sent, Context});
        #{started := true, unanswered := none, eof := true, eof_sent := false} ->
            ?assert(false, {job_eof_not_sent, Context});
        #{} ->
            ok
    end,
    M.

%% The model once Event has happened, with what it obliges the channel to do:
%% owed is the window the channel must open in this step, output_due the output
%% it must send and then answer.
channel_before({data, Bytes}, #{started := true, eof := false, accepted := A, data := N} = M) ->
    M#{data := N + 1, accepted := <<A/binary, Bytes/binary>>};
channel_before({data, Bytes}, #{data := N, owed := Owed} = M) ->
    M#{data := N + 1, owed := Owed + byte_size(Bytes)};
channel_before(eof, M) ->
    M#{eof := true};
channel_before(started, M) ->
    M#{started := true};
channel_before({heard, job_written}, #{unanswered := Size, owed := Owed} = M) when Size =/= none ->
    M#{unanswered := none, owed := Owed + Size};
channel_before({heard, {job_output, stdout, Bytes}}, M) ->
    M#{output_due := Bytes};
channel_before({heard, _}, M) ->
    M#{end_due := true}.

channel_act(_Action, #{done := true} = M) ->
    ?assert(false, {action_after_the_end, M});
channel_act({send, {job_input, Piece}}, #{started := true, unanswered := none, sent := Sent,
                                          accepted := Accepted} = M)
  when byte_size(Piece) >= 1, byte_size(Piece) =< ?ERX_TTY_LINE_DATA_MAX ->
    Next = <<Sent/binary, Piece/binary>>,
    ?assertEqual(Next, binary:part(Accepted, 0, byte_size(Next))),
    M#{sent := Next, unanswered := byte_size(Piece)};
channel_act({send, job_eof}, #{started := true, eof := true, eof_sent := false,
                               unanswered := none, sent := Same, accepted := Same} = M) ->
    M#{eof_sent := true};
channel_act({adjust, N}, #{owed := Owed} = M) when N >= 1, N =< Owed ->
    M#{owed := Owed - N};
channel_act({output, stdout, Bytes}, #{output_due := Bytes} = M) ->
    M#{output_due := {answer, Bytes}};
channel_act({send, job_sent}, #{output_due := {answer, _}} = M) ->
    M#{output_due := none};
channel_act({ended, 3}, #{end_due := true} = M) ->
    M#{done := true};
channel_act(close, #{end_due := true} = M) ->
    M#{done := true};
channel_act(Action, M) ->
    ?assert(false, {unexpected, Action, M}).

%% The channel's checks of what the line sends for its job.
channel_heard_test() ->
    Big = binary:copy(<<1>>, ?ERX_TTY_LINE_DATA_MAX + 1),
    New = erx_ssh_job_core:new_channel(),
    {Started, []} = erx_ssh_job_core:channel_step(started, New),
    {Writing, [{send, {job_input, <<"x">>}}]} =
        erx_ssh_job_core:channel_step({data, <<"x">>}, Started),
    Heard = [{job_written, Writing}, {job_written, Started},
             {{job_output, stderr, <<0>>}, Started},
             {{job_output, stdin, <<0>>}, Started}, {{job_output, stdout, Big}, Started},
             {{exited, 255}, Started}, {{exited, 256}, Started},
             {{signaled, sigint}, Started}, {other, Writing}],
    ?assertEqual([[{adjust, 1}], [close], [{output, stderr, <<0>>}, {send, job_sent}],
                  [close], [close], [{ended, 255}], [close], [close], [close]],
                 [element(2, erx_ssh_job_core:channel_step({heard, Message}, Channel))
                  || {Message, Channel} <- Heard]).

%% The client's end of input before the job starts is kept, and goes as job_eof
%% once it has; its data before the start goes nowhere, the window opening by it.
channel_eof_before_the_start_test() ->
    {C1, [{adjust, 2}]} = erx_ssh_job_core:channel_step({data, <<"ab">>},
                                                        erx_ssh_job_core:new_channel()),
    {C2, []} = erx_ssh_job_core:channel_step(eof, C1),
    ?assertMatch({_, [{send, job_eof}]}, erx_ssh_job_core:channel_step(started, C2)).
