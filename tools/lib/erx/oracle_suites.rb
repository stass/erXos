# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'securerandom'
require 'socket'
require_relative 'oracle'
require_relative 'oracle_comparison'
require_relative 'output_directory'
require_relative 'runner'

module Erx
  # What `tools/erx oracle hosted` and `tools/erx oracle qemu` share: the OTP
  # suites they run, the table of erXos's known differences, the compiled
  # suites and reporter both sides run, and the stock side, which is the same
  # run on stock OTP 29.1.2 on the host whichever erXos side it is compared
  # with.
  #
  # The suites are OTP's groups of plan.md's M3 (emulator, kernel, stdlib
  # and compiler), and an instance serves one group: suite names repeat
  # across groups (bif_SUITE is in emulator, kernel and compiler), so a
  # group's suites, helper modules, runs, table and report are its own.
  #
  # Both erXos sides read one table per group: a difference is erXos's
  # whether its runtime runs as a macOS process or in the system domain
  # under QEMU, and a case that differs on one and not the other is a bug in
  # one of them.
  class OracleSuites
    # OTP's suite groups and the directory of OTP's tree that holds each
    # group's suites, their _data and the helper modules they share.
    GROUPS = { 'emulator' => 'otp/erts/emulator/test', 'kernel' => 'otp/lib/kernel/test',
               'stdlib' => 'otp/lib/stdlib/test', 'compiler' => 'otp/lib/compiler/test' }.freeze
    # The subset `make check-oracle-hosted` runs on every change, by group;
    # `make check-oracle` runs it beside its whole groups (tools/erx).
    FAST = { 'kernel' => %w[file_SUITE], 'stdlib' => %w[filelib_SUITE] }.freeze
    # One table of known differences per group, named after it.
    KNOWN_DIFFERENCES = 'test/oracle/hosted_known_differences'
    # The reporter, from test/oracle, and the helpers OTP's suites take from
    # Common Test's own test_server directory, which the install leaves out.
    REPORTER = %w[erx_oracle_events.erl erx_oracle_observer.erl common_test/test_server_ctrl.erl
                  erx_ct_oracle.erl].freeze
    TEST_SERVER = %w[ts_install_cth.erl ts_lib.erl].freeze
    # Stock's own builds of what Common Test needs and erXos does not build:
    # erl2html2 parses each suite with syntax_tools' epp_dodger, and cover is
    # in tools.
    STOCK_APPLICATIONS = %w[common_test sasl syntax_tools tools].freeze
    # Where Common Test logs on erXos: a RAM file system of its own, which
    # erx_ct_oracle mounts, so a suite that fills /tmp, where its priv_dir
    # and data_dir are, fails only its own cases. Its cap, 256 MiB, is above
    # the 100 MB of logs stock's kernel group writes besides heart_SUITE's
    # 144 MB case log (a peer case erXos does not run; erxos-history
    # oracle-hosted/2026-11-06-kernel-ct-logs), and the system domain's
    # memory covers it beside /tmp's on the oracle's machines
    # (OracleQemu::MACHINE; the hosted runtime has no bound of its own).
    ERXOS_LOGS = '/ct-logs'
    ERXOS_LOG_CAP = 256 << 20
    # erx_ct_oracle's arguments on erXos: the suites, the work directory
    # under /tmp, and the log tree.
    def self.erxos_arguments(work) = ['/test/ct/suites', work, ERXOS_LOGS, ERXOS_LOG_CAP.to_s]
    # Generated headers of stock's source tree that a group's test Makefile
    # installs beside its suites (release_tests_spec), by group, each with the
    # file it is generated from, which the image's receipt names as its
    # source. compiler's beam_debug_info_SUITE includes beam_opcodes.hrl,
    # which beam_makeops generates from genop.tab; compile_SUITE warnings
    # compiles beam_debug_info_SUITE.erl again at run time, from the suite
    # directory.
    RELEASED_HEADERS = { 'compiler' => { 'lib/compiler/src/beam_opcodes.hrl' => 'lib/compiler/src/genop.tab' } }.freeze
    # One of RELEASED_HEADERS in stock's source tree, with the file it is generated from.
    ReleasedHeader = Data.define(:source_header, :generator)
    # Files of the test directories that are copied but not compiled, being
    # no module of their own name: kernel's code_a_test.erl is a source that
    # code_SUITE compiles itself, as code_b_test.
    NOT_MODULES = %w[code_a_test.erl].freeze
    STOCK_NODE = 'erx_oracle_stock'
    COMPILE_DEADLINE = 600
    # The stock node's distribution, its epmd and its peers' listen on the
    # loopback interface only.
    LOOPBACK_DISTRIBUTION = '-kernel inet_dist_use_interface {127,0,0,1}'

    # A compiled file of the tree and the source it was compiled or copied
    # from, which a packed image's receipt names.
    Compiled = Data.define(:path, :source)

    # The suites of `group`, in name order.
    def self.suites(root:, group:)
      Dir.glob('*_SUITE.erl', base: File.join(root, GROUPS.fetch(group))).map { |file| File.basename(file, '.erl') }.sort
    end

    # What `names` select, as each group's suites in GROUPS' order: a name is
    # a group, `group/SUITE` for one suite of it, or `fast` for FAST.
    def self.select(names, root:)
      chosen = names.flat_map do |name|
        case name.split('/', 2)
        in ['fast'] then FAST.flat_map { |group, suites| suites.map { |suite| [group, suite] } }
        in [group] if GROUPS.key?(group) then suites(root: root, group: group).map { |suite| [group, suite] }
        in [group, suite] if GROUPS.key?(group) && suites(root: root, group: group).include?(suite) then [[group, suite]]
        else raise Error, "#{name} is no group (#{GROUPS.keys.join(', ')}), group/SUITE or fast"
        end
      end
      GROUPS.keys.to_h { |group| [group, suites(root: root, group: group) & chosen.filter_map { |g, s| s if g == group }] }
            .reject { |_, suites| suites.empty? }
    end

    # The combined report of `results`, each group's comparison by group:
    # each group's report under its name, then the counts over every group
    # and the one result.
    def self.combined_report(results)
      rows = results.values.flat_map(&:rows)
      counts = OracleComparison::VERDICTS.map { |verdict| "#{verdict} #{rows.count { |row| row.verdict == verdict }}" }
      failed = results.reject { |_, result| result.passed? }.keys
      sections = results.map { |group, result| "== #{group}\n#{result.report}" }
      [*sections, "all groups: #{counts.join(', ')}\n",
       "overall: #{failed.empty? ? 'PASS' : "FAIL (#{failed.join(', ')})"}\n"].join
    end

    # `source` is the directory the suites come from, by default the group's.
    def initialize(root:, out:, runner:, deadline:, group:, source: File.join(root, GROUPS.fetch(group)))
      @root = root
      @out = out
      @runner = runner
      @deadline = deadline
      @group = group
      @source = source
    end

    # The group's table, whose rows may name only the group's suites, so none
    # lies unchecked.
    def known_differences
      path = File.join(KNOWN_DIFFERENCES, "#{@group}.txt")
      table = OracleComparison.known_differences(text: File.read(File.join(@root, path)), source: path)
      foreign = table.map(&:suite).uniq - OracleSuites.suites(root: @root, group: @group)
      raise Error, "#{path} names suites #{@group} does not have: #{foreign.join(', ')}" unless foreign.empty?

      table
    end

    # The reporter into `reporter` and `suites` with their data into `suite_directory`,
    # compiled by stock's erlc. `stock_source` is stock's built source tree, which
    # gives the reporter Common Test's headers and the group its RELEASED_HEADERS,
    # all of which are found before anything compiles, so a missing one is
    # refused first. Returns each file written with its source.
    def compile(reporter:, suite_directory:, suites:, erlc:, stock_source:)
      headers = released_headers(stock_source)
      [*compile_reporter(reporter, erlc: erlc, common_test: File.join(stock_source, 'lib/common_test')),
       *compile_suites(suite_directory, suites, erlc: erlc, headers: headers)]
    end

    # Stock's installed STOCK_APPLICATIONS, each copied whole to
    # `directory/<application>`.
    def copy_stock_applications(directory, erl:)
      install = File.expand_path('../lib/erlang/lib', File.dirname(erl))
      STOCK_APPLICATIONS.each do |application|
        source = Dir.glob(File.join(install, "#{application}-*")).fetch(0) do
          raise Error, "stock OTP has no #{application} under #{install}"
        end
        FileUtils.cp_r(source, File.join(directory, application))
      end
    end

    # Runs every suite compiled into `tree` on stock. Stock reads its events
    # where erx_oracle_events writes them, so a run cut off by its deadline
    # still shows the cases it reached. `schedulers`, when given, is the
    # number of schedulers the erXos side runs, which stock then runs too
    # (`+S`, which the dirty CPU schedulers follow):
    # a suite skips the cases that need more schedulers than are online, so
    # sides with different counts would differ in those cases for that alone.
    # The peers a suite starts keep ERTS's default.
    def run_stock(tree, erl:, schedulers: nil)
      work = File.join(@out, 'stock')
      FileUtils.rm_rf(work)
      OutputDirectory.prepare(root: @out, path: work)
      write_cookie(work)
      # ERL_ZFLAGS reaches the peers the suites start as well as this node.
      # XDG_CONFIG_HOME is cleared so the cookie can only be the run's own.
      environment = Oracle::CLEAN_ERLANG_ENV.merge('HOME' => work, 'XDG_CONFIG_HOME' => nil,
                                                  'ERL_EPMD_PORT' => free_port.to_s,
                                                  'ERL_EPMD_ADDRESS' => '127.0.0.1',
                                                  'ERL_ZFLAGS' => LOOPBACK_DISTRIBUTION,
                                                  'ERL_EPMD_RELAXED_COMMAND_CHECK' => '1')
      record = begin
        finished([erl, *scheduler_flags(schedulers), '-sname', STOCK_NODE, '-noshell', '-pa', File.join(tree, 'test/ct/reporter'),
                  '-run', 'erx_ct_oracle', 'main', File.join(tree, 'test/ct/suites'), work],
                 name: 'stock', deadline: @deadline, chdir: work, env: environment)
      ensure
        stop_epmd(File.join(File.dirname(erl), 'epmd'), environment: environment)
      end
      OracleComparison.side(events: File.join(work, 'logs/events.jsonl'), command_state: record.fetch('state'),
                            seconds: record['elapsed_seconds'])
    end

    # The record of a run judged by what it left rather than by its exit;
    # its state is succeeded, failed, timed_out or cancelled.
    def finished(argv, **options)
      @runner.run(argv, **options)
    rescue CommandError => error
      error.result
    end

    private

    def compile_reporter(directory, erlc:, common_test:)
      reporter = REPORTER.map { |path| File.join(@root, 'test/oracle', path) }
      erlang(erlc, '-I', File.join(common_test, 'include'), '-I', File.join(common_test, 'src'),
             '-o', directory, *reporter, name: 'erlc-reporter')
      test_server = File.join(common_test, 'test_server')
      helpers = TEST_SERVER.map { |path| File.join(test_server, path) }
      erlang(erlc, '-I', test_server, '-o', directory, *helpers, name: 'erlc-test-server')
      [*reporter, *helpers].map { |source| Compiled.new(path: File.join(directory, "#{File.basename(source, '.erl')}.beam"), source: source) }
    end

    # The suites with their _data and every other module and header of the
    # group's test directory, since a group's suites share helper modules
    # there, all compiled together beside `headers`, the group's
    # RELEASED_HEADERS, which no file of the test directory may shadow.
    # erx_ct_oracle runs every suite the directory holds, so the suites it
    # holds are refused unless they are `suites`.
    def compile_suites(directory, suites, erlc:, headers:)
      helpers = Dir.glob(File.join(@source, '*.{erl,hrl}')).sort.reject { |path| path.end_with?('_SUITE.erl') }
      shadowed = helpers.map { |path| File.basename(path) } & headers.map { |header| File.basename(header.source_header) }
      raise Error, "#{@source} has its own #{shadowed.join(', ')}, which the release installs" unless shadowed.empty?

      FileUtils.cp(helpers, directory)
      FileUtils.cp(headers.map(&:source_header), directory)
      sources = helpers + suites.flat_map do |suite|
        FileUtils.cp(File.join(@source, "#{suite}.erl"), directory)
        data = File.join(@source, "#{suite}_data")
        FileUtils.cp_r(data, directory) if File.directory?(data)
        [File.join(@source, "#{suite}.erl"),
         *Dir.glob('**/*', base: data).map { |path| File.join(data, path) }.select { |path| File.file?(path) }]
      end
      modules = sources.select { |path| File.dirname(path) == @source && path.end_with?('.erl') }
                       .reject { |path| NOT_MODULES.include?(File.basename(path)) }
      erlang(erlc, '-I', directory, '-o', directory,
             *modules.map { |path| File.join(directory, File.basename(path)) }, name: 'erlc-suites')
      held = Dir.glob('*_SUITE.erl', base: directory).map { |file| File.basename(file, '.erl') }.sort
      raise Error, "#{directory} holds the suites #{held.join(' ')}, not the selection" unless held == suites.sort
      copied = sources.map { |path| Compiled.new(path: File.join(directory, path.delete_prefix("#{@source}/")), source: path) }
      installed = headers.map do |header|
        Compiled.new(path: File.join(directory, File.basename(header.source_header)), source: header.generator)
      end
      beams = modules.map { |path| Compiled.new(path: File.join(directory, "#{File.basename(path, '.erl')}.beam"), source: path) }
      copied + installed + beams
    end

    # The group's RELEASED_HEADERS in stock's source tree `stock_source`, each
    # with the file it is generated from; every missing file is refused at once.
    def released_headers(stock_source)
      headers = RELEASED_HEADERS.fetch(@group, {}).map do |header, generator|
        ReleasedHeader.new(source_header: File.join(stock_source, header), generator: File.join(stock_source, generator))
      end
      missing = headers.flat_map { |header| [header.source_header, header.generator] }.reject { |path| File.file?(path) }
      raise Error, "stock's source tree has no #{missing.join(' or ')}" unless missing.empty?

      headers
    end

    def erlang(*argv, name:)
      @runner.run(argv, name: name, deadline: COMPILE_DEADLINE, chdir: @out, env: Oracle::CLEAN_ERLANG_ENV)
    end

    # The node the stock run started its epmd for has halted, but epmd stays
    # until told to go; the run's own port and relaxed check let it be told.
    def scheduler_flags(schedulers) = schedulers ? ['+S', "#{schedulers}:#{schedulers}"] : []

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
