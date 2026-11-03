# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
load File.expand_path('../../tools/erx', __dir__) unless defined?(Erx::CLI)

class OracleCliTest < Minitest::Test
  def run_cli(*arguments)
    status = nil
    _stdout, output = capture_io { status = Erx::CLI.run(arguments) }
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
    Erx::OracleContainer.stub(:new, backend) do
      status, output = run_cli('oracle', 'run', 'kernel', '--docker-context', 'owned',
                               '--flavour', 'jit', '--jobs', '2', '--deadline', '60',
                               '--suite', 'basic_SUITE', '--case', 'simple')
      assert_equal 1, status
      assert_includes output, 'Linux host oracle: failed'
      assert_equal [['kernel', { flavour: 'jit', jobs: 2, deadline: 60,
                                test_suite: 'basic_SUITE', testcase: 'simple' }]], calls
    end
  end

  def test_native_build_is_separately_labelled
    calls = []
    backend = Object.new
    backend.define_singleton_method(:build) { |**options| calls << options }
    Erx::Oracle.stub(:new, backend) do
      status, output = run_cli('oracle', 'build', '--backend', 'native', '--flavour', 'jit', '--clean')
      assert_equal 0, status
      assert_includes output, 'native stock OTP bootstrap jit ready'
      assert_equal [{ flavours: ['jit'], jobs: 4, clean: true }], calls
    end
  end
end
