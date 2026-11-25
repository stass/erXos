# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'io/wait'
require_relative 'bench_measurement'
require_relative 'board_log'
require_relative 'board_walk'
require_relative 'error'
require_relative 'line_escape'

module Erx
  # The board's console for a walk (docs/design-bench.md, "The walk"): the device opened
  # once, held exclusively and set to 115,200 baud, every byte it gives appended to the log
  # as it is read, and each line, at most a BENCH line's 64 KiB and its end, handed to the
  # walk as a BoardWalk event. A line longer than that is cut there and never handed on; it
  # and the rest of it, to its newline, are handed on only as bytes, so the walk still holds
  # them to the boot's byte limit. At most one line's bytes are held between reads.
  #
  # Every byte is the board's and untrusted: the console only classifies lines
  # (BoardLog.classify) and counts them; it shows none.
  class BoardConsole
    BAUD = 115_200
    CHUNK = 4096

    # The console of device, its bytes appended to a new file at log; line sets the
    # device's line on its open IO (set_line, or a test's stand-in); clock gives the
    # monotonic seconds the events carry. A device that cannot be opened, or that another
    # run holds, is refused before anything is served.
    def self.open(device, log:, clock:, line: method(:set_line))
      io = begin
        File.open(device, File::RDONLY | File::NOCTTY | File::NONBLOCK | File::BINARY)
      rescue SystemCallError => e
        raise Error, "bench: the console #{LineEscape.escape(device)} cannot be opened: #{e.class.name.split('::').last}"
      end
      begin
        raise Error, "bench: another run holds the console #{LineEscape.escape(device)}" unless io.flock(File::LOCK_EX | File::LOCK_NB)

        line.call(io)
        new(io, log: File.open(log, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644), clock: clock)
      rescue StandardError
        io.close
        raise
      end
    end

    # 115,200 baud, raw, no echo, on the device open as io: stty acts on its standard input,
    # so the setting is made on the descriptor the run keeps open.
    def self.set_line(io)
      pid = Process.spawn('stty', BAUD.to_s, 'raw', '-echo', 'clocal', 'cread', in: io, out: File::NULL, err: File::NULL)
      Process.wait(pid)
      raise Error, "bench: stty could not set the console's line (exit status #{$?.exitstatus.inspect})" unless $?.success?
    end

    def initialize(io, log:, clock:, line_bytes: BenchMeasurement::LINE_BYTES)
      @io = io
      @log = log
      @clock = clock
      @line_bytes = line_bytes
      @partial = +''.b
      @cutting = false
      @offset = 0
    end

    # The events of the console's next read, waiting no later than until (the clock's
    # seconds): its whole lines and cut bytes, [Quiet] when nothing came by then, or
    # [Stop] when the console closed.
    def read(until_at)
      wait = until_at - @clock.call
      return [BoardWalk::Quiet.new(at: @clock.call)] unless wait.positive? && @io.wait_readable(wait)

      chunk = @io.read_nonblock(CHUNK, exception: false)
      return [] if chunk == :wait_readable
      return [BoardWalk::Stop.new(ending: 'console_closed', at: @clock.call)] if chunk.nil?

      @log.write(chunk)
      @log.flush
      events(chunk, at: @clock.call)
    rescue Errno::EIO, Errno::ENXIO, IOError
      [BoardWalk::Stop.new(ending: 'console_closed', at: @clock.call)]
    end

    def close
      @log.close unless @log.closed?
      @io.close unless @io.closed?
    end

    private

    # chunk's pieces, each ending at a newline but perhaps the last, as events.
    def events(chunk, at:)
      chunk.split(/(?<=\n)/n).filter_map { |piece| piece(piece, at: at) }
    end

    def piece(piece, at:)
      @offset += piece.bytesize
      whole = piece.end_with?("\n")
      return cut(piece.bytesize, whole: whole, at: at) if @cutting

      @partial << piece
      return line(at) if whole
      return nil if @partial.bytesize <= @line_bytes

      cut(@partial.bytesize, whole: false, at: at)
    end

    def line(at)
      raw = @partial
      @partial = +''.b
      text = raw.delete_suffix("\n")
      return BoardWalk::Bytes.new(bytes: raw.bytesize, at: at) if text.bytesize > @line_bytes

      BoardWalk::Line.new(kept: BoardLog.classify(text.sub(/\r+\z/n, ''), @offset), bytes: raw.bytesize, at: at)
    end

    # Bytes of a line past its limit: the walk counts them, and the line's rest, to its
    # newline, is cut too.
    def cut(bytes, whole:, at:)
      @partial = +''.b
      @cutting = !whole
      BoardWalk::Bytes.new(bytes: bytes, at: at)
    end
  end
end
