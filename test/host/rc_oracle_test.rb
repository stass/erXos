# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/lib/erx/rc_oracle'

# The oracle runner's rules, against a stand-in for rc: what rc writes comes
# back as bytes, the final $status only from rc's own report, a deadline kill
# as timed out, and a missing or stale build as a typed error. The real rc
# runs in test/integration/rc_oracle_test.rb, which needs plan9port fetched.
class RcOracleTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  # The stand-in reads the script that the runner's `-c` command sources and
  # obeys one directive per line; `report` writes a status report on
  # descriptor 3 as the runner's exit trap does.
  FAKE_RC = <<~RUBY
    #!#{RbConfig.ruby} --disable-gems
    # frozen_string_literal: true
    require 'json'
    $stdout.sync = true
    arguments = ARGV.dup
    command = arguments.index('-c') ? arguments[arguments.index('-c') + 1] : nil
    script = command ? command[/\\. (\\S+) >\\[3=\\]\\z/, 1] : arguments.last
    File.readlines(script, chomp: true).each do |line|
      verb, text = line.split(' ', 2)
      case verb
      when 'out' then $stdout.write(text + "\\n")
      when 'err' then $stderr.write(text + "\\n")
      when 'report' then IO.new(3).write("erx_oracle_status=\#{text}\\n")
      when 'sleep' then sleep(Float(text))
      when 'flood' then $stdout.write('x' * Integer(text))
      when 'exit' then exit(Integer(text))
      when 'kill' then Process.kill(text, Process.pid)
      when 'child'
        pid = Process.spawn('sleep', '60')
        Process.detach(pid)
        $stdout.write("\#{pid}\\n")
      when 'describe'
        $stdout.write(JSON.generate('argv' => ARGV, 'env' => ENV.to_h, 'cwd' => Dir.pwd,
                                    'entries' => Dir.children(Dir.pwd), 'stdin' => $stdin.read))
      end
    end
  RUBY

  def setup
    @directory = Dir.mktmpdir('erx-rc-oracle-test-')
    rc = File.join(@directory, 'rc')
    File.write(rc, FAKE_RC)
    File.chmod(0o755, rc)
    rcmain = File.join(@directory, 'rcmain')
    File.write(rcmain, "# rcmain\n")
    @oracle = Erx::RcOracle::Oracle.new(rc: rc, rcmain: rcmain)
  end

  def teardown = FileUtils.remove_entry(@directory)

  def script(*lines)
    path = File.join(@directory, "script-#{lines.hash.abs}.rc")
    File.write(path, lines.map { |line| "#{line}\n" }.join)
    path
  end

  def test_a_run_returns_output_and_the_reported_status
    result = @oracle.run(script('out hello', 'err oops', "report 'it''s'"))
    assert_equal(:completed, result.state)
    assert_equal("hello\n", result.stdout)
    assert_equal("oops\n", result.stderr)
    assert_equal(["it's"], result.status)
    assert_equal(0, result.exit_status)
  end

  def test_an_empty_status_is_success_and_a_list_keeps_its_words
    assert_equal([''], @oracle.run(script("report ''")).status)
    assert_equal(['a b', 'c'], @oracle.run(script("report ('a b' c)")).status)
    assert_equal([], @oracle.run(script('report ()')).status)
  end

  def test_the_environment_is_only_path_and_home_in_an_empty_directory
    result = @oracle.run(script('describe'), path: %w[/p/one /p/two], home: '/h')
    seen = JSON.parse(result.stdout)
    # macOS's CoreFoundation sets __CF_USER_TEXT_ENCODING in the stand-in's
    # own Ruby process; the real rc's environment has no such variable.
    assert_equal({ 'PATH' => '/p/one:/p/two', 'HOME' => '/h' }, seen.fetch('env').except('__CF_USER_TEXT_ENCODING'))
    assert_empty(seen.fetch('entries'))
    assert_equal('', seen.fetch('stdin'))
    argv = seen.fetch('argv')
    assert_equal(['-m', @oracle.rcmain, '-c'], argv.first(3))
    assert(argv[3].start_with?(Erx::RcOracle::Oracle::STATUS_TRAP), 'the exit trap leads the command')
    assert(argv[3].end_with?('. ../script.rc >[3=]'), 'the script runs with the status channel closed')
    assert_equal('cwd', File.basename(seen.fetch('cwd')))
    refute(File.exist?(seen.fetch('cwd')), 'the private directory outlived the run')
  end

  def test_no_status_report_is_exited_and_never_a_status
    result = @oracle.run(script('out x', 'exit 3'))
    assert_equal(:exited, result.state)
    assert_nil(result.status)
    assert_equal(3, result.exit_status)
  end

  def test_a_malformed_status_report_is_no_status
    %w[(unclosed 'open a'b].each do |text|
      result = @oracle.run(script("report #{text}"))
      assert_equal(:exited, result.state, text)
      assert_nil(result.status, text)
    end
  end

  def test_a_deadline_kill_is_timed_out_and_reports_nothing_more
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = @oracle.run(script('out before', 'report done', 'sleep 30'), deadline: 1)
    assert_operator(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10)
    assert_equal(:timed_out, result.state)
    assert_nil(result.status, 'a status written before the kill is not the final status')
    assert_nil(result.exit_status)
    assert_equal("before\n", result.stdout)
  end

def test_output_past_the_limit_is_output_limit_and_never_a_result
  limit = Erx::RcOracle::Oracle::MAX_OUTPUT_BYTES
  result = @oracle.run(script("flood #{limit + 1}", "report ''"))
  assert_equal(:output_limit, result.state)
  assert_nil(result.status)
  assert_equal(limit, result.stdout.bytesize)
  assert_equal(:completed, @oracle.run(script("flood #{limit}", "report ''")).state, 'output at the limit is whole')
end

  def test_a_signal_is_reported_as_such
    result = @oracle.run(script('kill TERM'))
    assert_equal(:signalled, result.state)
    assert_equal(Signal.list.fetch('TERM'), result.signal)
    assert_nil(result.status)
  end

  def test_no_program_rc_started_outlives_the_run
    result = @oracle.run(script('child', "report ''"))
    child = Integer(result.stdout)
    gone = 50.times.any? do
      Process.kill(0, child)
      sleep(0.02)
      false
    rescue Errno::ESRCH
      true
    end
    assert(gone, 'the background child survived the run')
  end

  def test_parse_runs_rc_with_d_and_with_y_for_the_yacc_grammar
    path = script('describe')
    assert_equal(['-m', @oracle.rcmain, '-D'], JSON.parse(@oracle.parse(path).stdout).fetch('argv').first(3))
    assert_equal(['-m', @oracle.rcmain, '-D', '-Y'],
                 JSON.parse(@oracle.parse(path, parser: :yacc).stdout).fetch('argv').first(4))
    assert_raises(Erx::Error) { @oracle.parse(path, parser: :other) }
  end

  def test_an_unsafe_environment_or_deadline_is_refused
    path = script('out x')
    assert_raises(Erx::Error) { @oracle.run(path, path: ['bin']) }
    assert_raises(Erx::Error) { @oracle.run(path, path: ['/a:/b']) }
    assert_raises(Erx::Error) { @oracle.run(path, home: 'home') }
    assert_raises(Erx::Error) { @oracle.run(path, deadline: 0) }
    assert_raises(Erx::Error) { @oracle.run(File.join(@directory, 'absent.rc')) }
  end

  def test_describe_escapes_what_rc_reported
    result = @oracle.run(script("report \e]0;title\a"))
    assert_equal(["\e]0;title\a"], result.status)
    refute_match(/[\x00-\x1f\x7f]/, result.describe)
  end

  def test_status_lists_parse_as_whatis_prints_them
    parse = Erx::RcOracle.method(:parse_list)
    assert_equal(['1|1'], parse.call("'1|1'"))
    assert_equal(['x'], parse.call('x'))
    assert_equal(['x', "y'z"], parse.call("(x 'y''z')"))
    assert_nil(parse.call('x y'), 'two words outside parentheses')
    assert_nil(parse.call("'x"))
  end

  def test_a_missing_build_fails_with_how_to_build_it
    Dir.mktmpdir do |root|
      error = assert_raises(Erx::RcOracle::MissingBuild) { Erx::RcOracle.locate(root: root) }
      assert_match(%r{not built.*tools/erx build rc-oracle}, error.message)
    end
  end

  def test_a_build_from_another_pin_is_stale
    Dir.mktmpdir do |root|
      FileUtils.cp(File.join(ROOT, 'deps.lock'), root)
      output = File.join(root, Erx::RcOracle::OUTPUT)
      FileUtils.mkdir_p(output)
      FileUtils.cp(File.join(@directory, 'rc'), output)
      File.write(File.join(output, 'rcmain'), '')
      source = Erx::RcOracle.source_record(root: root).merge('commit' => '0' * 40)
      File.write(File.join(output, 'build.json'),
                 JSON.generate('source' => source, 'recipe' => Erx::RcOracle::Build::RECIPE))
      assert_raises(Erx::RcOracle::StaleBuild) { Erx::RcOracle.locate(root: root) }
    end
  end

  # A build record that does not parse is stale, so ensure_rc_oracle rebuilds over it
  # instead of failing check.
  def test_a_build_with_a_corrupt_record_is_stale
    Dir.mktmpdir do |root|
      FileUtils.cp(File.join(ROOT, 'deps.lock'), root)
      output = File.join(root, Erx::RcOracle::OUTPUT)
      FileUtils.mkdir_p(output)
      FileUtils.cp(File.join(@directory, 'rc'), output)
      File.write(File.join(output, 'build.json'), '{"source": ')
      error = assert_raises(Erx::RcOracle::StaleBuild) { Erx::RcOracle.locate(root: root) }
      assert_match(%r{unreadable build record.*tools/erx build rc-oracle}, error.message)
    end
  end

  def test_a_build_without_the_fetched_source_says_how_to_fetch_it
    Dir.mktmpdir do |root|
      FileUtils.cp(File.join(ROOT, 'deps.lock'), root)
      runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs'))
      error = assert_raises(Erx::RcOracle::MissingSource) { Erx::RcOracle::Build.new(root: root, runner: runner).call }
      assert_match(/tools\/erx fetch --source plan9port/, error.message)
    end
  end
end
