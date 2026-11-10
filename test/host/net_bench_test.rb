# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/net_bench_freebsd'

# What the network benchmarks read from a client's output and print (tools/lib/erx/net_bench.rb),
# and the one place a remote command string is built (Erx::NetBenchFreebsd::Remote). Nothing connects
# to a host here.
class NetBenchTest < Minitest::Test
  NB = Erx::NetBench
  TIME_L = <<~TEXT
            5.20 real        19.30 user         4.20 sys
        330304  maximum resident set size
       6100000  voluntary context switches
           123  involuntary context switches
  TEXT
  BULK = "boot noise\nRESULT mode=send stack=erx_net bytes=536870912 secs=4.771 mbit=900.1\n" \
         "COUNTER no_route=3\nCOUNTER ingress=12\n#{TIME_L}"

  WINDOW = "WINDOW cpu_ms=2500 voluntary=900 involuntary=100\n"
  BEAM = "BEAM schedulers=128 online=128 sbwt=none sbwtdcpu=default sbwtdio=default\n"

  def run_of(stack, workload_name, output)
    reading = NB::Output.parse(output)
    workload = NB::WORKLOADS.find { |w| w.name == workload_name }
    NB::Run.new(stack: stack, workload: workload, result: reading.result, counters: reading.counters,
                rusage: NB::TimeReport.parse(output), window: reading.window, beam: reading.beam)
  end

  def test_a_run_is_read_from_its_result_counters_and_time_report
    run = run_of('erx_net', 'bulk-send', BULK)
    assert_equal 900.1, run.metric
    assert_equal({ 'no_route' => 3, 'ingress' => 12 }, run.counters)
    assert_nil run.window
    assert_equal [6_100_000, 123, 23.5], [run.rusage.voluntary, run.rusage.involuntary, run.rusage.cpu]
  end

  def test_a_window_is_the_runs_own_cost_and_a_run_without_one_shows_its_whole_process
    windowed = run_of('erx_net', 'bulk-send', "#{BEAM}#{WINDOW}#{BULK}")
    assert_equal NB::Cost.new(cpu: 2.5, switches: 1000, basis: 'run'), windowed.cost
    assert_equal NB::Beam.new(schedulers: '128', online: '128', sbwt: 'none', sbwtdcpu: 'default', sbwtdio: 'default'), windowed.beam
    whole = run_of('lwip', 'bulk-send', BULK)
    assert_nil whole.window
    assert_equal NB::Cost.new(cpu: 23.5, switches: 6_100_123, basis: 'process'), whole.cost
  end

  def test_a_window_or_beam_line_that_is_repeated_incomplete_or_not_a_count_reads_as_absent
    base = "RESULT mode=send stack=erx_net bytes=1 secs=1 mbit=1\n"
    twice = NB::Output.parse("#{base}#{WINDOW}#{WINDOW}")
    assert_nil twice.window
    assert_nil NB::Output.parse("#{base}WINDOW cpu_ms=1 voluntary=2\n").window
    assert_nil NB::Output.parse("#{base}WINDOW cpu_ms=-5 voluntary=2 involuntary=3\n").window
    assert_nil NB::Output.parse("#{base}WINDOW cpu_ms=1 voluntary=2 involuntary=#{'9' * 16}\n").window
    assert_nil NB::Output.parse("#{base}WINDOW cpu_ms=1 cpu_ms=9 voluntary=2 involuntary=3\n").window
    assert_nil NB::Output.parse("#{base}BEAM schedulers=1 online=1 sbwt=none\n").beam
    assert_nil NB::Output.parse("#{base}BEAM schedulers=1 online=1 sbwt=none sbwtdcpu=x sbwtdio=y;id\n").beam
  end

  def test_the_emulator_settings_of_the_runs_are_summarized_or_reported_as_absent
    with = run_of('erx_net', 'bulk-send', "#{BEAM}#{BULK}")
    other = run_of('erx_net', 'bulk-recv', "#{BEAM.sub('=128', '=1')}#{BULK}")
    without = run_of('lwip', 'bulk-send', BULK)
    assert_equal '+S 128:128, +sbwt none, +sbwtdcpu default, +sbwtdio default', NB.beam_summary([with, with, without])
    assert_equal 2, NB.beam_summary([with, other]).split('; ').length
    assert_equal 'not reported', NB.beam_summary([without])
  end

  def test_output_without_exactly_one_well_formed_result_line_is_refused
    assert_raises(NB::ParseError) { NB::Output.parse("COUNTER a=1\n") }
    assert_raises(NB::ParseError) { NB::Output.parse("RESULT mode=send secs=1\nRESULT mode=send secs=2\n") }
    # A value with a control character or shell syntax is not a RESULT line at all.
    assert_raises(NB::ParseError) { NB::Output.parse("RESULT mode=send secs=$(id)\n") }
    assert_raises(NB::ParseError) { NB::Output.parse("RESULT mode=send secs=1\e[2J\n") }
  end

  def test_a_result_with_a_missing_zero_or_non_finite_number_is_refused
    good = { 'bytes' => '1', 'secs' => '1', 'mbit' => '5.0' }
    NB::Output.validate(good, 'send')
    assert_raises(NB::ParseError) { NB::Output.validate(good.except('mbit'), 'send') }
    assert_raises(NB::ParseError) { NB::Output.validate(good.merge('mbit' => 'nan'), 'send') }
    assert_raises(NB::ParseError) { NB::Output.validate(good.merge('secs' => '0'), 'recv') }
    assert_raises(NB::ParseError) { NB::Output.validate(good, 'rr') }
  end

  def test_the_last_time_report_is_the_clients_and_invalid_bytes_do_not_raise
    noisy = "9.00 real 9.00 user 9.00 sys\n#{TIME_L}\xff\n"
    assert_equal 23.5, NB::TimeReport.parse(noisy).cpu
  end

  def test_a_time_report_missing_a_line_is_refused
    assert_raises(NB::ParseError) { NB::TimeReport.parse("1.0 real 1.0 user 1.0 sys\n") }
  end

  def test_counters_the_interface_does_not_keep_are_unsupported_with_their_reporter_never_zero
    lines = NB::Counters.lines({ 'run_frames' => 30, 'runs' => 10, 'units' => 0 })
    assert_equal ['frames per run: 3', 'segments per merged unit: unsupported (reporter: erx_net_if counters)',
                  'frames dropped: unsupported (reporter: erx_net_if counters)'], lines.map { |c| "#{c.label}: #{c.text}" }
  end

  def test_the_fast_path_check_fails_a_send_without_runs_and_a_receive_without_units
    assert_match(/keeps no runs counter/, NB::Counters.fast_path_failure('send', {}))
    assert_match(/runs is 0/, NB::Counters.fast_path_failure('send', { 'runs' => 0 }))
    assert_match(/units is 0/, NB::Counters.fast_path_failure('recv', { 'units' => 0, 'runs' => 9 }))
    assert_nil NB::Counters.fast_path_failure('send', { 'runs' => 4 })
    assert_nil NB::Counters.fast_path_failure('rr', {})
  end

  def test_the_report_shows_the_ratio_a_missing_cell_and_escapes_the_hosts_words
    lwip = "RESULT mode=send stack=lwip bytes=536870912 secs=0.65 mbit=6600.0\n#{TIME_L}"
    medians = { 'bulk-send' => { 'erx_net' => NB.median([run_of('erx_net', 'bulk-send', BULK)]),
                                 'lwip' => NB.median([run_of('lwip', 'bulk-send', lwip)] * 3) } }
    lines = NB::Report.lines(conditions: { 'host' => "FreeBSD\e]0;x\a" }, medians: medians, stacks: %w[erx_net lwip],
                             planned: 3, selected: %w[bulk-send bulk-recv])
    assert_equal 'host: FreeBSD<U+001B>]0;x<U+0007>', lines.first
    assert(lines.any? { |line| line.start_with?('bulk-send') && line.include?('erx_net/lwip') && line.end_with?('0.136') })
    # A cell whose runs failed says how many it is the median of.
    assert(lines.any? { |line| line.start_with?('bulk-send') && line.match?(/erx_net\s+1\/3\s/) })
    assert(lines.any? { |line| line.start_with?('bulk-send') && line.match?(/lwip\s+3\/3\s/) })
    assert(lines.any? { |line| line.start_with?('bulk-recv') && line.end_with?('missing') })
    assert(lines.any? { |line| line.include?('bulk-send lwip: frames per run: unsupported (reporter: lwip_bench') })
  end

  # `--only` leaves workloads out: they have no row, and a table with none has no title, so a
  # workload that was not run never reads as a result that is missing. Each cost cell says
  # whether it covers the run or the whole process.
  def test_the_report_prints_only_the_selected_workloads_and_the_basis_of_each_cost
    windowed = run_of('erx_net', 'bulk-send', "#{WINDOW}#{BULK}")
    whole = run_of('lwip', 'bulk-send', "RESULT mode=send stack=lwip bytes=536870912 secs=0.65 mbit=6600.0\n#{TIME_L}")
    medians = { 'bulk-send' => { 'erx_net' => NB.median([windowed]), 'lwip' => NB.median([whole]) } }
    lines = NB::Report.lines(conditions: {}, medians: medians, stacks: %w[erx_net lwip], planned: 1, selected: %w[bulk-send])
    text = lines.join("\n")
    refute_match(/bulk-recv|rr-|request-reply|missing/, text)
    # 2.5 CPU-s and 1000 switches for 0.5 GiB, against 23.5 CPU-s and 6100123 switches.
    assert(lines.any? { |line| line.match?(/\Abulk-send\s+erx_net\s+1\/1\s+900\s+5\.00\s+2000\s+run\z/) })
    assert(lines.any? { |line| line.match?(/\Abulk-send\s+lwip\s+1\/1\s+6600\s+47\.00\s+12200246\s+process\z/) })
    # A selected workload with no run is the one shown as missing.
    both = NB::Report.lines(conditions: {}, medians: {}, stacks: %w[erx_net lwip], planned: 1, selected: %w[bulk-send rr-64])
    assert(both.any? { |line| line.start_with?('bulk-send') && line.include?('0/1') && line.include?('missing') })
    assert(both.any? { |line| line.start_with?('rr-64') && line.include?('missing') })
    refute(both.any? { |line| line.start_with?('rr-1k') })
  end

  def test_the_median_run_is_the_middle_one_by_its_metric
    runs = [900.0, 100.0, 500.0].map { |mbit| run_of('erx_net', 'bulk-send', BULK.sub('900.1', mbit.to_s)) }
    assert_equal [500.0, 3], [NB.median(runs).run.metric, NB.median(runs).count]
  end

  def test_a_remote_command_is_one_quoted_string_and_refuses_what_tcsh_would_expand
    remote = Erx::NetBenchFreebsd::Remote.new(host: 'freebsd.example')
    # The login shell strips one level of quotes; sh then reads the words back as given.
    text, = Open3.capture2e('sh', '-c', remote.command_string(['echo', 'a  b', "it's"]))
    assert_equal "a  b it's\n", text
    assert_raises(Erx::NetBenchFreebsd::RemoteError) { remote.command_string(['echo', '!!']) }
    assert_raises(Erx::NetBenchFreebsd::RemoteError) { remote.command_string(['echo', "a\nb"]) }
    assert_raises(ArgumentError) { Erx::NetBenchFreebsd::Remote.new(host: '-oProxyCommand=x') }
    assert_raises(ArgumentError) { Erx::NetBenchFreebsd::Remote.new(host: nil) }
  end

  # The lock's commands, run here through the same command string as on the host (BSD stat on
  # both), and the decisions read from their answers.
  def test_the_lock_is_taken_once_named_in_a_refusal_released_only_by_its_holder_and_stale_past_its_deadline
    lock = Erx::NetBenchFreebsd::Lock
    remote = Erx::NetBenchFreebsd::Remote.new(host: 'freebsd.example')
    run = ->(argv) { Open3.capture2e('sh', '-c', remote.command_string(argv)).first }
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'erx-net-bench.lock')
      mine = lock.holder_line(host: 'mac 1', pid: 42, started: Time.utc(2026, 11, 9), deadline: 600)
      theirs = lock.holder_line(host: 'other', pid: 7, started: Time.utc(2026, 11, 9), deadline: 600)
      assert_equal 'host=mac_1 pid=42 started=2026-11-09T00:00:00Z deadline=600', mine
      assert_equal :acquired, lock.decide(run.call(lock.acquire_argv(path, mine)), fallback_deadline: 600).state
      refusal = lock.decide(run.call(lock.acquire_argv(path, theirs)), fallback_deadline: 600)
      assert_equal [:held, mine], [refusal.state, refusal.holder]
      run.call(lock.release_argv(path, theirs))
      assert File.directory?(path), 'only the holder releases the lock'
      run.call(lock.release_argv(path, mine))
      refute File.exist?(path)
    end
    assert_equal :stale, lock.decide("held age=601 deadline=600\n", fallback_deadline: 9999).state
    assert_equal :held, lock.decide("held age=600 deadline=600\n", fallback_deadline: 1).state
    # A holder that died before writing its line is judged by the run's own deadline.
    assert_equal :stale, lock.decide("held age=31 \n", fallback_deadline: 30).state
    assert_raises(Erx::NetBenchFreebsd::RemoteError) { lock.decide("sh: mkdir: not found\n", fallback_deadline: 30) }
  end
end
