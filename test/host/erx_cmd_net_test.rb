# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_cmd_net_tests.erl, the EUnit cases of the command shell's
# `ifconfig` and `ping` (docs/design-shell.md, "Commands"), against the erx_shell
# application compiled from source with warnings as errors on stock's emulator (ERX_ERL
# and ERX_ERLC, which make check supplies). Then a seeded fault: ping counting a reply
# whose sequence number only shares its slot with a request it sent must fail the
# matching case.
class ErxCmdNetTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  NET_INCLUDE = File.join(ROOT, 'erlang/apps/erx_net/include')
  APPLICATION = File.join(ROOT, 'erlang/apps/erx_shell/src')
  PING = File.join(APPLICATION, 'erx_cmd_ping.erl')
  # erx_cmd first, so that the commands find their behaviour.
  SOURCES = [File.join(ROOT, 'build/gen/erlang/apps/erx/src/erx_text_tables.erl'),
             File.join(ROOT, 'erlang/apps/erx/src/erx_text.erl'),
             File.join(ROOT, 'erlang/apps/erx/src/erx_facets.erl'),
             File.join(APPLICATION, 'erx_cmd.erl'),
             *Dir[File.join(APPLICATION, '*.erl')].sort,
             # ping's loop calls the echo socket's API, which its case answers with a stand-in.
             File.join(ROOT, 'erlang/apps/erx_net/src/erx_icmp_sock.erl'),
             File.join(ROOT, 'test/erlang/erx_cmd_net_tests.erl')].uniq.freeze
  SEEDED = ['#{Slot := {Seq, At, Seen}} ->', '#{Slot := {_, At, Seen}} ->'].freeze

  def test_net_command_cases_pass_under_eunit
    output, status = eunit(SOURCES)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_seeded_slot_match_without_the_sequence_number_is_caught
    Dir.mktmpdir('erx-cmd-net-fault') do |dir|
      exact, faulty = SEEDED
      text = File.read(PING)
      assert_equal 1, text.scan(exact).size
      faulty_ping = File.join(dir, 'erx_cmd_ping.erl')
      File.write(faulty_ping, text.sub(exact) { faulty })
      output, status = eunit(SOURCES.map { |source| source == PING ? faulty_ping : source })
      refute status.success?, output
      assert_match(/only_replies_to_remembered_requests_count_test.*failed/, output)
    end
  end

  private

  def eunit(sources)
    Dir.mktmpdir('erx-cmd-net-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-I', NET_INCLUDE, '-pa', work, '-o', work,
                                       *sources, stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_cmd_net_tests) of ok -> 0; _ -> 1 end).',
                      chdir: work, stdin_data: '')
    end
  end
end
