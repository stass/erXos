# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/bench_g3'
require_relative '../../tools/lib/erx/bench_guest'
require_relative '../../tools/lib/erx/bench_guest_log'

class BenchGuestTest < Minitest::Test
  PLAN = Erx::BenchGuest::PLANS.fetch('tcg')
  BEAM = (0..999).map { |value| value % 256 }.pack('C*')
  PLATFORM = Erx::Platform.development(File.expand_path('../..', __dir__))

  def test_the_transcript_is_one_the_harness_accepts_and_types_in_order
    points = Erx::BenchGuest.checkpoints(beam: BEAM, plan: PLAN, platform: PLATFORM)
    Erx::Transcript.new(checkpoints: points)
    typed = points.filter_map { |point| point[:type] }
    # erl reaches the command shell first, and the footprint is typed at the Erlang shell's banner.
    assert_equal ["erl\r", Erx::BenchGuest::FOOTPRINT_EXPRESSION + "\r"], typed.first(2)
    shells = points.select { |point| %w[release-shell erlang-shell].include?(point.fetch(:name)) }
    assert_equal [nil, typed[1]], shells.map { |point| point[:type] }
    assert_match shells.first.fetch(:pattern), "rc: the command shell; erl starts the Erlang shell\r\n"
    assert_match shells.last.fetch(:pattern), "Eshell V16.0 (type help(). for help)\r\n"
    assert_equal 4, typed.count { |line| line.include?('erx_otp_bench:run(') }
    assert_equal 'workload-switch', points.last.fetch(:name)
    refute points.last.key?(:type)
  end

  def test_each_answer_types_the_line_after_the_one_it_answers
    points = Erx::BenchGuest.checkpoints(beam: BEAM, plan: PLAN, platform: PLATFORM).to_h { |point| [point.fetch(:name), point] }
    lines = Erx::BenchGuest.load_lines(BEAM)
    # The footprint prints and then evaluates to ok; only the second answer types the next line.
    refute points.fetch('footprint').key?(:type)
    assert_equal lines.first, points.fetch('footprint-ok').fetch(:type)
    assert_equal lines[1], points.fetch('load-0').fetch(:type)
    assert_equal Erx::BenchGuest.workload_line('pingpong', PLAN), points.fetch("load-#{lines.size - 1}").fetch(:type)
    assert_equal Erx::BenchGuest.workload_line('switch', PLAN), points.fetch('workload-spawn').fetch(:type)
  end

  def test_the_load_prints_the_digest_of_the_module_and_waits_for_it
    points = Erx::BenchGuest.checkpoints(beam: BEAM, plan: PLAN, platform: PLATFORM)
    answer = points.find { |point| point.fetch(:name) == "load-#{Erx::BenchGuest.load_lines(BEAM).size - 1}" }
    assert_match answer.fetch(:pattern), "G3BEAM #{MD5}\r\n"
    refute_match answer.fetch(:pattern), "ok\r\n"
    assert_includes Erx::BenchGuest.load_lines(BEAM).last, 'module_info(md5)'
  end

  def test_the_beam_travels_in_bounded_lines_that_join_back_to_it
    lines = Erx::BenchGuest.load_lines(BEAM)
    assert_equal 4, lines.size - 1
    assert(lines.all? { |line| line.bytesize < Erx::BenchGuest::CHUNK_BYTES * 4 + 250 })
    joined = lines[0...-1].flat_map { |line| line[/<<(.*)>>/, 1].split(',').map(&:to_i) }
    assert_equal BEAM.bytes, joined
    assert_includes lines.last, 'code:load_binary'
  end

  def test_the_ring_is_asked_for_more_sends_than_the_others_iterations
    assert_equal 10_000, Erx::BenchGuest.iterations_for('ring', PLAN)
    assert_equal 1_000, Erx::BenchGuest.iterations_for('spawn', PLAN)
    assert_equal %w[pingpong ring spawn switch], Erx::BenchGuest.asked(PLAN).keys
  end

  MD5 = 'a' * 32
  FOOTPRINT = { 'processes' => 3, 'emu_flavor' => 'emu', 'schedulers' => 1,
                'native_time_unit_hz' => 1_000_000_000 }.freeze

  def measurement(workload, **override)
    iterations = Erx::BenchGuest.iterations_for(workload, PLAN)
    { 'workload' => workload, 'iterations' => iterations, 'operations' => iterations,
      'samples' => PLAN.samples, 'ns_per_operation' => Array.new(PLAN.samples, 100.0),
      'beam_md5' => MD5, 'emu_flavor' => 'emu', 'schedulers' => 1, 'wordsize' => 8 }.merge(override)
  end

  def log_text(measurements, footprint: FOOTPRINT, beam: MD5)
    text = +''
    text << "G3FOOT #{JSON.generate(footprint)}\r\nok\r\n" if footprint
    text << "G3BEAM #{beam}\r\nok\r\n" if beam
    measurements.each { |entry| text << "G3 #{JSON.generate(entry)}\r\nok\r\n" }
    text
  end

  # The checkpoints a run reached: the boot points, then each workload five host seconds apart.
  def observed(workloads: Erx::BenchGuest::WORKLOADS)
    boot = Erx::BenchGuestLog::BOOT_POINTS.each_with_index.map { |name, i| { 'name' => name, 'elapsed_seconds' => i + 1.0 } }
    runs = workloads.each_with_index.map { |name, i| { 'name' => "workload-#{name}", 'elapsed_seconds' => 10.0 + 5.0 * i } }
    boot + [{ 'name' => 'load-4', 'elapsed_seconds' => 5.0 }] + runs
  end

  def read(text, observed: self.observed, flavour: 'emu', **rest)
    Erx::BenchGuestLog.read_log(text, observed, expected: Erx::BenchGuest.asked(PLAN), samples: PLAN.samples,
                                                flavour: flavour, **rest)
  end

  def all_measurements = Erx::BenchGuest::WORKLOADS.map { |name| measurement(name) }

  def statuses(result) = result.fetch('workloads').transform_values { |entry| entry.fetch('status') }

  def test_a_complete_log_reads
    result = read(log_text(all_measurements))
    assert_equal %w[measured] * 4, statuses(result).values
    assert_equal 'measured', result.fetch('footprint').fetch('status')
    assert_equal 3, result.fetch('footprint').fetch('measurement').fetch('processes')
    assert_equal MD5, result.fetch('beam').fetch('md5')
    assert_equal 3.0, result.fetch('boot_seconds').fetch('release-shell')
    assert_equal 5.0, result.fetch('workloads').fetch('ring').fetch('host_interval_seconds')
  end

  def test_an_empty_log_has_everything_missing_and_nothing_defaulted
    result = read('', observed: [])
    assert_equal %w[missing] * 4, statuses(result).values
    assert_equal 'missing', result.fetch('footprint').fetch('status')
    assert_equal 'missing', result.fetch('beam').fetch('status')
    assert_empty result.fetch('boot_seconds')
  end

  def test_a_timed_out_workload_keeps_the_ones_before_it
    result = read(log_text(all_measurements.first(2)), observed: observed(workloads: %w[pingpong ring]),
                  awaiting: 'workload-spawn', timed_out: true)
    assert_equal %w[measured measured timed_out missing], statuses(result).values
  end

  def test_a_workload_is_not_timed_out_unless_the_run_timed_out
    result = read(log_text(all_measurements.first(2)), observed: observed(workloads: %w[pingpong ring]),
                  awaiting: 'workload-spawn', timed_out: false)
    assert_equal %w[measured measured missing missing], statuses(result).values
  end

  def test_a_duplicate_workload_line_is_refused_where_it_stands
    lines = [measurement('pingpong'), measurement('pingpong'), measurement('spawn'), measurement('switch')]
    result = read(log_text(lines))
    assert_equal %w[measured rejected measured measured], statuses(result).values
    assert_match(/field workload is not the requested ring/, result.fetch('workloads').fetch('ring').fetch('reason'))
  end

  def test_more_lines_than_workloads_refuses_them_all
    result = read(log_text(all_measurements + [measurement('switch')]))
    assert_equal %w[rejected] * 4, statuses(result).values
    assert_match(/5 measurement lines, not 4/, result.fetch('workloads').fetch('spawn').fetch('reason'))
  end

  def rejection(workload: 'spawn', **overrides)
    lines = all_measurements.map { |entry| entry.fetch('workload') == workload ? entry.merge(overrides) : entry }
    entry = read(log_text(lines)).fetch('workloads').fetch(workload)
    assert_equal 'rejected', entry.fetch('status')
    entry.fetch('reason')
  end

  def test_empty_samples_are_refused
    assert_match(/ns_per_operation is not one number per sample/, rejection('ns_per_operation' => []))
  end

  def test_a_zero_or_negative_guest_value_is_refused
    assert_match(/not positive and finite/, rejection('ns_per_operation' => [0, 1.0, 1.0]))
    assert_match(/not positive and finite/, rejection('ns_per_operation' => [-1.0, 1.0, 1.0]))
    assert_match(/not positive and finite/, rejection('ns_per_operation' => [1.0, 'fast', 1.0]))
  end

  def test_a_flavour_mismatch_is_refused_for_every_line
    result = read(log_text(all_measurements), flavour: 'jit')
    assert_equal %w[rejected] * 4, statuses(result).values
    assert_equal 'rejected', result.fetch('footprint').fetch('status')
    assert_match(/field emu_flavor is not the requested jit/, result.fetch('workloads').fetch('spawn').fetch('reason'))
  end

  def test_more_than_one_scheduler_is_refused
    assert_match(/field schedulers is not the requested 1/, rejection('schedulers' => 2))
  end

  def test_a_wrong_size_is_refused
    assert_match(/field samples is not the requested 3/, rejection('samples' => 4))
    assert_match(/field iterations is not the requested 1000/, rejection('iterations' => 999))
    assert_match(/operations is not a positive integer/, rejection('operations' => 0))
  end

  def test_a_guest_clock_that_ran_ahead_of_the_host_is_refused
    # 1000 operations of 10 ms each, three samples: 30 s inside a 5 s host interval.
    assert_match(/the guest timed 30\.000 s inside 5\.000 s/, rejection('ns_per_operation' => [1e7] * 3))
  end

  def test_a_guest_clock_within_the_host_interval_and_poll_slack_is_accepted
    fits = 5.0 + Erx::BenchGuestLog::POLL_SLACK_SECONDS
    ns = fits * 1e9 / (1000 * 3)
    result = read(log_text(all_measurements.map { |entry| entry.merge('ns_per_operation' => [ns] * 3) }))
    assert_equal 'measured', result.fetch('workloads').fetch('spawn').fetch('status')
    over = (fits + 0.01) * 1e9 / (1000 * 3)
    assert_match(/the guest timed/, rejection('ns_per_operation' => [over] * 3))
  end

  def test_a_workload_with_no_arrival_time_cannot_be_checked_against_the_host_clock
    result = read(log_text(all_measurements), observed: observed(workloads: %w[pingpong]))
    assert_equal %w[measured rejected rejected rejected], statuses(result).values
    assert_match(/no host arrival times/, result.fetch('workloads').fetch('ring').fetch('reason'))
  end

  def test_another_beam_than_the_one_loaded_is_refused
    assert_match(/another beam than the one loaded/, rejection('beam_md5' => 'b' * 32))
    result = read(log_text(all_measurements, beam: nil))
    assert_equal %w[rejected] * 4, statuses(result).values
    assert_match(/loaded no beam/, result.fetch('workloads').fetch('spawn').fetch('reason'))
  end

  def test_a_footprint_without_the_time_unit_is_refused
    result = read(log_text(all_measurements, footprint: FOOTPRINT.except('native_time_unit_hz')))
    assert_equal 'rejected', result.fetch('footprint').fetch('status')
  end

  def test_the_guests_text_is_never_echoed_into_a_reason
    reason = rejection('workload' => "\e]0;owned\a")
    refute_includes reason, "\e"
    refute_includes reason, 'owned'
  end

  def test_a_guest_line_that_is_not_json_is_refused_not_raised
    result = read(log_text(all_measurements.first(1)) + "G3 {nope}\r\n")
    assert_equal %w[measured rejected missing missing], statuses(result).values
  end

  def test_a_line_the_transcript_accepts_is_the_line_the_log_reader_judges
    # The checkpoint matches the prefix `G3 {`; the reader must pair the same lines.
    odd = "G3 #{JSON.generate(measurement('pingpong'))}\r\r\n"
    text = log_text([]) + odd + log_text(all_measurements.drop(1), footprint: nil, beam: nil)
    assert_equal %w[measured] * 4, statuses(read(text)).values
  end

  def test_an_integral_float_is_not_an_integer
    assert_match(/schedulers is not the requested 1/, rejection('schedulers' => 1.0))
    assert_match(/iterations is not the requested 1000/, rejection('iterations' => 1000.0))
  end

  def test_the_footprint_parser_wants_exactly_one_line
    assert_equal({ 'a' => 1 }, Erx::BenchGuestLog.parse_footprint("noise\nG3FOOT {\"a\":1}\n"))
    assert_equal({ 'a' => 1 }, Erx::BenchGuestLog.parse_footprint("G3FOOT {\"a\":1}\r\n".b))
    assert_raises(Erx::BenchGuestLog::Absent) { Erx::BenchGuestLog.parse_footprint("no line\n") }
    assert_raises(Erx::Error) { Erx::BenchGuestLog.parse_footprint("G3FOOT {\"a\":1}\nG3FOOT {\"a\":2}\n") }
    assert_raises(Erx::Error) { Erx::BenchGuestLog.parse_footprint("G3FOOT {\"a\":1,\"a\":2}\n") }
    assert_raises(Erx::Error) { Erx::BenchGuestLog.parse_footprint("G3FOOT {\"a\":#{'1' * 70_000}}\n") }
  end

  def test_a_run_that_timed_out_leaves_a_partial_result
    points = Erx::BenchGuest.checkpoints(beam: BEAM, plan: PLAN, platform: PLATFORM)
    reached = points.index { |point| point.fetch(:name) == 'workload-spawn' }
    seen = points.first(reached).each_with_index.map { |point, i| { 'name' => point.fetch(:name), 'elapsed_seconds' => i * 1.0 } }
    Dir.mktmpdir('erx-g3-') do |directory|
      File.write(File.join(directory, 'report.json'), JSON.generate('state' => 'timed_out', 'checkpoints' => seen))
      File.write(File.join(directory, 'serial.log'), log_text(all_measurements.first(2)))
      failure = Erx::TranscriptTimeout.new('QEMU checkpoint timed out: workload-spawn')
      result = Erx::BenchGuest.send(:settle, directory: directory, failure: failure, points: points,
                                             plan: PLAN, flavour: 'emu')
      assert_equal 'timed_out', result.fetch('state')
      assert_equal 'QEMU checkpoint timed out: workload-spawn', result.fetch('error')
      assert_equal %w[measured measured timed_out missing], statuses(result).values
    end
  end

  def test_a_run_that_left_no_report_has_nothing_measured
    Dir.mktmpdir('erx-g3-') do |directory|
      points = Erx::BenchGuest.checkpoints(beam: BEAM, plan: PLAN, platform: PLATFORM)
      result = Erx::BenchGuest.send(:settle, directory: directory, failure: Erx::Error.new('no image'),
                                             points: points, plan: PLAN, flavour: 'emu')
      assert_equal 'failed', result.fetch('state')
      assert_equal %w[missing] * 4, statuses(result).values
    end
  end

  def test_comparison_is_guest_over_stock_by_median
    guest = { 'ns_per_operation' => [30.0, 10.0, 20.0] }
    stock = { 'ns_per_operation' => [5.0, 15.0] }
    result = Erx::BenchG3.compare(guest, stock)
    assert_equal 20.0, result.fetch('guest_ns')
    assert_equal 10.0, result.fetch('stock_ns')
    assert_equal 2.0, result.fetch('guest_over_stock')
  end

  def stock_runs(**override)
    Erx::BenchGuest::WORKLOADS.to_h { |name| [name, { 'measurement' => measurement(name, **override) }] }
  end

  def report(guest_log, state: 'passed', stock: stock_runs)
    guest = { 'state' => state, 'error' => nil }.merge(guest_log)
    beam = Erx::Bench::Beam.new(directory: '/x', source: '/x/a.erl', bytes: BEAM, sha256: 'c' * 64)
    Erx::BenchG3.report(host: 'host', now: Time.utc(2026, 1, 1), plan: PLAN, flavour: 'emu', guest: guest,
                        stock: stock, stock_footprint: {}, build: { 'compiler' => 'c', 'flags' => {} },
                        beam: beam, load: { 'guest' => {}, 'stock' => {} })
  end

  def test_a_complete_run_makes_a_complete_report
    report = report(read(log_text(all_measurements)))
    assert report.fetch('complete')
    assert_equal %w[compared] * 4, report.fetch('comparison').values.map { |entry| entry.fetch('status') }
  end

  def test_a_timed_out_workload_gives_a_partial_report_that_is_not_complete
    log = read(log_text(all_measurements.first(2)), observed: observed(workloads: %w[pingpong ring]),
                                                    awaiting: 'workload-spawn', timed_out: true)
    report = report(log, state: 'timed_out')
    refute report.fetch('complete')
    assert_equal %w[compared compared timed_out missing], report.fetch('comparison').values.map { |e| e.fetch('status') }
    assert_equal 'compared', report.fetch('comparison').fetch('ring').fetch('status')
  end

  def test_a_guest_that_did_not_end_cleanly_is_not_complete_whatever_it_printed
    refute report(read(log_text(all_measurements)), state: 'failed').fetch('complete')
  end

  def test_guest_and_stock_must_have_run_the_same_operations_of_the_same_beam
    log = read(log_text(all_measurements))
    other_ops = report(log, stock: stock_runs('operations' => 7))
    assert_equal 'rejected', other_ops.fetch('comparison').fetch('ring').fetch('status')
    other_beam = report(log, stock: stock_runs('beam_md5' => 'b' * 32))
    assert_equal %w[rejected] * 4, other_beam.fetch('comparison').values.map { |entry| entry.fetch('status') }
    refute other_beam.fetch('complete')
  end
end
