# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_record'
require_relative 'board_clock'
require_relative 'bench_suite'

module Erx
  # The side-by-side tables of a comparison session (docs/design-bench.md, "A comparison
  # session"): a pure function of the session's runs and the benchmark's declaration.
  # There is one table per layer, the kernel table of the native boot, the Erlang table of
  # the xdomain boot and the program table of the posix boot, each with a row per erXos
  # cell and a column per system; a program row also prints its operation's act, whether
  # both systems do the same work for the call (docs/design-bench.md, "Fairness"). A cell on
  # one CPU is read from the one-CPU runs and one across CPUs from the runs at the
  # landing boot's count. The tables give no verdict: setting systems beside each other
  # is never a comparison.
  #
  # A number is converted to nanoseconds only by its own run's clocks: a clock with a
  # frequency by its run's clock group, and a cell in CPU cycles by the ARM clock its sets'
  # build records state the cards were configured to hold (BoardClock), which the row then
  # names; a cell in cycles from a run with no such clock, as under QEMU, stays in cycles
  # whatever another boot's CLOCK line measured, since a calibration describes only its own
  # boot. A ratio is set only between two histograms in nanoseconds, neither converted
  # from cycles at a configured clock.
  module BenchSideBySide
    # One boot of the session: the round it booted in and its record.
    Run = Data.define(:round, :record)
    # An amount in a unit: ns, cycles, ticks (a frequency clock whose run recorded no
    # frequency) or operations.
    Quantity = Data.define(:amount, :unit)
    # One run's cell in a row: its status and reason, clock and summary form, the
    # statistics its summary reports, the ARM clock in hertz its cycles were converted at
    # (nil when they were not), and its median over erXos's run of the same round, nil
    # unless both are histograms in nanoseconds.
    Entry = Data.define(:round, :status, :reason, :clock, :form, :values, :converted_hz, :ratio)
    # One system in a row: what it runs for the operation (nil for erXos, whose cell the
    # row is; 'none' where the system has no counterpart, and then no entries), and its
    # runs' cells.
    Column = Data.define(:system, :counterpart, :entries)
    # act is the operation's declared act line, nil outside the program layer's table.
    Row = Data.define(:benchmark, :cell, :cpus, :act, :columns)
    Table = Data.define(:layer, :benchmark, :rows)

    # The clocks whose ticks have a frequency, which their run's clock group records.
    FREQUENCY_CLOCKS = %w[counter monotonic].freeze
    # The statistics a histogram's row shows, where its profile allows them.
    STATISTICS = %w[p50 p99 max].freeze
    NONE = 'none'

    module_function

    # The tables of benchmark's landing boots from runs, with a column for each of systems.
    # Each row reads the runs of its cell's CPU form; with forms false, as on the board,
    # where each system boots in its own form, every run, and the row names no form.
    def tables(benchmark, runs, systems:, forms: true)
      BenchSuite::BOOTS.filter_map do |boot, entry|
        cells = benchmark.landing[boot] or next
        rows = cells.map do |cell|
          cpus = (cell.cpus == 1 ? 1 : entry.cpus if forms)
          read = forms ? runs.select { |run| run.record.environment.cpus == cpus } : runs
          Row.new(benchmark: benchmark.name, cell: cell, cpus: cpus, act: benchmark.operations.fetch(cell.operation).act,
                  columns: columns(benchmark, cell, read, systems))
        end
        Table.new(layer: entry.layer, benchmark: benchmark.name, rows: rows)
      end
    end

    def columns(benchmark, cell, runs, systems)
      entries = systems.to_h do |system|
        [system, runs.filter_map { |run| entry(run, cell, benchmark.name) if run.record.environment.system == system }]
      end
      erxos = entries.fetch('erxos', []).to_h { |entry| [entry.round, entry] }
      counterparts = benchmark.operations.fetch(cell.operation).counterparts
      systems.map do |system|
        next Column.new(system: system, counterpart: nil, entries: entries.fetch(system)) if system == 'erxos'
        next Column.new(system: system, counterpart: NONE, entries: []) unless counterparts.key?(system)

        Column.new(system: system, counterpart: counterparts.fetch(system),
                   entries: entries.fetch(system).map { |entry| entry.with(ratio: ratio(entry, erxos[entry.round])) })
      end
    end

    # The entry of run's cell for the declared cell, matched by operation and the
    # conditions both systems share (load, placement, parameters); nil when the run has
    # no such cell.
    def entry(run, declared, benchmark)
      boot = run.record.boot
      cell = boot.cells.find do |candidate|
        [candidate.benchmark, candidate.operation, candidate.conditions.load, candidate.conditions.placement,
         candidate.conditions.parameters] ==
          [benchmark, declared.operation, declared.load, declared.placement, declared.parameters]
      end
      return nil unless cell

      cycles = cell.conditions.clock == 'cycles'
      hz = frequency(cell.conditions.clock, boot.clock, run.record.run.details)
      Entry.new(round: run.round, status: cell.status, reason: cell.reason, clock: cell.conditions.clock, form: cell.form,
                values: values(cell, hz, cycles ? 'cycles' : 'ticks'), converted_hz: (hz if cycles), ratio: nil)
    end

    # The frequency a cell counted on clock_name is converted to nanoseconds at, from its
    # own run: for cycles the ARM clock the run's details state, for a frequency clock the
    # positive frequency its clock group recorded; nil when there is none.
    def frequency(clock_name, clock, details)
      case clock_name
      when 'cycles' then BoardClock.stated_hz(details, label: 'bench: a board run')
      when *FREQUENCY_CLOCKS
        clock&.fetch('frequency_hz', nil).then { |hz| hz if hz.is_a?(Integer) && hz.positive? }
      end
    end

    # What a cell's summary reports, each amount at hz (amount): a histogram's statistics,
    # and the mean of a cell that kept its count and total, a mean's or a batched
    # histogram's.
    def values(cell, hz, unit)
      summary = cell.summary
      statistics = cell.form == 'mean' ? {} : STATISTICS.to_h { |name| [name, reported(summary[name])] }.compact
      statistics.transform_values { |ticks| amount(ticks, hz, unit) }.merge(mean(summary, hz, unit))
    end

    # A statistic's amount: a percentile is reported as a map holding its value.
    def reported(value) = value.is_a?(Hash) ? value['value'] : value

    # A mean is shown as its total over its count, one operation of the cell: a program's
    # printed mean may count each operation as more than one (ipcbench's IPC mean is half
    # a round trip), and the record keeps it as printed; a batched histogram's count is
    # its calls, not its samples.
    def mean(summary, hz, unit)
      return {} unless summary.key?('total')

      count = summary.fetch('count')
      { 'count' => Quantity.new(amount: count, unit: 'operations'),
        'mean' => amount(Rational(summary.fetch('total'), count), hz, unit) }
    end

    # ticks in nanoseconds at hz (frequency), or in unit, cycles or ticks, without one.
    def amount(ticks, hz, unit)
      hz ? Quantity.new(amount: Rational(ticks * 1_000_000_000, hz), unit: 'ns') : Quantity.new(amount: ticks, unit: unit)
    end

    # entry's median over erXos's, where both are histograms in nanoseconds and neither was
    # converted from cycles at a configured clock; a mean is never set in a ratio
    # (docs/design-bench.md, "A mean").
    def ratio(entry, erxos)
      return nil if entry.converted_hz || erxos&.converted_hz

      own, base = [entry, erxos].map { |side| side&.form == 'histogram' ? side.values['p50'] : nil }
      own && base && base.unit == 'ns' && own.unit == 'ns' && base.amount.positive? ? own.amount / base.amount : nil
    end

    # The tables as lines for the terminal; the caller escapes them at its sink.
    def render(tables)
      tables.flat_map do |table|
        ["The #{table.layer} table of #{table.benchmark}, side by side; no verdict",
         *table.rows.flat_map { |row| render_row(row) }]
      end
    end

    def render_row(row)
      cell = row.cell
      ["#{row.benchmark}.#{cell.operation} #{cell.load} #{cell.placement}#{parameters(cell.parameters)}, " \
       "#{row.cpus ? "#{row.cpus}-CPU form" : 'on the board'}",
       *(row.act ? ["  act: #{row.act}"] : []),
       *row.columns.flat_map { |column| render_column(column) }]
    end

    def parameters(given) = given.empty? ? '' : " #{given.map { |name, value| "#{name}=#{value}" }.join(' ')}"

    def render_column(column)
      return ["  #{column.system}: #{NONE}"] if column.counterpart == NONE

      heading = column.counterpart ? "  #{column.system}: #{column.counterpart}" : "  #{column.system}"
      entries = column.entries.map { |entry| "    round #{entry.round + 1}: #{render_entry(entry)}" }
      [heading, *(entries.empty? ? ['    no run'] : entries)]
    end

    def render_entry(entry)
      status = entry.reason ? "#{entry.status} (#{entry.reason})" : entry.status
      values = entry.values.map { |name, quantity| "#{name} #{quantity_text(quantity)}" }
      ratio = entry.ratio ? ["ratio #{format('%.2f', entry.ratio)}"] : []
      clock = entry.converted_hz ? "cycles, shown in ns at the #{entry.converted_hz / 1_000_000} MHz ARM clock its config.txt set, not measured" : entry.clock
      "#{[status, clock, entry.form].join(', ')}#{values.empty? ? '' : ": #{[*values, *ratio].join(', ')}"}"
    end

    def quantity_text(quantity)
      amount = quantity.amount
      "#{amount.is_a?(Integer) ? amount : format('%.1f', amount)} #{quantity.unit}"
    end

    private_class_method :columns, :entry, :values, :reported, :mean, :amount, :ratio, :render_row, :parameters, :render_column,
                         :render_entry, :quantity_text
  end
end
