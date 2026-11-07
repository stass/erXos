%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hostlink_stream).
-moduledoc """
The host link's frames within a session (docs/design-live.md, "Host link
frames" and "The host link"), as pure state machines over the frames of
erx_hostlink_frame: which frames a receiver takes, the control messages it
reassembles from their pieces, the frames a sender numbers and cuts a
message into, and the credit the target grants as it consumes input. The
session protocol over them (hello, the call window, facets) is
erx_hostlink_session's; it holds one receiver, one sender and one grant.

**Receiving.** `accept/3` takes each frame `erx_hostlink_frame:feed/2`
returned and gives one result:

* `{frame, Frame}`: a frame of the current session on a stream other than
  control, as it arrived. A files body is one whole 9P2000.L message, a
  terminal or events body raw bytes, a credit frame's `target` the credit
  granted.
* `{message, Message}`: the last piece of a control message of the
  current session, which `message/0` describes; its payload is the
  external-term-format bytes, not yet checked or decoded.
* `{hello, Message}`: a control message of session 0, which carries a
  hello. It is taken whatever the current session, and in one frame only:
  a hello is small, so it touches neither the current session's sequence
  nor the message it is reassembling. It is not checked against `Room`: a
  hello replaces the session whose bytes `Room` leaves out, and it is held
  no longer than the step that takes it.
* `pending`: a piece of a control message, kept.
* `{refused, Head}`: the first piece of a control message whose `total`
  does not fit `Room`. Its bytes are not kept, its later pieces are
  `skipped`, and the session answers a refused call `{error, busy}`.
* `skipped`: a later piece of a refused or too large message.
* `{error, Reason}`: the frame is discarded and counted (`counts/1`):
  * `session`: a frame of another session than the current one, other
    than a control frame of session 0.
  * `seq`: a frame of the current session whose `seq` is below the one
    the receiver expects, a repeat of a frame already taken or passed. It
    changes nothing else, so a repeated piece leaves the message under way
    alone.
  * `control`: a control body without a well-formed 16-byte header: one
    shorter than the header, a kind other than call, reply or cast, an
    unknown flag, a nonzero reserved field, a call or reply with id 0, or
    a cast with another. In the current session it also ends the message
    under way; a hello's leaves that message alone.
  * `too_large`: a `total` over the receiver's message limit; the
    message's later pieces are `skipped`.
  * `pieces`: a piece that does not continue the message under way by its
    kind, id, target or total, or that is not the size its place in the
    message makes it: every piece but the last is 8,176 bytes, and the
    last is what remains of `total`. A hello in more than one frame is
    refused so too.

The pieces of one message are consecutive among the control frames of its
session; frames of other streams may come between them. Since every piece
but the last is full, a message has exactly as many pieces as its `total`
needs, and what the receiver keeps is the `total` it reserved. The
receiver expects each frame's `seq` to be one more than the last one's of
the current session, and takes any `seq` for the session's first frame. A
`seq` below the expected one is discarded (`seq` above). One above it is a
gap, counted as `gap`: the message being reassembled is dropped, and the
frame itself is then taken as usual, so a message whose first piece
follows the gap still arrives. A piece that
does not continue the message being reassembled ends that message
(counted as `pieces`) and is taken as the first piece of a new one.

`Room` is the bytes the session's resident limit has left besides the
receiver's own reservation, `held/1`: the `total` of the message being
reassembled, from its first piece on. A first piece always replaces that
reservation, so the receiver checks its `total` against `Room` alone.
`set_session/2` drops the message under way and starts the sequence anew.

**Sending.** A sender numbers the frames of one session and direction
from 0. `frame/4` makes one frame of a stream other than control;
`message/5` cuts a control message into pieces of 8,176 bytes and a last
one behind their 16-byte headers. Either fails with `{error, exhausted}`
when the frames would take `seq` past 2^32 - 1, and the session must end
before it wraps.

**Credit.** The host sends only within credit: 16 KiB at the start of a
session, plus what the target has granted since. A credit frame's `target`
is the total the target has granted in the session, modulo 2^32, so a
later grant makes up for a lost one. `consumed/2` takes the bytes the
target has read from the link, the zeros and any damaged bytes included,
and grants once 4 KiB are owed, so the host can always send a frame of the
largest size while less is owed. `flush/1` grants whatever is owed, and
repeats the last grant when nothing is: the session calls it when the
link's input goes idle, and may repeat it, so a host whose credit is short
of a frame is never left waiting.

Both ends count from the hello. erx_hostlink_session counts each read of
the link before it takes the frames the read holds, so a session's grant
counts the reads after the one that held its hello. The host counts every
byte it sends from its hello's first byte on, and sends nothing between
its hello and the reply but repeats of the hello. The target thus never
grants a byte the host has not sent, and grants less only by the hello and
what was read with it. Those bytes must stay well under the 8,083 by which
the initial credit exceeds the largest frame and its zero, so the host
repeats a hello only after waiting for its reply.
""".

