# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/tla'

class TlaTest < Minitest::Test
  def tlc_frame(code, body, level: 0)
    "@!@!@STARTMSG #{code}:#{level} @!@!@\n#{body}\n@!@!@ENDMSG #{code} @!@!@\n"
  end

  def beginning
    tlc_frame(2262, 'TLC2 Version pinned') + tlc_frame(2219, 'SANY finished.') +
      tlc_frame(2185, 'Starting...')
  end

  def ending
    tlc_frame(2186, 'Finished in 20ms at a tool-reported timestamp')
  end

  def good_output
    beginning + tlc_frame(2193, 'Model checking completed. No error has been found.') +
      tlc_frame(2199, '4 states generated, 3 distinct states found, 0 states left on queue.') + ending
  end

  def negative_output(property: 'Bounded')
    beginning + tlc_frame(2110, "Invariant #{property} is violated.", level: 1) +
      tlc_frame(2121, 'The behavior up to this point is:', level: 1) +
      tlc_frame(2217, "1: <Initial predicate>\ncount = 3", level: 4) + ending
  end

  def command(state: 'succeeded', exit_status: 0)
    { 'state' => state, 'exit_status' => exit_status }
  end

  def expected_negative
    { 'kind' => 'counterexample', 'property' => 'Bounded', 'exit_status' => 12 }
  end

  def test_completed_good_run_requires_tool_success
    result = Erx::TlcOutput.classify(good_output, command: command, expectation: { 'kind' => 'pass' })
    assert_equal 'checked', result.fetch('state')
    failed = Erx::TlcOutput.classify(good_output, command: command(state: 'failed', exit_status: 1),
                                    expectation: { 'kind' => 'pass' })
    assert_equal 'failed', failed.fetch('state')
  end

  def test_targeted_counterexample_requires_exact_property_and_exit
    accepted = Erx::TlcOutput.classify(negative_output,
                                      command: command(state: 'failed', exit_status: 12),
                                      expectation: expected_negative)
    assert_equal 'checked', accepted.fetch('state')
    wrong = Erx::TlcOutput.classify(negative_output(property: 'Other'),
                                   command: command(state: 'failed', exit_status: 12),
                                   expectation: expected_negative)
    assert_equal 'failed', wrong.fetch('state')
    wrong_exit = Erx::TlcOutput.classify(negative_output,
                                        command: command(state: 'failed', exit_status: 150),
                                        expectation: expected_negative)
    assert_equal 'failed', wrong_exit.fetch('state')
  end

  def temporal_output
    beginning + tlc_frame(2116, 'Temporal properties were violated.', level: 1) +
      tlc_frame(2264, 'The following behavior constitutes a counter-example:', level: 1) +
      tlc_frame(2217, "1: <Initial predicate>\ncount = 0", level: 4) +
      tlc_frame(2218, '2: Stuttering', level: 4) + ending
  end

  def expected_temporal
    { 'kind' => 'counterexample', 'property' => 'Reached', 'exit_status' => 13 }
  end

  def test_temporal_counterexample_requires_its_diagnostic_and_exit
    accepted = Erx::TlcOutput.classify(temporal_output,
                                      command: command(state: 'failed', exit_status: 13),
                                      expectation: expected_temporal)
    assert_equal 'checked', accepted.fetch('state')
    wrong_exit = Erx::TlcOutput.classify(temporal_output,
                                        command: command(state: 'failed', exit_status: 12),
                                        expectation: expected_temporal)
    assert_equal 'failed', wrong_exit.fetch('state')
    invariant = Erx::TlcOutput.classify(negative_output,
                                       command: command(state: 'failed', exit_status: 13),
                                       expectation: expected_temporal)
    assert_equal 'failed', invariant.fetch('state')
    as_invariant = Erx::TlcOutput.classify(temporal_output,
                                          command: command(state: 'failed', exit_status: 12),
                                          expectation: expected_negative)
    assert_equal 'failed', as_invariant.fetch('state')
  end

  def test_parser_error_is_never_an_expected_counterexample
    output = beginning + tlc_frame(3002, 'Parsing or semantic analysis failed.', level: 1) + ending
    result = Erx::TlcOutput.classify(output, command: command(state: 'failed', exit_status: 150),
                                    expectation: expected_negative)
    assert_equal 'failed', result.fetch('state')
  end

  def test_initial_counterexample_carries_its_state_in_the_diagnostic
    output = beginning + tlc_frame(2107, "Invariant Bounded is violated by the initial state:\ncount = 3", level: 1) + ending
    result = Erx::TlcOutput.classify(output, command: command(state: 'failed', exit_status: 12),
                                    expectation: expected_negative)
    assert_equal 'checked', result.fetch('state')
  end

  def test_missing_finish_and_wrong_phase_order_are_incomplete
    unfinished = good_output.delete_suffix(ending)
    result = Erx::TlcOutput.classify(unfinished, command: command, expectation: { 'kind' => 'pass' })
    assert_equal 'incomplete', result.fetch('state')
    reordered = ending + good_output.delete_suffix(ending)
    result = Erx::TlcOutput.classify(reordered, command: command, expectation: { 'kind' => 'pass' })
    assert_equal 'incomplete', result.fetch('state')
  end

  def test_timeout_is_not_expected_even_with_a_property_diagnostic
    result = Erx::TlcOutput.classify(negative_output,
                                    command: command(state: 'timed_out', exit_status: 124),
                                    expectation: expected_negative)
    assert_equal 'failed', result.fetch('state')
  end

  def test_malformed_frames_are_diagnostics
    assert_raises(Erx::Error) { Erx::TlcOutput.parse("@!@!@STARTMSG 2262:0 @!@!@\n") }
    assert_raises(Erx::Error) { Erx::TlcOutput.parse("@!@!@ENDMSG 2262 @!@!@\n") }
  end

  def with_roster
    Dir.mktmpdir('erx-tla-roster-') do |root|
      File.write(File.join(root, 'Model.tla'), '---- MODULE Model ---- ====')
      File.write(File.join(root, 'Good.cfg'), "SPECIFICATION Spec\n")
      entry = { 'id' => 'good', 'module' => 'Model', 'config' => 'Good.cfg',
                'translation' => 'tla', 'deadline' => 10, 'deadlock' => 'check',
                'scope' => 'finite', 'expect' => { 'kind' => 'pass' } }
      roster = { 'version' => 1, 'entries' => [entry] }
      yield root, roster
    end
  end

  def write_roster(root, roster)
    File.write(File.join(root, 'roster.json'), JSON.generate(roster))
  end

  def test_complete_roster_is_validated_before_filtering
    with_roster do |root, roster|
      write_roster(root, roster)
      assert_equal 1, Erx::TlaRoster.read(root).size
      File.write(File.join(root, 'Unregistered.cfg'), "SPECIFICATION Spec\n")
      assert_raises(Erx::Error) { Erx::TlaRoster.read(root) }
    end
  end

  def test_invalid_utf8_roster_is_a_domain_error
    with_roster do |root, roster|
      bytes = JSON.generate(roster).b.sub('good'.b, "\xff".b)
      File.binwrite(File.join(root, 'roster.json'), bytes)
      assert_raises(Erx::Error) { Erx::TlaRoster.read(root) }
    end
  end

  def test_duplicate_configuration_and_unknown_expectation_are_refused
    with_roster do |root, roster|
      roster.fetch('entries') << roster.fetch('entries').first.merge('id' => 'duplicate')
      write_roster(root, roster)
      assert_raises(Erx::Error) { Erx::TlaRoster.read(root) }
    end
    with_roster do |root, roster|
      roster.fetch('entries').first['expect'] = { 'kind' => 'anything' }
      write_roster(root, roster)
      assert_raises(Erx::Error) { Erx::TlaRoster.read(root) }
    end
  end

  def test_temporal_expectation_names_the_one_configured_property
    with_roster do |root, roster|
      roster.fetch('entries').first['expect'] = expected_temporal
      [["SPECIFICATION Spec\nPROPERTY Reached\n", true],
       ["SPECIFICATION Spec\n\\* PROPERTY Other\nPROPERTIES Reached\nINVARIANT TypeOK\n", true],
       ["SPECIFICATION Spec\nPROPERTY Other\n", false],
       ["SPECIFICATION Spec\nPROPERTIES Reached Other\n", false],
       ["SPECIFICATION Spec\nINVARIANT Reached\n", false]].each do |config, valid|
        File.write(File.join(root, 'Good.cfg'), config)
        write_roster(root, roster)
        if valid
          assert_equal 13, Erx::TlaRoster.read(root).first.fetch('expect').fetch('exit_status'), config
        else
          assert_raises(Erx::Error, config) { Erx::TlaRoster.read(root) }
        end
      end
      roster.fetch('entries').first['expect'] = expected_temporal.merge('exit_status' => 11)
      File.write(File.join(root, 'Good.cfg'), "SPECIFICATION Spec\nPROPERTY Reached\n")
      write_roster(root, roster)
      assert_raises(Erx::Error) { Erx::TlaRoster.read(root) }
    end
  end

  def test_temporal_counterexample_refuses_other_evidence
    failed = command(state: 'failed', exit_status: 13)
    no_trace = beginning + tlc_frame(2116, 'Temporal properties were violated.', level: 1) + ending
    twice = beginning + tlc_frame(2116, 'Temporal properties were violated.', level: 1) +
            tlc_frame(2116, 'Temporal properties were violated.', level: 1) +
            tlc_frame(2217, "1: <Initial predicate>\ncount = 0", level: 4) + ending
    with_invariant = beginning + tlc_frame(2110, 'Invariant Bounded is violated.', level: 1) +
                     tlc_frame(2116, 'Temporal properties were violated.', level: 1) +
                     tlc_frame(2217, "1: <Initial predicate>\ncount = 0", level: 4) + ending
    [[no_trace, failed], [twice, failed], [with_invariant, failed], [deadlock_output, failed],
     [temporal_output, command(state: 'succeeded', exit_status: 13)],
     [good_output, command]].each do |bytes, outcome|
      result = Erx::TlcOutput.classify(bytes, command: outcome, expectation: expected_temporal)
      assert_equal 'failed', result.fetch('state')
    end
  end

  def deadlock_output
    beginning + tlc_frame(2114, 'Deadlock reached.', level: 1) +
      tlc_frame(2121, 'The behavior up to this point is:', level: 1) +
      tlc_frame(2217, "1: <Initial predicate>\ncount = 0", level: 4) + ending
  end

  def test_deadlock_expectation_requires_its_diagnostic_and_exit
    expected = { 'kind' => 'deadlock' }
    failed = command(state: 'failed', exit_status: 11)
    assert_equal 'checked',
                 Erx::TlcOutput.classify(deadlock_output, command: failed, expectation: expected).fetch('state')
    [[deadlock_output, command(state: 'failed', exit_status: 12), expected],
     [negative_output, failed, expected], [temporal_output, failed, expected],
     [good_output, command, expected],
     [beginning + tlc_frame(2114, 'Deadlock reached.', level: 1) + ending, failed, expected],
     [deadlock_output, failed, expected_negative],
     [deadlock_output, failed, expected_temporal]].each do |bytes, outcome, expectation|
      result = Erx::TlcOutput.classify(bytes, command: outcome, expectation: expectation)
      assert_equal 'failed', result.fetch('state')
    end
  end

  def test_temporal_properties_need_deadlock_checking
    with_roster do |root, roster|
      roster.fetch('entries').first['deadlock'] = 'terminal'
      write_roster(root, roster)
      assert_equal 1, Erx::TlaRoster.read(root).size
      File.write(File.join(root, 'Good.cfg'), "SPECIFICATION Spec\n\\* PROPERTY Reached\n")
      assert_equal 1, Erx::TlaRoster.read(root).size
      ["SPECIFICATION Spec\nPROPERTY Reached\n", "SPECIFICATION Spec\nPROPERTIES Reached\n"].each do |config|
        File.write(File.join(root, 'Good.cfg'), config)
        assert_raises(Erx::Error, config) { Erx::TlaRoster.read(root) }
      end
    end
  end

  def test_deadlock_expectation_needs_deadlock_checking_and_no_temporal_property
    with_roster do |root, roster|
      roster.fetch('entries').first['expect'] = { 'kind' => 'deadlock' }
      write_roster(root, roster)
      assert_equal 'deadlock', Erx::TlaRoster.read(root).first.fetch('expect').fetch('kind')
      File.write(File.join(root, 'Good.cfg'), "SPECIFICATION Spec\nPROPERTY Reached\n")
      assert_raises(Erx::Error) { Erx::TlaRoster.read(root) }
      File.write(File.join(root, 'Good.cfg'), "SPECIFICATION Spec\n")
      roster.fetch('entries').first['deadlock'] = 'terminal'
      write_roster(root, roster)
      assert_raises(Erx::Error) { Erx::TlaRoster.read(root) }
      roster.fetch('entries').first['deadlock'] = 'check'
      roster.fetch('entries').first['expect'] = { 'kind' => 'deadlock', 'exit_status' => 11 }
      write_roster(root, roster)
      assert_raises(Erx::Error) { Erx::TlaRoster.read(root) }
    end
  end

  def test_deadlock_checking_is_set_only_by_the_roster
    with_roster do |root, roster|
      write_roster(root, roster)
      ["SPECIFICATION Spec\n\\* CHECK_DEADLOCK FALSE\n", "SPECIFICATION Spec\n(* CHECK_DEADLOCK FALSE *)\n",
       "SPECIFICATION Spec\nCONSTANT Name = \"CHECK_DEADLOCK\"\n"].each do |config|
        File.write(File.join(root, 'Good.cfg'), config)
        assert_equal 1, Erx::TlaRoster.read(root).size, config
      end
      ["SPECIFICATION Spec\nCHECK_DEADLOCK FALSE\n", "SPECIFICATION Spec\nCHECK_DEADLOCK TRUE\n"].each do |config|
        File.write(File.join(root, 'Good.cfg'), config)
        assert_raises(Erx::Error, config) { Erx::TlaRoster.read(root) }
      end
    end
  end

  def test_constraints_must_be_reported_as_constrained
    with_roster do |root, roster|
      File.write(File.join(root, 'Good.cfg'), "SPECIFICATION Spec\nCONSTRAINT Bound\n")
      write_roster(root, roster)
      assert_raises(Erx::Error) { Erx::TlaRoster.read(root) }
      roster.fetch('entries').first['scope'] = 'constrained'
      write_roster(root, roster)
      assert_equal 'constrained', Erx::TlaRoster.read(root).first.fetch('scope')
    end
  end
