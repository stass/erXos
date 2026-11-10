# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'etc'
require_relative 'error'
require_relative 'runner'
require_relative 'bounded_file'
require_relative 'generated'

module Erx
  # erx-lvgl for the host (docs/design-display.md, "The widget server"):
  # LVGL from the git submodule display/lvgl/lvgl (display/lvgl/ORIGIN.md),
  # the generated ui.txt reader and writer, and display/lvgl/erx_lvgl.c,
  # built by display/lvgl/Makefile into build/host/lvgl/VARIANT. The
  # sanitized variant, under ASan and UBSan, is the one the tests run; GNU make
  # keeps the objects, so a rebuild compiles only what changed. Nothing of
  # the submodule runs: the build compiles its C and nothing else.
  module Lvgl
    SUBMODULE = 'display/lvgl/lvgl'
    MAKEFILE = 'display/lvgl/Makefile'
    DEADLINE = 1800
    GIT_DEADLINE = 900
    STATUS_BYTES = 65_536
    SANITIZE = '-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer'
    INIT_COMMAND = "git submodule update --init #{SUBMODULE}".freeze
    # The flags after S in the submodule field of a porcelain v2 entry.
    DRIFT_NOTES = { 'C' => 'is not at the commit the index records', 'M' => 'has changes to tracked files',
                    'U' => 'has untracked files' }.freeze

    module_function

    def checked_out?(root) = File.file?(File.join(root, SUBMODULE, 'lvgl.h'))

    # Clones the submodule at the commit the superproject records, with no
    # history, when it is not checked out yet; `git fetch --unshallow` in it
    # brings the history for patch work. A checkout that is there is left as
    # it is, so a patch being developed in it is never moved. `tools/erx
    # fetch` runs it: the one step that reaches the network for LVGL. Returns
    # the line that says which of the two it did.
    def init(root:, runner:)
      return "LVGL: #{SUBMODULE} is already checked out; left as it is" if checked_out?(root)
      git(root: root, runner: runner, name: 'lvgl-submodule-init',
          arguments: ['submodule', 'update', '--init', '--depth', '1', '--', SUBMODULE])
      "LVGL: cloned #{SUBMODULE} at the commit its gitlink records, without history"
    end

    # LVGL's tree for the build. A missing checkout is the one refusal. A
    # checkout that differs from what the superproject's HEAD records, or
    # that git cannot report on, is built with a warning, since a checkout
    # moved to a patch of the fork is how a patch is developed.
    def source_tree(root:, runner:)
      raise Error, "LVGL is not checked out at #{SUBMODULE}; run `#{INIT_COMMAND}`" unless checked_out?(root)
      notes = begin
        drift(status(root: root, runner: runner))
      rescue Error => error
        ["cannot be checked: #{error.message}"]
      end
      notes.each { |note| Terminal.puts("warning: #{SUBMODULE} #{note}") }
      File.join(root, SUBMODULE)
    end

    # Decides what `git status --porcelain=v2` says of the submodule. Its
    # entry, `1 XY S<c><m><u> mH mI mW hH hI path`, is absent when the
    # checkout and the index match HEAD. XY other than `..` is a change
    # staged or unstaged (a staged gitlink bump among them), hH and hI differ
    # when the index records another commit than HEAD, and c, m and u name
    # what differs in the checkout. An unmerged entry (`u`) is a conflict.
    def drift(porcelain)
      porcelain.each_line(chomp: true).flat_map do |line|
        kind, xy, sub, *rest = line.split(' ')
        next [] unless rest.last == SUBMODULE
        next ['has an unresolved merge conflict'] if kind == 'u'
        next [] unless %w[1 2].include?(kind) && sub&.start_with?('S')

        head, index = rest[3], rest[4]
        notes = DRIFT_NOTES.filter_map { |flag, note| note if sub.include?(flag) }
        notes.unshift('is staged at another commit than HEAD records') if head != index
        notes.empty? && xy != '..' ? ["differs from HEAD (#{xy})"] : notes
      end
    end

    # The submodule is never ignored and its untracked files are always
    # shown, whatever the user's configuration says; --no-optional-locks
    # keeps git from rewriting an index under the output limit.
    def status(root:, runner:)
      result = git(root: root, runner: runner, name: 'lvgl-submodule-status',
                   arguments: ['--no-optional-locks', 'status', '--porcelain=v2', '--ignore-submodules=none',
                               '--untracked-files=normal', '--', SUBMODULE],
                   output_limit: STATUS_BYTES)
      BoundedFile.read(result.fetch('log'), maximum: STATUS_BYTES)
    end

    # git on the superproject the root names, with no GIT_ variable of the
    # caller's environment and core.fsmonitor off, so it acts on that
    # checkout alone and starts no program its configuration names.
    def git(root:, runner:, name:, arguments:, output_limit: nil)
      unless File.exist?(File.join(root, '.git'))
        raise Error, "#{root} is not a git checkout, so git cannot fetch or check #{SUBMODULE}"
      end
      runner.run(['git', '-c', 'core.fsmonitor=false', '-C', root, *arguments], name: name,
                 deadline: GIT_DEADLINE, chdir: root, output_limit: output_limit,
                 env: ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] })
    rescue CommandError => error
      raise Error, "git #{arguments.grep_v(/\A-/).first} of #{SUBMODULE} failed; log: #{error.result.fetch('log')}"
    end
    private_class_method :status, :git

    # Builds the variant and returns the program's path.
    class Build
      def initialize(root:, runner:, sanitized: true, jobs: Etc.nprocessors)
        @root = File.expand_path(root)
        @runner = runner
        @sanitized = sanitized
        @jobs = jobs
      end

      def call
        tree = Lvgl.source_tree(root: @root, runner: @runner)
        Generated.ensure(root: @root)
        output = File.join(@root, 'build/host/lvgl', @sanitized ? 'sanitized' : 'plain')
        @runner.run(['gmake', "-j#{@jobs}", '-f', File.join(@root, MAKEFILE), "LVGL=#{tree}",
                     "GEN=#{File.join(@root, Generated::OUTPUT)}", "OUT=#{output}",
                     "CC=#{ENV.fetch('ERX_CLANG', 'clang')}", "SANITIZE=#{@sanitized ? SANITIZE : ''}"],
                    name: "lvgl-#{@sanitized ? 'sanitized' : 'plain'}", deadline: DEADLINE, chdir: @root)
        File.join(output, 'erx-lvgl')
      end
    end
  end
end
