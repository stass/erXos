%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hostlink_frame).
-moduledoc """
The host link's wire frames (docs/design-live.md, "Host link frames"), as
pure functions: `encode/1` turns a frame into the bytes that go on the
serial line, and a deframer turns the bytes that arrive into frames.

On the wire a frame is the COBS encoding of a 28-byte header, a body of at
most 8,192 bytes and the CRC-32C of both, followed by one zero byte; the
layouts and bounds come from abi/protocols/hostlink.txt through the
generated header. Since COBS leaves no zero inside a frame, a receiver
finds the end of every frame, and after any damage it resynchronises at the
next zero.

`deframer/1` makes the state of one receiving side, `target` (the system
domain's `erx_hostlink`) or `host` (the host tool, whose Ruby twin is
tools/lib/erx/hostlink_frame.rb). `feed/2` takes the bytes as they arrive,
in pieces of any size, and returns, in order, `{ok, Frame}` for each
frame that passed every check and `{error, Reason}` for each it discarded:

* `oversize`: more than 8,300 encoded bytes before the zero, or a decoded
  body over 8,192 bytes. The deframer keeps at most 8,300 bytes of a frame
  it has not seen the end of, and skips to the next zero past that.
* `cobs`: a code byte that runs past the end of the frame.
* `short`: fewer bytes than a header and a CRC.
* `crc`: the CRC does not match.
* `version`: a version other than 2.
* `header`: a reserved field that is not zero, or a nonzero `target` on a
  stream that gives it no meaning.
* `stream`: a stream that this side does not receive. The target receives
  control, terminal and files; the host also events and credit.

Each discard is also counted, and `counts/1` gives the counts. Two zeros in
a row make an empty frame, which is no frame at all: a sender may send a
zero first to end whatever damaged bytes came before. Nothing here answers
the sender. The session, the sequence numbers and the control messages
carried in the bodies are erx_hostlink_stream's.

Every byte is untrusted: each parse is bounded by the sizes above, and
nothing the bytes hold makes these functions raise. `encode/1` is for the
system's own frames and fails with `badarg` on one outside the bounds.
""".

-include("generated/erx_abi.hrl").

-export([deframer/1, feed/2, counts/1, encode/1, decode/2, cobs_encode/1, cobs_decode/1]).

-export_type([deframer/0, frame/0, side/0, stream/0, session/0, reason/0]).

-define(HEADER, ?ERX_HOSTLINK_FRAME_SIZE).
-define(CRC, ?ERX_HOSTLINK_CRC_SIZE).
-define(BODY_MAX, ?ERX_HOSTLINK_BODY_MAX).
-define(ENCODED_MAX, ?ERX_HOSTLINK_ENCODED_MAX).
-define(U32_MAX, 16#FFFFFFFF).

%% header/1 and decode_header/1 lay the header out field by field in the bit syntax; this
%% fails the build if the generated layout ever puts a field elsewhere.
-if(?ERX_HOSTLINK_FRAME_OFF_VERSION =/= 0 orelse ?ERX_HOSTLINK_FRAME_OFF_STREAM =/= 1
    orelse ?ERX_HOSTLINK_FRAME_OFF_RESERVED =/= 2 orelse ?ERX_HOSTLINK_FRAME_OFF_SESSION =/= 4
    orelse ?ERX_HOSTLINK_FRAME_OFF_SEQ =/= 20 orelse ?ERX_HOSTLINK_FRAME_OFF_TARGET =/= 24
    orelse ?HEADER =/= 28 orelse ?CRC =/= 4).
-error("erx_hostlink_frame's header syntax disagrees with abi/protocols/hostlink.txt").
-endif.

%% The largest frame encodes within the bound: COBS adds one byte per 254 and one more.
-if(?HEADER + ?BODY_MAX + ?CRC + (?HEADER + ?BODY_MAX + ?CRC) div 254 + 1 > ?ENCODED_MAX).
-error("the host link's largest frame does not fit hostlink_encoded_max").
-endif.

-type side() :: target | host.
-type stream() :: control | terminal | events | credit | files.
-type session() :: <<_:128>>.
-type frame() :: #{stream := stream(), session := session(), seq := 0..?U32_MAX,
                   target := 0..?U32_MAX, body := binary()}.
-type reason() :: oversize | cobs | short | crc | version | header | stream.

