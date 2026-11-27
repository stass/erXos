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
  # sends eleven commands: qmp_capabilities, screendump (format ppm), input-send-event,
  # query-pci, eject, device_del, set_link, block_set_io_throttle, chardev-change,
  # chardev-remove and quit.
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

    # Takes the medium out of the drive QEMU names drive, forced, as a hand opens a reader's
    # tray; the device stays on its bus.
    def eject(drive)
      command('eject', { 'device' => drive, 'force' => true })
    end

    # Unplugs the device QEMU names id, as a hand pulls it out; the guest sees it leave.
    def device_del(id)
      command('device_del', { 'id' => id })
    end

    # Sets the link of the network device QEMU names name down or up, as a cable is pulled
    # or plugged; the guest sees its carrier follow where the device reports link status.
    def set_link(name, up:)
      raise ArgumentError, 'set_link takes up: true or false' unless [true, false].include?(up)

      command('set_link', { 'name' => name, 'up' => up })
    end

    # Moves the character device QEMU names id to another backend: with no unix_socket, the
    # null backend, which reads nothing and drops what it is written; with one, a client of
    # the UNIX socket there, which must be in the connection's own directory, so no change
    # reaches a file or socket outside it.
    def chardev_change(id, unix_socket: nil)
      backend = if unix_socket
                  check_own_path(unix_socket, 'a chardev socket')
                  { 'type' => 'socket', 'data' => { 'addr' => { 'type' => 'unix', 'data' => { 'path' => unix_socket } },
                                                    'server' => false } }
                else
                  { 'type' => 'null', 'data' => {} }
                end
      command('chardev-change', { 'id' => id, 'backend' => backend })
    end

    # Removes the character device QEMU names id.
    def chardev_remove(id)
      command('chardev-remove', { 'id' => id })
    end

    # Limits the reads of the block device QEMU names id (its -device id) to bps_rd bytes a
    # second, every other limit off; bps_rd 0 takes every limit off. A limit of 1 holds every
    # read after the first, which the throttle lets through, for longer than any run.
    def block_set_io_throttle(id, bps_rd:)
      raise ArgumentError, 'block_set_io_throttle takes bps_rd: a count of bytes' unless bps_rd.is_a?(Integer) && bps_rd >= 0

      limits = %w[bps bps_wr iops iops_rd iops_wr].to_h { |name| [name, 0] }
      command('block_set_io_throttle', { 'id' => id, 'bps_rd' => bps_rd, **limits })
    end

    # One PCI function as QEMU holds it (query-pci): its place on its bus, its identity, and
    # its BARs, each a PciRegion.
    PciFunction = Data.define(:bus, :slot, :function, :vendor, :device, :regions)
    # One BAR of a function: its index, :memory or :io, and its address, nil while QEMU maps
    # it nowhere (query-pci's -1), and size.
    PciRegion = Data.define(:bar, :type, :address, :size)
    # The query-pci answer's bounds: QEMU's root bus and every bus behind it, 32 slots of 8
    # functions, 6 BARs and the expansion ROM's region.
    MAX_PCI_BUSES = 256
    MAX_PCI_FUNCTIONS = 256
    MAX_PCI_REGIONS = 7

    # Every function on every bus QEMU's query-pci lists, as PciFunction values in its order,
    # each field checked against its type and bounds as QEMU 11.1.3 answers; any other shape
    # is a ProtocolError that quotes nothing of it. A function behind a bridge, which QEMU
    # nests in its bridge's entry, is not read: the answer nests past MAX_NESTING.
    def pci_functions
      buses = command('query-pci')
      raise ProtocolError, 'QEMU answered query-pci with no list of buses' unless list_within?(buses, MAX_PCI_BUSES)

      functions = buses.flat_map do |bus|
        devices = bus.is_a?(Hash) && bus['devices']
        raise ProtocolError, 'QEMU answered query-pci with a bus without its devices' unless list_within?(devices, MAX_PCI_FUNCTIONS)

        devices.map { |device| pci_function(device) }
      end
      raise ProtocolError, "QEMU listed more than #{MAX_PCI_FUNCTIONS} PCI functions" if functions.size > MAX_PCI_FUNCTIONS

      functions
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

    def list_within?(value, limit) = value.is_a?(Array) && value.size <= limit

    def integer_within?(value, range) = value.is_a?(Integer) && range.cover?(value)

    # One query-pci device as a PciFunction.
    def pci_function(device)
      id = device.is_a?(Hash) && device['id']
      regions = device.is_a?(Hash) && device['regions']
      valid = id.is_a?(Hash) && integer_within?(device['bus'], 0..255) && integer_within?(device['slot'], 0..31) &&
              integer_within?(device['function'], 0..7) && integer_within?(id['vendor'], 0..0xffff) &&
              integer_within?(id['device'], 0..0xffff) && list_within?(regions, MAX_PCI_REGIONS)
      raise ProtocolError, 'QEMU answered query-pci with a malformed device' unless valid

      PciFunction.new(bus: device['bus'], slot: device['slot'], function: device['function'], vendor: id['vendor'],
                      device: id['device'], regions: regions.map { |region| pci_region(region) }.freeze)
    end

    # One query-pci region as a PciRegion: its address -1, QEMU's "mapped nowhere", is nil.
    def pci_region(region)
      valid = region.is_a?(Hash) && integer_within?(region['bar'], 0..6) && %w[memory io].include?(region['type']) &&
              integer_within?(region['size'], 1..((1 << 64) - 1)) &&
              (region['address'] == -1 || integer_within?(region['address'], 0..((1 << 64) - 1)))
      raise ProtocolError, 'QEMU answered query-pci with a malformed region' unless valid

      PciRegion.new(bar: region['bar'], type: region['type'].to_sym, address: region['address'] == -1 ? nil : region['address'],
                    size: region['size'])
    end

    def check_dump_path(path) = check_own_path(path, 'a screendump path')

    # path names a file in the connection's own directory, the owner-only one the socket is in.
    def check_own_path(path, what)
      valid = path.is_a?(String) && path.start_with?('/') && !path.include?("\0") && File.dirname(path) == @directory
      raise ProtocolError, "#{what} is a file in #{@directory}" unless valid
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
