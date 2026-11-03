# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/bootstrap_memory'

class BootstrapMemoryTest < Minitest::Test
  MIB = 1 << 20

  def line(total, available)
    "  Total RAM: #{total}; available for Bootstrap/Sigma0/Kernel: #{available}\r\n"
  end

  # The line a 512 MiB guest printed when bootstrap reported the size of its
  # whole-address-space allocation window instead of RAM.
  def test_window_reported_as_memory_fails
    error = assert_raises(Erx::Error) do
      Erx::BootstrapMemory.verify(line('512.0 MiB', '16.0 EiB'), ram_bytes: 512 * MIB)
    end
    assert_match(/available for Bootstrap\/Sigma0\/Kernel: 16\.0 EiB/, error.message)
    assert_match(/expected '.*Kernel: 512\.0 MiB'\z/, error.message)
  end

  def test_exact_guest_ram_passes
    assert Erx::BootstrapMemory.verify(line('512.0 MiB', '512.0 MiB'), ram_bytes: 512 * MIB)
    assert Erx::BootstrapMemory.verify(line('512.0 MiB', '512.0 MiB').chomp, ram_bytes: 512 * MIB)
    assert Erx::BootstrapMemory.verify(line('3.0 GiB', '3.0 GiB'), ram_bytes: 3072 * MIB)
  end

  def test_undercounted_or_mismatched_memory_fails
    [line('512.0 MiB', '511.0 MiB'), line('512.0 MiB', '0 B  '), line('1.0 GiB', '1.0 GiB'),
     line('512.0 MiB', '512.0 MiB') + 'x', "  Total RAM: 512.0 MiB\r\n"].each do |text|
      assert_raises(Erx::Error) { Erx::BootstrapMemory.verify(text, ram_bytes: 512 * MIB) }
    end
  end

  # Expected strings are what l4util_human_readable_size prints, including
  # its strict unit threshold and truncated tenths. Its tenths divisor is
  # one byte above a tenth of the unit, so an exact half prints as .4.
  def test_sizes_render_like_bootstrap
    {
      1000 => '1000 B  ', 1024 => '1024 B  ', 1025 => '1.0 KiB',
      512 * MIB => '512.0 MiB', 1024 * MIB => '1024.0 MiB', 1024 * MIB + 1 => '1.0 GiB',
      1536 * MIB => '1.4 GiB', 4096 * MIB => '4.0 GiB', 2047 * MIB => '1.9 GiB',
      (1 << 64) - 1 => '15.9 EiB'
    }.each do |bytes, text|
      assert_equal text, Erx::BootstrapMemory.human_size(bytes), "for #{bytes} bytes"
    end
  end

  def test_diagnostic_escapes_and_bounds_guest_bytes
    text = "  Total RAM: \e]0;owned\a" + ('x' * 4096) + "\r\n"
    error = assert_raises(Erx::Error) { Erx::BootstrapMemory.verify(text, ram_bytes: 512 * MIB) }
    assert error.message.ascii_only?
    refute_match(/[\x00-\x1f\x7f]/, error.message)
    assert_operator error.message.bytesize, :<, 512
  end

  def test_checkpoint_requires_positive_ram
    assert_raises(Erx::Error) { Erx::BootstrapMemory.checkpoint(ram_bytes: 0) }
    assert_raises(Erx::Error) { Erx::BootstrapMemory.checkpoint(ram_bytes: '512') }
    point = Erx::BootstrapMemory.checkpoint(ram_bytes: 512 * MIB)
    assert_equal 'bootstrap-memory', point.fetch(:name)
    assert point.fetch(:verify).call(line('512.0 MiB', '512.0 MiB'))
  end
end
