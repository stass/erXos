# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/manifest_text'
require_relative '../../tools/lib/erx/platform'

# ManifestText, the one edit harnesses make to a manifest's numbers
# (tools/lib/erx/manifest_text.rb).
class ManifestTextTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCE = "# memory 1 in a comment\nprincipal system\n  memory 10\n  domains 2\nprincipal other\n  memory 20\n" \
           "machine\n  root_memory 100\n  max_domains 4\n"

  # A field is reached through its record: the other principal's memory, the comment
  # and every other line stay as they were.
  def test_grow_and_set_edit_only_the_named_records_field
    grown = Erx::ManifestText.grow(SOURCE, { ['principal system', 'memory'] => 5, %w[machine root_memory] => -1 })
    assert_equal SOURCE.sub('  memory 10', '  memory 15').sub('  root_memory 100', '  root_memory 99'), grown
    assert_equal SOURCE.sub('  max_domains 4', '  max_domains 7'), Erx::ManifestText.set(SOURCE, %w[machine max_domains] => 7)
  end

  # Every edit the harnesses make finds its field in the development manifest.
  def test_the_development_manifest_has_every_field_the_harnesses_edit
    source = Erx::Platform.development(ROOT).manifest_source(ROOT)
    fields = [%w[machine root_memory], %w[machine system_baseline], %w[machine max_domains], %w[machine max_connections],
              ['principal system', 'memory'], ['principal system', 'domains'], ['runtime_limits system', 'tmp']]
    assert_equal source, Erx::ManifestText.grow(source, fields.to_h { |field| [field, 0] })
  end

  # A record or field that is not there exactly once, a value that is not a decimal
  # number, and a result below zero are refused, never applied somewhere else.
  def test_an_edit_that_has_no_one_place_is_refused
    { %w[machine absent] => 1, ['principal absent', 'memory'] => 1, %w[nothing root_memory] => 1,
      %w[machine root_memory] => -101 }.each do |field, number|
      assert_raises(Erx::Error, field.join(' ')) { Erx::ManifestText.grow(SOURCE, { field => number }) }
    end
    ["machine\n  root_memory 1\nmachine\n  root_memory 2\n", "machine\n  root_memory 1\n  root_memory 2\n",
     "machine\n  root_memory 0x10\n", "machine\n  root_memory 1_000\n", "machine\n# a comment\n  root_memory 1\n"]
      .each do |source|
        assert_raises(Erx::Error, source) { Erx::ManifestText.grow(source, { %w[machine root_memory] => 1 }) }
      end
  end
end
