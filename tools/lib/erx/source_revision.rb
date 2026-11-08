# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # Which source a build is of, as git records it, for what `uname -v` shows
  # (docs/design-shell.md, "Text commands"): the commit count and the 12-digit
  # commit hash, FreeBSD's sys/conf/newvers.sh form without its branch,
  # whether tracked files differ from that commit, and the commit's date.
  # Each is a fact of the source alone, the same for every build of one tree
  # in one state on any branch, so it keeps the boot image reproducible and
  # one commit gives one image wherever it is checked out; no branch, no
  # build counter and no build time enter it.
  #
  # The facts are read once per build, with git started through an argument
  # vector (Runner), never a shell. A tree that is not a git checkout, such as
  # an unpacked source archive, has no revision: read answers nil and the
  # build reports the revision as unknown. A checkout whose git fails, or
  # answers something this module cannot read, is a failure with a
  # diagnostic, never a made-up revision.
  module SourceRevision
    # count is nil in a shallow clone, whose count would be short; committed_at
    # is the commit's committer time, a UTC Time.
    Revision = Data.define(:count, :hash, :dirty, :committed_at) do
      # newvers.sh's words without the branch: [n<count>-]<hash>[-dirty].
      def to_s = [count && "n#{count}", hash, ('dirty' if dirty)].compact.join('-')
    end

    # git's fsmonitor setting, which would run a hook program, is turned off,
    # and so is every GIT_ variable of the environment (read), any of which
    # could redirect git to another tree or add configuration; the stat and
    # mode settings are newvers.sh's, so a checkout's file times and modes
    # alone do not mark it dirty, and paths are quoted, so a changed file's
    # name is ASCII whatever the user's configuration says.
    GIT = %w[git --no-optional-locks --no-pager -c core.fsmonitor=false -c core.checkStat=minimal
             -c core.fileMode=off -c core.quotePath=true].freeze
    # Where a query names the commit, which read resolves once, first, so every
    # answer is of the one commit even if HEAD moves during the build.
    COMMIT = :commit
    # What each query asks, by name, and how its answer must read.
    QUERIES = {
      commit: [%w[rev-parse --verify HEAD^{commit}], /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/],
      shallow: [%w[rev-parse --is-shallow-repository], /\A(?:true|false)\z/],
      count: [[*%w[rev-list --first-parent --count], COMMIT], /\A[1-9][0-9]{0,9}\z/],
      committed: [[*%w[show -s --no-show-signature --format=%ct], COMMIT], /\A[0-9]{1,12}\z/],
      # Porcelain lines alone, `XY path`, so a warning git writes to the same log
      # is refused rather than read as a change.
      changes: [%w[status --porcelain --untracked-files=no --ignore-submodules=none], /\A(?:[ MTADRCU]{2} .+\n)*\z/]
    }.freeze
    DEADLINE = 60
    # The hash's length on the line, newvers.sh's, cut from the full hash so it
    # does not grow as git's shortest unambiguous form would.
    HASH_DIGITS = 12

    module_function

    # The revision of the checkout at root, or nil when root is no checkout.
    def read(root:, runner:)
      return nil unless File.exist?(File.join(root, '.git'))

      environment = ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }
      ask = lambda do |name, arguments|
        result = runner.run([*GIT, *arguments], name: "source-revision-#{name}", deadline: DEADLINE,
                                                 chdir: root, env: environment)
        File.binread(result.fetch('log'))
      end
      commit = ask.call(:commit, QUERIES.fetch(:commit).first)
      resolved = answer(:commit, commit)
      answers = QUERIES.to_h do |name, (arguments, _shape)|
        [name, name == :commit ? commit : ask.call(name, arguments.map { |word| word == COMMIT ? resolved : word })]
      end
      parse(answers)
    end

    # The revision the answers of QUERIES give, each git's output with its
    # final newline. Pure, for the tests.
    def parse(answers)
      given = QUERIES.keys.to_h { |name| [name, answer(name, answers.fetch(name))] }
      Revision.new(count: (Integer(given.fetch(:count), 10) if given.fetch(:shallow) == 'false'),
                   hash: given.fetch(:commit)[0, HASH_DIGITS], dirty: !given.fetch(:changes).empty?,
                   committed_at: Time.at(Integer(given.fetch(:committed), 10)).utc)
    end

    # One answer without its final newline (all of it for changes), which
    # raises when it is not of its query's shape, such as a warning git
    # wrote in place of a hash.
    def answer(name, text)
      text = text.chomp unless name == :changes
      raise Error, "git's answer to #{name} is not what a source revision needs: #{text.dump}" unless
        text.ascii_only? && QUERIES.fetch(name).last.match?(text)

      text
    end
  end
end
