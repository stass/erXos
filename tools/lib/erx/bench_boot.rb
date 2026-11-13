# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require 'tmpdir'
require_relative 'bench'
require_relative 'bench_g3'
require_relative 'error'
require_relative 'interactive_boot'
require_relative 'output_directory'
require_relative 'platform'
require_relative 'process_group'
require_relative 'production_image'
require_relative 'qemu'

module Erx
  # Boot time of the development image, under QEMU with one CPU: N boots of one image, each
  # timed to four lines of the serial console, as a person waiting at the console sees them.
  #
  # The boot is timed by the host. QEMU's serial line is a pipe, and each chunk read from it
  # is stamped with the host's monotonic seconds since QEMU was spawned, so a line is known
  # to the millisecond (the QEMU harness's checkpoints poll every 50 ms at most, too coarse
  # for a boot of half a second under HVF). Each boot runs on a fresh QEMU with no disk and
  # no network, stops at the shell banner and is then killed. The times include QEMU's own
  # start-up and the deadline tool's, which are the same for every image on the same host.
  #
  # QEMU runs under the deadline tool in a process group of its own, so no run, whether it
  # ends, fails or is interrupted, leaves a QEMU behind. Each boot's serial bytes and QEMU's
  # standard error go to files beside the report, which is written when a boot fails too.
  #
  # Reading the lines is pure (Transcript, marks, summarize); the image build and the QEMU
  # process are the effects at the edge.
  module BenchBoot
    # What one run asks: how many boots, and how long one may take before it is a failure.
    Plan = Data.define(:accel, :runs, :deadline_seconds)
    PLANS = {
      'hvf' => Plan.new(accel: 'hvf', runs: 11, deadline_seconds: 60),
      'tcg' => Plan.new(accel: 'tcg', runs: 5, deadline_seconds: 240)
    }.freeze
    MAX_RUNS = 101
    # A boot prints a few kilobytes; a console that prints more than this is not booting.
    MAX_SERIAL_BYTES = 4 * 1024 * 1024
    # The deadline tool outlives the host's own deadline by this long, so it only fires when
    # the host process is gone.
    TOOL_MARGIN_SECONDS = 5

    # A line of the serial console, newline included, and the seconds after the spawn of the
    # chunk that ended it.
    Line = Data.define(:seconds, :text)
    # A progress line of the boot: the first line that matches pattern is when the boot
    # reached name.
    Mark = Data.define(:name, :pattern)

    # The lines that mark progress, in the order the boot reaches them, named as the QEMU
    # harness names the same lines (BenchGuestLog::BOOT_POINTS): the kernel's banner, the
    # root task's identity line, the Erlang/OTP slogan of the system domain, and the command
    # shell's banner, after which the console reads a command. The run stops at the last.
    # The patterns are the harness's own, so both agree on which line answered; the root task's
    # line is matched by its prefix, whatever the build and index it names.
    MARKS = [
      Mark.new(name: 'erxos-banner',
               pattern: Qemu::BANNER.find { |entry| entry.fetch(:name) == 'erxos-banner' }.fetch(:pattern)),
      Mark.new(name: 'root-identity', pattern: /\Aerx: root task: build /n),
      Mark.new(name: 'release-slogan', pattern: ProductionImage::Run::SLOGAN.fetch(:pattern)),
      Mark.new(name: 'release-shell', pattern: ProductionImage::Run::RELEASE_SHELL.fetch(:pattern))
    ].freeze
    MARK_NAMES = MARKS.map(&:name).freeze
    LAST_MARK = MARK_NAMES.last

    # The serial text as Lines, one chunk at a time, with the one buffer for the text no
    # newline has ended yet.
    class LineSplitter
      def initialize
        @pending = +''.b
        @seconds = 0.0
      end

      # The lines this chunk ended, in order.
      def push(seconds, chunk)
        @seconds = seconds
        ended, newline, @pending = (@pending + chunk.b).rpartition("\n")
        (ended + newline).lines.map { |text| Line.new(seconds: seconds, text: text) }
      end

      # The text no newline has ended, as the line a newline would end, or nil without any.
      # The command shell's banner may reach the host before its newline does, so the last
      # mark is looked for here too; the marks' patterns are written for whole lines.
      def tail
        Line.new(seconds: @seconds, text: "#{@pending}\n") unless @pending.empty?
      end
    end

    # What the serial line has said so far: every chunk goes to log, the first stamp of each
    # mark is kept, and so are the last two lines for a failure's diagnostic. The sum of the
    # chunks is bounded by limit, and the chunk that crosses it is the last one logged, so a
    # guest cannot grow the host's memory or disk by more than a chunk past limit.
    class Transcript
      attr_reader :found, :recent, :bytes

      def initialize(log:, limit: MAX_SERIAL_BYTES)
        @log = log
        @limit = limit
        @splitter = LineSplitter.new
        @found = {}
        @recent = []
        @bytes = 0
      end

      def add(seconds, chunk)
        @log.write(chunk)
        @bytes += chunk.bytesize
        raise Error, "the console printed more than #{@limit} bytes" if @bytes > @limit

        lines = @splitter.push(seconds, chunk)
        @found = BenchBoot.mark_lines(@found, lines)
        @found = BenchBoot.mark_lines(@found, [@splitter.tail], marks: [MARKS.last]) if @splitter.tail
        @recent = (@recent + lines).last(2)
      end

      def complete? = @found.key?(LAST_MARK)
    end

    module_function

    # found, plus the first stamp among lines of each of marks that found does not have yet.
    def mark_lines(found, lines, marks: MARKS)
      marks.each_with_object(found.dup) do |mark, reached|
        next if reached.key?(mark.name)

        line = lines.find { |candidate| mark.pattern.match?(candidate.text) }
        reached[mark.name] = line.seconds if line
      end
    end

    # The first stamp of each mark among lines. A mark the boot never printed is absent.
    def marks(lines) = mark_lines({}, lines)

    # Median, smallest, largest and the interquartile spread of values, in seconds.
    def spread(values)
      raise Error, 'no values to summarize' if values.empty?

      sorted = values.sort
      { 'median' => quantile(sorted, 0.5), 'min' => sorted.first, 'max' => sorted.last,
        'q1' => quantile(sorted, 0.25), 'q3' => quantile(sorted, 0.75), 'n' => sorted.size }
    end

    # The quantile q of sorted values, by interpolation between the two nearest.
    def quantile(sorted, quantile)
      position = (sorted.size - 1) * quantile
      lower = sorted.fetch(position.floor)
      upper = sorted.fetch(position.ceil)
      lower + ((upper - lower) * (position - position.floor))
    end

    # One spread per mark over the runs that reached it, plus the count that did not.
    def summarize(runs)
      MARK_NAMES.to_h do |name|
        reached = runs.filter_map { |marks| marks[name] }
        [name, reached.empty? ? { 'n' => 0 } : spread(reached).merge('missed' => runs.size - reached.size)]
      end
    end

    # A run is complete when no boot failed and every mark was reached by some boot; a mark
    # nobody reached is a pattern that no longer matches the console.
    def complete?(summary, failure)
      failure.nil? && summary.values.none? { |entry| entry.fetch('n').zero? }
    end

    # One mark's summary as a line of the report, in milliseconds.
    def format_line(mark, entry)
      return format('boot %-14s never reached', mark) if entry.fetch('n').zero?

      format('boot %-14s median %6.1f ms  min %6.1f  max %6.1f  q1..q3 %6.1f..%6.1f  (n=%d)', mark,
             *%w[median min max q1 q3].map { |key| entry.fetch(key) * 1000 }, entry.fetch('n'))
    end

    # Boots argv under the deadline tool in a process group of its own, and returns the marks
    # the serial line shows. The serial bytes go to serial_log, QEMU's standard error to
    # qemu_log. The group is ended however this returns or raises, so no QEMU outlives its boot.
    # A boot that ends or runs out of time before the last mark is an Error.
    def boot_once(argv, deadline_seconds:, serial_log:, qemu_log:, timeout_program:)
      reader = writer = pid = nil
      transcript = nil
      ended = nil
      File.open(serial_log, 'wb', 0o600) do |log|
        reader, writer = IO.pipe
        started = monotonic
        # The spawn and the pid's assignment are one step, so an interrupt cannot come between.
        Thread.handle_interrupt(Object => :never) do
          pid = spawn_group([timeout_program, '-k', '10', (deadline_seconds + TOOL_MARGIN_SECONDS).to_s, *argv],
                            out: writer, err: [qemu_log, 'w', 0o600])
        end
        writer.close
        transcript = Transcript.new(log: log)
        ended = read_until_complete(reader, transcript, started: started, deadline: started + deadline_seconds)
      end
      raise_unfinished(ended, transcript, deadline_seconds: deadline_seconds, qemu_log: qemu_log) unless transcript.complete?

      transcript.found
    ensure
      # Ending the group is not interrupted: a second interrupt would leave QEMU to the deadline tool.
      Thread.handle_interrupt(Object => :never) do
        ProcessGroup.terminate(pid) if pid
        reader&.close
        writer&.close
      end
    end

    # The Error for a boot that stopped before the last mark: what the console ended with, and
    # where to look. Guest text is quoted only through inspect, which escapes it.
    def raise_unfinished(ended, transcript, deadline_seconds:, qemu_log:)
      last = transcript.recent.map { |line| line.text[0, 80] }.inspect
      case ended
      when :eof
        raise Error, "QEMU ended before #{LAST_MARK}; the console ended with #{last}; QEMU's standard error is in #{qemu_log}"
      else
        raise Error, "boot did not reach #{LAST_MARK} in #{deadline_seconds} s; the console ended with #{last}"
      end
    end
    private_class_method :raise_unfinished

    def spawn_group(argv, **redirects)
      Process.spawn([argv.first, argv.first], *argv.drop(1), in: File::NULL, pgroup: true, **redirects)
    rescue SystemCallError => error
      raise Error, "cannot start #{argv.first}: #{error.message}"
    end
    private_class_method :spawn_group

    # Feeds the pipe's chunks to transcript until the last mark, the end of the stream or
    # the deadline, which is looked at before each read. Returns which of the three ended it:
    # :complete, :eof or :deadline.
    def read_until_complete(reader, transcript, started:, deadline:)
      until transcript.complete?
        remaining = deadline - monotonic
        return :deadline unless remaining.positive?
        next unless IO.select([reader], nil, nil, remaining)

        chunk = reader.read_nonblock(65_536, exception: false)
        return :eof if chunk.nil?
        next if chunk == :wait_readable

        transcript.add(monotonic - started, chunk)
      end
      :complete
    end
    private_class_method :read_until_complete

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    private_class_method :monotonic

    # The first line of a tool's `--version`, run under the runner's deadline.
    def version_line(runner, program)
      command = runner.run([program, '--version'], name: 'bench-boot-version', deadline: 10)
      File.read(command.fetch('log')).lines.first.to_s.strip
    end
    private_class_method :version_line

    # Runs the plan on image (built here from this tree unless given) and writes
    # build/bench/boot-<accel>-*/result.json, with each boot's serial-N.log and qemu-N.log
    # beside it. The first boot that fails with an Error ends the run and is recorded as
    # 'failure'; the report is written all the same. Boots are one after another on a quiet host: the report records
    # the load average before and after. The report's 'complete' says whether no boot failed
    # and every mark was reached.
    def run(root:, runner:, plan:, image: nil, jobs: 4, compiler: ENV.fetch('ERX_CLANG', ''),
            linker: ENV.fetch('ERX_LLD', ''), platform: Platform.development(root), runs: nil)
      count = runs || plan.runs
      raise Error, "boot runs must be between 1 and #{MAX_RUNS}" unless count.is_a?(Integer) && count.between?(1, MAX_RUNS)

      build = BenchG3.new(root: root, runner: runner).build_record(image, clang: compiler)
      image ||= InteractiveBoot.build_image(root: root, runner: runner, jobs: jobs, platform: platform,
                                            compiler: compiler, linker: linker)
      image = File.expand_path(image)
      image_sha256 = Digest::SHA256.file(image).hexdigest
      line = ProductionImage::Run::COMMAND_LINES[plan.accel]
      argv = QemuPlan.argv(platform: platform, accel: plan.accel, cpus: 1, image: image,
                           serial: QemuPlan::STDIO, memory_mib: platform.memory_mib, command_line: line)
      bench = Bench.new(root: root, runner: runner)
      qemu_version = version_line(runner, argv.first)
      directory = output_directory(root, plan)
      load_before = bench.load_average
      boots, failure = boot_all(argv, count: count, plan: plan, directory: directory,
                                      timeout_program: runner.timeout_program)
      summary = summarize(boots)
      report = { 'kind' => 'boot', 'date' => Time.now.utc.iso8601, 'host' => bench.host_description,
                 'host_load' => { 'before' => load_before, 'after' => bench.load_average },
                 'accelerator' => plan.accel, 'cpus' => 1, 'image' => image, 'image_sha256' => image_sha256,
                 'qemu' => qemu_version, 'qemu_argv' => argv,
                 'compiler' => build.fetch('compiler'), 'erts_build_flags' => build.fetch('flags'),
                 'runs' => count, 'boots' => boots, 'failure' => failure, 'summary' => summary,
                 'complete' => complete?(summary, failure) }
      report.merge('report' => write(directory, report))
    end

    # The boots that reached the last mark, and the first that did not, as [boots, failure]
    # with failure nil when none failed.
    def boot_all(argv, count:, plan:, directory:, timeout_program:)
      boots = []
      failure = nil
      (1..count).each do |number|
        boots << boot_once(argv, deadline_seconds: plan.deadline_seconds, timeout_program: timeout_program,
                                 serial_log: File.join(directory, "serial-#{number}.log"),
                                 qemu_log: File.join(directory, "qemu-#{number}.log"))
      rescue Error => error
        failure = { 'boot' => number, 'error' => error.message }
        break
      end
      [boots, failure]
    end
    private_class_method :boot_all

    def output_directory(root, plan)
      parent = OutputDirectory.prepare(root: root, path: File.join(root, 'build/bench'))
      Dir.mktmpdir("boot-#{plan.accel}-", parent)
    end
    private_class_method :output_directory

    def write(directory, report)
      path = File.join(directory, 'result.json')
      File.write(path, JSON.pretty_generate(report) + "\n")
      path
    end
    private_class_method :write
  end
end
