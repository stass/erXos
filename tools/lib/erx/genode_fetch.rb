# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'side_lock'

module Erx
  # `tools/erx fetch --genode` (docs/design-bench.md, "Genode's guest"): what Genode's
  # guest in the benchmark comparison is built from, fetched on demand and by nothing
  # else, so neither a default fetch nor a --cache fetch downloads it. Genode's own lock
  # (SideLock), bench/genode/deps.lock, pins exactly two sources: Genode's release, a
  # git source whose tagged commit is exported as git's tar of it, and Genode's
  # pre-compiled tool chain, the archive its tool-chain page publishes with its SHA-256,
  # in the build for Debian 12, the distribution of the oracle's amd64 toolchain image.
  # Each is verified against its pin before it is published under build/genode-sources,
  # a root of its own, so no id it names can replace a source of erXos's deps.lock.
  #
  # Genode is AGPL-3.0 and a test oracle: the tree and the tool chain are untrusted data
  # that nothing on the host runs or reads, and nothing of them enters erXos's tree.
  module GenodeFetch
    LABEL = 'genode'
    LOCK = 'bench/genode/deps.lock'
    WORKSPACE = 'build/genode-sources'
    # Each pinned id and the kind its pin must have.
    SOURCES = { 'genode' => 'git', 'genode-toolchain' => 'file' }.freeze

    module_function

    # Fetches both sources; cache is another checkout's build/genode-sources/build/downloads,
    # from which the archives come with no network. Returns the lines that say what was done.
    def fetch(root:, runner:, cache: nil)
      SideLock.fetch(lock(root: root, runner: runner), root: root, label: LABEL, cache: cache)
    end

    # The lock's sources over the workspace; refuses a lock that does not pin exactly
    # SOURCES, each of its kind, so a fetch never brings a source the guest does not use.
    def lock(root:, runner:)
      dependencies = SideLock.dependencies(root: root, runner: runner, lock: LOCK, workspace: WORKSPACE, label: LABEL)
      pinned = dependencies.sources.to_h { |source| [source.fetch('id'), source.fetch('kind')] }
      return dependencies if pinned == SOURCES

      raise Error, "#{LOCK} pins #{pinned.map { |id, kind| "#{id} (#{kind})" }.join(', ')}; " \
                   "Genode's lock pins #{SOURCES.map { |id, kind| "#{id} (#{kind})" }.join(' and ')}"
    end
  end
end
