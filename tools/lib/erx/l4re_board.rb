# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'securerandom'
require 'time'
require_relative 'bench_record'
require_relative 'bench_session'
require_relative 'bench_side_by_side'
require_relative 'bench_suite'
require_relative 'board_clock'
require_relative 'board_record'
require_relative 'board_run'
require_relative 'board_walk'
require_relative 'boot_partition'
require_relative 'bounded_file'
require_relative 'error'
require_relative 'ipcbench'
require_relative 'json_input'
require_relative 'l4re_bench'
require_relative 'line_escape'
require_relative 'native_bench'
require_relative 'netboot'
require_relative 'netboot_entry'
require_relative 'output_directory'

module Erx
  # L4Re on the Raspberry Pi 4 (docs/design-bench.md, "L4Re on the board"). The board
  # build's bootstrap.raw is laid out as a bench set whose device tree keeps one CPU, and
  # netbooted as a queue of one entry with the found target as the way back. The run asks
  # the board to reboot, reads the console to `Benchmarks done.` or the run's deadline,
  # types the kernel debugger's reboot (ESC, ^, Return), and waits for erXos's banner from
  # the way back; the link is pointed back at the found target however the run ends. The
  # run's log is imported as a record of environment pi4-4gb-l4re, its cells through
  # L4Re's importer (Ipcbench), and set beside erXos's newest board record of the
  # benchmark.
  #
  # Every byte of the board's is untrusted: lines are only classified, and what the run
  # shows of them goes through LineEscape.
  module L4ReBoard
    ENVIRONMENT = BenchRecord::Environment.new(kind: 'pi4', model: nil, cpus: 1, system: 'l4re', details: {}).name
    # The board build's output (L4ReBuild::TARGETS).
    BUILD = 'build/l4re-raspi4b'
    BOOTABLE = 'bootstrap.raw'
    SETS = File.join(NativeBench::BoardSets::DIRECTORY, 'l4re')
    LOG = 'console.log'
    # From the reboot request to `Benchmarks done.`.
    DONE_SECONDS = L4ReBench::DONE.fetch(:seconds)
    # From the debugger's reboot to erXos's banner.
    RETURN_SECONDS = BoardRun::BOOT_SECONDS
    # Fiasco's kernel debugger's reboot, key by key: ESC enters the debugger from the
    # console, ^ asks for the reboot, and Return confirms it (the debugger answers ^ with
    # `Return reboots, "k" enters L4 kernel debugger...`). The pause before each key after
    # the first lets the debugger take the one before.
    DEBUGGER_REBOOT = ["\e", '^', "\r"].freeze
    TYPE_PAUSE_SECONDS = 1
    # A line Fiasco prints for each CPU it starts: the boot CPU's identification
    # registers, or a further CPU that has the boot CPU's.
    STARTED_CPU = /\ACPU(?<cpu>\d{1,4})(?:: ID_PFR| booted \(same IDs as CPU)/n
    NOT_RETURNED = 'the board did not come back from L4Re by the deadline: reset it by hand (a power cycle); ' \
                   'the link names the found target again, so it comes back on it'

    # The run's state: its phase (:running to the done line, :returning to the banner), the
    # phase's deadline in the clock's seconds, whether the done line came, and how the run
    # ended (nil while it runs).
    State = Data.define(:phase, :deadline, :done, :ending) do
      def ended? = !ending.nil?
    end
    # What a run left: its directory and log, whether `Benchmarks done.` came, and how it
    # ended: returned, not_returned, or the console's or a signal's ending.
    Ran = Data.define(:directory, :log, :done, :ending)

    module_function

    # What the run keeps of a console line: :done, :banner (erXos's), or nil.
    def classify(text, _stop)
      if L4ReBench::DONE.fetch(:pattern).match?(text) then :done
      elsif BoardLog::BANNER.match?(text) then :banner
      end
    end

    def start(at:) = State.new(phase: :running, deadline: at + DONE_SECONDS, done: false, ending: nil)

    # The next state after event (a BoardWalk event whose lines carry classify's value)
    # and the action it asks for: :reboot when the debugger's reboot is to be typed, else
    # nil. The run's deadline types the reboot too, since the debugger may still answer
    # when ipcbench has not finished. erXos's banner before the done line means the queue's
    # entry did not boot L4Re: the run ends there, typing nothing into erXos. Pure.
    def step(state, event)
      case [state.phase, event]
      in [_, BoardWalk::Stop] then [state.with(ending: event.ending), nil]
      in [:running, BoardWalk::Line] if event.kept == :done then [returning(state, event.at, done: true), :reboot]
      in [:running, BoardWalk::Line] if event.kept == :banner then [state.with(ending: 'no_l4re'), nil]
      in [:running, _] if event.at >= state.deadline then [returning(state, event.at, done: false), :reboot]
      in [:returning, BoardWalk::Line] if event.kept == :banner then [state.with(ending: 'returned'), nil]
      in [:returning, _] if event.at >= state.deadline then [state.with(ending: 'not_returned'), nil]
      else [state, nil]
      end
    end

    def returning(state, at, done:) = state.with(phase: :returning, deadline: at + RETURN_SECONDS, done: done)

    # The lines of L4Re's run: the log's up to its first done line, which the run's log
    # runs past to erXos's return boot and its own CPUs; all of them when none is done.
    def run_lines(lines)
      done = lines.index { |line| L4ReBench::DONE.fetch(:pattern).match?(line) }
      done ? lines.first(done + 1) : lines
    end

    # The CPUs lines say Fiasco started, in order.
    def started_cpus(lines) = lines.filter_map { |line| STARTED_CPU.match(line.b)&.[](:cpu)&.to_i }.uniq.sort

    # The cells of benchmark L4Re's board run asks: the landing cells with an l4re
    # counterpart, as a session asks them.
    def asked(benchmark) = BenchSuite::BOOTS.keys.flat_map { |boot| BenchSession.cells(benchmark, boot, 'l4re') }

    # Lays bootstrap.raw out as a bench set whose tree keeps one CPU, in a fresh
    # directory under build/bench-board/l4re; answers its boot set (Netboot::BootSet).
    def lay_out(root:, runner:, platform:, compiler:, linker:)
      build = L4ReBench::Build.new(directory: File.join(root, BUILD), bootable: BOOTABLE)
      raise Error, "bench: L4Re's board run needs #{build.bootstrap} and its build record: tools/erx build l4re --platform raspi4b" unless
        build.built?

      build.record
      directory = OutputDirectory.fresh(root: root, path: File.join(root, SETS))
      set = BootPartition.lay_out_set(root: root, runner: runner, platform: platform, build_kind: BuildKind::DEVELOPMENT,
                                      bootable: build.bootstrap, directory: directory, compiler: compiler, linker: linker,
                                      boot_cpu_only: true)
      Netboot.boot_set(File.dirname(set.files), record: BootPartition::SET_RECORD)
    end

    # The record of L4Re's board run of benchmark name from its console log and the build
    # record at subject, written under history, with arm_clock_hz, the ARM clock the board's
    # cards held (BoardClock); answers [the run directory, the record].
    # revision is the harness's (SourceRevision::Revision). A log in which Fiasco started
    # more than one CPU is refused: ipcbench's threads have a known placement only on one.
    def import(name, subject:, log:, root:, history:, revision:, arm_clock_hz:)
      benchmark = BenchSuite.benchmark(name)
      bytes = BoundedFile.read(log, maximum: BenchRecord::LOG_BYTES)
      lines = run_lines(bytes.split(/\r?\n/n))
      cpus = started_cpus(lines)
      raise Error, "bench import: #{log} shows Fiasco starting CPUs #{cpus.join(', ')}; only a one-CPU boot is imported" if
        cpus.size > 1

      answer = Ipcbench.import(lines, benchmark: name, cells: asked(benchmark))
      record = BenchRecord::Record.new(
        environment: BenchRecord::Environment.new(kind: 'pi4', model: nil, cpus: 1, system: 'l4re',
                                                  details: { 'memory_mib' => BoardRecord::MEMORY_MIB }),
        subject: BenchRecord::Subject.new(revision: revision.commit, dirty: revision.dirty, details: subject_record(subject)),
        run: BenchRecord::Run.new(date: File.mtime(log).utc, started_by: 'manual', load: nil, host_cpus: nil, reused_from: nil,
                                  details: { BoardClock::KEY => arm_clock_hz, 'refused' => answer.fetch(:refused) }),
        boots: [BenchRecord::Boot.new(position: 1, clock: nil, cells: answer.fetch(:cells), details: {})]
      )
      [BenchRecord.write(record, history: history, erxos_root: root, logs: [{ serial: bytes }]), record]
    end

    # The build record at path: a JSON object of printable ASCII, as L4ReBench::Build reads it.
    def subject_record(path)
      value = JsonInput.parse(BoundedFile.read(path, maximum: 1 << 20), max_bytes: 1 << 20, label: path)
      raise Error, "#{path} is not a JSON object of printable ASCII" unless BenchRecord.plain_hash?(value) && L4ReBench.printable?(value)

      value
    end

    # The board's side-by-side table of benchmark: record beside erXos's newest board
    # record of it under history, as lines for the terminal (escaped at its sink).
    def table(benchmark, record, history:)
      runs = [newest_erxos(benchmark.name, history: history), record].compact
                                                                     .map { |each| BenchSideBySide::Run.new(round: 0, record: each) }
      BenchSideBySide.render(BenchSideBySide.tables(benchmark, runs, systems: %w[erxos l4re], forms: false))
    end

    # erXos's newest board record of benchmark name under history, or nil.
    def newest_erxos(name, history:)
      directory = File.join(history, 'bench', BoardRun::ENVIRONMENT)
      return nil unless File.directory?(directory)

      Dir.children(directory).sort.reverse_each do |run|
        next unless File.file?(File.join(directory, run, BenchRecord::MANIFEST))

        record = BenchRecord.read(File.join(directory, run))
        return record if record.boots.any? { |boot| boot.cells.any? { |cell| cell.benchmark == name } }
      end
      nil
    end

    # L4Re's board run: effects around step. www is the served link; shell asks the board
    # to reboot (BoardRun::Ssh); prepare makes the queue as Netboot.prepare does, given its
    # keywords but runner and fsimg; console opens the console with a log path and the
    # classifier (BoardConsole.open); clock gives monotonic seconds; pause sleeps; out
    # takes the run's lines.
    class Run
      def initialize(root:, www:, shell:, prepare:, console:, clock:, out:, pause: Kernel.method(:sleep))
        @root = File.expand_path(root)
        @link = File.expand_path(www)
        @shell = shell
        @prepare = prepare
        @console = console
        @clock = clock
        @out = out
        @pause = pause
      end

      # Runs set, the boot set lay_out answered, signed with the key at key; answers Ran.
      def call(set:, key:)
        Netboot.locked(@link) do
          found = Netboot.found(@link)
          raise Error, "bench: #{BoardRun::QUEUE_LEFT}" if found.target && NetbootEntry.entries(found.target) > 1

          queue = @prepare.call(root: @link, sets: [set], names: [SecureRandom.hex(16)], key: key, found: found)
          begin
            served(queue)
          ensure
            point_back(found, queue)
          end
        end
      end

      private

      def served(queue)
        directory = run_directory
        log = File.join(directory, LOG)
        console = @console.call(log: log, classify: L4ReBoard.method(:classify))
        begin
          Netboot.point(root: @link, target: queue)
          say("bench: #{LineEscape.escape(@link)} serves L4Re's queue; the log is #{log}")
          state = walk(console)
        ensure
          console.close
        end
        say("bench: #{said(state)}")
        Ran.new(directory: directory, log: log, done: state.done, ending: state.ending)
      end

      # Asks erXos to reboot into the queue, then steps the console's events until the run
      # ends. A console that cannot be written ends the run as closed: neither reboot could
      # be asked through it.
      def walk(console)
        state = L4ReBoard.start(at: @clock.call)
        state = closed(state) unless ask_reboot(console)
        until state.ended?
          console.read(state.deadline).each do |event|
            state, action = L4ReBoard.step(state, event)
            state = closed(state) if action == :reboot && !debugger_reboot(console)
            break if state.ended?
          end
        end
        state
      end

      def closed(state) = L4ReBoard.step(state, BoardWalk::Stop.new(ending: 'console_closed', at: @clock.call)).first

      # Asks erXos over ssh, or, when ssh cannot, types reboot on the console, as root's
      # console session takes it (BoardRun#reboot); whether either could be asked.
      def ask_reboot(console)
        return true if @shell.reboot

        typed = console.type(BoardRun::CONSOLE_REBOOT)
        say(typed ? 'bench: ssh could not ask the board to reboot; the run typed reboot on its console' :
                    'bench: ssh could not ask the board to reboot, and the console could not be written')
        typed
      end

      # Types the kernel debugger's reboot (DEBUGGER_REBOOT), stopping at the first key
      # that cannot be written; whether every key was.
      def debugger_reboot(console)
        say("bench: typing the kernel debugger's reboot (ESC, ^, Return)")
        DEBUGGER_REBOOT.each_with_index.all? do |key, index|
          @pause.call(TYPE_PAUSE_SECONDS) if index.positive?
          console.type(key)
        end
      end

      def said(state)
        done = state.done ? 'Benchmarks done.' : 'no Benchmarks done. by the deadline'
        case state.ending
        when 'returned' then "#{done}; erXos's banner came from the way back"
        when 'not_returned' then "#{done}; #{NOT_RETURNED}"
        when 'no_l4re' then "#{done}; erXos's banner came before L4Re ran: the queue's entry did not boot, and nothing was typed"
        else "#{done}; the run ended: #{state.ending}; if the board is in L4Re, ESC then ^ on its console reboots it, or a power cycle"
        end
      end

      # Points the link back at the found target, or removes it when there was none, and
      # removes the queue; says what restores the link when that fails.
      def point_back(found, queue)
        Netboot.point(root: @link, target: found.target)
        FileUtils.rm_rf(queue)
      rescue Error, SystemCallError => e
        restore = found.target ? ['ln', '-sfh', File.basename(found.target), @link] : ['rm', @link]
        say("bench: the link could not be pointed back (#{LineEscape.escape(e.message)}); restore it with: #{Netboot.shell_line(restore)}")
      end

      def run_directory
        parent = OutputDirectory.prepare(root: @root, path: NativeBench::BoardSets::DIRECTORY)
        directory = File.join(parent, "l4re-walk-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(2)}")
        Dir.mkdir(directory, 0o755)
        directory
      end

      def say(line) = @out.call(line)
    end
  end
end
