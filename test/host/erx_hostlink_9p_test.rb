# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_hostlink_9p_tests.erl, the EUnit cases of the host link's 9P bridge
# (erx_hostlink_9p's core and erx_hostlink_files over a real erx_fs grant of
# erx_fs_test_tree), compiled from source on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies) with the generated codec, grammar and erx_abi.hrl from build/gen.
class ErxHostlink9pTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  GENERATED = %w[otp/erts/preloaded/src/erx_9p_grammar.erl
                 erlang/apps/erx/src/generated/erx_9p.erl erlang/apps/erx/src/generated/erx_manifest.erl]
              .map { |source| Erx::Generated.path(source, root: ROOT) }
  SOURCES = [*GENERATED,
             *%w[erlang/apps/erx_files/src/erx_fs_grant.erl
                 erlang/apps/erx_files/src/erx_fs.erl erlang/apps/erx_files/src/erx_fs_version.erl
                 erlang/apps/erx_hostlink/src/erx_hostlink_9p.erl erlang/apps/erx_hostlink/src/erx_hostlink_files.erl]
               .map { |source| File.join(ROOT, source) }].freeze
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  TESTS = %w[test/erlang/erx_fs_test_tree.erl test/erlang/erx_hostlink_9p_tests.erl].freeze

  def test_the_bridge_passes_under_eunit
    Dir.mktmpdir('erx-hostlink-9p-test') do |work|
      compile(work, SOURCES)
      compile(work, TESTS.map { |source| File.join(ROOT, source) })
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_hostlink_9p_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  private

  # The test tree declares the erx_fs behaviour, so it compiles once erx_fs is in work.
  def compile(work, sources)
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-pa', work,
                                     '-I', INCLUDE,
                                     '-o', work, *sources, stdin_data: '')
    assert status.success?, output
  end
end
