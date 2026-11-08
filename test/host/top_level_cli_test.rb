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

  def setup
    @directory = Dir.mktmpdir('erx-cli-')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  # A log that ends the way a Minitest run does, for the pool's check that
  # a file ran tests.
  def passing_log
    @passing_log ||= File.join(@directory, 'passing.log').tap do |path|
      File.write(path, "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips\n")
    end
  end

  def recording_runner(commands, fail_name: nil)
    log = passing_log
    Object.new.tap do |runner|
      runner.define_singleton_method(:run) do |argv, **options|
        commands << [argv, options]
        if fail_name && options.fetch(:name).start_with?(fail_name)
          raise Erx::CommandError, { 'state' => 'failed', 'log' => '/evidence/failure.log' }
        end
        { 'state' => 'succeeded', 'log' => log }
      end
    end
  end

  # The commands a step ran: one per test file, named after the step.
  def step_commands(commands, step)
    commands.select { |_argv, options| options.fetch(:name).start_with?("#{step}-") }
  end

  def with_checks(commands, fail_name: nil)
    runtime = proc do |**_options, &block|
      block.call('ERX_ERL' => '/verified/erl', 'ERX_ERLC' => '/verified/erlc')
    end
    rc_oracle = ->(runner:) { commands << [['ensure-rc-oracle'], { name: 'rc-oracle', runner: runner }] }
    yield runner_class: Factory.new(recording_runner(commands, fail_name: fail_name)),
          checks_class: Factory.new(PassingChecks.new), arch_terms: PassingChecks.new, runtime: runtime,
          rc_oracle: rc_oracle
  end

  # The gate needs HVF for its suites and TCG for its smoke and deterministic boots, and never
  # falls back from one to the other: a host without HVF fails before anything is built.
  def test_check_qemu_fails_clearly_when_hvf_is_not_offered
    log = File.join(@directory, 'accel.log')
    File.write(log, "Accelerators supported in QEMU binary:\ntcg\n")
    runner = Object.new.tap { |fake| fake.define_singleton_method(:run) { |_argv, **_options| { 'log' => log } } }
    fiasco = Class.new { define_method(:new) { |**| raise 'must not build' } }.new
    status, output = run_cli('check-qemu', runner_class: Factory.new(runner), fiasco_class: fiasco)
    assert_equal 1, status
    assert_includes output, 'does not offer hvf, which the gate needs (offered: tcg)'
  end

  def test_check_qemu_takes_no_accelerator_choice
    status, output = run_cli('check-qemu', '--accel', 'tcg,hvf', runner_class: UnexpectedRunner)
    assert_equal 2, status
    assert_includes output, '--accel'
  end

  def test_check_qemu_refuses_an_unknown_suite_before_running_anything
    status, output = run_cli('check-qemu', '--suite', 'native_task', '--suite', 'no_such_suite', runner_class: UnexpectedRunner)
    assert_equal 2, status
    assert_includes output, 'unknown suites: no_such_suite'
  end

  # Each command a gate suite stands for runs what its suite runs, under HVF.
  def test_the_suite_commands_take_no_accelerator_choice
    %w[check-boot-image check-debug-log conformance].each do |command|
      status, output = run_cli(command, '--accel', 'tcg')
      assert_equal 2, status, command
      assert_includes output, '--accel', command
    end
  end

  def test_check_runs_the_stack_proof_and_native_integration
    commands = []
    with_checks(commands) do |collaborators|
      status, output = run_cli('check', **collaborators)
      assert_equal 0, status, output
    end
    proof = commands.find { |_argv, options| options.fetch(:name) == 'stack-proof' }
    assert proof, 'check runs the stack proof'
    assert proof.first[1].end_with?('/tools/stack_proof.rb')
    assert_equal '/verified/erl', proof.last.fetch(:env).fetch('ERX_ERL')
    host = step_commands(commands, 'host-tests')
    discovered = Dir.glob(File.join(Erx::ROOT, 'test/host/*_test.rb'))
    assert_equal discovered.sort, host.map { |argv, _options| argv.last }.sort
    assert host.all? { |_argv, options| options.fetch(:deadline) > 180 }
    integration = step_commands(commands, 'native-integration')
    %w[terminal_tables structural_pack fiasco_config pack_fixture sanitizer_gate].each do |name|
      assert integration.any? { |argv, _options| argv.last.end_with?("/#{name}_test.rb") }, name
    end
    assert integration.all? { |_argv, options| options.fetch(:env).fetch('ERX_ERL') == '/verified/erl' }
    refute commands.any? { |argv, _options| argv.include?('fetch') || argv.include?('emulator_test') }
  end

  # The command shell's integration tests read the rc oracle, so check makes sure of it
  # before the runtime and every test.
  def test_check_ensures_the_rc_oracle_before_the_tests
    commands = []
    with_checks(commands) do |collaborators|
      status, output = run_cli('check', **collaborators)
      assert_equal 0, status, output
    end
    names = commands.map { |_argv, options| options.fetch(:name) }
    assert_equal 1, names.count('rc-oracle')
    assert_operator names.index('rc-oracle'), :<, names.index { |name| name.start_with?('stack-proof', 'host-tests-') }
  end

  # A tree without a current rc oracle builds one and locates it again, so a build that
  # leaves nothing behind fails check rather than its tests.
  def test_ensure_rc_oracle_builds_what_locate_refuses
    builds = []
    build_class = Class.new do
      define_method(:initialize) { |root:, runner:| builds << [root, runner] }
      define_method(:call) { nil }
    end
    assert_raises(Erx::RcOracle::MissingBuild) do
      Erx::CLI.ensure_rc_oracle(runner: :runner, root: @directory, build_class: build_class)
    end
    assert_equal [[@directory, :runner]], builds
  end

  # A current rc oracle is kept as it is: no build runs and its files stay untouched.
  def test_ensure_rc_oracle_keeps_a_current_build
    stamp = write_rc_oracle(commit: nil)
    before = File.binread(stamp)
    build_class = Class.new do
      define_method(:initialize) { |**| raise 'a current oracle was rebuilt' }
    end
    oracle = Erx::CLI.ensure_rc_oracle(runner: :runner, root: @directory, build_class: build_class)
    assert_equal File.join(@directory, Erx::RcOracle::OUTPUT, 'rc'), oracle.rc
    assert_equal before, File.binread(stamp)
  end

  # A stale rc oracle, built from another pin, is rebuilt, and the rebuilt one is located.
  def test_ensure_rc_oracle_rebuilds_a_stale_build
    write_rc_oracle(commit: '0' * 40)
    assert_rebuilt_by_ensure_rc_oracle
  end

  # A build record cut short does not parse; ensure_rc_oracle rebuilds over it rather than
  # failing check.
  def test_ensure_rc_oracle_rebuilds_over_a_corrupt_record
    File.write(write_rc_oracle(commit: nil), '{"source": ')
    assert_rebuilt_by_ensure_rc_oracle
  end

  def assert_rebuilt_by_ensure_rc_oracle
    builds = []
    test = self
    build_class = Class.new do
      define_method(:initialize) { |root:, runner:| builds << [root, runner] }
      define_method(:call) { test.write_rc_oracle(commit: nil) }
    end
    oracle = Erx::CLI.ensure_rc_oracle(runner: :runner, root: @directory, build_class: build_class)
    assert_equal [[@directory, :runner]], builds
    assert_equal File.join(@directory, Erx::RcOracle::OUTPUT, 'rc'), oracle.rc
  end

  # An rc oracle build in the test's tree: its build record names the tree's plan9port pin,
  # or that pin with another commit when commit is given. Returns the record's path.
  def write_rc_oracle(commit:)
    FileUtils.cp(File.expand_path('../../deps.lock', __dir__), @directory)
    output = File.join(@directory, Erx::RcOracle::OUTPUT)
    FileUtils.mkdir_p(output)
    File.write(File.join(output, 'rc'), '', perm: 0o755)
    File.write(File.join(output, 'rcmain'), '')
    source = Erx::RcOracle.source_record(root: @directory)
    source = source.merge('commit' => commit) if commit
    File.join(output, 'build.json').tap do |path|
      File.write(path, JSON.generate('source' => source, 'recipe' => Erx::RcOracle::Build::RECIPE))
    end
  end

  # check-litmus builds herd7 when Herd.locate refuses what is there: missing, built
  # from another pin, or with a record cut short; a current build is kept untouched.
  def test_ensure_herd7_builds_only_what_locate_refuses
    builds = []
    test = self
    directory = @directory
    build_class = Class.new do
      define_method(:initialize) { |root:, runner:| builds << [root, runner] }
      define_method(:call) do
        test.write_herd7(version: nil)
        Erx::Herd.locate(root: directory)
      end
    end
    FileUtils.cp(File.expand_path('../../deps.lock', __dir__), @directory)
    [-> {}, -> { write_herd7(version: '7.57') }, -> { File.write(write_herd7(version: nil), '{"source": ') }].each do |prepare|
      FileUtils.rm_rf(File.join(@directory, Erx::Herd::OUTPUT))
      prepare.call
      builds.clear
      herd = Erx::CLI.ensure_herd7(runner: :runner, root: @directory, build_class: build_class)
      assert_equal [[@directory, :runner]], builds
      assert_equal File.join(@directory, Erx::Herd::OUTPUT, Erx::Herd::PROGRAM), herd.program
    end

    stamp = write_herd7(version: nil)
    before = File.binread(stamp)
    keeper = Class.new { define_method(:initialize) { |**| raise 'a current herd7 was rebuilt' } }
    herd = Erx::CLI.ensure_herd7(runner: :runner, root: @directory, build_class: keeper)
    assert_equal File.join(@directory, Erx::Herd::OUTPUT, Erx::Herd::LIBRARY), herd.libdir
    assert_equal before, File.binread(stamp)
  end

  # A herd7 build in the test's tree: its build record names the tree's herdtools7 pin,
  # or that pin with another version when version is given. Returns the record's path.
  def write_herd7(version:)
    output = File.join(@directory, Erx::Herd::OUTPUT)
    FileUtils.mkdir_p([File.join(output, 'bin'), File.join(output, Erx::Herd::LIBRARY)])
    File.write(File.join(output, Erx::Herd::PROGRAM), '', perm: 0o755)
    source = Erx::Herd.source_record(root: @directory)
    source = source.merge('version' => version) if version
    File.join(output, Erx::Herd::STAMP).tap do |path|
      File.write(path, JSON.generate('source' => source, 'recipe' => Erx::Herd::Build::RECIPE))
    end
  end

  # Arm's archive is read only by `tools/erx sysreg refresh` and by
  # test/integration/sysreg_refresh_test.rb, which `make check` excuses, so
  # `make check` works in a tree that never fetched arm-registers. Host tests
  # are exempt by path: test/host/sysreg_test.rb works on synthetic trees.
  def test_check_needs_no_arm_registers_download
    commands = []
    with_checks(commands) do |collaborators|
      status, output = run_cli('check', **collaborators)
      assert_equal 0, status, output
    end
    host = File.join(Erx::ROOT, 'test/host/')
    readers = commands.reject { |argv, _options| argv.last.start_with?(host) }.select do |argv, options|
      (argv + [options.fetch(:name)]).any? { |word| word.to_s.match?(/sysreg|arm-registers|Registers\.json/) }
    end
    assert_empty readers
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

  # A new integration test runs without an entry; only excusing one takes an edit.
  def test_integration_tests_run_unless_excused
    Dir.mktmpdir('erx-cli-integration-') do |root|
      FileUtils.mkdir_p(File.join(root, 'test/integration'))
      %w[new_test.rb fiasco_reproducible_test.rb oracle_reporter_test.rb helper.rb].each do |name|
        File.write(File.join(root, 'test/integration', name), '')
      end
      assert_equal [File.join(root, 'test/integration/new_test.rb')], Erx::CLI.integration_tests(root)
    end
    Dir.mktmpdir('erx-cli-integration-') do |root|
      assert_raises(Erx::Error) { Erx::CLI.integration_tests(root) }
    end
  end

  # `make check` builds no runtime, so a test that reads the hosted build fails its setup
  # there on a clean checkout; `make check-runtime-hosted` builds it and runs them. The one
  # runtime test left in `make check` compiles its own harness and reads no build.
  def test_a_test_of_the_hosted_build_leaves_make_check_for_its_own_gate
    root = File.expand_path('../..', __dir__)
    tests = Dir.glob('*_test.rb', base: File.join(root, 'test/integration'))
    reads_build = tests.select { |name| File.read(File.join(root, 'test/integration', name)).include?('Runtime.check_current') }
    assert_equal %w[runtime_console_test.rb runtime_device_test.rb runtime_hosted_smoke_test.rb
                    runtime_literal_token_test.rb runtime_prim_file_test.rb runtime_release_test.rb],
                 reads_build.sort
    ordinary = Erx::CLI.integration_tests(root).map { |path| File.basename(path) }
    assert_empty reads_build & ordinary
    assert_equal %w[runtime_event_test.rb], ordinary.grep(/\Aruntime_/)

    recipe = File.read(File.join(root, 'Makefile'))[/^check-runtime-hosted:\n(?:\t.*\n)+/]
    tests.grep(/\Aruntime_/).each { |name| assert_includes recipe, "test/integration/#{name}" }
  end

  def test_gates_lists_what_each_discovered_gate_runs
    status, output = run_cli('gates')
    assert_equal 0, status, output
    assert_includes output, 'sanitizer test: test/host/cap_test.rb'
    assert_includes output, 'native fuzz target: cap: 5 seeds; sources kernel/core/cap.c kernel/core/attach.c kernel/core/object.c kernel/core/budget.c;'
    assert_includes output, 'chokepoint rule: cap-table-private: Forbidden, 10 seeds'
    assert_includes output, 'chokepoint rule: object-leg: Pending, 0 seeds'
  end

  def test_failed_native_integration_fails_the_aggregate_gate
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
    assert_empty step_commands(commands, 'host-tests')
  end

  def test_production_pack_takes_no_arguments
    status, output = run_cli('pack', 'extra')
    assert_equal 2, status
    assert_includes output, 'unexpected arguments'
  end

  def test_boot_refuses_bad_arguments_before_setting_anything_up
    [%w[--cpus 0], %w[--cpus 9], %w[--accel kvm], %w[extra]].each do |arguments|
      status, output = run_cli('boot', *arguments, runner_class: UnexpectedRunner)
      assert_equal 2, status, arguments.join(' ')
      refute_empty output
    end
  end

  def test_help_names_the_interactive_boot
    status, output = run_cli('--help')
    assert_equal 0, status
    assert_includes output, 'boot [--accel tcg|hvf] [--cpus N]'
  end

  def test_commands_refuse_unsupported_collaborators
    %w[check generate check-reproducible check-fuzz check-sanitizers check-ubsan check-stack-proof pack status fetch check-tla check-cbmc check-sources check-arch-terms build boot qemu oracle bench check-oracle gates --help -h].each do |command|
      assert_raises(ArgumentError, command) { run_cli(command, unexpected: Object.new) }
    end
  end

  def test_sanitizer_gate_instruments_the_pack_and_elf_regression_corpora
    commands = []
    with_checks(commands) do |collaborators|
      status, output = run_cli('check-sanitizers', **collaborators.slice(:runner_class, :runtime))
      assert_equal 0, status, output
    end
    tests = step_commands(commands, 'sanitizer-tests')
    expected = Erx::SanitizerTests.discover(root: Erx::ROOT).map { |path| File.join(Erx::ROOT, path) }
    refute_empty expected
    assert_equal expected.sort, tests.map { |argv, _options| argv.last }.sort
    assert tests.all? { |_argv, options| options.fetch(:env).fetch('ERX_SANITIZERS') == 'address,undefined' }
  end

  def test_fuzz_limits_are_checked_before_starting_commands
    status, output = run_cli('check-fuzz', '--runs', '0', runner_class: UnexpectedRunner)
    assert_equal 2, status
    assert_includes output, 'outside bounds'
  end

  # generate reports what tools/erx's one ensure, before any command, did.
  def test_generate_reports_the_ensure_tools_erx_ran
    %i[generated fresh].zip(['regenerated', 'up to date']).each do |status, said|
      tree = Erx::Generated::Result.new(status: status, output: '/tree/build/gen')
      code, output = run_cli('generate', tree: tree)
      assert_equal 0, code
      assert_includes output, "generated files in /tree/build/gen: #{said}"
    end
  end

  def test_generate_refuses_trailing_arguments
    status, output = run_cli('generate', 'ignored')
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
