# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/hardware'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# erx_device's core and effects (test/fixtures/erx_device_harness.c), over the PL011's table
# and over the table the generator makes of an invented peripheral with what the PL011 lacks,
# clean under the address and undefined sanitizers.
class ErxDeviceTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  SOURCES = [File.join(ROOT, 'test/fixtures/erx_device_harness.c'),
             File.join(ROOT, 'otp/erts/emulator/nifs/erxos/erx_device_core.c'),
             File.join(ROOT, 'otp/erts/emulator/nifs/erxos/erx_device.c'),
             File.join(ROOT, 'otp/erts/emulator/nifs/erxos/erx_device_queue.c'),
             File.join(ROOT, 'otp/erts/emulator/nifs/erxos/erx_device_dma.c'),
             File.join(ROOT, 'otp/erts/emulator/nifs/erxos/erx_device_genet.c'),
             File.join(ROOT, 'otp/erts/emulator/nifs/erxos/arch/host/erx_dma_arch.c')].freeze
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
      # erx_device.c names the virtio registers the NIF owns, so the tree has their source too.
      FileUtils.cp(File.join(ROOT, 'hw/svd/virtio_mmio/virtio_mmio.svd'), File.join(tree, 'hw/svd/virtio_mmio.svd'))
      Erx::Generated.generate_one('hardware', root: tree, output: File.join(tree, 'gen'))
      assert_match(/^erx_device fixture done$/, run_harness('-DERX_DEVICE_FIXTURE', '-I', File.join(tree, 'gen/include')))
    end
  end

  # The seeded fault of docs/design-shared-devices.md, "Verification": a bind check that
  # ignores the shared mark lets a driver bind a shared line directly, and the harness fails.
  SHARED_MARK = ["\tif (shared && binder == ERX_DEVICE_BINDER_DRIVER)\n",
                 "\tif (false && shared && binder == ERX_DEVICE_BINDER_DRIVER)\n"].freeze

  # The other seeded fault SD3 names: a line table keyed by record, where no open finds the
  # entry another record took, so the second record on a line asks the kernel again.
  PER_RECORD = ["\t\tif (find_line(spec, line, &entries[line]))\n\t\t\tcontinue;\n",
                "\t\tif (false && find_line(spec, line, &entries[line]))\n\t\t\tcontinue;\n"].freeze

  # The seeded fault of the command register (docs/design-storage.md, "Verification and
  # testing"): command/2 without its DMA check.
  NO_DMA_CHECK = ['!erx_device_command_allowed(cmdtm, &sdhci->fields[cmdtm->first_field + dma], word)',
                  'false'].freeze

  def test_a_command_without_its_dma_check_fails_the_harness
    assert_match(/FAILED .*erx_device_command\(record, read_block \| dma\)/, seeded_failure(NO_DMA_CHECK))
  end

  def test_a_bind_check_that_ignores_the_shared_mark_fails_the_harness
    assert_match(/FAILED .*ERX_DEVICE_BIND_SHARED/, seeded_failure(SHARED_MARK))
  end

  def test_a_line_table_keyed_by_record_fails_the_harness
    assert_match(/FAILED .*check_shared_line|FAILED .*irq_created == made \+ 1/, seeded_failure(PER_RECORD))
  end

  private

  # The harness's output over erx_device.c with `seed` applied; the run must fail.
  def seeded_failure(seed)
    Dir.mktmpdir('erx-device-seeded-') do |directory|
      source = File.read(File.join(NIFS, 'erx_device.c'))
      assert_includes source, seed.first
      seeded = File.join(directory, 'erx_device.c')
      File.write(seeded, source.sub(*seed))
      output, status = build_and_run(SOURCES.map { |path| path.end_with?('/erx_device.c') ? seeded : path })
      refute status.success?, output
      output
    end
  end

  public

  private

  def run_harness(*flags)
    output, status = build_and_run(SOURCES, *flags)
    assert status.success?, output
    output
  end

  # The harness built from `sources` and run; a build failure fails the test.
  def build_and_run(sources, *flags)
    Dir.mktmpdir('erx-device-harness-') do |directory|
      binary = File.join(directory, 'harness')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *flags, *Erx::Generated.include_flags(root: ROOT), '-I', ROOT,
                                       '-I', File.join(ROOT, 'include'), '-I', NIFS,
                                       *sources, '-o', binary, stdin_data: '')
      assert status.success?, output
      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    end
  end
end
