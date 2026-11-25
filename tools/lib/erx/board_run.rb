# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
require 'securerandom'
require 'time'
require_relative 'bench_record'
require_relative 'board_console'
require_relative 'board_files'
require_relative 'board_log'
require_relative 'board_walk'
require_relative 'boot_file'
require_relative 'boot_partition'
require_relative 'code_ssh'
require_relative 'error'
require_relative 'line_escape'
require_relative 'native_bench'
require_relative 'netboot'
require_relative 'netboot_entry'
require_relative 'output_directory'

module Erx
  # A board run's walk (docs/design-bench.md, "The walk"): `tools/erx bench NAME --env
  # pi4-4gb-erxos`'s effects around BoardWalk's decisions. Under the stager's lock it reads
  # the found target, refuses one that is a queue an earlier run left, prepares the queue,
  # writes queue.json beside the console's log, reads the sensors, points the link at the
  # queue, asks the board to reboot, walks the console's lines, and at the end points the
  # link back, removes the queue, writes walk.json, reads the sensors again and hands what
  # it has to the record's seam. The link is pointed back however the walk ends,
  # an interruption included. The found pair's identity, what the board returns to, is read
  # from the found target when it is a stage Netboot made (return_identity).
  #
  # Every byte of the board's that the run shows, from the console or from ssh, reaches
  # the output only through LineEscape; a boot name only selects an entry the host made.
  class BoardRun
    ENVIRONMENT = BenchRecord::Environment.new(kind: 'pi4', model: nil, cpus: 4, system: 'erxos', details: {}).name
    LOG = 'console.log'
    # What the walk types on the console when ssh cannot ask for the reboot.
    CONSOLE_REBOOT = "reboot\r"
    QUEUE_LEFT = 'the served link names a queue an earlier run left; stage a build first'
    # The boot deadline's starting value (docs/design-bench.md, "The walk", item 5).
    BOOT_SECONDS = 180
    # Between tries of the sensors' read after the return, while ssh does not answer.
    RETRY_SECONDS = 10

    # A set the walk boots: its boot set (Netboot::BootSet), the path of its build record,
    # the identity its banner names (BoardFiles::Identity, nil when unknown), the guest's
    # deadline its root is built with and the root's flags (nil when not known).
    Subject = Data.define(:set, :record, :identity, :deadline_seconds, :root_flags)
    # A sensors' reading, named for when it was read: the board's bytes, or nil when ssh did
    # not answer with them.
    Reading = Data.define(:taken, :text)
    # What the record's seam is handed: the run's directory (the log, queue.json and
    # walk.json), the queue, the walk, and the readings before and after.
    Ran = Data.define(:directory, :queue, :walk, :before, :after)

    # The subject of a set BoardSets laid out (NativeBench::BoardSets::Laid).
    def self.laid_subject(laid)
      Subject.new(set: Netboot.boot_set(File.dirname(laid.set.files), record: BootPartition::SET_RECORD),
                  record: laid.set.record,
                  identity: BoardFiles::Identity.new(build: laid.image.build_id, index: laid.image.index_hash),
                  deadline_seconds: laid.deadline_seconds, root_flags: laid.root_flags)
    end

    # The subject of a set's directory given by --set: its banner's identity and its root's
    # flags are not known here, and its root's deadline is taken as the landing form's.
    def self.directory_subject(directory)
      Subject.new(set: Netboot.boot_set(directory, record: BootPartition::SET_RECORD),
                  record: File.join(directory, BootPartition::SET_RECORD), identity: nil,
                  deadline_seconds: NativeBench::LANDING_DEADLINE_SECONDS, root_flags: nil)
    end

    # The ssh calls of a run: `ssh -o BatchMode=yes -T -- DEST reboot` and the read of
    # /proc/sensors/status, each an argument vector, never a shell line, within
    # DEADLINE_SECONDS. BatchMode makes ssh fail at once where it would ask for a password
    # or a host key's acceptance, which no one at the run answers.
    class Ssh
      DEADLINE_SECONDS = 30
      SENSORS = '/proc/sensors/status'
      # A reading larger than this is no reading.
      SENSOR_BYTES = 4096
      # ssh and its options, up to the destination.
      SSH = %w[ssh -o BatchMode=yes -T --].freeze

      def initialize(dest, spawn: Open3.method(:popen3), deadline: DEADLINE_SECONDS)
        @dest = CodeSsh.destination(dest)
        @spawn = spawn
        @deadline = deadline
      end

      def reboot_argv = [*SSH, @dest, 'reboot']
      def sensors_argv = [*SSH, @dest, 'cat', SENSORS]

      # Whether ssh ran the reboot.
      def reboot = run(reboot_argv).first

      # The sensors' bytes, or nil when ssh failed, did not answer or gave more than a reading.
      def sensors
        succeeded, output = run(sensors_argv)
        output if succeeded && output.bytesize <= SENSOR_BYTES
      end

      private

      # [whether argv succeeded within the deadline, its standard output's first bytes].
      def run(argv)
        @spawn.call(*argv) do |stdin, stdout, stderr, waiter|
          stdin.close
          reader = Thread.new { bounded(stdout) }
          Thread.new { bounded(stderr) }
          next [false, ''.b] unless waiter.join(@deadline)

          [waiter.value.success?, reader.value]
        ensure
          CodeSsh.stop(waiter) if waiter&.alive?
        end
      end

      # The stream's first SENSOR_BYTES + 1 bytes; the rest is read and dropped.
      def bounded(io)
        kept = io.read(SENSOR_BYTES + 1).to_s.b
        nil while io.read(BoardConsole::CHUNK)
        kept
      rescue IOError
        kept.to_s.b
      end
    end

    # root is the erXos tree, www the served link; shell answers reboot and sensors (Ssh);
    # prepare makes the queue as Netboot.prepare does, given its keywords but runner and
    # fsimg; console opens the console with a log path (BoardConsole.open); clock gives
    # monotonic seconds; pause sleeps; out takes the run's lines; record is the record's
    # seam, handed a Ran; codec is the ABI's (ABI::Codec), which reads a staged kernel8.img.
    def initialize(root:, www:, shell:, prepare:, console:, clock:, out:, record:, codec:, pause: Kernel.method(:sleep))
      @root = File.expand_path(root)
      @codec = codec
      @link = File.expand_path(www)
      @shell = shell
      @prepare = prepare
      @console = console
      @clock = clock
      @pause = pause
      @out = out
      @record = record
    end

    # Walks runs rounds of subjects, each round every subject in order, from the queue
    # signed with the key at key; returns the walk (BoardFiles::Walk).
    def call(benchmark:, subjects:, runs:, key:)
      raise Error, 'bench: --runs is below 1' unless runs.is_a?(Integer) && runs.positive?

      entries = Array.new(runs) { subjects }.flatten
      Netboot.locked(@link) do
        found = Netboot.found(@link)
        raise Error, "bench: #{QUEUE_LEFT}" if found.target && NetbootEntry.entries(found.target) > 1

        names = entries.map { SecureRandom.hex(16) }
        returning = return_identity(found)
        queue_path = @prepare.call(root: @link, sets: entries.map(&:set), names: names, key: key, found: found)
        directory, queue, state, interruption, restored = walked(benchmark, entries, names, returning, queue_path, found)
        walk = BoardWalk.walk(state, restored: restored)
        ended(directory, queue, walk)
        raise interruption if interruption

        walk
      end
    end

    private

    # Writes queue.json and walks the served queue; returns the run's directory, the queue,
    # the ended state, the interruption that ended it (or nil) and whether the link was
    # pointed back. The queue is removed, and the link pointed back once it was served,
    # whatever happens here.
    def walked(benchmark, entries, names, returning, queue_path, found)
      served = false
      restored = nil
      directory = run_directory(benchmark)
      queue = queue_of(benchmark, entries, names, returning, queue_path)
      BoardFiles.write_queue(directory, queue)
      state, interruption = served_walk(plan_of(entries, names, returning), directory, queue_path) { served = true }
      restored = point_back(found, queue_path)
      [directory, queue, state, interruption, restored]
    ensure
      if restored.nil?
        served ? point_back(found, queue_path) : remove(queue_path)
      end
    end

    # Opens the console, reads the sensors, serves the queue (yielding once it is served)
    # and walks; returns the ended state and the interruption that ended it, if one did.
    def served_walk(plan, directory, queue_path)
      console = @console.call(log: File.join(directory, LOG))
      begin
        @before = reading('before')
        Netboot.point(root: @link, target: queue_path)
        yield
        say("bench: #{LineEscape.escape(@link)} serves the queue of #{plan.names.size} entries; the log is #{File.join(directory, LOG)}")
        walk(plan, console)
      ensure
        console.close
      end
    end

    # Asks the board to reboot, then hands the console's events to BoardWalk until the walk
    # ends; a signal, from the reboot request on, is the walk's interruption, returned to be
    # raised once the link is back and walk.json written.
    def walk(plan, console)
      asked = reboot(console)
      state = BoardWalk.start(plan, at: @clock.call)
      state = BoardWalk.step(plan, state, BoardWalk::Stop.new(ending: 'console_closed', at: @clock.call)) unless asked

      until state.ended?
        console.read(state.deadline).each do |event|
          state = BoardWalk.step(plan, state, event)
          break if state.ended?
        end
      end
      say("bench: #{BoardWalk.said(plan, state)}")
      [state, nil]
    rescue SignalException => e
      [BoardWalk.step(plan, state || BoardWalk.start(plan, at: @clock.call), BoardWalk::Stop.new(ending: 'interrupted', at: @clock.call)), e]
    end

    # Asks the board to reboot over ssh, or, when ssh cannot, by typing reboot on the
    # console, as root's console session takes it; false when the console could not be
    # written, which leaves it closed for the walk.
    def reboot(console)
      return true if @shell.reboot

      typed = console.type(CONSOLE_REBOOT)
      say(typed ? 'bench: ssh could not ask the board to reboot; the walk typed reboot on its console; if the board does not restart, reset it by hand within the boot deadline' :
                  'bench: ssh could not ask the board to reboot, and the console could not be written; the walk ends with its console closed')
      typed
    end

    def ended(directory, queue, walk)
      BoardFiles.write_walk(directory, walk)
      after = %w[booted unexpected unknown].include?(walk.returned.status) ? reading_once_answered : Reading.new(taken: 'after', text: nil)
      @record.call(Ran.new(directory: directory, queue: queue, walk: walk, before: @before, after: after))
    end

    # Points the link back at the found target, or removes it when there was none, and
    # removes the queue; says what restores the link when that fails.
    def point_back(found, queue_path)
      Netboot.point(root: @link, target: found.target)
      remove(queue_path)
    rescue Error, SystemCallError => e
      restore = found.target ? ['ln', '-sfh', File.basename(found.target), @link] : ['rm', @link]
      say("bench: the link could not be pointed back at #{found.target || 'nothing'} (#{LineEscape.escape(e.message)}); " \
          "the queue is left in place; restore it with: #{Netboot.shell_line(restore)}")
      false
    end

    def remove(queue_path)
      FileUtils.rm_rf(queue_path)
      true
    end

    # A fresh directory for the run's files under the tree's build/bench-board, whose path
    # OutputDirectory checks, so a link on it cannot send the log elsewhere.
    def run_directory(benchmark)
      parent = OutputDirectory.prepare(root: @root, path: NativeBench::BoardSets::DIRECTORY)
      directory = File.join(parent, "#{benchmark}-walk-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(2)}")
      Dir.mkdir(directory, 0o755)
      directory
    end

    # The found pair's identity (docs/design-bench.md, "The walk", item 1): the build and
    # index hash of the kernel8.img a stage Netboot made boots, or nil, unknown, when the
    # found target is no such stage or its kernel8.img is no bootable file.
    def return_identity(found)
      kernel = Netboot.stage_kernel(found)
      return nil unless kernel

      header = BootFile.archive_header(codec: @codec, path: kernel)
      BoardFiles::Identity.new(build: header.fetch('build_id').unpack1('H*'), index: header.fetch('index_hash').unpack1('H*'))
    rescue Error => e
      say("bench: the found stage's #{BootPartition::KERNEL} names no build (#{LineEscape.escape(e.message)}); what the board returns to is unknown")
      nil
    end

    def queue_of(benchmark, entries, names, returning, queue_path)
      subjects = entries.uniq(&:record)
      records = subjects.map(&:record)
      BoardFiles::Queue.new(
        benchmark: benchmark, date: Time.now.utc.iso8601,
        sets: subjects.map do |subject|
          BoardFiles::BootSet.new(directory: File.dirname(subject.record), record_sha256: Digest::SHA256.file(subject.record).hexdigest,
                                  root_flags: subject.root_flags)
        end,
        entries: entries.zip(names).each.with_index(1).map do |(entry, name), position|
          BoardFiles::Entry.new(position: position, name: name, set: records.index(entry.record),
                                image_sha256: Digest::SHA256.file(File.join(queue_path, position.to_s, NetbootEntry::IMAGE)).hexdigest)
        end,
        return_identity: returning
      )
    end

    def plan_of(entries, names, returning)
      # One end deadline for the walk: the longest guest deadline of its sets, so a paired
      # walk's shorter set waits as long as the longer.
      guest = entries.map(&:deadline_seconds).max
      BoardWalk::Plan.new(names: names, identities: entries.map(&:identity), return_identity: returning,
                          deadlines: BoardWalk::Deadlines.new(boot_seconds: BOOT_SECONDS,
                                                              end_seconds: guest + NativeBench::DEADLINE_MARGIN_SECONDS,
                                                              return_seconds: BOOT_SECONDS),
                          byte_limit: BoardLog.boot_bytes(names.size))
    end

    def reading(taken) = reading_of(taken, @shell.sensors)

    # The reading after the return, tried until ssh answers or a boot deadline passes.
    def reading_once_answered
      give_up = @clock.call + BOOT_SECONDS
      loop do
        text = @shell.sensors
        return reading_of('after', text) if text || @clock.call >= give_up

        @pause.call(RETRY_SECONDS)
      end
    end

    def reading_of(taken, text)
      say("bench: sensors #{taken}: #{text ? '' : 'unknown'}")
      text&.each_line { |line| say("  #{LineEscape.escape(line.chomp)}") }
      Reading.new(taken: taken, text: text)
    end

    def say(line) = @out.call(line)
  end
end
