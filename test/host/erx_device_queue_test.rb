# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# The pure core of a device's queue (test/fixtures/erx_device_queue_harness.c), clean under
# the address and undefined sanitizers.
class ErxDeviceQueueTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  SOURCES = [File.join(ROOT, 'test/fixtures/erx_device_queue_harness.c'), File.join(NIFS, 'erx_device_queue.c')].freeze
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  def test_posts_completions_refusals_and_resets
    Dir.mktmpdir('erx-device-queue-') do |directory|
      binary = File.join(directory, 'harness')
      output, status = Open3.capture2e(COMPILER, *FLAGS, '-I', File.join(ROOT, 'include'), '-I', NIFS, *SOURCES,
                                       '-o', binary, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e({ 'ASAN_OPTIONS' => 'detect_leaks=0' }, binary, stdin_data: '')
      assert status.success?, output
      assert_match(/^erx_device_queue done$/, output)
    end
  end
end
