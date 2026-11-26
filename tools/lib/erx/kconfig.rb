# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'bounded_file'

module Erx
  # The one reader of Fiasco's Kconfig files: the checks on a kernel's
  # resolved configuration (FiascoConfig) and the ABI generator, which takes
  # the kernel's CPU count from the checked-in defconfig (max_cpus), both
  # read through it. It loads nothing generated, so the ABI generator can
  # use it.
  module Kconfig
    # The checked-in development defconfig of the Fiasco kernel.
    FIASCO_KERNEL_DEFCONFIG = 'config/fiasco/kernel.defconfig'
    MAX_BYTES = 1024 * 1024
    MAX_LINES = 16_384
    NAME = /CONFIG_[A-Za-z0-9_]{1,128}/
    ASSIGNMENT = /\A(?<name>#{NAME})=(?<value>[ -~]{0,1024})\z/
    UNSET = /\A# (?<name>#{NAME}) is not set\z/
    COMMENT_OR_BLANK = /\A(?:#(?: [ -~]{0,1024})?)?\z/
    CPU_COUNT = /\A[1-9][0-9]{0,3}\z/

    # One option a line names: its value, or nil when it is not set.
    Option = Data.define(:name, :value)

    module_function

    # The bytes of the Kconfig file at path, bounded.
    def read(path) = BoundedFile.read(path, maximum: MAX_BYTES)

    # The Option each line of a Kconfig file names; an option named twice is refused.
    def options(bytes)
      unless bytes.is_a?(String) && bytes.bytesize <= MAX_BYTES && bytes.b.ascii_only?
        raise Error, 'Fiasco configuration must be bounded ASCII'
      end
      lines = bytes.b.split("\n", -1)
      lines.pop if lines.last == ''
      raise Error, 'Fiasco configuration has too many lines' if lines.size > MAX_LINES

      options = lines.each_with_index.filter_map { |line, index| option(line, number: index + 1) }
      duplicate = options.map(&:name).tally.find { |_name, count| count > 1 }
      raise Error, "Fiasco configuration names #{duplicate.first} twice" if duplicate

      options
    end

    # Maps each assigned option to its value; an option not set is absent.
    def values(bytes)
      options(bytes).reject { |option| option.value.nil? }.to_h { |option| [option.name, option.value] }
    end

    # CONFIG_MP_MAX_CPUS, the number of CPUs the kernel is built for, which
    # sizes the kernel's trace rings (docs/design-fiasco.md, "The kernel's
    # trace rings").
    def max_cpus(bytes)
      value = values(bytes)['CONFIG_MP_MAX_CPUS']
      raise Error, 'Fiasco configuration does not set CONFIG_MP_MAX_CPUS' if value.nil?
      raise Error, "Fiasco configuration sets CONFIG_MP_MAX_CPUS to #{value.inspect}, not a CPU count" unless CPU_COUNT.match?(value)

      value.to_i
    end

    # The Option one line names, or nil for a comment or blank line.
    def option(line, number:)
      if (match = ASSIGNMENT.match(line)) then Option.new(name: match[:name], value: match[:value])
      elsif (match = UNSET.match(line)) then Option.new(name: match[:name], value: nil)
      elsif COMMENT_OR_BLANK.match?(line) then nil
      else raise Error, "Fiasco configuration line #{number} is not a Kconfig line"
      end
    end
    private_class_method :option
  end
end
