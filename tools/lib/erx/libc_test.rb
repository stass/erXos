# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative 'boot_image'
require_relative 'error'
require_relative 'fiasco'
require_relative 'musl'
require_relative 'native_root'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # musl's libc-test against erXos's musl (docs/design-stopgap.md, "musl's own tests"):
  # each test program is linked with musl and the task's side of liberx and runs as a
  # task of test/guest/native_libc_test's root, many to a boot. Every test ends the run with
  # one result, and none is ever guessed: only the root's end line of this boot says how a
  # test ended, and each test's program and each boot's log are made anew for the run.
  module LibcTest
    # Holds the image, and the pool every task's pages come from.
    MEMORY_MIB = 1024
    SOURCE_DIRECTORY = 'build/third_party/libc-test/libc-test-63e36e9'
    PROGRAM_PREFIX = 'boot/libc-test/'
    KINDS = %w[functional regression math musl].freeze
    # Helpers of other tests, not tests: libc-test builds them as shared objects, or links them in.
    HELPER = /_dso\z/
    # A static test's further objects, as src/functional/tls_align.mk names them.
    EXTRA_OBJECTS = { 'functional/tls_align' => ['functional/tls_align_dso'] }.freeze
    # The boot image's 16 MiB budget (test/fixtures/structural_pack.rb), less room for its kernel and root.
    BATCH_BYTES = 12 * 1024 * 1024
    TASK_SECONDS = 60
    BOOT_SECONDS = 120
    # A hung root costs this, at most. The test under way is then unknown, and the rest are not run.
    BOOT_LIMIT = 3600
    # What a test's own object calls that Phase 1 cannot give it: the first cause listed names
    # why it is not run. Phase 1's musl refuses these with ENOSYS, so each result would say
    # only that a later milestone has not come.
    NEEDS = {
      'files' => %w[open open64 openat creat fopen fopen64 freopen tmpfile tmpfile64 tmpnam tempnam mkstemp mkostemp mkdtemp
                    mkstemps stat stat64 lstat fstat fstatat fstat64 unlink unlinkat remove rename mkdir rmdir opendir fdopendir
                    fdopen pipe pipe2 dup dup2 dup3 ftw nftw chdir getcwd read pread close lseek lseek64 fcntl flock
                    ftruncate truncate access faccessat utimensat futimens futimesat link symlink readlink t_fdfill
                    glob realpath fileno],
      'processes' => %w[fork vfork _Fork wait waitpid execv execve execvp execl execle execlp posix_spawn posix_spawnp popen
                        system daemon],
      'signals' => %w[signal sigaction raise kill killpg pthread_kill pthread_sigmask sigprocmask sigsuspend sigwait sigwaitinfo
                      sigtimedwait sigaltstack alarm setitimer timer_create],
      'sockets' => %w[socket socketpair bind getaddrinfo getnameinfo gethostbyname],
      'shared objects' => %w[dlopen dlsym dlclose dladdr dl_iterate_phdr],
      'interprocess objects' => %w[shmget shmat msgget semget sem_open shm_open mq_open],
      'resource limits' => %w[t_setrlim setrlimit getrlimit],
      'a wall clock' => %w[clock_settime settimeofday adjtime]
    }.freeze

    Result = Data.define(:name, :state, :detail) do
      def to_h = { name: name, state: state.to_s, detail: detail }
    end
    Plan = Data.define(:runnable, :results)
    RUN_LINE = /\Aerx: libc-test: run (?<name>[A-Za-z0-9_.\/+-]+)\r?\z/n
    END_LINE = /\Aerx: libc-test: end (?<name>[A-Za-z0-9_.\/+-]+) (?:(?<how>status|other|launch-refused|join-refused) (?<value>-?[0-9]+)|(?<how>timeout|fault|no-program))\r?\z/n
    # The names make and the shell will read: anything else in a fetched tree or a path is refused.
    TEST_NAME = %r{\A[a-z]+/[A-Za-z0-9_+.-]+\z}
    SHELL_WORD = %r{\A[A-Za-z0-9_+.,=/:-]+\z}
    POOL_LINE = /\Aerx: libc-test: pool (?<before>[0-9]+) (?<after>[0-9]+)\r?\z/n

    module_function

    # The sources under source/src that are tests, as names like functional/argv, sorted.
    def discover(source)
      names = KINDS.flat_map do |kind|
        Dir[File.join(source, 'src', kind, '*.c')].map { |path| "#{kind}/#{File.basename(path, '.c')}" }
      end
      strange = names.grep_v(TEST_NAME)
      raise Error, "libc-test names a test oddly: #{strange.first.inspect}" unless strange.empty?

      names.reject { |name| name.match?(HELPER) }.sort
    end

    # Why a test with these undefined symbols cannot run yet, or nil. A file-free test may
    # still fail on what musl refuses, and then its own result says so.
    def cause(undefined)
      NEEDS.each do |need, symbols|
        used = symbols & undefined
        return "needs #{need}: #{used.first(4).join(', ')}" unless used.empty?
      end
      nil
    end

    # llvm-nm -u over many objects: each object's undefined symbols, by path.
    def parse_nm(text)
      current = nil
      text.each_line.with_object({}) do |line, symbols|
        line = line.strip
        if line.end_with?(':') && !line.start_with?('U ')
          current = line.chomp(':')
          symbols[current] = []
        elsif current && (match = /\AU (?<name>\S+)\z/.match(line))
          symbols[current] << match[:name]
        end
      end
    end

    # Groups programs in order, so that a boot image holds at most limit bytes of them,
    # or one program larger than that by itself, which the image's own budget then judges.
    def batches(programs, limit:)
      programs.each_with_object([]) do |(name, bytes), groups|
        groups << [[], 0] if groups.empty? || groups.last[1] + bytes > limit
        groups.last[0] << name
        groups.last[1] += bytes
      end.map(&:first)
    end

    # What the serial log of one boot says about the tests it was to run, in order.
    # machine says why the boot stopped short, if it did: how a test that started and has
    # no end went is unknown, and one never started was not run. A test's own output lies
    # between the root's lines, unchanged: the last end line for a name is the one that
    # counts. Test programs are trusted, so a program that prints such a line can fool this,
    # for itself if the boot stops before the root's line, or for an earlier test.
    def read_boot(serial, tests:, machine: nil)
      started = {}
      ended = {}
      serial.b.each_line(chomp: true) do |line|
        if (match = RUN_LINE.match(line))
          started[match[:name]] = true
        elsif (match = END_LINE.match(line))
          ended[match[:name]] = match
        end
      end
      tests.map { |name| result_of(name, ended[name], started: started.key?(name), machine: machine) }
    end

    def result_of(name, ended, started:, machine:)
      if ended
        from_end(name, ended)
      elsif started
        Result.new(name: name, state: :unknown, detail: "the machine stopped during it: #{machine || 'the boot said no more'}")
      else
        Result.new(name: name, state: :not_run, detail: "the machine stopped before it: #{machine || 'the boot said no more'}")
      end
    end

    def from_end(name, ended)
      case [ended[:how], ended[:value]&.to_i]
      in ['status', 0] then Result.new(name: name, state: :passed, detail: nil)
      in ['status', Integer => status] then Result.new(name: name, state: :failed, detail: "exit status #{status}")
      in ['fault', _] then Result.new(name: name, state: :failed, detail: 'its task faulted')
      in ['other', Integer => status] then Result.new(name: name, state: :failed, detail: "its start said #{status}")
      in ['timeout', _] then Result.new(name: name, state: :timed_out, detail: "still running after #{TASK_SECONDS} seconds")
      in ['no-program', _] then Result.new(name: name, state: :not_run, detail: 'its task came up without running the program')
      in ['launch-refused', code] then Result.new(name: name, state: :not_run, detail: "the launch said #{code}")
      in ['join-refused', code] then Result.new(name: name, state: :unknown, detail: "the join said #{code}")
      end
    end

    # The boot's pool line, as [before, after], or nil if it never came.
    def pool(serial)
      match = serial.b.each_line(chomp: true).filter_map { |line| POOL_LINE.match(line) }.last
      match && [match[:before].to_i, match[:after].to_i]
    end

    def totals(results) = results.map(&:state).tally

    class Run
      FLAGS = %w[--target=aarch64-none-elf -pipe -std=c99 -D_POSIX_C_SOURCE=200809L -D_FILE_OFFSET_BITS=64 -Wno-unused-function
                 -Wno-missing-braces -Wno-unused -Wno-overflow -Wno-unknown-pragmas -fno-builtin -frounding-math -nostdinc
                 -fno-stack-protector -mno-outline-atomics -Werror=implicit-function-declaration -Werror=implicit-int
                 -Werror=pointer-sign -Werror=pointer-arith].freeze
      COMMON = %w[fdfill memfill mtest path print rand setrlim utf8 vmfill].freeze
      TASK_SOURCES = [*(NativeRoot::TASK - ["#{NativeRoot::BACKEND}/root_mem.c"]), "#{NativeRoot::BACKEND}/libc_start.c",
                      "#{NativeRoot::BACKEND}/libc_task.c"].freeze
      ROOT_SOURCES = [*NativeRoot::RUNTIME, *NativeRoot::VM, *NativeRoot::SERVICE, *NativeRoot::LAUNCH,
                      'test/guest/native_libc_test/guest.c'].freeze

      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @build = File.join(@root, 'build/libc-test')
        @source = File.join(@root, SOURCE_DIRECTORY)
      end

      # Builds every test and runs those that can run, one image at a time, under one
      # accelerator and CPU count. only limits the run to these names. The report goes
      # to build/libc-test, and nothing in it is kept in the tree.
      def call(accel:, cpus:, jobs: 4, build: true, only: nil)
        raise Error, 'fetch libc-test first: tools/erx fetch --source libc-test' unless File.directory?(@source)

        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        tests = LibcTest.discover(@source).select { |name| only.nil? || only.include?(name) }
        planned = plan(tests, fiasco: fiasco, jobs: jobs)
        results = planned.results + boots(planned.runnable, fiasco: fiasco, accel: accel, cpus: cpus)
        report(results.sort_by(&:name), accel: accel, cpus: cpus)
      end

      private

      # Compiles and links everything by a generated Makefile, one tracked command. A test that
      # does not build, or needs what Phase 1 lacks, has its result already.
      def plan(tests, fiasco:, jobs:)
        musl = Musl.new(root: @root, runner: @runner, compiler: @compiler)
        libc = musl.build(directory: File.join(@build, 'musl'), jobs: jobs)
        native = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
        task = native.compile_all(sources: TASK_SOURCES, directory: File.join(@build, 'task'))
        archives = [libc, fiasco.user_library('libgcc.a'), fiasco.boot_core_archive, *NativeRoot::LIBRARIES.map { |name| fiasco.user_library(name) }]
        makefile = File.join(@build, 'tests.mk')
        File.write(makefile, Makefile.text(tests: tests, source: @source, output: File.join(@build, 'tests'), compiler: @compiler,
                                           linker: @linker, cflags: [*FLAGS, *musl.include_directories(directory: File.join(@build, 'musl')).flat_map { |path| ['-isystem', path] }],
                                           link_inputs: [*task], archives: archives, script: File.join(@root, NativeRoot::TASK_LINK_SCRIPT)))
        forget_programs(tests)
        run_make(makefile, jobs: jobs)
        judge(tests)
      end

      # A test that no longer links must not run its last build.
      def forget_programs(tests)
        tests.each do |name|
          base = File.join(@build, 'tests', name)
          FileUtils.rm_f(["#{base}.elf", "#{base}.elf.err"])
        end
      end

      # make's own failure is read per test: a program it did not leave has not built.
      def run_make(makefile, jobs:)
        @runner.run(['gmake', '-f', makefile, '-k', "-j#{jobs}", 'all'], name: 'libc-test-build', deadline: 1800, chdir: @root)
      rescue CommandError => e
        raise unless e.result.fetch('state') == 'failed'
      end

      def judge(tests)
        objects = tests.to_h { |name| [name, File.join(@build, 'tests', "#{name}.o")] }.select { |_name, path| File.file?(path) }
        symbols = undefined_symbols(objects.values)
        results = tests.to_h { |name| [name, verdict(name, objects[name], symbols)] }
        runnable, settled = results.partition { |_name, result| result.nil? }
        Plan.new(runnable: runnable.map(&:first), results: settled.map(&:last))
      end

      # A test's result already, or nil if it is to run.
      def verdict(name, object, symbols)
        unless object && File.file?(File.join(@build, 'tests', "#{name}.elf"))
          return Result.new(name: name, state: :failed, detail: "does not build: #{first_error(name)}")
        end

        why = LibcTest.cause(symbols.fetch(object, []))
        why && Result.new(name: name, state: :not_run, detail: why)
      end

      def undefined_symbols(objects)
        return {} if objects.empty?

        listing = @runner.run([File.join(File.dirname(@compiler), 'llvm-nm'), '-u', *objects], name: 'libc-test-nm', deadline: 120)
        LibcTest.parse_nm(File.binread(listing.fetch('log')))
      end

      # The compiler's first error, or the linker's.
      def first_error(name)
        logs = ["#{name}.err", "#{name}.elf.err"].map { |log| File.join(@build, 'tests', log) }.select { |log| File.file?(log) }
        line = logs.flat_map { |log| File.binread(log).lines }.find { |text| text.match?(/\berror\b/n) }
        line ? line.strip.sub("#{@source}/", '').scrub('?').encode('UTF-8', 'BINARY', undef: :replace, invalid: :replace) : 'no diagnostic'
      end

      def boots(tests, fiasco:, accel:, cpus:)
        sizes = tests.map { |name| [name, File.size(File.join(@build, 'tests', "#{name}.elf"))] }
        root_task = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                              .build(name: 'libc-test-root', sources: ROOT_SOURCES, directory: File.join(@build, 'root'),
                                     flags: ["-DLIBC_TEST_SECONDS=UINT64_C(#{TASK_SECONDS})"])
        LibcTest.batches(sizes, limit: BATCH_BYTES).flat_map.with_index do |batch, index|
          boot(batch, index: index, root_task: root_task, accel: accel, cpus: cpus)
        end
      end

      def boot(batch, index:, root_task:, accel:, cpus:)
        programs = batch.to_h { |name| ["#{PROGRAM_PREFIX}#{name}", File.join(@build, 'tests', "#{name}.elf")] }
        image = BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                         .build(directory: File.join(@build, "image-#{index}"), stand_in_root: root_task, programs: programs)
        directory = File.join(@build, "boot-#{accel}-#{cpus}cpu-#{index}")
        # An old log must not speak for a boot that never started.
        FileUtils.rm_rf(directory)
        # Every test may use its whole deadline; a hung machine is caught at the sum.
        points = [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
                  { name: 'libc-test-done', pattern: /\Aerx: libc-test: done/n, seconds: [BOOT_SECONDS + batch.size * TASK_SECONDS, BOOT_LIMIT].min }.freeze]
        machine = begin
          Qemu.new(root: @root, runner: @runner).run(accel: accel, cpus: cpus, image: image.single, memory_mib: MEMORY_MIB, checkpoints: points,
                                                     machine_end: true, directory: directory)
          nil
        rescue Error => e
          e.message.lines.first.to_s.strip
        end
        serial = File.join(directory, 'serial.log')
        text = File.file?(serial) ? File.binread(serial) : ''
        note_pool(index, LibcTest.pool(text))
        LibcTest.read_boot(text, tests: batch, machine: machine)
      end

      # A boot whose pool did not come back has leaked some task's pages: the report says which.
      def note_pool(index, pool)
        (@pool_leaks ||= []) << index if pool && pool.first != pool.last
      end

      def report(results, accel:, cpus:)
        path = File.join(@build, "report-#{accel}-#{cpus}cpu.json")
        leaks = @pool_leaks || []
        File.write(path, "#{JSON.pretty_generate({ pool_leaks_in_boots: leaks, results: results.map(&:to_h) })}\n")
        { report: path, totals: LibcTest.totals(results), pool_leaks_in_boots: leaks, results: results }.freeze
      end
    end

    # The tests' build as make rules: an object whose errors stay beside it, then a program.
    module Makefile
      module_function

      def text(tests:, source:, output:, compiler:, linker:, cflags:, link_inputs:, archives:, script:)
        words = [source, output, compiler, linker, *cflags, *link_inputs, *archives, script]
        strange = words.grep_v(LibcTest::SHELL_WORD)
        raise Error, "make cannot be given #{strange.first.inspect}" unless strange.empty?

        common = Run::COMMON.map { |name| object_rule("common/#{name}", source: source, output: output, compiler: compiler, cflags: cflags) }
        helpers = LibcTest::EXTRA_OBJECTS.values.flatten.map { |name| object_rule(name, source: source, output: output, compiler: compiler, cflags: cflags) }
        common_objects = Run::COMMON.map { |name| "#{output}/common/#{name}.o" }
        programs = tests.map { |name| "#{output}/#{name}.elf" }
        rules = tests.flat_map do |name|
          extra = LibcTest::EXTRA_OBJECTS.fetch(name, []).map { |helper| "#{output}/#{helper}.o" }
          inputs = ["#{output}/#{name}.o", *extra, *link_inputs]
          [object_rule(name, source: source, output: output, compiler: compiler, cflags: cflags),
           "#{output}/#{name}.elf: #{inputs.join(' ')} #{common_objects.join(' ')} #{archives.join(' ')}\n" \
           "\t#{linker} -T #{script} #{NativeRoot::TASK_LINK_FLAGS.join(' ')} -z max-page-size=4096 --strip-all -o $@ #{inputs.join(' ')} --start-group #{common_objects.join(' ')} #{archives.join(' ')} --end-group 2>$@.err\n"]
        end
        dependencies = "-include $(wildcard #{output}/*/*.d)\n"
        ["all: #{programs.join(' ')}\n", ".DELETE_ON_ERROR:\n", *common, *helpers, *rules, dependencies].join("\n")
      end

      def object_rule(name, source:, output:, compiler:, cflags:)
        "#{output}/#{name}.o: #{source}/src/#{name}.c\n" \
          "\t@mkdir -p $(dir $@)\n" \
          "\t#{compiler} #{cflags.join(' ')} -MMD -I#{source}/src/common -c $< -o $@ 2>#{output}/#{name}.err\n"
      end
    end
  end
end