-include("generated/erx_abi.hrl").

-export([receiver/1, set_session/2, session/1, accept/3, held/1, counts/1]).
-export([sender/1, sender/2, frame/4, message/5]).
-export([grant/0, consumed/2, flush/1]).

-export_type([receiver/0, sender/0, grant/0, result/0, message/0, head/0, kind/0, reason/0]).

-define(CONTROL, ?ERX_HOSTLINK_CONTROL_SIZE).
-define(PIECE_MAX, (?ERX_HOSTLINK_BODY_MAX - ?CONTROL)).
-define(U32_MAX, 16#FFFFFFFF).
-define(U64_MAX, 16#FFFFFFFFFFFFFFFF).
-define(SESSION_ZERO, <<0:128>>).
-define(GRANT_AT, (?ERX_HOSTLINK_CREDIT_INITIAL div 4)).

%% control_header/5 and decode_control/1 lay the control header out in the bit syntax.
-if(?ERX_HOSTLINK_CONTROL_OFF_KIND =/= 0 orelse ?ERX_HOSTLINK_CONTROL_OFF_FLAGS =/= 1
    orelse ?ERX_HOSTLINK_CONTROL_OFF_RESERVED =/= 2 orelse ?ERX_HOSTLINK_CONTROL_OFF_TOTAL =/= 4
    orelse ?ERX_HOSTLINK_CONTROL_OFF_ID =/= 8 orelse ?CONTROL =/= 16).
-error("erx_hostlink_stream's control header syntax disagrees with abi/protocols/hostlink.txt").
-endif.

%% With less than GRANT_AT owed, the host still has credit for the largest frame and its zero.
-if(?ERX_HOSTLINK_CREDIT_INITIAL - ?GRANT_AT < ?ERX_HOSTLINK_ENCODED_MAX + 1).
-error("the host link's grant threshold can leave the host without credit for a frame").
-endif.

-type session() :: erx_hostlink_frame:session().
-type kind() :: call | reply | cast.
-type message() :: #{kind := kind(), id := 0..?U64_MAX, target := 0..?U32_MAX,
                     session := session(), payload := binary()}.
-type head() :: #{kind := kind(), id := 0..?U64_MAX, target := 0..?U32_MAX,
                  session := session(), total := non_neg_integer()}.
-type reason() :: session | seq | control | too_large | pieces.
-type result() :: {frame, erx_hostlink_frame:frame()} | {message, message()} | {hello, message()}
                | pending
                | {refused, head()} | skipped | {error, reason()}.

%% The message being reassembled (keep) or skipped after a refusal (skip): its head, the
%% bytes of the pieces so far and, when kept, the pieces themselves, last first. Every piece
%% but the last is PIECE_MAX bytes, so a message is at most total div PIECE_MAX + 1 of them.
-record(partial, {mode :: keep | skip,
                  head :: head(),
                  got = 0 :: non_neg_integer(),
                  pieces = [] :: [binary()]}).

