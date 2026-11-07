# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
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

  # A record of erx_debug_log opens with the service's words, so it is no result.
  def test_a_tasks_record_is_no_result
    results = read(['erx: libc-test: run a/forged',
                    '#7 1.000000 debug space 3: erx: libc-test: end a/forged status 0'], %w[a/forged], machine: 'QEMU exited')
    assert_equal(:unknown, results.first.state)
  end

  # A program with TLS data, zeroed TLS and a global offset table entry: musl sizes each
  # thread's TLS from this segment, so it must hold both TLS sections and nothing else.
  TLS_PROGRAM = <<~C
    __thread char data = 1;
    __thread char zeroed[4096] __attribute__((aligned(4096)));
    extern char absent __attribute__((weak));
    void _start(void) { zeroed[0] = data + (&absent != 0); }
  C

  # Links TLS_PROGRAM and extra through script: yields the program's path, what the linker said and its status.
  def link_tls_program(script, link_flags: [], extra: '')
    compiler, linker = ENV.values_at('ERX_CLANG', 'ERX_LLD')
    skip('set ERX_CLANG and ERX_LLD') if compiler.to_s.empty? || linker.to_s.empty?

    Dir.mktmpdir do |directory|
      source, object, program = %w[tls.c tls.o tls.elf].map { |name| File.join(directory, name) }
      File.write(source, TLS_PROGRAM + extra)
      assert(system(compiler, '--target=aarch64-none-elf', '-O1', '-fPIC', '-ffreestanding', '-c', source, '-o', object))
      said, status = Open3.capture2e(linker, '-T', script, *link_flags, '-z', 'max-page-size=4096', '-o', program, object)
      yield program, said, status
    end
  end

  def tls_segment(script, link_flags: [])
    link_tls_program(script, link_flags: link_flags) do |program, said, status|
      assert(status.success?, said)
      headers = File.binread(program)
      offset, = headers.unpack('@32Q<')
      size, count = headers.unpack('@54S<S<')
      fields = count.times.map { |index| headers.unpack("@#{offset + index * size}L<L<Q<Q<Q<Q<Q<Q<") }
      fields.find { |type, *| type == 7 }
    end
  end

  def test_each_link_script_keeps_the_tls_segment_whole
    %w[task.ld root.ld].each do |script|
      flags = script == 'task.ld' ? Erx::NativeRoot::TASK_LINK_FLAGS : Erx::NativeRoot.place_flags(Erx::NativeRoot::PLACE)
      segment = tls_segment(File.expand_path("../../liberx/backend/fiasco/#{script}", __dir__), link_flags: flags)
      start, file_bytes, memory_bytes, alignment = segment.values_at(3, 5, 6, 7)
      assert_equal([1, 4096], [file_bytes, alignment], "#{script}: file bytes and alignment")
      # The zeroed array fills the page after the data's, wherever the data landed in its own.
      assert_equal((start | 4095) + 1 + 4096, start + memory_bytes, "#{script}: the end of the zeroed array")
    end
  end

  # A task's output lies between the root's lines as the program wrote it. With no
  # final newline, the newline that opens the root's end line keeps the result whole.
  def test_output_with_no_final_newline_keeps_its_result
    results = read(['erx: libc-test: run a/text', "no final newline\t\e[2J\xFF\r", 'erx: libc-test: end a/text status 0'], %w[a/text])
    assert_equal(:passed, results.first.state)
  end

  def test_a_line_glued_to_output_is_no_result
    results = read(['erx: libc-test: run a/glued', 'no final newlineerx: libc-test: end a/glued status 0'], %w[a/glued], machine: 'QEMU exited')
    assert_equal(:unknown, results.first.state)
  end

  def test_the_libc_test_root_opens_its_end_line_with_a_newline
    guest = File.read(File.expand_path('../guest/native_libc_test/guest.c', __dir__))
    assert_match(/say\("\\n"\);\n\s*say_line_start\("end"/, guest)
  end

  def test_the_roots_end_line_outweighs_a_line_the_test_printed
    results = read(['erx: libc-test: run a/forged', 'erx: libc-test: end a/forged status 0', 'erx: libc-test: end a/forged status 1'], %w[a/forged])
    assert_equal(:failed, results.first.state)
  end

  # The limit of trusting test programs (docs/design-stopgap.md, "musl's own tests").
  def test_a_printed_line_with_no_end_from_the_root_can_fool_the_runner
    results = read(['erx: libc-test: run a/forged', 'erx: libc-test: end a/forged status 0'], %w[a/forged], machine: 'QEMU exited')
    assert_equal(:passed, results.first.state)
  end

  def test_a_printed_line_can_rewrite_an_earlier_tests_result
    results = read(['erx: libc-test: end a/earlier status 1', 'erx: libc-test: run a/later',
                    'erx: libc-test: end a/earlier status 0', 'erx: libc-test: end a/later status 0'], %w[a/earlier a/later])
    assert_equal(%i[passed passed], results.map(&:state))
  end

  def test_the_write_case_needs_every_byte_as_written
    whole = Erx::NativeTask::WRITE_BYTES.gsub("\n", "\r\n")
    assert_nil(Erx::NativeTask.judge_write("erx: task: status 0\r\n#{whole}erx: task: write ok\r\n".b))
    assert_raises(Erx::Error) { Erx::NativeTask.judge_write(whole.sub("\e", '\\x1B')) }
    assert_raises(Erx::Error) { Erx::NativeTask.judge_write(whole.sub("\t", '\\x09')) }
    assert_raises(Erx::Error) { Erx::NativeTask.judge_write(whole.byteslice(0, 800)) }
    assert_raises(Erx::Error) { Erx::NativeTask.judge_write('') }
  end

  def test_the_log_case_refuses_a_forged_line_at_the_start
    record = "#3 0.000100 debug space 1: \\x0Aerx: task: forged ok\\x0A\\x1B[2J\n"
    assert_nil(Erx::NativeTask.judge_log(record))
    assert_raises(Erx::Error) { Erx::NativeTask.judge_log("#{record}erx: task: forged ok\n") }
    assert_raises(Erx::Error) { Erx::NativeTask.judge_log('') }
  end

  def test_the_canary_holds_only_a_whole_pass
    size = Erx::LibcTest::CANARY.size
    assert_empty(Erx::LibcTest.canary_problems(canary_outcome({ passed: size })))
    refute_empty(Erx::LibcTest.canary_problems(canary_outcome({ passed: size - 1, failed: 1 })))
    refute_empty(Erx::LibcTest.canary_problems(canary_outcome({ passed: size - 1, not_run: 1 })))
    refute_empty(Erx::LibcTest.canary_problems(canary_outcome({ passed: size - 1 })))
    refute_empty(Erx::LibcTest.canary_problems(canary_outcome({ passed: size }, leaks: [0])))
  end

  def test_the_canary_fails_on_an_unknown_pool
    problems = Erx::LibcTest.canary_problems(canary_outcome({ passed: Erx::LibcTest::CANARY.size }, unknown: [1]))
    assert_equal(['pool unknown in boots [1]'], problems)
  end

  def canary_outcome(totals, leaks: [], unknown: [])
    { totals: totals, pool_problems: Erx::LibcTest.pool_problems(leaks: leaks, unknown: unknown) }
  end

  def test_a_truncated_end_line_says_nothing
    results = read(['erx: libc-test: run a/cut', 'erx: libc-test: end a/cut status'], %w[a/cut])
    assert_equal(:unknown, results.first.state)
  end

  # A writable section after .tbss would shrink every thread's TLS, so a task's link refuses it.
  def test_a_tasks_link_refuses_a_section_the_script_does_not_name
    stray = "__attribute__((section(\".stray\"))) int stray = 1;\n"
    script = File.expand_path('../../liberx/backend/fiasco/task.ld', __dir__)
    link_tls_program(script, extra: stray) { |_, said, status| assert(status.success?, said) }
    link_tls_program(script, link_flags: Erx::NativeRoot::TASK_LINK_FLAGS, extra: stray) do |_, said, status|
      refute(status.success?, 'the stray section linked')
      assert_match(/\.stray/, said)
    end
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

  def test_memfill_and_statvfs_are_needs
    assert_equal('needs resource limits: t_memfill', Erx::LibcTest.cause(%w[t_memfill malloc]))
    assert_equal('needs files: statvfs', Erx::LibcTest.cause(%w[statvfs]))
  end

  def result(name, state, detail = nil) = Erx::LibcTest::Result.new(name: name, state: state, detail: detail)

  VERDICTS = <<~TABLE
    # a comment
    a/cancel  timed_out stopgap    blocked calls are not interrupted
    a/regex   failed    upstream   at=regex.c:14,regex.c:9 musl's matcher
    a/files   not_run   cannot-run needs files
  TABLE

  def test_the_checked_in_verdicts_parse_and_name_tests
    root = File.expand_path('../..', __dir__)
    verdicts = Erx::LibcTest.load_verdicts(root)
    refute_empty(verdicts)
    assert(verdicts.values.all? { |verdict| verdict.name.match?(Erx::LibcTest::TEST_NAME) })
  end

  def test_results_that_match_their_verdicts_agree
    verdicts = Erx::LibcTest.parse_verdicts(VERDICTS)
    results = [result('a/cancel', :timed_out), result('a/regex', :failed, 'exit status 1').with(at: %w[regex.c:14 regex.c:9]),
               result('a/files', :not_run, 'needs files: tmpfile'), result('a/plain', :passed)]
    assert_empty(Erx::LibcTest.disagreements(results, verdicts: verdicts, complete: true))
  end

  def test_every_difference_from_a_verdict_is_reported
    verdicts = Erx::LibcTest.parse_verdicts(VERDICTS)
    results = [result('a/cancel', :passed), result('a/regex', :timed_out, 'still running'),
               result('a/files', :not_run, 'the machine stopped before it: hung'), result('a/plain', :failed, 'exit status 1')]
    problems = Erx::LibcTest.disagreements(results, verdicts: verdicts, complete: true)
    assert_equal(4, problems.size, problems.inspect)
    assert_match(%r{\Aa/files: not run because the machine stopped}, problems[2])
  end

  # A failed test is held to the places it reports, so a new failure in a
  # half of the test that passed before is caught.
  def test_a_failure_at_a_place_its_verdict_does_not_list_is_reported
    verdicts = Erx::LibcTest.parse_verdicts(VERDICTS)
    results = [result('a/cancel', :timed_out), result('a/regex', :failed, 'exit status 1').with(at: %w[regex.c:14 regex.c:30 regex.c:9]),
               result('a/files', :not_run, 'needs files: tmpfile')]
    problems = Erx::LibcTest.disagreements(results, verdicts: verdicts, complete: true)
    assert_equal(['a/regex: fails at regex.c:14,regex.c:30,regex.c:9, its verdict says at regex.c:14,regex.c:9'], problems)
  end

  def test_a_tests_error_places_are_read_from_its_own_output_only
    results = read(['erx: libc-test: run a/one', 'X /b/src/math/ucb/powf.h:103: bad fp exception',
                    '/b/src/functional/one.c:42: f() failed', '/b/src/functional/one.c:42: f() failed',
                    'erx: libc-test: end a/one status 1', '/b/src/functional/stray.c:7: after the end',
                    'erx: libc-test: run a/two', 'erx: libc-test: end a/two status 0'], %w[a/one a/two])
    assert_equal([%w[one.c:42 powf.h:103], []], results.map(&:at))
  end

  def outcome(results, leaks: [], unknown: [])
    { results: results, pool_problems: Erx::LibcTest.pool_problems(leaks: leaks, unknown: unknown) }
  end

  def test_check_libc_test_fails_on_a_disagreement_a_leak_and_an_unknown_pool
    verdicts = Erx::LibcTest.parse_verdicts(VERDICTS)
    good = [result('a/cancel', :timed_out), result('a/regex', :failed, 'exit status 1').with(at: %w[regex.c:14 regex.c:9]),
            result('a/files', :not_run, 'needs files: tmpfile')]
    assert_empty(Erx::LibcTest.check_problems(outcome(good), verdicts: verdicts))
    assert_equal(['a/plain: failed (exit status 1), its verdict says passed'],
                 Erx::LibcTest.check_problems(outcome([*good, result('a/plain', :failed, 'exit status 1')]), verdicts: verdicts))
    assert_equal(['pool leaks in boots [2]'], Erx::LibcTest.check_problems(outcome(good, leaks: [2]), verdicts: verdicts))
    assert_equal(['pool unknown in boots [0]'], Erx::LibcTest.check_problems(outcome(good, unknown: [0]), verdicts: verdicts))
  end

  def test_an_unknown_result_never_agrees
    problems = Erx::LibcTest.disagreements([result('a/plain', :unknown, 'x')], verdicts: {}, complete: false)
    assert_equal(1, problems.size)
  end

  def test_a_verdict_for_no_test_is_stale_only_in_a_whole_run
    verdicts = Erx::LibcTest.parse_verdicts(VERDICTS)
    results = [result('a/cancel', :timed_out)]
    assert_empty(Erx::LibcTest.disagreements(results, verdicts: verdicts, complete: false))
    assert_equal(2, Erx::LibcTest.disagreements(results, verdicts: verdicts, complete: true).size)
  end

  def test_a_malformed_verdict_is_refused
    ['a/x passed upstream why', 'a/x failed guess why', 'a/x not_run upstream needs files',
     'a/x failed cannot-run needs files', 'a/x not_run cannot-run the shell', 'A x failed upstream why', 'a/x failed',
     "a/x failed upstream one\na/x failed upstream two", 'a/x failed upstream why', 'a/x failed upstream at=x.c:9,x.c:10 why',
     'a/x failed upstream at=x.c why', 'a/x timed_out stopgap at=x.c:1 why'].each do |text|
      assert_raises(Erx::Error, text) { Erx::LibcTest.parse_verdicts(text) }
    end
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

  # OTP links a tool with the archives ahead of its objects, so what an early libc reference
  # pulls in from the archive comes before the tool's own main. Every stdio call reaches the
  # root's write: were its member to reach the start path, that would bring runtime_main.c's
  # main and collide with the tool's, as yielding_c_fun's link did. So it needs the console alone.
  def test_the_root_write_member_needs_only_the_console
    compiler = ENV.fetch('ERX_CLANG', '')
    skip 'set ERX_CLANG to the installed LLVM clang' if compiler.empty?

    root = File.expand_path('../..', __dir__)
    source = Erx::NativeRoot::SYSTEM.find do |path|
      path.end_with?('.c') && File.read(File.join(root, path)).match?(/^erx_fiasco_libc_write\(/)
    end
    Dir.mktmpdir('erx-root-write-') do |directory|
      object = File.join(directory, 'write.o')
      assert system(compiler, *Erx::NativeRoot::FLAGS, '-c', source, '-o', object, chdir: root), "#{source} compiles"
      nm = File.join(File.dirname(compiler), 'llvm-nm')
      undefined = IO.popen([nm, '--undefined-only', '--format=just-symbols', object], &:read).split
      assert_equal %w[erx_fiasco_console_write], undefined, "what #{source} makes the link pull in"
    end
  end
end
