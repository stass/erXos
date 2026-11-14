# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# A program's handler (docs/design-programs.md, "The handler"): its pure core,
# erx_prog_handler_core, by test/erlang/erx_prog_handler_core_tests.erl, and its
# effect process, erx_prog_handler, with the real pipe server over a fake pipe NIF
# and stand-ins (test/erlang/stand_in) for the program driver, the pixel allocator
# and the NIF calls the handler makes, by
# test/erlang/erx_prog_handler_tests.erl. Each seeded fault must fail the EUnit
# case named beside it.
class ErxProgHandlerTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/erx_pipe_fake_nif.erl test/erlang/erx_prog_handler_fakes.erl
             test/erlang/stand_in/erx_program.erl test/erlang/stand_in/erx_pixels.erl
             test/erlang/stand_in/erx_pipe_nif.erl build/gen/otp/erts/preloaded/src/erx_prog.erl
             test/erlang/erx_prog_handler_core_tests.erl test/erlang/erx_prog_handler_tests.erl].freeze
  SUITES = %w[erx_prog_handler_core_tests erx_prog_handler_tests].freeze
  CORE = 'erlang/apps/erx/src/erx_prog_handler_core.erl'
  HANDLER = 'erlang/apps/erx/src/erx_prog_handler.erl'

  def test_the_handler_starts_forwards_and_ends
    text, ok = run_eunit({})
    assert ok, text
    assert_match(/All \d+ tests passed/, text)
  end

  # A seeded fault: the file it edits, the text it replaces and its replacement,
  # and the EUnit case that must catch it.
  Mutant = Data.define(:file, :original, :replacement, :caught_by)
  MUTANTS = {
    'a refused start that keeps its hand-offs' =>
      Mutant.new(file: CORE, original: '[{hand_drop, Number} || {_, {pipe_hand, Number, _}} <- Made] ++',
                 replacement: '[] ++', caught_by: 'refused_start_undoes_everything'),
    'a busy send treated as taken, so a newer frame passes the owed one' =>
      Mutant.new(file: CORE, original: "{C#core{out = owed}, []};\n",
                 replacement: "pump(drop_head(C));\n", caught_by: 'owed_report_waits_for_room'),
    'a stop asked again at every stop event' =>
      Mutant.new(file: CORE, original: 'stop(C) -> {C, []}.',
                 replacement: 'stop(C) -> {C, [{stop, ?STOP_STATUS}]}.', caught_by: 'stop_once_then_exit'),
    'a starter whose exit leaves its program running' =>
      Mutant.new(file: HANDLER, original: "{'DOWN', _, process, Starter, _} -> stop;",
                 replacement: '', caught_by: 'starters_exit_stops_the_program'),
    'a handler that stays after its program ends' =>
      Mutant.new(file: HANDLER, original: "        ended ->\n            ok;\n", replacement: '',
                 caught_by: 'exit_tells_the_starter'),
    'a refused start that keeps the program\'s holder entry, so its ends are never gone' =>
      Mutant.new(file: CORE, original: "        [holder_drop].\n", replacement: "        [].\n",
                 caught_by: 'an_end_of_another_process_is_refused')
  }.freeze

  def test_seeded_faults_are_caught
    MUTANTS.each do |name, mutant|
      source = File.read(File.join(ROOT, mutant.file))
      assert_equal 1, source.scan(mutant.original).size, "mutant #{name} must edit exactly one place"
      text, ok = run_eunit({ mutant.file => source.sub(mutant.original) { mutant.replacement } })
      refute ok, "seeded fault not caught: #{name}"
      # Verbose EUnit names every case, so only the named case's failure line counts.
      assert_match(/#{mutant.caught_by}.*\*failed\*/, text, "seeded fault not caught by its case: #{name}")
    end
  end

  private

  # The suites' text and whether they passed, with replaced's sources in place of the tree's.
  def run_eunit(replaced)
    Dir.mktmpdir('erx-prog-handler-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      eval_text = "halt(case eunit:test([#{SUITES.join(', ')}], [verbose]) of ok -> 0; _ -> 1 end)."
      text, status = Open3.capture2e('gtimeout', '-k', '10', '180', ENV.fetch('ERX_ERL'), '-noshell',
                                     '-pa', work, '-eval', eval_text, chdir: work, stdin_data: '')
      [text, status.success?]
    end
  end
end
