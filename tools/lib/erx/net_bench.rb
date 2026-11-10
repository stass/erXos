# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'line_escape'

module Erx
  # The pure half of the network benchmarks (docs/design-network-fastpath.md, "Benchmarks
  # and targets"): what a run's output says, and the report that sets the stacks side by
  # side. The effects, starting the peers and the clients, belong to NetBenchP620.
  #
  # A client (bench/erx_net_bench.erl, bench/lwip/lwip_bench.c) ends a run with one
  # `RESULT key=value ...` line and, for erx_net, one `COUNTER name=value` line per counter
  # its interface keeps. `time -l` of the host adds the CPU the run used. Everything a run
  # prints is text from the remote host, so a line is read only if it has exactly that
  # shape, and the report shows only numbers this code formats and, where it quotes the
  # host, text through LineEscape.
  module NetBench
    # A run's output does not have the shape this reader accepts.
    class ParseError < Error; end

    # The fast path's counters fail the run that asked to check them.
    class CounterError < Error; end

    # One bulk or request-reply workload: how a client is started and which number rates it.
    Workload = Data.define(:name, :mode, :arguments, :metric)

    WORKLOADS = [
      Workload.new(name: 'bulk-send', mode: 'send', arguments: %w[512], metric: 'mbit'),
      Workload.new(name: 'bulk-recv', mode: 'recv', arguments: %w[512], metric: 'mbit'),
      Workload.new(name: 'rr-64', mode: 'rr', arguments: %w[64 1 10], metric: 'tps'),
      Workload.new(name: 'rr-1k', mode: 'rr', arguments: %w[1024 1 10], metric: 'tps'),
      Workload.new(name: 'rr-64x16', mode: 'rr', arguments: %w[64 16 10], metric: 'tps')
    ].freeze

    # CPU and context switches of one run, from FreeBSD's `time -l`.
    Rusage = Data.define(:real, :user, :sys, :voluntary, :involuntary) do
      def cpu = user + sys
      def switches = voluntary + involuntary
    end

    # One run of one stack on one workload.
    Run = Data.define(:stack, :workload, :result, :counters, :rusage) do
      def metric = Float(result.fetch(workload.metric))
    end

    # A fast-path counter as the report shows it: a value, or the reason there is none.
    Counter = Data.define(:label, :value, :reporter) do
      def text = value.nil? ? "unsupported (reporter: #{reporter})" : format('%g', value)
    end

    # The counters the design asks of every measurement, and what keeps each. The Erlang
    # driver prints the interface's counters by name, so a package that makes the
    # interface keep one of these has filled the report's line without any change here.
    module Counters
      REPORTER = 'erx_net_if counters'
      NOT_KEPT = 'lwip_bench has no runs or merges'

      module_function

      # The three lines of the report: frames per run, segments per merged unit, frames
      # dropped, each from the totals the interface keeps. A total that is absent is
      # unsupported, never zero; a ratio whose divisor is zero is unsupported too, since no
      # run or unit made it.
      def lines(counters, reporter: REPORTER)
        [ratio(label: 'frames per run', counters: counters, sum: 'run_frames', count: 'runs', reporter: reporter),
         ratio(label: 'segments per merged unit', counters: counters, sum: 'unit_segments', count: 'units',
               reporter: reporter),
         Counter.new(label: 'frames dropped', value: counters['frames_dropped'], reporter: reporter)]
      end

      def ratio(label:, counters:, sum:, count:, reporter:)
        total = counters[sum]
        divisor = counters[count]
        value = total && divisor && divisor.positive? ? total.to_f / divisor : nil
        Counter.new(label: label, value: value, reporter: reporter)
      end
      private_class_method :ratio

      # Why a bulk run did not use the path under test, or nil: a send run must have cut
      # runs and a receive run merged units. Unsupported counters fail too, since then the
      # number is not known to come from the path under test.
      def fast_path_failure(mode, counters)
        key = { 'send' => 'runs', 'recv' => 'units' }[mode]
        return nil unless key

        count = counters[key]
        return "#{mode} run: the interface keeps no #{key} counter" if count.nil?

        count.positive? ? nil : "#{mode} run: #{key} is 0, the path under test was not used"
      end
    end

    # What a client printed: its RESULT line as a Hash of text, and its COUNTER lines as a
    # Hash of numbers.
    module Output
      PAIR = /[a-z][a-z0-9_]*=[A-Za-z0-9_.+-]+/
      LINE = /\A(RESULT|COUNTER)((?: #{PAIR.source})+)\z/
      MAX_LINE_BYTES = 4096

      module_function

      # The one RESULT line and every COUNTER line of text. A missing, repeated or
      # malformed RESULT line raises; other lines are not ours to read and are ignored,
      # and a counter whose value is not an integer is ignored too.
      def parse(text)
        pairs = text.each_line(chomp: true).filter_map { |line| read_line(line) }
        results = pairs.select { |kind, _| kind == 'RESULT' }
        raise ParseError, "expected one RESULT line, found #{results.length}" unless results.length == 1

        counters = pairs.select { |kind, _| kind == 'COUNTER' }.each_with_object({}) do |(_, fields), found|
          fields.each { |name, value| found[name] = Integer(value, 10) if value.match?(/\A\d+\z/) }
        end
        [results.first.last, counters]
      end

      REQUIRED = {
        'send' => %w[bytes secs mbit], 'recv' => %w[bytes secs mbit],
        'rr' => %w[bytes conns secs txns tps p50_us p99_us]
      }.freeze

      # Refuses a RESULT line that lacks what its mode reports, or whose numbers are not
      # positive and finite, so no report divides by zero or prints NaN as a measurement.
      def validate(result, mode)
        REQUIRED.fetch(mode).each do |key|
          value = Float(result.fetch(key) { raise ParseError, "RESULT has no #{key}" }, exception: false)
          raise ParseError, "RESULT #{key} is not a positive finite number" unless value&.finite? && value.positive?
        end
      end

      def read_line(line)
        return nil if line.bytesize > MAX_LINE_BYTES

        match = LINE.match(line.b)
        return nil unless match

        [match[1], match[2].split.to_h { |pair| pair.split('=', 2) }]
      end
      private_class_method :read_line
    end

    # FreeBSD's `time -l` report, for the CPU and context switches of a whole run.
    module TimeReport
      TIMES = /^\s*([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys\s*$/
      VOLUNTARY = /^\s*(\d+)\s+voluntary context switches\s*$/
      INVOLUNTARY = /^\s*(\d+)\s+involuntary context switches\s*$/

      module_function

      # time writes its report last, so the last matching line of each kind is its own.
      def parse(text)
        bytes = text.b
        times = bytes.scan(TIMES).last or raise ParseError, 'no real/user/sys line of time -l'
        voluntary = bytes.scan(VOLUNTARY).last or raise ParseError, 'no voluntary context switches line of time -l'
        involuntary = bytes.scan(INVOLUNTARY).last or raise ParseError, 'no involuntary context switches line of time -l'
        real, user, sys = times.map { |value| Float(value) }
        Rusage.new(real: real, user: user, sys: sys, voluntary: Integer(voluntary.first, 10),
                   involuntary: Integer(involuntary.first, 10))
      end
    end

    # The median run of a cell's runs by its metric, so one outlier moves nothing, and how many
    # runs it was taken over: a cell with failed runs shows n/N, never a bare median.
    Median = Data.define(:run, :count)

    def self.median(runs) = Median.new(run: runs.sort_by(&:metric)[runs.length / 2], count: runs.length)

    # The report, as lines: the conditions the numbers hold under, then a table for each
    # kind of workload with one column per stack, then each stack's counters.
    module Report
      GIB = 2.0**30

      module_function

      # conditions: label => text, the remote host's own words escaped here. medians:
      # { workload name => { stack => Median } }. planned: the runs each cell was to have.
      def lines(conditions:, medians:, stacks:, planned:)
        [*conditions.map { |label, text| "#{label}: #{LineEscape.escape(text)}" }, '',
         *table(title: 'bulk (512 MiB, 64 KiB sends, median of the runs)',
                headings: %w[Mbit/s CPU-s/GiB switches/GiB], names: %w[bulk-send bulk-recv],
                medians: medians, stacks: stacks, planned: planned) { |run| bulk_cells(run) },
         '',
         *table(title: 'request-reply (10 s, median of the runs)',
                headings: %w[txn/s p50-us p99-us CPU-us/txn], names: %w[rr-64 rr-1k rr-64x16],
                medians: medians, stacks: stacks, planned: planned) { |run| rr_cells(run) },
         '', *counter_lines(medians, stacks)]
      end

      def bulk_cells(run)
        gib = Float(run.result.fetch('bytes')) / GIB
        [format('%.0f', run.metric), format('%.2f', run.rusage.cpu / gib), format('%.0f', run.rusage.switches / gib)]
      end

      def rr_cells(run)
        txns = Float(run.result.fetch('txns'))
        [format('%.0f', run.metric), run.result.fetch('p50_us'), run.result.fetch('p99_us'),
         format('%.1f', run.rusage.cpu * 1e6 / txns)]
      end

      # A table: for each workload one row per stack, then a row of the first stack's metric
      # over the second's (the ratio the design's targets state). A stack without a run for a
      # workload shows `missing`, never a number, and `runs` says n/N of the runs it is the
      # median of.
      def table(title:, headings:, names:, medians:, stacks:, planned:, &cells)
        rows = names.flat_map do |name|
          rows_for(name: name, per_stack: medians.fetch(name, {}), stacks: stacks, width: headings.length,
                   planned: planned, &cells)
        end
        [title, *align([['workload', 'stack', 'runs', *headings], *rows])]
      end

      def rows_for(name:, per_stack:, stacks:, width:, planned:, &cells)
        stack_rows = stacks.map do |stack|
          median = per_stack[stack]
          values = median ? cells.call(median.run) : ['missing'] * width
          [name, stack, "#{median ? median.count : 0}/#{planned}", *values]
        end
        [*stack_rows, [name, stacks.join('/'), '', ratio(per_stack, stacks)]]
      end

      # The rows as text, each column as wide as its widest cell.
      def align(rows)
        columns = rows.map(&:length).max
        padded = rows.map { |row| row + [''] * (columns - row.length) }
        widths = padded.transpose.map { |column| column.map(&:length).max }
        padded.map { |row| row.zip(widths).map { |cell, width| cell.ljust(width) }.join('  ').rstrip }
      end

      def ratio(per_stack, stacks)
        first, last = stacks.map { |stack| per_stack[stack] }
        first && last ? format('%.3f', first.run.metric / last.run.metric) : 'missing'
      end

      # The counters of the stacks that keep any, one block per workload, so a package
      # that fills a counter shows up here with its number beside the others.
      def counter_lines(medians, stacks)
        ['counters (the fast path; unsupported names its reporter, never a zero)',
         *medians.flat_map do |name, per_stack|
           stacks.filter_map { |stack| per_stack[stack]&.run }.flat_map do |run|
             reporter = run.stack == 'lwip' ? Counters::NOT_KEPT : Counters::REPORTER
             Counters.lines(run.counters, reporter: reporter).map { |counter| "  #{name} #{run.stack}: #{counter.label}: #{counter.text}" }
           end
         end]
      end
    end
  end
end
