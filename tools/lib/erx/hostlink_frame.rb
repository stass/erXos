# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../generated/abi'
require_relative 'error'

module Erx
  # The host tool's half of the host link's frame layer (docs/design-live.md,
  # "Host link frames"), written apart from the target's erx_hostlink_frame and
  # erx_hostlink_stream and checked against them by shared byte vectors
  # (test/fixtures/hostlink_frames.txt) and a cross test, so a disagreement is
  # a bug in one of them.
  #
  # On the wire a frame is the COBS encoding of a 28-byte header, a body of at
  # most 8,192 bytes and the CRC-32C of both, then one zero byte; the layouts and
  # bounds are abi/protocols/hostlink.txt's. A Deframer turns the bytes that
  # arrive into Frames and Discards, a Receiver takes the frames of one session
  # and reassembles control messages from their pieces, a Sender numbers the
  # frames it sends and cuts control messages into pieces, and Credit holds what
  # the host may still send. The session protocol over them is the host tool's.
  #
  # Every byte from the target is untrusted: each parse is bounded, and nothing
  # the bytes hold makes a Deframer or a Receiver raise. The errors below are
  # for the tool's own mistakes and its own exhausted counters.
  module HostlinkFrame
    CODEC = ABI::Generated::CODEC

    HEADER_SIZE = CODEC.layout_size('erx_hostlink_frame')
    CONTROL_SIZE = CODEC.layout_size('erx_hostlink_control')
    CRC_SIZE = CODEC.constant('hostlink_crc_size')
    BODY_MAX = CODEC.constant('hostlink_body_max')
    ENCODED_MAX = CODEC.constant('hostlink_encoded_max')
    MESSAGE_MAX = CODEC.constant('hostlink_message_max')
    CREDIT_INITIAL = CODEC.constant('hostlink_credit_initial')
    VERSION = CODEC.constant('hostlink_version')
    PIECE_MAX = BODY_MAX - CONTROL_SIZE
    MORE = CODEC.member('hostlink_control_flags', 'more')
    FLAGS_KNOWN = CODEC.constant('hostlink_control_flags_known')
    U32_MAX = 0xffff_ffff
    U64_MAX = 0xffff_ffff_ffff_ffff
    SESSION_ZERO = ("\0" * 16).b.freeze

    STREAMS = %w[control terminal events credit files].to_h { |name| [name.to_sym, CODEC.member('hostlink_stream', name)] }
                                                       .freeze
    STREAM_NAMES = STREAMS.invert.freeze
    KINDS = %w[call reply cast].to_h { |name| [name.to_sym, CODEC.member('hostlink_kind', name)] }.freeze
    KIND_NAMES = KINDS.invert.freeze
    # The streams each side receives: the target is sent no events and no credit.
    RECEIVES = { target: %i[control terminal files], host: %i[control terminal events credit files] }.freeze
    # Only the control stream's facet number and the credit stream's grant use target.
    TARGETED = %i[control credit].freeze

    Frame = Data.define(:stream, :session, :seq, :target, :body)
    # A frame or a piece the receiver discarded, and why (Deframer and Receiver).
    Discard = Data.define(:reason)

    class EncodeError < Error; end
    class Exhausted < Error; end
    class TooLarge < Error; end
    class NoCredit < Error; end

    CRC_TABLE = (0..255).map do |byte|
      8.times.reduce(byte) { |crc, _| crc.odd? ? (crc >> 1) ^ 0x82f63b78 : crc >> 1 }
    end.freeze

    module_function

    # CRC-32C (Castagnoli, RFC 3720), table-driven.
    def crc32c(bytes)
      bytes.each_byte.reduce(0xffffffff) { |crc, byte| CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >> 8) } ^ 0xffffffff
    end

    # COBS (Cheshire and Baker): each run of nonzero bytes up to a zero, or 254 of
    # them, becomes a code byte one more than its length and the run; the zero after a
    # run shorter than 254 is implied. The result holds no zero.
    def cobs_encode(bytes)
      runs = bytes.empty? ? [''.b] : bytes.b.split("\0", -1)
      encoded = runs.map { |run| cobs_run(run) }.join.b
      # A last run of 254 bytes or a multiple has no empty group after it, as in the paper's encoder.
      last = runs.last.bytesize
      last.positive? && (last % 254).zero? ? encoded.byteslice(0...-1) : encoded
    end

    # The bytes a COBS encoding holds, or nil if a code byte runs past its end or it
    # holds a zero.
    def cobs_decode(encoded)
      decoded = []
      at = 0
      while at < encoded.bytesize
        code = encoded.getbyte(at)
        return nil if code.zero? || at + code > encoded.bytesize

        decoded << encoded.byteslice(at + 1, code - 1)
        at += code
        decoded << "\0" if code != 255 && at < encoded.bytesize
      end
      decoded.join.b
    end

    # The wire bytes of one frame, ending with its zero.
    def encode(frame)
      check_frame(frame)
      header = CODEC.encode_layout('erx_hostlink_frame',
                                   'version' => VERSION, 'stream' => STREAMS.fetch(frame.stream), 'reserved' => 0,
                                   'session' => frame.session.b, 'seq' => frame.seq, 'target' => frame.target)
      covered = header + frame.body.b
      "#{cobs_encode(covered + [crc32c(covered)].pack('V'))}\0".b
    end

    # The Frame of one encoded frame without its zero, checked for the side that
    # receives it, or a Discard saying why not.
    def decode(side, encoded)
      decoded = cobs_decode(encoded.b)
      return Discard.new(:cobs) if decoded.nil?
      return Discard.new(:short) if decoded.bytesize < HEADER_SIZE + CRC_SIZE
      return Discard.new(:oversize) if decoded.bytesize > HEADER_SIZE + BODY_MAX + CRC_SIZE

      covered = decoded.byteslice(0, decoded.bytesize - CRC_SIZE)
      return Discard.new(:crc) unless crc32c(covered) == decoded.byteslice(-CRC_SIZE, CRC_SIZE).unpack1('V')

      header_check(side, CODEC.decode_layout('erx_hostlink_frame', covered, prefix: true),
                   covered.byteslice(HEADER_SIZE..))
    end

    def header_check(side, header, body)
      stream = STREAM_NAMES[header.fetch('stream')]
      return Discard.new(:version) unless header.fetch('version') == VERSION
      return Discard.new(:header) unless header.fetch('reserved').zero?
      return Discard.new(:stream) unless RECEIVES.fetch(side).include?(stream)
      return Discard.new(:header) unless TARGETED.include?(stream) || header.fetch('target').zero?

      Frame.new(stream: stream, session: header.fetch('session').b.freeze, seq: header.fetch('seq'),
                target: header.fetch('target'), body: body.b.freeze)
    end
    private_class_method :header_check

    def check_frame(frame)
      targeted = TARGETED.include?(frame.stream) || frame.target.zero?
      valid = STREAMS.key?(frame.stream) && frame.session.bytesize == 16 && frame.body.bytesize <= BODY_MAX &&
              frame.seq.between?(0, U32_MAX) && frame.target.between?(0, U32_MAX) && targeted
      raise EncodeError, 'host link frame outside its bounds' unless valid
    end
    private_class_method :check_frame

    def cobs_run(run)
      run.bytes.each_slice(254).flat_map { |group| group.size == 254 ? [255, *group] : [group.size + 1, *group] }
         .then { |groups| run.bytesize % 254 == 0 ? groups + [1] : groups }
         .pack('C*')
    end
    private_class_method :cobs_run

    # The receiving side's frames from the bytes as they arrive, in pieces of any
    # size. It keeps at most ENCODED_MAX bytes of a frame whose zero has not come, and
    # past that skips to the next zero.
    class Deframer
      attr_reader :counts

      def initialize(side)
        raise ArgumentError, "unknown host link side #{side}" unless RECEIVES.key?(side)

        @side = side
        @partial = +''.b
        @skipping = false
        @counts = Hash.new(0)
      end

      # The Frames and Discards that bytes completes, in order.
      def feed(bytes)
        *ended, tail = bytes.b.split("\0", -1)
        results = ended.filter_map { |piece| ended_frame(piece) }
        unended(tail || ''.b)
        results
      end

      private

      def ended_frame(piece)
        skipped = @skipping
        size = @partial.bytesize + piece.bytesize
        partial = @partial
        @partial = +''.b
        @skipping = false
        result = if skipped || size > ENCODED_MAX then Discard.new(:oversize)
                 elsif size.zero? then nil
                 else HostlinkFrame.decode(@side, partial + piece)
                 end
        @counts[result.reason] += 1 if result.is_a?(Discard)
        result
      end

      def unended(tail)
        return if @skipping

        if @partial.bytesize + tail.bytesize > ENCODED_MAX
          @partial = +''.b
          @skipping = true
        else
          @partial << tail
        end
      end
    end

    # A control message, whole, with its payload's external-term-format bytes.
    Message = Data.define(:kind, :id, :target, :session, :payload)
    # A control message of session 0, which carries a hello, in one frame.
    Hello = Data.define(:message)
    # The first piece of a control message the room could not hold.
    Head = Data.define(:kind, :id, :target, :session, :total)
    Refused = Data.define(:head)
    Taken = Data.define(:frame)

    # The frames of one session (erx_hostlink_stream's receiver). accept gives a
    # Taken for a frame of another stream than control, a Message, a Hello,
    # :pending, a Refused, :skipped or a Discard, as erx_hostlink_stream:accept/3
    # does; its moduledoc states the rules. room is what the tool's resident limit
    # has left besides held.
    class Receiver
      attr_reader :counts, :session

      # The message under way: kept, with its bytes so far in a buffer the receiver
      # owns, or skipped after a refusal. Every piece but the last is PIECE_MAX bytes,
      # so the buffer never passes the total reserved.
      Partial = Struct.new(:mode, :head, :got, :buffer, keyword_init: true)

      def initialize(message_max: MESSAGE_MAX)
        raise ArgumentError, 'host link message limit outside its bounds' unless message_max.between?(0, MESSAGE_MAX)

        @message_max = message_max
        @session = nil
        @last = nil
        @partial = nil
        @counts = Hash.new(0)
      end

      # The current session, or nil once it has ended; the message under way is
      # dropped and the sequence starts anew.
      def session=(session)
        raise ArgumentError, 'a host link session is 16 bytes, not all zero' unless
          session.nil? || (session.bytesize == 16 && session.b != SESSION_ZERO)

        @session = session&.b
        @last = nil
        @partial = nil
      end

      def held = @partial&.mode == :keep ? @partial.head.total : 0

      def accept(frame, room: @message_max)
        return hello(frame) if frame.stream == :control && frame.session == SESSION_ZERO
        return discard(:session) unless @session && frame.session == @session
        return discard(:seq) if @last && frame.seq < @last

        sequence(frame)
        frame.stream == :control ? control(frame, room) : Taken.new(frame)
      end

      private

      # A frame above the one expected (a gap) ends the message under way; accept has
      # discarded one below it.
      def sequence(frame)
        if @last && frame.seq != @last
          @counts[:gap] += 1
          @partial = nil
        end
        @last = frame.seq + 1
      end

      # A whole message in one frame, apart from the current session's sequence and
      # from room: a hello replaces the session room leaves out.
      def hello(frame)
        header = control_header(frame.body)
        return discard(:control) if header.nil?

        kind, more, total, id = header
        piece = frame.body.byteslice(CONTROL_SIZE..)
        return discard(:too_large) if total > @message_max
        return discard(:pieces) if more || piece.bytesize != total

        head = Head.new(kind: kind, id: id, target: frame.target, session: SESSION_ZERO, total: total)
        Hello.new(message(head, piece))
      end

      def control(frame, room)
        header = control_header(frame.body)
        if header.nil?
          @partial = nil
          return discard(:control)
        end

        kind, more, total, id = header
        head = Head.new(kind: kind, id: id, target: frame.target, session: frame.session, total: total)
        piece = frame.body.byteslice(CONTROL_SIZE..)
        return continued(more, piece) if @partial&.head == head

        @counts[:pieces] += 1 if @partial
        @partial = nil
        first(head, more, piece, room)
      end

      def first(head, more, piece, room)
        return unkept(discard(:too_large), head, more, piece) if head.total > @message_max
        return unkept(Refused.new(head), head, more, piece) if head.total > room

        @partial = Partial.new(mode: :keep, head: head, got: 0, buffer: +''.b)
        continued(more, piece)
      end

      # The first piece of a message whose bytes are not kept: its later pieces are skipped.
      def unkept(result, head, more, piece)
        return discard(:pieces) unless fits?(0, more, piece, head.total)

        @partial = Partial.new(mode: :skip, head: head, got: piece.bytesize, buffer: nil) if more
        result
      end

      # A piece of the message under way, which must fit its place in it.
      def continued(more, piece)
        partial = @partial
        unless fits?(partial.got, more, piece, partial.head.total)
          @partial = nil
          return discard(:pieces)
        end

        partial.got += piece.bytesize
        partial.buffer << piece if partial.mode == :keep
        @partial = nil unless more
        case [more, partial.mode]
        in [true, :keep] then :pending
        in [false, :keep] then message(partial.head, partial.buffer)
        in [_, :skip] then :skipped
        end
      end

      def message(head, payload)
        Message.new(kind: head.kind, id: head.id, target: head.target, session: head.session,
                    payload: payload.b.freeze)
      end

      # A piece with MORE set is a full PIECE_MAX and leaves bytes for the last; the
      # last piece ends exactly at total.
      def fits?(got, more, piece, total)
        return piece.bytesize == PIECE_MAX && got + PIECE_MAX < total if more

        got + piece.bytesize == total
      end

      def control_header(body)
        return nil if body.bytesize < CONTROL_SIZE

        fields = CODEC.decode_layout('erx_hostlink_control', body, prefix: true)
        kind = KIND_NAMES[fields.fetch('kind')]
        flags = fields.fetch('flags')
        id = fields.fetch('id')
        return nil if kind.nil? || (flags & ~FLAGS_KNOWN) != 0 || !fields.fetch('reserved').zero?
        return nil unless kind == :cast ? id.zero? : id.positive?

        [kind, (flags & MORE) != 0, fields.fetch('total'), id]
      end

      def discard(reason)
        @counts[reason] += 1
        Discard.new(reason)
      end
    end

    # The frames one session sends, numbered from 0 (erx_hostlink_stream's sender).
    # A frame is numbered only once it is made, so a refused one leaves no gap.
    class Sender
      def initialize(session)
        raise ArgumentError, 'a host link session is 16 bytes' unless session.bytesize == 16

        @session = session.b.freeze
        @next = 0
      end

      # The wire bytes of one frame of a stream other than control.
      def frame(stream, body, target: 0)
        raise ArgumentError, 'control frames are sent as messages' if stream == :control

        numbered([[stream, target, body.b]]).first
      end

      # The wire bytes of the frames of one control message, in order.
      def message(kind, payload, id:, target:)
        raise ArgumentError, 'a call or reply has a nonzero id, a cast id 0' unless
          KINDS.key?(kind) && id.between?(0, U64_MAX) && (kind == :cast ? id.zero? : id.positive?)
        raise TooLarge, "host link message of #{payload.bytesize} bytes" if payload.bytesize > MESSAGE_MAX

        pieces = payload.b.empty? ? [''.b] : payload.b.scan(/.{1,#{PIECE_MAX}}/mn)
        numbered(pieces.each_with_index.map do |piece, index|
          more = index < pieces.size - 1 ? MORE : 0
          header = CODEC.encode_layout('erx_hostlink_control', 'kind' => KINDS.fetch(kind), 'flags' => more,
                                                               'reserved' => 0, 'total' => payload.bytesize, 'id' => id)
          [:control, target, header + piece]
        end)
      end

      private

      # The wire bytes of frames given as [stream, target, body], numbered from the next.
      def numbered(frames)
        raise Exhausted, 'host link frame numbers exhausted; the session must end' if @next + frames.size - 1 > U32_MAX

        wire = frames.each_with_index.map do |(stream, target, body), index|
          HostlinkFrame.encode(Frame.new(stream: stream, session: @session, seq: @next + index, target: target,
                                         body: body))
        end
        @next += frames.size
        wire
      end
    end

    # The bytes the host may still send: CREDIT_INITIAL at the start of a session,
    # plus what the target has granted since. A credit frame's target is the total
    # granted in the session modulo 2^32, so a later grant makes up for a lost one.
    # The host counts every byte it sends from its hello's first byte on (spend), and
    # the target never grants a byte it was not sent (erx_hostlink_stream, "Credit"),
    # so a grant that adds more than was sent and not yet granted is a stale or bogus
    # one, and is ignored.
    class Credit
      attr_reader :available

      def initialize
        @available = CREDIT_INITIAL
        @granted = 0
        @ungranted = 0
      end

      def allows?(bytes) = bytes <= @available

      def spend(bytes)
        raise NoCredit, "#{bytes} bytes with #{@available} of credit" unless allows?(bytes)

        @available -= bytes
        @ungranted += bytes
      end

      # Takes a credit frame; false when its grant is ignored.
      def grant(frame)
        delta = (frame.target - @granted) % (U32_MAX + 1)
        return false if delta > @ungranted

        @available += delta
        @ungranted -= delta
        @granted = frame.target
        true
      end
    end
  end
end
