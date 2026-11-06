# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_measurement'
require_relative 'error'
require_relative 'json_input'
require_relative 'runner'

module Erx
  # Reads what a G3 guest printed on its serial line. Everything in the log is untrusted
  # text from the guest: each line is parsed within a byte bound, checked as stock OTP's
  # measurement is, and judged on its own. A workload that has no line, was being waited
  # on at a timeout, or fails a check is reported as missing, timed out or rejected with
  # the reason; nothing is defaulted and one bad line does not hide the others.
  module BenchGuestLog
    # Raised when a line is absent, so the entry says "missing" and not "rejected".
    class Absent < Error; end

    MAX_JSON_BYTES = 65_536
    # The host reads the serial log every poll, so a checkpoint's arrival time is only
    # known to within one poll; the guest clock check allows that much.
    POLL_SLACK_SECONDS = Runner::POLL_SECONDS
    # The checkpoint names that carry boot time, in the order the guest reaches them.
    BOOT_POINTS = %w[erxos-banner release-slogan release-shell].freeze

    module_function

    # The text of the one line that starts `TAG {`, parsed. The harness's checkpoints match
    # the same prefix, so both agree on which line answered; a line that is not JSON is then
    # refused here and not skipped.
    # The text of the one `TAG {...}` line, parsed. Absent without it, an error with two.
    def tagged_json(text, tag)
      lines = text.scan(/^#{tag} (\{[^\n]*?)\r*$/).flatten
      raise Absent, "the log has no #{tag} line" if lines.empty?
      raise Error, "the log has #{lines.size} #{tag} lines, not one" unless lines.one?

      JsonInput.parse(lines.first.b, max_bytes: MAX_JSON_BYTES, label: tag)
    end

    # What a shell printed for the footprint expression, as a JSON object.
    def parse_footprint(text) = tagged_json(text, 'G3FOOT')

    # What the log says, entry by entry. expected maps each workload, in the order the guest
    # runs them, to the iterations it was asked for. awaiting names the checkpoint the run
    # was waiting for when it ended, and timed_out says whether the end was a timeout.
    def read_log(text, observed, expected:, samples:, flavour:, awaiting: nil, timed_out: false)
      beam = settle { { 'md5' => beam_md5(text) } }
      { 'boot_seconds' => boot_seconds(observed),
        'footprint' => settle { { 'measurement' => footprint(text, flavour: flavour) } },
        'beam' => beam,
        'workloads' => workloads(text, observed, expected: expected, samples: samples,
                                                 flavour: flavour, beam: beam,
                                                 awaiting: timed_out ? awaiting : nil) }
    end

    def beam_md5(text)
      digests = text.scan(/^G3BEAM ([0-9a-f]{32})\r*$/).flatten
      raise Absent, 'the log has no G3BEAM line' if digests.empty?
      raise Error, 'the log has more than one G3BEAM line' unless digests.one?

      digests.first
    end

    # The footprint line, which must come from the flavour and one scheduler that were asked
    # for and say what time unit the guest's clock counts in.
    def footprint(text, flavour:)
      value = parse_footprint(text)
      unless value['emu_flavor'] == flavour && value['schedulers'].eql?(1) &&
             BenchMeasurement.positive_integer?(value['native_time_unit_hz'])
        raise Error, 'the footprint line is not from the requested flavour, one scheduler and a time unit'
      end

      value
    end

    def boot_seconds(observed)
      observed.select { |point| BOOT_POINTS.include?(point.fetch('name')) }
              .to_h { |point| [point.fetch('name'), point.fetch('elapsed_seconds')] }
    end

    # Host seconds from the arrival of the checkpoint before each workload's to the arrival
    # of its own. The harness types the workload's line at the first, so the guest cannot
    # have timed more than this.
    def host_intervals(observed)
      observed.each_cons(2).filter_map do |before, after|
        next unless after.fetch('name').start_with?('workload-')

        [after.fetch('name').delete_prefix('workload-'),
         after.fetch('elapsed_seconds') - before.fetch('elapsed_seconds')]
      end.to_h
    end

    # One entry per workload: the guest prints one line for each, in the order it runs them.
    def workloads(text, observed, expected:, samples:, flavour:, beam:, awaiting:)
      lines = text.scan(/^G3 (\{[^\n]*?)\r*$/).flatten
      intervals = host_intervals(observed)
      expected.each_with_index.to_h do |(workload, iterations), index|
        ask = { workload: workload, iterations: iterations, samples: samples, flavour: flavour }
        entry =
          if lines.size > expected.size
            rejected("the guest printed #{lines.size} measurement lines, not #{expected.size}")
          elsif lines[index]
            judge(lines[index], ask: ask, beam: beam, interval: intervals[workload])
          elsif awaiting == "workload-#{workload}"
            { 'status' => 'timed_out', 'reason' => 'the run timed out waiting for it' }
          else
            { 'status' => 'missing', 'reason' => 'the guest printed no measurement for it' }
          end
        [workload, entry]
      end
    end

    # A line believed only if it is the asked workload, ran the beam the guest loaded, and
    # fits inside the host time that passed.
    def judge(line, ask:, beam:, interval:)
      settle do
        measurement = JsonInput.parse(line.b, max_bytes: MAX_JSON_BYTES, label: 'guest measurement')
        BenchMeasurement.validate(measurement, **ask)
        raise Error, 'the guest loaded no beam it reported' unless beam['status'] == 'measured'
        raise Error, 'the measurement is from another beam than the one loaded' unless
          measurement['beam_md5'] == beam['md5']

        seconds = guest_seconds(measurement)
        check_clock(seconds, interval)
        { 'measurement' => measurement, 'guest_seconds' => seconds, 'host_interval_seconds' => interval }
      end
    end

    # The time the guest says it spent in the timed operations of all samples.
    def guest_seconds(measurement)
      measurement.fetch('operations') * measurement.fetch('ns_per_operation').sum / 1e9
    end

    # The host's clock bounds the guest's from above: a guest cannot time more than passed.
    def check_clock(seconds, interval)
      raise Error, 'no host arrival times to check the guest clock against' unless interval
      return if seconds <= interval + POLL_SLACK_SECONDS

      raise Error, format('the guest timed %.3f s inside %.3f s of host time', seconds, interval)
    end

    # The block's hash marked measured; absent or refused as the status says, with the reason.
    def settle
      yield.merge('status' => 'measured')
    rescue Absent => error
      { 'status' => 'missing', 'reason' => error.message }
    rescue Error => error
      rejected(error.message)
    end

    def rejected(reason) = { 'status' => 'rejected', 'reason' => reason }
  end
end