end

class TlaFixtureRunner < Erx::Runner
  def initialize(owner_root:, log_dir:, child_environment: {})
    super(owner_root: owner_root, log_dir: log_dir)
    @child_environment = child_environment
  end

  def run(argv, **options)
    environment = options.fetch(:env, {}).merge(@child_environment)
    super(argv, **options.merge(env: environment))
  end
end

class TlaFixture < Erx::Tla
  private

  def execution_settings
    { 'jobs' => 2, 'workers' => 1, 'heap_mib' => 512 }.freeze
  end
end

class EditingTlaFixture < TlaFixture
  private

  def source_inputs
    File.write(File.join(@specs, 'Good.cfg'), "SPECIFICATION Spec\nCONSTRAINT Bound\n")
    super
  end
end

class CrashingTlaFixture < TlaFixture
  attr_reader :slow_closed

  def initialize(ready:, **options)
    super(**options)
    @ready = ready
    @slow_closed = false
  end

  private

  def check_entry(entry, **options)
    if entry.fetch('id') == 'crash'
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until File.exist?(@ready)
        raise 'fixture child never started' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.005
      end
      raise 'unexpected worker failure'
    end
    begin
      super
    ensure
      @slow_closed = true
    end
  end
end

class TlaExecutionTest < Minitest::Test
  def test_linked_report_branch_does_not_receive_a_report
    Dir.mktmpdir do |outside|
      FileUtils.mkdir_p(File.join(@directory, 'build'))
      File.symlink(outside, File.join(@directory, 'build/tla'))
      begin
        executor.send(:write_report, [])
      rescue Erx::Error
        # The outside directory must stay untouched.
      end
      assert_empty Dir.children(outside)
    end
  end

  def setup
    @directory = Dir.mktmpdir('erx-tla-run-')
    @specs = File.join(@directory, 'specs/tla')
    FileUtils.mkdir_p(@specs)
    File.write(File.join(@specs, 'Model.tla'), "---- MODULE Model ----\n====\n")
    @jar = File.join(@directory, 'fixture.jar')
    File.write(@jar, 'fixture jar')
    source = { 'id' => 'tla-tools', 'kind' => 'file', 'version' => 'fixture',
               'url' => 'https://example.org/fixture.jar', 'filename' => 'tla2tools.jar',
               'sha256' => Digest::SHA256.file(@jar).hexdigest,
               'license' => 'MIT', 'status' => 'permanent' }
    File.write(File.join(@directory, 'deps.lock'), JSON.generate('version' => 1, 'sources' => [source]))
    @java = File.join(@directory, 'fake-java')
    FileUtils.copy_file(File.expand_path('fixtures/tla/fake_java.rb', __dir__), @java)
    File.chmod(0o755, @java)
    @runner = TlaFixtureRunner.new(owner_root: @directory, log_dir: File.join(@directory, 'build/logs'))
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def entry(id: 'good', config: 'Good.cfg', translation: 'tla')
    File.write(File.join(@specs, config), "SPECIFICATION Spec\n")
    { 'id' => id, 'module' => 'Model', 'config' => config, 'translation' => translation,
      'deadline' => 10, 'deadlock' => 'check', 'scope' => 'finite',
      'expect' => { 'kind' => 'pass' } }
  end

  def roster(entries)
    File.write(File.join(@specs, 'roster.json'), JSON.generate('version' => 1, 'entries' => entries))
  end

  def executor(type = TlaFixture, **options)
    type.new(root: @directory, runner: @runner, java: @java, jar: @jar, **options)
  end

  def test_changed_config_is_validated_from_the_same_snapshot_as_execution
    roster([entry])
    assert_raises(Erx::Error) { executor(EditingTlaFixture).run(no_cache: true) }
  end

  def test_translation_uses_the_resolved_heap_limit
    roster([entry(translation: 'pluscal')])
    result = executor.run(no_cache: true)
    assert_equal 'checked', result.first.fetch('state')
  end

  def test_worker_failure_waits_for_every_child_cleanup
    ready = File.join(@directory, 'ready')
    survivor = File.join(@directory, 'survivor')
    @runner = TlaFixtureRunner.new(owner_root: @directory, log_dir: File.join(@directory, 'build/logs'),
                                   child_environment: { 'ERX_TLA_FIXTURE_READY' => ready,
                                                        'ERX_TLA_FIXTURE_SURVIVOR' => survivor })
    roster([entry(id: 'crash', config: 'Crash.cfg'), entry(id: 'slow', config: 'Slow.cfg')])
    instance = executor(CrashingTlaFixture, ready: ready)
    failure = assert_raises(RuntimeError) { instance.run(no_cache: true) }
    assert_equal 'unexpected worker failure', failure.message
    assert File.exist?(ready), 'fixture did not exercise a live child'
    assert instance.slow_closed, 'gate returned before another worker cleaned up'
    sleep 0.9
    refute File.exist?(survivor), 'cancelled child continued executing'
  ensure
    # The unfixed implementation returns before cleanup. Let its cancellation
    # finish so a deliberately failing regression leaves no fixture process.
    if instance
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until instance.slow_closed || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
    end
  end

  def test_cache_keeps_evidence_and_invalidates_changed_input
    roster([entry])
    instance = executor
    first = instance.run(no_cache: false)
    second = instance.run(no_cache: false)
    assert_equal 'checked', first.first.fetch('state')
    assert_equal 'cached', second.first.fetch('state')
    snapshots = Dir.glob(File.join(@directory, 'build/tla/runs/good-*'))
    refute_empty snapshots, 'completed run discarded its input evidence'
    assert File.file?(File.join(snapshots.first, 'Model.tla'))
    File.write(File.join(@specs, 'Model.tla'), "---- MODULE Model ----\n\\* changed\n====\n")
    changed = instance.run(no_cache: false)
    assert_equal 'checked', changed.first.fetch('state')
  end

  def test_empty_filter_and_missing_tool_are_errors
    roster([entry])
    assert_raises(Erx::Error) { executor.run(filter: 'absent') }
    File.unlink(@jar)
    assert_raises(Erx::Error) { executor.run }
  end
end
