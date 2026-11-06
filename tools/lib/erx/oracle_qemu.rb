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
  # to the release under /lib and /test/ct. Only this tool builds it, so no
  # production image carries test code. The kernel command line's erx.arg
  # words hand the system domain's ERTS `-run erx_ct_oracle main`, which runs
  # the suites from /tmp/ct and halts, and the halt ends the machine.
  #
  # The events reach the host on the console's serial line, which they share
  # with the kernel's, the root's and ERTS's own C output. In the system domain
  # erlang:display_string/2 reaches erx_console, which writes each call's
  # bytes to the UART whole and unchanged (docs/design-runtime.md, "The console
  # and standard I/O"), so console writers never split an event line; only a C
  # writer can, at any byte. Each event line carries its length and CRC-32,
  # so a damaged line is counted, never read, and a run that lost one is
  # reported as incomplete: TODO.md holds that residual.
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

    def initialize(root:, out:, deadline:, compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''),
                   qemu: 'qemu-system-aarch64')
      @root = File.realpath(root)
      @out = claim(out)
      @deadline = deadline
      @compiler = compiler
      @linker = linker
      @qemu = qemu
      @runner = Runner.new(owner_root: @root, log_dir: File.join(@out, 'logs'))
      @codec = ABI::Codec.new(ABI::Generator.plan(root: @root).schema)
      @suites = OracleSuites.new(root: @root, out: @out, runner: @runner, deadline: deadline)
    end

    # Runs `suites`, names from OracleSuites::SUITES, on stock and in the guest
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
      result = OracleComparison.compare(stock: stock, erxos: erxos, known: table)
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
    def fill_tree(tree, suites, installation:, source:)
      FileUtils.rm_rf(tree)
      prepare(tree)
      @suites.copy_stock_applications(prepare(tree, 'lib'), erl: installation.fetch('erl'))
      stock = OracleSuites::STOCK_APPLICATIONS.flat_map do |application|
        installed = File.join(tree, 'lib', application)
        LEFT_OUT.fetch(application, []).each { |path| FileUtils.rm_rf(File.join(installed, path)) }
        Dir.glob('**/*', base: installed).select { |path| File.file?(File.join(installed, path)) }.map do |path|
          stand_in = STAND_INS.fetch(application, {})[path]
          FileUtils.cp(File.join(@root, stand_in), File.join(installed, path)) if stand_in
          OracleSuites::Compiled.new(path: File.join(installed, path),
                                     source: stand_in ? File.join(@root, stand_in) : stock_source(source, application, path))
        end
      end
      stock + @suites.compile(reporter: prepare(tree, 'test/ct/reporter'), suite_directory: prepare(tree, 'test/ct/suites'),
                              suites: suites, erlc: installation.fetch('erlc'),
                              common_test: File.join(source, 'lib/common_test'))
    end

    # What a file of stock's installed application was built or copied from in
    # stock's source tree: a beam from its module's source, an application
    # file from its .app.src, anything else from the same path.
    def stock_source(source, application, path)
      tree = File.join(source, 'lib', application)
      candidates = case path
                   when %r{([^/]+)\.beam\z} then Dir.glob(File.join(tree, '**', "#{Regexp.last_match(1)}.erl")).sort
                   when %r{\Aebin/([^/]+)\.app\z} then [File.join(tree, 'src', "#{Regexp.last_match(1)}.app.src")]
                   else [File.join(tree, path)]
                   end
      candidates.find { |candidate| File.file?(candidate) } or
        raise Error, "stock #{application} has no source for #{path}"
    end

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
                     .build(directory: directory,
                            added: ProductionImage::Added.new(entries: added, inputs: inputs, imports: IMPORTS))
    end

    # Boots the image under its deadline and reads the events it printed. The
    # serial log is read whatever ended the boot, so a guest cut off by its
    # deadline still shows the cases it finished.
    def run_guest(built, suites, accel:, cpus:)
      directory = ProductionImage.clear_directory(root: @root, path: File.join(@out, 'guest'))
      points = [*Qemu.boot_transcript(memory_mib: MEMORY_MIB), ProductionImage::Run::SLOGAN,
                { name: 'oracle-result', pattern: RESULT, seconds: @deadline }]
      state = begin
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(accel: accel, cpus: cpus, image: built.single, memory_mib: MEMORY_MIB, checkpoints: points,
                 machine_end: true, directory: directory, command_line: self.class.command_line(suites, accel: accel))
        'succeeded'
      rescue TranscriptTimeout
        'timed_out'
      rescue CommandError => error
        error.result.fetch('state')
      rescue Error
        'failed'
      end
      record = JsonInput.parse(BoundedFile.read(File.join(directory, 'report.json'), maximum: 1024 * 1024),
                              max_bytes: 1024 * 1024, label: 'QEMU run report')
      printed = OracleComparison.printed_events(BoundedFile.read(record.fetch('serial_log'), maximum: MAX_SERIAL_BYTES))
      events = File.join(@out, 'erxos.events.jsonl')
      File.binwrite(events, printed.events)
      [OracleComparison.side(events: events, command_state: state, skipped: printed.skipped),
       record.fetch('elapsed_seconds')]
    end

    def reference(path) = { 'path' => path.delete_prefix("#{@root}/"), 'sha256' => Digest::SHA256.file(path).hexdigest }

    def prepare(*parts) = OutputDirectory.prepare(root: @root, path: File.join(*parts))
  end
end