%% partial holds the encoded bytes of the frame whose zero has not arrived yet, at most
%% ENCODED_MAX of them; skipping is true once a frame passed that bound, until its zero.
-record(deframer, {receives :: [stream()],
                   partial = <<>> :: binary(),
                   skipping = false :: boolean(),
                   counts = #{} :: #{reason() => pos_integer()}}).
-opaque deframer() :: #deframer{}.

-doc "A deframer for the side that receives, with nothing kept and nothing counted.".
-spec deframer(side()) -> deframer().
deframer(target) -> #deframer{receives = [control, terminal, files]};
deframer(host) -> #deframer{receives = [control, terminal, events, credit, files]}.

-doc """
The frames that `Bytes` completes, in order, after the bytes fed before,
each `{ok, Frame}` or `{error, Reason}`. Bytes after the last zero are kept
for the next call.
""".
-spec feed(binary(), deframer()) -> {[{ok, frame()} | {error, reason()}], deframer()}.
feed(Bytes, #deframer{} = Deframer) when is_binary(Bytes) ->
    %% binary:split/3 gives at least one part, the bytes after the last zero; every part
    %% before it ended at a zero.
    Parts = binary:split(Bytes, <<0>>, [global]),
    {Ended, [Tail]} = lists:split(length(Parts) - 1, Parts),
    {Results, Fed} = lists:foldl(fun ended/2, {[], Deframer}, Ended),
    {lists:reverse(Results), unended(Tail, Fed)}.

-doc "How many frames the deframer has discarded, by reason; a reason never seen is absent.".
-spec counts(deframer()) -> #{reason() => pos_integer()}.
counts(#deframer{counts = Counts}) -> Counts.

-doc """
The wire bytes of one frame, ending with its zero. Fails with `badarg` on a
body over 8,192 bytes, a field outside its width, an unknown stream, or a
nonzero `target` on a stream that gives it no meaning, so it makes only
frames a receiver takes.
""".
-spec encode(frame()) -> binary().
encode(#{stream := Stream, session := <<_:16/binary>> = Session, seq := Seq, target := Target,
         body := Body})
  when is_binary(Body), byte_size(Body) =< ?BODY_MAX, is_integer(Seq), Seq >= 0, Seq =< ?U32_MAX,
       is_integer(Target), Target >= 0, Target =< ?U32_MAX,
       (Stream =:= control orelse Stream =:= credit orelse
        ((Stream =:= terminal orelse Stream =:= events orelse Stream =:= files) andalso Target =:= 0)) ->
    Covered = <<(header(stream_number(Stream), Session, Seq, Target))/binary, Body/binary>>,
    Crc = erx_bytes:crc32c(0, Covered),
    <<(cobs_encode(<<Covered/binary, Crc:32/little>>))/binary, 0>>;
encode(_Frame) ->
    erlang:error(badarg).

-doc """
The frame of one encoded frame without its zero, checked for the side that
receives it, or why it is discarded. `feed/2` uses it for every frame.
""".
-spec decode(side(), binary()) -> {ok, frame()} | {error, reason()}.
decode(Side, Encoded) when is_binary(Encoded) ->
    #deframer{receives = Receives} = deframer(Side),
    decode_encoded(Receives, Encoded).

-doc """
The COBS encoding of `Bytes` (Cheshire and Baker): each run of nonzero
bytes up to a zero, or 254 of them, becomes a code byte, one more than the
run's length, and the run; the zero after a run shorter than 254 is
implied, and a last run of 254 bytes or a multiple has no empty group
after it, as in the paper's encoder. The result holds no zero.
""".
-spec cobs_encode(binary()) -> binary().
cobs_encode(Bytes) when is_binary(Bytes) ->
    Runs = binary:split(Bytes, <<0>>, [global]),
    Encoded = << <<(cobs_runs(Run))/binary>> || Run <- Runs >>,
    Last = lists:last(Runs),
    case byte_size(Last) of
        Size when Size > 0, Size rem 254 =:= 0 -> binary:part(Encoded, 0, byte_size(Encoded) - 1);
        _ -> Encoded
    end.

-doc "The bytes a COBS encoding holds, or `{error, cobs}` if a code byte runs past its end or it holds a zero.".
-spec cobs_decode(binary()) -> {ok, binary()} | {error, cobs}.
cobs_decode(Encoded) when is_binary(Encoded) ->
    cobs_groups(Encoded, []).

%% The bytes of a frame up to its zero.
ended(Piece, {Results, #deframer{skipping = true} = Deframer}) when is_binary(Piece) ->
    discard(oversize, Results, Deframer#deframer{skipping = false, partial = <<>>});
ended(Piece, {Results, #deframer{partial = Partial} = Deframer}) ->
    Cleared = Deframer#deframer{partial = <<>>},
    case byte_size(Partial) + byte_size(Piece) of
        0 -> {Results, Cleared};
        Size when Size > ?ENCODED_MAX -> discard(oversize, Results, Cleared);
        _ ->
            case decode_encoded(Deframer#deframer.receives, <<Partial/binary, Piece/binary>>) of
                {ok, Frame} -> {[{ok, Frame} | Results], Cleared};
                {error, Reason} -> discard(Reason, Results, Cleared)
            end
    end.

%% The bytes after the last zero, kept up to the bound.
unended(_Tail, #deframer{skipping = true} = Deframer) ->
    Deframer;
unended(Tail, #deframer{partial = Partial} = Deframer)
  when byte_size(Partial) + byte_size(Tail) > ?ENCODED_MAX ->
    Deframer#deframer{partial = <<>>, skipping = true};
unended(Tail, #deframer{partial = Partial} = Deframer) ->
    Deframer#deframer{partial = <<Partial/binary, Tail/binary>>}.

discard(Reason, Results, #deframer{counts = Counts} = Deframer) ->
    {[{error, Reason} | Results],
     Deframer#deframer{counts = maps:update_with(Reason, fun(Count) -> Count + 1 end, 1, Counts)}}.

decode_encoded(Receives, Encoded) ->
    case cobs_decode(Encoded) of
        {ok, Decoded} -> check(Receives, Decoded);
        {error, cobs} -> {error, cobs}
    end.

check(_Receives, Decoded) when byte_size(Decoded) < ?HEADER + ?CRC ->
    {error, short};
check(_Receives, Decoded) when byte_size(Decoded) > ?HEADER + ?BODY_MAX + ?CRC ->
    {error, oversize};
check(Receives, Decoded) ->
    CoveredSize = byte_size(Decoded) - ?CRC,
    <<Covered:CoveredSize/binary, Crc:32/little>> = Decoded,
    case erx_bytes:crc32c(0, Covered) of
        Crc ->
            <<Header:?HEADER/binary, Body/binary>> = Covered,
            check_header(Receives, decode_header(Header), Body);
        _ ->
            {error, crc}
    end.

%% The header's checks in order; the first that fails names the reason.
check_header(Receives, #{version := Version, stream := Number, reserved := Reserved,
                         target := Target} = Header, Body) ->
    Stream = stream_of(Number),
    if
        Version =/= ?ERX_HOSTLINK_VERSION -> {error, version};
        Reserved =/= 0 -> {error, header};
        Stream =:= unknown -> {error, stream};
        true ->
            case lists:member(Stream, Receives) of
                false -> {error, stream};
                true when Target =/= 0 -> target_check(Stream, Header, Body);
                true -> {ok, frame_of(Stream, Header, Body)}
            end
    end.

target_check(Stream, Header, Body) ->
    case takes_target(Stream) of
        true -> {ok, frame_of(Stream, Header, Body)};
        false -> {error, header}
    end.

frame_of(Stream, #{session := Session, seq := Seq, target := Target}, Body) ->
    #{stream => Stream, session => Session, seq => Seq, target => Target, body => Body}.

%% Only the control stream's facet number and the credit stream's grant use target.
takes_target(control) -> true;
takes_target(credit) -> true;
takes_target(_Stream) -> false.

header(Number, Session, Seq, Target) ->
    <<?ERX_HOSTLINK_VERSION:8, Number:8, 0:16, Session:16/binary, Seq:32/little, Target:32/little>>.

decode_header(<<Version:8, Number:8, Reserved:16/little, Session:16/binary, Seq:32/little,
                Target:32/little>>) ->
    #{version => Version, stream => Number, reserved => Reserved, session => Session, seq => Seq,
  target => Target}.

stream_number(control) -> ?ERX_HOSTLINK_STREAM_CONTROL;
stream_number(terminal) -> ?ERX_HOSTLINK_STREAM_TERMINAL;
stream_number(events) -> ?ERX_HOSTLINK_STREAM_EVENTS;
stream_number(credit) -> ?ERX_HOSTLINK_STREAM_CREDIT;
stream_number(files) -> ?ERX_HOSTLINK_STREAM_FILES.

stream_of(?ERX_HOSTLINK_STREAM_CONTROL) -> control;
stream_of(?ERX_HOSTLINK_STREAM_TERMINAL) -> terminal;
stream_of(?ERX_HOSTLINK_STREAM_EVENTS) -> events;
stream_of(?ERX_HOSTLINK_STREAM_CREDIT) -> credit;
stream_of(?ERX_HOSTLINK_STREAM_FILES) -> files;
stream_of(_Number) -> unknown.

%% A run of nonzero bytes and the zero after it (or the end), as COBS groups: full groups
%% of 254 bytes with code 255, then the rest with its length plus one. A run whose length
%% is a multiple of 254, the empty run included, ends with a group of code 1, which
%% cobs_encode/1 drops after the last run unless that run is empty.
cobs_runs(<<Group:254/binary, Rest/binary>>) ->
    <<255, Group/binary, (cobs_runs(Rest))/binary>>;
cobs_runs(Run) ->
    <<(byte_size(Run) + 1), Run/binary>>.

%% Each group gives its code's bytes, then the zero it implies unless its code is 255 or it
%% is the last group.
cobs_groups(<<>>, Decoded) ->
    {ok, iolist_to_binary(lists:reverse(Decoded))};
cobs_groups(<<0, _/binary>>, _Decoded) ->
    {error, cobs};
cobs_groups(<<Code, Rest/binary>>, Decoded) when byte_size(Rest) >= Code - 1 ->
    Length = Code - 1,
    <<Group:Length/binary, After/binary>> = Rest,
    case {Code, After} of
        {255, _} -> cobs_groups(After, [Group | Decoded]);
        {_, <<>>} -> cobs_groups(After, [Group | Decoded]);
        _ -> cobs_groups(After, [<<0>>, Group | Decoded])
    end;
cobs_groups(_Encoded, _Decoded) ->
    {error, cobs}.
