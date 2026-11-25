# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/bench_suite'
require_relative '../../tools/lib/erx/ipcbench'

# L4Re's importer (docs/design-bench.md, "L4Re's guest"): ipcbench's lines, as its facts
# record gives their format, become one mean cell in cycles per program the comparison
# reads. Every line here is written by erXos in that format, never captured output.
class IpcbenchTest < Minitest::Test
  Ipcbench = Erx::Ipcbench
  Suite = Erx::BenchSuite

  KERNEL = 'sc:single | CPU  0 done 10000 syscalls in 1234567 cpu-cycles, 123 cpu-cycles/syscall'
  SAME = 'ipc:1AS | CPU  0 done 20000 IPCs in 4200000 cpu-cycles, 210 cpu-cycles/IPC'
  CROSS = 'ipc:2AS | CPU  0 done 20000 IPCs in 9000001 cpu-cycles, 450 cpu-cycles/IPC'

  def cell(operation) = Suite::LandingCell.new(operation: operation, load: 'idle', placement: 'same-cpu', parameters: {})

  def asked = %w[kernel root-same-space root-cross-space].map { |operation| cell(operation) }

  def import(lines) = Ipcbench.import(lines, benchmark: 'nullcall', cells: asked)

  def by_operation(lines) = import(lines).fetch(:cells).to_h { |result| [result.operation, result] }

  def test_each_program_result_is_a_mean_over_its_calls_in_cycles
    cells = by_operation(['Syscall benchmark:', KERNEL, SAME, CROSS, 'Benchmarks done.'])
    kernel = cells.fetch('kernel')
    assert_equal ['measured', 'mean', 'cycles', 1], [kernel.status, kernel.form, kernel.conditions.clock,
                                                     kernel.conditions.batch]
    assert_equal({ 'count' => 10_000, 'total' => 1_234_567, 'mean' => 123 }, kernel.detail)
    # An IPC program counts a call's request and reply as two IPCs: the cell holds the
    # 10,000 calls, the total and the printed mean, half a round trip.
    assert_equal({ 'count' => 10_000, 'total' => 4_200_000, 'mean' => 210 }, cells.fetch('root-same-space').detail)
    assert_equal({ 'count' => 10_000, 'total' => 9_000_001, 'mean' => 450 }, cells.fetch('root-cross-space').detail)
    assert_empty import([KERNEL, SAME, CROSS]).fetch(:refused)
  end

  def test_lines_of_programs_the_comparison_does_not_read_are_ignored
    parallel = 'ipc:PL | CPU  1 done 20000 IPCs in 5 cpu-cycles, 7 cpu-cycles/IPC'
    result = import(['ipc:PL | Found 4 CPUs. Measuring core-local IPC latency on all CPUs.', parallel, KERNEL, SAME, CROSS])
    assert_equal %w[measured] * 3, result.fetch(:cells).map(&:status)
    assert_empty result.fetch(:refused)
  end

  def test_a_count_other_than_the_programs_calls_is_rejected
    cells = by_operation([KERNEL.sub('10000 syscalls', '10001 syscalls'), SAME.sub('20000', '10000'), CROSS])
    assert_equal %w[rejected rejected measured], cells.values_at('kernel', 'root-same-space', 'root-cross-space').map(&:status)
    assert_empty cells.fetch('kernel').detail
  end

  def test_a_mean_that_is_not_the_truncated_quotient_is_rejected
    cells = by_operation([KERNEL.sub(', 123 ', ', 124 '), SAME, CROSS])
    assert_equal 'rejected', cells.fetch('kernel').status
  end

  def test_a_result_in_another_programs_word_is_rejected
    cells = by_operation([KERNEL.sub('syscalls in', 'IPCs in'), SAME.sub('cpu-cycles/IPC', 'cpu-cycles/syscall'), CROSS])
    assert_equal %w[rejected rejected], cells.values_at('kernel', 'root-same-space').map(&:status)
  end

  def test_an_error_line_fails_its_program
    cells = by_operation([KERNEL, 'ipc:1AS | caller: ipc err', SAME, 'ipc:2AS | IPC error -3'])
    assert_equal %w[measured failed failed], cells.values_at('kernel', 'root-same-space', 'root-cross-space').map(&:status)
    assert_match(/ipc:1AS/, cells.fetch('root-same-space').reason)
  end

  def test_a_program_no_line_reports_is_not_run
    cells = by_operation([KERNEL])
    assert_equal %w[measured not_run not_run], cells.values_at('kernel', 'root-same-space', 'root-cross-space').map(&:status)
  end

  def test_a_second_result_of_one_program_is_rejected
    assert_equal 'rejected', by_operation([KERNEL, KERNEL, SAME, CROSS]).fetch('kernel').status
  end

  def test_an_unreadable_line_of_a_read_program_is_rejected_and_refused_escaped
    result = import([KERNEL, "ipc:1AS | CPU  0 done \e]0;title\a 20000 IPCs", SAME, CROSS])
    assert_equal 'rejected', result.fetch(:cells).find { |each| each.operation == 'root-same-space' }.status
    refused = result.fetch(:refused)
    assert_equal 1, refused.size
    refute_match(/[\x00-\x1f\x7f]/, refused.first)
  end

  def test_a_total_beyond_sixty_four_bits_or_a_long_line_is_rejected
    huge = KERNEL.sub('1234567', (2**64).to_s).sub(', 123 ', ", #{2**64 / 10_000} ")
    assert_equal 'rejected', by_operation([huge, SAME, CROSS]).fetch('kernel').status
    long = SAME.sub('CPU  0', "CPU#{' ' * Ipcbench::MAX_LINE}0")
    assert_equal 'rejected', by_operation([KERNEL, long, CROSS]).fetch('root-same-space').status
  end

  # A counter that did not count prints a total of zero, which is no measurement.
  def test_a_total_of_zero_is_rejected
    zero = 'sc:single | CPU  0 done 10000 syscalls in 0 cpu-cycles, 0 cpu-cycles/syscall'
    assert_equal 'rejected', by_operation([zero, SAME, CROSS]).fetch('kernel').status
  end

  def test_an_unreadable_line_outranks_an_error_line
    cells = by_operation([KERNEL, 'ipc:1AS | caller: ipc err', 'ipc:1AS | ??', CROSS])
    assert_equal 'rejected', cells.fetch('root-same-space').status
  end

  # A program is set beside one benchmark's operation, not any operation of its name.
  def test_another_benchmarks_operation_of_the_same_name_is_not_run
    result = Ipcbench.import([KERNEL], benchmark: 'vm', cells: [cell('kernel')])
    assert_equal %w[not_run], result.fetch(:cells).map(&:status)
  end

  def test_an_operation_ipcbench_has_no_program_for_is_not_run
    result = Ipcbench.import([KERNEL], benchmark: 'nullcall', cells: [cell('kernel'), cell('other')])
    assert_equal %w[measured not_run], result.fetch(:cells).map(&:status)
  end

  def test_the_line_reader_names_each_kind_of_line
    assert_nil Ipcbench.read_line('Benchmarks done.')
    assert_nil Ipcbench.read_line('sc:PL | CPU  1 done 10000 syscalls in 9 cpu-cycles, 0 cpu-cycles/syscall')
    result = Ipcbench.read_line(SAME)
    assert_equal ['ipc:1AS', :result, 20_000, 4_200_000, 210], [result.tag, result.kind, result.count, result.total, result.mean]
    assert_equal :error, Ipcbench.read_line('ipc:2AS | IPC error').kind
    assert_equal :unreadable, Ipcbench.read_line("sc:single | \xff".b).kind
  end
end
