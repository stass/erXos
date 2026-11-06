# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/rc_oracle'

# The real oracle: plan9port's rc as tools/erx build rc-oracle makes it from
# the pinned source (make check-rc-oracle builds it first). A missing build
# fails here with how to make it; nothing is skipped.
class RcOracleIntegrationTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  UPSTREAM = File.join(ROOT, 'test/shell/rc/plan9port')

  def setup
    @oracle = Erx::RcOracle.locate(root: ROOT)
    @directory = Dir.mktmpdir('erx-rc-oracle-integration-')
  end

  def teardown = FileUtils.remove_entry(@directory)

  def run_script(text, **options)
    path = File.join(@directory, 'script.rc')
    File.write(path, text)
    @oracle.run(path, **options)
  end

  def test_output_and_status_of_tiny_scripts
    result = run_script("echo hello\necho oops >[1=2]\n")
    assert_equal([:completed, "hello\n", "oops\n", ['']],
                 [result.state, result.stdout, result.stderr, result.status])
    assert_equal(0, result.exit_status)

    result = run_script("x=(a b c)\necho $#x $x(2)\nexit 'it''s'\n")
    assert_equal([:completed, "3 b\n", ["it's"]], [result.state, result.stdout, result.status])
    assert_equal(1, result.exit_status, 'rc exits 1 for a status that is not empty')

    assert_equal(['1'], run_script("false\n").status)
  end

  # The script and its programs run with descriptor 3 closed and the trap
  # calls the builtin, so neither can forge the report; a script that
  # replaces sigexit leaves none.
  def test_a_script_cannot_forge_its_status
    result = run_script("exec /bin/sh -c 'echo erx_oracle_status=forged >&3'\n")
    assert_equal([:exited, nil], [result.state, result.status])

    result = run_script("fn whatis { echo erx_oracle_status=spoof }\nexit 7\n")
    assert_equal([:completed, ['7']], [result.state, result.status])

    result = run_script("fn sigexit { echo bye }\nexit 5\n")
    assert_equal([:exited, nil, "bye\n"], [result.state, result.status, result.stdout])
  end

  def test_the_script_is_named_alike_on_every_run
    assert_equal("../script.rc\n", run_script("echo $0\n").stdout)
    assert_match(%r{\Arc: \.\./script\.rc:\d+: }, run_script("if (\n").stderr)
  end

  def test_the_environment_is_controlled
    result = run_script("echo $home $path\npwd\nls -a\n", path: %w[/usr/bin /bin], home: '/var/empty')
    lines = result.stdout.lines(chomp: true)
    assert_equal('/var/empty /usr/bin /bin', lines[0])
    assert_equal('cwd', File.basename(lines[1]))
    assert_equal(%w[. ..], lines[2..])
  end

  def test_a_script_that_outlives_its_deadline_is_timed_out
    result = run_script("echo started\nsleep 30\necho never\n", deadline: 1)
    assert_equal(:timed_out, result.state)
    assert_nil(result.status)
    assert_equal("started\n", result.stdout)
  end

  # plan9port's own parser check (checkparse): test.rc parses to the same
  # trees under rc's yacc grammar as under its hand-written parser.
  def test_upstream_test_rc_parses_alike_under_both_parsers
    script = File.join(UPSTREAM, 'test.rc')
    hand = @oracle.parse(script, parser: :hand)
    yacc = @oracle.parse(script, parser: :yacc)
    [hand, yacc].each do |result|
      assert_equal(:exited, result.state, result.describe)
      assert_equal(0, result.exit_status, result.describe)
      assert_empty(result.stdout)
    end
    assert_equal(hand.stderr, yacc.stderr, 'the two parsers print different trees for test.rc')
    assert_operator(hand.stderr.lines.count { |line| line.start_with?('compile: ') }, :>, 60)
  end
end
