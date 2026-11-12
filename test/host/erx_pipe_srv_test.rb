# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'

# erx_pipe_srv, the process that performs erx_pipe:step/2's actions
# (docs/design-pipes.md, "The pipe server"), against a fake pipe NIF:
# test/erlang/erx_pipe_srv_tests.erl. Each seeded fault of the server must
# fail the EUnit case named beside it.
class ErxPipeSrvTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  SERVER = File.join(ROOT, 'erlang/apps/erx/src/erx_pipe_srv.erl')
  SOURCES = [File.join(ROOT, 'erlang/apps/erx/src/erx_pipe.erl'),
             File.join(ROOT, 'test/erlang/erx_pipe_fake_nif.erl'),
             File.join(ROOT, 'test/erlang/erx_pipe_srv_tests.erl')].freeze

  def test_the_server_performs_the_steps
    text, ok = run_eunit(File.read(SERVER))
    assert ok, text
    assert_match(/All \d+ tests passed/, text)
  end

  # A seeded fault, the EUnit case that must catch it, and the edit that plants it.
  MUTANTS = {
    'a report sent before its holder\'s end has it' =>
      ['report_applied_before_it_is_sent',
       "case {Nif:apply(EndRes, resolve(Report, S)), erx_pipe:copies(Report)} of\n",
       "case {(Pid ! {pipe_report, Report}) =/= x andalso Nif:apply(EndRes, resolve(Report, S)), " \
       "erx_pipe:copies(Report)} of\n"],
    'the objects of a failed step left open' =>
      ['failed_make_undoes_the_step', 'lists:foreach(fun(Obj) -> (S#srv.nif):close(Obj) end, Made),', '_ = Made,'],
    'an end forgotten on another process\'s notice' =>
      ['forged_notice_changes_nothing', '#{{Pipe, End} := {Pid, _}} ->', '_ when is_pid(Pid) ->']
  }.freeze

  def test_seeded_faults_are_caught
    source = File.read(SERVER)
    MUTANTS.each do |name, (expected, original, replacement)|
      assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
      text, ok = run_eunit(source.sub(original) { replacement })
      refute ok, "seeded fault not caught: #{name}"
      assert_match(/#{expected}/, text, "seeded fault not caught by its case: #{name}")
    end
  end

  private

  def run_eunit(server)
    Dir.mktmpdir('erx-pipe-srv-test') do |work|
      path = File.join(work, 'erx_pipe_srv.erl')
      File.write(path, server)
      text, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-o', work,
                                     path, *SOURCES, stdin_data: '')
      return [text, false] unless status.success?

      eval_text = 'halt(case eunit:test(erx_pipe_srv_tests, [verbose]) of ok -> 0; _ -> 1 end).'
      text, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell',
                                     '-pa', work, '-eval', eval_text, chdir: work, stdin_data: '')
      [text, status.success?]
    end
  end
end
