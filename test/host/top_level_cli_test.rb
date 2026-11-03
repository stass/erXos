# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
load File.expand_path('../../tools/erx', __dir__) unless defined?(Erx::CLI)

class TopLevelCliTest < Minitest::Test
  def run_cli(*arguments)
    status = nil
    _stdout, output = capture_io { status = Erx::CLI.run(arguments) }
    [status, output]
  end

  def recording_runner(commands, fail_name: nil)
    Object.new.tap do |runner|
      runner.define_singleton_method(:run) do |argv, **options|
        commands << [argv, options]
        if options.fetch(:name) == fail_name
          raise Erx::CommandError, { 'state' => 'failed', 'log' => '/evidence/failure.log' }
        end
        { 'state' => 'succeeded' }
      end
    end
  end

  def with_checks(commands, fail_name: nil)
    checker = Object.new
    checker.define_singleton_method(:run) { true }
    runtime = proc do |**_options, &block|
      block.call('ERX_ERL' => '/verified/erl', 'ERX_ERLC' => '/verified/erlc')
    end
    Erx::Runner.stub(:new, recording_runner(commands, fail_name: fail_name)) do
      Erx::Checks.stub(:new, checker) do
        Erx::ArchTerms.stub(:check, true) do
          Erx::CLI.stub(:with_test_runtime, runtime) { yield }
        end
      end
    end
  end

  def test_check_runs_every_generation_gate_and_real_renderer_integration
    commands = []
    with_checks(commands) do
      status, output = run_cli('check')
      assert_equal 0, status, output
    end
    generated = commands.select { |_argv, options| options.fetch(:name).start_with?('check-gen-', 'check-sysreg') }
    scripts = generated.map { |argv, _options| File.basename(argv[1]) }.sort
    assert_equal %w[gen_abi.rb gen_hw.rb gen_terminal.rb sysreg_extract.rb], scripts
    assert generated.all? { |argv, _options| argv.last == '--check' }
    host = commands.find { |_argv, options| options.fetch(:name) == 'host-tests' }
    assert host
    assert_operator host.last.fetch(:deadline), :>, 180
    integration = commands.find { |_argv, options| options.fetch(:name) == 'native-integration' }
    assert integration.first.any? { |argument| argument.end_with?('/terminal_tables_test.rb') }
    assert integration.first.any? { |argument| argument.end_with?('/structural_pack_test.rb') }
    assert_equal '/verified/erl', integration.last.fetch(:env).fetch('ERX_ERL')
    refute commands.any? { |argv, _options| argv.include?('fetch') || argv.include?('emulator_test') }
  end

  def test_failed_renderer_integration_fails_the_aggregate_gate
    commands = []
    with_checks(commands, fail_name: 'native-integration') do
      status, output = run_cli('check')
      assert_equal 1, status
      assert_includes output, '/evidence/failure.log'
      refute_includes output, 'checks passed'
    end
  end

  def test_unbuilt_native_jit_does_not_start_host_tests
    commands = []
    checker = Object.new
    checker.define_singleton_method(:run) { true }
    oracle = Object.new
    oracle.define_singleton_method(:with_runtime) { |_flavour, &_block| raise Erx::Error, 'not built' }
    Erx::Runner.stub(:new, recording_runner(commands)) do
      Erx::Checks.stub(:new, checker) do
        Erx::ArchTerms.stub(:check, true) do
          Erx::CLI.stub(:host_environment, {}) do
            Erx::Oracle.stub(:new, oracle) do
              status, output = run_cli('check')
              assert_equal 1, status
              assert_includes output, 'not built'
            end
          end
        end
      end
    end
    refute commands.any? { |_argv, options| options.fetch(:name) == 'host-tests' }
  end

  def test_production_pack_reports_unsupported_startup
    status, output = run_cli('pack')
    assert_equal 1, status
    assert_includes output, 'unsupported root_startup'
  end

  def test_sanitizer_gate_instruments_the_pack_and_elf_regression_corpora
    commands = []
    with_checks(commands) do
      status, output = run_cli('check-sanitizers')
      assert_equal 0, status, output
    end
    tests = commands.find { |_argv, options| options.fetch(:name) == 'sanitizer-tests' }
    assert tests.first.any? { |argument| argument.end_with?('/pack_test.rb') }
    assert tests.first.any? { |argument| argument.end_with?('/elf_plan_test.rb') }
    assert_equal 'address,undefined', tests.last.fetch(:env).fetch('ERX_SANITIZERS')
  end

  def test_fuzz_limits_are_checked_before_starting_commands
    Erx::Runner.stub(:new, proc { raise 'unexpected command setup' }) do
      status, output = run_cli('check-fuzz', '--runs', '0')
      assert_equal 2, status
      assert_includes output, 'outside bounds'
    end
  end

  def test_generation_gate_refuses_trailing_arguments
    Erx::Runner.stub(:new, proc { raise 'unexpected command setup' }) do
      status, output = run_cli('check-generated', 'ignored')
      assert_equal 2, status
      assert_includes output, 'unexpected arguments'
    end
  end

  def test_malformed_status_record_fails_through_the_escaped_cli_boundary
    Dir.mktmpdir('erx-cli-status-') do |directory|
      path = File.join(directory, 'record.json')
      File.binwrite(path, "{\e]0;untrusted\a".b)
      Dir.stub(:glob, [path]) do
        status, output = run_cli('status')
        assert_equal 1, status
        refute_includes output, "\e"
        refute_includes output, "\a"
      end
    end
  end

  def test_status_rejects_invalid_fields_and_oversized_records
    valid = { 'state' => 'running', 'argv' => ['fixture'], 'started_at' => '2026-01-01T00:00:00Z',
              'deadline_seconds' => 30, 'log' => '/fixture.log' }
    mutations = [{ 'argv' => [] }, { 'started_at' => '2026-99-99T00:00:00Z' },
                 { 'deadline_seconds' => 0 }, { 'log' => 42 }, { 'state' => 'invented' }]
    mutations.each do |mutation|
      assert_raises(Erx::Error) { Erx::CLI.send(:status_record, JSON.generate(valid.merge(mutation))) }
    end
    assert_raises(Erx::Error) { Erx::CLI.send(:status_record, ' ' * 65_537) }
    record = Erx::CLI.send(:status_record, JSON.generate(valid))
    assert_equal Time.utc(2026, 1, 1), record.fetch('started_at')
  end

  def test_status_refuses_a_named_pipe_without_waiting_for_a_writer
    Dir.mktmpdir('erx-cli-status-fifo-') do |directory|
      path = File.join(directory, 'record.json')
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
      runner.run(['mkfifo', path], name: 'status-fifo', deadline: 10)
      Dir.stub(:glob, [path]) do
        status, output = run_cli('status')
        assert_equal 1, status
        assert_includes output, 'bounded regular file'
      end
    end
  end

  def test_nondefault_fuzz_options_reach_the_declared_target_groups
    commands = []
    observed = []
    c = proc { |**options| observed << [:c, options.fetch(:runs), options.fetch(:seed)] }
    ruby = proc { |**options| observed << [:ruby, options.fetch(:seconds), options.fetch(:seed)] }
    with_checks(commands) do
      Erx::CLI.stub(:fuzz_c, c) do
        Erx::CLI.stub(:fuzz_ruby, ruby) do
          status, output = run_cli('check-fuzz', '--seconds', '7', '--runs', '1234', '--seed', '19')
          assert_equal 0, status
          assert_includes output, 'fixed 20000 iterations, seed 1'
        end
      end
    end
    assert_equal [[:c, 1234, 19], [:ruby, 7, 19]], observed
  end
end