%% last is the session and seq of the last frame taken; partial is the message under way.
-record(receiver, {message_max :: non_neg_integer(),
                   current = none :: none | session(),
                   last = none :: none | {session(), non_neg_integer()},
                   partial = none :: none | #partial{},
                   counts = #{} :: #{reason() | gap => pos_integer()}}).
-opaque receiver() :: #receiver{}.

%% next is the seq of the sender's next frame, last_seq the highest it may use.
-record(sender, {session :: session(), next = 0 :: non_neg_integer(),
                 last_seq = ?U32_MAX :: 0..?U32_MAX}).
-opaque sender() :: #sender{}.

%% owed is what the target has consumed since its last grant, total what it has granted.
-record(grant, {owed = 0 :: non_neg_integer(), total = 0 :: non_neg_integer()}).
-opaque grant() :: #grant{}.

-doc """
A receiver with no current session, taking control messages of at most
`MessageMax` bytes: 16 MiB, or 8 KiB in a release build whose
configuration lists no facet for the host.
""".
-spec receiver(0..?ERX_HOSTLINK_MESSAGE_MAX) -> receiver().
receiver(MessageMax)
  when is_integer(MessageMax), MessageMax >= 0, MessageMax =< ?ERX_HOSTLINK_MESSAGE_MAX ->
    #receiver{message_max = MessageMax}.

-doc """
The receiver with `Session` current, or none once the session has ended,
with no message under way and its sequence started anew.
""".
-spec set_session(none | session(), receiver()) -> receiver().
set_session(none, #receiver{} = Receiver) ->
    Receiver#receiver{current = none, last = none, partial = none};
set_session(<<_:16/binary>> = Session, #receiver{} = Receiver) when Session =/= ?SESSION_ZERO ->
    Receiver#receiver{current = Session, last = none, partial = none}.

-doc "The current session, or none.".
-spec session(receiver()) -> none | session().
session(#receiver{current = Current}) -> Current.


-doc """
What one frame from erx_hostlink_frame:feed/2 gives, with `Room` bytes of
the resident limit left besides `held/1`.
""".
-spec accept(erx_hostlink_frame:frame(), non_neg_integer(), receiver()) -> {result(), receiver()}.
accept(#{stream := control, session := ?SESSION_ZERO} = Frame, Room, #receiver{} = Receiver)
  when is_integer(Room), Room >= 0 ->
    hello(Frame, Receiver);
accept(#{session := Session, seq := Seq}, Room, #receiver{last = {Session, Expected}} = Receiver)
  when is_integer(Room), Room >= 0, Seq < Expected ->
    discard(seq, Receiver);
accept(#{session := Session, seq := Seq} = Frame, Room, #receiver{current = Session} = Receiver)
  when is_integer(Room), Room >= 0 ->
    taken(Frame, Room, sequenced(Session, Seq, Receiver));
accept(#{}, Room, #receiver{} = Receiver) when is_integer(Room), Room >= 0 ->
    discard(session, Receiver).

-doc "The bytes reserved for the control message being reassembled.".
-spec held(receiver()) -> non_neg_integer().
held(#receiver{partial = #partial{mode = keep, head = #{total := Total}}}) -> Total;
held(#receiver{}) -> 0.

-doc """
How many frames the receiver has discarded, by reason, and under `gap`
how many times a frame's `seq` did not follow the last one's.
""".
-spec counts(receiver()) -> #{reason() | gap => pos_integer()}.
counts(#receiver{counts = Counts}) -> Counts.

-doc "A sender for `Session` (all zero for a hello) whose next frame is number 0.".
-spec sender(session()) -> sender().
sender(<<_:16/binary>> = Session) -> #sender{session = Session}.

-doc """
A sender for `Session` that numbers no frame past `LastSeq`, for tests that
reach the end of the sequence; the wire's own bound is 2^32 - 1.
""".
-spec sender(session(), 0..?U32_MAX) -> sender().
sender(<<_:16/binary>> = Session, LastSeq)
  when is_integer(LastSeq), LastSeq >= 0, LastSeq =< ?U32_MAX ->
    #sender{session = Session, last_seq = LastSeq}.

-doc """
The wire bytes of one frame of `Stream`, which is not control, and the
sender after it. `Target` is the bytes granted on the credit stream and 0
on the others.
""".
-spec frame(terminal | events | credit | files, 0..?U32_MAX, binary(), sender()) ->
          {ok, binary(), sender()} | {error, exhausted}.
frame(Stream, Target, Body, #sender{} = Sender) when Stream =/= control ->
    case numbered(1, Sender) of
        {ok, [Seq], Next} ->
            {ok, erx_hostlink_frame:encode(#{stream => Stream, session => Sender#sender.session,
                                             seq => Seq, target => Target, body => Body}),
             Next};
        {error, exhausted} ->
            {error, exhausted}
    end.

-doc """
The wire bytes of the frames of one control message, in order, and the
sender after them. `Id` is the call identifier, nonzero for a call or a
reply and 0 for a cast; `Target` the facet number. A payload over 16 MiB
is `{error, too_large}`.
""".
-spec message(kind(), 0..?U64_MAX, 0..?U32_MAX, binary(), sender()) ->
          {ok, [binary()], sender()} | {error, exhausted | too_large}.
message(Kind, Id, Target, Payload, #sender{} = Sender)
  when is_binary(Payload), is_integer(Id), Id >= 0, Id =< ?U64_MAX,
       is_integer(Target), Target >= 0, Target =< ?U32_MAX,
       (Kind =:= cast andalso Id =:= 0) orelse
       ((Kind =:= call orelse Kind =:= reply) andalso Id > 0) ->
    case byte_size(Payload) =< ?ERX_HOSTLINK_MESSAGE_MAX of
        true -> cut(Kind, Id, Target, Payload, Sender);
        false -> {error, too_large}
    end.

-doc "A grant with nothing owed, as at the start of a session.".
-spec grant() -> grant().
grant() -> #grant{}.

-doc """
After the target has consumed `Bytes` more bytes of the link, the credit
frame's `target` it sends now, if any, and the grant after it.
""".
-spec consumed(non_neg_integer(), grant()) -> {none | {grant, 0..?U32_MAX}, grant()}.
consumed(Bytes, #grant{owed = Owed} = Grant) when is_integer(Bytes), Bytes >= 0 ->
    case Owed + Bytes of
        Due when Due >= ?GRANT_AT -> flush(Grant#grant{owed = Due});
        Due -> {none, Grant#grant{owed = Due}}
    end.

-doc "The credit frame's `target` that grants all that is owed, and the grant after it.".
-spec flush(grant()) -> {{grant, 0..?U32_MAX}, grant()}.
flush(#grant{owed = Owed, total = Total}) ->
    Granted = (Total + Owed) band ?U32_MAX,
    {{grant, Granted}, #grant{total = Granted}}.

%% The receiver after a frame of the current session numbered Seq, at or above the one
%% expected: one above it ends the message under way. The first frame of a session follows
%% nothing.
sequenced(Session, Seq, #receiver{last = {Session, Seq}} = Receiver) ->
    Receiver#receiver{last = {Session, Seq + 1}};
sequenced(Session, Seq, #receiver{last = {Session, _Expected}} = Receiver) ->
    count(gap, Receiver#receiver{last = {Session, Seq + 1}, partial = none});
sequenced(Session, Seq, #receiver{last = none} = Receiver) ->
    Receiver#receiver{last = {Session, Seq + 1}}.

%% A control frame of session 0: a whole message in one frame, kept apart from the current
%% session's sequence and its message under way.
hello(#{body := Body, target := Target}, Receiver) ->
    case decode_control(Body) of
        {ok, _Kind, _More, Total, _Id, _Piece} when Total > Receiver#receiver.message_max ->
            discard(too_large, Receiver);
        {ok, Kind, false, Total, Id, Piece} when byte_size(Piece) =:= Total ->
            {{hello, #{kind => Kind, id => Id, target => Target, session => ?SESSION_ZERO,
                       payload => Piece}},
             Receiver};
        {ok, _Kind, _More, _Total, _Id, _Piece} ->
            discard(pieces, Receiver);
        error ->
            discard(control, Receiver)
    end.

taken(#{stream := control, session := Session, target := Target, body := Body}, Room, Receiver) ->
    case decode_control(Body) of
        {ok, Kind, More, Total, Id, Piece} ->
            Head = #{kind => Kind, id => Id, target => Target, session => Session, total => Total},
            piece(Head, More, Piece, Room, Receiver);
        error ->
            discard(control, Receiver#receiver{partial = none})
    end;
taken(Frame, _Room, Receiver) ->
    {{frame, Frame}, Receiver}.

%% A piece of the message under way, or the first piece of a new one.
piece(Head, More, Piece, _Room, #receiver{partial = #partial{head = Head} = Partial} = Receiver) ->
    continued(Partial, More, Piece, Receiver);
piece(Head, More, Piece, Room, #receiver{partial = #partial{}} = Receiver) ->
    first(Head, More, Piece, Room, count(pieces, Receiver#receiver{partial = none}));
piece(Head, More, Piece, Room, #receiver{partial = none} = Receiver) ->
    first(Head, More, Piece, Room, Receiver).

first(#{total := Total} = Head, More, Piece, _Room, #receiver{message_max = Max} = Receiver)
  when Total > Max ->
    unkept({error, too_large}, Head, More, Piece, count(too_large, Receiver));
first(#{total := Total} = Head, More, Piece, Room, Receiver) when Total > Room ->
    unkept({refused, Head}, Head, More, Piece, Receiver);
first(Head, More, Piece, _Room, Receiver) ->
    continued(#partial{mode = keep, head = Head}, More, Piece, Receiver).

%% The first piece of a message whose bytes are not kept: its later pieces are skipped.
unkept(Result, #{total := Total} = Head, More, Piece, Receiver) ->
    case fits(0, More, Piece, Total) of
        true when More ->
            {Result, Receiver#receiver{partial = #partial{mode = skip, head = Head,
                                                          got = byte_size(Piece)}}};
        true -> {Result, Receiver};
        false -> discard(pieces, Receiver)
    end.

%% A piece of a known message: it must leave room for a later piece when MORE is set and
%% end exactly at total when it is not.
continued(#partial{head = #{total := Total} = Head, got = Got, pieces = Pieces, mode = Mode} = Partial,
          More, Piece, Receiver) ->
    case {fits(Got, More, Piece, Total), More, Mode} of
        {false, _, _} ->
            discard(pieces, Receiver#receiver{partial = none});
        {true, true, keep} ->
            {pending, Receiver#receiver{partial = Partial#partial{got = Got + byte_size(Piece),
                                                                  pieces = [Piece | Pieces]}}};
        {true, false, keep} ->
            Payload = iolist_to_binary(lists:reverse([Piece | Pieces])),
            {{message, maps:put(payload, Payload, maps:remove(total, Head))},
             Receiver#receiver{partial = none}};
        {true, true, skip} ->
            {skipped, Receiver#receiver{partial = Partial#partial{got = Got + byte_size(Piece)}}};
        {true, false, skip} ->
            {skipped, Receiver#receiver{partial = none}}
    end.

%% A piece with MORE set is a full PIECE_MAX and leaves bytes for the last; the last piece
%% ends exactly at total.
fits(Got, true, Piece, Total) -> byte_size(Piece) =:= ?PIECE_MAX andalso Got + ?PIECE_MAX < Total;
fits(Got, false, Piece, Total) -> Got + byte_size(Piece) =:= Total.

discard(Reason, Receiver) ->
    {{error, Reason}, count(Reason, Receiver)}.

count(Key, #receiver{counts = Counts} = Receiver) ->
    Receiver#receiver{counts = maps:update_with(Key, fun(Count) -> Count + 1 end, 1, Counts)}.

decode_control(<<Kind:8, Flags:8, Reserved:16/little, Total:32/little, Id:64/little,
                 Piece/binary>>)
  when Flags band (bnot ?ERX_HOSTLINK_CONTROL_FLAGS_KNOWN) =:= 0, Reserved =:= 0 ->
    case kind_of(Kind) of
        {ok, cast} when Id =:= 0 -> {ok, cast, more(Flags), Total, Id, Piece};
        {ok, Named} when Named =/= cast, Id =/= 0 -> {ok, Named, more(Flags), Total, Id, Piece};
        _ -> error
    end;
decode_control(_Body) ->
    error.

more(Flags) -> Flags band ?ERX_HOSTLINK_CONTROL_MORE =/= 0.

control_header(Kind, More, Total, Id) ->
    Flags = case More of
                true -> ?ERX_HOSTLINK_CONTROL_MORE;
                false -> 0
            end,
    <<(kind_number(Kind)):8, Flags:8, 0:16, Total:32/little, Id:64/little>>.

kind_number(call) -> ?ERX_HOSTLINK_CALL;
kind_number(reply) -> ?ERX_HOSTLINK_REPLY;
kind_number(cast) -> ?ERX_HOSTLINK_CAST.

kind_of(?ERX_HOSTLINK_CALL) -> {ok, call};
kind_of(?ERX_HOSTLINK_REPLY) -> {ok, reply};
kind_of(?ERX_HOSTLINK_CAST) -> {ok, cast};
kind_of(_Number) -> error.

%% The frames of a message checked by message/5.
cut(Kind, Id, Target, Payload, #sender{session = Session} = Sender) ->
    Pieces = pieces(Payload),
    Last = length(Pieces),
    case numbered(Last, Sender) of
        {ok, Seqs, Next} ->
            Bodies = [<<(control_header(Kind, Index < Last, byte_size(Payload), Id))/binary,
                        Piece/binary>>
                      || {Index, Piece} <- lists:enumerate(Pieces)],
            {ok, [erx_hostlink_frame:encode(#{stream => control, session => Session, seq => Seq,
                                              target => Target, body => Body})
                  || {Seq, Body} <- lists:zip(Seqs, Bodies)],
             Next};
        {error, exhausted} ->
            {error, exhausted}
    end.

%% A payload's pieces: one per PIECE_MAX bytes, and one empty piece for an empty payload.
pieces(<<Piece:?PIECE_MAX/binary, Rest/binary>>) when Rest =/= <<>> -> [Piece | pieces(Rest)];
pieces(Last) -> [Last].

%% The numbers of the sender's next Count frames, unless one would pass its last seq.
numbered(Count, #sender{next = Next, last_seq = LastSeq} = Sender) when Next + Count - 1 =< LastSeq ->
    {ok, lists:seq(Next, Next + Count - 1), Sender#sender{next = Next + Count}};
numbered(_Count, #sender{}) ->
    {error, exhausted}.
