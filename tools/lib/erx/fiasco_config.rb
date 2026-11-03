# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'bounded_file'

module Erx
  # The configuration check of the stopgap kernel (docs/design-stopgap.md,
  # "The fork's configuration"). It reads the resolved configuration,
  # globalconfig.out, which Fiasco's Kconfig writes after every `select` and
  # `depends on` has been applied, never the defconfig, since a `select` can
  # set what the defconfig leaves unset.
  #
  # Required options must read `=y`. Forbidden options must be absent or
  # `# CONFIG_X is not set`; any assignment of one is a violation, whatever
  # its value. Kconfig writes nothing else, so a line of any other shape, or
  # an option named twice, is refused rather than guessed at.
  module FiascoConfig
    # A well-formed resolved configuration that breaks the rules.
    class Violation < Error; end

    # The FP unit, the performance build, user-mode reads of the performance
    # counters for profiling (a difference the design records), and the
    # synchronized clock that measures a stop's finishing share
    # (Timer::system_clock(), design-stopgap-scheduling.md).
    REQUIRED = %w[CONFIG_FPU CONFIG_PERFORMANCE CONFIG_PERF_CNT_USER CONFIG_SYNC_CLOCK].freeze
    # The fork switches FP state eagerly and leaves SVE trapped ("FP and SIMD
    # state"); the thread region is a constant of the non-hypervisor layout.
    FORBIDDEN = %w[CONFIG_LAZY_FPU CONFIG_ARM_SVE CONFIG_CPU_VIRT].freeze
    MAX_BYTES = 1024 * 1024
    MAX_LINES = 16_384
    NAME = /CONFIG_[A-Za-z0-9_]{1,128}/
    ASSIGNMENT = /\A(?<name>#{NAME})=(?<value>[ -~]{0,1024})\z/
    UNSET = /\A# (?<name>#{NAME}) is not set\z/
    COMMENT_OR_BLANK = /\A(?:#(?: [ -~]{0,1024})?)?\z/

    # One option a line names: its value, or nil when it is not set.
    Option = Data.define(:name, :value)

    module_function

    # The violations of the rules above in a resolved configuration, one
    # diagnostic per rule broken; empty when the configuration is the fork's.
    # Raises Error when the text is not a resolved configuration at all.
    def violations(bytes)
      values = assigned_values(bytes)
      missing = REQUIRED.reject { |name| values[name] == 'y' }.map do |name|
        "#{name} must be y, found #{values.key?(name) ? values[name].inspect : 'unset'}"
      end
      present = FORBIDDEN.select { |name| values.key?(name) }.map do |name|
        "#{name} must be unset, found #{values[name].inspect}"
      end
      missing + present
    end

    # Checks the resolved configuration at path; raises Violation naming
    # every rule broken, so one run reports all of them, and Error when the
    # file is unreadable or not a resolved configuration.
    def check(path)
      found = violations(BoundedFile.read(path, maximum: MAX_BYTES))
      return if found.empty?

      raise Violation, "stopgap kernel configuration #{path} breaks the fork's rules: #{found.join('; ')}"
    end

    # Maps each assigned option to its value. Unset options are recorded as
    # absent, which is what both rules need.
    def assigned_values(bytes)
      unless bytes.is_a?(String) && bytes.bytesize <= MAX_BYTES && bytes.b.ascii_only?
        raise Error, 'resolved Fiasco configuration must be bounded ASCII'
      end
      lines = bytes.b.split("\n", -1)
      lines.pop if lines.last == ''
      raise Error, 'resolved Fiasco configuration has too many lines' if lines.size > MAX_LINES

      options = lines.each_with_index.filter_map { |line, index| option(line, number: index + 1) }
      duplicate = options.map(&:name).tally.find { |_name, count| count > 1 }
      raise Error, "resolved Fiasco configuration names #{duplicate.first} twice" if duplicate

      options.reject { |option| option.value.nil? }.to_h { |option| [option.name, option.value] }
    end

    # The Option one line names, or nil for a comment or blank line.
    def option(line, number:)
      if (match = ASSIGNMENT.match(line)) then Option.new(name: match[:name], value: match[:value])
      elsif (match = UNSET.match(line)) then Option.new(name: match[:name], value: nil)
      elsif COMMENT_OR_BLANK.match?(line) then nil
      else raise Error, "resolved Fiasco configuration line #{number} is not a Kconfig line"
      end
    end
    private_class_method :assigned_values, :option
  end
end
