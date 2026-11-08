# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bounded_file'
require_relative 'error'

module Erx
  # Which LLVM a build takes, and which version a build record names.
  #
  # A development build, of an image or of a host test, takes any LLVM from
  # MINIMUM on, on whatever host it runs, and the record of what built an
  # image names the versions it actually ran (toolchain, read by NativeRoot's
  # linked receipts). Two builds on one host agree byte for byte, which
  # `make check-reproducible` checks. A release image is built with exactly
  # RELEASE and its hashes are published, so anyone can rebuild it with
  # RELEASE and compare (docs/plan.md, the security closure milestone).
  module LlvmVersion
    module_function

    # The oldest release a build takes: the start of the 23.1 series, the
    # series the tree is tested with. No feature the tree uses is known to
    # need 23.1 itself; it is the floor because nothing older is tested.
    MINIMUM = [23, 1, 0].freeze

    # The release images are built with, exactly.
    RELEASE = '23.1.3'

    # The first line `--version` prints, for each tool a build checks: an
    # optional vendor word (Homebrew, Ubuntu, Debian), then the version.
    # Apple's clang is refused, since its numbers follow Xcode's, not LLVM's.
    # The version is captured as digits alone, a bounded count of them, so
    # nothing else of the tool's output can reach a message or a record.
    VENDOR = '(?:(?!Apple )[A-Za-z][A-Za-z0-9._-]{0,31} )?'
    NUMBER = '(\d{1,4})\.(\d{1,4})\.(\d{1,4})(?=\s|\z)'
    FIRST_LINE = {
      'clang' => /\A#{VENDOR}clang version #{NUMBER}/,
      'lld' => /\A#{VENDOR}LLD #{NUMBER}/
    }.freeze

    # The version tool's first line reports, as "major.minor.patch" in
    # digits; raises Erx::Error when the line names no LLVM release.
    def parse(tool:, first_line:)
      pattern = FIRST_LINE.fetch(tool) { raise Error, "unknown LLVM tool: #{tool}" }
      found = pattern.match(first_line.to_s)
      raise Error, "#{tool} --version does not name an LLVM release" unless found

      found.captures.map(&:to_i).join('.')
    end

    # Whether a build may use version, which parse returned: nil for
    # RELEASE, a note naming the version for any other release a build
    # takes, and Erx::Error for one older than MINIMUM.
    def admit(tool:, version:)
      numbers = version.split('.').map(&:to_i)
      if (numbers <=> MINIMUM).negative?
        raise Error, "#{tool} #{version} is older than LLVM #{MINIMUM.join('.')}, the oldest a build takes"
      end
      return if version == RELEASE

      release = "release images are built with LLVM #{RELEASE}"
      series = RELEASE.split('.').first(2)
      return "note: building with #{tool} #{version}; #{release}" if version.split('.').first(2) == series

      "note: building with #{tool} #{version}, newer than the LLVM #{series.join('.')} series the tree " \
        "is tested with; #{release}"
    end

    # The versions compiler and linker report, as parse reads them, from one
    # `--version` run of each under runner; name prefixes the runs' names.
    # Raises Erx::Error for a version admit refuses, so whatever records
    # these versions records only ones a build takes.
    def toolchain(compiler:, linker:, runner:, name:, env: {})
      { 'clang' => compiler, 'lld' => linker }.to_h do |tool, program|
        run = runner.run([program, '--version'], name: "#{name}-#{tool}-version", deadline: 30, env: env)
        version = parse(tool: tool, first_line: BoundedFile.read(run.fetch('log'), maximum: 65_536).lines.first.to_s)
        admit(tool: tool, version: version)
        [tool, version]
      end.freeze
    end
  end
end
