# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'dependencies'
require_relative 'error'
require_relative 'output_directory'

module Erx
  # `tools/erx fetch --l4re` (docs/design-bench.md, "L4Re's guest"): the sources of
  # L4Re's guest in the benchmark comparison, fetched on demand and by nothing else, so
  # neither a default fetch nor a --cache fetch clones or needs them. They are pinned in
  # L4Re's own lock, bench/l4re/deps.lock, in the form of erXos's deps.lock: each is a
  # git source whose commit is exported as git's tar of it and verified against its
  # SHA-256 before it is published, under build/l4re-sources, a root of its own beside
  # the build's output (build/l4re), so no id it names can replace a source of erXos's
  # deps.lock. Upstream Fiasco's commit is the fork's: the Revision line of
  # fiasco/kernel/ORIGIN.md, which the lock must pin, so the fork's one pin moves both
  # kernels.
  #
  # The trees are untrusted data: nothing of them runs on the host. L4Re's container
  # build mounts each at the path L4Re's manifest gives it (LAYOUT).
  module L4ReFetch
    LOCK = 'bench/l4re/deps.lock'
    WORKSPACE = 'build/l4re-sources'
    ORIGIN = 'fiasco/kernel/ORIGIN.md'
    # Each source's path in the tree L4Re's build sees, as the manifest lays it out.
    LAYOUT = { 'l4re-mk' => 'l4', 'l4re-core' => 'l4/pkg/l4re-core', 'l4re-bootstrap' => 'l4/pkg/bootstrap',
               'l4re-libfdt' => 'l4/pkg/libfdt', 'l4re-drivers-frst' => 'l4/pkg/drivers-frst',
               'l4re-fiasco' => 'fiasco', 'l4re-ipcbench' => 'l4/pkg/ipcbench' }.freeze

    module_function

    # Fetches every source the lock pins; cache is another checkout's
    # build/l4re-sources/build/downloads, from which the archives come with no network.
    # Returns the lines that say what was done.
    def fetch(root:, runner:, cache: nil)
      dependencies = lock(root: root, runner: runner)
      dependencies.fetch(cache: cache)
      dependencies.sources.map do |source|
        tree = dependencies.fetched_tree(source.fetch('id')).delete_prefix("#{File.expand_path(root)}/")
        "l4re: #{source.fetch('id')} #{source.fetch('commit')[0, 12]} fetched to #{tree}"
      end
    end

    # The lock's sources over the workspace; refuses a lock that pins anything but git
    # sources at exactly LAYOUT's ids, so the build mounts every tree it fetched, or that
    # pins upstream Fiasco at another commit than the fork's. Its fetched_tree(id) is the
    # tree LAYOUT places.
    def lock(root:, runner:)
      dependencies = Dependencies.new(root: OutputDirectory.prepare(root: root, path: File.join(root, WORKSPACE)),
                                      runner: runner, lock_path: File.join(root, LOCK))
      ids = dependencies.sources.map { |source| source.fetch('id') }
      unless dependencies.sources.all? { |source| source.fetch('kind') == 'git' } && ids.sort == LAYOUT.keys.sort
        raise Error, "#{LOCK} pins #{ids.join(', ')}; L4Re's lock pins git sources #{LAYOUT.keys.join(', ')}"
      end
      fiasco = dependencies.sources.find { |source| source.fetch('id') == 'l4re-fiasco' }.fetch('commit')
      revision = fork_revision(root)
      unless fiasco == revision
        raise Error, "#{LOCK} pins upstream Fiasco at #{fiasco}, not the fork's revision #{revision} (#{ORIGIN})"
      end
      dependencies
    end

    def fork_revision(root)
      File.read(File.join(root, ORIGIN))[/^Revision: ([0-9a-f]{40})$/, 1] ||
        raise(Error, "#{ORIGIN} names no Revision")
    end
    private_class_method :fork_revision
  end
end
