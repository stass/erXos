# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/pipe_callers'

# The Erlang halves of the pipe's chokepoints (tools/lib/erx/pipe_callers.rb). pipe-makers (PI1):
# a call of erx_pipe_nif's make_lock/1, make_lane/1, make_bell/3 or hand_make/2 outside
# erx_pipe_srv fails, whether a remote call, a fun, an apply, a macro naming the module or any
# import. pipe-holders: a call of program_holder/1 or holder_drop/1 outside erx_prog_handler
# fails. pipe-holder-gone-erlang: the atom erx_pipe_holder_gone outside erx_pipe_srv fails. The
# NIF's other calls and the tests' own modules are not refused. The seeds are the design's
# (docs/design-pipes.md, Verification, build checks of the hand-offs).
class PipeCallersTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SERVER = 'erlang/apps/erx/src/erx_pipe_srv.erl'
  HANDLER = 'erlang/apps/erx/src/erx_prog_handler.erl'
  SESSION = 'erlang/apps/erx/src/erx_session.erl'
  SEEDED = "l() -> erx_pipe_nif:make_lock(1).\n"

  def found(files) = Erx::PipeCallers.violations(files).map { |violation| [violation.rule.name, violation.path, violation.line] }

  def test_the_tree_passes
    paths = Erx::DeviceCallers::SCOPE.flat_map { |glob| Dir.glob(glob, base: ROOT) }
    files = paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    assert_empty Erx::PipeCallers.violations(files).map(&:to_s)
  end

  def test_a_seeded_make_outside_the_pipe_server_is_refused
    assert_equal [['pipe-makers', SESSION, 2]],
                 found(SESSION => "%% erx_pipe_nif:make_lock() in a comment is not code\n#{SEEDED}")
    {
      'a lane' => "f(S) -> erx_pipe_nif:make_lane(S).\n",
      'a bell' => "f(P, I, E) -> erx_pipe_nif:make_bell(P, I, E).\n",
      'a fun' => "f() -> fun erx_pipe_nif:make_bell/3.\n",
      'a quoted atom' => "f() -> 'erx_pipe_nif':'make_lock'(1).\n",
      'an apply' => "f() -> erlang:apply(erx_pipe_nif, make_lane, [4096]).\n",
      'a call split across lines' => "f() ->\n    erx_pipe_nif:\n        make_lock(1).\n"
    }.each do |form, source|
      line = source.lines.index { |text| text.include?('erx_pipe_nif') } + 1
      assert_equal [['pipe-makers', SESSION, line]], found(SESSION => source), form
    end
    assert_equal [['pipe-makers', 'otp/lib/stdlib/src/seeded.erl', 1]], found('otp/lib/stdlib/src/seeded.erl' => SEEDED)
    # The design's seed: a hand-off made in the handler.
    assert_equal [['pipe-makers', HANDLER, 1]], found(HANDLER => "f(P, H) -> erx_pipe_nif:hand_make(P, H).\n")
  end

  def test_an_import_or_a_macro_of_the_nif_is_refused_by_each_call_rule
    {
      'an import' => "-import(erx_pipe_nif, [read/2]).\n",
      'a macro' => "-define(NIF, erx_pipe_nif).\n"
    }.each do |form, source|
      assert_equal [['pipe-makers', SESSION, 1], ['pipe-holders', SESSION, 1]], found(SESSION => source), form
      assert_equal [['pipe-holders', SERVER, 1]], found(SERVER => source), form
      assert_equal [['pipe-makers', HANDLER, 1]], found(HANDLER => source), form
    end
  end

  def test_a_seeded_holder_call_outside_the_handler_is_refused
    # The design's seed: the pipe server making a program's holder entry.
    assert_equal [['pipe-holders', SERVER, 1]], found(SERVER => "f(P) -> erx_pipe_nif:program_holder(P).\n")
    assert_equal [['pipe-holders', SESSION, 1]], found(SESSION => "f(P) -> erx_pipe_nif:holder_drop(P).\n")
    assert_equal [['pipe-holders', SESSION, 1]], found(SESSION => "f() -> fun erx_pipe_nif:program_holder/1.\n")
    assert_empty found(HANDLER => "f(P) -> ok = erx_pipe_nif:program_holder(P), erx_pipe_nif:holder_drop(P).\n")
  end

  def test_a_seeded_gone_outside_the_pipe_server_is_refused
    # The design's seed: the handler sending the program's gone.
    assert_equal [['pipe-holder-gone-erlang', HANDLER, 1]],
                 found(HANDLER => "f(P) -> erx_pipe_srv ! {erx_pipe_holder_gone, P}.\n")
    assert_equal [['pipe-holder-gone-erlang', SESSION, 1]], found(SESSION => "f() -> 'erx_pipe_holder_gone'.\n")
    assert_empty found(SESSION => "f() -> erx_pipe_holder_gone_x.\n%% erx_pipe_holder_gone\n")
    assert_empty found(SERVER => "handle_info({erx_pipe_holder_gone, P}, S) -> {noreply, S}.\n")
  end

  def test_the_server_other_calls_and_tests_are_not_refused
    assert_empty found(SERVER => SEEDED)
    assert_empty found(SESSION => "f(E) -> erx_pipe_nif:read(E, 1), erx_pipe_nif:close(E), x:make_lock().\n")
    assert_empty found(SESSION => "f() -> \"erx_pipe_nif, make_locks\".\n")
    assert_empty found('test/erlang/seeded_tests.erl' => "#{SEEDED}f() -> erx_pipe_holder_gone.\n")
  end

  # The source check runs the rules over the files git lists.
  def test_the_source_check_refuses_a_seeded_violation
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, File.dirname(SESSION)))
      File.write(File.join(root, SESSION), SEEDED)
      checks = Erx::Checks.new(root: root, runner: nil)
      error = assert_raises(Erx::Error) { checks.send(:check_pipe_callers, [SESSION, 'README.md']) }
      assert_match "#{SESSION}:1", error.message
    end
  end
end
