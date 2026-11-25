# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'side_lock'

module Erx
  # `tools/erx fetch --l4re` (docs/design-bench.md, "L4Re's guest"): the sources of
  # L4Re's guest in the benchmark comparison, fetched on demand and by nothing else, so
  # neither a default fetch nor a --cache fetch clones or needs them. They are pinned in
  # L4Re's own lock (SideLock), bench/l4re/deps.lock: each is a
  # git source whose commit is exported as git's tar of it and verified against its
  # SHA-256 before it is published, under build/l4re-sources, a root of its own beside
  # the build's output (build/l4re), so no id it names can replace a source of erXos's
  # deps.lock. Upstream Fiasco's commit is the fork's: the Revision line of
  # fiasco/kernel/ORIGIN.md, which the lock must pin, so the fork's one pin moves both
  # kernels.
  #
  # The trees and packages are untrusted data: nothing of them runs on the host. L4Re's
  # container build (L4ReBuild) copies each tree in at the path L4Re's manifest gives it
  # (LAYOUT), and each package beside them.
  module L4ReFetch
    LABEL = 'l4re'
    LOCK = 'bench/l4re/deps.lock'
    WORKSPACE = 'build/l4re-sources'
    ORIGIN = 'fiasco/kernel/ORIGIN.md'
    # Each source's path in the tree L4Re's build sees, as the manifest lays it out.
    LAYOUT = { 'l4re-mk' => 'l4', 'l4re-core' => 'l4/pkg/l4re-core', 'l4re-bootstrap' => 'l4/pkg/bootstrap',
               'l4re-libfdt' => 'l4/pkg/libfdt', 'l4re-drivers-frst' => 'l4/pkg/drivers-frst',
               'l4re-fiasco' => 'fiasco', 'l4re-ipcbench' => 'l4/pkg/ipcbench' }.freeze
    # A tool package's file name: the package's name and arm64, the image's architecture (its
    # version is the pin's own field).
    PACKAGE = /\A[a-z0-9][a-z0-9.-]*_arm64\.deb\z/

    module_function

    # Fetches every source the lock pins; cache is another checkout's
    # build/l4re-sources/build/downloads, from which the archives come with no network.
    # Returns the lines that say what was done.
    def fetch(root:, runner:, cache: nil)
      SideLock.fetch(lock(root: root, runner: runner), root: root, label: LABEL, cache: cache)
    end

    # The lock's sources over the workspace; refuses a lock whose git sources are not
    # exactly LAYOUT's ids, so the build copies in every tree it fetched, whose other
    # sources are not Debian arm64 packages (PACKAGE), or that pins upstream Fiasco at
    # another commit than the fork's. Its fetched_tree(id) is the tree LAYOUT places.
    def lock(root:, runner:)
      dependencies = SideLock.dependencies(root: root, runner: runner, lock: LOCK, workspace: WORKSPACE, label: LABEL)
      trees, others = dependencies.sources.partition { |source| source.fetch('kind') == 'git' }
      ids = trees.map { |source| source.fetch('id') }
      unless ids.sort == LAYOUT.keys.sort
        raise Error, "#{LOCK} pins git sources #{ids.join(', ')}; L4Re's lock pins git sources #{LAYOUT.keys.join(', ')}"
      end
      strays = others.reject { |source| source.fetch('kind') == 'file' && PACKAGE.match?(source.fetch('filename')) }
      unless strays.empty?
        raise Error, "#{LOCK} pins #{strays.map { |source| source.fetch('id') }.join(', ')}, which are neither " \
                     "L4Re's trees nor Debian arm64 packages"
      end
      fiasco = dependencies.sources.find { |source| source.fetch('id') == 'l4re-fiasco' }.fetch('commit')
      revision = fork_revision(root)
      unless fiasco == revision
        raise Error, "#{LOCK} pins upstream Fiasco at #{fiasco}, not the fork's revision #{revision} (#{ORIGIN})"
      end
      dependencies
    end

    # The fetched Debian packages of a lock, the build's tools beyond the image (flex and
    # bison among them), which the container unpacks as its non-root user and never
    # installs.
    def packages(dependencies)
      dependencies.sources.select { |source| source.fetch('kind') == 'file' }
                  .map { |source| dependencies.fetched_file(source.fetch('id')) }
    end

    def fork_revision(root)
      File.read(File.join(root, ORIGIN))[/^Revision: ([0-9a-f]{40})$/, 1] ||
        raise(Error, "#{ORIGIN} names no Revision")
    end
    private_class_method :fork_revision
  end
end
