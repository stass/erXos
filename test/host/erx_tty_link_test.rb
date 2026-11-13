# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_tty_link_tests.erl, the EUnit cases of the tty's side of the five
# messages (erx_tty_link), its exhaustive walk among them, against the core compiled
# from source on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies); the
# core is pure, so it needs no hosted build.
class ErxTtyLinkTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  TESTS = %w[test/erlang/erx_tty_link_tests.erl].freeze

  def test_link_core_cases_pass_under_eunit
    Dir.mktmpdir('erx-tty-link-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx_session], tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_tty_link_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
