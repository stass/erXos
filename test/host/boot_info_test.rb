# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'

# erx-gate: sanitizers

# The boot information page and the command line (docs/design-stopgap.md, "Boot
# information" and "The command line"): liberx/backend/core/boot_info.c and
# liberx/backend/fiasco/boot_args.c at every limit, driven by
# test/fixtures/boot_info_driver.c. Each seed below must make the driver name what it broke.
class BootInfoTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  INFO = 'liberx/backend/core/boot_info.c'
  ARGS = 'liberx/backend/fiasco/boot_args.c'
  WATCHDOG = 'kernel/core/watchdog.c'
  DRIVER = 'test/fixtures/boot_info_driver.c'

  # name => [source, original, replacement, the driver's diagnostic].
  MUTANTS = {
    'an unchecked args_off' => [INFO, 'span_ok(info->args_off, info->args_len, fixed, size)', 'true', 'bounds'],
    'a strings limit one too wide' => [INFO, 'need > ERX_BOOT_STRINGS_MAX - *total', 'need > ERX_BOOT_STRINGS_MAX + 1 - *total', 'strings limit'],
    'a word past the limit accepted' => [ARGS, 'length + 1 > ERX_BOOT_STRINGS_MAX - out->arg_bytes', 'false', 'erx.arg limit'],
    'an empty word let through' => [INFO, 'if (word == 0)', 'if (false)', 'word list'],
    'the page marked before the checks' => [INFO, "\tif (status != ERX_BOOT_INFO_OK)\n\t\treturn (status);\n\tif (size < fixed", "\tmemset(page, 0, size);\n\tif (status != ERX_BOOT_INFO_OK)\n\t\treturn (status);\n\tif (size < fixed", 'untouched']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-boot-info-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(sources, name:)
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *@flags, *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'), '-I', ROOT, *sources, File.join(ROOT, DRIVER), '-o', output,
                                  stdin_data: '')
    assert status.success?, log
    output
  end

  def sources = [INFO, ARGS, WATCHDOG].map { |source| File.join(ROOT, source) }

  def test_the_page_and_the_command_line_at_every_limit
    output, status = Open3.capture2e(build(sources, name: 'driver'), stdin_data: '')
    assert status.success?, output
    assert_match(/\Aboot info: ok\n/, output)
  end

  MUTANTS.each do |name, (source, original, replacement, diagnostic)|
    define_method("test_#{name.tr(' ', '_')}_is_caught") do
      text = File.read(File.join(ROOT, source))
      assert_includes text, original
      seeded = File.join(@directory, "seeded_#{File.basename(source)}")
      File.write(seeded, text.sub(original) { replacement })
      output, status = Open3.capture2e(build(sources.map { |path| path.end_with?(source) ? seeded : path }, name: name), stdin_data: '')
      refute status.success?, "#{name} went unnoticed"
      assert_match(/#{diagnostic}/, output)
    end
  end
end
