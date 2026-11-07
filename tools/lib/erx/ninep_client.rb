# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'generated_abi'
require_relative 'error'
require_relative 'line_escape'

module Erx
  # A small 9P2000.L client over one byte stream, for the host tests and the exit check
  # of `tools/erx files` (docs/design-live.md, "Files between the host and the machine"):
  # version, attach, walk, lopen, read and clunk, one request at a time. Message types,
  # NOFID and the error numbers come from the file protocol's table (abi/protocols/9p.txt)
  # through the generated ABI, never from constants of its own.
  #
  # What the server sends is untrusted: each reply's size is checked against the
  # negotiated msize before its bytes are read, every length and count against what the
  # message holds, and an error is reported by its name from the table, the number
  # itself when the table has none. Nothing the server sent is shown unescaped.
  class NinepClient
    # The server answered with an error, or outside the protocol.
    class Refused < Error; end
    # A deadline passed with no reply.
    class Timeout < Error; end
    # A file read past the byte cap its caller set.
    class TooLarge < Error; end

    CODEC = ABI::Generated::CODEC
    PROTOCOL = ABI::Generated::SCHEMA.protocols.find { |protocol| protocol.fetch(:name) == 'erx_9p' }
    TYPES = PROTOCOL.fetch(:operations).to_h { |operation| [operation.fetch(:name).to_sym, operation.fetch(:type)] }.freeze
    RLERROR = PROTOCOL.fetch(:error_type)
    ERRORS = PROTOCOL.fetch(:error_numbers).to_h { |name, number| [number, name] }.freeze
    NOFID = CODEC.constant('p9_nofid')
    NOTAG = CODEC.constant('p9_notag')
    VERSION = '9P2000.L'
    HEADER = 7
    # The most bytes read_file holds by default: well above any file the exit check reads.
    READ_MAX = 16 * 1024 * 1024
    QID = 13

    Qid = Data.define(:type, :version, :path)

    attr_reader :msize

    # io is the stream; msize the largest message this client offers; deadline the
    # seconds any one reply may take.
    def initialize(io:, msize: 8192, deadline: 30)
      @io = io
      @msize = msize
      @deadline = deadline
      @tag = 0
    end

    # Opens the session; returns the msize the server agreed.
    def version
      reply = rpc(:version, [@msize].pack('V') + string(VERSION), tag: NOTAG)
      agreed, rest = reply.unpack('Va*')
      raise Refused, "the server speaks #{LineEscape.escape(text(rest))}, not #{VERSION}" unless text(rest) == VERSION
      raise Refused, "the server offered an msize of #{agreed}, more than #{@msize}" if agreed > @msize

      @msize = agreed
    end

    def attach(fid, aname, uname: 'erx')
      qid(rpc(:attach, [fid, NOFID].pack('VV') + string(uname) + string(aname) + [0].pack('V')))
    end

    # The qids walked; fewer than names when the walk stopped part way.
    def walk(fid, new_fid, names)
      reply = rpc(:walk, [fid, new_fid, names.size].pack('VVv') + names.map { |name| string(name) }.join)
      raise Refused, "a walk reply of #{reply.bytesize} bytes, short of its count" if reply.bytesize < 2

      count = reply.unpack1('v')
      raise Refused, "a walk reply of #{count} qids for #{names.size} names" if count > names.size ||
                                                                               reply.bytesize != 2 + (count * QID)

      Array.new(count) { |index| qid(reply.byteslice(2 + (index * QID), QID)) }
    end

    # The opened file's qid and iounit.
    def lopen(fid, flags)
      reply = rpc(:lopen, [fid, flags].pack('VV'))
      raise Refused, 'an lopen reply of the wrong size' unless reply.bytesize == QID + 4

      [qid(reply.byteslice(0, QID)), reply.byteslice(QID, 4).unpack1('V')]
    end

    def read(fid, offset, count)
      reply = rpc(:read, [fid, offset, count].pack('VQ<V'))
      size = reply.unpack1('V')
      raise Refused, "a read reply of #{size} bytes for #{count}" if size.nil? || size > count || reply.bytesize != 4 + size

      reply.byteslice(4, size)
    end

    def clunk(fid)
      rpc(:clunk, [fid].pack('V'))
      nil
    end

    # The whole of the file at names in tree aname, read through fids 1 and 2; raises
    # TooLarge once it holds more than max_bytes, since the server decides where it ends.
    def read_file(aname, names, max_bytes: READ_MAX)
      attach(1, aname)
      raise Refused, "#{LineEscape.escape(names.join('/'))} not found" unless walk(1, 2, names).size == names.size

      _qid, iounit = lopen(2, 0)
      unit = iounit.zero? ? @msize - 24 : [iounit, @msize - 11].min
      contents = read_from(2, unit, max_bytes)
      clunk(2)
      clunk(1)
      contents
    end

    private

    def read_from(fid, unit, max_bytes)
      contents = String.new(encoding: Encoding::BINARY)
      loop do
        piece = read(fid, contents.bytesize, unit)
        return contents if piece.empty?

        contents << piece
        raise TooLarge, "the file holds more than #{max_bytes} bytes" if contents.bytesize > max_bytes
      end
    end

    # Sends one request and returns the body of its reply, raising on Rlerror.
    def rpc(name, body, tag: next_tag)
      type = TYPES.fetch(name)
      @io.write([HEADER + body.bytesize, type, tag].pack('VCv') + body)
      @io.flush
      reply_type, reply_tag, reply = receive
      raise Refused, "a reply to tag #{reply_tag}, not #{tag}" unless reply_tag == tag
      raise Refused, "#{name}: #{error_name(reply)}" if reply_type == RLERROR
      raise Refused, "#{name}: a reply of type #{reply_type}" unless reply_type == type + 1

      reply
    end

    def receive
      head = read_exactly(4)
      size = head.unpack1('V')
      raise Refused, "a reply of #{size} bytes, outside #{HEADER} to #{@msize}" unless size.between?(HEADER, @msize)

      type, tag = read_exactly(3).unpack('Cv')
      [type, tag, read_exactly(size - HEADER)]
    end

    def read_exactly(count)
      bytes = String.new(encoding: Encoding::BINARY)
      limit = now + @deadline
      while bytes.bytesize < count
        raise Timeout, "no 9P reply within #{@deadline} s" unless @io.wait_readable([limit - now, 0].max)

        piece = @io.read_nonblock(count - bytes.bytesize, exception: false)
        raise Refused, 'the 9P server closed the connection' if piece.nil?

        bytes << piece unless piece == :wait_readable
      end
      bytes
    end

    def error_name(reply)
      number = reply.unpack1('V')
      raise Refused, 'an Rlerror of the wrong size' unless reply.bytesize == 4

      ERRORS.fetch(number, number.to_s)
    end

    def qid(bytes)
      raise Refused, 'a qid of the wrong size' unless bytes.bytesize == QID

      Qid.new(*bytes.unpack('CVQ<'))
    end

    def string(value)
      bytes = value.b
      [bytes.bytesize].pack('v') + bytes
    end

    # A string field's text; its length must be what remains.
    def text(bytes)
      length = bytes.unpack1('v')
      raise Refused, 'a string field that runs past its message' unless length && bytes.bytesize == 2 + length

      bytes.byteslice(2, length)
    end

    # Tags 0 to 65534 in turn; NOTAG is only version's.
    def next_tag = (@tag = (@tag + 1) % NOTAG)

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
