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

  def test_target_parity_is_explicitly_unsupported
    status, output = run_cli('check-oracle')
    assert_equal 1, status
    assert_includes output, 'unsupported'
    assert_includes output, 'target ERTS and libc-test'
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

  # Stands in for OracleHosted: records how it was made and what it ran, and
  # reports a comparison with one unlisted difference.
  class FakeHosted
    attr_reader :calls

    def initialize(report)
      @report = report
      @calls = []
    end

    def new(**options)
      @calls << options
      self
    end

    def run(suites)
      @calls << suites
      File.write(@report, "differs    a_SUITE b #1: stock passed, erXos failed, not in the table\nresult: FAIL\n")
      Erx::OracleHosted::Outcome.new(result: Struct.new(:passed?).new(false), report: @report)
    end
  end

  def test_hosted_refuses_an_unknown_suite_before_running
    hosted = FakeHosted.new('unused')
    status, output = run_cli('oracle', 'hosted', 'kernel_SUITE', hosted_class: hosted)
    assert_equal 2, status
    assert_includes output, 'unknown suites: kernel_SUITE'
    assert_empty hosted.calls
  end

  def test_hosted_prints_the_report_and_fails_with_the_comparison
    Dir.mktmpdir do |directory|
      hosted = FakeHosted.new(File.join(directory, 'report.txt'))
      status, output = run_cli('oracle', 'hosted', '--out', directory, 'filelib_SUITE', hosted_class: hosted)
      assert_equal 1, status
      assert_includes output, 'differs    a_SUITE b #1'
      assert_equal ['filelib_SUITE'], hosted.calls.last
      assert_equal directory, hosted.calls.first.fetch(:out)
    end
  end
end
