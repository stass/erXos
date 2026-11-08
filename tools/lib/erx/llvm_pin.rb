# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # Which LLVM releases a command may build with. Everything that enters an
  # image, or the check that the image is reproducible, builds with exactly
  # the pinned release, because the image's bytes and its provenance record
  # depend on it. The host-only test gates (check-fuzz, check-sanitizers)
  # build programs that never leave the host, so they also take any patch
  # release of the pinned major.minor, as a host whose package manager ships
  # a neighbouring patch release offers; the caller names the version it
  # took when it is not the pin.
  module LlvmPin
    module_function

    VERSION = '23.1.3'
    PURPOSES = %i[image host_tests].freeze

    # The first line `--version` prints, for each tool the build checks.
    FIRST_LINE = {
      'clang' => /\A(?:Homebrew )?clang version (\d+\.\d+\.\d+)(?:\s|$)/,
      'lld' => /\A(?:Homebrew )?LLD (\d+\.\d+\.\d+)(?:\s|$)/
    }.freeze

    # Returns the version tool's first_line reports when purpose admits it,
    # and raises Erx::Error otherwise: :image admits only VERSION, and
    # :host_tests admits any release whose major.minor is VERSION's.
    def admit(tool:, first_line:, purpose:)
      raise Error, "unknown LLVM purpose: #{purpose.inspect}" unless PURPOSES.include?(purpose)

      pattern = FIRST_LINE.fetch(tool) { raise Error, "unknown LLVM tool: #{tool}" }
      found = pattern.match(first_line.to_s)&.[](1)
      return found if found && admitted?(found, purpose: purpose)

      raise Error, "#{tool} does not report #{requirement(purpose)}"
    end

    def admitted?(found, purpose:)
      case purpose
      in :image then found == VERSION
      in :host_tests then major_minor(found) == major_minor(VERSION)
      end
    end

    def major_minor(version) = version.split('.').first(2)

    def requirement(purpose)
      case purpose
      in :image then "the required LLVM #{VERSION} version"
      in :host_tests then "an LLVM #{major_minor(VERSION).join('.')}.x version"
      end
    end

    private_class_method :admitted?, :major_minor, :requirement
  end
end
