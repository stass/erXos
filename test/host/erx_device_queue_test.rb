# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The pure core of a device's queue (test/fixtures/erx_device_queue_harness.c), and the
# effects that put it on a virtio-mmio device the harness plays
# (test/fixtures/erx_device_dma_harness.c), clean under the address and undefined sanitizers.
class ErxDeviceQueueTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  CORE = File.join(NIFS, 'erx_device_queue.c')
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  def test_posts_completions_refusals_and_resets
    output = run_harness(File.join(ROOT, 'test/fixtures/erx_device_queue_harness.c'), CORE)
    assert_match(/^erx_device_queue done$/, output)
  end

  def test_queues_on_a_device
    output = run_harness(File.join(ROOT, 'test/fixtures/erx_device_dma_harness.c'), CORE,
                         File.join(NIFS, 'erx_device.c'), File.join(NIFS, 'erx_device_core.c'),
                         includes: [File.join(ROOT, 'test/fixtures/device_model')])
    assert_match(/^erx_device_dma done$/, output)
  end

  # The seeded faults of docs/design-runtime.md, "Regions": a region that leaves its pages to
  # the next queue, so the two overlap; a post that takes another device's region; and a region
  # made on a device that is not coherent. Each fails the regions scenario.
  REGION_SEEDS = {
    overlap: ["\tbzero(record->mapping, carve.length);\n\t*taken = carve.end;\n",
              "\tbzero(record->mapping, carve.length);\n"],
    foreign: ['regions_open, memory_order_relaxed) || regions[region].device != device)',
              'regions_open, memory_order_relaxed) || (false && regions[region].device != device))'],
    coherent: ['device->form == ERX_DEVICE_FORM_PHYSICAL || !device->coherent)',
               'device->form == ERX_DEVICE_FORM_PHYSICAL)']
  }.freeze

  # One test for each seed above, named after it.
  REGION_SEEDS.each do |name, seed|
    define_method(:"test_a_region_seeded_with_#{name}_fails_the_harness") do
      output = seeded_dma_output(seed)
      assert_match(/FAILED .*erx_device_dma_harness\.c/, output)
      refute_match(/^regions ok$/, output)
    end
  end

  private

  # The DMA harness's output over erx_device.c with `seed` applied.
  def seeded_dma_output(seed)
    source = File.read(File.join(NIFS, 'erx_device.c'))
    assert_includes source, seed.first
    Dir.mktmpdir('erx-device-region-seed-') do |directory|
      seeded = File.join(directory, 'erx_device.c')
      File.write(seeded, source.sub(*seed))
      output, = harness_output(File.join(ROOT, 'test/fixtures/erx_device_dma_harness.c'), CORE, seeded,
                               File.join(NIFS, 'erx_device_core.c'), includes: [File.join(ROOT, 'test/fixtures/device_model')])
      output
    end
  end

  def run_harness(*sources, includes: [])
    output, status = harness_output(*sources, includes: includes)
    assert status.success?, output
    output
  end

  # The harness built from `sources` and run, with its output and exit status. Directories in
  # includes come first, so the DMA harness's device model replaces the generated register
  # accesses. A build failure fails the test.
  def harness_output(*sources, includes: [])
    Dir.mktmpdir('erx-device-queue-') do |directory|
      binary = File.join(directory, 'harness')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *includes.flat_map { |dir| ['-I', dir] },
                                       *Erx::Generated.include_flags(root: ROOT), '-I', ROOT,
                                       '-I', File.join(ROOT, 'include'), '-I', NIFS,
                                       *sources, '-o', binary, stdin_data: '')
      assert status.success?, output
      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    end
  end
end
