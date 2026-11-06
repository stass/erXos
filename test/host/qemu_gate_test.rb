# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/qemu_gate'
require_relative '../../tools/lib/erx/production_image'

# The QEMU gate decides from what each suite observed and never turns an
# absence into a pass. These tests run the real suites only where they start
# no guest: a roster of pending cases. Every other suite is run here as a
# stand-in that reports chosen cells under the real suite's declaration.
class QemuGateTest < Minitest::Test
  Gate = Erx::QemuGate
  ROOT = File.expand_path('../..', __dir__)

  def context = Gate::Context.new(root: ROOT, jobs: 1)

  def result(**cells) = Gate.result(cells.transform_keys(&:to_s))

  def suite(name, cells, &run) = Gate::Suite.new(name: name, cells: cells, run: run)

  def real_suite(name) = Gate.suites.find { |entry| entry.name == name }

  # The real suite's declared cells, run by a stand-in that reports every
  # one of them as passed except those it drops.
  def run_dropping(name, dropped)
    declared = real_suite(name)
    reported = (declared.cells - dropped).to_h { |cell| [cell, 'passed'] }
    Gate.run(suites: [suite(name, declared.cells) { |_| Gate.result(reported) }], context: context).fetch(name)
  end

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
    with_suite_files('bad.rb' => "Erx::QemuGate.declare_suite(cells: ['hvf-1cpu'], run: 1)") do |directory|
      assert_raises(Erx::Error) { Gate.load_suites(directory) }
    end
    with_suite_files('Bad-Name.rb' => "Erx::QemuGate.declare_suite(cells: ['hvf-1cpu'], run: -> (_) {})") do |directory|
      assert_raises(Erx::Error) { Gate.load_suites(directory) }
    end
  end

  def test_a_suite_must_declare_the_cells_it_reports
    ['[]', 'nil', "['hvf-1cpu', 'hvf-1cpu']", '[1]'].each do |cells|
      with_suite_files('cells.rb' => "Erx::QemuGate.declare_suite(cells: #{cells}, run: -> (_) {})") do |directory|
        assert_raises(Erx::Error, cells) { Gate.load_suites(directory) }
      end
    end
  end

  def test_every_suite_runs_under_hvf_and_only_the_production_image_names_tcg
    Gate.suites.each do |entry|
      refute_empty entry.cells.select { |cell| cell.start_with?("#{Gate::SUITE_ACCELERATOR}-") }, entry.name
    end
    tcg = Gate.suites.to_h { |entry| [entry.name, entry.cells.grep(/\A#{Gate::SMOKE_ACCELERATOR}-/o)] }.reject { |_, cells| cells.empty? }
    assert_equal({ 'production_image' => %w[tcg-1cpu tcg-deterministic] }, tcg)
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

  def test_the_production_image_with_every_cell_passes
    assert_equal 'passed', Gate.status(run_dropping('production_image', []))
  end

  def test_a_production_image_run_without_the_smoke_does_not_pass
    entry = run_dropping('production_image', Erx::ProductionImage::Run::SMOKE_CELLS)
    assert_equal 'not_run', entry.cells.fetch('tcg-1cpu')
    assert_equal 'not_run', entry.cells.fetch('tcg-deterministic')
    assert_equal 'incomplete', Gate.status(entry)
    assert_equal 'incomplete', Gate.overall([Gate.status(entry)])
    assert_includes entry.notes, 'tcg-deterministic was expected and did not run'
  end

  def test_a_production_image_run_without_the_transcript_alone_does_not_pass
    entry = run_dropping('production_image', %w[tcg-deterministic])
    assert_equal 'incomplete', Gate.status(entry)
  end

  def test_a_run_that_drops_one_hvf_cell_does_not_pass
    %w[production_image debug_log boot_image].each do |name|
      entry = run_dropping(name, [real_suite(name).cells.find { |cell| cell.start_with?('hvf-4cpu') }])
      assert_equal 'incomplete', Gate.status(entry), name
      assert_equal 'incomplete', Gate.overall(['passed', Gate.status(entry)]), name
    end
  end

  def test_a_declared_cell_left_pending_beside_cells_that_ran_did_not_run
    entry = Gate.run(suites: [suite('s', %w[a b]) { |_| result(a: 'passed', b: 'pending') }], context: context).fetch('s')
    assert_equal({ 'a' => 'passed', 'b' => 'not_run' }, entry.cells)
    assert_equal 'incomplete', Gate.status(entry)
    waiting = Gate.run(suites: [suite('s', %w[a b]) { |_| result(a: 'pending', b: 'pending') }], context: context).fetch('s')
    assert_equal 'pending', Gate.status(waiting)
  end

  def test_a_suite_that_raises_is_a_failed_suite_with_the_message
    suites = [suite('boom', %w[x]) { |_| raise Erx::Error, 'transcript differs' },
              suite('fine', %w[x]) { |_| result(x: 'passed') }]
    results = Gate.run(suites: suites, context: context)
    assert_equal 'failed', Gate.status(results.fetch('boom'))
    assert_equal ['transcript differs'], results.fetch('boom').notes
    assert_equal 'passed', Gate.status(results.fetch('fine'))
    assert_equal 'failed', Gate.overall(results.values.map { |entry| Gate.status(entry) })
  end

  def test_a_bug_in_a_suite_is_not_swallowed
    suites = [suite('bug', %w[x]) { |_| raise NoMethodError, 'nil' }]
    assert_raises(NoMethodError) { Gate.run(suites: suites, context: context) }
  end

  def test_suites_run_under_hvf_and_tcg_is_the_smoke_alone
    assert_equal 'hvf', Gate::SUITE_ACCELERATOR
    assert_equal 'tcg', Gate::SMOKE_ACCELERATOR
    assert_equal %w[hvf tcg], Gate::REQUIRED_ACCELERATORS
    assert(Erx::ProductionImage::Run::SMOKE_CELLS.all? { |cell| cell.start_with?("#{Gate::SMOKE_ACCELERATOR}-") })
  end

  def test_pending_conformance_cases_are_reported_as_pending_and_start_no_guest
    results = Gate.run(suites: [real_suite('conformance')], context: context)
    entry = results.fetch('conformance')
    assert_equal Gate.suite_cells([1, 4]), entry.cells.keys & Gate.suite_cells([1, 4])
    assert_equal ['pending'], entry.cells.values.uniq
    assert_equal 'pending', Gate.status(entry)
  end

  def test_the_table_names_each_suite_its_status_and_what_did_not_run
    results = { 'a' => Gate.result({ 'hvf-1cpu' => 'passed', 'hvf-4cpu' => 'not_run' }, notes: ['hvf-4cpu was expected']),
                'b' => Gate.result({ 'case x' => 'pending' }) }
    lines = Gate.table(results)
    assert_match(/\Aa +incomplete +hvf-1cpu passed, hvf-4cpu not_run\z/, lines[0])
    assert_match(/\Ab +pending +case x pending\z/, lines[1])
    assert_equal 'a: hvf-4cpu was expected', lines[2]
    assert_equal 'qemu gate: incomplete; 2 suites, 1 pending; suites under hvf, smoke under tcg', lines[3]
  end
end
