# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # What one generator run produces and what it was computed from, in the
  # shape Erx::Generated stamps and publishes.
  #
  # files: repository-relative output path => bytes.
  # reads: repository-relative input path => SHA-256 of the bytes the
  #   generator actually read, so the record names exactly what it used.
  # globs: repository-relative pattern => sorted relative paths it expanded
  #   to, for inputs a generator discovers rather than names; a new or
  #   removed match changes the expansion even though no read file changed.
  GenerationPlan = Data.define(:files, :reads, :globs) do
    def initialize(files:, reads:, globs: {})
      super(files: files.sort.to_h.freeze, reads: reads.sort.to_h.freeze,
            globs: globs.sort.to_h { |pattern, paths| [pattern, paths.sort.freeze] }.freeze)
    end
  end
end
