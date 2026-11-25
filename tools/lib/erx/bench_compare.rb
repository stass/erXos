# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_record'
require_relative 'error'

module Erx
  # The one comparison of benchmark records (docs/design-bench.md, "Comparison"): a pure
  # function of records that compares one statistic of one cell between a baseline of at
  # least three boots and a candidate of one boot or three. Each boot of a record is one
  # side, so one record of three boots is as many as three records of one. Records are
  # compared only when their environments and cells are equal; a TCG or deterministic
  # record is compared only with its own kind, two systems never, and a mean, which has
  # one number per boot, with nothing. Inconclusive is never a pass, and a replayed boot
  # is never a side.
  module BenchCompare
    # One boot's cell, with the record that holds the boot.
    Side = Data.define(:record, :cell)
    # verdict is one of VERDICTS; reason says why an inconclusive one is; band is the
    # baseline's noise band as [low, high], nil when none was computed.
    Verdict = Data.define(:verdict, :reason, :band)
    VERDICTS = ['same', 'slower', 'faster', 'inconclusive', 'outside the band'].freeze
    BASELINE_BOOTS = 3
    # The advisory thresholds' starting values, as fractions of the baseline's median
    # (docs/design-bench.md, "Advisory thresholds"). Deterministic mode takes any change.
    ADVISORY = {
      'pi4' => { 'p50' => 5 / 100r, 'p99' => 10 / 100r, 'p999' => 20 / 100r },
      'qemu-hvf' => { 'p50' => 10 / 100r, 'p99' => 20 / 100r, 'p999' => 30 / 100r },
      'qemu-det' => { 'p50' => 0r }
    }.freeze
    # The environments whose runs share a host with other work, so a loaded host makes
    # their comparison inconclusive. A board runs alone, and deterministic time does not
    # depend on the host.
    SHARED_HOST = %w[qemu-hvf qemu-tcg host].freeze
    # A sustained cell's longest gap is its tail, judged against the 99th percentile's
    # threshold (docs/design-bench.md, "Comparison").
    THRESHOLD_OF = { 'longest' => 'p99' }.freeze

    # The cell fields two sides must agree on, in the order a refusal names them: the
    # operation, every member of its Conditions, and its profile sizes.
    CELL_FIELDS = { 'operation' => ->(cell) { [cell.benchmark, cell.operation] } }
                  .merge(BenchRecord::Conditions.members.to_h do |member|
                    ["condition #{member}", ->(cell) { cell.conditions.public_send(member) }]
                  end)
                  .merge('profile sizes' => ->(cell) { cell.profile }).freeze

    module_function

    # The Sides of the cell whose key is given (BenchRecord::Cell#key), one per boot of
    # records, in their order. Every boot keeps its side whatever its cell's status, so a
    # boot that ran twice or never makes the comparison inconclusive rather than shorter.
    # Every boot of a record holds the same cells, so a record without the cell ran
    # other cells, and is refused.
    def sides(records, key)
      records.flat_map do |record|
        raise Error, "#{record.environment.name}/#{record.name} holds no such cell" unless record.keys.include?(key)

        record.boots.map { |boot| Side.new(record: record, cell: boot.cells.find { |cell| cell.key == key }) }
      end
    end

    # The baseline the gates take for the cell whose key is given, from records newest
    # first (docs/design-bench.md, "The gates"): the newest of those holding the cell
    # until they hold BASELINE_BOOTS boots, or all of them.
    def baseline(newest_first, key)
      held = 0
      newest_first.select { |record| record.keys.include?(key) }
                  .take_while { |record| held < BASELINE_BOOTS && (held += record.boots.size) }
    end

    def threshold(environment, statistic)
      ADVISORY.dig(environment.kind, THRESHOLD_OF.fetch(statistic, statistic)) or
        raise Error, "no advisory threshold for #{statistic} in #{environment.kind}"
    end

    # Raises Erx::Error naming the first difference that makes a and b incomparable.
    def comparable!(a, b)
      reason = refusal(a, b)
      raise Error, reason if reason
    end

    def refusal(a, b)
      first, second = a.record.environment, b.record.environment
      if [a, b].any? { |side| side.cell.form == 'mean' }
        'a mean has no distribution to compare'
      elsif (first.isolated? || second.isolated?) && first.kind != second.kind
        'TCG numbers are not compared with HVF or native numbers'
      elsif first.system != second.system
        "systems differ: #{first.system} against #{second.system}; systems are only set side by side"
      elsif first.name != second.name
        "environments differ: #{first.name} against #{second.name}"
      else
        field = CELL_FIELDS.find { |_, value| value.call(a.cell) != value.call(b.cell) }
        "cells differ in #{field.first}" if field
      end
    end

    # The verdict on statistic (a summary key such as p50) between baseline and
    # candidate, each a list of Sides. threshold is the advisory fraction; rate reverses
    # the direction, for a sustained rate where more is faster.
    def verdict(statistic:, baseline:, candidate:, threshold:, rate: false)
      sides = baseline + candidate
      raise Error, 'a replayed log is not a new run' if sides.any? { |side| side.record.run.replayed? }
      raise Error, 'a candidate is one boot or three' unless [1, 3].include?(candidate.size)

      sides.each { |side| comparable!(sides.first, side) }
      reason = inconclusive_reason(statistic, baseline, sides)
      return Verdict.new(verdict: 'inconclusive', reason: reason, band: nil) if reason

      judged(band(baseline, statistic), baseline, candidate, statistic, threshold, rate)
    end

    def inconclusive_reason(statistic, baseline, sides)
      unmeasured = sides.find { |side| side.cell.status != 'measured' }
      if baseline.size < BASELINE_BOOTS
        "the baseline has #{baseline.size} of #{BASELINE_BOOTS} boots"
      elsif unmeasured
        "a side is #{unmeasured.cell.status}"
      elsif sides.any? { |side| !reported?(side, statistic) }
        "#{statistic} is not reported on every side"
      elsif sides.any? { |side| loaded?(side.record) }
        "a host's load was over half its CPUs, or not recorded"
      end
    end

    def reported?(side, statistic) = side.cell.summary[statistic]&.key?('value')

    def loaded?(record)
      return false unless SHARED_HOST.include?(record.environment.kind)

      load, cpus = record.run.load, record.run.host_cpus
      load.nil? || cpus.nil? || load.max > cpus / 2r
    end

    # The baseline's range of the statistic, widened by one histogram bucket at each end;
    # deterministic mode's band, and an exact statistic's, which has no bucket, have no width.
    def band(baseline, statistic)
      values = baseline.map { |side| side.cell.summary.fetch(statistic) }
      low, high = values.minmax_by { |value| value.fetch('value') }
      widen = baseline.first.record.environment.kind == 'qemu-det' ? 0 : 1
      [low.fetch('value') - (widen * low.fetch('bucket', 0)), high.fetch('value') + (widen * high.fetch('bucket', 0))]
    end

    def judged(band, baseline, candidate, statistic, threshold, rate)
      value = ->(side) { side.cell.summary.fetch(statistic).fetch('value') }
      above = candidate.count { |side| value.call(side) > band.last }
      below = candidate.count { |side| value.call(side) < band.first }
      outcome = ->(name, reason = nil) { Verdict.new(verdict: name, reason: reason, band: band) }
      return outcome.call('same') if above.zero? && below.zero?
      return outcome.call('outside the band', 'one candidate boot cannot say slower or faster') if candidate.size == 1

      base, cand = median(baseline.map(&value)), median(candidate.map(&value))
      if above >= 2 && cand > base * (1 + threshold)
        outcome.call(rate ? 'faster' : 'slower')
      elsif below >= 2 && cand < base * (1 - threshold)
        outcome.call(rate ? 'slower' : 'faster')
      else
        outcome.call('inconclusive', 'the candidate boots disagree or move less than the threshold')
      end
    end

    def median(values)
      sorted = values.sort
      middle = sorted.size / 2
      sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2r
    end

    private_class_method :inconclusive_reason, :reported?, :loaded?, :band, :judged, :median
  end
end
