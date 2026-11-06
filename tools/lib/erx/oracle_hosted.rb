# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'abi'
require_relative 'bounded_file'
require_relative 'erlang_apps'
require_relative 'oracle'
require_relative 'oracle_comparison'
require_relative 'oracle_suites'
require_relative 'output_directory'
require_relative 'pack_tools'
require_relative 'pack_wire'
require_relative 'release'
require_relative 'release_files'
require_relative 'runner'
require_relative 'runtime'

module Erx
  # `tools/erx oracle hosted`: one group of OTP's suites (OracleSuites)
  # under Common Test on erXos's hosted runtime, with the logs and every
  # priv_dir under /tmp, and on stock OTP 29.1.2 on the host, then compared
  # case by case by OracleComparison.
  #
  # Both sides run the same compiled suites and the same reporter
  # (erx_ct_oracle, erx_oracle_events and the patched test_server_ctrl).
  # Each copies the suites into its working directory first, so data_dir is
  # writable on erXos as it is in a stock checkout. Stock runs as a
  # distributed node with an epmd of its own, so its peer cases run;
  # erXos runs no distribution in Phase 1. Everything the run writes is
  # under `out`: the release tree and archive, both event streams, the
  # command logs and report.txt.
  class OracleHosted
    ERXOS_APPLICATIONS = [*Runtime::APPLICATIONS, *ErlangApps::APPLICATIONS].freeze
    # erXos's working directory: suites, logs and priv_dirs all live in /tmp.
    ERXOS_WORK = '/tmp/ct'
    MAX_OUTPUT_BYTES = 256 * 1024 * 1024
    ARCHIVE_BUDGET = 512 * 1024 * 1024
    # What marks a directory as this tool's: `--out` is refused when it holds
    # anything and lacks it, since a run replaces the subdirectories it owns.
    MARKER = '.erx-oracle-hosted'
    Outcome = Data.define(:result, :report)

    def initialize(root:, out:, deadline:, group:, compiler: ENV.fetch('ERX_CLANG', 'clang'))
      @root = File.realpath(root)
      @out = claim(out)
      @deadline = deadline
      @compiler = compiler
      @runner = Runner.new(owner_root: @out, log_dir: File.join(@out, 'logs'))
      @codec = ABI::Codec.new(ABI::Generator.plan(root: @root).schema)
      @suites = OracleSuites.new(root: @root, out: @out, runner: @runner, deadline: deadline, group: group)
    end

    # Runs `suites`, names of the group's suites, on both sides and compares
    # them.
    def run(suites)
      Runtime.check_current(root: @root)
      table = @suites.known_differences
      oracle = Oracle.new(root: @root, runner: @runner)
      stock, erxos = oracle.with_runtime('jit') do |installation|
        tree = File.join(@out, 'tree')
        fill_tree(tree, suites, installation: installation, common_test: File.join(oracle.source_path('jit'), 'lib/common_test'))
        [@suites.run_stock(tree, suites, erl: installation.fetch('erl')), run_erxos(tree, suites)]
      end
      result = OracleComparison.compare(stock: stock, erxos: erxos, known: table, runtime: 'hosted')
      report = File.join(@out, 'report.txt')
      File.write(report, result.report)
      Outcome.new(result: result, report: report)
    end

    # erXos's applications in the tree, as tree paths to the files they copy, each laid
    # out as the system release lays it out (ReleaseFiles.application_layout) from the
    # hosted build at otp.
    def self.application_files(root:, otp:)
      ERXOS_APPLICATIONS.flat_map do |application|
        ReleaseFiles.application_layout(root: root, otp: otp, application: application)
                    .map { |path, artifact| ["lib/#{application}/#{path}", artifact] }
      end.to_h
    end

    private

    # The output directory, created or reused only when it is empty or this
    # tool's own.
    def claim(out)
      FileUtils.mkdir_p(out)
      directory = File.realpath(out)
      marker = File.join(directory, MARKER)
      unless File.file?(marker) || Dir.empty?(directory)
        raise Error, "#{directory} is not empty and was not made by tools/erx oracle hosted"
      end
      File.write(marker, "made by tools/erx oracle hosted\n")
      directory
    end

    # The release's files: what the hosted runtime's own release holds, stock's
    # Common Test and SASL, the reporter, and the compiled suites with their data.
    def fill_tree(tree, suites, installation:, common_test:)
      FileUtils.rm_rf(tree)
      prepare(tree)
      output = Runtime.output(root: @root)
      File.binwrite(File.join(tree, 'manifest'),
                    Release.file_bytes(archive: output.archive, path: 'system/manifest', codec: @codec))
      # The pack format requires an image entry; the hosted runtime never
      # boots it, so its bytes are only a placeholder.
      File.write(File.join(tree, 'root'), "a root image's place\n")
      FileUtils.cp(File.join(output.root, 'bootstrap/bin/start.boot'), File.join(prepare(tree, 'bin'), 'start.boot'))
      self.class.application_files(root: @root, otp: output.root).each do |path, source|
        FileUtils.cp(source, File.join(prepare(tree, File.dirname(path)), File.basename(path)))
      end
      @suites.copy_stock_applications(prepare(tree, 'lib'), erl: installation.fetch('erl'))
      @suites.compile(reporter: prepare(tree, 'test/ct/reporter'), suite_directory: prepare(tree, 'test/ct/suites'),
                      suites: suites, erlc: installation.fetch('erlc'), common_test: common_test)
    end

    # erXos's /tmp is gone with the runtime, so its events are what it printed.
    def run_erxos(tree, suites)
      archive = pack(tree)
      output = Runtime.output(root: @root)
      paths = [*ErlangApps::APPLICATIONS, *OracleSuites::STOCK_APPLICATIONS].flat_map { |application| ['-pa', "/lib/#{application}/ebin"] }
      environment = Oracle::CLEAN_ERLANG_ENV.merge('ROOTDIR' => '/', 'BINDIR' => File.dirname(output.beam),
                                                  'EMU' => 'beam', 'PROGNAME' => 'erl', 'HOME' => nil,
                                                  'ERL_CRASH_DUMP_BYTES' => '0')
      record = @suites.finished([output.beam, archive, '-noshell', *paths, '-pa', '/test/ct/reporter',
                         '-run', 'erx_ct_oracle', 'main', '/test/ct/suites', ERXOS_WORK, *suites],
                        name: 'erxos', deadline: @deadline, chdir: @out, env: environment,
                        output_limit: MAX_OUTPUT_BYTES)
      events = File.join(@out, 'erxos.events.jsonl')
      printed = OracleComparison.printed_events(BoundedFile.read(record.fetch('log'), maximum: MAX_OUTPUT_BYTES))
      File.binwrite(events, printed.events)
      OracleComparison.side(events: events, command_state: record.fetch('state'), skipped: printed.skipped,
                            seconds: record['elapsed_seconds'])
    end

    def pack(tree)
      directory = prepare(@out, 'pack')
      tools = PackTools.build(root: @root, owner_root: @out, directory: File.join(directory, 'tools'),
                              runner: @runner, compiler: @compiler)
      rows = release_rows(tree)
      archive = File.join(@out, 'release.pack')
      writer = PackWire.new(codec: @codec, hasher: PackHasher.new(helper: tools.fetch('hasher'), runner: @runner))
      File.open(archive, 'wb+') do |output|
        writer.write(rows: rows, root_entry: rows.index { |row| row.fetch('path') == 'system/root' },
                     build_kind: 'development', output: output, budget: ARCHIVE_BUDGET)
      end
      archive
    end

    def release_rows(tree)
      flags = @codec.member('entry_flags', 'system')
      Dir.glob('**/*', base: tree).select { |path| File.file?(File.join(tree, path)) }.map do |path|
        name = "system/#{path}"
        { 'path' => name, 'kind' => @codec.member('entry_kind', name == 'system/root' ? 'image' : 'file'),
          'flags' => flags, 'size' => File.size(File.join(tree, path)), 'snapshot' => File.join(tree, path) }
      end.sort_by { |row| row.fetch('path').b }
    end

    def prepare(*parts) = OutputDirectory.prepare(root: @out, path: File.join(*parts))
  end
end
