# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'build_kind'
require_relative 'dependency_status'
require_relative 'error'
require_relative 'license_expression'

module Erx
  # The one rule for which licenses the image check (PackProvenance) and the release
  # kernel's check (FiascoProvenance) accept for the files of a closure (docs/design.md,
  # "Licenses and notices"). An input with a permissive grant
  # (LicenseExpression::PERMISSIVE) enters every build. An input under a license that is
  # not permissive enters only where exempt? says: as the input of a row of TABLE, in the
  # build kinds that row names, or as a package of a local test image (PACKAGE_LOCAL), in
  # a development build. Every other input, a stopgap's or a release component's included,
  # must be permissive, so a copyleft file that comes back into a closure, such as another
  # of Fiasco's GPL sources, fails its check however it is registered.
  module LicenseCheck
    # The status of a package of a local test image whose license is not permissive
    # (ImageApps::Plan#status), which a development build accepts under that license, since
    # no published image takes a builder's package.
    PACKAGE_LOCAL = 'package-local'

    # The one example an image carries (docs/design.md's dependency table, status example):
    # Doom's archive, attributed whole under this label by the image build, with the WAD it
    # links, at the path the image build writes it (DoomProgram), relative to the tree. It
    # is the only input that may be registered example (example?).
    EXAMPLE_LABEL = 'doomgeneric libdoom.a'
    EXAMPLE_ARCHIVE = 'build/doom/libdoom.a'
    EXAMPLE_LICENSES = ['GPL-2.0-or-later', 'GPL-2.0-or-later AND BSD-3-Clause'].freeze

    DEVELOPMENT_ONLY = [BuildKind::DEVELOPMENT].freeze

    # One input a build accepts under a license that is not permissive: the status it is
    # registered under, its label as its record names it, the license expressions it may
    # carry, exactly as recorded, where the build reads it, and the build kinds that accept
    # it. The path is relative to the tree.
    Row = Data.define(:status, :label, :licenses, :path, :build_kinds) do
      # Whether this row names the input registered under input_status with input_label and
      # license, read from input_path: relative to the tree within it, absolute outside.
      def names?(input_status:, input_label:, license:, input_path:)
        status == input_status && licenses.include?(license) && path == input_path && label == input_label
      end
    end

    # Doom, the example, in the images that offer its source: the archive the image
    # build writes, which only a development build takes.
    EXAMPLE = Row.new(status: DependencyStatus::EXAMPLE, label: EXAMPLE_LABEL, licenses: EXAMPLE_LICENSES,
                      path: EXAMPLE_ARCHIVE, build_kinds: DEVELOPMENT_ONLY)

    # The closed table of such inputs (docs/design.md, "Licenses and notices").
    TABLE = [EXAMPLE].freeze

    module_function

    # Whether a build of build_kind accepts an input under license although license is not
    # permissive: the input registered under status with label, read from path (relative
    # to the tree within it, absolute outside it).
    def exempt?(status:, label:, license:, path:, build_kind:)
      build_kind = BuildKind.fetch(build_kind)
      (status == PACKAGE_LOCAL && BuildKind.development?(build_kind)) ||
        TABLE.any? do |row|
          row.build_kinds.include?(build_kind) &&
            row.names?(input_status: status, input_label: label, license:, input_path: path)
        end
    end

    # The grant a build of build_kind takes from license for the input exempt? describes;
    # raises when it takes none. font_data: true says the license's FONT_DATA_ONLY licenses
    # cover font data in the input (LicenseExpression.select).
    # The refusal names the input and its license, since the expression alone
    # does not say which of an image's files to look at.
    def select(license, status:, label:, path:, build_kind:, font_data: false)
      LicenseExpression.select(license, allow_restricted: exempt?(status:, label:, license:, path:, build_kind:),
                                        font_data:)
    rescue Error => e
      raise e.exception("#{label} (#{license}): #{e.message}")
    end

    # Whether select takes a grant for an input that holds no font data, as the release
    # kernel's check asks of each source it links.
    def passes?(license, status:, label:, path:, build_kind:)
      LicenseExpression.permissive?(license) || exempt?(status:, label:, license:, path:, build_kind:)
    end

    # Whether the input is the example's archive, the one input the example status may
    # name, whatever build it is in: EXAMPLE's row decides which builds take its license.
    def example?(label:, license:, path:)
      EXAMPLE.names?(input_status: DependencyStatus::EXAMPLE, input_label: label, license:, input_path: path)
    end
  end
end
