# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'

# erx-gate: sanitizers

# The machine and CPU reports of erx_object_info on the Phase 1 backends, on the host
# (docs/design-stopgap.md, "Reporting kernel objects"): a reported bit is set exactly
# for a fact the backend gave. liberx/backend/core/object_info.c is the core, and each
# seed below drops one bit, which the driver must name.
class ObjectInfoTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'liberx/backend/core/object_info.c'
  DRIVER = 'test/fixtures/object_info_driver.c'

  # name => [original, replacement, the driver's diagnostic].
  MUTANTS = {
    'build dropped' => ['ERX_INFO_MACHINE_REPORTED_BUILD | ERX_INFO_MACHINE_REPORTED_BOOT_VALUE;',
                        'ERX_INFO_MACHINE_REPORTED_BOOT_VALUE;', 'build not reported'],
    'boot_value dropped' => ['ERX_INFO_MACHINE_REPORTED_BUILD | ERX_INFO_MACHINE_REPORTED_BOOT_VALUE;',
                             'ERX_INFO_MACHINE_REPORTED_BUILD;', 'boot_value not reported'],
    'reported without a handoff' => ['if (facts->boot_known) {', 'if (true) {', 'reported without a handoff']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-object-info-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  # The driver and the core, the core read from CORE_ROOT.
  def build(name:, core_root: ROOT, flags: @sanitizer_flags)
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *flags, *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'), '-I', ROOT, File.join(ROOT, DRIVER),
                                  File.join(core_root, CORE), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def test_reports_hold
    log, status = Open3.capture2e(build(name: 'report'), stdin_data: '')
    assert status.success?, log
    assert_match(/\Aobject info: [1-9]\d* cases, 0 failures\n\z/, log)
  end

  MUTANTS.each do |name, (original, replacement, diagnostic)|
    define_method("test_mutant_#{name.tr(' ', '_')}") do
      source = File.read(File.join(ROOT, CORE))
      assert_includes source, original
      core_root = File.join(@directory, name.tr(' ', '-'))
      seeded = File.join(core_root, CORE)
      FileUtils.mkdir_p(File.dirname(seeded))
      File.write(seeded, source.sub(original) { replacement })
      log, status = Open3.capture2e(build(name: "#{name} driver", core_root:, flags: []), stdin_data: '')
      refute status.success?, "#{name}: the driver passed: #{log}"
      assert_includes log, diagnostic
    end
  end
end
