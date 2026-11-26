# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The facts erXos's generators take from the Fiasco kernel's
  # configuration, config/fiasco/kernel.defconfig, which is their one
  # source: today the number of CPUs the kernel is built for, which sizes
  # the kernel's trace rings (docs/design-fiasco.md, "The kernel's trace
  # rings").
  module FiascoKernelConfig
    PATH = 'config/fiasco/kernel.defconfig'
    BYTES_MAX = 65_536
    MAX_CPUS = /^CONFIG_MP_MAX_CPUS=([0-9]{1,4})$/

    module_function

    def read(root)
      bytes = File.binread(File.join(root, PATH), BYTES_MAX + 1)
      raise Error, "#{PATH} is empty or exceeds #{BYTES_MAX} bytes" if bytes.nil? || bytes.bytesize > BYTES_MAX

      bytes
    rescue SystemCallError => error
      raise Error, "cannot read #{PATH}: #{error.message}"
    end

    # CONFIG_MP_MAX_CPUS, which the configuration states exactly once.
    def max_cpus(text)
      found = text.scan(MAX_CPUS)
      raise Error, "#{PATH} sets CONFIG_MP_MAX_CPUS #{found.size} times, not once" unless found.size == 1

      found.first.first.to_i
    end
  end
end
