# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/bench_record'

# The record type, its one writer's destination checks, and the percentile rule
# (docs/design-bench.md, "The record", "Profiles", "Verification").
class BenchRecordTest < Minitest::Test
  Record = Erx::BenchRecord
  REVISION = 'abcdef0123456789abcdef0123456789abcdef01'

  def setup
    @scratch = File.realpath(Dir.mktmpdir('erx-bench-record-'))
    # A stand-in for the erXos repository: its main work tree and a second worktree.
    @erxos = File.join(@scratch, 'erxos')
    @second = File.join(@scratch, 'erxos-second')
    git_init(@erxos)
    git(@erxos, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'x')
    git(@erxos, 'worktree', 'add', '-q', @second)
    @history = File.join(@scratch, 'history')
    git_init(@history)
  end

  def teardown
    FileUtils.remove_entry(@scratch)
  end

  def git_init(path)
    FileUtils.mkdir_p(path)
    git(path, 'init', '-q')
  end

  def git(path, *arguments)
    _, error, status = Open3.capture3('git', '-C', path, *arguments, stdin_data: '')
    raise "git #{arguments.first} failed: #{error}" unless status.success?
  end

  def cell(benchmark: 'wake', operation: 'park-deadline', batch: 1, status: 'measured', early: 0, profile: 'periodic',
           total: nil,
           histogram: [[1000, 1016, 2000]], reason: status == 'measured' ? nil : 'test',
           extremes: histogram.empty? ? {} : { 'min' => histogram.first.first, 'max' => histogram.last[1] })
    Record::Cell.new(
      benchmark: benchmark, operation: operation,
      conditions: Record::Conditions.new(load: 'idle', placement: 'service-cpu', parameters: {}, clock: 'counter',
                                         batch: batch),
      profile: Record::Profile.new(name: profile, warmup: 0, samples: 2000, runs: 1),
      status: status, reason: reason,
      counts: { 'lost' => 0, 'early' => early, 'missed' => 0 },
      detail: { 'histogram' => histogram }.merge(extremes, total.nil? ? {} : { 'total' => total })
    )
  end

  def boot(position: 1, cells: [cell], clock: { 'frequency_hz' => 24_000_000 }, details: {}) =
    Record::Boot.new(position: position, clock: clock, cells: cells, details: details)

  def run_facts(date: Time.utc(2026, 11, 23, 12, 0, 0), details: {}) =
    Record::Run.new(date: date, started_by: 'manual', load: [0.5, 0.6], host_cpus: 12, reused_from: nil, details: details)

  def record(cells: [cell], date: Time.utc(2026, 11, 23, 12, 0, 0), boots: [boot(cells: cells)], subject: {}, run: run_facts(date: date),
             environment: { 'command_line' => 'erx.arg=0 erx.trace=0' })
    Record::Record.new(
      environment: Record::Environment.new(kind: 'qemu-hvf', model: 'Mac16,10', cpus: 4, system: 'erxos', details: environment),
      subject: Record::Subject.new(revision: REVISION, dirty: false, details: subject),
      run: run, boots: boots
    )
  end

  def write(history, logs: [], **options) = Record.write(record(**options), history: history, erxos_root: @erxos, logs: logs)

  # An erXos run states the kernel command line it booted with (docs/design-bench.md,
  # "The kernel's trace rings"), so a bench path that forgets the line, and with it the
  # rings-off default, cannot add a run to the history; another system's run has no such line.
  def test_an_erxos_record_without_its_kernel_command_line_is_never_written
    error = assert_raises(Erx::Error) { write(@history, environment: {}) }
    assert_match(/kernel command line/, error.message)
    assert_empty Dir.glob(File.join(@history, 'bench', '*')), 'nothing is written'
    assert Record.write(mean_record, history: @history, erxos_root: @erxos), "an l4re record needs no line"
  end

  def test_a_record_under_a_separate_repository_is_written
    run = write(@history)
    assert_equal File.join(@history, 'bench', 'qemu-hvf-Mac16,10-4cpu-erxos', "20261123T120000Z-abcdef012345-#{record.subject.digest[0, 12]}"), run
    assert File.file?(File.join(run, 'run.json'))
    assert File.file?(File.join(run, 'boot-1', 'wake', 'park-deadline.json'))
    assert_equal Record::FORMAT, JSON.parse(File.read(File.join(run, 'run.json'))).fetch('format')
  end

  def test_a_written_record_reads_back
    run = write(@history)
    assert_equal record, Record.read(run)
  end

  def test_a_record_of_another_format_is_refused
    run = write(@history)
    path = File.join(run, 'run.json')
    File.write(path, JSON.generate(JSON.parse(File.read(path)).merge('format' => 0)))
    error = assert_raises(Erx::Error) { Record.read(run) }
    assert_match(/format/, error.message)
  end

  def test_a_run_directory_is_never_written_over
    write(@history)
    assert_raises(Erx::Error) { write(@history) }
  end

  def test_a_repository_inside_a_second_worktree_is_refused
    nested = File.join(@second, 'build', 'history')
    git_init(nested)
    error = assert_raises(Erx::Error) { write(nested) }
    assert_match(/inside the erXos worktree/, error.message)
    refute File.exist?(File.join(nested, 'bench'))
  end

  def test_the_second_worktree_itself_is_refused
    error = assert_raises(Erx::Error) { write(@second) }
    assert_match(/common git directory/, error.message)
  end

  def test_a_history_root_that_links_into_the_tree_is_refused
    nested = File.join(@erxos, 'history')
    git_init(nested)
    link = File.join(@scratch, 'link')
    File.symlink(nested, link)
    assert_raises(Erx::Error) { write(link) }
    refute File.exist?(File.join(nested, 'bench'))
  end

  def test_a_bench_directory_that_links_into_a_worktree_is_refused
    target = File.join(@second, 'build')
    FileUtils.mkdir_p(target)
    File.symlink(target, File.join(@history, 'bench'))
    error = assert_raises(Erx::Error) { write(@history) }
    assert_match(/symbolic link/, error.message)
    assert_empty Dir.children(target)
  end

  def test_a_plain_directory_is_refused
    plain = File.join(@scratch, 'plain')
    FileUtils.mkdir_p(plain)
    error = assert_raises(Erx::Error) { write(plain) }
    assert_match(/top of a git work tree/, error.message)
  end

  # A second clone of erXos has its own common git directory and is in no listed
  # worktree; it shares erXos's root commit, and that is what refuses it.
  def test_a_second_clone_of_erxos_is_refused
    clone = File.join(@scratch, 'clone')
    git(@scratch, 'clone', '-q', @erxos, clone)
    error = assert_raises(Erx::Error) { write(clone) }
    assert_match(/root commit/, error.message)
    refute File.exist?(File.join(clone, 'bench'))
  end

  def test_a_clone_on_an_orphan_branch_or_shallow_is_refused
    orphan = File.join(@scratch, 'orphan')
    git(@scratch, 'clone', '-q', @erxos, orphan)
    git(orphan, 'checkout', '-q', '--orphan', 'history')
    assert_match(/root commit/, assert_raises(Erx::Error) { write(orphan) }.message)
    shallow = File.join(@scratch, 'shallow')
    git(@scratch, 'clone', '-q', '--depth', '1', "file://#{@erxos}", shallow)
    assert_match(/history destination is a shallow clone/, assert_raises(Erx::Error) { write(shallow) }.message)
    separate = File.join(@scratch, 'separate')
    git_init(separate)
    message = assert_raises(Erx::Error) { Record.write(record, history: separate, erxos_root: shallow) }.message
    assert_match(/the erXos repository is a shallow clone/, message)
  end

  def test_a_clone_whose_head_names_a_missing_branch_is_refused
    clone = File.join(@scratch, 'dangling')
    git(@scratch, 'clone', '-q', @erxos, clone)
    git(clone, 'symbolic-ref', 'HEAD', 'refs/heads/missing')
    assert_match(/shares a root commit/, assert_raises(Erx::Error) { write(clone) }.message)
  end

  def test_a_plain_clone_is_refused_while_erxos_is_on_an_orphan_branch
    clone = File.join(@scratch, 'plain')
    git(@scratch, 'clone', '-q', @erxos, clone)
    git(@erxos, 'checkout', '-q', '--orphan', 'elsewhere')
    git(@erxos, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'y')
    assert_match(/shares a root commit/, assert_raises(Erx::Error) { write(clone) }.message)
  end

  def test_a_separate_repository_with_its_own_history_is_written
    git(@history, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-q', '--allow-empty',
        '-m', 'history')
    assert File.directory?(write(@history))
  end

  def test_a_missing_root_is_refused
    error = assert_raises(Erx::Error) { write(File.join(@scratch, 'absent')) }
    assert_match(/does not exist/, error.message)
  end

  def test_names_that_are_not_declaration_names_cannot_be_built
    assert_raises(Erx::Error) { cell(benchmark: '../escape') }
    assert_raises(Erx::Error) { cell(operation: 'a/b') }
    assert_raises(Erx::Error) { cell(status: 'passed') }
  end

  def test_a_wrong_answer_is_not_measured_and_an_absent_result_has_no_summary
    assert_raises(Erx::Error) { cell(early: 1) }
    cell(status: 'failed', early: 1)
    assert_raises(Erx::Error) { cell(status: 'timed_out') }
    assert_empty cell(status: 'timed_out', histogram: []).summary
  end

  # The summary is derived from the histogram, with its sample count, never supplied.
  def test_a_summary_is_derived_from_the_histogram
    summary = cell.summary
    assert_equal 2000, summary['samples']
    assert_equal({ 'value' => 1016, 'bucket' => 17 }, summary['p50'])
    assert_equal [1000, 1016, false], summary.values_at('min', 'max', 'partial')
    assert cell(status: 'partial').summary['partial']
    assert_raises(Erx::Error) { cell(histogram: [[10, 20, 1], [15, 30, 1]]) }
  end

  def test_the_summary_in_run_json_is_the_derived_one
    run = write(@history)
    manifest = JSON.parse(File.read(File.join(run, 'run.json')))
    assert_equal 2000, manifest.fetch('boots').first.fetch('cells').first.fetch('summary').fetch('samples')
  end

  def test_nothing_is_made_inside_a_worktree_at_the_history_roots_bench
    git(@erxos, 'worktree', 'add', '-q', '--detach', File.join(@history, 'bench'))
    assert_raises(Erx::Error) { write(@history) }
    assert_equal ['.git'], Dir.children(File.join(@history, 'bench'))
  end

  # n samples, one to a bucket of one tick, so the sample of rank r reports r.
  def histogram(count) = (1..count).map { |value| [value, value, 1] }

  def test_a_measured_cell_holds_every_sample_its_profile_asked_for
    error = assert_raises(Erx::Error) { cell(histogram: [[1000, 1016, 1999]]) }
    assert_match(/every sample/, error.message)
    cell(status: 'partial', histogram: [[1000, 1016, 1999]])
  end

  def test_a_cells_extremes_lie_in_the_buckets_that_hold_them
    histogram = [[1000, 1007, 1000], [1008, 1016, 1000]]
    assert_raises(Erx::Error) { cell(histogram: histogram, extremes: { 'min' => 1008, 'max' => 1016 }) }
    assert_raises(Erx::Error) { cell(histogram: histogram, extremes: { 'min' => 1000 }) }
    assert_raises(Erx::Error) { cell(status: 'partial', histogram: [], extremes: { 'min' => 1, 'max' => 1 }) }
    cell(histogram: histogram, extremes: { 'min' => 1003, 'max' => 1009 })
    # Both extremes in one bucket, the minimum above the maximum.
    assert_raises(Erx::Error) { cell(histogram: [[1000, 1016, 2000]], extremes: { 'min' => 1010, 'max' => 1005 }) }
  end

  # A one-way cell across CPUs is measured only while its uncertainty is at most a tenth
  # of its median (here the median bucket's upper end, 1016).
  def test_a_measured_cells_uncertainty_is_at_most_a_tenth_of_its_median
    bounds = { 'min' => 1000, 'max' => 1016 }
    assert_match(/uncertainty/, assert_raises(Erx::Error) { cell(extremes: bounds.merge('uncertainty' => 102)) }.message)
    cell(extremes: bounds.merge('uncertainty' => 101))
    cell(status: 'partial', extremes: bounds.merge('uncertainty' => 5000))
  end

  # A batched cell's total is the ticks its batches spanned. Each of its 2,000 samples is
  # its batch of 4 calls' ticks divided by 4, rounded down, so the total lies between 4
  # times the samples' sum and that sum plus 3 for each sample. Its summary claims the
  # calls and the total, from which a mean follows; a total held as null is refused.
  def test_a_total_is_the_ticks_its_batches_spanned
    histogram = [[4, 4, 1500], [5, 5, 500]]
    least = 4 * (4 * 1500 + 5 * 500)
    most = least + 2000 * 3
    [least, most].each do |total|
      summary = cell(profile: 'fast', batch: 4, histogram: histogram, total: total).summary
      assert_equal [8000, total], summary.values_at('count', 'total')
    end
    # A total outside that range, such as one batch's ticks, is refused.
    [least - 1, most + 1, 5].each do |total|
      assert_match(/total/, assert_raises(Erx::Error) do
        cell(profile: 'fast', batch: 4, histogram: histogram, total: total)
      end.message)
    end
    assert_raises(Erx::Error) do
      Record::Cell.new(**cell(profile: 'fast', batch: 4, histogram: histogram).to_h.merge(detail: { 'histogram' => histogram, 'min' => 4, 'max' => 5, 'total' => nil }))
    end
    refute cell.summary.key?('total')
  end

  def test_the_median_is_its_buckets_upper_end_at_any_count
    assert_equal 4, Record.median([[1, 1, 1], [2, 2, 1], [3, 4, 2], [5, 5, 1]])
    assert_nil Record.median([])
  end

  def test_a_cells_detail_is_frozen_through
    assert cell.detail.fetch('histogram').first.frozen?
  end

  def test_a_cells_reason_holds_nothing_a_terminal_interprets
    ["esc \e[31m", 'Upper', "tab\there", 'a' * 81].each do |reason|
      assert_raises(Erx::Error) { cell(status: 'unsupported', histogram: [], reason: reason) }
    end
    cell(status: 'unsupported', histogram: [], reason: 'counters across CPUs not bounded closely enough')
  end

  def test_a_percentile_needs_ten_samples_above_it
    [[Record::P99, 1000, 990], [Record::P999, 10_000, 9990], [Record::P50, 20, 10]].each do |p, count, value|
      assert_equal({ 'value' => value, 'bucket' => 1 }, Record.percentile(histogram(count), p), "#{p} of #{count}")
      assert_equal({ 'unsupported' => 'too few samples' }, Record.percentile(histogram(count - 1), p),
                   "#{p} of #{count - 1}")
    end
  end

  def test_a_percentile_is_its_buckets_upper_bound
    assert_equal({ 'value' => 1063, 'bucket' => 64 }, Record.percentile([[1000, 1063, 40]], Record::P50))
  end

  def environment(kind, system:, model: 'Mac16,10', cpus: 4) =
    Record::Environment.new(kind: kind, model: model, cpus: cpus, system: system, details: {})

  # docs/design-bench.md, "Environments": every environment that boots a guest names its
  # system, so two systems' records never share one; the host runs stock OTP and none.
  def test_every_guests_environment_names_its_system
    assert_equal 'qemu-hvf-Mac16,10-4cpu-erxos', environment('qemu-hvf', system: 'erxos').name
    assert_equal 'qemu-hvf-Mac16,10-4cpu-linux', environment('qemu-hvf', system: 'linux').name
    assert_equal 'qemu-tcg-Mac16,10-1cpu-l4re', environment('qemu-tcg', system: 'l4re', cpus: 1).name
    assert_equal 'qemu-det-erxos', environment('qemu-det', system: 'erxos', model: nil, cpus: 1).name
    assert_equal 'pi4-4gb-freebsd', environment('pi4', system: 'freebsd', model: nil).name
    assert_equal 'host-Mac16,10', environment('host', system: nil).name
    %w[qemu-hvf qemu-tcg qemu-det pi4].each do |kind|
      assert_match(/needs its system/, assert_raises(Erx::Error) { environment(kind, system: nil) }.message, kind)
    end
    assert_raises(Erx::Error) { environment('host', system: 'erxos') }
  end

  def test_a_record_of_a_guests_environment_without_its_system_does_not_parse
    run = write(@history)
    path = File.join(run, 'run.json')
    manifest = JSON.parse(File.read(path))
    manifest.fetch('environment')['system'] = nil
    File.write(path, JSON.generate(manifest))
    assert_raises(Erx::Error) { Record.read(run) }
  end

  def test_the_other_systems_clocks_are_clocks
    %w[monotonic cycles].each do |clock|
      Record::Conditions.new(load: 'idle', placement: 'same-cpu', parameters: {}, clock: clock, batch: 1)
    end
    assert_raises(Erx::Error) do
      Record::Conditions.new(load: 'idle', placement: 'same-cpu', parameters: {}, clock: 'tsc', batch: 1)
    end
  end

  MEAN = { 'count' => 10_000, 'total' => 4_213_000, 'mean' => 421.3 }.freeze

  def mean_cell(status: 'measured', detail: status == 'measured' ? MEAN : {}, counts: nil, profile: nil)
    Record::Cell.new(
      benchmark: 'nullcall', operation: 'root-same-space', form: 'mean',
      conditions: Record::Conditions.new(load: 'idle', placement: 'same-cpu', parameters: {}, clock: 'cycles', batch: 1),
      profile: profile, status: status, reason: status == 'measured' ? nil : 'test', counts: counts, detail: detail
    )
  end

  def mean_record(cells: [mean_cell], clock: nil)
    Record::Record.new(
      environment: environment('qemu-hvf', system: 'l4re', cpus: 1),
      subject: Record::Subject.new(revision: REVISION, dirty: false, details: {}),
      run: run_facts, boots: [boot(cells: cells, clock: clock)]
    )
  end

  # docs/design-bench.md, "A mean": a cell another system's own program reports holds its
  # operation count, total and printed mean, and its samples, percentiles, extremes and
  # event counts are absent, never zero.
  def test_a_mean_through_the_record_keeps_only_its_count_total_and_mean
    run = Record.write(mean_record, history: @history, erxos_root: @erxos)
    back = Record.read(run)
    assert_equal mean_record, back
    cell = back.boot.cells.first
    assert_equal ['mean', MEAN, nil, nil], [cell.form, cell.summary, cell.counts, cell.profile]
    assert_nil back.boot.clock
    listed = JSON.parse(File.read(File.join(run, 'run.json'))).fetch('boots').first.fetch('cells').first
    assert_equal MEAN, listed.fetch('summary')
    assert_nil listed.fetch('counts')
  end

  def test_a_mean_holds_nothing_but_its_mean
    assert_raises(Erx::Error) { mean_cell(detail: MEAN.merge('histogram' => [[1, 1, 1]])) }
    assert_raises(Erx::Error) { mean_cell(detail: MEAN.except('total')) }
    assert_raises(Erx::Error) { mean_cell(detail: MEAN.merge('count' => 0)) }
    assert_raises(Erx::Error) { mean_cell(counts: { 'lost' => 0, 'early' => 0, 'missed' => 0 }) }
    assert_raises(Erx::Error) { mean_cell(profile: Record::Profile.new(name: 'fast', warmup: 0, samples: 1, runs: 1)) }
    assert_raises(Erx::Error) { mean_cell(status: 'partial') }
    assert_raises(Erx::Error) { mean_cell(status: 'failed', detail: MEAN) }
    assert_empty mean_cell(status: 'failed').summary
    assert_empty mean_cell(status: 'not_run').summary
    assert_raises(Erx::Error) { cell.with(form: 'median') }
  end

  # A boot whose cells are all means has no clock group, since their program measures no
  # calibration; a boot with a histogram cell keeps its own.
  def test_only_a_boot_of_means_has_no_clock_group
    assert_raises(Erx::Error) { mean_record(clock: { 'frequency_hz' => 24_000_000 }) }
    assert_raises(Erx::Error) { boot(clock: nil) }
    mean_record(cells: [mean_cell, cell], clock: {})
  end

  # docs/design-bench.md, "The record of a board run": one record per subject holds that
  # set's boots, one per queued entry, each at its position in the queue with its own
  # facts, clock and cells, and each boot's cells in a directory of their own.
  def two_boots
    record(boots: [boot(position: 1, details: { 'outcome' => 'ended' }),
                   boot(position: 3, cells: [cell(status: 'not_run', histogram: [])], clock: {},
                        details: { 'outcome' => 'not_run' })],
           run: run_facts(details: { 'ending' => 'returned', 'restored' => true }))
  end

  def test_a_record_of_two_boots_reads_back
    run = Record.write(two_boots, history: @history, erxos_root: @erxos)
    assert_equal two_boots, Record.read(run)
    assert File.file?(File.join(run, 'boot-1', 'wake', 'park-deadline.json'))
    assert File.file?(File.join(run, 'boot-3', 'wake', 'park-deadline.json'))
    listed = JSON.parse(File.read(File.join(run, 'run.json'))).fetch('boots')
    assert_equal [[1, 'boot-1/wake/park-deadline.json'], [3, 'boot-3/wake/park-deadline.json']],
                 listed.map { |boot| [boot.fetch('position'), boot.fetch('cells').first.fetch('file')] }
  end

  # Each boot holds one cell per key; two boots of one record hold the same cell each.
  def test_a_boot_holds_one_cell_once_and_two_boots_hold_it_each
    error = assert_raises(Erx::Error) { boot(cells: [cell, cell]) }
    assert_match(/boot holds one cell twice/, error.message)
    record(boots: [boot(position: 1), boot(position: 2)])
  end

  def test_boots_are_in_ascending_positions_once_each
    [[2, 1], [1, 1]].each do |positions|
      boots = positions.map { |position| boot(position: position) }
      assert_raises(Erx::Error, positions.inspect) { record(boots: boots) }
    end
    [0, -1, 1 << 16, '1'].each { |position| assert_raises(Erx::Error, position.inspect) { boot(position: position) } }
    assert_raises(Erx::Error) { record(boots: []) }
  end

  def test_each_boots_logs_are_named_by_its_position
    serial = "erx: done\n"
    run = Record.write(two_boots, history: @history, erxos_root: @erxos, logs: [{}, { serial: serial }])
    assert_equal ['boot-3.serial.log'], Dir.children(run).grep(/\.log\z/)
    assert_raises(Erx::Error) { Record.write(two_boots, history: @history, erxos_root: @erxos, logs: [{ serial: serial }]) }
  end

  # Two sets of one revision booted in one walk share its date: the subject's digest
  # keeps their run directories apart.
  def test_two_subjects_of_one_revision_and_date_are_two_runs
    first = Record.write(record(subject: { 'image_sha256' => 'a' * 64 }), history: @history, erxos_root: @erxos)
    second = Record.write(record(subject: { 'image_sha256' => 'b' * 64 }), history: @history, erxos_root: @erxos)
    refute_equal first, second
  end

  # The format before boots held one boot's clock and cells at the top: refused by its
  # format, never misread.
  def test_a_record_of_the_previous_format_is_refused
    run = write(@history)
    path = File.join(run, 'run.json')
    manifest = JSON.parse(File.read(path))
    boot = manifest.delete('boots').first
    File.write(path, JSON.generate(manifest.merge('format' => 2, 'clock' => boot.fetch('clock'), 'cells' => boot.fetch('cells'))))
    assert_match(/not of format #{Record::FORMAT}/, assert_raises(Erx::Error) { Record.read(run) }.message)
  end

  # A cell's file is derived from its boot's position and its names; a manifest naming
  # another file, even one that exists and holds the same cell, or one outside the run,
  # is not a record.
  def test_a_manifest_naming_another_cell_file_is_refused
    run = Record.write(record(boots: [boot(position: 1), boot(position: 2)]), history: @history, erxos_root: @erxos)
    path = File.join(run, 'run.json')
    written = File.read(path)
    ['boot-1/wake/park-deadline.json', '../../x/run.json'].each do |file|
      manifest = JSON.parse(written)
      manifest.fetch('boots').last.fetch('cells').first['file'] = file
      File.write(path, JSON.generate(manifest))
      assert_match(/not derived from it/, assert_raises(Erx::Error) { Record.read(run) }.message, file)
    end
  end

  # Every boot of one subject was asked the same cells, whatever their statuses.
  def test_the_boots_of_a_record_hold_the_same_cells
    error = assert_raises(Erx::Error) { record(boots: [boot(position: 1), boot(position: 2, cells: [cell(batch: 2)])]) }
    assert_match(/different cells/, error.message)
  end
end
