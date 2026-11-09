# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'generated_abi'

module Erx
  module Web
    # The WebSocket's frames (RFC 6455 section 5) between the front end and a browser.
    # A Deframer takes the browser's bytes, which are untrusted, and returns events; the
    # module's functions write the front end's own frames, which are never masked.
    module Socket
      MESSAGE_MAX = ABI::Generated::CODEC.constant('web_message_max')
      CONTROL_MAX = 125
      OPCODES = { continuation: 0, text: 1, binary: 2, close: 8, ping: 9, pong: 10 }.freeze
      CONTROL = [8, 9, 10].freeze
      # The close codes a peer may send (RFC 6455 section 7.4).
      CLOSE_CODES = [1000, 1001, 1002, 1003, *1007..1011, *3000..4999].freeze
      NORMAL = 1000
      GOING_AWAY = 1001
      PROTOCOL_ERROR = 1002
      UNSUPPORTED = 1003
      NOT_UTF8 = 1007
      TOO_BIG = 1009
      INTERNAL = 1011
      # The most a Deframer holds between feeds: a message's payload so far, and the
      # unfinished frame after it, whose length its header bounds: a data frame within the
      # message's bound, a control frame within CONTROL_MAX, each after at most 14 bytes
      # of header and mask.
      HELD_MAX = MESSAGE_MAX + 14 + CONTROL_MAX

      # A whole binary message.
      Message = Data.define(:bytes)
      Ping = Data.define(:payload)
      Pong = Data.define(:payload)
      # The browser's close frame; code is nil when it carried none.
      Closed = Data.define(:code)
      # The browser broke the protocol: the connection closes with code, the RFC's.
      Failed = Data.define(:code, :why)

      module_function

      def binary(bytes) = frame(OPCODES.fetch(:binary), bytes)

      def ping(payload = '') = frame(OPCODES.fetch(:ping), payload)

      def pong(payload) = frame(OPCODES.fetch(:pong), payload)

      def close(code) = frame(OPCODES.fetch(:close), [code].pack('n'))

      # One final, unmasked frame of opcode and payload.
      def frame(opcode, payload)
        size = payload.bytesize
        length = if size < 126 then [size].pack('C')
                 elsif size <= 0xffff then [126, size].pack('Cn')
                 else [127, size].pack('CQ>')
                 end
        [0x80 | opcode].pack('C') + length + payload.b
      end

      # XORs payload with the four-byte mask, four bytes at a time.
      def unmask(payload, mask)
        padded = payload.b + ("\0" * (-payload.bytesize % 4))
        word = mask.unpack1('N')
        padded.unpack('N*').map { |value| value ^ word }.pack('N*').byteslice(0, payload.bytesize)
      end

      # What a frame's header says: its size with the mask, its payload's length and mask,
      # its opcode and FIN bit.
      Header = Data.define(:size, :length, :mask, :opcode, :final)

      # Turns the browser's bytes into events: Messages, Pings, Pongs, and at most one
      # Closed or Failed, after which it takes nothing more. A frame's header is checked
      # before its payload is waited for, so a declared length past the bound fails at
      # once and is never buffered, and what it holds stays within HELD_MAX.
      class Deframer
        def initialize
          @buffer = ''.b
          @message = nil
          @ended = false
        end

        # The bytes held: an unfinished frame and an unfinished message.
        def held = @buffer.bytesize + (@message&.bytesize || 0)

        def ended? = @ended

        def feed(bytes)
          return [] if @ended

          @buffer << bytes.b
          events = []
          while (event = next_event)
            events << event
            next unless event.is_a?(Closed) || event.is_a?(Failed)

            # Nothing after the end is read, so nothing of it is held.
            @ended = true
            @buffer = ''.b
            @message = nil
            break
          end
          events
        end

        private

        # The next event the buffer's whole frames complete, taking every frame before it
        # that completes none (a piece of a message); nil once no whole frame is left.
        def next_event
          loop do
            header = header(@buffer)
            return nil if header.nil?
            return header if header.is_a?(Failed)

            return nil if @buffer.bytesize < header.size + header.length

            payload = Socket.unmask(@buffer.byteslice(header.size, header.length), header.mask)
            @buffer = @buffer.byteslice(header.size + header.length..)
            event = take(header.opcode, header.final, payload)
            return event if event
          end
        end

        # The Header of the frame at the start of bytes, nil if it is incomplete, or Failed
        # when the header alone breaks the protocol.
        def header(bytes)
          return nil if bytes.bytesize < 2

          first, second = bytes.unpack('CC')
          opcode = first & 0x0f
          return Failed.new(PROTOCOL_ERROR, 'reserved bits set') if first.anybits?(0x70)
          return Failed.new(PROTOCOL_ERROR, 'an unmasked frame') unless second.anybits?(0x80)
          return Failed.new(PROTOCOL_ERROR, 'an unknown opcode') unless OPCODES.value?(opcode)

          short = second & 0x7f
          extra = { 126 => 2, 127 => 8 }.fetch(short, 0)
          return nil if bytes.bytesize < 2 + extra + 4

          length = case extra
                   when 2 then bytes.byteslice(2, 2).unpack1('n')
                   when 8 then bytes.byteslice(2, 8).unpack1('Q>')
                   else short
                   end
          final = first.anybits?(0x80)
          header_failure(opcode, final, extra, length) ||
            Header.new(size: 2 + extra + 4, length: length, mask: bytes.byteslice(2 + extra, 4), opcode: opcode, final: final)
        end

        def header_failure(opcode, final, extra, length)
          return Failed.new(PROTOCOL_ERROR, 'a length not in its shortest form') if
            (extra == 2 && length < 126) || (extra == 8 && length <= 0xffff)
          return control_refusal(final, length) if CONTROL.include?(opcode)
          return Failed.new(UNSUPPORTED, 'a text message') if opcode == OPCODES.fetch(:text)
          return Failed.new(PROTOCOL_ERROR, 'a continuation with no message') if
            opcode == OPCODES.fetch(:continuation) && @message.nil?
          return Failed.new(PROTOCOL_ERROR, 'a message inside a message') if
            opcode == OPCODES.fetch(:binary) && @message
          return Failed.new(TOO_BIG, "a message over #{MESSAGE_MAX} bytes") unless fits?(length)

          nil
        end

        def control_refusal(final, length)
          return Failed.new(PROTOCOL_ERROR, 'a fragmented control frame') unless final
          return Failed.new(PROTOCOL_ERROR, "a control frame over #{CONTROL_MAX} bytes") if length > CONTROL_MAX

          nil
        end

        # Whether a data frame of length bytes keeps its message within MESSAGE_MAX.
        def fits?(length) = (@message&.bytesize || 0) + length <= MESSAGE_MAX

        def take(opcode, final, payload)
          case OPCODES.key(opcode)
          when :ping then Ping.new(payload)
          when :pong then Pong.new(payload)
          when :close then closed(payload)
          else data(final, payload)
          end
        end

        def data(final, payload)
          (@message ||= ''.b) << payload
          return nil unless final

          message = @message
          @message = nil
          Message.new(message)
        end

        def closed(payload)
          return Closed.new(nil) if payload.empty?
          return Failed.new(PROTOCOL_ERROR, 'a close frame of one byte') if payload.bytesize == 1

          code = payload.unpack1('n')
          return Failed.new(PROTOCOL_ERROR, 'a close code a peer may not send') unless CLOSE_CODES.include?(code)
          return Failed.new(NOT_UTF8, 'a close reason that is not UTF-8') unless
            payload.byteslice(2..).force_encoding(Encoding::UTF_8).valid_encoding?

          Closed.new(code)
        end
      end
    end
  end
end
