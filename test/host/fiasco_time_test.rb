# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'

# erx-gate: sanitizers

# The time page's scale and the deadline's wait, on the host (docs/design-stopgap.md,
# "Deadlines"): the driver holds them to exact arithmetic, and each seed below must
# make it name what it broke. liberx/backend/fiasco/time_table.c is the core.
class FiascoTimeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'liberx/backend/fiasco/time_table.c'
  DRIVER = 'test/fixtures/fiasco_time_driver.c'

  # name => [original, replacement, the driver's diagnostic].
  MUTANTS = {
    'the scale rounded down' => ["\tif (remainder != 0)\n\t\tscale.mult++;\n", '', 'gives'],
    'a shift too small' => ['scale.mult >> 62 == 0', 'scale.mult >> 40 == 0', 'gives'],
    'a wait rounded down' => ['(deadline_ns - now_ns - 1) / TIME_NS_PER_US + 1', '(deadline_ns - now_ns) / TIME_NS_PER_US', 'a wait of'],
    'a wait past the maximum' => ['wait_us < max_us ? wait_us : max_us', 'wait_us + 0 * max_us', 'a long wait'],
    'a zero frequency divides' => ["if (hz == 0 || hz >> 63 != 0)\n\t\treturn (scale);\n", "if (hz == 0)\n\t\thz = 1;\n", 'time zero']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-fiasco-time-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(core, name:, flags: @sanitizer_flags)
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *flags, *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'), '-I', ROOT, core, File.join(ROOT, DRIVER), '-o', output,
                                  stdin_data: '')
    assert status.success?, log
    output
  end

  def test_scale_and_wait_agree_with_exact_arithmetic
    log, status = Open3.capture2e(build(File.join(ROOT, CORE), name: 'time'), stdin_data: '')
    assert status.success?, log
    assert_match(/\Atime: [1-9]\d* cases/, log)
  end

  MUTANTS.each do |name, (original, replacement, diagnostic)|
    define_method("test_mutant_#{name.tr(' ', '_')}") do
      source = File.read(File.join(ROOT, CORE))
      assert_includes source, original
      seeded = File.join(@directory, "#{name.tr(' ', '-')}.c")
      File.write(seeded, source.sub(original) { replacement })
      log, status = Open3.capture2e(build(seeded, name: "#{name} driver", flags: []), stdin_data: '')
      refute status.success?, "#{name}: the driver passed: #{log}"
      assert_includes log, diagnostic
    end
  end
end
