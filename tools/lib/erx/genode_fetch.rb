# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'side_lock'

module Erx
  # `tools/erx fetch --genode` (docs/design-bench.md, "Genode's guest"): what Genode's
  # guest in the benchmark comparison is built from, fetched on demand and by nothing
  # else, so neither a default fetch nor a --cache fetch downloads it. Genode's own lock
  # (SideLock), bench/genode/deps.lock, pins Genode's release, a git source whose tagged
  # commit is exported as git's tar of it, and Genode's pre-compiled tool chain, the
  # archive its tool-chain page publishes with its SHA-256, in the build for Debian 12,
  # the distribution of the oracle's amd64 toolchain image, each once; beside them only
  # files of two classes: the archives of Genode's ports (PORT), each under the name
  # Genode's port tool asks for, and Debian amd64 packages of the tools the image lacks
  # (TOOL). Each is verified against its pin before it is published under
  # build/genode-sources, a root of its own, so no id it names can replace a source of
  # erXos's deps.lock.
  #
  # Genode is AGPL-3.0 and a test oracle: the tree and the tool chain are untrusted data
  # that nothing on the host runs or reads, and nothing of them enters erXos's tree.
  module GenodeFetch
    LABEL = 'genode'
    LOCK = 'bench/genode/deps.lock'
    WORKSPACE = 'build/genode-sources'
    # The release and the tool chain: each id, pinned once, and the kind its pin must have.
    SOURCES = { 'genode' => 'git', 'genode-toolchain' => 'file' }.freeze
    # A port's archive: genode-port-<port>, its filename the one Genode's prepare_port
    # gives the download, which the probe of Genode's tools run offline printed
    # (docs/design-bench.md, "Genode's guest", "Third-party sources"); one archive per port.
    PORT = /\Agenode-port-[a-z0-9][a-z0-9_.-]*\z/
    # A tool the image lacks, as a Debian package for its architecture: genode-tool-<name>,
    # its filename <name>_amd64.deb (its version is the pin's own field).
    TOOL = 'genode-tool-'

    module_function

    # Fetches every source the lock pins; cache is another checkout's build/genode-sources/build/downloads,
    # from which the archives come with no network. Returns the lines that say what was done.
    def fetch(root:, runner:, cache: nil)
      SideLock.fetch(lock(root: root, runner: runner), root: root, label: LABEL, cache: cache)
    end

    # The lock's sources over the workspace; refuses a lock that does not pin each of
    # SOURCES with its kind, or that pins anything else than a port's archive (PORT) or
    # a tool package (TOOL), so a fetch never brings a source the guest does not use.
    def lock(root:, runner:)
      dependencies = SideLock.dependencies(root: root, runner: runner, lock: LOCK, workspace: WORKSPACE, label: LABEL)
      named, others = dependencies.sources.partition { |source| SOURCES.key?(source.fetch('id')) }
      pinned = named.to_h { |source| [source.fetch('id'), source.fetch('kind')] }
      unless pinned == SOURCES
        raise Error, "#{LOCK} pins #{pinned.map { |id, kind| "#{id} (#{kind})" }.join(', ')}; " \
                     "Genode's lock pins #{SOURCES.map { |id, kind| "#{id} (#{kind})" }.join(' and ')}"
      end
      strays = others.reject { |source| port?(source) || tool?(source) }
      return dependencies if strays.empty?

      raise Error, "#{LOCK} pins #{strays.map { |source| source.fetch('id') }.join(', ')}, which are neither " \
                   "Genode's release and tool chain, a port's archive (genode-port-<port>) nor a Debian " \
                   'amd64 tool package (genode-tool-<name>, <name>_amd64.deb)'
    end

    def port?(source) = source.fetch('kind') == 'file' && PORT.match?(source.fetch('id'))

    def tool?(source)
      id = source.fetch('id')
      source.fetch('kind') == 'file' && id.start_with?(TOOL) && source.fetch('filename') == "#{id.delete_prefix(TOOL)}_amd64.deb"
    end
    private_class_method :port?, :tool?
  end
end
