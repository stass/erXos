# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'build_kind'
require_relative 'kconfig'

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
    # No build has the kernel debugger, JDB, or the kernel's own console input
    # (docs/design-debugger.md, "On Fiasco"): with either, a panic waits on the
    # console with interrupts off (JDB, which selects INPUT, and terminate.cpp's
    # Exit_question::ask with INPUT) instead of resetting.
    FORBIDDEN = %w[CONFIG_LAZY_FPU CONFIG_ARM_SVE CONFIG_CPU_VIRT CONFIG_JDB CONFIG_INPUT].freeze
    # What a release kernel leaves unset that a development kernel's defconfig may
    # set: the release defconfig's only differences (release_defconfig), which the
    # check also refuses in a release kernel's resolved file, where a select can set
    # them again. The one the design names is the hold's option, CONFIG_ERX_HOLD
    # (docs/design-debugger.md, "On Fiasco"), which the fork does not have, so the
    # release defconfig is the development one.
    RELEASE_UNSET = [].freeze

    module_function

    # The violations of the rules above in the resolved configuration of a
    # kernel of build kind kind (BuildKind), one diagnostic per rule broken;
    # empty when the configuration is the fork's. Raises Error when the text
    # is not a resolved configuration at all, or kind is not a build kind.
    def violations(bytes, kind:)
      forbidden = BuildKind.development?(kind) ? FORBIDDEN : FORBIDDEN + RELEASE_UNSET
      values = Kconfig.values(bytes)
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
      found = violations(Kconfig.read(path), kind: kind)
      return if found.empty?

      raise Violation, "Fiasco #{kind} kernel configuration #{path} breaks the fork's rules: #{found.join('; ')}"
    end

    # The release kernel's defconfig: the development defconfig's text with
    # each option RELEASE_UNSET names written as not set after it. The
    # development defconfig must not name those options, so the release's
    # differences are stated only in RELEASE_UNSET and no line of the result
    # overrides another.
    def release_defconfig(development)
      named = Kconfig.options(development).map(&:name) & RELEASE_UNSET
      unless named.empty?
        raise Error, "the development kernel defconfig names #{named.join(', ')}, which only a release kernel's configuration sets"
      end

      text = development.b
      text += "\n" unless text.empty? || text.end_with?("\n")
      text + RELEASE_UNSET.map { |name| "# #{name} is not set\n" }.join
    end
  end
end
