# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'rbconfig'
require_relative 'abi'
require_relative 'bounded_file'
require_relative 'runner'

module Erx
  # Lands one commit by cherry-picking it. A conflict only in the ABI
  # generator's outputs carries no decision: the outputs are a function of
  # the sources, which merged, so this removes the conflicted outputs,
  # regenerates, proves the result matches and continues. A conflict anywhere
  # else is someone's decision: this stops with the pick in progress and lists
  # the files, and `resume` finishes once they are resolved and added. Every
  # commit it makes has outputs the generator has just checked against the
  # sources in that commit, a clean pick's included.
  class Land
    # state is :picked, :refreshed (a clean pick whose outputs were stale),
    # :regenerated, or :stopped; paths are the conflicted outputs, or when
    # stopped the files left to resolve.
    Outcome = Data.define(:state, :paths)
    LISTING_BYTES = 1 << 20
    GIT_DEADLINE = 120
    GENERATOR_DEADLINE = 120

    # What the ABI generator owns.
    def self.abi_output?(path)
      path == ABI::Generator::INVENTORY ||
        ABI::Generator::OWNED.any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME) }
    end

    # The files a person must resolve: every conflict outside the outputs.
    def self.left_to_resolve(conflicts, generated) = conflicts.reject { |path| generated.call(path) }

    def initialize(root:, runner:, env: {}, generator: [RbConfig.ruby, 'tools/gen_abi.rb'],
                   generated: self.class.method(:abi_output?))
      @root = root
      @runner = runner
      @env = env
      @generator = generator
      @generated = generated
    end

    def pick(commit)
      refuse_edits(tracked_changes)
      begin
        git('cherry-pick', commit)
      rescue CommandError => error
        conflicts = unmerged
        if conflicts.empty?
          raise Error, "cherry-pick of #{commit} failed with no conflict, as for a missing or an already applied " \
                       "commit; see #{error.result.fetch('log')}, and git cherry-pick --abort if one is in progress"
        end
        return settle(conflicts)
      end
      check_clean_pick
    end

    # After the files a stop listed are resolved and added.
    def resume
      raise Error, 'land: no cherry-pick is in progress' unless pick_in_progress?

      conflicts = unmerged
      refuse_edits(tracked_changes - conflicts) if self.class.left_to_resolve(conflicts, @generated).empty?
      settle(conflicts)
    end

    private

    def settle(conflicts)
      left = self.class.left_to_resolve(conflicts, @generated)
      return Outcome.new(state: :stopped, paths: left) unless left.empty?

      conflicts.each { |path| FileUtils.rm_f(File.join(@root, path)) }
      regenerate(also: conflicts)
      git('-c', 'core.editor=true', 'cherry-pick', '--continue')
      Outcome.new(state: :regenerated, paths: conflicts)
    end

    # Non-overlapping changes can merge cleanly into outputs that are stale,
    # as when the target changed an emitter and the commit adds a call.
    def check_clean_pick
      generate('--check')
      Outcome.new(state: :picked, paths: [])
    rescue CommandError
      regenerate(also: [])
      git('commit', '--amend', '--no-edit')
      Outcome.new(state: :refreshed, paths: [])
    end

    # Generates from the working tree and stages the outputs; refuse_edits
    # has made sure the tree's sources are the ones being committed.
    def regenerate(also:)
      generate
      stage = (also + listed('ls-files', '--modified', '--deleted', '--others', '--exclude-standard', '-z'))
              .uniq.select { |path| @generated.call(path) }
      git('add', '--all', '--', *stage) unless stage.empty?
      generate('--check')
    end

    # An edit that is not staged would reach the generator and not the commit.
    def refuse_edits(paths)
      edits = paths.reject { |path| @generated.call(path) }
      return if edits.empty?

      raise Error, "land: first commit, add or set aside these edits: #{edits.first(8).join(', ')}"
    end

    def generate(*arguments)
      @runner.run([*@generator, *arguments], name: 'land-generate', deadline: GENERATOR_DEADLINE, chdir: @root, env: @env)
    end

    def pick_in_progress?
      git('rev-parse', '--quiet', '--verify', 'CHERRY_PICK_HEAD')
      true
    rescue CommandError
      false
    end

    def unmerged = listed('diff', '--name-only', '--diff-filter=U', '-z')

    def tracked_changes = listed('ls-files', '--modified', '--deleted', '-z')

    def listed(*arguments)
      result = git(*arguments)
      BoundedFile.read(result.fetch('log'), maximum: LISTING_BYTES).split("\0").uniq.sort
    end

    def git(*arguments)
      @runner.run(['git', *arguments], name: 'land-git', deadline: GIT_DEADLINE, chdir: @root, env: @env)
    end
  end
end
