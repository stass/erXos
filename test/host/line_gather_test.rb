# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'

# erx-gate: sanitizers

# The line gather a domain's runtime writes its C output through (docs/design-runtime.md,
# "The console and standard I/O"): ERTS's byte-at-a-time writes must reach the debug log
# as one record per line. Each seed must make the driver name the check it broke; the
# first passes every byte on as it comes, which is what the console saw with no gather.
class LineGatherTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = File.join(ROOT, 'liberx/backend/core/line_gather.c')
  DRIVER = File.join(ROOT, 'test/fixtures/line_gather_driver.c')

  # name => [original, replacement, the diagnostic]. An overflow seed builds under
  # AddressSanitizer, whose report is the diagnostic.
  SEEDS = {
'every byte passed on' => ["\tgather->bytes[gather->length++] = byte;\n",
                           "\tgather->bytes[gather->length++] = byte;\n\tline_gather_flush(gather, emit, context);\n",
                           'bytewise lines'],
'no flush at a newline' => ["\t\t\tgather->returns = 0;\n\t\t\tline_gather_flush(gather, emit, context);\n", "\t\t\tgather->returns = 0;\n",
                            'bytewise lines'],
    'a full buffer flushed one byte late' => ['if (gather->length == sizeof(gather->bytes))', 'if (gather->length > sizeof(gather->bytes))',
                                              'global-buffer-overflow'],
    'a carriage return stored at once' => ["\t\t\tgather->returns++;\n", "\t\t\tline_gather_put(gather, '\\r', emit, context);\n", 'bytewise lines'],
    'a full buffer flushed after the store' => ["\tif (gather->length == sizeof(gather->bytes))\n\t\tline_gather_flush(gather, emit, context);\n\tgather->bytes[gather->length++] = byte;\n",
                                               "\tgather->bytes[gather->length++] = byte;\n\tif (gather->length == sizeof(gather->bytes))\n\t\tline_gather_flush(gather, emit, context);\n",
                                               'full line']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-line-gather-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(core, name:, flags: @sanitizer_flags)
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *flags, *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'), '-I', ROOT,
                                  core, DRIVER, '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def test_lines_come_out_whole
    log, status = Open3.capture2e(build(CORE, name: 'gather'), stdin_data: '')
    assert status.success?, log
    assert_match(/\Aline_gather: [1-9]/, log)
  end

  SEEDS.each do |name, (original, replacement, diagnostic)|
    define_method("test_seed_#{name.tr(' ', '_')}") do
      source = File.read(CORE)
      assert_includes source, original, 'the seed no longer applies'
      seeded = File.join(@directory, 'line_gather.c')
      File.write(seeded, source.sub(original) { replacement })
      flags = diagnostic.include?('overflow') ? %w[-fsanitize=address -fno-omit-frame-pointer] : []
      log, status = Open3.capture2e(build(seeded, name: "seed-#{name}", flags: flags), stdin_data: '')
      refute status.success?, "#{name}: the driver saw nothing: #{log}"
      assert_includes log, diagnostic
    end
  end
end
