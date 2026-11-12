# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/conformance'

class ConformanceTest < Minitest::Test
  C = Erx::Conformance
  PLATFORM = Erx::Platform.development(File.expand_path('../..', __dir__))

  def setup
    @directory = Dir.mktmpdir('erx-conformance-')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def roster(text = "case alpha 1\ncase beta 1\npending gamma 5\n") = C.roster(text, path: 'roster.txt')

  def report(lines) = C.report(lines.map { |line| "#{line}\n" }.join)

  def test_roster_declares_cases_and_pending_cases
    cases = roster("# comment\n\ncase alpha 3\npending gamma 5\n")
    assert_equal [%w[alpha 3 false], %w[gamma 5 true]],
                 cases.map { |entry| [entry.name, entry.seconds.to_s, entry.pending.to_s] }
    ["case Alpha 1\n", "case alpha 0\n", "case alpha\n", "run alpha 1\n", "case a;rm 1\n",
     "case alpha 1\ncase alpha 2\n"].each do |text|
      assert_raises(Erx::Error) { C.roster(text, path: 'roster.txt') }
    end
  end

  def test_report_reads_only_protocol_lines
    parsed = report(['kernel noise erx-test: case alpha failed', 'erx-test: case alpha passed',
                     "erx-test: case beta skipped\r", 'erx-test: end 2'])
    assert_equal({ 'alpha' => 'passed', 'beta' => 'skipped' }, parsed.results)
    assert_equal 2, parsed.ended
    assert_empty parsed.errors
  end

  def test_report_refuses_malformed_repeated_late_and_miscounted_lines
    parsed = report(['erx-test: case alpha passed', 'erx-test: case alpha failed', "erx-test: case beta \e]0;x",
                     'erx-test: end 3', 'erx-test: case late passed'])
    assert_equal 4, parsed.errors.size
    assert(parsed.errors.none? { |error| error.include?("\e") }, 'guest bytes must reach diagnostics escaped')
    assert_match(/reported twice/, parsed.errors[0])
    assert_match(/malformed/, parsed.errors[1])
    assert_match(/after the end line/, parsed.errors[2])
    assert_match(/counts 3 cases, guest reported 1/, parsed.errors[3])
  end

  def test_natural_exit_with_every_case_passed_passes
    verdict = C.verdict(roster, report(['erx-test: case alpha passed', 'erx-test: case beta passed',
                                        'erx-test: end 2']), ending: :exited)
    assert_equal 'passed', verdict.fetch('status')
    assert_equal({ 'alpha' => 'passed', 'beta' => 'passed', 'gamma' => 'pending' }, verdict.fetch('cases'))
  end

  def test_an_omitted_case_fails_the_configuration
    verdict = C.verdict(roster, report(['erx-test: case alpha passed', 'erx-test: end 1']), ending: :exited)
    assert_equal 'failed', verdict.fetch('status')
    assert_equal 'omitted', verdict.fetch('cases').fetch('beta')
  end

  def test_a_report_that_never_ended_is_partial_and_its_missing_cases_unknown
    verdict = C.verdict(roster, report(['erx-test: case alpha passed']), ending: :exited)
    assert_equal 'partial', verdict.fetch('status')
    assert_equal 'unknown', verdict.fetch('cases').fetch('beta')
  end

  def test_a_killed_guest_is_timed_out_and_keeps_only_what_it_reported
    verdict = C.verdict(roster, report(['erx-test: case alpha failed', 'erx-test: end 1']), ending: :killed)
    assert_equal 'timed_out', verdict.fetch('status')
    assert_equal({ 'alpha' => 'failed', 'beta' => 'unknown', 'gamma' => 'pending' }, verdict.fetch('cases'))
  end

  def test_qemu_failure_unsupported_hosts_and_unexpected_cases
    assert_equal 'failed', C.verdict(roster, C::EMPTY_REPORT, ending: :failed).fetch('status')
    unsupported = C.verdict(roster, C::EMPTY_REPORT, ending: :unsupported)
    assert_equal 'unsupported', unsupported.fetch('status')
    assert_equal %w[unsupported unsupported pending], unsupported.fetch('cases').values
    verdict = C.verdict(roster, report(['erx-test: case alpha passed', 'erx-test: case beta passed',
                                        'erx-test: case gamma passed', 'erx-test: end 3']), ending: :exited)
    assert_equal 'failed', verdict.fetch('status')
    assert_match(/does not run: gamma/, verdict.fetch('errors').join)
  end

  def test_a_guest_that_skips_every_case_does_not_pass
    verdict = C.verdict(roster, report(['erx-test: case alpha skipped', 'erx-test: case beta skipped',
                                        'erx-test: end 2']), ending: :exited)
    assert_equal 'partial', verdict.fetch('status')
    assert_equal 'incomplete', C.overall([verdict.fetch('status')])
  end

  def test_repeated_configurations_and_overlong_deadlines_are_refused
    program, = fake_qemu(serial: '')
    run = C::Run.new(root: @directory, program: program, platform: PLATFORM)
    error = assert_raises(Erx::Error) { run.run(image: image, roster: roster, configs: [C::MATRIX[0]] * 2) }
    assert_match(/repeated/, error.message)
    long = C.roster((1..25).map { |index| "case c#{index} 3600\n" }.join, path: 'roster.txt')
    error = assert_raises(Erx::Error) { run.run(image: image, roster: long, configs: C::MATRIX.first(1)) }
    assert_match(/exceed/, error.message)
  end

  def test_overall_status_never_passes_an_incomplete_matrix
    assert_equal 'passed', C.overall(%w[passed passed])
    assert_equal 'failed', C.overall(%w[passed failed unsupported])
    assert_equal 'incomplete', C.overall(%w[passed unsupported])
    assert_equal 'incomplete', C.overall(%w[passed timed_out])
    assert_equal 'incomplete', C.overall([])
  end

  # A stand-in for qemu-system-aarch64: it answers the version and
  # accelerator probes, writes its serial output, then exits with status or
  # hangs with a grandchild in its process group.
  def fake_qemu(serial:, status: 0, hang: false, accelerators: %w[tcg hvf])
    path = File.join(@directory, 'fake-qemu')
    pids = File.join(@directory, 'pids')
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      if ARGV.include?('--version')
        puts 'QEMU emulator version 11.1.3 (fixture)'
        exit 0
      end
      if ARGV.include?('help')
        puts 'Accelerators supported in QEMU binary:'
        puts #{accelerators.inspect}
        exit 0
      end
      raise 'no -no-reboot' unless ARGV.include?('-no-reboot')
      File.binwrite(ARGV.fetch(ARGV.index('-serial') + 1).delete_prefix('file:'), #{serial.dump})
      if #{hang}
        child = Process.spawn('sleep', '600')
        File.open(#{pids.dump}, 'a') { |file| file.puts(Process.pid, child) }
        sleep 600
      end
      exit #{status}
    RUBY
    File.chmod(0o700, path)
    [path, pids]
  end

  def image
    path = File.join(@directory, 'image.elf')
    File.write(path, 'fixture image')
    path
  end

  def run_matrix(program, configs: C::MATRIX.first(1))
    C::Run.new(root: @directory, program: program, boot_seconds: 1, platform: PLATFORM)
     .run(image: image, roster: roster, configs: configs)
  end

  def test_a_guest_that_exits_after_its_report_passes
    program, = fake_qemu(serial: "boot\nerx-test: case alpha passed\nerx-test: case beta passed\nerx-test: end 2\n")
    matrix = run_matrix(program)
    assert_equal 'passed', matrix.fetch('status')
    configuration = matrix.fetch('configurations').first
    assert_equal %w[passed exited], configuration.values_at('status', 'ending')
    assert File.file?(matrix.fetch('matrix'))
    assert_match(/\Aalpha +passed/, C.table(matrix)[1])
  end

  def test_a_guest_exiting_with_an_error_fails_even_after_a_good_report
    program, = fake_qemu(serial: "erx-test: case alpha passed\nerx-test: case beta passed\nerx-test: end 2\n",
                         status: 3)
    configuration = run_matrix(program).fetch('configurations').first
    assert_equal %w[failed failed], configuration.values_at('status', 'ending')
  end

  def test_a_hung_guest_is_killed_at_its_deadline_with_its_process_group
    program, pids = fake_qemu(serial: "erx-test: case alpha passed\n", hang: true)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    matrix = run_matrix(program)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    configuration = matrix.fetch('configurations').first
    assert_equal %w[timed_out killed], configuration.values_at('status', 'ending')
    assert_equal({ 'alpha' => 'passed', 'beta' => 'unknown', 'gamma' => 'pending' }, configuration.fetch('cases'))
    assert_equal 3, configuration.fetch('deadline_seconds')
    assert_operator elapsed, :<, 15
    File.readlines(pids).map(&:to_i).each do |pid|
      assert_raises(Errno::ESRCH, "process #{pid} survived the guest") { Process.kill(0, pid) }
    end
  end

  def test_a_host_without_the_accelerator_reports_unsupported
    program, = fake_qemu(serial: "erx-test: case alpha passed\nerx-test: case beta passed\nerx-test: end 2\n",
                         accelerators: %w[tcg])
    matrix = run_matrix(program, configs: C::MATRIX)
    assert_equal %w[unsupported unsupported],
                 matrix.fetch('configurations').map { |entry| entry.fetch('status') }
    assert_equal 'incomplete', matrix.fetch('status')
  end

  def test_a_roster_with_nothing_to_run_is_refused
    program, = fake_qemu(serial: '')
    error = assert_raises(Erx::Error) do
      C::Run.new(root: @directory, program: program, platform: PLATFORM).run(image: image, roster: roster("pending alpha 1\n"))
    end
    assert_match(/no case to run/, error.message)
  end

  def test_the_checked_in_roster_parses
    path = File.expand_path('../conformance/roster.txt', __dir__)
    C.roster(File.read(path), path: path)
  end
end
