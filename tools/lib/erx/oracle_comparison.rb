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
    # Common Test's skip results, and the group configuration functions: a side
    # that skipped a group's cases whole never ran its functions.
    SKIPPED_STATUSES = %w[user_skip auto_skip].freeze
    GROUP_CONFIG = %w[init_per_group end_per_group].freeze

    # One row of the table: the cases it names, the status erXos shows for
    # them and why that differs from stock. `group` is the group path,
    # outermost first, empty for a case outside every group, or ANY for every
    # path; `testcase` is a case's name or ANY for every case.
    KnownDifference = Data.define(:suite, :group, :testcase, :status, :reason) do
      def exact? = group != ANY && testcase != ANY

      def covers?(key)
        key.suite == suite && [ANY, key.group].include?(group) && [ANY, key.testcase].include?(testcase)
      end

      # Of the rows that cover a case, the one with a named case wins over
      # one with a named group, which wins over a row naming neither.
      def specificity = [testcase == ANY ? 0 : 2, group == ANY ? 0 : 1].sum
    end
    ANY = '*'
    # Which execution of which case: Common Test counts each case's runs
    # in its suite and group path from 1.
    CaseKey = Data.define(:suite, :group, :testcase, :attempt) do
      # The case whatever the attempt, as a table row names it.
      def identity = [suite, group, testcase]
    end
    # One run: `state` is complete, timed_out, crashed, incomplete (with the count of
    # damaged event lines skipped, when there were any), "unreadable: why", or a state
    # of the host that never ran the guest (qemu_failed: why, host_failed: why); `cases`
    # maps each CaseKey to a status of STATUSES or UNRESOLVED_STATUSES; `seconds` is the
    # run's wall-clock time, nil when no record of it exists; `lost` is how many of its
    # event lines were damaged or missing.
    Side = Data.define(:state, :cases, :seconds, :lost) do
      def initialize(state:, cases:, seconds: nil, lost: 0) = super
    end
    # One case's two statuses and its verdict. `attempt` is nil only for a
    # table row that names no case either run reached.
    Row = Data.define(:suite, :group, :testcase, :attempt, :stock, :erxos, :verdict, :reason) do
      # Names come from the runs' events, so each is escaped: none can
    # carry a newline into the report and forge a line of it.
    def name = [suite, *(group.join('/') unless group.empty?), testcase].map { |part| Terminal.escape(part) }.join(' ')
    end

    # `runtime` names the erXos side in the report, such as hosted or QEMU tcg.
    Result = Data.define(:stock, :erxos, :rows, :runtime) do
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
        times = "stock: #{OracleComparison.seconds(stock)}, erXos#{" (#{runtime})" if runtime}: #{OracleComparison.seconds(erxos)}"
        [*listed, "stock run: #{stock.state}", "erXos run: #{erxos.state}", times, counts.join(', '),
         "result: #{summary}"].join("\n") << "\n"
      end
    end

    # A row of the table: suite, group path, `-` or `*`, case or `*`, erXos's
    # status and the reason, which is the rest of the line. Names are plain
    # atoms; `*` alone is the only pattern, standing for every group path
    # (none included) or every case.
    NAME = '[a-z][A-Za-z0-9_]*'
    ROW = %r{\A(?<suite>#{NAME}_SUITE)\s+(?<group>-|\*|#{NAME}(?:/#{NAME})*)\s+(?<testcase>\*|#{NAME})\s+
             (?<status>\S+)\s+(?<reason>\S.*)\z}x

    # The line prefix of an event in output that carries other text too; the
    # reporter's twin is the prefix in test/oracle/erx_oracle_events.erl.
    EVENT_PREFIX = 'erx-oracle-event '
    # An event frame: the prefix, the event's sequence number from 0, the
    # JSON's length in bytes, the CRC-32 of the sequence number, length and
    # JSON as printed, as eight lower-case hex digits, then the JSON, closed
    # by "\n" or "\r\n". Other text may come before the prefix on its line.
    EVENT_FRAME = /\A#{EVENT_PREFIX}(?<sequence>\d+) (?<length>\d+) (?<crc>\h{8}) (?<json>.*?)\r?\n\z/m
    # The events found in a run's output, as one JSON line each, and how
    # many it lost: the larger of the lines that held the prefix but no
    # whole frame (or repeated a sequence number) and the sequence numbers
    # missing below the last one read. Either alone can miss a loss: a
    # damaged last event leaves no gap, and a line a writer cut away leaves
    # no damaged line.
    PrintedEvents = Data.define(:events, :skipped)

    module_function

    # The events in `output`, a run's captured standard output. Other text is
    # ignored, and so is a last line the run was cut off in, which no
    # newline closes. A closed line that holds EVENT_PREFIX anywhere but no
    # whole frame is counted in `skipped`, never read.
    def printed_events(output)
      framed = output.b.lines.select { |line| line.end_with?("\n") && line.include?(EVENT_PREFIX) }
      frames = framed.map { |line| event_frame(line) }
      read = frames.compact.uniq(&:first)
      damaged = frames.size - read.size
      missing = read.empty? ? 0 : read.map(&:first).max + 1 - read.size
      PrintedEvents.new(events: read.map { |_, json| "#{json}\n" }.join, skipped: [damaged, missing].max)
    end

    # The sequence number and JSON of the frame in one line, or nil when no
    # occurrence of the prefix in it starts a frame whose length and
    # checksum hold. A C writer can put any bytes before the prefix, and
    # those bytes may hold a damaged frame of their own, so each occurrence
    # is tried.
    def event_frame(line)
      starts = Enumerator.produce(line.index(EVENT_PREFIX)) { |at| line.index(EVENT_PREFIX, at + 1) }.take_while(&:itself)
      starts.lazy.filter_map { |at| checked_frame(line.byteslice(at..)) }.first
    end
    private_class_method :event_frame

    def checked_frame(text)
      frame = EVENT_FRAME.match(text)
      return unless frame
      return unless frame[:json].bytesize == Integer(frame[:length], 10)
      return unless Zlib.crc32("#{frame[:sequence]} #{frame[:length]} #{frame[:json]}") == Integer(frame[:crc], 16)

      [Integer(frame[:sequence], 10), frame[:json]]
    end
    private_class_method :checked_frame

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

      group = case match[:group]
              when '-' then []
              when ANY then ANY
              else match[:group].split('/')
              end
      KnownDifference.new(suite: match[:suite], group: group, testcase: match[:testcase], status: match[:status],
                          reason: match[:reason])
    end
    private_class_method :known_difference

    # What ended a run: its command finished (succeeded), the run itself
    # crashed (failed) or hit its deadline (timed_out). Any other state is the
    # host's own failure around the run (OracleQemu.state_of names them),
    # which says nothing of the system under test.
    RUN_STATES = %w[succeeded failed timed_out].freeze

    # One run, from the event stream erx_oracle_events wrote and the state
    # of the command that ran it, with `detail`, the host's message for a
    # state outside RUN_STATES, and `seconds`, the run's wall-clock time. A
    # stream that cannot be read yields no cases, so every case is unknown
    # there.
    def side(events:, command_state:, detail: nil, skipped: 0, seconds: nil)
      report = OracleResults.read(xml: nil, events: events, command: { 'state' => command_state }, lost: skipped)
      cut_off = cut_off_status(command_state: command_state, skipped: skipped)
      cases = report.fetch('cases').to_h do |record|
        status = record.fetch('status')
        [CaseKey.new(suite: record.fetch('suite'), group: record.fetch('group'), testcase: record.fetch('testcase'),
                     attempt: record.fetch('attempt')),
         status == 'incomplete' ? cut_off : status]
      end
      Side.new(state: run_state(complete: report.fetch('complete'), command_state: command_state, detail: detail,
                                skipped: skipped),
                cases: cases, seconds: seconds, lost: skipped)
    rescue Error => error
      Side.new(state: "unreadable: #{error.message}", cases: {}, seconds: seconds)
    end

    # What an open case shows: the deadline or the crash that cut it off, or
    # that its result is unknown, when a run that ended well lost event lines
    # or the host failed around the run.
    def cut_off_status(command_state:, skipped:)
      return 'timed_out' if command_state == 'timed_out'
      return 'crashed' if command_state == 'failed'

      'unknown'
    end
    private_class_method :cut_off_status

    def run_state(complete:, command_state:, detail:, skipped:)
      return [command_state, detail].compact.join(': ') unless RUN_STATES.include?(command_state)
      return 'timed_out' if command_state == 'timed_out'
      return 'crashed' if command_state == 'failed'
      return "incomplete: #{skipped} event lines damaged or lost" if skipped.positive?

      complete ? 'complete' : 'incomplete'
    end
    private_class_method :run_state

    # Every case either run reached, in stock's order and then erXos's, and
    # every table row of a suite that ran that accounts for no difference.
    def compare(stock:, erxos:, known:, runtime: nil)
      keys = stock.cases.keys | erxos.cases.keys
      repeated = keys.select { |key| key.attempt > 1 }.map(&:identity).uniq
      listed = keys.to_h { |key| [key, known.select { |row| row.covers?(key) }.max_by(&:specificity)] }
      rows = keys.map do |key|
        row(key, stock: status_of(stock, key, repeated: repeated), erxos: status_of(erxos, key, repeated: repeated),
                 listed: listed.fetch(key))
      end
      finished = stock.state == 'complete' && erxos.state == 'complete'
      used = rows.zip(keys).filter_map { |row, key| listed.fetch(key) if %w[known changed unresolved].include?(row.verdict) }
      Result.new(stock: stock, erxos: erxos, runtime: runtime,
                 rows: rows + unused_rows(known, used: used, keys: keys, listed: listed, finished: finished))
    end

    # What a side shows for a case: its recorded result, else, for a group
    # configuration function the side never ran, the skip of the cases under
    # that group, and otherwise unknown. A side that lost an event line may
    # have lost a case's start, which numbers that case's later runs one too
    # low, so it claims no run of a case either side ran more than once.
    def status_of(side, key, repeated:)
      return 'unknown' if side.lost.positive? && repeated.include?(key.identity)

      side.cases.fetch(key) { skipped_group_function(side, key) || 'unknown' }
    end
    private_class_method :status_of

    # A side that skips a suite or a group whole runs none of its cases and
    # none of its init_per_group or end_per_group. On a side that finished, a
    # function with no record did not run, so when the side recorded cases
    # under the group, in the same pass, and every one was skipped, the
    # function was skipped with them, as Common Test skips a group's cases
    # when its setup skips. A function with no recorded case under its group,
    # or with one that ran, stays unknown, and so does every function of a
    # side that lost events or was cut off, where a missing record shows
    # nothing.
    def skipped_group_function(side, key)
      return unless side.state == 'complete' && GROUP_CONFIG.include?(key.testcase) && !key.group.empty?

      under = side.cases.filter_map do |other, status|
        status if other.suite == key.suite && other.attempt == key.attempt && other.group.first(key.group.size) == key.group
      end
      'auto_skip' if !under.empty? && under.all? { |status| SKIPPED_STATUSES.include?(status) }
    end
    private_class_method :skipped_group_function

    # The rows of the table for a suite that ran that account for no case:
    # an exact row naming no case either run reached, or a `*` row under
    # which no case differs. When both runs finished, the row is stale;
    # otherwise a run may have stopped before its cases, so nothing is known.
    # An exact row whose case agrees with stock is already a stale row of the
    # comparison.
    def unused_rows(known, used:, keys:, listed:, finished:)
      suites = keys.to_set(&:suite)
      claimed = used.to_set | listed.values.compact.select(&:exact?)
      (known.select { |row| suites.include?(row.suite) } - claimed.to_a).map do |row|
        reason = if finished
                   'the table names no case that differs: correct or delete the row'
                 else
                   'neither run reached a case the table names'
                 end
        Row.new(suite: row.suite, group: row.group == ANY ? [ANY] : row.group, testcase: row.testcase,
                attempt: nil, stock: 'unknown', erxos: 'unknown', verdict: finished ? 'stale' : 'unresolved',
                reason: reason)
      end
    end
    private_class_method :unused_rows

    def row(key, stock:, erxos:, listed:)
      suite, group, testcase, attempt = key.deconstruct
      verdict = verdict(stock: stock, erxos: erxos, listed: listed)
      reason = case verdict
               when 'differs' then 'not in the table'
               when 'stale' then "listed as #{listed.status}, but erXos agrees with stock: delete the row"
               when 'changed' then "listed as #{listed.status}: #{listed.reason}"
               when 'known' then listed.reason
               end
      Row.new(suite: suite, group: group, testcase: testcase, attempt: attempt, stock: stock, erxos: erxos,
              verdict: verdict, reason: reason)
    end
    private_class_method :row

    # A `*` row claims only the cases that differ, so a case it covers that
    # agrees with stock is the same, where an exact row would be stale.
    def verdict(stock:, erxos:, listed:)
      return 'unresolved' unless STATUSES.include?(stock) && STATUSES.include?(erxos)
      return(stock == erxos ? 'same' : 'differs') unless listed
      return(listed.exact? ? 'stale' : 'same') if stock == erxos

      erxos == listed.status ? 'known' : 'changed'
    end
    private_class_method :verdict

    # A side's wall-clock time as the report prints it.
    def seconds(side) = side.seconds ? "#{side.seconds.round} s" : 'unknown'

    # One row of the report, without its verdict.
    def describe(row)
      attempt = row.attempt ? " ##{row.attempt}" : ''
      ["#{row.name}#{attempt}: stock #{row.stock}, erXos #{row.erxos}", row.reason].compact.join(', ')
    end
  end
end
