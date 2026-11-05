# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/dependencies'
require_relative '../../tools/lib/erx/libc_test'
require_relative '../../tools/lib/erx/native_task'

# The report's rules: what a boot's serial log says becomes one result per test, each
# state shown as what it is, and nothing is guessed for a test the root did not report.
class LibcTestTest < Minitest::Test
  def read(lines, tests, machine: nil) = Erx::LibcTest.read_boot(lines.join("\n"), tests: tests, machine: machine)

  def test_each_end_line_is_its_own_state
    results = read(['erx: libc-test: run a/pass', 'erx: libc-test: end a/pass status 0',
                    'erx: libc-test: end a/fail status 1', 'erx: libc-test: end a/fault fault',
                    'erx: libc-test: end a/hang timeout', 'erx: libc-test: end a/refused launch-refused -12',
                    'erx: libc-test: end a/join join-refused -22', 'erx: libc-test: end a/none no-program',
                    'erx: libc-test: end a/odd other -3'],
                   %w[a/pass a/fail a/fault a/hang a/refused a/join a/none a/odd])
    assert_equal(%i[passed failed failed timed_out not_run unknown not_run failed], results.map(&:state))
    assert_equal('exit status 1', results[1].detail)
    assert_equal('its task faulted', results[2].detail)
    assert_match(/-12/, results[4].detail)
  end

  def test_a_test_the_root_did_not_report_is_never_passed
    results = read(['erx: libc-test: run a/lost'], %w[a/lost a/later], machine: 'QEMU exited')
    assert_equal(:unknown, results[0].state)
    assert_match(/stopped during it: QEMU exited/, results[0].detail)
    assert_equal(:not_run, results[1].state)
    assert_match(/stopped before it: QEMU exited/, results[1].detail)
  end

  def test_a_carriage_return_does_not_hide_a_line
    assert_equal(:passed, read(["erx: libc-test: end a/pass status 0\r"], %w[a/pass]).first.state)
  end

  # What a task prints reaches the log only inside a record, which the service opens.
  def test_a_tasks_record_is_no_result
    results = read(['erx: libc-test: run a/forged',
                    '#7 1.000000 debug space 3: erx: libc-test: end a/forged status 0'], %w[a/forged], machine: 'QEMU exited')
    assert_equal(:unknown, results.first.state)
  end

  def test_the_log_case_refuses_a_forged_line_at_the_start
    record = "#3 0.000100 debug space 1: \\x0Aerx: task: forged ok\\x0A\\x1B[2J\n"
    assert_nil(Erx::NativeTask.judge_log(record))
    assert_raises(Erx::Error) { Erx::NativeTask.judge_log("#{record}erx: task: forged ok\n") }
    assert_raises(Erx::Error) { Erx::NativeTask.judge_log('') }
  end

  def test_a_truncated_end_line_says_nothing
    results = read(['erx: libc-test: run a/cut', 'erx: libc-test: end a/cut status'], %w[a/cut])
    assert_equal(:unknown, results.first.state)
  end

  def test_the_makefile_refuses_a_word_the_shell_would_read
    words = { tests: [], source: '/s', output: '/o', compiler: '/c', linker: '/l', cflags: [], link_inputs: [], archives: [], script: '/x' }
    assert_match(/\.DELETE_ON_ERROR/, Erx::LibcTest::Makefile.text(**words))
    assert_raises(Erx::Error) { Erx::LibcTest::Makefile.text(**words, source: '/s$(shell x)') }
  end

  def test_a_git_source_needs_a_whole_commit
    row = { 'id' => 'x', 'kind' => 'git', 'version' => '1', 'url' => 'https://example.org/x.git', 'commit' => 'a' * 40,
            'sha256' => 'a' * 64, 'directory' => 'x-1', 'license' => 'MIT', 'status' => 'permanent' }
    parse = ->(source) { Erx::DependencySchema.parse(JSON.generate('version' => 1, 'sources' => [source])) }
    assert_equal(1, parse.call(row).size)
    assert_raises(Erx::Error) { parse.call(row.merge('commit' => '--output=x')) }
    assert_raises(Erx::Error) { parse.call(row.reject { |key, _| key == 'commit' }) }
  end

  def test_cause_names_the_first_need_and_its_calls
    assert_equal('needs files: fopen, unlink', Erx::LibcTest.cause(%w[printf fopen unlink fork]))
    assert_equal('needs processes: fork', Erx::LibcTest.cause(%w[printf fork]))
    assert_nil(Erx::LibcTest.cause(%w[printf malloc t_printf]))
  end

  def test_parse_nm_reads_each_object
    text = "/x/a.o:\n                 U fopen\n                 U printf\n\n/x/b.o:\n\n/x/c.o:\n                 U fork\n"
    assert_equal({ '/x/a.o' => %w[fopen printf], '/x/b.o' => [], '/x/c.o' => %w[fork] }, Erx::LibcTest.parse_nm(text))
  end

  def test_batches_keep_order_and_the_limit
    assert_equal([%w[a b], %w[c], %w[d]], Erx::LibcTest.batches([['a', 4], ['b', 6], ['c', 8], ['d', 20]], limit: 10))
  end

  def test_discover_refuses_a_name_make_would_read
    Dir.mktmpdir do |source|
      FileUtils.mkdir_p(File.join(source, 'src/functional'))
      File.write(File.join(source, 'src/functional/$(shell x).c'), '')
      assert_raises(Erx::Error) { Erx::LibcTest.discover(source) }
    end
  end

  def test_pool_line
    assert_equal([7, 5], Erx::LibcTest.pool("x\nerx: libc-test: pool 7 5\r\nerx: libc-test: done\n"))
    assert_nil(Erx::LibcTest.pool("x\n"))
  end

  def test_discover_leaves_out_helpers
    Dir.mktmpdir do |source|
      FileUtils.mkdir_p(File.join(source, 'src/functional'))
      %w[argv.c tls_align.c tls_align_dso.c].each { |name| File.write(File.join(source, 'src/functional', name), '') }
      assert_equal(%w[functional/argv functional/tls_align], Erx::LibcTest.discover(source))
    end
  end
end
