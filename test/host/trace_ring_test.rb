# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/native_root'

# erx-gate: sanitizers

# The stopgap's trace ring and its lock-free reader on the host (docs/design-stopgap.md,
# "The trace ring", and its Verification row): test/fixtures/trace_ring_driver.c runs
# each case, and each seed below must make its case name what it broke.
class TraceRingTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  RING = 'liberx/backend/core/trace_ring.c'
  STUB = 'liberx/backend/fiasco/trace_stub.c'
  DRIVER = 'test/fixtures/trace_ring_driver.c'
  MODES = %w[basic refusals bounded lapped between writing exhausted race].freeze

  # name => [original, replacement, mode, the driver's diagnostic].
  SEEDS = {
    'the second seq load removed' => ["loaded &= erx_trace_record_seq_load(record, &after);", 'after = before;', 'between', 'rewritten during its read was kept'],
    'the present cursor returns 0' => ['*result = (erx_trace_read_result_t){ .next = head };', '*result = (erx_trace_read_result_t){ .next = 0 };', 'basic', 'present cursor'],
    'the skip counted one short' => ['lost = head - ERX_TRACE_RING_RECORDS - cursor;', 'lost = head - ERX_TRACE_RING_RECORDS - cursor - 1;', 'lapped', 'lapped count differs'],
    'the cursor check removed' => ["\tif (cursor > head)\n\t\treturn (ERX_EINVAL);\n", '', 'refusals', 'past the head was accepted'],
    'the max bound removed' => [' || max > ERX_TRACE_READ_MAX)', ')', 'refusals', 'max 513 was accepted'],
    'a read ignores max' => ['count = head - cursor < max ? head - cursor : max;', 'count = head - cursor;', 'bounded', 'did not copy four'],
    'the terminal check removed' => ["if (index > ERX_TRACE_RING_INDEX_LAST)\n\t\treturn (false);\n", '', 'exhausted', 'past the last index was accepted'],
    'the exhausted head not refused' => ["\tif (cursor == head && head == ERX_TRACE_RING_HEAD_EXHAUSTED)\n\t\treturn (ERX_ELIMIT);\n", '', 'exhausted', 'was not ERX_ELIMIT'],
    'the odd store moved after the fields' => ["\t(void)erx_trace_record_seq_store(record, 2 * index + 1);\n\t(void)erx_trace_record_time_ns_store(record, entry->time_ns);\n",
                                               "\t(void)erx_trace_record_time_ns_store(record, entry->time_ns);\n", 'writing', 'read while written was kept']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-trace-ring-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build(source, name:, flags: [])
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-pthread',
                                  *@sanitizer_flags, *flags, '-I', File.join(ROOT, 'include'), '-I', ROOT, source,
                                  File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def ring_driver(source = File.join(ROOT, RING), name: 'ring') = build(source, name: name, flags: ['-DERX_TRACE_RING_TEST_HOOKS'])

  def run_driver(driver, mode) = Open3.capture2e(driver, mode, stdin_data: '')

  def test_every_case_passes
    driver = ring_driver
    MODES.each do |mode|
      log, status = run_driver(driver, mode)
      assert status.success?, log
      assert_equal "#{mode}: ok\n", log
    end
  end

  def test_a_task_has_no_ring
    driver = build(File.join(ROOT, STUB), name: 'stub', flags: ['-DTRACE_RING_STUB'])
    log, status = run_driver(driver, 'stub')
    assert status.success?, log
    assert_equal "stub: ok\n", log
  end

# Only the root links the ring: a task's program links the stub in its place.
def test_only_the_root_links_the_ring
  assert_includes Erx::NativeRoot::SERVICE, RING
  refute_includes Erx::NativeRoot::SERVICE, STUB
  assert_includes Erx::NativeRoot::TASK, STUB
  refute_includes Erx::NativeRoot::TASK, RING
end

  SEEDS.each do |name, (original, replacement, mode, diagnostic)|
    define_method("test_seed_#{name.tr(' ', '_')}") do
      source = File.read(File.join(ROOT, RING))
      assert_equal 1, source.scan(original).size, "the seed's text is not in #{RING} once"
      seeded = File.join(@directory, "#{name.tr(' ', '-')}.c")
      File.write(seeded, source.sub(original, replacement))
      log, status = run_driver(ring_driver(seeded, name: name), mode)
      refute status.success?, "#{name}: #{mode} passed"
      assert_includes log, diagnostic
    end
  end
end
