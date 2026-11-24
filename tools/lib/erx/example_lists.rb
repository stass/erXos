# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # No list of the build names an example (docs/design-packaging.md, "Examples"): no file
  # of the build's tools, the board manifests or the host tests' build fixtures (where
  # ErlangBuild lists the applications tests compile) names a path under examples/ or an
  # example's application, a directory examples/*/lib/APP, but the few that fetch, pack
  # or build one, EXEMPT, each with the design text that names it: the fetch step, the
  # card's kiosk and the kiosk suite's, which pack an app example through the SDK as a
  # third party does, Doom's build for the published media (DoomProgram, the one example
  # the build compiles itself, which names the files it compiles and no line of their
  # source), and this file, which names the directory to say what it scans for. Checks
  # runs it over the tree's listing.
  module ExampleLists
    DIRECTORY = 'examples/'
    SCOPES = %w[tools/lib/erx/ config/manifest/ test/fixtures/].freeze
    # Each file that may name an example, with the design text that names it.
    EXEMPT = {
      'tools/lib/erx/example_fetch.rb' => 'docs/design-packaging.md#examples, the fetch step that obtains an example',
      'tools/lib/erx/doom_program.rb' => "docs/design.md's dependency table, status example: Doom in the published media",
      'tools/lib/erx/example_lists.rb' => 'this check, which names the directory it scans for',
      'tools/lib/erx/image_apps.rb' => "docs/design-packaging.md#the-apps-row, the card's kiosk (ImageApps.packed_kiosk)",
      'tools/lib/erx/kiosk.rb' => 'docs/design-packaging.md#verification-and-testing, the kiosk cell',
      'tools/lib/erx/bt_domain.rb' => "docs/design-bluetooth.md#decisions, 7: the Bluetooth suite's app cell boots the echo",
      'tools/lib/erx/qemu_suites/kiosk.rb' => 'docs/design-packaging.md#verification-and-testing, the kiosk cell'
    }.freeze

    def self.covers?(relative) = !EXEMPT.key?(relative) && SCOPES.any? { relative.start_with?(it) }

    # The examples' application names, from the directories below root/examples.
    def self.applications(root:)
      Dir.glob("#{DIRECTORY}*/lib/*/", base: root).map { File.basename(it) }.uniq.sort
    end

    # Each [path, line number, name] where the files covers? takes of files, a map from
    # relative path to text, name the examples directory or one of applications.
    def self.violations(files, applications:)
      pattern = Regexp.union(DIRECTORY, *applications.map { /\b#{Regexp.escape(it)}\b/ })
      files.select { |path, _| covers?(path) }.sort.flat_map do |path, text|
        text.each_line.with_index(1).filter_map { |line, number| [path, number, line[pattern]] if line.match?(pattern) }
      end
    end
  end
end
