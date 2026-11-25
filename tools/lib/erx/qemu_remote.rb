# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'shellwords'
require_relative 'error'
require_relative 'runner'
require_relative 'ssh_hardening'

module Erx
  # QEMU on a second development host (docs/design-build.md, "Placing
  # cells"). Only QEMU runs there: the harness here builds the image, copies
  # the boot's input files into a run directory of their own on that host,
  # starts QEMU there detached from any ssh session, and judges its serial
  # log here as it judges a local boot's, fetching it with short polls.
  #
  # The connection to that host drops now and then, so no ssh session is held
  # for longer than one short step, and every step is safe to run again: a step
  # whose connection is lost is retried (Run#step), a poll that loses it is
  # simply followed by the next, and the remote QEMU, its log, its exit status
  # and the times its serial bytes were written live in files on that host
  # until a poll reads them (qemu_remote_start.sh).
  #
  # ssh hands its command to the remote user's shell, which must be of the
  # Bourne family (sh, bash, zsh), and which must print nothing on standard
  # output for a command it runs; so every remote command
  # is built here from words, each quoted with Shellwords.escape, and fixed
  # operators; and every word that comes from configuration (the destination,
  # the paths) is checked against a plain character set first, so the quoting
  # is never the only defence.
  module QemuRemote
    # The remote host could not be reached, could not set the boot up or run
    # it, or was lost until the boot must have ended; the boot has no result.
    # The cell is reported as not run (QemuCells.lanes).
    class Unreachable < Error; end

    # Never prompt, never read a password, give up on a dead link, and open
    # nothing but the one session, whatever the user's ssh configuration
    # forwards (SshHardening).
    SSH_OPTIONS = [*%w[-T -e none -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=15
                       -o ServerAliveInterval=15 -o ServerAliveCountMax=4], *SshHardening::OPTIONS].freeze
    # user@host or host, as ssh takes it; no leading dash, so never an option.
    DESTINATION = /\A(?:[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}@)?[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z/
    # A remote path: absolute, or relative to the remote home directory, of
    # components that start with no dot or dash, so none is `..` or an option.
    PATH_WORD = %r{\A/?[A-Za-z0-9_][A-Za-z0-9._-]*(?:/[A-Za-z0-9_][A-Za-z0-9._-]*)*\z}
    MAX_PATH_BYTES = 200
    # The remote QEMU's own deadline runs this much past the local one, so the
    # local deadline is the one a slow boot meets, and the remote one ends a
    # QEMU whose harness lost the host or died without cleaning up.
    REMOTE_DEADLINE_SLACK = 30
    # How long the remote GNU timeout waits after its TERM before it kills.
    KILL_AFTER = 10
    # The script that runs the boot on the remote host.
    START_SCRIPT = File.join(__dir__, 'qemu_remote_start.sh')
    # The names the boot's input files take in its run directory.
    INPUT_NAMES = %w[image initrd dtb start.sh].freeze
    # The start script's exit status when it could not set the boot up, and GNU
    # timeout's when it could not run QEMU: the host's failure, not the guest's.
    HOST_FAILURES = [125, 126, 127].freeze

    # ssh's exit status when the connection itself failed, rather than the
    # remote command.
    SSH_LOST = 255
    # A step whose connection is lost runs up to this many times, waiting
    # RETRY_SECONDS times the tries so far, at most MAX_RETRY_SECONDS, between.
    STEP_TRIES = 5
    RETRY_SECONDS = 10
    MAX_RETRY_SECONDS = 30
    # An input file goes up in pieces of this size, each a step of its own,
    # so a lost connection costs one piece, not the file.
    UPLOAD_PIECE_BYTES = 4 << 20
    UPLOAD_PIECE_DEADLINE = 120
    # The wait between polls of a running boot, and each poll's own deadline,
    # past ssh's own limit on a dead link (ServerAliveInterval times
    # ServerAliveCountMax), so a dead link ends a poll as lost first.
    POLL_SECONDS = 2
    POLL_DEADLINE = 90
    # How long polls go on past the time the remote QEMU is surely gone (its
    # own deadline and kill), so a link that comes back still brings the result.
    RECONNECT_SECONDS = 60

    # The clock a remote boot's waits read and sleep on; tests pass one that
    # only pretends.
    module Clock
      def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def self.sleep(seconds) = Kernel.sleep(seconds)
    end

    # The remote host and what it runs: work_dir holds one directory per
    # boot, program is its QEMU and timeout its GNU timeout.
    Host = Data.define(:destination, :work_dir, :program, :timeout) do
      def initialize(destination:, work_dir: 'erxos-qemu', program: '/usr/local/bin/qemu-system-aarch64',
                     timeout: '/usr/local/bin/gtimeout')
        raise Error, "invalid remote QEMU host #{destination.inspect}" unless destination.is_a?(String) && DESTINATION.match?(destination)

        { 'work directory' => work_dir, 'QEMU' => program, 'timeout program' => timeout }.each do |what, path|
          next if path.is_a?(String) && path.bytesize <= MAX_PATH_BYTES && PATH_WORD.match?(path)

          raise Error, "invalid remote #{what} #{path.inspect}"
        end
        super
      end
    end

    # One boot's remote side: its run directory, named by 16 hex digits under
    # the host's work directory, the files in it, and the commands that use
    # them. Every method that makes a command returns the local argv of the
    # ssh that runs it; each command is safe to run again after a lost
    # connection.
    class Boot
      RUN_NAME = /\A\h{16}\z/
      attr_reader :host, :directory

      # name is random unless a test fixes it; it is never a path, so cleanup
      # removes nothing but a run directory under the work directory.
      def initialize(host:, name: Random.bytes(8).unpack1('H*'))
        raise Error, 'a remote run directory is named by 16 hex digits' unless name.is_a?(String) && RUN_NAME.match?(name)

        @host = host
        @name = name
        @directory = File.join(host.work_dir, name)
      end

      # Where an input file lands: one of INPUT_NAMES in the run directory.
      def path(name)
        raise Error, "no remote input named #{name.inspect}" unless INPUT_NAMES.include?(name)

        File.join(@directory, name)
      end

      # The guest's serial line, which QEMU writes and polls read.
      def serial = File.join(@directory, 'serial.log')

      # The FIFO QEMU reads the serial line's input from.
      def keyboard = File.join(@directory, 'keyboard')

      # The work directory, then the run directory, owner-only. The run
      # directory's random name is this boot's alone, so making it again
      # after a lost connection is not an error.
      def prepare_argv = ssh(words('mkdir', '-p', '-m', '700', '--', @host.work_dir),
                             '&&', words('mkdir', '-p', '-m', '700', '--', @directory))

      # Writes its standard input into the file at path from byte offset on,
      # leaving the rest of the file as it is, so writing the same bytes at the
      # same offset again changes nothing. dd counts its seek in blocks, so
      # the block is the largest power of two that divides offset, at most a
      # MiB; on a pipe each short read is written where the last one ended.
      def write_at_argv(path, offset)
        raise Error, 'a remote write starts at a byte offset' unless offset.is_a?(Integer) && !offset.negative?

        block = offset.zero? ? 1 << 20 : [offset & -offset, 1 << 20].min
        ssh(words('dd', "of=#{path}", "bs=#{block}", "seek=#{offset / block}", 'conv=notrunc'), '2>/dev/null')
      end

      # Prints the SHA-256 of a remote file and its path.
      def digest_argv(path) = ssh(words('shasum', '-a', '256', '--', path))

      def version_argv = ssh(words(@host.program, '--version'))

      # Runs the uploaded start script under nohup, detached from the ssh
      # session, with its every file named here (qemu_remote_start.sh). QEMU
      # runs under the remote timeout for seconds. qemu_argv is
      # QemuPlan.argv's, naming the remote program and the run directory's
      # files. Every remote command starts in the remote home directory,
      # which a relative work directory is relative to.
      def start_argv(qemu_argv, seconds:)
        raise Error, 'a remote boot runs the remote host\'s QEMU' unless qemu_argv.first == @host.program

        ssh(words('nohup', 'sh', path('start.sh'), started, status, sizes, keyboard, typed, serial, qemu_log,
                  @host.timeout, KILL_AFTER.to_s, seconds.to_s, *qemu_argv), '> /dev/null 2>&1 < /dev/null &')
      end

      # Prints the boot's state on its first line, `running` or the start
      # script's exit status, then the size samples from the given count on,
      # a line `--`, and the serial log from byte offset on. The status is
      # read first and the log last, so once the state is an exit status the
      # samples include the last one and the bytes cover it. A run directory
      # that is gone fails the poll.
      def poll_argv(samples:, offset:) = ssh(words('test', '-d', @directory), '|| exit 3;',
                                             words('cat', status), '2>/dev/null || echo running;',
                                             words('tail', '-n', "+#{samples + 1}", sizes), '2>/dev/null; echo --;',
                                             words('tail', '-c', "+#{offset + 1}", serial), '2>/dev/null; exit 0')

      # Writes the bytes typed from offset on into the typed file the feeder follows.
      def type_argv(offset) = write_at_argv(typed, offset)

      def log_argv = ssh(words('cat', '--', qemu_log))

      # Kills every process of the boot, then removes the run directory. Each
      # lasting process of the boot (the start script and its sampler, the
      # timeouts, the feeder and QEMU) has the run directory's unique name in
      # its arguments, and no other process does but this command's own
      # shell, which survives because BSD pkill never signals its ancestors
      # (the remote host is macOS; pkill elsewhere may not promise that). A
      # process killed in the middle of a write can finish it after rm has
      # listed the directory, and one forked just after pkill looked escapes
      # it, so a failed rm is followed by a second pkill and rm.
      def cleanup_argv
        kill = [words('pkill', '-KILL', '-f', '--', @name), '2>/dev/null;']
        remove = words('rm', '-rf', '--', @directory)
        ssh(*kill, remove, '|| { sleep 1;', *kill, remove, '; }')
      end

      private

      def started = File.join(@directory, 'started')
      def status = File.join(@directory, 'status')
      def sizes = File.join(@directory, 'sizes')
      def typed = File.join(@directory, 'typed')
      def qemu_log = File.join(@directory, 'qemu.log')

      # Each word quoted for the remote shell, joined by spaces.
      def words(*list)
        raise Error, 'a remote command word is a string without NUL' unless list.all? { |word| word.is_a?(String) && !word.include?("\0") }

        list.map { |word| Shellwords.escape(word) }.join(' ')
      end

      def ssh(*parts) = ['ssh', *SSH_OPTIONS, '--', @host.destination, parts.join(' ')].freeze
    end

    # The transcript's keyboard for a remote boot, as Qemu#run types into it.
    Keyboard = Data.define(:run) do
      def write(bytes) = run.type(bytes)

      def close = nil
    end

    # One remote boot as the harness runs it: each Boot command through the
    # runner, each retried when its connection is lost, files kept in the
    # local run directory, and the waits on clock. Every failure that is the
    # host's, not the guest's, is Unreachable; QEMU's own end is a
    # CommandError, as the runner raises for a local QEMU.
    class Run
      # A step lost its connection: ssh said so, or the step outlived its deadline.
      class Lost < Error; end
      private_constant :Lost

      SAMPLE = /\A(\d{1,12}) +(\d{1,15})\n\z/
      private_constant :SAMPLE

      attr_reader :boot
      # How long the guest had run, on the remote host's clock, at the last
      # size sample a poll brought; nil before the first.
      attr_reader :guest_seconds

      def initialize(boot:, runner:, clock:, directory:)
        @boot = boot
        @runner = runner
        @clock = clock
        @directory = directory
        @prepared = false
        @typed = 0
        @samples = 0
        @first_epoch = nil
        @guest_seconds = nil
        # Until a start has been tried no remote QEMU can run; after, none runs past this.
        @quiet_by = nil
      end

      # Whether a step has tried to make the run directory, which cleanup then removes.
      def prepared? = @prepared

      # The remote QEMU as reuse keys name it: the host, the program and its SHA-256,
      # so boots on different hosts or QEMUs never share a record.
      def identity
        "remote #{host.destination} #{host.program} #{remote_digest(host.program, name: 'qemu-remote-digest')}"
      end

      # The run directory, holding each input file and the start script, each
      # checked whole by its SHA-256.
      def upload(files)
        @prepared = true
        step(@boot.prepare_argv, name: 'qemu-remote-prepare', deadline: 60)
        files.merge('start.sh' => START_SCRIPT).each do |name, local|
          upload_file(local, @boot.path(name))
          next if remote_digest(@boot.path(name), name: 'qemu-remote-upload-digest') == Digest::SHA256.file(local).hexdigest

          raise Unreachable, "remote host #{host.destination}: #{@boot.path(name)} does not match #{local}"
        end
      end

      def version = step(@boot.version_argv, name: 'qemu-version', deadline: 30)

      def keyboard = Keyboard.new(self)

      # Types bytes: written at their own offset in the typed file, so a retry
      # puts the same bytes in the same place and QEMU reads each once.
      def type(bytes)
        return if bytes.empty?

        piece = File.join(@directory, 'typed-piece')
        File.binwrite(piece, bytes, perm: 0o600)
        step(@boot.type_argv(@typed), name: 'qemu-remote-type', deadline: 60, stdin: piece, retry_until: @quiet_by)
        @typed += bytes.bytesize
      end

      # Starts the boot, then polls it until stop says the transcript is whole,
      # QEMU exits, or the guest has run for deadline seconds; the record of a
      # passing boot, or a CommandError as the runner raises one. Each poll
      # appends the serial bytes one size sample at a time and calls stop with
      # the guest's seconds at that sample, so the transcript judges each byte
      # by when the remote host wrote it, however late a lost connection lets
      # it arrive. Once the remote QEMU is surely gone and RECONNECT_SECONDS
      # more have passed with no exit status read, the boot has no result.
      def run(qemu_argv, deadline:, serial:, stop:)
        seconds = deadline + REMOTE_DEADLINE_SLACK
        begin
          step(@boot.start_argv(qemu_argv, seconds: seconds), name: 'qemu-remote-start', deadline: 60)
        ensure
          # Any try of the start that started QEMU did so before now.
          @quiet_by = @clock.now + seconds + KILL_AFTER
        end
        loop do
          @clock.sleep(POLL_SECONDS)
          if @clock.now >= @quiet_by + RECONNECT_SECONDS
            raise Unreachable, "remote host #{host.destination}: no end of the boot read by its remote deadline; its result is unknown"
          end

          # A stop that is satisfied ends the boot from inside the poll.
          state = poll(serial) { |guest_seconds| return { 'log' => qemu_log, 'state' => 'succeeded' } if stop.call(guest_seconds) }
          next if state == :lost
          # Before the exit status: the last sample dates QEMU's exit, so a
          # boot that ended past its deadline times out, as it would have had
          # a poll seen it still running then.
          raise CommandError, { 'log' => qemu_log, 'state' => 'timed_out' } if @guest_seconds && @guest_seconds >= deadline
          return ended(state) unless state == :running
        end
      end

      # Ends every process of the boot and removes its run directory, retried
      # while its QEMU may still run. A failure is reported and not raised, so
      # it never hides the boot's own result; the remote timeout then ends the
      # QEMU, and the directory stays for the next look.
      def cleanup
        step(@boot.cleanup_argv, name: 'qemu-remote-cleanup', deadline: 60, retry_until: @quiet_by)
      rescue Unreachable => e
        Terminal.puts("remote cleanup of #{host.destination}:#{@boot.directory} failed: #{e.message}")
      end

      private

      def host = @boot.host

      def qemu_log = File.join(@directory, 'qemu-remote.log')

      # One short command, run again while its connection is lost, up to
      # STEP_TRIES times or, with retry_until, until that time has passed.
      def step(argv, name:, deadline:, stdin: nil, stdout: nil, retry_until: nil)
        tries = 0
        begin
          tries += 1
          attempt(argv, name: name, deadline: deadline, stdin: stdin, stdout: stdout)
        rescue Lost
          raise Unreachable, "remote host #{host.destination}: #{name} lost its connection #{tries} times" unless
            tries < STEP_TRIES || (retry_until && @clock.now < retry_until)

          @clock.sleep([RETRY_SECONDS * tries, MAX_RETRY_SECONDS].min)
          retry
        end
      end

      # The record of one run of argv. A lost connection is Lost; any other
      # failure is the host's.
      def attempt(argv, name:, deadline:, stdin:, stdout:)
        @runner.run(argv, name: name, deadline: deadline, stdin: stdin, stdout: stdout)
      rescue CommandError => e
        raise Lost if e.result['exit_status'] == SSH_LOST || e.result.fetch('state') == 'timed_out'

        raise Unreachable, "remote host #{host.destination}: #{name} #{e.message}"
      end

      # The file at local, written to remote one piece at a time, each piece
      # at its own offset, so a piece retried rewrites only itself. An empty
      # file is one empty piece, which makes the remote file.
      def upload_file(local, remote)
        piece = File.join(@directory, 'upload-piece')
        (0...[File.size(local), 1].max).step(UPLOAD_PIECE_BYTES) do |offset|
          File.open(piece, 'wb', 0o600) { |out| IO.copy_stream(local, out, UPLOAD_PIECE_BYTES, offset) }
          step(@boot.write_at_argv(remote, offset), name: 'qemu-remote-upload', deadline: UPLOAD_PIECE_DEADLINE, stdin: piece)
        end
      end

      def remote_digest(path, name:)
        log = step(@boot.digest_argv(path), name: name, deadline: 60).fetch('log')
        digest = File.binread(log, 64)
        raise Unreachable, "no SHA-256 of the remote #{path} in #{log}" unless digest&.match?(/\A\h{64}\z/)

        digest
      end

      # One look at the boot: its state, :running, the start script's exit
      # status, or :lost when the connection was lost. For each size sample
      # the look brings, the serial bytes up to that size are appended to the
      # local log, then the guest's seconds at that sample are yielded. Bytes
      # past the last sample wait for the next look, which asks from the local
      # log's end.
      def poll(serial)
        answer = File.join(@directory, 'remote-poll')
        begin
          attempt(@boot.poll_argv(samples: @samples, offset: File.size(serial)), name: 'qemu-remote-poll', deadline: POLL_DEADLINE,
                                                                                    stdin: nil, stdout: answer)
        rescue Lost
          return :lost
        end
        File.open(answer, 'rb') do |input|
          state = poll_state(input.gets("\n", 16))
          samples = poll_samples(input)
          File.open(serial, 'ab') do |out|
            samples.each do |epoch, size|
              copy_exactly(input, out, size - out.size) if size > out.size
              out.flush
              @samples += 1
              @first_epoch ||= epoch
              @guest_seconds = epoch - @first_epoch
              yield @guest_seconds
            end
          end
          state
        end
      end

      def poll_state(line)
        case line
        when "running\n" then :running
        when /\A(\d{1,3})\n\z/ then Integer(Regexp.last_match(1), 10)
        else unreadable_poll
        end
      end

      # The sample lines up to the `--` line, each [epoch, size].
      def poll_samples(input)
        samples = []
        until (line = input.gets("\n", 32)) == "--\n"
          sample = SAMPLE.match(line.to_s)
          unreadable_poll unless sample
          samples << [Integer(sample[1], 10), Integer(sample[2], 10)]
        end
        samples
      end

      def copy_exactly(input, out, bytes)
        unreadable_poll unless IO.copy_stream(input, out, bytes) == bytes
      end

      def unreadable_poll = raise(Unreachable, "remote host #{host.destination}: unreadable poll answer in #{File.join(@directory, 'remote-poll')}")

      # The record of a boot whose start script exited with status, with QEMU's
      # log fetched beside it, as the runner reads an exit: a nonzero status
      # raises, the remote timeout's own (124, or 137 once it kills) is timed
      # out, and a boot the host could not set up or run is Unreachable.
      def ended(status)
        begin
          step(@boot.log_argv, name: 'qemu-remote-log', deadline: 60, stdout: qemu_log)
        rescue Unreachable => e
          Terminal.puts("no QEMU log from the remote boot: #{e.message}")
        end
        raise Unreachable, "remote host #{host.destination}: the boot could not start (status #{status}); log: #{qemu_log}" if HOST_FAILURES.include?(status)

        state = { 0 => 'succeeded', 124 => 'timed_out', 137 => 'timed_out' }.fetch(status, 'failed')
        record = { 'log' => qemu_log, 'state' => state, 'exit_status' => status }
        raise CommandError, record unless state == 'succeeded'

        record
      end
    end
  end
end
