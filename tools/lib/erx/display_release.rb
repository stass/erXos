# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_callers'
require_relative 'erlang_apps'
require_relative 'error'
require_relative 'release_files'

module Erx
  # G9's build check (docs/design-display.md, G9): the display domain's release holds no
  # module of a display client, so no draw decoder, picture decoder, font reader, widget
  # module, terminal or pixel allocator reaches the display domain, and none of the
  # display's own modules names one. The release takes whole applications, so the check
  # is over the display side's applications (ReleaseFiles::DISPLAY_ONLY), module by module:
  #
  # * a module one of them lists is a client module when a client application
  #   (ReleaseFiles::CLIENT_ONLY) lists it too, or when its name is of a client family
  #   (CLIENT_FAMILIES), so a client module moved into the display side is caught by its
  #   name, and a client application put on the display side by its modules;
  # * a source of theirs names a client module, as a call, an apply's module literal, a
  #   quoted atom or a string, once comments and documentation are removed: the dependency
  #   that would fail at run time in the display domain, or pull the module in.
  #
  # Like DeviceCallers it reads names, so it catches a slip, not an atom built from pieces.
  module DisplayRelease
    # The client's module families: the draw protocol, its picture decoders erx_png and
    # erx_inflate, the widget trees, the terminal and its emulator, the pixel allocator, fonts and the client's
    # window library (docs/design-display.md, "What runs where").
    CLIENT_FAMILIES = /\Aerx_(?:draw|ui|vt|term|font|png|inflate|pixels|win)(?:_|\z)/
    Violation = Data.define(:where, :rule) do
      def to_s = "display release (G9): #{where}: #{rule}"
    end

    module_function

    # The violations among applications, a map of each application of the display side and
    # of the client side to its .app.src text and its module sources (path => text).
    def violations(display:, client:)
      clients = client.values.flat_map { |application| modules_of(application) }.to_set
      display.flat_map do |name, application|
        held = modules_of(application).filter_map do |module_name|
          next unless clients.include?(module_name) || CLIENT_FAMILIES.match?(module_name)

          Violation.new(where: "#{name} lists #{module_name}", rule: 'a client module is not in the display release')
        end
        named = application.fetch(:sources).flat_map { |path, text| names(path, text, clients) }
        [*held, *named]
      end
    end

    # The violations of the tree at root. An application the tree does not hold is not read,
    # as ErlangApps.check_sources does not read it; the runtime build fails on its absence.
    def check(root:)
      read = lambda do |names|
        names.select { |name| File.directory?(File.join(root, ErlangApps.source(name))) }
             .to_h { |name| [name, read_application(root, name)] }
      end
      violations(display: read.call(ReleaseFiles::DISPLAY_ONLY), client: read.call(ReleaseFiles::CLIENT_ONLY))
    end

    def read_application(root, name)
      sources = ErlangApps.read_sources(root: root, application: name)
      { resource: sources.resource,
        sources: sources.paths.to_h { |path| [path, File.read(File.join(root, path))] } }
    end

    def modules_of(application) = ErlangApps.modules_of(application.fetch(:resource), label: 'application file')

    # The lines of a source that name a client module, by number.
    def names(path, text, clients)
      code(text).each_line.with_index(1).flat_map do |line, number|
        line.scan(/(?<![A-Za-z0-9_@])erx_[A-Za-z0-9_@]+/).uniq
            .select { |atom| clients.include?(atom) || CLIENT_FAMILIES.match?(atom) }
            .map { |atom| Violation.new(where: "#{path}:#{number}", rule: "names the client module #{atom}") }
      end
    end

    # The text with comments and triple-quoted documentation blanked, every line kept.
    def code(text)
      DeviceCallers.code(text).gsub(DeviceCallers::TRIPLE) { |doc| "\n" * doc.count("\n") }
    end
  end
end
