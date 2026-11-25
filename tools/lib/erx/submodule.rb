# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'git_environment'
require_relative 'runner'

module Erx
  # The one place erXos runs git on a git submodule of its tree (Origin::SUBMODULES):
  # LVGL's, which the build compiles from (Lvgl), and an example's, which only
  # `tools/erx fetch --example` obtains (ExampleFetch). A submodule's checkout is
  # untrusted data: git runs with the fsmonitor off, so no program the checkout's
  # configuration names starts, and with the caller's GIT_* variables unset.
  module Submodule
    DEADLINE = 900
    # git refuses a clone from a local path (a worktree whose shared configuration
    # points the submodule at the main checkout's clone) unless the file transport is
    # allowed; the clone allows it for its one command, never in git's configuration.
    FILE_TRANSPORT = 'protocol.file.allow=always'

    module_function

    # Clones the submodule at path at the commit the superproject records, with no
    # history when its URL is remote (git ignores --depth for a local path). update
    # names the update mode to force ('checkout'), for a submodule whose .gitmodules
    # entry says `update = none` so that no recursive clone obtains it. url, for this
    # one command, replaces the URL .gitmodules gives (a clone of the main checkout's
    # copy, module_store), and git's configuration never records it.
    def checkout(root:, runner:, path:, name:, update: nil, url: nil)
      config = [FILE_TRANSPORT, *("submodule.#{path}.url=#{url}" if url)]
      git(root: root, runner: runner, path: path, name: name, config: config,
          arguments: ['submodule', 'update', '--init', '--depth', '1', *("--#{update}" if update), '--', path])
    end

    # The git directory that already holds the submodule at path for the checkout at
    # root, or nil: a clone's own `.git/modules/PATH`, or for a linked worktree the
    # one its main checkout keeps, which the worktree can clone from with no network.
    # Read from the files git writes: `.git` as a file names the worktree's git
    # directory, whose `commondir` names the shared one.
    def module_store(root:, path:)
      dot_git = File.join(root, '.git')
      gitdir = File.file?(dot_git) ? File.expand_path(gitdir_line(dot_git), root) : dot_git
      commondir = File.join(gitdir, 'commondir')
      common = File.file?(commondir) ? File.expand_path(File.read(commondir).strip, gitdir) : gitdir
      store = File.join(common, 'modules', path)
      File.directory?(store) ? store : nil
    end

    def gitdir_line(dot_git)
      File.read(dot_git)[/\Agitdir: (.+?)\r?$/, 1] || raise(Error, "#{dot_git} is a file that names no git directory")
    end
    private_class_method :gitdir_line

    # Runs git on the checkout at root alone and starts no program its configuration
    # names. config adds `-c` settings for this one command.
    def git(root:, runner:, path:, name:, arguments:, config: [], output_limit: nil)
      unless File.exist?(File.join(root, '.git'))
        raise Error, "#{root} is not a git checkout, so git cannot fetch or check #{path}"
      end
      settings = ['core.fsmonitor=false', *config].flat_map { |setting| ['-c', setting] }
      runner.run(['git', *settings, '-C', root, *arguments], name: name,
                 deadline: DEADLINE, chdir: root, output_limit: output_limit,
                 env: GitEnvironment.isolated)
    rescue CommandError => error
      raise Error, "git #{arguments.grep_v(/\A-/).first} of #{path} failed; log: #{error.result.fetch('log')}"
    end
  end
end
