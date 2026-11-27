# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'socket'
require 'zlib'
require_relative 'error'
require_relative 'linux_guest'
require_relative 'newc_archive'
require_relative 'output_directory'
require_relative 'process_group'
require_relative 'qmp'
require_relative 'runner'
require_relative 'side_lock'

module Erx
  # The probe that settles the QEMU fault kinds docs/design-recovery.md ("Fault injection
  # and tests", layer 3) leaves unverified, by their behaviour on the pinned QEMU: block_stall
  # (block_set_io_throttle, reads limited to a byte a second, then no limit), link_down with
  # its lift link_up (set_link) and chardev_stop (chardev-change to the null backend and back,
  # else chardev-remove).
  #
  # Linux's guest (LinuxGuest's pinned Alpine kernel, under HVF) runs test/fault_probe/init.c,
  # whose threads read a scratch disk, watch eth0's carrier and write a virtio console port the
  # probe listens on, and tick on the serial console. The probe injects each kind in turn,
  # holds it HOLD_SECONDS, lifts it and watches AFTER_SECONDS more; then it judges each kind
  # from what the guest printed and when the host saw it. A kind is verified only when (a) the
  # fault stopped exactly its operation, (b) the other two devices and the tick went on, and
  # (c) the operation completed once lifted; a kind QEMU refuses, or that misses any of the
  # three, is unsupported with QEMU's answer or the observation that failed.
  #
  # Nothing a fault does reaches the host outside the QEMU process the probe starts: the disk
  # is a file in the run's owner-only directory, the network backend is user mode with
  # restrict=on, and the console's socket is the probe's own, in that directory (Qmp's
  # chardev_change refuses any other path). QEMU's answers reach a reason only through Qmp,
  # which escapes them; the guest's text is parsed, never printed.
  module FaultProbe
    # The kinds in the order the probe injects them.
    KINDS = %i[block_stall link_down chardev_stop].freeze
    # The guest operation each kind stops; the other two must go on while it holds.
    TARGETS = { block_stall: :read, link_down: :carrier, chardev_stop: :console }.freeze
    SIGNALS = TARGETS.values.freeze

    # QEMU's names for the probe's devices, which the actions name.
    BLOCK_DRIVE = 'disk0'
    BLOCK_DEVICE = 'blk0'
    # The read limit that holds the guest's reads, in bytes a second; 0 is no limit.
    STALL_BPS_RD = 1
    NIC = 'nic0'
    CHARDEV = 'con0'

    HOLD_SECONDS = 3.0
    AFTER_SECONDS = 3.0
    # A read or console line already on its way when the fault came may land this late.
    SETTLE_SECONDS = 0.3
    # The guest ticks every 100 ms; a longer silence than this means the guest stalled.
    MAX_TICK_GAP_SECONDS = 1.0
    # An operation that goes on shows at least this many completions in a window.
    MIN_ACTIVITY = 5
    READY_SECONDS = 60
    POLL_SECONDS = 0.02
    MAX_LINE_BYTES = 4096
    BLOCK_BYTES = 4096
    # The guest's tick and console period; its reader and carrier watcher run at half of it.
    TICK_MS = 100
    DISK_BYTES = 65_536
    MEMORY_MIB = 256
    QEMU = 'qemu-system-aarch64'
    # The guest powers itself off after this; QEMU's deadline is a little later.
    GUEST_DEADLINE_SECONDS = 120
    QEMU_DEADLINE_SECONDS = GUEST_DEADLINE_SECONDS + 15
    INIT = 'test/fault_probe/init.c'
    # The virtio driver modules of the pinned kernel, which builds them as modules: the
    # members of Alpine's netboot initramfs this lock pins, over their own workspace.
    MODULES_LOCK = 'test/fault_probe/deps.lock'
    MODULES_WORKSPACE = 'build/fault-probe-sources'
    MODULES = 'alpine-initramfs-virt'
    LABEL = 'fault-probe'
    FETCH_COMMAND = 'ruby tools/erx probe-faults --fetch'

    # One line the guest printed, as a signal and its numbers, at the host's monotonic time
    # the probe first saw it.
    Observation = Data.define(:at, :signal, :values)
    # One kind's fault: when it was injected and lifted, and when watching it ended.
    Window = Data.define(:kind, :injected, :lifted, :ended)
    # A kind whose action QEMU refused, with its answer, escaped; leaves_state when the
    # refusal leaves a fault in place or QEMU unreachable, so later kinds cannot be judged.
    Refusal = Data.define(:kind, :answer, :leaves_state)
    # A kind's result: :verified, or :unsupported with the reason.
    Verdict = Data.define(:kind, :status, :reason)

    # The guest's lines on each of its outputs (test/fault_probe/init.c): the signal each
    # line is, its pattern, and the base of each number it captures (decimal unless named).
    LINES = {
      serial: { tick: [/\Afault: tick (\d+)\z/], read: [/\Afault: blk ok (\d+) (\h{8})\z/, [10, 16]],
                read_error: [/\Afault: blk error (\d+)\z/], carrier: [/\Afault: carrier (-1|0|1)\z/],
                console_error: [/\Afault: con error (\d+)\z/], setup_error: [/\Afault: setup [a-z0-9]+ (\d+)\z/],
                ready: [/\Afault: ready\z/] },
      console: { console: [/\Acon (\d+)\z/] }
    }.freeze

    module_function

    # The observation a guest line on output (:serial or :console) at time at shows, or nil
    # for any other line, such as the kernel's own.
    def observe(text, output:, at:)
      LINES.fetch(output).each do |signal, (pattern, bases)|
        match = pattern.match(text) or next
        values = match.captures.each_with_index.map { |capture, index| Integer(capture, bases&.fetch(index) || 10) }
        return Observation.new(at: at, signal: signal, values: values)
      end
      nil
    end

    # The verdict on kind from its attempt (a Window or a Refusal) and every observation of
    # the run; expected_crc is the CRC-32 of the block the guest reads.
    def judge(attempt, observations, expected_crc:)
      return Verdict.new(kind: attempt.kind, status: :unsupported, reason: attempt.answer) if attempt.is_a?(Refusal)

      reason = Judgement.new(attempt, observations, expected_crc).failure
      Verdict.new(kind: attempt.kind, status: reason ? :unsupported : :verified, reason: reason)
    end

    # The line the probe prints for a verdict; its reason is the probe's own text or QEMU's
    # escaped answer.
    def line(verdict)
      ["fault probe: #{verdict.kind} #{verdict.status}", verdict.reason].compact.join(': ')
    end

    # Judges one window against the three conditions; failure is the first that fails, or nil.
    class Judgement
      def initialize(window, observations, expected_crc)
        @window = window
        @observations = observations
        @expected_crc = expected_crc
      end

      def failure
        target = TARGETS.fetch(@window.kind)
        [stopped_failure(target), *(SIGNALS - [target]).map { |signal| working_failure(signal) }, pulse_failure,
         resumed_failure(target), wrong_data_failure].compact.first
      end

      private

      def between(signal, from, to) = @observations.select { |seen| seen.signal == signal && seen.at > from && seen.at <= to }
      def during(signal) = between(signal, @window.injected, @window.lifted)
      def held(signal) = between(signal, @window.injected + SETTLE_SECONDS, @window.lifted)
      def after(signal) = between(signal, @window.lifted, @window.ended)
      def held_seconds = @window.lifted - @window.injected

      # (a) The fault stopped the kind's own operation.
      def stopped_failure(target)
        case target
        when :read then "#{held(:read).size} reads completed while the fault held" unless held(:read).empty?
        when :carrier
          'the guest never saw its carrier go down, or saw it come back while the fault held' unless
            during(:carrier).last&.values == [0] && held(:carrier).none? { |seen| seen.values == [1] }
        when :console then "#{held(:console).size} console lines arrived while the fault held" unless held(:console).empty?
        end
      end

      # (b) An operation the kind does not target went on while the fault held.
      def working_failure(signal)
        case signal
        when :read
          return "reads failed while #{@window.kind} held" unless during(:read_error).empty?

          "only #{during(:read).size} reads completed while #{@window.kind} held" if during(:read).size < MIN_ACTIVITY
        when :carrier
          last = @observations.select { |seen| seen.signal == :carrier && seen.at <= @window.lifted }.last
          "the guest's carrier was not up while #{@window.kind} held" unless last&.values == [1] && during(:carrier).empty?
        when :console
          return "console writes failed while #{@window.kind} held" unless during(:console_error).empty?

          "only #{during(:console).size} console lines arrived while #{@window.kind} held" if during(:console).size < MIN_ACTIVITY
        end
      end

      # (b) The guest's own tick went on throughout.
      def pulse_failure
        ticks = between(:tick, @window.injected, @window.ended).map(&:at)
        gap = [@window.injected, *ticks, @window.ended].each_cons(2).map { |earlier, later| later - earlier }.max
        "the guest's tick stopped for #{format('%.2f', gap)} s" if gap > MAX_TICK_GAP_SECONDS
      end

      # (c) Once lifted, the operation completed: the held read answers, carrier returns,
      # console lines flow again.
      def resumed_failure(target)
        case target
        when :read
          first = after(:read).first
          return 'no read completed after the lift' unless first
          return "the first read after the lift took #{first.values[0]} ms, so it was not the held one" if
            first.values[0] < (held_seconds - SETTLE_SECONDS) * 1000
          return "only #{after(:read).size} reads completed after the lift" if after(:read).size < MIN_ACTIVITY
        when :carrier then 'the guest never saw its carrier come back' unless after(:carrier).any? { |seen| seen.values == [1] }
        when :console
          "only #{after(:console).size} console lines arrived after the lift" if after(:console).size < MIN_ACTIVITY
        end
      end

      def wrong_data_failure
        wrong = between(:read, @window.injected, @window.ended).reject { |seen| seen.values[1] == @expected_crc }
        "#{wrong.size} reads answered data the probe did not write" unless wrong.empty?
      end
    end

    # The modules' lock over its workspace.
    def modules_lock(root:, runner:)
      SideLock.dependencies(root: root, runner: runner, lock: MODULES_LOCK, workspace: MODULES_WORKSPACE, label: LABEL)
    end

    # Fetches what the modules' lock pins, from cache (another checkout's
    # build/fault-probe-sources/build/downloads) when given; a line per source.
    def fetch(root:, cache: nil)
      runner = Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs'))
      SideLock.fetch(modules_lock(root: root, runner: runner), root: root, label: LABEL, cache: cache)
    end

    # The effect layer: builds the guest, boots it, injects each kind and answers the verdicts,
    # leaving the serial log, QEMU's log and record.json in directory, a new directory (by
    # default under root's build/fault-probe), made owner-only for QMP's socket.
    def run(root:, directory: nil)
      directory = make_directory(root, directory)
      runner = Runner.new(owner_root: directory, log_dir: File.join(directory, 'commands'))
      kernel, initrd = build(root: root, runner: runner, directory: directory)
      block = Random.bytes(DISK_BYTES)
      File.binwrite(disk_path(directory), block)
      expected_crc = Zlib.crc32(block.byteslice(0, BLOCK_BYTES))
      qemu_version = File.binread(runner.run([QEMU, '--version'], name: 'qemu-version', deadline: 30).fetch('log')).lines.first.to_s.strip
      attempts, observations = boot(runner: runner, directory: directory, kernel: kernel, initrd: initrd)
      verdicts = attempts.map { |attempt| judge(attempt, observations, expected_crc: expected_crc) }
      File.write(File.join(directory, 'record.json'), JSON.pretty_generate(
        'qemu' => qemu_version, 'accelerator' => 'hvf', 'machine' => 'virt', 'arguments' => qemu_arguments(directory, kernel, initrd),
        'attempts' => attempts.map(&:to_h), 'verdicts' => verdicts.map(&:to_h),
        'observations' => observations.map(&:to_h)
      ))
      verdicts
    end

    # What QEMU boots: the guest on one CPU under HVF, its serial console in a file, and the
    # three scratch devices, each named as the actions name it.
    def qemu_arguments(directory, kernel, initrd)
      blockdev = JSON.generate('driver' => 'raw', 'node-name' => BLOCK_DRIVE,
                               'file' => { 'driver' => 'file', 'filename' => disk_path(directory) })
      ['-M', 'virt', '-accel', 'hvf', '-cpu', 'host', '-smp', '1', '-m', MEMORY_MIB.to_s, '-nodefaults',
       '-display', 'none', '-no-reboot', '-kernel', kernel, '-initrd', initrd, '-append', LinuxGuest::COMMAND_LINE,
       '-serial', "file:#{serial_path(directory)}", '-qmp', "unix:#{qmp_path(directory)},server=on,wait=off",
       '-blockdev', blockdev, '-device', "virtio-blk-device,drive=#{BLOCK_DRIVE},id=#{BLOCK_DEVICE}",
       '-netdev', 'user,id=net0,restrict=on', '-device', "virtio-net-device,netdev=net0,id=#{NIC}",
       '-chardev', "socket,id=#{CHARDEV},path=#{console_path(directory)},server=off",
       '-device', 'virtio-serial-device', '-device', "virtconsole,chardev=#{CHARDEV}"]
    end

    def disk_path(directory) = File.join(directory, 'disk.raw')
    def serial_path(directory) = File.join(directory, 'serial.log')
    def qmp_path(directory) = File.join(directory, 'qmp.sock')
    def console_path(directory) = File.join(directory, 'console.sock')

    def make_directory(root, directory)
      directory ||= File.join(OutputDirectory.prepare(root: root, path: File.join(root, 'build/fault-probe')),
                              "run-#{Process.pid}-#{Random.bytes(4).unpack1('H*')}")
      Dir.mkdir(directory, 0o700)
      File.realpath(directory)
    rescue SystemCallError => e
      raise Error, "fault probe: cannot make a new directory #{directory}: #{e.class.name.split('::').last}"
    end

    # The kernel LinuxGuest pins and an initramfs whose /init is the probe's guest program,
    # with the virtio modules in /modules.
    def build(root:, runner:, directory:)
      dependencies = LinuxGuest.lock(root: root, runner: runner)
      missing = [LinuxGuest::KERNEL, LinuxGuest::MUSL_DEV].reject { |id| dependencies.fetched?(id) }
      raise Error, "the fault probe needs #{missing.join(', ')}: run `#{SideLock.fetch_command(LinuxGuest::LABEL)}`" unless
        missing.empty?

      modules = modules_lock(root: root, runner: runner)
      raise Error, "the fault probe needs #{MODULES}: run `#{FETCH_COMMAND}`" unless modules.fetched?(MODULES)

      tree = modules.fetched_tree(MODULES)
      members = modules.sources.find { |source| source.fetch('id') == MODULES }.fetch('members').split
      module_entries = members.map do |member|
        NewcArchive::Entry.file("modules/#{File.basename(member)}", File.binread(File.join(tree, member)), mode: 0o644)
      end
      init = LinuxGuest.compile(root: root, usr: dependencies.fetched_tree(LinuxGuest::MUSL_DEV), output: directory,
                                runner: runner, source: INIT, flags: ["-DFAULT_PROBE_DEADLINE_S=#{GUEST_DEADLINE_SECONDS}", "-DFAULT_PROBE_TICK_MS=#{TICK_MS}",
                                       "-DFAULT_PROBE_BLOCK_BYTES=#{BLOCK_BYTES}"])
      initrd = File.join(directory, 'initramfs.cpio')
      File.binwrite(initrd, NewcArchive.write([NewcArchive::Entry.directory('dev'),
                                               NewcArchive::Entry.character('dev/console', major: 5, minor: 1),
                                               NewcArchive::Entry.directory('sys'), NewcArchive::Entry.directory('modules'),
                                               *module_entries,
                                               NewcArchive::Entry.file('init', File.binread(init), mode: 0o755)]))
      [dependencies.fetched_file(LinuxGuest::KERNEL), initrd]
    end

    # Boots QEMU in a process group of its own under the deadline tool, injects every kind, and
    # answers the attempts and the observations. However this ends, QEMU's group is ended.
    def boot(runner:, directory:, kernel:, initrd:)
      listener = UNIXServer.new(console_path(directory))
      recorder = Recorder.new(serial: serial_path(directory), listener: listener)
      pid = qmp = nil
      Qmp.check_directory(qmp_path(directory))
      Thread.handle_interrupt(Object => :never) do
        pid = Process.spawn(runner.timeout_program, '-k', '10', QEMU_DEADLINE_SECONDS.to_s, QEMU,
                            *qemu_arguments(directory, kernel, initrd),
                            in: File::NULL, out: [File.join(directory, 'qemu.log'), 'w', 0o600], err: %i[child out],
                            pgroup: true)
      end
      recorder.start
      qmp = Qmp.connect(qmp_path(directory))
      await_ready(recorder)
      attempts = KINDS.each_with_object([]) do |kind, done|
        done << (spoiled(done.last)&.with(kind: kind) || exercise(kind, qmp, directory))
      end
      qmp.quit
      [attempts, recorder.stop]
    ensure
      Thread.handle_interrupt(Object => :never) do
        begin
          ProcessGroup.terminate(pid) if pid
        ensure
          begin
            qmp&.close
            recorder&.stop
          ensure
            listener&.close
          end
        end
      end
    end

    # A later kind's attempt when an earlier one left QEMU in an unknown state (its lift
    # failed or the connection closed): not attempted, naming why; else nil.
    def spoiled(previous)
      return nil unless previous.is_a?(Refusal) && previous.leaves_state

      Refusal.new(kind: nil, answer: "not attempted: #{previous.kind} left QEMU's state unknown", leaves_state: true)
    end

    def await_ready(recorder)
      deadline = Qmp.monotonic + READY_SECONDS
      until ready?(recorder.observations)
        raise Error, "fault probe: the guest did not start its four threads in #{READY_SECONDS} s" if Qmp.monotonic > deadline

        sleep POLL_SECONDS * 5
      end
    end

    def ready?(observations)
      signals = observations.map(&:signal)
      %i[ready tick read console].all? { |signal| signals.include?(signal) } &&
        observations.reverse.find { |seen| seen.signal == :carrier }&.values == [1]
    end

    # Injects kind, holds it, lifts it and watches after; a Window, or a Refusal when QEMU
    # refused the injection or the lift or its monitor did not answer.
    def exercise(kind, qmp, directory)
      injected = Qmp.monotonic
      begin
        inject(kind, qmp)
      rescue Qmp::ProtocolError, Qmp::Timeout => e
        return Refusal.new(kind: kind, answer: "injection: #{e.message}", leaves_state: !e.instance_of?(Qmp::ProtocolError))
      end
      sleep HOLD_SECONDS
      lifted = Qmp.monotonic
      begin
        lift(kind, qmp, directory)
      rescue Qmp::ProtocolError, Qmp::Timeout => e
        return Refusal.new(kind: kind, answer: "lift: #{e.message}", leaves_state: true)
      end
      sleep AFTER_SECONDS
      Window.new(kind: kind, injected: injected, lifted: lifted, ended: Qmp.monotonic)
    end

    def inject(kind, qmp)
      case kind
      when :block_stall then qmp.block_set_io_throttle(BLOCK_DEVICE, bps_rd: STALL_BPS_RD)
      when :link_down then qmp.set_link(NIC, up: false)
      when :chardev_stop then stop_chardev(qmp)
      end
    end

    def lift(kind, qmp, directory)
      case kind
      when :block_stall then qmp.block_set_io_throttle(BLOCK_DEVICE, bps_rd: 0)
      when :link_down then qmp.set_link(NIC, up: true)
      when :chardev_stop then qmp.chardev_change(CHARDEV, unix_socket: console_path(directory))
      end
    end

    # chardev-change to the null backend, else chardev-remove; refused only when both are,
    # with both answers.
    def stop_chardev(qmp)
      qmp.chardev_change(CHARDEV)
    rescue Qmp::ProtocolError => e
      begin
        qmp.chardev_remove(CHARDEV)
      rescue Qmp::ProtocolError => removal
        raise Qmp::ProtocolError, "#{e.message}; #{removal.message}"
      end
    end

    # Watches the serial log QEMU writes and every connection QEMU makes to the console
    # socket, on a thread of its own, and stamps each guest line with the host's time.
    class Recorder
      def initialize(serial:, listener:)
        @serial_path = serial
        @listener = listener
        @peers = []
        @serial = nil
        @buffers = Hash.new { |hash, key| hash[key] = String.new(encoding: Encoding::BINARY) }
        @seen = Thread::Queue.new
        @observations = []
        @running = true
      end

      def start
        @thread = Thread.new { watch while @running }
        self
      end

      # Every observation so far, oldest first.
      def observations
        @observations << @seen.pop until @seen.empty?
        @observations.dup
      end

      # Stops watching and answers every observation.
      def stop
        @running = false
        thread = @thread
        @thread = nil
        thread&.join
        [@serial, *@peers].compact.each(&:close)
        @peers.clear
        @serial = nil
        observations
      end

      private

      def watch
        ready = IO.select([@listener, *@peers], nil, nil, POLL_SECONDS)&.first || []
        ready.each { |io| io == @listener ? @peers << @listener.accept : take(io, output: :console) }
        @serial ||= File.open(@serial_path, 'rb') if File.file?(@serial_path)
        take(@serial, output: :serial) if @serial
      end

      # Reads what io has now; the end of a console connection closes it. The serial log's
      # end is only where QEMU has written to so far.
      def take(io, output:)
        chunk = io.read_nonblock(65_536, exception: false)
        if chunk.nil? && output == :console
          @peers.delete(io)
          @buffers.delete(io)
          io.close
        elsif chunk.is_a?(String)
          split(io, chunk, output)
        end
      end

      def split(io, chunk, output)
        buffer = @buffers[io] << chunk
        while (newline = buffer.index("\n"))
          text = buffer.slice!(0, newline + 1).chomp.delete_suffix("\r")
          seen = FaultProbe.observe(text, output: output, at: Qmp.monotonic)
          @seen << seen if seen
        end
        buffer.clear if buffer.bytesize > MAX_LINE_BYTES
      end
    end
  end
end
