# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'bounded_file'
require_relative 'build_kind'

module Erx
  # The configuration check of the Fiasco kernel (docs/design-fiasco.md,
  # "Boot handoff", the kernel), and the one statement of how a release
  # kernel's configuration differs from a development one's. It reads the
  # resolved configuration, globalconfig.out, which Fiasco's Kconfig writes
  # after every `select` and `depends on` has been applied, never the
  # defconfig, since a `select` can set what the defconfig leaves unset.
  #
  # Required options must read `=y`. Forbidden options must be absent or
  # `# CONFIG_X is not set`; any assignment of one is a violation, whatever
  # its value. A release kernel's configuration must also leave the options
  # RELEASE_UNSET names unset. Kconfig writes nothing else, so a line of any
  # other shape, or an option named twice, is refused rather than guessed at.
  module FiascoConfig
    # A well-formed resolved configuration that breaks the rules.
    class Violation < Error; end

    # The FP unit, the performance build, user-mode reads of the performance
    # counters for profiling (a difference the design records), and the
    # synchronized clock: wait deadlines are times of the architecture's
    # counter, which Timer::system_clock() reads only with it, a tick
    # count in the information page without it (design-fiasco.md, "Boot handoff").
    REQUIRED = %w[CONFIG_FPU CONFIG_BENCHMARKING CONFIG_PERF_CNT_USER CONFIG_SYNC_CLOCK].freeze
    # The fork switches FP state eagerly and leaves SVE trapped ("Eager FP
    # switching"); the thread region is a constant of the non-hypervisor layout.
    FORBIDDEN = %w[CONFIG_LAZY_FPU CONFIG_ARM_SVE CONFIG_CPU_VIRT].freeze
    # What a release kernel leaves out (design-fiasco.md, the kernel): the kernel debugger and
    # the kernel's own console input. With either built in, a panic waits on
    # the console with interrupts off (JDB, which selects INPUT, and
    # terminate.cpp's Exit_question::ask with INPUT); with neither, it
    # resets once PSCI is known (design-fiasco.md, the kernel). These are the release defconfig's only differences
    # (release_defconfig), and the check refuses them in the resolved file,
    # where a select can set them again.
    RELEASE_UNSET = %w[CONFIG_JDB CONFIG_INPUT].freeze
    MAX_BYTES = 1024 * 1024
    MAX_LINES = 16_384
    NAME = /CONFIG_[A-Za-z0-9_]{1,128}/
    ASSIGNMENT = /\A(?<name>#{NAME})=(?<value>[ -~]{0,1024})\z/
    UNSET = /\A# (?<name>#{NAME}) is not set\z/
    COMMENT_OR_BLANK = /\A(?:#(?: [ -~]{0,1024})?)?\z/

    # One option a line names: its value, or nil when it is not set.
    Option = Data.define(:name, :value)

    module_function

    # The violations of the rules above in the resolved configuration of a
    # kernel of build kind kind (BuildKind), one diagnostic per rule broken;
    # empty when the configuration is the fork's. Raises Error when the text
    # is not a resolved configuration at all, or kind is not a build kind.
    def violations(bytes, kind:)
      forbidden = BuildKind.development?(kind) ? FORBIDDEN : FORBIDDEN + RELEASE_UNSET
      values = assigned_values(bytes)
      missing = REQUIRED.reject { |name| values[name] == 'y' }.map do |name|
        "#{name} must be y, found #{values.key?(name) ? values[name].inspect : 'unset'}"
      end
      present = forbidden.select { |name| values.key?(name) }.map do |name|
        "#{name} must be unset, found #{values[name].inspect}"
      end
      missing + present
    end

    # Checks the resolved configuration at path of a kernel of build kind
    # kind; raises Violation naming every rule broken, so one run reports
    # all of them, and Error when the file is unreadable or not a resolved
    # configuration.
    def check(path, kind:)
      found = violations(BoundedFile.read(path, maximum: MAX_BYTES), kind: kind)
      return if found.empty?

      raise Violation, "Fiasco #{kind} kernel configuration #{path} breaks the fork's rules: #{found.join('; ')}"
    end

    # The release kernel's defconfig: the development defconfig's text with
    # each option RELEASE_UNSET names written as not set after it. The
    # development defconfig must not name those options, so the release's
    # differences are stated only in RELEASE_UNSET and no line of the result
    # overrides another.
    def release_defconfig(development)
      named = options(development).map(&:name) & RELEASE_UNSET
      unless named.empty?
        raise Error, "the development kernel defconfig names #{named.join(', ')}, which only a release kernel's configuration sets"
      end

      text = development.b
      text += "\n" unless text.empty? || text.end_with?("\n")
      text + RELEASE_UNSET.map { |name| "# #{name} is not set\n" }.join
    end

    # Maps each assigned option to its value. Unset options are recorded as
    # absent, which is what both rules need.
    def assigned_values(bytes)
      options(bytes).reject { |option| option.value.nil? }.to_h { |option| [option.name, option.value] }
    end

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

    # The Option one line names, or nil for a comment or blank line.
    def option(line, number:)
      if (match = ASSIGNMENT.match(line)) then Option.new(name: match[:name], value: match[:value])
      elsif (match = UNSET.match(line)) then Option.new(name: match[:name], value: nil)
      elsif COMMENT_OR_BLANK.match?(line) then nil
      else raise Error, "Fiasco configuration line #{number} is not a Kconfig line"
      end
    end
    private_class_method :assigned_values, :options, :option
  end
end
