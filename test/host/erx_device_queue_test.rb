# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
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

  private

  # Directories in includes come first, so the DMA harness's device model replaces the
  # generated register accesses.
  def run_harness(*sources, includes: [])
    Dir.mktmpdir('erx-device-queue-') do |directory|
      binary = File.join(directory, 'harness')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *includes.flat_map { |dir| ['-I', dir] },
                                       *Erx::Generated.include_flags(root: ROOT), '-I', ROOT,
                                       '-I', File.join(ROOT, 'include'), '-I', NIFS,
                                       *sources, '-o', binary, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e({ 'ASAN_OPTIONS' => 'detect_leaks=0' }, binary, stdin_data: '')
      assert status.success?, output
      output
    end
  end
end
