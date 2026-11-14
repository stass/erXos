# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'socket'
require_relative 'error'
require_relative 'json_input'
require_relative 'line_escape'
require_relative 'ppm'

module Erx
  # The harness's end of QEMU's machine protocol (QMP) on a UNIX socket QEMU listens on
  # (QemuPlan::Display): one JSON object per line, a greeting, a capabilities command, then
  # commands answered in order with a reply or an error, among events the client skips. It
  # sends four commands: qmp_capabilities, screendump (format ppm), input-send-event and quit.
  #
  # QEMU is the peer, and what it says is untrusted all the same: every read is bounded
  # (MAX_LINE_BYTES a line, MAX_SKIPPED_EVENTS events between a command and its reply, one
  # deadline per command), JSON nests at most MAX_NESTING deep, a reply carries the id of the
  # command it answers, and text QEMU sends reaches a message only through LineEscape.
  # Not thread-safe: one thread drives a connection.
  class Qmp
    # QEMU did not answer as QMP does, or answered with an error, or its end closed.
    class ProtocolError < Error; end
    # A deadline passed with no answer.
    class Timeout < Error; end
    # The socket or its directory is not the caller's own, or is not a socket.
    class Untrusted < Error; end
    # The connection closed, so nothing more will come.
    class ConnectionClosed < ProtocolError; end

    MAX_LINE_BYTES = 65_536
    MAX_SKIPPED_EVENTS = 64
    MAX_NESTING = 8
    # QEMU creates the socket a moment after it starts; connecting retries this often.
    CONNECT_RETRY_SECONDS = 0.05

    # Connects to the socket at path, which QEMU listens on, within timeout seconds, and
    # completes the capabilities handshake. The socket's directory must be the caller's own
    # and closed to others (mode 0700, as OutputDirectory makes it) and the socket the
    # caller's own, else Untrusted: the directory's mode is what keeps another user off the
    # socket and out of the files screendump writes beside it.
    def self.connect(path, timeout: 10)
      check_directory(path)
      deadline = monotonic + timeout
      socket = open_socket(path, deadline)
      client = new(socket, directory: File.dirname(path), timeout: timeout)
      client.handshake(deadline: deadline)
      client
    rescue StandardError
      socket&.close
      raise
    end

    # The directory of the socket path is the caller's own and closed to others, else Untrusted.
    # QemuPlan checks it before QEMU starts to listen, as well as the client when it connects.
    def self.check_directory(path)
      raise Untrusted, 'a QMP socket path is absolute and holds no NUL' unless
        path.is_a?(String) && path.start_with?('/') && !path.include?("\0")

      directory = File.lstat(File.dirname(path))
      unless directory.directory? && directory.uid == Process.uid && (directory.mode & 0o077).zero?
        raise Untrusted, "the directory of #{path} is not a directory only the caller can read"
      end
    rescue SystemCallError => e
      raise Untrusted, "cannot check #{path}: #{e.class.name.split('::').last}"
    end

    def self.open_socket(path, deadline)
      loop do
        begin
          stat = File.lstat(path)
          raise Untrusted, "#{path} is not a socket of the caller's" unless stat.socket? && stat.uid == Process.uid

          return UNIXSocket.new(path)
        rescue Errno::ENOENT, Errno::ECONNREFUSED
          raise Timeout, "QEMU's QMP socket #{path} never came up" if monotonic >= deadline

          sleep CONNECT_RETRY_SECONDS
        rescue SystemCallError => e
          raise ProtocolError, "cannot connect to #{path}: #{e.class.name.split('::').last}"
        end
      end
    end
    private_class_method :open_socket

    def self.monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # socket is a connected stream whose path was in directory; timeout the seconds any one
    # command may take.
    def initialize(socket, directory:, timeout: 10)
      @socket = socket
      @directory = directory
      @timeout = timeout
      @buffer = String.new(encoding: Encoding::BINARY)
      @next_id = 0
    end

    # Reads the greeting and enables commands, within the deadline (a Qmp.monotonic time).
    def handshake(deadline: Qmp.monotonic + @timeout)
      greeting = read_object(deadline: deadline)
      raise ProtocolError, 'QEMU sent no QMP greeting' unless greeting.is_a?(Hash) && greeting['QMP'].is_a?(Hash)

      command('qmp_capabilities', deadline: deadline)
      self
    end

    # The guest's display as a Ppm::Image. QEMU writes a PPM to path, which must be a file in
    # the connection's own directory (the owner-only one the socket is in): QEMU follows links
    # and creates the file with the umask's permissions, so nowhere else is safe. A stale file
    # at path is removed first; the file is decoded within the picture limits and deleted.
    def screendump_image(path)
      check_dump_path(path)
      dump(path)
    end

    # Sends events, an array of QMP InputEvent objects, to the guest's input devices as one
    # batch, which QEMU ends with a report: key events go to the keyboard, absolute ones to
    # the tablet.
    def input_events(events)
      command('input-send-event', { 'events' => events })
    end

    # Ends QEMU's machine. QEMU may close the connection before or after the reply.
    def quit
      command('quit')
    rescue ConnectionClosed
      nil
    ensure
      close
    end

    def close
      @socket.close unless @socket.closed?
    end

    private

    def check_dump_path(path)
      valid = path.is_a?(String) && path.start_with?('/') && !path.include?("\0") && File.dirname(path) == @directory
      raise ProtocolError, "a screendump path is a file in #{@directory}" unless valid
    end

    # path has been checked: the ensure deletes only what this call may have made.
    def dump(path)
      File.unlink(path) if File.exist?(path) || File.symlink?(path)
      command('screendump', { 'filename' => path, 'format' => 'ppm' })
      Ppm.read_file(path)
    ensure
      File.unlink(path) if File.file?(path) && !File.symlink?(path)
    end

    # Runs a command and returns its reply's value, skipping events; an error reply raises.
    def command(name, arguments = nil, deadline: Qmp.monotonic + @timeout)
      @next_id += 1
      request = { 'execute' => name, 'id' => @next_id }
      request['arguments'] = arguments if arguments
      write_line(JSON.generate(request))
      MAX_SKIPPED_EVENTS.succ.times do
        reply = read_object(deadline: deadline)
        next if reply.key?('event')

        unless reply['id'] == @next_id
          raise ProtocolError, "QEMU answered command #{@next_id} with id #{LineEscape.escape(reply['id'].inspect.byteslice(0, 40))}"
        end

        return reply['return'] if reply.key?('return')
        raise ProtocolError, "QEMU refused #{name}: #{error_text(reply['error'])}" if reply.key?('error')

        raise ProtocolError, 'QEMU sent a reply that is neither a return nor an error'
      end
      raise ProtocolError, "QEMU sent more than #{MAX_SKIPPED_EVENTS} events before its reply"
    end

    def error_text(error)
      text = error.is_a?(Hash) ? "#{error['class']}: #{error['desc']}" : error.inspect
      LineEscape.escape(text.to_s.byteslice(0, 200))
    end

    def write_line(line)
      @socket.write("#{line}\n")
    rescue SystemCallError, IOError => e
      raise ConnectionClosed, "QEMU's QMP connection closed on write (#{e.class.name.split('::').last})"
    end

    # The next line as a JSON object, within the line and nesting bounds and the deadline.
    def read_object(deadline:)
      object = parse_line(read_line(deadline))
      raise ProtocolError, 'QEMU sent a QMP line that is not an object' unless object.is_a?(Hash)

      object
    end

    # JsonInput refuses malformed JSON, duplicate keys and invalid UTF-8 without quoting the line.
    def parse_line(line)
      JsonInput.parse(line, max_bytes: MAX_LINE_BYTES, max_nesting: MAX_NESTING, label: 'QMP line')
    rescue JsonInput::Unsupported
      raise
    rescue Erx::Error
      raise ProtocolError, 'QEMU sent a QMP line that is not JSON'
    end

    def read_line(deadline)
      loop do
        newline = @buffer.index("\n")
        too_long = (newline || @buffer.bytesize) > MAX_LINE_BYTES
        raise ProtocolError, "QEMU sent a QMP line longer than #{MAX_LINE_BYTES} bytes" if too_long
        return @buffer.slice!(0, newline + 1).chomp.force_encoding(Encoding::UTF_8) if newline

        remaining = deadline - Qmp.monotonic
        raise Timeout, 'QEMU did not answer within the deadline' unless remaining.positive? && @socket.wait_readable(remaining)

        chunk = @socket.read_nonblock(MAX_LINE_BYTES, exception: false)
        raise ConnectionClosed, "QEMU's QMP connection closed" if chunk.nil?

        @buffer << chunk unless chunk == :wait_readable
      end
    rescue SystemCallError, IOError => e
      raise ConnectionClosed, "QEMU's QMP connection closed (#{e.class.name.split('::').last})"
    end
  end
end
