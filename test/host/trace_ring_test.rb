# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/native_root'
require_relative '../fixtures/generated_tree'

# erx-gate: sanitizers

# The Fiasco backend's trace ring and its lock-free reader on the host (docs/design-fiasco.md,
# "The trace ring", and its Verification row): test/fixtures/trace_ring_driver.c runs
# each case, and each seed below must make its case name what it broke.
class TraceRingTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  RING = 'kernel/core/trace_ring.c'
  ROOT_RING = 'liberx/backend/core/trace_ring.c'
  RINGS = 'kernel/core/trace_rings.c'
  STUB = 'liberx/backend/fiasco/trace_stub.c'
  DRIVER = 'test/fixtures/trace_ring_driver.c'
  RINGS_DRIVER = 'test/fixtures/trace_rings_driver.c'
  MODES = %w[basic refusals bounded lapped between writing exhausted clear race].freeze
  RINGS_MODES = %w[cpus wrap pages].freeze

  # The kernel's rings over the ring core: name => [file, original, replacement, mode, diagnostic].
  # A write past the last ring lands in the padding, which the driver reports, or past the
  # rings' pages, where it may fault before the driver prints: its diagnostic is nil.
  RINGS_SEEDS = {
    'the ring index not masked' => [RING, 'record = &ring->records[index % ERX_TRACE_RING_RECORDS];', 'record = &ring->records[index];',
                                    'wrap', 'wrap: '],
    'the cpu bound widened' => [RINGS, 'if (cpu >= ERX_TRACE_KERNEL_RINGS)', 'if (cpu >= ERX_TRACE_KERNEL_RINGS + 1)', 'cpus', nil],
    'the cpu ignored' => [RINGS, 'erx_trace_ring_put(&erx_trace_rings.ring[cpu], &written)', 'erx_trace_ring_put(&erx_trace_rings.ring[0], &written)',
                          'cpus', 'not hold exactly'],
    "the entry's cpu kept" => [RINGS, "\twritten.cpu = (uint16_t)cpu;\n", '', 'cpus', 'holds another CPU']
  }.freeze

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
                                               "\t(void)erx_trace_record_time_ns_store(record, entry->time_ns);\n", 'writing', 'read while written was kept'],
    'the head not cleared' => ["\t(void)erx_trace_ring_head_store(ring, 0);\n", '', 'clear', 'the head was not cleared']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-trace-ring-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build(source, name:, flags: [], driver: DRIVER)
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-pthread',
                                  *@sanitizer_flags, *flags, *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'), '-I', ROOT, source,
                                  File.join(ROOT, driver), '-o', output, stdin_data: '')
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

  # Only the root links the ring: a task's program links the stub in its place. The kernel's
  # rings are the kernel's alone.
  def test_only_the_root_links_the_ring
    assert_includes Erx::NativeRoot::SERVICE, RING
    assert_includes Erx::NativeRoot::SERVICE, ROOT_RING
    refute_includes Erx::NativeRoot::SERVICE, RINGS
    refute_includes Erx::NativeRoot::SERVICE, STUB
    assert_includes Erx::NativeRoot::TASK, STUB
    refute_includes Erx::NativeRoot::TASK, RING
  end

  def rings_driver(ring: File.join(ROOT, RING), rings: File.join(ROOT, RINGS), name: 'rings')
    build(ring, name: name, driver: RINGS_DRIVER, flags: [rings])
  end

  def test_the_kernel_rings_each_hold_their_cpu
    driver = rings_driver
    RINGS_MODES.each do |mode|
      log, status = run_driver(driver, mode)
      assert status.success?, log
      assert_equal "#{mode}: ok\n", log
    end
  end

  RINGS_SEEDS.each do |name, (file, original, replacement, mode, diagnostic)|
    define_method("test_rings_seed_#{name.tr(' ', '_')}") do
      source = File.read(File.join(ROOT, file))
      assert_equal 1, source.scan(original).size, "the seed's text is not in #{file} once"
      seeded = File.join(@directory, "#{name.tr(' ', '-')}.c")
      File.write(seeded, source.sub(original, replacement))
      log, status = run_driver(rings_driver(**(file == RING ? { ring: seeded } : { rings: seeded }), name: name), mode)
      refute status.success?, "#{name}: #{mode} passed"
      assert_includes log, diagnostic if diagnostic
    end
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
