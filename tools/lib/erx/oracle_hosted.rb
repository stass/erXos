# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'securerandom'
require 'socket'
require_relative 'abi'
require_relative 'bounded_file'
require_relative 'erlang_apps'
require_relative 'oracle'
require_relative 'oracle_comparison'
require_relative 'output_directory'
require_relative 'pack_tools'
require_relative 'pack_wire'
require_relative 'release'
require_relative 'runner'
require_relative 'runtime'

module Erx
  # `tools/erx oracle hosted`: OTP's suites for /tmp (design-tmp.md,
  # Verification, "OTP's suites") under Common Test on erXos's hosted
  # runtime, with the logs and every priv_dir under /tmp, and on stock OTP
  # 29.1.2 on the host, then compared case by case by OracleComparison.
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
    # Each suite and the directory of OTP's tree that holds it and its _data.
    SUITES = { 'file_SUITE' => 'otp/lib/kernel/test', 'filelib_SUITE' => 'otp/lib/stdlib/test' }.freeze
    KNOWN_DIFFERENCES = 'test/oracle/hosted_known_differences.txt'
    # The reporter, from test/oracle, and the helpers OTP's suites take from
    # Common Test's own test_server directory, which the install leaves out.
    REPORTER = %w[erx_oracle_events.erl erx_oracle_observer.erl common_test/test_server_ctrl.erl
                  erx_ct_oracle.erl].freeze
    TEST_SERVER = %w[ts_install_cth.erl ts_lib.erl].freeze
    # Stock's own builds of what Common Test needs and erXos does not build.
    STOCK_APPLICATIONS = %w[common_test sasl].freeze
    ERXOS_APPLICATIONS = [*Runtime::APPLICATIONS, *ErlangApps::APPLICATIONS].freeze
    # erXos's working directory: suites, logs and priv_dirs all live in /tmp.
    ERXOS_WORK = '/tmp/ct'
    EVENT_PREFIX = 'erx-oracle-event '
    STOCK_NODE = 'erx_oracle_stock'
    MAX_OUTPUT_BYTES = 256 * 1024 * 1024
    ARCHIVE_BUDGET = 512 * 1024 * 1024
    COMPILE_DEADLINE = 600
    # What marks a directory as this tool's: `--out` is refused when it holds
    # anything and lacks it, since a run replaces the subdirectories it owns.
    MARKER = '.erx-oracle-hosted'
    # The stock node's distribution, its epmd and its peers' listen on the
    # loopback interface only.
    LOOPBACK_DISTRIBUTION = '-kernel inet_dist_use_interface {127,0,0,1}'

    Outcome = Data.define(:result, :report)

    def initialize(root:, out:, deadline:, compiler: ENV.fetch('ERX_CLANG', 'clang'))
      @root = File.realpath(root)
      @out = claim(out)
      @deadline = deadline
      @compiler = compiler
      @runner = Runner.new(owner_root: @out, log_dir: File.join(@out, 'logs'))
      @codec = ABI::Codec.new(ABI::Generator.plan(root: @root).schema)
    end

    # Runs `suites`, names from SUITES, on both sides and compares them.
    def run(suites)
      Runtime.check_current(root: @root)
      table = known_differences
      oracle = Oracle.new(root: @root, runner: @runner)
      stock, erxos = oracle.with_runtime('jit') do |installation|
        tree = File.join(@out, 'tree')
        fill_tree(tree, suites, installation: installation, common_test: File.join(oracle.source_path('jit'), 'lib/common_test'))
        [run_stock(tree, suites, erl: installation.fetch('erl')), run_erxos(tree, suites)]
      end
      result = OracleComparison.compare(stock: stock, erxos: erxos, known: table)
      report = File.join(@out, 'report.txt')
      File.write(report, result.report)
      Outcome.new(result: result, report: report)
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

    # The table, whose rows may name only the suites this tool runs, so none
    # lies unchecked.
    def known_differences
      table = OracleComparison.known_differences(text: File.read(File.join(@root, KNOWN_DIFFERENCES)),
                                                 source: KNOWN_DIFFERENCES)
      foreign = table.map(&:suite).uniq - SUITES.keys
      raise Error, "#{KNOWN_DIFFERENCES} names suites it does not run: #{foreign.join(', ')}" unless foreign.empty?

      table
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
      ERXOS_APPLICATIONS.each do |application|
        FileUtils.cp(Dir.glob(File.join(output.root, 'lib', application, 'ebin', '*.{beam,app}')),
                     prepare(tree, 'lib', application, 'ebin'))
      end
      install = File.expand_path('../lib/erlang/lib', File.dirname(installation.fetch('erl')))
      STOCK_APPLICATIONS.each do |application|
        source = Dir.glob(File.join(install, "#{application}-*")).fetch(0) do
          raise Error, "stock OTP has no #{application} under #{install}"
        end
        FileUtils.cp_r(source, File.join(prepare(tree, 'lib'), application))
      end
      compile_reporter(prepare(tree, 'test/ct/reporter'), erlc: installation.fetch('erlc'), common_test: common_test)
      compile_suites(prepare(tree, 'test/ct/suites'), suites, erlc: installation.fetch('erlc'))
    end

    def compile_reporter(directory, erlc:, common_test:)
      reporter = REPORTER.map { |path| File.join(@root, 'test/oracle', path) }
      erlang(erlc, '-I', File.join(common_test, 'include'), '-I', File.join(common_test, 'src'),
             '-o', directory, *reporter, name: 'erlc-reporter')
      test_server = File.join(common_test, 'test_server')
      erlang(erlc, '-I', test_server, '-o', directory, *TEST_SERVER.map { |path| File.join(test_server, path) },
             name: 'erlc-test-server')
    end

    def compile_suites(directory, suites, erlc:)
      suites.each do |suite|
        source = File.join(@root, SUITES.fetch(suite))
        FileUtils.cp(File.join(source, "#{suite}.erl"), directory)
        data = File.join(source, "#{suite}_data")
        FileUtils.cp_r(data, directory) if File.directory?(data)
      end
      erlang(erlc, '-o', directory, *suites.map { |suite| File.join(directory, "#{suite}.erl") }, name: 'erlc-suites')
    end

    def erlang(*argv, name:)
      @runner.run(argv, name: name, deadline: COMPILE_DEADLINE, chdir: @out, env: Oracle::CLEAN_ERLANG_ENV)
    end

    # Stock reads its events where erx_oracle_events writes them, so a run cut
    # off by its deadline still shows the cases it reached.
    def run_stock(tree, suites, erl:)
      work = File.join(@out, 'stock')
      FileUtils.rm_rf(work)
      prepare(work)
      write_cookie(work)
      # ERL_ZFLAGS reaches the peers the suites start as well as this node.
      # XDG_CONFIG_HOME is cleared so the cookie can only be the run's own.
      environment = Oracle::CLEAN_ERLANG_ENV.merge('HOME' => work, 'XDG_CONFIG_HOME' => nil,
                                                  'ERL_EPMD_PORT' => free_port.to_s,
                                                  'ERL_EPMD_ADDRESS' => '127.0.0.1',
                                                  'ERL_ZFLAGS' => LOOPBACK_DISTRIBUTION,
                                                  'ERL_EPMD_RELAXED_COMMAND_CHECK' => '1')
      record = begin
        finished([erl, '-sname', STOCK_NODE, '-noshell', '-pa', File.join(tree, 'test/ct/reporter'),
                  '-run', 'erx_ct_oracle', 'main', File.join(tree, 'test/ct/suites'), work, *suites],
                 name: 'stock', deadline: @deadline, chdir: work, env: environment)
      ensure
        stop_epmd(File.join(File.dirname(erl), 'epmd'), environment: environment)
      end
      OracleComparison.side(events: File.join(work, 'logs/events.jsonl'), command_state: record.fetch('state'))
    end

    # The node the stock run started its epmd for has halted, but epmd stays
    # until told to go; the run's own port and relaxed check let it be told.
    def stop_epmd(epmd, environment:)
      @runner.run([epmd, '-kill'], name: 'stock-epmd-kill', deadline: 30, chdir: @out, env: environment)
    rescue Error => error
      Terminal.puts("stock epmd on port #{environment.fetch('ERL_EPMD_PORT')} did not stop: #{error.message}")
    end

    # A cookie of the run's own in the stock node's HOME, readable only by
    # its owner, so no guessable or inherited cookie admits a connection.
    def write_cookie(work)
      File.open(File.join(work, '.erlang.cookie'), File::WRONLY | File::CREAT | File::EXCL, 0o400) do |file|
        file.write(SecureRandom.alphanumeric(32))
      end
    end

    # erXos's /tmp is gone with the runtime, so its events are what it printed.
    def run_erxos(tree, suites)
      archive = pack(tree)
      output = Runtime.output(root: @root)
      paths = [*ErlangApps::APPLICATIONS, *STOCK_APPLICATIONS].flat_map { |application| ['-pa', "/lib/#{application}/ebin"] }
      environment = Oracle::CLEAN_ERLANG_ENV.merge('ROOTDIR' => '/', 'BINDIR' => File.dirname(output.beam),
                                                  'EMU' => 'beam', 'PROGNAME' => 'erl', 'HOME' => nil,
                                                  'ERL_CRASH_DUMP_BYTES' => '0')
      record = finished([output.beam, archive, '-noshell', *paths, '-pa', '/test/ct/reporter',
                         '-run', 'erx_ct_oracle', 'main', '/test/ct/suites', ERXOS_WORK, *suites],
                        name: 'erxos', deadline: @deadline, chdir: @out, env: environment,
                        output_limit: MAX_OUTPUT_BYTES)
      events = File.join(@out, 'erxos.events.jsonl')
      File.binwrite(events, printed_events(BoundedFile.read(record.fetch('log'), maximum: MAX_OUTPUT_BYTES)))
      OracleComparison.side(events: events, command_state: record.fetch('state'))
    end

    def printed_events(output)
      output.b.each_line.filter_map { |line| line.delete_prefix(EVENT_PREFIX) if line.start_with?(EVENT_PREFIX) }.join
    end

    # The record of a run judged by what it left rather than by its exit;
    # its state is succeeded, failed, timed_out or cancelled.
    def finished(argv, **options)
      @runner.run(argv, **options)
    rescue CommandError => error
      error.result
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

    # A port no listener holds at the moment it is asked for. Another
    # program could take it before stock's epmd does; the run then fails
    # to start its node, which the report shows.
    def free_port
      server = TCPServer.new('127.0.0.1', 0)
      server.addr[1]
    ensure
      server&.close
    end
  end
end
