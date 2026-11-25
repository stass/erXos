# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
require 'securerandom'
require_relative 'bench_record'
require_relative 'board_console'
require_relative 'board_files'
require_relative 'board_walk'
require_relative 'code_ssh'
require_relative 'error'
require_relative 'line_escape'
require_relative 'native_bench'
require_relative 'netboot'
require_relative 'netboot_entry'

module Erx
  # A board run's walk (docs/design-bench.md, "The walk"): `tools/erx bench NAME --env
  # pi4-4gb-erxos`'s effects around BoardWalk's decisions. Under the stager's lock it reads
  # the found target, refuses one that is a queue an earlier run left, prepares the queue,
  # writes queue.json beside the console's log, reads the sensors, points the link at the
  # queue, asks the board to reboot, walks the console's lines, and at the end points the
  # link back, removes the queue, writes walk.json, reads the sensors again and hands what
  # it has to the record's seam. The link is pointed back however the walk ends,
  # an interruption included.
  #
  # Every byte of the board's that the run shows, from the console or from ssh, reaches
  # the output only through LineEscape; a boot name only selects an entry the host made.
  class BoardRun
    ENVIRONMENT = BenchRecord::Environment.new(kind: 'pi4', model: nil, cpus: 4, system: 'erxos', details: {}).name
    LOG = 'console.log'
    QUEUE_LEFT = 'the served link names a queue an earlier run left; stage a build first'
    # The boot deadline's starting value (docs/design-bench.md, "The walk", item 5).
    BOOT_SECONDS = 180
    # Between tries of the sensors' read after the return, while ssh does not answer.
    RETRY_SECONDS = 10

    # A set the walk boots: its boot set (Netboot::BootSet), the path of its build record,
    # the identity its banner names (BoardFiles::Identity, nil when unknown) and the guest's
    # deadline its root is built with.
    Subject = Data.define(:set, :record, :identity, :deadline_seconds)
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
                  deadline_seconds: laid.deadline_seconds)
    end

    # The subject of a set's directory given by --set: its banner's identity is not known
    # here, and its root's deadline is taken as the landing form's.
    def self.directory_subject(directory)
      Subject.new(set: Netboot.boot_set(directory, record: BootPartition::SET_RECORD),
                  record: File.join(directory, BootPartition::SET_RECORD), identity: nil,
                  deadline_seconds: NativeBench::LANDING_DEADLINE_SECONDS)
    end

    # The ssh calls of a run: `ssh -T -- DEST reboot` and the read of /proc/sensors/status,
    # each an argument vector, never a shell line, within DEADLINE_SECONDS.
    class Ssh
      DEADLINE_SECONDS = 30
      SENSORS = '/proc/sensors/status'
      # A reading larger than this is no reading.
      SENSOR_BYTES = 4096

      def initialize(dest, spawn: Open3.method(:popen3), deadline: DEADLINE_SECONDS)
        @dest = CodeSsh.destination(dest)
        @spawn = spawn
        @deadline = deadline
      end

      def reboot_argv = ['ssh', '-T', '--', @dest, 'reboot']
      def sensors_argv = ['ssh', '-T', '--', @dest, 'cat', SENSORS]

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
    # seam, handed a Ran.
    def initialize(root:, www:, shell:, prepare:, console:, clock:, out:, record:, pause: Kernel.method(:sleep))
      @root = File.expand_path(root)
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
        queue_path = @prepare.call(root: @link, sets: entries.map(&:set), names: names, key: key, found: found)
        directory, queue, state, interruption, restored = walked(benchmark, entries, names, queue_path, found)
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
    def walked(benchmark, entries, names, queue_path, found)
      served = false
      restored = nil
      directory = run_directory(benchmark)
      queue = queue_of(benchmark, entries, names, queue_path)
      BoardFiles.write_queue(directory, queue)
      state, interruption = served_walk(plan_of(entries, names), directory, queue_path) { served = true }
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
        unless @shell.reboot
          say('bench: ssh could not ask the board to reboot; reset it by hand, and the walk waits the boot deadline')
        end
        walk(plan, console)
      ensure
        console.close
      end
    end

    # The console's events through BoardWalk until the walk ends; a signal is the walk's
    # interruption, returned to be raised once the link is back and walk.json written.
    def walk(plan, console)
      state = BoardWalk.start(plan, at: @clock.call)
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

    def run_directory(benchmark)
      parent = File.join(@root, NativeBench::BoardSets::DIRECTORY)
      FileUtils.mkdir_p(parent)
      directory = File.join(parent, "#{benchmark}-walk-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(2)}")
      Dir.mkdir(directory, 0o755)
      directory
    end

    def queue_of(benchmark, entries, names, queue_path)
      records = entries.map(&:record).uniq
      BoardFiles::Queue.new(
        benchmark: benchmark,
        sets: records.map { |record| BoardFiles::BootSet.new(directory: File.dirname(record), record_sha256: Digest::SHA256.file(record).hexdigest) },
        entries: entries.zip(names).each.with_index(1).map do |(entry, name), position|
          BoardFiles::Entry.new(position: position, name: name, set: records.index(entry.record),
                                image_sha256: Digest::SHA256.file(File.join(queue_path, position.to_s, NetbootEntry::IMAGE)).hexdigest)
        end,
        # The found pair's identity is read only from a stage Netboot made; no reader of a
        # staged kernel8.img's banner identity exists yet, so the return is unknown.
        return_identity: nil
      )
    end

    def plan_of(entries, names)
      guest = entries.map(&:deadline_seconds).max
      BoardWalk::Plan.new(names: names, identities: entries.map(&:identity), return_identity: nil,
                          deadlines: BoardWalk::Deadlines.new(boot_seconds: BOOT_SECONDS,
                                                              end_seconds: guest + NativeBench::DEADLINE_MARGIN_SECONDS,
                                                              return_seconds: BOOT_SECONDS),
                          byte_limit: BenchRecord::LOG_BYTES)
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
