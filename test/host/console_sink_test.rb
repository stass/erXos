# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'

# Only erx_console sends bytes to the console's driver, and only a console driver takes
# them (docs/design-runtime.md, "The console and standard I/O"). The chokepoint engine reads
# C, so this rule over Erlang sources lives here. A new driver is a new site.
class ConsoleSinkTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SITES = %w[otp/lib/kernel/src/erx_console.erl otp/lib/kernel/src/erx_stdio.erl].freeze
  PATTERN = /\berx_console_output\b/

  def offenders(files) = files.select { |path, text| !SITES.include?(path) && PATTERN.match?(text) }.keys

  def test_no_other_erlang_source_names_the_drivers_output_message
    paths = Dir.glob('otp/{lib,erts}/**/*.{erl,hrl}', base: ROOT)
    files = paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    assert_includes paths, SITES.first
    assert_empty offenders(files)
    SITES.each { |site| assert_match PATTERN, files.fetch(site) }
  end

  def test_the_rule_catches_a_new_writer
    seeded = { 'otp/lib/stdlib/src/seeded.erl' => "f(D) -> D ! {erx_console_output, none, <<>>}.\n" }
    assert_equal seeded.keys, offenders(seeded)
  end
end
