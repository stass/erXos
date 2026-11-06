# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# erx-gate: sanitizers

# The group report's pure part, on the host (docs/design-stopgap.md, "The command line"):
# the executor count and the line both backends' reporters write. The driver holds them
# to exact text and to the buffer they are given, and each seed below must make it name
# what it broke. liberx/backend/core/group_report.h is the core.
class GroupReportTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'liberx/backend/core/group_report.h'
  DRIVER = 'test/fixtures/group_report_driver.c'

  # name => [original, replacement, the driver's diagnostic].
  MUTANTS = {
    'an empty slot counted' => ['!= ERX_EXEC_STATE_NONE', '!= ERX_EXEC_STATE_PAUSED', 'an empty page counts executors'],
    'the last slot skipped' => ['slot < ERX_GROUP_EXECUTORS_MAX; slot++) {', 'slot + 1 < ERX_GROUP_EXECUTORS_MAX; slot++) {', 'last slots'],
    'no room left for the NUL' => ['if (length >= size) {', 'if (length > size) {', 'wrote past'],
    'a count one digit short' => ['} while (value != 0);', '} while (value >= 10);', 'reads wrongly']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-group-report-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  # The driver, built against the tree's headers with a seeded root's ahead of them.
  def build(name:, seeded_root: nil, flags: @sanitizer_flags)
    output = File.join(@directory, name.tr(' ', '-'))
    includes = [seeded_root, ROOT].compact.flat_map { |root| ['-I', root] }
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *flags, '-I', File.join(ROOT, 'include'), *includes, File.join(ROOT, DRIVER), '-o', output,
                                  stdin_data: '')
    assert status.success?, log
    output
  end

  def test_count_and_line_hold
    log, status = Open3.capture2e(build(name: 'report'), stdin_data: '')
    assert status.success?, log
    assert_match(/\Agroup report: [1-9]\d* cases, 0 failures\n\z/, log)
  end

  MUTANTS.each do |name, (original, replacement, diagnostic)|
    define_method("test_mutant_#{name.tr(' ', '_')}") do
      source = File.read(File.join(ROOT, CORE))
      assert_includes source, original
      seeded_root = File.join(@directory, name.tr(' ', '-'))
      seeded = File.join(seeded_root, CORE)
      FileUtils.mkdir_p(File.dirname(seeded))
      File.write(seeded, source.sub(original) { replacement })
      log, status = Open3.capture2e(build(name: "#{name} driver", seeded_root:, flags: []), stdin_data: '')
      refute status.success?, "#{name}: the driver passed: #{log}"
      assert_includes log, diagnostic
    end
  end
end
