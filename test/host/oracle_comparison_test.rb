# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/oracle_comparison'

# The decisions of the hosted oracle's comparison, from small event streams
# of the shape erx_oracle_events writes and a table of known differences.
class OracleComparisonTest < Minitest::Test
  # Each case's status in the stock fixture and in the erXos one; nil is a
  # case that started and never finished.
  STOCK = { 'same' => 'passed', 'listed' => 'passed', 'unlisted' => 'passed',
            'stale' => 'passed', 'changed' => 'passed', 'hung' => 'passed' }.freeze
  ERXOS = { 'same' => 'passed', 'listed' => 'failed', 'unlisted' => 'failed',
            'stale' => 'passed', 'changed' => 'user_skip', 'hung' => 'passed' }.freeze
  TABLE = <<~TABLE
    # suite        group  case     status  reason
    fixture_SUITE  -      listed   failed  the fixture's listed difference
    fixture_SUITE  -      stale    failed  a difference erXos no longer shows
    fixture_SUITE  -      changed  failed  a difference whose erXos status moved
  TABLE

  def setup
    @directory = Dir.mktmpdir('erx-oracle-comparison-')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_a_listed_difference_passes
    assert_equal 'known', verdict('listed')
  end

  def test_an_unlisted_difference_fails
    assert_equal 'differs', verdict('unlisted')
    refute comparison.passed?
  end

  def test_a_listed_case_that_matches_stock_is_a_stale_row
    assert_equal 'stale', verdict('stale')
  end

  def test_a_listed_case_whose_erxos_status_moved_fails
    assert_equal 'changed', verdict('changed')
  end

  def test_agreement_passes_and_only_listed_differences_pass_the_run
    assert_equal 'same', verdict('same')
    table = Erx::OracleComparison.known_differences(text: TABLE.lines.first(2).join, source: 'fixture')
    erxos = ERXOS.merge('unlisted' => 'passed', 'changed' => 'passed')
    result = Erx::OracleComparison.compare(stock: side('stock', STOCK), erxos: side('erxos', erxos), known: table)
    assert result.passed?, result.rows.reject { |row| row.verdict == 'same' }.inspect
  end

  def test_a_case_cut_off_by_the_deadline_shows_as_timed_out
    erxos = side('erxos', ERXOS.merge('hung' => nil), command: 'timed_out')
    result = Erx::OracleComparison.compare(stock: side('stock', STOCK), erxos: erxos, known: known)
    row = result.rows.find { |candidate| candidate.testcase == 'hung' }
    assert_equal ['passed', 'timed_out', 'unresolved'], [row.stock, row.erxos, row.verdict]
    assert_equal 'timed_out', result.erxos.state
    refute result.passed?
  end

  def test_a_case_cut_off_by_a_crash_shows_as_crashed
    erxos = side('erxos', ERXOS.merge('hung' => nil), command: 'failed')
    row = Erx::OracleComparison.compare(stock: side('stock', STOCK), erxos: erxos, known: known)
                               .rows.find { |candidate| candidate.testcase == 'hung' }
    assert_equal %w[crashed unresolved], [row.erxos, row.verdict]
  end

  def test_a_case_one_side_never_reached_is_unknown
    erxos = side('erxos', ERXOS.except('hung'))
    result = Erx::OracleComparison.compare(stock: side('stock', STOCK), erxos: erxos, known: known)
    row = result.rows.find { |candidate| candidate.testcase == 'hung' }
    assert_equal %w[passed unknown unresolved], [row.stock, row.erxos, row.verdict]
    refute result.passed?
  end

  def test_an_unreadable_stream_makes_every_case_unknown
    path = File.join(@directory, 'broken.jsonl')
    File.write(path, "{\"event\":\n")
    erxos = Erx::OracleComparison.side(events: path, command_state: 'succeeded')
    assert_match(/unreadable/, erxos.state)
    result = Erx::OracleComparison.compare(stock: side('stock', STOCK), erxos: erxos, known: known)
    assert(result.rows.all? { |row| row.erxos == 'unknown' && row.verdict == 'unresolved' })
    refute result.passed?
  end

  def test_the_report_names_each_status_and_verdict
    report = comparison.report
    assert_match(/^differs\s+fixture_SUITE unlisted #1: stock passed, erXos failed, not in the table$/, report)
    assert_match(/^stale\s+fixture_SUITE stale #1: .*delete the row/, report)
    assert_match(/^known\s+fixture_SUITE listed #1: .*the fixture's listed difference/, report)
    assert_match(/^result: FAIL/, report)
  end

  def test_the_table_refuses_what_does_not_name_one_case
    ['fixture_SUITE - list* failed wildcard',
     'fixture_SUITE - listed timed_out not a Common Test status',
     'fixture_SUITE - listed failed',
     "fixture_SUITE - listed failed one\nfixture_SUITE - listed failed two",
     'fixture_SUITE files/ listed failed empty group'].each do |text|
      assert_raises(Erx::Error, text) { Erx::OracleComparison.known_differences(text: "#{text}\n", source: 'fixture') }
    end
  end

  def test_the_table_reads_group_paths
    table = Erx::OracleComparison.known_differences(text: "a_SUITE files/open open_errors failed why\n", source: 'x')
    assert_equal [%w[files open]], table.map(&:group)
  end

  def test_the_checked_in_table_parses
    path = File.expand_path('../oracle/hosted_known_differences.txt', __dir__)
    table = Erx::OracleComparison.known_differences(text: File.read(path), source: path)
    refute_empty table
  end

  def test_a_row_naming_no_case_of_two_finished_runs_is_stale
    table = known + Erx::OracleComparison.known_differences(text: "fixture_SUITE - renamed failed gone\n", source: 'x')
    result = Erx::OracleComparison.compare(stock: side('stock', STOCK), erxos: side('erxos', ERXOS), known: table)
    row = result.rows.find { |candidate| candidate.testcase == 'renamed' }
    assert_equal ['stale', nil], [row.verdict, row.attempt]
  end

  def test_a_row_naming_no_case_of_a_cut_off_run_is_unresolved
    table = known + Erx::OracleComparison.known_differences(text: "fixture_SUITE - later failed why\n", source: 'x')
    erxos = side('erxos', ERXOS.merge('hung' => nil), command: 'timed_out')
    row = Erx::OracleComparison.compare(stock: side('stock', STOCK), erxos: erxos, known: table)
                               .rows.find { |candidate| candidate.testcase == 'later' }
    assert_equal 'unresolved', row.verdict
  end

  def test_a_name_from_the_events_cannot_forge_a_report_line
    result = Erx::OracleComparison.compare(stock: side('stock', { "x\nresult: PASS" => 'passed' }),
                                           erxos: side('erxos', { "x\nresult: PASS" => 'failed' }), known: [])
    refute_match(/^result: PASS/, result.report)
    assert_match(/x\\u\{a\}result: PASS #1/, result.report)
  end

  private

  def known = Erx::OracleComparison.known_differences(text: TABLE, source: 'fixture')

  def comparison
    Erx::OracleComparison.compare(stock: side('stock', STOCK), erxos: side('erxos', ERXOS), known: known)
  end

  def verdict(testcase) = comparison.rows.find { |row| row.testcase == testcase }.verdict

  # An event stream of one fixture suite; a case whose status is nil starts
  # and never finishes, and the run then never reaches its end.
  def side(name, statuses, command: 'succeeded')
    path = File.join(@directory, "#{name}.jsonl")
    File.write(path, events(statuses).map { |record| "#{JSON.generate(record)}\n" }.join)
    Erx::OracleComparison.side(events: path, command_state: command)
  end

  def events(statuses)
    records = [{ 'event' => 'test_start' },
               { 'event' => 'selection_begin', 'id' => '#Ref<9.0.0>' },
               { 'event' => 'job_selected', 'selection' => '#Ref<9.0.0>', 'id' => '#Ref<9.0.1>', 'name' => 'fixture' },
               { 'event' => 'selection_seal', 'id' => '#Ref<9.0.0>', 'count' => 1 },
               { 'event' => 'job_admitted', 'id' => '#Ref<9.0.1>' },
               { 'event' => 'job_worker', 'id' => '#Ref<9.0.1>', 'worker' => '<0.1.0>' }]
    statuses.each_with_index do |(testcase, status), index|
      identity = { 'suite' => 'fixture_SUITE', 'testcase' => testcase, 'group' => nil }
      token = "#Ref<0.0.#{index}>"
      records << { 'event' => 'case_start', 'id' => token, 'suite' => 'fixture_SUITE', 'worker' => '<0.1.0>',
                   'testcase' => testcase, 'groups' => [], 'log' => "#{testcase}.html" }
      records << identity.merge('event' => 'tc_start')
      return records if status.nil?

      result = status.end_with?('skip') ? 'skipped' : status
      records << identity.merge('event' => 'tc_done', 'result' => result, 'detail' => result)
      records << { 'event' => 'case_finish', 'id' => token, 'status' => status, 'number' => index + 1,
                   'detail' => result }
    end
    counts = Erx::OracleResults::STATES.to_h { |state| [state, statuses.values.count(state)] }
    records << { 'event' => 'test_stats', **counts }
    records.push({ 'event' => 'job_traversed', 'worker' => '<0.1.0>' },
                 { 'event' => 'job_exit', 'id' => '#Ref<9.0.1>', 'worker' => '<0.1.0>', 'normal' => true },
                 { 'event' => 'selection_close', 'id' => '#Ref<9.0.0>', 'normal' => true },
                 { 'event' => 'test_done' })
  end
end
