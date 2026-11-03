# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
load File.expand_path('../../tools/erx', __dir__) unless defined?(Erx::CLI)

class TopLevelCliTest < Minitest::Test
  Factory = Struct.new(:instance) do
    def new(**) = instance
  end

  class UnexpectedRunner
    def self.new(**) = raise 'unexpected command setup'
  end

  class PassingChecks
    def run = true
    def check(**) = true
  end

  class UnbuiltOracle
    def with_runtime(_flavour) = raise Erx::Error, 'not built'
  end

  StatusDirectories = Struct.new(:path) do
    def glob(_pattern) = [path]
  end

  def run_cli(*arguments, **collaborators)
    status = nil
    _stdout, output = capture_io { status = Erx::CLI.run(arguments, **collaborators) }
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
    runtime = proc do |**_options, &block|
      block.call('ERX_ERL' => '/verified/erl', 'ERX_ERLC' => '/verified/erlc')
    end
    yield runner_class: Factory.new(recording_runner(commands, fail_name: fail_name)),
          checks_class: Factory.new(PassingChecks.new), arch_terms: PassingChecks.new, runtime: runtime
  end

  def test_check_runs_every_generation_gate_and_real_renderer_integration
    commands = []
    with_checks(commands) do |collaborators|
      status, output = run_cli('check', **collaborators)
      assert_equal 0, status, output
    end
    generated = commands.select { |_argv, options| options.fetch(:name).start_with?('check-gen-', 'check-sysreg') }
    scripts = generated.map { |argv, _options| File.basename(argv[1]) }.sort
    assert_equal %w[gen_abi.rb gen_hw.rb gen_terminal.rb sysreg_extract.rb], scripts
    assert generated.all? { |argv, _options| argv.last == '--check' }
    proof = commands.find { |_argv, options| options.fetch(:name) == 'stack-proof' }
    assert proof, 'check runs the stack proof'
    assert proof.first[1].end_with?('/tools/stack_proof.rb')
    assert_equal '/verified/erl', proof.last.fetch(:env).fetch('ERX_ERL')
    host = commands.find { |_argv, options| options.fetch(:name) == 'host-tests' }
    assert host
    assert_operator host.last.fetch(:deadline), :>, 180
    integration = commands.find { |_argv, options| options.fetch(:name) == 'native-integration' }
    assert integration.first.any? { |argument| argument.end_with?('/terminal_tables_test.rb') }
    assert integration.first.any? { |argument| argument.end_with?('/structural_pack_test.rb') }
    assert integration.first.any? { |argument| argument.end_with?('/fiasco_config_test.rb') }
    assert_equal '/verified/erl', integration.last.fetch(:env).fetch('ERX_ERL')
    refute commands.any? { |argv, _options| argv.include?('fetch') || argv.include?('emulator_test') }
  end

  def test_check_stack_proof_runs_the_proof_with_the_verified_toolchain
    commands = []
    verified = ->(runner:) { runner && { 'ERX_CLANG' => '/verified/clang' } }
    status, output = run_cli('check-stack-proof', runner_class: Factory.new(recording_runner(commands)),
                                                  host_environment: verified)
    assert_equal 0, status, output
    assert_equal ['stack-proof'], commands.map { |_argv, options| options.fetch(:name) }
    assert commands.first.first[1].end_with?('/tools/stack_proof.rb')
    assert_equal '/verified/clang', commands.first.last.fetch(:env).fetch('ERX_CLANG')

    commands.clear
    status, output = run_cli('check-stack-proof', runner_class: Factory.new(recording_runner(commands, fail_name: 'stack-proof')),
                                                  host_environment: verified)
    assert_equal 1, status
    assert_includes output, '/evidence/failure.log'
  end

  def test_failed_renderer_integration_fails_the_aggregate_gate
    commands = []
    with_checks(commands, fail_name: 'native-integration') do |collaborators|
      status, output = run_cli('check', **collaborators)
      assert_equal 1, status
      assert_includes output, '/evidence/failure.log'
      refute_includes output, 'checks passed'
    end
  end

  def test_unbuilt_native_jit_does_not_start_host_tests
    commands = []
    runtime = lambda do |runner:, &block|
      Erx::CLI.send(:with_test_runtime, runner: runner, oracle_class: Factory.new(UnbuiltOracle.new),
                    host_environment: ->(**) { {} }, &block)
    end
    with_checks(commands) do |collaborators|
      status, output = run_cli('check', **collaborators.merge(runtime: runtime))
      assert_equal 1, status
      assert_includes output, 'not built'
    end
    refute commands.any? { |_argv, options| options.fetch(:name) == 'host-tests' }
  end

  def test_production_pack_reports_unsupported_startup
    status, output = run_cli('pack')
    assert_equal 1, status
    assert_includes output, 'unsupported root_startup'
  end

  def test_commands_refuse_unsupported_collaborators
    %w[check check-generated check-reproducible check-fuzz check-sanitizers check-ubsan check-stack-proof pack status fetch check-tla check-sources check-arch-terms build qemu oracle bench check-oracle --help -h].each do |command|
      assert_raises(ArgumentError, command) { run_cli(command, unexpected: Object.new) }
    end
  end

  def test_sanitizer_gate_instruments_the_pack_and_elf_regression_corpora
    commands = []
    with_checks(commands) do |collaborators|
      status, output = run_cli('check-sanitizers', **collaborators.slice(:runner_class, :runtime))
      assert_equal 0, status, output
    end
    tests = commands.find { |_argv, options| options.fetch(:name) == 'sanitizer-tests' }
    assert tests.first.any? { |argument| argument.end_with?('/pack_test.rb') }
    assert tests.first.any? { |argument| argument.end_with?('/elf_plan_test.rb') }
    assert tests.first.any? { |argument| argument.end_with?('/watchdog_test.rb') }
    assert tests.first.any? { |argument| argument.end_with?('/tlb_plan_test.rb') }
    assert_equal 'address,undefined', tests.last.fetch(:env).fetch('ERX_SANITIZERS')
  end

  def test_fuzz_limits_are_checked_before_starting_commands
    status, output = run_cli('check-fuzz', '--runs', '0', runner_class: UnexpectedRunner)
    assert_equal 2, status
    assert_includes output, 'outside bounds'
  end

  def test_generation_gate_refuses_trailing_arguments
    status, output = run_cli('check-generated', 'ignored', runner_class: UnexpectedRunner)
    assert_equal 2, status
    assert_includes output, 'unexpected arguments'
  end

  def test_malformed_status_record_fails_through_the_escaped_cli_boundary
    Dir.mktmpdir('erx-cli-status-') do |directory|
      path = File.join(directory, 'record.json')
      File.binwrite(path, "{\e]0;untrusted\a".b)
      status, output = run_cli('status', directories: StatusDirectories.new(path))
      assert_equal 1, status
      refute_includes output, "\e"
      refute_includes output, "\a"
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
      status, output = run_cli('status', directories: StatusDirectories.new(path))
      assert_equal 1, status
      assert_includes output, 'bounded regular file'
    end
  end

  def test_nondefault_fuzz_options_reach_the_declared_target_groups
    commands = []
    observed = []
    c = proc { |**options| observed << [:c, options.fetch(:runs), options.fetch(:seed)] }
    ruby = proc { |**options| observed << [:ruby, options.fetch(:seconds), options.fetch(:seed)] }
    with_checks(commands) do |collaborators|
      status, output = run_cli('check-fuzz', '--seconds', '7', '--runs', '1234', '--seed', '19',
                               **collaborators.slice(:runner_class, :runtime), c_fuzzer: c, ruby_fuzzer: ruby)
      assert_equal 0, status
      assert_includes output, 'fixed 20000 iterations, seed 1'
    end
    assert_equal [[:c, 1234, 19], [:ruby, 7, 19]], observed
  end
end
