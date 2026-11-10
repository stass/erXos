# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require_relative '../../tools/lib/erx/net_bench_p620'

# What the network benchmarks read from a client's output and print (tools/lib/erx/net_bench.rb),
# and the one place a remote command string is built (Erx::NetBenchP620::Remote). Nothing connects
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

  def run_of(stack, workload_name, output)
    result, counters = NB::Output.parse(output)
    workload = NB::WORKLOADS.find { |w| w.name == workload_name }
    NB::Run.new(stack: stack, workload: workload, result: result, counters: counters, rusage: NB::TimeReport.parse(output))
  end

  def test_a_run_is_read_from_its_result_counters_and_time_report
    run = run_of('erx_net', 'bulk-send', BULK)
    assert_equal 900.1, run.metric
    assert_equal({ 'no_route' => 3, 'ingress' => 12 }, run.counters)
    assert_equal [6_100_000, 123, 23.5], [run.rusage.voluntary, run.rusage.involuntary, run.rusage.cpu]
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
                             planned: 3)
    assert_equal 'host: FreeBSD<U+001B>]0;x<U+0007>', lines.first
    assert(lines.any? { |line| line.start_with?('bulk-send') && line.include?('erx_net/lwip') && line.end_with?('0.136') })
    # A cell whose runs failed says how many it is the median of.
    assert(lines.any? { |line| line.start_with?('bulk-send') && line.match?(/erx_net\s+1\/3\s/) })
    assert(lines.any? { |line| line.start_with?('bulk-send') && line.match?(/lwip\s+3\/3\s/) })
    assert(lines.any? { |line| line.start_with?('bulk-recv') && line.end_with?('missing') })
    assert(lines.any? { |line| line.include?('bulk-send lwip: frames per run: unsupported (reporter: lwip_bench') })
  end

  def test_the_median_run_is_the_middle_one_by_its_metric
    runs = [900.0, 100.0, 500.0].map { |mbit| run_of('erx_net', 'bulk-send', BULK.sub('900.1', mbit.to_s)) }
    assert_equal [500.0, 3], [NB.median(runs).run.metric, NB.median(runs).count]
  end

  def test_a_remote_command_is_one_quoted_string_and_refuses_what_tcsh_would_expand
    remote = Erx::NetBenchP620::Remote.new(host: 'p620.example')
    # The login shell strips one level of quotes; sh then reads the words back as given.
    text, = Open3.capture2e('sh', '-c', remote.command_string(['echo', 'a  b', "it's"]))
    assert_equal "a  b it's\n", text
    assert_raises(Erx::NetBenchP620::RemoteError) { remote.command_string(['echo', '!!']) }
    assert_raises(Erx::NetBenchP620::RemoteError) { remote.command_string(['echo', "a\nb"]) }
    assert_raises(ArgumentError) { Erx::NetBenchP620::Remote.new(host: '-oProxyCommand=x') }
  end
end
