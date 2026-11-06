# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/hardware'

# erx_device's core and effects (test/fixtures/erx_device_harness.c), over the PL011's table
# and over the table the generator makes of an invented peripheral with what the PL011 lacks,
# clean under the address and undefined sanitizers.
class ErxDeviceTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  SOURCES = [File.join(ROOT, 'test/fixtures/erx_device_harness.c'),
             File.join(ROOT, 'otp/erts/emulator/nifs/erxos/erx_device_core.c'),
             File.join(ROOT, 'otp/erts/emulator/nifs/erxos/erx_device.c'),
             File.join(ROOT, 'otp/erts/emulator/nifs/erxos/erx_device_queue.c')].freeze
  FIXTURE = File.join(ROOT, 'test/fixtures/device_table_fixture.svd')
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  def test_the_pl011_table_and_the_records
    assert_match(/^erx_device pl011 done$/, run_harness)
  end

  def test_an_array_a_device_address_and_a_read_side_effect
    Dir.mktmpdir('erx-device-table-') do |tree|
      FileUtils.mkdir_p(File.join(tree, 'hw/svd'))
      FileUtils.cp(FIXTURE, File.join(tree, 'hw/svd/fixture.svd'))
      Erx::Hardware.publish_outputs(Erx::Hardware.output_plan(root: tree), root: tree)
      assert_match(/^erx_device fixture done$/, run_harness('-DERX_DEVICE_FIXTURE', '-I', File.join(tree, 'include')))
    end
  end

  private

  def run_harness(*flags)
    Dir.mktmpdir('erx-device-harness-') do |directory|
      binary = File.join(directory, 'harness')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *flags, '-I', ROOT, '-I', File.join(ROOT, 'include'), '-I', NIFS,
                                       *SOURCES, '-o', binary, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e({ 'ASAN_OPTIONS' => 'detect_leaks=0' }, binary, stdin_data: '')
      assert status.success?, output
      output
    end
  end
end
