# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'timeout'
require 'tmpdir'
require_relative '../../tools/lib/erx/cbmc'

# Tests the CBMC gate's runner (tools/lib/erx/cbmc.rb) without CBMC: the
# roster's validation, the reading of CBMC's results, the command line,
# the classification of seeded defects, the tool's version pin and a whole
# run against a stand-in cbmc. The real harnesses run only under
# `make check-cbmc`; this test runs under `make check` and also checks that
# the checked-in roster still parses against the tree, so a core edit that
# breaks a seeded defect's one-place edit fails here first.
class CbmcTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SETTINGS = { 'solver' => 'cadical', 'checks' => ['--bounds-check'] }.freeze

  def harness_entry(**fields)
    { 'id' => 'h', 'source' => 'h.c', 'core' => 'kernel/core/x.c', 'deadline' => 60, 'unwind' => 2,
      'bounds' => 'small', 'assumptions' => [], 'unsupported' => [] }.merge(fields.transform_keys(&:to_s))
  end

  def mutant_entry(**fields)
    { 'id' => 'm', 'harness' => 'h', 'defect' => 'a removed check', 'file' => 'kernel/core/x.c',
      'original' => 'check();', 'replacement' => '', 'fails' => 'assertion' }.merge(fields.transform_keys(&:to_s))
  end

  def roster(harnesses: [harness_entry], mutants: [mutant_entry], **fields)
    { 'version' => 1, 'cbmc_version' => '6.11.0', 'solver' => 'cadical', 'checks' => ['--bounds-check'],
      'harnesses' => harnesses, 'mutants' => mutants }.merge(fields.transform_keys(&:to_s))
  end

  # A tree with one harness and one core holding one checked call.
  def with_tree(roster_value = roster)
    Dir.mktmpdir('cbmc-test-') do |root|
      FileUtils.mkdir_p(File.join(root, 'test/cbmc'))
      FileUtils.mkdir_p(File.join(root, 'kernel/core'))
      File.write(File.join(root, 'test/cbmc/h.c'), "#include \"x.c\"\nvoid harness(void) {}\n")
      File.write(File.join(root, 'test/cbmc/other.c'), "#include \"y.c\"\nvoid harness(void) {}\n")
      File.write(File.join(root, 'kernel/core/x.c'), "void f(void) { check(); }\n")
      File.write(File.join(root, 'test/cbmc/roster.json'), JSON.generate(roster_value))
      yield root
    end
  end

  def parse(value, root)
    Erx::CbmcRoster.parse(JSON.generate(value), root: root)
  end

  # CBMC's plain results: one line per property and the closing count.
  def cbmc_output(*statuses, warning: 'file h.c line 1: pointer arithmetic is not modelled precisely',
                  tally: nil)
    results = statuses.each_with_index.map do |status, index|
      "[harness.assertion.#{index + 1}] line #{index + 1} claim: #{status}"
    end
    failed = tally || statuses.count('FAILURE')
    ['CBMC version 6.11.0 (cbmc-6.11.0) 64-bit arm64 macos', warning, '', '** Results:', *results, '',
     "** #{failed} of #{statuses.size} failed (2 iterations)", 'VERIFICATION DONE'].join("\n") + "\n"
  end

  def test_the_checked_in_roster_parses_against_the_tree
    roster = Erx::CbmcRoster.read(ROOT)
    assert_equal '6.11.0', roster.fetch('cbmc_version')
    assert_operator roster.fetch('mutants').size, :>=, 3
    roster.fetch('harnesses').each { |entry| assert entry.fetch('bounds') }
  end

  def test_roster_refusals_name_the_fault
    with_tree do |root|
      parse(roster, root)
      {
        'unknown fields' => roster(extra: 1),
        'unknown solver' => roster(solver: 'kissat'),
        'pins no valid cbmc version' => roster(cbmc_version: '6.11'),
        'checks must be distinct options' => roster(checks: ['--unwind']),
        'checks must be distinct' => roster(checks: ['--no-pointer-check']),
        "must edit its harness's core" => roster(mutants: [mutant_entry(file: 'test/cbmc/h.c')]),
        'harness ids repeat' => roster(harnesses: [harness_entry, harness_entry]),
        'must be a path inside the tree' => roster(harnesses: [harness_entry(core: '../x.c')]),
        'is not a regular file' => roster(harnesses: [harness_entry(source: 'missing.c')]),
        'must include its core' => roster(harnesses: [harness_entry(source: 'other.c')]),
        'unwind must be an integer' => roster(harnesses: [harness_entry(unwind: 0)]),
        'unwindset has an invalid key' => roster(harnesses: [harness_entry(unwindset: { 'f;rm' => 2 })]),
        'defines has an invalid key' => roster(harnesses: [harness_entry(defines: { 'x' => 1 })]),
        'names an unknown harness' => roster(mutants: [mutant_entry(harness: 'other')]),
        'must edit exactly one place' => roster(mutants: [mutant_entry(original: 'absent();')]),
        'is not a regular expression' => roster(mutants: [mutant_entry(fails: '(')])
      }.each do |fault, value|
        error = assert_raises(Erx::Error, fault) { parse(value, root) }
        assert_includes error.message, fault
      end
    end
  end

  def test_output_classification
    verified = Erx::CbmcOutput.classify(cbmc_output('SUCCESS', 'SUCCESS'), exit_status: 0)
    assert_equal ['verified', 2, []], [verified.verdict, verified.properties, verified.failures]
    assert_empty verified.warnings
    ["file abi.h line 9 function f: function '__c11_atomic_load' is not declared",
     'no body for callee f'].each do |warning|
      missing = Erx::CbmcOutput.classify(cbmc_output('SUCCESS', warning: warning), exit_status: 0)
      assert_equal 'error', missing.verdict, warning
    end
    failed = Erx::CbmcOutput.classify(cbmc_output('SUCCESS', 'FAILURE'), exit_status: 10)
    assert_equal ['failed', ['harness.assertion.2: line 2 claim']], [failed.verdict, failed.failures]
    assert_equal 'error', Erx::CbmcOutput.classify(cbmc_output('FAILURE', tally: 0), exit_status: 10).verdict
    assert_equal 'error', Erx::CbmcOutput.classify(cbmc_output('SUCCESS'), exit_status: 6).verdict
    assert_equal 'error', Erx::CbmcOutput.classify(cbmc_output('FAILURE'), exit_status: 0).verdict
    assert_equal 'error', Erx::CbmcOutput.classify(cbmc_output('SUCCESS'), exit_status: 10).verdict
    assert_equal 'error', Erx::CbmcOutput.classify(cbmc_output, exit_status: 0).verdict
    assert_equal 'error', Erx::CbmcOutput.classify("[h.assertion.1] claim: SUCCESS\n", exit_status: 0).verdict
    assert_equal 'error', Erx::CbmcOutput.classify("\xff\n".b, exit_status: 0).verdict
    assert_equal 'error', Erx::CbmcOutput.classify(cbmc_output('SUCCESS', 'UNKNOWN'), exit_status: 0).verdict
  end

  def test_mutant_states
    state = lambda do |verdict, failures = []|
      result = Erx::CbmcOutput::Result.new(verdict: verdict, properties: 1, failures: failures, warnings: [])
      Erx::Cbmc.mutant_state(result, pattern: Erx::CbmcRoster.pattern(mutant_entry))
    end
    assert_equal 'caught', state.call('failed', ['h.assertion.1: x'])
    assert_equal 'wrong_failure', state.call('failed', ['h.overflow.1: x'])
    assert_equal 'missed', state.call('verified')
    assert_equal 'error', state.call('error')
    assert_equal 'timed_out', state.call('timed_out')
    # A pattern whose match runs out of time leaves the defect undecided.
    slow = Object.new
    def slow.match?(_text) = raise(Regexp::TimeoutError, 'regexp match timeout')
    result = Erx::CbmcOutput::Result.new(verdict: 'failed', properties: 1, failures: ['x'], warnings: [])
    assert_equal 'error', Erx::Cbmc.mutant_state(result, pattern: slow)
  end

  def test_argv_states_every_bound_and_searches_a_mutant_first
    entry = harness_entry(unwindset: { 'f.0' => 3, 'g.1' => 65 }, object_bits: 12, defines: { 'DEPTH' => 3 })
    argv = Erx::Cbmc.argv(entry, program: 'cbmc', root: '/r', settings: SETTINGS, mutant_dir: '/r/build/cbmc/mutants/m')
    assert_equal ['cbmc', '/r/test/cbmc/h.c', '--function', 'harness', '--sat-solver', 'cadical',
                  '--bounds-check', '--unwinding-assertions', '--unwind', '2', '--unwindset', 'f.0:3,g.1:65',
                  '--object-bits', '12', '-D', 'DEPTH=3'], argv.first(16)
    includes = argv.drop(16).each_slice(2).map(&:last)
    assert_operator includes.index('/r/build/cbmc/mutants/m'), :<, includes.index('/r/kernel/core')
    refute_includes Erx::Cbmc.argv(harness_entry, program: 'cbmc', root: '/r', settings: SETTINGS), '--unwindset'
  end

  # A stand-in cbmc: reports version, verifies a harness, and fails one
  # property when its include path holds a mutant, unless told to miss.
  def stand_in(directory, version:, miss: false)
    path = File.join(directory, 'cbmc')
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      if ARGV == ['--version']
        puts '#{version} (cbmc-#{version})'
        exit 0
      end
      mutant = ARGV.any? { |arg| arg.include?('/mutants/') } && !#{miss}
      status = mutant ? 'FAILURE' : 'SUCCESS'
      puts "** Results:\n[harness.assertion.1] line 1 claim: \#{status}\n** \#{mutant ? 1 : 0} of 1 failed"
      exit(mutant ? 10 : 0)
    RUBY
    File.chmod(0o755, path)
    path
  end

  def gate(root, program)
    runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs'))
    Erx::Cbmc.new(root: root, runner: runner, program: program, prepare: ->(_tree) {},
                  clock: -> { Time.utc(2026, 11, 7) })
  end

  def test_a_missing_or_other_cbmc_fails_with_a_diagnostic
    with_tree do |root|
      error = assert_raises(Erx::Error) { gate(root, File.join(root, 'absent/cbmc')).run }
      assert_includes error.message, 'cbmc not found'
      error = assert_raises(Erx::Error) { gate(root, stand_in(root, version: '6.10.0')).run }
      assert_includes error.message, 'is version 6.10.0; test/cbmc/roster.json pins 6.11.0'
    end
  end

  def test_a_run_verifies_harnesses_catches_mutants_and_writes_its_report
    with_tree do |root|
      report = gate(root, stand_in(root, version: '6.11.0')).run
      assert_equal 'passed', report.fetch('state')
      assert_equal %w[verified], report.fetch('harnesses').map { |result| result.fetch('state') }
      assert_equal %w[caught], report.fetch('mutants').map { |result| result.fetch('state') }
      written = JSON.parse(File.read(File.join(root, 'build/cbmc/report.json')))
      assert_equal report.fetch('tool').fetch('sha256'), written.fetch('tool').fetch('sha256')
      assert_includes File.read(File.join(root, 'build/cbmc/report.txt')), 'mutant m'
      assert_equal "void f(void) { check(); }\n", File.read(File.join(root, 'kernel/core/x.c'))
      assert_equal "void f(void) {  }\n", File.read(File.join(root, 'build/cbmc/mutants/m/x.c'))
    end
  end

  def test_a_missed_mutant_fails_the_gate
    with_tree do |root|
      error = assert_raises(Erx::Error) { gate(root, stand_in(root, version: '6.11.0', miss: true)).run }
      assert_includes error.message, 'CBMC gate failed'
      written = JSON.parse(File.read(File.join(root, 'build/cbmc/report.json')))
      assert_equal %w[failed missed], [written.fetch('state'), written.fetch('mutants').first.fetch('state')]
    end
  end

  def test_checks_run_at_once_up_to_the_job_count_and_return_in_order
    arrived = Queue.new
    # Each check waits for the other to start, so it returns only if two run at once.
    meet = lambda do |value|
      lambda do
        arrived << value
        Timeout.timeout(10) { sleep 0.01 while arrived.size < 2 }
        value
      end
    end
    assert_equal %i[a b], Erx::Cbmc.concurrently([meet.call(:a), meet.call(:b)], jobs: 2)
    assert_equal [1, 2, 3], Erx::Cbmc.concurrently([-> { sleep 0.05; 1 }, -> { 2 }, -> { 3 }], jobs: 2)
    error = assert_raises(RuntimeError) { Erx::Cbmc.concurrently([-> { raise 'boom' }, -> { 1 }], jobs: 1) }
    assert_equal 'boom', error.message
  end

  def test_the_job_count_is_a_positive_integer_else_the_cpu_count
    assert_equal 6, Erx::Cbmc.jobs(environment: {}, cpus: 6)
    assert_equal 2, Erx::Cbmc.jobs(environment: { 'CBMC_JOBS' => '2' }, cpus: 6)
    %w[0 -1 two 2.5 999].each do |bad|
      assert_raises(Erx::Error) { Erx::Cbmc.jobs(environment: { 'CBMC_JOBS' => bad }, cpus: 6) }
    end
  end
def test_serial_checks_run_alone_after_the_others_and_results_keep_their_order
  running = Queue.new
  overlap = false
  probe = lambda do |value|
    lambda do
      running << value
      sleep 0.05
      overlap ||= running.size > 1 && value.start_with?('s')
      running.pop
      value
    end
  end
  checks = [[true, probe.call('s1')], [false, probe.call('p1')], [false, probe.call('p2')], [true, probe.call('s2')]]
  assert_equal %w[s1 p1 p2 s2], Erx::Cbmc.scheduled(checks, jobs: 4)
  refute overlap
end

def test_a_roster_refuses_a_serial_that_is_not_a_boolean
  with_tree(roster(harnesses: [harness_entry(serial: 'yes')])) do |root|
    error = assert_raises(Erx::Error) { parse(roster(harnesses: [harness_entry(serial: 'yes')]), root) }
    assert_includes error.message, 'serial must be true or false'
  end
end
end
