# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_ns_tests.erl, the EUnit cases of the namespace table's one
# writer, against erx_ns compiled from source with warnings as errors on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies), over the stub of
# prim_file the cases start it with. An image mount runs the EROFS reader and its funnel
# over a fixture image (ERX_EROFS_FIXTURES) in a RAM window of erx_erofs_tests, and its
# log line reaches the case through a stub of erx_log, which sends it to the process
# registered as erx_ns_log.
class ErxNsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application holding erx_ns, compiled whole (ErlangBuild), and the modules the cases
  # run it with: the prim_file stub, the path, EROFS and verity modules of the preloaded
  # set (outside the applications) and the suites.
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/erx_ns_prim_stub.erl otp/erts/preloaded/src/erx_path.erl test/erlang/erx_ns_tests.erl
             otp/erts/preloaded/src/erx_erofs.erl otp/erts/preloaded/src/erx_verity.erl
             test/erlang/erx_erofs_tests.erl].freeze
  INCLUDES = %w[otp/lib/kernel/include].freeze
  FIXTURES = File.join(ROOT, 'test/fixtures/erofs')
  # This text is compiled in place of the application's erx_log (a stub), so the case sees
  # the log line a mount writes.
  LOG_STUB = <<~ERLANG
    -module(erx_log).
    -export([debug/1]).
    debug(Line) ->
        case whereis(erx_ns_log) of
            undefined -> ok;
            Log -> Log ! {log, Line}, ok
        end.
  ERLANG
  LOG = 'erlang/apps/erx/src/erx_log.erl'

  def test_writer_cases_pass_under_eunit
    output, status = eunit
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  private

  def eunit
    Dir.mktmpdir('erx-ns-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { LOG => LOG_STUB }, includes: INCLUDES)

      Open3.capture2e({ 'ERX_EROFS_FIXTURES' => FIXTURES }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_ns_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
