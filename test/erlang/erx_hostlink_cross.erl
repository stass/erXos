%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The target's half of test/host/hostlink_frame_test.rb's cross test: the Ruby frame layer
%% framed what is in In, and this deframes it with erx_hostlink_frame and erx_hostlink_stream
%% in random pieces and answers in Out, which the Ruby layer then deframes. A cast of
%% session 0 names the session, as a hello would: its payload is the 16-byte identifier.
%% Each call of that session is answered by a reply of the same id and payload, each cast
%% by a cast, each terminal or files frame by one of the same body, and the bytes consumed
%% after the session is named are granted back as credit, with a flush at the end. Prints the discard counts.

-module(erx_hostlink_cross).
-export([run/1]).

-record(state, {receiver, deframer, sender = none, grant, out = []}).

run([In, Out, Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    {ok, Bytes} = file:read_file(In),
    Fed = chunks(Bytes, #state{receiver = erx_hostlink_stream:receiver(16777216),
                                 deframer = erx_hostlink_frame:deframer(target),
                                 grant = erx_hostlink_stream:grant()}),
    {{grant, Granted}, _} = erx_hostlink_stream:flush(Fed#state.grant),
    State = send(frame, [credit, Granted, <<>>], Fed),
    ok = file:write_file(Out, lists:reverse(State#state.out)),
    io:format("cross: frame ~p stream ~p~n", [erx_hostlink_frame:counts(State#state.deframer),
                                               erx_hostlink_stream:counts(State#state.receiver)]).

chunks(<<>>, State) ->
    State;
chunks(Bytes, State) ->
    Size = min(rand:uniform(300), byte_size(Bytes)),
    <<Chunk:Size/binary, Rest/binary>> = Bytes,
    {Results, Deframer} = erx_hostlink_frame:feed(Chunk, State#state.deframer),
    Fed = lists:foldl(fun result/2, State#state{deframer = Deframer}, Results),
    chunks(Rest, credit(Size, Fed)).

credit(_Size, #state{sender = none} = State) ->
    State;
credit(Size, #state{grant = Grant} = State) ->
    case erx_hostlink_stream:consumed(Size, Grant) of
        {none, Next} -> State#state{grant = Next};
        {{grant, Bytes}, Next} -> send(frame, [credit, Bytes, <<>>], State#state{grant = Next})
    end.

result({error, _Reason}, State) ->
    State;
result({ok, Frame}, #state{receiver = Receiver} = State) ->
    {Taken, Next} = erx_hostlink_stream:accept(Frame, 16777216, Receiver),
    answer(Taken, State#state{receiver = Next}).

answer({hello, #{payload := Session}}, State) ->
    State#state{receiver = erx_hostlink_stream:set_session(Session, State#state.receiver),
                sender = erx_hostlink_stream:sender(Session)};
answer({message, #{kind := call, id := Id, target := Target, payload := Payload}}, State) ->
    send(message, [reply, Id, Target, Payload], State);
answer({message, #{kind := cast, target := Target, payload := Payload}}, State) ->
    send(message, [cast, 0, Target, Payload], State);
answer({frame, #{stream := Stream, body := Body}}, State) ->
    send(frame, [Stream, 0, Body], State);
answer(_Other, State) ->
    State.

send(Function, Arguments, #state{sender = Sender, out = Out} = State) ->
    case apply(erx_hostlink_stream, Function, Arguments ++ [Sender]) of
        {ok, Frames, Next} when is_list(Frames) -> State#state{sender = Next, out = lists:reverse(Frames) ++ Out};
        {ok, Frame, Next} -> State#state{sender = Next, out = [Frame | Out]}
    end.
