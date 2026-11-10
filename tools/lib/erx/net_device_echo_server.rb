# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'socket'
require_relative 'error'

module Erx
  module NetDevice
    # The TCP echo server the guest's connections to QemuPlan::NIC_ECHO_ADDRESS port
    # QemuPlan::NIC_ECHO_PORT reach through slirp's guest forward (QemuPlan::Nic's
    # echo_port). QEMU opens one connection to it when QEMU starts and carries the bytes
    # of every guest connection to that address and port over it, so the server sees one
    # stream and echoes it back as it comes. It counts and digests what it takes, which
    # the harness compares with the digest the guest prints of what it sent.
    #
    # One thread reads and another writes, with the bytes between them queued. A server
    # that read and wrote on one thread would stall the run: while the guest's receive
    # window is closed, slirp stops reading the server's echo, so the server would block
    # in its write and stop reading; QEMU writes the guest's bytes into the stream with a
    # blocking write from its main loop, which would then block too, and with it slirp
    # and the device. The server takes at most limit bytes: a guest that sends more fails
    # the run instead of growing the harness.
    #
    # The server listens on the host's loopback only, on a port the kernel picks, from new
    # until stop, and serves the first connection it accepts, which is QEMU's.
    class EchoServer
      READ_BYTES = 65_536

      def initialize(limit:)
        @limit = limit
        @server = TCPServer.new('127.0.0.1', 0)
        @digest = Digest::MD5.new
        @received = 0
        @lock = Mutex.new
        @queue = Queue.new
        @client = nil
        @threads = []
      end

      def port = @server.addr[1]

      # Each thread's value is the error it met, or nil, so stopping never raises and a
      # run's own failure is never replaced by the server's.
      def start
        # The writer pops only what the reader queued after accept set @client.
        @threads = [Thread.new { serve }, Thread.new { write_back }]
        self
      end

      # What the server has taken so far: its byte count and its MD5 in upper-case hex,
      # as the guest's binary:encode_hex/1 writes it.
      def received
        @lock.synchronize { { bytes: @received, md5: @digest.hexdigest.upcase } }
      end

      # Ends both threads, closes the sockets and returns the first error a thread met, or
      # nil. QEMU has exited or is about to, so the stream has nothing left to carry.
      def stop
        failed = @threads.each(&:kill).map(&:value).compact.first
        @client&.close
        @server.close unless @server.closed?
        failed
      end

      private

      def serve
        @client = @server.accept
        loop do
          data = @client.readpartial(READ_BYTES)
          @lock.synchronize do
            @digest << data
            @received += data.bytesize
          end
          return Error.new("the guest sent the echo server more than #{@limit} bytes") if received.fetch(:bytes) > @limit

          @queue << data
        end
      rescue EOFError
        nil
      rescue IOError, SystemCallError => e
        Error.new("the echo server could not read: #{e.message}")
      end

      def write_back
        loop do
          data = @queue.pop
          @client.write(data)
        end
      rescue IOError, SystemCallError => e
        Error.new("the echo server could not write: #{e.message}")
      end
    end
  end
end
