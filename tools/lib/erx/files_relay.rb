# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'socket'
require_relative 'error'
require_relative 'hostlink_client'
require_relative 'hostlink_frame'

module Erx
  # `tools/erx files` (docs/design-live.md, "Files between the host and the machine"):
  # relays a UNIX socket on the host to the host link's files stream, stream 4, so any
  # 9P2000.L client of the host mounts the machine's trees through it.
  #
  # Each client that connects gets a host-link session of its own, opened with a fresh
  # hello, so its 9P session starts clean and the target's bridge for the session
  # before it, with every fid it held, is gone. Clients are served one at a time. From
  # the client the relay checks each message's size field against the stream's msize,
  # one frame's body, and nothing more, and sends each whole message in one frame; a
  # size outside 7 to msize ends that client's connection. What the target sends is
  # written to the client as it arrives: the client parses the target's bytes as it
  # parses any server's.
  #
  # The listening socket must lie in a directory only its owner can enter, as the
  # harness's run directory is, and is made readable and writable by its owner only.
  class FilesRelay
    MSIZE = HostlinkFrame::BODY_MAX
    HEADER = 7
    READ_MAX = 65_536
    # How long the relay waits for either side before it looks again.
    POLL_SECONDS = 0.5

    # A client broke the 9P framing; its connection ends.
    class Framing < Error; end

    # Splits buffer into whole 9P messages: [messages, rest], or Framing for a size field
    # outside HEADER to MSIZE. Pure.
    def self.split(buffer)
      messages = []
      rest = buffer.b
      while rest.bytesize >= 4
        size = rest.unpack1('V')
        raise Framing, "a 9P message of #{size} bytes, outside #{HEADER} to #{MSIZE}" unless size.between?(HEADER, MSIZE)
        break if rest.bytesize < size

        messages << rest.byteslice(0, size)
        rest = rest.byteslice(size, rest.bytesize - size)
      end
      [messages, rest]
    end

    # Refuses a listening path whose directory others may enter, and a path that exists
    # and is not a stale socket of this user.
    def self.check_listen_path(path)
      directory = File.stat(File.dirname(File.expand_path(path)))
      raise Error, "#{File.dirname(path)} must be a directory only its owner can enter (mode 0700)" unless
        directory.directory? && directory.owned? && (directory.mode & 0o077).zero?
      return unless File.exist?(path) || File.symlink?(path)

      existing = File.lstat(path)
      raise Error, "#{path} exists and is not a socket of this user" unless existing.socket? && existing.owned?

      File.unlink(path)
    end

    # link is a HostlinkClient over the guest's host link; listen the path to serve on;
    # out prints a line.
    def initialize(link:, listen:, out:)
      @link = link
      @listen = listen
      @out = out
    end

    # Serves clients until connections have been served (forever when nil).
    def serve(connections: nil)
      FilesRelay.check_listen_path(@listen)
      server = UNIXServer.new(@listen)
      File.chmod(0o600, @listen)
      @out.call("files: serving the host link's files stream at #{@listen}")
      served = 0
      until connections && served >= connections
        client = server.accept
        begin
          relay(client)
        ensure
          client.close
        end
        served += 1
      end
    ensure
      server&.close
      File.unlink(@listen) if server && File.socket?(@listen)
    end

    # Relays one client in a session of its own until either side closes.
    def relay(client)
      @link.hello
      buffer = String.new(encoding: Encoding::BINARY)
      loop do
        ready, = IO.select([client, @link.io], nil, nil, POLL_SECONDS)
        if ready&.include?(client)
          bytes = client.read_nonblock(READ_MAX, exception: false)
          break if bytes.nil?

          buffer = forward(buffer + bytes) unless bytes == :wait_readable
        end
        @link.take_files(0).each { |body| client.write(body) }
      end
    rescue Framing, HostlinkClient::Timeout => e
      # A client that broke the framing, or whose messages the target gave no credit
      # for in time, loses its connection; the next client gets a session of its own.
      @out.call("files: #{e.message}; the client's connection ends")
    rescue Errno::EPIPE, Errno::ECONNRESET
      nil
    end

    private

    # Sends every whole message of buffer; returns what is left of it.
    def forward(buffer)
      messages, rest = FilesRelay.split(buffer)
      messages.each { |message| @link.send_files(message) }
      rest
    end
  end
end
