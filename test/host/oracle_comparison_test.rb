# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require 'zlib'
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

  # An event as the reporter prints it: a newline, the prefix, the sequence
  # number, the JSON's length, the CRC-32 of those and the JSON, the JSON and
  # a closing newline.
  def frame(json, sequence, eol: "\n")
    format("\nerx-oracle-event %<sequence>d %<length>d %<crc>08x %<json>s%<eol>s",
           sequence: sequence, length: json.bytesize, crc: Zlib.crc32("#{sequence} #{json.bytesize} #{json}"),
           json: json, eol: eol)
  end

  def frames(jsons) = jsons.each_with_index.map { |json, sequence| frame(json, sequence) }

  def streamed_side(output, command)
    printed = Erx::OracleComparison.printed_events(output)
    path = File.join(@directory, 'streamed.jsonl')
    File.binwrite(path, printed.events)
    [Erx::OracleComparison.side(events: path, command_state: command, skipped: printed.skipped), printed]
  end

  def erxos_statuses(erxos)
    result = Erx::OracleComparison.compare(stock: side('stock', STOCK), erxos: erxos, known: known)
    result.rows.to_h { |row| [row.testcase, row.erxos] }
  end

  def records(statuses) = events(statuses).map { |record| JSON.generate(record) }

  def finish_of_same(lines) = lines.index { |json| json.include?('"case_finish"') && json.include?('"number":1,') }

  # The streamed output of an erXos run killed mid-case: the events of the
  # finished cases, a suite's own prints around them, and a last event the
  # kill cut off in the middle.
  def test_streamed_events_of_a_run_cut_off_mid_case_keep_every_finished_result
    output = ["boot line\n", "a suite's print, unterminated", *frames(records(ERXOS.merge('hung' => nil))),
              "\nerx-oracle-event 99 12 00000000 {\"event\":\"tc_do"].join
    erxos, printed = streamed_side(output, 'timed_out')
    assert_equal 0, printed.skipped
    assert_equal({ 'same' => 'passed', 'listed' => 'failed', 'unlisted' => 'failed', 'stale' => 'passed',
                   'changed' => 'user_skip', 'hung' => 'timed_out' }, erxos_statuses(erxos))
    assert_equal 'timed_out', erxos.state
  end

  # A kernel line written into the middle of an event damages that one line.
  def test_a_damaged_event_line_is_skipped_and_counted_not_fatal
    lines = records(ERXOS)
    index = finish_of_same(lines)
    output = frames(lines).each_with_index.map do |line, at|
      at == index ? line.sub('"event"', "\"ev[kernel: panic]ent\"") : line
    end.join
    erxos, printed = streamed_side(output, 'succeeded')
    assert_equal 1, printed.skipped
    assert_equal 'incomplete: 1 event lines damaged or lost', erxos.state
    statuses = erxos_statuses(erxos)
    assert_equal 'unknown', statuses.fetch('same')
    assert_equal 'passed', statuses.fetch('hung')
  end

  # A C writer's partial line, closed by no newline, joins the event after it:
  # the event is still found and read.
  def test_an_event_after_junk_on_its_line_is_read
    lines = records(ERXOS)
    output = frames(lines).map { |line| "erx: root task: partial#{line.delete_prefix("\n")}" }.join
    erxos, printed = streamed_side(output, 'succeeded')
    assert_equal 0, printed.skipped
    assert_equal 'complete', erxos.state
    assert_equal ERXOS, erxos_statuses(erxos)
  end

  # Junk that holds a damaged frame before a whole one on the same line: the
  # whole frame is read, and the damaged one shows as a gap.
  def test_a_damaged_frame_before_a_whole_one_shows_as_a_gap
    lines = records(ERXOS)
    index = finish_of_same(lines)
    output = frames(lines).each_with_index.map do |line, at|
      next '' if at == index
      next "#{frame(lines[index], index).chomp[0, 40]}#{line.delete_prefix("\n")}" if at == index + 1

      line
    end.join
    erxos, printed = streamed_side(output, 'succeeded')
    assert_equal 1, printed.skipped
    assert_equal 'unknown', erxos_statuses(erxos).fetch('same')
  end

  # A line a writer cut away entirely leaves no damaged line, only a gap in
  # the sequence numbers.
  def test_a_lost_event_line_is_counted_by_its_sequence_gap
    lines = records(ERXOS)
    index = finish_of_same(lines)
    output = frames(lines).each_with_index.reject { |_, at| at == index }.map(&:first).join
    erxos, printed = streamed_side(output, 'succeeded')
    assert_equal 1, printed.skipped
    assert_equal 'incomplete: 1 event lines damaged or lost', erxos.state
    assert_equal 'unknown', erxos_statuses(erxos).fetch('same')
  end

