# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# GENET's register ring (docs/design-device-dma.md, "The three descriptor forms"): the form's
# pure core, erx_device_genet, driven with a stand-in controller through the check and the
# sequencer over the hosted model of a non-coherent cache
# (test/fixtures/erx_device_genet_model_harness.c), clean under the address and undefined
# sanitizers. Each seeded fault is planted and shown to fail an assertion.
class ErxDeviceGenetTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  HARNESS = 'test/fixtures/erx_device_genet_model_harness.c'
  SOURCES = %w[erx_device_genet.c erx_device_dma.c erx_dma_model.c erx_device_core.c].freeze
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  # Each planted fault: the sequencer's (each fails a byte comparison over the model), the
  # check's register reach, the core's receive length bound, and two bits the stand-in
  # controller checks: a transmit descriptor's append-CRC bit (a frame sent without its
  # Ethernet CRC) and the engine's enable in the start (rings that never run).
  SEEDS = %w[ERX_DMA_SEED_NO_CLEAN ERX_DMA_SEED_NO_TAKE_BACK ERX_DMA_SEED_STEP_BY_GRANULE
             ERX_DMA_SEED_NO_BUFFER_HANDOVER ERX_DMA_SEED_NO_ZEROING ERX_DMA_SEED_NO_REG_REACH
             ERX_DEVICE_GENET_SEED_NO_LENGTH_BOUND ERX_DEVICE_GENET_SEED_NO_TX_CRC
             ERX_DEVICE_GENET_SEED_NO_DMA_ENABLE].freeze
  # The harness check a seed must fail where one check alone guards what it removes; any
  # other seed may fail wherever its fault first shows.
  CAUGHT_BY = { 'ERX_DEVICE_GENET_SEED_NO_TX_CRC' => /^FAILED .*\(status & d->regs\.crc\)$/,
                'ERX_DEVICE_GENET_SEED_NO_DMA_ENABLE' => /^FAILED .*: running\(d\)$/ }.freeze

  def test_register_ring_over_a_non_coherent_cache
    output, status = run_harness
    assert status.success?, output
    assert_match(/^erx_device_genet_model done$/, output)
  end

  SEEDS.each do |seed|
    define_method("test_seed_#{seed.downcase}") do
      output, status = run_harness("-D#{seed}")
      refute status.success?, "#{seed} went unnoticed:\n#{output}"
      assert_match(CAUGHT_BY.fetch(seed, /^FAILED /), output)
    end
  end

  private

  def run_harness(*defines)
    Dir.mktmpdir('erx-device-genet-') do |directory|
      binary = File.join(directory, 'harness')
      sources = [File.join(ROOT, HARNESS), *SOURCES.map { |source| File.join(NIFS, source) }]
      output, status = Open3.capture2e(COMPILER, *FLAGS, *defines, *Erx::Generated.include_flags(root: ROOT),
                                       '-I', NIFS, '-I', ROOT, '-o', binary, *sources)
      return [output, status] unless status.success?

      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    end
  end
end
