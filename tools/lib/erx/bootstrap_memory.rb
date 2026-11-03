# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'runner'

module Erx
  # Checks the memory summary bootstrap prints before it loads the kernel
  # against the RAM the harness gave the guest:
  #
  #   Total RAM: 512.0 MiB; available for Bootstrap/Sigma0/Kernel: 512.0 MiB
  #
  # erXos passes bootstrap neither '-mem=' nor '-sysalloc=', so bootstrap
  # takes its RAM from the device tree, which QEMU fills with the guest's
  # whole RAM, and may allocate from all of it. Both figures must therefore
  # be exactly the guest RAM, rendered the way bootstrap renders sizes.
  module BootstrapMemory
    UNITS = %w[B K M G T P E].freeze
    PREVIEW_BYTES = 96

    module_function

    # The transcript checkpoint that fails a boot whose summary line is not
    # the one expected for ram_bytes of guest RAM.
    def checkpoint(ram_bytes:)
      raise Error, 'guest RAM must be a positive byte count' unless ram_bytes.is_a?(Integer) && ram_bytes.positive?

      { name: 'bootstrap-memory', pattern: /\A  Total RAM: /n,
        verify: ->(line) { verify(line, ram_bytes: ram_bytes) }, seconds: 30 }.freeze
    end

    def summary(ram_bytes:)
      size = human_size(ram_bytes)
      "  Total RAM: #{size}; available for Bootstrap/Sigma0/Kernel: #{size}"
    end

    # Raises Erx::Error unless the serial line, without its line ending, is
    # the expected summary. The diagnostic quotes a bounded, escaped preview
    # of the guest's line, never its raw bytes.
    def verify(line, ram_bytes:)
      expected = summary(ram_bytes: ram_bytes)
      return true if line.b.chomp == expected

      preview = Terminal.escape(line.b.chomp.byteslice(0, PREVIEW_BYTES))
      raise Error, "bootstrap memory summary is '#{preview}', expected '#{expected.strip}'"
    end

    # The output of l4util_human_readable_size (printf_helpers.h): the
    # largest binary unit strictly below the value, truncated to one decimal;
    # values up to 1 KiB print in bytes with two trailing spaces.
    def human_size(bytes)
      order = 60.step(10, -10).find { |shift| bytes > (1 << shift) } || 0
      value = bytes >> order
      return "#{value} B  " if order.zero?

      tenths = (bytes - (value << order)) / ((1 << order) / 10 + 1)
      "#{value}.#{tenths} #{UNITS.fetch(order / 10)}iB"
    end
  end
end
