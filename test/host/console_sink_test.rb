# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../fixtures/generated_tree'

# Each UART line has one sink, the one process that sends its driver bytes, and only a UART
# driver takes them: erx_console for the console's line (docs/design-runtime.md, "The console
# and standard I/O"), with erx_stdio, its client module, and erx_hostlink for the host link's
# (docs/design-live.md, "The host link"). The chokepoint engine reads C, so this rule over
# Erlang sources lives here. A new driver or line is a new site. The generated Erlang in
# build/gen is read under the path it mirrors, as the chokepoint rules read generated C.
class ConsoleSinkTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SITES = %w[erlang/apps/erx_uart/src/erx_pl011.erl erlang/apps/erx/src/erx_console.erl erlang/apps/erx/src/erx_stdio.erl
             erlang/apps/erx_hostlink/src/erx_hostlink.erl].freeze
  PATTERN = /\berx_console_output\b/

  def offenders(files) = files.select { |path, text| !SITES.include?(path) && PATTERN.match?(text) }.keys

  def test_no_other_erlang_source_names_the_drivers_output_message
    pattern = '{otp/lib,otp/erts,erlang/apps}/**/*.{erl,hrl}'
    generated = File.join(ROOT, Erx::Generated::OUTPUT)
    tree = Dir.glob(pattern, base: ROOT).to_h { |path| [path, File.join(ROOT, path)] }
    made = Dir.glob(pattern, base: generated).to_h { |path| [path, File.join(generated, path)] }
    refute_empty made, 'the generated tree holds Erlang sources'
    paths = tree.keys | made.keys
    files = tree.merge(made).transform_values { |file| File.binread(file) }
    assert_includes paths, SITES.first
    assert_empty offenders(files)
    SITES.each { |site| assert_match PATTERN, files.fetch(site) }
  end

  def test_the_rule_catches_a_new_writer
    seeded = { 'otp/lib/stdlib/src/seeded.erl' => "f(D) -> D ! {erx_console_output, none, <<>>}.\n" }
    assert_equal seeded.keys, offenders(seeded)
  end
end
