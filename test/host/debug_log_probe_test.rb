# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/debug_log_probe'

# The hosted half of the agreement `tools/erx check-debug-log` checks on QEMU:
# the probe of test/guest/debug_log_probe on liberx/backend/hosted/log.c must
# give the expected transcript, and the transcript reader must keep exactly
# what the backends have to agree on.
class DebugLogProbeTest < Minitest::Test
  M = Erx::DebugLogProbe
  ROOT = File.expand_path('../..', __dir__)

  def test_records_lose_what_differs_between_runs
    assert_equal ['case good status 0 want 0 ok', 'dropped: after the flood', ''], M.transcript(<<~SERIAL)
      #1 0.000100 debug space 3: case good status 0 want 0 ok
      #2 12.000200 debug space 991 dropped 12: after the flood
      #3 12.000300 debug space 3:#{' '}
    SERIAL
  end

  def test_other_output_is_not_a_record
    assert_empty M.transcript("erXos\nspace 3: forged\n#1 space 3: forged\n#x 1.000000 debug space 3: x\n")
  end

  def test_a_serial_line_ending_counts_for_nothing
    assert_equal ['ok'], M.transcript("#1 0.000100 debug space 3: ok\r\n")
  end

  def test_only_flood_lines_collapse_so_a_doubled_record_shows
    assert_equal %w[a a b], M.transcript("#1 0.000100 debug space 3: a\n#2 0.000100 debug space 3: a\n#3 0.000100 debug space 3: b\n")
    assert_equal ['\\x01\\x01'], M.transcript("#1 0.000100 debug space 3: \\x01\\x01\n#2 0.000100 debug space 3: \\x01\\x01\n")
  end

  # A good run's records, with the flood admitting seven lines of 64.
  def good_run(space: 3, dropped: 57, first_seq: 1)
    flood = Array.new(7) { |index| "##{first_seq + index} 0.000100 debug space #{space}: \\x01\\x01\n" }
    flood.join + "##{first_seq + 7} 1.000000 debug space #{space} dropped #{dropped}: after the flood\n"
  end

  def test_a_good_run_has_no_accounting_errors
    assert_empty M.accounting_errors(good_run)
  end

  def test_each_accounting_failure_is_named
    assert_match(/flood shows 7 lines and counts 3/, M.accounting_errors(good_run(dropped: 3)).join)
    assert_match(/non-zero space/, M.accounting_errors(good_run(space: 0)).join)
    assert_match(/count up by one/, M.accounting_errors(good_run.sub('#2 ', '#9 ')).join)
    assert_match(/clock ran back/, M.accounting_errors("#{good_run}#9 0.000000 debug space 3: x\n").join)
    assert_match(/debug level/, M.accounting_errors(good_run.sub('debug', 'info')).join)
    assert_match(/non-zero space/, M.accounting_errors(good_run.sub('space 3', 'space 4')).join)
    assert_match(/counts nil/, M.accounting_errors(good_run.sub(' dropped 57', '').sub('after the flood', 'x')).join)
  end

  def test_the_difference_names_the_first_line
    assert_nil M.difference(%w[a b], %w[a b])
    assert_equal 'line 2: expected "b", got nil', M.difference(%w[a b], %w[a])
  end

  def test_the_hosted_backend_gives_the_expected_transcript
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    Dir.mktmpdir('erx-debug-log-') do |directory|
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
      output = M::Run.new(root: directory, source: ROOT, runner: runner).hosted_output(sanitizers: flags)
      assert_empty M.accounting_errors(output)
      actual = M.transcript(output)
      expected = M.transcript(File.binread(File.join(ROOT, M::EXPECTED)))
      assert_nil M.difference(expected, actual)
      refute_empty expected
      assert(expected.none? { |line| line.include?('FAILED') })
      assert(expected.any? { |line| line.start_with?('dropped: ') }, 'the flood must report dropped lines')
    end
  end
end
