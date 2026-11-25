# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_path_tests.erl, the EUnit cases of the path resolver, against
# erx_path compiled from source with warnings as errors on stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies), with the model tree and executor the cases drive
# it through. The fuzz target, tools/fuzz/erx_path.rb, seeds the design's faults.
class ErxPathTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  SOURCES = %w[otp/erts/preloaded/src/erx_path.erl test/erlang/erx_path_tree.erl
               test/erlang/erx_path_tests.erl].map { |path| File.join(ROOT, path) }.freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')

  # A seeded resolver that ignores the nofollow mark, so a link on a drive is followed: the
  # marked tree's case must catch it.
  MARK = "follow(\#{nofollow := true}, _, _, _, _, _) ->\n    {error, eacces};\n"

  def test_resolver_cases_pass_under_eunit
    output, status = eunit(File.read(SOURCES.first))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_a_resolver_that_ignores_the_nofollow_mark_is_caught
    source = File.read(SOURCES.first)
    assert_equal 1, source.scan(MARK).size, 'erx_path has no nofollow clause to remove'
    output, status = eunit(source.sub(MARK, ''))
    refute status.success?, output
    assert_match(/a_link_in_a_tree_marked_nofollow_is_never_followed_test\.\.\.\*failed\*/, output)
    assert_match(/Failed: 1\./, output)
  end

  private

  # The cases over Resolver, the text of erx_path or of a seeded copy.
  def eunit(resolver)
    Dir.mktmpdir('erx-path-test') do |work|
      path = File.join(work, 'erx_path.erl')
      File.write(path, resolver)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-o', work, path,
                                       *SOURCES.drop(1), stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_path_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
