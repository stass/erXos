# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'error'
require_relative 'bounded_file'
require_relative 'dependencies'
require_relative 'json_input'
require_relative 'output_directory'
require_relative 'runner'

module Erx
  # The command shell's oracle: Plan 9's rc as plan9port carries it, built for
  # the development host from the pinned source (deps.lock, id `plan9port`) and
  # run on a script with a controlled environment (design-shell.md,
  # "The command shell against rc").
  #
  # Build compiles rc and the lib9 members it links with this module's own
  # compiler argument vectors; plan9port's INSTALL script, mkfiles and 9c/9l
  # wrappers never run. Oracle runs one script and returns what rc wrote and
  # the `$status` it ended with as a Result value; nothing rc writes is printed.
  module RcOracle
    SOURCE_ID = 'plan9port'
    OUTPUT = 'build/rc-oracle'
    STAMP = 'build.json'

    class MissingSource < Error; end
    class MissingBuild < Error; end
    class StaleBuild < Error; end

    # One run of rc. state is :completed when rc exited and reported its final
    # `$status` (status is then the rc list as an Array of Strings, [''] for
    # success); :exited when rc exited without a status report (status nil);
    # :timed_out when the deadline killed it (status and exit_status nil);
    # :output_limit when rc's output passed Oracle::MAX_OUTPUT_BYTES (the
    # output is cut there, status and exit_status nil); and
    # :signalled when a signal ended it (signal holds its number). stdout and
    # stderr are the bytes rc and its children wrote, unescaped, never printed.
    Result = Data.define(:state, :stdout, :stderr, :status, :exit_status, :signal) do
      # One line for a person, every byte from rc escaped.
      def describe
        detail = case state
                 when :completed then "status #{status.map { |word| Terminal.escape(word.inspect) }.join(' ')}"
                 when :exited then "exit #{exit_status}, no status report"
                 when :timed_out then 'killed at its deadline'
                 when :output_limit then 'output cut at its limit'
                 when :signalled then "signal #{signal}"
                 end
        "rc oracle: #{state}: #{detail}; #{stdout.bytesize} bytes out, #{stderr.bytesize} bytes error"
      end
    end

    module_function

    # The lock entry, read whole and checked by DependencySchema.
    def source_record(root:)
      DependencySchema.parse(File.binread(File.join(root, 'deps.lock')))
                      .find { |source| source.fetch('id') == SOURCE_ID } ||
        raise(Error, "deps.lock has no #{SOURCE_ID} source")
    end

    # Words of an rc list as `whatis` prints its value: `()`, one word, or a
    # parenthesised list; a word is bare or single-quoted with '' for a quote.
    # nil when the text is not that shape.
    WORD = /\G(?:'((?:[^']|'')*)'|([^\s'()]+))(?: |\z)/
    def parse_list(text)
      listed = text.start_with?('(') && text.end_with?(')')
      inner = listed ? text[1...-1] : text
      words = []
      position = 0
      while position < inner.length
        match = WORD.match(inner, position)
        return nil unless match

        words << (match[1] ? match[1].gsub("''", "'") : match[2])
        position = match.end(0)
      end
      listed || words.length == 1 ? words : nil
    end

    # Plan 9 rc's quoting: one quote rule, a quote doubled inside quotes.
    def quote(word) = "'#{word.gsub("'", "''")}'"

    # The oracle in build/rc-oracle, refused when it is missing or was built
    # from another pin of plan9port. A build record that does not parse says
    # nothing of what was built, so it is stale too, and a rebuild replaces it.
    def locate(root:)
      output = File.join(File.expand_path(root), OUTPUT)
      stamp_path = File.join(output, STAMP)
      unless File.file?(File.join(output, 'rc')) && File.file?(stamp_path)
        raise MissingBuild, "rc oracle is not built: #{output}/rc is missing; run tools/erx build rc-oracle"
      end

      stamp = begin
        JsonInput.parse(BoundedFile.read(stamp_path, maximum: 65_536), max_bytes: 65_536,
                        label: 'rc oracle build record')
      rescue Error => e
        raise StaleBuild, "rc oracle in #{output} has an unreadable build record (#{e.message}); " \
                          'run tools/erx build rc-oracle'
      end
      unless stamp.is_a?(Hash) && stamp['source'] == source_record(root: root) && stamp['recipe'] == Build::RECIPE
        raise StaleBuild, "rc oracle in #{output} was built from another source or recipe; run tools/erx build rc-oracle"
      end

      Oracle.new(rc: File.join(output, 'rc'), rcmain: File.join(output, 'rcmain'))
    end

    # Runs scripts under one built rc. rc reads rcmain, plan9port's start-up
    # script, from the build output instead of $PLAN9.
    class Oracle
      DEFAULT_PATH = %w[/bin /usr/bin].freeze
      # Fixed, empty and present on macOS and FreeBSD alike.
      DEFAULT_HOME = '/var/empty'
      DEFAULT_DEADLINE = 10
      MAX_SCRIPT_BYTES = 1024 * 1024
      MAX_OUTPUT_BYTES = 4 * 1024 * 1024
      MAX_STATUS_BYTES = 64 * 1024
      POLL_SECONDS = 0.01
      # The exit trap reports the final $status on descriptor 3 and gives it
      # back for the exit: an assignment resets $status, so the value is
      # copied first. `builtin whatis` is rc's own, so neither $path nor a
      # function the script defines changes the report. The script is
      # sourced with descriptor 3 closed (`>[3=]`), so neither it nor any
      # program it starts while it runs can write to the channel. rc runs the
      # exit trap with every redirection undone, so a script that replaces
      # sigexit with one writing this report line to descriptor 3 could forge
      # it; the corpus is trusted text, and a replaced trap that does not
      # leaves no report.
      STATUS_VARIABLE = 'erx_oracle_status'
      STATUS_TRAP = "fn sigexit { #{STATUS_VARIABLE}=$status; builtin whatis #{STATUS_VARIABLE} >[1=3]; " \
                    "status=$#{STATUS_VARIABLE} }"
      STATUS_LINE = /\A#{STATUS_VARIABLE}=(.*)\n\z/m
      # The script's copy as rc names it, relative to the working directory.
      SCRIPT = '../script.rc'

      attr_reader :rc, :rcmain

      def initialize(rc:, rcmain:)
        @rc = File.expand_path(rc)
        @rcmain = File.expand_path(rcmain)
        raise MissingBuild, "rc oracle program is missing: #{@rc}" unless File.file?(@rc) && File.executable?(@rc)
        raise MissingBuild, "rc oracle rcmain is missing: #{@rcmain}" unless File.file?(@rcmain)
      end

      # Runs script with $path, $home, an empty private directory as its
      # working directory, standard input at end of file, and a deadline in
      # seconds. A script that defines its own sigexit, or ends rc by exec,
      # leaves no status report and comes back :exited. The script is sourced
      # as ../script.rc from that directory, so $0 and rc's messages name the
      # same file on every run. rc exports every variable, so programs see the
      # trap as fn#sigexit; the command itself is cleared from $cflag.
      def run(script, path: DEFAULT_PATH, home: DEFAULT_HOME, deadline: DEFAULT_DEADLINE)
        validate_environment(path: path, home: home, deadline: deadline)
        isolated(script) do |_copy, directory|
          execute(['-c', "#{STATUS_TRAP}; cflag=(); . #{SCRIPT} >[3=]"],
                  directory: directory, env: { 'PATH' => path.join(':'), 'HOME' => home }, deadline: deadline)
        end
      end

      # rc's -D: the tree each command parses to, on standard error, without
      # running the script; parser :yacc adds -Y, rc's yacc grammar in place
      # of its hand-written parser. plan9port's checkparse compares the two.
      def parse(script, parser: :hand, deadline: DEFAULT_DEADLINE)
        flags = { hand: ['-D'], yacc: ['-D', '-Y'] }.fetch(parser) { raise Error, "unknown rc parser: #{parser}" }
        validate_environment(path: DEFAULT_PATH, home: DEFAULT_HOME, deadline: deadline)
        isolated(script) do |_copy, directory|
          execute([*flags, SCRIPT], directory: directory,
                  env: { 'PATH' => DEFAULT_PATH.join(':'), 'HOME' => DEFAULT_HOME }, deadline: deadline)
        end
      end

      private

      def validate_environment(path:, home:, deadline:)
        unless deadline.is_a?(Numeric) && deadline.between?(1, 600)
          raise Error, 'rc oracle deadline must be 1 to 600 seconds'
        end
        unless path.is_a?(Array) && path.all? { |entry| absolute_name?(entry) && !entry.include?(':') }
          raise Error, 'rc oracle $path must be absolute directories without a colon'
        end
        raise Error, 'rc oracle $home must be an absolute path' unless absolute_name?(home)
      end

      def absolute_name?(value)
        value.is_a?(String) && value.start_with?('/') && !value.include?("\0") && value.valid_encoding?
      end

      # A private directory holds the script's copy and rc's output files; its
      # empty subdirectory `cwd` is the working directory.
      def isolated(script)
        bytes = BoundedFile.read(script, maximum: MAX_SCRIPT_BYTES)
        Dir.mktmpdir('erx-rc-oracle-') do |directory|
          copy = File.join(directory, 'script.rc')
          File.open(copy, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
          Dir.mkdir(File.join(directory, 'cwd'), 0o700)
          yield copy, directory
        end
      end

      # Output past MAX_OUTPUT_BYTES is cut by the file-size limit, one byte
      # above it so that a cut is seen: such a run is :output_limit, never a
      # result, since rc's own messages about the limit are in its output.
      def execute(arguments, directory:, env:, deadline:)
        files = %w[stdout stderr status].to_h { |name| [name, File.join(directory, name)] }
        status = spawn_and_wait(arguments, directory: directory, env: env, files: files, deadline: deadline)
        stdout, stderr = %w[stdout stderr].map { |name| BoundedFile.read(files.fetch(name), maximum: MAX_OUTPUT_BYTES + 1) }
        if [stdout, stderr].any? { |bytes| bytes.bytesize > MAX_OUTPUT_BYTES }
          Result.new(state: :output_limit, stdout: stdout.byteslice(0, MAX_OUTPUT_BYTES),
                     stderr: stderr.byteslice(0, MAX_OUTPUT_BYTES), status: nil, exit_status: nil, signal: nil)
        elsif status.nil?
          Result.new(state: :timed_out, stdout: stdout, stderr: stderr, status: nil, exit_status: nil, signal: nil)
        elsif status.signaled?
          Result.new(state: :signalled, stdout: stdout, stderr: stderr, status: nil, exit_status: nil,
                     signal: status.termsig)
        else
          reported = reported_status(files.fetch('status'))
          Result.new(state: reported ? :completed : :exited, stdout: stdout, stderr: stderr, status: reported,
                     exit_status: status.exitstatus, signal: nil)
        end
      end

      # rc's Process::Status, or nil when the deadline killed it. rc leads its
      # own process group, so the deadline and the clean-up after it reach
      # every program it started that stayed in the group.
      def spawn_and_wait(arguments, directory:, env:, files:, deadline:)
        outputs = files.transform_values { |path| File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) }
        pid = Process.spawn(env, [@rc, 'rc'], '-m', @rcmain, *arguments,
                            chdir: File.join(directory, 'cwd'), unsetenv_others: true, in: File::NULL,
                            out: outputs.fetch('stdout'), err: outputs.fetch('stderr'), 3 => outputs.fetch('status'),
                            pgroup: true, close_others: true,
                            rlimit_fsize: [MAX_OUTPUT_BYTES + 1, MAX_OUTPUT_BYTES + 1], rlimit_core: [0, 0])
        outputs.each_value(&:close)
        stop_at = monotonic + deadline
        loop do
          waited = Process.waitpid2(pid, Process::WNOHANG)
          return waited.last if waited
          break if monotonic >= stop_at

          sleep(POLL_SECONDS)
        end
        # A run that ended between the last poll and the deadline keeps its result.
        waited = Process.waitpid2(pid, Process::WNOHANG)
        return waited.last if waited

        kill_group(pid)
        Process.waitpid2(pid)
        pid = nil
        nil
      ensure
        outputs&.each_value { |file| file.close unless file.closed? }
        if pid
          kill_group(pid)
          reap(pid)
        end
      end

      # After an interrupt rc may not have been reaped; after a normal exit it was.
      def reap(pid)
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end

      # macOS reports a group whose members have all exited as EPERM.
      def kill_group(pid)
        Process.kill('KILL', -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def reported_status(path)
        return nil if File.size(path) > MAX_STATUS_BYTES

        bytes = BoundedFile.read(path, maximum: MAX_STATUS_BYTES)
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        return nil unless text.valid_encoding? && (match = STATUS_LINE.match(text))

        RcOracle.parse_list(match[1])&.freeze
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Compiles rc for the host from the fetched plan9port tree into
    # build/rc-oracle: the lib9 members rc links, rc's sources and the parser
    # the host's yacc makes from syn.y, linked by the host compiler driver.
    # The member list is what rc pulls from lib9 on macOS (read from the
    # linker's map); a missing member fails the link, never the run.
    class Build
      # The recipe is this file: any change to it, the lists and flags below
      # or the steps that use them, makes an older build stale.
      RECIPE = Digest::SHA256.file(__FILE__).hexdigest.freeze
      LIB9 = %w[
        _p9dir argv0 atexit atoi await dirfstat dirstat dup errstr fmtlock2 get9root getenv jmp main malloc
        mallocz notify open pipe postnote qlock readn rfork strdup strecpy sysfatal tokenize unsharp wait write
        fmt/dofmt fmt/fltfmt fmt/fmt fmt/fmtfd fmt/fmtfdflush fmt/fmtlocale fmt/fprint fmt/nan64 fmt/snprint
        fmt/sprint fmt/strtod fmt/vfprint fmt/vseprint fmt/vsnprint
        utf/rune utf/utflen utf/utfrune
      ].freeze
      # rc's OFILES in src/cmd/rc/mkfile, less y.tab, which yacc makes.
      RC = %w[code exec getflags glob here io lex parse pcmd pfnc simple subr trap tree unixcrap var plan9ish
              havefork].freeze
      # 9c's clang flags for macOS, without debugging information.
      CFLAGS = %w[-DPLAN9PORT -O2 -Wall -Wno-parentheses -Wno-missing-braces -Wno-switch -Wno-comment
                  -Wno-sign-compare -Wno-unknown-pragmas -Wno-empty-body -Wno-unused-value -Wno-array-bounds
                  -Wno-gnu-designator -Wno-unneeded-internal-declaration -Wno-deprecated-pragma
                  -Wno-unused-but-set-variable -Wno-deprecated-non-prototype -fsigned-char
                  -fno-caret-diagnostics -fno-common].freeze
      # get9root's fallback when $PLAN9 is unset: plan9port's own default.
      PLAN9_TARGET = '/usr/local/plan9'
      DEADLINE = 300

      def initialize(root:, runner:, compiler: ENV.fetch('CC', 'cc'), yacc: 'yacc')
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @yacc = yacc
      end

      def call
        source = RcOracle.source_record(root: @root)
        tree = source_tree(source)
        build = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build'))
        Dir.mktmpdir('.rc-oracle-', build) do |work|
          output = File.join(work, 'out')
          %w[gen lib9 rc out].each { |name| Dir.mkdir(File.join(work, name)) }
          generate_parser(tree, gen: File.join(work, 'gen'))
          lib9 = compile(LIB9.map { |member| File.join(tree, 'src/lib9', "#{member}.c") },
                         directory: File.join(work, 'lib9'), name: 'rc-oracle-lib9',
                         includes: [File.join(tree, 'include'), File.join(tree, 'src/lib9/fmt')],
                         defines: ["-DPLAN9_TARGET=\"#{PLAN9_TARGET}\""])
          rc = compile([*RC.map { |name| File.join(tree, 'src/cmd/rc', "#{name}.c") }, File.join(work, 'gen/y.tab.c')],
                       directory: File.join(work, 'rc'), name: 'rc-oracle-rc',
                       includes: [File.join(tree, 'include'), File.join(work, 'gen'), File.join(tree, 'src/cmd/rc')])
          @runner.run([@compiler, '-o', File.join(output, 'rc'), *rc, *lib9],
                      name: 'rc-oracle-link', deadline: DEADLINE, chdir: work)
          FileUtils.cp(File.join(tree, 'rcmain'), File.join(output, 'rcmain'))
          stamp = { 'source' => source, 'recipe' => RECIPE, 'compiler' => compiler_identity(work) }
          File.write(File.join(output, STAMP), JSON.pretty_generate(stamp) + "\n")
          publish(output)
        end
        RcOracle.locate(root: @root)
      end

      private

      # The fetched tree, accepted only with the provenance record that
      # Dependencies#publish wrote for this pin.
      def source_tree(source)
        parent = File.join(@root, 'build/third_party', SOURCE_ID)
        marker = File.join(parent, '.source.json')
        tree = File.join(parent, source.fetch('directory'))
        unless File.file?(marker) && !File.symlink?(parent) && File.directory?(tree)
          raise MissingSource, "plan9port source is not fetched: #{parent}; run tools/erx fetch --source #{SOURCE_ID}"
        end
        recorded = JsonInput.parse(BoundedFile.read(marker, maximum: 65_536), max_bytes: 65_536,
                                   label: 'source download record')
        raise MissingSource, "#{parent} holds another pin of plan9port; run tools/erx fetch --source #{SOURCE_ID}" unless recorded == source

        tree
      end

      # The host's POSIX yacc writes y.tab.c and y.tab.h into gen; rc's
      # sources include the header as x.tab.h, which its mkfile copies.
      def generate_parser(tree, gen:)
        @runner.run([@yacc, '-d', File.join(tree, 'src/cmd/rc/syn.y')], name: 'rc-oracle-yacc',
                    deadline: DEADLINE, chdir: gen)
        FileUtils.cp(File.join(gen, 'y.tab.h'), File.join(gen, 'x.tab.h'))
      end

      # One compiler run for a set of sources; each object lands in directory
      # under its source's base name, which the member lists keep unique.
      def compile(sources, directory:, name:, includes:, defines: [])
        names = sources.map { |source| File.basename(source, '.c') }
        raise Error, "rc oracle sources share an object name: #{name}" unless names.uniq.length == names.length

        @runner.run([@compiler, '-c', *CFLAGS, *defines, *includes.map { |path| "-I#{path}" }, *sources],
                    name: name, deadline: DEADLINE, chdir: directory)
        names.map { |object| File.join(directory, "#{object}.o") }
      end

      def compiler_identity(work)
        record = @runner.run([@compiler, '--version'], name: 'rc-oracle-compiler', deadline: 60, chdir: work)
        BoundedFile.read(record.fetch('log'), maximum: 65_536).lines.first.to_s.strip
      end

      # The new output replaces the old whole: the old tree moves aside first
      # and is deleted only after the new one is in place.
      def publish(output)
        destination = File.join(@root, OUTPUT)
        raise Error, "rc oracle output is a symbolic link: #{destination}" if File.symlink?(destination)

        previous = "#{output}.previous"
        File.rename(destination, previous) if File.exist?(destination)
        File.rename(output, destination)
      end
    end
  end
end
