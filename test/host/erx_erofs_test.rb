# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_erofs_tests.erl, the EUnit cases of the EROFS reader and its
# funnel, against erx_erofs and erx_verity compiled from source with warnings as errors
# on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies), over the fixture
# images tools/erofs_fixtures.rb wrote with mkfs.erofs. The fuzz target,
# tools/fuzz/erx_erofs.rb, seeds the reader's faults.
class ErxErofsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[otp/erts/preloaded/src/erx_verity.erl otp/erts/preloaded/src/erx_erofs.erl
               test/erlang/erx_erofs_tests.erl].map { |path| File.join(ROOT, path) }.freeze
  INCLUDE = File.join(ROOT, 'erlang/apps/erx/include')
  FIXTURES = File.join(ROOT, 'test/fixtures/erofs')

  def test_reader_cases_pass_under_eunit
    output, status = eunit
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  private

  def eunit
    Dir.mktmpdir('erx-erofs-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-o', work, *SOURCES,
                                       stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e({ 'ERX_EROFS_FIXTURES' => FIXTURES }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_erofs_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
