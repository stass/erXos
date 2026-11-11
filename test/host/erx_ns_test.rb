# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_ns_tests.erl, the EUnit cases of the namespace table's one
# writer, against erx_ns compiled from source with warnings as errors on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies), over the stub of
# prim_file the cases start it with. An image mount runs the EROFS reader and its funnel
# over a fixture image (ERX_EROFS_FIXTURES) in a RAM window of erx_erofs_tests, and its
# log line reaches the case through a stub of erx_log, which sends it to the process
# registered as erx_ns_log.
class ErxNsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  SOURCES = %w[erlang/apps/erx/src/erx_ns.erl test/erlang/erx_ns_prim_stub.erl otp/erts/preloaded/src/erx_path.erl
               test/erlang/erx_ns_tests.erl otp/erts/preloaded/src/erx_erofs.erl
               otp/erts/preloaded/src/erx_verity.erl test/erlang/erx_erofs_tests.erl]
            .map { |path| File.join(ROOT, path) }.freeze
  INCLUDES = %w[build/gen/erlang/apps/erx/include otp/lib/kernel/include].flat_map { |dir| ['-I', File.join(ROOT, dir)] }.freeze
  FIXTURES = File.join(ROOT, 'test/fixtures/erofs')
  LOG_STUB = <<~ERLANG
    -module(erx_log).
    -export([debug/1]).
    debug(Line) ->
        case whereis(erx_ns_log) of
            undefined -> ok;
            Log -> Log ! {log, Line}, ok
        end.
  ERLANG

  def test_writer_cases_pass_under_eunit
    output, status = eunit
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  private

  def eunit
    Dir.mktmpdir('erx-ns-test') do |work|
      File.write(File.join(work, 'erx_log.erl'), LOG_STUB)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', *INCLUDES, '-o', work, *SOURCES,
                                       File.join(work, 'erx_log.erl'),
                                       stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e({ 'ERX_EROFS_FIXTURES' => FIXTURES }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_ns_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
