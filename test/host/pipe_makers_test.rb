# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/pipe_makers'

# The chokepoint "only the pipe server makes a pipe's objects" (PI1): a call of
# erx_pipe_nif's make_lock/0, make_lane/1 or make_bell/3 outside erx_pipe_srv fails,
# whether a remote call, a fun, an apply, a macro naming the module or any import; the
# NIF's other calls and the tests' own modules are not refused.
class PipeMakersTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SERVER = 'erlang/apps/erx/src/erx_pipe_srv.erl'
  SESSION = 'erlang/apps/erx/src/erx_session.erl'
  SEEDED = "l() -> erx_pipe_nif:make_lock().\n"

  def lines_of(files) = Erx::PipeMakers.violations(files).map { |violation| [violation.path, violation.line] }

  def test_the_tree_passes
    paths = Erx::DeviceCallers::SCOPE.flat_map { |glob| Dir.glob(glob, base: ROOT) }
    files = paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    assert_empty Erx::PipeMakers.violations(files).map(&:to_s)
  end

  def test_a_seeded_make_outside_the_pipe_server_is_refused
    assert_equal [[SESSION, 2]], lines_of(SESSION => "%% erx_pipe_nif:make_lock() in a comment is not code\n#{SEEDED}")
    {
      'a lane' => "f(S) -> erx_pipe_nif:make_lane(S).\n",
      'a bell' => "f(P, I, E) -> erx_pipe_nif:make_bell(P, I, E).\n",
      'a fun' => "f() -> fun erx_pipe_nif:make_bell/3.\n",
      'a quoted atom' => "f() -> 'erx_pipe_nif':'make_lock'().\n",
      'an apply' => "f() -> erlang:apply(erx_pipe_nif, make_lane, [4096]).\n",
      'an import' => "-import(erx_pipe_nif, [read/2]).\n",
      'a macro' => "-define(NIF, erx_pipe_nif).\n",
      'a call split across lines' => "f() ->\n    erx_pipe_nif:\n        make_lock().\n"
    }.each do |form, source|
      line = source.lines.index { |text| text.include?('erx_pipe_nif') } + 1
      assert_equal [[SESSION, line]], lines_of(SESSION => source), form
    end
    assert_equal [['otp/lib/stdlib/src/seeded.erl', 1]], lines_of('otp/lib/stdlib/src/seeded.erl' => SEEDED)
  end

  def test_the_server_other_calls_and_tests_are_not_refused
    assert_empty lines_of(SERVER => SEEDED)
    assert_empty lines_of(SESSION => "f(E) -> erx_pipe_nif:read(E, 1), erx_pipe_nif:close(E), x:make_lock().\n")
    assert_empty lines_of(SESSION => "f() -> \"erx_pipe_nif, make_locks\".\n")
    assert_empty lines_of('test/erlang/seeded_tests.erl' => SEEDED)
  end

  # The source check runs the rule over the files git lists.
  def test_the_source_check_refuses_a_seeded_violation
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, File.dirname(SESSION)))
      File.write(File.join(root, SESSION), SEEDED)
      checks = Erx::Checks.new(root: root, runner: nil)
      error = assert_raises(Erx::Error) { checks.send(:check_pipe_makers, [SESSION, 'README.md']) }
      assert_match "#{SESSION}:1", error.message
    end
  end
end
