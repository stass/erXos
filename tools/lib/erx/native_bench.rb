# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'

require_relative 'bench_landing'
require_relative 'bench_measurement'
require_relative 'bench_record'
require_relative 'boot_image'
require_relative 'boot_partition'
require_relative 'build_kind'
require_relative 'error'
require_relative 'fiasco'
require_relative 'native_root'
require_relative 'native_task'
require_relative 'output_directory'
require_relative 'platform'
require_relative 'qemu'
require_relative 'runner'

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
    # The vm seed's flag, and the reason of a protect cell whose disposable task's write to
    # its read-only page did not fault, which the root is built with (ERX_BENCH_UNFAULTED).
    SEED_PROTECT_IGNORED = '-DERX_BENCH_SEED_PROTECT_IGNORED'
    VM_UNFAULTED = 'the read-only page took the write'
    # The hang seed's flag: the root spins forever once it has reported its first cell.
    SEED_HANG = '-DERX_BENCH_SEED_HANG'

    # A seeded fault of a benchmark's guest: the flags its root and its task add for it,
    # whether a boot's cells show it, and the guest's deadline its root is built with when
    # not the landing form's (nil).
    Seed = Data.define(:name, :root_flags, :task_flags, :caught, :deadline_seconds) do
      def initialize(name:, root_flags:, task_flags:, caught:, deadline_seconds: nil) = super
    end
    # A benchmark's guest: the files of GUEST its root and its task add, its seeds, and
    # whether its image packs test/guest/native_task's program, which its cells launch.
    Guest = Data.define(:root, :task, :seeds, :native_task) do
      def initialize(root:, task:, seeds:, native_task: false) = super
    end

    # The cells of operation that came back failed.
    def self.failed(cells, operation) = cells.select { |cell| cell.operation == operation && cell.status == 'failed' }

    # Whether a cell of operation failed by its count of refusals.
    def self.uncounted?(cells, operation) = failed(cells, operation).any? { |cell| cell.reason == NULLCALL_UNCOUNTED }

    # Whether a boot's first cell was reported and then the guest's deadline ended it: that
    # cell rejected, since no CLOCK line followed it, and every later one timed_out.
    def self.hung_after_first?(cells)
      first, *rest = cells
      first&.status == 'rejected' && !rest.empty? && rest.all? { |cell| cell.status == 'timed_out' }
    end

    GUESTS = {
      # share-equal's spinners are native_task's MODE_SHARE.
      'sched' => Guest.new(root: %w[sched.c], task: [], seeds: [].freeze, native_task: true),
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
                 caught: ->(cells) { uncounted?(cells, 'root-cross-space') }),
        # The guest's deadline ends the hung boot, so short that the seed costs little.
        Seed.new(name: 'hang after the first cell', root_flags: [SEED_HANG], task_flags: [],
                 caught: ->(cells) { hung_after_first?(cells) }, deadline_seconds: 20)
      ].freeze),
      # The task's protects answer ERX_OK without calling the service: no read sees it, but
      # the disposable task's write to its read-only page goes through, and protect fails.
      'vm' => Guest.new(root: %w[vm.c], task: %w[vm_task.c], seeds: [
        Seed.new(name: 'protect ignored', root_flags: [], task_flags: [SEED_PROTECT_IGNORED],
                 caught: ->(cells) { failed(cells, 'protect').any? { |cell| cell.reason == VM_UNFAULTED } })
      ].freeze)
    }.freeze
    # The landing forms of the profiles the guest's cells take (docs/design-bench.md,
    # "Profiles"); the root is built with their sizes (flags).
    LANDING_PROFILES = {
      'fast' => BenchRecord::Profile.new(name: 'fast', warmup: 1000, samples: 10_000, runs: 1),
      'periodic' => BenchRecord::Profile.new(name: 'periodic', warmup: 0, samples: 2000, runs: 1),
      # Three 1 s windows after a 2 s warm-up, in milliseconds (docs/design-bench.md, "Profiles").
      'sustained' => BenchRecord::Profile.new(name: 'sustained', warmup: 2000, samples: 3, runs: 1)
    }.freeze
    # The guest's deadline in the landing form, from the start of its cells
    # (docs/design-bench.md, "The guest's deadline"), which the root is built with (flags);
    # QEMU's deadline for the boot's end is DEADLINE_MARGIN_SECONDS more, so a hung cell is
    # ended by the guest first.
    LANDING_DEADLINE_SECONDS = 540
    DEADLINE_MARGIN_SECONDS = 60
    # The word the root takes its boot's name from (docs/design-bench.md, "The boot name").
    NAME_WORD = 'erx.arg='
    # Under QEMU each boot has a console of its own, so every boot takes this one name
    # (docs/design-bench.md, "The boot name"), on its command line.
    QEMU_BOOT_NAME = '0' * 32
    QEMU_COMMAND_LINE = "#{NAME_WORD}#{QEMU_BOOT_NAME}".freeze
    # The root's naming line at its end, done or deadline, as one line of the serial log,
    # with or without its line end: QEMU's bench-done checkpoint and timed_out's one pattern.
    END_LINE = /\Aerx: bench: boot [0-9a-f]{32} (?<form>done|deadline)\r*$/n
    FAILED_LINE = /^erx: bench: .* FAILED/n
    # The machine's end, the boot's last line (docs/design-bench.md, "The end").
    MACHINE_END_LINE = /^erx: end (?<how>[a-z]+)\r*$/n
    # The root's naming line in any of its forms, with its name and its end form (nil
    # for a plain naming line); a line with its head
    # and anything else after it is a broken one.
    NAMING_HEAD = /\Aerx: bench: boot /n
    NAMING_LINE = /\Aerx: bench: boot (?<name>[0-9a-f]{32})(?: (?<form>done|deadline))?\r*\z/n
    GUEST_LINE = /\A(?:BENCH|CLOCK|WINDOW) /n

    module_function

    # The boot's checkpoints, its end the root's naming line in either end form, due within
    # the guest's deadline (deadline_seconds) and the margin.
    def checkpoints(deadline_seconds:)
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       { name: 'bench-timing', pattern: /\Aerx: bench: timing/n, seconds: 60 },
       { name: 'bench-done', pattern: END_LINE, seconds: deadline_seconds + DEADLINE_MARGIN_SECONDS }].freeze
    end

    # Why the boot of serial timed out: the guest ended it at its deadline; nil when it
    # ended done.
    def timed_out(serial)
      ended = serial.b.each_line.lazy.filter_map { |line| END_LINE.match(line) }.first
      "the guest's deadline ended the boot" if ended && ended[:form] == 'deadline'
    end

    # The cells a run of the image (Run#call) reports for asked: those of a boot the guest
    # ended at its deadline that it did not report are timed_out.
    def cells(run, asked) = BenchMeasurement.boot(run.fetch(:lines), asked, timed_out: !run[:timed_out].nil?).fetch(:cells)

    # The BENCH and CLOCK lines of a serial log, each without its line end. They are the
    # guest's, untrusted: BenchMeasurement.boot is their one judge.
    def guest_lines(serial) = serial.b.split(/\r?\n/n).grep(GUEST_LINE)

    def guest(name) = GUESTS.fetch(name) { raise Error, "bench: #{name} has no native bench guest" }

    # The build flags of the root, or of the task: the test hooks, the landing profiles'
    # sizes and the guest deadline, which test/guest/native_bench takes from them alone,
    # and a seed's flags for that side.
    def flags(seeded: [], deadline_seconds: LANDING_DEADLINE_SECONDS)
      ['-DERX_FIASCO_TEST_HOOKS', *profile_flags, "-DERX_BENCH_UNCOUNTED=\"#{NULLCALL_UNCOUNTED}\"",
       "-DERX_BENCH_UNFAULTED=\"#{VM_UNFAULTED}\"", "-DERX_BENCH_DEADLINE_S=#{deadline_seconds}u", *seeded].freeze
    end

    # The landing profiles' sizes as -D flags, which every bench guest's C, and the peer
    # bench's, takes from them alone.
    def profile_flags
      fast, periodic, sustained = LANDING_PROFILES.values_at('fast', 'periodic', 'sustained')
      ["-DERX_BENCH_FAST_WARMUP=#{fast.warmup}u", "-DERX_BENCH_FAST_SAMPLES=#{fast.samples}u",
       "-DERX_BENCH_PERIODIC_SAMPLES=#{periodic.samples}u", "-DERX_BENCH_SUSTAINED_SAMPLES=#{sustained.samples}u",
       "-DERX_BENCH_SUSTAINED_WARMUP_MS=#{sustained.warmup}u"].freeze
    end

    # The profile each operation of benchmark ran at, in its landing form.
    def profiles(benchmark)
      benchmark.operations.transform_values { |operation| LANDING_PROFILES.fetch(operation.profile, nil) }.compact
    end

    # What a landing boot asks of benchmark: cells, its cells in boot unless given, at
    # their landing profiles.
    def wanted(benchmark, boot:, cells: benchmark.landing.fetch(boot))
      BenchMeasurement::Wanted.new(benchmark: benchmark, cells: cells, profiles: profiles(benchmark))
    end

    # What a boot of the image at cpus CPUs asks of its guest: cells, the benchmark's
    # native landing cells unless given, at their profiles, on the counter, and the one
    # pair the root (on CPU 0) times wake-cross-cpu across, with the last CPU; none on
    # one CPU.
    def asked(benchmark, cpus:, cells: benchmark.landing.fetch('native'))
      BenchMeasurement::Asked.new(benchmarks: [wanted(benchmark, boot: 'native', cells: cells)], clock: 'counter',
                                  pairs: cpus > 1 ? [[0, cpus - 1]] : [])
    end

    # The guest's deadline a root is built with: seed's own, if it has one, or the landing
    # form's; QEMU's deadline for the boot's end is DEADLINE_MARGIN_SECONDS more.
    def deadline_seconds(seed) = seed&.deadline_seconds || LANDING_DEADLINE_SECONDS

    # Raises on a setup failure the guest named, which a transcript's timeout would only imply.
    def judge(serial)
      failed = FAILED_LINE.match(serial)
      raise Error, "the guest says #{failed[0].inspect}" if failed
    end

    # Raises unless the boot of serial ended the machine with a reset, as every end of the
    # bench root does: a board's boot that ends off has halted the board.
    def check_end(serial)
      how = serial.b.scan(MACHINE_END_LINE).last&.first
      return if how == 'reset'
      raise Error, 'the boot did not end the machine' if how.nil?

      raise Error, "the boot ended with erx: end #{how}: the board halts there, and its power needs cycling"
    end

    # The lines of serial that break its naming (docs/design-bench.md, "The boot name"):
    # a naming line that is broken or carries another name than name, and a BENCH or
    # CLOCK line without a naming line before and after it, which is every one of them
    # when there is no naming line.
    def misnamed_lines(serial, name:)
      lines = serial.b.split(/\r?\n/n)
      named = lines.each_index.select { |index| NAMING_HEAD.match?(lines[index]) }
      return lines.grep(GUEST_LINE) if named.empty?

      others = named.map { |index| lines[index] }.reject { |line| NAMING_LINE.match(line)&.[](:name) == name }
      outside = lines.each_index.select { |index| GUEST_LINE.match?(lines[index]) && !(named.first < index && index < named.last) }
      others + outside.map { |index| lines[index] }
    end

    # An entry's cmdline.txt: its set's line followed by the name's word, or that word
    # alone when the set has no line, with no newline (docs/design-bench.md, "The boot name").
    def entry_command_line(set_line, name)
      raise Error, "bench: #{name.inspect} is not a boot name" unless name.match?(/\A[0-9a-f]{32}\z/)

      [set_line.to_s.chomp, "#{NAME_WORD}#{name}"].reject(&:empty?).join(' ')
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
        fiasco.build_for(@platform, jobs: jobs) if build
        deadline = NativeBench.deadline_seconds(seed)
        flags = NativeBench.flags(seeded: seed ? seed.root_flags : [], deadline_seconds: deadline)
        built = image(fiasco, benchmark, seed: seed, flags: flags)
        directory = File.join(@root, 'build/qemu', "bench-#{accel}-#{cpus}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
        report = boot(built, accel: accel, cpus: cpus, directory: directory, deadline_seconds: deadline)
        serial = File.binread(report.fetch('serial_log'))
        NativeBench.check_end(serial)
        { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds'),
          lines: NativeBench.guest_lines(serial), image_sha256: report.fetch('image_sha256'), flags: flags,
          compiler: @compiler, qemu_version: report['qemu_version'], reused_from: report['reused_from'],
          timed_out: NativeBench.timed_out(serial) }.freeze
      end

      # benchmark's image for the run's platform, seeded with seed's fault if given, its
      # root built with flags: the boot image (BootImage::Built). BoardSets builds its sets'
      # images through it.
      def image(fiasco, benchmark, seed:, flags:)
        guest = NativeBench.guest(benchmark)
        build = File.join(@root, 'build', ['native-bench', *board_part, benchmark, *(seed && ['seeded', seed.name.tr(' ', '-')])].join('-'))
        native = NativeRoot.new(root: @root, source: @root, runner: @runner, compiler: @compiler, linker: @linker,
                                platform: @platform, fiasco: fiasco)
        root_task = native.build(name: 'bench-root', sources: [*ROOT_SOURCES, *guest.root.map { |file| "#{GUEST}/#{file}" }],
                                 directory: File.join(build, 'root'), flags: flags)
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @platform)
                 .build(directory: File.join(build, 'image'), stand_in_root: root_task, programs: programs(native, guest, build, seed))
      end

      private

      # A board's builds are apart from QEMU virt's, which take the development platform.
      def board_part = @platform.name == Platform::DEVELOPMENT_NAME ? [] : [@platform.name]

      def boot(built, accel:, cpus:, directory:, deadline_seconds:)
        Qemu.new(root: @root, runner: @runner).run(platform: @platform, accel: accel, cpus: cpus, image: built.single,
                                                   memory_mib: MEMORY_MIB, command_line: QEMU_COMMAND_LINE,
                                                   checkpoints: NativeBench.checkpoints(deadline_seconds: deadline_seconds),
                                                   machine_end: true, directory: directory)
      rescue Error => e
        serial = File.join(directory, 'serial.log')
        NativeBench.judge(File.binread(serial)) if File.file?(serial)
        raise e
      end

      # The test task's program, for a guest whose cells launch one.
      def programs(native, guest, build, seed)
        if guest.native_task
          return { NativeTask::PROGRAM_PATH => native.build_task(name: 'native-task', sources: NativeTask::PROGRAM_SOURCES,
                                                                 directory: File.join(build, 'task'),
                                                                 flags: ['-DERX_FIASCO_TEST_HOOKS']) }
        end
        return {} if guest.task.empty?

        { TASK_PATH => native.build_task(name: 'native-bench-task', sources: [*TASK_SOURCES, *guest.task.map { |file| "#{GUEST}/#{file}" }],
                                         directory: File.join(build, 'task'), flags: NativeBench.flags(seeded: seed ? seed.task_flags : [])) }
      end
    end

    # The board's sets (docs/design-bench.md, "The bench image's boot set"): each distinct
    # benchmark's native bench image built for platform, a board whose medium is a boot
    # partition, and laid out once as that partition's files and their build record in
    # build/bench-board/<benchmark>/, which every entry of the set is made from.
    class BoardSets
      DIRECTORY = 'build/bench-board'
      # A laid-out set: its files and record (BootPartition::WrittenSet), its image
      # (BootImage::Built), whose identity its banner names, and the guest's deadline its
      # root is built with.
      Laid = Data.define(:set, :image, :deadline_seconds)

      def initialize(root:, platform:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        raise Error, "bench: #{platform.name} boots no boot partition" unless BootPartition.boot_partition_medium?(platform)

        @root = File.expand_path(root)
        @platform = platform
        @runner = runner
        @compiler = compiler
        @linker = linker
        @run = Run.new(root: @root, runner: runner, compiler: compiler, linker: linker, platform: platform)
      end

      # Each distinct benchmark name of benchmarks to its Laid set, the kernel built for
      # the platform first; seed's root flags, if given, are a seeded build's
      # (docs/design-bench.md, "Verification").
      def call(benchmarks, seed: nil, jobs: 4)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build_for(@platform, jobs: jobs)
        deadline = NativeBench.deadline_seconds(seed)
        flags = NativeBench.flags(seeded: seed ? seed.root_flags : [], deadline_seconds: deadline)
        benchmarks.uniq.to_h { |benchmark| [benchmark, lay_out(fiasco, benchmark, seed: seed, flags: flags, deadline: deadline)] }
      end

      private

      def lay_out(fiasco, benchmark, seed:, flags:, deadline:)
        image = @run.image(fiasco, benchmark, seed: seed, flags: flags)
        directory = OutputDirectory.fresh(root: @root, path: File.join(@root, DIRECTORY,
                                                                      [benchmark, *(seed && ['seeded', seed.name.tr(' ', '-')])].join('-')))
        set = BootPartition.lay_out_set(root: @root, runner: @runner, platform: @platform, build_kind: BuildKind::DEVELOPMENT,
                                        bootable: image.single, directory: directory, compiler: @compiler, linker: @linker)
        Laid.new(set: set, image: image, deadline_seconds: deadline)
      end
    end

    # erXos's guest for the native boot (BenchSystem): the native bench image, which
    # times every native cell and prints their BENCH lines and one CLOCK line, judged by
    # BenchMeasurement.boot against the cells asked. It boots in one CPU and in the
    # landing boot's count, and its root is built with the landing profiles only.
    class Guest
      def initialize(run:)
        @run = run
      end

      def system = 'erxos'
      def boot = 'native'
      def forms(cpus) = [1, cpus]
      def offers?(profile) = profile == 'landing'

      def call(benchmark, cells:, cpus:, accel:)
        measured = @run.call(benchmark.name, accel: accel, cpus: cpus)
        answer = BenchMeasurement.boot(measured.fetch(:lines), NativeBench.asked(benchmark, cpus: cpus, cells: cells))
        BenchLanding.booted(measured, answer, memory_mib: MEMORY_MIB)
      end
    end

    # A benchmark's native boot of the landing matrix (docs/design-bench.md, "The gates"):
    # one boot of its image, recorded (BenchLanding), and one of each seeded build, whose
    # lines show whether its fault was caught. The record is written before the seeded
    # boots, so a failure there does not lose it.
    class Landing
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     run: Run.new(root: root, runner: runner))
        @landing = BenchLanding.new(root: root, runner: runner)
        @run = run
      end

      # benchmark's native cells booted as boot (a BenchSuite::Boot) says: the record, the
      # run directory written (nil for a replayed boot), the refused lines' reasons, the
      # boot's timed_out (the guest's deadline's reason, or nil for a boot that ended
      # done; one past QEMU's deadline raises), and the
      # names of the seeds whose boots did not show their fault.
      def call(benchmark, boot:, history:)
        asked = NativeBench.asked(benchmark, cpus: boot.cpus)
        recorded = @landing.call(asked, boot: boot, memory_mib: MEMORY_MIB, history: history) do |accel|
          @run.call(benchmark.name, accel: accel, cpus: boot.cpus)
        end
        accel = boot.kind.delete_prefix('qemu-')
        missed = NativeBench.guest(benchmark.name).seeds.reject do |seed|
          seeded = @run.call(benchmark.name, accel: accel, cpus: boot.cpus, seed: seed)
          seed.caught.call(NativeBench.cells(seeded, asked))
        end
        recorded.merge(seeds_missed: missed.map(&:name))
      end
    end
  end
end