# What another thread wrote to the console while an event's write was half
# done, as a stdlib run's serial log shows: the end of a crash report's line
# and the next line of it.
OTHER_WRITER = "185\r\n      stack_size: 42\r\n"

# The frames of `records` with the one at `index` torn by OTHER_WRITER: its
# last three bytes, the JSON's closing "]}" or "}}" and the newline, come
# after the other writer's bytes, so the frame's own line is short.
def torn(records, index)
  frames(records).each_with_index.map do |line, at|
    at == index ? "#{line[0..-4]}#{OTHER_WRITER}#{line[-3..]}" : line
  end.join
end

# A start whose frame another writer tore: the run lost an event and is
# incomplete, but every case it can still name is read. A lost case start
# leaves its case unknown; a lost Common Test event leaves every case.
def test_a_torn_start_leaves_its_case_unknown_and_the_run_readable
  expected = { 'case_start' => 'unknown', 'tc_start' => 'passed', 'test_start' => 'passed' }
  expected.each do |kind, same|
    lines = records(ERXOS)
    erxos, printed = streamed_side(torn(lines, lines.index { |json| json.include?(%("event":"#{kind}")) }), 'succeeded')
    assert_equal [1, 'incomplete: 1 event lines damaged or lost'], [printed.skipped, erxos.state], kind
    assert_equal ERXOS.merge('same' => same), erxos_statuses(erxos), kind
  end
end

# A finish with no start in a stream that lost no line is a stream that
# does not hold together, not a lost event.
def test_a_finish_without_its_start_in_a_whole_stream_is_unreadable
  lines = records(ERXOS).reject { |json| json.include?('"case_start"') && json.include?('"testcase":"same"') }
  erxos, printed = streamed_side(frames(lines).join, 'succeeded')
  assert_equal 0, printed.skipped
  assert_equal 'unreadable: controller case finished without its start', erxos.state
end

# Stock runs "same" twice and passes both; erXos fails its first run, whose
# start is lost, and passes its second, which the stream then numbers as the
# first. Neither run is claimed, so no row agrees or differs on a run erXos's
# stream cannot place.
def test_a_lost_start_claims_no_run_of_a_repeated_case
  twice = lambda do |status|
    lines = records(STOCK)
    run = lines.select { |json| json.include?('"testcase":"same"') || json.include?('"id":"#Ref<0.0.0>"') }
    again = run.map { |json| json.sub('#Ref<0.0.0>', '#Ref<0.0.99>') }
    run.each { |json| lines[lines.index(json)] = json.sub('"passed"', %("#{status}")) }
    lines.insert(lines.index { |json| json.include?('"test_stats"') }, *again)
    [lines, lines.index { |json| json.include?('"case_start"') && json.include?('"testcase":"same"') }]
  end
  stock_lines, = twice.call('passed')
  stock_path = File.join(@directory, 'stock.jsonl')
  File.write(stock_path, stock_lines.map { |json| "#{json}\n" }.join)
  stock = Erx::OracleComparison.side(events: stock_path, command_state: 'succeeded')
  lines, index = twice.call('failed')
  erxos, = streamed_side(torn(lines, index), 'succeeded')
  rows = Erx::OracleComparison.compare(stock: stock, erxos: erxos, known: []).rows
  same = rows.select { |row| row.testcase == 'same' }
  assert_equal [[1, 'passed', 'unknown'], [2, 'passed', 'unknown']], same.map { |row| [row.attempt, row.stock, row.erxos] }
  assert_equal 'same', rows.find { |row| row.testcase == 'stale' }.verdict
