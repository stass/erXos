# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # Directories that hold version-control internals, credentials or agent
  # state. A build reads no input from inside one: such bytes are not erXos
  # sources, and a build record must never carry their contents or hashes.
  # The project's .gitignore ignores each of them but .git wherever it
  # appears, so the source check never lists an untracked one either; a host
  # test keeps the two lists in step.
  module PrivateState
    DIRECTORY_NAMES = %w[.git .claude .codex .agents .aws .ssh .gnupg].freeze
    module_function

    # Decides whether a canonical path lies inside a private directory. For a
    # path inside the project only the components below the project root
    # count, so a checkout that itself sits under a private directory (an
    # agent worktree under .claude/worktrees, a Codex worktree under .codex)
    # still reads its own sources. For a path outside the project, such as a
    # compiler's SDK file, every component counts. A path that is not
    # absolute or holds an empty, "." or ".." component is refused, since its
    # components would not say where it leads.
    def inside?(path, project_root:)
      components = path.split('/', -1).drop(1)
      unless path.start_with?('/') && components.none? { |component| ['', '.', '..'].include?(component) }
        raise Error, 'private-state check needs an absolute canonical path'
      end
      root = File.realpath(project_root)
      counted = if path == root
                  []
                elsif path.start_with?(root + '/')
                  path.delete_prefix(root + '/').split('/')
                else
                  components
                end
      counted.any? { |component| DIRECTORY_NAMES.include?(component) }
    end
  end
end
