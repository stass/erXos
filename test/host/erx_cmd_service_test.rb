# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_cmd_service_tests.erl, the EUnit cases of the command
# shell's `service` (docs/design-apps.md, "Interfaces"), against the
# erx_shell application compiled from source with warnings as errors on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies).
class ErxCmdServiceTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  APPLICATION = File.join(ROOT, 'erlang/apps/erx_shell/src')
  # erx_cmd first, so that the commands find their behaviour.
  SOURCES = [Erx::Generated.path('erlang/apps/erx/src/erx_text_tables.erl', root: ROOT),
             File.join(ROOT, 'erlang/apps/erx/src/erx_text.erl'),
             File.join(ROOT, 'erlang/apps/erx/src/erx_facets.erl'),
             File.join(APPLICATION, 'erx_cmd.erl'),
             *Dir[File.join(APPLICATION, '*.erl')].sort,
             File.join(ROOT, 'test/erlang/erx_cmd_service_tests.erl')].uniq.freeze

  # The seeded fault: a command on a row that is not enabled acts as on an enabled one.
  ENABLED_CHECK = "act({Name, Command, false, _Settings}, false, _State, _Row) ->"
  NO_CHECK = "act({Name, Command, false, _Settings}, false, _State, _Row) when Name =:= <<>> ->"

  def test_service_cases_pass_under_eunit
    output = eunit(SOURCES)
    assert_match(/All \d+ tests passed/, output)
  end

  def test_the_cases_catch_a_command_that_skips_the_enabled_check
    source = File.join(APPLICATION, 'erx_cmd_service.erl')
    text = File.read(source)
    assert_equal 1, text.scan(ENABLED_CHECK).size
    Dir.mktmpdir('erx-cmd-service-fault') do |faulted|
      copy = File.join(faulted, 'erx_cmd_service.erl')
      File.write(copy, text.sub(ENABLED_CHECK) { NO_CHECK })
      output = eunit(SOURCES.map { |path| path == source ? copy : path }, passes: false)
      assert_match(/start_of_a_row_not_enabled_names_onestart_test[^\n]*\*failed\*/, output)
    end
  end

  private

  def eunit(sources, passes: true)
    Dir.mktmpdir('erx-cmd-service-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-pa', work, '-o', work,
                                       *sources, stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_cmd_service_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert_equal passes, status.success?, output
      output
    end
  end
end
