# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'line_escape'

module Erx
  # The pure half of the network benchmarks (docs/design-network-fastpath.md, "Benchmarks
  # and targets"): what a run's output says, and the report that sets the stacks side by
  # side. The effects, starting the peers and the clients, belong to NetBenchFreebsd.
  #
  # A client (bench/erx_net_bench.erl, bench/lwip/lwip_bench.c) ends a run with one
  # `RESULT key=value ...` line and, for erx_net, one `COUNTER name=value` line per counter
  # its interface keeps. Each also prints a `WINDOW cpu_ms=N voluntary=N involuntary=N` line,
  # the CPU time (user plus system, all threads) and the voluntary and involuntary context
  # switches of its own process, the quantities of getrusage, from just before the run to just
  # after it, so what starting the client costs (a BEAM with 128 schedulers spends several
  # CPU seconds on it) is not in the figures. erx_net also prints a `BEAM schedulers=N
  # online=N sbwt=V sbwtdcpu=V sbwtdio=V` line, its scheduler settings. `time -l` of the host
  # adds the whole process's CPU, which the report uses only for a run with no WINDOW line,
  # and says so in its basis column. Everything a run prints is text from the remote host,
  # so a line is read only if it has exactly that shape, and the report shows only numbers
  # this code formats and, where it quotes the host, text through LineEscape.
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

    # CPU and context switches over the run itself, as the client reports them in its WINDOW line.
    Window = Data.define(:cpu, :voluntary, :involuntary) do
      def switches = voluntary + involuntary
    end

    # What a run cost and what that figure covers: `run` is the client's own window over the
    # run, `process` the whole client process from its start, startup included.
    Cost = Data.define(:cpu, :switches, :basis)

    # The scheduler settings of the emulator a run used, each a flag's value or `default`.
    Beam = Data.define(:schedulers, :online, :sbwt, :sbwtdcpu, :sbwtdio) do
      def text = "+S #{schedulers}:#{online}, +sbwt #{sbwt}, +sbwtdcpu #{sbwtdcpu}, +sbwtdio #{sbwtdio}"
    end

    # One run of one stack on one workload. window and beam are nil where the client reported
    # no WINDOW or BEAM line (lwIP has no BEAM; a host whose ps lacks switches gives no window).
    Run = Data.define(:stack, :workload, :result, :counters, :rusage, :window, :beam) do
      def metric = Float(result.fetch(workload.metric))

      def cost
        return Cost.new(cpu: window.cpu, switches: window.switches, basis: 'run') if window

        Cost.new(cpu: rusage.cpu, switches: rusage.switches, basis: 'process')
      end
    end

    # One line for the emulators of all runs: their common settings, or each distinct one, or
    # the fact that no run reported any.
    def self.beam_summary(runs)
      texts = runs.filter_map { |run| run.beam&.text }.uniq
      texts.empty? ? 'not reported' : texts.join('; ')
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

    # What a client printed: its RESULT line as a Hash of text, its COUNTER lines as a Hash of
    # numbers, and its WINDOW and BEAM lines as a Window and a Beam, nil when absent.
    Reading = Data.define(:result, :counters, :window, :beam)

    module Output
      PAIR = /[a-z][a-z0-9_]*=[A-Za-z0-9_.+-]+/
      LINE = /\A(RESULT|COUNTER|WINDOW|BEAM)((?: #{PAIR.source})+)\z/
      MAX_LINE_BYTES = 4096
      # At most 15 digits: a window figure counts milliseconds or switches, and a longer one
      # is not a measurement.
      COUNT = /\A\d{1,15}\z/
      WINDOW_KEYS = %w[cpu_ms voluntary involuntary].freeze
      BEAM_KEYS = %w[schedulers online sbwt sbwtdcpu sbwtdio].freeze
      BEAM_VALUE = /\A(?:\d{1,6}|[a-z_]{1,16})\z/

      module_function

      # What text holds. A missing, repeated or malformed RESULT line raises; other lines are
      # not ours to read and are ignored, a counter whose value is not an integer is ignored
      # too, and a WINDOW or BEAM line that is repeated or not of the shape the client prints
      # reads as absent, so the report says what its figures cover instead of showing a guess.
      def parse(text)
        pairs = text.each_line(chomp: true).filter_map { |line| read_line(line) }
        results = pairs.select { |kind, _| kind == 'RESULT' }
        raise ParseError, "expected one RESULT line, found #{results.length}" unless results.length == 1

        counters = pairs.select { |kind, _| kind == 'COUNTER' }.each_with_object({}) do |(_, fields), found|
          fields.each { |name, value| found[name] = Integer(value, 10) if value.match?(/\A\d+\z/) }
        end
        Reading.new(result: results.first.last, counters: counters, window: window_of(pairs), beam: beam_of(pairs))
      end

      def window_of(pairs)
        fields = only_one(pairs, 'WINDOW')
        return nil unless fields&.keys&.sort == WINDOW_KEYS.sort && fields.values.all?(COUNT)

        Window.new(cpu: Integer(fields['cpu_ms'], 10) / 1000.0, voluntary: Integer(fields['voluntary'], 10),
                   involuntary: Integer(fields['involuntary'], 10))
      end
      private_class_method :window_of

      def beam_of(pairs)
        fields = only_one(pairs, 'BEAM')
        return nil unless fields&.keys&.sort == BEAM_KEYS.sort && fields.values.all?(BEAM_VALUE)

        Beam.new(**fields.transform_keys(&:to_sym))
      end
      private_class_method :beam_of

      # The fields of the one line of that kind, or nil if there is none or more than one.
      def only_one(pairs, kind)
        lines = pairs.select { |found, _| found == kind }
        lines.length == 1 ? lines.first.last : nil
      end
      private_class_method :only_one

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

        pairs = match[2].split.map { |pair| pair.split('=', 2) }
        return nil unless pairs.map(&:first).uniq.length == pairs.length

        [match[1], pairs.to_h]
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

      TABLES = [
        { title: 'bulk (512 MiB, 64 KiB sends, median of the runs)', names: %w[bulk-send bulk-recv],
          headings: %w[Mbit/s CPU-s/GiB switches/GiB basis], cells: :bulk_cells },
        { title: 'request-reply (10 s, median of the runs)', names: %w[rr-64 rr-1k rr-64x16],
          headings: %w[txn/s p50-us p99-us CPU-us/txn basis], cells: :rr_cells }
      ].freeze

      module_function

      # conditions: label => text, the remote host's own words escaped here. medians:
      # { workload name => { stack => Median } }. planned: the runs each cell was to have.
      # selected: the names of the workloads that were to run; a workload left out (by
      # `--only`) has no row, so it never reads as a result that is missing.
      def lines(conditions:, medians:, stacks:, planned:, selected:)
        tables = TABLES.filter_map do |spec|
          names = spec.fetch(:names) & selected
          next if names.empty?

          table(title: spec.fetch(:title), headings: spec.fetch(:headings), names: names, medians: medians,
                stacks: stacks, planned: planned, &method(spec.fetch(:cells)))
        end
        [*conditions.map { |label, text| "#{label}: #{LineEscape.escape(text)}" }, '',
         *tables.flat_map { |table| [*table, ''] }, *counter_lines(medians, stacks)]
      end

      # The cost of a run per GiB or per transaction, with what it covers (Run#cost).
      def bulk_cells(run)
        gib = Float(run.result.fetch('bytes')) / GIB
        cost = run.cost
        [format('%.0f', run.metric), format('%.2f', cost.cpu / gib), format('%.0f', cost.switches / gib), cost.basis]
      end

      def rr_cells(run)
        txns = Float(run.result.fetch('txns'))
        cost = run.cost
        [format('%.0f', run.metric), run.result.fetch('p50_us'), run.result.fetch('p99_us'),
         format('%.1f', cost.cpu * 1e6 / txns), cost.basis]
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