end

  def test_a_serial_consoles_crlf_line_ends_are_accepted
    output = frames(records(ERXOS)).map { |line| line.gsub("\n", "\r\n") }.join
    erxos, printed = streamed_side(output, 'succeeded')
    assert_equal 0, printed.skipped
    assert_equal 'complete', erxos.state
    assert_equal ERXOS, erxos_statuses(erxos)
  end

  def test_only_whole_checked_lines_are_events
    first = frame('{"a":1}', 0).lstrip
    output = [first, "not #{first}", "erx-oracle-log x\n", "erx-oracle-event 1 7 00000000 {\"c\":3}\n",
              frame('{"b":2}', 2).lstrip.chomp].join
    printed = Erx::OracleComparison.printed_events(output)
    assert_equal "{\"a\":1}\n", printed.events
    assert_equal 2, printed.skipped
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

  def test_the_checked_in_tables_parse
    paths = Dir.glob(File.expand_path('../oracle/hosted_known_differences/*.txt', __dir__))
    assert_equal %w[compiler emulator kernel stdlib], paths.map { |path| File.basename(path, '.txt') }.sort
    paths.each { |path| Erx::OracleComparison.known_differences(text: File.read(path), source: path) }
  end

  def test_the_report_names_each_sides_wall_clock_time_or_that_it_is_unknown
    stock = Erx::OracleComparison::Side.new(state: 'complete', cases: {}, seconds: 41.4)
    erxos = Erx::OracleComparison::Side.new(state: 'complete', cases: {})
    report = Erx::OracleComparison.compare(stock: stock, erxos: erxos, known: [], runtime: 'hosted').report
    assert_includes report.lines, "stock: 41 s, erXos (hosted): unknown\n"
  end

  def test_a_wildcard_row_claims_every_differing_case_it_covers
    table = Erx::OracleComparison.known_differences(text: "fixture_SUITE * * failed one cause\n", source: 'x')
    rows = Erx::OracleComparison.compare(stock: side('stock', STOCK), erxos: side('erxos', ERXOS), known: table)
                                .rows.to_h { |row| [row.testcase, row.verdict] }
    assert_equal({ 'same' => 'same', 'listed' => 'known', 'unlisted' => 'known', 'stale' => 'same',
                   'changed' => 'changed', 'hung' => 'same' }, rows)
  end

  def test_the_row_naming_a_case_wins_over_a_wildcard
    table = Erx::OracleComparison.known_differences(text: "fixture_SUITE - * user_skip all\n" \
                                                          "fixture_SUITE - unlisted failed this one\n", source: 'x')
    rows = Erx::OracleComparison.compare(stock: side('stock', STOCK), erxos: side('erxos', ERXOS), known: table)
                                .rows.to_h { |row| [row.testcase, row.verdict] }
    assert_equal %w[changed known known], rows.values_at('listed', 'unlisted', 'changed')
  end

  def test_a_wildcard_row_under_which_nothing_differs_is_stale
    table = Erx::OracleComparison.known_differences(text: "fixture_SUITE other * failed gone\n", source: 'x')
    result = Erx::OracleComparison.compare(stock: side('stock', STOCK), erxos: side('erxos', STOCK), known: table)
    assert_equal [['stale', %w[other], '*']], result.rows.reject { |row| row.verdict == 'same' }
                                                        .map { |row| [row.verdict, row.group, row.testcase] }
  end

  GROUP_STOCK = { 'g/init_per_group' => 'passed', 'g/a' => 'passed', 'g/b' => 'passed', 'g/end_per_group' => 'passed' }.freeze

  # A suite skipped whole on erXos runs none of its group functions, so its events hold only the
  # cases, auto-skipped; stock ran the functions.
  def test_a_group_function_of_a_group_erxos_skipped_whole_shows_as_skipped
    erxos = side('erxos', { 'g/a' => 'auto_skip', 'g/b' => 'auto_skip' })
    result = Erx::OracleComparison.compare(stock: side('stock', GROUP_STOCK), erxos: erxos, known: [])
    rows = result.rows.to_h { |row| [row.testcase, [row.stock, row.erxos, row.verdict]] }
    assert_equal %w[passed auto_skip differs], rows.fetch('init_per_group')
    assert_equal %w[passed auto_skip differs], rows.fetch('end_per_group')
    table = Erx::OracleComparison.known_differences(text: "fixture_SUITE g * auto_skip skipped whole\n", source: 'x')
    result = Erx::OracleComparison.compare(stock: side('stock', GROUP_STOCK), erxos: erxos, known: table)
    assert result.passed?, result.report
  end

  # Nothing is made up: a function stays unknown when erXos shows no skipped case under its group,
  # or a case that ran there.
  def test_a_group_function_erxos_never_showed_stays_unknown_unless_its_cases_all_skipped
    ran = side('erxos', { 'g/a' => 'auto_skip', 'g/b' => 'passed' })
    other = side('erxos', { 'h/a' => 'auto_skip' })
    [ran, other].each do |erxos|
      result = Erx::OracleComparison.compare(stock: side('stock', GROUP_STOCK), erxos: erxos, known: [])
      row = result.rows.find { |candidate| candidate.testcase == 'init_per_group' }
      assert_equal %w[unknown unresolved], [row.erxos, row.verdict]
    end
  end

  # A side that was cut off, or lost events, shows nothing by a missing record.
  def test_no_group_function_is_inferred_on_a_side_that_did_not_finish
    erxos = side('erxos', { 'g/a' => 'auto_skip' }, command: 'timed_out')
    result = Erx::OracleComparison.compare(stock: side('stock', GROUP_STOCK), erxos: erxos, known: [])
    row = result.rows.find { |candidate| candidate.testcase == 'init_per_group' }
    assert_equal %w[unknown unresolved], [row.erxos, row.verdict]
  end

  # Stock's third pass through a group is a pass erXos, which ran it twice, never reached.
  def test_no_group_function_is_inferred_for_a_pass_erxos_did_not_run
    key = ->(testcase, attempt) { Erx::OracleComparison::CaseKey.new(suite: 's_SUITE', group: %w[g], testcase: testcase, attempt: attempt) }
    stock = Erx::OracleComparison::Side.new(state: 'complete', cases: { key.('init_per_group', 3) => 'passed' })
    erxos = Erx::OracleComparison::Side.new(state: 'complete', cases: { key.('a', 1) => 'auto_skip', key.('a', 2) => 'auto_skip' })
    row = Erx::OracleComparison.compare(stock: stock, erxos: erxos, known: []).rows.find { |r| r.testcase == 'init_per_group' }
    assert_equal 'unknown', row.erxos
  end

  def test_a_nested_group_function_takes_the_skip_of_the_cases_below_it
    stock = side('stock', { 'o/i/init_per_group' => 'passed', 'o/i/a' => 'passed' })
    erxos = side('erxos', { 'o/i/a' => 'user_skip' })
    row = Erx::OracleComparison.compare(stock: stock, erxos: erxos, known: [])
                                .rows.find { |candidate| candidate.testcase == 'init_per_group' }
    assert_equal 'auto_skip', row.erxos
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
  # and never finishes, and the run then never reaches its end. A case named
  # "group/case" runs under that group, "outer/inner/case" under a nested one.
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
    statuses.each_with_index do |(path, status), index|
      *groups, testcase = path.split('/')
      identity = { 'suite' => 'fixture_SUITE', 'testcase' => testcase, 'group' => groups.last }
      config = Erx::OracleResults::CONFIG_CASES.include?(testcase)
      token = "#Ref<0.0.#{index}>"
      records << { 'event' => 'case_start', 'id' => token, 'suite' => 'fixture_SUITE', 'worker' => '<0.1.0>',
                   'testcase' => testcase, 'log' => "#{testcase}.html",
                   'groups' => groups.each_index.map { |depth| { 'id' => "#Ref<8.0.#{depth}>", 'name' => groups[depth] } } }
      records << identity.merge('event' => 'tc_start')
      return records if status.nil?

      result = status.end_with?('skip') ? 'skipped' : status
      records << identity.merge('event' => 'tc_done', 'result' => result, 'detail' => result)
      records << { 'event' => 'case_finish', 'id' => token, 'status' => status, 'number' => config ? 0 : index + 1,
                   'detail' => result }
    end
    # Common Test counts the cases, not the group functions around them.
    cases = statuses.reject { |path, _| Erx::OracleResults::CONFIG_CASES.include?(path.split('/').last) }
    counts = Erx::OracleResults::STATES.to_h { |state| [state, cases.values.count(state)] }
    records << { 'event' => 'test_stats', **counts }
    records.push({ 'event' => 'job_traversed', 'worker' => '<0.1.0>' },
                 { 'event' => 'job_exit', 'id' => '#Ref<9.0.1>', 'worker' => '<0.1.0>', 'normal' => true },
                 { 'event' => 'selection_close', 'id' => '#Ref<9.0.0>', 'normal' => true },
                 { 'event' => 'test_done' })
  end
end
