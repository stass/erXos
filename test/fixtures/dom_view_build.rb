# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../tools/lib/erx/generated'

# test/fixtures/dom_view_driver.c over the domain library's boot view, built for the host:
# with boot_view in liberx/system/dom_boot_view.c's place, or include, a directory searched
# before include/, for a seeded fault.
module DomViewBuild
  ROOT = File.expand_path('../..', __dir__)
  LIBRARY = %w[liberx/system/dom_core.c liberx/system/dom_life.c].freeze
  SUPPORT = %w[liberx/erx_lane.c liberx/backend/core/boot_manifest.c tools/host/input.c test/fixtures/dom_view_driver.c].freeze

  module_function

  def build(output:, runner:, name:, boot_view: File.join(ROOT, 'liberx/system/dom_boot_view.c'), include: nil)
    sources = [*LIBRARY.map { |path| File.join(ROOT, path) }, boot_view, *SUPPORT.map { |path| File.join(ROOT, path) }]
    runner.run([ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror',
                '-O1', *(include ? ['-I', include] : []), *Erx::Generated.include_flags(root: ROOT),
                '-I', File.join(ROOT, 'include'), '-I', ROOT, '-I', File.join(ROOT, 'tools/host'), *sources,
                Erx::Generated.path('liberx/generated/abi_reader.c', root: ROOT), '-o', output],
               name: "#{name}-build", deadline: 120)
    output
  end
end
