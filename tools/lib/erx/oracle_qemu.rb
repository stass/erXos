# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'abi'
require_relative 'bounded_file'
require_relative 'fiasco'
require_relative 'json_input'
require_relative 'oracle'
require_relative 'oracle_comparison'
require_relative 'oracle_suites'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # `tools/erx oracle qemu`: OTP's suites under Common Test in erXos's system
  # domain under QEMU, compared case by case with the same suites on stock OTP
  # 29.1.2 on the host (OracleSuites) and judged against the same table of
  # known differences as the hosted run.
  #
  # The guest boots a test image: the production image's kernel, root task and
  # system release, packed through the same funnel and manifest check, with
  # stock's Common Test and SASL, the reporter and the compiled suites added
  # to the release under /lib and /test/ct, through ProductionImage#build_test_image,
  # which marks its archive (ERX_PACK_TEST_CODE) so the kernel banner says so and the
  # boot transcript checks that line. Checks::TEST_IMAGE_BUILDERS holds that this file
  # and the block device suite's harness alone call that entry point, so no
  # production image carries test code. The
  # kernel command line's erx.arg words hand the system domain's ERTS
  # `-run erx_ct_oracle main`, which runs the suites from /tmp/ct and halts, and the
  # halt ends the machine.
  #
  # The events reach the host on the console's serial line, which they share
  # with the kernel's, the root's and ERTS's own C output. In the system domain
  # erlang:display_string/2 reaches erx_console, which writes each call's
  # bytes to the UART whole and unchanged (docs/design-runtime.md, "The console
  # and standard I/O"), so console writers never split an event line; only a C
  # writer can, at any byte. Each event frame carries a sequence number, its
  # length and a CRC-32, so a damaged line is counted, never read, a lost one
  # shows as a gap, and a run that lost one is reported as incomplete:
  # TODO.md holds that residual.
  class OracleQemu
    WORK = '/tmp/ct'
    MEMORY_MIB = ProductionImage::MEMORY_MIB
    MAX_SERIAL_BYTES = 256 * 1024 * 1024
    MARKER = '.erx-oracle-qemu'
    # The line erx_ct_oracle prints when Common Test returns; the machine ends
    # after its suite logs. The shell's prompt redraw may start its line, so the
    # pattern is not anchored.
    RESULT = /erx-oracle-result /n
    # Stock's files whose licence the packer cannot attribute, as no SPDX line
    # names it. Common Test copies its jQuery files beside its HTML logs and
    # stops without them, so each gets an erXos stand-in; its tile image is
    # only named in that HTML, and SASL's deps.mk is build glue, so both are
    # left out. The logs stay in the guest's /tmp, and nothing reads them.
    JQUERY = 'test/oracle/ct-priv-stand-in.js'
    STAND_INS = { 'common_test' => %w[priv/jquery-latest.js priv/jquery-migrate.js priv/jquery.tablesorter.min.js]
                                     .to_h { |path| [path, JQUERY] } }.freeze
    # The patched test_server_ctrl's imported tree, which the reporter compiles.
    IMPORTS = { 'test/oracle/common_test' => 'permanent' }.freeze
    LEFT_OUT = { 'common_test' => %w[priv/tile1.jpg], 'sasl' => %w[src/deps/deps.mk] }.freeze

    Outcome = Data.define(:result, :report, :seconds)

    def initialize(root:, out:, deadline:, group:, compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''),
                   qemu: 'qemu-system-aarch64')
      @root = File.realpath(root)
      @out = claim(out)
      @deadline = deadline
      @compiler = compiler
      @linker = linker
      @qemu = qemu
      @runner = Runner.new(owner_root: @root, log_dir: File.join(@out, 'logs'))
      @codec = ABI::Codec.new(ABI::Generator.plan(root: @root).schema)
      @suites = OracleSuites.new(root: @root, out: @out, runner: @runner, deadline: deadline, group: group)
    end

    # Runs `suites`, names of the group's suites (OracleSuites), on stock and in the guest
    # under `accel` with `cpus` CPUs, and compares them.
    def run(suites, accel:, cpus:, jobs: 4)
      table = @suites.known_differences
      oracle = Oracle.new(root: @root, runner: @runner)
      fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
      fiasco.build(jobs: jobs)
      stock, erxos, seconds = oracle.with_runtime('jit') do |installation|
        tree = File.join(@out, 'tree')
        compiled = fill_tree(tree, suites, installation: installation, source: oracle.source_path('jit'))
        image = test_image(tree, compiled, fiasco: fiasco)
        [@suites.run_stock(tree, suites, erl: installation.fetch('erl')), *run_guest(image, suites, accel: accel, cpus: cpus)]
      end
      result = OracleComparison.compare(stock: stock, erxos: erxos, known: table, runtime: "QEMU #{accel}")
      report = File.join(@out, 'report.txt')
      File.write(report, result.report)
      Outcome.new(result: result, report: report, seconds: seconds)
    end

    # The kernel command line of a run: the accelerator's own words, then one
    # erx.arg word for each argument ERTS takes after the manifest's.
    def self.command_line(suites, accel:)
      paths = [*OracleSuites::STOCK_APPLICATIONS.map { |application| "/lib/#{application}/ebin" }, '/test/ct/reporter']
      arguments = [*paths.flat_map { |path| ['-pa', path] }, '-run', 'erx_ct_oracle', 'main', '/test/ct/suites', WORK, *suites]
      unless arguments.all? { |argument| argument.match?(/\A[A-Za-z0-9_\/.-]+\z/) }
        raise Error, 'an oracle argument does not fit one kernel command-line word'
      end
      [ProductionImage::Run::COMMAND_LINES[accel], *arguments.map { |argument| "erx.arg=#{argument}" }].compact.join(' ')
    end

    private

    # The output directory, created or reused only when it is empty or this
    # tool's own.
    def claim(out)
      FileUtils.mkdir_p(out)
      directory = File.realpath(out)
      marker = File.join(directory, MARKER)
      unless File.file?(marker) || Dir.empty?(directory)
        raise Error, "#{directory} is not empty and was not made by tools/erx oracle qemu"
      end
      File.write(marker, "made by tools/erx oracle qemu\n")
      directory
    end

    # The files the test image adds to the system release, laid out as the
    # archive holds them under system/, each with the source its receipt names.
    # The effects come first (stock's installed files, the left-out files
    # removed, the stand-ins copied over theirs); what each file came from is
    # then a plan read off the tree.
    def fill_tree(tree, suites, installation:, source:)
      FileUtils.rm_rf(tree)
      prepare(tree)
      @suites.copy_stock_applications(prepare(tree, 'lib'), erl: installation.fetch('erl'))
      stock = OracleSuites::STOCK_APPLICATIONS.flat_map do |application|
        installed = File.join(tree, 'lib', application)
        LEFT_OUT.fetch(application, []).each { |path| FileUtils.rm_rf(File.join(installed, path)) }
        STAND_INS.fetch(application, {}).each do |path, stand_in|
          target = File.join(installed, path)
          raise Error, "stock #{application} has no #{path} for its stand-in" unless File.file?(target)

          FileUtils.cp(File.join(@root, stand_in), target)
        end
        files = Dir.glob('**/*', base: installed).select { |path| File.file?(File.join(installed, path)) }
        self.class.stock_plan(application, installed: installed, files: files, root: @root, source: source)
      end
      stock + @suites.compile(reporter: prepare(tree, 'test/ct/reporter'), suite_directory: prepare(tree, 'test/ct/suites'),
                              suites: suites, erlc: installation.fetch('erlc'),
                              common_test: File.join(source, 'lib/common_test'))
    end

    public

    # Each of `files`, paths under `installed`, the installed tree of stock's
    # `application`, with what its receipt names as its source: its erXos
    # stand-in, or what stock built or copied it from.
    def self.stock_plan(application, installed:, files:, root:, source:)
      files.map do |path|
        stand_in = STAND_INS.fetch(application, {})[path]
        OracleSuites::Compiled.new(path: File.join(installed, path),
                                   source: stand_in ? File.join(root, stand_in) : stock_source(source, application, path))
      end
    end

    # What a file of stock's installed application was built or copied from in
    # stock's source tree `source`: a beam from its module's one source, an
    # application or appup file from its .src, anything else from the same
    # path. No source, or more than one module source, is an error, never a
    # guess. A module's name is case-sensitive, and the glob on a host whose
    # file system is not (macOS) also returns names differing in case
    # (common_test's ct_suite.erl and ct_SUITE.erl), so the name is compared.
    # An application's emacs/ directory holds editor support that make never
    # compiles into ebin (tools' emacs/tags.erl beside src/tags.erl), so it is
    # no module source.
    def self.stock_source(source, application, path)
      tree = File.join(source, 'lib', application)
      candidates = case path
                   when %r{([^/]+)\.beam\z}
                     name = "#{Regexp.last_match(1)}.erl"
                     Dir.glob(File.join(tree, '**', name))
                        .select { |candidate| File.basename(candidate) == name }
                        .reject { |candidate| candidate.start_with?(File.join(tree, 'emacs', '')) }
                   when %r{\Aebin/([^/]+\.app(?:up)?)\z} then [File.join(tree, 'src', "#{Regexp.last_match(1)}.src")]
                   else [File.join(tree, path)]
                   end
      found = candidates.select { |candidate| File.file?(candidate) }
      raise Error, "stock #{application} has no source for #{path}" if found.empty?
      raise Error, "stock #{application} has #{found.size} sources for #{path}: #{found.sort.join(' ')}" if found.size > 1

      found.first
    end

    # What ended a guest run, named for the report, and why. `booted` says
    # whether the guest printed the first line its transcript checks:
    #   succeeded    the guest printed its result line;
    #   timed_out    the deadline, or a checkpoint's, passed first;
    #   failed       erXos ended before its result line, so its run crashed;
    #   qemu_failed  QEMU ended before the guest printed anything: it did not
    #                start, the host has no such accelerator, or an argument
    #                was refused;
    #   cancelled    the run was interrupted on the host;
    #   host_failed  the host failed before or around the boot.
    # Only `failed` speaks of erXos; the host states keep their message, and
    # the comparison shows their cases as unknown.
    GuestState = Data.define(:name, :message)

    def self.state_of(error, booted:)
      name = case error
             in nil then 'succeeded'
             in TranscriptTimeout then 'timed_out'
             in CommandError if error.result.fetch('state') == 'timed_out' then 'timed_out'
             in CommandError if error.result.fetch('state') == 'cancelled' then 'cancelled'
             in Error if booted then 'failed'
             in CommandError then 'qemu_failed'
             in Error then 'host_failed'
             end
      GuestState.new(name: name, message: error&.message)
    end

    # A guest run's outcome: its state, the run record Qemu#run wrote (empty
    # when it wrote none) and the serial output (empty when there is none).
    Guest = Data.define(:state, :record, :serial)

    # Runs `qemu`, a Qemu, into `directory` with `arguments` and reads what it
    # left there. Only Erx errors are caught; anything else is a bug and
    # propagates.
    def self.boot_guest(qemu, directory:, **arguments)
      error = begin
        qemu.run(directory: directory, **arguments)
        nil
      rescue Error => e
        e
      end
      report = File.join(directory, 'report.json')
      record = if File.file?(report)
                 JsonInput.parse(BoundedFile.read(report, maximum: 1024 * 1024), max_bytes: 1024 * 1024,
                                                                                 label: 'QEMU run report')
               else
                 {}
               end
      serial = record['serial_log']
      Guest.new(state: state_of(error, booted: !record.fetch('checkpoints', []).empty?), record: record,
                serial: serial && File.file?(serial) ? BoundedFile.read(serial, maximum: MAX_SERIAL_BYTES) : '')
    end

    private

    # The production image with the tree's files added, each as a release file
    # with a compiled receipt naming its source.
    def test_image(tree, compiled, fiasco:)
      directory = ProductionImage.clear_directory(root: @root, path: File.join(@out, 'image'))
      receipts = prepare(File.join(@out, 'receipts'))
      added = compiled.map.with_index do |file, index|
        receipt = File.join(receipts, "#{index}.json")
        File.write(receipt, JSON.pretty_generate('version' => 1, 'kind' => 'compiled', 'artifact' => reference(file.path),
                                                 'sources' => [reference(file.source)]))
        { 'path' => "system/#{file.path.delete_prefix("#{tree}/")}", 'kind' => @codec.member('entry_kind', 'file'),
          'flags' => @codec.member('entry_flags', 'system'), 'id' => "oracle-#{index}", 'artifact' => file.path,
          'receipt' => receipt }
      end
      inputs = [*compiled.flat_map { |file| [file.path, file.source] }, *added.map { |entry| entry.fetch('receipt') }].uniq
      ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                     .build_test_image(directory: directory,
                                       added: ProductionImage::Added.new(entries: added, inputs: inputs, imports: IMPORTS))
    end

    # Boots the image under its deadline and reads the events it printed. The
    # serial log is read whatever ended the boot, so a guest cut off by its
    # deadline still shows the cases it finished.
    def run_guest(built, suites, accel:, cpus:)
      directory = ProductionImage.clear_directory(root: @root, path: File.join(@out, 'guest'))
      points = [*Qemu.boot_transcript(memory_mib: MEMORY_MIB, test_image: built.test_code), ProductionImage::Run::SLOGAN,
                { name: 'oracle-result', pattern: RESULT, seconds: @deadline }]
      guest = self.class.boot_guest(Qemu.new(root: @root, runner: @runner, program: @qemu), directory: directory,
                                    accel: accel, cpus: cpus, image: built.single, memory_mib: MEMORY_MIB,
                                    checkpoints: points, machine_end: true,
                                    command_line: self.class.command_line(suites, accel: accel))
      printed = OracleComparison.printed_events(guest.serial)
      events = File.join(@out, 'erxos.events.jsonl')
      File.binwrite(events, printed.events)
      [OracleComparison.side(events: events, command_state: guest.state.name, detail: guest.state.message,
                             skipped: printed.skipped, seconds: guest.record['elapsed_seconds']),
       guest.record['elapsed_seconds']]
    end

    def reference(path) = { 'path' => path.delete_prefix("#{@root}/"), 'sha256' => Digest::SHA256.file(path).hexdigest }

    def prepare(*parts) = OutputDirectory.prepare(root: @root, path: File.join(*parts))
  end
end
