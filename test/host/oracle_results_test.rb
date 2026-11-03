# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/oracle_results'

class OracleResultsTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('erx-oracle-results-')
    @xml = File.join(@directory, 'junit.xml')
    @events = File.join(@directory, 'events.jsonl')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def xml(cases, tests:, failures: 0, skipped: 0)
    '<testsuites><testsuite name="fixture_SUITE" errors="0" ' \
      "tests=\"#{tests}\" failures=\"#{failures}\" skipped=\"#{skipped}\">" \
      "#{cases}</testsuite></testsuites>"
  end

  def testcase(name, body: '', group: 'outer.inner')
    "<testcase name=\"#{name}\" group=\"#{group}\" log=\"#{name}.html\" time=\"0.1\">#{body}</testcase>"
  end

  def evidence(passed: 1, failed: 0, user_skip: 0, auto_skip: 0, done: true, case_names: ['ok'])
    records = [{ 'event' => 'test_start' }]
    records.concat([
      { 'event' => 'selection_begin', 'id' => '#Ref<99.0.0>' },
      { 'event' => 'job_selected', 'selection' => '#Ref<99.0.0>', 'id' => '#Ref<99.0.1>', 'name' => 'fixture' },
      { 'event' => 'selection_seal', 'id' => '#Ref<99.0.0>', 'count' => 1 },
      { 'event' => 'job_admitted', 'id' => '#Ref<99.0.1>' },
      { 'event' => 'job_worker', 'id' => '#Ref<99.0.1>', 'worker' => '<0.1.0>' }
    ])
    case_names.each_with_index do |name, index|
      identity = { 'suite' => 'fixture_SUITE', 'testcase' => name, 'group' => nil }
      token = "#Ref<0.0.#{index}>"
      records << { 'event' => 'case_start', 'id' => token, 'suite' => 'fixture_SUITE',
                   'worker' => '<0.1.0>',
                   'testcase' => name, 'groups' => [], 'log' => "#{name}.html" }
      records << identity.merge('event' => 'tc_start')
      result = if %w[bad init_per_suite].include?(name)
                 'failed'
               elsif %w[user auto].include?(name)
                 'skipped'
               else
                 'passed'
               end
      records << identity.merge('event' => 'tc_done', 'result' => result, 'detail' => result)
      status = name == 'auto' ? 'auto_skip' : name == 'user' ? 'user_skip' : result
      records << { 'event' => 'case_finish', 'id' => token, 'status' => status,
                   'number' => Erx::OracleResults::CONFIG_CASES.include?(name) ? 0 : index + 1,
                   'detail' => name == 'bad' ? 'bad <term>' : result }
    end
    records << { 'event' => 'test_stats', 'passed' => passed, 'failed' => failed,
                 'user_skip' => user_skip, 'auto_skip' => auto_skip }
    records.concat([
      { 'event' => 'job_traversed', 'worker' => '<0.1.0>' },
      { 'event' => 'job_exit', 'id' => '#Ref<99.0.1>', 'worker' => '<0.1.0>', 'normal' => true },
      { 'event' => 'selection_close', 'id' => '#Ref<99.0.0>', 'normal' => true }
    ])
    records << { 'event' => 'test_done' } if done
    File.write(@events, records.map { |record| JSON.generate(record) + "\n" }.join)
  end

  def report(command: 'succeeded')
    Erx::OracleResults.read(xml: @xml, events: @events, command: { 'state' => command })
  end

  def test_repeats_and_group_projection_are_preserved
    body = testcase('same') + testcase('same') + testcase('same', group: 'different')
    cases = Erx::OracleResults.parse_xml(xml(body, tests: 3))
    assert_equal [1, 2, 1], cases.map { |record| record.fetch('attempt') }
    assert_equal ['outer.inner', 'outer.inner', 'different'], cases.map { |record| record.fetch('group') }
  end

  def test_completed_case_results_reconcile_with_common_test
    body = testcase('ok') + testcase('bad', body: '<failure>bad &lt;term&gt;</failure>') +
           testcase('user', body: '<skipped>{tc_user_skip,unsupported}</skipped>') +
           testcase('auto', body: '<skipped>{tc_auto_skip,{failed,setup}}</skipped>')
    File.write(@xml, xml(body, tests: 4, failures: 1, skipped: 2))
    evidence(passed: 1, failed: 1, user_skip: 1, auto_skip: 1, case_names: %w[ok bad user auto])
    result = report
    assert result.fetch('complete')
    assert_equal 'failed', result.fetch('state')
    assert_equal %w[passed failed user_skip auto_skip], result.fetch('cases').map { |record| record.fetch('status') }
    assert_equal 'bad <term>', result.fetch('cases')[1].fetch('detail')
  end

  def test_missing_completion_event_cannot_pass
    File.write(@xml, xml(testcase('ok'), tests: 1))
    evidence(done: false)
    result = report
    refute result.fetch('complete')
    assert_equal 'incomplete', result.fetch('state')
  end

  def test_event_totals_must_agree_with_cases
    File.write(@xml, xml(testcase('ok'), tests: 1))
    evidence(passed: 2)
    assert_equal 'incomplete', report.fetch('state')
  end

  def test_three_parallel_peer_cases_keep_actual_group_and_log_identity
    evidence(passed: 3, case_names: %w[peer_case peer_case peer_case])
    records = File.readlines(@events).map { |line| JSON.parse(line) }
    records.select { |record| record['event'] == 'case_start' }.each_with_index do |record, index|
      record['groups'] = [{ 'id' => "#Ref<1.0.#{index}>", 'name' => %w[one two three][index] }]
      record['log'] = "/tmp/erx-oracle/#{index}.html"
    end
    write_events(records)
    result = report
    assert result.fetch('complete')
    assert_equal [%w[one], %w[two], %w[three]], result.fetch('cases').map { |record| record.fetch('group') }
    assert_equal 3, result.fetch('cases').map { |record| record.fetch('log') }.uniq.size
    assert_equal [1, 1, 1], result.fetch('cases').map { |record| record.fetch('attempt') }
  end

  def test_missing_duplicate_and_foreign_terminal_records_cannot_pass
    evidence
    records = File.readlines(@events).map { |line| JSON.parse(line) }
    write_events(records.reject { |record| record['event'] == 'case_finish' })
    refute report.fetch('complete')
    duplicate = records.find { |record| record['event'] == 'case_finish' }
    write_events(records[0...-1] + [duplicate] + [records.last])
    assert_raises(Erx::Error) { report }
    records.find { |record| record['event'] == 'case_finish' }['id'] = '#Ref<9.9.9>'
    write_events(records)
    assert_raises(Erx::Error) { report }
  end

  def test_reused_group_reference_cannot_change_name_or_parent
    evidence(passed: 2, case_names: %w[ok ok])
    records = File.readlines(@events).map { |line| JSON.parse(line) }
    starts = records.select { |record| record['event'] == 'case_start' }
    starts[0]['groups'] = [{ 'id' => '#Ref<1.0.1>', 'name' => 'one' }]
    starts[1]['groups'] = [{ 'id' => '#Ref<1.0.1>', 'name' => 'two' }]
    write_events(records)
    assert_raises(Erx::Error) { report }
    starts[1]['groups'] = [{ 'id' => '#Ref<1.0.2>', 'name' => 'outer' }, starts[0]['groups'].first]
    write_events(records)
    assert_raises(Erx::Error) { report }
    starts[1]['groups'] = [starts[0]['groups'].first, starts[0]['groups'].first]
    write_events(records)
    assert_raises(Erx::Error) { report }
  end

  def test_external_suite_cases_can_share_the_actual_parent_group
    evidence(passed: 2, case_names: %w[ok ok])
    records = File.readlines(@events).map { |line| JSON.parse(line) }
    starts = records.select { |record| record['event'] == 'case_start' }
    starts.each { |record| record['groups'] = [{ 'id' => '#Ref<7.0.1>', 'name' => 'shared' }] }
    starts.last['suite'] = 'external_SUITE'
    independent = records.select { |record| %w[tc_start tc_done].include?(record['event']) }
    independent.last(2).each { |record| record['suite'] = 'external_SUITE' }
    write_events(records)
    assert report.fetch('complete')
    assert_equal %w[fixture_SUITE external_SUITE], report.fetch('cases').map { |record| record.fetch('suite') }
  end

  def test_optional_xml_cannot_create_extra_executions_or_change_status
    evidence
    File.write(@xml, xml(testcase('ok', body: '<failure>wrong</failure>') + testcase('surplus'), tests: 2, failures: 1))
    result = report
    assert result.fetch('complete')
    assert_equal ['ok'], result.fetch('cases').map { |record| record.fetch('testcase') }
    assert_equal 'passed', result.fetch('cases').first.fetch('status')
    refute result.fetch('cases').first.key?('xml')
    refute result.fetch('cases').first.key?('seconds')
    File.write(@xml, xml(testcase('ok'), tests: 1))
    assert_equal '0.1', report.fetch('cases').first.fetch('seconds')
    File.write(@xml, '<truncated')
    assert report.fetch('complete')
    assert_equal 'invalid', report.fetch('metadata').fetch('state')
  end

  def test_independent_event_outcomes_cannot_be_swapped_between_cases
    evidence(passed: 1, failed: 1, case_names: %w[ok bad])
    records = File.readlines(@events).map { |line| JSON.parse(line) }
    records.select { |record| record['event'] == 'tc_done' }.each do |record|
      record['result'] = record['result'] == 'passed' ? 'failed' : 'passed'
    end
    write_events(records)
    refute report.fetch('complete')
  end

  def test_optional_xml_timing_requires_one_execution_as_well_as_one_xml_row
    evidence(passed: 2, case_names: %w[ok ok])
    File.write(@xml, xml(testcase('ok'), tests: 1))
    result = report
    assert result.fetch('complete')
    refute result.fetch('cases').any? { |record| record.key?('seconds') }
  end

  def test_optional_xml_duration_must_be_bounded_finite_and_nonnegative
    evidence
    ['not-a-duration', 'NaN', 'Infinity', '-1', '1e999', '999999', '1' * 100, nil].each do |value|
      attribute = value ? "time=\"#{value}\"" : ''
      File.write(@xml, xml(testcase('ok').sub('time="0.1"', attribute), tests: 1))
      result = report
      assert result.fetch('complete')
      refute result.fetch('cases').first.key?('seconds'), "attached invalid duration #{value.inspect}"
    end
  end

  def test_whole_suite_skip_is_a_marker_not_an_executed_testcase
    evidence(passed: 0, user_skip: 1, case_names: ['all'])
    records = File.readlines(@events).map { |line| JSON.parse(line) }
    records.reject! { |record| %w[tc_start tc_done].include?(record['event']) }
    finish = records.find { |record| record['event'] == 'case_finish' }
    finish.merge!('number' => 0, 'status' => 'user_skip')
    records.insert(-3, { 'event' => 'tc_user_skip', 'suite' => 'fixture_SUITE',
                        'testcase' => 'all', 'group' => nil, 'detail' => 'skipped suite' })
    write_events(records)
    result = report
    assert result.fetch('complete')
    marker = result.fetch('cases').first
    assert_equal 'suite_skip', marker.fetch('kind')
    assert_equal 0, marker.fetch('number')
    assert_equal 0, result.fetch('counts').fetch('user_skip')
    assert_equal 1, result.fetch('suite_skip_counts').fetch('user_skip')
    assert_equal 1, result.fetch('common_test_counts').fetch('user_skip')
  end

  def test_completed_prefix_without_job_traversal_completion_is_incomplete
    evidence
    records = File.readlines(@events).map { |line| JSON.parse(line) }
    records.reject! { |record| record['event'].start_with?('job_', 'selection_') }
    write_events(records)
    refute report.fetch('complete')
  end

  def test_empty_job_after_finished_cases_cannot_certify_their_execution
    evidence
    records = File.readlines(@events).map { |line| JSON.parse(line) }
    jobs, rest = records.partition { |record| record['event'].start_with?('job_', 'selection_') }
    write_events(rest[0...-1] + jobs + [rest.last])
    refute report.fetch('complete')
  end

  def write_events(records)
    File.write(@events, records.map { |record| JSON.generate(record) + "\n" }.join)
  end

  def test_timeout_preserves_partial_evidence
    evidence(done: false)
    result = report(command: 'timed_out')
    assert_equal 'timed_out', result.fetch('state')
    refute result.fetch('complete')
    refute_empty result.fetch('partial_events')
  end

  def test_setup_failure_cannot_be_hidden_by_ignore_config_exit_status
    body = testcase('init_per_suite', body: '<failure>setup failed</failure>') +
           testcase('auto', body: '<skipped>{tc_auto_skip,{failed,setup}}</skipped>')
    File.write(@xml, xml(body, tests: 1, skipped: 1))
    evidence(passed: 0, auto_skip: 1, case_names: %w[init_per_suite auto])
    assert_equal 'failed', report.fetch('state')
  end

  def test_unsafe_or_malformed_xml_is_a_domain_error
    invalid = [
      '<!DOCTYPE testsuites [<!ENTITY x SYSTEM "file:///etc/passwd">]><testsuites/>',
      '<?xml version="1.0" encoding="UTF-16"?><testsuites/>',
      '<testsuites><testsuite>',
      '<testsuites><unknown/></testsuites>',
      "\xff".b,
      'garbage' + xml(testcase('ok'), tests: 1),
      xml(testcase('ok', body: '<failure>a</failure><skipped>{tc_user_skip,x}</skipped>'), tests: 1, skipped: 1)
    ]
    invalid.each do |bytes|
      assert_raises(Erx::Error) { Erx::OracleResults.parse_xml(bytes) }
    end
  end

  def test_suite_count_mismatch_and_unknown_skip_are_refused
    assert_raises(Erx::Error) { Erx::OracleResults.parse_xml(xml(testcase('ok'), tests: 2)) }
    bytes = xml(testcase('skip', body: '<skipped>unknown</skipped>'), tests: 1, skipped: 1)
    assert_raises(Erx::Error) { Erx::OracleResults.parse_xml(bytes) }
  end

  def test_completion_event_order_is_validated
    File.write(@xml, xml(testcase('ok'), tests: 1))
    evidence
    lines = File.readlines(@events)
    File.write(@events, lines.reverse.join)
    assert_raises(Erx::Error) { report }
  end

  def test_started_case_without_end_keeps_run_incomplete
    File.write(@xml, xml(testcase('ok'), tests: 1))
    evidence
    lines = File.readlines(@events)
    missing = JSON.generate('event' => 'tc_start', 'suite' => 'fixture_SUITE',
                            'testcase' => 'lost', 'group' => nil) + "\n"
    lines.insert(1, missing)
    lines.insert(1, JSON.generate('event' => 'case_start', 'id' => '#Ref<0.0.999>',
      'suite' => 'fixture_SUITE', 'testcase' => 'lost', 'groups' => [], 'log' => 'lost.html', 'worker' => '<0.1.0>') + "\n")
    File.write(@events, lines.join)
    result = report
    refute result.fetch('complete')
    assert_equal 'incomplete', result.fetch('cases').find { |record| record.fetch('testcase') == 'lost' }.fetch('status')
  end

  def test_attribute_entities_are_decoded_and_invalid_references_fail
    cases = Erx::OracleResults.parse_xml(xml(testcase('one&amp;two'), tests: 1))
    assert_equal 'one&two', cases.first.fetch('testcase')
    ['&#0;', '&#x110000;', '&not_declared;'].each do |reference|
      bytes = xml(testcase('bad', body: "<failure>#{reference}</failure>"), tests: 1, failures: 1)
      assert_raises(Erx::Error) { Erx::OracleResults.parse_xml(bytes) }
    end
  end

  def test_duplicate_or_unknown_event_fields_are_refused
    File.write(@xml, xml(testcase('ok'), tests: 1))
    evidence
    lines = File.readlines(@events)
    lines[0] = "{\"event\":\"test_start\",\"event\":\"test_start\"}\n"
    File.write(@events, lines.join)
    assert_raises(Erx::Error) { report }
    evidence
    records = File.readlines(@events).map { |line| JSON.parse(line) }
    records.first['unknown'] = 'field'
    File.write(@events, records.map { |record| JSON.generate(record) + "\n" }.join)
    assert_raises(Erx::Error) { report }
  end

  def test_utf8_projection_remains_valid_for_the_json_report
    name = "caf\u00e9"
    cases = Erx::OracleResults.parse_xml(xml(testcase(name), tests: 1))
    assert_equal name, cases.first.fetch('testcase')
    assert JSON.generate(cases).valid_encoding?
  end

  def test_framework_supplied_configuration_callbacks_use_the_suite_projection
    body = testcase('init_per_suite') + testcase('ok') + testcase('end_per_suite')
    File.write(@xml, xml(body, tests: 1))
    evidence(case_names: %w[init_per_suite ok end_per_suite])
    records = File.readlines(@events).map { |line| JSON.parse(line) }
    records.each do |event|
      if %w[init_per_suite end_per_suite].include?(event['testcase']) && event['event'].start_with?('tc_')
        event['suite'] = 'ct_framework'
        event['result'] = 'passed' if event.key?('result')
      end
      event['status'] = 'passed' if event['event'] == 'case_finish'
    end
    File.write(@events, records.map { |record| JSON.generate(record) + "\n" }.join)
    result = report
    assert result.fetch('complete')
    assert_equal 'completed', result.fetch('state')
    assert_equal 'fixture_SUITE', result.fetch('cases').first.fetch('suite')
  end

  def test_event_string_fields_require_valid_utf8_before_schema_use
    File.write(@xml, xml(testcase('ok'), tests: 1))
    evidence
    bytes = File.binread(@events).gsub('fixture_SUITE'.b, "fixture_\xff".b)
    File.binwrite(@events, bytes)
    assert_raises(Erx::Error) { report }
  end
end
