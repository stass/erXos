# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/build_facts'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_cmd_uname_tests.erl, the EUnit cases of the command
# shell's `uname` (docs/design-shell.md, "Text commands"), against the
# erx_shell application and erx_build compiled from source with warnings as
# errors on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies). The values come from the generated erx_abi.hrl in build/gen. The
# emulator gets a node name but no distribution, as the system release does.
# Then the reader is held to the writer: the files Erx::BuildFacts renders for
# facts at each field's longest and for every fact unknown, erx_build reads back.
class ErxCmdUnameTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  APPLICATION = File.join(ROOT, 'erlang/apps/erx_shell/src')
  # erx_cmd first, so that the commands find their behaviour.
  SOURCES = [File.join(ROOT, 'build/gen/erlang/apps/erx/src/erx_text_tables.erl'), File.join(ROOT, 'erlang/apps/erx/src/erx_text.erl'),
             File.join(ROOT, 'erlang/apps/erx/src/erx_build.erl'),
             File.join(APPLICATION, 'erx_cmd.erl'),
             *Dir[File.join(APPLICATION, '*.erl')].sort,
             File.join(ROOT, 'test/erlang/erx_cmd_uname_tests.erl')].uniq.freeze

  # Facts at each field's longest, which the writer's shapes admit, and every fact unknown.
  LONGEST = [Erx::BuildFacts::Facts.new(revision: "n9999999999-#{'f' * 12}-dirty", date: 999_999_999_999,
                                        configuration: "#{'a' * 64}/#{'b' * 32}", kernel: "k#{'.' * 63}"),
             Erx::BuildFacts::Facts.new(revision: nil, date: nil, configuration: nil, kernel: nil)].freeze

  def test_uname_cases_pass_under_eunit
    Dir.mktmpdir('erx-cmd-uname-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-pa', work, '-o', work,
                                       *SOURCES, stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-sname', 'uname@erxtest', '-kernel', 'start_distribution', 'false',
                                       '-eval', 'halt(case eunit:test(erx_cmd_uname_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)

      LONGEST.each_with_index { |facts, index| File.write(File.join(work, "facts-#{index}"), Erx::BuildFacts.render(facts)) }
      read = LONGEST.each_index.map { |index| "{ok, _} = erx_build:parse_facts(element(2, file:read_file(\"facts-#{index}\")))" }
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', "#{read.join(', ')}, halt(0).", chdir: work, stdin_data: '')
      assert status.success?, output
    end
  end
end
