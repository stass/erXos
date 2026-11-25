# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# erx-gate: sanitizers

# The one-shot timer's compare value on Fiasco (docs/design-fiasco.md, "The
# release's Fiasco build", "The timer's compare value"), on the host: the driver
# holds kernel/core/clock_inverse.c to the first count at which Fiasco's clock
# reads a wakeup, and each seed below must make it name what it broke.
class ClockInverseTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'kernel/core/clock_inverse.c'
  DRIVER = 'test/fixtures/clock_inverse_driver.c'

  # name => [original, replacement, the driver's diagnostic].
  MUTANTS = {
    'the count rounded down' => ['(part << bits) + scaler - 1', 'part << bits', 'gives'],
    'a count past the counter wraps' => ["\tif (whole > (UINT64_MAX - part_counts) >> bits)\n\t\treturn (UINT64_MAX);\n", '',
                                         'past the counter']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-clock-inverse-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(core, name:, flags: @sanitizer_flags)
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *flags, '-I', File.join(ROOT, 'include'), core, File.join(ROOT, DRIVER), '-o', output,
                                  stdin_data: '')
    assert status.success?, log
    output
  end

  def test_first_count_is_where_the_clock_reads_the_wakeup
    log, status = Open3.capture2e(build(File.join(ROOT, CORE), name: 'clock'), stdin_data: '')
    assert status.success?, log
    assert_match(/\Aclock: [1-9]\d* cases/, log)
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
