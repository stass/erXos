# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/fuzz/bench_line'
require_relative '../../tools/lib/erx/bench_suite'
require_relative '../../tools/lib/erx/qemu_gate'

# The bench suite's cells and the table from a benchmark cell's status to its suite cell
# (docs/design-bench.md, "The gates", "Cells and suite cells").
class BenchSuiteTest < Minitest::Test
  Suite = Erx::BenchSuite
  # Linux's Erlang guest's landing on a host without the oracle's install export.
  NOT_RUN = ->(*, **) { { not_run: "linux's Erlang guest needs the oracle's install export" } }

  def test_each_status_maps_to_its_suite_cell
    expected = { 'measured' => 'passed', 'unsupported' => 'partial', 'partial' => 'partial', 'rejected' => 'partial',
                 'timed_out' => 'timed_out', 'not_run' => 'not_run', 'failed' => 'failed' }
    assert_equal Erx::BenchRecord::STATUSES.sort, expected.keys.sort
    expected.each do |status, cell|
      assert_equal cell, Suite.suite_cell([[status, false]]), status
    end
  end

  def test_an_expected_unsupported_cell_passes
    assert_equal 'passed', Suite.suite_cell([['measured', false], ['unsupported', true]])
    assert_equal 'partial', Suite.suite_cell([['measured', false], ['unsupported', false]])
  end

  def test_a_suite_cell_takes_its_worst_status
    assert_equal 'failed', Suite.suite_cell([['measured', false], ['failed', false], ['timed_out', false]])
    assert_equal 'timed_out', Suite.suite_cell([['not_run', false], ['timed_out', false]])
    assert_equal 'not_run', Suite.suite_cell([['partial', false], ['not_run', false]])
    assert_equal 'not_run', Suite.suite_cell([])
  end

  def test_unsupported_is_expected_only_where_the_environment_lacks_the_cpus
    four = Erx::BenchRecord::Environment.new(kind: 'qemu-hvf', model: 'Mac16,10', cpus: 4, system: 'erxos', details: {})
    deterministic = Erx::BenchRecord::Environment.new(kind: 'qemu-det', model: nil, cpus: 1, system: 'erxos', details: {})
    cell = ->(placement) { Suite::LandingCell.new(operation: 'wake-same-cpu', load: 'idle', placement: placement, parameters: {}) }
    refute Suite.expected_unsupported?(cell.call('cross-cpu'), four)
    assert Suite.expected_unsupported?(cell.call('cross-cpu'), deterministic)
    assert Suite.expected_unsupported?(cell.call('other-cpu'), deterministic)
    refute Suite.expected_unsupported?(cell.call('same-cpu'), deterministic)
  end

  def test_the_suite_cells_are_each_boots_benchmarks
    assert_equal %w[hvf-4cpu-native-nullcall hvf-4cpu-native-sched hvf-4cpu-native-vm hvf-4cpu-native-wake
                    hvf-4cpu-xdomain-wake hvf-4cpu-xdomain-xdomain hvf-1cpu-linux-erlang-xdomain].sort, Suite.suite_cells.sort
    declared = Erx::QemuGate.suites.find { |suite| suite.name == 'bench' }
    assert_equal Suite.suite_cells, declared.cells
    refute declared.offload
  end

  def test_the_wake_landing_cells_follow_the_matrix
    landing = Suite.benchmarks.fetch('wake').landing
    assert_equal %w[park-deadline trigger-take wake-cross-cpu wake-same-cpu], landing.fetch('native').map(&:operation).sort
    assert_equal %w[erlang-timer], landing.fetch('xdomain').map(&:operation)
  end

  def test_an_undeclared_benchmark_or_operation_is_refused
    assert_raises(Erx::Error) { Suite.benchmark('nonesuch') }
    assert_raises(Erx::Error) do
      Suite::Benchmark.new(name: 'wake', operations: {}, landing: { 'native' => [Suite::LandingCell.new(
        operation: 'park-deadline', load: 'idle', placement: 'service-cpu', parameters: {}
      )] })
    end
  end
  # A boot's suite cell is its cells' worst, each judged in the record's environment,
  # and failed when its seeded run's fault went uncaught.
  def test_a_boots_suite_cell_comes_from_its_record_and_its_seeded_run
    assert_equal 'passed', Suite.boot_cell(wake_record(1, 'cross-cpu', 'unsupported'), benchmark: 'wake', seed_caught: true, refused: [])
    # A refused line may have been a failure, so the boot is at best partial.
    assert_equal 'partial', Suite.boot_cell(wake_record(1, 'cross-cpu', 'unsupported'), benchmark: 'wake', seed_caught: true,
                                                                                     refused: ['BENCH line is long'])
    assert_equal 'partial', Suite.boot_cell(wake_record(4, 'cross-cpu', 'unsupported'), benchmark: 'wake', seed_caught: true, refused: [])
    assert_equal 'not_run', Suite.boot_cell(wake_record(4, 'cross-cpu', 'not_run'), benchmark: 'wake', seed_caught: true, refused: [])
    assert_equal 'failed', Suite.boot_cell(wake_record(1, 'cross-cpu', 'unsupported'), benchmark: 'wake', seed_caught: false, refused: [])
    assert_equal 'not_run', Suite.boot_cell(wake_record(4, 'cross-cpu', 'failed'), benchmark: 'xdomain', refused: [])
  end

  # A benchmark whose seeded run missed its fault fails its own cell, with a note naming
  # the seed, and the others' cells stand.
  def test_a_missed_seed_fails_only_its_benchmarks_cell_and_says_so
    record = wake_record(1, 'cross-cpu', 'unsupported')
    native = lambda do |declared, **|
      { record: record, written: nil, refused: [], seeds_missed: declared.name == 'wake' ? ['lost wake'] : [] }
    end
    xdomain = ->(*, **) { { record: record, written: nil, refused: [] } }
    answer = Suite.run(Struct.new(:root).new('/nonexistent'), history: '/nonexistent', native: native, xdomain: xdomain,
                                                                                         linux_erlang: NOT_RUN)
    assert_equal 'failed', answer.fetch(:cells).fetch('hvf-4cpu-native-wake')
    assert_equal 'not_run', answer.fetch(:cells).fetch('hvf-4cpu-native-nullcall')
    assert_equal 'passed', answer.fetch(:cells).fetch('hvf-4cpu-xdomain-wake')
    assert_includes answer.fetch(:notes), 'bench: native: wake: the seeded lost wake was not caught'
  end

  # Linux's Erlang guest's cell is not run, never passed, without the install export; its
  # missed seed fails it; and a boot that measured its cells with the seed caught passes.
  def test_the_linux_erlang_cell_is_not_run_without_the_export_and_failed_by_a_missed_seed
    stub = ->(*, **) { { record: wake_record(1, 'cross-cpu', 'unsupported'), written: nil, refused: [], seeds_missed: [] } }
    ran = lambda do |linux|
      answer = Suite.run(Struct.new(:root).new('/nonexistent'), history: '/nonexistent', native: stub, xdomain: stub,
                                                                  linux_erlang: linux)
      [answer.fetch(:cells).fetch('hvf-1cpu-linux-erlang-xdomain'), answer.fetch(:notes).grep(/linux's Erlang guest/)]
    end
    cell, notes = ran.call(NOT_RUN)
    assert_equal 'not_run', cell
    assert_equal ["bench: linux's Erlang guest: not run: linux's Erlang guest needs the oracle's install export"], notes
    measured = wake_record(1, 'cross-cpu', 'unsupported').then do |kept|
      kept.with(boots: kept.boots.map { |boot| boot.with(cells: boot.cells.map { |cell| cell.with(benchmark: 'xdomain') }) })
    end
    missed = lambda do |declared, history:|
      raise 'the Linux guest runs the xdomain benchmark' unless declared.name == 'xdomain' && history == '/nonexistent'

      { record: measured, written: nil, refused: [], seeds_missed: ['echo cookie'] }
    end
    cell, notes = ran.call(missed)
    assert_equal 'failed', cell
    assert_includes notes, "bench: linux's Erlang guest: the seeded echo cookie was not caught"
    caught = ->(declared, **kept) { missed.call(declared, **kept).merge(seeds_missed: []) }
    assert_equal 'passed', ran.call(caught).first
  end

  # A benchmark whose landing raises is a failed cell with its message as a note, and the
  # others' cells stand.
  def test_a_failing_benchmark_fails_only_its_own_cell
    record = wake_record(4, 'cross-cpu', 'not_run')
    landing = lambda do |declared, **|
      raise Erx::Error, "the guest says \"erx: bench: no task FAILED\"\e[2J" if declared.name == 'nullcall'

      { record: record, written: nil, refused: [], seeds_missed: [] }
    end
    xdomain = ->(*, **) { { record: record, written: nil, refused: [] } }
    answer = Suite.run(Struct.new(:root).new('/nonexistent'), history: '/nonexistent', native: landing, xdomain: xdomain,
                                                                                         linux_erlang: NOT_RUN)
    assert_equal 'failed', answer.fetch(:cells).fetch('hvf-4cpu-native-nullcall')
    assert_equal 'not_run', answer.fetch(:cells).fetch('hvf-4cpu-native-wake')
    assert_equal 'not_run', answer.fetch(:cells).fetch('hvf-4cpu-xdomain-wake')
    failure = answer.fetch(:notes).grep(/nullcall: failed: /).first
    assert_match(/no task FAILED/, failure)
    refute_includes failure, "\e"
  end

  # The xdomain boot's run (XdomainBench::Run), stubbed: what a boot that QEMU's
  # checkpoint ended after local-rtt's line answers.
  class TimedOutRun
    def initialize(serial) = @serial = serial
    def memory_mib = 512

    def call(_asked, accel:, cpus:)
      raise 'the suite boots xdomain under HVF at four CPUs' unless [accel, cpus] == ['hvf', 4]

      rtt = Erx::BenchLineFuzz.line('wake-same-cpu', benchmark: 'xdomain', operation: 'local-rtt', status: 'partial',
                                                     reason: 'cut short',
                                                     conditions: { 'load' => 'idle', 'placement' => 'runtime',
                                                                   'parameters' => { 'bytes' => 64, 'encoded' => 78 },
                                                                   'clock' => 'counter', 'batch' => 1 })
      { serial: @serial, seconds: nil, lines: [Erx::BenchLineFuzz.clock_line(pairs: []), rtt], image_sha256: 'a' * 64,
        workloads: {}, compiler: '', qemu_version: nil, reused_from: nil,
        timed_out: "QEMU checkpoint timed out: cells\e]8;;x" }
    end
  end

  # The native boot's landing, stubbed: a record of one measured wake cell.
  class NativeLanding
    def call(_benchmark, boot:, history:)
      conditions = Erx::BenchRecord::Conditions.new(load: 'idle', placement: 'same-cpu', parameters: {}, clock: 'counter',
                                                    batch: 1)
      cell = Erx::BenchRecord::Cell.new(benchmark: 'wake', operation: 'wake-same-cpu', conditions: conditions,
                                        profile: Erx::BenchRecord::Profile.new(name: 'fast', warmup: 1, samples: 1, runs: 1),
                                        status: 'not_run', reason: 'the guest printed no line for it',
                                        counts: { 'lost' => 0, 'early' => 0, 'missed' => 0 }, detail: {})
      record = Erx::BenchRecord::Record.new(
        environment: Erx::BenchRecord::Environment.new(kind: boot.kind, model: 'Mac16,10', cpus: boot.cpus, system: 'erxos', details: {}),
        subject: Erx::BenchRecord::Subject.new(revision: '0' * 40, dirty: false, details: {}),
        run: Erx::BenchRecord::Run.new(date: Time.at(0).utc, started_by: 'landing', load: nil, host_cpus: nil, reused_from: nil, details: {}),
        boots: [Erx::BenchRecord::Boot.new(position: 1, clock: {}, cells: [cell], details: {})]
      )
      { record: record, written: File.join(history, 'native'), refused: [], seeds_missed: [], timed_out: nil }
    end
  end

  # A QEMU timeout of the xdomain boot ends only that boot: its unreported cells are
  # timed_out in a record written from what it printed, its notes carry the timeout
  # escaped, and the native boot's verdict stands.
  def test_a_timed_out_xdomain_boot_is_recorded_and_leaves_the_native_verdict
    Dir.mktmpdir('erx-bench-suite-') do |scratch|
      scratch = File.realpath(scratch)
      erxos = File.join(scratch, 'erxos')
      history = File.join(scratch, 'history')
      [erxos, history].each { |path| git(path, 'init', '-q') }
      git(erxos, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'x')
      serial = File.join(scratch, 'serial.log').tap { |path| File.write(path, "booted\n") }
      xdomain = Erx::XdomainBench::Landing.new(root: erxos, run: TimedOutRun.new(serial))
      ran = Suite.run(Struct.new(:root).new(erxos), history: history, native: NativeLanding.new, xdomain: xdomain,
                                                          linux_erlang: NOT_RUN)
      assert_equal({ 'hvf-4cpu-native-nullcall' => 'not_run', 'hvf-4cpu-native-sched' => 'not_run',
                     'hvf-4cpu-native-vm' => 'not_run', 'hvf-4cpu-native-wake' => 'not_run',
                     'hvf-4cpu-xdomain-wake' => 'timed_out',
                     'hvf-4cpu-xdomain-xdomain' => 'timed_out', 'hvf-1cpu-linux-erlang-xdomain' => 'not_run' },
                   ran.fetch(:cells))
      notes = ran.fetch(:notes).grep(/\Abench: xdomain: /)
      assert_includes notes, 'bench: xdomain: QEMU checkpoint timed out: cells<U+001B>]8;;x'
      assert_includes notes, 'bench: xdomain: erlang-timer runtime: timed_out (the boot timed out before its line)'
      assert(notes.none? { |note| note.include?("\e") })
      written = Dir.glob(File.join(history, '**', 'run.json'))
      assert_equal 1, written.size
      boot, = JSON.parse(File.read(written.first)).fetch('boots')
      statuses = boot.fetch('cells').to_h { |cell| [cell.fetch('operation'), cell.fetch('status')] }
      assert_equal({ 'local-rtt' => 'partial', 'xdomain-pingpong' => 'timed_out', 'erlang-timer' => 'timed_out' }, statuses)
    end
  end

  # docs/design-bench.md, "Counterparts": an operation names what each other system runs
  # for it; a cell no other system has a counterpart for is not asked of that system.
  def test_a_counterpart_names_another_system_and_what_it_runs
    operation = ->(counterparts) { Suite::Operation.new(name: 'x', profile: 'fast', result: 'ok', counterparts: counterparts) }
    assert_equal({ 'linux' => 'a condition wait' }, operation.call('linux' => 'a condition wait').counterparts)
    [{ 'erxos' => 'itself' }, { 'plan9' => 'x' }, { 'linux' => '' }, { 'linux' => "a\ttab" }].each do |counterparts|
      assert_raises(Erx::Error, counterparts.inspect) { operation.call(counterparts) }
    end
    assert_empty Suite::Operation.new(name: 'x', profile: 'fast', result: 'ok').counterparts
  end

  def test_wake_sets_posix_beside_its_wakes_and_deadline_and_nothing_beside_its_own
    operations = Suite.benchmark('wake').operations
    beside = operations.select { |_, operation| operation.counterparts.key?('linux') }.keys.sort
    assert_equal %w[park-deadline wake-cross-cpu wake-same-cpu], beside
    assert(operations.values.none? { |operation| operation.counterparts.key?('l4re') })
  end

  # The side-by-side tables are one per layer: the native boot's cells set the kernels'
  # paths beside each other, the xdomain boot's the runtimes' messages.
def test_each_boot_is_one_layer
  assert_equal({ 'native' => 'kernel', 'xdomain' => 'Erlang', 'posix' => 'program' }, Suite::BOOTS.transform_values(&:layer))
end

# The program table's boot runs in comparison sessions only; the landing gate boots the others.
def test_the_landing_gate_does_not_boot_the_program_table
  assert_empty Suite.suite_cells.grep(/posix/)
  refute_empty Suite.benchmark('posix').landing.fetch('posix')
end

# A program operation without its act line is refused before any boot, and an act is
# the same act or a nearest counterpart's line.
def test_a_program_operation_without_its_act_is_refused
  cell = Suite::LandingCell.new(operation: 'getpid', load: 'idle', placement: 'same-cpu', parameters: {})
  unsaid = Suite::Operation.new(name: 'getpid', profile: 'fast', result: 'ok')
  error = assert_raises(Erx::Error) do
    Suite::Benchmark.new(name: 'posix', operations: { 'getpid' => unsaid }, landing: { 'posix' => [cell] })
  end
  assert_match(/getpid do not say their act/, error.message)
  assert_raises(Erx::Error) { Suite::Operation.new(name: 'getpid', profile: 'fast', result: 'ok', act: 'similar') }
  assert Suite::Benchmark.new(name: 'posix', operations: { 'getpid' => unsaid.with(act: 'same act') },
                              landing: { 'posix' => [cell] })
  assert(Suite.benchmark('posix').operations.values.all?(&:act))
end

  private

  # A record of wake-cross-cpu alone, booted at cpus CPUs.
  def wake_record(cpus, placement, status)
    conditions = Erx::BenchRecord::Conditions.new(load: 'idle', placement: placement, parameters: {}, clock: 'counter',
                                                  batch: 1)
    cell = Erx::BenchRecord::Cell.new(benchmark: 'wake', operation: 'wake-cross-cpu', conditions: conditions,
                                      profile: Erx::BenchRecord::Profile.new(name: 'fast', warmup: 1, samples: 1, runs: 1),
                                      status: status, reason: 'the machine has one CPU',
                                      counts: { 'lost' => 0, 'early' => 0, 'missed' => 0 }, detail: {})
    Erx::BenchRecord::Record.new(
      environment: Erx::BenchRecord::Environment.new(kind: 'qemu-hvf', model: 'Mac16,10', cpus: cpus, system: 'erxos', details: {}),
      subject: Erx::BenchRecord::Subject.new(revision: '0' * 40, dirty: false, details: {}),
      run: Erx::BenchRecord::Run.new(date: Time.at(0).utc, started_by: 'landing', load: nil, host_cpus: nil, reused_from: nil, details: {}),
      boots: [Erx::BenchRecord::Boot.new(position: 1, clock: {}, cells: [cell], details: {})]
    )
  end

  def git(path, *arguments)
    FileUtils.mkdir_p(path)
    _, error, status = Open3.capture3('git', '-C', path, *arguments, stdin_data: '')
    raise "git #{arguments.first} failed: #{error}" unless status.success?
  end
end
