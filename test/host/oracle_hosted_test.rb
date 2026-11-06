# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/oracle_hosted'

# The hosted runtime's command line, which no run is needed to check.
class OracleHostedTest < Minitest::Test
  def command = Erx::OracleHosted.erxos_command(beam: '/b/beam.emu', archive: '/a/release.pack', suites: %w[x_SUITE])

  def code_paths = command.each_cons(2).filter_map { |flag, value| value if flag == '-pa' }

  def test_no_directory_is_given_twice_with_pa
    assert_equal code_paths.uniq, code_paths
  end

  # The code server lists every application under /lib itself, so a -pa for one puts it on the
  # path a second time and code_SUITE's set_path, add_path and add_paths fail.
  def test_no_application_under_lib_is_given_with_pa
    assert_empty code_paths.select { |path| path.start_with?('/lib/') }
  end

  def test_the_reporter_and_the_suites_are_passed
    assert_includes code_paths, '/test/ct/reporter'
    assert_equal %w[x_SUITE], command.last(1)
  end
end
