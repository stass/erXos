# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'generated'

module Erx
  # The web client's sources as Node runs them (docs/design-web.md,
  # "Verification and testing"): a temporary tree of web/'s own sources with
  # the generated files of build/gen/web laid over it at the same paths, so a
  # source's import of '../src/generated/ui_wire.ts' resolves with no build
  # step. Node strips the TypeScript types itself. Installed packages and
  # build output (node_modules, dist) are not sources and stay behind.
  module WebStage
    NODE = %w[node --no-warnings].freeze
    LEFT_OUT = %w[node_modules dist].freeze

    module_function

    def with(root:)
      Dir.mktmpdir('erx-web') do |stage|
        # Copied under the generator's lock, so no regeneration tears the copy.
        Generated.ensure(root: root) do |result|
          [File.join(root, 'web'), File.join(result.output, 'web')].each { |tree| copy(tree, stage) }
        end
        yield stage
      end
    end

    def copy(tree, stage)
      return unless File.directory?(tree)

      Dir.children(tree).reject { |name| LEFT_OUT.include?(name) }.each do |name|
        FileUtils.cp_r(File.join(tree, name), stage)
      end
    end
  end
end
