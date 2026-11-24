# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_measurement'
require_relative 'bench_record'
require 'etc'
require_relative 'boot_image'
require_relative 'error'
require_relative 'fiasco'
require_relative 'native_root'
require_relative 'qemu'
require_relative 'qemu_gate'
require_relative 'runner'
require_relative 'source_revision'

module Erx
  # The native bench images (docs/design-bench.md, "The first five benchmarks"): each
  # benchmark's image has test/guest/native_bench's root, guest.c with the benchmark's own
  # files (GUESTS), which times its native landing cells and prints a BENCH line for each
  # and one CLOCK line, which BenchMeasurement.boot judges, and the test task's program its
  # cells launch, if any. Each seeded build of a benchmark (Seed) must come back with the
  # cell its fault fails.
  module NativeBench
    MEMORY_MIB = 512
    GUEST = 'test/guest/native_bench'
    BENCH_LIBRARY = %w[bench_clock bench_hist bench_line bench_periodic].map { |name| "test/guest/bench/#{name}.c" }.freeze
    ROOT_SOURCES = [*NativeRoot::RUNTIME, *NativeRoot::VM, *NativeRoot::SERVICE, *NativeRoot::LAUNCH, *BENCH_LIBRARY,
                    "#{GUEST}/guest.c"].freeze
    TASK_SOURCES = [*NativeRoot::TASK, 'test/guest/bench/bench_hist.c'].freeze
    TASK_PATH = 'boot/native-bench-task'
    SEED_EMPTY_SLOT = '-DERX_BENCH_SEED_EMPTY_SLOT'
    # The reason of a nullcall cell whose run did not raise its task's refusal count by
    # its calls, which the root is built with (ERX_BENCH_UNCOUNTED).
    NULLCALL_UNCOUNTED = 'the decoder did not answer every call'

    # A seeded fault of a benchmark's guest: the flags its root and its task add for it, and
    # whether a boot's cells show it.
    Seed = Data.define(:name, :root_flags, :task_flags, :caught)
    # A benchmark's guest: the files of GUEST its root and its task add, and its seeds.
    Guest = Data.define(:root, :task, :seeds)

    # The cells of operation that came back failed.
    def self.failed(cells, operation) = cells.select { |cell| cell.operation == operation && cell.status == 'failed' }

    # Whether a cell of operation failed by its count of refusals.
    def self.uncounted?(cells, operation) = failed(cells, operation).any? { |cell| cell.reason == NULLCALL_UNCOUNTED }

    GUESTS = {
      # The root skips one wake: wake-same-cpu fails with a lost wake.
      'wake' => Guest.new(root: %w[wake.c], task: [], seeds: [
        Seed.new(name: 'lost wake', root_flags: ['-DERX_BENCH_SEED_LOST_WAKE'], task_flags: [],
                 caught: ->(cells) { failed(cells, 'wake-same-cpu').any? { |cell| cell.counts.fetch('lost').positive? } })
      ].freeze),
      # The requests go to the kernel cell's empty slot, from the root and then from the
      # task: the stub still answers ERX_EINVAL, but the caller's count of refusals does
      # not move.
      'nullcall' => Guest.new(root: %w[nullcall.c nullcall_time.c], task: %w[program.c nullcall_time.c], seeds: [
        Seed.new(name: 'root refusal to the empty slot', root_flags: [SEED_EMPTY_SLOT], task_flags: [],
                 caught: ->(cells) { uncounted?(cells, 'root-same-space') }),
        Seed.new(name: 'task refusal to the empty slot', root_flags: [], task_flags: [SEED_EMPTY_SLOT],
                 caught: ->(cells) { uncounted?(cells, 'root-cross-space') })
      ].freeze)
    }.freeze
    # The landing forms of the profiles the guest's cells take (docs/design-bench.md,
    # "Profiles"); the root is built with their sizes (flags).
    LANDING_PROFILES = {
      'fast' => BenchRecord::Profile.new(name: 'fast', warmup: 1000, samples: 10_000, runs: 1),
      'periodic' => BenchRecord::Profile.new(name: 'periodic', warmup: 0, samples: 2000, runs: 1)
    }.freeze
    FAILED_LINE = /^erx: bench: .* FAILED/n
    GUEST_LINE = /\A(?:BENCH|CLOCK) /n

    module_function

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       { name: 'bench-timing', pattern: /\Aerx: bench: timing/n, seconds: 60 },
       { name: 'bench-done', pattern: /\Aerx: bench: done/n, seconds: 600 }].freeze
    end

    # The BENCH and CLOCK lines of a serial log, each without its line end. They are the
    # guest's, untrusted: BenchMeasurement.boot is their one judge.
    def guest_lines(serial) = serial.b.split(/\r?\n/n).grep(GUEST_LINE)

    def guest(name) = GUESTS.fetch(name) { raise Error, "bench: #{name} has no native bench guest" }

    # The build flags of the root, or of the task: the test hooks, the landing profiles'
    # sizes, which test/guest/native_bench takes from them alone, and a seed's flags for
    # that side.
    def flags(seeded: [])
      fast, periodic = LANDING_PROFILES.values_at('fast', 'periodic')
      ['-DERX_FIASCO_TEST_HOOKS', "-DERX_BENCH_FAST_WARMUP=#{fast.warmup}u", "-DERX_BENCH_FAST_SAMPLES=#{fast.samples}u",
       "-DERX_BENCH_PERIODIC_SAMPLES=#{periodic.samples}u", "-DERX_BENCH_UNCOUNTED=\"#{NULLCALL_UNCOUNTED}\"", *seeded].freeze
    end

    # The profile each operation of benchmark ran at, in its landing form.
    def profiles(benchmark)
      benchmark.operations.transform_values { |operation| LANDING_PROFILES.fetch(operation.profile, nil) }.compact
    end

    # What a boot of the image at cpus CPUs asks of its guest: the benchmark's native
    # landing cells at their profiles, on the counter, and the one pair the root (on CPU
    # 0) times wake-cross-cpu across, with the last CPU; none on one CPU.
    def asked(benchmark, cpus:)
      BenchMeasurement::Asked.new(benchmark: benchmark, cells: benchmark.landing.fetch('native'),
                                  profiles: profiles(benchmark), clock: 'counter',
                                  pairs: cpus > 1 ? [[0, cpus - 1]] : [])
    end

    # Raises on a setup failure the guest named, which a transcript's timeout would only imply.
    def judge(serial)
      failed = FAILED_LINE.match(serial)
      raise Error, "the guest says #{failed[0].inspect}" if failed
    end

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''),
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @platform = platform
      end

      # One boot of benchmark's image, seeded with seed's fault if given, under accel at
      # cpus CPUs, with the kernel as last built unless asked to rebuild: its serial log,
      # its seconds, the guest's lines, the image's SHA-256, its root's build flags,
      # QEMU's version, and the stored log a replayed boot came from (nil for a fresh one).
      def call(benchmark, accel:, cpus:, seed: nil, build: false, jobs: 4)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        flags = NativeBench.flags(seeded: seed ? seed.root_flags : [])
        built = image(fiasco, benchmark, seed: seed, flags: flags)
        directory = File.join(@root, 'build/qemu', "bench-#{accel}-#{cpus}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
        report = boot(built, accel: accel, cpus: cpus, directory: directory)
        serial = File.binread(report.fetch('serial_log'))
        { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds'),
          lines: NativeBench.guest_lines(serial), image_sha256: report.fetch('image_sha256'), flags: flags,
          compiler: @compiler, qemu_version: report['qemu_version'], reused_from: report['reused_from'] }.freeze
      end

      private

      def boot(built, accel:, cpus:, directory:)
        Qemu.new(root: @root, runner: @runner).run(platform: @platform, accel: accel, cpus: cpus, image: built.single,
                                                   memory_mib: MEMORY_MIB, checkpoints: NativeBench.checkpoints,
                                                   machine_end: true, directory: directory)
      rescue Error => e
        serial = File.join(directory, 'serial.log')
        NativeBench.judge(File.binread(serial)) if File.file?(serial)
        raise e
      end

      def image(fiasco, benchmark, seed:, flags:)
        guest = NativeBench.guest(benchmark)
        build = File.join(@root, 'build', ['native-bench', benchmark, *(seed && ['seeded', seed.name.tr(' ', '-')])].join('-'))
        native = NativeRoot.new(root: @root, source: @root, runner: @runner, compiler: @compiler, linker: @linker,
                                platform: @platform, fiasco: fiasco)
        root_task = native.build(name: 'bench-root', sources: [*ROOT_SOURCES, *guest.root.map { |file| "#{GUEST}/#{file}" }],
                                 directory: File.join(build, 'root'), flags: flags)
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(build, 'image'), stand_in_root: root_task, programs: programs(native, guest, build, seed))
      end

      # The test task's program, for a guest whose cells launch one.
      def programs(native, guest, build, seed)
        return {} if guest.task.empty?

        { TASK_PATH => native.build_task(name: 'native-bench-task', sources: [*TASK_SOURCES, *guest.task.map { |file| "#{GUEST}/#{file}" }],
                                         directory: File.join(build, 'task'), flags: NativeBench.flags(seeded: seed ? seed.task_flags : [])) }
      end
    end

    # A benchmark's native boot of the landing matrix (docs/design-bench.md, "The gates"):
    # one boot of its image and one of each seeded build. The first boot's lines, judged
    # against what it asked, are a record, which BenchRecord.write adds to the history
    # unless the boot was replayed from the gate's store; each seeded boot's show whether
    # its fault was caught.
    class Landing
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     run: Run.new(root: root, runner: runner))
        @root = File.expand_path(root)
        @runner = runner
        @run = run
      end

      # benchmark's native cells booted as boot (a BenchSuite::Boot) says: the record, the
      # run directory written (nil for a replayed boot), the refused lines' reasons, and
      # the names of the seeds whose boots did not show their fault.
      def call(benchmark, boot:, history:)
        accel = boot.kind.delete_prefix('qemu-')
        asked = NativeBench.asked(benchmark, cpus: boot.cpus)
        revision = revision()
        model = sysctl('hw.model')
        date = Time.now.utc
        before = QemuGate.one_minute_load
        measured = @run.call(benchmark.name, accel: accel, cpus: boot.cpus)
        after = QemuGate.one_minute_load
        answer = BenchMeasurement.boot(measured.fetch(:lines), asked)
        # The record is written before the seeded boot, so a failure there does not lose it.
        record = BenchRecord::Record.new(
          environment: environment(boot, accel: accel, model: model, measured: measured),
          subject: subject(revision, measured),
          run: BenchRecord::Run.new(date: date, started_by: 'landing', load: before && after && [before, after],
                                    host_cpus: Etc.nprocessors, reused_from: measured.fetch(:reused_from)),
          clock: answer.fetch(:clock) || {}, cells: answer.fetch(:cells)
        )
        written = unless record.run.replayed?
                    BenchRecord.write(record, history: history, erxos_root: @root, boots: [{ serial: measured.fetch(:serial) }])
                  end
        missed = NativeBench.guest(benchmark.name).seeds.reject do |seed|
          seeded = @run.call(benchmark.name, accel: accel, cpus: boot.cpus, seed: seed)
          seed.caught.call(BenchMeasurement.boot(seeded.fetch(:lines), asked).fetch(:cells))
        end
        { record: record, written: written, refused: answer.fetch(:refused), seeds_missed: missed.map(&:name) }
      end

      private

      def environment(boot, accel:, model:, measured:)
        BenchRecord::Environment.new(
          kind: boot.kind, model: model, cpus: boot.cpus, system: nil,
          details: { 'memory_mib' => MEMORY_MIB, 'accelerator' => accel, 'machine' => 'virt',
                     'qemu' => measured.fetch(:qemu_version), 'host_os' => RbConfig::CONFIG['host_os'] }.compact
        )
      end

      def revision
        SourceRevision.read(root: @root, runner: @runner) ||
          raise(Error, "bench: #{@root} is not a git checkout, so a record has no revision")
      end

      def subject(revision, measured)
        BenchRecord::Subject.new(revision: revision.commit, dirty: revision.dirty,
                                 details: measured.slice(:image_sha256, :flags, :compiler).transform_keys(&:to_s))
      end

      def sysctl(name)
        result = @runner.run(['sysctl', '-n', name], name: "bench-sysctl-#{name.tr('.', '-')}", deadline: 10)
        File.binread(result.fetch('log'), 4096).strip
      end
    end
  end
end
