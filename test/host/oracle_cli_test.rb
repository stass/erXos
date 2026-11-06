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

    def run(suites, **options)
      @calls << [suites, options]
      Erx::OracleQemu::Outcome.new(result: OracleCliTest.comparison(passing: @passing), report: 'unused', seconds: 12.4)
    end
  end

  def test_check_oracle_runs_under_hvf_only_and_says_what_it_leaves_out
    Dir.mktmpdir do |directory|
      qemu = FakeQemu.new(directory, passing: true)
      status, output = run_cli('check-oracle', qemu_class: qemu, accelerators: %w[hvf tcg])
      assert_equal 2, status, 'a run that passed but leaves parts out is partial, not passed'
      assert_includes output, 'oracle qemu hvf: passed'
      refute_includes output, 'oracle qemu tcg'
      assert_includes output, 'partial: the system domain runs kernel/file_SUITE and stdlib/filelib_SUITE'
      assert_equal [[%w[file_SUITE], { accel: 'hvf', cpus: 1, jobs: 4 }], [%w[filelib_SUITE], { accel: 'hvf', cpus: 1, jobs: 4 }]],
                   qemu.calls.grep(Array)
    end
  end

  # Its runs go where a plain `oracle qemu` run's do not, so neither refuses
  # the other's directory.
  def test_check_oracle_and_oracle_qemu_use_separate_default_directories
    Dir.mktmpdir do |directory|
      qemu = FakeQemu.new(directory, passing: true)
      run_cli('check-oracle', qemu_class: qemu, accelerators: %w[hvf])
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
      status, output = run_cli('check-oracle', qemu_class: qemu, accelerators: %w[tcg])
      assert_equal 1, status
      assert_includes output, "failed: this host's QEMU does not offer hvf"
      assert_empty qemu.calls
    end
  end

  def test_check_oracle_fails_when_a_run_fails
    Dir.mktmpdir do |directory|
      status, output = run_cli('check-oracle', qemu_class: FakeQemu.new(directory, passing: false), accelerators: %w[tcg hvf])
      assert_equal 1, status
      assert_includes output, 'oracle qemu hvf: failed'
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
    line = Erx::OracleQemu.command_line(%w[file_SUITE], accel: 'tcg')
    words = line.split(' ')
    assert_equal "erx.watchdog=#{Erx::ProductionImage::Run::TCG_WATCHDOG}", words.first
    assert_equal %w[-pa /lib/common_test/ebin -pa /lib/sasl/ebin -pa /lib/syntax_tools/ebin -pa /lib/tools/ebin -pa /test/ct/reporter
                    -run erx_ct_oracle main
                    /test/ct/suites /tmp/ct file_SUITE], words.drop(1).map { |word| word.delete_prefix('erx.arg=') }
    assert words.drop(1).all? { |word| word.start_with?('erx.arg=') }
    refute_includes Erx::OracleQemu.command_line(%w[file_SUITE], accel: 'hvf'), 'erx.watchdog'
    assert_raises(Erx::Error) { Erx::OracleQemu.command_line(['a SUITE'], accel: 'tcg') }
  end

  # The system shell redraws its prompt before the reporter's io:format line.
  def test_qemu_result_line_is_found_after_the_shell_prompt
    assert_match Erx::OracleQemu::RESULT, "1> \b\b\b\e[Jerx-oracle-result {ok,{81,4,{6,0}}}\r\n".b
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
