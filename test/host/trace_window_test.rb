# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'

# erx-gate: sanitizers

# map_trace's decision and the root's reader of the kernel's rings through its window
# (docs/design-fiasco.md, "The kernel's trace rings", "The root's window" and "Reading"):
# test/fixtures/trace_window_driver.c runs each case, and each seed below must make its case
# name what it broke.
class TraceWindowTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  WINDOW = 'kernel/core/trace_window.c'
  READER = 'liberx/backend/fiasco/trace_window.c'
  RING = 'kernel/core/trace_ring.c'
  DRIVER = 'test/fixtures/trace_window_driver.c'
  MODES = %w[window refusals reader].freeze

  # name => [file, original, replacement, mode, the driver's diagnostic].
  SEEDS = {
    'the once-per-boot check removed' => [WINDOW, "\tif (call->mapped)\n\t\treturn ((erx_trace_window_t){ .verdict = ERX_TRACE_WINDOW_MAPPED });\n",
                                          '', 'window', 'second call was not refused'],
    'the size check removed' => [WINDOW, 'return (limits->rings_bytes - 1 <= last_offset);', 'return (true);',
                                 'window', 'smaller than the rings was accepted'],
    'the exact fit refused' => [WINDOW, 'limits->rings_bytes - 1 <= last_offset', 'limits->rings_bytes <= last_offset',
                                'window', "exactly the rings' size was refused"],
    'the window maps its whole size' => [WINDOW, '.bytes = limits->rings_bytes', '.bytes = UINT64_C(1) << call->order',
                                         'window', "rings' pages alone"],
    'the whole-page check removed' => [WINDOW, ' || (limits->rings_bytes & ((UINT64_C(1) << limits->page_order) - 1)) != 0', '',
                                       'window', 'rings of part of a page'],
    'the user bound removed' => [WINDOW, ' ||
	    call->base > limits->user_last - last_offset)', ')', 'refusals', 'past user space was accepted'],
    'the alignment check removed' => [WINDOW, '(call->base & last_offset) != 0 || ', '', 'refusals', 'not aligned to its size'],
    'the word count unchecked' => [WINDOW, 'call->words != ERX_FIASCO_PFC_MAP_TRACE_WORDS || ', '', 'refusals', 'wrong word count'],
    'the resource unchecked' => [READER, "\tif (res != ERX_ROOT_SLOT_ROOT_RESOURCE)\n\t\treturn (ERX_ERIGHTS);\n", "\t(void)res;\n", 'reader',
                                 'other than the root resource'],
    'the cpu bound widened' => [READER, 'if (cpu >= count)', 'if (cpu > count)', 'reader', 'past the rings mapped']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-trace-window-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build(window: File.join(ROOT, WINDOW), reader: File.join(ROOT, READER), name: 'window')
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *@sanitizer_flags, *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'), '-I', ROOT, window, reader, File.join(ROOT, RING),
                                  File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def run_driver(driver, mode) = Open3.capture2e(driver, mode, stdin_data: '')

  def test_every_case_passes
    driver = build
    MODES.each do |mode|
      log, status = run_driver(driver, mode)
      assert status.success?, log
      assert_equal "#{mode}: ok\n", log
    end
  end

  SEEDS.each do |name, (file, original, replacement, mode, diagnostic)|
    define_method("test_seed_#{name.tr(' ', '_').delete('-')}") do
      source = File.read(File.join(ROOT, file))
      assert_equal 1, source.scan(original).size, "the seed's text is not in #{file} once"
      seeded = File.join(@directory, "#{name.tr(' ', '-')}.c")
      File.write(seeded, source.sub(original, replacement))
      driver = build(**(file == WINDOW ? { window: seeded } : { reader: seeded }), name: name)
      log, status = run_driver(driver, mode)
      refute status.success?, "#{name}: #{mode} passed"
      assert_includes log, diagnostic
    end
  end
end
