# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'zlib'

require_relative 'error'
require_relative 'oracle_results'

module Erx
  # The verdict of the hosted oracle (design-tmp.md, Verification, "OTP's
  # suites"): the same suites under Common Test on erXos and on stock OTP,
  # compared case by case. Agreement with stock is the criterion, so the
  # comparison passes only when every case agrees or differs exactly as a
  # row of the checked-in table of known differences says, and both runs
  # finished. Everything here is pure: the runs, their files and the report's
  # printing belong to OracleHosted.
  module OracleComparison
    # Common Test's own results. A known difference expects one of them; a
    # case without one is reported by what happened to it instead.
    STATUSES = OracleResults::STATES
    # What happened to a case that has no Common Test result on a side: the
    # run hit its deadline or ended while the case ran, or the side's events
    # never mention it.
    UNRESOLVED_STATUSES = %w[timed_out crashed unknown].freeze
    # Every verdict, in the order the report lists them; only the last two pass.
    VERDICTS = %w[differs changed stale unresolved known same].freeze
    PASSING_VERDICTS = %w[known same].freeze

    # One row of the table: the case it names, the status erXos shows for it
    # and why that differs from stock. `group` is the group path, outermost
    # first, empty for a case outside every group.
    KnownDifference = Data.define(:suite, :group, :testcase, :status, :reason)
    # Which execution of which case: Common Test counts each case's runs
    # in its suite and group path from 1.
    CaseKey = Data.define(:suite, :group, :testcase, :attempt) do
      # The case whatever the attempt, as a table row names it.
      def identity = [suite, group, testcase]
    end
    # One run: `state` is complete, timed_out, crashed, incomplete (with the count of
    # damaged event lines skipped, when there were any) or
    # "unreadable: why"; `cases` maps each CaseKey to a status of STATUSES
    # or UNRESOLVED_STATUSES.
    Side = Data.define(:state, :cases)
    # One case's two statuses and its verdict. `attempt` is nil only for a
    # table row that names no case either run reached.
    Row = Data.define(:suite, :group, :testcase, :attempt, :stock, :erxos, :verdict, :reason) do
      # Names come from the runs' events, so each is escaped: none can
    # carry a newline into the report and forge a line of it.
    def name = [suite, *(group.join('/') unless group.empty?), testcase].map { |part| Terminal.escape(part) }.join(' ')
    end

    Result = Data.define(:stock, :erxos, :rows) do
      def passed? = stock.state == 'complete' && erxos.state == 'complete' && failing.empty?

      def failing = rows.reject { |row| PASSING_VERDICTS.include?(row.verdict) }

      # Every row that is not plain agreement, grouped by verdict, then the
      # counts and the result. Unknown, timed-out and crashed cases keep
      # those names; none is folded into a pass or a failure.
      def report
        listed = rows.reject { |row| row.verdict == 'same' }
                     .sort_by.with_index { |row, index| [VERDICTS.index(row.verdict), index] }
                     .map { |row| "#{row.verdict.ljust(10)} #{OracleComparison.describe(row)}" }
        counts = VERDICTS.map { |verdict| "#{verdict} #{rows.count { |row| row.verdict == verdict }}" }
        summary = passed? ? 'PASS' : "FAIL (#{failing.size} cases, stock run #{stock.state}, erXos run #{erxos.state})"
        [*listed, "stock run: #{stock.state}", "erXos run: #{erxos.state}", counts.join(', '),
         "result: #{summary}"].join("\n") << "\n"
      end
    end

    # A row of the table: suite, group path or `-`, case, erXos's status and
    # the reason, which is the rest of the line. Names are plain atoms, so a
    # row names one case and no pattern can stand for several.
    NAME = '[a-z][A-Za-z0-9_]*'
    ROW = %r{\A(?<suite>#{NAME}_SUITE)\s+(?<group>-|#{NAME}(?:/#{NAME})*)\s+(?<testcase>#{NAME})\s+
             (?<status>\S+)\s+(?<reason>\S.*)\z}x

    # The line prefix of an event in output that carries other text too; the
    # reporter's twin is the prefix in test/oracle/erx_oracle_events.erl.
    EVENT_PREFIX = 'erx-oracle-event '
    # An event line: the prefix, the JSON's length in bytes, its CRC-32 as
    # eight lower-case hex digits, then the JSON, closed by "\n" or "\r\n".
    EVENT_LINE = /\A#{EVENT_PREFIX}(?<length>\d+) (?<crc>\h{8}) (?<json>.*?)\r?\n\z/m
    # The events found in a run's output, as one JSON line each, and how
    # many lines claimed to be events but failed their length or checksum.
    PrintedEvents = Data.define(:events, :skipped)

    module_function

    # The events in `output`, a run's captured standard output. Other text is
    # ignored, and so is a last line the run was cut off in, which no
    # newline closes. A closed line that starts with EVENT_PREFIX and fails
    # its frame is counted in `skipped`, never read.
    def printed_events(output)
      framed = output.b.lines.select { |line| line.start_with?(EVENT_PREFIX) && line.end_with?("\n") }
      records = framed.map { |line| event_json(line) }
      PrintedEvents.new(events: records.compact.map { |json| "#{json}\n" }.join, skipped: records.count(nil))
    end

    # The JSON of one framed line, or nil when its length or checksum is wrong.
    def event_json(line)
      frame = EVENT_LINE.match(line)
      return unless frame
      return unless frame[:json].bytesize == Integer(frame[:length], 10)
      return unless Zlib.crc32(frame[:json]) == Integer(frame[:crc], 16)

      frame[:json]
    end
    private_class_method :event_json

    # The table, from `text`; `source` names it in diagnostics. Blank lines
    # and lines starting with `#` are comments.
    def known_differences(text:, source:)
      rows = text.each_line.with_index(1).filter_map do |line, number|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?('#')

        known_difference(stripped, where: "#{source}:#{number}")
      end
      duplicate = rows.group_by { |row| [row.suite, row.group, row.testcase] }.find { |_, same| same.size > 1 }
      raise Error, "#{source}: #{duplicate.first.flatten.join(' ')} is listed twice" if duplicate

      rows
    end

    def known_difference(line, where:)
      match = ROW.match(line) or
        raise Error, "#{where}: a row is a suite, a group path or -, a case, erXos's status and a reason"
      unless STATUSES.include?(match[:status])
        raise Error, "#{where}: status #{match[:status]} is not one of #{STATUSES.join(', ')}"
      end

      KnownDifference.new(suite: match[:suite], group: match[:group] == '-' ? [] : match[:group].split('/'),
                          testcase: match[:testcase], status: match[:status], reason: match[:reason])
    end
    private_class_method :known_difference

    # One run, from the event stream erx_oracle_events wrote and the state
    # of the command that ran it (succeeded, failed or timed_out). A stream
    # that cannot be read yields no cases, so every case is unknown there.
    def side(events:, command_state:, skipped: 0)
      report = OracleResults.read(xml: nil, events: events, command: { 'state' => command_state })
      cut_off = cut_off_status(command_state: command_state, skipped: skipped)
      cases = report.fetch('cases').to_h do |record|
        status = record.fetch('status')
        [CaseKey.new(suite: record.fetch('suite'), group: record.fetch('group'), testcase: record.fetch('testcase'),
                     attempt: record.fetch('attempt')),
         status == 'incomplete' ? cut_off : status]
      end
      Side.new(state: run_state(complete: report.fetch('complete'), command_state: command_state, skipped: skipped),
                cases: cases)
    rescue Error => error
      Side.new(state: "unreadable: #{error.message}", cases: {})
    end

    # What an open case shows: the deadline or the crash that cut it off, or,
    # when a run that ended well lost event lines, that its result is unknown.
    def cut_off_status(command_state:, skipped:)
      return 'timed_out' if command_state == 'timed_out'
      return 'unknown' if command_state == 'succeeded' && skipped.positive?

      'crashed'
    end
    private_class_method :cut_off_status

    def run_state(complete:, command_state:, skipped:)
      return 'timed_out' if command_state == 'timed_out'
      return 'crashed' unless command_state == 'succeeded'
      return "incomplete: #{skipped} damaged event lines skipped" if skipped.positive?

      complete ? 'complete' : 'incomplete'
    end
    private_class_method :run_state

    # Every case either run reached, in stock's order and then erXos's, and
    # every table row of a suite that ran but naming no case either reached.
    def compare(stock:, erxos:, known:)
      table = known.to_h { |row| [[row.suite, row.group, row.testcase], row] }
      keys = stock.cases.keys | erxos.cases.keys
      rows = keys.map do |key|
        row(key, stock: stock.cases.fetch(key, 'unknown'), erxos: erxos.cases.fetch(key, 'unknown'),
                 listed: table[key.identity])
      end
      finished = stock.state == 'complete' && erxos.state == 'complete'
      Result.new(stock: stock, erxos: erxos, rows: rows + unreached_rows(known, keys: keys, finished: finished))
    end

    # The rows of the table for a suite that ran that name no case either
    # run reached. When both runs finished, the row is stale; otherwise a
    # run may have stopped before the case, so nothing is known of it.
    def unreached_rows(known, keys:, finished:)
      reached = keys.to_set(&:identity)
      suites = keys.to_set(&:suite)
      unreached = known.select { |row| suites.include?(row.suite) && !reached.include?([row.suite, row.group, row.testcase]) }
      unreached.map do |row|
        reason = if finished
                   'the table names a case neither run reached: correct or delete the row'
                 else
                   'neither run reached the case the table names'
                 end
        Row.new(suite: row.suite, group: row.group, testcase: row.testcase, attempt: nil,
                stock: 'unknown', erxos: 'unknown', verdict: finished ? 'stale' : 'unresolved', reason: reason)
      end
    end
    private_class_method :unreached_rows

    def row(key, stock:, erxos:, listed:)
      suite, group, testcase, attempt = key.deconstruct
      verdict = verdict(stock: stock, erxos: erxos, listed: listed)
      reason = case verdict
               when 'differs' then 'not in the table'
               when 'stale' then "listed as #{listed.status}, but erXos agrees with stock: delete the row"
               when 'changed' then "listed as #{listed.status}: #{listed.reason}"
               else listed&.reason
               end
      Row.new(suite: suite, group: group, testcase: testcase, attempt: attempt, stock: stock, erxos: erxos,
              verdict: verdict, reason: reason)
    end
    private_class_method :row

    def verdict(stock:, erxos:, listed:)
      return 'unresolved' unless STATUSES.include?(stock) && STATUSES.include?(erxos)
      return(stock == erxos ? 'same' : 'differs') unless listed
      return 'stale' if stock == erxos

      erxos == listed.status ? 'known' : 'changed'
    end
    private_class_method :verdict

    # One row of the report, without its verdict.
    def describe(row)
      attempt = row.attempt ? " ##{row.attempt}" : ''
      ["#{row.name}#{attempt}: stock #{row.stock}, erXos #{row.erxos}", row.reason].compact.join(', ')
    end
  end
end
