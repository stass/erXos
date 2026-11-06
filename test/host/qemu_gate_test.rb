# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/qemu_gate'

# The QEMU gate decides from what each suite observed and never turns an
# absence into a pass. These tests run the real suites only where they start
# no guest: a host without the accelerator, and a roster of pending cases.
class QemuGateTest < Minitest::Test
  Gate = Erx::QemuGate
  ROOT = File.expand_path('../..', __dir__)

  def context(accels: %w[hvf], available: %w[hvf tcg])
    Gate::Context.new(root: ROOT, accels: accels, available: available, jobs: 1)
  end

  def result(**cells) = Gate.result(cells.transform_keys(&:to_s))

  def with_suite_files(files)
    Dir.mktmpdir('erx-qemu-suites-') do |directory|
      files.each { |name, text| File.write(File.join(directory, name), text) }
      yield directory
    end
  end

  def test_the_suites_are_found_by_their_files
    assert_equal Gate.suites.map(&:name).sort, Gate.suites.map(&:name)
    assert_includes Gate.suites.map(&:name), 'debug_log'
  end

  def test_a_directory_without_suites_or_with_a_bad_declaration_stops_the_gate
    with_suite_files({}) { |directory| assert_raises(Erx::Error) { Gate.load_suites(directory) } }
    with_suite_files('empty.rb' => '# nothing') { |directory| assert_raises(Erx::Error) { Gate.load_suites(directory) } }
    with_suite_files('bad.rb' => 'Erx::QemuGate.declare_suite(run: 1)') do |directory|
      assert_raises(Erx::Error) { Gate.load_suites(directory) }
    end
    with_suite_files('Bad-Name.rb' => 'Erx::QemuGate.declare_suite(run: -> (_) {})') do |directory|
      assert_raises(Erx::Error) { Gate.load_suites(directory) }
    end
  end

  def test_a_suite_is_judged_from_its_cells
    assert_equal 'passed', Gate.status(result(a: 'passed', b: 'passed', c: 'pending'))
    assert_equal 'pending', Gate.status(result(a: 'pending'))
    assert_equal 'incomplete', Gate.status(result(a: 'passed', b: 'not_run'))
    assert_equal 'incomplete', Gate.status(result(a: 'partial'))
    assert_equal 'failed', Gate.status(result(a: 'passed', b: 'timed_out', c: 'not_run'))
    assert_equal 'failed', Gate.status(result(a: 'failed', b: 'not_run'))
  end

  def test_a_suite_that_reports_nothing_fails_rather_than_passes
    assert_equal 'failed', Gate.status(Gate.result({}))
    assert_equal 'failed', Gate.overall([])
  end

  def test_an_unknown_cell_status_is_refused
    assert_raises(Erx::Error) { Gate.result({ 'a' => 'ok' }) }
    assert_raises(Erx::Error) { Gate::Result.new(cells: { 'a' => nil }, notes: []) }
  end

  def test_the_gate_passes_only_when_nothing_failed_or_went_unrun
    assert_equal 'passed', Gate.overall(%w[passed pending])
    assert_equal 'incomplete', Gate.overall(%w[passed incomplete pending])
    assert_equal 'failed', Gate.overall(%w[incomplete failed])
  end

  def test_a_gate_whose_suites_are_all_pending_ran_nothing
    assert_equal 'incomplete', Gate.overall(%w[pending])
  end

  def test_the_accelerators_the_qemu_plan_lists_work_as_a_set_would
    listed = Erx::QemuPlan.accelerators("Accelerators supported in QEMU binary:\nhvf\ntcg\n")
    here = Gate::Context.new(root: ROOT, accels: %w[hvf tcg tcg], available: listed, jobs: 1)
    assert_equal %w[hvf tcg], here.runnable
    assert_empty here.missing
  end

  def test_a_suite_that_raises_is_a_failed_suite_with_the_message
    suites = [Gate::Suite.new(name: 'boom', run: ->(_) { raise Erx::Error, 'transcript differs' }),
              Gate::Suite.new(name: 'fine', run: ->(_) { result(x: 'passed') })]
    results = Gate.run(suites: suites, context: context)
    assert_equal 'failed', Gate.status(results.fetch('boom'))
    assert_equal ['transcript differs'], results.fetch('boom').notes
    assert_equal 'passed', Gate.status(results.fetch('fine'))
    assert_equal 'failed', Gate.overall(results.values.map { |entry| Gate.status(entry) })
  end

  def test_a_bug_in_a_suite_is_not_swallowed
    suites = [Gate::Suite.new(name: 'bug', run: ->(_) { raise NoMethodError, 'nil' })]
    assert_raises(NoMethodError) { Gate.run(suites: suites, context: context) }
  end

  def test_a_missing_accelerator_is_reported_as_not_run
    here = context(accels: %w[hvf tcg], available: %w[tcg])
    assert_equal %w[hvf], here.missing
    assert_equal %w[tcg], here.runnable

    # No accelerator at all: the real debug-log suite starts no guest and says so.
    none = context(accels: %w[hvf], available: [])
    entry = Gate.suites.find { |suite| suite.name == 'debug_log' }.run.call(none)
    assert_equal({ 'hvf-1cpu' => 'not_run', 'hvf-4cpu' => 'not_run' }, entry.cells)
    assert_equal 'incomplete', Gate.status(entry)
    assert_match(/hvf is not offered/, entry.notes.first)
  end

def test_suites_run_under_hvf_and_tcg_is_the_smoke_alone
  assert_equal 'hvf', Gate::SUITE_ACCELERATOR
  assert_equal 'tcg', Gate::SMOKE_ACCELERATOR
  assert_equal %w[hvf tcg], Gate::REQUIRED_ACCELERATORS

  # Neither accelerator offered: the production-image suite starts no guest, and names both gaps.
  entry = Gate.suites.find { |suite| suite.name == 'production_image' }.run.call(context(available: []))
  assert_equal({ 'hvf-1cpu' => 'not_run', 'hvf-4cpu' => 'not_run', 'tcg-1cpu' => 'not_run' }, entry.cells)
  assert_equal ["hvf is not offered by this host's QEMU", "tcg is not offered by this host's QEMU"], entry.notes
end

  def test_pending_conformance_cases_are_reported_as_pending_and_start_no_guest
    entry = Gate.suites.find { |suite| suite.name == 'conformance' }.run.call(context(available: []))
    refute_empty entry.cells
    assert_equal ['pending'], entry.cells.values.uniq
    assert_equal 'pending', Gate.status(entry)
  end

  def test_the_table_names_each_suite_its_status_and_what_did_not_run
    results = { 'a' => Gate.result({ 'tcg-1cpu' => 'passed', 'hvf-1cpu' => 'not_run' }, notes: ['hvf is not offered']),
                'b' => Gate.result({ 'case x' => 'pending' }) }
    lines = Gate.table(results, context: context(accels: %w[tcg hvf], available: %w[tcg]))
    assert_match(/\Aa +incomplete +tcg-1cpu passed, hvf-1cpu not_run\z/, lines[0])
    assert_match(/\Ab +pending +case x pending\z/, lines[1])
    assert_equal 'a: hvf is not offered', lines[2]
    assert_equal 'qemu gate: incomplete; 2 suites, 1 pending; accelerators asked: tcg hvf; available: tcg', lines[3]
  end
end
