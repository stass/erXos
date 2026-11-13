# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/build_facts'
require_relative '../fixtures/erlang_build'

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
  # The applications the command runs in, compiled whole (ErlangBuild), and the cases.
  APPLICATIONS = %w[erx erx_shell].freeze
  TESTS = %w[test/erlang/erx_cmd_uname_tests.erl].freeze

  # Facts at each field's longest, which the writer's shapes admit, and every fact unknown.
  LONGEST = [Erx::BuildFacts::Facts.new(revision: "n9999999999-#{'f' * 12}-dirty", date: 999_999_999_999,
                                        configuration: "#{'a' * 64}/#{'b' * 32}", kernel: "k#{'.' * 63}"),
             Erx::BuildFacts::Facts.new(revision: nil, date: nil, configuration: nil, kernel: nil)].freeze

  def test_uname_cases_pass_under_eunit
    Dir.mktmpdir('erx-cmd-uname-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       # A name, but no epmd: one would outlive the test.
                                       '-sname', 'uname@erxtest', '-start_epmd', 'false',
                                       '-kernel', 'start_distribution', 'false',
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
