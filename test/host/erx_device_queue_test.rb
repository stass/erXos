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
  # The sequencer and a host DMA architecture layer that counts its maintenance, which erx_device.c's queues run through.
  DMA = [File.join(NIFS, 'erx_device_dma.c'), File.join(NIFS, 'erx_device_genet.c'), File.join(ROOT, 'test/fixtures/erx_dma_arch_counting.c')].freeze
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  def test_posts_completions_refusals_and_resets
    output = run_harness(File.join(ROOT, 'test/fixtures/erx_device_queue_harness.c'), CORE)
    assert_match(/^erx_device_queue done$/, output)
  end

  def test_queues_on_a_device
    output = run_harness(File.join(ROOT, 'test/fixtures/erx_device_dma_harness.c'), CORE,
                         File.join(NIFS, 'erx_device.c'), File.join(NIFS, 'erx_device_core.c'), *DMA,
                         includes: [File.join(ROOT, 'test/fixtures/device_model')])
    assert_match(/^erx_device_dma done$/, output)
  end

  def test_the_register_ring_on_a_device
    assert_match(/^erx_device_genet done$/, genet_output)
  end

  # The seeds of the register ring's effect layer, each of which fails the GENET harness: the
  # idle test reading only the receive direction (docs/design-device-dma.md, Verification,
  # "GENET's stop"), so the receive ring is installed while the transmit engine runs; and the
  # register lookup narrowed to owned registers, so the idle report of DMA status, which the
  # NIF does not own, reaches no register and the negotiation is refused.
  GENET_SEEDS = {
    idle_rx_only: ["\t\tidle = idle && shown == ERX_OK;\n",
                   "\t\tidle = side == 1 ? idle : shown == ERX_OK;\n"],
    owned_lookup: ["\t\tif (offset < reg->offset)\n\t\t\tcontinue;\n",
                   "\t\tif (offset < reg->offset || !reg->owned_by_nif)\n\t\t\tcontinue;\n"]
  }.freeze

  GENET_SEEDS.each do |name, seed|
    define_method(:"test_a_register_ring_seeded_with_#{name}_fails_the_harness") do
      assert_match(/FAILED .*erx_device_genet_harness\.c/, genet_output(seed))
    end
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

  # The effect layer keeps each queue's last accepted state as the next plan's `before`; seeded
  # to keep none, a later post or completion is refused by the check and the harness fails.
  def test_a_queue_that_keeps_no_state_fails_the_harness
    output = seeded_dma_output(["\tif (after != &record->state)\n\t\trecord->state = *after;\n", "\t(void)after;\n"])
    assert_match(/FAILED .*erx_device_dma_harness\.c/, output)
  end

  # The seeded fault of the core's post: each descriptor's address one byte past its segment.
  # The harness reads the descriptors back from the post's ring-write steps and refuses it.
  POST_SEED = ['device_base + buffer + taken->offset, taken->length);',
               'device_base + buffer + taken->offset + 1, taken->length);'].freeze

  def test_a_post_seeded_with_an_address_off_by_one_fails_the_harness
    text = File.read(CORE)
    assert_includes text, POST_SEED.first
    Dir.mktmpdir('erx-device-queue-seed-') do |directory|
      core = File.join(directory, 'erx_device_queue.c')
      File.write(core, text.sub(*POST_SEED))
      output, status = harness_output(File.join(ROOT, 'test/fixtures/erx_device_queue_harness.c'), core)
      refute status.success?, output
      assert_match(/erx_device_queue_harness\.c:\d+: .*\baddr\b/, output)
    end
  end

  private

  GENET_HARNESS = File.join(ROOT, 'test/fixtures/erx_device_genet_harness.c')

  # The GENET harness's output over erx_device.c, with `seed` applied when one is given.
  def genet_output(seed = nil)
    Dir.mktmpdir('erx-device-genet-') do |directory|
      source = File.join(NIFS, 'erx_device.c')
      if seed
        text = File.read(source)
        assert_includes text, seed.first
        source = File.join(directory, 'erx_device.c')
        File.write(source, text.sub(*seed))
      end
      output, status = harness_output(GENET_HARNESS, CORE, source, File.join(NIFS, 'erx_device_core.c'), *DMA,
                                      includes: [File.join(ROOT, 'test/fixtures/device_model')])
      assert_equal seed.nil?, status.success?, output
      output
    end
  end

  # The DMA harness's output over erx_device.c with `seed` applied.
  def seeded_dma_output(seed)
    source = File.read(File.join(NIFS, 'erx_device.c'))
    assert_includes source, seed.first
    Dir.mktmpdir('erx-device-region-seed-') do |directory|
      seeded = File.join(directory, 'erx_device.c')
      File.write(seeded, source.sub(*seed))
      output, = harness_output(File.join(ROOT, 'test/fixtures/erx_device_dma_harness.c'), CORE, seeded,
                               File.join(NIFS, 'erx_device_core.c'), *DMA, includes: [File.join(ROOT, 'test/fixtures/device_model')])
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
