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
  # pre-compiled tool chain for Ubuntu 24.04, the archive its tool-chain page publishes
  # with its SHA-256. Each is verified against its pin before it is published under
  # build/genode-sources, a root of its own, so no id it names can replace a source of
  # erXos's deps.lock.
  #
  # Genode is AGPL-3.0 and a test oracle: its tree and tool chain are untrusted data that
  # nothing on the host runs or reads. Its container build copies them in whole.
  module GenodeFetch
    LABEL = 'genode'
    LOCK = 'bench/genode/deps.lock'
    WORKSPACE = 'build/genode-sources'
    # Each pinned id and the kind its pin must have.
    SOURCES = { 'genode' => 'git', 'genode-toolchain' => 'file' }.freeze
    # The tool chain's archive as Genode publishes it for Ubuntu 24.04, the container's
    # distribution; its version is the pin's own field.
    TOOLCHAIN = /\Agenode-toolchain-[0-9.]+-ubuntu-24\.04\.tar\.xz\z/

    module_function

    # Fetches both sources; cache is another checkout's build/genode-sources/build/downloads,
    # from which the archives come with no network. Returns the lines that say what was done.
    def fetch(root:, runner:, cache: nil)
      SideLock.fetch(lock(root: root, runner: runner), root: root, label: LABEL, cache: cache)
    end

    # The lock's sources over the workspace; refuses a lock that does not pin exactly
    # SOURCES, each of its kind, or whose tool chain is not the Ubuntu 24.04 archive, so
    # the build never meets a source it does not use.
    def lock(root:, runner:)
      dependencies = SideLock.dependencies(root: root, runner: runner, lock: LOCK, workspace: WORKSPACE, label: LABEL)
      pinned = dependencies.sources.to_h { |source| [source.fetch('id'), source.fetch('kind')] }
      unless pinned == SOURCES
        raise Error, "#{LOCK} pins #{pinned.map { |id, kind| "#{id} (#{kind})" }.join(', ')}; " \
                     "Genode's lock pins #{SOURCES.map { |id, kind| "#{id} (#{kind})" }.join(' and ')}"
      end
      filename = dependencies.sources.find { |source| source.fetch('id') == 'genode-toolchain' }.fetch('filename')
      raise Error, "#{LOCK} pins #{filename}, not Genode's pre-compiled tool chain for Ubuntu 24.04" unless
        TOOLCHAIN.match?(filename)

      dependencies
    end
  end
end
