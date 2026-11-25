# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'dependencies'
require_relative 'output_directory'

module Erx
  # A comparison guest's own lock (docs/design-bench.md, "Other systems in QEMU under
  # HVF"): the pins of another system's guest, in the form of erXos's deps.lock, fetched
  # on demand, each by its guest's own fetch (`tools/erx fetch --l4re`), into a
  # workspace of their own under build/, so neither a default fetch nor a --cache fetch
  # needs them and no id they name can replace a source of erXos's deps.lock. Each
  # guest's module names its lock.
  module SideLock
    module_function

    # The command that fetches the side lock label names (`--l4re`), which a
    # refusal of a source it has not fetched names.
    def fetch_command(label) = "ruby tools/erx fetch --#{label}"

    # The sources lock pins (a path below root), over workspace, also below root, its
    # unfetched sources naming the fetch of label.
    def dependencies(root:, runner:, lock:, workspace:, label:)
      Dependencies.new(root: OutputDirectory.prepare(root: root, path: File.join(root, workspace)),
                       runner: runner, lock_path: File.join(root, lock), refetch: fetch_command(label))
    end

    # Fetches every source of dependencies, from cache (another checkout's
    # <workspace>/build/downloads) when given: a line per source, under label, of its
    # pin and where it was published.
    def fetch(dependencies, root:, label:, cache: nil)
      dependencies.fetch(cache: cache)
      dependencies.sources.map do |source|
        id = source.fetch('id')
        published = source.fetch('kind') == 'file' ? dependencies.fetched_file(id) : dependencies.fetched_tree(id)
        pin = source.fetch(source.fetch('kind') == 'git' ? 'commit' : 'sha256')[0, 12]
        "#{label}: #{id} #{pin} fetched to #{published.delete_prefix("#{File.expand_path(root)}/")}"
      end
    end
  end
end
