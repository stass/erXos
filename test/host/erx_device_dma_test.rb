# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The pure core of DMA by devices that are not cache-coherent (docs/design-device-dma.md,
# Verification): the sequencer and the whole-plan check over every transition of a small
# queue (test/fixtures/erx_device_dma_order_harness.c), and a split ring driven through them
# over the hosted model of a non-coherent cache (test/fixtures/erx_device_dma_model_harness.c),
# clean under the address and undefined sanitizers. Each seeded fault the design names is
# planted and shown to fail its assertion.
class ErxDeviceDmaTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  ORDER = { harness: 'test/fixtures/erx_device_dma_order_harness.c',
            sources: %w[erx_device_dma.c], done: 'erx_device_dma_order done' }.freeze
  MODEL = { harness: 'test/fixtures/erx_device_dma_model_harness.c',
            sources: %w[erx_device_dma.c erx_dma_model.c erx_device_queue.c],
            done: 'erx_device_dma_model done' }.freeze
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  # Each seed of the sequencer or the check, and the harness whose assertion it fails.
  ORDER_SEEDS = %w[PUBLISH_BEFORE_CLEAN NO_REPORT_BARRIER REPORT_BARRIER_LOADS STEP_BY_GRANULE
                   NO_GRANULE_CHECK].freeze
  MODEL_SEEDS = %w[NO_CLEAN NO_TAKE_BACK STEP_BY_GRANULE NO_BUFFER_HANDOVER PUBLISH_BEFORE_CLEAN
                   HANDOVER_BUFFERS_ONLY NO_ZEROING].freeze

  def test_order_and_check
    output, status = run_harness(ORDER)
    assert status.success?, output
    assert_match(/^#{ORDER[:done]}$/, output)
  end

  def test_split_ring_over_a_non_coherent_cache
    output, status = run_harness(MODEL)
    assert status.success?, output
    assert_match(/^#{MODEL[:done]}$/, output)
  end

  ORDER_SEEDS.each do |seed|
    define_method("test_order_seed_#{seed.downcase}") { assert_seed_caught(ORDER, "-DERX_DMA_SEED_#{seed}") }
  end

  MODEL_SEEDS.each do |seed|
    define_method("test_model_seed_#{seed.downcase}") { assert_seed_caught(MODEL, "-DERX_DMA_SEED_#{seed}") }
  end

  # The buffer stride left unrounded is the form's fault, not the core's, so the harness plants it.
  def test_model_seed_unrounded_stride
    assert_seed_caught(MODEL, '-DHARNESS_SEED_UNROUNDED_STRIDE')
  end

  private

  def assert_seed_caught(harness, define)
    output, status = run_harness(harness, define)
    refute status.success?, "#{define} went unnoticed:\n#{output}"
    assert_match(/^FAILED /, output)
  end

  def run_harness(harness, *defines)
    Dir.mktmpdir('erx-device-dma-') do |directory|
      binary = File.join(directory, 'harness')
      sources = [File.join(ROOT, harness[:harness]), *harness[:sources].map { |source| File.join(NIFS, source) }]
      output, status = Open3.capture2e(COMPILER, *FLAGS, *defines, *Erx::Generated.include_flags(root: ROOT), '-I', NIFS, '-I', ROOT, '-o', binary, *sources)
      return [output, status] unless status.success?

      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: "")
    end
  end
end
