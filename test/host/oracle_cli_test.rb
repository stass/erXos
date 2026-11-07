# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
load File.expand_path('../../tools/erx', __dir__) unless defined?(Erx::CLI)

class OracleCliTest < Minitest::Test
  BackendFactory = Struct.new(:backend) do
    def new(**) = backend
  end

  def run_cli(*arguments, **collaborators)
    status = nil
    _stdout, output = capture_io { status = Erx::CLI.run(arguments, **collaborators) }
    [status, output]
  end

  # Stands in for OracleQemu: records each run and passes or fails as told.
  class FakeQemu
    attr_reader :calls

    def initialize(directory, passing:)
      @directory = directory
      @passing = passing
      @calls = []
    end

    def new(**options)
      @calls << options
      self
    end

    # The group of each OracleQemu it made, in order.
    def groups = @calls.grep(Hash).filter_map { |options| options[:group] }

    def run(suites, **options)
      @calls << [suites, options]
      Erx::OracleQemu::Outcome.new(result: OracleCliTest.comparison(passing: @passing), report: 'unused', seconds: 12.4)
    end
  end

  def test_check_oracle_runs_under_hvf_only_and_says_what_it_leaves_out
    Dir.mktmpdir do |directory|
      qemu = FakeQemu.new(directory, passing: true)
      libc_calls = []
      libc = ->(arguments) { libc_calls << arguments && 0 }
      status, output = run_cli('check-oracle', qemu_class: qemu, accelerators: %w[hvf tcg], libc_test: libc)
      assert_equal 2, status, 'a run that passed but leaves parts out is partial, not passed'
      assert_includes output, 'oracle qemu hvf: passed'
      refute_includes output, 'oracle qemu tcg'
      assert_includes output, "partial: the system domain runs kernel/file_SUITE, the stdlib group's suites and the " \
                              "compiler group's suites; OTP's emulator and kernel groups are not classified there yet"
      options = { accel: 'hvf', cpus: 1, jobs: 4 }
      root = File.expand_path('../..', __dir__)
      groups = %w[stdlib compiler].map { |group| Erx::OracleSuites.suites(root: root, group: group) }
      assert_equal [[%w[file_SUITE], options], *groups.map { |suites| [suites, options] }],
                   qemu.calls.grep(Array)
      assert_equal %w[kernel stdlib compiler], qemu.calls.grep(Hash).filter_map { |call| call[:group] }
      assert_equal [Erx::CLI::ORACLE_DEADLINE], qemu.calls.grep(Hash).map { |call| call[:deadline] }.uniq
      assert_equal [%w[hvf 4]], libc_calls
      assert_includes output, 'libc-test hvf 4 CPUs: passed'
    end
  end

  # With every group checked, a run whose every part passed is passed.
  def test_check_oracle_passes_once_every_group_is_checked
    Dir.mktmpdir do |directory|
      qemu = FakeQemu.new(directory, passing: true)
      status, output = run_cli('check-oracle', qemu_class: qemu, accelerators: %w[hvf], libc_test: ->(_) { 0 },
                                               checked_groups: Erx::OracleSuites::GROUPS.keys)
      assert_equal 0, status
      refute_includes output, 'partial:'
      assert_equal Erx::OracleSuites::GROUPS.keys.sort, qemu.groups.sort
    end
  end

  # A libc-test failure fails the check even when every OTP group passed.
  def test_check_oracle_fails_when_libc_test_fails
    Dir.mktmpdir do |directory|
      status, output = run_cli('check-oracle', qemu_class: FakeQemu.new(directory, passing: true), accelerators: %w[hvf],
                                               libc_test: ->(_) { 1 })
      assert_equal 1, status
      assert_includes output, 'oracle qemu hvf: passed'
      assert_includes output, 'libc-test hvf 4 CPUs: failed'
      refute_includes output, 'partial:'
    end
  end

  # Its runs go where a plain `oracle qemu` run's do not, so neither refuses
  # the other's directory.
  def test_check_oracle_and_oracle_qemu_use_separate_default_directories
    Dir.mktmpdir do |directory|
      qemu = FakeQemu.new(directory, passing: true)
      run_cli('check-oracle', qemu_class: qemu, accelerators: %w[hvf], libc_test: ->(_) { 0 })
      run_cli('oracle', 'qemu', qemu_class: qemu)
      check, plain = qemu.calls.grep(Hash).map { |options| options.fetch(:out) }.values_at(0, -1)
      assert_equal File.join(Erx::ROOT, 'build/check-oracle/hvf/kernel'), check
      assert_equal File.join(Erx::ROOT, 'build/oracle-qemu/stdlib'), plain
      refute check.start_with?(File.join(Erx::ROOT, 'build/oracle-qemu/'))
    end
  end

  def test_check_oracle_fails_without_hvf_and_never_falls_back_to_tcg
    Dir.mktmpdir do |directory|
      qemu = FakeQemu.new(directory, passing: true)
      status, output = run_cli('check-oracle', qemu_class: qemu, accelerators: %w[tcg], libc_test: ->(_) { flunk 'libc-test ran' })
      assert_equal 1, status
      assert_includes output, "failed: this host's QEMU does not offer hvf"
      assert_empty qemu.calls
    end
  end

  def test_check_oracle_fails_when_a_run_fails
    Dir.mktmpdir do |directory|
      status, output = run_cli('check-oracle', qemu_class: FakeQemu.new(directory, passing: false), accelerators: %w[tcg hvf],
                                                                        libc_test: ->(_) { 0 })
      assert_equal 1, status
      assert_includes output, 'oracle qemu hvf: failed'
      assert_includes output, 'libc-test hvf 4 CPUs: passed'
    end
  end

  def test_qemu_refuses_an_unknown_suite_before_running
    qemu = FakeQemu.new('unused', passing: true)
    status, output = run_cli('oracle', 'qemu', '--suites', 'kernel/no_such_SUITE', qemu_class: qemu)
    assert_equal 2, status
    assert_includes output, 'kernel/no_such_SUITE is no group'
    assert_empty qemu.calls
  end

  def test_qemu_passes_its_options_and_prints_the_report
    Dir.mktmpdir do |directory|
      qemu = FakeQemu.new(directory, passing: false)
      status, output = run_cli('oracle', 'qemu', '--out', directory, '--accel', 'hvf', '--cpus', '4', '--suites', 'kernel/file_SUITE',
                               qemu_class: qemu)
      assert_equal 1, status
      assert_includes output, 'overall: FAIL (kernel)'
      assert_includes output, 'kernel: guest hvf 4 CPU, 12 s'
      assert_equal [['file_SUITE'], { accel: 'hvf', cpus: 4, jobs: 4 }], qemu.calls.last
      assert_equal File.join(directory, 'kernel'), qemu.calls.first.fetch(:out)
    end
  end

  def test_qemu_command_line_hands_erts_the_reporter_one_word_per_argument
    line = Erx::OracleQemu.command_line(accel: 'tcg', limit: 2048)
    words = line.split(' ')
    assert_equal "erx.watchdog=#{Erx::ProductionImage::Run::TCG_WATCHDOG}", words.first
    assert_equal %W[-pa /lib/common_test/ebin -pa /lib/sasl/ebin -pa /lib/syntax_tools/ebin -pa /lib/tools/ebin -pa /test/ct/reporter
                    -run erx_ct_oracle main
                    /test/ct/suites /tmp/ct /ct-logs 268435456], words.drop(1).map { |word| word.delete_prefix('erx.arg=') }
    assert words.drop(1).all? { |word| word.start_with?('erx.arg=') }
    refute_includes Erx::OracleQemu.command_line(accel: 'hvf', limit: 2048), 'erx.watchdog'
  end

  # Bootstrap cuts a command line longer than the kernel takes at its last
  # whole word, so a guest handed a whole group's suites by name ran only
  # those that fit and the rest showed as unresolved. The line names no
  # suite, and one over the limit is refused, never booted.
  def test_qemu_command_line_fits_what_the_kernel_takes_or_is_refused
    limit = Erx::ABI::Generated::CODEC.constant('boot_strings_max')
    line = Erx::OracleQemu.command_line(accel: 'tcg', limit: limit)
    assert_operator line.bytesize, :<=, limit
    assert_equal line, Erx::OracleQemu.command_line(accel: 'tcg', limit: line.bytesize)
    assert_raises(Erx::Error) { Erx::OracleQemu.command_line(accel: 'tcg', limit: line.bytesize - 1) }
  end

  # The system shell redraws its prompt before the reporter's io:format line.
  def test_qemu_result_line_is_found_after_the_shell_prompt
    assert_match Erx::OracleQemu::RESULT, "% \b\b\e[Jerx-oracle-result {ok,{81,4,{6,0}}}\r\n".b
    refute_match Erx::OracleQemu::RESULT, "erx-oracle-event 10 00000000 {}\r\n".b
  end

  def test_native_suite_cannot_bypass_container
    status, output = run_cli('oracle', 'run', 'emulator', '--backend', 'native')
    assert_equal 2, status
    assert_includes output, 'bootstrap build only'
  end

  def test_jobs_are_bounded_before_backend_construction
    status, output = run_cli('oracle', 'build', '--jobs', '0')
    assert_equal 2, status
    assert_includes output, 'jobs must be between'
  end

  def test_linux_run_preserves_requested_selection_and_failed_baseline
    calls = []
    backend = Object.new
    backend.define_singleton_method(:run) do |suite, **options|
      calls << [suite, options]
      { 'state' => 'failed', 'report' => '/owned/suite-result.json' }
    end
    status, output = run_cli('oracle', 'run', 'kernel', '--docker-context', 'owned',
                             '--flavour', 'jit', '--jobs', '2', '--deadline', '60',
                             '--suite', 'basic_SUITE', '--case', 'simple', container_class: BackendFactory.new(backend))
    assert_equal 1, status
    assert_includes output, 'Linux host oracle: failed'
    assert_equal [['kernel', { flavour: 'jit', jobs: 2, deadline: 60,
                              test_suite: 'basic_SUITE', testcase: 'simple' }]], calls
  end

  def test_native_build_is_separately_labelled
    calls = []
    backend = Object.new
    backend.define_singleton_method(:build) { |**options| calls << options }
    status, output = run_cli('oracle', 'build', '--backend', 'native', '--flavour', 'jit', '--clean',
                             native_class: BackendFactory.new(backend))
    assert_equal 0, status
    assert_includes output, 'native stock OTP bootstrap jit ready'
    assert_equal [{ flavours: ['jit'], jobs: 4, clean: true }], calls
  end

  # Stands in for OracleHosted: records how each group's run was made and
  # what it ran, and reports a comparison of one unlisted difference.
  class FakeHosted
    attr_reader :calls

    def initialize
      @calls = []
    end

    def new(**options)
      @calls << options
      self
    end

    def run(suites)
      @calls << suites
      Erx::OracleHosted::Outcome.new(result: OracleCliTest.comparison(passing: false), report: 'unused')
    end
  end

  # A comparison of one case that passes on stock and, unless `passing`,
  # fails on erXos with no row of the table naming it.
  def self.comparison(passing:)
    key = Erx::OracleComparison::CaseKey.new(suite: 'a_SUITE', group: [], testcase: 'b', attempt: 1)
    side = ->(status) { Erx::OracleComparison::Side.new(state: 'complete', cases: { key => status }) }
    Erx::OracleComparison.compare(stock: side.call('passed'), erxos: side.call(passing ? 'passed' : 'failed'), known: [])
  end

  def test_hosted_refuses_an_unknown_suite_before_running
    hosted = FakeHosted.new
    status, output = run_cli('oracle', 'hosted', '--suites', 'kernel/no_such_SUITE', hosted_class: hosted)
    assert_equal 2, status
    assert_includes output, 'kernel/no_such_SUITE is no group'
    assert_empty hosted.calls
  end

  def test_hosted_needs_a_suites_group_for_a_suite
    hosted = FakeHosted.new
    status, output = run_cli('oracle', 'hosted', '--suites', 'file_SUITE', hosted_class: hosted)
    assert_equal 2, status
    assert_includes output, 'file_SUITE is no group'
    assert_empty hosted.calls
  end

  def test_the_combined_report_counts_every_group_and_names_the_failing_ones
    results = { 'kernel' => OracleCliTest.comparison(passing: true), 'stdlib' => OracleCliTest.comparison(passing: false) }
    report = Erx::OracleSuites.combined_report(results)
    assert_match(/^== kernel\n/, report)
    assert_match(/^all groups: differs 1, .* same 1\n/, report)
    assert report.end_with?("overall: FAIL (stdlib)\n")
  end

  def test_the_selection_names_groups_suites_and_fast
    root = File.expand_path('../..', __dir__)
    assert_equal({ 'kernel' => %w[file_SUITE], 'stdlib' => %w[filelib_SUITE] },
                 Erx::OracleSuites.select(%w[fast], root: root))
    compiler = Erx::OracleSuites.select(%w[compiler stdlib/filelib_SUITE], root: root)
    assert_equal %w[stdlib compiler], compiler.keys
    assert_includes compiler.fetch('compiler'), 'bif_SUITE'
    assert_equal %w[filelib_SUITE], compiler.fetch('stdlib')
  end

  # Common Test's erl2html2 parses each suite with syntax_tools' epp_dodger
  # before it runs it, and OTP's suites call syntax_tools' merl and tools'
  # cover, so a release without them cannot run a suite as stock does.
  def test_the_release_takes_the_stock_applications_common_test_needs
    Dir.mktmpdir do |directory|
      root = File.expand_path('../..', __dir__)
      install = File.join(directory, 'stock/lib/erlang/lib')
      %w[common_test-1.0 sasl-1.0 syntax_tools-1.0 tools-1.0].each do |application|
        FileUtils.mkdir_p(File.join(install, application, 'ebin'))
      end
      lib = File.join(directory, 'lib')
      FileUtils.mkdir_p(lib)
      suites = Erx::OracleSuites.new(root: root, out: directory, runner: nil, deadline: 1, group: 'compiler')
      suites.copy_stock_applications(lib, erl: File.join(directory, 'stock/bin/erl'))
      assert_equal %w[common_test sasl syntax_tools tools], Dir.children(lib).sort
    end
  end

  # Records the commands it is handed and runs none.
  class RecordingRunner
    attr_reader :commands

    def initialize = @commands = []
    def run(argv, **) = @commands << argv
  end

  # Answers every command as passed and keeps its argument vector.
  class PassingRunner < RecordingRunner
    def run(argv, **)
      super
      { 'state' => 'passed', 'elapsed_seconds' => 1 }
    end
  end

  # A suite skips the cases that need more schedulers than are online, so
  # stock runs as many as the guest has CPUs, and the hosted run keeps
  # ERTS's default on both sides.
  def test_stock_runs_the_schedulers_it_is_given
    Dir.mktmpdir do |directory|
      root = File.expand_path('../..', __dir__)
      [[1, %w[+S 1:1]], [nil, []]].each do |schedulers, flags|
        runner = PassingRunner.new
        suites = Erx::OracleSuites.new(root: root, out: directory, runner: runner, deadline: 1, group: 'stdlib')
        suites.run_stock(File.join(directory, 'tree'), erl: '/stock/bin/erl', schedulers: schedulers)
        stock = runner.commands.first
        assert_equal ['/stock/bin/erl', *flags, '-sname'], stock.first(flags.size + 2)
      end
    end
  end

  # OTP's compiler test Makefile installs compiler's generated
  # beam_opcodes.hrl beside the suites. Without it compile_SUITE warnings
  # fails, leaving workers that reload the compiler modules pre_load_check
  # unloads, so pre_load_check fails on a host with several schedulers.
  def test_the_compiler_suites_get_the_header_their_makefile_installs_beside_them
    Dir.mktmpdir do |directory|
      root = File.expand_path('../..', __dir__)
      stock = File.join(directory, 'stock')
      src = File.join(stock, 'lib/compiler/src')
      FileUtils.mkdir_p(src)
      File.write(File.join(src, 'beam_opcodes.hrl'), "-define(tag_u, 0).\n")
      File.write(File.join(src, 'genop.tab'), "1: label/1\n")
      compiled = %w[compiler stdlib].to_h do |group|
        target = File.join(directory, group)
        FileUtils.mkdir_p(target)
        suites = Erx::OracleSuites.new(root: root, out: directory, runner: RecordingRunner.new, deadline: 1, group: group)
        [group, suites.compile(reporter: target, suite_directory: target, suites: [], erlc: 'erlc', stock_source: stock)]
      end
      header = File.join(directory, 'compiler/beam_opcodes.hrl')
      assert File.file?(header)
      assert_includes compiled.fetch('compiler'),
                      Erx::OracleSuites::Compiled.new(path: header, source: File.join(src, 'genop.tab'))
      refute File.exist?(File.join(directory, 'stdlib/beam_opcodes.hrl'))
      File.delete(File.join(src, 'genop.tab'))
      runner = RecordingRunner.new
      suites = Erx::OracleSuites.new(root: root, out: directory, runner: runner, deadline: 1, group: 'compiler')
      error = assert_raises(Erx::Error) do
        suites.compile(reporter: directory, suite_directory: File.join(directory, 'compiler'), suites: [], erlc: 'erlc',
                       stock_source: stock)
      end
      assert_includes error.message, 'genop.tab'
      assert_empty runner.commands, 'a missing header is refused before anything compiles'
      File.write(File.join(src, 'genop.tab'), "1: label/1\n")
      shadowing = File.join(directory, 'shadowing')
      FileUtils.mkdir_p(File.join(shadowing, 'otp/lib/compiler/test'))
      File.write(File.join(shadowing, 'otp/lib/compiler/test/beam_opcodes.hrl'), "-define(tag_u, 1).\n")
      suites = Erx::OracleSuites.new(root: shadowing, out: directory, runner: RecordingRunner.new, deadline: 1, group: 'compiler')
      error = assert_raises(Erx::Error) do
        suites.compile(reporter: directory, suite_directory: File.join(directory, 'compiler'), suites: [], erlc: 'erlc',
                       stock_source: stock)
      end
      assert_includes error.message, 'has its own beam_opcodes.hrl'
    end
  end

  def test_hosted_runs_each_group_in_its_own_directory_and_prints_the_combined_report
    Dir.mktmpdir do |directory|
      hosted = FakeHosted.new
      status, output = run_cli('oracle', 'hosted', '--out', directory, '--suites', 'stdlib/filelib_SUITE,kernel/file_SUITE',
                               hosted_class: hosted)
      assert_equal 1, status
      assert_includes output, 'differs    a_SUITE b #1'
      assert_includes output, 'overall: FAIL (kernel, stdlib)'
      assert_equal [{ group: 'kernel', out: File.join(directory, 'kernel') }, ['file_SUITE'],
                    { group: 'stdlib', out: File.join(directory, 'stdlib') }, ['filelib_SUITE']],
                   hosted.calls.map { |call| call.is_a?(Hash) ? call.slice(:group, :out) : call }
      assert File.file?(File.join(directory, 'report.txt'))
    end
  end
end
